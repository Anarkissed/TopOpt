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

**What does the card read after both fixes? NOT MEASURED YET — §1 has not
landed.** After fix 1 alone, on `M2_verticalStand.step`, face 2:

```
4.0 mm (the default)   density 5%  cells across 0.8  cell 4.93 mm  strut 0.32 mm  Out of regime
24.65 mm (dragged)     density 5%  cells across 5.0  cell 4.93 mm  strut 0.32 mm  Out of regime
```

**Does one region on his part certify? NOT MEASURED YET.** Fix 1 alone cannot
make one certify, and the reason is stated rather than glossed: even at 5.00
cells across the verdict stays out-of-regime, because the card's strut test fails
on the app's own octet law. That is §1's defect, and it is next.

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
| R1 one fix, one run, one report | ✅ fix 1 only; §1 not started |
| R2 auto density honest | ⬜ not started |
| R3 depth ⇄ handle, both directions + protection | ✅ 5 assertions |
| R4 one region certifies end to end | ⬜ blocked on §1 |
| R5 nothing regresses | ✅ 1538 app tests, 0 failures |
| R6 root cause with file and line | ✅ §1 and §2 both |
| R7 no assertion weakened or deleted | ✅ census below |
| R8 cost measured directly, Release verified | ✅ `CMAKE_BUILD_TYPE=Release`; no wall-clock claim made |
| R9 no placeholders, no root scratch | ✅ |

---

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
