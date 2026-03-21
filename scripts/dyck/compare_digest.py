#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import argparse, csv, math, os
from collections import defaultdict
import statistics as stats
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

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
            if _to_int(r.get("rc","0")) != 0:  # só sucessos
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
    """
    Calcula média, desvio e reps por célula.
    Retorna dict[(imb,delta,N,P)] = (mean, std, reps)
    """
    out = {}
    for k, vs in acc.items():
        if not vs: continue
        mu = sum(vs)/len(vs)
        sd = stats.stdev(vs) if len(vs) > 1 else 0.0
        out[k] = (mu, sd, len(vs))
    return out

def scenarios(stats_map):
    """ Conjunto de (imb,delta). """
    return sorted({(i,d) for (i,d,_,_) in stats_map.keys()})

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
    cands = [(P,)+stats_map[(imb,delta,N,P)] for P in Ps_for(stats_map,imb,delta,N)]
    if not cands: return None
    cands.sort(key=lambda t: t[1])
    return cands[0]

def ratio_and_err(mu_rb, sd_rb, mu_hs, sd_hs):
    """ R = mu_rb / mu_hs ; σ_R via propagação de erro relativa. """
    if mu_rb<=0 or mu_hs<=0:
        return float("nan"), float("nan")
    R = mu_rb / mu_hs
    a = (sd_rb/mu_rb) if mu_rb>0 else 0.0
    b = (sd_hs/mu_hs) if mu_hs>0 else 0.0
    sdR = R * math.sqrt(a*a + b*b)
    return R, sdR

def speedup_series(stats_map, imb, delta, N, Pmin):
    """
    Speedup e erro (propagação) vs P.
    S(P) = T(Pmin)/T(P).
    """
    Ps = Ps_for(stats_map, imb, delta, N)
    if Pmin not in Ps: return None, None, None
    mu0, sd0, _ = stats_map[(imb,delta,N,Pmin)]
    S, Ssd, Pvals = [], [], []
    for P in Ps:
        mu, sd, _ = stats_map[(imb,delta,N,P)]
        if mu<=0 or mu0<=0:
            S.append(float("nan")); Ssd.append(float("nan")); Pvals.append(P); continue
        s = mu0/mu
        a = (sd0/mu0) if mu0>0 else 0.0
        b = (sd/mu)   if mu>0  else 0.0
        ssd = s * math.sqrt(a*a + b*b)
        S.append(s); Ssd.append(ssd); Pvals.append(P)
    return Pvals, S, Ssd

def efficiency_from_speedup(Pvals, S, Pmin):
    """ Eficiência E(P) = S(P) / (P/Pmin). """
    E = []
    for P, s in zip(Pvals, S):
        E.append( (s / (P/float(Pmin))) if s and P>0 else float("nan") )
    return E

def plot_scenario(stats_rb, stats_hs, imb, delta, N, outdir, tag, side_label):
    """
    Um cenário em UMA figura com 2 subplots:
      (1) Runtime vs P, com barras de erro;
      (2) Speedup vs P, com barras de erro + rótulos de eficiência.
    Também anota melhores P de cada sistema e imprime resumo no terminal.
    """
    os.makedirs(outdir, exist_ok=True)

    Ps_rb = set(Ps_for(stats_rb, imb, delta, N))
    Ps_hs = set(Ps_for(stats_hs, imb, delta, N))
    Ps_common = sorted(Ps_rb & Ps_hs)
    if not Ps_common:
        print(f"[warn] sem P comum em (imb={imb}, delta={delta}, N={N})")
        return

    Pmin = min(Ps_common)

    # séries de runtime
    mu_rb = [stats_rb[(imb,delta,N,P)][0] for P in Ps_common]
    sd_rb = [stats_rb[(imb,delta,N,P)][1] for P in Ps_common]
    mu_hs = [stats_hs[(imb,delta,N,P)][0] for P in Ps_common]
    sd_hs = [stats_hs[(imb,delta,N,P)][1] for P in Ps_common]

    # speedup
    Pvals_rb, S_rb, Ssd_rb = speedup_series(stats_rb, imb, delta, N, Pmin)
    Pvals_hs, S_hs, Ssd_hs = speedup_series(stats_hs, imb, delta, N, Pmin)

    # eficiência (rótulos)
    E_rb = efficiency_from_speedup(Pvals_rb, S_rb, Pmin)
    E_hs = efficiency_from_speedup(Pvals_hs, S_hs, Pmin)

    # picks (melhor P por sistema)
    best_rb = pick_best_P(stats_rb, imb, delta, N)
    best_hs = pick_best_P(stats_hs, imb, delta, N)
    txt_pick = ""
    if best_rb and best_hs:
        Pr, mur, sdr, nr = best_rb
        Ph, muh, sdh, nh = best_hs
        R, Rsd = ratio_and_err(mur, sdr, muh, sdh)
        txt_pick = f"best: rb P={Pr} ({mur:.3g}±{sdr:.2g}s), hs P={Ph} ({muh:.3g}±{sdh:.2g}s), ratio={R:.3g}"
        print(f"[pick] (imb={imb}, delta={delta}, N={N})  {txt_pick}")

    # === figura ===
    fig = plt.figure(figsize=(7.2, 6.4))  # suficiente p/ duas subplots legíveis

    # (1) Runtime
    ax1 = fig.add_subplot(2,1,1)
    ax1.errorbar(Ps_common, mu_rb, yerr=sd_rb, marker="o", label="Ribault")
    ax1.errorbar(Ps_common, mu_hs, yerr=sd_hs, marker="s", label="Haskell (parallel)")
    ax1.set_xlabel("Threads (P)")
    ax1.set_ylabel("Runtime (s)")
    ax1.grid(True, linestyle=":", linewidth=0.8)
    ax1.legend()
    ax1.set_title(f"[{side_label}] Runtime vs Number of Threads for  N={N}, imb={imb}, δ={delta}")

    # (2) Speedup + eficiência (rótulos)
    ax2 = fig.add_subplot(2,1,2)
    ax2.errorbar(Pvals_rb, S_rb, yerr=Ssd_rb, marker="o", label="Ribault")
    ax2.errorbar(Pvals_hs, S_hs, yerr=Ssd_hs, marker="s", label="Haskell (parallel)")
    ax2.set_xlabel("Threads (P)")
    ax2.set_ylabel(f"Speedup vs P={Pmin}")
    ax2.grid(True, linestyle=":", linewidth=0.8)
    ax2.legend()

    # rótulos de eficiência
    def _annotate(Ps, S, E):
        for p,s,e in zip(Ps, S, E):
            if s is None or math.isnan(s): continue
            ax2.annotate(f"η={e:.2f}", xy=(p, s), xytext=(0,6),
                         textcoords="offset points", ha="center", va="bottom", fontsize=8)

    ##_annotate(Pvals_rb, S_rb, E_rb)
   ##  _annotate(Pvals_hs, S_hs, E_hs)

    fig.tight_layout()
    f_png = os.path.join(outdir, f"{tag}_{side_label}_imb{imb}_d{delta}_N{N}.png")
    f_pdf = os.path.join(outdir, f"{tag}_{side_label}_imb{imb}_d{delta}_N{N}.pdf")
    fig.savefig(f_png, dpi=180); fig.savefig(f_pdf)
    print(f"[plot] {f_png}")
    plt.close(fig)

def summarize_best_worst(stats_rb, stats_hs, outdir, tag):
    """
    Escolhe 2 cenários no N máximo comum:
      - BEST: menor razão (Ribault/Haskell)
      - WORST: maior razão
    E plota cada um.
    """
    picks = []
    for (imb,delta) in sorted(set(scenarios(stats_rb)) & set(scenarios(stats_hs))):
        Nstar = largest_common_N(stats_rb, stats_hs, imb, delta)
        if Nstar is None: 
            continue
        rb = pick_best_P(stats_rb, imb, delta, Nstar)
        hs = pick_best_P(stats_hs, imb, delta, Nstar)
        if not rb or not hs: 
            continue
        Pr, mur, sdr, _ = rb
        Ph, muh, sdh, _ = hs
        R, Rsd = ratio_and_err(mur, sdr, muh, sdh)
        if math.isnan(R): 
            continue
        picks.append((R, (imb,delta), Nstar, rb, hs))

    if not picks:
        print("[warn] não há cenários comuns com dados suficientes.")
        return

    picks.sort(key=lambda t: t[0])       # menor razão primeiro (melhor p/ Ribault)
    best  = picks[0]
    worst = picks[-1]

    # salvar CSV resumo
    os.makedirs(outdir, exist_ok=True)
    csvp = os.path.join(outdir, f"digest_{tag}.csv")
    with open(csvp, "w", newline="") as f:
        wr = csv.writer(f)
        wr.writerow(["case","imb","delta","N",
                     "rb_P","rb_mean","rb_std",
                     "hs_P","hs_mean","hs_std",
                     "ratio_rb_over_hs"])
        for name, item in [("best",best), ("worst",worst)]:
            R, (imb,delta), Nstar, rb, hs = item
            Pr, mur, sdr, _ = rb
            Ph, muh, sdh, _ = hs
            wr.writerow([name, imb, delta, Nstar, Pr, mur, sdr, Ph, muh, sdh, R])
    print(f"[csv] {csvp}")

    # plots (um arquivo por cenário; total 2 gráficos)
    Rb, (imbb, deltab), Nb, rb_b, hs_b = best
    plot_scenario(stats_rb, stats_hs, imbb, deltab, Nb, outdir, tag, "BEST")

    Rw, (imbw, deltaw), Nw, rb_w, hs_w = worst
    plot_scenario(stats_rb, stats_hs, imbw, deltaw, Nw, outdir, tag, "WORST")

def main():
    ap = argparse.ArgumentParser(description="Resumo sucinto: dois cenários (melhor e pior) com runtime, speedup e eficiência.")
    ap.add_argument("--metrics-super", required=True, help="CSV Ribault (dyck)")
    ap.add_argument("--metrics-hs",    required=True, help="CSV Haskell baseline (dyck_hs)")
    ap.add_argument("--outdir",        required=True)
    ap.add_argument("--tag",           required=True)
    args = ap.parse_args()

    rb = reduce_stats(read_metrics(args.metrics_super))
    hs = reduce_stats(read_metrics(args.metrics_hs))

    summarize_best_worst(rb, hs, args.outdir, args.tag)

if __name__ == "__main__":
    main()
