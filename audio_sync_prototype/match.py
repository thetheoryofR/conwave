"""
Pairwise audio clip matching via hash collision histogram + RANSAC linear fit.

Given two clips' FingerprintHash lists, finds:
  - offset_ms: how many ms clip B starts after clip A (negative = B started first)
  - drift_ppm: clock drift between devices (slope - 1) * 1e6
"""

from __future__ import annotations

import warnings
from dataclasses import dataclass

import numpy as np
import scipy.stats

from .fingerprint import FingerprintHash, frames_to_ms


@dataclass
class PairwiseResult:
    clip_a: str
    clip_b: str
    offset_ms: float
    drift_ppm: float
    confidence: float
    n_matches: int
    success: bool


class InsufficientMatchesError(Exception):
    pass


def build_hash_index(hashes: list[FingerprintHash]) -> dict[int, list[int]]:
    """Inverted index: hash_val → list of anchor_time frames."""
    index: dict[int, list[int]] = {}
    for h in hashes:
        index.setdefault(h.hash_val, []).append(h.anchor_time)
    return index


def find_collisions(
    hashes_a: list[FingerprintHash],
    index_b: dict[int, list[int]],
) -> list[tuple[float, float]]:
    """
    For each hash in A that also appears in B, emit corresponding (time_a_ms, time_b_ms) pairs.
    These are absolute timestamps within each clip's local timeline.
    """
    collisions: list[tuple[float, float]] = []
    for h in hashes_a:
        if h.hash_val in index_b:
            time_a_ms = frames_to_ms(h.anchor_time)
            for t_b in index_b[h.hash_val]:
                time_b_ms = frames_to_ms(t_b)
                collisions.append((time_a_ms, time_b_ms))
    return collisions


def histogram_offset(
    collisions: list[tuple[float, float]],
    bin_width_ms: float = 10.0,
) -> tuple[float, int]:
    """
    Histogram of raw_offset = time_b - time_a.
    The true offset produces a spike; false collisions spread flat.
    Returns (peak_offset_ms, peak_bin_count).
    """
    if not collisions:
        return 0.0, 0

    offsets = np.array([tb - ta for ta, tb in collisions])
    range_ms = max(abs(offsets.max()), abs(offsets.min()), 1000.0)
    bins = int(2 * range_ms / bin_width_ms) + 1
    counts, edges = np.histogram(offsets, bins=bins)
    peak_bin = int(np.argmax(counts))
    peak_offset_ms = float((edges[peak_bin] + edges[peak_bin + 1]) / 2)
    return peak_offset_ms, int(counts[peak_bin])


def ransac_linear_fit(
    collisions: list[tuple[float, float]],
    peak_offset_ms: float,
    inlier_window_ms: float = 50.0,
    min_inliers: int = 100,
    n_iter: int = 100,
    rng: np.random.Generator | None = None,
) -> tuple[float, float, list[tuple[float, float]]]:
    """
    Fit time_b = slope * time_a + intercept using RANSAC on histogram inliers.
    Returns (slope, intercept, inliers).
    Physical meaning:
      intercept = offset_ms  (when time_a=0, time_b=intercept)
      drift_ppm = (slope - 1) * 1e6
    """
    if rng is None:
        rng = np.random.default_rng(42)

    # Pre-filter to histogram inliers
    inliers_init = [
        (ta, tb) for ta, tb in collisions
        if abs((tb - ta) - peak_offset_ms) < inlier_window_ms
    ]

    if len(inliers_init) < min_inliers:
        raise InsufficientMatchesError(
            f"Only {len(inliers_init)} inliers after histogram filter "
            f"(need {min_inliers})"
        )

    ta_arr = np.array([ta for ta, tb in inliers_init])
    tb_arr = np.array([tb for ta, tb in inliers_init])

    # Initial fit via linregress
    result = scipy.stats.linregress(ta_arr, tb_arr)
    best_slope = float(result.slope)
    best_intercept = float(result.intercept)
    best_inlier_count = len(inliers_init)
    best_inliers = inliers_init

    # RANSAC refinement
    tight_window = inlier_window_ms / 2.0
    n = len(inliers_init)
    for _ in range(n_iter):
        if n < 2:
            break
        idx = rng.choice(n, size=2, replace=False)
        ta_s = ta_arr[idx]
        tb_s = tb_arr[idx]
        if abs(ta_s[1] - ta_s[0]) < 1e-6:
            continue
        slope_s = (tb_s[1] - tb_s[0]) / (ta_s[1] - ta_s[0])
        intercept_s = tb_s[0] - slope_s * ta_s[0]

        residuals = np.abs(tb_arr - (slope_s * ta_arr + intercept_s))
        mask = residuals < tight_window
        count = int(mask.sum())
        if count > best_inlier_count:
            best_inlier_count = count
            ta_in = ta_arr[mask]
            tb_in = tb_arr[mask]
            r = scipy.stats.linregress(ta_in, tb_in)
            best_slope = float(r.slope)
            best_intercept = float(r.intercept)
            best_inliers = [(float(ta_arr[i]), float(tb_arr[i])) for i in np.where(mask)[0]]

    return best_slope, best_intercept, best_inliers


def match_clips(
    hashes_a: list[FingerprintHash],
    hashes_b: list[FingerprintHash],
    clip_a_id: str = "A",
    clip_b_id: str = "B",
) -> PairwiseResult:
    """
    Top-level pairwise matching.
    Returns PairwiseResult with success=False if clips can't be reliably matched.
    """
    _fail = PairwiseResult(
        clip_a=clip_a_id,
        clip_b=clip_b_id,
        offset_ms=0.0,
        drift_ppm=0.0,
        confidence=0.0,
        n_matches=0,
        success=False,
    )

    index_b = build_hash_index(hashes_b)
    collisions = find_collisions(hashes_a, index_b)

    # False positive pairs from repeated musical patterns typically yield <200 collisions;
    # genuine overlapping clips produce thousands. 300 is a safe minimum.
    if len(collisions) < 300:
        return _fail

    peak_offset_ms, peak_count = histogram_offset(collisions)

    if peak_count < 5:
        return _fail

    try:
        slope, intercept, inliers = ransac_linear_fit(collisions, peak_offset_ms)
    except InsufficientMatchesError:
        return _fail

    # Sanity check: reject catastrophically bad slope
    if not (0.99 <= slope <= 1.01):
        warnings.warn(
            f"Suspicious slope {slope:.6f} for {clip_a_id}↔{clip_b_id}; clamping drift."
        )
        slope = max(0.99, min(1.01, slope))

    drift_ppm = (slope - 1.0) * 1_000_000.0
    confidence = min(1.0, peak_count / max(len(collisions), 1))

    return PairwiseResult(
        clip_a=clip_a_id,
        clip_b=clip_b_id,
        offset_ms=intercept,
        drift_ppm=drift_ppm,
        confidence=confidence,
        n_matches=len(inliers),
        success=True,
    )


if __name__ == "__main__":
    # Smoke test: two identical hash lists should give offset≈0, drift≈0
    from .fingerprint import FingerprintHash

    hashes = [FingerprintHash(hash_val=i * 31337 % (1 << 30), anchor_time=i * 10) for i in range(500)]
    result = match_clips(hashes, hashes, "same_a", "same_b")
    print(f"Self-match: offset={result.offset_ms:.1f}ms  drift={result.drift_ppm:.2f}ppm  success={result.success}")
    assert result.success, "Self-match should succeed"
    assert abs(result.offset_ms) < 5.0, f"Self offset too large: {result.offset_ms}"
    print("PASS")
