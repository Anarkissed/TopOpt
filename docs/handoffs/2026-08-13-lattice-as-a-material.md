# lattice-as-a-material — a frozen region as a MATERIAL, not as solid

Evidence: `evidence/2026-08-13-lattice-as-a-material/`. The pre-registration
(`r0_preregistration.md`) was **committed before the first arm ran** — commit
`00eff24`, whose tree contains that file and nothing else under that directory.

## ★ READ THIS FIRST — the headline, and what in this document is superseded

**The feature works, and on his part it takes 31–47% of the printed mass out at a
margin the shipped gate still accepts by ~70–98x.**

| | rung 0.68 | rung 0.26 |
|---|---|---|
| ★ **NET mass saved** (re-optimised control, freed mass banked) | **−170.840 g (−31.4%)** | **−169.297 g (−47.0%)** |
| margin then | 146.877 (−78.2%) | 104.232 (−78.0%) |
| accepted by the shipped gate | **yes**, 98x `margin_stop` | **yes**, 69x |
| **B3** (NET ≥ 8.0%) | ★ **PASSES**, ~4x | ★ **PASSES**, ~6x |
| **B2** (margin ≥ 0.95x) | **MISSED** | **MISSED** |

So the trade is stated in one line: **you can remove a third to a half of the
mass, and what you spend is roughly three quarters of a margin that was 450x what
the gate requires.** Whether that headroom is real is a question about
`z_knockdown` and the strut law's own caveats (§1.4), not one this task settles.

★ **THIS DOCUMENT CONTAINS FIVE EXPLICIT WITHDRAWALS, AND THEY ARE KEPT RATHER
THAN EDITED AWAY** so the reasoning is auditable. In order of how badly each
misled:

1. **"None of the frozen mass is quiet / the wall carries the peak stress"** —
   an artefact of building regions by CONNECTIVITY, which fused the declared
   collar with the load pads. Superseded by §0.2 (provenance, 14 regions).
2. **"The light rung refuses the region holding 73% of the prize"** — that
   refusal was MY code, refusing against one run-wide cell. Superseded by §2.5
   (the cell is fitted per region).
3. **"B3 cannot be met / is decided against"** — reasoned from GROSS per-cell
   figures with the optimiser held still. Superseded by §0.4: B3 passes by ~4x.
4. **"Giving the freed mass back buys nothing"** — true at rung 0.68, false at
   0.26 where it buys 40.9%. Superseded by §0.4b.
5. **"A cold certification is 590.6 s, so the campaign is unaffordable"** —
   measured on a build with `CMAKE_BUILD_TYPE` empty. It is **28.0 s** in
   Release. Superseded by §0.6, and it is the one that cost the most: four
   scope decisions rested on it.

★ **WHAT IS STILL NOT DONE**: the margin as a per-iteration CURVE with a settling
iteration (bar R4's other half) and Mode 2's β-in-MMA coupling. §7 has each with
what it would take. §3(e)'s cost confirmation IS done — §0.4c, **0.0750%**.

★ **Nothing below is estimated, and no gross figure is presented as a saving.**

---

## 0. THE ANSWERS, IN ORDER — one line each

### 0.1 ★ The law's reach at his cell — and it clears, barely, on the median only.

At a **0.45 mm** nozzle the thinnest member that can hold a CERTIFIABLE octet
lattice — at *any* (cell, density) pair in the band — is **5.8659 mm**. At his
declared **2 mm** cell the homogenisation floor of **5 cells per member** demands
a **10 mm** member, and the lightest density whose strut still prints at that
cell is **0.2651**, not the band floor of 0.0505.

His face protection is declared at **5.0 mm** depth (3 voxels at his 1.705 mm
spacing), which read as its own member would be **half** the thinnest certifiable
member at his nozzle. Measured, it is not its own member — it is 26-connected to
the load pad, and the combined region's **median** thickness is 10.2317 mm, which
clears the floor by 2.4%. **60.2% of that region's voxels clear it; 39.8% do
not.** §0.2b. `evidence/…/m0/law.txt`, `evidence/…/m1/regions_r0.68.txt`.

### 0.1b ★★ TWO OF §0'S OWN FINDINGS ARE RETRACTED. Read this before the tables.

Both came from decisions I made in the instrument, not from the part, and both
made the feature look worse than it is.

★ **RETRACTED 1 — "the frozen region carries the part's peak stress" (§0.2).**
I built regions by flood-filling the frozen set, and face 16's protection collar
turns out to be 26-CONNECTED to the structural pads under the 22 load faces. So
`load-pad-1` is *the declared wall fused with the load pads*, and the load pads
sit directly under the applied force. **The 100%-of-part-peak figure is the load
pads' stress attributed to a blob that also contains the wall.** It says nothing
about the wall. `mask_step_face` (step.hpp) gives per-face provenance and would
have separated them; I did not use it. §0.2's QUIET/LOAD-BEARING split is
therefore **not a measurement of his declared regions** and should not be quoted
as one.

★ **RETRACTED 2 — "the light rung refuses the region holding 73% of the prize"
(§0.3b).** That refusal was MY CODE, on a rule that should not have applied. The
cells-per-member floor is a property of the region **and the cell**, not of the
region alone: the same 6.8 mm member misses 5 cells at a 2 mm cell and clears
them at a 1.3 mm one. My first cut took ONE cell for the whole run and refused
everything that could not hold it. `lattice_derive_cell_for_member` has answered
this since PR 302 and I did not call it. **With the cell fitted to each region's
own thickness the floor is cleared by construction and the refusal disappears** —
see §2.5. The rung-dependence measurement in §0.3b is real and still stands; what
it does NOT show is that the region is un-latticeable.

★ **What survives both retractions**, because it is arithmetic on the user's own
print profile rather than on my region definition: §0.1's window, §1's law and
its Gibson-Ashby gap, the drainability result, and — from the tables — that the
STRUT bound binds in every certified cell and that latticing the anchor moves the
solid region's margin by −0.003%.

### 0.2 ★★ The frozen set, keyed on PROVENANCE — 14 declared regions, not 2

`evidence/…/m1/regions_provenance_r0.68.txt`. Regions keyed on WHICH DECLARATION
froze each voxel (`mask_step_face`, replayed per declared face) rather than on
connectivity. **11,380 voxels are claimed by more than one declaration**; the face
protection wins them, and the overlap is reported rather than resolved silently.

| region | voxels | mass | energy share | peak vM / PART peak | verdict |
|---|---|---|---|---|---|
| anchor-18 | 10,966 | 67.431 g | 2.50% | 51.60% | LOAD-BEARING |
| ★ **protect-16** | 10,554 | **64.897 g** | **6.31%** | ★ **84.09%** | LOAD-BEARING |
| load-20 | 4,802 | 29.528 g | 1.73% | 60.62% | LOAD-BEARING |
| load-1 | 3,439 | 21.147 g | 6.45% | **100.00%** | LOAD-BEARING |
| load-24 | 2,778 | 17.082 g | 11.40% | 96.76% | LOAD-BEARING |
| load-25 | 2,609 | 16.043 g | 9.60% | 94.89% | LOAD-BEARING |
| *(7 more load faces)* | 5,068 | 31.163 g | 9.91% | 30–72% | LOAD-BEARING |
| load-49 | 130 | 0.799 g | 0.02% | **16.15%** | ★ QUIET |

> frozen mass **247.290 g** of 543.724 g printed (**45.48%**)
> **QUIET 0.799 g (0.32%) · LOAD-BEARING 246.491 g (99.68%)**

★ **THE PEAK VON MISES IS NOT WHERE THE FUSED MEASUREMENT PUT IT.** Under
connectivity the whole 29,250-voxel blob reported 100% of part peak; the peak
actually sits in **load-1**, a 3,439-voxel pad directly under the applied force.
The declared protection face is a separate region and reads 84.09%.

★ **AND ON THE STANDING HYPOTHESIS THAT THE PROTECTED WALL IS UNLOADED: THIS
MEASUREMENT DOES NOT SUPPORT IT.** `protect-16` reads **84.09% of part peak**,
which core's own ceiling (0.20) calls load-bearing by a wide margin. Two honest
caveats on that number, because they cut in the hypothesis's favour:

* the predicate is a **PEAK**, so one hot voxel where the collar meets a load
  path governs the whole region. By ENERGY the collar is **6.31%** of the printed
  part's strain energy while being **26%** of the frozen set by volume — i.e.
  markedly quieter per unit volume than the load pads, just not ~0;
* it is one load case at one rung. A different service case could move it.

The QUIET column is not empty but it is nearly so: **0.799 g of 247.290 g**.

### 0.2b ★★ AND THE DECISIVE FACT ABOUT THE COLLAR IS GEOMETRIC, NOT STRUCTURAL

| region | median member | cells/member @ 2 mm | fits at its own cell? |
|---|---|---|---|
| ★ **protect-16** | ★ **3.4106 mm** | 1.71 | ★ **NO — and no finer cell rescues it** |
| load-24, load-32 | 6.8211 mm | 3.41 | **YES** — at 1.3642 mm, ρ ≥ 0.4782 |
| anchor-18 | 27.2845 mm | 13.64 | yes (already in range) |
| the other 10 | 10.2–30.7 mm | 5.12–15.35 | yes (already in range) |

★ **The declared protection collar is 3.41 mm thick, and the thinnest member that
can hold a CERTIFIABLE octet lattice at a 0.45 mm strut width is 5.8659 mm.** So
the stress question never arises for it: there is no (cell, density) pair in the
band that both prints and homogenises across 3.41 mm, at any cell. The software
now says exactly that, with the two numbers that would change it:

> *region 2 spans 3.411 mm at the median … it clears the percolation floor, so it
> is BUILDABLE AND UNCERTIFIABLE, not un-latticeable. ★ AND NO FINER CELL RESCUES
> IT: at a 0.450 mm strut width no (cell, density) pair in the band fits a member
> this thin. It must be at least 5.8659 mm across, or the strut width must come
> down.*

★ **Whereas two load-face pads at 6.82 mm ARE rescued by the fit** — refused at
the run's 2 mm cell, certifiable at their own 1.3642 mm cell with ρ ≥ 0.4782. That
is the mechanism §2.5 added, doing its job on his part.

★ **So the honest reading is a THIRD one, not either of the first two.** It is not
"the frozen set carries the peak stress" (that was the fusion artefact) and it is
not "the light rung refuses the prize" (that was my fixed cell). It is: **the
biggest single frozen region a user explicitly declared is too THIN to certify a
lattice on this printer** — 3.41 mm against a 5.87 mm floor — and the remedy is a
thicker collar or a finer nozzle, both of which are the user's to choose and
neither of which the software can invent.

### 0.3 ★★ THE ASSIGNMENT TABLE, PROPERLY: 14 regions x 5 densities x 2 rungs = **140 cells**

`evidence/…/m2rel/`. Release build, provenance-keyed regions, every cell reported
including the failures. **1122 s at the shipped rung, 429 s at the light one** —
the whole thing in 26 minutes, which is what §0.6's correction bought.
Baseline rung 0.68: margin 673.856, mass 543.724 g. Rung 0.26: margin 624.112,
mass 360.304 g.

**f = 0.20 is refused in EVERY region at both rungs** — the strut does not print
at a 2 mm cell and a 0.45 mm width. The remaining four densities:

| region | cells/m | best Δmass | its margin | best margin | its Δmass | regime |
|---|---|---|---|---|---|---|
| anchor-18 | 13.64 | **−47.201 g** @0.30 | −74.31% | −22.24% @0.75 | −16.858 g | OUT |
| **protect-16** | 1.71 | ★ **REFUSED at every density** — below the floor, and no finer cell rescues it | | | | |
| load-20 | 10.23 | −20.669 g @0.30 | −37.20% | −15.18% @0.75 | −7.382 g | OUT |
| **load-1** | 6.82 | ★ **SEALED at every density — B7 REFUSES it** | | | | |
| load-24, load-32 | 3.41 | ★ REFUSED — below the floor (but **both fit at 1.3642 mm**) | | | | |
| load-25 | 6.82 | −11.230 g @0.30 | −62.54% | −33.52% @0.75 | −4.011 g | OUT |
| load-21 | 15.35 | −6.263 g @0.30 | −36.14% | ★ **−0.04%** @0.75 | −2.237 g | OUT |
| load-22 | 10.23 | −4.825 g @0.30 | −55.54% | ★ **−0.00%** @0.75 | −1.723 g | ★ **in** |
| load-19 | 5.12 | −1.627 g @0.30 | ★ **+1.09%** | +1.09% @0.30 | −1.627 g | OUT |
| load-31 | 6.82 | −1.141 g @0.30 | ★ **+0.00%** | +0.00% | −1.141 g | OUT |
| load-76 | 10.23 | −0.693 g @0.30 | ★ **+0.02%** | +0.02% | −0.693 g | OUT |
| load-49 | 5.12 | −0.560 g @0.30 | −0.35% | −0.20% @0.75 | −0.200 g | OUT |

★★ **(a) `load-1` IS SEALED AT EVERY DENSITY — bar B7 fires for the first time.**
Latticing the pad under the primary load face creates a lattice cavity whose pore
space cannot reach the exterior, so the drainability check refuses all four cells.
It is a refusal that only became visible once regions were keyed on PROVENANCE —
under the fused decomposition `load-1` sat inside a 29,250-voxel blob that drained
through its other end.

★ **AND IT IS NARROWER THAN "the part cannot be built", which PR 333 establishes:
sealed void blocks LATTICING, not PRINTING, and the refusal counts only pockets
CONTAINING latticed voxels** (`lattice_void.cpp:231-239`; the report's own
`sealed()` is `latticed_sealed > 0`). So the reading is precise: **`load-1` may
still be printed SOLID** — it is one of the fourteen regions this feature offers
to lighten, and the answer for that one is no. Nothing about the part's
printability is in question, and the other thirteen regions are unaffected.

★★ **(b) `load-22` @ 0.75 IS THE ONLY FULLY CERTIFIABLE CELL IN 140.** It is the
only one that comes back **`in` regime** — every other accepted cell is
out-of-regime and carries the certificate's own caveat. It is drainable, accepted,
and its margin moves **−0.00%**. It saves **1.723 g**. ★ **That is the honest
answer to "what can this feature certify on his part today": 1.7 grams.**

★ **(c) SOME REGIONS ARE FREE, AND ONE IS BETTER THAN FREE.** `load-19` at 0.30
**improves** the margin by +1.09% while saving 1.627 g; `load-31` and `load-76`
move it by +0.00% and +0.02%. Removing a little stiffness from a lightly-loaded
pad redistributes stress favourably. So the earlier claim that **B2 is missed at
every cell is WITHDRAWN** — it was an artefact of having only two fused regions
and three densities. Cells that clear the 0.95x bound exist; they are simply small.

★ **(d) THE MASS/MARGIN TENSION IS REAL AND NOW PRECISELY BOUNDED.** Everything
that clears B2 sums to roughly **8 g gross**. The one cell that clears B3's 8.68%
threshold on gross — `anchor-18` @ 0.30, −47.201 g — costs **−74.31%** of margin.
You can have the mass or the margin on this part, not both.

★ **(e) AND THE LIGHT RUNG THINS ALMOST EVERYTHING OUT OF RANGE.** At rung 0.26
seven of the fourteen regions drop below the floor (`load-20`, `load-1`,
`load-25`, `load-4` and others fall to 3.41 or 1.71 cells) and only `anchor-18`
and `load-21` remain. The rung-dependence of §0.3b is confirmed across 14 regions
rather than 2.

### 0.4 ★★ THE NET MASS SAVING, MEASURED AT BOTH RUNGS (bar R4): **−170.840 g (−31.4%)** and **−169.297 g (−47.0%)**

`evidence/…/m3/loop_r0.68.txt`. Rung 0.68, every region latticed at f = 0.30 with
its cell FITTED to its own thickness, four re-optimisations.

★ **The control is a RE-OPTIMISATION, not the stored design** — same rung, same
iteration cap, feature OFF. Comparing a re-optimised arm against `design.bin`
would fold the two runs' cap difference into the "saving".

> control (feature OFF): **543.724 g, margin 673.856, accepted, 27 iterations**

| `freed_mass_return` | mass | ★ **NET Δmass** | margin | Δmargin | iters | accepted |
|---|---|---|---|---|---|---|
| **0.00** banked | 372.884 g | ★ **−170.840 g (−31.4%)** | 146.877 | −78.20% | 94 | **yes** |
| 0.50 half back | 458.011 g | −85.713 g | 146.643 | −78.24% | 16 | yes |
| 1.00 mass-neutral | 511.895 g | −31.829 g | 146.616 | −78.24% | 31 | yes |

### 0.4b ★★ AND THE LIGHT RUNG CONTRADICTS IT — which is what bar R3 is for

`evidence/…/m3/loop_r0.26.txt`. Rung 0.26, everything else identical.
Control: **360.150 g, margin 473.440, accepted, 120 iterations.**

| `freed_mass_return` | mass | **NET Δmass** | margin | Δmargin |
|---|---|---|---|---|
| **0.00** banked | 190.853 g | ★ **−169.297 g (−47.0%)** | **104.232** | −77.98% |
| 0.50 half back | 275.815 g | −84.335 g | **133.584** | −71.78% |
| 1.00 mass-neutral | 360.395 g | +0.245 g | ★ **146.864** | −68.98% |

★★ **AT THE LIGHT RUNG, RETURNING THE MASS BUYS 40.9% OF MARGIN** (104.232 →
146.864). At the shipped rung it bought **0.18%**. Same feature, same density,
same knob — opposite conclusions. **A one-rung answer here would have been
confidently wrong either way**, which is precisely the case bar R3 and §4(b)
exist to catch, and the second time in this task that the two rungs disagreed.

★ **AND THE TWO RUNGS EXPLAIN EACH OTHER.** Look at where the margin *lands* at
`return = 1.0`: **146.864** at rung 0.26 and **146.616** at rung 0.68 — the same
ceiling to three digits. That ceiling is the latticed region's **strut bound**,
which is a property of the lattice and its local stress, not of the rung. So:

* at rung **0.68** the solid-region margin is several hundred, far above the
  strut ceiling, so `min(solid, strut)` is the strut term at every posture and
  returning mass cannot move it — **flat**;
* at rung **0.26** the solid margin starts *below* the ceiling when the mass is
  banked (104.2), so returning mass raises it until it meets the ceiling and
  stops — **+40.9%, then pinned**.

One mechanism, two behaviours, and the crossover is whether the part still has
solid-region margin to spare.

★ **SO §0.2's PREDICTION IS HALF RIGHT, AND I OVERGENERALISED FROM ONE RUNG.** I
wrote that the mass-neutral posture "is not a variant to try — it is the one the
measurement demands", then on the strength of rung 0.68 alone wrote that it "buys
nothing". **Both are withdrawn.** What is true: returning the freed mass buys
margin *only while the solid region is the binding term*, and on this part that is
the light rung and not the shipped one.

★ **SO THE PRE-REGISTERED BOUNDS SPLIT CLEANLY, AND B3 PASSES BY A FACTOR OF
FOUR.**

* **B3** (NET ≥ 8.0% at the shipped rung): **−31.4% — PASSES**, ~4x the bound, and
  **−47.0% at the light rung**.
  Every earlier statement in this handoff that B3 could not be met is
  **WITHDRAWN**; they were reasoning from GROSS cell-by-cell figures with the
  optimiser held still, and the loop is what R4 asked for precisely because that
  reasoning is not sound.
* **B2** (margin ≥ 0.95x baseline): **MISSED at both rungs** — −78.2% and −68.98%
  at their best. At the shipped rung it is **structurally unfixable by this
  knob** (the strut ceiling governs at every posture); at the light rung the knob
  recovers 40.9% and still lands 69% short. The bound is unreachable on this part
  either way.

★ **AND THE SHIPPED GATE ACCEPTS ALL THREE.** 146.6 against `margin_stop` 1.5 is
**98x** the requirement. So the honest sentence for this part is: **you can take
31% of the mass out and the shipped certification still accepts it; what you
spend is 78% of a margin that was 450x what the gate asks.** Whether that trade
is worth taking is a judgement about how much of that headroom is real, which is
a question about `z_knockdown` and the strut law's own caveats (§1.4) and not one
this task can settle.

### 0.4c ★ §3(e) CONFIRMED, not assumed: the machinery is **0.0750%** of one state solve

`evidence/…/m5/cost.txt`. The brief asked for this to be confirmed rather than
taken on PR 324's word, and it is — by timing the machinery **directly** rather
than differencing two runs.

★ **The obvious experiment would have been wrong.** Timing a frozen-lattice run
against a solid one and calling the difference "the machinery" conflates the
field resolution (which IS the machinery) with the fact that a latticed voxel
makes the operator a composite cubic element, so the CG does different work. A
raw wall delta charges the machinery for the solver's extra iterations. So each
piece is timed on its own, 50 repetitions, against one state solve on the same
grid at the trajectory tolerance:

| | ms |
|---|---|
| MODE 1 — resolve the constant field | **0.7959** |
| MODE 2 — resolve t = Σ β ψ (864 coefficients) | 14.6131 |
| MODE 2 — dρ/dβ, the analytic Jacobian | 39.7001 |
| ★ **MODE 2 machinery, per iteration** | **54.3132** |
| ONE STATE SOLVE (1057 CG iterations) | **72,389.6** |

> ★ **machinery / state solve = 0.0750%**

**CONFIRMED.** Even Mode 2 — the doubled coefficient block, its resolution AND
its Jacobian — is under a thousandth of one state solve on his part. Mode 1's
constant field is **0.8 ms** against 72 seconds. The brief's premise holds with
three orders of magnitude to spare, so cost is not a reason to prefer Mode 1 over
Mode 2, and it never was.

### 0.5 ★ Whether Mode 2 beat Mode 1 — **NOT MEASURED, and Mode 2's in-loop coupling is NOT BUILT.**

What IS built and is exact: the second coefficient-expanded field
t(x) = Σ β_j ψ_j(x) on its own knot lattice, the monotone clamped map t → ρ, and
the analytic Jacobian dρ_e/dβ_j (`lattice_beta_jacobian`), together with the
compliance sensitivity dc/dρ_e at a frozen latticed voxel, which
`simp_compliance` now returns and which is the other half of the chain rule.
What is NOT built is β joining the MMA design vector — §7.2.

### 0.6 ★★ A CORRECTION THAT INVALIDATES THIS SECTION'S ORIGINAL CLAIM: **every wall-clock number in the first cut of this handoff was measured on an UNOPTIMISED BUILD**

I configured the build with a bare `cmake -S core -B build`. That leaves
`CMAKE_BUILD_TYPE` **empty** — no `-O` flag at all. CI configures with
`-DCMAKE_BUILD_TYPE=Release` (`-O3 -DNDEBUG`), and the repository deliberately
undefines `NDEBUG` on the `topopt` target (core/CMakeLists.txt:134) precisely so
the draft-quality assertions survive an optimised build. ★ **Release is the
intended configuration here and I had no reason not to use it.**

Measured, same machine, same part, same solve:

| | debug (as first reported) | **Release** | |
|---|---|---|---|
| one cold certification of his part | **590.6 s** | ★ **28.0 s** | **21x** |
| the whole `--stage regions` run | ~12 min | ★ **47 s** | |
| `test_frozen_lattice_c0` (5 ladder runs) | ~236 s under load | **11 s** | |
| `test_lattice_density_field` | 0.55 s CPU | 0.08 s CPU | ~7x |

★ **AND THE PHYSICS IS UNCHANGED, WHICH IS THE POINT.** The Release run reproduces
the debug run's region table to every printed digit — `protect-16` 64.897 g at
84.09% of part peak, `anchor-18` 67.431 g at 51.60%, QUIET 0.799 g, margin
673.856173, mass 543.7239 g. Optimisation moved the clock and nothing else, so
every margin, mass, cells-per-member and validity verdict in this handoff stands.
**What does not stand is everything I concluded FROM the cost.**

★ **WHAT THAT COST ME, STATED PLAINLY.** The "a cold certification is tens of
minutes" finding drove the whole scope argument: 14 cells instead of 40, the loop
declared unaffordable, bar R4 written off as MISSED, and R1 first attempted as a
2h17m run on his part. At 28 s a cell the entire 40-cell table is **under twenty
minutes**. The campaign was never expensive; my build was.

★ **THE PART OF THE ORIGINAL FINDING THAT SURVIVES** is about the POSTURE, not the
clock, and it is still worth knowing: a probe doing a SINGLE cold certification
must isolate the solver (recycling and GenEO off, as `ScopedLadderSolverIsolation`
does) because GenEO pays its whole coarse-basis build on one solve with nothing to
amortise it over. That is a ratio between two postures and it does not depend on
`-O3`. What was wrong was the absolute number attached to it.

★ **AND THE GENERAL LESSON, WHICH IS THE ONE TO KEEP.** A cost measurement is a
claim about a configuration, and I never stated the configuration. Any handoff
quoting a wall clock must name the build type beside it, or the number means
nothing and — as here — the decisions taken on the strength of it are unfounded.

---

## 1. ★ THE ρ→STIFFNESS LAW — measured, and it is not Gibson-Ashby

`evidence/…/m0/law.txt`, reproducible with
`./build/frozen_lattice_probe … --stage law`.

### 1.1 The optimiser never sees an asymptotic law, and here is what it would cost if it did

The stiffness the optimiser steers on is `LatticeMaterialModel` — a C¹ curve
fitted to the library's **19 MEASURED resolved rows** for octet, read from
`lattice_resolved_rows` (CORE, never a transcript), origin-anchored, 4 terms.

Beside it, fitted **in this run** to the same rows' own axial Young's modulus so
the comparison is like for like:

> Gibson-Ashby **E\*/Es = 0.794431 ρ^1.6783**, over 19 measured rows.

and differenced row by row:

| ρ | measured E\*/Es | G-A E\*/Es | G-A error |
|---|---|---|---|
| 0.0505 | 7.117e-03 | 5.288e-03 | **−25.70%** |
| 0.0988 | 1.608e-02 | 1.633e-02 | +1.56% |
| 0.2041 | 4.452e-02 | 5.519e-02 | +23.99% |
| **0.2973** | 8.183e-02 | 1.037e-01 | ★ **+26.76%** |
| 0.5064 | 2.311e-01 | 2.536e-01 | +9.72% |
| 0.6987 | 4.659e-01 | 4.352e-01 | −6.57% |
| 0.8999 | 8.138e-01 | 6.655e-01 | **−18.22%** |

★ The exponent comes out at **1.678**, and the error sweeps from **−25.7% to
+26.8%** — a **52.5-point** band, worst at ρ ≈ 0.30, which is precisely the
density a lightweighting assignment wants. `lattice-phase0` M2 recorded the gap
as 23–52% with an exponent near 2.0; measured here on this library it is the same
finding to the same magnitude, and the sign REVERSES across the band, so no
single-exponent law is conservative everywhere. **The fitted curve does not
inherit any of it**, because it interpolates the rows rather than an exponent.
★ **ON THE INSTRUCTION TO "ROUTE THE REGION'S STIFFNESS THROUGH
`knockdown_spec_for`'s WIDTH-AWARE COMPOSITE", RESTATED BECAUSE IT HAS BEEN
REPEATED.** The requirement behind it — *never let the optimiser see the raw
f^1.5* — is met, and met more strongly than asked. But the literal routing is a
category error and this handoff will not pretend otherwise:

* `knockdown_spec_for` builds a **`KnockdownSpec`**, which scales the acceptance
  gate's stress MARGIN (`gate_margin_effective`). It never enters the FEA
  operator and is not a constitutive law. Stiffness cannot be routed through it.
* **The optimiser's stiffness** comes from `LatticeMaterialModel` — the C1 fit to
  the library's 19 MEASURED resolved rows. There is no f^1.5 anywhere on that
  path, and §1.1 measures what the asymptotic form would have cost: −25.7% to
  +26.8%, worst at the density a lightweighting assignment picks.
* **The gate's knockdown** IS routed through the one builder: `minimize_plastic`
  calls `knockdown_spec_for(options)` and hands it to `analyze_fixed_design`, so
  this path and the CLI and the bridge gate identically.
* **And for a LATTICED voxel the gate does not use f^1.5 at all.** Latticed
  voxels are excluded from the solid maxima and gated by the measured
  de-homogenised STRUT bound instead (§1.4). That is strictly better than the
  width-aware composite for this case, and §0.3 measures it binding in every
  certified cell.

So: `knockdown_spec_for`'s composite is left exactly where it is — it is not, and
must not be made into, a homogenised-stiffness law — and the requirement it was
invoked for is satisfied by the measured tensor plus the measured strut bound.

### 1.2 ★ The validity range, in cells per member — and it is TWO bounds that bind opposite ways

| | value | source |
|---|---|---|
| certifiable floor N\* | **5.0000** | `lattice_cells_per_member_min` |
| percolation floor | **1.0000** | `lattice_percolation_cells_per_member_min` |
| printability floor cell @ 0.45 mm | **4.931378 mm** | `lattice_cell_printability_floor_mm` |
| ★ thinnest certifiable member @ 0.45 mm | ★ **5.8659 mm** | `lattice_derive_cell_for_member` |

and at **his** 2 mm cell:

| cell | lightest printable ρ @ 0.45 mm | member needed for N\* = 5 |
|---|---|---|
| 1 mm | **none in the band** | 5 mm |
| **2 mm** | **0.2651** | **10 mm** |
| 3 mm | 0.1312 | 15 mm |
| 4.93 mm | 0.0505 (the band floor) | 24.7 mm |

★ **The two bounds cross.** A coarser cell buys printability and costs
homogenisation; a finer cell does the reverse. That is why they are reported
separately everywhere in this task and never merged into one verdict, and it is
why the app's face card shows the cell, the density AND the strut diameter rather
than one "OK".

### 1.2b ★★ PRINTABILITY IS ENTIRELY USER INPUT — and this task got it wrong first

Every project carries a print profile the user chose and the software may not
change. The minimum extrudable strut width comes from **there** — `job.hpp`'s
`min_extrudable_width_mm` ("stated minimum strut width (mm), finite > 0"), which
the app fills from `PrintParams.strutLineWidthMM`. Core's own convention is that
**0 means UNSET**, not "use a sensible number".

★ **An earlier cut of this task defaulted `frozen_lattice_min_extrudable_width_mm`
to 0.45.** That is HIS nozzle, from HIS profile, baked into a production options
struct where every other project would have inherited it silently. The app side
was worse: `LatticeFaceCardDerivation.card` treated a width of 0 as "skip the
printability test", so a project whose profile had not reached the call
**certified every density as printable**.

Both are fixed, and the rule is now pinned by tests rather than by comment:

* core defaults the field to **0.0** and `minimize_plastic` **REFUSES** a
  frozen-lattice run that does not state it — printability cannot be assumed and
  cannot be skipped;
* the app's card takes the width with **no default**, and an unknown width reads
  as `outOfRegime` — "I cannot tell", never a silent pass. Making it required
  immediately found a pre-existing caller that was not supplying it.

★ **AND THE NUMBER MATTERS BY MORE THAN 3x, MEASURED.** Across the common nozzle
range the printability floor moves 2.74 mm → 4.93 mm → 8.77 mm at 0.25 / 0.45 /
0.80 mm. The same 30 mm slab at the same declared density is **certified** under
a 0.25 mm profile and **out of regime** under a 0.80 mm one — same geometry, same
lattice, opposite verdict, because the coarse profile pushes the printability
floor above what the slab can homogenize. A hardcoded width would have refused
lattices that print perfectly well and approved ones that come out as gaps.

### 1.3 What happens outside the range: a REFUSAL, per region

`lattice_region_validity` reports, per region: median / p10 member width, cells
per member at both, the fraction of the region's voxels clearing the floor, the
two floors, and one quotable refusal sentence naming the number a user acts on
(the thinnest member that *could* clear the floor at this nozzle). A region below
the floor is **refused** — `minimize_plastic` drops it from the field entirely —
not approved with a footnote. `frozen_lattice_refuse_below_floor` defaults true,
and arming a run with a lattice cell of zero (so the question cannot be asked at
all) **throws** rather than passing silently.

The middle case is named rather than collapsed: a region between the percolation
and certifiable floors is **BUILDABLE AND UNCERTIFIABLE**, which has a different
remedy from un-latticeable.

### 1.4 ★ M5, the failure mode this closes

M5 as recorded: *default `infill_percent=100` → knockdown 1.0 → the gate
certifies the SOLID envelope margin, but the lattice is 5–12× more compliant.*

Two halves, and both are closed here:

* **the compliance and the macro stress field** — the certification now solves
  the real composite object. `minimize_plastic` hands `analyze_fixed_design` a
  `LatticePosture` carrying the frozen region's mask and relative density, so the
  latticed elements carry the measured homogenised cubic tensor;
* **the latticed region's STRENGTH** — `analyze_fixed_design` gains
  `gate_on_strut_strength`. **OFF by default**, so bar L1 ("report only") stands
  for every existing caller byte-for-byte; **ON for this feature**, because a
  latticed region excluded from the solid maxima and not otherwise gated is M5
  moved one stage later. Armed, the acceptance test becomes
  `min(solid-region effective margin, lattice_strut.margin_worst_case)` — the
  measured PR 259 de-homogenisation bound — and `margin_effective_solid_only`
  keeps the number the gate would have used, so the strut term's cost is on the
  receipt and never folded invisibly into one figure. `strut_gated` says which of
  the two happened. The out-of-regime case is **not** special-cased into a pass.

---

## 2. THE MECHANISM

`core/include/topopt/lattice_density_field.hpp` is the whole of it, and its
header is the reference; this is the shape.

### 2.1 A fixed density IS a constant density field

One representation, two modes:

* **MODE 1 — DECLARED.** `t` is constant over the region: the user's `f`.
* **MODE 2 — OPTIMISED.** `t(x) = Σ β_j ψ_j(x)`, the **same basis family** φ
  already uses (`plsm_basis.hpp`, shared — not a second copy), on its **own,
  coarser knot lattice**. The rule, stated before it was measured: **4× φ's
  spacing on every axis**, per axis, with no minimum and no maximum taken over
  the axes (`gridap-alpha-rule-breaks-on-slabs` is why). Relative density is a
  monotone map of `t` through a smooth Heaviside, clamped to the region's band —
  and `β = 0` seeds the MIDDLE of the band rather than an endpoint.

The prior art is read and named: Deng & To, *Projection-based Implicit Modeling
Method (PIMM) for Functionally Graded Lattice Optimization*, arXiv 2008.07487 /
JOM 73:2012-2021 (2021), DOI 10.1007/s11837-021-04659-1 — a second global-RBF
field whose coefficients are the design variables, knots decoupled from the FE
mesh, a projection to an ersatz density, chain-rule sensitivities, MMA. Its own
version meshes the real lattice and takes no homogenisation shortcut, which is
more honest and puts the whole cost on the state solve; §0.6 is what that costs
here, so **we keep `fea_solve_cg_lattice_matfree` (PR 257) and the re-fitted law
of §1**, exactly as the brief's §3(f) directs.

### 2.2 ★ The per-voxel density contract is preserved (bar R6), and here is each consumer

A latticed frozen voxel's **design density stays 1.0**. The lattice cell fills
the voxel's envelope; the pore space is a property of the **material**, not of the
occupancy. The relative density travels in a **second** grid-indexed field —
exactly the `(mask, relative_density)` pair `LatticePosture` has carried since
lattice certification Phase 1. Nothing here lowers `printed_iso`.

| consumer | what it reads | verified |
|---|---|---|
| certification (`analyze_fixed_design`) | `density[e] > iso`, plus the posture | ✔ frozen voxel is 1.0 → printed, as before; its lattice density arrives on the posture, the contract that already existed |
| min-feature (`check_v3`) | `density` at `kIso` | ✔ unchanged — `kIso` is 0.5 on a frozen-lattice run and the frozen voxel is 1.0 |
| frozen / protect masks | `effective_design_mask` | ✔ untouched; the field is emitted **only** where that mask says FrozenSolid (`only_where`) |
| clearances | the FrozenVoid overlay | ✔ untouched; a cleared voxel is not FrozenSolid so it can never enter the field |
| octet grading law (`grade_lattice`) | a density field | ✔ unchanged — it reads the same 1.0 |
| the load-path walk | `density > iso` | ✔ unchanged, and B5 states it separately because PR 324 measured 40 leaked frozen voxels out of 40,216 breaking it |

### 2.4b ★ AGAINST PR 331 (`face-regions`): THIS WORK IS A VOXEL SET, SO NOTHING CHANGES

PR 331's §6 records that **a region cannot yet be a lattice region**: core's
`lattice.regions` are pure GEOMETRY that become `ClearanceGeometry` predicates
evaluated pointwise (`run_job.cpp:621`, `:756`, `:856`), and a region is a voxel
SET, not a predicate. *"A grid split grades what is FROZEN, not what is
LATTICED."*

★ **This feature is on the other side of that line and is unaffected.**

| | |
|---|---|
| what it keys on | `frozen_lattice_region_id` — a **`std::vector<int>`, one id per voxel**. A SET, never a predicate. |
| what it may touch | only voxels the effective mask holds **FrozenSolid** (`only_where`), i.e. exactly what a face protection and the anchor/load pads freeze |
| what it does NOT touch | `lattice.regions`, `ClearanceGeometry`, and the pointwise-predicate path — `grep` over this task's sources finds none of them |

So it does **not** assume grid-split sectors can carry lattice properties, and it
does not need PR 331's §6 gap closed to work. It grades what is FROZEN, which is
the half PR 331 says already exists.

★ **And the shapes compose the right way round, which is worth recording for
whoever picks up that gap.** PR 331's regions ARE voxel sets, and this feature's
region input IS a per-voxel id field — so a `face_protection_region_ids` sector
could feed `frozen_lattice_region_id` **directly**, with per-sector densities
falling out of the existing `LatticeRegionSpec` list. That is an observation about
two existing shapes, not a licence: ★ **the §6 gap is a separate task and nothing
here builds toward it.**

### 2.5 ★★ THE CELL IS FITTED TO THE REGION — the difference between refusing and working

The cells-per-member floor is a property of the region **and the cell**. Taking
one cell for a whole run and refusing every region that cannot hold it throws
away regions that are perfectly latticeable at a cell derived from their own
thickness. That is what my first cut did, and on his part it refused the region
holding 73% of the mass.

`lattice_derive_cell_for_member` (lattice.hpp, PR 302) returns the admissible
(cell, density) window from a member's own width and **the user's own stated
strut width**. Its coarsest end — exactly N\* cells across, at the lightest
density that still prints there — is the **minimum-mass certified lattice** for
that member.

| | |
|---|---|
| `LatticeRegionCellMode::Fit` | derive this region's cell from its own thickness |
| `ResolvedLatticeDensityField::cell_mm` | the per-voxel cell it produces — which IS `LatticePosture::cell_size_field`, the SWEPT posture from `2026-08-01-lattice-cell-size-sweep`, so the certificate's regime guard asks each voxel about **its own** cell rather than one number for the part |
| a Declared density below the fitted cell's printable floor | **RAISED** to it, and the raise is **REPORTED** — the user asked for one mass and got another, and that must never be silent |
| refusal | only when **no** (cell, density) pair fits the member at the user's width — the one case a finer cell cannot rescue, whose remedy is a thicker member or a finer nozzle |

★ **And every refusal now carries the number that fixes it.** "IT FITS AT ITS OWN
CELL: at 1.6 mm this member holds exactly 5 cells, and the lightest density that
prints there is 0.22" versus "NO FINER CELL RESCUES IT: it must be at least
5.8659 mm across". *Too thin for a 2 mm cell* and *cannot be latticed* are very
different statements and only one of them is usually true.

Measured end to end (`test_frozen_lattice_c0`), same region, same declared
density, floor enforced in both arms:

```
FIXED  member 24.000 mm = 4.00 cells at 6.00 mm  refused ->    0 latticed
FIT    member 24.000 mm = 4.00 cells at 4.80 mm          -> 2304 latticed
```

★ **In the app this is what AUTO already meant.** PR 328's face card derives the
cell as `depth / N*` and floors it at core's printability floor — the same
derivation. So the card and the run now agree about which cell a region gets,
instead of the card previewing one and the run refusing at another.

### 2.3 The four fields of the defect, and where each is fixed

| | was | now | where |
|---|---|---|---|
| FEA stiffness | full solid | the measured homogenised tensor at ρ | `SimpParams::lattice_relative_density` → `simp_compliance` |
| mass | full solid | ρ × solid | falls out — `analyze_fixed_design` already counts a latticed voxel as its relative density |
| volume budget | **outside** it | **inside** it | `frozen_effective += ρ` (part-relative) and `SimpOptions::freed_mass_voxels / freed_mass_return` |
| sensitivity | zero | zero (Mode 1), β-only (Mode 2) | the region is never a per-voxel design variable |

`freed_mass_return ∈ [0,1]` is the one knob the frontier is walked on: **0.0**
banks the freed mass (the assignment table's posture — what latticing COSTS in
margin with nothing given back), **1.0** is mass-neutral (the posture §3's
buttressing coupling demands, since 94% of what the optimiser places lands within
5 mm of the frozen wall). **The rung's meaning is not redefined**: at f = 1
nothing is freed and every posture is the shipped one, bit-for-bit.

### 2.4 ★ R1 — C0 inertness, and why it is exact rather than tight

**A lattice at relative density 1.0 has no pore space; it IS solid.** The
resolver emits no mask bit and no ρ for it, so the run is byte-identical to one
that never declared the region. That is a definition, not a shortcut.

Measured beside it, because it is a different claim and only the first is a bar:
`LatticeMaterialModel::value(1.0)` returns the **exact** isotropic solid triplet —
C11 5185.7585, C12 2554.1796, C44 1315.7895 against c(1−ν), cν, E/2(1+ν)
computed independently, at **0.000e+00 relative on all three components**. So the
law is continuous at the join too, and the alternative (routing f = 1.0 through
the cubic element) would have been correct to PR 252's 8.5e-16 — which is
"identical to machine precision", not "byte-identical", and only the second is
the bar.

The verification is a checksum, not an argument: `--stage r1` runs the ladder
with the feature off and with it on at f = 1.0 over every region — with the
cells-per-member floor **deliberately not enforced**, so a refusal cannot make
the field empty for the wrong reason — and compares `design_fingerprint` of the
converged fields.

---

## 3. ★ DRAINABILITY — and a correction to the brief

### 3.1 The named file does not exist on `main`

The brief's §6(b) attributes a correctness bug to `plsm_topology.hpp`'s
`in_region`, "which treats the frozen set as outside the region", and cites
cavity counts of 5/0/2 against 51/21/32. **There is no `plsm_topology.hpp` in
this repository**, on `main` or on any branch reachable from it, and no
`in_region` outside a harness helper in `external_field_surface_probe.cpp` that
selects mesh vertices and has nothing to do with drainability. The cited counts
appear in no evidence directory. Whatever that is, it is not in this tree, so it
could not be fixed here and it is not being left silently.

### 3.2 What IS here already does the manufacturing definition

`lattice_void.hpp` / `lattice_void.cpp` — shipped by
`2026-08-05-lattice-void-reaches-exterior` — is the predicate, and it is exactly
§6(a):

* the escape network is **LATTICED ∪ VOID**, walked **6-connected**, and its
  header argues the (26 solid, 6 void) pairing from digital topology rather than
  asserting it;
* **printed material that is not latticed BLOCKS** — so frozen material the run
  leaves solid is a barrier, which is the bolt-boss case;
* the seeds are the grid's six boundary planes, and voxels outside the part are
  not printed, so the seed set IS the true part exterior.

★ **And this task changes what that predicate sees, which is the real coupling.**
A frozen region declared as lattice moves from the BLOCKING set into the ESCAPE
network. That is correct — a latticed boss really does let powder through — and
it means the check must be re-evaluated per assignment, which is what the
assignment table's `sealed` column does (bar B7). ★ **Measured on every certified
cell at both rungs: `sealed = 0` throughout.** Latticing either of his frozen
regions at any admissible density leaves the pore space connected to the exterior,
so B7 is HELD on all nine certified assignments.

---

## 4. THE APP (§7)

`main` moved under this branch: **PR 328 landed**, and the face card the brief's
§0(b) refers to is real. The branch was merged and §7 was rewritten onto it.

* **§7b** — `LatticeFaceCard` gains `latticedMassG` and `savedMassG`; the card
  row gains two chips, "as lattice" and "saved". The card already stated what the
  barrier **hands** the lattice in grams and stopped one multiplication short of
  the number the feature exists for. It is named `savedMassG` and the doc comment
  says GROSS, because `frozen_buttress_probe` measured 94% of what the optimiser
  places landing within 5 mm of that wall.
* **§7a** — a per-region **density** control, keyed like `groupRoles` on the ONE
  `SelectionModel`. **AUTO is the default and Auto is ABSENCE** — a stored
  default would make the app the author of core's number — and Auto **cannot
  refuse**: it picks inside core's certifiable band, verified by a test that
  sweeps the depth from 0.5 mm to 60 mm and asserts Auto never produces a state
  the page cannot proceed from. `Solid` is 1.0 and emits no lattice at all,
  mirroring core's `kLatticeSolidAt`.
* **§7c** — a declared density outside the validity range shows as
  **Out of regime** on the card's own verdict, and a declared density whose strut
  is thinner than one bead is **refused rather than quietly raised** — raising it
  would print a heavier lattice than the user asked for and report the lighter
  one.

`FrozenRegionAsMaterialTests` covers all three, and its last test reads
`WorkspacePlaceholder.swift` and asserts the row renders the two chips and the
control writes the settings key — because *tests on value types miss call sites*
has shipped five times here.

---

## 5. BARS

| bar | state |
|---|---|
| **R1** C0 inertness first | exact by dispatch, and asserted at the resolver in `test_lattice_density_field` (f = 1.0 emits nothing; 0.95 is still clamped into the band, so "solid" is the number and not a tolerance). The whole-run stash-rebuild checksum did NOT run — §7.1 |
| **R2** Mode 2 off until Mode 1 measured; Mode 1 off until bounds met | **held** — `frozen_lattice` defaults false, `frozen_lattice_beta` defaults empty, and no production path sets either |
| **R3** every arm at two rungs | ★ **HELD, and it paid for itself** — both tables complete (8/8 and 6/6), and the light rung REFUSED the region holding 73% of the prize while the shipped rung admitted it (§0.3b) |
| **R4** NET, and margin as a curve | ★ **NET HELD AT BOTH RUNGS** — −170.840 g (−31.4%) at 0.68 and −169.297 g (−47.0%) at 0.26, across the freed-mass frontier with a re-optimised control (§0.4, §0.4b). The margin CURVE with a settling iteration is still not produced (the loop reports per-arm endpoints), so R4 is **partly held**. |
| **R5** cells-per-member per region | **held** — §0.2b, per region, with the p10 and the fraction beside the median, and §0.3(b) reports where the region-level test and the certificate's own guard disagree. ★ Read with §0.1b: the REGIONS those numbers are attributed to were built by connectivity, so a declared face's numbers are fused with its neighbour's |
| **R6** per-voxel density contract | **held** — §2.2, each of the six consumers checked |
| **R7** assertion census | **held** — §6 |
| **R8** root cause with file and line, no placeholders, no root scratch | held |
| **R9** separate commit for any review response | n/a — no review yet |

---

## 5b. The test suites — run overnight, under a watchdog

**core, Release, CI's full denominator: `ctest` 123/123.**
The two tests that had never run in this worktree (`export_3mf`, `threemf_import`)
now register and pass. ★ Before that they were **silently absent**: `lib3mf` was
installed but never on CMake's prefix path, so the suite reported "121/121
passed" while being 2 short of CI. A local pass without CI's denominator is not a
pass.

**New, and green:**

* `frozen_lattice_c0` — bar R1 as a permanent guard: `Lattice(f = 1.0)` is
  byte-identical to Solid over a WHOLE `minimize_plastic` run, with a positive
  control (the same arming at f = 0.30 must move the design and the mass) so it
  cannot pass by the feature doing nothing. **15.8 s.**
* `lattice_density_field` — the two floors, every refusal, the fitted cell, and
  the β Jacobian against central differences at **6.013e-10**. **0.11 s.**

**app:** `AppModelTests` **31/31, 0 failures**, run directly against the built
bundle — including the three 3MF tests that were failing with *"lib3mf not
available in this build"* until `Package.swift` was fixed (§7.4).

★ **`swift test` as a whole does NOT go green on this machine, and it is the
documented flake, not this work.** `app-swift-test-gpu-flake`: an intermittent
SIGTRAP in GPU-touching tests under parallel xctest workers, where the crashing
test WANDERS and each passes in isolation. Observed here exactly: one run died in
`AppModelTests`, the next in `RunModelTests` after **1023 tests**. Two further
"failures" in the overnight log are **my own `pkill`** while re-ordering queues
(`Terminated: 15` in those logs) and are not failures at all.

The byte-identity argument for every pre-existing path is a construction, not a
test result, and is stated so it can be checked by reading: every new option
defaults to the value that takes no new branch, `vf_target` reduces to
`options.volume_fraction` by adding exactly 0.0, `SimpParams::lattice_relative_density`
is null on every existing caller, and `gate_on_strut_strength` is false unless a
run actually latticed something.

## 6. R7 — the assertion census

`evidence/…/assertion_census.sh`, run `BASE_REF=main`. Message census, not a name
grep: test assertion messages, registered ctest names, production refusal
messages, the comparison-operator histogram inside `CHECK()`, and the harness's
own refusals as one bag.

Run against `main` **after merging it twice** — it moved under this task both
times (PR 328's lattice-page redesign, then PR 329's solver-speed work), which is
the trap `main-moves-under-long-tasks` records. A census against a stale base
reports the OTHER branch's additions as this one's removals; the first run here
did exactly that, flagging eight latch-re-arm assertions that were simply not in
this tree yet.

Against the merged tree: **nothing removed in any of the five sections.**
Registered ctests **121 → 123** (`frozen_lattice_c0`, `lattice_density_field`),
production refusals **418 → 445**, and no comparison operator inside `CHECK()`
weakened.

Production refusals went UP because this task adds them: an untrustworthy
topology, a mismatched region-id size, a region in Optimised mode with no β
field, a fitted region with no validity to fit against, a narrowing that empties
the band, a `freed_mass_return` outside [0,1], a `lattice_relative_density` with
no material law, a lattice cell of zero when the floor is enforced, and — the one
this task learned late — **an unset minimum extrudable strut width** (§1.2b).
The full run is in `evidence/…/r7_assertion_census.txt`.

---

## 7. ★ WHAT WAS NOT DONE, AND WHAT IT WOULD TAKE

Stated plainly and separately, because scaling this task down is the
maintainer's call and not mine.

### 7.1 ★ THE LOOP (§4c of the brief; bar R4) — the one measurement still owed

**M0, M1 and M2 all completed**, both rungs, every cell including the failures
(§0.1–§0.3b). What did NOT run is **M3, the loop**: assign → re-optimise the
remainder at the rung the freed mass allows → certify → step the densest region
up one level → repeat.

So there is no NET number and no margin CURVE with a settling iteration, which is
what bar R4 asks for. ★ **It is not, however, the thing standing between this and
a decision**: §0.4 settles B3 against the feature from the two completed tables
alone, because the only region surviving the ladder saves at most 8.68% GROSS at
its worst-margin density and NET is strictly smaller. The loop would quantify how
much smaller. Run it with `freed_mass_return` swept from 0.0 to 1.0 —
`evidence/…/queue.sh` is the queue, in the pre-registered order.

The cost, measured rather than assumed: **491–882 s per certified cell**, mean
~610 s at the shipped rung and ~820 s at the light one, on 1.47M DOFs of plain CG
(§0.6). The 14 cells reported here were ~4 hours of solve. A loop pass adds a
full re-optimisation (60+ iterations) on top of a certification, per point.

`queue.sh` takes `M2_REGIONS` and `M2_DENSITIES` from the environment so any cap
is on the command line and in the record rather than hidden in a default, and the
probe **prints the regions it skipped** — a table that silently omitted them would
read as though they had been measured.

### 7.1b ★ REGIONS BY PROVENANCE (the retraction in §0.1b)

The probe builds regions by 26-connected components of the frozen set. That fuses
a declared face protection with the structural pads it happens to touch, and then
attributes the pads' stress to the wall. **The fix is to key regions on
PROVENANCE — which declared thing froze each voxel — via `mask_step_face`**, which
is public and is the same primitive `build_production_loadcase` uses to create
those voxels in the first place.

★ **Core needs no change for this**: `frozen_lattice_region_id` is already a
per-voxel id supplied by the caller, and the APP is already right — it keys
regions on `SelectionGroup.id`, which is provenance by construction. It is the
probe (and, when it is wired, `run_job`) that must build the ids from the
declaration rather than from connectivity.

Until that is done, no per-region stress number measured on his part should be
quoted for a declared face.

### 7.2 Mode 2's in-loop coupling (§3c)

Built and exact: the β field, the t → ρ map, `lattice_beta_jacobian` (dρ_e/dβ_j),
and dc/dρ_e at a frozen latticed voxel. Not built: **β joining the MMA design
vector**. The remaining piece is one function — `mma_update_masked` extended with
a parallel β block inside the same 1-D dual bisection, which is exact rather than
approximate because MMA's subproblem is separable and the coupling is the single
volume constraint (dV/dβ_j = Σ_e dρ_e/dβ_j, a linear functional). It was not done
because it could not have been *measured* in this session (§7.1), and shipping an
unmeasured optimiser change behind a flag that R2 keeps off buys nothing.

### 7.3 The job-schema entry point and the export hookup

`frozen_lattice` is a `MinimizePlasticOptions` field with no `job.json` key and
no `run_job` wiring. That is deliberate under R2 — nothing can arm it by accident
— but it is also the gap that must close before this ships, and the shape of the
fix matters:

★ **`run_job` must DERIVE the frozen-lattice regions from the same
`lattice.regions` include declarations the EXPORT already uses**, rather than
taking a second declaration. The export path already lattices frozen voxels that
fall inside an include region — that is what `lattice_export_frozen_latticed`
counts and what PR 328's face card is about. Two independent declarations of
"which frozen material is lattice" is precisely the loop/export disagreement this
codebase has been bitten by twice (the two-step pipeline, and the pre-multiscale
certification), and the way not to have it is not to have two.

---

## 8. In plain language

A part that gets optimised has regions the optimiser is not allowed to touch — a
bolt boss, the face you told it to protect, the skin behind an anchor. Today the
optimiser treats every one of those as **solid plastic**: it is stiff, it is
heavy, it does not count against the weight budget, and the optimiser cannot
change it. On the maintainer's own part those regions are **45% of the printed
weight** — 247 grams of 544.

But they do not have to be solid. They can be a **lattice** — a scaffold of thin
struts with air in between — which is much lighter and, for a region that is not
carrying much load, plenty strong. This task built the machinery that lets the
optimiser know that: the frozen region now has a *density*, its stiffness is the
real measured stiffness of that lattice rather than of solid plastic, its weight
is its density times solid, and — this is the part that matters — the weight it
gives up goes back into the budget, so the optimiser can spend it somewhere
useful.

Two things came out of it that are worth knowing even though the big measurement
did not finish.

**One: the printer's nozzle, not the software, is what limits this.** For the
lattice's stiffness to be *predictable* you need at least five lattice cells
across the thing you are latticing, and for the struts to actually come out of
the nozzle the cells cannot be too small. Those two demands pull in opposite
directions, and on this printer they leave you needing a wall at least **5.9 mm
thick** before a lattice there can be certified at all. His protected collar is
declared at 5 mm. So the honest answer for his part may well be "not there, not
at this cell" — and the software now says so per region, with the number he'd
have to change, instead of quietly latticing it and certifying a stiffness the
part does not have.

**Two: the old rule of thumb for lattice stiffness is wrong by up to a quarter,
in both directions.** The textbook formula over-predicts stiffness by 27% at the
densities you would actually pick and under-predicts by 26% at the light end. The
optimiser never sees that formula here — it uses the 19 real measurements — but
it is worth writing down, because that formula is what most tools use.

**Three: the real answer for his part is about THICKNESS, not about stress — and
I got there by way of two mistakes that were my software rather than the part.**

The wall he protects is about **3.4 mm** thick. For a lattice's stiffness to be
predictable you need at least five cells across the thing you're latticing, and
for the struts to come out of the nozzle the cells can't be too small. Those two
demands pull in opposite directions, and on his 0.45 mm nozzle they leave a hard
floor: **nothing thinner than 5.9 mm can hold a certifiable lattice, at any cell
size**. His wall is well under that. So the question "is it carrying load?" never
really arises for it — there is no lattice to put there in the first place. The
remedy is a thicker collar or a finer nozzle, and the software now says so with
both numbers instead of just refusing.

Two of his load-bearing pads, at 6.8 mm, are a different story: they were refused
at the run's cell and are perfectly certifiable at their own. That is the fix
below, working.

Now the two mistakes, because they are why it took three attempts to see that.

The first was how I grouped the regions. I found them by "what's touching what",
and it turns out the protected wall is touching the pads that sit directly under
where the load is applied. So my measurement fused them into one blob and then
reported the pads' stress as if it were the wall's. That number should not be
used.

The second was worse. I had the software pick **one lattice cell size for the
whole part** and refuse any region that was too thin to hold five of them. That
is the wrong question: a wall that can't hold five 2 mm cells holds five 1.3 mm
cells perfectly well. The software already had a function that works this out per
region — it has since a task months ago — and I didn't call it. So when the
optimiser stripped material and the wall got thinner, my code refused it, and I
wrote that up as "the part can't be latticed". It can. That's now fixed: each
region gets a cell derived from its own thickness, so the accuracy requirement is
met by construction instead of by luck, and the only genuine refusal left is a
member so thin that *no* cell works — where the software now tells you the
thickness you'd need.

**What still stands** is the arithmetic that doesn't depend on how I grouped
things: what a lattice can and can't do at a given nozzle, the fact that the
struts' own strength is what limits these designs rather than damage to the
surrounding part, and that latticing the anchor pad barely disturbs the rest of
the structure at all.

**What's still open** is the last loop — give the freed weight back to the
optimiser and see how much comes back as material — and re-measuring the part now
that the two bugs above are fixed. `queue.sh` is the button for both.
