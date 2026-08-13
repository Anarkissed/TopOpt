# plsm-production-settings — ship what is settled

Evidence: `evidence/2026-08-13-plsm-production-settings/` — `./reproduce.sh`
regenerates all of it, and nothing is cloned to do so.

★ **THIS TASK IS THE ONE THAT TOUCHES PRODUCTION.** PR 325 shipped the parametric
level set as a mode; PR 326 and PR 327 measured it in a sandbox and **changed no
production file between them**. Everything below is `core/src`, `core/include`
and the job schema, and every arm runs through `topopt-cli run` on his captured
job — not through `levelset_probe`.

★★ **THE PERIMETER PENALTY IS NOT HERE, AND IT IS NOT COMING.** It was held for
Stage B; Stage B is in and **superseded it** — the robust erode/dilate triple
dominates it on both surface columns at identical margin, and the filters the
reviewer thought might beat both **collapse** at the light rung (margins 510 and
308 against SIMP's 3014). §5 closes the placeholder rather than holding it.

## 0. THE ANSWERS, IN ORDER — one line each

**1. What eta = 1 costs and buys at the shipped rung.** ★ On the `Heaviside`
path it buys **−7.5% of the internal surface** (31,528 → 29,170) and costs
**+8.0% of carved roughness** (7.6090 → 8.2173) at a margin that is a wash
(−1.3%) — Stage A's triangle direction confirmed, **its carved direction
REVERSED**. ★★ **But on the path that SHIPS it buys and costs NOTHING: all three
design-affecting readers of `eta_voxels` sit behind `if (!frac)`, so after §2 the
knob cannot move a design at all.** Its one surviving consumer was reporting a
guarantee it no longer measured, and the enumeration the amendment asked for is
what caught that. §1(c), §1(d), §4b(d).

**2. Whether the finite-difference check passed on the new sensitivity.** ★ **On
the volume, yes, first time: −0.085% and +0.479%, flat across three decades of
step size.** ★★ **On the compliance, NO — and it found a SECOND wrong gradient**:
the CONTINUUM weight every level-set arm since PR 324 has used reads **+56.0% and
+45.0%**, flat to five digits, and the DISCRETE weight that replaced it reads
**−0.31% and +0.97%** on the same solves. §2(g).

**3. What the stopping rule would have chosen on each Stage A arm against what it
returned.** ★ It recovers **+19.5%** on `L0_none`, **+23.5%** on `L1_perim1` and
**+24.1%** on PR 327's control, and is **±0.0%** on the four arms whose curves are
flat — it may not cost anything where there is nothing to gain. §3(e). ★ And run
for real on the production path it is worth **+47.0%** at the light rung
(1728.5 → 2541.4) while using **200 iterations against the 60-cap's 240**. §4b(e).

**4. The iteration count to convergence before and after the volume-fraction
fix.** ★ **Before: it does not converge, it runs out** — all four rungs of both
Heaviside arms stopped on `iteration-ceiling`, 240 iterations, the compliance
plateau never firing once. **After: the margin-plateau rule stops every rung at
40–60**, for 200 iterations total. ★ **But no rung reached the COMPLIANCE plateau
even with 120 available, so PR 327's "57 and 61" is NOT confirmed here** and is
not claimed. §4b(e).

---

### and the three results nobody asked for

★★ **THE VOLUME CONSTRAINT NOW MEANS WHAT IT SAYS.** The fraction lands on SIMP's
printed fraction to **0.04%** at every rung where the Heaviside arms miss by up to
**4.5%** — so every prior margin comparison at the light rung in this line of work
was confounded by mass, invisibly, because `achieved_vf` reported the smoothed sum
and that was on target the whole time. §4b(a).

★★ **THE SURFACE PREMISE IS GONE.** "3× the internal surface" became "+20.3% at
matched volume" and is now **+2.0% at the shipped rung and −3.8% at the light
one** — a WIN over SIMP on both surface columns at the light rung (carved −18.8%)
at a volume matched to 0.02%, **with no perimeter penalty**. §4b(c).

★ **THE STOPPING RULE IS CHEAPER THAN THE CAP IT REPLACES**, which was not the
expectation: 200 iterations plus 20 certifications against 240 iterations.
§4b(e).

---

*(The method is §1–§6; §4b is the campaign. The plain-language section is §8.)*

## 1. ITEM 1 — `eta_voxels`, AND WHY IT IS NOT SIMPLY SET TO 1

★★ **THE AMENDMENT CHANGED THIS ITEM AND THE CHANGE IS RIGHT.** The instruction is
no longer "set eta = 1": it is **ship §2 first, then enumerate every remaining
reader of `eta_voxels` with file and line, and only then decide between tuning it
and deleting it** — because a live knob with no consumer is how the next person
plans against a number that does nothing.

★ **§2 HAS SHIPPED** (the amendment was written before it did), so the
enumeration is answerable and is §1(c). `eta_voxels` **stays at 1.0**, and the
reason is narrower than "it is the better value".

The value itself is one line in `core/include/topopt/plsm.hpp`, and one more in
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

`plsm_heaviside` is GridapTopOpt's, and `H(h/2, eta)` is what a FrozenSolid
voxel's ersatz occupancy comes out at under the smooth boolean, because
`phi_eff <= -h/2` there by construction. At eta = 2 voxels that is **0.737540**;
at eta = 1 it is **0.909155**. ★ So on the `Heaviside` path, halving eta also
stiffens the WHOLE FROZEN SET by 23% — the anchor pad, the load pad and the
protected face — and by the same arithmetic it empties the keep-outs, whose
occupancy falls from **0.262460** to **0.090845**.

★ **IT IS NOT AN ARGUMENT: THE RUN PRINTS IT.** `run_info.json` on the shipped
default reads `plsm_frozen_floor_occupancy: 0.9091549431`, which is `H(h/2, 1·h)`
to ten digits (`evidence/.../path_validation`). That is how item 1 is verified to
be in force rather than merely written down.

★ **It is reported here because the arms measure the two changes together**, so
the margin column between `B_heaviside` and `C_eta1` belongs partly to this one
and not only to the band the shape derivative sees.

★ **Under the volume fraction it stops existing**: a frozen cell is STAMPED to
1.0 and the guarantee is exact rather than a band-width argument. §2(c).

### (c) ★★ EVERY REMAINING READER OF `eta_voxels`, WITH FILE AND LINE

Merged tree, after §2 shipped. `grep` over `core/src`, `core/include` and the app
bridge; the app reads none.

**Affects the DESIGN — and ONLY on the non-default `Heaviside` path:**

| file:line | what |
|---|---|
| `core/src/simp/plsm.cpp:497` | `build_fields` — `plsm_heaviside(-phi_eff, eta)`. ★ inside `else if (!frac)`; **dead under the shipped default.** |
| `core/src/simp/plsm.cpp:547` | `active_volume_at` — the volume constraint. ★ `!frac` branch; **dead under the default.** |
| `core/src/simp/plsm.cpp:763` | the shape derivative's `plsm_dheaviside(phi, eta)`. ★ `!frac` branch; **dead under the default.** |

**Affects a REFUSAL — and this one runs on BOTH paths:**

| file:line | what |
|---|---|
| `core/src/simp/plsm.cpp:298` → `:307` | `plsm_frozen_floor_occupancy` and the load-path throw. |

**Validation, no design effect:** `plsm.cpp:234`.
**Pure plumbing and receipt, no design effect:** `job.cpp:879,916–919`;
`run_job.cpp:269,416–417,434,6665`; `minimize_plastic.cpp:1334`;
`observability.cpp:801`; `pipeline.hpp:982`; `observability.hpp:587`;
`job.hpp:742`; `plsm.hpp:195,378`.

★★ **SO: UNDER THE SHIPPED DEFAULT, `eta_voxels` HAS NO CONSUMER THAT CAN CHANGE
A DESIGN.** All three design-affecting readers sit behind `if (!frac)`.

★★ **AND THE ONE SURVIVING CONSUMER WAS MEASURING THE WRONG THING — THE
ENUMERATION IS WHAT CAUGHT IT.** Under the fraction a FrozenSolid cell is STAMPED
to 1.0 by `build_fields`; it is never sampled and `H_eta` is never evaluated on
it. `plsm_frozen_floor_occupancy` was nevertheless still reporting
`H_eta(h/2) = 0.909155` — a property of a density the run does not use — while
the actual floor was **1.0**. The assertion passed for a reason unrelated to what
shipped and the receipt published the wrong number. ★ **Fixed**: each path now
reports its own floor (the stamp under the fraction, `H_eta` under the
Heaviside), and **the assertion itself is untouched and still fires on both** —
R7 does not permit deleting a check because one path stopped needing it.

### (d) ★ SO WHY NOT DELETE IT — the amendment's own (c), answered

★ **The amendment's two branches are "something reads it → set 1.0 and say what"
and "nothing reads it → propose deleting". The truth is a third thing and it is
worth stating precisely: NOTHING ON THE SHIPPED PATH READS IT, BUT
`PlsmErsatz::Heaviside` IS STILL REACHABLE AND CANNOT RUN WITHOUT IT.**

Deleting `eta_voxels` therefore means deleting `PlsmErsatz::Heaviside` with it,
and that would cost three things this task used and a successor will want:

1. ★ **the control arm.** `B_heaviside` IS the previous production posture; it is
   how §4b can say what changed rather than only what is.
2. **the A/B for the next ersatz.** Anything that replaces the fraction will want
   the same one-flag comparison the fraction got.
3. **PR 324–327's reproducibility.** Four tasks' arms are `H_eta` arms; with the
   enum gone, none of them can be re-run on the production path.

★ **RECOMMENDATION, NOT DONE HERE.** When the fraction has shipped a release and
nobody needs the control, delete `PlsmErsatz`, `PlsmSensWeight::Continuum`,
`eta_voxels` and `plsm_frozen_floor_occupancy`'s eta branch **together, in one
commit** — they are one feature, and removing the knob while leaving the path
would produce exactly the orphan the amendment is warning about. ★ Until then
`eta_voxels = 1.0` is correct **for the only path that reads it**, and the
handoff should not claim it does anything on the path that ships.

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
**0.262460 at eta = 2, 0.090845 at eta = 1** — so a keep-out was never actually
empty, it was a quarter full. Under the fraction it is exactly 0. Nothing in this
task's arms isolates what that was worth; it is named as a consequence, not
claimed as a result.

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

### ★★ AND THE COUNTERS THEMSELVES HAD A DEFECT, WHICH THE UNIT TEST FOUND

The sandbox header computed `tunnels = b0 + b2 - chi` with **`b2` set to the
number of undrainable pockets**. `b2` is a BETTI NUMBER — the solid islands the
void encloses — and drainability is not a Betti number. They are not the same
quantity and not even the same kind of quantity.

★ **The one-line disproof is now a unit test.** A single convex 3×3×3 pocket in a
solid block has `V,E,F,C = 64,144,108,27`, so **chi = 1** (it is contractible),
with `b0 = 1`, `b1 = 0`, `b2 = 0` — and **one sealed pocket**. The substitution
reported `chi = 2` and one phantom tunnel. **Every tunnel count taken that way is
off by the number of sealed pockets.**

`enclosed_solid` (26-connected, complementary to the 6-connected void) and
`sealed_pockets` are now separate fields with separate names, and the test pins
both with a drilled-out positive control beside them — because "no sealed
cavities" must not be a verdict the function returns regardless of its input.

### ★ the counters cross-checked on a REAL design, not only on a 9³ block

A union-find and an alternating sum are easy to get subtly wrong in a way a
toy-shape test cannot see. `crosscheck_topology.py` recomputes all of it with
different code — BFS instead of union-find, explicit cell enumeration instead of
the anchored scan — on SIMP's own rungs:

| SIMP rung | b0 | chi | b2 | b1 | sealed pockets | sealed voxels |
|---|---|---|---|---|---|---|
| 0.68 shipped — shipped C++ | 16 | 16 | 0 | 0 | 10 | 1034 |
| 0.68 shipped — independent | **16** | **16** | **0** | **0** | **10** | **1034** |
| 0.26 light — shipped C++ | 2 | −7 | 0 | 9 | 0 | 0 |
| 0.26 light — independent | **2** | **−7** | **0** | **9** | **0** | **0** |

★ **Every field agrees.** The script says in its own docstring that it is a
one-off and must never become the shipped number.

★ **AND IT REPRODUCES R6's OWN CAVEAT INDEPENDENTLY, ON SIMP.** Sealed void is
**4.60% of the void at the shipped rung and 0.00% at the light one** (1034 voxels
/ 5127.5 mm³ against nothing at all). Trapped powder is a HIGH-DENSITY problem,
so a light rung passing the enclosed-void check says nothing about a heavy one.

## 4b. ★★ THE ARMS — FOUR ARMS, ONE VARIABLE EACH, BOTH RUNGS OUT OF EVERY RUN

Every arm is `topopt-cli run` on his captured job. Consecutive arms differ in one
thing; B, C and D are all capped at 60 iterations so the budget is not a second
variable, and only D → A changes it — which IS item 3.

| arm | ersatz | eta | weight | cap | probe |
|---|---|---|---|---|---|
| `B_heaviside` | `H_eta` at the cell centre | 2 | continuum | 60 | off |
| `C_eta1` | `H_eta` at the cell centre | **1** | continuum | 60 | off |
| `D_fraction` | **the volume fraction, k = 4** | 1 | **discrete** | 60 | off |
| `A_ship` | the volume fraction, k = 4 | 1 | discrete | **120** | **every 10** |

`B_heaviside` is the PREVIOUS production posture exactly — the ersatz, the band
width, the compliance weight and the cap that shipped before this task.

### (a) ★★ THE VOLUME CONSTRAINT NOW MEANS WHAT IT SAYS, AND THIS IS THE BIGGEST RESULT

Printed fraction against SIMP's own, per rung:

| rung | B (eta 2) | C (eta 1) | **D (fraction)** | SIMP | D's error |
|---|---|---|---|---|---|
| 0.68 | 0.7900 | 0.7928 | **0.7969** | 0.7973 | **0.05%** |
| 0.52 | 0.6802 | 0.6889 | **0.6947** | 0.6941 | 0.09% |
| 0.38 | 0.5860 | 0.5977 | **0.6049** | 0.6048 | 0.02% |
| 0.26 | 0.5047 | 0.5199 | **0.5281** | 0.5283 | **0.04%** |

★★ **THE HEAVISIDE ARMS MISS BY UP TO 4.5%; THE FRACTION MISSES BY 0.04%.** It is
not a tuning result — it is what "summing `f_v` IS summing the volume" means.

★★ **SO EVERY PRIOR MARGIN COMPARISON AT THE LIGHT RUNG IN THIS LINE OF WORK WAS
CONFOUNDED BY MASS.** A "rung 0.26" parametric run printed 0.5047 where SIMP
printed 0.5283 — **4.5% lighter**, which at the light rung is worth a great deal
of margin — and nothing in the receipt showed it, because `achieved_vf` reported
the SMOOTHED SUM and that was on target the whole time. This is the same defect
Stage A's `--volume-count` found in the probe (8.9% drift), arriving on the
production path and fixed by construction rather than by a flag.

### (b) the certificates, at both rungs, at last comparable

| rung 0.68 → printed 0.7973 | printed | margin | vs SIMP | mass g |
|---|---|---|---|---|
| **SIMP** | 0.7973 | **3254.4** | — | 543.7 |
| B (eta 2) | 0.7900 | 3297.3 | — | 538.8 |
| C (eta 1) | 0.7928 | 3255.5 | — | 540.7 |
| D (fraction) | 0.7969 | 3263.5 | **+0.3%** | 543.4 |
| ★ **A (shipped)** | **0.7963** | **3271.5** | ★ **+0.5%** | **543.0** |

| rung 0.26 → printed 0.5283 | printed | margin | vs SIMP | mass g |
|---|---|---|---|---|
| **SIMP** | 0.5283 | **3014.1** | — | 360.3 |
| B (eta 2) | 0.5047 | 777.5 | — | 344.2 |
| C (eta 1) | 0.5199 | 1619.2 | — | 354.5 |
| D (fraction) | 0.5281 | 1728.5 | −42.7% | 360.1 |
| ★ **A (shipped)** | **0.5282** | **2541.4** | **−15.7%** | **360.2** |

★ **At the shipped rung the posture that ships is +0.5% over SIMP at 0.1% less
mass.** At the light rung it is still **−15.7% BELOW SIMP** — improved from
−74.2% across the arms, and only D's and A's rows are like-for-like at all. ★ What
remains at the light rung is NOT a mass artefact and is not claimed to be fixed:
**the parametric method is genuinely weaker than SIMP at low volume fraction on
this part**, and that is now measured cleanly rather than confounded.

### (c) ★★ THE SURFACE — ONE PROBE INVOCATION, SIMP IN THE SAME RUN (R5)

| rung 0.68 | n_cut | vs SIMP | carved | CAD mm | mid % | min-feat | volume mm³ |
|---|---|---|---|---|---|---|---|
| **SIMP** | **26,191** | — | **7.5521** | **0.4293** | 85.28% | 5,464 | 440,551 |
| B (eta 2) | 31,528 | +20.4% | 7.6090 | 0.4741 | 60.33% | 3,894 | 436,387 |
| C (eta 1) | 29,170 | +11.4% | 8.2173 | 0.4501 | 67.26% | 4,776 | 442,002 |
| ★ **D (fraction)** | **26,719** | ★ **+2.0%** | ★ **6.9646** | **0.4341** | 82.28% | 5,096 | 444,064 |
| **A (shipped)** | 27,806 | **+6.2%** | **7.4214** | **0.4301** | 82.15% | 5,483 | 443,366 |

| rung 0.26 | n_cut | vs SIMP | carved | CAD mm | mid % | min-feat | volume mm³ |
|---|---|---|---|---|---|---|---|
| **SIMP** | **74,646** | — | **10.2657** | **0.4375** | 99.99% | 5,523 | 288,713 |
| B (eta 2) | 77,883 | +4.3% | 8.4065 | 0.4978 | 38.25% | 3,128 | 268,159 |
| C (eta 1) | 75,647 | +1.3% | 9.4222 | 0.4451 | 45.18% | 4,285 | 282,003 |
| D (fraction) | 73,337 | −1.8% | 8.2827 | 0.4413 | 77.45% | 5,292 | 288,644 |
| ★★ **A (shipped)** | **71,826** | ★★ **−3.8%** | ★★ **8.3380** | 0.4506 | 77.81% | 5,246 | **288,651** |

★★ **THE PREMISE THIS TRACK STARTED FROM IS GONE.** "3× the internal surface"
became "+20.3% at matched volume" became, here, **+2.0% at the shipped rung and
−3.8% at the light one** — and the light-rung row is a WIN over SIMP on both
surface columns (carved 8.3380 against 10.2657, **−18.8%**) at a volume matched
to 0.02%.

★ **AND IT IS THE FIRST SURFACE WIN OVER SIMP THIS LINE OF WORK HAS PRODUCED
WITHOUT THE PERIMETER PENALTY.** The brief notes C = 1 buying −7.4% n_cut at the
light rung as "the first surface result any arm has produced that beats SIMP";
the shipped posture gets −3.8% with no penalty term at all, and Stage B can now
be read against that rather than against a +20% baseline.

★ **B's and C's surface rows at the light rung may NOT be read against SIMP.**
They print 268,159 and 282,003 mm³ against SIMP's 288,713 — 7.1% and 2.3% less
material — so their triangle counts are cheaper for a reason that has nothing to
do with smoothness. Only D and A are volume-matched. **That is (a) again, in the
column where it is easiest to be fooled by it.**

### (d) ★ ITEM 1, ON THE PRODUCTION PATH, AND IT IS NOT WHAT STAGE A MEASURED

`B_heaviside` → `C_eta1` is eta alone:

| | n_cut 0.68 | carved 0.68 | CAD 0.68 | margin 0.68 | margin 0.26 |
|---|---|---|---|---|---|
| eta = 2 | 31,528 | 7.6090 | 0.4741 | 3297.3 | 777.5 |
| eta = 1 | 29,170 (**−7.5%**) | 8.2173 (**+8.0%**) | 0.4501 | 3255.5 (−1.3%) | 1619.2 (★ **+108%**) |

★ **THE DIRECTION ON TRIANGLE COUNT HOLDS AND THE CARVED COLUMN REVERSES.**
Stage A measured −3.6% n_cut and −21.7% CARVED at the shipped volume on the probe
path; on the production path it is **−7.5% n_cut and +8.0% carved — carved gets
WORSE.** Both are "eta = 1 at the shipped volume", and they disagree on a column.
The n_cut direction is confirmed twice; **the carved direction is not, and is
reported as unresolved rather than averaged.**

★★ **AND THE MARGIN CLAIM DOES NOT SURVIVE THE SECOND RUNG.** Stage A found the
margins "identical to three digits" and concluded eta is a surface knob and not a
margin knob. At the shipped rung that reproduces (−1.3%). At the LIGHT rung eta = 1
**more than doubles the margin, 777.5 → 1619.2**. The conclusion was right where
it was measured and wrong as a general statement — which is exactly what R3's
two-rung rule exists to catch.

★ **But part of that +108% is bought, not free**, and the mechanism is (a): eta = 1
prints 3.0% MORE material at that rung, because a narrower band drifts less
between the smoothed sum the constraint targets and the printed set it is meant
to mean. Under the fraction the two coincide and the question stops existing.

### (e) ★★ ITEM 3, ON THE PRODUCTION PATH — AND IT IS CHEAPER THAN THE CAP IT REPLACES

`D_fraction` and `A_ship` differ in TWO settings — the cap and the probe — and
land on the SAME printed fraction (0.5281 against 0.5282). The margin difference
is therefore entirely WHICH ITERATE SHIPS.

    rung 0.26   it10 1367.7   it20 ★2541.4   it30 1784.3   it40 1771.3   it50 1458.0
    rung 0.68   it10 3243.5   it20 3242.4   it30 ★3271.5   it40 3259.3   it50 3238.1   it60 3262.4

★★ **THE LIGHT RUNG'S MARGIN PEAKS AT ITERATION 20 AND FALLS 43% BY ITERATION 50,
AND STOPPING AT THE PEAK IS WORTH +47.0% (1728.5 → 2541.4).** The brief predicted
16–19% from the Stage A and PR 327 curves; on the production path at the light
rung it is **47%**.

| | iterations | optimise wall | probes |
|---|---|---|---|
| B / C / D (cap 60) | 240 | 136.0 / 107.1 / 103.3 min | — |
| ★ **A (the rule, cap 120)** | **200** | **95.0 min** | 20, costing **721.7 s** |

★★ **200 ITERATIONS AGAINST 240, PLUS 20 CERTIFICATIONS AT 36 s EACH.** Counting
every probe as a whole extra iteration that is ~220 iteration-equivalents against
240: **the margin-plateau rule uses LESS machine time than the 60-iteration cap it
replaces, and returns a better design.** The cadence was budgeted in §3(c) as a
cost needing justification. It pays for itself.

★ **AND THE 0.5% BAND EARNED ITS PLACE TWICE.** On rung 0.38 iteration 30 reads
HIGHER than the retained peak — by 0.23%, inside the band and inside the 0.15%
reproduction floor — so iteration 20's design ships. On rung 0.52 the whole tail
spans 0.1% and the rule returns **iteration 10**, +0.2% over SIMP in ten
iterations. Without the band both rungs would have re-selected the shipped design
on noise.

★ **What this task does NOT establish.** Every rung stopped on `margin-plateau`,
so **no rung reached the COMPLIANCE plateau even with 120 available**. PR 327's
"57 and 61 iterations" was on the shipped compliance rule at the probe's volume
convention. The two rules are different rules; this campaign cannot confirm that
claim on the production path and does not.

### (f) ★ ITEM 2(e) — THE COST, CONFIRMED ON THE PRODUCTION PATH

| arm | rung | sampling | sensitivity | rung wall | share | cut cells |
|---|---|---|---|---|---|---|
| D | 0.68 | 17.58 s | 1.24 s | 941.0 s | ★ **1.97%** | 4,009 |
| D | 0.26 | 18.39 s | 1.73 s | 2096.7 s | 0.94% | 5,574 |
| A | 0.68 | 17.90 s | 1.39 s | 1087.6 s | 1.74% | 4,042 |
| A | 0.26 | 15.19 s | 1.45 s | 1756.7 s | 0.93% | 5,579 |

★ **1.97% at the shipped rung against PR 327's 1.92% on the probe path** — the
same number, on a different code path, at a different volume convention. It is
**half that at the light rung** because the state solve is dearer there and the
sampling is not.

★ **The Heaviside arms read 0.00 in both columns.** That is the column's positive
control, not a missing measurement.

### (g) ★ ITEM 4's COUNTERS, ON THE ARMS

| arm | rung | b0 | chi | b2 | b1 tunnels | sealed pk | sealed vox | sealed % |
|---|---|---|---|---|---|---|---|---|
| B | 0.68 | 34 | 25 | 0 | 9 | 22 | 1,602 | 6.88% |
| C | 0.68 | 24 | 16 | 0 | 8 | 9 | 1,979 | 8.61% |
| ★ **D** | 0.68 | **16** | 15 | 0 | **1** | 8 | 1,864 | 8.27% |
| **A** | 0.68 | **17** | 15 | 0 | **2** | 7 | 1,740 | 7.70% |
| **SIMP** | 0.68 | **16** | 16 | 0 | **0** | 10 | 1,034 | 4.60% |
| B | 0.26 | 20 | −7 | 0 | 27 | 18 | 30 | 0.05% |
| D | 0.26 | 4 | −8 | 0 | 12 | 0 | 0 | 0.00% |
| A | 0.26 | 4 | −7 | 0 | 11 | 0 | 0 | 0.00% |
| SIMP | 0.26 | 2 | −7 | 0 | 9 | 0 | 0 | 0.00% |

★ **The fraction HALVES the void component count and lands on SIMP's** — 16 and
17 against B's 34 and C's 24, with SIMP at 16 — and takes the tunnel count from 9
to 1. The counters shipped as a diagnostic and their first real use is to say
that the ersatz change did something structural, not only dimensional.

★ **R6, and the caveat the brief asked to be carried: sealed void is 0.00–0.05%
at the light rung against 4.60–8.61% at the shipped one, on EVERY arm including
SIMP.** Trapped powder is a HIGH-DENSITY problem, so a light rung passing the
enclosed-void check says nothing about a heavy one. ★ The parametric arms still
carry **1.7–2.0× SIMP's trapped VOLUME** at the shipped rung even where their
pocket COUNT is lower, which is `plsm-nucleates-sealed-cavities` surviving the
ersatz change.

## 5. WHAT IS NOT IN THIS TASK

* ★★ **THE PERIMETER PENALTY (C) — THE PLACEHOLDER IS CLOSED, NOT PENDING.**
  Stage B is in and **superseded it**: the ROBUST ERODE/DILATE TRIPLE dominates it
  on both columns at identical margin (shipped rung, n_cut 27,511 against 27,887
  and carved **7.5190 against 9.1155**), and the robust arm's carved roughness
  **beats SIMP outright** — 7.5190 against 7.5521. **Do not hold a slot for the
  penalty; it is not shipping in this task or a successor.**
* ★ **AND THE ROBUST TRIPLE IS BLOCKED, NOT NEXT.** It leaves **14.85% sealed void
  (16,553 mm³)** against a production lattice step that has already REFUSED a PLSM
  design over **337 mm³** — 49× less. A post-hoc gate means running 88 minutes to
  be refused, so drainability has to become a constraint INSIDE the loop, and the
  `in_region` predicate defect has to be fixed first or that constraint measures
  the wrong thing. ★ **That is a separate task and NOTHING HERE WAITS ON IT.**
* ★ **The filters are refuted in the opposite direction to the hypothesis.** The
  reviewer's question was whether the Helmholtz filter at r = 2 or r = 3 might
  clear both rungs and beat the penalty. At the light rung they **collapse** —
  margins 510 and 308 against SIMP's 3014.12, −83.1% and −89.8%. This task's §1
  was written to wait on that answer; the answer is no, and §1 no longer waits.
* ★★ **AND THE NUMBER THAT SHOULD GOVERN WHAT COMES NEXT: NOTHING CLEARS SIMP AT
  THE LIGHT RUNG, INCLUDING DOING NOTHING.** Stage B's unmodified control is
  −27.6%; this task's shipped posture is **−15.7%**, the best of either campaign,
  and still short. That is a property of the parametric method rather than of any
  mechanism, and it is the largest open number on this branch.
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

## 6b. ★ R10 — THE SOLVER POSTURE, BEFORE AND AFTER §2, ON THE SAME JOB

The amendment's hypothesis: the exact fraction narrows the boundary from roughly
four voxels to one cell, **which is harder for a coarsening operator, not
easier**, so §2 might change what PR 329 measured about the latch.

Read from the four arms' own `run_info.json` — same job, same four rungs, the two
Heaviside arms being "before" and the two fraction arms "after":

| | B heav | C eta1 | **D frac** | **A ship** |
|---|---|---|---|---|
| `cg_multigrid` | False | False | **False** | **False** |
| `mg_levels` | 0 | 0 | **0** | **0** |
| `mg_mode` | stagnated-latched | stagnated-latched | **stagnated-latched** | **stagnated-latched** |
| `mg_algebraic_level1` | False | False | False | False |
| `geneo_twolevel` | True | True | True | True |
| `geneo_basis_dim` | 1685 | 1685 | 1685 | 1686 |
| `geneo_basis_builds` | 2 | 2 | 2 | 1 |
| `geneo_armed_solves` | 15 | 4 | 8 | 14 |
| `geneo_declined_solves` | 233 | 244 | 240 | 214 |
| `krylov_recycle_dim` | 16 | 16 | 16 | 16 |
| `solved_grid_dofs` | 1,473,696 | 1,473,696 | 1,473,696 | 1,473,696 |

★★ **THE ANSWER IS NO CHANGE, AND IT IS A CLEAN NEGATIVE.** `mg_mode` is
`stagnated-latched` and `cg_multigrid` false on all four arms. The exact fraction
neither helps nor hurts the coarse space — **because the geometric hierarchy
already fails on this part before boundary width is what matters**, which is
exactly what PR 329 concluded from the other side.

★ **The GenEO counts move but not with the ersatz.** `armed_solves` reads
15 / 4 / 8 / 14 — the FEWEST is `C_eta1`, a HEAVISIDE arm, and the most is a
Heaviside and a fraction arm respectively. The variation tracks how many solves
each arm ran and how its design conditioned, not which density it used.
`geneo_basis_dim` is 1685 on three arms and 1686 on the fourth.

★ **What this does NOT say.** It is one part at one resolution, and `mg_mode` was
already latched before §2 — so this rules out the fraction making coarsening
WORSE on a part where coarsening already fails. It cannot say what the fraction
would do to a part where the hierarchy builds.

## 7. THE BARS

| bar | how it was met |
|---|---|
| **R1** byte-identical where nothing should change | ★ **MET — see §7b.** design.bin, report.json and all four meshes BYTE-IDENTICAL; iterations.csv identical across 240 iterations and 44 columns; `run_info.json` 24 keys added, **0 removed, 0 shared values changed**. ★★ And it took THREE attempts to make the check mean anything — §7b is the retraction. |
| **R2** the new sensitivity, finite-differenced | §2(g). Both functionals, five step sizes, on the SHIPPED header. It found the compliance weight wrong by 45–56%. |
| **R3** every claim at both rungs | §4b throughout. Nominal 0.68 → printed 0.7973, nominal 0.26 → printed 0.5283, SIMP's own margins 3254.36 and 3014.12 read out of production's run of record by `tables.py`, never retyped. |
| **R4** margin as a curve with its peak | §4b(e) prints the probe curve the rule actually watched, per rung. Mass, enclosed volume and CAD error in mm sit beside every roughness number in §4b(c). |
| **R5** SIMP rows from the same probe invocation | One `external_field_surface_probe` call for the whole of §4b(c). ★ And a positive control for it: SIMP's own rung 0.68, dumped and handed back in as an arm, reproduces its internal row to four decimals. |
| **R6** sealed void by the manufacturing definition | §4b(g), through the SHIPPED `plsm_void_topology` for SIMP and PLSM alike, cross-checked against an independent implementation. The caveat is carried: 0.00–0.05% at the light rung against 4.60–8.61% at the shipped one. |
| **R7** no assertion weakened or deleted | `assertion_census.sh`, a MESSAGE census: 3,344 test messages before and after, 121 ctests before and after, **0 removed**, 3 production refusals ADDED. |
| **R8** root cause with file and line, no placeholders | §2(g) names `core/src/simp/plsm.cpp:104`; §6 names `core/include/topopt/job.hpp`. No scratch at the repository root; every large field lives outside the repo under `$SCRATCH`. |
| **R9** separate commit for any review response | Nothing to respond to yet; the branch's history is one commit per finding. |

## 7b. ★★ R1 — AND THE TWO WAYS IT PASSED WITHOUT MEASURING ANYTHING FIRST

### the verdict that counts

    BEFORE  9e96beb (the merge-base with main), checked out in place
    AFTER   this branch, with the OLD defaults PINNED in the plsm block
    binaries b13a13b9... vs 6b2692e7...   (checked DISTINCT by the script)

| artefact | result |
|---|---|
| `design.bin` — every evaluated rung's density field | ★ **BYTE-IDENTICAL** (14,983,608 bytes) |
| `report.json` — every margin, mass and verdict | ★ **BYTE-IDENTICAL** |
| `variant_026 / 038 / 052 / 068 .stl` | ★ **BYTE-IDENTICAL** |
| `iterations.csv`, computed columns | **IDENTICAL** across 240 iterations, 44 columns |
| `run_info.json` | 24 keys added, **0 removed, 0 shared values changed** |

★★ **WHAT THIS ESTABLISHES: EVERY DIFFERENCE THIS TASK PRODUCES COMES FROM A
DEFAULT, NOT FROM AN UNINTENDED CHANGE TO THE MACHINERY.** The new binary,
configured as the old one, reproduces the old one exactly — 240 iterations, every
design byte, every mesh, every certificate. The new paths are genuinely opt-in.

★ **The AFTER run's 240 iterations are themselves the proof the pinning took.**
This task's defaults produce **200** (60/40/50/50, the margin-plateau rule
firing). Had the plsm block been ignored, AFTER would have shown 200 and
`stop_reason: margin-plateau`.

★ **The excluded columns are excluded honestly.** `total_ms`, `solve_ms` and
`fea_ms` DO differ between the two sides — this task fixed the PLSM path's blank
timing block (§4b, and they read 0.000 on the BEFORE side by construction). They
are wall clocks, the comparison excludes wall clocks on both sides for the reason
it always did, and that is stated rather than left for a reader to notice.

### ★★ AND IT PASSED VACUOUSLY TWICE BEFORE IT PASSED HONESTLY

**Attempt 1 reported BYTE-IDENTICAL on every artefact and had compared one binary
with itself.** Two independent causes, both now guarded in the script:

1. ★ **`cmake --build build --target topopt-cli` IS A SILENT NO-OP.** The CMake
   target is `topopt_cli`; `topopt-cli` is the OUTPUT FILE in the build
   directory, so make finds no rule, sees the file, calls it up to date and exits
   **0**. Neither side was ever rebuilt. The tell was `build/topopt-cli`'s mtime
   never moving across a 3.5-hour run. ★ **This is a documented trap in this
   repository and it still landed, because the command arrived INSIDE an
   inherited script rather than being typed.**
2. ★ **The CLI has no SIMP route.** `core/src/cli/main.cpp` (~line 429) sets
   `job.has_plsm = true; job.plsm_enabled = true` unconditionally on `run` and
   REFUSES `plsm.enabled: false`. The script's original premise — "the job
   carries no plsm block, therefore `PlsmMode::Off` holds" — has been false since
   PR 329. **Both sides ran the parametric path**, which is also how (1) was
   caught: both `run_info.json` files said `ersatz: fraction`, and the base
   commit has no such thing.

★ **The guard that makes a repeat impossible**: the script hashes the binary on
each side and REFUSES if they match. A pass now requires a real rebuild.

★ **Attempt 2 aborted in 45 seconds** — the pinned job was written to `$SCRATCH`
without the STEP beside it, and a job names its model relative to its own
directory. `set -e` stopped the run and produced nothing. **A script that fails
loudly on a real problem is the evidence the guards are live.**

★ **SIMP's own byte-identity is NOT this script's to prove**, and `main.cpp` says
why: `run_job` and `minimize_plastic` keep `PlsmMode::Off`, and *"22 test files
call them IN-PROCESS with values pinned from SIMP designs ... those tests are the
evidence that the SIMP code is unmoved."* That evidence is the ctest suite.

## 8. ★ IN PLAIN LANGUAGE

**What this task was asked to do.** Take three settings that earlier experiments
had already settled, put them into the real optimiser, and prove they work on the
real part rather than in a test harness.

**What the three settings are.**

1. *A width knob (`eta`) halved.* The optimiser used to blur the edge of the part
   over four voxels so it could do calculus on it. Halving that blur was measured
   to give a cleaner surface.
2. *How the optimiser measures "how much material is in this cell".* It used to
   ask one question at the centre of the cell — "is the middle of this box inside
   the part?" — and get a yes/no smeared into a maybe. It now measures the actual
   **fraction** of the box that is inside, by sampling 64 points in it.
3. *When to stop.* It used to run a fixed 60 rounds. Sometimes that was too few
   and sometimes the answer got **worse** if you kept going.

**What actually happened, in order.**

★ **Before spending six hours of computer time, I checked the maths.** There is a
standard way to test whether an optimiser's "which way is downhill" calculation is
right: nudge the design a tiny bit, see how much the answer changes, and compare
that with what the calculation predicted. The new cell-fraction calculation passed
— it was right to within a tenth of a percent.

★★ **But the same test found something else, which nobody was looking for.** The
"downhill" calculation has two parts: *where* the edge moves, and *what that
costs*. An earlier task had found and fixed a 23% error in the first part. Nobody
had ever checked the second part. **It was wrong by 45–56%** — and it had been
wrong in every experiment in this line of work for months. The tell is that the
error did not change when I made the nudge ten times smaller; a measurement error
would have moved, a *maths* error does not.

Had I run the experiments first, all six hours of them would have been on the
broken calculation and would have had to be thrown away.

★★ **Then the biggest surprise, from the cell-fraction change.** The optimiser is
told "make the part 26% as heavy". It was reporting that it had hit that target
exactly — and it had, *by its own smeared measure*. But the part it actually
produced was **4.5% lighter than asked**. Every previous comparison against the
old optimiser at that setting was therefore comparing a lighter part with a
heavier one and calling the difference a quality difference. **With the new
measurement the part comes out within 0.04% of the target**, and the comparison
finally means something.

★★ **And then the surface result this whole line of work has been chasing.** The
new optimiser was believed to produce three times as much internal surface as the
old one — later revised to 20% more. Measured properly, at the same weight: **2%
more at the heavy setting, and 4% LESS at the light setting**, where it also comes
out visibly smoother. That is the first time the new method has beaten the old one
on surface at all.

★★ **The stopping rule turned out to be free.** The worry was that checking "is
this design actually strong enough?" every ten rounds would be expensive, because
that check is roughly as costly as a round. It stopped the run so much earlier
that it used **less** computer time than the fixed 60 rounds it replaced — and the
design it returned was **47% stronger** at the light setting, because the strength
peaks around round 20 and then falls away, and the old rule shipped whatever was
there at round 60.

**What is honestly still wrong.** At the lightest setting the new method is still
**16% weaker than the old one** at the same weight. That is not a measurement
artefact and it is not fixed here — it is now simply *known*, cleanly, for the
first time.

**What was deliberately left out.** A fourth mechanism (a "perimeter penalty")
was excluded because a different experiment currently running may beat it, and
adding it now would make that experiment unreadable.

**And four bugs found by needing a number rather than by looking for one:** the
wrong cost calculation above; a topology formula that reported a phantom hole for
every sealed cavity; a settings file that would have silently ignored two of the
three changes this task shipped; and the fact that the optimiser had never
recorded where its time went — every timing column in its log had been zero since
the feature shipped.
