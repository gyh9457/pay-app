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
    case writeFailed(underlying: Error)
    /// Data integrity is not confirmed, so accounting is paused until reopen.
    case recoveryRequired

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
        case .writeFailed(let underlying):
            return "保存失败：\(underlying.localizedDescription)"
        case .recoveryRequired:
            return "账本暂需恢复，记账已暂停。请重新打开应用重试。"
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
         readLedgerFile: ((URL) throws -> Data)? = nil) {
        let fm = FileManager.default
        let usingDefaultLocation = fileURL == nil
        self.fileURL = fileURL ?? Self.defaultFileURL
        self.legacyFileURL = legacyFileURL ?? (usingDefaultLocation ? Self.legacyDefaultFileURL : nil)
        self.backupExclusionOverride = backupExclusion
        self.removeLegacyFile = removeLegacyFile
        self.finalPublishFailure = finalPublishFailure
        self.readLedgerFile = readLedgerFile

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
    }

    /// Commits a new expense with a single atomic replacement. All fallible
    /// work happens in `commit`, so any failure leaves the real ledger
    /// byte-for-byte untouched and memory unmodified.
    func addExpense(amountCents: Int, categoryID: String, date: Date = Date()) throws {
        guard amountCents > 0 else { return }
        guard !migrationPending else { throw LedgerStoreError.migrationPending }
        guard readiness != .needsRecovery else { throw LedgerStoreError.recoveryRequired }
        guard !isLedgerUnreadable else { throw LedgerStoreError.unreadableLedger }

        let updated = expenses + [Expense(amountCents: amountCents, categoryID: categoryID, date: date)]
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
    private func commitData(_ data: Data, failIfTargetExists: Bool = false) throws {
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

    @discardableResult
    private func load() -> LedgerFilePresence {
        let presence = readLedgerPresence(at: fileURL)
        switch presence {
        case .absent:
            // No ledger at all: a genuine first run, so an empty ledger is fine.
            return presence
        case .present(let data):
            do {
                expenses = try JSONDecoder().decode([Expense].self, from: data)
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
        let targetContainsAllLegacy = legacyRecords.allSatisfy { targetRecords.contains($0) }
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
        for record in legacyRecords where !merged.contains(record) {
            merged.append(record)
        }
        do {
            try commit(merged)
            let committedData = try Data(contentsOf: fileURL)
            let committedRecords = try JSONDecoder().decode([Expense].self, from: committedData)
            guard legacyRecords.allSatisfy({ committedRecords.contains($0) }),
                  targetRecords.allSatisfy({ committedRecords.contains($0) }) else {
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
