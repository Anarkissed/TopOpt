# Lattice an existing variant — the job that did not exist

Slug: `lattice-a-variant` · Evidence: `evidence/2026-08-02-lattice-a-variant/`

Scope: `core/` + job schema + app. No solver work. No gate changes.

---

## 1. The gap, and the two storage holes under it

The task named the gap correctly, and it is confirmed in code:

* `WorkspacePlaceholder.openLatticePage(variantIndex:)` set **only**
  `latticePageVariantField` — the variant's von Mises field, used as a grading
  demand. It never changed the working model.
* `job.cpp` accepted exactly two modes, `minimize_plastic` and `analyze`.
  Neither takes a finished design as input geometry.
* So Optimize from the lattice page re-ran the whole ladder from the **original**
  model, merely graded by a previous run's field.

Two things had to be true before a "lattice this variant" job could exist, and
neither was.

### Hole 1 — the design was never persisted

A run wrote, per accepted rung: the iso-surface **mesh** (`variant_*.stl`), the
scalar **report** (`report.json`) and the per-voxel **result fields**
(`fields.bin` — von Mises + displacement). The **design** — the density field the
optimizer converged on and the gate certified — lived only in memory and was
dropped when the process exited.

> The brief said `fields.bin` "already carries the variant's density". It does
> not. `fields.hpp` v1 carries von Mises, an empty stress-tensor slot and
> displacement. There was no density field anywhere on disk, and no app-side
> record of one either (`OutcomeCodec.VariantDTO` has no density).

That is *why* the maintainer's workaround was export-the-STL-and-re-import: the
mesh was the only surviving record of the design. And it is why that workaround
cannot work even in principle, beyond the three failures the brief lists — the
mesh is the 0.5 iso-surface of a **grayscale** field, so its re-voxelization is a
*different* design, and the certificate would describe that different object.

### Hole 2 — the app kept no record of the job it submitted

The LAN worker keeps `job.json` beside its `out/`. The app kept nothing:
`OutcomeStore` persists the outcome, not the request. The only thing available at
"lattice this variant" time was the project's **current, editable** state — which
is not the load case the variant was optimized under if the user has moved an
anchor since.

**Per the BLOCKED-STOP, the gap is reported rather than papered over with a
reconstruction.** It is then closed by **retention** — keeping the job document
and keeping the design — which is the opposite of re-authoring them. Nothing in
this task derives a load case from anything other than the bytes that produced
the variant.

---

## 2. What was built

### Core

**`design.bin`** — `core/include/topopt/design_store.hpp`,
`core/src/io/design_store.cpp`. A new container `run_job` writes beside
`fields.bin`. One block per evaluated variant: its density field, the scalars the
run **recorded** for it (margin, effective margin, peak von Mises, verdict,
iteration count), the build direction it was **certified in**, and an FNV-1a
fingerprint over the density bytes.

Three deliberate choices:

* **The density is `f64`, not `f32`.** `fields.bin` narrows its arrays because
  they are display data. This one is fed straight back into
  `analyze_fixed_design`, and the whole path hangs on reproducing the recorded
  margin *exactly*. A narrowed field would reproduce a margin that is merely
  close — the "plausible but wrong" class this codebase rejects everywhere else.
* **The applied build direction is stored.** The recorded margin is a margin *at
  an orientation*. A run that let the scorer choose one would otherwise be
  re-certified against a direction re-derived from gravity and refuse for a
  reason that has nothing to do with the design.
* **The fingerprint is checked on read.** A design that does not hash to its
  record never reaches the gate.

**`loadcase.json`** — a new receipt `run_job` writes in both modes, from one
emitter, recording every fact that determines the load: anchor faces, clamped
DOF, and per force group the resolved magnitude and the **voxels its faces
actually tagged** (the `LoadGroupReport` the builder already produced but only
ever logged to a stderr sink). Nothing environmental is in it — no paths, no
timings — so two documents are comparable byte for byte.

**Mode `lattice_variant`** (`job.cpp`) plus a `variant` block naming the
originating run's `design.bin` and **exactly one** of `index` /
`volume_fraction`. No nearest-rung matching: latticing a rung the user did not
name is precisely the silent surprise this job exists to remove.

**`lattice_variant_job()`** (`run_job.cpp`) — the new entry point:

1. Rebuild the load case from the job — which **is** the original run's job (the
   schema requires the `variant` block to live in it, `mode` swapped). Write the
   same `loadcase.json` from the same emitter.
2. Read the named design back, fingerprint-checked.
3. **One null-posture certification solve** on that density. Its margin **must**
   equal the margin the run recorded, or the job **throws and writes nothing**.
   This solve also recovers the variant's own von Mises field — which is what the
   grading law then consumes, so Auto density needs no separate simulation.
4. The **shared** per-variant lattice pipeline: grade, build the mask, emit the
   mesh, certify the composite, write the receipt.

**The shared pipeline.** `run_job`'s ~300-line `emit_lattice` lambda body was
extracted to `lattice_one_variant(...)`; the lambda now holds only the run-level
aggregation and the streaming checkpoint line. Both entry points run the same
body, so Z3 (one mask and one density, for both the mesh and the certification)
and Z5 (the strut report rides the composite solve) are properties of the code
rather than of two copies that agree today.

**`topopt-cli lattice-variant`**, a worker route on `mode`, and an optional
`design` multipart field. A `lattice_variant` job that ships no design is refused
at the worker with that message, not deep in the CLI with a path the client never
chose.

### App

* **`RelatticeArtifacts`** — the submitted `job.json` and the run's `design.bin`,
  captured at run time and persisted as `run_job.json` / `run_design.bin` beside
  the results (`ProjectStore`), restored together with them. Read back only when
  **both** survive; a design without the job that produced it cannot be certified
  under the right load case.
* **`LatticeVariantContext`** — which variant a page is working on, carrying that
  variant's **own mesh** and its own field, plus whether it can be re-latticed
  and, if not, why.
* **`LatticePageActions`** — two clearly-labelled actions from a variant, one
  from the workspace.
* **`RelatticeJobBuilder`** — the retained document with `mode` swapped and
  `variant` + the lattice blocks added. Everything else is carried **untouched**,
  including keys this build has never heard of (dropping an unknown load-case key
  is the mesh-job-params defect). `loadCaseDifferences` names any key that moved,
  and the workspace refuses to submit if any did.
* **`RelatticeRun`** — submit, poll, fetch the one result. Not the SSE streaming
  runner: a re-lattice has no ladder to stream.
* **`ForceModel.hasPending(in:latticeRoleGroups:)`** — a lattice role is a
  complete declaration, like keep-clear and Protect.
* Face tapping is **off** on a variant, with the reason posted, and the variant's
  own mesh is what the stage renders.

---

## 3. The bars

| Bar | Verdict | Evidence |
|---|---|---|
| **Z1** no ladder runs | MET (with a stated count) | `test_lattice_variant` §A |
| **Z2** the load case is the SAME one | MET | `test_lattice_variant` §A + `LatticeVariantTests` |
| **Z3** certified object == exported one | MET | `test_lattice_variant` §A |
| **Z4** auto grading with no sim | MET | `test_lattice_variant` §B |
| **Z5** strut-strength report comes along | MET | `test_lattice_variant` §A, §B |
| **Z6** existing paths byte-identical | MET | `z6_byte_identity.log` |
| **Z7** the app route is honest | MET | `LatticeVariantTests` |
| **Z8** determinism | MET | `test_lattice_variant` §A, §B |
| **Z9** the page shows/operates on the variant | MET (with a stated limit) | `LatticeVariantTests` |
| **Z10** lattice roles must not stick in "pending" | MET | `LatticeVariantTests` |
| **Z11** authoring is not face-id based | MET | `LatticeVariantTests` |

### Z1 — no ladder runs

    [Z1] lattice-variant wall time: 0.37 s (3 certification solves, 0 design iterations)

`design_iterations == 0`, `variant_meshes_written == 0`, and the output directory
holds **no** `variant_*.stl` — only the latticed file. Asserted, and stated in
`lattice_variant.json`.

**Where this deviates from the bar's wording, and why.** Z1 says "exactly one
solve". The path runs **three** certification solves (four when band clamping
happened), and they are counted and named on the receipt rather than hidden:

1. the null-posture solve that reproduces the variant's **recorded** margin — the
   proof the load case and the design are the originals (this is Z2's backbone);
2. the lattice pipeline's own null-posture reproduction, which PR 245 introduced
   as the live proof that the composite reconstruction is faithful;
3. the composite (latticed) certification;
4. the band-clamp counterfactual, when any voxel was clamped.

Dropping (2) or (4) would delete an existing assertion, which the task forbids;
(1) is what makes Z2 checkable at all. What Z1 is actually protecting — no
optimization, no design loop, minutes not hours — holds: **0.37 s** on the
fixture, three linear solves on the macro grid, no added DOF.

### Z2 — the load case is the same one

`loadcase.json` from the optimize run and from the re-lattice run are compared
**byte for byte** and are identical. It carries the tagged voxel counts, not just
"non-zero":

```json
{ "resolution": 32, "model": "plate_bore.stl", "material": "PLA",
  "anchor_bc_dofs": 540, "load_source": "self_weight",
  "fixture_face_ids": [2], "fixture_voxels_tagged": 50,
  "gravity_direction": [0, 0, -1], "gravity_magnitude_mm_s2": 9810 }
```

In loadcase mode the same emitter writes one entry per force group carrying
`force_mag_n`, `voxels_tagged` and the `ok` / `zero_force` / `zero_tagged`
status, plus the clearance and face-protection footprints.

And the stronger check, **enforced rather than reported**:

```json
"reproduction": {
  "recorded_margin_worst_case": 28597.06713,
  "reproduced_margin_worst_case": 28597.06713,
  "exact": true,
  "note": "ENFORCED, not reported: an inexact reproduction throws and nothing is written"
}
```

Two negative cases are asserted: a job at a different resolution is refused
("grid does not match"), and a job with the *same* grid and the *same* design but
a **different load** (gravity doubled) is caught by the reproduction check and
refused ("does NOT reproduce the margin"). The second is the important one — it
is the case a load-case receipt alone would not catch.

App side: `RelatticeJobBuilder` transforms the retained document and
`loadCaseDifferences` reports `[]` across every load-case key, including a key
the build has never seen. The workspace refuses to submit if any moved.

### Z3 — the certified object is the exported one

One FNV-1a fingerprint over the density field, shared by three roles: the field
that was **stored**, the field the mesh was **built from**, and the field the
composite certification **solved on**. `lattice_one_variant` fingerprints the one
`dens` reference both consumers read, and `lattice_variant_job` throws if it
disagrees with the store. The provenance names it:
`"design_fingerprint": "7989720817242328305"`. A design.bin with one flipped bit
is refused at read with the word "fingerprint" in the message.

### Z4 — auto grading with no sim

    [Z4] graded from the variant's own stored design, NO sim:
         rho 0.0505 .. 0.7352 over 6080 latticed voxels, cell 4.603 mm

Per-voxel relative density **varies** across the part, every value inside the
band core owns, from the variant's own recovered field alone — the job takes no
field input and runs no simulation step. The receipt names the provenance
("THIS variant's own certification von Mises field").

### Z5 — the strut-strength report comes along

On this path's receipt, uniform **and** graded, with the two margins separate:

```json
"strut_strength": { "gated": false,
  "margin_in_plane": 15196.41777, "margin_interlayer": 9552.394544,
  "margin_worst_case": 9552.394544, "z_knockdown": 0.55, ... }
```

Still labelled report-only, still carrying the unsourced-`z_knockdown`
provenance. It is present because the composite solve is the same solve — not
because this path re-derives it.

### Z6 — existing paths byte-identical

`evidence/2026-08-02-lattice-a-variant/z6_byte_identity.sh` builds the tree **at
HEAD** in a throwaway worktree and runs the same optimize job and analyze job
through both binaries:

```
== PRE-EXISTING ARTIFACTS (must be identical) ==
  IDENTICAL opt/report.json                    667f205fd5d32366
  IDENTICAL opt/fields.bin                     bad3cce4d3c1cf79
  IDENTICAL opt/variant_060.stl                2f2432f7f7f2a2f4
  IDENTICAL ana/analysis_report.json           05d62030e68b37af
  IDENTICAL ana/analysis.json                  b068791367c58cae
  IDENTICAL ana/fields.bin                     54d409d763fe14b7

== NEW, ADDITIVE ARTIFACTS (absent at HEAD, present now) ==
  design.bin     HEAD:absent  now:present
  loadcase.json  HEAD:absent  now:present

Z6: PASS — every pre-existing artifact is byte-identical.
```

The new artifacts are separate FILES, deliberately — the PR-271 discipline. The
`emit_lattice` extraction is proven behaviour-preserving by this plus
`test_lattice_hookup` and `test_lattice_certification` staying green.

**Full ctest: 92/92 passed** (1502 s), including the new `lattice_variant`.

**App suite: 1044 tests, 3 failures** — `testThreeMFImport…`,
`testThreeMFImportOptimisesOnDeviceEndToEnd`,
`testReopenedThreeMFProjectReimportsTheStlWorkingCopy`. All three fail with
"3MF import requires lib3mf, which is not available in this build": the
**pre-existing** worktree lib3mf gap, unrelated to this task.

### Z7 — the app route is honest

From the variants page the lattice page carries an identity bar naming the
variant ("Working on · Variant 2 · 60% · 41.2 g · from 'Bracket' · margin 2.31")
and **two** actions:

* **"Lattice this variant"** — primary, accent — *"certifies and exports variant
  2 (60%) — no ladder re-runs"*. Runs the `lattice_variant` job.
* **"Optimize from scratch"** — secondary, bordered — *"re-runs the whole ladder
  from the original part · …"*.

From the workspace entry there is still exactly one **"Optimize"** button with
its previous sub-line, unchanged. When the run kept no design the re-lattice
button is disabled and **carries the reason** rather than going blank.

### Z8 — determinism

Every file both paths write is byte-identical on a rerun: the latticed mesh, the
lattice receipt, the report, the provenance, `loadcase.json`, `fields.bin`. Two
identical optimize runs also produce byte-identical `design.bin` and
`loadcase.json`. `run_info.json` is excluded and says why — it carries a
deliberate wall-clock stamp, as it did before this task. The wall time is
reported on the result and on the CLI line, **not** written into any artifact,
precisely so this bar can be total.

### Z9 — the page shows and operates on the variant

`openLatticePage(variantIndex:)` now builds a `LatticeVariantContext` carrying
the variant's own `meshVertices`/`meshIndices`, and the stage draws
`stageMesh = latticeVariantMesh ?? viewerMesh`. The variant's `ViewerMesh` is
built with **empty** `faceIDs` — an optimized result has no B-rep and no
pseudo-faces, and claiming otherwise is exactly what would let a tap resolve to a
face that is not there. `handlePick` refuses while a variant context is active
and posts the reason. A region authored on the page lands on variant geometry in
the emitted job (asserted: the emitted `axis_point` is the placed primitive's
model-space centre).

**Stated limit.** The stage's *other* overlays — the raymarched strut preview and
the clearance/region volume pass — still read `project.viewerMesh` rather than
`stageMesh`. They draw in the same model frame, so nothing lands in the wrong
place, but the strut preview's occupancy is the original part's, not the
variant's. That is a preview fidelity gap, not a correctness or authoring one:
the **emitted job** and the **certified object** are the variant's throughout.
Threading `stageMesh` through `buildStrutScene`/`LatticeSDFScene` is the obvious
follow-up and was left out of this change rather than done half-way.

### Z10 — lattice roles must not stick in "pending"

`hasPending(in:latticeRoleGroups:)` treats a lattice role as a complete
declaration, exactly as keep-clear and Protect already were. A group set to
"lattice here" no longer blocks Optimize, the summary shows the real reason
("needs an anchor and a load") instead of "finish the pending group", and the
panel row reads "Lattice here" / "No lattice here" instead of "Pending…". The new
parameter defaults to empty, so every existing caller and test is unchanged.

### Z11 — authoring on a variant is not face-id based

`LatticeRegionEmission.variantRegions` emits **only** explicit geometry
predicates — the bolt-cylinder / bounded-slab shape `resolve_clearance_manual`
already carries and core's `lattice.regions` accepts verbatim. Face selections
carried over from the setup page are **counted** (`skippedFaces`) and surfaced,
never synthesised from the original part's B-rep: their geometry describes a
surface this design no longer has, and emitting it would place a region the user
has never seen against the geometry it will actually affect. Face tapping is off
with a stated reason, and primitive placement stays on.

---

## 4. Scope honestly stated

* **On-device runs cannot be re-latticed.** The bridge writes no job document and
  no design container, and has no lattice path at all. The button says so
  ("this run was solved on this device… re-run it on a Mac worker"). Closing that
  would mean giving the bridge a lattice pipeline, which is a different task.
* **Results from before this change cannot be re-latticed.** Their design was
  never stored. Same honest refusal, different wording.
* **The strut preview overlay is not yet variant-aware** — see Z9's stated limit.
* **No fixture, `materials.json`, `ARCHITECTURE.md` or `DECISIONS.md` was
  touched.** The core test builds its own synthetic cylinder in the temp
  directory and reuses the committed `plate_bore.stl`.
* **No assertion was weakened or deleted.** The one place this could have
  happened — the lattice pipeline's null-posture reproduction solve — was kept
  and the solve count reported instead (see Z1).

---

## 5. In plain language

**What was wrong.** You could open the lattice page from a finished variant, and
the page would even use that variant's stress picture to decide where the lattice
should be dense. But the button on that page did not lattice the variant. It
threw the variant away and started the whole optimization over from the original
part — hours of work, and a different shape at the end. Nothing on screen said
so.

Underneath that was a quieter problem: **the app was never keeping the thing you
would need in order to lattice a variant.** When a run finished it saved the
shape (a triangle mesh), the numbers, and the stress colours — but not the
*design* itself, the grid of "how much material is here" that the optimizer
actually produced and the strength check actually signed off on. The mesh is a
tracing of that grid at one contour. You cannot get the grid back from the
tracing. That is why exporting the STL and re-importing it was never going to
work, quite apart from the three ways it visibly failed.

And the app kept no copy of the *job* it had sent either — only whatever you
happen to have on screen right now. If you nudged an anchor after the run, "the
load it was optimized under" was simply gone.

**What now happens.** A run now saves two more things next to its results: the
design grid for each variant, and the exact job it submitted. Neither changes any
file that existed before — checked byte for byte against the old build.

Pick a variant and open the lattice page and you now see, at the top, which
variant you are working on, and the viewport shows *that* variant, not the
original part. There are two buttons instead of one, and they say what they do:
**"Lattice this variant"** and **"Optimize from scratch"**. You can no longer
press one and get the other.

Press "Lattice this variant" and no optimization runs at all. The saved design is
loaded back, checked against the strength number the original run recorded — and
if that number does not come back *exactly*, the job stops and tells you, because
a mismatch means something about the load or the part is not the one that made
this variant. Then the lattice is generated, graded from that variant's own
stress field, and the strength check is re-run on the real latticed object. On
the test part that whole thing takes **0.37 seconds**; on a real part it is
minutes, not the hours a fresh optimization takes.

Two smaller things came out in the wash. Marking a group "lattice here" used to
leave it stuck in limbo and refuse to let you press Optimize at all — it now
counts as a decision, like "keep clear" and "protect" already did. And because an
optimized shape has no clean flat faces to tap, tapping it on the lattice page no
longer pretends to select something: it tells you to place a region instead,
which is the way of marking areas that actually works on that geometry.

One honest limit: this only works for runs done on a Mac worker, and only for
runs done from now on. Runs solved on the iPad, and results from before this
change, have no saved design — and the button says exactly that rather than
quietly doing something else.
