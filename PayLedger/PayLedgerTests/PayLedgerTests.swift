import XCTest
@testable import PayLedger

/// Tests exercise the public ledger API with example amounts only.
/// Real accounts stay on the user's iPhone.
final class PayLedgerTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    // MARK: - Amount entry seam

    func testAmountParserAcceptsYuanAndCents() {
        XCTAssertEqual(AmountInput.parseCents("12.34"), 1234)
        XCTAssertEqual(AmountInput.parseCents("0.05"), 5)
        XCTAssertEqual(AmountInput.parseCents("8"), 800)
    }

    func testAmountParserRejectsInvalidAndNonPositiveInput() {
        for raw in ["", " ", "0", "0.00", "-1", "abc", "12.345", "1e3"] {
            XCTAssertNil(AmountInput.parseCents(raw), "expected \(raw) to be rejected")
        }
    }

    func testAmountParserAcceptsLeadingSeparatorAndCommaDecimal() {
        // A native decimal pad lets the user start at the separator, and a
        // decimal-comma locale emits "," instead of ".". The integer part is
        // omitted (treated as zero) only when the separator is present.
        XCTAssertEqual(AmountInput.parseCents(".05"), 5)
        XCTAssertEqual(AmountInput.parseCents(",05"), 5)
        XCTAssertEqual(AmountInput.parseCents("12,34"), 1234)
        XCTAssertEqual(AmountInput.parseCents("0,05"), 5)
        XCTAssertEqual(AmountInput.parseCents("12.34"), 1234)
    }

    func testAmountParserRejectsGroupingSeparatorsAndMalformedDecimals() {
        // ","/ "." as a thousands grouping has three fraction digits or a
        // second separator; those are not amounts with a decimal fraction.
        for raw in ["1,234", "1.234", "1,234.56", "1.234,56", "1,2,3",
                    ".", ",", "12.", "12,", "-.05"] {
            XCTAssertNil(AmountInput.parseCents(raw), "expected \(raw) to be rejected")
        }
    }

    // MARK: - Persistence seam (app restart)

    func testExpenseIsReadableAfterStoreIsRecreated() throws {
        let store = LedgerStore(fileURL: fileURL)
        try store.addExpense(amountCents: 1234, categoryID: "food")

        let reopened = LedgerStore(fileURL: fileURL)
        XCTAssertEqual(reopened.expenses.count, 1)
        XCTAssertEqual(reopened.expenses.first?.amountCents, 1234)
        XCTAssertEqual(reopened.expenses.first?.categoryID, "food")
    }

    func testStoreRejectsNonPositiveAmount() throws {
        let store = LedgerStore(fileURL: fileURL)
        try store.addExpense(amountCents: 0, categoryID: "food")
        try store.addExpense(amountCents: -100, categoryID: "food")
        XCTAssertTrue(store.expenses.isEmpty)
    }

    // MARK: - Persistence failure seam (write-before-memory, no silent loss)

    func testFailedWriteDoesNotChangeMemoryOrLeavePartialFile() {
        let missingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)", isDirectory: true)
        let badURL = missingDir.appendingPathComponent("ledger.json")
        let store = LedgerStore(fileURL: badURL)

        XCTAssertTrue(store.expenses.isEmpty)
        XCTAssertThrowsError(try store.addExpense(amountCents: 1234, categoryID: "food"))
        XCTAssertTrue(store.expenses.isEmpty, "memory must not change when the write fails")
        XCTAssertFalse(FileManager.default.fileExists(atPath: badURL.path))
    }

    func testUnreadableLedgerIsPreservedAndBlocksWrites() throws {
        let original = "broken ledger".data(using: .utf8)!
        try original.write(to: fileURL)
        let store = LedgerStore(fileURL: fileURL)

        XCTAssertTrue(store.expenses.isEmpty)
        XCTAssertThrowsError(try store.addExpense(amountCents: 1234, categoryID: "food"))
        XCTAssertEqual(try Data(contentsOf: fileURL), original, "original bytes must be preserved")
        XCTAssertTrue(store.expenses.isEmpty)
    }

    // MARK: - Local backup-exclusion + migration seam

    func testLedgerFileIsExcludedFromBackupAfterTwoSaves() throws {
        let store = LedgerStore(fileURL: fileURL)
        try store.addExpense(amountCents: 100, categoryID: "food")
        try store.addExpense(amountCents: 200, categoryID: "transport")

        let values = try fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testLegacyLedgerMigratesBeforeRemovingOriginal() throws {
        let fm = FileManager.default
        let legacy = fm.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString).json")
        let newDir = fm.temporaryDirectory
            .appendingPathComponent("migrated-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        let target = newDir.appendingPathComponent("ledger.json")
        defer {
            try? fm.removeItem(at: legacy)
            try? fm.removeItem(at: newDir)
        }

        let records = [Expense(amountCents: 1234, categoryID: "food", date: Date())]
        let data = try JSONEncoder().encode(records)
        try data.write(to: legacy)

        let store = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertEqual(store.expenses.count, 1)
        XCTAssertEqual(store.expenses.first?.amountCents, 1234)
        XCTAssertEqual(try Data(contentsOf: target), data)
        XCTAssertFalse(fm.fileExists(atPath: legacy.path), "legacy copy removed only after success")
    }

    func testUnreadableLegacyLedgerIsNotRemoved() throws {
        let fm = FileManager.default
        let legacy = fm.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString).json")
        let newDir = fm.temporaryDirectory
            .appendingPathComponent("migrated-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        let target = newDir.appendingPathComponent("ledger.json")
        defer {
            try? fm.removeItem(at: legacy)
            try? fm.removeItem(at: newDir)
        }

        let original = "broken legacy".data(using: .utf8)!
        try original.write(to: legacy)

        let store = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertTrue(store.expenses.isEmpty)
        XCTAssertEqual(try Data(contentsOf: legacy), original, "recoverable legacy kept on failure")
        XCTAssertFalse(fm.fileExists(atPath: target.path))
    }

    func testCurrencyFormatKeepsLargeTotalsExact() {
        // 2,500,000,000.00 yuan = 250,000,000,000 cents. A 32-bit %d
        // renders this as a negative number; the full Int64 value must survive.
        XCTAssertEqual(Currency.format(250_000_000_000), "2500000000.00")
        XCTAssertEqual(Currency.format(1234), "12.34")
        XCTAssertEqual(Currency.format(5), "0.05")
    }

    // MARK: - Summary seam (exact cents + calendar boundaries)

    func testTotalSumsOnlyExpensesInsideTheInterval() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let interval = DateInterval(
            start: cal.date(from: DateComponents(year: 2026, month: 11, day: 1))!,
            end: cal.date(from: DateComponents(year: 2026, month: 12, day: 1))!
        )

        let expenses = [
            Expense(amountCents: 1234, categoryID: "food",
                    date: cal.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))!),
            Expense(amountCents: 500, categoryID: "transport",
                    date: cal.date(from: DateComponents(year: 2026, month: 11, day: 30, hour: 9))!),
            // Exactly at the end boundary — must not be counted.
            Expense(amountCents: 9999, categoryID: "food",
                    date: cal.date(from: DateComponents(year: 2026, month: 12, day: 1, hour: 0))!)
        ]

        XCTAssertEqual(LedgerStats.totalCents(expenses, in: interval), 1734)
    }

    func testWeekIntervalStartsOnMonday() {
        // Use the production calendar + interval helper, not a test-local one,
        // so the Monday rule the app ships with is what is actually verified.
        let wednesday = LedgerStats.calendar.date(
            from: DateComponents(year: 2026, month: 11, day: 18, hour: 10)
        )!
        let interval = LedgerStats.weekInterval(containing: wednesday)!

        XCTAssertEqual(LedgerStats.calendar.component(.weekday, from: interval.start), 2)
        XCTAssertEqual(interval.duration, 7 * 24 * 60 * 60, accuracy: 1)
    }

    // MARK: - Codex re-review: backup exclusion + migration failures

    func testBackupExclusionFailureBlocksSave() {
        let rejecting: (URL) throws -> Void = { _ in throw LedgerStoreError.backupExclusionFailed }
        let store = LedgerStore(fileURL: fileURL, backupExclusion: rejecting)

        XCTAssertTrue(store.expenses.isEmpty)
        XCTAssertThrowsError(try store.addExpense(amountCents: 1234, categoryID: "food")) { error in
            guard case LedgerStoreError.backupExclusionFailed = error else {
                return XCTFail("expected backupExclusionFailed, got \(error)")
            }
        }
        XCTAssertTrue(store.expenses.isEmpty, "an unprotected write must not update memory")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                       "no ledger may be written while it is unprotected")
    }

    func testFailedMigrationBlocksSavingUntilRestart() throws {
        let fm = FileManager.default
        let legacy = fm.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString).json")
        let targetDir = fm.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)", isDirectory: true)
        let target = targetDir.appendingPathComponent("ledger.json")
        defer {
            try? fm.removeItem(at: legacy)
            try? fm.removeItem(at: targetDir)
        }

        let old = [Expense(amountCents: 1234, categoryID: "food", date: Date())]
        let oldData = try JSONEncoder().encode(old)
        try oldData.write(to: legacy)

        // First launch: the target directory is absent, so migration fails.
        let first = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertTrue(first.expenses.isEmpty)
        XCTAssertThrowsError(try first.addExpense(amountCents: 8765, categoryID: "transport")) { error in
            guard case LedgerStoreError.migrationPending = error else {
                return XCTFail("expected migrationPending, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: legacy), oldData, "legacy bytes must be preserved")
        XCTAssertFalse(fm.fileExists(atPath: target.path), "no partial target may be left behind")
        let legacyExclusion = try legacy.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(legacyExclusion.isExcludedFromBackup, true,
                       "the preserved ledger stays backup-excluded after a failed migration")

        // The target becomes writable; a restart completes the migration.
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let reopened = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertEqual(reopened.expenses.count, 1)
        XCTAssertEqual(reopened.expenses.first?.amountCents, 1234)
        try reopened.addExpense(amountCents: 8765, categoryID: "transport")
        XCTAssertEqual(reopened.expenses.count, 2)

        let afterRestart = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertEqual(afterRestart.expenses.count, 2, "old + new counted exactly once")
        XCTAssertEqual(afterRestart.expenses.map(\.amountCents).sorted(), [1234, 8765])
    }

    func testFirstMigrationStagesCommitAndFinalPublishFailurePreservesLegacy() throws {
        let fm = FileManager.default
        let legacy = fm.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString).json")
        let newDir = fm.temporaryDirectory
            .appendingPathComponent("migrated-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        let target = newDir.appendingPathComponent("ledger.json")
        defer {
            try? fm.removeItem(at: legacy)
            try? fm.removeItem(at: newDir)
        }

        let old = [Expense(amountCents: 1234, categoryID: "food", date: Date())]
        let oldData = try JSONEncoder().encode(old)
        try oldData.write(to: legacy)

        // A first migration stages every fallible step, then publishes with
        // an atomic `link` create that fails if the target already exists.
        // A real publish cannot move or delete the original, so the failure
        // seam only short-circuits the publish.
        var hookCalls = 0
        var failPublish = true
        let makeStore = { () -> LedgerStore in
            LedgerStore(fileURL: target, legacyFileURL: legacy, finalPublishFailure: {
                hookCalls += 1
                return failPublish ? TestFinalPublishError.failed : nil
            })
        }

        let first = makeStore()
        XCTAssertEqual(hookCalls, 1, "first migration must go through the staged publish seam")
        XCTAssertEqual(first.expenses.map(\.amountCents), [], "a partial target must never be shown")
        XCTAssertEqual(first.readiness, .needsRecovery)
        XCTAssertThrowsError(try first.addExpense(amountCents: 8765, categoryID: "transport")) { error in
            guard case LedgerStoreError.migrationPending = error else {
                return XCTFail("expected migrationPending, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: legacy), oldData, "legacy bytes survive a failed publish")
        let legacyValues = try legacy.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(legacyValues.isExcludedFromBackup, true, "legacy stays backup-excluded")
        XCTAssertFalse(fm.fileExists(atPath: target.path), "no target before a successful publish")
        let leftovers = (try? fm.contentsOfDirectory(atPath: newDir.path)) ?? []
        XCTAssertFalse(leftovers.contains { LedgerStore.isStagingFile(newDir.appendingPathComponent($0)) },
                       "no staging file may remain after a failed publish")

        // Restart without the failure: migration completes, the old expense is
        // read exactly once, and a new example save is added once.
        failPublish = false
        let reopened = makeStore()
        XCTAssertEqual(reopened.expenses.map(\.amountCents), [1234])
        XCTAssertEqual(reopened.readiness, .ready)
        XCTAssertEqual(try Data(contentsOf: target), oldData)
        XCTAssertFalse(fm.fileExists(atPath: legacy.path), "legacy cleaned up after a successful publish")
        try reopened.addExpense(amountCents: 8765, categoryID: "transport")
        let final = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertEqual(final.expenses.map(\.amountCents).sorted(), [1234, 8765],
                       "old and new each counted exactly once")
    }

    /// Codex cfbe0a7e 规格 1: an atomic publish failure during first migration
    /// must never delete or rewrite a live ledger that already exists. The
    /// counterpart case (target absent throughout the failure) is covered by
    /// `testFirstMigrationStagesCommitAndFinalPublishFailurePreservesLegacy`.
    func testFirstMigrationFailurePreservesTargetThatAppearedBeforePublish() throws {
        let fm = FileManager.default
        let legacy = fm.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString).json")
        let newDir = fm.temporaryDirectory
            .appendingPathComponent("migrated-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        let target = newDir.appendingPathComponent("ledger.json")
        defer {
            try? fm.removeItem(at: legacy)
            try? fm.removeItem(at: newDir)
        }

        let old = [Expense(amountCents: 1234, categoryID: "food", date: Date())]
        let oldData = try JSONEncoder().encode(old)
        try oldData.write(to: legacy)

        // Simulate a valid live ledger appearing at the moment the final
        // publish fails. A real atomic publish cannot create this state, but the
        // failure handler must still leave any existing file byte-for-byte
        // intact rather than treating its presence as a partial migration.
        let appeared = [Expense(amountCents: 8765, categoryID: "transport", date: Date())]
        let appearedData = try JSONEncoder().encode(appeared)
        var hookCalls = 0
        var failPublish = true
        let makeStore = { () -> LedgerStore in
            LedgerStore(fileURL: target, legacyFileURL: legacy, finalPublishFailure: {
                hookCalls += 1
                if failPublish {
                    try? appearedData.write(to: target)
                    return TestFinalPublishError.failed
                }
                return nil
            })
        }

        let first = makeStore()
        XCTAssertEqual(hookCalls, 1, "first migration goes through the staged publish seam")
        XCTAssertTrue(first.expenses.isEmpty, "a partial target must never be shown")
        XCTAssertEqual(first.readiness, .needsRecovery)
        XCTAssertThrowsError(try first.addExpense(amountCents: 500, categoryID: "food")) { error in
            guard case LedgerStoreError.migrationPending = error else {
                return XCTFail("expected migrationPending, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: legacy), oldData, "legacy 12.34 bytes survive the failed publish")
        XCTAssertEqual(try Data(contentsOf: target), appearedData,
                       "an existing target must NOT be deleted or rewritten on publish failure")
        let leftovers = (try? fm.contentsOfDirectory(atPath: newDir.path)) ?? []
        XCTAssertFalse(leftovers.contains { LedgerStore.isStagingFile(newDir.appendingPathComponent($0)) },
                       "no staging file may remain after a failed publish")

        // Restart without the failure: both originals are merged and each
        // example expense is read exactly once; a new save lands once.
        failPublish = false
        let reopened = makeStore()
        XCTAssertEqual(reopened.readiness, .ready)
        XCTAssertEqual(reopened.expenses.map(\.amountCents).sorted(), [1234, 8765],
                       "both originals read exactly once after recovery")
        XCTAssertFalse(fm.fileExists(atPath: legacy.path), "legacy cleaned up after a successful merge")
        try reopened.addExpense(amountCents: 500, categoryID: "food")
        let final = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertEqual(final.expenses.map(\.amountCents).sorted(), [500, 1234, 8765],
                       "the new example expense is added exactly once")
    }

    /// Codex af97063c 规格 2: a first migration judged the target absent, but
    /// a valid live ledger may appear between that check and the publish. A
    /// plain rename would overwrite it and silently lose its expense. The
    /// first-migration publish must fail atomically when the target exists,
    /// keeping both originals and deferring the merge to a restart. No publish
    /// failure is injected here — the hook only stages the competing ledger.
    func testFirstMigrationConflictWithAppearedTargetKeepsBothAndPauses() throws {
        let fm = FileManager.default
        let legacy = fm.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString).json")
        let newDir = fm.temporaryDirectory
            .appendingPathComponent("migrated-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        let target = newDir.appendingPathComponent("ledger.json")
        defer {
            try? fm.removeItem(at: legacy)
            try? fm.removeItem(at: newDir)
        }

        let old = [Expense(amountCents: 1234, categoryID: "food", date: Date())]
        let oldData = try JSONEncoder().encode(old)
        try oldData.write(to: legacy)

        let appeared = [Expense(amountCents: 8765, categoryID: "transport", date: Date())]
        let appearedData = try JSONEncoder().encode(appeared)
        var stageConflict = true
        var hookCalls = 0
        let makeStore = { () -> LedgerStore in
            LedgerStore(fileURL: target, legacyFileURL: legacy, finalPublishFailure: {
                hookCalls += 1
                if stageConflict { try? appearedData.write(to: target) }
                return nil
            })
        }

        let first = makeStore()
        XCTAssertEqual(hookCalls, 1, "the publish must be attempted once")
        XCTAssertTrue(first.expenses.isEmpty, "no partial ledger may be shown")
        XCTAssertEqual(first.readiness, .needsRecovery)
        XCTAssertThrowsError(try first.addExpense(amountCents: 500, categoryID: "food")) { error in
            guard case LedgerStoreError.migrationPending = error else {
                return XCTFail("expected migrationPending, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: legacy), oldData, "legacy 12.34 bytes must be preserved")
        XCTAssertEqual(try Data(contentsOf: target), appearedData,
                       "the appeared 87.65 ledger must NOT be overwritten by the migration")
        let leftovers = (try? fm.contentsOfDirectory(atPath: newDir.path)) ?? []
        XCTAssertFalse(leftovers.contains { LedgerStore.isStagingFile(newDir.appendingPathComponent($0)) },
                       "the conflicted publish's staging file must be cleaned up")

        // Restart without the competing target: the existing merge path reads
        // both originals exactly once, cleans up the legacy copy, and a later
        // example save lands exactly once.
        stageConflict = false
        let reopened = makeStore()
        XCTAssertEqual(reopened.readiness, .ready)
        XCTAssertEqual(reopened.expenses.map(\.amountCents).sorted(), [1234, 8765],
                       "both originals must be read exactly once after conflict recovery")
        XCTAssertFalse(fm.fileExists(atPath: legacy.path), "legacy cleaned up after a successful merge")
        try reopened.addExpense(amountCents: 500, categoryID: "food")
        let final = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertEqual(final.expenses.map(\.amountCents).sorted(), [500, 1234, 8765],
                       "the new example expense is added exactly once")
    }

    func testFirstMigrationDoesNotPublishTargetWhenLegacyProtectionFails() throws {
        let fm = FileManager.default
        let legacy = fm.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString).json")
        let newDir = fm.temporaryDirectory
            .appendingPathComponent("migrated-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        let target = newDir.appendingPathComponent("ledger.json")
        defer {
            try? fm.removeItem(at: legacy)
            try? fm.removeItem(at: newDir)
        }

        let old = [Expense(amountCents: 1234, categoryID: "food", date: Date())]
        let oldData = try JSONEncoder().encode(old)
        try oldData.write(to: legacy)

        // Only the legacy copy's marker is refused: no target may be published
        // while the sole source of truth is unconfirmed as protected.
        let rejectingLegacy: (URL) throws -> Void = { url in
            if url == legacy { throw LedgerStoreError.backupExclusionFailed }
        }
        let first = LedgerStore(fileURL: target, legacyFileURL: legacy, backupExclusion: rejectingLegacy)
        XCTAssertEqual(first.readiness, .needsRecovery)
        XCTAssertTrue(first.expenses.isEmpty, "no partial ledger may be shown")
        XCTAssertEqual(try Data(contentsOf: legacy), oldData, "legacy bytes untouched")
        XCTAssertFalse(fm.fileExists(atPath: target.path), "target must not be published")

        let reopened = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertEqual(reopened.expenses.map(\.amountCents), [1234])
        XCTAssertEqual(reopened.readiness, .ready)
        XCTAssertFalse(fm.fileExists(atPath: legacy.path))
        try reopened.addExpense(amountCents: 8765, categoryID: "transport")
        let final = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertEqual(final.expenses.map(\.amountCents).sorted(), [1234, 8765],
                       "old and new each counted exactly once")
    }

    /// Codex 443dba69 规格 1: a first migration stages and verifies the exact
    /// legacy bytes before publishing. After a successful publish it must go
    /// straight to the shared cleanup — not re-read the live file (which can
    /// fail and trigger a rollback that deletes the just-published ledger) and
    /// not re-apply the legacy copy's marker a second time (a second-call
    /// failure stranded both copies in needsRecovery).
    func testSuccessfulFirstMigrationConfirmsLegacyMarkerOnceAndCleansUp() throws {
        let fm = FileManager.default
        let legacy = fm.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString).json")
        let newDir = fm.temporaryDirectory
            .appendingPathComponent("migrated-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        let target = newDir.appendingPathComponent("ledger.json")
        defer {
            try? fm.removeItem(at: legacy)
            try? fm.removeItem(at: newDir)
        }

        let old = [Expense(amountCents: 1234, categoryID: "food", date: Date())]
        let oldData = try JSONEncoder().encode(old)
        try oldData.write(to: legacy)

        var legacyMarkerCalls = 0
        let countingExclusion: (URL) throws -> Void = { url in
            guard url == legacy else { return }
            legacyMarkerCalls += 1
            // The second confirmation is the redundant one this test guards
            // against; a real platform refusal on that call used to leave
            // both copies on disk and pause accounting.
            if legacyMarkerCalls == 2 {
                throw LedgerStoreError.backupExclusionFailed
            }
        }
        let store = LedgerStore(fileURL: target, legacyFileURL: legacy,
                                backupExclusion: countingExclusion)

        XCTAssertEqual(legacyMarkerCalls, 1,
                       "a successful first migration confirms the legacy marker only once")
        XCTAssertEqual(store.readiness, .ready)
        XCTAssertEqual(store.expenses.map(\.amountCents), [1234])
        XCTAssertEqual(try Data(contentsOf: target), oldData)
        XCTAssertFalse(fm.fileExists(atPath: legacy.path),
                       "legacy cleaned up after a successful publish")

        try store.addExpense(amountCents: 8765, categoryID: "transport")
        let final = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertEqual(final.expenses.map(\.amountCents).sorted(), [1234, 8765],
                       "old and new example expenses each counted exactly once")
    }

    func testUnwritableTargetDuringMigrationKeepsLegacyUntilRestart() throws {
        let fm = FileManager.default
        let legacy = fm.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString).json")
        let newDir = fm.temporaryDirectory.appendingPathComponent("migrated-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        let target = newDir.appendingPathComponent("ledger.json")
        defer {
            try? fm.removeItem(at: legacy)
            try? fm.removeItem(at: newDir)
        }

        let old = [Expense(amountCents: 1234, categoryID: "food", date: Date())]
        let oldData = try JSONEncoder().encode(old)
        try oldData.write(to: legacy)

        let rejecting: (URL) throws -> Void = { _ in throw LedgerStoreError.backupExclusionFailed }
        let first = LedgerStore(fileURL: target, legacyFileURL: legacy, backupExclusion: rejecting)
        XCTAssertTrue(first.expenses.isEmpty)
        XCTAssertThrowsError(try first.addExpense(amountCents: 8765, categoryID: "transport"))
        XCTAssertEqual(try Data(contentsOf: legacy), oldData, "legacy bytes preserved while target is unwritable")
        XCTAssertFalse(fm.fileExists(atPath: target.path))

        let reopened = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertEqual(reopened.expenses.first?.amountCents, 1234, "restart reads the preserved legacy")
    }

    func testLegacyCopyCleanupIsRetriedOnRestart() throws {
        let fm = FileManager.default
        let legacy = fm.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString).json")
        let newDir = fm.temporaryDirectory.appendingPathComponent("migrated-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        let target = newDir.appendingPathComponent("ledger.json")
        defer {
            try? fm.removeItem(at: legacy)
            try? fm.removeItem(at: newDir)
        }

        let records = [Expense(amountCents: 1234, categoryID: "food", date: Date())]
        let data = try JSONEncoder().encode(records)
        try data.write(to: legacy)
        try data.write(to: target)

        let store = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertEqual(store.expenses.count, 1)
        XCTAssertEqual(try Data(contentsOf: target), data)
        XCTAssertFalse(fm.fileExists(atPath: legacy.path), "cleanup retried once both copies verified")
    }

    /// Two already-complete, identical copies exercise the third cleanup path
    /// (distinct from first migration and verified merge). When only the
    /// protected legacy copy's deletion fails, the full ledger stays visible
    /// and writable with `cleanupPending` — the same transition the other two
    /// paths use. A restart retries the deletion and each row is read once.
    func testCompleteCopiesOnlyCleanupFailureKeepsRowsVisibleAndWritable() throws {
        let fm = FileManager.default
        let legacy = fm.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString).json")
        let newDir = fm.temporaryDirectory
            .appendingPathComponent("migrated-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        let target = newDir.appendingPathComponent("ledger.json")
        defer { try? fm.removeItem(at: legacy); try? fm.removeItem(at: newDir) }

        let records = [Expense(amountCents: 1234, categoryID: "food", date: Date())]
        let data = try JSONEncoder().encode(records)
        try data.write(to: legacy)
        try data.write(to: target)

        var failRemoval = true
        let first = LedgerStore(fileURL: target, legacyFileURL: legacy,
                                removeLegacyFile: { _ in if failRemoval { throw TestLegacyRemovalError.failed } })
        XCTAssertEqual(first.expenses.map(\.amountCents), [1234],
                       "the complete ledger stays visible when only deletion fails")
        XCTAssertEqual(first.readiness, .cleanupPending,
                       "only deletion of an already-protected copy failed: accounting stays open")
        XCTAssertTrue(first.legacyCleanupPending, "pending cleanup is reported")
        XCTAssertTrue(fm.fileExists(atPath: legacy.path), "retained copy stays on disk")
        let marker = try legacy.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(marker.isExcludedFromBackup, true, "retained copy stays backup-excluded")

        try first.addExpense(amountCents: 8765, categoryID: "transport")
        XCTAssertEqual(first.expenses.map(\.amountCents).sorted(), [1234, 8765],
                       "writes stay open while cleanup is pending")

        failRemoval = false
        let reopened = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertFalse(fm.fileExists(atPath: legacy.path), "cleanup retried on restart")
        XCTAssertEqual(reopened.readiness, .ready)
        XCTAssertEqual(reopened.expenses.map(\.amountCents).sorted(), [1234, 8765],
                       "each example expense read exactly once after restart")
    }

    func testDivergentLedgersAreMergedAndReadExactlyOnceAfterRestart() throws {
        let fm = FileManager.default
        let legacy = fm.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString).json")
        let newDir = fm.temporaryDirectory.appendingPathComponent("migrated-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        let target = newDir.appendingPathComponent("ledger.json")
        defer {
            try? fm.removeItem(at: legacy)
            try? fm.removeItem(at: newDir)
        }

        // Two ledgers each hold a record the other lacks. The partial target
        // must never be treated as the complete ledger (which would lose 12.34).
        let legacyExpense = Expense(amountCents: 1234, categoryID: "food", date: Date())
        let targetExpense = Expense(amountCents: 8765, categoryID: "transport", date: Date())
        try JSONEncoder().encode([legacyExpense]).write(to: legacy)
        try JSONEncoder().encode([targetExpense]).write(to: target)

        let store = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertEqual(store.expenses.map(\.amountCents).sorted(), [1234, 8765],
                       "both unique records must be present before accounting opens")
        XCTAssertFalse(store.legacyCleanupPending,
                       "a verified merge opens accounting with no pending recovery")
        XCTAssertFalse(fm.fileExists(atPath: legacy.path),
                       "legacy copy removed only after a verified merge")

        let restart = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertEqual(restart.expenses.map(\.amountCents).sorted(), [1234, 8765],
                       "each committed expense appears exactly once after restart")
    }

    func testFailedMergeHidesPartialLedgerAndBlocksWritesUntilRestart() throws {
        let fm = FileManager.default
        let legacy = fm.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString).json")
        let newDir = fm.temporaryDirectory.appendingPathComponent("migrated-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        let target = newDir.appendingPathComponent("ledger.json")
        defer {
            try? fm.removeItem(at: legacy)
            try? fm.removeItem(at: newDir)
        }

        let legacyExpense = Expense(amountCents: 1234, categoryID: "food", date: Date())
        let targetExpense = Expense(amountCents: 8765, categoryID: "transport", date: Date())
        let legacyData = try JSONEncoder().encode([legacyExpense])
        let targetData = try JSONEncoder().encode([targetExpense])
        try legacyData.write(to: legacy)
        try targetData.write(to: target)

        // The staged file's marker is refused, so the merge cannot commit.
        let rejecting: (URL) throws -> Void = { url in
            if LedgerStore.isStagingFile(url) { throw LedgerStoreError.backupExclusionFailed }
        }
        let store = LedgerStore(fileURL: target, legacyFileURL: legacy, backupExclusion: rejecting)
        XCTAssertTrue(store.expenses.isEmpty, "a partial target must not be shown as the complete ledger")
        XCTAssertThrowsError(try store.addExpense(amountCents: 500, categoryID: "food")) { error in
            guard case LedgerStoreError.migrationPending = error else {
                return XCTFail("expected migrationPending, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: legacy), legacyData, "legacy bytes preserved")
        XCTAssertEqual(try Data(contentsOf: target), targetData, "partial target bytes preserved")

        // Markers recovered: a restart completes the merge, both rows align.
        let reopened = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertEqual(reopened.expenses.map(\.amountCents).sorted(), [1234, 8765])
    }

    /// After a verified merge only the protected legacy copy's deletion may
    /// fail. That must stay `cleanupPending` (both rows visible, writes open),
    /// not collapse into `needsRecovery` and hide the already-complete ledger.
    func testMergeThenOnlyLegacyCleanupFailureKeepsRowsVisibleAndWritable() throws {
        let fm = FileManager.default
        let legacy = fm.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString).json")
        let newDir = fm.temporaryDirectory.appendingPathComponent("migrated-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        let target = newDir.appendingPathComponent("ledger.json")
        defer { try? fm.removeItem(at: legacy); try? fm.removeItem(at: newDir) }

        // Target 87.65, legacy 12.34: each holds a record the other lacks, so a
        // verified merge is required before accounting opens.
        let legacyExpense = Expense(amountCents: 1234, categoryID: "food", date: Date())
        let targetExpense = Expense(amountCents: 8765, categoryID: "transport", date: Date())
        try JSONEncoder().encode([legacyExpense]).write(to: legacy)
        try JSONEncoder().encode([targetExpense]).write(to: target)

        var failRemoval = true
        let first = LedgerStore(fileURL: target, legacyFileURL: legacy,
                                removeLegacyFile: { _ in if failRemoval { throw TestLegacyRemovalError.failed } })
        XCTAssertEqual(first.expenses.map(\.amountCents).sorted(), [1234, 8765],
                       "the fully merged ledger must stay visible, not be hidden as recovery")
        XCTAssertEqual(first.readiness, .cleanupPending,
                       "only deletion of an already-protected copy failed: accounting stays open")
        XCTAssertTrue(first.legacyCleanupPending, "pending cleanup is reported")
        XCTAssertTrue(fm.fileExists(atPath: legacy.path), "retained copy stays on disk")
        let marker = try legacy.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(marker.isExcludedFromBackup, true, "retained copy stays backup-excluded")

        // Writes remain allowed while only cleanup is pending.
        try first.addExpense(amountCents: 500, categoryID: "food")
        XCTAssertEqual(first.expenses.map(\.amountCents).sorted(), [500, 1234, 8765])

        // Restart with removal working: cleanup retried, every row read once.
        failRemoval = false
        let reopened = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertFalse(fm.fileExists(atPath: legacy.path), "cleanup retried on restart")
        XCTAssertEqual(reopened.readiness, .ready)
        XCTAssertEqual(reopened.expenses.map(\.amountCents).sorted(), [500, 1234, 8765])
    }

    /// A failure while protecting the retained legacy copy (a distinct phase
    /// from deletion) is still a recovery condition: no partial ledger shown,
    /// writes blocked, original bytes preserved until a restart recovers.
    func testMergeWithLegacyProtectionFailureStillPausesAccounting() throws {
        let fm = FileManager.default
        let legacy = fm.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString).json")
        let newDir = fm.temporaryDirectory.appendingPathComponent("migrated-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        let target = newDir.appendingPathComponent("ledger.json")
        defer { try? fm.removeItem(at: legacy); try? fm.removeItem(at: newDir) }

        let legacyExpense = Expense(amountCents: 1234, categoryID: "food", date: Date())
        let targetExpense = Expense(amountCents: 8765, categoryID: "transport", date: Date())
        let legacyData = try JSONEncoder().encode([legacyExpense])
        try legacyData.write(to: legacy)
        try JSONEncoder().encode([targetExpense]).write(to: target)

        // Commit succeeds, but the legacy copy's marker is refused afterward.
        let rejectingLegacy: (URL) throws -> Void = { url in
            if url == legacy { throw LedgerStoreError.backupExclusionFailed }
        }
        let first = LedgerStore(fileURL: target, legacyFileURL: legacy, backupExclusion: rejectingLegacy)
        XCTAssertEqual(first.readiness, .needsRecovery,
                       "an unconfirmed retained copy pauses accounting")
        XCTAssertTrue(first.expenses.isEmpty, "no partial ledger is presented as complete")
        XCTAssertThrowsError(try first.addExpense(amountCents: 500, categoryID: "food")) { error in
            guard case LedgerStoreError.migrationPending = error else {
                return XCTFail("expected migrationPending, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: legacy), legacyData, "legacy bytes preserved")

        // Markers recovered: a restart completes cleanup and both rows align.
        let reopened = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertFalse(fm.fileExists(atPath: legacy.path))
        XCTAssertEqual(reopened.readiness, .ready)
        XCTAssertEqual(reopened.expenses.map(\.amountCents).sorted(), [1234, 8765])
    }

    func testUndecodableLegacyBlocksSavingUntilReplaced() throws {
        let fm = FileManager.default
        let legacy = fm.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString).json")
        let newDir = fm.temporaryDirectory.appendingPathComponent("migrated-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        let target = newDir.appendingPathComponent("ledger.json")
        defer {
            try? fm.removeItem(at: legacy)
            try? fm.removeItem(at: newDir)
        }

        let original = "broken legacy".data(using: .utf8)!
        try original.write(to: legacy)
        let store = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertTrue(store.expenses.isEmpty)
        XCTAssertThrowsError(try store.addExpense(amountCents: 8765, categoryID: "food")) { error in
            guard case LedgerStoreError.migrationPending = error else {
                return XCTFail("expected migrationPending, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: legacy), original)

        // Recovery: restore a valid legacy file and restart.
        let records = [Expense(amountCents: 1234, categoryID: "food", date: Date())]
        let valid = try JSONEncoder().encode(records)
        try valid.write(to: legacy)
        let recovered = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertEqual(recovered.expenses.first?.amountCents, 1234)
        try recovered.addExpense(amountCents: 8765, categoryID: "transport")
        XCTAssertEqual(recovered.expenses.count, 2)
    }

    // MARK: - Codex re-review: UI test ledger isolation (no default-path reset)

    func testTestLedgerEnvironmentResolvesToIsolatedFile() {
        let url = PayLedgerApp.ledgerFileURL(environment: ["PAYLEDGER_TEST_LEDGER": "uitest-example.json"])
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.lastPathComponent, "uitest-example.json")
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PayLedgerUITests", isDirectory: true)
        XCTAssertEqual(url?.deletingLastPathComponent(), testDirectory)
        XCTAssertEqual(url?.path.hasPrefix(testDirectory.path + "/"), true)
        XCTAssertNotEqual(url, LedgerStore.defaultFileURL)
        XCTAssertNotEqual(url, LedgerStore.legacyDefaultFileURL)
        XCTAssertNil(PayLedgerApp.ledgerFileURL(environment: [:]),
                     "production launches (no env) use the default location")
    }

    func testInvalidTestLedgerConfigStaysIsolated() {
        // A test launch with an invalid name must NOT fall through to the
        // production or legacy ledger — it stays in the test sandbox.
        for name in ["", "ledger.json", "../Documents/ledger.json", "uitest-../ledger.json",
                     "uitest-a/b.json", "uitest-.json", "uitest-a.txt", "uitest a.json"] {
            let url = PayLedgerApp.ledgerFileURL(environment: ["PAYLEDGER_TEST_LEDGER": name])
            let testDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("PayLedgerUITests", isDirectory: true)
            XCTAssertNotNil(url, "an invalid name still needs an isolated ledger, got nil for \(name)")
            XCTAssertEqual(url?.lastPathComponent, "uitest-invalid-config.json",
                           "invalid \(name) must map to the safe fallback")
            XCTAssertEqual(url?.deletingLastPathComponent(), testDirectory)
            XCTAssertNotEqual(url, LedgerStore.defaultFileURL)
            XCTAssertNotEqual(url, LedgerStore.legacyDefaultFileURL)
        }
    }

    func testClockOnlyTestLaunchStaysIsolated() {
        // Only the test clock is supplied: still a test launch, so it must not
        // read, create, or migrate either production ledger path.
        let url = PayLedgerApp.ledgerFileURL(environment: ["PAYLEDGER_TEST_NOW": "2026-11-17T10:00:00"])
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.lastPathComponent, "uitest-invalid-config.json")
        XCTAssertNotEqual(url, LedgerStore.defaultFileURL)
        XCTAssertNotEqual(url, LedgerStore.legacyDefaultFileURL)
    }

    // MARK: - Codex re-review: same-session clock advance, amount range, post-write failure, cleanup

    func testPinnedClockAdvanceMovesToNextDay() throws {
        let pinned = try XCTUnwrap(AppClock.parseOverride("2026-11-17T10:00:00"))
        AppClock.overrideDate = pinned
        defer { AppClock.overrideDate = nil }
        XCTAssertEqual(AppClock.now, pinned)

        AppClock.advanceOverride(by: 1)
        let advanced = try XCTUnwrap(AppClock.overrideDate)
        let cal = LedgerStats.calendar
        XCTAssertEqual(cal.component(.day, from: advanced), 18)
        XCTAssertEqual(cal.component(.month, from: advanced), 11)
        XCTAssertEqual(cal.component(.year, from: advanced), 2026)
    }

    func testAmountParserAcceptsLargeRepresentableAmounts() {
        // Previously capped at nine integer digits; 1,000,000,000.00 fits in
        // Int cents and must be accepted.
        XCTAssertEqual(AmountInput.parseCents("1000000000.00"), 100_000_000_000)
        XCTAssertEqual(AmountInput.parseCents("123456789012.34"), 12_345_678_901_234)
        XCTAssertEqual(AmountInput.parseCents("92233720368547758.07"), Int.max)
    }

    func testAmountParserRejectsUnrepresentableAmounts() {
        for raw in ["92233720368547759.00", "9223372036854775808.00",
                    "99999999999999999999999.99", "12.345", "0.001"] {
            XCTAssertNil(AmountInput.parseCents(raw), "expected \(raw) to be rejected")
        }
    }

    func testSummaryReportsOverflowingTotalAsOutOfRange() {
        let interval = DateInterval(
            start: Date(timeIntervalSinceReferenceDate: 0),
            duration: 24 * 60 * 60
        )
        // 92233720368547758.07 + 0.01 overflows Int cents. The summary must not
        // masquerade the capped value as a real total.
        let expenses = [
            Expense(amountCents: Int.max, categoryID: "food",
                    date: Date(timeIntervalSinceReferenceDate: 10)),
            Expense(amountCents: 1, categoryID: "transport",
                    date: Date(timeIntervalSinceReferenceDate: 20))
        ]
        XCTAssertNil(LedgerStats.totalCents(expenses, in: interval),
                     "an overflowing total is reported as out of range, not capped")
        XCTAssertEqual(LedgerStats.totalCents([expenses[0]], in: interval), Int.max,
                       "an individually representable amount still returns its exact total")
    }

    func testStagingBackupExclusionFailureLeavesLedgerAndMemoryUnchanged() throws {
        let seed = LedgerStore(fileURL: fileURL)
        try seed.addExpense(amountCents: 1234, categoryID: "food")
        let before = try Data(contentsOf: fileURL)

        // Directory marking succeeds; only the staged file's marker is refused.
        // The real ledger must never be replaced in this case.
        let rejecting: (URL) throws -> Void = { url in
            if LedgerStore.isStagingFile(url) { throw LedgerStoreError.backupExclusionFailed }
        }
        let store = LedgerStore(fileURL: fileURL, backupExclusion: rejecting)
        XCTAssertEqual(store.expenses.map(\.amountCents), [1234])
        XCTAssertThrowsError(try store.addExpense(amountCents: 8765, categoryID: "transport")) { error in
            guard case LedgerStoreError.backupExclusionFailed = error else {
                return XCTFail("expected backupExclusionFailed, got \(error)")
            }
        }
        XCTAssertEqual(store.expenses.map(\.amountCents), [1234], "a failed save must not change memory")
        XCTAssertEqual(try Data(contentsOf: fileURL), before, "a failed save must not change ledger bytes")

        let reopened = LedgerStore(fileURL: fileURL)
        XCTAssertEqual(reopened.expenses.map(\.amountCents), [1234],
                       "the failed expense must not appear after restart")
        try reopened.addExpense(amountCents: 8765, categoryID: "transport")
        let final = LedgerStore(fileURL: fileURL)
        XCTAssertEqual(final.expenses.map(\.amountCents).sorted(), [1234, 8765],
                       "a retry after recovery saves the expense exactly once")
    }

    func testFinalPublishFailureLeavesLiveLedgerMemoryAndRestartIntact() throws {
        let seed = LedgerStore(fileURL: fileURL)
        try seed.addExpense(amountCents: 1234, categoryID: "food")
        let originalBytes = try Data(contentsOf: fileURL)

        // A real publish is atomic: on failure it moves or rewrites nothing.
        // The seam may only short-circuit the publish; it must never relocate
        // the original the way replaceItemAt could.
        var failPublish = true
        let makeStore = { () -> LedgerStore in
            LedgerStore(fileURL: self.fileURL, finalPublishFailure: {
                failPublish ? TestFinalPublishError.failed : nil
            })
        }

        let store = makeStore()
        XCTAssertEqual(store.expenses.map(\.amountCents), [1234])
        XCTAssertThrowsError(try store.addExpense(amountCents: 8765, categoryID: "transport")) { error in
            guard case LedgerStoreError.writeFailed(let underlying) = error,
                  underlying is TestFinalPublishError else {
                return XCTFail("expected writeFailed(TestFinalPublishError), got \(error)")
            }
        }
        XCTAssertEqual(store.expenses.map(\.amountCents), [1234],
                       "a failed final publish must not change memory")
        XCTAssertEqual(try Data(contentsOf: fileURL), originalBytes,
                       "the live ledger must stay byte-for-byte unchanged after a failed publish")

        let directory = fileURL.deletingLastPathComponent()
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertFalse(leftovers.contains { LedgerStore.isStagingFile(directory.appendingPathComponent($0)) },
                       "staging files must be cleaned up after a failed publish")

        let reopened = LedgerStore(fileURL: fileURL)
        XCTAssertEqual(reopened.expenses.map(\.amountCents), [1234],
                       "restart must see only the original expense")

        failPublish = false
        let retry = makeStore()
        try retry.addExpense(amountCents: 8765, categoryID: "transport")
        let final = LedgerStore(fileURL: fileURL)
        XCTAssertEqual(final.expenses.map(\.amountCents).sorted(), [1234, 8765],
                       "a retry after recovery saves the expense exactly once")
    }

    func testFailedLegacyRemovalKeepsProtectedCopyAndCleansUpOnRestart() throws {
        let fm = FileManager.default
        let legacy = fm.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString).json")
        let newDir = fm.temporaryDirectory.appendingPathComponent("migrated-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        let target = newDir.appendingPathComponent("ledger.json")
        defer {
            try? fm.removeItem(at: legacy)
            try? fm.removeItem(at: newDir)
        }

        let records = [Expense(amountCents: 1234, categoryID: "food", date: Date())]
        let data = try JSONEncoder().encode(records)
        try data.write(to: legacy)

        var failRemoval = true
        let first = LedgerStore(fileURL: target, legacyFileURL: legacy,
                                removeLegacyFile: { _ in
            if failRemoval { throw TestLegacyRemovalError.failed }
        })
        XCTAssertEqual(first.expenses.map(\.amountCents), [1234], "content is migrated despite cleanup failure")
        XCTAssertEqual(first.readiness, .cleanupPending,
                       "only an already-protected copy's deletion failed: accounting stays open")
        XCTAssertTrue(fm.fileExists(atPath: legacy.path), "the retained copy stays on disk")
        let marker = try legacy.resourceValues(forKeys: [URLResourceKey.isExcludedFromBackupKey])
        XCTAssertEqual(marker.isExcludedFromBackup, true, "the retained copy stays backup-excluded")

        // Recording continues while both copies exist, so their contents diverge.
        try first.addExpense(amountCents: 8765, categoryID: "transport")

        failRemoval = false
        let reopened = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertFalse(fm.fileExists(atPath: legacy.path), "cleanup is retried on restart")
        XCTAssertEqual(reopened.expenses.map(\.amountCents).sorted(), [1234, 8765])

        let after = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertEqual(after.expenses.map(\.amountCents).sorted(), [1234, 8765],
                       "every committed expense appears exactly once")
    }

    func testTargetMarkerFailureKeepsLegacyAndReportsPendingUntilRestart() throws {
        let fm = FileManager.default
        let legacy = fm.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString).json")
        let newDir = fm.temporaryDirectory.appendingPathComponent("migrated-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        let target = newDir.appendingPathComponent("ledger.json")
        defer {
            try? fm.removeItem(at: legacy)
            try? fm.removeItem(at: newDir)
        }

        let records = [Expense(amountCents: 1234, categoryID: "food", date: Date())]
        let data = try JSONEncoder().encode(records)
        try data.write(to: legacy)
        try data.write(to: target)

        // Both copies exist; the target's marker is refused, so cleanup must
        // be deferred and the recovery state reported.
        let rejectingTarget: (URL) throws -> Void = { url in
            if url == target { throw LedgerStoreError.backupExclusionFailed }
        }
        let first = LedgerStore(fileURL: target, legacyFileURL: legacy, backupExclusion: rejectingTarget)
        XCTAssertTrue(first.legacyCleanupPending, "a failed target marker must be reported")
        XCTAssertEqual(first.readiness, .needsRecovery,
                       "an unconfirmed target copy pauses accounting")
        XCTAssertTrue(fm.fileExists(atPath: legacy.path), "recoverable copy is retained")

        // The target copy is unprotected, so writes are blocked while the two
        // copies still exist; the legacy copy must not be dropped.
        XCTAssertThrowsError(try first.addExpense(amountCents: 8765, categoryID: "transport")) { error in
            guard case LedgerStoreError.recoveryRequired = error else {
                return XCTFail("expected recoveryRequired, got \(error)")
            }
        }
        XCTAssertTrue(fm.fileExists(atPath: legacy.path))

        // Restart with markers working: recovery completes and each expense is
        // read exactly once.
        let reopened = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertFalse(reopened.legacyCleanupPending)
        XCTAssertEqual(reopened.readiness, .ready)
        XCTAssertFalse(fm.fileExists(atPath: legacy.path), "cleanup runs after marker recovery")
        XCTAssertEqual(reopened.expenses.map(\.amountCents).sorted(), [1234])
    }

    func testLegacyMarkerFailureKeepsCopyAndReportsPendingUntilRestart() throws {
        let fm = FileManager.default
        let legacy = fm.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString).json")
        let newDir = fm.temporaryDirectory.appendingPathComponent("migrated-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        let target = newDir.appendingPathComponent("ledger.json")
        defer {
            try? fm.removeItem(at: legacy)
            try? fm.removeItem(at: newDir)
        }

        let records = [Expense(amountCents: 1234, categoryID: "food", date: Date())]
        let data = try JSONEncoder().encode(records)
        try data.write(to: legacy)
        try data.write(to: target)

        // Only the legacy copy's marker is refused; the copy must be kept and
        // the state reported rather than treating cleanup as successful.
        let rejectingLegacy: (URL) throws -> Void = { url in
            if url == legacy { throw LedgerStoreError.backupExclusionFailed }
        }
        let first = LedgerStore(fileURL: target, legacyFileURL: legacy, backupExclusion: rejectingLegacy)
        XCTAssertTrue(first.legacyCleanupPending)
        XCTAssertEqual(first.readiness, .needsRecovery,
                       "an unprotected retained copy pauses accounting")
        XCTAssertThrowsError(try first.addExpense(amountCents: 8765, categoryID: "transport"))
        XCTAssertTrue(fm.fileExists(atPath: legacy.path))
        XCTAssertEqual(first.expenses.map(\.amountCents), [1234])

        let reopened = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertFalse(reopened.legacyCleanupPending)
        XCTAssertEqual(reopened.readiness, .ready)
        XCTAssertFalse(fm.fileExists(atPath: legacy.path), "cleanup runs after legacy marker recovery")
        XCTAssertEqual(reopened.expenses.map(\.amountCents), [1234])
    }

    // MARK: - Codex re-review: entry-level isolation (production paths untouched)

    func testInvalidTestLaunchNeverTouchesProductionLedgers() throws {
        let fm = FileManager.default
        let prodDir = fm.temporaryDirectory
            .appendingPathComponent("prod-\(UUID().uuidString)", isDirectory: true)
        let legacyDir = fm.temporaryDirectory
            .appendingPathComponent("legacy-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: prodDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        let prodFile = prodDir.appendingPathComponent("ledger.json")
        let legacyFile = legacyDir.appendingPathComponent("ledger.json")
        defer {
            try? fm.removeItem(at: prodDir)
            try? fm.removeItem(at: legacyDir)
        }

        // Only example amounts ever touch these sentinel paths.
        let prodBytes = try JSONEncoder().encode(
            [Expense(amountCents: 1234, categoryID: "food", date: Date())])
        let legacyBytes = try JSONEncoder().encode(
            [Expense(amountCents: 8765, categoryID: "transport", date: Date())])
        try prodBytes.write(to: prodFile)
        try legacyBytes.write(to: legacyFile)

        let fallback = fm.temporaryDirectory
            .appendingPathComponent("PayLedgerUITests/uitest-invalid-config.json")

        for environment in [
            ["PAYLEDGER_TEST_LEDGER": "ledger.json"],
            ["PAYLEDGER_TEST_NOW": "2026-11-17T10:00:00"]
        ] {
            try? fm.removeItem(at: fallback)
            let store = PayLedgerApp.makeStore(
                environment: environment,
                productionFileURL: prodFile,
                legacyFileURL: legacyFile)

            XCTAssertTrue(store.expenses.isEmpty,
                          "an invalid test config must open an isolated empty ledger")
            XCTAssertEqual(try Data(contentsOf: prodFile), prodBytes,
                           "the production ledger must not be read or written")
            XCTAssertEqual(try Data(contentsOf: legacyFile), legacyBytes,
                           "the legacy ledger must not be migrated or removed")
            XCTAssertTrue(fm.fileExists(atPath: legacyFile.path),
                          "the legacy ledger must survive an invalid test launch")
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: prodDir.path).count, 1,
                           "no extra ledger file may appear in the production directory")
        }
    }

    func testValidTestLaunchRestartReadsBackThroughEntry() throws {
        let fm = FileManager.default
        let name = "uitest-\(UUID().uuidString).json"
        let prodDir = fm.temporaryDirectory
            .appendingPathComponent("prod-\(UUID().uuidString)", isDirectory: true)
        let legacyDir = fm.temporaryDirectory
            .appendingPathComponent("legacy-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: prodDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        let prodFile = prodDir.appendingPathComponent("ledger.json")
        let legacyFile = legacyDir.appendingPathComponent("ledger.json")
        let injectedFile = fm.temporaryDirectory
            .appendingPathComponent("PayLedgerUITests/\(name)")
        defer {
            try? fm.removeItem(at: injectedFile)
            try? fm.removeItem(at: prodDir)
            try? fm.removeItem(at: legacyDir)
        }

        let environment = ["PAYLEDGER_TEST_LEDGER": name]
        let first = PayLedgerApp.makeStore(
            environment: environment, productionFileURL: prodFile, legacyFileURL: legacyFile)
        XCTAssertTrue(first.expenses.isEmpty)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: prodDir.path).count, 0)
        try first.addExpense(amountCents: 1234, categoryID: "food")

        let reopened = PayLedgerApp.makeStore(
            environment: environment, productionFileURL: prodFile, legacyFileURL: legacyFile)
        XCTAssertEqual(reopened.expenses.map(\.amountCents), [1234],
                       "the same test config must read back the isolated example ledger")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: prodDir.path).count, 0,
                       "a valid test launch must not create a production ledger")
    }

    func testStateOnlyTestLaunchStaysIsolatedThroughEntryFactory() throws {
        // A launch carrying only PAYLEDGER_TEST_STATE is still a test launch.
        // It must apply the example state in the isolated sandbox and never
        // read, create, or migrate either production ledger.
        let fm = FileManager.default
        let prodDir = fm.temporaryDirectory
            .appendingPathComponent("prod-\(UUID().uuidString)", isDirectory: true)
        let legacyDir = fm.temporaryDirectory
            .appendingPathComponent("legacy-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: prodDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        let prodFile = prodDir.appendingPathComponent("ledger.json")
        let legacyFile = legacyDir.appendingPathComponent("ledger.json")
        let fallback = fm.temporaryDirectory
            .appendingPathComponent("PayLedgerUITests/uitest-invalid-config.json")
        defer {
            try? fm.removeItem(at: fallback)
            try? fm.removeItem(at: prodDir)
            try? fm.removeItem(at: legacyDir)
        }

        // Sentinel bytes use example amounts only; real accounts stay on device.
        let prodBytes = try JSONEncoder().encode(
            [Expense(amountCents: 1234, categoryID: "food", date: Date())])
        let legacyBytes = try JSONEncoder().encode(
            [Expense(amountCents: 8765, categoryID: "transport", date: Date())])
        try prodBytes.write(to: prodFile)
        try legacyBytes.write(to: legacyFile)

        try? fm.removeItem(at: fallback)
        let store = PayLedgerApp.makeStore(
            environment: ["PAYLEDGER_TEST_STATE": "unreadable"],
            productionFileURL: prodFile,
            legacyFileURL: legacyFile)

        XCTAssertEqual(store.readiness, .needsRecovery,
                       "a state-only launch must apply the example state on the isolated ledger")
        XCTAssertEqual(try Data(contentsOf: prodFile), prodBytes,
                       "the production ledger must not be read or written")
        XCTAssertEqual(try Data(contentsOf: legacyFile), legacyBytes,
                       "the legacy ledger must not be migrated or removed")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: prodDir.path).count, 1,
                       "no extra ledger file may appear in the production directory")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: legacyDir.path).count, 1,
                       "no extra ledger file may appear in the legacy directory")
    }

    // MARK: - Codex decision: recovery state (paused vs cleanup-only)

    func testNormalLaunchIsReadyAndAllowsWriting() throws {
        let store = LedgerStore(fileURL: fileURL)
        XCTAssertEqual(store.readiness, .ready)
        try store.addExpense(amountCents: 1234, categoryID: "food")
        XCTAssertEqual(store.expenses.map(\.amountCents), [1234])
    }

    func testUnreadableLedgerPausesAccountingIncludingWrites() throws {
        let broken = "broken example ledger".data(using: .utf8)!
        try broken.write(to: fileURL)
        let store = LedgerStore(fileURL: fileURL)

        XCTAssertEqual(store.readiness, .needsRecovery)
        XCTAssertEqual(store.expenses.count, 0,
                       "an unreadable ledger is not presented as an empty/zero ledger")
        XCTAssertThrowsError(try store.addExpense(amountCents: 8765, categoryID: "food")) { error in
            guard case LedgerStoreError.recoveryRequired = error else {
                return XCTFail("expected recoveryRequired, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), broken, "original bytes preserved")
    }

    func testFailedMigrationPausesAccountingUntilRestart() throws {
        let fm = FileManager.default
        let legacy = fm.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString).json")
        let targetDir = fm.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)", isDirectory: true)
        let target = targetDir.appendingPathComponent("ledger.json")
        defer { try? fm.removeItem(at: legacy); try? fm.removeItem(at: targetDir) }

        try JSONEncoder().encode([Expense(amountCents: 1234, categoryID: "food", date: Date())])
            .write(to: legacy)

        let first = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertEqual(first.readiness, .needsRecovery)
        XCTAssertThrowsError(try first.addExpense(amountCents: 8765, categoryID: "transport"))

        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let reopened = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertEqual(reopened.readiness, .ready)
        XCTAssertEqual(reopened.expenses.map(\.amountCents), [1234])
    }

    func testIncompleteRecordsPauseAccounting() throws {
        let fm = FileManager.default
        let legacy = fm.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString).json")
        let newDir = fm.temporaryDirectory.appendingPathComponent("migrated-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        let target = newDir.appendingPathComponent("ledger.json")
        defer { try? fm.removeItem(at: legacy); try? fm.removeItem(at: newDir) }

        // Both copies exist, but the target cannot be decoded — records are
        // incomplete and must not be shown or written as a full ledger.
        try JSONEncoder().encode([Expense(amountCents: 1234, categoryID: "food", date: Date())])
            .write(to: legacy)
        try Data("broken target".utf8).write(to: target)

        let store = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertEqual(store.readiness, .needsRecovery)
        XCTAssertThrowsError(try store.addExpense(amountCents: 8765, categoryID: "transport"))
    }

    func testOnlyCleanupFailureKeepsAccountingOpenAndRetriesOnRestart() throws {
        let fm = FileManager.default
        let legacy = fm.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString).json")
        let newDir = fm.temporaryDirectory.appendingPathComponent("migrated-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        let target = newDir.appendingPathComponent("ledger.json")
        defer { try? fm.removeItem(at: legacy); try? fm.removeItem(at: newDir) }

        try JSONEncoder().encode([Expense(amountCents: 1234, categoryID: "food", date: Date())])
            .write(to: legacy)

        var failRemoval = true
        let first = LedgerStore(fileURL: target, legacyFileURL: legacy,
                                removeLegacyFile: { _ in if failRemoval { throw TestLegacyRemovalError.failed } })
        XCTAssertEqual(first.readiness, .cleanupPending)
        // Writes remain allowed while only cleanup is pending.
        try first.addExpense(amountCents: 8765, categoryID: "transport")
        XCTAssertEqual(first.expenses.map(\.amountCents).sorted(), [1234, 8765])

        failRemoval = false
        let reopened = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertEqual(reopened.readiness, .ready)
        XCTAssertFalse(fm.fileExists(atPath: legacy.path))
        XCTAssertEqual(reopened.expenses.map(\.amountCents).sorted(), [1234, 8765])
    }
    // MARK: - Codex re-review: a single on-device ledger must confirm protection

    func testExistingSingleLedgerNeedsRecoveryWhenProtectionCannotBeConfirmed() throws {
        // A production ledger stands alone (no legacy copy). If the platform
        // will not confirm its backup exclusion or a protected directory,
        // accounting must pause instead of reporting `ready`.
        let records = [Expense(amountCents: 1234, categoryID: "food", date: Date())]
        let original = try JSONEncoder().encode(records)
        try original.write(to: fileURL)

        let ledger = fileURL!
        let refusing: (URL) throws -> Void = { url in
            if url == ledger || url == ledger.deletingLastPathComponent() {
                throw LedgerStoreError.backupExclusionFailed
            }
        }
        let store = LedgerStore(fileURL: ledger, backupExclusion: refusing)
        XCTAssertEqual(store.readiness, .needsRecovery,
                       "an unconfirmable single ledger must pause accounting")
        XCTAssertEqual(store.expenses.map(\.amountCents), [1234],
                       "the original record stays visible for recovery")
        XCTAssertThrowsError(try store.addExpense(amountCents: 8765, categoryID: "transport")) { error in
            guard case LedgerStoreError.recoveryRequired = error else {
                return XCTFail("expected recoveryRequired, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), original, "original bytes preserved")

        // Protection recovered: a restart reads the original record and opens
        // accounting, and a new example expense is saved exactly once.
        let reopened = LedgerStore(fileURL: fileURL)
        XCTAssertEqual(reopened.readiness, .ready)
        XCTAssertEqual(reopened.expenses.map(\.amountCents), [1234])
        try reopened.addExpense(amountCents: 8765, categoryID: "transport")
        let after = LedgerStore(fileURL: fileURL)
        XCTAssertEqual(after.expenses.map(\.amountCents).sorted(), [1234, 8765])
    }

    func testExistingSingleLedgerStaysReadyWhenOnlyOneProtectionIsConfirmable() throws {
        // The ledger file's marker is refused, but its directory is protected.
        // That directory covers the file during atomic renames, so a single
        // confirmable protection is enough to keep accounting open.
        let records = [Expense(amountCents: 1234, categoryID: "food", date: Date())]
        try JSONEncoder().encode(records).write(to: fileURL)

        let ledger = fileURL!
        let refusingFileOnly: (URL) throws -> Void = { url in
            if url == ledger { throw LedgerStoreError.backupExclusionFailed }
        }
        let store = LedgerStore(fileURL: ledger, backupExclusion: refusingFileOnly)
        XCTAssertEqual(store.readiness, .ready,
                       "a protected directory alone confirms protection of a single ledger")
        try store.addExpense(amountCents: 8765, categoryID: "transport")
        XCTAssertEqual(store.expenses.map(\.amountCents).sorted(), [1234, 8765])
    }

    func testExistingSingleLedgerNeedsRecoveryWhenDirectoryProtectionCannotBeConfirmed() throws {
        // The file's own backup-exclusion marker can be confirmed, but the
        // directory where a staged save is written cannot. `commit` refuses to
        // publish without a protected directory, so every save would fail
        // while the home view still looked `ready`. Startup must pause.
        let records = [Expense(amountCents: 1234, categoryID: "food", date: Date())]
        let original = try JSONEncoder().encode(records)
        try original.write(to: fileURL)

        let ledger = fileURL!
        let directory = ledger.deletingLastPathComponent()
        let refusingDirectoryOnly: (URL) throws -> Void = { url in
            if url == directory { throw LedgerStoreError.backupExclusionFailed }
        }
        let store = LedgerStore(fileURL: ledger, backupExclusion: refusingDirectoryOnly)
        XCTAssertEqual(store.readiness, .needsRecovery,
                       "a ledger whose directory cannot be protected must pause accounting")
        XCTAssertEqual(store.expenses.map(\.amountCents), [1234],
                       "the original record stays visible for recovery")
        XCTAssertThrowsError(try store.addExpense(amountCents: 8765, categoryID: "transport")) { error in
            guard case LedgerStoreError.recoveryRequired = error else {
                return XCTFail("expected recoveryRequired, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: ledger), original, "original bytes preserved")

        // Directory protection recovered: a restart reads the original record
        // and a new example expense is saved exactly once.
        let reopened = LedgerStore(fileURL: ledger)
        XCTAssertEqual(reopened.readiness, .ready)
        XCTAssertEqual(reopened.expenses.map(\.amountCents), [1234])
        try reopened.addExpense(amountCents: 8765, categoryID: "transport")
        let after = LedgerStore(fileURL: ledger)
        XCTAssertEqual(after.expenses.map(\.amountCents).sorted(), [1234, 8765])
    }

    func testRefusedDirectoryStillMarksExistingLedgerFile() throws {
        // Codex 443dba69 规范 1: a refused directory pauses accounting, but the
        // single on-device ledger file may still be permitted its own marker.
        // Best-effort protection of that file must not be skipped.
        let records = [Expense(amountCents: 1234, categoryID: "food", date: Date())]
        let original = try JSONEncoder().encode(records)
        try original.write(to: fileURL)

        let ledger = fileURL!
        let directory = ledger.deletingLastPathComponent()
        var fileMarkerCalls = 0
        let refusingDirectoryOnly: (URL) throws -> Void = { url in
            if url == directory { throw LedgerStoreError.backupExclusionFailed }
            if url == ledger { fileMarkerCalls += 1 }
        }
        let store = LedgerStore(fileURL: ledger, backupExclusion: refusingDirectoryOnly)
        XCTAssertEqual(fileMarkerCalls, 1,
                       "the existing ledger file's marker must still be applied when only its directory is refused")
        XCTAssertEqual(store.readiness, .needsRecovery,
                       "a refused directory still pauses accounting")
        XCTAssertEqual(try Data(contentsOf: ledger), original, "original bytes preserved")
        XCTAssertThrowsError(try store.addExpense(amountCents: 8765, categoryID: "transport")) { error in
            guard case LedgerStoreError.recoveryRequired = error else {
                return XCTFail("expected recoveryRequired, got \(error)")
            }
        }

        // Directory protection recovered: a restart reads the original record
        // and a new example expense is saved exactly once.
        let reopened = LedgerStore(fileURL: ledger)
        XCTAssertEqual(reopened.readiness, .ready)
        XCTAssertEqual(reopened.expenses.map(\.amountCents), [1234])
        try reopened.addExpense(amountCents: 8765, categoryID: "transport")
        let after = LedgerStore(fileURL: ledger)
        XCTAssertEqual(after.expenses.map(\.amountCents).sorted(), [1234, 8765])
    }

    // MARK: - Codex af97063c 规范 1: file marking uses the launch observation

    /// A launch first reads a valid ledger, the read during the marking phase
    /// reports a definite absence, and the protection-phase read sees the
    /// ledger again with the directory marker refused. The file must still get
    /// its best-effort marker: accounting was opened against the ledger seen
    /// at launch, so a later absent read cannot silently skip protection.
    func testBestEffortMarkerUsesLaunchPresenceWhenMarkingReadSaysAbsent() throws {
        let records = [Expense(amountCents: 8765, categoryID: "food", date: Date())]
        let original = try JSONEncoder().encode(records)
        try original.write(to: fileURL)
        let ledger = fileURL!
        let directory = ledger.deletingLastPathComponent()

        // Read 1 = data read (valid ledger); read 2 = best-effort marking phase
        // (definite absence); read 3 = protection confirmation (valid again).
        var readCalls = 0
        let presentThenAbsentThenPresent: (URL) throws -> Data = { url in
            readCalls += 1
            if readCalls == 2 {
                throw NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: nil) // NSFileNoSuchFileError
            }
            return try Data(contentsOf: url)
        }
        var fileMarkerCalls = 0
        let refusingDirectoryOnly: (URL) throws -> Void = { url in
            if url == directory { throw LedgerStoreError.backupExclusionFailed }
            if url == ledger { fileMarkerCalls += 1 }
        }
        let store = LedgerStore(fileURL: ledger,
                                backupExclusion: refusingDirectoryOnly,
                                readLedgerFile: presentThenAbsentThenPresent)
        XCTAssertEqual(fileMarkerCalls, 1,
                       "the ledger observed at launch must be marked even if a later read says absent")
        XCTAssertEqual(store.readiness, .needsRecovery,
                       "a refused directory still pauses accounting")
        XCTAssertEqual(store.expenses.map(\.amountCents), [8765],
                       "the record read at launch stays visible under recovery")
        XCTAssertThrowsError(try store.addExpense(amountCents: 500, categoryID: "transport")) { error in
            guard case LedgerStoreError.recoveryRequired = error else {
                return XCTFail("expected recoveryRequired, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: ledger), original, "original bytes preserved")

        // Protection recovered: a restart reads the original once and a new
        // example expense is saved exactly once.
        let reopened = LedgerStore(fileURL: ledger)
        XCTAssertEqual(reopened.readiness, .ready)
        XCTAssertEqual(reopened.expenses.map(\.amountCents), [8765])
        try reopened.addExpense(amountCents: 500, categoryID: "transport")
        let after = LedgerStore(fileURL: ledger)
        XCTAssertEqual(after.expenses.map(\.amountCents).sorted(), [500, 8765],
                       "original and new example expenses each counted once")
    }

    // MARK: - Codex 8750812d 规范 1: the last read still marks a discovered file

    /// Launch loading and the marking read both see a definite absence, but
    /// the final protection read discovers the real 87.65 ledger. Inconsistent
    /// reads pause accounting, yet a file just discovered before the recovery
    /// decision must still get its best-effort backup-exclusion marker — an
    /// on-device ledger must never be left unprotected because a read was late.
    func testProtectionReadDiscoversLedgerStillMarksItAndPauses() throws {
        let records = [Expense(amountCents: 8765, categoryID: "food", date: Date())]
        let original = try JSONEncoder().encode(records)
        try original.write(to: fileURL)
        let ledger = fileURL!
        let directory = ledger.deletingLastPathComponent()

        // Read 1 = load (absent), read 2 = marking (absent), read 3 = protection
        // (the real ledger, discovered only at the last read).
        var readCalls = 0
        let absentAbsentThenPresent: (URL) throws -> Data = { url in
            readCalls += 1
            if readCalls <= 2 {
                throw NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: nil) // NSFileNoSuchFileError
            }
            return try Data(contentsOf: url)
        }
        var fileMarkerCalls = 0
        let refusingDirectoryOnly: (URL) throws -> Void = { url in
            if url == directory { throw LedgerStoreError.backupExclusionFailed }
            if url == ledger { fileMarkerCalls += 1 }
        }
        let store = LedgerStore(fileURL: ledger,
                                backupExclusion: refusingDirectoryOnly,
                                readLedgerFile: absentAbsentThenPresent)
        XCTAssertEqual(fileMarkerCalls, 1,
                       "the ledger discovered at the protection read must still be marked")
        XCTAssertEqual(store.readiness, .needsRecovery,
                       "reads that disagree pause accounting")
        XCTAssertTrue(store.expenses.isEmpty,
                      "a ledger first seen at protection time is not loaded as a snapshot")
        XCTAssertThrowsError(try store.addExpense(amountCents: 500, categoryID: "transport")) { error in
            guard case LedgerStoreError.recoveryRequired = error else {
                return XCTFail("expected recoveryRequired, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: ledger), original, "original bytes preserved")

        // Protection and reads recovered: a restart loads the original once,
        // and a new example expense is saved exactly once.
        let reopened = LedgerStore(fileURL: ledger)
        XCTAssertEqual(reopened.readiness, .ready)
        XCTAssertEqual(reopened.expenses.map(\.amountCents), [8765])
        try reopened.addExpense(amountCents: 500, categoryID: "transport")
        let after = LedgerStore(fileURL: ledger)
        XCTAssertEqual(after.expenses.map(\.amountCents).sorted(), [500, 8765],
                       "original and new example expenses each counted once")
    }

    // MARK: - Codex 443dba69 规格 2: fileExists == false must not mean "first run"

    /// A legacy ledger whose path cannot be inspected (permission denied) is
    /// not an absent ledger. Reporting it as absent would publish a new target
    /// that silently drops the 12.34 record.
    func testInaccessibleLegacyLedgerIsNotTreatedAsFirstRun() throws {
        let fm = FileManager.default
        let legacyDir = fm.temporaryDirectory
            .appendingPathComponent("legacy-dir-\(UUID().uuidString)", isDirectory: true)
        let targetDir = fm.temporaryDirectory
            .appendingPathComponent("target-dir-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let legacy = legacyDir.appendingPathComponent("ledger.json")
        let target = targetDir.appendingPathComponent("ledger.json")
        defer {
            try? fm.removeItem(at: legacyDir)
            try? fm.removeItem(at: targetDir)
        }

        let old = [Expense(amountCents: 1234, categoryID: "food", date: Date())]
        let oldData = try JSONEncoder().encode(old)
        try oldData.write(to: legacy)

        let denied = NSError(domain: NSCocoaErrorDomain, code: 257, userInfo: nil) // NSFileReadNoPermissionError
        let blocking: (URL) throws -> Data = { url in
            if url == legacy { throw denied }
            return try Data(contentsOf: url)
        }
        let first = LedgerStore(fileURL: target, legacyFileURL: legacy, readLedgerFile: blocking)
        XCTAssertEqual(first.readiness, .needsRecovery)
        XCTAssertTrue(first.expenses.isEmpty, "no partial ledger may be shown")
        XCTAssertThrowsError(try first.addExpense(amountCents: 8765, categoryID: "transport"))
        XCTAssertEqual(try Data(contentsOf: legacy), oldData, "legacy bytes preserved")
        XCTAssertFalse(fm.fileExists(atPath: target.path), "no target published from an unreadable legacy")

        // Access restored: the original record is read once and a new save once.
        let reopened = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertEqual(reopened.readiness, .ready)
        XCTAssertEqual(reopened.expenses.map(\.amountCents), [1234])
        try reopened.addExpense(amountCents: 8765, categoryID: "transport")
        let after = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertEqual(after.expenses.map(\.amountCents).sorted(), [1234, 8765],
                       "legacy and new example expenses each counted once")
    }

    /// An existing on-device ledger whose path cannot be inspected is not a
    /// first run. It must pause accounting rather than show an empty ledger.
    func testInaccessibleTargetLedgerIsNotTreatedAsFirstRun() throws {
        let records = [Expense(amountCents: 1234, categoryID: "food", date: Date())]
        let original = try JSONEncoder().encode(records)
        try original.write(to: fileURL)
        let ledger = fileURL!
        let denied = NSError(domain: NSCocoaErrorDomain, code: 257, userInfo: nil)
        let blocking: (URL) throws -> Data = { url in
            if url == ledger { throw denied }
            return try Data(contentsOf: url)
        }

        let store = LedgerStore(fileURL: ledger, readLedgerFile: blocking)
        XCTAssertEqual(store.readiness, .needsRecovery)
        XCTAssertTrue(store.expenses.isEmpty)
        XCTAssertThrowsError(try store.addExpense(amountCents: 8765, categoryID: "transport"))
        XCTAssertEqual(try Data(contentsOf: ledger), original, "existing ledger bytes untouched")

        let reopened = LedgerStore(fileURL: ledger)
        XCTAssertEqual(reopened.readiness, .ready)
        XCTAssertEqual(reopened.expenses.map(\.amountCents), [1234])
        try reopened.addExpense(amountCents: 8765, categoryID: "transport")
        let after = LedgerStore(fileURL: ledger)
        XCTAssertEqual(after.expenses.map(\.amountCents).sorted(), [1234, 8765],
                       "original and new example expenses each counted once")
    }

    /// An explicit "no such file" read is a genuine first run, not a recovery
    /// condition — only a definite absence may enter the first-use path.
    func testNoSuchFileReadStillOpensFirstRun() throws {
        let store = LedgerStore(fileURL: fileURL, readLedgerFile: { _ in
            throw NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: nil) // NSFileNoSuchFileError
        })
        XCTAssertEqual(store.readiness, .ready)
        XCTAssertTrue(store.expenses.isEmpty)
        try store.addExpense(amountCents: 1234, categoryID: "food")
        XCTAssertEqual(store.expenses.map(\.amountCents), [1234])
    }

    // MARK: - Codex cfbe0a7e 规范 1: file marking is independent of readability

    /// A single on-device ledger whose bytes cannot be read (permission
    /// denied) still carries a backup-exclusion marker whenever the platform
    /// permits it. Marking must not be skipped just because the path is
    /// unreadable; the ledger stays in recovery and its bytes are preserved.
    func testUnreadableSingleLedgerFileStillGetsBestEffortMarker() throws {
        let records = [Expense(amountCents: 1234, categoryID: "food", date: Date())]
        let original = try JSONEncoder().encode(records)
        try original.write(to: fileURL)

        let ledger = fileURL!
        let directory = ledger.deletingLastPathComponent()
        let denied = NSError(domain: NSCocoaErrorDomain, code: 257, userInfo: nil) // NSFileReadNoPermissionError
        let blocking: (URL) throws -> Data = { url in
            if url == ledger { throw denied }
            return try Data(contentsOf: url)
        }
        var fileMarkerCalls = 0
        let refusingDirectoryOnly: (URL) throws -> Void = { url in
            if url == directory { throw LedgerStoreError.backupExclusionFailed }
            if url == ledger { fileMarkerCalls += 1 }
        }
        let store = LedgerStore(fileURL: ledger,
                                backupExclusion: refusingDirectoryOnly,
                                readLedgerFile: blocking)
        XCTAssertEqual(fileMarkerCalls, 1,
                       "an existing ledger must be marked even when its bytes cannot be read")
        XCTAssertEqual(store.readiness, .needsRecovery, "unreadable ledger stays in recovery")
        XCTAssertTrue(store.expenses.isEmpty, "no partial ledger may be shown")
        XCTAssertThrowsError(try store.addExpense(amountCents: 8765, categoryID: "transport")) { error in
            guard case LedgerStoreError.recoveryRequired = error else {
                return XCTFail("expected recoveryRequired, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: ledger), original, "original bytes preserved")

        // Access restored: a restart reads the original once and a new save once.
        let reopened = LedgerStore(fileURL: ledger)
        XCTAssertEqual(reopened.readiness, .ready)
        XCTAssertEqual(reopened.expenses.map(\.amountCents), [1234])
        try reopened.addExpense(amountCents: 8765, categoryID: "transport")
        let after = LedgerStore(fileURL: ledger)
        XCTAssertEqual(after.expenses.map(\.amountCents).sorted(), [1234, 8765],
                       "original and new example expenses each counted once")
    }

    /// During migration, an unreadable target path must still get a best-effort
    /// marker on the target file. Migration is pending and accounting paused,
    /// but protection of the on-device file is decided independently of that.
    func testUnreadableTargetDuringMigrationStillGetsBestEffortMarker() throws {
        let fm = FileManager.default
        let legacyDir = fm.temporaryDirectory
            .appendingPathComponent("legacy-dir-\(UUID().uuidString)", isDirectory: true)
        let targetDir = fm.temporaryDirectory
            .appendingPathComponent("target-dir-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let legacy = legacyDir.appendingPathComponent("ledger.json")
        let target = targetDir.appendingPathComponent("ledger.json")
        defer {
            try? fm.removeItem(at: legacyDir)
            try? fm.removeItem(at: targetDir)
        }

        let old = [Expense(amountCents: 1234, categoryID: "food", date: Date())]
        let oldData = try JSONEncoder().encode(old)
        try oldData.write(to: legacy)
        let current = [Expense(amountCents: 8765, categoryID: "food", date: Date())]
        let currentData = try JSONEncoder().encode(current)
        try currentData.write(to: target)

        let denied = NSError(domain: NSCocoaErrorDomain, code: 257, userInfo: nil)
        let blocking: (URL) throws -> Data = { url in
            if url == target { throw denied }
            return try Data(contentsOf: url)
        }
        var targetMarkerCalls = 0
        let refusingDirectoryOnly: (URL) throws -> Void = { url in
            if url == target.deletingLastPathComponent() {
                throw LedgerStoreError.backupExclusionFailed
            }
            if url == target { targetMarkerCalls += 1 }
        }
        let store = LedgerStore(fileURL: target, legacyFileURL: legacy,
                                backupExclusion: refusingDirectoryOnly,
                                readLedgerFile: blocking)
        XCTAssertEqual(targetMarkerCalls, 1,
                       "an existing target must be marked even when unreadable during migration")
        XCTAssertEqual(store.readiness, .needsRecovery, "unreadable target pauses accounting")
        XCTAssertTrue(store.expenses.isEmpty, "no partial ledger may be shown")
        XCTAssertThrowsError(try store.addExpense(amountCents: 500, categoryID: "transport"))
        XCTAssertEqual(try Data(contentsOf: legacy), oldData, "legacy bytes preserved")
        XCTAssertEqual(try Data(contentsOf: target), currentData, "target bytes preserved")

        // Access restored: both originals are read exactly once after restart.
        let reopened = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertEqual(reopened.readiness, .ready)
        XCTAssertEqual(reopened.expenses.map(\.amountCents).sorted(), [1234, 8765])
    }

    // MARK: - Codex 3b1de682 规范 1: migration-phase target observation feeds the marker decision

    /// During migration the first probe of the live ledger is unreadable, but
    /// the later marking read reports a definite absence. The unified
    /// best-effort marker decision must adopt the target presence observed
    /// during migration: a file occupies that path even if a later read can no
    /// longer see it, so it must not be left unprotected before recovery.
    func testMigrationPhaseTargetObservationStillMarksUnreadableTarget() throws {
        let fm = FileManager.default
        let legacyDir = fm.temporaryDirectory
            .appendingPathComponent("legacy-dir-\(UUID().uuidString)", isDirectory: true)
        let targetDir = fm.temporaryDirectory
            .appendingPathComponent("target-dir-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let legacy = legacyDir.appendingPathComponent("ledger.json")
        let target = targetDir.appendingPathComponent("ledger.json")
        defer {
            try? fm.removeItem(at: legacyDir)
            try? fm.removeItem(at: targetDir)
        }

        let old = [Expense(amountCents: 1234, categoryID: "food", date: Date())]
        let oldData = try JSONEncoder().encode(old)
        try oldData.write(to: legacy)
        let current = [Expense(amountCents: 8765, categoryID: "food", date: Date())]
        let currentData = try JSONEncoder().encode(current)
        try currentData.write(to: target)

        let denied = NSError(domain: NSCocoaErrorDomain, code: 257, userInfo: nil) // NSFileReadNoPermissionError
        let absent = NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: nil) // NSFileNoSuchFileError
        var targetReadCalls = 0
        // Read 1 = migration probe of the target (unreadable); every later
        // target read = definite absence (the marking phase).
        let unreadableAtMigrationThenAbsent: (URL) throws -> Data = { url in
            if url == legacy { return try Data(contentsOf: url) }
            targetReadCalls += 1
            if targetReadCalls == 1 { throw denied }
            throw absent
        }
        var targetMarkerCalls = 0
        let refusingDirectoryOnly: (URL) throws -> Void = { url in
            if url == target.deletingLastPathComponent() {
                throw LedgerStoreError.backupExclusionFailed
            }
            if url == target { targetMarkerCalls += 1 }
        }
        let store = LedgerStore(fileURL: target, legacyFileURL: legacy,
                                backupExclusion: refusingDirectoryOnly,
                                readLedgerFile: unreadableAtMigrationThenAbsent)
        XCTAssertEqual(targetMarkerCalls, 1,
                       "the target observed as unreadable during migration must still be marked")
        XCTAssertEqual(store.readiness, .needsRecovery,
                       "migration against an unreadable target pauses accounting")
        XCTAssertTrue(store.expenses.isEmpty, "no partial ledger may be shown")
        XCTAssertThrowsError(try store.addExpense(amountCents: 500, categoryID: "transport"))
        XCTAssertEqual(try Data(contentsOf: legacy), oldData, "legacy bytes preserved")
        XCTAssertEqual(try Data(contentsOf: target), currentData, "target bytes preserved")

        // Reads recovered: a restart merges both originals and a new example
        // expense is saved exactly once.
        let reopened = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertEqual(reopened.readiness, .ready)
        XCTAssertEqual(reopened.expenses.map(\.amountCents).sorted(), [1234, 8765])
        try reopened.addExpense(amountCents: 500, categoryID: "transport")
        let after = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertEqual(after.expenses.map(\.amountCents).sorted(), [500, 1234, 8765],
                       "each example expense counted exactly once")
    }

    // MARK: - Codex cfbe0a7e 规格 2: one launch must not decide data and protection from two disagreeing reads

    /// The first read sees a valid ledger (87.65), but the protection check's
    /// later read is refused and the directory marker is refused too. The
    /// store reported `ready` because the protection guard bailed out on an
    /// unreadable path; integrity is unconfirmed, so accounting must pause.
    func testProtectionReadRefusedAfterDataReadPausesAccounting() throws {
        let records = [Expense(amountCents: 8765, categoryID: "food", date: Date())]
        let original = try JSONEncoder().encode(records)
        try original.write(to: fileURL)
        let ledger = fileURL!
        let directory = ledger.deletingLastPathComponent()

        var readCalls = 0
        let onceThenDenied: (URL) throws -> Data = { url in
            readCalls += 1
            if readCalls == 1 { return try Data(contentsOf: url) }
            throw NSError(domain: NSCocoaErrorDomain, code: 257, userInfo: nil) // NSFileReadNoPermissionError
        }
        let refusingDirectoryOnly: (URL) throws -> Void = { url in
            if url == directory { throw LedgerStoreError.backupExclusionFailed }
        }
        let store = LedgerStore(fileURL: ledger,
                                backupExclusion: refusingDirectoryOnly,
                                readLedgerFile: onceThenDenied)
        XCTAssertEqual(store.readiness, .needsRecovery,
                       "a protection read that cannot be confirmed must pause accounting")
        XCTAssertEqual(store.expenses.map(\.amountCents), [8765],
                       "the record read at launch stays visible under recovery")
        XCTAssertThrowsError(try store.addExpense(amountCents: 500, categoryID: "transport")) { error in
            guard case LedgerStoreError.recoveryRequired = error else {
                return XCTFail("expected recoveryRequired, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: ledger), original, "original bytes preserved")

        // Protection and reads restored: the original is read once and a save once.
        let reopened = LedgerStore(fileURL: ledger)
        XCTAssertEqual(reopened.readiness, .ready)
        XCTAssertEqual(reopened.expenses.map(\.amountCents), [8765])
        try reopened.addExpense(amountCents: 500, categoryID: "transport")
        let after = LedgerStore(fileURL: ledger)
        XCTAssertEqual(after.expenses.map(\.amountCents).sorted(), [500, 8765],
                       "original and new example expenses each counted once")
    }

    /// The data read sees no ledger, so memory holds an empty snapshot, but a
    /// later protection read is refused. Without pausing, a save would publish
    /// `[500]` over the real 87.65 record discovered only afterwards. Recovery
    /// must block that write and keep the original bytes intact.
    func testEmptySnapshotFromFirstReadCannotOverwriteLaterDiscoveredLedger() throws {
        let records = [Expense(amountCents: 8765, categoryID: "food", date: Date())]
        let original = try JSONEncoder().encode(records)
        try original.write(to: fileURL)
        let ledger = fileURL!

        var readCalls = 0
        let absentThenDenied: (URL) throws -> Data = { _ in
            readCalls += 1
            if readCalls == 1 {
                throw NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: nil) // NSFileNoSuchFileError
            }
            throw NSError(domain: NSCocoaErrorDomain, code: 257, userInfo: nil) // NSFileReadNoPermissionError
        }
        let store = LedgerStore(fileURL: ledger, readLedgerFile: absentThenDenied)
        XCTAssertEqual(store.readiness, .needsRecovery,
                       "an unconfirmable protection read must pause accounting")
        XCTAssertTrue(store.expenses.isEmpty, "no partial snapshot may be shown")
        XCTAssertThrowsError(try store.addExpense(amountCents: 500, categoryID: "transport")) { error in
            guard case LedgerStoreError.recoveryRequired = error else {
                return XCTFail("expected recoveryRequired, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: ledger), original,
                       "the ledger found on the later read must never be overwritten")

        let reopened = LedgerStore(fileURL: ledger)
        XCTAssertEqual(reopened.readiness, .ready)
        XCTAssertEqual(reopened.expenses.map(\.amountCents), [8765])
        try reopened.addExpense(amountCents: 500, categoryID: "transport")
        let after = LedgerStore(fileURL: ledger)
        XCTAssertEqual(after.expenses.map(\.amountCents).sorted(), [500, 8765],
                       "original and new example expenses each counted once")
    }

    // MARK: - Codex af97063c 规格 1: one launch must not open an empty snapshot over a ledger found later

    /// The data read sees a definite absence, but the marking and protection
    /// reads both see the real 87.65 ledger and the directory marker succeeds.
    /// Opening accounting against the empty snapshot would publish `[500]`
    /// over that record on the next save. Inconsistent startup reads must
    /// pause accounting and keep the original bytes untouched.
    func testEmptySnapshotThenLaterReadFindsLedgerPausesAccounting() throws {
        let records = [Expense(amountCents: 8765, categoryID: "food", date: Date())]
        let original = try JSONEncoder().encode(records)
        try original.write(to: fileURL)
        let ledger = fileURL!

        var readCalls = 0
        let absentThenFound: (URL) throws -> Data = { url in
            readCalls += 1
            if readCalls == 1 {
                throw NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: nil) // NSFileNoSuchFileError
            }
            return try Data(contentsOf: url)
        }
        let store = LedgerStore(fileURL: ledger, readLedgerFile: absentThenFound)
        XCTAssertEqual(store.readiness, .needsRecovery,
                       "a ledger discovered after the data read makes the snapshot untrustworthy")
        XCTAssertTrue(store.expenses.isEmpty, "no partial snapshot may be shown")
        XCTAssertThrowsError(try store.addExpense(amountCents: 500, categoryID: "transport")) { error in
            guard case LedgerStoreError.recoveryRequired = error else {
                return XCTFail("expected recoveryRequired, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: ledger), original,
                       "the ledger found on a later read must never be overwritten")

        let reopened = LedgerStore(fileURL: ledger)
        XCTAssertEqual(reopened.readiness, .ready)
        XCTAssertEqual(reopened.expenses.map(\.amountCents), [8765])
        try reopened.addExpense(amountCents: 500, categoryID: "transport")
        let after = LedgerStore(fileURL: ledger)
        XCTAssertEqual(after.expenses.map(\.amountCents).sorted(), [500, 8765],
                       "original and new example expenses each counted once")
    }

    /// The data read sees a definite absence, the marking read then finds the
    /// real ledger, and the protection read is refused. Both the late discovery
    /// and the unconfirmable read leave integrity unconfirmed, so no empty
    /// snapshot may be opened or written.
    func testEmptySnapshotThenMarkingFindsLedgerAndProtectionReadRefused() throws {
        let records = [Expense(amountCents: 8765, categoryID: "food", date: Date())]
        let original = try JSONEncoder().encode(records)
        try original.write(to: fileURL)
        let ledger = fileURL!

        var readCalls = 0
        let absentThenFoundThenDenied: (URL) throws -> Data = { url in
            readCalls += 1
            switch readCalls {
            case 1:
                throw NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: nil) // NSFileNoSuchFileError
            case 2:
                return try Data(contentsOf: url)
            default:
                throw NSError(domain: NSCocoaErrorDomain, code: 257, userInfo: nil) // NSFileReadNoPermissionError
            }
        }
        let store = LedgerStore(fileURL: ledger, readLedgerFile: absentThenFoundThenDenied)
        XCTAssertEqual(store.readiness, .needsRecovery,
                       "an unconfirmable protection read must pause accounting")
        XCTAssertTrue(store.expenses.isEmpty, "no partial snapshot may be shown")
        XCTAssertThrowsError(try store.addExpense(amountCents: 500, categoryID: "transport")) { error in
            guard case LedgerStoreError.recoveryRequired = error else {
                return XCTFail("expected recoveryRequired, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: ledger), original,
                       "the ledger found on a later read must never be overwritten")

        let reopened = LedgerStore(fileURL: ledger)
        XCTAssertEqual(reopened.readiness, .ready)
        XCTAssertEqual(reopened.expenses.map(\.amountCents), [8765])
        try reopened.addExpense(amountCents: 500, categoryID: "transport")
        let after = LedgerStore(fileURL: ledger)
        XCTAssertEqual(after.expenses.map(\.amountCents).sorted(), [500, 8765],
                       "original and new example expenses each counted once")
    }

    // MARK: - Codex 3b1de682 规格 1: migration's verified snapshot joins startup consistency

    /// Migration reads a complete target (12.34 + 87.65), confirms both copies
    /// are protected and removes the legacy file. Every read afterwards this
    /// launch reports a definite absence, so `load()` sees an empty ledger.
    /// Unless the snapshot verified by migration joins the consistency check,
    /// the store opens `ready` and the next 5.00 save overwrites both records.
    func testMigrationVerifiedSnapshotThenAllLaterReadsAbsentPausesAccounting() throws {
        let fm = FileManager.default
        let legacyDir = fm.temporaryDirectory
            .appendingPathComponent("legacy-dir-\(UUID().uuidString)", isDirectory: true)
        let targetDir = fm.temporaryDirectory
            .appendingPathComponent("target-dir-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let legacy = legacyDir.appendingPathComponent("ledger.json")
        let target = targetDir.appendingPathComponent("ledger.json")
        defer {
            try? fm.removeItem(at: legacyDir)
            try? fm.removeItem(at: targetDir)
        }

        let shared = Expense(amountCents: 1234, categoryID: "food", date: Date())
        let extra = Expense(amountCents: 8765, categoryID: "transport", date: Date())
        let legacyData = try JSONEncoder().encode([shared])
        let targetData = try JSONEncoder().encode([shared, extra])
        try legacyData.write(to: legacy)
        try targetData.write(to: target)

        var targetReadCalls = 0
        let absentAfterMigrationProbe: (URL) throws -> Data = { url in
            if url == legacy { return try Data(contentsOf: url) }
            targetReadCalls += 1
            // Only the migration probe sees the real, complete target; load,
            // marking and protection all report a definite absence.
            guard targetReadCalls == 1 else {
                throw NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: nil) // NSFileNoSuchFileError
            }
            return try Data(contentsOf: url)
        }
        let store = LedgerStore(fileURL: target, legacyFileURL: legacy,
                                readLedgerFile: absentAfterMigrationProbe)
        XCTAssertEqual(store.readiness, .needsRecovery,
                       "reads disagreeing with the migration-verified snapshot must pause accounting")
        XCTAssertTrue(store.expenses.isEmpty, "no partial snapshot may be shown")
        XCTAssertThrowsError(try store.addExpense(amountCents: 500, categoryID: "food")) { error in
            guard case LedgerStoreError.recoveryRequired = error else {
                return XCTFail("expected recoveryRequired, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: target), targetData,
                       "the verified target snapshot must stay byte-for-byte")

        // Reads recovered: a restart shows both records, and a new example
        // expense is stored exactly once alongside them.
        let reopened = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertEqual(reopened.readiness, .ready)
        XCTAssertEqual(reopened.expenses.map(\.amountCents).sorted(), [1234, 8765])
        try reopened.addExpense(amountCents: 500, categoryID: "food")
        let after = LedgerStore(fileURL: target, legacyFileURL: legacy)
        XCTAssertEqual(after.expenses.map(\.amountCents).sorted(), [500, 1234, 8765],
                       "each example expense counted exactly once")
    }

    // MARK: - Issue 02: two-level categories and maintenance

    private func exampleCategoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("categories-\(UUID().uuidString).json")
    }

    // MARK: - Codex 09:08 规范 2: category path derives from the validated test ledger

    func testCategoryTestFileURLDerivesFromValidatedLedgerPath() {
        let environment = ["PAYLEDGER_TEST_LEDGER": "uitest-example.json"]
        let ledgerURL = PayLedgerApp.ledgerFileURL(environment: environment)
        let categoryURL = CategoryStore.testFileURL(environment: environment)

        XCTAssertNotNil(ledgerURL)
        XCTAssertNotNil(categoryURL)
        XCTAssertEqual(categoryURL?.lastPathComponent, "categories-uitest-example.json")
        XCTAssertEqual(categoryURL?.deletingLastPathComponent(),
                       ledgerURL?.deletingLastPathComponent(),
                       "the category file must live beside the isolated example ledger")
        XCTAssertNotEqual(categoryURL, ledgerURL,
                          "the category file must be independent of the ledger file")
        XCTAssertNotEqual(categoryURL, CategoryStore.defaultFileURL)
    }

    func testCategoryTestFileURLStaysIsolatedForInvalidOrMissingLedgerName() {
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PayLedgerUITests", isDirectory: true)

        // Invalid names and test overrides without a ledger name must not
        // escape the isolated directory or fall through to the production path.
        for environment in [
            ["PAYLEDGER_TEST_LEDGER": "ledger.json"],
            ["PAYLEDGER_TEST_LEDGER": "../Documents/ledger.json"],
            ["PAYLEDGER_TEST_LEDGER": "uitest-a/b.json"],
            ["PAYLEDGER_TEST_NOW": "2026-11-17T10:00:00"],
            ["PAYLEDGER_TEST_STATE": "recovered"]
        ] {
            let url = CategoryStore.testFileURL(environment: environment)
            XCTAssertNotNil(url, "expected an isolated category path for \(environment)")
            XCTAssertEqual(url?.lastPathComponent, "categories-uitest-invalid-config.json",
                           "invalid \(environment) must use the validated fallback name")
            XCTAssertEqual(url?.deletingLastPathComponent(), testDirectory,
                           "invalid \(environment) must stay inside the isolated directory")
            XCTAssertNotEqual(url, CategoryStore.defaultFileURL)
        }
        XCTAssertNil(CategoryStore.testFileURL(environment: [:]),
                     "production launches use the on-device category path")
    }

    func testCategoryTestFileURLPersistsAcrossRestart() throws {
        let name = "uitest-\(UUID().uuidString).json"
        let environment = ["PAYLEDGER_TEST_LEDGER": name]
        let categoryURL = try XCTUnwrap(CategoryStore.testFileURL(environment: environment))
        defer { try? FileManager.default.removeItem(at: categoryURL) }

        let first = CategoryStore(fileURL: categoryURL)
        try first.addPrimary(name: "购物示例")
        let primaryID = try XCTUnwrap(first.groups.last?.id)
        try first.addSubcategory(primaryID: primaryID, name: "日用示例")

        let reopened = CategoryStore(fileURL: categoryURL)
        XCTAssertEqual(reopened.primaryName(for: primaryID), "购物示例")
        XCTAssertEqual(reopened.subcategories(in: primaryID).map(\.name), ["日用示例"])
    }

    /// Codex 10:57 规范: the old `\(stem)-categories.json` derivation produced a
    /// name that the ledger-name validator also accepts. Two legal example
    /// names could then cross-read each other's category/ledger JSON.
    func testCategoryAndLedgerExamplePathsAreMutuallyIndependent() throws {
        let token = UUID().uuidString
        let firstName = "uitest-\(token)-a.json"
        // Exactly the name the old derivation produced for the first example's
        // category file — and a valid ledger name in its own right.
        let secondName = "uitest-\(token)-a-categories.json"
        let firstEnv = ["PAYLEDGER_TEST_LEDGER": firstName]
        let secondEnv = ["PAYLEDGER_TEST_LEDGER": secondName]

        let firstLedger = try XCTUnwrap(PayLedgerApp.ledgerFileURL(environment: firstEnv))
        let firstCategories = try XCTUnwrap(CategoryStore.testFileURL(environment: firstEnv))
        let secondLedger = try XCTUnwrap(PayLedgerApp.ledgerFileURL(environment: secondEnv))
        let secondCategories = try XCTUnwrap(CategoryStore.testFileURL(environment: secondEnv))
        let allPaths = [firstLedger, firstCategories, secondLedger, secondCategories]
        defer { allPaths.forEach { try? FileManager.default.removeItem(at: $0) } }

        XCTAssertEqual(Set(allPaths.map(\.path)).count, 4,
                       "ledger and category files for both examples must be four distinct paths")

        // A category filename must never itself be acceptable as a ledger name.
        for categories in [firstCategories, secondCategories] {
            let resolved = PayLedgerApp.ledgerFileURL(
                environment: ["PAYLEDGER_TEST_LEDGER": categories.lastPathComponent])
            XCTAssertNotEqual(resolved?.lastPathComponent, categories.lastPathComponent,
                              "\(categories.lastPathComponent) must be rejected by the ledger-name validator")
        }

        // Add a category in the first example, then an expense in the second.
        let firstCategoryStore = CategoryStore(fileURL: firstCategories)
        try firstCategoryStore.addPrimary(name: "示例一组")
        let firstPrimaryID = try XCTUnwrap(firstCategoryStore.groups.last?.id)

        let secondLedgerStore = LedgerStore(fileURL: secondLedger)
        try secondLedgerStore.addExpense(amountCents: 1234, categoryID: "food")

        // Reopen both: neither example sees the other's data.
        let reopenedFirstCategories = CategoryStore(fileURL: firstCategories)
        XCTAssertEqual(reopenedFirstCategories.primaryName(for: firstPrimaryID), "示例一组")
        let reopenedFirstLedger = LedgerStore(fileURL: firstLedger)
        XCTAssertTrue(reopenedFirstLedger.expenses.isEmpty)

        let reopenedSecondCategories = CategoryStore(fileURL: secondCategories)
        XCTAssertFalse(reopenedSecondCategories.groups.contains { $0.name == "示例一组" })
        let reopenedSecondLedger = LedgerStore(fileURL: secondLedger)
        XCTAssertEqual(reopenedSecondLedger.expenses.map(\.amountCents), [1234])
    }

    func testCategoryStoreDefaultsAndLookup() throws {
        let store = CategoryStore(fileURL: exampleCategoryURL())
        XCTAssertEqual(store.groups.count, 2)
        XCTAssertEqual(store.primaryName(for: "food"), "食品酒水")
        XCTAssertEqual(store.primaryName(for: "transport"), "交通")
        // Unknown ids fall back to the legacy mapping instead of showing a raw id.
        XCTAssertEqual(store.primaryName(for: "unknown"), "unknown")
        XCTAssertEqual(store.subcategories(in: "food").map(\.name), ["早午晚餐", "零食饮料"])
        XCTAssertEqual(
            store.subcategoryName(primaryID: "food", subcategoryID: "food-meal"), "早午晚餐")
    }

    func testReconciledSubcategoryKeepsValidChoiceAndSelectsFirstOtherwise() throws {
        let url = exampleCategoryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CategoryStore(fileURL: url)

        // A child that still belongs to the primary is preserved.
        XCTAssertEqual(
            store.reconciledSubcategoryID(primaryID: "food", current: "food-snack"),
            "food-snack")
        // Switching to another primary resets to that primary's first child.
        XCTAssertEqual(
            store.reconciledSubcategoryID(primaryID: "transport", current: "food-snack"),
            "transport-bus")
        // A primary without children has no subcategory to select.
        try store.addPrimary(name: "购物")
        let emptyID = try XCTUnwrap(store.groups.last?.id)
        XCTAssertNil(store.reconciledSubcategoryID(primaryID: emptyID, current: "food-snack"))
        // Adding the first child makes it the selection when none was held.
        try store.addSubcategory(primaryID: emptyID, name: "日用品")
        let addedID = try XCTUnwrap(store.subcategories(in: emptyID).first?.id)
        XCTAssertEqual(store.reconciledSubcategoryID(primaryID: emptyID, current: nil), addedID)
        // A still-valid choice is not overwritten by the newly added sibling.
        XCTAssertEqual(
            store.reconciledSubcategoryID(primaryID: emptyID, current: addedID), addedID)
    }

    func testRenamePrimaryKeepsHistoricalAmountAndDateAndShowsNewName() throws {
        let ledgerURL = fileURL!
        let categoryURL = exampleCategoryURL()
        defer { try? FileManager.default.removeItem(at: categoryURL) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let ledger = LedgerStore(fileURL: ledgerURL)
        try ledger.addExpense(amountCents: 1234, categoryID: "food",
                              subcategoryID: "food-meal", date: date)

        let categories = CategoryStore(fileURL: categoryURL)
        XCTAssertEqual(categories.primaryName(for: "food"), "食品酒水")
        try categories.renamePrimary(id: "food", to: "餐饮")
        XCTAssertEqual(categories.primaryName(for: "food"), "餐饮")

        // Rename never touches the expense; amount and date stay identical and
        // the new name is reflected on restart of both stores.
        let reopenedCategories = CategoryStore(fileURL: categoryURL)
        XCTAssertEqual(reopenedCategories.primaryName(for: "food"), "餐饮")
        let reopenedLedger = LedgerStore(fileURL: ledgerURL)
        XCTAssertEqual(reopenedLedger.expenses.count, 1)
        XCTAssertEqual(reopenedLedger.expenses.first?.amountCents, 1234)
        XCTAssertEqual(reopenedLedger.expenses.first?.date, date)
        XCTAssertEqual(reopenedLedger.expenses.first?.subcategoryID, "food-meal")
    }

    func testAddAndRenameSubcategoryPersistAcrossRestart() throws {
        let categoryURL = exampleCategoryURL()
        defer { try? FileManager.default.removeItem(at: categoryURL) }
        let store = CategoryStore(fileURL: categoryURL)
        try store.addSubcategory(primaryID: "food", name: "夜宵")
        let addedID = try XCTUnwrap(store.subcategories(in: "food").last?.id)
        XCTAssertEqual(store.subcategoryName(primaryID: "food", subcategoryID: addedID), "夜宵")

        try store.renameSubcategory(primaryID: "food", subcategoryID: addedID, to: "深夜食堂")
        let reopened = CategoryStore(fileURL: categoryURL)
        XCTAssertEqual(reopened.subcategoryName(primaryID: "food", subcategoryID: addedID), "深夜食堂")
        // Renaming a subcategory does not disturb its siblings.
        XCTAssertEqual(reopened.subcategories(in: "food").map(\.name),
                       ["早午晚餐", "零食饮料", "深夜食堂"])
    }

    func testAddPrimaryPersistsAcrossRestart() throws {
        let categoryURL = exampleCategoryURL()
        defer { try? FileManager.default.removeItem(at: categoryURL) }
        let store = CategoryStore(fileURL: categoryURL)
        try store.addPrimary(name: "居家生活")
        let addedID = try XCTUnwrap(store.groups.last?.id)
        XCTAssertEqual(store.primaryName(for: addedID), "居家生活")
        let reopened = CategoryStore(fileURL: categoryURL)
        XCTAssertEqual(reopened.primaryName(for: addedID), "居家生活")
        XCTAssertEqual(reopened.groups.count, 3)
    }

    func testLegacyExpenseWithoutSubcategoryStillDecodes() throws {
        // A record written before issue 02 has no subcategoryID key. Swift's
        // synthesized decoder must fill nil so old ledgers keep working.
        let legacyJSON = """
        [{"id":"00000000-0000-0000-0000-000000000001","amountCents":1234,\
        "categoryID":"food","date":1700419200}]
        """
        try Data(legacyJSON.utf8).write(to: fileURL)
        let store = LedgerStore(fileURL: fileURL)
        XCTAssertEqual(store.expenses.count, 1)
        XCTAssertEqual(store.expenses.first?.amountCents, 1234)
        XCTAssertNil(store.expenses.first?.subcategoryID)
        XCTAssertEqual(store.expenses.first?.categoryID, "food")
    }

    // MARK: - Issue 02, Codex 09:08 规范 1: protected category persistence

    func testCategoryBackupExclusionFailureKeepsOriginalFileMemoryAndRestart() throws {
        let url = exampleCategoryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let seed = CategoryStore(fileURL: url)
        try seed.renamePrimary(id: "food", to: "餐饮")
        let original = try Data(contentsOf: url)
        let originalNames = seed.groups.map(\.name)

        let refusing: (URL) throws -> Void = { _ in throw LedgerStoreError.backupExclusionFailed }
        let store = CategoryStore(fileURL: url, backupExclusion: refusing)
        XCTAssertThrowsError(try store.addPrimary(name: "购物")) { error in
            guard case LedgerStoreError.backupExclusionFailed = error else {
                return XCTFail("expected backupExclusionFailed, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: url), original, "live category file must stay untouched")
        XCTAssertEqual(store.groups.map(\.name), originalNames, "memory stays at the original tree")
        let reopened = CategoryStore(fileURL: url)
        XCTAssertEqual(reopened.primaryName(for: "food"), "餐饮", "restart reads original categories")
    }

    func testCategoryExclusionVerificationFailureBlocksPublish() throws {
        let url = exampleCategoryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let seed = CategoryStore(fileURL: url)
        try seed.renamePrimary(id: "food", to: "餐饮")
        let original = try Data(contentsOf: url)

        // The override succeeds but never sets the marker, so the mandatory
        // readback sees false. A swallowed false used to publish over the file.
        let store = CategoryStore(fileURL: url, backupExclusion: { _ in })
        XCTAssertThrowsError(try store.addPrimary(name: "购物")) { error in
            guard case LedgerStoreError.backupExclusionFailed = error else {
                return XCTFail("expected backupExclusionFailed on false readback, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(store.groups.contains { $0.name == "购物" })
    }

    func testCategoryPublishFailureKeepsOriginalFileMemoryAndRestart() throws {
        let url = exampleCategoryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let seed = CategoryStore(fileURL: url)
        try seed.renamePrimary(id: "food", to: "餐饮")
        let original = try Data(contentsOf: url)

        let store = CategoryStore(fileURL: url, finalPublishFailure: { TestFinalPublishError.failed })
        XCTAssertThrowsError(try store.addSubcategory(primaryID: "food", name: "夜宵"))
        XCTAssertEqual(try Data(contentsOf: url), original, "failed publish leaves the live file intact")
        XCTAssertFalse(store.groups.contains { $0.subcategories.contains { $0.name == "夜宵" } })
        let reopened = CategoryStore(fileURL: url)
        XCTAssertEqual(reopened.primaryName(for: "food"), "餐饮")
    }

    func testUnreadableCategoryFileIsPreservedAndBlocksOverwrite() throws {
        let url = exampleCategoryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let corrupt = Data("not a category tree".utf8)
        try corrupt.write(to: url)

        let store = CategoryStore(fileURL: url)
        XCTAssertTrue(store.isUnreadable, "an undecodable file must surface as unreadable")
        XCTAssertThrowsError(try store.addPrimary(name: "购物"))
        XCTAssertEqual(try Data(contentsOf: url), corrupt, "corrupt bytes stay byte-for-byte")
        let reopened = CategoryStore(fileURL: url)
        XCTAssertTrue(reopened.isUnreadable)
        XCTAssertEqual(try Data(contentsOf: url), corrupt)

        // A path that cannot be inspected is equally unwritable.
        let unreadable = CategoryStore(fileURL: url, readCategoriesFile: { _ in
            throw NSError(domain: "test", code: 5)
        })
        XCTAssertTrue(unreadable.isUnreadable)
        XCTAssertThrowsError(try unreadable.renamePrimary(id: "food", to: "餐饮"))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }
}

private enum TestLegacyRemovalError: Error { case failed }
private enum TestFinalPublishError: Error { case failed }
