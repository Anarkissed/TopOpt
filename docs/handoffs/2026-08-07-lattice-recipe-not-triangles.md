# The recipe, not the triangles

Task `lattice-recipe-not-triangles`, branch `claude/lattice-recipe-triangles-d64151`,
branched from `ea45f7c` (`origin/main`, PR 310).
Evidence: `evidence/2026-08-07-lattice-recipe-not-triangles/`.

**This is a scoping and measurement task. Nothing was built.**
`git diff main -- core/src app/TopOptKit/Sources` is empty:

```bash
git diff main --stat -- core/src app/TopOptKit/Sources
```

Full transcript in `evidence/2026-08-07-lattice-recipe-not-triangles/r2_no_production_change.txt`.
Two build outputs on merge (`core-linux`, `app-macos`), because the branch adds
files under `evidence/` and `docs/` only — no source in either target changes.

---

## 0 · What changes for you

**You were right, and the margin is bigger than you thought.** For your run the
description weighs **15.0 MB** against **5.1 GB** of triangles — about **340×**.
And the number that matters more: **the description's size does not depend on the
cell.** It is indexed per voxel and per job, so the same ~15 MB describes your
5.1 GB run and a coarser one that writes 116 MB. The triangles grow as (1/cell)³;
the recipe does not grow at all.

**Nothing between the worker and your screen reads those triangles.** I
enumerated every consumer with file and line (`s1c_consumers.md`, 21 in core, 18
in the app, 7 in tools). Certification never sees the mesh — `analyze_fixed_design`
has no mesh parameter. The void-escape rule never sees it. Nothing in core
re-imports what it wrote. And on a normal LAN run **the app never downloads it at
all**: the `VARIANT … mesh=` line the worker forwards is the *solid* mesh. Your
5.1 GB was written to the Mac Mini's disk, counted, and read by nobody — and the
worker has no `out/` cleanup, so it is still there.

**Re-deriving it is cheap.** Generating all four rungs took **0.63 s — 0.017 % of
the 3823 s run.** Your 21.3 s for 103 M triangles is the same generator at the
same rate. The geometry is not what the run costs.

**But there is a blocker, and it is not the one anyone expected.** The
materialise-on-demand path already exists and ships — `topopt-cli
lattice-variant`, which the iPad already drives and already uploads `design.bin`
for. **Pointed at this very run, it refuses.** It re-solves the stored design and
demands the margin match the recorded one *exactly* — a bare `==` on a double —
and a cold re-solve differs in the ninth significant figure. §3 has the
measurement on every rung. **Deferring materialisation is blocked on that check
before it is blocked on anything else.**

**One route is already decided and should not be re-opened.** "Tessellate for
display" was surveyed, measured and rejected in PR 229/241/184: 368 k → 2.95 M
triangles across 8→4 mm, and ~2.8 GB of GPU buffers over the iOS ceiling before a
frame is drawn. The implicit renderer that replaced it already ships and is flat
in cell size (12.7 ms vs 14.6 ms where a mesh would be 8× the triangles).

**Two deviations from your captured job, both forced** (§1.1): your `"skin":
"rim"` now aborts on any voxel-silhouette part, and your job as captured hits PR
310's pre-flight refusal in 0.39 s. I ran with `"skin": "none"` and a 2 mm cell —
the remedy your own refusal names.

---

## 1 · What was measured, and on what

### 1.1 The run, and two forced deviations

Your captured job document
(`evidence/2026-08-04-protect-freeze-vs-solidity/job_maintainer.json` +
`M2_verticalStand.step`), resolution 128, four rungs `[0.68, 0.52, 0.38, 0.26]`.

**Deviation 1 — `"skin": "none"` instead of your `"rim"`.** Since PR 302 a `skin`
other than `"none"` that emits zero rim/skin triangles is refused, and that fires
on every voxel-silhouette part. Measured: the first attempt aborted after the
vf=0.68 variant with

> lattice `"skin": "rim"` produced NO geometry on this part (rim_triangles 0,
> skin_triangles 0), so refusing rather than silently exporting an undressed
> lattice under a finish the job asked for.

(`run_2mm_first_attempt.log`). `"none"` is the only setting under which your job
runs at all today.

**Deviation 2 — `grading.cell_min_mm: 2.0` instead of `4.602619931809993`.** As
captured, the job now refuses in 0.39 s (`run_refusal_as_captured.log`):

> 5 of 8 declared lattice include regions are too thin for the planned
> 4.602619932 mm cell — refusing before spending a solve.
> SET cell size between 1.094961872 mm and 4 mm

2.0 mm is inside the range that refusal names.

**So this reproduces your JOB, not your RUN's cell** — and §4 reconciles the
difference. It does not affect the headline, because the recipe is
cell-independent.

### 1.2 The recipe — S1(a)

Grid `128 × 31 × 118` = 468,224 voxels, spacing 1.70528 mm.

| part of the description | bytes | what it is |
|---|---|---|
| the job document | 3,941 | topology, cell mode + window, skin, all 9 regions, the whole load case — the file, not an extract |
| `design.bin`, per variant | 3,745,888 | 96 B header + 468,224 × f64 density |
| `design.bin`, four rungs | 14,983,608 | validated to the byte against the live container: `56 + 4 × 3,745,888` |
| **MINIMAL recipe** | **14,987,549 B = 14.29 MiB** | job + `design.bin`, both of which core **already writes today** |
| + derived per-cell layer | +126,216 | 1-bit occupancy over the cell block, f32 ρ per latticed cell → 15,113,765 B self-contained |

The minimal recipe is not a proposal — it is what core already emits. Every
population in the lattice file is a function of it, because the generator's
boundary is `LatticeBoundary::set_voxel_base(grid, density, iso, window)`
(`core/include/topopt/lattice_boundary.hpp:100`): the shell and the kept-solid
companion are marching cubes over that density field, and the struts are the cell
plan plus per-cell ρ clipped against it.

**The solid companion shell IS a mesh and STAYS one.** `variant_XXX.stl` totals
62,080,536 B / 1,241,604 triangles across the four rungs; the recipe keeps it
verbatim.

### 1.3 The expansion, and the ratio — S1(b)

| variant | cells | cell mm | file triangles | of which struts | lattice STL bytes | vs recipe |
|---|---|---|---|---|---|---|
| variant_026 | 157 | 2 | 277,044 | 109,084 | 13,852,284 | 3.7× |
| variant_038 | 411 | 2 | 473,816 | 307,624 | 23,690,884 | 6.3× |
| variant_052 | 805 | 2 | 799,188 | 644,364 | 39,959,484 | 10.7× |
| variant_068 | 767 | 4 | 766,532 | 619,232 | 38,326,684 | 10.2× |
| **RUN** | **2,140** | | **2,316,580** | **1,680,304** | **115,829,336** (110.46 MiB) | **7.7×** |

**★ The recipe does not grow with the cell; the triangles do.** The description
is indexed per voxel (the design field) and per job (the lattice block); its only
cell-dependent term is 4 bytes per latticed cell. So:

| | expansion | recipe | ratio |
|---|---|---|---|
| this reproduction (2 mm / 4 mm cell) | 115,829,336 B | 14,987,549 B | **7.7×** |
| **your run** (your 102,972,348 triangles / ~5.1 GB) | ~5,100,000,000 B | 14,987,549 B | **~340×** |

Your run's recipe is the same 15.0 MB because it is the same part at the same
resolution with the same four rungs. That row is the answer to your question.

### 1.4 What re-deriving costs — S1(d)

`run_info.lattice_export.gen_seconds` = **0.6314112926 s** for all four rungs,
`gen_fraction` **0.0001657785515** — **0.017 %** of the 3823.38 s run. That is
1,680,304 strut triangles at **2.66 M triangles/s**.

Two independent cross-checks on the same generator:

| source | triangles | seconds | rate |
|---|---|---|---|
| this run | 1,680,304 | 0.631 | 2.66 M/s |
| your run (your figures) | 102,972,348 | 21.3 | 4.83 M/s |
| `evidence/2026-08-05-lattice-cell-fit-mode/r6_cost.txt` | 1,675,088 | 0.389 | 4.31 M/s |

**Materialising the geometry is seconds against a run that costs an hour.** The
round trip is not the expensive part — §3 explains what is.

---

## 2 · Where the mesh is actually consumed — S1(c)

The full table with file:line is `s1c_consumers.md`. The shape of it:

**Core — the only consumer of the triangles is the writer.** Twenty-one rows. The
certified margin, the mass, the strut-strength envelope, the void-escape rule,
the min-feature count, the watertight and single-component gates are all computed
on the voxel grid or on the solid isosurface, *before* a triangle is written.
`analyze_fixed_design` (`core/include/topopt/analyze.hpp:306`) has no mesh
parameter. `lattice_void.cpp` and `strut_strength.cpp` contain **zero**
`TriangleMesh` references. The one production caller of `read_stl_file` is input
part import (`core/src/io/part.cpp:51`) — **nothing in core re-imports what it
wrote**.

**The recipe already exists in memory, one function above the writer.**
`build_lattice_posture` (`core/src/cli/run_job.cpp:1199`) builds
`{topology, cell_size_mm, occupancy mask, per-voxel relative density}`, hands it
to the certifier, and drops it — while the expansion goes to disk.

**App — three real triangle consumers, and one of them already has an implicit
replacement.** `grep -rn "_lattice.stl" app/TopOptKit/Sources` returns exactly
**one** hit: `RelatticeRunner.swift:457`. Everything else feeds off the buffers
that fetch produces — the viewer (B3/B4), the share-sheet export (B5), the
volume/watertight/mass math (B6–B8), the stress tint (B9), and `results.plist`
persistence (B10). The lattice *preview* is already implicit with zero triangles
(`LatticeSDFMetal.swift`). Smoothing already refuses latticed variants.

**On a normal LAN run the app never fetches the lattice mesh.** `VARIANT … mesh=`
carries the solid mesh (`core/src/cli/run_job.cpp:7737`); the worker forwards
that basename (`topopt_worker.py:262`); the app fetches it
(`RemoteRunner.swift:1301`). The `LATTICE …` line falls through as a generic log
line. Only the re-lattice path pulls a lattice mesh, one variant at a time.

**Tools — the worker never looks inside, and never cleans up.** Artifacts are
served as opaque bytes. The only `shutil.rmtree` calls are on the upload staging
tmpdir; `worker.log` has rotation and `out/` has none. Your 5.1 GB is still on
that disk.

**Exhaustiveness (bar R3).** The file is named in one place
(`lattice_base_name`, `run_job.cpp:396`), so a consumer must either spell the
suffix or take the path from `oc.paths`. Both routes were swept
(`r3_consumer_sweep.sh`). Outside `evidence/` and `docs/` the suffix appears
**four times in the whole repository**: two flag declarations
(`core/include/topopt/job.hpp:186-187`), one `filesystem::exists` assertion
(`test_designbox_lattice_recert.cpp:234`), and the one app fetch. Where the
enumeration stops is stated at the end of `s1c_consumers.md`.

**The answer to your question:** nothing between the worker and the screen needs
the triangles except drawing and slicer export.

---

## 3 · BLOCKED-STOP — the on-demand path refuses this run's own variants

The task says to stop and say so if a consumer needs triangles in a way that
makes deferral pointless. **The blocker is not a consumer.** It is the
materialise-on-demand mechanism itself, and it is measured.

`lattice_variant_job` (`core/src/cli/run_job.cpp:5049`) is the shipped entry
point that turns {job document, `design.bin`, which rung} back into
`variant_XXX_lattice.stl`. `topopt-cli lattice-variant` drives it; the iPad
drives it over the LAN and already uploads `design.bin` to do so
(`RelatticeRunner.swift:374`). It is exactly what "write triangles only when an
export is requested" would call.

Before it lattices anything, it re-solves the stored design and compares the
margin with the one the run recorded:

```cpp
result.reproduction_exact =
    (result.solid.margin.worst_case == sd.margin_worst_case);
```
(`core/src/cli/run_job.cpp:5410-5411` — a bare `==` on a `double`, no tolerance.)

Pointed at the run in §1, built from nothing but its own job document and its own
`design.bin`, it **refuses every rung**:

| vf | recorded margin | reproduced | relative Δ | verdict |
|---|---|---|---|---|
| 0.68 | 3254.356637 | 3254.356646 | 2.77e-09 | REFUSED |
| 0.52 | 3389.417071 | 3389.417070 | 2.95e-10 | REFUSED |
| 0.38 | 3290.912400 | 3290.912403 | 9.12e-10 | REFUSED |
| 0.26 | 3014.120054 | 3014.120050 | 1.33e-09 | REFUSED |

> lattice_variant: the restored design does NOT reproduce the margin the run
> recorded for this variant (recorded 3254.356637, reproduced 3254.356646). That
> means the load case, the grid or the design is not the one that produced this
> variant — refusing to lattice it, because the certificate would describe a
> different object than the run's.

**It is systematic, not flaky.** vf=0.68 was run twice and reproduced
3254.356646 both times. The difference is between a *warm-started* certification
solve inside the ladder and a *cold* standalone one — both converged, differing
in the ninth significant figure. `4 of 4` in `s2a_blocker_reproduction.txt`.

**Why this blocks (a).** Deferral means the mesh exists only when someone asks
for it, and this is the thing that would be asked. As it stands, a deferred run
could never be materialised at all — not by the iPad, not by the CLI. The
refusal's *reasoning* is sound (a certificate must describe the object it
certified); its *implementation* — exact bit equality of a double across two
different solve paths — is not something a re-solve can satisfy. **This has to be
given a tolerance, or the recorded margin has to be carried rather than
recomputed, before any of route (a) is worth starting.**

I did not change it: R2 forbids touching `core/src` on this branch, and picking
the tolerance is a certification decision, not a refactor.

**A second, smaller blocker in the same place.** The job schema refuses a lattice
block that asks for no output at all:

> topopt-cli: job.json: lattice block requests neither STL nor 3MF output

(`s2_probes.txt` P2). So there is no way today to ask core for the receipt, the
counters and the certification *without* also writing the mesh — which is the
whole of route (a) expressed as a flag. Deferral is a code change, not a
configuration.

**And a trap behind that one.** `export_latticed_variant` generates *inside* the
write arms (`run_job.cpp:1154-1168`), and `oc.stats` — the triangle count, the
latticed-cell count, `interior_volume_mm3`, and the rim/skin counts the skin
refusal tests — is produced *by* that pass. So "stop writing" must still run the
generator into a `DiscardSink` (the pattern exists at
`core/src/orient/build_orientation.cpp:79`), or every one of those receipt fields
goes to zero and the skin refusal fires spuriously. **Deferral saves the bytes,
not the 0.63 s.**

---

## 4 · Reconciling this run with yours

Your figures and this run agree on the generator and disagree only on the cell.

**The generator is the same.** Triangles per cell: yours 102,972,348 / 129,195 =
**797**; measured here **807 / 800 / 748 / 800** per rung. An octet cell emits
32 triangles per strut and 20 per node (`lattice_gen.cpp:476, 936`), so that
ratio is a property of the topology, not of the part.

**The cell is not.** Your run has 60× this run's cells. Cells grow faster than
(1/cell)³ because a finer cell also clears the cells-per-member floor in more
members, so more of the part becomes latticeable — measured previously at 3.83×
the triangles for a 2.50× finer cell
(`evidence/2026-08-05-lattice-cell-fit-mode/r6_cost.txt:32`). Your figures land
at the printability floor your own refusal quotes, **1.094961872 mm**, and the
same prior evidence measured **152.3 MB for the heaviest rung at 1.0950 mm** on a
res-48 seven-4-mm-region job — which at your resolution 128 scales to the
~1.28 GB/rung your 5.1 GB implies.

**This was not re-measured end to end on your part, and I am saying so rather
than implying otherwise.** It needs another 64-minute optimize run, and the cheap
route — re-lattice from `design.bin` at a finer cell — is exactly what §3 blocks.
What the headline ratio needs from your run is the **recipe size**, and that is
measured exactly, because it does not depend on the cell.

---

## 5 · The three routes — S2

Full scoping, with what breaks and which consumers change, is `s2_scope.md`.
**A recommendation, not a decision:**

**1. (a) DEFER MATERIALISATION — but fix §3 first.** This is the only route whose
blast radius in core is bounded by a single `if`, and it captures the whole
disk/network/RAM/`results.plist` saving with no change to anything core asserts.
Its prerequisites, in order: (i) the margin-reproduction check needs a tolerance
or a carried value; (ii) the schema needs a way to ask for a receipt without a
mesh; (iii) the generator must still run into a `DiscardSink` so the counters
survive; (iv) the app's export path needs a materialisation route, because
`canExport` is literally "do I have mesh buffers"
(`ResultsModel.swift:1158`) and `exportSTLData()` re-serialises them — deferral
alone silently disables export.

**2. (c) KEEP AN IMPLICIT FORM — for the results view, after one prerequisite.**
Half of it ships: `LatticeSDFMetal.swift` renders the lattice with zero triangles
on device. The prerequisite is specific, not general: the app's
`LatticeType.strutRadiusMM` and core's `octet_strut_diameter_mm` disagree by
**~1.4×**, and `LatticeSDFPreview.isApproximate` is hard-coded `true` with the
reason in the source. Promoting a deliberately approximate preview to *the*
representation means unifying the two strut laws through the bridge first. This
is the largest of the three, and it is where the remaining cost lives.

**3. (b) TESSELLATE FOR DISPLAY — do not re-open.** Surveyed, measured and
rejected in PR 229/241/184 before this task existed: 368 k / 873 k / 2.95 M
triangles at 8/6/4 mm, ~2.8 GB of GPU buffers over the iOS ceiling before a frame
is drawn (`docs/handoffs/2026-07-29-lattice-preview.md:21-33`). The implicit
renderer that replaced it is flat in cell size — 12.722 ms @1024² at 8 mm vs
14.563 ms at 4 mm, **1.14× where a mesh would be 8.0× the triangles**
(Apple M2 Pro, `evidence/2026-08-05-lattice-retention-app-control/full_suite_after.txt:3175`).

**Separable from all three:** deriving `interior_volume_mm3`, the triangle count
and the cell count in closed form. That is the one piece that would let (a) save
the CPU term as well as the bytes.

---

## 6 · In plain words

You asked why we write the triangles at all when keeping it as a description
would be a non-issue for space. Here is the size, measured on your job:

**The recipe is about 15 megabytes. The triangles are about 5.1 gigabytes. Around
340 times bigger.**

The 15 MB is not something we would have to invent. It is your job document
(3,941 bytes) plus `design.bin` (14,983,608 bytes) — two files core already
writes on every run, and which your iPad already uploads when it re-lattices a
variant. Everything in the 5.1 GB file is computed from them.

And the part that makes the case stronger than you put it: **the 15 MB does not
change when the cell gets finer.** It is one number per voxel. The triangles grow
with the cube of how fine the cell is — that is why your run reached 5.1 GB. Halve
the cell again and the recipe is still 15 MB.

Making the triangles back costs **0.63 seconds** on this run, and 21.3 on yours.
The run itself took an hour. The geometry is not what you are waiting for.

Nothing between the worker and your screen reads that file. The certification
never opens it. On a normal run over the LAN your iPad never even downloads it —
it downloads the solid mesh. Your 5.1 GB was written to the Mac Mini and read by
nobody, and the worker never deletes it, so it is still sitting there.

**The catch, and it is a real one.** We already have the machinery to make the
triangles on demand — it is what the "re-lattice this variant" button uses. I
pointed it at this run and it refused all four rungs. Before it will lattice
anything it re-checks the design and insists the strength number come out
*exactly* the same as the run recorded, down to the last bit of a decimal. It
comes out right to nine significant figures and then differs. The check is right
to exist; it is just written as "exactly equal" when it needs to be "equal to
within a hair". Until that is loosened, a run that kept only the recipe could
never be turned back into a printable file — so that is the first thing to fix,
not the last.
