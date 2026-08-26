# The holes and the quilt — everything tried, measured, fixed, and still open

Written 2026-08-26 ~02:15 by the outgoing agent, for a fresh agent with no context.
Every number here was measured, not estimated. Where I was wrong, it says so.

---

## 0. THE TWO SYMPTOMS, IN HIS WORDS

1. **HOLES** — "there's a massive hole", "still massive holes", dark voids inside a
   latticed wall. Confirmed genuinely empty: when he taps inside one, the callout
   reports a strut at the hole's **EDGE**, i.e. the ray passes through the void and
   lands on something at the rim. There is nothing drawn in the hole.
2. **QUILT** — a dense fabric of small shapes instead of an open truss. He has seen
   it under Stepped AND Default, single-cell on AND off: "It's in *every* setting!"

**Where to look:** open his part and **zoom on the BOTTOM OF THE FRONT of the
model**. That is where he photographed both, most recently at 02:04 on 2026-08-26.

**★ STRONGEST LEAD, FOUND LAST (see the evidence README):** in
`evidence/2026-08-26-holes-and-quilt/02_quilting_pink_his_camera.png` the pink
patches are **flat, angular, solid blobs with no struts inside them** — the march
drawing SOLID, not a fine lattice. `F = anyActive ? max(dn*cellHere, dClip) : dClip`
draws solid whenever a cell finds no active neighbour, and `anyActive` skips every
neighbour of a DIFFERENT CELL SIZE (the `sameLattice` gate). A cell surrounded by
differently-sized cells is therefore rendered solid. The shape grade creates size
changes all over a face. **Test this first** — the README has two cheap decisive
tests. It is immune to density, appears under both algorithms, and survives every
bake-side check, which matches every symptom.

**SEE IT FIRST:** `evidence/2026-08-26-holes-and-quilt/01_holes_and_quilt_front_bottom.png`
is a capture of exactly that area with both defects visible, plus a README pointing
out which marks are the quilt and which are the holes. Look at it before you touch
code. Capture your own with
`xcrun simctl io <udid> screenshot <path>.png` (the MCP screenshot action does not
write a file) — same camera, before and after every candidate fix.

---

## 1. REPRODUCTION

* Simulator: **iPad Pro 13-inch (M5), UDID `A030C20C-D243-4CC4-A602-E2A90FB6CCDF`**.
  Two TopOpt apps are installed; the right bundle id is **`com.nadim.topopt`**.
  Never `simctl launch` blindly — launch by explicit `app_path` + bundle id.
* Project: **"M2 verticalStand" with the green `Optimized` badge**
  (`68BF7B74-3C2A-4ED6-A46D-AC040A9CA649`). NOT the "Ready" copy of the same name.
* Its settings: algorithm `stepped`, `stageMode: aesthetic`, `singleCellMembers: true`,
  boundary `fullSkin`, `shapeFitBandMM: 10`, `densityMode: sim`, Fast·64³, Protect 8 mm,
  two include faces — **face 15 @ 12 mm** and **face 2 @ 13 mm**.
* Path to the preview: open project → **See Original** → **Lattice** stage chip →
  the **box viewport icon** (opens the settings page) → **Save & Exit** (this is what
  ARMS the preview and forces a bake). No DIAG lines appear before that.
* Headless fixture for the same part: `LatticePreviewConfettiTests.hisMesh()`
  (`Tests/TopOptFlowsTests/Fixtures/M2_verticalStand.step`).

**Verify the binary every single time.** A stale-binary incident cost a previous
session a whole night. After `xcodebuild` + `simctl install`, hash the installed
bundle against the build product AND hash the running process's binary
(`ps -p <pid> -o comm`). Three-way match or it did not ship.

---

## 1b. IN-APP DIAGNOSTICS — USE THESE, THEY ARE THE FASTEST TOOLS YOU HAVE

**★ TAP THE LEGEND TO HIDE THE PART AND SEE THE NAKED LATTICE.** The maintainer
taught me this and it is the single most useful move on this page. The legend panel
("TAP TO EXPLORE") sits on the **right-hand side** of the viewport and lists
**Rim & skin** and **Interior fill**. Tapping a row drills into "explore" mode for
that colour, which **makes the prism/body invisible** so you see the strut geometry
alone, with nothing drawn over it. **Double-tap anywhere to go back.**

Why it matters here: with the body hidden the lattice looked CONTINUOUS, which is
what first proved the bake was not dropping geometry and pushed the search toward
the shell and the march. Any claim of the form "the lattice is missing there" must
be checked in this mode before you believe it — otherwise you cannot tell missing
struts from struts hidden behind a surface.

Isolating **Rim & skin** vs **Interior fill** separately is also how you tell the
SKIN's diagrid apart from the interior truss — which matters enormously for the
quilt, since the fine triangular fabric blanketing his wall is the skin, not the
lattice (§6 step 3).

*Practical note:* when driving the simulator, aim carefully — the legend is a narrow
panel on the right. I wasted several attempts tapping ~90 pt to its left and hitting
the viewport instead, which orbits the camera rather than opening explore mode.

**★ THE TAP CALLOUT.** Tapping a strut reports the density, strut diameter and cell
size AT THAT STRUT, read back from the renderer's own baked field — trust it. This
is what produced the decisive numbers: a 12.03 mm region cell reading **2.01 mm with
a 0.45 mm strut** (the shape-band quilt), and the fact that tapping inside a hole
only ever returns a strut at its **EDGE** (proving the void is genuinely empty).

**★ THE RESOLUTION CHIP** (Fast·64³ / Fine·128³) — flipping it and re-baking is a
ten-second test that discriminates sampling artefacts from real geometry. It already
ruled out the whole clip-resolution family of theories.

---

## 2. WHAT IS FIXED (measured, committed)

| Commit | What | Evidence |
|---|---|---|
| `db8a28d9` | Shrunk cells kept the REGION's tiling fraction; caps sliced mid-cell | face 15: 107/304 cells 0.51–0.68 mm off a boundary → 0.013 mm |
| `f74675ee` | Lattice params written to a not-yet-created layer were dropped → first bake used defaults → **dyadic ladder drawn instead of stepped** (the "quilt while calculating") | 2 `stepped NOT RUN` bakes per change → 0; bakes per change 4 → 2 |
| `14e5eca3` | Per-spot cells took ANY local size → neighbours couldn't share nodes → struts cut to pieces | 13 sizes, **180/1144 (15.7%)** neighbour boundaries unmeshable → 6 sizes, 0.5% |
| `00af9728` | **The shape band ramped to the FINEST PRINTABLE cell.** With a 10 mm reach most of a face is inside the band, so most of the face went to S/6 with one-bead struts | his tap: 12.03 mm region cell reading **2.01 mm, 0.45 mm strut**. Ramp now capped at S/3 (`shapeBandMaxDivisor`) |
| `8ed20b7d` | Density dial mapped through rho, where the strut law **saturates**: 62/75/90/100% all produce an identical strut | 33%→3.37 mm, 62%→4.99 mm, 90%→4.99 mm. Now linear in strut WIDTH; Auto at 45% of the band |
| `a25eb6c5` | Full scene bake per drag frame / per keystroke | now one bake on release or keypad OK |
| `98ad5303` | Settings page restructured to his order; preview hidden while the FEA runs; density locked under Sim | — |
| `7885e3cd` | **`shell_is_latticed` opened BOTH caps** of a declared wall (near and far), so a wall was open on both faces | fixed: only the cap facing the eye opens; the other backs it |
| `bf6c0205` | Fusion width now measured per topology rather than assumed cell/2 | octet 0.5000, diamond 0.4330 |
| `106b21da` | The offscreen render probe harness | see §5 |

---

## 3. THE SINGLE MOST IMPORTANT MEASUREMENT

**An octet lattice can never close.** Measured through core's own strut law at
`rho = 1.0` (the densest the law allows):

```
cell  5.00 mm -> strut 1.92 mm = 38.4% of the cell across
cell  6.00 mm -> strut 2.30 mm = 38.4%
cell  8.00 mm -> strut 3.07 mm = 38.4%
cell 10.31 mm -> strut 3.95 mm = 38.4%
cell 13.00 mm -> strut 4.99 mm = 38.4%
```

A constant **38.4%** at every cell size. Consequences you must hold onto:

* No density setting can make a wall opaque. If a wall is open on both surfaces you
  WILL see through it, at any setting. (That was `7885e3cd`.)
* Coverage plateaus: whole-part lattice, rho 0.05→0.90, dark inside the part goes
  7.4% → 5.4% → 4.8% → **4.8%** (0.60 and 0.90 byte-identical).
* Therefore "make it denser" is never a fix for a hole. Do not go down that road;
  I did, and the user correctly rejected it.

---

## 4. THEORIES THAT WERE **WRONG** (do not re-run these)

1. **Cells being deleted by the member/inside-fraction floors.** Refuted:
   **528 of 528** in-region base cells painted, at maxDim 64 AND 128, with floor 1,
   floor 2, and floors disabled. Zero deletions in every combination.
2. **Clip-resolution shredding at Fast·64³.** Refuted by the user: switching to
   Fine·128³ and re-baking produced a **pixel-identical** picture.
3. **Incommensurate neighbouring cells.** REAL (and fixed, `14e5eca3`) but NOT the
   holes — holes persisted after it.
4. **Struts fusing (the quilt ceiling).** Refuted: octet never fuses (see §3).
   `quiltDensityCeiling` returned 1.0 at 5/8/13 mm cells.
5. **Struts too thin to see.** Refuted by arithmetic: 0.95 mm strut on a ~200 mm
   part at his zoom ≈ 5 screen pixels. Visible.
6. **The march's step budget.** Refuted: 512 / 1024 / 2048 / 8192 steps and
   `minStep 0` all gave **byte-identical** hole pixel counts.
7. **Declared face with no material behind it.** Refuted: only **1–2%** of declared
   columns are empty through the full depth.
8. **Prefetch window (3×3×3).** NOT tested properly — the segment buffer encodes the
   owning-neighbour index (`a.w` → 0…26), so widening the shader loop alone is
   invalid. If you want to test it you must regenerate the segment list too.

---

## 5. THE HARNESSES — AND WHY BOTH ARE INADEQUATE

### `LatticeHoleRenderProbe` (committed, WORKS but measures the wrong thing)
Drives `LatticeSDFRenderer` alone and floods dark from the image border, so what
survives is enclosed by lattice. Found a real signal: **one enclosed hole, 5044 px,
14.7% of the drawn lattice, only from BACK views (az 3.14, 3.93)**, immune to shape
band / algorithm / cell size / density / bead / dressing / step budget.

**Its fatal limitation: it never draws the part.** Only the lattice layer. So every
non-strut pixel is background by construction and it cannot see a hole *through a
wall*. This is why I twice declared "verified" on pictures the user then opened and
found broken. **A harness that cannot fail the way the product fails is not a
harness.**

### `LatticeWholeFrameProbe` (committed, BROKEN — fix this first)
My attempt to render shell + lattice in one frame via `MeshRenderer.setLatticeScene`.
It reports zeros, but the zeros are meaningless: **hiding the lattice entirely changes
lit pixels by 0.3%** (252056 → 251334), proving the lattice never draws in it.
Likely causes to chase: the lattice layer needs its pipelines built and `isReady`
true; `latticeHidden` must be false; the shell clip is only armed when
`latticeInFrame && latticeLayer != nil`; params must be applied BEFORE `setScene`
or the first bake uses defaults.

---

## 6. START HERE — THE NEXT STEPS, IN ORDER

1. **Build the harness that draws what he sees.** One offscreen frame containing the
   shell, the clip and the struts, from `MeshRenderer` with a real lattice layer
   installed, at **the bottom of the FRONT of the model, zoomed in**. Prove it works
   by making it FAIL first: render a build with `7885e3cd` reverted and confirm the
   hole appears as enclosed dark. A harness you haven't seen fail is worthless.
2. With that number in hand, attack the **holes** and the **quilt** separately.
3. **The skin is the prime suspect for the remaining quilt, and it was never fixed.**
   I promised to pin it three times and never did. The fine triangular mesh blanketing
   his wall is the **skin diagrid** (`boundary: .fullSkin`, forced on by
   `singleCellMembers`). Its strut thickness scales with cell and density — the
   dressing multiplies the radius by up to **1.6×** (`float fat = 1.0 + 0.6 * dressing`
   in `UnifiedShading.swift`). Pin it to a fixed printable width (a bead or two) so the
   pattern stays open regardless of cell size. He explicitly asked for "same size AND
   thin": keep the DIAMOND PITCH tied to the cell, decouple the THICKNESS.
4. **Sweep every combination and confirm each is clean**, headlessly where possible
   and in the simulator for the final word:
   * algorithm: Stepped × Default Grade (Organic is OFF-LIMITS unless he says otherwise)
   * single-cell members: on × off
   * grading: Stress+shape × Shape × Stress × No grade
   * finish: None × Rim × Skin × Covered
   * density: Sim × Uniform × Per region, across the band
   * cell size mode: Auto × Fit × Swept × Manual
   * resolution: Fast·64³ × Fine·128³
5. Only claim "fixed" with a zoomed screenshot of the failing area plus a number.

---

## 7. KEY CODE MAP

| File | What lives there |
|---|---|
| `LatticePreviewOccupancy.swift` | `steppedCellField` (the bake), `cellField` (activation), `shapeBandMaxDivisor`, `tilingPhase`, the printability lift |
| `UnifiedShading.swift` | `lsdf_march`, `F = anyActive ? max(dn*cellHere, dClip) : dClip`, the 3×3×3 prefetch + `rnCache/rhoCache`, `min(rn*fat, 0.49)`, `lsdf_part_clip` |
| `MetalMeshView.swift` | `shell_is_latticed` (~line 254) and the `ShellClip` struct/uniform (~3953); `MeshRenderer`, `setLatticeScene`, `renderOffscreen` |
| `LatticeSDFMetal.swift` | `rebakeCellField`, `LSDFUniforms`, `LatticeSDFRenderer.renderOffscreen`, debug knobs (`debugMaxSteps`, `debugShadeMode`) |
| `LatticeType.swift` | `strutRadiusMM` (core's measured law), `quiltDensityCeiling`, `separationFactor` |
| `ProjectModel.swift` | `latticeDensityBandDiametersMM`, `latticeDensityPercent/ForPercent` |

---

## 8. STANDING RULES FROM HIM (binding)

* **Judge in the SIMULATOR, zoomed in on the failing area.** Distant screenshots hide
  exactly this class of defect — that mistake was made twice tonight.
* **He is the source of truth.** If he says it's wrong, the code is wrong. Never close
  with "that's the setting".
* Never overshoot: a cell must never exceed the wall it sits in.
* Printability is user input, never a default. The lift already guarantees ≥ 1 bead —
  do NOT "fix" a hole by raising the density floor; he rejected that explicitly.
* Organic is OFF-LIMITS until he says otherwise.
* Don't pipe suites through `tail` (eats the exit code); redirect and echo EXIT=$?.
* Full package suite: `swift test` from `app/TopOptKit`, ~2200 tests, ~22 min.
