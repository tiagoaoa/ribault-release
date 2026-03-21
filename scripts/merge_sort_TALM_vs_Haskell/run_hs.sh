#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# merge_sort/run_hs.sh — baseline GHC parallel (-N)
# ============================================================

START_N=0; STEP=0; N_MAX=0; REPS=1
PROCS_CSV=""; OUTROOT=""; VEC_MODE="range"; TAG="ghc_ms"
GEN_OVERRIDE=""
VARIANT="ghc"
GHC="${GHC:-ghc}"
GHC_PKGS="${GHC_PKGS:--package time}"
PY3="${PY3:-python3}"

usage(){
  echo "uso: $0 --start-N A --step B --n-max C --reps R --procs \"1,2,...\" --outroot DIR [--vec range|rand] [--tag nome] [--gen script.py] [--variant name]"
  echo "env: GHC=ghc  PY3=python3"
  exit 2
}

# ----------------- parse -----------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --start-N) START_N="$2"; shift 2;;
    --step)    STEP="$2";    shift 2;;
    --n-max)   N_MAX="$2";   shift 2;;
    --reps)    REPS="$2";    shift 2;;
    --procs)   PROCS_CSV="$2"; shift 2;;
    --outroot) OUTROOT="$2"; shift 2;;
    --vec)     VEC_MODE="$2"; shift 2;;
    --tag)     TAG="$2"; shift 2;;
    --gen)     GEN_OVERRIDE="$2"; shift 2;;
    --variant) VARIANT="$2"; shift 2;;
    *) usage;;
  esac
done

[[ -n "$START_N$STEP$N_MAX$REPS$PROCS_CSV$OUTROOT" ]] || usage

command -v "$GHC" >/dev/null || { echo "[ERRO] GHC não encontrado: $GHC"; exit 1; }
echo "[env ] GHC=${GHC} ; PY3=${PY3} ; GHC_PKGS=${GHC_PKGS}"

MS_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -n "$GEN_OVERRIDE" ]]; then
  GEN_HS="$GEN_OVERRIDE"
else
  GEN_HS="$MS_DIR/gen_hs_input.py"
fi
[[ -f "$GEN_HS" ]] || { echo "[ERRO] não achei: $GEN_HS"; exit 1; }
echo "[hs  ] usando gerador: $GEN_HS"

mkdir -p "$OUTROOT"
METRICS_CSV="$OUTROOT/metrics_${TAG}.csv"
echo "variant,N,P,rep,seconds,rc" > "$METRICS_CSV"

IFS=',' read -r -a PROCS <<< "$PROCS_CSV"

# ----------------- helpers -----------------
gen_hs() {
  local N="$1" out_hs="$2"
  "$PY3" "$GEN_HS" --out "$out_hs" --N "$N" --vec "$VEC_MODE"
}

build_bin() {
  local hs="$1" bin="$2"
  echo "[ghc ] compiling $hs -> $bin"
  "$GHC" $GHC_PKGS -threaded -rtsopts -o "$bin" "$hs" >/dev/null
}

run_bin_time_rc() {
  # stdout: "<secs> <rc>"
  local bin="$1" P="$2" logs="$3"
  mkdir -p "$logs"
  local outlog="$logs/run.out" errlog="$logs/run.err"
  set +e
  "$bin" +RTS -N"$P" -RTS >"$outlog" 2>"$errlog"
  local rc=$?
  set -e
  local secs="NaN"
  if [[ $rc -eq 0 ]]; then
    secs="$(awk -F= '/^RUNTIME_SEC=/{print $2; found=1} END{if(!found) print "NaN"}' "$outlog")"
    # Verify sorting correctness
    local sorted_val
    sorted_val="$(awk -F= '/^SORTED=/{print $2}' "$outlog" 2>/dev/null || true)"
    if [[ -n "$sorted_val" && "$sorted_val" != "True" ]]; then
      >&2 echo "[ERR ] SORT INCORRECT: SORTED=$sorted_val"
      rc=99
    elif [[ -z "$sorted_val" ]]; then
      >&2 echo "[WARN] SORTED= line missing from output"
    fi
  fi
  echo "$secs $rc"
}

# ----------------- main -----------------
N="$START_N"
while [[ "$N" -le "$N_MAX" ]]; do
  NDIR="$OUTROOT/ghc/N_${N}"
  mkdir -p "$NDIR/bin"
  HS="$NDIR/bin/ms_hs_N${N}.hs"
  BIN="$NDIR/bin/ms_hs_N${N}"
  gen_hs "$N" "$HS"
  build_bin "$HS" "$BIN"

  for P in "${PROCS[@]}"; do
    CASE_DIR="$OUTROOT/ghc/N_${N}/P_${P}"
    mkdir -p "$CASE_DIR/logs"
    for ((rep=1; rep<=REPS; rep++)); do
      out="$(run_bin_time_rc "$BIN" "$P" "$CASE_DIR/logs")"
      read -r secs rc <<< "$out"
      echo "variant=ghc, N=${N}, P=${P}, rep=${rep}, secs=${secs}, rc=${rc}"
      echo "${VARIANT},${N},${P},${rep},${secs},${rc}" >> "$METRICS_CSV"
    done
  done
  N=$((N + STEP))
done

echo "[DONE] resultados em: $OUTROOT"
echo "[plot] gerando graficos"
"$PY3" "$MS_DIR/plot_hs.py" \
  --metrics "$METRICS_CSV" \
  --outdir "$OUTROOT" \
  --tag "$TAG"
