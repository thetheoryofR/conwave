"""
Wang 2003 audio fingerprinting: audio file → list of (hash, anchor_time) pairs.

Algorithm:
  1. Downsample to 11025 Hz mono
  2. Compute log-magnitude STFT spectrogram
  3. Pick local maxima (constellation map)
  4. Pair each peak with nearby peaks in a target zone ahead → hashes
"""

from __future__ import annotations

import warnings
from typing import NamedTuple

import numpy as np
import scipy.ndimage
import scipy.signal
import librosa

# --- Tunable constants ---
TARGET_SR = 11025
N_FFT = 2048
HOP_LENGTH = 1024
PEAK_NEIGHBORHOOD = 10
MIN_PEAKS_PER_SEC = 10
MAX_PEAKS_PER_SEC = 200
FAN_VALUE = 15
TARGET_T_MIN = 2
TARGET_T_MAX = 40


class FingerprintHash(NamedTuple):
    hash_val: int   # (f1 & 0x3FF) << 20 | (f2 & 0x3FF) << 10 | (delta_t & 0x3FF)
    anchor_time: int  # frame index of anchor peak


def load_audio(path: str) -> tuple[np.ndarray, int]:
    """Load audio file as mono float32 resampled to TARGET_SR."""
    samples, _ = librosa.load(path, sr=TARGET_SR, mono=True, res_type="kaiser_fast")
    if len(samples) / TARGET_SR < 4.0:
        raise ValueError(f"Clip too short for fingerprinting (minimum ~4 seconds): {path}")
    return samples, TARGET_SR


def compute_spectrogram(samples: np.ndarray, sr: int) -> np.ndarray:
    """
    Compute log-magnitude spectrogram via STFT.
    Returns shape (n_freq_bins, n_frames).
    Log compression is mandatory: makes quiet-passage peaks detectable.
    """
    _, _, Zxx = scipy.signal.stft(
        samples,
        fs=sr,
        window="hann",
        nperseg=N_FFT,
        noverlap=N_FFT - HOP_LENGTH,
    )
    magnitude = np.abs(Zxx)
    # Log compression — suppresses dynamic range so peaks in quiet sections survive
    return np.log1p(magnitude)


def pick_peaks(spec: np.ndarray) -> list[tuple[int, int]]:
    """
    Find local maxima in the 2D spectrogram using a sliding maximum filter.
    Returns list of (freq_bin, frame_index) sorted by frame.
    """
    n_freq, n_frames = spec.shape
    duration_s = n_frames * HOP_LENGTH / TARGET_SR

    struct = np.ones((PEAK_NEIGHBORHOOD, PEAK_NEIGHBORHOOD), dtype=bool)
    local_max = scipy.ndimage.maximum_filter(spec, footprint=struct)
    peak_mask = spec == local_max

    # Suppress DC and near-DC
    peak_mask[:2, :] = False

    freq_idx, time_idx = np.where(peak_mask)

    if len(freq_idx) == 0:
        warnings.warn("No peaks found in spectrogram (silent or near-silent clip).")
        return []

    # Prune to MAX_PEAKS_PER_SEC by keeping highest-amplitude peaks
    target_count = max(1, int(MAX_PEAKS_PER_SEC * duration_s))
    if len(freq_idx) > target_count:
        amplitudes = spec[freq_idx, time_idx]
        top_idx = np.argpartition(amplitudes, -target_count)[-target_count:]
        freq_idx = freq_idx[top_idx]
        time_idx = time_idx[top_idx]

    # Warn on sparse peaks
    actual_per_sec = len(freq_idx) / max(duration_s, 1e-6)
    if actual_per_sec < MIN_PEAKS_PER_SEC:
        warnings.warn(
            f"Sparse peaks ({actual_per_sec:.1f}/s < {MIN_PEAKS_PER_SEC}/s); "
            "clip may be near-silent or pure tone."
        )

    # Sort by frame index for deterministic hash construction
    order = np.argsort(time_idx)
    return list(zip(freq_idx[order].tolist(), time_idx[order].tolist()))


def build_hashes(peaks: list[tuple[int, int]]) -> list[FingerprintHash]:
    """
    Wang 2003 constellation map pairing.
    For each anchor peak, pair with up to FAN_VALUE peaks in the target zone.
    hash = (f1 & 0x3FF) << 20 | (f2 & 0x3FF) << 10 | (delta_t & 0x3FF)
    """
    hashes: list[FingerprintHash] = []
    n = len(peaks)

    for i, (f1, t1) in enumerate(peaks):
        # Scan forward to find target-zone peaks
        count = 0
        for j in range(i + 1, n):
            f2, t2 = peaks[j]
            delta_t = t2 - t1
            if delta_t < TARGET_T_MIN:
                continue
            if delta_t > TARGET_T_MAX:
                break
            hash_val = ((f1 & 0x3FF) << 20) | ((f2 & 0x3FF) << 10) | (delta_t & 0x3FF)
            hashes.append(FingerprintHash(hash_val=hash_val, anchor_time=t1))
            count += 1
            if count >= FAN_VALUE:
                break

    return hashes


def fingerprint_file(path: str) -> tuple[list[FingerprintHash], int, float]:
    """Top-level entry: file → (hashes, sr, duration_seconds)."""
    samples, sr = load_audio(path)
    duration_s = len(samples) / sr
    spec = compute_spectrogram(samples, sr)
    peaks = pick_peaks(spec)
    hashes = build_hashes(peaks)
    return hashes, sr, duration_s


def frames_to_ms(frame: int, sr: int = TARGET_SR, hop: int = HOP_LENGTH) -> float:
    """Convert spectrogram frame index to milliseconds."""
    return frame * hop / sr * 1000.0


if __name__ == "__main__":
    import sys
    import os

    if len(sys.argv) > 1:
        path = sys.argv[1]
        hashes, sr, dur = fingerprint_file(path)
        print(f"File: {path}")
        print(f"Duration: {dur:.1f}s  |  Hashes: {len(hashes)}  |  Rate: {len(hashes)/dur:.0f}/s")
        print(f"Sample hashes: {hashes[:5]}")
    else:
        # Quick smoke test with a generated sine burst
        t = np.linspace(0, 30, 30 * TARGET_SR, dtype=np.float32)
        audio = np.sin(2 * np.pi * 440 * t) + 0.5 * np.sin(2 * np.pi * 880 * t)
        spec = compute_spectrogram(audio, TARGET_SR)
        peaks = pick_peaks(spec)
        hashes = build_hashes(peaks)
        print(f"Smoke test: {len(peaks)} peaks, {len(hashes)} hashes from 30s sine burst")
        assert len(hashes) > 0, "No hashes produced"
        print("PASS")
