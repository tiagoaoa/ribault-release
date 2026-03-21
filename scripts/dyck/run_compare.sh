#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# dyck/run_compare.sh — Run TALM super sweep + GHC baseline,
# then produce individual + comparison plots.
# Supports comma-separated N for multi-N sweeps.
# ============================================================

N_CSV=""; REPS=1
PROCS_CSV=""; IMB_CSV=""; DELTA_CSV="0"
INTERP=""; ASM_ROOT=""; CODEGEN_ROOT=""
OUTROOT=""; TAG="dyck_compare"
PY2="${PY2:-python3}"
PY3="${PY3:-python3}"
PLACE_MODE="${PLACE_MODE:-rr}"
SUPERS_FIXED="${SUPERS_FIXED:-}"
SKIP_SUPER="${SKIP_SUPER:-0}"
SKIP_GHC="${SKIP_GHC:-0}"
SKIP_PARPSEQ="${SKIP_PARPSEQ:-0}"

usage(){
  echo "uso: $0 --N \"50000,100000,...\" --reps R --procs \"1,2,...\" --imb \"0,10,...\" [--delta \"0,2\"] \\"
  echo "        --interp PATH --asm-root PATH --codegen PATH --outroot PATH [--tag TAG]"
  echo ""
  echo "env: SKIP_SUPER=1  (reuse existing TALM metrics)"
  echo "     SKIP_GHC=1    (reuse existing GHC metrics)"
  echo "     SUPERS_FIXED, PLACE_MODE, PY2, PY3"
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --N)        N_CSV="$2"; shift 2;;
    --reps)     REPS="$2"; shift 2;;
    --procs)    PROCS_CSV="$2"; shift 2;;
    --imb)      IMB_CSV="$2"; shift 2;;
    --delta)    DELTA_CSV="$2"; shift 2;;
    --interp)   INTERP="$2"; shift 2;;
    --asm-root) ASM_ROOT="$2"; shift 2;;
    --codegen)  CODEGEN_ROOT="$2"; shift 2;;
    --outroot)  OUTROOT="$2"; shift 2;;
    --tag)      TAG="$2"; shift 2;;
    *) usage;;
  esac
done

[[ -n "$N_CSV" && -n "$PROCS_CSV$IMB_CSV$OUTROOT" ]] || usage

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUPER_CSV="$OUTROOT/metrics_${TAG}_super.csv"
GHC_CSV="$OUTROOT/metrics_${TAG}_ghc.csv"
PARPSEQ_CSV="$OUTROOT/metrics_${TAG}_parpseq.csv"
mkdir -p "$OUTROOT"

# ── Step 1: TALM super sweep ──────────────────────────────
if [[ "$SKIP_SUPER" -eq 1 && -f "$SUPER_CSV" ]]; then
  echo "=== Skipping TALM sweep (SKIP_SUPER=1, reusing $SUPER_CSV) ==="
else
  echo "=== TALM Super Sweep ==="
  PY2="$PY2" PLACE_MODE="$PLACE_MODE" SUPERS_FIXED="$SUPERS_FIXED" \
  bash "$SCRIPT_DIR/run.sh" \
    --N "$N_CSV" --reps "$REPS" --procs "$PROCS_CSV" --imb "$IMB_CSV" --delta "$DELTA_CSV" \
    --interp "$INTERP" --asm-root "$ASM_ROOT" --codegen "$CODEGEN_ROOT" \
    --outroot "$OUTROOT" --tag "${TAG}_super" --plots no
fi

# ── Step 2: GHC baseline ──────────────────────────────────
if [[ "$SKIP_GHC" -eq 1 && -f "$GHC_CSV" ]]; then
  echo "=== Skipping GHC sweep (SKIP_GHC=1, reusing $GHC_CSV) ==="
else
  echo "=== GHC Baseline ==="
  bash "$SCRIPT_DIR/run_hs.sh" \
    --N "$N_CSV" --reps "$REPS" --procs "$PROCS_CSV" --imb "$IMB_CSV" --delta "$DELTA_CSV" \
    --outroot "$OUTROOT" --tag "${TAG}_ghc"
fi

# ── Step 2b: GHC par/pseq baseline ────────────────────────
if [[ "$SKIP_PARPSEQ" -eq 1 && -f "$PARPSEQ_CSV" ]]; then
  echo "=== Skipping GHC par/pseq (SKIP_PARPSEQ=1, reusing $PARPSEQ_CSV) ==="
else
  echo "=== GHC par/pseq Baseline ==="
  bash "$SCRIPT_DIR/run_hs.sh" \
    --N "$N_CSV" --reps "$REPS" --procs "$PROCS_CSV" --imb "$IMB_CSV" --delta "$DELTA_CSV" \
    --outroot "$OUTROOT" --tag "${TAG}_parpseq" \
    --gen "$SCRIPT_DIR/gen_hs_parpseq.py" --variant "parpseq"
fi

# ── Step 3: Plots ─────────────────────────────────────────
echo "=== Generating plots ==="
PLOT_ARGS=("--outdir" "$OUTROOT" "--tag" "$TAG")
METRICS_FILES=()
[[ -f "$SUPER_CSV" ]]   && METRICS_FILES+=("$SUPER_CSV")
[[ -f "$GHC_CSV" ]]     && METRICS_FILES+=("$GHC_CSV")
[[ -f "$PARPSEQ_CSV" ]] && METRICS_FILES+=("$PARPSEQ_CSV")

if [[ ${#METRICS_FILES[@]} -eq 0 ]]; then
  echo "[ERRO] No metrics CSV found"; exit 1
fi

"$PY3" "$SCRIPT_DIR/plot.py" --metrics "${METRICS_FILES[@]}" "${PLOT_ARGS[@]}"

echo "[DONE] results in: $OUTROOT"
