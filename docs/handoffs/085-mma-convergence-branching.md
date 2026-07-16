# 085 — MMA convergence / branching diagnosis

DIAGNOSE-FIRST. No core default was changed; Gate-V2 untouched. The maintainer,
watching optimization-history playback, reported *"I was expecting a lot more
branches and they were starting to come about but then it stopped"* — the design
kept evolving right up to the end. This confirms that and explains why.

## TL;DR (STEP 1 findings first)

**MMA terminates on the ITERATION CAP, not on convergence — in every production
rung.** The design is still moving materially at exit (`max|drho|` sits at or near
the move limit, 0.12–0.20, vs the `change_tol` of 0.01). Genuine convergence of
this same case takes **~395 iterations**; the objective is within ~1% of optimum
by **~150** and within ~3.4% at the production cap of **60**. The maintainer's
"it stopped" is real premature termination on the cap — a defect, not an
aesthetic preference. The filter-radius floor is a **separate** limit that caps
how *fine* the branches can get (~9 mm members on a 200 mm/64³ part); it does not
cause the "stopped mid-evolution" symptom.

## How the run was reproduced

Read-only harness (`scratchpad/diag.cpp`, `scratchpad/timing.cpp`) driving the
public `minimize_plastic` with the app's real options copied verbatim from
`app/.../TopOptBridge/bridge.cpp`:

- ladder `{0.68, 0.52, 0.38, 0.26}` (`reduction_ladder()`), `margin_stop = 1.5`
- `min_feature_mm = 2.5`, `updater = MMA` (default), solver `MultigridCG_Matfree`
- **`simp.max_iterations = 60`, `simp.change_tol = 0.01`, `simp.move = 0.2`** —
  the library defaults, which the bridge leaves untouched (it never sets
  `opts.simp.max_iterations` / `change_tol` / `move`; confirmed by grep).
- Geometry: a tall thin cantilever, 64×4×32 vox @ 3.125 mm = 200 mm long ×
  100 mm tall (the branching regime; matches the 083 filter-floor scenario).
  Self-weight PLA (E 3500 MPa, yield 55 MPa).

The per-iteration series below is `SimpOptimizeResult.history`, which already
records `{compliance, change = max_e|x_new−x|, volume_fraction}` per MMA step —
no instrumentation of the loop was needed.

## Termination mechanism (the code)

`simp_optimize` (`core/src/simp/simp.cpp`, masked overload ~L1287) is:

```
for (int it = 0; it < st.iterations; ++it) {      // st.iterations == max_iterations for MMA
    ... solve, mma_update_masked ...
    change = max_e |x_new[e] - x[e]|;
    if (change < options.change_tol) { stage_converged = true; break; }   // the ONLY early exit
}
result.converged = stage_converged;                // false => it ran the full cap
```

- **The cap**: `SimpOptions::max_iterations` (`simp.hpp:344`), default **60**,
  comment literally calls it *"hard iteration cap (a convergence criterion)"*.
- **The tolerance**: `SimpOptions::change_tol` (`simp.hpp:345`), default **0.01**,
  tested against `max|drho|` in **design** space.
- MMA rejects a Heaviside projection schedule, so the production MMA rung is
  always the single plain stage: `st.iterations == max_iterations == 60`.

### (a) Which one fires in production? — the CAP, always.

CONFIG A (production-faithful, `margin_stop = 1.5`): all four rungs were
evaluated and accepted (`stopped_on_margin = 0`), and **every one hit the cap**:

| rung | vf   | iterations | converged | final max\|drho\| (tol 0.01) |
|------|------|-----------|-----------|------------------------------|
| 0    | 0.68 | 60        | **no**    | 0.119  ← still moving         |
| 1    | 0.52 | 60        | **no**    | 0.200  ← at the move limit    |
| 2    | 0.38 | 60        | **no**    | 0.200  ← at the move limit    |
| 3    | 0.26 | 60        | **no**    | 0.136  ← still moving         |

`change_tol` **never** fires at cap 60. The cap fires 100% of the time.

### (b) Is max|drho| still large at termination? — YES.

At exit `max|drho|` is 0.12–0.20. The move limit is 0.2, so on some voxels the
design is still taking the **maximum allowed step** when the loop is cut off. The
design is materially changing — this is exactly the maintainer's "still evolving
when it stopped".

### (c) How many iterations to genuine convergence? — ~395; objective plateaus ~150.

CONFIG C: rung vf=0.26 with the cap raised to 400 (same `change_tol = 0.01`). It
**converged at iteration 395** (`max|drho| = 0.0095 < 0.01`). Compliance curve
(converged value ≈ 0.007825):

| iter | compliance | vs converged |
|------|-----------|--------------|
| 10   | 0.02511   | +221 %       |
| 20   | 0.01609   | +106 %       |
| 30   | 0.01022   | +30.6 %      |
| 40   | 0.008672  | +10.8 %      |
| 50   | 0.008250  | +5.4 %       |
| **60**  | **0.008093** | **+3.4 %  ← PRODUCTION STOPS HERE** |
| 80   | 0.007992  | +2.1 %       |
| 100  | 0.007954  | +1.6 %       |
| 150  | 0.007903  | +1.0 %       |
| 200  | 0.007859  | +0.4 %       |
| 300  | 0.007848  | +0.3 %       |
| 395  | 0.007825  | converged    |

Two distinct "converged" answers, and the distinction matters:

- **Objective (what the part actually is)**: the knee is ~iter 40–50; by ~iter 90
  compliance is within ~1.7 % and by ~iter 150 within ~1 %. The *topology* — the
  branches — keeps refining across iters 60→~150 (compliance falls another ~2.4 %
  by redistributing the same 26 % of material into better/finer members). **This
  is the branching the maintainer saw forming and then lose.**
- **Design-change metric (`max|drho| < 0.01`)**: needs **395** iterations, but the
  last ~250 of those buy almost nothing (0.4 %→0 %). They are spent chasing a
  handful of boundary voxels that oscillate at the move limit while the objective
  is already settled. `max|drho|` is a *poor* stopping test for MMA at fixed
  volume — a few flickering elements keep it pinned near the move limit long after
  the structure is done. (You can see the oscillation directly: compliance is
  non-monotone, spiking whenever a member toggles then recovers.)

### (d) Does the ladder budget iterations per rung? — Yes, equally; no rung is starved.

Each rung is a fresh `simp_optimize` call with its own `max_iterations = 60` and a
fresh `MmaState`. All four rungs ran exactly 60 (table above). No later rung gets
fewer than rung 0 — the problem is that **60 is too few for every rung**, not that
the budget is skewed.

## STEP 2 — what limits the branching (ranked, with numbers)

1. **Iteration cap (60) — DOMINATES the reported symptom.** Provably premature:
   `converged = false` on every rung, `max|drho|` at/near the move limit, and
   ~2.4 % of compliance (the branch-refinement phase) still on the table between
   iters 60 and 150. This is "branches were starting to come about but then it
   stopped." It is a tuning knob and it is set too low.

2. **Filter-radius floor — a real, SEPARATE resolution limit; no iteration count
   fixes it.** Confirmed and quantified: on the 200 mm/64³ grid,
   `spacing = 3.125 mm`, so `rmin = 2.5 / 3.125 = 0.80` voxels, which is below the
   hard floor of **1.5 voxels** (`physical_filter_radius`, `simp.cpp:286`), so the
   filter radius is floored to **1.5 vox = 4.69 mm** (members ≈ 2× that ≈ 9 mm
   minimum thickness). This caps how *fine/numerous* branches can be, regardless
   of iterations. It manifests as "branches are chunky," **not** as "they stopped
   mid-formation." (Same floor documented in 083.) If the maintainer wants
   genuinely finer trusses, this — not the cap — is the wall, and the fix is grid
   resolution (finer voxels → `rmin` clears the floor), not a tuning knob.

3. **Volume fraction / load — did NOT limit branching in this case.** CONFIG A
   reached the lightest rung (vf 0.26, the most-branched) with `margin_stop`
   rejecting nothing. The core design load here is self-weight; under a *heavier*
   external service load the margin gate could reject low rungs before the
   branching regime (the STEP 2c hypothetical), but that did not occur for the
   self-weight PLA case, so it is not the active limiter. (App failure-load
   magnitude is app-side per prior memory; it does not drive the core ladder's
   self-weight margin here.)

4. **Penalty continuation — N/A (nothing to truncate).** SIMP penalty is FIXED at
   `p = 3.0` (`SimpParams::penalty`), not ramped, and the production MMA path
   rejects the Heaviside/β continuation schedule entirely (it is OC-only). So
   there is no ramp that a truncated cap could leave incomplete. MMA designs have
   slightly softer boundaries than the OC+projection path, but that is a known
   projection-support gap, not a continuation-truncation artifact.

**Ranking:** the iteration cap is the cause of the maintainer's specific symptom;
the filter floor is the cap on ultimate fineness. If the ask is "the branches
stopped forming," raise/replace the cap. If the ask is "make the branches thinner
than ~9 mm," that is the filter floor and needs finer voxels.

## STEP 3 — recommendation (proposal only; nothing changed)

STEP 1 shows a genuine premature cap, so a minimal change is warranted. Real
wall-time, measured at true 64³ (823 k DOF) with the production matrix-free MGCG
solver: **~14.75 s/iter** (`scratchpad/timing.cpp`, 8-iter probe). Per rung:

| cap  | reaches | s/rung @64³ | ×4-rung ladder |
|------|---------|-------------|----------------|
| 60 (today) | +3.4 % above optimum, still refining | ~15 min | ~1.0 h |
| 150  | within ~1 %, branches essentially finished | ~37 min | ~2.5 h |
| 400  | full `max|drho|<0.01` (chases flicker)     | ~98 min | ~6.5 h |

Do **not** raise the cap to 400 — it costs **hours** (~6.5 h for the ladder) to
buy <1 % objective, chasing oscillating boundary voxels. Two better options:

- **Minimal (a): raise the cap to ~120–150.** Captures the branch-refinement
  phase (to within ~1 %). Cost ~2.5×, i.e. roughly **+1.5 h** on the full 64³
  ladder. Simple, but wasteful on rungs that settle early and still open-ended at
  128³.

- **Preferred (b): add an OBJECTIVE-plateau termination** and keep a raised safety
  cap. Stop a rung when the relative compliance change, averaged over a short
  window (e.g. last 5 iters), drops below ~1e-3 — this fires ~iter 90–100 here,
  adapts per rung and per resolution, and does not chase the `max|drho|` flicker
  that the current design-change test gets stuck on. This directly fixes the root
  cause: the current `change_tol` on `max|drho|` is the wrong convergence test for
  MMA at fixed volume, which is *why* the cap is doing all the terminating.

Either way this is opt-in-shaped work that must re-green Gate-V2 (the OC-locked
projected fixture asserts its own iteration counts/values and must stay
byte-identical — scope any change to the MMA path / driver cap, not the shared
projected loop).

## Evidence / reproduction

- `scratchpad/diag.cpp` — full per-iteration log, CONFIG A (production), CONFIG B
  (whole ladder), CONFIG C (raised cap → convergence at 395). Output:
  `scratchpad/diag_out.txt`.
- `scratchpad/timing.cpp` — 64³ per-iteration wall-time probe (14.75 s/iter).
- Build: `cmake -S core -B build -DEigen3_DIR=... -DCMAKE_DISABLE_FIND_PACKAGE_OpenCASCADE=ON`
  then link the harness against `libtopopt.a` (Eigen 5.0.1, AppleClang).

No ROADMAP box checked (diagnosis only).
