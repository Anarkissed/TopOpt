# 091 — Galerkin block cache turned ON for production (the flip)

**Status:** DONE. The app's two production optimize entry points now enable the
matrix-free Galerkin block cache (handoff 090). The library default stays OFF, so
Gate-V2, the CLI and every core test are byte-identical to before.

**Track:** bridge (the flip). **Territory:** the sanctioned `TopOptBridge` only —
**no `/core/` change was needed** (see STEP 1). No `/app/` view code, no fixtures,
no benchmarks, no materials.json, no ARCHITECTURE.md, no ROADMAP box.

**Builds on:** 090 (the cache itself, opt-in default-OFF), 079 (flipped the two
bridge entry points to `MultigridCG_Matfree`), 074 (the precedent this mirrors:
flip at the bridge, leave the library default alone).

**Environment caveat, read this.** 090 ran on Apple M2 Pro arm64/NEON, so its
numbers (1.34× solve, 2.09× build, 0 differing DOFs of 2,286,387) are the
device-authoritative figures and are **unchanged by this flip** — the flip only
turns that measured path on. This worktree ran on **x86_64/GCC-13, Linux, 4 cores**
(no Apple hardware here), so:
- The **bit-identity proof below is architecture-independent** (0 differing DOFs is
  0 on any arch) and was re-run in full here — it stands on this box exactly as 090
  reported it on arm64.
- The **timings below are an x86_64 proxy** (as 085 used an x86/SSE2 proxy). They
  confirm the direction and the memory-neutrality; the RATIO that transfers to the
  iPad is 090's arm64 1.34×, not the proxy's number. No on-device run was performed.

---

## STEP 1 — THE SEAM DECISION (reported before flipping), and its justification

`fea_set_matfree_galerkin_block_cache(bool)` is a **GLOBAL toggle** — a
`std::atomic<bool> g_mf_galerkin_block_cache` in `core/src/fea/matfree.cpp:245`,
read once in `core/src/fea/multigrid.cpp:885` inside `build_mf_hierarchy`'s numeric
pass. Unlike `SolverKind`, it does **not** thread through `SimpOptions`. The three
placements the task named, judged against "keep Gate-V2's reference path provably
untouched":

**(i) Set the global at the two production bridge entry points — CHOSEN.**
Mirrors 074/079 exactly: one line added immediately after each
`opts.simp.solver = SolverKind::MultigridCG_Matfree`.
Why this keeps Gate-V2 provably untouched — the strongest form of the guarantee:
the setter is called **only from `bridge.cpp`**, which is **not compiled or linked
into any core test binary** (`test_gate_v2`, the CLI, the whole `core/tests` tree
link `libtopopt` but never the bridge). So in Gate-V2's process the setter
**physically never executes**, and `g_mf_galerkin_block_cache` stays at its `false`
default. The guarantee is "the flip code does not run there," not "it runs but
happens not to matter." That is provable by construction, not by measurement.

**(ii) Thread it through `SimpOptions` like `SolverKind` — REJECTED.** It would
touch `/core/` (`simp.hpp` field + plumbing through `simp_compliance` →
`fea_solve_mgcg_matfree` → `build_mf_hierarchy`) to carry a per-call bool that then
sets a global that **already exists**. More core surface, a second mechanism for one
state, and a per-call flag mapping onto a process-global atomic is awkward (and
thread-unsafe if two solves ran concurrently). No cleaner than (i); strictly more
invasive. Gate-V2 would still be untouched (its `SimpOptions` default = OFF), but at
a higher cost for no gain.

**(iii) Flip the library default to ON — REJECTED.** Simplest edit, but it turns the
cache on in **every** process — the CLI, all core tests, Gate-V2's process — so the
"locked reference" now runs a different code path and needs a byte-identical proof to
stay honest. Gate-V2 would in fact still match (it runs assembled JacobiCG, which
never calls `build_mf_hierarchy` — see below), but the posture is weaker: you are
now proving "on-by-default doesn't matter" instead of "the toggle never fires here."
The task explicitly asked to prefer the option that leaves Gate-V2's path provably
untouched; (iii) is the one that doesn't.

### STEP 1b — does anything in the app process depend on the cache being OFF?

**No.** Two facts:
1. **The only matrix-free callers in the whole app process are the two bridge entry
   points**, and both are being flipped ON. `grep` for `SolverKind::` across `app/`
   returns exactly `bridge.cpp:569` and `:744` (now `MultigridCG_Matfree`); nothing
   else in the process builds a matrix-free hierarchy. There is no third caller to
   leak into. The global stays set for the process lifetime, which is the desired
   state for **all** production runs (both the recommendation ladder and the fixed
   single-fraction preview go through the same `solver`).
2. **Even a hypothetical leak would be harmless**, because the cache is
   bit-identical. Nothing can depend on it being OFF *for correctness* — "OFF" and
   "ON" produce the same bits (proven below). The only reason to prefer confinement
   is cleanliness, which (i) already gives: the global lives in the app process and
   never reaches the library default that Gate-V2/CLI read.

**Why Gate-V2 (and the CLI, and every core test) is untouched regardless of
placement — the underlying fact:** the cache is read *only* inside
`build_mf_hierarchy`, which runs *only* on the `MultigridCG_Matfree` path. Gate-V2
(`core/tests/validation/test_gate_v2.cpp:481`) builds a `SimpOptions` with the
default `solver = SolverKind::JacobiCG` (`simp.hpp:380`) and never sets it, so it
solves via assembled Jacobi-CG and **never enters `build_mf_hierarchy`**. The cache
toggle is a no-op for it in any state. Placement (i) makes that a moot point anyway,
since the setter never runs in Gate-V2's process.

## STEP 2 — THE FLIP

`app/TopOptKit/Sources/TopOptBridge/bridge.cpp`, +28 lines, **`git diff` on
`core/` is empty**:

- `run_minimize_plastic` (`bridge.cpp:583`, STL / self-weight path) — added
  `topopt::fea_set_matfree_galerkin_block_cache(true);` after the solver line.
- `run_minimize_plastic_loadcase` (`bridge.cpp:772`, STEP / declared-load-case path,
  M7.6) — the identical line.

**Both** were flipped, for the same reason 074 flipped both: each is a genuine
production run, and flipping only one would silently leave an entire class of real
runs on the recompute path. `topopt/fea.hpp` (which declares the setter) is already
`#include`d by the bridge (line 23).

---

## STEP 3 — THE PROOF (bit-identical, stronger than 074's same-answer-within-tol)

All re-run in this worktree (x86_64, Eigen 3.4). Bit-identity is arch-independent.

### 3a. Gate-V2 GREEN and BYTE-IDENTICAL

Because the seam is placement (i), **Gate-V2's process never runs the setter**, so
its path is byte-identical by construction, not merely equal. Confirmed green with
the same reference values it always produced:

```
gate v2 validation (projected): all 72 checks passed
  final analysis compliance 7.482256 (ref 7.482098)   projected vf 0.30000000
  thresholded(0.5): 928 solid voxels (ref 928), 1 component, Mnd 0.015371
```

### 3b. Full 4-rung design-box ladder, cache ON vs OFF — BIT-IDENTICAL

A real 4-rung ladder (`{0.7, 0.6, 0.5, 0.4}`, `margin_stop=0` so all four run)
driven through `minimize_plastic` — the exact call the bridge makes — on the M7.dom
L-bracket expanded through `expand_design_domain`, `freeze_imported_part=false` (the
design-box production default, 080), `SolverKind::MultigridCG_Matfree`. Asserted per
rung: **exact** bit-identity (0 differing voxels, not `max|drho| ≤ 1e-6`), same OC
iteration count, same compliance bits (17 significant digits), same accept/reject:

```
per-solve (expanded 16x8x16, 7803 DOFs): differing=0 maxdiff=0.0e+00 iters 87==87 used_mg=1 levels=3
  rung 0 vf=0.70: diff_voxels=0 max|drho|=0.00e+00 iters 25==25 compliance 4.7592847214504811e-10==...  accepted 1==1 grown=29
  rung 1 vf=0.60: diff_voxels=0 max|drho|=0.00e+00 iters 25==25 compliance 7.2093924244185228e-10==...  accepted 1==1 grown=19
  rung 2 vf=0.50: diff_voxels=0 max|drho|=0.00e+00 iters 25==25 compliance 1.3690749259121664e-09==...  accepted 1==1 grown=8
  rung 3 vf=0.40: diff_voxels=0 max|drho|=0.00e+00 iters 25==25 compliance 6.8299453003243761e-09==...  accepted 1==1 grown=0
proof_ladder: 27 checks, 0 failures
```

Same rung count (4==4), same 25 iters every rung, same compliance to the last bit,
same accept decision every rung. The run **genuinely grows** into the near-void
Active region (29/19/8 voxels on the first three rungs), so the identity is not
vacuous — a scheme that skipped or froze the void would diverge here.
(Harness kept out of `/core/` per the territory rule — it lives in the scratchpad,
not the repo; it reproduces and tightens 090's committed `test_galerkin_cache`
growth guard from 1 rung / `≤1e-6` to 4 rungs / exact.)

### 3c. 078 parity — holds EXACTLY

```
matfree MG-CG graded soft-void 32^3: 18 iters (assembled MG 18), residual 5.340e-10, 3 levels
fea mgcg matfree: all 44 checks passed
```
18 == 18, unchanged. Since A1 is bit-identical the parity holds by construction.

### 3d. Existing galerkin_cache gate + full core suite — GREEN

```
galerkin_cache: solid 32^3 ON==OFF bit-for-bit (19 iters), soft-void ON==OFF (20==20),
                growth 140==140 grown voxels, max|drho|=0.00e+00 — 16 checks, 0 failures

100% tests passed, 0 tests failed out of 39   (Total 938 s)
```
(This Linux/Eigen-only config builds 39 tests; the 4 OCCT-gated tests — `cli_demo`,
`step_import` and siblings — are not built here and touch neither the bridge nor the
matrix-free path. 090's 43/43 was on a macOS build with OCCT.)

---

## STEP 4 — THE PRODUCTION NUMBER (x86_64 proxy; arm64 ratio is 090's 1.34×)

`fea_set_matfree_threads(4)`, quiet machine, one process per config (peak RSS
isolated via `getrusage`). Single matrix-free solve on a **96×80×96** soft-void
graded field (090's design-box regime, 4 multigrid levels engaged):

| config | per-solve wall | peak RSS | iters | mg levels |
|--------|---------------:|---------:|------:|----------:|
| cache OFF | **27.38 s** | **1.532 GB** | 24 | 4 |
| cache ON  | **17.34 s** | **1.532 GB** | 24 | 4 |
| ON vs OFF | **1.58×** | **unchanged (identical to the MB)** | same | same |

- **Peak memory is unchanged to the megabyte** (1.532 GB both), confirming 090's
  "memory unchanged" on a second architecture. This matters more than the speed: the
  cache adds 36 KB (8 colours × 24×24 doubles), nothing against the ~3 GB cap.
- **Why 1.58× here vs 090's 1.34×, honestly:** the ratio is field-dependent. The
  cache removes build work; the build's *share* of the solve is larger when there
  are fewer CG iterations to dilute it. This synthetic field converges in 24 iters,
  so the build dominates more and the ratio is higher. 090's *production* field
  (iteration-0 of the real optimize) takes 94 iters, where the build is a smaller
  share and the per-solve win is **1.34×**. That 1.34× is the number the maintainer
  should quote for the device; the proxy's 1.58× just confirms the win is real and
  grows as fields get easier.

### End-to-end: does the per-solve win survive the full ladder?

A real 4-rung `minimize_plastic` ladder (the exact bridge call), timed ON vs OFF,
threads(4). Two scales, because **the dilution is entirely a function of the build's
share of each rung, which grows with grid size**:

| ladder | grid | rungs | OFF wall | ON wall | ratio | peak RSS |
|--------|------|------:|---------:|--------:|------:|---------:|
| small-scale (measured here) | 32×8×32 (8,192 el) | 4 | 179.9 s | 174.1 s | **1.03×** | 0.027 GB, identical |

**Read this measurement honestly — it UNDERSTATES production, and here is exactly
why.** At 8,192 elements the hierarchy build is a few milliseconds, so the cache has
almost nothing to remove; the ladder wall is instead dominated by the **fixed
per-rung non-solve work** (stress/margin analysis, variant meshing, the V3 property
suite) plus the CG *iterate*, none of which the cache touches. So 1.03× is what the
cache buys **when the build is negligible** — the floor, not the production case.

At **production scale** the arithmetic inverts. On the 96×80×96 design box (090),
one FEA solve is ~12 s of which the hierarchy **build is 48%**, and a rung runs ~25
OC iterations each doing a full penalized solve — so a rung is ~25 solves ≈ hundreds
of seconds of solve-dominated wall, against which the single per-rung stress solve +
mesh/property work is small. The fixed overhead that dominated the 8K-element ladder
**becomes negligible**, and the ladder retains most of the per-solve win.

**The honest end-to-end delta the maintainer will feel:**
- **Per solve: 1.34× on device** (090, 94-iter production field), which is where the
  time is at production scale. Memory: **zero change** (measured 1.532 GB both ways
  at 96×80×96; the cache is 36 KB).
- **Full ladder: ~1.25–1.34× on device** — the per-solve 1.34× lightly diluted by
  the one stress solve + meshing/properties per rung, i.e. 090's ~80 min iPad ladder
  → **~60–65 min**. It is **NOT** the 1.58× the easy-field proxy showed, and **NOT**
  the 1.03× the tiny-grid ladder showed; both are off the production regime in
  opposite directions (proxy: fewer iters inflate the build share; tiny grid: no
  build to speed).
- It is a **time win only**. Peak memory is unchanged, so it does **not** bring 128³
  or Fine+box under the ~3 GB cap (090 §"Does this bring… into range? No"). The
  memory lever remains option (b), the void coarse-operator shrink.

---

## Files

- `app/TopOptKit/Sources/TopOptBridge/bridge.cpp` — the two-line flip (with the
  justifying comment) at `run_minimize_plastic` and `run_minimize_plastic_loadcase`.

`git diff --stat -- core/` is **empty** — no library default, header or source
changed. The library toggle stays default-OFF, so Gate-V2, the CLI and every core
test are byte-identical.

## THE ONE RULE — honoured

- **Library default unchanged (OFF).** The flip lives entirely in the app process at
  the bridge; `g_mf_galerkin_block_cache` still initialises `false`, and no `/core/`
  caller enables it. Gate-V2 and the locked reference run assembled JacobiCG,
  untouched.
- **Bit-identical, proven exact** — 0 differing DOFs, 4-rung ladder bit-for-bit,
  078 parity 18==18, full suite green.
- **No ROADMAP box checked.**
- **A bridge (`/app/`) file changed** → the app already links the current core
  framework; **`app/scripts/build_core.sh` is required before the app sees the flip
  compiled in** only if the core framework itself is rebuilt — here `/core/` is
  untouched, so the existing framework is current and the flip takes effect on the
  next Xcode app build of the bridge. (Stated per the task's build_core.sh note; no
  core rebuild was needed.)
