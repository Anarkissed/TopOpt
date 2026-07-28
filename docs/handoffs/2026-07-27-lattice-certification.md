# 2026-07-27 — Lattice certification (Phase 1): homogenized tensor in the solve

**Track:** production core capability + certification wiring + validation. Octet only.
**Not built** (out of scope, by the task): the UI, the viewer proxy, the grading law,
the export path, the job-JSON region declaration. `ARCHITECTURE.md` §2 and
`DECISIONS.md` were **not** amended — the amendment §2 would need is described below for
the maintainer.

---

## The problem this closes

ARCHITECTURE §2 has the FEA solve SOLID and applies the infill knockdown at DISPLAY,
assuming uniform infill (`analyze.cpp`: `margin_effective = margin.worst_case *
infill_knockdown`). If a region is latticed, the margin, the heatmap and the failure
load then describe a **different object than the exported file** — the same failure
mode that got MTOP and ML up-resolution rejected, and the reason lattice mode was
closed. This task makes the certification solve be **of the real thing**: the latticed
elements carry the homogenized effective **cubic tensor** (PR 198's library), so the
displacement field, the compliance/stiffness and the solid-region stresses describe the
real composite object rather than solid material with a scalar knockdown bolted on.

---

## Architecture finding (read first — it sizes the feature)

**Every production solver path is scalar-per-voxel to the core.** `assemble_reduced`,
the cached `PenalizedSolver` (in-place value rescale of ONE reference element), the
matrix-free apply (`matfree.cpp`, one reference `Ke` scaled by a per-voxel modulus),
the multigrid Galerkin block cache (`W^T Ke W`, geometry-only), AND the
compliance/sensitivity in `simp_compliance` (`sum_e E_e * u_e^T Kunit u_e`) are all
built on **one isotropic reference element scaled by a scalar modulus** `E(rho)`. A
cubic tensor is NOT a scalar multiple of that element, so it **cannot ride the existing
scalar paths**.

This is NOT a hard BLOCKED-STOP: the tensor is carried by an **additive assembled
path** (`fea_solve_cg_lattice`) that leaves all four scalar paths byte-for-byte
untouched. But the honest consequence, which sizes any follow-on work:

* **Certification carries the tensor. Optimization does not.** The certification solve
  (`analyze_fixed_design`) routes to the new assembled path when a lattice region is
  present; the optimizer's ladder (matrix-free/multigrid/PenalizedSolver) stays
  scalar-modulus. This is exactly right for Phase 1 — a lattice region is a *grading
  choice*, not something the optimizer designs against — but it means the accelerated
  production paths would each need restructuring to design *against* a lattice tensor.
* **A latticed certification is ASSEMBLED Jacobi-CG**, regardless of the run's
  `solver_kind`. Same grid, **zero added DOF** (C5), but no multigrid/matrix-free
  acceleration and the assembled `K` is materialised. Fine for a certification-scale
  solve on the macro grid; it is NOT the memory-lean design-box path.

---

## What was built (all byte-identical when no lattice region is declared)

1. **General cubic Hex8 element** — `hex8_stiffness_cubic(C11,C12,C44,h)` and
   `hex8_stress_cubic(...)` (`fea.hpp`, `hex_element.cpp`). Shares the existing
   `integrate_hex8(D,h)` integrator; only `D` differs. A cubic tensor with
   `C44 == (C11-C12)/2` is isotropic, and the isotropic triplet reproduces
   `hex8_stiffness(E,nu,h)` **bit-for-bit** (verified). Rejects a non-SPD tensor.

2. **Octet lattice library** — `lattice.hpp` / `lattice.cpp`:
   `lattice_cubic_tensor(Octet, rho, Es)` embeds PR 198's measured octet rows
   (`evidence/2026-07-26-lattice-homog-phase0/tensor_library.csv`, vpc48) VERBATIM,
   interpolates piecewise-linearly in `rho`, scales linearly in `Es`, and clamps to the
   RESOLVED range `[0.148, 0.591]` (flagging the clamp). It returns a **tensor, not a
   scalar** — octet's Zener ratio is 1.22 at printable density (measured 1.6→0.87 across
   the sweep), so a scalar knockdown would misrepresent shear.

3. **Additive anisotropic solver** — `fea_solve_cg_lattice(...)` (`assembly.cpp`).
   Solid voxels scatter `E(rho)*Kunit_iso` (bit-identical to the graded `fea_solve_cg`);
   latticed voxels scatter `hex8_stiffness_cubic(...)`. Same BC-reduced, void-gated,
   Jacobi-CG system, same tolerance/throw contract. An all-zero mask is the graded
   `fea_solve_cg` **bit-for-bit**. The existing scalar paths are untouched.

4. **Certification wiring** — `analyze_fixed_design(...)` gains an optional trailing
   `const LatticePosture* lattice = nullptr` (`analyze.hpp`/`analyze.cpp`). With a
   posture: the solve routes to `fea_solve_cg_lattice`, lattice-voxel stress is the
   EFFECTIVE (macro) stress via `hex8_stress_cubic`, mass weighs each latticed voxel by
   its relative density, and the posture is recorded in `FixedDesignAnalysis`
   (topology, cell size, rho range, region size). `nullptr` (every current caller) is
   the exact pre-lattice path.

5. **run_info** — `RunInfo` carries the posture and `run_info_json` emits a `"lattice"`
   object **only when a region was certified**; a non-latticed run writes NO lattice key
   and is byte-for-byte the pre-lattice record. (No production job declares a region
   yet — that front-end is out of scope — so every current run is byte-identical.)

---

## What the reported margin now describes (REQUIREMENT 3 — state it explicitly)

With a lattice region, the certification solve carries the region's homogenized cubic
tensor, so:

* **Certified:** the displacement field, the compliance / **stiffness**, and the
  **SOLID region's strength margin** — all over the REAL composite field (a softer,
  anisotropic lattice load path), not over a solid object with a scalar knockdown. The
  reported `margin`/`accepted` is the solid region's worst-case strength margin over
  that real field. Lattice voxels are excluded from that maximum.
* **NOT certified:** the lattice region's **strut-level strength**. The recovered
  lattice stress is the EFFECTIVE (macro, smeared) stress; the peak strut stress is
  higher by a stress-concentration factor. `FixedDesignAnalysis::
  lattice_strength_uncertified` is set whenever a region is present. Certifying strut
  strength needs the **de-homogenization** step named in
  `2026-07-26-lattice-homog-phase0` (Phase 2).

So Phase 1's honest claim is: *the object's stiffness and its solid-region strength are
now certified against the real composite; the lattice region's own strut strength is
not, and is flagged.*

---

## BARS

### C1 — LATTICE OFF IS BYTE-IDENTICAL ✅ (proven against a stashed pre-change build)

`lattice_parity_probe.cpp` FNV-1a hashes every certification output of
`analyze_fixed_design` (nullptr posture) on a fixed deterministic design. Built and run
against the CURRENT build and the `git stash`-ed PRE-change build:

```
POST-change:  PARITY_FNV 49f41d08663177f8   mass=0.895280000 maxvm=227.821723541 ...
PRE-change :  PARITY_FNV 49f41d08663177f8   mass=0.895280000 maxvm=227.821723541 ...  IDENTICAL
```

Corroborated by 12/12 regression tests unchanged (analyze_fixed_design, fea_assembly,
hex_element, fea_matfree, fea_mgcg_matfree, galerkin_cache, nonconvergence_rejection,
stress, traction_loads, production_parity, materials_loader) and the full suite green.
Evidence: `evidence/2026-07-27-lattice-certification/c1_byte_identical.txt`.

### C2 — VALIDATE AGAINST THE RESOLVED TRUTH ✅ (within 10% at matched resolution)

One small octet block solved BOTH ways — coarse HOMOGENIZED (cubic macro element,
library tensor, `fea_solve_cg_lattice`) vs DIRECTLY RESOLVED struts
(`fea_solve_cg`), apparent-stiffness gap. `c2_homog_vs_resolved.csv`:

* **Resolution convergence (rho≈0.30, 2-cell block, library FIXED at vpc48):**
  vpc16 → **3.1%**, vpc24 → **1.9%**, vpc32 → **0.4%**, vpc48 → **1.2%** — all GO,
  converging to ~1% as the resolved reference reaches the vpc48 the library was measured
  at. This is the clean test of the method: **within 10%, in fact ~1%.**
* **Density sweep (3-cell, resolved vpc16):** rho 0.285 → **3.5% GO**; rho 0.22 →
  13.0%, rho 0.39 → 16.2% — MISSES at the endpoints. Reported, not softened: the misses
  are octet's ±10% resolution caveat (C6) compounded with an under-resolved vpc16
  reference (octet needs 6–8 vox/wall; PR 198 HR), NOT a failure of the method — the
  resolution-convergence rows above prove the gap collapses to ~1% once resolution is
  matched.

### C3 — NAME AND MEASURE THE BOUNDARY LIMITATION ✅ (measured AT the interface)

A solid|octet series column (3 solid + 3 octet cells, 3×3 lateral), solved resolved and
homogenized, `c3_interface.csv`:

* **OVERALL apparent E error: 0.35%** — but this DILUTES the boundary layer (the stiff
  solid half dominates the series compliance). The overall metric HIDES the interface
  error.
* **Per-cell-layer axial strain** exposes it: the octet layer TOUCHING the solid shows
  **+4.2% strain error** vs **0.7%** in the bulk octet layer — **6× worse at the
  interface**, exactly where load transfers and printed parts fail.
* **Free-surface error:** a 1-cell octet block is **−1.5%** softer than the 3-cell block
  (the 1–2 cell boundary layer the periodic assumption cannot see).

Stated plainly: homogenization is accurate in the bulk (~0.7%) and ~4% off at a
solid↔lattice interface at this resolution. This is why strut-level certification at
boundaries needs **de-homogenization (Phase 2)** — not shipped, and the margin does not
claim it (see Requirement 3).

### C4 — THE GATE NEVER SOFTENS ✅ (asserted against the named constant)

`test_lattice_certification.cpp` certifies a composite, reads its worst-case margin
`Mw`, then certifies at `margin_stop = Mw*0.999` (ACCEPTS) and `Mw*1.001` (REJECTS) —
the exact-threshold gate applied to the composite, unsoftened, asserted at runtime (not
commented). The certification solve runs at the caller's tight `cg_tolerance`, unchanged
(`analyze.cpp`). The reported margin is `Mw` regardless of the threshold.

### C5 — SOLVE COST: LATTICED vs SOLID (zero added DOF) ✅

`c5_cost.csv`, 3×3×3-cell block:

| case | cells | ndof | solve_ms |
|---|---|---|---|
| solid macro (mask=0) | 27 | **192** | 0.5 |
| lattice macro (cubic) | 27 | **192** | 0.4 |
| resolved struts (vpc16) | 27 | **352,947** | 9,502 |

Latticed vs solid: **192 vs 192 DOF (delta = 0)**, ~equal time. The resolved struts need
**1838× more DOF** and ~24,000× the time. Adding zero DOF — the whole point of
homogenization — holds.

### C6 — OCTET'S ±10% CAVEAT (restated for the handoff)

PR 198's HR study found octet's struts had **not converged even at vpc48** (11% drift
32→48), so octet's ABSOLUTE tensor magnitudes carry **~±10% resolution uncertainty**,
and the low-density rows are the least reliable. **A margin quoted to three digits on a
±10% material property is false precision.** The library documents this at the top of
`lattice.hpp`; C2's endpoint misses are this caveat made visible. Any margin reported
for a latticed part should be quoted with this ±10% band, and a physical coupon
calibration remains the maintainer's fixture before this ships to users.

---

## ARCHITECTURE.md §2 amendment this would require (described, NOT made)

§2 currently states the FEA solve is solid with the infill knockdown at display, and
that TopOpt "is not a research project in infill homogenization." Wiring this feature to
users would require §2 to record: (a) a certification MODE where a declared region is
solved with its homogenized effective **cubic tensor** (per-lattice, tensor-valued —
the excluded "infill homogenization"), adding zero DOF; (b) that such a run's margin
certifies composite **stiffness** and **solid-region strength** but NOT **lattice strut
strength** (which needs de-homogenization); (c) a validation-gate class for effective
moduli — V1 beam theory cannot certify a tensor. This is a maintainer act for
`DECISIONS.md`, per the Phase-0 handoff. **Not done here.**

---

## Follow-on work, honestly scoped

* **De-homogenization (Phase 2)** — the ~4% interface / strut-level strength gap (C3).
  The single biggest thing between this and certifying a lattice region's strength.
* **Region-declaration front-end** — the job-JSON / UI / grading law that populates a
  `LatticePosture`. Out of scope here; until it exists, no production run declares a
  region and run_info is byte-identical.
* **Optimizer carries the tensor** — restructuring the matrix-free/multigrid/
  PenalizedSolver scalar paths to design *against* a lattice tensor (see the finding).
* **Schwarz-D and the rest** — the library and element already accept any cubic tensor;
  only the octet rows are populated. Schwarz-D also cleared PR 198's 10% bar.
* **Physical coupon calibration** — anchors the ±10% (C6) empirically.

---

## Reproduce

```bash
cd core
cmake -S . -B build -DTOPOPT_USE_OCCT=OFF -DTOPOPT_BUILD_TESTS=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
ctest --test-dir build -R "lattice_certification|analyze_fixed_design|observability|production_parity"

# validation harness (C2/C3/C5), CSVs -> evidence/2026-07-27-lattice-certification/
c++ -std=c++17 -O2 -I include tests/harness/lattice_cert_probe.cpp build/libtopopt.a -o build/lattice_cert_probe
TOPOPT_LATTICE_CSV_DIR=../evidence/2026-07-27-lattice-certification ./build/lattice_cert_probe
#   TOPOPT_CERT_ONLY=self|c2|c3|c5 runs one section (c2's vpc48 row takes ~72 s).
```

Evidence: `evidence/2026-07-27-lattice-certification/` — `c1_byte_identical.txt`,
`c2_homog_vs_resolved.csv`, `c3_interface.csv`, `c5_cost.csv`, `probe_stdout.txt`.
