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
    /// accounting open with the cleanup banner; a later launch clears it.
    func testCleanupPendingKeepsAccountingOpenAndClearsOnRestart() {
        let ledger = "uitest-\(UUID().uuidString).json"
        let app = XCUIApplication()
        app.launchEnvironment = [
            "PAYLEDGER_TEST_LEDGER": ledger,
            "PAYLEDGER_TEST_STATE": "cleanupPending"
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
            "PAYLEDGER_TEST_STATE": "cleanupPendingRecover"
        ]
        app.launch()
        XCTAssertFalse(app.staticTexts["旧账本副本待清理"].exists, "banner clears after cleanup retry")
        assertPersistedRow(category: "食品酒水", amount: "12.34", in: app)
        assertPersistedRow(category: "食品酒水", amount: exampleAmount, in: app)
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

        subWheel.pickerWheels.element.adjust(toPickerWheelValue: "零食饮料")
        XCTAssertTrue(app.staticTexts["食品酒水 · 零食饮料"].waitForExistence(timeout: 5),
                      "选子类后表单应同步显示")
        primaryWheel.pickerWheels.element.adjust(toPickerWheelValue: "交通")
        XCTAssertTrue(app.staticTexts["交通 · 公交地铁"].waitForExistence(timeout: 5),
                      "切换大类后右列应切到对应首个子类")

        app.buttons["doneCategoryWheel"].tap()
        XCTAssertFalse(app.pickers["primaryCategoryPicker"].exists, "完成后滚轮应收起")
        XCTAssertTrue(app.staticTexts["交通 · 公交地铁"].exists, "收起后保留所选分类")
        XCTAssertEqual(amountField.value as? String, "31.20", "收起后保留已输入金额")

        app.buttons["保存"].tap()
        assertPersistedRow(category: "交通", amount: "31.20", in: app)
        assertPersistedRow(category: "公交地铁", amount: "31.20", in: app)
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
        subWheel.pickerWheels.element.adjust(toPickerWheelValue: "零食饮料")
        XCTAssertTrue(app.staticTexts["食品酒水 · 零食饮料"].waitForExistence(timeout: 5),
                      "选择子类后表单应同步显示食品酒水 · 零食饮料")

        // Changing the primary refreshes the subcategory column to that
        // primary's children and resets the synced label.
        primaryWheel.pickerWheels.element.adjust(toPickerWheelValue: "交通")
        XCTAssertTrue(app.staticTexts["交通 · 公交地铁"].waitForExistence(timeout: 5),
                      "切换大类后子类应刷新为交通的子类")
        app.buttons["doneCategoryWheel"].tap()
        XCTAssertFalse(app.pickers["primaryCategoryPicker"].exists, "点完成后应回到收起状态")

        // The form is already open; enter the amount and save from here.
        let amountField = app.textFields["0.00"]
        XCTAssertTrue(amountField.waitForExistence(timeout: 5))
        amountField.tap()
        amountField.typeText("23.45")
        app.buttons["保存"].tap()
        assertPersistedRow(category: "交通", amount: "23.45", in: app)
        assertPersistedRow(category: "公交地铁", amount: "23.45", in: app)

        // Rename the primary from the management screen. The historical row
        // keeps its amount and shows the new name, before and after restart.
        app.buttons["分类"].tap()
        let rename = app.buttons["renamePrimary-transport"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        rename.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5), "改名应弹出输入框")
        let field = app.alerts.firstMatch.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("出行")
        app.buttons["保存"].tap()
        app.buttons["完成"].tap()
        assertPersistedRow(category: "出行", amount: "23.45", in: app)
        assertPersistedRow(category: "公交地铁", amount: "23.45", in: app)

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
        app.buttons["addPrimary"].tap()
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
        app.buttons["addPrimary"].tap()
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
        var addSubButtons = app.buttons.allElementsBoundByIndex.filter { $0.label == "新增子类" }
        XCTAssertEqual(addSubButtons.count, 3)
        addSubButtons.last?.tap()
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
        addSubButtons = app.buttons.allElementsBoundByIndex.filter { $0.label == "新增子类" }
        addSubButtons.last?.tap()
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

    // MARK: - Helpers

    private func save(_ amount: String, in app: XCUIApplication) {
        app.buttons["记一笔"].tap()
        let field = app.textFields["0.00"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(amount)
        app.buttons["保存"].tap()
    }

    /// Asserts one ledger row carries BOTH the example category and amount,
    /// checked after save and again after restart.
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
