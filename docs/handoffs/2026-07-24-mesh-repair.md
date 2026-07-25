# 2026-07-24 — Mesh REPAIR (STL/3MF import, Phase 2)

**Track:** core `io/` only. **Territory:** `core/include/topopt/part.hpp`,
`core/src/io/part.cpp`, `core/tests/unit/test_segment.cpp`,
`core/tests/tools/repair_evidence.cpp`, `core/CMakeLists.txt`. **No app, no
bridge, no solver, no optimizer, no segmenter.** Nothing outside the import
adapter changed; every downstream consumer still takes the same `StepModel`.

**Predecessor:** [134 — STL/3MF import, Phase 1](134-stl-3mf-import-phase-1.md).
Phase 1 REFUSED any non-manifold / open / non-orientable / zero-thickness mesh
with an honest sheet. Phase 2 **attempts a deterministic, conservative repair
before refusing**, re-inspects, and proceeds if the result is clean.

**Gates:** full `ctest` **66/66**, 1008 s
(`evidence/2026-07-24-mesh-repair/ctest.txt`); `mesh_segmentation` **84 checks**
(was 55). Byte-identity gates (`cli_demo` 240 s, `production_parity`,
`clearance_parity`, `face_protection_parity`) all pass untouched — repair is a
**no-op on a clean mesh**, so nothing that imported before imports differently.

---

## 0. What Phase 2 repairs, and what it still refuses

The single decision point is `inspect_and_repair` in `part.cpp`, run by BOTH
`import_part` (refuses by throwing) and `inspect_part_file` (reports) — so the
sheet can never disagree with the refusal. The pipeline is now:

```
weld + drop degenerates                (Phase 1)
  └─ remove exact-duplicate facets     (Phase 2, NEW)
       └─ topology verdict (check_watertight)
            ├─ non-manifold edges remain? → REFUSE (ambiguous junction)
            └─ boundary edges? → fill small holes (Phase 2, NEW) → re-check
                 └─ unify normals + zero-thickness verdict   (Phase 1)
```

| defect | Phase 1 | Phase 2 |
|---|---|---|
| duplicate vertices | welded | welded |
| inverted / mixed normals | unified | unified |
| **redundant exact-duplicate facets** | (fell through to non-manifold refusal) | **removed** — reported as `removed_duplicate_triangles` |
| **small hole** (simple boundary loop within bounds) | refused (OpenBoundary) | **capped** — reported as `filled_holes` / `filled_hole_triangles` |
| large / complex hole | refused | **still refused** (conservative bound) |
| ambiguous non-manifold junction | refused | **still refused** (survives duplicate removal) |
| non-orientable, zero-thickness, empty | refused | still refused |

**Repair never silently changes the intended solid.** Every repair is reported;
the bounds are conservative; the result is accepted only after a clean
re-inspection.

---

## 1. Repair A — redundant exact-duplicate facets (`remove_duplicate_triangles`)

The #1 cause of "N edges shared by three or more triangles" in a CAD-exported
STL is a **stacked coincident facet** — the same triangle written twice. Each
duplicate pushes its three edges past two uses, so the mesh reads non-manifold
even though the *surface it describes* is a clean solid.

The fix is unambiguous: drop the redundant copy. `remove_duplicate_triangles`
keys each triangle by its **oriented** canonical form (rotate so the smallest
index leads, preserving cyclic order), keeps the first occurrence in triangle
order, drops every later exact copy. Two decisions:

* **Oriented, not unordered.** An OPPOSITE-wound coincident pair (`{0,1,2}` and
  `{0,2,1}`) is *not* a duplicate — it is a doubled-over membrane, and collapsing
  it would turn the zero-thickness verdict into a spurious open-boundary one.
  It is left untouched and caught by the ZeroThickness check, exactly as before.
* **First-wins, ordered map** → deterministic: the surviving triangle list is a
  pure function of the input order.

Runs BEFORE the topology verdict, so a mesh that was non-manifold *only* because
of duplicates is measured clean and proceeds.

## 2. Repair B — small holes (`fill_small_holes`)

A hole is a closed loop of boundary edges. The repair:

1. Collect **directed** boundary edges (a→b where undirected `{a,b}` is used
   once). Trace loops from the lowest vertex index, ordered maps throughout.
2. Fill only a **simple** loop — every vertex on it has exactly one incoming and
   one outgoing boundary edge. A pinched / branching boundary is ambiguous and
   is left open (→ refused). This is checked per vertex during the walk.
3. Fill only within **conservative bounds** (`MeshRepairOptions`):
   * `max_hole_edges = 64` — more edges than that is a large opening, not a
     dropped facet.
   * `max_hole_fraction = 0.5` — a loop whose bbox diagonal exceeds half the
     part's is a **missing wall**, not a defect. (A missing cube face is ~0.82 of
     the diagonal → refused.)
4. Cap a qualifying loop with a **centroid fan**: add one new centre vertex,
   join it to every loop edge. This is **topologically guaranteed 2-manifold** —
   the new edges all touch a fresh vertex, so no existing edge can be pushed to
   three uses. (A vertex fan across existing loop vertices *can* collide with an
   existing chord and re-introduce a non-manifold edge; the centroid fan cannot.)
   The cap is wound opposite the boundary directed edge, so it is
   orientation-consistent with the body before `unify_normals` even runs.

The loop's lowest-index vertex leads the fan, so the added geometry is a pure
function of the input → deterministic and re-import-stable.

## 3. What still refuses, and why it is honest

* **Non-manifold edges that survive duplicate removal** → `NonManifoldEdges`.
  Three or more *distinct* facets at one edge is a genuine junction; inside /
  outside is undefined and no deterministic split is unambiguous. Refused. Hole
  filling is not even attempted on such a mesh (an ambiguous interior has no
  well-defined loop to cap).
* **Boundary edges that survive hole filling** → `OpenBoundary`. A loop too big,
  too many-edged, or non-simple. The `describe_defect` copy now says so ("holes
  too large or complex to fill safely").
* **NonOrientable / ZeroThickness / EmptyMesh** — unchanged from Phase 1.

---

## 4. Evidence — before/after on real broken brackets

`repair_evidence` (`cmake --build core/build --target repair_evidence`) builds a
real 60×40×6 mm plate-with-bore bracket (the geometry class of the failing
screenshot), injects each defect, writes it as binary STL, and reports the
verdict straight off the shipping `inspect_part_file`. Full output:
`evidence/2026-07-24-mesh-repair/repair_report.txt`; the STLs are committed
beside it.

| case | before | after |
|---|---|---|
| **[0] clean control** | watertight | accepted, repair a **no-op**, 13930.022 mm³ |
| **[1] duplicate facets** (the bracket class) | **17 non-manifold edges** | **6 duplicates removed** → watertight, accepted, **same 13930.022 mm³** (solid unchanged) |
| **[2] small hole** (2 dropped facets) | 4 boundary edges | **1 hole filled (+4 tris)** → watertight, accepted, same volume |
| **[3a] wall-sized hole** (top face gone) | 104 boundary edges | fills the small bore-rim sub-loop (0.14× span) but **refuses** the wall-sized outline (1.0× span) → 52 boundary edges remain → **REFUSED**. The conservative bound holds even when a part has one fillable and one unfillable loop. |
| **[3b] ambiguous junction** (a fin) | 1 non-manifold + 2 boundary | not a duplicate → **REFUSED** with both reasons |

### The BARS case: repaired bracket OPTIMIZES end-to-end

The duplicate-facet bracket (case [1]) was run through the full `topopt-cli run`
pipeline — not just imported. It **repaired and optimized**:

```
model: bracket.stl (7 pseudo faces, 1 fixture faces matched)
variants: 2 evaluated, 2 accepted
  vf 0.70: margin 1.62e+04, accepted
  vf 0.50: margin 1.19e+04, accepted
```

Import → repair (6 dups removed) → voxelize → tag → 2-rung ladder → export, no
crash, no silent bad repair. Artifacts: `evidence/2026-07-24-mesh-repair/e2e_*`.
(The `MultigridCG_Matfree → Jacobi` warning on the 24×16×3 grid is the known
odd-extent fallback, unrelated to this work.)

---

## 5. Contract changes to existing tests (read this)

Two `test_segment` refusal cases were **augmented** (not worked around) to pin
the Phase-2 facts, and both still refuse:

1. **open cube** (missing +X face) — now documented as a *wall-sized* hole:
   still `OpenBoundary`, `boundary_edges == 4`, and additionally
   `filled_holes == 0` (the conservative bound refused the fill). The same
   fixture backs `test_stl`'s `broken_open_cube.stl` and the app's
   `testImportBrokenSTLIsRefusedWithADiagnosis`; both stay green because a
   whole missing face is deliberately *not* filled.
2. **non-manifold fin** — now documented as an *ambiguous junction*: still
   `NonManifoldEdges`, plus `removed_duplicate_triangles == 0` (the fin is not a
   duplicate, so duplicate removal correctly does not touch it).

New `mesh_segmentation` checks (29): the `remove_duplicate_triangles` unit
(first-wins, opposite-wound kept), the duplicate-facet REPAIR (accepted, volume
preserved), the small-hole REPAIR (filled, watertight, volume within a hair),
repair determinism across re-import, the conservative bound as a real gate
(same hole filled under default / refused under a tightened fraction / refused
under a tightened edge cap), and a beyond-repair junction that still refuses.

---

## 6. Files

**Changed (core):** `include/topopt/part.hpp` (three repair-report fields on
`PartInspection`, `MeshRepairOptions`, `remove_duplicate_triangles` +
`fill_small_holes` declarations, scope comment rewritten for Phase 2),
`src/io/part.cpp` (the two new repairs + reworked `inspect_and_repair` +
honest `describe_defect` copy), `CMakeLists.txt` (`repair_evidence` target).

**New (tests/tools):** `tests/tools/repair_evidence.cpp`.

**Changed (tests):** `tests/unit/test_segment.cpp` (+29 checks).

---

## 7. Follow-ups (none blocking)

1. **3MF still unexercised** — lib3mf is not installed here (same as Phase 1).
   The repair path is format-agnostic (it runs on the `TriangleMesh` after
   `read_mesh_any`), so it applies to 3MF for free, but it is untested there.
2. **App surfacing of repair reports.** The bridge already carries
   `PartInspection`; the new fields (`removed_duplicate_triangles`,
   `filled_holes`, `filled_hole_triangles`) are populated but the app's import
   sheet does not yet *show* "repaired: N duplicate facets removed, 1 hole
   filled". Phase 1's sheet already shows `welded`/`flipped`; extending it is a
   pure app change.
3. **Vertex-fan holes** were rejected in favour of centroid fans for topological
   safety (§2). A future pass could ear-clip a planar loop to avoid the extra
   centre vertex when the loop is provably planar and convex — cosmetic only.
