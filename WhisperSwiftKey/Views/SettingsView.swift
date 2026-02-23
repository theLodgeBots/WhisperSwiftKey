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
                .environmentObject(appState)
                .tabItem {
                    Label("History", systemImage: "clock")
                }
        }
        .frame(width: 520, height: 440)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        Form {
            Section("Dictation Hotkey") {
                Picker("Mode", selection: $appState.recordingMode) {
                    ForEach(RecordingMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .onChange(of: appState.recordingMode) { _, newValue in
                    appState.hotkeyService?.mode = newValue == .pushToTalk ? .pushToTalk : .doubleTap
                    if newValue == .pushToTalk {
                        appState.hotkeyService?.onPushStart = { [weak appState] in
                            appState?.startRecording()
                        }
                        appState.hotkeyService?.onPushStop = { [weak appState] in
                            appState?.stopRecording()
                        }
                    }
                }
                
                Toggle("Auto-insert text at cursor", isOn: $appState.autoInsertText)
                Toggle("Show dictation overlay", isOn: $appState.showOverlay)

                if appState.accessibilityPermissionStatus != .granted {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Accessibility permission is required for the Fn/Globe hotkey and text insertion.")
                            .font(.caption)
                            .foregroundColor(.orange)
                        HStack(spacing: 8) {
                            Button("Request Permission") {
                                appState.requestAccessibilityPermission()
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            }
                            Button("Re-check") {
                                appState.refreshAccessibilityPermissionStatus()
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }

                switch appState.fnKeyConflictStatus {
                case .possibleSystemConflict(let detail):
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Fn/Globe key may be reserved by macOS")
                            .font(.caption)
                            .foregroundColor(.orange)
                        Text(detail)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("Check System Settings > Keyboard and change the Fn/Globe key behavior if the hotkey does not trigger.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                case .unknown:
                    Text("If Fn/Globe does not trigger dictation, check System Settings > Keyboard for Fn/Globe key shortcuts.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                case .noConflictDetected:
                    EmptyView()
                }

                Button("Re-check Fn/Globe Key") {
                    appState.refreshFnKeyConflictStatus()
                }
                .buttonStyle(.borderless)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Verify Hotkey Key Presses")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("Press the key you want to use twice. WhisperSwiftKey will show what macOS is actually sending.")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    HStack(spacing: 8) {
                        if appState.isHotkeyVerificationActive {
                            Button("Stop Verification") {
                                appState.stopHotkeyVerification()
                            }
                            Button("Clear") {
                                appState.clearHotkeyVerification()
                            }
                        } else {
                            Button("Start Verification") {
                                appState.startHotkeyVerification()
                            }
                        }

                        Button("Modifier Keys…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                        }
                    }
                    .buttonStyle(.borderless)

                    switch appState.hotkeyVerificationResult {
                    case .none:
                        EmptyView()
                    case .listening:
                        Text("Listening… press your desired key twice (for default behavior, press Globe/Fn twice).")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    case .success(let message):
                        Text(message)
                            .font(.caption2)
                            .foregroundColor(.green)
                            .fixedSize(horizontal: false, vertical: true)
                    case .issue(let message):
                        Text(message)
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !appState.hotkeyVerificationEvents.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(appState.hotkeyVerificationEvents.suffix(6)) { event in
                                Text("• \(event.summary)")
                                    .font(.caption2.monospaced())
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                            }
                        }
                        .padding(8)
                        .background(Color.gray.opacity(0.08))
                        .cornerRadius(6)
                    }
                }
            }
            
            Section("Language") {
                Picker("Language", selection: $appState.selectedLanguage) {
                    Text("Auto-detect").tag("auto")
                    Divider()
                    Text("English").tag("en")
                    Text("Spanish").tag("es")
                    Text("French").tag("fr")
                    Text("German").tag("de")
                    Text("Italian").tag("it")
                    Text("Portuguese").tag("pt")
                    Text("Dutch").tag("nl")
                    Text("Russian").tag("ru")
                    Text("Japanese").tag("ja")
                    Text("Korean").tag("ko")
                    Text("Chinese").tag("zh")
                    Text("Arabic").tag("ar")
                    Text("Hindi").tag("hi")
                    Text("Turkish").tag("tr")
                    Text("Polish").tag("pl")
                    Text("Swedish").tag("sv")
                    Text("Danish").tag("da")
                    Text("Norwegian").tag("no")
                    Text("Finnish").tag("fi")
                    Text("Czech").tag("cs")
                    Text("Romanian").tag("ro")
                    Text("Hungarian").tag("hu")
                    Text("Greek").tag("el")
                    Text("Hebrew").tag("he")
                    Text("Thai").tag("th")
                    Text("Ukrainian").tag("uk")
                    Text("Vietnamese").tag("vi")
                    Text("Indonesian").tag("id")
                    Text("Malay").tag("ms")
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
        .onAppear {
            appState.refreshAccessibilityPermissionStatus()
            appState.refreshFnKeyConflictStatus()
        }
    }
}

// MARK: - Models

struct ModelsSettingsView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Whisper Models")
                .font(.headline)
            
            HStack(spacing: 4) {
                Text("Models are downloaded from HuggingFace on first use.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Link(destination: URL(string: "https://huggingface.co/argmaxinc/whisperkit-coreml")!) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                }
            }
            
            List {
                ForEach(WhisperService.availableModels) { model in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(model.displayName)
                                    .font(.headline)
                                if model.recommended {
                                    Text("Recommended")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.2))
                                        .cornerRadius(4)
                                }
                                if appState.selectedModel == model.name {
                                    Text("Active")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.green.opacity(0.2))
                                        .cornerRadius(4)
                                }
                                Link(destination: URL(string: "https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/\(model.name)")!) {
                                    Image(systemName: "link")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .help("View on HuggingFace")
                            }
                            
                            HStack(spacing: 12) {
                                Label(ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file), systemImage: "internaldrive")
                                HStack(spacing: 2) {
                                    Image(systemName: "star.fill")
                                    Text("\(model.qualityRating)/5")
                                }
                                HStack(spacing: 2) {
                                    Image(systemName: "bolt.fill")
                                    Text("\(model.speedRating)/5")
                                }
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        if appState.whisperService.isDownloading && appState.selectedModel == model.name {
                            ProgressView()
                                .controlSize(.small)
                        } else if appState.selectedModel == model.name {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.accentColor)
                        } else {
                            Button("Select") {
                                appState.selectedModel = model.name
                                Task {
                                    try? await appState.whisperService.loadModel(model.name)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
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
    @EnvironmentObject var appState: AppState
    @State private var history: [Transcription] = []
    @State private var searchText = ""
    
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
                    appState.clearHistory()
                    history = []
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.originalText)
                            .font(.body)
                            .lineLimit(2)
                        
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
                    .padding(.vertical, 2)
                    .contextMenu {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(item.originalText, forType: .string)
                        }
                    }
                }
            }
        }
        .padding()
        .onAppear {
            history = appState.fetchHistory()
        }
    }
}
