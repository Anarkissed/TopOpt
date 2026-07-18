# 104 — cli_demo volume-fraction basis: two labeled fields (fixes 102's BLOCKED)

**Status:** DONE (core). App/bridge mapping applied and compiled. cli_demo green
locally (84/84) and — see the CI section — must be confirmed green on CI (the
arbiter of cli_demo). The design is provably untouched: raw densities are
bit-identical before/after.

**Decision implemented:** handoff 102's **Option 1** — un-overwrite the reported
achieved fraction (revert 094 for the report field) and keep the count basis in a
separate, labeled field. 102's diagnosis is authoritative and was NOT
re-investigated; the plateau/PR-119 hypothesis stays dead.

Handoff-number note: main tops at 102; 101 (remote-run liveness) and 103
(keep-clear-ux-v2) are in-flight in their own worktrees, so this is **104**.

---

## The change (reporting only — one question per field)

Per variant, the core report now carries TWO volume bases, each answering one
question. On the grayscale MMA field they genuinely diverge (MMA has no Heaviside
projection → the density is a ramp ~1 filter-radius wide; a sub-threshold fringe
carries real mass in Σρ but 0 in `#{ρ>0.5}`); the gap grows as the target shrinks.

1. **`volume_fraction`** — the OPTIMIZER-ACHIEVED fraction ("did the solve hit its
   volume target?"). Reverted to its pre-094 meaning:
   - **No-box path** (the demo/production ladder): the optimizer's *continuous*
     fraction `Σρ/n_active` over the active design set (== the part here: `G==grid`,
     only the 1-voxel BC skin is frozen). The volume constraint drives it to the
     request — **0.6997 / 0.4997 / 0.2997** for 0.7 / 0.5 / 0.3 (102's transcripts).
     This is `simp_optimize`'s own value, **no longer overwritten** — 094 had
     clobbered it with basis (2), silently redefining what cli_demo line 252 tests.
   - **Design-box path** (080 whole-domain): the solve targets the Active envelope,
     so simp's raw fraction is not part-relative; 080's overwrite to
     `printed_voxels/part_solid` **stands** — "the same part-relative normalization
     handoff 080 established on the box path". Unchanged in value.

2. **`printed_fraction`** (NEW) — the PRINTED/thresholded count basis ("how much
   material actually prints?") = `#{ρ>0.5}/part_solid`, exactly 094's number. It is
   the SAME voxel count the reported mass is built from, and
   `volume_saved_fraction = 1 - printed_fraction`. So savings% and mass are two
   views of one count and can never disagree — **094's fix is preserved, moved to
   its own field**. `printed_fraction` is also the number that matches the exported
   mesh's mass basis (the mass-gap item at export still comes due — see limitations).

3. **cli_demo line 252** now tests what it always meant — the optimizer-achieved
   (continuous) fraction within 0.01 of the request. No tolerance change, no
   demo-job config change. `expected_values.json` documents BOTH bases and why they
   diverge on gray MMA fields (cites 102), in the same change as the report contract
   (102's closing rule: contract + integration test reconcile in one commit).

4. **Bridge/app**: `printed_fraction` is mapped ADDITIVELY as a flat field through
   the bridge struct → TopOptKit → OutcomeStore → RemoteRunner. **App display values
   do not change**: the app's savings basis stays the printed/count fraction
   (`achieved_volume_fraction` is now sourced from `report.printed_fraction`, i.e.
   the same value it always had), so `savings = 1 - achieved` is byte-identical on
   the local, remote-live, remote-final and persisted paths. The continuous
   optimizer-achieved fraction remains the RemoteRunner stream↔report join key. The
   CLI `VARIANT` line gained a `printed=` field; the Python worker forwards it.

---

## Files changed

Core (report contract + the two tests that pin it — one commit):
- `core/src/simp/minimize_plastic.cpp` — revert the no-box overwrite; compute
  `printed_fraction`; box overwrite (080) unchanged; big two-basis comment citing 102/104.
- `core/include/topopt/report.hpp` — `VariantReport::printed_fraction`; doc updates.
- `core/src/settings/report.cpp` — emit `printed_fraction`; `volume_saved_fraction
  = 1 - printed_fraction`; validator: `printed_fraction` optional number in [0,1],
  savings consistency uses it when present (legacy `1 - volume_fraction` otherwise).
- `core/tests/unit/test_report.cpp` — set `printed_fraction` in builders; savings
  derives from it; new `test_printed_fraction_validator` teeth.
- `core/tests/validation/test_savings_part_relative.cpp` — read
  `report.printed_fraction` (was `optimization.volume_fraction`); +2 checks locking
  that `volume_fraction` is simp's continuous value and stays distinct from the
  count basis (guards against a future re-clobber).
- `core/tests/fixtures/demo/expected_values.json` — `volume_bases` +
  `why_bases_diverge`, both bases stated with numbers; line-252 meaning clarified.
- `core/src/cli/run_job.cpp` — `VARIANT` stream line adds `printed=`.

App / bridge / worker (additive):
- `app/TopOptKit/Sources/TopOptBridge/include/TopOptBridge.hpp` — `printed_fraction`.
- `app/TopOptKit/Sources/TopOptBridge/bridge.cpp` — `achieved_volume_fraction` and
  `printed_fraction` both from `v.report.printed_fraction`.
- `app/TopOptKit/Sources/TopOptKit/TopOptKit.swift` — `OptimizeVariant.printedFraction`
  (init defaults to `achievedVolumeFraction` for old callers); bridge mapping.
- `app/TopOptKit/Sources/TopOptFlows/OutcomeStore.swift` — DTO `printedFraction`
  (optional → backward-compatible decode of pre-104 blobs).
- `app/TopOptKit/Sources/TopOptFlows/RemoteRunner.swift` — parse `printed`; savings
  basis from it; join key unchanged (continuous).
- `tools/topopt-worker/topopt_worker.py` — forward the `printed` field.

---

## Evidence

### Design is UNTOUCHED (this is reporting only)

Raw `physical_density` dumped from the 094 baseline binary (a clean worktree at
`4bbd0b1`) and from this branch, for the demo self-weight job (res 48, ladder
0.7/0.5/0.3), all three rungs — **bit-identical (matching SHA256)**:

```
rung 0: 94e984237405f2965db5e060752bfe51ffddca616a9b285dd75c32aee9e26521 | (same)
rung 1: 157edb22b9694b2e536ae79ff183ac39bc054eab912167291b6492df5310cfd6 | (same)
rung 2: d01a35da5b9d9a73808513ec14b33a9154c08c078020174ead066ec6e554b545 | (same)
```

The exported STL meshes (`variant_070/050/030.stl`) are likewise byte-identical
before/after. The change never writes `physical_density`, `design`, the mask, loads
or the optimizer — it only reads `printed_voxels` and assigns report scalars.
Permanent guards: `production_parity` (density determinism) stays green, and
`savings_part_relative` gained two checks that `volume_fraction` is simp's
continuous value and stays distinct from `printed_fraction`.

(The density-dump used to produce the SHA256 evidence was a temporary
`TOPOPT_DUMP_DENSITY`-gated block in `run_job.cpp`, applied identically to both
worktrees and **reverted** — the tree is clean of it.)

### before/after report.json (one demo rung shows both fields)

```
              BEFORE (094)              AFTER (104)
rung 0:  volume_fraction 0.6729    volume_fraction 0.6997   printed_fraction 0.6729
rung 1:  volume_fraction 0.4241    volume_fraction 0.4997   printed_fraction 0.4241
rung 2:  volume_fraction 0.2065    volume_fraction 0.2997   printed_fraction 0.2065
```

`volume_saved_fraction` is byte-identical before/after (0.3271 / 0.5759 / 0.7935 —
`= 1 - printed_fraction`), so savings% and mass are unchanged. The after
`volume_fraction` values land within 0.01 of the request → line 252 passes.

### Local ctest (macOS, no lib3mf → STL path, 84 checks in cli_demo)

`100% tests passed out of 50` (523 s). Named gates the task requires green:

```
 #7 report ...................... Passed
#26 gate_v2 .................... Passed
#32 load_retention_connectivity  Passed
#36 savings_part_relative ...... Passed   (9 checks, was 7)
#37 ladder_rung_count ......... Passed
#47 cli_demo .................. Passed   (84/84; was 3/84 FAILED on line 252)
#48 production_parity ......... Passed
#49 clearance_parity ......... Passed
```

### CI (the arbiter of cli_demo — pristine 3MF job with lib3mf)

<!-- CI-RESULT: fill in with the PR's ci run URL + `cli_demo` line once green. -->
Pending push. Per 102, CI runs the pristine 3MF demo (lib3mf present, 83 checks);
the 3 vf failures were basis failures computed long before any mesh is written, so
CI must show `cli_demo` green. See the PR checks.

### App/bridge

`swift build` of the TopOptKit package against the freshly vendored core
xcframework (built via `app/scripts/build_core.sh`): **succeeds** — all 60 targets
compile, only pre-existing unrelated `Sendable` warnings in `PlaybackVideo.swift`.
Note: the app is not built by the Linux CI (no Xcode); its standard is
`xcodebuild`/simulator per handoff 097.

---

## Honest limitations

- **The two bases keep diverging until MMA gains projection.** `volume_fraction`
  (continuous) and `printed_fraction` (count) will disagree on every gray MMA field,
  by more as the target shrinks. Closing the gap is 102's *option 2* (Heaviside
  projection on MMA, `projection_supported(MMA)` → true) — a substantial numerical
  feature and its own future task, out of scope here.
- **`printed_fraction` is the mesh's mass basis.** It matches the exported mesh's
  voxel count, so savings%/mass agree with the printed object. The separate
  **mass-gap at export** (surface-resample smoothing changes the exported mesh's
  volume vs the in-memory variant; handoff 087) is unaffected and still comes due.
- **Coordination:** the keep-clear-ux-v2 task (handoff 103) owns other app files; it
  had not touched the results models (`ResultsModel`, `OutcomeStore`, `RemoteRunner`,
  `TopOptKit`, bridge) as of this work, and this change leaves `ResultsModel`
  untouched (savings logic is unchanged), minimizing conflict surface.
