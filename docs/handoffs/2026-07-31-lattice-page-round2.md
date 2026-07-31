# Lattice page round 2 — maintainer UI feedback, and ONE selection system

**Date:** 2026-07-31 · **Branch:** `claude/lattice-page-round2-ui-14c772`
**Base:** main at 4b53386 (after PR 259).
**Scope:** `app/` (+ `tools/topopt-worker/e2e/real_cli_smoke.py` for the M3 CLI
probe). **Core untouched** — the regions schema this task consumes is PR 256's.
**Evidence:** `evidence/2026-07-31-lattice-page-round2/`

## THE HEADLINE: ONE selection system (items 18/22/23 → L18/L22/L23, bars M1/M2)

The lattice page's second selection UX is GONE — the regions accordion, the
paint pane, the primitive pane, and the Paint/Regions chips are all deleted.
"Regions & faces" now opens **the workspace's own `selectionsPanel`** — the SAME
view definition, mounted over the page, iterating the SAME
`ProjectModel.selection` (`WorkspacePlaceholder.swift` mounts it twice, gated by
context; `LatticePageRound2Tests.testLatticePageSourceHasNoSecondSelectionUI`
asserts exactly one definition exists and that `LatticePage.swift` builds no
selection model of its own).

**How the pieces landed:**

* **L22 — roles ride the TO page's groups.** `LatticeGroupRole` (include |
  exclude) is stored as `LatticeSettings.groupRoles: [UUID: LatticeGroupRole]` —
  an id-keyed ATTRIBUTE over the one `SelectionModel`, the exact `KeepClearAffix`
  precedent. The group object never moves or copies; renaming it on the TO page
  is instantly visible in the lattice context because there is nothing to sync
  (M1 test proves both directions). In the lattice context every group row grows
  a two-chip role control ("Lattice here" / "No lattice"; tap the lit chip to
  clear). "+ primitive" works on a role group and the primitive becomes a
  lattice REGION (below).
* **L23/M2 — non-destructive by construction.** While the library is open over
  the page, model taps route through the new pure `LatticeLibraryTap` (NOT
  `WorkspaceTap`): an owned face — active or not — only SELECTS its group
  (no tap-again-to-deselect, no steal); a free face grows the active group
  (only unowned faces are ever added, so a steal is impossible); the trash
  button is not rendered in the lattice context. `testNoLatticePageInteraction-
  CanRemoveATOFaceOrGroup` walks every lattice-context mutation (owned tap,
  repeat tap, cross-group loop tap, role set/clear, primitive add, free-face
  grow) and asserts no group and no face is ever lost.
* **M1 — one model, proven.** `testLatticePageRendersFromTheSameGroupModelAsThe-
  TOPage`: role assignment moves/copies nothing; a TO-side rename is seen by the
  lattice-side derivation with no sync step; a lattice-side tap activates the TO
  page's own group; and `LatticeSettings` is reflected over to prove it holds NO
  group/SelectionModel-typed storage (a second store is the diverge-later
  failure mode the bar names).

### The regions now REACH THE JOB (M3, + the stale copy)

`LatticePage.swift:826`'s claim ("core's schema carries no region yet",
"exclude PRIMITIVES have no job field yet") was false since PR 256 and is
deleted along with its two sibling restatements. The emission it denied now
exists:

* `LatticeRegionSpec` — the exact wire shape of `lattice.regions[]` (role,
  kind, bolt `axis_point/axis_dir/radius_mm/half_length_mm`, face
  `origin/normal/half_u_mm/half_w_mm/depth_mm`; `isValid` mirrors core's
  "every extent > 0, direction non-zero" so a refusable entry is never emitted).
* `LatticeRegionEmission` (new, pure): role groups' **manual primitives** map
  1:1 (the primitive IS the region — zero margins, matching PR 256's
  `resolve_clearance_manual` semantics); role groups' **B-rep faces** are
  synthesised from their exact geometry (cylinder → bolt over its real axial
  span; plane → face slab with the outward normal FLIPPED so the slab reaches
  INTO the part, depth = the page's new "Region depth" control, which is the
  emitted `depth_mm`); the **legacy include primitives** emit as role=include.
  Faces with no usable B-rep surface are skipped AND counted.
* `ProjectModel.latticeJobRegions()` resolves slab depths through the same
  `clearanceMetric` chain the chips and volumes read (run == picture == chips),
  `LatticeSettings.runSpec(regions:)` carries them, and `RemoteRunner` emits
  `lattice.regions` beside `skin` using the manual-clearance geometry encoder
  plus the lattice-only `depth_mm`.
* **Precedence guard:** a role group's manual primitives LEAVE
  `loads.clearances` while lattice is on (region ≠ keep-out; never both), and
  with lattice OFF roles are inert — clearances unchanged, no regions emitted,
  so the TO-only job stays byte-identical whatever roles are stored
  (`testRoleGroupPrimitivesLeaveClearancesAndJoinRegions`;
  `testTOOnlyJobByteIdenticalByHash` still green).
* **Core parses it, twice over:** `testCoreCLIParsesTheEmittedRegions` runs the
  REAL locally-built `topopt-cli` on the app-serialized job and asserts the
  failure is model import, never a schema rejection (ran live, not skipped);
  `tools/topopt-worker/e2e/real_cli_smoke.py`'s representative job now carries
  an include + exclude region (smoke re-run: OK). Artifacts:
  `job_with_regions.json` + `cli_parse_output.txt` in the evidence dir.

**Blocked-stop not needed:** unifying did NOT require restructuring
WorkspacePlaceholder — the lattice page always was an overlay inside it, so the
unification is literally mounting the existing panel in a second gate, plus
context conditionals inside `groupRow`.

## Bugs — root causes (bar M7; none hidden, none worked around)

* **T5 (move icon renders a second primitive).** Root cause: the panel's
  primitive listing (`clearancePrimitives`) did not apply the suppression
  filter the renderer (`resolvedClearances`) and the run (`clearanceSpecs`)
  both apply. The move icon on an auto keep-clear row calls
  `convertAutoClearanceToManual`, which adds the manual primitive AND
  `suppressClearanceFace(f)` — renderer and run correctly showed ONE keep-out,
  but the panel listed the dead auto row PLUS the manual row: a second
  primitive where only one exists. Fix: one shared listing rule,
  `ProjectModel.listedClearanceFaces` (bore-or-explicit ∧ not-suppressed ∧
  has-geometry), consumed by the panel, the sync-coupling face list and the T2
  reveal. `testConvertingAnAutoClearanceListsExactlyOnePrimitive` pins
  listing == run == picture == 1 after a convert.
* **L6 (RUN SIM behind the position gizmo).** Root cause: `orientationGizmo`
  was the ONLY piece of workspace chrome not gated behind `!showLatticePage`
  (WorkspacePlaceholder body, the old line 386), and its Metal-backed glass
  (an MTKView/CAMetalLayer inside a UIViewRepresentable) composites over the
  page's pure-SwiftUI chrome regardless of ZStack order — so the page's RUN SIM
  drew behind a gizmo that was never supposed to be there ("one set of controls
  at a time" is the page's own rule). The page even carried a 130 pt
  trailing-padding dodge admitting the overlap. Fix: the gizmo is now gated
  like all other chrome, and the dodge is deleted (RUN SIM sits in the true
  corner). Not a z-index nudge — the stray mount was the defect.
* **L21 (invisible primitives — device rounds 8/9, never fixed).** The task's
  hypothesised mechanism (face-plus-margin sizing under render tolerance) is
  NOT what it was. Actual root cause, two layers:
  1. a fresh primitive spawns at the **model bounding-box centre**
     (`ProjectModel.addManualPrimitive`: bbox centre, sized off the bounding
     radius) — i.e. **inside the solid** — and the clearance-volume pass is
     depth-tested (`MetalMeshView` "MODEL-space depth-tested pass"), so a
     buried volume was fully occluded by the opaque body: it rendered as
     nothing at all;
  2. the lattice page's include primitives had **no volume render path
     whatsoever** — only the gizmo glass, nothing showing the primitive's own
     extent.
  Fix: (1) a new **x-ray edge pass** — the clearance tessellator also builds a
  low-alpha edge buffer drawn depth-ALWAYS, so a buried primitive reads as a
  ghost wireframe wherever it is (visible part unchanged: the solid pass still
  draws on top of it); (2) include primitives and role-group primitives render
  through the same `ClearanceVolume` path, tinted the density ramp's indigo
  family (include mid-violet, exclude deep indigo — `ClearanceRenderItem.tint`,
  nil ⇒ the old red, so plain keep-outs are pixel-identical).

## TO page (T-items)

* **T1** — the Lattice chip became a 64 pt-tall button (Optimize's stature),
  top right, LEFT of the position gizmo (offset by
  `OrientationGizmoView.standardSize`). Gated by the new pure
  `LatticeEntryButtonGate` on gravity ∧ anchor ∧ load, and the sub-line SAYS
  what is missing ("needs gravity and a load"), never a mute disable
  (`testLatticeEntryButtonGate`).
* **T2** — primitive chips (the locked clearance editor) now open ONLY via an
  explicit `chipsRevealedGroup` set by exactly three paths: tapping the group
  row in the library, tapping the primitive (its viewport knob / a fresh
  primitive), or tapping one of the group's own cleared faces on the model. A
  face tap that merely grows a selection no longer pops chips under the finger;
  `leaveGroupEditing` clears the reveal.
* **T3** — root cause of "can't add a face to an existing group":
  `WorkspaceTap.route` refused to grow a NON-PENDING active group, so selecting
  a committed group and tapping a free face silently started a fresh group.
  Since every production commit immediately `clearActive()`s (M7.6), a
  committed group can only BE active by explicit re-selection — which is
  exactly the "I want to edit this group" signal — so the rule is now: grow
  whatever group is active. New `testSelectedCommittedGroupGrowsOnTap`; the
  four existing fixtures that committed WITHOUT the production `clearActive()`
  gained that one line (every assertion unchanged — see "test updates" below).
* **T4** — `ForceModel.unit` defaults to `.lbs` (and pre-unit snapshots decode
  to lbs). Display-only: storage stays kgf, jobs unchanged. The lattice page's
  load readout now uses `formattedWeight` instead of hardcoded "kg".
* **T6** — the viewport move knob grew 26 → 40 pt glass (~64 pt hit target with
  its −12 pt inset); the panel's convert move icon is a real 34 pt button in a
  filled tile instead of a bare 12 pt glyph.

## Lattice page chrome (L-items)

* **L1/M4** — `LatticeChromeLayout.gap = 12` (strictly between the old 9 and
  16, per the task) with NAMED per-seam constants the view consumes; the
  portrait panel clearance derives from `edge + clusterHeight + gap` instead of
  the magic 104. `testChromeSpacingIsOneConstant` pins: every named gap == the
  token, the token's 9<gap<16 window, and the old literals (74/9/104) gone from
  the source.
* **L2** — the bottom-left "Scrub sliders…" hint capsule is deleted (with
  `LatticePageModel.hint`).
* **L3** — the modal's "PART" kicker is gone (root pane is just "Lattice");
  "Depth into part" copy replaced by the Region-depth card.
* **L4** — the panel's scroll region measures its content (preference key) and
  the panel is exactly content-tall up to the cap; landscape it sits CENTRED on
  the left edge (no stretched frame, no empty bottom).
* **L8** — cell size, density min, density max and region depth are tappable
  numbers opening the shared `NumberPad` (primitive dims already were, via the
  library's pills).
* **L9** — "Cell size" + "Density range" are ONE ladder row ("Cell & density" —
  they always opened the same pane).
* **L13** — notes are transient: `LatticeTransientNote` + post/dismiss/tick on
  the page model — top-centre capsule, dismissed by tap, by a different note,
  or after 60 s (`testTransientNoteLifecycle` drives all three rules with an
  explicit clock).
* **L14** — topology names render on ONE line; a certifiable-but-ungeneratable
  row is greyed with an orange asterisk; ONE footnote ("* the geometry does not
  exist yet") replaces the per-row badge sentence. Presentation only: the rows
  and the split still come from core's two sets (B0's test untouched;
  `testTopologyListShowsOneFootnoteNotPerRowBadges`).
* **L15** — Boundary & finish's one real question (None / Rim only / Full skin)
  is inline on the ladder; the sub-page is gone (its two explainer cards were
  restating core behaviour that cannot be configured).
* **L16** — "Review & run" left the ladder; a bottom-right **Review** button
  opens a drawer with the full settings summary.
* **L17** — the bottom-right **Preview** toggle is the ONLY preview control
  (the review pane's second toggle died with the pane; the workspace's Struts
  chip is workspace chrome, hidden under the page), plus a separate **Refresh**
  that re-bakes the strut scene + proxy with current settings.
* **L19** — the Paint/Regions/Preview chip column is deleted; the unified
  library + the bottom-right cluster supersede it.

## The overlay (L5/L11, bar M5)

* **L5** — root cause: the renderer's stress-tint channel REPLACES face
  highlights wholesale (`MetalMeshView` upload is an if/else), so the lattice
  proxy's per-vertex colours painted over every selection group.
  `LatticeDensityProxy.tints` now takes `selectionTints` (+ the paint-effective
  face ids) and composes the group colours ABOVE the density colours per
  vertex; the workspace passes `roleTints`.
* **L11** — whose bug was the missing gradient: **the app's.** Production
  always called `tints(demand: nil)` — the graded branch only ever ran in
  tests — while the app HAD graded fields on hand (the sim's, the variant's).
  The overlay's "uniform" colour was additionally a constant BY ARITHMETIC
  (uniform ρ = band midpoint ⇒ legend fraction ≡ 0.5, the same violet under
  every setting). Now: in Auto density the overlay grades from the page's own
  demand field (same source the strut preview grades from); Uniform mode stays
  deliberately flat because a uniform lattice's density IS flat.
  `testOverlayMapsAVaryingFieldAndSelectionsDrawAbove` (M5) pins: a varying
  field ⇒ varying colour, selection colours win exactly on their faces, both
  branches.

## Deviations / observations (stated, not hidden)

1. **The primitive pane and "who honours" card left the page** with the second
   selection UX. Primitive dims are edited through the library's pills (the
   same `clearanceMetric` values); `LatticeSizingLanes` (B4's law) stays tested
   at the model level. If the maintainer wants the lanes surfaced per-primitive
   again, the pure model is intact — one card in the library row would do it.
2. **Legacy stores kept working, not migrated:** `includePrimitives`,
   `paintedIncludeFaces`, and the protect-group exclude helper still decode,
   emit (includePrimitives → role=include regions) and pass their pinned tests
   (`testRoleHelpersMapToDistinctStores`, `testClearanceAndExcludeProduce-
   DifferentJobs`, `testLegacyRegionSnapshotMigratesIntoIncludeList`). New work
   flows through group roles only.
3. **Painted include faces still don't emit** as regions: a painted pseudo-face
   has no B-rep surface to synthesise geometry from (the emitter counts such
   skips honestly). Exclude-painting still rides face_protections as before.
4. **Core refuses lattice + design box** ("certification load case cannot be
   reconstructed under domain expansion") — discovered while producing the CLI
   evidence. Pre-existing, core-side, and the app can still emit that
   combination; the page does not yet gate it. Reported here for a follow-up
   (either an app-side gate with the reason, or core support).
5. **T1's button colour** uses the density ramp's indigo at 0.75 (the lattice
   identity colour) rather than Optimize's accent, so the two 64 pt buttons
   read as siblings, not twins.

## Test updates that touched existing files (nothing weakened)

* `WorkspaceInteractionTests` — four fixtures committed a group and did NOT
  `clearActive()`, a state production never leaves (every `makeAnchor/makeLoad`
  site clears). T3 makes an ACTIVE committed group growable, so those fixtures
  now do what the app does; **every original assertion is unchanged** and the
  new `testSelectedCommittedGroupGrowsOnTap` pins the new rule.
* `LatticePageTests.testGateGovernsBothEntryPoints` — the `page.hint` line died
  with the hint bar (L2). Replaced by assertions on the surviving surface (the
  gate overlay's title + CTA name exactly what is missing) — strictly more
  specific than the old generic-hint containment check.
* `LatticePageEvidenceGen` — captures the review DRAWER instead of the four
  deleted panes.

## Files

| File | Change |
|---|---|
| NEW `LatticeRegionEmission.swift` | groups+roles+primitives+faces → `lattice.regions` wire specs (pure) |
| NEW `LatticeLibraryTap.swift` | the non-destructive lattice-context tap router (M2/L23) |
| NEW `Tests/LatticePageRound2Tests.swift` | M1–M5 + T1/T4/T5 + L13/L14 + emission + CLI parse (15 tests) |
| `LatticeSettings.swift` | `LatticeGroupRole`, `LatticeRegionSpec`, `groupRoles` (Codable, default empty), `LatticeSpec.regions`, `runSpec(regions:)`, stale copy fixed |
| `LatticePageModel.swift` | Pane pruned to topology/cellDensity; `libraryOpen`/`reviewOpen`; `LatticeTransientNote` + post/tick; `LatticeEntryButtonGate` (T1); `LatticeChromeLayout` (M4); `hint` deleted |
| `LatticePage.swift` | round-2 rewrite: one spacing token, merged cell+density row, inline boundary, library row, Review drawer, Preview+Refresh cluster, transient note, tappable numbers, one-footnote topology list, content-height left-centred panel; regions/paint/primitive/review/boundary panes + chips + hint bar deleted |
| `WorkspacePlaceholder.swift` | library mounted over the page (ONE panel); role chips + no-trash in lattice context; `LatticeLibraryTap` routing; T1 entry button; T2 `chipsRevealedGroup`; T5 shared listing; T6 knob sizes; L6 gizmo gating; L5/L11 tint composition; region-tinted volumes incl. legacy include primitives; refresh closure |
| `ProjectModel.swift` | `latticeJobRegions()`, `isLatticeRegionGroup`, `listedClearanceFaces` (T5), role-group primitives excluded from `clearanceSpecs`/rendered margin-free |
| `AppModel.swift` | `makeRunRequest` passes `latticeJobRegions().regions` |
| `RemoteRunner.swift` | emits `lattice.regions` (clearance-encoder shape + `depth_mm`) |
| `ForceModel.swift` | T4 lbs default (+ decode fallback) |
| `LatticeDensityProxy.swift` | `tints(selectionTints:effectiveFaceIDs:)` — selections above the overlay |
| `MetalMeshView.swift` | per-item volume tint; L21 x-ray edge pass (depth-always, low alpha) |
| `ClearanceGeometry.swift` | `ClearanceRenderItem.tint` |
| `WorkspaceInteraction.swift` | T3: grow the active group, pending or committed |
| `tools/topopt-worker/e2e/real_cli_smoke.py` | representative job carries include+exclude regions |

## Test / regression results (M6)

* `LatticePageRound2Tests` — 15/15 green, **including the live `topopt-cli`
  parse of the emitted regions** (binary present, ran, not skipped).
* `LatticePageTests` (24), `LatticeModeTests`, `LatticeProxyTests`,
  `JobJSONEquivalenceTests`, `ManualPrimitiveJobTests`, `SelectionModelTests`,
  `SelectionTaggingTests`, `WorkspaceInteractionTests` (10, incl. the new T3
  case) — all green.
* `real_cli_smoke.py` against the freshly built CLI — OK both directions
  (schema accepted; stray key still rejected).
* Full serial `swift test --no-parallel` run: **1008 tests, 992 passed, 13
  skipped (env-gated e2e/evidence), 3 failing test cases — exactly the
  documented pre-existing 3MF `AppModelTests` set** (`testThreeMFImport*`,
  `testReopenedThreeMFProject*`: "3MF import requires lib3mf, which is not
  available in this build" — the lib3mf-free-macOS gotcha every lattice handoff
  since 2026-07-29 records; unrelated to this change). `TopOptKitTests` fully
  green.
* PR 251's preview regressions re-run in that same pass: `LatticeSDFTests`
  (the alignment assertions) **passed**, `LatticeSDFProfileTests` (the raymarch
  cost gate) **passed**.

## Plain language — what changed, and why it matters

**One selections list, everywhere.** The lattice page used to have its own way
of picking regions and faces — different buttons, different behaviour, a whole
second thing to learn. That's gone. The page now opens the exact same
Selections list you already use on the setup page: same groups, same names,
same colours, same taps. Anything you built during setup is right there, and
you give a group a lattice meaning with two small chips — "Lattice here" or
"No lattice" — or add a cylinder/plane region to it with the same + button as
always. And it's build-on, not start-over: nothing you do on the lattice page
can delete a setup group or pull a face out of one. Taking a face out of a
group is a setup-page action, on purpose. Tests enforce both halves: the two
pages provably read one list (not two lists kept in sync), and no lattice-page
interaction can remove setup work.

**Regions actually reach the engine now.** The old page admitted in small print
that "keep this solid" and "lattice only here" regions never travelled to the
engine. The engine grew the vocabulary for them a few days ago (PR 256), and
now the app speaks it: mark a group "lattice here" or "no lattice", and real
region entries ride the job — we proved the engine parses them by running the
actual engine binary on the app's own output. The stale small print is deleted.

**The three reported bugs are root-caused, not patched over.** The "second
primitive" after tapping the move icon was the side panel forgetting to hide a
converted-away entry that the 3D view and the engine already hid — one shared
rule now, so panel, picture and engine can't disagree. The Run Sim button hid
behind the orientation gizmo because that gizmo was the one piece of workspace
chrome never told to step aside when the lattice page opens — it steps aside
now. And the invisible-primitives mystery from device rounds 8 and 9: new
primitives are born at the model's centre — inside the solid — and the renderer
only drew what wasn't hidden by the part, so a buried primitive drew as
nothing. They now show a faint ghost outline through the material, wherever
they are, and lattice regions get their own indigo colour so they never look
like red keep-outs.

**The page itself got the requested cleanup.** One spacing constant between
every button (with a test that fails if two gaps differ). The big Lattice
button now sits top-right next to the position gizmo, and when it's greyed out
it tells you exactly what's missing — gravity, an anchor, a load. Weight
defaults to pounds. Notes pop up top-centre and go away on their own (tap, 60
seconds, or the next note) instead of squatting until replaced. Topology names
fit on one line, with one shared footnote for the ones whose geometry doesn't
exist yet. Cell size and density are one row; boundary is one inline question;
Review is a drawer next to Optimize; Preview is one toggle plus a Refresh. And
every number on the page can be tapped and typed on the keypad.

**The purple overlay is honest now.** It used to paint one flat violet over
everything — including over your selection highlights — no matter what you
changed. Your selections now draw on top of it, and in Auto density it shades
the part by the real stress field (that one was our bug to own: the app had the
field all along and never handed it to the overlay).
