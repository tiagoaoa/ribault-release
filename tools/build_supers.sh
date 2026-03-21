#!/usr/bin/env bash
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
Usage:
  tools/build_supers.sh <input.hsk> <output/Supers.hs>
  tools/build_supers.sh
    (auto: scan test/*.hsk and generate+build test/supers/*/Supers.hs + libsupers.so)

Environment:
  GHC                  (default: ghc)
  CC                   (default: gcc)
  CFLAGS               (default: -O2 -fPIC)
  SUPERS_WRAPPERS_MAX  (default: 256) number of superN wrappers to emit

Optional environment (if your Makefile already computes them, we will reuse them):
  GHC_VER
  GHC_LIBDIR
  DYNLIB_DIR
  RTS_SO

This script:
  1) Runs ./supersgen to generate Supers.hs
  2) Normalizes the Haskell module name so it is NOT Main (avoids GHC main requirement)
  3) Generates C stubs:
       - supers_aliases.c  (empty, for Makefile compatibility)
       - supers_wrappers.c (exports super0..superN-1; calls weak s0..sN-1 if present)
  4) Builds a relocatable shared library bundle in the same directory as Supers.hs:
       - libsupers.so
       - ghc-deps/ (copies relevant libHS* + libgmp/libffi dependencies)
  5) Forces the GHC RTS into DT_NEEDED to avoid dlopen() failures on unresolved stg_* symbols.
EOF
  exit 2
}

repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P
}

detect_ghc_ver() {
  local ghc="$1"
  "$ghc" --numeric-version
}

is_real_ghc_libdir() {
  local d="$1"
  [[ -n "$d" ]] || return 1
  [[ -d "$d" ]] || return 1
  [[ -f "$d/settings" ]] || return 1
  [[ -d "$d/package.conf.d" ]] || return 1
  return 0
}

detect_ghc_libdir_raw() {
  local ghc="$1"
  "$ghc" --print-libdir
}

# If the GHC binary is a shim and --print-libdir is not a real GHC libdir,
# fall back to ghcup's standard layout for the detected version.
resolve_ghc_libdir() {
  local ghc="$1"
  local ghc_ver="$2"

  local d
  d="$(detect_ghc_libdir_raw "$ghc" 2>/dev/null || true)"
  if is_real_ghc_libdir "$d"; then
    echo "$d"
    return 0
  fi

  # ghcup fallback (matches your RTS path in the make output)
  local cand="$HOME/.ghcup/ghc/$ghc_ver/lib/ghc-$ghc_ver/lib"
  if is_real_ghc_libdir "$cand"; then
    echo "$cand"
    return 0
  fi

  # distro fallback
  cand="/usr/lib/ghc"
  if is_real_ghc_libdir "$cand"; then
    echo "$cand"
    return 0
  fi

  # last resort: return whatever we got (caller will fail with a clear error)
  echo "$d"
}

# Robust for ghcup and distro layouts:
# We find the directory that actually contains libHSbase-*-ghc<ver>.so etc.
detect_dynlib_dir() {
  local ghc_libdir="$1"
  local ghc_ver="$2"

  local -a cands=()

  # ghcup-style (from libdir)
  cands+=("$ghc_libdir/lib/../lib/x86_64-linux-ghc-$ghc_ver")
  cands+=("$ghc_libdir/../lib/x86_64-linux-ghc-$ghc_ver")
  cands+=("$ghc_libdir/lib/../lib/"*"-ghc$ghc_ver")
  cands+=("$ghc_libdir/../lib/"*"-ghc$ghc_ver")

  # ghcup direct (even if libdir came from a shim)
  cands+=("$HOME/.ghcup/ghc/$ghc_ver/lib/ghc-$ghc_ver/lib/../lib/x86_64-linux-ghc-$ghc_ver")
  cands+=("$HOME/.ghcup/ghc/$ghc_ver/lib/ghc-$ghc_ver/lib/../lib/"*"-ghc$ghc_ver")

  local d
  for d in "${cands[@]}"; do
    [[ -d "$d" ]] || continue
    if ls -1 "$d"/libHSbase-*-ghc"${ghc_ver}".so >/dev/null 2>&1; then
      echo "$d"
      return 0
    fi
    if ls -1 "$d"/libHSghc-prim-*-ghc"${ghc_ver}".so >/dev/null 2>&1; then
      echo "$d"
      return 0
    fi
    if ls -1 "$d"/libHSrts-*-ghc"${ghc_ver}".so >/dev/null 2>&1; then
      echo "$d"
      return 0
    fi
  done

  # Shim layout: symlinked package dirs under GHC_LIBDIR
  if ls -1 "$ghc_libdir"/libHSbase-*-ghc"${ghc_ver}".so >/dev/null 2>&1; then
    echo "$ghc_libdir"
    return 0
  fi
  for d in "$ghc_libdir"/*; do
    [[ -d "$d" ]] || continue
    if ls -1 "$d"/libHSbase-*-ghc"${ghc_ver}".so >/dev/null 2>&1; then
      echo "$d"
      return 0
    fi
  done

  echo ""
}

dynlib_dir_from_rts() {
  local rts_so="$1"
  [[ -n "$rts_so" && -f "$rts_so" ]] || { echo ""; return 0; }
  dirname "$rts_so"
}

# Prefer non-debug RTS, then threaded, and only use debug as last resort.
detect_rts_so() {
  local dynlib_dir="$1"
  local ghc_ver="$2"
  local prefer_thr="${SUPERS_THREADED:-1}"

  [[ -n "$dynlib_dir" && -d "$dynlib_dir" ]] || { echo ""; return 0; }

  local -a cands=()
  if [[ "$prefer_thr" == "1" ]]; then
    cands+=(
      "$dynlib_dir/libHSrts_thr-ghc${ghc_ver}.so"
      "$dynlib_dir/libHSrts_thr-"*"-ghc${ghc_ver}.so"
      "$dynlib_dir/libHSrts-"*"_thr-ghc${ghc_ver}.so"
      "$dynlib_dir/libHSrts-"*"-ghc${ghc_ver}.so"
      "$dynlib_dir/libHSrts-"*"_debug-ghc${ghc_ver}.so"
      "$dynlib_dir/libHSrts-"*.so
    )
  else
    cands+=(
      "$dynlib_dir/libHSrts-"*"-ghc${ghc_ver}.so"
      "$dynlib_dir/libHSrts_thr-ghc${ghc_ver}.so"
      "$dynlib_dir/libHSrts_thr-"*"-ghc${ghc_ver}.so"
      "$dynlib_dir/libHSrts-"*"_debug-ghc${ghc_ver}.so"
      "$dynlib_dir/libHSrts-"*.so
    )
  fi

  local f
  for f in "${cands[@]}"; do
    [[ -f "$f" ]] || continue
    echo "$f"
    return 0
  done

  echo ""
}

normalize_hs_module() {
  local hs="$1"
  [[ -f "$hs" ]] || die "normalize_hs_module: missing file: $hs"

  local tmp
  tmp="$(mktemp)"

  awk '
  function strip_bom(s) {
    if (NR == 1) sub(/^\xef\xbb\xbf/, "", s)
    return s
  }
  function is_pragma(line) { return (line ~ /^[[:space:]]*{-#/) }
  function is_module_start(line) { return (line ~ /^[[:space:]]*module[[:space:]]+/) }
  function is_module_end(line) { return (line ~ /(^|[[:space:]])where([[:space:]]|$)/) }

  BEGIN {
    inserted = 0
    skipping_module = 0
  }

  {
    line = strip_bom($0)

    if (skipping_module) {
      if (is_module_end(line)) skipping_module = 0
      next
    }

    if (!inserted && is_pragma(line)) {
      print line
      next
    }

    if (is_module_start(line)) {
      skipping_module = 1
      if (is_module_end(line)) skipping_module = 0
      next
    }

    if (!inserted) {
      print "module Supers where"
      inserted = 1
    }

    print line
  }

  END {
    if (!inserted) print "module Supers where"
  }
  ' "$hs" >"$tmp"

  mv -f "$tmp" "$hs"
}

inject_hs_io_init() {
  local hs="$1"
  [[ -f "$hs" ]] || die "inject_hs_io_init: missing file: $hs"

  if rg -q "supers_io_init" "$hs"; then
    return 0
  fi

  local tmp
  tmp="$(mktemp)"

  awk '
  BEGIN { inserted_import = 0 }
  {
    print $0
    if (!inserted_import && $0 ~ /import[[:space:]]+System\.IO\.Unsafe/) {
      print "import System.IO (hSetBuffering, hFlush, BufferMode(..), stdout, stderr)"
      inserted_import = 1
    }
  }
  END {
    if (!inserted_import) {
      print "import System.IO (hSetBuffering, hFlush, BufferMode(..), stdout, stderr)"
    }
  }
  ' "$hs" >"$tmp"

  mv -f "$tmp" "$hs"

  cat >>"$hs" <<'EOF'

foreign export ccall "supers_io_init" supers_io_init :: IO ()
supers_io_init :: IO ()
supers_io_init = do
  hSetBuffering stdout NoBuffering
  hSetBuffering stderr NoBuffering
EOF
}

gen_empty_aliases_c() {
  local out_c="$1"
  {
    echo '/* Intentionally empty.'
    echo ' * Kept only because some build rules expect this translation unit.'
    echo ' */'
    echo ''
  } >"$out_c"
}

gen_super_wrappers_c() {
  local out_c="$1"
  local max="$2"

  {
    echo '#include <stdint.h>'
    echo '#include <stdio.h>'
    echo '#include "queue.h"'
    echo '#include "interp.h"'
    echo ''
    echo '#if defined(__GNUC__)'
    echo '#  define EXPORT_FN __attribute__((visibility("default")))'
    echo '#  define WEAK_FN   __attribute__((weak))'
    echo '#  define USED_FN   __attribute__((used))'
    echo '#else'
    echo '#  define EXPORT_FN'
    echo '#  define WEAK_FN'
    echo '#  define USED_FN'
    echo '#endif'
    echo ''
    echo 'static int64_t supers_missing(int n) {'
    echo '  fprintf(stderr, "[supers] missing symbol: s%d (called via super%d)\n", n, n);'
    echo '  return 0;'
    echo '}'
    echo ''

    local n=0
    while [[ "$n" -lt "$max" ]]; do
      echo "extern void s${n}(int64_t *in, int64_t *out) WEAK_FN;"
      echo "EXPORT_FN USED_FN void super${n}(oper_t **oper, oper_t *result) {"
      echo "  int64_t in[2];"
      echo "  int64_t out[1];"
      echo "  in[0] = (int64_t)oper[0]->value.li;"
      echo "  in[1] = 0;"
      echo "  if (oper[1] != NULL) { in[1] = (int64_t)oper[1]->value.li; }"
      echo "  if (s${n}) {"
      echo "    s${n}(in, out);"
      echo "    result[0].value.li = out[0];"
      echo "  } else {"
      echo "    result[0].value.li = supers_missing(${n});"
      echo "  }"
      echo "}"
      echo ''
      n=$((n + 1))
    done
  } >"$out_c"
}

populate_ghc_deps() {
  local so_path="$1"
  local deps_dir="$2"
  local rts_so="${3:-}"

  [[ -f "$so_path" ]] || die "populate_ghc_deps: missing so: $so_path"

  rm -rf "$deps_dir"
  mkdir -p "$deps_dir"

  command -v ldd >/dev/null 2>&1 || die "ldd not found; cannot populate ghc-deps"

  local line dep_path base
  while IFS= read -r line; do
    dep_path="$(echo "$line" | awk '/=> \// {print $3} /^\// {print $1} { }')"
    [[ -n "$dep_path" && -f "$dep_path" ]] || continue

    base="$(basename "$dep_path")"

    case "$base" in
      libHS*.so*|libgmp.so*|libffi.so*)
        cp -f "$dep_path" "$deps_dir/$base"
        ;;
      *)
        ;;
    esac
  done < <(ldd "$so_path" 2>/dev/null || true)

  if [[ -n "$rts_so" && -f "$rts_so" ]]; then
    cp -f "$rts_so" "$deps_dir/$(basename "$rts_so")" || true
  fi
}

build_libsupers_so() {
  local out_dir="$1"
  local ghc="$2"
  local cc="$3"
  local cflags="$4"
  local rr
  rr="$(repo_root)"
  local rts_init_src="$rr/tools/supers_rts_init.c"
  cflags="$cflags -I$rr/TALM/interp/include"

  local ghc_ver="${GHC_VER:-}"
  local ghc_libdir="${GHC_LIBDIR:-}"
  local dynlib_dir="${DYNLIB_DIR:-}"
  local rts_so="${RTS_SO:-}"

  if [[ -z "$ghc_ver" ]]; then ghc_ver="$(detect_ghc_ver "$ghc")"; fi

  if [[ -z "$ghc_libdir" ]]; then
    ghc_libdir="$(resolve_ghc_libdir "$ghc" "$ghc_ver")"
  fi

  # If RTS_SO is provided, trust it and derive DYNLIB_DIR from it.
  if [[ -n "$rts_so" && -z "$dynlib_dir" ]]; then
    dynlib_dir="$(dynlib_dir_from_rts "$rts_so")"
  fi

  if [[ -z "$dynlib_dir" ]]; then
    dynlib_dir="$(detect_dynlib_dir "$ghc_libdir" "$ghc_ver")"
  fi

  if [[ -z "$rts_so" ]]; then
    rts_so="$(detect_rts_so "$dynlib_dir" "$ghc_ver")"
  fi

  [[ -n "$dynlib_dir" && -d "$dynlib_dir" ]] || die "Could not detect DYNLIB_DIR for GHC $ghc_ver (ghc_libdir=$ghc_libdir)"
  [[ -n "$rts_so" && -f "$rts_so" ]] || die "Could not detect RTS_SO for GHC $ghc_ver under DYNLIB_DIR=$dynlib_dir"

  (
    cd "$out_dir"

    rm -f Supers.o supers_wrappers.o supers_aliases.o libsupers.so

    if [[ "${SUPERS_THREADED:-1}" == "1" ]]; then
      GHC_ENVIRONMENT=- "$ghc" -O2 -dynamic -fPIC -threaded -c Supers.hs -o Supers.o
    else
      GHC_ENVIRONMENT=- "$ghc" -O2 -dynamic -fPIC -c Supers.hs -o Supers.o
    fi

    "$cc" $cflags -c supers_wrappers.c -o supers_wrappers.o
    "$cc" $cflags -c supers_aliases.c  -o supers_aliases.o
    if [[ -f "$rts_init_src" ]]; then
      "$cc" $cflags -c "$rts_init_src" -o supers_rts_init.o
    fi

    local -a ghc_link=(
      -shared
      -dynamic
      -no-hs-main
      -o libsupers.so
      Supers.o
      supers_wrappers.o
      supers_aliases.o
    )
    if [[ -f supers_rts_init.o ]]; then
      ghc_link+=(supers_rts_init.o)
    fi

    ghc_link+=(-optl "-Wl,-rpath,\$ORIGIN")
    ghc_link+=(-optl "-Wl,-rpath,\$ORIGIN/ghc-deps")
    ghc_link+=(-optl "-Wl,-rpath,${dynlib_dir}")

    # Force RTS into DT_NEEDED so dlopen resolves stg_* and RTS globals.
    ghc_link+=(
      -optl "-Wl,--no-as-needed"
      "$rts_so"
      -optl "-Wl,--as-needed"
    )

    if [[ "${SUPERS_THREADED:-1}" == "1" ]]; then
      GHC_ENVIRONMENT=- "$ghc" -threaded "${ghc_link[@]}"
    else
      GHC_ENVIRONMENT=- "$ghc" "${ghc_link[@]}"
    fi

    populate_ghc_deps "$out_dir/libsupers.so" "$out_dir/ghc-deps" "$rts_so"
  )
}

generate_one() {
  local rr="$1"
  local in_hsk="$2"
  local out_hs="$3"
  local max="$4"

  [[ -f "$in_hsk" ]] || die "Input not found: $in_hsk"

  local out_dir
  out_dir="$(dirname "$out_hs")"
  mkdir -p "$out_dir"
  out_dir="$(cd "$out_dir" && pwd -P)"

  local supersgen="$rr/supersgen"
  [[ -x "$supersgen" ]] || die "supersgen not found or not executable: $supersgen"

  echo "[SUPERS] $in_hsk -> $out_hs"
  "$supersgen" "$in_hsk" >"$out_hs"

  normalize_hs_module "$out_hs"
  inject_hs_io_init "$out_hs"

  gen_empty_aliases_c "$out_dir/supers_aliases.c"
  gen_super_wrappers_c "$out_dir/supers_wrappers.c" "$max"

  local ghc="${GHC:-ghc}"
  local cc="${CC:-gcc}"
  local cflags="${CFLAGS:--O2 -fPIC}"

  build_libsupers_so "$out_dir" "$ghc" "$cc" "$cflags"

  echo "[SUPERS] built: $out_dir/libsupers.so"
}

generate_all() {
  local rr="$1"
  local max="$2"

  local test_dir="$rr/test"
  [[ -d "$test_dir" ]] || die "Missing directory: $test_dir"

  local found=0
  shopt -s nullglob
  for in_hsk in "$test_dir"/*.hsk; do
    found=1
    local base
    base="$(basename "$in_hsk" .hsk)"
    local out_dir="$test_dir/supers/$base"
    local out_hs="$out_dir/Supers.hs"
    generate_one "$rr" "$in_hsk" "$out_hs" "$max"
  done
  shopt -u nullglob

  [[ "$found" -eq 1 ]] || die "No .hsk files found in $test_dir"
}

main() {
  local rr
  rr="$(repo_root)"

  local max="${SUPERS_WRAPPERS_MAX:-256}"

  case $# in
    0) generate_all "$rr" "$max" ;;
    2) generate_one "$rr" "$1" "$2" "$max" ;;
    *) usage ;;
  esac
}

main "$@"
