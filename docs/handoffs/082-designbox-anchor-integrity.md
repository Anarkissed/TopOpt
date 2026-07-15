# 082 — Anchor integrity on the design-box path

Status: **FIXED.** Handoff 080 (Option 2, "whole-domain optimize") made the imported
part Active/REMOVABLE under a design box (`freeze_imported_part == false`, the default),
which silently opened the anchor hole diagnosis 064 had closed on the no-box path: the
N-voxel frozen anchor pad was SKIPPED under a design box, so only the 1-voxel Load/Fixture
BC skin was pinned and the optimizer could carve an anchor boss thin. This handoff builds
the pad on the box path and MERGES it into the expanded design domain. No-box path is
byte-identical; the add-material contract is preserved.

Territory: `/core/` + the sanctioned `TopOptBridge/bridge.cpp`. Branch:
`claude/designbox-anchor-integrity-lb2scy` (fast-forwarded onto the Option-2 tree,
`claude/busy-engelbart-f97e51` @ 47fda64, before this work — see "Merge" below). No
fixtures / benchmarks / materials.json / ARCHITECTURE / ROADMAP box touched.

---

## STEP 0 — Audit of ALL THREE parts of the 064 anchor-integrity fix

The 064 fix had three independent parts. Their status on the Option-2 (removable-part)
box path, audited BEFORE fixing:

### (a) N-voxel frozen anchor pad — WAS SKIPPED under a box (the hole; now fixed)

- The no-box path builds a pad via `mask_step_face(grid, model, fid, FrozenSolid,
  kAnchorPadDepthVoxels=3, pad)` behind every anchor + retained-load face and passes it
  as `opts.design_mask`; the core pins those voxels to density 1 and holds them out of
  the design (`bridge.cpp`, `minimize_plastic.cpp`).
- On the box path the pad was **skipped** (`bridge.cpp`, old `if (!load_case.has_design_box)`
  guard) with the comment *"unnecessary under a design box: expand_design_domain freezes
  EVERY imported-part solid voxel as FrozenSolid."* Under Option 1 (part frozen) that was
  true. Under **Option 2 the part is Active/removable** (`expand_design_domain` tags part
  voxels `freeze_part ? FrozenSolid : Active`, `voxelize.cpp:143-144`; the driver passes
  `freeze_imported_part == false` by default). So only the Load/Fixture BC skin stayed
  pinned (via `effective_mask`), and the boss behind it was a free design variable — the
  hole. **Confirmed skipped; fixed below.**

### (b) Ladder floor (FIX 2) — DOMAIN-INDEPENDENT, still functions (confirmed)

- Handoff 080 STEP-3c claimed the floor is domain-independent. **Confirmed.** The floor
  test is `margin.worst_case * infill_knockdown >= margin_floor_multiple * margin_stop`
  (`minimize_plastic.cpp:458`) — a pure stress-margin threshold with **no voxel-count or
  grid term**. In the bridge, `opts.margin_floor_multiple = kAnchorMarginFloorMultiple`
  is set at `bridge.cpp` *inside* `if (minimize_plastic)` but *outside* the
  `has_design_box` guard, so it applied on both paths already. It needed no change and got
  none.

### (c) keep-frozen-components — does NOT silently no-op, but its reach narrowed (reported)

- This part surfaces disconnected pinned regions as `load_fixture_islands` via
  `keep_largest_and_marked_components` (`voxelize.cpp`). It keys off `VoxelTag::Load ||
  VoxelTag::Fixture` (`voxelize.cpp:437,449`), **not** off `MaskValue::FrozenSolid`.
- Because those TAGS survive into the expanded grid regardless of `freeze_part`
  (`voxelize.cpp:142` keeps the part's original tag), it does **not** silently no-op on
  the Option-2 box path. What it protects, however, **narrowed**: under Option 1 the whole
  part was FrozenSolid so any frozen fragment was covered; under Option 2 it marks only
  the ≤2-voxel edge set bounding a Load/Fixture voxel — i.e. the 1-voxel BC skin, never
  the boss behind it. **Boss protection was never this part's job; it is the pad's (a).**
  So (c) is not a second hole — it functions as designed — but it is not a substitute for
  the pad. No change made to (c); the fix to (a) restores the boss protection it never
  provided.

**Summary:** (a) was the hole. (b) was already fine on both paths. (c) still functions but
only ever guarded the BC skin, so it did not cover the gap (a) left. Only (a) needed a fix.

---

## Merge (branch reconciliation, before any code change)

This branch (`claude/designbox-anchor-integrity-lb2scy`) was cut from the *old* merge-
reconcile 080 (`c4c6a38`), which predates Option 2 — on it the part was still FrozenSolid
under a box and the hole was not yet open. Option 2 landed on
`claude/busy-engelbart-f97e51` via **080-designbox-nearsolid-diagnosis** (the
`freeze_part` / `freeze_imported_part` implementation) and **081-designbox-conflict-
resolution** (reconciled 079's `coarsen_align` with 080's `freeze_part` into one
signature). `c4c6a38` is an ancestor of that tip (`47fda64`), so this branch was
**fast-forwarded** onto it first; only then was the fix built. Verified after merging:
`expand_design_domain(..., freeze_part=false)` tags part voxels `Active`
(`voxelize.cpp:143-144`) and `MinimizePlasticOptions::freeze_imported_part` defaults
`false` (`pipeline.hpp:166`) — the part is genuinely removable under a box, so the hole is
real and guard (a) can fail on pre-fix code.

---

## STEP 1 — The merge rule (design_box + design_mask, made compatible)

The app passes the anchor pad AS a `design_mask`; `expand_design_domain` builds its own
mask on a LARGER grid at an OFFSET. They are merged, not chosen between:

- **The pad is indexed on the PART grid; the expanded domain is larger and offset.** A pad
  voxel at part `(pi,pj,pk)` maps to expanded voxel `(pi+offset_i, pj+offset_j,
  pk+offset_k)` — the SAME whole-voxel offset `remap_node_to_domain` applies to the BCs
  and loads (`domain.offset_*`, `voxelize.cpp` / `minimize_plastic.cpp`).
- **MERGE RULE (stated explicitly):** a voxel the app marked **FrozenSolid** in the
  part-grid pad stays **FrozenSolid** at its offset location in the expanded mask;
  `expand_design_domain`'s Active / FrozenVoid / Empty classification stands everywhere
  else. The pad only ADDS keep-in (FrozenSolid) voxels — the sole value `mask_step_face`
  writes — so nothing else is propagated and the box's own domain is never un-frozen. A
  pad FrozenSolid voxel always lands on a part-solid voxel (mask_step_face walks solid
  layers), which the whole-domain expand left Active; the overlay pins it back to a boss.
- **Compatibility is gated on the semantics, not blanket-relaxed.** `design_box` +
  `design_mask` is merged only when `freeze_imported_part == false` (the part is
  removable, so a pad is meaningful). When `freeze_imported_part == true` (add-material:
  the whole import is already FrozenSolid and the box builds its own mask) a `design_mask`
  is still **rejected** — so `test_design_domain`'s add-material contract assertion is
  untouched, exactly as required.

---

## STEP 2 — What was implemented

All gated so the no-box path and the add-material (frozen-part) path are byte-identical.

**`core/src/simp/minimize_plastic.cpp`**
1. Relaxed the incompatibility: throw on `design_box` + `design_mask` only when
   `freeze_imported_part == true`; otherwise validate the mask is part-grid sized and
   proceed to merge. (Replaces the old unconditional throw.)
2. Merge: after `expand_design_domain`, overlay every FrozenSolid pad voxel onto
   `domain.mask` at its `offset_*`-remapped index.
3. Budget correctness: the `part_relative` `frozen_effective` accounting now counts a
   merged-pad FrozenSolid voxel as always-printed (alongside the Load/Fixture skin), so a
   rung's TOTAL printed material stays at `vf * part_solid`. Without this the pad would
   silently overshoot the part budget by the pad size. No pad ⇒ no FrozenSolid on this
   path ⇒ byte-identical to the pre-082 whole-domain run.

**`app/.../TopOptBridge/bridge.cpp`**
4. Build the anchor pad on BOTH paths (removed the `if (!has_design_box)` guard) and pass
   it as `design_mask`. On the box path the pad is built on the PART `grid` (the expansion
   is internal to the core), so it is exactly the part-grid mask the core now expects.
5. Replaced the now-false `bridge.cpp:706` comment ("anchor pad unnecessary under a design
   box") with the Option-2 reality and the merge description. No stale claim remains.

**Tests**
6. New `core/tests/validation/test_designbox_anchor_pad.cpp` (CMake `designbox_anchor_pad`)
   — the four correctness guards below.

---

## Correctness guards (each FAILS on the pre-082 driver)

New gate `designbox_anchor_pad` (all 9 checks pass). Raw run:

```
[082] part_mass=0.83328 g  pad_voxels=18 (min density 1.0000)  offset=(3,2,3)
[082] box+pad : rungs=1  achieved(part-rel)=0.6667  mass=0.55552 g  savings=33.3%
[082] box nopad: rungs=2  achieved(part-rel)=0.4762  mass=0.3968 g  savings=52.4%
designbox_anchor_pad (082): all 9 checks passed
```

- **(a) THE PAD PROTECTS** — every one of the 18 pad voxels, remapped into the expanded
  grid, is retained SOLID (min density **1.0000** ≥ 0.9) after a whole-domain box
  optimize. Fails on pre-082 code: the run could not even execute (design_box +
  design_mask threw unconditionally).
- **(b) REMAP AT A NONZERO OFFSET** — the box is drawn so the part sits at offset
  **(3,2,3)** (strictly positive on every axis); the pad is checked at the offset-remapped
  indices and `rho.size()` matches the driver's internal expanded grid. A zero/wrong
  offset would sample unpinned Active voxels and fail.
- **(c) STILL REDUCES** — with the pad merged the box path still removes material: printed
  mass **0.556 g < part 0.833 g**, part-relative achieved **0.667 < 1** (not near-solid).
  Savings **33.3%** with the pad vs **52.4%** without, on the same (large) box. The drop is
  NOT the pad over-freezing: the pad freezes only 18/84 voxels and that material is
  absorbed by the part budget (frozen_effective), so per-rung printed mass is unchanged.
  The drop is the **ladder floor (FIX 2)** correctly halting one rung earlier — the padded,
  stiffer part clears the comfort floor (margin ≥ 2·margin_stop = 3.0) at rung 0, so the
  walk stops. That is intended anchor-integrity behaviour, not over-freezing. For scale,
  080's snug-box `designbox_reduction` gate reports **+38%** on its terminal rung; 33.3%
  here is in the same band (and this test uses a deliberately larger box).
- **(d) ADD-MATERIAL CONTRACT SURVIVES** — `design_box` + `design_mask` still THROWS when
  `freeze_imported_part == true`. `test_design_domain`'s assertion is unchanged and still
  green.

---

## THE ONE RULE

- **No-box path byte-identical.** Every core change is gated: the merge/relaxation is
  inside `if (expanded)` and only fires when a `design_mask` is present; the
  `frozen_effective` change only sees FrozenSolid on the box path (none exists on the
  whole-domain no-pad path). The bridge still builds the same pad on the no-box path
  exactly as before. `gate_v2` GREEN and unchanged; `anchor_integrity` (the no-box pad
  gate) unchanged.
- **Add-material feature intact.** `freeze_imported_part = true` + `design_box` still
  rejects a `design_mask`; `test_design_domain` (which opts into that contract) is
  untouched and green.

---

## Evidence

- **Core ctest: 100% — 34/34 passed, 0 failed** (`ctest`, Release; raw:
  `100% tests passed, 0 tests failed out of 34`, total 1051 s). Includes
  `designbox_anchor_pad` (new, 9 checks, 8.4 s), `designbox_reduction` (080, +38% intact,
  2.0 s), `design_domain` (add-material contract, 5.0 s), `designbox_padding` (079, 0.5 s),
  `anchor_integrity` (no-box pad, 8.1 s), `minimize_plastic` (52 s), `mma` (116 s), and
  **`gate_v2` (green, byte-identical, 140 s)**.
- **34/34, not 37:** this local build has Eigen (apt `libeigen3-dev`) but not OCCT/lib3mf,
  so 3 DEPS-gated tests (3MF round-trip, OCCT slice/sketch — none touching the optimizer or
  design-box code) are not registered. CI configures `-DTOPOPT_REQUIRE_DEPS=ON` and runs
  all of them (38 with this new gate). Every optimizer/design-box gate relevant to this
  change is present and green here.
- The new gate's raw output above (savings delta with vs without the pad).
- Built with Eigen (apt `libeigen3-dev`) on Linux (`cmake -DCMAKE_BUILD_TYPE=Release`).
- **`build_core.sh` NOT run here (macOS-only).** `/core/` changed, so the app must be
  re-vendored via `app/scripts/build_core.sh` before the Swift/app tests — but that script
  is an Xcode/`brew`/`lipo`/`xcframework` flow that only runs on macOS; this session is
  Linux (`no xcodebuild`). It must be run on a macOS machine to pick up the core + bridge
  changes for the app suite. No Swift source changed except `bridge.cpp` (the sanctioned
  bridge), which is compiled from the vendored core, so re-vendoring is the only app-side
  step needed.

## Not done / honest notes

- **App/bridge `result_grid` vs the internal expanded grid (PRE-EXISTING, not touched).**
  `bridge.cpp`'s `result_grid` recomputes the expanded grid with the DEFAULT
  `expand_design_domain(grid, box, keep_out)` — i.e. `freeze_part=true, coarsen_align=1` —
  while the core solves internally with `coarsen_align=8`. Their high-side dims can differ
  (e.g. an 8×3×8 snug expand becomes 8×8×8 at align-8), which would misalign the app's
  field sampling on the box path. This landed with the Option-2 merge (081), is outside
  anchor integrity, and no core gate goes through the bridge, so it is untouched here —
  flagged for a follow-up (the bridge should pass the same `freeze_imported_part` and
  `coarsen_align=8` when rebuilding `result_grid`).
- **Guard (a) is deterministic (FrozenSolid ⇒ pinned) + reachability (pre-082 threw).**
  The test does not assert that the *un-padded* boss gets thinned, because for this
  cantilever the anchor root is load-bearing and may be kept anyway; a contrast that
  depended on the optimizer thinning a specific voxel would be flaky. The load-bearing
  guarantee the pad provides is the pinning at the correctly-remapped voxels, which the
  test verifies exactly.
- No ROADMAP box checked.
