# lattice-as-a-material — evidence

Handoff: `docs/handoffs/2026-08-13-lattice-as-a-material.md`.

★ **`r0_preregistration.md` was committed BEFORE the first arm ran** (commit
`00eff24`). At that commit this directory contains that file and nothing else.
Every bound in it stands as written; none was retuned.

## What is here

| | |
|---|---|
| `r0_preregistration.md` | the bounds, and the stop rule |
| `m0/law.txt` | **M0** — the ρ→stiffness law: the fit, the Gibson-Ashby comparison row by row, and the validity range in cells per member |
| `m1/regions_provenance_r0.68.txt` | **M1** — his frozen set decomposed by PROVENANCE (which declaration froze each voxel), each region's strain energy and peak macro von Mises off ONE certification solve, the QUIET / LOAD-BEARING split, and the per-region validity |
| `m1/regions_r0.68.txt` | ★ the SUPERSEDED first cut, kept as the record. It keyed regions on 26-CONNECTIVITY, which fused face 16's protection collar with the load-face pads and attributed the pads' stress to the wall. **Do not quote its per-region stress.** `--regions connectivity` reproduces it |
| `m2/assign_r*.txt`, `m2/r*/m2_assignment.csv` | **M2** — the Mode 1 assignment table, one certified analysis per cell |
| `r7_assertion_census.txt` | R7, as a MESSAGE census against the merged `main` |
| `assertion_census.sh` | the census, re-runnable |
| `queue.sh` | the measurement queue, in the pre-registered order, strictly serial |

## How to reproduce

```sh
cmake -S core -B build
cmake --build build -j3 --target frozen_lattice_probe
sh evidence/2026-08-13-lattice-as-a-material/queue.sh
```

★ **Bar R1 is NOT in this queue, and that is deliberate.** "Byte-identical" is
scale-independent, so it is a registered ctest on a synthetic wall
(`frozen_lattice_c0`) that runs in seconds on every build, rather than a pair of
ladder runs on his part. `ctest -R frozen_lattice_c0`.

Nothing is cloned and nothing is downloaded. The only inputs are his STEP
(`evidence/2026-08-09-reference-implementation-bakeoff/M2_verticalStand.step`),
his converged SIMP rungs (that directory's `s2_simp_baseline/design.bin` — the
same baseline every arm since PR 322 has been measured against), and this
repository's own sources.

## ★ What one row costs, and why the campaign is capped

**590.6 s** — one certification of his rung 0.68, isolated (recycling off, GenEO
off, FP64, the tight `cg_tolerance`), at 8 threads. Measured, in `m1`.

That is the unit cost of every cell of the assignment table, so the brief's ~20
certified runs is a multi-hour campaign and its two-rung requirement doubles it.
`queue.sh` therefore takes `M2_REGIONS` and `M2_DENSITIES` from the environment,
so a cap is on the command line and in the record rather than hidden in a
default — and the probe **prints the regions it skipped**, because a table that
silently omitted them would read as though they had been measured.

★ Arming the production posture for these solves makes it **worse**, not better:
a cold standalone certification pays GenEO's whole coarse-basis build with
nothing to amortise it over. The first cut of this probe was sampled sitting
inside `geneo_engage_now` after 51 minutes of CPU without reaching its first
certificate. See the handoff §0.6.

## The threads

**3 by default in `queue.sh`** — he needs his Mac. It cannot change an answer:
the matrix-free apply threads a deterministic 8-colour partition whose
accumulation order is set by the colour scheme and not by the thread count
(`fea.hpp`, `fea_set_matfree_threads`). The runs recorded here were taken at 8
on an otherwise idle machine and their WALL CLOCK is not comparable to a 3-thread
run's; every other number is.
