# §3 — the two "while the machine is quiet" items

**Neither needs a run, and both were resolved by reading. That is the answer,
not a shortcut around one.** §3(a) told me to read a specific handoff first and
said in as many words: "If it is off for a measured reason, that is the answer
and no run is needed." §3(b) turns out to be in the same position, which the
task did not know — its sweep was run in full a fortnight earlier.

Recording this is the point. Both items are framed in the task as open
questions nobody had closed. Both were closed, and the cost of not knowing that
would have been a day of measurement on a contended box reproducing existing
tables.

---

## (a) `warm_start_coarse` — OFF FOR A MEASURED REASON. Do not flip it.

### What the handoff found

`docs/handoffs/2026-08-02-warm-start-coarse-experiment.md` is a full experiment
on exactly this option: three fixtures, three postures each, each run twice,
with a negative-control floor, a full per-rung gate table, and a determinism
check. **Its §6 is titled "Recommendation — DO NOT ARM"** and says explicitly:
"this is a recommendation NOT to change the production default.
`warm_start_coarse` should stay `false`."

Its four reasons, in its own order of weight:

1. **It LOSES in the regime it exists to fix.** On `nobox` — the only fixture
   where multigrid genuinely never carries, i.e. the closest thing to the
   maintainer's latched runs — charged DOF-touches were **+7.2 %**, stagnating
   iterations rose 942 -> 1000, and the wall inside them rose 9.2 %.
2. **It landed on a materially worse design there**: `nobox` rung 2 compliance
   **+26.0 %** and margin **−15.2 %**, with a design difference 10.4x the
   negative-control floor. Slower *and* worse.
3. **Both honest controls are losses** (`healthy` +2.7 %, `nobox` +7.2 %). The
   single win (`stag` −13.1 %) is one fixture of three, and the handoff refuses
   to average them because the average would describe no real run.
4. **The win is structurally capped at rung 0.** The ladder clears the seed
   after rung 0, so a 4-rung ladder can capture at most one rung's benefit.

So the July note's instruction — "find out WHY it is off before flipping it" —
**was carried out, on 2026-08-02.** The task's premise that "nobody did" is not
correct, and the answer to §3(a) is that handoff's recommendation, unchanged.

### The line numbers in the task are stale — corrected here

The task cites `minimize_plastic.cpp:414-450`. The option is not there. As of
this tree:

- the cascade block is [`minimize_plastic.cpp:860`](core/src/simp/minimize_plastic.cpp:860)
  (`if (options.warm_start_coarse) {`), running to ~:918;
- the seed handoff to the rung is [`:1132`](core/src/simp/minimize_plastic.cpp:1132)
  (`opt.initial_design = warm_seed;`);
- the structural rung-0 cap is [`:1885`](core/src/simp/minimize_plastic.cpp:1885)
  (`warm_seed = options.warm_start_inherit ? rho : std::vector<double>();`),
  which the 08-02 handoff cited at `:1104`. **The cap is still there and still
  says what it said** — only its line number moved.

### ★ AND THE TASK'S OWN ARGUMENT FOR RE-OPENING IT IS REFUTED BY THE CODE

The task argues the cascade is "EASIER under PLSM than it ever was under SIMP,
because phi is analytic so the coarse grid is evaluated exactly rather than
restricted."

**That is not what this code path does.** Traced end to end:

1. [`minimize_plastic.cpp:910`](core/src/simp/minimize_plastic.cpp:910) —
   `warm_seed = prolong_density(Gc, G, coarse.physical_density);`
   The cascade produces a **prolonged DENSITY field**, not a φ.
2. [`:1132`](core/src/simp/minimize_plastic.cpp:1132) — it is handed on as
   `opt.initial_design`.
3. [`plsm.cpp:391-392`](core/src/simp/plsm.cpp:391) — PLSM consumes it as
   ```cpp
   if (plsm.seed == "inherit" && options.initial_design.size() == n)
     for (std::size_t v = 0; v < n; ++v) phi[v] = 0.5 - options.initial_design[v];
   ```

So φ is **reconstructed from a prolonged density by `0.5 - rho`**, per voxel.
The analytic φ the argument depends on is never evaluated on the coarse grid;
what crosses the grid boundary is a restricted-then-prolonged density, which is
precisely the lossy transfer the argument hoped PLSM avoided. **The hoped-for
advantage does not exist on this path.** It could be built — a genuinely
analytic coarse φ is a different and larger change — but it is not what
flipping the existing flag would get.

Two smaller facts worth carrying:

- `plsm.seed` defaults to `"inherit"` ([`plsm.hpp:278`](core/include/topopt/plsm.hpp:278)),
  so the seed path IS live under PLSM. The flag is reachable; it is just not
  advantaged.
- His captured production run already reports `warm_start_inherit = True` and
  `warm_start_coarse = False`. **Part A — the lever the 08-02 handoff named as
  "the follow-up with the larger prize" — is already armed on his run.** The
  unspent lever is not this one.

**Verdict: no run. `warm_start_coarse` stays off, for the reason it was already
off, and the new argument for re-opening it does not survive contact with
`plsm.cpp:392`.**

---

## (b) `matfree_threads` — the sweep the task asks for ALREADY EXISTS, and 6 is not arbitrary

### What the machine actually has

    Apple M2 Pro
    6 performance cores + 4 efficiency cores = 10 logical
    16 GB unified memory, ~200 GB/s peak bus

**`matfree_threads = 6` IS THE PERFORMANCE-CORE COUNT.** It is not a guess and
not a default that drifted: `production_matfree_thread_count()`
(`core/src/simp/production.cpp`) derives it from
`sysctl hw.perflevel0.physicalcpu`, and it shipped as the "P-core pin" in
handoff `132-mixed-precision-blocked-and-pcore-pin.md`.

### Where it stops scaling — MEASURED, in `2026-07-28-apple-silicon-envelope.md`

The exact 1/2/4/6/8/max sweep the task asks for, on the **production**
`apply_kgg` kernel at 96³ (2.74M DOF):

| threads | s/matvec | GB/s issued | % of 200 GB/s peak | GFLOP/s |
| --: | --: | --: | --: | --: |
| 1 | 0.0501 | 12.0 | 6 % | 20 |
| 4 | 0.0151 | 39.8 | 20 % | 68 |
| **6** | **0.0110** | **54.5** | **27 %** | **92** |
| 8 | 0.0131 | 45.8 | 23 % | 78 |
| 10 | 0.0118 | 50.9 | 25 % | 86 |

At 128³ (6.44M DOF — his grid's scale): 6 threads → 52.6 GB/s, 26 % of peak.

**IT STOPS SCALING AT 6, AND 8 IS A REGRESSION.** The four E-cores contend for
the same bus and make the matvec slower (45.8 GB/s at 8 threads against 54.5 at
6). Handoff 113's independent sweep agrees (45.0 / 45.0 / 48.3 GB/s at 6/8/10)
and adds that a 10-thread run *regresses to 36 GB/s under sustained thermal
load*. The design is bit-identical at 6 and 10 threads, so this is purely a
speed question.

### The memory-bandwidth answer the task actually wanted

Pure STREAM triad on the same box saturates at **two threads** (145.9 GB/s of a
151 GB/s sustained ceiling — 76 % of the 200 GB/s peak). The operator reaches
only 27 %.

**But the missing ~73 % is NOT reclaimable bandwidth.** The kernel is an
*indirect* gather/scatter (`x[edof[r]]`, `y[edof[r]] +=`) and is
**latency-limited, not bandwidth-limited**. The envelope handoff's own summary:
"there is no idle bandwidth a new algorithm would find."

### And whether a GPU port could ever pay — also measured

A Metal FP32 prototype of the same element apply was built and checked against
both CPU applies:

| grid | Metal FP32 | % of 200 | GFLOP/s | CPU FP64 |
| --- | --: | --: | --: | --: |
| 96³ | 0.00273 s | 62.8 % | 373 | 0.0110 s / 27 % |
| 128³ | 0.00587 s | 69.4 % | 412 | 0.0271 s / 26 % |

**The kernel win is real — ~4x, and thousands of GPU threads do hide the
gather latency that stalls 6 CPU cores.** The system-level verdict is still no,
for three reasons that a faster kernel cannot fix:

- **Precision.** GPU-FP32 vs CPU-FP64 relative L2 = 6.9e-8, which IS the FP32
  epsilon. Production CG runs FP64 to 1e-8…1e-11, so an FP32 apply cannot be the
  convergence operator — only an inner preconditioner, and that lever already
  exists on the CPU (`fea_set_matfree_mixed_precision`, handoff 092) and is
  unspent.
- **Amdahl.** The matvec is only ~34 % of the solve; the Galerkin build is ~66 %
  and is rebuilt every MMA iteration. Full-solve ceiling: **~1.2x realistic,
  ~1.5x absolute.**
- **Determinism.** GPU-FP32 and CPU-FP32 agree only to 7e-8, so a GPU apply is a
  third non-bit-identical answer and breaks the contract `test_matfree_threads`
  enforces.

**Verdict: no run. 6 is correct and already derived from the hardware; scaling
stops at 6 and regresses at 8; the operator is latency-bound not
bandwidth-bound; and a GPU port buys ~1.2x at the system level while costing
determinism.**

### One thing I could not have measured here anyway

A thread-scaling sweep is a pure WALL measurement — there is no
contention-immune unit for it, unlike `N_t` and CG counts. This host ran at load
averages of **18 to 137 on 10 cores** throughout (`host_load.txt`), i.e. 6-13x
starvation that varied minute to minute. **A 1/2/4/6/8/10 sweep taken here would
have been a measurement of the neighbours, not of the machine**, and per R2 and
`never-difference-wallclock-across-runs` it would not have been citable. That
the answer already exists from a quiet-host run is the reason this section has
numbers at all.
