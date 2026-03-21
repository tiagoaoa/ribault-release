#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# merge_sort/run_compare.sh — TALM + GHC-strategies + GHC-par/pseq
# ============================================================

START_N=50000; STEP=50000; N_MAX=1000000; REPS=10
PROCS_CSV="1,2,4,8"
INTERP=""; ASM_ROOT=""; CODEGEN_ROOT=""
OUTROOT=""; TAG="ms"
PY2="${PY2:-python3}"
PY3="${PY3:-python3}"
SKIP_TALM="${SKIP_TALM:-0}"
SKIP_GHC="${SKIP_GHC:-0}"
SKIP_PARPSEQ="${SKIP_PARPSEQ:-0}"

usage(){
  echo "uso: $0 --start-N A --step B --n-max C --reps R --procs \"1,2,...\""
  echo "        --interp PATH --asm-root PATH --codegen PATH --outroot DIR [--tag TAG]"
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --start-N)  START_N="$2"; shift 2;;
    --step)     STEP="$2"; shift 2;;
    --n-max)    N_MAX="$2"; shift 2;;
    --reps)     REPS="$2"; shift 2;;
    --procs)    PROCS_CSV="$2"; shift 2;;
    --interp)   INTERP="$2"; shift 2;;
    --asm-root) ASM_ROOT="$2"; shift 2;;
    --codegen)  CODEGEN_ROOT="$2"; shift 2;;
    --outroot)  OUTROOT="$2"; shift 2;;
    --tag)      TAG="$2"; shift 2;;
    *) usage;;
  esac
done

[[ -n "$OUTROOT" ]] || usage

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TALM_CSV="$OUTROOT/metrics_${TAG}_super.csv"
GHC_CSV="$OUTROOT/metrics_${TAG}_ghc.csv"
PARPSEQ_CSV="$OUTROOT/metrics_${TAG}_parpseq.csv"
mkdir -p "$OUTROOT"

# ── Step 1: TALM ─────────────────────────────────────────
if [[ "$SKIP_TALM" -eq 1 && -f "$TALM_CSV" ]]; then
  echo "=== Skipping TALM (SKIP_TALM=1) ==="
else
  echo "=== TALM Merge Sort ==="
  PY2="$PY2" PY3="$PY3" \
  MS_LEAF=array DF_LIST_BUILTIN=1 SUPERS_FORCE_PAR=1 \
  bash "$SCRIPT_DIR/run.sh" \
    --start-N "$START_N" --step "$STEP" --n-max "$N_MAX" \
    --reps "$REPS" --procs "$PROCS_CSV" \
    --interp "$INTERP" --asm-root "$ASM_ROOT" --codegen "$CODEGEN_ROOT" \
    --outroot "$OUTROOT" --vec range --plots no --tag "${TAG}_super"
fi

# ── Step 2: GHC Strategies ───────────────────────────────
if [[ "$SKIP_GHC" -eq 1 && -f "$GHC_CSV" ]]; then
  echo "=== Skipping GHC Strategies (SKIP_GHC=1) ==="
else
  echo "=== GHC Strategies Merge Sort ==="
  GHC_PKGS="-package time -package deepseq -package parallel" \
  bash "$SCRIPT_DIR/run_hs.sh" \
    --start-N "$START_N" --step "$STEP" --n-max "$N_MAX" \
    --reps "$REPS" --procs "$PROCS_CSV" \
    --outroot "$OUTROOT" --vec range --tag "${TAG}_ghc" --variant "ghc"
fi

# ── Step 3: GHC par/pseq ─────────────────────────────────
if [[ "$SKIP_PARPSEQ" -eq 1 && -f "$PARPSEQ_CSV" ]]; then
  echo "=== Skipping GHC par/pseq (SKIP_PARPSEQ=1) ==="
else
  echo "=== GHC par/pseq Merge Sort ==="
  GHC_PKGS="-package time -package deepseq -package parallel" \
  bash "$SCRIPT_DIR/run_hs.sh" \
    --start-N "$START_N" --step "$STEP" --n-max "$N_MAX" \
    --reps "$REPS" --procs "$PROCS_CSV" \
    --outroot "$OUTROOT" --vec range --tag "${TAG}_parpseq" \
    --gen "$SCRIPT_DIR/gen_hs_parpseq.py" --variant "parpseq"
fi

# ── Step 4: All plots ────────────────────────────────────
echo "=== Generating all plots ==="
PLOT_ARGS=("--outdir" "$OUTROOT" "--tag" "$TAG")
METRICS_FILES=()
[[ -f "$TALM_CSV" ]]    && METRICS_FILES+=("$TALM_CSV")
[[ -f "$GHC_CSV" ]]     && METRICS_FILES+=("$GHC_CSV")
[[ -f "$PARPSEQ_CSV" ]] && METRICS_FILES+=("$PARPSEQ_CSV")

if [[ ${#METRICS_FILES[@]} -gt 0 ]]; then
  "$PY3" "$SCRIPT_DIR/plot_all.py" --metrics "${METRICS_FILES[@]}" "${PLOT_ARGS[@]}"
fi

echo "[DONE] results in: $OUTROOT"
