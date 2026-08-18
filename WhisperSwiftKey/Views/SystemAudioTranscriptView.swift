import SwiftUI

/// Live transcript window for the system-audio transcription mode.
struct SystemAudioTranscriptView: View {
    @EnvironmentObject var appState: AppState
    @State private var copiedFeedback = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle()
                    .fill(appState.isSystemAudioTranscribing ? Color.red : Color.secondary)
                    .frame(width: 9, height: 9)
                Text(title)
                    .font(.headline)
                Spacer()
                Button {
                    appState.toggleSystemAudioTranscription()
                } label: {
                    Label(
                        appState.isSystemAudioTranscribing ? "Stop" : (appState.isSystemAudioFinishing ? "Finishing..." : "Start"),
                        systemImage: appState.isSystemAudioTranscribing ? "stop.circle.fill" : "record.circle"
                    )
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(appState.isSystemAudioFinishing)
            }

            if let status = appState.systemAudioStatusMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text(status)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if status.contains("Screen Recording") {
                        Button("Open Screen Recording Settings") {
                            NSWorkspace.shared.open(
                                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                            )
                        }
                        .controlSize(.small)
                    }
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading) {
                        if appState.systemAudioTranscript.isEmpty {
                            Text("Anything playing on your Mac — a video, a Zoom call, music with vocals — will be transcribed here.")
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(appState.systemAudioTranscript)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("transcript-bottom")
                    }
                    .padding(10)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25))
                )
                .onChange(of: appState.systemAudioTranscript) {
                    proxy.scrollTo("transcript-bottom", anchor: .bottom)
                }
            }

            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(appState.systemAudioTranscript, forType: .string)
                    copiedFeedback = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copiedFeedback = false
                    }
                } label: {
                    Label(copiedFeedback ? "Copied" : "Copy Transcript", systemImage: "doc.on.doc")
                }
                .disabled(appState.systemAudioTranscript.isEmpty)

                Spacer()

                if !appState.systemAudioTranscript.isEmpty {
                    Text("\(appState.systemAudioTranscript.split(whereSeparator: \.isWhitespace).count) words")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 300)
    }

    private var title: String {
        if appState.isSystemAudioTranscribing {
            return "Transcribing system audio..."
        }
        if appState.isSystemAudioFinishing {
            return "Finishing transcript..."
        }
        return "System Audio Transcription"
    }
}
