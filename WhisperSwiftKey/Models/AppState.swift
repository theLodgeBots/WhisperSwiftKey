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

/// Allows exactly one final result to mutate the document for each recording.
/// Repeated async callbacks for the same session are ignored after the first one.
struct DictationFinalizationGate {
    private(set) var pendingSessionID: UUID?

    var hasPendingSession: Bool { pendingSessionID != nil }

    mutating func begin(sessionID: UUID) -> Bool {
        guard pendingSessionID == nil else { return false }
        pendingSessionID = sessionID
        return true
    }

    mutating func consume(sessionID: UUID) -> Bool {
        guard pendingSessionID == sessionID else { return false }
        pendingSessionID = nil
        return true
    }
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
    let systemAudioCaptureService = SystemAudioCaptureService()
    let textInsertionService: any TextInsertionServing
    private let recordingOverlayController = RecordingOverlayController()
    private let modelLoadingOverlayController = ModelLoadingOverlayController()

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

    @Published private(set) var history: [Transcription]
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
    private var realtimeStartTask: Task<Void, Never>?
    private var liveDictationSessionID = UUID()
    private var liveDictationTranscribeInFlight = false
    private var liveDictationLastRequestedSampleCount = 0
    private var liveDictationInsertedText = ""
    private var liveDictationLastPartialText = ""
    private var liveDictationHasSeenSpeechEnergy = false
    private var liveDictationTargetApplicationPID: pid_t?
    private var liveDictationSupportsProvisionalInsertion = true
    private var isUsingWhisperRealtimeStreaming = false
    private var isPreparingWhisperRealtime = false
    private var shouldStopPreparingWhisperRealtime = false
    private var finalizationGate = DictationFinalizationGate()

    @Published var isSystemAudioTranscribing = false
    @Published private(set) var isSystemAudioFinishing = false
    @Published var systemAudioTranscript = ""
    @Published var systemAudioStatusMessage: String?
    private var systemAudioSessionID = UUID()
    private var systemAudioLoopTask: Task<Void, Never>?
    private var systemAudioCommittedText = ""
    private var systemAudioTranscribeInFlight = false
    private var systemAudioLastLiveSampleCount = 0
    private var systemAudioSessionStartedAt: Date?

    var runtimeBundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "(missing bundle identifier)"
    }

    var runtimeAppPath: String {
        Bundle.main.bundleURL.path
    }

    init(
        textInsertionService: any TextInsertionServing = TextInsertionService(),
        defaults: UserDefaults = .standard
    ) {
        self.textInsertionService = textInsertionService

        let storedModel = defaults.string(forKey: Keys.selectedModel)
            ?? WhisperService.availableModels.first(where: \.recommended)?.name
            ?? "openai_whisper-base"
        self.selectedModel = WhisperService.currentModelName(for: storedModel)
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

        if !selectedModel.isEmpty,
           ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
           ProcessInfo.processInfo.environment["WSK_AX_SMOKE_TEST"] != "1" {
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
        guard HotkeyService.hasAccessibilityPermission() else {
            accessibilityPermissionStatus = .missing
            HotkeyService.requestAccessibilityPermissionPrompt()
            transcriptionState = .error(
                "Enable Accessibility access for live dictation at the text cursor"
            )
            return
        }
        guard !finalizationGate.hasPendingSession else {
            print("[AppState] Ignoring start while the previous dictation is finalizing")
            return
        }
        guard !isSystemAudioTranscribing, !isSystemAudioFinishing else {
            transcriptionState = .error("Stop system-audio transcription before dictating")
            return
        }
        // Don't start a new load if one is already in progress
        switch transcriptionState {
        case .loadingModel, .processing:
            return
        default:
            break
        }
        print("[AppState] startRecording() called, modelLoaded=\(whisperService.isModelLoaded)")

        if !whisperService.isModelLoaded {
            transcriptionState = .loadingModel
            let sessionID = UUID()
            liveDictationSessionID = sessionID
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.whisperService.ensureModelLoaded(self.selectedModel)
                } catch {
                    await MainActor.run {
                        guard self.liveDictationSessionID == sessionID else { return }
                        self.transcriptionState = .error("Failed to load model: \(error.localizedDescription)")
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

        // AudioStreamTranscriber starts capture from its own long-running task. Keep
        // explicit preparation state so a quick key release cannot fall through to an
        // unrelated, empty AudioService capture.
        isPreparingWhisperRealtime = true
        realtimeStartTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.whisperService.startRealtimeTranscription(language: language, prompt: prompt) { [weak self] (confirmedText: String, displayText: String) in
                    self?.handleRealtimeStreamingPartialText(confirmedText: confirmedText, displayText: displayText, sessionID: sessionID)
                }
                await MainActor.run {
                    guard self.liveDictationSessionID == sessionID else {
                        Task { await self.whisperService.stopRealtimeTranscription() }
                        return
                    }
                    self.isPreparingWhisperRealtime = false
                    self.isUsingWhisperRealtimeStreaming = true
                    self.realtimeStartTask = nil
                    print("[AppState] Using WhisperKit realtime streaming dictation")
                    if self.shouldStopPreparingWhisperRealtime {
                        self.shouldStopPreparingWhisperRealtime = false
                        self.finishRealtimeRecording()
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.liveDictationSessionID == sessionID else { return }
                    self.isPreparingWhisperRealtime = false
                    self.realtimeStartTask = nil
                    if self.shouldStopPreparingWhisperRealtime {
                        self.shouldStopPreparingWhisperRealtime = false
                        self.endLiveDictationSession()
                        self.textInsertionService.cancelProvisionalInsertionSession()
                        self.transcriptionState = .error("Could not start microphone capture: \(error.localizedDescription)")
                        return
                    }
                    guard self.isRecording else { return }
                    print("[AppState] Realtime streaming unavailable, falling back to buffered dictation: \(error.localizedDescription)")
                    self.startBufferedRecordingFallback(sessionID: sessionID)
                }
            }
        }
    }

    func stopRecording() {
        guard isRecording || isPreparingWhisperRealtime else { return }
        isRecording = false

        if isPreparingWhisperRealtime {
            shouldStopPreparingWhisperRealtime = true
            transcriptionState = .processing
            return
        }

        if isUsingWhisperRealtimeStreaming {
            finishRealtimeRecording()
            return
        }

        let finalizationSessionID = liveDictationSessionID
        guard finalizationGate.begin(sessionID: finalizationSessionID) else { return }
        let language = selectedLanguage == "auto" ? nil : selectedLanguage
        let prompt = customDictionary.isEmpty ? nil : customDictionary.joined(separator: ", ")
        endLiveDictationSession()
        transcribeCapturedSamples(
            audioService.stopRecording(),
            language: language,
            prompt: prompt,
            finalizationSessionID: finalizationSessionID
        )
    }

    private func finishRealtimeRecording() {
        let finalizationSessionID = liveDictationSessionID
        guard finalizationGate.begin(sessionID: finalizationSessionID) else {
            print("[AppState] Ignoring duplicate realtime finalization request")
            return
        }
        let language = selectedLanguage == "auto" ? nil : selectedLanguage
        let prompt = customDictionary.isEmpty ? nil : customDictionary.joined(separator: ", ")
        isUsingWhisperRealtimeStreaming = false
        endLiveDictationSession()
        transcriptionState = .processing

        Task { [weak self] in
            guard let self else { return }
            let samples = await self.whisperService.stopRealtimeTranscriptionAndCaptureSamples()
            await MainActor.run {
                self.transcribeCapturedSamples(
                    samples,
                    language: language,
                    prompt: prompt,
                    finalizationSessionID: finalizationSessionID
                )
            }
        }
    }

    func fetchHistory() -> [Transcription] {
        history.sorted { $0.timestamp > $1.timestamp }
    }

    /// The most recent dictations for the menu-bar quick-copy list.
    func recentDictations(limit: Int = 5) -> [Transcription] {
        Array(fetchHistory().prefix(limit))
    }

    func clearHistory() {
        history = []
        persistHistory()
    }

    private func saveToHistory(text: String, durationSeconds: Double, language: String?) {
        history.insert(
            Transcription(
                originalText: text,
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

    // MARK: - System audio transcription

    func toggleSystemAudioTranscription() {
        if isSystemAudioTranscribing {
            stopSystemAudioTranscription()
        } else {
            startSystemAudioTranscription()
        }
    }

    /// Transcribes everything the system is playing (videos, calls, music) via
    /// a ScreenCaptureKit audio tap. The transcript accumulates in
    /// `systemAudioTranscript` and is saved to history when stopped.
    func startSystemAudioTranscription() {
        guard !isSystemAudioTranscribing, !isSystemAudioFinishing else { return }
        guard !isRecording, !isPreparingWhisperRealtime else {
            systemAudioStatusMessage = "Stop dictation before transcribing system audio."
            return
        }
        guard !finalizationGate.hasPendingSession else {
            systemAudioStatusMessage = "Wait for the current dictation to finish before transcribing system audio."
            return
        }

        let sessionID = UUID()
        systemAudioSessionID = sessionID
        systemAudioTranscript = ""
        systemAudioCommittedText = ""
        systemAudioLastLiveSampleCount = 0
        systemAudioTranscribeInFlight = false
        systemAudioStatusMessage = "Starting system audio capture..."
        isSystemAudioTranscribing = true
        isSystemAudioFinishing = false
        systemAudioSessionStartedAt = Date()

        systemAudioCaptureService.onStreamStopped = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.systemAudioSessionID == sessionID, self.isSystemAudioTranscribing else { return }
                let failureMessage = error.map { "System audio capture stopped: \($0.localizedDescription)" }
                self.stopSystemAudioTranscription(finalStatusMessage: failureMessage)
            }
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.whisperService.ensureModelLoaded(self.selectedModel)
                try await self.systemAudioCaptureService.startCapture()
            } catch {
                await MainActor.run {
                    guard self.systemAudioSessionID == sessionID else { return }
                    self.isSystemAudioTranscribing = false
                    self.isSystemAudioFinishing = false
                    self.systemAudioStatusMessage = Self.systemAudioStartFailureMessage(for: error)
                }
                return
            }
            await MainActor.run {
                guard self.systemAudioSessionID == sessionID, self.isSystemAudioTranscribing else {
                    Task { _ = await self.systemAudioCaptureService.stopCapture() }
                    return
                }
                self.systemAudioStatusMessage = "Listening to system audio..."
                self.startSystemAudioLoop(sessionID: sessionID)
            }
        }
    }

    func stopSystemAudioTranscription() {
        stopSystemAudioTranscription(finalStatusMessage: nil)
    }

    private func stopSystemAudioTranscription(finalStatusMessage: String?) {
        guard isSystemAudioTranscribing else { return }
        isSystemAudioTranscribing = false
        isSystemAudioFinishing = true
        let liveTranscriptionTask = systemAudioLoopTask
        liveTranscriptionTask?.cancel()
        systemAudioLoopTask = nil

        // Invalidate any in-flight partial transcription so it cannot race the
        // final pass below; the final pass runs under this fresh session ID.
        let finalSessionID = UUID()
        systemAudioSessionID = finalSessionID
        systemAudioStatusMessage = "Finishing transcript..."

        let language = selectedLanguage == "auto" ? nil : selectedLanguage
        let prompt = customDictionary.isEmpty ? nil : customDictionary.joined(separator: ", ")
        let startedAt = systemAudioSessionStartedAt

        Task { [weak self] in
            guard let self else { return }
            let remaining = await self.systemAudioCaptureService.stopCapture()

            // Cancellation prevents another live tick, but WhisperKit may still
            // be finishing the inference already in progress. Wait for that task
            // before using the same model for the final tail transcription.
            await liveTranscriptionTask?.value

            var finalText = await MainActor.run { self.systemAudioCommittedText }
            if SpeechActivityDetector.containsSpeech(remaining),
               let tail = try? await self.whisperService.transcribe(samples: remaining, language: language, prompt: prompt) {
                let trimmedTail = tail.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedTail.isEmpty {
                    finalText = WhisperService.mergeTranscriptFragments(finalText, trimmedTail)
                }
            }

            await MainActor.run {
                guard self.systemAudioSessionID == finalSessionID else { return }
                self.systemAudioCommittedText = finalText
                self.systemAudioTranscript = finalText
                self.isSystemAudioFinishing = false
                self.systemAudioStatusMessage = finalStatusMessage ?? (finalText.isEmpty
                    ? "No speech detected in system audio."
                    : nil)
                if !finalText.isEmpty {
                    let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
                    self.saveToHistory(text: finalText, durationSeconds: duration, language: language)
                }
            }
        }
    }

    private func startSystemAudioLoop(sessionID: UUID) {
        systemAudioLoopTask?.cancel()
        systemAudioLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self?.runSystemAudioTick(sessionID: sessionID)
            }
        }
    }

    private func runSystemAudioTick(sessionID: UUID) async {
        guard isSystemAudioTranscribing, sessionID == systemAudioSessionID else { return }
        guard !systemAudioTranscribeInFlight, whisperService.isModelLoaded else { return }

        let samples = systemAudioCaptureService.snapshot()
        let chunkSampleCount = 30 * 16_000

        if samples.count >= chunkSampleCount {
            // Close out a chunk at the quietest recent moment so words are not
            // cut in half, then transcribe it once and commit the text.
            let cutIndex = SpeechActivityDetector.quietestCutIndex(
                in: samples,
                searchingLast: 8 * 16_000
            )
            let chunk = Array(samples[..<cutIndex])
            systemAudioCaptureService.consumeSamples(cutIndex)
            systemAudioLastLiveSampleCount = 0
            await transcribeSystemAudio(chunk, sessionID: sessionID, commitsChunk: true)
        } else if samples.count - systemAudioLastLiveSampleCount >= 2 * 16_000 {
            guard SpeechActivityDetector.containsSpeech(samples) else { return }
            systemAudioLastLiveSampleCount = samples.count
            await transcribeSystemAudio(samples, sessionID: sessionID, commitsChunk: false)
        }
    }

    private func transcribeSystemAudio(_ samples: [Float], sessionID: UUID, commitsChunk: Bool) async {
        systemAudioTranscribeInFlight = true
        defer { systemAudioTranscribeInFlight = false }

        let language = selectedLanguage == "auto" ? nil : selectedLanguage
        let prompt = customDictionary.isEmpty ? nil : customDictionary.joined(separator: ", ")

        do {
            let text = try await whisperService.transcribe(samples: samples, language: language, prompt: prompt)
            guard sessionID == systemAudioSessionID, isSystemAudioTranscribing else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if commitsChunk {
                if !trimmed.isEmpty {
                    systemAudioCommittedText = WhisperService.mergeTranscriptFragments(systemAudioCommittedText, trimmed)
                }
                systemAudioTranscript = systemAudioCommittedText
            } else if !trimmed.isEmpty {
                systemAudioTranscript = WhisperService.mergeTranscriptFragments(systemAudioCommittedText, trimmed)
            }
            if !systemAudioTranscript.isEmpty {
                systemAudioStatusMessage = nil
            }
        } catch {
            print("[AppState] System audio transcription failed: \(error.localizedDescription)")
        }
    }

    private static func systemAudioStartFailureMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" {
            return "Screen Recording permission is required to capture system audio. Enable WhisperSwiftKey in System Settings > Privacy & Security > Screen Recording, then try again."
        }
        return "Could not start system audio capture: \(error.localizedDescription)"
    }

    private func handleTranscriptionResult(
        text: String,
        durationSeconds: Double,
        language: String?,
        finalizationSessionID: UUID
    ) {
        guard finalizationGate.consume(sessionID: finalizationSessionID) else {
            print("[AppState] Ignoring duplicate final transcription for session \(finalizationSessionID)")
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            handleNoSpeechDetected()
            return
        }

        lastTranscription = trimmed
        transcriptionState = .done(trimmed)

        if autoInsertText {
            finalizeTextInsertion(trimmed)
        } else {
            textInsertionService.cancelProvisionalInsertionSession()
        }

        saveToHistory(text: trimmed, durationSeconds: durationSeconds, language: language)
    }

    /// Completes delivery independently from transcription so the no-session
    /// compatibility path can be regression-tested without recording audio.
    func finalizeTextInsertion(_ text: String) {
        switch textInsertionService.commitProvisionalText(text) {
        case .committed:
            break
        case .needsFallbackInsertion:
            textInsertionService.insertText(text)
        case .provisionalTextPreserved:
            print("[AppState] Final transcript could not safely replace the verified provisional text")
        }
    }

    private func handleNoSpeechDetected() {
        textInsertionService.cancelProvisionalInsertionSession()
        transcriptionState = .error("No speech detected")
    }

    private func transcribeCapturedSamples(
        _ samples: [Float]?,
        language: String?,
        prompt: String?,
        finalizationSessionID: UUID
    ) {
        guard finalizationGate.pendingSessionID == finalizationSessionID else {
            print("[AppState] Ignoring stale transcription task for session \(finalizationSessionID)")
            return
        }

        guard let samples else {
            _ = finalizationGate.consume(sessionID: finalizationSessionID)
            textInsertionService.cancelProvisionalInsertionSession()
            transcriptionState = .error("No audio captured")
            return
        }

        guard SpeechActivityDetector.containsSpeech(samples) else {
            _ = finalizationGate.consume(sessionID: finalizationSessionID)
            handleNoSpeechDetected()
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
                        finalizationSessionID: finalizationSessionID
                    )
                }
            } catch {
                await MainActor.run {
                    guard finalizationGate.consume(sessionID: finalizationSessionID) else { return }
                    textInsertionService.cancelProvisionalInsertionSession()
                    transcriptionState = .error(error.localizedDescription)
                }
            }
        }
    }

    private func beginLiveDictationSession() {
        liveDictationPollingTask?.cancel()
        liveDictationTranscribeTask?.cancel()
        realtimeStartTask?.cancel()
        liveDictationSessionID = UUID()
        liveDictationTranscribeInFlight = false
        liveDictationLastRequestedSampleCount = 0
        liveDictationInsertedText = ""
        liveDictationLastPartialText = ""
        lastTranscription = ""
        liveDictationHasSeenSpeechEnergy = false
        isUsingWhisperRealtimeStreaming = false
        isPreparingWhisperRealtime = false
        shouldStopPreparingWhisperRealtime = false
        liveDictationTargetApplicationPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        liveDictationSupportsProvisionalInsertion =
            textInsertionService.beginProvisionalInsertionSession(
                targetApplicationPID: liveDictationTargetApplicationPID
            )
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

    private func handleRealtimeStreamingPartialText(confirmedText: String, displayText: String, sessionID: UUID) {
        guard sessionID == liveDictationSessionID else { return }
        guard isRecording else { return }

        let trimmedDisplay = displayText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedDisplay.isEmpty else { return }

        // Do not infer silence from a handful of common words. Gate the live display
        // on the actual microphone signal instead.
        guard whisperService.currentRealtimeContainsSpeech() else { return }

        liveDictationHasSeenSpeechEnergy = true
        liveDictationLastPartialText = trimmedDisplay
        updateLiveDictationPreview(trimmedDisplay)
    }

    private func endLiveDictationSession() {
        liveDictationPollingTask?.cancel()
        liveDictationPollingTask = nil
        liveDictationTranscribeTask?.cancel()
        liveDictationTranscribeTask = nil
        realtimeStartTask?.cancel()
        realtimeStartTask = nil
        liveDictationTranscribeInFlight = false
        liveDictationSessionID = UUID()
        isPreparingWhisperRealtime = false
        shouldStopPreparingWhisperRealtime = false
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

        let recentWindowSamples = min(samples.count, 16_000) // Last second of audio.
        let recentSamples = Array(samples.suffix(recentWindowSamples))
        if !liveDictationHasSeenSpeechEnergy {
            guard SpeechActivityDetector.containsSpeech(recentSamples) else {
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
        updateLiveDictationPreview(trimmed)
    }

    func updateLiveDictationPreview(_ transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let willReplaceProvisionalText =
            autoInsertText &&
            liveDictationSupportsProvisionalInsertion &&
            liveDictationInsertedText != trimmed
        if willReplaceProvisionalText {
            recordingOverlayController.beginProvisionalTextReplacement()
        }
        defer {
            if willReplaceProvisionalText {
                recordingOverlayController.endProvisionalTextReplacement()
            }
        }

        // The overlay always previews the latest hypothesis. The document preview
        // replaces one captured AX range atomically; partial hypotheses are never
        // appended or merged because Whisper may revise any earlier word.
        lastTranscription = trimmed
        guard autoInsertText else { return }
        guard liveDictationSupportsProvisionalInsertion else { return }
        guard liveDictationInsertedText != trimmed else { return }

        if textInsertionService.updateProvisionalText(trimmed) {
            liveDictationInsertedText = trimmed
        } else {
            // Stop touching an editor that rejected or failed to reflect an AX
            // update. Finalization will reconcile the last observed document
            // state before deciding whether a normal paste is safe.
            liveDictationSupportsProvisionalInsertion = false
        }
    }

    private func handleLiveDictationPartialFailure(error: Error, sessionID: UUID) {
        guard sessionID == liveDictationSessionID else { return }
        liveDictationTranscribeInFlight = false
        if isRecording {
            print("[AppState] Live dictation partial failed: \(error.localizedDescription)")
        }
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

        Publishers.CombineLatest3($transcriptionState, $showOverlay, $lastTranscription)
            .sink { [weak self] state, showOverlay, previewText in
                self?.updateRecordingOverlay(state: state, showOverlay: showOverlay, previewText: previewText)
            }
            .store(in: &cancellables)

        // Subscribe to whisperService download progress/phase changes to update loading overlay
        whisperService.$downloadProgress
            .combineLatest(whisperService.$loadingPhase)
            .sink { [weak self] _, _ in
                guard let self else { return }
                if case .loadingModel = self.transcriptionState {
                    self.updateRecordingOverlay(state: .loadingModel, showOverlay: self.showOverlay, previewText: "")
                }
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] notification in
                self?.handleActivatedApplication(notification)
            }
            .store(in: &cancellables)
    }

    private func updateRecordingOverlay(state: TranscriptionState, showOverlay: Bool, previewText: String) {
        guard showOverlay else {
            recordingOverlayController.dismiss()
            modelLoadingOverlayController.dismiss()
            return
        }

        switch state {
        case .loadingModel:
            // Use the big centered loading overlay instead of the small capsule
            recordingOverlayController.dismiss()
            let displayName = WhisperService.availableModels
                .first(where: { $0.name == selectedModel })?.displayName ?? selectedModel
            modelLoadingOverlayController.show(
                modelDisplayName: displayName,
                progress: whisperService.downloadProgress,
                phase: whisperService.loadingPhase,
                storagePath: whisperService.modelStorageURL.path
            )
        case .recording:
            modelLoadingOverlayController.dismiss()
            recordingOverlayController.show(
                state: state,
                modelName: whisperService.currentModelName,
                previewText: previewText,
                targetApplicationPID: liveDictationTargetApplicationPID
            )
        default:
            modelLoadingOverlayController.dismiss()
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
