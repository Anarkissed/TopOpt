# Organic lattice in the Lattice Stage UI — handoff (in progress)

**Branch:** `claude/topopt-lattice-preview-holes-5ab466` (merged `origin/main` @ PR 353 at `de96877d`)
**Last green commit:** `dbcb356e` (settings, keys, gates, wizard row — 7/7 tests)
**Everything after it is UNCOMPILED at the time of writing** — the SwiftPM lock was held by the
full lattice suite for the whole session. Read §4 before trusting anything below it.

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
