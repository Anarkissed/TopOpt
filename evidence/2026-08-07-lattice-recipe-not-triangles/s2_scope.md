# S2 — scope of the three routes, and what each actually costs

Scoping only. Nothing in this document was built; `git diff main -- core/src
app/TopOptKit/Sources` is empty (see `r2_no_production_change.txt`).

The consumer enumeration this rests on is `s1c_consumers.md`; row ids below
(A*, B*, C*) refer to its tables.

---

## The three facts that set the scope

**F1 · The recipe already exists in memory, one function above the writer.**
`build_lattice_posture` (`core/src/cli/run_job.cpp:1199`) builds
`{topology, cell_size_mm, occupancy mask, per-voxel relative density}`, hands it
to the certifier, and drops it. Its persistent form is already written too —
`design.bin` (`core/include/topopt/design_store.hpp:46`) — because the
generator's boundary is `LatticeBoundary::set_voxel_base(grid, density, iso,
window)` (`core/include/topopt/lattice_boundary.hpp:100`). Every population in
the lattice file (shell, companion, struts) is a function of that field plus the
job's lattice block.

**F2 · The mechanism to materialise on demand already ships — and it REFUSES
this run's own variants.**
`topopt-cli lattice-variant` / `lattice_variant_job`
(`core/src/cli/run_job.cpp:5049`) takes exactly {job document, `design.bin`,
which rung} and produces the same `variant_XXX_lattice.stl`. The iPad already
drives it (`RelatticeRunner.swift`), already *uploads* `design.bin` to do so
(`RelatticeRunner.swift:374`), and already persists the pair as a sidecar while
*deliberately not persisting the mesh* (`ProjectStore.swift:163`,
`LatticeVariantSession.swift:50` — row B11).

**But pointed at the run measured in `README.md`, it refuses.** See
`s2_probes.txt` P1 and the reproduction table below: the entry point re-solves
the stored design and requires the margin to equal the recorded one **exactly**
— `result.reproduction_exact = (result.solid.margin.worst_case ==
sd.margin_worst_case)` (`run_job.cpp:5410-5411`), a bare `==` on a `double`
with no tolerance — and a cold re-solve does not reproduce a warm-started run's
margin bit-for-bit.

**F3 · On the normal LAN flow, nobody ever reads the file.**
`VARIANT … mesh=` carries the **solid** mesh (`run_job.cpp:7737`), the worker
forwards that basename (`topopt_worker.py:262`), and the app fetches it
(`RemoteRunner.swift:1301`). `LATTICE … mesh=` falls through as a generic log
line. `grep -rn "_lattice.stl" app/TopOptKit/Sources` returns **one** hit —
`RelatticeRunner.swift:457`, the re-lattice path, one variant at a time. So on
the maintainer's run the lattice STL was written to the worker's disk, counted,
and read by nothing. And there is no `out/` cleanup in the worker (row C7): the
only `shutil.rmtree` calls are on the upload staging tmpdir.

---

## (a) DEFER MATERIALISATION — the worker keeps the recipe, writes triangles on export

**What it is.** Stop calling the writer during `run`. Keep emitting the receipt,
the counters and the certification exactly as today. Materialise via the
existing `lattice-variant` entry point when an export is asked for.

### What breaks

| consumer | breaks? | why |
|---|---|---|
| A7–A19 (all of core's assertions) | **no** | none of them read the file |
| A1/A2 the writers | by definition | that is the change |
| A4/A5/A6/A14 the counters (`triangles`, `latticed_cells`, `interior_volume_mm3`, the skin refusal) | **YES, and this is the trap** | see below |
| B13/B14 normal LAN run (solid mesh + receipt) | **no** | never touched the lattice file |
| B16–B18 the raymarch preview and proxy | **no** | already implicit |
| B12 smoothing | **no** | already refuses latticed variants |
| C1–C6 worker | **no** | opaque byte pass-through |
| B1–B10 the re-lattice results path | **YES** | see below |

**★ Trap 1 — deferral does not save the generation time, only the bytes.**
`export_latticed_variant` generates *inside* the write arms:

```cpp
if (lat.emit_stl) { StreamingStlWriter w(path); write_with(w); w.finish(); }
if (lat.emit_3mf) { StreamingThreeMfWriter w(path); write_with(w); w.finish(); }
```
(`run_job.cpp:1154-1168`)

`oc.stats` — the triangle count, the latticed-cell count, `interior_volume_mm3`,
`rim_triangles`/`skin_triangles` — is assigned *by* that pass. Turn both flags
off and every one of those receipt fields is zero, and the skin refusal
(`run_job.cpp:3283`) fires spuriously on any `skin != "none"` job because it
tests the measured count. So a correct deferral either (i) still runs the
generator into a `DiscardSink` — the pattern already exists at
`core/src/orient/build_orientation.cpp:79` — which keeps the CPU cost and saves
only the I/O and the storage, or (ii) re-derives those counters in closed form,
which is a second, separate piece of work.

**And you cannot even express the question today.** Probe P2 set
`emit_stl: false, emit_3mf: false` and core refused at schema validation in
0.04 s:

> topopt-cli: job.json: lattice block requests neither STL nor 3MF output

There is no way to ask core for a lattice receipt, its counters and its
certification *without* also writing the mesh. Route (a) is a code change, not a
flag.

**The size of the CPU term is known from the run itself, not from P2:**
`run_info.lattice_export.gen_seconds` = **0.6314112926 s** for all four rungs —
`gen_fraction` 0.017 % of a 3823.38 s run. That is what deferral does *not* save.

**★ Trap 0 — and it comes first: the on-demand path refuses this run.**
See `s2a_blocker_reproduction.txt`. `lattice_variant_job` re-solves the stored
design and requires exact `==` on the margin; all four rungs of the run in
`README.md` are refused, with relative deltas of 3e-10 to 3e-9. Until that check
carries a tolerance (or the recorded margin is carried rather than recomputed),
a deferred run cannot be materialised at all — by the CLI or by the iPad. This
is the first prerequisite of route (a), ahead of Traps 1 and 2.

**★ Trap 2 — export is fed by the app's own buffers, not by the worker.**
`canExport` is `!v.meshVertices.isEmpty && v.meshIndices.count >= 3`
(`ResultsModel.swift:1158`) and `exportSTLData()` re-serialises those buffers
(`:1204`). Deferral alone does not preserve export — the app would have nothing
to serialise. Export survives only if the app asks the worker to materialise
(needs the worker reachable *at export time*, which is a new failure mode on a
flow that currently works offline once the results are in hand), or tessellates
locally, which is route (b) with print-detail requirements.

**Consumers needing change:** B1, B3, B5, B6, B7, B8, B9, B10 — plus the
counter decision above in core.

**Honest cost.** Small in core (one flag and a `DiscardSink`, or a closed-form
counter pass). Real in the app: the results screen and export path both assume
mesh buffers are present the moment a variant exists. The saving is the whole
disk/network/RAM/`results.plist` term and none of the CPU term.

---

## (b) TESSELLATE FOR DISPLAY AT SCREEN RESOLUTION

**What it is.** Ship the recipe to the app; the app builds a mesh at viewport
detail rather than print detail.

**This was already surveyed, measured and rejected — in PR 229/241/184.**
`docs/handoffs/2026-07-29-lattice-preview.md:26-33` is a five-way comparison on
the maintainer's own bracket, and approach #2 ("instanced unit cell", i.e.
tessellate for display) is rejected in it:

> tris @8/6/4 mm: **368 k / 873 k / 2.95 M** … frame time grows as (1/cell)³ …
> boundary-clip to the part is a second pass; can't grade radius within a cell

and PR 184 measured **~2.8 GB of GPU buffers** for a full fine lattice — over
the iOS per-app ceiling *before a frame is drawn*
(`docs/handoffs/2026-07-29-lattice-preview.md:21`). PR 241 separately found the
viewer's real bottleneck was rebuilding the mesh, which disqualifies anything
that regenerates during orbit.

**What it costs on device.** A decimated display mesh is not a smaller version
of the same problem: the strut soup has no smooth surface to decimate toward,
and cutting cells changes what the maintainer is looking at. The measured
alternative already in production is the raymarch (route c), whose frame time is
*flat* in cell size — **12.722 ms @1024² at 8 mm vs 14.563 ms at 4 mm, a 1.14×
ratio where the mesh would be 8.0× the triangles** (Apple M2 Pro,
`evidence/2026-08-05-lattice-retention-app-control/full_suite_after.txt:3175-3184`).

**Verdict: this route is already answered NO by measurement that predates the
task.** Recommending it again would be re-deciding a settled question.

---

## (c) KEEP AN SDF / IMPLICIT FORM

**What it is.** The research route — never materialise a fine graded lattice at
all; carry the field and evaluate it where needed.

**Half of it already ships.** `LatticeSDFMetal.swift:1-27` is a raymarched
analytic SDF with **zero lattice triangles on the device**, tiled by folding into
one cell, CSG-trimmed against the part's narrow-band SDF, radius graded per
owning cell. That is the *preview*. What does not exist is the same treatment
for the **results** view and for export.

**What changes versus (a) and (b).**
- Versus (a): (a) keeps triangles as the interchange format and only moves *when*
  they are made. (c) removes them from everything except the slicer handoff.
- Versus (b): (b) makes a worse mesh; (c) makes no mesh.

**Be honest that this is the largest of the three — and here is the specific
reason, not a general one.** The shipped implicit renderer is **deliberately
approximate and uses a different strut law from core**:

- `LatticeSDFPreview.isApproximate` is hard-coded `true`, with the reason stated
  in the source: *"a sphere-traced iso-surface of the analytic field is the true
  strut TOPOLOGY, but not the byte-identical exported STL (node fillets and print
  tessellation differ)"* (`LatticeSDFPreview.swift:140-143`), and the UI carries a
  banner saying so.
- The app's `LatticeType.strutRadiusMM` and core's
  `topopt::octet_strut_diameter_mm` disagree by **~1.4×** — measured 2026-08-05,
  1.643 mm vs 1.173 mm for the same densest-end floor at a 0.45 mm bead.

So promoting the preview to *the* representation means either shipping an
approximation where a certified artefact is expected, or unifying the two strut
laws through the bridge first. That unification is a prerequisite, not a detail.

**Also unresolved on this route:** the slicer still needs a triangle soup at the
end (row B5), so (c) does not remove materialisation — it moves it to exactly one
place and makes that place explicit.

---

## Recommended order (a recommendation, not a decision)

0. **Unblock the on-demand path (Trap 0).** Give the margin-reproduction check a
   tolerance, or carry the recorded margin instead of recomputing it. Nothing
   below is worth starting while a deferred run cannot be materialised at all.
   This is a certification decision, not a refactor — which is why it is item 0
   and not part of item 1.
1. **(a) next, narrowly: stop writing, keep generating.** Flip the write off,
   keep the `DiscardSink` pass so every counter, receipt field and refusal is
   bit-identical to today. That is the whole of the disk/network/RAM saving with
   *zero* change to anything core asserts, and it is the only one of the three
   whose blast radius is bounded by a single `if`. Its other prerequisites are
   Trap 2 (the app's export path needs a materialisation route before the bytes
   stop being written) and the schema (P2: a lattice block must be allowed to
   request no mesh).
2. **(c) second, for the results view only**, after the app/core strut-law
   unification. This is where the remaining cost lives (`results.plist`, viewer
   RAM, the tint sampling), and the renderer already exists.
3. **(b) not at all** — measured and rejected before this task existed.

The counter-derivation work (closed-form `interior_volume_mm3`, triangle and cell
counts) is the one piece that would let (a) save the CPU term too, and it is
separable from all three.
