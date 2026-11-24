import SwiftUI

@main
struct PayLedgerApp: App {
    @StateObject private var store: LedgerStore
    @StateObject private var categoryStore: CategoryStore
    @StateObject private var historyStore: HistoryStore

    init() {
        let environment = ProcessInfo.processInfo.environment
        #if DEBUG
        // Clock pinning and time-zone pinning are test-only affordances
        // compiled out of release. The zone lets a UI test restart the same
        // isolated ledger under UTC+8, UTC+9 and UTC to prove a recorded day
        // never shifts across the opening cutoff.
        if let zoneID = environment["PAYLEDGER_TEST_TZ"],
           let zone = TimeZone(identifier: zoneID) {
            LedgerStats.calendarTimeZoneOverride = zone
        }
        if let pinned = environment["PAYLEDGER_TEST_NOW"],
           let date = AppClock.parseOverride(pinned) {
            AppClock.overrideDate = date
        }
        #endif
        let stores = Self.makeStores(
            environment: environment,
            productionFileURL: LedgerStore.defaultFileURL,
            legacyFileURL: LedgerStore.legacyDefaultFileURL,
            categoryFileURL: CategoryStore.defaultFileURL,
            historyFileURL: HistoryStore.defaultFileURL)
        _store = StateObject(wrappedValue: stores.ledger)
        _categoryStore = StateObject(wrappedValue: stores.categories)
        _historyStore = StateObject(wrappedValue: stores.history)
    }

    /// Single assembly point for all three stores, shared by the real app
    /// entry and by entry-level tests. Tests inject sentinel production/legacy
    /// paths to observe that a unit-test host reads, writes, marks and migrates
    /// none of them; the shipped entry passes the on-device paths here.
    static func makeStores(
        environment: [String: String],
        productionFileURL: URL,
        legacyFileURL: URL?,
        categoryFileURL: URL,
        historyFileURL: URL
    ) -> (ledger: LedgerStore, categories: CategoryStore, history: HistoryStore) {
        #if DEBUG
        // A XCTest host reaches this entry with no PAYLEDGER_TEST_* override.
        // Resolve one isolated example set for ALL three stores instead of
        // touching on-device files (including the legacy ledger migration).
        let effective = hostTestEnvironment(environment) ?? environment
        #else
        let effective = environment
        #endif
        let ledger = makeStore(environment: effective,
                               productionFileURL: productionFileURL,
                               legacyFileURL: legacyFileURL)
        let categories = makeCategoryStore(environment: effective,
                                           productionFileURL: categoryFileURL)
        let history = makeHistoryStore(environment: effective,
                                       productionFileURL: historyFileURL,
                                       ledger: ledger)
        return (ledger, categories, history)
    }

    #if DEBUG
    /// A unit-test host launch carries XCTestConfigurationFilePath and no test
    /// override. It uses a fixed isolated example ledger for all three stores;
    /// the usual name validation keeps every derived path inside the test
    /// directory. UI-test launches and real launches are unaffected.
    private static func hostTestEnvironment(_ environment: [String: String]) -> [String: String]? {
        guard environment["XCTestConfigurationFilePath"] != nil,
              !isTestLaunch(environment) else { return nil }
        return ["PAYLEDGER_TEST_LEDGER": "uitest-unithost.json"]
    }
    #endif

    /// Resolves the category tree. Test launches get an isolated example file
    /// derived from the test ledger name; production uses the on-device path.
    private static func makeCategoryStore(environment: [String: String],
                                          productionFileURL: URL) -> CategoryStore {
        #if DEBUG
        if let injected = CategoryStore.testFileURL(environment: environment) {
            return CategoryStore(fileURL: injected)
        }
        #endif
        return CategoryStore(fileURL: productionFileURL)
    }

    /// Resolves the historical-amounts file. Test launches get a file derived
    /// from the validated test ledger name; production uses the on-device path.
    private static func makeHistoryStore(environment: [String: String],
                                         productionFileURL: URL,
                                         ledger: LedgerStore? = nil) -> HistoryStore {
        let historyStore: HistoryStore
        #if DEBUG
        if let injected = HistoryStore.testFileURL(environment: environment) {
            // Drives the unreadable-history branch from UI tests using example
            // bytes only, inside the isolated test directory. Compiled out of
            // release; never touches either production path.
            if let mode = environment["PAYLEDGER_TEST_HISTORY"] {
                if mode == "unreadable" {
                    try? Data("broken example history".utf8).write(to: injected)
                } else if mode == "invalid-fields" {
                    // Structurally valid JSON that decodes but carries a
                    // duplicate month (4000 + 3000 would double-count).
                    let example = #"{"monthlySummaries":[{"year":2026,"month":10,"amountCents":4000},{"year":2026,"month":10,"amountCents":3000}],"openingBalance":null}"#
                    try? Data(example.utf8).write(to: injected)
                }
            }
            historyStore = HistoryStore(fileURL: injected)
        } else {
            historyStore = HistoryStore(fileURL: productionFileURL)
        }
        #else
        historyStore = HistoryStore(fileURL: productionFileURL)
        #endif
        // Opening balance represents every per-record expense through its
        // cutoff. Until the ledger is trusted those records may be unloaded,
        // so the data layer refuses to write or replace the opening balance.
        if let ledger {
            historyStore.openingBalanceAllowed = { ledger.readiness != .needsRecovery }
        }
        return historyStore
    }

    /// The single ledger factory used by the real app entry and by entry-level
    /// tests. A normal launch passes the on-device paths; tests pass sentinel
    /// paths to observe that no production path is touched. Both callers run
    /// through this one resolution, so the tested path is the shipped path.
    static func makeStore(environment: [String: String],
                          productionFileURL: URL,
                          legacyFileURL: URL?) -> LedgerStore {
        #if DEBUG
        // ANY test override — including a state-only launch — resolves to an
        // isolated example ledger, never to either production path.
        if let injected = ledgerFileURL(environment: environment) {
            if let staged = storeForTestState(environment, injected: injected) {
                return staged
            }
            return LedgerStore(fileURL: injected)
        }
        #endif
        try? FileManager.default.createDirectory(
            at: productionFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        // A unit-test host is redirected to an isolated example ledger by
        // makeStores before reaching this branch, so production paths here are
        // only ever used by a real on-device launch.
        return LedgerStore(fileURL: productionFileURL, legacyFileURL: legacyFileURL)
    }

    #if DEBUG
    /// Drives the recovery branches from UI tests without ever touching either
    /// production path. All files live in the isolated PayLedgerUITests temp
    /// directory. Compiled out of release.
    /// Encodes the example record the way an old on-device ledger looks:
    /// original fields only, with no `consumptionDay` key. The cleanup-pending
    /// fixture uses this for the retained copy so the UI case really exercises
    /// backfill-on-migration. Compiled out of release.
    private static func legacyExampleData(for expense: Expense) -> Data? {
        guard let records = try? JSONSerialization.jsonObject(
                with: JSONEncoder().encode([expense])) as? [[String: Any]],
              var record = records.first else { return nil }
        record.removeValue(forKey: "consumptionDay")
        return try? JSONSerialization.data(withJSONObject: [record])
    }

    private static func storeForTestState(_ environment: [String: String],
                                          injected: URL) -> LedgerStore? {
        guard let state = environment["PAYLEDGER_TEST_STATE"] else { return nil }
        let fm = FileManager.default
        let legacy = injected.deletingLastPathComponent()
            .appendingPathComponent("\(injected.deletingPathExtension().lastPathComponent)-legacy.json")
        // Use the pinned clock (when supplied) so the injected legacy record
        // shares the recording day of expenses entered through the UI. Without
        // this, a timezone/clock-pinned UI test attributes the seed record to
        // the real device day and silently drops it from the pinned bills.
        let seed = Expense(amountCents: 1234, categoryID: "food", date: AppClock.now)
        let example = try? JSONEncoder().encode([seed])

        switch state {
        case "unreadable":
            try? Data("broken example ledger".utf8).write(to: injected)
            return LedgerStore(fileURL: injected)
        case "recovered":
            try? example?.write(to: injected)
            return LedgerStore(fileURL: injected)
        case "cleanupPending":
            // The live copy is already migrated and backfilled; the retained
            // legacy copy is a genuine old ledger with no consumption day.
            // Only deletion of the protected legacy copy fails, so accounting
            // stays open and a later restart must import that same UUID once.
            try? example?.write(to: injected)
            if let oldExample = legacyExampleData(for: seed) {
                try? oldExample.write(to: legacy)
            }
            return LedgerStore(fileURL: injected, legacyFileURL: legacy,
                               removeLegacyFile: { _ in throw TestLegacyRemovalNeedsRetry.failed })
        case "cleanupPendingRecover":
            // Next launch: the retained legacy copy can now be removed. Keep
            // the existing target untouched so expenses saved while cleanup
            // was pending are read back exactly once.
            if fm.fileExists(atPath: legacy.path) {
                return LedgerStore(fileURL: injected, legacyFileURL: legacy)
            }
            return LedgerStore(fileURL: injected)
        default:
            return nil
        }
    }
    #endif

    /// A test launch is any launch carrying a `PAYLEDGER_TEST_*` override —
    /// including a state-only launch. Every such launch must be treated as a
    /// test launch so it can never fall through to the production ledger (and
    /// its legacy migration path). Compiled out of release.
    #if DEBUG
    static func isTestLaunch(_ environment: [String: String]) -> Bool {
        environment.keys.contains { $0.hasPrefix("PAYLEDGER_TEST_") }
    }
    #endif

    /// Resolves this launch's ledger location without ever touching the
    /// production ledger. Injection is compiled out of non-DEBUG builds. In
    /// DEBUG, ANY test override yields an isolated example ledger inside a
    /// dedicated temporary directory: an invalid or missing ledger name falls
    /// back to a fixed safe name instead of resolving to the production (or
    /// legacy) path.
    static func ledgerFileURL(environment: [String: String]) -> URL? {
        #if DEBUG
        guard isTestLaunch(environment) else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PayLedgerUITests", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let requested = environment["PAYLEDGER_TEST_LEDGER"]
        let name = requested.flatMap { isValidTestLedgerName($0) ? $0 : nil } ?? Self.invalidTestLedgerName
        return directory.appendingPathComponent(name)
        #else
        return nil
        #endif
    }

    /// Fixed isolated file used when a test launch supplies an invalid (or no)
    /// ledger name. Keeps the launch inside the test sandbox rather than
    /// silently reverting to the on-device ledger.
    private static let invalidTestLedgerName = "uitest-invalid-config.json"

    /// Accepts only a bare `uitest-<safe>.json` name: no path separators, no
    /// parent components, no other extension. This keeps the injection from
    /// ever resolving to a production or legacy ledger path.
    private static func isValidTestLedgerName(_ name: String) -> Bool {
        let prefix = "uitest-"
        let suffix = ".json"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let middle = name.dropFirst(prefix.count).dropLast(suffix.count)
        guard !middle.isEmpty else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return middle.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store, categoryStore: categoryStore, historyStore: historyStore)
        }
    }
}

#if DEBUG
private enum TestLegacyRemovalNeedsRetry: Error { case failed }
#endif
