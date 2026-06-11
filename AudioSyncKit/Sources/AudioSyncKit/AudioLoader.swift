import AVFoundation
import Accelerate

/// Loads any audio file into a mono Float32 buffer at TARGET_SR (11025 Hz).
///
/// Uses AVAudioFile + AVAudioConverter so the same code handles WAV, M4A,
/// AAC, and any format QuickTime can open — which covers everything recorded
/// by iOS cameras.
public enum AudioLoader {

    /// Target sample rate for fingerprinting (matches Python prototype).
    public static let targetSampleRate: Double = 11_025

    /// Load an audio file from disk, returning a mono Float32 array at 11025 Hz.
    /// Throws if the file cannot be opened or converted.
    public static func load(url: URL) throws -> [Float] {
        let audioFile = try AVAudioFile(forReading: url)

        // Output format: mono, 32-bit float, 11025 Hz
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioLoadError.formatCreationFailed
        }

        guard let converter = AVAudioConverter(from: audioFile.processingFormat,
                                               to: outputFormat) else {
            throw AudioLoadError.converterCreationFailed
        }

        // Estimate output frame count
        let inputSampleRate = audioFile.processingFormat.sampleRate
        let inputFrameCount = AVAudioFrameCount(audioFile.length)
        let outputFrameCount = AVAudioFrameCount(
            Double(inputFrameCount) * targetSampleRate / inputSampleRate
        ) + 1

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                                  frameCapacity: outputFrameCount) else {
            throw AudioLoadError.bufferAllocationFailed
        }

        // Read and convert in one pass (file is buffered by AVAudioFile)
        var error: NSError?
        var inputDepleted = false

        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputDepleted {
                outStatus.pointee = .noDataNow
                return nil
            }
            let chunkSize = AVAudioFrameCount(4096)
            guard let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: audioFile.processingFormat,
                frameCapacity: chunkSize
            ) else {
                outStatus.pointee = .noDataNow
                return nil
            }
            do {
                try audioFile.read(into: inputBuffer)
                if inputBuffer.frameLength == 0 {
                    inputDepleted = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inputBuffer
            } catch {
                outStatus.pointee = .endOfStream
                return nil
            }
        }

        if status == .error, let err = error {
            throw AudioLoadError.conversionFailed(err)
        }

        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0,
              let channelData = outputBuffer.floatChannelData?[0] else {
            throw AudioLoadError.emptyAudio
        }

        // Copy to Swift array
        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))

        if Double(frameCount) / targetSampleRate < 4.0 {
            throw AudioLoadError.tooShort(duration: Double(frameCount) / targetSampleRate)
        }

        return samples
    }

    /// Load raw Float32 samples already in memory (e.g. from capture pipeline).
    /// Resamples from `sourceSampleRate` to `targetSampleRate` using vDSP.
    public static func resampleToTarget(samples: [Float],
                                        sourceSampleRate: Double) -> [Float] {
        guard sourceSampleRate != targetSampleRate else { return samples }
        let ratio = targetSampleRate / sourceSampleRate
        let outputCount = Int(Double(samples.count) * ratio)
        var output = [Float](repeating: 0, count: outputCount)

        // Linear interpolation via vDSP_vgenp
        var indices = (0..<outputCount).map { Float($0) / Float(ratio) }
        let n = vDSP_Length(outputCount)
        samples.withUnsafeBufferPointer { src in
            indices.withUnsafeMutableBufferPointer { idx in
                output.withUnsafeMutableBufferPointer { dst in
                    vDSP_vqint(src.baseAddress!, idx.baseAddress!, 1,
                               dst.baseAddress!, 1, n, vDSP_Length(samples.count))
                }
            }
        }
        return output
    }
}

// MARK: - Errors

public enum AudioLoadError: Error, LocalizedError {
    case formatCreationFailed
    case converterCreationFailed
    case bufferAllocationFailed
    case conversionFailed(Error)
    case emptyAudio
    case tooShort(duration: Double)

    public var errorDescription: String? {
        switch self {
        case .formatCreationFailed:       return "Failed to create output audio format."
        case .converterCreationFailed:    return "Failed to create audio converter."
        case .bufferAllocationFailed:     return "Failed to allocate audio buffer."
        case .conversionFailed(let e):    return "Audio conversion failed: \(e.localizedDescription)"
        case .emptyAudio:                 return "Audio file contains no samples."
        case .tooShort(let d):            return "Clip too short for fingerprinting (\(String(format: "%.1f", d))s; minimum 4s)."
        }
    }
}
