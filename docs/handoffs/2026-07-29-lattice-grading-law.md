# The lattice grading law — stress to density and cell size

**Date:** 2026-07-29
**Scope:** production feature. The front-end that turns a stress field into a
printable, certifiable lattice posture.
**Builds on:** PR 235 (cell size free in the tensor; cells-per-member is the
ceiling; bending binds at ~5 cells), PR 234 (certifiable density band), PR 220 /
lattice certification (the `LatticePosture` the engine already consumes), PR 206
(`local_member_thickness_mm`).
**Code:** `include/topopt/grading.hpp`, `src/simp/grading.cpp`; limits exposed in
`include/topopt/lattice.hpp` + `src/fea/lattice.cpp`; job block + run_info in
`job.hpp`/`job.cpp`/`observability.*`/`run_job.cpp`. Tests
`tests/unit/test_grading.cpp` (+ additions to `test_job.cpp`, `test_observability.cpp`).
Evidence harness `tests/harness/lattice_grading_probe.cpp`. Evidence
`evidence/2026-07-29-lattice-grading-law/`.

---

## TL;DR

The grading law maps a per-voxel demand (von Mises stress, or strain energy) to a
per-voxel **relative density** and **one uniform cell size**, clamped so every point
it emits is certifiable, and returns a `LatticePosture` the existing certification
engine (`analyze_fixed_design`) consumes. It **reads its limits from core** — the
density band from `lattice_rho_min/max`, the cells-per-member floor from the new
`lattice_cells_per_member_min` — so when those measurements move, the law moves with
them.

The three constraints it enforces (task requirements 1–3):

1. **Density** is clamped into `[rho_min, rho_max]` (0.14764 … 0.59093 today) —
   every emitted density is certifiable by construction.
2. **Cell size** is chosen as `max(target, printability_floor)` and then the
   **cells-per-member ceiling** is enforced per voxel: a member with
   `width / cell < floor` (5) is not latticed. The width is the real
   `local_member_thickness_mm` (PR 206).
3. **Strut diameter** is computed (`octet_strut_diameter_mm`, PR 235's B3 numbers)
   and checked against the stated minimum extrudable width — reported, never silently
   violated.

The **printability floor** and the **ceiling** together are the law's teeth: the
smallest printable cell is `min_width / phi(rho_min) ≈ 2.52 mm` at a 0.4 mm nozzle,
and the ceiling needs `floor × cell = 5 × 2.52 = 12.6 mm` of member width. **A member
thinner than that cannot be graded at any printable cell, so it stays SOLID** (bar
L4) — which is exactly PR 235's BLOCKED-STOP for this project's ~9.4 mm ribs, made
operational instead of asserted.

**Uniform cell per region** (task constraint): the law emits one cell size. The
cell-size TRANSITION (dyadic vs conformal) is deliberately NOT built — a separate
task, per the instructions.

---

## The law (grading.hpp)

`grade_lattice(grid, density, demand, region, params, iso) -> GradedField`.

- `demand` — per-voxel nonnegative demand. `demand_exponent = 1` is fully-stressed
  grading for a **stress** demand (octet strength ≈ linear in rho, so rho ∝ stress
  holds an even margin); `0.5` recovers the same grade from a strain-**energy** demand.
- Density map: `rho = rho_max · (demand / demand_max)^exp`, clamped to `[rho_lo, rho_hi]`.
  All-zero demand → a uniform `rho_min` lattice.
- Cell: `cell = max(target_cell, printability_floor)`, `printability_floor =
  min_extrudable_width / octet_strut_diameter_mm(rho_lo, 1)`.
- Per voxel: `cells_across = width / cell`; `< floor` ⇒ stays SOLID (counted in
  `solid_fallback_voxels`); else latticed with the mapped rho.
- **Bar L2 asserted before returning:** every voxel the posture marks latticed has
  `rho ∈ [rho_lo, rho_hi]` AND `width/cell ≥ floor`. A violation throws `std::logic_error`
  — the bug the bar exists to prevent can never leave the function.

The report (`GradedField`) carries the limits read from core (provenance), the chosen
cell + whether the printability floor raised it, the achieved rho band, the
region/latticed/**solid-fallback** counts, the strut-diameter range, the thinnest
latticed member's cells-per-member, and two honesty flags (`any_strut_below_min`,
`region_ungradeable`). All of it serializes to run_info's `grading` object.

---

## Limits READ from core (the ★ requirement)

- **Density band** — already exposed: `lattice_rho_min` / `lattice_rho_max`
  (`lattice.hpp`), derived from the resolved rows of the embedded octet library.
  0.14764 … 0.59093 today.
- **Cells-per-member floor** — NEW: `lattice_cells_per_member_min(topo)` returns
  **5.0**, the bending ceiling of PR 235 (error crosses 2.4 % between 4 and 5 cells
  across a member). Header tripwire says: MEASURED, being re-measured; change it in the
  one place and the grading unit test's L2 assertion catches a stale value.
- **Strut diameter** — NEW: `octet_strut_diameter_mm(rho, cell)`, PR 235's B3 vpc48
  rows verbatim; diameter is exactly linear in cell, so `d = cell · phi(rho)`. For the
  printability check only, never a solve.

None of these are hardcoded in the law. When the band widens or the ceiling drops, the
law picks it up without a rewrite.

---

## Bars

- **L1 — lattice off is byte-identical.** The `grading` job block absent ⇒
  `job.grading.present == false` and the analyze path writes no run_info, unchanged
  (`test_job` grading-absent case). The run_info serializer emits the `grading` key
  only when `grading_present`, so the observability golden is byte-for-byte the
  pre-grading record (`test_observability`).
- **L2 — never an uncertifiable point.** Asserted inside `grade_lattice` and checked
  independently in `test_grading` (including adversarial 1e18/1e-18 demand), and proven
  **end to end** in the harness: the produced posture is fed back through
  `analyze_fixed_design` and certifies (B: composite margin 0.0303, no throw).
- **L3 — report on the maintainer's bracket.** See the harness table below: density +
  cell-size field, strut diameters, cells-per-member at the thinnest member.
- **L4 — what happens when a part cannot be graded.** A member too thin for any
  printable cell to hold the floor STAYS SOLID; `solid_fallback_voxels` and
  `region_ungradeable` record it in run_info. Specimen A (the 9.4 mm bracket) is
  entirely ungradeable — the honest answer.
- **L5 — determinism.** Pure arithmetic in a fixed voxel order; `test_grading` runs the
  same input twice and asserts a byte-identical field.

---

## L3 / L4 evidence — the L-bracket (`grading_bracket.csv`, `..._stdout.txt`)

0.4 mm nozzle, octet, uniform cell. Band [0.14764, 0.59093], floor 5, printability
floor 2.519 mm (so a member needs ≥ 12.6 mm to grade at the floor cell).

| specimen | member | target→cell | latticed / fallback | rho band | strut Ø (mm) | thin member → cells/member | certify (composite vs solid) |
|:--|:--|:--|:--|:--|:--|:--|:--|
| **A — 9.4 mm bracket** | ~9.4 mm | 2.0→2.52 (floored) | **0 / 2790** | — | — | **region ungradeable (L4)** | stays solid, margin 0.075 |
| **B — thick bracket** | 16–20 mm | 2.0→2.52 (floored) | 12212 / 1868 | 0.148–0.591 | 0.400–0.956 | 14 mm → **5.56** (≥5) | **certified** 0.0303, 4.87 g vs 17.46 g |
| **C — thick, 6 mm cell** | 16–20 mm | 6.0→6.0 | **0 / 14080** | — | — | region ungradeable (L4) | stays solid, margin 0.119 |

- **A is the maintainer's real member (~9.4 mm) and it is BLOCKED-STOP.** No printable
  cell holds the 5-cell floor in a 9.4 mm rib (needs 12.6 mm), so the whole region stays
  solid. This is PR 235's finding made operational, not re-argued.
- **B grades and certifies.** 16–20 mm legs hold the floor; the surface skin (< 12.6 mm)
  falls back to solid, so a real composite (solid skin + graded core) certifies at a
  finite margin and 72 % lighter. Struts span 0.40–0.96 mm, all above the nozzle.
- **C shows the cell/coverage trade.** A 6 mm cell needs 30 mm of member; the 16–20 mm
  legs no longer qualify, so more falls back to solid. The maintainer controls this with
  the target cell; the law keeps it certifiable either way.

---

## What this is NOT

- **Not the transition builder.** Uniform cell per region only (task constraint). Dyadic
  vs conformal is a separate task (PR 235 compared them; picking one is future work).
- **Not a second certification solve in production.** The law runs on the analyze path's
  von Mises field and writes the posture + report to run_info; feeding that posture into
  a production re-certification (two-pass solve) is a deliberate follow-up. The harness
  proves the loop closes (grade → certify) so the posture is known-certifiable.
- **Strut STRENGTH is still uncertified** (Phase 2 de-homogenization) — inherited from
  the certification engine; the law grades stiffness-certifiable density, and the macro
  von Mises the composite reports is the effective, not the strut-peak, stress.

---

## Reproduce

```
cd core
cmake -S . -B build -DTOPOPT_USE_OCCT=OFF -DTOPOPT_BUILD_TESTS=ON && cmake --build build -j
./build/test_grading            # L2 / L4 / L5 + read-from-core
./build/test_job                # grading block absent => byte-identical
./build/test_observability      # grading run_info gated => byte-identical off

# L3 / L4 evidence on the bracket (standalone, not in CTest):
cmake --build build --target topopt -j
c++ -std=c++17 -O2 -I include tests/harness/lattice_grading_probe.cpp \
    build/libtopopt.a -o build/grading_probe
TOPOPT_LATTICE_CSV_DIR=<dir> ./build/grading_probe
```
