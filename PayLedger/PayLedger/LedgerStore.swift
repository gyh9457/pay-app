import Foundation

/// Whether the ledger is safe to present and write to. Recovery state is
/// decided once at launch, before accounting opens, so incomplete data is
/// never shown as a complete ledger.
enum LedgerReadiness: Equatable {
    /// Full ledger available, all retained copies protected, accounting open.
    case ready
    /// Full ledger migrated and protected; only deletion of a protected
    /// legacy copy failed. Accounting stays open; the home view asks for a
    /// retry on the next launch.
    case cleanupPending
    /// Integrity unconfirmed: migration incomplete, ledger unreadable,
    /// records incomplete, or a retained copy's backup exclusion unconfirmed.
    /// Accounting is paused.
    case needsRecovery
}

enum LedgerStoreError: Error, LocalizedError {
    /// An on-device ledger exists but cannot be decoded. The original file is
    /// kept and writes are blocked so it can never be silently overwritten.
    case unreadableLedger
    /// A legacy ledger needs migrating but the target is not writable yet
    /// (or the legacy file cannot be decoded). The legacy file is preserved
    /// and saving from an empty ledger is blocked until a restart succeeds.
    case migrationPending
    /// The platform refused to apply the backup-exclusion marker. The save
    /// must not be reported as successful while the ledger is unprotected.
    case backupExclusionFailed
    /// The migrated copy did not byte-match the source, so the old copy must
    /// stay in place.
    case migrationVerificationFailed
    /// A staged ledger did not byte-match the encoded data before commit.
    case writeVerificationFailed
    /// The live ledger changed (or became unreadable) after startup confirmed
    /// the snapshot a consumption-day backfill was computed from. The live
    /// bytes were preserved and the backfill was not published.
    case ledgerChangedDuringBackfill
    case writeFailed(underlying: Error)
    /// A category file exists but cannot be read or decoded. The original is
    /// preserved and writes are blocked so defaults never overwrite it.
    case unreadableCategories
    /// Data integrity is not confirmed, so accounting is paused until reopen.
    case recoveryRequired
    /// A history file exists but cannot be read or decoded. The original is
    /// preserved and every write is blocked so pasted historical totals are
    /// never silently replaced by an empty snapshot.
    case unreadableHistory
    /// An observed history file exists but neither its directory nor the
    /// file itself could be confirmed backup-excluded. Writes are blocked so
    /// history is never persisted without on-device protection.
    case historyProtectionUnconfirmed
    /// The user typed a whole-month summary in November 2026 or later, or a
    /// cutoff outside November 2026 / on a non-existent day. Nothing was saved.
    case invalidHistoryInput
    /// The per-record ledger is unrecovered, so its expenses may be unloaded.
    /// An opening balance would represent an unknown covered set and must not
    /// be saved or replaced until the ledger is trusted again.
    case openingBalancePausedForRecovery

    var errorDescription: String? {
        switch self {
        case .unreadableLedger:
            return "账本文件无法读取，已保留原文件且不会覆盖，请联系维护。"
        case .migrationPending:
            return "历史账本尚未迁移完成，已保留原文件且暂时禁止记账，请稍后重试。"
        case .backupExclusionFailed:
            return "无法设置备份排除标记，本次未保存。"
        case .migrationVerificationFailed:
            return "历史账本迁移校验失败，已保留原文件。"
        case .writeVerificationFailed:
            return "保存校验失败，本次未保存。"
        case .ledgerChangedDuringBackfill:
            return "账本在回填期间发生变化，已保留原文件并暂停记账，请重新打开应用重试。"
        case .writeFailed(let underlying):
            return "保存失败：\(underlying.localizedDescription)"
        case .unreadableCategories:
            return "分类文件无法读取，已保留原文件且不会覆盖，请联系维护。"
        case .recoveryRequired:
            return "账本暂需恢复，记账已暂停。请重新打开应用重试。"
        case .unreadableHistory:
            return "历史汇总文件无法读取，已保留原文件且不会覆盖，请联系维护。"
        case .historyProtectionUnconfirmed:
            return "历史汇总文件未能确认仅存本机，已暂停保存并保留原文件，请重新打开应用重试。"
        case .invalidHistoryInput:
            return "历史数据无效：月度汇总须为 2026 年 11 月之前的有效年月；期初截止日须为 2026 年 11 月的有效日期。"
        case .openingBalancePausedForRecovery:
            return "账本暂需恢复，期初累计暂不可保存。请重新打开应用重试。"
        }
    }
}

/// Owns the ledger and persists it to a JSON file inside a dedicated,
/// backup-excluded directory in the app's own Application Support.
/// Nothing is written outside the device's app storage.
final class LedgerStore: ObservableObject {
    @Published private(set) var expenses: [Expense] = []
    /// True when a legacy copy was retained because cleanup or its
    /// backup-exclusion marker could not be confirmed. Surfaces the recovery
    /// state instead of silently ignoring a protection failure.
    @Published private(set) var legacyCleanupPending = false
    /// The single source of truth for whether accounting may open and writes
    /// are allowed. `legacyCleanupPending` alone must not decide writability.
    @Published private(set) var readiness: LedgerReadiness = .ready

    private let fileURL: URL
    private let legacyFileURL: URL?
    /// Whether a one-time consumption-day backfill may be published. A unit
    /// test host launches the real app entry against production paths; it must
    /// never rewrite the on-device ledger just because it decoded old records.
    private let backfillConsumptionDays: Bool
    private var isLedgerUnreadable = false
    private var migrationPending = false

    /// Presence of the live ledger observed while reconciling a legacy copy.
    /// The single best-effort marker decision at launch includes this: a
    /// migration may be the only phase that sees an on-device file, because a
    /// later marking read can report a definite absence while the file is
    /// still on disk. Leaving it out skips the marker on that real file.
    private var migrationTargetObservation: LedgerFilePresence?

    /// The exact bytes of the live ledger verified by the migration that just
    /// ran. Later startup reads must agree with this snapshot; otherwise the
    /// complete migrated records could be replaced by an empty snapshot that
    /// a following save would publish over them. Nil when no migration ran or
    /// it could not be verified.
    private var migrationVerifiedTargetSnapshot: Data?

    /// Consumption days computed from timestamps for an old ledger, held in
    /// memory until the launch consistency check and protection check confirm
    /// the bytes we decoded are the on-device ledger. Publishing inside
    /// `load()` makes the later reads disagree and can overwrite a newer
    /// snapshot, so the atomic publish is deferred to `init` after those checks.
    private var pendingConsumptionDayData: Data?

    /// The exact live-ledger bytes confirmed by the launch consistency check
    /// that `pendingConsumptionDayData` was derived from. The backfill may only
    /// be published while the live file still matches these bytes; a change
    /// between launch and publish must never be replaced by the older snapshot.
    private var backfillBaseSnapshot: Data?

    /// Test-only seam: replaces the backup-exclusion enforcer so tests can
    /// simulate the platform refusing to apply the marker. Production code
    /// never passes one.
    private let backupExclusionOverride: ((URL) throws -> Void)?

    /// Test-only seam: replaces legacy-copy cleanup so tests can simulate a
    /// failed removal. Production code never passes one.
    private let removeLegacyFile: ((URL) throws -> Void)?

    /// Test-only seam: injects a failure into the final atomic publish before
    /// it makes the staging file visible. Production never passes one. The
    /// publish is a single atomic rename (ordinary saves) or atomic create via
    /// `link` (first migration); either is atomic, so on failure neither the
    /// staging file nor the live ledger is moved or rewritten. The seam can
    /// only short-circuit the publish — it can never relocate or delete the
    /// original.
    private let finalPublishFailure: (() -> Error?)?

    /// Test-only seam: replaces ledger file reads so tests can simulate a path
    /// that cannot be inspected (permission denied) without depending on
    /// host filesystem permissions. Production code never passes one; it
    /// reads with `Data(contentsOf:)`.
    private let readLedgerFile: ((URL) throws -> Data)?

    /// Production ledger location.
    static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("PayLedger", isDirectory: true)
            .appendingPathComponent("ledger.json")
    }

    /// Pre-migration location from the first version, read-only after migration.
    static var legacyDefaultFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ledger.json")
    }

    /// - Parameters:
    ///   - fileURL: on-device ledger location. Tests inject a temporary file.
    ///   - legacyFileURL: pre-migration file. Defaults only for the production
    ///     location; injected URLs skip migration unless explicitly supplied.
    ///   - backupExclusion: test-only exclusion enforcer override.
    init(fileURL: URL? = nil, legacyFileURL: URL? = nil,
         backupExclusion: ((URL) throws -> Void)? = nil,
         removeLegacyFile: ((URL) throws -> Void)? = nil,
         finalPublishFailure: (() -> Error?)? = nil,
         readLedgerFile: ((URL) throws -> Data)? = nil,
         backfillConsumptionDays: Bool = true) {
        let fm = FileManager.default
        let usingDefaultLocation = fileURL == nil
        self.fileURL = fileURL ?? Self.defaultFileURL
        self.legacyFileURL = legacyFileURL ?? (usingDefaultLocation ? Self.legacyDefaultFileURL : nil)
        self.backupExclusionOverride = backupExclusion
        self.removeLegacyFile = removeLegacyFile
        self.finalPublishFailure = finalPublishFailure
        self.readLedgerFile = readLedgerFile
        self.backfillConsumptionDays = backfillConsumptionDays

        if usingDefaultLocation {
            let directory = self.fileURL.deletingLastPathComponent()
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        reconcileLegacyLedger()
        // A migrated-but-unconfirmed ledger still shows its decoded records;
        // the banner communicates the paused state. Only an unfinished
        // migration skips loading, so no partial snapshot is ever presented.
        // Keep the presence observed while loading: a later read during
        // marking can disagree, but it cannot un-observe a ledger accounting
        // has already opened against.
        var launchPresence: LedgerFilePresence?
        if !migrationPending {
            launchPresence = load()
        }
        // Protect the ledger's directory even on a read-only first run; the
        // directory marker also covers the file during atomic renames.
        try? applyBackupExclusion(to: self.fileURL.deletingLastPathComponent())
        // Read the live ledger for the marking and protection phases. One
        // launch may get different answers from these reads; every observation
        // feeds the single best-effort marker decision below, and the
        // protection check decides whether those disagreements pause opening.
        let markingPresence = readLedgerPresence(at: self.fileURL)
        let protectionPresence = confirmSingleLedgerProtection(launchPresence: launchPresence,
                                                               markingPresence: markingPresence)
        // An on-device ledger carries its own backup-exclusion marker
        // independently of whether its bytes can be read and independently of
        // a pending migration or a disagreement between reads. In particular,
        // a protection read that is the FIRST to discover a real ledger must
        // still mark it before the recovery decision returns. A genuine first
        // run (every read reports a definite absence) is left untouched.
        bestEffortMarkLedgerFile(observations: [launchPresence, markingPresence,
                                                protectionPresence, migrationTargetObservation])
        // One-time consumption-day backfill is the last fallible write of
        // startup. Publish only after the launch reads agree, the verified
        // migration snapshot matches, and a protected directory is confirmed;
        // a refused publish keeps the original bytes and pauses accounting so
        // an unpersisted attribution can never gate an opening balance.
        finalizeConsumptionDayBackfill()
    }

    /// Commits a new expense with a single atomic replacement. All fallible
    /// work happens in `commit`, so any failure leaves the real ledger
    /// byte-for-byte untouched and memory unmodified.
    func addExpense(amountCents: Int, categoryID: String, subcategoryID: String? = nil,
                    date: Date = Date()) throws {
        guard amountCents > 0 else { return }
        guard !migrationPending else { throw LedgerStoreError.migrationPending }
        guard readiness != .needsRecovery else { throw LedgerStoreError.recoveryRequired }
        guard !isLedgerUnreadable else { throw LedgerStoreError.unreadableLedger }

        // Capture the chosen calendar day now, in the device calendar at
        // recording time. Storing components (not the instant) is what keeps a
        // later time-zone change from moving this record across the cutoff.
        let day = ConsumptionDay.from(date, calendar: LedgerStats.calendar)
        let updated = expenses + [Expense(amountCents: amountCents, categoryID: categoryID,
                                          subcategoryID: subcategoryID, date: date,
                                          consumptionDay: day)]
        try commit(updated)
        expenses = updated
    }

    /// Encodes a full snapshot and publishes it with a single atomic rename.
    private func commit(_ records: [Expense]) throws {
        try commitData(try JSONEncoder().encode(records))
    }

    /// Atomically publishes raw snapshot bytes. Taking the bytes directly
    /// lets a first migration stage the legacy file's exact bytes:
    /// JSONEncoder key order is not stable across encoder instances, so
    /// re-encoding decoded records would change them. Every fallible step
    /// (directory marker, staged write, staged marker, byte verification) runs
    /// on a staging file in the same directory, so the live ledger is untouched
    /// until the final publish. The staged file's exclusion marker travels
    /// with the inode; nothing fallible follows the publish.
    ///
    /// - Parameter failIfTargetExists: when true the publish uses an atomic
    ///   create that fails if the live ledger already exists. First migration
    ///   checked for absence earlier; a target appearing before publish must
    ///   never be overwritten. Normal saves pass false and replace in place.
    /// - Parameter expectedCurrentData: when provided, the publish is refused
    ///   unless the live ledger still byte-matches this snapshot. The check and
    ///   the publish are consecutive synchronous steps with no suspension
    ///   point, so a change during staging cannot be replaced by an older byte
    ///   snapshot. Production writes are serialized through this store.
    private func commitData(_ data: Data, failIfTargetExists: Bool = false,
                            expectedCurrentData: Data? = nil) throws {
        let directory = fileURL.deletingLastPathComponent()
        let staging = directory.appendingPathComponent(Self.stagingFileName)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            // Protect the stable directory first: it covers the ledger during
            // the atomic publish. A refusal here aborts before any file exists.
            try applyBackupExclusion(to: directory)
            try data.write(to: staging, options: .atomic)
            try applyBackupExclusion(to: staging)
            guard try Data(contentsOf: staging) == data else {
                throw LedgerStoreError.writeVerificationFailed
            }
            if let finalPublishFailure, let failure = finalPublishFailure() {
                throw failure
            }
            // The snapshot startup confirmed must still be the live ledger
            // immediately before the atomic publish. A concurrent update (or a
            // path that became unreadable) keeps its bytes untouched and aborts
            // the publish; the caller enters recovery and retries next launch.
            if let expectedCurrentData {
                let current = readLedgerPresence(at: fileURL)
                guard case .present(let actual) = current, actual == expectedCurrentData else {
                    throw LedgerStoreError.ledgerChangedDuringBackfill
                }
            }
            if failIfTargetExists {
                // link(2) is atomic and fails with EEXIST when the destination
                // exists, so a live ledger that appeared after the absence
                // check cannot be replaced. Both originals stay byte-for-byte;
                // the staging entry is removed by `defer`, and the target keeps
                // the same inode together with its backup-exclusion marker.
                guard link(staging.path, fileURL.path) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
                }
            } else {
                // Single atomic publish within the ledger's own directory.
                guard rename(staging.path, fileURL.path) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
                }
            }
        } catch {
            if let storeError = error as? LedgerStoreError { throw storeError }
            throw LedgerStoreError.writeFailed(underlying: error)
        }
    }

    /// Names the transient file used to stage a save before its atomic commit.
    static func isStagingFile(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix(".ledger-staging-")
    }

    private static var stagingFileName: String {
        ".ledger-staging-\(UUID().uuidString).tmp"
    }

    func totalCents(in interval: DateInterval) -> Int? {
        LedgerStats.totalCents(expenses, in: interval)
    }

    // MARK: - Private

    /// Distinguishes a definitely-absent ledger from one whose path cannot be
    /// inspected. `FileManager.fileExists` returns false for both, so it must
    /// never be used to decide that a ledger is a genuine first run.
    private enum LedgerFilePresence {
        case present(Data)
        case absent
        case inaccessible

        /// Two reads agree only when they classify the path the same way and,
        /// for a readable ledger, see the same bytes.
        func isConsistent(with other: LedgerFilePresence) -> Bool {
            switch (self, other) {
            case (.absent, .absent), (.inaccessible, .inaccessible):
                return true
            case (.present(let lhs), .present(let rhs)):
                return lhs == rhs
            default:
                return false
            }
        }

        /// True when an observation means a file occupies the ledger path and
        /// therefore needs a backup-exclusion marker, even if it cannot be read.
        var indicatesLiveFile: Bool {
            switch self {
            case .present, .inaccessible: return true
            case .absent: return false
            }
        }
    }

    private func readLedgerPresence(at url: URL) -> LedgerFilePresence {
        do {
            return .present(try readLedgerData(at: url))
        } catch {
            // Only a definite "no such file" is a first run. Permission and
            // other read failures leave data integrity unconfirmed.
            let nsError = error as NSError
            let missing = (nsError.domain == NSCocoaErrorDomain &&
                (nsError.code == CocoaError.Code.fileNoSuchFile.rawValue ||
                 nsError.code == CocoaError.Code.fileReadNoSuchFile.rawValue)) ||
                (nsError.domain == NSPOSIXErrorDomain && nsError.code == ENOENT)
            return missing ? .absent : .inaccessible
        }
    }

    private func readLedgerData(at url: URL) throws -> Data {
        if let readLedgerFile { return try readLedgerFile(url) }
        return try Data(contentsOf: url)
    }

    /// Best-effort backup exclusion for the live ledger file, based on every
    /// presence observed this launch. A read that first discovers a real
    /// ledger during the protection check must not leave that file unmarked:
    /// reads can disagree while still agreeing a file occupies the path, and
    /// each such observation independently calls for protection. Only when
    /// every read reports a definite absence (a genuine first run) is the path
    /// left untouched.
    private func bestEffortMarkLedgerFile(observations: [LedgerFilePresence?]) {
        guard observations.contains(where: { $0?.indicatesLiveFile ?? false }) else { return }
        try? applyBackupExclusion(to: fileURL)
    }

    /// Confirms that the directory holding a single on-device ledger is
    /// protected before accounting opens. Publishing a staged save requires a
    /// protected directory (the staging file is created there), so a directory
    /// that cannot be confirmed pauses accounting even when the ledger file's
    /// own marker is intact — otherwise the home view would report `ready`
    /// while every save failed. The file's own marker is applied best-effort
    /// by `bestEffortMarkLedgerFile()`, independently of this check. No-ops for
    /// a first run with no file or while a migration is pending and will decide
    /// readiness.
    private func confirmSingleLedgerProtection(launchPresence: LedgerFilePresence?,
                                               markingPresence: LedgerFilePresence) -> LedgerFilePresence? {
        guard !migrationPending else { return nil }
        // Launch reads the live ledger more than once. The protection check
        // must use the same presence classification as loading: a definite
        // absence is a genuine first run, a readable file confirms its
        // protected directory, and a path that cannot be confirmed pauses
        // accounting. Bailing out on an unreadable path used to leave `ready`
        // even when the directory marker failed, so a save could publish over
        // records that a later read would have discovered.
        let protectionPresence = readLedgerPresence(at: fileURL)
        // One launch must reach a single conclusion about the on-device
        // ledger. Reads that disagree make the snapshot loaded into memory
        // untrustworthy: an "absent" load followed by a read that finds the
        // real 87.65 ledger must never open with an empty snapshot, or the
        // next save would overwrite that record.
        let verifiedSnapshot: LedgerFilePresence? = migrationVerifiedTargetSnapshot.map { .present($0) }
        for observation in [launchPresence, markingPresence, verifiedSnapshot].compactMap({ $0 }) {
            guard observation.isConsistent(with: protectionPresence) else {
                readiness = .needsRecovery
                return protectionPresence
            }
        }
        switch protectionPresence {
        case .absent:
            return protectionPresence
        case .inaccessible:
            readiness = .needsRecovery
        case .present:
            let directoryProtected = (try? applyBackupExclusion(to: fileURL.deletingLastPathComponent())) != nil
            guard directoryProtected else {
                readiness = .needsRecovery
                return protectionPresence
            }
        }
        return protectionPresence
    }

    /// Publishes a computed consumption-day backfill only once startup has
    /// agreed on a single, protected snapshot. `launchPresence`, the marking
    /// read, the protection read and the migration-verified snapshot have all
    /// been reconciled by this point (see `init`), so an in-memory day derived
    /// from a stale or partial read is never written over the on-device ledger.
    /// A refused publish leaves the original bytes untouched and pauses
    /// accounting; a later launch retries the one-time backfill.
    private func finalizeConsumptionDayBackfill() {
        guard backfillConsumptionDays,
              let data = pendingConsumptionDayData,
              !migrationPending,
              !isLedgerUnreadable,
              readiness != .needsRecovery else { return }
        do {
            // Refuse the publish if the live ledger no longer matches the
            // snapshot startup verified. The original bytes are kept and the
            // next launch recomputes the backfill against whatever is on disk.
            try commitData(data, expectedCurrentData: backfillBaseSnapshot)
            // Startup continues against the newly published snapshot.
            migrationVerifiedTargetSnapshot = data
        } catch {
            // The atomic publish moved or rewrote nothing; keep the original
            // bytes and do not open on an attribution we failed to persist.
            readiness = .needsRecovery
        }
        pendingConsumptionDayData = nil
        backfillBaseSnapshot = nil
    }

    @discardableResult
    private func load() -> LedgerFilePresence {
        let presence = readLedgerPresence(at: fileURL)
        switch presence {
        case .absent:
            // No ledger at all: a genuine first run, so an empty ledger is fine.
            return presence
        case .present(let data):
            do {
                var decoded = try JSONDecoder().decode([Expense].self, from: data)
                // A ledger written before consumption days existed has records
                // with no independent day. Establish each one's day from its
                // timestamp in the device calendar ONCE and persist it, so a
                // later restart under another time zone keeps the same
                // attribution. Original timestamp/amount/category are kept.
                let cal = LedgerStats.calendar
                var backfilled = false
                decoded = decoded.map { expense in
                    guard expense.consumptionDay == nil else { return expense }
                    backfilled = true
                    var copy = expense
                    copy.consumptionDay = ConsumptionDay.from(expense.date, calendar: cal)
                    return copy
                }
                if backfilled && backfillConsumptionDays {
                    // Establish the days in memory now, but hold the encoded
                    // snapshot for `finalizeConsumptionDayBackfill()` to publish
                    // only after startup consistency and protection are
                    // confirmed. Publishing here makes the marking/protection
                    // reads disagree with this launch read and can overwrite a
                    // newer on-device snapshot.
                    pendingConsumptionDayData = try? JSONEncoder().encode(decoded)
                    // Carry the confirmed launch bytes so the publish can
                    // refuse to replace a ledger that changed in the meantime.
                    backfillBaseSnapshot = data
                }
                expenses = decoded
            } catch {
                // A file exists but cannot be read/decoded. Preserve it byte-for-byte,
                // pause accounting, and never present an empty ledger instead.
                isLedgerUnreadable = true
                readiness = .needsRecovery
            }
        case .inaccessible:
            // The path exists but cannot be inspected (e.g. permission denied).
            // This is not a first run: keep the bytes untouched, show no partial
            // ledger, and pause accounting so no new file can be published over it.
            isLedgerUnreadable = true
            readiness = .needsRecovery
        }
        return presence
    }

    /// Sets (and verifies) the backup-exclusion marker on a URL, throwing when
    /// the platform refuses it so callers never report success while the
    /// ledger is unprotected.
    private func applyBackupExclusion(to url: URL) throws {
        if let backupExclusionOverride {
            try backupExclusionOverride(url)
            return
        }
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(excluded)
        let actual = try mutableURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        guard actual.isExcludedFromBackup == true else {
            throw LedgerStoreError.backupExclusionFailed
        }
    }

    /// Brings a legacy ledger into the new location. A failed or interrupted
    /// migration must never look like a first run: the legacy file is kept and
    /// saving from an empty ledger is blocked until a restart completes it.
    private func reconcileLegacyLedger() {
        guard let legacy = legacyFileURL else { return }
        let legacyData: Data
        switch readLedgerPresence(at: legacy) {
        case .absent:
            return
        case .inaccessible:
            // The sole copy cannot be inspected. Never treat it as absent and
            // publish a new ledger over it; pause accounting and keep the bytes.
            migrationPending = true
            legacyCleanupPending = true
            readiness = .needsRecovery
            try? applyBackupExclusion(to: legacy)
            return
        case .present(let data):
            legacyData = data
        }

        let targetPresence = readLedgerPresence(at: fileURL)
        // Record the target observation made during migration. It is the
        // earliest — and sometimes the only — evidence that a live file
        // occupies the path; the launch-time marker decision consumes it.
        migrationTargetObservation = targetPresence
        if case .inaccessible = targetPresence {
            // The live ledger path cannot be inspected either: migration must
            // not proceed against an unknown target. Keep both copies intact.
            migrationPending = true
            legacyCleanupPending = true
            readiness = .needsRecovery
            try? applyBackupExclusion(to: legacy)
            return
        }

        if case .absent = targetPresence {
            // Migration has not been performed yet. Confirm the only copy we
            // have is protected BEFORE publishing anything, then reuse the
            // same staged publish as an ordinary save: directory marker,
            // staged write, staged marker and byte verification all run on a
            // staging file, and a single atomic `link` create publishes it —
            // failing if a target appeared after the absence check. The
            // legacy bytes stay untouched until that publish succeeds.
            do {
                let data = legacyData
                // Validate before copying so an undecodable legacy file is
                // never migrated, and is preserved instead.
                _ = try JSONDecoder().decode([Expense].self, from: data)
                try applyBackupExclusion(to: legacy)
                // `commitData` verifies the staged bytes before the single
                // atomic publish, so a successful publish already guarantees
                // the live ledger matches. No post-publish re-read (which
                // could fail and trigger a rollback) is needed. Publishing
                // fails atomically if a target appeared after the absence
                // check, so such a live ledger is never overwritten.
                try commitData(data, failIfTargetExists: true)
                // The published target now holds exactly these verified bytes.
                // Record them so later startup reads must agree with this
                // snapshot: the migration removed its only other copy.
                migrationVerifiedTargetSnapshot = data
            } catch {
                // The publish never happened: keep the legacy bytes and path
                // intact, leave the target empty, and block saving until a
                // restart can retry.
                pauseAccountingAfterFailedFirstMigration()
                return
            }

            // Legacy protection was confirmed before publish and the staged
            // bytes were verified before the publish. Go straight to the shared
            // cleanup: re-applying the legacy marker here can spuriously fail
            // and strand two complete copies in a recovery state.
            cleanupLegacyCopy(legacy)
            return
        }

        // Both copies exist. Only drop the legacy file after confirming every
        // one of its expenses is present in the target AND both copies carry
        // their backup-exclusion marker: after a failed cleanup the two
        // legitimately diverge as new saves land in the target. If either copy
        // cannot be decoded, the records are incomplete — pause accounting.
        guard case .present(let targetData) = targetPresence,
              let legacyRecords = try? JSONDecoder().decode([Expense].self, from: legacyData),
              let targetRecords = try? JSONDecoder().decode([Expense].self, from: targetData) else {
            protectLegacyAndReport(legacy)
            readiness = .needsRecovery
            return
        }
        // Compare by original fields, not full `Expense` equality: a retained
        // legacy copy may lack the consumption day that the live copy already
        // persisted. Treating that backfill-only difference as a new record
        // would import the same UUID twice after a failed cleanup.
        let targetContainsAllLegacy = legacyRecords.allSatisfy { legacy in
            targetRecords.contains { $0.hasSameOriginalFields(as: legacy) }
        }
        if targetContainsAllLegacy {
            // This target snapshot was decoded and confirmed to hold every
            // legacy record; it is the complete ledger migration validated.
            // Later startup reads must agree with it before accounting opens.
            migrationVerifiedTargetSnapshot = targetData
            // Confirm both copies are protected BEFORE removing the legacy one.
            // A protection failure is a recovery condition; a deletion failure
            // of two already-protected copies only defers cleanup.
            do {
                try applyBackupExclusion(to: fileURL)
                try applyBackupExclusion(to: legacy)
            } catch {
                legacyCleanupPending = true
                readiness = .needsRecovery
                try? applyBackupExclusion(to: legacy)
                return
            }
            cleanupLegacyCopy(legacy)
            return
        }

        // The legacy copy holds records the target lacks. The partial target
        // must never be shown as the complete ledger (that silently loses the
        // legacy expenses). Merge both copies into one snapshot and commit it
        // atomically before accounting opens.
        var merged = targetRecords
        // Skip a legacy record whose original fields already exist in the
        // merge (e.g. the live copy's backfilled twin). Keep the live copy's
        // persisted consumption day rather than appending a second copy.
        for record in legacyRecords where !merged.contains(where: { $0.hasSameOriginalFields(as: record) }) {
            merged.append(record)
        }
        do {
            try commit(merged)
            let committedData = try Data(contentsOf: fileURL)
            let committedRecords = try JSONDecoder().decode([Expense].self, from: committedData)
            guard legacyRecords.allSatisfy({ legacy in
                    committedRecords.contains { $0.hasSameOriginalFields(as: legacy) }
                  }),
                  targetRecords.allSatisfy({ target in
                    committedRecords.contains { $0.hasSameOriginalFields(as: target) }
                  }) else {
                throw LedgerStoreError.migrationVerificationFailed
            }
            // The published, re-read snapshot is the complete ledger. Startup
            // consistency is judged against these post-publish bytes, not the
            // partial target seen before the merge.
            migrationVerifiedTargetSnapshot = committedData
            try applyBackupExclusion(to: legacy)
        } catch {
            // An incomplete merge or an unconfirmable retained copy is a
            // failed migration: keep the recoverable legacy copy, block
            // writes, and do not load the partial target as if it were the
            // whole ledger. A restart can retry the merge.
            migrationPending = true
            legacyCleanupPending = true
            readiness = .needsRecovery
            try? applyBackupExclusion(to: legacy)
            return
        }

        // The full ledger is merged and every retained copy is confirmed
        // protected. Only deleting the protected legacy copy remains. Share
        // the cleanup transition used by the other two paths: a failed
        // deletion defers cleanup without hiding the complete ledger or
        // closing accounting, and a restart retries it.
        cleanupLegacyCopy(legacy)
    }

    /// Removes a protected legacy copy after its content is known to be fully
    /// present in the live ledger and every retained copy is confirmed
    /// protected. All three migration paths (first migration, two complete
    /// copies, verified merge) share this single transition so a deletion
    /// failure always defers cleanup without hiding the complete ledger or
    /// closing accounting; a restart retries. Protection/verification failures
    /// are decided by the caller and reach the recovery state instead.
    private func cleanupLegacyCopy(_ legacy: URL) {
        do {
            try removeLegacy(legacy)
            legacyCleanupPending = false
            readiness = .ready
        } catch {
            legacyCleanupPending = true
            readiness = .cleanupPending
        }
    }

    /// Keeps a copy that cannot be cleaned up, applying (and reporting) its
    /// backup-exclusion marker rather than swallowing the result.
    private func protectLegacyAndReport(_ legacy: URL) {
        do {
            try applyBackupExclusion(to: legacy)
            legacyCleanupPending = false
        } catch {
            legacyCleanupPending = true
        }
    }

    /// Pauses accounting after a failed first-migration publish — it does not
    /// roll anything back. Every existing file is kept byte-for-byte as it was.
    /// The publish uses a single atomic `link` create, so it cannot leave a
    /// partial target: a failed publish means the link never happened. Never remove
    /// or rewrite the target here — a live ledger may already occupy that path
    /// (e.g. a concurrently created copy), and deleting it would destroy the
    /// user's only record. Only the legacy copy's best-effort protection and
    /// the recovery state are applied; the name reflects that it only pauses.
    private func pauseAccountingAfterFailedFirstMigration() {
        if let legacy = legacyFileURL {
            try? applyBackupExclusion(to: legacy)
        }
        migrationPending = true
        readiness = .needsRecovery
    }

    private func removeLegacy(_ url: URL) throws {
        if let removeLegacyFile {
            try removeLegacyFile(url)
        } else {
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// Owns the user-editable two-level category tree and persists it on-device
/// alongside the ledger. Category ids are stable: renaming only changes the
/// display name, so historical expenses keep their date and amount and show
/// the current name. Like the ledger, the file is excluded from backup.
final class CategoryStore: ObservableObject {
    @Published private(set) var groups: [ExpenseCategoryGroup]
    /// True when the category file exists but cannot be read or decoded.
    /// The original bytes are preserved and every write is blocked so a
    /// damaged tree can never be silently replaced by defaults.
    @Published private(set) var isUnreadable = false

    private let fileURL: URL
    /// Test-only seam: replaces the backup-exclusion enforcer so tests can
    /// simulate the platform refusing the marker or a readback that is false.
    /// Production never passes one.
    private let backupExclusionOverride: ((URL) throws -> Void)?
    /// Test-only seam: injects a failure into the final atomic publish before
    /// it becomes visible. Production never passes one.
    private let finalPublishFailure: (() -> Error?)?
    /// Test-only seam: replaces category reads so tests can simulate a path
    /// that cannot be inspected without relying on host permissions.
    private let readCategoriesFile: ((URL) throws -> Data)?

    static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("PayLedger", isDirectory: true)
            .appendingPathComponent("categories.json")
    }

    /// DEBUG-only isolated path derived from the validated test ledger URL so
    /// each UI test gets its own tree while a restart with the same ledger
    /// reuses it. Reusing `PayLedgerApp.ledgerFileURL` means the same name
    /// validation applies: an invalid or missing test name cannot escape the
    /// isolated directory or resolve to the production category tree.
    ///
    /// The category filename is deliberately prefixed with `categories-`
    /// instead of suffixed with `-categories`: the ledger validator accepts
    /// any bare `uitest-<safe>.json`, so `uitest-x-categories.json` would itself
    /// be a valid ledger name and two example names could cross-read each
    /// other's category/ledger JSON. The `categories-` prefix is never
    /// accepted as a ledger name.
    static func testFileURL(environment: [String: String]) -> URL? {
        #if DEBUG
        guard let ledgerURL = PayLedgerApp.ledgerFileURL(environment: environment) else { return nil }
        let stem = ledgerURL.deletingPathExtension().lastPathComponent
        return ledgerURL.deletingLastPathComponent()
            .appendingPathComponent("categories-\(stem).json")
        #else
        return nil
        #endif
    }

    init(fileURL: URL? = nil,
         backupExclusion: ((URL) throws -> Void)? = nil,
         finalPublishFailure: (() -> Error?)? = nil,
         readCategoriesFile: ((URL) throws -> Data)? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        self.backupExclusionOverride = backupExclusion
        self.finalPublishFailure = finalPublishFailure
        self.readCategoriesFile = readCategoriesFile
        // Defaults are held in memory only until a first edit on a genuinely
        // missing file publishes them. An existing unreadable file is never
        // replaced by this in-memory tree.
        self.groups = ExpenseCategories.defaults
        self.isUnreadable = false

        let fm = FileManager.default
        let directory = self.fileURL.deletingLastPathComponent()
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // Protect the directory first: a staged save is created here, so a
        // directory that cannot be protected must be fixed before publishing.
        try? applyBackupExclusion(to: directory)

        let data: Data
        do {
            data = try readCategoriesData(at: self.fileURL)
        } catch {
            // Only a definite "no such file" is a first run. Any other read
            // failure leaves a possible live file unconfirmed, so writes block.
            if Self.isMissingFileError(error) { return }
            self.isUnreadable = true
            return
        }
        do {
            self.groups = try JSONDecoder().decode([ExpenseCategoryGroup].self, from: data)
        } catch {
            // Keep the original bytes untouched and surface the damage.
            self.isUnreadable = true
            return
        }
        try? applyBackupExclusion(to: self.fileURL)
    }

    private func readCategoriesData(at url: URL) throws -> Data {
        if let readCategoriesFile { return try readCategoriesFile(url) }
        return try Data(contentsOf: url)
    }

    /// Only a definite "no such file" is a genuine first run; permission and
    /// other read failures must never be mistaken for an absent file.
    private static func isMissingFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return (nsError.domain == NSCocoaErrorDomain &&
                (nsError.code == CocoaError.Code.fileNoSuchFile.rawValue ||
                 nsError.code == CocoaError.Code.fileReadNoSuchFile.rawValue)) ||
               (nsError.domain == NSPOSIXErrorDomain && nsError.code == ENOENT)
    }

    /// Primary name shown on ledger rows. Falls back to the legacy mapping
    /// for ids created before the category tree existed.
    func primaryName(for id: String) -> String {
        groups.first { $0.id == id }?.name ?? ExpenseCategory.displayName(for: id)
    }

    func subcategories(in primaryID: String) -> [ExpenseSubcategory] {
        groups.first { $0.id == primaryID }?.subcategories ?? []
    }

    func subcategoryName(primaryID: String, subcategoryID: String?) -> String? {
        guard let subcategoryID else { return nil }
        return subcategories(in: primaryID).first { $0.id == subcategoryID }?.name
    }

    /// Keeps a subcategory selection only while it still belongs to the
    /// current primary; otherwise selects that primary's first child (nil
    /// when it has none). Used when switching primaries or when the tree is
    /// edited while the entry form is open.
    func reconciledSubcategoryID(primaryID: String, current: String?) -> String? {
        let valid = subcategories(in: primaryID).map(\.id)
        if let current, valid.contains(current) { return current }
        return valid.first
    }

    func addPrimary(name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = groups
        updated.append(ExpenseCategoryGroup(id: Self.newID(prefix: "cat"),
                                            name: trimmed, subcategories: []))
        try persistAndPublish(updated)
    }

    func renamePrimary(id: String, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = groups
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        updated[index].name = trimmed
        try persistAndPublish(updated)
    }

    func addSubcategory(primaryID: String, name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = groups
        guard let index = updated.firstIndex(where: { $0.id == primaryID }) else { return }
        updated[index].subcategories.append(
            ExpenseSubcategory(id: Self.newID(prefix: "sub"), name: trimmed))
        try persistAndPublish(updated)
    }

    func renameSubcategory(primaryID: String, subcategoryID: String, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = groups
        guard let primaryIndex = updated.firstIndex(where: { $0.id == primaryID }),
              let subIndex = updated[primaryIndex].subcategories.firstIndex(where: { $0.id == subcategoryID })
        else { return }
        updated[primaryIndex].subcategories[subIndex].name = trimmed
        try persistAndPublish(updated)
    }

    private func persistAndPublish(_ updated: [ExpenseCategoryGroup]) throws {
        try persist(updated)
        groups = updated
    }

    private func persist(_ groups: [ExpenseCategoryGroup]) throws {
        guard !isUnreadable else { throw LedgerStoreError.unreadableCategories }
        let data = try JSONEncoder().encode(groups)
        let directory = fileURL.deletingLastPathComponent()
        let staging = directory.appendingPathComponent(Self.stagingFileName)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            // Every fallible step runs on the staging file; the live tree is
            // untouched until the single atomic publish, so a failed
            // protection or write check never leaves disk and memory disagreed.
            try applyBackupExclusion(to: directory)
            try data.write(to: staging, options: .atomic)
            try applyBackupExclusion(to: staging)
            guard try Data(contentsOf: staging) == data else {
                throw LedgerStoreError.writeVerificationFailed
            }
            if let finalPublishFailure, let failure = finalPublishFailure() {
                throw failure
            }
            guard rename(staging.path, fileURL.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
            }
        } catch {
            if let storeError = error as? LedgerStoreError { throw storeError }
            throw LedgerStoreError.writeFailed(underlying: error)
        }
    }

    private static var stagingFileName: String {
        ".categories-staging-\(UUID().uuidString).tmp"
    }

    private static func newID(prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString)"
    }

    /// Sets (and verifies) the backup-exclusion marker, throwing when the
    /// platform refuses it or a readback comes back false. A swallowed false
    /// used to report success while leaving the live file unprotected.
    private func applyBackupExclusion(to url: URL) throws {
        if let backupExclusionOverride {
            try backupExclusionOverride(url)
        } else {
            var excluded = URLResourceValues()
            excluded.isExcludedFromBackup = true
            var mutableURL = url
            try mutableURL.setResourceValues(excluded)
        }
        let actual = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        guard actual.isExcludedFromBackup == true else {
            throw LedgerStoreError.backupExclusionFailed
        }
    }
}

// MARK: - Issue 04: historical amounts store

/// Owns the month-level historical summaries and the opening balance the user
/// enters because the old app could not export a ledger. Like the ledger and
/// the category tree, the file lives in the app's own backup-excluded directory
/// on this device. Each save is a protected staging write followed by one
/// atomic publish, so a failed protection or verification never leaves disk
/// and memory disagreeing.
final class HistoryStore: ObservableObject {
    @Published private(set) var snapshot = HistorySnapshot()
    /// True when a history file exists but cannot be read or decoded. The
    /// original bytes are preserved and every write is blocked.
    @Published private(set) var isUnreadable = false
    /// True when an observed history file could not be confirmed
    /// backup-excluded at either the directory or the file level.
    @Published private(set) var isProtectionUnconfirmed = false
    /// History cannot be trusted: unreadable, or protection unconfirmed.
    /// Totals that include history must be shown as unavailable, and writes
    /// are blocked, so incomplete or unprotected data never looks complete.
    var isUnavailable: Bool { isUnreadable || isProtectionUnconfirmed }
    /// Text shown wherever a history-dependent total would otherwise appear.
    static let unavailableText = "历史不可用"
    /// Set by the app to the per-record ledger's trust state. An opening
    /// balance represents every expense through its cutoff, so it must not be
    /// saved while the ledger is unrecovered and those records may be
    /// unloaded. Nil in isolated history-only tests (no ledger gate).
    var openingBalanceAllowed: (() -> Bool)?

    private let fileURL: URL
    private let backupExclusionOverride: ((URL) throws -> Void)?
    private let finalPublishFailure: (() -> Error?)?
    private let readHistoryFile: ((URL) throws -> Data)?

    static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("PayLedger", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    /// DEBUG-only isolated path derived from the already-validated test ledger
    /// URL, so a restart with the same ledger reuses the same history. The
    /// `history-` prefix is never accepted as a ledger name, keeping all test
    /// files mutually independent and away from production paths.
    static func testFileURL(environment: [String: String]) -> URL? {
        #if DEBUG
        guard let ledgerURL = PayLedgerApp.ledgerFileURL(environment: environment) else { return nil }
        let stem = ledgerURL.deletingPathExtension().lastPathComponent
        return ledgerURL.deletingLastPathComponent()
            .appendingPathComponent("history-\(stem).json")
        #else
        return nil
        #endif
    }

    init(fileURL: URL? = nil,
         backupExclusion: ((URL) throws -> Void)? = nil,
         finalPublishFailure: (() -> Error?)? = nil,
         readHistoryFile: ((URL) throws -> Data)? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        self.backupExclusionOverride = backupExclusion
        self.finalPublishFailure = finalPublishFailure
        self.readHistoryFile = readHistoryFile

        let fm = FileManager.default
        let directory = self.fileURL.deletingLastPathComponent()
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // Directory exclusion is attempted first; the file-level attempt
        // below is independent, so a failed directory marker never skips it.
        let directoryProtected = (try? applyBackupExclusion(to: directory)) != nil

        let data: Data?
        do {
            data = try readHistoryData(at: self.fileURL)
        } catch {
            // Only a definite missing file is a first run. Any other read
            // failure leaves a possible live file unconfirmed, so writes block.
            if Self.isMissingFileError(error) { return }
            data = nil
            isUnreadable = true
        }

        // A file that was observed to exist gets its own, verified backup
        // exclusion — including on read/decode failures — so the original
        // bytes stay protected on this device no matter what went wrong.
        if data != nil || isUnreadable {
            let fileProtected = (try? applyBackupExclusion(to: self.fileURL)) != nil
            if !directoryProtected && !fileProtected {
                isProtectionUnconfirmed = true
            }
        }

        guard let data, !isUnreadable else { return }
        do {
            let decoded = try JSONDecoder().decode(HistorySnapshot.self, from: data)
            // Decoding alone only proves the JSON is structurally valid. A
            // snapshot with duplicate months, an out-of-range period, a
            // negative amount or a bad cutoff would silently corrupt month
            // and year totals, so reject it exactly like an unreadable file:
            // keep the original bytes, publish nothing, and block all writes.
            guard decoded.isValid else {
                isUnreadable = true
                return
            }
            snapshot = decoded
        } catch {
            isUnreadable = true
        }
    }

    /// Adds or replaces one historical month. Keying by (year, month) makes a
    /// repeated save replace the value instead of adding a second summary that
    /// would be counted twice.
    func setHistoricalMonth(year: Int, month: Int, amountCents: Int) throws {
        // A historical month total may be zero (no pre-enablement spend), but
        // never negative. Only per-record expenses require a positive amount.
        guard amountCents >= 0, HistoryInput.isValidHistoricalMonth(year: year, month: month) else {
            throw LedgerStoreError.invalidHistoryInput
        }
        var updated = snapshot
        let item = HistoricalMonth(year: year, month: month, amountCents: amountCents)
        if let index = updated.monthlySummaries.firstIndex(where: { $0.key == item.key }) {
            updated.monthlySummaries[index] = item
        } else {
            updated.monthlySummaries.append(item)
        }
        updated.monthlySummaries.sort { ($0.year, $0.month) < ($1.year, $1.month) }
        try persistAndPublish(updated)
    }

    /// Sets (or replaces) the single opening balance. Re-saving never creates
    /// a second cumulative entry. The cutoff is stored as validated calendar
    /// components; the enablement day is the following calendar day.
    func setOpeningBalance(amountCents: Int, cutoffYear: Int,
                           cutoffMonth: Int, cutoffDay: Int) throws {
        // The covered record set is unknown while the per-record ledger is
        // unrecovered; saving an opening now would silently exclude records
        // that reappear after recovery.
        if let allowed = openingBalanceAllowed, !allowed() {
            throw LedgerStoreError.openingBalancePausedForRecovery
        }
        // A zero opening balance is valid; negatives are still rejected.
        guard amountCents >= 0,
              HistoryInput.isValidOpeningCutoff(year: cutoffYear, month: cutoffMonth, day: cutoffDay) else {
            throw LedgerStoreError.invalidHistoryInput
        }
        var updated = snapshot
        updated.openingBalance = OpeningBalance(amountCents: amountCents,
                                                cutoffYear: cutoffYear,
                                                cutoffMonth: cutoffMonth,
                                                cutoffDay: cutoffDay)
        try persistAndPublish(updated)
    }

    /// Convenience for callers holding a Date: components are read in the
    /// ledger calendar, then validated and stored by the primary setter.
    func setOpeningBalance(amountCents: Int, cutoffDate: Date) throws {
        let parts = LedgerStats.calendar.dateComponents([.year, .month, .day], from: cutoffDate)
        try setOpeningBalance(amountCents: amountCents, cutoffYear: parts.year ?? 0,
                              cutoffMonth: parts.month ?? 0, cutoffDay: parts.day ?? 0)
    }

    private func persistAndPublish(_ updated: HistorySnapshot) throws {
        guard !isUnavailable else {
            throw isUnreadable
                ? LedgerStoreError.unreadableHistory
                : LedgerStoreError.historyProtectionUnconfirmed
        }
        try persist(updated)
        snapshot = updated
    }

    private func persist(_ snapshot: HistorySnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        let directory = fileURL.deletingLastPathComponent()
        let staging = directory.appendingPathComponent(Self.stagingFileName)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try applyBackupExclusion(to: directory)
            try data.write(to: staging, options: .atomic)
            try applyBackupExclusion(to: staging)
            guard try Data(contentsOf: staging) == data else {
                throw LedgerStoreError.writeVerificationFailed
            }
            if let finalPublishFailure, let failure = finalPublishFailure() {
                throw failure
            }
            guard rename(staging.path, fileURL.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
            }
        } catch {
            if let storeError = error as? LedgerStoreError { throw storeError }
            throw LedgerStoreError.writeFailed(underlying: error)
        }
    }

    private func readHistoryData(at url: URL) throws -> Data {
        if let readHistoryFile { return try readHistoryFile(url) }
        return try Data(contentsOf: url)
    }

    private static func isMissingFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return (nsError.domain == NSCocoaErrorDomain &&
                (nsError.code == CocoaError.Code.fileNoSuchFile.rawValue ||
                 nsError.code == CocoaError.Code.fileReadNoSuchFile.rawValue)) ||
               (nsError.domain == NSPOSIXErrorDomain && nsError.code == ENOENT)
    }

    private func applyBackupExclusion(to url: URL) throws {
        if let backupExclusionOverride {
            try backupExclusionOverride(url)
        } else {
            var excluded = URLResourceValues()
            excluded.isExcludedFromBackup = true
            var mutableURL = url
            try mutableURL.setResourceValues(excluded)
        }
        let actual = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        guard actual.isExcludedFromBackup == true else {
            throw LedgerStoreError.backupExclusionFailed
        }
    }

    private static var stagingFileName: String {
        ".history-staging-\(UUID().uuidString).tmp"
    }
}
