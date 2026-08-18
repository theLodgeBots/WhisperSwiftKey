import AVFoundation
import Foundation

/// Handles microphone capture and returns raw Float samples at 16kHz for WhisperKit
class AudioService {
    private var audioEngine: AVAudioEngine?
    private var collectedSamples: [Float] = []
    private var isRecording = false
    private let sampleLock = NSLock()
    
    func startRecording() {
        sampleLock.lock()
        collectedSamples.removeAll(keepingCapacity: true)
        isRecording = false
        sampleLock.unlock()

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
                self.sampleLock.lock()
                if self.isRecording {
                    self.collectedSamples.append(contentsOf: samples)
                }
                self.sampleLock.unlock()
            }
        }
        
        do {
            try engine.start()
            audioEngine = engine
            sampleLock.lock()
            isRecording = true
            sampleLock.unlock()
            print("[AudioService] Recording started (16kHz mono)")
        } catch {
            print("[AudioService] Failed to start: \(error)")
        }
    }
    
    /// Stop recording and return raw 16kHz Float samples for WhisperKit
    func stopRecording() -> [Float]? {
        sampleLock.lock()
        let wasRecording = isRecording
        isRecording = false
        sampleLock.unlock()

        guard let engine = audioEngine, wasRecording else { return nil }
        
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil

        sampleLock.lock()
        let samples = collectedSamples
        collectedSamples.removeAll(keepingCapacity: true)
        sampleLock.unlock()
        
        let duration = Double(samples.count) / 16000.0
        print("[AudioService] Captured \(samples.count) samples (\(String(format: "%.1f", duration))s)")
        
        return samples.isEmpty ? nil : samples
    }

    func currentSamplesSnapshot() -> [Float] {
        sampleLock.lock()
        defer { sampleLock.unlock() }
        return collectedSamples
    }

    var currentSampleCount: Int {
        sampleLock.lock()
        defer { sampleLock.unlock() }
        return collectedSamples.count
    }

    var recordingActive: Bool {
        sampleLock.lock()
        defer { sampleLock.unlock() }
        return isRecording
    }
    
    func requestPermission(completion: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }
}

/// Lightweight speech gate used before decoding. It adapts to the current microphone's
/// noise floor instead of treating common words as hallucinations.
enum SpeechActivityDetector {
    private static let frameSize = 320 // 20 ms at Whisper's 16 kHz sample rate

    static func containsSpeech(_ samples: [Float]) -> Bool {
        guard samples.count >= frameSize * 4 else { return false }

        var frameEnergies: [Float] = []
        frameEnergies.reserveCapacity(samples.count / frameSize)

        var offset = 0
        while offset + frameSize <= samples.count {
            var sumSquares: Float = 0
            for sample in samples[offset..<(offset + frameSize)] {
                sumSquares += sample * sample
            }
            frameEnergies.append(sqrt(sumSquares / Float(frameSize)))
            offset += frameSize
        }

        guard frameEnergies.count >= 4 else { return false }
        let sorted = frameEnergies.sorted()
        let noiseFloor = sorted[min(sorted.count - 1, max(0, sorted.count / 5))]
        let adaptiveThreshold = max(0.0025, noiseFloor * 3)
        let adaptiveSpeechFrames = frameEnergies.filter { $0 >= adaptiveThreshold }.count

        // Require approximately 80 ms of voiced audio to avoid reacting to clicks.
        if adaptiveSpeechFrames >= 4 {
            return true
        }

        // A sustained voice can occupy the entire capture, making a purely local
        // noise estimate as loud as the speech itself. Keep a conservative absolute
        // floor so that case is recognized without treating digital silence as speech.
        let absoluteSpeechFrames = frameEnergies.filter { $0 >= 0.006 }.count
        return absoluteSpeechFrames >= 4
    }

    /// Picks a sample index at which a long capture can be split without cutting
    /// through a word: the middle of the quietest 300 ms window inside the
    /// trailing `searchWindow` samples. Falls back to the end of the buffer.
    static func quietestCutIndex(in samples: [Float], searchingLast searchWindow: Int) -> Int {
        let windowSize = 4_800 // 300 ms at 16 kHz
        let hop = windowSize / 2
        guard samples.count > windowSize else { return samples.count }

        let searchStart = max(0, samples.count - max(searchWindow, windowSize))
        var bestIndex = samples.count
        var bestEnergy = Float.greatestFiniteMagnitude

        var offset = searchStart
        while offset + windowSize <= samples.count {
            var sumSquares: Float = 0
            for sample in samples[offset..<(offset + windowSize)] {
                sumSquares += sample * sample
            }
            if sumSquares < bestEnergy {
                bestEnergy = sumSquares
                bestIndex = offset + windowSize / 2
            }
            offset += hop
        }
        return bestIndex
    }
}
