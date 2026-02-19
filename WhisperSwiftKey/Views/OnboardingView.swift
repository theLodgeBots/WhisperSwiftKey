import SwiftUI
import WhisperKit

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    @State private var currentStep = 0
    @State private var testResult: String?
    @State private var isTesting = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Progress dots
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
            
            // Navigation
            HStack {
                if currentStep > 0 {
                    Button("Back") { currentStep -= 1 }
                }
                Spacer()
                if currentStep < 3 {
                    Button("Next") { currentStep += 1 }
                        .buttonStyle(.borderedProminent)
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
        .frame(width: 480, height: 400)
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
            
            Text("On-device speech-to-text that types where your cursor is.\nFast, private, no cloud — powered by WhisperKit.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 40)
            
            VStack(alignment: .leading, spacing: 8) {
                Label("100% on-device — nothing leaves your Mac", systemImage: "lock.shield")
                Label("Double-tap Fn to start dictating", systemImage: "keyboard")
                Label("Text appears at your cursor instantly", systemImage: "text.cursor")
            }
            .font(.callout)
            .padding(.top, 8)
        }
    }
    
    // MARK: - Step 2: Permissions
    
    private var permissionsStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "hand.raised.circle")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            
            Text("Permissions Needed")
                .font(.title2)
                .bold()
            
            VStack(alignment: .leading, spacing: 16) {
                permissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    description: "To hear your voice for transcription",
                    action: {
                        appState.audioService.requestPermission { _ in }
                    }
                )
                
                permissionRow(
                    icon: "accessibility",
                    title: "Accessibility",
                    description: "To detect hotkeys and insert text at cursor",
                    action: {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                )
            }
            .padding(.horizontal, 40)
        }
    }
    
    private func permissionRow(icon: String, title: String, description: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 30)
                .foregroundColor(.accentColor)
            
            VStack(alignment: .leading) {
                Text(title).font(.headline)
                Text(description).font(.caption).foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button("Grant") { action() }
                .buttonStyle(.bordered)
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
            
            Text("Double-tap the Fn key and say something!")
                .font(.callout)
                .foregroundColor(.secondary)
            
            if appState.isRecording {
                HStack(spacing: 8) {
                    Circle().fill(.red).frame(width: 12, height: 12)
                    Text("Recording...").foregroundColor(.red)
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
                    Text("Press Fn twice quickly to start")
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}
