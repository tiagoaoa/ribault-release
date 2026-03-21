#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import argparse, csv, math, os
from collections import defaultdict
import statistics as stats
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

# ---------------- IO & agregação ----------------

def _to_int(x, d=0):
    try: return int(x)
    except: return d

def _to_float(x):
    try: return float(x)
    except: return float("nan")

def read_metrics(path):
    """
    Lê CSV de métricas (dyck_super / dyck_hs).
    Retorna dict[(imb,delta,N,P)] -> list[seconds] (somente rc==0).
    Aceita coluna 'seconds' ou 'secs'.
    """
    acc = defaultdict(list)
    with open(path, newline="") as f:
        rdr = csv.DictReader(f)
        sec_key = "seconds" if "seconds" in rdr.fieldnames else ("secs" if "secs" in rdr.fieldnames else None)
        if sec_key is None:
            raise SystemExit(f"[err] '{path}' não tem coluna 'seconds' ou 'secs'.")
        has_imb   = "imb"   in rdr.fieldnames
        has_delta = "delta" in rdr.fieldnames
        for r in rdr:
            if _to_int(r.get("rc","0")) != 0:
                continue
            N     = _to_int(r.get("N","0"))
            P     = _to_int(r.get("P","0"))
            imb   = _to_int(r.get("imb","0"))   if has_imb   else 0
            delta = _to_int(r.get("delta","0")) if has_delta else 0
            sec   = _to_float(r.get(sec_key,"nan"))
            if not math.isnan(sec):
                acc[(imb, delta, N, P)].append(sec)
    return acc

def reduce_stats(acc):
    """ dict[(imb,delta,N,P)] -> (mean, std, reps) """
    out = {}
    for k, vs in acc.items():
        if not vs: continue
        mu = sum(vs)/len(vs)
        sd = stats.stdev(vs) if len(vs) > 1 else 0.0
        out[k] = (mu, sd, len(vs))
    return out

# ---------------- helpers de seleção ----------------

def Ns_for(stats_map, imb, delta):
    return sorted({N for (i,d,N,_) in stats_map.keys() if (i,d)==(imb,delta)})

def Ps_for(stats_map, imb, delta, N):
    return sorted({P for (i,d,n,P) in stats_map.keys() if (i,d,n)==(imb,delta,N)})

def largest_common_N(statsA, statsB, imb, delta):
    NsA = set(Ns_for(statsA, imb, delta))
    NsB = set(Ns_for(statsB, imb, delta))
    com = NsA & NsB
    return max(com) if com else None

def pick_best_P(stats_map, imb, delta, N):
    """ P com menor média de tempo. Retorna (P, mean, std, reps) """
    Ps = Ps_for(stats_map, imb, delta, N)
    if not Ps: return None
    cands = [(P,)+stats_map[(imb,delta,N,P)] for P in Ps]
    cands.sort(key=lambda t: t[1])
    return cands[0]

# ---------------- speedup ----------------

def speedup_series(stats_map, imb, delta, N, Pvals, Pmin):
    """
    S(P) = T(Pmin)/T(P) para cada P em Pvals.
    Retorna (S, Ssd).
    """
    mu0, sd0, _ = stats_map[(imb,delta,N,Pmin)]
    S, Ssd = [], []
    for P in Pvals:
        mu, sd, _ = stats_map[(imb,delta,N,P)]
        if mu <= 0 or mu0 <= 0:
            S.append(float("nan")); Ssd.append(float("nan")); continue
        s = mu0/mu
        a = (sd0/mu0) if mu0>0 else 0.0
        b = (sd/mu)   if mu>0  else 0.0
        ssd = s * math.sqrt(a*a + b*b)
        S.append(s); Ssd.append(ssd)
    return S, Ssd

# ---------------- plot principal ----------------

def plot_digest_for_imb(stats_rb, stats_hs, imb, delta, Nopt, outdir, tag):
    """
    Para (imb, delta) fixos:
      - escolhe N = Nopt, ou então o MAIOR N comum se Nopt for None;
      - usa apenas os P em comum;
      - plota UMA figura com 2 subplots: Runtime (topo) e Speedup (base).
    """
    os.makedirs(outdir, exist_ok=True)

    # N alvo
    if Nopt is None:
        N = largest_common_N(stats_rb, stats_hs, imb, delta)
        if N is None:
            raise SystemExit(f"[err] não há N comum para imb={imb}, delta={delta}.")
    else:
        N = Nopt
        Ns_rb = set(Ns_for(stats_rb, imb, delta))
        Ns_hs = set(Ns_for(stats_hs, imb, delta))
        if not (N in Ns_rb and N in Ns_hs):
            raise SystemExit(f"[err] N={N} não existe nos dois CSVs para imb={imb}, delta={delta}.")

    # P em comum
    Ps_rb = set(Ps_for(stats_rb, imb, delta, N))
    Ps_hs = set(Ps_for(stats_hs, imb, delta, N))
    Ps_common = sorted(Ps_rb & Ps_hs)
    if not Ps_common:
        raise SystemExit(f"[err] sem P comum para (imb={imb}, delta={delta}, N={N}).")

    Pmin = min(Ps_common)

    # séries de runtime
    mu_rb = [stats_rb[(imb,delta,N,P)][0] for P in Ps_common]
    sd_rb = [stats_rb[(imb,delta,N,P)][1] for P in Ps_common]
    mu_hs = [stats_hs[(imb,delta,N,P)][0] for P in Ps_common]
    sd_hs = [stats_hs[(imb,delta,N,P)][1] for P in Ps_common]

    # speedup por sistema (baseline = Pmin em comum)
    S_rb, Ssd_rb = speedup_series(stats_rb, imb, delta, N, Ps_common, Pmin)
    S_hs, Ssd_hs = speedup_series(stats_hs, imb, delta, N, Ps_common, Pmin)

    # picks (melhor P por sistema)
    best_rb = pick_best_P(stats_rb, imb, delta, N)
    best_hs = pick_best_P(stats_hs, imb, delta, N)
    if best_rb and best_hs:
        Pr, mur, sdr, nr = best_rb
        Ph, muh, sdh, nh = best_hs
        ratio = mur/muh if (mur>0 and muh>0) else float("nan")
        print(f"[pick] (imb={imb}, delta={delta}, N={N})  "
              f"best: Ribault P={Pr} ({mur:.4g}±{sdr:.2g}s), "
              f"Haskell P={Ph} ({muh:.4g}±{sdh:.2g}s), "
              f"ratio_rb/hs={ratio:.3g}")

    # --- figura única com 2 subplots ---
    fig = plt.figure(figsize=(7.2, 6.4))

    # (1) Runtime no topo
    ax1 = fig.add_subplot(2,1,1)
    ax1.errorbar(Ps_common, mu_rb, yerr=sd_rb, marker="o", label="Ribault")
    ax1.errorbar(Ps_common, mu_hs, yerr=sd_hs, marker="s", label="Haskell (parallel)")
    ax1.set_xlabel("Threads (P)")
    ax1.set_ylabel("Runtime (s)")
    ax1.grid(True, linestyle=":", linewidth=0.8)
    ax1.legend()
    ax1.set_title(f"Runtime vs P  —  N={N}, imb={imb}, δ={delta}")

    # (2) Speedup na base
    ax2 = fig.add_subplot(2,1,2)
    ax2.errorbar(Ps_common, S_rb, yerr=Ssd_rb, marker="o", label="Ribault")
    ax2.errorbar(Ps_common, S_hs, yerr=Ssd_hs, marker="s", label="Haskell (parallel)")
    ax2.set_xlabel("Threads (P)")
    ax2.set_ylabel(f"Speedup vs P={Pmin}")
    ax2.grid(True, linestyle=":", linewidth=0.8)
    ax2.legend()

    fig.tight_layout()
    f_png = os.path.join(outdir, f"{tag}_imb{imb}_d{delta}_N{N}.png")
    f_pdf = os.path.join(outdir, f"{tag}_imb{imb}_d{delta}_N{N}.pdf")
    fig.savefig(f_png, dpi=180); fig.savefig(f_pdf)
    print(f"[plot] {f_png}")
    plt.close(fig)

# ---------------- main ----------------

def main():
    ap = argparse.ArgumentParser(
        description="Digest para um desbalanceamento fixo: figura única com Runtime (topo) + Speedup (base)."
    )
    ap.add_argument("--metrics-super", required=True, help="CSV do Ribault (dyck)")
    ap.add_argument("--metrics-hs",    required=True, help="CSV do Haskell baseline (dyck_hs)")
    ap.add_argument("--imb",           required=True, type=int, help="Desbalanceamento fixo (e.g., 1, 50, 75)")
    ap.add_argument("--delta",         type=int, default=0, help="Delta (padrão 0)")
    ap.add_argument("--N",             type=int, default=None, help="N fixo (opcional). Se ausente, usa maior N comum.")
    ap.add_argument("--outdir",        required=True)
    ap.add_argument("--tag",           required=True)
    args = ap.parse_args()

    rb = reduce_stats(read_metrics(args.metrics_super))
    hs = reduce_stats(read_metrics(args.metrics_hs))

    plot_digest_for_imb(rb, hs, args.imb, args.delta, args.N, args.outdir, args.tag)

if __name__ == "__main__":
    main()
