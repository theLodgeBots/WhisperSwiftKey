import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject var appState: AppState
    @State private var copiedDictationID: UUID?
    
    var body: some View {
        VStack(spacing: 0) {
            // Status
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            Divider()

            if appState.accessibilityPermissionStatus != .granted {
                accessibilityWarning
                Divider()
            } else if case .possibleSystemConflict = appState.fnKeyConflictStatus {
                fnConflictWarning
                Divider()
            }
            
            // Last transcription
            if !appState.lastTranscription.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last dictation:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(appState.lastTranscription)
                        .font(.body)
                        .lineLimit(3)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Divider()
            }

            recentDictationsSection

            // Actions
            Button {
                appState.toggleRecording()
            } label: {
                Label(
                    appState.isRecording ? "Stop Dictation" : "Start Dictation",
                    systemImage: appState.isRecording ? "stop.circle.fill" : "mic.circle.fill"
                )
            }
            .disabled(appState.isSystemAudioTranscribing || appState.isSystemAudioFinishing)
            .keyboardShortcut("r", modifiers: [.command])
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            Button {
                if appState.isSystemAudioTranscribing {
                    appState.stopSystemAudioTranscription()
                    openWindow(id: "system-transcript")
                    NSApp.activate(ignoringOtherApps: true)
                } else {
                    openWindow(id: "system-transcript")
                    NSApp.activate(ignoringOtherApps: true)
                    appState.startSystemAudioTranscription()
                }
            } label: {
                Label(
                    appState.isSystemAudioTranscribing
                        ? "Stop System Audio Transcription"
                        : (appState.isSystemAudioFinishing ? "Finishing System Audio Transcript..." : "Transcribe System Audio..."),
                    systemImage: appState.isSystemAudioTranscribing ? "stop.circle" : "waveform"
                )
            }
            .disabled(appState.isSystemAudioFinishing || appState.isRecording)
            .keyboardShortcut("t", modifiers: [.command])
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            
            if appState.whisperService.isModelLoaded {
                Button {
                    appState.sleepModel()
                } label: {
                    Label("Sleep Model", systemImage: "moon.fill")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            } else if appState.whisperService.isModelAsleep {
                Button {
                    appState.wakeModel()
                } label: {
                    Label("Wake Model", systemImage: "sun.max.fill")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            } else if appState.whisperService.isDownloading {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading model...")
                        .font(.body)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }

            Divider()

            Button("Settings...") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .keyboardShortcut(",", modifiers: [.command])
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            
            Divider()
            
            Button("Quit WhisperSwiftKey") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(width: 280)
        .onAppear {
            appState.refreshAccessibilityPermissionStatus()
            appState.refreshFnKeyConflictStatus()
        }
    }

    @ViewBuilder
    private var recentDictationsSection: some View {
        let recent = appState.recentDictations()
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recent dictations — click to copy")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 2)

                ForEach(recent) { item in
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.originalText, forType: .string)
                        copiedDictationID = item.id
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: copiedDictationID == item.id ? "checkmark" : "doc.on.doc")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(item.originalText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 3)
                    .help(item.originalText)
                }
            }
            .padding(.bottom, 4)

            Divider()
        }
    }

    private var accessibilityWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Accessibility Permission Required", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundColor(.orange)

            Text("Fn/Globe hotkeys will not work until WhisperSwiftKey is enabled in macOS Accessibility settings.")
                .font(.caption2)
                .foregroundColor(.secondary)

            Text("If it is already enabled, you may be running a different build copy.")
                .font(.caption2)
                .foregroundColor(.secondary)

            Text("Current app: \(appState.runtimeBundleIdentifier)")
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(appState.runtimeAppPath)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 6) {
                Button("Request") {
                    appState.requestAccessibilityPermission()
                }
                Button("Open") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                Button("Re-check") {
                    appState.refreshAccessibilityPermissionStatus()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            HStack(spacing: 6) {
                Button("Open Setup Guide") {
                    openWindow(id: "onboarding")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(appState.runtimeAppPath, forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
    }

    private var fnConflictWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Fn/Globe Key May Be Reserved", systemImage: "keyboard")
                .font(.caption.weight(.semibold))
                .foregroundColor(.orange)

            Text("macOS may be using Fn/Globe for another shortcut. If dictation does not toggle, change Fn/Globe behavior in Keyboard settings.")
                .font(.caption2)
                .foregroundColor(.secondary)

            if case .possibleSystemConflict(let detail) = appState.fnKeyConflictStatus {
                Text(detail)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Button("Keyboard Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                }
                Button("Re-check") {
                    appState.refreshFnKeyConflictStatus()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            HStack(spacing: 6) {
                Button("Open Setup Guide") {
                    openWindow(id: "onboarding")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.06))
    }
    
    private var statusColor: Color {
        if appState.accessibilityPermissionStatus != .granted {
            return .orange
        }
        if case .possibleSystemConflict = appState.fnKeyConflictStatus {
            return .orange
        }
        if appState.isSystemAudioTranscribing {
            return .red
        }
        if appState.isSystemAudioFinishing {
            return .orange
        }
        switch appState.transcriptionState {
        case .idle: return .green
        case .loadingModel: return .orange
        case .recording: return .red
        case .processing: return .orange
        case .done: return .green
        case .error: return .red
        }
    }
    
    private var statusText: String {
        if appState.accessibilityPermissionStatus != .granted {
            return "Setup required - Enable Accessibility"
        }
        if case .possibleSystemConflict = appState.fnKeyConflictStatus {
            return "Check Fn/Globe keyboard setting"
        }
        if appState.isSystemAudioTranscribing {
            return "Transcribing system audio..."
        }
        if appState.isSystemAudioFinishing {
            return "Finishing system audio transcript..."
        }
        switch appState.transcriptionState {
        case .idle: return "Ready - Double-tap Fn/Globe to dictate"
        case .loadingModel: return "Loading model..."
        case .recording: return "Dictating..."
        case .processing: return "Transcribing..."
        case .done(let text): return "Done — \(text.prefix(30))..."
        case .error(let msg): return "Error: \(msg)"
        }
    }
}
