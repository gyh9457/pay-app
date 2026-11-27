#!/usr/bin/env python3
"""Check or renew the locally installed PayLedger development build."""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import subprocess
from tempfile import TemporaryDirectory
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[4]
BUNDLE_ID = "com.guoyanhao.payledger"
DEFAULT_IPA = ROOT / "dist" / "PayLedger-iPhone.ipa"


def run(*args, data=None, capture=False):
    return subprocess.run(
        args, input=data, stdout=subprocess.PIPE if capture else None,
        cwd=ROOT, check=True,
    ).stdout


def read_profile(data):
    return plistlib.loads(run("security", "cms", "-D", data=data, capture=True))


def local_expiry(profile):
    expiry = profile["ExpirationDate"].replace(tzinfo=timezone.utc)
    return expiry.astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")


def device_query(result, *args):
    run("xcrun", "devicectl", *args, "--timeout", "20", "--quiet", "--json-output", str(result))
    return json.loads(result.read_text())["result"]


def choose_phone(devices, allowed_udids, explicit_device):
    phones = []
    for device in devices:
        properties = device["properties"]
        hardware = properties["hardware"]
        udid = hardware.get("udid")
        if hardware.get("reality") != "physical" or hardware.get("deviceType") != "iPhone":
            continue
        if udid not in allowed_udids or (explicit_device and udid != explicit_device):
            continue
        phones.append(properties)
    if len(phones) != 1:
        raise ValueError("找不到唯一匹配的原 iPhone。请在 Device Hub 核对设备。")
    return phones[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("check", "renew"))
    parser.add_argument("--ipa", type=Path, default=DEFAULT_IPA, help="上次签名的 IPA")
    parser.add_argument("--team", help="没有上次的 IPA 时，指定已核实的原 Team ID")
    parser.add_argument("--device", help="指定已核实的原 iPhone UDID")
    args = parser.parse_args()

    old_profile = None
    if args.ipa.is_file():
        with ZipFile(args.ipa) as archive:
            old_profile = read_profile(archive.read("Payload/PayLedger.app/embedded.mobileprovision"))
        team, = old_profile["TeamIdentifier"]
        app_identifier = old_profile["Entitlements"]["application-identifier"]
        allowed_udids = old_profile.get("ProvisionedDevices", [])
        if not app_identifier.endswith(f".{BUNDLE_ID}") or (args.team and args.team != team):
            raise ValueError("上次安装包的应用标识或开发团队不匹配。")
        print(f"上次签名到期：{local_expiry(old_profile)}", flush=True)
    else:
        if not args.team or not args.device:
            raise ValueError("缺少上次签名的 IPA。请提供 --ipa，或核实并提供 --team 和 --device。")
        team = args.team
        app_identifier = f"{team}.{BUNDLE_ID}"
        allowed_udids = [args.device]

    with TemporaryDirectory(prefix="payledger-renew-") as tmp:
        work = Path(tmp)
        devices = device_query(work / "devices.json", "list", "devices")["devices"]
        phone = choose_phone(devices, allowed_udids, args.device)
        connection = phone["connection"]
        state = connection["state"]
        transport = connection.get("transportType", "")
        print(f"iPhone 连接状态：{state} {transport}".rstrip(), flush=True)
        if args.action == "check":
            return
        if state != "connected":
            raise ValueError("iPhone 尚未连接到 Xcode。请解锁手机，并检查同一局域网或 USB 连接。")

        udid = phone["hardware"]["udid"]
        device_args = ("--device", udid)
        apps = device_query(work / "apps.json", "device", "info", "apps", *device_args,
                            "--bundle-id", BUNDLE_ID)["apps"]
        if not apps:
            raise ValueError("手机上没有找到原来的随手记，无法覆盖安装。")

        run("xcodebuild", "build", "-project", "PayLedger.xcodeproj", "-scheme", "PayLedger",
            "-configuration", "Release", "-destination", f"platform=iOS,id={udid}",
            "-destination-timeout", "30", "-derivedDataPath", str(work / "build"),
            "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration", "-quiet",
            f"PRODUCT_BUNDLE_IDENTIFIER={BUNDLE_ID}", f"DEVELOPMENT_TEAM={team}",
            "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_STYLE=Automatic")

        app = work / "build/Build/Products/Release-iphoneos/PayLedger.app"
        run("codesign", "--verify", "--strict", str(app))
        signed = run("codesign", "-d", "--xml", "--entitlements", "-", str(app), capture=True)
        start = signed.index(b"<?xml")
        end = signed.index(b"</plist>", start) + len(b"</plist>")
        entitlements = plistlib.loads(signed[start:end])
        profile = read_profile((app / "embedded.mobileprovision").read_bytes())
        if (profile["TeamIdentifier"] != [team]
                or profile["Entitlements"]["application-identifier"] != app_identifier
                or entitlements["application-identifier"] != app_identifier
                or entitlements["com.apple.developer.team-identifier"] != team
                or udid not in profile["ProvisionedDevices"]):
            raise ValueError("新包的团队、应用标识或授权设备不匹配，无法覆盖安装。")

        expiry = profile["ExpirationDate"].replace(tzinfo=timezone.utc)
        if expiry <= datetime.now(timezone.utc):
            raise ValueError("Xcode 生成的签名描述文件已经到期。")
        if old_profile and profile["ExpirationDate"] <= old_profile["ExpirationDate"]:
            print("Xcode 沿用了原签名，本次有效期未延长。")
            return

        payload = work / "Payload"
        payload.mkdir()
        run("ditto", str(app), str(payload / "PayLedger.app"))
        DEFAULT_IPA.parent.mkdir(exist_ok=True)
        with TemporaryDirectory(prefix=".payledger-ipa-", dir=DEFAULT_IPA.parent) as staging:
            ipa = Path(staging) / DEFAULT_IPA.name
            run("ditto", "-c", "-k", "--keepParent", str(payload), str(ipa))
            run("unzip", "-tq", str(ipa))
            run("xcrun", "devicectl", "device", "install", "app", *device_args, "--timeout", "45", str(app))
            os.replace(ipa, DEFAULT_IPA)
        print(f"已覆盖安装，签名到期：{local_expiry(profile)}", flush=True)
        print(f"已更新安装包：{DEFAULT_IPA.relative_to(ROOT)}", flush=True)
        run("xcrun", "devicectl", "device", "process", "launch", *device_args,
            "--timeout", "20", BUNDLE_ID)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        raise SystemExit(f"{Path(error.cmd[0]).name} 失败，退出码 {error.returncode}。请查看上方输出。")
    except (ValueError, KeyError, OSError) as error:
        raise SystemExit(str(error))
