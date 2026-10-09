# Task (queued 2026-10-03): move the Regions popover's abilities into the Surface stage, then remove the popover

**Start after lattice-types round 3 lands on PR #354's branch.** This is a separate task with its own handoff. App only: never edit a file under `core/`.

## The ruling (maintainer, 2026-10-03, round 3, item 4)

"He wants ALL its popover-only abilities kept. Do NOT remove it yet. Queue a separate task, after this round, with its own handoff: move each ability into the Surface stage, then remove the popover everywhere:
- filter-backed union with its drift warning;
- Small-faces filter with sliders;
- Dissolve, Undo split, add/drop one face;
- whole-region grid split, cylindrical, up to 64.

Screenshot-and-match the Surface stage first."

## Order of work

1. **Screenshot-and-match the Surface stage first**, before any change.
   - Restore his projects from a store snapshot. Use round 2's `tools/snapshot_store.sh`, and never write into the simulator container.
   - Capture the Surface stage as it stands.
   - Match each popover ability to what the Surface stage offers today. Round 2's map, below, is the starting point; re-verify it at the task's HEAD.
2. **Move each ability into the Surface stage**, one commit each, with a test and a RED control. Keep the model calls. Only the UI moves.
3. **Remove the popover everywhere, UI only.** Every saved region stays, and so does the region model.

## What the popover offers, and its model calls (round 2 map, read at 4f63770c; re-verify)

The popover is `FaceRegionSheet.swift`, laid out by `FaceRegionSheetModel.swift`. It is mounted in `WorkspacePlaceholder.swift` (state `regionsOpen` / `regionTapTarget`, overlay `regionsPanelOverlay`, a button with accessibilityLabel "Regions").

| Ability | Model call | Only in the popover today? |
|---|---|---|
| Presets "Fillets & chamfers" (`RegionFilter.blend`), "Bores of one size" (`RegionFilter.bores`, ±0.05 mm), "Small faces" (area under a threshold) | `FaceRegionGeometry.match` | "Small faces" and its numeric sliders: **yes** |
| Size slider (0.02–1.0 × median face area); radius slider (0.5–40 mm) | — | **yes** |
| Combine: one region storing the **filter** and `matchedAtAuthor` | `FaceRegionModel.union(faces:named:filter:matchedAtAuthor:)` | **yes**. `commitSurfaceUnion(_ filter:named:)` exists but only tests call it. |
| Drift banner, "name: then → now faces" | `FaceRegionModel.drift(matchedNow:)`; `ProjectModel.faceRegionDrift` is computed on restore but nothing displays it | **yes** |
| Region list with face, voxel and child counts | `FaceRegionModel.roots` | informational |
| Split N×M (1–64) in the region's own frame over ALL members, cylindrical Around/Along when they share an axis | `gridPreview` / `gridCells`, `FaceRegionModel.splitGrid` | **yes**. Surface Pattern frames from one face, caps at 12, no cylindrical frame. |
| Undo split, at any later time | `FaceRegionModel.revertSplit` | **yes**. Header Undo only reaches back within the session. |
| Dissolve: region → plain faces in the active group | `dissolve`, `selection.removeRegions`, `addFaces` | **yes** |
| Tap to add/drop one face on an existing region (Topology stage) | `FaceRegionModel.addFace` / `removeFace`, then `refreshFaceRegionDrift` | **yes** |
| Rotate, Cut once, Collapse, sliver refusal and dimming | various | covered by the Surface stage / Selections |

**Possible defect to check first.** From reading only, patterning a face inside a Surface **union** aims at the union, which owns no faces, so the cells would hold none. Run a positive control before relying on "combine, then pattern" through the Surface stage.

## Removal sites (round 2 map; re-verify the line numbers)

- `WorkspacePlaceholder.swift`:
  - the `regionsOpen` / `regionTapTarget` state;
  - the overlay mount;
  - the regions branch of `handlePick`;
  - the `!regionsOpen` clause in `handleTopologyPiecePick` (a compile dependency);
  - `regionsPanelOverlay`;
  - the button.
- Delete `FaceRegionSheet.swift`. If `FaceRegionSheetModel.swift` goes too, port or deliberately delete `FaceRegionTests.swift`'s three sheet-model tests, and say which.
- Stale comments that claim "the Regions sheet still offers it": in `WorkspacePlaceholder.swift` and `SurfaceSimilar.swift`.

**Must not touch:**
- `FaceRegionModel` (`FaceRegion.swift`) and `ProjectModel.faceRegions` / `faceRegionDrift`.
- Persistence, `EditSnapshot.faceRegions`, `SurfaceScratch`.
- The job emission of `face_regions` / `region_ids` / `region_id`.
- `LatticeRegionEmission` and `latticeRegionRefs`.

## His data

None of his 9 saved regions came from the popover: every one has a single-face `add` list, no filter, no cuts (102117B9: ids 100–107; 68BF7B74: 101). Removal loses no saved data, only abilities, and this task keeps every ability.

## Done means

- Every ability above is reachable on the Surface stage, each with a test and a RED control.
- The popover and its button are gone, and every saved region still loads and emits the same job bytes (stage-hash dump before and after).
- The full suite has run, with every failure named.
- A handoff in `docs/handoffs/`.
