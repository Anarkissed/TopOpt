# Exact Protect — the proof (ruling 2026-10-26 23:44 + 23:48)

ONE CLI run: TO-core af6d19d9 (oriented keep), his Carriage Arms job d60aedc8ed4a40fd (bcb45454ea8d, quality 64, 2 h) with the
app's keep_regions for his 30 Protected faces (206 regions), at quality 40 (voxel 3.06 mm), one conservative variant
(redesign removed for time). 341 s, rc 0. "Today" = his own export variant_013.stl of that job (finer grid: favours today).

| Check | Today (voxel export) | Exact Protect | Bar |
|---|---|---|---|
| 22 Protected bores: diameter vs CAD (vertex circle fit) | off by up to 0.92 mm (Ø12 → 11.07) | Ø3.300 / 9.2769 / 12.000 / 32.500 = CAD to 0.0001 | 0.05 mm |
| Out of round (peak-to-peak) | 1.0 – 4.4 mm | 0.000 – 0.007 mm | — |
| Bore filled (5 axis points inside the solid) | 0 | 0 | never frozen solid |
| 8 Protected flat faces (ray-sampled, 2 mm grid) | 0.00 – 0.51 mm off the plane | 0.0000 mm | 0.02 mm |
| 4 counterbore rings (240 samples each) | 2.3 – 4.6 mm | 0.0000 mm | 0.02 mm |
| Connected pieces (all 3 versions) | 1 | 1 | — |

Keep clear: the 8 Ø3.3 bores are both Protected and auto keep-clear. Today's export holds Ø3.3 there, so the clearance never
empties the part's own wall; keep restores only the part's own material → no conflict. CAVEAT (to TO-core/reviewer): a
keep region reaches 1.5 voxels past an open end / Protected face; core's export cuts (export − K) there, so material the
optimizer GREW into that band (design box) would be cut. Not seen here (one piece, all versions).

Ring faces: a flat ring is filled by rectangles inside its outline (≤ 16); on his part the rings are counterbore steps
between two Protected bores, whose cylinders (bore + 3 mm) cover them fully.

Scripts: measure2.py (bores), flat3.py (faces), ring.py, comp.py, render.py → cup_today_vs_exact.png.

## Re-run on a STRENGTHEN (growth) job — core 139a5411 (d67204ade10f), 2026-10-27 03:11 (ruling 06:13)

His same job WITH redesign=strengthen and its design box, quality 40, the same 206 keep regions (now reaching past every
face). 1,473 s, rc 0. Version 1 (vf 0.2023, 8.95×) and Version 2 (vf 0.4731, 11.04×) verified; Version 3 unreachable.
Both files ONE piece. **The bar is NOT met:**

| | Version 1 | Version 2 | his own v2 (bcb45454, no keep, q64) |
|---|---|---|---|
| 8 Ø3.3 bores (also keep-clear) | 4 exact, 4 off by ≤ 0.06 mm, out-of-round ≤ 1.4 | 5 exact, 3 rough (oor ≤ 5.2) | open, ≈ Ø3.35 |
| Ø9.28 / Ø12 / Ø32.5 bores (not keep-clear) | open but rough: Ø9.58–10.0, oor 1.4–3.5 | **PLUGGED**: Ø9.28 → Ø1.58 (5/5 axis points solid); 3 bores have no wall left; Ø12 → 10.29 | all open (Ø9.65, 11.05, 32.58 …) |
| Protected flat faces | 2 faces 0.674 mm off; others 0.0000 | 0.674 and 1.44 mm off | — |
| counterbore rings | 2.24 / 1.06 mm | — | — |

Reading: 139a5411 keeps every printed voxel whose centre is outside the original part inside the band. That cannot tell
GROWTH from the voxel skin poking past a CAD surface, nor from growth INTO a Protected hole's own air — so the bumps come back
on bores and faces, and strengthen's growth inside a Protected hole is kept (the 03:11 run plugs four holes his own run kept
open). The first proof (af6d19d9, no redesign) met the bar on every face and bore.
