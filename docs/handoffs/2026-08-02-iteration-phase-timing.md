# Per-phase timing for the design iteration — finding the missing 410 s

**Task:** `iteration-phase-timing` · **Evidence:** `evidence/2026-08-02-iteration-phase-timing/`
**Kind:** DIAGNOSTIC. Adds measurement; changes no behaviour, no default, no gate,
no solver. Proven bit-identical (§Y1).

---

## The answer, first

The 410 s is **the GenEO two-level deflation's coarse-space work**, and it is
invisible to `cg_iters` because it happens *outside the CG recurrence*.

Reproduced on a design-box ladder whose multigrid latched OFF — the maintainer's
rung-3 state exactly (`hier_built=0`, `cg_multigrid=0`, plain Jacobi-CG). **56
latched iterations of 64, 851.0 s of wall:**

| phase of a latched iteration | wall | share |
| --- | ---: | ---: |
| **CG recurrence** — what `cg_iters` describes | 101.8 s | **12.0 %** |
| **GenEO coarse-operator setup** (refresh, or full LOBPCG rebuild) | 465.3 s | **54.7 %** |
| **GenEO coarse correction**, summed over CG iterations | 221.1 s | **26.0 %** |
| Krylov recycle setup + augmentation | 61.6 s | 7.2 % |
| reduced-system build | 0.2 s | 0.0 % |
| **residual — unattributed** | **0.0 s** | **0.0 %** |

Nothing is missing. **87.9 % of a latched iteration is accelerator overhead that
the iteration counter cannot see**, and the residual column — the whole point of
the instrument — reads zero, so there is no second, unnamed culprit.

Scale that to the maintainer's rung 3 (449 s/iteration): ~395 s of the ~410 s
unattributed is GenEO + recycling. The measured ~30 s of CG work is the 12 %.

**Why this was invisible.** The GenEO arming handoff says so in its own words:

> "several campaign runs shared the host, so **NO wall ratio is cited as
> evidence** — the deterministic CG counts are the signal"
> — `docs/handoffs/2026-07-29-geneo-arming.md`, §Machine

That was the right call for a shared host. But it means the accelerator was armed
on an **iteration-count** measurement, and on this path *iteration count is not
cost*. The refresh runs `N_t` full operator applies **before iteration 1**; the
correction more than triples the price of every iteration after it. Neither moves
`cg_iters` by one.

**The memory hypothesis is dead** (§Y4): peak RSS 372 MB against 3.7 GB available,
major faults **flat** across every iteration, swapins **0**. The machine was not
paging. It was computing.

---

## 1. What was built

`iterations.csv` carried one `wall_ms` per iteration — an **epoch timestamp, not a
duration** (a name that predates any duration on that row) — and no breakdown at
all. `minimize_plastic.cpp` contained no timing calls. So the question could not
be answered from any artifact on disk; it had to be measured.

### 1a. Per-phase wall timing → 28 new `iterations.csv` columns

| column group | columns |
| --- | --- |
| the iteration's own wall | `total_ms`, `tail_prev_ms` |
| named phases | `filter_ms`, `project_ms`, `solve_ms`, `update_ms`, `analysis_ms`, `observe_ms` |
| **the point** | **`residual_ms`** |
| solve split (SUB-split, not extra terms) | `fea_ms`, `sens_ms` |
| solver-internal split (SUB-split) | `solver_build_ms`, `mg_build_ms`, `mg_ms`, `cg_ms`, `geneo_setup_ms`, `geneo_apply_ms`, `recycle_ms` |
| work counters | `fea_solves`, `matvecs`, `geneo_dim`, `geneo_action` |
| process memory | `rss_mb`, `peak_rss_mb`, `compressed_mb`, `available_mb`, `major_faults`, `swapins` |

**The accounting is exact and closes.**
`total_ms == filter + project + solve + update + analysis + observe + residual`,
asserted on every row of a live run in `test_observability_capture` to within the
0.005 ms the `%.3f` format can express. Every term is a difference of two reads of
the *same* steady clock, so the identity is structural, not approximate.

`total_ms` runs from the top of the optimizer's loop body to the moment the
observation is handed to the sink. Everything after that — keyframe, density
snapshot, plateau/continuation logic, and the caller's own CSV write — is carried
on the **next** row as `tail_prev_ms`, because the previous row was already on disk
when it was spent. `sum(total_ms + tail_prev_ms)` over a rung is that rung's wall.

**No phase was hoisted or reordered to make it easier to time**, and spans are
taken with explicit start/stop marks rather than a rolling lap — so code *between*
two phases stays unattributed and lands in `residual_ms`. A rolling lap would have
silently folded those gaps into whichever phase ended next, which is precisely the
failure this instrument exists to avoid. **The BLOCKED-STOP condition did not
arise**: the iteration loop's structure is unchanged.

### 1b. Process memory per iteration

`topopt::process_memory()` (`observability.hpp`) — `getrusage` for the high-water
resident size and major fault count; on macOS `task_vm_info` for `phys_footprint`,
compressor holdings and the `ledger_swapins` counter, plus `host_statistics64` for
host availability. Linux gets `/proc/self/statm` + `MemAvailable`.

A field the platform cannot answer is **negative, never zero**. "Unavailable" and
"measured no swapping" are different facts, and the entire paging question turns on
that distinction.

### 1c. Solve count and operator applies

- `simp_compliance_call_count()` — bumped on **every** penalized solve. Its delta
  across one design iteration *is* the FEA-solve count.
- `fea_matvec_count()` — bumped in `MatfreeReduced::apply_kgg_raw`, the one apply
  every matrix-free caller routes through (CG recurrence, V-cycle smoother, recycle
  setup, **and the GenEO refresh**). It is the honest work unit when `cg_iters` is
  not.

**Asserted answer: exactly ONE FEA solve per design iteration.** Pinned on live
rows in `test_observability_capture`; `fea_solves` reads 1 on every trajectory row
of every run made for this task. **A second hidden solve is NOT the explanation** —
that possibility is now closed by measurement rather than by reading the call graph.

What *is* hidden is arithmetic, and the counter shows it. Across the 56 latched
rows of the reproduction, `matvecs / cg_iters` has median **2.4x** and reaches
**9.8x** — e.g. rung 0 iteration 12: `cg_iters` 406, `matvecs` 1147, because the
GenEO refresh runs `N_t` (646–823) operator applies that move no CG counter.
`cg_iters` under-reports this path's operator work by up to an order of magnitude.

---

## 2. Y3 — the anomaly reproduced and attributed

**Fixture:** `core/tests/fixtures/demo/l-bracket.step`, res 32, whole-domain design
box 80 × 55 × 70 mm (9.24 part-volumes), production ladder `[0.68, 0.52, 0.38,
0.26]`, `simp.max_iterations` 16. Job committed as
`evidence/…/ladder32.json`. Production posture armed by the CLI exactly as the
maintainer's run: matrix-free multigrid, GenEO two-level ON (trigger 500, rebuild
factor 2), Krylov recycling k=16 Jacobi-only, active domain disarmed.

The maintainer's build fingerprint `9f6738726016` is commit `9f67387`
(build-direction-separation merge), two commits behind this branch — the same era,
same armed posture.

**The signature reproduced.** Rung 0's `hier_built` column reads
`11111111` then `0` for its remaining 24 iterations, and rung 1 reads `0` on all
32: from iteration 9 the 127 stagnation latch fires, multigrid is off for the rest
of the run, and every solve is plain Jacobi-CG with no stagnation noise. That is
the maintainer's rung-3 state exactly.

**The run ended early, and honestly:** after rung 1 it aborted in the
certification with `recommend_settings: worst_case_stress_margin must be finite
and >= 0` — an ultra-dilute whole-domain design carries no stress, so its margin
is +inf and the whole CLI run dies instead of that rung being rejected. Rungs 2
and 3 were not reached. **This is PRE-EXISTING and not caused by this change**:
the stash-rebuilt pre-instrumentation binary aborts identically on the same
pathology (`evidence/…/abort20.json`, both transcripts in
`ladder32_phase_summary.txt`). It is a real defect and worth its own task; it does
not touch the attribution, which rests on the 56 latched iterations that did run.

Representative latched iterations:

| rung 0 iter | `cg_iters` | total | `cg_ms` | `geneo_setup_ms` | `geneo_apply_ms` | action | `N_t` |
| ---: | ---: | ---: | ---: | ---: | ---: | :--- | ---: |
| 9  | 1203 | 9.48 s | 1.98 s (21 %) | 2.26 s (24 %) | 4.16 s (44 %) | refresh | 658 |
| 12 | 406  | **41.4 s** | 0.77 s (**1.8 %**) | **38.4 s (92.6 %)** | 1.64 s | **rebuild** | 723 |
| 14 | 440  | **48.2 s** | 0.86 s (**1.8 %**) | **44.9 s (93.1 %)** | 1.73 s | **rebuild** | 712 |
| 17 | 118  | 4.08 s | 0.22 s (5.5 %) | 2.96 s (72 %) | 0.46 s (11 %) | refresh | 712 |
| 20 | 1644 | 48.4 s | 3.16 s (6.5 %) | 35.7 s (74 %) | 7.71 s (16 %) | rebuild | 823 |

`residual_ms` on these rows: **0.03–0.34 ms**. Nothing unattributed.

Over all 56 latched rows: `cg_iters` median **562** (range 96–3316); GenEO refresh
n=48, median **3.6 s**; full LOBPCG rebuild n=8, median **38.4 s**; `N_t` 646–823.

### The two mechanisms, named

**(1) The coarse-operator refresh, once per fallback solve, before iteration 1.**
`geneo_solve_begin` keys on a moduli fingerprint. The per-voxel penalised modulus
changes *every design iteration by construction*, so the fingerprint always
differs and the refresh is **mandatory on every single fallback solve**.
`build_coarse_operator` costs `N_t` full operator applies plus an `N_t²` Galerkin
assembly. Measured median **3.6 s** per refresh here (48 refreshes, `N_t` 646–823).

Every ~6–7 iterations the degradation trigger (`kGeneoRebuildFactor = 2.0`) instead
schedules a **full LOBPCG rebuild**: measured median **38.4 s** over 8 rebuilds,
i.e. **50x** the CG recurrence it is accelerating on the same row.

The header comment calls the refresh "the cheap coarse-operator refresh". Relative
to the eigensolve it is (3.6 s vs 38 s). Relative to *the CG recurrence it
accelerates*, it is not: on iteration 17 the refresh cost **13x** the entire CG
solve.

**(2) The coarse correction, on every CG iteration.** Measured per-CG-iteration
cost, medians over the 56 latched rows:

- bare Jacobi recurrence: **2.05 ms/iteration**
- GenEO coarse correction: **4.70 ms/iteration**

A deflated iteration costs **3.3x** a bare one. So the deflation must cut the
iteration count by more than 3.3x *just to break even on the per-iteration price*,
before paying for any setup at all.

### What this does NOT settle

Whether GenEO is net-positive in **wall** on this path. That needs a control run
with the deflation disarmed, and disarming it is a change to a production default —
out of scope here (this task adds measurement only). **This is the obvious next
task**, and the numbers above are what it should be sized against: it must beat a
3.3x per-iteration handicap plus 3.6 s/solve of setup (38 s on a rebuild
iteration).

The 21.7x iteration-count win the arming measured may well survive that. It also
may not. Nobody has measured it, and the instrument to do so now exists.

### Healthy-regime control (same instrument, same day)

The 48-scale gate fixture, multigrid carried on 180/180 solves, 69.6 s:

| phase | share |
| --- | ---: |
| `solve_ms` | 98.75 % |
| ├ `mg_build_ms` (hierarchy build, **rebuilt every iteration**) | 26.41 % |
| ├ `mg_ms` (V-cycles) | 71.37 % |
| └ `sens_ms` (adjoint) | 0.49 % |
| `update_ms` (OC/MMA + volume bisection) | 1.01 % |
| `filter_ms` | 0.17 % |
| **`residual_ms`** | **0.01 %** |

Two readings worth keeping:
- **The self-adjoint sensitivity is free** — 0.49 %. Compliance is self-adjoint;
  there is no separate adjoint solve, and now the CSV says so rather than leaving
  it to be assumed.
- **A quarter of a healthy run's wall is the multigrid hierarchy build**, paid from
  scratch on every iteration. That corroborates the older "design-box solve cost is
  the BUILD" finding and is a second, independent lead — a *separate* task.

---

## 3. Y4 — the memory hypothesis, settled

**Not paging. The finding is compute, not swap.**

Machine of record: Apple M2 Pro, 16 GB, macOS 25.5.0.

| reading | latched reproduction | healthy gate fixture |
| --- | ---: | ---: |
| peak RSS | **372 MB** | 142 MB |
| host available (min over the run) | 3679 MB | 4315 MB |
| `major_faults` (first → last iteration) | **959 → 959, FLAT** | 517 → 521 |
| `swapins` | **0 → 0** | 0 → 0 |
| process compressed pages | 0 → 178 MB | 0 |

Peak RSS is **10 %** of available memory, and the two counters that would move if
the kernel were fetching pages from backing store — major faults and swapins —
**do not move at all** across 48 latched iterations. The 14x slowdown happens on a
process that never waits on the disk.

**Honest limit of this evidence.** The reproduction is res 32 (solved grid
48×32×40, `N_t` ≈ 700–800), not the maintainer's 128³ with its 313 MB GenEO basis.
I did not reproduce their footprint, and I do not claim their machine was not under
pressure. What I claim is narrower and enough: **the 14x-at-identical-arithmetic
signature is fully explained by compute that the instrument now names, with a zero
residual — so memory pressure is not needed to explain it.** If their run *was*
also paging, that is an additive second problem and the same CSV will now say so on
the very first re-run, because `peak_rss_mb`, `major_faults` and `swapins` are on
every row.

---

## 4. Y5 — the volume-target "miss", reported not fixed

**`achieved_vf` and the ladder target are on DIFFERENT DENOMINATORS. Rung 3 did not
miss its target by 37x; it was reported against a different base.** No metric was
changed.

- **`iterations.csv` `achieved_vf`** = `sum(rho over Active) / n_active`, on the
  **SOLVED (design-box) grid** — the Active envelope. (`active_volfrac` in
  `core/src/simp/simp.cpp`.)
- **The ladder's `vf`** is a fraction **of the original PART**. On the whole-domain
  box path (`freeze_imported_part == false`, the CLI default) `minimize_plastic`
  rescales it before handing it to the optimizer:

  ```
  opt.volume_fraction = (vf * P − F) / A
      P = part_solid       solid voxels of the ORIGINAL part grid
      A = active_effective solved-grid voxels the constraint moves
      F = frozen_effective solved-grid voxels effective_mask pins solid
  ```

`A == n_active` exactly (same set, same exclusions), so once the volume constraint
is met `achieved_vf` **equals** `(vf·P − F)/A`, not `vf`.

Counted directly for the reproduction geometry (`volume_basis_probe`, read-only —
it voxelizes and counts, never solves):

```
part grid   : 32x22x32, solid P = 4992 voxels
solved grid : 48x32x40
active A    = 46107   frozen F = 32      A/P = 9.236   F/P = 0.0064

rung  ladder vf  effective target (vf*P−F)/A   ratio vf/effective
 0      0.68            0.072929                    9.3
 1      0.52            0.055606                    9.4
 2      0.38            0.040449                    9.4
 3      0.26            0.027456                    9.5
```

The "miss" is `A/P` — how many part-volumes the design box is. It grows down the
ladder because `F` is subtracted *before* dividing.

**Applied to the maintainer's two reported pairs** (rung 0: target 0.68 → 0.039;
rung 3: target 0.26 → 0.0071), solving for the two unknowns gives
**A/P ≈ 13.2, F/P ≈ 0.167** — a box ~13 part-volumes with a frozen anchor/BC set
~17 % of the part. Both readings then sit exactly on their rescaled targets, i.e.
**the constraint was met on both rungs.**

Stated honestly: with only two reported pairs that fit is *exactly determined* and
therefore not an independent check — it shows consistency, not proof. The proof of
the *mechanism* is the direct count above. Two structural facts back it up: the MMA
volume constraint is enforced by a **dual bisection every single step**, so a rung
cannot sit 37x off its own effective target for 21 consecutive iterations; and
`report.json`'s `volume_fraction` on the box path is separately overwritten to the
part-relative *printed* fraction, so the report and the CSV are on different bases
**by construction**.

**Two reader traps found on the way, neither fixed here:**

1. `report.json` (part basis) and `iterations.csv` (envelope basis) disagree on a
   box run by design. Nothing labels which is which.
2. During a **conditional-projection** phase, `achieved_vf` reports the
   **unprojected** filtered fraction while the constraint is enforced on the
   projected field, so the column jumps upward mid-rung. In the reproduction rung 0
   ends its grayscale phase at 0.0545 and its projection phase at 0.0781 — same
   design, two different numbers.

Both are reporting-legibility defects, both out of scope for a diagnostic task, and
both belong in a follow-up that labels the basis on the column rather than changing
it.

---

## 5. Bars

### Y1 — behaviour is unchanged ✔

Stash-rebuild: the pre-instrumentation tree built into a separate build dir, same
compiler, same `CMAKE_BUILD_TYPE=Release`; same job
(`core/tests/fixtures/demo/job.json`, STL output; 3 rungs, 180 iterations).

| artifact | OFF vs ON |
| --- | --- |
| `report.json` | **IDENTICAL** |
| `fields.bin` | **IDENTICAL** |
| `variant_070.stl` / `variant_050.stl` / `variant_030.stl` | **IDENTICAL** |
| `build_orientation.json` | differs — **pre-existing**, see below |

`build_orientation.json` differs on *every* pair including ON-vs-ON2, because it
records the orientation sweep's own wall time (`sweep_seconds`,
`strut_axis_measure_seconds`). Not caused by this change; reported rather than
hidden.

**ctest: 91 tests, 91 passed** (`evidence/…/ctest.txt`, 1360 s). Two
tests were updated because they pin the CSV schema by design
(`test_observability` golden rows, `test_observability_capture` header) — and both
gained assertions rather than losing any: the golden row now pins a full phase
breakdown, and the capture test now asserts, on live rows, that the accounting
closes and that exactly one FEA solve runs per iteration.

### Y2 — the overhead is negligible and measured ✔

**Bar stated before measuring** (in `phase_timing_overhead_probe.cpp`, unedited):
*< 0.1 % of a design iteration's wall.* Rationale: the smallest production
iteration this codebase produces is ~275 ms, so 0.1 % is 275 µs; anything inside
that cannot perturb a run anyone cares about.

Measured on the machine of record: one `steady_clock_ms()` = **21.6 ns**, one
`process_memory()` = **1.73 µs**. The executed path takes **50** clock reads + 1
memory sample per iteration = **2.8 µs fixed** (counted term by term in the probe
source, not rounded). The Jacobi+GenEO recurrence adds 6 reads per CG iteration.

| regime | `cg_iters` | instrument | iteration wall | share |
| --- | ---: | ---: | ---: | ---: |
| MG carried (gate fixture) | 60 | 2.8 µs | 275 ms | 0.00102 % |
| MG carried (late rung) | 245 | 2.8 µs | 961 ms | 0.00029 % |
| Jacobi+GenEO, fewest CG iters | 96 | 15.2 µs | 4.74 s | 0.00032 % |
| Jacobi+GenEO, median CG iters | 562 | 75.6 µs | 52.3 s | 0.00014 % |
| Jacobi+GenEO, most CG iters | 3316 | 432.5 µs | 30.4 s | **0.00142 %** |

Worst case **0.00142 %** — 70x under the bar. The
instrument's only mechanism for perturbing a run is spending time; nothing it
records is read back by any solver or updater decision.

### Y3 — reproduced and attributed ✔ — §2.

### Y4 — memory settled ✔ — §3. Not paging.

### Y5 — volume basis reported, not fixed ✔ — §4.

### Y6 — determinism ✔

Two runs of the same instrumented binary on the same job produce **identical**
`report.json`, `fields.bin` and all three meshes. Same evidence file as Y1. The
timing columns themselves are wall measurements and of course differ run to run —
that is what they are for.

---

## 6. Files

**Instrument**
- `core/include/topopt/simp.hpp` — `IterationPhaseTimes` (the accounting contract),
  `SimpIterationObservation::phases`, `SimpCompliance::t_solve_ms/t_sensitivity_ms`,
  `simp_compliance_call_count()`.
- `core/include/topopt/observability.hpp` — `ProcessMemory`, `process_memory()`,
  `steady_clock_ms()`, the extended CSV schema doc.
- `core/include/topopt/fea.hpp` — `CgInfo::t_*_ms` + `matvecs`,
  `fea_matvec_count()` / `_reset()`.
- `core/src/simp/simp.cpp` — spans in both `simp_optimize` overloads (masked =
  production, unconstrained = pre-solve/fixtures) through the shared `IterSpans` /
  `finish_phases`; solve-vs-sensitivity split in `simp_compliance`.
- `core/src/simp/observability.cpp` — `process_memory()`, `steady_clock_ms()`, the
  28 new CSV columns.
- `core/src/fea/matfree.cpp`, `core/src/fea/multigrid.cpp`,
  `core/src/fea/fea_matfree.hpp` — the per-solve split (`MfCgTimes`), the matvec
  counter, hierarchy-build and V-cycle timing.

**Probes (not CI)**
- `core/tests/harness/phase_timing_overhead_probe.cpp` — Y2.
- `core/tests/harness/volume_basis_probe.cpp` — Y5, read-only.

**Tests updated**
- `core/tests/unit/test_observability.cpp` — golden row now pins the phase block.
- `core/tests/validation/test_observability_capture.cpp` — header from
  `kIterationCsvHeader`; **new** assertions that the accounting closes on live
  rows, that exactly one FEA solve runs per iteration, and that peak RSS ≥ current
  RSS wherever both were answered.

**Not touched:** fixtures, `materials.json`, `ARCHITECTURE.md`, `DECISIONS.md`, the
gate, the solver, any default, `/app/`.

---

## 7. What to do next (in order)

1. **Measure whether GenEO pays in WALL on the latched path.** It is armed on an
   iteration-count win with the wall explicitly not measured. It must beat a 3.3x
   per-iteration handicap plus 3.6 s/solve of setup (38 s on rebuild iterations).
   Needs a disarmed control run — a default change, hence its own task.
2. **The refresh cadence.** The moduli fingerprint changes every design iteration
   by construction, so the refresh is unconditional. Whether a coarse operator one
   MMA step stale is good enough is an empirical question nobody has asked.
3. **The multigrid hierarchy rebuild** — 26 % of a *healthy* run's wall, rebuilt
   from scratch every iteration. Independent of everything above.
4. **Label the volume basis** in `report.json` / `iterations.csv` (§4). Reporting
   legibility, not a metric change.
5. **A non-finite margin aborts the whole run** instead of rejecting the rung
   (§2). Pre-existing, reproduced on the pre-instrumentation binary, and the
   reason this task's reproduction never reached rungs 2 and 3.

---

## In plain language

A design iteration is one step of the optimiser: solve the physics, work out where
material wants to go, move it, repeat. On the maintainer's big run, twenty steps in
a row took about 7½ minutes **each** — while the one cost number we recorded, the
count of solver iterations, said they should have taken about half a minute. The
other seven minutes were unaccounted for. We could not find out where they went,
because nothing in the program had ever been asked to hold a stopwatch. The file we
write per iteration recorded *what time it was*, not *how long anything took*.

So we added the stopwatch. Every step now records how long it spent on each part of
its job — filtering, solving, updating the shape, writing its own log — plus a
final column that says **"and this much time went somewhere I can't name."** That
last column is the whole idea. If time is disappearing, the file has to admit it
rather than let someone work it out by subtraction years later.

Then we rebuilt the problem: a bracket inside a big empty design box, squeezed down
to almost nothing, until the solver hit the same trouble the real run did. The
stopwatch answered immediately, and the "can't name it" column read **zero**.

The time is going to an **accelerator we switched on last week**. When the fast
solver gives up on a very sparse shape, a helper called GenEO takes over. It works
— it genuinely cuts the number of solver iterations. But before each solve it has
to rebuild a summary of the whole structure, and every few steps it rebuilds that
summary from scratch, which took **38 seconds** on our small test while the actual
solving took **0.8 seconds**. And once it is running, it makes every solver
iteration about three and a half times more expensive. None of that shows up in the
number we were watching, because that number counts iterations, and this work
happens *between* and *around* them, never *in* them.

Why nobody caught it: when the helper was switched on, it was judged purely on
"does it need fewer iterations?" — and it does, by a lot. The person who made that
call wrote down, honestly, that they were deliberately **not** measuring elapsed
time, because the test machine was shared and the timings would have been
misleading. That was the right call at the time. It just left a gap: fewer
iterations does not mean less time when each iteration costs three times more and
comes with a 38-second setup fee.

We also checked the leading suspicion, that the computer had run out of memory and
was shuffling data to disk. It had not. The program used 372 MB with 3.7 GB free,
and the two counters that move when a computer starts swapping never moved once.
That theory is dead, and it is dead because of a number rather than an argument.

One more thing we cleared up. A rung of the run said it was aiming for 26 % material
and reported 0.71 % — a 37-fold miss that looked alarming. It is not a miss. The
target is "26 % of the original part", the report is "0.71 % of the big empty box
the part sits inside", and the box is about thirteen times the part. Two honest
numbers on two different scales, with nothing on the page saying so. We counted the
voxels and proved it; we did **not** change the number, because changing a metric to
make a report read better is how you lose the ability to compare it to last month's
run. It needs a label, not a new definition.

Nothing about how the optimiser behaves was changed. We checked that the hard way:
built the program from before these changes, ran the same job, and compared the
results byte for byte. The design, the physics fields and all three exported
3D-printable files come out **identical**. The stopwatch itself costs about two
millionths of a second per step — roughly one part in a hundred thousand of the
smallest step we ever run.

**What we did not settle**, and should say plainly: we found where the time goes,
not whether spending it is worth it. The accelerator might still be a net win —
fewer, more expensive iterations can beat many cheap ones. Answering that means
running the same job with it switched off and comparing the clock, and switching it
off changes how the product behaves, so it belongs in its own piece of work rather
than being slipped into a measurement task. The numbers it has to beat are now
written down.
