# Organic lattice in the Lattice Stage UI — handoff (in progress)

> ## ★ STATE AT 2026-09-03 — REVERTED: no core change in this PR
> On 2026-09-02 the maintainer said organic should be available under Structural;
> the agent read that as a core instruction and retired two core gates on disk
> (`run_job.cpp refuse_organic_structural`, `job.cpp` shape-fit intent check). The
> reviewer ruled that a deleted assertion is forbidden regardless of who asked:
> core has NO INSTRUMENT to certify organic geometry under a structural intent (the
> certificate reads density against the OCTET tensor; nothing has measured a tensor
> for traced geometry). **Reverted** — `git status core/` is clean at commit
> `94313e30`. The UI keeps the committed behaviour: the Organic chip is offered in
> both intents, DISABLED under Structural with the reason shown, never hidden,
> never silently switched; it never writes a job core refuses. Making organic
> certifiable under Structural is a CORE task (resolved beam-network certification
> over the GRID/SKIN/SEG span export) — out of scope here.
>
> Also per the reviewer: the traced path's refusals are the traced path behaving as
> known (trace-then-repair cannot be made clean by adding passes —
> `organic_lattice.cpp:2477-2479`; traced 40 mm cube 8,793 legs vs GROWN 0). Fix (a)
> "re-run support after cleanup" is DECLINED. `support_converged = true` in the
> receipt describes the state BEFORE cleanup changed it and is not a printability
> claim. The next measurements are the GROWN path on the same job bytes and the
> M2's own separation cliff (§14 below when written).
>
> UI fixes on disk (uncommitted until the suite names its failures):
> - **The octet window no longer rides into organic — at its real source.** The
>   on-disk project said `cellSizeMode: auto` (window 4–8); the job carried `swept
>   5.5–6` because `runSpec`'s PR 310 plan turns an octet Auto into a per-member
>   swept window. Under `algorithm == "organic"` an Auto pick now travels as core's
>   own `cell_mode: auto` with no window (only an explicit size is ever sent); the
>   octet path is untouched. Test: `testOrganicAutoDoesNotInheritTheOctetsDerivedWindow`
>   (octet control still derives). The wizard row additionally resets an inherited
>   swept/fit mode to Auto out loud and lights nothing for an inherited mode.
> - **Section 6(i) struck from the UI** (addendum A): the "up to 4 mm stayed one
>   lattice / 5 mm left 40 % dust / 6 mm 85 %" captions were gc2's inline tracer, not
>   `trace_organic_lattice`; both captions are now neutral. No cell-size verdicts or
>   thresholds remain in the organic pane.
> - **The receipt's four fields are carried, not judged:** `OrganicRunReceipt`
>   gains `growthJoinRefusedSpan` and a one-line `contiguityLine` (survival · pieces
>   (largest %) · joins refused); the scene exposes it as `organicReceiptSummary` and
>   the preview label appends it. Pinned in `OrganicRunReceiptTests`.
>
> ### E. The census — every organic run in this handoff (Release core `build/topopt-cli`, 2026-09-02/03)
> `length_census_mm` per stage (mm). **`census_components[]` is NOT in the receipt
> this core build writes** — every stage's component count is absent, not null;
> the length census is what exists. `null` = stage did not run.
>
> | stage | TRACED, run-2 bytes, gate off | GROWN, run-2 bytes + `organic_growth` |
> |---|---|---|
> | grown (initial curves) | 6016.08 | 15646.75 |
> | emitted | 7683.25 | 16073.25 |
> | node_merge | 7211.25 | 13533.31 |
> | base_cut | null | null |
> | support_prune | 783.28 | 85.71 |
> | stranded_drop | 783.28 | 85.71 |
> | ground_tie | null (yet `ground_tie_legs_added` = 8) | null |
> | branch_support | null | null |
> | dangling | 783.28 | 85.71 |
> | stranded_drop_2 | 783.28 | 85.71 |
> | fill_mat | null | null |
> | finish | null | null |
> | written | 783.28 | 85.71 |
>
> Traced receipt: survival 0.130, 1240 spans, 5 pieces, largest 45.2 %, stranded
> 429.3 mm, legs 7343, cuts 607, `unsupported_cells_remaining` 17 (the run-2
> refusal). Grown receipt (report only — addendum B withdraws "switch to grown";
> traced ships): survival 0.0055, 103 spans, 6 pieces, largest 37.7 %, stranded
> 53.4 mm, legs 1834, cuts 462, `unsupported_cells_remaining` 0; the support prune
> took 13,533 → 85.7 mm. **Receipt defect to report:** `growth_ran` reads `false`
> although the grown branch ran (the "grown" census row is 2.6× the traced one and
> `oo.lat = jg.organic_growth ? grow… : trace…` is unambiguous) — on the
> lattice-variant path `R.oc.growth_ran` reaches the receipt unset. The separation
> sweep (3.0–6.0) was started under the earlier instruction and STOPPED at its first
> point when the addendum withdrew it; no sweep numbers exist.
>
> **The organic SAMPLE preview is NOT built.** The wizard's sample is still
> `LatticeSamplePatch` (an octet patch); it has no organic branch, so what he saw
> is not an organic lattice. Plan: generate the 40 mm cube's spans with the recipe's
> bending load (`scratchpad/cube/job.json` is written: `cube40.stl`, force
> `[200, 0, −100]`, `emit_organic_spans`, res 64), bundle the `_SPANS.txt` as a
> `TopOptFlows` resource (Package.swift has no `resources:` yet), and add an
> organic branch to `stageMesh` that draws capsules from `OrganicSpanIndex` — no
> tube/capsule mesh helper exists in the app yet. The run itself was blocked:
> `cd <scratchpad>/cube && ../../build/topopt-cli lattice-variant job.json --out out`.
>
> **The real-part preview from a run's spans IS wired** (`organicSpans` →
> `bakeField` → capsule-min field; label names the span count) but has never been
> exercised on device because no on-device organic run has yet completed (three
> endings, §9). The Mac replay proves core's side (§10).

**Branch:** `claude/topopt-lattice-preview-holes-5ab466` (merged `origin/main` @ PR 353 at `de96877d`)
**Last green commit:** `dbcb356e` (settings, keys, gates, wizard row — 7/7 tests)
**§2 now compiles and its 15 tests are green** (OrganicSpanIndex ×4, OrganicRunReceipt ×2,
LatticeSchemaProbe ×1, LatticeOrganicSettings ×7 + the settings tests). Read §4 for what is
still unverified.

## 1. Landed and tested (dbcb356e)
- `LatticeSettings` + `LatticeSpec`: the seven `organic_*` keys, core's defaults, CodingKeys,
  decode AND encode (unconditional). `gradingDictionary()` writes a key only if (1) algorithm is
  organic, (2) `gradingSchemaAccepts` (this core: all seven true), (3) moved off core's default.
  `organic_growth` never without `layerHeightMM > 0` (§2A); overhang never under growth (§2C).
- `runSpec(layerHeightMM:)` threaded from `project.printParams` at all three callers.
- Wizard model mirrors the seven in/out. `LatticeOrganicSettingsTests` ×7.

## 2. Landed, NOT yet compiled (after dbcb356e)
- **Core**: `lattice.emit_organic_spans` (job.hpp/job.cpp), span ledger collected for weld OR
  spans (§2B), `_SPANS.txt` written post-emission (`GRID` + `SEG`, no `SKIN` — nothing in scope
  states a designed rim), **refuse-on-empty via `JobError`**, receipt `span_count / span_length_mm
  / span_path` under `grading`. `test_job.cpp`: S1 schema test.
- **App**: `OrganicSpanIndex` (parse, uniform 4 mm index, `distance`, `bakeField`) + tests;
  `OrganicRunReceipt` (§5 fields, null-tolerant census, `mismatch(...)`, `contiguityReport`) +
  tests; `TopOptKit.latticeSchemaAccepts(key:)` + controls test; `LatticeVariantAlternative.spanText`
  and `RelatticeResult.spanText` fetched beside the mesh; both job builders set
  `emit_organic_spans` when organic; `LatticeSDFScene(organicSpans:organicReceipt:)` bakes the
  organic field from spans FIRST (trace only when none) and exposes `organicSpanSource` +
  `organicReceiptMismatch`; preview label appends the source and SHOUTS a mismatch; workspace
  stashes spans+receipt from on-device (`RelatticeRun`) and remote (`openLatticePage`) runs, folds
  them into the bake key, and rebakes on run change.
- **Wizard UI (his 2026-09-02 spec)**: "Organic" chip at the TYPE level (sets
  `cellTransition = .organicGrade`; tapping a lattice type leaves organic); a separate organic
  "In the part" pane: Traced/Grown (Grown disabled WITH reason), Cell size Auto·grade / Fit·one
  size / Pick a size (list from `regionMemberMM` ÷ k, printability-filtered), Density
  Auto / Sim / Thicker (+ strut width), FIXED finish "grade to fit the outline"
  (`organic_shape_fit` forced on select and on load), overhang (hidden under growth), spacing
  scale with the §6 note as ADVISORY.

## 3. Open questions put to the maintainer (unanswered)
1. Structural-mode cell list: hard filter to the measured-lattice band, or advisory (§6/§8)?
   Grown list its own set?
2. "No finish on the faces": `organic_boundary_finish = "clean"` (drops the net-skin, clipped
   ends become cantilevers) or keep core's `skin`? Currently: NOT written (core default).
3. Remove the "Organic Grade" pill from Grade style now that Organic is a Type-level chip?
   Currently: still there.

## 4. Not done / caveats
- **The lattice-key probe reads the VENDORED xcframework.** `latticeSchemaAccepts("emit_organic_spans")`
  printed `false` in the test run because `app/TopOptKit/vendor` was built before the core change;
  `build_core.sh` was re-run afterwards. Until the app is rebuilt against it the job builders will
  NOT ask for the span file — by design, that is the probe doing its job. Re-run
  `LatticeSchemaProbeTests` after `build_core.sh` and expect `true`.
- ctest (Release) #1: every test passed except `cli_demo` (= `test_cli`, a validation binary that
  shells out per case), which sat at 0% CPU for 30 min after 36 CPU-min and was killed. Its solo
  rerun is in flight; its source does not reference lattice/welded/organic (see grep in the
  session), so the span export is not in its path. `job_schema` (with S1) passes.
- Compile + tests of §2; ctest Release #2 (with S1); `build_core.sh` re-run (chained);
  device verification (an organic on-device run → label shows "N struts from the run's
  emitted spans", no MISMATCH).
- **Persistence gap**: `spanText` is NOT in `LatticeAlternativeDTO` (OutcomeStore) — a reopened
  project loses the run's spans and the preview falls back to the trace (and says so). Persist
  the file to the sidecar dir and store a path rather than the text.
- Step 3 (in-shader capsule-min over the index) — deferred; the baked field is the enabler,
  the shader path is the fidelity upgrade. Blocker 1 in the task doc is stale on this tree.
- §7: multi-component grown is REPORTED (`contiguityReport`), never judged.
- Organic Grade pill + `LatticePage.algorithmCard` (dead) untouched pending Q3.

## On-device, 2026-09-02 evening — what the simulator actually showed

Measured on `A030C20C…` (iPad Pro 13", 1032×1376 pt), build hash `60f9dc2dbd24fb7c`,
project `102117B9` ("M2 verticalStand", Ready) with `lattice.algorithm` set to
`"organic"` by hand (backup: scratchpad `project.json.BACKUP2`, sha `d6d1d335…`).

1. **The Organic chip is real and the state round-trips.** With the project saying
   organic, the wizard opens with Organic selected (filled chip, its "on" caption).
   The "chip won't select" lead from earlier tonight was a HARNESS SCALE error:
   the screenshot is ~1500 px wide for 1032 pt, so pt = px × 0.688, not ÷2 — every
   tap landed at 73 % of its target (a control chip missed the same way). Fixed in
   memory; no code was wrong.
2. **The organic run died at core's validation** (screenshot 21:07): `organic
   requires "intent": "aesthetic", stated explicitly (this job says nothing)`. The
   app never wrote `grading.intent`. Fixed: `LatticeSpec.stageMode` mirrors the
   stage's Structural/Aesthetic choice and the organic block emits `intent` from
   it (`"aesthetic"` runs; `"structural"` travels as the stage's own word so core's
   refusal stays faithful; a non-organic job still emits no `intent` — bar U1).
   Test: `LatticeWizardOrganicChipTests` (positive, structural, and no-key controls).
3. **Core makes organic AESTHETIC-ONLY** (`run_job.cpp refuse_organic_structural`:
   one cubic tensor per topology, none measured for traced struts). So Q1 is not
   an app choice: under a Structural stage the Organic chip is now DISABLED with
   that reason as its caption. His item (1) "Structural shows only true lattices"
   cannot arise inside Organic — it must be his call whether Structural+Organic
   should instead flip the stage to Aesthetic.
4. **"In the part" was showing BOTH sections** (screenshot 21:12): the octet Cell
   size / Density / Finish rows above the organic block. Fixed: under Organic the
   stage's three rows are dropped and `organicRow` carries them.
5. The results screen's Lattice entry is BLOCKED for on-device runs (same "re-run
   on a Mac worker" refusal as Smooth) and the blocked Smooth caption pushes the
   Lattice chip OFF-SCREEN to the right on portrait 13" (Smooth's VStack is up to
   260 pt wide). Not touched tonight — the lattice stage is reached from the
   workspace's top-right "Lattice" chip → "Settings"; noted for QA.
6. Two iPads were booted; `screenshot`/`tap` without `udid` go to the OTHER one.
   Always pass `udid`.

7. **After the rebuild (dylib `f49df957ac923314`, 21:30) the captured job document**
   (`lattice_job.json`, copied while it existed) carries
   `grading: {algorithm: organic, intent: aesthetic, topology: octet, cell_mode: swept,
   cell_min 5.5 / cell_max 6, min_extrudable_width_mm 0.45}` and
   `lattice.emit_organic_spans: true`, `loads.layer_height_mm: 0.2`. The run passed
   core's validation (it died there at 21:07; at 21:34 it was 2:26 into the solve).
   NOT in the job: `organic_shape_fit` — the wizard forces it in the model, but
   `project.json` still has the 20:56 mtime after Save & Exit, so persistence of the
   forced pick is an OPEN question (check the project store's write path).
8. `LatticeWizardOrganicChipTests` first SKIPPED silently: the guard used
   `latticeSchemaAccepts` (the lattice-block probe) on a GRADING key. A skip reads
   as green in a filtered run — read the "skipped" count, not the exit code.
9. **Three on-device organic runs, three different endings — all core's own words:**
   - run #1 (21:07, no `intent`): refused at validation — fixed in the app.
   - run #2 (21:37, `intent` present, no shape-fit because Save & Exit had not
     persisted): passed validation, solved, refused at the PRINTABILITY gate —
     "17 raster cells (0.627 mm³, 2 regions) would be extruded into open air at
     0.2 mm; 7343 support legs added, 607 spans cut; these defeated both. Set
     `require_no_midair_start: false` or change geometry." The app exposes NO such
     key — whether to offer "export anyway" is HIS call.
   - run #3 (21:49, persisted picks incl. `organic_shape_fit: true`): passed the
     printability gate (!) and was refused at the EXPORT guard — "5 of 237,996
     lattice vertices lie OUTSIDE the solid shell, worst by 0.0318 mm at
     (25.947, −48.942, 14.680), interior strut pass, allowance 0.0001 mm." A core
     clip-vs-shell escape on the shape-fit path — the strut-clip family, not the
     Organic algorithm, and not touched tonight.
10. **Core's span export works on his real part.** The SAME job bytes as run #2,
    replayed on the Mac with `topopt-cli lattice-variant` and the gate off:
    `variant_024_lattice_SPANS.txt` = 1240 SEG lines, 783.28 mm recomputed from the
    file, radii 0.430–2.052 mm; `run_info.json grading.organic.span_count = 1240`,
    `span_length_mm = 783.27785`, `length_survival = 0.130`, `tensor_out_of_regime =
    true`. Receipt and file agree — the §10 check, done by hand on real data.
11. **The receipt read the wrong level.** `OrganicRunReceipt(info:)` read
    `grading.span_count`; core writes `grading.organic.span_count` (every organic
    field is nested). On a real run the receipt was EMPTY and the "PREVIEW DOES NOT
    MATCH THE RUN" guard could never fire. Fixed (nested first, flat fallback) and
    pinned with the replay's numbers; the original test had built a flat dictionary
    and so passed against the broken reader.
12. Restored his `project.json` from the session backup (`BACKUP2`, sha `d6d1d335…`)
    into the current data container after the runs; the app was relaunched to the
    project list.
14. **CORE TASK, REPORTED NOT FIXED (reviewer §4b): the 0.0318 mm shell escape under
    shape fit is a real traced-path bug.** Measurement site: the per-element observer in
    `run_job.cpp` (~2136–2190) records `max_out` per pass into `oc.max_protrusion_mm`
    with `worst_protrusion_pass` ("interior strut" here — organic feeds the same
    observer as octet); the guard at `run_job.cpp:5597` refuses when
    `max_protrusion_mm > protrusion_allowance_mm` (0.0001 mm on an ordinary run).
    On run 3 (organic, `organic_shape_fit: true`): 5 of 237,996 vertices out, worst
    0.0318 mm at (25.947, −48.942, 14.680). Where organic ENDS are clipped to the shell
    before emission was not traced; open whether the shape-fit pull moves an end past
    the clip or a capsule cap is unclipped.
15. **Reviewer §3 — components, reported not changed.** `kOrganicStrandedKeepFraction
    = 0.02` kept 5 pieces on a 2-region part (receipt: `emitted_components 5`, largest
    45.2 % of 783.28 mm, `emitted_stranded_length_mm 429.3`, 8 components / 115.1 mm
    dropped). An endpoint-exact union over the SPANS file (no capsule overlap) splits
    finer — 30 pieces: 335.0 / 184.7 / 132.8 / 50.3 / 13.3 mm then 25 pieces under
    13 mm — so the receipt's 5 are welded-overlap components, not shared-endpoint
    ones. Keep-by-fraction vs keep-by-attachment is the maintainer's decision.
13. OPEN (QA): the organic pane showed "Cell size · Auto·grade" lit while both captured
    jobs carried the OCTET's window — `cell_mode: swept, cell_min 5.5, cell_max 6` —
    inherited from the project's earlier octet settings. `organicCellIndex` reads
    `model.cellSizeMode == .auto` for index 0; the display and the emitted
    `cell_mode` need one source of truth under Organic (what should "Auto·grade"
    write — `cell_mode: auto`? — is a mapping question for the spec's item 1).
