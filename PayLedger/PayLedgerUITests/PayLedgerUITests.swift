import XCTest

/// Drives the real entry screen on the simulator with example amounts only.
/// Real accounts stay on the user's iPhone. Each run gets an isolated example
/// ledger inside the app's own temp directory via PAYLEDGER_TEST_LEDGER; the
/// production ledger path is never reset or touched.
final class PayLedgerUITests: XCTestCase {
    private let exampleAmount = "87.65"

    func testExampleExpenseIsVisibleAfterSaveAndAfterRelaunch() {
        let ledger = "uitest-\(UUID().uuidString).json"
        let app = XCUIApplication()
        app.launchEnvironment = ["PAYLEDGER_TEST_LEDGER": ledger]
        app.launch()

        save(exampleAmount, in: app)
        assertPersistedRow(category: "食品酒水", amount: exampleAmount, in: app)
        assertSummaries(show: exampleAmount, in: app)

        // Relaunch WITHOUT any reset: the same isolated ledger must persist.
        app.terminate()
        app.launchEnvironment = ["PAYLEDGER_TEST_LEDGER": ledger]
        app.launch()
        assertPersistedRow(category: "食品酒水", amount: exampleAmount, in: app)
        assertSummaries(show: exampleAmount, in: app)
    }

    func testEditFromHomeAndDeleteFromWeekBillPersistAfterRelaunch() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["PAYLEDGER_TEST_LEDGER": "uitest-\(UUID().uuidString).json"]
        app.launch()
        save("12.34", in: app)
        save("5.00", in: app)
        let original = try XCTUnwrap(app.cells.allElementsBoundByIndex.first {
            $0.staticTexts["早午晚餐"].exists && $0.staticTexts["12.34"].exists
        })
        original.tap()
        XCTAssertTrue(app.navigationBars["修改流水"].waitForExistence(timeout: 5))
        let amount = app.textFields["0.00"]
        XCTAssertEqual(amount.value as? String, "12.34")
        amount.tap()
        amount.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5) + "23.45")
        app.buttons["保存"].tap()
        assertPersistedRow(category: "早午晚餐", amount: "23.45", in: app)
        assertSummaries(show: "28.45", in: app)

        openBill("本周", in: app)
        tapCell(with: "食品酒水", in: app)
        let edited = try XCTUnwrap(app.cells.allElementsBoundByIndex.first {
            $0.staticTexts["早午晚餐"].exists && $0.staticTexts["23.45"].exists
        })
        edited.swipeLeft()
        app.buttons["删除"].tap()
        let confirmation = app.alerts["删除这笔流水？"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["取消"].tap()
        assertPersistedRow(category: "早午晚餐", amount: "23.45", in: app)

        edited.swipeLeft()
        app.buttons["删除"].tap()
        confirmation.buttons["删除"].tap()
        XCTAssertTrue(app.navigationBars["周账单"].exists)
        assertBillTotal("5.00", in: app)
        assertPersistedRow(category: "早午晚餐", amount: "5.00", in: app)
        XCTAssertEqual(countCells(containing: "23.45", in: app), 0)

        app.terminate()
        app.launch()
        assertPersistedRow(category: "早午晚餐", amount: "5.00", in: app)
        assertSummaries(show: "5.00", in: app)
        XCTAssertFalse(app.staticTexts["23.45"].exists)
    }

    /// Rerunnable cross-midnight check: the pinned clock is advanced on the
    /// SAME open home screen (no terminate/relaunch, so a reference date fixed
    /// at view initialization would be caught). The new expense lands in the
    /// right day/week/month interval while the previous day's row stays intact.
    func testExpenseAfterMidnightFallsIntoCorrectIntervals() {
        let ledger = "uitest-\(UUID().uuidString).json"
        let app = XCUIApplication()
        app.launchEnvironment = [
            "PAYLEDGER_TEST_LEDGER": ledger,
            "PAYLEDGER_TEST_NOW": "2026-11-17T10:00:00" // Tuesday
        ]
        app.launch()
        save(exampleAmount, in: app)
        assertPersistedRow(category: "食品酒水", amount: exampleAmount, in: app)
        assertSummaries(show: exampleAmount, in: app)

        // Advance the clock in the running app, on the already-open home view.
        let advanceClock = app.buttons["测试：推进一天"]
        XCTAssertTrue(advanceClock.waitForExistence(timeout: 5))
        advanceClock.tap()

        save("12.34", in: app)
        assertPersistedRow(category: "食品酒水", amount: "12.34", in: app)
        assertSummary("今天", is: "12.34", not: exampleAmount, in: app)
        assertSummary("本周", is: "99.99", in: app) // 87.65 + 12.34
        assertSummary("本月", is: "99.99", in: app)

        // Independent restart reads both rows back from the same isolated ledger.
        app.terminate()
        app.launchEnvironment = [
            "PAYLEDGER_TEST_LEDGER": ledger,
            "PAYLEDGER_TEST_NOW": "2026-11-18T10:00:00"
        ]
        app.launch()
        assertPersistedRow(category: "食品酒水", amount: exampleAmount, in: app)
        assertPersistedRow(category: "食品酒水", amount: "12.34", in: app)
        assertSummary("本周", is: "99.99", in: app)
    }

    /// An overflowing total must be reported explicitly rather than showing a
    /// capped number that looks like a real summary. Both individual example
    /// amounts remain visible and readable after restart.
    func testOutOfRangeTotalIsShownExplicitlyAndPersists() {
        let ledger = "uitest-\(UUID().uuidString).json"
        let app = XCUIApplication()
        app.launchEnvironment = ["PAYLEDGER_TEST_LEDGER": ledger]
        app.launch()

        // 92233720368547758.07 + 0.01 exceeds Int cents and cannot be summed.
        save("92233720368547758.07", in: app)
        save("0.01", in: app)
        for label in ["今天", "本周", "本月"] {
            assertSummary(label, is: "金额超出汇总范围", in: app)
        }
        assertPersistedRow(category: "食品酒水", amount: "92233720368547758.07", in: app)
        assertPersistedRow(category: "食品酒水", amount: "0.01", in: app)

        app.terminate()
        app.launchEnvironment = ["PAYLEDGER_TEST_LEDGER": ledger]
        app.launch()
        assertPersistedRow(category: "食品酒水", amount: "92233720368547758.07", in: app)
        assertPersistedRow(category: "食品酒水", amount: "0.01", in: app)
        assertSummary("今天", is: "金额超出汇总范围", in: app)
    }

    /// Recovery-needed branch: an unreadable example ledger pauses accounting,
    /// shows the persistent banner, disables every entry, and never shows a
    /// zero/empty ledger. Reopening with valid bytes clears the state.
    func testRecoveryNeededPausesAccountingUntilReopen() {
        let ledger = "uitest-\(UUID().uuidString).json"
        let app = XCUIApplication()
        app.launchEnvironment = [
            "PAYLEDGER_TEST_LEDGER": ledger,
            "PAYLEDGER_TEST_STATE": "unreadable"
        ]
        app.launch()

        let banner = "账本暂需恢复，记账已暂停。请重新打开应用重试。"
        XCTAssertTrue(app.staticTexts[banner].waitForExistence(timeout: 5))
        let entry = app.buttons["记一笔"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertFalse(entry.isEnabled, "记一笔 must be disabled while accounting is paused")

        let todayRow = app.cells.allElementsBoundByIndex.first { $0.staticTexts["今天"].exists }
        XCTAssertNotNil(todayRow)
        let values = todayRow?.staticTexts.allElementsBoundByIndex.map(\.label) ?? []
        XCTAssertTrue(values.contains("账本暂需恢复"))
        XCTAssertFalse(values.contains("0.00"), "an unconfirmed ledger must not show a zero total")

        app.terminate()
        app.launchEnvironment = [
            "PAYLEDGER_TEST_LEDGER": ledger,
            "PAYLEDGER_TEST_STATE": "recovered"
        ]
        app.launch()
        XCTAssertFalse(app.staticTexts[banner].exists, "recovery clears after reopen")
        let reopenedEntry = app.buttons["记一笔"]
        XCTAssertTrue(reopenedEntry.waitForExistence(timeout: 5))
        XCTAssertTrue(reopenedEntry.isEnabled)
    }

    /// Cleanup-only branch: a protected legacy copy awaiting deletion keeps
    /// accounting open; appending a record and restarting in another time zone
    /// must read the original and the appended record back exactly once each.
    func testCleanupPendingKeepsAccountingOpenAndClearsOnRestart() {
        let ledger = "uitest-\(UUID().uuidString).json"
        let app = XCUIApplication()
        app.launchEnvironment = [
            "PAYLEDGER_TEST_LEDGER": ledger,
            "PAYLEDGER_TEST_STATE": "cleanupPending",
            "PAYLEDGER_TEST_TZ": "Asia/Shanghai",
            "PAYLEDGER_TEST_NOW": "2026-11-20T10:00:00"
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["旧账本副本待清理"].waitForExistence(timeout: 5))
        let entry = app.buttons["记一笔"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertTrue(entry.isEnabled, "cleanup-only state must keep accounting open")

        save(exampleAmount, in: app)
        assertPersistedRow(category: "食品酒水", amount: exampleAmount, in: app)

        app.terminate()
        app.launchEnvironment = [
            "PAYLEDGER_TEST_LEDGER": ledger,
            "PAYLEDGER_TEST_STATE": "cleanupPendingRecover",
            "PAYLEDGER_TEST_TZ": "UTC",
            "PAYLEDGER_TEST_NOW": "2026-11-20T10:00:00"
        ]
        app.launch()
        XCTAssertFalse(app.staticTexts["旧账本副本待清理"].exists, "banner clears after cleanup retry")

        // The retained legacy copy must not re-import the original record.
        XCTAssertEqual(countCells(containing: "12.34", in: app), 1, "原笔只读到一次")
        XCTAssertEqual(countCells(containing: exampleAmount, in: app), 1, "追加笔只读到一次")
        for label in ["今天", "本周", "本月", "本年"] {
            assertSummary(label, is: "99.99", in: app)
        }

        openBill("本周", in: app)
        XCTAssertTrue(app.navigationBars["周账单"].waitForExistence(timeout: 5))
        assertBillTotal("99.99", in: app)
        assertWeekCategorySubtotal("食品酒水", is: "99.99", in: app)
        tapCell(with: "食品酒水", in: app)
        assertPerRecordRowShowsDate("2026-11-20", amount: "12.34", in: app)
        assertPerRecordRowShowsDate("2026-11-20", amount: exampleAmount, in: app)
        goHome(in: app)

        openBill("本月", in: app)
        XCTAssertTrue(app.navigationBars["月账单"].waitForExistence(timeout: 5))
        assertBillTotal("99.99", in: app)
        goHome(in: app)

        openBill("本年", in: app)
        XCTAssertTrue(app.navigationBars["年账单"].waitForExistence(timeout: 5))
        assertBillTotal("99.99", in: app)
    }

    /// A native decimal pad lets the user begin at the separator. Saving ".05"
    /// from the form must show 0.05 on the home screen and read back as a single
    /// row after restart. A decimal-comma locale's "12,34" must become 12.34.
    func testAmountEnteredStartingAtSeparatorSavesAndPersists() {
        let pointLedger = "uitest-\(UUID().uuidString).json"
        let app = XCUIApplication()
        app.launchEnvironment = ["PAYLEDGER_TEST_LEDGER": pointLedger]
        app.launch()

        save(".05", in: app)
        assertPersistedRow(category: "食品酒水", amount: "0.05", in: app)
        assertSummaries(show: "0.05", in: app)

        app.terminate()
        app.launchEnvironment = ["PAYLEDGER_TEST_LEDGER": pointLedger]
        app.launch()
        assertPersistedRow(category: "食品酒水", amount: "0.05", in: app)
        assertSummaries(show: "0.05", in: app)
    }

    func testCommaDecimalAmountSavesAndPersists() {
        let ledger = "uitest-\(UUID().uuidString).json"
        let app = XCUIApplication()
        app.launchEnvironment = ["PAYLEDGER_TEST_LEDGER": ledger]
        app.launch()

        save("12,34", in: app)
        assertPersistedRow(category: "食品酒水", amount: "12.34", in: app)
        assertSummaries(show: "12.34", in: app)

        app.terminate()
        app.launchEnvironment = ["PAYLEDGER_TEST_LEDGER": ledger]
        app.launch()
        assertPersistedRow(category: "食品酒水", amount: "12.34", in: app)
        assertSummaries(show: "12.34", in: app)
    }

    /// 规格 1：点「分类」从底部展开双列滚轮，选择时表单同步，切换大类时
    /// 右列切到对应首个子类；点「完成」收起后金额和所选分类都保留，保存
    /// 回首页显示正确的逐笔金额与分类。
    func testCategoryWheelCollapsesOnDoneAndKeepsAmountAndSelection() {
        let ledger = "uitest-\(UUID().uuidString).json"
        let app = XCUIApplication()
        app.launchEnvironment = ["PAYLEDGER_TEST_LEDGER": ledger]
        app.launch()

        app.buttons["记一笔"].tap()
        let amountField = app.textFields["0.00"]
        XCTAssertTrue(amountField.waitForExistence(timeout: 5))
        amountField.tap()
        amountField.typeText("31.20")

        XCTAssertFalse(app.pickers["primaryCategoryPicker"].exists, "滚轮初始应收起")
        XCTAssertFalse(app.pickers["subcategoryPicker"].exists, "子类滚轮初始应收起")
        app.buttons["chooseCategory"].tap()

        let primaryWheel = app.pickers["primaryCategoryPicker"]
        let subWheel = app.pickers["subcategoryPicker"]
        XCTAssertTrue(primaryWheel.waitForExistence(timeout: 5), "点分类后应展开一级滚轮")
        XCTAssertTrue(subWheel.waitForExistence(timeout: 5), "点分类后应展开子类滚轮")
        XCTAssertTrue(app.staticTexts["食品酒水 · 早午晚餐"].waitForExistence(timeout: 5),
                      "默认选择应在表单同步显示")

        subWheel.pickerWheels.element.adjust(toPickerWheelValue: "水果零食")
        XCTAssertTrue(app.staticTexts["食品酒水 · 水果零食"].waitForExistence(timeout: 5),
                      "选子类后表单应同步显示")
        primaryWheel.pickerWheels.element.adjust(toPickerWheelValue: "行车交通")
        XCTAssertTrue(app.staticTexts["行车交通 · 公共交通"].waitForExistence(timeout: 5),
                      "切换大类后右列应切到对应首个子类")

        app.buttons["doneCategoryWheel"].tap()
        XCTAssertFalse(app.pickers["primaryCategoryPicker"].exists, "完成后滚轮应收起")
        XCTAssertTrue(app.staticTexts["行车交通 · 公共交通"].exists, "收起后保留所选分类")
        XCTAssertEqual(amountField.value as? String, "31.20", "收起后保留已输入金额")

        app.buttons["保存"].tap()
        assertPersistedRow(category: "行车交通", amount: "31.20", in: app)
        assertPersistedRow(category: "公共交通", amount: "31.20", in: app)
    }

    /// The two-column wheel selects a primary and a subcategory; changing the
    /// primary refreshes the subcategory column. A rename keeps historical
    /// rows and their amounts, and both survive a restart.
    func testTwoLevelWheelSelectionAndCategoryRenamePersist() {
        let ledger = "uitest-\(UUID().uuidString).json"
        let app = XCUIApplication()
        app.launchEnvironment = ["PAYLEDGER_TEST_LEDGER": ledger]
        app.launch()

        app.buttons["记一笔"].tap()
        let choose = app.buttons["chooseCategory"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        XCTAssertFalse(app.pickers["primaryCategoryPicker"].exists, "滚轮初始应收起")
        choose.tap()

        let primaryWheel = app.pickers["primaryCategoryPicker"]
        let subWheel = app.pickers["subcategoryPicker"]
        XCTAssertTrue(primaryWheel.waitForExistence(timeout: 5), "缺少一级分类滚轮")
        XCTAssertTrue(subWheel.waitForExistence(timeout: 5), "缺少子类滚轮")

        // Selecting a subcategory updates the synced label immediately.
        subWheel.pickerWheels.element.adjust(toPickerWheelValue: "水果零食")
        XCTAssertTrue(app.staticTexts["食品酒水 · 水果零食"].waitForExistence(timeout: 5),
                      "选择子类后表单应同步显示食品酒水 · 水果零食")

        // Changing the primary refreshes the subcategory column to that
        // primary's children and resets the synced label.
        primaryWheel.pickerWheels.element.adjust(toPickerWheelValue: "行车交通")
        XCTAssertTrue(app.staticTexts["行车交通 · 公共交通"].waitForExistence(timeout: 5),
                      "切换大类后子类应刷新为行车交通的子类")
        app.buttons["doneCategoryWheel"].tap()
        XCTAssertFalse(app.pickers["primaryCategoryPicker"].exists, "点完成后应回到收起状态")

        // The form is already open; enter the amount and save from here.
        let amountField = app.textFields["0.00"]
        XCTAssertTrue(amountField.waitForExistence(timeout: 5))
        amountField.tap()
        amountField.typeText("23.45")
        app.buttons["保存"].tap()
        assertPersistedRow(category: "行车交通", amount: "23.45", in: app)
        assertPersistedRow(category: "公共交通", amount: "23.45", in: app)

        // Rename the primary from the management screen. The historical row
        // keeps its amount and shows the new name, before and after restart.
        app.buttons["分类"].tap()
        let rename = app.buttons["renamePrimary-transport"]
        for _ in 0..<12 {
            if rename.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(rename.isHittable)
        rename.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5), "改名应弹出输入框")
        let field = app.alerts.firstMatch.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("出行")
        app.buttons["保存"].tap()
        app.buttons["完成"].tap()
        assertPersistedRow(category: "出行", amount: "23.45", in: app)
        assertPersistedRow(category: "公共交通", amount: "23.45", in: app)

        app.terminate()
        app.launchEnvironment = ["PAYLEDGER_TEST_LEDGER": ledger]
        app.launch()
        assertPersistedRow(category: "出行", amount: "23.45", in: app)
    }

    /// 规格 2：没有子类的大类在右列显示「无子类」，表单同步只显示大类，
    /// 保存按该大类入账且不写子类标识。全程示例金额与示例分类。
    func testPrimaryWithoutSubcategoryShowsPlaceholderAndSaves() {
        let ledger = "uitest-\(UUID().uuidString).json"
        let app = XCUIApplication()
        app.launchEnvironment = ["PAYLEDGER_TEST_LEDGER": ledger]
        app.launch()

        // 从首页「分类」新增一个没有子类的大类。
        app.buttons["分类"].tap()
        scrollToAddPrimary(in: app).tap()
        let nameField = app.alerts.firstMatch.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("购物")
        app.buttons["保存"].tap()
        app.buttons["完成"].tap()

        app.buttons["记一笔"].tap()
        let amountField = app.textFields["0.00"]
        XCTAssertTrue(amountField.waitForExistence(timeout: 5))
        amountField.tap()
        amountField.typeText("12.34")

        app.buttons["chooseCategory"].tap()
        let primaryWheel = app.pickers["primaryCategoryPicker"]
        let subWheel = app.pickers["subcategoryPicker"]
        XCTAssertTrue(primaryWheel.waitForExistence(timeout: 5))
        XCTAssertTrue(subWheel.waitForExistence(timeout: 5))
        primaryWheel.pickerWheels.element.adjust(toPickerWheelValue: "购物")
        XCTAssertEqual(subWheel.pickerWheels.element.value as? String, "无子类",
                       "无子类的大类右列应显示「无子类」")
        XCTAssertEqual(app.staticTexts["categorySelection"].label, "购物",
                       "表单应同步显示所选大类（无子类时不拼接子类）")

        app.buttons["doneCategoryWheel"].tap()
        XCTAssertEqual(amountField.value as? String, "12.34", "收起后保留金额")
        app.buttons["保存"].tap()
        assertPersistedRow(category: "购物", amount: "12.34", in: app)
        assertSummaries(show: "12.34", in: app)
    }

    /// 规格 2：给当前选中的大类新增第一个子类后，回到表单应自动选中该子类；
    /// 再新增其他子类时，仍然有效的原选择应保留。保存写入所选子类标识。
    func testAddingFirstSubcategoryToSelectedPrimarySelectsItAndKeepsValidChoice() {
        let ledger = "uitest-\(UUID().uuidString).json"
        let app = XCUIApplication()
        app.launchEnvironment = ["PAYLEDGER_TEST_LEDGER": ledger]
        app.launch()

        app.buttons["分类"].tap()
        scrollToAddPrimary(in: app).tap()
        let nameField = app.alerts.firstMatch.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("购物")
        app.buttons["保存"].tap()
        app.buttons["完成"].tap()

        app.buttons["记一笔"].tap()
        let amountField = app.textFields["0.00"]
        XCTAssertTrue(amountField.waitForExistence(timeout: 5))
        amountField.tap()
        amountField.typeText("23.45")
        app.buttons["chooseCategory"].tap()
        let primaryWheel = app.pickers["primaryCategoryPicker"]
        XCTAssertTrue(primaryWheel.waitForExistence(timeout: 5))
        primaryWheel.pickerWheels.element.adjust(toPickerWheelValue: "购物")
        XCTAssertEqual(app.staticTexts["categorySelection"].label, "购物")
        app.buttons["doneCategoryWheel"].tap()

        // 在已打开的表单里给当前大类新增第一个子类。购物是最后一段，
        // 取其「新增子类」按钮。
        app.buttons["管理分类"].tap()
        tapAddSubcategoryForLastGroup(in: app)
        var field = app.alerts.firstMatch.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("日用品")
        app.alerts.firstMatch.buttons["保存"].tap()
        app.buttons["完成"].tap()
        XCTAssertEqual(app.staticTexts["categorySelection"].label, "购物 · 日用品",
                       "新增首个子类后回表单应选中该子类")

        // 再次新增子类，仍有效的「日用品」选择不应被重置。
        app.buttons["管理分类"].tap()
        tapAddSubcategoryForLastGroup(in: app)
        field = app.alerts.firstMatch.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("服饰")
        app.alerts.firstMatch.buttons["保存"].tap()
        app.buttons["完成"].tap()
        XCTAssertEqual(app.staticTexts["categorySelection"].label, "购物 · 日用品",
                       "仍有效的子类选择应保留，不被最新新增的子类覆盖")

        app.buttons["保存"].tap()
        assertPersistedRow(category: "购物", amount: "23.45", in: app)
        assertPersistedRow(category: "日用品", amount: "23.45", in: app)
        let row = app.cells.allElementsBoundByIndex.first { cell in
            cell.staticTexts["购物"].exists && cell.staticTexts["23.45"].exists
        }
        XCTAssertNotNil(row)
        XCTAssertFalse(row?.staticTexts["服饰"].exists ?? true,
                       "逐笔行应写入当时选中的子类，而非后来新增的子类")
    }

    private func scrollToAddPrimary(in app: XCUIApplication) -> XCUIElement {
        let addPrimary = app.buttons["addPrimary"]
        for _ in 0..<20 {
            if addPrimary.isHittable { break }
            app.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(addPrimary.isHittable)
        return addPrimary
    }

    private func tapAddSubcategoryForLastGroup(in app: XCUIApplication) {
        _ = scrollToAddPrimary(in: app)
        let addSubcategory = app.buttons.matching(identifier: "新增子类")
            .allElementsBoundByIndex.last(where: \.isHittable)
        XCTAssertNotNil(addSubcategory)
        addSubcategory?.tap()
    }

    /// 账单入口与展开：从首页进入周/月/年账单，用示例金额核对小计、逐笔明细
    /// 与多个月份各自独立展开。全程示例账目，真实账本留在用户设备。
    func testBillEntriesNavigateAndExpandWithExampleAmounts() {
        let ledger = "uitest-\(UUID().uuidString).json"
        let app = XCUIApplication()
        app.launchEnvironment = [
            "PAYLEDGER_TEST_LEDGER": ledger,
            "PAYLEDGER_TEST_NOW": "2026-11-18T10:00:00" // Wednesday
        ]
        app.launch()

        // 首页风景图随应用打包、离线可用；截图留证核对浅色列表、绿色金额与橙色入口。
        XCTAssertTrue(app.otherElements["landscapeHeader"].waitForExistence(timeout: 5))
        let homeShot = XCTAttachment(screenshot: app.screenshot())
        homeShot.name = "home-landscape-and-summary"
        homeShot.lifetime = .keepAlways
        add(homeShot)

        save("12.34", in: app) // 食品酒水 · 早午晚餐
        // Second example amount in another primary category.
        app.buttons["记一笔"].tap()
        let amountField = app.textFields["0.00"]
        XCTAssertTrue(amountField.waitForExistence(timeout: 5))
        amountField.tap()
        amountField.typeText("87.65")
        app.buttons["chooseCategory"].tap()
        let primaryWheel = app.pickers["primaryCategoryPicker"]
        XCTAssertTrue(primaryWheel.waitForExistence(timeout: 5))
        primaryWheel.pickerWheels.element.adjust(toPickerWheelValue: "行车交通")
        app.buttons["doneCategoryWheel"].tap()
        app.buttons["保存"].tap()

        // 周账单：一级分类小计与展开后的逐笔明细。
        openBill("本周", in: app)
        XCTAssertTrue(app.navigationBars["周账单"].waitForExistence(timeout: 5))
        assertBillTotal("99.99", in: app)
        XCTAssertEqual(countCells(containing: "早午晚餐", in: app), 0, "展开前不显示逐笔明细")
        tapCell(with: "食品酒水", in: app)
        XCTAssertEqual(countCells(containing: "早午晚餐", in: app), 1)
        XCTAssertGreaterThanOrEqual(countCells(containing: "12.34", in: app), 1)
        goHome(in: app)

        // 月账单：进入时明细默认收起；点当月汇总行在原页展开/收起按日期明细。
        openBill("本月", in: app)
        XCTAssertTrue(app.navigationBars["月账单"].waitForExistence(timeout: 5))
        assertBillTotal("99.99", in: app)
        XCTAssertEqual(countCells(containing: "2026-11-18", in: app), 0, "进入月账单时日期明细应默认收起")
        tapCell(with: "2026年11月", in: app)
        XCTAssertTrue(cellExists(with: "2026-11-18", in: app))
        XCTAssertEqual(countCells(containing: "早午晚餐", in: app), 1)
        XCTAssertEqual(countCells(containing: "公共交通", in: app), 1)
        tapCell(with: "2026年11月", in: app)
        XCTAssertEqual(countCells(containing: "2026-11-18", in: app), 0, "再次点按月汇总行应收起明细")
        XCTAssertTrue(app.navigationBars["月账单"].exists, "展开收起仍停留在月账单页")
        goHome(in: app)

        // 年账单：单点月份即直接显示按日期分组的逐笔记录，各月独立展开/收起。
        openBill("本年", in: app)
        XCTAssertTrue(app.navigationBars["年账单"].waitForExistence(timeout: 5))
        assertBillTotal("99.99", in: app)
        tapCell(with: "1月", in: app)
        XCTAssertTrue(cellExists(with: "本月无记录", in: app))
        // SwiftUI List 按需加载：先滚到 11 月汇总行，再在点按前确认两笔示例明细均不可见，
        // 才能发现 11 月附近提前显示逐笔内容的回归。
        guard let november = findCell("11月", in: app, swipeUp: true) else {
            XCTFail("找不到 11 月"); return
        }
        XCTAssertEqual(countCells(containing: "早午晚餐", in: app), 0, "滚到 11 月后、点按前不应显示逐笔内容")
        XCTAssertEqual(countCells(containing: "公共交通", in: app), 0, "滚到 11 月后、点按前不应显示第二笔逐笔内容")
        november.tap()
        XCTAssertTrue(cellExists(with: "2026-11-18", in: app))
        // 逐行配对核对：子类与金额必须在同一行，金额互换也会失败。
        assertPersistedRow(category: "早午晚餐", amount: "12.34", in: app)
        assertPersistedRow(category: "公共交通", amount: "87.65", in: app)
        XCTAssertFalse(app.cells.allElementsBoundByIndex.contains {
            $0.staticTexts["早午晚餐"].exists && $0.staticTexts["87.65"].exists
        }, "同一逐笔行的子类与金额必须配对，不能跨行混用")
        XCTAssertEqual(countCells(containing: "早午晚餐", in: app), 1, "单点月份应直接显示逐笔子类行")
        XCTAssertEqual(countCells(containing: "公共交通", in: app), 1)
        guard let january = findCell("1月", in: app, swipeUp: false) else {
            XCTFail("找不到 1 月"); return
        }
        XCTAssertTrue(cellExists(with: "本月无记录", in: app), "展开其它月份不应收起已展开的 1 月")
        january.tap()
        XCTAssertEqual(countCells(containing: "本月无记录", in: app), 0, "再次点按应收起该月份")
        guard let novemberAgain = findCell("11月", in: app, swipeUp: true) else {
            XCTFail("找不到 11 月"); return
        }
        XCTAssertEqual(countCells(containing: "早午晚餐", in: app), 1, "收起其它月份不应影响已展开的 11 月")
        novemberAgain.tap()
        XCTAssertEqual(countCells(containing: "早午晚餐", in: app), 0, "收起 11 月应移除其逐笔明细")
        XCTAssertEqual(countCells(containing: "公共交通", in: app), 0, "收起 11 月应移除第二笔逐笔明细")
        XCTAssertEqual(countCells(containing: "2026-11-18", in: app), 0, "收起 11 月应移除其日期行")
        XCTAssertNotNil(findCell("合计", in: app, swipeUp: false))
        assertBillTotal("99.99", in: app)
        goHome(in: app)

        // 重启后账单仍由同一份示例账本计算。
        app.terminate()
        app.launchEnvironment = [
            "PAYLEDGER_TEST_LEDGER": ledger,
            "PAYLEDGER_TEST_NOW": "2026-11-18T10:00:00"
        ]
        app.launch()
        openBill("本周", in: app)
        XCTAssertTrue(app.navigationBars["周账单"].waitForExistence(timeout: 5))
        assertBillTotal("99.99", in: app)
    }

    /// Example history counts in month/year only. Week and per-record detail
    /// stay individual-expense-only, and the values survive a restart.
    func testHistoryCountsInMonthAndYearOnlyWithExampleAmounts() {
        let ledger = "uitest-\(UUID().uuidString).json"
        let app = XCUIApplication()
        app.launchEnvironment = [
            "PAYLEDGER_TEST_LEDGER": ledger,
            "PAYLEDGER_TEST_NOW": "2026-11-20T10:00:00"
        ]
        app.launch()

        enterHistory(monthAmount: "30.00", openingAmount: "50.00", in: app)
        save("12.34", in: app)

        assertSummary("今天", is: "12.34", in: app)
        assertSummary("本周", is: "12.34", in: app)
        assertSummary("本月", is: "62.34", in: app) // 期初 50.00 + 逐笔 12.34
        assertSummary("本年", is: "92.34", in: app) // 历史月 30.00 + 期初 50.00 + 逐笔 12.34

        openBill("本周", in: app)
        XCTAssertTrue(app.navigationBars["周账单"].waitForExistence(timeout: 5))
        assertBillTotal("12.34", in: app)
        goHome(in: app)

        openBill("本月", in: app)
        XCTAssertTrue(app.navigationBars["月账单"].waitForExistence(timeout: 5))
        assertBillTotal("62.34", in: app)
        XCTAssertTrue(cellExists(with: "期初累计支出", in: app), "月账单应显示期初累计的历史行")
        XCTAssertFalse(cellExists(with: "2026年10月", in: app), "10 月历史汇总不应出现在 11 月月账单")
        goHome(in: app)

        openBill("本年", in: app)
        XCTAssertTrue(app.navigationBars["年账单"].waitForExistence(timeout: 5))
        assertBillTotal("92.34", in: app)
        goHome(in: app)

        app.terminate()
        app.launchEnvironment = [
            "PAYLEDGER_TEST_LEDGER": ledger,
            "PAYLEDGER_TEST_NOW": "2026-11-20T10:00:00"
        ]
        app.launch()
        assertSummary("本月", is: "62.34", in: app)
        assertSummary("本年", is: "92.34", in: app)
    }

    /// 规格 1: the form starts with a blank cutoff, rejects a non-November-2026
    /// cutoff while keeping the typed amount, then backfills the saved cutoff
    /// when reopened so editing the amount reuses the same calendar date.
    func testHistoryCutoffValidationAndBackfillWithExampleAmounts() {
        let ledger = "uitest-\(UUID().uuidString).json"
        let app = XCUIApplication()
        app.launchEnvironment = [
            "PAYLEDGER_TEST_LEDGER": ledger,
            "PAYLEDGER_TEST_NOW": "2026-11-20T10:00:00"
        ]
        app.launch()
        app.buttons["manageHistory"].tap()

        let cutoff = app.textFields["historyCutoffDate"]
        XCTAssertTrue(cutoff.waitForExistence(timeout: 5))
        // An empty SwiftUI TextField reports its placeholder as its value.
        XCTAssertNotEqual(cutoff.value as? String ?? "", "2026-11-30", "首次录入不应预填截止日")
        let amount = app.textFields["historyOpeningAmount"]
        amount.tap()
        amount.typeText("50.00")
        cutoff.tap()
        cutoff.typeText("2026-10-31")
        app.buttons["saveHistoryOpening"].tap()

        XCTAssertTrue(app.staticTexts["historyErrorMessage"].waitForExistence(timeout: 5),
                      "非 11 月的截止日应显示校验错误")
        XCTAssertFalse(app.cells["historyOpeningRow"].exists, "校验失败不应写入期初累计")
        XCTAssertEqual(amount.value as? String ?? "", "50.00", "校验失败应保留用户输入")

        // Relaunch with the same isolated ledger; a rejected save changed nothing.
        app.terminate()
        app.launchEnvironment = [
            "PAYLEDGER_TEST_LEDGER": ledger,
            "PAYLEDGER_TEST_NOW": "2026-11-20T10:00:00"
        ]
        app.launch()
        app.buttons["manageHistory"].tap()
        let cutoff2 = app.textFields["historyCutoffDate"]
        XCTAssertTrue(cutoff2.waitForExistence(timeout: 5))
        XCTAssertNotEqual(cutoff2.value as? String ?? "", "2026-11-30", "未保存的截止日不应被回填")

        let amount2 = app.textFields["historyOpeningAmount"]
        amount2.tap()
        amount2.typeText("50.00")
        cutoff2.tap()
        cutoff2.typeText("2026-11-30")
        app.buttons["saveHistoryOpening"].tap()
        XCTAssertTrue(app.staticTexts["期初累计支出（截至 2026-11-30）"].waitForExistence(timeout: 5),
                      "有效的 11 月截止日应保存期初累计")

        app.buttons["完成"].tap()
        app.buttons["manageHistory"].tap()
        let cutoff3 = app.textFields["historyCutoffDate"]
        XCTAssertTrue(cutoff3.waitForExistence(timeout: 5))
        XCTAssertEqual(cutoff3.value as? String ?? "", "2026-11-30", "重新打开应回填已保存的截止日")
    }

    /// 规格 (Codex 2002dd5f 规格 2): 显式清空已回填的截止日后保存，应提示无效日期并
    /// 保留输入，原期初金额与截止日不变；保留回填日期只改金额则仍可成功替换。
    func testClearingBackfilledCutoffRequiresValidDateWithExampleAmounts() {
        let ledger = "uitest-\(UUID().uuidString).json"
        let launchEnv: [String: String] = [
            "PAYLEDGER_TEST_LEDGER": ledger,
            "PAYLEDGER_TEST_NOW": "2026-11-20T10:00:00"
        ]
        let app = XCUIApplication()
        app.launchEnvironment = launchEnv
        app.launch()
        app.buttons["manageHistory"].tap()
        XCTAssertTrue(app.textFields["historyOpeningAmount"].waitForExistence(timeout: 5))
        app.textFields["historyOpeningAmount"].tap()
        app.textFields["historyOpeningAmount"].typeText("50.00")
        let cutoff = app.textFields["historyCutoffDate"]
        cutoff.tap()
        cutoff.typeText("2026-11-15")
        app.buttons["saveHistoryOpening"].tap()
        XCTAssertTrue(app.staticTexts["期初累计支出（截至 2026-11-15）"].waitForExistence(timeout: 5),
                      "示例期初应保存")

        // 重新打开：截止日被回填。
        app.buttons["完成"].tap()
        app.buttons["manageHistory"].tap()
        let cutoff2 = app.textFields["historyCutoffDate"]
        XCTAssertTrue(cutoff2.waitForExistence(timeout: 5))
        XCTAssertEqual(cutoff2.value as? String ?? "", "2026-11-15", "重新打开应回填已保存的截止日")

        // 显式清空回填的截止日，改金额保存：应报错并保留原值。
        cutoff2.tap()
        for _ in 0..<12 { cutoff2.typeText("\u{8}") }
        XCTAssertNotEqual(cutoff2.value as? String ?? "", "2026-11-15", "截止日应已被清空")
        let amount2 = app.textFields["historyOpeningAmount"]
        amount2.tap()
        amount2.typeText("60.00")
        app.buttons["saveHistoryOpening"].tap()
        XCTAssertTrue(app.staticTexts["historyErrorMessage"].waitForExistence(timeout: 5),
                      "显式清空截止日后应提示无效日期，而不是沿用旧日期")
        XCTAssertEqual(amount2.value as? String ?? "", "60.00", "校验失败应保留输入金额")
        XCTAssertTrue(app.staticTexts["期初累计支出（截至 2026-11-15）"].exists,
                      "原期初截止日不应被覆盖")
        XCTAssertTrue(app.staticTexts["50.00"].exists, "原期初金额 50.00 不应被覆盖")

        // 重启后原值仍在。
        app.terminate()
        app.launchEnvironment = launchEnv
        app.launch()
        app.buttons["manageHistory"].tap()
        XCTAssertTrue(app.staticTexts["期初累计支出（截至 2026-11-15）"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["50.00"].exists, "重启后仍应读到原期初 50.00")

        // 对照：保留回填日期、只改金额，应成功替换。
        app.textFields["historyOpeningAmount"].tap()
        app.textFields["historyOpeningAmount"].typeText("60.00")
        app.buttons["saveHistoryOpening"].tap()
        XCTAssertFalse(app.staticTexts["historyErrorMessage"].exists, "保留有效回填日期时不应报错")
        XCTAssertTrue(app.staticTexts["期初累计支出（截至 2026-11-15）"].exists)
        XCTAssertTrue(app.staticTexts["60.00"].exists, "保留回填日期只改金额应成功替换为 60.00")
    }

    /// 规格 (Codex f17d77a2)：校验错误须位于对应保存操作附近，而不是排在
    /// 所有已存月份与期初记录之后。已有多条示例历史时提交无效月份与无效
    /// 截止日，都应在保存按钮附近、无需滚动越过已存行即可看到反馈，且保留
    /// 已有值与本次输入。
    func testHistoryValidationErrorsStayBesideSaveActionsWithManyRows() {
        let ledger = "uitest-\(UUID().uuidString).json"
        let app = XCUIApplication()
        app.launchEnvironment = [
            "PAYLEDGER_TEST_LEDGER": ledger,
            "PAYLEDGER_TEST_NOW": "2026-11-20T10:00:00"
        ]
        app.launch()
        app.buttons["manageHistory"].tap()
        XCTAssertTrue(app.textFields["historyMonthAmount"].waitForExistence(timeout: 5))

        func setField(_ id: String, _ value: String, clear: Int = 0) {
            let field = app.textFields[id]
            field.tap()
            for _ in 0..<clear { field.typeText("\u{8}") }
            field.typeText(value)
        }

        // 录入三条示例月度汇总，让已存行列表足够长——旧实现把错误放在末尾
        // Section，用户在保存按钮处提交时看不到反馈。
        for (month, amount) in [("1", "10.00"), ("2", "20.00"), ("3", "30.00")] {
            setField("historyMonth", month, clear: 4)
            XCTAssertEqual(app.textFields["historyMonth"].value as? String ?? "", month, "月份字段应被替换为 \(month)")
            setField("historyMonthAmount", amount)
            app.buttons["saveHistoryMonth"].tap()
        }
        for label in ["2026年1月", "2026年2月", "2026年3月"] {
            XCTAssertTrue(app.staticTexts[label].waitForExistence(timeout: 5), "应已保存示例月度汇总 \(label)")
        }

        // 在月份保存按钮处提交无效的 2026-11 汇总。
        setField("historyMonth", "11", clear: 4)
        setField("historyMonthAmount", "40.00")
        app.buttons["saveHistoryMonth"].tap()
        XCTAssertTrue(app.staticTexts["historyErrorMessage"].waitForExistence(timeout: 5),
                      "无效月份应显示校验错误")

        let rows = app.cells.allElementsBoundByIndex
        guard let amountIdx = rows.firstIndex(where: { $0.textFields["historyMonthAmount"].exists }),
              let errorIdx = rows.firstIndex(where: { $0.staticTexts["historyErrorMessage"].exists }),
              let saveIdx = rows.firstIndex(where: { $0.buttons["saveHistoryMonth"].exists }) else {
            XCTFail("找不到月度表单的金额/错误/保存行")
            return
        }
        XCTAssertLessThan(amountIdx, errorIdx, "校验错误应紧随金额输入之后")
        XCTAssertLessThan(errorIdx, saveIdx, "校验错误应位于保存按钮之前，无需滚动越过已存月份")
        XCTAssertEqual(app.textFields["historyMonth"].value as? String ?? "", "11", "校验失败应保留月份输入")
        XCTAssertEqual(app.textFields["historyMonthAmount"].value as? String ?? "", "40.00", "校验失败应保留金额输入")
        for label in ["2026年1月", "2026年2月", "2026年3月"] {
            XCTAssertTrue(app.staticTexts[label].exists, "校验失败应保留已存历史值 \(label)")
        }

        // 在期初保存按钮处提交无效的 2026-10 截止日。
        setField("historyOpeningAmount", "50.00")
        setField("historyCutoffDate", "2026-10-31")
        app.buttons["saveHistoryOpening"].tap()
        XCTAssertTrue(app.staticTexts["historyErrorMessage"].waitForExistence(timeout: 5),
                      "无效截止日应显示校验错误")

        let openingRows = app.cells.allElementsBoundByIndex
        guard let cutoffIdx = openingRows.firstIndex(where: { $0.textFields["historyCutoffDate"].exists }),
              let openErrIdx = openingRows.firstIndex(where: { $0.staticTexts["historyErrorMessage"].exists }),
              let openSaveIdx = openingRows.firstIndex(where: { $0.buttons["saveHistoryOpening"].exists }) else {
            XCTFail("找不到期初表单的截止日/错误/保存行")
            return
        }
        XCTAssertLessThan(cutoffIdx, openErrIdx, "校验错误应位于截止日字段之后")
        XCTAssertLessThan(openErrIdx, openSaveIdx, "校验错误应位于期初保存按钮之前")
        XCTAssertEqual(app.textFields["historyOpeningAmount"].value as? String ?? "", "50.00", "校验失败应保留期初金额")
        XCTAssertEqual(app.textFields["historyCutoffDate"].value as? String ?? "", "2026-10-31", "校验失败应保留截止日输入")
    }

    /// 规格 2: a per-record expense on or before the opening cutoff stays in
    /// the ledger but disappears from summaries and bills, and the history
    /// form warns before saving. Example: cutoff 11-25, a 11-20 record of 1.00.
    func testCoveredPerRecordIsExcludedAndWarnedBeforeSavingWithExampleAmounts() {
        let ledger = "uitest-\(UUID().uuidString).json"
        let app = XCUIApplication()
        app.launchEnvironment = [
            "PAYLEDGER_TEST_LEDGER": ledger,
            "PAYLEDGER_TEST_NOW": "2026-11-20T10:00:00"
        ]
        app.launch()
        save("1.00", in: app)
        assertSummary("今天", is: "1.00", in: app)

        app.buttons["manageHistory"].tap()
        let amount = app.textFields["historyOpeningAmount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap()
        amount.typeText("50.00")
        let cutoff = app.textFields["historyCutoffDate"]
        XCTAssertTrue(cutoff.waitForExistence(timeout: 5))
        cutoff.tap()
        cutoff.typeText("2026-11-25")

        let warning = app.staticTexts["historyCoveredRecordsWarning"]
        XCTAssertTrue(warning.waitForExistence(timeout: 5), "保存前应提示覆盖时段的逐笔将被排除")
        XCTAssertTrue(warning.label.contains("1.00"), "提示应说明受影响的逐笔金额：\(warning.label)")

        app.buttons["saveHistoryOpening"].tap()
        app.buttons["完成"].tap()

        assertSummary("今天", is: "0.00", in: app)
        assertSummary("本周", is: "0.00", in: app)
        assertSummary("本月", is: "50.00", in: app)
        assertSummary("本年", is: "50.00", in: app)

        openBill("本周", in: app)
        XCTAssertTrue(app.navigationBars["周账单"].waitForExistence(timeout: 5))
        assertBillTotal("0.00", in: app)
        XCTAssertFalse(cellExists(with: "1.00", in: app), "覆盖时段的逐笔不应出现在周账单")
        goHome(in: app)

        openBill("本月", in: app)
        XCTAssertTrue(app.navigationBars["月账单"].waitForExistence(timeout: 5))
        assertBillTotal("50.00", in: app)
        XCTAssertTrue(cellExists(with: "期初累计支出", in: app), "月账单应显示期初累计历史行")
        goHome(in: app)
    }

    /// 规范 (Codex f17d77a2): while the per-record ledger needs recovery the
    /// opening balance must not be saved or replaced (its covered records may
    /// be unloaded), the form explains why, and monthly summaries stay
    /// independent. After a healthy reopen the covered warning is accurate.
    func testOpeningSavePausedUntilLedgerRecoversWithExampleAmounts() {
        // A) Recovery needed: opening save disabled + reason shown; a monthly
        // summary can still be entered because it needs no per-record data.
        let pausedLedger = "uitest-\(UUID().uuidString).json"
        let paused = XCUIApplication()
        paused.launchEnvironment = [
            "PAYLEDGER_TEST_LEDGER": pausedLedger,
            "PAYLEDGER_TEST_STATE": "unreadable",
            "PAYLEDGER_TEST_NOW": "2026-11-20T10:00:00"
        ]
        paused.launch()
        paused.buttons["manageHistory"].tap()
        XCTAssertTrue(paused.textFields["historyOpeningAmount"].waitForExistence(timeout: 5))

        let reason = paused.staticTexts["historyOpeningPausedBanner"]
        XCTAssertTrue(reason.waitForExistence(timeout: 5), "恢复前应说明期初为何不可保存")
        let openingSave = paused.buttons["saveHistoryOpening"]
        XCTAssertTrue(openingSave.waitForExistence(timeout: 5))
        XCTAssertFalse(openingSave.isEnabled, "恢复前应禁用期初保存")
        XCTAssertTrue(paused.buttons["saveHistoryMonth"].isEnabled, "月度汇总应可独立录入")
        paused.textFields["historyMonthAmount"].tap()
        paused.textFields["historyMonthAmount"].typeText("40.00")
        paused.buttons["saveHistoryMonth"].tap()
        XCTAssertTrue(paused.staticTexts["40.00"].waitForExistence(timeout: 5),
                      "恢复前仍应可保存历史月度汇总")
        paused.buttons["完成"].tap()
        paused.terminate()

        // B) Healthy ledger: 11-15 1.00 is covered, 11-16 2.00 is counted.
        let healthyLedger = "uitest-\(UUID().uuidString).json"
        let app = XCUIApplication()
        app.launchEnvironment = [
            "PAYLEDGER_TEST_LEDGER": healthyLedger,
            "PAYLEDGER_TEST_NOW": "2026-11-15T10:00:00"
        ]
        app.launch()
        save("1.00", in: app)
        XCTAssertTrue(app.buttons["测试：推进一天"].waitForExistence(timeout: 5))
        app.buttons["测试：推进一天"].tap()
        save("2.00", in: app)

        app.buttons["manageHistory"].tap()
        app.textFields["historyOpeningAmount"].tap()
        app.textFields["historyOpeningAmount"].typeText("50.00")
        app.textFields["historyCutoffDate"].tap()
        app.textFields["historyCutoffDate"].typeText("2026-11-15")
        let warning = app.staticTexts["historyCoveredRecordsWarning"]
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        XCTAssertTrue(warning.label.contains("1 笔"), "11-15 截止只覆盖一笔：\(warning.label)")
        XCTAssertTrue(warning.label.contains("1.00"), "覆盖金额应为 1.00：\(warning.label)")
        XCTAssertTrue(app.buttons["saveHistoryOpening"].isEnabled, "恢复后期初保存应可用")
        app.buttons["saveHistoryOpening"].tap()
        app.buttons["完成"].tap()

        assertSummary("今天", is: "2.00", in: app)
        assertSummary("本周", is: "2.00", in: app)
        assertSummary("本月", is: "52.00", in: app) // 期初 50.00 + 逐笔 2.00
    }

    /// 规格 (Codex 7973a7c0): the covered-records warning must live inside the
    /// opening-balance form, before the save button, so the user sees the count
    /// and amount before saving; it must also follow the typed cutoff date.
    func testCoveredWarningSitsInsideOpeningFormAndFollowsCutoffWithExampleAmounts() {
        let ledger = "uitest-\(UUID().uuidString).json"
        let app = XCUIApplication()
        app.launchEnvironment = [
            "PAYLEDGER_TEST_LEDGER": ledger,
            "PAYLEDGER_TEST_NOW": "2026-11-20T10:00:00"
        ]
        app.launch()

        // Two example records on different dates: 11-20 = 1.00, 11-26 = 2.00.
        save("1.00", in: app)
        for _ in 0..<6 {
            app.buttons["测试：推进一天"].tap()
        }
        save("2.00", in: app)

        app.buttons["manageHistory"].tap()
        XCTAssertTrue(app.textFields["historyOpeningAmount"].waitForExistence(timeout: 5))
        app.textFields["historyOpeningAmount"].tap()
        app.textFields["historyOpeningAmount"].typeText("50.00")
        let cutoff = app.textFields["historyCutoffDate"]
        cutoff.tap()
        cutoff.typeText("2026-11-25")

        let warning = app.staticTexts["historyCoveredRecordsWarning"]
        XCTAssertTrue(warning.waitForExistence(timeout: 5), "保存前应提示覆盖时段的逐笔")
        XCTAssertTrue(warning.label.contains("1 笔"), "截止 11-25 只覆盖一笔：\(warning.label)")
        XCTAssertTrue(warning.label.contains("1.00"), "提示应说明被覆盖的逐笔金额：\(warning.label)")
        XCTAssertFalse(warning.label.contains("2.00"), "11-26 的记录未被 11-25 截止覆盖：\(warning.label)")

        // Placement: the warning row belongs to the opening form — after the
        // cutoff field and before the save button (a trailing Section fails).
        let rows = app.cells.allElementsBoundByIndex
        guard let cutoffIdx = rows.firstIndex(where: { $0.textFields["historyCutoffDate"].exists }),
              let warningIdx = rows.firstIndex(where: { $0.staticTexts["historyCoveredRecordsWarning"].exists }),
              let saveIdx = rows.firstIndex(where: { $0.buttons["saveHistoryOpening"].exists }) else {
            XCTFail("找不到期初表单的截止日/提示/保存行")
            return
        }
        XCTAssertLessThan(cutoffIdx, warningIdx, "覆盖提示应位于截止日期字段之后")
        XCTAssertLessThan(warningIdx, saveIdx, "覆盖提示应位于保存按钮之前、期初表单内")

        // Not saved: relaunch with a later cutoff and confirm the warning
        // follows the cutoff (both example records now fall in the covered span).
        app.terminate()
        app.launchEnvironment = [
            "PAYLEDGER_TEST_LEDGER": ledger,
            "PAYLEDGER_TEST_NOW": "2026-11-26T10:00:00"
        ]
        app.launch()
        app.buttons["manageHistory"].tap()
        let cutoff2 = app.textFields["historyCutoffDate"]
        XCTAssertTrue(cutoff2.waitForExistence(timeout: 5))
        XCTAssertFalse((cutoff2.value as? String ?? "").contains("2026-11"),
                       "未保存期初时截止日不应回填")
        cutoff2.tap()
        cutoff2.typeText("2026-11-30")
        let warning2 = app.staticTexts["historyCoveredRecordsWarning"]
        XCTAssertTrue(warning2.waitForExistence(timeout: 5))
        XCTAssertTrue(warning2.label.contains("2 笔"), "截止 11-30 应覆盖两笔：\(warning2.label)")
        XCTAssertTrue(warning2.label.contains("3.00"), "两笔合计 3.00：\(warning2.label)")
    }

    /// 规格 (Codex 7973a7c0): a user with no pre-enablement spending can save
    /// a zero October summary and a zero opening balance through the form, and
    /// both read back after restart. The 11-15 per-record expense stays in the
    /// ledger but is excluded, while the 11-16 one counts in week/category/
    /// month/year. Re-saving the same zero segment replaces rather than adds.
    func testZeroHistoryAmountsSaveAndSurviveRestartWithExampleAmounts() {
        let ledger = "uitest-\(UUID().uuidString).json"
        let app = XCUIApplication()
        app.launchEnvironment = [
            "PAYLEDGER_TEST_LEDGER": ledger,
            "PAYLEDGER_TEST_NOW": "2026-11-15T10:00:00"
        ]
        app.launch()

        // A 11-15 record exists before any history is entered (fully counted).
        save("1.00", in: app)
        assertSummary("今天", is: "1.00", in: app)

        // Zero October summary and zero opening balance via the offline form.
        // The 11-15 record falls on the cutoff and will be excluded; the form
        // warns before saving. Re-saving the same zero segments replaces them.
        app.buttons["manageHistory"].tap()
        app.textFields["historyMonthAmount"].tap()
        app.textFields["historyMonthAmount"].typeText("0.00")
        app.buttons["saveHistoryMonth"].tap()
        app.textFields["historyMonthAmount"].tap()
        app.textFields["historyMonthAmount"].typeText("0.00")
        app.buttons["saveHistoryMonth"].tap()
        app.textFields["historyOpeningAmount"].tap()
        app.textFields["historyOpeningAmount"].typeText("0.00")
        app.textFields["historyCutoffDate"].tap()
        app.textFields["historyCutoffDate"].typeText("2026-11-15")
        let warning = app.staticTexts["historyCoveredRecordsWarning"]
        XCTAssertTrue(warning.waitForExistence(timeout: 5), "零期初保存前应提示覆盖记录")
        XCTAssertTrue(warning.label.contains("1.00"), "提示应说明受影响的 1.00 逐笔：\(warning.label)")
        app.buttons["saveHistoryOpening"].tap()
        app.buttons["完成"].tap()

        // After setting the zero opening: cutoff-day 1.00 excluded, so the
        // only counted per-record is a new 11-16 expense.
        assertSummary("今天", is: "0.00", in: app)
        assertSummary("本月", is: "0.00", in: app) // 期初 0.00 + 逐笔 0.00 (1.00 被排除)

        // Advance on the same open screen to 11-16 (enable day) and save 2.00.
        let advanceClock = app.buttons["测试：推进一天"]
        XCTAssertTrue(advanceClock.waitForExistence(timeout: 5))
        advanceClock.tap()
        save("2.00", in: app)
        assertSummary("今天", is: "2.00", in: app)
        assertSummary("本周", is: "2.00", in: app)
        assertSummary("本月", is: "2.00", in: app) // 期初 0.00 + 逐笔 2.00
        assertSummary("本年", is: "2.00", in: app) // 10 月 0.00 + 期初 0.00 + 逐笔 2.00

        app.buttons["manageHistory"].tap()
        XCTAssertGreaterThan(app.staticTexts.matching(identifier: "historyOpeningRow").count, 0,
                      "零额期初应显示在表单中")
        app.buttons["完成"].tap()

        // Restart: zero history + both per-record rows read back; 1.00 stays
        // in the ledger but remains excluded, 2.00 counted once.
        app.terminate()
        app.launchEnvironment = [
            "PAYLEDGER_TEST_LEDGER": ledger,
            "PAYLEDGER_TEST_NOW": "2026-11-16T10:00:00"
        ]
        app.launch()
        assertSummary("今天", is: "2.00", in: app)
        assertSummary("本月", is: "2.00", in: app)
        assertSummary("本年", is: "2.00", in: app)
        app.buttons["manageHistory"].tap()
        XCTAssertGreaterThan(app.staticTexts.matching(identifier: "historyOpeningRow").count, 0,
                             "重启后零额期初仍在")
    }

    /// 规格 3: the home screen still opens the current year, but the year bill
    /// can switch back to the year that owns historical summaries. With the
    /// clock pinned in 2027, the 2026 opening balance and October summary stay
    /// viewable and their months expand independently on the same page.
    func testYearBillSwitchesToHistoryYearWhileHomeStaysOnCurrentYear() {
        let ledger = "uitest-\(UUID().uuidString).json"
        let app = XCUIApplication()
        app.launchEnvironment = [
            "PAYLEDGER_TEST_LEDGER": ledger,
            "PAYLEDGER_TEST_NOW": "2026-11-20T10:00:00"
        ]
        app.launch()
        enterHistory(monthAmount: "30.00", openingAmount: "50.00", in: app)
        save("12.34", in: app)
        assertSummary("本年", is: "92.34", in: app)

        // Relaunch in 2027: the home screen must still default to that year.
        app.terminate()
        app.launchEnvironment = [
            "PAYLEDGER_TEST_LEDGER": ledger,
            "PAYLEDGER_TEST_NOW": "2027-03-10T10:00:00"
        ]
        app.launch()
        assertSummary("本年", is: "0.00", in: app)

        openBill("本年", in: app)
        XCTAssertTrue(app.navigationBars["年账单"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["yearBillCurrentYear"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["yearBillCurrentYear"].label.contains("2027"),
                      "首页默认进入当前 2027 年账单：\(app.staticTexts["yearBillCurrentYear"].label)")
        assertBillTotal("0.00", in: app)

        let previous = app.buttons["yearBillPreviousYear"]
        XCTAssertTrue(previous.waitForExistence(timeout: 5), "年账单应提供切换到上一年入口")
        previous.tap()
        XCTAssertTrue(app.staticTexts["yearBillCurrentYear"].label.contains("2026"),
                      "切回历史所属年份 2026：\(app.staticTexts["yearBillCurrentYear"].label)")
        assertBillTotal("92.34", in: app) // 10 月历史 30.00 + 期初 50.00 + 启用后逐笔 12.34

        guard let november = findCell("11月", in: app, swipeUp: true) else {
            XCTFail("找不到 11 月"); return
        }
        november.tap()
        XCTAssertTrue(cellExists(with: "期初累计支出", in: app), "2026 年 11 月应显示期初累计历史行")
        XCTAssertTrue(cellExists(with: "12.34", in: app), "2026 年 11 月应显示启用后逐笔")

        guard let october = findCell("10月", in: app, swipeUp: false) else {
            XCTFail("找不到 10 月"); return
        }
        october.tap()
        let dump = { app.cells.allElementsBoundByIndex.map { $0.staticTexts.allElementsBoundByIndex.map(\.label) }.description }
        XCTAssertNotNil(findCell("2026年10月", in: app, swipeUp: true),
                        "2026 年 10 月应显示历史月度汇总行；cells=\(dump())")
        XCTAssertNotNil(findCell("30.00", in: app, swipeUp: true),
                        "10 月历史金额 30.00 应可见；cells=\(dump())")
        XCTAssertNotNil(findCell("期初累计支出", in: app, swipeUp: true),
                        "展开 10 月不应收起已展开的 11 月；cells=\(dump())")
    }

    /// f17d77a2 规格 3: a year-bill month that only has a historical summary
    /// must not show the misleading "本月无记录" empty state beside that
    /// history row; it should say there are no per-record entries. A month
    /// with neither history nor per-record rows keeps the original empty state.
    func testYearBillHistoryOnlyMonthShowsNoMisleadingEmptyState() {
        let ledger = "uitest-\(UUID().uuidString).json"
        let app = XCUIApplication()
        app.launchEnvironment = [
            "PAYLEDGER_TEST_LEDGER": ledger,
            "PAYLEDGER_TEST_NOW": "2026-11-20T10:00:00"
        ]
        app.launch()

        // Only a historical month (form defaults to 2026-10). No per-record
        // expense and no opening balance are saved.
        let manage = app.buttons["manageHistory"]
        XCTAssertTrue(manage.waitForExistence(timeout: 5))
        manage.tap()
        let monthField = app.textFields["historyMonthAmount"]
        XCTAssertTrue(monthField.waitForExistence(timeout: 5))
        monthField.tap()
        monthField.typeText("30.00")
        app.buttons["saveHistoryMonth"].tap()
        app.buttons["完成"].tap()

        openBill("本年", in: app)
        XCTAssertTrue(app.navigationBars["年账单"].waitForExistence(timeout: 5))

        guard let october = findCell("10月", in: app, swipeUp: true) else {
            XCTFail("找不到 10 月"); return
        }
        october.tap()
        XCTAssertTrue(cellExists(with: "2026年10月", in: app), "2026 年 10 月应显示历史月度汇总行")
        XCTAssertFalse(cellExists(with: "本月无记录", in: app),
                       "只有历史汇总的月份不应再显示「本月无记录」")
        XCTAssertTrue(cellExists(with: "本月无逐笔记录", in: app),
                      "只有历史汇总的月份应明确提示本月无逐笔记录")

        // A month with neither history nor per-record rows keeps the original
        // empty state.
        guard let january = findCell("1月", in: app, swipeUp: false) else {
            XCTFail("找不到 1 月"); return
        }
        january.tap()
        XCTAssertTrue(cellExists(with: "本月无记录", in: app),
                      "两类记录均为空的月份仍应显示原有的「本月无记录」")
    }

    /// 规范 1: a corrupt history file is reported as unavailable on the home
    /// month/year summaries and in the history form and bills, while pure
    /// per-record queries (today/week/daily rows) keep working. The original
    /// bytes are never overwritten by a save attempt.
    func testUnreadableHistoryShowsUnavailableButPerRecordQueriesStillWork() {
        assertHistoryUnavailableSurfaces(mode: "unreadable")
    }

    /// 规范 1: a decodable but semantically invalid history file (duplicate
    /// month) must surface the same unavailability on every history-dependent
    /// total while pure per-record queries keep working.
    func testSemanticallyInvalidHistoryShowsUnavailableButPerRecordQueriesStillWork() {
        assertHistoryUnavailableSurfaces(mode: "invalid-fields")
    }

    /// f17d77a2 规格: with a damaged history file, only intervals that could
    /// contain a history value are flagged. Months from 2026-12 and years from
    /// 2027 fall entirely after the latest enable day, so their totals are
    /// computed from per-record expenses alone.
    func testUnavailableHistoryOnlyAffectsIntervalsBeforeDecember2026() {
        let ledger = "uitest-\(UUID().uuidString).json"
        let app = XCUIApplication()
        app.launchEnvironment = [
            "PAYLEDGER_TEST_LEDGER": ledger,
            "PAYLEDGER_TEST_HISTORY": "unreadable",
            "PAYLEDGER_TEST_NOW": "2026-12-10T10:00:00"
        ]
        app.launch()

        // A December 2026 per-record expense: its month total is computable.
        save("12.34", in: app)
        assertPersistedRow(category: "食品酒水", amount: "12.34", in: app)
        // Home 本月 (2026-12) is after the history window -> real total.
        assertSummary("本月", is: "12.34", in: app)
        // Home 本年 (2026) still owns the opening balance month -> unavailable.
        assertSummary("本年", is: "历史不可用", in: app)

        // The December month bill total is computable, while 2026 full-year is not.
        openBill("本月", in: app)
        assertBillTotal("12.34", in: app)
        goHome(in: app)
        openBill("本年", in: app)
        assertBillTotal("历史不可用", in: app)
        // In the 2026 year bill, December's row is computable (starts 2026-12-01)
        // while November's row is still unavailable.
        guard let december = findCell("12月", in: app, swipeUp: true) else {
            XCTFail("找不到 2026 年 12 月行"); return
        }
        let decValues = december.staticTexts.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(decValues.contains("12.34"), "2026-12 月小计应由逐笔算出：\(decValues)")
        XCTAssertFalse(decValues.contains("历史不可用"), "2026-12 月不应标记不可用：\(decValues)")
        guard let november = findCell("11月", in: app, swipeUp: false) else {
            XCTFail("找不到 2026 年 11 月行"); return
        }
        let novValues = november.staticTexts.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(novValues.contains("历史不可用"), "2026-11 归属月仍应不可用：\(novValues)")
        goHome(in: app)

        // Relaunch in 2027: the full year and its January month are computable.
        app.terminate()
        app.launchEnvironment = [
            "PAYLEDGER_TEST_LEDGER": ledger,
            "PAYLEDGER_TEST_HISTORY": "unreadable",
            "PAYLEDGER_TEST_NOW": "2027-01-10T10:00:00"
        ]
        app.launch()
        save("12.34", in: app)
        assertSummary("本月", is: "12.34", in: app)
        assertSummary("本年", is: "12.34", in: app)
        openBill("本年", in: app)
        assertBillTotal("12.34", in: app)
    }

    /// Codex 293af6e2 规格 2: a substring match would let "11 笔 / 11.00"
    /// satisfy "1 笔 / 1.00". Pin the field-boundary matcher so lookalikes
    /// (extra leading digit, extra trailing decimal) are rejected.
    func testCoveredPreviewFieldMatchingRejectsLookalikeValues() {
        let correct = "已有 1 笔逐笔记录（合计 1.00）落在覆盖时段，将保留在账本中，但从账单统计中排除。"
        XCTAssertTrue(coveredPreviewField("1 笔", appearsIn: correct))
        XCTAssertTrue(coveredPreviewField("1.00", appearsIn: correct))

        let lookalike = "已有 11 笔逐笔记录（合计 11.00）落在覆盖时段，将保留在账本中，但从账单统计中排除。"
        XCTAssertFalse(coveredPreviewField("1 笔", appearsIn: lookalike))
        XCTAssertFalse(coveredPreviewField("1.00", appearsIn: lookalike))
        XCTAssertFalse(coveredPreviewField("1.00", appearsIn: "已有 1 笔逐笔记录（合计 1.000）落在覆盖时段"))
    }

    /// Codex 2002dd5f 规格 1: a record saved at 23:30 on 11-15 in UTC+8 must
    /// remain in the opening-balance covered period after restarts under UTC+9
    /// and UTC, even though its raw instant falls on 11-16 in those zones.
    func testConsumptionDayStableAcrossTimeZoneRestarts() {
        let ledger = "uitest-\(UUID().uuidString).json"
        let app = XCUIApplication()

        func relaunch(zone: String, now: String) {
            app.terminate()
            app.launchEnvironment = [
                "PAYLEDGER_TEST_LEDGER": ledger,
                "PAYLEDGER_TEST_TZ": zone,
                "PAYLEDGER_TEST_NOW": now
            ]
            app.launch()
        }

        // The 11-16 00:15 record is the only eligible per-record spend:
        // today/week are 2.00, month/year are opening 50.00 + 2.00.
        func assertStableBills() {
            assertSummary("今天", is: "2.00", in: app)
            assertSummary("本周", is: "2.00", in: app)
            assertSummary("本月", is: "52.00", in: app)
            assertSummary("本年", is: "52.00", in: app)

            // 周账单：合计与一级分类小计都只含启用后逐笔；展开后逐笔行显示消费日。
            openBill("本周", in: app)
            XCTAssertTrue(app.navigationBars["周账单"].waitForExistence(timeout: 5))
            assertBillTotal("2.00", in: app)
            assertWeekCategorySubtotal("食品酒水", is: "2.00", not: "3.00", in: app)
            tapCell(with: "食品酒水", in: app) // expand the primary category
            assertPerRecordRowShowsDate("2026-11-16", amount: "2.00", in: app)
            goHome(in: app)

            openBill("本月", in: app)
            XCTAssertTrue(app.navigationBars["月账单"].waitForExistence(timeout: 5))
            assertBillTotal("52.00", in: app)
            tapCell(with: "合计", in: app) // expand the in-place day detail
            XCTAssertTrue(cellExists(with: "2.00", in: app), "启用后 2.00 应出现在月账单")
            XCTAssertFalse(cellExists(with: "1.00", in: app), "覆盖时段的 1.00 不应出现在账单")
            assertPerRecordRowShowsDate("2026-11-16", amount: "2.00", in: app)
            goHome(in: app)

            // 年账单：展开 11 月后，逐笔行同样显示稳定的消费日。
            openBill("本年", in: app)
            XCTAssertTrue(app.navigationBars["年账单"].waitForExistence(timeout: 5))
            assertBillTotal("52.00", in: app)
            guard let november = findCell("11月", in: app, swipeUp: true) else {
                XCTFail("年账单应能滚动到 11 月")
                return
            }
            november.tap()
            assertPerRecordRowShowsDate("2026-11-16", amount: "2.00", in: app)
            goHome(in: app)

            // 覆盖预览在 UTC+08/UTC+09/UTC 三次启动中都必须为 1 笔 / 1.00。
            assertCoveredPreview(count: "1 笔", amount: "1.00", in: app)
        }

        relaunch(zone: "Asia/Shanghai", now: "2026-11-15T23:30:00")
        save("1.00", in: app)
        relaunch(zone: "Asia/Shanghai", now: "2026-11-16T00:15:00")
        save("2.00", in: app)

        // Enter opening balance 50.00 with cutoff 11-15; the warning must count
        // exactly one covered record for 1.00.
        app.buttons["manageHistory"].tap()
        let opening = app.textFields["historyOpeningAmount"]
        XCTAssertTrue(opening.waitForExistence(timeout: 5))
        opening.tap()
        opening.typeText("50.00")
        let cutoff = app.textFields["historyCutoffDate"]
        XCTAssertTrue(cutoff.waitForExistence(timeout: 5))
        cutoff.tap()
        cutoff.typeText("2026-11-15")
        let warning = app.staticTexts["historyCoveredRecordsWarning"]
        XCTAssertTrue(warning.waitForExistence(timeout: 5), "保存前应提示覆盖的逐笔")
        XCTAssertTrue(warning.label.contains("1 笔"), "覆盖提示应为 1 笔：\(warning.label)")
        XCTAssertTrue(warning.label.contains("1.00"), "覆盖提示应含 1.00：\(warning.label)")
        app.buttons["saveHistoryOpening"].tap()
        app.buttons["完成"].tap()

        assertStableBills()

        // UTC+9: the 23:30 instant would re-derive to 11-16 under the old code.
        relaunch(zone: "Asia/Tokyo", now: "2026-11-16T00:15:00")
        assertStableBills()

        // UTC: same instant is 11-15 15:30, but the recorded day still governs.
        relaunch(zone: "UTC", now: "2026-11-16T00:15:00")
        assertStableBills()
    }

    private func assertHistoryUnavailableSurfaces(mode: String) {
        let ledger = "uitest-\(UUID().uuidString).json"
        let app = XCUIApplication()
        app.launchEnvironment = [
            "PAYLEDGER_TEST_LEDGER": ledger,
            "PAYLEDGER_TEST_HISTORY": mode,
            "PAYLEDGER_TEST_NOW": "2026-11-20T10:00:00"
        ]
        app.launch()

        // Pure per-record accounting is unaffected by unreadable history.
        save("12.34", in: app)
        assertPersistedRow(category: "食品酒水", amount: "12.34", in: app)
        assertSummary("今天", is: "12.34", in: app)
        assertSummary("本周", is: "12.34", in: app)
        // Month/year totals include history, so they must not look complete.
        assertSummary("本月", is: "历史不可用", in: app)
        assertSummary("本年", is: "历史不可用", in: app)

        // The offline history form surfaces the same unavailability.
        app.buttons["manageHistory"].tap()
        XCTAssertTrue(app.staticTexts["historyUnavailableBanner"].waitForExistence(timeout: 5))
        let monthAmount = app.textFields["historyMonthAmount"]
        XCTAssertTrue(monthAmount.waitForExistence(timeout: 5))
        monthAmount.tap()
        monthAmount.typeText("30.00")
        app.buttons["saveHistoryMonth"].tap()
        XCTAssertTrue(app.staticTexts["historyErrorMessage"].waitForExistence(timeout: 5),
                      "保存历史月份应报告失败，不能静默覆盖损坏文件")
        app.buttons["完成"].tap()

        // Month and year bill totals must also flag the unavailable history.
        openBill("本月", in: app)
        assertBillTotal("历史不可用", in: app)
        goHome(in: app)
        openBill("本年", in: app)
        assertBillTotal("历史不可用", in: app)
    }

    // MARK: - Helpers

    private func openBill(_ label: String, in app: XCUIApplication,
                          file: StaticString = #filePath, line: UInt = #line) {
        guard let row = app.cells.allElementsBoundByIndex.first(where: {
            $0.staticTexts[label].exists
        }) else {
            XCTFail("缺少账单入口：\(label)", file: file, line: line)
            return
        }
        row.tap()
    }

    private func assertBillTotal(_ expected: String, in app: XCUIApplication,
                                 file: StaticString = #filePath, line: UInt = #line) {
        guard let row = app.cells.allElementsBoundByIndex.first(where: {
            $0.staticTexts["合计"].exists
        }) else {
            XCTFail("缺少账单合计行", file: file, line: line)
            return
        }
        let values = row.staticTexts.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(values.contains(expected),
                      "账单合计应为 \(expected)，实际为 \(values)", file: file, line: line)
    }

    private func tapCell(with text: String, in app: XCUIApplication,
                         file: StaticString = #filePath, line: UInt = #line) {
        guard let cell = app.cells.allElementsBoundByIndex.first(where: {
            $0.staticTexts[text].exists
        }) else {
            XCTFail("找不到可点按的单元格：\(text)", file: file, line: line)
            return
        }
        cell.tap()
    }

    /// SwiftUI List only materialises visible rows, so long bill lists need a
    /// scroll before an off-screen month can be tapped.
    private func findCell(_ text: String, in app: XCUIApplication,
                          swipeUp: Bool, maxSwipes: Int = 20) -> XCUIElement? {
        for _ in 0..<maxSwipes {
            if let cell = app.cells.allElementsBoundByIndex.first(where: {
                $0.staticTexts[text].exists
            }) { return cell }
            if swipeUp { app.swipeUp() } else { app.swipeDown() }
        }
        return app.cells.allElementsBoundByIndex.first { $0.staticTexts[text].exists }
    }

    private func cellExists(with text: String, in app: XCUIApplication) -> Bool {
        app.cells.allElementsBoundByIndex.contains { $0.staticTexts[text].exists }
    }

    private func countCells(containing text: String, in app: XCUIApplication) -> Int {
        app.cells.allElementsBoundByIndex.filter { $0.staticTexts[text].exists }.count
    }

    private func goHome(in app: XCUIApplication,
                        file: StaticString = #filePath, line: UInt = #line) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.exists, "缺少返回按钮", file: file, line: line)
        back.tap()
    }

    private func save(_ amount: String, in app: XCUIApplication) {
        app.buttons["记一笔"].tap()
        let field = app.textFields["0.00"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(amount)
        app.buttons["保存"].tap()
    }

    /// Enters one example historical month and the opening balance using the
    /// offline history form. The month field defaults to 10; the cutoff starts
    /// blank, so a valid example November 2026 date is typed explicitly.
    private func enterHistory(monthAmount: String, openingAmount: String,
                               in app: XCUIApplication,
                               file: StaticString = #filePath, line: UInt = #line) {
        let manage = app.buttons["manageHistory"]
        XCTAssertTrue(manage.waitForExistence(timeout: 5), file: file, line: line)
        manage.tap()

        let monthField = app.textFields["historyMonthAmount"]
        XCTAssertTrue(monthField.waitForExistence(timeout: 5), file: file, line: line)
        monthField.tap()
        monthField.typeText(monthAmount)
        app.buttons["saveHistoryMonth"].tap()

        let openingField = app.textFields["historyOpeningAmount"]
        XCTAssertTrue(openingField.waitForExistence(timeout: 5), file: file, line: line)
        openingField.tap()
        openingField.typeText(openingAmount)
        let cutoffField = app.textFields["historyCutoffDate"]
        XCTAssertTrue(cutoffField.waitForExistence(timeout: 5), file: file, line: line)
        cutoffField.tap()
        cutoffField.typeText("2026-11-15")
        app.buttons["saveHistoryOpening"].tap()

        XCTAssertTrue(app.staticTexts[openingAmount].waitForExistence(timeout: 5),
                      "期初累计金额应显示在历史表单中", file: file, line: line)
        app.buttons["完成"].tap()
    }

    /// Match a value as a whole field, not a substring: "1 笔" must not match
    /// "11 笔", and "1.00" must not match "11.00" or "1.000".
    private func coveredPreviewField(_ field: String, appearsIn label: String) -> Bool {
        let pattern = "(?<![0-9])\(NSRegularExpression.escapedPattern(for: field))(?![0-9])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) != nil
    }

    /// The opening form previews covered per-record spends from the persisted
    /// cutoff. Assert BOTH the count and the amount on every launch so a
    /// timezone change cannot silently flip a record across the cutoff.
    private func assertCoveredPreview(count: String, amount: String, in app: XCUIApplication,
                                      file: StaticString = #filePath, line: UInt = #line) {
        app.buttons["manageHistory"].tap()
        let warning = app.staticTexts["historyCoveredRecordsWarning"]
        XCTAssertTrue(warning.waitForExistence(timeout: 5), "保存前应提示覆盖的逐笔",
                      file: file, line: line)
        XCTAssertTrue(coveredPreviewField(count, appearsIn: warning.label),
                      "覆盖笔数应为 \(count)：\(warning.label)", file: file, line: line)
        XCTAssertTrue(coveredPreviewField(amount, appearsIn: warning.label),
                      "覆盖金额应为 \(amount)：\(warning.label)", file: file, line: line)
        app.buttons["完成"].tap()
    }

    /// A primary-category row in the week bill carries that group's subtotal.
    /// The covered 1.00 must never inflate it (e.g. to 3.00).
    private func assertWeekCategorySubtotal(_ category: String, is expected: String,
                                             not other: String? = nil,
                                             in app: XCUIApplication,
                                             file: StaticString = #filePath, line: UInt = #line) {
        let row = app.cells.allElementsBoundByIndex.first { $0.staticTexts[category].exists }
        XCTAssertNotNil(row, "周账单应有一级分类 \(category) 小计行", file: file, line: line)
        let values = row?.staticTexts.allElementsBoundByIndex.map(\.label) ?? []
        XCTAssertTrue(values.contains(expected), "\(category) 小计应为 \(expected)，实际 \(values)",
                      file: file, line: line)
        if let other {
            XCTAssertFalse(values.contains(other), "覆盖的逐笔不得计入 \(category) 小计，实际 \(values)",
                           file: file, line: line)
        }
    }

    /// Asserts that exactly one actual per-record row carries the given amount,
    /// and that THIS SAME row shows the expected consumption day. The amount
    /// and date leaves share the expense's stable id as an identifier suffix,
    /// so the match is scoped to one expense even when several rows sit on the
    /// same day. Page-wide separate searches could pair 12.34's amount with
    /// 87.65's correct 11-20 date and pass while 12.34's own row shows a wrong
    /// day — the shared suffix prevents that false positive.
    private func assertPerRecordRowShowsDate(_ date: String, amount: String,
                                              in app: XCUIApplication,
                                              file: StaticString = #filePath,
                                              line: UInt = #line) {
        let amountPrefix = "billExpenseAmount-"
        let datePrefix = "billExpenseDate-"
        let amountLeaves = app.staticTexts
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", amountPrefix))
            .allElementsBoundByIndex
        let matches = amountLeaves.filter { $0.label == amount }
        XCTAssertEqual(matches.count, 1,
                       "应有且仅有一条金额为 \(amount) 的逐笔行，实际匹配 \(matches.count) 条（逐笔行总数 \(amountLeaves.count)）",
                       file: file, line: line)
        guard let amountLeaf = matches.first else { return }
        let token = String(amountLeaf.identifier.dropFirst(amountPrefix.count))
        let dateLeaves = app.staticTexts.matching(identifier: datePrefix + token)
        XCTAssertEqual(dateLeaves.count, 1,
                       "逐笔行 \(amount) 应有唯一消费日，实际匹配 \(dateLeaves.count) 条",
                       file: file, line: line)
        XCTAssertEqual(dateLeaves.allElementsBoundByIndex.first?.label, date,
                       "逐笔行 \(amount) 应显示消费日 \(date)，实际 \(dateLeaves.allElementsBoundByIndex.map(\.label))",
                       file: file, line: line)
    }

    private func assertPersistedRow(
        category: String,
        amount: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let row = app.cells.allElementsBoundByIndex.first { cell in
            cell.staticTexts[category].exists && cell.staticTexts[amount].exists
        }
        XCTAssertNotNil(
            row,
            "找不到同时含 \(category) 与 \(amount) 的逐笔行",
            file: file, line: line
        )
    }

    private func assertSummaries(
        show amount: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for label in ["今天", "本周", "本月"] {
            assertSummary(label, is: amount, in: app, file: file, line: line)
        }
    }

    private func assertSummary(
        _ label: String,
        is expected: String,
        not other: String? = nil,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let row = app.cells.allElementsBoundByIndex.first(where: {
            $0.staticTexts[label].exists
        }) else {
            XCTFail("缺少汇总行：\(label)", file: file, line: line)
            return
        }
        let values = row.staticTexts.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(values.contains(expected),
                      "\(label) 汇总应为 \(expected)，实际为 \(values)",
                      file: file, line: line)
        if let other {
            XCTAssertFalse(values.contains(other),
                           "\(label) 汇总不应包含 \(other)，实际为 \(values)",
                           file: file, line: line)
        }
    }
}
