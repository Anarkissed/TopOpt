# Organic lattice in the Lattice Stage UI — handoff (in progress)

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
