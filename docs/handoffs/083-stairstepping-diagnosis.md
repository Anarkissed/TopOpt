# 083 — Stair-stepping / terracing on large parts (diagnosis + display fix)

Symptom (device): **"I bracket large"** (588 g) renders with pronounced horizontal
terracing — the voxel grid shows through the surface. The smaller **"I bracket"**
(27 g), *same app settings*, renders smooth/organic. Both at Detail = Fast (64³).

## STEP 1 — Measurement (table first)

Both parts run the **identical** pipeline — there is no size-based branch in the
mesh/density path (`kSmallMaxDimensionMm` only feeds slicer settings,
`settings.cpp:505`). The only thing that differs is bounding-box size, and size
drives the density-filter radius, which sets how sharp the iso-surface is.

### The governing chain (all in-tree, cited)

| Step | Code | Formula |
|---|---|---|
| Voxel edge (spacing) | `voxelize.cpp:226` | `spacing = max_extent / resolution`, `resolution = 64` (Fast, `FlowModels.swift:53`) |
| Min feature (physical, fixed) | `bridge.cpp:199` | `min_feature_mm = 2.5` (both updaters) |
| Filter radius (voxels) | `minimize_plastic.cpp:371`, `simp.cpp:286` | `radius = max(1.5, 2.5 / spacing)` — floor 1.5 vox (`simp.hpp:203`) |
| Iso-surface | `mesh.cpp:383` | marching cubes, `iso = 0.5`, linear edge interpolation |
| Density projection | `simp.hpp:329`, `bridge.cpp:197` | **MMA (production default) skips Heaviside** → grayscale field, both parts |
| Mesh smoothing | — | **none exists** (core or app) |
| Render shading | `ViewerMesh.swift:204` | **was** flat / per-face normals for the optimized result (now smooth — see STEP 3) |

### Voxel edge + filter radius vs part size (Fast = 64³, min_feature = 2.5 mm)

Reproduction of the two cited formulas (`/tmp/tbl.cpp`):

| max_ext (mm) | spacing (mm/vox) | filter radius (vox) | floored? | eff. min-feat (mm) | band ≈2·r (vox) |
|---:|---:|---:|:--:|---:|---:|
| 20 | 0.312 | 8.00 | no | 2.50 | 16.0 |
| 40 | 0.625 | 4.00 | no | 2.50 | 8.0 |
| 64 | 1.000 | 2.50 | no | 2.50 | 5.0 |
| 100 | 1.562 | 1.60 | no | 2.50 | 3.2 |
| **106.7** | 1.667 | **1.50** | **YES** | 2.50 | **3.0** ← crossover |
| **140** | 2.188 | **1.50** | **YES** | **3.28** | **3.0** |
| 200 | 3.125 | 1.50 | YES | 4.69 | 3.0 |

**Crossover: `max_ext > 106.7 mm` (spacing > 1.667 mm) → filter radius pins to the
1.5-voxel checkerboard floor.** Past that point the density transition band is the
*narrowest the pipeline allows* and the requested 2.5 mm min feature is no longer
honored (it silently grows). Corroborated by `test_rmin.cpp:95-110`:
`physical_filter_radius(2.5, 2.5/1.5) == 1.5` is exactly the 1.667 mm boundary.

### The two parts — measured

| | small "I bracket" (27 g) | large "I bracket large" (588 g) |
|---|---:|---:|
| bbox (mm) | ~72 × 36 × 54 *(derived)* | **200 × 100 × 150** *(measured, device)* |
| grid (Fast 64³) | ~64 × 32 × 48 | **64 × 32 × 48** *(measured)* |
| **voxel edge (mm)** | **~1.12** *(derived)* | **3.125** *(measured; 200/64)* |
| filter radius (vox) | ~2.2 (unfloored) | **1.5 (floored)** — 2.5 mm < one 3.1 mm voxel |
| transition band ≈2·r (vox) | ~4.5 → **smooth** | 3.0 → **terraced** |
| floor engaged? | no | **YES** |
| surface note shown? | no | **yes** ("Solved at 3.1 mm voxels…") |

The large bracket is measured from the device readout. The small bracket's bbox is
**derived**: 588/27 = 21.8× mass ⇒ (21.8)^(1/3) ≈ 2.8× linear at equal density, so
~200/2.8 ≈ 72 mm longest ⇒ spacing ≈ 1.12 mm, radius ≈ 2.2 vox (**above** the 1.5
floor → smooth). Its exact bbox should be read off the device to confirm, but any
longest axis **< 107 mm** lands it in the smooth (unfloored) regime — which is why
it renders organic at the same Fast setting. Decisively, the large bracket's 2.5 mm
requested min feature is **smaller than a single 3.125 mm voxel**, so the filter
cannot help but sit on its floor. (The new `surfaceResolutionNote` now *displays*
the real voxel size per part, so this is no longer a back-derived heuristic.)

### Is the density band ALSO sharp? (the MMA / Heaviside question)

**No — and that is protective, not a second cause.** MMA (production default) skips
Heaviside projection on *both* parts, so neither field is near-binary; the measured
grayscale is `Mnd ≈ 0.27` (`test_mma_projection_gate`, `benchmarks.json`). On the
large part the filter band is pinned to its **minimum** (1.5 voxels ≈ 4.7 mm) but it
is still a *grayscale ramp*, not a 0/1 snap — so the iso = 0.5 crossing still
interpolates within that ramp. The stairs come from the **3.1 mm voxel size**, not
from the field snapping to voxel boundaries. Turning projection **on** (the OC path)
would *sharpen* the band toward binary and make the terracing **worse**. So there is
no separable "sharp-band" defect to fix — voxel size dominates, and the grayscale
band is the only smoothing present, already at its floor.

### Which hypothesis the numbers support

- **(a) resolution-to-feature ratio — YES, the cause.** Fast pins 64 voxels to the
  longest axis; the 2.5 mm physical filter collapses to the 1.5-voxel floor once the
  part exceeds ~107 mm. The large part is optimized and meshed at the coarsest
  smoothing the pipeline permits, with 3.1 mm voxels.
- **(b) smoothing absent/unscaled — YES, amplifier.** No mesh smoothing exists, and
  the viewer drew the raw marching-cubes surface **flat-shaded**, making every
  lattice facet a visible terrace. The small part survived flat shading only because
  its geometry is already smooth.
- **(c) sharper density band on the large part — REFUTED.** See above: MMA leaves
  both fields grayscale; the band is at its floor but not binary.
- **(d) part shape — secondary amplifier only.** Broad flat faces read terracing
  more than a blob, but the 1.5-voxel floor makes the large part coarser regardless.

## Named cause

**The physical 2.5 mm minimum-feature filter collapses to the 1.5-voxel
checkerboard floor once a part's longest axis exceeds ~107 mm at Fast = 64³.** Below
that the radius grows as `2.5/spacing` (6–16-voxel band) → organic surface; at/above
the floor the field transitions over ~1.5 voxels → the iso = 0.5 crossing is confined
to single lattice edges → the marching-cubes staircase, drawn flat-shaded, reads as
terracing. It is a genuine resolution/length-scale limit on the large part, **not** a
projection or extraction defect. The large "I bracket large" is solved at **3.125 mm
voxels** — the terracing is real geometry at that scale.

## STEP 2 — Recommendation (tradeoffs)

The root cause is in the **optimizer's filter** — changing it changes the FEA-solved
and printed geometry, out of bounds for a display fix. Options:

1. **Smooth-shade the optimized result (display only). CHOSEN.** The viewer already
   computes smooth per-vertex normals; switching the optimized result from flat to
   smooth normals is the intended use, touches **no geometry, mass, exported STL/3MF,
   or FEA**, and directly reduces "the grid showing through." Honest caveat: it is
   shading, not geometry — the **silhouette still steps** and the **exported STL is
   unchanged**. Paired with an honest note (option 3) so it is not sold as making the
   part smoother/stronger.
2. **Raise Detail for large parts (real geometric cure — changes the FEA).** 96³/128³
   clears the floor, but **changes the optimization result** and the memory bill is
   steep — 128³ is 8× the voxels of 64³, and the design-box path already peaks
   ~1.97 GB (handoff 079; ~7 GB transient K avoided only via matrix-free multigrid,
   `simp.hpp:64`). **Not auto-applied** — offered as a user choice in the note.
3. **Expose the limit honestly (UX). CHOSEN (paired with 1).** Surface the real voxel
   size when a part crosses the ~107 mm floor.

**Excluded:** default Laplacian/Taubin *vertex* smoothing — it moves vertices, shrinks
volume, and changes reported mass + printed geometry (misrepresents the part).

## STEP 3 — Implementation (display/extraction only; no FEA/optimizer change)

1. **Smooth-shaded organic result.** New `MeshGeometry.flatShadedSmooth`
   (`ViewerMesh.swift`): same unshared-vertex layout and **byte-identical positions/
   order** as `flatShaded` (so per-flat-vertex stress/flex/id buffers stay aligned),
   but each vertex carries the shared-vertex smooth normal instead of the face normal.
   `ViewerMesh.init(…, smoothShaded:)` gates it — **default `false`** (imported CAD
   preview, `ProjectModel.swift:108`, stays flat/crisp), **`true`** on the two
   optimized-result sites (`ResultsModel.selectedMesh`, `.keyframes()`).
2. **Honest note.** `ResultsModel.surfaceResolutionNote` returns a concrete note ONLY
   when `spacing > 2.5/1.5 ≈ 1.667 mm` (floor engaged): *"Solved at 3.1 mm voxels. The
   surface stepping is real geometry at this scale and stays in the exported STL —
   smoothing softens the preview only. Raise Detail for a finer surface."* Surfaced as
   a non-interactive caption below the top bar (`ResultsScreen.resolutionNote`). Small
   parts (spacing < 1.667 mm) show nothing.

**Honesty invariants held:** exported STL/3MF is **byte-identical** — `export_stl`
(`bridge.cpp:364`) writes the core `TriangleMesh` via `write_stl_file` and never sees
the viewer's display normals. Mass, FEA, and optimizer untouched. The note states the
real voxel size and that the export keeps the stepping.

## Evidence

- Filter-radius / voxel-edge table: reproduction of `voxelize.cpp:226` +
  `physical_filter_radius` (`simp.cpp:286`), `/tmp/tbl.cpp` output above.
- `test_rmin.cpp:95-110` asserts the floor behavior and the 1.667 mm / 106.7 mm
  boundary.
- MMA-skips-projection: `simp.hpp:329`, `bridge.cpp:197`, `test_mma_projection_gate`
  (grayscale `Mnd ≈ 0.27` both paths).
- **Swift tests: 410 pass, 0 fail** (`swift test`), including 2 new `ViewerTests`
  cases: `testSmoothFlatBufferMatchesFlatPositionsButUsesSmoothNormals` (same
  positions, smooth ≠ flat normals) and `testSmoothShadedViewerMeshLeavesGeometryUnchanged`
  (positions/indices identical; only render normals differ). `swift build` clean
  (two pre-existing PlaybackVideo Sendable warnings, unrelated).

## Notes for the next session

- Worktree hazard: this branch's file edits initially landed in the **shared main
  working tree** (a concurrent session was mid-flight there on branch `main` with
  bridge.cpp / CMakeLists / an 084 handoff). Edits were relocated to this worktree and
  reverted from main. If you build here, run `app/scripts/build_core.sh` first
  (stale vendored core lib — see memory `app-worktrees-need-build-core`).
- Did NOT check any ROADMAP box.
