#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate par/pseq Merge Sort .hs (no Strategies, only Control.Parallel)."""

import argparse, os, random

HS_TMPL = r"""-- Auto-generated: parallel Merge Sort (par/pseq, NO Strategies)
{-# LANGUAGE BangPatterns #-}
import Control.Parallel (par, pseq)
import Control.DeepSeq
import Data.Time.Clock (getCurrentTime, diffUTCTime)

-- split em duas metades
split2 :: [Int] -> ([Int],[Int])
split2 []         = ([],[])
split2 [x]        = ([x],[])
split2 (x:y:zs)   = let (xs,ys) = split2 zs in (x:xs, y:ys)

-- merge (estável)
merge :: [Int] -> [Int] -> [Int]
merge xs [] = xs
merge [] ys = ys
merge (x:xs) (y:ys)
  | x <= y    = x : merge xs (y:ys)
  | otherwise = y : merge (x:xs) ys

-- mergesort com par/pseq (sem Strategies)
msort :: [Int] -> [Int]
msort []  = []
msort [x] = [x]
msort xs  =
  let (a,b) = split2 xs
      goA   = force (msort a)
      goB   = force (msort b)
  in goA `par` goB `pseq` merge goA goB

-- garante avaliação total
forceList :: NFData a => [a] -> ()
forceList xs = xs `deepseq` ()

-- entrada (gerada pelo script)
xsInput :: [Int]
xsInput = __VEC__

main :: IO ()
main = do
  let !_ = length xsInput  -- force spine
  t0 <- getCurrentTime
  let ys = msort xsInput
  forceList ys `seq` return ()
  t1 <- getCurrentTime
  let secs = realToFrac (diffUTCTime t1 t0) :: Double
  let sorted = and (zipWith (<=) ys (tail ys))
  putStrLn $ "SORTED=" ++ show sorted
  putStrLn $ "SORTED_HEAD=" ++ show (take 10 ys)
  putStrLn $ "RUNTIME_SEC=" ++ show secs
"""

def make_vec(n, kind):
    if kind == "range":
        return f"[{n}, {n-1} .. 1]"
    elif kind == "rand":
        rnd = random.Random(1337)
        xs = [rnd.randint(0, n*2) for _ in range(n)]
        return "[" + ",".join(map(str, xs)) + "]"
    else:
        raise SystemExit("vec precisa ser 'range' ou 'rand'")

def emit_hs(path, n, vec_kind):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    vec = make_vec(n, vec_kind)
    src = HS_TMPL.replace("__VEC__", vec)
    with open(path, "w", encoding="utf-8") as f:
        f.write(src)
    print(f"[hs_gen_parpseq] wrote {path} (N={n}, vec={vec_kind})")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--N", type=int, required=True)
    ap.add_argument("--vec", default="range", choices=["range","rand"])
    args = ap.parse_args()
    emit_hs(args.out, args.N, args.vec)

if __name__ == "__main__":
    main()
