# Handoff 043 — revert M7.6-ring: remove the entire Aim feature

## Task
Maintainer request (interactive): "revert back and just remove the entire 'Aim'
process." The M7.6-ring constrained-rotation-ring "Aim" feature (handoff 042 and
its addenda) was not working on device across several QA rounds; remove it
entirely and return the workspace to its M7.6-app state.

## What I did
Reverted the only Aim work that had reached `main` — PR #43 (merge `238bec8`,
commit `1ec687c` "M7.6-ring: add constrained single-DOF rotation ring") — on a new
branch off `main`, using a revert commit (not a history rewrite, since `238bec8`
is on `origin/main`).

- `git checkout main` → `git checkout -b revert-m7.6-ring-aim`.
- `git revert -m 1 238bec8` (mainline = parent 1). This:
  - **Deletes** `app/TopOptKit/Sources/TopOptFlows/RotationRing.swift` and
    `RotationRingGizmo.swift`, and `Tests/TopOptFlowsTests/RotationRingTests.swift`.
  - **Reverts** `ForceModel.swift` (removes the `customAim` channel /
    `resolvedDirection` / custom-direction methods) and its tests in
    `ForceModelTests.swift` back to the M7.6-app version.
  - **Reverts** `WorkspacePlaceholder.swift` back to the M7.6-app workspace (no Aim
    button, no ring/aim overlay, no custom direction).
  - **Un-checks** the `M7.6-ring` box in `docs/ROADMAP.md` (back to `- [ ]`).
- **Kept** `docs/handoffs/042-M7.6-ring-constrained-rotation-ring.md` (the revert
  had staged its deletion; I restored it from `HEAD`) as the historical record of
  what was attempted and why it was pulled — so a future run doesn't blindly redo it.

The three follow-up commits that redesigned Aim (dedicated screen, on-object arrow,
orientation cube, Left/Top views) lived only on the unmerged branch
`m7.6-ring-uxfixes` and never reached `main`; they are simply abandoned (branch left
in place, not merged). Nothing Aim-related remains in the `main` lineage after this
revert.

Scope: `/app/` + ROADMAP + this handoff only. No `/core/`, `tests/fixtures/**`,
`materials.json`, CI, `Package.swift`, or `ARCHITECTURE.md` touched. No new
dependency.

## Test evidence (raw, pasted, unedited)

### App package — `xcodebuild test -scheme TopOptKit-Package -destination 'platform=macOS'`
(OCCT-free-iOS manifest per runs 039–042; benign `ld: warning … newer version`
OCCT lines filtered)
```
Test Suite 'TopOptFlowsTests.xctest' passed at 2026-07-10 05:12:51.221.
	 Executed 110 tests, with 0 failures (0 unexpected) in 0.229 (0.263) seconds
Test Suite 'TopOptKitTests.xctest' passed at 2026-07-10 05:12:52.233.
	 Executed 19 tests, with 0 failures (0 unexpected) in 0.498 (0.502) seconds
** TEST SUCCEEDED **
```
(146 = 17 design + 110 flows + 19 kit — the exact M7.6-app baseline from handoff
041; the +36 Aim tests are gone with the feature.) Both iOS slices build
(`** BUILD SUCCEEDED **`, simulator + device).

### Core `ctest`
Not re-run: the revert touches only `/app/` + docs, no `/core/` file. The Linux-CI
gate is unchanged from the 26/26 green baseline recorded in handoff 042.

CI run: <maintainer fills>   PR: <maintainer fills>
New tests added: none (this is a removal).

## What I did NOT do
- **Did NOT delete the `m7.6-ring-uxfixes` branch.** The abandoned Aim redesign
  commits (`d66ce4e`, `09c673e`, `00ace21`) remain there, unmerged, in case any
  piece is wanted later; delete the branch if you want them gone.
- **Did NOT remove handoff 042.** Kept as history (it documents the attempt + the
  device-QA rounds). It now describes code that no longer exists — 043 is the
  current state of record.
- **Did NOT change any other M7 task or ROADMAP line** — only the M7.6-ring box was
  un-checked. M7.6-ring remains a `[ ]` "(deferred, v2)" item.
- **Did NOT alter M7.6-app, M7.5, or any earlier merged work** — the revert is
  scoped to exactly PR #43's diff.

## Warnings for the next run
- **M7.6-ring is un-checked again and stays deferred (v2).** The next active M7
  task is **M7.7** (Run screen). Do not re-attempt the rotation ring unless the
  maintainer re-scopes it — it was pulled after repeated device-QA failure (see 042
  for what was tried: in-scene ring, dedicated screen, on-object arrow, orientation
  cube).
- **`main` still points at `238bec8` (the PR #43 merge).** This branch
  (`revert-m7.6-ring-aim`) carries the revert commit; it needs to be merged for the
  removal to land on `main`.
- Standard app-build caveats unchanged: run `./app/scripts/build_core.sh` if the
  vendored core xcframework is stale; the macOS test path needs the git-ignored
  `occt-frameworks.generated.json` moved aside + the SwiftPM manifest cache purged
  (M7.1c invariant; `Package.swift` stays committed-clean).

## Blocked
None.
