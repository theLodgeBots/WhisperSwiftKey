import Foundation
import WhisperKit

/// Wraps WhisperKit for on-device speech-to-text
@MainActor
class WhisperService: ObservableObject {
    private var whisperKit: WhisperKit?
    private var realtimeTranscriber: AudioStreamTranscriber?
    private var realtimeTranscriberTask: Task<Void, Never>?
    private var realtimeSessionID = UUID()

    @Published var isModelLoaded = false
    @Published var isModelAsleep = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var loadingPhase: String = ""
    @Published var currentModelName: String?

    struct ModelInfo: Identifiable {
        var id: String { name }
        let name: String
        let displayName: String
        let sizeBytes: Int64
        let qualityRating: Int
        let speedRating: Int
        let recommended: Bool
    }

    static let availableModels: [ModelInfo] = [
        ModelInfo(name: "openai_whisper-tiny", displayName: "Tiny", sizeBytes: 75_000_000, qualityRating: 2, speedRating: 5, recommended: false),
        ModelInfo(name: "openai_whisper-base", displayName: "Base", sizeBytes: 142_000_000, qualityRating: 3, speedRating: 4, recommended: false),
        ModelInfo(name: "openai_whisper-small", displayName: "Small", sizeBytes: 466_000_000, qualityRating: 3, speedRating: 3, recommended: false),
        ModelInfo(name: "openai_whisper-large-v3", displayName: "Large V3", sizeBytes: 1_500_000_000, qualityRating: 5, speedRating: 2, recommended: false),
        ModelInfo(name: "openai_whisper-large-v3_turbo", displayName: "Large V3 Turbo", sizeBytes: 800_000_000, qualityRating: 5, speedRating: 4, recommended: true),
    ]

    // MARK: - Model Storage

    /// Base directory where WhisperKit/HuggingFace stores downloaded models
    var modelStorageURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
    }

    /// Returns the on-disk folder URL for a specific model variant, or nil if not found
    func modelFolderURL(for modelName: String) -> URL? {
        let url = modelStorageURL.appendingPathComponent(modelName)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return url
        }
        return nil
    }

    /// Whether a model's files exist on disk
    func isModelDownloaded(_ modelName: String) -> Bool {
        modelFolderURL(for: modelName) != nil
    }

    /// Actual disk usage in bytes for a downloaded model, or nil if not downloaded
    func downloadedModelSize(_ modelName: String) -> Int64? {
        guard let folder = modelFolderURL(for: modelName) else { return nil }
        return Self.directorySize(folder)
    }

    /// Remove a downloaded model from disk
    func deleteModel(_ modelName: String) throws {
        guard let folder = modelFolderURL(for: modelName) else { return }
        // If this is the currently loaded model, unload it
        if currentModelName == modelName {
            whisperKit = nil
            isModelLoaded = false
            isModelAsleep = false
        }
        try FileManager.default.removeItem(at: folder)
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: - Model Loading (split download + init)

    func loadModel(_ modelName: String) async throws {
        print("[WhisperService] Loading model: \(modelName)")
        isDownloading = true
        downloadProgress = 0
        loadingPhase = "Downloading model..."

        do {
            // Phase 1: Download (with progress)
            let modelFolder: String
            if let existingFolder = modelFolderURL(for: modelName) {
                print("[WhisperService] Model already downloaded at: \(existingFolder.path)")
                downloadProgress = 1.0
                modelFolder = existingFolder.path
            } else {
                print("[WhisperService] Downloading model: \(modelName)")
                let downloadedURL = try await WhisperKit.download(
                    variant: modelName,
                    progressCallback: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            self?.downloadProgress = progress.fractionCompleted
                        }
                    }
                )
                downloadProgress = 1.0
                modelFolder = downloadedURL.path
                print("[WhisperService] Download complete: \(modelFolder)")
            }

            // Phase 2: Initialize from local files
            loadingPhase = "Initializing model..."
            let config = WhisperKitConfig(
                modelFolder: modelFolder,
                verbose: true,
                prewarm: true,
                download: false
            )
            whisperKit = try await WhisperKit(config)
            isModelLoaded = true
            currentModelName = modelName
            isDownloading = false
            downloadProgress = 1.0
            loadingPhase = ""
            print("[WhisperService] Model loaded: \(modelName)")
        } catch {
            isDownloading = false
            isModelLoaded = false
            loadingPhase = ""
            print("[WhisperService] Failed to load model: \(error)")
            throw error
        }
    }

    func sleepModel() {
        guard isModelLoaded else { return }
        print("[WhisperService] Sleeping model to reclaim VRAM")
        whisperKit = nil
        isModelLoaded = false
        isModelAsleep = true
    }

    func wakeModel() async throws {
        guard isModelAsleep, let modelName = currentModelName else { return }
        print("[WhisperService] Waking model: \(modelName)")
        isModelAsleep = false
        try await loadModel(modelName)
    }

    /// Ensures a model is loaded and ready, handling all states:
    /// already loaded, asleep, currently downloading, or never loaded.
    func ensureModelLoaded(_ modelName: String) async throws {
        if isModelLoaded { return }
        if isModelAsleep {
            try await wakeModel()
            if isModelLoaded { return }
        }
        // If a download is already in progress (e.g. from app launch), wait for it
        if isDownloading {
            print("[WhisperService] Waiting for in-progress model download...")
            while isDownloading {
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            if isModelLoaded { return }
        }
        try await loadModel(modelName)
    }

    func transcribe(
        samples: [Float],
        language: String? = nil,
        prompt: String? = nil
    ) async throws -> String {
        guard let kit = whisperKit else {
            throw WhisperSwiftKeyError.modelNotLoaded
        }

        // Build prompt tokens from custom dictionary string
        var promptTokens: [Int]? = nil
        if let prompt = prompt, let tokenizer = kit.tokenizer {
            let encoded = tokenizer.encode(text: prompt)
            if !encoded.isEmpty {
                promptTokens = encoded
            }
        }

        let options = DecodingOptions(
            language: language,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            promptTokens: promptTokens
        )

        let results = await kit.transcribe(audioArrays: [samples], decodeOptions: options)

        // Flatten results and strip any residual Whisper control tokens
        let text = Self.stripWhisperTokens(
            results
                .compactMap { $0 }
                .flatMap { $0 }
                .map { $0.text }
                .joined(separator: " ")
        )

        // Filter out hallucinated silence artifacts
        if Self.isHallucination(text) {
            print("[WhisperService] Filtered hallucination: \(text)")
            return ""
        }

        print("[WhisperService] Transcribed: \(text.prefix(100))")
        return text
    }

    func startRealtimeTranscription(
        language: String? = nil,
        prompt: String? = nil,
        onTextUpdate: @escaping @MainActor (_ confirmedText: String, _ displayText: String) -> Void
    ) async throws {
        guard let kit = whisperKit else {
            throw WhisperSwiftKeyError.modelNotLoaded
        }
        guard let tokenizer = kit.tokenizer else {
            throw WhisperSwiftKeyError.modelNotLoaded
        }

        await stopRealtimeTranscription()

        kit.audioProcessor.stopRecording()
        kit.audioProcessor.purgeAudioSamples(keepingLast: 0)

        var promptTokens: [Int]? = nil
        if let prompt, !prompt.isEmpty {
            let encoded = tokenizer.encode(text: prompt)
            if !encoded.isEmpty {
                promptTokens = encoded
            }
        }

        let options = DecodingOptions(
            language: language,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            promptTokens: promptTokens
        )

        let sessionID = UUID()
        realtimeSessionID = sessionID

        let transcriber = AudioStreamTranscriber(
            audioEncoder: kit.audioEncoder,
            featureExtractor: kit.featureExtractor,
            segmentSeeker: kit.segmentSeeker,
            textDecoder: kit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: kit.audioProcessor,
            decodingOptions: options
        ) { [weak self] oldState, newState in
            guard let self else { return }
            guard oldState.currentText != newState.currentText ||
                    oldState.unconfirmedSegments != newState.unconfirmedSegments ||
                    oldState.confirmedSegments != newState.confirmedSegments
            else {
                return
            }

            let (confirmed, display) = Self.realtimeTranscriptTexts(from: newState)
            guard !display.isEmpty else { return }
            Task { @MainActor in
                guard self.realtimeSessionID == sessionID else { return }
                onTextUpdate(confirmed, display)
            }
        }

        realtimeTranscriber = transcriber
        realtimeTranscriberTask = Task { [weak self] in
            do {
                try await transcriber.startStreamTranscription()
            } catch {
                print("[WhisperService] Realtime transcription failed: \(error.localizedDescription)")
            }
            await MainActor.run {
                guard let self else { return }
                if self.realtimeSessionID == sessionID {
                    self.realtimeTranscriberTask = nil
                }
            }
        }
    }

    func stopRealtimeTranscription() async {
        let sessionID = UUID()
        realtimeSessionID = sessionID

        if let transcriber = realtimeTranscriber {
            await transcriber.stopStreamTranscription()
        }
        realtimeTranscriber = nil
        realtimeTranscriberTask?.cancel()
        realtimeTranscriberTask = nil
    }

    func stopRealtimeTranscriptionAndCaptureSamples() async -> [Float]? {
        await stopRealtimeTranscription()
        return currentRealtimeCapturedSamples()
    }

    func currentRealtimeCapturedSamples() -> [Float]? {
        guard let kit = whisperKit else { return nil }
        let samples = Array(kit.audioProcessor.audioSamples)
        return samples.isEmpty ? nil : samples
    }

    /// Returns (confirmedText, displayText).
    /// confirmedText: only stable segments that won't be revised — safe to insert into the document.
    /// displayText: full transcript including unconfirmed/in-progress text — for overlay display only.
    private static func realtimeTranscriptTexts(from state: AudioStreamTranscriber.State) -> (confirmed: String, display: String) {
        let confirmed = state.confirmedSegments.map(\.text).joined()
        let unconfirmedSegmentsText = state.unconfirmedSegments.map(\.text).joined()

        let currentText: String
        if state.currentText == "Waiting for speech..." {
            currentText = ""
        } else {
            currentText = state.currentText
        }

        let suffix: String
        if currentText.count >= unconfirmedSegmentsText.count {
            suffix = currentText
        } else {
            suffix = unconfirmedSegmentsText
        }

        let cleanedConfirmed = stripWhisperTokens(confirmed)
        let cleanedDisplay = stripWhisperTokens(confirmed + suffix)

        // Filter hallucinated silence artifacts
        if isHallucination(cleanedDisplay) { return ("", "") }

        return (cleanedConfirmed, cleanedDisplay)
    }

    /// Known Whisper hallucination phrases produced when decoding silence or near-silence.
    /// Whisper Large V3 is particularly prone to these.
    private static let whisperHallucinations: Set<String> = [
        "thank you",
        "thank you.",
        "thanks for watching",
        "thanks for watching.",
        "thanks for watching!",
        "subscribe",
        "subscribe.",
        "bye",
        "bye.",
        "bye bye",
        "bye bye.",
        "you",
        "you.",
        "the end",
        "the end.",
        "so",
        "so.",
        "...",
    ]

    /// Remove Whisper control tokens like <|startoftranscript|>, <|en|>, <|0.00|>, etc.
    private static func stripWhisperTokens(_ text: String) -> String {
        // Strip well-formed tokens: <|...|>
        var result = text.replacingOccurrences(of: "<\\|[^|>]*\\|>", with: "", options: .regularExpression)
        // Strip partial/broken tokens at end of string (e.g. trailing "<|en" or "<|")
        result = result.replacingOccurrences(of: "<\\|[^>]*$", with: "", options: .regularExpression)
        // Strip any remaining orphaned <| sequences
        result = result.replacingOccurrences(of: "<\\|", with: "", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns true if the entire text is a known Whisper hallucination (silence artifact).
    static func isHallucination(_ text: String) -> Bool {
        whisperHallucinations.contains(text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Returns true if the text is a hallucination or a growing prefix of one.
    /// Use during streaming to catch fragments like "Thank" before they complete to "Thank you."
    static func isLikelyHallucination(_ text: String) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        if whisperHallucinations.contains(normalized) { return true }
        // Check if text is a prefix of any known hallucination
        for hallucination in whisperHallucinations {
            if hallucination.hasPrefix(normalized) { return true }
        }
        return false
    }
}

enum WhisperSwiftKeyError: LocalizedError {
    case modelNotLoaded
    case noAudioCaptured

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "No model loaded. Please download a model first."
        case .noAudioCaptured: return "No audio was captured."
        }
    }
}
