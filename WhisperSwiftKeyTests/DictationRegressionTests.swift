import AppKit
import ApplicationServices
import Foundation
import XCTest
@testable import WhisperSwiftKey

final class DictationRegressionTests: XCTestCase {
    @MainActor
    func testLivePreviewAtomicallyReplacesTheWholeHypothesis() {
        let defaults = UserDefaults(suiteName: "DictationRegressionTests.\(UUID().uuidString)")!
        let insertionSpy = TextInsertionSpy()
        let appState = AppState(textInsertionService: insertionSpy, defaults: defaults)

        appState.updateLiveDictationPreview("Hey")
        appState.updateLiveDictationPreview("Hey, what's going on now?")

        XCTAssertEqual(insertionSpy.provisionalUpdates, ["Hey", "Hey, what's going on now?"])
        XCTAssertTrue(insertionSpy.regularInsertions.isEmpty)
    }

    @MainActor
    func testLivePreviewStopsAXUpdatesAfterTheEditorRejectsOne() {
        let defaults = UserDefaults(suiteName: "DictationRegressionTests.\(UUID().uuidString)")!
        let insertionSpy = TextInsertionSpy()
        insertionSpy.updateResult = false
        let appState = AppState(textInsertionService: insertionSpy, defaults: defaults)

        appState.updateLiveDictationPreview("Hey")
        appState.updateLiveDictationPreview("Hey, what's going on now?")

        XCTAssertEqual(insertionSpy.provisionalUpdates, ["Hey"])
    }

    @MainActor
    func testFinalTextUsesNormalInsertionWhenNoProvisionalTextExists() {
        let defaults = UserDefaults(suiteName: "DictationRegressionTests.\(UUID().uuidString)")!
        let insertionSpy = TextInsertionSpy()
        insertionSpy.commitResult = .needsFallbackInsertion
        let appState = AppState(textInsertionService: insertionSpy, defaults: defaults)

        appState.finalizeTextInsertion("Hey, what's going on now?")

        XCTAssertEqual(insertionSpy.regularInsertions, ["Hey, what's going on now?"])
    }

    @MainActor
    func testFinalTextDoesNotBlindlyPasteOverUnresolvedProvisionalText() {
        let defaults = UserDefaults(suiteName: "DictationRegressionTests.\(UUID().uuidString)")!
        let insertionSpy = TextInsertionSpy()
        insertionSpy.commitResult = .provisionalTextPreserved
        let appState = AppState(textInsertionService: insertionSpy, defaults: defaults)

        appState.finalizeTextInsertion("Hey, what's going on now?")

        XCTAssertTrue(insertionSpy.regularInsertions.isEmpty)
    }

    func testStreamingFragmentsDoNotRepeatConfirmedPrefix() async {
        let merged = await WhisperService.mergeTranscriptFragments(
            "Hey",
            "Hey, what's going on now?"
        )
        XCTAssertEqual(merged, "Hey, what's going on now?")
    }

    func testMinimalStreamingReplacementAppendsAtTheExistingCaret() {
        let delta = TextInsertionService.minimalReplacement(
            from: "What time is",
            to: "What time is it?"
        )

        XCTAssertEqual(delta.range, NSRange(location: 12, length: 0))
        XCTAssertEqual(delta.replacement, " it?")
    }

    func testMinimalStreamingReplacementIsolatesARevision() {
        let delta = TextInsertionService.minimalReplacement(
            from: "Hello world",
            to: "Hallo world"
        )

        XCTAssertEqual(delta.range, NSRange(location: 1, length: 1))
        XCTAssertEqual(delta.replacement, "a")
    }

    func testFinalizationGateAcceptsOnlyOneResultPerRecording() {
        let sessionID = UUID()
        var gate = DictationFinalizationGate()

        XCTAssertTrue(gate.begin(sessionID: sessionID))
        XCTAssertFalse(gate.begin(sessionID: sessionID))
        XCTAssertTrue(gate.consume(sessionID: sessionID))
        XCTAssertFalse(gate.consume(sessionID: sessionID))
    }

    func testSpeechGateRejectsSilence() {
        XCTAssertFalse(SpeechActivityDetector.containsSpeech(Array(repeating: 0, count: 16_000)))
    }

    func testSpeechGateAcceptsVoicedAudio() {
        let samples = (0..<16_000).map { index in
            0.05 * sin(2 * .pi * 220 * Double(index) / 16_000)
        }

        XCTAssertTrue(SpeechActivityDetector.containsSpeech(samples.map(Float.init)))
    }

    func testSpeechGateDoesNotRequireAFullSecondOfSpeech() {
        let samples = (0..<1_600).map { index in
            0.05 * sin(2 * .pi * 220 * Double(index) / 16_000)
        }

        XCTAssertTrue(SpeechActivityDetector.containsSpeech(samples.map(Float.init)))
    }

    func testBrowsersAndTerminalsUseClipboardOnlyInsertion() {
        XCTAssertTrue(TextInsertionService.usesClipboardOnlyInsertion(bundleID: "com.google.Chrome"))
        XCTAssertTrue(TextInsertionService.usesClipboardOnlyInsertion(bundleID: "com.google.Chrome.beta"))
        XCTAssertTrue(TextInsertionService.usesClipboardOnlyInsertion(bundleID: "com.apple.Safari"))
        XCTAssertTrue(TextInsertionService.usesClipboardOnlyInsertion(bundleID: "org.mozilla.firefox"))
        XCTAssertTrue(TextInsertionService.usesClipboardOnlyInsertion(bundleID: "com.apple.Terminal"))
        XCTAssertFalse(TextInsertionService.usesClipboardOnlyInsertion(bundleID: "com.apple.TextEdit"))
        XCTAssertFalse(TextInsertionService.usesClipboardOnlyInsertion(bundleID: "com.apple.Notes"))
    }

    func testGhostPhraseFromSilenceIsFiltered() async {
        // "Thank you." decoded from a silent stretch: elevated no-speech probability.
        let filtered = await WhisperService.isLikelyHallucination(
            text: "Thank you.",
            noSpeechProb: 0.45,
            avgLogprob: -0.3
        )
        XCTAssertTrue(filtered)
    }

    func testGenuinelySpokenThankYouIsKept() async {
        let filtered = await WhisperService.isLikelyHallucination(
            text: "Thank you.",
            noSpeechProb: 0.05,
            avgLogprob: -0.2
        )
        XCTAssertFalse(filtered)
    }

    func testLowConfidenceNonSpeechSegmentIsFilteredRegardlessOfText() async {
        let filtered = await WhisperService.isLikelyHallucination(
            text: "The quick brown fox",
            noSpeechProb: 0.8,
            avgLogprob: -0.9
        )
        XCTAssertTrue(filtered)
    }

    func testNormalDictationIsNotFiltered() async {
        let filtered = await WhisperService.isLikelyHallucination(
            text: "Please send the report by Friday.",
            noSpeechProb: 0.1,
            avgLogprob: -0.25
        )
        XCTAssertFalse(filtered)
    }

    func testPhraseNormalizationIgnoresCaseAndPunctuation() async {
        let normalized = await WhisperService.normalizedTranscriptPhrase(" Thanks for watching! ")
        XCTAssertEqual(normalized, "thanks for watching")
        let phrases = await WhisperService.hallucinationPhrases
        XCTAssertTrue(phrases.contains(normalized))
    }

    func testChunkSplitPrefersTheQuietestRecentMoment() {
        // 10 s of loud tone with 500 ms of silence from 7.0 s to 7.5 s.
        var samples = (0..<160_000).map { index in
            Float(0.1 * sin(2 * .pi * 220 * Double(index) / 16_000))
        }
        for index in 112_000..<120_000 {
            samples[index] = 0
        }

        let cutIndex = SpeechActivityDetector.quietestCutIndex(
            in: samples,
            searchingLast: 64_000
        )

        XCTAssertTrue(
            (112_000...120_000).contains(cutIndex),
            "Cut index \(cutIndex) should fall inside the silent stretch"
        )
    }

    func testLegacyModelNamesMigrateToCurrentVariants() async {
        let turbo = await WhisperService.currentModelName(for: "openai_whisper-large-v3_turbo")
        let large = await WhisperService.currentModelName(for: "openai_whisper-large-v3")

        XCTAssertEqual(
            turbo,
            "openai_whisper-large-v3-v20240930_turbo"
        )
        XCTAssertEqual(
            large,
            "openai_whisper-large-v3-v20240930_626MB"
        )
    }

    @MainActor
    func testTextViewReceivesExactStreamingHypothesisAndExposesCaretBounds() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 240, y: 240, width: 560, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let textView = NSTextView(frame: window.contentView?.bounds ?? .zero)
        textView.autoresizingMask = [.width, .height]
        textView.string = "Dictation marker test: "
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApplication.shared.activate(ignoringOtherApps: true)
        defer { window.close() }

        try await Task.sleep(for: .milliseconds(150))

        let insertionService = TextInsertionService()
        guard insertionService.beginProvisionalInsertionSession(
            targetApplicationPID: ProcessInfo.processInfo.processIdentifier
        ) else {
            throw XCTSkip(
                "macOS did not vend AX caret attributes (for example, while the desktop is locked or shielded)"
            )
        }
        XCTAssertTrue(insertionService.updateProvisionalText("Hey"))
        XCTAssertEqual(textView.string, "Dictation marker test: Hey")

        XCTAssertTrue(insertionService.updateProvisionalText("Hey, what's going on now?"))
        XCTAssertEqual(textView.string, "Dictation marker test: Hey, what's going on now?")

        XCTAssertEqual(
            insertionService.commitProvisionalText("Hey, what's going on now?"),
            .committed
        )
        XCTAssertEqual(
            insertionService.commitProvisionalText("Hey, what's going on now?"),
            .needsFallbackInsertion
        )
        XCTAssertEqual(textView.string, "Dictation marker test: Hey, what's going on now?")

        guard let caretRect = RecordingOverlayController.caretRectInScreenCoordinates(
            for: ProcessInfo.processInfo.processIdentifier
        ) else {
            XCTFail("The focused text view did not expose AX caret bounds")
            return
        }
        XCTAssertTrue(
            window.frame.insetBy(dx: -24, dy: -24).contains(
                NSPoint(x: caretRect.midX, y: caretRect.midY)
            ),
            "Caret bounds should resolve inside the focused editor window, not near the mouse pointer"
        )
    }

    @MainActor
    func testFinalFallbackPastesIntoTheFocusedTextView() async throws {
        guard AXIsProcessTrusted() else {
            throw XCTSkip("The XCTest host is not trusted to post global keyboard paste events")
        }

        let window = NSWindow(
            contentRect: NSRect(x: 260, y: 260, width: 480, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let textView = NSTextView(frame: window.contentView?.bounds ?? .zero)
        textView.autoresizingMask = [.width, .height]
        textView.string = "Fallback test: "
        textView.setSelectedRange(
            NSRange(location: (textView.string as NSString).length, length: 0)
        )
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApplication.shared.activate(ignoringOtherApps: true)
        defer { window.close() }

        try await Task.sleep(for: .milliseconds(100))

        TextInsertionService().insertText("dictated text")

        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(textView.string, "Fallback test: dictated text")
    }
}

private final class TextInsertionSpy: TextInsertionServing {
    var regularInsertions: [String] = []
    var provisionalUpdates: [String] = []
    var updateResult = true
    var commitResult: ProvisionalTextCommitResult = .committed

    func beginProvisionalInsertionSession(targetApplicationPID: pid_t?) -> Bool { true }

    func updateProvisionalText(_ text: String) -> Bool {
        provisionalUpdates.append(text)
        return updateResult
    }

    func commitProvisionalText(_ text: String) -> ProvisionalTextCommitResult {
        commitResult
    }

    func cancelProvisionalInsertionSession() {}

    func insertText(_ text: String) {
        regularInsertions.append(text)
    }
}
