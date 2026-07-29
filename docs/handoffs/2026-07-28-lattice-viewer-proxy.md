# Lattice viewer proxy — show a lattice without rendering it

**Date:** 2026-07-28
**Branch:** `claude/lattice-density-proxy-a12459`
**Scope:** `app/` only. **No `core/`, no solver, no solver default touched** (FORBIDDEN bar held).
**Evidence:** `evidence/2026-07-28-lattice-viewer-proxy/`

## The problem

A latticed variant is ~316k triangles at an 8 mm octet cell and grows as
`(1/cell)³`. On the maintainer's own part (`WallMount_ShelfBracket`, 204.7 cm³
solid) the real lattice mesh is **368k tris at 8 mm, 2.9 M at 4 mm**; a whole
part at a printable cell is the ~2.8 GB/variant PR-184 measured — over the iOS
per-app jetsam ceiling **before a frame is drawn**. The device cannot render it.
But the user must still SEE what they are about to get.

## What shipped — a density proxy, not the geometry

The device never holds the lattice mesh. Instead it **shades the part surface it
already draws by the lattice's local RELATIVE DENSITY**, so the user reads WHERE
the lattice is dense and WHERE it is sparse — with no lattice geometry on the
device — and a **small true-geometry sample patch** rides alongside as the "this
is what the cells look like" reference.

### Why this representation (the justification the task asked for)

- A graded lattice **is** a scalar relative-density field ρ(x) over the part
  interior. Painting ρ(x) on the surface conveys exactly the two things that
  matter: **where** it is dense and **how dense** there. (Requirement 2.)
- It reuses the viewer's existing per-vertex colour channel (`setStressTints`),
  so shading adds **zero triangles and zero new GPU buffers** — the marginal cost
  over the part already shown is nil. Nothing else clears the memory bar.
  (Requirement 3 / V1.)
- It needs no lattice mesh, so it works when the real (worker-generated) mesh is
  **not on the device at all** — generation is worker-side. (Requirement 4.)
- Its inputs are local (lattice type, cell size, density bounds + the on-device
  von Mises demand field), so it re-shades **instantly** on a parameter change,
  with no round trip to the worker. (Requirement V3.)

### Honesty (requirement 1)

The `LatticeProxyLegend` card names it plainly: **"LATTICE PREVIEW — density proxy,
not the exported geometry."** The colours use a distinct single-hue **indigo**
"amount of material" ramp — deliberately NOT the stress heatmap's blue→red
rainbow — so a preview is never mistaken for a stress result or for the exported
mesh. The legend shows the ρ range, the true sample-patch triangle count, and the
cost it saves versus the real mesh.

### Files (all new except the two wiring points)

| File | Role |
|---|---|
| `TopOptFlows/LatticeType.swift` | **The lattice family, on device.** The worker's canonical-cell segment tables ported exactly (sc, bcc, bccz, fcc, fccz, diamond, octet), with each K in ρ ≈ K·(r/L)² and the grading map r(ρ)=L·√(ρ/K). Pure integer/Float math. |
| `TopOptFlows/LatticeDensityProxy.swift` | **The grading engine + cost model.** demand→ρ→colour tints for `setStressTints`; the indigo ramp; and the honest proxy-vs-real triangle/GPU-byte comparison at any cell. |
| `TopOptFlows/LatticeSamplePatch.swift` | **The true-geometry sample patch.** A few cells of capped-8-gon-prism struts (32 tris) + icosahedron nodes (20 tris) → a small `ViewerMesh`. |
| `TopOptFlows/LatticeProxyModel.swift` | `@MainActor` state: params, density tints, memoised patch thumbnail, cost table, legend stops, and the `LatticeProxyLayout` keep-out element. |
| `TopOptFlows/LatticeProxyLegend.swift` | The honest SwiftUI legend card (banner + sample patch + ρ ramp + cost line). |
| `TopOptFlows/WorkspacePlaceholder.swift` | **Wiring (2 points):** a "Lattice preview" toggle chip + `latticePreviewOverlay`; and `stressTints: latticeProxyTints` on the workspace `MetalMeshView`. Off by default → byte-identical when unused. |
| `Tests/…/LatticeProxyTests.swift`, `LatticeSamplePatchTests.swift`, `LatticeProxyKeepOutTests.swift`, `LatticeProxyProfileTests.swift`, `LatticeProxyEvidenceGen.swift` | 23 headless tests + the M2-Pro profile + the evidence renderer. |

## The bars

### V1 — triangle count + GPU memory, proxy vs real, at 8 / 6 / 4 mm

On the maintainer's bracket (204.7 cm³ solid, octet), M2 Pro. GPU bytes use the
**same 156 B/tri** model PR-184 measured the 2.8 GB figure with (handoff 134's
viewer pipeline: pos+nrm+tint+flex soup = 36 628 tris → 5 580 KB → 156.0 B/tri).

| cell | REAL lattice tris | REAL GPU | PROXY tris | PROXY GPU | cheaper by |
|---|---:|---:|---:|---:|---:|
| 8 mm | 368 328 | 54.8 MB | **8 940** | **1.3 MB** | **41×** |
| 6 mm | 873 073 | 129.9 MB | **8 940** | **1.3 MB** | **98×** |
| 4 mm | 2 946 620 | 438.4 MB | **8 940** | **1.3 MB** | **330×** |

The proxy is a **flat 8 940 tris / 1.3 MB regardless of cell size** — it is the
sample patch (shading adds 0 tris, 0 new buffers). The real mesh grows as
`(1/cell)³`; at a denser lattice / finer cell it reaches PR-184's ~2.8 GB
(18.5 M tris × 156 B) and **cannot be held in memory to draw at all**, which is
exactly the case the proxy exists for. Full data:
`evidence/…/profile_m2pro.txt`. (`realReferences` anchors the scaling to the
committed 8 mm reference_region.csv counts; the finite-block boundary correction
is a few percent and shrinks with more cells.)

### V2 — frame time in a busy scene vs the PR-166/134 committed viewer profile

Busy working scene = part + CAD stage + design box + keep-out box (the workspace's
heaviest renderer overlays; the gizmo is a SwiftUI overlay, not a renderer draw).
Minimum of 40 frames, M2 Pro — the same method and machine as handoff 134's
committed `viewer_profile.txt` (body @1024² = 0.436 ms).

| | @1024² | @2048² |
|---|---:|---:|
| proxy OFF (neutral) | 0.40–0.70 ms | 2.0–2.9 ms |
| proxy ON (density shaded) | 0.39–0.64 ms | 2.0–2.5 ms |
| sample-patch inset @512² | — | 0.165 ms |

**OFF and ON are statistically indistinguishable — ON is the faster of the two in
4 of 6 measured rows.** The density shading is a per-vertex colour on the same
draw call; it adds no measurable frame cost, as predicted. The busy scene stays
~0.5 ms @1024² (≈ the 0.436 ms body baseline + the box overlays), ~30× inside the
16.6 ms 60 Hz budget. The only extra thing the proxy draws is the ~0.17 ms sample
patch. (3 runs: `evidence/…/profile_m2pro.txt`.)

### V3 — updates on a local param change, no worker round trip

`LatticeProxyTests.testParamChangeReshadesLocally`: a grading-curve (gamma) change
re-shades the surface from the SAME field object; the density-range labels track
ρmin/ρmax instantly. The colour is normalized over [ρmin,ρmax] (maximising
contrast for the where-dense/sparse question), so a pure ρmax change re-labels the
legend rather than the extremes — gamma / lattice / cell / field all re-derive the
tints, patch, cost and readouts with no round trip. `latticeProxyTints` recomputes
in `body` (O(vertices), a few k) — the update is local and immediate.

### V4 — does not fight PR-217 keep-out or the gizmo

`LatticeProxyKeepOutTests`: driven through the real `KeepOutSolver` with a busy
scene (transform gizmo + orientation gizmo + settings chip + clearance knob), the
legend is registered as the **lowest priority `.label`** (`LatticeProxyLayout`),
so it never displaces a control — when the gizmo lands on it, the pass floats the
LEGEND clear (it moves; the rigid gizmo does not) and it overlaps none of the
busy set afterwards. In the live app it is additionally leading-anchored, clear of
the centre gizmo, the top-right orientation gizmo and the bottom-right chips.

### V5 — device-real evidence on the maintainer's own part

Rendered through the app's **own Metal pipeline** (`MeshRenderer` +
`renderOffscreen`) on `WallMount_ShelfBracket`, M2 Pro:

- `proxy_graded_bracket.png` — the bracket shaded by an illustrative cantilever
  demand field: deep indigo (dense) grading to pale (sparse) along the part. The
  grading *correctness* is pinned separately in `LatticeProxyTests` against a
  controlled field; this render is illustrative of the LOOK, not a solve.
- `proxy_uniform_bracket.png` — the workspace pre-run state (no field → uniform
  density), the honest flat preview.
- `proxy_sample_patch.png` — the true-geometry octet 2³ patch (struts + node
  blobs), 8 940 tris.

**Owed, per the 134/PR-166 precedent:** a physical-iPad screenshot of the live
`latticePreviewOverlay` + an Instruments frame capture on device. Nothing on the
Mac can stand in for the on-device frame time; the M2 Pro numbers here are the
directly-comparable proxy for it, exactly as handoff 134 recorded its device
numbers separately.

## What this is NOT / honest gaps

- **The workspace preview is uniform pre-run** (no demand field exists before a
  solve). Graded shading engages wherever a von Mises field is supplied — the
  code path and its correctness are proven; wiring the last result's field into
  the workspace preview is a small follow-up, not done here.
- **Kelvin / rhombic / re-entrant** are not ported to the on-device table (they
  need polyhedron-edge / waist-node builders the sample patch does not need to be
  representative). The seven ported lattices span the family's K = 8.49…48 range.
- The proxy shows **relative** density normalized to the design's own [ρmin,ρmax];
  absolute ρ is read from the legend labels. This is deliberate (max contrast for
  the where-dense/sparse question).

## Off-switch / blast radius

`LatticeProxyModel.isActive` defaults false → `latticeProxyTints` is nil → the
workspace `MetalMeshView` draw is byte-identical to before. No core, solver,
fixture, materials.json, rules.json or ROADMAP box was touched.
