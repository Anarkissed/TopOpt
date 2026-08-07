# S1(c) — every consumer of the lattice triangles, with file:line

The artefact under audit is `variant_XXX_lattice.stl` (and its `.3mf` twin): the
interpenetrating triangle soup core writes for a latticed variant. It is produced
**streaming** — it never exists as an in-memory mesh in core.
`export_latticed_variant` (`core/src/cli/run_job.cpp:970`) pushes three
populations into one `TriangleSink`:

| population | site | re-derivable from? |
|---|---|---|
| the solid shell (`variant.v3.mesh`) | `run_job.cpp:1059` | marching cubes over the design density |
| the kept-solid companion body | `run_job.cpp:1093` | marching cubes over the design density ∧ ¬cert-mask |
| the strut soup | `run_job.cpp:1122` | topology + cell plan + per-cell ρ + the boundary |

and the sink is `StreamingStlWriter` (`run_job.cpp:1155`) or
`StreamingThreeMfWriter` (`run_job.cpp:1163`).

**"Reads triangles?"** below means: does this consumer read the triangle data of
the emitted lattice file. **"Description suffices?"** means: would
{topology, cell plan, per-cell relative density, occupancy, the design density
field, the job's lattice block} answer the same question.

---

## A · core/

| # | consumer | file:line | reads triangles? | description suffices? | note |
|---|---|---|---|---|---|
| A1 | `StreamingStlWriter` | `run_job.cpp:1155`, `core/src/io/stl.cpp:267` | **yes — it IS the triangles** | n/a | the terminal writer; flat RSS, cost is disk |
| A2 | `StreamingThreeMfWriter` | `run_job.cpp:1163` | **yes** | n/a | same, OPC/zip |
| A3 | `RotatingTriangleSink` (bake build frame) | `core/include/topopt/build_frame.hpp:139`; call `run_job.cpp:1148` | yes (per-triangle map) | **yes** — the same rigid motion applies to a cell grid | pure pass-through wrapper |
| A4 | `LatticeGenStats` counters | `core/include/topopt/lattice_gen.hpp:144`; accumulated across `core/src/mesh/lattice_gen.cpp` | **no** — emitted *by* the generator, never read back | **yes** | triangles/struts/nodes/clipped/landings |
| A5 | emitted-solid volume (`interior_/skin_/rim_volume_mm3`) | `lattice_gen.cpp:892, 938, 478, 663, 777` | **no** — analytic per-primitive sums | **yes** | closed form of topology + cell + ρ |
| A6 | "skin produced nothing" refusal | `run_job.cpp:3283` | **no** — reads `stats.rim_triangles + skin_triangles` | **yes** | a guard on counters, not on the file |
| A7 | lattice certification (`certify_latticed_variant`) | `run_job.cpp:1346`; posture built at `run_job.cpp:1199` | **NO — voxel grid only** | **yes** | ★ see "the recipe already exists" below |
| A8 | `analyze_fixed_design` (the certifier itself) | `core/include/topopt/analyze.hpp:306` | **no mesh parameter exists** | **yes** | takes `VoxelGrid` + `density[]` + `LatticePosture*` |
| A9 | V3 suite — watertight / single-component / min-feature | `core/src/simp/analyze.cpp:389` → `check_v3`; `core/src/voxel/voxelize.cpp:428` | **no** — runs on the SOLID isosurface, never the strut soup | **yes** | `V3Report.mesh` is the density isosurface |
| A10 | mass | `core/src/simp/analyze.cpp:368` | **no** — voxel count × spacing³ × density | **yes** | |
| A11 | enclosed-void rule (void reaches exterior) | `core/src/mesh/lattice_void.cpp` (**zero** `TriangleMesh` references); call `run_job.cpp:2986` | **NO** — 6-connected flood fill on the voxel classification | **yes** | its own header says it "is NOT a claim about the EXPORTED MESH" |
| A12 | strut-strength report | `core/src/simp/analyze.cpp:434`; `core/src/fea/strut_strength.cpp` (**zero** `TriangleMesh`) | **no** — octet strut law on per-cell ρ | **yes** | |
| A13 | build-orientation strut-axis probe | `core/src/orient/build_orientation.cpp:79` (`DiscardSink`), `:83–127` | **explicitly discards every triangle** | **yes** | axes are a topology property |
| A14 | per-variant lattice receipt JSON | `run_job.cpp:1609` | **no** | **yes** | every field from stats + voxels |
| A15 | `shell_enclosed_volume_mm3` in the receipt | `run_job.cpp:1651` | reads `variant.v3.mesh` — the **solid shell**, not the struts | **yes** | only for non-default `outer_finish` |
| A16 | `LATTICE …` stdout checkpoint | `run_job.cpp:7386, 7399` | **no** — prints `mesh=<path>` | **yes** | |
| A17 | `mesh_paths` bookkeeping | `run_job.cpp:5518, 7378` | **no** — filenames only | **yes** | |
| A17b | `lattice_variant.json` provenance `"meshes"` array | `run_job.cpp:5721-5724` | **no** — `base_name()` of each path | **yes** | written by the re-lattice entry point; the app reads it at `RelatticeRunner.swift:468` |
| A18 | smoothing / resample / CAD-face projection | `run_job.cpp:314` (`export_variant_mesh`), `core/src/mesh/smooth.cpp`, `surface_operator.cpp`, `cad_project.cpp` | **never touch the lattice file** — solid variant mesh only | n/a | |
| A19 | STL re-import (`read_stl_file` / `import_stl_file`) | `core/src/io/stl.cpp:134, 148`; sole production caller `core/src/io/part.cpp:51` | reads triangles of the **INPUT part** only | n/a | **nothing in core re-imports the lattice it wrote** |
| A20 | `analyze --mesh PATH` | `core/src/cli/main.cpp:120`; `run_job.cpp:4669` | would read whatever mesh you hand it | n/a | hypothetical: no code path feeds it a lattice file, and the app refuses to route a latticed variant here (B12) |

**Core verdict: the only consumer of the triangles in core is the writer.**
Everything core asserts about a lattice — the certified margin, the mass, the
strut-strength envelope, the void-escape rule, the min-feature count, the
watertight and single-component gates — is computed on the voxel grid or on the
solid isosurface, *before* a single triangle is written.

### ★ The recipe already exists, in memory, one function above the writer

`build_lattice_posture` (`core/src/cli/run_job.cpp:1199`) constructs exactly
`{topology, cell_size_mm, occupancy mask, per-voxel relative density}` — the
compact description this task is asking about. It is built, handed to the
certifier, and dropped, while the expansion is written to disk. And its
persistent form is already written too: `design.bin`
(`core/include/topopt/design_store.hpp:46`) carries the per-voxel density field
the whole thing derives from, because the generator's boundary is
`LatticeBoundary::set_voxel_base(grid, density, iso, window)`
(`core/include/topopt/lattice_boundary.hpp:100`).

---

## B · app/

| # | consumer | file:line | reads triangles? | description suffices? | note |
|---|---|---|---|---|---|
| B1 | **LAN re-lattice result fetch** | `RelatticeRunner.swift:457` (fetch), `:462` (`parseBinarySTL`) | **YES — the only place the app pulls the lattice mesh** | **yes** | 3MF is never fetched |
| B2 | → variant mesh buffers | `RelatticeRunner.swift:489` | yes | yes | everything below feeds off these buffers |
| B3 | results viewer mesh build | `ResultsModel.swift:1317`; `ViewerMesh.swift:236` | **yes** | **drawing — one of the two legitimate needs** | smooth normals + unshared flat soup |
| B4 | Metal renderer draw | `MetalMeshView.swift:2528`; `ResultsScreen.swift:515` | **yes** | (drawing) | |
| B5 | **export / share sheet STL** | `ResultsModel.swift:1204` (`exportSTLData`) | **YES** | **NO — the slicer needs a triangle soup** | ★ re-serialises the *local* buffers; see the coupling note |
| B6 | export mesh volume | `ResultsModel.swift:1213` → `MeshExport.meshVolume` | **yes**, over the strut soup | **yes** — core already ships analytic `interior_volume_mm3` in the receipt | divergence theorem over ~10⁵–10⁶ tris |
| B7 | export watertight check | `ResultsModel.swift:1222` → `MeshExport.isWatertight` | **yes**, over the strut soup | **yes** | ★ structurally wrong today — see below |
| B8 | mass comparison (mesh vs voxel) | `ResultsModel.swift:1236` | yes (via B6/B7) | **yes** | |
| B9 | stress tint / flex sampling | `ResultsScreen.swift:460`; `ResultsModel.swift:1443` | yes — samples the field per flat vertex | **yes** | O(struts) today; implicit would shade per pixel |
| B10 | **results persistence** (`results.plist`) | `OutcomeStore.swift:208` (encode), `:291` (decode); `ProjectStore.swift:125` | **yes — the whole soup is packed into the project blob** | **yes** | the largest single win |
| B11 | re-lattice sidecar artifacts | `ProjectStore.swift:163`; `LatticeVariantSession.swift:50` | **no — `job.json` + `design.bin` only** | **already a description** | ★ the mesh is deliberately *not* persisted here |
| B12 | smoothing page | `SmoothingVariantSession.swift:181` (`.alreadyLatticed`) | **REFUSES latticed variants** | n/a | "smoothing it would round the struts" |
| B13 | LAN optimize-run mesh download | `RemoteRunner.swift:910` (`fetchMesh`), call `:1301` | reads the **SOLID** `variant_XXX.stl` — **never the lattice file** | n/a | a lattice-mode LAN run shows the solid mesh + receipt numbers |
| B14 | LAN lattice receipt fetch | `RemoteRunner.swift:1039` | **no** | **yes** | already the compact-description channel |
| B15 | `design.bin` fetch | `RemoteRunner.swift:973` (`fetchDesign`) | **no** | **already a description** | ★ the recipe's dominant term already crosses the wire |
| B16 | **lattice raymarch preview** | `LatticeSDFMetal.swift:1–27` | **NO — "ZERO lattice triangles on the device"** | **it already IS the description** | analytic SDF, sphere-traced per pixel |
| B17 | lattice density proxy (surface tints) | `LatticeProxyModel.swift:33` | **no** — per-vertex tints on the solid surface | **yes** | |
| B18 | lattice sample-patch thumbnail | `LatticeProxyModel.swift:55` | generates its own few-thousand triangles on device | **already a description** | not a consumer of the emitted file |

---

## C · tools/

| # | consumer | file:line | reads triangles? | description suffices? | note |
|---|---|---|---|---|---|
| C1 | worker artifact serving | `tools/topopt-worker/topopt_worker.py:955` (`_file`), `:938` (`_file_from_disk`) | **no — opaque byte pass-through** | **yes** | |
| C2 | worker result zip | `topopt_worker.py:922` | **no** | **yes** | zips the whole `out/` dir |
| C3 | worker `done` artifact list | `topopt_worker.py:593` | filenames only | **yes** | |
| C4 | webhook "N variants ready" | `topopt_worker.py:305` | counts `.stl/.3mf/.obj` **filenames** | **yes** | counts the lattice file as a separate variant — a pre-existing cosmetic miscount |
| C5 | worker `VARIANT` line parse | `topopt_worker.py:248` | forwards the **solid** mesh basename | **yes** | `LATTICE …` lines fall through as generic log lines |
| C6 | `tools/TopOptWorkerApp` | — | **nothing** | n/a | supervisor/menu-bar GUI, no mesh handling |
| C7 | worker disk retention | — | — | — | ★ **there is no `out/` cleanup.** The only `shutil.rmtree` calls (`:810`, `:826`) are on the upload staging tmpdir; `worker.log` has rotation, `out/` has none. Every byte written stays until deleted by hand. |

---

## D · tests that touch the emitted lattice file

Relevant because they are the work item any deferral creates.

| test | file:line | what it does |
|---|---|---|
| graded byte-identity | `core/tests/validation/test_lattice_hookup.cpp:461–468` | `read_file(mesh1) == read_file(mesh2)` — **opaque bytes, never parsed** |
| graded receipt identity | `test_lattice_hookup.cpp:366` | receipt JSON string compare |
| design-box re-cert | `core/tests/validation/test_designbox_lattice_recert.cpp:234` | `std::filesystem::exists` only |

`grep -rn "_lattice.stl" core/tests` returns **one** hit (the existence check).
No core test parses lattice triangles. On the app side
`app/TopOptKit/Tests/**` calls `parseBinarySTL` in
`MeshExportTests.swift:36`, `ResultsExportTests.swift:93`,
`ViewerProfileTests.swift:66,104`, `ViewerRebuildProfileTests.swift:57,85` —
against *fixture* meshes, not an emitted lattice file.

---

## The two couplings that decide the scope

**★ B5 — export is fed by the app's own buffers, not by the worker.**
`canExport` (`ResultsModel.swift:1158`) is literally
`!v.meshVertices.isEmpty && v.meshIndices.count >= 3`, and `exportSTLData()`
re-serialises those buffers. So "the worker keeps the description and writes
triangles only on export" does **not** by itself preserve export: the app would
have nothing to serialise. Export survives deferral only if the app either
(i) asks the worker to materialise (a `lattice_variant` job — the mechanism
already ships, `core/src/cli/run_job.cpp:5049`, `topopt-cli lattice-variant`),
which needs the worker reachable at export time, or (ii) tessellates locally at
print detail, which is the PR 184 ceiling (~2.8 GB of GPU buffers for a full
fine lattice, over the iOS per-app limit — `docs/handoffs/2026-07-29-lattice-preview.md:21`).

**★ B7 — the watertight check is asking the wrong question today.**
Core writes the lattice deliberately as an unshared, interpenetrating soup (that
is what the slicer accepts), so `MeshExport.isWatertight` returns false and the
UI labels the mass an ESTIMATE — for a file that is correct by design. A
description-based mass (core's analytic `interior_volume_mm3 + skin_volume_mm3 +
rim_volume_mm3 + solid_region_volume_mm3`, all already in the receipt) would be
both cheaper and more honest. Pre-existing; noted, not fixed here.

---

## The exhaustiveness check (bar R3)

The lattice file is named in exactly one place — `lattice_base_name`
(`core/src/cli/run_job.cpp:396`) — so every consumer must either name the
`_lattice.stl` / `_lattice.3mf` suffix or receive the path as a string from
`oc.paths`. Both were swept:

```
$ grep -rn "_lattice\.stl\|_lattice\.3mf" . | grep -v "^\./evidence/\|^\./docs/\|^\./\.git/"
core/include/topopt/job.hpp:186        bool emit_stl = true;   // write <prefix>_<vf>_lattice.stl
core/include/topopt/job.hpp:187        bool emit_3mf = false;  // write <prefix>_<vf>_lattice.3mf (streaming)
core/tests/validation/test_designbox_lattice_recert.cpp:234   CHECK(std::filesystem::exists(...))
app/TopOptKit/Sources/TopOptFlows/RelatticeRunner.swift:457    guard let meshData = file("variant_\(vfTag)_lattice.stl")
```

**Four hits in the entire repository outside `evidence/` and `docs/`: two flag
declarations, one existence assertion, and one app fetch.** The path-as-string
route is `oc.paths`, swept separately — `run_job.cpp:1159, 1166` (push),
`:5518, 7378, 7380` (record and print), and nothing else.

`ci/`, `Testing/` and `tools/` contain no reference: the worker serves artifacts
by name as opaque bytes (rows C1–C3) and never distinguishes this file from any
other.

## Where this enumeration stops

- **`docs/`, `evidence/`, `ci/`, `Testing/`** — grepped for filename references
  only, not audited as consumers.
- **The MSL shader source** behind `LatticeSDFMetal.swift` was not read line by
  line; the Swift-side uniforms and the file header are unambiguous that no
  triangle buffer exists on that path.
- **`app/TopOpt/`** (the shell target outside TopOptKit) — grepped for `.stl`
  and `lattice`; no hits beyond the table.
- Third-party slicers are out of scope by definition: they are the one consumer
  that genuinely needs geometry, and they are the last step.

## The answer to the maintainer's question

**Nothing between the worker and the screen requires the triangles except
(a) drawing and (b) slicer export.** Certification never sees the mesh (A7, A8);
the void rule never sees the mesh (A11); nothing in core re-imports what it wrote
(A19); and the app's *preview* is already implicit with zero triangles (B16).
