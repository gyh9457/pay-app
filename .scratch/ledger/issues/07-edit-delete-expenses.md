# 07 修改与删除逐笔流水

Status: done
Blocked by: 06 (done)
Agent: Codex

用户要求支持修改和删除已记流水。首页和周、月、年账单的逐笔行点按可进入预填表单，修改金额、分类或日期。左滑可选「修改」或「删除」，确认后移除所选流水。表单取消和删除取消都保留原记录。历史汇总继续由「历史」界面管理。

修改及删除共用新增流水的原子写入路径，保存成功后更新内存。保留流水标识，日期未改时保留原消费日；日期改变时按新消费日重新统计。旧账本副本待清理时先暂停修改和删除，避免下次打开时旧记录从副本被重新并入。

验收使用 iOS 17.5 模拟器和隔离示例账本。覆盖修改、删除确认及取消、重启，以及示例在启用日两侧的归属。

## 验证

Xcode 15.4、iPhone 15 / iOS 17.5 模拟器。运行命令如下，复跑时改用新的结果包路径。

```sh
ledger_verify_dir="$(mktemp -d)"

xcodebuild test -project PayLedger.xcodeproj -scheme PayLedger -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.5' \
  -derivedDataPath "$ledger_verify_dir/build" -resultBundlePath "$ledger_verify_dir/tests.xcresult" \
  -parallel-testing-enabled NO -only-testing:PayLedgerTests \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testBillEntriesNavigateAndExpandWithExampleAmounts \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testCategoryWheelCollapsesOnDoneAndKeepsAmountAndSelection \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testEditFromHomeAndDeleteFromWeekBillPersistAfterRelaunch -quiet
```

119 项单元测试通过。账单展开和分类滚轮两项界面回归通过。新增界面用例在删除后按金额重新定位流水，因为原先按位置取得的测试元素会指向列表中的下一条记录。以相同命令仅选择该用例并使用新的结果包路径，复跑通过。验证了修改金额、取消删除、确认删除及重启读回。iOS 26.6 真机验收暂缓。
