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
    
    func loadModel(_ modelName: String) async throws {
        print("[WhisperService] Loading model: \(modelName)")
        isDownloading = true
        downloadProgress = 0
        
        do {
            let config = WhisperKitConfig(
                model: modelName,
                verbose: true,
                prewarm: true
            )
            whisperKit = try await WhisperKit(config)
            isModelLoaded = true
            currentModelName = modelName
            isDownloading = false
            downloadProgress = 1.0
            print("[WhisperService] Model loaded: \(modelName)")
        } catch {
            isDownloading = false
            isModelLoaded = false
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

        print("[WhisperService] Transcribed: \(text.prefix(100))")
        return text
    }

    func startRealtimeTranscription(
        language: String? = nil,
        prompt: String? = nil,
        onTextUpdate: @escaping @MainActor (String) -> Void
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

            let transcript = Self.realtimeTranscriptText(from: newState)
            guard !transcript.isEmpty else { return }
            Task { @MainActor in
                guard self.realtimeSessionID == sessionID else { return }
                onTextUpdate(transcript)
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

    private static func realtimeTranscriptText(from state: AudioStreamTranscriber.State) -> String {
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

        return stripWhisperTokens(confirmed + suffix)
    }

    /// Remove Whisper control tokens like <|startoftranscript|>, <|en|>, <|0.00|>, etc.
    private static func stripWhisperTokens(_ text: String) -> String {
        text.replacingOccurrences(of: "<\\|[^|>]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
