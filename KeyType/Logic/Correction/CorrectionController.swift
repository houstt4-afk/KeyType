import AppCompatibility
import AppKit
import AutocompleteCore
import CompletionUI
import Foundation
import MacContextCapture
import Personalization
import TextInsertion
import os

@MainActor
final class CorrectionController {
    private let tracker: AccessibilityContextTracker
    private let settings: SettingsStore
    private let telemetry: CompletionTelemetryStore
    private let compatibilityStore: AppCompatibilityStore
    private let presenter: InlineGhostTextPresenter
    private let placementResolver: OverlayPlacementResolver
    private let rangeGeometryResolver: TextRangeGeometryResolver
    private let inserter: PasteboardCompletionInserter
    private let predictionLog = PredictionLog()
    private let log = Logger(subsystem: "com.pattonium.KeyType", category: "correction")

    private var listenerToken: UUID?
    private let detectionTasks = CompletionTaskRegistry()
    private var detectionTask: CompletionTaskRegistry.Handle?
    private var isShuttingDown = false
    private var lastContextKey: String?
    private var dismissedWordKey: String?
    private(set) var visibleCorrection: CorrectionCandidate?
    private var visibleContext: TextFieldContext?
    private var visibleWordRect: CGRect?

    var validateWithModel: (([CorrectionCandidate], CorrectionTarget, TextFieldContext) async throws -> [CorrectionCandidate])?
    var onWillShowCorrection: ((TextFieldContext) -> Void)?
    var onCorrectionAccepted: (() -> Void)?

    init(
        tracker: AccessibilityContextTracker,
        settings: SettingsStore,
        telemetry: CompletionTelemetryStore,
        compatibilityStore: AppCompatibilityStore,
        presenter: InlineGhostTextPresenter = InlineGhostTextPresenter(),
        placementResolver: OverlayPlacementResolver? = nil,
        rangeGeometryResolver: TextRangeGeometryResolver? = nil,
        inserter: PasteboardCompletionInserter? = nil
    ) {
        self.tracker = tracker
        self.settings = settings
        self.telemetry = telemetry
        self.compatibilityStore = compatibilityStore
        self.presenter = presenter
        self.placementResolver = placementResolver ?? OverlayPlacementResolver(compatibilityStore: compatibilityStore)
        self.rangeGeometryResolver = rangeGeometryResolver ?? TextRangeGeometryResolver()
        self.inserter = inserter ?? PasteboardCompletionInserter(
            planner: InsertionPlanner(compatibilityStore: compatibilityStore)
        )
    }

    var hasVisibleCorrection: Bool {
        visibleCorrection != nil
    }

    func start() {
        guard !isShuttingDown, listenerToken == nil else { return }
        listenerToken = tracker.addListener { [weak self] snapshot in
            self?.handle(snapshot)
        }
    }

    func stop() {
        if let listenerToken {
            tracker.removeListener(listenerToken)
        }
        listenerToken = nil
        detectionTask?.cancel()
        detectionTask = nil
        clear()
    }

    /// Stop accepting snapshots and join every superseded detection task. A detection may be inside
    /// model validation even after cancellation, so completion's llama runtime must not be freed
    /// until this drain returns.
    func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        stop()
        await detectionTasks.closeAndWait()
    }

    func shouldSuppressCompletion(for context: TextFieldContext) -> Bool {
        guard let visibleCorrection, let visibleContext else { return false }
        return visibleContext.target == context.target
            && visibleCorrection.originalRange.container == .beforeCursor
            && context.beforeCursor.hasPrefix(visibleContext.beforeCursor)
    }

    func canAcceptCorrection() -> Bool {
        visibleCorrection != nil && visibleContext != nil
    }

    func acceptCorrection() {
        guard let correction = visibleCorrection,
              let context = visibleContext,
              let plan = inserter.planCorrection(candidate: correction, context: context) else {
            telemetry.recordCorrectionReplacementFailure()
            clear()
            return
        }

        telemetry.recordCorrectionAccepted()
        predictionLog.append(
            "CORRECT_ACCEPT \"\(PredictionLog.escape(correction.original))\" -> \"\(PredictionLog.escape(correction.replacement))\""
        )
        lastContextKey = nil
        onCorrectionAccepted?()
        clear()
        Task { [weak self] in
            do {
                try await self?.inserter.insert(plan: plan)
                try? await Task.sleep(nanoseconds: 80_000_000)
                await MainActor.run {
                    self?.tracker.requestRefresh()
                }
            } catch {
                await MainActor.run {
                    self?.telemetry.recordCorrectionReplacementFailure()
                    self?.log.error("Correction replacement failed: \(error, privacy: .public)")
                }
            }
        }
    }

    static let minimumConfidence = 0.72
    static let detectionDebounceNanoseconds: UInt64 = 120_000_000

    /// GEMINI-REVIEW-2026-10-22: called from the key-down tap. A keystroke makes any in-flight
    /// detection stale, so cancel it before it can show (or auto-apply) against old text.
    func noteUserKeyDown() {
        detectionTask?.cancel()
        detectionTask = nil
        lastContextKey = nil
    }

    func dismissCorrection() {
        guard let correction = visibleCorrection, let context = visibleContext else { return }
        dismissedWordKey = Self.wordKey(correction: correction, context: context)
        telemetry.recordCorrectionDismissed()
        clear()
    }

    private func handle(_ snapshot: FocusedFieldSnapshot?) {
        guard !isShuttingDown else { return }
        guard let snapshot else {
            clear()
            return
        }
        let context = snapshot.context
        let policy = compatibilityStore.policy(for: context)
        guard settings.autocorrectSuggestionsEnabled,
              settings.showSuggestedFixes,
              !settings.perAppCorrectionDisabled.contains(context.target.bundleIdentifier),
              !policy.autocorrectDisabled,
              !Self.isKeyTypeTarget(context.target),
              placementResolver.placement(for: context) != nil else {
            clear()
            return
        }

        let key = Self.contextKey(for: context)
        if key == lastContextKey { return }
        lastContextKey = key

        detectionTask?.cancel()
        detectionTask = detectionTasks.start { [weak self] in
            guard let self else { return }
            let started = DispatchTime.now()
            do {
                // GEMINI-REVIEW-2026-10-22: debounce — wait out fast typing; a keystroke cancels this
                // task (noteUserKeyDown / next snapshot) before any spellcheck work starts.
                try await Task.sleep(nanoseconds: Self.detectionDebounceNanoseconds)
                let detector = SystemSpellcheckCorrectionDetector()
                let grammarDetector = SystemGrammarCorrectionDetector()
                let detection = try await detector.detectCorrection(for: context)
                let rawCandidates: [CorrectionCandidate]
                let fallbackTarget: CorrectionTarget?
                if let detection {
                    let spellcheckCandidates = detection.candidates
                    let grammarAfterSpelling = spellcheckCandidates.flatMap {
                        grammarDetector.candidates(afterApplying: $0, in: context)
                    }
                    rawCandidates = grammarAfterSpelling + spellcheckCandidates
                    fallbackTarget = detection.target
                } else {
                    rawCandidates = grammarDetector.correctionCandidates(for: context)
                    fallbackTarget = nil
                }
                guard !rawCandidates.isEmpty else {
                    try Task.checkCancellation()
                    telemetry.recordCorrectionSuppressed(reason: "noCandidate")
                    clear()
                    return
                }
                telemetry.recordCorrectionDetected()
                let candidates: [CorrectionCandidate]
                if let validateWithModel {
                    candidates = try await validateCandidatesByRange(
                        rawCandidates,
                        fallbackTarget: fallbackTarget,
                        context: context,
                        validator: validateWithModel
                    )
                } else {
                    candidates = rawCandidates.filter { $0.source == .spellcheckOnly }
                }
                try Task.checkCancellation()
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                telemetry.recordCorrectionValidationLatency(milliseconds: elapsed)
                present(candidates: candidates, target: fallbackTarget ?? Self.target(for: rawCandidates[0], context: context), context: context)
            } catch is CancellationError {
            } catch {
                log.error("Correction detection failed: \(error, privacy: .public)")
            }
        }
    }

    private func validateCandidatesByRange(
        _ candidates: [CorrectionCandidate],
        fallbackTarget: CorrectionTarget?,
        context: TextFieldContext,
        validator: ([CorrectionCandidate], CorrectionTarget, TextFieldContext) async throws -> [CorrectionCandidate]
    ) async throws -> [CorrectionCandidate] {
        let groups = Dictionary(grouping: candidates) { candidate in
            [
                candidate.originalRange.container.rawValue,
                String(candidate.originalRange.startOffset),
                String(candidate.originalRange.endOffset)
            ].joined(separator: ":")
        }
        var validated: [CorrectionCandidate] = []
        for group in groups.values {
            try Task.checkCancellation()
            guard let first = group.first else { continue }
            let target = fallbackTarget.flatMap { $0.range == first.originalRange ? $0 : nil }
                ?? Self.target(for: first, context: context)
            validated.append(contentsOf: try await validator(group, target, context))
        }
        return validated.sorted {
            if Self.correctionPriority($0) != Self.correctionPriority($1) {
                return Self.correctionPriority($0) > Self.correctionPriority($1)
            }
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            return $0.replacement < $1.replacement
        }
    }

    private func present(candidates: [CorrectionCandidate], target: CorrectionTarget, context: TextFieldContext) {
        guard let best = candidates.first else {
            telemetry.recordCorrectionSuppressed(reason: "lowModelMargin")
            predictionLog.append("CORRECT word=\"\(PredictionLog.escape(target.original))\" -> SUPPRESS(lowModelMargin)")
            clear()
            return
        }
        // TYLER-MAX-2026-10-22 lowered 0.76 → 0.5; GEMINI-REVIEW-2026-10-22: spellcheck clamps its
        // confidence at ≥ 0.55, so 0.5 let every guess through. 0.72 restores a real floor.
        guard best.confidence >= Self.minimumConfidence else {
            telemetry.recordCorrectionSuppressed(reason: "lowSpellcheckConfidence")
            predictionLog.append("CORRECT word=\"\(PredictionLog.escape(best.original))\" -> SUPPRESS(lowSpellcheckConfidence)")
            clear()
            return
        }
        guard dismissedWordKey != Self.wordKey(correction: best, context: context) else {
            telemetry.recordCorrectionSuppressed(reason: "dismissedForWord")
            clear()
            return
        }
        let wordRect = rangeGeometryResolver.resolve(range: best.originalRange, context: context)?.rect
        if wordRect == nil, !Self.isNearCaret(best.originalRange, context: context) {
            telemetry.recordCorrectionSuppressed(reason: "noWordRect")
            clear()
            return
        }
        guard let placement = placementResolver.placement(for: context) else {
            telemetry.recordCorrectionSuppressed(reason: "noPlacement")
            clear()
            return
        }

        onWillShowCorrection?(context)
        visibleCorrection = best
        visibleContext = context
        visibleWordRect = wordRect
        telemetry.recordCorrectionShown()
        predictionLog.append(
            "CORRECT word=\"\(PredictionLog.escape(best.original))\" guess=\"\(PredictionLog.escape(best.replacement))\" -> SHOWN confidence=\(String(format: "%.2f", best.confidence)) source=\(best.source.rawValue)"
        )
        presenter.show(
            correction: best,
            placement: placement,
            style: FieldFontResolver.currentStyle().overlayTextStyle,
            wordRect: wordRect
        )
        // TYLER-AUTOFIX-2026-10-22: fix finished words on their own, like Apple autocorrect —
        // once a space or punctuation follows the misspelled word, apply the fix without Tab.
        // GEMINI-REVIEW-2026-10-22: only if no keystroke arrived since this detection started
        // (noteUserKeyDown clears lastContextKey), so the backspaces never hit newer text.
        if Self.wordIsFinished(best, context: context),
           lastContextKey == Self.contextKey(for: context) {
            acceptCorrection()
        }
    }

    /// GEMINI-REVIEW-2026-10-22: "finished" means the word was JUST closed — one space or one
    /// punctuation mark (optionally punctuation + space) right after it, never a newline. The old test
    /// (any whitespace/punctuation tail) also fired on words the user had moved away from.
    static func wordIsFinished(_ candidate: CorrectionCandidate, context: TextFieldContext) -> Bool {
        guard candidate.originalRange.container == .beforeCursor,
              let range = candidate.originalRange.range(in: context.beforeCursor) else { return false }
        let tail = Array(context.beforeCursor[range.upperBound...])
        switch tail.count {
        case 1:
            return tail[0] == " " || tail[0].isPunctuation
        case 2:
            return tail[0].isPunctuation && tail[1] == " "
        default:
            return false
        }
    }

    private func clear() {
        presenter.hide()
        visibleCorrection = nil
        visibleContext = nil
        visibleWordRect = nil
    }

    private static func contextKey(for context: TextFieldContext) -> String {
        [
            context.target.bundleIdentifier,
            context.target.domain ?? "",
            context.beforeCursor,
            context.afterCursor
        ].joined(separator: "\u{1E}")
    }

    /// GEMINI-REVIEW-2026-10-22: identifies the word by the text just before it plus the word, not
    /// by the whole `beforeCursor` — typing a space after Esc used to change the key, so a dismissed
    /// word was auto-replaced anyway.
    static func wordKey(correction: CorrectionCandidate, context: TextFieldContext) -> String {
        var lead = ""
        if correction.originalRange.container == .beforeCursor,
           let range = correction.originalRange.range(in: context.beforeCursor) {
            lead = String(context.beforeCursor[..<range.lowerBound].suffix(40))
        }
        return [
            context.target.bundleIdentifier,
            correction.originalRange.container.rawValue,
            lead,
            correction.original,
            correction.replacement
        ].joined(separator: "\u{1E}")
    }

    private static func isKeyTypeTarget(_ target: AppTarget) -> Bool {
        target.bundleIdentifier == "com.pattonium.KeyType"
    }

    private static func target(for candidate: CorrectionCandidate, context: TextFieldContext) -> CorrectionTarget {
        switch candidate.originalRange.container {
        case .beforeCursor:
            let range = candidate.originalRange.range(in: context.beforeCursor)
            let prefix = range.map { String(context.beforeCursor[..<$0.lowerBound]) } ?? context.beforeCursor
            let suffix = range.map { String(context.beforeCursor[$0.upperBound...]) + context.afterCursor } ?? context.afterCursor
            return CorrectionTarget(
                original: candidate.original,
                range: candidate.originalRange,
                prefixBeforeWord: prefix,
                suffixAfterWord: suffix
            )
        case .afterCursor:
            let range = candidate.originalRange.range(in: context.afterCursor)
            let prefix = context.beforeCursor + (range.map { String(context.afterCursor[..<$0.lowerBound]) } ?? "")
            let suffix = range.map { String(context.afterCursor[$0.upperBound...]) } ?? context.afterCursor
            return CorrectionTarget(
                original: candidate.original,
                range: candidate.originalRange,
                prefixBeforeWord: prefix,
                suffixAfterWord: suffix
            )
        }
    }

    private static func correctionPriority(_ candidate: CorrectionCandidate) -> Int {
        switch candidate.source {
        case .spellcheckThenSystemGrammar: return 3
        case .spellcheckValidatedByModel, .priorPrediction: return 2
        case .systemGrammarValidatedByModel: return 1
        case .spellcheckOnly, .systemGrammarOnly: return 0
        }
    }

    private static func isNearCaret(_ range: TextRangeDescriptor, context: TextFieldContext) -> Bool {
        guard range.container == .beforeCursor else { return false }
        return max(0, context.beforeCursor.count - range.endOffset) <= 3
    }
}
