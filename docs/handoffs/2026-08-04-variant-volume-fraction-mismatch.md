# The app sends the wrong volume fraction, and the lattice comes out empty

Slug: `variant-volume-fraction-mismatch` ·
Evidence: `evidence/2026-08-04-variant-volume-fraction-mismatch/`

---

## 0. THE HEADLINE

**The maintainer now has a latticed part.** `evidence/.../wallmount_xsec_zoom.png`
is a cross-section of his own WallMount bracket with octet struts visibly in it:
371 lattice cells, 2 791 clipped struts, 3 112 landings, **strut radius 0.80 mm**
(diameter 1.60 mm), 9 851 latticed voxels of a 49 909-voxel region (**19.7 %
latticed**), certified and **accepted** at margin 3.392 effective against a
required 1.50. The file is 17.6 MB of real geometry. §5 has the whole receipt and
the caveat that comes with it.

Getting there needed **four** separate blockers cleared, only one of which the
brief named. Every one is reproduced below from his own worker directories.

Two of the brief's premises turned out to be **wrong**, and the corrections
changed the fix:

* **A1's premise — "the app is attaching a volume fraction that belongs to
  something else" — is REFUTED.** `1.1` belongs to exactly that variant: it is
  its ladder rung, and the design container it was sent with holds
  `requested_volume_fraction = 1.1` for it. The defect is not a stale or foreign
  number; it is that a **ladder POSITION was travelling in a job key that core
  validates as a FRACTION**. §1.
* **A3 as written is unsatisfiable, and the data says so.** It asks that
  `variant.volume_fraction` equal the variant's `achieved_vf` while A2 forbids
  widening `(0, 1]`. On a growth ladder the achieved fraction is part-relative
  and **exceeds 1** — MEASURED at `1.0866043075327818` for his 1.10 rung. Its
  intent is met in full and enforced at runtime; the letter is not, and §1.4 says
  exactly why.

Also refuted, from the same evidence: the maintainer's "**REDUCTION variant at
-49 %**". The job that failed carried the **growth** run's `design.bin` and its
own growth job document — self-consistently. His −49 % variant is a different run
(`193b605fb69d4eee`, rung 0.52, achieved 0.5082). Nothing crossed over; §1.2
shows why a cross-run mix-up is structurally impossible on this path.

---

## 1. FAILURE A — WHERE `1.1` CAME FROM

### 1.1 The line

**`app/TopOptKit/Sources/TopOptFlows/WorkspacePlaceholder.swift:1919`** (as it
was):

```swift
return try? RelatticeJobBuilder.build(
    original: art.jobJSON,
    variantVolumeFraction: ctx.requestedVolumeFraction,   // <- the bug
    designFileName: "design.bin", lattice: spec)
```

`ctx.requestedVolumeFraction` is `LatticeVariantContext.requestedVolumeFraction`
— **the ladder rung**, set from `OptimizeVariant.requestedVolumeFraction`.
`RelatticeJobBuilder.build` wrote it into `variant.volume_fraction`
(`RelatticeRunner.swift:61`), and core validates that key as a fraction
(`core/src/cli/job.cpp:1114`):

```
"variant.volume_fraction" must be in (0, 1]
```

`minimize_plastic: false` makes core walk `production_growth_ladder()` =
**{1.55, 1.25, 1.10}** (`core/src/simp/production.cpp:793`). So the last rung's
only correct join key is `1.1`, and the schema rejected it in 48 ms. Three
attempts, identical (`18b5535710af4441`, `3ca987bd965e4321`, `0cc8e495de084e5d`).

**The bound was doing its job.** A number that describes a part's volume fraction
belongs in `(0, 1]`. What had no business being there was a ladder position.

### 1.2 Why the number was NOT foreign — and cannot be

Read straight out of `~/.topopt-worker/0cc8e495de084e5d/design.bin`:

| block | requested | achieved | fingerprint |
|---|---|---|---|
| 0 | 1.55 | 1.5376855112224839 | 14561760059330257218 |
| 1 | 1.25 | 1.2368710980536173 | 9817955135575584118 |
| 2 | **1.10** | **1.0866043075327818** | 2898949975693851963 |

The job asked for `1.1`; block 2 is `1.1`. The container, the retained job
document (`minimize_plastic: false`, `design_box` present) and the rung all come
from optimize run `efa7cfd3b4e344c6`. Nothing is stale.

A cross-run mix-up is not reachable here either: `relatticeArtifacts` is
`run.retainedArtifacts` (`ProjectModel.swift:101`) — the pair lives **on the run**
whose `outcome` supplies the variant, so they move together or not at all. And
the entry gate already refuses a rung the container does not hold
(`RelatticeUnavailable.variantNotInDesign`), which a mismatch would have tripped.

### 1.3 The fix — name the variant by its IDENTITY

The rung stopped travelling in a fraction-shaped field. A variant is now named by
its **design fingerprint** — core's FNV-1a over that rung's density field, which
`design.bin` already stores and the app already parses
(`DesignContainerIndex.fingerprints`). It cannot alias another rung, cannot go out
of range, and is the same number bar Z3 uses to tie the certified object to the
exported one.

* `core/include/topopt/job.hpp` — `JobVariantRef` gains `fingerprint` (a **decimal
  string**: FNV-1a is a u64 and `2898949975693851963` does not survive a JSON
  double) and `achieved_volume_fraction`.
* `core/src/cli/job.cpp` — exactly one of `index` / `volume_fraction` /
  `fingerprint`. **`volume_fraction`'s `(0, 1]` bound is byte-for-byte
  unchanged**, and a test asserts `1.1` is still refused there.
* `core/src/cli/run_job.cpp` — selection by fingerprint, refusing by name and
  listing what the container holds.
* `app/.../LatticeVariantSession.swift` — `LatticeVariantContext` gains
  `achievedVolumeFraction` + `designFingerprint`, and **one** builder
  (`LatticeVariantContext.from`) fills them from the variant's own record. The
  page used to assemble this inline in the view, which is why the number it
  attached and the number it showed could differ with nothing able to see both.
* `app/.../RelatticeRunner.swift` — `build(original:variant:lattice:)` takes the
  **context**, so no call site can pair one variant's identity with another's
  fraction. A missing fingerprint **throws**; falling back to the rung is the bug.

### 1.4 Bar A3 — the intent, enforced; the letter, refuted

A3 wants the number travelling with a variant to be *that variant's own*, asserted
by equality rather than by a range. That is now true **and checked at runtime**:
the job carries `variant.achieved_volume_fraction`, and
`lattice_variant_job` refuses when it does not match the selected block —

```
lattice_variant: the job says this variant achieved volume fraction 0.51, but the
stored design achieved 1.086604308 (rung 1.1). The job is describing a different
variant than the one it selected.
```

Two deviations from the letter, both forced by measurement:

1. **It is `variant.achieved_volume_fraction`, not `variant.volume_fraction`.**
   Putting it in the latter would require widening `(0, 1]` — A2 forbids it, and
   rightly.
2. **The comparison is `1e-9` relative, not exact.** `json_num` writes report.json
   at 10 significant digits, so the app is handed `0.6686514886` for a design that
   achieved `0.6686514886164624`. An exact comparison would refuse every honest
   job on the shipping path and catch nothing. `1e-9` is ~20× the worst truncation
   error and ~8 orders of magnitude tighter than the gap between adjacent rungs, so
   it cannot confuse one variant with another — which is all it exists to catch.
   (The margin-reproduction check beside it stays **exact**: both of its operands
   exist at full precision.)

Tests, on the shipping path (bar L2):
`app/TopOptKit/Tests/TopOptFlowsTests/VariantIdentityTravelsTests.swift` drives a
finished `OptimizeVariant` + a real `design.bin` through
`LatticeVariantContext.from` → `RelatticeJobBuilder.build` and asserts the emitted
`achieved_volume_fraction` is **the same Double**, for a reduction variant
(0.508231173380035) **and** a growth variant (1.0866043075327818), using his own
runs' numbers.

### 1.5 Bar A4 — every field that travels with a variant

| field | source | verdict |
|---|---|---|
| `variant.design` | literal `"design.bin"` | correct — the worker's upload name |
| `variant.fingerprint` | container index for this rung | **new**, correct by construction |
| `variant.achieved_volume_fraction` | `v.achievedVolumeFraction` | **fixed**, and now checked by core |
| `variant.volume_fraction` | *was* the rung | **removed from this path** |
| `lattice.*`, `grading.*` | `project.lattice.runSpec` | correct — the settings the user has NOW, which is the point of the page |
| `lattice.regions` | `project.variantLatticeJobRegions()` | correct; face-derived regions are dropped with a posted note (bar Z11) |
| everything else | the retained job, verbatim | correct — additive copy, `loadCaseDifferences` asserts it |

**One more was wrong, and is fixed.** `RelatticeRunner.swift` built the result
variant with `achievedVolumeFraction: inputs.requestedVolumeFraction` — the same
conflation one layer on. It would have labelled a design that achieved 1.0866 as
1.1. It now **reads** the value from the job's own `lattice_variant.json`
provenance; absent provenance gives 0 ("not stated"), never a number from
somewhere else.

---

## 2. FAILURE B — WHY THE DENSITY WAS ZERO

### 2.1 B1 — the predicate, with counts

The receipt the maintainer read is worker run **`4dabe3b8512d4d59`**
(`M2_verticalStand.step`), and its `run_info.json` matches his screen exactly:

```json
"lattice_export": { "latticed_cells": 132, "triangles": 134116,
                    "strut_radius_min_mm": 0, "strut_radius_max_mm": 0.6452567419 }
"lattice":        { "rho_min": 0, "rho_max": 0.3709106553,
                    "strut_margin_in_plane": 530.3930798,
                    "strut_margin_interlayer": 317.0035085 }
```

There are **two** defects in that record, and they are not the same one.

**(a) The per-rung predicate.** `grading.cpp:184` — a candidate voxel whose
`width[e] / cell < n_star` (**`lattice_cells_per_member_min` = 5**, octet) stays
SOLID, counted as `member_too_thin_for_cell`. When that claims *every* candidate,
`region_ungradeable` is set — and `rho_min_used` / `min_strut_diameter_mm` are only
assigned `if (latticed_voxels > 0)`, so they stay at their `0.0` defaults.
`region_ungradeable` was computed, carried through five receipts and observability
— and **acted on nowhere**.

**(b) The run-level aggregate — this is what produced "0 %".** `run_job.cpp`
takes a MIN over rungs:

```cpp
lat_agg.r_min  = std::min(lat_agg.r_min,  oc.stats.min_strut_diameter_mm / 2.0);
lat_agg.rho_lo = std::min(lat_agg.rho_lo, graded ? gf.rho_min_used : cc.rho);
```

One ungradeable rung contributes `0` to both and drags the **whole run's** report
to zero. That is why the receipt reads `rho_min 0` and `strut radius 0.00` next to
a perfectly real `rho_max 0.371` and `0.645 mm` — **other rungs latticed fine**.
The report was quoting a rung that had no struts at all.

`evidence/.../B_extrusion_width_sweep.tsv` has the graded law re-run across
extrusion widths and cell sizes on that same design.

### 2.2 B3 / L3 — it refuses now

`lattice_one_variant` returns early with `ungradeable` + a full reason and
**emits nothing**. The two callers want opposite things from that fact and get
them:

* **`lattice_variant_job`** — its whole purpose is one lattice, so it **refuses**:

  ```
  lattice_variant: the grading law could lattice NONE of this variant's 19488
  candidate voxels, so there is no lattice to emit — refusing rather than writing a
  file with zero struts in it and calling it a lattice. Reasons:
  member_too_thin_for_cell=19488, strut_unprintable_at_every_cell=0,
  irrecoverable_by_any_cell_size=13408. The widest member the law rejected is 25 mm;
  at this cell size a member must be at least 1000 mm across to hold 5 cells. A
  smaller cell needs a finer declared extrusion width (min_extrudable_width_mm 0.42
  mm sets the printability floor at 4.602619932 mm) — run the pre-flight forecast
  for the evaluated remedies.
  ```

* **the optimize path** — has a LADDER, so one thin rung must not destroy the
  others' output. It logs `[lattice] vf=… NO LATTICE EMITTED — …`, skips the rung
  **before the aggregation** (closing 2.1(b)), and records
  `lattice_export.ungradeable_variants` so "3 of 4 rungs latticed" is a stated
  fact rather than a missing file.

Test: `core/tests/validation/test_lattice_variant.cpp::section_identity_and_zero_density`
asserts the refusal, its predicate, its counts, **and that no `.stl` was written** —
a refusal that still left a zero-strut mesh on disk would be the same failure with
an error message attached. 86 checks, 0 failures.

App side (`ResultsModel.latticeNotes`): a record with 0 latticed cells or a
zero max strut radius now reads *"NO LATTICE WAS PRODUCED … the density and strut
figures below describe nothing and are withheld"* — **B4**, since a strut margin of
530.39 computed on no material is not a number. The lattice page also **disables**
the button when the forecast says nothing would be latticed (it warned before,
which is right for a *partial* lattice and wrong for an empty one).

### 2.3 B2 — are A and B one bug? **REFUTED, and it matters**

They are independent, and the proof is that each reproduces without the other:

* B's signature comes from run `4dabe3b8512d4d59`, an **optimize+lattice** run
  that never went near `variant.volume_fraction` — no `variant` block exists on
  that path.
* A's failure is at **schema validation**, 48 ms in, before any grading law runs.

They share only a victim. Fixing A does not fix B and vice versa; both are fixed.

### 2.4 THE REMEDY THE FORECAST REFUSED TO NAME — and the "nothing can help" lie

`irrecoverable_by_any_cell_size` is true only **inside a fixed printability
floor**, and that floor is not a property of the part:

```
floor_mm = min_extrudable_width_mm / phi(rho_lo, unit cell)
```

It is the **declared extrusion width** divided by a constant. So the sentence the
forecast emitted whenever it withheld its cell remedies —

> "An empty list means no parameter change could help."

— was **FALSE**, and false on exactly his parts.

MEASURED on his `M2_verticalStand` run (`4dabe3b8512d4d59`, no design box, so the
graded law runs on it today — `evidence/.../B_extrusion_width_sweep.tsv`, rung 0,
9 628 region voxels):

| declared width | printability floor | best cell probed | latticed voxels | fraction |
|---|---|---|---|---|
| **0.42 mm (his)** | 4.603 mm | 4.6 / 3.0 mm (both clamp to the floor) | 1 295 | 13.5 % |
| 0.30 mm | 3.288 mm | 3.0 mm | **1 581** | 16.4 % |
| 0.25 mm | 2.740 mm | 3.0 mm | **1 581** | 16.4 % |

and the total case on the same run's rung 3 (0.26 — the rung the app re-latticed,
and the one whose `0` poisoned the run-level minimum): **0 voxels at every one of
the twelve combinations probed**; its widest member is 13.64 mm and a 3.0 mm cell
needs 15 mm.

The same law on his WallMount growth run (rung 1.55, 70 788 region voxels) is
starker — 0.42 mm ⇒ **0** at every cell size; 0.30 mm + a 3.0 mm cell ⇒ **6 750**
(9.5 %); 0.25 mm ⇒ **12 020** (17.0 %). Those were taken by driving the grading law
directly at that design; the job itself cannot be run graded today because it
carries a design box (§4.1).

He was told nothing could help, for a week. The forecast now **evaluates** an
extrusion-width remedy (the break-even width in closed form, plus half the declared
width, each re-run through the grading law and reported with the cell it unlocks),
offered whenever any voxel was rejected as irrecoverable-by-cell — not only when
the lattice is entirely empty — and the note no longer claims to have exhausted the
space:

> "An empty list means none of the changes probed here (cell size, extrusion
> width, dropping the include regions) lattices anything on this design — **NOT**
> that the part is beyond help."

### 2.5 B5 — `forecast_only` IS honoured. The forecast was forecasting the wrong job.

`run_job.cpp:3827` returns immediately after writing `lattice_forecast.json`, before
any solve or emission — confirmed on disk: his forecast job dirs contain only
`lattice_forecast.json` + `loadcase.json`. The 134 116 triangles in his panel came
from a **different, non-forecast run** (`4dabe3b8512d4d59`, §2.1). B5's premise is
refuted.

**But a real B5-shaped defect was found underneath it.** `lattice_forecast_json`
ran `grade_lattice` unconditionally — including for a job with **no `grading`
block**, which does not run the grading law at all (`graded = job.grading.present`;
uniform means one declared radius everywhere, no cells-per-member floor, no
printability floor). So for a uniform job it forecast a graded run that was never
going to happen:

* forecast, before: `would_lattice_voxels: 0` — *"This configuration would lattice
  NOTHING"*
* the same job, run for real: **17.6 MB of struts**, 371 cells, 9 851 latticed
  voxels

A forecast of a different job is worse than no forecast: it warned him off the one
configuration that worked. The uniform case is now forecast by running the **same
two predicates the uniform run runs** (`lattice_boundary_for` +
`lattice_certification_mask`) and counting their mask — 100 % of the region, which
is what the run then produced. `evidence/.../B5_uniform_forecast_after.json`.

### 2.6 B6 — the preview/build scope, reconciled

`ResultsModel.latticeNotes` printed *"Region-scoped in the preview; this build
lattices the whole solid interior"* whenever **anything** scoped the preview. That
announced a disagreement that is only sometimes real, and made every user's regions
look ineffective. The two cases are genuinely different:

* `lattice.regions` **do** travel with the job and core restricts the latticed set
  to the include union — region-scoped, exactly as previewed.
* the legacy preview-only include primitive (`LatticeSettings.region`) never
  reaches the job. That, and only that, is what the old sentence described.

`LatticeReport` gains `emittedRegions` (what the job carried, mirrored into the
`OutcomeStore` DTO — the honesty-flag rule) so the line reports which of the two
actually happened.

---

## 3. FAILURE C — THE BRUSH PREVIEW

The toggle was **inert** until a re-certification ran: both tabs drew the same
mesh, and the page printed *"Nothing smoothed yet"* over a live 71 752-triangle
brush region at strength 0.49. It was describing its own inability to preview as a
fact about his brush.

**C1 — the brush is applied live.** New seam `smooth_brush_preview`
(`bridge.cpp`): the **same** `constrained_taubin_smooth` under the same per-vertex
weights, with two things deliberately left out so it runs at interactive rates —
no model import / voxelization / load case (the caller's already-computed freeze
mask arrives as weight 0, which the smoother copies **verbatim** on the identical
code path it uses for a frozen vertex), and no min-feature constraint. The
certified pass may therefore smooth *less*, and the page says so rather than
implying the preview is the certified result.

Wired on the shipping path: `WorkspacePlaceholder` passes a `previewer`, fires it
on stroke `.ended` (not mid-drag), and lands the result in `smoothedVariantMesh`
— **the buffer the stage actually draws**. A preview that landed anywhere else
would flip a label over unchanged geometry, which is the defect, not the fix. A
certified or kept result always outranks it.

The note now reads, e.g.: *"Smoothed shows the brush applied — 0.42 mm at the
deepest. Re-certify APPLIES it under the min-feature constraint and measures the
result, so the certified shape may move less."* A page with no preview engine says
*"This page can't preview the brush"* instead of offering the comparison.

**C2 — "Re-certify" → "Apply & certify"**, sub-line *"applies the brush to the
variant, then one certification solve on the result"*. It read as a check on a
smoothing that had already happened; nothing is smoothed until it runs.

**L4**: `BrushPreviewVisibleTests.swift` — Smoothed differs from Original after a
stroke with `certifyCallCount == 0`; an unpainted brush and a zero-displacement
preview are both refused as smoothed sides; the no-engine page says so; C2's copy
is asserted.

---

## 4. THE FOUR BLOCKERS, AND THE TWO THAT REMAIN

Every re-lattice the maintainer attempted, from his worker directories:

| blocker | attempts | status |
|---|---|---|
| `"variant.volume_fraction" must be in (0, 1]` | 3 | **FIXED** (§1) |
| `a "grading" block is not yet supported together with a "design_box"` | 9 | **NOT FIXED — see below** |
| `the restored design does NOT reproduce the margin … (recorded 2030.401632, reproduced 2030.401633)` | 1 | **NOT FIXED — see below** |
| `exit rc=-9` (SIGKILL, out of memory) | 1 | not reached this task |

### 4.1 Grading + design box — left refused, deliberately

Every one of his parts uses a design box, and the app's Auto-density path sends a
`grading` block, so this refusal blocks the graded path on all of them. It is
nevertheless **correct as it stands**: the grading law chooses its cell plan before
the added-material policy runs, and that policy acts on **whole cells** (the
receipt's `voxels_strut_and_solid = 0` is what makes the uniform path provably
safe). With a per-cell variable plan the policy's atom is ambiguous, and a graded
design-box run could emit struts into cells the certificate calls solid — the exact
class this project has spent weeks eliminating. Lifting it needs the two to be
sequenced, which is a design change beyond this task.

**What this task did instead**: made the uniform path — the one the refusal steers
him to — actually reachable and honestly forecast (§2.5). That is how §5's part
was produced.

### 4.2 The margin reproduction failing on the last digit

`e11d627fe0e344c0` refused with recorded `2030.401632` vs reproduced
`2030.401633` — a **~5e-10 relative** difference. Both operands are full-precision
f64 (design.bin and a fresh solve), so unlike §1.4 this is not a wire-truncation
artefact: it is the CG solve not reproducing bit-for-bit. **I did not touch it**,
because the brief forbids weakening assertions and because diagnosing why the
solve is not bit-reproducible is its own task. It did **not** block the WallMount
part (§5 reproduces `exact: true`). Flagged as the next thing to look at: on the
parts where it fires it is unfixable from the UI.

---

## 5. BAR L1 — HIS PART, LATTICED

`variant_110_lattice.stl`, 17 652 084 bytes, 353 040 triangles.
Job: worker `0cc8e495de084e5d`'s own document — same model, same 128³ grid, same
design box, same load case, same `design.bin`, rung 1.10 selected **by
fingerprint** `2898949975693851963` with `achieved_volume_fraction`
`1.0866043075327818` — with the graded block swapped for a uniform 8 mm cell +
0.80 mm strut radius (§4.1 is why).

| | |
|---|---|
| latticed_voxels / region_voxels | **9 851 / 49 909 = 19.7 %** |
| rho range | 0.2117332176 – 0.2117332176 (uniform) |
| strut radius | **0.80 mm** (diameter **1.60 mm**) — the FAIL condition was 0.00 |
| lattice cells emitted / certified | 371 / 371 (equal — the exported set IS the certified set) |
| clipped struts / landings / skin struts | 2 791 / 3 112 / 735 |
| margin worst-case / effective / required | 5.222 / 3.392 / 1.50 — **accepted** |
| margin reproduction | recorded 12.37710892, reproduced 12.37710892, **exact: true** |
| mass | 224.26 g |
| wall | 1 233 s (3 certification solves, 0 design iterations) |

Cross-sections: `wallmount_xsec.png` (three orthogonal), `wallmount_xsec_zoom.png`
(octet cells resolved inside the wall plate).

**Why only 19.7 %.** 73.3 % of this growth variant's printed material lies OUTSIDE
the imported part's envelope — it is what the design box let the optimizer add —
and the added-material policy is `keep_solid`. Only material inside the original
part is latticed. That is the documented conservative default, not a defect.

**The caveat, stated plainly.** The receipt reports
`strut_strength.cells_per_member_min = 0.405` — the octet homogenization wants ≥ 5,
and this is 12× below it. The uniform path applies **no** cells-per-member floor
and **no** printability floor; that is exactly why it succeeds where the graded law
refuses. The gate verdict does not use the strut numbers
(`strut_gated: false`), so "accepted" is a statement about the composite
certification, and the report-only interlayer strut margin is **1.074**. This part
is a real latticed object and a legitimate export; its strut-level strength is
**out of regime and uncertified**, and the receipt says so. Closing that gap is
the graded path (§4.1).

---

## 6. BARS

| bar | verdict |
|---|---|
| **L1** his part, latticed, visible, certified | **MET** — §5, strut radius 0.80 mm |
| **L2** the variant's own number travels, shipping path | **MET** — `VariantIdentityTravelsTests`, both ladders |
| **L3** no silent degenerate output | **MET** — `test_lattice_variant` §2.2, incl. "no .stl written" |
| **L4** the brush is visible before re-certification | **MET** — `BrushPreviewVisibleTests` |
| **L5** byte-identity where nothing changed | **MET** — §7, with the binaries proven to differ first |
| **L6** full CTEST + app-macos | **MET** — ctest 106/106; app 1192 tests / 0 failures |
| **L7** determinism | **MET** — the L1 job reruns byte-identical, 17.6 MB mesh included |
| **A2** the `(0, 1]` bound | **untouched**, and asserted still-refusing at 1.1 and 0 |
| **A3** | intent enforced at runtime; letter refuted with measurement (§1.4) |

---

## 7. VERIFICATION

### L2, the whole chain — the app's own bytes, parsed by core

`VariantIdentityTravelsTests` writes the **exact `Data`** the lattice page submits
to `evidence/.../L2_growth_variant_job_as_the_app_emits_it.json` (set
`TOPOPT_EVIDENCE_DIR`; without it the test is a no-op). Those bytes, against his
real `design.bin`:

```
variant: {"design": "design.bin",
          "fingerprint": "2898949975693851963",
          "achieved_volume_fraction": 1.0866043075327818}

$ topopt-cli lattice-variant job.json --out out
→ ACCEPTED. variant_volume_fraction 1.1 | would_lattice 50300 / 50300
```

The growth rung that could not be expressed at all now resolves, on bytes this app
produced rather than a hand-written stand-in.
(`evidence/.../L2_core_accepted_the_apps_bytes.json`.)

### L5 — byte-identity where nothing changed

`core` at `HEAD` was extracted with `git archive` into a separate tree and built
into its own binary, so the working tree was never disturbed. **Guard first**, per
this repo's history of vacuous identity bars:

```
before f0a20654643edebe0bdbfa9924865bab41f792c238bc104d75d590e63f1a7e30
after  47a20701ad14eeed031b3a8f39eefe845442f498b6f139cbe1deba6dd156f2ab
→ the two binaries DIFFER, so the comparison below is not vacuous
```

Both ran the same optimize+lattice job (`plate_bore.stl`, res 32, ladder [0.6],
octet 3.0 mm cell, 0.45 mm strut, diagrid) — a path this task changed code inside
(`emit_lattice` now has an early-out branch):

| artifact | verdict |
|---|---|
| `design.bin` | **IDENTICAL** |
| `fields.bin` | **IDENTICAL** |
| `loadcase.json` | **IDENTICAL** |
| `report.json` | **IDENTICAL** |
| `variant_060.stl` | **IDENTICAL** |
| `variant_060_lattice.stl` | **IDENTICAL** |
| `variant_060_lattice.report.json` | **IDENTICAL** |
| `iterations.csv` | identical in **every** non-timing, non-memory column; differs only in `wall_ms` / the `*_ms` phase columns |
| `build_orientation.json` | identical apart from `sweep_seconds` and `strut_axis_measure_seconds` |
| `run_info.json` | excepted by design — it carries a deliberate wall-clock stamp |

Every design and geometry artifact is byte-for-byte unchanged. The only
differences anywhere are measured durations.

### L6 — the two suites

**core**: `ctest --output-on-failure` — **106 / 106 passed, 100 %**, 1 851.59 s.
Run against a build made from the FINAL sources (an earlier run was discarded
because it had been started before the last `run_job.cpp` edits, and reporting a
stale-binary pass as the number would be the wrong kind of green). `lattice_variant`
33.03 s, `protect_freeze_vs_solidity` 354.98 s, `cli_demo` 251.39 s.

**app-macos**: `swift test --package-path app/TopOptKit` —
**1192 tests, 14 skipped, 0 failures**. Run WITHOUT `TOPOPT_ASSERT_FRAME_BUDGET=0`,
i.e. stricter than CI, and the raymarch budget passed on its own (13.676 ms against
16.6).

One trap worth recording: this worktree had no `vendor/lib3mf-lib`, so eight
AppModelTests failed on 3MF import before it was provisioned
(`app/scripts/build_lib3mf_macos.sh` then `build_core.sh`), and SwiftPM's manifest
cache had to be cleared for the new link flags to take. CI provisions lib3mf
explicitly for exactly this reason.

### L7 — determinism

`test_lattice_variant`'s Z8 checks (byte-identical latticed mesh and receipt on a
rerun) pass on both the uniform and graded paths — **90 checks, 0 failures**,
including this task's new `section_identity_and_zero_density`.

And on the deliverable itself: §5's job was run **a second time, from scratch**
(1 456.57 s against the first run's 1 233.29 s — the machine was busier, which is
the point: the wall time moved and the output did not):

```
IDENTICAL  variant_110_lattice.stl          (17 652 084 bytes)
IDENTICAL  variant_110_lattice.report.json
IDENTICAL  lattice_variant.json
IDENTICAL  lattice_variant_report.json
IDENTICAL  loadcase.json
IDENTICAL  fields.bin
```

Every file the job writes, including the 17.6 MB mesh and the 10.8 MB field
container, byte for byte.
