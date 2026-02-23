import AVFoundation
import Foundation

/// Handles microphone capture and returns raw Float samples at 16kHz for WhisperKit
class AudioService {
    private var audioEngine: AVAudioEngine?
    private var collectedSamples: [Float] = []
    private var isRecording = false
    
    func startRecording() {
        collectedSamples = []
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        
        // WhisperKit needs 16kHz mono
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else {
            print("[AudioService] Failed to create 16kHz format")
            return
        }
        
        guard let converter = AVAudioConverter(from: nativeFormat, to: targetFormat) else {
            print("[AudioService] Failed to create audio converter")
            return
        }
        
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            
            let frameCount = AVAudioFrameCount(targetFormat.sampleRate * Double(buffer.frameLength) / nativeFormat.sampleRate)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }
            
            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            
            if status == .haveData, let channelData = convertedBuffer.floatChannelData?[0] {
                let count = Int(convertedBuffer.frameLength)
                let samples = Array(UnsafeBufferPointer(start: channelData, count: count))
                DispatchQueue.main.async {
                    self.collectedSamples.append(contentsOf: samples)
                }
            }
        }
        
        do {
            try engine.start()
            audioEngine = engine
            isRecording = true
            print("[AudioService] Recording started (16kHz mono)")
        } catch {
            print("[AudioService] Failed to start: \(error)")
        }
    }
    
    /// Stop recording and return raw 16kHz Float samples for WhisperKit
    func stopRecording() -> [Float]? {
        guard let engine = audioEngine, isRecording else { return nil }
        
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        audioEngine = nil
        
        let samples = collectedSamples
        collectedSamples = []
        
        let duration = Double(samples.count) / 16000.0
        print("[AudioService] Captured \(samples.count) samples (\(String(format: "%.1f", duration))s)")
        
        return samples.isEmpty ? nil : samples
    }

    func currentSamplesSnapshot() -> [Float] {
        collectedSamples
    }

    var currentSampleCount: Int {
        collectedSamples.count
    }

    var recordingActive: Bool {
        isRecording
    }
    
    func requestPermission(completion: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }
}
