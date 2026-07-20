# 122 — Serialize the full result fields over the LAN

Builds on **097** (LAN offload Tier 2, which introduced the `computedRemotely` "n/a
— computed on Mac" gap), **101** (remote-run liveness), and **108/111** (the persist
honesty invariants). Territory: `core/src/io/fields.{hpp,cpp}` + `run_job.cpp` (one
additive output), `tools/topopt-worker` (serve it — no protocol change),
`RemoteRunner.swift` / `RemoteFields.swift` / `ResultsModel.swift` /
`OutcomeStore.swift` (fetch / parse / wire / persist), + tests.

Handoff number: **122** — highest in `docs/handoffs/` was 121 (two lanes collided on
121, one interaction-visual, one worker), so the first free is 122.

## The gap this closes

A LAN remote run received each variant's **mesh** + the scalar `report.json`, but NOT
the per-voxel arrays the results overlays consume. So on a Mac-computed variant the
**Stress**, **Flex**, and **Load-path** overlays and the **voxel mass** all rendered
"n/a — computed on Mac" (097). This handoff serialises those arrays over the wire so a
remote run lights up the same overlays a local run does.

---

## 1. CORE/CLI — `out/fields.bin` (the one additive output)

New `write_fields_file()` in `core/src/io/fields.cpp` (declared in
`core/include/topopt/fields.hpp`), called from `run_job` after the report/meshes are
written (both the batch and streaming paths, from `result.pipeline.evaluated`). Added
`fields_path` + `fields_variant_count` to `RunJobResult`. The writer is pure
C++/std (no Eigen/OCCT), in the always-built `topopt` library.

**Format `fields.bin` v1** — all little-endian, **version byte first** (the schema
WILL evolve; a reader MUST check it). One run-level header (the solved grid every
field indexes to) + one block per **accepted** variant:

```
run header
  u8   version = 1
  u8   reserved[3]
  i32  grid_nx, grid_ny, grid_nz          solved-grid dims
  f64  grid_origin_x/y/z                   solved-grid min corner (mm)
  f64  spacing                             cubic voxel edge (mm)
  f64  voxel_volume_mm3
  i32  variant_count
  i32  reserved
per accepted variant
  f64  requested_volume_fraction           ladder rung — the app's join key
  f64  mass_grams                          scalar summary
  i32  support_volume_voxels               scalar summary
  i32  reserved
  i64  von_mises_count       (= voxel_count)
  i64  stress_tensor_count   (= 0 in v1 — see below)
  i64  displacement_count    (= 3·(nx+1)(ny+1)(nz+1))
  f32[von_mises_count]       per-voxel von Mises (MPa), grid-indexed
  f32[stress_tensor_count]   per-voxel Cauchy tensor, Voigt (empty in v1)
  f32[displacement_count]    per-node displacement (mm), DOF-ordered
```

The three arrays are stored as **float32** — the same narrowing the bridge applies
locally (`OptimizeVariant` carries `std::vector<float>`), so the wire bytes are
identical to what the app consumes locally, not an approximation. Only **accepted**
variants are serialised (a cancelled/rejected rung's fields are default-constructed).
The writer throws `FieldsError` if an accepted variant's field sizes disagree with the
grid (fail loud, never ship a container the app would misindex).

**"displacement magnitude"** (the task's wording) is served as the full 3-component
`displacement_field` — the flex animation and the load-path derivation both need the
vector, not just the magnitude, and it's the same array the bridge hands the app.

### Size honesty (at 128³)

| array | bytes/variant |
|---|---|
| von Mises (`128³·4`) | 8.39 MB |
| displacement (`3·129³·4`) | 25.76 MB |
| scalars + header | ~0.06 KB |
| **per accepted variant** | **≈ 34.15 MB** |
| **4-rung ladder** | **≈ 136.6 MB** |

Fetched **once** over the LAN after the run completes (the meshes already streamed);
at ~100 MB/s that's ~1.4 s, negligible against a multi-hour 128³ solve. No new iPad
memory peak — the app already holds these arrays for local runs. Served **uncompressed**
(the fields are ~90% zeros off the printed set, so gzip would ~10× it; deferred, it's
a wire-time non-issue and adds a decode step).

**The 6-component stress tensor is DELIBERATELY omitted in v1** (another ~50 MB/variant,
60% of the wire cost) — only the load→anchor **flow sub-mode** consumes it, and the
honesty invariant lets that stay gated. The block is length-prefixed at 0, so a future
version can populate it with **no format change**.

---

## 2. WORKER — no protocol change

The existing `GET /jobs/{id}/files/{name}` route already serves ANY file in the job's
out dir by basename, so `fields.bin` flows through it unchanged; it also appears in the
`done` event's `artifacts` list (harmless — `RemoteRunner` doesn't consume that list).
Only a docstring note was added.

---

## 3. APP — fetch / parse / wire

- **`RemoteFields.swift`** (new): `RemoteFieldsContainer.parse(Data)` — a bounds-checked
  little-endian decoder mirroring `fields.hpp` v1. Any malformed / unknown-version /
  truncated input → `nil` (fields are enrichment; never crash or corrupt a result).
- **`RemoteRunner.swift`**: `fetchFields()` GETs `fields.bin` via the same
  `/files/{name}` route, once, inside `assembleFinalOutcome` — **after** the meshes have
  streamed, so progressive results stay progressive. On success it splices each accepted
  variant's von Mises / displacement / mass / support (matched by `requested_volume_
  fraction`) and threads the grid metadata into the `OptimizeOutcome`. On ANY failure
  (pre-122 worker, transport error) `fields` is nil, mass/support stay 0, arrays stay
  empty — the run still shows geometry + margins, unlike a missing MESH which fails the
  run.
- **`ResultsModel.swift`**: the overlay gates dropped `computedRemotely` in favour of
  **field PRESENCE** (`selectedStressField`/`selectedDisplacementField`/
  `selectedTensorField` + the mass/support labels). Local is unchanged (always has
  fields); a remote run with fetched fields lights up Stress/Flex/Load-path + shows real
  mass/support; a fetch failure leaves them gated (`StressField.isEmpty` is true when the
  grid dims are 0). `remoteComputeNote` is now **data-driven** — it names ONLY the
  readouts genuinely missing, so the "computed on Mac" note **dies where real data
  replaced it** and survives only for what's still Mac-only (playback; and, on a partial
  fetch, the missing fields). The 108/111 invariants hold: never a dead control, never a
  fake 0 g.

### Still Mac-only after this handoff (honestly noted)

- **Optimization-playback keyframes** — not serialised (large, separate scope).
- **The load→anchor flow sub-mode** — needs the 6-component tensor, omitted in v1.

Both keep their note clause; everything else the note used to claim now lights up.

---

## 4. DTO — persist the fetched fields

`OutcomeStore` already persisted `vonMisesField` / `displacementField` / `massGrams` /
`supportVolumeVoxels` / grid metadata / `computedRemotely`, so the fetched fields
already survive reopen. Applying the 108/134 lesson **preemptively**, this handoff also
adds `stressTensorField` to `VariantDTO` (optional, legacy→empty) — it was silently
DROPPED on the round-trip before, killing the anchor-flow overlay after reopen even for
LOCAL runs. Now packed/unpacked + round-trip tested.

---

## Evidence

- **ctest `fields`** (`test_fields.cpp`): writes a synthetic `MinimizePlasticResult`,
  parses the bytes back with an independent LE reader, asserts every header field, the
  accepted-only selection, counts, and float values round-trip; plus the empty-run and
  mis-sized-field (throws) cases. **37 checks, 0 failures.** The CLI end-to-end (`cli_demo`,
  `test_cli`) exercises the real `run_job` write path — a demo run produced a real
  `out/fields.bin` (3.7 MB) beside the report + 3 variant STLs, so the write path is
  proven on real solver output, not just synthetic input.
- **swift test** (self-run, macOS): `RemoteFieldsTests` (4) — parser round-trip +
  unknown-version / truncated / empty failure modes; `ResultsRemoteFieldsTests` (6) —
  fields-less remote stays gated (097), remote-WITH-fields lights up Stress/Flex/Load-path
  + shows real mass, partial-fetch keeps the note only for the missing field, fetched
  fields survive persist→reopen; `OutcomeStoreTests` (8) — the tensor round-trips + its
  legacy-blob-without-tensor decodes. Regression sweep of the touched accessors —
  `ResultsModelTests` (79), `LoadFlowTests` (20), `LoadPathTests` (21),
  `LoadAnchorFlowTests`, `RemoteLivenessUnitTests` (7) — **141 tests, 0 failures.**

### Device QA (the arc closes when this passes)

1. Run a job on the iPad against a **real Mac worker** (rebuild the worker's `topopt-cli`
   from this commit first — the fingerprint guard refuses a mismatch).
2. On a **Mac-computed** accepted variant, open **Stress** → the overlay colours the body
   (not a blank grid). This is the headline: *Stress overlay live on a Mac-computed
   variant = the arc closes.*
3. **Flex** animates; **Load-path** draws its comet flow; the **mass** chip shows a real
   gram figure and **support** a real cm³/minimal.
4. The "computed on Mac" note now mentions only **playback** (not stress/flex/mass).
5. Force a **partial failure** (e.g. point at a pre-122 worker, or delete `fields.bin`
   from the worker out dir): overlays stay gated, note returns in full, **no 0 g**, no
   dead controls.
6. **Reopen** the project after relaunch: the overlays + mass persist (DTO).
