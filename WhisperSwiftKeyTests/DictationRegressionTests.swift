import AppKit
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

        XCTAssertTrue(insertionService.commitProvisionalText("Hey, what's going on now?"))
        XCTAssertFalse(insertionService.commitProvisionalText("Hey, what's going on now?"))
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
}

private final class TextInsertionSpy: TextInsertionServing {
    var regularInsertions: [String] = []
    var provisionalUpdates: [String] = []

    func beginProvisionalInsertionSession(targetApplicationPID: pid_t?) -> Bool { true }

    func updateProvisionalText(_ text: String) -> Bool {
        provisionalUpdates.append(text)
        return true
    }

    func commitProvisionalText(_ text: String) -> Bool { true }

    func cancelProvisionalInsertionSession() {}

    func insertText(_ text: String) {
        regularInsertions.append(text)
    }
}
