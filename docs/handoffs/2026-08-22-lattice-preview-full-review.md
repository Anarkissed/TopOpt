# Handoff — review the ENTIRE lattice preview against what the algorithm actually builds

You are taking over a preview renderer that has been reported broken by the maintainer
**four rounds in a row**. Three of my four "fixes" were real defects that did not
resolve the symptom. Read the "What I got wrong" section before you plan anything: the
failure mode of this task is confident partial fixes, not lack of effort.

Branch: `claude/lattice-region-primitive-rewrite-f042a9`
Worktree: `.claude/worktrees/variant-postprocessing-reachability-852264`
HEAD: `11e363d9`
Simulator: `A030C20C-D243-4CC4-A602-E2A90FB6CCDF` (iPad Pro 13-inch M5, iOS 26.5)
His part: `app/TopOptKit/Tests/TopOptFlowsTests/Fixtures/M2_verticalStand.step`
His live project: sim container app `28FC2B4B-…`, project `68BF7B74-…` — ABS,
`stageMode: aesthetic`, `cellSizeMode: auto`, `cellMinMM 4`, `cellMaxMM 8`,
`minimizePlastic: true`, `topologyID: octet`, two declared faces (15 @ 11.0 mm,
2 @ 13.5 mm).

---

## THE GOAL, IN HIS WORDS

> "ensure that the preview is showing *exactly* what the algorithm does: correct
> lattices for aesthetic mode that actually work. That do not have floating regions.
> That have large cells and actually step-grade when demanded. And an organic lattice
> that actually works and connects."

And the standing requirement from the original brief, which has never been rescinded:

> "on Aesthetic, the declared walls get latticed. Full stop. All accuracy requirements
> are off."

Core is the authority for every law. **Do NOT re-derive any of them in the app** — the
app's octet strut law already drifted 1.4–1.7x from core's by being re-derived once, and
that class of bug is invisible until someone measures a shipped file. Call
`topoptbridge` / `TopOptKit` forwarders. If a law you need is not exposed, add a
forwarder; do not reimplement.

---

## WHAT IS STILL BROKEN (his screenshots, 2026-08-22 21:08–21:16, on HEAD)

### A. Stepped in the part renders as a regular grid of tiles with void between them
Reported four times. Present at Balanced 96³ AND Fast 64³, with Finish = None,
Rim & skin, and Interior fill, and with "Allow single-cell members" both ON and OFF.

**★ THE MOST VALUABLE CLUE, AND IT IS FROM HIS OWN IMAGES:** the tiles are **the same
size** with single-cell OFF (floor N* = 2 ⇒ 5.50 mm cell on his 11 mm wall) and ON
(N* = 1 ⇒ 11.00 mm, clamped to his `cellMaxMM` 8 ⇒ 8.00 mm). That is a 45% change in
cell size with **no visible change in tile size**. So **the tiles are not cells.** They
are keyed to something else — a texture grid, a block/cache stride, or a clip term.
Any hypothesis that predicts tile size ∝ cell size is already refuted; discard it
before you spend time on it.

Inside each tile the lattice reads as a *fine* diagonal crosshatch — far finer than the
4–8 mm cell. Between tiles: **nothing at all** is drawn — not struts, not the solid
printed-layer fill, not the shell. In the march that means `F > eps` everywhere along
the ray, i.e. `dClip > 0` there, i.e. the clip believes those columns are outside the
part∩region. Start there.

### B. Organic in the part never actually bakes on his part
imgs 3 and 4 still show the banner "shown as the doubled ladder; the run builds the
organic lattice", i.e. `organicForBake` (`WorkspacePlaceholder.swift`) returned nil.
I plumbed `stressTensor:` into the variant `LatticeDemandField` at
`WorkspacePlaceholder.swift:~2839` because `latticeStressField = latticePageVariantField
?? latticeSim.field` means the variant path OUTRANKS the stage's own solve — that was a
real gap, and it did not clear the banner. There is at least one more gate. Find every
`return nil` on that path and print which one fires on his project.

What *is* drawn instead is sparse purple confetti strands over the part — thin,
disconnected, nothing like a lattice.

### C. The organic SAMPLE is strings, not a lattice
"getting better but the struts are supposed to be thicker and it's supposed to have
visible cells in there. It currently looks like a bunch of strings rolled up — there is
also no difference between with a skin and without."

Two defects: strut diameter (must come from `TopOptKit.organicStrutDiameterMM` /
core's `organic_strut_diameter_mm`, NOT re-derived), and the finish having no effect on
the sample at all.

### D. The stepped SAMPLE draws TWO SEPARATE OBJECTS (my regression, this round)
`LatticeSamplePatch.swift` — I made `.stepped` emit two full-size blocks at `cellMM` and
`cellMM * 1.5` via `merged(...)`, to fix "the stepped sample is too small". It now reads
as two objects floating side by side. It should be **one** sample that visibly step-
changes cell size across itself. This one is small and unambiguous; fix it first to get a
clean baseline.

---

## WHAT I FIXED AND PROVED — AND WHICH DID *NOT* RESOLVE THE SYMPTOM

Do not re-find these. Do not assume they were the cause.

**`blk` and `q` had different phase on the stepped path** (`UnifiedShading.swift`,
`lsdf_cell_frame_at`). `lsdf_cell_q` tiles stepped from the origin point by `sMM`
(`floor(cb/m)`); the frame derived the block from the base-cell grid
(`floor(round(cb)/m)`), which is correct for a dyadic block and wrong for a stepped one.
Measured mis-block rate per axis, with a positive control in
`LatticeSteppedPhaseTests.swift`:

```
m = 1.000  was 50.0%  now 0.0%     ← his case (one stated cell ⇒ baseCellMM == sMM)
m = 1.375  was 18.1%  now 0.0%
m = 2.000  was 25.0%  now 0.0%
```

At m = 1 only 0.5³ = 12.5% of the volume prefetched its own 3x3x3 neighbourhood. A real
defect, fixed and tested. **It did not fix the tiles** — his imgs 5 and 6 are on this
build. Treat it as noise removed from the picture, nothing more.

---

## WHAT IS RULED OUT, WITH THE MEASUREMENT

Each of these cost real time. Do not redo them; if you distrust one, re-measure it
deliberately rather than by accident.

1. **The cell activation field is NOT patchy.** Census on his part at Balanced 96,
   aesthetic, minimize plastic: **0 isolated cells** at 4.0 / 5.5 / 8.0 mm; mean face
   neighbours 5.13 / 4.79 / 4.11 of 6; histograms show no bimodality. The field is
   connected. The march is reading it in the wrong place, or the clip is cutting it.
2. **`regionSDF` shares `partSDF`'s grid** (`LatticeSDFMetal.swift:~415-433`, built over
   the same index space), so sampling `regionTex` at the part's `stc` is not a
   scale/offset mismatch.
3. **Stepped cell sizes are uniform within a region** (`steppedCellField`), so a
   per-region seam cannot produce a repeating interior grid.
4. **The occupancy voxel on his part at Balanced 96 is 2.2976 mm.** This is the source of
   the "2.2 mm" he has reported repeatedly. It is not a cell size and never was.
5. **The aesthetic hard floor on his scene measures N\* = 2.0.** With an 11 mm wall that
   caps the cell at 5.50 mm regardless of his 4–8 mm Auto window. `minimize_plastic`
   moves *density* (strut thickness), not cell size. His "the cells should be much
   larger" is therefore partly a real product question, not only a rendering bug —
   surface it to him rather than silently widening a floor core owns.

---

## WHERE I WOULD LOOK, AND THE EXPERIMENT THAT DISCRIMINATES

The gaps draw **nothing**, which in `lsdf_march` means `dClip > 0`. `dClip` is

```
dClip = max(max(lsdf_part_clip(U, sdfTex, regionTex, samp, RC, decls, p, dPart), dBox), dRegion)
```

so exactly one of `lsdf_part_clip`, `dBox`, or `dRegion` is rejecting those columns.

**Run this first — it is one afternoon and it ends the guessing.** Add a debug shade
mode that colours each fragment by *which* term won `dClip` (part / box / region /
none), render his part at Fast 64 with Stepped, and look at the tiling. That single
image names the culprit. Do not skip it in favour of reading more code; four rounds of
reading code produced three wrong answers.

Specific suspects, in the order I would take them:

- **`lsdf_part_clip`** — it insets struts by `clamp(0.25*voxel, 0.20, 0.60)` mm wherever
  the shell survives, and the shell's survival is decided per texel of a **nearest-
  filtered** cell-activation texture (`shellClipMSL`, `gate.y > 1.5`). A nearest-filtered
  per-texel decision multiplied by an inset is exactly the shape of a tiled artefact
  whose period follows a *texture*, not the cell — which is what his images show.
- **`delta` (trim erosion)**, `stepParams.y`, clamped to `[0.10, 0.35]` mm. Bounded now,
  but it is added to `dPart` before every test.
- **The `decls` buffer / `SHELL_DECL_STRIDE = 3`** at fragment buffer 5, and the
  half-space test that must run **per fragment**.
- **`dBox`** — `gridDims.w = 1 << maxLevel` is the ray-box pad in base cells, and
  `steppedCellField` returns `maxLevel: 0` ⇒ pad = 1 × S0. If two regions state
  different cells, the coarser region's `m > 1` and its struts are clipped by a box
  padded for the finer one.

---

## HOW TO WORK ON THIS (earned the hard way)

- **A green run that measures nothing is worse than a red one.** My
  "stepped-uniform ≡ doubled, 0.0% apart" was pixel coverage over a *uniform* field; it
  could not see a per-block cache offset, and it let me tell him twice that I could not
  reproduce his bug. Every comparison bar needs a **positive control** that fails when
  the defect is present.
- **Reproduce on HIS part, not a synthetic bracket.** `LatticePreviewConfettiTests.hisMesh()`
  plus faces 15 (11.0 mm) and 2 (13.5 mm) via `LatticeRegionEmission.planeFor` /
  `.spec` is the harness; several tests already use it.
- **Run the whole `Lattice|UnifiedShading` set, never a narrow `--filter`.** Nine tests
  once sat red behind a filter for days. Current baseline: **781 green**.
- **Uniform structs match their MSL twins by BYTE OFFSET, not by name.** Append new
  fields last, in both places, or you will silently shade with someone else's data.
- **Each `*ShaderSource` is its own Metal library and `try?` hides a dead one.** A
  compile failure is silent.
- **A Metal pipeline writes only its DECLARED attachments**; anything else is undefined
  and then stored.
- Build: `xcodebuild -project app/TopOpt.xcodeproj -scheme TopOpt -configuration Debug
  -destination 'id=A030C20C-…'`. **Install, never launch** (`xcrun simctl install`);
  he drives the app himself.
- If you touch `core/` or `app/TopOptKit/Sources/TopOptBridge/`, re-run
  `app/scripts/build_core.sh` — the xcframework is vendored and a stale one links fine
  and then hangs in a destructor.
- Do not commit evidence artefacts (`evidence/**` churn) with a code change.
- Report what you measured, not what you intended. If you cannot reproduce something he
  reports, say so plainly and say what you tried — do not assert it is fixed.

---

## DEFINITION OF DONE

On **his** project, in the simulator, at Aesthetic with minimize plastic on:

1. Stepped renders one continuous lattice over the full declared prism of both walls —
   no tiles, no void columns, nothing floating.
2. Cell size visibly changes with the "Allow single-cell members" switch, and the legend
   states the cell size actually being drawn.
3. Stepped visibly step-grades where two regions derive different cells.
4. Organic bakes on his part (banner stops saying "shown as the doubled ladder") and
   draws a connected lattice whose strut diameter and spacing come from core.
5. Both samples look like the algorithm they name: the stepped sample is ONE object that
   step-changes; the organic sample has visible cells and struts at core's diameter, and
   the finish changes it.
6. The whole `Lattice|UnifiedShading` suite green, with a positive control on every new
   comparison bar.
