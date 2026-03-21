# Experiment Results

From: **Ribault: a Haskell-to-Dataflow Compiler for High-Performance Parallelism**

## Setup

- Intel Xeon Gold 5412U (Sapphire Rapids, 24c/48t, 2.1-3.9 GHz)
- 251 GB DDR5, single-NUMA domain
- Arch Linux kernel 6.17
- Cores pinned via taskset to 0...P-1, P <= 16, no hyper-threading
- Medians over 3-5 reps, one discarded warmup

## Peak Speedups (P = 16)

| Benchmark | TALM | GHC Strategies | GHC par/pseq |
|-----------|------|----------------|--------------|
| Text Search (N=13000) | **8.13x** | 1.21x | 1.16x |
| LCS Wavefront (N=100000) | **5.62x** | 4.80x | 1.30x |
| Self-Attention (N=8192) | **8.16x** | 2.94x | 3.20x |
