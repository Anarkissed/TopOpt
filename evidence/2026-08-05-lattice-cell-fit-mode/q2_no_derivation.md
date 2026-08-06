# Q2 — where the skipped voxels went. Measured per region, not inferred.

The review asked the right question: a bare `no_derivation_voxels: 5254` against 456
latticed is exactly the shape of number that hid the overnight run's real failure for a
night. The receipt now answers it **per region**, and the answer is checkable by an
identity rather than by argument.

## What was added

`RunInfo::GradingFitRegion` gained `candidate_voxels` and `latticed_voxels` (printed
voxels whose centre lies in that declared region, and how many of them were graded to
lattice), and the run gained `grading_fit_printed_outside_regions` — printed voxels
lying in **no** declared include region. Filled by `fill_fit_region_voxels`
(`run_job.cpp:673`), which walks the printed set once using the SAME membership test and
the same first-match precedence as `fit_cell_field`, so the two cannot disagree about
which region owns a voxel. Wired at all three fit call sites (analyze `:4524`, the
lattice-variant path `:5260`, the optimize aggregate `:6745`).

The identity that decides the question:

```
no_derivation_voxels == printed_outside_regions   ⇒  every skipped voxel was OUTSIDE
```

## The measurement — his part, analyze path

★ **AT HIS OWN RESOLUTION 128** (the res-64 run that prompted the question follows, for
comparison; at 64 a 4 mm wall spans ~1.2 voxels and the instrument cannot resolve it):

```
region_voxels 46291   latticed 4414   solid_fallback 41877
no_derivation 41877   printed_outside_regions 41877
IDENTITY: True        density_raised 4414   out_of_regime_voxels 0   distinct_cells 1

  region 0: cand  238  latt  238      region 4: cand  672  latt  672
  region 1: cand  396  latt  396      region 5: cand  828  latt  828
  region 2: cand  384  latt  384      region 6: cand 1320  latt 1320
  region 3: cand  576  latt  576
  sum 4414  +  outside 41877  =  46291
```

### the resolution-64 run

```
region_voxels        5710
latticed_voxels       456
solid_fallback       5254
no_derivation        5254
printed_outside_reg  5254
IDENTITY no_derivation == printed_outside_regions: True

  region 0: extent 4 mm  cell 1.094962  candidate   18  latticed   18  out_of_regime True
  region 1: extent 4 mm  cell 1.094962  candidate   54  latticed   54  out_of_regime True
  region 2: extent 4 mm  cell 1.094962  candidate   42  latticed   42  out_of_regime True
  region 3: extent 4 mm  cell 1.094962  candidate   48  latticed   48  out_of_regime True
  region 4: extent 4 mm  cell 1.094962  candidate   84  latticed   84  out_of_regime True
  region 5: extent 4 mm  cell 1.094962  candidate  102  latticed  102  out_of_regime True
  region 6: extent 4 mm  cell 1.094962  candidate  108  latticed  108  out_of_regime True

sum of per-region candidates: 456  +  outside 5254  =  5710
```

## THE ANSWER

**Every skipped voxel was OUTSIDE every region he declared, at BOTH resolutions.** The
decomposition is exact and total: 4,414 inside + 41,877 outside = 46,291 at res 128, and
456 + 5,254 = 5,710 at res 64.

**Inside the declared regions, nothing failed.** candidates == latticed in all seven
regions, at both resolutions. There is no voxel anywhere that reached the fit path with a
declaration covering it and did not get a cell. So this is **not** a defect in this
branch's derivation.

## WHY the candidate set was the whole part here — and why that is NOT §B2

`run_job.cpp:4497`:

```cpp
grade_lattice(design_grid, density, a.von_mises_field, nullptr, gp);
```

The **analyze** path passes `nullptr` for the region mask — deliberate and pre-existing.
`analyze_job` grades the whole printed design (it has no lattice-region concept in its
own receipt), so *every* printed voxel is a candidate by construction. `fit` then
declines to invent a cell for material the user never declared, counts it, and keeps it
solid. That is the mode behaving correctly on a call site that hands it more than the
user asked about.

**The control that proves it is the call site and not the law:** the OPTIMIZE path
builds an include-scoped candidate set, and on the same geometry it reports

```
region_voxels 2302   latticed 2302   solid_fallback 0   no_derivation 0
```

Zero. Same derivation, same code, candidate set scoped to the declaration — nothing
skipped.

## ★ §B2 IS STILL LIVE, BUT IT IS A DIFFERENT MECHANISM, AND IT MUST NOT BE CONFLATED

Two distinct things can "reach past what he declared", and only one of them is here:

| | mechanism | status on this branch |
|---|---|---|
| **candidate set** — which voxels are graded | the analyze call site's `nullptr` region | NOT a leak: the extra voxels are counted as `no_derivation` and kept solid. On the optimize path the set is include-scoped and the count is 0. |
| **cell activation** — which cells the generator EMITS | whole-cell activation from any masked voxel, so an activated cell overhangs the region boundary | **STILL LIVE.** It is what put one clipped strut ~6 mm outside every region in the seam fixture, and it is why bar R5 is not met (see `s3_seam.txt` and handoff §5.4). |

So the answer to "is §B2 still live?" is **yes — at emission, not at candidacy**, and it
is reported as R5's named failure with its successor task, not buried.
