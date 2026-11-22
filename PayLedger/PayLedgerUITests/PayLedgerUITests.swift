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
