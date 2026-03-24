# Ribault — Haskell-to-Dataflow Compiler for High-Performance Parallelism

A compiler from an annotated subset of Haskell (H_sub) to dataflow graphs
targeting the TALM instruction set, executed on the Trebuchet multi-threaded
runtime. Achieves up to **8.16x speedup** over GHC's best parallel mechanisms
at 16 cores.

## Download

**Latest release:** [ribault-1.0.0.tar.gz](https://github.com/tiagoaoa/ribault-release/releases/download/v1.0.0/ribault-1.0.0.tar.gz)

Or clone this repository:

```bash
git clone https://github.com/tiagoaoa/ribault-release.git
cd ribault-release
```

## Quick Start

```bash
./configure          # check GHC, alex, happy, gcc, python3, ...
make                 # build Ribault compiler + Trebuchet interpreter
make test            # correctness tests (30 programs)
```

See [INSTALL.md](INSTALL.md) for the full installation and testing tutorial.

## What is Ribault?

Ribault exploits the structural correspondence between pure functional
programs and dataflow graphs: both are founded on the absence of shared
mutable state. The compiler translates annotated Haskell into TALM assembly
(a coarse-grained dataflow instruction set), and the Trebuchet runtime
executes the resulting graph using per-thread work-stealing with no shared
heap, no spark pool, and no stop-the-world garbage collection.

### Architecture

```
H_sub source (.hsk)
    │
    ▼
┌──────────┐   ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
│ Phase 1   │──▶│ Phase 2      │──▶│ Phase 3      │──▶│ Phase 4      │
│ Front-end │   │ Semantic     │   │ Graph        │   │ Code         │
│ (alex+    │   │ Analysis     │   │ Construction │   │ Generation   │
│  happy)   │   │ (type-check, │   │ (dataflow    │   │ (TALM .fl +  │
│           │   │  λ-lifting)  │   │  DAG/DDG)    │   │  libsupers)  │
└──────────┘   └──────────────┘   └──────────────┘   └──────────────┘
                                                            │
                                            ┌───────────────┼───────────────┐
                                            ▼               ▼               ▼
                                      TALM assembly   Supers.hs      libsupers.so
                                        (.fl)         (Haskell FFI)   (shared lib)
                                            │
                                            ▼
                                    ┌──────────────┐
                                    │ FlowASM      │
                                    │ Assembler     │
                                    │ (Python)      │
                                    └──────┬───────┘
                                           ▼
                                    ┌──────────────┐
                                    │ Trebuchet    │
                                    │ Interpreter  │
                                    │ (C, pthreads)│
                                    └──────────────┘
```

### Key Concepts

- **Super-instructions**: coarse-grained sequential blocks compiled by GHC as
  native code, linked into `libsupers.so`. All parallelism coordination happens
  *between* supers via TALM's token-matching firing rule.

- **Firing rule**: an instruction executes the instant all its input tokens
  arrive — no program counter, no barriers, no locks. Independent nodes
  fire in parallel on separate pthreads.

- **Heap isolation**: each super runs in its own pthread with its own GHC
  capability, so GC pauses are local (not stop-the-world).

## Prerequisites

| Tool | Required | Notes |
|------|----------|-------|
| GHC >= 9.0 | Yes | with packages: base, containers, mtl, array, text |
| alex | Yes | Haskell lexer generator |
| happy | Yes | Haskell parser generator |
| gcc | Yes | Trebuchet interpreter + libsupers.so |
| python3 >= 3.6 | Yes | TALM assembler |
| graphviz (dot) | No | Graph visualization |
| taskset | No | Core pinning for benchmarks |

`./configure` checks all of these and reports exactly what is missing.

## Repository Structure

```
ribault-release/
├── configure              # Dependency checker → generates config.mk
├── Makefile               # Build system (compiler + Trebuchet + tests + install)
├── ribault                # Unified CLI wrapper
├── src/
│   ├── Analysis/          # Lexer.x, Parser.y, Syntax.hs, Semantic.hs, AST-gen.hs
│   └── Synthesis/         # Builder.hs, Codegen.hs, GraphViz.hs, Types.hs, ...
├── TALM/
│   ├── asm/               # FlowASM assembler (assembler.py, flowasm.py, ...)
│   └── interp/            # Trebuchet interpreter (interp.c, queue.c, Makefile, ...)
├── test/                  # 30 test programs (.hsk)
├── tools/                 # Super-instruction build helpers
├── benchmarks/            # run_tests.sh, run_benchmarks.sh
├── results/paper/         # CSV data from all 3 paper benchmarks
├── scripts/               # Per-benchmark configurations
├── INSTALL.md             # Full installation and testing tutorial
├── README.md              # This file
└── LICENSE                # MIT
```

## Example: Adaptive Parallel Sum

```haskell
cutoff = 2   -- log2(P): for P=4 cores, spawn 4 leaf supers

psum xs level =
  if level == cutoff
  then
    super leafSum xs (
      leafSum xs = foldl' (+) 0 (toList xs)
    )
  else
    let (left, right) = split xs
    in psum left (level + 1) + psum right (level + 1)
```

Above `cutoff`: dataflow coordination (split, add). At `cutoff`: each
subproblem fires as a GHC-compiled super-instruction.
See `test/29_mergesort_adaptive.hsk` for a full merge sort example.

## Usage

### Compile and run a program

```bash
# Using the ribault CLI
./ribault compile myprogram.hsk --output-dir /tmp/out
./ribault run myprogram.hsk --threads 8

# Visualize
./ribault ast myprogram.hsk --png     # AST graph
./ribault df  myprogram.hsk --png     # Dataflow graph
```

### Step-by-step (manual)

```bash
./codegen   myprogram.hsk > prog.fl                               # compile
./supersgen myprogram.hsk > Supers.hs                             # extract supers
tools/build_supers.sh myprogram.hsk Supers.hs                     # build libsupers.so
python3 TALM/asm/assembler.py -a -n 8 -o prog prog.fl             # assemble
TALM/interp/interp 8 prog.flb prog_auto.pla ./libsupers.so        # execute
```

### Test and benchmark

```bash
make test              # Compile all 30 test programs through the pipeline
make test-execute      # Compile + execute on Trebuchet
make bench             # Performance benchmarks (TALM vs GHC)

# Or via CLI
./ribault test
./ribault test --execute
./ribault bench --threads "1 2 4 8 16" --reps 5
```

### Install system-wide

```bash
./configure --prefix=/usr/local
make
sudo make install

# Then use from anywhere:
ribault compile myprogram.hsk
ribault run myprogram.hsk --threads 8
```

## Experiment Results

Results from the paper: **Ribault: a Haskell-to-Dataflow Compiler for High-Performance Parallelism**

### Peak Speedups at P = 16 threads

| Benchmark | TALM | GHC Strategies | GHC par/pseq |
|-----------|------|----------------|--------------|
| Parallel Text Search (N=13,000) | **8.13x** | 1.21x | 1.16x |
| LCS Wavefront (N=100,000) | **5.62x** | 4.80x | 1.30x |
| Self-Attention (N=8,192, D=512) | **8.16x** | 2.94x | 3.20x |

### Why TALM outperforms GHC

1. **Heap isolation** — each super has its own GHC capability; GC pauses are
   thread-local, not stop-the-world
2. **No spark overhead** — the dataflow firing rule replaces GHC's spark pool
   (no creation, fizzling, or GC of sparks)
3. **Pipeline decomposition** — I/O-to-compute dependencies are first-class
   dataflow edges; Trebuchet overlaps phases that GHC's spark model cannot express
4. **No explicit barriers** — in LCS wavefront, the firing rule advances the
   wavefront without diagonal iteration loops

Full data with all (N, P) configurations: [`results/paper/`](results/paper/)

## Related Repositories

- [tiagoaoa/Ribault](https://github.com/tiagoaoa/Ribault) — Development fork
- [tiagoaoa/TALM](https://github.com/tiagoaoa/TALM) — TALM runtime (Trebuchet + FlowASM + Couillard)
- [rickymagal/Ribault](https://github.com/rickymagal/Ribault) — Original repository

## License

MIT License. See [LICENSE](LICENSE).
