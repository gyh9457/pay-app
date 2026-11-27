# 05 验证首版完整流程

Status: done
Blocked by: 04

用 iPhone 15 / iOS 17.5 模拟器从干净状态走通离线记账、分类改名、账单展开、历史汇总录入与重启读取。以可复跑的测试和操作记录交给 Codex 验收，修复发现的范围内问题。

- [x] 记录实际验证环境、命令、用例和结果。
- [x] 单独记下确实没有执行的录屏比对与真机确认项。

## 验证记录

- 用户确认已完成验证，同意将本票标记为完成。

CodeBuddy 在 Xcode 15.4、iPhone 15 / iOS 17.5 模拟器上使用隔离的示例账本、分类与历史数据。宿主联网时，116 项单元测试和两批 UI 测试（14 项、13 项）全部通过，模拟器 Release 构建通过。该结果记录的是首版集成验证，后续改动的结果分别见 [06](06-recorded-categories.md) 和 [07](07-edit-delete-expenses.md)。

- UI 覆盖保存和重启、金额输入、滚轮联动、分类维护、周月年账单展开、历史汇总和启用日校验。启用日示例与跨时区核对见 [04](04-opening-history.md)。
- CodeBuddy 另外在限制 IP 网络且保留本机 IPC 的沙箱下运行两项 UI 烟测，保存后重启读回及周月年账单展开均通过。网络限制由沙箱内连接探测确认，宿主仍联网。真机飞行模式待验。
- 记录已补齐并交 Codex 审查。两批 UI 选择器来自原测试结果包，互不重复。

## 复跑命令

在项目根目录运行。以下命令按原记录重建首版集成验证批次，结果包写入新建的临时目录。

```sh
ledger_verify_dir="$(mktemp -d)"

xcodebuild build-for-testing \
  -project PayLedger.xcodeproj -scheme PayLedger -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.5' \
  -derivedDataPath "$ledger_verify_dir/build"

xcodebuild test-without-building \
  -project PayLedger.xcodeproj -scheme PayLedger -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.5' \
  -derivedDataPath "$ledger_verify_dir/build" -parallel-testing-enabled NO \
  -only-testing:PayLedgerTests -resultBundlePath "$ledger_verify_dir/unit.xcresult"

xcodebuild test-without-building \
  -project PayLedger.xcodeproj -scheme PayLedger -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.5' \
  -derivedDataPath "$ledger_verify_dir/build" -parallel-testing-enabled NO \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testAddingFirstSubcategoryToSelectedPrimarySelectsItAndKeepsValidChoice \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testAmountEnteredStartingAtSeparatorSavesAndPersists \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testBillEntriesNavigateAndExpandWithExampleAmounts \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testCategoryWheelCollapsesOnDoneAndKeepsAmountAndSelection \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testCleanupPendingKeepsAccountingOpenAndClearsOnRestart \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testCommaDecimalAmountSavesAndPersists \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testExampleExpenseIsVisibleAfterSaveAndAfterRelaunch \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testExpenseAfterMidnightFallsIntoCorrectIntervals \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testHistoryCountsInMonthAndYearOnlyWithExampleAmounts \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testHistoryCutoffValidationAndBackfillWithExampleAmounts \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testOutOfRangeTotalIsShownExplicitlyAndPersists \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testPrimaryWithoutSubcategoryShowsPlaceholderAndSaves \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testRecoveryNeededPausesAccountingUntilReopen \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testTwoLevelWheelSelectionAndCategoryRenamePersist \
  -resultBundlePath "$ledger_verify_dir/ui-1.xcresult"

xcodebuild test-without-building \
  -project PayLedger.xcodeproj -scheme PayLedger -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.5' \
  -derivedDataPath "$ledger_verify_dir/build" -parallel-testing-enabled NO \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testClearingBackfilledCutoffRequiresValidDateWithExampleAmounts \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testConsumptionDayStableAcrossTimeZoneRestarts \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testCoveredPerRecordIsExcludedAndWarnedBeforeSavingWithExampleAmounts \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testCoveredPreviewFieldMatchingRejectsLookalikeValues \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testCoveredWarningSitsInsideOpeningFormAndFollowsCutoffWithExampleAmounts \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testHistoryValidationErrorsStayBesideSaveActionsWithManyRows \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testOpeningSavePausedUntilLedgerRecoversWithExampleAmounts \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testSemanticallyInvalidHistoryShowsUnavailableButPerRecordQueriesStillWork \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testUnavailableHistoryOnlyAffectsIntervalsBeforeDecember2026 \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testUnreadableHistoryShowsUnavailableButPerRecordQueriesStillWork \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testYearBillHistoryOnlyMonthShowsNoMisleadingEmptyState \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testYearBillSwitchesToHistoryYearWhileHomeStaysOnCurrentYear \
  -only-testing:PayLedgerUITests/PayLedgerUITests/testZeroHistoryAmountsSaveAndSurviveRestartWithExampleAmounts \
  -resultBundlePath "$ledger_verify_dir/ui-2.xcresult"

xcodebuild build -project PayLedger.xcodeproj -scheme PayLedger -configuration Release \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$ledger_verify_dir/release"

git diff --check
```

## 待验

- 用户已删除原始录屏。录屏回看未完成的部分包括点按顺序、双列滚轮联动手感、保存返回位置、账单原页展开动画及历史汇总呈现。分类名单和顺序已有 [06 的转录与核对记录](06-recorded-categories.md)。
- iOS 26.6 真机验收暂缓。待确认交互手感、地区小数键盘、自然跨午夜及跨时区、飞行模式和备份排除属性。
