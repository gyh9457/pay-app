# 06 按录屏补齐内置支出分类

Status: done
Blocked by: 02 (done)
Agent: Codex

用户确认以当时录屏中的两级支出分类名称、归属和滚轮顺序为准。Codex 对照约 00:12–01:17 的画面，按左列从上到下、右列在各大类内从上到下转录。录屏中的「最近使用」是快捷入口，「添加分类」是操作入口。

| 大类 | 子类（滚轮顺序） |
| --- | --- |
| 食品酒水 | 早午晚餐、烟酒茶、水果零食 |
| 居家物业 | 日常用品、水电煤气、房租、物业管理、维修保养 |
| 衣服饰品 | 衣服裤子、鞋帽包包、化妆饰品 |
| 行车交通 | 公共交通、打车租车、私家车费用、油费、高速、车内用品、停车费、车贷、罚款、洗车 |
| 交流通讯 | 座机费、手机费、上网费、邮寄费 |
| 休闲娱乐 | 运动健身、腐败聚会、休闲玩乐、宠物宝贝、旅游度假 |
| 学习进修 | 数码装备、书报杂志、培训进修 |
| 人情往来 | 送礼请客、孝敬家长、还人钱物、慈善捐助、婚礼 |
| 医疗保健 | 药品费、保健费、美容费、治疗费 |
| 金融保险 | 银行手续、投资亏损、按揭还款、消费税收、利息支出、赔偿罚款 |
| 其他杂项 | 其他支出、意外丢失、烂账损失 |

## 验收

- 首次启动时，两列按表中顺序提供 11 个大类、51 个子类，管理页读取同一套分类。切换到「行车交通」后默认选择「公共交通」，保存后首页和账单显示选择结果。
- 保留 `food`、`food-meal`、`food-snack`、`transport`、`transport-bus`、`transport-taxi` 的标识。旧示例名称「零食饮料／交通／公交地铁／打车」依次更新为「水果零食／行车交通／公共交通／打车租车」。已保存分类文件也补齐内置项目，按旧默认名判断是否由用户改名，保留自定义名称、分类及标识。自定义项排在其对应内置项之后，保持原相对顺序。迁移可重复加载，保留现有读取和写入失败保护。
- 更新受默认分类变化影响的断言，添加旧分类文件兼容的回归覆盖。在 iPhone 15 / iOS 17.5 上跑相关单元测试与覆盖切换、保存、重启及账单显示的现有 UI 用例。只用示例金额。iOS 26.6 真机验收暂缓。
- 修改范围限于分类模型、分类存储载入与相关测试，以及本任务的验证记录。分类转录已经保留在本票，用户已删除原始录屏。

## 验证

Xcode 15.4 / iPhone 15 / iOS 17.5 模拟器，使用隔离示例账本。对照表与代码中的 11 个大类和 51 个子类已逐项核对名称、归属和顺序。

```sh
ledger_verify_dir="$(mktemp -d)"

xcodebuild test -project PayLedger.xcodeproj -scheme PayLedger -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.5' \
  -derivedDataPath "$ledger_verify_dir/build" -resultBundlePath "$ledger_verify_dir/tests.xcresult" \
  -parallel-testing-enabled NO -only-testing:PayLedgerTests \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testCategoryWheelCollapsesOnDoneAndKeepsAmountAndSelection \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testTwoLevelWheelSelectionAndCategoryRenamePersist \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testPrimaryWithoutSubcategoryShowsPlaceholderAndSaves \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testAddingFirstSubcategoryToSelectedPrimarySelectsItAndKeepsValidChoice \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testBillEntriesNavigateAndExpandWithExampleAmounts -quiet
```

首轮通过 117 项单元测试和 4 项界面测试。改名用例因分类列表变长、目标行未滚入视野而失败。在用例中补上滚动操作后，以同一命令仅选择 `testTwoLevelWheelSelectionAndCategoryRenamePersist` 复跑通过。合计 117 项单元测试和 5 项界面用例验证通过。iOS 26.6 真机验收暂缓。
