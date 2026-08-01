# Gate rejections explain what bound them, and what would fix it

**Slug:** `gate-diagnosis-recommendations`
**Evidence:** `evidence/2026-08-02-gate-diagnosis-recommendations/`
**Scope:** `core/` (diagnosis engine + report schema) + `app/` (presentation).
**Status:** SHIPPED. Core ctest 92/92. App suite green except the 3 pre-existing
lib3mf 3MF-import failures this worktree already had (the macOS slice is built
3MF-free — `build_core.sh` prints `lib3mf: (none)`).

---

## 1. The motivating run

Real maintainer run, fingerprint `9f6738726016`, WallMount bracket, TO only,
design box on, 1.5 h. `report.json`:

```
variants:          []                 <- EMPTY
rejected_variants: [ one entry ]
  max_stress_mpa         14.459       margin.in_plane    3.8038
  max_interlayer_tension 10.876       margin.interlayer  2.7814
                                      margin.worst_case  2.7814
  margin_effective       0.5759       margin_required    1.5
  infill_percent         35
```

The app said:

> The strongest variant's worst-case stress margin was **0.00×** — below the 1.5×
> safety minimum. Try a stronger material, a coarser resolution, or a lighter load.

**Two faults, both now closed.**

**(a) 0.00× was a max over an empty array.** `RemoteRunner.assembleFinalOutcome`
read only `report["variants"]` — the ACCEPTED array. `rejected_variants`, which
exists precisely so a rejection is reported rather than omitted, was never
opened. So an all-rejected run produced an empty variant list, `variants.last`
was nil, and the sheet printed a `?? 0`. The numbers it needed were in the array
it never read. (The on-device bridge path never had this bug — it pushes all of
`mp.evaluated`, accepted or not.)

**(b) The advice was canned, and here mostly wrong.** The part's own worst-case
margin is 2.7814 — **nearly 2× the 1.5 requirement**. A stronger material was not
needed. A coarser resolution is not a term in the stress gate at all (and for the
one failure it *is* relevant to, min-feature, the sign is backwards: the §7 V3
floor is "≥ 2 voxels", so a FINER grid clears it). What rejected the part was the
f^1.5 **infill knockdown** at 35% infill:

```
2.7814 × 0.35^1.5 = 2.7814 × 0.20706 = 0.5759
```

---

## 2. The computed figure

The infill the part needs, by algebraic inversion of the f^1.5 seed curve:

```
f ≥ (1.5 / 2.781353)^(2/3) = 0.662557   ->  66.26%
```

**And that number is not the answer.** Infill is an integer slicer percent, and
at 66% the real gate returns

```
2.781353 × 0.66^1.5 = 1.49116  <  1.5     REJECTED
2.781353 × 0.67^1.5 = 1.52535  >= 1.5     ACCEPTED
```

So the shipped recommendation is **67%**, and it is 67% *because the gate was
asked*, not because the algebra said 66.26. An inversion-only implementation that
floors or rounds emits a setting that fails — the exact failure mode bar X3 is
about. `test_gate_diagnosis` asserts both halves: that 66% does not clear the
gate, and that the emitted value is ≥ 67.

---

## 3. What was built

### 3.1 `GateDiagnosis` — a structured object, not a prose string

`core/include/topopt/gate_diagnosis.hpp` (value types, dependency-free) and
`core/include/topopt/gate_diagnosis_eval.hpp` (the evaluator). Split in two
because `VariantReport` carries a diagnosis and the evaluator needs
`KnockdownSpec` from `analyze.hpp`, which includes `report.hpp` — one header
would be a cycle.

It carries:

* **which term BINDS** — `load_path` / `knockdown` / `interlayer` / `in_plane` /
  `min_feature` / `none`;
* **the binding value, the required value, and the ratio**, always in the sense
  "binding ≥ required means pass", whatever the term is;
* **BOTH margins** — `margin_worst_case_raw` (2.7814) and `margin_effective`
  (0.5759), plus both raw terms and the knockdown factor. They differ by 4.8× on
  this run and only one of them explains the refusal, so neither is ever the
  single number shown;
* `recommendations` — see §3.2;
* `levers` — one row **per lever**, including the ones that produced nothing,
  with `evaluable` / `candidates_tried` / `passed` / `reason`. "Tried and nothing
  passed" and "never tried" are different facts.

Emitted as `report.json`'s per-variant `"diagnosis"` object, **only when a
diagnosis actually ran**, so every pre-diagnosis document keeps its exact bytes.

### 3.2 Recommendations are verified counterfactuals

`price()` in `core/src/simp/gate_diagnosis.cpp` is the **only** path a number
takes to a recommendation, and it is a thin wrapper over `gate_margin_effective`
— the expression PR 271 lifted VERBATIM out of `analyze_fixed_design` for exactly
this purpose. There is no second margin arithmetic in the translation unit.

Algebra appears **once**, to pick a starting candidate for the infill search. The
candidate is then priced, and dropped if it does not pass.

The load-bearing consequence, measured in the test:

> "Try a stronger material" ranks by yield. `PA12_CF` has a **higher** yield than
> PLA (60 vs 55 MPa) and a much lower `z_knockdown` (0.40 vs 0.55). The gate's
> interlayer term is `(z_knockdown · yield) / tension`, so where that term binds
> PA12_CF is `24/tension` against PLA's `30.25/tension` — **measurably weaker
> than the material it would replace.** An inversion on yield recommends it. This
> module prices it and drops it.

### 3.3 The levers, least-invasive first

| lever | evaluable without a re-solve? | how |
|---|---|---|
| `infill_percent` | **yes** | infill never enters the solver (ARCHITECTURE §2), so the stress field is unchanged; reprice through `gate_margin_effective`. In the width-aware posture the in-plane term is a per-voxel max, so `analyze_fixed_design` now hands out the exact `(vm, member width)` pairs it maxed over and they are re-maxed through the same `width_aware_knockdown`. |
| `wall_loops` | **yes, and it reports itself INERT** in the default posture — `gate_margin_effective` never reads `wall_thickness_mm` on the scalar path. More walls make the part stronger in reality and cannot move this verdict by one bit, so nothing is recommended and the reason says so. |
| build orientation | **yes** — PR 271's scorer already priced every candidate with `gate_margin_effective`. The recommendation is the report's own **gate-constrained** pick (`auto_applied_index`), emitted only if that row's `would_be_accepted` is true. Never offered unless the interlayer term binds, because the build direction enters the gate through that term alone. |
| volume fraction | **partially** — rungs THIS RUN SOLVED carry their own measured verdicts and are used. A rung **heavier than the ladder's top is a different design**; pricing it needs a full re-solve, and that is reported, not guessed. |
| material | **conditionally** — for a force-driven linear elastic solve the modulus cancels exactly (`u ∝ 1/E`, `σ = D(E,ν)·B·u ∝ E·(1/E)`), so a swap that keeps Poisson's ratio leaves the stress field untouched and is exactly priceable. A **different ν is a different stress field**; such candidates are counted and reported as needing a re-solve, never recommended. A non-zero prescribed Dirichlet displacement breaks the cancellation entirely and disarms the lever (`poisson_locked`). `materials.json` is READ ONLY. |
| resolution | **only for min-feature**, and never for a stress-margin verdict. See §3.4. |
| lighter load | **yes** — stress is linear in the applied load, so a candidate scale prices exactly by scaling the two stress arguments. Offered LAST and framed as *changing the requirement, not fixing the part*. |

### 3.4 Resolution advice is routed, and honest about its criterion

Resolution is offered **iff the min-feature term binds** — i.e. the strength gate
passes and the §7 V3 min-feature count trips the rules threshold. It is the one
recommendation with `verified_through_gate = false`, because the quantity it
moves is the V3 count, not the stress margin, and it must not borrow the gate's
authority. It states its own criterion instead: the V3 rule "feature span ≥ 2
voxels" evaluated against **this design's measured thinnest printed member**
(`local_member_thickness_mm`), which needs no re-solve — plus the explicit
assumption that a finer run reproduces at least this geometry.

The thickness measurement (`O(cap · voxels)`) runs **only** when min-feature can
actually bind, so no run pays for it speculatively.

### 3.5 When nothing passes, it says so

`no_setting_fixes_this` + `no_fix_reason`, and the reason names the **binding
physical quantity**, not a list of things to try:

> no print setting fixes this: even at 100% infill the raw worst-case margin is
> 0.5042×, below the required 1.50×. The binding physical quantity is the peak
> tension across layer planes, 60.0000 MPa against a layer-bond allowable of
> 30.2500 MPa. The part has to carry less load, or be a different shape.

A severed load path short-circuits everything: no lever is tried, and the message
says the margins on that line are measurements of a structure that carries
nothing.

### 3.6 Provenance travels with the advice

`z_knockdown` is, per ARCHITECTURE.md §6, "seeded conservative and human-tuned",
and it is UNSOURCED for every material in the catalog. Any figure that divides by
it carries `inherits_unsourced_z_knockdown = true` **and** the sentence, per
recommendation and at diagnosis level. The app renders it as a trailing note. In
the motivating case the interlayer term is the governing one (2.7814 < 3.8038),
so the 67% figure inherits it and says so.

---

## 4. The app

* `RemoteRunner` now reads `rejected_variants` as well as `variants`. **This is
  fault (a).**
* `OptimizeVariant` carries `diagnosis: GateDiagnosis?`, decoded by ONE decoder
  from two sources: report.json's object (LAN) and the bridge's per-variant
  `diagnosis_json` string (on-device), both from the core's single emitter.
* `RunFailure.allRejectedOnMargin` now carries `worstMargin`, `effectiveMargin`,
  the violation count and the diagnosis — **two margins, not one**.
* The body copy is rebuilt from the core's own numbers. Nothing is re-derived
  app-side and no setting is suggested that the core did not price.

Before / after (`evidence/.../wallmount_dialog_before_after.txt`):

> **BEFORE** — The strongest variant's worst-case stress margin was 0.00× — below
> the 1.5× safety minimum, so it isn't strong enough to print. Try a stronger
> material, a coarser resolution, or a lighter load.

> **AFTER** — This design's own worst-case stress margin is 2.78×. What the gate
> compared is 0.58× — the same margin after the sparse-infill knockdown at 35%
> infill — and that is below the 1.5× minimum. The part itself is strong enough;
> the infill is what rejected it.
>
> What would fix it (each checked against the same gate that rejected this run):
> • Raise infill to 67% → 1.53× at the gate.
>
> Note: these figures divide by the material's layer-bond factor (z_knockdown), a
> conservative hand-tuned constant with no measured source for any material.
> Treat them as an ordering, not a calibration.

---

## 5. Arming

`MinimizePlasticOptions::gate_diagnosis` defaults to **false**, so the library,
Gate-V2 and every core reference run are byte-for-byte unchanged.
`configure_production_options` arms it — the same discipline as the solver,
min-feature and GenEO settings — so every production front-end (topopt-cli and
the on-device bridge) explains its own verdicts. Both front-ends also hand the
diagnosis their already-loaded `MaterialLibrary` (read-only); without it the
material lever reports itself NOT EVALUABLE rather than guessing.

---

## 6. Bars

**X1 — NO VERDICT MOVES.** Two ways.
*Numerically:* the same cantilever ladder is walked with the diagnosis OFF and
ON, and `accepted`, all three margin terms, `margin_effective`,
`margin_required`, `rejection_reason`, both stresses, both volume fractions and
the min-feature count are **bit-identical** on every rung, with the
accepted/rejected partition unchanged. The OFF document contains no `"diagnosis"`
key; the ON document does and still schema-validates.
*Structurally:* the diagnosis TUs contain no `const_cast` and **no assignment to
any `in.<field>`** (its inputs are where the gate's verdict lives);
`diagnose_gate` takes its inputs by const reference by declaration; and the
driver has exactly one call site, assigning exactly `vr.diagnosis`. A future edit
that starts writing a gate field fails here even on a fixture where the numbers
would not have moved. The whole 92-test ctest also passes unchanged, which is the
broadest verdict-stability check available.

**X2 — THE MOTIVATING CASE, REPRODUCED.** Asserted from the reported numbers, with
every gate quantity computed by the production functions rather than typed in:
`in_plane 3.8038`, `interlayer 2.7814`, `worst_case 2.7814`,
`margin_effective 0.5759`, binding term `knockdown`, binding value `0.35^1.5`
against the `1.5/2.7814 = 0.5393` it needed. **Neither margin is 0.00**, and the
test asserts their ratio is 4.83.
The recommendation is 67% infill. **Computed figure: exact inverse 66.2557%;
emitted 67%** (printed by the test).
*Verified, not inverted:* the test re-prices the emitted proposal itself through
`gate_margin_effective` and requires **bit equality** with the number the
diagnosis carried. **How it would fail against an inversion-only implementation:**
the algebraic inverse is 66.2557%, and 66% returns 1.49116 at the gate — below
1.5. An implementation that inverted and rounded/floored would emit 66, and the
test's `proposed_value >= 67.0` check fails; an implementation that inverted and
ceiled but never evaluated would pass this particular case by luck but fail X3(a),
where the inversion's answer is a material the gate rejects.

**X3 — NO UNVERIFIED RECOMMENDATION.** Constructed and asserted. Catalog: current
`CUR` (yield 55, z 0.55), `HIGH_YIELD` (yield **60**, z 0.40), `BETTER_Z`
(yield 55, z 0.75), `OTHER_NU` (passes, but ν 0.37 ≠ 0.33). Interlayer-bound case.
The naive inversion — "pick the higher yield" — selects `HIGH_YIELD`; the gate
returns 0.96 < 1.5. The test asserts `HIGH_YIELD` is **not** recommended, that
`BETTER_Z` **is** (so the lever is not merely dead), that `OTHER_NU` is not
(different ν = a different stress field = a re-solve), and that all three were
priced. The infill half of X3 is described under X2.

**X4 — IRRELEVANT-ADVICE REGRESSION.** A pure stress-margin rejection emits no
resolution recommendation, and the resolution lever is reported as not offered
with its reason. A min-feature binding (strength gate satisfied, 952 violations,
thinnest member 2.4 mm at 1.6 mm spacing = 1.5 voxels against the 2-voxel floor)
**does** recommend a resolution — 1.2 mm, i.e. **finer**, and the test asserts it
is finer than the current spacing, because the canned string had the sign wrong
too. No strength lever is offered for a reliability flag.

**X5 — ORIENTATION ADVICE COMES FROM THE SCORER.** On PR 266's rescue case (hook
fixture, res 48, load along −y, built at build = −gravity = +y, REJECTED), the
diagnosis's orientation recommendation is asserted to be the row at the ranking's
own `auto_applied_index` (the gate-constrained maximin), that row's
`would_be_accepted` is true, and the emitted margin equals that row's
`margin_effective` **bit for bit**. A control case with the interlayer term made
non-binding gets **no** orientation recommendation.

**X6 — ACCEPTED PARTS.** Cheap, so the machinery shipped: the same infill search
run downward. The motivating part at 80% infill is ACCEPTED with
`headroom_min_infill_percent = 67` — the same floor the rejection case landed on,
found by the same bisection — and the test confirms 66% really does fail. An
accepted part is told its headroom and given no advice. The number is emitted in
`report.json`, carried across the bridge, and decoded onto
`OptimizeVariant.diagnosis.headroomMinInfillPercent`.

*Partially skipped, deliberately, and reported here:* it is **not yet rendered on
the results screen**. Putting it there is a UI-design decision (which tab line,
what wording, how it sits with the existing margin/mass chips) rather than more
of this machinery, and it would have enlarged the task without adding a fact.
The data is in place for whoever does that pass; nothing further is needed from
core.

**X7 — DETERMINISM + ctest.** The same inputs emit a byte-identical diagnosis
document. **Core ctest: 92/92 passed** (including the new `gate_diagnosis`, test
#41, 229 checks). App: `RunModelTests` 51/51; whole package 1032 tests with the 3
pre-existing lib3mf 3MF-import failures (8 assertions) this worktree already had.

---

## 7. BLOCKED-STOP — what could NOT be priced through the real gate

Per the task's rule, these are reported rather than guessed at. **None of them is
emitted as a recommendation**; each appears in the diagnosis's `levers` array with
its reason.

1. **A volume-fraction rung heavier than the ladder's top.** It is a different
   design; pricing it is a full re-solve. Rungs the run *did* solve are used,
   because their verdicts are already the gate's.
2. **A material with a different Poisson's ratio.** The modulus cancels; ν does
   not. Such candidates are counted (`"N material(s) would clear the gate but
   carry a DIFFERENT Poisson ratio..."`) and never recommended.
3. **Any material swap when a Dirichlet BC prescribes a non-zero displacement.**
   The E-cancellation fails outright; the whole lever disarms.
4. **Infill and wall loops in the width-aware posture without the per-voxel
   pairs.** The in-plane term there is a per-voxel max. `analyze_fixed_design`
   now supplies the pairs so the production path *is* evaluable; a caller that
   arms width-aware and withholds them gets NOT EVALUABLE, not a number computed
   with the wrong (default-posture) law.
5. **Resolution, against the strength gate.** It cannot be priced there at all,
   which is why it is routed to the min-feature term and carries the V3
   criterion instead of the gate's.

The task's BLOCKED-STOP clause says to stop and report which levers cannot be
evaluated. Everything else in the task was delivered; this list is that report.

---

## 8. Files

**Core**
* `include/topopt/gate_diagnosis.hpp` — NEW. Value types + emitter declaration.
* `include/topopt/gate_diagnosis_eval.hpp` — NEW. Inputs + `diagnose_gate`.
* `src/simp/gate_diagnosis.cpp` — NEW. The evaluator (Eigen-gated with
  `analyze.cpp`, whose `gate_margin_effective` it calls).
* `src/settings/gate_diagnosis_report.cpp` — NEW. Names + JSON emitter
  (always-built, beside `report.cpp`).
* `include/topopt/report.hpp` — `VariantReport::diagnosis`.
* `src/settings/report.cpp` — emits `"diagnosis"` when evaluated.
* `include/topopt/analyze.hpp`, `src/simp/analyze.cpp` — `gate_printed_von_mises`
  / `gate_printed_member_width_mm`, filled only in the width-aware posture.
* `include/topopt/pipeline.hpp` — `gate_diagnosis`, `material_catalog`.
* `src/simp/minimize_plastic.cpp` — the post-pass, after the verdict is sealed.
* `src/simp/production.cpp` — arms it.
* `src/cli/run_job.cpp` — supplies the catalog (both modes).
* `tests/validation/test_gate_diagnosis.cpp` — NEW, 229 checks.

**App**
* `TopOptBridge/include/TopOptBridge.hpp`, `bridge.cpp` — per-variant
  `diagnosis_json`; the catalog for both entry points.
* `TopOptKit/TopOptKit.swift` — `GateDiagnosis` + decoder;
  `OptimizeVariant.diagnosis`.
* `TopOptFlows/RemoteRunner.swift` — reads `rejected_variants`; decodes the
  diagnosis.
* `TopOptFlows/RunModel.swift` — two margins; the rewritten body copy.
* `Tests/TopOptFlowsTests/RunModelTests.swift` — 4 new tests.

---

## 9. In plain language

When the app refused to print your bracket, it told you two things and both were
wrong.

It said the margin was **0.00** — as if the part had no strength at all. It
didn't. The part measured **2.78**, and the bar it had to clear was 1.5. It was
comfortably strong. The app printed 0.00 because it was looking in the wrong
place: the run's report has two lists, one for designs that passed and one for
designs that didn't, and the app only ever opened the first one. Everything was
in the second. With nothing in the list it was reading, it reported "the biggest
number I found", and it had found none.

Then it told you to try a stronger material, a coarser resolution, or a lighter
load. Only the last of those is even related to what went wrong, and it's the
option that means "decide the part doesn't have to hold as much" rather than
"make the part work". The real problem was the **infill** — how solid the inside
of the print is. You'd asked for 35%, and a part that's mostly hollow is a lot
weaker than the same shape printed solid. The software knows that and applies a
penalty for it, and that penalty is what pushed 2.78 down to 0.58 and under the
bar. The material was fine. The resolution had nothing to do with it.

So now it says what actually happened, and it tells you the fix: **print it at
67% infill**. And it doesn't just assert that — before showing you the number, it
runs the exact same strength check that rejected the part, at 67%, and confirms
it passes with 1.53. If a suggestion doesn't survive that check, you never see
it. That matters more than it sounds: the obvious version of "try a stronger
material" would have recommended a carbon-filled nylon here, because it has a
higher rated strength — and it would have made this part **worse**, because it
bonds less well between printed layers, and layer bonding is exactly what was
governing. The software now catches that by measuring instead of guessing.

If nothing works, it says that plainly rather than handing you a list. If the
part is broken in a way no setting fixes — no connected material between where
it's held and where it's loaded — it says that instead of quoting a strength
number that means nothing. And when a number depends on the layer-bonding factor,
which is a conservative estimate somebody typed in rather than something measured
in a lab, it tells you so, so you know how much weight to put on it.

One more thing, in the other direction: when a part **passes**, the same machinery
runs the other way and works out how much room you have — "passes at 80%, would
still pass at 67%" — so you can save material on purpose instead of by accident.
That number is computed and saved with the run, but it isn't shown on screen yet;
putting it somewhere sensible in the results view is a small design job that
belongs with the next round of UI work, not with this one.
