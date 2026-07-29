# Extrusion line width — Print Parameters capture + plumbing

**Date:** 2026-07-28
**Branch:** `claude/extrusion-line-width-params-b02da1` (built on top of PR 218 wall-loops-plumbing)
**Evidence:** `evidence/2026-07-28-line-width-plumbing/`

## What this is

PR 218 plumbed `wall_loops` for the accept-gate width-aware knockdown, which sizes the
solid wall ring around each printed member as `t = wall_loops · wall_line_width_mm`. But
`wall_line_width_mm` was **not a captured Print Parameter** — the CLI `loads` schema
accepted it, yet neither front-end set it, so both fell back to the core default 0.45 mm.
That is a fixed modelling assumption, not the user's real slicer setting, and wall
thickness is half of the SHELL+CORE composite the width-aware gate depends on.

This change exposes **extrusion line width** in Print Parameters and plumbs it through
both front-ends, exactly as PR 218 did for `wall_loops`.

## Which quantity — and the decision on the split

The three quantities the task warned not to conflate:

- **Nozzle diameter** — hardware (0.4 mm typically). NOT modelled here.
- **Extrusion line width** — the width of one deposited bead, a slicer setting (≈1.0–1.2×
  nozzle). **THIS is what we capture.**
- **Wall thickness** — `loops × width`. Derived, never entered.

Every new control is labelled **"… line width"** with a footnote on the sheet — *"Line
width is the width of one deposited wall bead (≈1.0–1.2× nozzle), not the nozzle
diameter."* — so a user cannot mistake it for the nozzle.

### The split: **Option (b)** — separate outer + inner line widths

Bambu Studio and OrcaSlicer expose the **outer** wall's line width **separately** from the
**inner** loops, and users routinely set them differently (a narrower outer for surface
quality, a wider inner for speed/strength). So `loops × one_number` is already an
approximation of what the slicer lays down. I chose **option (b)**: capture outer and
inner separately and size the ring as what the slicer actually deposits —

```
t = outer + (wall_loops - 1) · inner
```

one outer bead plus `(loops-1)` inner beads.

**Why (b), not (a):** the cost is small — the core already carried one
`wall_line_width_mm`; I added a sibling `wall_line_width_outer_mm` whose `< 0` value is a
**"mirror inner"** sentinel. When only one width is supplied (outer unset), the ring
collapses to `loops · inner` — **byte-identical** to the historical single-width formula.
So (b) is strictly more faithful with a zero-cost fallback to the old behaviour, and the
width-aware gate being OFF by default means the shipped optimizer output is unchanged
regardless.

`knockdown_spec_for` (`core/src/simp/production.cpp`) is the **one** place `t` is formed —
bridge, CLI and optimizer all read it, and `run_info` echoes it from the same function, so
the outer/inner split can never diverge between paths.

### Defaults (stated assumption)

Assume a **0.4 mm nozzle** and follow the Bambu/Orca 0.4-nozzle system profile:

- **Outer line width = 0.42 mm** (a hair narrower, for surface quality)
- **Inner line width = 0.45 mm** (the core's historical `wall_line_width_mm`, the value
  coupons 191/192 were measured at — so the inner term stays continuous with the
  calibrated knockdown)

Bounds 0.1–2.0 mm, step 0.02 mm (shared outer/inner).

## Files touched

**Core** (the physical model + schema + echo):
- `pipeline.hpp` — `MinimizePlasticOptions.wall_line_width_outer_mm = -1.0` (mirror-inner sentinel).
- `production.cpp` — `knockdown_spec_for` sizes `t = outer + (loops-1)·inner` (the ONE construction).
- `analyze.hpp` — `KnockdownSpec.wall_thickness_mm` doc updated to the split formula.
- `minimize_plastic.cpp` — validate outer width finite (sentinel < 0 allowed).
- `loadcase.hpp` / `loadcase.cpp` — `ProductionLoadCase.wall_line_width_outer_mm`, forwarded to opts.
- `job.hpp` / `job.cpp` — `JobLoads.wall_line_width_outer_mm`; schema accepts `loads.wall_line_width_outer_mm` in (0, 100].
- `run_job.cpp` — forwards the field; echoes effective outer + derived `wall_thickness_mm` (via `knockdown_spec_for`).
- `observability.hpp` / `observability.cpp` — `run_info` gains `wall_line_width_outer_mm` + `wall_thickness_mm`.

**Bridge** (on-device path):
- `TopOptBridge.hpp` — `BridgeLoadCase` gains `wall_line_width_mm` + `wall_line_width_outer_mm` (PR 218 never carried the width; now it must).
- `bridge.cpp` — forwards both onto the shared `ProductionLoadCase`.
- `TopOptKit.swift` — `minimizePlasticLoadCase` params + `bridgeWallLineWidthMM` / `bridgeWallLineWidthOuterMM` mappings (the parity seam).

**App** (capture + LAN path):
- `PrintParams.swift` — `wallLineWidthOuterMM` / `wallLineWidthInnerMM`, FDM defaults, bounds, steppers, `clamped()`, **custom Codable** (missing keys → defaults, back-compat).
- `PrintParamsSheet.swift` — two "Outer / Inner line width" controls grouped under Wall loops + disambiguation footnote (editable + locked modes).
- `RunModel.swift` — `RunRequest` carries both (part of request identity).
- `AppModel.swift` — threads them from `project.printParams`.
- `RemoteRunner.swift` — emits `loads.wall_line_width_mm` + `loads.wall_line_width_outer_mm` always.

## Bars

### N1 — run_info echoes what the user set (real job)
`evidence/.../N1_N5_run_info_echo.txt`. A real CLI run (`job_split.json`: 5 loops, inner
0.5, outer 0.4) → `run_info.json` echoes `wall_line_width_mm: 0.5`,
`wall_line_width_outer_mm: 0.4`, `wall_thickness_mm: 2.4` (= 0.4 + 4·0.5).

### N2 — both paths agree
Core `test_production_parity.cpp` asserts `knockdown_spec_for` sizes the split ring and
that a mirror-outer collapses to `loops·inner` byte-identically. App
`JobJSONEquivalenceTests.testWallLineWidthsAgreeAcrossBridgeAndCLI` asserts the LAN
`loads.*` and the on-device `bridgeWallLineWidth*` mappings produce the SAME values for one
`RunRequest` — the same divergence-class guard as the wall-loops parity test.

### N3 — byte-identical while width_aware_knockdown is false
`evidence/.../N3_byte_identical.txt`. Four CLI runs (no-wall baseline + three
width-carrying jobs) produce **identical md5s** for every ladder-rung STL. The widths only
form `wall_thickness_mm`, inert when the gate is OFF (the shipped default).

### N4 — pre-change project loads with a stated default
`PrintParamsTests.testLegacyPrintParamsJSONDecodesWidthsToDefault` decodes legacy
PrintParams JSON (six original keys, no widths) → widths default to 0.42 / 0.45 instead of
failing to decode. **Device-real:** `evidence/.../N4_N6_locked_sheet_device.png` — the
"Wall Bracket (round2)" project (saved before this change) opens and its locked sheet shows
Outer 0.42 mm / Inner 0.45 mm.

### N5 — maintainer's own settings (5 loops, 0.4 mm nozzle)
Under option (b) at the stated 0.4-nozzle defaults (outer 0.42, inner 0.45):
- **New model:** `t = 0.42 + 4·0.45 = 2.22 mm`
- **Old hardcoded:** `t = 5 × 0.45 = 2.25 mm`
- **Δ = −0.03 mm (−1.3%).** The true bead layout is a hair thinner because the single
  outer wall (0.42) is narrower than the inner loops (0.45); the old model over-counted it
  as a full 0.45 mm wall. Confirmed on a real job: `job_maintainer_defaults` →
  `wall_thickness_mm: 2.22`. (Inert today; the gate is OFF.)

### N6 — chips never two rows high (device-real)
`evidence/.../N4_N6_locked_sheet_device.png` — all eight sheet fields render as
single-row boxes in the 2-column grid; the two new line-width fields sit one-per-row with
the footnote below, no wrapping. The editable-mode controls reuse the identical
`decimalField` widget as the existing Layer-height field (minus / value / plus), which is
narrower per cell than the locked static box shown here.

## Not my regression

The full app `swift test` shows 8 failures, all in 3 `ThreeMF` import tests
(`AppModelTests.test*ThreeMF*`), failing with *"3MF import requires lib3mf, which is not
available in this build"* — the local `build_core.sh` slice lacks vcpkg lib3mf (see
handoffs `threemf-import-enabled`, `lib3mf-ios-silence-and-cmake4`). This is orthogonal to
this change, which touches zero 3MF code. All PrintParams / JobJSONEquivalence / core
job-schema / production-parity tests pass.

## Follow-up

`wall_line_width_mm` / `wall_line_width_outer_mm` are now fully plumbed. The width-aware
knockdown gate itself (`kProductionWidthAwareKnockdown`) remains OFF — arming it is still a
separate maintainer act gated on a physical-coupon calibration (see `production.cpp`).
