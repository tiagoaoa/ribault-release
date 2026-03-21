#!/usr/bin/env bash
set -euo pipefail

# ========================
# Config
# ========================
SRC_DIR="${SRC_DIR:-src}"          # Haskell sources root
OUT_ROOT="${OUT_ROOT:-html}"       # site root (for GitHub Pages)
OUT_API="$OUT_ROOT/api"            # where Haddock output goes
TITLE="${TITLE:-Ribault — Compiler API Docs}"

# 1) Ensure generated sources exist (your Makefile rule)
make tokens >/dev/null || true

# 2) Deps
command -v haddock >/dev/null 2>&1 || { echo 'Error: "haddock" not found in PATH.'; exit 1; }
[ -d "$SRC_DIR" ] || { echo "Error: $SRC_DIR not found"; exit 1; }

# 3) Collect .hs files EXCLUDING any module Main
mapfile -t ALL_HS < <(find "$SRC_DIR" -type f -name '*.hs' | sort)
HS_FILES=()
for f in "${ALL_HS[@]}"; do
  base="$(basename "$f")"
  [[ "$base" =~ ^Main.*\.hs$ ]] && continue
  if grep -Eq '^[[:space:]]*module[[:space:]]+Main([[:space:]]+|\()[^;]*where' "$f"; then
    continue
  fi
  HS_FILES+=("$f")
done
[ "${#HS_FILES[@]}" -gt 0 ] || { echo "Error: no library modules (non-Main) found."; exit 1; }

# 4) Clean output dirs
rm -rf "$OUT_API"
mkdir -p "$OUT_API/assets"
mkdir -p "$OUT_ROOT"

# 5) Minimal CSS polish for Haddock
cat > "$OUT_API/assets/custom.css" <<'CSS'
:root { --font: Inter, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
body, .module > h1, .caption, #package-header, #content { font-family: var(--font); }
#package-header { background:#fafbff; border-bottom:1px solid #eef1ff; }
#content { max-width: 1100px; margin: 0 auto; padding: 1.2rem; }
a { text-decoration: none; }
pre, code { font-size: 0.95em; }
.quick-jump { position: sticky; top: 0; background: #fff; z-index: 5; }
h1, h2, h3 { scroll-margin-top: 70px; }
#footer { opacity: .7; margin: 2rem 0 1rem; font-size:.9rem; }
CSS

# 6) Prologue (EN)
PROLOGUE="$OUT_API/assets/prologue.md"
cat > "$PROLOGUE" <<'MD'
# Ribault — Compiler API

HTML documentation for the compiler modules (Analysis and Synthesis).
Generated with Haddock (hyperlinked source + quickjump).
MD

# 7) Run Haddock into html/api/
haddock \
  --html \
  --quickjump \
  --hyperlinked-source \
  --odir="$OUT_API" \
  --title="$TITLE" \
  --prologue="$PROLOGUE" \
  "${HS_FILES[@]}"

# 8) English landing page at html/index.html (links to api/index.html)
cat > "$OUT_ROOT/index.html" <<HTML
<!doctype html><html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${TITLE}</title>
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;600;800&display=swap" rel="stylesheet">
<style>
  :root { --font: Inter, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
  body { font-family: var(--font); background:#f8fafc; }
  .wrap{max-width:900px;margin:10vh auto;padding:1rem}
  .card{border:1px solid #eef1ff;border-radius:14px;padding:1.2rem 1.4rem;box-shadow:0 10px 36px rgba(0,0,0,.06);background:white}
  .cta{display:inline-block;margin-top:.9rem;background:#eef2ff;color:#3730a3;border-radius:999px;padding:.48rem .9rem;text-decoration:none;font-weight:600}
  h1{margin:.2rem 0 .6rem}
  p{margin:0}
</style>
</head><body>
<div class="wrap">
  <div class="card">
    <h1>${TITLE}</h1>
    <p>HTML documentation for the compiler modules (Analysis &amp; Synthesis).</p>
    <a class="cta" href="./api/index.html">Open documentation</a>
  </div>
</div>
</body></html>
HTML

echo "✔ Built API docs in: $OUT_ROOT/  (open html/index.html → api/index.html)"
