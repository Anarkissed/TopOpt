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

## Still to come here

- The Default Grade plan jobs for 570B38E2, 3418E167, 102117B9 and 68BF7B74, and the Aesthetic
  Stepped plans. They will carry `stepped_cells` and `slot_origin_mm` and come with core's verdict
  on each.
- `job_owner_core.json` from the owner-swap parity proof on 68BF7B74.
