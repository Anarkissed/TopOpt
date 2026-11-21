# Item 2: organic one size, preview against run, on his 102117B9

The reviewer, 2026-10-05: "measure preview vs run as planned and list every gap with numbers. The
fixes join the queued organic preview task, not this round."

## How it was measured

- **The project.** A fresh copy of 102117B9 ("M2 verticalStand", organic, 177 include regions, his
  stated strut 0.9 mm, printer bead 0.45 mm) from snapshot S1-2026-10-02.
- **The setting.** Each copy was set to Manual, one size, with the simulation off, the way the
  wizard's Manual pill does it, at 4 mm and at 6 mm.
- **The preview.** `OrganicOneSizePreviewVsRunProbe` (afe81c65) wrote the stage job. Core's parser
  accepts it as swept with `cell_min_mm` = `cell_max_mm` = the size (ruling 5). The probe then baked
  the preview exactly as `WorkspacePlaceholder` assembles it.
- **The run.** The frozen CLI (core 436819f6) ran `lattice-variant` on that same job.

## His job is refused by core at both sizes

> "the void space inside this lattice does not reach the exterior. 1 of 7918 lattice cells (1 of
> 59609 latticed voxels) sit in 1 SEALED cavity … 4.959 mm^3 … declared include region 31."

At 6 mm the count is 1 of 3232 cells. The full text is in `run_s*_his_job_refused.txt`. The app
writes `require_lattice_void_reaches_exterior: true`, so the run exports nothing (88 s).

The preview draws the whole lattice and says nothing about it. **That is gap 0.**

## The counterfactual

To compare the geometry anyway, a labelled COUNTERFACTUAL ran: his job with only that key set to
false. It took 46 min at 4 mm and 38 min at 6 mm. Its run_info is in `run_s*_organic.json`.

## The gaps, with numbers

| # | Quantity | 4 mm preview | 4 mm run | 6 mm preview | 6 mm run |
|---|---|---|---|---|---|
| 0 | Exported? | drawn | **refused** (sealed voxel) | drawn | **refused** |
| 1 | Total strut length | 211,935 mm | 121,897 mm | 197,417 mm | 140,387 mm |
| 2 | Curves | 25,709 | 2,976 | 24,925 | 1,280 |
| 2 | Connectors | 153,595 | 14,755 | 136,004 | 4,738 |
| 3 | Spacing | 1.71–4.00 mm (drawn window) | achieved 2.00–8.72, median 3.47 | 1.71–6.00 mm | achieved 3.00–10.62, median 5.17 |
| 4 | Shape fit | 24,787 voxels shrunk, min ratio 0.50 | **0** shrunk (ratio 1) | 40,207 shrunk, 0.50 | **0** |
| 5 | 6 mm shape band | 27,448 voxels graded toward 1.71 mm | none (no organic job carries a band) | 27,448 voxels | none |
| 6 | Solid rim | 1.705 mm, 13,248 voxels | 0.691 mm, 7,093 voxels | 1.705 mm, 13,248 | 0.691 mm, 7,093 |
| 7 | Strut diameter | 0.900 everywhere | 0.900 everywhere (radius 0.45) | 0.900 | 0.900 |
| 8 | Lattice voxels | 71,655 planned | 66,631 latticed of 66,710 | 71,655 | 66,638 |
| 9 | Time | 458 s preview bake | 2,789 s run | 465 s | 2,265 s |

## What each gap is

- **0. The cavity check.** The run's verdict never reaches the preview: a lattice that cannot be
  exported looks the same as one that can.
- **1–3. The spacing the preview draws is not the run's.** The preview's curve count barely moves
  from 4 mm to 6 mm (25.7 k → 24.9 k); the run's falls by more than half (3.0 k → 1.3 k). The causes
  are gaps 4 and 5.
- **4. Shape fit.** In core, the shape fit is inert when the window's two ends are equal: its floor is
  `cell_min_mm`, which is the size itself. The preview shrinks to half the size, ratio 0.50.
- **5. The band.** The 6 mm band is drawn by the preview only.
- **6. The rim.** The job sends `organic_solid_rim_mm` = 0.691 mm, the bead floor 0.5·w·√(3π). The
  preview draws max(that, one solve voxel) = 1.705 mm, twice as many rim voxels.
- **7. Strut.** It matches, because he states 0.9 mm. With no stated strut the run grades it and the
  preview draws the bead (read from the code, not measured here).
- **9. Time.** The run is 5–6× the preview.

None of these was fixed this round, as ruled.
