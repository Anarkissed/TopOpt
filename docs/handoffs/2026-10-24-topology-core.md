# Handoff: 2026-10-24-topology-core (TO-core, core only)

Agent: TO-core. Reviewer: "reviewer" on agent-comms #TO-core. Coordination with #362 is on #CoreGroup.
Branch: `claude/topology-core`, made from `origin/claude/raster-receipt-fields` at `e0485f7d` (#358's latest push).
Syncs one way from that branch, merge only, never force. Not pushed yet.

## Status

- 2026-10-24 19:13: brief and the reviewer's 19:05 rulings received (#TO-core and #CoreGroup).
- 2026-10-24: PLAN posted on #TO-core (below).
- 2026-10-24 19:40 + 20:08 + 20:13 + 20:25: PLAN ruled. Order: **40, 41+47, 50, 51, Keep Clear, 1(B), primitives,
  61**. Answers: Q40a only saturated runs; Q40b skip; Q40c keep names and say so; Q41a new `export_mesh`; Q41b leave
  `exported_shell_for` (reviewer takes it to #358); Q47 reject; Q-KC1/2 yes; Q1B-a no cherry-pick (d475fac8 comes down
  the chain); pushes after each item's full suite. Item 50 REVERSED by him (see "Item 50, as ruled" below).
- **Item 40: built** (this batch). See "Item 40, as built".

## Item 40, as built (2026-10-24)

The clamp at `minimize_plastic.cpp` (rung loop, `raw < density_min` on a reduction ladder) now:
- flags the rung: `target_saturated`, with its `requested_volume_fraction`, on every line of such a run only;
- writes a top-level `frozen_share` block in report.json, only on such a run: `part_solid_voxels`, `frozen_voxels`,
  `frozen_material_voxels` (a frozen lattice at its density), `active_voxels`, `share`, `smallest_honoured_fraction`,
  `files_named_by: "requested_volume_fraction"`, `sources` (each frozen voxel once: `anchor_and_load_faces`,
  `anchor_pad`, one `face_protection` per face or region in job order, then `other` if anything is left), and
  `skipped_rungs`;
- SKIPS every later floor rung once the first floor rung has run, whatever its verdict (same target and same seed: an
  accepted floor rung seeds the next with the floor design, a rejected one leaves the seed untouched). The skipped rung
  run alone reproduces the floor design exactly (max |drho| = 0). The reason names the floor rung and its verdict.
- The sources come from `build_production_loadcase` (`MinimizePlasticOptions::frozen_mask_sources`, receipt only).
- The CLI prints the SATURATED line, one line per skipped rung and a `frozen:` line; run_job.cpp warns once on stderr.
- The validator checks the new keys (together, typed) and that the sources add up to `frozen_voxels`.
- Unsaturated runs: no new key anywhere, so their report.json bytes are unchanged.

Test: `core/tests/validation/test_starved_rung.cpp` (ctest `starved_rung`, OCCT+Eigen block), red-first: 4 of 11 checks
failed on `e0485f7d` (4 rungs ran, 0.52/0.38/0.26 all printed 0.5952 = 50/84, no block, no request). Green: 32/32.
Full core suite: 140/140 (lib3mf tests not registered on this Mac).

APP LIST (to #354 through the reviewer): the rung card shows `target_saturated`, the frozen share and what froze it
(largest sources first), and the skipped rungs (a line, no file). On-device runs need the bridge to carry
`report.frozen_share` and the two per-line keys; until then an on-device run shows fewer rungs with no reason.

## Items 41 + 47, as built (2026-10-24)

- `voxel.hpp` / `voxelize.cpp`: `printed_bodies` (26-connected printed voxels, the belt's definition; a body CARRIES
  if it holds a Load or Fixture voxel), `carrying_body_shells` (per carrying body its largest MC shell; a shell goes to
  the body most of its vertices vote for, nearest printed centre in the 3x3x3 block; byte-identical to
  `keep_largest_component` whenever the kept set is the single largest shell or the field tags no BC voxel), and
  `lost_anchored_pieces` (Fixture voxels whose as-drawn body held a load but whose design body holds none).
- `check_v3` fills `V3Report::export_mesh` (stored only when it differs from `mesh`), `bodies_exported`,
  `specks_dropped`, `speck_voxels`; `mesh` is unchanged (the §7 gate and the lattice shell, Q41a/Q41b).
- `minimize_plastic`: the as-drawn bodies once per run; per rung the lost-anchor check guards the warm seed and the
  verdict (`kAnchorDetachedReason`, below the belt, above the margin); the line's `bodies` block (exported, specks,
  lost pieces, lost anchor face / region ids from `MinimizePlasticOptions::anchor_voxels`, built in loadcase.cpp).
- `run_job` export: `exported_mesh()` at smooth_factor 1, `carrying_body_shells` on the resample at > 1; one stderr
  WARNING per detached rung; the CLI prints the bodies line.
- "Lost" compares with the part AS DRAWN: an anchored block the drawing never joined to a load is exported, not
  rejected (it was not lost by the design).
- Bodies are decided only when the grid tags BOTH Load and Fixture voxels (the belt's condition). A self-weight run
  keeps the single largest shell, as before. Found by the full suite: cli_demo's self-weight demo has a detached anchored
  ring in a rung, which the first version exported as a second body (2 of 87 checks red). A self-weight run therefore
  still drops a detached anchor ring silently; covering it needs a definition of "lost" without a declared load (open).
- Tests: `test_export_bodies` (ctest `export_bodies`) red-first 20/30 failed after item 40 + the merge (every two-block
  file 1 body; the plate's floor rung 0.26 accepted with the bore pad dropped); green 28/28. `test_shell_iso_provenance`
  gains sibling pins on `exported_mesh()` at both sites (the two existing pins keep their meaning).
- Merged origin/claude/raster-receipt-fields at a5706f41 (includes #358's d228514a outline fix).

## Item 50, NEW BRIEF (reviewer 2026-10-24 22:59; replaces the flex ladder) — PLAN

His latest strengthen run: `~/.topopt-worker/efe18e338ed84ea8` (read-only; res 128, PA12_CF, 13 protections, 37
clearances, 44 anchors, box + 1 keep-out, PLSM, smooth 2; rungs 1.55/1.25/1.10 at about 17 min each; recommended
+10 %, 3.209 >= 1.5).

Shape: a new job key `loads.redesign: "strengthen"` (only with `minimize_plastic: false` and a design box). Absent, the
growth ladder runs byte-for-byte as today. A driver `strengthen_part` (new `core/src/simp/strengthen.cpp` +
`include/topopt/strengthen.hpp`) runs OUTSIDE the optimizers: every optimize is an ordinary one-rung `minimize_plastic`
call, so `simp.cpp`, `plsm.cpp`, `analyze.cpp` (called only) and `production.cpp` are untouched.

1. DOMAIN: `MinimizePlasticOptions::domain_box_only` in `resolve_design_domain` (minimize_plastic.cpp): part voxels
   outside the box that nothing froze become Empty / FrozenVoid; clearances and keep-outs as today; every frozen voxel
   stays. Frozen voxels outside the box are reported. `volume_basis = Domain`: the rung target is vf over the Active
   envelope (no part-relative rescale). Mass in g and % of the original.
2. REFERENCE: certify the part as drawn on the part grid (`analyze_fixed_design`, knockdown): `ref = max(verified,
   margin_required)`; targets `ref x {1.333, 2.0, 4.0}`.
3. CEILING: certify the domain filled solid -> `margin_max`; a target above 0.95 x margin_max is UNREACHABLE (reported
   with margin_max), not run.
4. ADAPTIVE VOLUME, as an OUTER loop (in-loop updates would need simp.cpp/plsm.cpp, which wait on #362's cure):
   coarse grid (res/2) from uniform at vf0 (version 1: from the ceiling, vf0 = clamp(target / margin_max)^(1/1.5);
   version k: max(that, vf_(k-1))); run, certify, update `vf <- vf x (target(1+0.10)/m)^0.75`, capped +-5 % per update
   and floored at vf_(k-1); stop when the certified margin is inside [target, target x 1.25] or after 6 updates. Then
   one fine run at the found vf (uniform start), as the brief says, and verify.
5. VERIFY THE EXPORT: re-voxelize the exported (smoothed, all-bodies) mesh onto the run grid and certify it
   (`analyze_job`'s mesh path); record in-loop vs verified.
6. ACCEPT if verified >= target and >= 1.05 x the previous version, item 47's lost-anchor check clean, Keep Clears empty,
   0 specks; else REPAIR (vf x (target/verified)^(1/0.75), warm start from this result) at most 2 times; else UNREACHABLE
   with the best achieved. Two versions at the same design (vf within 1 % and IoU > 0.98) merge, said so.
7. IoU vs the original part voxels on the run grid; > 0.9 flagged "essentially your original".
8. CONNECTIVITY: item 47's check is the guard. If his test shows floating protected pieces, propose ONE of tether load
   cases or Li 2016's virtual temperature, with the evidence; build neither now.
- Receipt: report.json `strengthen` block (reference, ceiling, per version: target, verified + in-loop margin, mass g /
  %, max |u| at the load nodes mm, IoU, repairs, status Verified / Repaired / Unreachable / Merged, time); files
  `strengthen_1/2/3.stl`; design.bin blocks keyed by the achieved domain vf.
- Red-first `test_strengthen.cpp` (small part in a box): version 1 passes; strictly stronger versions; an unreachable
  target reported; a failing part referenced to the requirement; with the key absent the growth and reduction outputs
  byte-identical.
- Papers: Lin & Sheu 2009 is step 4's idea (adaptive volume until the stress meets its limit), applied here as an outer
  loop with our own update rule; Chu 2018's added stress penalty belongs with the later stress-constrained optimizer
  (it changes the objective, which this item does not); Li 2016's virtual temperature is step 8's candidate; Le 2010's
  adaptive normalisation matters when an aggregate (p-norm) drives the design, which here it does not: every margin is
  the certified max voxel stress; da Silva 2021 sets delta = 0.10 (voxel vs body-fitted 5-8 %) and explains why a
  compliance design is only a first step (99 % higher peak stress than a stress-constrained one at the same vf).
- Test on his Carriage Arms (efe18e33 copied to evidence): A = his outputs; B = from scratch at 1.10/1.25/1.55 at res
  64; C = the new mode, 3 versions at res 128 (estimate 1.5-2 h). Per-version table and one render per version.

### Item 50, as built (approved 2026-10-25 01:52, arm B dropped)

- Job key `loads.redesign: "strengthen"` (needs `minimize_plastic: false` and a design box; carried through the
  JobLoadCase field ledger). The load case sets `domain_box_only` + `volume_basis_domain`; `initial_design` seeds a repair.
- `strengthen_versions` (run_job.cpp, beside `build_job_setup`): reference = max(as drawn, required) via `analyze_job`;
  ceiling = the domain filled solid, certified; per version target = ref / (1 - cut), at least 1.05 x the previous
  verified; above 0.95 x ceiling -> unreachable. The fraction is BRACKETED on the res/2 grid (halve while the aim
  ref x (1 + 0.10) holds, double while it fails, bisect; at most 6 runs), changed from the +-5 % steps after the sample
  showed a margin plateau set by frozen features. Then one fine run from uniform, its exported model-frame mesh
  (`variant_export_model_mesh`) written and certified by `analyze_job`; repair up to 2 (vf x (target/verified)^(1/0.75),
  warm start). Receipt: report.json `strengthen` (reference, ceiling, rule, per version: target, status, vf, in-loop and
  verified margin, mass g / fraction, max |u| at the load nodes, IoU with the original, anchors attached, specks, Keep
  Clear voxels, coarse runs, repairs, seconds). Accepted versions are ordinary variants (files `variant_NNN` by their
  domain fraction).
- Tests: `test_strengthen` RED (the growth ladder refused the domain basis) then 16/16; full suite 143/143.
- Samples for him: `~/dev/TopOpt/reviewer-inbox/2026-10-24-strengthen-sample{,-2}/` (tool `core/tests/tools/strengthen_sample.cpp`).
- Observed: the coarse grid under-reads the margin, so version 1 lands heavier than needed (test bar: vf 0.82, verified
  11.94 vs target 7.92). A fine-grid lightening step is the candidate follow-up, not built.

## Item 50, as ruled (2026-10-24 20:08, 20:13, 20:25) — WITHDRAWN by the 22:59 brief

On a part that PASSES as drawn, "Redesign to strengthen" means stiffness: certify as drawn (margin, flex = max |u| over
the load faces' nodes in mm, compliance), then an ASCENDING walk 1.00, 1.10, 1.25, 1.55, 2.00, each rung gated on
margin; stop when an accepted step cuts flex by less than 5 % per +10 % of plastic (cut = 1 - (f_b/f_a)^(ln 1.1 /
ln(m_b/m_a)), consecutive accepted rungs, achieved printed mass), or when the box is full (growth_target_saturated), or
at the 2.0 cap ("more plastic would still cut flex"). Recommend the knee. A part that FAILS as drawn keeps today's
descending walk byte-for-byte. Plan posted 20:24 and adjusted 20:27; code is third in the order.

## Who owns what (the reviewer's 19:05 split)

- Mine, in this order once the PLAN is ruled: 50, 40, 51, the Keep Clear on an edited piece, 41, 1(B), then the
  design-primitives plan. Item 47 if #362's diagnosis finds core at fault.
- On hold: 42, 45, 46, 48.
- Item 43 (the lattice depth tie keyed by region) is #358's. My Keep Clear item must stay consistent with it.
- Shared files: `core/src/simp/simp.cpp` (#362's cure; my item 41) and `core/src/simp/production.cpp` (#362's 35-38; my
  item 50). Before editing either, I post the lines on #CoreGroup and wait for #362's answer. Whoever lands second
  re-runs the other's tests. #362 expects its edits at production.cpp `:545` and simp.cpp `:715`, `:840-849`, `~:2255`,
  `:2603`, `:3704`.
- I don't touch `LatticeOutlineIndex::min_distance` (#358's hang fix). I merge it when #358 posts the commit.
- Solver files (`core/src/fea/*`, `core/include/topopt/fea.hpp`, `simp.cpp`, `plsm.cpp`, `analyze.cpp`) stay untouched
  until the reviewer says the cure has reached my base.

## THE PLAN (as posted for review)

Line numbers are at `e0485f7d`. Three differ from the CORE LIST, which was written at `e2c70bbf`:
- main.cpp's recommendation is `:560-585` here, not `:614-628`.
- pipeline.hpp `:201`'s actual text is quoted under item 51.
- simp.cpp `:4321` is `simp_optimize_variants`, which only `test_variants.cpp` calls.

Rules for every item:
- Red-first tests.
- No existing test's meaning edited. Where an existing pin conflicts with an item, it is named below and put to the reviewer.
- New receipt keys appear only where the new thing happens, so a run without it keeps its exact report.json and
  run_info.json bytes. Wherever that can't hold, every golden diff is listed with its cause.
- One builder per batch (one item per batch), with narrow tests while building. The full core suite runs before each
  push, built in this worktree's `core/build` (never in the Mac worker's folder), after checking the Mac's load.

### Item 50: growth on a part that already passes

- **Where:** `minimize_plastic.cpp:395-440` holds the growth rules (rungs all above 1.0, descending, a design box
  required); the rung loop starts near `:1110`. `main.cpp:560-585` prints "recommended: +10% ... the SMALLEST addition
  that passes". `loadcase.cpp:500-521` sets the ladder, and `:545-546` assumes "a growth run is by definition a run whose
  structure is UNDER-strength". `production.cpp:818-821` holds the ladder `{1.55, 1.25, 1.10}`.
- **Proposal (a), my pick: certify the part as drawn first.** On a growth ladder, before rung 1.55, core analyses the
  part as drawn on the part grid, with the same fixed-design analysis `topopt-cli analyze` runs (`analyze_fixed_design`,
  `analyze.hpp:320`; I call it and don't edit `analyze.cpp`), and applies the same acceptance gate a rung uses
  (`margin_effective` >= `margin_required`).
  - If the part passes, the run stops before any rung and writes no variant files. The receipt says "already passes,
    nothing to add" with the numbers (his ad68d4c0: 3.71 >= 1.5).
  - If it fails, the as-drawn numbers are recorded and the ladder runs exactly as today.
  - `production.cpp` is untouched, so there's no shared-file edit.
- **Alternative (b):** add a 1.00 rung (`production.cpp:818-821`, a file shared with #362). That relaxes the
  all-or-nothing rule at `minimize_plastic.cpp:414-430`, and the rung's variant_100 file is the part itself. Not recommended.
- **Receipt:** report.json gets an `as_drawn` block (evaluated, passes, margin_effective, margin_required) and a
  `growth_verdict` (`already_passes` | `grown` | `none_passes`), on growth runs only. Reduction runs keep their bytes. Every
  growth golden gains the block, and each one is listed. The CLI prints "recommended: NOTHING TO ADD — the part as drawn
  passes: effective margin 3.71 >= 1.5". The stale comment at `loadcase.cpp:545-546` is corrected.
- **Red-first test:** new `test_growth_as_drawn.cpp`, a small part in a design box with a light load that passes as drawn.
  - RED today: three rungs run and it recommends +10%.
  - GREEN: `as_drawn.passes`, no rungs run, `growth_verdict: already_passes`.
  - Control: a part that fails as drawn keeps rung outputs byte-identical to today.
- **Risk:** the extra solve must not change later rungs through the process-wide solver caches (Galerkin cache,
  recycling: #362's item 36). The control test proves it. If the rungs move, I report it and ask.
- **Question Q50:** when the part already passes, stop (my pick), or run the ladder anyway and report "nothing needed"?
- **APP LIST:**
  - The results screen shows "Already passes as drawn — nothing to add (margin 3.71 >= 1.5)" when there are 0 variants
    and the verdict is `already_passes`.
  - The bridge's result carries the `as_drawn` fields for on-device runs.

### Item 40: a starved step, plus its addendum (run 13185527)

- **Where:**
  - `minimize_plastic.cpp:1045-1078` counts the frozen material: BC tags, the anchor pad's FrozenSolid, and a frozen
    lattice at rho.
  - `:1127-1134` (the `effective_vf` lambda) and `:1452-1467` hold the clamp: `raw = (vf * part_solid - frozen) / active`,
    clamped to `[density_min, 1]`. Only the growth side (`raw > 1`) is flagged today, as `growth_target_saturated`.
  - `report.cpp:79-170` (`emit_variant`) has no requested value, only `volume_fraction` and `printed_fraction`.
  - `run_job.cpp:91-99` (`mesh_file_name`) names files by the requested rung.
  - `main.cpp:525-553` prints the rung lines.
- **Change:**
  - Per rung: a `target_saturated` flag (the reduction mirror of `growth_target_saturated`, set when `raw <= density_min`),
    the requested vf, the achieved fraction and the frozen share (frozen / part solid).
  - Once per run, what froze it, in voxels by source: the Load/Fixture skin, the anchor and load pad, each face protection
    by face_id or region_id (from the existing face_protections receipt), and a frozen lattice region.
- **Rungs below the floor:** the first rung whose ask is at or below the frozen share runs, because it is the floor
  design. Every later rung that is also below the floor is not run. It's reported "skipped: below the frozen floor (0.758),
  same design as rung 0.68", with no file. On 13185527 that saves three full optimizations.
- **File names:** they keep `variant_068` and so on, because the requested vf is the app's join key (`design_store.hpp:63`,
  `job.hpp:868-911`). The receipt says so on each rung (`file_named_for: requested`), with the achieved value beside it.
- **Receipt bytes:** the new keys appear only on a run where some rung is saturated. Every other run keeps its bytes.
- **Red-first test:** new `test_starved_rung.cpp`, a part in a design box whose protections freeze 0.7 or more of its
  solid, on the 0.68/0.52/0.38/0.26 ladder.
  - RED today: no flag, four rungs at one achieved value, no requested value.
  - GREEN: 0.68 is flagged saturated, with requested, achieved, frozen share and sources; the other three are skipped.
  - Control: an unsaturated run's report.json is byte-identical to today.
  - The no-box path (target = vf over the Active part) is measured in the same test.
- **Questions:**
  - Q40a: requested vf on every rung, which changes every report.json, or only on saturated runs (my pick)?
  - Q40b: skip the rungs below the floor (my pick), merge them, or keep running them flagged?
  - Q40c: keep the file names and say so (my pick), or rename to the achieved value, which needs the app's join changed?
- **APP LIST:** the rung card shows the saturated flag, the frozen share and what froze it, and copes with skipped rungs
  (a line with no file).

### Item 51: the stale keep-out comment

- **What the text says:** `pipeline.hpp:198-202` says a keep-out "never carves into the imported part (part voxels are
  always FrozenSolid)". The first half is right: `voxelize.cpp:157-170` places part voxels before it tests the keep-out.
- **What's stale:** the parenthesis has been wrong since handoff 080. On the default whole-domain path the part's voxels are
  Active, so a keep-out neither voids them nor protects them. The CORE LIST's wording ("says it voids part material") doesn't
  match the text.
- **The same stale claim** is at `pipeline.hpp:176-177` ("the original part is NEVER removed"), `voxel.hpp:167` and
  `minimize_plastic.cpp:508-509`.
- **Fix:** comments only, with no behavior change.
- **Test:** none needed. Optionally, a pin that a part voxel inside a keep-out stays part material in both freeze modes. It
  would be green on arrival, because it pins today's behavior.

### The Keep Clear on an edited face piece (NEW)

- **Today:**
  - A clearance is exactly one of `face_id` (a raw B-rep face) or `geometry` (`job.cpp:702-800`, `job.hpp:816-846`,
    `loadcase.hpp:168-177`).
  - `build_clearance_overlay` (`loadcase.cpp:738-786`) feeds the optimizer and the preflight counterfactuals.
    `lattice_keep_outs_from_job` (`run_job.cpp:1773+`) feeds the lattice trim.
  - The receipt keys entries by face_id (`run_job.cpp:9102-9112`), and so does the bridge (`clearance_face_ids`).
- **The region layer already exists:** `loads.face_regions` (`job.cpp:557-663`, `face_region.hpp:139-225`) with an id,
  filter/add/remove, and cuts as model-space half-spaces. Anchors (`anchor_region_ids`), load groups (`region_ids`) and
  protections (`face_protections` `{region_id, depth_mm}`) all use it. Clearances don't.
- **Proposal:** a clearance may give `region_id` instead (exactly one of `face_id`, `region_id` or `geometry`). It must name
  a declared `loads.face_regions` id, or the job gets a schema refusal. Resolution works as it does for a protection:
  - `resolve_face_regions` gives the member faces.
  - Each member face gives today's face_id geometry (`resolve_clearance_from_face`, so the kinds and margins are unchanged).
  - The union is rasterized.
  - The region's cuts are applied as voxel-centre half-space tests, the same rule `tag_step_region` and
    `mask_step_region` use.
- **Identity:** a one-member region with no cuts gives exactly the face_id clearance, voxel for voxel.
- **Receipt:** the entry adds `region_id` only on a region clearance, so face_id entries keep their bytes.
- **Both consumers honor it:** the optimizer's overlay with its preflight, and the lattice trim.
- **Painted pieces** already send their painted run id as a face id (#354's B5, 3f293974), so they're unchanged.
- **Consistency with #358's item 43:** the same key (`region_id` = a `loads.face_regions` id), the same resolver, and cuts
  applied the same way, so a protected piece and a Keep Clear piece cover the same voxels. I don't touch `job.cpp:2537-2569`
  (the lattice depth tie).
- **Red-first test:** new `test_clearance_region.cpp`.
  - RED today: the schema refuses `region_id`.
  - GREEN: identity against face_id (bolt and face kinds); a plane cut in half and a bore cut in half, with exact voxel
    counts and 0 voxels past the cut; a two-face union; an unknown id refused; the receipt carries region_id.
  - The existing clearance tests are unchanged.
- **Questions:**
  - Q-KC1 (to #354 through the reviewer): is the key `region_id`, as above? What does the app draw for a cut piece's Keep
    Clear? My proposal is the clearance volume cut by the piece's own cut planes: half a bore gives half the swept cylinder;
    half a face gives the slab in front of that half.
  - Q-KC2: a member face whose kind doesn't fit (a "bolt" on a plane member) is skipped and reported per member. If no member
    resolves, the clearance is refused, not silently a no-op.
- **APP LIST (#354):**
  - Send `{kind, region_id, margins}` for a Keep Clear on a cut piece; unedited faces keep sending face_id.
  - The bridge needs a clearance region id (BridgeLoadCase) and `clearance_region_ids` back, so on-device runs honor it.

### Item 41: export every body that carries its own load or anchor

- **Today:**
  - `check_v3` (`voxelize.cpp:728-816`) already finds the extra bodies that bound Load or Fixture voxels
    (`keep_largest_and_marked_components`, `mesh.cpp:694`). It counts them (`load_fixture_islands`) but ships only the
    largest (`voxelize.cpp:814`).
  - The export writes `variant.v3.mesh` (`run_job.cpp:612-620`), or, at `smooth_factor > 1`, the resampled mesh cut to the
    largest body (`run_job.cpp:572`).
  - The lattice shell uses `exported_shell_for` (`run_job.cpp:1726-1732`).
  - `simp.cpp:4321` is `simp_optimize_variants`, which only `test_variants.cpp` calls.
- **Change:**
  - The exported mesh is the largest body plus every body that bounds a Load or Fixture voxel.
  - Loose specks touching neither are dropped and counted per variant in the receipt (count, triangles, volume).
  - The smooth path (`:572`) gets the same rule, with marks from the same voxels.
- **Two ways to keep the §7 gate's input:**
  - (a), my pick: a new `V3Report.export_mesh` that the export uses, with `V3Report.mesh` unchanged.
    `test_anchor_integrity.cpp:315-334`, which pins "the shipped mesh stays one body", stays green with its meaning intact.
  - (b): change `V3Report.mesh` itself. That changes that test's meaning, so it needs a ruling.
- **Out of my scope:**
  - `exported_shell_for` (`:1731`) is the lattice stage's shell. Changing it changes the latticed companion of a split part,
    so it's coordinated with #358 (Q41b).
  - `simp.cpp:4321`: no change proposed, since no app path reaches it. If the reviewer wants parity, it waits for the cure,
    and I post the lines on #CoreGroup first.
  - `organic_lattice.cpp:6888` also keeps only the largest body. That's lattice code (#358's), so I'm only noting it.
- **Receipt:** per variant, `bodies: {exported, with_load_or_anchor, specks_dropped, speck_volume_mm3}`, emitted only when
  more than one body is exported or a speck is dropped. I measure first how many goldens that touches and list them.
- **Red-first test:**
  - Re-pin `test_shell_iso_provenance.cpp:131` and `:197` (their reference uses `keep_largest_component`), on a two-body
    fixture so the re-pin goes red first.
  - New `test_export_bodies.cpp`: two arms, each with its own anchor and load. RED today: 1 body. GREEN: 2 bodies. A free
    speck is dropped and counted, and a single-body part is byte-identical.
- **APP LIST:** results and the preview may show several bodies in one STL/3MF.

### Item 1(B): the watertight voxelizer rule for every stage

- **Prerequisite:** d475fac8 (`VoxelTies::Watertight`) is only on `origin/claude/flexible-squish-maths`, not in my base.
  Q1B-a: does it reach my base through #358's merge down the chain, as its message says, or may I cherry-pick its voxel
  parts? I won't merge #361's branch.
- **Then, first, a measurement** (a harness probe, not shipped code). For each option below, the numbers on the 155 fixture
  grids, `test_smooth` S1 (28 under Watertight), `cube_10mm` at res 50 (+300 voxels) and his parts:
  - (A) Ignore violations within `freeze_tol_mm` of a frozen vertex, in both the baseline and the candidate.
  - (B) Compare per region (the frozen band against the free mesh), and reject only when the free region's count rises.
  - (C) Compare against the input's own Watertight baseline, with a tolerance of k voxels.
  - (D) Keep Legacy only inside the guard's re-voxelization (`min_feature_of`), and use Watertight everywhere else.
- **Then the reviewer rules, then I build:** the default tie becomes Watertight for every `voxelize` and
  `voxelize_onto_grid` caller, plus the ruled guard rule at `smooth.cpp:216-248`.
- **Proof:** the 10 of 155 fixture grids that change, listed with counts; every golden diff with its cause; `test_smooth`
  S1 green under the ruled rule; `test_voxelize_ties` green.

### Item 7: Topology design primitives (plan only, no code until ruled)

- **Today:** `design_box` (one box) and `keep_outs` (boxes, which need a design box): `job.cpp:956-968`,
  `job.hpp:1174-1177`, `pipeline.hpp:197-203`, `voxelize.cpp:130-195` (`expand_design_domain`), and `production.cpp:823+`
  (`minimal_growth_design_box`).
- **Proposed schema:** `design_primitives`, with up to 6 entries
  `{id, shape: box | cylinder, role: positive | negative, ...}`.
  - A box is given by min and max (or centre, size and rotation, to match what the app stores).
  - A cylinder is given by base_center, axis, diameter_mm and height_mm.
  - It's exclusive with `design_box`/`keep_outs` (one form per job).
- **Core support:**
  - The expanded grid is the bounding box of the part plus every positive primitive.
  - A voxel is Active when it's inside any positive and inside no negative. Negatives beat positives.
  - The part stays as today: a negative never voids part material, the same as a keep-out.
  - Growth's minimal box applies to the union.
  - The receipt reports, per primitive, the voxels it made Active or voided.
- **Questions:** are boxes axis-aligned or rotated as the app stores them? Is a cylinder's axis free? Is a negative outside
  every positive refused, or a no-op?

### Item 47: the cut hole (#362's diagnosis, 2026-10-24 19:25: the cause is core)

The cause chain, checked against my base read-only:
- Every rung of 13185527 was below the frozen floor (item 40, `minimize_plastic.cpp:1462-1467`), so all free material went.
- Each anchored hole's 3-voxel pad (`loadcase.cpp:564-570`) is a local skin, so the pads were left as floating islands
  at density 1.
- `check_v3` counts those islands (`voxelize.cpp:813`, `load_fixture_islands`, which nothing reads) but ships only the
  largest body (`:814`, and `run_job.cpp:572` on the smooth path). So the holes were deleted silently.
- The gate is `accepted = load_path_ok && margin_ok` (`analyze.cpp:442`, #362's solver file), so it never sees them.

Plan addendum, if routed to me. Each body is classified by what it carries:
- **Load AND anchor** (his split arms): exported, as Nadim ruled.
- **Anchor only** (a detached anchor ring) **or load only** (a floating loaded piece): the design lost a boundary
  condition. The rung is rejected with a reason that names the regions, and the receipt counts the pieces. The rejected
  rung still writes its report line.
- **Neither** (a speck): dropped and counted.

The gate change goes in `minimize_plastic.cpp`, where the rung's verdict reads `check_v3`, not in `analyze.cpp`. If the
reviewer prefers `analyze.cpp`, it waits for the cure.

Test: a scaled-down copy of 13185527. RED today: the holes are missing and the rung is accepted. GREEN: the starved rung
is flagged, and no accepted rung is missing an anchored hole.

Q47: reject or warn? Is an anchor-only ring exported for the record? My pick: reject, and don't export the ring.

Repro files: `~/.topopt-worker/13185527ac694165`, read-only.

From #362 (2026-10-24 19:26):
- The run was SIMP+PLSM at `smooth_factor` 2, so the delete is the smoothed path (`run_job.cpp:572-573`). The CAD
  projection (`:611-617`) runs on the filtered mesh.
- The Load/Fixture marks must be carried into `keep_largest_and_marked_components` (`mesh.cpp:694`) on that path too.
- #362's cure touches `analyze.cpp` only near `:273` (the island-drop forbid by `analyze_fixed_design`), not
  `:442`/`:446`. #362 agrees the gate goes in `minimize_plastic.cpp`.

### On hold

42, 45, 46 and 48: untouched.
