# 2026-07-28 — What the hardware can actually do: solver benchmark on Apple Silicon

**Status:** Measurement complete. **NO production code changed** —
`git diff main -- core app tools` is empty; the only new files are this handoff and
`evidence/2026-07-28-apple-silicon-envelope/` (four harnesses, their raw output, a
build script, the machine record, and the H5 re-cost analysis). Measurement-only,
per bar **B3**: Accelerate and Metal are **system frameworks**, no new build
dependency, nothing compiled into `libtopopt`.

**Track:** core measurement only. **Parallel-legal:** adds files, edits none.

This re-runs and extends handoff
[`113`](113-metal-gpu-multigrid-vcycle-go-no-go.md), which measured H1/H2 on this
same machine but stopped at STEP 0 (no Metal code, no Accelerate, no AMG re-cost).
This run reproduces H1/H2 on today's thermal state and adds the three angles 113
never took: an actual **Accelerate/AMX** comparison (H3), a **real Metal FP32
kernel** measured on the GPU (H4), and the **AMG re-cost under unified memory**
(H5). The harnesses 113 left in `scratchpad/` were never checked in; these are.

---

## B1 — the exact machine (`evidence/…/machine.txt`)

| | |
|---|---|
| Model | **Mac mini (Mac14,12)** |
| Chip | **Apple M2 Pro** |
| Cores | **10 = 6 Performance + 4 Efficiency** (`hw.perflevel0/1.physicalcpu`) |
| RAM | **16 GiB unified** (`hw.memsize` = 17,179,869,184 B) |
| Theoretical memory bandwidth | **200 GB/s** (LPDDR5-6400, 256-bit — spec, not measured) |
| macOS / clang | 26.5.1 (25F80) / Apple clang 21.0.0 |
| Metal | runtime compiler present (offline `metal` CLI component not installed; H4 compiles MSL at run time via `newLibraryWithSource:`) |

**The brief's numbers were for an M4 / M4 Pro; this box is an M2 Pro with 16 GiB.**
That RAM ceiling is decisive for H5 and is carried honestly there — it is *not* the
large-unified-memory Mac the H5 premise imagined.

Every throughput figure below is quoted against the **200 GB/s theoretical peak**
(bar B2). Wall-clock appears only as labelled corroboration (bar B4); the headline
signals are bandwidth (GB/s, % of peak) and, for H5, memory footprint.

---

## H1 — sustained memory bandwidth, measured (`stream.cpp`, `stream_out.txt`)

STREAM triad `a = b + s*c`, 512 MB arrays (past the 4 MB L2 / SLC), best-of-20,
counting 3 arrays (2R+1W); `+RFO` counts the write-allocate line fill (4 arrays).

| threads | FP64 GB/s | (+RFO) | FP32 GB/s | (+RFO) | % of 200 (FP64 counted) |
|--:|--:|--:|--:|--:|--:|
| 1  | 85.3  | 113.7 | 86.0  | 114.7 | 43% |
| 2  | 145.9 | 194.6 | 137.0 | 182.6 | 73% |
| 6  | 144.2 | 192.3 | 147.3 | 196.4 | 72% |
| 10 | **151.3** | 201.7 | 145.6 | 194.1 | **76%** |

**Sustained triad ≈ 151 GB/s counted = 76% of the 200 GB/s peak** (the `+RFO`
model reaches the bus, ~200). A **single thread already gets 85 GB/s = 43% of
peak**, and **two threads saturate ~146 GB/s** — a handful of cores own the bus.
This is the real ceiling every iterative solve runs into (O(1) arithmetic
intensity). (113 measured a lower ~127 GB/s under sustained thermal load; the
ratio-level conclusion is identical.)

---

## H2 — our matrix-free operator, achieved (`matvec_roofline.cpp`, `matvec_roofline_out.txt`)

The **production** kernel — `fea_detail::MatfreeReduced::apply_kgg` (matfree.cpp),
the element-by-element hex8 matvec run every CG/V-cycle iteration — driven at
production grid sizes, FP64, thread-swept. "issued" brackets the gather/scatter
traffic, "compulsory" the minimum stream; true DRAM traffic sits between.

**96³ (2.74M DOF, 884,736 elements):**

| threads | s/matvec | GB/s issued | % of 200 | GFLOP/s |
|--:|--:|--:|--:|--:|
| 1  | 0.0501 | 12.0 | 6% | 20 |
| 4  | 0.0151 | 39.8 | 20% | 68 |
| **6** | **0.0110** | **54.5** | **27%** | **92** |
| 8  | 0.0131 | 45.8 | 23% | 78 |
| 10 | 0.0118 | 50.9 | 25% | 86 |

**128³ (6.44M DOF, 2.10M elements):** 6 threads → **52.6 GB/s issued = 26% of
peak, 89 GFLOP/s**.

**Reading (said plainly, as the brief asks):** on the 6 P-cores the operator reaches
**~54 GB/s = 27% of the 200 GB/s peak (≈36% of the 151 GB/s STREAM ceiling)**. It is
**far below peak — but the missing ~73% is not reclaimable bandwidth.** The kernel is
an *indirect* gather/scatter (`x[edof[r]]`, `y[edof[r]] +=`), latency-limited, not a
sequential stream. **6 threads beat 8 and 10** — the 4 E-cores contend for the same
bus and *regress* the matvec (8 thr 45.8 < 6 thr 54.5), reproducing the handoff-132
P-core-pin finding exactly. **The cheapest win here is the P-core pin, and it already
shipped** (132); there is no idle bandwidth a new algorithm would find.

---

## H3 — Accelerate / AMX FP64, vs our kernel (`accel_amx.cpp`, `accel_amx_out.txt`)

Are we leaving FP64 throughput on the table by hand-writing the 24×24 element
matvec instead of routing it through Apple's matrix coprocessor?

| kernel | GFLOP/s | vs AMX peak |
|---|--:|--:|
| large `dgemm` (empirical AMX FP64 **peak**) | **637** | 100% |
| `dgemv` 24×24, one element at a time (cache-hot) | **15.4** | 2.4% |
| `dgemm` 24×24 · 24×256 (batched apply, cache-hot) | **208** | 33% |
| our hand NEON kernel (H2, incl. gather, 6 thr) | ~90 | — |

**Two clear findings:**
1. **Per-element BLAS is a 6× REGRESSION** (15 vs ~90 GFLOP/s): call overhead
   swamps a 24×24 `dgemv`; AMX has nothing to amortise. Our hand-written NEON
   kernel is the correct choice — nothing on the table there.
2. **Batched `dgemm` raises the COMPUTE ceiling to ~208 GFLOP/s (2.3× our kernel)**
   — but it is unreachable in practice: the operator is **gather-bound** (H2), and
   batching a colour's elements still requires gathering `X[24×N]` and scattering
   `Y[24×N]` — the *same* indirect traffic that is the actual bottleneck. It would
   also break the 8-colour **bit-identical** determinism contract (`dgemm`'s
   summation order is not the fixed column order `test_matfree_threads` asserts).

**Net: no meaningful AMX win for this kernel.** The table is bare on the compute
side we already run near-optimally, and full on the memory/gather side no BLAS call
touches.

---

## H4 — Metal FP32 matvec prototype (`metal_matvec.mm`, `metal_matvec_out.txt`)

The operator only — **not** a solver. The GPU kernel is the same element apply,
dispatched **one colour at a time** over the production 8-colour partition (so the
non-atomic scatter is race-free, exactly like the CPU path), fed the element table
built by the real `mf_build_reduced`. Correctness checked against both CPU applies.

| grid | Metal FP32 | % of 200 | GFLOP/s | CPU FP64 (H2) |
|---|--:|--:|--:|--:|
| 96³  | 0.00273 s | **62.8%** | 373 | 0.0110 s / 27% / 90 |
| 128³ | 0.00587 s | **69.4%** | 412 | 0.0271 s / 26% / 89 |

**Throughput: the GPU FP32 apply is genuinely ~4× the CPU FP64 apply and reaches
62–69% of the shared 200 GB/s bus, versus the CPU's 27%.** This **revises one claim
in 113** — the GPU *can* reclaim much of the gather slack, because thousands of GPU
threads hide the indirect-load latency that stalls 6 CPU cores. The isolated-kernel
win is real.

**But usability — and this is the honest verdict — it does not survive:**
- **Precision.** GPU-FP32-vs-CPU-FP64 relative L2 = **6.9e-8** (identical to the
  CPU FP32 floor 7.3e-8 — it *is* the FP32 epsilon, not a kernel bug). At that
  floor an FP32 apply **cannot be the outer/convergence operator** — the production
  CG runs FP64 to tol 1e-8…1e-11, which is exactly where the project's FP32
  iterative-refinement attempt already failed. FP32 is only viable as an **inner
  preconditioner** (the mixed-precision V-cycle) — a lever that **already exists on
  the CPU** (handoff 092, `fea_set_matfree_mixed_precision`) and is even *unspent*
  in production (113 §D).
- **System-level Amdahl.** The matvec is only ~34% of the solve; the Galerkin
  **build is ~66% and rebuilt every MMA iteration** (113) and a matvec port cannot
  touch it. 113's full-solve ceiling stands: **~1.2× realistic, ~1.5× absolute** —
  now with the kernel *measured* (373–412 GFLOP/s) instead of predicted.
- **Determinism.** GPU-FP32 vs CPU-FP32 agree only to 7e-8 (different rounding/FMA)
  — a GPU apply is a *third*, non-bit-identical answer, breaking the contract
  `test_matfree_threads` enforces.

**Net: usable only as a preconditioner-grade accelerator, chasing a system ~1.2×
behind a full Metal + determinism build — and the cheaper FP32 CPU lever it would
compete with is already sitting unused.** The 113 NO-GO holds, now on measured
GPU numbers rather than a roofline prediction.

---

## H5 — re-cost AMG under unified memory (`amg_recost.md`)

The old NO-GO (131) called the ~20 GB AMG hierarchy "unrunnable" against a
discrete-VRAM mental model. Re-made with **this run's H1 bandwidth** and the repo's
own AMG memory measurements, scaled to production DOF on this **16 GiB** box:

| grid | reduced DOF | matfree | **assembled AMG (23.3×)** | **lean AMG (2.37×)** |
|---|--:|--:|--:|--:|
| 96³  | 2,738,019 | 0.30 GB | **7.05 GB** | 0.72 GB |
| 128³ | 6,440,067 | 0.71 GB | **16.58 GB** | 1.69 GB |

(bytes/DOF from `2026-07-23-amg-phase-1-measurement`: matfree 110.5, assembled
2,573.9, lean 261.8. The "unsmoothed = 12× cheaper setup / 2.2× less memory" the
brief cites is 131 §6d's *unsmoothed-vs-smoothed* delta; the **2.37×** end-to-end
lean footprint is the number a RAM budget needs.)

**The re-cost splits — capacity is not uniformly reversed on this hardware:**

1. **The fat (assembled) hierarchy at 128³ = 16.58 GB EXCEEDS the machine's entire
   16 GiB — it still OOMs.** Unified memory removes the VRAM/host-copy split but not
   the 16 GiB ceiling of *this* mini. The premise's "it fits" is true only on a
   ≥32 GB Mac. **On this box, capacity is still binding for the fat variant.**
2. **For the LEAN variant the capacity NO-GO is fully reversed** — 0.72 GB (96³) /
   1.69 GB (128³) fit trivially. But note *what* reversed it: the Phase-1 lean
   rebuild (matrix-free fine + unsmoothed P) shrank the object 9.8×; **unified
   memory was not needed to fit this — being lean was.**
3. **Bandwidth is NOT the setup bottleneck.** One stream of the lean 128³ hierarchy
   (1.69 GB) at H1-sustained ~140 GB/s is **~12 ms**; a full build touches it a few
   times → **~60–120 ms** of streaming, negligible beside the geometric build
   already at ~5 s / 66% of the solve. The premise's guess that "the limit becomes
   bandwidth" does not hold — bandwidth is comfortably sufficient. What remains is
   **CPU FP64 sparse assembly + the coarse LDLT factorisation** (the other half of
   the premise's list).
4. **So the true binding constraint for the lean variant is iteration economics and
   the regime split, not memory.** Phase 1 measured that on real optimizer output
   (the ultra-dilute active-domain box) **geometric MG does not stagnate and lean
   AMG is 2.2× SLOWER**; AMG wins only where geometric has already failed, and even
   then pays 1.8–2.7× cycles for the Chebyshev-for-Gauss-Seidel substitution a
   matrix-free fine level forces.

**Bottom line:** unified memory + the lean rebuild make the AMG hierarchy
*runnable* on this box (≤1.7 GB at 128³) — a real change from "20 GB unrunnable."
But it is **not** a blanket solver replacement: the fat variant still OOMs at 128³
on 16 GiB, and the lean variant is a **targeted tool for the stagnation regime**,
sitting behind the cheaper, regime-independent win 113 already named (§B: reuse the
hierarchy across K MMA iterations — a stale preconditioner — for ~2–2.5×, which
helps the geometric path too). Measured bandwidth is not what stops AMG.

---

## What this run says the cheapest wins are (ordered, all zero-Metal)

1. **P-core pin — already shipped** (132). 6 threads beat 8/10 on the matvec
   (H2: 54.5 > 45.8 GB/s). Confirmed again here.
2. **Flip mixed-precision ON in production** (113 §D; capability shipped in 092,
   never enabled). The FP32 lever a GPU would headline is a one-line CPU flip.
   H4's 6.9e-8 floor is exactly the "inner-preconditioner-only" regime 092 targets.
3. **Stale-preconditioner reuse** (113 §B): the ~66% build, rebuilt every MMA
   iteration, is the real solver cost — reuse it across K iterations for ~2–2.5×.
   Dwarfs both the Metal ~1.2× (H4) and any AMG-vs-geometric swap (H5).
4. **AMG only where geometric stagnates** (H5): a targeted preconditioner for the
   developed-field regime, now capacity-feasible in its lean form, but never the
   default.

## Bars, checked

- **B1** exact machine named (`machine.txt`): Mac mini M2 Pro, 6P+4E, 16 GiB, 200 GB/s peak.
- **B2** every throughput quoted against the 200 GB/s theoretical peak (and the 151 GB/s STREAM ceiling).
- **B3** no production change, no new build dependency — `git diff` empty; Accelerate/Metal are system frameworks; nothing enters `libtopopt`.
- **B4** headlines are bandwidth / % of peak / footprint; wall-clock appears only as labelled corroboration.

## Reproduce

```
evidence/2026-07-28-apple-silicon-envelope/build.sh   # builds all 4 harnesses
```

Harnesses link the same core objects CMake compiles (`matfree/assembly/hex_element/
recycle`); `VoxelGrid::solid_count()` is defined in the harness (byte-identical to
`voxelize.cpp:30`) so no geometry deps are pulled. Raw output committed beside each:
`stream_out.txt`, `matvec_roofline_out.txt`, `accel_amx_out.txt`,
`metal_matvec_out.txt`, plus `machine.txt` and `amg_recost.md`.

## Limitations

- **Thermals** (the fanless-adjacent mini, 113's caveat): absolute s/matvec carries
  a ±~30% band under sustained load; the H2/H4 tables are best-of-N and the
  **ratios** (6 vs 10 threads, FP32 vs FP64, GPU vs CPU) are the robust signal, not
  the absolute seconds — consistent with bar B4.
- H2/H4 use a **solid block** (uniform modulus), not a graded design-box field. The
  gather/scatter pattern and DOF counts match production scale; a graded field
  changes `factor` per element but not the memory-access structure the roofline
  measures.
- The `+RFO` bandwidth model can exceed 200 (the SLC absorbs some write-allocate);
  the **counted 3-array figure (151 GB/s)** is the conservative, quotable ceiling.
