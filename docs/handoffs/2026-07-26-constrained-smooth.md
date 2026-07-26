# Constrained variant smoothing with re-certification — gate report + Option 3 build (2026-07-26)

Status: **Gates resolved, then Option 3 built and verified.** The two front gates
(APPETITE CHECK, BLOCKED-STOP) were resolved first with device-buildable evidence;
the maintainer chose **Option 3** — build ONLY the `analyze_fixed_design` entry
point (the re-certification engine): CLI verb + bridge shim + tests, no smoothing
UI. That is now built and its correctness bar is proven. See **IMPLEMENTATION
(Option 3)** below; the gate findings that precede it are kept for the record.

Evidence: `evidence/2026-07-26-constrained-smooth/` (appetite renders + roughness
table; `byte_identity_proof.txt`; `analyze/` CLI transcript + provenance records).

---

## TL;DR

1. **Appetite: JUSTIFIED, but not by the smoothing.** On a *current* post-projection
   variant (Heaviside + the shipped 2× tricubic export smoothing), residual
   roughness is real and visible — but the existing pipeline already removes the
   gross terracing. The differentiated value of this feature is the **receipt**
   (re-certification) and the **hard constraints** (frozen bolt circles / mating
   faces, min-feature-as-a-wall), *not* the raw smoothing delta. Cranking
   `smooth_factor` alone would buy most of the cosmetic win with none of the honesty.
2. **BLOCKED-STOP is triggered.** There is **no single-FEA-analysis entry point**
   separate from the optimization driver. Re-certification as specified ("run ONE
   FEA ANALYSIS SOLVE, not an optimization") cannot be wired without either building
   that entry point or carving through `minimize_plastic`. Per the task I am
   reporting what it would take rather than carving. Scope below.

Because a hard STOP gate fired, the build does not proceed without a maintainer
decision (see **Decision**).

---

## What was examined (device-real)

Built `topopt-cli` from this worktree (`core/build/topopt-cli`, OCCT+Eigen via
Homebrew, `TOPOPT_REQUIRE_DEPS=OFF` — lib3mf absent, so STL output). Ran the demo
L-bracket (self-weight, PLA) at **res 48**, ladder `[0.5, 0.3]`, twice:

- `smooth_factor = 1` — raw marching cubes.
- `smooth_factor = 2` — **the current shipped export** (`kSmoothExportFactor = 2`,
  `bridge.cpp:222`; `RemoteRunner.smoothExportFactor = 2`). This is what the app and
  LAN worker actually ship today.

Both runs accepted both rungs, byte-identical margins between sf1/sf2 (smoothing is
export-only, does not touch the solve).

### Residual roughness — dihedral angle across shared edges (`roughness_table.txt`)

| variant | smooth | mean | p90 | p99 | edges >30° | >45° |
|---|---|---|---|---|---|---|
| vf 0.50 | sf1 raw | 12.1° | 34.1° | 106.9° | 11.4% | 6.8% |
| vf 0.50 | **sf2 shipped** | **6.6°** | **17.6°** | **61.1°** | **4.6%** | **1.7%** |
| vf 0.30 | sf1 raw | 15.1° | 38.5° | 123.1° | 13.3% | 8.7% |
| vf 0.30 | **sf2 shipped** | **8.2°** | **20.4°** | **81.9°** | **6.2%** | **2.9%** |

The shipped export smoothing roughly **halves** mean dihedral and cuts sharp-edge
fraction ~2.5×. But a real residual survives: on the shipped output ~5–6% of edges
still exceed 30° and the worst 1% sit at 60–82°. Visually (`appetite_vf030…png`,
`appetite_vf050…png`) the shipped mesh (right panel) is cleaner than raw MC but the
thin organic tendrils and the base-plate perimeter still read as faceted /
terraced, not sculpted. This is exactly the residual that sends the maintainer to
Nomad's Smooth tool.

**Verdict:** the roughness is real enough to justify *a* smoothing feature — but the
honest case for THIS feature over "just raise `smooth_factor` to 3–4" rests on the
two things Nomad and a bigger resample both fundamentally cannot do:
- **A receipt.** Re-certify the smoothed geometry's physics.
- **Hard constraints.** Keep bolt circles circular, mating faces planar, and make
  the min-feature melt structurally impossible.

Corroborating real numbers from the shipped variant (`current_variant_report_sf2.json`):
the current output **already carries 660 (vf0.50) / 874 (vf0.30) min-feature
warnings** — sub-printable-width regions *before* any smoothing. Laplacian smoothing
(Nomad-style) provably shrinks volume and pulls nearby walls together, so it would
only manufacture more of these. The "min-feature as a constraint, not a warning"
half of the task is well-motivated by data already on screen.

---

## BLOCKED-STOP: the single-analysis entry point does not exist

Confirmed by full trace of `core/src/{cli,fea,simp,io}` and the Swift bridge:

- CLI verbs are only `run <job.json>` and `--version` (`core/src/cli/main.cpp:64`).
  `run` requires `mode == "minimize_plastic"` (`run_job.cpp:232`). No
  `analyze`/`solve`/`evaluate`.
- The Swift bridge exposes only `run_minimize_plastic` /
  `run_minimize_plastic_loadcase` (`bridge.cpp:609`, `:707`). Even
  `LoadCase.minimize_plastic == false` still runs `simp_optimize` on one rung — it is
  a single-rung optimize, **not** an analysis-only solve.
- Stress + mass + margin are computed **only inside** the optimizer's per-rung
  post-convergence recovery block (`minimize_plastic.cpp:935–1066`): one
  `simp_compliance` solve on the converged density → per-voxel `hex8_stress` →
  `von_mises_field`, `stress_tensor_field`, `displacement_field`, `mass_grams`,
  `support_overhang_voxels`, then `compute_stress_margin` (`report.cpp:402`) and the
  accept gate (`minimize_plastic.cpp:1105–1123`). This is exactly the logic
  re-certification needs — but it is welded to `simp_optimize`, never callable on an
  externally supplied fixed design.
- `fea_von_mises_field` (`assembly.cpp:843`) exists but has **no production caller**.

**What it would take (the clean route — do NOT carve through the optimizer):**
Extract the recovery/certification block into a standalone analysis entry point,
roughly:

```
AnalysisResult analyze_fixed_design(
    const VoxelGrid& G, const SimpParams& params,
    const std::vector<double>& rho,            // fixed density (binary for a re-voxelized mesh)
    const BoundaryConditions& B, const Loads& loads,
    const Material& material, Vec3 build_dir);
// -> { von_mises_field, stress_tensor_field, displacement_field,
//      mass_grams, support_volume, margin, accepted, rejection_reason }
```

- Body is a near-verbatim lift of `minimize_plastic.cpp:935–1066` (one
  `simp_compliance` at `kCertTol`, the stress loop, mass, support, margin, gate).
  The gate logic (`infill_margin_knockdown`, `margin_stop`, `load_path_connected`)
  moves with it.
- Wire it two ways: a CLI verb (`topopt-cli analyze <job.json> <mesh>`) and a bridge
  entry `analyze_mesh(...)`. Both are thin.
- Feed `rho` from the **re-voxelized smoothed mesh**: `voxelize(smoothedMesh, res)`
  (`voxelize.cpp:228`) already accepts an in-memory `TriangleMesh`, then map
  occupancy → density (1.0/0.0). This is the import-Phase-1 primitive; the only new
  glue is constructing BCs for the re-voxelized grid without a file round-trip
  (today all BC tagging comes from `import_part_file_resolved` face-tags; the
  smoothed export mesh carries no face ids — see the freeze section).
- Estimated size: one new core function (~130 lines lifted + adapted), one CLI verb,
  one bridge shim, tests. Self-contained; no optimizer changes.

This is a genuine prerequisite, not a nicety. It is the "receipt" engine.

---

## The other hard problem: "frozen means frozen" has no vertex→region map today

For S1 (bit-identical frozen vertices) the smoother must know which mesh vertices
lie on protected faces / anchor pads / keep-clear bores. Finding:

- All three primitives are keyed on a **face id**, resolved to voxels as a
  `DesignMask` (`FrozenSolid` = protect + anchor pad; `FrozenVoid` = clearance).
  Protect: `mask_step_face(... FrozenSolid ...)` (`loadcase.cpp:287`). Anchor pad:
  `loadcase.cpp:264`. Clearance: `mask_clearance_region → FrozenVoid`
  (`clearance.cpp:236`).
- **The exported/optimized/variant mesh carries no face ids and no region tags**
  (`ResultsModel.swift:1062`, `ViewerMesh.swift:241–245`). So imported `faceIDs`
  cannot be reused — the marching-cubes iso-surface vertices don't correspond to
  imported faces.
- Precedent to generalize: `check_v3` already builds a transient `vertex_frozen`
  flag by mapping each MC vertex to its ≤2 bounding voxel centres and testing
  `grid.tags == Load|Fixture` (`voxelize.cpp:535–569`). It **ignores the DesignMask**,
  so it misses Protect and Keep-clear, and it is never persisted.

**What it would take:** generalize that vertex→bounding-voxel test from `grid.tags`
to the `DesignMask` (`FrozenSolid`/`FrozenVoid`), and plumb the mask (or the exact
`StepFaceInfo`/`ClearanceGeometry` predicates) through to the smoothing stage. The
mask is the only region truth that survives to mesh-generation time. Freezing
against exact primitive geometry (cylinder/plane/slab predicates) is the more
robust option for "bolt circles stay circular" because a voxel-mask freeze is itself
quantized to the grid.

---

## Consequences for the bars, stated honestly now

- **S1 (frozen = identical):** implementable via the `check_v3` mapping generalized
  to the DesignMask, or exact-geometry predicates. Bit-identical is achievable
  because frozen vertices are simply excluded from every Taubin update.
- **S2 (no thinning below floor):** well-motivated — the shipped variant already
  flags 660/874 sub-width regions. The constraint is a per-step guard using the
  existing `min_feature_violations` detector (`voxelize.cpp:400`) run on the
  re-voxelized smoothed mesh; reject any Taubin step that raises the count.
- **S3 (re-cert can lower the verdict):** **cannot be shown on this demo.** Self-weight
  PLA margins here are 2444× / 2056× — so over-provisioned that no plausible
  smoothing moves the accept/reject verdict. Demonstrating S3 honestly requires a
  **traction load case** (real applied load), where margins live near the 1.5 stop.
  Flagging this now so S3 isn't quietly faked on the self-weight fixture.
- **S4 (volume drift vs Taubin bound):** Taubin λ|μ with μ ≈ −λ/(1−λk_PB) has a
  near-zero volume-drift bound by construction; measurable per strength setting once
  built.
- **S5 (determinism):** achievable (fixed vertex order, no RNG).
- **S6 (device-real):** a LAN worker (`TopOpt Worker.app`) is already running on this
  Mac against the main-repo CLI — the re-cert path is demonstrable on-device once the
  analysis entry point exists.

---

## Quantization footnote (task item 4), confirmed real

Re-analysis runs on the **voxelization of the smoothed mesh at the grid resolution**,
not on the printed triangles. At res 48 the L-bracket voxel is ~1.6 mm; the smoothed
surface and its voxelization differ by up to ~½ voxel. So "smoothed → re-analyzed"
margins describe the voxel proxy, not the exact printed surface. This gap must be
disclosed in the provenance tag's info, exactly as the task requires.

---

## Decision (maintainer's to make)

The appetite check passes on the merits of the *receipt + constraints*, and the
BLOCKED-STOP gate has fired. The fork:

- **A. Build the clean analysis entry point, then the feature.** ~1 bounded core
  function + CLI verb + bridge shim unlocks re-certification; then Taubin +
  freeze-mask + min-feature-constraint + UI + provenance tag. Largest, but the only
  path that delivers the "receipt" the task calls "the whole opportunity."
- **B. Stop here.** Take this report as the BLOCKED-STOP deliverable; revisit when
  there's appetite for the analysis-entry-point work.
- **C. Cosmetic-only smoothing without re-cert.** Cheapest, but it reproduces exactly
  what Nomad already does (smooth with no receipt) and violates the honesty premise.
  Not recommended.

Recommendation: **A**, but only with the S3 caveat resolved by adding a traction
fixture so re-certification is demonstrated where it can actually change a verdict —
and with the maintainer's go-ahead, since a hard STOP gate was placed here
deliberately.

---
---

# IMPLEMENTATION (Option 3)

The maintainer chose **Option 3**: build ONLY the `analyze_fixed_design` entry point
— CLI verb + bridge shim + tests — and demonstrate it re-certifying an existing
variant end to end. **No smoothing UI.** Two directives shaped it: (1) the
correctness bar — outputs must be **bit-identical** to the run's numbers when handed
that variant's own geometry; (2) freeze-mask (for the future smoothing) uses exact
cylinder/plane predicates from PR 190's `resolve_clearance_manual`, NOT a voxel-tag
map — recorded for later, not in this scope. And: no fixtures (maintainer-generated),
so S3 is reported as an owed traction fixture, not worked around.

## What was built

**1. The engine — `analyze_fixed_design`** (`core/include/topopt/analyze.hpp`,
`core/src/simp/analyze.cpp`). ONE penalized FEA solve on a FIXED density → per-voxel
von Mises / Cauchy-tensor / displacement fields, printed mass, support proxy,
interlayer tension, worst-case margin, the §7 V3 suite (min-feature count), and the
accept-gate verdict (infill-knockdown margin + connectivity belt). It never
optimizes. `infill_margin_knockdown` moved here too, so the ladder gate and a
standalone re-analysis share one definition.

**2. Single source of truth.** `minimize_plastic`'s per-rung recovery/certification
block (`minimize_plastic.cpp`, previously ~935–1111) was replaced by a call to
`analyze_fixed_design`. So the numbers a run reports and the numbers a re-analysis
reports are produced by the SAME code — byte-identity is structural, not tested-once.

**3. Re-voxelization primitive — `voxelize_onto_grid`** (`core/src/voxel/voxelize.cpp`,
declared in `voxel.hpp`). Voxelizes an edited mesh onto the SAME grid geometry a run
solved on (same voxel centres, so the run's node-indexed BCs/loads still apply). The
winding-fill core was extracted so `voxelize` and `voxelize_onto_grid` are one
implementation; `test_voxel` proves `voxelize` is byte-unchanged.

**4. CLI verb — `topopt-cli analyze <job.json> [--mesh PATH]`**
(`core/src/cli/{main,run_job}.cpp`). Builds grid/fixtures/BCs/loads from the job's
self-weight path, then ONE `analyze_fixed_design` solve on either the model as a
solid part (no `--mesh`) or a substitute mesh (`--mesh`, e.g. a smoothed variant)
re-voxelized onto the run's grid. Writes `analysis_report.json` (the NEW numbers),
`analysis.json` (provenance: `analyzed=true`, source, resolution, BOTH mass figures,
the quantization footnote), and `fields.bin`. Self-weight jobs only for now — a
declared `loads` block throws a clear "not yet supported".

**5. Bridge shim — `analyze_selfweight`** (`app/TopOptKit/.../TopOptBridge`,
declared in `TopOptBridge.hpp`). The seam a smoothing UI will call after Taubin:
imports the model, re-voxelizes an edited mesh, runs one `analyze_fixed_design`, and
returns the NEW scalars + grid metadata + re-analysed von Mises / displacement fields
(so a "smoothed – re-analyzed" overlay draws the NEW field). **No Swift caller yet**
(the UI is deferred); syntax-checked against the core headers, not built through the
Swift package (that needs a full xcframework rebuild — `build_core.sh`).

## The correctness bar — PROVEN (`evidence/.../byte_identity_proof.txt`)

- **Integration:** re-running the res-48 demo after the refactor produces
  `report.json` and `fields.bin` **byte-identical** to the pre-refactor baseline
  (sha256 `47dcec…` / `9c28a2…`, `cmp` clean).
- **Unit** (`test_analyze_fixed_design`, 22 checks, 0 failures): one
  `minimize_plastic` rung on a LOADED cantilever (real stress > 0), then
  `analyze_fixed_design` on that variant's OWN converged density reproduces von
  Mises / stress tensor / displacement / mass / support / every margin term /
  min-feature count / printed fraction / verdict with `==` (not "within tol"). Plus:
  deterministic re-run, and the gate REJECTS when `margin_stop` exceeds the measured
  margin (the gate is live, not a rubber stamp).

Regression: `voxelize, report, fields, traction_loads, simp, rmin, variants,
galerkin_cache, analyze_fixed_design, orientation, export_stl` all pass.

## Device-real (S6) — the CLI, end to end on this Mac (`evidence/.../analyze/`)

`topopt-cli analyze` on the L-bracket demo (res 48):
- **model solid:** peak 0.0216 MPa, margin 2551, ACCEPTED, voxel mass 41.44 g,
  0 min-feature violations.
- **variant mesh re-certified** (`--mesh variant_030.stl`): peak 0.0074 MPa, margin
  7406, ACCEPTED, voxel mass 10.05 g / mesh mass 7.45 g, **1085 min-feature
  violations** — the melt detector firing on the re-voxelized geometry, exactly the
  signal the constraint half of the feature is built on.

## Honest limits (stated, not worked around)

- **S3 needs a maintainer traction fixture.** Under SELF-WEIGHT, removing material
  removes load too, so a lighter variant can show a *higher* margin (7406 > 2551
  above) — smoothing cannot be shown to DROP a margin here. A verdict-lowering demo
  needs a fixed EXTERNAL (traction) load where geometry changes but load does not.
  Fixtures are maintainer-generated; this one is owed. The `analyze` CLI computes
  self-weight over the ANALYSED occupancy (the edited part's own weight) — correct
  and honest for a self-weight part, but it means analyze-vs-run numbers differ by
  load basis as well as geometry, which is another reason the S3 story is a
  traction-load story.
- **Bridge shim has no Swift caller** and is syntax-checked only — it lands with the
  deferred smoothing UI.
- **Not built:** Taubin smoothing, the frozen-vertex mask, the min-feature
  CONSTRAINT (the detector runs as a report here, not yet a hard limit on a smoother),
  and the provenance UI. All deferred with the smoothing UI per Option 3.

## When the smoothing feature IS built (recorded decisions)

- Freeze-mask = exact cylinder/plane/slab predicates from PR 190's
  `resolve_clearance_manual` geometry (survives re-meshing); do NOT generalize the
  `check_v3` voxel-tag map.
- The min-feature CONSTRAINT reuses `min_feature_violations` (already computed in
  every `analyze_fixed_design` via `v3`): reject any Taubin step that raises the count.
- Re-analysis of a smoothed MESH already works end to end via `voxelize_onto_grid` +
  `analyze_fixed_design`; the smoother just needs to feed its output mesh in.
