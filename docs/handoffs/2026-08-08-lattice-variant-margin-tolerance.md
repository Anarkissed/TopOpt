# 2026-08-08 — the margin tolerance, and ranking the object you'd print

Task `lattice-variant-margin-tolerance-and-mass-rule`, branch
`claude/lattice-variant-margin-tolerance-f0902f`, branched from `966ffa6`
(`origin/main`, PR 312). Successor to PR 312 (`lattice-recipe-not-triangles`) and
PR 311 (`lattice-variants-on-screen`).

Changes `core/` and `app/`. Two build outputs on merge. CI: `core-linux` +
`app-macos`.

Evidence: `evidence/2026-08-08-lattice-variant-margin-tolerance/`

---

## 0 · Headline

**Your four rungs lattice on demand now. All of them.** The check that refused
them was comparing two doubles with `==`, and the reason they differ is not the
design, the grid or the load case — **it is the solver.** The Krylov recycle
subspace is production-armed and carried between solves, so the margin your run
RECORDED came out of a solve carrying a warm subspace, while every
re-certification is deliberately denied it. Two Krylov paths, one operator, both
converged to the same residual: they agree to nine significant figures and no
further, for ever, by design.

**Your run has been failing its own proof since the recycler was armed, and
nothing said so.** Every one of your four lattice receipts on the Mac Mini already
carries `"solid_reconstruction_exact": false`. Nothing reads that key. That is the
same `==` in the same shape, one function away.

**The band is 1.0e-06 relative, and it is derived, not fitted.** It is 100× the
certification solve's own convergence tolerance — the thing that causes the
difference. Measured: it sits **148× above the worst solver noise** (6.8e-9) and
**100× below the smallest corruption it must catch** — and the smallest
corruption I could construct is **one voxel of the design flipped to solid**,
which moves the margin by 2.0e-3.

**The recommendation now points at the object you would actually print.** On your
run that moves it from the vf=0.26 rung's 360 g solid to the vf=0.68 rung's
**215 g lattice** — 31.22 g, 12.7 %, exactly what PR 311 measured the old rule
costing you. No verdict moved.

**Three corrections to what you were told, all in your favour except the last:**

1. **The 0.63 s was not your run.** That was PR 312's own small reproduction. Your
   `run_info.json` records `gen_seconds: 21.33` for all four rungs.
2. **Materialising a rung on demand costs ~6 minutes, not 0.63 s** — 276/351/354/390 s
   for your four. The geometry really is ~1 % of that; the other 99 % is that the
   re-lattice path runs **four 128³ certification solves** (`analysis_solves: 4`).
3. **The regenerated file is not byte-identical.** Same triangle count, 85 % of
   triangles bit-identical, worst vertex anywhere **1.5e-5 mm out — 1/112,000 of a
   voxel.** The same object; not the same bytes. §5 says what that costs.

**Your 5.17 GB is still there, and it can now be deleted safely by hand.** §5 has
the exact steps and the two caveats.

---

## 1 · S1(a) — the root cause, with file and line

**BEFORE THE TOLERANCE, THE EXPLANATION.** Full working, with the raw probe
output: `evidence/.../s1a_root_cause.md`.

### The measurement

`analyze_fixed_design` was instrumented to dump, on entry, an FNV-1a hash of the
grid tags / density field / BC array / load array plus every scalar argument, and
on exit the CG iteration count, the final residual and a hash of the whole
displacement vector. On your job at resolution 40 (so the loop is 60 s, not 64
minutes), the run's first two solid certification calls:

```
CERTPROBE grid=40x10x37 tags=35a935586e3286c4 density=8783339658f85963
          nbc=2106 bcs=ef388c6c57a7c696 nload=995 loads=5860948804eb27f2
          E=3500 nu=0.33 p=3 bdir=0,0,1 tol=1e-08 solver=2 psolid=3557 iso=0.5 lat=0
CERTPROBE-STATE recycling=1 mglatched=1
CERTPROBE-OUT  cgiter=509  cgres=9.313e-09 worst=2175.5297559536912

CERTPROBE grid=40x10x37 tags=35a935586e3286c4 density=8783339658f85963
          nbc=2106 bcs=ef388c6c57a7c696 nload=995 loads=5860948804eb27f2   ← IDENTICAL
CERTPROBE-STATE recycling=0 mglatched=1
CERTPROBE-OUT  cgiter=1062 cgres=9.359e-09 worst=2175.529755771578
```

**Every input hash is equal. `recycling` is not.** 509 iterations against 1062,
different displacement fields, margins differing at the ninth figure. All four
rungs, same shape.

### The mechanism

`analyze_fixed_design` is **not a pure function of its arguments**, and its own
header said it was ("the certification solve is stateless … so a re-analysis of
the same field is bit-identical" — `analyze.cpp`). That comment is now corrected
in place.

| | fact | file:line |
|---|---|---|
| 1 | The Krylov recycle subspace is a thread-local **carried between solves** | `core/src/fea/recycle.cpp:83` |
| 2 | It is **production-ARMED** | `core/src/simp/production.cpp:672` |
| 3 | …and deliberately **not reset per rung** | `core/src/simp/production.cpp:674` |
| 4 | It wraps the **matrix-free Jacobi-CG** path | `core/src/fea/matfree.cpp:945` |
| 5 | …and **not** multigrid, because production says so | `core/src/simp/production.cpp:673` |
| 6 | The **ladder's certification** — which produces the RECORDED margin — runs with it warm | `core/src/simp/minimize_plastic.cpp:1806` |
| 7 | Every **re-certification** runs with it OFF | `core/src/cli/run_job.cpp:2517` (`ScopedLadderSolverIsolation`), constructed `run_job.cpp:2547` |
| 8 | …and that isolation covers `lattice_variant_job` **on purpose** | `run_job.cpp:2515-2516` |
| 9 | Why it exists: without it, rung k+1's optimize inherited a subspace rung k's LATTICE solves had moved | `run_job.cpp:2477-2513` (task `subfloor-lattice-unloaded-regions`, §7) |
| 10 | The comparison that refused | `run_job.cpp:5463` — and the same `==` at `run_job.cpp:1391` |

Item 9 is a defect that was found by measurement and closed. **Re-arming the
accelerators for the re-certification would break it again.** The two solves are
supposed to differ. What was wrong was the comparison.

### The falsifier — and why the suite never caught it

Item 5 predicts that a part whose grid COARSENS never engages the recycler and so
reproduces bit-for-bit. Read straight out of each run's own `iterations.csv`:

| run | solves | multigrid carried | recycler engaged | `solid_reconstruction_exact` |
|---|---|---|---|---|
| `plate_bore.stl` res 48 (the repo's lattice fixture) | 240 | **240/240** | **0/240** | **true**, all rungs |
| `M2_verticalStand.step` res 40 | 243 | 4/243 | 238/243 | false |
| **your run**, res 128 | 445 | **0/445** | **444/445** | **false**, all rungs |

Your part is a thin vertical stand; its grid does not coarsen, so every solve is
Jacobi-CG — exactly the path the recycler wraps. Every lattice fixture in the repo
coarsens. That is the whole reason this shipped.

### Your own run has been reporting it

| rung | `solid_margin_worst_case` | `solid_margin_reproduced` | `solid_reconstruction_exact` |
|---|---|---|---|
| 0.68 | 2169.617171 | 2169.617163 | **false** |
| 0.52 | 2259.952815 | 2259.952813 | **false** |
| 0.38 | 2193.876833 | 2193.876835 | **false** |
| 0.26 | 2008.278339 | 2008.278337 | **false** |

And the standalone path lands on the **same numbers as the in-run
re-certification**, which is the final confirmation that the recorded value is the
odd one out.

---

## 2 · S1(b) — the band, and what it still catches

```cpp
inline constexpr double kMarginReproductionResidualFactor = 100.0;
bool margin_reproduces(double recorded, double reproduced, double cg_tolerance);
```
(`core/include/topopt/analyze.hpp`, with the full derivation; implemented in
`core/src/simp/analyze.cpp`.)

`band = 100 × cg_tolerance` = **1.0e-06** at the production certification
tolerance of 1e-8 (`minimize_plastic`'s `kCertTol`, asserted at
`minimize_plastic.cpp:1803`).

**Why anchored to `cg_tolerance` and not to the observed spread.** Both solves
satisfy ‖f − Ku‖/‖f‖ ≤ `cg_tolerance`; that inequality is the reason they can
disagree at all, and how far. A constant fitted to what I happened to observe
would be a number with no argument behind it. A non-positive tolerance falls back
to exact equality rather than inventing a band.

**The separation, entirely measured:**

| | relative delta | |
|---|---|---|
| solver-path noise across 3 parts / 13 rungs | 8.4e-11 … **6.8e-09** | must PASS |
| **the band** | **1.0e-06** | |
| the declared load off by one part in 10⁴ | 1.0e-04 | must FAIL |
| **ONE voxel of the design flipped to solid** | **2.0e-03** | must FAIL |
| the whole design 2 % denser | 6.1e-02 | must FAIL |

**148× above the worst noise; 100× below the smallest corruption** — and that
smallest corruption is a single voxel, which is the finest change to a design that
exists. There is no way to alter the object by less and still alter it.

**What it still protects.** Unchanged in kind: a mismatch still means the load
case, the grid or the design is not the one that produced this variant, and it
still refuses, with the relative delta and the band now in the message.

Where it sits among the other guards, precisely — because "what it still catches"
should be stated, not implied:

| guard | what it proves | file:line |
|---|---|---|
| grid dims / spacing / origin, exact | the stored design indexes THIS job's grid | `run_job.cpp:5307-5318` |
| FNV fingerprint on selection | `design.bin` was not corrupted, and the job names a block it really holds | `run_job.cpp:5338-5357` |
| achieved volume fraction, 1e-9 relative | the job selected the variant it thinks it did | `run_job.cpp:5397-5407` |
| **the margin reproduction — this one** | **the LOAD CASE, the material and the solver settings are the ones that produced it** | `run_job.cpp:5521-5541` |

None of the first three sees a load. A `design.bin` from the right run, on the
right grid, at the right rung, re-latticed under a **different load case** is
caught by this check and by nothing else — which is why the 1e-4 row of the table
above is measured on exactly that perturbation.

### ★ THE RELAXATION, REPORTED (bar R5)

**One production check was deliberately loosened. It is the task.**

```
before   core/src/cli/run_job.cpp:5463    result.reproduction_exact =
                                            (result.solid.margin.worst_case == sd.margin_worst_case);
         core/src/cli/run_job.cpp:5473    if (!result.reproduction_exact) throw …

after    core/src/cli/run_job.cpp:5521    result.reproduction_within_band =
                                            margin_reproduces(sd.margin_worst_case,
                                                              result.solid.margin.worst_case,
                                                              options.simp.cg_tolerance);
         core/src/cli/run_job.cpp:5532    if (!result.reproduction_within_band) throw …
```

**The exact comparison was not deleted.** `reproduction_exact` survives as a
reported flag, and **both core tests that assert it are untouched and still pass**
(`test_lattice_variant.cpp:251`, `test_designbox_lattice_recert.cpp:348`) — their
fixtures coarsen, so they still reproduce bit-for-bit, which is now the thing they
prove. The run receipt keeps `solid_reconstruction_exact` verbatim and gains
three keys beside it:

```json
"solid_reconstruction_exact": false,
"solid_reconstruction_relative_delta": 2.824072303e-09,
"solid_reconstruction_band": 1e-06,
"solid_reconstruction_reproduces": true
```

The `lattice_variant` provenance's `"exact": true` was **hard-coded**; it is now
the measured fact (usually false) with the delta, the band and a note naming the
mechanism.

Second deliberate change, also reported: PR 311's
`testTheRecommendationPointsAtTheHeaviestLatticedObject` pinned the old
recommendation rule *until you ruled*. You ruled. It is re-pinned as
`testTheRecommendationPointsAtTheLightestPrintedObject`, keeping every measured
fact it asserted and **adding** the 31.22 g the old rule cost as an assertion.

Full census: `evidence/.../R5_assertion_census.txt`. In the app tree no assertion
KIND fell (17 kinds, every one non-decreasing) and the only test function removed
is the re-pinned one above; in the core tree no assertion message disappeared at
all and `CHECK` sites went 3921 → 3947. The removed app message strings are all
from those two deliberately-changed tests and are listed in the census output.

---

## 3 · S1(c) — red, then green, on your own run

**RED** — `topopt-cli lattice-variant` on `{job.json, design.bin}` from worker job
`ca62f91cba4b422d`, nothing else read. Verbatim, `evidence/.../R2_red_his_run.txt`:

```
=== vf=0.68 ===
topopt-cli: lattice_variant: the restored design does NOT reproduce the margin the run
recorded for this variant (recorded 2169.617171, reproduced 2169.617169). …
=== vf=0.52 ===   recorded 2259.952815, reproduced 2259.952813   REFUSED
=== vf=0.38 ===   recorded 2193.876833, reproduced 2193.876835   REFUSED
=== vf=0.26 ===   recorded 2008.278339, reproduced 2008.278337   REFUSED
```

4 of 4.

**GREEN** — the same four commands, after (`evidence/.../S1cd_materialise.txt`):

```
=== vf=0.68 ===  exit=0  wall=275.99s   1954879484 bytes   rel delta 2.824e-09  band 1e-06
=== vf=0.52 ===  exit=0  wall=350.63s   1420059884 bytes   rel delta 1.267e-10  band 1e-06
=== vf=0.38 ===  exit=0  wall=353.54s   1058859084 bytes   rel delta 1.117e-11  band 1e-06
=== vf=0.26 ===  exit=0  wall=389.56s    740360884 bytes   rel delta 2.042e-10  band 1e-06
```

Every one produces a file of **exactly the byte count the eager run wrote**, with
`lattice_accepted: true`, and with `lattice_mass_grams` equal to the run's own to
all ten printed digits.

Plus a permanent regression test in core, `margin_reproduction`
(`core/tests/unit/test_margin_reproduction.cpp`, 28 checks), which reproduces the
divergence **in process** — same design, recycler armed then disarmed, on a
fixture forced into the same Jacobi-CG regime — and asserts (a) the two really do
differ, so the band cannot silently become unnecessary, (b) the band admits it,
(c) the band refuses one flipped voxel.

---

## 4 · S1(d) — what it unlocks, and what it actually costs

**The premise needs correcting, and the correction matters.** The 0.63 s PR 312
quoted was `gen_seconds` on **its own** small reproduction run (2,140 cells). Your
run's `run_info.json` records `gen_seconds: 21.33` for all four rungs, 0.53 % of
the 4012 s run.

Measured, end to end, one rung at a time from `{job.json, design.bin}`:

| rung | mesh written | wall | the generator's share |
|---|---|---|---|
| 0.68 | 1.95 GB | **276 s** | ~8 s |
| 0.52 | 1.42 GB | **351 s** | ~6 s |
| 0.38 | 1.06 GB | **354 s** | ~4 s |
| 0.26 | 740 MB | **390 s** | ~3 s |

`lattice_variant.json` reports `analysis_solves: 4` — the reproduction proof, the
lattice pipeline's own null-posture proof, the composite certification, and the
band-clamp counterfactual. **Four 128³ certification solves at ~90 s each is where
the six minutes go.** PR 312 was right that the geometry is ~1 % of the cost; it is
the certification wrapped around it that is not.

So: **materialise-on-demand works, and it prices at ~6 minutes of Mac time per
rung, not 0.63 s.** If that ever needs to be cheaper, the lever is visible and is
not the generator: three of those four solves are proofs, not products.

---

## 5 · S2 — ranking the object you would print

### (a) The rule

`ResultsModel.buildTabs` no longer uses `variants.count - 1`. A rung is ranked on
the object it would **export** — its accepted lattice where it has one, its solid
otherwise — and the recommendation is the lightest of those, badged on **that
object's own tab**. `ResultsModel.printedObjectPerRung` exposes the per-rung answer;
`ResultsModel.recommendation(_:)` the across-rungs one.

Two guard rails, both tested:

* **No mass, no ranking.** A remote run whose `fields.bin` scalars never arrived
  carries `massGrams == 0`, which would win every comparison and recommend the
  variant we know least about. When any rung's printed object has no real mass the
  rule falls back to the ladder's own ordering — which is what it always was.
* **Ties go to the later rung**, so a run with no lattice (solid masses descend
  down the ladder) recommends exactly what it recommended before — including the
  degenerate fixture case where every variant is 100 g. That is why the existing
  recommendation tests in `ResultsModelTests`, `GrowthLadderTests` and
  `StreamedVariantVisibilityTests` are untouched and still pass.

### (b) ★ The acceptance condition, with file and line

A rung's lattice counts as printable **only if its own composite certification
accepted it**. That verdict is:

* decided in core at **`core/src/cli/run_job.cpp:2171-2172`** —
  `lattice_accepted = a.accepted && finish_certified`, where `a` is the LATTICED
  certification solve (`run_job.cpp:1677`, the `analyze_fixed_design` call carrying
  the octet posture) and `finish_certified` refuses a shell-less `"skin"` finish;
* carried to the app on the per-variant receipt (`lattice_accepted`, read by
  `LatticeVariantAlternative.receiptFacts`) and on the rung's `LATTICE …`
  checkpoint line (`lattice_accepted=1`, `LatticeCheckpoint.parse`);
* landed on `LatticeVariantAlternative.accepted`.

**It is never the rung's own `accepted`.** A rung whose solid passes can produce a
lattice that does not, and one verdict must never stand for the other.
`testARefusedLatticeFallsBackToItsSolidForRanking` and
`testWithNoCertifiedLatticeTheRuleIsTheOldOne` pin both directions.

### (c) The recommendation says which object

`ResultsModel.recommendationLine`, rendered above the variant tabs
(`ResultsScreen.recommendationCaption`). On your run:

```
Recommended: the latticed object of the −20% rung, 215 g · the same rung's solid is 544 g
```

and, under the old rule, it would have read:

```
Recommended: the solid object of the −47% rung, 360 g · the same rung's latticed is 246 g
```

The recommended object's mass leads; the rung's other object is named as the other
object, so 544 g can never be read as the thing being recommended.

### (d) Before and after, on your run

Full table with every fallback: `evidence/.../S2d_recommendation_before_after.txt`.

| ladder | rung | solid | latticed | would print | mesh |
|---|---|---|---|---|---|
| 1st | 0.68 | 543.73 g | **215.16 g** | 215.16 g | 1.95 GB |
| 2nd | 0.52 | 473.32 g | 239.93 g | 239.93 g | 1.42 GB |
| 3rd | 0.38 | 412.47 g | 244.78 g | 244.78 g | 1.06 GB |
| 4th | 0.26 | **360.30 g** | 246.38 g | 246.38 g | 740 MB |

| | before | after |
|---|---|---|
| recommended tab | the 4th rung's SOLID | the 1st rung's LATTICE |
| what it weighs | 360.30 g (its lattice: 246.38 g) | **215.16 g** |
| against the old rule | — | **−31.22 g, −12.7 %** |
| the mesh to move | 740 MB | 1.95 GB (2.6×) |
| **verdicts moved** | — | **none** |

**The trade this makes, stated.** PR 311 warned that the lightest lattice sits on
the largest mesh. That is still true and is now the shipped behaviour. On your iPad
neither rung can be *displayed* anyway (PR 311 §4), so this changes which object
Export writes, not what you can look at.

**RED first** (`evidence/.../R2_red_s2_recommendation.txt`): with the old rule
restored and everything else in place, 4 of the 8 new tests fail —

```
RecommendThePrintedObjectTests.swift:65: XCTAssertEqualWithAccuracy failed:
  ("360.3037702411583") is not equal to ("215.16") +/- ("0.01")
  - …the lightest of the four latticed objects, on the vf=0.68 rung
```

---

## 6 · S3 — the `out/` cleanup, gated

Full scope: `evidence/.../s3_cleanup_scope.md`. **Nothing is deleted in this
branch.**

### (a) The test that satisfies your condition, by name

```
LatticesAreInTheAppGateTests
  .testEveryLatticeAnOptimizeRunProducedIsListedWeighedAndExportable
```

It drives your run through the app's real `RemoteRun` over a real HTTP socket and,
for **all four rungs**, asserts the lattice is LISTED (its own tab, tied to its
rung), WEIGHED (its own `lattice_mass_grams`, asserted **not** to be the solid's)
and EXPORTABLE (Export writes that rung's file **byte for byte**, under a name
that cannot collide). With a positive control: the four fixture meshes are
pairwise different bytes at the same length, so a wrong-rung export cannot pass.

It does **not** claim a lattice can be *displayed* — none of yours fits on your
iPad, and export deliberately does not depend on display.

### (b) What a cleanup would do

Your Mac Mini's `~/.topopt-worker` holds **9.7 GB across 88 jobs**, of which
**8.99 GB (93 %) is 26 latticed STLs**. Everything else — designs, fields,
receipts, reports, solid meshes, models, logs — is 1.3 GB.

* **DELETE**: `variant_*_lattice.stl`, and only where `job.json`, the model and
  `out/design.bin` are all present. Measured: **8.75 GB of the 8.99 GB qualifies**;
  0.24 GB sits in three old jobs with no `design.bin` and must be excluded by the
  rule, not by hope.
* **KEEP, always**: `design.bin`, `job.json`, the model, `report.json`,
  `fields.bin`, every `variant_XXX_lattice.report.json`, the solid meshes,
  `loadcase.json`, `run_info.json`, `iterations.csv`, `build_orientation.json`.
  The app reads mass, margin and verdict off the **receipt**, never the mesh — so
  after deletion the variant list, the masses, the verdicts and the recommendation
  are all unchanged.

### ★ What becomes unrecoverable — measured

Rung 0.26 was regenerated from `{job.json, design.bin}` and compared with the file
your run wrote, triangle by triangle:

```
triangles: 14807216 vs 14807216
identical triangles : 12540748 (84.6935 %)
worst vertex coordinate difference : 1.52588e-05 mm (8.95e-06 of a voxel)
worst normal component difference  : 2.00249e-13
```

**The same object to within 15 nanometres; not the same bytes.** Four orders of
magnitude below your 0.42 mm line width. What is genuinely lost:

* **byte provenance** — a checksum taken against the original can never be
  re-satisfied. Nothing downstream pins one today (PR 312 enumerated every
  consumer);
* **the 0.24 GB with no `design.bin`** — genuinely gone if deleted;
* **time** — ~6 minutes per rung, the first time anyone wants that file back.

### ★ Which world the recommendation assumes

**It assumes S1 landed, and S1 is in this branch.** Before it, deletion was
destruction: nothing could remake those meshes — not the CLI, not the iPad. Now
all four do.

But the calculus is not "0.63 s". It is **8.75 GB of disk against ~6 minutes of
Mac time per rung**, which argues for a **retention policy, not a purge**: delete
only where the recipe is complete, only beyond an age and a keep-most-recent-K
window, and write a `lattice_meshes_reclaimed.json` naming each deleted file, its
size, its SHA-256 and the exact command that rebuilds it.

**And one piece of real work comes first:** the app's Export must learn to
materialise on demand when the worker answers 404 for a reclaimed mesh. Until it
does, a reclaimed mesh means Export fails on that variant. That is the one
user-visible consequence, and it is why this is scoped rather than shipped.

### (c) Your 5.17 GB

**Still on the Mac Mini**, `~/.topopt-worker/ca62f91cba4b422d/out`, four files,
5,174,159,336 bytes. Its recipe is complete — `job.json` (971 B),
`M2_verticalStand.step` (229,557 B) and `design.bin` (14,983,608 B): **15.2 MB
against 5.17 GB** — and all four rungs have been rebuilt from exactly those three
files in this task, with matching triangle counts, masses, margins and verdicts.

To remove it safely by hand today:

```bash
ls -l ~/.topopt-worker/ca62f91cba4b422d/{job.json,M2_verticalStand.step} \
      ~/.topopt-worker/ca62f91cba4b422d/out/design.bin
```

```bash
cd ~/.topopt-worker/ca62f91cba4b422d/out && shasum -a 256 variant_*_lattice.stl > lattice_meshes_reclaimed.sha256 && ls -l variant_*_lattice.stl >> lattice_meshes_reclaimed.sha256
```

```bash
rm ~/.topopt-worker/ca62f91cba4b422d/out/variant_*_lattice.stl
```

Keep the four `variant_XXX_lattice.report.json` receipts (10 kB each) — they are
what the app reads. To rebuild any one, use
`evidence/2026-08-08-lattice-variant-margin-tolerance/s1cd_materialise.sh`
(≈6 min/rung; 22 GB free for all four).

Two caveats, not buried: the rebuilt file is the same object but **not the same
bytes**, so those checksums record what was there rather than letting you prove
you got it back — and until the Export-materialises-on-demand work above exists,
Export on those four variants fails after deletion.

---

## 7 · Bars

| bar | status |
|---|---|
| **R1** byte-identical where nothing changed | ✅ stash-rebuild against `966ffa6`, **with a base-vs-base control** separating the wall clock from real change. Non-lattice run: 8 files byte-identical, 3 clock-only, **0 unexpected**. Lattice run: 12 byte-identical, 3 clock-only, 4 expected (the three added receipt keys), **0 unexpected**. Guarded by asserting the two binaries differ. `evidence/.../R1_byte_identity.txt` |
| **R2** failing test first, S1 and S2 | ✅ §3 (his run, 4/4 refusing, verbatim) and §5 (4 app tests failing with the old rule restored). Both greens pasted |
| **R3** the tolerance is justified by a ROOT CAUSE | ✅ §1 — mechanism with file:line, a probe showing identical inputs, a falsifier on a second fixture, and an in-process reproduction as a test. The band is `100 × cg_tolerance`, derived from the cause |
| **R4** no verdict moves | ✅ `evidence/.../R4_no_verdict_moves.txt` — every rung's accept verdict, every `lattice_accepted`, every lattice mass, recorded vs on-demand. Nothing differs |
| **R5** never weaken or delete an assertion | ✅ census in `evidence/.../R5_assertion_census.txt`; the **two deliberate changes are reported in §2**, not buried; no assertion kind fell in either tree; no core message disappeared |
| **R6** root cause with file and line; no placeholders; no scratch at root | ✅ §1; `git diff` introduces no TODO/FIXME/PLACEHOLDER; `git status` clean at the repo root |
| **R7** separate commit for any review response | pending review |

**Suites.** core `ctest` **115/115** (CI's 114 + the one this task adds), configured
`-DTOPOPT_REQUIRE_DEPS=ON` with lib3mf so the denominator is CI's. app
`swift test` **1377 tests, 8 failures** — the 3 pre-existing `AppModelTests` 3MF
cases, proven pre-existing by parking every new file **and** stashing every app
source change and re-running those three alone. (Provisioning lib3mf in this
worktree breaks the test-bundle link; tried and reverted.)

---

## 8 · Files

**New**

| file | what |
|---|---|
| `core/tests/unit/test_margin_reproduction.cpp` | the predicate + the in-process reproduction of the divergence (ctest `margin_reproduction`) |
| `app/.../Tests/TopOptFlowsTests/HisRunReplay.swift` | his run, replayed through the real `RemoteRun`, as a shared helper with a lattice-refusal option and a live-worker mode |
| `app/.../Tests/TopOptFlowsTests/RecommendThePrintedObjectTests.swift` | 8 tests — the rule, the acceptance condition, the copy, the guard rails |
| `app/.../Tests/TopOptFlowsTests/LatticesAreInTheAppGateTests.swift` | the S3 gate: listed, weighed, exportable, all four rungs |

**Changed**

`core/include/topopt/analyze.hpp` (the band, its derivation, `margin_reproduces`) ·
`core/src/simp/analyze.cpp` (the implementation; the false "stateless" comment
corrected) · `core/include/topopt/job.hpp` (`reproduction_within_band`,
`reproduction_relative_delta`, `reproduction_band`) · `core/src/cli/run_job.cpp`
(both call sites, the three receipt keys, the provenance block, the refusal
message) · `core/CMakeLists.txt` (the new test) ·
`core/tests/unit/test_analyze_fixed_design.cpp` (comment only — names the
condition its claim depends on; no assertion touched) ·
`ResultsModel.swift` (`PrintedObject`, `printedObjectPerRung`, `recommendation`,
`recommendationLine`, `buildTabs`, `latticedTab`) · `ResultsScreen.swift`
(`recommendationCaption`) · `LatticeVariantsOnScreenTests.swift` (2 tests
re-pinned) · `LatticeVariantsHisRunEvidence.swift` (follows the new
recommendation).

---

## 9 · Open

1. **Export must materialise on demand** before any `out/` cleanup ships (§6). It
   is the largest remaining piece and it is not started.
2. **The re-lattice path runs four certification solves.** Three are proofs. If
   6 minutes per rung is too slow to make deferral attractive, that is the lever —
   not the generator.
3. **The band is per-call, from `cg_tolerance`.** If a future posture ever
   certifies at a looser tolerance, the band widens with it automatically. That is
   intended, and it is asserted nowhere; if it should be capped, say so.
4. **PR 311's open items stand**: the device-QA read of
   `LatticeMeshBudget.logDecision` off the iPad, and displaying a latticed mesh on
   an iPad at all.

---

## In plain language

**Which variant the app will now recommend, and what it weighs.**

It will recommend the **latticed version of your first rung — the −20 % one — and
it weighs 215 grams.** Before today it recommended the last rung's solid at 360
grams. The two objects are not comparable as printed things: if you had followed
the old recommendation and tapped Export on that rung's lattice, you would have
printed 246 grams. So the change is worth **31 grams, about 13 %**, and it is
exactly the number I reported last time and said was yours to rule on. You ruled:
rank by mass. This ranks the object that actually comes off the printer — the
lattice where the lattice passed its own certification, the solid where it did
not — and the card now says in words which of the two it means, and what the
other one weighs, so 215 g and 544 g can never be confused.

One honest cost: the lightest lattice happens to sit on the biggest file, 1.95 GB
instead of 740 MB. On your iPad you could not spin either of them around anyway,
so this changes what Export writes, not what you can look at.

**Whether your 5.1 GB can be deleted yet.**

**Yes — carefully, by hand, and §6(c) has the three commands.** What changed is
that the machine that rebuilds those files was refusing to touch your run at all,
and now it doesn't. I pointed it at all four rungs and all four came back, with
the same triangle counts, the same weights, the same safety margins and the same
verdicts.

Three things you should know before you do it.

The rebuilt file is the same shape but not the same bytes. I checked it triangle
by triangle: same number of triangles, 85 % of them bit-identical, and the worst
corner anywhere is fifteen millionths of a millimetre out of place. Your nozzle is
0.42 mm wide. It is the same object by any measure that matters — but a checksum
you write down today will never match again.

It is not 0.63 seconds. That figure was from a much smaller test run, and I should
say so plainly rather than let it stand. Rebuilding one of your rungs takes about
six minutes. The geometry itself really is about one percent of that, exactly as
reported — the rest is that the rebuild re-checks the strength of the design four
times over before it will write anything. So the trade is disk space against about
six minutes of Mac time, the first time you want that file back.

And the app's Export button does not yet know how to rebuild a file that has been
deleted. It will simply fail on that variant. Everything else — the list, the
weights, the margins, the verdicts, the recommendation — reads the small receipt
files, not the giant meshes, and is completely unaffected. Teaching Export to
rebuild on demand is the one real piece of work standing between "delete it by
hand" and "the worker cleans up after itself", and I have not started it, because
deleting things automatically before that exists would take away the button you
actually use.
