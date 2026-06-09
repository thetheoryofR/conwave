"""
Synthetic test data generator: creates WAV files with known ground-truth offsets and drift.

Produces a "concert" audio signal rich in stable spectral peaks (sum of sinusoids +
rhythmic transients), then slices and transforms it to simulate N phone recordings.
"""

from __future__ import annotations

import json
import os
import warnings
from dataclasses import dataclass, asdict
from typing import Sequence

import numpy as np
import scipy.signal
import soundfile as sf

from .fingerprint import TARGET_SR


@dataclass
class SynthClip:
    path: str
    clip_index: int
    true_start_ms: float
    true_drift_ppm: float
    true_duration_s: float
    noise_db: float


@dataclass
class SynthDataset:
    clips: list[SynthClip]
    source_audio_path: str
    output_dir: str


def generate_concert_audio(
    duration_s: float = 300.0,
    sr: int = TARGET_SR,
    seed: int = 42,
) -> np.ndarray:
    """
    Generate synthetic concert-like audio: sum of sinusoidal "instruments" +
    rhythmic transient track. Much better than white noise for fingerprinting
    tests (white noise produces a flat spectrogram with no detectable peaks).
    """
    rng = np.random.default_rng(seed)
    n_samples = int(duration_s * sr)
    t = np.arange(n_samples, dtype=np.float32) / sr
    audio = np.zeros(n_samples, dtype=np.float32)

    # 20 "instruments" — sinusoids with time-varying frequency (notes) AND amplitude
    # Using varying frequencies is critical: fixed-frequency instruments produce identical
    # fingerprints across all time windows, causing false positive matches between
    # non-overlapping clips.
    n_instruments = 20
    note_grid = np.array([261.6, 293.7, 329.6, 349.2, 392.0, 440.0, 493.9,
                          523.3, 587.3, 659.3, 698.5, 784.0, 880.0, 987.8,
                          1046.5, 1174.7, 1318.5, 1396.9, 1568.0, 1760.0,
                          1975.5, 2093.0, 2349.3, 2637.0, 2793.8], dtype=np.float32)
    for _ in range(n_instruments):
        note_change_s = rng.uniform(0.3, 1.5)  # how often the note changes
        n_note_segs = int(duration_s / note_change_s) + 2
        freqs_over_time = rng.choice(note_grid, size=n_note_segs)
        amps_over_time = rng.uniform(0.0, 1.0, size=n_note_segs)

        instrument = np.zeros(n_samples, dtype=np.float32)
        for seg_i in range(n_note_segs):
            start = int(seg_i * note_change_s * sr)
            end = min(start + int(note_change_s * sr), n_samples)
            if start >= n_samples:
                break
            seg_len = end - start
            seg_t = np.arange(seg_len, dtype=np.float32) / sr
            instrument[start:end] = amps_over_time[seg_i] * np.sin(
                2 * np.pi * freqs_over_time[seg_i] * seg_t
            )
        audio += instrument

    # Rhythmic transient track: noise bursts at varying intervals (simulates kick/snare)
    # Varying intervals prevent identical periodic patterns that cause false matches
    beat_t = 0.0
    while beat_t < duration_s:
        beat_duration_s = rng.uniform(0.02, 0.05)
        start = int(beat_t * sr)
        end = min(start + int(beat_duration_s * sr), n_samples)
        burst_len = end - start
        if burst_len > 0:
            burst = rng.standard_normal(burst_len).astype(np.float32)
            audio[start:end] += burst * 2.0
        beat_t += rng.uniform(0.4, 0.7)  # slightly varying beat interval

    # Mild pink noise floor
    white = rng.standard_normal(n_samples).astype(np.float32)
    b_pink, a_pink = scipy.signal.butter(1, 200 / (sr / 2), btype="low")
    pink = scipy.signal.lfilter(b_pink, a_pink, white).astype(np.float32)
    signal_rms = float(np.sqrt(np.mean(audio ** 2))) or 1.0
    pink_rms = float(np.sqrt(np.mean(pink ** 2))) or 1.0
    target_pink_rms = signal_rms * 10 ** (-30 / 20)  # -30dB below signal
    audio += pink * (target_pink_rms / pink_rms)

    # Normalize to [-0.9, 0.9]
    peak = float(np.max(np.abs(audio)))
    if peak > 0:
        audio = audio / peak * 0.9

    return audio


def apply_drift(audio: np.ndarray, sr: int, drift_ppm: float) -> np.ndarray:
    """
    Simulate clock drift by resampling.
    +drift_ppm means phone records at sr * (1 + drift_ppm * 1e-6).
    We resample to correct back to `sr`, effectively stretching/compressing time.
    """
    if abs(drift_ppm) < 0.01:
        return audio

    from fractions import Fraction
    # ratio = 1 / (1 + drift_ppm * 1e-6) ≈ 1 - drift_ppm * 1e-6
    ratio = Fraction(1.0 / (1.0 + drift_ppm * 1e-6)).limit_denominator(10000)
    up, down = ratio.numerator, ratio.denominator

    resampled = scipy.signal.resample_poly(audio, up, down).astype(np.float32)
    return resampled


def add_noise(audio: np.ndarray, snr_db: float, rng: np.random.Generator) -> np.ndarray:
    """Add white Gaussian noise at the specified SNR."""
    signal_power = float(np.mean(audio ** 2))
    if signal_power == 0:
        return audio
    noise_power = signal_power / (10 ** (snr_db / 10))
    noise = rng.standard_normal(len(audio)).astype(np.float32) * float(np.sqrt(noise_power))
    result = audio + noise
    # Clip to prevent integer overflow on save
    return np.clip(result, -1.0, 1.0)


def generate_dataset(
    n_clips: int = 5,
    concert_duration_s: float = 300.0,
    clip_duration_range_s: tuple[float, float] = (60.0, 180.0),
    drift_range_ppm: tuple[float, float] = (-50.0, 50.0),
    snr_db_range: tuple[float, float] = (10.0, 30.0),
    output_dir: str = "/tmp/synth_clips",
    seed: int = 42,
) -> SynthDataset:
    """
    Generate N synthetic WAV clips from a single concert audio source.
    Clip 0 is the anchor (start offset = 0, drift = 0).
    Others have random starts within the concert, random drift, and random noise.
    """
    os.makedirs(output_dir, exist_ok=True)
    rng = np.random.default_rng(seed)

    concert = generate_concert_audio(duration_s=concert_duration_s, sr=TARGET_SR, seed=seed)
    source_path = os.path.join(output_dir, "concert_source.wav")
    sf.write(source_path, concert, TARGET_SR, subtype="PCM_16")

    min_dur, max_dur = clip_duration_range_s
    clips: list[SynthClip] = []

    for i in range(n_clips):
        dur_s = float(rng.uniform(min_dur, max_dur))
        dur_samples = int(dur_s * TARGET_SR)

        if i == 0:
            # Anchor clip: starts at beginning, no drift
            start_sample = 0
            drift_ppm = 0.0
        else:
            # Random start ensuring full duration fits in concert
            max_start = max(0, len(concert) - dur_samples)
            start_sample = int(rng.integers(0, max_start + 1)) if max_start > 0 else 0
            drift_ppm = float(rng.uniform(*drift_range_ppm))

        true_start_ms = start_sample / TARGET_SR * 1000.0

        end_sample = min(start_sample + dur_samples, len(concert))
        clip_audio = concert[start_sample:end_sample].copy()

        # Apply drift
        clip_audio = apply_drift(clip_audio, TARGET_SR, drift_ppm)

        # Add noise
        snr_db = float(rng.uniform(*snr_db_range))
        clip_audio = add_noise(clip_audio, snr_db, rng)

        # Check overlap with anchor (clip 0) for later warning
        if i > 0 and len(clips) > 0:
            anchor_end_ms = clips[0].true_duration_s * 1000.0
            anchor_start_ms = clips[0].true_start_ms
            overlap_start = max(true_start_ms, anchor_start_ms)
            overlap_end = min(true_start_ms + dur_s * 1000.0, anchor_end_ms)
            overlap_s = max(0.0, overlap_end - overlap_start) / 1000.0
            if overlap_s < 30.0:
                warnings.warn(
                    f"Clip {i} overlaps anchor by only {overlap_s:.1f}s — "
                    "matching may fail (need ~30s overlap)"
                )

        path = os.path.join(output_dir, f"clip_{i:02d}.wav")
        sf.write(path, clip_audio, TARGET_SR, subtype="PCM_16")

        clips.append(SynthClip(
            path=path,
            clip_index=i,
            true_start_ms=true_start_ms,
            true_drift_ppm=drift_ppm,
            true_duration_s=len(clip_audio) / TARGET_SR,
            noise_db=snr_db,
        ))

    return SynthDataset(clips=clips, source_audio_path=source_path, output_dir=output_dir)


def save_ground_truth(dataset: SynthDataset, path: str) -> None:
    with open(path, "w") as f:
        json.dump(asdict(dataset), f, indent=2)


def load_ground_truth(path: str) -> SynthDataset:
    with open(path) as f:
        data = json.load(f)
    clips = [SynthClip(**c) for c in data["clips"]]
    return SynthDataset(
        clips=clips,
        source_audio_path=data["source_audio_path"],
        output_dir=data["output_dir"],
    )


if __name__ == "__main__":
    import tempfile

    print("Generating 3-clip synthetic dataset...")
    with tempfile.TemporaryDirectory() as tmpdir:
        dataset = generate_dataset(n_clips=3, concert_duration_s=120.0, output_dir=tmpdir)
        gt_path = os.path.join(tmpdir, "ground_truth.json")
        save_ground_truth(dataset, gt_path)

        print(f"Generated {len(dataset.clips)} clips:")
        for c in dataset.clips:
            print(f"  clip_{c.clip_index:02d}: start={c.true_start_ms:.0f}ms  "
                  f"drift={c.true_drift_ppm:.1f}ppm  dur={c.true_duration_s:.1f}s  "
                  f"snr={c.noise_db:.0f}dB")

        loaded = load_ground_truth(gt_path)
        assert len(loaded.clips) == len(dataset.clips)
        print("Round-trip JSON: PASS")
    print("PASS")
