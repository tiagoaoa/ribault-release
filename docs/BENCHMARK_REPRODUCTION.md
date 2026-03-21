# Reproduzindo os Benchmarks: Merge Sort e Caminho de Dyck

Guia completo para reproduzir os benchmarks de **Merge Sort** e **Caminho de Dyck** comparando Ribault (TALM) vs GHC.

---

## 1. Dependencias

### Sistema

| Dependencia | Versao testada | Comando de verificacao |
|-------------|---------------|----------------------|
| GHC         | 8.10.7+       | `ghc --version`      |
| gcc         | qualquer      | `gcc --version`      |
| Python 3    | 3.8+          | `python3 --version`  |
| make        | qualquer      | `make --version`     |
| alex        | qualquer      | `alex --version`     |
| happy       | qualquer      | `happy --version`    |

### Pacotes GHC (ja vem com GHC, mas precisam ser expostos)

- `time` (merge sort GHC)
- `deepseq` (merge sort e dyck GHC)
- `parallel` (merge sort e dyck GHC)

Verificar:
```bash
ghc-pkg list | grep -E 'time|deepseq|parallel'
```

### Pacotes Python

```bash
pip3 install matplotlib numpy pandas
```

- `matplotlib` — graficos
- `numpy` — usado nos plots do dyck
- `pandas` — usado no compare_best do dyck

---

## 2. Compilar o projeto

```bash
cd /caminho/para/Ribault

# Compilar o compilador Ribault (codegen, supersgen, etc.)
make

# Compilar o interpretador TALM
make -C TALM/interp clean && make -C TALM/interp

# Verificar que tudo foi gerado
ls codegen supersgen TALM/interp/interp
```

Os tres binarios devem existir: `codegen`, `supersgen`, `TALM/interp/interp`.

---

## 3. Benchmark: Merge Sort (TALM vs GHC)

### 3a. Rodar TALM (Ribault)

```bash
PY2=python3 \
PY3=python3 \
MS_LEAF=array \
DF_LIST_BUILTIN=1 \
SUPERS_FORCE_PAR=1 \
bash scripts/merge_sort_TALM_vs_Haskell/run.sh \
  --start-N 50000 \
  --step 50000 \
  --n-max 1000000 \
  --reps 10 \
  --procs "1,2,4,8" \
  --interp TALM/interp/interp \
  --asm-root TALM/asm \
  --codegen . \
  --outroot RESULTS/mergesort \
  --vec range \
  --plots yes \
  --tag ms_super
```

Saida: `RESULTS/mergesort/metrics_ms_super.csv` (dados brutos) e `RESULTS/mergesort/metrics_aggregated_ms_super.csv` (mediana + std).

### 3b. Rodar GHC

```bash
GHC_PKGS="-package time -package deepseq -package parallel" \
bash scripts/merge_sort_TALM_vs_Haskell/run_hs.sh \
  --start-N 50000 \
  --step 50000 \
  --n-max 1000000 \
  --reps 10 \
  --procs "1,2,4,8" \
  --outroot RESULTS/mergesort_ghc \
  --vec range \
  --tag ghc_ms
```

Saida: `RESULTS/mergesort_ghc/metrics_ghc_ms.csv` (dados brutos) e `RESULTS/mergesort_ghc/metrics_aggregated_ghc_ms.csv` (mediana + std).

### 3c. Gerar grafico de comparacao

```bash
python3 scripts/merge_sort_TALM_vs_Haskell/compare_best.py \
  --agg-super RESULTS/mergesort/metrics_aggregated_ms_super.csv \
  --agg-ghc RESULTS/mergesort_ghc/metrics_aggregated_ghc_ms.csv \
  --outdir RESULTS/mergesort \
  --tag ms_compare
```

Saida: `RESULTS/mergesort/compare_best_ms_compare.png` e `.pdf`.

---

## 4. Benchmark: Caminho de Dyck (TALM vs GHC)

### 4a. Rodar tudo de uma vez (recomendado)

O script `run_compare.sh` roda TALM + GHC + gera graficos automaticamente:

```bash
PY2=python3 \
bash scripts/dyck/run_compare.sh \
  --N "50000,100000,150000,200000,250000,300000,350000,400000,450000,500000,550000,600000,650000,700000,750000,800000,850000,900000,950000,1000000" \
  --reps 10 \
  --procs "1,2,4,8" \
  --imb "0,25,50,75,100" \
  --delta "0" \
  --interp TALM/interp/interp \
  --asm-root TALM/asm \
  --codegen . \
  --outroot RESULTS/dyck_N_IMB_sweep \
  --tag dyck
```

Saida:
- `RESULTS/dyck_N_IMB_sweep/metrics_dyck_super.csv` — TALM
- `RESULTS/dyck_N_IMB_sweep/metrics_dyck_ghc.csv` — GHC
- Graficos de runtime, speedup e eficiencia por N e IMB (`.png` e `.pdf`)

### 4b. Gerar grafico de comparacao best-of-breed

```bash
python3 scripts/dyck/compare_best.py \
  --metrics-super RESULTS/dyck_N_IMB_sweep/metrics_dyck_super.csv \
  --metrics-hs RESULTS/dyck_N_IMB_sweep/metrics_dyck_ghc.csv \
  --outdir RESULTS/dyck_N_IMB_sweep \
  --tag dyck
```

---

## 5. O que cada benchmark mede

### Merge Sort

- **Entrada**: vetor `[N, N-1, ..., 1]` (pior caso)
- **TALM**: divide-and-conquer paralelo via dataflow, supers em C puro (array com size embutido). `init_super` gera o vetor, `sort_leaf` ordena folhas, `merge_pair` faz merge, `verify_sorted` checa que a saida esta ordenada e imprime 1/0.
- **GHC**: `Control.Parallel.Strategies` com `rpar`/`rseq` e `force`, compilado com `-threaded -rtsopts`, executado com `+RTS -N<P>`.
- **Guarda de corretude**: toda execucao TALM verifica que o vetor saiu ordenado. Se nao saiu, `rc=99` e o dado nao conta.

### Caminho de Dyck

- **Entrada**: sequencia de parenteses balanceados de tamanho 2N, com desbalanceamento de trabalho configuravel (IMB).
- **TALM**: verificacao paralela via dataflow com supers Haskell.
- **GHC**: mesmo algoritmo paralelo com `par`/`pseq`.
- **Guarda de corretude**: `delta=0` espera resultado 1 (valido), `delta!=0` espera 0 (invalido).

---

## 6. Parametros

| Parametro | Merge Sort | Dyck |
|-----------|-----------|------|
| N (tamanho) | 50K a 1M, passo 50K | 50K a 1M, passo 50K |
| P (cores) | 1, 2, 4, 8 | 1, 2, 4, 8 |
| Reps | 10 | 10 |
| IMB | n/a | 0, 25, 50, 75, 100 |
| Delta | n/a | 0 |

---

## 7. Variaveis de ambiente importantes

| Variavel | Valor | Descricao |
|----------|-------|-----------|
| `PY2` | `python3` | Assembler TALM (aceita python2 ou 3) |
| `PY3` | `python3` | Scripts de geracao e plots |
| `MS_LEAF` | `array` | Modo de merge sort: supers C com arrays |
| `DF_LIST_BUILTIN` | `1` | Listas como celulas C (16 bytes) |
| `SUPERS_FORCE_PAR` | `1` | Desabilita mutex em supers para execucao paralela |
| `GHC_PKGS` | `-package time -package deepseq -package parallel` | Pacotes GHC para o baseline |

---

## 8. Tempo esperado

| Benchmark | TALM (800 runs) | GHC (800 runs) |
|-----------|-----------------|----------------|
| Merge Sort | ~5 minutos | ~30 minutos |
| Dyck (5 IMBs) | ~20 minutos | ~40 minutos |

---

## 9. Resultados esperados (ordem de grandeza)

### Merge Sort (N=1M, melhor P)

| Implementacao | Runtime (mediana) |
|--------------|-------------------|
| Ribault (TALM) | ~0.04s |
| GHC (-N4) | ~0.95s |

Ribault ~22x mais rapido.

### Dyck (N=1M, IMB=0, melhor P)

Ribault significativamente mais rapido que GHC em todos os tamanhos.
