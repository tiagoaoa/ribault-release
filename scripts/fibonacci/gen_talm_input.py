#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate a parametric Fibonacci .hsk for the TALM benchmark.

The .hsk uses:
  - fib_seq: a super that computes fib(n) sequentially (iterative in Haskell)
  - fib: recursive, drops to fib_seq below cutoff; above cutoff, both
         branches fire as independent dataflow operations (implicit parallelism)
  - print_result: super that prints the result for correctness validation
"""

import argparse, os


def emit_hsk(path, N, CUTOFF):
    os.makedirs(os.path.dirname(path), exist_ok=True)

    hsk = f"""-- fib.hsk  (auto-generated)
-- N={N}  CUTOFF={CUTOFF}

-- SUPER: sequential fibonacci (iterative)
fib_seq n =
  super single input (n) output (out)
#BEGINSUPER
    out = let go i a b = if i >= n then a
                         else go (i + 1) b (a + b)
          in go 0 0 1
#ENDSUPER

-- Recursive fib: parallel above cutoff, sequential below
fib n =
  if n <= {CUTOFF}
  then fib_seq n
  else fib (n - 1) + fib (n - 2)

-- SUPER: print result for correctness check
print_result r =
  super single input (r) output (out)
#BEGINSUPER
    out = unsafePerformIO
      (do
        putStrLn ("RESULT=" ++ show r)
        pure 0)
#ENDSUPER

main = print_result (fib {N})
"""
    with open(path, "w", encoding="utf-8") as f:
        f.write(hsk)
    print(f"[gen_fib_talm] wrote {path} (N={N}, cutoff={CUTOFF})")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--N", type=int, required=True)
    ap.add_argument("--cutoff", type=int, required=True)
    args = ap.parse_args()
    emit_hsk(args.out, args.N, args.cutoff)


if __name__ == "__main__":
    main()
