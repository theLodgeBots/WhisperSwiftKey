import Foundation
import WhisperKit

/// Wraps WhisperKit for on-device speech-to-text
@MainActor
class WhisperService: ObservableObject {
    private var whisperKit: WhisperKit?
    
    @Published var isModelLoaded = false
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
            promptTokens: promptTokens
        )
        
        let results = await kit.transcribe(audioArrays: [samples], decodeOptions: options)
        
        // Flatten results
        let text = results
            .compactMap { $0 }
            .flatMap { $0 }
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        print("[WhisperService] Transcribed: \(text.prefix(100))")
        return text
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
