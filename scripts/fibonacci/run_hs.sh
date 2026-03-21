#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# fibonacci/run_hs.sh — GHC Fibonacci benchmark runner
# Accepts --gen to select generator (strategies or par/pseq)
# ============================================================

N_CSV=""; CUTOFF_CSV=""; REPS=1
PROCS_CSV=""; OUTROOT=""; TAG="fib_ghc"
VARIANT="ghc"
GEN_OVERRIDE=""
GHC="${GHC:-ghc}"
GHC_PKGS="${GHC_PKGS:--package time -package parallel}"
PY3="${PY3:-python3}"

usage(){
  echo "uso: $0 --N \"30,35,...\" --cutoff \"15,20,...\" --reps R --procs \"1,2,...\" --outroot DIR"
  echo "        [--tag TAG] [--gen script.py] [--variant name]"
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --N)       N_CSV="$2"; shift 2;;
    --cutoff)  CUTOFF_CSV="$2"; shift 2;;
    --reps)    REPS="$2"; shift 2;;
    --procs)   PROCS_CSV="$2"; shift 2;;
    --outroot) OUTROOT="$2"; shift 2;;
    --tag)     TAG="$2"; shift 2;;
    --gen)     GEN_OVERRIDE="$2"; shift 2;;
    --variant) VARIANT="$2"; shift 2;;
    *) usage;;
  esac
done

[[ -n "$N_CSV" && -n "$CUTOFF_CSV" && -n "$PROCS_CSV" && -n "$OUTROOT" ]] || usage

IFS=',' read -r -a NS      <<< "$N_CSV"
IFS=',' read -r -a CUTOFFS  <<< "$CUTOFF_CSV"
IFS=',' read -r -a PROCS    <<< "$PROCS_CSV"

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
echo "variant,N,cutoff,P,rep,seconds,rc" > "$METRICS"

# Compute expected fib values for validation
declare -A FIB_EXPECTED
compute_fib() {
  local n="$1"
  "$PY3" -c "
a, b = 0, 1
for _ in range($n):
    a, b = b, a + b
print(a)
"
}

for N in "${NS[@]}"; do
  FIB_EXPECTED[$N]="$(compute_fib "$N")"
  echo "[fib ] expected fib($N) = ${FIB_EXPECTED[$N]}"
done

TOTAL_RUNS=$(( ${#NS[@]} * ${#CUTOFFS[@]} * ${#PROCS[@]} * REPS ))
RUN_NUM=0

for N in "${NS[@]}"; do
  for CUTOFF in "${CUTOFFS[@]}"; do
    CASE_DIR="$OUTROOT/${VARIANT}/N_${N}/cutoff_${CUTOFF}"
    BIN_DIR="$CASE_DIR/bin"; mkdir -p "$BIN_DIR"
    HS="$BIN_DIR/fib.hs"
    BIN="$BIN_DIR/fib"

    "$PY3" "$GEN_PY" --out "$HS" --N "$N" --cutoff "$CUTOFF"
    echo "[build] N=${N} cutoff=${CUTOFF} -> compiling"
    "$GHC" -O2 -threaded -rtsopts $GHC_PKGS -outputdir "$BIN_DIR" -o "$BIN" "$HS" >/dev/null 2>&1

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
          result="$(awk -F= '/^RESULT=/{print $2}' "$outlog")"
          expected="${FIB_EXPECTED[$N]}"
          if [[ "$result" != "$expected" ]]; then
            >&2 echo "[ERR ] WRONG fib($N): got '$result', expected '$expected'"
            local_rc=99
          fi
        fi
        [[ -z "$secs" ]] && secs="NaN"

        echo "[${RUN_NUM}/${TOTAL_RUNS}] N=${N} cut=${CUTOFF} P=${P} rep=${rep} -> ${secs}s rc=${local_rc}"
        echo "${VARIANT},${N},${CUTOFF},${P},${rep},${secs},${local_rc}" >> "$METRICS"
      done
    done
  done
done

echo "[DONE] ${TOTAL_RUNS} runs; metrics: $METRICS"
