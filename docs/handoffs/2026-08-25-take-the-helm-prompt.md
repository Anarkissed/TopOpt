# Prompt: take the helm of the TopOpt lattice-preview work

You are taking over an in-flight repair of the **lattice preview stage** of TopOpt,
an iPad topology-optimization / 3D-printing app. The maintainer (Nadim — he is the
source of truth; when he says it's wrong, the code is wrong) has lost confidence in
the previous agent after a night where every claimed fix appeared to do nothing.
The root cause of that appearance is item 0 below — read it before anything else,
because it changes how you must verify everything you do.

Working directory: `/Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/plsm-production-settings-ship-7e17ab`
Branch: `claude/topopt-lattice-preview-1b7355`. App package: `app/TopOptKit`
(SwiftPM; `swift build` / `swift test` from that directory). App project:
`app/TopOpt.xcodeproj`, scheme `TopOpt`.

---

## 0. THE STALE-BINARY INCIDENT — your verification protocol

On 2026-08-24 the previous agent committed a full round of fixes, built the app,
installed it, and told the maintainer it was ready. **The installed bundle was a
Debug product from 21:41, built before any of the fixes.** The scheme's
`xcodebuild build` writes to `Build/Products/Release-iphonesimulator/`; a stale
`Debug-iphonesimulator/` product from an earlier session sat beside it in the same
derived-data directory, and the agent installed that one. The maintainer spent an
hour at 2 AM re-reporting five bugs that were all just the old binary.

**Protocol — never skip this:**
1. Build: `xcodebuild -project TopOpt.xcodeproj -scheme TopOpt -destination
   'platform=iOS Simulator,id=A030C20C-D243-4CC4-A602-E2A90FB6CCDF'
   -derivedDataPath <DD> build` (from `app/`). Check which config directory the
   log actually wrote.
2. Install that exact product:
   `xcrun simctl install A030C20C-D243-4CC4-A602-E2A90FB6CCDF <path>/TopOpt.app`.
3. **Prove it**: `xcrun simctl get_app_container <udid> com.nadim.topopt app`,
   then `stat` the binary's mtime (must be your build's time) and
   `strings <binary> | grep <marker>` for a string literal your change added.
   Only then say it is installed.
4. `simctl install` does **not** restart a running app. Tell him to relaunch.
   Never `simctl launch` or `open -a Simulator` — several TopOpt bundles exist
   and launch fronts the wrong one (his standing complaint).

As of this handoff the **correct** binary (Release, 2026-08-24 23:30, contains
every commit through `977fee72`) **is installed** and verified by marker string.
He has not yet looked at it. So: every complaint in his 02:03–02:08 screenshots
was filed against the OLD code. Your first task is re-verification, not rework.

## 1. Environment and standing rules (his rulings — binding)

- **Simulator**: iPad Pro 13-inch (M5), UDID `A030C20C-D243-4CC4-A602-E2A90FB6CCDF`.
  Two TopOpt apps are installed; the right one is the **last icon on the second
  page** (`com.nadim.topopt`). If you see a full page of projects or the model
  doesn't load, you're in the wrong app.
- **Save to copies only.** Never save over his projects. His test copy is the one
  with "M2 verticalStand" content; work on the copies made earlier.
- **Judge previews in the simulator**, never from your own offline renders — a
  whole night was once lost to a bodyAlpha=0 difference between the two.
- **He drives the sim** when he's at the desk; drive it yourself only when he's
  away and has asked for autonomous verification.
- To arm the strut preview in-app: open project → See Original → "Lattice" stage
  chip → the BOX viewport icon opens the settings page → **Save & Exit** arms the
  preview + bake. No DIAG lines appear at all before that arming.
- Log reading: `log show` self-matches its own invocation arguments — grep for
  `"(Foundation) DIAG"` or filter to the app process, or you will "find" your own
  query. Same for `pgrep`-based waiting (bracket trick: `TopOptKitPackageTest[s]`).
- **Worktree build traps** (all previously hit): the app link needs `vendor/`,
  `CoreFingerprint.generated.swift`, `occt-frameworks.generated.json`, and the
  xcframework — copy from a sibling worktree or run `app/scripts/build_core.sh`.
  After any rebase onto a core change, run build_core.sh again.
- **Test-run honesty**: never pipe a suite through `tail` (it eats the exit code);
  redirect to a file and echo `EXIT=$?`. Don't rebuild while a suite runs. The
  full package suite is ~2200 tests, ~22 min, and was green at handoff.

**Product rulings** (do not re-litigate):
- **Never overshoot**: a cell must never exceed the measured wall it sits in —
  a 12 mm wall gets a 12 mm cell, never 13. Width is read **per voxel** at the
  cell centre; an unmeasured centre is unconstrained (footprint-min poisons
  curved walls).
- The density **floor** keys on the printable bead (strut line width, 0.45 mm);
  the density **max is the quilt** — "saying the max is solid, is wrong". The
  user-facing % is **relative** between those two.
- Aesthetic stress display = dramatic/relative; Structural = absolute (absolute
  half not wired yet).
- **Organic is OFF-LIMITS** until he says otherwise.
- Corner rule: a 15 mm-deep prism on a 10 mm wall lattices at 10 mm, but a
  corner that truly measures 15 mm gets 15 mm.
- A finish is a look, not a repair; printability is user input, never a default.

## 2. What is in the code but he has NEVER seen (verify each in the sim first)

All committed on this branch; the installed Release build contains them.

1. **Stepped/algorithm persistence** — `cellTransition` is computed over
   `algorithm` (`LatticeSettings.swift`); loading no longer silently rewrites
   stepped→doubled on save.
2. **Never-overshoot + per-voxel width** — `latticeRegionCellsMM` in
   `WorkspacePlaceholder.swift` (effDepth = min(declared, measured), whole-number
   fit); per-cell local divisor in `LatticePreviewOccupancy.steppedCellField`
   (`nW = ceil(s·floor/wLocal − 1e-6)`, centre-only width read). Verified in-sim
   earlier (stated cells 10.31/12.03 on his two walls).
3. **Doubled**: ladder base from the p05 of wants (not min); decided-solid cells
   render solid via `rimParams.z` gate in `UnifiedShading.swift` (~line 833) —
   verified in-sim (solid margins, chamfer meets material) **on doubled only**.
4. **Stress overlay** paints the measured `stressDemand`, not the
   utilisation-capped grading demand (`LatticeSDFMetal.swift`).
5. **Printability lift** — graded cells' demand raised so every strut ≥ 1 bead
   (`LatticeLiftProbe` proves all sizes lift to ρ*).
6. **Attached-only solid rim bake** — outline distance seeded only where the
   wall meets material (`attachedSeed` from `memberThicknessMM`, NOT partSDF —
   its sign is region-clipped); unreached voxels get the `kFarMM = 1e6` sentinel
   (0 would mean "on the outline" and paint everything solid).
7. **Aesthetic per-face Density control** — band = [printability floor, quilt
   ceiling] (`quiltDensityCeiling(cellMM:)` in `LatticeType.swift`, bisected from
   the strut law at strut = cell/2), relative % display, write clamps into band
   (`ProjectModel.writeLatticeDensity`), density row first when single-cell.
8. **The 2026-08-24 late round** (commits `ac0dcefe`–`977fee72`, none seen):
   - Stepped **sample re-made from scratch**: `LatticeSamplePatch.centreAndShell`
     — one block two members across; centre = the floor's worth of derived cells
     (single-cell ⇒ ONE cell "filling half the cube", floor 2 ⇒ 2×2×2), wrapped
     by a one-grade-finer shell ("the grade around" — his verbatim spec). The
     toggle changes structure at constant envelope. Wizard passes
     `steppedCoarsePerHalf` 1/2 from `LatticeSetupWizard.rebuild()`.
   - **"Auto · N%"** density display for faces with no stored override; typing
     **0 clears to Auto** (`latticeSelectableDrawer` in WorkspacePlaceholder).
   - **Aesthetic diagnosis floor**: `latticeDiagnosis(_:)` (WorkspacePlaceholder
     ~8939) uses the stage floor, not core's accuracy floor of 5.
   - **Retention switch gated structural-only** (`LatticeSetupWizard.swift`
     ~268: `if model.stage == .lattice, stageMode == .structural`).
   - **Region-cell memo** (`LatticeRegionCellMemo`): the per-region 128³ wall
     walk ran on every SwiftUI body evaluation; now once per scene token +
     input fingerprint. This was the "2-cell lattice flashes while waiting" cost.
   - **All modifiable row labels white + bold** (his final ruling after one
     round-trip both ways); the Density value additionally larger/heavier.

## 3. His current complaint list (2026-08-25, 02:03–02:08) — how to work it

Every item was filed against the stale binary. Re-verify on the new build first;
below is what should now happen and what to do if it doesn't.

1. **"Won't certify — tap for the fix" must not show in aesthetic.** The badge
   (group row and face rows) flows through `latticeDiagnosis(_:)` →
   `LatticeFaceDiagnosis.of(card:cellsPerMemberFloor:nozzleWidthMM:)`. The floor
   trigger is fixed, but `.of` has OTHER triggers (nozzle/strut checks — read
   `LatticeFaceDiagnosis.swift:175` area). His instruction is categorical:
   **in aesthetic mode the badge must never render**. Cleanest compliant change:
   in `latticeDiagnosisBadge(_:)` (WorkspacePlaceholder ~8870, call site ~8861)
   return empty when `(project.lattice.stageMode ?? .structural) == .aesthetic`.
2. **"Too thin to certify" switch must not appear in aesthetic** (settings page,
   img 2). The gate exists (§2.8). **Verify the condition**: it checks
   `model.stage == .lattice` — confirm that is the stage value on the settings
   page where the switch renders; if the page shows it under a different stage
   case, the gate is dead code and the switch still shows. Fix the condition to
   whatever the page's actual stage is, and verify in the sim.
3. **The sample** (img 2, "looks worse than before"): what he saw was the OLD
   halves-based sample. The new `centreAndShell` is unseen. Have him (or drive)
   the settings page on the new build and judge. If he still rejects it, iterate
   with him at the desk against his spec sentence — do not invent a third
   interpretation silently. Note the sample draws with `boundary: .none` and the
   block pinned to the min declared include depth.
4. **Quilt at "default" density in single-cell stepped** (img 3): two causes.
   (a) A **stale stored 20%** density on that face from the old clamp bug —
   stored beats derived. On the new build the drawer shows a plain % (no
   "Auto ·" prefix) on that face, which is the tell; entering 0 clears it.
   Consider adding a read-time guard so this never needs manual clearing:
   when reading a stored aesthetic density, clamp/ignore values outside the
   current band (`latticeAestheticDensityBand`) — decide with him.
   (b) The structural quilt mechanisms in §4A below.
5. **The 2-cell-floor flash while single-cell computes** (img 4 → img 5): the
   memo + the `hidden`-while-baking gate (`LatticeLayerInputs.hidden`,
   `strutBakeInFlight`) should remove it. If a flash remains, instrument WHICH
   frame draws the 2-cell picture: it is either a body evaluation still using
   the old derived cells (memo key missing an input) or a bake applied before
   params (ordering in `MetalMeshView.update` — params must be applied before
   `setLatticeScene`; this was fixed once already, regression-check it).
6. **Labels** (img 4/5 note): on the old binary the *values* were white. The new
   build styles every modifiable row's **label** white + bold too
   (WorkspacePlaceholder ~9027). Verify visually; "Density", "Depth", "Expand"
   labels must all read white/bold; fact rows stay quiet.

## 4. The two hard problems he named — full context and marching orders

### A. The quilt — why it keeps coming back

"The quilt" = the preview (and the printed part) reading as a dense fabric of
fused X-shaped bosses instead of an open truss. There are FOUR distinct
mechanisms, and every past regression was one of them wearing the other's face:

1. **Caps slicing cells mid-cell.** The struts are trimmed flush at the region's
   two cap planes. A cap on a cell boundary leaves open cells (the truss); a cap
   mid-cell slices every strut at its fattest — cross-sections that nearly touch.
   Fixed per region by the whole-number-of-cells fit (cell = effDepth/n), with
   the tiling phase anchored to the face. Measured proof lives in the comments at
   `latticeRegionCellsMM`.
2. **Density high enough that struts fuse.** At strut diameter ≥ cell/2 adjacent
   struts merge — that IS the quilt as a material state. This is why the density
   band's ceiling is `quiltDensityCeiling`, and why his ruling says the max is
   the quilt, not "solid". The slider can no longer select past it; old STORED
   values can still sit past it (§3.4a).
3. **Stale stored density** (§3.4a) — an override nobody remembers dialling.
4. **NEW, unresolved — the per-voxel divisor vs the caps.** The per-cell local
   width divide (`nW`) shrinks a cell where its own wall is thinner. A shrunk
   cell has a different size than its region's cell, so the region's cap-flush
   phase no longer lands its caps on ITS boundaries — locally re-creating
   mechanism 1 in exactly the shrunk bands. Suspect this is part of "holes /
   quilt patches" in his stepped screenshots. **Direction**: constrain the local
   shrink to sizes that keep caps flush — e.g. only shrink by integer factors of
   the region cell along the depth axis (s/k), or re-anchor the shrunk cell's
   phase to the nearest cap plane. Measure first: log how many cells shrink and
   where they sit relative to the caps (the `DIAG steppedGrade` line already
   prints `shrunk=`).

### B. Grade-to-shape never grades to solid at the edge the face-prism removed

What he wants: where the declared face's prism was carved out of the part, the
lattice should **grade down and then meet solid material** at the boundary — a
solid rim tying the lattice to the surrounding walls and the chamfer, so nothing
floats. What he sees on stepped: lattice ending in air, chamfer "held up in thin
air", no solid band.

The machinery that exists:
- **In-plane outline distance** per region, baked into the cell texture's `g`
  channel on the stepped path (`steppedCellField`, `boundaryDistancePerRegion` /
  `rimDistancePerRegion` from `LatticeBoundaryDistance.inPlanePerRegion`).
- The march unions a solid term: `F = min(F, max(dClip, dOutline − band))` with
  `band = rimParams.y = solidOutlineBandMM` (≈ max(finest printable cell, one
  occupancy voxel) ≈ 1.3–1.7 mm) — `UnifiedShading.swift` ~816.
- The rim is **attached-only**: distances are seeded only from outline voxels
  that touch part material outside the latticed set (`attachedSeed` in
  `LatticeSDFMetal.swift`), so an edge open to the world grows no rim.
  Unreached voxels carry `kFarMM`.
- On **doubled**, an extra mechanism ships and is verified: cells the ladder
  decided must be solid render as solid (`rimParams.z` gate). **Stepped has no
  equivalent** beyond the thin outline band.

Why it can still fail on his part — investigate in THIS order:
1. **Seeding returns zero seeds on his real geometry** → every distance is the
   far sentinel → the shader's band never fires → no solid anywhere. The bake
   logs `DIAG rim dressing=… outlineBand=…` and `DIAG steppedGrade …
   solidRim=N dCentre[…]`. Reproduce on his stepped copy (arm the preview, read
   the app's log), and check `solidRim` and the dCentre count. If 0 → fix
   seeding (`memberThicknessMM > 0` mask is the whole-part authority; partSDF's
   sign is region-clipped and is NOT usable for this).
2. **The band is drawn but too thin to see** (~1.5 mm at his scale).
   `steppedSolidRimMM` (3 beads ≈ 1.35 mm minimum) exists for exactly this; he
   has been invited to name a chunkier width ("a fraction of the local cell?
   fixed mm?") and has not yet — ask, or propose one visibly (e.g. half the
   local cell) and show him.
3. **The 3 mm exterior gap is not the rim's job at all.** Measured fact
   (LatticeChamferGapProbe): the chamfer is its OWN CAD face, so the declared
   face's outline — and the whole prism — stops where the bevel starts. A ~3 mm
   band of real material sits OUTSIDE the declared region (face 15: +3,834
   voxels, face 2: +4,151; region expansion saturates at +3 mm). Nothing renders
   that band's cross-section, so the lattice visually ends before the chamfer
   even when the in-region rim is perfect. Remedies (HIS call — present, don't
   pick): (a) auto-absorb adjacent narrow chamfer faces into the region;
   (b) default the existing per-face Expand to the measured gap; (c) render the
   interior band. He has already been shown (a) vs (b) once without ruling.
4. **Holes inside the stepped lattice** (distinct from the edge): undiagnosed.
   Hypotheses: §4A.4 (shrunk-cell cap misalignment), or big cells whose clipped
   window contains no strut segment. Diagnose with the tap callout (it reads the
   renderer's own baked activation — trust it) and screenshots at known
   coordinates before changing anything.

### C. The 2D look, and the depth the prism took but the lattice does not fill

Two more of his standing reports, related to each other and to §4B:

1. **The lattice reads as 2D** — a flat wallpaper pasted on the wall instead of
   a truss with visible depth (his img 14 of the night round, and again in the
   02:05 screenshot's front view). Candidate causes, in order of likelihood:
   (a) it literally IS shallow — see point 2; (b) a single cell across the
   depth (n = 1 after the whole-number fit) puts both cap planes on the same
   cell's boundaries, so front and back show the same cross-section and nothing
   interior is ever visible at grazing angles; (c) shading — the raymarched
   struts' normals/AO may be flattening the read; compare against the doubled
   path, which he accepts as 3D. Diagnose by orbiting the same wall in the sim
   and by reading the tap callout's cell/cells-across before touching code.
2. **The lattice does not reach the entire depth the face-prism removed.** The
   carve takes the DECLARED depth (13 mm on face 2), but the drawn lattice sits
   visibly shallower — a void slab behind the struts, which also feeds the
   floating/2D read and the "chamfer held up in thin air" picture. Places the
   depths can diverge — check each: (a) the never-overshoot clamp
   (`effDepth = min(declared, measured wall)`) must size the CELL only; if any
   path lets it shrink the clip/tiling extent, the strut field ends at the
   measured wall while the carve honours the declaration; (b) the occupancy
   mask the bake tiles into may be thinner than the declaration on curved or
   chamfered walls (the along-normal walk stops at the first exit); (c) the
   shell-cut and the march use different prisms (`lsdf_part_clip` + decls vs
   the bake's region field). Measure, don't guess: on face 2, compare the
   carved void's depth against the strutted depth at three probe points, and
   log which of the three volumes (declaration, occupancy, clip) each number
   matches. The fix must make the STRUTS fill the carve — never the carve
   shrink to the struts (his never-overshoot ruling governs cell size, not
   coverage; the declared volume must end up either strutted or solid, no air).

## 5. Bigger queued items (in his priority language)

- **Preview ↔ run parity** — the ultimate question, answered: the job document
  carries only topology/bead/cell-mode/retention/algorithm; ALL the new
  derivation (never-overshoot, per-voxel width, shape-fit band, solid rim) is
  preview-only. Recommended package: write per-region derived cells/floors into
  the job document so the run builds what the preview shows. He was seen typing
  "Go with the job-side approach" but never sent it — **confirm before building**.
- **Watertight lattice STL** — his preference; core-side boolean; queued.
- **Structural absolute stress display** — ruled, not wired.
- **Stepped rim width** — his to name (§4B.2).
- **Organic** — off-limits until he says.

## 6. Tests and probes you inherit

`swift test` from `app/TopOptKit` (full suite ~22 min, green at 2199 at handoff;
30 known GPU-flake skips). Focused suites that guard this work:
`LatticePerVoxelWidthTests`, `LatticeSampleSingleCellTests` (envelope-across-
the-toggle), `LatticeAestheticDensityControlTests` (band clamp; needs the 2.0 mm
cell fixture — at 6 mm cells the floor ≈ 0 and the test is vacuous),
`LatticeAlgorithmPersistenceTests`, `LatticeGradingDistanceTests`,
`LatticeAttachedRimTests`, `LatticeStressOverlayTests`. Probes (run as tests):
`LatticeLiftProbe`, `LatticeDoubledWantsProbe`, `LatticeChamferGapProbe`,
`LatticeWallWidthProbe`.

Session history: `docs/handoffs/2026-08-24-overnight-run.md` (the full overnight
log, including the eight desk-review fixes and the open decisions list).

## 7. How to work with him

Report outcomes plainly; if something is unverified, say unverified. He reads
receipts, not reassurance. When he reports a defect, the code is wrong — find it;
never close with "that's the setting". Ask his open questions once, crisply, and
otherwise make the judgement call and leave him a list. And verify the binary.
