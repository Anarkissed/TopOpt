# Core brief: three ways core refuses a sound Default Grade (doubled) plan, plus one way it moves one

2026-10-02, from PR #354's app agent to #358. Maintainer ruling 4, the same day: "Core-side causes (R2, R5, and R1 if it's core's): one core brief, with a minimal failing job for each." The app never edits core.

## In plain words

The app can now send core its preview's exact cell plan for Default Grade (`lattice.stepped_cells`). Sending stays OFF until core accepts every project's plan. On the CLI, with core at the linked 19a1443b, core refuses the plans for three reasons that are core's:
- **R2:** a cell in the deepest layer of a wall whose normal points the negative way is refused for "leaving the prism", although it sits inside it.
- **R5:** two cells that only touch are called overlapping when two regions' cell sizes don't nest.
- **R3:** two cells tens of millimetres apart in different regions are called overlapping, because the overlap check forgets which region a cell is in.

Each has a minimal job on core's own fixture, which core refuses, and a one-change control, which core accepts. A fourth issue, R6, is by reading: core can accept a cell and then lay it somewhere else. The app-side causes (R1, R4, R7) are listed at the end, for context.

## How to reproduce

The jobs are in `docs/handoffs/evidence/2026-10-02-lattice-types-round2/core-brief-jobs/`, built on core's `tests/fixtures/organic/dead_parity_tab.stl`. Their load case is `organic/dead_parity.json`'s, and the algorithm is `doubled` with no `intent`, the way the app writes a Default Grade job.

```
docs/handoffs/evidence/2026-10-02-lattice-types-round2/core-brief-jobs/run.sh <topopt-cli> [workdir]
```

Recorded at the linked core (`run_linked-19a1443b.log`, CLI built from a tree whose `core/` equals 19a1443b): every defect job is refused and every control is ACCEPTED, each in about 6 s. The plan check runs after SOLVE 1, so in the app every refusal costs a solve.

## R2: the depth check projects the cell's MINIMUM corner

`stepped_validate_plan` (stepped_plan.cpp:201-219) computes `s0 = (origin − slot_origin)·n̂` and `s1 = s0 + size`. It refuses when `s0 < −1e-6` or `s1 > depth`.
- The origin is the cell's minimum corner (stepped_plan.hpp:96, the app's wire contract).
- For a region whose normal has a negative component, the minimum corner is the cell's far end along −n.
- So the deepest layer reads one cell too deep, and the first layer one cell too shallow.

**Minimal job (`R2_min_corner_depth.json`).**
- One face region: origin (18, 12, 8), normal (0, −1, 0), depth 12. The prism is y ∈ [0, 12].
- One 3 mm base cell at (18, 0, 8), spanning y ∈ [0, 3]. That is 9–12 mm along the normal, inside the prism.
- Core says: "lies from 12 to 15 mm along the region normal, outside its 12 mm prism".

**Control (`R2_control_shallower.json`).** The same cell one layer shallower is ACCEPTED.

**Ask.** Test the cube's projection interval, `[s0 + S·Σmin(0, n̂ᵢ), s0 + S·Σmax(0, n̂ᵢ)]`, against `[0, depth]`.
- For an axis normal this is exact.
- For a tilted facet the cube's extent along n is wider than S. Say what containment rule a tilted facet's cells must meet (R2b below).

`test_stepped_plan.cpp` never sets `normal` or `depth_mm`, so this check is untested in core.

**On his projects** (all converted copies except 570B38E2), counted by `tools/classify_plan.py`, a Python port of the validator that reports every cell rather than the first:
- the stand's −y wall: 1,467 cells;
- the stand's 17°-tilted face-23 facet: 90 cells.

## R5: one global finest tile for the overlap hash

The overlap test hashes every cell on ONE finest tile, the smallest size on ANY region's menu (stepped_plan.cpp:132-136). It buckets with `llround(offset/finest)` and spans `llround(size/finest)` (:221-240). The comment assumes "every cell is a whole number of those on every axis". That holds only if every region's ladder nests in every other's. When a size/tile ratio has a fraction above one half, the span rounds up while the next cell's start rounds down.

**Minimal job (`R5_global_finest_overlap.json`).**
- Region 1 has a 2.5 mm base, so the global finest is 0.625.
- Region 2 has a 3.25 mm base. Two 1.625 mm cells on region 2's own halving grid, at x offsets 1.625 and 3.25, touch and do not overlap.
- 1.625 / 0.625 = 2.6, so the span is 3 tiles and the second start is at slot 3: a shared slot.
- Core says: "cell 3 in region 2 … OVERLAPS cell 2".

**Control (`R5_control_one_region.json`).** The same region-2 cells without region 1's cell, so the hash tile is region 2's own 0.8125, are ACCEPTED.

**Ask.** Hash per region on that region's own finest tile, or test overlap exactly (interval intersection with positive volume).

**On his projects:**
- 570B38E2, native Default Grade: 1,458 collisions, every one false. An exact check finds 0 positive-volume overlaps among its 4,198 cells.
- 3418E167, converted: 31.

## R3: the hash key has no region id

Offsets are measured from each region's own `slot_origin` (stepped_plan.cpp:176-178), but the key is `(i, j, k)` alone (:142-146). So two regions' cells at the same relative offset share a key however far apart they are.

**Minimal job (`R3_no_region_in_key.json`).**
- Two +y regions, origins (18, 0, 8) and (54, 0, 18).
- One 3 mm base cell each, at relative offset (0, 0, 0). They are 36 mm apart.
- Core says: "cell 1 in region 2 … OVERLAPS cell 0".

**Control (`R3_control_shifted.json`).** Region 2's cell moved one cell along x is ACCEPTED.

**Ask.** Key the hash on the region id as well. If cells of different regions must never overlap in space, test that in world coordinates, which needs one common grid or an exact test.

Note: on the stand, the cross-region refusals are mostly REAL overlaps (see R7), so R3 is a separate defect.

## R6, by reading: an accepted cell can be laid elsewhere

- Base-size cells are exempt from the alignment check (stepped_plan.cpp:183-185).
- `stepped_group_cells` then snaps every cell to a grid of its own size measured from `slot_origin` (:284-305), and that is what the run lays (run_job.cpp:7027-7030).
- So a base cell that is not on its own size grid is accepted and then moved.
- Core's own grouping test uses only own-size-aligned cells (test_stepped_plan.cpp:573-575).
- It cannot be shown as a refusal, because nothing refuses. It needs a unit test: the index → position identity after grouping, for a base cell at a non-multiple offset.

**Ask.** Either check base cells too, or make grouping preserve the sent origin. And add the identity check.

## R2b: tilted facets

The stand's face-23 facets are tilted up to 17°. The app starts a facet's cell span in front of the face plane by design, so the cube covers the slanted face (LatticeOctreeBake.swift:186-200). No projection fix accepts a cell that starts in front of the plane.

**Ask.** Decide the rule. For example, the cell's centre must lie inside the prism, or the prism tested against the cell's projection with a tolerance of the cell's own sagitta.

## For context: the app-side causes (not asked of core)

- **R4.** Fixed at 20eb5edd. The preview packed any-step sizes under doubled.
- **R1: the in-plane slot origin.**
  - The app's octree grid is the occupancy origin minus an in-plane anchor shift. The app searches for that shift itself, to fit more base cells (LatticeOctreeBake.swift:404-431).
  - Core lays the plan from the region's sent `origin` and applies no anchor. Its own header (stepped_plan.hpp:109-111) says the slot origin should carry "the region's anchor shift in-plane", but no key on the wire carries one.
  - On every project the refused non-base cells are off core's grid by ONE constant in-plane vector per region. For example, 570B38E2 region 1 is x ≡ 1.6647, z ≡ 0.5443 (mod 2.578) for both cell sizes.
  - Two fixes, which need the maintainer's ruling:
    - (a) the app anchors at the region origin and drops its anchor search, which changes the preview he approved;
    - (b) core takes a per-region slot origin, matching its own header.
  - **If (b), the ask is a per-region `slot_origin_mm` key (or an in-plane anchor) on `lattice.regions`, used by validation, grouping and laying alike.**
- **R7 (new): overlapping prisms.**
  - Where two include regions' prisms intersect, the app's plan lists cells of BOTH regions over the same space. On the stand, the face-23 facets' 24.15 mm prisms run into both walls: 1,367 real cross-region overlapping pairs.
  - The preview gives each texel one owner; the plan does not.
  - This is the app's to fix: one owner per space in the plan. Core is right to refuse a real overlap.
