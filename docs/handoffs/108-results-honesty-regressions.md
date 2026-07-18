# 108 — Results screen: three honesty regressions + frame-rate collapse

**Branch:** `claude/results-honesty-regressions-954613`
**Territory (edited):** `ResultsScreen.swift`, `ResultsModel.swift`, `OutcomeStore.swift`,
`OrientationGizmoMetal.swift` (idle/throttle + one signpost only), the remote-fields /
outcome-store tests. **Read but NOT edited:** `RemoteRunner.swift`, `RunModel.swift`,
`WorkspacePlaceholder.swift`, `MetalMeshView.swift`, `OrbitCamera*.swift` (a sibling design
task owns `WorkspacePlaceholder`; the seam is kept clean).
**Handoff number:** **108** (first free ≥ current top; `docs/handoffs/` tops out at 107).

**Build status — actually run this time.** This session had a **macOS toolchain**. I ran
`./app/scripts/build_core.sh` (vendors `TopOptCore.xcframework`, ~56 s) and then
`swift test` in `app/TopOptKit`. **Full suite: 518 tests, 1 skipped, 0 failures.** Device
frame-rate I could **not** measure in-container — see STEP 3, which fixes what code inspection
proves and hands the maintainer the on-device Instruments checklist. No fps number is claimed
that I did not observe (I observed none).

Reproduce:
```
./app/scripts/build_core.sh
cd app/TopOptKit && swift test          # 518 tests, 0 failures
# focused:
swift test --filter ResultsRemoteFieldsTests --filter OutcomeStoreTests
```

---

## STEP 1 — Archaeology: where gating was severed

The observed symptoms are **(a)** chips read `0.0 g · plastic`, **(b)** a dead Stress chip,
**(c)** a fake bottom-to-top layer-sweep playbar, **(d)** the "computed on your Mac" note
missing, **(e)** ~1 fps. Two distinct severances produce these — not one.

### The `computedRemotely` flag is wired correctly end-to-end — but NOT persisted

I traced the live path hop by hop and it is **intact**:

- `RemoteRunner.swift:781` (each streamed variant) and `:835/:841` (the assembled final
  outcome) both set `computedRemotely: true`.
- `RunModel.appendStreamed` (`RunModel.swift:641`) carries `partial.computedRemotely`;
  `RunModel.finish` (`:734/:741`) sets `outcome = o` (the flagged RemoteRunner result).
- `WorkspacePlaceholder.swift:203` passes `run.outcome` straight through; `ResultsScreen.init`
  builds `ResultsModel(outcome:)`; `ResultsModel.apply` (`:792`) reads
  `computedRemotely = outcome.computedRemotely`.

So a **live** remote run is honest. The break is in **persistence**. Results persist across app
launches (`OutcomeStore` / `persist-c`), and the observation is a **reopened** remote run:

> **`OutcomeCodec.OutcomeDTO` never carried `computedRemotely`.** `dto(from:)` dropped it and
> `outcome(from:)` reconstructed `OptimizeOutcome` **without** it → it defaulted to `false`.

The flag was introduced by handoff **097** (commit `60e18b2`). `OutcomeStore` was even touched
**after** that (handoff 104, `0a612d9`, adding `printedFraction`) and *still* did not add the
field. So the moment a remote result is written to disk and reopened, the model rebuilds as
**local**, and:

- `buildTabs(remote: false)` → `massLabel(0)` → **`"0.0 g"`** → symptom **(a)**;
- `remoteComputeNote` guards on `computedRemotely` → **nil** → symptom **(d)**;
- the stress field is reconstructed empty and playback keyframes are absent → aggravates
  **(b)/(c)** (see below).

`ResultsScreen.swift:970` — `MeshExport.meshVolume`-based mass etc. is unaffected; this is
purely the persisted flag.

### The screen never gated two controls on the model (latent, pre-097)

Independently of the flag, the **screen** shows two controls unconditionally, disconnected from
the model gating the tests verify:

- **Stress chip** — `ResultsScreen.swift:934` (`vizRow(open: model.stressOn, …)`) had **no**
  data-presence gate, unlike the Flex/Load-path/Failure chips right below it (`if model.hasFlex`
  etc.). Blame: `2fabbb89` (2026-07-12). For a remote run the stress field is withheld (097),
  so the chip opened an empty legend over a body it can't tint → symptom **(b)**.
- **Playbar (`mediaPlayer`)** — `ResultsScreen.swift:156` sat in the `ZStack`
  unconditionally. Blame: `10c7be19` (2026-07-10). With no keyframes, `showsHistoryMorph` is
  false, so the slider drove `viewerReveal = playT`, **reveal-slicing the finished mesh
  bottom-to-top** — the fake "layer sweep." A remote run never serialises keyframes → symptom
  **(c)** every time.

### Why the tests were green while the UI lied — the two mechanisms

`ResultsRemoteFieldsTests` (097) is correct about the **model**, and the model is correct. It
was green while the UI lied for two reasons, and the fix closes **both**:

1. It built the model from an **in-memory** `OptimizeOutcome`, never round-tripping through
   `OutcomeStore`. The persistence DTO that dropped the flag was **never on the tested path**.
2. It asserted **labels** (`massLabel`, `selectedStressField == nil`), never the **control
   visibility** the screen actually branches on. The screen ignored those model props for the
   Stress chip and the playbar, so no model assertion could catch the dead/fake controls.

---

## STEP 2 — Restore honesty at the display path the screen uses

- **Persist the flag (root of a + d).** `OutcomeStore.swift`: `OutcomeDTO` gains
  `computedRemotely: Bool?` (optional → legacy blobs decode to `false`, correct: they predate
  remote runs). `dto(from:)`/`outcome(from:)` wire it. A reopened remote run is now honest at
  the source: n/a mass, note restored, gates false.
- **Gate the Stress chip (b).** New model prop `ResultsModel.hasStress` (mirrors `hasFlex`:
  `selectedStressField != nil && !isEmpty`). `ResultsScreen` wraps the Stress row in
  `if model.hasStress`. A remote run (or any variant without a von Mises field) hides it.
- **Gate the playbar (c).** `ResultsScreen`: `if model.hasHistory { mediaPlayer }`. No real
  keyframes → no playbar, so the reveal-slice fake layer-sweep is unreachable. When keyframes
  DO exist (local run), the playbar plays **them** exactly as before. (A labelled layer-sweep
  *preview* remains explicitly out of scope, per the task.)
- **Note (d).** Already rendered at `ResultsScreen.swift:146`; the persistence fix makes
  `computedRemotely` true on reopen, so it reappears — no view change needed.

### Tests re-pointed so the same lie can't pass again

- `OutcomeStoreTests`: `testComputedRemotelySurvivesRoundTrip` (encode→decode a remote outcome,
  assert the flag holds) and `testDecodesLegacyBlobWithoutComputedRemotely` (missing key →
  `false`). The main round-trip test now also asserts a local outcome stays local.
- `ResultsRemoteFieldsTests`: **new** `testRemoteHonestySurvivesPersistRoundTrip` drives the
  model through the **same `OutcomeCodec.encode/decode` the store uses**, then asserts the
  restored model is still honest (mass n/a, note present, `hasStress`/`hasHistory` false,
  geometry renders). The existing test now also asserts `hasStress == false` — the exact prop
  the screen branches on, tying the test to what the screen renders, not just the labels.

### Incidental fix required to build (in-territory)

`OutcomeStore.dto(from:)` passed `printedFraction` **before** `massGrams` to the `VariantDTO`
memberwise initializer, whose declaration order is `massGrams` then `printedFraction` — a hard
compile error. It shipped on `main` because handoff 104 (which introduced it) and the export
batch were authored in Linux containers that **can't run `swift test` past the C++ link**
(see the `app-worktrees-need-build_core` note), so the whole target never compiled there. One
line reordered; the suite now builds.

---

## STEP 3 — Performance (~1 fps): instrument, fix what inspection proves, hand off the rest

**I cannot measure frames in this container.** The 1 fps is the maintainer's device
observation; I did not reproduce or quantify it. What I did: ruled out one suspect, fixed the
one provable waste, and shipped signposts + an Instruments checklist.

**Ruled out — per-frame mesh re-upload.** `MetalMeshView` gates re-upload on `meshSignature`
(`MetalMeshView.swift:221`), an O(1) count+bounds tuple, *identity-independent*. So
`ResultsModel.selectedMesh` allocating a fresh `ViewerMesh` per access does **not** cause a
re-upload, and the main viewer is `isPaused = true` (render-on-demand). Not the sink. (Out of
territory regardless.)

**Fixed — the gizmo's free-running display link (provable waste).**
`OrientationGizmoMetal.swift` ran the raymarched-SDF `MTKView` **continuously at 60 fps whenever
Reduce Motion is off** — forever, even sitting untouched — purely for a decorative idle-float.
Now it runs continuously **only while the user is actively dragging the glass**; otherwise it
**pauses and redraws on demand**. Every pose change that matters still paints exactly once: a
viewer/gizmo drag publishes each orbit delta, and an animated snap/home eases via the camera's
**own** `CADisplayLink` (`OrbitCameraModel.startClock` → per-frame `@Published camera`), both
caught by the gizmo's camera sink (`bind`, which requests a redraw while paused). This is
exactly "idle when the orientation is unchanged."
**Disclosed trade-off:** the decorative idle wobble no longer plays while idle. Reduce Motion is
unchanged (it was already on-demand and still).

> **Honest caveat on causation.** The workspace hosts the *same* gizmo and is smooth, so the
> gizmo's continuous cost is not, by itself, proven to be the 1 fps. It IS provable, unconditional
> waste that the results screen (heavier mesh + overlays + the 30 fps ticker) is a plausible
> place to feel. The fix is correct on its own merits (battery + GPU idle); whether it fully
> resolves the collapse needs the device measurement below.

**Signposts shipped** (subsystem `com.topopt.results`; zero-cost when not recording):
- `GizmoFrame / gizmo_draw` — interval around each raymarch. Near-continuous = the bug;
  near-silent when parked = the fix working.
- `ResultsFrame / body_eval` — event per SwiftUI re-evaluation of the results screen.
- `ResultsFrame / playback_tick` — event per ticker tick that actually advances an animation.

**On-device Instruments checklist for the maintainer (I could not run these):**
1. **Time Profiler + os_signpost**, results screen idle (nothing touched): if `body_eval` fires
   in a steady stream → a state source is invalidating the view every frame (start with the
   shared `OrbitCameraModel` and the `Timer.publish` ticker at `ResultsScreen.swift:71`).
2. **Metal System Trace / GPU counters:** confirm `gizmo_draw` intervals are sparse after this
   fix (only during drag/snap). Compare GPU % idle vs. before.
3. **Add a signpost around `MeshRenderer.draw`** (in `MetalMeshView`, out of this task's
   territory) to see whether the *main* viewer is redrawing when it shouldn't.
4. Toggle **Reduce Motion** and re-measure — it was already on-demand, so it's a useful A/B for
   whether the gizmo link was the dominant cost.

---

## Not done / follow-ups (deliberately out of scope)

- **`appliedClearances` is also dropped by `OutcomeStore`** (same DTO gap as the flag was): a
  reopened run loses its honest "Keep clear" notes. Same class of bug, but the task named the
  `computedRemotely` symptoms and the keep-clear seam is a sibling area — left for a focused
  follow-up rather than widening this diff. Fix is identical (add an optional DTO field).
- **Playbar cosmetic gap:** `savingsTabs` keeps its `.padding(.bottom, 92)` that used to clear
  the now-sometimes-absent playbar; harmless extra space on historyless runs, device-QA only.
- **Device fps is unmeasured** — see STEP 3.
