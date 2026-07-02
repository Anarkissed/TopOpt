# ARCHITECTURE.md — TopOpt (working name)

> **THIS FILE IS IMMUTABLE TO AGENTS.**
> Agents MUST read this file at the start of every run and MUST NOT modify it.
> Changes require explicit approval from the human maintainer (Nadim), recorded
> in `docs/DECISIONS.md`. Any commit touching this file without a linked
> decision entry must be rejected in review and reverted.

---

## 1. What this project is

An iPad app that takes a 3D model (STEP preferred, STL/3MF accepted), a
material choice, and either (a) user-defined loads or (b) a "minimize plastic"
directive, and produces:

1. Topology-optimized geometry variants (e.g. 70% / 50% / 30% of original
   material volume) via SIMP-based topology optimization with FDM-aware
   anisotropic material models.
2. A recommended print orientation.
3. Recommended basic slicer settings: wall count, top/bottom layers, infill %
   (rule-based heuristics derived from stress margins — NOT simulated infill).
4. Printable mesh export (3MF primary, STL secondary).

**Pipeline is STEP in → mesh out.** We do NOT convert optimized organic
geometry back to B-rep/STEP. That is out of scope permanently unless a
decision entry says otherwise.

## 2. What this project is NOT

- Not a CAD modeller. No sketching, no feature history.
- Not a slicer. We recommend settings; we do not generate G-code.
- Not a neural-network project. The optimizer is classical SIMP + FEA.
  "AI" appears only in marketing copy.
- Not a research project in infill homogenization. Settings recommendations
  are explicitly heuristic rules over FEA stress margins.

## 3. Repository layout

```
/core/                  # Platform-agnostic C++17 library. NO Apple deps.
  /include/topopt/      # Public headers (the API the app and plugins see)
  /src/
    io/                 # STEP/STL/3MF import (OCCT), 3MF/STL export
    mesh/               # Tessellation, watertight checks, marching cubes
    voxel/              # Voxelization (solid, with boundary tagging)
    fea/                # Linear elastic FEA, isotropic + transversely
                        #   isotropic (layer-direction) material models
    simp/               # SIMP optimizer (density filter, OC updater)
    orient/             # Orientation candidate generation + scoring
    settings/           # Rule engine: stress margins -> walls/infill/top-bottom
    materials/          # materials.json loader + validation
  /tests/
    unit/               # Fast tests, every module
    validation/         # Analytical benchmarks (beam theory, MBB, cantilever)
    property/           # Watertightness, connectivity, min-feature-size
    fixtures/           # Golden STEP/STL files + expected values. IMMUTABLE.
/app/                   # SwiftUI + Metal iPad shell. Thin. Human-owned.
/docs/
  ARCHITECTURE.md       # This file. Immutable to agents.
  ROADMAP.md            # Milestone checklist. Agents check boxes only.
  DECISIONS.md          # Human-approved architecture changes, append-only.
  /handoffs/            # One file per agent run: NNN-short-title.md
/ci/                    # CI scripts. Agents may extend, never weaken.
```

## 4. Technology decisions (locked)

| Concern | Decision | Notes |
|---|---|---|
| Core language | C++17 | CMake build. Compiles on Linux (CI) and macOS/iOS. |
| Geometry kernel | Open CASCADE (OCCT) ≥ 7.8 | **LGPL 2.1: must be dynamically linked.** Never statically link or vendor-modify OCCT. |
| Linear algebra / solver | Eigen (headers) + its CG solver | SimplicialLDLT acceptable for small problems; CG w/ Jacobi preconditioner for voxel FEA. |
| FEA element | 8-node hexahedral (voxel-native), linear elastic, small deformation | One element per voxel. |
| Optimizer | SIMP, penalty p=3, density filter (radius ≥ 1.5 voxels), Optimality Criteria updater | Standard Sigmund 99-line formulation, extended to 3D + anisotropy. |
| Anisotropy model | Transversely isotropic: full in-plane properties, Z-direction knocked down by material factor | Isotropic mode must remain available (resins, validation tests). |
| Export | 3MF primary (lib3mf), STL secondary | |
| App UI | SwiftUI + Metal viewer | Agents do not work in /app/ unless the task explicitly says so. |
| CI | Linux, headless, GitHub Actions | Entire /core/ must build and test with zero Apple frameworks. |

## 5. The pipeline (canonical data flow)

```
STEP/STL/3MF ──OCCT──▶ tessellated surface ──▶ watertight check
      ──▶ voxelize (solid fill, tag load/boundary voxels)
      ──▶ FEA solve (material from materials.json, orientation-dependent if FDM)
      ──▶ SIMP loop (target volume fraction; repeat per requested variant)
      ──▶ marching cubes ──▶ mesh cleanup ──▶ property checks
      ──▶ orientation scoring (per variant)
      ──▶ settings rules (per variant + material + margin)
      ──▶ 3MF/STL export + JSON report
```

Self-weight mode (`minimize_plastic`): load = gravity × density × voxel
volume, applied per solid voxel, direction = chosen print orientation's
build-plate normal. Fixture = user-tagged mounting face(s); if none given,
the largest flat face oriented downward.

## 6. materials.json (schema locked)

```json
{
  "PLA": {
    "youngs_modulus_mpa": 3500,
    "yield_strength_mpa": 55,
    "density_g_cm3": 1.24,
    "z_knockdown": 0.55,
    "poisson": 0.33,
    "family": "fdm"
  },
  "PETG":  { "...": "...", "z_knockdown": 0.70, "family": "fdm" },
  "ASA":   { "...": "...", "z_knockdown": 0.60, "family": "fdm" },
  "Resin_Standard": { "...": "...", "z_knockdown": 1.0, "family": "resin" }
}
```

Rules: every material MUST have all fields; loader MUST reject unknown or
missing fields; `z_knockdown` ∈ (0, 1]; resins use 1.0. Values are seeded
conservative and human-tuned later — agents MUST NOT change numeric values,
only the human does.

## 7. Verification spine (the actual source of truth)

Handoff notes are narrative. **Tests are facts.** A milestone is complete
when its validation tests pass in CI, not when a handoff says so.

Mandatory validation gates:

- **V1 — FEA correctness:** Cantilever and simply-supported beam under point
  and distributed load. Tip/midspan deflection within **2%** of
  Euler–Bernoulli analytical values at sufficient voxel resolution
  (convergence must be demonstrated across ≥ 3 resolutions).
- **V2 — Optimizer correctness:** 3D MBB beam and cantilever benchmarks.
  Final compliance within **5%** of the reference implementation values
  stored in `tests/fixtures/benchmarks.json`; topology visually/structurally
  equivalent (connectivity-based comparison, not pixel-perfect).
- **V3 — Property tests (every optimized output, every run):**
  - Mesh is watertight (closed, 2-manifold).
  - Exactly one connected component.
  - All load-application and fixture voxels retained at density ≥ 0.9.
  - Minimum feature size ≥ 2 voxels (proxy for nozzle-printability).
- **V4 — Self-weight sanity:** Column under gravity matches hand-calculated
  axial stress within 2%.
- **V5 — Orientation sanity:** Fixture parts in `tests/fixtures/orient/`
  (e.g. a hook) where the correct orientation is known; the scorer must rank
  it first. Tension across layer planes must be penalized by the
  `z_knockdown` factor in scoring.

## 8. Rules for agents (non-negotiable)

1. **Never edit:** `ARCHITECTURE.md`, `tests/fixtures/**`, numeric values in
   `materials.json`, existing test assertions/tolerances.
2. **Never delete, skip, `#ifdef`-out, or loosen a test.** If a test seems
   wrong, STOP, write it up in the handoff under `## Blocked`, and end the run.
3. **Tests first.** Every task starts by writing/extending tests, then
   implementation until green.
4. **One task per run.** Take the single topmost unchecked item in
   ROADMAP.md for the active milestone. Do not start the next one.
5. **All CI green before handoff.** No exceptions, no "will fix next run."
6. **Handoff must contain pasted raw test output** (the actual final summary
   lines from ctest), not a claim that tests pass.
7. **No new dependencies** beyond §4 without a `## Blocked` handoff
   requesting human approval.
8. **No speculative abstraction.** Build what the current task needs.
9. `/app/` is off-limits unless the ROADMAP task explicitly lives in M7.

## 9. Milestones (summary — detail lives in ROADMAP.md)

- **M1** — Import & voxelize: OCCT STEP/STL import, tessellation, watertight
  check, solid voxelizer with boundary tagging. Exact-volume tests on golden
  STEP fixtures.
- **M2** — FEA: hex-element linear elastic solver, isotropic. Gate: V1.
- **M3** — SIMP (isotropic): density filter, OC updater, multi-volume-fraction
  runs, marching cubes extraction. Gates: V2, V3.
- **M4** — Anisotropy & orientation: transversely isotropic FEA,
  orientation candidate generation (face-aligned + coarse sphere sampling),
  scoring (support volume proxy + stress-vs-layer alignment). Gates: V4, V5.
- **M5** — Variants & settings: N-variant pipeline, rule-based settings
  engine with margin thresholds, JSON report format.
- **M6** — Export: 3MF/STL out, report embedding, CLI driver
  (`topopt-cli run job.json`) as the canonical headless entry point.
- **M7** — iPad shell (human-led): SwiftUI, Metal viewer, force-arrow UI on
  STEP faces. Agents assist only on explicitly-scoped tasks.

## 10. Licensing constraints

- OCCT: LGPL 2.1 → **dynamic linking only**, ship license text, do not modify
  OCCT sources. lib3mf: BSD. Eigen: MPL2. All fine for a paid App Store app
  under these terms. Any new dependency needs a license check in DECISIONS.md.
