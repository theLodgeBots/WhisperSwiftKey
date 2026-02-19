import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    
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
            
            // Last transcription
            if !appState.lastTranscription.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last transcription:")
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
            
            // Actions
            Button {
                appState.toggleRecording()
            } label: {
                Label(
                    appState.isRecording ? "Stop Recording" : "Start Recording",
                    systemImage: appState.isRecording ? "stop.circle.fill" : "mic.circle.fill"
                )
            }
            .keyboardShortcut("r", modifiers: [.command])
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            
            Divider()
            
            Button("Settings...") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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
    }
    
    private var statusColor: Color {
        switch appState.transcriptionState {
        case .idle: return .green
        case .recording: return .red
        case .processing: return .orange
        case .done: return .green
        case .error: return .red
        }
    }
    
    private var statusText: String {
        switch appState.transcriptionState {
        case .idle: return "Ready — Double-tap Fn to dictate"
        case .recording: return "Recording..."
        case .processing: return "Transcribing..."
        case .done(let text): return "Done — \(text.prefix(30))..."
        case .error(let msg): return "Error: \(msg)"
        }
    }
}
