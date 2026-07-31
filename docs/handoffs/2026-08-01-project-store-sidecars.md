# 2026-08-01 — project store carries sidecars + legible bridge refusal

Task: project-store-sidecars
Evidence: `evidence/2026-08-01-project-store-sidecars/`
Scope: app/ + bridge (the two chips PR 261 spawned and, being core-scoped, did
not patch).

## Q-A — the store carries what the selections were authored against

**The bug (as PR 261 diagnosed it):** `ProjectStore.save` copied ONLY the model
file into the project folder. The face-overrides sidecar (`<model>.faces` — the
painted pseudo-faces, written by `ProjectModel.persistPaint` next to the
ORIGINAL import) and the clearance sidecar (`<model>.clearances.json`) never
arrived. On reopen, `AppModel.restoreFromDisk` re-imports from the store copy;
`import_part` finds no sidecar, so the painted pseudo-faces do not exist —
while the restored `SelectionModel` groups still reference their ids. RUN SIM
and Optimize then throw "face_id out of range", or tag the wrong faces.

**The fix** (`ProjectStore.swift`): `save` now syncs both sidecars next to the
store's model copy on EVERY save — copy when the source has one, delete a
stale store copy when the source deleted its own (a cleared paint overlay
deletes its sidecar; the store must say the same thing). The model copy stays
copy-once (it is immutable); the sidecars are not, so they refresh each save.
A reopened project's model source IS the store copy — the sync is a no-op then
(`persistPaint`/`persistClearances` already write beside it directly).

### Q1 — the failing-first round trip

`ProjectStoreSidecarTests.testQ1PaintedGroupsResolveToSameFacesAfterReopen`
drives the REAL flow (AppModel + ProjectStore + the bridge importer): import
the cube fixture from a sandboxed "original" location, paint native face 0's
triangles into a Load group (6 kg), tap native face 1 as an Anchor group,
persist the paint sidecar, autosave via `backHome`, then reopen through a
FRESH AppModel over the same store directory. It asserts, per group: same ids
(every referenced id resolves on the re-import; the painted load keeps id 6),
same face count (`faceCount == base + 1`), same triangles under the painted
face, and same tagged voxel counts through the real bridge tagger
(`tagStepFace` on the store copy vs the original import).

**Confirmed failing on the unfixed store** by running it before touching
`ProjectStore.save`: 4 failures —
`faceCount 6 != 7` (the painted pseudo-face is gone), `face 6 not < 6` (the
group still references it), the painted face covers `[]` not the painted
triangles, and the tagger throws `tag_step_face: face_id 6 out of range — the
model carries 6 faces (valid ids 0..5)`.
`prefix-Q1-roundtrip-FAIL.log`; post-fix: `postfix-Q1-Q6-PASS.log`.

### Q2 — existing (pre-fix) projects open legibly

A project already saved WITHOUT sidecars must not crash on open — and must not
wait for a raw out-of-range at run time. `ProjectModel.init(restoring:)` now
checks every restored group's face ids against the re-imported model's
`faceCount` and, when some no longer resolve, sets a plain `restoreWarning`
naming each affected group and its missing painted face ids;
`AppModel.open` surfaces it as the toast. The message states the recovery:

> This project was saved before painted selections were stored with it, so the
> reopened model doesn't carry the hand-painted faces that "Group A" (painted
> face 6) selected. Those groups can't reach the solver. To recover: delete
> them, re-paint the faces, and save the project again.

(That IS what a user should do: the paint data was never persisted anywhere the
store can recover it from — re-painting re-mints the pseudo-face and re-saving
now persists it.) `testQ2LegacyProjectWithoutSidecarOpensWithNamedWarning`
strips the sidecars from a saved project (exactly the on-disk shape of a
legacy save), reopens without crashing, and asserts the warning names the
painted group, states the recovery, is the surfaced toast, and does NOT blame
the intact tapped anchor group. The composer is pure
(`unresolvableGroupsWarning`), with the healthy nil side pinned too.

### Q3 — round-trip RUN SIM

`testQ3RoundTripRunSimResolvesDeclaredLoad`: save → reopen → `loadCase()` →
real bridge `analyzeSolidLoadCase` on the reopened store copy. Measured on the
reopened project (from the test's own output):

* resolved load magnitude: **|F| = 58.8399 N** (6 kg × 9.80665 — non-zero)
* tagged voxels: **painted load face 6: 1024; anchor face 1: 1024** at
  resolution 32 (non-zero, and equal to the pre-save counts — Q1)
* the sim solve converges: **max stress 1.326 MPa, max displacement
  0.00218 mm, accepted** — and re-running it is bit-identical, field included
  (the in-test determinism check).

## Q-B — the bridge adopts core's legible refusal

`bridge.cpp:1110` hardcoded the pre-261 generic string ("every group
zero-force or tagged no voxels — nothing to certify under").
`analyze_loadcase`'s refusal is now composed from
`topopt::no_external_load_message(setup, resolution)` (PR 261's per-group
composer: WHICH group, its faces, |F|, and WHY — zero-force vs zero-tagged vs
unresolvable), keeping the bridge's own sim framing ("nothing to certify
under"). Same condition, same loudness — only legible now.

**Prerequisite stated, not skipped:** adopting it required a vendored-core
rebuild (`app/scripts/build_core.sh`) — this worktree had NO `vendor/` tree at
all, so the rebuild was done first (and once more with
`LIB3MF_PREFIX=<repo>/.vcpkg/installed/arm64-osx-dynamic` so the macOS slice
kept 3MF import — a slice built without it fails the 8 committed 3MF tests).
The `core/build/topopt-cli` binary was also stale (pre-`lattice.regions`) and
was rebuilt for the gated PR-260 CLI-parse test. Note the make target is
`topopt_cli` (underscore); `cmake --build --target topopt-cli` exits 0 doing
nothing.

### Q4 — the test

`testQ4BridgeRefusalNamesGroupAndReason` declares a zero-force load group
through the real bridge (`analyzeSolidLoadCase`) and asserts the thrown
message contains `group 0`, `face 0` and `zero force`, and does NOT contain
the old generic string. Live message now:

```
analyze: the declared load case produced NO external load — every declared
load group contributed nothing at resolution 32: group 0 (face 0, |F|=0 N):
zero force — set a non-zero force on this load — nothing to certify under
```

## Q5 — no regression

* Full app package suite: **1015 tests, 0 failures, 13 skips** (all the usual
  gated evidence/e2e/device tests — listed in `fulltest-PASS-summary.txt`).
* PR 251's alignment/profile suites (`LatticeSDFAlignmentTests`,
  `LatticeSDFProfileTests`) and PR 260's round-2 suites
  (`LatticePageRound2Tests`, `LatticePageTests`,
  `WorkspaceInteractionTests`) re-run explicitly: **57 tests, 0 failures**
  (1 skip: the `TOPOPT_LATTICE_ALIGN_DIR` evidence renderer).
  `regression-PR251-PR260-suites.log`.
* The 8 failures seen mid-task were ALL the 3MF suite against the first
  (lib3mf-free) vendored rebuild — an environment artifact of this fresh
  worktree, fixed by the second rebuild above, not by any code change. Two
  environment gotchas worth writing down: SwiftPM CACHES the manifest
  evaluation, so vendoring `vendor/lib3mf-lib` after a first build leaves the
  link flags stale until `~/.swiftpm/cache/manifests` is purged (touching
  Package.swift does NOT invalidate — the cache is content-keyed); and a full
  test run overwrites the two committed
  `docs/handoffs/assets/120_contact_cylinder_*.png` (ContactShadingTests
  writes them ungated — restored via git, follow-up chip spawned).

## Q6 — determinism

* `testQ6SaveSyncsSidecarsDeterministicallyAndDropsStaleOnes`: saving the
  identical snapshot value twice leaves `project.json` AND the synced `.faces`
  sidecar byte-identical; deleting the source sidecar (cleared paint) deletes
  the store copy on the next save — no stale resurrection. Honest scoping
  found by the full-suite run: the test's first draft compared the LIVE
  model's encode against a decode→re-encode and flaked, because ForceModel's
  UUID-keyed dictionaries encode as arrays in hash-iteration order — two
  byte-different but semantically equal `project.json`s are possible across
  instances (pre-existing app-wide encoding behavior, not introduced here).
  The determinism claim is therefore per-value: same snapshot value → same
  bytes, proven stable across 5 consecutive runs.
* RUN SIM on the reopened project re-run in-test: bit-identical result
  including the full von Mises field (Q3).

## Plain language

When you save a project, the app keeps its own copy of your part file so it
can reopen the project later without asking for the original. But if you had
painted some selections by hand — brushing exactly the surface a load pushes
on — those brush strokes were stored in a little side file next to the
original part, and the app forgot to copy that side file into the project.
Reopening the project brought back your groups, but the painted surfaces they
pointed at no longer existed, so running a simulation crashed with a cryptic
"face out of range" error, or quietly pushed on the wrong place.

Now the save copies the side files too — every time you save, so the copy
always matches your latest strokes. A test proves the full journey: paint,
save, reopen, run the simulation, and the same surfaces carry the same load
as before the save.

For projects saved before this fix, the paint data is simply gone — nothing
can bring it back. Instead of crashing, the app now tells you plainly when
you open one: which groups lost their painted surfaces, and what to do —
delete those groups, re-paint the faces, and save again (the new save keeps
them for good).

And when a simulation refuses to run because no load actually reached the
part, the app now shows the detailed explanation the solver has known since
the last fix — which load contributed nothing and why (zero force set, or a
face too small to register at the chosen quality) — instead of the old
one-line shrug.
