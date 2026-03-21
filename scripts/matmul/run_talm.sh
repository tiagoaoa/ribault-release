#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# matmul/run_talm.sh — TALM MatMul benchmark runner
# ============================================================

N_CSV=""; REPS=1
PROCS_CSV=""; OUTROOT=""; TAG="matmul_talm"
INTERP=""; ASM_ROOT=""; CODEGEN_ROOT=""
PY2="${PY2:-python3}"
PY3="${PY3:-python3}"

usage(){
  echo "uso: $0 --N \"128,256,...\" --reps R --procs \"1,2,...\""
  echo "        --interp PATH --asm-root PATH --codegen PATH --outroot DIR [--tag TAG]"
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --N)        N_CSV="$2"; shift 2;;
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

[[ -n "$N_CSV" && -n "$PROCS_CSV" && -n "$INTERP" && -n "$ASM_ROOT" && -n "$CODEGEN_ROOT" && -n "$OUTROOT" ]] || usage

IFS=',' read -r -a NS    <<< "$N_CSV"
IFS=',' read -r -a PROCS <<< "$PROCS_CSV"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GEN_PY="$SCRIPT_DIR/gen_talm_input.py"

if [[ -x "$CODEGEN_ROOT/codegen" ]]; then
  CODEGEN="${CODEGEN_ROOT}/codegen"
else
  echo "[ERRO] codegen not found: $CODEGEN_ROOT/codegen"; exit 1
fi

BUILD_SUPERS="${CODEGEN_ROOT}/tools/build_supers.sh"
[[ -f "$BUILD_SUPERS" ]] || { echo "[ERRO] build_supers.sh not found: $BUILD_SUPERS"; exit 1; }

[[ -x "$INTERP" ]]  || { echo "[ERRO] interp not executable: $INTERP"; exit 1; }
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
echo "variant,N,P,rep,seconds,rc" > "$METRICS"

TOTAL_RUNS=$(( ${#NS[@]} * ${#PROCS[@]} * REPS ))
RUN_NUM=0

# Build or cache supers for a given N. Prints absolute path to supers dir.
get_supers_dir() {
  local N="$1"
  local d="$OUTROOT/supers_cache/N_${N}"
  if [[ -f "$d/libsupers.so" ]]; then
    d="$(cd "$d" && pwd)"
    echo "$d"
    return
  fi
  mkdir -p "$d"
  d="$(cd "$d" && pwd)"
  echo "[sup ] building supers for N=${N}..." >&2
  # Generate a representative .hsk (P=1) for super compilation
  "$PY3" "$GEN_PY" --out "$d/representative.hsk" --N "$N" --P 1 >&2
  CFLAGS="$SUPERS_CFLAGS" bash "$BUILD_SUPERS" "$d/representative.hsk" "$d/Supers.hs" >&2
  [[ -f "$d/libsupers.so" ]] || { echo "[ERRO] super build failed for N=${N}" >&2; exit 1; }
  echo "[sup ] built: $d/libsupers.so" >&2
  echo "$d"
}

for N in "${NS[@]}"; do
  # Pre-build supers for this N
  SUPERS_DIR="$(get_supers_dir "$N")"
  LIBSUP="$SUPERS_DIR/libsupers.so"
  GHCDEPS="$SUPERS_DIR/ghc-deps"

  for P in "${PROCS[@]}"; do
    CASE_DIR="$OUTROOT/talm/N_${N}/P_${P}"
    mkdir -p "$CASE_DIR"

    HSK="$CASE_DIR/matmul.hsk"
    FL="$CASE_DIR/matmul.fl"
    PREFIX_P="$CASE_DIR/matmul"

    # Generate .hsk (P-specific: unrolled block structure)
    "$PY3" "$GEN_PY" --out "$HSK" --N "$N" --P "$P"

    # Codegen: .hsk -> .fl
    "$CODEGEN" "$HSK" > "$FL" 2>/dev/null

    # Assemble with P PEs
    pushd "$ASM_ROOT" >/dev/null
      "$PY2" assembler.py -a -n "$P" -o "$PREFIX_P" "$FL" >/dev/null 2>&1
    popd >/dev/null

    FLB="${PREFIX_P}.flb"
    PLA="${PREFIX_P}.pla"
    [[ -f "$FLB" ]] || { echo "[ERRO] .flb not found: $FLB"; continue; }

    REF_CS=""
    for ((rep=1; rep<=REPS; rep++)); do
      RUN_NUM=$((RUN_NUM + 1))
      local_rc=0
      outlog="$CASE_DIR/run_rep${rep}.out"
      errlog="$CASE_DIR/run_rep${rep}.err"

      set +e
      LD_LIBRARY_PATH="${SUPERS_DIR}:${GHCDEPS}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        "$INTERP" "$P" "$FLB" "$PLA" "$LIBSUP" >"$outlog" 2>"$errlog"
      local_rc=$?
      set -e

      secs="NaN"
      if [[ $local_rc -eq 0 ]]; then
        # Try to extract execution time from stderr (interpreter prints it there)
        secs="$(grep -oP 'EXEC_TIME_S \K[0-9.]+' "$errlog" 2>/dev/null || true)"
        [[ -z "$secs" ]] && secs="$(awk -F= '/^EXEC_TIME_S=/{print $2}' "$outlog" 2>/dev/null || true)"
        [[ -z "$secs" ]] && secs="$(awk -F= '/^RUNTIME_SEC=/{print $2}' "$outlog" 2>/dev/null || true)"
        cs="$(awk -F= '/^CHECKSUM=/{print $2}' "$outlog" 2>/dev/null || true)"
        if [[ -z "$cs" ]]; then
          >&2 echo "[ERR ] CHECKSUM= missing from TALM output (N=${N} P=${P})"
          local_rc=98
        elif [[ -z "$REF_CS" ]]; then
          REF_CS="$cs"
          echo "[ref ] N=${N} reference checksum: $REF_CS"
        elif [[ "$cs" != "$REF_CS" ]]; then
          >&2 echo "[ERR ] CHECKSUM MISMATCH N=${N} P=${P}: got '$cs', expected '$REF_CS'"
          local_rc=99
        fi
      fi
      [[ -z "$secs" ]] && secs="NaN"

      echo "[${RUN_NUM}/${TOTAL_RUNS}] N=${N} P=${P} rep=${rep} -> ${secs}s rc=${local_rc}"
      echo "super,${N},${P},${rep},${secs},${local_rc}" >> "$METRICS"
    done
  done
done

echo "[DONE] ${TOTAL_RUNS} runs; metrics: $METRICS"
