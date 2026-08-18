import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

enum SystemAudioCaptureError: LocalizedError {
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No display is available for system audio capture."
        }
    }
}

/// Captures the audio of everything playing on the system (videos, calls,
/// music) via ScreenCaptureKit and exposes it as 16 kHz mono Float samples
/// for WhisperKit. Requires the Screen Recording permission.
final class SystemAudioCaptureService: NSObject {
    private let sampleLock = NSLock()
    private var stream: SCStream?
    private var streamStoppedHandler: ((Error?) -> Void)?
    private var collectedSamples: [Float] = []
    private var capturing = false
    private let sampleHandlerQueue = DispatchQueue(label: "com.laanlabs.WhisperSwiftKey.systemAudio")

    /// Called on an arbitrary queue when macOS tears the stream down
    /// (display sleep, permission revoked, ...).
    var onStreamStopped: ((Error?) -> Void)? {
        get { locked { streamStoppedHandler } }
        set { locked { streamStoppedHandler = newValue } }
    }

    var isCapturing: Bool {
        locked { capturing }
    }

    var bufferedSampleCount: Int {
        locked { collectedSamples.count }
    }

    private func locked<T>(_ body: () -> T) -> T {
        sampleLock.lock()
        defer { sampleLock.unlock() }
        return body()
    }

    func startCapture() async throws {
        await stopStreamIfNeeded()

        locked { collectedSamples.removeAll(keepingCapacity: true) }

        // This call triggers the Screen Recording permission prompt on first use.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw SystemAudioCaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 16_000
        configuration.channelCount = 1
        // Only the audio track is consumed; keep the mandatory video leg as
        // small and infrequent as ScreenCaptureKit allows.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 5

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleHandlerQueue)
        try await stream.startCapture()

        locked {
            self.stream = stream
            capturing = true
        }
        print("[SystemAudioCaptureService] System audio capture started")
    }

    /// Stops the stream and returns any samples not yet consumed.
    func stopCapture() async -> [Float] {
        await stopStreamIfNeeded()
        return locked {
            let remaining = collectedSamples
            collectedSamples.removeAll(keepingCapacity: false)
            return remaining
        }
    }

    func snapshot() -> [Float] {
        locked { collectedSamples }
    }

    /// Drops the first `count` samples after a chunk has been transcribed.
    func consumeSamples(_ count: Int) {
        locked { collectedSamples.removeFirst(min(count, collectedSamples.count)) }
    }

    private func stopStreamIfNeeded() async {
        let stream = locked {
            capturing = false
            let activeStream = self.stream
            self.stream = nil
            return activeStream
        }
        guard let stream else { return }
        do {
            try await stream.stopCapture()
        } catch {
            // The stream may already be stopped by the system; nothing to recover.
            print("[SystemAudioCaptureService] stopCapture: \(error.localizedDescription)")
        }
    }
}

extension SystemAudioCaptureService: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[SystemAudioCaptureService] Stream stopped: \(error.localizedDescription)")
        let callback = locked { () -> ((Error?) -> Void)? in
            // Ignore a delayed callback from an older stream after a new
            // capture session has already started.
            guard self.stream === stream else { return nil }
            let was = capturing
            capturing = false
            self.stream = nil
            return was ? streamStoppedHandler : nil
        }
        callback?(error)
    }
}

extension SystemAudioCaptureService: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let samples = Self.monoFloatSamples(from: sampleBuffer) else { return }

        locked {
            if capturing {
                collectedSamples.append(contentsOf: samples)
            }
        }
    }

    /// Converts a ScreenCaptureKit audio buffer to mono Float samples,
    /// averaging channels and resampling if the stream ignored the requested
    /// 16 kHz mono format.
    static func monoFloatSamples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        let asbd = asbdPointer.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32 else {
            return nil
        }

        var sizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil
        )
        guard sizeNeeded > 0 else { return nil }

        let ablMemory = UnsafeMutableRawPointer.allocate(
            byteCount: sizeNeeded,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { ablMemory.deallocate() }
        let ablPointer = ablMemory.bindMemory(to: AudioBufferList.self, capacity: 1)

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPointer,
            bufferListSize: sizeNeeded,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        var mono: [Float] = []
        withExtendedLifetime(blockBuffer) {
            let audioBuffers = UnsafeMutableAudioBufferListPointer(ablPointer)
            if audioBuffers.count == 1, let buffer = audioBuffers.first {
                mono = monoSamples(fromInterleaved: buffer)
            } else if audioBuffers.count > 1 {
                mono = monoSamples(fromNonInterleaved: audioBuffers)
            }
        }
        guard !mono.isEmpty else { return nil }

        if asbd.mSampleRate != 16_000, asbd.mSampleRate > 0 {
            mono = resampleLinearly(mono, from: asbd.mSampleRate, to: 16_000)
        }
        return mono
    }

    private static func monoSamples(fromInterleaved buffer: AudioBuffer) -> [Float] {
        guard let data = buffer.mData else { return [] }
        let channelCount = max(1, Int(buffer.mNumberChannels))
        let totalValues = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        let values = UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: Float.self),
            count: totalValues
        )
        guard channelCount > 1 else { return Array(values) }

        let frameCount = totalValues / channelCount
        var mono = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += values[frame * channelCount + channel]
            }
            mono[frame] = sum / Float(channelCount)
        }
        return mono
    }

    private static func monoSamples(fromNonInterleaved buffers: UnsafeMutableAudioBufferListPointer) -> [Float] {
        let channels: [[Float]] = buffers.compactMap { buffer in
            guard let data = buffer.mData else { return nil }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
        }
        guard let frameCount = channels.map(\.count).min(), frameCount > 0 else { return [] }

        var mono = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in channels {
                sum += channel[frame]
            }
            mono[frame] = sum / Float(channels.count)
        }
        return mono
    }

    private static func resampleLinearly(_ samples: [Float], from sourceRate: Float64, to targetRate: Float64) -> [Float] {
        guard samples.count > 1 else { return samples }
        let ratio = sourceRate / targetRate
        let outputCount = Int(Float64(samples.count) / ratio)
        guard outputCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: outputCount)
        for index in 0..<outputCount {
            let sourcePosition = Float64(index) * ratio
            let lower = min(samples.count - 1, Int(sourcePosition))
            let upper = min(samples.count - 1, lower + 1)
            let fraction = Float(sourcePosition - Float64(lower))
            output[index] = samples[lower] * (1 - fraction) + samples[upper] * fraction
        }
        return output
    }
}
