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
Table 2, typed from the paper): 72 of 72 values, worst relative difference 2.7e-16.

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

**(a) `a_pad_centre_soft`** — 100 × 100 × 20 mm pad, top loaded with 30 kg spread
evenly (0.0294 MPa), centre-soft on both axes (curves 0.3 → 1 → 0.3, deepest 4 mm),
varioShore at 220 °C, topology auto, springy.
Gyroid at 220 °C. Honeycomb weighed and dropped: its softest row squishes only 0.92 mm
under this pressure, so 8,916 of 10,000 columns cannot go deep enough. All 10,000
columns reachable. Buildable 0.42–3.92 mm (target 0.38–4.00), density 0.145–0.310,
cells 4.2–9.0 mm, literature ±40 %. The top's other end is the bottom (face 0 /
region 100, 100 % of the area).

**(b) `b_pad_thumb_design_palm_heel_check`** — the same pad with the thumb stamp
(20 × 26 mm ellipse, 50 N ≈ 0.12 MPa) as the design load; palm (100 N) and heel (300 N)
in check mode.
Under the thumb the core is denser (it carries 4× the pressure at the same target depth).
Palm: 6,056 columns pressed, max dent 1.40 mm, all inside the data. Heel: 3,600
columns pressed, **3,120 squish past the tested strain** (no number: dark red on the
map), 92 extrapolated. A pad drawn for 30 kg spread evenly does not survive a heel;
the map says so instead of inventing a depth.
Smoothing finding, and the recommender's verdict: every TARGET column is reachable, but
around the thumb's edge one cell of smoothing cannot follow a 4× pressure step — the
buildable depth overshoots the target by up to 2.4 mm, 168 columns land in 0.20–0.25
strain and **180 squish past the tested strain**. Auto therefore reports *nothing fits
every face* (closest: gyroid at 220 °C) and names the face and the 180 columns. (Before
the review fix it wrongly said "reachable" here.) This is the R14 heuristic as
specified; C2's realised lattice replaces it.

**(c) `c_block_top_and_side_handover`** — 100 × 100 × 60 mm block, top loaded
(30 kg, edges soft, "either" mode, deepest 10 mm) and the +X side loaded (25 kg,
centre → edge curve 0.4 → 1, deepest 10 mm); nozzle temperature auto, damped.
Honeycomb is not eligible (face 103 is pushed from the side, R6), so gyroid; 190 °C
fails (4,992 columns too firm), 220 and 240 both reach, and 220 wins the first
tiebreak (3,648 vs 4,256 columns near a table edge). The side stack is 'estimated'
(±50 %); its other end is the −X face (region 105). The two stacks overlap on the whole
block (600,000 mm³); each voxel follows the nearer loaded face, blended over one cell
(85,264 mm³ in the blend band) — see `field_xz_owner.svg`: the split runs along
x = 40 + z, equal depth from both faces.

## Byte-identity (F11/F13)

See the handoff's F11/F13 section: existing jobs run through the base binary and this
branch's binary, every output file hashed.
