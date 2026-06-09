"""
Evaluation: run the full fingerprint → match → align pipeline on a SynthDataset
and measure accuracy against ground truth.
"""

from __future__ import annotations

import os
from itertools import combinations

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

from .fingerprint import fingerprint_file, FingerprintHash
from .match import match_clips, PairwiseResult, find_collisions, build_hash_index
from .align import align_clips, AlignmentResult, ClipAlignment
from .synth_test import SynthDataset


def run_pipeline(
    dataset: SynthDataset,
    verbose: bool = False,
) -> tuple[AlignmentResult, dict[str, list[FingerprintHash]], list[PairwiseResult]]:
    """Fingerprint all clips, match all pairs, align. Returns (result, hashes, pairwise)."""
    clip_ids = [c.path for c in dataset.clips]
    durations: dict[str, float] = {}
    all_hashes: dict[str, list[FingerprintHash]] = {}

    if verbose:
        print("Fingerprinting clips...")
    for clip in dataset.clips:
        hashes, sr, dur = fingerprint_file(clip.path)
        all_hashes[clip.path] = hashes
        durations[clip.path] = dur
        if verbose:
            print(f"  {os.path.basename(clip.path)}: {len(hashes)} hashes, {dur:.1f}s")

    if verbose:
        print("Matching pairs...")
    pairwise: list[PairwiseResult] = []
    for path_a, path_b in combinations(clip_ids, 2):
        r = match_clips(all_hashes[path_a], all_hashes[path_b], path_a, path_b)
        pairwise.append(r)
        if verbose:
            status = f"offset={r.offset_ms:.0f}ms  drift={r.drift_ppm:.1f}ppm  matches={r.n_matches}" if r.success else "FAILED"
            print(f"  {os.path.basename(path_a)} ↔ {os.path.basename(path_b)}: {status}")

    if verbose:
        print("Aligning...")
    result = align_clips(clip_ids, durations, pairwise)
    return result, all_hashes, pairwise


def compute_metrics(
    result: AlignmentResult,
    ground_truth: SynthDataset,
    pairwise_results: list | None = None,
    min_overlap_s: float = 30.0,
) -> dict:
    """
    Compute accuracy metrics vs. ground truth.

    match_rate is computed only over pairs with >=min_overlap_s of shared audio —
    non-overlapping pairs that correctly fail are NOT counted as misses.
    """
    from itertools import combinations
    gt_by_path = {c.path: c for c in ground_truth.clips}
    aligned_by_id = {c.clip_id: c for c in result.clips}

    anchor_path = result.anchor_clip_id
    anchor_gt = gt_by_path.get(anchor_path)
    anchor_true_start = anchor_gt.true_start_ms if anchor_gt else 0.0

    offset_errors = []
    drift_errors = []
    aligned_count = 0

    for clip in ground_truth.clips:
        if clip.path not in aligned_by_id:
            continue
        aligned = aligned_by_id[clip.path]
        aligned_count += 1
        true_relative_start = clip.true_start_ms - anchor_true_start
        error = abs(aligned.global_start_ms - true_relative_start)
        offset_errors.append(error)
        drift_errors.append(abs(aligned.drift_ppm - clip.true_drift_ppm))

    # Compute overlap-aware match rate
    clips = ground_truth.clips
    expected_pairs = 0   # pairs with >=min_overlap_s shared audio
    false_positives = 0  # non-overlapping pairs that matched anyway

    matched_ids: set[tuple[str, str]] = set()
    if pairwise_results:
        for r in pairwise_results:
            if r.success:
                key = (min(r.clip_a, r.clip_b), max(r.clip_a, r.clip_b))
                matched_ids.add(key)

    expected_matched = 0
    for ca, cb in combinations(clips, 2):
        # Compute overlap on the concert timeline
        start_a, end_a = ca.true_start_ms / 1000.0, ca.true_start_ms / 1000.0 + ca.true_duration_s
        start_b, end_b = cb.true_start_ms / 1000.0, cb.true_start_ms / 1000.0 + cb.true_duration_s
        overlap_s = max(0.0, min(end_a, end_b) - max(start_a, start_b))
        key = (min(ca.path, cb.path), max(ca.path, cb.path))
        if overlap_s >= min_overlap_s:
            expected_pairs += 1
            if key in matched_ids:
                expected_matched += 1
        else:
            # Non-overlapping pair: check for false positives
            if key in matched_ids:
                false_positives += 1

    n_total = len(clips)
    match_rate = expected_matched / expected_pairs if expected_pairs > 0 else 0.0

    metrics = {
        "n_clips": n_total,
        "n_aligned": aligned_count,
        "offset_errors_ms": offset_errors,
        "median_offset_error_ms": float(np.median(offset_errors)) if offset_errors else float("inf"),
        "p95_offset_error_ms": float(np.percentile(offset_errors, 95)) if offset_errors else float("inf"),
        "max_offset_error_ms": float(np.max(offset_errors)) if offset_errors else float("inf"),
        "median_drift_error_ppm": float(np.median(drift_errors)) if drift_errors else float("inf"),
        "match_rate": match_rate,
        "expected_pairs": expected_pairs,
        "false_positives": false_positives,
        "residual_ms": result.residual_ms,
        "target_median_ms": 20.0,
        "target_p95_ms": 50.0,
        "target_match_rate": 0.95,
    }
    return metrics


def print_report(
    metrics: dict,
    result: AlignmentResult,
    ground_truth: SynthDataset,
    pairwise_results: list | None = None,
) -> None:
    gt_by_path = {c.path: c for c in ground_truth.clips}
    aligned_by_id = {c.clip_id: c for c in result.clips}
    anchor_gt = gt_by_path.get(result.anchor_clip_id)
    anchor_true_start = anchor_gt.true_start_ms if anchor_gt else 0.0

    print("\n" + "=" * 70)
    print("AUDIO SYNC EVALUATION REPORT")
    print("=" * 70)
    print(f"{'Clip':<20} {'TrueStart':>12} {'RecovStart':>12} {'Error':>10} {'TrueDrift':>10} {'RecDrift':>10}")
    print("-" * 70)

    for clip in ground_truth.clips:
        name = os.path.basename(clip.path)
        if clip.path not in aligned_by_id:
            print(f"{name:<20} {'N/A':>12} {'MISSING':>12} {'---':>10} {clip.true_drift_ppm:>9.1f}p {'---':>10}")
            continue
        aligned = aligned_by_id[clip.path]
        true_rel = clip.true_start_ms - anchor_true_start
        error = abs(aligned.global_start_ms - true_rel)
        print(
            f"{name:<20} {true_rel:>11.0f}ms {aligned.global_start_ms:>11.0f}ms "
            f"{error:>9.0f}ms {clip.true_drift_ppm:>9.1f}p {aligned.drift_ppm:>9.1f}p"
        )

    print("-" * 70)
    print(f"\nMedian offset error : {metrics['median_offset_error_ms']:.1f} ms  "
          f"(target <{metrics['target_median_ms']:.0f}ms)  "
          + ("✓ PASS" if metrics['median_offset_error_ms'] < metrics['target_median_ms'] else "✗ FAIL"))
    print(f"P95 offset error    : {metrics['p95_offset_error_ms']:.1f} ms  "
          f"(target <{metrics['target_p95_ms']:.0f}ms)  "
          + ("✓ PASS" if metrics['p95_offset_error_ms'] < metrics['target_p95_ms'] else "✗ FAIL"))
    exp = metrics.get("expected_pairs", "?")
    fp = metrics.get("false_positives", 0)
    print(f"Match rate          : {metrics['match_rate']*100:.1f}%  "
          f"(overlapping pairs only, n={exp})  "
          f"(target >{metrics['target_match_rate']*100:.0f}%)  "
          + ("✓ PASS" if metrics['match_rate'] >= metrics['target_match_rate'] else "✗ FAIL"))
    print(f"False positives     : {fp} non-overlapping pairs that matched (target=0)")
    print(f"Median drift error  : {metrics['median_drift_error_ppm']:.2f} ppm "
          f"(note: <50ppm drift undetectable at 93ms frame resolution)")
    print(f"Global residual     : {metrics['residual_ms']:.2f} ms")
    print(f"Anchor clip         : {os.path.basename(result.anchor_clip_id)}")
    print("=" * 70)


def plot_debug(
    hashes_a: list[FingerprintHash],
    hashes_b: list[FingerprintHash],
    result: PairwiseResult,
    output_path: str = "debug_match.png",
) -> None:
    """Save debug plot: collision scatter + offset histogram."""
    index_b = build_hash_index(hashes_b)
    collisions = find_collisions(hashes_a, index_b)
    if not collisions:
        print("No collisions to plot.")
        return

    ta = np.array([c[0] for c in collisions])
    tb = np.array([c[1] for c in collisions])
    offsets = tb - ta

    fig, axes = plt.subplots(1, 2, figsize=(12, 5))

    # Scatter: time_a vs time_b with fitted line
    axes[0].scatter(ta, tb, s=1, alpha=0.3, label="collisions")
    if result.success:
        t_line = np.linspace(ta.min(), ta.max(), 100)
        slope = 1.0 + result.drift_ppm * 1e-6
        b_line = t_line * slope + result.offset_ms
        axes[0].plot(t_line, b_line, "r-", linewidth=2, label=f"fit: offset={result.offset_ms:.0f}ms")
    axes[0].set_xlabel("time in clip A (ms)")
    axes[0].set_ylabel("time in clip B (ms)")
    axes[0].set_title("Hash Collision Pairs")
    axes[0].legend()

    # Histogram of raw offsets
    axes[1].hist(offsets, bins=100, color="steelblue", edgecolor="none")
    if result.success:
        axes[1].axvline(result.offset_ms, color="red", linewidth=2, label=f"peak={result.offset_ms:.0f}ms")
    axes[1].set_xlabel("offset = time_b - time_a (ms)")
    axes[1].set_ylabel("count")
    axes[1].set_title("Offset Histogram")
    axes[1].legend()

    plt.suptitle(f"{os.path.basename(result.clip_a)} ↔ {os.path.basename(result.clip_b)}")
    plt.tight_layout()
    plt.savefig(output_path, dpi=100)
    plt.close()
    print(f"Debug plot saved: {output_path}")


def main_evaluate(
    ground_truth_path: str,
    verbose: bool = True,
    plot: bool = False,
) -> None:
    from .synth_test import load_ground_truth
    dataset = load_ground_truth(ground_truth_path)
    result, all_hashes, pairwise = run_pipeline(dataset, verbose=verbose)
    metrics = compute_metrics(result, dataset, pairwise_results=pairwise)
    print_report(metrics, result, dataset, pairwise_results=pairwise)

    if plot and len(result.clips) >= 2:
        clip_ids = list(all_hashes.keys())
        out_path = os.path.join(os.path.dirname(ground_truth_path), "debug_match_01.png")
        from .match import match_clips as _mc
        r01 = _mc(all_hashes[clip_ids[0]], all_hashes[clip_ids[1]], clip_ids[0], clip_ids[1])
        plot_debug(all_hashes[clip_ids[0]], all_hashes[clip_ids[1]], r01, output_path=out_path)
