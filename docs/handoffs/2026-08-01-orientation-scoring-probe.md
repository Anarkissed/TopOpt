# Is build orientation worth choosing? — scoring probe

**Date:** 2026-08-01
**Branch:** `claude/orientation-scoring-probe-516f52` (from main after PR 265)
**Predecessors:** PR 263 (`2026-07-31-lattice-strut-strength-report` — the strut
evaluator this consumes), PR 259 (`2026-07-31-lattice-dehomogenization-probe` —
the measured law), PR 247 (`2026-07-29-layer-anisotropy-fea` — the fixed-field
build-direction sweep this generalizes), PR 201 (the octet print test).
**Scope:** core/ PROBE ONLY. No production change, no gate change, no arming, no
job-schema change. `run_job.cpp` untouched. Fixtures, `materials.json`,
`ARCHITECTURE.md`, `DECISIONS.md` untouched.
**Evidence:** `evidence/2026-08-01-orientation-scoring-probe/`

---

## VERDICT

**Cheap scoring holds — EXACTLY, not approximately. Orientation scoring is worth
building. But the lever is NOT a new optimizer: it is separating the build
direction from the gravity setting (three call sites, one optional job key), and
the "scorer" that pays for itself is a one-solve post-pass costing ~1 ms.**

Scoring all 26 candidates on all six criteria against a real solved field costs
**0.5 ms at res 32 and 1.6 ms at res 48 — 0.1% to 0.4% of the single
certification solve it rides on** (0.33 s and 0.40 s respectively). Every
criterion is a re-evaluation of one field; none needs a re-solve. Measured, not
argued: 15 full re-solves across 3 cases returned a **bit-identical** stress,
displacement and von Mises field, and every criterion agreed to the last bit.

The headline number is not the scorer, it is the conflation. Three separate call
sites set `build_dir = -gravity_direction` (`minimize_plastic.cpp:270`,
`run_job.cpp:648`, `run_job.cpp:1427`). On the V5 hook's own load case that
derives the **worst** orientation in the candidate set, and at resolution 48 it
turns a part that PASSES the gate into one that FAILS it:

| | build = -gravity (+y) | best candidate (+z) |
|---|---|---|
| gated worst-case margin (res 48) | **0.6968** | **1.3285** |
| verdict at `margin_stop` 1.0 | **REJECTED** | ACCEPTED |
| macro interlayer margin | 0.6968 | 6.3494 (**9.11x**) |
| support-requiring voxels | 48 | **0** |
| build height (layers) | 48 | 8 (**6.0x**) |

That is not a scoring nicety. That is the pipeline answering a different question
from the one the user asked.

---

## THE BAR, AND WHETHER IT WAS MET

The bar was written and committed **before any number was measured** —
`evidence/00_bar_declared_before_measuring.md`, unedited since.

| gate | bar | result |
|---|---|---|
| **G1** | a criterion that reaches the gate or the plate moves by **>= 1.5x** between the best candidate and the maintainer's hand-picked one | **MET.** Gated worst-case margin 1.87x (res 32) / **1.91x** (res 48); macro interlayer margin 6.95x / 9.11x; support 18 -> 0 and 48 -> 0 (unbounded); build height 5.33x / 6.0x. |
| **G2** | the criteria **do not all agree** — otherwise a scorer is ceremony | **MET, but narrowly and not where expected.** Exactly ONE criterion dissents: S-e (horizontal strut population) wants a `<110>` edge direction; S-a, S-b, S-d and both S-f terms all attain their optimum at a cube axis. Everything else that looked like disagreement was a TIE (below). |

**GO** — with the scope correction stated in "What is actually worth building".

### Predictions logged before measuring, scored honestly

| prediction | outcome |
|---|---|
| S-a swings large | HIT (0 to 150 support voxels) |
| S-b swings large (~6x, PR 247) | HIT (6.95x, 9.11x at res 48) |
| S-c exactly zero swing | HIT (bit-identical over 26 candidates x 3 cases, and over 257 sampled directions in the unit test) |
| S-d: six cube axes identical, off-axis strictly worse, NO off-axis improvement | HIT (18/18 cube-axis comparisons bit-identical; 60 of 60 off-axis candidates strictly worse, **0 improvements**, and 0 improvements over 257 further sampled directions in the unit test) |
| S-e: some candidate class beats the cube axes | HIT (`<110>` halves the horizontal population, 1/3 -> 1/6) |
| S-f min-feature exactly invariant | HIT (0 violations for every candidate; the V3 test is an isotropic 2x2x2 block test and structurally cannot move) |

Nothing was tuned after the fact.

---

## WHAT IS ACTUALLY WORTH BUILDING (the scope correction)

The bar passed, but the measurement points at a smaller and cheaper thing than
"an orientation scorer". Three findings narrow it:

1. **Every winner, in every case, on every criterion that matters, was one of the
   six cube axes.** The 26-direction candidate set — sphere sampling plus
   flat-face normals both ways up — earned nothing. A 6-direction check finds the
   same answer. (Caveat: this part's flat faces ARE the cube axes; a part with a
   large slanted face was not tested and could change this.)
2. **The strut criteria can only veto, never reward.** S-c does not move at all;
   S-d is identical across all six cube axes and strictly worse everywhere else.
   Between the candidates that actually win, both contribute exactly 1.00x. Their
   job in a scorer is to stop it choosing off-axis, not to help it choose.
3. **The existing `score_orientations` collapses everything into one number.**
   That is the wrong shape for what was measured: the gated worst-case margin
   *saturates* (12 of 26 candidates tie), S-e dissents from everything else, and
   S-c carries no information. A single weighted sum would hide all three.

So the recommendation is:

* **Do** separate `build_direction` from `gravity.direction` (S5) — that is where
  the 1.9x on the gated number and the res-48 reject/accept flip live. Optional
  key, defaulting to `-gravity`, so every existing job stays byte-identical.
* **Do** report the per-criterion scores for the six axes on the receipt. It costs
  0.5 ms on a solve that already ran, and it is what lets a user see *why* one way
  up beats another.
* **Do not** wire `score_orientations`' single collapsed number into the gate, and
  **do not** let a scorer pick an orientation silently. Nothing measured here
  justifies the software rotating a part without saying so.
* **Do not** extend the candidate set or add off-axis search on this evidence.

---

## S1 — THE CHEAP-SCORING CLAIM, TESTED

**Result: cheap scoring is EXACT for all six criteria. No criterion needs a
re-solve. Yes, this can be interactive.**

For each of 5 build directions x 3 cases, the probe scored the candidate the
cheap way (re-evaluate the one shared field) and the expensive way (re-run the
entire `analyze_fixed_design` certification with that build direction), then
compared. All 15:

```
case A (+0.000,+0.000,+1.000)  field BIT-IDENTICAL | S-a exact (0)  | S-b exact (4.0419304168)  | S-c exact (0.5196317840) | S-d exact (0.3249486551)
case A (+0.000,+1.000,+0.000)  field BIT-IDENTICAL | S-a exact (18) | S-b exact (28.1024517300) | S-c exact (0.5196317840) | S-d exact (0.3249486551)
case A (+0.707,+0.707,+0.000)  field BIT-IDENTICAL | S-a exact (24) | S-b exact (10.1955427311) | S-c exact (0.5196317840) | S-d exact (0.1961727878)
...
```

Full log: `evidence/probe_run.txt`, section S1. Not "within tolerance" —
`==` on `std::vector<double>`, and `==` on each scalar.

The cost, measured in the same run:

| case | one certification solve | all 26 candidates x 6 criteria | per candidate | sweep as % of the solve |
|---|---|---|---|---|
| A (res 32) | 0.3298 s | **0.0005 s** | 0.02 ms | **0.2%** |
| B (res 32) | 0.3883 s | **0.0005 s** | 0.02 ms | **0.1%** |
| C (res 48) | 0.4036 s | **0.0016 s** | 0.06 ms | **0.4%** |

The honest version of the interactivity question: the sweep is free; the SOLVE is
the cost, and the solve already happens on every certification. Scoring rides on
it for a rounding error.

### Why it is exact, and exactly what would break it

`build_dir` enters `analyze_fixed_design` **only after the solve**, at three call
sites and nowhere else (`src/simp/analyze.cpp:288, 315, 393`):
`max_interlayer_tension`, `support_overhang_voxels`, `evaluate_strut_strength`.
The element stiffness is `hex8_stiffness` (isotropic) or the lattice's
homogenized cubic tensor; **neither reads the build direction**. So the solved
field cannot depend on `n`, and one solve genuinely serves every candidate.

The layer-anisotropic element `hex8_stiffness_transverse` **exists in core and
has zero production callers** — verified, `evidence/01_call_graph.txt`. The day
that element is armed in the solve, this exactness dies and every criterion needs
its own solve: 26 candidates x one certification each. **That is the tripwire to
watch, and it is exactly the change `2026-07-29-layer-anisotropy-fea` recorded as
BLOCKED-STOP** (no measured TI constants for ASA/PETG). So the cheap path is safe
as long as that block stands — and the moment it lifts, this probe's economics
must be re-derived, not inherited.

**One honest limit on the claim.** Cheap scoring is exact for *scoring a fixed
design*. It says nothing about making orientation an *optimizer variable*: an
overhang-aware topology optimization would feed the support proxy back into the
design and would need a solve per orientation per iteration. That is a different,
far more expensive question and this probe does not answer it.

---

## S2 — THE SELF-CHECKS FIRE

Run on every case, not just the detailed one, and additionally pinned in CI by a
new unit test (`core/tests/unit/test_orient_invariants.cpp`, 320 checks).

| invariant | case A | case B | case C |
|---|---|---|---|
| S-c strut in-plane margin, max deviation over 26 candidates | **0** (0.51963178) | **0** (0.75424995) | **0** (0.46164486) |
| S-d, six cube axes | **EXACT** (0.32494866) | **EXACT** (0.47130131) | **EXACT** (0.28850357) |
| S-d off-axis improvements | **0** of 20 | **0** of 20 | **0** of 20 |
| S-d off-axis strictly worse | 20 of 20 | 20 of 20 | 20 of 20 |

The unit test extends this beyond the candidate set: over **257 deterministically
sampled sphere directions**, the strut in-plane margin, bound *and argmax voxel*
are bit-identical, every off-axis direction is strictly worse on interlayer, and
zero improve. The cross factor is exactly `0` on all six axes and exactly
`2/sqrt(3)` on the body diagonal.

**The correction the task warned about did not recur.** No off-axis
strut-interlayer improvement was measured anywhere, in any case, at any sample
density. The measurement agrees with PR 263's algebra: the cross term only adds.

### The S-e instrument, reconciled with PR 201

The octet strut population is measured from the **real generator** via
`LatticeGenObserver`, not transcribed. It reduces to exactly **six `<110>` face
diagonals carrying exactly 1/6 of the strut length each**, and the emitted
fragment count over an `n^3` block is exactly **24n^3 + 12n^2** (verified at
n = 1, 2, 3, 4, 6, 8) — 24 legs owned per cell plus 12 shared across each
boundary face. **24 + 12 = 36: PR 201's per-cell figure, reconciled.** A `+z`
build therefore leaves exactly 1/3 of strut length horizontal (PR 201's 12 of 36),
2/3 at exactly 45 degrees (24 of 36), and **zero vertical** — PR 201's finding,
reproduced from code rather than quoted.

---

## S3 — THE TRADE-OFF

Full 26-candidate x 12-column table: `evidence/probe_run.txt` (case A) and
`evidence/orientation_scores.csv` (all three cases, machine-readable).
Per-candidate strut-angle histograms: `evidence/strut_angle_histogram.csv`.

Case A, grouped by direction class. A class here is a symmetry class of the
LATTICE, not of the part or the load — so S-c, S-d and S-e are constant within a
class, while S-a, S-b and S-f are not and are given as ranges:

| class | n | S-a support | S-b il margin | S-b gated worst | S-c in-plane | S-d interlayer | S-d cross | S-e horiz % | S-f layers |
|---|---|---|---|---|---|---|---|---|---|
| cube axis (flat) | (0,0,±1) | **0** | **7.4840** | 2.0138 | 0.5196 | **0.3249** | 0.0000 | 0.333 | **6** |
| cube axis (upright) | (0,±1,0) | 18 / 42 | 1.0764 | 1.0764 | 0.5196 | **0.3249** | 0.0000 | 0.333 | 32 |
| cube axis (edge-on) | (±1,0,0) | 72 / 150 | 1.8200 | 1.8200 | 0.5196 | **0.3249** | 0.0000 | 0.333 | 19 |
| `<110>` edge | 6 dirs, e.g. (0,±.707,±.707) | 12-34 | 1.09-2.97 | 1.09-2.01 | 0.5196 | 0.1962 | 0.5774 | **0.167** | 18-33 |
| body diagonal | (±.577,±.577,±.577) | 79-83 | 1.48-3.33 | 1.48-2.01 | 0.5196 | **0.1405** | 1.1547 | **0.500** | 22-30 |

Read the S-d and S-e columns first, because they are the trade-off. Best to worst
on **S-d** (higher margin better): cube axis 0.3249, `<110>` 0.1962, body diagonal
0.1405. Best to worst on **S-e** (lower horizontal fraction better): `<110>`
0.167, cube axis 0.333, body diagonal 0.500. The two orderings **swap the top two
classes**, and neither is close. That opposition is a property of the octet
lattice, not of this part or this load, so it will show up on every latticed part.

### Best per criterion, and where they genuinely disagree

Ties are real here and must not be read as disagreement — `+z` and `-z` both rest
the hook flat, all six cube axes tie on S-d, all six `<110>` edges tie on S-e, and
the **gated worst-case margin saturates** at the direction-independent in-plane
term (`yield / max_vm`) once the interlayer term passes it, so 12 of 26 candidates
tie at 2.0138. The probe therefore reports whether the compromise **attains** each
optimum, with the tie count:

```
S-a support voxels         optimum (0,0,-1)      ( 2 tied) compromise ATTAINS it
S-b macro il margin        optimum (0,0,-1)      ( 2 tied) compromise ATTAINS it
S-b macro worst margin     optimum (-.577,...)   (12 tied) compromise ATTAINS it
S-c strut in-plane         optimum (any)         (26 tied) criterion does not move — no preference
S-d strut interlayer       optimum (0,0,-1)      ( 6 tied) compromise ATTAINS it
S-e horizontal strut %     optimum (0,-.707,-.707)(12 tied) compromise does NOT attain it  <-- DISAGREES
S-f build height           optimum (0,0,-1)      ( 2 tied) compromise ATTAINS it
S-f first-layer footprint  optimum (0,0,-1)      ( 2 tied) compromise ATTAINS it
```

**Best compromise: a cube axis, `(0,0,±1)`** (maximin over the four moving
criteria; worst standing 0.500, dragged down only by S-e). Identical in all three
cases.

**The one real disagreement, priced.** S-e asked whether an orientation that
eliminates the horizontal strut population might be worth more than the margin
terms. It is answerable exactly, so the probe answered it exhaustively rather
than settling for the 26 candidates:

* Over **400 000 directions covering the whole sphere**, the flattest octet strut
  family can be lifted to at most **18.40 degrees** above the plate, at
  `n ≈ (0.894, 0, 0.448)` = `(2,0,1)/sqrt(5)`. **No orientation reaches the
  45-degree FDM self-supporting limit — the octet always has struts that need
  support the lattice interior cannot give them.** That is a property of the
  topology, not of the part, and no scorer can fix it.
* That best-possible direction, priced on case A's own field:

| direction | S-a support | S-b il margin | S-d interlayer | S-d cross | S-e horiz % | S-e flattest |
|---|---|---|---|---|---|---|
| cube axis +z | **0** | **7.4840** | **0.3249** | 0.0000 | 0.333 | 0.00 deg |
| `<110>` edge | 13 | 1.9036 | 0.1962 | 0.5774 | 0.167 | 0.00 deg |
| body diagonal | 83 | 3.3278 | 0.1405 | 1.1547 | 0.500 | 0.00 deg |
| **(2,0,1)/sqrt(5)** | **181** | 2.0397 | 0.2129 | 0.4627 | **0.000** | **18.40 deg** |

  Buying the horizontal population away costs 181 support voxels (from zero), 73%
  of the macro interlayer margin, and 34% of the strut interlayer margin — and
  still leaves every strut family 26 degrees below self-supporting. **On this part
  it is not worth it.** S-e loses the argument, and it loses it quantitatively.

### Does the winner depend on the load or the grid?

| criterion | A (load -y, res 32) | B (load -z, res 32) | C (load -y, res 48) |
|---|---|---|---|
| S-a support | (0,0,-1) | (0,0,-1) | (0,0,-1) |
| S-b macro il margin | (0,0,-1) | (0,0,-1) | (0,0,-1) |
| S-d strut interlayer | (0,0,-1) | (0,0,-1) | (0,0,-1) |
| S-e horizontal strut % | (0,-.707,-.707) | (0,-.707,-.707) | (0,-.707,-.707) |

The winner is stable across a changed load direction and a 1.5x finer grid. What
is **not** stable is how much it wins by — see S5.

---

## S4 — IS IT WORTH BUILDING?

Best candidate vs (a) the maintainer's hand-picked orientation (`-gravity`, what
production derives) and (b) the worst candidate:

| criterion | case A best | vs -gravity | vs +z | vs worst |
|---|---|---|---|---|
| S-a support voxels | 0 | 18 (**unbounded**) | 0 (1.00x) | 150 (**unbounded**) |
| S-b macro il margin | 7.4840 | 1.0764 (**6.95x**) | 1.00x | 1.0764 (6.95x) |
| S-b **gated** worst margin | 2.0138 | 1.0764 (**1.87x**) | 1.00x | 1.0764 (1.87x) |
| S-c strut in-plane | 0.5196 | 1.00x | 1.00x | **1.00x** (invariant) |
| S-d strut interlayer | 0.3249 | **1.00x** | 1.00x | 0.1405 (2.31x) |
| S-e horizontal strut % | 0.167 | 0.333 (2.00x) | 2.00x | 0.500 (3.00x) |
| S-f build height | 6 | 32 (**5.33x**) | 1.00x | 33 (5.50x) |
| S-f first-layer footprint | 440 | 96 (4.58x) | 1.00x | 4 (110x) |
| S-f min-feature violations | 0 | 0 | 0 | **0** (cannot move) |

Case C (res 48) is the same story with a sharper edge: 9.11x on the interlayer
margin term and **1.91x on the gated number, across the accept threshold**.

**These are not "a few percent."** Two things deserve emphasis, though, because
they cut against a naive reading:

1. **S-d and S-c give the scorer nothing.** The maintainer's orientation is a cube
   axis, and every cube axis is optimal on S-d and every direction is optimal on
   S-c. A scorer that ranks cube axes against each other gains **exactly 1.00x**
   on both strut criteria. The strut margins only ever *punish* a scorer for
   choosing off-axis — they never reward it. If a future scorer is tempted to
   pick an off-axis winner for S-a or S-e reasons, S-d is the term that should
   veto it.
2. **The whole win is available from the six cube axes.** Every criterion's
   optimum in all three cases is a cube axis (S-e excepted, and S-e loses). The
   26-direction candidate set, the flat-face normals, the sphere sampling — none
   of it earned anything here. A 6-direction scorer would have found the same
   answer at a quarter the cost. That is a finding about *this* part class
   (axis-aligned extrusions with flat faces); a part with a genuinely slanted
   large face may differ, and this probe did not test one.

---

## S5 — THE GRAVITY/BUILD CONFLATION (reported, NOT fixed)

`src/cli/run_job.cpp:648`:

```cpp
cx.build_dir = normalized(Vec3{-options.gravity_direction.x,
                               -options.gravity_direction.y,
                               -options.gravity_direction.z});
```

"Which way is down in service" and "which way is up on the plate" are different
questions. Measured cost of conflating them:

| case | gravity | derived build | S-b il margin | best | penalty | S-a support | best |
|---|---|---|---|---|---|---|---|
| A | (0,-1,0) | (0,+1,0) | 1.0764 | 7.4840 | **6.95x** | 18 | 0 |
| B | (0,0,-1) | (0,0,+1) | 6.1227 | 6.1227 | 1.00x | 0 | 0 |
| C | (0,-1,0) | (0,+1,0) | 0.6968 | 6.3494 | **9.11x** | 48 | 0 |

Case B is the honest counterweight: when the service-down direction happens to be
the good build direction, the conflation costs **nothing**. It is not always
wrong — it is *unconditionally unexamined*, and on 2 of 3 cases here it lands on
the worst orientation in the set.

### What separating them would take (NOT done — no schema was changed)

1. **THREE call sites, in TWO files — not one.** The identical
   `normalized(-options.gravity_direction)` expression appears at:

   | site | path it governs |
   |---|---|
   | `src/simp/minimize_plastic.cpp:270` | **the main optimize path** — this is the one that certifies every rung and writes `vr.orientation` onto the variant report |
   | `src/cli/run_job.cpp:648` | the lattice certification context (`lattice_cert_context`) |
   | `src/cli/run_job.cpp:1427` | the analyze / re-certify path (`analyze_job`) |

   All three read `options.gravity_direction` independently. A separated build
   direction must reach **all three**, or a run's report, its lattice receipt and
   a later re-analysis of the same part will certify against different
   orientations — a silent inconsistency, since each path would look
   self-consistent. *(The task brief named `run_job.cpp:647` as the site; the
   assignment there begins at 648, and neither of the other two was mentioned.
   The main one is not in `run_job.cpp` at all.)*
2. **One optional job key.** A `"build_direction": [x,y,z]` alongside
   `"gravity"`, absent by default and falling back to `-gravity` exactly as today
   — so every existing job stays byte-identical. `MinimizePlasticOptions` gains
   one `Vec3`; `analyze_fixed_design` already takes `build_dir` as an explicit
   parameter and needs no change at all.
3. **A default that is not a lie.** Falling back to `-gravity` silently is what
   produced case C's rejected part. Either the fallback is reported on the
   receipt ("build direction assumed from gravity"), or it is not a fallback.
4. **The app side.** `gravity_direction` is already user-facing (the gravity
   direction widget). A second direction needs its own affordance or it will be
   set wrong; the existing widget's flat-face-normal snapping is the natural
   basis for it, since every winner here was a flat-face normal.
5. **Nothing in the gate changes.** `margin`, `margin_effective`, `accepted` keep
   their definitions exactly; only the direction fed to three post-solve metrics
   moves.

---

## S6 — DETERMINISM AND NO PRODUCTION CHANGE

* **Full ctest green: 89/89, 100% passed** (`evidence/02_ctest_full.txt`),
  including the new `orientation_invariants` test.
* **Byte identity** (`evidence/03_byte_identity.txt`): an ordinary CLI run built
  from this branch vs one built from an **independent git worktree at HEAD**
  (2ebf6f0) — nothing stashed, working tree never touched:
  * `report.json` and `variant_060.stl` — **raw sha256 identical**.
  * `iterations.csv` and `run_info.json` carry wall-clock stamps. Those differ
    between **two runs of the same binary**, so the probe ran the changed build
    twice to prove it is timestamp noise; with `wall_ms` / `created_wall_ms`
    stripped, all three runs hash to `b754763c...` — every physics column
    identical to the byte.
* **No production source changed.** `git diff --stat HEAD -- core/src/
  core/include/` is empty. The only tracked edit is +13 lines of CMake adding a
  test target and its `add_test`. `run_job.cpp` was not touched.

---

## What shipped

| file | what it is |
|---|---|
| `core/tests/harness/orientation_scoring_probe.cpp` | The probe. Standalone, NOT in CTest, not wired into anything. Three cases, six criteria, the S1 cheap-vs-expensive comparison, the S2 invariants, the exhaustive sphere search, CSV sink. |
| `core/tests/unit/test_orient_invariants.cpp` | **New unit test, in CTest** (320 checks). Pins the invariants an orientation sweep rests on so a future law/traversal change breaks loudly. Gates nothing. |
| `core/CMakeLists.txt` | +13 lines: the test target and `add_test`. |

Nothing was armed. `orientation_candidates` and `score_orientations` are still
called only by the V5 gate; `run_job.cpp` still derives the build direction from
gravity.

---

## Corrections to the task brief (verified, `evidence/01_call_graph.txt`)

Three premises in the brief are not quite right, and each changes what a follow-up
should do:

1. **"The ONLY reference anywhere is the declaration in orient.hpp: NOTHING CALLS
   IT."** Not so. `tests/validation/test_v5.cpp:169,177,214` calls both
   `orientation_candidates` and `score_orientations` — the V5 acceptance gate is a
   live, passing consumer. The accurate statement is that **nothing in
   PRODUCTION** calls them.
2. **"Combining these into a score is M4.4" (still to do).** `score_orientations`
   is **already fully implemented** (`src/orient/orient.cpp:239-291`) with
   normalization, weights, the z-knockdown penalty and stable ranking. The comment
   at the top of `orient.cpp` saying M4.4 is future work is stale. A follow-up
   does not need to write a scorer — it needs to decide whether to *call* one, and
   whether that scorer's single collapsed number is the right shape (this probe
   says: report the criteria separately; the one collapsed number hides that S-d
   can only ever veto).
3. **`support_overhang_voxels` and `max_interlayer_tension` are in production**
   (`src/simp/analyze.cpp:288,315`), used on the one build direction the job
   supplies. Only the *sweep* is missing, not the metrics.

## Residuals and what this probe does NOT establish

* **One part.** Everything rests on the V5 hook — an axis-aligned extruded
  profile whose flat-face normals are already cube axes. The conclusion "the whole
  win is available from six directions" is a claim about that part class. A part
  with a large slanted face would add real off-axis candidates and was not tested.
* **The lattice posture is synthetic.** The octet region is a one-voxel erosion of
  the hook interior at uniform rho 0.30, not a graded design from the grading law.
  S-c/S-d absolute values are therefore illustrative; their *invariances* (which
  is what S2 pins) are not.
* **`z_knockdown` is still unsourced** (0.55 assumed, PR 259's caveat). Every
  interlayer MARGIN here divides by it; the MPa bounds do not. The 6.95x/9.11x
  interlayer ratios are ratios of margins that share the constant, so they survive
  a re-sourcing; the absolute accept/reject verdict in case C does not.
* **The cells-per-member regime.** The hook at res 32/48 with a 4 mm nominal cell
  is well below the 5-cell floor `lattice_cells_per_member_min` reports. The strut
  numbers are out of regime in exactly the way PR 263's guard flags — they are
  used here only for their direction-dependence, which is the part that is exact.
* **Print time was not modelled.** Build height is a proxy for it; the real
  quantity (layer count x per-layer time, plus support material) needs a slicer.

---

## PLAIN LANGUAGE

Right now the software never asks how the part should sit on the printer. It just
assumes: whatever direction you said gravity pulls in service, it prints the part
the other way up. Those are two completely different questions — "which way is
down when I use it" and "which way is up when I print it" — and the code treats
them as the same question.

I measured what that costs. On the test part, printing it the way the software
picks makes the part **seven to nine times weaker** in the direction where 3D
prints actually break (between layers), needs support material where the good
orientation needs none, and takes six times as many layers to print. At the finer
grid it is worse than cosmetic: the part the software would print **fails its own
strength check**, and the same part printed the good way **passes**. Same part,
same load, same everything — just rotated.

The good news is that finding the better orientation is nearly free. I expected
we might have to re-run the expensive physics simulation once per orientation —
26 simulations instead of 1. It turns out we do not. Rotating the part does not
change the forces inside it, only which way the print layers run, so one
simulation answers the question for all 26 orientations. I checked this rather
than assumed it: I ran the full simulation again for several orientations and got
back **byte-for-byte the same numbers**. Scoring all 26 takes about a second.

The trade-off is real but one-sided. Different criteria want different things,
and one of them — the angle of the internal lattice struts — does prefer a tilted
orientation. So I checked whether tilting is worth it. It is not: tilting to fix
the strut angles wrecks everything else (support material goes from zero to 181
voxels, strength drops by a third), and it still does not fix the underlying
problem. The lattice we use has struts that can never all be printable, in **any**
orientation — I searched 400,000 of them to be sure. That is a fact about the
lattice shape, not about how you place the part, and no amount of clever rotating
will fix it.

Two things a reader should not over-read. First, the software's guess is not
always wrong — on one of my three test cases it happened to pick the best
orientation, purely by luck of how that load pointed. Second, the fancy part of
the existing code (checking 26 directions including angled ones) earned nothing
here: on this part every good answer was one of the six simple face-down
orientations. A much simpler check would have found the same thing.

So my recommendation is narrow and cheap: **stop guessing the print orientation
from the gravity setting.** Let it be its own setting, defaulting to today's
behaviour so nothing existing changes, and show the user the handful of scores so
they can see why one way up beats another. That is a small change to two lines
and one optional setting — not a new optimizer.

I changed nothing in the product. No gate moved, no schema changed, no file the
optimizer runs was touched. I proved that: an ordinary run produces byte-for-byte
identical output compared against a clean build of the unchanged code, and all 89
tests pass. What I added is one measurement harness and one new test that will
fail loudly if someone later breaks the assumptions this measurement relies on.
