#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate a parametric MatMul .hsk for the TALM benchmark.

Uses Haskell supers (normal pipeline, compiled by GHC).
P block-multiply supers fire in parallel via dataflow.

Each super computes rows [start..start+rows) of C = A * B^T,
returning a partial checksum. The dataflow sums all partial
checksums and a print super validates the result.
"""

import argparse, os


def emit_hsk(path, N, P):
    os.makedirs(os.path.dirname(path), exist_ok=True)

    block_size = N // P
    remainder = N % P
    blocks = []
    start = 0
    for i in range(P):
        rows = block_size + (1 if i < remainder else 0)
        blocks.append((start, rows))
        start += rows

    SHIFT = N + 1

    leaf_lets = []
    for i, (s, rows) in enumerate(blocks):
        kw = "let" if i == 0 else "in let"
        packed = s * SHIFT + rows
        leaf_lets.append(f"  {kw} b{i} = block_mul {packed}")

    if P == 1:
        sum_expr = "b0"
    else:
        sum_expr = " + ".join(f"b{i}" for i in range(P))

    # NOTE: All type annotations inside #BEGINSUPER must use Int64
    # because supersgen wraps the body in s<N>_impl :: Int64 -> Int64.
    # Using plain Int causes type-mismatch compilation errors.
    hsk = f"""-- matmul.hsk  (auto-generated, Haskell supers)
-- N={N}  P={P}  blocks={P}

-- SUPER: multiply rows [start..start+rows) of A by B^T
-- Input: packed = start * {SHIFT} + rows
-- Output: partial checksum (truncated integer)
block_mul packed =
  super single input (packed) output (cs)
#BEGINSUPER
    cs = let
        sh   = {SHIFT} :: Int64
        n    = {N} :: Int64
        s    = packed `div` sh
        rows = packed `mod` sh
        -- generate A (seed=42) and B (seed=137) deterministically
        -- simple LCG: x_{{i+1}} = (a*x_i + c) mod m, scaled to [0,1)
        lcg seed idx =
          let m = 2147483647 :: Int64
              a = 1103515245 :: Int64
              c = 12345 :: Int64
              val = (a * (seed + idx) + c) `mod` m
          in fromIntegral val / fromIntegral m
        getA i j = lcg 42  (i * n + j)
        getB i j = lcg 137 (i * n + j)
        dot i k = sum [ getA (s + i) j * getB k j | j <- [0..n-1] ]
        blockCS = sum [ dot ri k | ri <- [0..rows-1], k <- [0..n-1] ]
      in truncate (blockCS * 1000000 :: Double)
#ENDSUPER

-- SUPER: print final checksum
print_checksum cs =
  super single input (cs) output (out)
#BEGINSUPER
    out = unsafePerformIO
      (do
        putStrLn ("CHECKSUM=" ++ show cs)
        pure 0)
#ENDSUPER

main =
{chr(10).join(leaf_lets)}
  in let total = {sum_expr}
  in print_checksum total
"""
    with open(path, "w", encoding="utf-8") as f:
        f.write(hsk)
    print(f"[gen_matmul_talm] wrote {path} (N={N}, P={P})")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--N", type=int, required=True)
    ap.add_argument("--P", type=int, required=True)
    args = ap.parse_args()
    emit_hsk(args.out, args.N, args.P)


if __name__ == "__main__":
    main()
