#!/usr/bin/env bash
set -euo pipefail
# ──────────────────────────────────────────────────────────────
# run_benchmarks.sh — Performance benchmark harness
# ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TALM_DIR="${ROOT}/TALM"
OUTPUT_DIR="${ROOT}/results/runs/$(date +%Y%m%d_%H%M%S)"
THREADS="1 2 4 8 16"
REPS=5

while [[ $# -gt 0 ]]; do
    case "$1" in
        --threads)    THREADS="$2";    shift 2 ;;
        --reps)       REPS="$2";       shift 2 ;;
        --talm-dir)   TALM_DIR="$2";   shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--threads LIST] [--reps N] [--talm-dir DIR] [--output-dir DIR]"
            exit 0 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

[ -x "$TALM_DIR/interp/interp" ] || { echo "ERROR: Trebuchet not built ($TALM_DIR/interp/interp)"; exit 1; }
[ -x "$ROOT/codegen" ]           || { echo "Building compiler..."; make -C "$ROOT" compiler; }

mkdir -p "$OUTPUT_DIR"

echo "══════════════════════════════════════════════════════════"
echo " Ribault Benchmark Suite"
echo "══════════════════════════════════════════════════════════"
echo " TALM:    $TALM_DIR"
echo " Threads: $THREADS"
echo " Reps:    $REPS"
echo " Output:  $OUTPUT_DIR"
echo "══════════════════════════════════════════════════════════"
echo ""

# Scan scripts/ for benchmark directories containing .hss files
found=0
for bench_dir in "$ROOT"/scripts/*/; do
    [ -d "$bench_dir" ] || continue
    shopt -s nullglob
    hsk_files=("$bench_dir"*.hss)
    shopt -u nullglob
    [ ${#hsk_files[@]} -eq 0 ] && continue

    found=1
    bench_name="$(basename "$bench_dir")"
    echo "── $bench_name ──"
    csv="$OUTPUT_DIR/${bench_name}.csv"
    echo "P,variant,rep,time_s" > "$csv"

    for hsk in "${hsk_files[@]}"; do
        variant="$(basename "$hsk" .hss)"
        for P in $THREADS; do
            for r in $(seq 1 "$REPS"); do
                tmp=$(mktemp -d)
                "$ROOT/codegen" "$hsk" > "$tmp/prog.fl" 2>/dev/null || true
                "$ROOT/supersgen" "$hsk" > "$tmp/Supers.hs" 2>/dev/null || true
                SUPERS_DIR="$tmp" bash "$ROOT/tools/build_supers.sh" "$hsk" "$tmp/Supers.hs" 2>/dev/null || true
                python3 "$TALM_DIR/asm/assembler.py" -a -n "$P" -o "$tmp/prog" "$tmp/prog.fl" 2>/dev/null || true
                libsupers="$(find "$tmp" -name 'libsupers.so' 2>/dev/null | head -1)"
                if [ -n "$libsupers" ] && [ -f "$tmp/prog.flb" ]; then
                    cores=$(seq -s, 0 $((P-1)))
                    start=$(date +%s%N)
                    taskset -c "$cores" "$TALM_DIR/interp/interp" "$P" \
                        "$tmp/prog.flb" "$tmp/prog_auto.pla" "$libsupers" >/dev/null 2>&1 || true
                    end=$(date +%s%N)
                    t=$(echo "scale=6; ($end - $start) / 1000000000" | bc)
                    echo "$P,$variant,$r,$t" >> "$csv"
                    printf "  P=%-3s rep=%-2s %-20s %s s\n" "$P" "$r" "$variant" "$t"
                fi
                rm -rf "$tmp"
            done
        done
    done
    echo "  → $csv"
    echo ""
done

[ "$found" -eq 1 ] || echo "No benchmark .hss files found in scripts/*/"

echo "══════════════════════════════════════════════════════════"
echo " Done. Results: $OUTPUT_DIR"
echo "══════════════════════════════════════════════════════════"
