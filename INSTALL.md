# Ribault 1.0.0 — Installation and Testing Guide

## 1. Prerequisites

You need the following tools installed on a Linux x86_64 system:

| Tool | Purpose | Install (Debian/Ubuntu) | Install (Arch) | Install (Fedora) |
|------|---------|------------------------|-----------------|------------------|
| GHC >= 9.0 | Haskell compiler | `sudo apt install ghc` | `sudo pacman -S ghc` | `sudo dnf install ghc` |
| alex | Lexer generator | `sudo apt install alex` | `sudo pacman -S alex` | `sudo dnf install alex` |
| happy | Parser generator | `sudo apt install happy` | `sudo pacman -S happy` | `sudo dnf install happy` |
| gcc | C compiler | `sudo apt install gcc` | `sudo pacman -S gcc` | `sudo dnf install gcc` |
| make | Build system | `sudo apt install make` | `sudo pacman -S make` | `sudo dnf install make` |
| python3 >= 3.6 | TALM assembler | `sudo apt install python3` | (preinstalled) | (preinstalled) |

**Optional** (not required for core functionality):

| Tool | Purpose |
|------|---------|
| graphviz (`dot`) | Render AST and dataflow graphs as PNG |
| taskset | Pin cores during benchmarks |
| bc | Timing calculations in benchmarks |

### Installing GHC via ghcup (recommended)

If your distro's GHC is too old (< 9.0):

```bash
curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh
# Follow prompts, then:
ghcup install ghc 9.6.6
ghcup set ghc 9.6.6
ghcup install cabal latest
cabal install alex happy
```

### Verify prerequisites

```bash
ghc --numeric-version    # should print 9.x.x
alex --version
happy --version
gcc --version
python3 --version
make --version
```

---

## 2. Unpack

```bash
tar xzf ribault-1.0.0.tar.gz
cd ribault-1.0.0
```

---

## 3. Configure

```bash
./configure
```

This checks every dependency and reports what is found, missing, or optional.
A successful run looks like:

```
Configuring Ribault + TALM
══════════════════════════════════════════════════════════

── Required tools ──
checking GHC            ...   ok      /home/user/.ghcup/bin/ghc  (9.6.6)
checking ALEX           ...   ok      /home/user/.ghcup/bin/alex  (3.5.1.0)
checking HAPPY          ...   ok      /home/user/.ghcup/bin/happy  (2.1.3)
checking GCC            ...   ok      /usr/bin/gcc  (13.2.0)
checking PYTHON3        ...   ok      /usr/bin/python3  (3.12.3)
checking MAKE           ...   ok      /usr/bin/make  (4.4.1)

── GHC packages ──
  base                 ... ok
  containers           ... ok
  mtl                  ... ok
  array                ... ok
  text                 ... ok
  ...

── TALM / Trebuchet ──
  TALM directory        ... ok      ./TALM
  TALM assembler.py     ... ok      ./TALM/asm/assembler.py
  Trebuchet interp.c    ... ok      ./TALM/interp/interp.c
  Trebuchet Makefile    ... ok      ./TALM/interp/Makefile
  Trebuchet binary      ... not built — will compile during 'make interp'

══════════════════════════════════════════════════════════
OK
══════════════════════════════════════════════════════════

Generated config.mk
```

If something is missing, it tells you exactly what and how to fix it.

**Configure options:**

```bash
./configure --prefix=/opt/ribault     # custom install location
./configure --ghc=/path/to/ghc-9.8.4  # specific GHC version
./configure --disable-dot              # skip Graphviz check
./configure --help                     # all options
```

---

## 4. Build

```bash
make
```

This builds two things:

1. **Ribault compiler** — four executables:
   - `analysis` — parse H_sub source → AST (.dot)
   - `synthesis` — AST → dataflow graph (.dot)
   - `codegen` — dataflow graph → TALM assembly (.fl)
   - `supersgen` — extract super-instruction Haskell code

2. **Trebuchet interpreter** — the TALM runtime:
   - `TALM/interp/interp` — multi-threaded dataflow executor

Build only the compiler (skip Trebuchet):

```bash
make compiler
```

Build only Trebuchet:

```bash
make interp
```

---

## 5. Test

### 5a. Correctness tests (compile-only)

```bash
make test
```

This compiles all 30 test programs in `test/` through the full pipeline
(analysis → synthesis → codegen) and reports pass/fail:

```
══════════════════════════════════════════════════════════
 Ribault Correctness Tests
══════════════════════════════════════════════════════════
  00_hello_world                         PASS
  01_literals                            PASS
  02_lambda                              PASS
  ...
  26_matrix_mul                          PASS
  27_vector_sum_couillard                PASS
  28_vector_sum                          PASS

══════════════════════════════════════════════════════════
 28 passed, 0 failed
══════════════════════════════════════════════════════════
```

### 5b. Correctness tests (compile + execute on Trebuchet)

```bash
make test-execute
```

This goes further: for each test program, it also builds the
super-instruction library (`libsupers.so`), assembles the TALM bytecode,
and runs it on the Trebuchet interpreter.

### 5c. Run a single test program manually

```bash
# Compile to TALM assembly
./codegen test/10_fibonacci.hss > /tmp/fib.fl

# View the dataflow graph
./synthesis test/10_fibonacci.hss    # prints .dot to stdout

# Full compile + run (using the ribault CLI)
./ribault run test/10_fibonacci.hss --threads 4
```

---

## 6. Try your own program

Create a file `myprogram.hss` in the H_sub language:

```haskell
-- Recursive factorial
fac n =
  if n < 2
  then 1
  else n * fac (n - 1)

main = fac 10
```

Then:

```bash
# Compile
./ribault compile myprogram.hss --output-dir /tmp/myout

# Run on Trebuchet with 4 threads
./ribault run myprogram.hss --threads 4

# Or step by step:
./analysis  myprogram.hss               # check syntax
./synthesis myprogram.hss > my.df.dot    # dataflow graph
./codegen   myprogram.hss > my.fl        # TALM assembly

# Assemble and execute
python3 TALM/asm/assembler.py -a -n 4 -o /tmp/my my.fl
# (after building supers)
TALM/interp/interp 4 /tmp/my.flb /tmp/my_auto.pla /path/to/libsupers.so
```

---

## 7. Benchmarks

```bash
# Run performance benchmarks (scans scripts/ for .hss benchmarks)
make bench

# Custom thread counts and repetitions
./benchmarks/run_benchmarks.sh --threads "1 2 4 8 16" --reps 5

# Results are saved to results/runs/<timestamp>/
```

The paper's reference results are in `results/paper/`:
- `text_search.csv` — parallel text search (up to 8.13x speedup)
- `lcs_wavefront.csv` — LCS dynamic programming (up to 5.62x speedup)
- `self_attention.csv` — transformer attention (up to 8.16x speedup)

---

## 8. Install system-wide (optional)

```bash
sudo make install
```

Default location: `/usr/local/`. Change with `--prefix`:

```bash
./configure --prefix=$HOME/.local
make
make install    # no sudo needed for ~/.local
```

After install:

```bash
ribault compile myprogram.hss
ribault run myprogram.hss --threads 8
ribault info     # show installed tool paths
```

Uninstall:

```bash
sudo make uninstall
```

---

## 9. Generate visualizations (optional)

Requires Graphviz (`dot`):

```bash
# Generate AST and dataflow images for all test programs
make ast    # → test/ast-output/*.dot + test/ast-images/*.png
make df     # → test/df-output/*.dot + test/df-images/*.png

# Single program
./ribault ast myprogram.hss --png
./ribault df  myprogram.hss --png
```

---

## 10. Troubleshooting

**`./configure` fails on GHC packages:**
```
  mtl                  ... ERROR   GHC package 'mtl' not found
```
→ Install via cabal: `cabal install --lib mtl`

**`make` fails with "libHSrts not found":**
→ Your GHC installation may be incomplete. Try reinstalling via ghcup:
```bash
ghcup install ghc 9.6.6 --force
```

**Trebuchet interpreter won't build:**
```
  gcc: error: interp.c: No such file or directory
```
→ The TALM sources are missing. Re-extract from the tarball.

**`make test` reports failures:**
→ Run the failing test manually to see the error:
```bash
./analysis test/FAILING_TEST.hss
./synthesis test/FAILING_TEST.hss
./codegen test/FAILING_TEST.hss
```

**`make bench` says "Trebuchet not built":**
→ Run `make interp` first, or `make` to build everything.

---

## Quick reference

```bash
./configure                          # check dependencies
make                                 # build everything
make test                            # correctness tests
make test-execute                    # tests + Trebuchet execution
make bench                           # performance benchmarks
make ast && make df                  # render graphs (needs dot)
make install                         # install to PREFIX
make clean                           # remove build artifacts
make distclean                       # clean + remove config.mk + Trebuchet binary
./ribault --help                     # CLI usage
```
