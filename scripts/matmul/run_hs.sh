#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# matmul/run_hs.sh — GHC MatMul benchmark runner
# ============================================================

N_CSV=""; REPS=1
PROCS_CSV=""; OUTROOT=""; TAG="matmul_ghc"
VARIANT="ghc"
GEN_OVERRIDE=""
GHC="${GHC:-ghc}"
GHC_PKGS="${GHC_PKGS:--package time -package deepseq -package parallel}"
PY3="${PY3:-python3}"

usage(){
  echo "uso: $0 --N \"128,256,...\" --reps R --procs \"1,2,...\" --outroot DIR"
  echo "        [--tag TAG] [--gen script.py] [--variant name]"
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --N)       N_CSV="$2"; shift 2;;
    --reps)    REPS="$2"; shift 2;;
    --procs)   PROCS_CSV="$2"; shift 2;;
    --outroot) OUTROOT="$2"; shift 2;;
    --tag)     TAG="$2"; shift 2;;
    --gen)     GEN_OVERRIDE="$2"; shift 2;;
    --variant) VARIANT="$2"; shift 2;;
    *) usage;;
  esac
done

[[ -n "$N_CSV" && -n "$PROCS_CSV" && -n "$OUTROOT" ]] || usage

IFS=',' read -r -a NS    <<< "$N_CSV"
IFS=',' read -r -a PROCS <<< "$PROCS_CSV"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -n "$GEN_OVERRIDE" ]]; then
  GEN_PY="$GEN_OVERRIDE"
else
  GEN_PY="$SCRIPT_DIR/gen_hs_strategies.py"
fi

[[ -f "$GEN_PY" ]] || { echo "[ERRO] gen script not found: $GEN_PY"; exit 1; }
command -v "$GHC" >/dev/null || { echo "[ERRO] GHC not found: $GHC"; exit 1; }
echo "[env ] GHC=${GHC} ; GEN=${GEN_PY} ; variant=${VARIANT}"

mkdir -p "$OUTROOT"
METRICS="$OUTROOT/metrics_${TAG}.csv"
echo "variant,N,P,rep,seconds,rc" > "$METRICS"

TOTAL_RUNS=$(( ${#NS[@]} * ${#PROCS[@]} * REPS ))
RUN_NUM=0

for N in "${NS[@]}"; do
  CASE_DIR="$OUTROOT/${VARIANT}/N_${N}"
  BIN_DIR="$CASE_DIR/bin"; mkdir -p "$BIN_DIR"
  HS="$BIN_DIR/matmul.hs"
  BIN="$BIN_DIR/matmul"

  "$PY3" "$GEN_PY" --out "$HS" --N "$N"
  echo "[build] N=${N} -> compiling"
  "$GHC" -O2 -threaded -rtsopts $GHC_PKGS -outputdir "$BIN_DIR" -o "$BIN" "$HS" >/dev/null 2>&1

  # Get reference checksum (P=1, first run)
  REF_CS=""

  for P in "${PROCS[@]}"; do
    for ((rep=1; rep<=REPS; rep++)); do
      RUN_NUM=$((RUN_NUM + 1))
      local_rc=0
      outlog="$CASE_DIR/run_P${P}_rep${rep}.out"
      set +e
      "$BIN" +RTS -N"$P" -RTS >"$outlog" 2>/dev/null
      local_rc=$?
      set -e

      secs="NaN"
      if [[ $local_rc -eq 0 ]]; then
        secs="$(awk -F= '/^RUNTIME_SEC=/{print $2}' "$outlog")"
        cs="$(awk -F= '/^CHECKSUM=/{print $2}' "$outlog")"
        if [[ -z "$cs" ]]; then
          >&2 echo "[ERR ] CHECKSUM= missing from output"
          local_rc=98
        elif [[ -z "$REF_CS" ]]; then
          REF_CS="$cs"
          echo "[ref ] N=${N} reference checksum: $REF_CS"
        elif [[ "$cs" != "$REF_CS" ]]; then
          >&2 echo "[ERR ] CHECKSUM MISMATCH: got '$cs', expected '$REF_CS'"
          local_rc=99
        fi
      fi
      [[ -z "$secs" ]] && secs="NaN"

      echo "[${RUN_NUM}/${TOTAL_RUNS}] N=${N} P=${P} rep=${rep} -> ${secs}s rc=${local_rc}"
      echo "${VARIANT},${N},${P},${rep},${secs},${local_rc}" >> "$METRICS"
    done
  done
done

echo "[DONE] ${TOTAL_RUNS} runs; metrics: $METRICS"
