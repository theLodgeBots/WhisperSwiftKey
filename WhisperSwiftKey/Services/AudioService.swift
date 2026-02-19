import AVFoundation
import Foundation

/// Handles microphone capture and returns audio buffers for transcription
class AudioService {
    private var audioEngine: AVAudioEngine?
    private var audioBuffer: AVAudioPCMBuffer?
    private var isRecording = false
    
    func startRecording() {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        
        // Collect audio samples
        var samples: [Float] = []
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            let channelData = buffer.floatChannelData?[0]
            let frameLength = Int(buffer.frameLength)
            if let data = channelData {
                samples.append(contentsOf: UnsafeBufferPointer(start: data, count: frameLength))
            }
        }
        
        do {
            try engine.start()
            audioEngine = engine
            isRecording = true
        } catch {
            print("[AudioService] Failed to start: \(error)")
        }
    }
    
    func stopRecording() -> AVAudioPCMBuffer? {
        guard let engine = audioEngine, isRecording else { return nil }
        
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        audioEngine = nil
        
        // TODO: Return captured audio buffer
        // For now, return nil — will integrate with WhisperKit's expected format
        return nil
    }
    
    func requestPermission(completion: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }
}
