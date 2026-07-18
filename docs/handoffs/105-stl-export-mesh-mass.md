# 105 — STL export + honest mesh mass (EXPORT; closes Open #6 mass gap)

## What shipped

The results-screen **Export** button is now real. It writes a **binary STL** of the
selected variant and presents a share sheet (AirDrop / Files / Mail). At export it
also computes the **exported mesh's** mass and shows it beside the voxel-count
estimate when they diverge — closing the mass gap flagged in handoff 086 (Open #6),
option (a) "compute the displayed mass from the exported mesh's enclosed volume".

No bridge / core change. `OptimizeVariant.meshVertices/meshIndices` already carry the
mesh for **both** local and remote variants (a remote variant's mesh is a local
buffer too — 097), so the STL is written app-side from those buffers. The core's
`write_stl_file` stays for the CLI path.

### Files

- **NEW `MeshExport.swift`** — pure value math, no SwiftUI/bridge:
  - `binarySTL(vertices:indices:header:)` — little-endian, **80-byte header** naming
    the app + variant, correct triangle count, **computed facet normals**
    (`(b−a)×(c−a)` normalized; zero for degenerate). Units = the stored units (mm).
    Out-of-range/partial triangles are dropped and the count field stays honest.
  - `parseBinarySTL(_)` — the reader; `RemoteRunner` now delegates its private
    parser to it, so the app export **round-trips through the same parse** the
    remote mesh path relies on.
  - `meshVolume(vertices:indices:)` — enclosed volume by the **divergence theorem**
    (Σ a·(b×c)/6, abs). Unit cube → 1.0; ×k → k³.
  - `meshMassGrams(...:densityGCm3:)` — `density × volume(mm³)/1000` (the SAME
    definition `minimize_plastic.cpp` uses for the voxel count, measured on the mesh).
  - `isWatertight(vertices:indices:)` — topology check (every undirected edge shared
    exactly twice), mirroring the core's `check_watertight`; the variant carries no
    stored flag, so watertightness is derived to know when to label the mesh mass an
    estimate.
- **`ResultsModel.swift`** — `canExport` / `exportDisabledReason`, `exportFilename`
  (`{project}-{material}-{NN}pct.stl`, **NN = printed savings %**, names sanitized),
  `exportSTLData()`, `selectedMeshVolumeMM3`, `selectedMeshWatertight`, and
  `selectedMassComparison` (the `MassComparison` value + labels). New
  `materialDensityGCm3` (see wiring note). Added `MassComparison` and a
  `MaterialDensityTable` (bundled-materials.json density lookup by name).
- **`ResultsScreen.swift`** — Export button label `Export .3mf` → **`Export .stl`**;
  real action (`exportSTL()` writes a temp file + presents `UIActivityViewController`
  via the existing `ShareSheet`); **disabled** with an honest accessibility reason
  when the variant has no mesh; a `massDetailCaption` shows
  "Mesh: 41.3 g · voxel estimate: 43.1 g" when they diverge >1% (or "(est.)" when the
  mesh isn't watertight).
- **Tests** — `MeshExportTests.swift` (round-trip, 80-byte header, exact triangle
  count/byte size, unit-cube volume == 1.0, two-cube box == 2.0, disjoint cubes,
  orientation independence, mass, facet normals, watertight vs open, empty/bad-index
  guards); `ResultsExportTests.swift` (filename format + sanitize, enable/disable
  gate, valid STL bytes, remote parity, mass comparison show-both/single/estimate/
  no-density/remote-no-voxel).

## Mass gap (Open #6) — resolved

The voxel-count mass runs a percent or two **heavy** on lacy parts vs the mesh that
exports. At export we compute the mesh's enclosed volume and derive its mass from the
material density, and show **both, labeled** ("Mesh: … · voxel estimate: …") when
they diverge beyond 1% — never silently swapped. Non-watertight mesh → the mesh
number is labeled an estimate. This is the app-side implementation of 086's
recommendation; `mass_grams` in the core is untouched.

## .3mf — out of scope (unchanged)

lib3mf is not in the app build, so **STL today; .3mf planned**. The button label and
its doc comment now say so. The old **"Export (.3mf) arrives in M7.9" toast is dead**:
the button no longer calls the injected `onExport` closure (retained only for API
compatibility). That toast string literally lives in `WorkspacePlaceholder.swift:229`,
which this task must NOT touch (handles task owns it tonight) — it is now
**unreachable dead code**; recommend the handles-task owner (or a tiny follow-up)
delete the closure body. No user-visible `.3mf` copy remains.

## Density wiring note (coordination)

`ResultsScreen`/`ResultsModel` are constructed in `WorkspacePlaceholder.swift` (off-
limits tonight), which passes the material **name** but not its density. Rather than
edit that call site, `ResultsModel` resolves density from the material name via the
**bundled materials.json** (`MaterialDensityTable`, a dependency-free Foundation read,
cached) when a density isn't passed explicitly. So production gets the real density
with **no `WorkspacePlaceholder` change**; tests inject density directly. An explicit
`materialDensityGCm3:` parameter is already threaded through both inits, so whoever
next touches `WorkspacePlaceholder` can pass
`model.densityGCm3(for: project.material)` for directness (optional — it already
works). In a headless unit bundle there's no materials.json, so the lookup returns 0
and the mass comparison hides — which is why the tests inject density.

## Remote parity

Remote variants export identically (mesh buffers are local). For a remote run the
**voxel** mass isn't serialised (097), so the comparison shows the mesh mass alone
(computed app-side) and never a stale voxel number — the caption stays hidden unless
the mesh is non-watertight.

## Evidence / honest limitations

- **Numerics validated independently** (Python, no framework): unit cube volume =
  1.0 & watertight; 2×1×1 box = 2.0; two disjoint unit cubes = 2.0; 20 mm cube =
  8000 mm³ = 8 cm³ → 9.92 g @ 1.24 g/cm³; reversed winding = 1.0; open mesh not
  watertight; 12-triangle STL = 684 bytes (80+4+12·50). These match the test
  expectations exactly.
- **`xcodebuild` NOT run here.** This session's container is Linux; the `/app/`
  Swift package requires macOS + Xcode (Metal, the C++/OCCT bridge, Apple `simd`),
  and Linux CI covers only the C++ core (per the package header + ROADMAP M7 rules).
  A maintainer must run, on macOS:
  `xcodebuild test -scheme TopOptKit -destination 'platform=macOS'` (or the repo's
  usual app scheme) and paste raw output — expecting `MeshExportTests` and
  `ResultsExportTests` green alongside the existing suite. **Not fabricated.**
- **Device QA:** the share-sheet flow (AirDrop/Files/Mail), the disabled-button
  pixels, and opening the exported `.stl` in a slicer/CAD viewer are device/desktop
  QA — described, not claimed. The bytes/filename/volume/mass are what's headlessly
  tested.

## Coordination

- Handoff number **105** (first free ≥ 105 on `main`, which tops out at 104). The
  repo already carries parallel same-number handoffs, so a sibling using 105 with a
  different suffix won't conflict.
- Touched only the task's territory: `MeshExport.swift` (new), `ResultsModel.swift`,
  `ResultsScreen.swift`, tests, plus a one-line delegation in `RemoteRunner.swift`
  (its private STL parser now calls `MeshExport.parseBinarySTL`). Did **not** touch
  `MetalMeshView` / `WorkspacePlaceholder` / `ClearanceGeometry` / `OrientationGizmo*`.
  `OutcomeStore.swift` needed no change — it already persists the mesh buffers export
  reads, so reopened projects export too.
