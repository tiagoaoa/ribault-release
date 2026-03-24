# What If Haskell's Parallelism Problem Isn't the Language, but the Runtime?

*Ribault compiles Haskell to dataflow graphs and runs them on a dedicated runtime, achieving 8–43x speedup over GHC on representative workloads and complete immunity to GHC's stop-the-world GC collapse under workload imbalance.*

---

Functional languages imply that their referential transparency and absence of side effects make programs "naturally parallel," yet extracting high performance from these properties has proved difficult in practice. In GHC, the dominant Haskell compiler, parallelism is expressed through annotations such as `par`/`pseq` or the `Strategies` library. While conceptually elegant, this approach carries three sources of overhead that grow with problem size and core count.

The overhead is not in the language, it is in the runtime system.

## Three Sources of Overhead in GHC's Parallel Runtime

GHC's parallel mechanisms inject *sparks* into a shared work-stealing pool managed by the runtime system (RTS). Three costs are well documented in the literature [Harris et al. 2005, Marlow et al. 2009]:

**1. Spark management overhead.** Every potential parallel task creates a spark: a lightweight thunk placed on a deque. Sparks can be *fizzled* (discarded because the main thread already evaluated them), garbage collected (if unreferenced), or stolen by other capabilities. At scale, you're spending significant time managing sparks that may never execute.

**2. Thunk allocation and blackhole synchronisation.** Under lazy evaluation, multiple threads can attempt to evaluate the same thunk simultaneously. GHC prevents this through *blackholing*: a synchronisation mechanism where a thread marks a thunk as "being evaluated" and others block until completion. This works, but it means every shared thunk is a potential contention point.

**3. Stop-the-world garbage collection.** When *any* GHC capability triggers a GC, *all* capabilities must pause, even if they are in the middle of useful work. With 8 threads allocating in parallel, GC pauses synchronise all of them. Under workload imbalance, where one thread does all the work and the rest are idle, GC frequency actually *increases* with the number of cores.

These aren't implementation bugs. They're consequences of a fundamental design choice: GHC's parallel runtime shares a single heap across all capabilities.

## Dataflow Execution as an Alternative

The dataflow model of computation represents a program as a directed graph where nodes are operations and edges carry data tokens. A node *fires* when all its input tokens arrive, consuming them and producing output tokens. No program counter, no locks, and no central scheduler are required.

In the late 1970s and 1980s, MIT built hardware for this: the Tagged-Token Dataflow Architecture. The Id language and its successor pH compiled functional programs to these machines, exploiting the structural correspondence between referential transparency and the dataflow firing rule. Both models are founded on the same principle: a computation proceeds when its inputs are available, without requiring centralised scheduling.

The specialised hardware was eventually abandoned, but the underlying model remains sound. Ribault revisits this correspondence using a modern software runtime on commodity multi-core hardware.

## Ribault: Compiling Haskell to Dataflow Graphs

Ribault is a compiler from H_sub, an annotated subset of Haskell, to dataflow graphs targeting the TALM instruction set. The graphs execute on Trebuchet, a multi-threaded C runtime that simulates the dataflow firing rule on commodity hardware using POSIX pthreads and Chase-Lev work-stealing deques.

The key insight is the *super-instruction*. A super is a coarse-grained, self-contained sequential block: opaque Haskell code compiled by GHC with full optimisations (`-O2`). The programmer marks super boundaries with annotations. The syntax is `super funcName args ( body )`, where the body is arbitrary Haskell passed verbatim to GHC.

A simple example, parallel sum with adaptive granularity:

```haskell
cutoff = 2   -- log2(P): for P=4 cores, spawn 4 leaf supers

psum xs level = case xs of
  []     -> 0
  (x:[]) -> x
  _      ->
    if level == cutoff
    then
      super leafSum xs (
        leafSum xs = foldl' (+) 0 (toList xs)
      )
    else
      case split xs of
        (left, right) ->
          psum left (level + 1) + psum right (level + 1)
```

The recursion tree splits via dataflow coordination until `level == cutoff`, at which point each subproblem becomes a GHC-compiled super-instruction. Setting `cutoff = log2(P)` guarantees exactly P leaf supers, one per core.

```
depth 0:        split               ← dataflow coordination
               /      \
depth 1:    split      split        ← dataflow coordination
           /    \     /    \
depth 2:  S₁    S₂   S₃    S₄      ← 4 GHC-compiled super-instructions
```

The same pattern applies to merge sort, where each leaf super performs a full sequential sort:

```haskell
cutoff = 3   -- for P=8 cores

msort xs level = case xs of
  []     -> []
  (x:[]) -> [x]
  _      ->
    if level == cutoff
    then
      super seqSort xs (
        seqSort xs =
          let hlist = toList xs
              ms []  = []
              ms [x] = [x]
              ms xs  = let (l, r) = splitL xs
                       in mergeL (ms l) (ms r)
          in fromList (ms hlist)
      )
    else
      case split xs of
        (left, right) ->
          merge (msort left (level + 1)) (msort right (level + 1))
```

Everything *inside* a super executes as native code: GHC's strictness analyser, worker/wrapper transformation, and native code generator all apply. Everything *between* supers is coordinated by the dataflow graph: token matching, the firing rule, work-stealing dispatch.

## The Compiler Pipeline

Ribault is implemented in approximately 2,500 lines of Haskell (excluding the generated lexer and parser). It has four phases:

**Phase 1: Front-end.** Alex and Happy lex and parse the source into an AST. Super-instruction blocks are preserved verbatim as opaque strings.

**Phase 2: Semantic analysis.** Type inference over the AST, lambda-lifting to make all free variables explicit, and assignment of unique names to super-instruction blocks.

**Phase 3: Graph construction.** The core of the compiler. The typed AST is traversed to produce a `DGraph DNode`: a directed graph of dataflow nodes with typed ports. Literals become constant nodes, conditionals become steering subgraphs, recursive calls create back-edges with the TALM call/return protocol (`callgroup`/`callsnd`/`retsnd`/`ret`), and super annotations become opaque `NSuper` nodes.

**Phase 4: Code generation.** The graph is serialised to TALM assembly (`.fl` files), one instruction per node in topological order. Separately, super bodies are extracted into a Haskell module compiled by GHC into a shared library (`libsupers.so`) loaded by Trebuchet at runtime.

The translation is *compositional*: each H_sub expression maps to a DFG subgraph through the function `goExpr`, threading a builder monad that manages the graph, lexical environment, guard stack, and active function set. The full paper proves this translation is Turing-complete (H_sub can express all partial recursive functions), preserves types (well-typed source produces well-typed graphs under an enriched DFG type system), and preserves semantics (executing the graph on an initial state produces the encoded result of evaluating the source expression).

## What Happens at Runtime

When Trebuchet loads a program:

1. The bytecode (assembled from `.fl`) is distributed across P processing elements (PEs)
2. Each PE maintains a local *token store*: partial input sets indexed by (node, tag) pairs
3. When all inputs for a node arrive on the same tag, the node is placed on the PE's ready deque
4. Worker threads dequeue and execute nodes: primitive operations inline, super-instructions via `dlopen`/`dlsym` into `libsupers.so`
5. Output tokens are deposited to downstream nodes, potentially on other PEs

The critical difference from GHC: **each super runs in its own pthread with its own GHC capability**. When super `s4` allocates and triggers a GC, only `s4`'s thread pauses. Supers `s5`, `s6`, `s7` continue uninterrupted. There is no stop-the-world anything.

Tags are computed as integers: `tag = parent * R + k`, where R is the tag radix (default 9) and k identifies the call site. This supports approximately `floor(log_9(2^63))` ≈ 19 levels of recursive nesting, sufficient for the coarse-grained decompositions Ribault targets.

## The Numbers

Two sets of experiments tell the story. The first, on a laptop (Core i5-12450H, 4+4 cores, 8 GB RAM), tests four benchmarks spanning regular and irregular parallelism. The second, on a server (Xeon Gold 5412U, 24 cores, 251 GB DDR5), tests three I/O-heavy and compute-heavy workloads at scale.

### Merge Sort: 43x Faster

Parallel merge sort on random integer lists, N from 50,000 to 1,000,000.

At N=10^6, Ribault (P=4) finishes in **23 ms**. The best GHC `par`/`pseq` configuration (P=4) takes **939 ms**: a **40x** gap. GHC Strategies (P=2) is slightly slower at 1005 ms, yielding **43x**.

Where does the 43x come from? Not primarily from parallelism. Ribault's four P curves (P=1: 29 ms, P=4: 23 ms, P=8: 27 ms) lie close together: super-instruction execution dominates total runtime, and the TALM coordination adds only marginal additional speedup. The advantage is systemic: it comes from eliminating GHC's RTS overhead, not from extracting more parallelism.

### Dyck Paths: GHC Collapses, Ribault Doesn't

Dyck path enumeration generates all paths of length 2N using a recursive tree. The `imb` parameter controls workload imbalance: at `imb=0%`, the tree is balanced; at `imb=100%`, virtually all work concentrates in a single branch.

With N=10^6, P=8, and balanced workload (`imb=0%`), both GHC baselines run at about 13 ms. Ribault runs at 5 ms, a **14.7x** advantage.

At `imb=100%`, the situation changes substantially. GHC Strategies degrades from 13 ms to **3.43 seconds** (a **264x** slowdown relative to its own balanced performance). GHC `par`/`pseq` degrades to 1.47 s. Ribault stays at **5.3 ms**, unaffected. The gap is not because Ribault gets faster: it is because GHC collapses under imbalanced GC pressure while Ribault's runtime is immune to this failure mode.

The root cause is anti-scaling in GHC's garbage collector. At `imb=100%`, one thread does all the work while P-1 threads idle. Yet stop-the-world GC pauses synchronise across *all* threads. More cores produce more idle threads participating in synchronisation: P=2 takes 579 ms (45x slower than P=1), P=8 takes 3.43 s (269x slower than P=1).

The TALM runtime is immune: tokens are consumed deterministically, there is no garbage collector, and no stop-the-world synchronisation is required. Ribault's runtime is flat across all imbalance levels and thread counts.

### Parallel Text Search: 8.13x on 16 Cores

On the server platform, parallel keyword counting over 130 GB of text (13,000 files of 10 MB each), partitioned into 14 independent tasks.

At P=16, TALM reaches **8.13x** speedup over the sequential baseline. Both GHC variants plateau below **1.21x**, barely improving over sequential despite having 16 cores available. The bottleneck: concurrent heap allocation across 14 tasks triggers stop-the-world GC so frequently that at P≥4, GHC effectively serialises execution.

TALM avoids this entirely: each super executes in its own pthread with its own capability, so a GC pause triggered by one task's allocation is local to that thread.

### Self-Attention Pipeline: 8.16x

This benchmark exercises pipeline parallelism. Each of 14 blocks reads Q, K, V matrices from disk (I/O phase), then computes scaled dot-product attention (compute phase). The phases are sequential *within* a block but independent *across* blocks.

In TALM, each block compiles into two supers connected by a single token edge. Trebuchet fires all 14 I/O supers immediately, and fires each compute super the instant its paired I/O super completes. I/O and compute overlap freely across blocks, with no synchronisation between them.

In GHC, both phases are bundled into a single spark. The compute phase of one block cannot begin while the I/O phase of another is still executing. Pipeline overlap that TALM expresses as a first-class dataflow edge is *structurally inexpressible* in GHC's spark model.

Result at P=16, N=8192: TALM reaches **8.16x**. The best GHC variant achieves **2.94x**.

### LCS Wavefront: Dataflow Without Barriers

Longest Common Subsequence via the standard O(N^2) dynamic programming recurrence. This is *not* embarrassingly parallel: each cell depends on its upper, left, and upper-left neighbours. The only available parallelism is along anti-diagonals.

In TALM, you state the recurrence: block (i,j) depends on blocks (i-1,j) and (i,j-1). Trebuchet fires each block the instant both tokens arrive. The wavefront advances purely by data availability, without diagonal iteration loops or explicit barriers.

GHC `par`/`pseq` must iterate over diagonals in a sequential outer loop, spark blocks on each diagonal, force all results, then advance to the next. This explicit barrier is the performance ceiling: `par`/`pseq` plateaus at ≈1.3x regardless of P.

At P=16, N=100,000: TALM reaches **5.62x**. GHC Strategies reaches 4.80x. GHC `par`/`pseq` reaches 1.30x.

## Limitations: Where Ribault Is Slower

The Fibonacci benchmark reveals the granularity boundary of Ribault's approach.

Computing fib(35) with tree-recursive decomposition, the `cutoff` parameter controls granularity. At `cutoff=30`, only 8 leaf super-instructions execute, each performing ~30 iterative additions (~240 total). Ribault completes in 3.5 ms. GHC finishes in approximately **1 microsecond**. That's a 3,000x disadvantage.

At `cutoff=15`, the tree has fib(21) = 10,946 leaves and ~164,000 total additions. Ribault (P=4) takes 91.9 s. GHC takes 0.7 ms. A **94,000x** disadvantage.

The explanation is the per-operation overhead of TALM's runtime. Each dataflow node firing, including the call/return protocol for recursive invocations, costs approximately 0.2–0.5 ms. With `cutoff=15`, the dataflow graph contains ~21,000 operations. At ~5 ms per operation, the expected runtime is ~105 s, closely matching the observed 91.9 s.

GHC's spark mechanism, by contrast, creates and schedules a spark in ~100 ns, four orders of magnitude cheaper per task.

The practical consequence: **supers must encapsulate O(ms) or more of sequential work** to amortise the dataflow dispatch overhead. Programs that require fine-grained interleaving of parallel coordination and computation (lock-step stencil computations, iterative Fibonacci base cases) are not well suited to the current architecture.

## Why This Matters

The experimental results support three observations:

**1. The overhead structure of GHC's RTS is the primary bottleneck for parallel Haskell, not the parallelism mechanism itself.** Ribault's P=1 runtime is 2.9x faster than GHC's P=1 on matrix multiplication, before any parallelism enters the picture. On merge sort, the sequential advantage alone accounts for most of the 43x gap. Super-instructions execute as GHC `-O2` native code without the allocator, closure representation, or stack frame overhead of the GHC runtime system.

**2. The absence of garbage collection is decisive under workload imbalance.** The Dyck path benchmark demonstrates this: TALM's runtime is flat across all imbalance levels because tokens are fixed-size integers consumed deterministically during node firing. There is no heap, no nursery, no generational promotion, no synchronisation between workers for memory management. GHC's catastrophic degradation (264x slowdown) under 100% imbalance is a consequence of the shared-heap parallel GC design; Ribault is immune to it.

**3. Dataflow graphs make pipeline parallelism a first-class citizen.** The self-attention benchmark shows overlap that is trivially expressible in the dataflow model (two supers connected by an edge) but structurally impossible in GHC's spark model (where both phases must be bundled into a single evaluation unit). The firing rule ("execute when your inputs arrive") is a more general coordination primitive than sparks.

## The Source Language Is Turing-Complete

H_sub supports mutually recursive function declarations, lambda abstractions, conditionals (`if`/`case`), local recursive bindings (`let` as `letrec`), binary and unary operators, lists, pairs, cons cells, and super-instruction blocks. The proof encodes the six primitives that generate the class of mu-recursive functions: zero, successor, projection, composition, primitive recursion, and unbounded minimisation. Since these coincide with the Turing-computable functions, H_sub is Turing-complete.

The translation to dataflow graphs also preserves types and semantics. The type preservation theorem shows that if a well-typed H_sub expression translates to a DFG subgraph G, then G is well-typed under an enriched port type system that tracks compound types (lists, pairs) through compilation. The semantic preservation theorem shows that executing G on an initial state produces the encoded result of evaluating the source expression, proved by induction on the evaluation derivation, with a secondary induction on the translation relation.

## Try It Yourself

The full release (compiler, runtime, 29 test programs, benchmark harness, and all paper data) is available as a self-contained package:

**Download:** [ribault-1.0.0.tar.gz](https://github.com/tiagoaoa/ribault-release/releases/download/v1.0.0/ribault-1.0.0.tar.gz)

**Repository:** [github.com/tiagoaoa/ribault-release](https://github.com/tiagoaoa/ribault-release)

```bash
tar xzf ribault-1.0.0.tar.gz
cd ribault-1.0.0
./configure        # checks GHC >= 9.0, alex, happy, gcc, python3
make               # builds compiler + Trebuchet interpreter
make test          # compiles all 28 test programs

# Run Fibonacci on 4 threads:
./ribault run test/10_fibonacci.hsk --threads 4
```

The compiler is MIT-licensed. The TALM runtime (Trebuchet interpreter + FlowASM assembler) is LGPL-3.0: modifications to the runtime must be shared, but programs running on it are not encumbered.

## What's Next

Several directions are promising:

**Adaptive granularity control.** Currently the programmer manually places super boundaries. Dynamically merging or splitting supers based on runtime profiling (similar to heartbeat scheduling) could eliminate the need for manual cutoff tuning.

**Speculative execution.** The TALM instruction set already includes commit/cancel nodes for speculative branches. Enabling these would improve performance on programs with unpredictable control flow.

**Higher-order functions and type classes.** H_sub currently requires all higher-order functions to be specialised at compile time. Extending the source language to support first-class closures as dataflow values and type class dispatch would significantly broaden the class of compilable programs.

**Hardware dataflow accelerators.** The software Trebuchet runtime pays ~0.5 ms per dataflow operation. Targeting hardware accelerators (e.g. the SambaNova SN40L's dataflow architecture) could eliminate the matching-store overhead entirely, recovering the performance lost on fine-grained benchmarks like Fibonacci.

**Distributed execution.** Mapping dataflow graphs onto multi-node clusters by extending Trebuchet's communication layer to networked processing elements, a direction already explored for Python in the Sucuri library.

These directions build on the central observation of this work: the correspondence between pure functional programs and dataflow graphs, first exploited by the MIT Tagged-Token Architecture in the 1980s, can be effectively realised in software on commodity multi-core hardware.

---

*Ribault is developed at UFES/UERJ. The compiler is the undergraduate thesis of Ricardo Magalhaes Santos Filho, advised by Prof. Alberto Ferreira de Souza and Prof. Tiago A.O. Alves. The TALM runtime was developed at COPPE/UFRJ.*

*The release package, including all source code, benchmarks, and paper data, is available at [github.com/tiagoaoa/ribault-release](https://github.com/tiagoaoa/ribault-release).*
