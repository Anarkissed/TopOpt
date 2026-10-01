# 00 — Decisions

**Plain language:** the "M" rows are Nadim's calls and are binding. The "R" rows are the reviewer's defaults; they stand unless Nadim overrides them. The "Q" rows are still open. Agents follow the M and R rows and must not decide a Q row themselves.

## 1. Maintainer decisions (binding)

| # | Decision | Date / source |
|---|---|---|
| M1 | **Round 1 adds eight types** to Structural and Aesthetic. Struts: Simple cubic (SC), Body-centred cubic (BCC), Face-centred cubic (FCC), Diamond, Kelvin, Rhombic dodecahedron. Sheets (TPMS): Gyroid, Schwarz-D. **BCCZ, FCCZ and Re-entrant stay unoffered**: they are stiffer along one axis, and their certification would need a new tetragonal path (Q4). | 2026-09-28 |
| M2 | Types the maintainer hasn't printed are **offered with a "Not print-tested" tag**. The tag clears when he prints a sample and marks the type tested in `core/src/materials/lattice_print_tests.json`. | 2026-09-28 |
| M3 | **PR 354 merges PR 358 one-way** (merge only, never edit core), so the app links the core that has the new types. Updates flow 358 → 354 → Flexible. | 2026-09-28 |
| M4 | Octet stays **first on the left** and stays the default. | 2026-08-14 |
| M5 | The **run's STL must look exactly like the preview**, for every type. | 2026-09-18 (core brief "preview parity") |
| M6 | **FEA certifies every user-facing result.** Aesthetic still runs the certificate; it only changes what the density means. So a type can be picked in a mode only when core can both **generate and certify** it. | DECISIONS 2026-07-10; LatticeStageMode.swift |
| M7 | Structural or Aesthetic is chosen **once**, on entering the stage. Types don't change that. | 2026-08-21 |
| M8 | "Grey out every lattice type but Octet Truss" is **lifted type by type**, as core reports each one ready (R1). | 2026-09-18 ruling, superseded by M1 |

## 2. Reviewer defaults (keep unless overridden)

| # | Default | Why |
|---|---|---|
| R1 | **Go-live gate.** A type joins `lattice_gen_topology_names()` only when every number it uses is its **own measurement**: the density ↔ strut/wall law, the diameter/thickness table, the printability floor, the bending cells-per-member floor, the percolation floor, the aesthetic hard-floor check, and the band. Octet's placeholders are forwarded in code today (`lattice.cpp` `lattice_cells_per_member_min`, `lattice_percolation_cells_per_member_min`, and the printability floor, which reads octet's diameter table for every type). They don't count. | The tensor-library-nine handoff (T4) warns that octet's floor of 5 is likely an **under-estimate** for the bending-dominated types (SC, BCC, Diamond, Kelvin). |
| R2 | **Go-live order**, least risky first: FCC → Kelvin → Rhombic → Diamond → BCC → SC, then Gyroid → Schwarz-D. One commit per type going live. | FCC is octet's own legs, and its tensor is identical to the shipped "octet" rows. Kelvin is nearly isotropic (Zener 0.68–0.89). SC (Zener as low as 0.045) and BCC (up to 34.7) are the most direction-dependent. |
| R3 | SC and BCC carry a **"strongly directional"** note in the picker and on the receipt: "best when the load runs along the cell axes". | tensor-library-nine: the certificate carries the full tensor and is correct, but the grading law's scalar E100 proxy mis-ranks off-axis members. |
| R4 | **Cell-size steps** (Doubled / Stepped) are offered for a strut type only where core proves the struts **meet across a size step** (connected-component test on a two-size block). Otherwise that type refuses them, with core's reason. | Octet and FCC keep nodes on the cell faces, so an S cell and its S/2 neighbours share them. Kelvin's and Diamond's face nodes may not line up. Measure; don't assume. |
| R5 | **Gyroid and Schwarz-D grade by wall thickness at one cell size per region.** Doubled and Stepped are not offered for them. | Every graded-TPMS paper grades thickness (Wallat 2022, Wang 2026, Kedziora 2023). No published method grades a TPMS's cell size at a fixed wall, and a period change at a boundary leaves the sheets unjoined. |
| R6 | Minimum TPMS wall = **one bead**: the same `min_extrudable_width_mm` rule struts use. | Keeps one printability rule. Justino Netto 2024 saw holes at overhangs with 1-bead PLA gyroid walls, so the print test (M2) decides whether to raise it (Q3). |
| R7 | **One TPMS field in core** (`core/include/topopt/tpms.hpp`): gyroid and Schwarz-D level sets and gradients, using **exactly** the PR 198 probe's formulas, period and phase (`core/tests/harness/lattice_homog_probe.cpp`, `gyroid_val` / `schwarzD_val`). The wall is the gradient-normalised band \|f\|/\|∇f\| ≤ t/2, so it is **one uniform thickness**. **The July tensor rows were measured on a different wall** (\|f\| < level, whose thickness varies over the sheet). So the rows must be **re-measured on the production wall** with the same probe before a sheet type goes live. Flexible's bead-walled gyroid (its C2 step) reuses this file. | "One definition" (DECISIONS 2026-09-27 item 4); the same wall rule is in `docs/design/flexibles/03-generators.md`. A uniform wall is what bead-based printing needs. Certifying one wall shape and building another is the "certified object isn't the exported object" failure this project has already paid for. |
| R8 | **Skins:** the solid outline and Rim apply to every type. Diagrid (anchored where struts meet the surface) is **strut-only**. Core reports which finishes apply to each type, and the app greys the rest with core's reason. | A sheet meets the surface along curves, not at points, so there is nothing for Diagrid to anchor to. |
| R9 | **Octet is untouched**: byte-identical outputs, receipts and tensor. Octet's legs-only tensor question stays open (Q2). | Everything already shipped rests on it. |
| R10 | The **strut-strength report** (report-only; it never gates) gets each type's own law, measured the PR 259 way. Until then it says "not measured for this type" and never shows octet's numbers. | `strut_strength.hpp` already refuses non-octet types rather than borrow octet's law. |
| R11 | **Aesthetic density ceiling** ("prints open"). Struts: the octet rule applied per type (strut diameter ≤ 20 % of the cell), each through its own diameter table. Sheets: the band maximum until ruled (Q1). | Ruling D (2026-09-18) was stated for octet. This generalises its geometry, not its number. |
| R12 | **The app draws every type from core**: struts from core's canonical cell (nodes and struts), sheets from core's field. Parity tests pin the preview to core. The Swift tables in `LatticeType.swift` become a test oracle, not a source. | M5. The Swift port carries only 7 types and no Kelvin or Rhombic. |
| R13 | **A sample block per type** via a core CLI command: a 40 mm cube, 8 mm cells, density mid-band, and a 1.5 mm solid base plate for bed adhesion. | Gives M2 a one-step way to clear the tag. The base plate answers the BCCZ adhesion finding (2026-07-29). |

## 3. Open questions (the maintainer answers; agents don't decide)

- **Q1** What does "prints open" mean for sheets? What should the Aesthetic ceiling be for Gyroid and Schwarz-D? (Default until then: the band maximum, 0.60.)
- **Q2** **Octet's certificate uses the legs-only tensor**, which is identical to FCC. The production generator builds the full octet, with braces. Full-octet rows were measured (band 0.207–0.480, `evidence/2026-07-29-tensor-library-nine/`) but never landed (tensor-library-nine finding 3). FCC is now a separate type with the same tensor as "octet", so should octet move to its own rows? That would change every octet certificate and narrow its band from 0.05–0.90. The core agent measures and reports the gap. Nothing changes until this is ruled.
- **Q3** Minimum TPMS wall under Structural: one bead or two?
- **Q4** When to build the tetragonal certification path for BCCZ, FCCZ and Re-entrant. Their constants were measured on 2026-07-29, and `hex8_stiffness_transverse` exists with no callers.
- **Q5** Display names. Defaults: "Simple cubic", "BCC", "FCC", "Diamond", "Kelvin", "Rhombic dodecahedron", "Gyroid", "Schwarz-D".

## 4. Collisions with ARCHITECTURE.md / DECISIONS.md

- **DECISIONS 2026-09-27 item 5** keeps Flexible's generators out of the Structural/Aesthetic picker "without a separate maintainer decision". This round is that decision **for the gyroid field only**: Gyroid enters Structural/Aesthetic as a certified sheet lattice. Honeycomb stays Flexible-only.
- **Territory lock (2026-07-11)**: agents edit only their own territory. M3 is a **merge**, not an edit. The app agent never changes a core file, and a merge conflict in core stops it.
- Nothing else collides. FEA certification (M6) is unchanged, and so are ARCHITECTURE §2 and §4.

## 5. The DECISIONS.md entry (maintainer appends; it has force only once it's in docs/DECISIONS.md)

```
- 2026-09-28: LATTICE TYPES ROUND 1 (maintainer).
  1. Structural and Aesthetic gain eight lattice types: strut SC, BCC, FCC, Diamond,
     Kelvin, Rhombic dodecahedron; sheet (TPMS) Gyroid and Schwarz-D. BCCZ, FCCZ and
     Re-entrant stay generate-but-not-certify and are not offered.
  2. A type is offered in a mode only when core reports it both generatable and
     certifiable (the 2026-07-10 certification rule is unchanged; Aesthetic still
     certifies). A type goes live only when every number it uses is its own
     measurement - no octet placeholder (docs/design/lattice-types/00-decisions.md R1).
  3. Print status is maintainer data: core/src/materials/lattice_print_tests.json.
     Types not marked tested are offered with a "Not print-tested" tag. Agents never
     edit the file.
  4. One definition: every type's geometry, density law, floors and ceilings live in
     /core/; the app draws from core through the bridge. The run's STL must match the
     preview for every type (2026-09-18 ruling).
  5. One TPMS field in core (topopt/tpms.hpp), shared with the Flexible stage. This
     amends 2026-09-27 item 5 for the gyroid field only: Gyroid enters Structural and
     Aesthetic as a certified sheet lattice. Honeycomb stays Flexible-only.
  6. Gyroid and Schwarz-D grade by wall thickness at one cell size per region; Doubled
     and Stepped are not offered for them until a transition method is measured.
  7. PR 354 (app) merges PR 358 (core) one-way - merge only, never edit core - so the
     app links the core it ships with. Updates flow 358 -> 354 -> Flexible.
  8. Octet is unchanged (outputs, receipts, tensor). Whether octet moves from the
     legs-only rows to its own full-octet rows is an open maintainer question.
  9. Reference pack: docs/design/lattice-types/ (maintainer-committed).
```
