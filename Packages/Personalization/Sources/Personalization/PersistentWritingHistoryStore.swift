import Foundation
import GRDB
import Prompting

/// A writing-history store that can be both queried (for `previousUserInputs`) and written to (by
/// the recorder), and cleared in one action. Sendable so the app can record off the main actor.
public protocol WritingHistoryStoring: WritingHistoryProviding, Sendable {
    func record(_ sample: WritingHistorySample)
    func clearAll()
    func count() -> Int
}

/// No-op store used as a graceful fallback when the encrypted database can't be opened. Keeps the
/// completion pipeline alive (it just never has any personalization samples).
public struct NullWritingHistoryStore: WritingHistoryStoring {
    public init() {}
    public func samples(for query: WritingHistoryQuery) -> [String] { [] }
    public func record(_ sample: WritingHistorySample) {}
    public func clearAll() {}
    public func count() -> Int { 0 }
}

/// One row in the encrypted writing-history database. Mirrors `WritingHistorySample`
/// (`Prompting`) plus a denormalized `charCount` used for cheap longest/budget selection.
struct StoredWritingSample: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var text: String
    var appBundleIdentifier: String?
    var domain: String?
    var typingContext: String?
    var language: String?
    var createdAt: Date
    var updatedAt: Date
    var hasAcceptedCompletion: Bool
    var charCount: Int
    var selectedText: String?
    var textAfterCursor: String?
    var windowTitle: String?
    var screenText: String?
    var screenshotData: Data?
    var originDeviceID: String?

    static let databaseTableName = "writingSample"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    init(sample: WritingHistorySample) {
        self.id = nil
        self.text = sample.text
        self.appBundleIdentifier = sample.appBundleIdentifier
        self.domain = sample.domain
        self.typingContext = sample.typingContext
        self.language = sample.language
        self.createdAt = sample.createdAt
        self.updatedAt = sample.updatedAt
        self.hasAcceptedCompletion = sample.hasAcceptedCompletion
        self.charCount = sample.text.count
        self.selectedText = sample.selectedText
        self.textAfterCursor = sample.textAfterCursor
        self.windowTitle = sample.windowTitle
        self.screenText = sample.screenText
        self.screenshotData = sample.screenshotData
        self.originDeviceID = sample.originDeviceID
    }

    var asSample: WritingHistorySample {
        WritingHistorySample(
            text: text,
            appBundleIdentifier: appBundleIdentifier,
            domain: domain,
            typingContext: typingContext,
            language: language,
            createdAt: createdAt,
            updatedAt: updatedAt,
            hasAcceptedCompletion: hasAcceptedCompletion,
            selectedText: selectedText,
            textAfterCursor: textAfterCursor,
            windowTitle: windowTitle,
            screenText: screenText,
            screenshotData: screenshotData,
            originDeviceID: originDeviceID
        )
    }
}

/// On-device, opt-in writing-history store, encrypted at rest with SQLCipher. Conforms to
/// `WritingHistoryProviding` so it drops straight into the prompt builder in place of the M3
/// in-memory stub.
///
/// - Encryption: the database is opened with a Keychain-held passphrase
///   (`KeychainPassphrase`); the file on disk is unreadable without it.
/// - Privacy: all data stays in `~/Library/Application Support/KeyType/History/` and is removed in
///   one action via `clearAll()` (the app also wipes the Keychain passphrase).
/// - Resilience: `record(_:)`/`samples(for:)` never throw out to the live completion path — they
///   swallow database errors and degrade to a no-op / empty result so a storage hiccup can't break
///   typing. Construction *can* throw; the app falls back to the in-memory store in that case.
///
/// See ADR-023.
///
/// `@unchecked Sendable`: the only stored state is a GRDB `DatabaseQueue` (thread-safe; it
/// serializes access internally) and an immutable URL, so concurrent `record`/`samples` calls from
/// different actors are safe.
public final class PersistentWritingHistoryStore: WritingHistoryStoring, @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    private let databaseURL: URL

    /// Default location of the encrypted database inside Application Support.
    public static func defaultDatabaseURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support
            .appendingPathComponent("KeyType/History", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("history.sqlcipher", isDirectory: false)
    }

    /// Opens (creating if needed) the encrypted database at `databaseURL`, using `passphrase` as
    /// the SQLCipher key. Defaults resolve the standard on-device location and the Keychain
    /// passphrase. Throws if the directory, keychain, or database can't be opened.
    public init(
        databaseURL: URL? = nil,
        passphrase: String? = nil
    ) throws {
        let url = try databaseURL ?? Self.defaultDatabaseURL()
        let key = try passphrase ?? KeychainPassphrase.loadOrCreate()

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.usePassphrase(key)
        }
        self.databaseURL = url
        self.dbQueue = try DatabaseQueue(path: url.path, configuration: configuration)
        try Self.migrator.migrate(dbQueue)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-create-writingSample") { db in
            try db.create(table: StoredWritingSample.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("text", .text).notNull()
                t.column("appBundleIdentifier", .text)
                t.column("domain", .text)
                t.column("typingContext", .text)
                t.column("language", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("hasAcceptedCompletion", .boolean).notNull().defaults(to: false)
                t.column("charCount", .integer).notNull().defaults(to: 0)
            }
            try db.create(
                index: "idx_sample_bundle_updated",
                on: StoredWritingSample.databaseTableName,
                columns: ["appBundleIdentifier", "updatedAt"]
            )
        }
        migrator.registerMigration("v2-richer-context") { db in
            try db.alter(table: StoredWritingSample.databaseTableName) { t in
                t.add(column: "selectedText", .text)
                t.add(column: "textAfterCursor", .text)
                t.add(column: "windowTitle", .text)
                t.add(column: "screenText", .text)
                t.add(column: "screenshotData", .blob)
                t.add(column: "originDeviceID", .text)
            }
        }
        return migrator
    }

    /// TYLER-SYNC-2026-10-22: rows changed after `date`, oldest first (used by `HistorySync`).
    public func samplesUpdated(after date: Date, limit: Int) -> [WritingHistorySample] {
        (try? dbQueue.read { db in
            try StoredWritingSample
                .filter(Column("updatedAt") > date)
                .order(Column("updatedAt"))
                .limit(limit)
                .fetchAll(db)
                .map(\.asSample)
        }) ?? []
    }

    // MARK: - Recording

    /// Persists one writing sample, deduping against a recent identical capture from the same app
    /// (when the same text was last seen, only its `updatedAt`/acceptance is refreshed). Errors are
    /// swallowed so a storage failure can't interrupt typing.
    public func record(_ sample: WritingHistorySample) {
        let trimmed = sample.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try dbQueue.write { db in
                let existing = try StoredWritingSample
                    .filter(Column("text") == sample.text)
                    .filter(Column("appBundleIdentifier") == sample.appBundleIdentifier)
                    .fetchOne(db)
                if var existing {
                    existing.updatedAt = sample.updatedAt
                    existing.hasAcceptedCompletion = existing.hasAcceptedCompletion || sample.hasAcceptedCompletion
                    try existing.update(db)
                } else {
                    var row = StoredWritingSample(sample: sample)
                    try row.insert(db)
                }
            }
        } catch {
            // Intentionally ignored: history is best-effort and must never break the typing path.
        }
    }

    /// Total stored samples (for diagnostics / Settings stats).
    public func count() -> Int {
        (try? dbQueue.read { db in try StoredWritingSample.fetchCount(db) }) ?? 0
    }

    // MARK: - Clearing

    /// Deletes every stored sample in one action. Used by the Settings "Clear all personal data"
    /// control. Errors are swallowed.
    public func clearAll() {
        do {
            try dbQueue.write { db in
                _ = try StoredWritingSample.deleteAll(db)
            }
        } catch {
            // Best-effort; the app also wipes the Keychain passphrase as a hard backstop.
        }
    }

    // MARK: - WritingHistoryProviding

    public func samples(for query: WritingHistoryQuery) -> [String] {
        let candidates: [StoredWritingSample]
        do {
            candidates = try dbQueue.read { db -> [StoredWritingSample] in
                var request = StoredWritingSample
                    .filter(Column("charCount") >= query.minimumCharacters)
                if let bundle = query.bundleIdentifier, query.sameAppOnly {
                    request = request.filter(Column("appBundleIdentifier") == bundle)
                }
                if let language = query.language {
                    // Keep rows whose language matches or is unknown (conservative).
                    request = request.filter(
                        Column("language") == language || Column("language") == nil
                    )
                }
                // Hard upper bound on rows pulled into memory before mixing.
                return try request
                    .order(Column("updatedAt").desc)
                    .limit(query.currentText == nil ? 200 : 2000) // TYLER-SIMILAR-2026-10-22
                    .fetchAll(db)
            }
        } catch {
            return []
        }

        return WritingHistorySelection.select(from: candidates.map { $0.asSample }, query: query)
    }
}

/// Pure recency/longest/cross-app mixing + token-budget capping, factored out so it is unit-testable
/// without a database. Mirrors the "recent + long + same-context" guidance in `docs/02-prompting.md`
/// and the shape of the M3 `InMemoryWritingHistoryStore`.
enum WritingHistorySelection {
    static func select(from entries: [WritingHistorySample], query: WritingHistoryQuery) -> [String] {
        let candidates = entries.filter { $0.text.count >= query.minimumCharacters }

        let sameApp = candidates.filter { entry in
            guard let bundle = query.bundleIdentifier else { return true }
            return entry.appBundleIdentifier == bundle
        }
        let crossApp = candidates.filter { entry in
            guard let bundle = query.bundleIdentifier else { return false }
            return entry.appBundleIdentifier != bundle
        }

        var picked: [WritingHistorySample] = []
        var seen = Set<String>()

        func take(_ samples: [WritingHistorySample], upTo limit: Int) {
            for s in samples.prefix(limit) where seen.insert(s.text).inserted {
                picked.append(s)
            }
        }

        // TYLER-SIMILAR-2026-10-22: entries that share words with the text near the cursor go first,
        // so the earliest-selected (budget-protected) samples are the most relevant ones.
        if let current = query.currentText, query.similarCount > 0 {
            let words = similarityWords(current)
            if !words.isEmpty {
                // Skip the saved copy of the field being typed right now (it would echo itself).
                let probe = String(current.suffix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
                var scored: [(sample: WritingHistorySample, score: Double)] = []
                for entry in candidates {
                    if probe.count >= 12, entry.text.contains(probe) { continue }
                    if current.contains(entry.text) { continue }
                    let score = similarityScore(similarityWords(entry.text), against: words)
                    if score > 0 { scored.append((entry, score)) }
                }
                scored.sort { a, b in
                    a.score != b.score ? a.score > b.score : a.sample.updatedAt > b.sample.updatedAt
                }
                take(scored.map { $0.sample }, upTo: query.similarCount)
            }
        }
        take(sameApp.sorted { $0.updatedAt > $1.updatedAt }, upTo: query.mostRecentCount)
        take(sameApp.sorted { $0.text.count > $1.text.count }, upTo: query.longestCount)
        if !query.sameAppOnly {
            take(crossApp.sorted { $0.updatedAt > $1.updatedAt }, upTo: query.crossAppRecentCount)
        }

        // Cap by both fetch size and an approximate token budget (~4 chars/token), keeping the
        // earliest-selected (highest-priority) samples.
        var result: [String] = []
        var tokens = 0
        for sample in picked.prefix(query.fetchSize) {
            let cost = max(1, Int((Double(sample.text.count) / 4.0).rounded(.up)))
            if tokens + cost > query.tokenBudget, !result.isEmpty { break }
            result.append(sample.text)
            tokens += cost
        }
        return result
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "you", "are", "was", "but", "not", "have",
        "has", "had", "its", "it's", "they", "them", "then", "than", "there", "what", "when", "will",
        "would", "can", "could", "from", "your", "about", "just", "into", "also", "our", "his", "her"
    ]

    /// Lowercased content words of 3+ letters, minus common filler words.
    static func similarityWords(_ text: String) -> Set<String> {
        let parts = text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'") }
        return Set(parts.map(String.init).filter { $0.count >= 3 && !stopWords.contains($0) })
    }

    /// Shared-word count, lightly normalised so long entries don't win just by being long.
    static func similarityScore(_ entry: Set<String>, against current: Set<String>) -> Double {
        let shared = entry.intersection(current).count
        guard shared > 0 else { return 0 }
        return Double(shared) / (1.0 + log(Double(max(entry.count, 1))))
    }
}

enum WritingHistorySampleBridge {
    static func make(text: String, app: String?, domain: String?, typingContext: String?, language: String?,
                     createdAt: Date, updatedAt: Date, accepted: Bool, selectedText: String?, after: String?,
                     windowTitle: String?, screenText: String?, screenshot: Data?, origin: String?) -> WritingHistorySample {
        WritingHistorySample(text: text, appBundleIdentifier: app, domain: domain, typingContext: typingContext,
                             language: language, createdAt: createdAt, updatedAt: updatedAt,
                             hasAcceptedCompletion: accepted, selectedText: selectedText, textAfterCursor: after,
                             windowTitle: windowTitle, screenText: screenText, screenshotData: screenshot,
                             originDeviceID: origin)
    }
}
