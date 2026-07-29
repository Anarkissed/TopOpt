# 2026-07-29 — Viewer lag on variant display

**Track:** app only. **Territory:** `/app/TopOptKit/` (`TopOptFlows`). **NO core, NO
bridge, NO solver, NO shaders.** One source file changed (`ResultsModel.swift`), one
test file added.

**Verdict:** The lag is **not** the GPU draw and **not** the mesh's vertex count. It
is `ResultsModel.selectedMesh` **rebuilding the entire `ViewerMesh` from scratch on
every SwiftUI body evaluation** — once per orbit frame and 30×/s during any
animation — an O(triangles) main-thread cost that scales with resolution, which is
exactly why it bites on "real" (higher-resolution) variants. The fix caches the built
mesh on `selectedIndex`, in the same idiom every sibling derived quantity already
uses. The displayed and exported geometry are **byte-identical** (proven).

---

## 0. Reproduce 166's committed profile first (the ★ requirement)

PR 166 / handoff 134 committed the instrument `ViewerProfileTests` and its numbers in
`docs/handoffs/evidence/134/viewer_profile.txt`. **The instrument still works.** Run
today on freshly-generated res-64 l-bracket variants (Apple M2 Pro, the same GPU 134
used), it reproduces every *structural* finding of the committed profile:

| finding | 134 committed | today (exact res-64 ladder) |
|---|---|---|
| weld ratio (soup ÷ welded) | 6.00–6.02× | **6.00–6.01×** |
| raw verts = tris × 3 | yes (asserted) | yes (asserted, green) |
| draw calls at rest/orbit | 2 (stage + body) | 2 |
| body GPU frame @1024² | 0.13–0.50 ms | **0.34–0.47 ms** |
| body GPU frame @2048² | 0.28–1.04 ms | **0.28–1.01 ms** |
| shape: fill-bound, not geometry-bound | yes | yes |

**One honest caveat, itself a finding:** the *absolute triangle counts* do not
reproduce. 134's res-64 ladder was 36,628 / 29,100 / 21,652 tris; today's is 33,028 /
25,840 / 16,756. That is **solver-output drift**, not an instrument regression — the
mesh is a function of the solver, and HEAD (post-multigrid / graded-cell, `020bac0`)
converges to a different accepted density field than 134's commit
(`multigrid-solver-opt-in-e1bba5`). The margins match closely (0.70 rung: 2856 today
vs 2.86e3 in 134), the meshes are real accepted bracket variants, and the census
columns are exact deterministic functions of whatever mesh is fed in. The committed
STLs themselves were never checked in (134's harness writes them to a temp dir), so
the *exact* committed numbers cannot be regenerated without that exact solver commit.
Evidence: `evidence/2026-07-29-viewer-lag/profile_release_res64_AFTER.txt` (GPU block),
`evidence/2026-07-29-viewer-lag/ladder64/` (the meshes + `cli.log` + `report.json`).

Reproduce:
```bash
# regenerate the ladder (~13 min on an M2 Pro)
core/build/topopt-cli run evidence/2026-07-29-viewer-lag/ladder64/job.json --out <dir>
# run the committed instrument against it
cd app/TopOptKit
TOPOPT_VIEWER_PROFILE_DIR=<dir> swift test --filter ViewerProfileTests
```

---

## 1. Diagnose before fixing — where the time goes, with a number

134 already proved half of this and left the other half as "the fix task's first
step": the body **draw** is sub-millisecond and **fill-bound** ("Indexing would not
buy frame time here"), and the open question was **at-rest / per-frame invalidation** —
"whether some state keeps invalidating the view."

It does. The results viewer's per-frame cost is not on the GPU; it is on the **CPU, in
the SwiftUI body**. `ResultsScreen.body` reads `viewerMesh` → `model.selectedMesh`,
which was a **computed property with no cache**: every read ran `ViewerMesh.init`,
which computes smooth per-vertex normals (O(tris)) and builds the **6× unshared
flat-shaded soup** (O(tris), millions of Swift array appends). `body` re-evaluates:

* **once per orbit frame** — the shared `OrbitCameraModel` is an `@StateObject`; every
  drag delta republishes `@Published camera`, invalidating the screen; and
  `onProjection { projection = $0 }` writes an `@State` on top of that; and
* **30×/s during any Play / Flex / Load-path animation** — the ticker advances
  `@Published playT` / `flexPhase` / `flowClock`.

Every sibling derived quantity is already cached on `selectedIndex` — `flexCache`,
`keyframeCache`, `loadPathCache`, `loadPathSegmentCache`, `flowCurveCache`,
`peakToRedCache`. `selectedMesh` was the one exception, and it is the largest of them.
It is even read **more than once per body pass** (the `flexDisplacements` guard reads
it again; `bounds.radius` markers read it twice more).

**The number** (min-of-60, same method as 134's profile, same M2 Pro), measured by the
added instrument `ViewerRebuildProfileTests` against the committed meshes:

| build | mesh | `selectedMesh` rebuild / body-eval | for comparison: 166's GPU draw @1024² |
|---|---|---|---|
| **release** (ships) | 33,028 tris | **1.27 ms** | 0.47 ms |
| release | 25,840 tris | 0.98 ms | 0.30 ms |
| release | 16,756 tris | 0.63 ms | 0.34 ms |
| **debug** (166's config) | 14,984 tris | **50.5 ms — 151% of a 30 fps frame** | ~0.4 ms |
| debug | 13,784 tris | 46.6 ms — 140% | ~0.4 ms |
| debug | 8,700 tris | 29.3 ms — 88% | ~0.4 ms |

Read this two ways, both honest:
* **Same config as the committed instrument** (debug — what `swift test` and 134's
  profile run in): the rebuild is **30–50 ms, i.e. 60–100× the body draw**, and blows
  the entire frame budget on its own.
* **Release** (what the maintainer ships): the rebuild is 0.6–1.3 ms at res-64 —
  *smaller* than in debug, but still **larger than the whole GPU frame 166 measured**,
  and unlike the draw it (a) runs on the main thread, (b) recurs every body-eval and
  2–4× within a flex frame, and (c) **scales with triangle count**, so at the higher
  resolutions the maintainer actually uses, and on the iPad's slower CPU, it is the
  term that turns into visible lag.

Either way the dominant cost is **mesh generation re-run during view updates**, not the
draw. Evidence: `rebuild_release_res64_BEFORE.txt`, `rebuild_debug_smoothset_BEFORE.txt`.

### The wrong-stage trap this avoids
134's memory finding was that the soup is 6× and welding it would cut ~5.6 MB → ~1.4 MB
per variant. That is a real **memory** win, but 134 also states plainly it "would not
buy frame time." Welding/indexing the mesh is precisely the mis-aimed fix this project
has shipped before: it targets the GPU draw (already sub-ms) and would make the
*per-frame rebuild* — the actual cost — **slower**, because welding adds a
dedup pass on top of the build. The lag lives one stage upstream of where a
vertex-count optimization would touch.

---

## 2. The fix

`ResultsModel.selectedMesh` now caches the built `ViewerMesh` keyed on `selectedIndex`,
reset alongside the sibling caches in `update(from:)` when variant data changes. Nine
lines of logic, in the established idiom.

* **Per-body-eval cost after:** cache hit, **0.001 ms** at every triangle count (the
  build runs once per variant *selection* — a discrete user action — not once per
  frame). `profile_release_res64_AFTER.txt`.
* **Geometry unchanged (bar V2):** `testCachedMeshIsGeometricallyIdentical` asserts the
  cached mesh's `flat.positions`, `flat.normals`, and `indices` are equal, element for
  element, to a fresh `ViewerMesh` build. The cache returns the *same value*, so there
  is **no** level-of-detail, decimation, or approximation — the viewer shows exactly
  what it did before and exactly what it exports. This is not an LOD trick.

The getter mutates a plain (non-`@Published`) stored property on the `ResultsModel`
class, so there is no objectWillChange feedback loop — identical to how `flexCache`
et al. already work.

---

## 3. Before / after at each triangle count (bar V1)

Per-frame cost of displaying a variant (orbit or animation), Apple M2 Pro:

| tris (res-64) | GPU draw (166, unchanged) | CPU rebuild BEFORE | CPU rebuild AFTER | per-frame total AFTER |
|---|---|---|---|---|
| 16,756 | 0.11–0.34 ms | 0.63 ms (rel) / 29 ms (dbg) | **0.001 ms** | ≈ GPU draw only |
| 25,840 | 0.30–0.97 ms | 0.98 ms (rel) / 47 ms (dbg) | **0.001 ms** | ≈ GPU draw only |
| 33,028 | 0.47–1.01 ms | 1.27 ms (rel) / 50 ms (dbg) | **0.001 ms** | ≈ GPU draw only |

After the fix the per-frame cost of the variant viewer is **the GPU draw alone** —
which 166 measured as sub-millisecond and fill-bound.

---

## 4. Usable / not-usable triangle count (bar V3)

* **Now usable across the whole practical variant range.** With the rebuild removed
  from the frame, per-frame cost is the fill-bound GPU draw (sub-ms at res-64, growing
  slowly with tris). Orbit and animation are limited by the draw, not the mesh build,
  from the tens-of-thousands of triangles a res-64 surface carries up through the
  hundreds-of-thousands a res-128 surface carries. The only residual is a **one-time**
  sub-frame build on variant *selection* (0.6–1.3 ms release at res-64), which is a
  discrete tap, not a per-frame cost.
* **Still not usable — and out of scope for this viewer — at the multi-million-triangle
  scale** of a fully-rendered lattice (the res-4mm case is 2.9 M tris / 438 MB in the
  lattice-proxy profile). That regime is exactly what the **lattice density proxy (PR
  229)** exists for: it shades the part by density instead of rendering the lattice
  geometry (41–330× cheaper). This fix does not change that boundary; it makes the
  *solid variant* viewer fast up to it.

---

## 5. No regression to the other systems drawing into this view (bar V4)

Full package suite: **925 tests, 8 pre-existing failures, 0 introduced.** The 8
failures are all `AppModelTests` 3MF-import cases failing with "3MF import requires
lib3mf, which is not available in this build" — an artifact of `build_core.sh` not
linking vcpkg's lib3mf into the macOS test slice; they fail **identically on the base
commit with the fix stashed** (verified). Nothing in this change touches import.

The three systems the brief names all draw into this view and all pass:

* **Keep-out layout (PR 217):** `ViewportKeepOutTests`, `ClearanceGeometryTests`,
  `ClearanceDerivationTests`, `ClearanceChipLayoutTests`, `LatticeProxyKeepOutTests` — green.
* **Gizmo:** `OrientationGizmoTests`, `PrimitiveGizmoTests`, `TransformGizmoTests`,
  `GizmoShaderCompileTests` — green.
* **Lattice density proxy (PR 229):** `LatticeProxyTests`, `LatticeProxyProfileTests`,
  `LatticeSamplePatchTests`, `LatticeProxyEvidenceGen` — green (its own profile still
  reports 41–330× and its busy-scene numbers unchanged).

Plus the viewer/results suites: `ResultsModelTests`, `ViewerTests`,
`ViewerVisibilityRegressionTests`, `StreamedVariantVisibilityTests`,
`ViewerProfileTests` — green.

---

## 6. Device-real evidence (bar V5) — honest scope

These are **Apple M2 Pro** numbers, the same machine and the same headless offscreen /
CPU-timing method 166's committed profile used. As 134 stated for its own numbers, an
iPad's CPU and tile-based GPU do not scale from these linearly. What transfers to the
device is the **structure**, not the milliseconds:

* the rebuild is O(triangles) and the draw is fill-bound — both hold on any GPU/CPU;
* the iPad CPU is materially slower at single-threaded Swift array-append work than an
  M2 Pro, and the maintainer runs higher resolutions, so the BEFORE rebuild is *larger*
  on device than the 0.6–1.3 ms measured here, not smaller — the fix helps more there,
  not less;
* the AFTER per-frame cost is a dictionary-free struct cache hit (~1 µs) on any CPU.

I could not attach Instruments to a physical iPad from this environment, and the iOS
Simulator runs on the Mac's own CPU/GPU so it is not a device measurement either — so,
like 134, I am explicit about the one cell I cannot fill: **the on-device GPU frame
time.** The instrument to close it already ships (134's `ViewerFrame` signpost +
`ResultsFrame` `body_eval`). The maintainer's device capture is now a clean confirm:
open results on a real variant, record Instruments, orbit 10 s. BEFORE, each
`body_eval` interval carries a multi-millisecond main-thread stall (the rebuild) beside
every `ViewerFrame`; AFTER, `body_eval` collapses to the sub-ms cache-hit path and the
frame is the draw alone.

---

## Files

* `app/TopOptKit/Sources/TopOptFlows/ResultsModel.swift` — `selectedMesh` caches on
  `selectedIndex`; cache reset added to `update(from:)`.
* `app/TopOptKit/Tests/TopOptFlowsTests/ViewerRebuildProfileTests.swift` — new, opt-in
  (gated on `TOPOPT_VIEWER_PROFILE_DIR` exactly like `ViewerProfileTests`): times the
  per-body-eval rebuild and asserts the cached mesh is geometrically identical.
* `evidence/2026-07-29-viewer-lag/` — GPU profile (166 reproduced), rebuild before/after
  (release + debug), and `ladder64/` (the exact meshes + `job.json` + `cli.log` +
  `report.json`).

## Reproduce the fix numbers
```bash
cd app/TopOptKit
D=<topopt-cli --out dir>
# AFTER (fix in tree): rebuild cost is ~0.001 ms and the identity test passes
TOPOPT_VIEWER_PROFILE_DIR=$D swift test -c release --filter 'ViewerProfileTests|ViewerRebuildProfileTests'
# BEFORE: git stash the ResultsModel change and re-run ViewerRebuildProfileTests
```
