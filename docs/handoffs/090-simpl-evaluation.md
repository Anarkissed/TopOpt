# 090 — SiMPL as an MMA replacement: evaluation (read-only)

**Track:** research / diagnosis. **Territory:** read-only. No code changed; the
only diff is this file. **Builds on:** 085-mma-convergence (MMA terminates on
the iteration cap, objective within ~1% by ~150 iters, full stationarity ~395),
086-mma-plateau (running-minimum plateau detector built to survive 10³× compliance
spikes), 066-M7.mma.4 (MMA is the production updater; Gate-V2 stays OC+projection).

**Question posed:** replace the MMA design updater with SiMPL (Sigmoidal Mirror
descent with a Projected Latent variable) to cut ITERATION COUNT, TopOpt's real
bottleneck.

**Sources actually read** (full text via `pdftotext`, not the abstract/press
release):
- **[Intro]** Kim, Lazarov, Surowiec, Keith, *A Simple Introduction to the SiMPL
  Method for Density-Based Topology Optimization*, arXiv:2411.19421v3 (Struct.
  Multidisc. Optim. 2025, [Springer 10.1007/s00158-025-04008-9](https://link.springer.com/article/10.1007/s00158-025-04008-9)).
- **[Analysis]** Keith, Kim, Lazarov, Surowiec, *Analysis of the SiMPL Method for
  Density-Based Topology Optimization*, arXiv:2409.19341 (SIAM J. Optim.,
  [10.1137/24M1708863](https://epubs.siam.org/doi/10.1137/24M1708863)) — the
  convergence theory + line-search algorithms.
- Reference implementation: **MFEM `ex37`** ([mainline](https://github.com/mfem/mfem/blob/master/examples/ex37.cpp),
  the entropic-mirror-descent precursor) and the full SiMPL reproduction branch
  **[dohyun-cse/mfem `simpl2`](https://github.com/dohyun-cse/mfem/tree/simpl2)**,
  commit `022954b`. MFEM is BSD-3-Clause. Readable as a spec; **not vendorable**
  into TopOpt (MFEM-assembly / PDE-filter dependent — see STEP 2).

Convention below: **"PROVEN"** = a theorem in [Analysis]; **"SHOWN"** = an
empirical result in a table/figure. The distinction matters and the papers are
scrupulous about it, so this report is too.

---

## TL;DR — the honest bottom line first

1. **STEP 0 is not a full stop, but it halves the scope.** SiMPL handles bounds +
   volume + self-weight cleanly, but as published it **cannot carry the stress
   aggregate** (STEP 0b). The stress path (`simp_optimize_stress`, a two-constraint
   volume+stress MMA subproblem) **must keep MMA**. SiMPL is a candidate for the
   **compliance path only**. That alone caps the win: it cannot replace MMA
   wholesale.

2. **The headline "up to 80% fewer iterations" is real but measured against a
   stopping criterion TopOpt does not use.** It is 300→~50 iterations on a 2D MBB
   beam, versus OC **and** MMA, both run to a KKT-equivalent stationarity target
   `Sₖ ≤ 1e-5` ([Intro] Table 1). TopOpt terminates MMA on an **objective
   plateau** (~140/rung, 086), not on stationarity — and MMA's *objective* lands
   within **0.4 %** of SiMPL's ([Intro] Table 1: 1.2129e-3 vs 1.2078e-3). On
   TopOpt's own criterion the honest iteration reduction is **~2–3×, not 6×.**

3. **The line-search cost does NOT evaporate the win, but the "3 PDE solves per
   iteration" scare does not apply to TopOpt.** [Analysis §6] states the exact
   accounting: *"three PDE solves are required for each iteration with two extra
   PDE solves per backtracking sub-iteration."* Two of those three are the
   **Helmholtz filter solve and the Riesz-map solve** — both of which TopOpt does
   as **cheap explicit matvecs**, not solves. In TopOpt's architecture SiMPL costs
   **~1 elasticity solve per iteration + 1 per backtrack**, same base cost as MMA.
   Backtracking is <10 % of iterations in well-behaved 2D but **~64 % for
   self-weight** ([Intro] Problem 4: 52 backtracks / 81 iters). So for TopOpt's
   real self-weight case the FEA-solve reduction is **~1.5–2×**, not 5×.

4. **The two properties may be worth more than the raw speed.** Strict monotone
   objective decrease is **PROVEN** ([Analysis] Thm 5.6) — it would retire the
   086 plateau detector. Mesh-independent convergence is **SHOWN** (not proven)
   in both 2D (h=1/64→1/512) and **3D at 33.5 M elements** ([Intro] Problem 2) —
   and because 128³ is TopOpt's *finish line*, a constant iteration count as
   resolution rises is worth more than a one-time factor.

5. **Recommendation: (b→a) — a read-only spike first, then a default-off,
   compliance-path-only flag if the spike pays.** The single decisive number
   (self-weight FEA-solve reduction at TopOpt's plateau criterion, at 64³ *and*
   128³) is **not in the papers**; my estimate straddles the "worth it" line.
   Measure it before committing. Cost if it turns out ~1.3×: a flag nobody enables
   — a few days, no production risk (default-off, compliance-only, Gate-V2
   untouched). The expensive mistake is shipping it as default without the spike.

---

## STEP 0 — THE BLOCKER QUESTIONS (answered first)

### 0a. Volume constraint — supported, and cheap. ✓

SiMPL enforces the volume constraint with a **single scalar Lagrange multiplier
`μ_{k+1} ≥ 0`** ([Intro] Eq. 8, 16). Each iteration the multiplier is found by a
**scalar root-finding method** — [Intro] Remark 3 recommends bisection or the
**Illinois algorithm** (modified regula-falsi) — solving the algebraic volume
equation `1ᵀM σ(ψ_{k+1}(μ)) = θ|Ω|`. The search interval is bounded a priori to
`μ_{k+1} ∈ [0, max(−gₖ)]` by monotonicity of the sigmoid, so it converges in a
handful of scalar iterations.

**Per-iteration cost: O(Nρ) vector evaluations of the sigmoid, no extra FEA/PDE
solves.** The root function is `μ ↦ Σ M σ(ψ − α(g + μ1))`, a pointwise map — no
state solve inside the root-find. This is the same order of cost as OC's
bisection on the volume multiplier, which TopOpt already does. **Not a blocker.**

### 0b. Stress aggregate — NOT supported as published. ✗ (scope-halving)

**Every one of the five example problems in [Intro] uses the volume constraint as
its only constraint.** The paper is explicit that anything beyond that is future
work: *"The method can be developed further to handle a larger number of design
constraints than considered here. One possible extension is to utilize Lagrangian
multipliers for the additional constraints … an augmented objective function
featuring Lagrange multiplier terms that can be updated using standard augmented
Lagrangian update rules"* ([Intro], Concluding remarks). There is **no analysis
and no experiment** for a second general constraint. [Analysis] proves convergence
for **bounds + one volume constraint only** (Assumption 4.1 onward).

TopOpt's stress path is `simp_optimize_stress` (`simp.hpp:676–710`): a
**two-constraint** convex subproblem per iteration (volume **and** an aggregated
von Mises P-norm), solved **MMA-only** ("Uses MMA regardless of `options.updater`
… the stress path is MMA-only, per M7.mma.2", `simp.hpp:700`). MMA carries
multiple general constraints natively; SiMPL, as published, does not.

**Verdict:** SiMPL can at best replace MMA on the **compliance path**
(`simp_optimize` / its masked overload — the volume-only rungs, self-weight
included). **The stress path keeps MMA.** This is the STEP 0b instruction ("state
that plainly and reassess the value") — done: the value is capped at "one of two
updater paths," and it is the path where MMA already reaches within 0.4 % of the
optimum.

### 0c. Design-dependent loads (self-weight) — supported, same formulation. ✓

[Intro] §3.3, Problem 4 is exactly self-weight compliance minimization:

```
min_ρ  fᵀu + g(ρ̃)ᵀu
s.t.   K(ρ̃)u = f + g(ρ̃),   g(ρ̃)ᵢ = 9.81·(ρ̃)ᵢ  (downward internal force per element)
       (ε²A + M̃)ρ̃ = Nρ,   0 ≤ ρ ≤ 1,   1ᵀMρ ≤ θ|Ω|
```

The self-weight term is a **design-dependent load added to the RHS** — the same
formulation TopOpt uses (gravity scales with the physical density). Confirmed from
the body, not the abstract. SiMPL-B converged the self-weight bridge in **81
iterations with 52 backtracking steps**, and the volume constraint went inactive
(`1ᵀMρ_final = 0.5415 < 0.7|Ω|`) — SiMPL handled the inactive-constraint case
correctly. **Not a blocker.** (But note the high backtrack count — see STEP 2.)

**STEP 0 net:** proceed, but SiMPL is a **compliance-path replacement only**.

---

## STEP 1 — BASELINE HONESTY CHECK

**What the baselines actually were.** [Intro] §3 compares SiMPL against **OC**
(Sigmund's `[9]` formulation) **and MMA** (Svanberg, "default parameters given in
[37]"). So MMA — TopOpt's actual, stronger baseline — **is** in the comparison.
Both OC and MMA had their move limit **tuned** (`ch = 0.15`, "the best performance
among the tested values `ch ∈ {0.05 … 0.4}`"), so the baseline was not
sandbagged.

**The numbers ([Intro] Table 1, Problem 1 — 2D MBB, 768×256, θ=0.3):**

| method | final compliance | stationarity Sₖ | iters | obj. evals |
|---|---:|---:|---:|---:|
| SiMPL-A | 1.2078e-3 | 9.62e-6 | **50** | 56 |
| SiMPL-B | 1.2079e-3 | 9.30e-6 | **46** | 58 |
| OC | 1.2234e-3 | 1.42e-5 | 300 | 300 |
| MMA | 1.2129e-3 | 3.01e-4 | 300 | 300 |

The "up to 80 %" is this: **300 → ~50 iterations = 83 % fewer**, against both OC
and MMA. **But read the stopping rule.** OC and MMA were run to the stationarity
target `Sₖ ≤ 1e-5` (Eq. 35) and *"appear to require more than 300 iterations to
reach"* it — they hit a **300 cap without converging** (MMA's `Sₖ = 3.01e-4` is
30× above target). The 80 % is measured at a **stationarity** criterion.

**Why TopOpt's honest delta is smaller.** TopOpt does **not** run MMA to `Sₖ ≤
1e-5`. Per 085/086 it runs MMA to an **objective plateau** (~140/rung) and accepts
a **grayscale** design (Mnd ~0.27). On the *objective* metric MMA is not far off:
its final compliance (1.2129e-3) is **0.4 % above** SiMPL's (1.2078e-3). MMA's
problem here is slow **stationarity** convergence, not a worse optimum. So on
TopOpt's plateau criterion the expected iteration reduction is roughly the ratio
of "iters to objective-plateau" (SiMPL ~30–50 in 2D, ~42–81 in 3D vs MMA's
~100–150) — **~2–3×, not 6×.**

**The absence that is itself a finding:** **[Intro] reports NO MMA comparison on
the 3D cantilever (Problem 2) or on self-weight (Problem 4).** Those two —
precisely TopOpt's regime (3D, self-weight) — are SiMPL-only. The head-to-head
MMA numbers exist **only** for the 2D compliance MBB. There is no published
SiMPL-vs-MMA iteration count for a 3D self-weight problem, so any "5×" claim for
TopOpt's case is an extrapolation, not a measured result.

**Mesh dependence of the baseline ([Intro] Table 2, obj. at fixed iter 30):** as
`h` refines 1/64→1/512, MMA's objective **degrades** (1.24e-3 → 2.70e-3, and its
volume drifts off target), while SiMPL and OC stay ~1.05–1.10e-3. This is the one
place the MMA gap *grows* with resolution — see STEP 3a; it is the strongest
pro-SiMPL data point for TopOpt's 128³ target.

---

## STEP 2 — LINE-SEARCH COST (the number that decides it)

**Structure ([Intro] Algorithm 1).** The gradient `gₖ` is computed **once per
outer iteration** (line 6). Then an inner backtracking loop (lines 8–15) proposes
`ψ_{k+1} = ψₖ − αₖ(gₖ + μ_{k+1})`, forms `ρ_{k+1} = σ(ψ_{k+1})`, and tests a
sufficient-decrease condition (18); if it fails, `αₖ ← αₖ/2` and retry.
Condition (18) — Armijo (18a) or Bregman (18b) — requires evaluating
`F(ρ_{k+1})`, i.e. **one objective evaluation (a state solve) per backtrack
trial**. The initial step guess is a Barzilai–Borwein / relative-smoothness
estimate ([Intro] Eq. 19–20), which is why the first trial is usually accepted.

### a. Evaluations per iteration — the exact accounting

[Analysis §6] gives the formula and Tables 1–2 give measured counts:

> *"three PDE solves are required for each iteration with two extra PDE solves per
> backtracking sub-iteration."*

Verified against [Analysis] Table 1 (SiMPL-A, h=1/64): `24 iters, 3 backtracks →
24·3 + 3·2 = 78 PDE solves` ✓.

**What the three PDE solves are ([Analysis §6]):** (2.1) the **Helmholtz density
filter** solve, (2.2) the **elasticity** solve, (2.4b) the **gradient / Riesz-map**
(adjoint filter) solve. For compliance the elasticity adjoint equals `−u`, so no
separate adjoint state solve. A backtrack redoes only (2.1)+(2.2) = 2.

### b. **Is the 80 % in iterations or in FEA solves? — For TopOpt, essentially in FEA solves.**

**This is the crux, and it flips the naive fear.** Two of the paper's three "PDE
solves per iteration" are the **filter** and the **Riesz map**. In MFEM those are
genuine FEM solves; **in TopOpt they are not:**

- TopOpt's density filter is an **explicit mm-based convolution** (a matvec,
  ARCHITECTURE.md:75 / `simp.hpp`), **not** a Helmholtz PDE solve.
- TopOpt's Riesz map on a voxel grid (lumped/diagonal mass) is a **cheap scaling**,
  not a solve.
- Only the **elasticity** solve is the 4.73 s cost (086).

So the paper's "3 solves/iter + 2/backtrack" maps, **in TopOpt units**, to:

> **~1 elasticity solve per iteration + ~1 elasticity solve per backtrack.**

That is the **same base per-iteration cost as MMA** (MMA also does one elasticity
solve per design update). The only SiMPL surcharge is the backtracks. Measured
backtrack rates:

| problem | iters | backtracks | backtracks/iter | note |
|---|---:|---:|---:|---|
| MBB beam ([Intro] T1) | 50 | 6 | 0.12 | well-conditioned 2D |
| Mesh sweep ([Analysis] T1) | 21–24 | 1–3 | <0.10 | "< 10 % of iterations" |
| Multi-load frame ([Intro] P3) | 25 | 3 | 0.12 | |
| Force inverter ([Intro] P5) | 197 | 47 | 0.24 | non-self-adjoint |
| **Self-weight bridge ([Intro] P4)** | **81** | **52** | **0.64** | **TopOpt's case** |

**So for TopOpt's real (self-weight) case, avg ≈ 1.6 elasticity solves/iter**
(worst single iteration can halve several times, but the BB guess keeps the mean
near 1.6). A ~3× iteration reduction becomes a **~1.5–2× elasticity-solve
reduction** for self-weight. Concretely: SiMPL self-weight to full KKT `≤1e-5` =
**133 elasticity solves** (81+52); to a mere objective plateau it is fewer (the
objective plateaus well before stationarity). MMA self-weight to its plateau ≈
**~140 solves** (086, ~140 iters × 1). Net **~1.1–2× fewer FEA solves** — real,
but **not** the 5× headline.

### c. Wall time — **neither paper reports any.** Finding.

Both papers report **only** iteration counts, backtrack counts, objective
evaluations, and PDE-solve counts. There is **no wall-clock time** anywhere (no
CPU seconds, no runtime, no throughput). Every efficiency claim is a *count*, not
a *time*. For a method whose entire pitch is "cheaper because fewer iterations,"
the absence of a single wall-time comparison is a genuine gap — it means the
solve-count arithmetic above (not the papers) is the only basis for a TopOpt
wall-time estimate.

---

## STEP 3 — THE TWO PROPERTIES THAT MAY OUTWEIGH THE SPEED

### 3a. Mesh-independent convergence — **SHOWN, not proven; but shown in 3D.**

[Analysis] abstract, verbatim: *"the numerical experiments demonstrate **apparent
mesh-independent** convergence of the algorithm."* It is an **empirical**
observation, explicitly not claimed as a theorem. It is *motivated* by the
optimize-then-discretize / Riesz-map derivation at the function-space level
([Intro §2.4]), but iteration-count-vs-resolution independence is **shown**, not
**proven**.

Evidence:
- **2D:** [Analysis] Table 1 — 21–24 iters flat across h = 1/64, 1/128, 1/256,
  1/512. [Intro] Table 2 — SiMPL objective stable across the same range while MMA
  degrades.
- **3D:** [Intro] Problem 2 — a **512×256×256 = 33.5 M-element** cantilever
  converged in **42–81 iterations** (42–49 for θ ∈ [0.1, 0.2]); the count is
  driven by design complexity, not mesh size.
- **Order-independence** (bonus): [Analysis] Table 2 / [Intro] Problem 3 — iter
  count is also flat across polynomial degree p = 0…4.

**Why this matters more than a constant factor for TopOpt.** TopOpt's target is
**bounded**: 128³ is exactly where the 2.5 mm min-feature filter floor clears, and
160³ buys nothing (task premise, ARCHITECTURE.md:75). 128³ is the **finish line**,
not a waypoint. [Intro] Table 2 shows MMA's iteration cost *grows* with
refinement while SiMPL's does not — so the SiMPL/MMA gap is **widest at the
highest resolution TopOpt will ever run.** A method that holds ~50 iters from 64³
to 128³ while MMA needs progressively more is worth more than the 1.5–2× measured
at low resolution. **This is the single strongest argument for SiMPL** — but it is
empirical, and it has **not** been demonstrated for 3D self-weight specifically.

### 3b. Strict monotone objective decrease — **PROVEN, and it survives the volume constraint.**

[Analysis] Theorem 5.6 (SiMPL-A / Armijo) and the companion result for SiMPL-B /
Bregman **prove** `F(ρ_{k+1}) < F(ρₖ)` strictly, for **both** line searches. The
proof (read in full, [Analysis §5]) shows the sufficient-decrease condition plus
the Bregman term yields `F(ρ_{k+1}) ≤ F(ρₖ) − (1/αₖ)D_φ(ρₖ, ρ_{k+1}) < F(ρₖ)`.
Crucially it is stated for the **reduced objective including the volume
projection/multiplier** — the projected iterate stays feasible, so **monotonicity
holds with the volume constraint active**, not just for the unconstrained update.
[Intro §2.2] restates it as a design guarantee: *"ensure the sequence of objective
function values never increases."*

**Direct consequence for 086.** Handoff 086 built a running-minimum plateau
detector specifically because MMA's compliance is **non-monotone** — it measured
two ~10³× compliance spikes in six iterations when members toggle, and a naive
`|Δc|/c` test fires in the flat spot *before* a productive toggle. **SiMPL has no
such spikes** (proven). That means:
- The 086 plateau machinery (running-minimum window + progress gate) could be
  **replaced by a trivial `δF < tol` or `KKTₖ ≤ tol` test** ([Intro §2.3]).
- **Termination becomes trivially safe** — you can never stop in a pre-toggle flat
  spot that a later toggle would escape, because the objective only ever descends.

**Caveats (be precise):** (i) the proof assumes **exact** PDE solves; TopOpt's
iterative CG/multigrid with a finite tolerance could introduce *tiny*
non-monotonicity — nothing like the member-toggle spikes, but the `δF < tol` test
should still use a small guard band. (ii) The self-weight objective is non-convex;
the theorem gives monotone descent to a **stationary point**, not a global optimum
— same guarantee class MMA offers, just without the spikes.

---

## STEP 4 — THE GUARD (acceptance criterion)

A different updater gives a **different design**, so the guard is not
same-answer. Two forces make SiMPL's design differ from MMA's:
1. **SiMPL trends toward binary.** `ρ = σ(ψ)` drives densities to 0/1 as `ψ →
   ±10` ([Intro] Remark 2) — SiMPL naturally binarizes **without a Heaviside
   projection**. TopOpt's MMA path deliberately stays **grayscale** (Mnd ~0.27,
   the mma-vs-projection gate). So SiMPL rungs will be **crisper** than MMA rungs.
   That is a **product change**, and the guard must not demand design-equality.

**Precedent to mirror:** `test_minimize_plastic` **Scenario O**
(`test_minimize_plastic.cpp:1215`) compares MMA vs OC at a **matched iteration
budget** (`mma_plateau_window = 0` to disable plateau termination so it measures
the *update rule*, not the *stopping rule*) and asserts MMA "matches or beats" the
OC optimum. `test_mma.cpp:159` fixes the band at **2 %** (`kVolTol`).

**Proposed SiMPL guard (analogous):**
- **Per-rung compliance parity:** at each ladder rung's target volume fraction,
  SiMPL's converged compliance ≤ MMA's within **2 %** (matched budget, plateau
  termination disabled on both sides so the *updater* is isolated). SiMPL should
  *match or beat* MMA, exactly as MMA matched-or-beat OC.
- **Ladder decision invariance (the product guard):** the 4-rung ladder
  `{0.68, 0.52, 0.38, 0.26}` accept/reject decisions under the **stress-margin
  gate** (`margin_stop`) must be **unchanged**. A change in *which rungs pass* is a
  change in the **product**, not an optimization, and fails the guard even if every
  per-rung compliance is better.
- **Crispness is reported, not gated:** record Mnd per rung; a crisper SiMPL design
  is allowed (and may be desirable) as long as the two guards above hold.

**Gate-V2 stays byte-identical — for free. Confirmed.** Gate-V2 is
**OC + projection-locked** (`simp.hpp:310–314`, handoff 066: *"the projected chain
is the OC-locked Gate-V2 formulation"*). SiMPL would be a **new updater on the
plain, non-projected compliance path only** — the same seam MMA was added through
without touching the OC/projected path. SiMPL rejects a Heaviside/projection
schedule just as MMA does, so it can never enter the projected chain. No Gate-V2
byte can move. (Test: the existing `test_mma_projection_gate` invariants remain
green unchanged.)

---

## STEP 5 — RANKED RECOMMENDATION

**Recommendation: option (b) → (a) — a read-only spike first; then a default-off,
compliance-path-only flag if and only if the spike pays.**

The decision hinges on one number the papers do **not** provide: the FEA-solve
reduction for a **3D self-weight** problem, at TopOpt's **plateau** criterion, at
**64³ and 128³**. My estimate from the paper data is **~1.5–2× at 64³, widening at
128³ if mesh-independence holds** — right on the "worth a new updater" boundary.
Don't guess it; measure it.

**Ranked options:**

1. **(b, recommended) Prototype spike, read-only-ish, ~2–4 days.** Implement SiMPL
   in a throwaway harness (like `mma_probe.cpp`, not wired to CTest) on the plain
   compliance path only. Run TopOpt's actual self-weight cantilever at 64³ **and**
   128³ and record: elasticity-solve count to objective-plateau, backtrack rate,
   per-rung compliance vs MMA, and whether iter-count is flat 64³→128³.
   **Decision gate:** promote to (a) only if (self-weight solve reduction ≥ ~2.5×
   at 128³) **or** (mesh-independence clearly holds AND monotonicity lets the 086
   plateau detector retire). Otherwise **reject** and record the number.

2. **(a) Production flag, default OFF, compliance-path only, ~1–2 weeks after the
   spike.** New `SimpUpdater::SiMPL` selectable on `simp_optimize` / masked only;
   `simp_optimize_stress` untouched (MMA); Gate-V2 untouched (OC). Ship behind the
   guard in STEP 4. Default stays MMA until a maintainer-run A/B on real parts
   clears it — same cautious path every prior solver change took (matrix-free,
   multigrid, MMA switchover). SiMPL is genuinely **simple to implement** — the
   papers stress analytical updates, a scalar root-find, a BB step, and
   backtracking (much simpler than MMA's moving-asymptote subproblem) — so the
   engineering risk is low; the *behavioural* risk (untested on the 93 %-void
   design box with 1e-9 modulus contrast — a regime **no** paper example touches)
   is the real one, which is why default-off.

3. **(c) Reject outright.** Justified if the spike shows ~1.3× on self-weight and
   mesh-independence doesn't hold for the 3D self-weight case. A well-argued
   rejection here would read: *"SiMPL's 80 % is against OC/MMA at a stationarity
   target TopOpt doesn't use; on TopOpt's plateau criterion with self-weight
   backtracking it's ~1.3–1.5× on FEA solves, it can't carry the stress path, and
   the monotonicity/mesh-independence upside doesn't survive the 93 %-void box — a
   new updater isn't worth it."* This is a legitimate outcome; the spike decides.

**What it costs the maintainer if it's 1.3× not 5×:** with the staged plan, almost
nothing — the spike (~days) produces the number, and if it's 1.3× you stop before
the production flag. Even if built, a default-off compliance-only flag with
Gate-V2 untouched carries **no production risk**; the wasted cost is bounded to the
implementation days. The only way to lose real money is to **skip the spike and
ship SiMPL as default** on the strength of the 2D MBB headline — don't.

**Net verdict:** SiMPL is **credible and the mesh-independence + monotonicity
properties are individually attractive**, but the raw-speed case for *TopOpt
specifically* is **materially weaker than the press-release "4–5×"**: it can't
touch the stress path, and on the compliance path at TopOpt's own stopping rule
with self-weight backtracking it's plausibly ~1.5–2×. **Worth a spike, not worth a
blind swap.**

---

## Secondary items (one paragraph each — roadmap, not now)

**SEMDOT** — *State-of-the-Art Overview*, [Computation 2026, 14, 27](https://www.mdpi.com/2079-3197/14/1/27)
(orig. Fu et al., [CMAME / arXiv:2005.09233](https://arxiv.org/pdf/2005.09233)).
SEMDOT attacks jagged/terraced boundaries at the **algorithm** level via
sub-element (grayscale-element) smooth material distribution — adjacent to
TopOpt's stairstepping (083/084). But it is a **BESO-family discretization/updater
replacement**, a *larger* change than SiMPL and **orthogonal to the iteration-count
problem** this task targets; it also doesn't address self-weight or stress
constraints out of the box. Interestingly, SiMPL's own bound-preserving high-order
(`p>0`) story overlaps SEMDOT's sub-element goal. **Verdict: roadmap-only,
lower priority than the SDF item below.**

**SDF smooth extraction** — Ježek et al., *Smooth geometry extraction from SIMP …
signed distance function approach with volume preservation*, [Adv. Eng. Software
212, 104071 (2026)](https://www.sciencedirect.com/science/article/pii/S0965997825002091)
/ [arXiv:2512.06976](https://arxiv.org/html/2512.06976v1). This is a
**post-processing** method (SDF isocontour + RBF refinement) with **explicit
volume preservation** and a reported 18 % max-stress reduction, exporting directly
to CAD. It is **directly adjacent to handoff 086's resample AND its ~4.2 %
voxel-vs-mesh mass gap** — "volume preservation" is exactly the 086 mass problem.
Because it changes **only post-processing** (no updater, no product change to the
optimization), it is **lower-risk and more immediately relevant to a known TopOpt
defect** than SiMPL. **Verdict: worth its own evaluation task, arguably ahead of
SiMPL.**

**Penalty continuation / Heaviside for the MMA path** — 085 found `p` is FIXED at
3.0 and the MMA path skips Heaviside entirely (grayscale, Mnd ~0.27). **This is not
an obvious gap:** the SiMPL papers *also* use **fixed p=3, no continuation**
([Analysis §6.1] "penalty parameter s=3"), and they reach near-binary designs
**without** Heaviside — via the sigmoid latent variable. So TopOpt's fixed-p /
no-projection choice is shared by this SOTA method. Continuation (ramping p 1→3)
and Heaviside are standard in the Sigmund/Guest line primarily to *binarize* and to
*escape local minima*; TopOpt deliberately accepts grayscale. Note continuation
would **add** iterations (multiple p-stages) — cutting **against** this task's
iteration-count goal. **Verdict: a deliberate simplification, not a defect.** If
crisper designs are ever wanted, SiMPL's *natural* binarization is a cleaner route
than bolting Heaviside onto MMA.

---

## Verification (read-only compliance)

- No source touched. `git diff --stat` shows only this file added.
- No ROADMAP box checked.
- Papers read in full via `pdftotext` (venv `pypdf`); every factual claim above is
  tagged [Intro]/[Analysis] with the table/section it came from, and PROVEN vs
  SHOWN is distinguished throughout.
