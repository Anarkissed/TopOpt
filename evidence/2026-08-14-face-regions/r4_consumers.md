# R4 — EVERY CONSUMER OF A FACE ID, AND WHAT IT READS NOW

Task 2026-08-14-face-regions §3(e). One row per site that resolves a face id.
**LAYER 1** = the original CAD face id (`StepModel::triangle_face`,
`StepModel::faces`). **LAYER 2** = a region.

A consumer marked *"unchanged"* was not touched and does not know regions exist.
That is the point: a consumer silently switched from face to region would be a
regression, so each switch below is a NEW code path beside the old one, and the
old one still runs first and unchanged.

## Core — the selection consumers

| # | consumer | file:line | reads BEFORE | reads NOW |
|---|---|---|---|---|
| 1 | anchor faces → Fixture | `core/src/cli/loadcase.cpp:322` | layer 1, `tag_step_face` | **unchanged**, then `anchor_region_ids` → `tag_step_region` at :324 |
| 2 | load group → Load (probe grid) | `core/src/cli/loadcase.cpp:357` | layer 1 | **unchanged**, then `group.region_ids` at :359 |
| 3 | load group → Load (main grid, retained) | `core/src/cli/loadcase.cpp:380` | layer 1 | **unchanged**, then `group.region_ids` at :388 |
| 4 | anchor/load structural pad | `core/src/cli/loadcase.cpp:566` | layer 1, `mask_step_face` | **unchanged**, then retained load REGIONS at :576 |
| 5 | face protections | `core/src/cli/loadcase.cpp:604` | layer 1, `mask_step_face` | **unchanged**, then `face_protection_region_ids` → `mask_step_region` at :639 |
| 6 | load-path diagnosis | `core/src/cli/loadcase.cpp:901` | layer 1 | **unchanged** — it re-tags each group's FACES on a scratch grid. A region-only group therefore reports no walk; stated in the handoff as a known gap. |
| 7 | clearance keep-outs | `core/include/topopt/clearance.hpp:179`, `core/src/voxel/clearance.cpp` | layer 1, `model.faces[face_id]` axis/normal/outline | **unchanged, and deliberately so** — a keep-out is an ANALYTIC swept cylinder or bounded slab. A region has no analytic surface, so it cannot produce one. |
| 8 | lattice role regions | `core/src/cli/run_job.cpp:621` (`lattice_role_regions_from_job`) | explicit bolt/face GEOMETRY + an optional `face_id` for the depth tie | **unchanged** — see the handoff §6 for what this costs and what it would take. |
| 9 | CAD-face projection | `core/src/cli/run_job.cpp:487-493`, `core/src/mesh/cad_project.cpp` | layer 1 (`triangle_face` + `model.faces`) | **unchanged, and this is bar R2** — measured identical to the digit with a union and a 10x5 grid split applied (`r2_r3_his_part.txt` §4). |
| 10 | CAD/cut classifier (attribution) | `core/src/mesh/cad_project.cpp` `attribute_to_cad_faces` | layer 1 | **unchanged** — per-vertex attribution asserted identical. |
| 11 | face-overrides sidecar (paint) | `core/src/io/face_overrides.cpp:apply_face_overrides` | **WRITES layer 1** (appends pseudo-faces) | **unchanged** — and it is why regions exist as a second layer: paint re-partitions, a region does not. |
| 12 | `tag_step_face` / `mask_step_face` | `core/src/io/face_tag.cpp:151/196` | layer 1 | **unchanged**. `tag_step_region` / `mask_step_region` (`core/src/io/face_region.cpp`) are the layer-2 counterparts, and a one-member zero-cut region tags the same voxels — asserted voxel-for-voxel in `core/tests/unit/test_face_region.cpp`. |
| 13 | job → load case copy | `core/src/cli/run_job.cpp:4141` | a structured binding over `JobLoadCase` | **extended**: the binding now names 18 members, so adding a field without carrying it does not compile. |

## App — the selection consumers

| # | consumer | file:line | reads BEFORE | reads NOW |
|---|---|---|---|---|
| 14 | anchors + load groups → run | `app/…/ProjectModel.swift:494` `loadCase()` | `SelectionGroup.faces` | **unchanged**, plus `g.regionIDs` → `anchorRegionIDs` / `LoadGroupSpec.regionIDs` |
| 15 | face protections → run | `app/…/ProjectModel.swift:594` `faceProtectionSpecs()` | `g.faces` | **unchanged**, plus `g.regionIDs` with their own per-region depths |
| 16 | clearances → run | `app/…/ProjectModel.swift:532` `clearanceSpecs()` | `g.faces` + `mesh.faceGeometry` | **unchanged** (see #7) |
| 17 | lattice regions → run | `app/…/LatticeRegionEmission.swift:116` | `g.faces` + resolved B-rep geometry | **unchanged** (see #8) |
| 18 | job.json emission | `app/…/RemoteRunner.swift:835-900` | `anchorFaceIDs`, `groups[].face_ids`, `face_protections` | **unchanged**, plus `face_regions`, `anchor_region_ids`, `groups[].region_ids`, `face_protections[].region_id` — **all omitted when no region exists**, which is bar R1 |
| 19 | on-device bridge | `app/…/TopOptKit.swift:1624` + `bridge.cpp:436` | flat face-id arrays | **unchanged**, plus flat region arrays; empty ⇒ byte-identical POD |
| 20 | viewer highlight | `app/…/SelectionModel.swift:faceToGroup` | `g.faces` | **unchanged** — a region highlights through its resolved members |
| 21 | project persistence | `app/…/ProjectStore.swift` `ProjectSnapshot` | `selection` | **unchanged**, plus optional `faceRegions`; nil ⇒ the project.json it always wrote |

## The gap, stated

**#6, the load-path diagnosis, does not walk a region.** A load group that names
ONLY regions gets no load-path verdict. It is a diagnostic, not a gate, and the
group still tags, loads and certifies normally — but the diagnosis will say
nothing about it. Fixing it is one call: re-tag the group's regions on the scratch
grid alongside its faces at `loadcase.cpp:901`.
