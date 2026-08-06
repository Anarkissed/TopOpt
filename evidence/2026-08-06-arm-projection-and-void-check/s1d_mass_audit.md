# S1(d) — EVERY MASS AND VOLUME THE APP DISPLAYS, AND WHERE ITS NUMBER COMES FROM

Task `2026-08-06-arm-projection-and-void-check`.

**★ NOTHING HERE WAS CHANGED, AND THAT IS THE POINT.** The brief is explicit:
*do not "fix" any of them — the voxel figures were never wrong and the mesh ones
become right on their own.* Changing a mass formula in the same PR that changes
the geometry would make both unattributable. This file is the audit, not a diff.

## The rule that decides every row

* **VOXEL-derived** — counted off the density field on the solved grid.
  CAD-face projection runs inside `export_variant_mesh`
  ([core/src/cli/run_job.cpp:343](../../core/src/cli/run_job.cpp)) on a **copy of
  the mesh**, after the design, the field, the certification and the report are
  all final. It never touches a voxel. **These figures do not move.**
* **MESH-derived** — the enclosed volume of an exported triangle mesh × density.
  **These drop by about 8% on his part**, because PR 307 measured the
  un-projected export ~8% oversize: 100% of flat-face vertices outside their own
  CAD plane by ~0.67 mm, and a re-certified un-projected variant reporting a
  volume fraction of **1.0028**, which is impossible for a design that removed a
  third of the material. They drop because they stop being wrong.

## The audit

| # | What he sees | Where | MESH or VOXEL | Moves? |
|---|---|---|---|---|
| 1 | `"Mass (voxel / mesh)"`, formatted `"%.1f / %.1f g"` | [SmoothingPanel.swift:133](../../app/TopOptKit/Sources/TopOptFlows/SmoothingPanel.swift) | **BOTH, side by side** — voxel from `bridge.cpp` `a.mass_grams`; mesh from the signed-tetrahedra volume × density | the **mesh** half drops ~8%; the voxel half does not |
| 2 | smoothing page row `"Mass (voxel)"`, before/after | [SmoothingPageModel.swift:206](../../app/TopOptKit/Sources/TopOptFlows/SmoothingPageModel.swift) | **VOXEL** (`raw.voxel_mass_grams`) | **no** |
| 3 | smoothing page row `"Mass (mesh)"`, before/after | [SmoothingPageModel.swift:210](../../app/TopOptKit/Sources/TopOptFlows/SmoothingPageModel.swift) | **MESH** (`raw.mesh_mass_grams`) | **yes, ~8% down** |
| 4 | the variant tab's mass label | [ResultsModel.swift:2157](../../app/TopOptKit/Sources/TopOptFlows/ResultsModel.swift) | **VOXEL** (device: `bridge.cpp` `v.mass_grams`; remote: `fields.bin`) | **no** |
| 5 | `"Mesh: 41.3 g · voxel estimate: 43.1 g"` | [ResultsModel.swift:542](../../app/TopOptKit/Sources/TopOptFlows/ResultsModel.swift), rendered [ResultsScreen.swift:1371](../../app/TopOptKit/Sources/TopOptFlows/ResultsScreen.swift) | **BOTH, explicitly labelled** — mesh via `MeshExport.meshMassGrams`, voxel alongside | the **mesh** half drops ~8% — see the note below, this row changes SHAPE |
| 6 | `"+X g of plastic added"` (growth ladder) | [ResultsModel.swift:396](../../app/TopOptKit/Sources/TopOptFlows/ResultsModel.swift) | **VOXEL** (`net_added_mass_grams`) | **no** |
| 7 | lattice page identity line `"Variant 2 · 60% · 41.2 g"` | [LatticeVariantSession.swift:344](../../app/TopOptKit/Sources/TopOptFlows/LatticeVariantSession.swift) | **VOXEL** | **no** |
| 8 | smoothing page identity line | [SmoothingVariantSession.swift:282](../../app/TopOptKit/Sources/TopOptFlows/SmoothingVariantSession.swift) | **VOXEL** | **no** |
| 9 | discard confirmation `"(lightest %.1f g)"` | [VariantEntry.swift:321](../../app/TopOptKit/Sources/TopOptFlows/VariantEntry.swift) | **VOXEL** | **no** |
| 10 | support volume `"%.1f cm³"` | [ResultsModel.swift:2138](../../app/TopOptKit/Sources/TopOptFlows/ResultsModel.swift) | **VOXEL-field** (`supportVolumeVoxels × voxelVolumeMM3`) | **no** |

**Every displayed figure's source was determined.** The blocked-stop *"the mass
audit finds a displayed figure whose source you cannot determine"* was not hit.

## Two things worth saying out loud

**★ Row 5 changes SHAPE, not just value.** `MassComparison.summary`
([ResultsModel.swift:542](../../app/TopOptKit/Sources/TopOptFlows/ResultsModel.swift))
prints BOTH numbers only when they diverge beyond 1%
(`divergesBeyond1Percent`, [:530](../../app/TopOptKit/Sources/TopOptFlows/ResultsModel.swift));
otherwise it prints the mesh mass alone. On his part they currently diverge by
about 5% (mesh 649.94 g against voxel 683.84 g on rung 068), so he sees the
two-number form. With projection armed the mesh figure falls to 598.99 g and the
gap **widens**, so the two-number form stays — but on a part where the two
happened to sit near the 1% threshold, the row could switch between one number
and two. That is the existing rule doing what it was designed to do on a
newly-correct input, **not** something to fix here.

**`lattice_mass_grams` is never displayed.** Core writes it
([core/src/cli/run_job.cpp](../../core/src/cli/run_job.cpp), the lattice
receipt), and a repo-wide grep over `app/TopOptKit/Sources` and `app/TopOpt`
returns **zero** reads. A latticed variant's mass on the results screen is still
the plain per-variant **VOXEL** figure of row 4. So the brief's starting point
("`lattice_mass_grams` in the variant reports") is a figure in the *receipt*,
not on his screen — worth knowing before anyone goes looking for it in the UI.

## The measured before/after on his own part, resolution 128

Mesh-derived mass, from `r1_table_128.txt` — his four rungs, the same meshes
PR 307 measured:

| rung | mesh mass BEFORE | mesh mass AFTER | change |
|---|---:|---:|---:|
| variant_026 | 479.97 g | 436.85 g | **−8.98%** |
| variant_038 | 529.56 g | 484.20 g | **−8.57%** |
| variant_052 | 604.70 g | 556.84 g | **−7.91%** |
| variant_068 | 649.94 g | 598.99 g | **−7.84%** |

The **voxel** mass of those same designs does not move at all, because the design
does not move — see R2's flip count.

**★ AND THE DIRECTION IS NOT UNIVERSAL.** On the demo l-bracket at resolution 48
the same operation makes the exported volume **larger**, 20 215.0 → 22 029.1 mm³
(**+9.0%**, `r4_end_to_end.txt`). PR 307's "−8%" is a property of **his part**,
where the density filter's outward bias dominates; it is not a constant of the
feature. Anyone reading "masses drop 8%" as a general rule would be wrong.
