# lattice-page-round2 — test evidence (2026-07-31)

## New suite: LatticePageRound2Tests — 15/15 green

| Bar / item | Test |
|---|---|
| M1 one model | testLatticePageRendersFromTheSameGroupModelAsTheTOPage · testLatticePageSourceHasNoSecondSelectionUI |
| M2 non-destructive | testNoLatticePageInteractionCanRemoveATOFaceOrGroup |
| M3 regions reach job | testIncludeAndExcludeRegionsReachTheEmittedJobJSON · testCoreCLIParsesTheEmittedRegions (RAN against core/build/topopt-cli — not skipped) · testRoleGroupPrimitivesLeaveClearancesAndJoinRegions |
| M4 one spacing token | testChromeSpacingIsOneConstant |
| M5 overlay | testOverlayMapsAVaryingFieldAndSelectionsDrawAbove |
| T1 | testLatticeEntryButtonGate |
| T4 | testDefaultWeightUnitIsLbs |
| T5 | testConvertingAnAutoClearanceListsExactlyOnePrimitive |
| L13 | testTransientNoteLifecycle |
| L14 | testTopologyListShowsOneFootnoteNotPerRowBadges |
| emission | testRegionSpecMappingAndValidity · testGroupRolesRoundTripAndLegacyDecode |
| T3 | WorkspaceInteractionTests.testSelectedCommittedGroupGrowsOnTap (that suite: 10/10) |

## Full serial run (`swift test --no-parallel`, 2026-07-30 20:27)

Executed 1008 tests: 992 passed, 13 skipped (env-gated e2e/evidence gens),
3 failing TEST CASES — exactly the documented pre-existing 3MF set on a
lib3mf-free macOS checkout (`AppModelTests.testThreeMFImport*`,
`testReopenedThreeMFProjectReimportsTheStlWorkingCopy`; refusal text:
"3MF import requires lib3mf, which is not available in this build").
No other failures. TopOptKitTests green.

M6's explicit PR-251 re-runs, same pass:
* LatticeSDFTests (preview alignment) — PASSED
* LatticeSDFProfileTests (raymarch cost gate) — PASSED

## Real-CLI schema proof (M3)

* `job_with_regions.json` — the representative app job with 1 exclude bolt +
  1 include face region (the exact serializer shape).
* `cli_parse_output.txt` — `topopt-cli run` on it: with the design box the
  refusal is the POST-PARSE lattice⊗design-box gate; without the design box the
  failure is the missing model file. Both are past schema parse ⇒ the regions
  schema was accepted. (The lattice⊗design-box refusal is a pre-existing core
  gate the app does not yet surface — noted in the handoff observations.)
* `tools/topopt-worker/e2e/real_cli_smoke.py` (now carrying the regions block):
  "OK: the real CLI accepts the app's job.json schema and rejects worker
  metadata — no app→worker→CLI drift."

## Captures (offscreen ImageRenderer — platform-backed Toggle/Slider render as
placeholder glyphs; frames are exact; live-device QA remains the maintainer's)

* page_default_landscape/portrait.png — merged Cell & density row, Regions &
  faces (group roles · regions), inline Boundary three-way, content-height
  left-centred panel, bottom-right Preview·Review·Optimize cluster at the one
  12 pt gap, RUN SIM in the true corner, "5.5 lbs load" (T4).
* page_topology_pane.png — one-line names, orange asterisk + single footnote.
* page_cell_density_pane.png — tappable numbers (cell, min %, max %, depth).
* page_review_drawer.png — the L16 drawer.
* page_gate_landscape/portrait.png — the unchanged B1 entry gate.
* topology_truth_from_core.txt — live core sets at capture time.
