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

## Still to come here

- The Default Grade plan jobs for 570B38E2, 3418E167, 102117B9 and 68BF7B74, and the Aesthetic
  Stepped plans. They will carry `stepped_cells` and `slot_origin_mm` and come with core's verdict
  on each.
- The owner swap's parity proof on 68BF7B74 is in `owner-68BF7B74/`. Its plan job comes from the
  Aesthetic Stepped plan proof, not from that proof (see its README).
