# 112 — Metal GPU multigrid V-cycle: STEP-0 roofline + go/no-go

**Outcome: NO-GO (Blocked-stop before any Metal code, exactly as STEP 0 mandates).**
No kernel was written. No `accel/` directory was created. No `/core/` source was
modified. The measurement says a Metal V-cycle port cannot pay for itself on this
workload, and the predicted ceiling is stated below *before* a kernel exists — as
required — so the ledger stays honest.

Machine: Apple M2 Pro Mac mini (T6020), 6P+4E, ~200 GB/s advertised unified
memory. macOS 25.5, Metal toolchain present (`xcrun metal` = 26.5). Fixture: the
production L-bracket design box, graded modulus (part solid, design-void
`rho_min^3`), **2,282,256 active DOFs / 737,280 solid elements** — sized to the
real 96×80×96 production case (handoff 092's ~2.29M-DOF figure). Matrix-free
MG-CG (`fea_solve_mgcg_matfree`), 4 levels, Galerkin block cache ON
(production-faithful — `production.cpp:33`).

---

## STEP 0(a) — memory ceiling, measured (not assumed)

STREAM triad on this machine (`scratchpad/stream.cpp`, 512 MB arrays, past cache):

| threads | FP64 GB/s | FP32 GB/s |
|--:|--:|--:|
| 1 | 74.9 | 79.6 |
| 4 | 91.2 | 116.8 |
| 6 | 107.7 | 121.7 |
| 8 | 121.6 | 100.9 |
| 10 | **126.9** | **130.9** |

The advertised "~200 GB/s" is theoretical peak. **Achievable STREAM triad is
~127 GB/s** counting 3 arrays (2R+1W); counting the store's write-allocate RFO it
is ~170 GB/s. A *single* thread already reaches ~75 GB/s — **60% of the 10-thread
peak** — so a handful of cores saturate most of the bus. Any compute unit (CPU or
GPU) sharing this DRAM is bounded by the same ~127–170 GB/s, and the GPU brings no
wider bus (the maintainer's hardware truth, now confirmed here).

## STEP 0(a) — fine matvec roofline (the kernel a Metal V-cycle would replace)

`MatfreeReduced::apply_kgg`, the element-by-element hex8 matvec, 60 reps.
"issued" = per-element gather (24) + scatter-RMW (24×2) + edof (24 int) + factor;
"compulsory" = each active DOF's x/y streamed once + element table once. Actual
DRAM traffic sits between the two.

**FP64:**

| thr | s/matvec | GB/s issued | GB/s compulsory | matvec/s |
|--:|--:|--:|--:|--:|
| 1 | 0.0439 | 11.4 | 3.0 | 23 |
| 4 | 0.0131 | 38.3 | 10.0 | 76 |
| 6 | 0.0111 | **45.0** | 11.8 | 90 |
| 8 | 0.0111 | 45.0 | 11.8 | 90 |
| 10 | 0.0104 | 48.3 | 12.7 | 96 |

**FP32:**

| thr | s/matvec | GB/s issued | GB/s compulsory | matvec/s |
|--:|--:|--:|--:|--:|
| 1 | 0.0256 | 11.3 | 4.1 | 39 |
| 6 | 0.0072 | 40.2 | 14.5 | 139 |
| 8 | 0.0070 | 41.4 | 14.9 | 143 |

**Utilization: the matvec reaches ~45 GB/s issued = 35% of the 127 GB/s STREAM
ceiling (26% of ~170 GB/s with RFO, ~23% of the 200 GB/s theoretical).** It is
**not** bandwidth-saturated. The reason it falls short of STREAM is that it is a
*gather/scatter* (indirect `x[edof[r]]` / `y[edof[r]] +=`), which is
latency-limited, not a sequential stream. The 65% "slack" is gather inefficiency,
**not** bandwidth headroom a GPU could trivially reclaim — the GPU faces the same
indirect pattern, and the determinism requirement (no float atomics, fixed-order
accumulation — `fea_matfree.hpp` 8-colour scheme) forbids the atomic-scatter trick
GPUs normally use to hide it.

FP32 is ~1.55–1.75× faster than FP64 (0.0072 vs 0.0111 s) — so the kernel *is*
traffic-sensitive (halving element bytes ≈ halves time). **The FP32 lever already
exists on the CPU** as the mixed-precision V-cycle (handoff 092,
`fea_set_matfree_mixed_precision`) — so a Metal port does not *unlock* FP32.

**Correction to the record (verified this run):** the mixed-precision *capability*
shipped in 092, but `configure_production_options` (`production.cpp`) enables only
the Galerkin block cache — it **never calls `fea_set_matfree_mixed_precision`**, and
the global default is `false` (`matfree.cpp:320`). **Production therefore runs FP64,
mixed-precision OFF.** So FP32 is *available* but *unspent* in production — a
**fourth free CPU win still owed** (see Blocked §, item D), not a lever a GPU would
be first to claim. This strengthens the NO-GO: the GPU's headline FP32 advantage is
one the CPU can take first, for a one-line flip.

## STEP 0(b) — thread sweep finding (QoS)

FP64 matvec: **6 threads (45.0) ≈ 8 (45.0) ≈ 10 (48.3) GB/s.** The 4 E-cores add
essentially nothing beyond the 6 P-cores — the hypothesis in the brief is
confirmed. **QoS advice: schedule the matrix-free apply on the 6 P-cores
(`fea_set_matfree_threads(6)` / `QOS_CLASS_USER_INITIATED`); adding E-cores buys
~0–7% and, under thermal load, sometimes regresses** (the 10-thread FP32 run
dipped to 36 GB/s — see limitations). This is a CPU-side tuning win available with
zero Metal work.

## Where the solve time actually goes (production-faithful, cache ON, 6 threads)

Two-point tolerance-sweep fit of `total(iters) = build + iters·per_iter`, repeated
to bound thermal variance:

```
tol=1e-03  iters=11  total≈5.98s
tol=1e-11  iters=28  total≈7.52s
=> build ≈ 5.0 s   per_iter ≈ 0.09 s   (repeats: build 4.7–5.3s, per_iter 0.078–0.12s)
```

- **Build (Galerkin hierarchy assembly + coarse LDLT factorisation): ~5.0 s =
  ~66% of the solve.** This is CPU-bound sparse assembly, rebuilt **every MMA
  iteration** (the density field changes). **It is not the V-cycle** and is out of
  scope for a "Metal V-cycle preconditioner" — a GPU cannot touch it without a
  separate, larger, determinism-hostile project.
- **Iterate: 28 × 0.09 s ≈ 2.5 s = ~34% of the solve.** Within one iteration
  (0.09 s): the 4 fine matvecs (1 CG apply + 3 in the V-cycle) ≈ 0.044 s (~49%);
  the remainder (~51%) is the P0 restrict/prolong SpMVs (2.28M×285k sparse), the
  assembled coarse-level SpMVs, the **coarse direct LDLT solve** (a sparse
  triangular solve — CPU-only, and a mandatory CPU↔GPU round-trip *mid-V-cycle*
  every iteration if the fine level moves to Metal), and the CG vector ops.

## STEP 0(c) — predicted ceiling (stated BEFORE any kernel) → GO/NO-GO

Amdahl on the full solve, which is what the maintainer ships:

- **Absolute hard cap** (make the entire iterate portion *free*): 7.5 s → 5.0 s =
  **1.5×**. The build alone forbids more.
- **Realistic** (Metal makes the addressable iterate portion 2× — optimistic,
  given the coarse sparse levels + LDLT round-trip + deterministic scatter):
  7.5 s → 6.25 s = **~1.2×**.
- The FP32 byte-halving that would headline a GPU port is a CPU lever too (092) —
  and *cheaper* there (a one-line production flip, item D), so the GPU's marginal
  win over an FP32 CPU path is only the bus-utilization delta on a gather-bound
  kernel — small, and shared-bus-limited.

**Predicted full-solve speedup: ~1.2× realistic, ~1.5× absolute ceiling.**

Reading against the brief's gate: the matvec's 35% bus utilization is <40%, which
by the letter says "2–4× on the table." That 2–4× is real **for the isolated
matvec kernel** — but it does **not** survive to the solve, because (1) the
kernel is only ~34% of the solve and the build (66%) is unaddressable, (2) the
coarse LDLT/SpMV levels don't port cleanly or deterministically, and (3) FP32 is
already spent. The kernel-local gate and the system-level ceiling disagree, and
the honest number for the decision is the system one: **~1.2×.**

This is precisely the "10–15×-predicted / 1.33×-delivered" pattern the project has
been burned by. A Metal port (new `accel/metal/`, MSL kernels, MTLBuffer plumbing,
a bit-identical `PreconditionerBackend` seam + parity test, no-atomics determinism
proof, ≥2-fixture correctness guards, thermal characterisation, `--precond=metal`
worker plumbing) for a measured ~1.2× is a **NO-GO** on cost/benefit.

## Blocked

Per STEP 0(c) and ARCHITECTURE §8.2/§8.7, stopping here with the numbers.
**Decision (maintainer, this run): accept NO-GO.** The Metal port is not built.
Recorded below are the follow-ups this measurement surfaced — **four zero-Metal
CPU wins**, three of them free, one a genuine new lever. Each is a *spec*, not
implemented here (ARCHITECTURE §8.8 — one task per run).

### D. Owed free win — flip mixed precision ON in production (small task)
The FP32 mixed-precision V-cycle (092) is capability-complete and tested, but
`configure_production_options` never enables it, so **production solves in FP64**
(verified: `production.cpp` sets only the Galerkin cache; `g_mf_mixed_precision`
defaults false). Add `fea_set_matfree_mixed_precision(true)` alongside the cache
line. Measured effect here: iterate ~1.1–1.15× (3 of the 4 fine applies per CG
iteration go FP32); correctness is guarded by the outer CG's FP64 true residual —
the same sloppy-preconditioner argument 092 already made. Gate-V2 unaffected
(library default unchanged; this flips the production *front-end* config only).
Verify no iteration-count regression on the ladder before flipping.

### C. Owed free win — pin the apply to the 6 P-cores (small task)
6 threads ≈ 10 threads on the matvec (E-cores add ~0–7%, sometimes regress under
thermals). Default the matrix-free thread count to the P-core count (or set the
worker QoS to `USER_INITIATED` so the scheduler keeps it off the E-cluster).
One-line change; no correctness surface (the apply is bit-identical across thread
counts by construction — `fea_matfree.hpp` 8-colour).

### B. Headline future lever — a STALE-PRECONDITIONER scheme (own roadmap item)
**This, not the V-cycle, is where the solver time is.** The Galerkin hierarchy
BUILD (assembly + coarse LDLT) is **~66% of every solve and is rebuilt every MMA
iteration** — but the hierarchy is a *preconditioner*: it does not have to be
*current*, only *useful*. CG's FP64 true residual is the correctness certificate
(exactly the argument that licensed FP32 sloppiness in 092), so a preconditioner
built from a slightly stale density field only costs *iterations*, never accuracy.
Rebuild the hierarchy every K MMA iterations (or on a density-drift threshold),
reusing it in between; the fine matrix-free operator (which alone sets the field
and the sensitivities) stays exactly current every iteration — only the *coarse
correction* goes stale. **Solve-level ceiling ~2–2.5×** (amortising a 5 s build
over K solves), in pure deterministic C++ — dwarfing Metal's 1.2×. Spec, don't
implement; the risk is iteration-count blow-up if K is too large or the drift
threshold too loose, so the task must measure iters-vs-K on ≥2 fixtures and pick K
from the knee. Composes with D (mixed precision) and C (P-core pin).

### A. If a GPU experiment is ever genuinely queued — seam only
Land the pure-C++ `PreconditionerBackend` seam (bit-identical refactor + parity
test), no Metal impl, so future work has a home. Adds an abstraction with no
consumer today (borders on §8.8) — worth it only if A/B/D don't already close the
gap. Full Metal is not recommended on the ~1.2× numbers.

ARCHITECTURE.md was **not** modified. The seam it pre-authorises (`/core/`
Apple-free + a new top-level `accel/metal/` under a default-OFF CMake option) is
genuinely permitted — §3/§4 forbid Apple deps *in /core/*, not a sibling
directory — so path A (seam) and a future full-Metal attempt remain open to the
maintainer without an ARCHITECTURE change. Nothing in the file forbids the seam;
the block is on cost/benefit, not architecture.

### Wrap-up item 4 — warmA-vs-cold @ 128-scale (warm-start production-flip gate)

**Status: not captured by Step 0** (the Metal roofline instrumentation measured
the matvec + MG-CG *solve* only — it never ran the `minimize_plastic` ladder or
warm-start; the existing `warm_start_probe` uses span-8 fixtures). A literal 128³
cold+warmA ladder proved to be a *multi-hour* single-thread-build-bound run (which
itself re-confirms §B: the ladder is build-bound), **not** the "quick rider" the
framing implied. Per the maintainer's call, it runs at **production-scale ~64** on
`scratchpad/warm64_probe.cpp` — **both** load modes (110 found the cold-vs-warmA
divergence is mode-dependent: |Δρ|=0.0013 load-case vs 0.197 self-weight, so both
must be checked), cold vs warmA, production-faithful (MMA ladder, matrix-free
MG-CG, Galerkin cache + mixed precision + 6 P-cores). Reported on the 110 template:
per-rung iters, wall, achieved fraction, worst-case margin, savings %, and terminal
|Δρ|, all costs counted. **Result table appended below on completion.**

**Follow-up if savings hold:** the warmA production flip is its own small,
114-style task (add `o.warm_start_inherit = true` to the production config). That
handoff **must state plainly** that flipping *changes production self-weight
designs* — a different optimum with comparable margins, not a byte-identical
speedup (110's self-weight |Δρ|=0.197 is a real geometry change) — so the
maintainer signs off on the design change with eyes open, not as a footnote. This
is the *warm-start* flip (110 lineage), orthogonal to this Metal NO-GO.

## Evidence — raw test output (baseline unchanged; no source modified)

Rebuilt `libtopopt.a` from current source (the vendored lib was stale — missing
the 092 mixed-precision symbols); no `.cpp`/`.hpp` edited. Solver suite green:

```
    Start 18: fea_mgcg_matfree
1/3 Test #18: fea_mgcg_matfree .................   Passed   16.35 sec
    Start 19: fea_matfree_threads
2/3 Test #19: fea_matfree_threads ..............   Passed    8.96 sec
    Start 20: fea_mixed_precision
3/3 Test #20: fea_mixed_precision ..............   Passed    7.97 sec
100% tests passed out of 3
```

Gate-V2 untouched (library solver default = CPU matrix-free MG-CG, unchanged). No
opt-in flag added; fingerprint unaffected. iPad app untouched.

## Limitations observed

- **Thermals (the brief's fanless-adjacent-mini caveat, confirmed).** Under
  sustained load `per_iter` wandered 0.078–0.12 s (±~30%) and the 10-thread FP32
  matvec once regressed to 36 GB/s below the 8-thread 41 GB/s. `build` was stable
  (~5 s). Absolute s/iter numbers carry this ±30% thermal band; the *ratios*
  (build vs iterate, FP32 vs FP64, 6 vs 10 threads) are robust across repeats.
- The "issued" vs "compulsory" byte models bracket true DRAM traffic; the
  utilization conclusion (well under half the bus, gather-limited) holds under
  both.
- Harnesses live in `scratchpad/` (`stream.cpp`, `step0_roofline.cpp`), not
  checked in — they are diagnostics, not CI tests, and depend on the internal
  `fea_matfree.hpp`. Rebuild: `clang++ -O3 -std=c++17 -I core/include
  -I core/src/fea -I <eigen3> step0_roofline.cpp core/build/libtopopt.a`.
