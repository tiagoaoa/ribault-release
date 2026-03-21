#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Plot Merge Sort benchmark results: runtime, speedup, efficiency.

Reads one or more CSV files (variant column: super, ghc, parpseq).
For each variant: runtime vs N (per P), speedup vs N (per P), efficiency vs N (per P).
When multiple variants are present: comparison plots (best of each).
"""

import argparse, csv, os, math
from collections import defaultdict
from statistics import mean, stdev
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


def read_metrics(*paths):
    """Read CSV files. Returns data[variant][N][P] = [secs...]"""
    data = defaultdict(lambda: defaultdict(lambda: defaultdict(list)))
    for path in paths:
        if not os.path.isfile(path):
            continue
        with open(path, newline="") as f:
            for row in csv.DictReader(f):
                try:
                    variant = row["variant"].strip()
                    N = int(row["N"])
                    P = int(row["P"])
                    sec = float(row["seconds"])
                    rc = int(row["rc"])
                except Exception:
                    continue
                if rc != 0 or not math.isfinite(sec):
                    continue
                data[variant][N][P].append(sec)
    return data


def _save(outdir, base):
    os.makedirs(outdir, exist_ok=True)
    plt.savefig(os.path.join(outdir, base + ".png"), dpi=180)
    plt.savefig(os.path.join(outdir, base + ".pdf"))
    plt.close()
    print(f"[plot] saved {base}.png/.pdf")


VARIANT_LABELS = {
    "super": "Ribault (TALM)",
    "ghc": "GHC Strategies",
    "parpseq": "GHC par/pseq",
}


def plot_runtime(byN, Ns, Ps, outdir, tag, variant):
    plt.figure(figsize=(10, 6))
    for P in Ps:
        ns, mus, sds = [], [], []
        for N in Ns:
            vals = byN.get(N, {}).get(P, [])
            if vals:
                ns.append(N)
                mus.append(mean(vals))
                sds.append(stdev(vals) if len(vals) >= 2 else 0.0)
        if ns:
            plt.errorbar(ns, mus, yerr=sds, marker="o", capsize=3, label=f"P={P}")
    label = VARIANT_LABELS.get(variant, variant)
    plt.title(f"Parallel Merge Sort ({label}): Runtime vs Input Size", fontsize=12)
    plt.xlabel("Input Size (N)", fontsize=11)
    plt.ylabel("Runtime (s)", fontsize=11)
    plt.grid(True, ls=":", lw=0.8)
    plt.legend(title="Processors", fontsize=9)
    plt.tight_layout()
    _save(outdir, f"runtime_{tag}_{variant}")


def plot_speedup(byN, Ns, Ps, outdir, tag, variant):
    if not Ps:
        return
    baseP = Ps[0]
    plt.figure(figsize=(10, 6))
    for P in Ps:
        ns, sus = [], []
        for N in Ns:
            base_vals = byN.get(N, {}).get(baseP, [])
            p_vals = byN.get(N, {}).get(P, [])
            if base_vals and p_vals:
                mb = mean(base_vals)
                mp = mean(p_vals)
                if mp > 0 and mb > 0:
                    ns.append(N)
                    sus.append(mb / mp)
        if ns:
            plt.plot(ns, sus, marker="o", label=f"P={P}")
    label = VARIANT_LABELS.get(variant, variant)
    plt.title(f"Parallel Merge Sort ({label}): Speedup vs Input Size", fontsize=12)
    plt.xlabel("Input Size (N)", fontsize=11)
    plt.ylabel(f"Speedup (baseline P={baseP})", fontsize=11)
    plt.grid(True, ls=":", lw=0.8)
    plt.legend(title="Processors", fontsize=9)
    plt.tight_layout()
    _save(outdir, f"speedup_{tag}_{variant}")


def plot_efficiency(byN, Ns, Ps, outdir, tag, variant):
    if not Ps:
        return
    baseP = Ps[0]
    plt.figure(figsize=(10, 6))
    for P in Ps:
        ns, effs = [], []
        for N in Ns:
            base_vals = byN.get(N, {}).get(baseP, [])
            p_vals = byN.get(N, {}).get(P, [])
            if base_vals and p_vals:
                mb = mean(base_vals)
                mp = mean(p_vals)
                if mp > 0 and mb > 0:
                    ns.append(N)
                    effs.append((mb / mp) / P)
        if ns:
            plt.plot(ns, effs, marker="o", label=f"P={P}")
    label = VARIANT_LABELS.get(variant, variant)
    plt.title(f"Parallel Merge Sort ({label}): Parallel Efficiency vs Input Size", fontsize=12)
    plt.xlabel("Input Size (N)", fontsize=11)
    plt.ylabel("Efficiency (Speedup / P)", fontsize=11)
    plt.grid(True, ls=":", lw=0.8)
    plt.legend(title="Processors", fontsize=9)
    plt.tight_layout()
    _save(outdir, f"efficiency_{tag}_{variant}")


def plot_compare_runtime(data, Ns, outdir, tag):
    """Overlay best-P runtime for each variant."""
    STYLES = [
        dict(marker="o", capsize=3, color="tab:blue", ls="-"),
        dict(marker="s", capsize=3, color="tab:orange", ls="-"),
        dict(marker="D", capsize=3, color="tab:green", ls="-"),
    ]
    plt.figure(figsize=(10, 6))
    si = 0
    for variant in ("super", "ghc", "parpseq"):
        if variant not in data:
            continue
        byN = data[variant]
        ns, mus, sds, best_p_at_max = [], [], [], 0
        for N in Ns:
            if N not in byN:
                continue
            best_m, best_s, best_P = float("inf"), 0, 0
            for P, vals in byN[N].items():
                m = mean(vals)
                if m < best_m:
                    best_m = m
                    best_s = stdev(vals) if len(vals) >= 2 else 0.0
                    best_P = P
            if best_m < float("inf"):
                ns.append(N)
                mus.append(best_m)
                sds.append(best_s)
                best_p_at_max = best_P
        if ns:
            label = f"{VARIANT_LABELS.get(variant, variant)}, P={best_p_at_max}"
            plt.errorbar(ns, mus, yerr=sds, label=label, **STYLES[si])
        si += 1
    plt.title("Parallel Merge Sort: Best Runtime per System", fontsize=12)
    plt.xlabel("Input Size (N)", fontsize=11)
    plt.ylabel("Runtime (s)", fontsize=11)
    plt.grid(True, ls=":", lw=0.8)
    plt.legend(fontsize=9)
    plt.tight_layout()
    _save(outdir, f"compare_best_{tag}")


def plot_compare_speedup(data, Ns, outdir, tag):
    """Overlay best speedup for each variant."""
    STYLES = [
        dict(marker="o", color="tab:blue", ls="-"),
        dict(marker="s", color="tab:orange", ls="-"),
        dict(marker="D", color="tab:green", ls="-"),
    ]
    plt.figure(figsize=(10, 6))
    si = 0
    for variant in ("super", "ghc", "parpseq"):
        if variant not in data:
            continue
        byN = data[variant]
        ns, best_sus, best_p_at_max = [], [], 0
        for N in Ns:
            if N not in byN:
                continue
            base_vals = byN[N].get(1, byN[N].get(min(byN[N].keys()), []))
            if not base_vals:
                continue
            mb = mean(base_vals)
            best_su, best_P = 1.0, 1
            for P, vals in byN[N].items():
                mp = mean(vals)
                if mp > 0 and mb > 0:
                    su = mb / mp
                    if su > best_su:
                        best_su = su
                        best_P = P
            ns.append(N)
            best_sus.append(best_su)
            best_p_at_max = best_P
        if ns:
            label = f"{VARIANT_LABELS.get(variant, variant)}, P={best_p_at_max}"
            plt.plot(ns, best_sus, label=label, **STYLES[si])
        si += 1
    plt.title("Parallel Merge Sort: Best Speedup per System", fontsize=12)
    plt.xlabel("Input Size (N)", fontsize=11)
    plt.ylabel("Speedup (baseline P=1)", fontsize=11)
    plt.grid(True, ls=":", lw=0.8)
    plt.legend(fontsize=9)
    plt.tight_layout()
    _save(outdir, f"compare_speedup_{tag}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--metrics", required=True, nargs="+")
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--tag", required=True)
    args = ap.parse_args()
    os.makedirs(args.outdir, exist_ok=True)

    data = read_metrics(*args.metrics)
    if not data:
        print("[plot] no data"); return

    all_Ns = sorted({N for v in data for N in data[v]})
    all_Ps = sorted({P for v in data for N in data[v] for P in data[v][N]})

    # Per-variant plots
    for variant in sorted(data.keys()):
        byN = data[variant]
        Ns = sorted(byN.keys())
        Ps = sorted({P for N in byN for P in byN[N]})
        plot_runtime(byN, Ns, Ps, args.outdir, args.tag, variant)
        plot_speedup(byN, Ns, Ps, args.outdir, args.tag, variant)
        plot_efficiency(byN, Ns, Ps, args.outdir, args.tag, variant)

    # Comparison plots (when 2+ variants present)
    if len(data) >= 2:
        plot_compare_runtime(data, all_Ns, args.outdir, args.tag)
        plot_compare_speedup(data, all_Ns, args.outdir, args.tag)

    print(f"[plot] all plots saved in {args.outdir}")


if __name__ == "__main__":
    main()
