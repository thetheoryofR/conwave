import Accelerate
import Foundation

/// Pairwise clip matching: hash collision histogram + RANSAC linear fit.
///
/// Given hashes from two clips A and B, finds:
///   offset_ms  = intercept of (time_b = slope * time_a + intercept)
///              = global_start_A − global_start_B
///   drift_ppm  = (slope − 1) × 1e6   (clock drift; ~0 for short clips at frame resolution)
///
/// The algorithm is identical to the Python prototype. See match.py for commentary.
public enum Matcher {

    // MARK: - Result

    public struct PairwiseResult: Sendable {
        public let clipA: String
        public let clipB: String
        /// RANSAC intercept = global_start_A - global_start_B (ms).
        /// Positive means clip A started later than clip B.
        public let offsetMs: Double
        public let driftPpm: Double
        public let confidence: Double
        public let nMatches: Int
        public let success: Bool

        static var failure: (String, String) -> PairwiseResult = { a, b in
            PairwiseResult(clipA: a, clipB: b,
                           offsetMs: 0, driftPpm: 0, confidence: 0,
                           nMatches: 0, success: false)
        }
    }

    // MARK: - Thresholds (mirror Python prototype)

    static let minInliers     = 100
    static let histBinWidthMs = 10.0
    static let inlierWindowMs = 50.0
    static let ransacIter     = 100

    // MARK: - Public API

    public static func match(
        hashesA: [Fingerprinter.FingerprintHash],
        hashesB: [Fingerprinter.FingerprintHash],
        clipAId: String = "A",
        clipBId: String = "B",
        rng: inout RandomNumberGenerator
    ) -> PairwiseResult {
        let fail = PairwiseResult.failure(clipAId, clipBId)

        // Build inverted index for B: hashValue → [anchorFrame]
        var indexB: [UInt32: [Int]] = [:]
        for h in hashesB {
            indexB[h.hashValue, default: []].append(h.anchorFrame)
        }

        // Find collisions
        var collisions: [(Double, Double)] = []    // (time_a_ms, time_b_ms)
        for h in hashesA {
            guard let matches = indexB[h.hashValue] else { continue }
            let tA = Fingerprinter.framesToMs(h.anchorFrame)
            for frame in matches {
                collisions.append((tA, Fingerprinter.framesToMs(frame)))
            }
        }

        guard !collisions.isEmpty else { return fail }

        // Histogram of raw offsets (time_b − time_a)
        let (peakOffset, peakCount) = histogramOffset(collisions)
        guard peakCount >= 5 else { return fail }

        // RANSAC linear fit
        guard let (slope, intercept, inliers) = ransacFit(
            collisions: collisions,
            peakOffsetMs: peakOffset,
            rng: &rng
        ), inliers.count >= minInliers else { return fail }

        // Sanity-clamp slope to ±10000 ppm
        let clampedSlope = min(max(slope, 0.99), 1.01)
        let driftPpm = (clampedSlope - 1.0) * 1_000_000.0
        let confidence = min(1.0, Double(peakCount) / Double(max(collisions.count, 1)))

        return PairwiseResult(
            clipA: clipAId, clipB: clipBId,
            offsetMs: intercept,
            driftPpm: driftPpm,
            confidence: confidence,
            nMatches: inliers.count,
            success: true
        )
    }

    // MARK: - Histogram

    static func histogramOffset(
        _ collisions: [(Double, Double)],
        binWidthMs: Double = 10.0
    ) -> (peakOffset: Double, peakCount: Int) {
        let offsets = collisions.map { $0.1 - $0.0 }
        guard let minOff = offsets.min(), let maxOff = offsets.max() else {
            return (0, 0)
        }
        let range = max(maxOff - minOff, 1000.0)
        let nBins = Int(range / binWidthMs) + 2
        let base  = minOff - binWidthMs / 2

        var counts = [Int](repeating: 0, count: nBins)
        for off in offsets {
            let bin = Int((off - base) / binWidthMs)
            if bin >= 0 && bin < nBins { counts[bin] += 1 }
        }

        let peakBin   = counts.indices.max(by: { counts[$0] < counts[$1] }) ?? 0
        let peakOffset = base + (Double(peakBin) + 0.5) * binWidthMs
        return (peakOffset, counts[peakBin])
    }

    // MARK: - RANSAC linear fit

    /// Fits time_b = slope * time_a + intercept.
    /// Returns nil if there are fewer than `minInliers` histogram-filtered points.
    static func ransacFit(
        collisions: [(Double, Double)],
        peakOffsetMs: Double,
        inlierWindowMs: Double = 50.0,
        rng: inout RandomNumberGenerator
    ) -> (slope: Double, intercept: Double, inliers: [(Double, Double)])? {

        // Pre-filter to histogram inliers
        let inliers = collisions.filter { abs(($0.1 - $0.0) - peakOffsetMs) < inlierWindowMs }
        guard inliers.count >= minInliers else { return nil }

        let taArr = inliers.map { $0.0 }
        let tbArr = inliers.map { $0.1 }

        // Initial fit via least-squares (linregress equivalent)
        var (slope, intercept) = linregress(taArr, tbArr)
        var bestInliers = inliers
        var bestCount   = inliers.count
        let tight = inlierWindowMs / 2.0

        // RANSAC iterations
        let n = inliers.count
        for _ in 0..<ransacIter {
            guard n >= 2 else { break }
            let i1 = Int.random(in: 0..<n, using: &rng)
            var i2 = Int.random(in: 0..<n, using: &rng)
            while i2 == i1 { i2 = Int.random(in: 0..<n, using: &rng) }

            let ta1 = taArr[i1], tb1 = tbArr[i1]
            let ta2 = taArr[i2], tb2 = tbArr[i2]
            guard abs(ta2 - ta1) > 1e-6 else { continue }

            let s = (tb2 - tb1) / (ta2 - ta1)
            let b = tb1 - s * ta1

            let candidate = zip(taArr, tbArr).filter { abs($0.1 - (s * $0.0 + b)) < tight }
            if candidate.count > bestCount {
                bestCount   = candidate.count
                bestInliers = candidate.map { ($0.0, $0.1) }
                let (rs, rb) = linregress(candidate.map { $0.0 }, candidate.map { $0.1 })
                slope     = rs
                intercept = rb
            }
        }

        return (slope, intercept, bestInliers)
    }

    // MARK: - Ordinary least-squares (y = a*x + b)

    static func linregress(_ x: [Double], _ y: [Double]) -> (slope: Double, intercept: Double) {
        guard x.count >= 2 else { return (1.0, 0.0) }
        let n  = Double(x.count)
        let sx = x.reduce(0, +)
        let sy = y.reduce(0, +)
        let sxx = zip(x, x).reduce(0) { $0 + $1.0 * $1.1 }
        let sxy = zip(x, y).reduce(0) { $0 + $1.0 * $1.1 }
        let denom = n * sxx - sx * sx
        guard abs(denom) > 1e-12 else { return (1.0, sy / n - sx / n) }
        let slope     = (n * sxy - sx * sy) / denom
        let intercept = (sy - slope * sx) / n
        return (slope, intercept)
    }
}

// MARK: - RandomNumberGenerator conformance for SystemRandomNumberGenerator

extension SystemRandomNumberGenerator: @retroactive RandomNumberGenerator {}
