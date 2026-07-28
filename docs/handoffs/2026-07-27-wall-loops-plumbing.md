# Wall-loops plumbing — carry the user's wall count through to the engine

## The problem

A real run's `run_info.json` showed `wall_loops: 0` while the maintainer's Print
Parameters sheet showed **5**. The perimeter wall-loop count the width-aware
knockdown depends on was not reaching core.

It is harmless **today** because `width_aware_knockdown` ships **false** (the pure
`f^1.5` scalar gate; see `production_width_aware_knockdown()`). It becomes a
**safety** problem the moment that flag is armed. The shell+core composite gate
sizes each member's solid perimeter ring as `t = wall_loops · wall_line_width_mm`
(`knockdown_spec_for`, `core/src/simp/production.cpp`). With `wall_loops = 0` the ring
vanishes and every member is modelled as **bare infill with no solid walls** — the
`f^1.5`-only regime PR 191 measured as **non-conservative on real (large) parts**
(`[[knockdown-size-dependent-real-parts]]`: true margin ≈ 0.98–1.13 at 200 mm). The
gate would then **overstate strength**, on every part, silently.

## Diagnosis — where the value died

The core is, and already was, **fully plumbed** end to end:

- `core/src/cli/job.cpp` parses `loads.wall_loops` (schema-checked non-negative int ≤ 1000).
- `core/src/cli/run_job.cpp` copies `job.loads.wall_loops → ProductionLoadCase.wall_loops`.
- The **shared** `build_production_loadcase` (`core/src/cli/loadcase.cpp`) copies
  `lc.wall_loops → opts.wall_loops` — the same builder **both** front-ends call.
- `run_job.cpp`'s `build_run_info` echoes `info.wall_loops = options.wall_loops`, and
  `observability.cpp` writes it.

The gap was entirely in the **two app-side serializers**, which never set the value:

- **On-device (bridge) path.** `BridgeLoadCase` (`TopOptBridge.hpp`) had no `wall_loops`
  field at all, and `bridge.cpp` mapped `infill_percent` but not walls. So the bridge
  handed core the POD default `0`.
- **LAN worker path.** `RemoteRunner.buildJobJSON()` emitted `infill_percent` but no
  `wall_loops` key, so the CLI fell back to its schema default `0` — exactly the
  `run_info: wall_loops: 0` observed.

Both front-ends read from the app's `PrintParams.wallLoops`, which is captured and
persisted; it just never left the app.

## The fix (app-side only; core untouched)

`RunRequest` now carries `wallLoops`, and both serializers read it:

- **`RunRequest.wallLoops`** (`RunModel.swift`), part of the request identity like
  `infillPercent`. `AppModel.makeRunRequest` fills it from `project.printParams.wallLoops`.
- **On-device:** `BridgeLoadCase.wall_loops` (new field) ← set by
  `TopOptKit.minimizePlasticLoadCase(wallLoops:)`; `bridge.cpp` maps it onto the shared
  `ProductionLoadCase.wall_loops`. `wall_line_width_mm` is left at the ProductionLoadCase
  default (`< 0 → core default 0.45 mm`), identical to a CLI job that omits it.
- **LAN:** `buildJobJSON()` now always emits `loads.wall_loops` (0 is a meaningful
  "no walls", and the CLI defaults an **absent** key to 0 — the bug).
- **One shared mapping.** Both paths take the value through `TopOptKit.bridgeWallLoops(_:)`
  (the identity `Int32(wallLoops)`), so the on-device POD assignment and the LAN JSON
  value can never drift. This is the same bridge/CLI-divergence class that
  `knockdown_spec_for` already fixed once (`[[knockdown-spec-shared-builder]]`).

Diffstat: `evidence/2026-07-27-wall-loops-plumbing/diffstat.txt` — 7 files, app only.

## Bars

### W1 — run_info echoes the value the user set (real job, non-default count)
`topopt-cli run` on the l-bracket with `loads.wall_loops: 5`:
`run_info_after_wall5.json` → `"wall_loops": 5`. The paired contrast job that **omits**
the key (what the app used to send) → `run_info_before_wall0.json` → `"wall_loops": 0`.
Note: only the **CLI/LAN** path writes `run_info.json`; the on-device bridge returns an
`OptimizeResult`, not a run-info file — so W1 is verified on the CLI, which is the path
that produced the original `wall_loops: 0` symptom.

### W2 — both paths agree
`testWallLoopsAgreeAcrossBridgeAndCLI` (in `JobJSONEquivalenceTests`, the mesh-job-params
regression gate's home) asserts the LAN `buildJobJSON()` value **equals** the on-device
value `TopOptKit.bridgeWallLoops(request.wallLoops)`, for the same `RunRequest`, on both
STEP and mesh sources. It is the app-side twin of `test_production_parity.cpp`'s existing
assertion that the shared knockdown spec sizes `wall_thickness_mm = wall_loops ·
wall_line_width_mm` — both still pass (`W2_core_parity.txt`). Evidence:
`W2_W3_swift_tests.txt`.

### W3 — a pre-change project loads with a sensible default
A project saved before this change loads its params via
`ProjectModel: snapshot.printParams ?? .fdmDefault`. A snapshot that predates
`PrintParams` (or has a null block) decodes to **`.fdmDefault`, i.e. 3 wall loops** —
the sheet's own seed value and a typical desktop-FDM default. A project that *did* save
its Print Parameters keeps its real captured count. The default is **never the buggy 0**:
`testWallLoopsDefaultsToTheFDMDefaultNotZero` asserts an unspecified `RunRequest` serializes
`wall_loops: 3` on both paths. Why 3 and not 0: 3 is the value the sheet already displays
by default, so a user who never opened the sheet gets exactly what the UI shows; and 3
credits *fewer* walls than a typical 5-wall print, i.e. it errs to the **more conservative**
(smaller wall-ring) side of the gate.

### W4 — byte-identical results while width_aware_knockdown is false
When `knockdown.width_aware` is false, `analyze.cpp` never enters the `member_width_mm`
branch and never reads `wall_thickness_mm`; the effective margin is
`margin.worst_case * infill_knockdown`, independent of `wall_loops`. Measured, not just
argued: two CLI runs of the same job differing **only** in `loads.wall_loops` (0 vs 5)
produce an **identical `report.json`** and **bit-identical** variant STL meshes (matching
SHA sums for all four rungs). `run_info.json` differs only in the `wall_loops` line and the
wall-clock timestamp. Evidence: `W4_byte_identical.txt`.

### W5 — is any OTHER knockdown input still unplumbed?
The knockdown model's inputs are `infill_percent`, `wall_thickness_mm` (=
`wall_loops · wall_line_width_mm`), and `member_width_mm` (measured from the printed
field, **not** a print parameter). Cross-checking against the six captured Print
Parameters:

- `infillPercent` → **plumbed** (pre-existing, both paths).
- `wallLoops` → **plumbed by this change** (both paths).
- `wall_line_width_mm` → **not a captured Print Parameter.** The sheet has no
  line-width control, so neither front-end sets it; both fall back to the **core default
  0.45 mm**. This is consistent across paths (not a divergence), but it is a fixed
  modelling assumption, not the user's real nozzle width. **If** the maintainer arms
  width-aware *and* wants the true line width to matter, that needs a new sheet field.
- `topLayers` / `bottomLayers` → feed only the M5.1 recommend-settings engine; the
  knockdown reads member width from geometry, never a shell count. Correctly unplumbed.
- `layerHeightMM`, `infillPattern` → not knockdown inputs (no core field / the `f^1.5`
  curve is pattern-agnostic).

A `rg` for `top_layers|bottom_layers|layer_height|infill_pattern` across the
knockdown/analyze/production path returns **no matches**. Full write-up:
`W5_knockdown_inputs.txt`.

## Tests / evidence

- `app/.../JobJSONEquivalenceTests.swift`: `testWallLoopsAgreeAcrossBridgeAndCLI` (W2),
  `testWallLoopsDefaultsToTheFDMDefaultNotZero` (W3), plus a `wall_loops` assertion added
  to the existing full-load-case test. Whole file: 6/6 pass.
- Related app suites re-run green: `ManualPrimitiveJobTests`, `GravityDirectionTests`,
  `ManualPrimitiveTests`, `RunModelTests`, `PrintParamsTests` (136 tests, 0 failures).
- Core unchanged; `test_job` (113 checks) and `test_production_parity` still pass.
- `evidence/2026-07-27-wall-loops-plumbing/`:
  `job_wall_loops_5.json`, `job_wall_loops_omitted.json`,
  `run_info_after_wall5.json`, `run_info_before_wall0.json`,
  `W4_byte_identical.txt`, `W2_W3_swift_tests.txt`, `W2_core_parity.txt`,
  `W5_knockdown_inputs.txt`, `diffstat.txt`.

## For the maintainer arming width-aware later

The value now reaches core on both paths and `run_info` proves it per job. Before you
arm `kProductionWidthAwareKnockdown`, decide whether `wall_line_width_mm` (currently a
fixed 0.45 mm on both paths) should become a user field — it is the one knockdown input
still defaulted rather than captured.
