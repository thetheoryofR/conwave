import AVFoundation
import Foundation

/// Top-level async API for syncing a set of audio/video clips.
///
/// Usage (on a background Task):
///
///   let result = try await ClipSync.sync(urls: clipURLs) { progress in
///       print("Progress: \(progress.stage) \(progress.fraction)")
///   }
///   for clip in result.clips {
///       print("\(clip.clipId): globalStartMs=\(clip.globalStartMs)")
///   }
///
/// The result is directly compatible with the JSON schema produced by the
/// Python CLI (`cli.py sync`), so iOS and Python outputs are interchangeable.
public enum ClipSync {

    // MARK: - Progress

    public struct Progress: Sendable {
        public enum Stage: String, Sendable {
            case fingerprinting, matching, aligning
        }
        public let stage: Stage
        /// 0.0 … 1.0 within the overall sync operation.
        public let fraction: Double
        public let detail: String
    }

    public typealias ProgressHandler = @Sendable (Progress) -> Void

    // MARK: - Output (mirrors Python cli.py JSON schema)

    public struct SyncResult: Sendable {
        public let anchorClipId: String
        public let clips: [Aligner.ClipAlignment]
        public let residualMs: Double
        public let nPairsUsed: Int
        public let matchRate: Double
    }

    // MARK: - Main entry point

    /// Sync N clips by URL. Fingerprints in parallel, then matches all pairs.
    /// `progress` is called on an arbitrary Task context (not Main actor).
    public static func sync(
        urls: [URL],
        progress: ProgressHandler? = nil
    ) async throws -> SyncResult {
        guard urls.count >= 2 else {
            throw SyncError.tooFewClips(count: urls.count)
        }

        // --- Phase 1: Fingerprint all clips ---
        var allHashes  = [Int: [Fingerprinter.FingerprintHash]]()
        var durations  = [String: Double]()
        let totalURLs  = Double(urls.count)

        // Fingerprint concurrently (bounded by system threads)
        try await withThrowingTaskGroup(of: (Int, [Fingerprinter.FingerprintHash], Double).self) { group in
            for (i, url) in urls.enumerated() {
                group.addTask {
                    let samples  = try AudioLoader.load(url: url)
                    let hashes   = Fingerprinter.fingerprint(samples: samples)
                    let duration = Double(samples.count) / AudioLoader.targetSampleRate
                    return (i, hashes, duration)
                }
            }
            var done = 0
            for try await (i, hashes, duration) in group {
                allHashes[i] = hashes
                durations[urls[i].lastPathComponent] = duration
                done += 1
                progress?(Progress(
                    stage: .fingerprinting,
                    fraction: Double(done) / totalURLs * 0.4,
                    detail: urls[i].lastPathComponent
                ))
            }
        }

        // --- Phase 2: Match all pairs ---
        var pairs  = [(Int, Int)]()
        for i in 0..<urls.count {
            for j in (i + 1)..<urls.count { pairs.append((i, j)) }
        }
        let totalPairs = Double(pairs.count)
        var pairResults = [Matcher.PairwiseResult]()
        pairResults.reserveCapacity(pairs.count)

        // Match pairs sequentially (each match is CPU-bound on the thread pool)
        var rng: RandomNumberGenerator = SystemRandomNumberGenerator()
        for (p, (i, j)) in pairs.enumerated() {
            let idA = urls[i].lastPathComponent
            let idB = urls[j].lastPathComponent
            let r = Matcher.match(
                hashesA: allHashes[i] ?? [],
                hashesB: allHashes[j] ?? [],
                clipAId: idA,
                clipBId: idB,
                rng: &rng
            )
            pairResults.append(r)
            progress?(Progress(
                stage: .matching,
                fraction: 0.4 + Double(p + 1) / totalPairs * 0.4,
                detail: "\(idA) ↔ \(idB): \(r.success ? "✓" : "✗")"
            ))
        }

        // --- Phase 3: Align ---
        progress?(Progress(stage: .aligning, fraction: 0.9, detail: "Computing global timeline…"))

        let clipIds = urls.map { $0.lastPathComponent }
        let result  = Aligner.align(
            clipIds: clipIds,
            durations: durations,
            pairwiseResults: pairResults
        )

        let nSuccessful = pairResults.filter { $0.success }.count
        let matchRate   = Double(nSuccessful) / Double(max(pairResults.count, 1))

        progress?(Progress(stage: .aligning, fraction: 1.0, detail: "Done"))

        return SyncResult(
            anchorClipId: result.anchorClipId,
            clips: result.clips,
            residualMs: result.residualMs,
            nPairsUsed: result.nPairsUsed,
            matchRate: matchRate
        )
    }
}

// MARK: - Errors

public enum SyncError: Error, LocalizedError {
    case tooFewClips(count: Int)

    public var errorDescription: String? {
        switch self {
        case .tooFewClips(let n):
            return "Need at least 2 clips to sync (got \(n))."
        }
    }
}
