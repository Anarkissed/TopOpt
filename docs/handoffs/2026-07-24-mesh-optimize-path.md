# 2026-07-24 — Optimize a MESH part (STL/3MF), not only STEP

**Track:** core `io/` + `cli/`. **Territory:** `core/include/topopt/step.hpp`,
`core/src/io/face_tag.cpp`, `core/src/cli/run_job.cpp`, `core/CMakeLists.txt`,
`core/tests/`. **No solver change, no optimizer change, no bridge/app change.**

**Gates (all green):**
* full `ctest` **66/66**, 273 s — `evidence/2026-07-24-mesh-optimize-path/ctest_raw.txt`
* STEP byte-identity: the demo L-bracket run is identical before/after (report +
  all three variant STLs + fields.bin), and `cli_demo` + `production_parity`
  (the end-to-end STEP gates) are untouched and green —
  `evidence/.../step_byte_identity.txt`
* new `mesh_job` ctest, 48 checks, 7.8 s — the equivalence table + the
  end-to-end mesh run

---

## 0. What was actually wrong

Handoff 134 made an STL/3MF part **selectable**: it imports, segments into
pseudo-faces, and every tap resolves to a face id. But the last mile was still
STEP-locked. `run_job` — the one function the CLI and the LAN worker call to
actually optimize — opened the part with a hardcoded `import_step_file()`
(`run_job.cpp:228`). So an STL part selected fine in the app and then **died at
Optimize** with the core's "not a readable STEP file", because the front door
only knew how to read STEP.

Everything *behind* that door was already mesh-based. The pipeline is typed on
`StepModel` + `face_id`, `voxelize()` takes a `TriangleMesh`, and `tag_step_face`
/ `mask_step_face` read only `StepModel::triangle_face` + the grid (handoff 134
moved them out of the OCCT-gated `step.cpp` for exactly this reason). **The spine
was mesh-ready; only the front door and the (cosmetic) tag-call naming weren't.**

## 1. The one format-aware line

`run_job` now imports through `import_part_file()` (the handoff-134 adapter),
which dispatches on the extension:

```
.step/.stp  ──OCCT B-rep──────────────▶  StepModel   (REAL faces, UNCHANGED path)
.stl / .3mf ──read + repair + segment──▶  StepModel   (PSEUDO-faces)
```

`import_part_file(<step>)` forwards to `import_step_file(path, {})` verbatim, so
the STEP path is byte-for-byte what it always was — **proved** two ways:
`import_part_file(<step>)` deep-equals `import_step_file(<step>)` (section A of
the new test), and the demo run's report + meshes + fields are bit-identical
before/after (`step_byte_identity.txt`).

A `PartError` (unreadable file, unavailable format, or a Phase-1 **mesh refusal**
— non-manifold / open / non-orientable / zero-thickness) is caught and re-raised
as the `JobError` `run_job` documents, carrying the core's own plain-language
reason. The existing watertight check is kept as a belt-and-suspenders guard (a
mesh that reached it already passed the open-boundary refusal).

## 2. Face tags: `tag_mesh_face`, a forwarder, not a fork

The task asked for a `tag_mesh_face` parallel to `tag_step_face` that tags voxels
from the mesh's per-triangle pseudo-face ids. The honest finding: **that is
already exactly what `tag_step_face` does** — it selects the voxels against the
triangles carrying a given `triangle_face` id, and for a mesh import those ids
*are* the pseudo-face ids. A second copy would be 40 duplicated lines.

So the shared scan was extracted into `tag_face_impl`, and **both** public names
(`tag_step_face`, `tag_mesh_face`) forward to it — zero logic duplicated, and a
mesh-source call site now reads honestly. `run_job`'s self-weight path picks the
name by source (`model_is_mesh ? tag_mesh_face : tag_step_face`); the result is
identical, the name is truthful. The load-case / clearance / protect paths go
through `build_production_loadcase`, which already calls `tag_step_face` /
`mask_step_face` on the source-agnostic model — no change needed, and handoff
134 already link-proved that whole path runs OCCT-free.

## 3. `resolve_selectors` on a mesh — stated, not branched

The geometric selector (`{"cylindrical", radius_mm}`) is **unchanged** and needs
no mesh branch. It matches on `StepFaceInfo::kind == Cylinder` and the **fitted**
radius the segmenter produced; a mesh has no B-rep, so the fitted radius *is* the
exact radius for the geometry supplied, compared under the same
`kJobFaceRadiusToleranceMm` (1e-6 mm). The honest consequence, documented at the
function and pinned by the test: a bore whose fit lands outside that 1e-6 window
matches **nothing** and the selector **refuses** with the existing "matched no
face of the model" message — it never silently falls back to a raw index or a
fuzzy match. The demo L-bracket exported to STL fits its r=2.5 bore to
2.500000112 mm (1.1e-7 error, inside tolerance), and the plate fixture fits r=3.0
to 2.99999998 mm — both match. A hand-authored mesh job that wants a specific
bore should give a radius the fit achieves, or select by **raw face id** via the
loads block (`anchor_face_ids` / `face_ids`), the form the app's tap already
produces for both sources.

## 4. Equivalence, measured through voxelization + tagging

`segment_vs_step` (134) proved the pseudo-face **structure** matches the B-rep.
This extends that the rest of the way to the grid the optimizer solves on. Export
the demo L-bracket STEP → STL, voxelize both, tag both bores:

```
 res | grid       |  solid | solid-diff | tag(step) tag(mesh)  jacc
  16 | 16x11x16   |    656 |     0      |    12       12       1.000
  24 | 24x16x24   |   2142 |     0      |    18       18       1.000
  32 | 32x22x32   |   4992 |     0      |    32       32       1.000
  48 | 48x32x48   |  17112 |     0      |    48       48       1.000
  64 | 64x43x64   |  45648 |     0      |   153      153       1.000
```

**Identical solid set (0 diff) and identical fixture-tag set (Jaccard 1.000) at
every resolution.** The STL is the STEP's own tessellation, so voxelization sees
the same triangles — the equivalence is exact, not approximate.

## 5. A mesh job, end to end

`tests/fixtures/mesh/plate_bore.stl` (a committed 24×16×4 mm plate with a central
r=3 bore, 7 pseudo-faces) runs `run_job` in-process: import → segment → voxelize
→ tag the bore as FIXTURE → self-weight ladder → gate → **report + variants +
fields**, structurally identical to a STEP job (`mesh_job_report.json`). Two
variants accepted, each with a finite positive margin. Determinism: same STL
bytes → byte-identical report + variant meshes + pseudo-face ids, twice-run
(asserted).

### One resolution caveat, found and pinned

At res 24 the r=3 bore aliases *off* the grid — the nearest solid voxels sit
~0.54 voxels from the bore wall, just past the half-voxel tag threshold, so the
selector matches the face but tags **0** voxels and `run_job` raises its existing
"resolution too coarse for the selected faces" error. res 32 tags 50. The test
uses 32 and its comment records why. This is not a mesh bug — it is the same
half-voxel selection rule STEP uses, meeting a small feature at a coarse grid.

## 6. Files

**New:**
* `core/tests/validation/test_mesh_job.cpp` — the three-section gate (A
  identity, B equivalence table, C end-to-end + determinism).
* `core/tests/fixtures/mesh/plate_bore.stl` — the small committed mesh job.

**Modified:**
* `core/src/cli/run_job.cpp` — format dispatch at the front door (`+part.hpp`,
  `import_part_file`, `PartError`→`JobError`), source-appropriate tag call,
  `resolve_selectors` mesh doc.
* `core/src/io/face_tag.cpp` — `tag_face_impl` shared body; `tag_step_face` +
  `tag_mesh_face` forwarders.
* `core/include/topopt/step.hpp` — `tag_mesh_face` declaration.
* `core/CMakeLists.txt` — the `mesh_job` test (OCCT+Eigen block).

## 7. Scope honesty

* **3MF is code-complete but unexercised here** — same as handoff 134: lib3mf is
  not installed in this environment, so `import_part_file` on a `.3mf` compiles
  and dispatches (`read_3mf_file` + weld + segment) but was never run. The STL
  path is the one exercised end to end. The dispatch is format-symmetric, so 3MF
  should follow once run on a lib3mf machine — treat as untested until then.
* **`run_job` stays in the OCCT+Eigen CMake block.** It is the desktop/CI/worker
  driver, which always has OCCT; a mesh job flows through it there. Meshes on the
  OCCT-free iOS slices go through the bridge's load-case path, which handoff 134
  already made OCCT-free and link-proved. Moving `run_job` itself off OCCT was
  not needed for this task and was not attempted.
* **No app/bridge change.** The job schema needed no format hint — dispatch is by
  the `model` path's extension, which the app already sets to `model.<ext>`
  (`ProjectModel.snapshot`) and the worker preserves (`topopt_worker._create_job`).
