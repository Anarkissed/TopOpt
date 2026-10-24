# Item 47: the anchored hole that was cut away (CORE, routed to TO-core)

These are the images behind the item 47 diagnosis in `docs/handoffs/2026-09-29-flexible-screens.md` (entry 47, "DIAGNOSED 2026-10-24"). They were rendered read-only from his part, the run's job and its variant STLs. Nothing was built and no source file was changed.

- **Run:** `13185527ac694165`
- **Rung:** 0.26 (`variant_026`, the one he got)
- **Core:** `61cfce05` (the app's core when he ran it)

His STL (`variant_026.stl`) and his screenshot (`variant_026_screenshot.png`) are **not** copied here. They stay in `/Users/nadim/dev/TopOpt/reviewer-inbox/2026-10-24-cut-hole/`.

## The images

- **`item47_his_part_vs_variant026.png`** has three rows and four columns. The rows are his screenshot angle (from −y), a close-up of the top of the +x arm from the inner side, and the same close-up from the outer side (the countersinks).
  - Column 1 is his part. Magenta is the top-right hole (faces 119 bore + 121 countersink): it is anchored and has an automatic bolt clearance. Yellow is the hole under it (126/111), which is not anchored. Red is the other anchors and green is protected.
  - Column 2 is `variant_026.stl`, what he got.
  - Column 3 is `variant_026` with the frozen anchor-pad islands added in red. They were in the optimised field at density 1 but were deleted at export by `keep_largest_component`.
  - Column 4 is `variant_068` with its dropped islands in red. Both top rings are gone there too.
- **`item47_plus_x_arm_voxel_map.png`** shows the +x arm voxel by voxel, at columns i = 39 (x = 14.34) and i = 40 (x = 16.25), for rungs 068 and 026.
  - Red is a frozen anchor pad that became an island at density 1 and was deleted at export. Grey is the frozen main body. Orange is his free material, removed. Green is free material that was kept. Black is air or bore. Blue is material added outside the part.
  - The white circles are the r = 3 bores of each hole, in the y = 25.3 and y = 45.3 rows, z = 101 to 150. The top-right hole is at (y 45.3, z 150). The hole under it, at (y 45.3, z 140), is not anchored.
- **`compare_all.png`** compares the original with variants 068, 052, 038 and 026 from four views: his screenshot angle (from −y), the +x plate's outer face (from +x), the +x plate's inner face (from −x, through the gap) and the −x plate's outer face (from −x). In the original, red is anchored, green is protected and yellow is the unanchored z 140 hole.

## The cause in five lines

1. The top-right hole was anchored, so core froze a 3-voxel pad ring around it (`loadcase.cpp:564-570`). That ring is a local skin and ties nothing to the body, despite the comment at `:571-574`.
2. The ring's only link to the arm was the free wall around the hole below (126/111), which he chose to leave free.
3. Every rung was below the frozen floor (item 40, `minimize_plastic.cpp:1462-1467`), so all free material went and the ring became a 106-voxel island at density 1.
4. `keep_largest_component` (`run_job.cpp:573`) deleted it silently at export. The same happened to all 12 anchored holes in the y = 25.3 row (both arms, every rung), so `variant_026` keeps 9 of its 22 anchored holes.
5. Core counts these islands (`voxelize.cpp:813`) but nothing reads the count. `keep_largest_and_marked_components` already exists (`mesh.cpp:694`), and the gate ignores islands (`analyze.cpp:442`). TO-core's plan is to keep anchored and loaded pieces, report the count, and reject a rung that loses one with a named reason.

Line numbers are at core `61cfce05`.
