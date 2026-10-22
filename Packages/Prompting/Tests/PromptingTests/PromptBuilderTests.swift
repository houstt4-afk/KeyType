import AutocompleteCore
import ModelRuntime
import Prompting
import XCTest

/// All tests in this file use `UTF8FallbackTokenizer` (1 ASCII byte = 1 token) so the
/// token math is deterministic and the golden prompt is checkable byte-for-byte.
/// Production wiring uses `LlamaTokenizer`; the contract under test (truncate by
/// measured tokens, fit within `maxPromptTokens`, stable section order) is the same.
private func makeCounter() -> PromptTokenCounting {
    TokenizerPromptTokenCounter(tokenizer: UTF8FallbackTokenizer())
}

private func makeContext(
    beforeCursor: String = "Hi Maya,\nThanks for sending this over.",
    afterCursor: String = " Let me know if you want anything.",
    appName: String = "Mail",
    bundleIdentifier: String = "com.apple.mail",
    windowTitle: String? = "Inbox",
    typingContext: String? = "email",
    detectedLanguage: String? = "en"
) -> TextFieldContext {
    TextFieldContext(
        beforeCursor: beforeCursor,
        afterCursor: afterCursor,
        target: AppTarget(
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            windowTitle: windowTitle
        ),
        detectedLanguage: detectedLanguage,
        typingContext: typingContext
    )
}

final class PromptBuilderSmokeTests: XCTestCase {
    func testTokenizerPromptTokenCounterMatchesTokenizer() throws {
        let counter = makeCounter()
        XCTAssertEqual(counter.tokenCount(for: ""), 0)
        XCTAssertEqual(counter.tokenCount(for: "hi"), 2)
        XCTAssertEqual(counter.tokenCount(for: "hello world"), 11)
    }

    func testApproximateCounterIsCharsOverFour() {
        let counter = ApproximatePromptTokenCounter()
        XCTAssertEqual(counter.tokenCount(for: ""), 0)
        XCTAssertEqual(counter.tokenCount(for: "abcd"), 1)
        XCTAssertEqual(counter.tokenCount(for: "abcde"), 2)
        XCTAssertEqual(counter.tokenCount(for: String(repeating: "x", count: 17)), 5)
    }
}

final class PromptBuilderGoldenTests: XCTestCase {
    /// Fixed context → exact expected base-mode prompt string. Verifies section
    /// ordering, heading format, separator (`\n\n`) and that `beforeCursor` ends the
    /// prompt so the model continues from the caret.
    func testGoldenBaseContinuationPromptForFixedContext() {
        let builder = PromptBuilder(tokenCounter: makeCounter(), maxPromptTokens: 1024)
        let result = builder.buildPrompt(context: makeContext())

        let expected = """
        [Completion instructions]
        Continue the user's current text at the cursor. Produce only text that should be inserted.

        [General information]
        Application: Mail
        Bundle identifier: com.apple.mail
        Window title: Inbox
        Context: email

        [Text field properties]
        Language: en

        [Text after cursor]
         Let me know if you want anything.

        [Text before cursor]
        Hi Maya,
        Thanks for sending this over.
        """

        XCTAssertEqual(result.prompt, expected)
        XCTAssertTrue(
            result.prompt.hasSuffix("Hi Maya,\nThanks for sending this over."),
            "base-mode prompt must end exactly at beforeCursor so the model continues at the caret"
        )
        XCTAssertEqual(result.estimatedTokenCount, result.prompt.utf8.count)
    }

    /// Same context plus every optional input — golden snapshot for the rich path.
    func testGoldenBaseContinuationPromptWithAllOptionalSections() {
        let builder = PromptBuilder(tokenCounter: makeCounter(), maxPromptTokens: 1024)
        let result = builder.buildPrompt(
            context: makeContext(),
            customInstructions: ["Match the user's casual tone."],
            previousUserInputs: ["Cheers,\nBJ"],
            pasteboardText: "agenda.pdf",
            screenText: "subject line: schedule"
        )

        let expected = """
        [Completion instructions]
        Continue the user's current text at the cursor. Produce only text that should be inserted.

        [Custom writing instructions]
        Match the user's casual tone.

        [General information]
        Application: Mail
        Bundle identifier: com.apple.mail
        Window title: Inbox
        Context: email

        [Text field properties]
        Language: en

        [Relevant previous writing]
        Cheers,
        BJ

        [Clipboard context]
        agenda.pdf

        [Screen context]
        subject line: schedule

        [Text after cursor]
         Let me know if you want anything.

        [Text before cursor]
        Hi Maya,
        Thanks for sending this over.
        """

        XCTAssertEqual(result.prompt, expected)
    }
}

final class PromptBuilderGeminiReviewTests: XCTestCase {
    /// GEMINI-REVIEW-2026-10-22: no empty "[Text after cursor]" header at end-of-line.
    func testEmptyAfterCursorSectionIsOmitted() {
        let builder = PromptBuilder(tokenCounter: makeCounter(), maxPromptTokens: 1024)
        let result = builder.buildPrompt(context: makeContext(afterCursor: "  "))
        XCTAssertFalse(result.prompt.contains("[Text after cursor]"))
        XCTAssertNil(result.sections.first { $0.name == "afterCursor" })
    }

    /// GEMINI-REVIEW-2026-10-22: highest-priority history entry lands nearest the cursor.
    func testFirstHistoryEntryIsRenderedLast() {
        let builder = PromptBuilder(tokenCounter: makeCounter(), maxPromptTokens: 1024)
        let result = builder.buildPrompt(
            context: makeContext(),
            previousUserInputs: ["most similar", "least similar"]
        )
        let section = result.sections.first { $0.name == "previousUserInputs" }
        XCTAssertEqual(section?.content, "least similar\n\nmost similar")
    }
}

final class PromptBuilderBoundaryTests: XCTestCase {
    /// Trailing whitespace at the caret is trimmed so a base model continues from a clean word
    /// boundary (and so insertion doesn't double the separator space). See ADR-017.
    func testTrailingWhitespaceTrimmedFromBeforeCursor() {
        let builder = PromptBuilder(tokenCounter: makeCounter(), maxPromptTokens: 1024)
        let result = builder.buildPrompt(context: makeContext(
            beforeCursor: "The capital of France is ",
            afterCursor: ""
        ))
        XCTAssertTrue(
            result.prompt.hasSuffix("The capital of France is"),
            "prompt must end at the word boundary, not a dangling space; got: '\(String(result.prompt.suffix(30)))'"
        )
        XCTAssertFalse(result.prompt.hasSuffix("is "))

        let before = result.sections.first { $0.name == "beforeCursor" }
        XCTAssertEqual(before?.content, "The capital of France is")
    }

    func testTrailingNewlinesAndTabsTrimmed() {
        let builder = PromptBuilder(tokenCounter: makeCounter(), maxPromptTokens: 1024)
        let result = builder.buildPrompt(context: makeContext(beforeCursor: "Dear team,\n\n\t", afterCursor: ""))
        let before = result.sections.first { $0.name == "beforeCursor" }
        XCTAssertEqual(before?.content, "Dear team,")
    }

    /// Code editors / terminals pass `includeEnvironmentContext: false`, which drops the app/window
    /// and field-property metadata that biases a base model toward code and numbers. See ADR-017.
    func testEnvironmentContextOmittedWhenDisabled() {
        let builder = PromptBuilder(tokenCounter: makeCounter(), maxPromptTokens: 1024)
        let result = builder.buildPrompt(context: makeContext(), includeEnvironmentContext: false)

        let names = result.sections.map(\.name)
        XCTAssertFalse(names.contains("generalInfo"))
        XCTAssertFalse(names.contains("textFieldProperties"))
        XCTAssertFalse(result.prompt.contains("[General information]"))
        XCTAssertFalse(result.prompt.contains("[Text field properties]"))
        // Cursor-local sections and the instruction header remain.
        XCTAssertTrue(names.contains("beforeCursor"))
        XCTAssertTrue(result.prompt.contains("[Completion instructions]"))
        XCTAssertTrue(result.prompt.hasSuffix("Hi Maya,\nThanks for sending this over."))
    }

    func testEnvironmentContextIncludedByDefault() {
        let builder = PromptBuilder(tokenCounter: makeCounter(), maxPromptTokens: 1024)
        let result = builder.buildPrompt(context: makeContext())
        let names = result.sections.map(\.name)
        XCTAssertTrue(names.contains("generalInfo"))
        XCTAssertTrue(names.contains("textFieldProperties"))
    }
}

final class PromptBuilderTruncationTests: XCTestCase {
    /// Oversized `beforeCursor` must be tail-truncated (preserve-end) — the text
    /// nearest the caret stays, and the prompt still fits inside `maxPromptTokens`.
    /// HEAD/TAIL markers let us verify the dropped end without ambiguity.
    func testOversizedBeforeCursorIsTailTruncatedAndWithinBudget() {
        let big = "HEAD_FAR_FROM_CARET" + String(repeating: "a", count: 5000) + "TAIL_NEAR_CARET"
        let context = makeContext(
            beforeCursor: big,
            afterCursor: " stop"
        )
        let limit = 400
        let builder = PromptBuilder(tokenCounter: makeCounter(), maxPromptTokens: limit)
        let result = builder.buildPrompt(context: context)

        XCTAssertLessThanOrEqual(
            result.prompt.utf8.count, limit,
            "rendered prompt must fit inside maxPromptTokens under the real counter"
        )
        XCTAssertTrue(
            result.prompt.hasSuffix("TAIL_NEAR_CARET"),
            "preserve-end truncation keeps the text nearest the caret; got tail: '\(String(result.prompt.suffix(20)))'"
        )
        let beforeSection = result.sections.first { $0.name == "beforeCursor" }
        XCTAssertNotNil(beforeSection)
        XCTAssertTrue(beforeSection!.content.hasSuffix("TAIL_NEAR_CARET"))
        XCTAssertFalse(
            beforeSection!.content.contains("HEAD_FAR_FROM_CARET"),
            "beforeCursor head must have been dropped; preserve-end keeps the tail"
        )
    }

    /// Oversized `afterCursor` must be head-truncated (preserve-start) — the text
    /// nearest the caret on the right side stays.
    func testOversizedAfterCursorIsHeadTruncatedAndWithinBudget() {
        let big = "HEAD_NEAR_CARET" + String(repeating: "z", count: 5000) + "TAIL_FAR_FROM_CARET"
        let context = makeContext(
            beforeCursor: "short",
            afterCursor: big
        )
        let limit = 400
        let builder = PromptBuilder(tokenCounter: makeCounter(), maxPromptTokens: limit)
        let result = builder.buildPrompt(context: context)

        XCTAssertLessThanOrEqual(result.prompt.utf8.count, limit)
        let afterSection = result.sections.first { $0.name == "afterCursor" }
        XCTAssertNotNil(afterSection)
        XCTAssertTrue(
            afterSection!.content.hasPrefix("HEAD_NEAR_CARET"),
            "preserve-start truncation keeps the text nearest the caret on the right side"
        )
        XCTAssertFalse(
            afterSection!.content.contains("TAIL_FAR_FROM_CARET"),
            "afterCursor tail must have been dropped; preserve-start keeps the head"
        )
    }

    /// Tight budget: even with absurdly long sections everywhere, the rendered prompt
    /// must still measure within `maxPromptTokens` under the real counter (M3
    /// acceptance criterion).
    func testRenderedPromptStaysWithinBudgetUnderRealCounter() {
        let context = makeContext(
            beforeCursor: String(repeating: "x", count: 8000),
            afterCursor: String(repeating: "y", count: 8000)
        )
        let limit = 300
        let builder = PromptBuilder(tokenCounter: makeCounter(), maxPromptTokens: limit)
        let result = builder.buildPrompt(
            context: context,
            customInstructions: [String(repeating: "c", count: 1000)],
            previousUserInputs: [String(repeating: "h", count: 1000)],
            pasteboardText: String(repeating: "p", count: 1000),
            screenText: String(repeating: "s", count: 1000)
        )

        XCTAssertLessThanOrEqual(result.prompt.utf8.count, limit)
        XCTAssertEqual(result.estimatedTokenCount, result.prompt.utf8.count)
    }
}

final class PromptBuilderOrderingTests: XCTestCase {
    /// Section order is stable and `beforeCursor` is always last in base mode (the
    /// design rule from `docs/02-prompting.md`: generation begins immediately after
    /// the before-cursor bytes).
    func testSectionOrderIsStableAndBeforeCursorIsLastInBaseMode() {
        let builder = PromptBuilder(tokenCounter: makeCounter(), maxPromptTokens: 1024)
        let result = builder.buildPrompt(
            context: makeContext(),
            customInstructions: ["foo"],
            previousUserInputs: ["bar"],
            pasteboardText: "baz",
            screenText: "qux"
        )
        let names = result.sections.map { $0.name }
        XCTAssertEqual(names, [
            "completionInstructions",
            "customInstructions",
            "generalInfo",
            "textFieldProperties",
            "previousUserInputs",
            "pasteboard",
            "screen",
            "afterCursor",
            "beforeCursor"
        ])
        XCTAssertEqual(names.last, "beforeCursor")
        XCTAssertTrue(result.prompt.contains("[Text before cursor]"))
        let beforeRange = result.prompt.range(of: "[Text before cursor]")!
        let after = String(result.prompt[beforeRange.upperBound...])
        XCTAssertFalse(
            after.contains("["),
            "no further section headings may appear after [Text before cursor] in base mode"
        )
    }

    /// chatML wraps the body but the body's section order is unchanged and the
    /// assistant turn begins at the cursor (after `beforeCursor`).
    func testChatMLModeWrapsBodyAndKeepsBeforeCursorLastInsideBody() {
        let builder = PromptBuilder(tokenCounter: makeCounter(), maxPromptTokens: 1024)
        let result = builder.buildPrompt(context: makeContext(), mode: .chatML)
        XCTAssertTrue(result.prompt.hasPrefix("<|system|>"))
        XCTAssertTrue(result.prompt.hasSuffix("<|assistant|>\n"))
        let bodyStart = result.prompt.range(of: "<|user|>\n")!.upperBound
        let bodyEnd = result.prompt.range(of: "\n<|assistant|>\n")!.lowerBound
        let body = String(result.prompt[bodyStart..<bodyEnd])
        XCTAssertTrue(
            body.hasSuffix("Hi Maya,\nThanks for sending this over."),
            "even in chatML mode, the body must end at beforeCursor"
        )
    }
}

final class PromptBuilderOptionalSectionsTests: XCTestCase {
    /// Empty optional inputs (customInstructions, previousUserInputs, pasteboardText,
    /// screenText) are omitted cleanly — neither their headings nor stray blank lines
    /// appear in the prompt.
    func testEmptyOptionalSectionsAreOmitted() {
        let builder = PromptBuilder(tokenCounter: makeCounter(), maxPromptTokens: 1024)
        let result = builder.buildPrompt(context: makeContext())
        XCTAssertFalse(result.prompt.contains("[Custom writing instructions]"))
        XCTAssertFalse(result.prompt.contains("[Relevant previous writing]"))
        XCTAssertFalse(result.prompt.contains("[Clipboard context]"))
        XCTAssertFalse(result.prompt.contains("[Screen context]"))
        let names = result.sections.map { $0.name }
        XCTAssertFalse(names.contains("customInstructions"))
        XCTAssertFalse(names.contains("previousUserInputs"))
        XCTAssertFalse(names.contains("pasteboard"))
        XCTAssertFalse(names.contains("screen"))
    }

    /// Optional sections appear only when their input is non-empty. Empty strings
    /// (`""`) for pasteboard/screen still count as empty.
    func testOptionalSectionsAppearWhenInputsNonEmpty() {
        let builder = PromptBuilder(tokenCounter: makeCounter(), maxPromptTokens: 1024)
        let result = builder.buildPrompt(
            context: makeContext(),
            customInstructions: ["Be concise."],
            previousUserInputs: ["Hi team, here's a quick note."],
            pasteboardText: "",
            screenText: ""
        )
        XCTAssertTrue(result.prompt.contains("[Custom writing instructions]\nBe concise."))
        XCTAssertTrue(result.prompt.contains("[Relevant previous writing]"))
        XCTAssertFalse(result.prompt.contains("[Clipboard context]"))
        XCTAssertFalse(result.prompt.contains("[Screen context]"))
    }
}

final class WritingHistoryStoreTests: XCTestCase {
    /// The in-memory stub filters by minimum length, keeps same-app samples first by
    /// recency, mixes in longest, then cross-app recents. Exhaustive behavior is M8;
    /// this is a smoke test.
    func testInMemoryWritingHistoryStoreSelectsAndDedupesSamples() {
        let now = Date()
        let store = InMemoryWritingHistoryStore(entries: [
            WritingHistorySample(text: "Too short", appBundleIdentifier: "com.apple.mail", createdAt: now),
            WritingHistorySample(text: "Hi Maya, thanks for sending this over.", appBundleIdentifier: "com.apple.mail", createdAt: now.addingTimeInterval(-10)),
            WritingHistorySample(text: "A much longer email-style note used as the longest example.", appBundleIdentifier: "com.apple.mail", createdAt: now.addingTimeInterval(-3600)),
            WritingHistorySample(text: "Notes from another app for cross-app recency.", appBundleIdentifier: "com.example.other", createdAt: now.addingTimeInterval(-5))
        ])
        let samples = store.samples(for: WritingHistoryQuery(
            bundleIdentifier: "com.apple.mail",
            longestCount: 1,
            mostRecentCount: 2,
            crossAppRecentCount: 1
        ))
        XCTAssertEqual(samples.count, 3)
        XCTAssertTrue(samples.contains("Hi Maya, thanks for sending this over."))
        XCTAssertTrue(samples.contains("A much longer email-style note used as the longest example."))
        XCTAssertTrue(samples.contains("Notes from another app for cross-app recency."))
        XCTAssertFalse(samples.contains("Too short"))
    }

    func testSameAppOnlyExcludesCrossAppSamples() {
        let store = InMemoryWritingHistoryStore(entries: [
            WritingHistorySample(text: "Same app sample for filtering test.", appBundleIdentifier: "com.apple.mail"),
            WritingHistorySample(text: "Cross app sample that should be filtered.", appBundleIdentifier: "com.example.other")
        ])
        let samples = store.samples(for: WritingHistoryQuery(
            bundleIdentifier: "com.apple.mail",
            sameAppOnly: true
        ))
        XCTAssertEqual(samples, ["Same app sample for filtering test."])
    }
}
