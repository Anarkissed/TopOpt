# Surface stage: four interactions and a set of assertions

Task `surface-stage-gestures`. **PRODUCTION**, `app/` only — the Surface stage's input
handling. Evidence: `evidence/2026-08-17-surface-stage-gestures/`.
Base: `main` at `500833ed` (PR 338 merged).

The maintainer's verdict on this stage was *"It doesn't do exactly that. But I am happy
with what it has… it's the best possible stage thus far."* So this is four interactions
and a set of assertions. The stage was not redesigned.

---

## §0 — the one-liners

**The similar-face match count on his part, against 24-of-78.** PR 331's number is
reproduced exactly — its part-level blend filter still matches **24 of 78**, kind-only
still **misses 13** and **over-catches 19**. The double tap does not use that filter: it
uses the shipped `surfaceSimilarFilter(to:)`, whose threshold is read off the *tapped*
face, so the answer is per seed — on his 78 faces it is **1–32, median 7, mean 9.81
(12.6% of the part)**, where a kind-only filter's worst seed still takes **36 of 78 (46%)**.
Both numbers are measured from the same STEP file in
`r2_similar_match_count.txt`; §R2 below says why they differ before assuming mine is right.

**How select-tool taps are disambiguated from the cut and pattern tools.** One table,
`SurfaceTool.meaning(taps:tool:surfaceStage:)`, asked twice. It decides whether the
double-tap recognizer is even *enabled* (only with Select armed, only on the Surface
stage), and the handler asks it again before acting. Under a cut, pattern, union or
similar the recognizer is disabled, a second tap is two single taps exactly as today, and
those tools keep their immediate pick — a mounted double tap costs every single tap the
system's double-tap interval, so mounting it only where it means something is a
performance fact and not just tidiness.

**What happens in pencil mode with no pencil paired.** Nothing is withheld. There is no
"is a pencil paired" API, so the only honest signal is a `UITouch` of type `.pencil`
having arrived; until one has, `SurfaceInputDiscipline.enforced` is false and a finger
goes on editing. The button still latches (it is a preference) and the stage says so in
its one hint line: *"Pencil only — no pencil seen yet, so fingers still edit."* The moment
a pencil touches the glass the separation engages with nothing further to press.
Screenshot: `03_pencil_mode_on_no_pencil_seen.png`.

**Undo and redo survive pencil mode.** `SurfaceIntent` has three cases, and `undoRedo` is
one of them — `admits(_:_:)` returns true for it unconditionally, from either contact, in
every mode. The two-finger and three-finger double-tap recognizers are not routed through
the discipline at all. Failing test first: `testUndoAndRedoSurvivePencilModeFromEitherContact`,
written against the obvious wrong implementation ("fingers may not act"), which kills them.

**The bottom-right control stack was not touched.** No chip added, none removed, no space
reserved for "Lattice This". `git diff --stat` below; the only file outside the Surface
stage's own input handling is one line of `ProjectModel.commitSurfaceCut`, which is the
rotate angle's consumer.

---

## §1 — the taps

**A single tap with Select selects one face** (already true; now asserted).
**A double tap with Select selects every face like it.**

The second tap arms the **Similar** tool on the tapped face — it does not invent a
parallel mechanism. That buys three things for free:

- **The rule is PR 331's measured signature** (§1c). `surfaceSimilarFilter(to:)` is same
  kind, bores matched by radius *ahead of* the blend rule, and a size band rather than
  kind alone. A `kind`-only filter has already been proven wrong on this exact bracket and
  is not used.
- **The count is reported** (§1d) — on the action cluster ("*N* selected" / "1 like this")
  and in the hint line, before anything commits. `02_similar_selection_count_reported.png`.
- **He can correct it by tap** (§1d). A further tap adds a kind; a tap on a face the
  selection already covers drops *that* kind, not just the seed. Nothing is committed
  until ✂ or another tool is chosen — `testTheMatchIsCorrectableByTapAndCommitsNothing`
  asserts `faceRegions` is still empty after the selection.

Mechanics: one tap recognizer per contact kind (finger / pencil), as the pan recognizers
already are, so "which contact was this?" is a fact rather than an inference from touch
counts. Each single tap requires only *its own* double-tap sibling to fail, so a pencil
double tap never delays a finger's pick. Both taps resolve the face through the same ray
(`pick(at:in:deliver:)`), so they cannot disagree about what was under them.

macOS gets the same two meanings via a second `NSClickGestureRecognizer`; AppKit has no
`require(toFail:)`, so there the first click selects and the second supersedes it — same
end state, and a plain click stays instant.

## §2 — the pencil mode button

`SurfaceInputDiscipline` — a pure value type modelled on `BrushGesture`, which exists
because the same question ("may this contact do this?") was once answered from two
different flags and the pencil-only smoothing brush disarmed the pencil.

- **Off by default** (§2b): both contacts do everything, exactly as the stage behaves today.
- **On**: editing is pencil-only, camera movement is fingers-only. A pencil drag no longer
  orbits; a finger tap no longer picks.
- **`.off` on every other stage.** This task owns the Surface stage's input handling and
  nothing else, so no other stage's gestures can change under the button.
- The button: 44 × 44, `DS.Radius.pill`, `applepencil` at 17 pt semibold, `accentDeep` at
  0.55 when on — the same pattern as the wireframe and x-ray switches it sits beside.
  Checked against the topology screenshot line by line in
  `00_look_rules_read_off_the_screenshot.md`.

## §3 — rotate with 15° detents

**Which of §3(b) I built: settle on release, plus a haptic tick at each detent crossed.**
Not a resistance curve — bending the angle away from the finger mid-drag makes the readout
disagree with the hand, and on a knob geared at 0.8°/pt that reads as the control sticking.
The drag stays exactly linear.

**And §3(c) was a real defect, not a nicety.** The drag used to end in `SurfaceCut.snap`,
a *quantiser*: every release landed on a multiple of 15, so 37° became 30° and there was
no way to ask for 37° at all. `SurfaceCut.settle` takes a release **within 3°** of a
detent and otherwise keeps the angle to the degree. Three degrees is a fifth of the
spacing — about 4 pt of travel either side, so landing on a detent needs no aim while four
fifths of every gap stays freely reachable.

`settle` is idempotent, which is what let it replace `snap` at *every* consumer — the
preview line, the move-drag's screen-space sign, the angle readout and the commit — so a
free angle survives all the way to the cut plane instead of being quantised on the way.
`snap` is kept for the ¼-turn button, which means "square to what it is now".

Measured on his part: the drag reached **36°** (`04b_rotate_readout_36deg.png`) and the cut
committed there (`05_cut_committed_at_the_free_angle.png`). The ¼-turn button then took
36.8° to **120°** — onto a detent, as it should (`04c`).

## §4 — the three-stage visibility rule

One test per stage, each naming what must and must not be present.
These are **assertions, not changes** — every stage already behaved this way.

| Stage | MUST | MUST NOT |
|---|---|---|
| Topology | design box, group primitives, keep-outs; group row = clearance editor | lattice depth planes, lattice controls, surface editing |
| Lattice | lattice depth planes, lattice controls; group row = the three lattice sections | design box, group primitives, keep-outs, surface editing |
| Surface | surface editing only | design box, group primitives, keep-outs, lattice depth planes, lattice controls |

Plus: the wireframe and x-ray controls are offered on all three (§5d, untouched), and a
fourth stage added later fails `testEveryStageHasARowInTheTable` rather than quietly
inheriting whatever the switch's last case happened to be.

---

## The bars

**R1 — demonstrated on `M2_verticalStand.step`.** Screenshots 00–07. Entered the Surface
stage, single-tapped one face (`01`→ the lit band), reached the similar selection with its
count reported (`02`), toggled pencil mode (`03`), rotated a cut through the detents to a
free 36° and committed it (`04`, `04b`, `04c`, `05`), undid it and redid it (`06`, `07`).

★ **Two things could not be injected and are not claimed.** The simulator harness has no
multi-tap primitive — two sequential taps land about a second apart, well outside the
system double-tap interval — so **the double tap itself and the two/three-finger
undo/redo double taps could not be driven on the device.** What is shown instead is the
*destination state* of each (the similar selection with its count; undo and redo through
the header buttons, which run the same `project.performUndo()` / `performRedo()` the
gestures call), and the routing is pinned headlessly by `SurfaceTapMeaningTests` and
`SurfaceInputDisciplineTests`. This limitation is not new to this task: it applies equally
to the undo/redo gestures that shipped in round 6.
★ **And the enforced half of pencil mode cannot be exercised on a simulator at all** —
there is no pencil hardware, so no `.pencil` `UITouch` can ever arrive. That is precisely
the case §2(c) is about, and `03` shows the stage saying so on screen rather than
pretending.

**R2 — the match count.** `r2_similar_match_count.txt`. PR 331's 24-of-78 / 13 missed / 19
over-caught reproduced to the face, and asserted so they cannot drift. My per-seed numbers
differ because they are a different measurement, not a better one: PR 331 evaluated one
filter over the whole part at 0.25 × the median area; the double tap derives its filter
from the tap. Three of his 78 seeds happen to give exactly 24.

**R3 — undo/redo with pencil mode on.** `testUndoAndRedoSurvivePencilModeFromEitherContact`,
failing-first against the naive implementation. `SurfaceIntent.undoRedo` is a named case so
nobody can withhold it by folding it into `edit`.

**R4 — one visibility test per stage.** `ThreeStageVisibilityTests`, table above.

**R5 — nothing that already works regresses.** The whole package suite:
**1792 tests, 24 skipped, 1 failure** (`r5_full_suite.txt`).

★ **That one failure is not mine, and I proved it rather than argued it.**
`LatticePageRound2Tests.testCoreCLIParsesTheEmittedRegions` fails with
`topopt-cli: job.json: unknown key "plsm" in the job`. I reverted this branch's entire
diff (`git apply -R` against the merge base), ran that single test, and it failed
identically; then re-applied. The cause is a **stale local CLI**: this worktree's
`core/build/topopt-cli` was built **7 Aug**, `core/` last moved **14 Aug** (PR 336), and
main's job emitter now writes a `plsm` key the older binary rejects. The test *skips* when
that binary is absent, which is why CI is green. This branch mentions `plsm` **zero
times** and touches no job emission.

Enumerated and confirmed:

| Thing | Status |
|---|---|
| Wireframe | untouched; `testTheWireframeAndItsXrayReachAllThreeStages` asserts the control still reaches all three |
| X-ray | untouched, same test |
| Undo / redo | ungated by construction; R3 test; demonstrated on his part (`06`, `07`) |
| Pattern tool | untouched — its own rotation still uses `snap`, asserted by `testThePatternRotationStillReleasesOnFifteens` |
| The cut | unchanged except the rotate angle it is given; `testAFreeAngleReachesTheCutPlane` |
| Selections list | untouched; no file under it is in the diff |
| Tool tray | five tools, same order, same icons and hints — `testTheToolTrayIsUnchanged` |
| Default tool | still `select`, still the only non-editing one — `testTheDefaultToolIsStillSelect` |
| ¼-turn button | still lands on a detent — `testTheQuarterTurnButtonStillLandsOnADetent` |
| Single-tap latency off the Select tool | unchanged: the double-tap recognizer is disabled, so `require(toFail:)` is satisfied instantly |

**R6 — files touched.** `r6_diffstat.txt`, two-point against the merge base `500833ed`:

```
 MetalMeshView.swift        | 208 ++++-    the viewport's gesture recognizers
 ProjectModel.swift         |   2 +-      ONE line: the rotate angle's consumer
 SurfaceCut.swift           |  38 +++-    the detent math
 SurfaceTool.swift          |  43 +++     the tap-meaning table
 WorkspacePlaceholder.swift | 159 +++-    the Surface stage's handlers + its tray
 5 files changed, 434 insertions(+), 16 deletions(-)
 + SurfaceInputDiscipline.swift, SurfaceStageGesturesTests.swift,
   SurfaceDoubleTapMatchEvidence.swift
```

No lattice stage, no density path, no `core/`, no bottom-right control stack, no
`materials.json`. The one file that could be argued is `ProjectModel.swift`: its
`commitSurfaceCut(faces:rotationDegrees:)` quantised the rotation the Surface stage's knob
produced, so leaving it would have meant a free angle that survives the release and dies
at the commit.

**R7 — no wall of text.** The longest shipped string added is 56 characters, **11 words**:
*"Pencil only — no pencil seen yet, so fingers still edit."* (`r7_longest_string.txt`.) The
stage still carries exactly one line of text at a time; nothing added a sheet, a modal or
a toast.

**R8 — assertion census.** `r8_assertion_census.txt`, read whole rather than through a
filter, diffed against the **merge base** and not a moving head. This branch deletes 16
lines. None is an `XCTAssert`, an `assert`, a `precondition` or an assertion message. No
test function is removed. The one `guard` among them,
`guard let face = surfaceSelectedFaceID else { return }`, becomes
`guard let face = aimedAt ?? surfaceSelectedFaceID else { return }` — it admits strictly
more and still refuses when there is nothing to aim at. **92 `XCTAssert` lines added
across 25 new tests.**

**R9 — no unfilled placeholders, no scratch at the repository root.** New files are the
three above plus the evidence directory.

---

## Method

1. Screenshot the topology screen first and write the look rules off it
   (`00_look_rules_read_off_the_screenshot.md`), before adding the one new control.
2. Read what already existed. The similar heuristic, the `SurfaceSimilar` multi-select, the
   `BrushGesture` pencil precedent and `SurfaceCut.snap` were all already there — most of
   this task was pointing existing machinery at a new gesture rather than building
   anything.
3. Pure value types first, so the rules are testable without a viewport:
   `SurfaceTool.meaning` (§1), `SurfaceInputDiscipline` (§2), `SurfaceCut.settle` (§3).
4. Then the recognizers, one per contact kind, gated so nothing costs latency where it
   means nothing.
5. Measure on his own STEP file rather than on a synthetic mesh, and reproduce PR 331's
   own numbers in the same run so neither is taken on trust.

**A build note for the next worktree.** This worktree could not link the iOS app until
three per-machine artifacts were provisioned: `app/scripts/build_core.sh` (the vendored
`TopOptCore.xcframework` was stale against the bridge header — `analyze_fixed_design`
undefined), symlinks to the main checkout's prebuilt `vendor/occt-ios` and
`vendor/lib3mf-ios`, and a copy of the git-ignored `TopOptKit/occt-frameworks.generated.json`
that the manifest gates on. SwiftPM then still served a **cached** manifest evaluation —
`swift package dump-package` reported 1 binary target where `--manifest-cache none`
reported 49 — so `swift package purge-cache` was needed as well. All four are
build-environment provisioning; none is a repository change.

---

## In plain language

Four things changed on the Surface stage, and none of them changed how it looks or how it
already worked.

**Tap a face and you get that face. Tap it twice and you get every face like it.** The
"like it" part is not a new guess — it is the same rule that was measured on his own
bracket months ago, the one that knows a 3 mm hole from a 12 mm one. The stage tells him
how many faces it caught, and he can add or remove kinds by tapping before anything
happens. Double tap only means this while the Select tool is armed; with the scissors or
the grid out, two taps are just two taps, as before.

**There is a new pencil button.** Off, everything works as it does today. On, the pencil
does the editing and fingers move the view — which is what he asked for back in July. If
no pencil has ever touched the screen, the button does not lock him out; it says so, and
fingers keep working until a pencil actually shows up. Undo and redo are finger gestures
and they keep working either way, because undoing is not editing.

**The cut's rotate knob now really has detents.** It used to *look* like it had them and
actually behave like a 15° stepper — you could not ask for 37°. Now it lands on the 15s if
you let go near one, keeps whatever angle you chose if you don't, and ticks as each 15 goes
past. Demonstrated on his part at 36°.

**And three tests now pin what each of the three stages may show.** Topology shows its
primitives and the design box. Lattice shows its depth planes and neither of those. Surface
shows nothing but the part and its faces. All three were already right; the tests are so a
later change cannot quietly break one.
