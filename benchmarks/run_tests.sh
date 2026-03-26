#!/usr/bin/env bash
set -euo pipefail
# ──────────────────────────────────────────────────────────────
# run_tests.sh — Compile (and optionally execute) all test/*.hss
# ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TALM_DIR="${ROOT}/TALM"
EXECUTE=0
FILTER="*.hss"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --execute)  EXECUTE=1;       shift ;;
        --talm-dir) TALM_DIR="$2";   shift 2 ;;
        --filter)   FILTER="$2";     shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--execute] [--talm-dir DIR] [--filter GLOB]"
            exit 0 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

# Ensure compiler is built
for tool in analysis synthesis codegen; do
    [ -x "$ROOT/$tool" ] || { echo "Building compiler..."; make -C "$ROOT" compiler; break; }
done

echo ""
echo "══════════════════════════════════════════════════════════"
echo " Ribault Test Suite"
echo "══════════════════════════════════════════════════════════"
echo " Test dir: $ROOT/test/"
echo " Filter:   $FILTER"
echo " Execute:  $([ "$EXECUTE" -eq 1 ] && echo 'yes (Trebuchet)' || echo 'no (compile-only)')"
echo "══════════════════════════════════════════════════════════"
echo ""

PASS=0; FAIL=0; SKIP=0

for hsk in "$ROOT"/test/$FILTER; do
    [ -f "$hsk" ] || continue
    name="$(basename "$hsk" .hss)"
    printf "  %-40s " "$name"
    tmp=$(mktemp -d)

    # Phases 1-3: analysis → synthesis → codegen
    if "$ROOT/analysis" "$hsk" > "$tmp/ast.dot" 2>/dev/null \
       && "$ROOT/synthesis" "$hsk" > "$tmp/df.dot" 2>/dev/null \
       && "$ROOT/codegen" "$hsk" > "$tmp/code.fl" 2>/dev/null; then

        if [ "$EXECUTE" -eq 1 ] && [ -x "$TALM_DIR/interp/interp" ]; then
            # Phase 4: build supers + assemble + execute
            "$ROOT/supersgen" "$hsk" > "$tmp/Supers.hs" 2>/dev/null || true
            if SUPERS_DIR="$tmp" bash "$ROOT/tools/build_supers.sh" "$hsk" "$tmp/Supers.hs" 2>/dev/null; then
                python3 "$TALM_DIR/asm/assembler.py" -a -n 1 -o "$tmp/$name" "$tmp/code.fl" 2>/dev/null
                libsupers="$(find "$tmp" -name 'libsupers.so' 2>/dev/null | head -1)"
                if [ -n "$libsupers" ] && [ -f "$tmp/${name}.flb" ]; then
                    if timeout 30 "$TALM_DIR/interp/interp" 1 \
                         "$tmp/${name}.flb" "$tmp/${name}_auto.pla" "$libsupers" >/dev/null 2>&1; then
                        printf "PASS (executed)\n"; PASS=$((PASS+1))
                    else
                        printf "FAIL (runtime)\n"; FAIL=$((FAIL+1))
                    fi
                else
                    printf "SKIP (no libsupers)\n"; SKIP=$((SKIP+1))
                fi
            else
                printf "SKIP (supers build)\n"; SKIP=$((SKIP+1))
            fi
        else
            printf "PASS\n"; PASS=$((PASS+1))
        fi
    else
        printf "FAIL (compile)\n"; FAIL=$((FAIL+1))
    fi
    rm -rf "$tmp"
done

echo ""
echo "══════════════════════════════════════════════════════════"
printf " %d passed, %d failed, %d skipped\n" "$PASS" "$FAIL" "$SKIP"
echo "══════════════════════════════════════════════════════════"
[ "$FAIL" -eq 0 ] || exit 1
