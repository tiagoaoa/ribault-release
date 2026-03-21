#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate an index-based Dyck path .hsk for the TALM benchmark.

Uses an UNROLLED tree: the gen script precomputes all P leaf boundaries
based on IMB, then generates explicit code with no recursion.
The only conditional logic (min in merge) uses a tiny myMin super.
All other operations are pure arithmetic in the dataflow.
Works for any IMB 0-100 and any power-of-2 P.
"""

import argparse, os, math

SHIFT = 0  # max(totalLen+1, SHIFT) ensures shift >= totalLen+1


def compute_leaves(totalLen, P, IMB):
    """Compute P leaf intervals by splitting with IMB at each level.
    Guarantees every leaf has count >= 1 (steals from largest if needed)."""
    if P <= 1:
        return [(0, totalLen)]
    depth = int(math.ceil(math.log2(P)))
    # Each entry: (start, count)
    nodes = [(0, totalLen)]
    for _ in range(depth):
        new_nodes = []
        for (start, count) in nodes:
            if count <= 1:
                new_nodes.append((start, count))
                new_nodes.append((start + count, 0))
            else:
                kRaw = (count * (100 + IMB)) // 200
                k = max(1, min(count - 1, kRaw))
                new_nodes.append((start, k))
                new_nodes.append((start + k, count - k))
        nodes = new_nodes
    leaves = nodes[:P]
    # Ensure every leaf has count >= 1: steal from the largest leaf
    counts = [c for _, c in leaves]
    zeros = [i for i, c in enumerate(counts) if c == 0]
    if zeros:
        biggest = max(range(len(counts)), key=lambda i: counts[i])
        for zi in zeros:
            counts[biggest] -= 1
            counts[zi] = 1
        # Recompute starts from counts
        new_leaves = []
        pos = 0
        for c in counts:
            new_leaves.append((pos, c))
            pos += c
        leaves = new_leaves
    return leaves


def gen_merge_code(n_leaves, OFF, RNG, MINOFF, MINSH):
    """Generate merge tree code using myMin super for conditional min.
    Returns (lines, final_s_var, final_m_var)."""
    lines = []
    # Decode each leaf result
    for i in range(n_leaves):
        lines.append(f"  in let s_{i} = a{i} / {RNG} - {OFF}")
        lines.append(f"  in let m_{i} = a{i} % {RNG} - {OFF}")

    # Binary merge bottom-up
    current = [(f"s_{i}", f"m_{i}") for i in range(n_leaves)]
    gen_id = 0
    while len(current) > 1:
        new_current = []
        for i in range(0, len(current), 2):
            if i + 1 < len(current):
                sl, ml = current[i]
                sr, mr = current[i + 1]
                s_new = f"ms{gen_id}"
                v_var = f"vv{gen_id}"
                ml_off = f"lo{gen_id}"
                ml_sc = f"ls{gen_id}"
                v_off = f"vo{gen_id}"
                mp_var = f"mp{gen_id}"
                m_new = f"mm{gen_id}"
                lines.append(f"  in let {s_new} = {sl} + {sr}")
                lines.append(f"  in let {v_var} = {sl} + {mr}")
                # Pack (ml, v) for myMin: ml_off * MINSH + v_off
                lines.append(f"  in let {ml_off} = {ml} + {MINOFF}")
                lines.append(f"  in let {ml_sc} = {ml_off} * {MINSH}")
                lines.append(f"  in let {v_off} = {v_var} + {MINOFF}")
                lines.append(f"  in let {mp_var} = {ml_sc} + {v_off}")
                lines.append(f"  in let {m_new} = myMin {mp_var}")
                new_current.append((s_new, m_new))
                gen_id += 1
            else:
                new_current.append(current[i])
        current = new_current

    return lines, current[0][0], current[0][1]


def emit_hsk(path, N, P, IMB, DELTA, vec_kind):
    os.makedirs(os.path.dirname(path), exist_ok=True)

    totalLen = N + abs(DELTA)
    OFF = totalLen
    RNG = 2 * OFF + 1
    shift = max(totalLen + 1, SHIFT)

    # For myMin packing: values range from -2*totalLen to totalLen
    # MINOFF makes both non-negative; MINSH > max shifted value
    MINOFF = 2 * totalLen
    MINSH = 3 * totalLen + 1

    leaves = compute_leaves(totalLen, P, IMB)

    # Build leaf call lines
    leaf_lines = []
    for i, (start, count) in enumerate(leaves):
        kw = "let" if i == 0 else "in let"
        packed = start * shift + count
        if packed == 0:
            leaf_lines.append(f"  {kw} a{i} = analyseRange 0")
        elif start == 0:
            leaf_lines.append(f"  {kw} a{i} = analyseRange {count}")
        else:
            leaf_lines.append(f"  {kw} sc{i} = {start} * {shift} + {count}")
            leaf_lines.append(f"  in let a{i} = analyseRange sc{i}")

    # Build merge tree
    if len(leaves) == 1:
        merge_lines = []
        # Decode the single result
        merge_lines.append(f"  in let sf = a0 / {RNG} - {OFF}")
        merge_lines.append(f"  in let mf = a0 % {RNG} - {OFF}")
        final_s, final_m = "sf", "mf"
    else:
        merge_lines, final_s, final_m = gen_merge_code(
            len(leaves), OFF, RNG, MINOFF, MINSH)

    # Re-pack final (tot, mn) and call checkAndPrint
    final_lines = [
        f"  in let sf_off = {final_s} + {OFF}",
        f"  in let sf_sc = sf_off * {RNG}",
        f"  in let mf_off = {final_m} + {OFF}",
        f"  in let final_packed = sf_sc + mf_off",
        f"  in checkAndPrint final_packed",
    ]

    # Supers section
    # Always include myMin super so super IDs are consistent across P values
    mymin_super = f"""
-- SUPER: compute min of two packed values
-- Input: packed = (a + MINOFF) * MINSH + (b + MINOFF)
-- Output: min(a, b)
myMin packed =
  super single input (packed) output (m)
#BEGINSUPER
    m = let minsh = {MINSH}
            minoff = {MINOFF}
            a = packed `div` minsh - minoff
            b = packed `mod` minsh - minoff
        in if a < b then a else b
#ENDSUPER
"""

    # Build full HSK
    hsk = f"""-- dyck_path.hsk  (index-based, unrolled tree, auto-generated)
-- N={N}  P={P}  IMB={IMB}  DELTA={DELTA}
-- {len(leaves)} leaves, no recursion

-- SUPER: analyse elements [start .. start+count-1] of the Dyck sequence
-- Input:  sc = start * SHIFT + count  (packed literal)
-- Output: packed result = (tot + OFFSET) * RANGE + (mn + OFFSET)
analyseRange sc =
  super single input (sc) output (res)
#BEGINSUPER
    res =
      let
        sh     = {shift}
        start  = sc `div` sh
        cnt    = sc `mod` sh
        endIdx = start + cnt
        ntot   = {N}
        d      = {DELTA}
        off    = {OFF}
        rng    = {RNG}
        gen i  = if i < ntot
                 then (if mod i 2 == 0 then 1 else -1)
                 else (if d > 0 then 1 else -1)
        go s mn i
          | i >= endIdx = (s + off) * rng + (mn + off)
          | otherwise   =
              let x   = gen i
                  s1  = s + x
                  mn1 = if s1 < mn then s1 else mn
              in s1 `seq` mn1 `seq` go s1 mn1 (i + 1)
      in go 0 0 start
#ENDSUPER
{mymin_super}
-- SUPER: unpack final result, check validity, print
checkAndPrint packed =
  super single input (packed) output (out)
#BEGINSUPER
    out =
      let off = {OFF}
          rng = {RNG}
          tot = packed `div` rng - off
          mn  = packed `mod` rng - off
          r   = if tot == 0 then (if mn >= 0 then 1 else 0) else 0
      in unsafePerformIO (do print r; pure 0)
#ENDSUPER

-- Main: {len(leaves)} parallel leaf SUPERs + merge tree
main =
"""

    all_body = leaf_lines + merge_lines + final_lines
    hsk += "\n".join(all_body) + "\n"

    with open(path, "w", encoding="utf-8") as f:
        f.write(hsk)
    print(f"[dyck_gen_input] wrote {path} (N={N}, P={P}, imb={IMB}, delta={DELTA}, "
          f"leaves={len(leaves)}, shift={shift})")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--N", type=int, required=True)
    ap.add_argument("--P", type=int, required=True)
    ap.add_argument("--imb", type=int, required=True)
    ap.add_argument("--delta", type=int, required=True)
    ap.add_argument("--vec", default="range", choices=["range", "rand"])
    args = ap.parse_args()
    emit_hsk(args.out, args.N, args.P, args.imb, args.delta, args.vec)


if __name__ == "__main__":
    main()
