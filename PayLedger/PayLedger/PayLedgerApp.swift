import SwiftUI

@main
struct PayLedgerApp: App {
    @StateObject private var store: LedgerStore
    @StateObject private var categoryStore: CategoryStore

    init() {
        let environment = ProcessInfo.processInfo.environment
        #if DEBUG
        // Clock pinning is a test-only affordance compiled out of release.
        if let pinned = environment["PAYLEDGER_TEST_NOW"],
           let date = AppClock.parseOverride(pinned) {
            AppClock.overrideDate = date
        }
        #endif
        _store = StateObject(wrappedValue: Self.makeStore(
            environment: environment,
            productionFileURL: LedgerStore.defaultFileURL,
            legacyFileURL: LedgerStore.legacyDefaultFileURL))
        _categoryStore = StateObject(wrappedValue: Self.makeCategoryStore(environment: environment))
    }

    /// Resolves the category tree. Test launches get an isolated example file
    /// derived from the test ledger name; production uses the on-device path.
    private static func makeCategoryStore(environment: [String: String]) -> CategoryStore {
        #if DEBUG
        if let injected = CategoryStore.testFileURL(environment: environment) {
            return CategoryStore(fileURL: injected)
        }
        #endif
        return CategoryStore()
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
        return LedgerStore(fileURL: productionFileURL, legacyFileURL: legacyFileURL)
    }

    #if DEBUG
    /// Drives the recovery branches from UI tests without ever touching either
    /// production path. All files live in the isolated PayLedgerUITests temp
    /// directory. Compiled out of release.
    private static func storeForTestState(_ environment: [String: String],
                                          injected: URL) -> LedgerStore? {
        guard let state = environment["PAYLEDGER_TEST_STATE"] else { return nil }
        let fm = FileManager.default
        let legacy = injected.deletingLastPathComponent()
            .appendingPathComponent("\(injected.deletingPathExtension().lastPathComponent)-legacy.json")
        let example = try? JSONEncoder().encode(
            [Expense(amountCents: 1234, categoryID: "food", date: Date())])

        switch state {
        case "unreadable":
            try? Data("broken example ledger".utf8).write(to: injected)
            return LedgerStore(fileURL: injected)
        case "recovered":
            try? example?.write(to: injected)
            return LedgerStore(fileURL: injected)
        case "cleanupPending":
            // Full ledger migrated and both copies protected; only deletion of
            // the protected legacy copy fails, so accounting stays open.
            try? example?.write(to: injected)
            try? example?.write(to: legacy)
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
            ContentView(store: store, categoryStore: categoryStore)
        }
    }
}

#if DEBUG
private enum TestLegacyRemovalNeedsRetry: Error { case failed }
#endif
