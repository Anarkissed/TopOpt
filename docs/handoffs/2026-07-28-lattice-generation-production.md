# Lattice generation: harness → production

**Date:** 2026-07-28
**Branch:** claude/lattice-generation-production-751116
**Status:** BUILT. All six bars (P1–P6) met with numbers below.

## What shipped

The octet strut generator that PR 201 measured in
`core/tests/harness/octet_gen_probe.cpp` — and a physical print certified — is now
a production component wired into the job export path. A job that declares a
`lattice` block emits, **alongside** each accepted variant's solid mesh, a
**latticed variant**: the solid shell unioned with an octet lattice filling the
part's solid interior, streamed to disk as STL and/or 3MF. Generation runs
wherever `run_job` runs — the Mac worker's `topopt-cli` — and the file is served
as an ordinary `out_dir` artifact, so the iPad fetches it on demand and never
holds the mesh.

**Not built (held, by instruction):** the grading LAW. The generator ACCEPTS a
radius/density field (`LatticeRadiusField::field`); how that field is derived from
stress is a separate task, held until the certifiable density band is measured.
The job front-end ships a uniform radius and records the posture it implies.

## Files

New:
- `core/include/topopt/lattice_gen.hpp`, `core/src/mesh/lattice_gen.cpp` — the
  production octet generator. Ported operation-for-operation from the harness
  (same node/strut tables, cell-local ownership, swept-solid strut, icosahedral
  node, fixed traversal). Emits to a `TriangleSink`; accepts uniform radius or an
  external field.
- `core/include/topopt/threemf_stream.hpp`, `core/src/io/threemf_stream.cpp` — a
  self-contained **streaming** 3MF writer (temp-file model XML + minimal
  stored-zip OPC + incremental CRC-32). No lib3mf dependency, always built.
- `core/tests/unit/test_lattice_gen.cpp` — golden reproduction + determinism +
  streaming-equivalence + external field + manifoldness.

Changed:
- `core/include/topopt/mesh.hpp` — `TriangleSink` / `MeshSink` interfaces.
- `core/include/topopt/stl.hpp`, `core/src/io/stl.cpp` — `StreamingStlWriter`
  (byte-identical to `write_stl_file(Binary)` fed the same soup).
- `core/include/topopt/job.hpp`, `core/src/cli/job.cpp` — optional `lattice`
  block (topology / cell_mm / strut_radius_mm / emit_stl / emit_3mf).
- `core/src/cli/run_job.cpp` — `export_latticed_variant` + wiring into the
  streaming and batch export paths + a `LATTICE …` checkpoint line.
- `core/include/topopt/observability.hpp`, `core/src/simp/observability.cpp` —
  `lattice_export` run_info posture (emitted only when a lattice was generated).
- `core/src/cli/main.cpp` — count accepted VARIANTS, not mesh files, in the
  summary (a latticed run writes extra companion meshes per variant).
- `core/tests/unit/test_job.cpp` — lattice-block schema tests.
- `core/CMakeLists.txt` — new sources + `test_lattice_gen`.

## Design: why streaming survives (BLOCKED-STOP)

Peak RSS is flat in output size because the generator holds no global state:
cell-local ownership (integer half-coordinate keying) emits each strut/node from
exactly one cell, so a single fixed-order sweep pushes triangles to a sink with
O(1) live memory. The two production writers (`write_stl_file`, `write_3mf_file`)
buffer the whole mesh; re-using them would have silently reintroduced the memory
wall, so both got a streaming counterpart instead:

- **STL** streams natively (header count patched by seek-back at `finish()`).
- **3MF** cannot stream through lib3mf (PR 201 confirmed). Rather than buffer, the
  streaming 3MF writer streams the model XML to a **temp file on disk** (flat RAM,
  incremental CRC-32), then packages it as a STORED zip entry whose CRC/size are
  known before its local header — no data descriptor, maximal reader
  compatibility. Disk cost, not memory cost. The trade-off: a stored 3MF is
  uncompressed, so larger than a lib3mf-deflated one; the STL is the compact
  streaming artifact and the named deliverable.

## Bars

**P1 — LATTICE OFF IS BYTE-IDENTICAL.** No-lattice job vs lattice job, same binary,
same solve. Solid `variant_060.stl`, `report.json`, `fields.bin`: byte-identical
(`cmp`). `iterations.csv`: identical but the `wall_ms` timestamp column.
`run_info.json`: identical but the added `lattice_export` key and `created_wall_ms`
(a wall stamp that varies run-to-run regardless). Every physics/config value
equal. See `evidence/.../P1_byte_identical.txt`. Structurally, all lattice code is
guarded by `job.lattice.present` and the serializer writes no `lattice_export` key
when absent.

**P2 — STREAMING HOLDS IN PRODUCTION.** `rss_probe` streams a full N³ block; one
process per size so `ru_maxrss` is its own peak (`evidence/.../rss_sweep.csv`):

| N  | STL size  | peak RSS | 3MF size  | peak RSS |
|----|-----------|----------|-----------|----------|
| 7  | 15.8 MB   | 1.5 MB   | 71.5 MB   | 1.6 MB   |
| 14 | **121 MB**| 1.5 MB   | 560 MB    | 1.5 MB   |
| 22 | 464 MB    | 1.5 MB   | **2.19 GB** | 1.5 MB |

STL output spans 15.8 MB → 464 MB (29×) and 3MF → 2.19 GB, all at a **flat 1.5 MB
peak RSS**. It is flat. Output is a disk cost, not a memory cost.

**P3 — DETERMINISM.** Same inputs twice → byte-identical file, at the generator
level (`test_lattice_gen` `det_a`==`det_b`) and end-to-end (the CLI lattice STL and
3MF are byte-identical across two full runs).

**P4 — UNION IS THE SLICER-ACCEPTED SOUP.** The lattice unions with the shell as an
interpenetrating triangle soup (three fresh vertices per facet — same as the STL
body and the harness). Manifoldness, regression-visible:
- Pinned in `test_lattice_gen` (welded 2×2×2 block): boundary_edges 0,
  non_manifold_edges 2238, components 78, watertight NO.
- The end-to-end deliverable (`variant_060_lattice.stl`, 151,384 tris): welded
  52,540 verts, **boundary_edges 0** (every primitive closed), **non_manifold_edges
  41,732** (the interpenetrating junctions). No open holes; overlaps the slicer's
  boolean union resolves — exactly what the PR 201 print certified.

**P5 — END TO END.** `evidence/.../out_lattice/variant_060_lattice.stl` is a real
job's latticed STL — a valid binary STL (header + 151,384 facets, exact byte size)
the maintainer can open in a slicer. **That file is the deliverable.** The
companion 3MF (regenerable from `job_lattice.json`) opens as a valid OPC package
(zip CRC check passes, 151,384 triangles).

**P6 — GENERATION WALL-TIME FRACTION.** run_info `lattice_export`: `gen_seconds`
0.647 s (STL + 3MF, one variant, 148,896 lattice triangles), `gen_fraction`
**14.0%** of this job. CAVEAT, stated plainly: this job is a deliberately tiny
10-iteration / single-rung solve (~4.6 s total) to keep the harness fast, so the
fraction is inflated. Absolute generation time is <1 s per variant; against any
production multi-minute solve it is a fraction of a percent. The RSS probe shows
raw throughput: 316 k triangles streamed to STL in 0.081 s.

## Worker-side (item 3)

`run_job` (= the Mac worker's `topopt-cli`) does the generation; the streaming path
prints a machine-parseable `LATTICE vf=… mesh=…` checkpoint per file, and the file
lands in `out_dir`. The Python worker (`tools/topopt-worker/topopt_worker.py`)
already lists and serves every `out_dir` artifact by name (the `done` event +
`/jobs/{id}/files/{n}`), so it needs **no change** to surface the latticed mesh —
the iPad fetches the file on demand and never holds the mesh. The iPad's on-device
path simply never populates the `lattice` block.

## Reproduce

```
# unit tests
cd core/build && cmake --build . --target test_lattice_gen test_job && ./test_lattice_gen && ./test_job

# end-to-end (P1 baseline + lattice), from repo root
core/build/topopt-cli run evidence/2026-07-28-lattice-generation-production/job_nolattice.json --out /tmp/nl
core/build/topopt-cli run evidence/2026-07-28-lattice-generation-production/job_lattice.json  --out /tmp/lat

# streaming RSS sweep (P2)
sh evidence/2026-07-28-lattice-generation-production/build_rss_probe.sh
evidence/2026-07-28-lattice-generation-production/rss_probe 14 8 0.8 /tmp/block.stl 3mf
```

## Follow-ups (out of scope here)

- The grading LAW (stress → density field). The generator already carries the
  field; only the derivation is missing. See [[lattice-homog-phase0-built]] /
  [[knockdown-member-scale-governs]] for the certifiable-band prerequisite.
- App UI to request a lattice (cell size / radius / region). The core + CLI + job
  schema + worker are ready; the front-end is a separate task like the grading law.
- If a stored 3MF's size matters, add streaming DEFLATE (zlib) to the 3MF writer.
