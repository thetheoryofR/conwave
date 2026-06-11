import Foundation

/// Wang 2003 constellation-map hash construction.
///
/// For each anchor peak, pairs it with up to FAN_VALUE later peaks in the
/// target zone [TARGET_T_MIN, TARGET_T_MAX] frames ahead. Each pair becomes:
///
///   hash = (f1 & 0x3FF) << 20 | (f2 & 0x3FF) << 10 | (delta_t & 0x3FF)
///
/// This 30-bit integer is stable across clips that share audio because the
/// delta_t between any two spectral events is the same regardless of when
/// the clip started. Drift up to ~12,500 ppm doesn't degrade hashes (the
/// delta_t shift is sub-frame for realistic phone drift ≤ 100 ppm).
public enum Fingerprinter {

    // MARK: - Constants

    public static let fanValue   = 15   // pairs per anchor peak
    public static let targetTMin = 2    // min frame offset into target zone
    public static let targetTMax = 40   // max frame offset (~3.7s at 11025/1024)

    // MARK: - Hash type

    /// A single fingerprint hash with its anchor timestamp.
    public struct FingerprintHash: Hashable, Sendable {
        /// 30-bit integer: (f1 & 0x3FF) << 20 | (f2 & 0x3FF) << 10 | (delta_t & 0x3FF)
        public let hashValue: UInt32
        /// Frame index of the anchor peak (convert to ms with `Fingerprinter.framesToMs`)
        public let anchorFrame: Int

        public init(hashValue: UInt32, anchorFrame: Int) {
            self.hashValue  = hashValue
            self.anchorFrame = anchorFrame
        }
    }

    // MARK: - Public API

    /// Build the hash list from a sorted peak array.
    public static func buildHashes(from peaks: [PeakPicker.Peak]) -> [FingerprintHash] {
        var hashes: [FingerprintHash] = []
        hashes.reserveCapacity(peaks.count * fanValue)

        let n = peaks.count
        for i in 0..<n {
            let anchor = peaks[i]
            var count = 0

            for j in (i + 1)..<n {
                let target = peaks[j]
                let dt = target.frame - anchor.frame
                if dt < targetTMin { continue }
                if dt > targetTMax { break }   // peaks are time-sorted

                let f1 = UInt32(anchor.freqBin & 0x3FF)
                let f2 = UInt32(target.freqBin & 0x3FF)
                let d  = UInt32(dt & 0x3FF)
                let hv = (f1 << 20) | (f2 << 10) | d

                hashes.append(FingerprintHash(hashValue: hv, anchorFrame: anchor.frame))
                count += 1
                if count >= fanValue { break }
            }
        }

        return hashes
    }

    // MARK: - Top-level convenience

    /// Full pipeline: samples → hashes.
    public static func fingerprint(samples: [Float]) -> [FingerprintHash] {
        let spec   = Spectrogram.compute(samples: samples)
        let peaks  = PeakPicker.pick(from: spec)
        return buildHashes(from: peaks)
    }

    // MARK: - Time conversion

    /// Convert a spectrogram frame index to milliseconds.
    public static func framesToMs(_ frame: Int) -> Double {
        Double(frame * Spectrogram.hopLength) / AudioLoader.targetSampleRate * 1000.0
    }

    /// Convert milliseconds to the nearest frame index.
    public static func msToFrame(_ ms: Double) -> Int {
        Int((ms / 1000.0 * AudioLoader.targetSampleRate) / Double(Spectrogram.hopLength))
    }
}
