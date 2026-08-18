import SwiftUI
import ApplicationServices

final class WhisperSwiftKeyAppDelegate: NSObject, NSApplicationDelegate {
#if DEBUG
    private var accessibilitySmokeOverlay: RecordingOverlayController?
#endif

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Unit-test hosts share the application bundle identifier but must not
        // terminate a real running copy of the menu-bar app.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let existingInstances = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != currentPID && !$0.isTerminated }

        guard existingInstances.isEmpty else {
            let paths = existingInstances
                .compactMap { $0.bundleURL?.path }
                .joined(separator: ", ")
            print("[App] Another WhisperSwiftKey instance is already running at \(paths); closing this duplicate")
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
            return
        }
    }

#if DEBUG
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["WSK_AX_SMOKE_TEST"] == "1" else { return }

        Task { @MainActor in
            // Give the external editor host time to become the frontmost app.
            try? await Task.sleep(for: .milliseconds(350))

            if let requestedPIDString = ProcessInfo.processInfo.environment["WSK_AX_SMOKE_TARGET_PID"],
               let requestedPID = pid_t(requestedPIDString),
               let requestedApplication = NSRunningApplication(processIdentifier: requestedPID) {
                _ = requestedApplication.activate(options: [.activateAllWindows])
                try? await Task.sleep(for: .milliseconds(250))
            }

            let requestedTargetPID = ProcessInfo.processInfo.environment["WSK_AX_SMOKE_TARGET_PID"]
                .flatMap(pid_t.init)
            guard let targetApplication = requestedTargetPID
                .flatMap(NSRunningApplication.init(processIdentifier:))
                ?? NSWorkspace.shared.frontmostApplication else {
                Self.writeSmokeResult("AX_SMOKE target=missing")
                NSApplication.shared.terminate(nil)
                return
            }

            let insertionService = TextInsertionService()
            insertionService.beginProvisionalInsertionSession(
                targetApplicationPID: targetApplication.processIdentifier
            )

            let overlay = RecordingOverlayController()
            accessibilitySmokeOverlay = overlay
            overlay.show(
                state: .recording,
                modelName: "AX smoke test",
                previewText: "Listening",
                targetApplicationPID: targetApplication.processIdentifier
            )

            let firstUpdate = insertionService.updateProvisionalText("Hey")
            let secondUpdate = insertionService.updateProvisionalText("Hey, what's going on now?")
            let committed = insertionService.commitProvisionalText("Hey, what's going on now?")
            if committed == .needsFallbackInsertion {
                insertionService.insertText("Hey, what's going on now?")
                try? await Task.sleep(for: .milliseconds(250))
            }
            let caretRect = RecordingOverlayController.caretRectInScreenCoordinates(
                for: targetApplication.processIdentifier
            )
            let focusedValue = Self.focusedTextValue(for: targetApplication.processIdentifier) ?? "(unavailable)"

            Self.writeSmokeResult(
                "AX_SMOKE target=\(targetApplication.localizedName ?? "unknown") " +
                "trusted=\(AXIsProcessTrusted()) " +
                "first=\(firstUpdate) second=\(secondUpdate) commit=\(String(describing: committed)) " +
                "caret=\(caretRect.map(String.init(describing:)) ?? "nil") " +
                "value=\(focusedValue)"
            )

            // Keep the real floating indicator visible briefly so the smoke test
            // exercises the same panel lifecycle as a dictation session.
            try? await Task.sleep(for: .milliseconds(900))
            overlay.dismiss()
            accessibilitySmokeOverlay = nil
            NSApplication.shared.terminate(nil)
        }
    }

    private static func focusedTextValue(for processIdentifier: pid_t) -> String? {
        let application = AXUIElementCreateApplication(processIdentifier)
        var focusedElementRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        ) == .success,
        let focusedElementRef else {
            return nil
        }

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElementRef as! AXUIElement,
            kAXValueAttribute as CFString,
            &valueRef
        ) == .success else {
            return nil
        }
        return valueRef as? String
    }

    private static func writeSmokeResult(_ result: String) {
        guard let data = (result + "\n").data(using: .utf8) else { return }
        FileHandle.standardOutput.write(data)
    }
#endif
}

@main
struct WhisperSwiftKeyApp: App {
    @NSApplicationDelegateAdaptor(WhisperSwiftKeyAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @State private var showOnboarding =
        ProcessInfo.processInfo.environment["WSK_AX_SMOKE_TEST"] != "1" &&
        !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    
    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Image(systemName: menuBarIconName)
                .symbolEffect(.pulse, isActive: appState.isRecording || appState.isSystemAudioTranscribing)
                .symbolEffect(.bounce, value: appState.hotkeyFeedbackCount)
        }
        
        Settings {
            SettingsView()
                .environmentObject(appState)
        }
        
        Window("Transcription History", id: "dictation-history") {
            DictationHistoryWindowView()
                .environmentObject(appState)
        }
        .defaultSize(width: 480, height: 400)
        .defaultPosition(.center)

        Window("System Audio Transcription", id: "system-transcript") {
            SystemAudioTranscriptView()
                .environmentObject(appState)
        }
        .defaultSize(width: 480, height: 380)
        .defaultPosition(.center)

        // Onboarding window
        Window("Welcome to WhisperSwiftKey", id: "onboarding") {
            OnboardingView(isPresented: $showOnboarding)
                .environmentObject(appState)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

    private var menuBarIconName: String {
        if appState.hotkeyFeedbackActive {
            return "keyboard"
        }
        if appState.isSystemAudioTranscribing {
            return "waveform.circle.fill"
        }
        if appState.isSystemAudioFinishing {
            return "ellipsis.circle"
        }
        return appState.isRecording ? "mic.fill" : "mic"
    }
}
