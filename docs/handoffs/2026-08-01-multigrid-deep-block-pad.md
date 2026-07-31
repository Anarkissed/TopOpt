# Deep-blocked all-even grids get the multigrid pad — PR 151 re-tested first

**Task slug:** multigrid-deep-block-pad
**Evidence:** `evidence/2026-08-01-multigrid-deep-block-pad/`
**Builds on:** PR #262 (multigrid-odd-axis-cliff) — branched from its head
(`b2b6370` = main + 262, since 262 had not merged when this task started);
this work assumes 262's parity-pad machinery.

## The residual 262 left

After 262, 23.7% of realistic grids still got NO multigrid: all-even but
deep-blocked (the walk-back regime — e.g. 30^3, 232x64x216). Those runs fall
back to Jacobi-CG + GenEO, which 262 measured at 2448.6 s vs 239.6 s on the
same workload. 262's scope guard said: "the solver engages the pad only when
a FINE axis is odd" — deliberately, because PR #151 had once measured forcing
these builds as harmful.

The task's observation held: `mg_pad_target` is already depth-aware (it
searches for the shallowest depth whose padded extents reach an accepted
hierarchy — 232x64x216 pads to 240x64x224 at depth 4, the very grid #151's
escalation produced). The fix is a scope change on the gate in
`mg_effective_extents`, not new machinery. But it was NOT quite as simple as
deleting the fine-odd condition — see the discovery below.

## P1 — PR #151's finding, re-tested FIRST

**The original finding (handoffs 122/127).** #151 escalated the design-box
pad to force the production res-128 job's grid from 232x64x216 (rejected) to
240x64x224 (coarsenable). MG then BUILT a hierarchy and STAGNATED on the
high-contrast thin-part + clearance field, falling back anyway — paying the
hierarchy build (~60% of a stagnating solve) plus the full then-100-cycle
budget on EVERY solve of a 19.4 h run. Forcing the build was measurably
harmful; the escalation was withdrawn. That measurement predates the 127
stagnation latch (skip the build after 3 consecutive stagnations) and the
128 budget raise (100 -> 300 cycles).

**The re-test** (`probes/deepblock_extents.cpp`, expectations stated before
running in `expectations.txt`): handoff 125's occ x hole factorial — the
reproduction of exactly the #151 stagnation regime — at #151's own extents
232x64x216, production entry point `fea_solve_mgcg_matfree`, tol 1e-6,
pad OFF (today) vs pad AUTO (the lifted gate), 4 threads
(`p1_deepblock_extents.txt`):

| case (232x64x216) | pad OFF (today) | pad AUTO (this change) |
|---|---|---|
| occ1.0 no hole | rejected; Jacobi 1416 it, 502.7 s | **5 levels, MG 30 cycles, 138.6 s (3.6x)** |
| occ1.0 hole0.4 | rejected; Jacobi 1516 it, 458.3 s | **5 levels, MG 66 cycles, 173.8 s (2.6x)** |
| occ0.7 hole0.4 | rejected; Jacobi 1320 it, 213.3 s | **5 levels, MG 118 cycles, 119.4 s (1.8x)** |
| occ0.5 hole0.4 | **builds TODAY**: 4 levels, MG 62 cycles, 44.1 s | identical (62 cycles, 44.2 s) — untouched |
| occ0.4 no hole | **builds TODAY**: 4 levels, MG 181 cycles, 65.0 s | identical — untouched |
| occ0.4 hole0.4 | **builds TODAY**: 4 levels, MG 193 cycles, 67.7 s | identical — untouched |

**Verdict: #151's finding does NOT reproduce under today's code, for two
reasons, one of which was a discovery:**

1. **The sparse rows — #151's actual regime — already build multigrid
   TODAY.** The builder accepts on ACTUAL active-DOF counts at the walk
   stop, not on the conservative full-node bound `mg_grid_coarsenable`
   uses; a thin part in a large Empty design-box expanse leaves few active
   DOFs on the coarse lattice, and 232x64x216 with occ <= 0.5 fits the
   6000-DOF cap at its depth-3 stop unpadded. (What #151's job actually
   lacked in its day was the budget: these rows need 62-193 cycles, over
   the old 100 budget on the hard end — the 128 budget-300 raise is what
   carries them now, exactly the "borderline band" 125 predicted it would
   rescue.)
2. **The rows the pad genuinely rescues (occ 0.7-1.0, dense active sets)
   are MG-friendly**: 30-118 cycles, 1.8-3.6x wall wins — dense fields are
   precisely where geometric MG works (125 §1b measured the same shape).

**The worst case FOR THE PAD — dense AND non-contracting** (a 1e-9
checkerboard on deep-blocked solid 60^3, which pads to 64^3 and stagnates —
the test_coarsen_rule (5) fixture regime at twice the size):

```
pad OFF reference:            Jacobi 740 it, 17.7 s   (no build attempted)
pad AUTO solve 1: hier=1 mg=0 cyc=300  49.7 s  latched=0
pad AUTO solve 2: hier=1 mg=0 cyc=300  47.5 s  latched=0
pad AUTO solve 3: hier=1 mg=0 cyc=300  50.4 s  latched=1
pad AUTO solve 4: hier=0 mg=0 cyc=0    12.4 s  latched=1   <- build skipped
pad AUTO solve 5: hier=0 mg=0 cyc=0    12.7 s  latched=1
```

The latch does exactly what 127 built it to do: the tax is 3 solves x ~32 s
(build + 300 wasted cycles each) ≈ +97 s per run, once, and every later
solve is the plain Jacobi path (identical 740 iterations; the 12-13 s vs
17.7 s difference is cache warmth across consecutive solves, not a code
path difference). On a production run of dozens-to-hundreds of solves this
is a few percent, against a 1.8-3.6x win everywhere MG carries. Under the
old regime #151 measured — no latch, the build paid on all 158 iterations —
the same field would have cost +5000 s. The latch is what changed the
calculus, exactly as 262 suspected.

## What shipped

`mg_effective_extents` (multigrid.cpp) — the pad's scope, was:

> pad only when a FINE axis is odd; all-even grids take the legacy path

now: **pad whenever the UNPADDED build would be rejected** —

- an odd fine axis (structural: no halving is ever possible) — 262's scope,
  unchanged;
- an all-even grid whose halving blocks deep **and whose ACTUAL active-DOF
  count at the unpadded walk stop exceeds the coarse-DOF cap** (new).

The second condition is the discovery above, made load-bearing: a
bound-rejected grid whose actual active set fits the cap at the stop depth
builds unpadded today, and the gate must leave it byte-identically alone.
`mg_unpadded_stop_active` (multigrid.cpp) computes the actual count — kept
fine DOFs whose node coordinates are all multiples of 2^d at the structural
stop depth d (`mg_unpadded_stop_depth`, coarsen.hpp), exactly the
coincident-node injection rule every hierarchy level applies, transitively.
Active counts are monotone non-increasing in depth, so `count <= cap`
predicts the unpadded builder's acceptance exactly (one corner: an active
set that vanishes on the coarse lattice reads 0 <= cap while the builder
rejects — the prediction then errs toward NOT padding, preserving today's
rejection; no behavior change). The scan is O(active DOFs), a few ms once
per hierarchy build, and only runs on the deep-block branch.

Both call sites pass the count: `build_mf_hierarchy` (production
matrix-free) and the assembled `solve_reduced_mgcg`.

NOT touched: the coarsening rule itself (all-axes-even + kMgCoarseDofCap +
kMgMinLevels — never relaxed; padded extents halve cleanly at every level),
kMgIterBudget=300, the stagnation latch, GenEO arming, fixtures,
materials.json, ARCHITECTURE.md, DECISIONS.md. No assertion was weakened:
legacy deep-block fallback assertions run verbatim under pad OFF (the
regime still exists — the latch routes there), with new AUTO assertions
beside them, the 262 pattern.

`mg_startup_banner` (coarsen.hpp) follows the solver: a deep-blocked grid
with the pad enabled now gets the NOTE (naming the block point and the
padded shape) instead of the WARNING; with the pad disabled the WARNING is
verbatim 262's. One honest caveat documented at the banner: it is geometric
and cannot see the void pattern, so on a sparse-active deep-blocked grid
the solver builds UNPADDED where the banner's NOTE names a pad — the
headline (multigrid engages) holds either way.

## P2 — correctness, 262's standard

262's bar was: bit-identical displacement bytes by memcmp on a force-padded
coarsenable control, and `max|drho| = 0.0` over every physical_density byte
on a full production run. Both are held, and both are extended to the new
scope (`p2_coarsen_rule.txt`):

1. **Solver level, memcmp** — test_mgcg_matfree 7c (262's, unchanged):
   FORCE-padding the coarsenable 32^3 control, solid and 1e-9-graded, gives
   bit-identical displacement bytes, iteration counts and level counts.
2. **Solver level, the NEW gate** — test_mgcg_matfree 7d(ii): a deep-blocked
   30^3 grid with a SPARSE active set (only a 30x15x15 sub-block solid)
   already builds unpadded; under pad AUTO the solve is **bit-identical**
   (memcmp) to pad OFF, with identical iteration and level counts. This is
   the invariant that keeps grids which build today untouched.
3. **Run level, the NEW scope** — test_coarsen_rule 4d: on the deep-blocked
   30^3 grid the default AUTO pad engages (index space 32^3); a FORCE pad
   grows it one further 2^L block. Full production `minimize_plastic`:
   identical variant count and **max|drho| = 0.000e+00** over every
   physical_density byte.
4. **Run level, 262's control** — test_coarsen_rule 4c (unchanged):
   FORCE-padded 32^3, **max|drho| = 0.000e+00**.

**One number stated plainly, because it is NOT zero.** Turning multigrid on
for a deep-blocked grid changes the *preconditioner*, and a different Krylov
path reaches the same solution by a different route. Over a 24-iteration MMA
run at 30^3, the pad-OFF (Jacobi) and pad-AUTO (multigrid) designs differ by
**max|drho| = 4.267e-06** (test_coarsen_rule 4e). That is a solver-tolerance
difference, not a physics change — the same order as the trajectory motion
110's warm start and 127's tolerance schedule already introduce — and it is
reported rather than bounded by an invented constant. The bit-identity
claims above are all made where the preconditioner is held FIXED, which is
where bit-identity is a meaningful claim.

## P3/P4 — the win on real deep-blocked grids (expectations stated first)

Expected numbers were written to `expectations.txt` BEFORE each run
(including a protocol amendment after P1: the 232x64x216 production repro
uses 3 MMA iterations, not 262's 5, because P1 measured the before-side
Jacobi at ~500 s/solve — 5 iterations adds hours without changing the
story).

**30^3, production config (matfree MG + GenEO armed), self-weight, vf 0.6,
5 MMA iterations = 10 solves** (`p3_repro_30_{before,after}.txt`):

| | before (pad off) | after (pad auto) |
|---|---|---|
| mg_mode | build-rejected, all 10 solves | carried, **3 levels**, all 10 solves |
| CG iterations/solve | 77-213 | **12-21** |
| total CG iterations | 1173 | **149** (7.9x cut) |
| geneo | never armed (run too short) | never armed |
| wall | 12.2 s | 7.2 s (1.7x — hierarchy build amortizes poorly on a 2 s solve) |

**232x64x216 (3.2M elements, 9.6M DOF), same config, 3 MMA iterations =
6 solves:**

TODO(p3big)

### What could NOT be measured here, stated plainly

The **before** column of the full production run at 232x64x216 was started
and **abandoned after 70 minutes without completing its first solve**
(`p3_repro_232_before.txt` holds only its header). That is not a tooling
failure — it is the cost being measured: at 9.6M DOF the unpadded run falls
back to Jacobi-CG, burns past GenEO's 500-iteration trigger, and begins a
GenEO basis build whose cost grows far faster than the grid (262's whole
10-solve run at 1.4M DOF took 41 minutes; this grid is 6.9x larger in DOF).
Extrapolating a wall number from a run that did not produce one would be
inventing evidence, so the before-side production counters at this grid are
**not reported**. What IS measured at these exact extents is P1: the same
production matrix-free solver, six coefficient fields, before and after,
under clean conditions — 1416-1516 unpadded Jacobi iterations per solve
(comfortably past GenEO's 500 trigger) against 30-118 padded MG cycles.

## P5 — the new residual

`probes/deepblock_sweep.cpp` re-runs 262's O8 sweep (12,100 grids at res
128: longest axis 128, shorter axes 15-100% aspect; same sweep at 64-192):

```
resolution 128 (12,100 grids):
  rejected before 262:  98.7%
  after 262 (odd-axis pad):  23.7%
  after THIS change:  0.00%  (0 grids rejected)
res  64: 95.2% -> 20.2% -> 0.00%
res  96: 97.8% -> 23.4% -> 0.00%
res 160: 99.1% -> 24.5% -> 0.00%
res 192: 99.4% -> 24.7% -> 0.00%
```

**No realistic grid shape is rejected any more.** `mg_pad_target` finds a
feasible depth for every grid in the sweep; the only shapes that can still
fail are those where no depth keeps >= 2 coarse elements per axis under the
DOF cap (degenerate needles/pancakes below the 15% aspect floor, e.g.
2x1x1). Note the sweep counts GEOMETRIC acceptance: a grid is "fixed"
when a hierarchy can build; whether MG then contracts on a given
coefficient field is the latch's department (P1).

## P6 — no regression on grids that already build

Stash-rebuild checksum (`probes/even_checksum.cpp`), FNV-1a hashes of raw
result bytes, baseline = this branch's parent `b2b6370` (262's head), built
and run in the same tree (`p6_checksum_old.txt` vs `p6_checksum_new.txt`):

| case | baseline (262) | after this change | |
|---|---|---|---|
| matrix-free MG, solid 32^3 | `fbfbd74b43de574b` | `fbfbd74b43de574b` | identical |
| matrix-free MG, graded 1e-9 32^3 | `449b14b614b781b2` | `449b14b614b781b2` | identical |
| assembled MG, solid 32^3 | `17dbdd35cb5376e8` | `17dbdd35cb5376e8` | identical |
| production run, 32^3 | `f41b3655cb69fe70` | `f41b3655cb69fe70` | identical |
| production run, **30^3 (deep-blocked)** | `e3f6653c038428cb`, used_mg=0 | `b344e0a79d144f9f`, used_mg=1, 3 levels | **changed by design** |

Every grid that already built multigrid is bit-identical, on both solver
paths and at the run level. The single changed row is the deep-blocked 30^3
— the entire point of the task — and its design agrees with the old one to
`max|drho| = 4.267e-06` (P2 above).

**A methodology note worth keeping.** The first attempt at this comparison
was WRONG and looked right: `git stash` was used to produce the "old"
library, but the solver changes had already been committed, so the stash
reverted only the uncommitted test edits and the "baseline" binary was the
new gate. Every row matched — including the 30^3 row that *must* change —
and that false pass is what exposed the error. The comparison here is
against `git checkout b2b6370 -- <solver sources>`, and the 30^3 row now
reads `used_mg=0`, matching 262's own recorded baseline. A checksum test
that cannot fail is not evidence.

## P7 — determinism + tests

TODO(p7)

## Files touched

- `core/include/topopt/coarsen.hpp` — `mg_unpadded_stop_depth` (new);
  widened scope doc; `mg_startup_banner` now emits the NOTE for a
  pad-rescued deep block (with the honest geometric-only caveat).
- `core/include/topopt/fea.hpp` — pad-mode doc updated to the new scope.
- `core/src/fea/multigrid.cpp` — `mg_unpadded_stop_active` (new);
  `mg_effective_extents` gains the actual-count argument and the deep-block
  branch; both call sites pass it.
- `core/tests/unit/test_mgcg_matfree.cpp` — block 7d: deep-block pad on a
  dense grid, and the actual-count gate's bit-identity on a sparse one.
- `core/tests/validation/test_coarsen_rule.cpp` — banner assertions for both
  pad states on 232x64x216; run-level 4a (deep-blocked engages), 4d
  (neutrality, max|drho| = 0), 4e (the Jacobi/MG flip, reported).
- `evidence/2026-08-01-multigrid-deep-block-pad/` — probes and raw output.

Deliberately untouched: fixtures, materials.json, ARCHITECTURE.md,
DECISIONS.md, the coarsening rule, the DOF cap, kMgIterBudget, the
stagnation latch, GenEO.

## BLOCKED-STOP assessment

- Grids that build today: untouched by construction (the actual-count gate)
  and by measurement (P1's occ<=0.5 rows identical; P6 checksums).
- Grids that do NOT build today: dense-active ones win 1.8-3.6x per solve
  (P1, P3); the dense-AND-non-contracting corner pays a bounded 3-solve
  latch tax (~+97 s once per run at 60^3-scale) and then runs at Jacobi
  parity. No shape got worse than today by more than that bounded,
  latch-terminated tax; this is a full lift, not a partial one.

## Plain language

The solver has a fast mode and a slow mode. The fast mode (multigrid) works
by repeatedly shrinking the problem — halving the voxel grid again and again
until it is small enough to solve outright — so it needs a grid that can be
halved several times over on all three axes. PR 262 fixed the obvious way to
fail that test: a grid with an odd number of voxels on some axis, like 31,
can't be halved even once. It taught the solver to *pretend* the grid is one
voxel bigger — 31 becomes 32 — purely in its own internal bookkeeping, with
the imagined slice containing nothing and affecting no result.

But there is a second, quieter way to fail the same test, and 262 left it
alone on purpose. A grid can be entirely even and still get stuck: 30 halves
to 15, and 15 is odd, so the shrinking stops after one step — far too early.
Roughly a quarter of realistic part shapes fail this way, and those runs were
still crawling on the slow mode. This change extends the same pretending
trick to them: 30 becomes 32, and now the grid shrinks five times instead of
one.

The reason 262 didn't just do this is that it had been tried once before, in
an old change (PR 151), and measured as *harmful* — forcing the fast mode on
these shapes made a real job slower, because the fast mode built all its
machinery and then failed to actually converge, on every single step, for
hours. So the first thing this task did was re-run that old experiment, and
the honest result is that it no longer holds, for two reasons. One is that
the solver has since gained a safety catch: if the fast mode fails to make
progress three times in a row, it stops trying for the rest of the run. That
turns an all-day tax into a few seconds, once. The other reason is a genuine
surprise: the specific shapes PR 151 was worried about — a thin part floating
in a big empty design box — turn out to *already* get the fast mode today,
because the solver's real acceptance test is stricter than the rule of thumb
we were reading. What PR 151's job actually lacked was patience, and a
different change (raising the iteration budget) supplied it later.

So the change is safe in the way that matters: every grid that gets the fast
mode today is left alone, byte for byte — verified by checksum against the
previous version. The grids that gain it run between 1.8 and 3.6 times
faster per solve on the large realistic case, and on a small test case the
total solver work dropped roughly eightfold. The proportion of realistic part
shapes shut out of the fast mode goes from about a quarter to zero.

One number is deliberately not zero, and it should be stated rather than
buried: switching a run from the slow mode to the fast mode changes the
answer by about four parts in a million. That is not the geometry moving —
it is the ordinary difference between two routes to the same solution, the
same size as differences the solver already accepts elsewhere. Where we
claim a result is identical to the last bit, we compare like with like: the
same mode, with and without the imagined padding. There it is exactly zero.
