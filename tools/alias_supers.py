#!/usr/bin/env python3
"""
Prefix exported super symbols to avoid collisions.

The generated Supers.hs exports C symbols like "s0", "s1", ...
If you compile multiple Supers modules into a single shared object, those
symbols collide. This script rewrites:

  foreign export ccall "s0" s0 :: ...

into:

  foreign export ccall "<prefix>_s0" s0 :: ...

Usage:
  python3 tools/alias_supers.py <prefix> [Supers.hs]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


def read_text_fallback(path: Path) -> str:
    data = path.read_bytes()
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return data.decode("latin-1")


def sanitize_prefix(prefix: str) -> str:
    p = re.sub(r"[^A-Za-z0-9_]", "_", prefix)
    if not p or not re.match(r"[A-Za-z_]", p[0]):
        p = "_" + p
    return p


def main(argv: list[str]) -> int:
    if not argv:
        print("Usage: alias_supers.py <prefix> [Supers.hs]", file=sys.stderr)
        return 2

    prefix = sanitize_prefix(argv[0])
    path = Path(argv[1]) if len(argv) > 1 else Path("Supers.hs")

    src = read_text_fallback(path)

    def repl(m: re.Match[str]) -> str:
        sym = m.group(1)
        return f'foreign export ccall "{prefix}_{sym}"'

    out = re.sub(r'foreign\s+export\s+ccall\s+"(s[0-9]+)"', repl, src)

    path.write_text(out, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
