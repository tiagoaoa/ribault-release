#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# run_all_benchmarks.sh — Roda a suite completa de benchmarks:
#   1) Merge Sort      (TALM + GHC Strategies + GHC par/pseq)
#   2) Caminho de Dyck (TALM + GHC Strategies + GHC par/pseq)
#   3) Fibonacci       (TALM + GHC Strategies + GHC par/pseq)
#   4) MatMul          (TALM + GHC Strategies + GHC par/pseq)
# e gera os gráficos de comparação (3 curvas por benchmark).
#
# Uso:
#   bash scripts/run_all_benchmarks.sh [opções]
#
# Opções (todas opcionais — defaults reproduzem os resultados do paper):
#   --start-N   N       Primeiro tamanho (MS/Dyck)       (default: 50000)
#   --step      S       Passo entre tamanhos (MS/Dyck)   (default: 50000)
#   --n-max     M       Último tamanho (MS/Dyck)         (default: 1000000)
#   --reps      R       Repetições por configuração       (default: 10)
#   --procs     P       Cores, separados por vírgula      (default: "1,2,4,8")
#   --outroot   DIR     Diretório base para resultados    (default: RESULTS)
#   --fib-N     CSV     Fibonacci N values                (default: "30,35,40,45")
#   --fib-cutoff CSV    Fibonacci cutoff values           (default: "15,20,25")
#   --matmul-N  CSV     MatMul N values                   (default: "128,256,512,1024")
#   --skip-build        Não recompila o projeto
#   --only-ms           Só roda Merge Sort
#   --only-dyck         Só roda Dyck
#   --only-fib          Só roda Fibonacci
#   --only-matmul       Só roda MatMul
#
# Requisitos:
#   ghc (8.10.7+), gcc, python3, make, alex, happy
#   pip3 install matplotlib numpy pandas
# ============================================================

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ── Defaults ────────────────────────────────────────────────
START_N=50000
STEP=50000
N_MAX=1000000
REPS=10
PROCS_CSV="1,2,4,8"
OUTROOT="$ROOT/RESULTS"
SKIP_BUILD=0
ONLY_MS=0
ONLY_DYCK=0
ONLY_FIB=0
ONLY_MATMUL=0
FIB_N="30,35,40,45"
FIB_CUTOFF="15,20,25"
MATMUL_N="128,256,512,1024"

PY2="${PY2:-python3}"
PY3="${PY3:-python3}"

# ── Parse args ──────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --start-N)    START_N="$2"; shift 2;;
    --step)       STEP="$2"; shift 2;;
    --n-max)      N_MAX="$2"; shift 2;;
    --reps)       REPS="$2"; shift 2;;
    --procs)      PROCS_CSV="$2"; shift 2;;
    --outroot)    OUTROOT="$2"; shift 2;;
    --fib-N)      FIB_N="$2"; shift 2;;
    --fib-cutoff) FIB_CUTOFF="$2"; shift 2;;
    --matmul-N)   MATMUL_N="$2"; shift 2;;
    --skip-build) SKIP_BUILD=1; shift;;
    --only-ms)    ONLY_MS=1; shift;;
    --only-dyck)  ONLY_DYCK=1; shift;;
    --only-fib)   ONLY_FIB=1; shift;;
    --only-matmul) ONLY_MATMUL=1; shift;;
    -h|--help)
      sed -n '2,/^# ====/{ /^# ====/d; s/^# \?//; p }' "$0"
      exit 0;;
    *) echo "[ERRO] flag desconhecida: $1"; exit 2;;
  esac
done

# Se nenhum --only-* foi passado, roda todos
HAVE_ONLY=$(( ONLY_MS + ONLY_DYCK + ONLY_FIB + ONLY_MATMUL ))
RUN_MS=1; RUN_DYCK=1; RUN_FIB=1; RUN_MATMUL=1
if [[ "$HAVE_ONLY" -gt 0 ]]; then
  RUN_MS=$ONLY_MS; RUN_DYCK=$ONLY_DYCK; RUN_FIB=$ONLY_FIB; RUN_MATMUL=$ONLY_MATMUL
fi

# ── Construir N_CSV a partir de start/step/max ──────────────
N_CSV=""
for (( n=START_N; n<=N_MAX; n+=STEP )); do
  [[ -n "$N_CSV" ]] && N_CSV="${N_CSV},"
  N_CSV="${N_CSV}${n}"
done
echo "=== MS/Dyck N values: $N_CSV ==="
echo "=== Fibonacci N: $FIB_N  cutoff: $FIB_CUTOFF ==="
echo "=== MatMul N: $MATMUL_N ==="

# ── Checar dependências ─────────────────────────────────────
check_cmd(){ command -v "$1" >/dev/null 2>&1 || { echo "[ERRO] '$1' não encontrado. Instale-o antes de continuar."; exit 1; }; }
check_cmd ghc
check_cmd gcc
check_cmd python3
check_cmd make

echo "=== Dependências OK ==="

# ── Build ───────────────────────────────────────────────────
if [[ "$SKIP_BUILD" -eq 0 ]]; then
  echo ""
  echo "========================================================"
  echo "  COMPILANDO O PROJETO"
  echo "========================================================"
  make -C "$ROOT"
  make -C "$ROOT/TALM/interp" clean
  make -C "$ROOT/TALM/interp"
  echo "=== Build OK ==="
fi

# Verificar binários
for bin in "$ROOT/codegen" "$ROOT/supersgen" "$ROOT/TALM/interp/interp"; do
  [[ -x "$bin" ]] || { echo "[ERRO] binário não encontrado: $bin"; exit 1; }
done

INTERP="$ROOT/TALM/interp/interp"
ASM_ROOT="$ROOT/TALM/asm"
CODEGEN_ROOT="$ROOT"

MS_OUT="$OUTROOT/mergesort"
DYCK_OUT="$OUTROOT/dyck_N_IMB_sweep"
FIB_OUT="$OUTROOT/fibonacci"
MATMUL_OUT="$OUTROOT/matmul"

elapsed(){
  local t0="$1" t1="$2"
  local dt=$(( t1 - t0 ))
  printf "%dm%02ds" $(( dt / 60 )) $(( dt % 60 ))
}

# ============================================================
#  MERGE SORT
# ============================================================
run_merge_sort(){
  echo ""
  echo "========================================================"
  echo "  MERGE SORT — TALM + GHC Strategies + GHC par/pseq"
  echo "========================================================"
  local t0; t0=$(date +%s)

  PY2="$PY2" PY3="$PY3" \
  bash "$ROOT/scripts/merge_sort_TALM_vs_Haskell/run_compare.sh" \
    --start-N "$START_N" \
    --step "$STEP" \
    --n-max "$N_MAX" \
    --reps "$REPS" \
    --procs "$PROCS_CSV" \
    --interp "$INTERP" \
    --asm-root "$ASM_ROOT" \
    --codegen "$CODEGEN_ROOT" \
    --outroot "$MS_OUT" \
    --tag ms

  local t1; t1=$(date +%s)
  echo "=== Merge Sort concluído em $(elapsed "$t0" "$t1") ==="
}

# ============================================================
#  DYCK PATH
# ============================================================
run_dyck(){
  echo ""
  echo "========================================================"
  echo "  CAMINHO DE DYCK — TALM + GHC Strategies + GHC par/pseq"
  echo "========================================================"
  local t0; t0=$(date +%s)

  # IMB sweep: 0 to 100 step 5 (21 values)
  local IMB_CSV="0,5,10,15,20,25,30,35,40,45,50,55,60,65,70,75,80,85,90,95,100"

  PY2="$PY2" PY3="$PY3" \
  bash "$ROOT/scripts/dyck/run_compare.sh" \
    --N "$N_CSV" \
    --reps "$REPS" \
    --procs "$PROCS_CSV" \
    --imb "$IMB_CSV" \
    --delta "0" \
    --interp "$INTERP" \
    --asm-root "$ASM_ROOT" \
    --codegen "$CODEGEN_ROOT" \
    --outroot "$DYCK_OUT" \
    --tag dyck

  local t1; t1=$(date +%s)
  echo "=== Dyck concluído em $(elapsed "$t0" "$t1") ==="
}

# ============================================================
#  FIBONACCI
# ============================================================
run_fibonacci(){
  echo ""
  echo "========================================================"
  echo "  FIBONACCI — TALM + GHC Strategies + GHC par/pseq"
  echo "========================================================"
  local t0; t0=$(date +%s)

  PY2="$PY2" PY3="$PY3" \
  bash "$ROOT/scripts/fibonacci/run_compare.sh" \
    --N "$FIB_N" \
    --cutoff "$FIB_CUTOFF" \
    --reps "$REPS" \
    --procs "$PROCS_CSV" \
    --interp "$INTERP" \
    --asm-root "$ASM_ROOT" \
    --codegen "$CODEGEN_ROOT" \
    --outroot "$FIB_OUT" \
    --tag fib

  local t1; t1=$(date +%s)
  echo "=== Fibonacci concluído em $(elapsed "$t0" "$t1") ==="
}

# ============================================================
#  MATRIX MULTIPLY
# ============================================================
run_matmul(){
  echo ""
  echo "========================================================"
  echo "  MATRIX MULTIPLY — TALM + GHC Strategies + GHC par/pseq"
  echo "========================================================"
  local t0; t0=$(date +%s)

  PY2="$PY2" PY3="$PY3" \
  bash "$ROOT/scripts/matmul/run_compare.sh" \
    --N "$MATMUL_N" \
    --reps "$REPS" \
    --procs "$PROCS_CSV" \
    --interp "$INTERP" \
    --asm-root "$ASM_ROOT" \
    --codegen "$CODEGEN_ROOT" \
    --outroot "$MATMUL_OUT" \
    --tag matmul

  local t1; t1=$(date +%s)
  echo "=== MatMul concluído em $(elapsed "$t0" "$t1") ==="
}

# ============================================================
#  MAIN
# ============================================================
TOTAL_T0=$(date +%s)

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║   BENCHMARK SUITE: Ribault (TALM) vs GHC (3 sistemas)  ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  MS/Dyck N : $START_N .. $N_MAX (step $STEP)"
echo "║  Fib N     : $FIB_N"
echo "║  Fib cutoff: $FIB_CUTOFF"
echo "║  MatMul N  : $MATMUL_N"
echo "║  Reps      : $REPS"
echo "║  Procs     : $PROCS_CSV"
echo "║  Outroot   : $OUTROOT"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

[[ "$RUN_MS"     -eq 1 ]] && run_merge_sort
[[ "$RUN_DYCK"   -eq 1 ]] && run_dyck
[[ "$RUN_FIB"    -eq 1 ]] && run_fibonacci
[[ "$RUN_MATMUL" -eq 1 ]] && run_matmul

TOTAL_T1=$(date +%s)

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                    SUITE COMPLETA                       ║"
echo "╠══════════════════════════════════════════════════════════╣"
if [[ "$RUN_MS" -eq 1 ]]; then
echo "║  Merge Sort results  : $MS_OUT/"
fi
if [[ "$RUN_DYCK" -eq 1 ]]; then
echo "║  Dyck results        : $DYCK_OUT/"
echo "║  Dyck compare        : $DYCK_OUT/compare_best_dyck_*.png"
fi
if [[ "$RUN_FIB" -eq 1 ]]; then
echo "║  Fibonacci results   : $FIB_OUT/"
fi
if [[ "$RUN_MATMUL" -eq 1 ]]; then
echo "║  MatMul results      : $MATMUL_OUT/"
fi
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Tempo total         : $(elapsed "$TOTAL_T0" "$TOTAL_T1")"
echo "╚══════════════════════════════════════════════════════════╝"
