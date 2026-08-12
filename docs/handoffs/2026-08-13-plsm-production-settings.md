# plsm-production-settings — ship what is settled

Evidence: `evidence/2026-08-13-plsm-production-settings/` — `./reproduce.sh`
regenerates all of it, and nothing is cloned to do so.

★ **THIS TASK IS THE ONE THAT TOUCHES PRODUCTION.** PR 325 shipped the parametric
level set as a mode; PR 326 and PR 327 measured it in a sandbox and **changed no
production file between them**. Everything below is `core/src`, `core/include`
and the job schema, and every arm runs through `topopt-cli run` on his captured
job — not through `levelset_probe`.

★ **THE PERIMETER PENALTY IS NOT HERE.** It waits for Stage B, for the reason the
brief gives: if the Helmholtz filter at r = 2 or r = 3 clears at both rungs it
beats the penalty on surface and the question changes. Nothing below depends on
that result.

*(§0 is written last, when every number in it exists. The method is §1-§6.)*

## 1. ITEM 1 — `eta_voxels` 2.0 → 1.0

One line in `core/include/topopt/plsm.hpp`, and one more in
`core/include/topopt/job.hpp` — see §6 for why the second one is the interesting
half.

### (a) the measurement it ships on, and the magnitude that is now superseded

Measured as a MATCHED PAIR at the **shipped volume convention** (rung 0.7973),
which is the pairing Amendment 1 asked for because eta sits inside the perimeter
functional and a weight does not transfer across it:

| C=1, shipped rung | n_cut | carved | CAD mm | margin |
|---|---|---|---|---|
| eta = 2 | 28,934 | 11.6466 | 0.4461 | 3252.3 |
| ★ **eta = 1** | **27,887** (−3.6%) | **9.1155** (−21.7%) | **0.4373** | 3251.0 |

★★ **THE MARGINS ARE IDENTICAL TO THREE DIGITS. eta IS A SURFACE KNOB AND NOT A
MARGIN KNOB.**

★ **AND THE MAGNITUDE IS A THIRD OF THE EARLIER CLAIM.** −11.7% was measured at
rung 0.68 **on the probe path**, which prints 17.1% less material than production
does at the same nominal rung. At the shipped volume it is **−3.6%**. The
direction is confirmed; the number is not.

★ **THE SUPERSESSION IS WRITTEN WHERE THE CLAIM IS, NOT ONLY HERE.**
`docs/handoffs/2026-08-11-plsm-minimise-extra-surface.md` now carries the
correction twice — in §7 beside the −11.7% table, and in §0, where the whole
section is marked as being at the probe's volume convention. A reader who never
opens this file cannot plan against −11.7%.

### (b) ★ what eta 2 → 1 ALSO does, which the surface tables do not show

`plsm_heaviside` is GridapTopOpt's, and `H(0.5h, eta)` is what a FrozenSolid
voxel's ersatz occupancy comes out at under the smooth boolean, because
`phi_eff <= -h/2` there by construction. At eta = 2 voxels that is **0.7375**; at
eta = 1 it is **0.9088**. So on the `Heaviside` path, halving eta also stiffens
the whole frozen set by 23% — the anchor pad, the load pad and the protected
face. It is reported because the arms measure the two changes together and the
margin column belongs partly to this one.

★ **Under the volume fraction it stops existing**: a frozen cell is STAMPED to
1.0 and the guarantee is exact rather than a band-width argument. §2(c).

## 2. ITEM 2 — the exact volume fraction, which is a correctness fix

### (a) what was wrong, and how wrong

PR 327 §4 finite-differenced the gradient the shipped `--plsm` mode uses —
`DH_eta(phi)*|grad phi|` projected by `Psi^T` against a centre-sampled `H_eta`
density — and measured it **wrong by up to 23%, FLAT ACROSS TWO DECADES OF STEP
SIZE**. Flatness is the whole evidence: a finite difference that has not
converged moves with the step; one that has converged to the wrong number does
not. Coefficient 8904 read +19.67% and +19.65% at steps a factor of ten apart.

★ **The cause is named rather than guessed.** `DH_eta(phi)*|grad phi|` is the
SURFACE measure `dS`, which is correct for the CONTINUUM shape derivative. The
derivative of the DISCRETE ersatz carries no `|grad phi|` at all. The two agree
exactly on a true signed distance; this phi is not one (`‖grad phi‖−1` runs
0.35–0.39 rms through every arm), so the difference is real.

★★ **AND ITS OWN LINE IS THE REASON THIS SHIPS: "a 20%-wrong descent direction
does not fail; it converges slowly."** Both of PR 327's fraction arms reached the
shipped convergence criterion in **57 and 61 iterations while the control never
reached it in 120**, at the same compliance within 0.9%.

★ **PR 327 CHANGED NO PRODUCTION FILE. THIS IS WHERE IT SHIPS.**

### (b) the change, and what it leaves alone

    was:  rho_e = rho_min + (1 - rho_min) * H_eta(-phi(x_centre)),  eta = 2 vox
    now:  rho_e = rho_min + (1 - rho_min) * f_v
          f_v   = (1/|C_v|) INT_{C_v} 1[phi(x) < 0] dx,  by k x k x k sampling

`core/include/topopt/plsm_frac.hpp` is a **MOVE** of PR 327's
`core/tests/harness/frac_ersatz.hpp` into core — the same move `plsm_basis.hpp`
and `plsm_kernel.hpp` were, and for the same reason: a production copy of the
quadrature would be a second quadrature law in the repository.

★ **ONLY `rho_e` CHANGES.** For an isotropic ersatz the cell stiffness is
`rho_e * K0`, so the 24x24 reference block, the matrix-free stencil, the
geometric multigrid, GenEO, the Krylov recycler and the Galerkin block cache are
untouched: no per-cell `Ke`, no O(cut cells) storage, no cache-key change.

★ **k = 4, carried across rather than re-derived.** PR 327 §S1(a) swept k on a
fixed design and established 4 as sufficient. Re-deriving it here would have
spent the budget this task needs for the arms, and the sweep is not
part-dependent in a way that would change the answer: it is a quadrature
refinement question, and its own convergence table is in that task's evidence.

★ **The sub-cell lattice IS the export lattice.** Sample `(p,q,r)` of cell
`(i,j,k)` sits at `x = i + (p + 0.5)/k - 0.5`, which is exactly where
`plsm_evaluate(..., factor = k)` and `marching_cubes_resampled` put theirs. There
is no second convention anywhere in the file.

★ **Only the ACTIVE cells are ever sampled** — 70,688 of 468,224 on his part. The
rest are stamped by the mask, and the ones actually CUT are **counted** every
iteration (`frac_cut_cells` on the receipt) rather than bounded by a classifier.

### (c) ★ WHAT STILL READS eta, ITEM BY ITEM

The brief's 2(c) asks for this plainly, and the list is printed in the code as
well — `PlsmRunResult::eta_voxels` carries it as a comment block so it cannot
drift from the implementation.

| reads eta | what it does | what was done |
|---|---|---|
| the PRINTED predicate `{occ > 0.5}` | defines the part: the volume constraint, the F=1 export, the certificate, the mass | ★ **eta-free ALREADY, as a set.** `H` is monotone with `H(0) = 0.5` exactly, so `{H_eta(-phi) > 0.5} == {phi < 0}` for every eta — an eight-fold change in eta was measured to move the extracted triangle count by ZERO. Under the fraction it is `{f_v > 0.5}`, the same set to O(1/k³). **Unchanged, deliberately**: changing it would change what "the part" means and make the mass column incomparable. |
| the F>=1 ANALYTIC EXPORT's field VALUES | where marching cubes puts a vertex on a crossing edge | ★ **THE ONE PLACE ITEM 1 STILL ACTS** once the density is a fraction, and it is where the surface numbers come from. Kept as the row of record (R5). |
| `plsm_frozen_floor_occupancy` | the load-path guarantee | ★ **SUPERSEDED, NOT MERELY SATISFIED.** Under the fraction a FrozenSolid cell is STAMPED to 1.0, so the floor is exactly 1 and carries no eta. The eta-dependent form is still computed and **still thrown on** — it is what the `Heaviside` path rests on, and R7 does not permit deleting an assertion because a second path stopped needing it. |
| the reinitialisation's reporting band | the `‖grad phi‖−1` diagnostic | reporting only. |
| `Per = INT DH_eta(phi)|grad phi|` | the perimeter penalty | **NOT IN PRODUCTION AT ALL.** It exists only in the sandbox and is Stage B's. |

★★ **AND eta IS NOT QUIETLY RETAINED IN THE DENSITY, WHICH THE BRIEF NAMES AS THE
FAILURE MODE.** `build_fields` under `VolumeFraction` never calls
`plsm_heaviside`. The A/B is a job-document flag (`plsm.ersatz`), so the two
densities are one `if` apart and the control arm runs the old one exactly.

### (d) ★ THE SMOOTH BOOLEAN BECOMES A STAMP, AND THAT IS CHECKED, NOT ASSERTED

The frozen set entered the old ersatz as
`phi_eff = max(min(phi, phi_solid), -phi_void)`. A volume fraction counts SIGNS,
and that expression can only change the sign of phi where `phi_solid < 0` (a
FrozenSolid voxel) or `phi_void < 0` (a keep-out). Both distances are **strictly
positive everywhere else by construction** — `plsm_build_frozen_boolean` seeds
them at `+h/2` and `plsm_reinitialise` preserves the sign — so on every ACTIVE
cell the boolean is a no-op on the sign, and stamping the frozen cells is not an
approximation of the boolean: on this partition it **is** the boolean.

★ **That property is CHECKED at run start** (`plsm.cpp`, the `if (frac)` block
after the floor-occupancy throw), over every non-Empty voxel, and refuses the run
by name if it ever fails. It is the same failure PR 324 §5 spent a day on — 40
leaked frozen voxels of 40,216 breaking the anchor-to-load walk — arriving one
representation later, and it is now a measurement rather than a paragraph.

★ **A second thing falls out of it and is reported rather than buried:** under
the old ersatz a FrozenVoid (keep-out) voxel carried occupancy `H_eta(-h/2)` —
**0.2625 at eta = 2, 0.0912 at eta = 1** — so keep-outs were never actually
empty. Under the fraction they are exactly 0.

### (e) ★ THE SENSITIVITY, WHICH IS THE PART THAT CAN WASTE THE RUN

Leaving the old measure in place would be a mismatched gradient: it converges,
just slowly and to somewhere else, and it would be believed. The derivative of
`f_v` is a surface integral that the co-area formula turns into a volume integral
of a Dirac:

    d f_v/d alpha_i = -(1/|C|) INT_{Gamma cap C} psi_i/|grad phi| dS
                    = -(1/|C|) INT_C delta(phi) psi_i dx
                   ~= -(1/k^3) SUM_s delta_q(phi_s) psi_i(x_s)

Two things about it are load-bearing:

★ **THE `|grad phi|` IS GONE, AND ITS ABSENCE IS THE CORRECTION.** The old measure
is `dS`; this one is `dS/|grad phi|`, and the second is what the derivative of a
VOLUME FRACTION actually is.

★ **`psi_i` IS EVALUATED AT THE SAMPLES, NOT AT THE CELL CENTRE.** `Psi` is built
on the cell-centre lattice, so `Psi^T` would factor `psi_i` out of the sub-cell
sum — the same substitution this change exists to remove, one level down, and it
would have been invisible. PR 327 §4(c)(i) priced it: **~15 percentage points of
gradient accuracy on a general direction, and NOTHING on a single coefficient**,
so a single-coefficient check would have said the scatter was unnecessary. Both
forms are reachable (`plsm.frac_sens_exact`); the exact one is the default.

### (f) ★ THE MOLLIFIED VALUE IS THE DEFAULT, AND THE L1 BANDWIDTH IS NOT

PR 327 ran two fraction arms: `F1_frac4` (the hard sample count) and `A2_all`
(mollified value + L1 bandwidth). `A2_all` was the only arm in that study whose
margin SETTLED. ★ **But its own R4 attributed the win to ONE of the two flags**:
the mollified value alone finite-differences at −1.33 / +3.18% on the compliance,
and adding the L1 bandwidth takes it to **−2.32 / +7.61%**. Its §8 says so
outright — *"the arm that should have been run is `--frac-soft` alone; it was
not"*.

★ **So that is the arm that ships, and this task is where it was finally run.**
`frac_mollified = true`, `frac_eps_l1 = false`. The L1 form is kept reachable
with its citation (Engquist, Tornberg & Tsai prove it is the convergent choice in
3D) and its measurement (it lost here) at the same site, so nobody re-derives the
theory and re-arms it without seeing the number.

★ **Why the mollified value is not a return to eta**, which is the obvious
objection: `eps_q = eps_mult * |grad phi| * h/k` is tied to the SAMPLE SPACING and
shrinks like 1/k, so it converges to the exact indicator as k refines. eta is
fixed in voxels and converges to nothing. And the value function is the exact
ANTIDERIVATIVE of the mollifier the sensitivity uses, so `dS/dt = -delta_q(t)`
identically — the value and the gradient are two facts about one function.

### (g) ★★ R2 — THE FINITE DIFFERENCE, AND THE SECOND WRONG GRADIENT IT FOUND

`core/tests/harness/plsm_frac_fd_probe.cpp` differences the **shipped header** —
`plsm_frac_build`, `plsm_frac_of_soft`, `plsm_frac_band`, `plsm_frac_scatter`, in
the order and with the arguments `plsm_optimize` uses them in. A probe that
reimplemented the gradient would verify the probe.

**The volume, `V(alpha) = SUM_{v ACTIVE} f_v`, swept over five step sizes:**

| probe | 0.001 | 0.01 | 0.1 | 0.3 | 1.0 |
|---|---|---|---|---|---|
| random dir 0 | **−0.085%** | **−0.085%** | **−0.085%** | **−0.085%** | −0.096% |
| random dir 1 | **+0.479%** | **+0.479%** | **+0.479%** | **+0.479%** | +0.489% |
| coefficient 20136 | +0.564% | +0.572% | +0.663% | +1.626% | +6.681% |
| coefficient 11982 | +0.569% | +0.578% | +0.671% | +1.636% | +6.688% |
| coefficient 14696 | +0.563% | +0.572% | +0.665% | +1.630% | +6.683% |

★ **THE VOLUME SENSITIVITY IS VERIFIED TO BETTER THAN HALF A PERCENT, FLAT ACROSS
THREE DECADES.** PR 327's HARD variant read +182% at step 0.001 and −45.7% at
0.01 on the same functional; the mollified value removes that staircase
completely, which is the whole reason it is the default. The single-coefficient
rows climb at the large steps because the FUNCTION curves there, not because the
gradient does — that is truncation, and it moves with the step exactly as
truncation should.

**★★ AND THE COMPLIANCE, WHERE THE ANSWER WAS NOT THE EXPECTED ONE.** Two state
solves per point, at the tight tolerance, both weights differenced against the
SAME solves:

| probe | step | **continuum** (the shipped weight) | **discrete** (the derivative of the actual law) |
|---|---|---|---|
| random dir 0 | 0.01 | ★ **+56.017%** | **−0.313%** |
| random dir 0 | 0.1 | ★ **+56.014%** | **−0.314%** |
| random dir 1 | 0.01 | ★ **+45.050%** | **+0.967%** |
| random dir 1 | 0.1 | ★ **+45.049%** | **+0.967%** |
| coefficient 20136 | 0.01 | +6.288% | −1.534% |
| coefficient 20136 | 0.1 | +5.998% | −1.802% |
| coefficient 11982 | 0.01 | +7.327% | −1.529% |
| coefficient 14696 | 0.01 | +7.123% | −1.497% |

★★ **THE COMPLIANCE GRADIENT PR 324, 325, 326, 327 AND THE SHIPPED `--plsm` MODE
ALL USE IS OFF BY 45–56% ON A GENERAL DIRECTION, AND IT IS FLAT TO FIVE DIGITS
ACROSS A FACTOR OF TEN IN STEP SIZE.** 56.017 against 56.014. By exactly the
criterion PR 327 established for the `|grad phi|` defect, that is a gradient
error and not noise.

★ **THE ROOT CAUSE, WITH FILE AND LINE.** `core/src/simp/plsm.cpp:104`
(`energy_from`) returns the strain-energy density `q E0` — the energy released
when material appears across the interface as a 0 → 1 **jump**. That is the
continuum shape derivative, and it is also the discrete one **when the stiffness
law is linear**. GridapTopOpt's is: `E(rho) = rho E0`, penalty 1. ★ **This
trajectory runs SIMP at penalty 3**, so the derivative of the ersatz compliance
the solver actually minimises is

    dC/dalpha_i = SUM_v (dC/drho_v)(1 - rho_min) d f_v/d alpha_i

and the two differ by a per-voxel factor `p (1 - rho_min) rho_v^(p-1)` — about
0.75 at `rho = 0.5` and **varying across the band**, so it is not even a constant
rescaling that a move limit could absorb.

★ **PR 327 CORRECTED THE MEASURE AND LEFT THE WEIGHT.** `delta` says WHERE the
boundary moves; the weight says WHAT THAT COSTS. They are separate factors of one
product and only the first had ever been differenced. Correcting one and not the
other is why this had to be re-checked rather than inherited.

★ **AND A SINGLE-COEFFICIENT CHECK WOULD HAVE PASSED IT** — 6–7% against the
discrete form's 1.5–1.8%. That is the same trap PR 327's own sub-cell-psi
ablation fell into, arriving a second time: only a general direction, where many
knots combine across the band, separates the two.

`PlsmSensWeight::Discrete` is the default. `Continuum` is reachable, documented
with this table at the site, and is what `B_heaviside` and `C_eta1` run so the
control arms are the controls.

## 3. ITEM 3 — the stopping rule

### (a) `max_iterations = 60` was wrong in BOTH directions

**At the shipped rung 60 is too FEW.** Production's own run of record reports
last-10 compliance spreads of 4.43 / 10.24 / 20.40% on rungs 0.52 / 0.38 / 0.26
under a 40-iteration cap, and says so itself.

**At the light rung MORE IS WORSE.** Stage A, rung 0.5283, margin certified every
20 iterations:

| | it40 | it60 | it80 | it100 | it120 | peak |
|---|---|---|---|---|---|---|
| control | 1682 | 2025 | **2609** | 2344 | 2183 | **it80** |
| C=1 | 1988 | **2385** | 1920 | 2221 | 1931 | **it60** |

Both PEAK then FALL — the control −16.3% from it80, the penalty arm −19.0% from
it60. PR 327 measured the same shape at the shipped rung: a margin peaking at
3276 (iteration 80) and falling **19.4% to 2640 by 120** while compliance was flat
to 0.9% and every certificate said ACCEPTED.

★★ **SO A RAISED CAP IS NOT THE FIX. STOPPING AT THE PEAK RECOVERS 16–24%,
which is twice what the perimeter-penalty argument is about.**

### (b) the rule, as implemented

    every `margin_probe_every` iterations:
        certify the CURRENT design (one tight, cold analyze_fixed_design)
        discard the probe if the design is not load-path connected, or if the
            certification solve did not converge
        improved := margin > best * (1 + margin_plateau_tol)
        stale += 1 when not improved, reset to 0 when improved
        stop when stale >= margin_plateau_probes
    ship THE PEAK ITERATE, not the last and not the best-compliance one

Defaults: **cadence 10, window 3 probes, tolerance 0.5%, hard ceiling 120.**

★ **THE PROBE IS SUPPLIED BY THE DRIVER.** Certifying needs a material, a build
direction, a knockdown posture and an acceptance threshold — four job-level facts
an optimiser has no business learning. `PlsmOptions::margin_probe` is a
`std::function` from a density to `{margin, load_path_ok, non_convergent,
wall_s}`, and `minimize_plastic.cpp` builds it from the SAME arguments the
per-rung certification uses, so an in-loop probe and the rung's own certificate
are one measurement of one object.

★ **The two post-passes that can MOVE a verdict are passed false.** The
orientation scorer and its auto-apply are reading instruments for a rung's final
certificate; a probe is a reading and may not re-seal the direction the run is
certifying against.

★★ **A PROBE THAT IS NOT LOAD-PATH CONNECTED IS DISCARDED, NOT RECORDED.** A
severed design measures ~zero stress and therefore an enormous, meaningless
margin. Taking a maximum over margins without that guard would make the rule
select the worst design in the run — which is the exact shape of
`compliance-is-not-a-proxy-for-the-margin` pointing the other way.

★ **AND IT IS REFUSED, NOT DEGRADED, UNDER MULTISCALE.** A multiscale rung is
certified against the `LatticePosture` built from THAT rung's design, which does
not exist until after `plsm_optimize` returns. A probe could pass only the
previous rung's posture or none, and either would certify a different object than
the rung's own certificate — the loop/export disagreement this repository has
already paid for once. The run keeps the compliance-plateau rule and the receipt
says which rule ran.

### (c) ★ THE CADENCE COST, STATED

A probe is **one tight cold certification solve** — on his part about the cost of
an optimiser iteration, because the trajectory solve runs LOOSE and WARM and the
certification runs TIGHT and COLD. Probing every iteration would therefore more
than double a run.

★ **The cadence is 10 because 10 is what resolved the peak in every curve this
line of work has measured.** PR 327's control reads 3233 / **3276** / 3273 at
iterations 70 / 80 / 90 — so a 10-iteration grid locates the maximum to within
1.3% of its own value, against an endpoint that was missing it by 19.4%. The
measured share of a run is in §0 and in Table 5 of `tables.txt`.

★ **The window is 3 probes = 30 iterations** — wide enough that the control's
3233 / 3276 / 3273 / 3198 tail does not stop it early at iteration 70, narrow
enough to stop before the fall completes.

★ **The tolerance is 0.5%** because twenty consecutive certified iterates of one
converged tail spread **0.15%, sd 0.04% of the mean**. 0.5% is comfortably above
that reproduction floor and well below any real move. A consequence worth naming:
where the margin is genuinely flat the rule returns the EARLIER design, because a
later one inside the tolerance is not an improvement. That is a saving, not a
loss — see the shipped-rung rows in §3(e).

### (d) ★ COMPLIANCE IS NOT A CONVERGENCE PROXY, SO IT IS DISARMED

PR 326 measured one arm's margin **DOUBLE between iterations 40 and 60 while its
compliance moved 2%**, and a compliance-plateau stop halting another task's
control at iteration 56 while its margin was still climbing 3195 → 3395.

★ **So when a margin probe is attached, the compliance-plateau rule DOES NOT
FIRE.** It is not merely outranked — it is gated off, because a rule that can
pre-empt the rule you are testing is a rule that decides the experiment. With no
probe attached (the historical path, and every job that sets
`margin_probe_every: 0`) it is exactly what it was.

### (e) ★★ WHAT THE RULE WOULD HAVE CHOSEN — the evidence it works

`evidence/.../replay_stop_rule.py` replays the shipped logic — the same three
decisions, the same two constants — over every margin curve this line of work has
published. The rule is REPLAYED, not re-described.

| arm | rung | cadence | would stop | would return | actually returned | delta |
|---|---|---|---|---|---|---|
| L0_none, Stage A control | 0.5283 light | 20 | ran out (it120) | it80 **2609.1** | it120 2183.2 | ★ **+19.5%** |
| L1_perim1, Stage A C=1 | 0.5283 light | 20 | it120 | it60 **2384.9** | it120 1930.9 | ★ **+23.5%** |
| E2_c1_eta2, Stage A | 0.7973 shipped | 20 | it100 | it40 3251.4 | it120 3252.3 | −0.0% |
| E1_c1_eta1, Stage A | 0.7973 shipped | 20 | it100 | it40 3251.8 | it120 3251.0 | +0.0% |
| H1_heaviside, PR 327 | 0.68 probe | 10 | it110 | it80 **3276.0** | it120 2640.4 | ★ **+24.1%** |
| F1_frac4, PR 327 | 0.68 probe | 10 | ran out (it50) | it50 3379.0 | it57 compliance-plateau 3379.4 | −0.0% |
| A2_all, PR 327 | 0.68 probe | 10 | ran out (it60) | it50 3392.0 | it61 compliance-plateau 3391.1 | +0.0% |

★★ **THE THREE ARMS THAT TURN OVER RECOVER 19.5 / 23.5 / 24.1%, AND THE FOUR THAT
DO NOT ARE UNCHANGED TO THREE DIGITS.** That is the shape a stopping rule has to
have: it may not cost anything where the curve is flat.

★ **AND ON THE SHIPPED RUNG IT SAVES 80 ITERATIONS FOR −0.03% OF MARGIN.** Both
Stage A shipped-rung arms are flat from iteration 40; the rule returns iteration
40's design and stops at 100. That is `levelset-margin-saturates-before-the-
compliance-plateau`, arriving as a saving.

★ **Two caveats, stated rather than left in the table.** (1) Stage A's curves
were sampled every 20 iterations, so three consecutive non-improving probes span
60 there rather than 30 — the rule stops LATER on that data than it would on a
cadence-10 run, and `L0_none` runs out of samples before it can fire at all. (2)
`F1_frac4` and `A2_all` were stopped by the shipped COMPLIANCE rule before the
margin rule could accumulate a window, so their rows say the two rules agree
where they both fire, not that the margin rule was tested there.

### (f) ★★ WHAT THIS COSTS ON THE DEVICE — SURFACED, NOT BURIED

`bridge.cpp` arms the parametric mode and then says, deliberately, *"Everything
else is left at `PlsmOptions`' own defaults ON PURPOSE"* — so the on-device and
LAN paths inherit **every** default this task changes, which is the right
architecture (core owns the rule) and also means the maintainer should see the
bill before it arrives.

★ **THE ITERATION CEILING DOUBLES, 60 → 120,** and **a certification lands every
10 iterations**. A 128³ re-certification on the device was measured at **101 s**
(`smoothing-is-on-device`), so a four-rung run that used its whole budget would
add roughly **12 probes × 4 rungs × 101 s ≈ 80 minutes** on top of a doubled
optimise budget.

★ **In practice it will be much less than that**, and the reason is the rule
itself: the plateau stops the run, and §3(e) shows it stopping at iteration 100
on the shipped rung while returning iteration 40's design. But "much less" is a
prediction and 80 minutes is the ceiling, so the ceiling is what is written here.

★ **It is diagnosable rather than mysterious**: `run_info.json` carries
`plsm_margin_probe_every`, `plsm_margin_probe_wall_s`, `plsm_stop_reason` and
`plsm_margin_peak_iteration`, so a run that took longer than expected says which
of the two reasons it was.

★ **A device that wants the old budget sets `margin_probe_every: 0` and
`max_iterations: 60`** and gets the historical rule back, byte for byte. That is
an app-track decision and this task does not make it; it is named here because
shipping the core default silently would have made someone find it with a
stopwatch.

## 4. ITEM 4 — the counters ship, the enforcement does not

★ **The verdict is accepted as the brief states it.** The monotone topological
constraint bought **1.7%** of the internal surface over eight arms at matched
iteration 60; in the same study a change of SEED bought 9.4% and cost nothing. A
1.7% mechanism does not justify a production flag.

★ **The counters cost milliseconds and made every other finding legible**, so
they ship: `core/include/topopt/plsm_topology.hpp` reports the void's component
count `b0`, the Euler characteristic `chi`, the cavity count `b2` and the tunnel
count `b1 = b0 + b2 - chi` on **every** parametric run, into the receipt and into
the per-rung `_alpha.meta`. Two examples of what they were worth, both of which
reversed a premise that had already been written down:

* ★ **the void's component count FALLS over a run.** In all eight arms it spiked
  in the first ~6 iterations as the seed dissolved (87 → 439) then decayed to 41.
  The constraint was policing a quantity that was already decreasing.
* ★ **the increase that does occur is SPLITTING, not nucleation.** Of the
  control's largest jump (+425 components), 3 were genuinely new and 422 were
  existing void fragmenting as solid bridged across it.

★ **The 3D caveat is reported, not hidden.** A hole can be TUNNELLED through
material without any new component appearing — the void stays connected and its
genus rises — so `b1` is carried beside `b0`. If `b1` rises while `b0` does not,
the constraint would have been satisfied and evaded at once.

### ★ the escape rule is the manufacturing one, and that is a deliberate difference

`b2` needs a definition of "enclosed", and this repository already has one:
`lattice_void.hpp`'s enclosed-void rule. Its two commitments are adopted verbatim
so that a cavity these counters report and a cavity the lattice pass REFUSES on
are the same object — the void walk is **6-connected** (because the solid walk is
26-connected, and in 3D the complementary sets must take complementary
adjacencies) and the exterior is **the grid's six boundary planes**, reached
through the full not-printed set including the `Empty` voxels outside the part.

★★ **The Stage A sandbox's `plsm_topology.hpp` does NOT do this**: it marks a
component open when it touches any voxel outside its `in_region` predicate, which
includes **FrozenSolid**. A cavity walled in by the anchor pad or a protected face
is counted there as drainable, and it is not — frozen material is material. Per
the brief that defect is raised separately with its own measurement; **what ships
here does not carry it**, and the difference is written at the top of the
production header so the next reader does not "fix" it back.

## 5. WHAT IS NOT IN THIS TASK

* ★ **THE PERIMETER PENALTY (C).** Waits for Stage B. When it lands the decision
  is the maintainer's and it is a trade, not a defect: at the light rung C = 1
  buys **−7.4% n_cut against SIMP** — the first surface result any arm has
  produced that beats SIMP — and costs **8.3 points of margin**.
* `hole_period_voxels` — withdrawn by the matched-volume measurement, which
  showed a seed mechanism REVERSING SIGN across the volume change (the gyroid's
  −12.0% became +5.3% worse than nothing). Seed conclusions do not transfer
  across volumes and period 16 has never been measured at production's.
* the `in_region` drainability predicate defect — raised separately, with the
  measurement, as §4 describes.

## 6. ★ THE DEFECT THIS TASK FOUND WHILE WIRING ITEM 1

★★ **`JobDescription` DUPLICATED `PlsmOptions`' DEFAULTS AS LITERALS, AND THOSE
LITERALS WIN.** `core/include/topopt/job.hpp` carried `plsm_eta_voxels = 2.0` and
`plsm_max_iterations = 60`, and `run_job.cpp` copies every one of those fields
onto `MinimizePlasticOptions::plsm` **whenever a job carries a plsm block** — which
every job that uses the feature does.

★ **So changing the production default alone would have shipped TWO NO-OPS.**
Items 1 and 3 would have been correct in `plsm.hpp`, correct in the header
comment, and dead for every real run. Nothing in the type system objected,
nothing in the test suite objected, and the receipt would have printed the
overriding value as if it were the chosen one.

★ **The fix is not to retype the new numbers in the second place.** Every one of
those fields now reads `PlsmOptions{}.<field>`, so the two cannot drift again,
and the reason is written at the site. This is the same defect class as
`tests-on-value-types-miss-call-sites` and
`app-strut-law-differs-from-core` — one value, two homes, and the wrong home
wins.
