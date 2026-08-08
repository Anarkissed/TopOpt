# levelset-on-our-solver

Evidence: `evidence/2026-08-09-levelset-on-our-solver/` — `./reproduce.sh`
regenerates all of it, and nothing is cloned to do so.

## 0. THE THREE NUMBERS

A level set runs on our own solver, on his part, at rung 0.68, and finishes.

**1. Seconds per iteration: 25.09 s.** Against SIMP's 13.62 s at this rung and
GridapTopOpt's 277.73 s, both on the same grid on the same machine. **1.84x
SIMP, and 11.1x FASTER than Gridap.** PR 321's 25x was the library, not the
method, and this is how much of it was the library: all but 1.84x of it.

Two independent FP64 runs of the whole 120 iterations landed 25.054 s and
25.088 s per iteration and produced **byte-identical** designs, so the number is
not a single sample and the optimizer is deterministic.

**2. Cut-population roughness: 6.7080 deg against SIMP's 7.5521 deg — 11.2%
smoother.** Measured by `external_field_surface_probe`, the same binary that
produced PR 321's rows, invoked and not retyped, on a run that carries its own
four SIMP baseline rows. It is a real win and it is **a quarter of the win
Gridap's level set got** (4.0156 deg, 46.9%). Section 4 says what the mechanism
column shows about why, and it is not a mystery.

**3. The margin and the verdict held — and improved.** Worst-case margin
**3378.49 against SIMP's 3254.36 (+3.8%), VERDICT ACCEPTED**, at achieved
vf 0.681319 against a target of 0.68. Certified by `analyze_fixed_design`, in
FP64, under the same isolation production certifies under.

## 1. what was built

A working level-set topology optimizer in an `EXCLUDE_FROM_ALL` sandbox target
(`core/tests/harness/levelset_probe.cpp`), driven by our own matrix-free solver.

It writes **no FEA**. `simp_compliance` runs every state solve and
`analyze_fixed_design` runs the certification — the same two calls the shipped
ladder makes, on the same matrix-free operator, at the same tolerance — and
`build_production_loadcase` supplies the grid, the tags, the clamped DOFs and the
nodal loads, exactly as `portable_problem_export` does for PR 321. What is new is
only the design variable in front of them: a scalar phi whose zero level set is
the boundary, in place of a density the optimality criterion updates voxel by
voxel.

The six pieces, and the three on the fallback the task named:

| piece | what runs | fallback |
|---|---|---|
| (a) phi | signed distance on his 128 x 31 x 118 grid, negative inside | seeded from his own converged SIMP rung 0.68 |
| (b) ersatz | `rho = rho_min + (1-rho_min)*H_eta(-phi)`, C1 smoothed Heaviside, `H(0)=0.5` exactly | eta = 1 voxel, as instructed |
| (c) shape derivative | per-element strain energy density, read off `simp_compliance`'s own `dc/drho_e`, less the volume multiplier | |
| (d) velocity extension | separable `[1 2 1]/4`, 4 passes | **yes** |
| (e) advection | explicit upwind Hamilton-Jacobi, Godunov gradient, CFL 0.4 | |
| (f) reinitialisation | fast sweeping to `\|grad phi\| = 1`, 8 sweeps, every iteration | |
| (g) volume | a constant offset on phi, bisected to the rung target each iteration | **yes** |

The shape derivative is not derived anywhere in the file. `simp_compliance`
documents `dc/drho_e = -p * rho_e^(p-1) * E0 * (u_e^T K_unit u_e)`, so the element
strain energy is read back from the sensitivity core already returns:

    u_e^T K_unit u_e = -(dc/drho_e) / (p * rho_e^(p-1) * E0)

The volume multiplier is the mean band energy, which makes the flow
volume-neutral to first order; the residual is what the offset bisection removes
at the top of the next iteration, so the two pieces do not fight.

**The volume bisection recovers what PR 321's SDF arm could not.** That arm
reinitialised his rung 0.68 and came out at achieved `vf = 0.774451` against a
requested 0.68, which is why it reports no compliance and no verdict — its rows
are geometry at the wrong volume. The same pull appears here: at zero offset the
seeded level set sits about 2 voxels above target, and the bisection is what
holds it on the rung. `iterations.csv`'s `offset_mm` column is that correction,
in millimetres, and it runs from +3.63 mm at iteration 1 to +0.55 mm at 120 as
the shape takes over from the offset.

## 2. the posture, which is where this measurement was nearly lost

The first cut of the probe disarmed Krylov recycling and GenEO at startup,
copying the re-certifying probes (`boundary_cell_probe` and friends), which do it
for a real reason: `analyze_fixed_design` is not a pure function of its arguments
while the recycler carries a subspace between solves.

**On his part that posture cost 2.5x per iteration — 28.4 s against 11.2 s — and
it was measuring the handicap, not the level set.** His run is exactly the Jacobi
regime the recycler was armed for (`run_info.json`: `krylov_recycling: true`,
`recycle_dim: 16`, `cg_multigrid: false`, `mg_mode: "stagnated-latched"`), where
handoff 133 measured 45.4% fewer CG iterations.

`build_production_loadcase` has already run `configure_production_options`, which
arms the Galerkin block cache, recycling, GenEO and the thread count globally.
The run of record leaves that alone, so its seconds-per-iteration is comparable
to SIMP's, which was measured in the same posture. `--isolate` restores the
disarmed posture as a control.

The **certification** is isolated separately, and in FP64 regardless of `--fp32`,
exactly as production isolates it (`ScopedLadderSolverIsolation`,
`run_job.cpp:2847`) — so the certificate is produced on the same solver path, in
the same arithmetic, as every other certificate in this repository.

## 3. S1 — mixed precision is ARMED, and it is a no-op on his part

`--fp32` calls `fea_set_matfree_mixed_precision(true)`. The capability shipped
complete in handoff 092 and is opt-in; nothing production-side has ever called
the setter, which is why `run_info` honestly echoes `mixed_precision: false`. It
is armed here, on the sandbox path only — **no production file changed**.

**It cannot do anything on his part, and this is structural, not a null result.**
FP32 in this codebase is the **V-cycle preconditioner** — the fine apply, the
Jacobi smoother, restriction, prolongation. The outer CG stays FP64 by design
(residual, dot products, x/r/p, the convergence test), and so does the coarse
direct solve; the flag selects `mf_v_cycle_mixed` over `mf_v_cycle` at
`multigrid.cpp:1191` and changes nothing else. On his part the multigrid
hierarchy never engages — his own `run_info.json` records `cg_multigrid: false`,
`mg_levels: 0`, `mg_mode: "stagnated-latched"` — and this run reproduces that
exactly:

**the V-cycle engaged on 0 of 120 state solves.**

So the FP32 branch is never taken. **This is not argued from the wall clock — it
is proved by byte-identity.** Two 120-iteration arms, same binary, one flag
differing, produced a bit-for-bit identical design:

    rho.f64     BYTE-IDENTICAL   sha256 3a9a06aa...d490cea4
    design.bin  BYTE-IDENTICAL
    margin      3378.485259539 on both arms, to every digit printed

That matters because this machine's run-to-run offset cannot resolve a few
percent (the bakeoff's `host_contention.txt`), so a wall-clock A/B could never
have settled it either way. The walls are 25.05 s (FP64) and 24.37 s (FP32) and
**carry no conclusion**; the identical bytes do. Evidence:
`s1_fp32_is_a_noop.txt`.

Handoff 132 already measured the FP32 flip as a 1.197x **regression** on a grid
where the V-cycle does run, because `cg_tolerance` 1e-8 is essentially FP32's
precision and the preconditioner returns noise near convergence. Nothing here
contradicts that or revives it. Arming it was one line; what it buys on this part
is zero, for a reason that is in the solver's own records.

## 4. the measurement

Rung 0.68, seeded from his converged SIMP rung, 120 iterations (the budget; the
compliance plateau test — spread < 1e-3 over a 10-iteration window, the shipped
MMA termination rule — had not fired).

| | ours (level set) | SIMP | Gridap (PR 321) |
|---|---|---|---|
| **s / iteration** | **25.09** | 13.62 | 277.73 |
| iterations | 120 (budget) | 27 (converged) | 3 (unconverged) |
| total wall, the rung | 3010.5 s | 367.7 s | 1110.9 s |
| **cut roughness (deg)** | **6.7080** | 7.5521 | 4.0156 |
| CAD amplitude (mm) | 0.4489 | 0.4293 | 0.7080 |
| **margin worst case** | **3378.49** | 3254.36 | not certified |
| **verdict** | **ACCEPTED** | ACCEPTED | — |
| achieved vf | 0.681319 | 0.679951 | 0.774451 |
| min-feature count | 4888 | 5619 | 4547 |
| sub-voxel, crossing rms (mm) | 0.2168 | 0.1297 | 0.5790 |
| crossings at the edge midpoint | 72.82% | 85.28% | 7.20% |

**Per iteration we are 1.84x SIMP. Per rung we are 8.19x**, because the level set
took 120 iterations and had not converged where SIMP converged in 27. That is the
honest cost and it is the more important of the two numbers: a first-order shape
derivative with a CFL-limited explicit step is a slower descent than MMA, and no
part of this run's cost is the FEA being different.

**Why our roughness win is a quarter of Gridap's is in the last two rows.** The
mechanism column is sub-voxel content, and ours moved only partway. Our field is
**91.7% binary at a band end** with 10466 fractional samples; Gridap's SDF arm had
100834 — nearly 10x more. With `eta = 1 voxel` on a true signed distance, only
the cells within one voxel of the interface are fractional at all, so most of the
boundary is saturated and carries no sub-voxel information for marching cubes to
use. The representation is coherent — that is what reinitialisation bought, and
the crossing statistics moved decisively away from SIMP's 85.3% edge-midpoint
staircase — but there is simply less of it than Gridap put there.

`eta` was fixed at 1 voxel because the task fixed it, on PR 321's evidence that
the win survives at half a voxel. That evidence says a narrow band does not
*destroy* the win; it does not say a narrow band *maximises* it, and these rows
are the first measurement on our own implementation that separates the two.

## 5. two design choices a reader must not have to infer

**Penalty 3, the production value, on the ersatz band.** The trajectory and the
certification both use the shipped `SimpParams` (penalty 3, `density_min` 1e-3)
rather than a linear ersatz interpolation, so the certificate comes from the same
material law as every other certificate here. The cost: a band voxel at
`rho = 0.5` is stiffness 0.125 rather than 0.5 — a systematic sub-voxel thinning
of the interface, one band wide. It biases compliance UP relative to reading the
same geometry as binary, so **our compliance (0.0026159) and SIMP's converged
compliance (0.0024004) are not directly comparable** and are not put in one row
above as if they were. It is a bias, not an instability: the volume target is met
on the ersatz measure regardless, and the margin — which is computed on the
printed set, not the band — is higher than SIMP's.

**The certified design is the best-compliance iterate, not the last one.** An
explicit Hamilton-Jacobi step can overshoot, and certifying an overshoot would
report the scheme's worst moment as its result. Here they coincide (iteration
120 was also the best), and `summary.txt` records which it was.

## 6. what this does not answer

* **Only rung 0.68 ran.** One finished rung beat four unfinished ones. Nothing
  here says the level set holds its margin at 0.52, 0.38 or 0.26 — and note that
  face protection plus the BC pads pin 36.3% of his part FrozenSolid, which is
  the floor any rung must clear.
* **It was seeded from his SIMP design, not from holes.** `--seed holes` is
  implemented and untested on his part. So this run measures a level set
  *re-optimising* from a feasible SIMP start, not one finding a topology from
  scratch, and it never had to survive a severed load path — which is exactly
  what killed Gridap's from-scratch ALM arm.
* **It had not converged at 120 iterations.** The compliance was still falling
  0.8% per 20 iterations at the end.
* **`eta` was not varied.** Section 4 argues it is the lever; nothing here
  measures that.

**What the next hour would have been:** rerun at `eta = 2` and `eta = 3` voxels,
unchanged in every other respect, and put the three rows beside each other. The
mechanism column predicts the roughness win grows and the CAD amplitude worsens;
if it does, the band width — not the representation — is what separates our
11.2% from Gridap's 46.9%, and it is a one-argument change.

## 7. in plain language

We built our own version of the thing that won last time, and ran it on his part.

Last time we borrowed someone else's level-set optimizer and it produced a much
smoother cut surface than our own method — the first real win in six tries — but
it took 277 seconds per step against our 11, which looked like the idea was
unaffordable. It wasn't. That 25x was the borrowed software being a
general-purpose tool doing our specific job the slow way. Written into our own
solver, the same idea costs **25 seconds a step instead of 277**.

It is not free. Our version needs a lot more steps to settle than our current
method does, so finishing one setting of the part took about eight times as long
overall. And it delivered about a quarter of the smoothing the borrowed one did:
11% smoother instead of 47%.

The reason for that shortfall looks like a setting rather than a flaw. The method
works by letting each voxel on the surface hold a fraction of "how full" it is,
which is what lets the surface sit between voxels instead of stepping around
them. We were told to use the narrowest setting for that blur — one voxel — and
at that setting most of the surface saturates to fully-in or fully-out and stops
carrying the extra information. The borrowed tool had ten times as much of it.
Widening that one number is the obvious next thing to try, and it is a
one-argument change.

The important safety result: the part still passes. Its certified strength margin
came out slightly *better* than our current method's (3378 against 3254), it hit
its weight target, and the certificate was produced by the same code, in the same
arithmetic, that certifies everything else here.

Separately, we switched on the half-precision solver option that had never been
turned on. On his part it does nothing at all — not because it is broken, but
because it only speeds up a part of the solver that his particular part never
uses. That is now measured rather than assumed: it was skipped 120 times out of
120.
