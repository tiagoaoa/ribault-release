#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import argparse, os, sys
import pandas as pd
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

def read_rows(metrics_path):
    df = pd.read_csv(metrics_path)
    df = df[(df["variant"]=="ghc") & (df["rc"]==0)].copy()
    if df.empty:
        print("[plot] WARNING: no successful rows.", file=sys.stderr)
    return df

def agg_mean_std(df):
    g = df.groupby(["N","P","imb","delta"], as_index=False)["seconds"].agg(["mean","std"]).reset_index()
    g.rename(columns={"mean":"mean_seconds","std":"std_seconds"}, inplace=True)
    return g

def runtime_vs_N(g, outdir, tag):
    # one fig per (imb,delta); curves = P; errorbar = std
    for (imb, delta), sub in g.groupby(["imb","delta"]):
        pivot_mu = sub.pivot(index="N", columns="P", values="mean_seconds").sort_index()
        pivot_sd = sub.pivot(index="N", columns="P", values="std_seconds").reindex_like(pivot_mu)
        plt.figure()
        for P in pivot_mu.columns:
            Ns = pivot_mu.index.values
            mu = pivot_mu[P].values
            sd = pivot_sd[P].fillna(0.0).values
            plt.errorbar(Ns, mu, yerr=sd, marker="o", capsize=3, label=f"P={P}")
        plt.title(f"Dyck Path (GHC Parallel): Runtime vs N  (imb={imb}, delta={delta})", fontsize=12)
        plt.xlabel("Input size N", fontsize=11)
        plt.ylabel("Runtime (seconds)", fontsize=11)
        plt.grid(True, linestyle=":", linewidth=0.8)
        plt.legend(title="Threads", fontsize=9)
        plt.tight_layout()
        base = os.path.join(outdir, f"hs_runtime_{tag}_imb{imb}_delta{delta}")
        plt.savefig(base + ".png", dpi=200); plt.savefig(base + ".pdf")
        plt.close()

def speedup_efficiency(g, outdir, tag):
    # baseline = smallest P present
    for (imb, delta), sub in g.groupby(["imb","delta"]):
        Pmin = sub["P"].min()
        base = sub[sub["P"]==Pmin][["N","mean_seconds"]].set_index("N")["mean_seconds"]
        # speedup
        sub2 = sub.copy()
        sub2["speedup"] = sub2.apply(lambda r: float(base.loc[r["N"]])/r["mean_seconds"] if r["N"] in base.index else np.nan, axis=1)
        piv_sp = sub2.pivot(index="P", columns="N", values="speedup").sort_index()

        plt.figure()
        for N in piv_sp.columns:
            plt.plot(piv_sp.index.values, piv_sp[N].values, marker="o", label=f"N={N}")
        plt.title(f"Dyck Path (GHC Parallel): Speedup vs P  (baseline P={Pmin}, imb={imb}, delta={delta})")
        plt.xlabel("Threads (P)")
        plt.ylabel("Speedup (×)")
        plt.grid(True, linestyle=":", linewidth=0.8)
        plt.legend(title="Input size N", fontsize=9)
        plt.tight_layout()
        base = os.path.join(outdir, f"hs_speedup_{tag}_imb{imb}_delta{delta}")
        plt.savefig(base + ".png", dpi=200); plt.savefig(base + ".pdf")
        plt.close()

        # efficiency
        piv_eff = piv_sp.divide(piv_sp.index.values, axis=0)
        plt.figure()
        for N in piv_eff.columns:
            plt.plot(piv_eff.index.values, piv_eff[N].values, marker="o", label=f"N={N}")
        plt.title(f"Dyck Path (GHC Parallel): Efficiency vs P  (baseline P={Pmin}, imb={imb}, delta={delta})")
        plt.xlabel("Threads (P)")
        plt.ylabel("Efficiency")
        plt.grid(True, linestyle=":", linewidth=0.8)
        plt.legend(title="Input size N", fontsize=9)
        plt.tight_layout()
        base = os.path.join(outdir, f"hs_efficiency_{tag}_imb{imb}_delta{delta}")
        plt.savefig(base + ".png", dpi=200); plt.savefig(base + ".pdf")
        plt.close()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--metrics", required=True)
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--tag", required=True)
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    df = read_rows(args.metrics)
    if df.empty: 
        sys.exit(0)
    g = agg_mean_std(df)
    runtime_vs_N(g, args.outdir, args.tag)
    speedup_efficiency(g, args.outdir, args.tag)
    print(f"[plot] saved into {args.outdir}")

if __name__ == "__main__":
    main()
