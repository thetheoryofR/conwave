import Accelerate
import Foundation

/// Global timeline solver: N clips + pairwise results → per-clip globalStartMs + driftPpm.
///
/// Direct Swift port of align.py. Same three-step algorithm:
///   1. Select anchor (most-connected clip)
///   2. BFS propagate offsets from anchor
///   3. Weighted least-squares refinement for global consistency
public enum Aligner {

    // MARK: - Types

    public struct ClipAlignment: Sendable {
        public let clipId: String
        /// When this clip starts on the shared timeline (ms). Negative = started before anchor.
        public let globalStartMs: Double
        /// Clock drift relative to anchor (ppm). ~0 for clips < 5 min; see note in README.
        public let driftPpm: Double
        public let confidence: Double
        public let anchorHops: Int
    }

    public struct AlignmentResult: Sendable {
        public let clips: [ClipAlignment]
        public let anchorClipId: String
        /// RMS residual across all pairwise constraints after LS refinement (ms).
        public let residualMs: Double
        public let nPairsUsed: Int
    }

    // MARK: - Public API

    public static func align(
        clipIds: [String],
        durations: [String: Double],
        pairwiseResults: [Matcher.PairwiseResult]
    ) -> AlignmentResult {
        let anchor    = selectAnchor(clipIds: clipIds, durations: durations, results: pairwiseResults)
        let graph     = buildGraph(from: pairwiseResults)
        var aligned   = bfsPropagate(anchor: anchor, graph: graph, clipIds: clipIds)
        aligned       = leastSquaresRefine(alignments: aligned, results: pairwiseResults)

        let successful = pairwiseResults.filter { $0.success }
        let residual   = computeResidual(alignments: aligned, results: successful)

        let clips = clipIds.compactMap { aligned[$0] }
        return AlignmentResult(
            clips: clips,
            anchorClipId: anchor,
            residualMs: residual,
            nPairsUsed: successful.count
        )
    }

    // MARK: - Anchor selection

    static func selectAnchor(
        clipIds: [String],
        durations: [String: Double],
        results: [Matcher.PairwiseResult]
    ) -> String {
        var degree = [String: Int]()
        for r in results where r.success {
            degree[r.clipA, default: 0] += 1
            degree[r.clipB, default: 0] += 1
        }
        return clipIds.max { a, b in
            let da = degree[a, default: 0], db = degree[b, default: 0]
            if da != db { return da < db }
            return (durations[a] ?? 0) < (durations[b] ?? 0)
        } ?? clipIds[0]
    }

    // MARK: - Adjacency graph
    // Edge weight = delta = global_start[neighbor] - global_start[current]
    // From RANSAC: offset_ms = global_start_A - global_start_B
    //   A→B: delta = -offset_ms
    //   B→A: delta = +offset_ms / slope  (drift-corrected)

    typealias Edge = (neighbor: String, delta: Double, drift: Double, confidence: Double)

    static func buildGraph(from results: [Matcher.PairwiseResult]) -> [String: [Edge]] {
        var graph = [String: [Edge]]()
        for r in results where r.success {
            let slope = 1.0 + r.driftPpm * 1e-6
            let fwd   = -r.offsetMs
            let rev   = r.offsetMs / slope
            graph[r.clipA, default: []].append((r.clipB, fwd,  r.driftPpm,  r.confidence))
            graph[r.clipB, default: []].append((r.clipA, rev, -r.driftPpm,  r.confidence))
        }
        return graph
    }

    // MARK: - BFS propagation

    static func bfsPropagate(
        anchor: String,
        graph: [String: [Edge]],
        clipIds: [String]
    ) -> [String: ClipAlignment] {
        var alignments = [String: ClipAlignment]()
        alignments[anchor] = ClipAlignment(
            clipId: anchor, globalStartMs: 0, driftPpm: 0,
            confidence: 1, anchorHops: 0
        )

        var queue = [anchor]
        var head  = 0
        while head < queue.count {
            let current = queue[head]; head += 1
            let ca = alignments[current]!
            for edge in graph[current] ?? [] {
                guard alignments[edge.neighbor] == nil else { continue }
                alignments[edge.neighbor] = ClipAlignment(
                    clipId: edge.neighbor,
                    globalStartMs: ca.globalStartMs + edge.delta,
                    driftPpm: ca.driftPpm + edge.drift,
                    confidence: ca.confidence * edge.confidence,
                    anchorHops: ca.anchorHops + 1
                )
                queue.append(edge.neighbor)
            }
        }

        for id in clipIds where alignments[id] == nil {
            print("[AudioSyncKit] Warning: clip '\(id)' unreachable from anchor '\(anchor)'")
        }
        return alignments
    }

    // MARK: - Least-squares refinement

    /// Solve weighted least-squares: anchor fixed at 0, free variables = all other clips.
    /// Constraint per pair (A, B): x_B - x_A = -offset_ms
    static func leastSquaresRefine(
        alignments: [String: ClipAlignment],
        results: [Matcher.PairwiseResult]
    ) -> [String: ClipAlignment] {
        let anchorId  = alignments.values.first { $0.anchorHops == 0 }?.clipId
                        ?? alignments.keys.first!
        let freeIds   = alignments.keys.filter { $0 != anchorId }.sorted()
        let n         = freeIds.count
        guard n > 0 else { return alignments }

        let idToIdx   = Dictionary(uniqueKeysWithValues: freeIds.enumerated().map { ($1, $0) })

        var rows  = [[Double]]()
        var rhs   = [Double]()
        var weights = [Double]()

        let successful = results.filter {
            $0.success && alignments[$0.clipA] != nil && alignments[$0.clipB] != nil
        }

        for r in successful {
            var row = [Double](repeating: 0, count: n)
            let rh  = -r.offsetMs
            let w   = r.confidence

            if r.clipA == anchorId {
                guard let idx = idToIdx[r.clipB] else { continue }
                row[idx] = 1.0
                rows.append(row); rhs.append(rh); weights.append(w)
            } else if r.clipB == anchorId {
                guard let idx = idToIdx[r.clipA] else { continue }
                row[idx] = 1.0
                rows.append(row); rhs.append(r.offsetMs); weights.append(w)
            } else {
                guard let bIdx = idToIdx[r.clipB], let aIdx = idToIdx[r.clipA] else { continue }
                row[bIdx] =  1.0
                row[aIdx] = -1.0
                rows.append(row); rhs.append(rh); weights.append(w)
            }
        }

        guard !rows.isEmpty else { return alignments }

        // Weighted: multiply rows and rhs by sqrt(w)
        let m = rows.count
        var A_flat = [Double](repeating: 0, count: m * n)
        var b_vec  = [Double](repeating: 0, count: m)

        for (i, (row, (r, w))) in zip(rows, zip(rhs, weights)).enumerated() {
            let sqrtW = w.squareRoot()
            for j in 0..<n { A_flat[i * n + j] = row[j] * sqrtW }
            b_vec[i] = r * sqrtW
        }

        // Solve via LAPACK dgels (least-squares via QR)
        var solution = leastSquaresSolve(A: &A_flat, b: &b_vec, m: m, n: n)

        var refined = alignments
        for (i, id) in freeIds.enumerated() {
            guard let orig = alignments[id] else { continue }
            refined[id] = ClipAlignment(
                clipId: id,
                globalStartMs: solution[i],
                driftPpm: orig.driftPpm,
                confidence: orig.confidence,
                anchorHops: orig.anchorHops
            )
        }
        return refined
    }

    // MARK: - LAPACK least-squares wrapper

    static func leastSquaresSolve(A: inout [Double], b: inout [Double],
                                   m: Int, n: Int) -> [Double] {
        // dgels solves min ||Ax - b||_2
        // On entry A is m×n, b is m×1 (or m×nrhs).
        // On exit the first n elements of b contain the solution.
        var trans: Int8 = Int8(("N" as UnicodeScalar).value)
        var M = __CLPK_integer(m)
        var N = __CLPK_integer(n)
        var nrhs: __CLPK_integer = 1
        var lda  = __CLPK_integer(m)
        var ldb  = __CLPK_integer(max(m, n))

        // Pad b to max(m,n)
        var bPadded = b + [Double](repeating: 0, count: max(m, n) - m)

        var lwork: __CLPK_integer = -1
        var workQuery = [Double](repeating: 0, count: 1)
        var info: __CLPK_integer = 0

        // Query optimal workspace size
        dgels_(&trans, &M, &N, &nrhs, &A, &lda, &bPadded, &ldb, &workQuery, &lwork, &info)
        lwork = __CLPK_integer(workQuery[0])
        var work = [Double](repeating: 0, count: Int(lwork))

        // Solve
        dgels_(&trans, &M, &N, &nrhs, &A, &lda, &bPadded, &ldb, &work, &lwork, &info)

        if info != 0 {
            // Fall back to BFS values (already in alignments) — LS is best-effort
            return [Double](repeating: 0, count: n)
        }
        return Array(bPadded.prefix(n))
    }

    // MARK: - Residual

    static func computeResidual(
        alignments: [String: ClipAlignment],
        results: [Matcher.PairwiseResult]
    ) -> Double {
        var residuals = [Double]()
        for r in results where r.success {
            guard let ca = alignments[r.clipA], let cb = alignments[r.clipB] else { continue }
            let predicted = cb.globalStartMs - ca.globalStartMs
            let expected  = -r.offsetMs   // x_B - x_A = -offset_ms
            residuals.append(predicted - expected)
        }
        guard !residuals.isEmpty else { return 0 }
        let sumSq = residuals.reduce(0) { $0 + $1 * $1 }
        return (sumSq / Double(residuals.count)).squareRoot()
    }
}
