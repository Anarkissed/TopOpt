# An odd grid axis silently disables multigrid — fixed and made loud

**Task slug:** multigrid-odd-axis-cliff
**Evidence:** `evidence/2026-07-31-multigrid-odd-axis-cliff/`

## The bug, from a real run

A 6-hour maintainer run recorded `cg_multigrid: false, mg_levels: 0,
mg_mode: "build-rejected"` with GenEO carrying 433 armed solves. The grid,
decoded from that run's own fields.bin header, was **128 x 31 x 118**.
`ny = 31` is odd; the coarsening loop (coarsen.hpp / multigrid.cpp) halves
only while every axis is even, so coarsening stopped before it started —
zero levels, hierarchy rejected, the entire run fell back to Jacobi-CG with
GenEO deflation carrying a load it was designed to share with multigrid, not
to carry alone. Discoverable only by reading run_info.json afterwards.

Grid parity is not physics. This run paid ~6 hours for a property of an
integer.

## What shipped

### (A) It is loud now — at run START

- `mg_coarsen_plan(ex,ey,ez)` (coarsen.hpp) — the same walk as
  `mg_grid_coarsenable`, but it reports the achievable level count, where
  halving stops, and **which axes are odd there**. A brute-force test pins
  its `accepted` bit to `mg_grid_coarsenable` over all of 1..40^3.
- `mg_startup_banner(...)` (coarsen.hpp) — pure decision + text:
  - grid coarsenable → **silent** (0);
  - odd fine axis that the parity pad rescues → **NOTE** (1) naming the odd
    axes, the padded index-space shape, and the level count;
  - hierarchy will still be rejected → **WARNING** (2) naming the grid, the
    offending axes and the extents where halving stops, the achievable
    levels, and the concrete remedy shape.
- run_job.cpp prints the banner to stderr immediately after the solved grid
  is known, before the first solve (both `run` and loadcase jobs pass
  through this site). The existing post-run observed warning is untouched.

Verified end-to-end on the real l-bracket STEP fixture at resolution 47
(grid 47x32x47, two odd axes): the NOTE prints at run start and the run
records `mg_mode: "carried"`, 3 levels
(`evidence/.../cli_banner_l_bracket_res47.txt`).

Note the task's own example remedy "128x32x118" would NOT have worked — 118
allows only one halving, leaving the coarsest level far over the DOF cap.
The remedy the banner prints (128x32x120) is computed by `mg_pad_target`
and is guaranteed sufficient. A test asserts this distinction.

### (B) The cliff is gone — index-space parity padding

**Approach (stated before measuring).** The design grid, voxels, loads,
mass, volume fraction, printed fraction, min-feature counts, margins and
exports are **never touched**. There are no padded voxels anywhere. When
the fine grid has an odd element axis, both multigrid solvers
(`build_mf_hierarchy` for the production matrix-free path,
`solve_reduced_mgcg` for the assembled path) build the hierarchy on a
padded **index space**: each axis rounded up to a multiple of 2^L
(`mg_pad_target`), where L is the shallowest depth whose coarsest level
fits the existing `kMgCoarseDofCap` counting **real** nodes only. The
virtual high-side nodes are permanently inactive (-1 in the active map) —
the exact treatment fixed and void DOFs already get, so prolongation rows,
the Galerkin coarse operators, and every solve involve exactly the real
active DOFs. 128x31x118 pads to 128x32x120 and builds 4 levels.

The all-axes-even rule in coarsen.hpp is **not relaxed** — the padded
extents halve cleanly at every level; no odd axis is ever coarsened.

**Scope guard.** Padding engages **only when a fine axis is odd**. All-even
grids take the legacy code path with `(pex,pey,pez) == (fex,fey,fez)` —
byte-identical by construction and by measurement (below). In particular
the all-even deep-blocked regime (232x64x216 — the withdrawn PR #151
escalation, where forcing a build led to build-then-stagnate on the
high-contrast design-box field) keeps today's behavior exactly. That
regime's banner is an honest WARNING with the remedy shape, not a pad.

Test hooks (`fea_set_mg_parity_pad_mode`): 1 = AUTO (default), 0 = OFF
(legacy — the existing odd-grid fallback tests in test_mgcg,
test_mgcg_matfree and test_mixed_precision run under OFF with **every
original assertion verbatim**, since the fallback path still exists for
stagnation and the latch), 2 = FORCE (tests only: pad a coarsenable
control grid to prove neutrality).

## O4 — correctness first (all proofs pass)

There are no padded voxels, so "padded voxels must be void / carry no load
/ not appear in mass" holds vacuously; what must be proven is that the
padded *hierarchy* is the same preconditioner. Proven twice:

1. **Solver level** (test_mgcg_matfree 7c): FORCE-padding the fully
   coarsenable 32^3 control grid — solid AND 1e-9-contrast graded — gives
   **bit-identical** displacement bytes (memcmp), identical iteration
   counts, identical level counts.
2. **Run level** (test_coarsen_rule 4c): a full production-config
   minimize_plastic run on 32^3, FORCE-padded vs default: identical variant
   count and `max|drho| = 0.0` over every physical_density byte — so mass,
   vf, margins and min-feature counts (all downstream of those bytes) are
   identical.

Why bit-identity holds structurally: coarse-node enumeration is row-major
with high-side-only padding, so the active coarse DOF numbering is
unchanged; P's stencil drops inactive (virtual) coarse nodes exactly as it
already drops fixed/void ones; every successful hierarchy terminates on the
active-DOF cap break, which depends only on real active counts.

## O5 — the win, measured on 128x31x118

Expected (stated before running): 4 levels; MG-CG tens of iterations per
solve vs Jacobi hundreds-to-thousands; >10x total-CG cut; GenEO quiet.

Reproduction: production solver config (`configure_production_options`:
matrix-free MG + GenEO armed), self-weight, solid 128x31x118 block at the
run's own spacing 1.7053 mm, single rung vf 0.6, 5 MMA iterations/stage —
10 solves total, identical workload both sides
(`repro_before_pad_off_5iter.log` / `repro_after_pad_on_5iter.log`).

| | before (pad off) | after (pad on, the fix) |
|---|---|---|
| mg_mode | build-rejected (`hier_built=0`, all 10 solves) | carried, **4 levels**, all 10 solves |
| CG iterations/solve | 290-447 plain Jacobi, then 53-82 GenEO-deflated | 62-88 |
| total recorded CG iterations | 2201 | **670** |
| geneo armed_solves / basis_builds | **8 / 1** (dim 5376, coarse refreshes 6) | **0 / 0** |
| geneo basis memory | **221.9 MB** | 0 |
| wall | 2448.6 s (40.8 min) | **239.6 s (4.0 min)** |

**10.2x wall speedup** on the identical workload. The recorded-CG ratio
(3.3x) understates the true cost of the before column: the per-solve counts
there exclude each armed solve's ~500-iteration trigger burn and the
LOBPCG matvecs of the 5376-dim basis build — the wall clock captures them.
Against the stated expectations: 4 levels as predicted; MG-CG per-solve
62-88 (predicted 10-40 — right order, the graded self-weight field is a bit
harder); GenEO to zero as predicted.

## O6 — GenEO goes quiet

The before run reproduces the motivating run's exact signature — GenEO
arming inside the Jacobi fallback (8 armed solves, a 5376-dim basis, 221.9
MB) because multigrid never built. In the after run `geneo_armed_solves =
0`, `basis_builds = 0`, `basis_dim = 0`: multigrid carries every solve and
the fallback where GenEO lives is never reached. Multigrid is building AND
working on this grid — there is no deeper bug behind the cliff.

## O7 — no regression on already-even grids

Stash-rebuild checksum (`checksum_old.txt` == `checksum_new.txt`,
bit-identical FNV hashes of raw result bytes):

- matrix-free MG on even 32^3, solid and graded — identical;
- assembled MG on even 32^3 — identical;
- production minimize_plastic on even 32^3 (MG carried, 3 levels) —
  identical design bytes;
- production minimize_plastic on even 30^3 (the even deep-blocked
  fallback regime) — identical design bytes, still `used_multigrid=0`.

## O8 — what parity costs in general (systemic, not one unlucky part)

The CLI voxelizer gives the longest axis exactly `resolution` voxels; the
two shorter axes land on whatever integers the part's aspect ratio
produces. Sweeping all shorter-axis pairs from 15% to 100% of the longest
at resolution 128 (12,100 grids — every realistic aspect ratio lands on
one of them):

- **98.7% of grids are rejected today.** Only 152/12,100 coarsen.
- 75.0% of all grids fail on a fine odd axis — **all** of these are fixed
  by the parity pad.
- 23.7% are all-even but deep-blocked (the walk-back regime) — unchanged
  by this PR, by design.
- Rejection rate after the fix: **23.7%** (was 98.7%). Same shape at
  resolutions 64-192 (evidence: `parity_tax_sweep.txt`).

So the motivating run was not unlucky: multigrid was effectively OFF for
three out of four plain part runs, and this PR turns it on for all of
them. The remaining 23.7% (even-but-shallow grids like 30^3 and
232x64x216) is a follow-up decision, not an accident: forcing those builds
was measured harmful once (PR #151), but that measurement predates the
stagnation latch and the budget-300 raise, so re-testing it is now cheap
and bounded. Until then the banner names those grids loudly.

## O9 — determinism + tests

- Padded odd-grid solve (31x15x27, all axes odd, graded): bit-identical
  run-to-run and across 1/2/4/8 matvec threads
  (`determinism_probe.txt`).
- Full ctest: **85/85 green**. The first full run had 2 failures —
  test_matfree_cubic (blocks 4a/5-7) and test_designbox_padding both used
  ODD grids as their routing device into the Jacobi/GenEO/recycling
  regimes, which the parity pad now rescues. Both now pin pad mode OFF for
  exactly those blocks (the regimes they test still exist — stagnation and
  the latch still route there) and every original assertion runs verbatim.
- No assertion was weakened or deleted anywhere: legacy odd-grid fallback
  blocks in test_mgcg, test_mgcg_matfree, test_mixed_precision,
  test_matfree_cubic and test_designbox_padding run verbatim under pad
  mode OFF; new padded-behavior assertions were added beside them.

## App surfacing (reported, not wired)

The banner is one stderr line at run start. The app/worker do not currently
parse CLI stderr (no existing hook found), so wiring it is not trivial and
was not done. Two candidate hooks for a follow-up: (1) parse the
`NOTE:`/`WARNING:` stderr line in the worker's process wrapper; (2) add the
banner text as an up-front field in run_info.json (written before the run
starts) and let the app read it from there — the schema change ripples into
the app DTOs (see OutcomeStore memory), which is why it was left out here.

## Files touched

- `core/include/topopt/coarsen.hpp` — `MgCoarsenPlan`, `mg_coarsen_plan`,
  `mg_pad_target`, `mg_startup_banner`; parity-pad doc block.
- `core/include/topopt/fea.hpp` — `fea_set_mg_parity_pad_mode` /
  `fea_mg_parity_pad_mode` (thread-local, like the latch).
- `core/src/fea/multigrid.cpp` — `mg_effective_extents` (the engage rule);
  padded index space in `build_mf_hierarchy` and the assembled
  `solve_reduced_mgcg`; pad-mode state + setters.
- `core/src/cli/run_job.cpp` — run-start banner (one call site, both job
  modes).
- Tests: `test_coarsen_rule.cpp` (plan/pad/banner units, brute-force rule
  equivalence, run-level odd-grid engagement, run-level FORCE-pad
  bit-identity), `test_mgcg.cpp`, `test_mgcg_matfree.cpp` (padded-odd
  blocks + FORCE bit-identity; legacy blocks under pad OFF),
  `test_mixed_precision.cpp`, `test_matfree_cubic.cpp`,
  `test_designbox_padding.cpp` (legacy odd-grid blocks under pad OFF,
  assertions verbatim).

Deliberately untouched: fixtures, materials.json, ARCHITECTURE.md,
DECISIONS.md, the coarsening rule itself, the DOF cap, the stagnation
latch, the all-even deep-blocked behavior.

## Plain language

Your six-hour run was slow because of a coin flip. The solver's fast path
(multigrid) needs the voxel grid to be divisible by two, several times
over, on all three axes. Your part happened to be 31 voxels deep — an odd
number — so the fast path switched itself off before it started, silently,
and the run crawled on the slow path all day. Whether a part hits this
depends on nothing but how its dimensions round to whole voxels: three out
of four parts lose the fast path this way.

The fix: the solver now quietly imagines a slightly bigger grid — 31
becomes 32 — but only in its own internal bookkeeping. The imagined extra
slice contains nothing, weighs nothing, carries no load, and never appears
in any result, mass, or margin; we proved the answers are identical to the
last bit. On your exact grid the fast path now runs at full depth: the same
workload that took 41 minutes on the slow path finishes in 4, and the
emergency helper (GenEO) that was burning 222 MB propping up the slow path
goes back to doing nothing, which is its job when things are healthy. And
if a grid ever does fall off the fast path again, the run now says so out
loud the moment it starts — naming the axis that caused it and the grid
size that would fix it — instead of leaving the evidence buried in a JSON
file after the money is spent.
