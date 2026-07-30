# Measurements — lattice preview alignment / jitter / single object (2026-07-30)

All numbers from `LatticeSDFAlignmentTests` / `LatticeSDFProfileTests` on the M2 Pro,
maintainer bracket (`WallMount_ShelfBracket.stl`), settle = 60° about a skew axis
(nothing axis-aligned, so any missed rotation shows).

## A1 — alignment is exact

Worst screen-space displacement of the 8 projected AABB corners, lattice pass vs the
body pass's own composition (settle-about-centre + CameraProjection), 3 orbit angles
× 2 zoom levels, 1024×768 viewport. Includes the shader's actual per-pixel ray
fidelity (eye + exact ray basis), not just the matrix.

- after: **0.0007 px** (bar: ≤ 0.5 px) — MET
- the shipped P·V-only transform, same poses: **839.9 px** (the bug)

## A2 — no jitter

Scripted orbit (120 frames, Δazimuth 0.004 rad), fixed model-space corner:

- transform track: worst frame delta 0.2993 px, worst reversal **0.0000 px** (bar 0.25) — MET
- rendered-frame alpha-centroid track (40 frames @512², empirical, catches hidden
  per-frame state): worst frame delta 0.2371 px, worst reversal **0.2371 px** (bar 0.25) — MET
- before the ray fix the same rendered track showed reversals of **3.24 px** —
  the swimming came from far-plane w-cancellation in the Float inv(P·V) unproject,
  NOT from the eps constant. eps (:404) is untouched; the eps-shell view-dependence
  (hit accepted anywhere in F < eps) is fixed at the cause by a secant refinement to
  the F = 0 root (zero extra field evaluations).

## A3 — one object, picking intact

`testPickingUnchangedWithBodyInvisible`: with `bodyAlpha 0` every rendered pixel
equals the clear colour (max body contribution byte = 0), and `pickFaceID` at three
viewport points returns identical face ids to the visible-body reference. MET.

## A4 — selection tints on the lattice

`testFaceTintVolumeLockstep`: tint volume voxels carry the tint dictionary's colours
VERBATIM (unorm8), including `WorkspacePlaceholder.protectFaceRGB` — one source of
truth, asserted byte-for-byte. GPU: mean(G−R) over pixels facing the anchor-tinted
face: −5.6 plain → **+49.0** tinted. MET. See `single_object_tinted_faces.png`.

## A5 — preview-off byte-identical

Deterministic preview-off mesh render + pick hash (`testPreviewOffRenderAndPickHash`):

- HEAD (11a4352): `e5655c7e1a5202b60f941894ff4b155a8f05d5075db3b045da3f9a41f7a35142`, pick=1
- after this change: **same hash, same pick**. `MetalMeshView.swift` untouched (git diff). MET.

## A6 — no perf regression (LatticeSDFProfileTests, @1024², best-of-40)

| cell | before (HEAD) | after |
|------|---------------|-------|
| 8 mm | 12.978 ms | 13.137 ms |
| 6 mm | 13.871 ms | 13.180 ms |
| 4 mm | 14.730 ms | 14.254 ms |
| busy strut-mode scene | 14.047 ms | 13.019–13.881 ms |

Run-to-run variance ~±1 ms; all inside the 16.6 ms bar, no regression. MET.

## A7 — the P2 claim is now true

`testNoBakeAcrossDrawsOrShadeParamChanges` pins `bakeGeneration` across encoded
frames / camera / model-rotation / shade-param changes, and asserts exactly one bump
per cell-size change. The source comment now names the test. MET.

## Images

- `align_pose1_before.png` / `align_pose1_after.png`, `align_pose2_before.png` /
  `align_pose2_after.png` — settled body (opaque, for the comparison) with the
  lattice layer composited over it at MATCHED camera poses; "before" replays the
  shipped transform. The thin grey rim in "after" is the documented 0.35-voxel
  flush-trim erosion — invisible in the app, where the body is not drawn (A3).
- `single_object_tinted_faces.png` — the lattice as the only object, protect-mint
  and anchor-green faces tinting the flush-cut sections (A4).
- `a5-baseline.txt` — the HEAD-side hash record.

## Pre-existing failures (identical at HEAD and after: 9)

- `AppModelTests` 3MF (3): this worktree's core build has no lib3mf (build_core.sh
  says so); environmental.
- `LatticeModeTests` (2 tests, one crashes the suite): stale vs the 7-topology
  certifiable core (tensor-library-nine) — flagged as a separate task.
