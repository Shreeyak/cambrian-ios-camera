#!/usr/bin/env python3
"""Analyze a texture-bridge spike run.

Inputs (per run, pulled off the iPad via `xcrun devicectl device copy from`):
    seconds.csv   columns: elapsedSec,produced,signal,pull,widget   (cumulative)
    pulls.csv     columns: pullSeqNo,producedFrameNumber,pullAtNs,latencyNs

Outputs:
    same/+1/+N pulled-stamp histogram + P50/P95/P99 firstPullLatencyNs.
    Pass/fail signal printed on stdout per the spec's exit criteria.

Usage:
    python3 histogram.py path/to/run-dir [outdir]

If outdir is supplied, writes:
    outdir/histogram.png
    outdir/summary.json
"""

import csv
import json
import os
import sys
from collections import Counter
from pathlib import Path

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    HAVE_MPL = True
except Exception:
    HAVE_MPL = False


def percentile(sorted_xs, q):
    if not sorted_xs:
        return None
    k = (len(sorted_xs) - 1) * q
    lo = int(k)
    hi = min(lo + 1, len(sorted_xs) - 1)
    frac = k - lo
    return sorted_xs[lo] + (sorted_xs[hi] - sorted_xs[lo]) * frac


def analyze_run(run_dir: Path):
    seconds_csv = run_dir / "seconds.csv"
    pulls_csv = run_dir / "pulls.csv"
    if not seconds_csv.exists() or not pulls_csv.exists():
        raise FileNotFoundError(f"missing seconds.csv or pulls.csv in {run_dir}")

    # ---------- Per-second snapshots ----------
    seconds_rows = []
    with seconds_csv.open() as f:
        for row in csv.DictReader(f):
            seconds_rows.append({k: int(v) for k, v in row.items()})

    if not seconds_rows:
        raise ValueError(f"empty seconds.csv in {run_dir}")

    # Per-second deltas (the CSV is cumulative)
    deltas = []
    prev = {"produced": 0, "signal": 0, "pull": 0, "widget": 0}
    for row in seconds_rows:
        d = {k: row[k] - prev[k] for k in ("produced", "signal", "pull", "widget")}
        d["elapsedSec"] = row["elapsedSec"]
        deltas.append(d)
        prev = row

    avg_produced = sum(d["produced"] for d in deltas) / len(deltas)
    avg_signal = sum(d["signal"] for d in deltas) / len(deltas)
    avg_pull = sum(d["pull"] for d in deltas) / len(deltas)
    avg_widget = sum(d["widget"] for d in deltas) / len(deltas)

    # ---------- Per-pull entries ----------
    pulls = []
    with pulls_csv.open() as f:
        for row in csv.DictReader(f):
            pulls.append({
                "pullSeqNo": int(row["pullSeqNo"]),
                "producedFrameNumber": int(row["producedFrameNumber"]),
                "pullAtNs": int(row["pullAtNs"]),
                "latencyNs": int(row["latencyNs"]),
            })

    # Skip the warm-up first pull (no predecessor to diff against)
    diffs = []
    for prev_p, cur_p in zip(pulls, pulls[1:]):
        d = cur_p["producedFrameNumber"] - prev_p["producedFrameNumber"]
        diffs.append(d)

    hist = Counter()
    for d in diffs:
        if d == 0:
            hist["same"] += 1
        elif d == 1:
            hist["+1"] += 1
        elif d > 1:
            hist[f"+{d}"] += 1
        else:
            hist[f"{d}"] += 1  # negative — frame went backwards (shouldn't happen)

    same = hist["same"]
    fresh = hist["+1"]
    skip_total = sum(v for k, v in hist.items() if k.startswith("+") and k != "+1")
    skip_max = max([int(k[1:]) for k in hist if k.startswith("+") and k != "+1"], default=1)

    # ---------- Latency stats ----------
    pos_latencies = sorted(p["latencyNs"] for p in pulls if p["latencyNs"] >= 0)
    p50 = percentile(pos_latencies, 0.5)
    p95 = percentile(pos_latencies, 0.95)
    p99 = percentile(pos_latencies, 0.99)
    lat_max = pos_latencies[-1] if pos_latencies else None

    summary = {
        "run_dir": str(run_dir),
        "n_seconds": len(deltas),
        "n_pulls": len(pulls),
        "avg_produced_per_sec": round(avg_produced, 2),
        "avg_signal_per_sec": round(avg_signal, 2),
        "avg_pull_per_sec": round(avg_pull, 2),
        "avg_widget_per_sec": round(avg_widget, 2),
        "histogram": {
            "same": same,
            "+1": fresh,
            "skip_total": skip_total,
            "skip_max_jump": skip_max,
            "all_buckets": dict(hist),
        },
        "ratios": {
            "produced:signal": round(avg_signal / max(avg_produced, 1e-9), 4),
            "signal:pull": round(avg_pull / max(avg_signal, 1e-9), 4),
            "pull:widget": round(avg_pull / max(avg_widget, 1e-9), 4),
        },
        "latency_ns": {
            "p50": p50, "p95": p95, "p99": p99, "max": lat_max,
        },
        "latency_ms": {
            "p50": round(p50 / 1e6, 3) if p50 is not None else None,
            "p95": round(p95 / 1e6, 3) if p95 is not None else None,
            "p99": round(p99 / 1e6, 3) if p99 is not None else None,
            "max": round(lat_max / 1e6, 3) if lat_max is not None else None,
        },
    }
    return summary, hist, pos_latencies


def write_plots(out_dir: Path, hist: Counter, latencies: list, run_label: str):
    if not HAVE_MPL:
        print(f"[warn] matplotlib unavailable; skipping plots for {run_label}")
        return
    out_dir.mkdir(parents=True, exist_ok=True)
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(11, 4))

    # Histogram of pull-to-pull frame deltas
    keys = ["same", "+1"] + sorted(
        [k for k in hist if k.startswith("+") and k != "+1"],
        key=lambda x: int(x[1:])
    )
    vals = [hist.get(k, 0) for k in keys]
    ax1.bar(keys, vals, color=["#d62728", "#2ca02c"] + ["#ff7f0e"] * (len(keys) - 2))
    ax1.set_title(f"{run_label} — pull-to-pull frame delta")
    ax1.set_ylabel("count")
    ax1.grid(axis="y", alpha=0.3)

    # Latency histogram (capped at p99×2 for readability)
    if latencies:
        cap = latencies[int(len(latencies) * 0.99)] * 2 if len(latencies) > 100 else latencies[-1]
        clipped = [x for x in latencies if x <= cap]
        ax2.hist([x / 1e6 for x in clipped], bins=40, color="#1f77b4")
        ax2.set_title(f"{run_label} — first-pull latency (ms)")
        ax2.set_xlabel("ms")
        ax2.set_ylabel("count")
        ax2.grid(axis="y", alpha=0.3)

    plt.tight_layout()
    out_path = out_dir / f"{run_label}.png"
    plt.savefig(out_path, dpi=110)
    plt.close(fig)
    print(f"  wrote {out_path}")


def verdict_for(summary):
    """Apply the spec's exit criteria to a single run."""
    h = summary["histogram"]
    lat = summary["latency_ms"]
    notes = []

    pull_deficit = 1.0 - summary["ratios"]["signal:pull"]
    skip_rate = h["skip_total"] / max(1, h["same"] + h["+1"] + h["skip_total"])
    same_rate = h["same"] / max(1, h["same"] + h["+1"] + h["skip_total"])

    # Numeric heuristic — the spec leaves the final call to a human looking
    # at the recording, but we can flag the "smell" cases here.
    if skip_rate > 0.05:
        notes.append(f"skip rate {skip_rate:.1%} > 5% — staleness vector")
    if pull_deficit > 0.05:
        notes.append(f"signal:pull deficit {pull_deficit:.1%} > 5% — Flutter dropped nudges")
    if lat["p95"] and lat["p95"] > 50:
        notes.append(f"P95 first-pull latency {lat['p95']} ms > 50 ms — sustained staleness")
    if h["skip_max_jump"] > 3:
        notes.append(f"max skip jump {h['skip_max_jump']} frames — burst staleness")

    return notes


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    run_dir = Path(sys.argv[1])
    out_dir = Path(sys.argv[2]) if len(sys.argv) > 2 else None

    summary, hist, latencies = analyze_run(run_dir)
    notes = verdict_for(summary)
    summary["heuristic_notes"] = notes

    print(json.dumps(summary, indent=2, default=str))
    if notes:
        print("HEURISTIC FLAGS:")
        for n in notes:
            print(f"  - {n}")
    else:
        print("HEURISTIC: clean (no numeric red flags)")

    if out_dir:
        out_dir.mkdir(parents=True, exist_ok=True)
        run_label = run_dir.name
        write_plots(out_dir, hist, latencies, run_label)
        with (out_dir / f"{run_label}-summary.json").open("w") as f:
            json.dump(summary, f, indent=2, default=str)


if __name__ == "__main__":
    main()
