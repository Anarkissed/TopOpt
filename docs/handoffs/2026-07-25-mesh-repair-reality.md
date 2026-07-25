# Mesh-repair reality: what actually happens on import, and the two real defects

**Date:** 2026-07-25
**Branch:** `claude/mesh-repair-import-trace-4ef98f`
**Task:** determine, on the real import path, what actually happens when a mesh
that needs repair is imported — no assumption that repair runs, no assumption
that it doesn't — then fix whatever is broken.

---

## TL;DR — ground truth

Repair **IS** wired into the path the app and the worker actually execute, and it
**does** run. Proven on real files (not ctest): a duplicate-facet mesh and a
small-hole mesh both **repair and import**; an ambiguous-junction mesh and a
wall-hole mesh are **refused with the specific, correct core reason**.

So this was **not** the "repair never gets called" case. The two real defects
were:

1. **Stale refusal copy (Bar 2 violation).** `ImportRefusal.scopeNote` — the last
   sentence of the sheet the user saw — read *"it doesn't repair holes or
   self-intersections yet."* The build **does** cap small holes and **does**
   remove duplicate facets. The sheet denied a capability the build has. This is
   the exact stale sentence in the user's screenshot.

2. **Repair-count plumbing gap.** The core reports four repair kinds; the bridge
   DTO and the Swift `PartDiagnostics` only carried two of them
   (`welded_vertices`, `flipped_triangles`). `removed_duplicate_triangles`,
   `filled_holes`, and `filled_hole_triangles` were dropped at the bridge. A mesh
   accepted **only** because a hole was filled or a duplicate facet was removed
   reported `didRepair == false` and showed **no** repair note — silently
   changing the user's geometry, in violation of the documented "every repair is
   reported" contract (`part.hpp`).

Both are fixed. Which case per the task's STEP 3: **"repair IS wired and runs but
the SHEET COPY is stale → fix the copy"**, plus the plumbing gap that made the
accepted-with-repair path lie by omission.

---

## STEP 1 — the real call chain (file:line)

The refusal the user saw is produced **app-locally, before anything is sent to
the worker.** A remote (Mac worker) run has two import moments; the refusal is
the first one.

### A. App import / refusal (what the user hit)

```
File picker
  → AppModel.pickedFile(atPath:)                app/.../TopOptFlows/AppModel.swift:458
      → inspector(path)  ==  TopOptKit.inspectPart(path:)
                                                app/.../TopOptFlows/AppModel.swift:467, :170
        → TopOptKit.inspectPart                 app/.../TopOptKit/TopOptKit.swift:557
          → topoptbridge.inspect_part(path)     app/.../TopOptKit/TopOptKit.swift:559
            → inspect_part (bridge)             app/.../TopOptBridge/bridge.cpp:456
              → topopt::inspect_part_file(path) app/.../TopOptBridge/bridge.cpp:459
                → inspect_part_file             core/src/io/part.cpp:539
                  → inspect_and_repair(mesh)    core/src/io/part.cpp:63   ← REPAIR LIVES HERE
      → if !d.acceptable: ImportRefusal(...)    app/.../TopOptFlows/AppModel.swift:471
      → sheet copy: ImportRefusal.scopeNote     app/.../TopOptFlows/ImportInspection.swift
```

`inspect_and_repair` (`core/src/io/part.cpp:63–140`) is the single definition of
"is this mesh usable", and it runs, in order:

1. `weld_and_clean` (Phase 1) — `part.cpp:71`
2. `remove_duplicate_triangles` (Phase 2) — `part.cpp:77`
3. `check_watertight`; if non-manifold edges survive dedup → **refuse**
   `NonManifoldEdges` — `part.cpp:87–101`
4. `fill_small_holes` (Phase 2) on the manifold surface — `part.cpp:109–113`
5. remaining open edges → **refuse** `OpenBoundary` — `part.cpp:118`
6. `unify_normals`; failure → **refuse** `NonOrientable` — `part.cpp:122`
7. zero-volume → **refuse** `ZeroThickness` — `part.cpp:134`

### B. Worker run (the remote job, if the mesh was accepted in A)

```
topopt-cli run  → run_job                       core/src/cli/run_job.cpp
  → import_part_file_resolved(model_path)        core/src/cli/run_job.cpp:272
    → import_part_file_resolved                  core/src/io/face_overrides.cpp:133
      → import_part(path, opts)                  core/src/io/part.cpp:482
        → inspect_and_repair(mesh)               core/src/io/part.cpp:506  ← SAME REPAIR
      → PartError on refusal → JobError          core/src/cli/run_job.cpp:273
```

Both moments funnel through `inspect_and_repair`. The repair is deterministic
(ordered maps, min-index rotation), so the worker re-derives the identical
repaired mesh from the same original bytes the app inspected — the repaired
geometry is never persisted, it is re-computed identically on each stateless
import. **`inspect_and_repair` / `import_part` is on the path, not bypassed.**

---

## STEP 2 — reproduced on the real path, both file classes

Two independent real-path harnesses, no ctest:

### (i) C++ probe against the core entry points (`inspect_part_file` + `import_part`)

Compiled the actual core sources (`part.cpp`, `stl.cpp`, `segment.cpp`,
`mesh.cpp`) and called the exact functions the bridge and the worker call. Raw
output:

| Fixture | `inspect_part_file` result | `import_part` (worker verdict) |
|---|---|---|
| `bracket_clean.stl` | acceptable, no repairs | ACCEPTED (7 faces, 416 tris) |
| `bracket_duplicate_facets.stl` | acceptable, **removed_dup_tris=6** | ACCEPTED (416 tris) |
| `bracket_small_hole.stl` | acceptable, **filled_holes=1 (+4 tris)** | ACCEPTED (418 tris) |
| `bracket_wall_hole.stl` | REFUSED — filled 1, 52 edges remain | *"holes too large or complex to fill safely"* |
| `bracket_ambiguous_junction.stl` | REFUSED — non_manifold_edges=1 survives dedup | *"non-manifold edges that could not be resolved automatically … the junction is ambiguous"* |

The RR2Bracket file itself is not committed / not on disk;
`bracket_ambiguous_junction.stl` is the committed equivalent (a genuine
3+-surface junction → the same `NonManifoldEdges` / "N edges shared by 3+"
refusal the user saw).

### (ii) Real Swift bridge, against fresh vendored core

Ran `build_core.sh` (fresh `TopOptCore.xcframework`, fingerprint `5524204b4f75`
== HEAD), then exercised `TopOptKit.importMesh` / `TopOptKit.inspectPart` — the
**exact** calls `AppModel` makes — on the committed fixtures. New tests in
`TopOptKitTests.swift`:

- `testDuplicateFacetMeshRepairsAndImports` — acceptable, `removedDuplicateTriangles > 0`, imports.
- `testSmallHoleMeshRepairsAndImports` — acceptable, `filledHoles > 0`, imports.
- `testAmbiguousJunctionIsRefusedWithTheRealReason` — refused, `defects.contains(.nonManifoldEdges)`, throws "non-manifold".
- `testWallSizedHoleIsRefusedAfterSafeCapping` — refused, `defects.contains(.openBoundary)`.

All pass through the real bridge. **Before the fix**, the first two would have
imported but reported `didRepair == false` and no repair note (the counts never
crossed the bridge); the ambiguous/wall cases refused correctly but the sheet's
`scopeNote` denied the hole-repair capability.

---

## STEP 3 — the fix (matching the case actually observed)

Case observed: **repair is wired and runs; the sheet copy was stale**, plus the
accepted-path repair reporting was dropped at the bridge. Fixes:

**Honest copy** (`ImportInspection.swift`):
- `scopeNote` rewritten to state what the build actually does (welds,
  re-orients, drops duplicate facets, caps small holes) and where it stops
  (large/complex holes, ambiguous junctions, non-orientable, self-intersections).
- `openBoundary` reason now says the holes remain *after small holes were
  capped* — consistent with the wall-hole behaviour, no longer implying nothing
  was attempted.
- `ImportRepairNote.text` now reports `removed N duplicate facets` and
  `closed N small holes`.
- Stale Phase-1 header/doc comments in `ImportInspection.swift` and
  `TopOptKit.swift` corrected.

**Plumbing** (report every repair the core made):
- `TopOptBridge.hpp` `PartDiagnostics`: added `removed_duplicate_triangles`,
  `filled_holes`, `filled_hole_triangles`.
- `bridge.cpp` `inspect_part`: copies those three from `PartInspection`.
- `TopOptKit.swift` `PartDiagnostics`: added the three fields, threaded through
  `inspectPart`, and `didRepair` now counts dedup + hole-fill.

No core logic changed — the core was already correct. The change is entirely the
app's honesty about what the core did.

---

## Why device could differ from a green test — the stale-vendored-core trap

The app links a **vendored** `TopOptCore.xcframework` produced by
`app/scripts/build_core.sh`; the git-ignored `vendor/` tree is absent on a fresh
checkout. If the app is built/shipped without re-running `build_core.sh`, it
links a **stale core** that may predate Phase 2 — repair would not run on the
device even though every ctest (which compiles fresh core) passes. This is the
mechanism behind "everything passed its own tests and failed on the device."

**Two consequences the shipper must heed:**
1. The bridge changes here read `PartInspection::removed_duplicate_triangles`
   etc. — they require a core at/after the Phase-2 commit. `build_core.sh` must
   be run before building the app (it was, here — fingerprint `5524204b4f75`).
2. If the user's failing build shipped a pre-Phase-2 core, a duplicate-facet
   mesh that *should* repair would have shown a "N edges shared by 3+" refusal on
   the device. Whether RR2Bracket's 10 edges are genuine junctions (correctly
   refused) or removable duplicates (stale-core false refusal) is **unknowable
   without the file** — get RR2BracketSMwithCenterMount.stl and run it through
   the C++ probe / the new bridge tests to settle it. The probe is at
   `scratchpad/probe.{cpp,}` in this session's notes; rebuild with the one-liner
   in §2(i).

---

## Bars

- ✅ A repairable STL imports and is usable — proven on the real path (C++ probe
  ACCEPTED + real-bridge `testDuplicateFacetMeshRepairsAndImports` /
  `testSmallHoleMeshRepairsAndImports`).
- ✅ An unrepairable STL's refusal names the actual, specific reason — the reason
  line names non-manifold / open-boundary; the scope note no longer denies a
  capability the build has (it previously did).
- ✅ Exact call chain app→refusal/repair documented file:line (§1).

## Evidence run

- `build_core.sh`: fingerprint `5524204b4f75` (== HEAD `5524204`).
- `swift test`: `ImportInspectionTests` 14/14, `TopOptKitTests` 30/30,
  `AppModelTests` 28/28 — all green, including the four new real-bridge
  repair/refuse tests and the new Phase-2 repair-note test.

## Files changed

- `app/TopOptKit/Sources/TopOptBridge/include/TopOptBridge.hpp`
- `app/TopOptKit/Sources/TopOptBridge/bridge.cpp`
- `app/TopOptKit/Sources/TopOptKit/TopOptKit.swift`
- `app/TopOptKit/Sources/TopOptFlows/ImportInspection.swift`
- `app/TopOptKit/Tests/TopOptFlowsTests/ImportInspectionTests.swift`
- `app/TopOptKit/Tests/TopOptKitTests/TopOptKitTests.swift`
