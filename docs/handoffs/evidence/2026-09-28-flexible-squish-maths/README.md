# Evidence — 2026-09-28-flexible-squish-maths (C1)

Everything here was written by `harness/make_evidence.py` and `topopt-cli flexible`.
Re-create it with:

```
cmake --build build --target topopt_cli
python3 docs/handoffs/evidence/2026-09-28-flexible-squish-maths/harness/make_evidence.py --cli build/topopt-cli
```

The harness writes box STLs (triangles in the order bottom, top, −Y, +X, +Y, −X, so
the importer's pseudo-faces are 0–5 in that order; every scenario checks this from its
receipt), rasterises the `stamps.json` shapes into pressure grids (0.5 mm cells,
force spread evenly over the shape, cells summed to the stated force), writes the job,
runs the CLI, and checks the receipt.

`iacob_spot_checks.md` is `flexible_spot_table` (core's lookup against Iacob 2024
Table 2, typed from the paper): 72 of 72 values at the converted core strains (0.1147 / 0.2294), worst relative difference 2.0e-16.

## Files per scenario (`<scenario>/out/`)

| file | what |
|---|---|
| `face<id>_target_depth.svg` | what was drawn: S × deepest squish (mm). Not a prediction. |
| `face<id>_buildable_depth.svg` | what can be built (R14 heuristic): depth under the design load |
| `face<id>_density.svg` | buildable printed-core relative density |
| `face<id>_cell_size.svg` | planning cell size at that density (gyroid L = 3.0915 t/ρ) |
| `face<id>_tier_flags.svg` | per column: ok / extrapolated / too firm / too soft / beyond the data |
| `face<id>_columns.csv` | every column, every number (target, clamped, buildable, band) |
| `check_<stamp>_face<id>.svg/.csv` | the dent under a check stamp |
| `field_xz_density.svg`, `field_xz_owner.svg` | a slice of the 3D density field, and which face each voxel follows |
| `run_info.json` | provenance + the `flexible` receipt |

## The three scenarios

All numbers are after review round 1: **core strain** (the loader removes the
specimen's 1.6 mm skins from Iacob's 12.5 mm gauge length, so ε_core = ε_nominal ×
12.5 / 10.9 and the zones are ≤ 0.229 measured, ≤ 0.287 extrapolated), the blend is
one cell measured across the boundary, and the mass tiebreak weighs grams.

**(a) `a_pad_centre_soft`** — 100 × 100 × 20 mm pad, top loaded with 30 kg spread
evenly (0.0294 MPa), centre-soft on both axes (curves 0.3 → 1 → 0.3, deepest 4 mm),
varioShore at 220 °C, topology auto, springy.
Gyroid at 220 °C is the closest candidate but **not everything fits**: the 12 corner
columns (3 per corner) are drawn at 0.377 mm and even the firmest gyroid squishes
0.402 mm there (too soft). The other 9,988 columns are reachable. Honeycomb misses on
8,444 columns (its softest row squishes about 1 mm, not 4). Buildable 0.42–3.92 mm,
density 0.148–0.345, literature ±40 %. The top's other end is the bottom (face 0 /
region 100, 100 %).

**(b) `b_pad_thumb_design_palm_heel_check`** — the same pad with the thumb stamp
(20 × 26 mm ellipse, 50 N ≈ 0.12 MPa) as the design load; palm (100 N) and heel (300 N)
in check mode.
Under the thumb the core is denser (4× the pressure at the same target depth). Around
the thumb's edge one cell of smoothing cannot follow the pressure step: 128 columns
squish past the tested strain once smoothed and 108 land in the extrapolated zone
(largest smoothing change 2.3 mm), so Auto reports *nothing fits every face* and names
them. Palm: 6,056 columns pressed, max 1.50 mm, all inside the data. Heel: 3,600
pressed, **3,080 squish past the tested strain** (dark red, no number), 88
extrapolated. A pad drawn for 30 kg spread evenly does not survive a heel; the map says
so instead of inventing a depth.

**(c) `c_block_top_and_side_handover`** — 100 × 100 × 60 mm block, top loaded (30 kg,
edges soft, "either" mode, deepest 10 mm) and the +X side loaded (25 kg, centre → edge
curve 0.4 → 1, deepest 10 mm); nozzle temperature auto, damped.
Honeycomb is not eligible (face 103 is pushed from the side, R6), so gyroid; 190 °C
fails (4,224 columns), 220 and 240 both reach, and 220 wins the first tiebreak (3,008
vs 3,648 columns near a table edge; it is also the lightest: 245 g vs 273 g at 240 °C and
378 g at 190 °C, from the measured specimen densities). The side stack is 'estimated'
(±50 %); its other end is the −X face (region 105). The stacks overlap on the whole
block (600,000 mm³); each voxel follows the nearer loaded face, blended over one cell
measured across the boundary (57,588 mm³ in the band). 190 °C carries the note
"below the manufacturer's range 195-260 °C; tested by iacob2024".

**(d) `d_cube_top_and_vertical_edge_press`** (C1 addendum, angled presses, 2026-10-07)
— a 60 mm cube pressed on top (10 kg, straight down) and on its vertical +X/+Y EDGE as
one footprint of two faces, along (−1, −1, 0) (15 kg, centre → edge curve 0.5 → 1).
The edge press is a side press (90° from Z): 'estimated', gyroid only. Its other end is
the −Y and −X faces (0.51 / 0.49). The two stacks are 90° apart, so they hand over
(34,671 mm³ blended) and do not conflict. The edge press's columns run 0.7–84.7 mm
long; the 762 shorter than 12.7 mm (the footprint's rim, cutting a small corner) squish
past the tested strain, dark red on its tier map. That is geometry, not a defect.

## Byte-identity (F11/F13)

See the handoff's F11/F13 section: existing jobs run through the base binary and this
branch's binary, every output file hashed.
