import AVFoundation
import SwiftUI
import WhisperKit

struct OnboardingView: View {
    enum MicrophonePermissionState: Equatable {
        case unknown
        case granted
        case missing
    }

    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    @State private var currentStep = 0
    @State private var microphonePermissionState: MicrophonePermissionState = .unknown

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { step in
                    Circle()
                        .fill(step <= currentStep ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 20)

            Spacer()

            switch currentStep {
            case 0: welcomeStep
            case 1: permissionsStep
            case 2: modelStep
            case 3: testStep
            default: EmptyView()
            }

            Spacer()

            HStack {
                if currentStep > 0 {
                    Button("Back") { currentStep -= 1 }
                }
                Spacer()
                if currentStep < 3 {
                    Button("Next") { currentStep += 1 }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canProceedToNextStep)
                } else {
                    Button("Done") {
                        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
        .frame(width: 580, height: 560)
        .onAppear {
            refreshSetupChecks()
        }
    }

    private var canProceedToNextStep: Bool {
        currentStep != 1 || permissionsStepReady
    }

    private var permissionsStepReady: Bool {
        appState.accessibilityPermissionStatus == .granted && microphonePermissionState == .granted
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("Welcome to WhisperSwiftKey")
                .font(.title)
                .bold()

            Text("On-device speech-to-text that types where your cursor is.\nFast, private, no cloud - powered by WhisperKit.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 40)

            VStack(alignment: .leading, spacing: 8) {
                Label("100% on-device - nothing leaves your Mac", systemImage: "lock.shield")
                Label("Double-tap Fn/Globe to start dictating", systemImage: "keyboard")
                Label("Text appears at your cursor instantly", systemImage: "text.cursor")
            }
            .font(.callout)
            .padding(.top, 8)
        }
    }

    // MARK: - Step 2: Permissions / Keyboard Setup

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "checklist")
                .font(.system(size: 44))
                .foregroundColor(.orange)
                .frame(maxWidth: .infinity)

            Text("Set Up Permissions & Fn/Globe")
                .font(.title2)
                .bold()
                .frame(maxWidth: .infinity)

            Text("WhisperSwiftKey needs Accessibility and Microphone access. We also check whether macOS is using the Fn/Globe key for another shortcut.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)

            VStack(spacing: 10) {
                setupChecklistRow(
                    number: 1,
                    icon: "accessibility",
                    title: "Enable Accessibility (Required)",
                    subtitle: "Allows the app to listen for the Fn/Globe hotkey and insert text.",
                    status: accessibilityStatusText,
                    statusColor: accessibilityStatusColor
                ) {
                    Button("Request") { appState.requestAccessibilityPermission() }
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    Button("Re-check") { appState.refreshAccessibilityPermissionStatus() }
                }

                setupChecklistRow(
                    number: 2,
                    icon: "mic.fill",
                    title: "Allow Microphone (Required)",
                    subtitle: "Lets WhisperSwiftKey capture audio for transcription.",
                    status: microphoneStatusText,
                    statusColor: microphoneStatusColor
                ) {
                    Button("Request") {
                        appState.audioService.requestPermission { _ in
                            refreshMicrophonePermissionStatus()
                        }
                    }
                    Button("Re-check") { refreshMicrophonePermissionStatus() }
                }

                setupChecklistRow(
                    number: 3,
                    icon: "keyboard",
                    title: "Check Fn/Globe Key Conflicts",
                    subtitle: "macOS may reserve Fn/Globe for Emoji, Dictation, or other shortcuts.",
                    status: fnConflictStatusText,
                    statusColor: fnConflictStatusColor
                ) {
                    Button("Open Keyboard Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                    }
                    Button("Re-check") { appState.refreshFnKeyConflictStatus() }
                }

                setupChecklistRow(
                    number: 4,
                    icon: "bolt.circle",
                    title: "Hotkey Listener Ready",
                    subtitle: "This confirms the event tap can be created after Accessibility is granted.",
                    status: hotkeyReadyStatusText,
                    statusColor: hotkeyReadyStatusColor
                ) {
                    Button("Refresh All") { refreshSetupChecks() }
                }
            }
            .padding(.horizontal, 26)

            if permissionsStepReady {
                Label("Required permissions are ready. Continue to choose a Whisper model.", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
                    .frame(maxWidth: .infinity)
            } else {
                Text("Next is enabled after Accessibility and Microphone are granted.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            refreshSetupChecks()
        }
    }

    @ViewBuilder
    private func setupChecklistRow<Actions: View>(
        number: Int,
        icon: String,
        title: String,
        subtitle: String,
        status: String,
        statusColor: Color,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Text("\(number)")
                    .font(.caption.bold())
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.accentColor.opacity(0.15)))
                    .foregroundColor(.accentColor)

                Image(systemName: icon)
                    .foregroundColor(.accentColor)
                    .frame(width: 16)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(title)
                            .font(.headline)
                        Spacer()
                        Text(status)
                            .font(.caption)
                            .foregroundColor(statusColor)
                    }

                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if number == 1, appState.accessibilityPermissionStatus != .granted {
                        Text("Enable WhisperSwiftKey under Privacy & Security > Accessibility, then click Re-check.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("If it is already enabled, confirm the permission matches this running build: \(appState.runtimeAppPath)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }

                    if number == 3, case .possibleSystemConflict(let detail) = appState.fnKeyConflictStatus {
                        Text(detail)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            HStack(spacing: 8) {
                Spacer().frame(width: 50)
                actions()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.gray.opacity(0.08))
        )
    }

    private var accessibilityStatusText: String {
        switch appState.accessibilityPermissionStatus {
        case .granted: return "Granted"
        case .missing: return "Missing"
        case .unknown: return "Unknown"
        }
    }

    private var accessibilityStatusColor: Color {
        switch appState.accessibilityPermissionStatus {
        case .granted: return .green
        case .missing: return .orange
        case .unknown: return .secondary
        }
    }

    private var microphoneStatusText: String {
        switch microphonePermissionState {
        case .granted: return "Granted"
        case .missing: return "Missing"
        case .unknown: return "Unknown"
        }
    }

    private var microphoneStatusColor: Color {
        switch microphonePermissionState {
        case .granted: return .green
        case .missing: return .orange
        case .unknown: return .secondary
        }
    }

    private var fnConflictStatusText: String {
        switch appState.fnKeyConflictStatus {
        case .noConflictDetected: return "No conflict detected"
        case .possibleSystemConflict: return "Possible conflict"
        case .unknown: return "Unknown"
        }
    }

    private var fnConflictStatusColor: Color {
        switch appState.fnKeyConflictStatus {
        case .noConflictDetected: return .green
        case .possibleSystemConflict: return .orange
        case .unknown: return .secondary
        }
    }

    private var hotkeyReadyStatusText: String {
        if appState.accessibilityPermissionStatus != .granted {
            return "Waiting for Accessibility"
        }
        if appState.hotkeyService?.isEventTapActive == true {
            return "Ready"
        }
        return "Not active yet"
    }

    private var hotkeyReadyStatusColor: Color {
        if appState.hotkeyService?.isEventTapActive == true { return .green }
        return appState.accessibilityPermissionStatus == .granted ? .orange : .secondary
    }

    private func refreshSetupChecks() {
        appState.refreshAccessibilityPermissionStatus()
        appState.refreshFnKeyConflictStatus()
        refreshMicrophonePermissionStatus()
    }

    private func refreshMicrophonePermissionStatus() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphonePermissionState = .granted
        case .denied, .restricted:
            microphonePermissionState = .missing
        case .notDetermined:
            microphonePermissionState = .unknown
        @unknown default:
            microphonePermissionState = .unknown
        }
    }

    // MARK: - Step 3: Model

    private var modelStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "cpu")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("Choose a Model")
                .font(.title2)
                .bold()

            Text("Larger models are more accurate but use more memory.")
                .font(.callout)
                .foregroundColor(.secondary)

            VStack(spacing: 8) {
                ForEach(WhisperService.availableModels) { model in
                    HStack {
                        VStack(alignment: .leading) {
                            HStack {
                                Text(model.displayName).font(.headline)
                                if model.recommended {
                                    Text("Recommended")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.2))
                                        .cornerRadius(4)
                                }
                            }
                            Text(ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if appState.selectedModel == model.name {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.accentColor)
                        } else {
                            Button("Select") {
                                appState.selectedModel = model.name
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
            .padding(.horizontal, 40)

            if appState.whisperService.isDownloading {
                ProgressView(value: appState.whisperService.downloadProgress)
                    .padding(.horizontal, 40)
                Text("Downloading model...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Step 4: Test

    private var testStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 48))
                .foregroundColor(.green)

            Text("Test Drive")
                .font(.title2)
                .bold()

            Text("Double-tap the Fn/Globe key and say something!")
                .font(.callout)
                .foregroundColor(.secondary)

            if appState.accessibilityPermissionStatus != .granted {
                Text("Accessibility is not enabled yet, so the hotkey will not trigger. Go back to the setup step to finish permissions.")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            if case .possibleSystemConflict = appState.fnKeyConflictStatus {
                Text("Fn/Globe may still be mapped to a macOS shortcut. If dictation does not start/stop, check Keyboard settings.")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            if appState.isRecording {
                HStack(spacing: 8) {
                    Circle().fill(.red).frame(width: 12, height: 12)
                    Text("Dictating...").foregroundColor(.red)
                }
                .padding()
            } else if case .processing = appState.transcriptionState {
                ProgressView("Transcribing...")
            } else if !appState.lastTranscription.isEmpty {
                VStack(spacing: 8) {
                    Text("You said:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(appState.lastTranscription)
                        .font(.body)
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                }
                .padding(.horizontal, 40)

                Image(systemName: "checkmark.circle.fill")
                    .font(.title)
                    .foregroundColor(.green)
                Text("You're all set!")
                    .font(.headline)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "keyboard")
                        .font(.title)
                        .foregroundColor(.secondary)
                    Text("Press Fn/Globe twice quickly to start")
                        .foregroundColor(.secondary)
                    Button("Re-check Setup") {
                        refreshSetupChecks()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .onAppear {
            refreshSetupChecks()
        }
    }
}
