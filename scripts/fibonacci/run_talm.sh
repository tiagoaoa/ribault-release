#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# fibonacci/run_talm.sh — TALM Fibonacci benchmark runner
# Generates .hsk, compiles to .fl, builds supers, assembles,
# runs with interp
# ============================================================

N_CSV=""; CUTOFF_CSV=""; REPS=1
PROCS_CSV=""; OUTROOT=""; TAG="fib_talm"
INTERP=""; ASM_ROOT=""; CODEGEN_ROOT=""
PY2="${PY2:-python3}"
PY3="${PY3:-python3}"

usage(){
  echo "uso: $0 --N \"30,35,...\" --cutoff \"15,20,...\" --reps R --procs \"1,2,...\""
  echo "        --interp PATH --asm-root PATH --codegen PATH --outroot DIR [--tag TAG]"
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --N)       N_CSV="$2"; shift 2;;
    --cutoff)  CUTOFF_CSV="$2"; shift 2;;
    --reps)    REPS="$2"; shift 2;;
    --procs)   PROCS_CSV="$2"; shift 2;;
    --interp)  INTERP="$2"; shift 2;;
    --asm-root) ASM_ROOT="$2"; shift 2;;
    --codegen) CODEGEN_ROOT="$2"; shift 2;;
    --outroot) OUTROOT="$2"; shift 2;;
    --tag)     TAG="$2"; shift 2;;
    *) usage;;
  esac
done

[[ -n "$N_CSV" && -n "$CUTOFF_CSV" && -n "$PROCS_CSV" && -n "$INTERP" && -n "$ASM_ROOT" && -n "$CODEGEN_ROOT" && -n "$OUTROOT" ]] || usage

IFS=',' read -r -a NS      <<< "$N_CSV"
IFS=',' read -r -a CUTOFFS  <<< "$CUTOFF_CSV"
IFS=',' read -r -a PROCS    <<< "$PROCS_CSV"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GEN_PY="$SCRIPT_DIR/gen_talm_input.py"
CODEGEN="$CODEGEN_ROOT/codegen"

# Locate build_supers.sh relative to the codegen root (repo root)
BUILD_SUPERS="$CODEGEN_ROOT/tools/build_supers.sh"

[[ -x "$INTERP" ]]   || { echo "[ERRO] interp not executable: $INTERP"; exit 1; }
[[ -x "$CODEGEN" ]]  || { echo "[ERRO] codegen not found: $CODEGEN"; exit 1; }
[[ -f "$ASM_ROOT/assembler.py" ]] || { echo "[ERRO] assembler.py not found in: $ASM_ROOT"; exit 1; }
[[ -f "$BUILD_SUPERS" ]] || { echo "[ERRO] build_supers.sh not found: $BUILD_SUPERS"; exit 1; }

echo "[env ] INTERP=${INTERP} ; CODEGEN=${CODEGEN}"

# Detect GHC include path for building supers (needed for HsFFI.h)
GHC_BIN="${GHC:-ghc}"
GHC_LIBDIR_RAW="$("$GHC_BIN" --print-libdir)"
GHC_VER="$("$GHC_BIN" --numeric-version)"
# Find HsFFI.h include directory
SUPERS_CFLAGS="${CFLAGS:-}"
if [[ -z "$SUPERS_CFLAGS" ]]; then
  HsFFI_INC=""
  for cand in \
    "$GHC_LIBDIR_RAW/x86_64-linux-ghc-${GHC_VER}/rts-"*/include \
    "$GHC_LIBDIR_RAW/../lib/x86_64-linux-ghc-${GHC_VER}/rts-"*/include \
    "$GHC_LIBDIR_RAW/rts/include" \
    "$GHC_LIBDIR_RAW/include"; do
    if [[ -f "$cand/HsFFI.h" ]]; then
      HsFFI_INC="$cand"
      break
    fi
  done
  if [[ -n "$HsFFI_INC" ]]; then
    SUPERS_CFLAGS="-O2 -fPIC -I$HsFFI_INC"
    echo "[env ] HsFFI.h found at: $HsFFI_INC"
  else
    SUPERS_CFLAGS="-O2 -fPIC"
    echo "[warn] HsFFI.h not found, build_supers may fail"
  fi
fi

mkdir -p "$OUTROOT"
METRICS="$OUTROOT/metrics_${TAG}.csv"
echo "variant,N,cutoff,P,rep,seconds,rc" > "$METRICS"

# Compute expected fib values
declare -A FIB_EXPECTED
compute_fib() { "$PY3" -c "a,b=0,1
for _ in range($1): a,b=b,a+b
print(a)"; }

for N in "${NS[@]}"; do
  FIB_EXPECTED[$N]="$(compute_fib "$N")"
  echo "[fib ] expected fib($N) = ${FIB_EXPECTED[$N]}"
done

TOTAL_RUNS=$(( ${#NS[@]} * ${#CUTOFFS[@]} * ${#PROCS[@]} * REPS ))
RUN_NUM=0

for N in "${NS[@]}"; do
  for CUTOFF in "${CUTOFFS[@]}"; do
    CASE_DIR="$OUTROOT/talm/N_${N}/cutoff_${CUTOFF}"
    mkdir -p "$CASE_DIR"

    HSK="$CASE_DIR/fib.hsk"
    FL="$CASE_DIR/fib.fl"
    PREFIX="$CASE_DIR/fib"

    # Generate .hsk
    "$PY3" "$GEN_PY" --out "$HSK" --N "$N" --cutoff "$CUTOFF"

    # Codegen: .hsk -> .fl
    "$CODEGEN" "$HSK" > "$FL" 2>/dev/null

    # Build supers: .hsk -> libsupers.so
    SUPERS_DIR="$CASE_DIR/supers"
    mkdir -p "$SUPERS_DIR"
    echo "[sup ] building supers for N=${N} cutoff=${CUTOFF}..."
    CFLAGS="$SUPERS_CFLAGS" bash "$BUILD_SUPERS" "$HSK" "$SUPERS_DIR/Supers.hs" 2>&1 \
      | sed 's/^/  /'
    LIBSUP="$SUPERS_DIR/libsupers.so"
    if [[ ! -f "$LIBSUP" ]]; then
      echo "[ERRO] libsupers.so not found after build: $LIBSUP"
      # Record failures for all (P, rep) combinations
      for P in "${PROCS[@]}"; do
        for ((rep=1; rep<=REPS; rep++)); do
          RUN_NUM=$((RUN_NUM + 1))
          echo "[${RUN_NUM}/${TOTAL_RUNS}] N=${N} cut=${CUTOFF} P=${P} rep=${rep} -> NaN s rc=1 (supers build failed)"
          echo "super,${N},${CUTOFF},${P},${rep},NaN,1" >> "$METRICS"
        done
      done
      continue
    fi
    echo "[sup ] built: $LIBSUP"

    for P in "${PROCS[@]}"; do
      # Assemble with P PEs
      PREFIX_P="$CASE_DIR/fib_P${P}"
      pushd "$ASM_ROOT" >/dev/null
        "$PY2" assembler.py -a -n "$P" -o "$PREFIX_P" "$FL" >/dev/null 2>&1
      popd >/dev/null

      FLB="${PREFIX_P}.flb"
      PLA="${PREFIX_P}_auto.pla"
      [[ -f "$PLA" ]] || PLA="${PREFIX_P}.pla"
      [[ -f "$FLB" ]] || { echo "[ERRO] .flb not found: $FLB"; continue; }

      LIBDIR="$(dirname "$LIBSUP")"
      GHCDEPS="$LIBDIR/ghc-deps"

      for ((rep=1; rep<=REPS; rep++)); do
        RUN_NUM=$((RUN_NUM + 1))
        local_rc=0
        outlog="$CASE_DIR/run_P${P}_rep${rep}.out"
        errlog="$CASE_DIR/run_P${P}_rep${rep}.err"

        set +e
        LD_LIBRARY_PATH="$LIBDIR:$GHCDEPS${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
          "$INTERP" "$P" "$FLB" "$PLA" "$LIBSUP" >"$outlog" 2>"$errlog"
        local_rc=$?
        set -e

        secs="NaN"
        if [[ $local_rc -eq 0 ]]; then
          # EXEC_TIME_S is printed to stderr by the interpreter
          secs="$(grep -oP 'EXEC_TIME_S \K[0-9.]+' "$errlog" 2>/dev/null || true)"
          [[ -z "$secs" ]] && secs="$(awk -F'=' '/^EXEC_TIME_S=/{print $2}' "$errlog" 2>/dev/null || true)"
          [[ -z "$secs" ]] && secs="$(awk -F'=' '/^EXEC_TIME_S=/{print $2}' "$outlog" 2>/dev/null || true)"

          # Check result (from stdout)
          result="$(awk -F= '/^RESULT=/{print $2}' "$outlog" 2>/dev/null || true)"
          expected="${FIB_EXPECTED[$N]}"
          if [[ -z "$result" ]]; then
            >&2 echo "[WARN] RESULT= missing from stdout (known TALM issue for deep recursion)"
          elif [[ "$result" != "$expected" ]]; then
            >&2 echo "[ERR ] WRONG fib($N): got '$result', expected '$expected'"
            local_rc=99
          fi
        fi
        [[ -z "$secs" ]] && secs="NaN"

        echo "[${RUN_NUM}/${TOTAL_RUNS}] N=${N} cut=${CUTOFF} P=${P} rep=${rep} -> ${secs}s rc=${local_rc}"
        echo "super,${N},${CUTOFF},${P},${rep},${secs},${local_rc}" >> "$METRICS"
      done
    done
  done
done

echo "[DONE] ${TOTAL_RUNS} runs; metrics: $METRICS"
