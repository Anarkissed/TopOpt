# evidence — lattice-recipe-not-triangles (2026-08-07)

Scoping and measurement only. `git diff main -- core/src app/TopOptKit/Sources`
is empty; see `r2_no_production_change.txt`.

Branch `claude/lattice-recipe-triangles-d64151`, branched from `ea45f7c`
(`origin/main`, PR 310).

## The run everything is measured on

The maintainer's captured job document,
`evidence/2026-08-04-protect-freeze-vs-solidity/job_maintainer.json` +
`M2_verticalStand.step`, at his resolution 128, four rungs
`[0.68, 0.52, 0.38, 0.26]`.

**Two deviations from the captured document, both forced, both stated:**

1. **`"skin": "none"`** instead of his `"rim"`. Since PR 302 a `skin` other than
   `"none"` that emits zero rim/skin triangles is refused, and that fires on
   every voxel-silhouette part — his job included. Measured: the first attempt
   aborted with *"lattice `skin`: `rim` produced NO geometry on this part"*
   after the vf=0.68 variant (`run_2mm_first_attempt.log`). `"none"` is the only
   setting under which his job runs at all today.
2. **`grading.cell_min_mm: 2.0`** instead of his `4.602619931809993`. As
   captured, the job now hits PR 310's pre-flight refusal in 0.39 s — *"5 of 8
   declared lattice include regions are too thin for the planned 4.602619932 mm
   cell"* (`run_refusal_as_captured.log`). The refusal's own remedy is
   *"SET cell size between 1.094961872 mm and 4 mm"*; 2.0 mm is inside it.

**The reproduction is therefore of his JOB, not of his RUN's cell.** His stated
129,195 cells / 102,972,348 triangles need a cell near the 1.095 mm printability
floor, not 2 mm — see "reconciliation" below. What this branch measures exactly
is **the recipe**, whose size does not depend on the cell at all.

## Files

| file | what |
|---|---|
| `s1c_consumers.md` | **the deliverable** — every consumer of the lattice triangles, with file:line, and whether it needs triangles |
| `r3_consumer_sweep.sh` / `.txt` | the exhaustiveness sweep behind it (4 source references repo-wide) |
| `s1_recipe_vs_expansion.py` | weighs the recipe against the expansion from a run's own artifacts |
| `s1_recipe_vs_expansion.txt` / `.csv` | its output on the run above |
| `s2_scope.md` | the three routes scoped and costed, with a recommended order |
| `s2a_make_lattice_variant_job.py` | builds a `lattice_variant` job from {job document, `design.bin`} — the deferred-materialisation path, nothing else |
| `s2_probes.sh` / `s2_probes.txt` | P1–P5: the on-demand round trip, and the refusals that block it |
| `s2a_blocker_reproduction.txt` | **the blocked-stop** — `lattice_variant` refuses all four rungs of the run it came from |
| `r2_no_production_change.txt` | the empty diff |
| `job_his_2mm_skinnone.json` | the job actually run (his document + the two deviations) |
| `run_his_2mm_skinnone.log` | the 3823 s four-rung run everything above is measured on |
| `run_2mm_first_attempt.log` | deviation 1 — the `skin: "rim"` abort |
| `run_refusal_as_captured.log` | deviation 2 — his document unmodified, refused in 0.39 s |

## S2 — what the probes found

| probe | result |
|---|---|
| **P1** materialise on demand (`lattice-variant`, emit STL) | **REFUSED** after 98.46 s — margin reproduction, see below |
| **P2** same recipe, `emit_stl: false, emit_3mf: false` | **REFUSED** at schema validation in 0.04 s — *"lattice block requests neither STL nor 3MF output"*. There is no way to ask core for a receipt without a mesh. |
| **P3** `cell_mode: fit` | refused — *"grading `cell_min_mm` / `cell_max_mm` are only allowed with `cell_mode`: `swept`"*. That was a bug in `s2a_make_lattice_variant_job.py` (it carried the swept window across a mode switch); fixed, but P3–P5 all reach P1's blocker anyway. |
| **P4/P5** pinned 2 mm / 1.094961872 mm | not reached — same blocker |

### ★ The blocker

`lattice_variant_job` re-solves the stored design and demands
`margin.worst_case == sd.margin_worst_case` — a bare `==` on a `double`
(`core/src/cli/run_job.cpp:5410-5411`). Built from nothing but the run's own job
document and its own `design.bin`, **all four rungs are refused**:

| vf | recorded | reproduced | relative Δ |
|---|---|---|---|
| 0.68 | 3254.356637 | 3254.356646 | 2.77e-09 |
| 0.52 | 3389.417071 | 3389.417070 | 2.95e-10 |
| 0.38 | 3290.912400 | 3290.912403 | 9.12e-10 |
| 0.26 | 3014.120054 | 3014.120050 | 1.33e-09 |

Systematic, not flaky: vf=0.68 reproduced 3254.356646 on two separate runs. The
difference is warm-started (in-ladder) versus cold (standalone) certification.

## S1(a)/(b) — the recipe against the expansion, measured

Grid `128 × 31 × 118` = 468,224 voxels, spacing 1.70528 mm.

**The recipe** — what core would have to keep:

| part | bytes | note |
|---|---|---|
| job document (topology, cell mode + window, skin, 9 regions, load case) | 3,941 | the whole file, not an extract |
| `design.bin`, per variant | 3,745,888 | 96 B header + 468,224 × f64 |
| `design.bin`, four rungs | 14,983,608 | validated to the byte: `56 + 4 × 3,745,888` |
| **MINIMAL recipe (job + design.bin)** | **14,987,549** | **14.29 MiB** |
| + derived per-cell layer (1-bit occupancy over the cell block, f32 ρ per latticed cell) | +126,216 | self-contained: 15,113,765 B = 14.41 MiB |

**The expansion** — what the run actually wrote:

| variant | cells | cell mm | file triangles | of which struts | lattice STL bytes | recipe ratio |
|---|---|---|---|---|---|---|
| variant_026 | 157 | 2 | 277,044 | 109,084 | 13,852,284 | 3.7× |
| variant_038 | 411 | 2 | 473,816 | 307,624 | 23,690,884 | 6.3× |
| variant_052 | 805 | 2 | 799,188 | 644,364 | 39,959,484 | 10.7× |
| variant_068 | 767 | 4 | 766,532 | 619,232 | 38,326,684 | 10.2× |
| **RUN** | **2,140** | | **2,316,580** | **1,680,304** | **115,829,336** (110.46 MiB) | **7.7×** |

The solid companion shell IS a mesh and STAYS one: `variant_XXX.stl` totals
62,080,536 B / 1,241,604 triangles across the four rungs, and the recipe keeps
it as-is.

**★ The recipe's size does not depend on the cell.** It is indexed per VOXEL
(the design field) and per JOB (the lattice block); the derived per-cell layer
is 4 bytes a cell. The expansion is indexed per STRUT and grows as (1/cell)³.
So the same ~15 MB recipe describes this 116 MB run and the maintainer's 5.1 GB
one:

| | expansion | recipe | ratio |
|---|---|---|---|
| this reproduction (2 mm/4 mm cell) | 115,829,336 B | 14,987,549 B | **7.7×** |
| his run, 102,972,348 triangles / ~5.1 GB (his figures) | ~5,100,000,000 B | 14,987,549 B | **~340×** |

## S1(d) — what re-deriving costs

`run_info.lattice_export.gen_seconds` = **0.6314112926 s** for all four rungs —
**gen_fraction 0.0001657785515**, i.e. **0.017 %** of the 3823.38 s run.
That is 1,680,304 strut triangles at **2.66 M triangles/s**.

Cross-checks on the same generator:
* his run: 102,972,348 triangles in 21.3 s = **4.83 M tri/s**
* `evidence/2026-08-05-lattice-cell-fit-mode/r6_cost.txt`: 1,675,088 in 0.389 s
  = **4.31 M tri/s**

**Re-deriving the geometry costs seconds against a run that costs an hour.**

## Reconciliation — why this run is 2,140 cells and his is 129,195

Both his figures and this run give the same triangles-per-cell (his 102,972,348
/ 129,195 = **797**; measured here 807 / 800 / 748 / 800 per rung), so the
generator is the same and the difference is entirely the cell.

His cell count is 60× this run's. Cells scale faster than (1/cell)³ because a
finer cell also clears the cells-per-member floor in more members, so more of
the part is latticed — measured previously at 3.83× triangles for a 2.50× finer
cell (`r6_cost.txt:32`). His figures land at the printability floor his own
refusal quotes, 1.094961872 mm, and the same prior evidence measured **152.3 MB
for the heaviest rung at 1.0950 mm on a res-48 seven-4-mm-region job**, which at
his res 128 scales to the ~1.28 GB/rung his 5.1 GB implies.

**This was not re-measured end-to-end on his part.** Doing so needs another
64-minute optimize run, and the two refusals in `s2_probes.txt` block the cheap
route (re-lattice from `design.bin`). What the ratio above needs from his run —
the recipe size — is measured exactly, because it is cell-independent.
