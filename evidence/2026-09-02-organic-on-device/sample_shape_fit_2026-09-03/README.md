# Organic sample with shape fit — 2026-09-03 (Debug builds; Mac SwiftPM probe + iPad simulator screenshots)

Six bakes of the 20 mm corner of the PR 353 cube through OrganicSampleCube.baked (temporary probe, deleted after the run). occupied = organic field voxels < 0 at voxel 0.105 mm; z-thirds = occupied voxel counts bottom/mid/top.

PROBE traced fit bare: 23.8 s · occupied 0.630% (211 mm³) · z-thirds bottom/mid/top = 8648/28525/10538 · 162 curves, 811 connectors, 3.00–4.43 mm spacing · shape-fit: 11039 voxels shrunk (min ratio 0.50, depth 16) · traced, shape-fit, bare (no outline; ends trimmed) · window 3.0–6.0 mm · voxel 0.10 mm
PROBE traced fit covered: 22.6 s · occupied 0.622% (208 mm³) · z-thirds bottom/mid/top = 7690/28299/11069 · 162 curves, 811 connectors, 3.00–4.43 mm spacing · shape-fit: 11039 voxels shrunk (min ratio 0.50, depth 16) · traced, shape-fit, covered (ends anchor on the shell) · window 3.0–6.0 mm · voxel 0.10 mm
PROBE traced nofit covered: 21.6 s · occupied 0.674% (225 mm³) · z-thirds bottom/mid/top = 6854/27591/16539 · 148 curves, 694 connectors, 3.00–6.00 mm spacing · traced, no shape fit, covered (ends anchor on the shell) · window 3.0–6.0 mm · voxel 0.10 mm
PROBE grown  fit bare: 20.6 s · occupied 0.263% (88 mm³) · z-thirds bottom/mid/top = 9971/8023/1923 · 2819 curves, 811 connectors, 3.00–4.43 mm spacing · shape-fit: 11039 voxels shrunk (min ratio 0.50, depth 16) · grown, shape-fit, bare (no outline; ends trimmed) · window 3.0–6.0 mm · voxel 0.10 mm
PROBE grown  fit covered: 20.8 s · occupied 0.264% (88 mm³) · z-thirds bottom/mid/top = 9971/8059/1929 · 2819 curves, 811 connectors, 3.00–4.43 mm spacing · shape-fit: 11039 voxels shrunk (min ratio 0.50, depth 16) · grown, shape-fit, covered (ends anchor on the shell) · window 3.0–6.0 mm · voxel 0.10 mm
PROBE grown  nofit covered: 18.5 s · occupied 0.401% (134 mm³) · z-thirds bottom/mid/top = 24533/5210/606 · 2134 curves, 694 connectors, 3.00–6.00 mm spacing · grown, no shape fit, covered (ends anchor on the shell) · window 3.0–6.0 mm · voxel 0.10 mm

Screenshots: traced_shape_fit_bare.png, grown_shape_fit_bare.png (dylib 883494cf71a9c504, Debug, iPad Pro 13-inch M5 simulator).

## Round 2 — whole 20 mm cube, sim on/off (Debug dylib 5744aa3148150ed0 → e91f93ec505fa0a3)

- whole_cube_sim_on_traced.png — Simulate Stresses ON, traced, shape-fit, bare: census "197 curves, 851 connectors, 3.00–4.29 mm spacing · shape-fit: 97502 voxels shrunk (min ratio 0.50, depth 32) · simulated field". Reads as a cube; every corner present.
- whole_cube_sim_off_uniform.png — Simulate Stresses OFF, traced on a SYNTHETIC uniform build-axis field: a bare cubic grid. REJECTED by the maintainer the same night ("way too uniform"); sim OFF is now the cube's own field, ungraded (see whole_cube_sim_off_ungraded.png). Fit ⇒ one separation (4.5 mm), so shape-fit-only ramps nothing (lo == hi).
- whole_cube_sim_off_grown_finetune.png — Simulate Stresses OFF, grown: census "720 curves, 348 connectors, 4.50–4.50 mm" but ONE branched strut rendered — core's grower on a field with no gradient; the count is the traced set's (the growth-receipt gap). Fine-tune disclosure open (spacing scale; overhang fixed 30° on grown).
- sim_off_shape_fit_lock_alert.png — item 3.2: with the simulation off, turning 'Shape fit only' off shows 'Grading needs a stress simulation' and the switch stays on (dylib e91f93ec505fa0a3).
- whole_cube_sim_off_ungraded.png — Simulate Stresses OFF after the revert (dylib 0f06727ecd88cbd5): the cube's own field, shape-fit only, one 4.5 mm spacing — the organic look with curves, ungraded.
- whole_cube_sim_on_standing.png — dylib 1cf12e316eef5b14: the wizard stage now settles Z-up → viewer Y-up (the workspace's own quaternion); the cube stands on its bottom face, columns vertical, arches on the sides like the print; gizmo TOP is the cube's top.
- gizmo_follows_sample_orbit.png — dylib 22a5617fcb8aae88: after an orbit drag the ONE gizmo (bound to the wizard's camera while the wizard is up) reads LEFT/FRONT/TOP from above, matching the cube's turn.
