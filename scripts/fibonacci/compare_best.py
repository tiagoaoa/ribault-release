#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Fibonacci: compare 3 systems (TALM, GHC Strategies, GHC par/pseq)."""

import argparse, csv, os
from collections import defaultdict
from statistics import median, pstdev
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

def read_metrics(path, variant):
    """Read raw metrics CSV, return dict: (N,cutoff,P) -> [seconds]"""
    data = defaultdict(list)
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            if r.get("variant","") != variant: continue
            if int(r["rc"]) != 0: continue
            key = (int(r["N"]), int(r["cutoff"]), int(r["P"]))
            data[key].append(float(r["seconds"]))
    return data

def aggregate(data, trim=1):
    """Return dict: (N,cutoff,P) -> (median, std)"""
    out = {}
    for key, vals in data.items():
        vals = sorted(vals)
        if trim > 0 and len(vals) > 2*trim:
            vals = vals[trim:-trim]
        m = median(vals)
        s = pstdev(vals) if len(vals) > 1 else 0.0
        out[key] = (m, s)
    return out

def best_P_per_N_cutoff(agg):
    """For each (N,cutoff), pick P with lowest median at that (N,cutoff)."""
    groups = defaultdict(list)
    for (N, cutoff, P), (m, s) in agg.items():
        groups[(N, cutoff)].append((P, m, s))
    best = {}
    for (N, cutoff), entries in groups.items():
        entries.sort(key=lambda x: x[1])
        P, m, s = entries[0]
        best[(N, cutoff)] = (P, m, s)
    return best

STYLES = [
    dict(fmt="-o", capsize=3, color="tab:blue"),
    dict(fmt="-s", capsize=3, color="tab:orange"),
    dict(fmt="-D", capsize=3, color="tab:green"),
]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--metrics-talm",    required=True)
    ap.add_argument("--metrics-ghc",     required=True)
    ap.add_argument("--metrics-parpseq", default=None)
    ap.add_argument("--outdir",          required=True)
    ap.add_argument("--tag",             required=True)
    args = ap.parse_args()
    os.makedirs(args.outdir, exist_ok=True)

    sources = []
    if os.path.isfile(args.metrics_talm):
        d = read_metrics(args.metrics_talm, "super")
        if d:
            sources.append(("Ribault (TALM)", aggregate(d), STYLES[0]))
    if os.path.isfile(args.metrics_ghc):
        d = read_metrics(args.metrics_ghc, "ghc")
        if d:
            sources.append(("GHC Strategies", aggregate(d), STYLES[1]))
    if args.metrics_parpseq and os.path.isfile(args.metrics_parpseq):
        d = read_metrics(args.metrics_parpseq, "parpseq")
        if d:
            sources.append(("GHC par/pseq", aggregate(d), STYLES[2]))

    if len(sources) < 2:
        print("[compare] need at least 2 variants"); return

    # Collect all cutoff values
    all_cutoffs = set()
    for label, agg, style in sources:
        for (N, cutoff, P) in agg:
            all_cutoffs.add(cutoff)

    # Plot: for each cutoff, runtime vs N (best P per system)
    for cutoff in sorted(all_cutoffs):
        plt.figure()
        for label, agg, style in sources:
            best = best_P_per_N_cutoff(agg)
            Ns = sorted(N for (N, c) in best if c == cutoff)
            if not Ns: continue
            mus = [best[(N, cutoff)][1] for N in Ns]
            sds = [best[(N, cutoff)][2] for N in Ns]
            Pbest = best[(Ns[-1], cutoff)][0]
            plt.errorbar(Ns, mus, yerr=sds,
                         label=f"{label}, P={Pbest}", **style)
        plt.title(f"Fibonacci: Runtime vs N (cutoff={cutoff}, best P)", fontsize=12)
        plt.xlabel("N", fontsize=11)
        plt.ylabel("Runtime (seconds)", fontsize=11)
        plt.grid(True, linestyle=":", linewidth=0.8)
        plt.legend(fontsize=9)
        plt.tight_layout()
        for ext in ("png","pdf"):
            fn = os.path.join(args.outdir, f"compare_best_{args.tag}_cutoff{cutoff}.{ext}")
            plt.savefig(fn, dpi=180)
        plt.close()

    print(f"[compare] plots saved in {args.outdir}")

if __name__ == "__main__":
    main()
