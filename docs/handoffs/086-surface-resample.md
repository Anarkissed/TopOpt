# 086 — Smooth surface tessellation by resampling the density field

**Track:** core. **Territory:** `/core/` mesh extraction + the CLI export seam
(`job.cpp` / `run_job.cpp`). No optimizer, no FEA, no filter, no density-field
changes. `simp.cpp` / `simp.hpp` / `minimize_plastic.cpp` untouched (a concurrent
task owns them). No fixtures, benchmarks, materials.json, ARCHITECTURE.md, ROADMAP.
**Builds on:** 083 (terracing diagnosis: min-feature floor → 4.7 mm ramp).

## What this is (and what it is NOT)

MESH ONLY. It resamples the EXISTING physical-density field to a finer lattice and
runs the SAME marching cubes there, so the exported STL/3MF is a better polygonal
approximation of the SAME 0.5 iso-surface. It adds **no** design information, makes
**no** claim the optimizer did not make, and needs **no** ML.

Why that is faithful, not invention:
- The optimizer's physical density is **grayscale** — the M3.3 density filter blurs
  the 0/1 design into a ramp. Marching cubes already interpolates it; it is not a
  binary field.
- On a 200 mm part at 64³ the min-feature filter floors at 1.5 voxels, so the ramp
  spans ~1.5 vox ≈ **4.69 mm** (measured: `physical_filter_radius(2.5mm, h=3.125) =
  1.5000 voxels`). That ramp **is** a smooth curved surface.
- MC at 64³ tessellates it with ~3.1 mm facets — roughly one facet per curvature
  feature. The observed "terracing" is **under-tessellation of a smooth field**, not
  a blocky field. Resampling the SAME field and running MC finer removes it.

---

## STEP 0 — COST FIRST (measured before wiring anything)

Real ~200 mm bracket, **64×24×40** grid, spacing **3.125 mm** (200/64), the
production physical filter applied (min-feature 2.5 mm → rmin floored at 1.5 vox →
4.69 mm ramp; 16 % of voxels in the grayscale ramp). Single-thread, clang -O2,
Apple Silicon. Marching cubes is **pure geometry — no solve.**

| factor | grid solved | triangles | vertices | resample | MC | fine field | proc peak |
|-------:|-------------|----------:|---------:|---------:|------:|-----------:|----------:|
| 1×     | 64×24×40    |    17,456 |    8,726 |    —     | 17 ms | 0.47 MB    |           |
| 2×     | 128×48×80   |    70,196 |   35,096 |  36 ms   | 97 ms | 3.75 MB    |           |
| 4×     | 256×96×160  |   279,280 |  139,638 | 209 ms   | 510 ms| 30.0 MB    | ~100 MB   |

Triangle count scales ≈ factor² (surface area). **Memory is NOT the FEA budget:**
the 4× fine *scalar* field is 30 MB (doubles); whole-process peak stayed ~100 MB.
Contrast 128³ **FEA**, which is ~2M DOFs of vectors + operators + a solve — not
viable. Resample+MC at 4× is pure geometry and finishes in <0.8 s.

**Recommendation: default 2×.** 2× (~70 k tris) removes the terracing at trivial
cost and is comfortable for the iPad viewer and any slicer. 4× (~280 k tris on this
part; would be higher on a lace-y optimized topology) risks choking the viewer /
bloating the STL for little visible gain over 2×. The flag accepts 1–4; 3–4× is
there for a desktop slicer that wants it.

## STEP 1 — INTERPOLANT: tricubic (Catmull-Rom), justified by measurement

Both interpolants are zero-padded to match MC's background convention.

- **Trilinear** — C0 across cell boundaries. Cheap, but the gradient jump at the
  original cell walls creases the iso-surface.
- **Tricubic (Catmull-Rom / Keys a=−½)** — C1-continuous **and INTERPOLATING**: it
  passes exactly through the original samples, so the extracted surface is still the
  **0.5 level set of the input samples**, not an approximation of them. It is NOT an
  approximating spline — there is no sample-fidelity deviation to quantify. (It can
  overshoot on a ramp; measured overshoot <0.05, far from spurious 0.5 crossings —
  asserted in `test_resample`.)

Numeric comparison at **2×** on the real part:

| interp | tris | vol (mm³) | watertight | χ (genus) | **mean vtx dist to 6× smooth ref** |
|--------|-----:|----------:|:----------:|:---------:|-----------------------------------:|
| trilinear | 69,752 | 926,941 | yes | −2 (g2) | **0.0917 mm** |
| tricubic  | 70,196 | 929,552 | yes | −2 (g2) | **0.0148 mm** |

The decisive number is the last column: distance to a 6×-tricubic surface (the
near-continuous smooth iso-surface). **Tricubic-2× is ~6× closer to the true smooth
surface (0.015 mm) than trilinear-2× (0.092 mm).** The two 2× surfaces differ from
each other by 0.085 mm mean. So the crease concern is **real but sub-0.1 mm** on a
filter-smoothed field; a raw dihedral-angle mean does NOT separate them (tricubic
tracks genuine curvature, nudging its dihedral tail *up*), which is why the
distance-to-reference metric is the honest discriminator. Tricubic is the default:
guaranteed C1, sample-exact, ~6× more faithful, negligible extra cost.

## STEP 3 — MASS CONSISTENCY (the honesty guard)

**Reported mass is VOXEL-COUNT based**, not mesh volume:
`minimize_plastic.cpp: mass_grams = density_g_cm3 * (printed_voxels *
voxel_volume) / 1000`. So the readout and the exported mesh **already disagree
today**, before any resampling:

| geometry                         | volume (mm³) | mass (g) | vs readout |
|----------------------------------|-------------:|---------:|-----------:|
| reported (voxel count, printed>0.5) | 936,000  | **1160.68** | — |
| 64³ MC mesh (what's exported today) |    933,665 | 1157.75 | **+0.25 %** |
| 2× resampled mesh                |    929,552   | 1152.64  | +0.70 % |
| 4× resampled mesh                |    929,811   | 1152.97  | +0.67 % |

The voxel readout runs **~0.25 % heavy vs today's exported mesh**, widening to
**~0.7 %** once the mesh is smoothed (MC's 1× volume over-estimates the true
iso-surface by ~0.4 %; resampling converges it downward — 2× and 4× agree at
~929.6 k). This gap is **small but real and it is not mine to fix** here:
`mass_grams` lives in `minimize_plastic.cpp` (forbidden territory this task).
**Flagged, not silently shipped.** Recommendation for the maintainer: when smooth
export is turned on, either (a) compute the displayed mass from the exported mesh's
enclosed volume, or (b) state the readout is the voxel-model mass (±~1 % of the
mesh). Either is a `minimize_plastic.cpp` / app change, out of scope here.

## Correctness guards

- **(a) Same shape.** Enclosed volume within **0.44 %** of the 64³ MC surface at 2×
  and 4×; **no new components** (comps=1 throughout); **no new holes/handles** —
  Euler χ = **−2 (genus 2, the bracket's two lightening holes) at 1×, 2×, 4×, both
  interpolants**. Nothing invented or destroyed. Watertight at every factor.
- **(b) Field/optimizer/FEA untouched.** `resample_field` takes the field by const
  ref and never mutates it (asserted). The new code is only reached when
  `smooth_factor > 1`; at the default 1 the export is **byte-identical** to before
  (`marching_cubes_resampled(...,1,...)` and `resample_field(...,1,...)` are the
  identity — asserted byte-for-byte in `test_resample`). Density arrays, ladder,
  report unchanged.
- **(c)** Gate-V2 green; full core suite green (see below).

---

## What shipped

Core API (`mesh.hpp` / `mesh.cpp`), pure geometry, no new deps:
- `enum class ResampleInterp { Trilinear, Tricubic };`
- `std::vector<double> resample_field(nx,ny,nz, field, factor, interp)` —
  separable 3-pass resample, zero-padded, factor≥1 (1 = identity).
- `TriangleMesh marching_cubes_resampled(nx,ny,nz, spacing, origin, field, iso,
  factor, interp)` — resample then reuse the existing verified `marching_cubes`.

Opt-in seam (default **OFF**), CLI only:
- `JobOutput::smooth_factor` (default 1). Optional job.json key
  `output.smooth_factor` ∈ [1,4]; absent/1 keeps every existing job byte-identical.
- `run_job.cpp`: when `smooth_factor > 1`, the exported mesh is re-extracted from
  the SAME `variant.optimization.physical_density` on `solved_grid` via
  `marching_cubes_resampled(...,Tricubic)` + `keep_largest_component`. **`variant.
  v3.mesh` (the V3-gated + displayed mesh) and the JobReport are untouched** — only
  the bytes written to the STL/3MF change.

Test: `core/tests/unit/test_resample.cpp` (pure C++/std, runs in every config) —
23 checks: factor-1 identity (byte-for-byte), no-mutation, tricubic overshoot bound,
volume within 3 % + no new components + watertight at 2×/4× for both interpolants,
triangle-count growth, argument validation. Registered in CMake (`resample`).

## NOT wired (deliberately) — the app/bridge and the 083 note

- **App / bridge export is NOT wired.** The iPad app draws/exports `variant.mesh()`
  via the bridge; this task added the seam in the **CLI** path only, default OFF, so
  the maintainer sees it before it changes any product output. Wiring the bridge is
  a one-liner follow-up once approved (call `marching_cubes_resampled` where the
  bridge currently reads `v3.mesh`), on the app track (needs `build_core.sh`).
- **STEP 4 — the 083 note: NOT edited, by territory + honesty.** The note lives in
  `app/.../ResultsModel.swift:surfaceResolutionNote` — **app track, outside this
  worktree's `/core/`+bridge territory** — and while the flag is OFF and the app
  export is unwired, the app **still exports the terraced mesh**, so the current note
  ("stepping … stays in the exported STL") is **still true for the app today**.
  Rewriting it now to imply a smooth export would be dishonest. **Apply this exact
  rewrite when smooth export is turned on in the app:**

  > Solved at %.1f mm voxels. At this resolution the design's finest features are
  > limited to about 4.7 mm (the min-feature filter floor) — detail finer than that
  > cannot form regardless of tessellation. The surface faceting is a separate
  > tessellation effect, now smoothed on export; it is not the design limit. Raise
  > Detail for finer *features* (slower, more memory).

  This distinguishes **surface smoothness** (fixed here — resampling) from **design
  detail** (NOT fixed here — that is the 4.7 mm filter floor and needs finer
  *voxels*, i.e. more FEA, not more tessellation).

## Build / verify

`/core/` change → run `app/scripts/build_core.sh` to refresh the app's vendored lib
before any app build. Core: `cmake --build core/build` + `ctest`.
Measurement harness (not committed) lives in the session scratchpad
(`gen_field.cpp` builds the filtered field, `measure.cpp` prints the tables above).

> **Why the filtered field, not a full optimizer run:** a 64×24×40 penalized FEA
> solve takes ~45 s here (the known Jacobi-CG fallback stall), so 20 MMA iters is
> ~15 min. The terracing is caused by the **filter ramp**, not the optimizer's
> topology, and that ramp is identical whether the design is the optimizer's or a
> representative bracket — so the measurement applies the SAME production filter to a
> bracket design with curved lightening holes (Mnd 0.094 here vs ~0.27 on a lacier
> optimized part; the 4.69 mm ramp width — what governs terracing — is identical).
> Triangle counts scale with the exported topology's surface area, so an optimized
> lattice will have more than this solid-ish bracket; the 2× recommendation holds.
