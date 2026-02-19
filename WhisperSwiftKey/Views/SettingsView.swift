import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        TabView {
            GeneralSettingsView()
                .environmentObject(appState)
                .tabItem {
                    Label("General", systemImage: "gear")
                }
            
            ModelsSettingsView()
                .environmentObject(appState)
                .tabItem {
                    Label("Models", systemImage: "cpu")
                }
            
            DictionarySettingsView()
                .environmentObject(appState)
                .tabItem {
                    Label("Dictionary", systemImage: "text.book.closed")
                }
            
            HistorySettingsView()
                .tabItem {
                    Label("History", systemImage: "clock")
                }
        }
        .frame(width: 500, height: 400)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        Form {
            Section("Recording") {
                Picker("Mode", selection: $appState.recordingMode) {
                    ForEach(RecordingMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                
                Toggle("Auto-insert text at cursor", isOn: $appState.autoInsertText)
                Toggle("Show recording overlay", isOn: $appState.showOverlay)
            }
            
            Section("Language") {
                Picker("Language", selection: $appState.selectedLanguage) {
                    Text("Auto-detect").tag("auto")
                    Text("English").tag("en")
                    Text("Spanish").tag("es")
                    Text("French").tag("fr")
                    Text("German").tag("de")
                    Text("Japanese").tag("ja")
                    Text("Chinese").tag("zh")
                    // TODO: Full 58-language list
                }
            }
            
            Section("AI Agent (Optional)") {
                Toggle("Enable AI agent", isOn: $appState.agentEnabled)
                if appState.agentEnabled {
                    TextField("Agent name (e.g., Jarvis)", text: $appState.agentName)
                        .textFieldStyle(.roundedBorder)
                    Text("Say \"Hey \(appState.agentName.isEmpty ? "Agent" : appState.agentName), ...\" to trigger AI processing")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
    }
}

// MARK: - Models

struct ModelsSettingsView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        List {
            ForEach(WhisperService.availableModels, id: \.name) { model in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(model.displayName)
                                .font(.headline)
                            if model.recommended {
                                Text("Recommended")
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.2))
                                    .cornerRadius(4)
                            }
                        }
                        
                        HStack(spacing: 12) {
                            Label("\(ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file))", systemImage: "internaldrive")
                            Label("Quality: \(model.qualityRating)/5", systemImage: "star.fill")
                            Label("Speed: \(model.speedRating)/5", systemImage: "bolt.fill")
                        }
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
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding()
    }
}

// MARK: - Dictionary

struct DictionarySettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var newWord = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom words help Whisper recognize names, jargon, and technical terms.")
                .font(.caption)
                .foregroundColor(.secondary)
            
            HStack {
                TextField("Add word or phrase...", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addWord() }
                
                Button("Add") { addWord() }
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            
            List {
                ForEach(appState.customDictionary, id: \.self) { word in
                    HStack {
                        Text(word)
                        Spacer()
                        Button(role: .destructive) {
                            removeWord(word)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            
            HStack {
                Text("\(appState.customDictionary.count) words")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Clear All") {
                    appState.customDictionary = []
                }
                .disabled(appState.customDictionary.isEmpty)
            }
        }
        .padding()
    }
    
    private func addWord() {
        let word = newWord.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty, !appState.customDictionary.contains(word) else { return }
        appState.customDictionary.append(word)
        newWord = ""
    }
    
    private func removeWord(_ word: String) {
        appState.customDictionary.removeAll { $0 == word }
    }
}

// MARK: - History

struct HistorySettingsView: View {
    var body: some View {
        VStack {
            Text("Transcription history")
                .font(.headline)
            Text("Coming soon — search and browse past transcriptions")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
