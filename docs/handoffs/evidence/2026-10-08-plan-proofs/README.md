# Plan proofs and job documents for #358 (round 5, 2026-10-08)

The reviewer's rulings of 2026-10-08 (approved by the maintainer):
- "Dump the plans as job documents into evidence on the branch, for #358's pass-count gate."
- "Put 102117B9's organic one-size job document (4 mm) in evidence with the plan dumps. #358 needs
  it to prove the 27,448 of 71,655 voxels."

His projects are used for testing with his permission. His CAD models are NOT committed. Each job
names its model, and the model's SHA-256 is given so #358 can check it has the same file.

## organic-102117B9-onesize-4mm/

- `job.json` is the stage job the app writes today for 102117B9 ("M2 verticalStand"). It was taken
  from a fresh copy of snapshot S1-2026-10-02, set to Manual one size 4 mm with the simulation off,
  the way the wizard's Manual pill does it (`OrganicOneSizePreviewVsRunProbe`).
  - SHA-256 starts `cb0665d87ffbee40`.
  - Core's parser accepts it.
  - Grading: organic, swept 4–4 mm, structural intent, beam_network, strut 0.9 mm, bead 0.45 mm,
    shape fit on, growth on.
  - The rim is `organic_solid_rim_mm` 1.705 mm, the item-2 floor (the round-3 job carried 0.691).
  - It has 177 include face regions.
  - Its model is `model.step`, SHA-256 starts `bdf5646481e370ba`.
- `preview_probe.txt` holds the probe's summary lines from the same run, at app commit 9c934d2e
  (core 36f5fdde):
  - ONESIZE-PREVIEW-REGIONS: 177 includes, **71,655 planned voxels**.
  - ONESIZE-PREVIEW-SUMMARY: "shape band 6.0 mm: **27448 voxels graded** toward the 1.71 mm floor".
    The band is 6 mm wide at strength 1.00 (the project's own setting).
  - The trace grid is 1.705 mm (128×32×118), resampled ×2 from the 3.411 mm solve.

The band's rule, in terms core can evaluate, is the 2026-10-08 answer on the #354 channel.

## Core findings this round (for #358; no file under core/ was edited)

1. **An invalid include shifts every later region id.** `lattice_role_regions_from_job` skips a
   geometry `resolve_clearance_manual` calls invalid (run_job.cpp:1019, `if (!g.valid) continue;`).
   - The run's include list is then shorter than the job's.
   - Every later include's 1-based id (the plan's `region_id`, `stepped_region_owner`'s answer, the
     receipts' keys) names the NEXT region.
   - The app numbers includes in job order without that skip.
   - The owner bridge (`stepped_region_owners`) returns core's include count, and the bake refuses a
     reply whose count differs from the job's. The ask: refuse the job, or keep the slot, rather
     than skip.
2. **The published beam-network set disagrees with the run.** At 36f5fdde
   `lattice_beam_network_certified_algorithms()` returns {"stepped", "organic"} ("in ANY
   configuration"). The run routes `certify_organic_structural` only for organic + structural
   (run_job.cpp:7581), and refuses a Structural Stepped plan without the key (5161-5183). The app
   keeps its own {"organic"} and blocks Structural Stepped until the run routes it (K8).

## The plan proofs (core 36f5fdde, frozen CLI `sync-36f5fdde`; app at 6c9eb0d6 and after)

`tools/run_all.sh` drives the arms. Each arm is a fresh copy of snapshot S1-2026-10-02 (converted
copies are labelled). Each arm produces:
- the app's own bake and jobs (`LatticeDefaultGradePlanProof`);
- the frozen CLI on job_noplan, job_plan and job_plan_spans (and job_plan_k2 where the app withholds
  the plan);
- `compare_plan_spans.py` on what core shipped.

### 570B38E2, Default Grade (his project, unconverted): CORE ACCEPTS THE PLAN

- The plan: 4,198 cells over 2 regions. Both regions carry `slot_origin_mm`.
- Core's histogram (stderr) equals the preview's, byte for byte, in 4 passes:
  `[stepped] doubled (halves) plan: 4198 cell(s) over 2 region(s) in 4 pass(es) | 6.02=125 5.16=543 3.01=2479 2.58=1051`.
- Verdict: ACCEPTED for job_plan, job_noplan and job_plan_spans (exit 0).
- **Cell for cell, from what ships** (the spans arm): all 133,308 shipped struts lie in plan cells
  (0 foreign).
  - 4,188 of the 4,198 plan cells got struts. Per size: 6.02 125/125, 5.16 543/543,
    3.01 2478/2479, 2.58 1042/1051.
  - **The 10 cells that got none are all outline cut cells.** Their centres lie 0.84–1.49 mm
    OUTSIDE the region outline (9 in region 1's face layer, 1 in region 2). The preview paints the
    part of such a cell inside the outline; core lays no strut in it. A mismatch to rule on: the
    plan drops cells whose centre is outside the outline, or core lays their struts clipped.
- **From the receipt: NOT the plan.** run_info's grading and the variant report are IDENTICAL with
  and without the plan: core's own law layout, cell_mm 12, 7 cells, 148 latticed voxels,
  547.64 g, effective margin 140.3. Yet the plan run's STL is 191 MB and the no-plan run's 2.1 MB.
  The plan is laid, but the certificate and the receipt describe the 7-cell law layout. That is
  K3 (plan-driven mask and certification) and K4 (the laid plan in run_info). Until both land,
  "core lays exactly the preview" holds only for the STL.

### 3418E167, Default Grade (converted): REFUSED, the same with and without the plan

Core's words (job_plan, job_noplan and job_plan_spans alike):
> "lattice_variant: no lattice remains to emit, so there is nothing to certify or print -- refusing
> rather than writing a file with zero struts in it and calling it a lattice. The grading law
> latticed 4 of this variant's 63657 candidate voxels, and then the outline beam turned 4 voxel(s)
> solid -- every one that was left. … The law's own fallbacks over the voxels it rejected:
> member_too_thin_for_cell=179, strut_unprintable_at_every_cell=63474,
> irrecoverable_by_any_cell_size=179."

The app's plan has 2,636 cells over 2 regions (12.00=5 6.00=179 4.67=914 3.00=1538), with both
regions' slot origins. Core's law mask empties the region before the plan is read. This is K3: on a
plan job, the plan is the design.

### 102117B9 and 68BF7B74, Default Grade (converted): the app WITHHOLDS the plan (K2)

- 102117B9: 22,344 cells over 177 regions. Region 19's face is tilted: the bake's grid stands
  −45.74 mm along its normal from its plane.
- 68BF7B74: 11,120 cells over 5 regions. Region 3's face is tilted: +13.26 mm.

Core refuses a slot origin off the face plane (job.cpp:1592-1611), so the app sends no plan and
says why. For K2, `job_plan_k2.json` is the job the app would send once slot_origin_mm is a grid
phase. It stamps every planned region with the bake's grid point (19 regions on 102117B9, 5 on
68BF7B74). At 36f5fdde core refuses it at parse, as expected:
> "job.json: lattice region 19 (face 27): a face lattice region's "slot_origin_mm" must lie IN the
> face plane, and this one stands -45.739777 mm along the region normal from "origin". …"

(68BF7B74: region 3, face 23, +13.264125 mm.)
- The no-plan jobs: 68BF7B74 is ACCEPTED (core's own layout).
- 102117B9 is REFUSED by the law mask (K3), with or without a plan:
> "the grading law could lattice NONE of this variant's 66710 candidate voxels … Reasons:
> member_too_thin_for_cell=6, strut_unprintable_at_every_cell=66704, irrecoverable_by_any_cell_size=6."

### Aesthetic Stepped (any-step plans, behind `anyStepPlansForTests`)

- **68BF7B74 (his, unconverted).** 9,865 cells over 5 regions
  (12.07=5 8.05=21 7.73=18 6.87=7 6.04=45 5.16=789 4.02=568 4.01=2505 3.44=293 2.58=5614).
  - WITHHELD by the app: region 3 (face 23) is tilted, +13.26 mm off its plane (K2).
  - `job_plan_k2.json` is refused at parse, as above. The no-plan job is ACCEPTED.
- **3418E167 (converted to Aesthetic).** 2,902 cells over 2 regions
  (6.00=237 4.67=683 3.50=387 3.00=1595), sent with both regions' slot origins.
  - REFUSED by core's menu:
    > "lattice "stepped_cells": stepped cell 0 in region 1 is 3.5 mm, which is not on that region's
    > menu (base 8.756 mm at a 0.45 mm bead admits 4 size(s), largest 8.756, finest 2.919). Core
    > validates the plan and does not repack it -- the run lays down the arrangement the preview
    > showed, or it stops here."
  - The app's region-1 base is 7 mm (4.67 = 2/3·7, 3.5 = 7/2). Core builds the any-step menu on its
    OWN base for the region (8.756 mm, its FEA cell). This is K1: the any-step base comes from the
    app's plan.
  - The no-plan job is ACCEPTED.

### Where the proofs stand

| arm | the app | core at 36f5fdde | waits on |
|---|---|---|---|
| 570B38E2 Default Grade | sends 4,198 cells | ACCEPTS; histogram equal; 4,188/4,198 cells laid; receipt is the law's | the 10 cut cells (a ruling), K3, K4 |
| 3418E167 Default Grade | sends 2,636 cells | refuses: the law mask lattices 4 voxels | K3 |
| 102117B9 Default Grade | withholds (region 19, −45.7 mm) | refuses the K2 job at parse; the law mask refuses the job | K2, K3 |
| 68BF7B74 Default Grade | withholds (region 3, +13.3 mm) | refuses the K2 job at parse | K2 |
| 68BF7B74 Aesthetic Stepped | withholds (region 3) | refuses the K2 job at parse | K2 |
| 3418E167 Aesthetic Stepped | sends 2,902 cells | refuses: 3.5 mm not on core's menu (core's base 8.756) | K1 |

The production switch stays OFF. No arm passes "core accepts it and lays exactly the preview, cell
for cell from the receipt and STL".

Each arm's folder in `plans/` holds:
- `summary.txt`: the harness lines, every CLI verdict and refusal verbatim, and the cell-for-cell
  counts;
- the jobs, compacted: `job_noplan.json`; `job_plan.json` only where a plan was sent;
  `job_plan_k2.json` where the app withheld it.

`job_plan_spans.json` is `job_plan.json` with `lattice.emit_welded_stl` and
`lattice.emit_organic_spans` set true. These jobs are #358's documents for the pass-count gate.

The owner swap's parity proof on 68BF7B74 is in `owner-68BF7B74/`.
