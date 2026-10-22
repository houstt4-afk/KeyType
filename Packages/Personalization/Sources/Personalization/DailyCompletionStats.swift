import Foundation

/// TYLER-DAILYSTATS-2026-10-22: per-day accepted-suggestion counts (Cotypist `completionStats.json`
/// parity). Short = one word accepted; long = a whole suggestion accepted. Plain JSON, local only.
public final class DailyCompletionStats: @unchecked Sendable { // lock-guarded; url is immutable
    public struct Day: Codable, Equatable {
        public var shortAccepted = 0
        public var longAccepted = 0
        public var characters = 0
        public init() {}
    }

    private let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    /// One instance per file, so every reader and writer goes through the same lock.
    /// GEMINI-REVIEW-2026-10-22 (the Statistics pane used to build its own unlocked copy).
    public static let shared = DailyCompletionStats(url: defaultURL())

    /// Wipes the per-day counts ("Clear all personal data").
    public func clearAll() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("KeyType/completionStats.json")
    }

    public static func dayKey(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    public func load() -> [String: Day] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url),
              let days = try? JSONDecoder().decode([String: Day].self, from: data) else { return [:] }
        return days
    }

    public func recordAcceptance(characters: Int, isFull: Bool, on date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        var days: [String: Day] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONDecoder().decode([String: Day].self, from: data) { days = existing }
        let key = Self.dayKey(date)
        var day = days[key] ?? Day()
        if isFull { day.longAccepted += 1 } else { day.shortAccepted += 1 }
        day.characters += characters
        days[key] = day
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        if let out = try? encoder.encode(days) { try? out.write(to: url, options: .atomic) }
    }
}
