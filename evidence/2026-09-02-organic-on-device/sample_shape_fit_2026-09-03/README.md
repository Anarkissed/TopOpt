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

## Round 3 — 2026-09-04: the grower, the sim-off rule, and the mirror's floor (all measured)

- `cli_cube20/` — core's OWN CLI (Release `build/topopt-cli lattice-variant`) on `TestCube20.stl`, the printed job's grading (swept 3–6, shape fit, aesthetic, clean, bare), traced and grown. Receipts: traced written 1007.9 mm, 1 component; grown written 1337.9 mm (2834.6 mm grown before pruning). Surface of the written STL by height thirds (bottom/mid/top): traced 30/28/42 %, grown **59/21/20 %**. The grower is bottom-heavy by construction; the app's grown sample (94 % of occupied voxels in the bottom third under Auto) is the same behaviour on the same cube.
- Bridge-direct probes on the sample's FEA field (Debug, Mac): grown length by thirds 1638/945/186 mm at uniform 4.5 mm separation, IDENTICAL for density bands 0–1, 0.05–0.12, 0.08–0.55, 0.02–0.3 (the band is not a lever); every span radius = 0.21 mm on both paths (radius is not a lever); layer 0.12/0.2/0.28 mm all bottom-heavy.
- The mirror's floor: core floors the shape-fit cap at `kOrganicShapeFitMinCellRatio × spacing` when the job has no swept window (always, for organic under D2); the app's mirror was floored at the preview window's low end. Corrected; on this cube the tracer's own resolution floor binds first, so the sim-on traced Auto sample is unchanged (197 curves, 851 connectors).
- `organic_shape_fit_only` is refused by core on every organic job (needs a cell window; windows only with `cell_mode: swept`, which D2 forbids) — the app no longer writes it; the switch means Fit (one separation) vs Auto.
- The sim-off rule (Auto hidden, Fit forced) is reverted: core's run traces its OWN solved field for organic whatever the app simulated, so the sample under sim off must show the same Auto cube; the switch only takes Sim off the Density row.

### Every version, simulator, dylib 1dbcd7041af3688b (2026-09-04 04:28–04:35)
- v3_A_sim_on_traced_auto.png — the cube (197 curves, 851 connectors). Unchanged since 22:13 except standing on its base.
- v3_B_sim_on_traced_fit.png — Fit: one separation on the axial field ⇒ the hoop family, corners open. Core's Fit on this cube.
- v3_C_sim_on_grown_auto.png — Grown: base mat + two columns (94 % of occupied voxels in the bottom third; core's own CLI: 59 % of surface in the bottom third).
- v3_D_sim_off_grown_auto.png — identical to C (the switch no longer moves the organic cell mode).
- v3_E_sim_off_traced_auto.png — identical to A.

## Round 4 — 2026-09-04: the grower's counters, and core's Auto on the cube (reviewer's three points)

**1. Not the pruner** — agreed; and corrected: the bridge ALREADY runs `generate_organic_lattice` and bakes the post-clip spans (a NullSink, boundary nullptr). It did so without `lat.layer_height_mm`, which run_job sets before emission; the base trim (`trim_below_base && layer_height_mm > 0`) and the mid-air raster were skipped in the preview. Fixed.

**2. The counters, from the grower itself** (`OrganicGenStats.growth_*`, now on the bridge header [11..20] and in the sample's census; bridge-direct on the cube's FEA field, whole cube, bare, layer 0.2):

| run | curves | seeds | steps | blocked by support | clamped to cone | joins (refused) | branches (refused) | length by z-thirds mm |
|---|---|---|---|---|---|---|---|---|
| grown, uniform 4.5 mm | 874 | 256 | 7929 | **0** | **0** | 2818 (0) | 1222 (604) | 1638 / 945 / 186 |
| grown, uniform 3.0 mm | 3342 | 484 | 23844 | **0** | **0** | 3186 (0) | 5600 (2742) | 939 / 517 / 261 |
| grown, uniform 6.0 mm | 553 | 121 | 6660 | **0** | **0** | 1201 (0) | 792 (360) | 5 / 0 / 0 |
| sample, Auto 3–4.3 mm (the app's) | 1332 | 484 | 7946 | **0** | **0** | 3544 (0) | 1620 (772) | (94 % of voxels in the bottom third) |

Printability never fired: zero steps refused by the support rule, zero tips clamped to the cone, in every run. A curve averages 9 steps (≈ 3 mm at the 0.2 mm layer) and 3–4 joins against a budget of 6 (`kOrganicGrowthMaxJoins`); half of all branch attempts are refused. The stop_* counters on the grown receipt are the traced FIELD pass (identical to traced). ★ CORE ITEM: the tip loop's other four exits — `!in_region`, no direction, the join-budget `break` (organic_lattice.cpp ~1862), `MAXSTEP` — are uncounted, so the exact split among them cannot be read without a core change. What can be read says budget/joining, not support.

**Core's own CLI under the app's actual job** (`cell_mode: auto`, shape fit, clean, bare; `cli_cube20/auto_*`): achieved spacing 0.47 / 1.02 (median) / 2.37 mm on the cube — core's Auto derives a ~1 mm window, nothing like the 3–6 mm the sample is told. Traced written 15,614 mm (surface 34/38/28 % by thirds); grown written 40,096 mm from 28,268 grown (node_merge 56,577 → base_cut 42,924 → support_prune 40,096), surface **73/18/9 %**. Grown is bottom-heavy in core's own file too. D2's "core decides the window" is ahead of core: what core decides today is ~1 mm.

**The sample's own census after the layer-height fix (Mac, Debug, `OrganicSampleCube.baked`, sim on, Auto 3–4.3 mm):**
- traced: emitted 3043 → node_merge 3005 → base_cut 2932 → support_prune 4979 → … → written 4979 mm (208 % of 2397 mm traced), 1 component; occupied 762 mm³ (was 280 without the layer height), z-thirds 35/46/19 %, 96.7 s. The support pass ADDS legs, as in core's own file (CLI auto_traced: 12,791 emitted → 15,614 written).
- grown: emitted 7857 → node_merge 7901 → base_cut 7063 → support_prune 5538 → written 5538 mm (82 % of 6721 mm grown), 1 component; occupied 181 mm³, z-thirds 90/6/3 %, 30.1 s.

**With the emission BOUNDARY built in the bridge** (`LatticeBoundary.set_voxel_base` on the candidate grid, iso 0.5, window 2·max separation — run_job's `lattice_boundary_for` voxel base; a written shell has no preview object, so this mirrors a BARE job):
- traced Auto: emitted 2810 → node_merge 2761 → base_cut 2719 → support_prune 4182 → written 4182 mm (175 % of 2397 traced), 1 component, occupied 614 mm³, z-thirds 38/46/16 %, 79.8 s (Mac).
- grown Auto: emitted 7699 → node_merge 7727 → base_cut 6977 → support_prune 5578 → written 5578 mm (83 % of 6721 grown), 1 component, occupied 181 mm³, z-thirds 89/7/4 %, 32.0 s.
- ★ RESIDUAL, not attributable here: the sample's support stage ADDS (+54 % traced) where core's own swept run on the cube CUTS (1738 → 1008, −42 %). Different lattices (the app's demand-graded 3–4.3 mm vs core's swept ladder 1.5–4.7 mm), so this is not an emitter A/B. An honest A/B needs the SAME curves through both emitters — a core hook to export/import a traced lattice. Core item.
- Cost: the traced bake went from 27 s to 80 s on the Mac (the support pass); on the iPad expect minutes per change.

### Simulator, dylib 6fd1faf9b521341f (2026-09-04 06:47–06:50), emission with layer height + boundary
- v5_A_sim_on_traced_auto_emitted.png — traced Auto: the cube with the support pass's legs, node balls and base mat, as the file has them. Bake ≈ 3 min on the iPad.
- v5_C_sim_on_grown_auto_emitted.png — grown Auto: the base mat with five posts (census 89/7/4 %).
- v4_A_sim_on_traced_auto_with_layer_height.png — the intermediate (layer height, no boundary).

## Round 5 — 2026-09-04 (evening): the mirror fix actually landed; the split; the 3MF cache
- ★ Correction: the "mirror floor corrected" claim of round 3 was FALSE at the time (the edit's anchor missed). Landed now; the sim-on traced Auto sample is 492 curves, 2340 connectors, 1.50–4.29 mm, 26,773 emitted spans, 6,903 mm.
- Mac timings (Debug): trace+emission+store 105 s; bake from the cached 3MF 16.6 s (was 154 s with the window as the bake band); field from the 3MF vs the trace: max |Δ| 0.0000 mm on the same 196×196×197 grid.
- Two-channel field pinned by OrganicCentrelineFieldTests (surface channel == old bakeField inside the footprint; the first "centreline − nearest radius" design was off on 366 voxels).

### Simulator, dylib 4eee00c4649eaf03 (2026-09-04 16:33–16:38) — the split, on device
- 16:33 → 16:34: Organic on; "Solving the test cube, then tracing…" cleared within ~75 s (solve + trace + emission + bake + store — a cache MISS: the shipped variants were keyed with the stage flag and the project is Aesthetic; fixed, key v4). The device stored `5dabfe47af0f300321742482.3mf` (3.08 MB) in Application Support.
- v6_B_thicker_0_90mm_live.png — Density → Thicker (0.90 mm): thicker struts on the SAME topology within one screenshot interval, no re-trace banner. Thickness is a uniform now.
- The picture itself is the corrected mirror's sim-on traced Auto (492 curves, 1.50–4.29 mm, emission passes on): dense walls, support legs, node balls — core's D2 Auto with shape fit and the file's passes.
- v6_C_shipped_variant_hit.png — dylib 466db7e845fc3e29, device cache cleared: Organic on at 16:43:5x, sample up before the 25 s mark including the 16 s solve; census reads 'the shipped variant (3MF beam lattice)'; no file stored on the device (a hit).

## Round 6 — 2026-09-04 (night): "it looks like ribbons again" — the blobs are the support pass's ARCHES
- The shipped traced-Auto variant (`f75715e5….3mf`): 26,773 beams; 81 % shorter than 0.3 mm; radius p50 0.252 / p90 0.473 / max 0.499 mm (the bead is 0.21); 10,148 beams fatter than 0.3 mm, median length 0.064 mm, 447 of 1274 mm³ of the material.
- Source, by counter (`filleted_spans`, now on the bridge header [47] and in the census): the emission's support pass flags any span running over air by more than `kOrganicArchMinUnsupportedMm` = 0.01 mm and flares it into a fillet — `kOrganicFilletSegments` 12 short segments up to `kOrganicFilletMaxRadiusRatio` 2.5 × the bead. 1938 arched spans on this cube. Prism sides (3 → 8) and the weld pitch hint (0 → 0.28) change nothing (identical census both times).
- It is the FILE: every app job states `loads.layer_height_mm` (0.2 from Print Parameters, RemoteRunner.swift) and the arch pass is gated on it; the printed PR 353 cube's job predates that key, so it printed without arches — which is why the photo shows clean beams. Core's swept run on this cube with a layer height arches 239 spans, max radius 1.01 mm.
- No job key controls the pass (organic keys: boundary_finish, growth, overhang_angle_deg, scale, shape_fit, shape_fit_only, strut_width_mm). Core item: the 0.01 mm threshold and the 2.5× cap.

## Round 7 — 2026-09-05: the part preview's ladder, and two repair switches
- Device log (Save & Exit 00:07:17 → `analyze_loadcase ENTER res=64` 00:07:22 → part bake 00:07:33 → no `verdict=` line in the following hour, app at 0 % CPU): the part's organic bake ran before the stage's solve landed, and the solve never reported. The scene now records `organicNotDrawnReason` and the banner prints it.
- "Flare overhangs for printing" = core `organic_overhang_fillet` (maintainer wire-up): persisted, written only when false and only for organic, probe-gated; bridge sets `OrganicLattice::overhang_fillet` when the linked core has the member. This worktree's core (`ca56654d2805`) does not — the row is disabled with its reason.
- "Preview: show print repairs" = preview-only; off bakes the traced/grown curves (`emit_repairs = 0`), keyed into the variant cache (`repairs=0`), banner says REPAIRS HIDDEN.

## Round 8 — 2026-09-05 (00:40–01:00): the part preview draws ORGANIC; the region layer; synthetic stresses
- Root cause of the octet-looking part preview (Round 7): the stage's solve was never handed the REGION layer. Group B's load is region-defined (faces [], regionIDs [103,105,106,100]; the project declares 8 regions 100–107), and `analyzeSolidLoadCase` sent faces only — so core threw "the declared load case produced NO external load" and no tensor ever reached the tracer. `TopOptKit.applyRegionLayer` (extracted from the optimize wrapper) now feeds `analyzeSolidLoadCase`; `LatticeSimModel.Context` carries `faceRegions`/`anchorRegionIDs`; the fingerprint includes them.
- Mac replay of his project (Debug, `ZZM2SimReplayTests`, temporary): "load group 0 names region 103, which is not declared" was the REPLAY's own call omitting the arguments; with them: solve 7 s, nonConvergent 0, grid 64×16×59, vm 60,416, tensor 362,496 (= 6·n).
- Second gate found on device: the part's bake only runs while the strut preview is ARMED (box icon); before it is, the field landing rebakes nothing (by design — `.onChange` guards on `showStrutPreview`). And `needsStressSolve` was `densityMode == .sim || swept` — an organic job under Uniform density would never solve; now `|| isOrganic`.
- Simulator, dylib 02cf28d39e1b8fd9 (Debug, installed 00:40:12): Lattice stage → Save & Exit 00:42:30 → `analyze_loadcase ENTER res=64` 00:42:35 → `verdict=ACCEPTED margin=1173.63` 00:42:43 (8 s) → box icon 00:44 → "Building the strut preview" → v7_part_preview_organic_sim_on.png at 00:45: traced organic curves on every declared wall (no octet ladder). The back wall reads visibly sparser — the dead wall of the 2026-09-03 note.
- Synthetic stresses on unloaded walls (Aesthetic only): new `OrganicSyntheticStress.inject` — per INCLUDE region, median vM under 2 % of the peak ⇒ dead ⇒ 1–5 foci along the wall's longer in-plane axis at mid-depth, alternating ±, tensor sum w/(r²+s²)·r̂⊗r̂ (s = max(voxel, 0.15·extent)), scaled to 0.5·peak, smoothstep blend (2–6 % of peak). Unit fixture (20³ block, 4 mm dead slab): 1600/1600 voxels injected, live half byte-identical, directions vary across the wall. Settings + wizard section + per-wall Foci pills in Selections; job keys `organic_synthetic_stresses`/`organic_synthetic_foci`/region `synthetic_foci` probe-gated (this core: absent).
- Simulator, dylib 46d9e58c852986ce (01:01): v8_A_unloaded_walls_section_off.png (the section under "In the part", switch off), v8_B_unloaded_walls_on_foci_pills.png (on: Foci per wall 1–5, default 2, the core warning in amber). Save & Exit 01:04:5x → verdict ACCEPTED 01:05:10 → bake with the switch on: `DIAG synthetic: walls=2 dead=0 injected=0 · face 2: loaded · 26% of peak · face 15: loaded · 3% of peak` — the wall he calls unloaded measures 3 % of the stage solve's peak, above the 2 % rule.
- Rule changed on that number: Auto threshold 5 % (`deadFraction`), and a wall that STATES its own count (1–5 in its Selections row) is injected whatever it carries (`forced`, shown in the row). Pinned by OrganicSyntheticStressTests (10 tests).
- Simulator, dylib 9402e625ba8f35fe (01:08): Save & Exit 01:09:5x → part solve ENTER 01:10:14 → ACCEPTED 01:10:23 (9 s) → `DIAG synthetic: walls=2 dead=1 injected=4086 · face 2: loaded · 26% · face 15: unloaded · 3.5% of peak foci=2 inj=4086/4356` (01:10:24).
- v8_C_ladder_banner_before_field_landed.png — the FIRST bake (armed before the solve landed) draws the ladder and the banner says why: "no stress tensor reached the tracer (the stage's solve has not produced one, or it failed)". The rebake on the field's arrival replaces it.
- v8_D_part_preview_synthetic_on.png — the second bake: organic curves on both walls, the back wall now traced on its synthetic field.
- v8_E_foci_row_auto.png — Selections → Group C → Face 2: the Foci row (Auto · 1 2 3 4 5) under Density.
- v8_F_face2_forced_3_foci.png — "3" tapped on Face 2: `DIAG synthetic … face 2: loaded · 26% of peak · forced foci=3 inj=4188/4188 | face 15: unloaded · 3.5% foci=2 inj=4086/4356` (01:12:22). The pill tap produced TWO identical bakes 28 ms apart (both DIAG lines) — the pill's own rebuild plus a second trigger; wasteful, not wrong; open.
- Next build (dylib pending) adds a "Stress on wall" fact row under Foci carrying the bake's verdict.
- Simulator, dylib c942c3db051098f5 (01:14): v8_G_face2_stress_row.png — Face 2's drawer: Foci (Auto) then "Stress on wall · loaded · 26% of peak"; v8_H_face15_unloaded_row.png — Face 15: "unloaded · 3.5% of peak" (DIAG 01:15:35: inj 4086/4356 with 2 foci). A face's stated count set by a pill did NOT survive the reinstall that followed (the app was killed before the project saved on navigation) — the same per-face persistence as the depth and density, not a new defect.
- His project.json restored from `BACKUP2` (sha d6d1d335024d418e) into the new data container after the walk; the app was terminated first.
- 01:20 correction: wizard pills removed; Foci greyed and refused on loaded walls (measured ≥ 5 % of peak, persisted from the bake); the "forced" rule withdrawn. Core brief (01:25): per-region `synthetic_stress`/`synthetic_foci` (default 4), receipt keyed by face; preview foci now on the 80 % ellipse, softening ¼ of the largest extent. Next dylib verifies the greyed row on Face 2 and the live pills on Face 15.
- Simulator, dylib bb0ed829eac8f6bb (01:41), his project re-set to Organic (the restore had returned it to octet): v9_A_section_switch_only.png — the Unloaded walls section is the switch and its (i) only, no pills. Save & Exit 01:45:4x → verdict 01:45:55 → `DIAG synthetic … face 2: loaded · 26% foci=4 inj=0/4188 | face 15: unloaded · 3.5% foci=4 inj=4086/4356` (default now 4, core's recipe). v9_B_face2_loaded_foci_greyed.png — Face 2: Foci pills greyed, "Stress on wall · loaded · 26% of peak"; a tap on its "3" produced NO bake line in the following 8 s (0 `DIAG synthetic`). v9_C_face15_unloaded_foci_live.png — Face 15: pills live, Auto lit, "unloaded · 3.5% of peak".
- His project.json restored again from `BACKUP2` (sha d6d1d335024d418e); app terminated first.
- 02:00: organic cell-size approval wired against the contract (`OrganicForecast`, version-gated, request keys probe-gated — false on this core). No device change until core writes the block; the next dylib re-photographs the fallback Manual list to show it is unchanged.
- Simulator, dylib 42721a3cfaf66c6d (04:34): v10_A_manual_list_fallback_no_probe.png — Cell size → Manual with the probe block ABSENT (this core): the fallback list exactly as before (ladder, every size starred under Aesthetic, "Certification has not reported approved grades yet."). Its caption still read "may leave the lattice in more than one piece" and the (i) promised "a single, contiguous lattice" — both forbidden by the contract; rewritten to the criterion (≥ 95 % of length rooted; one piece is not the bar). His project.json restored again (sha d6d1d335024d418e).
- 05:00: final probe contract wired (in-run `organic_probe.json`, "Check sizes", tints, predicted margin). On this core the button is disabled with its reason; the next dylib photographs that.
- Simulator, dylib b2537a33768018a5 (17:31): v11_A_check_sizes_disabled_no_probe.png — Cell size → Manual: "Check sizes" beside the Approved sizes header, disabled (this core's schema lacks organic_probe_cells_mm; the hover names it), the fallback list unchanged. His project.json restored (sha d6d1d335024d418e).
