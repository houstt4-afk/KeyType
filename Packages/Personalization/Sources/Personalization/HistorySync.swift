import CryptoKit
import Foundation
import Security

/// TYLER-SYNC-2026-10-22: end-to-end encrypted history sync through the user's iCloud Drive folder
/// (Cotypist CloudKit-sync parity without needing a paid CloudKit container). Each new history entry
/// becomes one AES-GCM sealed file under `iCloud Drive/KeyType Sync/<device-id>/`. Other Macs import
/// files they haven't seen. The 256-bit sync key lives in an iCloud-Keychain-synchronized item, so
/// only Macs signed into the same Apple ID can read the files; iCloud only ever holds ciphertext.
public final class HistorySync {
    public static let keyService = "com.pattonium.KeyType.sync"
    public static let keyAccount = "sync-key"

    private let store: PersistentWritingHistoryStore
    private let defaults: UserDefaults
    private let root: URL
    private let deviceID: String

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
        let key = try key()
        let fm = FileManager.default
        let mine = root.appendingPathComponent(deviceID)
        try fm.createDirectory(at: mine, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970

        let since = Date(timeIntervalSince1970: defaults.double(forKey: "KeyType.sync.lastPush"))
        var pushed = 0
        var newest = since
        for s in store.samplesUpdated(after: since, limit: 500) where s.originDeviceID == nil {
            let env = Envelope(text: s.text, appBundleIdentifier: s.appBundleIdentifier, domain: s.domain,
                               typingContext: s.typingContext, language: s.language, createdAt: s.createdAt,
                               updatedAt: s.updatedAt, hasAcceptedCompletion: s.hasAcceptedCompletion,
                               selectedText: s.selectedText, textAfterCursor: s.textAfterCursor,
                               windowTitle: s.windowTitle, screenText: s.screenText,
                               screenshotData: s.screenshotData, originDeviceID: deviceID)
            let sealed = try AES.GCM.seal(try encoder.encode(env), using: key)
            guard let combined = sealed.combined else { continue }
            let name = "\(Int(s.updatedAt.timeIntervalSince1970 * 1000))-\(abs(s.text.hashValue)).ksync"
            try combined.write(to: mine.appendingPathComponent(name), options: .atomic)
            pushed += 1
            newest = max(newest, s.updatedAt)
        }
        defaults.set(newest.timeIntervalSince1970, forKey: "KeyType.sync.lastPush")

        var seen = Set(defaults.stringArray(forKey: "KeyType.sync.imported") ?? [])
        var pulled = 0
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where dir.lastPathComponent != deviceID {
            for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension == "ksync" {
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
        defaults.set(Array(seen), forKey: "KeyType.sync.imported")
        return (pushed, pulled)
    }
}
