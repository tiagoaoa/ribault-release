#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# TALM_examples_test/run_talm_example.sh
# ------------------------------------------------------------
# Run a standalone TALM .fl example with the TALM interpreter.
# - No supers .so is used.
# - Assembles .fl -> .flb/.pla with Python2 assembler.
# - Rewrites .pla manually (round-robin or chunk).
# - Runs interp via taskset across multiple P values.
# - Records timings to CSV.
#
# Env you can set:
#   PY2=python2 (or py2)
#   PLACE_MODE=rr|chunk  (default rr)
# ============================================================

PY2="${PY2:-python2}"
PLACE_MODE="${PLACE_MODE:-rr}"

usage() {
  cat <<EOF
Usage:
  $0 \\
    --fl PATH_TO_EXAMPLE.fl \\
    --interp PATH_TO_interp \\
    --asm-root PATH_TO_TALM_asm \\
    --outroot PATH_FOR_RESULTS \\
    --procs "1,2,4,6" \\
    --reps 5 \\
    [--cpus "CPUSET"] [--tag NAME] [--plots yes|no]

Notes:
  - Only ASM path is used (no supers).
  - --cpus goes to 'taskset -c'. Default: all online CPUs (e.g. 0-11).
  - Results CSV: <outroot>/metrics_<tag>.csv (columns: variant,N,P,rep,seconds,rc)
  - N is fixed to 0 for this synthetic example.

Example:
  PLACE_MODE=rr PY2=py2 \\
  $0 \\
    --fl /home/ricky/Desktop/TALM/examples/add_two_calls.fl \\
    --interp /home/ricky/Desktop/TALM/interp/interp \\
    --asm-root /home/ricky/Desktop/TALM/asm \\
    --outroot results/TALM_examples/add_two_calls \\
    --procs "1,2,4,6" \\
    --reps 10 \\
    --cpus "0-11" \\
    --tag add_calls \\
    --plots no
EOF
  exit 2
}

# ----------------- parse args -----------------
FL=""; INTERP=""; ASM_ROOT=""; OUTROOT=""
PROCS_CSV=""; REPS=""
TAG="talm_example"; PLOTS="no"; CPU_LIST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fl) FL="$2"; shift 2;;
    --interp) INTERP="$2"; shift 2;;
    --asm-root) ASM_ROOT="$2"; shift 2;;
    --outroot) OUTROOT="$2"; shift 2;;
    --procs) PROCS_CSV="$2"; shift 2;;
    --reps) REPS="$2"; shift 2;;
    --tag) TAG="$2"; shift 2;;
    --plots) PLOTS="$2"; shift 2;;
    --cpus) CPU_LIST="$2"; shift 2;;
    *) usage;;
  esac
done

[[ -n "$FL$INTERP$ASM_ROOT$OUTROOT$PROCS_CSV$REPS" ]] || usage

[[ -f "$FL" ]] || { echo "[ERR] .fl not found: $FL"; exit 1; }
[[ -x "$INTERP" ]] || { echo "[ERR] interp not executable: $INTERP"; exit 1; }
[[ -f "$ASM_ROOT/assembler.py" ]] || { echo "[ERR] ASM_ROOT invalid: $ASM_ROOT"; exit 1; }

IFS=',' read -r -a PROCS <<< "$PROCS_CSV"

# taskset CPU list (default: all online)
if [[ -z "$CPU_LIST" ]]; then
  if [[ -r /sys/devices/system/cpu/online ]]; then
    CPU_LIST="$(cat /sys/devices/system/cpu/online)"
  else
    NCORES=$(nproc --all)
    CPU_LIST="0-$((NCORES-1))"
  fi
fi

echo "[env ] PY2=${PY2}  PLACE_MODE=${PLACE_MODE}"
echo "[sched] taskset CPU list: ${CPU_LIST}"

mkdir -p "$OUTROOT"
METRICS_CSV="$OUTROOT/metrics_${TAG}.csv"
echo "variant,N,P,rep,seconds,rc" > "$METRICS_CSV"

# ----------------- helpers -----------------
assemble_baseline() {
  local src_fl="$1" prefix="$2"
  local fl_abs prefix_abs
  fl_abs="$(cd "$(dirname "$src_fl")" && pwd)/$(basename "$src_fl")"
  prefix_abs="$(cd "$(dirname "$prefix")" && pwd)/$(basename "$prefix")"
  pushd "$ASM_ROOT" >/dev/null
    echo "[asm ] assembling -> ${prefix_abs}.flb/.pla"
    "$PY2" assembler.py -o "$prefix_abs" "$fl_abs" >/dev/null
  popd >/dev/null
  [[ -f "${prefix_abs}.flb" && -f "${prefix_abs}.pla" ]] \
    || { echo "[ERR] assembler did not produce .flb/.pla at ${prefix_abs}.*"; exit 1; }
  cp "${prefix_abs}.pla" "${prefix_abs}.pla.base"
}

rewrite_pla_manual() {
  local prefix="$1" P="$2" mode="$3"
  local base="${prefix}.pla.base"
  local pla="${prefix}.pla"
  local nt; nt="$(head -n1 "$base" | tr -d '\r')"
  [[ "$nt" =~ ^[0-9]+$ ]] || { echo "[ERR] invalid first line in ${base}"; exit 1; }

  if (( P <= 1 )); then
    echo "[pla ] P=1 -> all on PE 0"
    awk -v N="$nt" 'BEGIN{print N} NR>1{print 0}' "$base" > "$pla"
    return
  fi

  case "$mode" in
    rr|RR)
      echo "[pla ] manual RR: ntasks=${nt}, P=${P}"
      awk -v P="$P" -v N="$nt" 'BEGIN{print N} NR>1{ i=NR-2; print (i%P) }' "$base" > "$pla"
      ;;
    chunk|CHUNK)
      echo "[pla ] manual CHUNK: ntasks=${nt}, P=${P}"
      awk -v P="$P" -v N="$nt" 'BEGIN{print N} NR>1{ i=NR-2; printf "%d\n", int((i*P)/N) }' "$base" > "$pla"
      ;;
    *) echo "[ERR] invalid PLACE_MODE: $mode"; exit 1;;
  esac
}

print_pla_load() {
  local pla="$1" P="$2"
  local line; line="$(awk -v P="$P" '
    NR==1{N=$1; next}
    {c[$1]++}
    END{
      for(i=0;i<P;i++){
        n=(i in c? c[i]:0);
        printf "%d:%d%s", i, n, (i<P-1?" ":"\n")
      }
    }' "$pla")"
  echo "[pla ] load: $line"
}

run_interp_time_rc() {
  # stdout: "<secs> <rc>"
  local P="$1" flb="$2" pla="$3" case_dir="$4"
  local logs="$case_dir/logs"; mkdir -p "$logs"
  local outlog="$logs/run.out" errlog="$logs/run.err"
  local t0 t1 rc=0

  >&2 echo "[run ] interp P=${P}"
  >&2 echo "[run ] flb=${flb}"
  >&2 echo "[run ] pla=${pla}"

  t0=$(date +%s%N)
  if ! taskset -c "${CPU_LIST}" "$INTERP" "$P" "$flb" "$pla" >"$outlog" 2>"$errlog"; then
    rc=$?
  fi
  t1=$(date +%s%N)
  awk -v A="$t0" -v B="$t1" -v R="$rc" 'BEGIN{ printf "%.6f %d", (B-A)/1e9, R }'
}

# ----------------- main -----------------
# Copy the .fl once into OUTROOT/src to keep things tidy
mkdir -p "$OUTROOT/src"
FL_COPY="$OUTROOT/src/$(basename "$FL")"
cp -f "$FL" "$FL_COPY"

for P in "${PROCS[@]}"; do
  CASE_DIR="$OUTROOT/P_${P}"
  mkdir -p "$CASE_DIR"
  PREFIX="$CASE_DIR/example_P${P}"

  assemble_baseline "$FL_COPY" "$PREFIX"
  rewrite_pla_manual "$PREFIX" "$P" "$PLACE_MODE"
  print_pla_load "${PREFIX}.pla" "$P"

  for ((rep=1; rep<=REPS; rep++)); do
    set +e
    out="$(run_interp_time_rc "$P" "${PREFIX}.flb" "${PREFIX}.pla" "$CASE_DIR")"
    st=$?
    set -e
    secs="NaN"; rc=999
    if [[ $st -eq 0 ]]; then
      read -r secs rc <<< "$out" || { secs="NaN"; rc=998; }
    fi
    echo "variant=asm_example, N=0, P=${P}, rep=${rep}, secs=${secs}, rc=${rc}"
    echo "asm_example,0,${P},${rep},${secs},${rc}" >> "$METRICS_CSV"

    if [[ "${LOG_ERR:-0}" -eq 1 && "$rc" -ne 0 ]]; then
      echo "[err] $CASE_DIR/logs/run.err"
      sed -n '1,120p' "$CASE_DIR/logs/run.err" || true
    fi
  done
done

echo "[DONE] results in: $OUTROOT"
echo "[INFO] CSV: $METRICS_CSV"
