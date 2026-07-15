# 081 — Design-box conflict resolution (079 padding + 080 whole-domain, merged)

Status: **RESOLVED.** `git merge main` into `claude/busy-engelbart-f97e51`. Both handoff
079 (coarsen-align padding, on-device multigrid fix) and handoff 080 (whole-domain
optimize + part-relative baseline) modified the SAME `expand_design_domain` /
`minimize_plastic` code. Resolved by KEEPING BOTH — one merged function, both parameters,
each default preserved. No side was dropped. No ROADMAP box checked.

## The two sides
- **main (079):** `expand_design_domain` gained `int coarsen_align = 1` — rounds the
  expanded element dims UP to a multiple of N by appending HIGH-side Empty voxels so the
  geometric-multigrid hierarchy can coarsen the ~1e-9-contrast design-box system. Test
  `designbox_padding`. Default `1` = byte-identical grid.
- **branch (080):** `expand_design_domain` gained `bool freeze_part = true`; the driver
  gained `MinimizePlasticOptions::freeze_imported_part = false` + the part-relative budget
  rescale and achieved-fraction reporting. Test `designbox_reduction`. Default `freeze_part
  = true` = the M7.dom add-material feature unchanged.

These are orthogonal (grid shape vs mask semantics + reporting), so both coexist.

## Each conflicted file and how it was resolved

**core/include/topopt/voxel.hpp** — signature carries BOTH params, each default intact:
```
DesignDomain expand_design_domain(const VoxelGrid& part,
                                  const DesignBox& design_box,
                                  const std::vector<DesignBox>& keep_out = {},
                                  bool freeze_part = true, int coarsen_align = 1);
```
Both doc-comment blocks (freeze_part rules + COARSENING ALIGNMENT) had already
auto-merged; only the parameter line conflicted. Order chosen: `freeze_part` then
`coarsen_align` (matches the comment order in the header).

**core/src/voxel/voxelize.cpp** — the function BODY auto-merged cleanly (079's
`coarsen_align < 1` validation + the high-side rounding in the `axis` lambda, AND 080's
`freeze_part ? FrozenSolid : Active` mask assignment all present). Only the definition's
parameter line conflicted; resolved to match the header order
(`bool freeze_part, int coarsen_align`).

**core/src/simp/minimize_plastic.cpp** — the driver now passes BOTH at the single call
site, in header order:
```
domain = expand_design_domain(grid, *options.design_box,
                              options.keep_out_boxes,
                              options.freeze_imported_part,   // 080
                              kDesignBoxCoarsenAlign);         // 079 (=8)
```
080's part-relative work is all present and unchanged: `part_relative = expanded &&
!options.freeze_imported_part` gates the budget rescale (`active_target / active_effective`,
line ~304) and the achieved-fraction overwrite (`printed_voxels / part_solid`, line ~466).
079's `kDesignBoxCoarsenAlign = 8` constant + comment kept. The anchor-integrity ladder
floor (`margin_floor_multiple` validation + `stopped_on_floor`) is untouched on this branch.

**core/CMakeLists.txt** — kept BOTH test registrations (`designbox_reduction` from 080 and
`designbox_padding` from 079), plus the shared `design_domain`. All three build.

## Call-site fixes required by the merged signature (NOT a dropped side)
The naive auto-merge left main's POSITIONAL callers binding `coarsen_align` into the new
4th param `bool freeze_part` (int→bool: `8` → `true`), which silently disabled alignment.
Fixed each to the merged 5-arg form, preserving the original intent exactly:
- `test_designbox_padding.cpp:124-125` → `(part, box, {}, /*freeze_part=*/true, 1)` and
  `(..., true, 8)`. freeze_part=true is the default 079 was written against (part frozen);
  coarsen_align back in its intended slot so d1≠d8 padding is actually exercised.
- `test_design_domain.cpp:204` → `(part, box, {keep_out}, /*freeze_part=*/true,
  kCoarsenAlign)`. freeze_part=true matches `o.freeze_imported_part = true` (this gate
  exercises the add-material feature), and coarsen_align=8 matches the run's internal
  expand so the test domain aligns index-for-index (its `nx==16 && ny==8 && nz==16`
  assertion depends on it).

Without these fixes both tests compile but assert against the wrong grid — so they are the
proof the merge did not silently pick a side.

## Proof nothing was dropped
- Full core suite: **100% — 37/37 tests passed, 0 failed** (`ctest`, DEPS=ON with
  Eigen+OCCT). Raw: `100% tests passed, 0 tests failed out of 37`.
- Named gates green: `designbox_padding` (079) all 12 checks; `designbox_reduction` (080)
  all 6; `design_domain` all 24 (now covers BOTH the add-material mask AND the
  coarsen-align dims — proof both features are exercised in one test); `fea_mgcg_matfree`
  44; `fea_matfree` 78; `fea_mgcg` 35; `fea_cg` passed.
- **Gate-V2 GREEN and unchanged**: `gate v2 validation (projected): all 72 checks passed`
  — same 72 as before the merge (simp.cpp / the optimizer core were not touched).
- **No-box path byte-identical**: every 080 addition is gated on `expanded &&
  !freeze_imported_part`; every 079 addition is gated on `coarsen_align > 1` (default 1).
  With no design box, neither branch is entered.

## Both parameters survived with correct defaults; all three features coexist
- `coarsen_align` default **1** (079: byte-identical when unset).
- `freeze_part` default **true** at the `expand_design_domain` level (080: add-material
  feature unchanged); `minimize_plastic` opts the production box path into
  `freeze_imported_part = false` (whole-domain optimize).
- 079's high-side Empty padding + 080's part-relative reporting + the anchor-integrity
  ladder floor all present and mutually independent.
