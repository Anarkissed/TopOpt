# 087 — Wire the smooth surface export into the app

**Track:** app / bridge. **Territory:** `app/TopOptKit/Sources/TopOptBridge/bridge.cpp`
+ `app/.../TopOptFlows/ResultsModel.swift` + `ResultsScreen.swift`. `/core/` UNTOUCHED
(086 landed the algorithm there). No fixtures, benchmarks, materials.json,
ARCHITECTURE.md, ROADMAP box. **Builds on:** 086-surface-resample (core
`marching_cubes_resampled` + `resample_field`, tricubic Catmull-Rom, default-OFF CLI
seam) and 082-designbox-grid-mismatch-fix (use `mp.solved_grid`, never a re-derived
grid).

086 wired 086's smooth tessellation into the **CLI export point only**, default OFF, so
the app still tessellated the raw 64³ marching-cubes surface and the maintainer never
saw the fix on device. This turns it on in the bridge at factor 2.

Not invention: the physical density is a grayscale ramp (the M3.3 filter blurs the 0/1
design; min-feature floors at 1.5 voxels → ~4.7 mm ramp at 64³); MC at 64³ tessellates
that smooth ramp with ~3.1 mm facets, so the terracing is **under-tessellation of a
smooth field**. Resampling the SAME field and running the SAME MC finer is a better
polygonal approximation of the SAME 0.5 iso-surface. No new design detail, no ML.

---

## STEP 1 — THE SEAM DECISION (first, because it drives everything)

**Decision: smooth the ONE mesh the bridge hands the app (display + future export), at
factor 2. There is no separate "export-only" path to wire, and export-only would leave
the maintainer's screen unchanged.**

Why, from the code as it actually is:

- The bridge sends exactly ONE mesh per variant: `to_optimize_variant` copies
  `v.mesh()` (= `v3.mesh`) into `OptimizeVariant.mesh_vertices / mesh_indices`. That
  single buffer is *all the geometry the app has* for a variant.
- The viewer renders it (`ResultsModel.selectedMesh` → `ViewerMesh(v.meshVertices,
  v.meshIndices)`).
- **File export (.3mf/.stl) is still a placeholder.** Tapping "Export .3mf" runs
  `onExport`, which in the one place it is constructed (`WorkspacePlaceholder.swift`)
  is `{ model.toast = "Export (.3mf) arrives in M7.9" }` — no file is written, no
  `ImportedMesh` is built, `TopOptKit.exportSTL` is called only from a unit test. When
  M7.9 lands, export will necessarily read the same `meshVertices / meshIndices`.

So the two consumers the task names — EXPORT and DISPLAY — are today a **single buffer**,
and the only consumer that produces anything **visible on device is the viewer**. An
"export-only" wiring (a second smoothed buffer the display ignores) would ship a mesh
nothing renders and leave the maintainer's screen unchanged — the exact outcome this
task exists to fix. Smoothing the shared mesh is the only wiring that reaches the device.

That leaves one real question: **can the iPad viewer take the 2× triangle count on a
lacy part** (2× ≈ 4× triangles, re-uploaded per variant selection)? Measured on a
genuine lacy 64³ result (a low-vf self-weight cantilever, NOT 086's solid-ish bracket).

**Real lacy part — 64×24×40, 3.125 mm spacing (200×75×125 mm), production min-feature
filter (2.5 mm → rmin floored at 1.5 vox → 4.69 mm ramp), MMA + matrix-free multigrid,
`simp_optimize` to vf 0.30, Mnd 0.376 (lacy grayscale):**

| factor | MC lattice   | triangles | vertices | viewer upload (per variant) | MC time |
|-------:|--------------|----------:|---------:|----------------------------:|--------:|
| 1×     | 64×24×40     |    32,460 |   16,178 | 145,914 floats ≈ **0.58 MB** |   24 ms |
| **2× (shipped)** | 128×48×80 | **124,856** | 62,380 | 561,708 floats ≈ **2.25 MB** | 111 ms |
| 4×     | 256×96×160   |   506,808 |  253,352 | 2,280,480 floats ≈ 9.12 MB  |  587 ms |

Triangle count grows ≈ factor² (surface area). The lacy part is ~1.8× the triangles of
086's solid-ish bracket (086: 17k→70k at 1×→2×; here 32k→125k) — exactly the "more on a
lacy topology" 086 could not measure. **At 2× that is 124,856 triangles / ~2.25 MB
uploaded once per variant selection** (not per frame; the ladder has ≤4 accepted
variants). That is well within an iPad Metal viewer's budget — it renders millions of
triangles per frame; the only cost here is a one-off ~2 MB GPU buffer upload on tab
switch. **The viewer is not tanked. Recommendation confirmed: smooth both, factor 2.**

The knob is one constant (`kSmoothExportFactor`); 4× (~507k tris, ~9 MB) is there for a
desktop slicer but is heavier than the 2× visible gain warrants for the on-device viewer.

---

## STEP 2 — WHAT WAS WIRED

`bridge.cpp`, one seam, mirroring the CLI (`run_job.cpp`) call exactly:

- `constexpr int kSmoothExportFactor = 2;` (086's recommendation; the core call
  accepts 1–4).
- New helper `export_display_mesh(v, solved_grid, factor, scratch)`: at `factor > 1`
  returns
  `keep_largest_component(marching_cubes_resampled(sg.nx, sg.ny, sg.nz, sg.spacing,
  sg.origin, v.optimization.physical_density, 0.5, factor, ResampleInterp::Tricubic))`
  — the identical call the CLI export uses. At `factor <= 1`, for a cancelled rung
  (empty `v.mesh()`), or a field/grid size mismatch, it returns `v.mesh()` verbatim.
- `to_optimize_variant` now takes `(v, solved_grid, smooth_factor)` and builds
  `mesh_vertices / mesh_indices / mesh_triangle_count` from `export_display_mesh(...)`.
- Both call sites already thread the correct grid: `to_optimize_result(mp, grid)` is
  called with `mp.solved_grid` (loadcase path, line 881) and the no-box selfweight grid
  (== solved, line 602); `set_variant_stream` captures `result_grid =
  minimize_plastic_solved_grid(grid, opts)` (loadcase) / the selfweight grid. **The
  resample runs on `mp.solved_grid` — the grid `physical_density` is indexed to — never
  a re-derived grid (082 guard).**

Keyframe playback meshes are left raw (the 12-frame "carving-out" animation); only the
final displayed/exported surface is smoothed. If the last playback frame's pop-to-smooth
reads as distracting, smoothing the final keyframe is a cheap follow-up.

---

## STEP 3 — THE MASS NUMBER (honesty guard) — bigger than 086 knew

Reported mass is **voxel-count based** (`minimize_plastic.cpp`: `mass_grams =
density_g_cm3 * printed_voxels * voxel_volume / 1000` — every voxel with ρ>0.5 counted
as FULLY solid). The three numbers for the real lacy part:

| geometry | volume (mm³) | mass (g) | vs voxel readout |
|----------|-------------:|---------:|-----------------:|
| reported (voxel count, ρ>0.5) | 470,154 | **582.99** | — |
| 1× MC mesh (today's export/display) | 450,908 | 559.13 | voxel **+4.3 %** heavier |
| 2× resampled mesh (shipped) | 451,123 | 559.39 | voxel **+4.2 %** heavier |
| 4× resampled mesh | 453,877 | 562.81 | voxel +3.6 % heavier |

**The mesh volumes agree within 0.66 % across 1×/2×/4× (the 0.5 iso-surface is stable);
the voxel count is the +4 % outlier.** This is the physically meaningful gap: the printer
prints the exported MESH (the 0.5 iso-surface), so the mesh-volume mass (~559 g) is the
print mass; the voxel count (~583 g) over-reads it because on a **grayscale, lacy**
design it treats every ρ>0.5 voxel — many of them partial/boundary — as 100 % solid.

**This is much larger than 086's ~0.25 %/0.7 %.** 086 measured on a solid-ish, nearly
black/white bracket (Mnd 0.094, low surface-to-volume), which is exactly where the
voxel-count ≈ mesh-volume. The gap **scales with grayscale-ness (Mnd) and laciness**:
here Mnd 0.376 → +4.3 %. The production part's Mnd (~0.27 per the task context) would be
somewhat smaller, but still **several percent — materially above 086's number, because
production MMA runs WITHOUT projection (projection_supported(MMA)==false), so the shipped
designs are grayscale.** Once we ship a smooth (accurate) mesh, the "583 g" readout
describes an object ~4 % heavier than the file/preview.

**In-territory decision: the readout is left voxel-count based, NOT silently — it is
flagged here with the exact fix and the measured magnitude. It is NOT recomputed in the
bridge**, because:

1. The mass definition must be ONE thing across core, CLI JobReport, and app. Fixing it
   only in the bridge fragments it: the same design would report ~559 g in the app and
   ~583 g in the CLI report (which keeps the voxel formula in `minimize_plastic.cpp`).
   The CLI already has the SAME latent inconsistency (086's smooth export vs its
   voxel-mass report) — the correct fix cures all consumers at once, in the core.
2. Recomputing in the bridge would change today's factor-1 readout too and would be an
   unverifiable numeric change to a user-facing value (the Swift app suite cannot be
   built in this Linux worktree).

This is NOT the 080 class (a wrong SIGN shipped to users): it is a consistent, coarser
definition that is ~4 % heavy vs the printed mesh — but at 4 % it is no longer negligible
polish, and it must be fixed before the app ships smooth export to end users.

**FOLLOW-UP (core, out of this task's territory) — exact change** in
`core/src/simp/minimize_plastic.cpp`, replacing the voxel-count mass (~line 513, which
runs BEFORE `variant.v3` is populated at ~line 546 — move it after, so `v3.mesh` exists):

```cpp
// after `variant.v3 = check_v3(G, rho, kIso);` (v3.mesh now exists), replace
// the voxel-count mass so core, CLI report, and app all report the printed mesh:
variant.mass_grams =
    material.density_g_cm3 * std::abs(topopt::signed_volume(variant.v3.mesh)) / 1000.0;
```

Maintainer decision in that follow-up: anchor mass on the **1× mesh volume** (`v3.mesh`,
already computed — deterministic, independent of the `smooth_factor` knob) rather than
the resampled export volume (most accurate but then mass tracks the tessellation factor).
Recommend the 1× mesh volume: it removes the standing ~4 % over-read against the exported
geometry and does not vary with the display/export knob. (`savings` /
`achieved_volume_fraction` are volume-fraction DESIGN metrics, correctly voxel-based —
they are not mass and need not change.) `signed_volume` is sign-conventioned to the MC
winding, hence `std::abs`.

---

## STEP 4 — THE 083 NOTE (now that export is smooth)

The old note ("The surface stepping is real geometry … stays in the exported STL —
smoothing softens the preview only") became FALSE once export is smooth. Replaced in
`ResultsModel.surfaceResolutionNote`:

> Solved at %.1f mm voxels. At this resolution the design's finest features are limited
> to about %.1f mm (the min-feature filter floor) — detail finer than that cannot form
> regardless of tessellation. The surface faceting is a separate tessellation effect,
> now smoothed on export; it is not the design limit. Raise Detail for finer features.

It keeps two DIFFERENT things distinct:

- **SURFACE SMOOTHNESS** (the marching-cubes faceting) → a tessellation effect, **FIXED
  here** (resampled export).
- **DESIGN DETAIL** (the finest member the optimizer can form) → the min-feature filter
  floor, `max(1.5·spacing, 2.5 mm)` in mm, which smoothing does NOT change: finer
  features need finer VOXELS (Raise Detail), not finer tessellation. NOT fixed here.

The effective min feature is **computed from the actual spacing** (`max(1.5·spacing,
2.5)`), not hardcoded 4.7. The doc comments in `ResultsScreen.resolutionNote` and
`ResultsModel.selectedMesh` were updated to match.

---

## Guards

- **factor 1 == today.** `export_display_mesh` returns the *same `v.mesh()` reference*
  at `factor <= 1`, so the exported/displayed buffers are byte-identical to today. (086
  additionally asserts `marching_cubes_resampled(...,1,...) == marching_cubes(...)`
  byte-for-byte in `test_resample`; the bridge avoids the recompute entirely at 1×.)
- **Watertight, no new components, end to end.** Measured on the lacy part via the exact
  bridge path (`keep_largest_component(marching_cubes_resampled(...))`): **watertight,
  1 component, 0 boundary + 0 non-manifold edges at 1×, 2× AND 4×.** 086's core guards
  prove the algorithm; this confirms the bridge path preserves it.
- **Field / optimizer / FEA / ladder untouched.** `physical_density` is read by const
  ref (086 asserts `resample_field` never mutates); `/core/` is unchanged; the resample
  is pure geometry after the solve. Cancelled rungs return empty `v.mesh()` verbatim (no
  spurious mesh synthesized from a half-optimized field).
- **Core suite green: 38/38 passed** (`ctest`, this worktree, Eigen present). The Swift
  app suite could not be run here (Xcode/macOS only; `build_core.sh` builds the
  xcframework on macOS). `bridge.cpp` was type-checked against the core headers
  (`clang++ -fsyntax-only`, clean); the change is mechanical field-mapping plus one core
  call already covered by `test_resample`.

## Build / verify

`/core/` is untouched by THIS task, but 086 changed `/core/`, so the app still needs
`app/scripts/build_core.sh` (macOS) to refresh the vendored xcframework before the next
app build. Core: `cmake --build core/build && ctest`. Measurement harness (not
committed) lives in the session scratchpad (`measure2.cpp`): a real `simp_optimize` run
with the production filter that prints the STEP-1 / STEP-3 tables above.

## NOT done (deliberately)

- **No app-side smoothing UI control** — the maintainer wants to *see* the fix, not
  configure it; the factor is one bridge constant ("app/ only if a control must surface"
  — none must).
- **Mass unification** (STEP 3) — core territory; exact patch above.
- **No ROADMAP box checked.**
