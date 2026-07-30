# Show the real lattice before approving — raymarched SDF preview

**Date:** 2026-07-29
**Branch:** `claude/lattice-preview-options-8fba53`
**Scope:** `app/` only. No `core/`, no solver, no generator, no default touched.
**Evidence:** `evidence/2026-07-29-lattice-preview/`
**Status at handoff:** **SHIPPED — look approved by the maintainer after four
evidence rounds** (P5 honoured: each round posted device-real renders and waited;
rounds 2–4 were his edge-consistency feedback, below). Workspace wiring complete:
opt-in "Struts" chip (off by default → byte-identical), honesty banner, shared-
camera live layer at a capped internal resolution, P4 busy-scene test green.

## The problem

PR 229 shipped a density *proxy*: the part surface shaded by local relative density.
It says WHERE and HOW DENSE, but the maintainer cannot see the lattice he is about
to print. He wants to look at the actual struts.

The obvious answer — render the lattice mesh — is dead on arrival: on his own
bracket the real octet mesh is **368 k triangles at 8 mm and 2.95 M at 4 mm**
(measured, `profile_m2pro.txt`), and PR 184 measured ~2.8 GB of GPU buffers for a
full fine lattice — over the iOS per-app ceiling **before a frame is drawn**. And
PR 241 found the viewer's real bottleneck was rebuilding the mesh per frame, so any
answer that regenerates geometry during orbit is disqualified up front.

## The survey (numbers first, then the pick)

All figures on the maintainer's `WallMount_ShelfBracket` (204.7 cm³, bbox
201×207×20 mm), M2 Pro, the same machine as handoff 134 / PR 166 and the PR 229
proxy baseline. GPU bytes at PR 184's 156 B/tri.

| # | Approach | tris @8/6/4 mm | GPU mem @8/6/4 mm | frame time (busy) | graded? | works w/o worker mesh? | verdict |
|---|---|---|---|---|---|---|---|
| 1 | **Raymarched SDF** ★ | **0 / 0 / 0** | **~0.2 MB / 0.2 / 0.2** (occupancy tex; flat) | 15.5 / 16.3 / 16.9 ms @1024²; 47–58 ms @2048² (round-2 whole-cell edges) | **yes — radius = f(x)** | **yes** (occupancy from part mesh) | **CHOSEN** |
| 2 | Instanced unit cell | 368 k / 873 k / 2.95 M *(drawn)* | ~0.15 MB base + ≤0.3 MB instances | grows as (1/cell)³ (vertex+fill = full mesh) | per-cell scale only (crude) | yes | rejected — frame time scales like the mesh; boundary-clip to the part is a second pass; can't grade radius within a cell |
| 3 | Shell / skin | ~100 k+ (surface layer) | tens of MB | needs generation | shell only | **no** (worker-side gen) | rejected — needs the worker mesh; a view-facing shell re-generates per orbit (breaks P2); hides the interior grading, which is the feature |
| 4 | Cutaway / section | ~2–10 k (one slab) | ~1 MB | cheap, but re-gen on plane move | on the slice only | partial | rejected — shows one slice, not the part; moving the plane regenerates |
| 5 | Density proxy + patch (PR 229) | 8 940 flat | 1.3 MB | **0.31 ms** @1024² | via surface colour, not geometry | yes | the baseline — keeps its job, but does not show the lattice (the gap this task closes) |

**Why #1 wins.** A strut lattice is an analytic distance field — exactly what the
transform gizmo (PR 205/215) already sphere-traces on this device. So a fragment
shader can render the true struts with **no geometry at all**: cost is per-pixel,
and — the property this problem needs — **memory is independent of cell size** and
frame time grows only ~1.5× from 8→4 mm (measured 1.49×), where a real mesh is 8×
the triangles. It is the *only* candidate that shows the true geometry of the whole
part, at flat memory, with full grading (strut radius varies with the demand field),
needing no worker mesh, and with zero per-frame regeneration.

**What it costs (bar P3, said plainly).** The preview is **not free** the way the
proxy is. After round 2 (whole-cell edges, below), against the proxy's 0.31 ms
busy-scene baseline the raymarch is **15.5 ms @1024² (≈50×)** at an 8 mm cell —
just inside the 16.6 ms 60 Hz budget — and nearly flat in cell size (16.9 ms
@4 mm, ratio 1.09× where a real mesh is 8× the triangles). At native 2048² it is
47–58 ms (≈17–21 fps): fill-bound, it scales with pixels². The mitigation is
standard and honest: the live preview raymarches at a **capped internal resolution
(~1024² or below) and upscales**, trading edge sharpness for a smooth orbit; the
density proxy stays the always-on, near-free default and this is the opt-in "show
me the struts" view. Known un-taken speed levers if the cap is not enough on an
iPad-class GPU: per-segment bounding-sphere rejects and the octet's octant fold
(~8× fewer segments per sample). That is the trade: **~50× the proxy's frame time
(still 60 Hz-capable at the capped resolution) to see the real lattice instead of
a colour.**

## Round 2 — the maintainer's edge feedback (2026-07-29)

First posting: *"edges inconsistent — some edges lined with struts, some parts have
holes of missing cells; closest is the 4 mm; I want the edges lined with struts."*

Root cause: round 1 clipped struts per SAMPLE against a trilinear occupancy at 0.5 —
razor-cutting struts mid-span wherever the mask crossed, and dropping whole cells in
thin regions (the 20 mm plate is ~9 voxels deep, so the knife-edge test flickered).

Fix — **the worker's own emission rule, ported into the shader**: generation emits
WHOLE struts by canonical-midpoint cell ownership (PR 201); it never cuts a strut.
So now (a) every soup segment carries its owning-cell offset (`LatticeSegment.owner`
— the copy translation, which IS the midpoint rule); (b)
`LatticePreviewOccupancy.cellField` bakes a per-LATTICE-CELL activation+demand
texture, a cell being active when ≥30 % of its volume is inside the part — below
half deliberately, so boundary cells KEEP their complete struts and edges are LINED;
(c) the shader prefetches the 3×3×3 neighbourhood per marched cell and shows a strut
iff its owner is active — complete cells, never razor-cut, matching what the
generator would emit. Strut radius is now also constant per owning cell (as
production grades), not per sample point. Cost of correctness: 8.1 → 15.5 ms @1024²
(more boundary struts to march + the neighbourhood fetch); still inside 60 Hz.
`sdf_edge_closeup_4mm.png` is the zoomed edge for judgement.

## Round 3 — straight edges at every cell size (2026-07-29)

Round-2 verdict: *4 mm great; 8 mm "edges are not straight and feel messy."* Whole
cells poke ±cell/2, so the wobble scales with the cell — fine at 4 mm, messy at 8.

Fix — compose the whole-cell rule with a **flush trim at the part surface**, which
is also what the print gets (the production lattice owes exactly this union/trim at
the walls — octet-soup memory). Three pieces:

1. `LatticePreviewOccupancy.signedDistance` — an exact narrow-band signed-distance
   field of the part on the occupancy grid, by triangle SCATTER (each triangle
   min-writes exact point-triangle distances into its band-padded AABB; Ericson
   closest-point). **1.9 s debug-build bake on the bracket** (was 47 s in a first
   search-based cut), once per mesh. KEY PROPERTY: distance-to-a-plane is affine, so
   trilinear interpolation reproduces flat faces EXACTLY — the trimmed edge is
   geometrically straight, which is why this succeeds where round 1's binary-mask
   clip was ragged.
2. The shader CSG-intersects the strut field with the part SDF
   (`F = max(d_lattice, d_part, d_bbox)` — all 1-Lipschitz, so sphere-trace steps
   stay valid; the bbox term stops the clamp-to-edge sampler extruding faces that
   touch the bounds). Struts cut flush, cut faces get the part-surface normal (flat
   facets, like a machined section). Far from the part, `d_part` gives free
   empty-space leaps — round 3 is FASTER than round 2: **13.0 ms @1024² @8 mm,
   14.7 ms @4 mm (ratio 1.14×)**.
3. Cell activation drops to "any overlap" (≥2 %): every boundary cell contributes
   struts up to the surface — edges LINED at every cell size — and the trim, not a
   threshold, decides where they stop.

Silhouette now equals the part's true shape at 8 mm and 4 mm both; the 4 mm look
the maintainer approved keeps its strut-lined edges.

## Round 4 — crease slivers: floating bits + rogue stubs (2026-07-29)

Round-3 verdict: floating artifacts near the 8 mm silhouette; rogue cells poking
out along edges in the close-up.

Root cause — a real property of the interpolated trim, not a tuning knob: near a
CREASE (two faces meeting) the true SDF is a min of planes, which is concave, and
trilinear interpolation UNDERESTIMATES a concave function — so the zero surface
bulges outward in a lumpy per-voxel pattern. Strut slivers survived just outside
the true surface: against black they read as floating bits, along edges as stubs.
(Plane interiors are exact; only creases err.)

Fix: **erode the trim** by `δ = 0.35 × SDF voxel` (`stepParams.y`) so nothing
renders unless genuinely interior — flat faces just shift uniformly (still
straight) — and **refine the SDF grid** `maxDim 96 → 128` so δ stays small
(~0.57 mm on the bracket, invisible at part scale). Affordable because the bake
was rewritten from per-voxel bucket search to triangle SCATTER: **47 s → 1.9 s**
debug-build on the bracket (and 128³ stays ~2 s). Self-inspected at pixel zoom
before posting: edges end in a fine REGULAR sawtooth of trimmed strut ends; no
floaters (the top-right notch is the bracket's own slot). Perf unchanged:
**13.1 ms @1024² @8 mm, 14.9 @4 mm, ratio 1.14×**.

## How it is built

Same construction as the gizmo — a standalone raymarch renderer, so the 2 830-line
`MeshRenderer` is untouched.

| File | Role |
|---|---|
| `TopOptFlows/LatticeSDFPreview.swift` | Pure model: folds the on-device lattice family (`LatticeType`, the faithful mirror of the worker's cell table) into the centred segment soup the shader tiles; the grading map r/L = √(ρ/K); the honesty contract (`isApproximate`, `previewLabel`). |
| `TopOptFlows/LatticePreviewOccupancy.swift` | Column-parity solid voxelisation of the **part** mesh → an occupancy grid; a demand grid from the von Mises field. Baked once on a data change — never per frame (P2). |
| `TopOptFlows/LatticeSDFMetal.swift` | `LatticeSDFRenderer` + the MSL fragment shader. Sphere-traces the periodic octet field (132 capsules folded per sample), **masks each hit by the occupancy** (so it reads as the part filled with lattice, not a block), grades the strut radius by the demand texture, world-registered to the real `OrbitCamera`. `renderOffscreen` + `measureFrameGPUSeconds` mirror `MeshRenderer`. |
| `Tests/…/LatticeSDFEvidenceGen.swift`, `LatticeSDFProfileTests.swift` | Device-real PNGs (2× SSAA) + the frame-time/cost profile on the bracket. |

## The bars

- **P1 — honest.** `isApproximate` is always true; the banner will read
  **"LATTICE PREVIEW — live strut geometry, not the exported mesh."** A sphere-traced
  iso-surface is the true strut *topology* but not the byte-identical STL (node
  fillets, print tessellation differ). Colours are the proxy's indigo "amount of
  material" family (lifted off black for a lit 3-D strut), deliberately NOT the
  stress rainbow.
- **P2 — no per-frame regeneration.** There is no geometry to regenerate. Textures
  are baked once in `setScene`; `draw()` asserts `bakeGeneration` is unchanged. The
  MTKView is `isPaused` + redraw-on-demand, like the gizmo.
- **P3 — cost vs the proxy baseline.** Stated above: ~26× the proxy's 0.31 ms
  (still interactive at 1024²), 0 triangles, ~0.2 MB. `profile_m2pro.txt`.
- **P4 — plays with the keep-out layout / gizmo / proxy.** *(owed with the wiring —
  see below.)* The renderer is a separate transparent layer exactly like the two
  gizmos; the proxy stays the default and this is an opt-in mode.
- **P5 — device-real evidence, posted, WAIT for approve/change.** Rendered through
  the real `LatticeSDFRenderer` on the maintainer's own bracket, M2 Pro:
  `sdf_graded_bracket_8mm.png`, `sdf_graded_bracket_4mm.png` (finer weave, **same
  per-pixel cost** — the headline), `sdf_uniform_bracket_8mm.png` (pre-run honest
  case). Posted for judgement; **not claiming done until approved.**

## Round 5 — approval + workspace wiring (2026-07-29)

Maintainer: *"That looks amazing! Ship it!"* Wired for real:

- **`LatticeSDFPreviewView`** — the live SwiftUI host (sibling of
  `TransformGizmoMetalView`): transparent, non-interactive, `isPaused` MTKView that
  redraws only on a shared-`OrbitCameraModel` tick, with the internal raymarch
  resolution CAPPED at 1152 px long-side and compositor-upscaled (the documented
  P3 trade made concrete).
- **Workspace** (`WorkspacePlaceholder`): a "Struts" chip beside the Lattice chip
  (visible only when lattice mode is on; **off by default → byte-identical**);
  toggling on bakes the scene (occupancy + exact part SDF + segment soup) OFF-main
  (~2 s debug on the bracket, once per mesh/lattice-type — cell size and density
  changes are live shader params, no rebake); while up, the mesh body drops to
  `bodyAlpha 0.22` so the part reads as a glass shell around the TRUE struts, and
  the honesty banner (P1) rides under the chips: *"LATTICE PREVIEW — live strut
  geometry, not the exported mesh."* Lattice mode off ⇒ strut preview off.
- **P4 test** (`LatticeSDFProfileTests`): the busy strut-mode scene — glass body +
  CAD stage + design box + keep-out + the raymarch layer — measured as the SUM of
  both layers: **0.2–0.3 ms + ~13 ms ≈ 13.9 ms @1024², inside the 16.6 ms 60 Hz
  budget**. Full lattice sweep (SDF + proxy + patch + type): 30 tests green.

## Honest gaps

- **132-capsule soup** is the literal octet period; an abs-fold octant reduction
  (~8×) and per-segment bounding rejects are known further speedups, not yet taken
  (13.9 ms busy-scene total left headroom inside 16.6).
- **Node fillets / exact STL surface** are not reproduced — this is a preview of the
  strut topology, cut flush at the surface, labelled as such (P1). The trim is
  eroded ~0.6 mm inward (round 4); production's boundary union may differ in detail
  once the worker's owed lattice∪wall union lands.
- Only **octet** is wired (the print-tested cell, and the only one core certifies);
  other family members are one segment-table swap away.
- The workspace preview is **uniform pre-run** (no demand field exists before a
  solve), exactly like the density proxy; wiring a result's von Mises field into
  `LatticeSDFScene(field:)` engages graded strut radii — the code path is proven by
  the graded evidence renders.
- The 2048² native numbers (38–48 ms) are the honest uncapped cost; the live layer
  never runs there (1152 px cap).
