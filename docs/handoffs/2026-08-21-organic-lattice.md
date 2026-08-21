# The third lattice algorithm, and a selector for all three

**Base commit: `2e718ad1`** — PR **347**'s HEAD, which carries 344 + 345 + 346.
Rebased, not cherry-picked. (The earlier base was `d28527cc`; §0 explained why 346 was
deliberately not pulled mid-task, and that decision is now spent — 347 is in.)

Scope: **core/**. No UI, no settings row (§6a). Schema + CLI only.

## ★ THE REBASE ONTO 347 — ADDED AFTER REVIEW

**New base: `2e718ad1`.** One conflict, in `observability.hpp`, purely additive — 347
added its re-certification and layer-height fields where this task adds the algorithm
and organic blocks. Both kept. Core suite **122/122** on the rebased tree.

**Which of my reported numbers moved: none.** Every figure in R3, R5, R6 and R10 re-run
and identical — spacing 1.5020 / 5.9606 / median 3.0854, connectivity 99.9875 % with
2.032 mm stranded, 584 curves, soup volumes to the last digit. Full table in
`r15_r21_rebase_remeasure.txt`, **including why** each of 347's three changes is inert
here: the second solve is structural-only and organic refuses structural; layer height
is derived **from** the emitted strut, not an input **to** the tracer; and the default
aesthetic range only moves the *default*, which every job here overrides explicitly.

**The latticed margin (R17), his part, his nine regions, his 0.42 mm bead:**

| | lattice solid vol | margin solid → latticed | spent | strut peak vM |
|---|---|---|---|---|
| doubled | 1004.46 mm³ | 3242.279 → 2272.907 | 29.9 % | 0.00406431 MPa |
| stepped | 1004.46 mm³ | 3242.279 → 2272.907 | 29.9 % | 0.00406431 MPa |
| **organic** | **797.56 mm³** | 3242.279 → **2053.597** | **36.7 %** | **0.00145738 MPa** |

★ **Organic spends materially more margin — 6.8 points.** Per §4(c) that is a finding
about the method, and here it is. **The confound is stated with it:** organic put in
**20.6 % less material**, and less material is a softer load path, which raises stress
in the solid region — and that margin *is* the solid region's. So part of the 6.8 points
is less mass, not worse mass.

★ **And the number pointing the other way is the Daynes effect showing up:** organic's
own struts carry **2.8× less stress** (0.00145738 vs 0.00406431 MPa) while carrying 20.6 %
less material. That is precisely the claim that aligning struts with the principal
directions makes each one work less hard.

★ **What this does not settle.** It is **not** a matched-density comparison, so it does
not establish organic as more or less efficient than the octet cell. §4(d)'s question —
is organic worth its complexity structurally — needs a **matched-mass** run that nobody
has done.

★ **Doubled and stepped certify identically, to the last digit, by construction.** The
homogenised tensor is a function of relative density alone and both take their density
from the same law; only the cell differs, and the cell does not enter the tensor. Their
difference is purely geometric (soup 2168.76 vs 3084.84 mm³ for the same certified
object).

**The welded body after the rebase (R18):** all three **watertight and 2-manifold** —
0 boundary edges, 0 non-manifold edges, measured by an independent edge-use census on
the written file rather than read off the generator's own report.

---

> ★ **READ `x1_geometry_path_defects.txt` FIRST IF YOU READ NOTHING ELSE.** The first
> version of this task passed every bar it set and produced files with no lattice in
> them. The maintainer found that by slicing them. Everything below is after that.

---

## SECTION 0 — the answers, one line each

**The three CLI invocations.** From `evidence/2026-08-21-organic-lattice/cube/`, three
job files differing in **exactly one line** (`grading.algorithm`):

```
core/build/topopt-cli lattice-variant final_doubled.json --out ../ship_doubled
core/build/topopt-cli lattice-variant final_stepped.json --out ../ship_stepped
core/build/topopt-cli lattice-variant final_organic.json --out ../ship_organic
```

**Did organic produce a connected lattice (R3).** **Yes — 99.99 % of the emitted length
in ONE component, 2.0 mm stranded of ~14,400 mm.** Measured three times over: the traced
curves, the spans after boundary clipping, and the welded body. ★ The FIRST version of
R3 counted edges in a curve-graph I had built and reported "1 component, 100 %" on a file
whose solids were in thousands of pieces. That metric is gone.

**Is the exported mesh watertight and manifold (R4).** The soup is closed (zero boundary
edges) and outward-wound — signed volume equals the analytic sum to the last digit — but
it is **not one object**: it is thousands of interpenetrating closed shells, exactly as
the shipped octet export has always been. **So this task adds a WELDED single-body
output**, and that is the file a slicer should be given.

**The achieved spacing window (R5).** Requested 3.00–6.00 mm; **achieved 1.50–5.96 mm,
median 3.09**. The undershoot is Jobard-Lefer's own stop rule (`d_test = 0.5 x d_sep`).

**What fraction the overhang clamp touched (R6).** Default is **disarmed** — the
maintainer's coupon printed a 41.78 mm unsupported run clean. Counterfactual reported
regardless: **66.6 %** of traced segments sit outside a 45-degree cone. Armed at 45,
**exactly 0.000000** remain.

**The three-way comparison (R10).** `r10_three_way_comparison.txt`.

**★ AND THE ONE THAT MATTERS: MEASURED AGAINST HIS OWN PRINTED COUPON.**

| | triangles | volume | solid fraction |
|---|---|---|---|
| his printed coupon | 1,451,500 | 4,110.3 mm³ | 6.05 % |
| **organic, welded, default pitch** | 4,152,700 | **4,031.9 mm³** | **6.30 %** |

Same 40 mm envelope, same 0.42 mm bead. **Within 2 %.**

---

## THE METHOD

### §1 — the tracer (`organic_lattice.hpp`, `src/mesh/organic_lattice.cpp`)

**(a) Eigen-decompose.** Cyclic Jacobi, fixed sweeps, fixed pivot order. Chosen over the
closed-form solution because the analytic form loses orthogonality near a degenerate
pair, which is where a stress field spends its time. Sign-canonicalised, or the field is
a line field whose sign flips voxel to voxel. Cost, timed directly: **0.22 s**.

**(b) RK4** on a trilinear, sign-aligned direction field.

**(c) ★ SPACING IS THE INPUT — AND THE JOB'S SWEPT WINDOW IS WHAT SETS IT.**
`cell_min_mm`/`cell_max_mm` are organic's separation range. The grading law's own density
decides where in that window each voxel sits; the **bead falls out** of the mass coupling
`t = 2 d sqrt(rho / 3 pi)`, floored at the stated minimum extrudable width.

★ The first version had this backwards — constant bead, spacing derived — so the window
was **silently ignored**. A job asking for 5–10 mm cells got 0.6–2.0 mm separation and a
**2.76 GB** mesh carrying 27x the part's own volume. The task spec said it plainly:
*"spacing as the input, cell size derived from the spacing."* Confirmed against the
reference variable-density implementation (`adaptive-streamlines`, from Jobard-Lefer),
which takes `minStartDist`/`maxStartDist` — a window — with a density function choosing
within it, and `endRatio` = d_test/d_sep in (0,1).

**(d) Connect** at every near-approach, refined to the mutual nearest pair — which is
what restores Daynes' cross-product direction (measured 0.000 deg on the fixture; the
station search alone reads 78 deg off it).

**(e) Thin** in descending length.

**(f) ★ STOP ORBITING.** `vtkEvenlySpacedStreamlines2D` carries `LoopAngle` and a
closed-loop distance; mine had neither. **Eight curves were spiralling and held 83 % of
all traced length** — 1,683 mm each in a 40 mm cube. Now: a full revolution of
accumulated turning, or crossing its own trail, ends the curve.

**(g) ★ CALIBRATE THE BEAD TO THE LENGTH ACTUALLY TRACED.** The coupling assumes three
perfectly orthogonal families on a box; the real lattice bends, and connectors add length
the model never counted. Solved by Newton on `k^2*P + k^3*N = target` — prisms scale as
k², node balls as k³, and **the node balls are a quarter of the emitted solid**. On the
cube it converges to **k = 1.0000**: the coupling was right, and it was the *accounting*
that was wrong.

### §2 — the constraints, in the loop
Overhang projected onto the nearest in-cone direction **during** tracing, never repaired
after. `min_extrudable_width_mm` = 0 means UNSET and refuses. **Two floors on the
separation**: printability `d >= t sqrt(3 pi)/2`, and the one nobody had named — the
**RESOLUTION floor**, one voxel, because the tracer cannot place curves closer than the
grid samples the field they follow.

### §3 — certification
`curves_per_member = member_width / spacing`, reported under its **own** name;
`cell_size_field` is left **empty** for organic on purpose, or the certification's
cells-per-member guard would be silently re-pointed at it. Floor 2 (percolation), not 5 —
there is no homogenised tensor for traced geometry, so no accuracy claim to floor.
**Organic requires `"intent": "aesthetic"` stated explicitly** and throws otherwise.

### §4 — the selector and the welded body
`LatticeAlgorithm {Doubled, Stepped, Organic}`, orthogonal to `CellSizeMode`. Absent key
= `doubled`. All three emit a per-voxel density (`r8_density_consumer_census.txt`).

**`lattice.emit_welded_stl` / `lattice.welded_pitch_mm`** (both default-off) write
`<prefix>_lattice_WELDED.stl`: the emitted spans rasterised and marched into ONE
watertight body, largest component kept. **Available to all three algorithms.** Not
cosmetic — the coupon harness's own note says a slicer analysing the MESH reports every
shell that misses the plate as a FLOATING BODY, which is exactly what the maintainer saw.

---

## ★ WHAT WENT WRONG, AND WHAT FOUND IT

Nine defects. **Not one was found by a bar I wrote.**

| # | defect | found by |
|---|---|---|
| 1 | per-voxel density was a binary occupancy, 8x high | positive control vs hand arithmetic |
| 2 | two of three families never traced (`[28, 534, 0]`) | reading my own diagnostics |
| 3 | one connector per curve PAIR, not per near-approach | the R3 number |
| 4 | `LatticeClipSpan` read as a fraction; it is **millimetres** | the codebase's no-protrusion invariant |
| 5 | node balls unguarded at clipped ends | same invariant |
| 6 | **the swept window never reached organic** | **the maintainer** |
| 7 | **the aesthetic band never reached the geometry path** | **the maintainer** |
| 8 | **no loop detection — 8 curves held 83 % of the length** | **the maintainer's print** |
| 9 | **R3 measured a graph I invented, not the geometry** | **the maintainer slicing the file** |

★ 6 through 9 were found by a person looking at the output. The deepest is 9: I built the
validation out of the same wrong idea as the code, so every bar passed while the thing
was broken. **A metric that shares the implementation's model cannot falsify it.**

---

## BARS

| bar | status |
|---|---|
| R1 three algorithms from the CLI | **done** — one key apart |
| R2 doubled/stepped byte-identical | **done, and re-run after the intent change** — on the GEOMETRY path with no intent stated, `variant_070_lattice.stl` is **byte-identical** to the base binary's. `run_info.json` gains 3 additive fields + timestamp. Binary-differ guard run first |
| R3 connectivity | **done, on a rebuilt metric** — 99.99 % largest, 2.0 mm stranded |
| R4 watertight + manifold | **done** — closed and outward-wound; NOT one object as a soup, which is why the welded body exists |
| R5 achieved spacing | **done** — 1.50–5.96 mm vs 3.00–6.00 requested |
| R6 overhang at default and 45 | **done** — 0 % / 66.6 % counterfactual / exactly 0 armed |
| R7 curve-crossing count | **done**, under its own name |
| R8 per-voxel density, consumers | **done** — 11-entry census |
| R9 determinism | **done** — see `r9_determinism.txt` |
| R10 three-way table | **done** |
| R11 no no-go without §0 | **n/a** — not a no-go |
| R12 no assertion weakened | **done** — 0 removed |
| R13 cost measured directly | **done** — tracer timed alone at 0.22 s; `CMAKE_BUILD_TYPE=Release` |
| R14 no placeholders, no root scratch | **done** |

Core suite: **122/122** (three slow tests excluded for time; a full 125/125 pass was
recorded earlier in the task).

---

## ★ WHAT IS NOT DONE, PLAINLY

* **1,450 of 1,541 traced curves are binned as too short.** The lattice that survives is
  correct, but 94 % waste means the seeding is wrong somewhere. Unexplained.
* **No unit tests.** Two standalone probes carry the positive controls. Thinner than this
  codebase's norm and a reviewer should say so.
* **Organic's skin is anchor balls only** — no diagrid. `outer_finish: "skin"` works
  because the anchors satisfy the M4 guard, but organic has no true skin pass.
* **STEPPED is new here and measured, not endorsed.** 4 of 5 abutting region pairs are
  mechanically disconnected — the cost of no transition handling, which is exactly why
  DOUBLED's dyadic ladder exists.
* **A pre-existing throw, twice sighted.** `plan_cell_sizes: level assignment is not an
  aligned octree` on the maintainer's part at the default band AND on a 40 mm cube at
  band `[0.1, 0.35]` — which PR 346 characterises as fine, so it is broader than that PR
  says. Owned by PR 346, not fixed here (§6b forbids changing DOUBLED).

---

## PLAIN LANGUAGE

There are three ways to fill a part with lattice now, chosen from the job file. A job
that says nothing gets exactly what it got yesterday — proved by running the old program
and the new one on the same job and comparing the files byte for byte.

**Doubled** is what you had: cubic cells that change size by doubling, so their corners
land on each other and the struts meet.

**Stepped** gives each region its own cell size and skips the doubling. The price is now
a number: of the five places two regions touch, the struts meet at **one**.

**Organic** traces curves along the stress, like iron filings around a magnet, packed
closer where the part works harder. On a 40 mm test cube it lands **within 2 % of the
coupon you printed** — 4,031.9 mm³ against 4,110.3.

Two things worth keeping. The lattice is a pile of overlapping tubes, and a slicer that
looks at the *mesh* rather than the solid calls every tube that doesn't touch the plate a
floating body — that's what you saw. There's now a second file that is one welded object.
And the honest headline: **nine things were wrong with this, and the last four were found
by you looking at the output, not by any check I wrote.** The check I was most confident
in was measuring a diagram I'd drawn rather than the thing that gets printed.
