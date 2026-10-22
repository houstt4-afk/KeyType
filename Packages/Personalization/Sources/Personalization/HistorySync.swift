import CryptoKit
import Foundation
import Security

/// TYLER-SYNC-2026-10-22: end-to-end encrypted history sync through the user's iCloud Drive folder
/// (Cotypist CloudKit-sync parity without needing a paid CloudKit container). Each new history entry
/// becomes one AES-GCM sealed file under `iCloud Drive/KeyType Sync/<device-id>/`. Other Macs import
/// files they haven't seen. The 256-bit sync key lives in an iCloud-Keychain-synchronized item, so
/// only Macs signed into the same Apple ID can read the files; iCloud only ever holds ciphertext.
/// GEMINI-REVIEW-2026-10-22: every stored property is immutable and runs are serialized by `runLock`,
/// so it is safe to hand to the background sync queue.
public final class HistorySync: @unchecked Sendable {
    public static let keyService = "com.pattonium.KeyType.sync"
    public static let keyAccount = "sync-key"

    private let store: PersistentWritingHistoryStore
    private let defaults: UserDefaults
    private let root: URL
    private let deviceID: String
    /// GEMINI-REVIEW-2026-10-22: one sync at a time; an overlapping call is skipped, not queued.
    private let runLock = NSLock()
    private static let lastPushKey = "KeyType.sync.lastPush"
    private static let importedKey = "KeyType.sync.imported"

    public init(store: PersistentWritingHistoryStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        self.root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/KeyType Sync")
        if let id = defaults.string(forKey: "KeyType.sync.deviceID") {
            deviceID = id
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: "KeyType.sync.deviceID")
        }
    }

    public var isAvailable: Bool {
        FileManager.default.fileExists(atPath: root.deletingLastPathComponent().path)
    }

    private func key() throws -> SymmetricKey {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keyService,
            kSecAttrAccount as String: Self.keyAccount,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any
        ]
        var q = base; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let d = item as? Data {
            return SymmetricKey(data: d)
        }
        let fresh = SymmetricKey(size: .bits256)
        var add = base
        add[kSecValueData as String] = fresh.withUnsafeBytes { Data($0) }
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return fresh
    }

    private struct Envelope: Codable {
        var text: String
        var appBundleIdentifier: String?
        var domain: String?
        var typingContext: String?
        var language: String?
        var createdAt: Date
        var updatedAt: Date
        var hasAcceptedCompletion: Bool
        var selectedText: String?
        var textAfterCursor: String?
        var windowTitle: String?
        var screenText: String?
        var screenshotData: Data?
        var originDeviceID: String?
    }

    /// Pushes entries newer than the last push, then pulls files from other devices. Returns counts.
    @discardableResult
    public func syncOnce() throws -> (pushed: Int, pulled: Int) {
        guard isAvailable else { return (0, 0) }
        guard runLock.try() else { return (0, 0) }
        defer { runLock.unlock() }
        let key = try key()
        let fm = FileManager.default
        let mine = root.appendingPathComponent(deviceID)
        try fm.createDirectory(at: mine, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970

        let since = Date(timeIntervalSince1970: defaults.double(forKey: Self.lastPushKey))
        var pushed = 0
        var newest = since
        // GEMINI-REVIEW-2026-10-22: local rows only, filtered in SQL (pulled rows used to fill the
        // 500-row page and block every later local push). Only the text and its light metadata are
        // synced — selection, after-cursor text, window title, screen text and screenshots stay on
        // this Mac (none of them are used for prompting).
        for s in store.localSamplesUpdated(after: since, limit: 500) {
            let env = Envelope(text: s.text, appBundleIdentifier: s.appBundleIdentifier, domain: s.domain,
                               typingContext: s.typingContext, language: s.language, createdAt: s.createdAt,
                               updatedAt: s.updatedAt, hasAcceptedCompletion: s.hasAcceptedCompletion,
                               selectedText: nil, textAfterCursor: nil, windowTitle: nil, screenText: nil,
                               screenshotData: nil, originDeviceID: deviceID)
            let sealed = try AES.GCM.seal(try encoder.encode(env), using: key)
            guard let combined = sealed.combined else { continue }
            // Deterministic name: `String.hashValue` is re-seeded every launch (new duplicate file per
            // relaunch) and `abs(Int.min)` traps.
            let ms = Int64((s.updatedAt.timeIntervalSince1970 * 1000.0).rounded())
            let name = "\(ms)-\(Self.digest(s.text)).ksync"
            try combined.write(to: mine.appendingPathComponent(name), options: .atomic)
            pushed += 1
            newest = max(newest, s.updatedAt)
        }
        if pushed > 0 {
            // +1 ms so date rounding in the store can't make `newest` re-export on the next run.
            defaults.set(newest.timeIntervalSince1970 + 0.001, forKey: Self.lastPushKey)
        }

        var seen = Set(defaults.stringArray(forKey: Self.importedKey) ?? [])
        var pulled = 0
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where dir.lastPathComponent != deviceID {
            for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                // GEMINI-REVIEW-2026-10-22: iCloud evicts files to `.name.ksync.icloud` placeholders;
                // ask for the download and import the real file on a later run.
                if let realName = Self.placeholderTarget(file.lastPathComponent) {
                    if !seen.contains(dir.lastPathComponent + "/" + realName) {
                        try? fm.startDownloadingUbiquitousItem(at: file)
                    }
                    continue
                }
                guard file.pathExtension == "ksync" else { continue }
                let id = dir.lastPathComponent + "/" + file.lastPathComponent
                if seen.contains(id) { continue }
                guard let data = try? Data(contentsOf: file),
                      let box = try? AES.GCM.SealedBox(combined: data),
                      let plain = try? AES.GCM.open(box, using: key),
                      let e = try? decoder.decode(Envelope.self, from: plain) else { continue }
                store.record(WritingHistorySampleBridge.make(
                    text: e.text, app: e.appBundleIdentifier, domain: e.domain, typingContext: e.typingContext,
                    language: e.language, createdAt: e.createdAt, updatedAt: e.updatedAt,
                    accepted: e.hasAcceptedCompletion, selectedText: e.selectedText, after: e.textAfterCursor,
                    windowTitle: e.windowTitle, screenText: e.screenText, screenshot: e.screenshotData,
                    origin: e.originDeviceID ?? dir.lastPathComponent))
                seen.insert(id); pulled += 1
            }
        }
        defaults.set(Array(seen), forKey: Self.importedKey)
        return (pushed, pulled)
    }

    /// Called after "Clear all personal data": removes this Mac's uploaded files and marks every
    /// other Mac's existing files as already imported, so the next sync neither re-uploads nor
    /// re-imports the wiped history. The shared sync key is kept — deleting it from iCloud Keychain
    /// would break sync on the user's other Macs. GEMINI-REVIEW-2026-10-22.
    public func resetAfterLocalClear() {
        runLock.lock()
        defer { runLock.unlock() }
        let fm = FileManager.default
        try? fm.removeItem(at: root.appendingPathComponent(deviceID))
        defaults.set(Date().timeIntervalSince1970, forKey: Self.lastPushKey)
        var seen = Set(defaults.stringArray(forKey: Self.importedKey) ?? [])
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where dir.lastPathComponent != deviceID {
            for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                let name = Self.placeholderTarget(file.lastPathComponent) ?? file.lastPathComponent
                guard name.hasSuffix(".ksync") else { continue }
                seen.insert(dir.lastPathComponent + "/" + name)
            }
        }
        defaults.set(Array(seen), forKey: Self.importedKey)
    }

    /// First 8 bytes of SHA-256, hex — stable across launches and machines.
    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// `".123-abc.ksync.icloud"` → `"123-abc.ksync"`; nil for anything that isn't an evicted sync file.
    static func placeholderTarget(_ name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".ksync.icloud") else { return nil }
        return String(name.dropFirst().dropLast(".icloud".count))
    }
}
