#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate Fibonacci .hs using Control.Parallel.Strategies."""

import argparse, os

TMPL = r"""{-# LANGUAGE BangPatterns #-}
-- Auto-generated: Fibonacci with cutoff (GHC Strategies)
-- N=__N__  CUTOFF=__CUTOFF__

import Control.Parallel.Strategies (rpar, rseq, runEval)
import Data.Time.Clock (getCurrentTime, diffUTCTime)

fibSeq :: Int -> Int
fibSeq 0 = 0
fibSeq 1 = 1
fibSeq n = fibSeq (n - 1) + fibSeq (n - 2)

fib :: Int -> Int -> Int
fib cutoff n
  | n <= 1      = n
  | n <= cutoff = fibSeq n
  | otherwise   = runEval $ do
      a <- rpar (fib cutoff (n - 1))
      b <- rseq (fib cutoff (n - 2))
      return (a + b)

main :: IO ()
main = do
  t0 <- getCurrentTime
  let !r = fib __CUTOFF__ __N__
  t1 <- getCurrentTime
  let secs = realToFrac (diffUTCTime t1 t0) :: Double
  putStrLn $ "RESULT=" ++ show r
  putStrLn $ "RUNTIME_SEC=" ++ show secs
"""

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--N", type=int, required=True)
    ap.add_argument("--cutoff", type=int, required=True)
    args = ap.parse_args()
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    src = TMPL.replace("__N__", str(args.N)).replace("__CUTOFF__", str(args.cutoff))
    with open(args.out, "w") as f:
        f.write(src)
    print(f"[gen_fib_strategies] wrote {args.out} (N={args.N}, cutoff={args.cutoff})")

if __name__ == "__main__":
    main()
