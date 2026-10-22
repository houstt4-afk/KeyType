import Foundation
import ImageIO
import UniformTypeIdentifiers

/// TYLER-SCREENSHOT-2026-10-22: keeps the most recent window screenshot (JPEG) from the OCR capturer
/// so the history recorder can save it with an entry (Cotypist `screenshotData` parity). Off unless
/// `isEnabled` is set from the opt-in Settings toggle; nothing is kept while it is off.
public final class ScreenshotStash: @unchecked Sendable {
    public static let shared = ScreenshotStash()
    private let lock = NSLock()
    private var enabled = false
    private var jpeg: Data?
    /// GEMINI-REVIEW-2026-10-22: which app the screenshot came from and when, so a history entry
    /// never picks up another app's (possibly sensitive) window.
    private var sourceBundleIdentifier: String?
    private var capturedAt: Date?
    public static let maxAge: TimeInterval = 15

    public var isEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return enabled }
        set { lock.lock(); enabled = newValue; if !newValue { jpeg = nil; sourceBundleIdentifier = nil; capturedAt = nil }; lock.unlock() }
    }

    public var latestJPEG: Data? { lock.lock(); defer { lock.unlock() }; return jpeg }

    /// The stored screenshot only if it was captured from `bundleIdentifier` within `maxAge`.
    public func latestJPEG(for bundleIdentifier: String, now: Date = Date()) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let jpeg, let capturedAt, sourceBundleIdentifier == bundleIdentifier,
              now.timeIntervalSince(capturedAt) <= Self.maxAge else { return nil }
        return jpeg
    }

    public func clear() {
        lock.lock(); jpeg = nil; sourceBundleIdentifier = nil; capturedAt = nil; lock.unlock()
    }

    func store(_ image: CGImage, bundleIdentifier: String?) {
        guard isEnabled else { return }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.5] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return }
        lock.lock(); jpeg = data as Data; sourceBundleIdentifier = bundleIdentifier; capturedAt = Date(); lock.unlock()
    }
}
