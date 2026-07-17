# 089 — Lattice / Voronoi / lace tooling: research & diagnosis

**Track:** diagnostic (READ-ONLY). No source, test, fixture, ROADMAP, DECISIONS or
ARCHITECTURE file was modified. No box checked. No PR. The only file written is
this report. `git status` shows exactly one new file: this one.

**Question asked:** should TopOpt add lattice / voronoi / lace tooling, motivated by
wanting visible fine/organic structure that the 64³ min-feature floor (~4.7 mm min
feature, ~9.4 mm members on a 200 mm part) currently prevents, given that 128³ is
unaffordable?

---

## STEP 0 — THE REFRAME (read this before anything else)

**Lattice tooling does not address the stated motivation. It is a different feature.**

The chunky-rib complaint and the lattice idea are about two different things, and
conflating them is the central risk in this proposal:

- The **min-feature floor** governs **where the optimizer is allowed to put material** —
  how fine a branch it may route, how many ribs it may split into.
- A **lattice** governs **what is inside material the optimizer already placed** — it
  subtracts from the interior of a rib whose position, count and thickness are already
  decided.

These do not touch. Latticing a 9.4 mm rib yields a **latticed 9.4 mm rib**. The rib
centrelines, the rib count, the branching pattern, the overall chunkiness — all
identical. You would get a chunky part with holes in it.

### Why the floor cannot be reached this way (code, not opinion)

The floor is in [`physical_filter_radius`](core/src/simp/simp.cpp:296):

```cpp
const double rmin_voxels = min_feature_mm / spacing;
return rmin_voxels < floor_voxels ? floor_voxels : rmin_voxels;
```

with `floor_voxels = 1.5` ([simp.hpp:203](core/include/topopt/simp.hpp:203)). At 200 mm /
64 = 3.125 mm spacing, `2.5 / 3.125 = 0.80 < 1.5` → floored → effective min feature
`1.5 × 3.125 = 4.69 mm`. Confirmed by my own reproduction of the two cited formulas:

| resolution | spacing (mm) | rmin (vox) | floored? | eff. min feature (mm) | member ≈ 2× (mm) |
|---:|---:|---:|:--:|---:|---:|
| 64³ | 3.125 | 0.80 | **YES** | **4.69** | **9.38** |
| 96³ | 2.083 | 1.20 | **YES** | 3.12 | 6.25 |
| 128³ | 1.562 | 1.60 | no | **2.50** | 5.00 |
| 160³ | 1.250 | 2.00 | no | 2.50 | 5.00 |

That 1.5 floor is **not an arbitrary constant an agent may lower**. It is locked by
[ARCHITECTURE.md:75](docs/ARCHITECTURE.md:75) — *"density filter (radius ≥ 1.5 voxels)"* —
and it exists to keep the optimizer mesh-independent and checkerboard-free. Dropping it
does not buy fine structure; it buys numerical noise that *looks* like fine structure.
The only honest route to a finer feature is **finer spacing**, i.e. higher resolution.

### The two facts that reframe the whole request

1. **128³ already ships.** [`FlowModels.swift:53-57`](app/TopOptKit/Sources/TopOptFlows/FlowModels.swift:53)
   — `fast: 64`, `balanced: 96`, `fine: 128`. The capability the maintainer wants is not
   missing from the product. It is present and too slow to use. Lattices would be a *new
   feature built to work around a performance problem in a feature that already exists*.
2. **The target is bounded.** The table above shows 128³ is exactly where the floor
   clears, and 160³ buys **nothing further** (min feature is honoured at 2.5 mm, so the
   request, not the grid, becomes the binding constraint). "Make 128³ affordable" is a
   finite, well-defined engineering goal — not an infinite regress. That makes it a far
   better investment than it looks.

**Plain statement, as requested:** if the goal is "my ribs are too chunky, I want finer
structure," lattice tooling **does not deliver it, at any price, in any of the variants
below**. It is a cosmetic/eye-candy feature or a mass-reduction feature, and it should be
argued for on those merits or not at all. The fix for chunky ribs is 128³, and the work
that unlocks 128³ is solver performance — the track the project is already on
(matrix-free multigrid, handoffs 077/078/085).

---

## STEP 1 — WHAT ALREADY EXISTS

### 1a. The slicer already gyroid-fills the interior. Who owns what?

**TopOpt owns: a number in a report. The slicer owns: all of the geometry.**

- The rule engine emits a **single scalar per variant** —
  [`settings.hpp:29`](core/include/topopt/settings.hpp:29) `int infill_percent = 0;` —
  from a margin-band lookup in `core/src/settings/rules.json` (60/50/40/25/15 % across
  margin bands < 1.2 / 1.5 / 2.0 / 4.0 / ∞), plus a small-part `+5 %` modifier, clamped
  to `[10, 60]`. Resin returns no FDM fields at all
  ([settings.cpp:483](core/src/settings/settings.cpp:483)).
- **The 3MF export writes geometry and nothing else.**
  [`core/src/io/threemf.cpp`](core/src/io/threemf.cpp) is 95 lines: vertices, triangles,
  one build item, identity transform, write. No `SetMetaData`, no production extension,
  no per-object attributes, no beam lattice. I confirmed this by reading the file.
- Therefore **the recommendation reaches the slicer only by the user reading it and
  typing it in.** The exported file carries no infill instruction whatsoever.
- The gyroid the user's part contains is **the slicer's gyroid**, at the slicer's cell
  size, generated at slice time from the slicer's own infill algorithm. TopOpt never
  generates, sees, meshes, or exports that geometry. It never has.
- Worth flagging for planning: **the app's "Export .3mf" is still a placeholder**
  ([ResultsScreen.swift:908-911](app/TopOptKit/Sources/TopOptFlows/ResultsScreen.swift:908),
  M7.9) — it shows a toast and writes no file. Only the CLI writes 3MF today. Any
  proposal in this document that involves "what we put in the exported file" is
  downstream of work that has not landed.

This is the single most important context for everything below: **TopOpt has never been
in the business of authoring interior structure.** Adding lattice generation is not an
extension of an existing capability; it is a new capability class, and it lands squarely
against [ARCHITECTURE §2](docs/ARCHITECTURE.md:32) *"Not a slicer."*

### 1b. `infill_margin_knockdown` / Gibson-Ashby f^1.5 — where, and what it assumes

**Where (core):** [`minimize_plastic.cpp:67-72`](core/src/simp/minimize_plastic.cpp:67):

```cpp
double infill_margin_knockdown(double infill_percent) {
  const double f = infill_percent / 100.0;
  if (f >= 1.0) return 1.0;  // solid / unset: exact 1.0, byte-identical gate
  if (f <= 0.0) return kKnockdownFloor;
  return std::max(std::pow(f, kKnockdownExponent), kKnockdownFloor);
}
```

`kKnockdownExponent = 1.5`, `kKnockdownFloor = 1e-3`. It is applied at **exactly two
expressions**, both comparisons at the ladder's acceptance gate
([:567-568](core/src/simp/minimize_plastic.cpp:567) and
[:596-597](core/src/simp/minimize_plastic.cpp:596)):

```cpp
variant.accepted = margin.worst_case * infill_knockdown >= options.margin_stop;
```

The **stored** margin is the solid margin ([:553](core/src/simp/minimize_plastic.cpp:553)).
The code's own comment is unambiguous: *"applied ONLY to what the acceptance test
compares, never to the FEA, the stress field, or the displayed value."*

**Where (app):** re-applied post-hoc for **display** —
[`ResultsModel.swift:1497-1499`](app/TopOptKit/Sources/TopOptFlows/ResultsModel.swift:1497)
(`worstCaseMargin * knockdown`) and
[`:514`](app/TopOptKit/Sources/TopOptFlows/ResultsModel.swift:514)
(`effectiveYieldStrengthMPa = yieldStrengthMPa * infillKnockdown`), which keys the stress
heatmap scale, the legend and the hot-spot readout.

**Answer to "display or FEA": neither, exactly — and this matters.** It is *not* purely
cosmetic (it changes which ladder rung is accepted, so it changes the shipped geometry),
and it is *not* in the FEA (the solver never sees a reduced modulus). It is a scalar
applied to a scalar, after the solve. Confirmed by absence: zero `infill` hits in
`core/src/fea/`. The modulus law is pure SIMP density
([simp.cpp:85](core/src/simp/simp.cpp:85)): `pow(rho, params.penalty) * params.youngs_modulus`,
where `rho` is **topology** density, not print infill.

**What it assumes:** a **single uniform scalar `f` for the entire part**. The signature is
`double → double`; the storage is one field
([pipeline.hpp:239](core/include/topopt/pipeline.hpp:239) `double infill_percent = 100.0;`);
it is hoisted **once, outside the rung loop**
([:342](core/src/simp/minimize_plastic.cpp:342)), described in-code as *"a single
rung-independent scalar."* No voxel index appears anywhere near it.

The curve is explicitly provisional — [:48](core/src/simp/minimize_plastic.cpp:48):
*"CURVE (SEED — the maintainer tunes this; do NOT treat it as final)"* — and it names its
own conservatism: it *"deliberately ignores the load the solid perimeters/walls of a real
slice carry, so it UNDER-estimates strength."*

**What breaks if infill VARIES spatially — three failures, escalating:**

1. **The reduction order is backwards.**
   [`compute_stress_margin`](core/src/settings/report.cpp:388) takes **already-reduced
   scalars** (`double max_von_mises_stress, double max_interlayer_tension`) and returns
   `worst_case = min(in_plane, interlayer)`. The knockdown then multiplies that *after*
   the `min()`. With varying `f` the correct quantity is per-voxel —
   `margin(x) = f(x)^1.5 · yield / σ(x)` — and its minimum is generally **not** at the
   solid-stress hot spot. A moderately stressed voxel at 10 % infill can govern over the
   peak-stress voxel at 60 %. Taking the scalar picks the **wrong critical location**,
   and can be **non-conservative** — the one direction this code's comments promise it
   never errs in.
2. **The stress field itself becomes wrong.** Sparse regions are more compliant, so load
   **redistributes** toward dense regions. But `f` never enters the solve, so `σ(x)` is
   computed for a uniformly-solid part. You would be scaling a stress field that no
   longer describes the object. **This is not fixable by any post-hoc scalar**, however
   clever — a scalar cannot represent a stiffness field.
3. **The display premise collapses.** There is no single `effectiveYieldStrengthMPa`, so
   the "one colour = one physical safety level" heatmap contract
   ([ResultsModel.swift:650-653](app/TopOptKit/Sources/TopOptFlows/ResultsModel.swift:650))
   has no meaning. The app never holds the field — only `maxStressMPa` — so the failure
   headline, legend and `LayerShear.classify` all consume scalars that would no longer exist.

### 1c. The Failure chip — "Holds ~465 lbs at 45% gyroid"

Traced end to end. The whole formula, one line:

```
lbs = (yieldMPa × (infill/100)^1.5 / peakVonMisesMPa) × totalLoadKg × 2.20462
```

Chain: `peak = max(vonMisesField)` (**core FEA, solid material**) →
`effectiveYield = yieldMPa × f^1.5`
([ResultsModel.swift:514](app/TopOptKit/Sources/TopOptFlows/ResultsModel.swift:514)) →
`multiplier = effectiveYield / peak` → `failKg = multiplier × appliedLoadKg`
([:1137](app/TopOptKit/Sources/TopOptFlows/ResultsModel.swift:1137)) → × 2.20462
(`ForceModel.kgToLb`). Headline assembled at
[:1153](app/TopOptKit/Sources/TopOptFlows/ResultsModel.swift:1153); the `at N% gyroid`
suffix is suppressed for solid by
[`infillDescriptor`](app/TopOptKit/Sources/TopOptFlows/ResultsModel.swift:1160)
(`percent < 100 ? "\(percent)% \(pattern)" : nil`).

Provenance: `peak` is core-computed; `yieldStrengthMPa` is a materials.json constant;
`appliedLoadKg` is **app-side user data** (ForceModel, not a core field — consistent with
the standing note that applied load is app-side); infill is user input **locked at project
creation**, so the number is a fixed FEA result post-scaled by a constant.

**What it would mean for a voronoi/lattice geometry: nothing defensible.** The `f^1.5`
term is a Gibson-Ashby cellular-solid scaling whose exponent is a **seed the maintainer
has not yet tuned even for gyroid**. Gibson-Ashby is not one law — it is a family, and the
exponent encodes the cell's **deformation mode**: bending-dominated (open-cell foam,
random voronoi) scales near `f^2`, stretch-dominated (a well-conditioned truss) scales
nearer `f^1`. A random voronoi strut network and a gyroid sheet are *different structures
with different exponents and different coefficients*. Reusing `f^1.5` for voronoi produces
a number with **no basis at all** — not conservative, not optimistic, just unfounded. And
it would be printed on screen in pounds, next to the word "Holds."

### 1d. ARCHITECTURE §2 — the FEA solves SOLID. Confirmed.

Confirmed three independent ways: the modulus law is
[`pow(rho, penalty) * params.youngs_modulus`](core/src/simp/simp.cpp:85) with `rho` =
topology density and `params.youngs_modulus` = the **solid** modulus; `grep -i infill`
returns **zero** hits across `core/src/fea/`; and the standing decision says so in words
(DECISIONS.md, 2026-07-11): *"EXPLICITLY: infill does NOT enter the FEA. The solver
continues to model kept material at full solid modulus (ARCHITECTURE §2 stands,
unchanged — infill is still not simulated)."*

**A correction to the task's framing, offered because it changes the cost of the ask:
there is no M8.** [ARCHITECTURE §9](docs/ARCHITECTURE.md:170) enumerates **M1–M7 only**,
and `grep -rn "M8\b" docs/` returns **zero hits** — ROADMAP.md has no M8. So "M8-gated"
does not mean "scheduled for a later milestone." It means:

> **create a milestone that does not exist, which requires a DECISIONS.md entry amending
> ARCHITECTURE §2** — a file that is immutable to agents ([§8.1](docs/ARCHITECTURE.md:150))
> and whose §2 currently reads *"Not a research project in infill homogenization."*

That is a maintainer-only act of scope change, not a backlog item. Everything below marked
"M8" carries that full price.

**Which proposed features require amending §2:**

| Feature | Amends §2? | Why |
|---|:--:|---|
| Cosmetic lace on the exported mesh, safety readout dropped | **No** | No structural claim is made; §2 is untouched. But see STEP 3c — it is not cheap. |
| Cosmetic lace, safety readout **retained** | **Yes (M8)** | The readout would describe a different object. Same failure mode as MTOP/ML up-res. |
| Voronoi struts replacing solid, re-verified by FEA on the lattice | **No** — §2 stands | Nothing is homogenized; the lattice *is* the FEA'd object. Blocked by cost, not architecture (STEP 3c). |
| Voronoi struts, margin inferred by a knockdown | **Yes (M8)** | Requires an unfounded new Gibson-Ashby law (§1c) and infill-as-material. |
| Spatially-varying infill driven by the stress field | **Yes (M8)** | Requires `f` inside the modulus law — literally the thing §2 excludes and the 2026-07-11 decision forbids. |
| Uniform-infill knockdown (today's behaviour) | **No** | Already shipped; a scalar on a scalar at the acceptance gate. |

---

## STEP 2 — THE HONESTY FORK

The project already has a settled rule for exactly this situation, and it should decide
this question. **M7-ML, the non-negotiable track constraint:**

> *"every design shown to a user is certified by a real FEA pass against real material
> properties BEFORE display. The ML output is NEVER the source of truth... A design that
> fails its certifying FEA is rejected/re-refined, never shipped."*

The generalisation is: **the object the numbers describe must be the object in the file.**
Every candidate below is judged against that.

### (i) NO STRUCTURAL CLAIM — cosmetic lace on the exported mesh

The app drops or re-verifies the safety readout. **Honest if labelled** — that much is
true, and there is precedent: [`smooth_factor`](core/include/topopt/job.hpp:63) is an
existing, shipped, opt-in export-only knob that changes *"ONLY the surface tessellation of
the exported STL/3MF — NOT the design, the physics, the optimizer, the density field, the
JobReport."* A cosmetic lattice is that pattern, taken much further.

**But "honest if labelled" is doing more work than it appears, in three ways:**

1. **It is not one label, it is the whole results screen.** Dropping "the safety readout"
   means dropping the Failure chip, the stress heatmap (whose scale is
   `effectiveYieldStrengthMPa`), the hot-spot callout, the margin, the layer-shear
   classification, and the flex animation — every one of them describes the solid object,
   not the lace. What remains is a picture. The M7.8b honesty surface, which is *supposed*
   to travel with the exported file, would have to say "this file is not the analysed
   part."
2. **`mass_grams` is already wrong for it, silently.**
   [`minimize_plastic.cpp:513`](core/src/simp/minimize_plastic.cpp:513) computes
   `density_g_cm3 × printed_voxels × voxel_volume` — a **solid-voxel mass** — and it
   passes to the app unmodified
   ([ResultsModel.swift:1490](app/TopOptKit/Sources/TopOptFlows/ResultsModel.swift:1490))
   and is displayed as `"· plastic"`. `smooth_factor` already had to flag a
   *"mesh-vs-readout volume gap."* A cosmetic lattice detonates that gap: the headline
   mass number would describe a solid rib while the file contains lace. Mass is not
   usually thought of as a safety number, so it is the one most likely to be forgotten.
3. **It bypasses V3's feature gate rather than passing it.** V3 requires *"Minimum feature
   size ≥ 2 voxels"* ([ARCHITECTURE.md:141](docs/ARCHITECTURE.md:141)), and
   [`min_feature_violations(grid, density, iso)`](core/include/topopt/voxel.hpp:270)
   evaluates it on the **voxel density field** — *"gate 4: solid voxels not in any 2x2x2
   block."* A mesh-space lattice is **invisible** to that check. "It passes V3" would be
   vacuously true, which is worse than failing: the gate would report green on a mesh it
   never examined. (Note also: at 64³ on a 200 mm part, V3's 2-voxel rule means a
   *voxel-space* lattice strut must be ≥ **6.25 mm** — thicker than the 4.69 mm minimum
   feature. A voxel-space lattice cannot be fine and pass V3. Any fine lattice must live
   in mesh space, i.e. in exactly the blind spot just described.)

**Is this useful, or does a user who wanted lace also want it to hold?**

My honest read: **a user who asks for lace on a load-bearing bracket wants it to hold.**
The entire premise of TopOpt is "this shape is optimized *for your load*." A user who has
just placed force arrows, watched a flex animation, and read "Holds ~465 lbs" does not
then want a decorative object. Lace-without-numbers is a product for someone printing a
lamp shade — and that person did not need topology optimization to get there. The feature
is coherent; I am not persuaded it has a user *in this app*.

There is one genuinely useful non-structural variant, worth separating out: **a
visualisation-only lace** (render it in the viewer, never export it, never touch the
file). That is pure eye-candy with zero honesty surface, because no file leaves. It
belongs with M7.11a/M7.11b matcaps in **Parked — cosmetics**
([ROADMAP.md:663](docs/ROADMAP.md:663)), and it is where "I want it to look organic"
should go if the motivation is genuinely aesthetic. It still costs what STEP 3c says.

**Cost to make it honest:** the labelling itself is cheap (it is copy). The
*de-claiming* is not: you must suppress six coupled readouts on one code path, fix or
caveat `mass_grams`, and make V3's vacuous green explicit rather than silent. Call it a
real M7.8b-sized chunk of app work, not a weekend. And at the end you have shipped a
feature whose selling point is that it tells you less.

### (ii) STRUCTURAL — the printed part differs from the FEA'd part

**Covers:** voronoi struts replacing solid; spatially-varying infill; any lattice where
the margin/heatmap/failure load is retained.

**Verdict: NOT SHIPPABLE as-is.** This is precisely the failure mode the project rejected
MTOP and ML up-res for, and the M7-ML constraint was written to prevent. The stress
heatmap, the margin and the "Holds ~465 lbs" chip would describe an object that is not the
one in the exported file. The maintainer's stated line — *refuses to ship a number that
describes a different object than the file* — is not a preference here; it is the
project's own written rule.

Two routes make it honest, and only two:

**Route A — re-verify by FEA on the lattice.** The lattice becomes the analysed object;
§2 is untouched (nothing is homogenized); the M7-ML rule is satisfied literally. This is
architecturally *clean* — and computationally fatal. The FEA is one hex element per voxel
([ARCHITECTURE §4](docs/ARCHITECTURE.md:76)). To resolve a 2.5 mm strut you need voxels
several times smaller, i.e. a grid **several times finer than 128³ in each axis** — and
128³ (≈6.4M DOF) is already the thing the maintainer cannot afford. 128³ is noted in-repo
as *"not viable"* for the FEA budget; a lattice-resolving grid is 10–100× beyond that. It
is not a matter of waiting longer on an iPad; it is off the table by orders of magnitude.
**Cost: unbounded. This route does not exist in practice.**

**Route B — homogenization (the milestone that doesn't exist).** Model the lattice's
effective anisotropic stiffness tensor per region and put *that* in the FEA. This is the
technically correct answer, it is standard practice in the literature, and it is exactly
what [ARCHITECTURE §2](docs/ARCHITECTURE.md:35) excludes in one sentence: *"Not a research
project in infill homogenization."* **Cost:** a DECISIONS entry amending an immutable
file; a new milestone; effective-property derivation and its own validation gates (you
cannot certify homogenized properties against Euler–Bernoulli — V1 does not cover it, so
new fixtures and a new gate class are required); per-region tensor plumbing through
assembly; and re-tuning every downstream margin/settings rule. This is the largest single
piece of work anyone has proposed for this codebase, and its payoff is *not* finer ribs
(STEP 0) — it is honest variable infill.

---

## STEP 3 — WHAT THE PIPELINE CAN CARRY

### 3a. Does 3MF support variable infill / modifier meshes / per-region density?

**3MF core: no.** The core specification has **no notion of infill density**. Print
settings are not part of core; they are vendor extensions or vendor metadata. The 3MF
**Beam Lattice extension** (v1.2.0) encodes *geometry only* — beams as conical frustums
between vertices with per-endpoint radii, balls, and cap modes — and, per my read of the
spec, makes **no mention of infill density, slicer settings, or print parameters**. Its
stated purpose is representing lattices whose triangle counts would be unmanageable as
meshes ([spec_beamlattice](https://github.com/3MFConsortium/spec_beamlattice/blob/master/3MF%20Beam%20Lattice%20Extension.md)).

**Who honors Beam Lattice: essentially nobody in consumer FDM.** The 3MF Consortium's own
[compatibility matrix](https://3mf.io/compatibility-matrix/) lists **only 3-matic**
(Materialise, an industrial tool) as supporting the BEAM extension. PrusaSlicer, Cura,
Bambu Studio and OrcaSlicer are all listed with **core import/export only** — no beam
lattice. (The matrix notes compatibility is *self-reported by vendors* and not
independently verified, so treat it as an upper bound on support, not a lower one.)
`lib3mf` itself does implement Beam Lattice and a Volumetric extension
([lib3mf](https://github.com/3MFConsortium/lib3mf)) — so **the library we already link
could write beam lattices that no consumer slicer would read.** Our own tree touches none
of it: `grep -rli "beamlattice"` over `core/` returns nothing.

**Per-region settings: expressible, but only as three mutually incompatible vendor blobs.**

| Slicer | Modifier / per-object mechanism | Carried in 3MF? | Source |
|---|---|---|---|
| PrusaSlicer | Modifier meshes; per-model settings | Yes — in **its own project 3MF**, as `Metadata/Slic3r_PE_model.config` (`MODEL_CONFIG_FILE`), with per-volume keys incl. `modifier`, `volume_type`, `matrix` | [3mf.cpp](https://github.com/prusa3d/PrusaSlicer/blob/master/src/libslic3r/Format/3mf.cpp), [Modifiers KB](https://help.prusa3d.com/article/modifiers_1767), [Per-model settings](https://help.prusa3d.com/article/per-model-settings_1674) |
| Bambu Studio | Modifier parts; per-object settings | Yes — `Metadata/model_settings.config` in **its own project 3MF** | [3MF project handling](https://deepwiki.com/bambulab/BambuStudio/2.3-3mf-project-file-handling) |
| Cura | Per-model settings | Yes — via **Cura-namespaced metadata** parsed by libSavitar (namespace `http://software.ultimaker.com/xml/cura/3mf/2015/10`) and applied in `ThreeMFReader` | [ThreeMFReader.py](https://github.com/Ultimaker/Cura/blob/main/plugins/3MFReader/ThreeMFReader.py), [libSavitar#22](https://github.com/Ultimaker/libSavitar/issues/22) |

The critical distinction the task asked me to draw: **each slicer's `.3mf` is that
slicer's native *project* format** (3MF core + a vendor metadata blob), not an
interoperable exchange file. A plain 3MF written by a third-party tool — which is exactly
what [threemf.cpp](core/src/io/threemf.cpp) writes — carries no settings and will be
imported as bare geometry everywhere.

**And writing a vendor blob is actively hostile in at least one case:** Bambu's tracker
carries [BambuStudio#3591](https://github.com/bambulab/BambuStudio/issues/3591) —
*"Re-importing a non BL .3mf should not reset the per object settings already in the
project"* — i.e. importing a **non-Bambu** 3MF **resets per-object settings to default**.
That is the exact path a TopOpt-authored file would take. Cross-slicer 3MF project
interchange is broadly known-broken ([BambuStudio#3316](https://github.com/bambulab/BambuStudio/issues/3316),
[#169](https://github.com/bambulab/BambuStudio/issues/169)).

**Adaptive/gradient infill is slicer-native and not externally drivable.** Cura's
**Gradual Infill Steps** halves infill density per step measured downward from top
surfaces ([Ultimaker: Infill settings](https://support.ultimaker.com/hc/en-us/articles/360012607079-Infill-settings));
Prusa has adaptive/support cubic. These are computed by the slicer from its own geometry
analysis. They are keyed to **distance from the top surface** — a printability heuristic —
**not to stress**. There is no mechanism by which TopOpt hands them a field.

**Bottom line for 3a:** variable infill *is* expressible — by writing three different,
undocumented, vendor-specific, version-unstable metadata blobs, one per target slicer, and
maintaining them. Doing so makes TopOpt a **slicer project-file generator**, against
[ARCHITECTURE §2](docs/ARCHITECTURE.md:32) *"Not a slicer."* The portable, standards-based
option (Beam Lattice) is read by no consumer slicer.

### 3b. Could TopOpt drive variable infill from the per-voxel stress field it already computes?

The field genuinely exists — `vonMisesField` is already computed, already streamed to the
app, already drives the heatmap. The idea is natural. **The honest margin, however, needs
M8's homogenization. A conservative scalar cannot rescue it, and this is worth being
precise about, because "just be conservative" is the tempting middle path the task warned
against inventing.**

Consider the two conservative dodges:

- **Dodge 1 — use the lowest infill in a stressed region as a global scalar.** This is not
  actually conservative, for the reason in §1b(2): `σ(x)` is computed on a **uniformly
  solid** part. A real part with sparse regions redistributes load; its true peak stress
  can **exceed** the solid part's peak, and can appear somewhere the solid analysis shows
  as quiet. `f_min^1.5 × yield / σ_solid_peak` is therefore **not a rigorous bound** —
  it is a plausible-looking number derived from the wrong stress field. You cannot bound
  with a field that is wrong about the object.
- **Dodge 2 — use `f_min` over the whole part.** Now the margin is that of a uniform print
  at the sparsest density — which is (a) still built on the wrong `σ(x)`, per Dodge 1, and
  (b) so pessimistic it stops the ladder early and throws away the entire benefit of being
  dense-where-stressed. You would pay full engineering cost for a feature whose reported
  margin is *worse* than today's.

**So: the answer to 3b is M8's homogenization, unambiguously.** A correct variable-infill
margin needs per-voxel `margin(x) = f(x)^1.5 · yield / σ(x)` **and** a `σ(x)` computed
with `f` in the modulus law — i.e. `f` inside the FEA — i.e. the thing
[ARCHITECTURE §2](docs/ARCHITECTURE.md:35) excludes and the 2026-07-11 decision explicitly
forbids. The reduction-order inversion (§1b(1)) is the *easy* half and is feasible on its
own; it is worthless without the hard half.

### 3c. Lattice GENERATION cost — this kills even the cosmetic version

**Anchor (measured, in-repo, handoff 087 — a genuinely lacy 64×24×40 result on a
200×75×125 mm part):**

| factor | MC lattice | triangles | viewer upload | MC time |
|---:|---|---:|---:|---:|
| 1× | 64×24×40 | 32,460 | 0.58 MB | 24 ms |
| **2× (shipped)** | 128×48×80 | **124,856** | **2.25 MB** | 111 ms |
| 4× | 256×96×160 | 506,808 | 9.12 MB | 587 ms |

From that same table the app's real cost per triangle is **18 bytes** (561,708 floats ÷
124,856 tris = 4.5 float32/tri). Handoff 086 already recommends **2× as the default** and
warns 4× *"risks choking the viewer / bloating the STL."* **So the shipped budget is ~125k
triangles.** That is the number every estimate below must be compared against.

**Gyroid/TPMS generation cost — MY ESTIMATE, assumptions stated explicitly.**
Assumptions: part bbox 200×100×150 mm; ~30 % occupied by the optimized shape; gyroid
surface area per cubic unit cell ≈ 3.09 L² (the standard Schoen-gyroid value — **I could
not source this to a primary reference in the time available; treat it as approximate**);
MC triangles ≈ 2A/h²; h = L/12 (12 voxels per cell for an acceptable TPMS surface).
The conclusion is robust to large errors in these constants — the results are 50–400×
over budget, so even a 2× error changes nothing.

| gyroid cell L | voxel h | triangles | vertex buffer | binary STL | implicit field (f32) |
|---:|---:|---:|---:|---:|---:|
| 10 mm | 0.83 mm | **0.8 M** | 14 MB | 40 MB | 55 MB |
| 5 mm | 0.42 mm | **6.4 M** | 115 MB | 320 MB | 442 MB |
| 2.5 mm | 0.21 mm | **51 M** | 923 MB | 2,563 MB | 3,539 MB |

**Now the decisive observation.** The motivation is fine structure inside ~**9.4 mm**
members. For a lattice to *read* as lace you need at least 2–3 cells across a member:

| cells across a 9.4 mm member | cell L | triangles | binary STL | field |
|---:|---:|---:|---:|---:|
| 2 | 4.69 mm | **7.8 M** | 388 MB | 536 MB |
| 3 | 3.13 mm | **26.1 M** | 1,306 MB | 1,803 MB |

Against a shipped viewer budget of **125k triangles** and an iOS per-app memory ceiling of
roughly **half physical RAM** — ~3 GB on a 6 GB iPad Pro, with jetsam force-quitting on
breach ([Apple: jetsam event reports](https://developer.apple.com/documentation/xcode/identifying-high-memory-use-with-jetsam-event-reports),
[9to5Mac on the iPad Pro per-app cap](https://9to5mac.com/2021/05/28/ipad-pro-ram-limits/)) —
and remembering the app targets **iOS 16**, i.e. older iPads with *less*.

**The trap, stated plainly:** the only affordable cell size (**10 mm**, 0.8 M triangles) is
**larger than the 9.4 mm member it is supposed to decorate**. A 10 mm gyroid cell does not
fit inside a 9.4 mm rib. The lattice only reads as fine structure at 3–5 mm cells, which
costs **8–26 M triangles and 0.5–1.8 GB of field memory** — 60–200× the viewer budget, a
0.4–1.3 GB export through a share sheet, and a plausible jetsam on the target device.

**So the "cheap cosmetic option" is not cheap.** It is cheap only at a fineness that
defeats its own purpose. This is independent of every honesty argument above — it is
arithmetic. And a 10 M-triangle STL handed to a desktop slicer is its own problem, on a
machine we do not control.

---

## STEP 4 — RANKING

Given: iPad hardware (iOS 16, ~half-RAM per-app cap), an FEA that solves solid, a shipped
gyroid-infill + Gibson-Ashby path, a ~125k-triangle viewer budget, and a maintainer who
refuses to ship a number describing a different object than the file.

### #1 — Do none of it. Spend the effort on making 128³ affordable.

This is the honest #1, and it is not a dodge — it is the only option that actually serves
the stated motivation.

- It is **the only route to finer structure at all** (STEP 0). Every lattice variant leaves
  the ribs exactly as chunky as they are today.
- The capability **already ships** (`fine: 128`); only the cost is missing.
- The target is **bounded**: 128³ clears the floor at 2.5 mm and 160³ buys nothing more.
  This is a finite goal with a known finish line — rare, and worth a lot.
- It is **the track already in flight**: matrix-free multigrid (077/078), MMA plateau
  termination (086, already 3.1× better per-iteration than assumed — 4.73 s/iter, not
  14.75). The 64³ 4-rung ladder is ~41 min at plateau; the gap to a usable 128³ is large
  but it is the *same kind of work the project is already doing well*.
- It requires **no architecture change, no §2 amendment, no new honesty surface**. Every
  number on the results screen keeps describing the file. V3 keeps meaning what it says.

There is also a cheap partial win available immediately: **96³ takes the effective min
feature from 4.69 mm to 3.12 mm** (a 33 % improvement) and already exists as "Balanced."
If the maintainer has not compared a 96³ result side-by-side with 64³ specifically for
*chunkiness*, that is a zero-cost experiment that might substantially move the complaint.
(Reported ~2.25 h for 2 of 4 rungs at 96³ is the maintainer's device figure, not a
documented benchmark — it is worth measuring properly against the post-086 numbers, since
086 found the prior per-iteration estimate was 3.1× pessimistic.)

### #2 — Viewer-only lace, parked with the other cosmetics.

**If and only if the motivation is honestly "I want it to look cool," not "my ribs are too
chunky."** Render-only; never exported; no file leaves; therefore no honesty surface at
all. Belongs next to matcaps in
[Parked — cosmetics](docs/ROADMAP.md:663). **But** STEP 3c applies in full: at a cell size
that reads as lace this is 8–26 M triangles, i.e. **it does not fit on the target device
either**. So this is ranked #2 only in the sense that it is the least-harmful lattice
idea, not because it is viable. Realistically it needs a level-of-detail scheme or a
screen-space/shader trick (fake the lace in the fragment shader, never generate geometry)
to be feasible at all — which is a genuinely different and much smaller project, and the
one I would actually suggest if "make it look organic" is the real goal.

### #3 — Cosmetic lace on the *exported* mesh, all safety readouts dropped.

Honest if labelled, and §2-clean. Ranked below #2 because it is strictly worse: it costs
everything #2 costs *plus* the de-claiming work (six coupled readouts, the `mass_grams`
gap, V3's vacuous green), and it ships a file that no longer matches the analysis. **I do
not recommend it.** As STEP 2 argues: a user who placed force arrows and read "Holds ~465
lbs" wants a part that holds, not a decoration.

### #4 — Everything else: M8, i.e. not a backlog item but a scope change.

Spatially-varying infill from the stress field; voronoi struts with an inferred margin;
any lattice retaining the safety readout. All require amending
[ARCHITECTURE §2](docs/ARCHITECTURE.md:35) via a DECISIONS entry, creating a milestone
that does not exist, and building homogenization plus a new validation-gate class (V1's
beam theory cannot certify effective properties). And — the point that should settle it —
**none of this produces finer ribs.** It produces honest variable infill: a real feature,
a large one, worth wanting on its own merits, and **not an answer to the question that
prompted this research.**

Route A (re-verify by FEA on the lattice) deserves one line of its own because it is the
only structurally *clean* answer and it is worth knowing why it fails: one hex element per
voxel means resolving a 2.5 mm strut needs a grid many times finer than 128³ — the
resolution already out of budget by a wide margin. It is not slow; it is impossible.

### The recommendation in one sentence

**Lattice tooling is a different feature from the one the motivation asks for; the cosmetic
version is honest but — contrary to expectation — *not* cheap on an iPad at any fineness
that would satisfy the motivation; and everything with a structural claim is an
§2-amending scope change that still leaves the ribs chunky. Fund 128³.**

---

## Found in passing (NOT acted on; reported for the maintainer)

Surfaced while tracing the infill path. None are lattice issues; none were touched.

1. **The recommended infill and the knockdown input are decoupled — possibly
   safety-relevant.** The rule engine recommends 15–60 % (`rules.json`), but the knockdown
   consumes the **user's PrintParams slider**, defaulting to a sentinel that means "no
   override" → core default `100` → knockdown **exactly 1.0**
   ([bridge.cpp:825-831](app/TopOptKit/Sources/TopOptBridge/bridge.cpp:825)). So a user who
   accepts a recommended 25 % infill and never touches the slider gets a ladder that
   **gates as if the part were solid** — the precise scenario the 2026-07-11 decision added
   the knockdown to prevent. The bridge comment calls this *"use the M5.1 recommendation,
   i.e. no knockdown,"* which reads as intentional, but the two numbers are not connected.
   Worth a maintainer ruling.
2. **The core/app knockdown copies are not cross-pinned in CI.** They are currently
   branch-for-branch identical, but `ResultsModelTests.swift:842-852` tests the Swift
   constant against **hardcoded literals**, not against the core. The core comment
   anticipates tuning `p` toward 2 ([minimize_plastic.cpp:54-56](core/src/simp/minimize_plastic.cpp:54)) —
   if that happens, nothing fails, and the app would display margins the ladder did not
   gate on. (This is the standing "keep the two copies in sync" hazard, now with a named
   mechanism for how it would break.)
3. **`mass_grams` is a solid mass presented as "plastic."**
   [minimize_plastic.cpp:513](core/src/simp/minimize_plastic.cpp:513) counts printed voxels
   at full density and the app renders it `"· plastic"` while the project recommends 20 %
   gyroid. As a *relative* comparator across variants it is fine, which may well be the
   intent; as an absolute gram figure it overstates plastic used by roughly the inverse of
   the infill fraction. Flagging for a maintainer check, not asserting a defect.

---

## Verification

- **Read-only confirmed.** `git status --short` and `git diff --stat` were empty
  throughout; the working tree now contains exactly one new file, this report.
- No code, test, fixture, ROADMAP, DECISIONS or ARCHITECTURE file was modified.
- No ROADMAP box checked.
- No tests were run — nothing was changed to test. Every code claim above is a first-hand
  read of the cited file:line in this worktree.
- Every external factual claim about 3MF/slicer behaviour carries a URL in §3a. The one
  quantity I could **not** source (gyroid area constant ≈ 3.09 L²) is labelled as an
  estimate at the point of use, with a note on why the conclusion survives it.
- The min-feature and lattice-cost tables are my own arithmetic, reproduced from formulas
  cited in-tree ([simp.cpp:296](core/src/simp/simp.cpp:296)) and from measured triangle
  counts in handoff 087.
