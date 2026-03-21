#!/usr/bin/env python3
"""Clear the executable flag from PT_GNU_STACK in ELF binaries.

Some environments reject loading shared objects that request an executable
stack. This script locates the PT_GNU_STACK program header and clears PF_X.

Usage:
  python3 tools/fix_execstack.py path/to/lib.so [more.so ...]
"""

from __future__ import annotations

import sys
from pathlib import Path

try:
    from elftools.elf.constants import P_FLAGS, P_TYPE  # type: ignore
    from elftools.elf.elffile import ELFFile  # type: ignore
except Exception as e:
    print(f"ERROR: pyelftools is required: {e}", file=sys.stderr)
    print("Install: pip install pyelftools (or your distro package).", file=sys.stderr)
    raise


PT_GNU_STACK = getattr(P_TYPE, "PT_GNU_STACK", 0x6474E551)
PF_X = P_FLAGS.PF_X


def fix_one(path: Path) -> bool:
    data = bytearray(path.read_bytes())

    with path.open("rb") as f:
        elf = ELFFile(f)

        for seg in elf.iter_segments():
            if seg.header.p_type != PT_GNU_STACK:
                continue

            if (seg.header.p_flags & PF_X) == 0:
                return False

            # Patch p_flags in place. This is safe for ET_DYN.
            offset = seg.header.get_file_offset() + seg.header.structs.Elf_Phdr.p_flags.offset
            cur = int.from_bytes(
                data[offset : offset + seg.header.structs.Elf_Phdr.p_flags.size],
                byteorder=elf.little_endian and "little" or "big",
                signed=False,
            )
            new = cur & ~PF_X
            data[offset : offset + seg.header.structs.Elf_Phdr.p_flags.size] = new.to_bytes(
                seg.header.structs.Elf_Phdr.p_flags.size,
                byteorder=elf.little_endian and "little" or "big",
                signed=False,
            )

            path.write_bytes(data)
            return True

    return False


def main(argv: list[str]) -> int:
    if not argv:
        print("Usage: fix_execstack.py path/to/lib.so [more.so ...]", file=sys.stderr)
        return 2

    changed_any = False
    for s in argv:
        p = Path(s)
        if not p.exists():
            print(f"WARNING: not found: {p}", file=sys.stderr)
            continue
        try:
            changed = fix_one(p)
            changed_any = changed_any or changed
        except Exception as e:
            print(f"WARNING: failed to patch {p}: {e}", file=sys.stderr)

    return 0 if changed_any or True else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
