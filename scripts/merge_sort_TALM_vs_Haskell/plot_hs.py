#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import argparse, csv, os, math
from collections import defaultdict
from statistics import median, pstdev
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

def read_rows(metrics_path):
    rows = []
    variant_found = None
    with open(metrics_path, newline="") as f:
        cr = csv.DictReader(f)
        for row in cr:
            try:
                v  = row.get("variant","")
                N  = int(row["N"])
                P  = int(row["P"])
                rc = int(row["rc"])
                if rc != 0:
                    continue
                t  = float(row["seconds"])
            except Exception:
                continue
            if variant_found is None:
                variant_found = v
            rows.append((N, P, t))
    return rows, variant_found or "ghc"

def aggregate(rows, trim=1):
    g = defaultdict(list)         # (P,N) -> [times]
    for N, P, t in rows:
        g[(P, N)].append(t)

    stats = {}
    byP = defaultdict(list)
    for (P, N), vals in g.items():
        vals.sort()
        vals_sorted = sorted(vals)
        if trim > 0 and len(vals_sorted) > (2 * trim):
            vals_used = vals_sorted[trim:-trim]
        else:
            vals_used = vals_sorted
        m = median(vals_used)
        s = pstdev(vals_used) if len(vals_used) > 1 else 0.0
        byP[P].append((N, m, s, len(vals_used)))

    for P, entries in byP.items():
        entries.sort(key=lambda x: x[0])
        Ns   = [e[0] for e in entries]
        mus  = [e[1] for e in entries]
        sigs = [e[2] for e in entries]
        cnts = [e[3] for e in entries]
        stats[P] = {"Ns": Ns, "mean": mus, "std": sigs, "count": cnts}
    return stats

def save_aggregated_csv(stats, outdir, tag, variant="ghc"):
    path = os.path.join(outdir, f"metrics_aggregated_{tag}.csv")
    with open(path, "w", newline="") as f:
        cw = csv.writer(f)
        cw.writerow(["variant","N","P","reps","median_seconds","std_seconds"])
        for P in sorted(stats.keys()):
            Ns=stats[P]["Ns"]; mus=stats[P]["mean"]; sigs=stats[P]["std"]; cnts=stats[P]["count"]
            for N, m, s, c in zip(Ns, mus, sigs, cnts):
                cw.writerow([variant, N, P, c, f"{m:.6f}", f"{s:.6f}"])
    print(f"[plot] aggregated CSV: {path}")
    return path

def _common_points(stats, P, baseP):
    NsP, muP, sdP = stats[P]["Ns"], stats[P]["mean"], stats[P]["std"]
    NsB, muB, sdB = stats[baseP]["Ns"], stats[baseP]["mean"], stats[baseP]["std"]
    mp = dict(zip(NsP, zip(muP, sdP))); mb = dict(zip(NsB, zip(muB, sdB)))
    Ns = sorted(set(NsP).intersection(NsB))
    out=[]
    for N in Ns:
        mP,sP=mp[N]; mB,sB=mb[N]
        if mP>0 and mB>0: out.append((N,mP,sP,mB,sB))
    return out

def plot_runtime(stats, outdir, tag):
    plt.figure()
    for P in sorted(stats.keys()):
        Ns=stats[P]["Ns"]; mus=stats[P]["mean"]; sigs=stats[P]["std"]
        if not Ns: continue
        plt.errorbar(Ns, mus, yerr=sigs, fmt="-o", capsize=3, label=f"P = {P}")
    plt.title("Merge Sort (GHC -N): Runtime vs Input Size", fontsize=12)
    plt.xlabel("Input size N", fontsize=11)
    plt.ylabel("Runtime (seconds)", fontsize=11)
    plt.grid(True, linestyle=":", linewidth=0.8)
    plt.legend(title="Threads", fontsize=9)
    plt.tight_layout()
    for ext in ("png","pdf"):
        fn=os.path.join(outdir, f"runtime_{tag}.{ext}"); plt.savefig(fn, dpi=180)

def plot_speedup(stats, outdir, tag, baselineP=None):
    Ps = sorted(stats.keys())
    if not Ps: return
    baseP = baselineP if (baselineP in Ps) else Ps[0]
    plt.figure()
    for P in Ps:
        pts=_common_points(stats,P,baseP)
        if not pts: continue
        Ns=[N for (N, *_) in pts]
        sp=[mB/mP for (_N,mP,sP,mB,sB) in pts]
        yerr=[]
        for (_N,mP,sP,mB,sB) in pts:
            r=mB/mP; term=0.0
            if mB>0: term+=(sB/mB)**2
            if mP>0: term+=(sP/mP)**2
            yerr.append(r*math.sqrt(term) if term>0 else 0.0)
        plt.errorbar(Ns, sp, yerr=yerr, fmt="-o", capsize=3, label=f"P = {P}")
    plt.title(f"Merge Sort (GHC -N): Parallel Speedup (baseline P = {baseP})", fontsize=12)
    plt.xlabel("Input size N", fontsize=11)
    plt.ylabel("Speedup", fontsize=11)
    plt.grid(True, linestyle=":", linewidth=0.8)
    plt.legend(title="Threads", fontsize=9)
    plt.tight_layout()
    for ext in ("png","pdf"):
        fn=os.path.join(outdir, f"speedup_{tag}.{ext}"); plt.savefig(fn, dpi=180)

def plot_efficiency(stats, outdir, tag, baselineP=None):
    Ps = sorted(stats.keys())
    if not Ps: return
    baseP = baselineP if (baselineP in Ps) else Ps[0]
    plt.figure()
    for P in Ps:
        pts=_common_points(stats,P,baseP)
        if not pts: continue
        Ns=[N for (N, *_) in pts]
        sp=[mB/mP for (_N,mP,sP,mB,sB) in pts]
        yerr_sp=[]
        for (_N,mP,sP,mB,sB) in pts:
            r=mB/mP; term=0.0
            if mB>0: term+=(sB/mB)**2
            if mP>0: term+=(sP/mP)**2
            yerr_sp.append(r*math.sqrt(term) if term>0 else 0.0)
        eff=[s/float(P) for s in sp]
        yerr=[e/float(P) for e in yerr_sp]
        plt.errorbar(Ns, eff, yerr=yerr, fmt="-o", capsize=3, label=f"P = {P}")
    plt.title(f"Merge Sort (GHC -N): Parallel Efficiency (baseline P = {baseP})", fontsize=12)
    plt.xlabel("Input size N", fontsize=11)
    plt.ylabel("Efficiency", fontsize=11)
    plt.grid(True, linestyle=":", linewidth=0.8)
    plt.legend(title="Threads", fontsize=9)
    plt.tight_layout()
    for ext in ("png","pdf"):
        fn=os.path.join(outdir, f"efficiency_{tag}.{ext}"); plt.savefig(fn, dpi=180)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--metrics", required=True)
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--trim", type=int, default=1,
                    help="Drop N min/max samples before aggregating (default: 1)")
    ap.add_argument("--baselineP", type=int, default=None)
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    rows, variant = read_rows(args.metrics)
    if not rows:
        print("[plot] no data to plot"); return
    stats = aggregate(rows, trim=args.trim)
    save_aggregated_csv(stats, args.outdir, args.tag, variant=variant)
    plot_runtime(stats, args.outdir, args.tag)
    plot_speedup(stats, args.outdir, args.tag, baselineP=args.baselineP)
    plot_efficiency(stats, args.outdir, args.tag, baselineP=args.baselineP)

if __name__ == "__main__":
    main()
