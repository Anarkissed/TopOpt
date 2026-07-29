# Auto-clearance heuristic — FIX

**Date:** 2026-07-29
**Implements:** `docs/handoffs/2026-07-26-clearance-heuristic-diagnosis.md` (PR 188).
**Evidence:** `docs/handoffs/evidence/2026-07-29-clearance-heuristic-fix/`

## The complaint (recap)

On a small `WallMount_ShelfBracket` STL the auto-clearance heuristic over-found
and under-found in the same session: one anchor group proposed **8 bore
primitives** with margins/axials sprawling far past the part, another group's
Bore rows rendered **blank "— mm  Auto"**. Whole-part census: **24 bore
primitives against 2–3 real holes, 8 of them blank**, with axials up to **443 mm
on a 20 mm-thick plate**. Previously flagged for "135 mm axials".

## What PR 188 found (and what I built)

PR 188 traced it to **two independent defects** and recommended a fix without
writing it. I implemented the recommendation; the diagnosis still held against
current code, so nothing needed re-deriving. The recommended merge of coaxial
fragments (rec #4) I deliberately did **not** build — see "Deliberate
under-find" below.

### Defect 1 — the bore predicate was geometry-blind

A face counted as a clearance "bore" via `FaceTopology.isCurved` (any two of its
triangle normals differ by > 5°). That fires on **every** curved region —
pocket-corner blends, outer rounded edges, fillets, a whole sphere — not just
holes, and it is decoupled from whether the segmenter actually fit a cylinder. So
a curved-but-non-cylinder face became a bore chip with **no radius → the blank
"— mm Auto" row**, and dozens of non-hole curved faces became proposed bores.

**Fix (app):** a new single predicate `FaceTopology.isFastenerBore`
(`app/TopOptKit/Sources/TopOptFlows/FaceSelection.swift`) replaces `isCurved` at
**every** auto-clearance call site. A face is a fastener bore iff:

- it is a **fitted cylinder** with a real radius (`faceGeometry.isCylinder`) — so
  a proposed bore ALWAYS has an Auto margin/axial: **the blank-row class is gone
  by construction**;
- it is **concave** — the wall faces the axis (a hole), not away from it (a boss,
  or a round plate's outer rim, which a least-squares fit also reads as a
  cylinder);
- it wraps **≥ 300°** about the axis — a through-hole encircles its axis; a
  rounded pocket corner covers only a shallow arc.

`isFastenerBore` reads the same triangle buffer + fitted axis the app already
holds, so no bridge change. Wired into `ProjectModel.autoClearanceApplies`,
`clearanceSpecs`, `resolvedClearances`, `manualDetentTargets`, and the
`WorkspacePlaceholder` clearance-chip/primitive builders.

### Defect 2 — the cylinder fit was over-permissive

`segment.cpp` accepted a region as a Cylinder if the fit was tight and the radius
was below `max_cylinder_radius_span · bbox_diagonal`, default **1.0**. On a 290 mm
part that ceiling is the whole diagonal, so a nearly-flat outer edge fit a
**221 mm** "cylinder" and passed → the Ø443 mm axials.

**Fix (core):** `max_cylinder_radius_span` `1.0 → 0.5`
(`core/include/topopt/segment.hpp`). A cylinder wider than half the part's space
diagonal is not a feature of the part; the bracket's 0.77 and 0.69 fits fall back
to `Other`. This fixes the bogus radius at the source, so a keep-clear/protect
tapped on such a wall no longer sweeps a giant keep-out either (the risk the
diagnosis flagged), not just the auto proposal. Every real bore across the mesh
fixtures is < 0.5·diag (widest is the filleted-plate rim at 0.35), so the parts
already classified correctly are **byte-identical**.

## Where the discriminators came from

Not reasoned about — measured. `gate.cpp` (evidence dir) runs the real
`import_part` + `segment_mesh_faces` on every mesh fixture and computes wrap,
concavity, and radius/bbox per cylinder face. On the bracket the two real
through-holes wrap 353°/354° and are concave; the 22 non-holes are either convex
(bosses/rims/outer edges) or wrap ≤ 198° (pocket-corner arcs) or both. The gate
`{isCylinder ∧ concave ∧ wrap ≥ 300°}` separates them with a wide margin (worst
non-hole arc 198° vs the 300° bound). The Swift `boreAxisMetrics` mirrors
`gate.cpp` exactly.

## Bars

### C1 — proposal on every fixture, before → after

| fixture | real holes | OLD bores (blank) | NEW bores | worst axial |
|---|---|---|---|---|
| **WallMount_ShelfBracket** | 3 | **24 (10 blank)** | **2** | **443 → 9 mm** |
| plate_bore | 1 | 1 (0) | 1 | 6 → 6 |
| filleted_bore_plate | 1\* | 3 (2 blank) | 0\* | 44 → — |
| l-bracket | 2 | 2 (0) | 2 | 5 → 5 |
| hook | 0 | 2 (2 blank) | 0 | — |
| sphere_r10mm | 0 | 1 (1 blank) | 0 | — |
| cube_10mm / sample_cube | 0 | 0 | 0 | — |
| bracket_clean | 1 | 1 (0) | 1 | 10 → 10 |
| bracket_small_hole | 1 | 1 (0) | 1 | 10 → 10 |

\* `filleted_bore_plate`: the only cylinder the old test fit was the plate's
**convex outer rim** (r 22 mm), offered as a Ø44 mm bolt hole — a Defect-2 false
positive the concavity gate now rejects. The part's real bore is unfittable on
the mesh path (`Other`, no radius) and is left to the escape hatch — honest (no
radius ⇒ nothing to auto-propose) rather than a blank row.

### C2 — no blank Auto rows

Structural, not cosmetic: a fastener bore is always a fitted cylinder, so
`faceBoreRadius` is never nil for a bore row and the Margin/Axial pills always
get a real Auto. Blank-Auto count across the fixtures went **13 → 0**. An
explicit-affix non-fastener face renders as a Depth (slab) row, which carries a
constant Auto and never blanks. `testNonBoreCurvedFaceProducesNoBlankClearance`
pins it.

### C3 — no regression on parts already handled

`plate_bore`, `l-bracket`, `bracket_clean`, `bracket_small_hole` propose the
identical bore, radius, and axial after the fix (byte-identical core
classification + identical app gate result). Proven by `gate_output.txt` and the
unchanged `ClearanceDerivationTests` / `ManualPrimitiveTests` numeric assertions.

### C4 — manual add / delete unaffected

Manual primitives never pass through `isFastenerBore` — they are emitted
unconditionally (`clearanceSpecs` top of loop) and render via their own stored
geometry. `testManualPrimitiveUnaffectedByGate` forces a manual bolt onto a face
the gate rejects and asserts the spec is still emitted. Auto-suppression /
delete / restore tests are green.

### C5 — device-real, on the maintainer's own bracket

`ClearanceHeuristicBracketTests` imports the committed
`WallMount_ShelfBracket.stl` through the **actual bridge** (`TopOptKit.importMesh`
→ core segmenter with the 0.5 bound) and runs the **shipping**
`FaceTopology.isFastenerBore` + full `ProjectModel.clearanceSpecs` — the same code
path the iPad runs. Result (`bracket_test_output.txt`):

```
[bracket] OLD isCurved bores = 24 (10 blank-Auto) | NEW fastener bores = 2 | worst auto axial = 9.0 mm
```

`clearanceSpecs` yields exactly 2 bolt clearances, each resolving to a real
margin + axial (no blank pill possible), 2 non-degenerate rendered volumes.

## Deliberate under-find (stated, not hidden)

The bracket has **3** physical holes; the gate proposes **2**. The 3rd is a Ø9
hole the segmenter fragments into two sub-300° arcs (faces 19+20, wrapping 80°
and 274°) — the PR-167 coarse-tessellation caveat. Recovering it needs either a
knife-edge wrap threshold (274° is 4° under a 278° bound) or a coaxial-fragment
merge (rec #4). Both risk re-admitting the pocket-corner false positives this
fixes (worst non-hole arc 198°). Per the diagnosis, the gate stays **strict** and
the fragmented hole is left to the manual "+ primitive" escape hatch — the
sanctioned path for a face the tightened detector rejects. This is the same
trade the segmenter itself documents for its 8-gon caveat: take the under-find,
state it, don't loosen the bound.

## Tests

- `app/.../ClearanceDerivationTests.swift` — +8 gate cases (concave hole accepted;
  convex rim, shallow arc, non-cylinder curved rejected; no blank; convex boss no
  auto; manual unaffected). Shared fixture rewound to a genuine concave hole.
- `app/.../ManualPrimitiveTests.swift` — shared fixture rewound identically
  (34 cases green).
- `app/.../ClearanceHeuristicBracketTests.swift` — new, device-real (2 cases).
- `core/tests/unit/test_segment.cpp` — 93 checks green with the 0.5 bound.
- Full `TopOptFlowsTests` (881 tests) green except 8 pre-existing `AppModelTests`
  3MF failures — this build's macOS core slice was vendored without lib3mf
  (`build_lib3mf_macos.sh` not run); unrelated to this change (touches no 3MF /
  segment / clearance code).

## Files

- `core/include/topopt/segment.hpp` — `max_cylinder_radius_span` 1.0 → 0.5.
- `app/TopOptKit/Sources/TopOptFlows/FaceSelection.swift` — `isFastenerBore` +
  `boreAxisMetrics`.
- `app/TopOptKit/Sources/TopOptFlows/ProjectModel.swift`,
  `WorkspacePlaceholder.swift` — the 6 bore-predicate call sites.
- Tests as above.
