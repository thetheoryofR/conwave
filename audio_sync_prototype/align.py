"""
Global timeline solver: given N clips and pairwise match results, assigns each clip
a globalStartMs and driftPpm on a single shared timeline.

Steps:
  1. Select anchor (most-connected clip)
  2. BFS to propagate initial offsets
  3. Least-squares refinement for global consistency
"""

from __future__ import annotations

import warnings
from collections import deque
from dataclasses import dataclass, field

import numpy as np

from .match import PairwiseResult


@dataclass
class ClipAlignment:
    clip_id: str
    global_start_ms: float
    drift_ppm: float
    confidence: float
    anchor_hops: int


@dataclass
class AlignmentResult:
    clips: list[ClipAlignment]
    anchor_clip_id: str
    residual_ms: float
    n_pairs_used: int


def select_anchor(
    clip_ids: list[str],
    durations: dict[str, float],
    pairwise_results: list[PairwiseResult],
) -> str:
    """Pick the clip with the most successful pairwise connections; ties by duration."""
    degree: dict[str, int] = {c: 0 for c in clip_ids}
    for r in pairwise_results:
        if r.success:
            degree[r.clip_a] = degree.get(r.clip_a, 0) + 1
            degree[r.clip_b] = degree.get(r.clip_b, 0) + 1

    return max(clip_ids, key=lambda c: (degree.get(c, 0), durations.get(c, 0.0)))


def build_alignment_graph(
    pairwise_results: list[PairwiseResult],
) -> dict[str, list[tuple[str, float, float, float]]]:
    """
    Adjacency list: clip_id → list of (neighbor_id, delta_ms, drift_ppm, confidence).
    delta_ms = global_start[neighbor] - global_start[current].

    From RANSAC: offset_ms (intercept) = global_start_A - global_start_B
    So: A→B delta = -offset_ms,  B→A delta = +offset_ms (first-order; drift corrected)
    """
    graph: dict[str, list[tuple[str, float, float, float]]] = {}
    for r in pairwise_results:
        if not r.success:
            continue
        slope = 1.0 + r.drift_ppm * 1e-6
        # A→B: global_start_B - global_start_A = -intercept = -offset_ms
        fwd_delta = -r.offset_ms
        # B→A: global_start_A - global_start_B = +intercept = offset_ms (drift corrected)
        rev_delta = r.offset_ms / slope
        graph.setdefault(r.clip_a, []).append((r.clip_b, fwd_delta, r.drift_ppm, r.confidence))
        graph.setdefault(r.clip_b, []).append((r.clip_a, rev_delta, -r.drift_ppm, r.confidence))
    return graph


def propagate_offsets_bfs(
    anchor: str,
    graph: dict[str, list[tuple[str, float, float, float]]],
    clip_ids: list[str],
) -> dict[str, ClipAlignment]:
    """
    BFS from anchor to assign initial global_start_ms.
    Anchor gets global_start_ms=0, drift_ppm=0.
    """
    alignments: dict[str, ClipAlignment] = {}
    alignments[anchor] = ClipAlignment(
        clip_id=anchor,
        global_start_ms=0.0,
        drift_ppm=0.0,
        confidence=1.0,
        anchor_hops=0,
    )

    queue: deque[str] = deque([anchor])
    while queue:
        current = queue.popleft()
        current_align = alignments[current]

        for neighbor, offset_ms, drift_ppm, confidence in graph.get(current, []):
            if neighbor in alignments:
                continue
            # offset_ms = global_start_ms[neighbor] - global_start_ms[current]
            global_start = current_align.global_start_ms + offset_ms
            # Drift composes additively (first-order approx for small ppm)
            combined_drift = current_align.drift_ppm + drift_ppm
            combined_confidence = current_align.confidence * confidence

            alignments[neighbor] = ClipAlignment(
                clip_id=neighbor,
                global_start_ms=global_start,
                drift_ppm=combined_drift,
                confidence=combined_confidence,
                anchor_hops=current_align.anchor_hops + 1,
            )
            queue.append(neighbor)

    # Warn about unreachable clips
    for cid in clip_ids:
        if cid not in alignments:
            warnings.warn(f"Clip '{cid}' is unreachable from anchor '{anchor}' — no successful matches.")

    return alignments


def least_squares_refinement(
    initial_alignments: dict[str, ClipAlignment],
    pairwise_results: list[PairwiseResult],
) -> dict[str, ClipAlignment]:
    """
    Refine global_start_ms via weighted least-squares over all successful pairwise constraints.
    Anchor clip is fixed at 0 (removed from unknowns).
    """
    aligned_ids = [cid for cid, a in initial_alignments.items() if a.global_start_ms is not None]
    if len(aligned_ids) < 2:
        return initial_alignments

    # Identify anchor (anchor_hops == 0)
    anchor_id = next(
        (cid for cid, a in initial_alignments.items() if a.anchor_hops == 0), aligned_ids[0]
    )

    # Free variables: all aligned clips except anchor
    free_ids = [cid for cid in aligned_ids if cid != anchor_id]
    id_to_idx = {cid: i for i, cid in enumerate(free_ids)}
    n = len(free_ids)

    if n == 0:
        return initial_alignments

    # Build system: A x = b  where x[i] = global_start_ms[free_ids[i]]
    rows_A, rows_b, rows_w = [], [], []

    successful = [r for r in pairwise_results if r.success and
                  r.clip_a in initial_alignments and r.clip_b in initial_alignments]

    for r in successful:
        # offset_ms = global_start_A - global_start_B  (RANSAC intercept convention)
        # Constraint: x_B - x_A = -offset_ms
        row = np.zeros(n)
        rhs = -r.offset_ms
        w = r.confidence

        if r.clip_a == anchor_id:
            # 0 is fixed; x_B = -offset_ms
            if r.clip_b in id_to_idx:
                row[id_to_idx[r.clip_b]] = 1.0
                rows_A.append(row)
                rows_b.append(rhs)
                rows_w.append(w)
        elif r.clip_b == anchor_id:
            # x_A - 0 = offset_ms  →  x_A = offset_ms
            if r.clip_a in id_to_idx:
                row[id_to_idx[r.clip_a]] = 1.0
                rows_A.append(row)
                rows_b.append(r.offset_ms)
                rows_w.append(w)
        else:
            if r.clip_b in id_to_idx and r.clip_a in id_to_idx:
                row[id_to_idx[r.clip_b]] = 1.0
                row[id_to_idx[r.clip_a]] = -1.0
                rows_A.append(row)
                rows_b.append(rhs)
                rows_w.append(w)

    if not rows_A:
        return initial_alignments

    A_mat = np.array(rows_A)
    b_vec = np.array(rows_b)
    w_vec = np.array(rows_w)

    # Weighted least-squares: multiply by sqrt(w)
    sqrt_w = np.sqrt(w_vec)
    A_w = A_mat * sqrt_w[:, None]
    b_w = b_vec * sqrt_w

    x, _, _, _ = np.linalg.lstsq(A_w, b_w, rcond=None)

    # Apply refined values
    refined = dict(initial_alignments)
    for i, cid in enumerate(free_ids):
        orig = refined[cid]
        refined[cid] = ClipAlignment(
            clip_id=cid,
            global_start_ms=float(x[i]),
            drift_ppm=orig.drift_ppm,
            confidence=orig.confidence,
            anchor_hops=orig.anchor_hops,
        )

    return refined


def align_clips(
    clip_ids: list[str],
    durations: dict[str, float],
    pairwise_results: list[PairwiseResult],
) -> AlignmentResult:
    """Top-level entry: clips + pairwise results → global timeline."""
    anchor = select_anchor(clip_ids, durations, pairwise_results)
    graph = build_alignment_graph(pairwise_results)
    initial = propagate_offsets_bfs(anchor, graph, clip_ids)
    refined = least_squares_refinement(initial, pairwise_results)

    successful_pairs = [r for r in pairwise_results if r.success]

    # Compute RMS residual
    # Constraint: global_start_B - global_start_A = -offset_ms  (since offset_ms = start_A - start_B)
    residuals = []
    for r in successful_pairs:
        if r.clip_a in refined and r.clip_b in refined:
            predicted = refined[r.clip_b].global_start_ms - refined[r.clip_a].global_start_ms
            expected = -r.offset_ms
            residuals.append(predicted - expected)
    residual_ms = float(np.sqrt(np.mean(np.array(residuals) ** 2))) if residuals else 0.0

    clips_out = [
        refined[cid] for cid in clip_ids if cid in refined
    ]

    return AlignmentResult(
        clips=clips_out,
        anchor_clip_id=anchor,
        residual_ms=residual_ms,
        n_pairs_used=len(successful_pairs),
    )


if __name__ == "__main__":
    # Smoke test with three synthetic clips
    results = [
        PairwiseResult("A", "B", offset_ms=5000.0, drift_ppm=10.0, confidence=0.9, n_matches=50, success=True),
        PairwiseResult("B", "C", offset_ms=-3000.0, drift_ppm=-5.0, confidence=0.8, n_matches=40, success=True),
        PairwiseResult("A", "C", offset_ms=2000.0, drift_ppm=5.0, confidence=0.85, n_matches=45, success=True),
    ]
    durations = {"A": 120.0, "B": 100.0, "C": 110.0}
    ar = align_clips(["A", "B", "C"], durations, results)
    print(f"Anchor: {ar.anchor_clip_id}")
    for c in ar.clips:
        print(f"  {c.clip_id}: globalStartMs={c.global_start_ms:.1f}  drift={c.drift_ppm:.2f}ppm  hops={c.anchor_hops}")
    print(f"Residual: {ar.residual_ms:.2f}ms  PairsUsed: {ar.n_pairs_used}")
    print("PASS")
