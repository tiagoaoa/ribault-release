#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import argparse, os
import pandas as pd
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

def load_variant(path, variant):
    df = pd.read_csv(path)
    df = df[(df["variant"]==variant) & (df["rc"]==0)].copy()
    return df

def mean_std(df):
    g = df.groupby(["N","P","imb","delta"], as_index=False)["seconds"].agg(["mean","std"]).reset_index()
    g.rename(columns={"mean":"mean_seconds","std":"std_seconds"}, inplace=True)
    return g

def pick_best_per_N(g):
    g["rank"] = g.groupby(["N","imb","delta"])["mean_seconds"].rank(method="first")
    best = g[g["rank"]==1].drop(columns=["rank"])
    return best

STYLES = [
    dict(marker="o", capsize=3, color="tab:blue"),   # TALM
    dict(marker="s", capsize=3, color="tab:orange"),  # GHC Strategies
    dict(marker="D", capsize=3, color="tab:green"),   # GHC par/pseq
]

def plot_compare(variants_data, outdir, tag):
    # collect all (imb,delta) keys
    all_keys = set()
    for label, best, style in variants_data:
        keys = set(map(tuple, best[["imb","delta"]].drop_duplicates().values.tolist()))
        all_keys |= keys

    for (imb, delta) in sorted(all_keys):
        plt.figure()
        has_data = False
        for label, best, style in variants_data:
            sub = best[(best["imb"]==imb) & (best["delta"]==delta)]
            if sub.empty: continue
            has_data = True
            plt.errorbar(sub["N"], sub["mean_seconds"],
                         yerr=sub["std_seconds"].fillna(0.0),
                         label=f"{label} (best P)", **style)
        if not has_data:
            plt.close()
            continue
        plt.title(f"Dyck Path: Best-of-Breed Runtime vs N  (imb={imb}, delta={delta})")
        plt.xlabel("Input size N"); plt.ylabel("Runtime (seconds)")
        plt.grid(True, linestyle=":", linewidth=0.8)
        plt.legend()
        plt.tight_layout()
        base = os.path.join(outdir, f"compare_best_{tag}_imb{imb}_delta{delta}")
        plt.savefig(base + ".png", dpi=200); plt.savefig(base + ".pdf")
        plt.close()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--metrics-super",   required=True)
    ap.add_argument("--metrics-hs",      required=True)
    ap.add_argument("--metrics-parpseq", default=None)
    ap.add_argument("--outdir",          required=True)
    ap.add_argument("--tag",             required=True)
    args = ap.parse_args()
    os.makedirs(args.outdir, exist_ok=True)

    variants_data = []

    ds = load_variant(args.metrics_super, "super")
    if not ds.empty:
        gs = mean_std(ds); bs = pick_best_per_N(gs)
        variants_data.append(("Ribault (TALM)", bs, STYLES[0]))

    dh = load_variant(args.metrics_hs, "ghc")
    if not dh.empty:
        gh = mean_std(dh); bh = pick_best_per_N(gh)
        variants_data.append(("GHC Strategies", bh, STYLES[1]))

    if args.metrics_parpseq and os.path.isfile(args.metrics_parpseq):
        dp = load_variant(args.metrics_parpseq, "parpseq")
        if not dp.empty:
            gp = mean_std(dp); bp = pick_best_per_N(gp)
            variants_data.append(("GHC par/pseq", bp, STYLES[2]))

    if len(variants_data) < 2:
        print("[warn] need at least 2 variants to compare.")
        return

    plot_compare(variants_data, args.outdir, args.tag)
    print(f"[compare] saved into {args.outdir}")

if __name__ == "__main__":
    main()
