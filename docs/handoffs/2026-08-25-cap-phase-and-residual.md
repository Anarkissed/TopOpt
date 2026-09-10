# 2026-08-25 — the shrunk cell's phase, the far-cap residual, and the badge gate

Session log, incoming agent after the take-the-helm handoff. Everything below is
measured; the probe that measured it is committed
(`LatticeSteppedCapPhaseAndDepthProbe`, runs the SHIPPING bake with every
production input on the M2 verticalStand fixture, faces 15/12.0 and 2/13.0,
stated cells 10.31/12.03).

## 0. Binary verification (the protocol, followed)

The handoff's claim checked out: the installed bundle was hash-identical to the
23:30 Release product, built after 977fee72, docs-only commits since. After this
session's two fixes the app was rebuilt (Release-iphonesimulator), reinstalled,
and re-proven by mtime + sha256 against the build product. He must relaunch.

## 1. Closed this session

### 1a. The aesthetic badge never renders (his categorical instruction)
`latticeDiagnosisBadge` now returns nothing when the stage mode is aesthetic —
the gate is on the BADGE, not on one trigger, so the nozzle/strut checks in
`LatticeFaceDiagnosis.of` can no longer resurrect it. Structural untouched.
(b55be283)

### 1b. The retention-switch gate is LIVE, not dead code (§3.2 verified)
The only render site of `subfloorRetentionSwitch` is inside
`model.stage == .lattice` (the "In the part" wizard view, where it appears) AND
`stageMode == .structural`, on the observed live ProjectModel. Needs only the
visual once-over in the sim.

### 1c. The quilt's fourth mechanism — measured, then closed (db8a28d9)
`faceTilingPhase` measures the cap offset in REGION cells; the shader shifts
each cell by `pfrac × LOCAL cell`. On any cell the shape-fit grade or the
per-voxel width divide shrank to S/n, the caps landed `((n−1)·frac mod 1)`
cells off a boundary — mid-cell slices exactly in the shrunk bands.

Measured on his part, face 15 (region frac 0.1011): 107 of 304 cells at
S/2–S/3, near cap 0.509–0.682 mm off a boundary. Face 2 (frac 0.0000): immune —
which is how the defect hid behind one clean face. Fix: the bake re-measures
the fraction per cell (`frac·n mod 1`, encoder's own snap). Post-fix probe:
0.013 mm at every size on face 15. Pinned by `LatticeSteppedShrunkPhaseTests`
(real encoder + real bake + the shader's own tiling rule, synthetic slab with
frac ≈ 0.3).

### 1d. §3.4a ruled out on the stepped copy
His stepped test copy (68BF7B74, "M2 verticalStand", algo=stepped, aesthetic,
single-cell) stores `selectableDensity = {}` — NO stale per-face density.
Whatever quilt remains on that copy is structural (1c and §2 below), not a
stored override. The read-time band guard remains worth discussing but has no
evidence of being needed on this copy.

## 2. OPEN — the far cap, measured and waiting on his ruling

The never-overshoot fit divides `effDepth = min(declared, measured-median)`;
the caps stay at the DECLARED depth. Where the wall measures thinner than its
declaration — BOTH his faces — the far cap is off the last cell boundary:

    face 15: declared 12.0, median wall 10.31, cell 10.31 → far cap 1.70 mm off
             material (occupancy) reaches ~12.2 mm deep — the sliced band is real
    face 2:  declared 13.0, median wall 12.03, cell 12.03 → far cap 0.97 mm off
             per-voxel wall reaches 13.75 mm in patches (DIAG w[max])

So the back of each wall carries a sub-cell band of mid-cell-sliced struts —
feeding the back-face quilt, the "doesn't fill the carve" read, and the chamfer
"held in thin air". The 2026-08-23 whole-number fit divided the DECLARED depth
and guaranteed flush caps; the 2026-08-24 never-overshoot ruling changed the
dividend and silently broke that guarantee. Both rulings are his; they conflict
exactly here, so the resolution is his:

  (a) Fit the DECLARED depth, never overshooting: n = ceil(declared/measured),
      cell = declared/n. Face 2 → 6.5 mm × 2. Flush everywhere, carve fully
      strutted — but a 12 mm wall no longer gets a 12 mm cell (single-cell
      spirit lost on these faces).
  (b) Keep cell = measured; the residual past n·cell goes SOLID ("the declared
      volume must end up either strutted or solid, no air" — his sentence).
      Mechanically: the march clip and the shell cut must move TOGETHER to the
      fitted extent (they were once mismatched — the 0.61 mm teeth — so this is
      a one-place change or it regresses), and the visual is a pocket that ends
      at the wall with solid behind, which brushes against "never the carve
      shrink to the struts".
  (c) Extend the per-voxel rule BOTH WAYS — his corner ruling ("a corner that
      truly measures 15 gets 15") already implies a cell may GROW to its own
      thicker wall. A column whose wall is 12.2 gets a 12.2 cell spanning its
      own wall exactly: locally flush at the back surface by construction.
      Today the mechanism can only shrink (sizes are S/n); growth needs the
      non-integer phase rescale (the per-cell rescale just landed handles any
      ratio ≥ 1 only in integer form — extend before using).

## 3. OPEN — the rim is seeded, thin, and mostly out of band

`attachedSeed` finds 73k/79k seeds on the single-region scenes — §4B.1's
zero-seed hypothesis is DEAD. But the painted cells' rim distances start at one
voxel (1.72 mm, the grid's smallest expressible in-material distance) and only
17/304 (face 15) and 3/150 (face 2) fall inside the 1.72 mm band. The rim
exists and is nearly invisible — §4B.2, the width question he has been asked
and has not answered. Numbers for the conversation: at his scale a band needs
to be ≥ 2 voxels (3.4 mm) to survive discretisation, and half the local cell
(5.2/6.0 mm) to read as deliberate.

## 4. Notes in passing

- The `steppedFinestPrintableCellMM` halving loop cannot terminate if the
  density band's ceiling is 1.0 (`rhoStar` is capped at 1): finest collapses to
  0 and grading+width+rim all silently disable. Unreachable for certifiable
  topologies (LatticeBounds clamps hi to core's rhoMax ≈ 0.59) but LIVE for
  preview-only topologies, where the clamp is skipped. Worth a defensive break.
- Params-before-scene ordering in `MetalMeshView.update` verified still correct
  (steppedCellMM at 6026, setLatticeScene at 6036).
- The occupancy candidate reaches the declared depth on both faces (§4C.2's
  "occupancy too thin" hypothesis is out); the depth story is §2 above.
