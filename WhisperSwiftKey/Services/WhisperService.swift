import AVFoundation
import Foundation

/// Wraps WhisperKit for on-device speech-to-text
class WhisperService {
    // TODO: Import WhisperKit and initialize
    // private var whisperKit: WhisperKit?
    
    struct ModelInfo {
        let name: String
        let displayName: String
        let sizeBytes: Int64
        let qualityRating: Int // 1-5
        let speedRating: Int   // 1-5
        let recommended: Bool
    }
    
    static let availableModels: [ModelInfo] = [
        ModelInfo(name: "openai_whisper-tiny", displayName: "Tiny", sizeBytes: 75_000_000, qualityRating: 2, speedRating: 5, recommended: false),
        ModelInfo(name: "openai_whisper-base", displayName: "Base", sizeBytes: 142_000_000, qualityRating: 3, speedRating: 4, recommended: true),
        ModelInfo(name: "openai_whisper-small", displayName: "Small", sizeBytes: 466_000_000, qualityRating: 4, speedRating: 3, recommended: false),
        ModelInfo(name: "openai_whisper-large-v3", displayName: "Large V3", sizeBytes: 1_500_000_000, qualityRating: 5, speedRating: 1, recommended: false),
    ]
    
    var isModelLoaded: Bool {
        // TODO: Check if WhisperKit model is loaded
        return false
    }
    
    func loadModel(_ modelName: String) async throws {
        // TODO: Initialize WhisperKit with selected model
        // whisperKit = try await WhisperKit(model: modelName)
        print("[WhisperService] Loading model: \(modelName)")
    }
    
    func transcribe(
        audioBuffer: AVAudioPCMBuffer,
        model: String,
        language: String? = nil,
        prompt: String? = nil
    ) async throws -> String {
        // TODO: Integrate WhisperKit transcription
        // let options = DecodingOptions(
        //     language: language,
        //     prompt: prompt
        // )
        // let result = try await whisperKit?.transcribe(audioBuffer: audioBuffer, decoding: options)
        // return result?.text ?? ""
        
        // Placeholder
        return "[WhisperKit not yet integrated — transcription placeholder]"
    }
    
    func downloadModel(_ modelName: String, progress: @escaping (Double) -> Void) async throws {
        // TODO: Download model from HuggingFace via WhisperKit
        print("[WhisperService] Downloading model: \(modelName)")
    }
    
    func deleteModel(_ modelName: String) throws {
        // TODO: Delete cached model files
        print("[WhisperService] Deleting model: \(modelName)")
    }
    
    func modelDiskUsage(_ modelName: String) -> Int64 {
        // TODO: Calculate disk usage for model
        return 0
    }
}
