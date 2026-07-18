# 099 — Small-face load loss: surface it BEFORE the run

Status: **SHIPPED.** The silent failure (a load face smaller than a voxel footprint
tags zero voxels, `external_loads` arrives empty, the run is refused) is now
**visible on three surfaces before it can waste a run**: a permanent per-load-group
core log line, a selection-time warning badge in the app, and an Optimize pre-flight
that blocks an all-dead load case with an actionable message. The core
`require_external_loads` guard is **untouched** — it stays the hard backstop. **No
ROADMAP box, no fixtures, no ARCHITECTURE change.** The explicit non-goal (making
`tag_step_face` "rescue" a too-small face) was **not** done — see §NON-GOAL.

Territory: `/core/` (`build_production_loadcase` + `loadcase.hpp`) and app Swift
(`TopOptFlows`, `TopOptDesign`). **`bridge.cpp` was NOT touched** — the app warning
is a pure-Swift heuristic (it needs no core query), so the PR-118 block never came
into play. Branch: `claude/small-face-load-loss-3e535b`.

---

## ROOT CAUSE (confirmed, mechanism named)

`tag_step_face` (`core/src/io/step.cpp:227`) tags a solid voxel iff its centre is
within **half a voxel** of the face surface (`thr2 = 0.25·h²`). The voxel edge is
`h = longest bbox axis / resolution` (`voxelize`, `voxelize.cpp:226`). At Fast·64³ on
`test_Tendrils.step` `h ≈ 4.14 mm`, and the load-tab face is smaller than that
footprint, so **no** solid voxel centre lands within `h/2` of it → **zero voxels
tagged**. `build_production_loadcase` then skipped the group (`any=false`),
`external` came back empty, and `require_external_loads` correctly refused. The SAME
load registers at Balanced/Fine (finer `h`), and a large face registers at Fast — so
nothing is wrong with the physics; the loss was just **silent until Optimize**. This
zero-tag skip is also the probable mechanism of the original 097 fragmentation
report.

---

## DELIVERABLE 1 — permanent core instrumentation

`build_production_loadcase` now emits **one line per load group** through an
injectable sink (default: one line to stderr; a front-end may reroute to os_log, a
test may capture). Header: `core/include/topopt/loadcase.hpp` (`LoadcaseLogFn`,
`set_loadcase_log_sink`). Impl + call sites: `core/src/cli/loadcase.cpp`. The load
loop was refactored to count the group's distinct tagged voxels and log the outcome;
`external_loads` is byte-for-byte the same set as before (production_parity proves
it, bit-identical).

**Evidence — the real stderr lines from a forced zero-tag reproduction** (a 50 mm
cube whose +X face is split into a 2 mm corner patch and a large remainder, at
resolution 4 → `h = 12.5 mm`, so the patch is sub-voxel):

```
[loadcase] load-group 0: faces=1 |F|=111N voxels_tagged=0 SKIP=zero-tagged
[loadcase] load-group 1: faces=1 |F|=490N voxels_tagged=16 status=ok
[loadcase] load-group 2: faces=1 |F|=0N voxels_tagged=0 SKIP=zero-force
```

This is the observability that would have caught the loss in week one: group index,
face count, |force| N, voxels tagged, and the skip reason (`zero-force` vs
`zero-tagged`).

## DELIVERABLE 2 — selection-time warning (app)

`app/.../TopOptFlows/LoadFaceFit.swift` (pure value types, headlessly tested):

- `VoxelFit.spacing(forBounds:resolution:)` derives `h` EXACTLY as the voxelizer does
  (longest bbox axis / resolution).
- `VoxelFit.footprint(ofFace:in:)` measures a face's **area** (Σ triangle areas) and
  **thinnest in-plane extent** (projected onto the face plane, so a tilted planar
  face's thin dimension stays honest — not fooled by an axis-aligned bbox).
- `VoxelFit.mayTagZeroVoxels(_:spacing:)` — the heuristic: warn if
  `thinnestExtent < h·1.5` **or** `area < (h·1.5)²`. The 1.5 safety factor biases
  toward warning (a false "may not register" costs a resolution bump; a MISSED
  warning is the silent loss).
- `VoxelFit.warningText / badgeText` — the plain-English copy ("This face is smaller
  than a Fast-quality voxel (4.1 mm) — the load may not register. Use Balanced or
  Fine, or pick a larger face."). Always hedged — **never a definitive claim**, only
  the voxelizer knows for sure.

Wired in `WorkspacePlaceholder.swift`: a load group whose **every** face is sub-voxel
(matching the core: a group registers if ANY face tags a voxel) badges its
selections-panel row amber (`DS.Color.warning`, new token) with the `.help()`
tooltip carrying the full sentence.

## DELIVERABLE 3 — Optimize pre-flight (app)

`LoadCasePreflight.evaluate(_:qualityTitle:spacingMM:)` in the same file returns
`.block` / `.warn` / `.allow`:

- **every** load group dead (zero-force or may-not-register) → `.block` with a
  message naming the group(s) and the fix (resolution / larger face / non-zero
  weight) — **not** the solver's exception text.
- **some** dead → `.warn` (proceed, but flag which).
- none dead, or no load groups (self-weight/STL) → `.allow`.

Wired in `WorkspacePlaceholder.startRun()` before `run.start`: a `.block` toasts and
returns (Optimize stays enabled so the user can fix and retry); a `.warn` toasts and
proceeds. The core guard still backs all of this.

---

## NON-GOAL honored

`tag_step_face` was **not** changed to auto-tag a centroid voxel or otherwise
"rescue" a too-small face. Concentrating a 25 lb load on one voxel is a different
physics problem than the user posed; a silent geometry change that makes the number
describe a different object is reject-class here. If a tagging improvement is ever
wanted (e.g. an explicit "point load at face centroid" mode), it should be a separate
task with its physics named — not a silent rescue.

---

## REGRESSION + EVIDENCE (raw)

**Core (ctest, macOS, Eigen+OCCT, lib3mf absent → `-DTOPOPT_REQUIRE_DEPS=OFF`):**

- NEW `loadcase_small_face` — **Passed 0.10 s.** Synthetic in-code `StepModel` (no
  OCCT): a sub-voxel load face tags zero → `zero-tagged` log + EMPTY external set;
  the SAME force on a large face tags 16 voxels → `status=ok` + non-empty external; a
  zero-force group → `zero-force` log. (The existing guard test covers the throw.)
- `load_retention_connectivity` — **Passed 10.18 s.**
- `production_parity` — **Passed 15.63 s** (build_production_loadcase still
  bit-identical: the log/refactor changed no computed output).
- Full suite: **47 / 48 tests pass.** The one failure is `cli_demo` (3 of 84 checks:
  "achieved volume fraction within 0.01 of its request"). **Pre-existing and
  unrelated** — verified by `git stash`ing this branch's core changes and rebuilding
  `test_cli`: it fails the SAME 3 checks. It is the known local-mode artifact
  (lib3mf absent ⇒ the demo job is run STL-patched; CI runs the pristine 3MF job).

**App (`swift test` + `xcodebuild test`, macOS, after `app/scripts/build_core.sh`):**

- NEW `LoadFaceFitTests` — **8 / 8 pass** under both `swift test` and `xcodebuild
  test -scheme TopOptKit-Package -destination 'platform=macOS'`. Includes the
  decisive case: a 4 mm face on a 256 mm-long part **warns at Fast (h=4.0 mm) and
  does NOT warn at Fine (h=2.0 mm)**; the pre-flight **blocks** an all-dead case with
  an actionable message (names the groups, mentions resolution + Balanced/Fine, no
  "exception" text); a partially-dead case warns-but-allows; a tilted planar face's
  thin extent still reads ~4 mm.
- Full app suite: **437 tests, 0 failures, 1 skipped.**

## Honest limitations

The area/extent threshold is a **heuristic**, deliberately labeled "may not
register":

- **False positives:** a compact face a little over one voxel wide can be flagged
  though it would in fact tag a voxel — harmless (user bumps resolution or picks a
  larger face). The 1.5 safety factor makes this the intended, cheap error.
- **False negatives:** a LONG, THIN, TILTED sliver (large area, wide in-plane bbox)
  can slip past both tests. The in-plane extent is measured against a basis derived
  from the mean normal, so a shape rotated *within* its plane can over-report its
  thin dimension. The core `require_external_loads` guard still catches this at run
  time — the pre-flight makes the *common* case legible, it does not replace the
  backstop.

## Build / not done

- `/core/` changed ⇒ the app was re-vendored via `app/scripts/build_core.sh`
  (~70 s here) before the Swift suite; `bridge.cpp` was **not** touched.
- The upstream UI→bridge force-loss question from 097 is orthogonal and not
  revisited here; this work makes the *geometry* failure mode visible regardless of
  where a lost force originates.
