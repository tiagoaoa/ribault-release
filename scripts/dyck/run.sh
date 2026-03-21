#!/usr/bin/env bash
set -euo pipefail

# ============= Dyck (SUPER) sweep =====================
# Varies N, IMB (work imbalance) and P.
# Uses EXEC_TIME_S from interpreter output.
# Checks correctness: delta=0 → expects "1", else "0".
# Supports comma-separated N for multi-N sweeps with
# automatic per-N super compilation.
# ======================================================

N_CSV=""; REPS=1
PROCS_CSV=""; IMB_CSV=""; DELTA_CSV="0"
INTERP=""; ASM_ROOT=""; CODEGEN_ROOT=""
OUTROOT=""; VEC_MODE="range"; PLOTS="yes"; TAG="dyck_super"
PY2="${PY2:-python2}"
PY3="${PY3:-python3}"
PLACE_MODE="${PLACE_MODE:-rr}"

# Override: skip per-N compilation, use this fixed supers dir
SUPERS_FIXED="${SUPERS_FIXED:-}"

usage(){
  echo "uso: $0 --N \"50000,100000,...\" --reps R --procs \"1,2,...\" --imb \"0,10,20,...\" [--delta \"0,2,-2\"] \\"
  echo "          --interp PATH --asm-root PATH --codegen PATH --outroot PATH [--plots yes|no] [--tag nome]"
  echo "env: PLACE_MODE=rr|chunk  SUPERS_FIXED=/abs/path  LOG_ERR=1"
  exit 2
}

# ----------------- parse -----------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --N)       N_CSV="$2"; shift 2;;
    --reps)    REPS="$2"; shift 2;;
    --procs)   PROCS_CSV="$2"; shift 2;;
    --imb)     IMB_CSV="$2"; shift 2;;
    --delta)   DELTA_CSV="$2"; shift 2;;
    --interp)  INTERP="$2"; shift 2;;
    --asm-root) ASM_ROOT="$2"; shift 2;;
    --codegen) CODEGEN_ROOT="$2"; shift 2;;
    --outroot) OUTROOT="$2"; shift 2;;
    --vec)     VEC_MODE="$2"; shift 2;;
    --plots)   PLOTS="$2"; shift 2;;
    --tag)     TAG="$2"; shift 2;;
    *) usage;;
  esac
done

[[ -n "$N_CSV" && -n "$REPS$PROCS_CSV$IMB_CSV$INTERP$ASM_ROOT$CODEGEN_ROOT$OUTROOT" ]] || usage

IFS=',' read -r -a NS     <<< "$N_CSV"
IFS=',' read -r -a PROCS  <<< "$PROCS_CSV"
IFS=',' read -r -a IMBS   <<< "$IMB_CSV"
IFS=',' read -r -a DELTAS <<< "$DELTA_CSV"

echo "[env ] PY3=${PY3} ; PY2=${PY2} ; N=${N_CSV} (${#NS[@]} values)"

[[ -x "$INTERP" ]] || { echo "[ERRO] interp não executável: $INTERP"; exit 1; }
[[ -f "$ASM_ROOT/assembler.py" ]] || { echo "[ERRO] ASM_ROOT inválido: $ASM_ROOT"; exit 1; }
if [[ -x "$CODEGEN_ROOT/codegen" ]]; then
  CODEGEN="${CODEGEN_ROOT}/codegen"
else
  echo "[ERRO] não achei 'codegen' em: $CODEGEN_ROOT"; exit 1
fi
echo "[talm ] usando codegen: $CODEGEN"

BUILD_SUPERS="${CODEGEN_ROOT}/tools/build_supers.sh"

# Validate SUPERS_FIXED
if [[ -n "$SUPERS_FIXED" ]]; then
  if [[ ${#NS[@]} -gt 1 ]]; then
    echo "[WARN] SUPERS_FIXED ignored for multi-N sweep (supers depend on N)"
    SUPERS_FIXED=""
  else
    echo "[sup ] usando supers fixa: $SUPERS_FIXED"
    [[ -f "$SUPERS_FIXED/libsupers.so" ]] || { echo "[ERRO] libsupers.so não encontrada"; exit 1; }
  fi
fi

DYCK_DIR="$(cd "$(dirname "$0")" && pwd)"
GEN_PY="$DYCK_DIR/gen_dyck_input.py"
PLOT_PY="$DYCK_DIR/plot.py"
echo "[hsk ] usando gerador: $GEN_PY"

mkdir -p "$OUTROOT"
METRICS_CSV="$OUTROOT/metrics_${TAG}.csv"
echo "variant,N,P,imb,delta,rep,seconds,rc" > "$METRICS_CSV"

# ---------- helpers ----------
abspath(){ local d b; d="$(cd "$(dirname "$1")" && pwd)"; b="$(basename "$1")"; printf "%s/%s" "$d" "$b"; }

gen_hsk() {
  local N="$1" P="$2" IMB="$3" DELTA="$4" out_hsk="$5"
  mkdir -p "$(dirname "$out_hsk")"
  "$PY3" "$GEN_PY" --out "$out_hsk" --N "$N" --P "$P" --imb "$IMB" --delta "$DELTA" --vec "$VEC_MODE"
}

build_fl() {
  local hsk="$1" fl="$2"
  mkdir -p "$(dirname "$fl")"
  "$CODEGEN" "$hsk" > "$fl"
  [[ -s "$fl" ]] || { echo "[ERRO] .fl vazio/não criado: $fl"; exit 1; }
}

assemble_baseline() {
  local fl_abs="$1" prefix_abs="$2"
  pushd "$ASM_ROOT" >/dev/null
    "$PY2" assembler.py -o "$prefix_abs" "$fl_abs" >/dev/null
  popd >/dev/null
  [[ -f "${prefix_abs}.flb" && -f "${prefix_abs}.pla" ]] || { echo "[ERRO] baseline não gerou .flb/.pla"; exit 1; }
  cp -f "${prefix_abs}.pla" "${prefix_abs}.pla.base"
}

rewrite_pla_manual() {
  local prefix_abs="$1" P="$2" mode="$3"
  local base="${prefix_abs}.pla.base"
  local pla="${prefix_abs}.pla"
  local nt; nt="$(head -n1 "$base" | tr -d '\r')"
  [[ "$nt" =~ ^[0-9]+$ ]] || { echo "[ERRO] primeira linha de ${base} inválida"; exit 1; }

  if [[ "$P" -le 1 ]]; then
    awk 'NR==1{print; next} {print 0}' "$base" > "$pla"
    return
  fi

  case "$mode" in
    rr|RR)
      awk -v P="$P" 'NR==1{print; next} {i=NR-2; print (i%P)}' "$base" > "$pla"
      ;;
    chunk|CHUNK)
      awk -v P="$P" -v N="$nt" 'NR==1{print; next} {i=NR-2; printf "%d\n", int((i*P)/N)}' "$base" > "$pla"
      ;;
    *) echo "[ERRO] PLACE_MODE inválido: $mode"; exit 1;;
  esac
}

# Run interpreter, extract EXEC_TIME_S and check correctness
run_interp() {
  local P="$1" flb_abs="$2" pla_abs="$3" lib="${4:-}" case_dir="$5" expected="$6"
  local logs="$case_dir/logs"; mkdir -p "$logs"
  local outlog="$logs/run.out" errlog="$logs/run.err"

  local rc=0
  if [[ -n "$lib" ]]; then
    local libdir; libdir="$(dirname "$lib")"
    local ghcdeps="$libdir/ghc-deps"
    SUPERS_FORCE_PAR=1 NUM_CORES="$P" \
      LD_LIBRARY_PATH="$libdir:$ghcdeps" \
      "$INTERP" "$P" "$flb_abs" "$pla_abs" "$lib" >"$outlog" 2>"$errlog" &
  else
    "$INTERP" "$P" "$flb_abs" "$pla_abs" >"$outlog" 2>"$errlog" &
  fi
  local pid=$!
  if ! wait "$pid"; then rc=$?; fi

  # Extract EXEC_TIME_S (interp prints it to stderr)
  local secs="NaN"
  for f in "$errlog" "$outlog"; do
    if [[ -f "$f" ]]; then
      local et; et="$(grep -oP 'EXEC_TIME_S \K[0-9.]+' "$f" 2>/dev/null || true)"
      [[ -n "$et" ]] && { secs="$et"; break; }
    fi
  done

  # Correctness check
  if [[ -f "$outlog" && "$rc" -eq 0 ]]; then
    local result; result="$(grep -oP '^\d+$' "$outlog" | head -1 || true)"
    if [[ -n "$result" && "$result" != "$expected" ]]; then
      >&2 echo "[WARN ] WRONG ANSWER: got '$result', expected '$expected'"
      rc=99
    elif [[ -z "$result" ]]; then
      >&2 echo "[WARN ] No result found in output"
      rc=98
    fi
  fi

  printf "%s %d" "$secs" "$rc"
}

# Expected result: delta=0 → 1 (valid), else 0 (invalid)
expected_result() {
  local delta="$1"
  if [[ "$delta" -eq 0 ]]; then echo "1"; else echo "0"; fi
}

# Detect GHC shim environment (built by 'make supers_prepare')
SHIM_DIR="${CODEGEN_ROOT}/build/ghc-shim"
if [[ -d "$SHIM_DIR/rts" ]]; then
  GHC_VER="$(ghc --numeric-version)"
  SHIM_RTS_SO="$(ls "$SHIM_DIR/rts/libHSrts"*"-ghc${GHC_VER}.so" 2>/dev/null | head -1 || true)"
  if [[ -n "$SHIM_RTS_SO" ]]; then
    export GHC_LIBDIR="$SHIM_DIR"
    export RTS_SO="$SHIM_RTS_SO"
    # Include paths for HsFFI.h etc.
    if [[ -f "$SHIM_DIR/.cpath" ]]; then
      export C_INCLUDE_PATH="$(cat "$SHIM_DIR/.cpath")"
      export CPATH="$(cat "$SHIM_DIR/.cpath")"
    fi
    echo "[sup ] detected shim: GHC_LIBDIR=$GHC_LIBDIR  RTS_SO=$RTS_SO"
  fi
fi

# Build or cache supers for (N, DELTA). Prints absolute path to supers dir on stdout.
get_supers_dir() {
  local N="$1" DELTA="$2"
  local d="$OUTROOT/supers_cache/N_${N}_delta_${DELTA}"
  if [[ -f "$d/libsupers.so" ]]; then
    d="$(cd "$d" && pwd)"
    echo "$d"
    return
  fi
  mkdir -p "$d"
  d="$(cd "$d" && pwd)"
  echo "[sup ] building supers for N=${N} delta=${DELTA}..." >&2
  "$PY3" "$GEN_PY" --out "$d/representative.hsk" --N "$N" --P 1 --imb 0 --delta "$DELTA" --vec "$VEC_MODE" >&2
  bash "$BUILD_SUPERS" "$d/representative.hsk" "$d/Supers.hs" >&2
  [[ -f "$d/libsupers.so" ]] || { echo "[ERRO] super build failed for N=${N}" >&2; exit 1; }
  echo "[sup ] built: $d/libsupers.so" >&2
  echo "$d"
}

# Resolve libsupers.so path for (N, DELTA)
resolve_lib() {
  local N="$1" DELTA="$2"
  if [[ -n "$SUPERS_FIXED" ]]; then
    abspath "$SUPERS_FIXED/libsupers.so"
  else
    local d; d="$(get_supers_dir "$N" "$DELTA")"
    echo "$d/libsupers.so"
  fi
}

# ----------------- main -----------------
TOTAL_RUNS=$(( ${#NS[@]} * ${#PROCS[@]} * ${#IMBS[@]} * ${#DELTAS[@]} * REPS ))
RUN_NUM=0

for N in "${NS[@]}"; do
  echo ""
  echo "======== N=${N} ========"

  # Pre-build supers for all deltas at this N
  if [[ -z "$SUPERS_FIXED" ]]; then
    for DELTA in "${DELTAS[@]}"; do
      get_supers_dir "$N" "$DELTA" > /dev/null
    done
  fi

  for P in "${PROCS[@]}"; do
    for IMB in "${IMBS[@]}"; do
      for DELTA in "${DELTAS[@]}"; do
        EXPECTED="$(expected_result "$DELTA")"
        CASE_DIR="$OUTROOT/super/N_${N}/P_${P}/imb_${IMB}/delta_${DELTA}"
        mkdir -p "$CASE_DIR"
        HSK="$CASE_DIR/dyck.hsk"
        FL="$CASE_DIR/dyck.fl"
        PREFIX="$CASE_DIR/dyck"

        gen_hsk "$N" "$P" "$IMB" "$DELTA" "$HSK"
        build_fl "$HSK" "$FL"

        FL_ABS="$(abspath "$FL")"
        PREFIX_ABS="$(abspath "$PREFIX")"

        assemble_baseline "$FL_ABS" "$PREFIX_ABS"
        rewrite_pla_manual "$PREFIX_ABS" "$P" "$PLACE_MODE"

        LIBSUP="$(resolve_lib "$N" "$DELTA")"

        for ((rep=1; rep<=REPS; rep++)); do
          RUN_NUM=$((RUN_NUM + 1))
          set +e
          out="$(run_interp "$P" "${PREFIX_ABS}.flb" "${PREFIX_ABS}.pla" "$LIBSUP" "$CASE_DIR" "$EXPECTED")"
          st=$?
          set -e
          secs="NaN"; rc=999
          if [[ $st -eq 0 ]]; then
            read -r secs rc <<< "$out" || { secs="NaN"; rc=998; }
          fi

          echo "[${RUN_NUM}/${TOTAL_RUNS}] N=${N} P=${P} imb=${IMB} delta=${DELTA} rep=${rep} -> ${secs}s rc=${rc}"
          echo "super,${N},${P},${IMB},${DELTA},${rep},${secs},${rc}" >> "$METRICS_CSV"

          if [[ "${LOG_ERR:-0}" -eq 1 && "$rc" -ne 0 ]]; then
            echo "[err ] $CASE_DIR/logs/run.err"
            sed -n '1,120p' "$CASE_DIR/logs/run.err" || true
          fi
        done
      done
    done
  done
done

if [[ "$PLOTS" == "yes" ]]; then
  "$PY3" "$PLOT_PY" --metrics "$METRICS_CSV" --outdir "$OUTROOT" --tag "$TAG"
fi

echo ""
echo "[DONE] ${TOTAL_RUNS} runs; resultados em: $OUTROOT"
