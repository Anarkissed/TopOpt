# 2026-07-31 — RUN SIM load-case resolution: root cause + legible refusals

Task: analyze-loadcase-resolution
Evidence: `evidence/2026-07-31-analyze-loadcase-resolution/`
Scope: core/ + CLI (app gaps REPORTED, not patched — see "What the app must send").

## The symptom

Two errors on RUN SIM from the maintainer's device:

1. `sim failed - tag_step_face: face_id out of range`
2. `analyze: the load case resolved to no external load (every group zero-force
   or tagged no voxels) - nothing to certify under`

Both blocked the whole Auto density path: no sim → no stress field → Auto has
nothing to grade → the lattice overlay stays flat.

## N1 — the root cause, named

Both error strings are verbatim surfaces of the app's ON-DEVICE bridge path —
not the CLI/worker route. RUN SIM runs `LatticeSimModel` →
`TopOptKit.analyzeSolidLoadCase` → `topoptbridge::analyze_loadcase`
(`app/TopOptKit/Sources/TopOptBridge/bridge.cpp:1095`). Error 2 is the
hardcoded string at `bridge.cpp:1110-1115`; error 1 is a raw
`std::invalid_argument` from `tag_face_impl`
(`core/src/io/face_tag.cpp:92-93`) passed through the bridge's catch at
`bridge.cpp:1207-1211`, thrown from `build_production_loadcase`
(`core/src/cli/loadcase.cpp:122` anchors, `:142` load groups).

**The hypothesis ("resolved against a variant mesh") — verified, and refuted in
its specific form.** No analyze surface resolves selectors against a variant
mesh:

* the bridge resolves against `model_path`, which the app sets to
  `project.importedFile.path` — the ORIGINAL import
  (`app/TopOptKit/Sources/TopOptFlows/AppModel.swift:239`,
  `bridge.cpp:1105`);
* the CLI analyze route resolves against `job.model`
  (`core/src/cli/run_job.cpp:1138`, used at `:1174-1178`); the `--mesh`
  variant is imported only as GEOMETRY (`:1250`), never for selector
  resolution.

**The mechanism the hypothesis pointed at is, however, exactly right**: the
face-id selectors get resolved against an import that does not carry the id
space they were authored on. The concrete, code-proven path in this repo is the
RESTORED PROJECT, not the exported variant:

* `ProjectStore.save` copies ONLY the model file into the project folder
  (`app/TopOptKit/Sources/TopOptFlows/ProjectStore.swift:138-146`). The
  face-overrides sidecar (`<model>.faces` — the painted pseudo-faces of a mesh
  part, written by `ProjectModel.persistPaint` next to the ORIGINAL import
  path) is never copied. Neither is the clearance sidecar.
* On reopen, `AppModel.restoreFromDisk` re-imports from the store copy
  (`AppModel.swift:918-929`); `import_part` finds no sidecar there, so the
  painted pseudo-faces do not exist on the re-import — while the restored
  `SelectionModel` groups still reference their ids (persisted in
  `project.json`).
* RUN SIM (and Optimize) then resolve those ids against a model whose
  `face_count` no longer covers them: an id ≥ face_count throws the raw
  out-of-range (error 1); ids that still fall in range land on the WRONG or
  sub-voxel faces and tag nothing, so the load case correctly resolves to no
  external load (error 2). One cause, two surfaces — the maintainer's "three
  separate issues" are one.

Independently of how the ids came to mismatch, the CORE defect this task fixes
is that the resolution path made the failure illegible and the empty case
undebuggable:

* `tag_face_impl` reported "out of range" naming neither the id, nor the count
  available, nor the mesh (face_tag.cpp:92-93);
* `build_production_loadcase` already computed per-group WHY (zero-force vs
  zero-tagged, `loadcase.cpp:137/149`) but only wrote it to a stderr log sink;
  both refusal messages (bridge.cpp:1110, run_job.cpp:1199) discarded it.

**A third, adjacent defect found while proving N3**: `write_fields_file`
serialises ACCEPTED variants only (`core/src/io/fields.cpp:56-58`), and the
analyze route's single pseudo-variant carries the margin verdict
(`run_job.cpp:1469`) — so a REJECTED analyze wrote an EMPTY `fields.bin`: the
field was computed, then dropped, and the overlay went flat exactly when the
part was overstressed. Captured live: `prefix-sim-fields-EMPTY.txt`
(`variants=0` on a real REJECTED analyze).

## N2 — failing tests first

* `evidence/prefix-loadcase-analyze-FAIL.log` — 5 runtime failures on the
  UNFIXED code (N5: message names id/count/mesh; N4: refusal names group+why),
  from the new checks added to `core/tests/validation/test_loadcase_analyze.cpp`.
* `evidence/prefix-loadcase-resolution-COMPILEFAIL.log` — the new
  `core/tests/validation/test_loadcase_resolution.cpp` (R1–R6) does not even
  compile pre-fix (`load_group_reports` / `no_external_load_message` did not
  exist); its R1/R2 message checks fail against the pre-fix strings by
  construction (the old message contained no id or count).
* `evidence/prefix-sim-fields-EMPTY.txt` — the REJECTED analyze's empty
  fields.bin, from a real CLI run on the unfixed writer.

Post-fix: `postfix-loadcase-resolution-PASS.log`,
`postfix-loadcase-analyze-PASS.log` (68 checks, 0 failures — includes the new
N3 rejected-analyze-still-serves-its-field block).

## The fix (core/ + CLI only)

* `core/src/io/face_tag.cpp` — `tag_step_face` / `tag_mesh_face` /
  `mask_step_face` out-of-range messages now name the id, the count and the
  valid range; a model with `face_count == 0` is called out as carrying no face
  ids at all (exported variant mesh / lost sidecar). Exception type unchanged.
* `core/src/voxel/clearance.cpp` — `resolve_clearance_from_face` likewise.
* `core/src/cli/loadcase.cpp` — `validate_face_id` at the resolution points
  (anchors before tagging; a LIVE group's ids after the zero-force skip, so a
  zero-force group's ids are still never resolved — semantics pinned by R3).
  New structured `ProductionRunSetup::load_group_reports` (index, faces, |F|,
  voxels tagged, Ok/ZeroForce/ZeroTagged) mirroring the existing log lines, and
  `no_external_load_message(setup, resolution)` composing the per-group WHY.
* `core/src/cli/run_job.cpp` — the analyze refusal is composed from the
  reports; the analyze AND run loadcase builders wrap builder errors with the
  model name (`against model "l-bracket.step"`); the run route gains the same
  legible empty-load-case refusal (minimize_plastic's guard stays as the
  backstop — no assertion weakened, same throw conditions).
* `core/include/topopt/fields.hpp` / `src/io/fields.cpp` /
  `run_job.cpp:1477` — `write_fields_file` gains `accepted_only` (default
  true, run path byte-identical); the analyze route passes `false` so its ONE
  variant's field is served regardless of verdict.

Messages before → after:

```
tag_step_face: face_id out of range
→ load group 0 face id 137 is out of range — the model carries 10 faces
  (valid ids 0..9). The load case appears to have been authored on a different
  model or import than the one being analyzed.
  (wrapped: analyze: cannot build the declared load case against model
   "l-bracket.step": ...)

analyze: the load case resolved to no external load (every group zero-force or
tagged no voxels) — nothing to certify under
→ analyze: the declared load case produced NO external load — every declared
  load group contributed nothing at resolution 64: group 0 (face 4, |F|=0 N):
  zero force — set a non-zero force on this load. Refusing to analyze under
  SELF-WEIGHT instead of the declared load (that silent fallback is the PR-178
  param-drop bug).
```

(Live captures: `negative-out-of-range.log`, `negative-zero-force.log`.)

## N3 — RUN SIM produces a usable field end to end

RUN SIM twin via `topopt-cli analyze` (`sim_job.json`: l-bracket.step, page-one
anchors = the two Ø5 bores, one RAW-face-id load group, the app's fast tier
64³):

* resolved load: **|F| = 800 N** (group 0, status=ok)
* tagged voxels per group: **load group 0 (face 4): 387**; anchors: **face 8:
  63, face 9: 90** (probe at the same resolution)
* field: `fields.bin` **176,128 voxels, 45,495 non-zero von Mises, peak
  73.58 MPa, max displacement 0.355 mm** (`postfix-sim-fields-summary.txt`)
* verdict REJECTED (margin 0.7475 < 1.5) — honest for 800 N on PLA, and the
  field is now served anyway (that is the N3 fix; before, `variants=0`).

## N6 — the grading chain, proven not inferred

`_graded_job.json` (30 mm cylinder, ladder [1.0], lattice octet + grading
block) through `topopt-cli run` — the same path the app's Optimize takes with
Auto density:

* run → per-variant field → grading law → graded octet lattice, all in one job
* **per-voxel rho range actually produced: 0.05047 → 0.89988** (not uniform),
  315 graded cells, strut radii 0.20 → 0.84 mm, cell 4.38 mm (floored at the
  printability floor), 10,560 latticed voxels + 192 solid fallback,
  `region_ungradeable: false`, lattice ACCEPTED
* `graded_run.log` LATTICE line + `graded_out/run_info.json` `grading` object.

## N7 / N8 — regression + determinism

* Byte-identical reruns: sim fields.bin + report, graded meshes + report +
  fields — ALL IDENTICAL on rerun (`determinism-checksums.txt`).
* Unaffected path, stash-rebuild: the demo self-weight `minimize_plastic` job
  (l-bracket, res 48, 3 rungs) run on the FIXED build and on the stashed PARENT
  build — `variant_070/050/030.stl`, `report.json` and `fields.bin` all
  **byte-identical**; the only differing bytes anywhere are wall-clock stamps
  (`created_wall_ms` in run_info.json; the epoch-ms column of iterations.csv —
  identical with that column stripped). `stash-rebuild-byteidentity.txt`.
* Full ctest on the fixed tree: **86/86 passed** (571 s wall), including the
  new `loadcase_resolution` suite and the grown `loadcase_analyze` (68 checks).
  `ctest-full.log`.

## BLOCKED-STOP / what the app must send (reported, not stubbed)

The core fix makes every resolution failure loud AND legible, but the app-side
cause of the id mismatch needs one thing the app does not persist today:

* **The project store must carry the face-overrides sidecar (and the clearance
  sidecar) alongside the model copy.** `ProjectStore.save` copies only the
  model file; on restore the painted pseudo-face id space is gone while the
  groups still reference it. No core change can recover ids that no longer
  exist on the import — the app must save what the selections were authored
  against. (Follow-up task chip spawned: "Copy face/clearance sidecars into
  the project store".)
* **The bridge should adopt `no_external_load_message`** for its empty-load-
  case refusal (bridge.cpp:1110 still hardcodes the old string; needs a
  vendored-core rebuild first). (Chip: "Adopt core's legible load-case refusal
  in the bridge".) Until then the app still shows the generic message, but the
  out-of-range case is already legible on-device because the bridge surfaces
  the core exception text verbatim.

The job schema needed NO new field: both analyze surfaces already carry the
correct original model; the schema gap hypothesized in the task (original
model missing alongside the variant) does not exist.

## Plain language

When you tap RUN SIM, the app hands the solver your part plus little bookmarks
that say "hold the part here, push on it there". Each bookmark is just a
number — "face number 7 of this file". The crash happened because, after a
project was saved and reopened, the app quietly lost the extra notes that gave
some of those numbers meaning (the faces you had painted by hand). The solver
was then told "push on face 137" of a part that only has 10 faces. It gave up
— but its error said nothing useful, and its cousin error ("no external load")
didn't say which load went missing or why.

The solver now checks every bookmark the moment it uses it, and if one doesn't
match it tells you exactly what's wrong: which number, how many faces the part
actually has, and that the selections were probably made on a different version
of the file. An empty load case still refuses to run — that's a safety rule —
but the message now lists each load and the specific reason it contributed
nothing (zero force, or a face too small to register at the chosen sim
quality). And one more real bug: when the sim decided your part wasn't strong
enough, it threw away the stress picture it had just computed — the exact
picture the lattice needs to know where to put material. It now keeps it.

What's left for the app (two one-click follow-ups): save the hand-painted face
notes together with the part when a project is saved, and show the new detailed
"why" message instead of the old generic one.
