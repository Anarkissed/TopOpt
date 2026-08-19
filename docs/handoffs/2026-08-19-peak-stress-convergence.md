# peak-stress-convergence — does the certificate's peak stress converge on a smooth boundary?

Task: `peak-stress-convergence`. Branch `claude/peak-stress-convergence-dd008c`,
merge base `93202ea6` (against `origin/main`). Evidence:
`evidence/2026-08-19-peak-stress-convergence/`.
Machine: **Apple M2 Pro, 10 cores, 16 GB, macOS.** Build: **Release**
(`CMAKE_BUILD_TYPE:STRING=Release` in `core/build/CMakeCache.txt`), verified
before any wall clock below was quoted (R8).

**MEASUREMENT ONLY. No production default moved** — the tracked diff is two new
`EXCLUDE_FROM_ALL` harnesses and the CMake blocks declaring them; `topopt-cli` is
byte-identical to the merge base (R6). `materials.json` untouched.

---

## Section 0 — the answers, one line each

| | |
|---|---|
| **q on the smooth boundary** | **Between 0.00 and 0.25, depending how far from the load pads you look — never 0.45.** On the level-set-controlled cells ≥5 mm clear of the voxel-specified pads, `q = +0.015` (R² 0.39, ACTIVE) and `q = −0.033` (R² 0.22, CUT): no power law, a 2.6–7.7 % spread over a 3× refinement. Deeper in, ≥20 mm, it is `q = +0.124` (CUT) and `q = +0.245` (ACTIVE) — small, but a clean rise, not zero. Against PR 320's **0.4945 → 0.4391** and the re-entrant corner's **0.4555**. |
| **but the number the certificate reads did NOT converge** | `q = +0.5510`, R² **0.9911** — a textbook power law, squarely in PR 320's regime. ★ **It is not the level set.** At every rung, in every arm, the peak sits on a voxel the mask stamped `FrozenSolid` — the anchor pad, the load pad, the face protection. Those are a CAD-tagged voxel staircase the design never touched. |
| **did the staircase control reproduce PR 320?** | **Yes, where the peak sits on it.** The pads ARE a staircase frozen at one resolution with the elements around it shrinking — PR 320's construction exactly — and they give `q = +0.5641` (R² 0.9932) in the staircase arm and `+0.5510` (R² 0.9911) in the smooth arm, because both arms stamp them identically. Where the peak is NOT on a staircase corner (the active region ≥5 mm out) a frozen staircase gives only `q = +0.0757`, R² 0.9973. |
| **the certified margin** | 1726.75 (res 96) → 1233.29 (192) → **934.53** (288), a **61.03 %** spread of the mean, on geometry that did not change by 0.01 %. `accepted` at every rung (margin_effective 357.5 → 193.5 against `margin_stop` 1.5). |
| **the positive control** | On a spherical cavity with a KNOWN finite concentration, the same instrument returns **q = −0.000000, spread 0.000 %** with no cavity (exact answer), and on the cavity the fraction ersatz **turns over and converges** — K = 2.1986 / 2.1769 / 2.1624 on the top three rungs, pairwise q **−0.044, −0.037**, spread 1.66 %, against Southwell's 2.0607 — while the staircase of the same sphere is still climbing at +0.116. |
| **★ would a hand-smoothed change be distinguishable from grid noise?** | **On this job, no — and not because of grid noise. The margin does not read the surface the user would be smoothing.** It reads the peak in the anchor/load pads, which a design-surface edit does not touch; and that peak is mesh-set (q = 0.55, the margin moving 61 % across a 3× refinement of an unchanged solid). The surface the user WOULD move has a peak that is stable to 2.6–7.7 % — so the sculpting comparison is possible in principle, but only against a peak restricted to the sculpted region, not against `margin.worst_case`. |

---

## Section 1 — what was measured, and the one thing that had to be fixed first

### The design is `alpha`, and it is one file

Worker job `4f8a5fc335a44253` — the maintainer's own `M2_verticalStand.step`,
PLA, resolution 128, `plsm=true`, fingerprint `c618a90a3a72`, run 2026-08-11 —
rung **0.68**, the rung PR 320 headlined. The analytic design is
`out/variant_068_alpha.f64`, 85,680 float64,
`sha256 4055c941e1030aee606d6904737f2b4ada285582190913d8316ff83d686e403b`, with
`.meta` `sha256 c71536c6…` beside it. Every rung of every arm read that one file.

`phi(x) = Σ alpha_i psi(|x − x_i|_R)` is a function of position with no lattice of
its own once the knots are placed, so the probe **re-evaluates it** on each solve
grid rather than resampling any density field. A point `P` maps into the design's
frame by `u = (P − origin0)/spacing0 − 0.5`; `voxelize` puts the origin at the
model bbox min, so every resolution of one model shares it, and the probe asserts
that bit-for-bit rather than assuming it
(`core/tests/harness/smooth_convergence_probe.cpp`, the frame check).

**One caveat, stated plainly.** The `.meta` says
`# the ersatz is plsm_heaviside(-phi, eta_voxels * spacing)`: this design was
*optimised* under H_eta at `eta_voxels = 2`, because both PLSM jobs on this
machine carrying an alpha export are from 2026-08-11 and the volume fraction
became the production default on 2026-08-13. §4(c) forbids re-optimising, so a
fraction-optimised design was not available inside this task. What it changes:
nothing about the geometry claim — `{phi<0}` is an analytic surface either way and
re-evaluating it is exact at every rung — and nothing about the certification,
which uses the production exact-volume-fraction ersatz in every arm as §1(c) asks.
What it does change is that the design was *steered* by a slightly different
objective than today's default would steer it by.

### ★ The first sweep was void, and finding out why is half the result

The obvious sweep — `build_production_loadcase` at 64, 80, 96, 112, 128, 144, 160,
192 — was run first, in both arms
(`evidence/.../raw/pre_split/`, `s2_retag.csv`). It cannot measure convergence,
and the reason is not subtle:

* **the anchor pad's depth is specified in VOXELS** (`[loadcase] anchor-pad
  depth=3`), so it is 3 × 3.41 = **10.2 mm** thick at resolution 64 and 3 × 1.14 =
  **3.4 mm** at 192. The frozen-stamped volume falls from **344,268 mm³** at 64 to
  **200,087 mm³** at 128. A resolution sweep in this mode certifies a *different
  physical solid* at every rung, which is exactly what §1(b) forbids.
* and the global peak was not monotone in `h` at all — 0.04524, 0.03600, 0.03185,
  **0.07300**, 0.02290, 0.03598, 0.04971 MPa — with the smooth and staircase arms
  agreeing to within 1 % at every rung, because the peak was in the frozen set
  where the two arms are identical by construction.

So S1 was rebuilt as a **replicate** sweep, which is PR 320's own reference
construction: the load case is built ONCE at resolution 96 and the grid is then
subdivided 1× / 2× / 3× child-for-child. The tags, the mask, the pads and the
protection are one physical solid at every rung; the Dirichlet set is rebuilt by
the production rule and the traction by the production call; **only the element
size changes.** The retag sweep is kept and reported as S2 — it prices something
real (what a re-certification at another resolution returns) — and is never mixed
with S1.

### And the population filter had to be anchored too

Isolating the level set means excluding the pads, which needs a distance gate. A
chamfer computed *per solve grid* is quantised to that grid's own `h`, so the
band edge moves by O(h) and — where the stress gradient across it is steep, as it
is beside a load introduction — the gated peak inherits the movement. It did: the
10 mm gate came out at `q = +1.4834` with the 5 mm and 20 mm gates either side of
it flat, and **+1.48 is steeper than any elastic corner exponent in two or three
dimensions**, so it could not be a singularity. The distance field is now computed
on the BASE grid and read through the parent index, so the gate is the same
physical region at every rung. `evidence/.../raw/pre_stable_gate/NOTE.md` keeps
that pass and says what it showed.

*(The 10 mm gate's steep rise survives the fix — see §3 — so it is a real feature
of the field and not the filter. It is reported, not explained away.)*

---

## Section 2 — S1, the convergence measurement

Base resolution 96, refine 1× / 2× / 3× → effective **96 / 192 / 288**, spacing
2.27371 / 1.13685 / 0.75790 mm, 0.65 M / 5.02 M / 16.77 M DOF.

### (a) R1 — the geometry is identical at every rung, and here is the invariant

The invariant is the enclosed volume of `{phi < 0}` inside the part, computed with
the mask ignored — a property of `alpha` and the part occupancy and nothing else —
and the frozen-stamped volume beside it, which is the other half of the certified
object.

| res | `{phi<0}` in part, mm³ | ACTIVE mm³ | frozen-stamped mm³ | certified mm³ | cut cells |
|---|---|---|---|---|---|
| 96 | 384,979.6661 | 192,913.16 | 235,629.9541382419 | 428,543.11 | 2,460 |
| 192 | 385,009.9892 | 192,933.80 | 235,629.9541382352 | 428,563.76 | 9,986 |
| 288 | 385,018.4200 | 192,939.62 | 235,629.9541405098 | 428,569.57 | 22,433 |

**Spread of the `{phi<0}` volume: 0.010 %. Spread of the certified volume:
0.006 %** (and **0.000 %** in the `stair_base` arm, whose occupancy is replicated
so its object is bit-identical at every rung). The frozen volume agrees to nine
significant figures because replicate mode subdivides one solid. The cut-cell
count grows 4.06× then 2.25× — `h⁻²` to two figures, which is what a surface
population must do.

### (b) The table

`frac` — the production exact-volume-fraction ersatz:

| res | ALL (the gate) | FROZEN | ACTIVE | CUT | ACTIVE ≥5 mm | CUT ≥5 mm | ACTIVE ≥20 mm | CUT ≥20 mm | margin | analyze wall |
|---|---|---|---|---|---|---|---|---|---|---|
| 96 | 0.031852 | 0.031852 | 0.019032 | 0.019032 | 0.0158512 | 0.0158512 | 0.0058387 | 0.0015737 | 1726.747 | 11.0 s |
| 192 | 0.044596 | 0.044596 | 0.024326 | 0.024326 | 0.0157544 | 0.0146723 | 0.0069182 | 0.0017662 | 1233.293 | 143.9 s |
| 288 | 0.058853 | 0.058853 | 0.032776 | 0.032776 | 0.0161730 | 0.0154443 | 0.0076391 | 0.0017925 | 934.526 | 754.0 s |

(MPa. `ALL` = `FROZEN` and `ACTIVE` = `CUT` at every rung because the peak of each
larger population is attained inside the smaller one — the peak of the whole part
is on a pad, and the peak of the level set's cells is on a cut cell.)

### (c) R3 — q, fitted, against 0.4945 / 0.4391 / 0.4555

Pairwise is PR 320's form; the global fit carries its R² beside it because **a
global slope with a poor R² is not a power law.**

| population | pairwise q | global q | R² | spread |
|---|---|---|---|---|
| **ALL — what the gate reads** | +0.4855, +0.6842 | **+0.5510** | **0.9911** | 59.9 % |
| FROZEN — the pads | +0.4855, +0.6842 | +0.5510 | 0.9911 | 59.9 % |
| ACTIVE, ungated (= CUT here) | +0.3540, +0.7354 | +0.4796 | 0.9581 | 54.2 % |
| **ACTIVE ≥5 mm from pads** | −0.0088, +0.0647 | **+0.0154** | 0.3877 | **2.63 %** |
| **CUT ≥5 mm from pads** | −0.1115, +0.1265 | **−0.0331** | 0.2190 | **7.69 %** |
| CUT ≥10 mm | +1.7295, +0.9824 | +1.4834 | 0.9828 | 128 % |
| ACTIVE ≥20 mm | +0.2448, +0.2445 | +0.2447 | **1.0000** | 26.5 % |
| CUT ≥20 mm | +0.1665, +0.0364 | +0.1237 | 0.9290 | 12.8 % |
| **compliance — THE CONTROL** | +0.0110, +0.0047 | +0.0089 | — | **0.95 %** |

**The compliance control is what says the solve is sound**: 0.0035746 → 0.0036019
→ 0.0036087 N·mm, 0.95 % over the whole ladder, in the textbook direction. PR 320
used the same control for the same reason — a wrong load, a wrong clamp or an
unconverged CG would have moved compliance too. It did not.

### (d) R2 — the staircase negative control

The `stair_base` arm reads the SAME phi as a hard 0/1 occupancy at the **base**
grid's cell centres and replicates it down, so its staircase is frozen at
`h = 2.27 mm` and only the elements resolving it shrink. That is precisely what
PR 320 did to a stored `design.bin`.

| population | `frac` global q (R²) | `stair_base` global q (R²) |
|---|---|---|
| ALL / FROZEN | +0.5510 (0.9911) | **+0.5641 (0.9932)** |
| ACTIVE, ungated | +0.4796 (0.9581) | +0.0921 (0.9878) |
| CUT, ungated | +0.4796 (0.9581) | +0.3006 (0.9976) |
| ACTIVE ≥5 mm | +0.0154 (0.3877) | +0.0757 (0.9973) |
| CUT ≥5 mm | −0.0331 (0.2190) | +0.3007 (0.8289) |
| ACTIVE ≥20 mm | +0.2447 (1.0000) | +0.2419 (1.0000) |
| CUT ≥20 mm | +0.1237 (0.9290) | +0.1687 (0.8521) |

**The control passes, and it passes on the object that is a replicated
staircase.** The pads give `q = 0.5641 / 0.5510` with R² = 0.99 — the same regime
as PR 320's 0.4945 → 0.4391, a little above the corner's 0.4555. So this sweep IS
measuring what PR 320 measured, and §2(a)'s escape hatch is not triggered.

Two honest qualifications. First, the pads are identical in *both* arms, so that
control is a **population** contrast (staircase object vs analytic object measured
in one solve), not an arm contrast. Second, the arm contrast — `stair_base` vs
`frac` on the same CUT cells — is in the right direction and materially so
(+0.3007 vs −0.0331 at ≥5 mm) but is noisier, and where the peak of the active
region does not sit on a staircase corner a frozen staircase yields only
`q = +0.0757`, R² 0.9973. A singularity only shows when the peak is at it.

★ And the two arms **agree in the limit** where it matters: at ≥5 mm the ACTIVE
peaks are 0.0158512 vs 0.0148990 at res 96 (6.4 % apart) and 0.0161730 vs
0.0161809 at res 288 (**0.05 % apart**). The ersatz choice is a coarse-grid
difference that refines away.

### (e) R4 — the certified margin, and the noise floor it sets

| res | margin worst_case | margin effective | accepted |
|---|---|---|---|
| 96 | 1726.7472 | 357.5451 | true |
| 192 | 1233.2932 | 255.3691 | true |
| 288 | 934.5256 | 193.5055 | true |

**Spread 61.03 % of the mean** (`stair_base`: 62.47 %), on geometry whose enclosed
volume moved 0.010 %. `margin.worst_case` is `margin.in_plane` at every rung —
`yield / peak_von_mises`, exactly — so the margin's spread is the peak's spread
with the sign flipped, and the peak is the pads'.

**The noise floor a sculpting comparison inherits, by region:**

| what a re-certification at a different `h` moves | |
|---|---|
| `margin.worst_case`, replicate (S1 — the same solid, only `h` changes) | **61 %** |
| `margin.worst_case`, retag (S2 — what a re-certification actually does) | **119 %** |
| the peak over the level set's cells ≥5 mm from the pads | **2.6 %** (ACTIVE) / **7.7 %** (CUT) |
| the peak over the level set's cells ≥20 mm from the pads | 26.5 % / 12.8 % |
| compliance | 0.95 % |

---

## Section 3 — the one number that is not near zero, reported and not explained away

`CUT ≥10 mm` rises at `q = +1.4834`, R² 0.983, over a 128 % spread — 0.0016878 →
0.0055969 → 0.0083355 MPa — while the 5 mm gate that **contains** it is flat and
the 20 mm gate inside it moves 12.8 %. It survives anchoring the gate to the base
grid, so it is the field and not the filter.

What it is not: **+1.48 cannot be a corner singularity.** The strongest classical
elastic corner gives stress ~ r^−λ with λ ≤ 0.5 (0.5 is the crack tip; the
re-entrant 90° wedge is 0.4555). An exponent three times that is a different
mechanism.

What it plausibly is — named, not resolved here, because §4 forbids fixing
anything in this task:

* **a member crossing the printed iso.** The certificate's peak is taken over
  `density > 0.5`. `min_feature_mm` on this job is 2.5 mm, which is 1.1 voxels at
  `h = 2.27` and 3.3 at `h = 0.758`; a thin member whose exact volume fraction is
  0.4 at the coarse rung is **not in the population at all**, and enters it — at
  full stress — when it refines.
* **the centroid stress recovery on a 1-to-3-element-thick member**
  (`core/src/simp/analyze.cpp:355` recovers stress at the element centroid; task
  2026-08-08 measured 17–41 % of optimism from exactly this): the reading moves
  toward the free surface as the member gains elements through thickness.

Both would raise a *sub-region's* maximum toward the whole region's maximum
without the whole region's maximum moving — which is exactly the pattern in the
table: `CUT ≥10 mm` climbs from 11 % of the `≥5 mm` peak to 54 % of it and never
overtakes it.

---

## Section 4 — S3, the positive control

`core/tests/harness/cavity_convergence_probe.cpp`: a spherical cavity, R/L = 1/6,
in a 60 mm bar under uniform uniaxial tension, supported by a roller plane plus
exactly three scalar constraints — **no clamp**, because a Dirichlet-to-free
corner is itself singular and would put an unknown second singularity into the
control. Same ersatz, same arms, same `analyze_fixed_design`. Southwell & Gough's
infinite-medium concentration is `K = (27−15ν)/(2(7−5ν)) = 2.0607` at ν = 0.35.

| arm | K at 24 / 32 / 48 / 64 / 80 / 96 | global q (R²) | spread |
|---|---|---|---|
| **no cavity** (the control's own control) | 1.00013933 … 1.00013890 | **−0.0000000** | **0.000 %** |
| cavity, exact volume fraction | 1.8291, 2.0078, 2.1056, 2.1986, 2.1769, 2.1624 | +0.1180 (0.819) | 17.8 % |
| cavity, staircase | 1.7320, 1.8305, 2.0677, 2.0408, 2.1360, 2.1817 | +0.1642 (0.931) | 22.5 % |

**The no-cavity arm is exact to 1.4 × 10⁻⁴ and does not move in the seventh
decimal across a 4× refinement** — so the instrument (grid build → ersatz →
`analyze_fixed_design` → peak recovery → fit) returns zero when zero is the right
answer. That is what makes a near-zero exponent on his part believable rather than
merely quiet.

**On the cavity the fraction arm turns over and converges**: on the top three
rungs (R/h = 10.7, 13.3, 16.0) K = 2.1986 / 2.1769 / 2.1624, pairwise q **−0.0443,
−0.0368** — negative, i.e. falling toward a limit — with a **1.66 %** spread,
against Southwell's 2.0607 for an infinite medium (a finite bar is expected
slightly above). **The staircase of the same sphere is still climbing** at the top
of the same ladder: pairwise +0.2043, +0.1161, a 6.65 % spread over the same three
rungs. Same geometry, same solver, same load — only the boundary representation
differs, and only one of them has stopped moving.

---

## Section 5 — S2, what a re-certification at another resolution actually returns

Reported because it is what a user would hit, and labelled because it is **not** a
convergence measurement: the pads move with `h`, so the certified object moves.

The `frac` arm, `build_production_loadcase` run outright at eight resolutions:

| res | h mm | peak vM MPa | margin worst_case | frozen-stamped mm³ | `{phi<0}` mm³ |
|---|---|---|---|---|---|
| 64 | 3.41056 | 0.045245 | 1215.615 | 344,267.63 | 389,408.54 |
| 80 | 2.72845 | 0.035996 | 1527.947 | 289,705.94 | 379,797.63 |
| 96 | 2.27371 | 0.031852 | 1726.747 | 235,629.95 | 384,979.67 |
| 112 | 1.94889 | **0.072997** | 753.451 | 213,502.44 | 382,817.64 |
| 128 | 1.70528 | **0.022898** | **2402.001** | 200,087.21 | 392,112.60 |
| 144 | 1.51580 | 0.035978 | 1528.697 | 185,501.09 | 389,046.83 |
| 160 | 1.36422 | 0.049709 | 1106.444 | 193,938.76 | 392,969.69 |
| 192 | 1.13685 | 0.070115 | 784.427 | 154,571.18 | 390,700.00 |

**Not monotone, not a power law: global `q = +0.2823` with R² = 0.0687.** The
consecutive-pair exponents are −1.02, −0.67, +5.38, −8.68, +3.84, +3.07, +1.89 —
noise, not a rate. Every rung's peak is on a `FrozenSolid` voxel.

**The margin spans 753.45 to 2402.00 — a 119.40 % spread of the mean** — and the
compliance control is destroyed with it (R² 0.0005, pairwise swinging ±7), which
is the tell that the OBJECT changed and not merely the mesh: the frozen-stamped
volume falls from 344,268 mm³ to 154,571 mm³ as the voxel-deep pads thin, and even
the `{phi<0}` volume wobbles 3.4 % because the part occupancy is re-voxelized.
The `stair_fine` arm tracks it to within ~1 % at every rung, for the same reason
as everywhere else: the peak is in the frozen set, where the arms are identical.

★ **This is the number a user would actually meet.** Re-certifying an unchanged
design at a different resolution moves the reported margin by up to 3.2×.

---

## Section 6 — cost (R8), and the rung that was not run

Measured directly, per rung, on a Release build, one process per solve, sequential,
recycling and GenEO off (`ScopedLadderSolverIsolation`'s posture):

| refine | effective res | DOF | `frac` analyze wall | `stair_base` analyze wall |
|---|---|---|---|---|
| 1× | 96 | 647,475 | 11.0 s | 10.7 s |
| 2× | 192 | 5,021,667 | 143.9 s | 142.2 s |
| 3× | 288 | 16,772,115 | 754.0 s | 737.9 s |

**Refine 4× (effective 384, ~39.8 M DOF) was not attempted.** The measured growth
across the three rungs above is ≈ `DOF^1.4`, which puts one 4× solve near 45–50
minutes and the pair near 1.6 hours; against a three-point ladder that already
carries PR 320's own number of points and a decided answer, it was not worth the
machine time, and a fourth point measured while anything else ran would not have
been a measurement. Reported as a choice, not as a result.

---

## Section 7 — the bars

| bar | where | verdict |
|---|---|---|
| R1 geometry identical | §2(a) | **PASS** — one alpha file (sha256 quoted); `{phi<0}` volume spread **0.010 %**, certified volume **0.006 %**, frozen volume identical to 9 s.f. |
| R2 staircase control | §2(d) | **PASS** — `q = 0.5641` (R² 0.9932) on the replicated staircase, PR 320's regime. Two qualifications stated. |
| R3 q fitted and reported | §2(c) | **PASS** — against 0.4945 / 0.4391 / 0.4555, with R² beside every fit. |
| R4 margin per rung + spread | §2(e) | **PASS** — 1726.75 / 1233.29 / 934.53, **61.03 %**. |
| R5 §3(d) in one sentence | §0, last row | **PASS** |
| R6 no production default moves | `R6_byte_identity.txt` | **PASS** — `topopt-cli` byte-identical to the merge base, with a negative-control arm and a from-scratch-build guard. |
| R7 assertions | `R7_assertion_census.txt` | **PASS** — no CHECK site, message, test name, assertion kind or ctest registration removed; no test file changed at all. Against `origin/main`, not a moving head. |
| R8 cost measured directly, build type verified | §6 | **PASS** |
| R9 no placeholders, no scratch at the root, separate commit for review response | — | **PASS** |

---

## In plain language

Back in August we measured that the strength number on the certificate keeps
changing as you make the simulation grid finer — it never settles down. The
explanation at the time was that the part's surface was a staircase of little
cubes, and a staircase is full of sharp inside corners; sharp corners have
infinite stress in theory, so a finer grid just finds a bigger number, forever.

Since then the shape stopped being a staircase. The optimiser now stores the
surface as a smooth mathematical formula, and each cell records exactly how much
of it is inside. So the obvious question was: does the number settle down now?

**Two answers, and the second one is the surprise.**

The first: on the smooth part of the surface, yes, essentially. Refining the grid
three times over moves the peak stress there by about 3–8 %, with no trend — where
before it grew relentlessly at a rate that matched a sharp corner exactly. We
checked that our measuring stick is honest by pointing it at a shape whose answer
is known from a 1926 textbook result — a spherical bubble inside a stretched bar —
and it converged on the right value; the staircase version of the very same bubble
was still climbing.

The second: **the number on the certificate is not measuring that surface at all.**
Every single time, the worst stress in the part turned up in the anchor pad or the
load pad — the blocks of material the software freezes solid around the bolt holes
and the loaded face so the optimiser cannot carve them away. Those blocks are
still staircases, and worse, their thickness is measured in grid cells rather than
millimetres, so they physically get thinner as you refine the grid. The certified
margin moved by 61 % across our sweep on a part whose actual shape changed by one
hundredth of one percent.

**What that means for the sculpting idea.** If someone smooths a surface by hand
and re-certifies, the margin will barely move — not because the smoothing did
nothing, but because the margin is reading a completely different part of the
model. To answer "did I make it weaker?" the comparison has to be the peak stress
*in the region that was sculpted*, and that number is trustworthy to a few percent.
Comparing `margin.worst_case` before and after would mostly be comparing the pads
to themselves.

**And cut-cell is not the thing to build.** The smooth boundary already converges
well enough to answer the question. The two things actually in the way are that
the pads are defined in grid cells rather than millimetres, and that the pads have
staircase corners the design was never allowed to smooth. Neither needs a solver
rewrite.
