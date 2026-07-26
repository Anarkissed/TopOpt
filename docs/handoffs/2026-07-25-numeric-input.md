# Numeric input system + preset name (app-only)

## Problem

Changing any number in the app raised the **full system keyboard**: a triple‑tap to
bring it up, the caret stranded at the far right of the field, and digits appended to
whatever was already there. This was the behaviour of *every* numeric input — the load
weight chip, the clearance pills, the print‑parameter fields, the compute‑location port
— not just the load chip.

## What shipped

**One shared numeric‑entry component**, `NumberPad`
([NumberPad.swift](../../app/TopOptKit/Sources/TopOptFlows/NumberPad.swift)):

- A **single tap** on any numeric chip opens a **compact on‑screen pad anchored beside
  that chip** — a SwiftUI `.popover`, never the system keyboard, never a modal sheet. On
  iPad (regular width) `.popover` is already an anchored floating panel; a guarded
  `presentationCompactAdaptation(.popover)` keeps it a popover on a compact width too.
- **The first keystroke replaces the whole value.** The pad opens seeded with the chip's
  current value; the first digit/decimal clears it (`NumberPadEntry.touched`), so the
  user never positions a caret. Backspace edits the seed in place as a nudge affordance.
- The behaviour is split into a **pure, headless state machine** (`NumberPadEntry` —
  replace‑on‑first‑key, single decimal point, no leading zeros, parse) unit‑tested
  directly, and a thin SwiftUI shell (the pad grid) which is maintainer device QA, per
  the established /app/ rule (same split as `ClearanceScrub`/`GlassValuePill`).
- Every site emits its **live parsed value on each keystroke through its normal setter**,
  so a value typed on the pad flows through the *same* code path (and therefore the same
  `UndoHistory` and the same unit handling) as a scrub — there is no parallel entry path.

Callers attach it with one modifier:

```swift
someChip
  .numberPad($presented,
             config: .init(title: "Margin", unit: "mm", allowsDecimal: true),
             seed: currentValue) { v in /* write v through the normal setter */ }
```

## B1 — every numeric input, enumerated and converted

The exhaustive sweep of `app/TopOptKit/Sources/TopOptFlows/` (and `app/TopOpt/`) found
these numeric‑entry sites. "Raised keyboard?" is the *before* state.

| # | Input | File | Was | Raised keyboard? | Now |
|---|-------|------|-----|:---:|-----|
| 1 | Load weight (kg/lbs) | `WorkspacePlaceholder.weightPill` | bare `TextField` | **yes (default kbd)** | tap → `NumberPad`; scrub kept; unit preserved |
| 2 | Clearance **Margin** | `GlassValuePill` @ WorkspacePlaceholder 1383/1787 | `TextField .decimalPad` | **yes** | tap → `NumberPad`; scrub kept |
| 3 | Clearance **Axial** | `GlassValuePill` @ 1388/1791 | `TextField .decimalPad` | **yes** | tap → `NumberPad`; scrub kept |
| 4 | Clearance **Depth / slab** | `GlassValuePill` @ 1393/1796 | `TextField .decimalPad` | **yes** | tap → `NumberPad`; scrub kept |
| 5 | **Layer height** (mm) | `PrintParamsSheet.decimalField` | `TextField .decimalPad` | **yes** | tap value → `NumberPad`; ± steppers kept |
| 6 | **Wall loops** | `PrintParamsSheet.intField` | `TextField .numberPad` | **yes** | tap value → `NumberPad`; ± steppers kept |
| 7 | **Top shell layers** | `PrintParamsSheet.intField` | `TextField .numberPad` | **yes** | tap value → `NumberPad`; ± steppers kept |
| 8 | **Bottom shell layers** | `PrintParamsSheet.intField` | `TextField .numberPad` | **yes** | tap value → `NumberPad`; ± steppers kept |
| 9 | **Infill density** (%) | `PrintParamsSheet.infillStepper` | `TextField .numberPad` | **yes** | tap value → `NumberPad`; ± steppers + slider kept |
| 10 | Compute‑location **Port** | `ComputeLocationControl` | `TextField .numberPad` | **yes** | tap value → `NumberPad` |

`GlassValuePill` is one component rendered at **six** call sites (viewport ×3 +
Selections panel ×3), all converted by the single change to the pill — rows 2–4 cover
all six.

### Sites that are numeric but were already caret‑free (left as‑is, by design)

- **Design box X/Y/Z dimensions** — there is **no typed input** for the box anywhere; it
  is sized purely by 3D drag handles (`DesignBoxDrag`/`DesignBoxHitTest`). Nothing raised
  a keyboard, so there was nothing to convert. (Decision confirmed with the requester:
  leave drag‑only, document it. Adding W/D/H pads would be a new feature, not a
  conversion.)
- **Face‑protection depth** (`faceProtectDepthChip`) — a **tap‑to‑cycle** button stepping
  3→5→8→12 mm. No keyboard, no caret; left as a cycle.
- **Sliders** — infill density (paired with the now‑converted number), and the five
  Results visualization sliders (deflection ×, flow speed/wiggle, push, playback scrub).
  Drag inputs, no keyboard.

## B2 — no path raises the system keyboard for a number (demonstrated)

Not asserted — shown by grep over the source (full output:
[evidence/…/b2_no_numeric_system_keyboard.txt](../../evidence/2026-07-25-numeric-input/b2_no_numeric_system_keyboard.txt)):

- `grep -rn '\.keyboardType(\.decimalPad)\|\.keyboardType(\.numberPad)'` → **no matches.**
- The only surviving `.keyboardType` is `.URL` on the manual **host** field — text, not a
  number.
- Every remaining `TextField` is text: Host/IP, Preset name, project Name (×2), Group
  name. Every numeric field now opens the `NumberPad` popover.

## B3 — first keystroke replaces (tested)

`NumberPadTests.testFirstDigitReplacesTheSeed`: pad opens showing `12.5`; first key `3`
leaves `3`, not `12.53`. Plus decimal rules, no‑leading‑zeros, single decimal point,
backspace, empty→nil, and the "trailing dot never flickers to nil" guard. Illustrated in
[03_replace_on_first_key.png](../../evidence/2026-07-25-numeric-input/03_replace_on_first_key.png).

## B4 — undo/redo covers pad‑entered values (tested, existing history)

`ProjectModel.force`/`designBox` are `@Published` and part of `EditSnapshot`; the pad
writes through the same `ForceModel` setters a scrub uses, so a pad entry arms the same
debounced `UndoHistory` (PR 173) — no parallel stack.

- `testUndoRedoCoversLoadWeightEnteredThroughTheNumberPad`: a settled 2.5 kg, then a pad
  entry of 42 → **undo** reverts to 2.5, **redo** restores 42.
- `testUndoCoversClearanceMarginEnteredThroughTheNumberPad`: same for a `GlassValuePill`
  margin write.

**Scope note on print parameters:** the print‑params sheet is a separate
creation‑time modal, and `printParams` is intentionally *not* in `EditSnapshot` (it is
locked at creation, and the workspace two‑finger undo does not reach into the sheet).
Per the "don't fork a second history" constraint, I did **not** add a parallel undo for
the sheet; the pad there writes through the existing bindings, and the sheet's own
clamp‑and‑lock on close is unchanged.

## Preset name on the Presets button (+ dirty marker) — decision & justification

The sheet's preset button used to always read **"Presets"**. Now
`AppModel.presetButtonLabel()` drives it:

- No preset chosen this project → **"Presets"**.
- A preset selected and values still match → **its name** (e.g. "PLA Fine").
- Values edited away from it → **"PLA Fine · Edited"**.

**Decision: a dirty marker, not a revert to "Presets."** Justification — the preset name
is *provenance the user deliberately chose*; it tells them these values started from
"PLA Fine". Reverting to the generic "Presets" would discard that context at the exact
moment it matters most (they're mid‑tweak: "this is PLA Fine but I bumped infill"). The
"· Edited" marker is the document‑editor convention ("Title — Edited"): honest that the
values no longer equal the saved preset while preserving the lineage. Re‑selecting the
preset — or editing the values back to match — clears the marker, because dirtiness is
**derived** (`params == preset.params`), never a stored flag, so it self‑corrects.
Selection resets to "Presets" when a different project opens. Covered by
`PrintParamsTests.testPresetButtonLabelTracksSelectionAndDirtiness` and
`…ResetsWhenAnotherProjectOpens`.

## Constraints

- **Round‑6 "chips never two rows high":** the pad is a *popover*, not a chip — no chip
  grew. The clearance/weight chips keep their exact one‑row rendering (only the tap
  target's *action* changed from "raise keyboard" to "open pad").
- **Existing UndoHistory:** see B4 — same setters, same stack.
- **Units keep working:** the weight pad edits in the current unit (`force.unit.label`)
  and converts back to kg on write, so typing a number never silently changes the unit;
  kg/lbs and mm toggles are untouched.

## B5 — device‑real evidence (and an honest limitation)

The change is a touch‑target + keyboard‑behaviour change; the project standard is that
nothing is done until it works on the device. **I cannot drive a physical iPad from this
environment** (the tooling is simulator‑only), so the final on‑device pass is the
maintainer's — consistent with this project's documented "SwiftUI shell = maintainer
device QA" convention (the same note lives in `GlassValuePill.swift` and the round‑6
capture tests). What I *can* and did verify:

- **The full app builds and launches on the iPad simulator** —
  `xcodebuild … -scheme TopOpt … BUILD SUCCEEDED`, then launched on iPad Pro 11″ (M5):
  [05_app_launches_on_ipad_sim.png](../../evidence/2026-07-25-numeric-input/05_app_launches_on_ipad_sim.png).
- **The pad renders correctly** via the project's own offscreen `ImageRenderer` evidence
  path (`NumberPadEvidenceCaptureTests`):
  [01_number_pad.png](../../evidence/2026-07-25-numeric-input/01_number_pad.png),
  [02_pad_anchored_beside_chip.png](../../evidence/2026-07-25-numeric-input/02_pad_anchored_beside_chip.png),
  [03_replace_on_first_key.png](../../evidence/2026-07-25-numeric-input/03_replace_on_first_key.png),
  [04_integer_pad.png](../../evidence/2026-07-25-numeric-input/04_integer_pad.png).
- **B2/B3/B4 are proven structurally + headlessly** (grep + tests above), which do not
  depend on a device.

**Maintainer device checklist (the one step I can't run):** on a real iPad, tap each of
the 10 inputs above and confirm (a) the pad appears anchored beside the chip with *no*
system keyboard, (b) the first digit replaces, (c) two‑finger undo reverts the value, and
(d) the kg/lbs and mm toggles still convert.

## Tests

- New: `NumberPadTests` (14 — the state machine + two undo‑integration cases). All pass.
- New: `NumberPadEvidenceCaptureTests` (4 — render the pad to the evidence dir).
- Extended: `PrintParamsTests` (+2 — preset‑button label + reset).
- Full suite: green except the **pre‑existing** `PaintModeUITests
  .testShelfBracketBackFacePaintedAnchorMatchesTap` failure, confirmed failing on the
  clean base with this work stashed (mesh‑fixture issue, unrelated to numeric input).

## Files touched

- **New** `NumberPad.swift`, `NumberPadTests.swift`, `NumberPadEvidenceCaptureTests.swift`
- `GlassValuePill.swift` — tap opens the pad; removed the `.decimalPad` TextField branch
- `WorkspacePlaceholder.swift` — `weightPill` opens the pad; removed the TextField branch
- `PrintParamsSheet.swift` — 5 fields open the pad; preset button shows the preset name
- `ComputeLocationControl.swift` — port opens the pad
- `AppModel.swift` — `selectedPresetID` + `presetButtonLabel()`; set on apply/save, reset on open
- `PrintParamsTests.swift` — preset‑label coverage
