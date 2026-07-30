# 2026-07-30 — Lattice preview alignment, jitter, single object

Branch: `claude/lattice-preview-alignment-jitter-fdcb2d`
Scope: app/ only — `LatticeSDFMetal.swift`, `LatticeSDFPreview.swift`,
`WorkspacePlaceholder.swift`, lattice test files. `MetalMeshView.swift` untouched
(that is itself part of the A5 proof). Evidence:
`evidence/2026-07-30-lattice-preview-alignment/` (note: the maintainer's screenshots
were said to be there, but the directory did not exist in the repo — diagnosis was
done from code and measurement instead; the before/after composites reproduce the
reported symptoms exactly).

## The hypothesis, verified — and where it was wrong

The handoff hypothesized two model-to-world transforms: a `maxDim` normalisation in
`LatticeSDFScene` (:74) and the renderer framing its own camera (:174).

- **`maxDim` normalisation: REFUTED.** `maxDim` only sets the occupancy/SDF voxel
  resolution; every grid is in the mesh's own mm coordinates. There was no scale
  transform.
- **Own camera at :174: real but not the cause.** `setScene` did frame the
  renderer's local camera, but `apply()` overwrote it with the shared
  `OrbitCameraModel` mirror in the same call, before any draw. Removed anyway —
  `setScene` no longer touches the camera; there is exactly ONE camera source.
- **The actual offset: the missing settle model matrix.** `MeshRenderer` draws the
  body with `mvp = P · V · T(centre) · R_settle · T(−centre)` (the gravity settle);
  the lattice pass used `P · V` alone. With gravity set — the normal edit state —
  the body is rendered rotated and the lattice is not: a small offset on parts whose
  settle is small, floating clear of the solid on parts settled ~90°. Measured
  worst-corner displacement under a realistic settle: **839.9 px**.
- **A second, subtler offset + the orbit swim: ray reconstruction.** The shader
  reconstructed rays by unprojecting clip-space corners through a Float32
  `inv(P·V)`. With near 0.01 / far 10 000 the w component at the far plane is a
  catastrophic cancellation (terms ~1 summing to ~1e-4), warping rays by **1–8.9 px**
  depending on pose — present even with identity settle, and varying smoothly with
  the camera, i.e. the preview swam during orbit even "when correctly placed".
- **Two smaller jitter contributors**, both fixed at their cause:
  - macOS `apply()` re-set `view.drawableSize` on every SwiftUI update — every
    orbit tick — forcing CAMetalLayer churn mid-orbit. Now only touched on change.
  - the sphere-trace accepted a hit anywhere in the eps-thick shell `{F < eps}`,
    whose depth along the ray varies with view direction — the surface breathes as
    the camera orbits. Fixed by one secant step to the true `F = 0` root (zero
    extra field evaluations). The eps constant (:404) is untouched, per the bar.

## The fix: one transform, one camera, from a single source

The workspace hands the SAME `(settleQuat, meshCenter)` it gives `MetalMeshView` to
`LatticeSDFPreviewView`; the lattice renderer composes the identical
`T·R·T⁻¹` model matrix and marches in MODEL space, where every baked grid lives.
The per-pixel ray is now the exact geometric inverse of `P·V·model`, built on the
CPU from the camera basis (eye + right/up/forward with the frustum half-tangents) —
no matrix inversion anywhere in the ray path. The projection uses the shared
viewport aspect rather than the capped drawable's integer-rounded ratio. Eye and
key light are rotated into model space so shading stays world-fixed on a settled
part.

While the preview is up the body is not drawn at all (`bodyAlpha 0` — bar A3): one
visible object. It keeps serving the id-pass pick unchanged. The face-role markings
(anchor / load / keep-clear / protect) now read on the LATTICE: `LatticeFaceTintVolume`
bakes the mesh view's own `[FaceID: color]` dictionary — one source of truth,
protect mint included — into an rgba8 volume on the part-SDF grid; the shader tints
flush-cut hits by a trilinear sample. Baked only when the selection changes (P2).

## Bars — all MET (numbers in evidence/…/measurements.md)

- **A1** worst corner displacement **0.0007 px** (bar 0.5) over 3 angles × 2 zooms;
  the shipped transform measured 839.9 px on the same poses.
- **A2** transform track: 0 reversals (worst delta 0.299 px/frame); rendered
  alpha-centroid track: worst reversal **0.237 px** (bar 0.25) — down from 3.24 px
  before the ray fix. The eps question is answered explicitly above: the swim was
  the inverse-matrix cancellation, and the eps-shell breathing is fixed by secant
  refinement, not by tuning the constant.
- **A3** `testPickingUnchangedWithBodyInvisible`: alpha-0 render contributes zero
  bytes; same face ids picked at three points.
- **A4** `testFaceTintVolumeLockstep`: colours pass through byte-exact from the one
  dictionary (asserted against `WorkspacePlaceholder.protectFaceRGB`); GPU render
  shifts mean(G−R) by +54 facing the tinted face.
- **A5** preview-off render+pick hash identical at HEAD and after
  (`e5655c7e…5142`, pick=1); `MetalMeshView.swift` has no diff.
- **A6** profile @1024²: 13.14/13.18/14.25 ms (8/6/4 mm) vs 12.98/13.87/14.73 ms
  before; busy scene 13.0–13.9 ms vs 14.0 ms — inside 16.6 ms, no regression.
- **A7** `testNoBakeAcrossDrawsOrShadeParamChanges` written; the :135 comment now
  names it instead of claiming coverage that did not exist.

## Caveats / known residuals

- The settle ANIMATION (0.8 s ease, `MeshRenderer`-internal) animates the body's
  rotation; the lattice uses the target quat. If the strut layer is up during that
  brief animation the two disagree transiently, then coincide. Threading the
  animated rotation out would touch `MetalMeshView` — out of this PR's scope, and
  invisible in practice since the body is hidden while the preview is on.
- The lattice still lives in its own MTKView layered over the stage/ground view;
  hiding the body removed the visible reference that made cross-layer presentation
  skew perceptible, and the drawable is no longer reset per tick. A single-drawable
  merge remains available as a future step if any residual is ever observed.
- Pre-existing test failures (identical at HEAD, 9): `AppModelTests` 3MF ×3 (no
  lib3mf in this worktree's core build), `LatticeModeTests` ×2 stale vs the
  7-topology certifiable core (separate task chip spawned).

## Plain language

**What was built.** The strut preview now sits exactly where the part is, in every
camera pose. The bug was that the part gets rotated onto the floor once gravity is
set, but the strut preview was never told about that rotation — so it drew the
lattice where the part used to be. On top of that, the preview's per-pixel rays
were computed through a poorly-conditioned inverted matrix that bent them by a few
pixels and made the image swim during orbit. Both are gone: both layers now consume
one camera and one part-rotation from a single source, and the rays are built
exactly, with no inversion. While the preview is on, the solid body is no longer
drawn at all — the lattice IS the object — but tapping faces still works because
the invisible body still answers picking. Faces you mark (anchor, load, keep-clear,
protect) now paint their colours onto the lattice itself, using the exact same
colour table as the body, and a test keeps the two in lockstep. With the preview
off, rendering is proven byte-identical to before. Frame cost is unchanged
(~13–14 ms in the busiest scene, inside the 60 Hz budget).

**Next steps.** (1) If any residual cross-layer skew is ever seen during orbit, the
follow-up is to move the lattice pass into the mesh renderer's own drawable — the
transform work here makes that a mechanical merge. (2) The settle animation could be
shared so the lattice follows the 0.8 s settle ease frame-by-frame. (3) Two stale
test groups unrelated to this work need attention: the 3MF app tests need lib3mf in
the worktree build, and LatticeModeTests still assumes only octet is certifiable
(a chip for that fix has been filed).
