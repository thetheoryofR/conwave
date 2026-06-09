"""
Command-line interface for the audio sync prototype.

Subcommands:
  sync  FILE [FILE ...]  --output PATH        Align multiple clips
  test  --n-clips N --evaluate               Generate synthetic data and evaluate
  debug-match  FILE_A FILE_B [--plot]        Debug a single clip pair
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import sys
import tempfile
from itertools import combinations


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="audio-sync",
        description="Multi-angle concert audio alignment (Wang 2003 fingerprinting)",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # --- sync ---
    p_sync = sub.add_parser("sync", help="Align multiple audio clips to a shared timeline")
    p_sync.add_argument("files", nargs="+", help="WAV files to align")
    p_sync.add_argument("--output", default="offsets.json", help="Output JSON path (default: offsets.json)")
    p_sync.add_argument("--verbose", "-v", action="store_true")
    p_sync.add_argument("--plot", action="store_true", help="Save debug plots for each pair")

    # --- test ---
    p_test = sub.add_parser("test", help="Generate synthetic test data and optionally evaluate")
    p_test.add_argument("--n-clips", type=int, default=5)
    p_test.add_argument("--duration", type=float, default=300.0, help="Concert duration in seconds")
    p_test.add_argument("--output-dir", default="/tmp/synth_clips")
    p_test.add_argument("--seed", type=int, default=42)
    p_test.add_argument("--evaluate", action="store_true", help="Run evaluation after generation")
    p_test.add_argument("--snr", type=float, default=20.0, help="Noise SNR in dB")
    p_test.add_argument("--verbose", "-v", action="store_true")
    p_test.add_argument("--plot", action="store_true")

    # --- debug-match ---
    p_dbg = sub.add_parser("debug-match", help="Debug matching between two clips")
    p_dbg.add_argument("file_a")
    p_dbg.add_argument("file_b")
    p_dbg.add_argument("--plot", action="store_true")
    p_dbg.add_argument("--verbose", "-v", action="store_true")

    return parser


def cmd_sync(args: argparse.Namespace) -> None:
    from .fingerprint import fingerprint_file
    from .match import match_clips
    from .align import align_clips

    files = args.files
    if len(files) < 2:
        print("Error: need at least 2 files to sync.", file=sys.stderr)
        sys.exit(1)

    if args.verbose:
        print(f"Syncing {len(files)} clips...")

    all_hashes = {}
    durations = {}
    for path in files:
        if args.verbose:
            print(f"  Fingerprinting {os.path.basename(path)}...", end=" ", flush=True)
        hashes, sr, dur = fingerprint_file(path)
        all_hashes[path] = hashes
        durations[path] = dur
        if args.verbose:
            print(f"{len(hashes)} hashes, {dur:.1f}s")

    pairwise = []
    pairs = list(combinations(files, 2))
    if args.verbose:
        print(f"Matching {len(pairs)} pairs...")
    for path_a, path_b in pairs:
        r = match_clips(all_hashes[path_a], all_hashes[path_b], path_a, path_b)
        pairwise.append(r)
        if args.verbose:
            name_a = os.path.basename(path_a)
            name_b = os.path.basename(path_b)
            if r.success:
                print(f"  {name_a} ↔ {name_b}: offset={r.offset_ms:.0f}ms  drift={r.drift_ppm:.1f}ppm  matches={r.n_matches}")
            else:
                print(f"  {name_a} ↔ {name_b}: FAILED (insufficient matches)")
        if args.plot and r.success:
            from .evaluate import plot_debug
            plot_path = f"debug_{os.path.basename(path_a)}_{os.path.basename(path_b)}.png".replace(".wav", "")
            plot_debug(all_hashes[path_a], all_hashes[path_b], r, output_path=plot_path)

    if args.verbose:
        print("Aligning...")
    result = align_clips(files, durations, pairwise)

    n_successful = sum(1 for r in pairwise if r.success)
    match_rate = n_successful / len(pairs) if pairs else 0.0

    output = {
        "anchor": os.path.basename(result.anchor_clip_id),
        "generatedAt": datetime.datetime.utcnow().isoformat() + "Z",
        "clips": [
            {
                "file": os.path.basename(c.clip_id),
                "globalStartMs": round(c.global_start_ms, 2),
                "driftPpm": round(c.drift_ppm, 4),
                "confidence": round(c.confidence, 4),
                "anchorHops": c.anchor_hops,
            }
            for c in result.clips
        ],
        "residualMs": round(result.residual_ms, 2),
        "nPairsUsed": result.n_pairs_used,
        "matchRate": round(match_rate, 4),
    }

    with open(args.output, "w") as f:
        json.dump(output, f, indent=2)

    print(f"Wrote {args.output}")
    print(f"Anchor: {os.path.basename(result.anchor_clip_id)}  |  "
          f"Residual: {result.residual_ms:.1f}ms  |  "
          f"Match rate: {match_rate*100:.0f}%")


def cmd_test(args: argparse.Namespace) -> None:
    from .synth_test import generate_dataset, save_ground_truth

    print(f"Generating {args.n_clips} synthetic clips (concert={args.duration:.0f}s, SNR={args.snr}dB)...")
    dataset = generate_dataset(
        n_clips=args.n_clips,
        concert_duration_s=args.duration,
        snr_db_range=(args.snr, args.snr),
        output_dir=args.output_dir,
        seed=args.seed,
    )

    gt_path = os.path.join(args.output_dir, "ground_truth.json")
    save_ground_truth(dataset, gt_path)
    print(f"Ground truth saved to: {gt_path}")
    print(f"\n{'Clip':<20} {'TrueStart':>12} {'Drift':>10} {'Duration':>10} {'SNR':>6}")
    print("-" * 60)
    for c in dataset.clips:
        print(f"  {os.path.basename(c.path):<18} {c.true_start_ms:>11.0f}ms "
              f"{c.true_drift_ppm:>9.1f}p {c.true_duration_s:>9.1f}s {c.noise_db:>5.0f}dB")

    if args.evaluate:
        from .evaluate import run_pipeline, compute_metrics, print_report
        print("\nRunning evaluation pipeline...")
        result, _, pairwise = run_pipeline(dataset, verbose=args.verbose)
        metrics = compute_metrics(result, dataset, pairwise_results=pairwise)
        print_report(metrics, result, dataset, pairwise_results=pairwise)
        if args.plot:
            from .evaluate import main_evaluate
            main_evaluate(gt_path, verbose=args.verbose, plot=True)


def cmd_debug_match(args: argparse.Namespace) -> None:
    from .fingerprint import fingerprint_file
    from .match import match_clips, find_collisions, build_hash_index, histogram_offset

    print(f"Fingerprinting {os.path.basename(args.file_a)}...")
    hashes_a, _, dur_a = fingerprint_file(args.file_a)
    print(f"  {len(hashes_a)} hashes, {dur_a:.1f}s")

    print(f"Fingerprinting {os.path.basename(args.file_b)}...")
    hashes_b, _, dur_b = fingerprint_file(args.file_b)
    print(f"  {len(hashes_b)} hashes, {dur_b:.1f}s")

    index_b = build_hash_index(hashes_b)
    collisions = find_collisions(hashes_a, index_b)
    print(f"\nHash collisions: {len(collisions)}")

    if collisions:
        peak_offset, peak_count = histogram_offset(collisions)
        print(f"Histogram peak: {peak_offset:.0f}ms  ({peak_count} counts)")

    result = match_clips(hashes_a, hashes_b, args.file_a, args.file_b)
    print(f"\nMatch result:")
    print(f"  success   : {result.success}")
    print(f"  offset_ms : {result.offset_ms:.2f} ms")
    print(f"  drift_ppm : {result.drift_ppm:.3f} ppm")
    print(f"  confidence: {result.confidence:.3f}")
    print(f"  n_matches : {result.n_matches}")

    if args.plot:
        from .evaluate import plot_debug
        plot_path = "debug_match.png"
        plot_debug(hashes_a, hashes_b, result, output_path=plot_path)


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()

    if args.command == "sync":
        cmd_sync(args)
    elif args.command == "test":
        cmd_test(args)
    elif args.command == "debug-match":
        cmd_debug_match(args)


if __name__ == "__main__":
    main()
