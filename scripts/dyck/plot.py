#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Plot Dyck path benchmark results.

Reads one or more CSV files (with 'variant' column: super, ghc).
Produces per-variant plots (runtime, speedup, efficiency) and,
when both variants are present, comparison plots.

Supports multi-N data:
  - Single N: plots with IMB on X-axis (same as before).
  - Multiple N: per-N subdir plots + summary plots (runtime vs N, heatmap).
"""

import argparse, csv, os, math
from collections import defaultdict
import statistics as stats
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

# ── data loading ──────────────────────────────────────────────

def read_metrics(*paths):
    """Read CSV files.  Returns data[variant][delta][N][P][IMB] = [secs...], sorted Ns."""
    data = defaultdict(lambda: defaultdict(lambda: defaultdict(
               lambda: defaultdict(lambda: defaultdict(list)))))
    Ns = set()
    for path in paths:
        with open(path, newline="") as f:
            for row in csv.DictReader(f):
                try:
                    variant = row["variant"].strip()
                    N       = int(row["N"])
                    P       = int(row["P"])
                    imb     = int(row["imb"])
                    delta   = int(row["delta"])
                    sec     = float(row["seconds"])
                    rc      = int(row["rc"])
                except Exception:
                    continue
                if rc != 0 or not math.isfinite(sec):
                    continue
                Ns.add(N)
                data[variant][delta][N][P][imb].append(sec)
    return data, sorted(Ns)

# ── helpers ───────────────────────────────────────────────────

def series_stats(series):
    """series: IMB -> [secs...].  Returns IMBs, means, stds."""
    IMBs = sorted(series.keys())
    means, stds = [], []
    for imb in IMBs:
        xs = series[imb]
        means.append(stats.mean(xs))
        stds.append(stats.stdev(xs) if len(xs) >= 2 else 0.0)
    return IMBs, means, stds

def best_runtime(byP):
    """byP[P][IMB] = [secs...].  For each IMB, min mean across P.
    Returns (IMBs, best_means, best_Ps)."""
    all_imbs = sorted({imb for P in byP for imb in byP[P]})
    best, best_Ps = [], []
    for imb in all_imbs:
        cands = [(stats.mean(byP[P][imb]), P) for P in byP
                 if imb in byP[P] and byP[P][imb]]
        if cands:
            val, p = min(cands)
            best.append(val); best_Ps.append(p)
        else:
            best.append(float('nan')); best_Ps.append(0)
    return all_imbs, best, best_Ps

def _save(outdir, base):
    os.makedirs(outdir, exist_ok=True)
    plt.savefig(os.path.join(outdir, base + ".png"), dpi=180)
    plt.savefig(os.path.join(outdir, base + ".pdf"))
    plt.close()
    print(f"[plot] saved {base}.png/.pdf")

def _select_imbs(byN):
    """Select representative IMB values from available data."""
    all_imbs = sorted({imb for N in byN for P in byN[N] for imb in byN[N][P]})
    if not all_imbs:
        return []
    targets = [0, 25, 50, 75, 100]
    selected = []
    for t in targets:
        closest = min(all_imbs, key=lambda x: abs(x - t))
        if closest not in selected:
            selected.append(closest)
    return selected

# ── per-N plots (IMB on X-axis) ─────────────────────────────

def plot_runtime(byP, outdir, tag, N, delta):
    plt.figure(figsize=(10, 6))
    for P in sorted(byP):
        xs, mu, sd = series_stats(byP[P])
        if xs:
            plt.errorbar(xs, mu, yerr=sd, marker="o", capsize=3, label=f"P={P}")
    t = f"Dyck Path Validation: Runtime vs Work Imbalance (N={N:,})"
    if delta: t += f", \u03b4={delta}"
    plt.title(t, fontsize=12); plt.xlabel("Work Imbalance (%)", fontsize=11); plt.ylabel("Runtime (s)", fontsize=11)
    plt.grid(True, ls=":", lw=.8); plt.legend(title="Processors"); plt.tight_layout()
    _save(outdir, f"runtime_{tag}_delta{delta}")

def plot_speedup(byP, outdir, tag, N, delta):
    Ps = sorted(byP)
    if not Ps: return
    bP = Ps[0]; bmap = dict(zip(*series_stats(byP[bP])[:2]))
    plt.figure(figsize=(10, 6))
    for P in Ps:
        xs, mu, _ = series_stats(byP[P])
        si, sv = [], []
        for imb, t in zip(xs, mu):
            if imb in bmap and t > 0:
                si.append(imb); sv.append(bmap[imb] / t)
        if si: plt.plot(si, sv, marker="o", label=f"P={P}")
    t = f"Dyck Path Validation: Speedup vs Work Imbalance (N={N:,})"
    if delta: t += f", \u03b4={delta}"
    plt.title(t, fontsize=12); plt.xlabel("Work Imbalance (%)", fontsize=11); plt.ylabel(f"Speedup (baseline P={bP})", fontsize=11)
    plt.grid(True, ls=":", lw=.8); plt.legend(title="Processors"); plt.tight_layout()
    _save(outdir, f"speedup_{tag}_delta{delta}")

def plot_efficiency(byP, outdir, tag, N, delta):
    Ps = sorted(byP)
    if not Ps: return
    bP = Ps[0]; bmap = dict(zip(*series_stats(byP[bP])[:2]))
    plt.figure(figsize=(10, 6))
    for P in Ps:
        xs, mu, _ = series_stats(byP[P])
        ei, ev = [], []
        for imb, t in zip(xs, mu):
            if imb in bmap and t > 0:
                ei.append(imb); ev.append((bmap[imb] / t) / P)
        if ei: plt.plot(ei, ev, marker="o", label=f"P={P}")
    t = f"Dyck Path Validation: Parallel Efficiency vs Work Imbalance (N={N:,})"
    if delta: t += f", \u03b4={delta}"
    plt.title(t, fontsize=11); plt.xlabel("Work Imbalance (%)", fontsize=11); plt.ylabel("Efficiency (Speedup / P)", fontsize=11)
    plt.grid(True, ls=":", lw=.8); plt.legend(title="Processors"); plt.tight_layout()
    _save(outdir, f"efficiency_{tag}_delta{delta}")

# ── comparison plots (per-N) ────────────────────────────────

def plot_compare_runtime(data, outdir, tag, N, delta):
    """All variant P-curves, each with a unique color."""
    plt.figure(figsize=(10, 6))
    colors = plt.cm.tab10.colors
    ci = 0
    variant_styles = [
        ('super',  '-',  's', 'TALM'),
        ('ghc',    '--', 'o', 'GHC Strategies'),
        ('parpseq','-.', 'D', 'GHC par/pseq'),
    ]
    for variant, ls, mk, vlbl in variant_styles:
        if variant not in data or delta not in data[variant]:
            continue
        for P in sorted(data[variant][delta]):
            xs, mu, sd = series_stats(data[variant][delta][P])
            plt.errorbar(xs, mu, yerr=sd, color=colors[ci % len(colors)],
                         ls=ls, marker=mk, ms=5, capsize=3, lw=1.8,
                         label=f'{vlbl} P={P}')
            ci += 1
    plt.title(f"Dyck Path Validation: Runtime Comparison (N={N:,})", fontsize=12)
    plt.xlabel("Work Imbalance (%)", fontsize=11); plt.ylabel("Runtime (s)", fontsize=11)
    plt.grid(True, ls=":", lw=.8); plt.legend(fontsize=8, ncol=2); plt.tight_layout()
    _save(outdir, f"compare_runtime_{tag}_delta{delta}")

def plot_compare_speedup(data, outdir, tag, N, delta):
    """Speedup comparison: all variants, each relative to own P=1. Unique color per curve."""
    plt.figure(figsize=(10, 6))
    colors = plt.cm.tab10.colors
    ci = 0
    variant_styles = [
        ('super',  '-',  'TALM'),
        ('ghc',    '--', 'GHC Strategies'),
        ('parpseq','-.', 'GHC par/pseq'),
    ]
    for variant, ls, vlbl in variant_styles:
        if variant not in data or delta not in data[variant]:
            continue
        byP = data[variant][delta]
        Ps = sorted(byP)
        if not Ps: continue
        bP = Ps[0]; bmap = dict(zip(*series_stats(byP[bP])[:2]))
        for P in Ps:
            xs, mu, _ = series_stats(byP[P])
            si, sv = [], []
            for imb, t in zip(xs, mu):
                if imb in bmap and t > 0:
                    si.append(imb); sv.append(bmap[imb] / t)
            if si:
                plt.plot(si, sv, ls, color=colors[ci % len(colors)],
                         marker='o', ms=5, lw=1.8, label=f'{vlbl} P={P}')
            ci += 1
    plt.title(f"Dyck Path Validation: Speedup Comparison (N={N:,})", fontsize=12)
    plt.xlabel("Work Imbalance (%)", fontsize=11); plt.ylabel("Speedup (baseline P=1)", fontsize=11)
    plt.grid(True, ls=":", lw=.8); plt.legend(fontsize=8, ncol=2); plt.tight_layout()
    _save(outdir, f"compare_speedup_{tag}_delta{delta}")

def plot_compare_best(data, outdir, tag, N, delta):
    """Best-of-each-variant runtime comparison, annotated with chosen P."""
    plt.figure(figsize=(10, 6))
    styles = {
        'super':  ('k-',   's', 'TALM best',          'black'),
        'ghc':    ('r--',  'D', 'GHC Strategies best', 'red'),
        'parpseq':('g-.', '^', 'GHC par/pseq best',   'green'),
    }
    for variant in ('super', 'ghc', 'parpseq'):
        if variant not in data or delta not in data[variant]:
            continue
        imbs, best, best_Ps = best_runtime(data[variant][delta])
        ls, mk, lbl, clr = styles[variant]
        plt.plot(imbs, best, ls, marker=mk, ms=7, lw=2.5, label=lbl)
        for x, y, p in zip(imbs, best, best_Ps):
            plt.annotate(f'P={p}', (x, y), textcoords="offset points",
                         xytext=(0, 10), ha='center', fontsize=7, color=clr)
    plt.title(f"Dyck Path Validation: Best Runtime per System (N={N:,})", fontsize=12)
    plt.xlabel("Work Imbalance (%)", fontsize=11); plt.ylabel("Runtime (s)", fontsize=11)
    plt.grid(True, ls=":", lw=.8); plt.legend(fontsize=11); plt.tight_layout()
    _save(outdir, f"compare_best_{tag}_delta{delta}")

# ── summary plots (N on X-axis, multi-N only) ───────────────

def plot_runtime_vs_N(byN, outdir, tag, Ns, delta, selected_imbs=None):
    """For each selected IMB: runtime vs N with curves for P."""
    if selected_imbs is None:
        selected_imbs = _select_imbs(byN)
    Ps = sorted({P for N in byN for P in byN[N]})
    for imb in selected_imbs:
        plt.figure(figsize=(10, 6))
        for P in Ps:
            ns, mus, sds = [], [], []
            for N in Ns:
                if N in byN and P in byN[N] and imb in byN[N][P] and byN[N][P][imb]:
                    ns.append(N)
                    vals = byN[N][P][imb]
                    mus.append(stats.mean(vals))
                    sds.append(stats.stdev(vals) if len(vals) >= 2 else 0.0)
            if ns:
                plt.errorbar(ns, mus, yerr=sds, marker='o', capsize=3, label=f'P={P}')
        t = f"Dyck Path Validation: Runtime vs Input Size (IMB={imb}%)"
        if delta: t += f", \u03b4={delta}"
        plt.title(t, fontsize=12); plt.xlabel("Input Size (N)", fontsize=11); plt.ylabel("Runtime (s)", fontsize=11)
        plt.grid(True, ls=":", lw=.8); plt.legend(title="Processors"); plt.tight_layout()
        _save(outdir, f"runtime_vs_N_{tag}_imb{imb}_delta{delta}")

def plot_speedup_vs_N(byN, outdir, tag, Ns, delta, selected_imbs=None):
    """For each selected IMB: speedup vs N with curves for P."""
    if selected_imbs is None:
        selected_imbs = _select_imbs(byN)
    Ps = sorted({P for N in byN for P in byN[N]})
    if not Ps:
        return
    base_P = Ps[0]
    for imb in selected_imbs:
        plt.figure(figsize=(10, 6))
        base_map = {}
        for N in Ns:
            if N in byN and base_P in byN[N] and imb in byN[N][base_P] and byN[N][base_P][imb]:
                base_map[N] = stats.mean(byN[N][base_P][imb])
        for P in Ps:
            ns, sus = [], []
            for N in Ns:
                if N in byN and P in byN[N] and imb in byN[N][P] and byN[N][P][imb]:
                    if N in base_map and base_map[N] > 0:
                        mu = stats.mean(byN[N][P][imb])
                        if mu > 0:
                            ns.append(N)
                            sus.append(base_map[N] / mu)
            if ns:
                plt.plot(ns, sus, marker='o', label=f'P={P}')
        t = f"Dyck Path Validation: Speedup vs Input Size (IMB={imb}%)"
        if delta: t += f", \u03b4={delta}"
        plt.title(t, fontsize=12); plt.xlabel("Input Size (N)", fontsize=11); plt.ylabel(f"Speedup (baseline P={base_P})", fontsize=11)
        plt.grid(True, ls=":", lw=.8); plt.legend(title="Processors"); plt.tight_layout()
        _save(outdir, f"speedup_vs_N_{tag}_imb{imb}_delta{delta}")

def plot_heatmap_best(byN, outdir, tag, Ns, delta):
    """Heatmap of best runtime across P, indexed by (N, IMB)."""
    all_imbs = sorted({imb for N in byN for P in byN[N] for imb in byN[N][P]})
    if not all_imbs or not Ns:
        return
    grid = []
    for N in Ns:
        row = []
        for imb in all_imbs:
            best_val = float('inf')
            for P in byN.get(N, {}):
                if imb in byN[N][P] and byN[N][P][imb]:
                    mu = stats.mean(byN[N][P][imb])
                    if mu < best_val:
                        best_val = mu
            row.append(best_val if best_val < float('inf') else float('nan'))
        grid.append(row)

    fig, ax = plt.subplots(figsize=(14, 8))
    im = ax.imshow(grid, aspect='auto', origin='lower', cmap='viridis')
    fig.colorbar(im, ax=ax, label='Best Runtime (s)')
    # X ticks (IMB)
    step_x = max(1, len(all_imbs) // 20)
    ax.set_xticks(range(0, len(all_imbs), step_x))
    ax.set_xticklabels([str(all_imbs[i]) for i in range(0, len(all_imbs), step_x)], fontsize=8)
    # Y ticks (N)
    ax.set_yticks(range(len(Ns)))
    ax.set_yticklabels([f"{N // 1000}k" for N in Ns], fontsize=8)
    ax.set_xlabel('Work Imbalance (%)', fontsize=11); ax.set_ylabel('Input Size (N)', fontsize=11)
    t = f"Dyck Path Validation: Best Runtime Heatmap"
    if delta: t += f" (\u03b4={delta})"
    ax.set_title(t, fontsize=12)
    plt.tight_layout()
    _save(outdir, f"heatmap_best_{tag}_delta{delta}")

def plot_heatmap_speedup(byN, outdir, tag, Ns, delta):
    """Heatmap of best speedup (vs P=1) across P, indexed by (N, IMB)."""
    all_imbs = sorted({imb for N in byN for P in byN[N] for imb in byN[N][P]})
    Ps = sorted({P for N in byN for P in byN[N]})
    if not all_imbs or not Ns or not Ps:
        return
    base_P = Ps[0]

    grid = []
    for N in Ns:
        row = []
        base_val = None
        for imb in all_imbs:
            if N in byN and base_P in byN[N] and imb in byN[N][base_P] and byN[N][base_P][imb]:
                base_val_imb = stats.mean(byN[N][base_P][imb])
            else:
                base_val_imb = None
            best_su = 1.0
            if base_val_imb and base_val_imb > 0:
                for P in Ps:
                    if N in byN and P in byN[N] and imb in byN[N][P] and byN[N][P][imb]:
                        mu = stats.mean(byN[N][P][imb])
                        if mu > 0:
                            su = base_val_imb / mu
                            if su > best_su:
                                best_su = su
            row.append(best_su)
        grid.append(row)

    fig, ax = plt.subplots(figsize=(14, 8))
    im = ax.imshow(grid, aspect='auto', origin='lower', cmap='RdYlGn')
    fig.colorbar(im, ax=ax, label=f'Best Speedup vs P={base_P}')
    step_x = max(1, len(all_imbs) // 20)
    ax.set_xticks(range(0, len(all_imbs), step_x))
    ax.set_xticklabels([str(all_imbs[i]) for i in range(0, len(all_imbs), step_x)], fontsize=8)
    ax.set_yticks(range(len(Ns)))
    ax.set_yticklabels([f"{N // 1000}k" for N in Ns], fontsize=8)
    ax.set_xlabel('Work Imbalance (%)', fontsize=11); ax.set_ylabel('Input Size (N)', fontsize=11)
    t = f"Dyck Path Validation: Best Speedup Heatmap"
    if delta: t += f" (\u03b4={delta})"
    ax.set_title(t, fontsize=12)
    plt.tight_layout()
    _save(outdir, f"heatmap_speedup_{tag}_delta{delta}")

# ── main ──────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--metrics", required=True, nargs="+",
                    help="One or more CSV files (variant column distinguishes super/ghc)")
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--tag", required=True)
    args = ap.parse_args()
    os.makedirs(args.outdir, exist_ok=True)

    data, Ns = read_metrics(*args.metrics)
    if not data:
        print("[plot] no data to plot"); return

    variants = sorted(data.keys())
    multi_N = len(Ns) > 1

    # Per-variant, per-N plots
    for v in variants:
        vtag = f"{args.tag}_{v}"
        for delta in sorted(data[v]):
            byN = data[v][delta]
            for N in Ns:
                if N not in byN:
                    continue
                byP = byN[N]
                if not byP:
                    continue
                if multi_N:
                    subdir = os.path.join(args.outdir, f"N_{N}")
                else:
                    subdir = args.outdir
                plot_runtime(byP, subdir, vtag, N, delta)
                plot_speedup(byP, subdir, vtag, N, delta)
                plot_efficiency(byP, subdir, vtag, N, delta)

            # Summary plots (multi-N only)
            if multi_N:
                plot_runtime_vs_N(byN, args.outdir, vtag, Ns, delta)
                plot_speedup_vs_N(byN, args.outdir, vtag, Ns, delta)
                plot_heatmap_best(byN, args.outdir, vtag, Ns, delta)
                plot_heatmap_speedup(byN, args.outdir, vtag, Ns, delta)

    # Comparison plots (when both variants present)
    if len(variants) >= 2:
        all_deltas = sorted({d for v in variants for d in data[v]})
        for delta in all_deltas:
            for N in Ns:
                # Build per-N flat view: cmp[variant][delta][P][IMB]
                cmp = {}
                for v in variants:
                    if v in data and delta in data[v] and N in data[v][delta]:
                        cmp[v] = {delta: data[v][delta][N]}
                if len(cmp) < 2:
                    continue
                if multi_N:
                    subdir = os.path.join(args.outdir, f"N_{N}")
                else:
                    subdir = args.outdir
                plot_compare_runtime(cmp, subdir, args.tag, N, delta)
                plot_compare_speedup(cmp, subdir, args.tag, N, delta)
                plot_compare_best(cmp, subdir, args.tag, N, delta)

if __name__ == "__main__":
    main()
