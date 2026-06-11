import Accelerate
import Foundation

/// Finds constellation-map peaks in a 2D log-magnitude spectrogram.
///
/// A peak is a point that is the local maximum in a PEAK_NEIGHBORHOOD × PEAK_NEIGHBORHOOD
/// window. The top MAX_PEAKS_PER_SEC peaks by amplitude are kept.
public enum PeakPicker {

    public static let neighborhoodSize = 10        // frames × freq bins
    public static let maxPeaksPerSecond = 200
    public static let minPeaksPerSecond = 10

    /// Peak in spectrogram coordinates.
    public struct Peak: Equatable, Sendable {
        public let freqBin: Int    // 0..<nFreqBins
        public let frame: Int      // 0..<nFrames
        public let amplitude: Float
    }

    /// Extract peaks from a spectrogram.
    /// Returns peaks sorted by frame (ascending), then by freqBin.
    public static func pick(from spec: SpectrogramResult) -> [Peak] {
        let nF = spec.nFreqBins
        let nT = spec.nFrames
        let nh = neighborhoodSize

        // Running sliding-maximum filter over the 2D grid.
        // We do two 1-D passes (horizontal then vertical) which is equivalent
        // to a 2-D max filter for a rectangular neighbourhood.
        var rowMax = [Float](repeating: -.infinity, count: nF * nT)
        var maxFiltered = [Float](repeating: -.infinity, count: nF * nT)

        // 1-D max filter along time axis (inner dimension) for each freq bin
        for bin in 0..<nF {
            let rowStart = bin * nT
            for t in 0..<nT {
                var localMax = Float(-.infinity)
                let lo = max(0, t - nh / 2)
                let hi = min(nT, t + nh / 2 + 1)
                // vDSP_maxv on the slice
                var m: Float = 0
                vDSP_maxv(spec.data.withUnsafeBufferPointer { $0.baseAddress! + rowStart + lo },
                          1, &m, vDSP_Length(hi - lo))
                rowMax[rowStart + t] = m
                _ = localMax  // silence warning
            }
        }

        // 1-D max filter along frequency axis (outer dimension) for each frame
        for t in 0..<nT {
            for bin in 0..<nF {
                let lo = max(0, bin - nh / 2)
                let hi = min(nF, bin + nh / 2 + 1)
                var m: Float = 0
                // Stride = nT (stepping through rows at fixed column t)
                let ptr = rowMax.withUnsafeBufferPointer { $0.baseAddress! + lo * nT + t }
                vDSP_maxv(ptr, nT, &m, vDSP_Length(hi - lo))
                maxFiltered[bin * nT + t] = m
            }
        }

        // A point is a peak if spec == maxFiltered (i.e. it is its own neighbourhood max)
        // Skip DC (bin 0) to avoid low-frequency noise peaks
        var candidates: [Peak] = []
        candidates.reserveCapacity(nF * nT / 20)

        for bin in 1..<nF {
            let rowStart = bin * nT
            for t in 0..<nT {
                let v = spec.data[rowStart + t]
                if v == maxFiltered[rowStart + t] && v > 0 {
                    candidates.append(Peak(freqBin: bin, frame: t, amplitude: v))
                }
            }
        }

        // Prune to MAX_PEAKS_PER_SEC by amplitude, keeping the loudest
        let durationSec = spec.duration
        let targetCount = max(1, Int(Double(maxPeaksPerSecond) * durationSec))

        let pruned: [Peak]
        if candidates.count > targetCount {
            // Partial sort: nth_element equivalent using sorted slice of indices
            let sorted = candidates.sorted { $0.amplitude > $1.amplitude }
            pruned = Array(sorted.prefix(targetCount))
        } else {
            pruned = candidates
        }

        // Warn via print if too sparse (no throw — fingerprinting still works, just weaker)
        let actualRate = Double(pruned.count) / max(durationSec, 1e-6)
        if actualRate < Double(minPeaksPerSecond) {
            print("[AudioSyncKit] Warning: sparse peaks (\(String(format: "%.1f", actualRate))/s). "
                  + "Clip may be near-silent or a pure tone.")
        }

        // Sort by frame then freqBin for deterministic hash construction
        return pruned.sorted {
            $0.frame == $1.frame ? $0.freqBin < $1.freqBin : $0.frame < $1.frame
        }
    }
}
