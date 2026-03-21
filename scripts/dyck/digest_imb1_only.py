#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Digest Dyck (imb=1 FIXO): compara Ribault(super) vs Haskell(parallel),
gera 2 gráficos (runtime vs P e speedup vs P) e imprime melhores P.

Uso exemplo:
  python3 scripts/dyck/digest_imb1_only.py \
    --metrics-super results/dyck/metrics_dyck_super.csv \
    --metrics-hs    results/dyck_hs/metrics_dyck_hs.csv \
    --outdir        results/dyck_compare \
    --tag           dyck_imb1_N20 \
    --N 20 --delta 0

Se --N / --delta não forem passados, o script escolhe automaticamente
um (delta, N) comum (prioriza delta=0 e o maior N disponível).
"""

import argparse, csv, math, os
from collections import defaultdict
import statistics as stats

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

# -------------------- leitura e preparo --------------------

def _i(x, d=0):
    try: return int(x)
    except: return d

def _f(x):
    try: return float(x)
    except: return float("nan")

def read_metrics(path):
    """
    Lê CSV (dyck_super ou dyck_hs) e retorna:
      dict[(delta, N, P)] -> list[seconds]   **COM IMB=1 FIXO**
    Ignora rc != 0.
    """
    acc = defaultdict(list)
    with open(path, newline="") as f:
        rdr = csv.DictReader(f)
        sec_key = "seconds" if "seconds" in rdr.fieldnames else ("secs" if "secs" in rdr.fieldnames else None)
        if sec_key is None:
            raise SystemExit(f"[err] '{path}' não tem coluna 'seconds' ou 'secs'.")

        for r in rdr:
            if _i(r.get("rc","0")) != 0:
                continue
            imb = _i(r.get("imb","0"))
            if imb != 1:
                continue  # FIXO: imb=1

            N     = _i(r.get("N","0"))
            P     = _i(r.get("P","0"))
            delta = _i(r.get("delta","0"))
            sec   = _f(r.get(sec_key,"nan"))

            if math.isnan(sec): continue
            acc[(delta, N, P)].append(sec)
    return acc

def reduce_stats(acc):
    """
    dict[(delta, N, P)] -> (mean, std, reps)
    """
    out = {}
    for k, vs in acc.items():
        if not vs: continue
        mu = sum(vs)/len(vs)
        sd = stats.stdev(vs) if len(vs) > 1 else 0.0
        out[k] = (mu, sd, len(vs))
    return out

def sets_delta(stats_map):
    return sorted({d for (d,_,_) in stats_map.keys()})

def sets_N(stats_map, delta):
    return sorted({N for (d,N,_) in stats_map.keys() if d==delta})

def sets_P(stats_map, delta, N):
    return sorted({P for (d,n,P) in stats_map.keys() if d==delta and n==N})

# -------------------- escolha automática (se necessário) --------------------

def choose_delta_N(rb_stats, hs_stats, arg_delta=None, arg_N=None):
    """
    Retorna (delta, N) comum. Regras:
      - Se arg_delta/arg_N fornecidos, usa-os (erra se não existir em ambos).
      - Caso contrário, tenta delta=0 se comum, senão escolhe o menor delta comum.
      - Para o delta escolhido, pega o MAIOR N comum.
    """
    deltas_rb = {d for (d,_,_) in rb_stats.keys()}
    deltas_hs = {d for (d,_,_) in hs_stats.keys()}
    common_delta = sorted(deltas_rb & deltas_hs)

    if not common_delta:
        raise SystemExit("[err] não há nenhum delta comum entre Ribault e Haskell (com imb=1).")

    if arg_delta is not None:
        if arg_delta not in common_delta:
            raise SystemExit(f"[err] delta={arg_delta} não está presente em ambos os conjuntos.")
        chosen_delta = arg_delta
    else:
        chosen_delta = 0 if 0 in common_delta else common_delta[0]

    Ns_rb = {N for (d,N,_) in rb_stats.keys() if d==chosen_delta}
    Ns_hs = {N for (d,N,_) in hs_stats.keys() if d==chosen_delta}
    common_N = sorted(Ns_rb & Ns_hs)
    if not common_N:
        raise SystemExit(f"[err] não há N comum para delta={chosen_delta}.")

    if arg_N is not None:
        if arg_N not in common_N:
            raise SystemExit(f"[err] N={arg_N} não existe para delta={chosen_delta} em ambos.")
        chosen_N = arg_N
    else:
        chosen_N = common_N[-1]  # maior N comum

    return chosen_delta, chosen_N

# -------------------- speedup, eficiência, best P --------------------

def build_series(stats_map, delta, N):
    """
    Retorna:
      Ps (ordenado), mu[P], sd[P]
    """
    Ps = sets_P(stats_map, delta, N)
    mu = {P: stats_map[(delta,N,P)][0] for P in Ps}
    sd = {P: stats_map[(delta,N,P)][1] for P in Ps}
    return Ps, mu, sd

def common_baseline_P(PsA, PsB):
    common = sorted(set(PsA) & set(PsB))
    return common[0] if common else None

def speedup(Ps, mu, baseP):
    """
    S(P) = T(baseP)/T(P)
    Retorna listas (Pvals, S, Ssd) com propagação de erro simples.
    """
    if baseP not in mu: return [], [], []
    t0 = mu[baseP]
    Pvals, S, Ssd = [], [], []
    for P in Ps:
        t = mu[P]
        if t<=0 or t0<=0:
            Pvals.append(P); S.append(float("nan")); Ssd.append(float("nan"))
        else:
            Pvals.append(P); S.append(t0/t); Ssd.append(float("nan"))
    return Pvals, S, Ssd

def best_P(mu):
    if not mu: return None, None
    Pbest = min(mu, key=lambda p: mu[p])
    return Pbest, mu[Pbest]

# -------------------- plots --------------------

def plot_runtime(Ps, mu_rb, sd_rb, mu_hs, sd_hs, outdir, tag, delta, N):
    plt.figure(figsize=(6.5, 3.6))
    ax = plt.gca()
    if Ps:
        ax.errorbar(Ps, [mu_rb[p] for p in Ps], yerr=[sd_rb[p] for p in Ps],
                    marker="o", capsize=3, label="Ribault (super)")
        ax.errorbar(Ps, [mu_hs[p] for p in Ps], yerr=[sd_hs[p] for p in Ps],
                    marker="s", capsize=3, label="Haskell (parallel)")
    ax.set_title(f"Dyck — Runtime vs P (imb=1, δ={delta}, N={N})", fontsize=11)
    ax.set_xlabel("Threads (P)"); ax.set_ylabel("Runtime (s)")
    ax.grid(True, linestyle=":", linewidth=0.8); ax.legend(fontsize=9)
    plt.tight_layout()
    os.makedirs(outdir, exist_ok=True)
    png = os.path.join(outdir, f"digest_runtime_{tag}.png")
    pdf = os.path.join(outdir, f"digest_runtime_{tag}.pdf")
    plt.savefig(png, dpi=180); plt.savefig(pdf); plt.close()
    print(f"[plot] {png}")

def plot_speedup(Ps_common, mu_rb, mu_hs, outdir, tag, delta, N):
    baseP = common_baseline_P(Ps_common, Ps_common)
    plt.figure(figsize=(6.5, 3.6))
    ax = plt.gca()
    if baseP is None:
        ax.text(0.5,0.5,"No common baseline P",ha="center",va="center",transform=ax.transAxes)
    else:
        Prb, Srb, _ = speedup(Ps_common, mu_rb, baseP)
        Phs, Shs, _ = speedup(Ps_common, mu_hs, baseP)
        ax.plot(Prb, Srb, marker="o", label=f"Ribault (vs P={baseP})")
        ax.plot(Phs, Shs, marker="s", label=f"Haskell (vs P={baseP})")
        ax.set_ylim(bottom=0)
    ax.set_title(f"Dyck — Speedup vs P (imb=1, δ={delta}, N={N})", fontsize=11)
    ax.set_xlabel("Threads (P)"); ax.set_ylabel("Speedup (×)")
    ax.grid(True, linestyle=":", linewidth=0.8); ax.legend(fontsize=9)
    plt.tight_layout()
    os.makedirs(outdir, exist_ok=True)
    png = os.path.join(outdir, f"digest_speedup_{tag}.png")
    pdf = os.path.join(outdir, f"digest_speedup_{tag}.pdf")
    plt.savefig(png, dpi=180); plt.savefig(pdf); plt.close()
    print(f"[plot] {png}")

# -------------------- main --------------------

def main():
    ap = argparse.ArgumentParser(description="Digest Dyck (imb=1 fixo): runtime e speedup vs P.")
    ap.add_argument("--metrics-super", required=True, help="CSV Ribault (dyck)")
    ap.add_argument("--metrics-hs",    required=True, help="CSV Haskell (dyck_hs)")
    ap.add_argument("--outdir",        required=True)
    ap.add_argument("--tag",           required=True)
    ap.add_argument("--N",     type=int, default=None, help="N fixo (opcional)")
    ap.add_argument("--delta", type=int, default=None, help="delta fixo (opcional)")
    args = ap.parse_args()

    # ler e reduzir (imb=1 fixo)
    rb_stats = reduce_stats(read_metrics(args.metrics_super))
    hs_stats = reduce_stats(read_metrics(args.metrics_hs))

    # escolher (delta, N)
    delta, N = choose_delta_N(rb_stats, hs_stats, arg_delta=args.delta, arg_N=args.N)
    print(f"[choose] delta={delta}, N={N} (imb=1)")

    # construir séries por P (apenas Ps comuns)
    Ps_rb, mu_rb, sd_rb = build_series(rb_stats, delta, N)
    Ps_hs, mu_hs, sd_hs = build_series(hs_stats, delta, N)

    Ps_common = sorted(set(Ps_rb) & set(Ps_hs))
    if not Ps_common:
        raise SystemExit("[err] não há nenhum P comum entre Ribault e Haskell para esse (imb=1, delta, N).")

    # restringe aos Ps comuns
    mu_rb = {P: mu_rb[P] for P in Ps_common}
    sd_rb = {P: sd_rb[P] for P in Ps_common}
    mu_hs = {P: mu_hs[P] for P in Ps_common}
    sd_hs = {P: sd_hs[P] for P in Ps_common}

    # melhores P (tempo mínimo)
    Pbest_rb, Tbest_rb = best_P(mu_rb)
    Pbest_hs, Tbest_hs = best_P(mu_hs)
    if Pbest_rb is not None and Pbest_hs is not None:
        ratio = Tbest_hs / Tbest_rb if (Tbest_rb>0 and Tbest_hs>0) else float("nan")
        print(f"[best] Ribault:  P*={Pbest_rb}, mean={Tbest_rb:.6f}s")
        print(f"[best] Haskell:  P*={Pbest_hs}, mean={Tbest_hs:.6f}s")
        print(f"[cmp ] Haskell/Ribault at their own bests ≈ {ratio:.3f}×")

    # plots
    plot_runtime(Ps_common, mu_rb, sd_rb, mu_hs, sd_hs, args.outdir, args.tag, delta, N)
    plot_speedup(Ps_common, mu_rb, mu_hs, args.outdir, args.tag, delta, N)

if __name__ == "__main__":
    main()
