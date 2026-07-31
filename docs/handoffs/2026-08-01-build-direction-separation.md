# Build direction becomes its own input, with a scored recommendation

**Date:** 2026-08-01
**Branch:** `claude/build-direction-separation-c01191` (from main after PR 269, `eca04d6`)
**Implements:** PR 266 (`2026-08-01-orientation-scoring-probe` — the finding and the
measurement this ships), PR 263 (`2026-07-31-lattice-strut-strength-report` — the
callable strut evaluator whose bar L8 made `build_dir` an explicit parameter for
exactly this), PR 259 (the measured strut law), PR 247 (the fixed-field sweep).
**Scope:** `core/` + job schema + `app/`. Fixtures, `materials.json`,
`ARCHITECTURE.md`, `DECISIONS.md` and ROADMAP checkboxes untouched. No assertion
weakened or deleted. The gate's verdict logic and tolerance are unchanged.
**Evidence:** `evidence/2026-08-01-build-direction-separation/`

---

## WHAT SHIPPED

**The build-plate normal is now its own input.** It was never one: three call
sites each wrote `build_dir = -gravity_direction` and the app had never asked the
second question at all. "Which way is down in service" and "which way is up on the
plate" are different questions, and on the V5 hook's own load case that conflation
lands on the worst of 26 orientations — at resolution 48 it turns a part that
passes its strength check into one that fails it.

Three things, in order of how load-bearing they are:

1. **One optional job key, `"build_direction"`.** Absent ⇒ today's behaviour to the
   byte. Present ⇒ used verbatim.
2. **One resolver, `resolve_build_direction`.** All three sites consume it. It is
   the only place in the codebase where a gravity direction may become a build
   direction, and a test reads the sources to keep it that way.
3. **A scorer that is a post-pass, and a recommendation that never moves a
   verdict.** Opt-in, ~1 ms, riding the certification solve that already ran.

**Every bar was met.** No BLOCKED-STOP path was taken.

| bar | result |
|---|---|
| **U1** absent key is byte-identical | **MET.** `report.json`, `fields.bin` and the mesh are raw-sha256 identical to an independent baseline build. **Even with the scorer ARMED** — the ranking is a separate document. |
| **U2** no site still infers | **MET.** All three consume the resolver; zero inline derivations remain; a source-reading test fails the build if one returns. |
| **U3** the cost, measured | **MET.** 0.5 ms at res 32, 1.5 ms at res 48 — PR 266 measured 0.5 / 1.6. As a % of the solve it is **0.90% / 0.63%**, higher than PR 266's 0.1-0.4% because *the solve got faster*, not the sweep slower. See below — this is the one number that needs its context stated. |
| **U4** PR 266's numbers reproduce | **MET, exactly.** 0.6968 → REJECTED vs 1.3285 → ACCEPTED; interlayer 0.6968 vs 6.3494 = **9.11x**; support **48 vs 0**; height **48 vs 8** layers. Reproduced through `analyze_fixed_design`'s production post-pass. |
| **U5** a recommendation never silently changes a verdict | **MET.** The scorer runs strictly after `accepted`/`margin_effective` are sealed and cannot write to them; asserted in the analysis itself, and tested on the case that matters — a REJECTED run whose recommendation would PASS stays REJECTED. |
| **U6** the app asks the second question | **MET.** Its own chip + panel, adjacent to gravity, showing both questions side by side, the ranking, the recommendation marked, and six criteria as six columns. |
| **U7** the criteria stay honest | **MET, in production.** S-c bit-identical over 26 candidates; S-d bit-identical over all six cube axes with cross factor exactly 0. Reported on the receipt AND asserted. |
| **U8** determinism + full ctest | **MET.** **90/90, 100% passed** (was 89; +1 is the new test), twice. |

---

## U4 — PR 266's TABLE, REPRODUCED THROUGH THE PRODUCTION PATH

The V5 hook at resolution 48 under its own load case, run through
`analyze_fixed_design` with the scorer armed — not through the probe's private
scoring loop. `evidence/u2_u4_u5_u7_test.txt`:

```
U4 -- PR 266 case C (hook @ res 48, load -y) through production
    build = -gravity (+y): gated 0.6968  interlayer 0.6968  support 48
    best candidate  (+z):  gated 1.3285  interlayer 6.3494  support 0
    interlayer ratio 9.11x (PR 266 measured 9.11x)
```

| | build = -gravity (+y) | best candidate (+z) | task's stated figure |
|---|---|---|---|
| gated worst-case margin | **0.6968** | **1.3285** | 0.6968 / 1.3285 ✓ |
| verdict at `margin_stop` 1.0 | **REJECTED** | ACCEPTED | ✓ |
| macro interlayer margin | 0.6968 | 6.3494 (**9.11x**) | 9.11x ✓ |
| support-requiring voxels | 48 | **0** | 48 / 0 ✓ |
| build height (layers) | 48 | 8 (**6.0x**) | 6.0x ✓ |

Every figure to the digit. The S-c and S-d values also reproduce the probe's case C
exactly (`0.46164486` and `0.28850357`), which is the sharper check: those come
from PR 263's evaluator through a completely different call path.

---

## U3 — THE COST, AND THE ONE NUMBER THAT NEEDS ITS CONTEXT STATED

`evidence/u2_u4_u5_u7_test.txt`, measured on this build:

```
res 32: solve 0.0545 s | sweep 0.0005 s (26 candidates, 0.019 ms each) | SWEEP IS 0.90% OF THE SOLVE
res 48: solve 0.2338 s | sweep 0.0015 s (26 candidates, 0.056 ms each) | SWEEP IS 0.63% OF THE SOLVE
```

| | PR 266 | this build | reading |
|---|---|---|---|
| sweep, res 32 | 0.5 ms | **0.5 ms** | identical |
| sweep, res 48 | 1.6 ms | **1.5 ms** | identical |
| solve, res 32 | 0.33 s | **0.055 s** | **6.0x faster** |
| solve, res 48 | 0.40 s | **0.234 s** | 1.7x faster |
| sweep as % of solve | 0.1-0.4% | 0.63-0.90% | **the denominator moved** |

**Read the absolute column, not the percentage.** The sweep costs what PR 266
measured, to within a tenth of a millisecond — which is the actual test of "was
this reused or reimplemented", because a reimplemented criterion would show up as
milliseconds, not as a ratio. The percentage rose because the *solve* in this test
harness is 1.7-6x faster than the probe's (a different tolerance/solver config in a
release build), so the same numerator sits over a smaller denominator. Reporting
0.63-0.90% without that would be the misleading version.

The strut-axis measurement (the one-off generator tap for S-e) is timed separately
and rounds to **0.0000 s** at both resolutions.

The test also asserts what the percentage is a proxy for: **arming the scorer
leaves the certification bit-identical** (`margin_effective`, `accepted`,
`max_von_mises` and `max_interlayer_tension` all `==` between an armed and an
unarmed run of the same inputs). It is a post-pass, asserted, not asserted-by-comment.

---

## U5 — *** THE RECOMMENDATION NEVER MOVES THE VERDICT ***

This is the bar the whole design is arranged around, so here is how it is held up
at four separate layers rather than by one check.

**1. Ordering, in the code.** The post-pass runs as the last statement of
`analyze_fixed_design`, after `out.accepted` and `out.margin_effective` were
computed from `build_dir` — the orientation actually used — and it writes only to
`out.build_orientation`. It structurally cannot reach the verdict.

**2. An assertion in the analysis itself.**

```cpp
assert(out.build_orientation.candidates[out.build_orientation.as_built_index]
               .would_be_accepted == out.accepted &&
       "U5: the reported verdict must be the as-built orientation's verdict");
```

**3. The counterfactual uses THE SAME gate expression.** Each candidate's
`margin_effective` comes from `gate_margin_effective(...)` — extracted verbatim out
of `analyze_fixed_design` so the real gate and the counterfactual are the same code
by construction, not by inspection. `analyze_fixed_design` now calls it too. That
is what makes "as recommended: ACCEPTED" a measured statement rather than a guess.

**4. Tested on the case that matters.** `test_build_direction` certifies the hook
at the orientation production used to infer (+y), which **fails**, and whose
recommendation (+z) **passes**:

```
U5 -- the verdict is computed from the orientation USED
    as built: REJECTED; as recommended: ACCEPTED  (verdict stands: REJECTED)
```

with the load-bearing negative asserted explicitly:

```cpp
CHECK(a.accepted == false &&
          r.candidates[r.recommended_index].would_be_accepted == true,
      "U5: *** a recommendation that ACCEPTS did not flip a REJECTED run ***");
```

The mirror case is asserted too: certifying the same part with `+z` **declared**
accepts it, the as-built row tracks the verdict in that direction as well, and
`max_von_mises` / `mass_grams` are `==` across the two orientations — the solve did
not move, only the post-solve reading of it.

**And the receipt says both.** When the two verdicts differ, `build_orientation.json`
carries the sentence pre-composed in core, so no front-end can phrase it differently
from the file on disk:

> `"statement": "as built: REJECTED; as recommended: ACCEPTED. THE VERDICT THAT STANDS IS THE AS-BUILT ONE. Re-run with this build_direction to certify the recommended orientation."`

**Nothing auto-applies.** There is no code path from `recommended_index` to any
option, any grid, any gate. The user re-runs, or does not.

---

## U1 — BYTE IDENTITY (the load-bearing bar)

`evidence/u1_byte_identity.txt`. An ordinary CLI run from this branch against an
**independent git worktree at `origin/main` (`eca04d6`)**, configured and built on
its own — nothing stashed, the working tree never touched. The changed build ran
**twice** so the timestamp files can be shown to be timestamp noise.

* `report.json`, `fields.bin`, `variant_060.stl` — **raw sha256 identical** across
  all three runs.
* `iterations.csv` and `run_info.json` carry wall-clock stamps and differ between
  **two runs of the same binary**; with `wall_ms` / `created_wall_ms` stripped all
  three hash identically.

**And with the scorer ARMED, those three files still do not move.** That is why the
ranking is a separate document (`build_orientation.json`) instead of a block inside
`report.json`: a job that asks for a recommendation still produces the identical
certification artifacts, so arming the scorer can never be confused with changing
the answer.

**The key is live, and provably so.** Declaring `"build_direction": [0,0,1]` on the
same job changes `report.json` (a different orientation is a different interlayer
margin: 58655.75 → 258693.70) while `variant_060.stl` stays **bit-identical** — the
build direction is a post-solve input and the optimizer never saw it. Both halves
matter: the first proves the key reaches the gate, the second proves it does not
leak into the design.

---

## U2 — NO SITE STILL INFERS

`evidence/u2_no_site_infers.txt`.

| site | path it governs | now |
|---|---|---|
| `src/simp/minimize_plastic.cpp:274` | the optimize path (certifies every rung) | `resolve_build_direction(options)` |
| `src/cli/run_job.cpp:713` | the lattice certification context | `resolve_build_direction(options)` |
| `src/cli/run_job.cpp:1525` | the analyze / re-certify path | `resolve_build_direction(options)` |

`grep -rn -- "-options.gravity_direction" core/src/ core/include/` returns **nothing**.
The fallback exists in exactly one function, `production.cpp`.

`test_build_direction` asserts this **structurally**, by reading the production
sources and failing if the inline derivation reappears or if `run_job.cpp` stops
resolving at both of its sites. A source-reading test is unusual; it is warranted
here because the failure mode PR 266 named is not "one site is wrong" but "three
sites drift apart while each stays self-consistent", and that is invisible to any
behavioural test that only exercises one path.

**The app carried the same conflation** and it is gone too:
`ProjectModel.loadCase()` had `let up = force.gravity.map { -$0 } ?? ...` as the
build direction. It now returns a separate `plateDirection`, zero unless declared.

---

## U7 — THE CRITERIA STAY HONEST, IN PRODUCTION

PR 266's S2 self-checks now run on the production path and are **reported on the
receipt**, not only asserted in a test — so a drift is visible on a real run:

```
U7 -- PR 266's self-checks fire on the PRODUCTION path
    S-c in-plane 0.46164486, 0 deviations over 26 candidates
    S-d cube axes 0.28850357, 0 deviations over 6 axes
```

Both are `!=` comparisons on doubles — bit-identical, not "within tolerance". The
test checks them twice: once via the report's summary flags, and once by walking
the rows itself, so a summary that silently stopped being computed cannot pass.
`cube_axes_scored == 6` is asserted so the cube-axis check cannot pass vacuously.

The UI surfaces these too: if either fails, the panel replaces the strut columns
with "Consistency check failed — these lattice columns are not trustworthy."

---

## HOW THE SCORER IS BUILT (and what was deliberately NOT built)

**Every criterion is the production evaluator.** Nothing was reimplemented:

| | criterion | comes from |
|---|---|---|
| S-a | support proxy | `support_overhang_voxels` (orient.cpp) |
| S-b | macro interlayer + the gate's own number | `max_interlayer_tension` + `compute_stress_margin` + `gate_margin_effective` |
| S-c | strut in-plane margin | `evaluate_strut_strength` (PR 263) |
| S-d | strut interlayer margin | `evaluate_strut_strength` (PR 263) |
| S-e | horizontal strut population | the REAL generator, via `LatticeGenObserver` |
| S-f | printability | the V3 count already computed + build-frame metrics |

**The candidate set is mesh-free**, and that is a deliberate constraint, not an
omission: two of the three certification paths have no `TriangleMesh` in hand, so
requiring one would have reintroduced exactly the drift U2 exists to prevent — a
run's report and a later re-analysis recommending different orientations. The set
is the as-built direction plus PR 266's 26 sphere directions, derived inside
`analyze_fixed_design` so all three paths rank the same thing by construction.

**The recommendation is a maximin over the moving criteria, and there is no total
score.** PR 266's S3 measured that the criteria genuinely disagree (S-e wants a
`<110>` edge; everything else wants a cube axis) and that a weighted sum would
launder that away. The receipt and the UI publish the columns; `recommended_index`
sits *beside* them, never instead of them.

**Deliberately not built** (PR 266's own recommendations, followed):

* `score_orientations`' single collapsed number is **not** wired into anything.
* No off-axis search, no extended candidate set.
* No auto-apply, no "optimize the orientation".

---

## THE APP (U6)

A chip and a panel, deliberately adjacent to the gravity chip — the two are
side by side *because* they are the questions the app used to conflate.

* **Both questions, shown together.** "Down in service" (from the gravity arrow)
  and "Up on the plate", each with its own value and its own note. When the plate
  normal was not declared the note reads **"Assumed — the opposite of gravity. Not
  a choice you made."**, and the chip itself carries an `assumed` badge. A fallback
  the UI does not label is a fallback the user will mistake for a decision.
* **Six axis buttons + "Assume from gravity".** The recommended axis is outlined
  and marked `best`.
* **The ranking table: six columns, uncollapsed** — support, interlayer, strut
  in-plane, strut interlayer, flat-strut %, layers, and the gate verdict per row.
  The as-built row is highlighted and sealed; the recommended row is starred.
* **WHY it is recommended**, in words: which criteria dissent, computed from the
  rows (`dissentingCriteria`), plus the explicit line *"No single score is shown,
  deliberately — one number would hide that."*
* **The U5 banner.** When the recommendation would gate differently, both verdicts
  are stated in an amber block, with the core's own sentence beneath.

**One document, one decoder.** The receipt emitter lives in core
(`build_orientation_report_json`), so a LAN run's `build_orientation.json` file and
the on-device bridge's returned string are the *same bytes from the same code*, and
the app has exactly one parser for both. The ranking is DERIVED from
`run.outcome` — never stored independently — so it cannot describe a different run
from the results on screen.

---

## U8 — DETERMINISM AND TESTS

* **Full ctest: 90/90, 100% passed** (`evidence/u8_ctest.txt`), run twice with the
  same result. 89 before; the +1 is `build_direction`.
* **App suite: 1024 tests, 3 failures — all three pre-existing and unrelated.**
  They are the 3MF import tests, which need `lib3mf` provisioned in the checkout
  (`build_lib3mf_macos.sh`); this worktree has the 3MF-free macOS slice. **Verified
  by running them on the untouched baseline worktree at `eca04d6`, where they fail
  identically.** My change adds zero app-test failures. (I did try provisioning
  lib3mf to clear them; the macOS lib3mf link flags in `Package.swift` are set on
  the `TopOptKit` target and do not reach the test bundle, so the test binary fails
  to link. That is a real pre-existing `Package.swift` gap, out of scope here, and
  I reverted the provisioning rather than leave the worktree in a state that does
  not build.)
* **Determinism**: two runs of the changed binary produce identical `report.json`,
  `fields.bin` and mesh (the U1 new/new2 pair), and identical `iterations.csv` /
  `run_info.json` once wall-clock stamps are stripped.

---

## WHAT SHIPPED, file by file

| file | what |
|---|---|
| `core/include/topopt/build_orientation.hpp` | **NEW.** The six criteria, the report, the scorer + receipt emitter declarations. |
| `core/src/orient/build_orientation.cpp` | **NEW.** The scorer, the strut-axis instrument, the maximin rule, the receipt JSON. |
| `core/tests/validation/test_build_direction.cpp` | **NEW.** 56 checks: U2 (incl. the structural grep-assert), U3, U4, U5, U7. |
| `core/include/topopt/pipeline.hpp` | `MinimizePlasticOptions::{build_direction, build_orientation_report}`; `MinimizePlasticVariant::build_orientation`; the stale "orientation is the gravity direction" doc corrected. |
| `core/include/topopt/production.hpp`, `core/src/simp/production.cpp` | `resolve_build_direction` + `resolve_build_direction_is_inferred` — THE ONE derivation. |
| `core/include/topopt/analyze.hpp`, `core/src/simp/analyze.cpp` | `gate_margin_effective` extracted (the gate now calls it); the post-pass; two defaulted params. |
| `core/include/topopt/orient.hpp`, `core/src/orient/orient.cpp` | `build_orientation_candidates`; sphere sampling shared with `orientation_candidates`. |
| `core/include/topopt/job.hpp`, `core/src/cli/job.cpp` | `"build_direction"` + `"build_orientation_report"` in the allowed-key list. |
| `core/include/topopt/loadcase.hpp`, `core/src/cli/loadcase.cpp` | `ProductionLoadCase::{plate_dir, build_orientation_report}`. |
| `core/src/cli/run_job.cpp` | Three sites → the resolver; `apply_build_direction_options`; the receipt written on both entry points. |
| `core/src/simp/minimize_plastic.cpp` | The resolver; the per-rung ranking carried onto the variant. |
| `app/.../TopOptBridge.hpp`, `bridge.cpp` | `plate_dir_*`, `build_orientation_report`, `build_orientation_json`. |
| `app/.../BuildOrientation.swift` | **NEW.** The model, the app-side resolver, the receipt decoder, the dissent report. |
| `app/.../BuildOrientationView.swift` | **NEW.** The control, the ranking table, the U5 banner. |
| `app/.../BuildOrientationTests.swift` | **NEW.** 9 tests: U1 (no key ⇒ no key), U5 (the flipping receipt), U6. |
| `app/.../{ProjectModel,AppModel,RunModel,RemoteRunner,TopOptKit,WorkspacePlaceholder,WorkspaceChipLayout}.swift` | The plumbing and the chip. |
| `core/CMakeLists.txt` | +2 source lines, +1 test target. |
| `app/.../DesignOverhaulRound2Tests.swift` | Chip-order fixtures EXTENDED for the new chip (no assertion weakened — the tests still check the order, over one more chip). |

---

## RESIDUALS — what this does NOT establish

* **The slanted-face part is still untested.** The candidate set drops flat-face
  normals for the consistency reason above. PR 266 measured that they earned
  nothing on an axis-aligned extruded part whose flat faces ARE cube axes; a part
  with a large slanted face could put a genuine candidate outside the 26, and
  neither PR 266 nor this task tested one. If that part shows up, the fix is a
  mesh-aware candidate set threaded to **all three** sites at once — never to one.
* **The tripwire stands.** `hex8_stiffness_transverse` still has zero production
  callers. The day it is armed in the solve, the field starts depending on the
  build direction and this post-pass becomes 26 certifications instead of one. That
  arming is BLOCKED-STOP (`2026-07-29-layer-anisotropy-fea`: no measured TI
  constants for ASA/PETG). The economics here must be **re-derived, not inherited**,
  if it ever lifts. The header says so where someone would be about to break it.
* **`z_knockdown` is still unsourced** (0.55 assumed, PR 259's caveat). Every
  interlayer MARGIN divides by it. The ratios (9.11x) share the constant and
  survive a re-sourcing; the absolute REJECT/ACCEPT verdict at `margin_stop` 1.0
  does not.
* **The lattice posture in the test is synthetic** (a one-voxel erosion at uniform
  rho 0.30, and out of the cells-per-member regime PR 263's guard flags). S-c/S-d
  absolute values are illustrative; their *invariances* — which is what U7 pins —
  are not.
* **Print time is still not modelled.** Build height is a proxy; the real quantity
  needs a slicer.
* **The per-rung ranking is published only for the recommended rung.** Each rung
  scores its own design (correct — different designs have different overhangs), but
  the receipt carries the lightest accepted one, because that is the design the user
  exports. The others are on the variants in memory and unpublished.

---

## PLAIN LANGUAGE

Until now, the software never asked how you want the part to sit on the printer. It
just assumed: whatever direction you told it gravity pulls when the part is in use,
it would print the part the other way up. Those are two completely different
questions — "which way is down when I use it" and "which way is up when I print
it" — and the code treated them as one.

The previous piece of work measured what that costs, and it is not small. On the
test part, the orientation the software picks makes the part **seven to nine times
weaker** in the direction where 3D prints actually break (between the printed
layers), needs support material where the good orientation needs none, and takes
six times as many layers to print. At the finer resolution it is worse than
cosmetic: the part printed the way the software picks **fails its own strength
check**, and the same part printed the good way **passes**. Same part, same load,
same everything — just turned over.

So this change does three things.

**It makes the print orientation its own setting.** There is now a control in the
app that asks the second question directly, sitting right next to the gravity
control so you can see that they are two different things. If you do not answer it,
nothing changes at all — the software still assumes the old answer, exactly as
before — but it now **says** that it assumed, instead of quietly presenting a guess
as if it were your decision.

**It shows you how each orientation scores.** After a run you get a table: how much
support material each way up needs, how strong the part is between layers, how the
internal lattice struts fare, how many layers tall the print is. Six numbers, shown
as six numbers. I deliberately did **not** boil them down to a single score, because
they genuinely disagree with each other — one of them wants the part tilted while
all the others want it flat — and one combined number would hide exactly the
disagreement you need to see in order to choose.

**It never chooses for you, and this is the part I was most careful about.** The
software marks which orientation it thinks is best, and it stops there. If the
orientation you actually used fails the strength check while the recommended one
would pass, it says so in both directions, in plain words — "as built: REJECTED; as
recommended: ACCEPTED" — and the failing verdict stands until you re-run. It never
quietly re-scores your part against an orientation you did not pick. That failure
mode — where the number on the screen describes a different object than the file on
disk — is one this project has spent weeks stamping out, and I was not going to
reintroduce it through a helpful-looking suggestion. There is no code path from the
recommendation to the verdict at all, and there are tests whose whole job is to
fail if one ever appears.

Two things worth knowing about the cost. Finding the better orientation is
essentially free: turning the part over does not change the forces inside it, only
which way the print layers run, so one simulation answers the question for all 26
orientations. Scoring all of them takes about one and a half thousandths of a
second on a calculation that takes a quarter of a second — and I checked that
turning the scorer on leaves the strength calculation bit-for-bit unchanged, rather
than assuming it. And the whole feature is off unless asked for: I proved that an
ordinary run produces byte-for-byte identical output compared against a clean build
of the unchanged code, and that this stays true even when the scoring **is** turned
on, because the ranking is written to its own separate file.

One honest limitation. The lattice we use has internal struts that can never all be
printable, in **any** orientation — the previous work searched 400,000 of them to be
sure. That is a fact about the lattice shape, not about how you place the part, and
no amount of clever rotating fixes it. The scoring will tell you how bad it is; it
cannot make it good.

All 90 core tests pass, and the app's tests pass except three that were already
failing on this machine before I touched anything — they need a 3MF library that
this checkout does not have installed, and I confirmed they fail the same way on an
untouched copy of the code.
