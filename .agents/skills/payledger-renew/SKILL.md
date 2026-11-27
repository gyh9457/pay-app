---
name: payledger-renew
description: 检查或续期本项目「随手记」已安装版本的 Apple Personal Team 免费签名，在原 iPhone 上覆盖安装，支持已配对设备通过同一 Wi‑Fi 连接。用户说给随手记续签、签名到期、无线续签或调用 $payledger-renew 时使用。
---

# 随手记个人签名续期

从项目根目录运行。可用 USB，或让已配对的 iPhone 和 Mac 接入同一个支持 IPv6 的局域网。确认设备已解锁，开发者模式已开启，Xcode 已登录原来的 Personal Team。

```sh
python3 .agents/skills/payledger-renew/scripts/renew.py check
python3 .agents/skills/payledger-renew/scripts/renew.py renew
```

`check` 只读取上次安装包的签名有效期和目标手机的连接状态。用户要求续签和覆盖安装时运行 `renew`。它从 `dist/PayLedger-iPhone.ipa` 读取原应用的签名团队和设备，在当前工程用 Xcode 自动签名生成 Release，核对新的描述文件是否延长有效期，再覆盖安装并尝试启动。安装成功后本地 IPA 更新为新包。显示的有效期使用 Mac 本地时间。

- 应用标识固定为 `com.guoyanhao.payledger`。旧账保存在手机的应用容器内。续签使用原 Personal Team、原应用标识和原手机。保留已安装的 App，包括签名已经到期时。应用标识不匹配、设备有歧义或应用缺失时先核对。
- 如果本地 IPA 不在默认路径，用 `--ipa 路径` 指向上次签名的包。如果手上没有该包，从 Xcode 的 Apple Accounts / Signing & Capabilities 核实原 Team ID，再从 Device Hub 核实原 iPhone 的 UDID。两项都确认后传入 `--team TEAM_ID --device UDID`。这些标识只在本机使用。
- 无线连接不可用时，先让两台设备接入同一局域网、解锁 iPhone，再查 Device Hub。仍不可用时用数据线。需要登录、信任、开启开发者模式或解锁钥匙串时，由用户在对应设备上确认。
- Xcode 仍沿用未到期的描述文件时，脚本报告原到期时间。本轮覆盖安装没有续期收益，可以在到期后重试。保留已有证书和描述文件。
- 若安装成功但首次启动报开发者不受信任，请用户在 iPhone 的「设置 → 通用 → VPN 与设备管理」信任自己的开发者账号。随后重新检查启动，无需再安装。
