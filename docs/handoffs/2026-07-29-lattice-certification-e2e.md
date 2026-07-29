# 2026-07-29 — Lattice certification, end to end: a real job's variant is generated AND certified as a latticed object

**Branch:** claude/lattice-certification-e2e-8f1ce8
**Status:** BUILT + PROVEN. All bars (E1–E6) met; numbers below.

---

## What this closes

PR 220 built the certification engine (a declared region carries the homogenized
octet cubic tensor in `analyze_fixed_design`). PR 231 wired octet GENERATION into the
export path (a `lattice` job emits a latticed companion mesh). **The two were never
joined.** A real job with a `lattice` block generated `variant_060_lattice.stl` but
certified only the SOLID design, so `report.json`'s margin described a **different
object than the exported file** — the exact conflation that closed lattice mode
originally (ARCHITECTURE §2, the reason MTOP/ML up-resolution were rejected).

**FIRST FINDING (the task's ★): it did NOT already work.** Proven on the unmodified
CLI at base commit `020bac0` — `evidence/.../baseline_gap.txt`:

```
report.json (accompanies BOTH variant_060.stl AND variant_060_lattice.stl):
  margin.worst_case = 5167.716045 (SOLID)         max_stress_mpa = 0.0106 (solid material)
run_info.json: lattice (certification posture) = None ; lattice_export present = True
```

The latticed mesh shipped with a solid margin. This change joins the two pieces so the
certification is **of the real composite**.

## What the reported margin now describes (bar E1 — stated explicitly)

For a lattice job, each accepted variant is **re-certified against the octet tensor**
on the SAME occupancy the exported geometry used, and the result is written as a
receipt beside the mesh (`variant_060_lattice.report.json`) and into `run_info.lattice`:

* **Certified (composite):** the displacement field, the stiffness, and the
  **SOLID-region strength margin** over the REAL composite field (a softer, anisotropic
  octet load path) — NOT a solid object with a scalar knockdown. On the deliverable the
  composite margin is **3810.73** versus the solid **5167.72**: a genuinely different,
  ~26%-lower margin because the softer interior redistributes load into the solid shell.
* **NOT certified:** the lattice region's **strut-level strength** (the recovered
  lattice stress is the effective/macro stress). `strut_strength_uncertified: true` is
  flagged on every latticed cert. Certifying strut strength needs de-homogenization
  (Phase 2). Octet tensor magnitudes carry PR 198's ±10% caveat.

**The receipt is the proof the reconstruction is faithful.** The re-certification
reconstructs the exact grid / params / loads / BCs / tolerance `minimize_plastic`
certified the SOLID design with, and runs `analyze_fixed_design` TWICE: once with a
**nullptr posture** (must reproduce the solid margin) and once with the octet posture.
The receipt records `solid_margin_reproduced == solid_margin_worst_case` →
`solid_reconstruction_exact: true` (bit-for-bit, by analyze's single-source-of-truth
contract). Because the null re-cert reproduces the solid margin exactly, the composite
margin that shares the reconstruction is trustworthy.

## Files

Changed (core):
- `include/topopt/lattice.hpp`, `src/fea/lattice.cpp` — `octet_relative_density(cell_mm,
  strut_radius_mm)`: the map from a job's PRINTED geometry to the `rho` the tensor
  library is keyed on, computed on the library's OWN basis (voxelize one octet cell of
  cylindrical struts at `kLatticeLibraryVpc=48`, solid fraction). Cell-size invariant
  (depends only on r/L). Also the typed `LatticeDensityOutOfBand` exception.
- `src/simp/analyze.cpp` — bar E5: the posture loop reads the band from core
  (`lattice_rho_min/max`) and THROWS `LatticeDensityOutOfBand` on a clamp instead of
  silently certifying against a clamped tensor.
- `src/cli/run_job.cpp` — the join: `lattice_region_for` (shared occupancy predicate
  used by BOTH the exported geometry and the certification posture, so the sliced file
  and the certified object are the same region by construction);
  `build_lattice_posture`; `certify_latticed_variant` (the two-solve re-certification,
  E4 tolerance assert); `lattice_cert_report_json` (the receipt); the lattice pre-flight
  fast-fail (design-box refusal + out-of-band refusal before any I/O);
  `finalize_lattice_run_info` (folds export + certification posture into run_info on
  BOTH the streaming and batch paths).
- `include/topopt/observability.hpp`, `src/simp/observability.cpp` — `RunInfo` gains
  `lattice_margin_worst_case / lattice_margin_effective / lattice_accepted`; serializer
  emits them inside the (conditional) `"lattice"` object.
- `tests/validation/test_lattice_certification.cpp` — sections 2b (octet_relative_density:
  in-band, cell-size invariance, monotone, degenerate throw) and 2c (E5: in-band
  certifies, below AND above band REFUSED, exception carries the band).

## Bars

**E1 — THE MARGIN DESCRIBES THE EXPORTED FILE.** `evidence/.../e2e_wired.txt`. The
receipt states it describes "the exported latticed mesh (solid shell + octet interior)
solved with the octet homogenized cubic tensor"; composite margin 3810.73 ≠ solid
5167.72; `solid_reconstruction_exact: true` proves the reconstruction. The shared
occupancy predicate (`lattice_region_for`) guarantees the certified region == the
generated region.

**E2 — LATTICE OFF IS BYTE-IDENTICAL.** `evidence/.../byte_identical.txt`, PRE
(base `020bac0`) vs POST. No-lattice job: `report.json`, `variant_060.stl`, `fields.bin`
IDENTICAL; `run_info.json` equal but `created_wall_ms`; `iterations.csv` equal but the
`wall_ms` column; NO lattice keys. Structurally, every new path is gated by
`job.lattice.present`. Lattice job PRE vs POST: the SOLID design, SOLID mesh, and
GENERATED lattice mesh (`.stl`+`.3mf`) are all IDENTICAL — the certification, receipt,
and `run_info.lattice` key are the ONLY additions.

**E3 — run_info RECORDS THE POSTURE ALONGSIDE THE CERTIFICATION.** `run_info.lattice`:
topology, cell_size_mm, rho_min/max (the certifiable band the gate enforced),
region_voxels, **margin_worst_case, margin_effective, accepted**, strength_uncertified
— beside the existing `lattice_export` geometry posture. Provenance recoverable.

**E4 — CERTIFICATION AT THE EXACT TOLERANCE, ASSERTED.** `certify_latticed_variant`
passes `options.simp.cg_tolerance` (minimize_plastic's `kCertTol`) and asserts the draft
loose tolerance is never used: `assert(!options.draft_quality || cert_tol <
options.draft_loose_tol)`. A runtime assert, not a comment.

**E5 — DENSITY BAND ENFORCED AT CERTIFICATION.** `evidence/.../band_refusal.txt` +
test 2c. Band read from core. Two layers: (1) `run_job` pre-flight refuses an
out-of-band job before any I/O (below-band r=0.30→rho 0.095 and above-band r=1.05→rho
0.667 both exit 1, no output); (2) definitively, `analyze_fixed_design` throws
`LatticeDensityOutOfBand` for any out-of-band posture rho rather than certify against a
clamped/stale tensor.

**E6 — THE ARTIFACT.** `evidence/.../out_lattice/variant_060_lattice.stl` (7.6 MB,
151,384-facet binary STL) + `.3mf` (34 MB OPC package) — a real job's latticed variant a
maintainer can slice — WITH its certification receipt `variant_060_lattice.report.json`.
`job_step_lattice.json` + `l-bracket.step` regenerate it.

## Scope / honesty

* **Self-weight load reconstruction is exact; design box is refused.** The
  re-certification reconstructs the load case at run_job level (external tractions, or
  self-weight recomputed on the solved grid). A design box would remap BCs/loads onto an
  expanded grid, which this reconstruction does not do — so `run_job` REFUSES design-box +
  lattice with a clear error rather than certify a mismatched load case. Lattice fills a
  solid interior; design-box expansion is orthogonal and out of scope.
* **This demo is coarse (res 24, 5 mm cells on a small bracket).** The E2E proves the
  PLUMBING — the margin describes the exported object, the band is enforced, provenance
  is recorded — not the physical accuracy of this particular part. Homogenization wants
  ~3–5 cells per member and octet's ±10% resolution caveat stands; a physical coupon
  calibration remains the maintainer's fixture before user ship (unchanged from PR 220).
* **Latticed cert is assembled Jacobi-CG** on the macro grid (PR 220's path), zero added
  DOF, regardless of the run's solver_kind. It doubles the per-variant cert cost (null +
  posture solve); both are cheap certification-scale solves and run only for lattice jobs.

## Follow-ups (unchanged from PR 220/231, out of scope here)

- De-homogenization (Phase 2) for strut-level strength — the one thing between this and
  certifying the lattice region's own strength.
- The grading LAW (stress → density field); the generator + certification already carry a
  per-voxel field, only the derivation is missing.
- App UI to request a lattice; the LAN worker already serves the receipt as an ordinary
  out_dir artifact (no worker change).
- Design-box + lattice (currently refused): needs the load-case remap threaded in.

## Reproduce

```bash
cd core
cmake -S . -B build -DTOPOPT_USE_OCCT=OFF -DTOPOPT_BUILD_TESTS=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
ctest --test-dir build -R "lattice_certification|analyze_fixed_design|observability|production_parity|mesh_job"

# E2E (needs OCCT for the STEP part): configure a second build with -DTOPOPT_USE_OCCT=ON
cd ../evidence/2026-07-29-lattice-certification-e2e
<occt-cli> run job_step_lattice.json    --out out_lattice     # generates + certifies
<occt-cli> run job_step_belowband.json  --out /tmp/oob        # E5: refused (exit 1)
```

Evidence: `evidence/2026-07-29-lattice-certification-e2e/` — `baseline_gap.txt`,
`e2e_wired.txt`, `byte_identical.txt`, `band_refusal.txt`, `octet_rho.txt`,
`test_lattice_certification.txt`, and `out_lattice/` (the deliverable + receipt).
