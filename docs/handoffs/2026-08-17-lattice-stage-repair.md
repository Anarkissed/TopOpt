# 2026-08-17 — lattice-stage-repair: make a lattice possible at all

Evidence: `evidence/2026-08-17-lattice-stage-repair/`
Merge base: `01f8dab5` (Merge PR #337, render-quality)

> ★ "If everything is on auto and the density and depth are stuck at 5% and 4mm
> respectively, then that makes it an IMPOSSIBILITY to actually create a lattice."

---

## §0 — THE ANSWERS

*(Filled in as each is MEASURED. Anything not measured is marked NOT MEASURED
and says why — the standing rule on this branch.)*

**Where did the 5% come from? ★ MEASURED — IT IS THE BAND FLOOR, TAKEN AS AUTO'S
ANSWER, AT `LatticeFaceCard.swift:225`.**

```swift
let auto = limits.rhoMin > 0 ? limits.rhoMin : 0.1
```

`limits.rhoMin` is core's `lattice_rho_min(Octet)` = **0.05047**, which formats
as "5%". It is not a graded value that happens to land there, and it is **not**
the documented auto-density deadlock the brief's §1(a) suspected: the card's Auto
branch never looks at a stress field, never looks at the depth, and has no
fallback path at all — it *is* `rhoMin`, unconditionally. Proved by holding
everything else fixed and moving the depth 4 mm → 40 mm: the density does not
move by one ULP (`testHisCardIsReproducedExactlyByTheShippingDerivation`).

**Why were depth and the handle separate? ★ MEASURED — TWO RESOLVERS FOR ONE
NUMBER, AND THE DRAWER READ THE WRONG ONE.** Three lines, all app-side:

| | |
|---|---|
| `WorkspacePlaceholder.swift:4973` (pre-fix) | the cards were previewed **one face per GROUP**, at `latticeSlabDepthMM(g.id)` — the group's depth |
| `WorkspacePlaceholder.swift:4925` (pre-fix) | the drawer under a face/region row was handed **that group card**, while being labelled `latticeSlabDepthMM(ref, in: g.id)` — the *selectable's* depth |
| `LatticeRegionDrawer.swift:146` (pre-fix) | the Depth row then printed `c.depthMM` — **the card's** — so the `depthMM:` argument was dead whenever a card existed |

So `writeLatticeDepthMM` (the 3D handle, and the row chip's drag) wrote
`lattice.selectableDepthMM`; the row chip re-read it and moved; and the drawer
beneath it kept showing 4 mm, with a cell, a strut, a cells-across and a mass all
computed at 4 mm. **Not a stale cache — the per-selectable depth was never an
input to the derivation.**

**What does the card read after both fixes? ★ MEASURED — on
`M2_verticalStand.step`, face 2, his 0.45 mm bead:**

| depth | density | cells across | cell | strut | verdict |
|---|---|---|---|---|---|
| **4.00 mm** (his default) | **60%** | **3.4** | **1.17 mm** | **0.45 mm** | Out of regime |
| **6.00 mm** | 58% | **5.0** | 1.20 mm | 0.45 mm | ★ **Certified** |
| 8.00 mm | 37% | 5.0 | 1.60 mm | 0.45 mm | Certified |
| 12.00 mm | 20% | 5.0 | 2.40 mm | 0.45 mm | Certified |
| 24.65 mm | 5% | 5.0 | 4.93 mm | 0.45 mm | Certified |

His screenshot, for comparison: `4.0 mm · 5% · 0.8 cells · 4.93 mm · 0.32 mm`.
**All four were wrong and all four were app-side.**

★ **THE DIRECTION IS THE OPPOSITE OF THE OBVIOUS GUESS, and it is the prize.** A
deeper region admits a COARSER cell; strut diameter is LINEAR in cell size; so a
coarse cell clears one bead at a LIGHT density. Auto therefore gets *lighter* as
the region gets deeper — 60% at 4 mm, 5% at 24.65 mm. A deep region is exactly
where a lattice saves mass. (My first assertion asserted the reverse and failed;
the measurement corrected it.)

★ And the 5% at 24.65 mm is not the old bug returning: there the derivation
genuinely lands on the band floor, and unlike before, the strut it produces
(0.45 mm) PRINTS, so the card certifies instead of refusing. The objection was
never "5% is a forbidden number" — it was "5% was returned without deriving
anything".

**Does one region on his part certify? ★ YES — at 6.00 mm depth: Certified, 5.00
cells across, 58% density, 0.45 mm strut**
(`r1_fix2_card_rederived_on_his_part.txt`). Core's requirement is N* × the
DENSE-end floor = **5.87 mm**, not the 24.65 mm the old card implied.

---

## §3 — ★ THE BRIEF'S OWN ARITHMETIC WAS BUILT ON THE CARD'S WRONG CELL

The brief derives two routes out of his card: "at cell 4.93 mm the region needs
≥ 24.65 mm depth" or "at 4.0 mm depth the cell must be ≤ 0.80 mm". Both are
arithmetic on **4.93 mm**, and 4.93 mm is core's printability floor at the band's
**LIGHTEST** density — the coarsest floor there is.

Core does not pick that cell. `lattice_derive_cell_for_member` picks
`max(member/N*, min_printable_cell)` where `min_printable_cell` is the floor at
the band's **DENSEST** density, and then takes the *lightest density that prints
at that cell*. On the same region:

| | the card | core |
|---|---|---|
| cell | 4.93 mm | **1.173 mm** |
| density | 5% (band floor) | **60%** (lightest that prints there) |
| strut | 0.32 mm — "too thin" | **0.45 mm** — prints, exactly one bead |
| cells across, at 4 mm | 0.81 | **3.41** |
| depth needed for 5 cells | 24.65 mm | **5.87 mm** |

★ **The "six times short / 24.65 mm" reading is an artefact of the same bug.**
The real requirement on his part is a **5.87 mm** deep region — reachable — and
the "0.32 mm strut is under your 0.45 mm nozzle" problem **does not exist**: the
card computes the strut with `LatticeType.strutRadiusMM` (app), which
memory `app-octet-strut-law-differs-from-core` recorded as **1.4× off** core's
`octet_strut_diameter_mm`, and 0.45 / 0.32 = 1.41. The cell was chosen by core to
give exactly one bead; the app's law under-reports it and then refuses it.

`evidence/2026-08-17-lattice-stage-repair/r0_card_vs_core.txt`.

---

## THE METHOD

**Reproduction is analytic and needs no run — confirmed, not assumed (§0c).**
`LatticeFaceCardDerivation.card` is a pure function of (depth, held voxels,
spacing, bounds, limits, width). Every one of his card's eight numbers is
reproduced exactly from the shipping code, including the strings the drawer
renders (`"4.93 mm"`, `"0.8"`, `"5%"`, `"0.32 mm"`, `"85.2 g"`). The voxel count
feeds only the mass rows and comes from a **48³ preview** grid that is not the
run's grid. So a Fast · 64³ job is not the cheapest reproduction of this failure
and would not make the numbers more true; the run is where R4's certification is
demonstrated, not where the card comes from.

### Fix 1 (§2) — the depth and the handle are one value

`ProjectModel.latticeCardInputs()` resolves **one (key, face, depth) per drawer**
through the single `latticeSlabDepthMM` call the 3D plane, the row chip and the
protection spec already go through. The cards are derived from that list, keyed
by `LatticeSelectableRef.key`, and `LatticeRegionDrawer.make` prints the depth it
was handed rather than the card's copy. `LatticeRegionDrawer.depthDivergence`
makes "they cannot diverge" a checkable property rather than a convention — the
same shape `LatticeSlabDepth.mismatches` already uses.

Asserted **in both directions**, plus the protection tie (R3):

- dragging a handle moves the depth the card is derived at, and moves only that
  selectable — `testDraggingAHandleMovesTheDepthTheCardIsDerivedAt`
- typing a depth moves the 3D plane — `testTypingADepthMovesTheHandlesPlane`
- the protection depth still follows the same number, per face and per region —
  `testTheProtectionDepthStillFollowsTheSameNumber`
- a card derived at one depth can never be shown under another label, and the
  **shipping** card list never diverges, under three distinct depths so the check
  is not vacuous — `testTheShippingCardListNeverDivergesFromTheDepthInForce`

---

## BARS

| bar | state |
|---|---|
| R1 one fix, one run, one report | ✅ held until the maintainer said "keep going" |
| R2 auto density honest | ✅ derived from core, or an honest refusal |
| R3 depth ⇄ handle, both directions + protection | ✅ 5 assertions |
| R4 one region certifies end to end | ✅ 6.00 mm on his part |
| R5 nothing regresses | ✅ 1538 app tests, 0 failures — enumerated below |
| R6 root cause with file and line | ✅ §1 and §2 both |
| R7 no assertion weakened or deleted | ✅ census below |
| R8 cost measured directly, Release verified | ✅ `CMAKE_BUILD_TYPE=Release`; no wall-clock claim made |
| R9 no placeholders, no root scratch | ✅ |

### Fix 2 (§1) — the card asks CORE instead of re-deriving in Swift

`LatticeFaceCardDerivation.card` now makes ONE call to
`TopOptKit.latticeRegionDerivation` — the bridge onto
`lattice_derive_cell_for_member`, `lattice_min_density_for_strut` and
`octet_strut_diameter_mm`, the same functions the RUN calls. The cell, the
density, the strut and the cells-across are all core's; the app authors none of
them. `LatticeSectorDensity` (PR 336) already did this correctly — the face card
was the one surface that did not.

Three separate errors went with it:

1. the cell was `max(depth/N*, printabilityFloorMM)` — the floor at the band's
   LIGHTEST density. Core uses the DENSEST-end floor. 4.93 vs 1.17 mm, 4.2×.
2. `let auto = limits.rhoMin` — the band floor as Auto's answer, unconditional.
3. the strut came from `LatticeType.strutRadiusMM`, the app's own octet law,
   1.4× off core's — so the card refused its OWN Auto answer at a cell core had
   chosen to give exactly one bead. **That refusal was an artefact and it is
   gone.**

And the app half of §1(d): `ProjectModel.latticeDeclaredDensity` resolves the
mode's own number — per-group stated ▸ Uniform's generate density ▸ Auto (nil) —
through the same precedence the emitted job uses, and
`refreshLatticeFaceCards` passes it. **No shipping call site passed
`declaredDensity` at all before**, which is why "stuck at 5%" was true in every
mode.

R2 is asserted in both halves: Auto is a real derived value (it moves with the
region, agrees with core to 1e-12 at five depths, and its strut always prints),
and where core has no answer — unknown nozzle, member no lattice fits, declared
density too light to print — the card **refuses with the numbers it has** and
never certifies by omission. 10 assertions in
`LatticeAutoDensityIsDerivedTests`.

### ★ WHAT FIX 2 BROKE, AND WHAT THAT TAUGHT — 23 failures, read one by one

The first full sweep after fix 2 went **23 red**. Two were real defects in my own
change; the rest were fixtures tuned against numbers that describe no real
topology. None was glossed.

**★ DEFECT 1 — I left `bounds` and `limits` as DEAD PARAMETERS.** The rewrite
ignored them while every caller still passed them. That is precisely the defect
class this task exists to remove — an input that looks like it decides something
and does not — and I had shipped it into the very function I was fixing. Both are
now **gone from the signature**; `LatticeFaceCard` reads core and nothing else.

**★ DEFECT 2 — a declared density was BLANKED when the region could not take a
lattice.** The infeasible path returned `relativeDensity: 0`, so a user who typed
5% into a region nothing fits saw an empty row instead of "5%, and it will not
work here". That erases the user's own input; the refusal belongs in the VERDICT,
not in silence. Fixed, and asserted.

**★ ONE DELIBERATE CONTRACT CHANGE, marked rather than quietly loosened.** The
shipped bar was *"Auto can never refuse — a default that refuses is not a
default"* (§4c of the 2026-08-12 task). Below core's percolation floor there is
no lattice at all — the generator emits debris — and R2 of THIS task says Auto
must either derive a real value or say it cannot. So Auto now refuses there,
honestly. `testAutoNeverRefusesAtAnyDepthAndSaysSoWhereItCannot` states the
supersession in those terms, asserts the SAME property everywhere a lattice is
possible, and **counts both arms** so a sweep that only ever hit one branch
cannot pass while measuring half of it.

**★ THREE FIXTURES WERE TUNED TO INJECTED NUMBERS AND WOULD NOW PASS
VACUOUSLY.** `bounds(floor: 4.6026, cpm: 5)` and `limits(rhoMin: 0.2, rhoMax:
0.8)` describe no real topology. Under core's law a 30 mm slab certifies at
*every* nozzle and a 7 mm slab certifies at 0.45 mm — so the "thin slab", "one
bad region" and "profile changes the verdict" arms had all become no-ops. Each
was re-tuned to real values where the property genuinely flips (an 8 mm slab:
certified at 0.25 and 0.45 mm, out of regime at 0.80 mm) and each now asserts
that its negative arm really is negative. **No assertion was deleted; several are
stronger.**

**★ AND A SIXTH LINE-WIDTH SITE, caught by its own tripwire.**
`StrutLineWidthTests.testNoLatticeLineWidthSiteReadsAWallBead` counts the lattice
sites reading `printParams.strutLineWidthMM` and says "if this number moved,
audit the new site and update the count." `ProjectModel.latticeDeclaredDensity`
is the sixth. Audited: in UNIFORM mode it resolves the density the RUN generates
at, via `LatticeBounds.compute`, whose `lineWidthMM` drives the STRUT
printability floor — a lone unsupported extrusion, not a wall loop. A wall bead
there would put the card's density on the wrong floor and make it disagree with
the run. The count is updated **with that audit written down**, not bumped.

**★ MY OWN EVIDENCE HYGIENE FAILED FIRST.** I launched that sweep through
`grep -E "error:|Executed"`, which discarded every per-test failure line — so I
had "23 failures" and no way to see which. That is memory
`do-not-filter-a-check-you-cite-as-evidence`, on my own branch, and it cost a
full 24-minute re-run. Subsequent sweeps write the **whole** log and are read
unfiltered.

### R5 — the four things that already work, enumerated and re-run

The whole 1538-test suite is green, but R5 asks for these four by name, so they
are named and their guards were re-run against the rebuilt core:

| what must not regress | guard | result |
|---|---|---|
| the error badge, counting BOTH failures | `LatticeForecastTests` (12) | ✅ |
| the blue Topology button under the project name | `LatticesAreInTheAppGateTests` (3) | ✅ |
| the face/surface stage — "I can finally choose per face" | `FaceRegionTests` (26) + `LatticeSeparationRegionTests` (12) | ✅ |
| the render work | `ViewerTests` (33) + `ViewerVisibilityRegressionTests` (2) | ✅ |

★ The face stage is the one this change actually touches — the per-selectable
drawer is the same surface — so its two suites are the load-bearing ones here,
and `LatticeSeparationRegionTests` drives the region/face pair specifically.

### ★ THE SIMULATOR IN THIS WORKTREE CANNOT IMPORT STEP — SAID, NOT GLOSSED

The app builds and launches on the iPad Pro 13" simulator with this fix in it.
It cannot open `M2_verticalStand.step` there, because this worktree's iOS core
slice is built **OCCT-free** (`build_core.sh`: `ios-arm64-simulator (Eigen,
OCCT-free)`). That is the pre-existing gap memory
`viewer-blank-on-sim-is-occt-import-gap` describes, NOT anything this change
caused, and it is why the §0(c) reproduction is analytic rather than on-device.

A shortcut — symlinking the main checkout's `.build-occt-ios/install`,
`vendor/occt-ios`, `vendor/lib3mf-ios` and `occt-frameworks.generated.json` —
got the core slice built WITH OCCT but the app still failed to link (47 OCCT
symbols undefined; `swift package describe` showed 1 binary target, not 48, so
the manifest never declared them through the symlinked tree). It was REVERTED
rather than left half-wired, and the core was rebuilt back to the OCCT-free
slice (EXIT=0, all three slices vendored, 118 lattice/region/viewer tests
re-run green afterwards). The supported path, not yet run here:

```
./app/scripts/build_occt_ios.sh && ./app/scripts/build_core.sh
```

---

---

## §OVERNIGHT — THE 2026-08-17 BATCH (seven asks, in one message)

| # | ask | state |
|---|---|---|
| 1 | Selections minimize to bottom-left | ✅ — the bug was MODIFIER ORDER |
| 2 | Per-region density must update the PREVIEW | ✅ — via the demand field |
| 3 | Preview "looks cheap … part of the model?" | ★ **DIAGNOSED, NOT SHIPPED** — see below |
| 4 | "Lattice Preview" notice under the modal | ✅ — attached by layout |
| 5 | Expand **handle** (drag + number) | ✅ — 3D knob, selected-only |
| 6 | "Lattice" button beside Optimize; hint chip gone | ✅ |
| 7 | CAD surfaces → drawer with a toggle + blurb | ✅ |

### 1 — the minimize bug was the MODIFIER ORDER, not the alignment

`PageLeftModal` applied its paddings **after** `.frame(maxHeight: .infinity)` —
padding a view that is already its parent's size, so the padded result OVERFLOWS
and SwiftUI centres the overflow. Setting the alignment to `.bottomLeading` was
therefore correct and had **no effect on screen**, which is exactly what he
reported. Paddings now come first, then the expanding frame.

★ And the rest position is orientation-aware, because he named the reason: the
action row now carries BOTH `Lattice` and `Optimize`, so in PORTRAIT the panel
rests `PageChrome.edge + 76 pt` above the corner; in LANDSCAPE the corner itself.

### 2 — the density reaches the preview through the DEMAND field

The raymarcher grades a strut from one number per cell:
`rho = rhoMin + (rhoMax − rhoMin) · demand^gamma`, or `uniformRho` when there is
no demand grid. A per-region density therefore needs a PER-CELL input, and that
is what the demand grid is. `LatticeRegionMask.densityDemand` inverts the
shader's own mapping — `demand = ((rho − rhoMin)/(rhoMax − rhoMin))^(1/gamma)` —
so **nothing in the shader changed** and the number on the card is the number the
struts are drawn at. Round-tripped through the shader's formula in a test.

Nothing stated ⇒ nil ⇒ the caller keeps the field it had, so an untouched
project's preview is byte-identical.

### ★★ 3 — WHY THE PREVIEW LOOKS PASTED ON: IT HAS NO DEPTH BUFFER

Not a shading problem — a COMPOSITING one.

* the model's view: `depthStencilPixelFormat = MeshRenderer.depthFormat`
  (MetalMeshView.swift:4030) — it has depth.
* the strut view: `isOpaque = false`, alpha-blended, and **no depth attachment
  anywhere** (LatticeSDFMetal.swift:812).

So the struts are a separate transparent layer composited OVER the model image.
They can never be occluded by the part, never receive its contact shadow or AO,
and are lit by their own light. A sticker over a photograph.

★ **AND THE RAYMARCH IS ALREADY THE CHEAP OPTION** — 13.9 ms at 1024², from this
repo's own render-quality evidence. Instanced strut GEOMETRY would be far heavier
at 10⁵ struts. So the answer is not a different technique; it is putting the
existing one in the right pass:

1. the fragment shader returns `{ float4 color [[color(0)]]; float depth
   [[depth(any)]] }` — it already computes `hitPos`, so the depth is one matrix
   multiply it currently throws away;
2. draw the struts INSIDE `MeshRenderer`'s pass, into the same colour + depth
   attachments, instead of a second `MTKView`;
3. they then share the model's key light, AO and contact shadow for free, and the
   part's walls genuinely occlude them.

Same GPU cost. **NOT SHIPPED TONIGHT, DELIBERATELY**: it merges the two render
paths and is guarded by `LatticeProxyProfileTests` and
`ViewerVisibilityRegressionTests`; getting it subtly wrong yields a black viewer,
which is a far worse thing to wake up to than a preview that looks cheap. It is a
well-scoped half-day with device eyes on it.

### 5 — the expand HANDLE

A 3D knob on the slab's in-plane edge, dragged at the same 0.05 mm/pt scrub the
depth chip uses, writing the SAME `writeLatticeExpandMM` the drawer row writes —
so the handle and the number cannot diverge. ★ Visible only for the ACTIVE
group's selectables ("make it only visible when the group/face/primitive is
selected"): every latticed face casts a depth handle, but an expand handle on
every face at once is a field of knobs.

### 6 — the bottom bar, and its resulting order

**`[hint (Topology only)] … [Compute] [Print Parameters] [Lattice] [Optimize]`**

`Lattice` has Optimize's stature and sits to its left; it is the other thing you
can ask the screen to DO, not a modifier on the first. It runs core's new
`lattice_part` mode through `RunRequest.withJobMode` — the optimize request with
ONE key changed, so the load case, resolution, material, protections and lattice
block are the ones the user configured rather than re-authored.

### 7 — CAD surfaces is a DRAWER, not a deletion

★ **The removal brief was wrong about what this is, and the finding was reported
before cutting.** `projectCADFaces` has five readers, and one is the RUN: it is
saved in the project, travels as `output.project_cad_faces`, and core uses it to
decide whether the exported mesh is snapped back onto the CAD geometry
(job.cpp:1192, run_job.cpp:598). Deleting the chip would have stranded a live
export setting stuck ON with no way to reach it.

His answer was better than all three options I offered: keep it, and make it
explain itself. The drawer carries an on/off switch and three sentences — what it
does, what ON costs, what OFF costs — with the trade-off line switching to the
side you are actually on. The Surface stage was never reached through this chip
(`WorkspaceStage.forward`), so nothing became unreachable either way.

### The one that bit twice

Three guards assert "exactly ONE selections panel definition exists" by COUNTING
a source substring. Splitting the panel into a column + its card tripped all
three — so the helper was RENAMED rather than the guards edited. Then the doc
comment explaining that decision QUOTED the searched string and tripped them
again. **A source-text guard counts comments too.**

## PLAIN LANGUAGE

The lattice card on the setup page was showing you numbers from a **different
depth than the one it was labelled with**. When you dragged a face's depth
handle, the number beside the handle moved — and the card underneath kept doing
its arithmetic at the old 4 mm. That is fixed: there is now one depth per thing
you can select, and the card is built from it.

Two things you should know before you test it:

1. **This fix alone will not make anything certify.** The card still says 5%
   density and still says your struts are too thin. Both of those are the next
   fix.
2. **The "you need 24.65 mm of depth" advice in the brief is wrong**, and it is
   wrong because of that same next bug. Core's actual requirement on your part is
   about **5.9 mm** — a depth you can reach. The card is quoting a cell four
   times coarser than the one the run would actually use, and it is computing
   your strut width with a formula that is 1.4× off from the one core uses. Fix
   that and the "0.32 mm strut, under your 0.45 mm nozzle" complaint disappears
   entirely, because the real number is 0.45 mm exactly.
