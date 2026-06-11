import Accelerate
import Foundation

/// Computes a log-magnitude STFT spectrogram using Accelerate vDSP FFT.
///
/// Matches the Python prototype exactly:
///   - Hann window, N_FFT=2048, hop=1024 (50% overlap)
///   - Log compression: log(1 + |magnitude|)
///   - Output shape: (n_freq_bins, n_frames) where n_freq_bins = N_FFT/2 + 1 = 1025
public enum Spectrogram {

    // MARK: - Constants (mirror Python prototype)

    public static let nFFT       = 2048
    public static let hopLength  = 1024
    public static let nFreqBins  = nFFT / 2 + 1   // 1025

    // MARK: - Public API

    /// Compute log-magnitude spectrogram from mono float samples at TARGET_SR.
    /// Returns a column-major 2D array: result[freqBin * nFrames + frame].
    public static func compute(samples: [Float]) -> SpectrogramResult {
        let log2n = vDSP_Length(log2(Double(nFFT)))   // 11
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("Failed to create FFT setup — invalid N_FFT")
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        let window = hannWindow(size: nFFT)
        let nFrames = max(0, (samples.count - nFFT) / hopLength + 1)

        // Pre-allocate output: [freqBin × frame], column-major (frame is inner)
        var magnitudes = [Float](repeating: 0, count: nFreqBins * nFrames)

        // Scratch space for one frame
        var windowed   = [Float](repeating: 0, count: nFFT)
        var realPart   = [Float](repeating: 0, count: nFFT / 2)
        var imagPart   = [Float](repeating: 0, count: nFFT / 2)

        for frame in 0..<nFrames {
            let offset = frame * hopLength

            // Apply Hann window
            vDSP_vmul(Array(samples[offset..<(offset + nFFT)]), 1,
                      window, 1,
                      &windowed, 1,
                      vDSP_Length(nFFT))

            // Pack into split complex for vDSP_fft_zrip
            // Real FFT of N points uses N/2-point complex FFT
            var splitComplex = DSPSplitComplex(realp: &realPart, imagp: &imagPart)
            windowed.withUnsafeBytes { ptr in
                let floatPtr = ptr.bindMemory(to: DSPComplex.self)
                vDSP_ctoz(floatPtr.baseAddress!, 2, &splitComplex, 1, vDSP_Length(nFFT / 2))
            }

            vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

            // Compute magnitude for each frequency bin
            // Bin 0 (DC) and bin N/2 (Nyquist) are packed in realPart[0] and imagPart[0]
            // by the real FFT convention; unpack them here.
            let dc       = realPart[0]
            let nyquist  = imagPart[0]
            realPart[0]  = dc
            imagPart[0]  = 0

            // Standard bins 1..N/2-1
            var mag = [Float](repeating: 0, count: nFFT / 2)
            vDSP_zvmags(&splitComplex, 1, &mag, 1, vDSP_Length(nFFT / 2))
            // sqrt to get magnitude (not power)
            var sqrtMag = [Float](repeating: 0, count: nFFT / 2)
            vvsqrtf(&sqrtMag, mag, [Int32(nFFT / 2)])

            // Fill output column: bin 0 = DC, bins 1..N/2-1 = normal, bin N/2 = Nyquist
            magnitudes[0 * nFrames + frame] = abs(dc)
            for bin in 1..<(nFFT / 2) {
                magnitudes[bin * nFrames + frame] = sqrtMag[bin]
            }
            magnitudes[(nFFT / 2) * nFrames + frame] = abs(nyquist)

            // Scale: real FFT output is 2× for bins 1..N/2-1
            // Normalise by N_FFT so amplitude is independent of window size
            let scale = Float(1.0 / Double(nFFT))
            for bin in 0..<nFreqBins {
                magnitudes[bin * nFrames + frame] *= scale
            }
        }

        // Log compression: log(1 + |S|)  — applied in-place
        var one = Float(1.0)
        vDSP_vsadd(magnitudes, 1, &one, &magnitudes, 1, vDSP_Length(magnitudes.count))
        vvlogf(&magnitudes, magnitudes, [Int32(magnitudes.count)])

        return SpectrogramResult(
            data: magnitudes,
            nFreqBins: nFreqBins,
            nFrames: nFrames
        )
    }

    // MARK: - Hann window

    static func hannWindow(size: Int) -> [Float] {
        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        return window
    }
}

// MARK: - Result type

public struct SpectrogramResult {
    /// Column-major: data[freqBin * nFrames + frame]
    public let data: [Float]
    public let nFreqBins: Int
    public let nFrames: Int

    /// Subscript accessor: spec[freqBin, frame]
    @inline(__always)
    public subscript(bin: Int, frame: Int) -> Float {
        data[bin * nFrames + frame]
    }

    public var duration: Double {
        Double(nFrames * Spectrogram.hopLength) / AudioLoader.targetSampleRate
    }
}
