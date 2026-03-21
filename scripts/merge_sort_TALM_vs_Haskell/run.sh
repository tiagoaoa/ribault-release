#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# merge_sort_TALM_vs_Haskell/run.sh
#
# Generates HSK -> codegen -> FL -> assembler -> FLB/PLA,
# runs the TALM interpreter, records metrics, and optionally plots.
#
# Placement is automatic via assembler autoplace (-a -n P).
#
# Env:
#   PY2=python2|python3     (assembler / TALM asm tooling; usually python2)
#   PY3=python3             (generators/plots)
#   SUPERS_FIXED=/abs/path/to/test/supers/21_merge_sort_super
#   LOG_ERR=1               (print stderr snippets on failures)
# ============================================================

START_N=0; STEP=0; N_MAX=0; REPS=1
PROCS_CSV=""
INTERP=""; ASM_ROOT=""; CODEGEN_ROOT=""
OUTROOT=""; VEC_MODE="range"; PLOTS="yes"; TAG="ms_super"

PY2="${PY2:-python2}"
PY3="${PY3:-python3}"
export LC_ALL=C
SUPERS_FORCE_PAR="${SUPERS_FORCE_PAR:-1}"
export SUPERS_FORCE_PAR
DF_LIST_BUILTIN="${DF_LIST_BUILTIN:-1}"
export DF_LIST_BUILTIN
MS_LEAF="${MS_LEAF:-array}"
export MS_LEAF
CUTOFF="${CUTOFF:-4096}"
CUTOFF_MODE="${CUTOFF_MODE:-fixed}" # fixed | scaled | perP | balanced | balanced2 | grain | leafgrain | leafsmooth | fixedleaves | msgrain
CUTOFF_MIN="${CUTOFF_MIN:-256}"
CUTOFF_MAX="${CUTOFF_MAX:-4096}"
CUTOFF_DIV="${CUTOFF_DIV:-16}"
CUTOFF_TARGET="${CUTOFF_TARGET:-8}"
CUTOFF_POW2="${CUTOFF_POW2:-1}"
GMIN="${GMIN:-8192}"
MS_GRAIN="${MS_GRAIN:-$GMIN}"
LEAF_OVERSUB="${LEAF_OVERSUB:-2}"
NPAR_FACTOR="${NPAR_FACTOR:-2}"
LEAF_CAP_MULT="${LEAF_CAP_MULT:-1}"
OVR_P_SLOPE="${OVR_P_SLOPE:-0.0}"
OVR_P_MODE="${OVR_P_MODE:-log}" # log | linear | pow
ROUND_Q="${ROUND_Q:-16}"
LEAF_MIN_LEAVES="${LEAF_MIN_LEAVES:-2}"
SEQ_P1="${SEQ_P1:-0}"
SUPERS_FIXED="${SUPERS_FIXED:-}"
USE_SUPERS=1

usage(){
  cat <<EOF
Usage:
  $0 --start-N A --step B --n-max C --reps R --procs "1,2,4,8" \\
     --interp PATH --asm-root PATH --codegen PATH --outroot PATH \\
     [--vec range|rand] [--plots yes|no] [--tag name]

Env:
  SUPERS_FIXED=/abs/path/test/supers/21_merge_sort_super
  PY2=python2  PY3=python3
  LOG_ERR=1
  CUTOFF_MODE=fixed|scaled|perP|balanced|balanced2|grain|leafgrain|leafsmooth|fixedleaves
  CUTOFF_MIN=256  CUTOFF_MAX=4096
  CUTOFF_DIV=16   CUTOFF_TARGET=8
  CUTOFF_POW2=1
  GMIN=8192  MS_GRAIN=8192  NPAR_FACTOR=2  LEAF_CAP_MULT=1  OVR_P_SLOPE=0.0  OVR_P_MODE=log  ROUND_Q=16  LEAF_MIN_LEAVES=2
  LEAF_OVERSUB=2
  SEQ_P1=0  # if 1, generate sequential (no super) for P=1 only
EOF
  exit 2
}

# ----------------- parse -----------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --start-N) START_N="$2"; shift 2;;
    --step) STEP="$2"; shift 2;;
    --n-max) N_MAX="$2"; shift 2;;
    --reps) REPS="$2"; shift 2;;
    --procs) PROCS_CSV="$2"; shift 2;;
    --interp) INTERP="$2"; shift 2;;
    --asm-root) ASM_ROOT="$2"; shift 2;;
    --codegen) CODEGEN_ROOT="$2"; shift 2;;
    --outroot) OUTROOT="$2"; shift 2;;
    --vec) VEC_MODE="$2"; shift 2;;
    --plots) PLOTS="$2"; shift 2;;
    --tag) TAG="$2"; shift 2;;
    *) usage;;
  esac
done

[[ -n "$START_N" && -n "$STEP" && -n "$N_MAX" && -n "$REPS" && -n "$PROCS_CSV" && -n "$INTERP" && -n "$ASM_ROOT" && -n "$CODEGEN_ROOT" && -n "$OUTROOT" ]] || usage

echo "[env ] PY3=${PY3} ; PY2=${PY2}"

[[ -x "$INTERP" ]] || { echo "[ERR ] interp is not executable: $INTERP"; exit 1; }
[[ -f "$ASM_ROOT/assembler.py" ]] || { echo "[ERR ] ASM_ROOT invalid (missing assembler.py): $ASM_ROOT"; exit 1; }

if [[ -x "$CODEGEN_ROOT/codegen" ]]; then
  CODEGEN="${CODEGEN_ROOT}/codegen"
else
  echo "[ERR ] could not find 'codegen' in: $CODEGEN_ROOT"
  exit 1
fi
echo "[talm] using codegen: $CODEGEN"

if [[ "$MS_LEAF" == "asm" ]]; then
  USE_SUPERS=0
  SUPERS_FIXED=""
  echo "[sup ] supers disabled (MS_LEAF=asm)"
elif [[ "$MS_LEAF" == "super" || "$MS_LEAF" == "coarse" ]]; then
  USE_SUPERS=1
  SUPERS_FIXED=""
  echo "[sup ] will build supers per-N (verify_sorted depends on N)"
else
  # array, coarse: use fixed supers
  USE_SUPERS=1
  if [[ -z "${SUPERS_FIXED}" ]]; then
    if [[ "$MS_LEAF" == "array" ]]; then
      CAND="${CODEGEN_ROOT}/test/supers/ms_array_super"
    elif [[ "$MS_LEAF" == "coarse" ]]; then
      CAND="${CODEGEN_ROOT}/test/supers/ms_coarse_super"
    else
      CAND="${CODEGEN_ROOT}/test/supers/21_merge_sort_super"
    fi
    [[ -f "$CAND/libsupers.so" ]] && SUPERS_FIXED="$CAND" || SUPERS_FIXED=""
  fi
  [[ -n "$SUPERS_FIXED" ]] || { echo "[ERR ] SUPERS_FIXED not set and default not found"; exit 1; }
  [[ -f "$SUPERS_FIXED/libsupers.so" ]] || { echo "[ERR ] libsupers.so not found under SUPERS_FIXED: $SUPERS_FIXED"; exit 1; }
  echo "[sup ] using fixed supers: $SUPERS_FIXED"
fi

BUILD_SUPERS="$(cd "$CODEGEN_ROOT" && pwd)/tools/build_supers.sh"

# Detect GHC shim environment (built by 'make supers_prepare')
SHIM_DIR="$(cd "$CODEGEN_ROOT" && pwd)/build/ghc-shim"
if [[ -d "$SHIM_DIR/rts" ]]; then
  GHC_VER="$(ghc --numeric-version)"
  SHIM_RTS_SO="$(ls "$SHIM_DIR/rts/libHSrts"*"-ghc${GHC_VER}.so" 2>/dev/null | head -1 || true)"
  if [[ -n "$SHIM_RTS_SO" ]]; then
    export GHC_LIBDIR="$SHIM_DIR"
    export RTS_SO="$SHIM_RTS_SO"
    if [[ -f "$SHIM_DIR/.cpath" ]]; then
      export C_INCLUDE_PATH="$(cat "$SHIM_DIR/.cpath")"
      export CPATH="$(cat "$SHIM_DIR/.cpath")"
    fi
    echo "[sup ] detected shim: GHC_LIBDIR=$GHC_LIBDIR  RTS_SO=$RTS_SO"
  fi
fi

MS_DIR="$(cd "$(dirname "$0")" && pwd)"
GEN_PY="$MS_DIR/gen_ms_input.py"
PLOT_PY="$MS_DIR/plot.py"
echo "[hsk ] using generator: $GEN_PY"

echo "[env ] MS_LEAF=${MS_LEAF}"

rm -rf "$OUTROOT"
mkdir -p "$OUTROOT"

METRICS_CSV="$OUTROOT/metrics_${TAG}.csv"
echo "variant,N,P,rep,seconds,rc" > "$METRICS_CSV"

IFS=',' read -r -a PROCS <<< "$PROCS_CSV"

# ----------------- helpers -----------------
make_abs() {
  local p="$1"
  if [[ "$p" = /* ]]; then
    printf "%s" "$p"
  else
    printf "%s/%s" "$(pwd)" "$p"
  fi
}

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
  "$PY3" "$GEN_PY" --out "$d/representative.hsk" --N "$N" --P 1 --vec "$VEC_MODE" --cutoff 256 --mode "$MS_LEAF" >&2
  bash "$BUILD_SUPERS" "$d/representative.hsk" "$d/Supers.hs" >&2
  [[ -f "$d/libsupers.so" ]] || { echo "[ERR ] super build failed for N=${N}" >&2; exit 1; }
  echo "[sup ] built: $d/libsupers.so" >&2
  echo "$d"
}

gen_hsk() {
  local N="$1" P="$2" out_hsk="$3"
  local mode="super"
  if [[ "$SEQ_P1" -eq 1 && "$P" -eq 1 ]]; then
    mode="seq"
  elif [[ "${MS_LEAF:-}" == "array" ]]; then
    mode="array"
  elif [[ "${MS_LEAF:-}" == "coarse" ]]; then
    mode="coarse"
  fi
  local cutoff="$CUTOFF"
  local scaled=0
  local denom=0
  if [[ "$CUTOFF_MODE" == "scaled" ]]; then
    scaled=$(( N / CUTOFF_DIV ))
    if [[ "$scaled" -lt "$CUTOFF_MIN" ]]; then
      cutoff="$CUTOFF_MIN"
    else
      cutoff="$scaled"
    fi
  elif [[ "$CUTOFF_MODE" == "perP" ]]; then
    denom=$(( P * CUTOFF_DIV ))
    scaled=$(( N / denom ))
    if [[ "$scaled" -lt "$CUTOFF_MIN" ]]; then
      cutoff="$CUTOFF_MIN"
    else
      cutoff="$scaled"
    fi
  elif [[ "$CUTOFF_MODE" == "balanced" || "$CUTOFF_MODE" == "balanced2" ]]; then
    local pscale=1
    if [[ "$CUTOFF_MODE" == "balanced2" ]]; then
      pscale=$(( P * P ))
    fi
    denom=$(( P * CUTOFF_TARGET * pscale ))
    if [[ "$denom" -le 0 ]]; then
      denom=1
    fi
    scaled=$(( (N + denom - 1) / denom ))
    if [[ "$scaled" -lt "$CUTOFF_MIN" ]]; then
      cutoff="$CUTOFF_MIN"
    else
      cutoff="$scaled"
    fi
    if [[ "$cutoff" -gt "$CUTOFF_MAX" ]]; then
      cutoff="$CUTOFF_MAX"
    fi
    if [[ "$CUTOFF_POW2" -eq 1 ]]; then
      local pow2=1
      while [[ "$pow2" -lt "$cutoff" ]]; do
        pow2=$(( pow2 << 1 ))
      done
      cutoff="$pow2"
    fi
    if [[ "${LEAF_MIN_LEAVES:-0}" -gt 1 ]]; then
      local max_cutoff=$(( (N + LEAF_MIN_LEAVES - 1) / LEAF_MIN_LEAVES ))
      if [[ "$cutoff" -gt "$max_cutoff" ]]; then
        cutoff="$max_cutoff"
      fi
    fi
  elif [[ "$CUTOFF_MODE" == "grain" ]]; then
    denom=$(( P ))
    if [[ "$denom" -le 0 ]]; then
      denom=1
    fi
    local npar=$(( NPAR_FACTOR * P * GMIN ))
    if [[ "$N" -lt "$npar" ]]; then
      cutoff="$N"
    else
      scaled=$(( (N + denom - 1) / denom ))
      if [[ "$scaled" -lt "$GMIN" ]]; then
        cutoff="$GMIN"
      else
        cutoff="$scaled"
      fi
      if [[ "$CUTOFF_POW2" -eq 1 ]]; then
        local pow2=1
        while [[ "$pow2" -lt "$cutoff" ]]; do
          pow2=$(( pow2 << 1 ))
        done
        cutoff="$pow2"
      fi
    fi
  elif [[ "$CUTOFF_MODE" == "leafgrain" ]]; then
    local lcap=$(( LEAF_CAP_MULT * P ))
    if [[ "$lcap" -le 0 ]]; then
      lcap=1
    fi
    local npar=$(( NPAR_FACTOR * P * GMIN ))
    if [[ "$N" -lt "$npar" ]]; then
      cutoff="$N"
    else
      scaled=$(( (N + lcap - 1) / lcap ))
      if [[ "$scaled" -lt "$GMIN" ]]; then
        cutoff="$GMIN"
      else
        cutoff="$scaled"
      fi
      if [[ "$cutoff" -gt "$CUTOFF_MAX" ]]; then
        cutoff="$CUTOFF_MAX"
      fi
      local max_cutoff=$(( (N + LEAF_MIN_LEAVES - 1) / LEAF_MIN_LEAVES ))
      if [[ "$max_cutoff" -lt 1 ]]; then
        max_cutoff=1
      fi
      if [[ "$cutoff" -gt "$max_cutoff" ]]; then
        cutoff="$max_cutoff"
      fi
      if [[ "$CUTOFF_POW2" -eq 1 ]]; then
        local pow2=1
        while [[ "$pow2" -lt "$cutoff" ]]; do
          pow2=$(( pow2 << 1 ))
        done
        cutoff="$pow2"
      fi
    fi
  elif [[ "$CUTOFF_MODE" == "leafsmooth" ]]; then
    local lcap=$(( LEAF_CAP_MULT * P ))
    if [[ "$lcap" -le 0 ]]; then
      lcap=1
    fi
    scaled=$(( (N + lcap - 1) / lcap ))
    local g_ovh
    g_ovh="$("$PY3" - <<PY
import math
P=${P}
gmin=${GMIN}
slope=${OVR_P_SLOPE}
q=${ROUND_Q}
mode="${OVR_P_MODE}"
if mode == "linear":
    val = gmin * (1.0 + slope * max(P - 1, 0))
elif mode == "pow":
    val = gmin * (max(P, 1) ** slope)
else:
    val = gmin * (1.0 + slope * math.log2(P if P > 0 else 1))
if q > 1:
    val = int(math.ceil(val / q) * q)
else:
    val = int(math.ceil(val))
print(int(val))
PY
)"
    cutoff=$(( scaled > g_ovh ? scaled : g_ovh ))
    if [[ "$cutoff" -gt "$CUTOFF_MAX" ]]; then
      cutoff="$CUTOFF_MAX"
    fi
    local max_cutoff=$(( (N + LEAF_MIN_LEAVES - 1) / LEAF_MIN_LEAVES ))
    if [[ "$max_cutoff" -lt 1 ]]; then
      max_cutoff=1
    fi
    if [[ "$cutoff" -gt "$max_cutoff" ]]; then
      cutoff="$max_cutoff"
    fi
  elif [[ "$CUTOFF_MODE" == "msgrain" ]]; then
    local grain="$MS_GRAIN"
    if [[ "$grain" -le 0 ]]; then
      grain="$GMIN"
    fi
    cutoff="$grain"
    if [[ "$cutoff" -lt "$CUTOFF_MIN" ]]; then
      cutoff="$CUTOFF_MIN"
    fi
    if [[ "$cutoff" -gt "$CUTOFF_MAX" ]]; then
      cutoff="$CUTOFF_MAX"
    fi
  elif [[ "$CUTOFF_MODE" == "fixedleaves" ]]; then
    local target=$(( LEAF_OVERSUB * P ))
    if [[ "$target" -le 1 ]]; then
      target=1
    fi
    local leaves=1
    while [[ "$leaves" -lt "$target" ]]; do
      leaves=$(( leaves << 1 ))
    done
    cutoff=$(( (N + leaves - 1) / leaves ))
    if [[ "$cutoff" -lt "$GMIN" ]]; then
      cutoff="$GMIN"
    fi
    if [[ "$cutoff" -gt "$CUTOFF_MAX" ]]; then
      cutoff="$CUTOFF_MAX"
    fi
    if [[ "$ROUND_Q" -gt 1 ]]; then
      cutoff=$(( ((cutoff + ROUND_Q - 1) / ROUND_Q) * ROUND_Q ))
    fi
  fi
  echo "[gen ] generating HSK (N=${N}, P=${P})"
  "$PY3" "$GEN_PY" --out "$out_hsk" --N "$N" --P "$P" --vec "$VEC_MODE" --cutoff "$cutoff" --mode "$mode"
}

build_fl() {
  local hsk="$1" fl="$2"
  echo "[cg  ] codegen $hsk -> $fl"
  "$CODEGEN" "$hsk" > "$fl"
}

assemble_auto() {
  # Produces:
  #   prefix.flb
  #   prefix.pla
  #   prefix_auto.pla   (this is what we run with)
  local fl="$1" prefix="$2" P="$3" logs_dir="$4"
  mkdir -p "$logs_dir"

  local fl_abs prefix_abs
  fl_abs="$(make_abs "$fl")"
  prefix_abs="$(make_abs "$prefix")"

  echo "[asm ] autoplace (-a) with -n P=${P}"
  local asm_cmd
  if [[ "${ASM_PROFILE:-0}" -eq 1 ]]; then
    local prof_out="$logs_dir/asm.prof"
    asm_cmd=("$PY2" -m cProfile -o "$prof_out" assembler.py -n "$P" -a -o "$prefix_abs" "$fl_abs")
  else
    asm_cmd=("$PY2" assembler.py -n "$P" -a -o "$prefix_abs" "$fl_abs")
  fi
  (
    cd "$ASM_ROOT"
    "${asm_cmd[@]}"
  ) >"$logs_dir/asm.out" 2>"$logs_dir/asm.err" || {
    local rc=$?
    echo "[ERR ] assembler autoplace failed (rc=$rc)."
    if [[ "${LOG_ERR:-0}" -eq 1 ]]; then
      echo "[ERR ] stderr (first 160 lines):"
      sed -n '1,160p' "$logs_dir/asm.err" || true
    fi
    echo "[ERR ] command was:"
    echo "  $PY2 $ASM_ROOT/assembler.py -n $P -a -o $prefix_abs $fl_abs"
    exit 1
  }

  [[ -f "${prefix_abs}.flb" && -f "${prefix_abs}.pla" && -f "${prefix_abs}_auto.pla" ]] || {
    echo "[ERR ] assembler did not produce expected outputs:"
    echo "       ${prefix_abs}.flb"
    echo "       ${prefix_abs}.pla"
    echo "       ${prefix_abs}_auto.pla"
    exit 1
  }

}

print_pla_load() {
  local pla="$1" P="$2"
  local line
  line="$(awk -v P="$P" '
    NR==1{next}
    {c[$1]++}
    END{
      for(i=0;i<P;i++){
        n=(i in c? c[i]:0);
        printf "%d:%d%s", i, n, (i<P-1?" ":"\n")
      }
    }' "$pla")"
  echo "[pla ] load: $line"
}

stage_supers_fixed() {
  local src="$1" case_dir="$2"
  local dst="$case_dir/supers/pkg"
  local cache
  cache="$(make_abs "${OUTROOT}/_supers_pkg_cache")"
  local use_cache="${SUPERS_PKG_CACHE:-1}"

  if [[ "${SUPERS_REBUILD:-0}" == "1" ]]; then
    local rr
    rr="$(cd "$(dirname "$0")/../.." && pwd -P)"
    local ghc_bin="${GHC:-ghc}"
    local ghc_libdir
    ghc_libdir="$("$ghc_bin" --print-libdir)"
    local ghc_inc="${ghc_libdir}/include"
    local rts_dir="${ghc_libdir}/rts"
    if [[ ! -d "$rts_dir" ]]; then
      rts_dir="$(find "$ghc_libdir" -type d -name rts 2>/dev/null | head -n 1)"
    fi
    local rts_so=""
    if [[ -n "$rts_dir" ]]; then
      rts_so="$(ls "$rts_dir"/libHSrts_thr-ghc*.so 2>/dev/null | head -n 1)"
      if [[ -z "$rts_so" ]]; then
        rts_so="$(ls "$rts_dir"/libHSrts-ghc*.so 2>/dev/null | head -n 1)"
      fi
    fi
    GHC_LIBDIR="$ghc_libdir" CFLAGS="-O2 -fPIC -I${ghc_inc}" \
      DYNLIB_DIR="$rts_dir" RTS_SO="$rts_so" \
      "$rr/tools/build_supers.sh" "$rr/test/21_merge_sort_super.hsk" \
      "$rr/test/supers/21_merge_sort_super/Supers.hs" >/dev/null
  fi

  if [[ "$use_cache" == "1" ]]; then
    if [[ ! -f "$cache/libsupers.so" ]]; then
      mkdir -p "$cache"
      cp -a "$src/." "$cache/"
    fi
    mkdir -p "$(dirname "$dst")"
    rm -rf "$dst"
    ln -s "$cache" "$dst"
  else
    mkdir -p "$dst"
    cp -a "$src/." "$dst/"
  fi

  [[ -f "$dst/libsupers.so" ]] || { echo "[ERR ] supers copy failed (missing libsupers.so): $dst"; exit 1; }
  printf "%s" "$dst/libsupers.so"
}

run_interp_time_rc() {
  # stdout: "<secs> <rc>"
  local P="$1" flb="$2" pla="$3" lib="$4" case_dir="$5"

  local logs="$case_dir/logs"
  mkdir -p "$logs"
  local outlog="$logs/run.out"
  local errlog="$logs/run.err"

  >&2 echo "[run ] interp: P=${P}"
  >&2 echo "[run ] flb=${flb}"
  >&2 echo "[run ] pla=${pla}"
  if [[ -n "$lib" ]]; then
    >&2 echo "[run ] lib=${lib}"
  else
    >&2 echo "[run ] lib=(none)"
  fi

  local t0 t1 pid rc=0
  t0=$(date +%s%N)

  local libdir="" ghcdeps=""
  if [[ -n "$lib" ]]; then
    libdir="$(dirname "$lib")"
    ghcdeps="$libdir/ghc-deps"
  fi

  local lock_env="${SUPERS_RTS_LOCK:-}"
  local serial_env="${SUPERS_SERIAL:-}"
  local worker_env="${SUPERS_WORKER:-}"
  local worker_main_env="${SUPERS_WORKER_MAIN:-}"
  local force_par_env="${SUPERS_FORCE_PAR:-}"
  local force_worker_env="${SUPERS_FORCE_WORKER:-}"
  local rts_n_env="${SUPERS_RTS_N:-}"
  local threaded_rts=0
  if [[ -n "$lib" ]] && command -v nm >/dev/null 2>&1; then
    if nm -D "$lib" 2>/dev/null | rg -q "hs_init_thread"; then
      threaded_rts=1
    fi
  fi
  if [[ -n "$force_par_env" && "$force_par_env" != "0" ]]; then
    lock_env=0
    serial_env=0
    worker_env=0
    worker_main_env=0
  fi
  if [[ -z "$force_par_env" && "$P" -gt 1 && "$threaded_rts" -eq 1 ]]; then
    force_par_env=1
    lock_env=0
    serial_env=0
    worker_env=0
    worker_main_env=0
  fi
  if [[ -z "$force_worker_env" || "$force_worker_env" == "0" ]]; then
    if [[ "$threaded_rts" -eq 1 ]]; then
      worker_env=0
      worker_main_env=0
    fi
  fi
  if [[ -z "$worker_main_env" && "$P" -gt 1 ]]; then
    if [[ "$threaded_rts" -eq 0 ]]; then
      worker_main_env=1
    fi
  fi
  if [[ -z "$worker_env" && "$worker_main_env" == "1" ]]; then
    worker_env=1
  fi
  if [[ -z "$lock_env" && "$P" -gt 1 && "$worker_main_env" != "1" ]]; then
    if [[ "$threaded_rts" -eq 0 ]]; then
      lock_env=1
    fi
  fi
  if [[ -z "$serial_env" && "$P" -gt 1 && "$worker_main_env" != "1" ]]; then
    if [[ "$threaded_rts" -eq 0 ]]; then
      serial_env=1
    fi
  fi
  if [[ -z "$rts_n_env" ]]; then
    rts_n_env="$P"
  fi

  if [[ -n "$lib" ]]; then
    SUPERS_RTS_LOCK="$lock_env" SUPERS_SERIAL="$serial_env" \
      SUPERS_WORKER="$worker_env" SUPERS_WORKER_MAIN="$worker_main_env" \
      SUPERS_RTS_N="$rts_n_env" SUPERS_FORCE_PAR="$force_par_env" \
      NUM_CORES="$P" \
      LD_LIBRARY_PATH="$libdir:$ghcdeps" \
      "$INTERP" "$P" "$flb" "$pla" "$lib" >"$outlog" 2>"$errlog" &
  else
    SUPERS_RTS_LOCK="$lock_env" SUPERS_SERIAL="$serial_env" \
      SUPERS_WORKER="$worker_env" SUPERS_WORKER_MAIN="$worker_main_env" \
      SUPERS_RTS_N="$rts_n_env" SUPERS_FORCE_PAR="$force_par_env" \
      NUM_CORES="$P" \
      "$INTERP" "$P" "$flb" "$pla" >"$outlog" 2>"$errlog" &
  fi
  pid=$!
  echo "$pid" >"$logs/pid"

  wait "$pid"
  rc=$?

  if [[ "$rc" -eq 0 ]]; then
    if rg -q -n "schedule: re-entered unsafely|newBoundTask: RTS is not initialised|symbol lookup error|interrupted|Error allocating instrs" "$errlog"; then
      rc=1
    fi
  fi
  if [[ "$rc" -eq 0 ]]; then
    if ! rg -q -n "Procs[[:space:]]+[0-9]+" "$errlog"; then
      rc=1
    fi
  fi

  t1=$(date +%s%N)
  # Prefer internal EXEC_TIME_S from interpreter (no startup overhead)
  local exec_t=""
  if [[ -f "$errlog" ]]; then
    exec_t=$(grep -oP 'EXEC_TIME_S \K[0-9.]+' "$errlog" 2>/dev/null || true)
  fi

  # Correctness check: for super mode, verify output is "1"
  if [[ "$rc" -eq 0 && ( "$MS_LEAF" == "super" || "$MS_LEAF" == "coarse" || "$MS_LEAF" == "array" ) && -f "$outlog" ]]; then
    local result; result="$(grep -oP '^\d+$' "$outlog" | head -1 || true)"
    if [[ -n "$result" && "$result" != "1" ]]; then
      >&2 echo "[ERR ] WRONG ANSWER: got '$result', expected '1'"
      rc=99
    elif [[ -z "$result" ]]; then
      >&2 echo "[ERR ] No result found in output"
      rc=98
    fi
  fi

  if [[ -n "$exec_t" ]]; then
    LC_ALL=C awk -v T="$exec_t" -v R="$rc" 'BEGIN{ printf "%.6f %d", T, R }'
  else
    LC_ALL=C awk -v A="$t0" -v B="$t1" -v R="$rc" 'BEGIN{ printf "%.6f %d", (B-A)/1e9, R }'
  fi
}

# ----------------- main -----------------
for N in $(seq "$START_N" "$STEP" "$N_MAX"); do
  echo ""
  echo "======== N=${N} ========"
  # Pre-build supers for this N
  if [[ "$MS_LEAF" == "super" || "$MS_LEAF" == "coarse" ]]; then
    get_supers_dir "$N" > /dev/null
  fi
  for P in "${PROCS[@]}"; do
    CASE_DIR="$OUTROOT/super/N_${N}/P_${P}"
    LOGS_DIR="$CASE_DIR/logs"
    mkdir -p "$CASE_DIR" "$LOGS_DIR"

    HSK="$CASE_DIR/mergesort_super_N${N}_P${P}.hsk"
    FL="$CASE_DIR/mergesort_super_N${N}_P${P}.fl"
    PREFIX="$CASE_DIR/mergesort_super_N${N}_P${P}"

    gen_hsk "$N" "$P" "$HSK"
    build_fl "$HSK" "$FL"

    assemble_auto "$FL" "$PREFIX" "$P" "$LOGS_DIR"
    PLA_USED="${PREFIX}_auto.pla"

    print_pla_load "$PLA_USED" "$P"

    LIBSUP=""
    if [[ "$USE_SUPERS" -eq 1 ]]; then
      if [[ "$MS_LEAF" == "super" || "$MS_LEAF" == "coarse" ]]; then
        LIBSUP="$(get_supers_dir "$N")/libsupers.so"
      else
        LIBSUP="$(stage_supers_fixed "$SUPERS_FIXED" "$CASE_DIR")"
      fi
    fi

    for ((rep=1; rep<=REPS; rep++)); do
      retries=0; max_retries=2
      while true; do
        set +e
        out="$(run_interp_time_rc "$P" "${PREFIX}.flb" "$PLA_USED" "$LIBSUP" "$CASE_DIR")"
        st=$?
        set -e

        secs="NaN"; rc=999
        if [[ $st -eq 0 ]]; then
          if ! read -r secs rc <<< "$out"; then
            secs="NaN"; rc=998
          fi
        fi

        # Retry on rc=98 (intermittent missing output)
        if [[ "$rc" -eq 98 && "$retries" -lt "$max_retries" ]]; then
          retries=$((retries + 1))
          echo "[warn] rc=98, retrying (attempt $((retries+1))/$((max_retries+1)))"
          continue
        fi
        break
      done

      echo "variant=super, N=${N}, P=${P}, rep=${rep}, secs=${secs}, rc=${rc}"
      echo "super,${N},${P},${rep},${secs},${rc}" >> "$METRICS_CSV"

      if [[ "${LOG_ERR:-0}" -eq 1 && "$rc" -ne 0 ]]; then
        echo "[err ] ${CASE_DIR}/logs/run.err"
        sed -n '1,160p' "$CASE_DIR/logs/run.err" || true
      fi
    done
  done
done

if [[ "$PLOTS" == "yes" ]]; then
  "$PY3" "$PLOT_PY" --metrics "$METRICS_CSV" --outdir "$OUTROOT" --tag "$TAG"
fi

echo "[DONE] results in: $OUTROOT"
