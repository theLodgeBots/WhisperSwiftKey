import Combine
import CoreFoundation
import AppKit
import Foundation

enum RecordingMode: String, CaseIterable {
    case doubleTap = "Double-tap Fn"
    case pushToTalk = "Push to Talk"
}

enum TranscriptionState {
    case idle
    case loadingModel
    case recording
    case processing
    case done(String)
    case error(String)
}

enum FnKeyConflictStatus: Equatable {
    case unknown
    case noConflictDetected
    case possibleSystemConflict(detail: String)
}

enum AccessibilityPermissionStatus: Equatable {
    case unknown
    case granted
    case missing
}

struct HotkeyVerificationEvent: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let summary: String
}

enum HotkeyVerificationResult: Equatable {
    case none
    case listening
    case success(String)
    case issue(String)
}

@MainActor
final class AppState: ObservableObject {
    private enum Keys {
        static let selectedModel = "selectedModel"
        static let selectedLanguage = "selectedLanguage"
        static let autoInsertText = "autoInsertText"
        static let showOverlay = "showOverlay"
        static let agentEnabled = "agentEnabled"
        static let agentName = "agentName"
        static let customDictionary = "customDictionary"
        static let recordingMode = "recordingMode"
        static let transcriptionHistory = "transcriptionHistory"
    }

    let audioService = AudioService()
    let whisperService = WhisperService()
    let textInsertionService = TextInsertionService()
    private let recordingOverlayController = RecordingOverlayController()

    var hotkeyService: HotkeyService?

    @Published var isRecording = false
    @Published var lastTranscription = ""
    @Published var transcriptionState: TranscriptionState = .idle
    @Published var fnKeyConflictStatus: FnKeyConflictStatus = .unknown
    @Published var accessibilityPermissionStatus: AccessibilityPermissionStatus = .unknown
    @Published var hotkeyFeedbackActive = false
    @Published var hotkeyFeedbackCount = 0
    @Published var isHotkeyVerificationActive = false
    @Published var hotkeyVerificationEvents: [HotkeyVerificationEvent] = []
    @Published var hotkeyVerificationResult: HotkeyVerificationResult = .none

    @Published var selectedModel: String {
        didSet { UserDefaults.standard.set(selectedModel, forKey: Keys.selectedModel) }
    }

    @Published var selectedLanguage: String {
        didSet { UserDefaults.standard.set(selectedLanguage, forKey: Keys.selectedLanguage) }
    }

    @Published var autoInsertText: Bool {
        didSet { UserDefaults.standard.set(autoInsertText, forKey: Keys.autoInsertText) }
    }

    @Published var showOverlay: Bool {
        didSet { UserDefaults.standard.set(showOverlay, forKey: Keys.showOverlay) }
    }

    @Published var agentEnabled: Bool {
        didSet { UserDefaults.standard.set(agentEnabled, forKey: Keys.agentEnabled) }
    }

    @Published var agentName: String {
        didSet { UserDefaults.standard.set(agentName, forKey: Keys.agentName) }
    }

    @Published var customDictionary: [String] {
        didSet { UserDefaults.standard.set(customDictionary, forKey: Keys.customDictionary) }
    }

    @Published var recordingMode: RecordingMode {
        didSet {
            UserDefaults.standard.set(recordingMode.rawValue, forKey: Keys.recordingMode)
            applyHotkeyConfiguration()
            refreshFnKeyConflictStatus()
        }
    }

    private var history: [Transcription]
    private var cancellables = Set<AnyCancellable>()
    private var lastDoubleTapHotkeyTriggerAt: Date?
    private var lastObservedDoubleTapConflictDetail: String?
    private var lastObservedDoubleTapConflictAt: Date?
    private var hotkeyFeedbackGeneration = 0
    private var hotkeyVerificationLastRawFlags: UInt64?
    private var hotkeyVerificationLastSystemDefinedPulseAt: Date?
    private var hotkeyVerificationPressHistory: [(timestamp: Date, keyCode: Int64, label: String)] = []
    private var hotkeyVerificationTimeoutTask: Task<Void, Never>?
    private var liveDictationPollingTask: Task<Void, Never>?
    private var liveDictationTranscribeTask: Task<Void, Never>?
    private var liveDictationSessionID = UUID()
    private var liveDictationTranscribeInFlight = false
    private var liveDictationLastRequestedSampleCount = 0
    private var liveDictationInsertedText = ""
    private var liveDictationLastPartialText = ""
    private var liveDictationHasSeenSpeechEnergy = false
    private var isUsingWhisperRealtimeStreaming = false

    var runtimeBundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "(missing bundle identifier)"
    }

    var runtimeAppPath: String {
        Bundle.main.bundleURL.path
    }

    init() {
        let defaults = UserDefaults.standard

        self.selectedModel = defaults.string(forKey: Keys.selectedModel)
            ?? WhisperService.availableModels.first(where: \.recommended)?.name
            ?? "openai_whisper-base"
        self.selectedLanguage = defaults.string(forKey: Keys.selectedLanguage) ?? "auto"
        self.autoInsertText = defaults.object(forKey: Keys.autoInsertText) as? Bool ?? true
        self.showOverlay = defaults.object(forKey: Keys.showOverlay) as? Bool ?? true
        self.agentEnabled = defaults.bool(forKey: Keys.agentEnabled)
        self.agentName = defaults.string(forKey: Keys.agentName) ?? "Agent"
        self.customDictionary = defaults.stringArray(forKey: Keys.customDictionary) ?? []
        if let storedMode = defaults.string(forKey: Keys.recordingMode),
           let mode = RecordingMode(rawValue: storedMode) {
            self.recordingMode = mode
        } else {
            self.recordingMode = .doubleTap
        }
        self.history = Self.loadHistory()

        wireServices()
        refreshAccessibilityPermissionStatus()
        refreshFnKeyConflictStatus()

        if !selectedModel.isEmpty {
            Task {
                try? await whisperService.loadModel(selectedModel)
            }
        }
    }

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func sleepModel() {
        whisperService.sleepModel()
    }

    func wakeModel() {
        guard whisperService.isModelAsleep else { return }
        Task {
            try? await whisperService.wakeModel()
        }
    }

    func startRecording() {
        guard !isRecording else { return }

        if whisperService.isModelAsleep {
            transcriptionState = .loadingModel
            let sessionID = UUID()
            liveDictationSessionID = sessionID
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.whisperService.wakeModel()
                } catch {
                    await MainActor.run {
                        guard self.liveDictationSessionID == sessionID else { return }
                        self.transcriptionState = .error("Failed to wake model: \(error.localizedDescription)")
                    }
                    return
                }
                await MainActor.run {
                    guard self.liveDictationSessionID == sessionID else { return }
                    self.proceedWithRecording()
                }
            }
            return
        }

        proceedWithRecording()
    }

    private func proceedWithRecording() {
        guard !isRecording else { return }
        beginLiveDictationSession()
        isRecording = true
        transcriptionState = .recording

        let sessionID = liveDictationSessionID
        let language = selectedLanguage == "auto" ? nil : selectedLanguage
        let prompt = customDictionary.isEmpty ? nil : customDictionary.joined(separator: ", ")

        guard whisperService.isModelLoaded else {
            startBufferedRecordingFallback(sessionID: sessionID)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.whisperService.startRealtimeTranscription(language: language, prompt: prompt) { [weak self] text in
                    self?.handleRealtimeStreamingPartialText(text, sessionID: sessionID)
                }
                await MainActor.run {
                    guard self.liveDictationSessionID == sessionID, self.isRecording else { return }
                    self.isUsingWhisperRealtimeStreaming = true
                    print("[AppState] Using WhisperKit realtime streaming dictation")
                }
            } catch {
                await MainActor.run {
                    guard self.liveDictationSessionID == sessionID, self.isRecording else { return }
                    print("[AppState] Realtime streaming unavailable, falling back to buffered dictation: \(error.localizedDescription)")
                    self.startBufferedRecordingFallback(sessionID: sessionID)
                }
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        let insertedPrefix = liveDictationInsertedText
        let usedRealtimeStreaming = isUsingWhisperRealtimeStreaming
        endLiveDictationSession()
        let language = selectedLanguage == "auto" ? nil : selectedLanguage
        let prompt = customDictionary.isEmpty ? nil : customDictionary.joined(separator: ", ")

        if usedRealtimeStreaming {
            transcriptionState = .processing
            Task { [weak self] in
                guard let self else { return }
                let samples = await self.whisperService.stopRealtimeTranscriptionAndCaptureSamples()
                await MainActor.run {
                    self.transcribeCapturedSamples(
                        samples,
                        language: language,
                        prompt: prompt,
                        insertedPrefix: insertedPrefix
                    )
                }
            }
            return
        }

        transcribeCapturedSamples(
            audioService.stopRecording(),
            language: language,
            prompt: prompt,
            insertedPrefix: insertedPrefix
        )
    }

    func fetchHistory() -> [Transcription] {
        history.sorted { $0.timestamp > $1.timestamp }
    }

    func clearHistory() {
        history = []
        persistHistory()
    }

    private func handleTranscriptionResult(
        text: String,
        durationSeconds: Double,
        language: String?,
        insertedPrefix: String = ""
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            transcriptionState = .error("No speech detected")
            return
        }

        lastTranscription = trimmed
        transcriptionState = .done(trimmed)

        if autoInsertText {
            applyDictationInsertion(transcript: trimmed, previouslyInsertedText: insertedPrefix, finalResult: true)
        }

        history.insert(
            Transcription(
                originalText: trimmed,
                durationSeconds: durationSeconds,
                language: language
            ),
            at: 0
        )
        if history.count > 500 {
            history = Array(history.prefix(500))
        }
        persistHistory()
    }

    private func transcribeCapturedSamples(
        _ samples: [Float]?,
        language: String?,
        prompt: String?,
        insertedPrefix: String
    ) {
        guard let samples else {
            transcriptionState = .error("No audio captured")
            return
        }

        transcriptionState = .processing
        let durationSeconds = Double(samples.count) / 16_000.0

        Task {
            do {
                let text = try await whisperService.transcribe(samples: samples, language: language, prompt: prompt)
                await MainActor.run {
                    handleTranscriptionResult(
                        text: text,
                        durationSeconds: durationSeconds,
                        language: language,
                        insertedPrefix: insertedPrefix
                    )
                }
            } catch {
                await MainActor.run {
                    transcriptionState = .error(error.localizedDescription)
                }
            }
        }
    }

    private func beginLiveDictationSession() {
        liveDictationPollingTask?.cancel()
        liveDictationTranscribeTask?.cancel()
        liveDictationSessionID = UUID()
        liveDictationTranscribeInFlight = false
        liveDictationLastRequestedSampleCount = 0
        liveDictationInsertedText = ""
        liveDictationLastPartialText = ""
        liveDictationHasSeenSpeechEnergy = false
        isUsingWhisperRealtimeStreaming = false
    }

    private func startBufferedRecordingFallback(sessionID: UUID) {
        guard liveDictationSessionID == sessionID, isRecording else { return }
        guard !isUsingWhisperRealtimeStreaming else { return }
        print("[AppState] Using buffered dictation fallback (periodic batch transcription)")
        if !audioService.recordingActive {
            audioService.startRecording()
        }
        startLiveDictationLoopIfNeeded()
    }

    private func handleRealtimeStreamingPartialText(_ text: String, sessionID: UUID) {
        guard sessionID == liveDictationSessionID else { return }
        guard isRecording else { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        liveDictationHasSeenSpeechEnergy = true
        liveDictationLastPartialText = trimmed
        lastTranscription = trimmed

        if autoInsertText {
            liveDictationInsertedText = applyDictationInsertion(
                transcript: trimmed,
                previouslyInsertedText: liveDictationInsertedText,
                finalResult: false
            )
        }
    }

    private func endLiveDictationSession() {
        liveDictationPollingTask?.cancel()
        liveDictationPollingTask = nil
        liveDictationTranscribeTask?.cancel()
        liveDictationTranscribeTask = nil
        liveDictationTranscribeInFlight = false
        liveDictationSessionID = UUID()
    }

    private func startLiveDictationLoopIfNeeded() {
        guard whisperService.isModelLoaded else { return }
        let sessionID = liveDictationSessionID
        liveDictationPollingTask?.cancel()
        liveDictationPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                await self?.runLiveDictationTick(sessionID: sessionID)
            }
        }
    }

    private func runLiveDictationTick(sessionID: UUID) async {
        guard isRecording else { return }
        guard sessionID == liveDictationSessionID else { return }
        guard !liveDictationTranscribeInFlight else { return }
        guard whisperService.isModelLoaded else { return }

        let currentSampleCount = audioService.currentSampleCount
        let minSamples = 16_000          // wait for ~1s
        let minNewSamples = 9_600        // then require ~0.6s growth between partial requests
        guard currentSampleCount >= minSamples else { return }
        guard currentSampleCount - liveDictationLastRequestedSampleCount >= minNewSamples else { return }

        let samples = audioService.currentSamplesSnapshot()
        guard !samples.isEmpty else { return }

        let recentWindowSamples = min(samples.count, 12_800) // ~0.8s
        let recentRMS = rmsEnergy(samples.suffix(recentWindowSamples))
        let speechRMSThreshold: Float = 0.006
        if !liveDictationHasSeenSpeechEnergy {
            guard recentRMS >= speechRMSThreshold else {
                return
            }
            liveDictationHasSeenSpeechEnergy = true
        }

        liveDictationTranscribeInFlight = true
        liveDictationLastRequestedSampleCount = samples.count

        let language = selectedLanguage == "auto" ? nil : selectedLanguage
        let prompt = customDictionary.isEmpty ? nil : customDictionary.joined(separator: ", ")

        liveDictationTranscribeTask?.cancel()
        liveDictationTranscribeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await self.whisperService.transcribe(samples: samples, language: language, prompt: prompt)
                await MainActor.run {
                    self.handleLiveDictationPartialResult(
                        text: text,
                        sessionID: sessionID,
                        sampleCount: samples.count
                    )
                }
            } catch {
                await MainActor.run {
                    self.handleLiveDictationPartialFailure(error: error, sessionID: sessionID)
                }
            }
        }
    }

    private func handleLiveDictationPartialResult(text: String, sessionID: UUID, sampleCount: Int) {
        guard sessionID == liveDictationSessionID else { return }
        liveDictationTranscribeInFlight = false
        liveDictationLastRequestedSampleCount = max(liveDictationLastRequestedSampleCount, sampleCount)

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        liveDictationLastPartialText = trimmed
        lastTranscription = trimmed

        if autoInsertText {
            liveDictationInsertedText = applyDictationInsertion(
                transcript: trimmed,
                previouslyInsertedText: liveDictationInsertedText,
                finalResult: false
            )
        }
    }

    private func handleLiveDictationPartialFailure(error: Error, sessionID: UUID) {
        guard sessionID == liveDictationSessionID else { return }
        liveDictationTranscribeInFlight = false
        if isRecording {
            print("[AppState] Live dictation partial failed: \(error.localizedDescription)")
        }
    }

    private func liveDictationDeltaToAppend(fullTranscript: String, insertedPrefix: String) -> String? {
        guard !fullTranscript.isEmpty else { return nil }
        guard !insertedPrefix.isEmpty else { return fullTranscript }
        guard fullTranscript.count >= insertedPrefix.count else { return nil }
        guard fullTranscript.hasPrefix(insertedPrefix) else { return nil }
        return String(fullTranscript.dropFirst(insertedPrefix.count))
    }

    private func rmsEnergy<S: Sequence>(_ samples: S) -> Float where S.Element == Float {
        var sumSquares: Float = 0
        var count: Int = 0
        for sample in samples {
            sumSquares += sample * sample
            count += 1
        }
        guard count > 0 else { return 0 }
        return sqrt(sumSquares / Float(count))
    }

    @discardableResult
    private func applyDictationInsertion(
        transcript: String,
        previouslyInsertedText: String,
        finalResult: Bool
    ) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return previouslyInsertedText }

        if previouslyInsertedText.isEmpty {
            if finalResult {
                textInsertionService.insertText(trimmed)
            } else {
                textInsertionService.insertIncrementalText(trimmed)
            }
            return trimmed
        }

        if trimmed == previouslyInsertedText {
            return previouslyInsertedText
        }

        if let delta = liveDictationDeltaToAppend(fullTranscript: trimmed, insertedPrefix: previouslyInsertedText),
           !delta.isEmpty {
            textInsertionService.insertIncrementalText(delta)
            return previouslyInsertedText + delta
        }

        // Whisper partials may revise earlier words. Treat current insertion as provisional and replace it.
        textInsertionService.replaceRecentlyInsertedText(previouslyInsertedText, with: trimmed)
        return trimmed
    }

    private func ensureHotkeyService() {
        guard hotkeyService == nil else {
            applyHotkeyConfiguration()
            return
        }

        hotkeyService = HotkeyService { [weak self] in
            self?.handleDoubleTapHotkeyTrigger()
        }
        hotkeyService?.onInputObservation = { [weak self] observation in
            DispatchQueue.main.async {
                self?.handleHotkeyInputObservation(observation)
            }
        }
        applyHotkeyConfiguration()
    }

    private func applyHotkeyConfiguration() {
        hotkeyService?.mode = recordingMode == .pushToTalk ? .pushToTalk : .doubleTap
        hotkeyService?.onPushStart = { [weak self] in self?.startRecording() }
        hotkeyService?.onPushStop = { [weak self] in self?.stopRecording() }
        hotkeyService?.onInputObservation = { [weak self] observation in
            DispatchQueue.main.async {
                self?.handleHotkeyInputObservation(observation)
            }
        }

        if recordingMode != .doubleTap {
            lastDoubleTapHotkeyTriggerAt = nil
            lastObservedDoubleTapConflictDetail = nil
            lastObservedDoubleTapConflictAt = nil
        }
    }

    private func wireServices() {
        whisperService.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        Publishers.CombineLatest($transcriptionState, $showOverlay)
            .sink { [weak self] state, showOverlay in
                self?.updateRecordingOverlay(state: state, showOverlay: showOverlay)
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] notification in
                self?.handleActivatedApplication(notification)
            }
            .store(in: &cancellables)
    }

    private func updateRecordingOverlay(state: TranscriptionState, showOverlay: Bool) {
        guard showOverlay else {
            recordingOverlayController.dismiss()
            return
        }

        switch state {
        case .recording, .loadingModel:
            recordingOverlayController.show(state: state, modelName: whisperService.currentModelName)
        default:
            recordingOverlayController.dismiss()
        }
    }

    func refreshFnKeyConflictStatus() {
        let isDoubleTapMode = recordingMode == .doubleTap

        if let observedAt = lastObservedDoubleTapConflictAt,
           let detail = lastObservedDoubleTapConflictDetail,
           isDoubleTapMode,
           Date().timeIntervalSince(observedAt) < 3600 {
            fnKeyConflictStatus = .possibleSystemConflict(detail: detail)
            return
        }

        guard let usageType = readAppleFnUsageType() else {
            fnKeyConflictStatus = .unknown
            return
        }

        switch usageType {
        case 0:
            fnKeyConflictStatus = .noConflictDetected
        case 1:
            fnKeyConflictStatus = .possibleSystemConflict(
                detail: "Fn/Globe is set to Change Input Source (AppleFnUsageType=1), which conflicts with WhisperSwiftKey hotkeys."
            )
        case 2:
            fnKeyConflictStatus = .possibleSystemConflict(
                detail: "Fn/Globe is set to Show Emoji & Symbols (AppleFnUsageType=2). Double-tap Fn/Globe will open the emoji picker/search and conflict with dictation."
            )
        case 3:
            fnKeyConflictStatus = .possibleSystemConflict(
                detail: "Fn/Globe is set to Start Dictation (AppleFnUsageType=3), which conflicts with WhisperSwiftKey."
            )
        default:
            fnKeyConflictStatus = .possibleSystemConflict(
                detail: "macOS is using Fn/Globe for a system shortcut (AppleFnUsageType=\(usageType))."
            )
        }
    }

    func requestAccessibilityPermission() {
        HotkeyService.requestAccessibilityPermissionPrompt()
        refreshAccessibilityPermissionStatus()
    }

    func refreshAccessibilityPermissionStatus() {
        let granted = HotkeyService.hasAccessibilityPermission()
        accessibilityPermissionStatus = granted ? .granted : .missing
        if granted {
            ensureHotkeyService()
            hotkeyService?.reinitializeEventTapIfNeeded()
        }
    }

    private func persistHistory() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(history) {
            UserDefaults.standard.set(data, forKey: Keys.transcriptionHistory)
        }
    }

    private static func loadHistory() -> [Transcription] {
        guard let data = UserDefaults.standard.data(forKey: Keys.transcriptionHistory) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Transcription].self, from: data)) ?? []
    }

    private func recordDoubleTapHotkeyTrigger() {
        guard recordingMode == .doubleTap else { return }
        lastDoubleTapHotkeyTriggerAt = Date()
    }

    private func handleDoubleTapHotkeyTrigger() {
        recordDoubleTapHotkeyTrigger()
        triggerHotkeyFeedback()
        toggleRecording()
    }

    private func triggerHotkeyFeedback() {
        hotkeyFeedbackGeneration += 1
        let generation = hotkeyFeedbackGeneration
        hotkeyFeedbackActive = true
        hotkeyFeedbackCount += 1
        NSSound.beep()

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            await MainActor.run {
                guard let self else { return }
                guard self.hotkeyFeedbackGeneration == generation else { return }
                self.hotkeyFeedbackActive = false
            }
        }
    }

    func startHotkeyVerification() {
        hotkeyVerificationTimeoutTask?.cancel()
        isHotkeyVerificationActive = true
        hotkeyVerificationEvents = []
        hotkeyVerificationResult = .listening
        hotkeyVerificationLastRawFlags = nil
        hotkeyVerificationLastSystemDefinedPulseAt = nil
        hotkeyVerificationPressHistory = []

        hotkeyVerificationTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            await MainActor.run {
                guard let self else { return }
                guard self.isHotkeyVerificationActive else { return }
                guard self.hotkeyVerificationResult == .listening else { return }
                guard self.hotkeyVerificationEvents.isEmpty else { return }
                self.hotkeyVerificationResult = .issue(
                    "No key event was observed when you pressed Globe/Fn. macOS may be swallowing the key for a system shortcut, or the key may be remapped (for example to Control). Try pressing Globe/Fn again, then check the Fn/Globe conflict warning above or Keyboard Modifier Keys."
                )
            }
        }
    }

    func stopHotkeyVerification() {
        hotkeyVerificationTimeoutTask?.cancel()
        hotkeyVerificationTimeoutTask = nil
        isHotkeyVerificationActive = false
        if hotkeyVerificationResult == .listening {
            hotkeyVerificationResult = .none
        }
    }

    func clearHotkeyVerification() {
        hotkeyVerificationEvents = []
        hotkeyVerificationResult = isHotkeyVerificationActive ? .listening : .none
        hotkeyVerificationLastRawFlags = nil
        hotkeyVerificationLastSystemDefinedPulseAt = nil
        hotkeyVerificationPressHistory = []
    }

    private func handleHotkeyInputObservation(_ observation: HotkeyInputObservation) {
        guard isHotkeyVerificationActive else { return }

        let summary = summarizeHotkeyObservation(observation)
        appendHotkeyVerificationEvent(summary)

        guard let press = hotkeyPressCandidate(from: observation) else {
            return
        }

        hotkeyVerificationPressHistory.append(press)
        if hotkeyVerificationPressHistory.count > 6 {
            hotkeyVerificationPressHistory = Array(hotkeyVerificationPressHistory.suffix(6))
        }

        guard hotkeyVerificationPressHistory.count >= 2 else { return }
        let previous = hotkeyVerificationPressHistory[hotkeyVerificationPressHistory.count - 2]
        let current = hotkeyVerificationPressHistory[hotkeyVerificationPressHistory.count - 1]
        guard previous.keyCode == current.keyCode else { return }
        guard current.timestamp.timeIntervalSince(previous.timestamp) <= 1.2 else { return }

        hotkeyVerificationResult = verificationResult(for: current)
    }

    private func summarizeHotkeyObservation(_ observation: HotkeyInputObservation) -> String {
        let typeName: String
        switch observation.typeRawValue {
        case UInt32(CGEventType.flagsChanged.rawValue): typeName = "flagsChanged"
        case UInt32(CGEventType.keyDown.rawValue): typeName = "keyDown"
        case UInt32(CGEventType.keyUp.rawValue): typeName = "keyUp"
        case 14: typeName = "systemDefined"
        default: typeName = "type=\(observation.typeRawValue)"
        }

        let label = keyLabel(for: observation.keyCode)
        if observation.typeRawValue == 14 && observation.keyCode == 0 {
            return "\(typeName) • Globe/Fn (system event) • keyCode 0 • fnFlag \(observation.fnFlag ? "on" : "off")"
        }
        return "\(typeName) • \(label) • keyCode \(observation.keyCode) • fnFlag \(observation.fnFlag ? "on" : "off")"
    }

    private func appendHotkeyVerificationEvent(_ summary: String) {
        hotkeyVerificationEvents.append(HotkeyVerificationEvent(timestamp: Date(), summary: summary))
        if hotkeyVerificationEvents.count > 12 {
            hotkeyVerificationEvents = Array(hotkeyVerificationEvents.suffix(12))
        }
    }

    private func hotkeyPressCandidate(from observation: HotkeyInputObservation) -> (timestamp: Date, keyCode: Int64, label: String)? {
        let flagsChangedRaw = UInt32(CGEventType.flagsChanged.rawValue)
        let keyDownRaw = UInt32(CGEventType.keyDown.rawValue)
        let systemDefinedRaw: UInt32 = 14

        if observation.typeRawValue == systemDefinedRaw,
           observation.keyCode == 0,
           observation.flagsRawValue == 0 {
            if let lastPulse = hotkeyVerificationLastSystemDefinedPulseAt,
               observation.timestamp.timeIntervalSince(lastPulse) < 0.18 {
                return nil
            }
            hotkeyVerificationLastSystemDefinedPulseAt = observation.timestamp
            return (observation.timestamp, 63, "Globe/Fn (system event)")
        }

        if observation.typeRawValue == keyDownRaw {
            let label = keyLabel(for: observation.keyCode)
            return (observation.timestamp, observation.keyCode, label)
        }

        guard observation.typeRawValue == flagsChangedRaw else {
            return nil
        }

        let rawFlags = observation.flagsRawValue
        let previousFlags = hotkeyVerificationLastRawFlags
        hotkeyVerificationLastRawFlags = rawFlags

        guard let isPressed = modifierPressedState(for: observation.keyCode, flagsRawValue: rawFlags, fnFlag: observation.fnFlag) else {
            return nil
        }
        guard isPressed else { return nil }

        if let previousFlags {
            if previousFlags == rawFlags {
                return nil
            }
        }

        let label = keyLabel(for: observation.keyCode)
        return (observation.timestamp, observation.keyCode, label)
    }

    private func verificationResult(for press: (timestamp: Date, keyCode: Int64, label: String)) -> HotkeyVerificationResult {
        switch press.keyCode {
        case 63:
            return .success("Detected a double Globe/Fn press. This is the correct key for WhisperSwiftKey.")
        case 59, 62:
            return .issue("Detected a double Control press (\(press.label)). Your Globe/Fn key appears to be remapped to Control in macOS Keyboard Modifier Keys.")
        case 55, 54:
            return .issue("Detected a double Command press (\(press.label)). WhisperSwiftKey expected Globe/Fn. Check macOS Keyboard Modifier Keys.")
        case 58, 61:
            return .issue("Detected a double Option press (\(press.label)). WhisperSwiftKey expected Globe/Fn. Check macOS Keyboard Modifier Keys.")
        case 56, 60:
            return .issue("Detected a double Shift press (\(press.label)). WhisperSwiftKey expected Globe/Fn. Check macOS Keyboard Modifier Keys.")
        default:
            return .issue("Detected a double \(press.label) press (keyCode \(press.keyCode)). WhisperSwiftKey expected Globe/Fn.")
        }
    }

    private func keyLabel(for keyCode: Int64) -> String {
        switch keyCode {
        case 63: return "Globe/Fn"
        case 59: return "Left Control"
        case 62: return "Right Control"
        case 55: return "Left Command"
        case 54: return "Right Command"
        case 58: return "Left Option"
        case 61: return "Right Option"
        case 56: return "Left Shift"
        case 60: return "Right Shift"
        case 57: return "Caps Lock"
        case 0: return "System Event"
        default: return "Key"
        }
    }

    private func modifierPressedState(for keyCode: Int64, flagsRawValue: UInt64, fnFlag: Bool) -> Bool? {
        let flags = CGEventFlags(rawValue: flagsRawValue)
        switch keyCode {
        case 59, 62:
            return flags.contains(.maskControl)
        case 55, 54:
            return flags.contains(.maskCommand)
        case 58, 61:
            return flags.contains(.maskAlternate)
        case 56, 60:
            return flags.contains(.maskShift)
        case 63:
            return fnFlag
        default:
            return nil
        }
    }

    private func handleActivatedApplication(_ notification: Notification) {
        guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else {
            return
        }

        let bundleIdentifier = app.bundleIdentifier ?? ""
        let localizedName = app.localizedName ?? "system panel"

        let isCharacterViewer = Self.isCharacterViewerApplication(bundleIdentifier: bundleIdentifier, localizedName: localizedName)
        guard isCharacterViewer else {
            return
        }

        if isHotkeyVerificationActive {
            appendHotkeyVerificationEvent("Detected Emoji & Symbols opening (\(localizedName)). Globe/Fn appears to be handled by macOS before WhisperSwiftKey can receive it.")
            if hotkeyVerificationResult == .listening {
                hotkeyVerificationResult = .issue(
                    "Emoji & Symbols opened when you pressed Globe/Fn. macOS is handling the key before WhisperSwiftKey sees it. Change System Settings > Keyboard > Fn/Globe, or choose a different hotkey behavior."
                )
            }
        }

        guard recordingMode == .doubleTap else { return }
        guard let triggerAt = lastDoubleTapHotkeyTriggerAt else { return }
        guard Date().timeIntervalSince(triggerAt) <= 1.2 else { return }

        lastDoubleTapHotkeyTriggerAt = nil

        let detail = "Detected Emoji & Symbols opening (\(localizedName), \(bundleIdentifier.isEmpty ? "no bundle id" : bundleIdentifier)) after double-tap Fn/Globe. This macOS shortcut conflicts with WhisperSwiftKey. Change System Settings > Keyboard > Fn/Globe or switch WhisperSwiftKey to Push to Talk."
        lastObservedDoubleTapConflictDetail = detail
        lastObservedDoubleTapConflictAt = Date()
        fnKeyConflictStatus = .possibleSystemConflict(detail: detail)

        if isRecording {
            if isUsingWhisperRealtimeStreaming {
                Task { [weak self] in
                    await self?.whisperService.stopRealtimeTranscription()
                }
            } else {
                _ = audioService.stopRecording()
            }
            isRecording = false
            transcriptionState = .error("Fn/Globe opened Emoji & Symbols. Change the Keyboard > Fn/Globe shortcut or use Push to Talk.")
        }
    }

    private static func isCharacterViewerApplication(bundleIdentifier: String, localizedName: String) -> Bool {
        if bundleIdentifier == "com.apple.CharacterPaletteIM" || bundleIdentifier == "com.apple.CharacterPicker" {
            return true
        }

        let lowerName = localizedName.lowercased()
        if lowerName.contains("emoji") || lowerName.contains("character") {
            return true
        }

        return false
    }

    private func readAppleFnUsageType() -> Int? {
        let key = "AppleFnUsageType"
        let domainName = "com.apple.HIToolbox"

        if let domain = UserDefaults.standard.persistentDomain(forName: domainName),
           let value = Self.intValue(from: domain[key]) {
            return value
        }

        if let suite = UserDefaults(suiteName: domainName),
           let value = Self.intValue(from: suite.object(forKey: key)) {
            return value
        }

        let cfKey = key as CFString
        let cfDomain = domainName as CFString
        let scopes: [(CFString, CFString)] = [
            (kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
            (kCFPreferencesCurrentUser, kCFPreferencesCurrentHost),
            (kCFPreferencesAnyUser, kCFPreferencesCurrentHost)
        ]

        for (user, host) in scopes {
            if let raw = CFPreferencesCopyValue(cfKey, cfDomain, user, host),
               let value = Self.intValue(from: raw) {
                return value
            }
        }

        return nil
    }

    private static func intValue(from raw: Any?) -> Int? {
        if let int = raw as? Int {
            return int
        }
        if let number = raw as? NSNumber {
            return number.intValue
        }
        if let string = raw as? String {
            return Int(string)
        }
        return nil
    }
}
