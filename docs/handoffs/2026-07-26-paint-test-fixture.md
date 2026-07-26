# Fix PaintModeUITests wall-face selection (app-only, test fix)

**Date:** 2026-07-26
**Scope:** app-only. One test file + one build-script echo line. No core, no fixture, no wire changes.
**Evidence:** `evidence/2026-07-26-paint-test-fixture/`

## Problem

`PaintModeUITests.testShelfBracketBackFacePaintedAnchorMatchesTap` built the "wall face"
triangle set by **exact float equality**:

```swift
mesh.vertices[Int(mesh.indices[t * 3 + c]) * 3 + 1] == 0   // y == 0
```

then asserted the set was non-empty. On the committed fixture
`core/tests/fixtures/mesh/WallMount_ShelfBracket.stl` (binary, 2224 triangles) the y range
is **−196.79 → +10.57** and **zero** triangles have all three vertices at exactly `y == 0`
(see `fixture-geometry.txt`). The set was empty → nothing painted → the `XCTUnwrap` of
`selection.activeGroup` failed as a downstream consequence.

Provenance (given): the fixture came from PR 176 (main) and the test from PR 180 (branch);
the hand-merge kept main's STL and the branch's test, so test and fixture came from opposite
sides of the resolution. **The fixture was not touched** — PR 176's over-selection repro
depends on it exactly as committed.

## Fix

Select the wall face **the way the app does — through the mesh segmentation
(`mesh.pseudoFaces`)** — instead of a hardcoded coordinate. New private helper
`wallFaceTriangles(in:)` in the test:

1. Derives the plane from the mesh's own **minimum-y bound** (`ys.min()`), never a literal.
2. Picks a *representative* triangle on that plane with an **explicit tolerance**
   `planeTol = 1e-2 mm` and `abs(y − minY) < planeTol` — never exact equality.
3. Reads that triangle's **segmenter face id** (`mesh.faceIDs`) and returns **all** triangles
   of that pseudo-face. The selection is the segmenter's face, not a coordinate band — exactly
   the set a tap yields (pseudo-faces don't over-select).

The target test now also asserts the wall face is one coherent segmented pseudo-face
(`Set(triangles(ofFace:)) == Set(backTris)`), i.e. it exercises the real dihedral-segmentation
path.

### Why the tolerance is safe

The extrusion spans ~207 mm in y. The two lowest distinct y layers are
`−196.7901` and `−186.388`, a **10.40 mm** gap (`fixture-geometry.txt`). `planeTol = 1e-2 mm`
is ~3 orders of magnitude below that gap, so it can never reach a neighbouring layer, while
still comfortably absorbing 32-bit binary-STL float noise. It only selects the *representative*
triangle; the actual face membership comes from the segmenter.

## Bars

- **B1 — passes on the committed fixture, unmodified.** `paintmode-tests-pass.txt`:
  all 6 `PaintModeUITests` pass, including `testShelfBracketBackFacePaintedAnchorMatchesTap`.
  Fixture untouched (`git status` shows no change under `core/tests/fixtures/`).

- **B2 — it can fail.** Two forms of proof:
  1. A permanent negative test, `testShelfBracketWrongFaceFailsPaintedEqualsTap`, paints a
     deliberately wrong set (wall face minus one facet) and asserts the same round-trip
     equality the passing test relies on does **not** hold.
  2. `b2-stub-fails.txt`: I temporarily stubbed the *actual* target test's paint call to a
     wrong set and it failed exactly at the painted==tapped assertion —
     `XCTAssertEqual failed: ("[1645]") is not equal to ("[1645, 1646]")`. Reverted after.
     (This also confirms the wall face is triangles **1645 + 1646** — the two min-y facets.)

- **B3 — no exact float equality on geometry.** `b3-grep-no-exact-float-eq.txt`: every `==`/`!=`
  in the file is either prose in a comment or `$0.element == id` (Int32 face id). The only
  geometry comparison is `abs(... − minY) < planeTol`.

- **B4 — the rest of the suite passes.** `full-suite.txt` (raw `xcodebuild` output), tail:
  `** TEST SUCCEEDED **`. Bundles: `TopOptDesignTests` passed, `TopOptFlowsTests` 695 tests
  (3 skipped, 0 failures), `TopOptKitTests` 30 tests (0 failures).

- **B5 — is it the same face the original test intended?** **Yes, conceptually — and this is
  worth stating plainly.** The original test's own comment named the target as *"the two facets
  at the minimum-y bound of the L extrusion."* The committed fixture still has exactly **two**
  facets at its minimum-y bound (triangles 1645 + 1646, both normal −y). The stale `== 0` was a
  literal for that bound in the *branch's* fixture, where the bound happened to be 0; in main's
  committed fixture the same bound sits at −196.79. Deriving from the real `ys.min()` selects the
  **same conceptual face the author described** — the min-y end cap — so the fix restores the
  author's intent rather than substituting a different face. The only thing that moved is the
  coordinate value of the bound, which is precisely why hardcoding it was wrong.

## While I was here — build_core.sh test command

`app/scripts/build_core.sh` printed `xcodebuild test -scheme TopOptKit -destination
'platform=macOS'`. `TopOptKit` is the **library product** scheme and has no test action, so that
command intermittently errors with *"Scheme TopOptKit is not currently configured for the test
action."* (reproduced in `scheme-fix.txt`). The auto-generated **`TopOptKit-Package`** scheme is
the one carrying the package's test targets. Corrected the printed line (and added a comment
explaining why) to:

```
xcodebuild test -scheme TopOptKit-Package -destination 'platform=macOS'
```

This is the command used for every run in this handoff's evidence.

## Files changed

- `app/TopOptKit/Tests/TopOptFlowsTests/PaintModeUITests.swift` — segmentation-based wall-face
  selection (`wallFaceTriangles`), the B2 negative test, and a coherent-face assertion.
- `app/scripts/build_core.sh` — corrected the suggested test command to `-scheme TopOptKit-Package`.
