import XCTest
import Accelerate
@testable import AudioSyncKit

/// Tests that validate algorithm correctness using synthetic audio signals.
/// No real audio files required — all test data is generated in-memory.
///
/// These mirror the Python `synth_test.py` / `evaluate.py` validation but run
/// directly in the Swift test suite so CI can catch regressions.
final class AudioSyncKitTests: XCTestCase {

    // MARK: - Helpers: Synthetic Audio Generation

    /// Generate a tone-rich 30s audio clip suitable for fingerprinting.
    /// Uses a sum of sinusoids at varying frequencies to avoid the "all same hashes"
    /// problem that pure white noise creates.
    static func makeSyntheticConcert(durationS: Double = 30.0,
                                     sr: Int = Int(AudioLoader.targetSampleRate),
                                     seed: UInt64 = 42) -> [Float] {
        var rng = SeededRNG(seed: seed)
        let n   = Int(durationS * Double(sr))
        var audio = [Float](repeating: 0, count: n)

        // 20 "instruments" with time-varying frequencies (avoids fixed-pattern hashes)
        let noteGrid: [Float] = [261.6, 293.7, 329.6, 349.2, 392.0, 440.0, 493.9,
                                 523.3, 587.3, 659.3, 698.5, 784.0, 880.0, 987.8,
                                 1046.5, 1174.7, 1318.5, 1396.9, 1568.0, 1760.0]
        for _ in 0..<20 {
            let noteDurS  = rng.float(in: 0.3..<1.5)
            let segLen    = Int(noteDurS * Double(sr))
            var t         = 0
            while t < n {
                let freq  = noteGrid[Int(rng.next() % UInt64(noteGrid.count))]
                let amp   = rng.float(in: 0.2..<1.0)
                let end   = min(t + segLen, n)
                for i in t..<end {
                    audio[i] += amp * sin(2 * .pi * freq * Float(i) / Float(sr))
                }
                t += segLen
            }
        }

        // Rhythmic transient bursts (irregular interval — see Python synth_test.py)
        var beatT = 0
        while beatT < n {
            let burstLen = Int(rng.float(in: 0.02..<0.05) * Float(sr))
            let end      = min(beatT + burstLen, n)
            for i in beatT..<end {
                audio[i] += rng.float(in: -2.0..<2.0)
            }
            beatT += Int(rng.float(in: 0.4..<0.7) * Float(sr))
        }

        // Normalise
        var peak: Float = 0
        vDSP_maxmgv(audio, 1, &peak, vDSP_Length(n))
        if peak > 0 { vDSP_vsdiv(audio, 1, &peak, &audio, 1, vDSP_Length(n)) }
        var scale: Float = 0.9
        vDSP_vsmul(audio, 1, &scale, &audio, 1, vDSP_Length(n))

        return audio
    }

    /// Slice [startMs, startMs+durationMs) from a concert and apply a time offset
    /// (by slicing at different positions) and additive white noise.
    static func makeClip(from concert: [Float],
                         startMs: Double,
                         durationMs: Double,
                         noiseSNRdB: Double,
                         sr: Int = Int(AudioLoader.targetSampleRate),
                         rng: inout SeededRNG) -> [Float] {
        let startSample = Int(startMs / 1000.0 * Double(sr))
        let nSamples    = Int(durationMs / 1000.0 * Double(sr))
        let end         = min(startSample + nSamples, concert.count)
        var clip        = Array(concert[startSample..<end])

        // Additive white Gaussian noise
        let signalPower = clip.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(clip.count)
        let noisePower  = signalPower / pow(10, noiseSNRdB / 10)
        let noiseStd    = Float(noisePower.squareRoot())
        for i in clip.indices {
            clip[i] += rng.float(in: -noiseStd..<noiseStd)
        }
        return clip
    }

    // MARK: - Unit Tests

    func testSpectrogramShape() {
        let sr      = Int(AudioLoader.targetSampleRate)
        let samples = [Float](repeating: 0.5, count: sr * 10)  // 10s tone
        let spec    = Spectrogram.compute(samples: samples)

        XCTAssertEqual(spec.nFreqBins, Spectrogram.nFreqBins)  // 1025
        let expectedFrames = (samples.count - Spectrogram.nFFT) / Spectrogram.hopLength + 1
        XCTAssertEqual(spec.nFrames, expectedFrames)
    }

    func testPeakPickerProducesPeaks() {
        let concert = Self.makeSyntheticConcert(durationS: 10.0)
        let spec    = Spectrogram.compute(samples: concert)
        let peaks   = PeakPicker.pick(from: spec)

        XCTAssertGreaterThan(peaks.count, 50, "Expected at least 50 peaks in 10s of music-like audio")
        // All peaks should be within bounds
        for p in peaks {
            XCTAssertGreaterThan(p.freqBin, 0)
            XCTAssertLessThan(p.freqBin, spec.nFreqBins)
            XCTAssertLessThan(p.frame, spec.nFrames)
        }
    }

    func testFingerprintHashCount() {
        let concert = Self.makeSyntheticConcert(durationS: 10.0)
        let hashes  = Fingerprinter.fingerprint(samples: concert)

        // ~200 peaks/s × 15 fan × 10s = ~30,000 hashes, but allow wide range
        XCTAssertGreaterThan(hashes.count, 1_000)
        XCTAssertLessThan(hashes.count, 500_000)
    }

    func testSelfMatchReturnsZeroOffset() {
        let concert = Self.makeSyntheticConcert(durationS: 15.0)
        let hashes  = Fingerprinter.fingerprint(samples: concert)
        var rng: RandomNumberGenerator = SystemRandomNumberGenerator()

        let result = Matcher.match(
            hashesA: hashes,
            hashesB: hashes,
            clipAId: "A",
            clipBId: "A_copy",
            rng: &rng
        )

        XCTAssertTrue(result.success, "Self-match should succeed")
        XCTAssertLessThan(abs(result.offsetMs), 200.0,
                          "Self-match offset should be < 200ms (within 2 frames)")
        XCTAssertEqual(result.driftPpm, 0.0, accuracy: 1.0)
    }

    func testKnownOffsetRecovery() {
        // Clip A = concert[0s..15s], Clip B = concert[5s..15s]
        // True offset_ms = globalStart_A - globalStart_B = 0 - 5000 = -5000ms
        let sr      = Int(AudioLoader.targetSampleRate)
        let concert = Self.makeSyntheticConcert(durationS: 30.0)
        let clipA   = Array(concert[0..<(15 * sr)])
        let clipB   = Array(concert[(5 * sr)..<(20 * sr)])

        let hashA = Fingerprinter.fingerprint(samples: clipA)
        let hashB = Fingerprinter.fingerprint(samples: clipB)
        var rng: RandomNumberGenerator = SystemRandomNumberGenerator()

        let result = Matcher.match(hashesA: hashA, hashesB: hashB,
                                   clipAId: "A", clipBId: "B", rng: &rng)

        XCTAssertTrue(result.success, "Should successfully match clips with 10s shared audio")

        // offset_ms = globalStart_A - globalStart_B = 0 - (-5000) = -5000ms
        // (B started 5s after A on the global concert timeline)
        let trueOffset = 0.0 - 5000.0  // -5000ms
        XCTAssertEqual(result.offsetMs, trueOffset, accuracy: 100.0,
                       "Offset error should be < 100ms for 10s shared audio")
    }

    func testNonOverlappingClipsFail() {
        // Clip A = concert[0s..10s], Clip B = concert[20s..30s] — no shared audio
        let sr      = Int(AudioLoader.targetSampleRate)
        let concert = Self.makeSyntheticConcert(durationS: 30.0)
        let clipA   = Array(concert[0..<(10 * sr)])
        let clipB   = Array(concert[(20 * sr)..<(30 * sr)])

        let hashA = Fingerprinter.fingerprint(samples: clipA)
        let hashB = Fingerprinter.fingerprint(samples: clipB)
        var rng: RandomNumberGenerator = SystemRandomNumberGenerator()

        let result = Matcher.match(hashesA: hashA, hashesB: hashB,
                                   clipAId: "A", clipBId: "B_nooverlap", rng: &rng)

        XCTAssertFalse(result.success,
                       "Non-overlapping clips should not match (false positive)")
    }

    func testAlignThreeClips() {
        // Three clips from concert at offsets 0, 3000, 7000ms
        // Expected global starts (relative to clip 0 as anchor): 0, -3000, -7000ms
        let sr        = Int(AudioLoader.targetSampleRate)
        let concert   = Self.makeSyntheticConcert(durationS: 40.0)
        var rng       = SeededRNG(seed: 99)

        let starts    = [0.0, 3000.0, 7000.0]  // ms into concert
        let durMs     = 15_000.0

        let clips = starts.map { startMs -> [Float] in
            Self.makeClip(from: concert, startMs: startMs, durationMs: durMs,
                          noiseSNRdB: 25, rng: &rng)
        }

        let ids    = ["clip0", "clip1", "clip2"]
        let hashes = clips.map { Fingerprinter.fingerprint(samples: $0) }
        var matchRng: RandomNumberGenerator = SystemRandomNumberGenerator()

        var pairResults = [Matcher.PairwiseResult]()
        for i in 0..<ids.count {
            for j in (i + 1)..<ids.count {
                pairResults.append(Matcher.match(
                    hashesA: hashes[i], hashesB: hashes[j],
                    clipAId: ids[i], clipBId: ids[j],
                    rng: &matchRng
                ))
            }
        }

        let durations = Dictionary(uniqueKeysWithValues: ids.map { ($0, durMs / 1000.0) })
        let result    = Aligner.align(clipIds: ids, durations: durations,
                                      pairwiseResults: pairResults)

        let aligned = Dictionary(uniqueKeysWithValues: result.clips.map { ($0.clipId, $0) })
        let anchor  = result.anchorClipId

        // All clips must be aligned
        XCTAssertEqual(aligned.count, 3, "All 3 clips should be aligned")

        // Anchor is at 0
        XCTAssertEqual(aligned[anchor]?.globalStartMs ?? 999, 0, accuracy: 1,
                       "Anchor must have globalStartMs = 0")

        // Relative offsets: starts[i] - starts[anchorIdx]
        guard let anchorIdx = ids.firstIndex(of: anchor) else { return }
        for (i, id) in ids.enumerated() where i != anchorIdx {
            let trueRelative = starts[i] - starts[anchorIdx]
            // Negate because globalStartMs[B] = -(starts[B] - starts[A]) when B comes later
            // Actually: globalStartMs means "when clip starts on concert timeline"
            // clip0 starts at 0ms, clip1 at -3000ms relative to clip0 if clip0 is anchor
            // Wait: concert_time = globalStart + local_time
            // clip0: concert[0..15s], clip1: concert[3..18s]
            // clip1 started 3s AFTER clip0 on the concert → globalStart_clip1 - globalStart_clip0 = 3000ms
            // But globalStartMs[anchor] = 0, so globalStartMs[clip1] should be +3000ms? No…
            //
            // Convention: globalStartMs[X] = concert_time_when_X_started - concert_time_when_anchor_started
            // clip0 is anchor: concert_time_clip0 = 0ms, concert_time_clip1 = 3000ms
            // globalStartMs[clip1] = 3000 - 0 = 3000ms (positive: started after anchor)
            // But our offset_ms = globalStart_A - globalStart_B (RANSAC intercept)
            // For pair clip0↔clip1: time_b = slope*time_a + intercept, where a=clip0, b=clip1
            // time_b_local = time_a_local + (concert_start_a - concert_start_b)
            // intercept = concert_start_a - concert_start_b = 0 - 3000 = -3000ms
            // globalStart[clip1] = globalStart[clip0] - intercept = 0 - (-3000) = 3000ms ✓
            let expected = starts[i] - starts[anchorIdx]  // positive if started later
            let actual   = aligned[id]?.globalStartMs ?? .nan
            XCTAssertEqual(actual, expected, accuracy: 100.0,
                           "\(id) offset error > 100ms: expected \(expected), got \(actual)")
        }
    }

    func testFramesToMsConversion() {
        let ms = Fingerprinter.framesToMs(100)
        let expected = 100.0 * Double(Spectrogram.hopLength) / AudioLoader.targetSampleRate * 1000.0
        XCTAssertEqual(ms, expected, accuracy: 0.001)
    }
}

// MARK: - Seeded RNG (deterministic test data)

struct SeededRNG {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        // xorshift64
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func float(in range: Range<Float>) -> Float {
        let r = Float(next()) / Float(UInt64.max)
        return range.lowerBound + r * (range.upperBound - range.lowerBound)
    }
}
