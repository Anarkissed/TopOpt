# working notes — written as the campaign runs, not after it

★ **THIS FILE IS THE RECORD OF WHAT WAS SEEN WHEN, INCLUDING THE THINGS THAT
TURNED OUT TO BE WRONG.** The handoff carries the conclusions; this carries the
order they arrived in and what was believed in between.

---

## before the arms

**R2 ran first, deliberately, and it paid for itself immediately.** The volume
sensitivity verified at −0.085% / +0.479%, flat across three decades of step
size. Then the compliance rows came back at **+56.0% and +45.0%** on the two
random directions, flat to five digits — and the DISCRETE weight, differenced
against the same solves, read −0.31% / +0.97%.

That is a second wrong gradient, in the factor PR 327 did not look at. Had the
arms run first they would have run on it, and the campaign would have had to be
thrown away. **Order mattered.**

**The path validation (resolution 48, four minutes) is not a measurement** and
its README says so twice. It exists because the alternative was discovering a
plumbing bug at hour six.

**Two cross-checks were run that nobody asked for**, both because the code was
new and the unit tests only exercise it on toy shapes:

* the topology counters against an independent BFS implementation on SIMP's real
  rungs — every field equal;
* the surface pipeline against itself — SIMP's own rung 0.68, dumped and handed
  back in as an arm, reproduces its internal row to four decimals (+0.0 on every
  column). So the extra hop the arms travel is not the result.

---

## arm B — the previous production posture (heaviside, eta 2, continuum, cap 60)

Finished 08:07, about **2 h 40 min** of wall clock on a SHARED host.

| rung | printed | margin | accepted | SIMP's printed / margin |
|---|---|---|---|---|
| 0.68 | 0.7900 | **3297.3** | yes | 0.7973 / 3254.36 |
| 0.52 | 0.6802 | 3357.7 | yes | 0.6941 / 3389.42 |
| 0.38 | 0.5860 | 2378.0 | yes | 0.6048 / 3290.91 |
| 0.26 | 0.5047 | **777.5** | yes | 0.5283 / 3014.12 |

★ **ALL FOUR RUNGS STOPPED ON `iteration-ceiling`.** The compliance plateau never
fired once, in 240 iterations. That is PR 327's control reproduced on the
production path — *"the control never reached the shipped convergence criterion
in 120"* — and it is half of the §0 answer about iteration counts: **before the
volume-fraction fix the run does not converge, it runs out.**

★ **AND THE LIGHT RUNG IS WHERE THE METHOD FALLS OVER.** 777.5 against SIMP's
3014.12 — **−74%** — while the shipped rung is +1.3% ABOVE SIMP at 0.9% less
material. Two things to hold apart before reading anything into that:

1. this arm carries the 45–56%-wrong compliance weight R2 measured, so it is the
   worst case by construction, and
2. it stopped at 60 with its margin still moving, which is the other half of the
   same item.

★ **The printed fractions do NOT match SIMP's** (0.7900 against 0.7973; 0.5047
against 0.5283) — the parametric run lands slightly lighter at the same nominal
rung. Every margin comparison in the handoff has to carry that, or it is
comparing two different parts. It is a percent, not the 17% convention gap
between the probe and production, but it is not zero.

★ **The topology counters, first real reading on this path**, rung 0.68:

| | b0 | chi | b2 | b1 tunnels | sealed pockets | sealed voxels | sealed mm³ |
|---|---|---|---|---|---|---|---|
| SIMP 0.68 | 16 | 16 | 0 | 0 | 10 | 1034 (4.60%) | 5127.5 |
| arm B 0.68 | **34** | 25 | 0 | **9** | **22** | **1603 (6.88%)** | **7949.1** |

The parametric design carries **twice the void components, nine tunnels where
SIMP has none, and 55% more trapped volume**. That is
`plsm-nucleates-sealed-cavities` showing up in a counter instead of in a lattice
refusal, which is exactly what item 4 said the counters were for.

---

## arm C — item 1 alone (heaviside, **eta 1**, continuum, cap 60)

Finished 09:58, about **1 h 50 min**. All four rungs again on
`iteration-ceiling`: eta does not make the Heaviside path converge.

| rung | B (eta 2) printed / margin | C (eta 1) printed / margin | Δ margin | SIMP printed / margin |
|---|---|---|---|---|
| 0.68 | 0.7900 / 3297.3 | 0.7928 / 3255.5 | −1.3% | 0.7973 / 3254.4 |
| 0.52 | 0.6802 / 3357.7 | 0.6889 / 3347.8 | −0.3% | 0.6941 / 3389.4 |
| 0.38 | 0.5860 / 2378.0 | 0.5977 / 2751.6 | **+15.7%** | 0.6048 / 3290.9 |
| 0.26 | 0.5047 / 777.5 | 0.5199 / **1619.2** | ★ **+108.3%** | 0.5283 / 3014.1 |

★★ **eta = 1 MORE THAN DOUBLES THE LIGHT RUNG'S MARGIN** and is a wash at the
shipped one (−1.3%). Stage A measured this pairing at the shipped volume only,
where it found the margins identical to three digits; **the shipped rung is not
where eta's margin effect lives.** It lives where the margin can move at all —
which is the whole reason R3 asks for both rungs.

★ **BUT IT IS NOT A CLEAN COMPARISON AND THE REASON IS ITSELF A FINDING.**
eta = 1 prints MORE material at every rung (0.5047 → 0.5199 at the light one,
+3.0%), so part of that +108% is bought rather than free. The mechanism:

> the Heaviside path's volume constraint targets `volume_fraction × n_active` on
> the SMOOTHED OCCUPANCY SUM, while `printed_fraction` counts `{occ > 0.5}`. Those
> are the same number only when the band is narrow. A WIDER band drifts further —
> Stage A measured that drift at 8.9% — so halving eta does not only narrow the
> band the shape derivative sees, **it moves the achieved volume closer to the
> one that was asked for.**

★ **Under the volume fraction the two coincide by construction** (summing `f_v`
IS summing the volume), so arms D and A should land closer to the nominal target
than either Heaviside arm. That is a prediction, written before D finished.

★ topology, rung 0.68: eta = 1 gives **fewer, larger** pockets — 24 void
components against 34, 9 sealed pockets against 22, 8 tunnels against 9, but MORE
trapped voxels (1979 against 1603).

---

## the host

★ **NOT MINE.** Other worktrees ran `levelset_probe`, `solver_arm_sweep`,
`test_cli`, `test_lattice_variant` and a `test_protect_freeze_vs_solidity`
concurrently for most of the campaign; load average sat at 15–19 and my process
between 11% and 190% CPU. Per-iteration wall went from ~25 s to ~65 s and back.

**The designs are deterministic and unaffected. The wall clocks are not
comparable at better than about 10%** — the same caveat PR 327 §3(a) states, for
the same reason. Iteration COUNTS are also unaffected, and they are what the
convergence claim rests on.

---

## things found by needing a number, not by looking for them

* **the compliance weight** (R2, above);
* **`b2` vs drainability** in the Euler identity — a phantom tunnel per sealed
  pocket, caught by the unit test on a convex 3×3×3 pocket;
* **`JobDescription` duplicating `PlsmOptions`' defaults as literals** — items 1
  and 3 would have been no-ops for every job that carries a plsm block;
* ★ **the PLSM path writes 0.000 for `total_ms`, `solve_ms`, `fea_ms`, `sens_ms`
  and `analysis_ms` on every row of every run since PR 325.** Found because
  Table 5's cost share divided by it. The SIMP path fills them. The fix is
  DEFERRED to after the campaign on purpose: a rebuild mid-campaign would leave
  two arms measured on two binaries, and the change is observe-only so it cannot
  move a design;
* **R1 as inherited would have measured nothing** — it stashes to build its
  BEFORE side, and this branch's work is committed, so on a clean tree it saves
  nothing and never goes back.

---

## still open at the time of writing

* `cli_demo`'s determinism check failed once, at 5152 s under heavy contention,
  having passed in every prior evidence run at 150–420 s. A retry was started and
  KILLED — under contention it cannot separate "this diff" from "thread timing",
  and it was starving the campaign. **Must be re-run on an idle machine.**
  Mechanically this branch cannot reach it: `cli_demo` carries no plsm block and
  every added line in the driver is inside the `PlsmMode::Parametric` branch.
