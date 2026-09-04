# Organic sample with shape fit — 2026-09-03 (Debug builds; Mac SwiftPM probe + iPad simulator screenshots)

Six bakes of the 20 mm corner of the PR 353 cube through OrganicSampleCube.baked (temporary probe, deleted after the run). occupied = organic field voxels < 0 at voxel 0.105 mm; z-thirds = occupied voxel counts bottom/mid/top.

PROBE traced fit bare: 23.8 s · occupied 0.630% (211 mm³) · z-thirds bottom/mid/top = 8648/28525/10538 · 162 curves, 811 connectors, 3.00–4.43 mm spacing · shape-fit: 11039 voxels shrunk (min ratio 0.50, depth 16) · traced, shape-fit, bare (no outline; ends trimmed) · window 3.0–6.0 mm · voxel 0.10 mm
PROBE traced fit covered: 22.6 s · occupied 0.622% (208 mm³) · z-thirds bottom/mid/top = 7690/28299/11069 · 162 curves, 811 connectors, 3.00–4.43 mm spacing · shape-fit: 11039 voxels shrunk (min ratio 0.50, depth 16) · traced, shape-fit, covered (ends anchor on the shell) · window 3.0–6.0 mm · voxel 0.10 mm
PROBE traced nofit covered: 21.6 s · occupied 0.674% (225 mm³) · z-thirds bottom/mid/top = 6854/27591/16539 · 148 curves, 694 connectors, 3.00–6.00 mm spacing · traced, no shape fit, covered (ends anchor on the shell) · window 3.0–6.0 mm · voxel 0.10 mm
PROBE grown  fit bare: 20.6 s · occupied 0.263% (88 mm³) · z-thirds bottom/mid/top = 9971/8023/1923 · 2819 curves, 811 connectors, 3.00–4.43 mm spacing · shape-fit: 11039 voxels shrunk (min ratio 0.50, depth 16) · grown, shape-fit, bare (no outline; ends trimmed) · window 3.0–6.0 mm · voxel 0.10 mm
PROBE grown  fit covered: 20.8 s · occupied 0.264% (88 mm³) · z-thirds bottom/mid/top = 9971/8059/1929 · 2819 curves, 811 connectors, 3.00–4.43 mm spacing · shape-fit: 11039 voxels shrunk (min ratio 0.50, depth 16) · grown, shape-fit, covered (ends anchor on the shell) · window 3.0–6.0 mm · voxel 0.10 mm
PROBE grown  nofit covered: 18.5 s · occupied 0.401% (134 mm³) · z-thirds bottom/mid/top = 24533/5210/606 · 2134 curves, 694 connectors, 3.00–6.00 mm spacing · grown, no shape fit, covered (ends anchor on the shell) · window 3.0–6.0 mm · voxel 0.10 mm

Screenshots: traced_shape_fit_bare.png, grown_shape_fit_bare.png (dylib 883494cf71a9c504, Debug, iPad Pro 13-inch M5 simulator).
