# Core brief: three ways core refuses a sound Default Grade (doubled) plan, and one way it moves a cell it accepted

2026-10-02, from PR #354's app agent to #358. Maintainer ruling 4, the same day: "Core-side causes (R2, R5, and R1 if it's core's): one core brief, with a minimal failing job for each." The app never edits core.

Updated 2026-10-03 on the maintainer's ruling: "Write the R2/R3/R5/R6 core brief now, with a minimal failing job and a passing control for each, so #358 can take it straight into the Stepped work." Every number from a job below was re-measured on 2026-10-03 with the CLI built at #358 23e6154e. The counts "on his projects" are round 2's (2026-10-02), not re-measured. Every core reference is file:line at 23e6154e.

## In plain words

The app can now send core its preview's exact cell plan for Default Grade (`lattice.stepped_cells`). Sending stays OFF until core accepts every project's plan. On the CLI, with core at 19a1443b and again at #358 23e6154e, now linked (merged as 436819f6), core refuses the plans for three reasons that are core's:
- **R2:** the depth check reads every cell of a wall whose normal points the negative way one cell too deep. So a cell in the deepest layer is refused for "leaving the prism", although it sits inside it. And a cell one layer in front of the face, outside the part, is accepted.
- **R5:** two cells that only touch are called overlapping when two regions' cell sizes don't nest.
- **R3:** two cells tens of millimetres apart in different regions are called overlapping, because the overlap check forgets which region a cell is in.

Core also accepts cells and then lays them somewhere else:
- **R6:** a cell that is not on its own size's grid is accepted, then laid on that grid. It moves by up to half its size, and it can land on another cell. Nothing refuses it and no receipt shows it; the STL does. Any-step (Stepped) packs make such cells as a matter of course.

Each has a minimal job on core's own fixture and a one-change control. R2, R3 and R5's jobs are refused and their controls accepted. R6's jobs are accepted and laid in the wrong place, and their controls are laid where sent. The app-side causes (R1, R4, R7) are at the end, with the maintainer's 2026-10-03 rulings on R1 and R7. R1's ruling asks core for one optional key.

## How to reproduce

The jobs are in `docs/handoffs/evidence/2026-10-02-lattice-types-round2/core-brief-jobs/` (R2, R3, R5) and its `r6/` folder (R6 and R2x). All are built on core's `tests/fixtures/organic/dead_parity_tab.stl`, an L-shaped part spanning x 0–60, y 0–12, z 0–36. Their load case is `organic/dead_parity.json`'s. The doubled jobs use algorithm `doubled` with no `intent`, the way the app writes a Default Grade job. The any-step jobs (R6c, R6d) use `stepped` with `intent: aesthetic`.

```
core-brief-jobs/run.sh           <topopt-cli> [workdir]   # R2, R3, R5: the verdicts
core-brief-jobs/r6/run_r6_all.sh <topopt-cli> [workdir]   # R6, R2x: the verdicts, then where each cell was laid
```

Both scripts find the repo from their own location.
- `run.sh` was recorded at 19a1443b (`run_linked-19a1443b.log`, CLI built from a tree whose `core/` equals 19a1443b) and at 23e6154e (`run_sync-23e6154e.log`). Re-run on 2026-10-03 at 23e6154e: the same six verdicts, word for word. The plan check runs after SOLVE 1, so in the app every refusal costs a solve.
- `r6/run_r6_all.sh` was recorded at 23e6154e (`r6/run_sync-23e6154e.log`) and at 19a1443b (`r6/run_linked-19a1443b.log`). Every line after the version line is identical. It runs 18 jobs, then `r6/r6_measure.py` (where each cell was laid, read from the STL), then `r6/group_port.py` (a line-for-line Python port of `stepped_group_cells`, used for core's own packed-slot fixture).

| | Failing job | Core at 23e6154e | Control | Core at 23e6154e |
|---|---|---|---|---|
| R2 | `R2_min_corner_depth.json` | refused, "12 to 15 mm" | `R2_control_shallower.json` | accepted |
| R2x | `r6/R2x_outside_face_accepted.json` | ACCEPTED; should be refused | (R2's control) | |
| R3 | `R3_no_region_in_key.json` | refused, "OVERLAPS cell 0" | `R3_control_shifted.json` | accepted |
| R5 | `R5_global_finest_overlap.json` | refused, "OVERLAPS cell 2" | `R5_control_one_region.json` | accepted |
| R6 | `r6/R6_base_off_grid.json` | accepted, laid 1 mm from where sent | `r6/R6_control_on_grid.json` | accepted, laid where sent |
| R6b | `r6/R6b_half_on_quarter_grid.json` | accepted, laid 0.75 mm from where sent | `r6/R6b_control_half_at_21.json` | accepted, laid where sent |
| R6c | `r6/R6c_anystep_off_own_grid.json` | accepted, laid on top of the other cell | `r6/R6c_control_mirror.json` | accepted, laid where sent |
| R6d | `r6/R6d_anystep_second_slot.json` | accepted, laid 2.9 mm from where sent | `r6/R6d_control_first_slot.json` | accepted, laid where sent |

## R2: the depth check projects the cell's MINIMUM corner

`stepped_validate_plan(LatticeTopology, …)` (stepped_plan.cpp:115-119) checks depth at :205-223. It computes `s0 = (origin − slot_origin)·n̂` (:210) and `s1 = s0 + size` (:211). It refuses when `s0 < −1e-6` or `s1 > depth + 1e-6` (:212).
- The origin is the cell's minimum corner (stepped_plan.hpp:104, the app's wire contract).
- For a region whose normal has a negative component, the minimum corner is the cell's DEEPEST point along n̂. So `s0` is where the cell ends, not where it starts.
- So every layer reads one cell too deep. The deepest layer is refused. A cell one layer in FRONT of the face, outside the prism and the part, is accepted.

**Minimal job (`R2_min_corner_depth.json`).**
- One face region: origin (18, 12, 8), normal (0, −1, 0), depth 12. The prism is y ∈ [0, 12].
- One 3 mm base cell at (18, 0, 8), spanning y ∈ [0, 3]. That is 9–12 mm along the normal, inside the prism.
- Core says: "lies from 12 to 15 mm along the region normal, outside its 12 mm prism".

**Control (`R2_control_shallower.json`).** The same cell one layer shallower, at (18, 9, 8), spans 0–3 mm along the normal. It is ACCEPTED, but core reads it as 3–6 mm.

**Corollary (`r6/R2x_outside_face_accepted.json`).**
- The same cell one layer in front of the face, at (18, 12, 8), spans y ∈ [12, 15]. That is −3 to 0 mm along the normal: outside the prism, and outside the part (y ≤ 12).
- Core reads it as 0–3 mm and ACCEPTS it.
- What it lays sits on the part's face: 612 lattice triangles, every vertex at y 11.55–12.45.
- After the fix this job must be refused.

**Ask.** Test the cube's projection interval, `[s0 + S·Σmin(0, n̂ᵢ), s0 + S·Σmax(0, n̂ᵢ)]`, against `[0, depth]`.
- For an axis normal this is exact. For (0, −1, 0) it is `[s0 − S, s0]`.
- For a tilted facet the cube's extent along n is wider than S. Say what containment rule a tilted facet's cells must meet (R2b below).

`test_stepped_plan.cpp` never sets `normal` or `depth_mm`, so this check is untested in core. Add a −y region whose deepest layer is accepted and whose cell in front of the face is refused.

**On his projects** (all converted copies except 570B38E2), counted by `docs/handoffs/evidence/2026-10-02-lattice-types-round2/tools/classify_plan.py`, a Python port of the validator that reports every cell rather than the first:
- the stand's −y wall: 1,467 cells;
- the stand's 17°-tilted face-23 facet: 90 cells.

## R5: one global finest tile for the overlap hash

The overlap test hashes every cell on ONE finest tile: the smallest size on ANY region's menu (stepped_plan.cpp:137-140; the menus are built per region at :128-135). It buckets with `llround(offset/finest)` and spans `llround(size/finest)` (:225-244). The comment at :143-145 assumes "every cell is a whole number of those on every axis". That holds only if every region's ladder nests in every other's. When it does not, a span rounds up and the next cell's start can round into a slot the first cell already holds.

**Minimal job (`R5_global_finest_overlap.json`).**
- Region 1 has one 2.5 mm cell at (18, 0, 38). It is off the part (z > 36). It is there only to make region 1's base 2.5 mm: a doubled region's base is its largest sent cell (run_job.cpp:6989-7001). So the global finest is 2.5/4 = 0.625.
- Region 2 has a 3.25 mm base. Two 1.625 mm cells on region 2's own halving grid, at x offsets 1.625 and 3.25, touch and do not overlap.
- 1.625/0.625 = 2.6. So the first cell starts at slot 3 (2.6 rounds up) and spans 3 slots (3–5). The second starts at 3.25/0.625 = 5.2, which is slot 5. Slot 5 is shared.
- Core says: "cell 3 in region 2 … OVERLAPS cell 2".

**Control (`R5_control_one_region.json`).** The same region-2 cells without region 1's cell. Region 1 is still declared. With no cell, its base is `grading.cell_mm`, which is 0 under `swept`: job.cpp:1815-1821 refuses the key and job.hpp:463 defaults it to 0. A 0 base has an empty menu (stepped_plan.cpp:69). So the hash tile is region 2's own 0.8125, and the cells are ACCEPTED.

**Ask.** Hash per region on that region's own finest tile, or test overlap exactly (interval intersection with positive volume).

**On his projects:**
- 570B38E2, native Default Grade: 1,458 collisions, every one false. An exact check finds 0 positive-volume overlaps among its 4,198 cells.
- 3418E167, converted: 31.

## R3: the hash key has no region id

Offsets are measured from each region's own `slot_origin` (stepped_plan.cpp:180-182), but the key is `(i, j, k)` alone (:146-150). So two regions' cells at the same relative offset share a key however far apart they are.

**Minimal job (`R3_no_region_in_key.json`).**
- Two +y regions, origins (18, 0, 8) and (54, 0, 18).
- One 3 mm base cell each, at relative offset (0, 0, 0). They are 36 mm apart in x and 10 mm in z (37.4 mm).
- Core says: "cell 1 in region 2 … OVERLAPS cell 0".

**Control (`R3_control_shifted.json`).** Region 2's cell moved one cell along x is ACCEPTED.

**Ask.** Key the hash on the region id as well. If cells of different regions must never overlap in space, test that in world coordinates, which needs one common grid or an exact test.

Note: on the stand, the cross-region refusals are mostly REAL overlaps (see R7), so R3 is a separate defect.

## R6: an accepted cell is laid somewhere else

Measured. Core accepts a cell that is not on its own size's grid, then lays it on that grid. The observable is the STL. No receipt records cell positions: the `run_info.json` of `R6_base_off_grid` and of `R6_ref_at_18` differ only in `created_wall_ms`.

**How it happens.**
- Validation exempts base-size cells from the alignment check (stepped_plan.cpp:187-189).
- It checks every other cell only against the tile of SOME family that can express its size (`aligned_on_some_family`, :101-111, called at :184-186). It never checks a cell against its own size's grid.
- `stepped_group_cells` buckets the cells by (region, size). Each bucket gets ONE grid whose pitch is that size, starting from the slot origin walked back by whole cells (:288-293). Each cell's index is `llround((origin − grid origin)/size)` (:306-310). A cell that is not a whole number of its own size from the slot origin is rounded to the nearest grid point.
- The run lays exactly that grid: `PR.origin = g.origin`, `PR.cell_mm = g.size_mm`, and `latticed` marks the rounded indices (run_job.cpp:7030-7057).
- The header promises the opposite: a group's origin is "never a re-anchoring that could move a cell the maintainer approved" (stepped_plan.hpp:168-170).

**How the jobs measure it** (`r6/r6_measure.py`).
- Byte identity: the job's STL equals the STL of the same cell SENT where we predict core laid it.
- The lattice-only extent: the run's triangles minus the triangles common to two runs whose cells share no node (the shell and the solid companion). The extent is the cube plus the strut radius.

**Minimal job (`r6/R6_base_off_grid.json`), doubled.**
- The R2 control's region: origin (18, 12, 8), normal (0, −1, 0), depth 12.
- One 3 mm BASE cell sent at (19, 9, 8). It is 1 mm off its own 3 mm grid in x (the slot origin is x = 18). The sent cube is x ∈ [19, 22].
- Core ACCEPTS it.
- Its STL is byte-identical to the same cell sent at (18, 9, 8) (`r6/R6_ref_at_18.json`): sha256 `4dc6d9b062548da8ec513eaff618fbf565b80ac46b5b1177b9129865041a9ca9` for both.
- Its lattice spans x 17.51–21.43: the cube x ∈ [18, 21] plus struts. Core laid it 1 mm from where it was sent.

**Control (`r6/R6_control_on_grid.json`).**
- The same cell sent at (21, 9, 8), on its own grid. It is accepted and laid where sent: lattice x 20.57–24.31, STL `1ccf1bdf90a8be4f…`.
- That is not the x = 18 STL, so the STL does see where the cell is.
- Supporting: `r6/R6_off_grid_plus2.json` sends the cell at x = 20, 2 mm off. Its STL is byte-identical to the control's. It was laid at x = 21, the nearest grid point.

**R6b: a non-base cell on another family's tile, doubled (`r6/R6b_half_on_quarter_grid.json`).**
- A 3 mm base cell at (18, 9, 8), and a 1.5 mm cell (S/2) at (21.75, 10.5, 8). Its x offset, 3.75, is 5 × 0.75: on the S/4 tile, but not a whole number of 1.5.
- Accepted, because the quarters family "can express" 1.5 mm.
- Laid at x = 22.5, 0.75 mm further. Its STL is byte-identical to the 1.5 mm cell sent at x = 22.5 (`r6/R6b_ref_half_at_22_5.json`, `ea88b5cd0aa0559d…`). Its lattice reaches x 24.14.
- Control (`r6/R6b_control_half_at_21.json`): the 1.5 mm cell at x = 21, on its own grid, is laid where sent. Its lattice reaches x 22.70 (`e630030f9ccf7694…`).
- A halving octree can never place this cell. Doubled should refuse it.

**R6c: a cell laid on top of another, any-step (`r6/R6c_anystep_off_own_grid.json`).**
- Region origin (18, 0, 8), normal +y. Core derives a 14.5 mm base here (`run_info.json`, `grading.stepped.region_cell_mm[0]` = 14.5), so the sixths tile is 14.5/6 = 2.417 mm.
- A one-tile cell at x = 18, and a three-tile cell (7.25 mm) beside it at x = 20.417, one tile in. Both are on the sixths tile. Accepted.
- Core lays the 7.25 mm cell at x = 18, on top of the one-tile cell. The run's lattice triangles equal, triangle for triangle, the 7.25 mm cell alone at x = 18 plus the one-tile cell alone at x = 18. x 18–20.42 is covered twice; x 25.25–27.67 is bare.
- Control (`r6/R6c_control_mirror.json`): the mirror pack, the 7.25 mm cell at x = 18 and the tile at x = 25.25. Every cell is on its own grid. Its lattice equals the two cells laid where sent, and it reaches x 27.88 (the failing job reaches 25.90).

**R6d: the most ordinary any-step placement (`r6/R6d_anystep_second_slot.json`).**
- The same 14.5 mm base. One 8.7 mm cell (3 × 14.5/5) at the START of the second base slot along z: z = 22.5, offset 14.5. Accepted.
- Laid at z = 25.4, 2.9 mm further. Its STL is byte-identical to the cell sent at z = 25.4 (`r6/R6d_ref_at_25_4.json`, `0ce81cc4a25c8139…`). Its lattice spans z 24.72–34.80.
- Control (`r6/R6d_control_first_slot.json`): the same cell at the start of the first slot (z = 8) is laid where sent: z 7.60–17.39 (`5cae340a5661064f…`).
- The rule: a k-tile cell is laid where sent only if it starts a whole multiple of k tiles from the slot origin. A packer places k-tile cells at any whole tile, so most any-step packs with such a cell are moved.

**Core's own fixture has it.**
- `test_packed_slot_covers_exactly_once` (test_stepped_plan.cpp:705-788) packs a 12 mm slot with a 9 mm cell at (3, 3, 0) and 37 cells of 3 mm. The 9 is on the quarters tile, one tile in, so it is not on its own 9 mm grid.
- The plan validates. The test samples coverage on the SENT cells (:739-755): all 13,824 sample points covered once.
- Run through `r6/group_port.py`, the 9 is laid at (0, 0, 0). Of the 13,824 points, 7,344 are covered once, 3,240 twice and 3,240 not at all.
- `group_port.py` is a Python port, not core's binary. It predicts every move the CLI measured above (R6, R6 +2, R6b, R6c, R6d).
- `test_grouping_preserves_every_cell` (:561-622) does check that an index maps back to the sent origin (:595-605). But every cell in its fixture (:573-575) is a whole number of its own size from the slot origin, so it cannot see this.

**By reading, on his projects:** until R1 is fixed (below), the base cells of his plans sit off core's grid by the region's anchor shift. Base cells skip the alignment check, so they would be accepted and moved. Today the non-base cells are refused first, so this has not shown.

**Ask.**
- **Doubled.** A halving octree places every cell on its own size's grid from the slot origin. So check EVERY cell, base included, against its own size's grid. R6 and R6b must be refused.
- **Any-step.** The packer may place a k-tile cell at any whole tile (stepped_plan.cpp:98-100), so R6c and R6d are sound plans and must not be refused. Grouping must keep the sent origin. One way: split each (region, size) bucket by the cell's offset modulo its size on each axis, and give each part its own grid origin. Then R6c and R6d are laid where sent.
- **Base cells, either menu.** A base cell is a whole slot, so it belongs on the base grid. Do not exempt it.
- With R1's `slot_origin_mm` (below), every one of these checks measures from it.

**Tests to add.**
- After grouping, map every index back and require the sent origin, for: a base cell 1 mm off its grid (R6), a three-tile cell one tile in (R6c), and a k-tile cell at the start of the second slot (R6d).
- Validation under doubled refuses an S/2 cell on the S/4 tile (R6b) and a base cell off the base grid (R6).
- `test_packed_slot_covers_exactly_once`: sample coverage on the GROUPED cells (group origin + index × size), not on the sent list. Today that gives 3,240 points twice and 3,240 uncovered.
- At the CLI, after the fix: `R6_base_off_grid` and `R6b_half_on_quarter_grid` are refused. `R6c_anystep_off_own_grid`'s lattice is the 7.25 mm cell at x = 20.417 plus the tile at x = 18. `R6d_anystep_second_slot`'s STL differs from `R6d_ref_at_25_4`'s. Every control keeps its STL.

## R2b: tilted facets

The stand's face-23 facets are tilted up to 17°. The app starts a facet's cell span in front of the face plane by design, so the cube covers the slanted face (LatticeOctreeBake.swift:187-202). No projection fix accepts a cell that starts in front of the plane.

**Ask.** Decide the rule. For example, the cell's centre must lie inside the prism, or the prism tested against the cell's projection with a tolerance of the cell's own sagitta.

## App-side causes, with the maintainer's 2026-10-03 rulings

- **R4.** Fixed at 20eb5edd. The preview packed any-step sizes under doubled.
- **R1: the in-plane slot origin. Ruling: (b), core takes a per-region slot origin.**
  - The app's octree grid is the occupancy origin minus an in-plane anchor shift. The app searches for that shift itself, to fit more base cells (LatticeOctreeBake.swift:404-431).
  - Core lays the plan from the region's sent `origin` (run_job.cpp:6961 and :7002) and applies no anchor. Its own header says the slot origin carries "the region's anchor shift in-plane" (stepped_plan.hpp:117-118), but it is derived, not sent (:124-125). No key on the wire carries one.
  - On every project the refused non-base cells are off core's grid by ONE constant in-plane vector per region. For example, 570B38E2 region 1 is x ≡ 1.6647, z ≡ 0.5443 (mod 2.578) for both cell sizes.
  - **The ask:** an optional per-region `slot_origin_mm` on `lattice.regions`.
    - Absent: today's derived origin, so nothing moves until the app sends it.
    - Present: core validates against the grid the app actually packed. Alignment, depth, overlap, grouping and laying all measure from it.
- **R7: overlapping prisms. Ruling: the app fixes it.**
  - Where two include regions' prisms intersect, the app's plan listed cells of BOTH regions over the same space. On the stand, the face-23 facets' 24.15 mm prisms run into both walls: 1,367 real cross-region overlapping pairs. Core is right to refuse a real overlap.
  - The fix: one owner per cell, decided by the cell's CENTRE. The owner is the region whose prism contains the centre. A centre in two prisms goes to the region whose face plane is nearer. An exact tie goes to the lower region id. Cells stay whole.
  - **Note for #358.** Core gives an overlap voxel to the FIRST matching include region in declaration order, however far its face is. See run_job.cpp:5389-5399 (the per-voxel region ids), :1441-1463 (`fit_cell_field`) and :6595-6615 (the void rule's region ids). That is not the app's rule. A doubled plan's cells carry their own `region_id`, so validation follows the app. But what core derives per voxel can name the other region for the same space. That includes the any-step base cell per region, which `run_stepped_step` derives from those ids (:5540, :6456-6458). Say whether core should adopt the centre rule, or whether the app should send ownership.
