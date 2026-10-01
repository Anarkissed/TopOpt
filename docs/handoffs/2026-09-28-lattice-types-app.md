# Handoff — 2026-09-28-lattice-types-app: lattice types round 1, app track (A0 + A1, and the review's one fix)

2026-10-01, PR #354's branch. App only: no file under `core/` was edited. The spec is
`docs/design/lattice-types/03-app-spec.md`; the decisions are `00-decisions.md` (M1–M8, R1–R12).

## In plain words

- **What you can pick now: the Octet truss only, the same as before.**
  - Core can build only octet.
  - It can certify the six strut types this round adds (SC, BCC, FCC, Diamond, Kelvin, Rhombic
    dodecahedron), but not build them.
  - Its job parser also still refuses any type but octet.

  So no new type is live yet, and none can be offered. That is correct, not a failure: core's
  handoff says K1 starts with FCC.
- **What changed on screen:** both pickers now show **every** type, in this round's order:
  - Octet first;
  - the six struts;
  - Gyroid and Schwarz-D;
  - then BCC + Z, FCC + Z and Re-entrant.

  Each greyed type says why, from core's own facts:
  - "Core can't build this type yet." covers the six struts;
  - "Core can't build or certify this type yet." covers the sheets and the three tetragonal types.

  Where you read the reason:
  - **On the Lattice stage**, tap a greyed chip to read its reason.
  - **On the variant page**, each greyed row carries a mark and a footnote, and it can no longer
    be picked. Before, any certifiable row could be.
- **A project saved with a type core can't run now says so.** The review found this, and it
  predates this task.
  - **Before:** the variant page's old list let anyone pick, say, Simple cubic. That project's
    Optimize then ran with no lattice and said nothing, and "Lattice" failed on a message that
    never named the type.
  - **Now:** both buttons grey with "Simple cubic: Core can't build this type yet." and a chevron.
    The tap opens Settings, where the same line already shows and Octet truss is one tap away.
    This works under Organic too.
  - **Your projects:** none of the seven in your store has such a type; all are octet. Nothing
    you have changes.
- **The moment core makes a type live, it lights up by itself**, as long as core's job parser
  accepts it too. A test fails by name when that happens, so the per-type preview work (A2) starts
  then.
- **What to print:** nothing new yet. The "Not print-tested" tag and its sheet need core to
  publish print status, and core has no loader for it yet.
- **Three things need your ruling.** All three are under "## Blocked" below:
  - the run never received the preview's packed cells;
  - the octet ceiling's source;
  - Stepped under Structural.
- **Core moved after my sync.** #358 is now at 4764ca7e (2026-10-01 01:54). Its message says no
  type goes live. It moves the job's topology gate to "can build AND can certify". It also writes
  core's own plain-language reason for each type, which answers this branch's brief item (a).
  - I did not merge it: the task syncs on "sync core" or before starting a type.
  - On the next "sync core", the app bridges core's reason and drops its own wording.

## Task

TASK 2026-09-28-lattice-types-app, round 1, the app track:
- light each type up as core makes it live;
- mark the types he hasn't printed;
- draw each type exactly as core builds it;
- grey out, with core's reason, the options a type can't use.

## What I did

### Branch and sync (steps 1–6)

| | commit | what |
|---|---|---|
| merge main | **5087b9be** (main at **f932266f**) | Brought in #360 (the lattice-types pack and DECISIONS entry) and #359 (the maintainer's **Flexible reference pack**: docs, seed data, papers and one `core/src/materials/flexible_curves` file). The task orders this merge, so it lands here despite the standing "never merge Flexible" rule. It is the maintainer's pack, not the Flexible agent's code. |
| merge #358 | **19a1443b** (#358 at **4a1ccc45**) | One way, no conflicts. Since the previous sync (7793ee0f), core changed only data files. |
| rebuild | `app/scripts/build_core.sh` | Linked core fingerprint **19a1443bee65**. |
| core ctest | own build dir, core at 19a1443b | 131/131 passed (raw text below). |

**Probes that flipped:** `docs/handoffs/evidence/2026-09-28-lattice-types-app/probes_flipped.md`.

- **Flipped at the first link of #358** (74e510c4, 2026-09-28), never reported until now:
  - `coreCarriesTheSampleRepairFix`, `steppedStructuralCertificationWired` and `regionFrameAxesWired`;
  - the grading keys `max_relative_density`, `shape_grade`, `shape_grade_band_mm`,
    `stepped_min_tile_mm` and `structural_certification`.
- **Flipped off:** `organic_overhang_fillet`. Its toggle was removed in 026904dd.
- **Found broken: `steppedCellsWired` is false on every core**, by its own construction (see
  Blocked 1).
- `LatticeCoreProbeReportTests` pins every value, so the next sync that flips one fails by name.

### A0: the octet-only inventory, before any code (U3)

`docs/handoffs/evidence/2026-09-28-lattice-types-app/app_inventory.md`: **237 rows**, each read at its
file:line.
- 52 in the preview (raymarch, octree bake, sample patch, density proxy);
- 80 in settings, types, cells, posture and the wizard;
- 86 in everything else (workspace, page, receipts, runners, the bridge);
- 19 from the completeness critic.

Each row says where its number must come from once a type is live (02-core-spec §5), or that it is
already from core, or that it stays.

The single largest hazard: **`LatticeType.named()` silently returns octet** for any id it doesn't
know (kelvin, rhombic, gyroid, schwarz_d, reentrant). Several "already from core" calls pass that
LatticeType's `.id`, so a Kelvin project would get octet's band.

No row changes behaviour today: with no type live, every path still runs octet.

### U1 + U2: the offered set from core, every type visible (25fc32ce)

- **`LatticeTypeCatalog`** (new, `Sources/TopOptFlows/LatticeTypeCatalog.swift`): one definition
  for both pickers.
  - **Offered** = core can build it (`lattice_gen_topology_names`) **and** certify it
    (`lattice_certifiable_topology_names`; M6: Aesthetic still certifies) **and** core's job parser
    accepts it.
  - **The parser check** is `TopOptKit.jobSchemaAcceptsTopology`: two whole-job parses through
    core's own schema (the lattice block and the grading block), with octet as the control, memoised.
    So a type core lights up is offered only with a job that will run.
  - **The reason** is worded from which of core's facts is missing (brief item a, until core
    publishes its own).
  - **A type core adds** that the list doesn't know yet still shows, after the round's.
- **Order** (03 §2, M4): octet, sc, bcc, fcc, diamond, kelvin, rhombic, gyroid, schwarz_d, bccz,
  fccz, reentrant.
- **Names** (Q5 defaults): `LatticeType.displayName(forID:)` gives Simple cubic, BCC, FCC, Diamond,
  Kelvin, Rhombic dodecahedron, Gyroid, Schwarz-D and Re-entrant first. Octet truss, BCC + Z and
  FCC + Z come from the family.
- **The Lattice stage's Type row** reads the catalog. A greyed chip, tapped, shows its reason in one
  line under the row and never selects.
- **The variant page's topology pane** reads the same catalog:
  - one footnote per distinct reason, marked *, †, …;
  - a greyed row can't be picked (before, any certifiable row could be).

### The review's fix: a saved type core can't run (b38aa074, pins ccae13ce)

A read-only adversarial review of the diff (15 agents) confirmed one defect and refuted eleven
claims. The defect predates this task, and it is low severity.

**The defect.** The variant page's old pane wrote any certifiable id unguarded, so a saved project
can carry "sc". `LatticeSettings.runSpec` is nil for a type core can't build, so that project's run
had **no lattice block**:
- Optimize ran the part bare and said nothing;
- "Lattice" failed on core's "lattice_part requires a lattice block".

**The fix:**
- **`LatticeTypeCatalog.selectionRefusal(id)`:** nil when the type is offered, else
  "<Name>: <reason>". An id core doesn't know reads "neither built nor certified", never octet.
  `reasonLine` is the sentence's one home; the chip tap uses it too.
- **Workspace:** Optimize and Lattice refuse on the button (`latticeOptimizeRefusal` /
  `latticeStageRefusal ?? latticeTypeRefusal`). This covers Organic too, because the topology
  still rides the job. The button is greyed with a chevron, and its tap opens Settings.
  - The tap is navigation only: no type is picked for him.
  - This is a different condition from "nothing set to lattice", so it has its own words (ruling (b)).
- **Wizard:** the Type row shows the line **at once** for the saved type, not only when a greyed
  chip is tapped. The offered chip stays live as the fix. Under Organic, where the chips are
  otherwise greyed, that chip stays live too: it puts the octet back and leaves Organic on.
- **Never migrated:** the pick stays his, and it runs by itself once core lights the type.

### Per-type status (linked core 19a1443bee65)

| type | build | certify | job parser | offered | reason shown |
|---|---|---|---|---|---|
| Octet truss | yes | yes | yes | **yes** | — |
| Simple cubic, BCC, FCC, Diamond, Kelvin, Rhombic dodecahedron | no | yes | no | no | Core can't build this type yet. |
| Gyroid, Schwarz-D | no | no | no | no | Core can't build or certify this type yet. |
| BCC + Z, FCC + Z, Re-entrant (M1) | no | no | no | no | Core can't build or certify this type yet. |

**Parity (U4):** none to report. No type besides octet is live, and octet's preview is unchanged.

### Screenshots

All three are rendered from the app's own views, in `docs/handoffs/evidence/2026-09-28-lattice-types-app/`:
- `picker_type_chips.png`: the Lattice stage's Type row, every type, octet lit, plus the reason
  lines two greyed chips show when tapped.
- `picker_topology_pane.png`: the variant page's topology pane with its two footnotes.
- `stale_saved_type.png`: a project saved with Simple cubic. The Type row lights it greyed and
  says why at once, with Octet truss live beside it. Lattice and Optimize are greyed in the same
  sentence with the chevron.

These are offscreen renders, not simulator screenshots. I install only and never drive the
simulator, and none of his projects is in the stale state. So the fix has **no simulator
evidence**; its evidence is the tests and the render.

### Octet hash (U8): the stage job, byte for byte

SHA-256 (first 16 hex) of each P1 store project's `lattice_part` job. The dump is
`LatticeJobJSONDump`, run with **SWIFT_DETERMINISTIC_HASHING unset**. P1 is a read-only copy of
his store taken 2026-10-01.

| project | before the task (p1f) | after U1 (lt1) | after the fix (lt2, b38aa074) | final (lt3, ccae13ce) |
|---|---|---|---|---|
| 92A8016E "l bracket 3" (**octet**) | 225865c83c64cb23 | 225865c83c64cb23 | 225865c83c64cb23 | **225865c83c64cb23** |
| 68BF7B74 the stand (M2) | 3fd5d1b2388fe949 | 3fd5d1b2388fe949 | 3fd5d1b2388fe949 | 3fd5d1b2388fe949 |
| 102117B9 | 3f19f920e5c96a5a | 3f19f920e5c96a5a | 3f19f920e5c96a5a | 3f19f920e5c96a5a |
| 3418E167 | 6cd09b2c12c57614 | 6cd09b2c12c57614 | 6cd09b2c12c57614 | 6cd09b2c12c57614 |
| 570B38E2 | 43a0828a8bbb1e1d | 43a0828a8bbb1e1d | 43a0828a8bbb1e1d | 43a0828a8bbb1e1d |
| 887AC498 | b457718dfc23ab42 | b457718dfc23ab42 | b457718dfc23ab42 | b457718dfc23ab42 |
| AA4C7953 | 3e6f162cb36212a9 | 3e6f162cb36212a9 | 3e6f162cb36212a9 | 3e6f162cb36212a9 |

No job byte moved. Organic is untouched: no organic job, preview or result path was edited.

### Core briefs (U9)

`docs/handoffs/2026-09-28-core-brief-lattice-types-app-needs.md` lists only what 02 §5–§6 do not
already plan:
- **(a)** a reason per type;
- **(b)** one complete id list (sheets included) and one name table;
- **(c)** the job parser accepts each type it makes live;
- **(d)** print status through the bridge;
- **(e)** "no ceiling", stated;
- **(f)** the sheets' per-region cell and anchor keys;
- **(g)** a way to detect `lattice-sample`;
- **(h)** a per-type "strut strength measured" flag;
- **(i)** Stepped under Structural, for core and the maintainer;
- **(j)** optional: the frame basis at parse time.

Since then #358's 4764ca7e answers **(a)** (`lattice_type_readiness`, a plain line per state) and
**(c)** (`require_live_topology`). Both arrive at the next sync.

### Last synced commits

- **main:** f932266f, merged at 5087b9be. Unchanged since.
- **#358:** 4a1ccc45, merged at 19a1443b. **#358 has since moved to 4764ca7e; not merged** (see
  above).

## Test evidence (raw, pasted, unedited)

**The full app suite, once, at b38aa074** (`swift test`, every test; 2:48 → 5:45, load 7–12; `suite_lt.log`).
Every failing test case, then the summary:
```
'-[TopOptFlowsTests.AppModelTests testReopenedThreeMFProjectReimportsTheStlWorkingCopy]' failed (0.468 seconds).
'-[TopOptFlowsTests.AppModelTests testThreeMFImportNormalisesToStlWorkingCopyAndKeepsProvenance]' failed (0.002 seconds).
'-[TopOptFlowsTests.AppModelTests testThreeMFImportOptimisesOnDeviceEndToEnd]' failed (0.001 seconds).
'-[TopOptFlowsTests.LatticeCellGradingTests testGradingChangesTheRenderedLattice]' failed (10.314 seconds).
'-[TopOptFlowsTests.LatticeSimSolveTriggerTests testTheTriggerRefusesOnAllThreeGrounds]' failed (0.010 seconds).
'-[TopOptFlowsTests.LatticeWizardOneLineCaptionTests testOnlyTheOctetTrussIsOffered]' failed (0.016 seconds).
'-[TopOptFlowsTests.OrganicSampleCubeTests testThickerIsLiveAndNeverRetraces]' failed (0.003 seconds).
'-[TopOptFlowsTests.OrganicVariantCacheTests testTheKeyIgnoresThicknessAndFollowsCoreAndTopology]' failed (0.002 seconds).
'-[TopOptFlowsTests.VariantRetentionTests testTheOptimizeButtonRoutesThroughTheConfirmation]' failed (0.026 seconds).
	 Executed 2653 tests, with 46 tests skipped and 15 failures (0 unexpected) in 10618.984 (10619.201) seconds
SUITE-EXIT 1
```
Nine failing tests:
- **Pre-existing, the known 7** (round 2's suite, 2625 tests, failed exactly these, at the same lines):
  - AppModelTests 3MF ×3: this build has no lib3mf;
  - LatticeCellGradingTests.testGradingChangesTheRenderedLattice;
  - LatticeSimSolveTriggerTests.testTheTriggerRefusesOnAllThreeGrounds (LatticeStressTintTests.swift:195,
    "…and otherwise it actually runs");
  - OrganicSampleCubeTests.testThickerIsLiveAndNeverRetraces;
  - OrganicVariantCacheTests.testTheKeyIgnoresThicknessAndFollowsCoreAndTopology.
- **Mine, 2: source pins b38aa074 broke, fixed in ccae13ce:**
  - `VariantRetentionTests.testTheOptimizeButtonRoutesThroughTheConfirmation` reads the first 400
    characters of `optimizeButton`. The added lines pushed `requestRun()` to offset 501. The
    decision now sits in one helper both buttons share (`opensLatticeType`): offset 311.
  - `LatticeWizardOneLineCaptionTests.testOnlyTheOctetTrussIsOffered` pinned the chip's old reason
    string and `.disabled(organicOn)`. It now pins `reasonLine` with its sentence asserted, and
    `.disabled(inert)`.
  - My targeted run had missed both, because neither class was in it.

**After the pin fix, at ccae13ce:** every test class that reads `WorkspacePlaceholder.swift`,
`LatticeSetupWizard.swift` or `LatticeTypeCatalog.swift` (59, found by grep), plus
`LatticeStaleTypeTests`, `LatticeTypeCatalogTests`, `LatticeWizardOneLineCaptionTests`,
`VariantRetentionTests` and `LatticeCoreProbeReportTests`:
```
AppModelTests testReopenedThreeMFProjectReimportsTheStlWorkingCopy
AppModelTests testThreeMFImportNormalisesToStlWorkingCopyAndKeepsProvenance
AppModelTests testThreeMFImportOptimisesOnDeviceEndToEnd
LatticeSimSolveTriggerTests testTheTriggerRefusesOnAllThreeGrounds
	 Executed 541 tests, with 6 tests skipped and 9 failures (0 unexpected) in 328.894 (328.937) seconds
```
Only known failures remain. The ccae13ce change moves a comment and adds a two-line helper, so I
did not run the full suite a second time. The iOS simulator build succeeded at ccae13ce.

**Core ctest** at 19a1443b, own build dir (`lt_ctest.log`, tail):
```
129/131 Test #117: design_stream ....................   Passed  315.05 sec
130/131 Test #126: protect_freeze_vs_solidity .......   Passed  385.60 sec
131/131 Test #115: cli_demo .........................   Passed  2529.71 sec

100% tests passed out of 131

Total Test time (real) = 2784.67 sec
CTEST_EXIT 0
```
This is **131 locally, not CI's count**: `lib3mf_DIR:PATH=lib3mf_DIR-NOTFOUND`, so
`export_3mf` and `threemf_import` did not register.

**Targeted runs at b38aa074** (these missed the two pins above):
```
LatticeStaleTypeTests|LatticeTypeCatalogTests|LatticeIncludeGateTests|LatticeTypesEvidenceGen
	 Executed 20 tests, with 0 failures (0 unexpected) in 6.806 (6.808) seconds
```

**RED controls.** Each mutation was made, built, run, seen red, then restored from a snapshot.
- **U1 (25fc32ce):**
  - the job-parser check removed → the catalog offers a type whose job dies;
  - certification alone made sufficient;
  - the page's `guard e.offered` removed.

  Each failed its test.
- **The fix (b38aa074):** three mutations at once, each caught by its own test.
  - The stage's `?? latticeTypeRefusal` removed. `canLatticeThis` stays true for a stale type, for
    octet and for organic, and the source pin fails.
  - The at-once line reverted to `typeReason` only. The pin fails.
  - The unknown-id reason returned nil. The "lattice9" assertion fails.

  The result: 5 failures in 4 tests. Restored, then 20/20 green.

CI run: <maintainer fills after push>
PR: #354

New tests added:
- `LatticeCoreProbeReportTests` (d3ef10cf): pins every core-capability probe's value on the linked
  core, and proves `steppedCellsWired` is broken (its own document is refused; the same document
  without lattice `cell_mm`/`strut_radius_mm` parses).
- `LatticeTypeCatalogTests` (4):
  - the order and names;
  - offered = build ∩ certify ∩ the job parser, with each reason;
  - the linked core offers the octet alone (fails by name when core lights a type);
  - both pickers read the one catalog and neither picks a greyed type.
- `LatticeStaleTypeTests` (5):
  - the mechanism: `latticeRunSpec` is nil for "sc", with an octet control, organic and not;
  - the refusal equals the catalog for every id, including an unknown one;
  - the stage's Lattice is refused for a stale type;
  - both buttons refuse, and the tap only navigates;
  - the Type row says it at once, and the offered chip is the fix under Organic too.
- Re-pinned:
  - `LatticeWizardOneLineCaptionTests.testOnlyTheOctetTrussIsOffered` now reads core's set;
  - `LatticePageRound2Tests.testTopologyListShowsOneFootnoteNotPerRowBadges` now expects one
    footnote per distinct reason.
- `LatticeTypesEvidenceGen` (opt-in, `TOPOPT_LATTICE_TYPES_EVIDENCE=1`): the three PNGs.

## What I did NOT do

- **No type was lit (A2/A3).** None is live in core.
- **U4, parity.** Nothing to compare.
- **U5, options per type.** These need 02 §5's facts struct through the bridge; none exists yet.
- **U6, sheets.** No field, sampler or `tpms.hpp` in core yet.
- **U7, receipts.** The names are ready (`displayName(forID:)`). The tag and the directional note
  have nothing to say until a type is live.
- **The "Not print-tested" tag and its sheet (M2).** Core has no print-status loader (brief d).
  4764ca7e adds only a design note for it (`k4_print_tests_loader_constraint.md`).
- **The directional note for SC and BCC (R3).** It shows "when selected", and neither can be
  selected yet. It lands with their go-live.
- **The 237 inventory rows.** I changed none: each is fixed in the sync that lights its type.
  - `LatticeType.named()`'s octet fallback stays, because every path is octet today.
  - The bridge's octet-only gates (bridge.cpp:3042, 3059, 3106, 3154) stay.
- **#358's 4764ca7e is not merged** (see "In plain words").
- **Simulator evidence for the fix.** I install only; none of his projects is in that state.
- **The variant page's Optimize** still words a stale type its old way, "Simple cubic certifies,
  but core has no geometry generator for it yet — a run can't lattice it" (LatticePageModel.swift:319).
  It always refused that type, so it never dropped the lattice silently, but it is a second
  sentence for the condition the workspace now names.
- **Found, not fixed: the same silent drop through a second condition.** A cell over core's
  cells-per-member ceiling also makes `runSpec` nil (`LatticeBounds.runnableAsCertified`,
  LatticeSettings.swift:3043). The workspace's Optimize doesn't check it; the variant page's does.
  - It is reachable only through a legacy include primitive: `regionMemberMM` reads
    `includePrimitives.first`, and no UI adds one any more (`addLatticeIncludePrimitive` and
    `placeLatticeRegion` have no callers).
  - None of the seven store projects has one.
  - Since the bridge returns core's floor of 5 (bridge.cpp:3081), it is a real gate, not the
    "advisory" its comment at LatticeSettings.swift:2327 says.

## Warnings for the next run

- **On "sync core" (4764ca7e and later):**
  - bridge `lattice_type_readiness` and show core's plain line in place of the four worded reasons
    in `LatticeTypeCatalog`;
  - expect `LatticeTypeCatalogTests.testTheLinkedCoreOffersTheOctetAlone` to stay green: no type
    goes live there;
  - re-run `LatticeCoreProbeReportTests`.

  Core now writes the resolved topology into both job blocks and refuses two different ones. The
  app writes both from one setting (RemoteRunner.swift:758, RelatticeRunner.swift:107,
  LatticeSettings.swift:850), so nothing changes.
- **`jobSchemaAcceptsTopology` is memoised per process.** A core change needs an app relaunch,
  which always happens with a new link.
- **A targeted run must include every class that pins a source file you touched.** Grep
  `Tests/TopOptFlowsTests` for the file's name. `WorkspacePlaceholder.swift` alone has 59 classes
  reading it, some through a fixed character window (VariantRetentionTests reads 400 characters).
  Mine missed two, and the full suite caught them.
- **`swift test` rewrites other tasks' evidence** under `docs/handoffs/assets/` and `evidence/`.
  I restored them before committing. Do the same.
- **Stage-hash dumps:** run them with SWIFT_DETERMINISTIC_HASHING **unset** (the task's
  condition) and compare within one snapshot. P1's stand and 3418E167 were re-saved at
  2026-09-30 23:21/23:22, so P0's hashes differ for reasons unrelated to code.
- **The aesthetic ceiling:**
  - 4764ca7e's `lattice_aesthetic_density_ceiling(topo)` returns octet's 0.218871 exactly and throws
    for every other type;
  - the app's Swift value comes from a 24-step bisection at the project's cell;
  - taking core's value is Blocked 2.

## Blocked

These are three decisions for the maintainer. Each one moves octet job bytes or concerns preview vs
run, which the task forbids me to decide.

1. **The run never receives the preview's packed cells.**
   - `steppedCellsWired` puts lattice `cell_mm`/`strut_radius_mm` beside a grading block, which
     core refuses as a pair, so it is false on every core.
   - So **the app has never sent `lattice.stepped_cells`**, and Stepped and Default Grade runs use
     core's own planner, not the preview's plan. That is an M5 gap.
   - Fixing the probe adds `stepped_cells` to every Stepped or Default Grade octet job with a baked
     plan: an octet byte move.
   - **Decision:** fix it, and record new hashes for those projects, or leave it?
2. **The octet aesthetic ceiling's source (R12 vs R9).**
   - R12 says take it from core: 0.218871, a 200-step bisection at a 4 mm cell.
   - The app re-derives it in Swift: 24 steps at the project's cell (LatticeType.swift:269-276).
   - Switching changes the digits of `max_relative_density` in every graded octet job.
   - **Decision:** switch, with new hashes, or keep the app's digits?
3. **Stepped / Default Grade under Structural (core brief item i).**
   - Since #358 linked, the preview sizes their cells at the beam-network floor (2 cells per member,
     not 5).
   - The run certifies the beam network only for organic (run_job.cpp:7488, call at 7587). Core
     refuses the key for Default Grade, and the app sends it for Stepped only.
   - So the preview's Structural cells can be about 2.5x coarser than the run's homogenised
     certificate supports.
   - **Decision:** core runs the beam network for Stepped, or the preview goes back to the
     homogenised floor?
