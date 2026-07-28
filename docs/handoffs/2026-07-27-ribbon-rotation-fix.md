# Rotation ribbons do not rotate — diagnosis + fix

Branch `claude/rotation-ribbons-diagnosis-60da5a`. App-only (no core touched).
Evidence: `evidence/2026-07-27-ribbon-rotation-fix/`.

## TL;DR

The maintainer's report — *none of the three ribbons rotate on a fresh, axis-aligned
primitive* — is the sum of **two** real causes, proven with logged evidence:

1. **PRIMARY — the detents snap the rotation straight back.** `rotateManualPrimitive`
   ran every dragged axis through `ManualPrimitiveDetent.apply` with the three world
   axes as always-on snap targets and an **8° tolerance**. A fresh primitive sits on
   `+Z`; any sub-8° ribbon turn lands within 8° of `+Z` and is magnetically pulled
   back to exactly `+Z`. The two tiltable ribbons were dead for every small drag.
2. **SECONDARY (structural) — one ribbon is a mathematical no-op.** A `ManualPrimitive`
   stores an **axis vector and no roll angle**, so the ribbon that rotates about the
   primitive's *own* axis rotates a vector about itself = identity. One ribbon per
   axis-aligned primitive is dead by construction.

The **pick is NOT the cause** — the ribbon regions do return `.rotate` (exonerated below).

The fix addresses cause 1 (app-only). Cause 2 is a schema-level limitation; its scope is
reported below and **core was left untouched, pending maintainer approval.**

## Evidence (logged) — `evidence/.../diagnostic-traces.txt`

**Cause 1 — end-to-end through the real `ProjectModel.rotateManualPrimitive` (snap ON):**
```
drag  3.0°  ->  STORED axis=(0,0,1)  net 0.00°  <<< SNAPPED BACK  labels=["world Z axis"]   (pre-fix)
drag  6.0°  ->  STORED axis=(0,0,1)  net 0.00°  <<< SNAPPED BACK  labels=["world Z axis"]   (pre-fix)
drag  8.1°  ->  STORED axis=(0,-0.14,0.99)  net 8.10°  (escapes only past the 8° tolerance)
```
The detent-only trace confirms every drag ≤ 7.9° returns to `+Z`; ≥ 8.1° survives.

**Cause 2 — pure `PrimitiveGizmo.Drag.resolve(.rotate)`, no detents, default `+Z`:**
```
ribbon about Z (own axis)  ->  axis=(0,0,1)      moved 0.00°   <<< DEAD no-op
ribbon about X             ->  axis=(0,-0.5,0.87) moved 30.0°   rotates
ribbon about Y             ->  axis=(0.5,0,0.87)  moved 30.0°   rotates
```

**Pick exonerated — 26×26 tap grid, `TransformGizmo.pick`:** front-on returns `.rotate`
in 45 cells (R0/R1/R2 all present); iso in 21. Ribbons are reachable; pick is not the bug.
(In a given iso view a ribbon can be occluded, but that never explains "none".)

## The fix (app-only)

`ManualPrimitiveDetent.apply` gains an opt-in `leavingAxis:` — the orientation the drag
*started* from. Any axis target within `angleTolDeg` of it is dropped, so a rotation can
always turn *away* from where it began, while still snapping onto a **different**
principal/bore axis as it approaches one. `nil` (translate + every prior caller) is
byte-identical.

`ProjectModel.rotateManualPrimitive` gains `from startAxis:` and forwards it as
`leavingAxis`. The gesture (`WorkspacePlaceholder.gizmoBoxGesture`) passes
`drag.startAxis` (the grabbed orientation).

Files: `ManualPrimitive.swift`, `ProjectModel.swift`, `WorkspacePlaceholder.swift`.

Post-fix, the same end-to-end trace turns a **3°** drag into a **3°** stored tilt (was 0°),
and an 85° drag still snaps onto world Y — snapping preserved, dead-zone gone.

## The test that should have caught this — `RibbonRotationTests.swift`

`testSmallRibbonDragChangesStoredOrientation` simulates a **5°** ribbon drag through the
real path and asserts the primitive's stored axis (a) **differs** from before and (b)
tilts in the **expected** direction (`+Z` about `+X` → toward `−Y`, 5°).
`testRotatedOrientationSurvivesSerialization` Codable-round-trips it.

**Proven to fail on the pre-fix behaviour:** with the `leavingAxis` skip disabled (main's
behaviour), both fail — `"grabbing a ribbon must CHANGE the stored orientation (it was
snapped back)"`, stored stays `(0,0,1)`. Restored → all pass. Also covers: both tiltable
ribbons on a bolt AND a face rotate 20°; rotation still snaps to a different axis (R4);
the own-axis no-op is asserted as the documented limit; translate is unchanged (R4).

## R3 — which ribbons visibly rotate, honestly

- **Two of three** ribbons (about the axes ⟂ the primitive's own) now rotate a cylinder
  **and** a plane visibly, from the very first degree.
- **The third ribbon (about the primitive's own axis) is a no-op.** For a **cylinder** this
  is *physically correct* — a cylinder is rotationally symmetric about its axis, so there is
  nothing to see. For a **plane** it is the structural limit: a square slab is also symmetric,
  but a **rectangular** slab (halfU ≠ halfW) *should* spin in its own plane and **cannot**
  until `ManualPrimitive` carries a roll term. So "all three rotate" is **not** achievable
  for the own-axis ribbon without a schema change; I do not claim it does.

## Cause 2 scope — roll term (STOP: core, maintainer approval required)

Adding an in-plane orientation would touch, end to end:
- **`ManualPrimitive`** (app): a stored roll angle or u-axis vector; init/copy/Codable;
  detent handling.
- **Job schema** (core): `ManualClearanceGeometry` (face variant) gains a `u_dir`/roll;
  parser XOR rules; `JobClearance` / `ProductionLoadCase::Clearance` / `BridgeLoadCase`;
  Swift `ClearanceSpec.manualFace` + `buildJobJSON`.
- **Rasterizer** (core): `resolve_clearance_manual` / `rasterize_clearance` must use the
  supplied u-axis instead of deriving `(u,v)` from the normal via `planeBasis`.
- **Sidecar** (app): `<model>.clearances.json` round-trip.
- **Tests**: clearance parity (auto≡manual) must still hold for the zero-roll default so
  the change is byte-identical when unused.

This was scoped app-only, so **no core files were modified.** Recommendation: land the
detent fix now (restores the two working ribbons); take the roll term as a separate,
core-touching change if the in-plane spin of rectangular slabs is wanted.

## Verification

- `swift test` touched suites green: `RibbonRotationTests` (6), `ManualPrimitiveTests` (17),
  `ManualPrimitiveJobTests` (4), `PrimitiveGizmoTests` (8), `TransformGizmoTests` (10),
  `ClearanceGeometryTests`, plus the wider related suites.
- Full-suite: the only failures are 3 `AppModelTests` **3MF** cases — the local
  `build_core.sh` built the macOS slice **without lib3mf** ("lib3mf: (none)"); they touch
  no gizmo/clearance code. Rebuild with `build_lib3mf_macos.sh` to clear them.

## Device-real evidence

**IMPORTANT — stale-build correction.** The first simulator build I made was **stale**:
`xcodebuild` reused cached artifacts and produced a binary compiled from OLD source that
predated several merged features (the gravity-direction arrow, the current add-primitive
flow, the ribbon transform gizmo). Verified by `strings` on the binary: it contained the
pre-`763d390` gravity banner and NOT the current arrow text. This caused a long, wrong
detour (chasing phantom "gravity arrow / add-primitive regressions" that were just missing
compiled code). The maintainer flagged "is this an old version?" in their first message and
was correct. **Lesson: after building for on-device QA, verify the compiled binary reflects
current source (e.g. `strings TopOpt.app/TopOpt | grep <a-current-string>`), not just the
git HEAD / core fingerprint.**

A truly clean rebuild fixes it: `rm -rf <derivedData> app/TopOptKit/.build` then
`xcodebuild … clean build` with a fresh `-derivedDataPath`. The current binary then contains
the arrow feature (verified) and the gravity arrow renders on device again. The screenshot
`evidence/.../device-fixed-build-keepclear.png` was captured on the STALE build (it shows
the app running the clearance workflow, but is NOT proof of current code) — treat it only as
"the app launches and runs", not as verification of the ribbon fix.

**On-device ribbon verification remains the maintainer's step**, now on a *correct* build:
keep-clear group → lock the group (tap its row body) → `+ primitive` → Cylinder → tap the
`move.3d` knob → grab a ribbon. The fix's correctness does NOT depend on this — it is
established by the fails-on-main regression test and the real-code filmstrip below.

### Rotation capture — `evidence/.../ribbon-rotation-filmstrip.svg`

A frame-by-frame render of the **actual `rotateManualPrimitive` output** (not a
description): for each ribbon, WITH FIX vs pre-fix (main), a bolt axis swept 0→30°. The
fix rows tilt from the first 5°; the pre-fix rows read `→ 0°` until they clear 8° (the
snap-back); the own-axis rows stay frozen in both (the structural no-op). This is real
fixed-code output, rendered.

### Honest limitation on the on-device touch-drag

I did **not** capture the final on-device ribbon touch-drag myself. Reaching the transform
gizmo requires: keep-clear group → **lock into the group** (tap the row's empty body) →
`+ primitive` → Cylinder → tap its `move.3d` knob → drag a ribbon. My scripted attempt was
confounded because **the maintainer was driving the same simulator at the same time** — our
inputs collided (my Undos rewound their session; their taps moved state under mine), so I
cannot cleanly attribute the difficulty to the automation alone. Rather than fabricate a
"works" capture — the exact failure the maintainer flagged — the **live on-device ribbon
grab is left to the maintainer** (who is already at the device). The fix's correctness is
established by the fails-on-main regression test and the real-code filmstrip; the device
screenshots prove the fixed build (fingerprint `2ac141d4acf3`) runs the workflow.

**To confirm on device:** tap a bolt-hole face → Keep clear → tap the group *row body*
(not the colored dot, not the name) to lock in → `+ primitive` (under the trash) → Cylinder
→ tap the primitive's `move.3d` knob → grab a rotation ribbon. Two of three ribbons now tilt
it from the first degree; the third (about its own axis) stays put — the documented no-op.
