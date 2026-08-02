# A design-box run must be latticeable and re-certifiable

Slug: `design-box-recertification`
Evidence: `evidence/2026-08-03-design-box-recertification/`
Scope touched: `core/` only (one header, one core TU, the CLI, one new test).

---

## The symptom, and what it actually was

From the maintainer's device (Aug 1): set a design box, optimize, try to lattice a
variant. The run refused:

> lattice certification does not support a design box (add-material) run: the
> certification load case cannot be reconstructed under domain expansion. Run the
> lattice job without a design box.

That refusal was not protecting against something impossible. A design box expands
the voxel grid, and every node-indexed input — the mounting Dirichlet BCs, the
declared external tractions — is indexed to the ORIGINAL part grid, so it must be
remapped onto the expanded grid. `minimize_plastic` has always done that. The
latticed RE-CERTIFICATION rebuilt the same load case a SECOND time, at `run_job`
level, and did not. The old code said so in its own words
(`run_job.cpp:716-717`): *"run_job refuses design-box + lattice, so no remap is
needed here and this reconstruction is exact."*

The refusal was protecting the codebase from its own second reconstruction.

---

## Review round (PR 285) — two confirmed defects, both mine, both fixed

Two findings from the PR review were confirmed by reading and are fixed in this
branch. Both were introduced by this task, not inherited.

**P1 — the certified object was not the exported object.** `export_latticed_variant`
takes a cell predicate; the uniform path had always passed NULL, which the
generator reads as "lattice every cell the boundary cannot prove empty". That was
correct while the certification mask WAS the boundary's own silhouette. The
added-material policy broke that invariant the moment it cleared voxels the
boundary still considers material: the mask said solid, the generator kept writing
struts, and the solid companion wrote the *same voxels* solid. On specimen D that
was most of the file, not an edge — the run emitted 110 latticed cells against a
mask implying 16.

Fixed two ways at once, because one alone is not enough:

* the uniform path now derives its cell set FROM THE FINAL MASK under a design
  box, exactly as the graded path already did (`cell_latticed`);
* the policy now acts on WHOLE LATTICE CELLS. A cell is the atom the generator
  emits, so clearing a cell's added voxels while leaving its part voxels masked
  would leave the cell latticed. A cell holding any added material is kept solid
  entire. Strictly more conservative — more solid, never less — and it makes both
  properties exact rather than approximate.

That second decision costs mass and the receipt says so: on specimen D the policy
now keeps **892 voxels (69.4% of the printed object)** solid, not 716 (55.7%). The
extra 176 are part voxels sharing a cell with added material. Both numbers are in
every receipt (`outside_original_part`, `kept_solid_voxels`).

**P2 — a no-mesh analyze certified a filled box.** `VoxelGrid design_grid =
cert_grid;` used the expanded domain for *every* analyze job, but
`expand_design_domain` tags the in-box Active region `Interior` — SOLID — and the
no-mesh path takes its occupancy from the grid's tags. So a design-box analyze
with no `--mesh` certified the box filled rather than the part as drawn. That is
RUN SIM and every non-smoothing re-certification.

Fixed: the expansion is used only when there IS a substitute mesh
(`expand_for_mesh`), which is the only case that needs it. The no-mesh path keeps
the model grid, the part-indexed BCs and the part-indexed tractions — byte-identical
to HEAD, verified below.

**A third gap the P1 fix exposed, and how it is handled.** A GRADED run takes its
swept multilevel cell occupancy from `grade_lattice`'s cell plan, which is built
before the added-material policy can speak — so a graded design-box run could emit
struts into cells the certificate calls solid, the same failure in another shape.
Rather than ship it unverified, `grading` + `design_box` is now REFUSED with a
message naming exactly that reason. This is strictly NARROWER than the refusal that
stood before this task, which rejected the whole design-box + lattice combination.
Uniform lattice + a design box is supported and tested.

## What shipped

**ONE remap, in core, with four callers.** `topopt/pipeline.hpp` now declares:

* `SolvedDesignDomain resolve_design_domain(part_grid, bcs, options)` — the
  expansion (`expand_design_domain` with the caller's keep-outs, freeze flag and
  `kDesignBoxCoarsenAlign`), the anchor-pad merge, and `remap_node_to_domain` over
  the BCs and the external loads. This is the block that used to live inline in
  `minimize_plastic`; it was **moved**, not reimplemented.
* `std::vector<NodalLoad> design_domain_loads(domain, options, density)` — THE
  definition of "the load this run is solved under": the declared tractions
  remapped onto the solved grid, else self-weight on that grid.
* `std::vector<char> original_part_voxels(part_grid, domain)` — which solved-grid
  voxels are the imported part, i.e. what "material grown outside the part" means.

Callers: `minimize_plastic` (the optimize ladder), `run_job`'s latticed
certification, `lattice_variant_job` (re-lattice a stored design),
`analyze_job` (fixed-design / smoothing re-certification).
`minimize_plastic_solved_grid` is now literally `resolve_design_domain(...).grid`,
so the doc comment claiming "minimize_plastic itself uses it" is finally true.

**Both refusals are gone** (`run_job` pre-flight and `lattice_variant_job`), each
replaced by a comment naming what changed. The density-band refusal (bar E5) is
untouched.

**Three latent grid mix-ups the sharing exposed and this fixes:**

| site | was | now |
|---|---|---|
| `lattice_cert_context` part-solid denominator | `solved_grid.solid_count()` | the PART grid's — what `minimize_plastic`'s ladder normalises to (handoff 080) |
| `lattice_variant_job` `fields.bin` | written against the part grid | the solved grid (it threw `size 12288 != 4224` under a box) |
| `analyze_job` design grid (SUBSTITUTE MESH ONLY — see P2) | `voxelize_onto_grid(mesh, model_grid)` | onto the SOLVED grid — it was silently CLIPPING a design-box mesh at the part's bounding box |

The last one is measured below and matters.

---

## *** THE DECISION YOU HAVE TO MAKE — I have NOT made it ***

With a design box the optimizer grows material where the original part was not.
Nothing in the generator or the gate has an opinion about what should happen to
that material when the variant is latticed. **On the specimen below it is 55.7% of
the printed object — and 69.4% once the whole-cell rule the P1 fix requires is
counted.** The three answers are different objects:

**KEEP SOLID — what ships today, as a placeholder.** Every lattice cell holding
added material is dropped from the certification mask WHOLE, so those cells are
certified SOLID, are not latticed, and are exported as the solid companion body.
Most conservative: solid is stiffer and stronger than lattice at the same
geometry, so no margin here is optimistic, and the certified object is exactly the
exported file (one mask governs both — asserted, see P1). Cost: mass — you get a
lattice inside the part you imported and solid everywhere the optimizer added,
*plus* the part material sharing those cells. On the specimen that is **892 voxels
/ 376 mm³, 69.4% of the printed object**, and the lattice covers 16 cells where
the un-fixed code emitted 110.

**LATTICE IT.** Lightest, and arguably what someone asking for a lattice meant.
Certified honestly either way — the composite solve carries the octet tensor over
those voxels too. The reservation is that the added region is new, thin, load-path
material with no imported geometry behind it: a cell that does not fit is clipped,
and the margin then rests on struts in a region you never drew.

**EXCLUDE IT — considered and rejected, deliberately not implemented.** Omitting
it would export an object the certificate does not describe, and the design the
gate accepted needs that material to carry its load.

Flipping the decision is **one constant**: `kDesignBoxAddedMaterialKeptSolid` in
`run_job.cpp` (the alternative branch is one line, already in place). Every receipt
names which policy ran (`added_material.policy`) and says out loud that it is a
placeholder.

---

## Bars

### AI1 — the load case is the SAME one, not a valid one

`test_designbox_lattice_recert` sections B and C.

* The re-lattice run's `loadcase.json` is **byte-for-byte** the optimize run's —
  anchor faces, clamped DOF count, and per group the resolved force magnitude and
  the number of voxels its faces tagged.
* The restored design reproduces the margin the run **RECORDED** for that variant:
  `recorded 16013.15016 == reproduced 16013.15016`, `==`, enforced (the job throws
  otherwise), not reported.
* The composite margin agrees across both entry points for the same design:
  `12044.85937` from the optimize path and from `lattice_variant_job`, compared as
  the two receipts render it (same emitter, same precision — a textual identity).
  (It was `12121.61941` before the P1 fix; the fix keeps whole cells solid, which
  is a different — and now actually exported — composite.)

**How I confirmed the test FAILS against a no-remap reconstruction** (section C, a
live negative control in the test, not an argument): the same stored design is
certified on the same expanded grid with the load case rebuilt the OLD way —
part-grid-indexed BCs used verbatim, self-weight computed on the PART grid — and
asserted not to reproduce. It does not merely land on a different number, it
**cannot solve at all**:

```
[AI1-neg] no-remap reconstruction threw: fea_solve_mgcg_matfree: under-constrained
          system (load applied to a void DOF with no stiffness)
```

The same section asserts the WITH-remap reconstruction reproduces bit-for-bit, so
the control is a controlled comparison, not a broken input.

### AI2 — the refusal is gone, and earned

The maintainer's shape — **design box + 4 keep-clears + lattice on** — runs end to
end (`jobs/C_box_keepclear_lattice.json`, HEAD refuses it):

```
[loadcase] clearance face=-1 kind=bolt voxels_frozen=32 status=ok   (x4)
LATTICE vf=0.68 octet cell_mm=3 strut_r=0.45 rho=0.4096 cells=96 tris=50024
        lattice_margin=21.9001 lattice_accepted=1
```

Four rungs, all ACCEPTED against the production `margin_stop=1.5`, each with a
receipt and a latticed mesh. Receipts in `evidence/.../receipts/`.

Re-latticing a stored design-box variant later (`lattice_variant_job`, which had
its own refusal) also works:

```
design: fingerprint 4361396442930156187, 16 optimizer iterations originally
reproduction: recorded margin 16013.2 == reproduced 16013.2 (enforced)
solves: 3 certification (design iterations 0, variant meshes 0)
solid margin 1.601e+04 -> latticed margin 1.204e+04
verdict: ACCEPTED                                        wall: 0.57 s
```

**One thing this does NOT fix, and it is not lattice's.** A keep-clear whose swept
volume reaches into the design box's ADD-region, on a **self-weight** run, cannot
solve — on HEAD and on this branch identically, **with no lattice block anywhere
in the job** (`evidence/.../preexisting_selfweight_clearance_crash.txt`,
`jobs/X_preexisting_selfweight_clearance_crash.json`). Cause: `expand_design_domain`
tags the add-region `Interior` (solid), so `self_weight_loads` puts weight on it,
while the clearance overlay pins those same voxels `FrozenVoid` — the load lands
on an eliminated DOF. A *declared load* run is unaffected (the C job above has
keep-clears freezing 32 voxels each and runs fine), and a run with no design box is
unaffected (the rasterizer already skips part material, and part-grid empties carry
no weight).

I did **not** fix it. The obvious fix — drop clearance-void voxels from
self-weight — would change the load on any design-box + clearance run that
survives today (a thin clearance shell inside solid add-material keeps its DOFs
stiff and does contribute weight), which is a verdict-flip risk on an existing
path and therefore not mine to take under this task's bars. Flagged as separate
work.

### P1 / P2 — the two review fixes, measured

`evidence/.../p1_p2_audit.txt`. Every design-box receipt now carries the audit;
`emitted_lattice_cells` is `LatticeGenStats::latticed_cells`, the generator's own
count of the cells it wrote (predicate AND boundary-overlap), not a re-derivation.

| variant | printed | outside part | kept solid | certified cells | emitted cells | strut+solid |
|---|---|---|---|---|---|---|
| C vf 0.68 | 2064 | 0 | 0 | 62 | 62 | **0** |
| D vf 0.80 | 1286 | 716 | 892 | 16 | 16 | **0** |
| D vf 0.70 | 726 | 266 | 394 | 22 | 22 | **0** |
| D vf 0.60 | 360 | 42 | 88 | 16 | 16 | **0** |
| E (D re-latticed) | 1286 | 716 | 892 | 16 | 16 | **0** |

Note C: outside-part material is zero there, so the policy clears nothing — yet
the emitted cell count still fell from 96 to 62. That is the SAME P1 bug in its
other form: the old NULL predicate latticed 34 cells that held no masked voxel at
all, so the certificate described no lattice there while the file had struts.

P2, the same analyze run three ways:

| | voxel mass | printed fr | margin | claims an expansion |
|---|---|---|---|---|
| design box, no `--mesh` (fixed) | 1.62691875 g | 1.0 | 34550.69196 | no |
| NO design box, no `--mesh` | 1.62691875 g | 1.0 | 34550.69196 | no |
| HEAD, design box, no `--mesh` | 1.62691875 g | 1.0 | 34550.69196 | no |

Equal to the last digit, and equal to HEAD — the no-mesh path is restored exactly.
Asserted in `test_designbox_lattice_recert` section E.

### AI3 — no-design-box paths byte-identical

Stash-rebuild: `git stash` → build HEAD → save the binary → restore → build →
run both binaries over the same jobs. `evidence/.../byte_identity.txt`.

Re-run after the P1/P2 fixes. Every artifact of the **no-design-box + lattice**
run and of the **design-box, no-lattice** run is byte-identical — 20 artifacts, 0
differ: `design.bin`, `fields.bin`, `report.json`, `loadcase.json`, every
`variant_*.stl`, every `*_lattice.stl`, every `*_lattice.report.json`. So is the
no-box `analyze --smooth` run (`analysis_report.json`, `fields.bin`, the smoothed
STL), and — new since the P2 fix — the **design-box no-mesh analyze**
(`analysis_report.json`, `fields.bin`). `iterations.csv` matches
on every physics column (the differing columns are `wall_ms` and the `*_ms`
timings); `build_orientation.json` differs only in `sweep_seconds`;
`run_info.json` carries its documented wall-clock stamp. `analysis.json` differs
only in the output-directory path it echoes back.

**ctest: 97/97 passing** (96 before; +1 for the new test). The new test is 54
checks, 0 failures.

### AI4 — full gate table, before and after, every rung

`evidence/.../gate_tables.txt`, **re-run after the P1/P2 fixes**. Condensed:

| job | rung (printed fr) | HEAD | NEW |
|---|---|---|---|
| A no box + lattice | 0.8025723 | ACCEPTED 34732.24587 | ACCEPTED 34732.24587 |
| | 0.7279743 | ACCEPTED 31991.90649 | ACCEPTED 31991.90649 |
| | 0.5903537 | ACCEPTED 28597.06713 | ACCEPTED 28597.06713 |
| B design box, no lattice | 0.4135048 | ACCEPTED 16013.15016 | ACCEPTED 16013.15016 |
| | 0.2334405 | ACCEPTED 10180.36257 | ACCEPTED 10180.36257 |
| | 0.1157556 | ACCEPTED 7475.920599 | ACCEPTED 7475.920599 |
| C box + 4 keep-clears + lattice | all 4 | **REFUSED** | ACCEPTED 7.238580468 / 8.025392377 ×3 (required 1.5) |
| D box + self-weight + lattice | 3 rungs | **REFUSED** | identical to B, rung for rung |

**No verdict flips and no margin drift on any existing path.** D's ladder being
digit-for-digit B's is worth noting on its own: adding a lattice block to a
design-box job does not perturb the optimize ladder.

**Voxel classification against a 1e-9 negative-control floor** (PR 248's
discipline), `evidence/.../design_cmp.py`:

```
A_nobox_lattice   HEAD vs NEW: max |d rho| = 0.000e+00   classification flips = 0
                  NEGATIVE CONTROL (one voxel moved 1e-9 below iso): flips = 1
B_box_nolattice   HEAD vs NEW: max |d rho| = 0.000e+00   classification flips = 0
                  NEGATIVE CONTROL: flips = 1
```

Zero drift, and the comparator demonstrably sees a 1e-9 move — the zero is a
measurement, not a blind spot. Unchanged by the P1/P2 fixes: neither touches the
optimizer, and the design-box ladder (job D) is still digit-for-digit job B's.

### AI5 — smoothing too

A smoothed design-box variant **does** re-certify through `analyze_job`
(`jobs/F_box_analyze_smooth.json`), and getting there uncovered a defect on that
path that has nothing to do with lattice: `analyze_job` voxelized the substitute
mesh onto the **part** grid, so under a design box it silently **clipped** the
material the optimizer grew and certified a smaller object than the file it
claimed to describe. Same specimen, same input mesh:

| | HEAD | this branch |
|---|---|---|
| grid used | part 32×22×6 | solved 32×24×16 |
| voxel mass | 0.2349 g | 0.5179 g |
| mesh mass (the honest reference) | 0.4694 g | 0.4694 g |
| printed fraction | 0.1444 | 0.3183 |
| margin (worst case) | 286600.8 | 63678.7 |
| min-feature violations | 41 | 110 |
| verdict | ACCEPTED | ACCEPTED |

HEAD's voxel mass is **half** the mesh mass of the very geometry it was handed;
the new one brackets it correctly (voxel proxy slightly above, as centre-sampling
gives). **The verdict does not flip** — but the margin moves 4.5×, so on a job
whose `margin_stop` sits between the two it would. I am flagging that explicitly
rather than burying it: the old number described a truncated object, the new one
describes the object, and no existing path in the evidence changes verdict. The
`analysis.json` provenance now carries a `design_box` block naming the part grid,
the solved grid and the offset, so a reader never has to guess which grid a
re-certification ran on.

### AI6 — the expansion is visible in the receipt

Every latticed receipt on a design-box run carries an `added_material` section.
Measured:

| specimen | printed | inside part | outside | outside % | kept solid (whole-cell) | % |
|---|---|---|---|---|---|---|
| D box + self-weight, vf 0.80 | 1286 | 570 | **716** | **55.7%** | **892** | **69.4%** |
| D vf 0.70 | 726 | 460 | 266 | 36.6% | 394 | 54.3% |
| D vf 0.60 | 360 | 318 | 42 | 11.7% | 88 | 24.4% |
| E the same design re-latticed | 1286 | 570 | 716 | 55.7% | 892 | 69.4% |
| C box + keep-clears + declared load, vf 0.68 | 2064 | 2064 | 0 | 0.0% | 0 | 0.0% |

The counts partition the printed set exactly (`inside + outside == printed`,
asserted), and `kept_solid_voxels >= outside_original_part` is asserted too — the
whole-cell rule's cost is reported, never absorbed. Every kept-solid voxel is
picked up by the solid companion body, so material can never be certified solid
and then omitted from the file. Each receipt also carries the **P1 audit**:
`certified_lattice_cells`, `emitted_lattice_cells` (the generator's own count) and
`voxels_strut_and_solid`. C growing nothing
outside the part is a real result, not a null: with a declared load the optimizer
had no reason to leave the plate, which is exactly why the D specimen exists.

### AI7 — determinism

Rerun of the design-box lattice **optimize** job: 16 artifacts (job C) and 13
(job D) byte-identical, timing files excluded. Rerun of `lattice_variant_job`:
6 artifacts byte-identical, asserted in the test. Composite margin identical.

---

## Blocked-stop checks

* **"If the remap cannot be shared between the optimize path and the
  re-certification path — one implementation, two callers — STOP."** It is shared.
  `resolve_design_domain` / `design_domain_loads` live in core and have four
  callers; the block was moved out of `minimize_plastic`, not copied. The optimize
  path additionally asserts that the domain it resolves is the grid
  `minimize_plastic_solved_grid` names.
* **Known gap, refused rather than shipped**: `grading` + `design_box`. The graded
  cell plan is chosen before the added-material policy runs, so the swept
  multilevel emission could reproduce P1 in another shape. Refused with that
  reason named — strictly narrower than the refusal that stood before this task.
* **"If the retained job document does not carry enough to rebuild the expanded
  grid exactly, report the storage gap."** No gap. The job carries `design_box`
  and `keep_outs`, which is everything `expand_design_domain` needs, and
  `design.bin`'s header already stores the grid the run SOLVED on (under a box,
  the expanded one) — so the re-lattice path rebuilds the grid AND checks it
  against the stored header before touching a solve. The exact-match check now
  compares against the rebuilt solved grid and, when they disagree, names both
  shapes in the message.

## Files

Core: `include/topopt/pipeline.hpp`, `src/simp/minimize_plastic.cpp`,
`src/cli/run_job.cpp`, `tests/validation/test_designbox_lattice_recert.cpp`,
`CMakeLists.txt`. No app changes — no new capability needed consuming yet; the app
reaches these paths through the same CLI/bridge entry points.

`multigrid.cpp` untouched. Fixtures, `materials.json`, `ARCHITECTURE.md` and
`DECISIONS.md` untouched. No assertion weakened or deleted; the gate's verdict
logic and tolerance untouched.

---

## In plain language

You set a design box, optimized, and asked for a lattice. The program said no.

The reason it said no was not that the job is impossible. When you use a design
box, the program works on a bigger block of space than your part occupies, so that
it can add material outside the part. Everything that was pinned to your part —
where it is bolted down, where the load pushes — has to be re-pointed at the
bigger block. The main optimizer has always done that re-pointing correctly. But
the lattice step worked out where the load goes a *second* time, on its own, and
that second calculation had been written assuming the block never gets bigger.
Rather than get it wrong, someone made it refuse. The refusal was guarding against
the program's own duplicated arithmetic.

There is now one piece of code that does the re-pointing, and everything that
needs it calls that one piece. So the lattice step can no longer disagree with the
optimizer, because it is no longer doing its own version of the sum. Both refusals
are gone. Your shape — design box, four keep-clears, lattice on — runs from start
to finish and produces the certificate. So does picking a finished variant later
and latticing it then; that path checks that the restored design gives back
*exactly* the same strength number the original run recorded, and refuses if it
does not.

Nothing you already had changed. Runs without a design box produce the same files,
byte for byte, down to the meshes.

**There is one decision I did not make for you.** When the optimizer adds material
outside your original part, should that new material be latticed, or stay solid?
Right now it stays solid, because that is the safe answer — solid is always
stronger than lattice, so the strength number can't be flattering. But on the test
part, that new material is **56% of the object, and 69% once you count the rule
that keeps whole lattice cells solid** (a cell is the smallest thing the generator
can place, so a cell that is part new material has to be all-or-nothing). So you
would be getting a lattice inside your original plate and solid plastic everywhere
the optimizer grew, which may be the opposite of why you asked for a lattice.
Every certificate now prints both percentages so you can see what it is costing on
your own parts. Changing the answer is one line; I have left it where it is until
you say.

**Two bugs the review caught, both mine, both fixed.** The first was the worse
one: the certificate was quietly describing a different object than the file. It
said "this material is kept solid", but the strut generator had never been told,
so it filled those places with struts *and* the solid was written on top — the two
were laid over each other. On the test part that was most of the file. It is fixed,
and there is now a check in every certificate that counts the cells the generator
actually wrote and the cells the certificate says are latticed, and refuses to
agree unless the two numbers match. On the test part: 16 and 16, and zero places
where both a strut and solid were written.

The second: asking for a plain re-check of a part (no smoothed mesh handed in)
while a design box was set would have measured the *whole box filled with plastic*
instead of your part. Also fixed, and now checked by asserting that the answer with
a design box and the answer without one are identical to the last digit.

Two other things you should know:

1. Re-certifying a *smoothed* design-box part used to quietly measure only the
   part-shaped half of it — it reported half the weight of the object it was
   handed. That is fixed, and the strength number it prints is now about 4.5×
   smaller because it is finally about the whole object. The verdict did not
   change on the test part, but on a part sitting near your strength threshold it
   could, and it would be the honest answer replacing a wrong one.
2. There is a separate, older bug I found and did **not** touch: if a keep-clear
   sticks out into the design box's empty growth space *and* the run has no
   declared load (self-weight only), the solver fails with "under-constrained
   system". It fails the same way without any lattice involved, so it is not part
   of this work, and fixing it could move strength numbers on runs that currently
   succeed — which is your call, not mine. Your keep-clears with a declared load
   are fine.
