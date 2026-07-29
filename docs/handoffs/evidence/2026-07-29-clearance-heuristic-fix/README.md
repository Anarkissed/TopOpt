# Evidence — auto-clearance heuristic FIX (2026-07-29)

Implements PR 188's diagnosis
(`docs/handoffs/2026-07-26-clearance-heuristic-diagnosis.md`). The baseline
"before" numbers live in that diagnosis's evidence dir
(`../2026-07-26-clearance-heuristic-diagnosis/probe_output.txt`,
`analyze_output.txt`) — this dir carries the "after".

## The fix, in two parts

1. **Core** — `core/include/topopt/segment.hpp`: `max_cylinder_radius_span`
   `1.0 → 0.5`. A flat wall can no longer least-squares-fit a cylinder wider than
   half the part's bbox diagonal, so the bracket's 221 mm / 199 mm "cylinders"
   (Defect 2, the Ø443 mm axials) fall back to `Other`. Every real bore is well
   under 0.5·diag (widest is the filleted-plate rim at 0.35), so all fixtures whose
   classification was already correct are byte-identical.
2. **App** — `FaceTopology.isFastenerBore` (new, `FaceSelection.swift`) REPLACES
   the 5°-`isCurved` bore test at every auto-clearance call site
   (`ProjectModel.autoClearanceApplies` / `clearanceSpecs` / `resolvedClearances`,
   `WorkspacePlaceholder` chips). A face is a fastener bore iff it is **a fitted
   cylinder** (so it always has an Auto radius → no blank rows), **concave** (walls
   face the axis — a hole, not a boss / outer rim), and **wraps ≥ 300°** about the
   axis (a through-hole, not a pocket-corner arc).

## Files

- `gate.cpp` / `gate_output.txt` — the measurement harness. Runs the real
  `import_part` + `segment_mesh_faces` (with the 0.5 bound) on every mesh fixture,
  computes the three discriminators (wrap, concavity, radius/bbox) per cylinder
  face, and prints the OLD (`isCurved`) vs NEW (fastener gate) verdict + a
  per-fixture summary. This is the exact logic mirrored in Swift
  `FaceTopology.isFastenerBore` / `boreAxisMetrics`.
- `bracket_test_output.txt` — the DEVICE-REAL proof: the shipping Swift predicate
  (`ClearanceHeuristicBracketTests`) run over the maintainer's own
  `WallMount_ShelfBracket.stl`, imported through the actual bridge. It exercises
  the same code path the iPad runs.

## Reproduce

```bash
EVID=docs/handoffs/evidence/2026-07-29-clearance-heuristic-fix
CORE="core/src/io/part.cpp core/src/io/stl.cpp core/src/io/segment.cpp core/src/mesh/mesh.cpp"
clang++ -std=c++17 -O2 -Icore/include "$EVID/gate.cpp" $CORE -o "$EVID/gate"
./"$EVID/gate" .                     # OLD-vs-NEW census, every mesh fixture

# device-real (needs the vendored core: ./app/scripts/build_core.sh once):
cd app/TopOptKit && swift test --filter TopOptFlowsTests.ClearanceHeuristicBracketTests
```

## Result (C1 — before → after, every fixture)

| fixture | real holes | OLD bores (blank) | NEW bores | worst axial before → after |
|---|---|---|---|---|
| **WallMount_ShelfBracket** | 3 | **24 (10 blank)** | **2** | **443 mm → 9 mm** |
| plate_bore | 1 | 1 (0) | 1 | 6 → 6 |
| filleted_bore_plate | 1* | 3 (2 blank) | 0* | 44 → — |
| l-bracket | 2 | 2 (0) | 2 | 5 → 5 |
| hook | 0 | 2 (2 blank) | 0 | — |
| sphere_r10mm | 0 | 1 (1 blank) | 0 | — |
| cube_10mm / sample_cube | 0 | 0 | 0 | — |
| bracket_clean | 1 | 1 (0) | 1 | 10 → 10 |
| bracket_small_hole | 1 | 1 (0) | 1 | 10 → 10 |

- **Zero blank-Auto rows anywhere** (was 8+2+2+1 = 13 across the fixtures) — C2.
- **The already-correct parts are byte-identical** (plate_bore, l-bracket,
  bracket_clean, bracket_small_hole, cube: same bore, same radius/axial) — C3.
- \* `filleted_bore_plate`: the only cylinder the old test fit was the plate's
  **convex 22 mm outer rim** (offered as a Ø44 mm "bolt hole" — a Defect-2 false
  positive); the concavity gate correctly rejects it. The part's actual bore is
  unfittable on the mesh path (lands as `Other`, no radius) and is left to the
  manual "+ primitive" escape hatch — which is honest (no radius ⇒ nothing to
  auto-propose) rather than a blank row.
- The shelf bracket's **3rd** physical hole (a Ø9 the segmenter fragments into two
  sub-300° arcs, faces 19+20) is the one deliberate under-find: the gate stays
  strict and defers it to the escape hatch rather than lowering the wrap bound into
  the pocket-corner false positives (worst non-hole arc wrapped 198°). This matches
  the segmenter's own documented coarse-tessellation caveat.
