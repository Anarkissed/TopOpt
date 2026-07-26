# Draft Quality — approximate trajectory + exact final certification (Phase 1, built)

**Date:** 2026-07-25
**Area:** core optimizer posture (`MinimizePlasticOptions::draft_quality` + the
escalation gate in `minimize_plastic.cpp`), observability, and the topopt-cli job
schema. **NOT `/app/`** (the user-facing toggle is a separate parallel-legal PR).
**Status:** BUILT and instrumented. Default OFF; arming is a maintainer decision and
is **not** part of this task. **The escalation trigger is PROVISIONAL** — measured
not to separate; the conservative posture and the reason are stated below.
**Evidence:** `evidence/2026-07-25-draft-quality/` (three probe transcripts, the B1
checksums, per-iteration regime CSVs, `BUILD.md`).

## TL;DR

All four load-bearing parts are built, plumbed, and instrumented:
- **(a) loose early trajectory solves + (b) progressive tightening over the last k**
  — `draft_loose_tol` drives the motion-keyed `adaptive_traj_cg_tol` schedule; k is
  derived from the convergence criterion and measured per rung.
- **(c) one exact solve + real certification** — the final compliance and stress
  solves ALWAYS run tight; **asserted, not commented (B2)**.
- **(d) auto-escalation** — a self-contained certified-vs-trajectory compliance gap
  re-runs a rung tight from its recoverable warm seed; mechanically proven to fire
  and recover.

The headline measurements, scored against the pre-stated bars:

| Bar | Requirement | Result | |
|-----|-------------|--------|-|
| **B1** | draft OFF byte-identical to origin/main | FNV over full densities+compliance+margins+accepts, boxed & no-box: **`2e5d…9df1` == `2e5d…9df1`** (stash-rebuild proof). ctest 67/67. | **PASS** |
| **B2** | Gate never softens; assert it | Certification tolerance asserts in both `simp_optimize` finals + the recovery solve; asserts live (no `-DNDEBUG`), never tripped in ctest or any probe. | **PASS** |
| **B3** | Noise floor from a benign perturbation | tight 1e-8 vs 1e-9 on grid S: **0 classification flips, mean\|Δρ\|=0** on every rung. Floor is below measurement resolution. | **PASS (clean)** |
| **B4** | Belt proven to FIRE and RECOVER | Mechanism proven: at loose 5e-1 a rung diverges (0.15 flip-frac) and escalation re-runs it tight → **0.15→0** (recovered). See the trigger caveat. | **PASS (mechanism); trigger provisional** |
| **B5** | ≥2× summed trajectory CG on a stagnating grid | Grid S (16×8×16, CSV shows cg_multigrid=0/hier_built=1/thousands): **2.07×**. Bigger grid (32×16×32): 1.53×. **Met on the stated grid, scale-sensitive.** | **PARTIAL** |
| **B6** | No CG rise on a healthy MG grid | Healthy grid H (32×12×32): **all 4 rungs FALL, 0 rise** (1.46×). Big grid: 0 rise. One degenerate REJECT rung on grid S rises (named below). | **PASS** |
| **B7** | Record hier_built, cg_multigrid, mg_mode per iter | Per-iteration regime CSV written; the exact columns PR 181 lacked. | **PASS** |
| **B8** | Design diff as fraction of solid voxels changing classification | Reported as flip-fraction with grid dims + solid count in every row; raw mean\|Δρ\| alongside, never headline. | **PASS** |

**The one thing that could have derailed this DID: the compliance gap does NOT
separate diverged rungs from converged ones.** Handled per the task's instruction —
no threshold was fitted to look good; the trigger is shipped provisional and the
conservative posture documented. Details in §Escalation.

## What was built

### (a)+(b) The draft schedule and the derivation of k

`draft_quality` drives each rung's `SimpOptions::cg_tolerance_loose = draft_loose_tol`
(default 1e-3). The existing motion-keyed `adaptive_traj_cg_tol` then interpolates
the trajectory tolerance log-linearly between loose (design moving at the move limit)
and the tight `cg_tolerance` (design settled). Loose tolerance is therefore spent on
the EARLY, fast-moving iterations whose sensitivities feed a step that is immediately
overwritten; the tolerance tightens back toward `cg_tolerance` as `max|Δρ|` decays.

**k is not chosen by feel.** It is the length of the convergence tail the schedule
tightens over, DERIVED from the convergence criterion: the objective must be flat
over `mma_plateau_window` (=10) iterations to terminate, so those trailing iterations
are the ones that lock the terminal basin and must be resolved accurately — they are
exactly where motion is smallest and the schedule is already near-tight. k is then
MEASURED per rung as the count of trailing iterations whose tolerance reached within
one decade of `cg_tolerance` (`draft_rung_tail_k`). The CSV confirms the derivation:
on grid S rung 1 (`S_draft_noesc.csv`), `traj_tol` starts at 1.0e-3 and the trailing
rows read 5.19e-8, 1.23e-8, 1.14e-8, 1.11e-8 — the last ~4 iterations at ≈ the tight
1e-8, which is the reported `tail_k=4`. Because MMA is plateau-terminated, N is not
known a priori, so a literal "last k iterations" cannot be scheduled ahead of time;
keying the tightening to the settling signal (motion) is the robust realization and
its tail length is reported, not assumed.

### (c) Exact certification — B2, structural

The final compliance solve in both `simp_optimize` overloads and the stress-recovery
solve in `minimize_plastic` pass `options.cg_tolerance` unchanged; draft mode writes
ONLY `cg_tolerance_loose`. This is asserted, not commented:
`assert(adaptive_traj_cg_tol(options,0)==cg_tolerance && adaptive_traj_cg_tol(options,move)>=cg_tolerance)`
at each final solve (the schedule floor equals the certification tolerance and is
never tighter than it, so the certificate is at least as tight as every trajectory
solve), plus `assert(opt.cg_tolerance==kCertTol)` at the recovery solve and the
escalation re-run. Draft mode is therefore structurally incapable of certifying a
part on a loosened solve.

### (d) The escalation gate — self-contained trigger, recoverable re-run

After a rung's draft optimize, the driver computes
`c_gap = |C_cert − C_traj| / C_cert`, where `C_cert` is the tight final solve and
`C_traj` the last loose trajectory solve — both already computed, no exact trajectory
run (that is the point; PR 181's `C_delta` column measured this same quantity). If
`c_gap` exceeds `draft_escalation_c_gap`, the rung is RE-RUN at tight tolerance from
its own warm seed (`opt.initial_design == warm_seed`, still unmutated at that point —
the seed guard runs only after the rung), and the escalation is recorded. **The rung
is re-runnable from recoverable state — the BLOCKED-STOP path is NOT hit.** Escalation
cost is real and reported (the win is net of it).

### Plumbing + observability

- New `SimpIterationObservation::cg_trajectory_tol` (read-only; the schedule column).
- `MinimizePlasticResult::draft_rung_tail_k / _c_gap / _escalated`, one entry per
  evaluated rung, aligned across every terminal branch (normal/infeasible/cancelled).
- `run_info.json` echoes `draft_quality`, `draft_loose_tol`,
  `draft_escalation_c_gap`, the three per-rung vectors (finalize-only, like
  cg_multigrid), and a compact `draft_escalations: [{rung, gap}]` — "every escalation
  with its rung index and measured gap".
- topopt-cli job schema: optional `"draft": {quality, loose_tol, escalation_c_gap}`
  block; parsed strictly (empty block or unknown key REJECTED), mapped in run_job for
  both front-ends. Absent → OFF → byte-identical.

## B5 — the win, with scale (never averaged over a regression)

Summed trajectory CG, tight vs draft(1e-3), margin_stop=0 so the whole ladder runs:

| grid (solved) | ladder | tight CG | draft CG | ratio | notes |
|---|---|---|---|---|---|
| **S 16×8×16** | 0.50/0.35/0.24 | 95 303 | 45 982 | **2.07×** | genuine stagnation; **meets B5** |
| S 16×8×16 | +0.16 (degenerate) | 107 905 | 66 596 | 1.62× | vf0.16 REJECT rung, C≈5e8, RISES 0.61× |
| **L 32×16×32** | 0.50/0.35/0.25 | 246 667 | 161 365 | **1.53×** | stagnation less dominant at scale |
| H 32×12×32 (healthy) | prod ladder | 99 328 | 67 951 | 1.46× | **B6: all 4 rungs fall, 0 rise** |

The mechanism is where the CSV says it should be: on grid S under tight, rung 1's
early dilute iterations STAGNATE (`cg_multigrid=0, hier_built=1`, 1613/1729/2398 CG —
the near-singular near-uniform design grinds Jacobi); under draft the SAME iterations
run at loose 9.9e-4 and **MG carries** (164/125/203 CG) because the loose residual is
met inside the V-cycle budget before the stagnation-latch trips. A single stagnating
iteration goes ~2200→~150 CG (~15×) — but stagnating iterations are a MINORITY of the
trajectory, so the aggregate is diluted to ~1.5–2.1×.

**Honest verdict on B5:** met (2.07×) on the stated stagnation grid; the win is real,
consistent, and never a regression on healthy/big grids, but it is scale-sensitive
(1.53× at 32³) and does not robustly clear 2× everywhere. The per-stagnating-iteration
win is large; the aggregate win is bounded by the stagnating fraction of the ladder.

**B6 named regression:** the only rung whose CG rose under draft is grid S's vf0.16
rung (0.61×), a degenerate ultra-dilute REJECT (achieved 0.14, compliance 5e8, a
near-singular system where a looser early solve lands a worse-conditioned iterate). It
is not a healthy MG case and never ships. On the healthy grid H and the big grid L, no
rung rises.

## The design does not change — PR 181's blocker does not reproduce

PR 181 filed a NO-GO on a design-difference blocker (mean|Δρ|≈0.055, `max|Δρ|=1.000`).
Its own recorded errors: an 8×3×8 fixture (192 voxels), whole-voxel flips, a design
bar imported from a production-scale measurement, no negative control. This handoff
inherited neither.

With the negative control in place (B3: tight-vs-tight = **0 flips**) and the scale-
correct metric (fraction of solid voxels changing printed↔void classification, with
dims + count), the finding reverses: **draft mode leaves the SHIPPED (terminal,
certified) design classification-identical to tight — 0 flips — across a 500× loose
sweep (1e-3 … 5e-1), WITH and WITHOUT warm-start inheritance.** A transient mid-ladder
divergence does appear at aggressive tolerances (a non-terminal REJECT rung flips
0.05–0.15 of its solid voxels) but it washes out: each rung re-optimizes to the same
basin and the certification is exact, so the shipped part is untouched. PR 181's
basin-flip was an artifact of the broken fixture, not a property of the mechanism.

## Escalation — the trigger is PROVISIONAL (the derail, handled honestly)

The escalation trigger assumes the compliance gap separates diverged rungs from
converged ones. **It does not.** From the divergence sweep and the inheritance probe:

- loose 5e-1, warm-start ON: rung 1 GENUINELY diverges (**flip-frac 0.15**) but carries
  **gap ≈ 0.0000** → the gap-triggered belt does NOT fire on it.
- loose 3e-1: rung 2 carries **gap 0.031** but **flip-frac 0.000** → a false positive.
- across the whole 500× sweep the max rung gap wanders 0.003–0.031 with no monotone
  relation to the (mostly zero) design divergence.

The reason is structural: compliance is a flat objective near the optimum, so a
genuinely different design can share its compliance (miss) and a converged design can
differ slightly in it (false alarm). Per the task's explicit instruction, **no
threshold was fitted to look good on one grid.** What IS load-bearing is (c): the
certified numbers are always exact (B2), and empirically the shipped design is
tolerance-robust (0 flips, above). Escalation is defense-in-depth, not the safety
guarantee.

The escalation MECHANISM is nonetheless proven: with `escalate every rung` (threshold
≤ 0) at loose 5e-1, the transient rung-1 divergence recovers 0.15→0.00 (the re-run
re-seeds the next rung from the corrected design). The mechanism works; the scalar
trigger is what needs replacing.

**Shipped posture.** `draft_escalation_c_gap` defaults to 0.02 — a coarse,
win-preserving guard that rarely fires, documented as PROVISIONAL in the option
comment. The conservative override is `≤ 0` (escalate every rung → every shipped
design had a tight trajectory), which is correctness-over-win and costs MORE than a
plain tight run (a draft pass plus a tight re-run per rung) — the honest price of a
safety net without a reliable trigger. A reliable trigger would be a DESIGN-SPACE
signal (e.g. mid-ladder Δρ between the loose iterate and a tight probe), which is the
recommended Phase-2 replacement. When in doubt, the ≤0 posture is the slow-but-safe
choice; the exact certification (B2) makes even the default posture safe for the
shipped part's numbers.

## Bars not otherwise covered

- **B7** — `S_tight_1e8.csv` etc. carry per-iteration `cg_multigrid`, `hier_built`,
  `mg_mode`, plus `traj_tol` (the schedule). PR 181 recorded none, so nobody could
  tell which regime it measured; here the stagnation is a direct read.
- **B8** — every design-difference number is the fraction of solid voxels changing
  classification, with grid dims and solid-voxel count in the same row, reported as a
  multiple of the B3 noise floor (which is 0 here, so absolute flip-fractions are
  given; raw mean|Δρ| appears alongside, never as the headline).

## Files

Core (378 insertions, 1 deletion across 9 files):
`simp.hpp`/`simp.cpp` (cg_trajectory_tol + B2 asserts), `pipeline.hpp`
(draft options + result vectors), `minimize_plastic.cpp` (schedule config,
escalation gate, k measurement, recovery assert), `observability.hpp`/`.cpp`
(run_info echo + serializer), `run_job.cpp` (build/finalize + job→options map),
`job.hpp`/`job.cpp` (draft block parse).

Harnesses (core/tests/harness/, not in CTest): `draft_quality_probe.cpp`,
`draft_quality_divergence_probe.cpp`, `draft_quality_inherit_probe.cpp`,
`draft_b1_identity_probe.cpp`. Reproduction: `evidence/2026-07-25-draft-quality/BUILD.md`.

## What Phase 2 would need

1. A reliable divergence trigger — a design-space signal, not the scalar compliance
   gap. The instrument to build: at a rung's plateau, take one extra tight probe solve
   and compare the loose vs tight iterate in Δρ; escalate on Δρ over the B3 floor.
2. A grid where stagnation dominates enough of the ladder to clear 2× robustly at
   scale (fixtures are maintainer-only; this handoff's programmatic grids reach 2.07×
   at 16×8×16 and 1.53× at 32×16×32).
3. The `/app/` toggle (separate, parallel-legal PR).
