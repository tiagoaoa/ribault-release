#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate an index-based Dyck path .hs for the GHC parallel baseline.

Mirrors the TALM version exactly: checkRec operates on (start, count)
integer indices; each leaf generates Dyck elements on-the-fly.
"""

import argparse, os

SHIFT = 16777216  # must match gen_dyck_input.py

TMPL = r"""{-# LANGUAGE BangPatterns #-}
-- Auto-generated Dyck (GHC parallel baseline, index-based)
-- N=__N__  P=__P__  IMB=__IMB__  DELTA=__DELTA__

import Control.DeepSeq (NFData(..), force)
import Control.Parallel.Strategies (parTuple2, rdeepseq, using)
import Data.Int (Int64)

-- Parameters (compile-time)
n0, p0, imb0, delta0, totalLen0, threshold0 :: Int64
n0     = __N__
p0     = __P__
imb0   = __IMB__
delta0 = __DELTA__
totalLen0 = n0 + abs delta0
threshold0 = totalLen0 `div` p0

-- Generate element at index i of the Dyck sequence
gen :: Int64 -> Int64
gen i
  | i < n0    = if mod i 2 == 0 then 1 else -1
  | otherwise = if delta0 > 0 then 1 else -1

-- Analyse a range [start .. start+count-1]
analyseRange :: Int64 -> Int64 -> (Int64, Int64)
analyseRange start count = go 0 0 start
  where
    endIdx = start + count
    go !s !mn i
      | i >= endIdx = (s, mn)
      | otherwise   =
          let x   = gen i
              s1  = s + x
              mn1 = if s1 < mn then s1 else mn
          in go s1 mn1 (i + 1)

-- Integer split with clamping
splitK :: Int64 -> Int64
splitK count
  | count <= 1 = 1
  | kRaw < 1   = 1
  | kRaw >= count = count - 1
  | otherwise  = kRaw
  where kRaw = (count * (100 + imb0)) `div` 200

-- Recursive parallel validation
checkRec :: Int64 -> Int64 -> (Int64, Int64)
checkRec start count
  | count <= threshold0 = analyseRange start count
  | otherwise =
      let k = splitK count
          (lr, rr) = (checkRec start k, checkRec (start + k) (count - k))
                     `using` parTuple2 rdeepseq rdeepseq
          (s1, m1) = lr
          (s2, m2) = rr
      in ( s1 + s2
         , let v = s1 + m2 in if m1 < v then m1 else v )

validateDyck :: Bool
validateDyck =
  let (tot, mn) = checkRec 0 totalLen0
  in (tot == 0) && (mn >= 0)

main :: IO ()
main = do
  let ok = validateDyck
  ok `seq` putStrLn (if ok then "1" else "0")
"""

def emit_hs(out, N, P, IMB, DELTA, vec_kind):
    os.makedirs(os.path.dirname(out), exist_ok=True)
    src = (TMPL
           .replace("__N__", str(N))
           .replace("__P__", str(P))
           .replace("__IMB__", str(IMB))
           .replace("__DELTA__", str(DELTA)))
    with open(out, "w", encoding="utf-8") as f:
        f.write(src)
    print(f"[hs_gen_input] wrote {out} (N={N}, P={P}, imb={IMB}, delta={DELTA})")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--N", type=int, required=True)
    ap.add_argument("--P", type=int, required=True)
    ap.add_argument("--imb", type=int, required=True)
    ap.add_argument("--delta", type=int, required=True)
    ap.add_argument("--vec", default="range", choices=["range","rand"])
    args = ap.parse_args()
    emit_hs(args.out, args.N, args.P, args.imb, args.delta, args.vec)

if __name__ == "__main__":
    main()
