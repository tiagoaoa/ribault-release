#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate all paper figures following spec_paper_figures_v4.md."""

import csv, os, math, statistics, argparse
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
matplotlib.rcParams.update({
    'font.family': 'serif',
    'font.serif': ['Times New Roman', 'DejaVu Serif'],
    'font.size': 11,
    'axes.labelsize': 12,
    'legend.fontsize': 10,
    'xtick.labelsize': 10,
    'ytick.labelsize': 10,
    'figure.figsize': (6, 4),
    'figure.dpi': 300,
    'savefig.bbox': 'tight',
    'savefig.pad_inches': 0.05,
    'axes.grid': True,
    'grid.alpha': 0.3,
    'grid.linestyle': '--',
    'lines.linewidth': 1.8,
    'lines.markersize': 6,
})
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
import numpy as np

# ── Palettes ──────────────────────────────────────────────────

COMP_COLORS = {
    'super':   '#2166ac',
    'ghc':     '#e08214',
    'parpseq': '#4dac26',
}
COMP_MARKERS = {'super': 'o', 'ghc': 's', 'parpseq': 'D'}
COMP_LABELS = {
    'super':   'Ribault',
    'ghc':     'GHC Strategies',
    'parpseq': 'GHC par/pseq',
}

PER_P_STYLE = {
    1: dict(color='#c6dbef', ls='--', alpha=0.8, lw=1.8),
    2: dict(color='#6baed6', ls='-.', alpha=1.0, lw=1.8),
    4: dict(color='#2171b5', ls='-',  alpha=1.0, lw=1.8),
    8: dict(color='#08306b', ls='-',  alpha=1.0, lw=2.5),
}

# ── Data loading ──────────────────────────────────────────────

def load_csv(path):
    """Load CSV into list of dicts with typed values."""
    rows = []
    with open(path, newline='') as f:
        for row in csv.DictReader(f):
            try:
                r = {}
                r['variant'] = row['variant'].strip()
                r['N'] = int(row['N'])
                r['P'] = int(row['P'])
                r['seconds'] = float(row['seconds'])
                r['rc'] = int(row['rc'])
                if 'imb' in row:
                    r['imb'] = int(row['imb'])
                if 'delta' in row:
                    r['delta'] = int(row['delta'])
                if 'cutoff' in row:
                    r['cutoff'] = int(row['cutoff'])
            except Exception:
                continue
            if r['rc'] != 0 or not math.isfinite(r['seconds']):
                continue
            rows.append(r)
    return rows


def load_all(results_root):
    """Load all benchmark data."""
    data = {}
    # MatMul
    mm = []
    for v in ('talm', 'ghc', 'parpseq'):
        p = os.path.join(results_root, 'matmul', f'metrics_matmul_{v}.csv')
        if os.path.isfile(p):
            mm.extend(load_csv(p))
    for r in mm:
        if r['variant'] == 'talm':
            r['variant'] = 'super'
    data['matmul'] = mm

    # MergeSort
    ms = []
    for v in ('super', 'ghc', 'parpseq'):
        p = os.path.join(results_root, 'mergesort', f'metrics_ms_{v}.csv')
        if os.path.isfile(p):
            ms.extend(load_csv(p))
    data['mergesort'] = ms

    # Dyck
    dk = []
    for v in ('super', 'ghc', 'parpseq'):
        p = os.path.join(results_root, 'dyck_N_IMB_sweep', f'metrics_dyck_{v}.csv')
        if os.path.isfile(p):
            dk.extend(load_csv(p))
    data['dyck'] = dk

    # Fibonacci — file may be named _talm or _super
    fb = []
    for v in ('talm', 'super', 'ghc', 'parpseq'):
        p = os.path.join(results_root, 'fibonacci', f'metrics_fib_{v}.csv')
        if os.path.isfile(p):
            fb.extend(load_csv(p))
    for r in fb:
        if r['variant'] == 'talm':
            r['variant'] = 'super'
    data['fibonacci'] = fb

    return data


# ── Helper functions ──────────────────────────────────────────

def aggregate(times):
    """Median + std, discarding min and max if n > 4."""
    s = sorted(times)
    if len(s) > 4:
        s = s[1:-1]
    med = statistics.median(s)
    sd = statistics.stdev(s) if len(s) > 1 else 0
    return med, sd


def best_config(data, variant, X_values, X_key='N',
                P_values=(1, 2, 4, 8), **filters):
    """For each X, return (median, std, best_P) of the P that minimizes median."""
    results = {}
    for x in X_values:
        best_med, best_std, best_P = float('inf'), 0, 1
        for P in P_values:
            times = [r['seconds'] for r in data
                     if r['variant'] == variant
                     and r[X_key] == x and r['P'] == P
                     and all(r.get(k) == v for k, v in filters.items())]
            if not times:
                continue
            med, sd = aggregate(times)
            if med < best_med:
                best_med, best_std, best_P = med, sd, P
        if best_med < float('inf'):
            results[x] = (best_med, best_std, best_P)
    return results


def per_P_data(data, variant, X_values, X_key='N',
               P_values=(1, 2, 4, 8), **filters):
    """Return {P: {X: (median, std)}}."""
    results = {}
    for P in P_values:
        results[P] = {}
        for x in X_values:
            times = [r['seconds'] for r in data
                     if r['variant'] == variant
                     and r[X_key] == x and r['P'] == P
                     and all(r.get(k) == v for k, v in filters.items())]
            if not times:
                continue
            results[P][x] = aggregate(times)
    return results


def _save(outdir, name):
    os.makedirs(outdir, exist_ok=True)
    plt.savefig(os.path.join(outdir, name + '.pdf'))
    plt.savefig(os.path.join(outdir, name + '.png'), dpi=300)
    plt.close()
    print(f"  [ok] {name}.pdf/.png")


def _comp_label(variant, best_ps):
    """Build legend label: 'System (best P)' or 'System, P=X' if constant."""
    unique_ps = set(best_ps)
    if len(unique_ps) == 1:
        return f"{COMP_LABELS[variant]}, $P$={best_ps[0]}"
    return f"{COMP_LABELS[variant]} (best $P$)"


def plot_comp_errorbar(ax, all_data, X_values, X_key='N',
                       variants=('super', 'ghc', 'parpseq'), **filters):
    """Plot comparative best-config curves with errorbar. Returns dict of results."""
    results = {}
    for v in variants:
        bc = best_config(all_data, v, X_values, X_key=X_key, **filters)
        if not bc:
            continue
        results[v] = bc
        xs = sorted(bc.keys())
        meds = [bc[x][0] for x in xs]
        stds = [bc[x][1] for x in xs]
        best_ps = [bc[x][2] for x in xs]
        lbl = _comp_label(v, best_ps)
        ax.errorbar(xs, meds, yerr=stds,
                    color=COMP_COLORS[v], marker=COMP_MARKERS[v],
                    label=lbl, capsize=2, elinewidth=0.8, alpha=0.5)
        # Re-plot line on top for visibility
        ax.plot(xs, meds, color=COMP_COLORS[v], marker=COMP_MARKERS[v])
    return results


def plot_fixed_P_errorbar(ax, all_data, X_values, fixed_P, X_key='N',
                          variants=('super', 'ghc', 'parpseq'), **filters):
    """Plot curves for a fixed P with errorbar."""
    for v in variants:
        xs, meds, stds = [], [], []
        for x in X_values:
            times = [r['seconds'] for r in all_data
                     if r['variant'] == v and r[X_key] == x and r['P'] == fixed_P
                     and all(r.get(k) == val for k, val in filters.items())]
            if not times:
                continue
            med, sd = aggregate(times)
            xs.append(x)
            meds.append(med)
            stds.append(sd)
        if xs:
            lbl = f"{COMP_LABELS[v]}, $P$={fixed_P}"
            ax.errorbar(xs, meds, yerr=stds,
                        color=COMP_COLORS[v], marker=COMP_MARKERS[v],
                        label=lbl, capsize=2, elinewidth=0.8, alpha=0.5)
            ax.plot(xs, meds, color=COMP_COLORS[v], marker=COMP_MARKERS[v])


def fmt_N_ticks_k(ax):
    """Format X ticks as K/M."""
    def fmt(x, _):
        if x >= 1_000_000:
            return f"{x/1_000_000:.0f}M"
        elif x >= 1000:
            return f"{x/1000:.0f}K"
        return str(int(x))
    ax.xaxis.set_major_formatter(ticker.FuncFormatter(fmt))


# ── PART A: Comparative figures ───────────────────────────────

def fig1_matmul_best_runtime(data, outdir):
    """Fig 1: MatMul best runtime vs N."""
    print("Fig 1: MatMul best runtime")
    mm = data['matmul']
    Ns = sorted({r['N'] for r in mm})
    fig, ax = plt.subplots()
    plot_comp_errorbar(ax, mm, Ns)
    ax.set_title("Matrix Multiply: Best Runtime per System", fontsize=13, fontweight='normal')
    ax.set_xlabel("Matrix dimension $N$")
    ax.set_ylabel("Runtime (s)")
    ax.set_ylim(bottom=0)
    ax.set_xticks([100, 200, 400, 600, 800, 1000])
    ax.legend()
    _save(outdir, "fig1_matmul_best_runtime")


def fig2_matmul_best_speedup(data, outdir):
    """Fig 2: MatMul best speedup vs N."""
    print("Fig 2: MatMul best speedup")
    mm = data['matmul']
    Ns = sorted({r['N'] for r in mm})
    fig, ax = plt.subplots()
    for v in ('super', 'ghc', 'parpseq'):
        bc = best_config(mm, v, Ns)
        # P=1 baseline
        p1 = {}
        for N in Ns:
            times = [r['seconds'] for r in mm
                     if r['variant'] == v and r['N'] == N and r['P'] == 1]
            if times:
                p1[N] = aggregate(times)[0]
        ns, sus, best_ps = [], [], []
        for N in Ns:
            if N in bc and N in p1 and bc[N][0] > 0:
                ns.append(N)
                sus.append(p1[N] / bc[N][0])
                best_ps.append(bc[N][2])
        if ns:
            lbl = _comp_label(v, best_ps)
            ax.errorbar(ns, sus, color=COMP_COLORS[v], marker=COMP_MARKERS[v],
                        label=lbl, capsize=2, elinewidth=0.8, alpha=0.5)
            ax.plot(ns, sus, color=COMP_COLORS[v], marker=COMP_MARKERS[v])
    ax.axhline(y=8, color='gray', ls='--', lw=1, alpha=0.6, label='Ideal ($P{=}8$)')
    ax.set_title("Matrix Multiply: Best Speedup per System", fontsize=13, fontweight='normal')
    ax.set_xlabel("Matrix dimension $N$")
    ax.set_ylabel("Speedup vs. $P{=}1$")
    ax.set_ylim(0, 14)
    ax.legend()
    _save(outdir, "fig2_matmul_best_speedup")


def fig3_ms_best_runtime(data, outdir):
    """Fig 3: MergeSort best runtime vs N (log Y)."""
    print("Fig 3: MergeSort best runtime")
    ms = data['mergesort']
    Ns = sorted({r['N'] for r in ms})
    fig, ax = plt.subplots()
    plot_comp_errorbar(ax, ms, Ns)
    ax.set_yscale('log')
    ax.set_title("Merge Sort: Best Runtime per System", fontsize=13, fontweight='normal')
    ax.set_xlabel("List size $N$")
    ax.set_ylabel("Runtime (s)")
    fmt_N_ticks_k(ax)
    ax.legend()
    _save(outdir, "fig3_ms_best_runtime")


def fig4_ms_advantage(data, outdir):
    """Fig 4: MergeSort advantage ratio vs N."""
    print("Fig 4: MergeSort advantage ratio")
    ms = data['mergesort']
    Ns = sorted({r['N'] for r in ms})
    bc_rib = best_config(ms, 'super', Ns)
    bc_ghc = best_config(ms, 'ghc', Ns)
    bc_pp = best_config(ms, 'parpseq', Ns)
    fig, ax = plt.subplots()
    # vs GHC Strategies
    ns1, r1 = [], []
    for N in Ns:
        if N in bc_rib and N in bc_ghc and bc_rib[N][0] > 0:
            ns1.append(N)
            r1.append(bc_ghc[N][0] / bc_rib[N][0])
    if ns1:
        ax.plot(ns1, r1, color=COMP_COLORS['ghc'], marker=COMP_MARKERS['ghc'],
                label='vs. GHC Strategies')
    # vs GHC par/pseq
    ns2, r2 = [], []
    for N in Ns:
        if N in bc_rib and N in bc_pp and bc_rib[N][0] > 0:
            ns2.append(N)
            r2.append(bc_pp[N][0] / bc_rib[N][0])
    if ns2:
        ax.plot(ns2, r2, color=COMP_COLORS['parpseq'], marker=COMP_MARKERS['parpseq'],
                label='vs. GHC par/pseq')
    ax.axhline(y=1, color='gray', ls='--', lw=1, alpha=0.6)
    ax.set_title("Merge Sort: Ribault Advantage Ratio", fontsize=13, fontweight='normal')
    ax.set_xlabel("List size $N$")
    ax.set_ylabel(r"Ribault speedup ratio ($\times$ faster)")
    fmt_N_ticks_k(ax)
    ax.legend()
    _save(outdir, "fig4_ms_advantage")


def fig5_dyck_imbalance(data, outdir):
    """Fig 5: Dyck runtime vs imbalance (N=1M, P=8, log Y)."""
    print("Fig 5: Dyck runtime vs imbalance")
    dk = data['dyck']
    imbs = sorted({r['imb'] for r in dk
                   if r.get('delta', 0) == 0 and r['N'] == 1000000})
    fig, ax = plt.subplots()
    plot_fixed_P_errorbar(ax, dk, imbs, fixed_P=8, X_key='imb', N=1000000, delta=0)
    ax.set_yscale('log')
    ax.set_title("Dyck Paths: Runtime vs. Workload Imbalance ($P{=}8$)",
                 fontsize=13, fontweight='normal')
    ax.set_xlabel("Workload imbalance (%)")
    ax.set_ylabel("Runtime (s)")
    ax.set_xticks([0, 20, 40, 60, 80, 100])
    ax.legend()
    _save(outdir, "fig5_dyck_imbalance")


def fig6_dyck_collapse_scaling(data, outdir):
    """Fig 6: Dyck runtime vs N (imb=100%, P=8, log Y)."""
    print("Fig 6: Dyck collapse scaling")
    dk = data['dyck']
    Ns = sorted({r['N'] for r in dk if r.get('imb') == 100 and r.get('delta', 0) == 0})
    fig, ax = plt.subplots()
    plot_fixed_P_errorbar(ax, dk, Ns, fixed_P=8, imb=100, delta=0)
    ax.set_yscale('log')
    ax.set_title("Dyck Paths: Worst-Case Scaling ($P{=}8$, 100% Imbalance)",
                 fontsize=13, fontweight='normal')
    ax.set_xlabel("Sequence length $N$")
    ax.set_ylabel("Runtime (s)")
    fmt_N_ticks_k(ax)
    ax.legend()
    _save(outdir, "fig6_dyck_collapse_scaling")


def fig7_summary_barplot(data, outdir):
    """Fig 7: Consolidated barplot (4 groups x 3 bars, log Y)."""
    print("Fig 7: Summary barplot")
    # force_P=8 for Dyck imbalanced to show the GHC collapse
    scenarios = [
        ("MatMul", data['matmul'], dict(N=1000), None),
        ("MergeSort", data['mergesort'], dict(N=1000000), None),
        ("Dyck (bal.)", data['dyck'], dict(N=1000000, imb=0, delta=0), None),
        ("Dyck (imb.)", data['dyck'], dict(N=1000000, imb=100, delta=0), 8),
    ]
    variants = ('super', 'ghc', 'parpseq')
    n_groups = len(scenarios)
    x = np.arange(n_groups)
    width = 0.25

    fig, ax = plt.subplots(figsize=(7, 4.5))
    for i, v in enumerate(variants):
        vals = []
        for label, dset, filt, force_P in scenarios:
            if force_P is not None:
                # Use fixed P
                times = [r['seconds'] for r in dset
                         if r['variant'] == v and r['P'] == force_P
                         and all(r.get(k) == val for k, val in filt.items())]
                if times:
                    med, _ = aggregate(times)
                    vals.append(med)
                else:
                    vals.append(0)
            else:
                # Best P
                best_med = float('inf')
                for P in (1, 2, 4, 8):
                    times = [r['seconds'] for r in dset
                             if r['variant'] == v and r['P'] == P
                             and all(r.get(k) == val for k, val in filt.items())]
                    if not times:
                        continue
                    med, _ = aggregate(times)
                    if med < best_med:
                        best_med = med
                vals.append(best_med if best_med < float('inf') else 0)
        bars = ax.bar(x + i * width, vals, width,
                      color=COMP_COLORS[v], label=COMP_LABELS[v])
        for bar, val in zip(bars, vals):
            if val > 0:
                txt = f'{val:.4f}' if val < 0.01 else (f'{val:.3f}' if val < 1 else f'{val:.2f}')
                ax.annotate(txt,
                            xy=(bar.get_x() + bar.get_width() / 2, bar.get_height()),
                            xytext=(0, 4), textcoords='offset points',
                            ha='center', fontsize=8)
    ax.set_yscale('log')
    ax.set_title("Runtime Comparison Across Benchmarks", fontsize=13, fontweight='normal')
    ax.set_ylabel("Runtime (s)")
    ax.set_xticks(x + width)
    ax.set_xticklabels([s[0] for s in scenarios], fontsize=9)
    # Annotate that Dyck (imb.) uses P=8
    ax.annotate("$P{=}8$", xy=(3 + width, 0), xytext=(0, -18),
                textcoords='offset points', ha='center', fontsize=8,
                color='gray')
    ax.legend()
    _save(outdir, "fig7_summary_barplot")


# ── PART B: Per-P scaling figures ─────────────────────────────

def _plot_per_P(ax, ppdata, x_values):
    """Plot per-P curves with blue gradient. No error bars."""
    for P in sorted(ppdata.keys()):
        xs = sorted(x for x in x_values if x in ppdata[P])
        if not xs:
            continue
        meds = [ppdata[P][x][0] for x in xs]
        style = PER_P_STYLE.get(P, {})
        ax.plot(xs, meds, marker='o', label=f"$P{{=}}{P}$", **style)


def fig8_matmul_ribault_perP(data, outdir):
    """Fig 8: MatMul Ribault runtime vs N per P."""
    print("Fig 8: MatMul Ribault per-P")
    mm = data['matmul']
    Ns = sorted({r['N'] for r in mm if r['variant'] == 'super'})
    ppd = per_P_data(mm, 'super', Ns)
    fig, ax = plt.subplots()
    _plot_per_P(ax, ppd, Ns)
    ax.set_title(r"Matrix Multiply: Ribault Scaling by $P$", fontsize=13, fontweight='normal')
    ax.set_xlabel("Matrix dimension $N$")
    ax.set_ylabel("Runtime (s)")
    ax.set_ylim(bottom=0)
    ax.legend()
    _save(outdir, "fig8_matmul_ribault_perP")


def fig9_ms_ribault_perP(data, outdir):
    """Fig 9: MergeSort Ribault runtime vs N per P."""
    print("Fig 9: MergeSort Ribault per-P")
    ms = data['mergesort']
    Ns = sorted({r['N'] for r in ms if r['variant'] == 'super'})
    ppd = per_P_data(ms, 'super', Ns)
    fig, ax = plt.subplots()
    _plot_per_P(ax, ppd, Ns)
    ax.set_title(r"Merge Sort: Ribault Scaling by $P$", fontsize=13, fontweight='normal')
    ax.set_xlabel("List size $N$")
    ax.set_ylabel("Runtime (s)")
    fmt_N_ticks_k(ax)
    ax.set_ylim(bottom=0)
    ax.legend()
    _save(outdir, "fig9_ms_ribault_perP")


def fig10_dyck_ribault_perP(data, outdir):
    """Fig 10: Dyck Ribault runtime vs imbalance per P (N=1M)."""
    print("Fig 10: Dyck Ribault per-P")
    dk = data['dyck']
    imbs = sorted({r['imb'] for r in dk
                   if r['variant'] == 'super' and r['N'] == 1000000
                   and r.get('delta', 0) == 0})
    ppd = per_P_data(dk, 'super', imbs, X_key='imb', N=1000000, delta=0)
    fig, ax = plt.subplots()
    _plot_per_P(ax, ppd, imbs)
    ax.set_title(r"Dyck Paths: Ribault Scaling by $P$", fontsize=13, fontweight='normal')
    ax.set_xlabel("Workload imbalance (%)")
    ax.set_ylabel("Runtime (s)")
    ax.set_xticks([0, 20, 40, 60, 80, 100])
    ax.legend()
    _save(outdir, "fig10_dyck_ribault_perP")


def fig11_fib_ribault_perP(data, outdir):
    """Fig 11: Fib Ribault runtime vs cutoff per P (N=35, log Y)."""
    print("Fig 11: Fib Ribault per-P")
    fb = data['fibonacci']
    if not fb:
        print("  [skip] no fibonacci data")
        return
    cutoffs = sorted({r['cutoff'] for r in fb
                      if r['variant'] == 'super' and r['N'] == 35})
    if not cutoffs:
        print("  [skip] no Ribault fibonacci data for N=35")
        return
    ppd = per_P_data(fb, 'super', cutoffs, X_key='cutoff', N=35)
    fig, ax = plt.subplots()
    _plot_per_P(ax, ppd, cutoffs)
    ax.set_yscale('log')
    ax.set_title(r"Fibonacci: Ribault Scaling by $P$", fontsize=13, fontweight='normal')
    ax.set_xlabel("Cutoff threshold")
    ax.set_ylabel("Runtime (s)")
    ax.legend()
    _save(outdir, "fig11_fib_ribault_perP")


# ── PART C: Fib comparative ──────────────────────────────────

def fig12_fib_best_runtime(data, outdir):
    """Fig 12: Fib best runtime vs cutoff (3 systems, log Y)."""
    print("Fig 12: Fib best runtime vs cutoff")
    fb = data['fibonacci']
    if not fb:
        print("  [skip] no fibonacci data")
        return
    cutoffs = sorted({r['cutoff'] for r in fb if r['N'] == 35})
    if not cutoffs:
        print("  [skip] no fibonacci data for N=35")
        return
    fig, ax = plt.subplots()
    plot_comp_errorbar(ax, fb, cutoffs, X_key='cutoff', N=35)
    ax.set_yscale('log')
    ax.set_title("Fibonacci: Best Runtime vs. Cutoff", fontsize=13, fontweight='normal')
    ax.set_xlabel("Cutoff threshold")
    ax.set_ylabel("Runtime (s)")
    ax.legend()
    _save(outdir, "fig12_fib_best_runtime")


# ── Main ──────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", default="RESULTS",
                    help="Root results directory")
    ap.add_argument("--outdir", default="RESULTS/paper_figures",
                    help="Output directory for figures")
    args = ap.parse_args()

    print("Loading data...")
    data = load_all(args.results)
    for k, v in data.items():
        print(f"  {k}: {len(v)} rows")

    outdir = args.outdir
    os.makedirs(outdir, exist_ok=True)

    print("\n=== PART A: Comparative figures ===")
    fig1_matmul_best_runtime(data, outdir)
    fig2_matmul_best_speedup(data, outdir)
    fig3_ms_best_runtime(data, outdir)
    fig4_ms_advantage(data, outdir)
    fig5_dyck_imbalance(data, outdir)
    fig6_dyck_collapse_scaling(data, outdir)
    fig7_summary_barplot(data, outdir)

    print("\n=== PART B: Per-P scaling figures ===")
    fig8_matmul_ribault_perP(data, outdir)
    fig9_ms_ribault_perP(data, outdir)
    fig10_dyck_ribault_perP(data, outdir)
    fig11_fib_ribault_perP(data, outdir)

    print("\n=== PART C: Fib comparative ===")
    fig12_fib_best_runtime(data, outdir)

    print(f"\n=== All figures saved in {outdir} ===")
    for f in sorted(os.listdir(outdir)):
        sz = os.path.getsize(os.path.join(outdir, f))
        print(f"  {f:45s} {sz//1024:>4d} KB")


if __name__ == "__main__":
    main()
