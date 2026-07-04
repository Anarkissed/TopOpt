# ROADMAP.md — Task checklist

> Agents: take the **topmost unchecked task** in the active milestone. One
> task per run. Check the box only when all CI is green. Do not reorder,
> reword, add, or remove tasks — if a task is wrong or too big, write a
> `## Blocked` handoff and stop.
>
> Active milestone: **M1**

## M1 — Import & voxelize

- [x] M1.1 Repo scaffold: CMake project, `core/` layout per ARCHITECTURE §3,
      CI workflow that builds and runs an empty ctest suite on Linux with
      OCCT + Eigen + lib3mf installed. Green pipeline is the deliverable.
- [x] M1.2 `materials/` loader: parse materials.json, strict schema
      validation per ARCHITECTURE §6, reject bad files. Unit tests incl.
      malformed inputs.
- [x] M1.2b Add loader tests: duplicate top-level material name rejected;
      on-disk load of the committed core/src/materials/materials.json succeeds.
- [x] M1.3 STL import + watertight/manifold check. Fixtures: golden cube,
      sphere, and a deliberately broken (open) mesh that must be rejected
      with a diagnostic.
- [ ] M1.4 STEP import via OCCT + tessellation with controllable deflection.
      Fixtures: STEP cube (volume exact to 1e-6 relative), cylinder
      (volume within 0.1% at fine deflection, convergence shown at 3
      deflection values).
- [ ] M1.5 Solid voxelizer: surface mesh → filled voxel grid at resolution N.
      Tests: cube voxel count exact; sphere volume within 2% at 128³;
      grid stores per-voxel tags (interior / surface / user-tagged).
- [ ] M1.6 Face tagging: given a STEP face ID, tag its voxels as
      LOAD or FIXTURE. Test: cube fixture — tag one face, assert tagged
      voxel set is exactly the expected slab.

## M2 — FEA (isotropic)

- [ ] M2.1 Hex element: 8-node stiffness matrix for given E, ν. Test against
      known reference matrix values.
- [ ] M2.2 Global assembly + Dirichlet BCs + point/distributed loads on
      tagged voxels. Small hand-checkable 2×1×1 problem solved exactly.
- [ ] M2.3 CG solver w/ Jacobi preconditioner over Eigen; converges on
      64³ problems in CI time budget (< 5 min).
- [ ] M2.4 **Gate V1**: cantilever + simply-supported beam vs Euler–Bernoulli,
      ≤ 2% error, convergence across 3 resolutions. Von Mises stress field
      output added.

## M3 — SIMP (isotropic)

- [ ] M3.1 Density field + SIMP-penalized stiffness (p=3), compliance +
      sensitivities. Finite-difference check of sensitivities on a tiny grid.
- [ ] M3.2 Density filter (radius ≥ 1.5 voxels) + Optimality Criteria update.
      2D-equivalent slice reproduces the classic 99-line MBB result pattern.
- [ ] M3.3 Full 3D loop with volume-fraction target + convergence criteria.
      **Gate V2** on 3D MBB + cantilever vs fixtures/benchmarks.json.
- [ ] M3.4 Marching cubes on final density (threshold 0.5) + cleanup.
      **Gate V3** property suite wired to run on every optimizer output in
      all future tests.
- [ ] M3.5 Multi-variant runner: one job → volume fractions [0.7, 0.5, 0.3]
      → three meshes + per-variant compliance report.

## M4 — Anisotropy & orientation

- [ ] M4.1 Transversely isotropic hex element (z_knockdown on the layer
      normal axis). Isotropic mode preserved; V1 must still pass in
      isotropic mode.
- [ ] M4.2 Self-weight loading mode (gravity × density × voxel volume).
      **Gate V4** column test.
- [ ] M4.3 Orientation candidates: 6 axis-aligned + face-normal-aligned +
      coarse sphere sampling (≤ 26 dirs). Support-volume proxy metric
      (overhang voxel count > 45°).
- [ ] M4.4 Orientation scoring: combine support proxy + max tensile stress
      across layer planes (knocked down). **Gate V5** hook fixture ranks
      correct orientation first.

## M5 — Variants & settings

- [ ] M5.1 Settings rule engine: inputs = material, worst-case stress margin,
      part size; outputs = walls, top/bottom layers, infill % + pattern name.
      Rules table lives in `settings/rules.json` (human-tunable). Unit tests
      per rule boundary.
- [ ] M5.2 Job report: single JSON per run — variants, volume saved, max
      stress, margin, orientation, settings. Schema-validated in tests.
- [ ] M5.3 `minimize_plastic` end-to-end: self-weight + auto volume-fraction
      ladder, stopping when margin < 1.5. Integration test on bracket
      fixture.

## M6 — Export & CLI

- [ ] M6.1 3MF export (lib3mf) + STL export. Round-trip: export → re-import →
      V3 properties hold, volume within 0.5%.
- [ ] M6.2 `topopt-cli run job.json`: the canonical headless entry point
      driving the full pipeline. Integration test = the demo job checked
      into fixtures.

## M7 — iPad shell (human-led; agent tasks added ad hoc by Nadim)

- [ ] M7.x — defined later, one at a time, explicitly.
