# Core brief for #358: per-region verdicts the app can show, and a lattice-void pre-flight

PR #354's app track, round 4 (2026-10-08). Core lines are at 23e6154e, which is the core #354 linked
when this was read. Each claim was read by one reader and checked by a second. No file under `core/` was
edited.

RULED 2026-10-08, under the maintainer's standing rule: "the app's design is the source of truth. Core
builds what the app designs. Where core can't, it says so BEFORE a run, through a check the app can
call. Never a silent substitute."

## A. One verdict per region, keyed by region, before and after a run

The reviewer's ruling 5 (2026-10-07): "The drawer's cells-across and verdict: core's count for that
algorithm. The verdict is core's to give; one source."

### What core gives today

1. **N\* is 5 for every algorithm the app sends, under either intent** (lattice.cpp:314-326).
   - The only relaxation is `aesthetic_adaptive_cells_per_member` (grading.cpp:197-229, used at
     cell_plan.cpp:129-131 and 474-476). It works per voxel, so the app's Aesthetic region floor of 2
     or 1 has no key.
2. **The count is 5.0 by construction.** Stepped (run_job.cpp:4118-4126) and Fit (1231, 1239) both pick
   the cell as max(W/5, the printable floor), so cells-across is exactly 5.0 unless the floor binds.
3. **Stepped's receipt (run_info `grading.stepped`, run_job.cpp:4951-4967; observability.cpp:1336-1355)
   carries no region id and no per-region out-of-regime flag.**
   - It skips regions that got no cell. On the only real receipt (3418E167 with a widened window) it
     has 1 row for 2 includes.
   - A refused run writes no receipt at all.
4. **Default Grade and Fixed write no per-region count.**
   - The Stage E rows (report.json `grading.regions[]`, run_job.cpp:6052-6148) are written only with
     `report_region_cells`. They are taken before the synthesis domain (6228) and the outline beam
     (6400-6446).
   - `solid_load` is inferred from the uncapped derivation (6130-6140). It is never measured; this is
     D13 in the floors brief.
5. **Fit's receipt (`grading.fit.regions[]`) is keyed by the JOB region index** (run_job.cpp:1526).
   Stage E and Stepped key by 1-based include id.
6. **Two verdicts disagree on one run.** On the same receipt:
   - Stepped's row says 5.0 cells, i.e. certified.
   - The certificate guard in report.json (`strut_strength.cells_per_member_min` / `out_of_regime`,
     run_job.cpp:3786-3791) says 2.06 cells, OUT OF REGIME.

### Asks (as ruled 2026-10-08)

- **V0 — THE FAST LAYOUT CHECK (the ruling's centre).** Core exports a check the app can call in the
  background as he edits: the app's plan plus core's own wall measurement → each region's cells across
  and ONE verdict. The drawer shows "checking…", then core's answer. Until it lands the app shows Fit's
  exact count (lattice_region_derivation), and for Stepped / Default Grade its measured estimate labelled
  "estimate, core checks it"; organic "—".
- **V1.** Add `region_id[]` and `region_out_of_regime[]` to `grading.stepped`, and a row for every
  include, including regions that got no cell, with the reason.
- **V2.** A per-region cells-across at the run's own cells in the Stage E row, and Stage E taken after
  the domain and the beam.
- **V3.** ONE per-region verdict, and it is the strength-check guard's (ruled). Core writes it on EVERY
  graded job, so the app does not add `report_region_cells`.
- **V4.** Export `fill_fit_region_cell`, `lattice_region_thinnest_extent_mm` and `run_stepped_step`
  from run_job.cpp's anonymous namespace (lines 67-7818), so the bridge can call what the run calls.
- **V5.** A key that carries the app's Aesthetic region floor, if core wants the run to count what the
  Aesthetic preview lays. Otherwise the app shows core's N\* = 5 count beside an Aesthetic cell, and
  the two will disagree.

## B. A lattice-void pre-flight: what core will refuse, before a run

The reviewer, 2026-10-07: "Item 2's sealed-cavity refusal on 102117B9 goes FIRST in the queued organic
preview task: the preview must say what core will refuse, before a run."

### The facts

- **The check is public.** It is `lattice_void_escape` plus `lattice_void_refusal`
  (lattice_void.hpp:199-208). It is a 6-connected voxel fill from the grid's boundary, and its cost is
  linear in the voxel count.
- **It runs in one place only,** inside `lattice_one_variant` (run_job.cpp:6594-6641, in the anonymous
  namespace). It runs after the grading, the trace and the rim, and before any geometry. There is no
  algorithm condition, so it applies to octet Default Grade and Stepped as well as organic. The app
  writes `require_lattice_void_reaches_exterior: true` on every lattice job.
- **The mask it tests is the run's own:**
  - for organic, the traced window minus the job's rim, with face protections as solid;
  - on the grown path, still the traced mask (organic_lattice.cpp:2161-2162, 3052).
- **The preview cannot reproduce it.** On 102117B9 the preview's inputs differ:
  - candidates 71,655 vs 66,710;
  - rim 1.705 vs 0.691 mm;
  - no keep-outs and no protections;
  - a resampled tensor.

  His refusal is 1 voxel of 59,609 (include region 31, face 27, 4.959 mm³). Checking the preview's
  own lattice could miss it or invent others.

### Ask (as ruled 2026-10-08)

The app calls the pre-flight on Save & Exit and shows core's words with the one-tap fix ("Leave Face 27
solid"). Nothing in the app claims core's verdict before then.

- **P1.** `preflight_lattice_void(job, job_dir, materials, rules)`, beside `preflight_job`
  (job.hpp:1335). It should:
  - run lattice_variant_job's own pipeline up to run_job.cpp:6641;
  - write NOTHING (no loadcase receipt, no organic_probe.json);
  - return {ran, decidable, the LatticeVoidEscapeReport, `lattice_void_refusal(report)`, the
    ungradeable reason, seconds}.

  It is exact by construction. Its cost is the run's front end: about 88 s on 102117B9 (the refused
  run, measured once).
- **P2 (optional).** Make `organic_solid_rim_band` (run_job.cpp:5220, static) public, so the
  preview's rim mirror can call it.
