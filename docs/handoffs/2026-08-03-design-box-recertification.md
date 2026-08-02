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
| `analyze_job` design grid | `voxelize_onto_grid(mesh, model_grid)` | onto the SOLVED grid — it was silently CLIPPING a design-box mesh at the part's bounding box |

The last one is measured below and matters.

---

## *** THE DECISION YOU HAVE TO MAKE — I have NOT made it ***

With a design box the optimizer grows material where the original part was not.
Nothing in the generator or the gate has an opinion about what should happen to
that material when the variant is latticed. **On the specimen below it is 55.7% of
the printed object.** The three answers are different objects:

**KEEP SOLID — what ships today, as a placeholder.** The added voxels are dropped
from the certification mask, so they are certified SOLID and exported as the solid
companion body. Most conservative: solid is stiffer and stronger than lattice at
the same geometry, so no margin here is optimistic, and the certified object is
exactly the exported file (one mask governs both, as everywhere else). Cost: mass
— you get a lattice inside the part you imported and solid everywhere the
optimizer added. On the specimen that means **302 mm³ / 716 voxels of solid you
may not have wanted**, and the lattice covers only 44% of the object.

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
  `12121.61941` from the optimize path and from `lattice_variant_job`, compared as
  the two receipts render it (same emitter, same precision — a textual identity).

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
solid margin 1.601e+04 -> latticed margin 1.212e+04
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

### AI3 — no-design-box paths byte-identical

Stash-rebuild: `git stash` → build HEAD → save the binary → restore → build →
run both binaries over the same jobs. `evidence/.../byte_identity.txt`.

Every artifact of the **no-design-box + lattice** run and of the **design-box,
no-lattice** run is byte-identical: `design.bin`, `fields.bin`, `report.json`,
`loadcase.json`, every `variant_*.stl`, every `*_lattice.stl`, every
`*_lattice.report.json`. So is the no-box `analyze --smooth` run
(`analysis_report.json`, `fields.bin`, the smoothed STL). `iterations.csv` matches
on every physics column (the differing columns are `wall_ms` and the `*_ms`
timings); `build_orientation.json` differs only in `sweep_seconds`;
`run_info.json` carries its documented wall-clock stamp. `analysis.json` differs
only in the output-directory path it echoes back.

**ctest: 97/97 passing** (96 before; +1 for the new test).

### AI4 — full gate table, before and after, every rung

`evidence/.../gate_tables.txt`. Condensed:

| job | rung (printed fr) | HEAD | NEW |
|---|---|---|---|
| A no box + lattice | 0.8025723 | ACCEPTED 34732.24587 | ACCEPTED 34732.24587 |
| | 0.7279743 | ACCEPTED 31991.90649 | ACCEPTED 31991.90649 |
| | 0.5903537 | ACCEPTED 28597.06713 | ACCEPTED 28597.06713 |
| B design box, no lattice | 0.4135048 | ACCEPTED 16013.15016 | ACCEPTED 16013.15016 |
| | 0.2334405 | ACCEPTED 10180.36257 | ACCEPTED 10180.36257 |
| | 0.1157556 | ACCEPTED 7475.920599 | ACCEPTED 7475.920599 |
| C box + 4 keep-clears + lattice | all 4 | **REFUSED** | ACCEPTED 7.2386 / 8.0254 ×3 (required 1.5) |
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
measurement, not a blind spot.

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

| specimen | printed | inside part | outside | outside % | kept solid | volume |
|---|---|---|---|---|---|---|
| D box + self-weight, vf 0.80 | 1286 | 570 | **716** | **55.7%** | 716 | 302.06 mm³ |
| E the same design re-latticed | 1286 | 570 | 716 | 55.7% | 716 | 302.06 mm³ |
| C box + keep-clears + declared load, vf 0.68 | 2064 | 2064 | 0 | 0.0% | 0 | 0.00 mm³ |

The counts partition the printed set exactly (`inside + outside == printed`,
asserted). Under the shipped policy every outside voxel is dropped from the
lattice mask and picked up by the solid companion body — asserted too, so material
can never be certified solid and then omitted from the file. C growing nothing
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
part, that new material is **56% of the object**. So you would be getting a lattice
inside your original plate and solid metal-thick plastic everywhere the optimizer
grew, which may be the opposite of why you asked for a lattice. Every certificate
now prints that percentage so you can see what it is costing on your own parts.
Changing the answer is one line; I have left it where it is until you say.

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
