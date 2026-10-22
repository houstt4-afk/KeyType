import AutocompleteCore
import Foundation
import ModelRuntime

public enum PromptTemplateMode: Equatable {
    case baseContinuation
    case chatML
}

public enum PromptTruncationMode: Equatable {
    case none
    case preserveStart
    case preserveEnd
    case hard
}

public struct PromptSection: Equatable {
    public var name: String
    public var heading: String?
    public var content: String
    public var priority: Int
    public var minBudget: Int
    public var maxBudget: Int
    public var truncationMode: PromptTruncationMode

    public init(
        name: String,
        heading: String? = nil,
        content: String,
        priority: Int,
        minBudget: Int = 0,
        maxBudget: Int,
        truncationMode: PromptTruncationMode = .hard
    ) {
        self.name = name
        self.heading = heading
        self.content = content
        self.priority = priority
        self.minBudget = minBudget
        self.maxBudget = maxBudget
        self.truncationMode = truncationMode
    }
}

public protocol PromptTokenCounting {
    func tokenCount(for text: String) -> Int
}

/// Fallback counter when no real tokenizer is wired (kept so existing callers / tests
/// stay green without depending on llama). Approximates GPT-style BPE at ~4 chars/token.
public struct ApproximatePromptTokenCounter: PromptTokenCounting {
    public init() {}

    public func tokenCount(for text: String) -> Int {
        if text.isEmpty { return 0 }
        return max(1, Int(ceil(Double(text.count) / 4.0)))
    }
}

/// Real tokenizer-backed counter. Wraps any `ModelTokenizing` (e.g. `LlamaTokenizer`)
/// and falls back to an approximate counter if the tokenizer throws. Used by the
/// `PromptBuilder` so truncation and budget enforcement match what the model will
/// actually see — which is the M3 acceptance criterion.
public struct TokenizerPromptTokenCounter: PromptTokenCounting {
    private let tokenizer: ModelTokenizing
    private let fallback: PromptTokenCounting

    public init(
        tokenizer: ModelTokenizing,
        fallback: PromptTokenCounting = ApproximatePromptTokenCounter()
    ) {
        self.tokenizer = tokenizer
        self.fallback = fallback
    }

    public func tokenCount(for text: String) -> Int {
        if text.isEmpty { return 0 }
        do {
            return try tokenizer.tokenize(text).count
        } catch {
            return fallback.tokenCount(for: text)
        }
    }
}

public struct PromptBuildResult: Equatable {
    public var prompt: String
    public var sections: [PromptSection]
    public var estimatedTokenCount: Int

    public init(prompt: String, sections: [PromptSection], estimatedTokenCount: Int) {
        self.prompt = prompt
        self.sections = sections
        self.estimatedTokenCount = estimatedTokenCount
    }
}

public struct PromptBuilder {
    private let tokenCounter: PromptTokenCounting
    private let maxPromptTokens: Int

    /// Default `maxPromptTokens` is sized for the **steady-state** cost rather than the
    /// cold-prefill cost: with KV prefix reuse, every keystroke after the first only
    /// re-decodes the changed suffix, so the per-keystroke prefill is proportional to
    /// the edit, not the full prompt. The first prompt after focus change still pays
    /// the cold cost — at 4096 tokens that's well above the 200 ms cold budget on the
    /// M2 reference runtime — but that cost is paid once per context, not per
    /// keystroke. See `PrefillLatencyBenchmarkTests` and ADR-008 for the measured
    /// cold + warm curves and the trade-off rationale.
    public static let defaultMaxPromptTokens: Int = 4096

    public init(
        tokenCounter: PromptTokenCounting = ApproximatePromptTokenCounter(),
        maxPromptTokens: Int = PromptBuilder.defaultMaxPromptTokens
    ) {
        self.tokenCounter = tokenCounter
        self.maxPromptTokens = maxPromptTokens
    }

    public func buildPrompt(
        context: TextFieldContext,
        customInstructions: [String] = [],
        previousUserInputs: [String] = [],
        pasteboardText: String? = nil,
        screenText: String? = nil,
        mode: PromptTemplateMode = .baseContinuation,
        includeEnvironmentContext: Bool = true
    ) -> PromptBuildResult {
        let sections = makeSections(
            context: context,
            customInstructions: customInstructions,
            previousUserInputs: previousUserInputs,
            pasteboardText: pasteboardText,
            screenText: screenText,
            includeEnvironmentContext: includeEnvironmentContext
        )
        let templateOverhead = tokenCount(for: templateOverheadString(mode: mode))
        let contentBudget = max(0, maxPromptTokens - templateOverhead)

        var allocated = allocate(sections: sections, contentBudget: contentBudget)
        var body = renderBody(allocated)
        body = fitOverall(body, allocated: &allocated, limit: contentBudget)

        let prompt = wrap(body: body, mode: mode)
        return PromptBuildResult(
            prompt: prompt,
            sections: allocated,
            estimatedTokenCount: tokenCount(for: prompt)
        )
    }

    // MARK: - Section construction

    private func makeSections(
        context: TextFieldContext,
        customInstructions: [String],
        previousUserInputs: [String],
        pasteboardText: String?,
        screenText: String?,
        includeEnvironmentContext: Bool
    ) -> [PromptSection] {
        var sections: [PromptSection] = [
            PromptSection(
                name: "completionInstructions",
                heading: "Completion instructions",
                content: "Continue the user's current text at the cursor. Produce only text that should be inserted.",
                priority: 100,
                minBudget: 16,
                maxBudget: 96
            )
        ]

        // App/window/field metadata. Omitted for code editors and terminals, where it biases the
        // model toward code/numbers rather than the user's prose (see ADR-017).
        if includeEnvironmentContext {
            sections.append(
                PromptSection(
                    name: "generalInfo",
                    heading: "General information",
                    // GEMINI-REVIEW-2026-10-22: omit empty metadata lines so a base model isn't primed
                    // to emit bare "Key: " lists.
                    content: Self.metadataLines([
                        ("Application", context.target.appName),
                        ("Bundle identifier", context.target.bundleIdentifier),
                        ("Window title", context.target.windowTitle),
                        ("Context", context.typingContext)
                    ]),
                    priority: 60,
                    maxBudget: 192
                )
            )
            sections.append(
                PromptSection(
                    name: "textFieldProperties",
                    heading: "Text field properties",
                    content: Self.metadataLines([
                        ("Placeholder", context.placeholder),
                        ("Labels", context.labels.joined(separator: ", ")),
                        ("Language", context.detectedLanguage)
                    ]),
                    priority: 65,
                    maxBudget: 192
                )
            )
        }

        // GEMINI-REVIEW-2026-10-22: an empty "[Text after cursor]" header right above the caret
        // invites small base models to echo headers; only include the section when it has text.
        if !context.afterCursor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(
                PromptSection(
                    name: "afterCursor",
                    heading: "Text after cursor",
                    content: context.afterCursor,
                    priority: 90,
                    maxBudget: 512,
                    truncationMode: .preserveStart
                )
            )
        }
        sections.append(contentsOf: [
            PromptSection(
                name: "beforeCursor",
                heading: "Text before cursor",
                // Trailing whitespace at the caret makes a base model wander (it must emit a word
                // with no leading space, which it does poorly) and produces double-space artifacts
                // on insertion. Feed the clean word boundary; the caller re-aligns the candidate's
                // leading space against the live text via `CaretBoundary.reconcile`. See ADR-017.
                content: Self.trimmingTrailingWhitespace(context.beforeCursor),
                priority: 100,
                minBudget: 64,
                maxBudget: 2048,
                truncationMode: .preserveEnd
            )
        ])

        if !customInstructions.isEmpty {
            sections.append(
                PromptSection(
                    name: "customInstructions",
                    heading: "Custom writing instructions",
                    content: customInstructions.joined(separator: "\n"),
                    priority: 80,
                    maxBudget: 384
                )
            )
        }

        if !previousUserInputs.isEmpty {
            sections.append(
                PromptSection(
                    name: "previousUserInputs",
                    heading: "Relevant previous writing",
                    // GEMINI-REVIEW-2026-10-22: inputs arrive highest-priority first; reverse them so the
                    // most relevant entry sits nearest the cursor and survives `.preserveEnd` truncation,
                    // and separate entries with a blank line so they don't run together.
                    content: previousUserInputs.reversed().joined(separator: "\n\n"),
                    priority: 50,
                    maxBudget: 512,
                    truncationMode: .preserveEnd
                )
            )
        }

        if let pasteboardText, !pasteboardText.isEmpty {
            sections.append(
                PromptSection(
                    name: "pasteboard",
                    heading: "Clipboard context",
                    content: pasteboardText,
                    priority: 40,
                    maxBudget: 384
                )
            )
        }

        if let screenText, !screenText.isEmpty {
            sections.append(
                PromptSection(
                    name: "screen",
                    heading: "Screen context",
                    content: screenText,
                    priority: 35,
                    maxBudget: 384
                )
            )
        }

        return sections
    }

    // MARK: - Allocation

    /// Allocates token budget across sections in priority order, charging both the
    /// section's content tokens and its rendered heading/separator overhead against the
    /// running remaining budget. Each section's content is then truncated by *measured*
    /// token count (binary search on Character boundaries) using its truncation mode.
    private func allocate(sections: [PromptSection], contentBudget: Int) -> [PromptSection] {
        let separatorTokens = tokenCount(for: "\n\n")
        let priorityOrdered = sections.sorted { lhs, rhs in
            lhs.priority == rhs.priority ? lhs.name < rhs.name : lhs.priority > rhs.priority
        }

        var remaining = contentBudget
        var allocated: [PromptSection] = []
        allocated.reserveCapacity(priorityOrdered.count)

        for (index, section) in priorityOrdered.enumerated() {
            let headingOverhead = renderingOverhead(for: section)
            let separatorOverhead = index == 0 ? 0 : separatorTokens
            let fixedOverhead = headingOverhead + separatorOverhead

            let preferred = tokenCount(for: section.content)
            let target = min(section.maxBudget, max(section.minBudget, preferred))
            let cap = max(0, remaining - fixedOverhead)
            let budget = min(target, cap)

            var copy = section
            copy.content = truncate(section.content, toTokens: budget, mode: section.truncationMode)
            let actualContentTokens = tokenCount(for: copy.content)
            remaining = max(0, remaining - actualContentTokens - fixedOverhead)
            allocated.append(copy)
        }

        return allocated.sorted { lhs, rhs in sectionOrder(lhs.name) < sectionOrder(rhs.name) }
    }

    /// Tokens consumed by the section's heading line (`[Heading]\n`), excluding the
    /// content itself and the `\n\n` separator between sections.
    private func renderingOverhead(for section: PromptSection) -> Int {
        if let heading = section.heading {
            return tokenCount(for: "[\(heading)]\n")
        }
        return 0
    }

    // MARK: - Truncation

    /// Trims `text` so its measured token count is `<= budget`, keeping the slice
    /// nearest the caret (tail for `preserveEnd`, head for `preserveStart`/`hard`).
    /// Uses binary search on Character boundaries so multi-byte content (emoji, CJK)
    /// is split safely. `none` is a passthrough.
    private func truncate(_ text: String, toTokens budget: Int, mode: PromptTruncationMode) -> String {
        if mode == .none { return text }
        if budget <= 0 { return "" }
        if text.isEmpty { return text }
        if tokenCount(for: text) <= budget { return text }

        switch mode {
        case .preserveEnd:
            return largestSuffix(of: text, withinTokens: budget)
        case .preserveStart, .hard:
            return largestPrefix(of: text, withinTokens: budget)
        case .none:
            return text
        }
    }

    private func largestPrefix(of text: String, withinTokens budget: Int) -> String {
        let count = text.count
        var lo = 0
        var hi = count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            let slice = String(text.prefix(mid))
            if tokenCount(for: slice) <= budget {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return String(text.prefix(lo))
    }

    private func largestSuffix(of text: String, withinTokens budget: Int) -> String {
        let count = text.count
        var lo = 0
        var hi = count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            let slice = String(text.suffix(mid))
            if tokenCount(for: slice) <= budget {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return String(text.suffix(lo))
    }

    // MARK: - Rendering and final-fit

    private func renderBody(_ sections: [PromptSection]) -> String {
        sections.map(render).joined(separator: "\n\n")
    }

    /// Defensive second pass: even though `allocate` charges heading + separator
    /// overhead, tokenizer non-linearities (a word split differently when it sits at
    /// the boundary of another section, BPE merges across whitespace, etc.) can push
    /// the rendered body a few tokens over budget. Shrink lowest-priority sections
    /// first; trim `beforeCursor` (preserve-end) last so the dominant signal survives.
    private func fitOverall(
        _ body: String,
        allocated: inout [PromptSection],
        limit: Int
    ) -> String {
        var current = body
        var count = tokenCount(for: current)
        if count <= limit { return current }

        let order = allocated.indices.sorted { a, b in
            let sa = allocated[a]
            let sb = allocated[b]
            if sa.name == "beforeCursor" && sb.name != "beforeCursor" { return false }
            if sb.name == "beforeCursor" && sa.name != "beforeCursor" { return true }
            return sa.priority < sb.priority
        }

        for i in order {
            if count <= limit { break }
            var section = allocated[i]
            let contentTokens = tokenCount(for: section.content)
            if contentTokens == 0 { continue }
            let overshoot = count - limit
            let target = max(0, contentTokens - overshoot)
            let trimmed = truncate(section.content, toTokens: target, mode: section.truncationMode)
            section.content = trimmed
            allocated[i] = section
            current = renderBody(allocated)
            count = tokenCount(for: current)
        }

        return current
    }

    private func render(_ section: PromptSection) -> String {
        if let heading = section.heading {
            return "[\(heading)]\n\(section.content)"
        }
        return section.content
    }

    // MARK: - Template wrappers

    /// The fixed-string overhead of the requested template mode (excluding the body
    /// itself). Used to reserve budget so the final prompt — including chatML markers
    /// — fits inside `maxPromptTokens`.
    private func templateOverheadString(mode: PromptTemplateMode) -> String {
        switch mode {
        case .baseContinuation:
            return ""
        case .chatML:
            return "<|system|>\nComplete the user's text at the cursor.\n<|user|>\n\n<|assistant|>\n"
        }
    }

    private func wrap(body: String, mode: PromptTemplateMode) -> String {
        switch mode {
        case .baseContinuation:
            return body
        case .chatML:
            return "<|system|>\nComplete the user's text at the cursor.\n<|user|>\n\(body)\n<|assistant|>\n"
        }
    }

    private func tokenCount(for text: String) -> Int {
        tokenCounter.tokenCount(for: text)
    }

    /// `Key: value` lines, skipping keys whose value is missing or blank.
    static func metadataLines(_ pairs: [(String, String?)]) -> String {
        pairs.compactMap { key, value in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return "\(key): \(value)"
        }.joined(separator: "\n")
    }

    /// Drops trailing whitespace (spaces, tabs, newlines) so the base-model prompt ends exactly at
    /// a word boundary. See the `beforeCursor` section and ADR-017.
    static func trimmingTrailingWhitespace(_ text: String) -> String {
        var view = Substring(text)
        while let last = view.last, last.isWhitespace {
            view = view.dropLast()
        }
        return String(view)
    }

    /// Section ordering in the final prompt. `beforeCursor` is last in base mode so the
    /// model's next token is the natural continuation of the user's text at the caret.
    private func sectionOrder(_ name: String) -> Int {
        [
            "completionInstructions",
            "customInstructions",
            "generalInfo",
            "textFieldProperties",
            "previousUserInputs",
            "pasteboard",
            "screen",
            "afterCursor",
            "beforeCursor"
        ].firstIndex(of: name) ?? Int.max
    }
}
