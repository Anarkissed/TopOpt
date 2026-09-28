# Flexible stage — reference pack

**Plain language:** everything a coding agent needs to know to build TopOpt's Flexible ("Squish") lattice stage honestly: what Nadim has decided, how the squish prediction works, how the lattice is built, what to print and test, and every source behind the numbers. Drafted by the reviewer (Claude) on 2026-09-27 from two research runs and the design discussion of 2026-09-26/27. **Committed by the maintainer.**

## Read in this order

| File | What it is |
|---|---|
| `00-decisions.md` | Maintainer decisions (binding), reviewer defaults (keep unless overridden), open questions, **collisions with ARCHITECTURE.md**, and the draft DECISIONS.md entry. |
| `01-product-spec.md` | The user's flow, Auto recommender rules, honesty rules, out-of-scope list. |
| `02-squish-model.md` | The measured-curve squish model: interpolation, inversion, spring-bed solve, error bands, what isn't modelled. |
| `03-generators.md` | Gyroid and honeycomb geometry: bead-sized walls, grading, skins, printability, mesh-size budget, isolation from existing stages. |
| `04-print-settings.md` | Bambu Studio settings, foaming-filament rules, per-layer temperature/flow, the G-code decision. |
| `05-coupon-protocol.md` | The DIY rig, the calibration coupons, the test method, the raw-data format. |
| `06-references.md` | Every source with its URL and specific finding. |
| `07-roadmap.md` | Build order: C1 → (C2 ∥ A1) → A2 → C3 … → v2. |

## Data (`data/`)

| File | Contents | Status |
|---|---|---|
| `flexible_materials.seed.json` | Filament catalogue: temperatures, flow, drying, AMS, data tier, error-band defaults. `null` = unknown. | Seed. Maintainer copies it to `core/src/materials/flexible_materials.json` before C1. |
| `iacob2024_curves.json` | The 36 literature squish entries in the curve-table schema. | Maintainer copies it to `core/src/materials/flexible_curves/iacob2024_curves.json` before C1. |
| `curve_table.schema.json` | Schema shared by literature and calibrated curves. | |
| `iacob2024_varioshore_secant_moduli.csv` | The same 36 rows, human-readable. Includes stresses, **± SD**, **specimen density (all rows, before and 2 months after)**, print time, and the reviewer's estimate of printed core density at 190 °C. | Checked value-for-value against the paper's Table 2 (0 mismatches). Strictly increasing in infill at every temperature, pattern and strain. |
| `foaming_temperature_tables.csv` | Temperature → hardness → flow points for every foaming filament found, conflicts flagged. | |
| `printed_tpu_solid_properties.csv` | Solid printed-TPU properties (TDS vs independent). | |
| `hyperelastic_constants_printed_tpu.csv` | Mooney–Rivlin / Ogden constants for printed TPU (reference; the v1 model doesn't use them). | |
| `elastomer_lattice_studies.csv` | Every elastomer lattice study found, with its finding and whether it's extractable. | |
| `coupon_sets.json` | Calibration coupon definitions (sets A, B, S, SW; C and D deferred). | Seed for the C3 coupon exporter. |
| `stamps.json` | Built-in stamps (fingertip, thumb, four fingers, palm, fist, heel, knee, elbow, flat plate, IFD foot) and import rules. | Typical adult sizes, reviewer-set; the user scales them. For the app (A1). |
| `v2_insoles_out_of_scope/insole_priors.csv` | Plantar-pressure priors for the v2 insole add-on. | **Do not build.** |

## Papers (`papers/` at the repo root)

The maintainer supplied the full PDFs of the five papers this pack leans on hardest:
- Iacob 2024 (the squish table);
- Justino Netto 2024 (cell size vs wall thickness, i.e. the 2-bead question);
- Wang 2026 (load-path graded gyroid);
- Wallat 2022 (gyroid gradient functions);
- Kedziora 2023 (graded shell-lattice infill).

All five were read in full on 2026-09-27. Their findings are in `06-references.md` §A–B, and the files are named by DOI/pii. All five are open access; four are CC BY and Justino Netto 2024 is CC BY-NC.

## Live copies

The filament file and the curve table are also placed at `core/src/materials/flexible_materials.json` and `core/src/materials/flexible_curves/iacob2024_curves.json`. **Those core copies are the live data** the code loads. The seeds here are reference drafts; if a value changes, change the core copy, as maintainer data.

## Rules for agents

- **Numbers in `data/` are maintainer data.** Same rule as `materials.json`, `settings/rules.json` and fixtures: never change a value. Propose changes under `## Blocked`.
- **`null` means unknown.** Never replace it with an estimate.
- Where this pack and `DECISIONS.md` disagree, **DECISIONS.md wins**. Where either disagrees with `ARCHITECTURE.md`, stop and report.
- The draft DECISIONS entry in `00-decisions.md` has **no force** until it appears in `docs/DECISIONS.md`.
