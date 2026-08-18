import SwiftUI

/// Searchable transcription history with one-click copy to clipboard. Shown both
/// in the Settings > History tab and in the standalone history window.
struct DictationHistoryList: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var copiedID: UUID?
    @State private var isConfirmingClear = false

    private var history: [Transcription] {
        appState.fetchHistory()
    }

    var filteredHistory: [Transcription] {
        if searchText.isEmpty { return history }
        return history.filter { $0.originalText.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transcription History")
                    .font(.headline)
                Spacer()
                Button("Clear All", role: .destructive) {
                    isConfirmingClear = true
                }
                .disabled(history.isEmpty)
            }

            TextField("Search...", text: $searchText)
                .textFieldStyle(.roundedBorder)

            if filteredHistory.isEmpty {
                VStack {
                    Spacer()
                    Text(history.isEmpty ? "No transcriptions yet" : "No matches")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(filteredHistory, id: \.id) { item in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.originalText)
                                .font(.body)
                                .lineLimit(3)
                                .textSelection(.enabled)

                            HStack(spacing: 12) {
                                Text(item.timestamp, style: .relative)
                                Text("\(item.wordCount) words")
                                Text(String(format: "%.1fs", item.durationSeconds))
                                if let lang = item.language {
                                    Text(lang.uppercased())
                                }
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }

                        Spacer(minLength: 0)

                        Button {
                            copy(item)
                        } label: {
                            Image(systemName: copiedID == item.id ? "checkmark" : "doc.on.doc")
                                .foregroundColor(copiedID == item.id ? .green : .secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Copy to clipboard")
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        Button("Copy") {
                            copy(item)
                        }
                    }
                }
            }
        }
        .padding()
        .confirmationDialog(
            "Clear all transcription history?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                appState.clearHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    private func copy(_ item: Transcription) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.originalText, forType: .string)
        copiedID = item.id
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedID == item.id {
                copiedID = nil
            }
        }
    }
}

/// Standalone transcription history window, openable from Settings and the menu bar.
struct DictationHistoryWindowView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        DictationHistoryList()
            .environmentObject(appState)
            .frame(minWidth: 440, minHeight: 320)
    }
}
