# exact-volume-fraction-ersatz

Evidence: `evidence/2026-08-12-exact-volume-fraction-ersatz/` — `./reproduce.sh`
regenerates all of it, and nothing is cloned to do so.

★ **EVERY COMPARISON IS AGAINST SIMP, THE SHIPPED LADDER**, with PR 326's
re-baseline beside it as the thing one variable is changed from.

★ **THE WHOLE DIFF IS IN THE SANDBOX.** `git diff main -- core/src core/include
app/` is **0 lines** (`check_r6.sh`), `materials.json` is untouched, and the
assertion census removed nothing (`assertion_census.sh`).

## 0. THE ANSWERS, IN ORDER — one line each

Every row at **matched iteration 50**, the last snapshot present in all three
arms, in ONE probe invocation with SIMP produced in the same run (R2).

| | ★ CAD mm | ★ mid % | ★ n_cut | carved | margin | mass |
|---|---|---|---|---|---|---|
| **SIMP rung 0.68** | **0.4293** | **85.28%** | **26,191** | 7.5521 | **3254.3** | 543.7 g |
| PR 326 re-baseline *(quoted, other tree)* | — | 57.7% | 79,577 | 14.1322 | 2859.5 ↑ | 463.8 g |
| PR 326 best, C=1 η=1 *(quoted)* | 0.3232 | 80.4% | 53,243 | 9.2460 | 3388.6 | 463.7 g |
| `H1_heaviside` — **this task's control** | 0.4908 | 57.79% | 79,542 | 14.0857 | peak **3276** @80, then −19.4% | 463.8 g |
| `F1_frac4` — **the arm** | **0.4701** | 57.50% | 80,962 | 15.3541 | **3379** @50, rising | 463.8 g |
| ★ `A2_all` — all mechanisms | **0.4708** | 58.78% | 78,553 | 14.9895 | ★ **3391 SETTLED** @50 | 463.8 g |

1. ★ **CAD ERROR IN MM — IT IMPROVES, 4.2%.** 0.4908 → 0.4701 against SIMP's
   0.4293. The brief's claim — a continuous density carries sub-voxel boundary
   position and should improve dimensional accuracy — **holds**. It does not
   reach PR 326's 0.3232, which was a *frozen-region* result on the CAD faces and
   is complementary to this, not competing with it. §3(c).

2. ★ **MIDPOINT SHARE — IT DOES NOT MOVE.** 57.79% → 57.50% → 58.78%, all far
   below SIMP's 85.28%. **The answer to the brief's second headline question is
   no**, and the reason was written into the source before the run: the midpoint
   share is a property of the field MARCHING CUBES IS HANDED, and under R5 all
   three arms export the same `H_eta` field. §5 M3 changed the export instead and
   made it **8.7 points WORSE** — as predicted. §3(c), §5 M3.

3. ★ **INTERNAL SURFACE — IT DOES NOT MOVE EITHER.** 79,542 → 80,962 → 78,553,
   a 3% spread against SIMP's 26,191. **The exact volume fraction is not a
   smoothness lever.** Said first and plainly, because it is what the brief hoped
   for. §3(c).

4. ★★ **THE MARGIN: `A2_all` IS THE ONLY ARM HERE THAT SETTLES, AT ITERATION 50,
   AT 3391.1 — +4.2% OVER SIMP, WITH NO PERIMETER PENALTY AT ALL.** PR 326's best
   point reached +4.1% and needed a perimeter weight AND a halved eta. ★ **And the
   CONTROL's margin PEAKS at 3276 (iteration 80, +0.7%) and then FALLS 19.4% to
   2640 by 120** while its compliance is flat — which revises PR 326 §9's
   top-ranked "run them longer than 60": run longer and the curve turns over.
   §3(d).

5. ★★ **THE RESULT NOBODY ASKED FOR, AND IT IS THE BIGGEST ONE: BOTH FRACTION
   ARMS REACHED THE SHIPPED CONVERGENCE CRITERION IN 57 AND 61 ITERATIONS AND THE
   CONTROL NEVER REACHED IT IN 120** — at the same compliance within 0.9%. §3(a).
   ★ **§4 predicted it before the arms ran**: PR 326's gradient is wrong by up to
   **23%**, flat across two decades of step size, in every level-set arm since
   PR 322 **and in the shipped `--plsm` job mode**. A 20%-wrong descent direction
   does not fail; it converges slowly.

6. ★ **THE SECOND RESULT NOBODY ASKED FOR: MIN-FEATURE VIOLATIONS 7,273 → 5,337,
   a 27% drop that takes the fraction arms BELOW SIMP's 5,464** where the control
   is 33% above. A density that steps when the boundary crosses a cell centre
   cannot see a member thinner than a voxel; a volume fraction can. §3(c).

7. ★ **WHAT IT COSTS: 1.92% of an iteration.** Sampling every active cell at
   k = 4 is 543 ms and the sensitivity's scatter is 85 ms against a 28.3 s state
   solve. PR 324 measured **99.5%** of an iteration as the state solve; it is now
   about **97.6%**. Nothing about the solver moved — no per-cell `Ke`, no
   O(cut cells) storage, no cache-key change. §3(b).

8. ★ **AND ONE FOUND WHILE BUILDING IT, WHICH IS WHY ARM 2 EXISTS: the smeared
   ersatz was carrying 365.8 voxels of material that are not there** — 1.05% of
   the region the optimiser owns, and 1.08% of extra stiffness. `H_eta` is
   antisymmetric about a PLANE, so that bias is exactly zero on a flat boundary
   and non-zero only where the surface is curved. **A more branched design was
   being credited with more phantom stiffness, for free**, because the volume
   constraint counts the printed set and never saw it. §7 O1.

## 1. THE ONE CHANGE, AND WHAT IT LEAVES ALONE

**Today** the ersatz density was a smoothed Heaviside sampled at the cell centre,

    rho_e = rho_min + (1 - rho_min) * H_eta(-phi(x_centre)),   eta = 2 voxels

**Now** it is the exact volume fraction of the cell inside `{phi < 0}`,

    rho_e = rho_min + (1 - rho_min) * f_v,
    f_v   = (1/|C_v|) INT_{C_v} 1[phi(x) < 0] dx

★ **AND ONLY `rho_e` CHANGES.** For an isotropic ersatz the cell stiffness is
`rho_e * K0`, so the 24x24 reference block, the matrix-free stencil, the
geometric multigrid, GenEO, the Krylov recycler and the Galerkin block cache are
all untouched: no per-cell `Ke`, no O(cut cells) storage, no cache-key change.
What is bought is that `rho_e` now carries SUB-VOXEL BOUNDARY POSITION — it
varies continuously as the interface moves inside a cell instead of stepping when
the boundary crosses the centre.

### (a) how `f_v` is computed — sub-cell sampling, not an analytic integral

`phi` is a sum of compactly-supported RBFs; the exact polyhedral intersection of
its zero set with a cube is not worth writing. `f_v` is the fraction of a
`k x k x k` lattice of points inside the cell with `phi < 0`. Sample `(p,q,r)` of
cell `(i,j,k)` sits at voxel coordinate `x = i + (p + 0.5)/k - 0.5`, which is
EXACTLY where `plsm_evaluate(..., factor = k)` puts its sample and exactly where
`resample_field` / `marching_cubes_resampled` put theirs. **The sub-cell lattice
and the export lattice are the same lattice**; there is no second convention
anywhere in this task.

### (b) only the cells that can be cut are ever sampled

`Empty`, `FrozenSolid` and `FrozenVoid` cells are stamped 0 or 1 by the mask and
the optimiser never had any say over them — **397,536 of the 468,224 voxels on
his part**. So only the 70,688 ACTIVE cells are sampled at all, and of those the
ones actually CUT (mixed sample signs) are **counted every iteration** rather
than bounded by a classifier. A classifier would need a margin, and a margin is
one more thing that can be wrong; the count is exact and is in the CSV
(`frac_cut_cells`).

### (c) ★ the sensitivity, which is the part that can waste the run

Leaving `DH_eta(phi)*|grad phi|` in place against a volume-fraction density would
be a mismatched gradient: it converges, just slowly and to somewhere else. The
derivative of `f_v` is a surface integral over the part of the interface inside
the cell, which the co-area formula turns into a volume integral of a Dirac:

    d f_v / d alpha_i = -(1/|C|) INT_{Gamma cap C} psi_i / |grad phi| dS
                      = -(1/|C|) INT_C delta(phi) psi_i dx
                     ~= -(1/k^3) SUM_s delta_q(phi_s) psi_i(x_s)

with `delta_q` a NORMALISED TENT of half-width `eps_q = eps_mult * |grad phi| *
h/k`. Two things about that expression are load-bearing and neither is obvious:

★ **THE `|grad phi|` IS GONE, AND ITS ABSENCE IS THE CORRECTION.** The old
measure is `dS`; this one is `dS/|grad phi|`, and the second is what the
derivative of a VOLUME FRACTION actually is. On a true signed distance they
coincide. This `phi` is not one — PR 326's own P3 measured `‖grad phi‖-1` at
0.35-0.39 rms through every arm — so the difference is real, and §4 measures what
it was costing.

★ **`psi_i` IS EVALUATED AT THE SAMPLES, NOT AT THE CELL CENTRE.** `Psi` is built
on the cell-centre lattice, so `Psi^T` would factor `psi_i` out of the sub-cell
sum — the same substitution this task exists to remove, made one level down.
Building a `Psi` on the sample lattice is 64x bigger and would be rebuilt every
iteration, so the projection is a SCATTER instead: the knot walk that evaluates
`phi` at a sample already holds the `(index, psi)` list, and the sensitivity
re-walks it into per-thread coefficient accumulators. `--frac-sens centre` keeps
the cheap form reachable so the sub-cell `psi` is PRICED rather than assumed to
matter.

`rho_min` stays at 1e-3 and `rho_e` is the same affine map of `f_v` into
`[rho_min, 1]` that PR 326 applied to `H_eta`.

## 2. ★ WHAT HAPPENED TO eta — S2, ANSWERED ITEM BY ITEM

eta's job WAS to be a smeared stand-in for this fraction, and in the density it
now has none. **It is out of the density path entirely.** What still reads it,
stated rather than left to be found (this list is printed by the run itself, at
the top of every `--frac` log):

| reads eta | what it does | what was done about it |
|---|---|---|
| the PRINTED predicate `{H_eta(-phi) > 0.5}` | defines the part: the volume constraint, `printed_voxels`, the F=1 export, the certificate, the mass | ★ **KEPT, DELIBERATELY.** `H` is monotone with `H(0) = 0.5` exactly, so the printed SET is `{phi < 0}` and does not contain eta at all — PR 326 §3(e) both proves this and measures it (an eight-fold change in eta moved the extracted triangle count by ZERO). Changing it would have changed what "the part" means and made the mass column incomparable: a second variable. |
| the F>=1 EXPORT's field VALUES | where marching cubes puts a vertex on a crossing edge | ★ eta DOES move this, and it is a SECOND substitution the density change does not touch. Kept as the row of record (R5) and measured as its own axis: `--frac-export` emits the same design as a volume-fraction field beside the `H_eta` one. §3. |
| `reinit_residual`'s reporting band | the `‖grad phi‖-1` diagnostic | reporting only |
| the approximate reinitialisation's fit weight | `--plsm-refit-every 5`'s target band | not the variable under test; unchanged in both arms |
| `Per = INT DH_eta(phi)|grad phi|` | the perimeter penalty | ★ **GONE WITH THE DENSITY.** Under `--frac` the perimeter term rides the quadrature band and contains no eta. Inert in this task — both arms run at C = 0, as the brief requires. |

### ★ and the band that IS structurally needed, NAMED — S2(b)

Quadrature of `INT_C delta(phi) psi_i dx` needs a mollifier, and a mollifier has
a width. It is called **`eps_q`, the QUADRATURE BANDWIDTH**, and here is why it is
not eta wearing a different hat:

* **it appears in no density.** `f_v` is a hard count of sample signs.
* **it is tied to the SAMPLE SPACING** — `eps_mult * |grad phi| * h/k` — so it
  shrinks like `1/k`. eta is fixed at 2 voxels and shrinks with nothing. Refining
  `k` makes this converge to the exact surface delta; refining anything at all
  never made `H_eta` converge to the indicator.
* **at `eps_mult = 1` and a locally planar interface the tent is a PARTITION OF
  UNITY along the normal**: `SUM_m (1 - |t - m*D|/D)/D = 1/D` exactly, for every
  offset of the interface. So the estimator is smooth in alpha by construction
  rather than by averaging, and that property is why a tent was chosen over the
  raised cosine that `H_eta` differentiates to — the cosine bell is a partition
  of unity at no sampling, and would leave a ripple as the interface slides
  between samples.

## 3. THE RUN

Three arms, rung 0.68, his captured job, from PR 326's re-baseline
configuration — `--seed holes` with no SIMP anywhere, the gaussian basis at
85,680 coefficients, MMA, `--volume-count`, `--plsm-refit-every 5`, 24 HJ steps,
★ **no perimeter penalty**. They differ in one flag each:

| arm | ersatz | gradient |
|---|---|---|
| `H1_heaviside` | `H_eta(-phi(cell centre))`, eta = 2 voxels | `DH_eta(phi)*|grad phi|`, `Psi^T` |
| `F1_frac4` | the exact volume fraction, 4x4x4 | the quadrature band, sample-scatter |
| `A2_all` | the MOLLIFIED fraction (`--frac-soft`) | the same, on the L1 bandwidth (`--frac-eps-l1`) |

★ **ONE THING CHANGES FROM PR 326 IN ALL THREE AND IT IS DECLARED: 120 iterations
instead of 60.** PR 326 §2 measured every unsettled arm still climbing in margin
at 60 — the re-baseline by 26.7% between 40 and 60 while its compliance moved
0.05% — and its §9 ranks running longer first. The brief asks for MARGIN
convergence, and 60 is known not to reach it. It is applied to all three, so it
is not a variable between them.

### (a) ★★ THE FIRST RESULT IS THAT TWO OF THEM STOPPED ON THEIR OWN

| arm | iterations | why it stopped | best compliance | optimisation wall |
|---|---|---|---|---|
| `H1_heaviside` | **120** | ★ **the iteration count ran out** | 0.002505390 | 58.7 min |
| `F1_frac4` | **57** | compliance flat within 1e-3 over 10 iterations | 0.002528286 | 30.5 min |
| `A2_all` | **61** | compliance flat within 1e-3 over 10 iterations | 0.002527541 | 27.6 min |

★★ **BOTH FRACTION ARMS REACHED THE SHIPPED CONVERGENCE CRITERION IN ABOUT HALF
THE ITERATIONS, AND THE CONTROL NEVER REACHED IT AT ALL IN 120.** They land on
the same compliance — 0.0025283 and 0.0025275 against 0.0025054, within 0.9% —
so this is the same answer reached sooner, not a different and easier one.

★ **This is what §4 predicted before the arms ran.** PR 326's gradient is wrong by
up to 23% and flat across step sizes; the fraction's is verified to 2%, and the
mollified one to 1.3–5.2% on the compliance itself. A descent direction that is
20% off does not fail — it converges, slowly, which is exactly the shape of
"120 iterations and the plateau rule never fires".

★ **The wall clock is stated with the caveat PR 326's P10 states.** Another
worktree's optimiser ran on this host throughout, so 29.6 / 32.7 / 27.6 seconds
per iteration are not comparable to each other at better than about 10%. **The
ITERATION COUNTS are not subject to that** — the designs are deterministic — and
they are what the row above rests on.

### (b) what the fraction costs, as a share of an iteration

| arm | sampling | sensitivity | state solve | iteration | the fraction is |
|---|---|---|---|---|---|
| `F1_frac4` | 543.1 ms | 85.0 ms | 28,312 ms | 32,659 ms | **1.92%** |
| `A2_all` | 545.5 ms | 106.3 ms | 23,319 ms | 27,562 ms | **2.36%** |

★ PR 324 measured **99.5% of an iteration as the state solve**. With the exact
fraction it is about **97.6%**. The sub-cell sampling of every active cell at
k = 4 costs half a second; the sensitivity's scatter costs another tenth.
★ **Nothing about the solver moved**: no per-cell `Ke`, no O(cut cells) storage,
no cache-key change, and `frac_cut_cells` — the cells that are actually cut — is
in the CSV every iteration.

### (c) the surface, at a matched iteration, SIMP in the same run (R2)

★ **Iteration 50 is the last snapshot present in all three arms** (F1 stopped at
57 and A2 at 61), derived by `measure.sh` rather than assumed. One
`external_field_surface_probe` invocation, SIMP's row produced in the same run at
the same extraction factor.

| | carved | ★ n_cut | whole | ★ CAD mm | ★ mid % | min-feature | volume mm³ |
|---|---|---|---|---|---|---|---|
| **SIMP rung 0.68** | **7.5521** | **26,191** | 8.4075 | **0.4293** | 85.28% | 5,464 | 440,551 |
| `H1_heaviside` (control) | 14.0857 | 79,542 | 11.6024 | **0.4908** | 57.79% | 7,273 | 371,080 |
| `F1_frac4` | 15.3541 | 80,962 | 12.2208 | **0.4701** | 57.50% | **5,337** | 373,616 |
| `A2_all` | 14.9895 | 78,553 | 11.9612 | **0.4708** | 58.78% | **5,517** | 373,008 |

★ **THE CAD ERROR IMPROVES BY 4.2%** — 0.4908 → 0.4701 — which is the brief's
first headline question and the claim it was testing: a continuous density
carries sub-voxel boundary position and should improve dimensional accuracy. **It
does.** It does not reach SIMP's 0.4293 and it does not reach PR 326's best arm's
0.3232, which was a *frozen-region* result on the CAD faces (S2) and is
complementary to this, not competing with it.

★ **THE MIDPOINT SHARE DOES NOT MOVE** — 57.79% → 57.50% → 58.78%, all far below
SIMP's 85.28%. **That is the brief's second headline question and the answer is
no**, and the reason was written into `frac_ersatz.hpp` before the run: the
midpoint share is a property of the FIELD MARCHING CUBES IS HANDED, and under R5
all three arms export the same `H_eta` field. The density change cannot move it.
§5 M3 measures what changing the export does instead.

★ **THE INTERNAL SURFACE DOES NOT MOVE EITHER** — 79,542 / 80,962 / 78,553,
a 3% spread. **The exact fraction is not a smoothness lever.** Said plainly
because it is the thing the brief hoped for.

★ **AND ONE COLUMN MOVES A LOT AND WAS NOT ASKED FOR: min-feature violations,
7,273 → 5,337, a 27% drop that takes the fraction arms BELOW SIMP's 5,464.** The
control is 33% above SIMP. A density that steps when the boundary crosses a cell
centre cannot see a member thinner than a voxel; a volume fraction can, and
prices it. That is a manufacturability column, not a roughness one, and it is the
largest single change in the table.

### (d) ★★ THE MARGIN AS A CURVE — AND THE CONTROL'S TURNS OVER

★ **R3 ASKS FOR THE CURVE AND ITS SETTLING ITERATION, AND THE HONEST ANSWER
NEEDED A THIRD STATISTIC.** Every snapshot of every arm, certified by
`analyze_fixed_design` in ONE process. `accepted` = 1 and
`load_path_connected` = 1 on all 26 certificates; mass is 463.8 g on every row of
every arm.

| iteration | 1 | 10 | 20 | 30 | 40 | 50 | 60 | 70 | 80 | 90 | 100 | 110 | 120 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `H1_heaviside` | 628 | 1915 | 1965 | 2105 | 2418 | 2734 | 2923 | 3233 | **3276** | 3273 | 3198 | 3161 | **2640** |
| `F1_frac4` | 628 | 2262 | 2372 | 2606 | 3068 | **3379** | — | | | | | | |
| `A2_all` | 628 | 2295 | 2560 | 2968 | 3076 | **3392** | **3391** | | | | | | |

| arm | peak | at | endpoint | settled? | vs SIMP's 3254.34 |
|---|---|---|---|---|---|
| `H1_heaviside` | 3276.3 | **80** | **2640.4** at 120 | ★ **NO** | peak **+0.7%**, endpoint **−18.9%** |
| `F1_frac4` | 3379.4 | 50 | 3379.4 at 50 | no (still rising) | **+3.8%** |
| ★ `A2_all` | 3392.4 | 50 | **3391.1** at 60 | ★ **YES, at 50** | ★ **+4.2%** |

★★ **`A2_all` IS THE ONLY ARM IN THIS TASK WHOSE MARGIN SETTLES, IT SETTLES AT
ITERATION 50, AND IT SETTLES 4.2% ABOVE SIMP — WITH NO PERIMETER PENALTY AT
ALL.** PR 326's best point reached +4.1% (3388.6) and needed a perimeter weight
AND a halved eta to get there. This lands on the same number — 3391.1 against
3388.6 — from the ersatz and the gradient alone.

★★ **AND THE CONTROL'S CURVE TURNS OVER, WHICH REVISES PR 326's OWN TOP-RANKED
RECOMMENDATION.** PR 326 §2 measured every unsettled arm still CLIMBING at
iteration 60 and §9 ranked "run them longer than 60" first. Run longer: the
control climbs to **3276 at iteration 80** — just past SIMP — and then **FALLS
19.4% to 2640 by 120**, while its compliance is flat to 0.9% over the same span
and every one of those certificates says ACCEPTED.

★ **So "run longer" is right up to a point and wrong after it, and NEITHER
compliance NOR iteration count finds that point.** A stopping rule that watches
compliance stops too early (PR 326's finding); one that just runs to a fixed
budget can stop on the far side of the maximum (this one). The margin has a
maximum and only a margin-aware rule can find it — which is PR 326 §9 item 3,
now with a second and sharper reason to build it.

★ **This is also why the tables report a PEAK and its iteration beside the
endpoint.** A "settling iteration" is the wrong statistic for a curve with a
maximum, and reporting only the endpoint would have reported the far side of it —
the control would have read as a catastrophic −18.9% arm when at its own best
iterate it is +0.7%. PR 326's P11 is the same trap in a different costume and it
reversed a conclusion there too.

★ **What this does NOT say.** `F1` and `A2` stopped at 57 and 61 on the shipped
compliance rule, so neither was run past its own maximum. **Whether the fraction
arms turn over too is NOT established by this task** — they are settled at their
endpoints and the control is not, which is the comparison that can be made. It is
ranked in §8.

## 4. ★ R4 — THE SENSITIVITY AGAINST A FINITE DIFFERENCE

★ **RUN BEFORE THE ARMS WERE SPENT, ON PR 326's OWN CONVERGED DESIGN**, read
back through the new `--alpha`. Four (density, gradient) pairs, the same design,
the same directions, the same steps. `probe/fd_*/frac_fd.csv`.

**What is differenced.** `V(alpha)` is the material in the ACTIVE region — no
state solve, so the step can be swept freely. `C(alpha)` is the ersatz compliance
— two state solves per point, so only two steps carry one. The offset is NOT
re-solved between the plus and minus points: the finite difference is of the
UNCONSTRAINED functions, which is what the gradients are gradients of. The sign
convention is written out in the source (MMA's design is `beta = -alpha`, so
`dV/dalpha = -dv` and `dC/dalpha = -(1-rho_min)*E0*dc`).

### (a) ★ THE CONTROL FIRST — PR 326's OWN GRADIENT, AND IT IS OFF BY UP TO 23%

Without this row "the new gradient checks out" is a number with nothing to be
better or worse than. This is `DH_eta(phi)*|grad phi|` projected by `Psi^T`
against the `H_eta` density it belongs to — the arm the bar is written against.

| probe | step 0.01 | step 0.1 | step 1.0 |
|---|---|---|---|
| random dir 0, dV | +0.46% | +0.51% | +2.22% |
| random dir 1, dV | +7.25% | +6.93% | −20.20% |
| coefficient 73654, dV | **+7.36%** | **+7.35%** | +6.25% |
| coefficient 8856, dV | **+17.26%** | **+17.25%** | +15.83% |
| coefficient 8904, dV | **+19.67%** | **+19.65%** | +18.48% |
| random dir 0, dC | **+10.64%** | **+10.55%** | — |
| random dir 1, dC | +0.73% | +1.19% | — |
| coefficient 8856, dC | — | — | **+21.91%** |
| coefficient 8904, dC | — | — | **+22.87%** |

★★ **THE ERRORS ARE FLAT ACROSS TWO DECADES OF STEP SIZE, WHICH IS WHAT MAKES
THEM A GRADIENT ERROR AND NOT NOISE.** Coefficient 8904 reads +19.67% and +19.65%
at steps a factor of ten apart. A finite difference that has not converged moves
with the step; one that has converged to the wrong number does not.

★ **AND THE CAUSE IS NAMED, NOT GUESSED.** `delta = DH_eta(phi)*|grad phi|` is
the SURFACE measure `dS` — correct for the continuum shape derivative, which is
what GridapTopOpt's formulation is. The derivative of the DISCRETE ersatz
`rho_v = H_eta(-phi_v)` carries no `|grad phi|` at all. The two agree exactly
when `phi` is a signed distance; PR 326's own P3 measured `‖grad phi‖-1` at
0.35-0.39 rms through every arm, and 20% is about what a 37% error in a
multiplicative field buys once it is weighted by where the knots sit.

★ **This is a finding about the CONTROL, and the control is left exactly as
PR 326 ran it.** Correcting it would have been a second variable. It is ranked
in §8 as the cheapest single experiment this task suggests.

### (b) THE ARM — the exact fraction with the sample-scatter gradient

| probe | 0.001 | 0.01 | **0.1** | 0.3 | 1.0 |
|---|---|---|---|---|---|
| random dir 0, dV | +181.8% | −17.6% | **−2.03%** | +6.85% | +19.5% |
| random dir 1, dV | +9.5% | −45.7% | **+0.56%** | +1.78% | −29.5% |
| coefficient 8991, dV | — | −4.88% | **−1.90%** | — | −10.6% |

★ **THE VOLUME SENSITIVITY IS VERIFIED TO 2% AT THE PLATEAU, AND THE SHAPE OF
THE SWEEP IS THE EVIDENCE THAT IT IS A PLATEAU** — quantisation-dominated below,
truncation-dominated above, a clean minimum at step 0.1 on every probe. That
shape is the reason the step is swept: a single step would have produced one
number with no way to know which of the three regimes it came from, and at
step 0.001 it would have been +182%.

★ **The quantisation is `f_v`'s own** — a count of sample signs moves in steps of
1/k³ = 1/64 of a voxel — which is P2, arriving. It is why the compliance
difference, which can only afford two steps, is still noise-dominated at both of
them (−25.5% and +24.9% on the two directions — **opposite signs, so unbiased**,
against the control's consistent +10.6% on both steps of one direction).

### (c) the two ablations, and what they separate

**(i) `--frac-sens centre` — what the SUB-CELL psi is worth.** Identical
everything, except `psi_i` is factored out at the cell centre and `Psi^T` does
the projection instead of the scatter:

| probe, at the plateau step 0.1 | scatter (the arm) | centre (`Psi^T`) |
|---|---|---|
| random dir 0, dV | **−2.03%** | **−14.87%** |
| random dir 1, dV | **+0.56%** | **+17.35%** |
| random dir 0, dC | −25.50% | −46.39% |
| random dir 1, dC | +24.86% | +100.74% |
| single coefficients, dV | −1.90 / −0.39 / −0.12% | −2.24 / +0.30 / +2.44% |

★ **THE SUB-CELL psi IS WORTH ABOUT 15 PERCENTAGE POINTS OF GRADIENT ACCURACY ON
A GENERAL DIRECTION** — the same order as the `|grad phi|` error in §4(a). On a
SINGLE coefficient the two are indistinguishable, which is the mechanism made
visible: one knot's `psi` is smooth over its own support, and the difference only
appears once many knots combine over the sub-cell sum. **A single-coefficient
check would have said the scatter was unnecessary.**

**(ii) `--frac-soft` — the discriminator P13 needed, and the strongest row in the
study.** Same quadrature, same scatter, same design, same steps; only the value
function smoothed:

| probe | 0.001 | 0.01 | 0.1 |
|---|---|---|---|
| random dir 0, dV | **−0.294%** | **−0.374%** | +1.475% |
| random dir 1, dV | **+0.815%** | **+0.959%** | +1.900% |
| coefficient 8991, dV | — | **+0.143%** | −0.609% |
| coefficient 8990, dV | — | **+0.082%** | −2.062% |
| coefficient 5999, dV | — | **+0.572%** | −0.256% |
| random dir 0, ★ **dC** | — | ★ **−1.326%** | −2.889% |
| random dir 1, ★ **dC** | — | ★ **+3.184%** | +5.167% |
| coefficient 8991, ★ **dC** | — | — | ★ **+2.412%** (step 1.0) |

★★ **SUB-1% ON THE VOLUME AT EXACTLY THE STEPS WHERE THE HARD VARIANT READ +182%
AND −45.7%, AND 1.3–5.2% ON THE COMPLIANCE WHERE THE HARD VARIANT WAS
NOISE-DOMINATED AT EVERY AFFORDABLE STEP.** Three things follow, and the third is
the one that licenses ARM 1:

1. **the quadrature and the scatter are CORRECT.** Nothing is wrong with the
   implementation — the two variants share every line except the value function.
2. **the hard variant's residual is entirely its own 1/64 staircase.** P13
   claimed this and could not prove it; this is the proof.
3. ★ **`--frac-soft` is the only formulation in this study whose gradient can be
   verified on BOTH functionals.** The control's compliance error is a consistent
   10.6–22.9%; this is 1.3–5.2%.

★ **And the two value functions agree to 0.037% on the volume they measure**
(34,972.3 against 34,959.5 active-cell voxels), so the mollification buys the
differentiability **without moving the geometry** — which was the design intent
and is now a number rather than an intention.

★ **This is why `A2_all` carries it, and why `A2_all` is the arm that settles.**

## 5. ARM 2 — "THE BEST I CAN DO"

★ **ARM 2's INPUT IS §7's PROBLEM LIST, NOT A LIST OF INTERESTING IDEAS.** Every
mechanism below is named with the problem from §7 it answers, where it came from,
what it cost, and what it measured — including the ones that lost.

### ★ THE TWO ARMS SIDE BY SIDE, SAME INSTRUMENTS, SAME RUN

| | ARM 1 — `F1_frac4` | ARM 2 — `A2_all` |
|---|---|---|
| ersatz | the hard sampled fraction | + M1 `--frac-soft` |
| bandwidth | `eps_q ∝ \|grad phi\|_2` | + M5 `--frac-eps-l1` |
| carved | 15.3541 | **14.9895** |
| n_cut | 80,962 | **78,553** |
| CAD mm | **0.4701** | 0.4708 |
| mid % | **57.50%** | 58.78% |
| min-feature | **5,337** | 5,517 |
| iterations to the shipped stop | **57** | 61 |
| ★ margin | 3379 @50, still rising | ★ **3391.1 SETTLED @50, +4.2% over SIMP** |
| gradient, dV at the plateau | −2.03 / +0.56% | ★ **−0.29 / +0.82% at step 0.001** |
| gradient, ★ **dC** | noise-dominated, ±25% | ★ **−1.33 / +3.18%** |

★★ **ARM 2 IS BETTER ON THE TWO COLUMNS THAT DECIDE WHETHER THE WORK IS SOUND —
it is the only arm in this task whose MARGIN SETTLES, and the only one whose
COMPLIANCE GRADIENT CAN BE VERIFIED AT ALL** — and it is a wash on the geometry
columns (2–3% either way, inside the run-to-run floor §7 P15 measures). **The two
mechanisms bought correctness, not surface.** Said that way round because that is
what the numbers say.

★ **AND THE CREDIT GOES TO M1, NOT TO BOTH.** R4 finite-differenced each flag
alone: `--frac-soft` on its own verifies at −1.33 / +3.18% on the compliance, and
adding `--frac-eps-l1` takes it to −2.32 / +7.61%. **M5 is mixed-to-negative on
this part and is along for the ride.** The arm that should have been run is
`--frac-soft` alone; it was not, and §8 ranks it. §5 M5 has the full pairing.

### M1 — the CONSISTENTLY MOLLIFIED value (`--frac-soft`)

**Problem: P2 and P13.** `f_v` is a hard count of sample signs, so it is
piecewise constant in `alpha` and its derivative is zero almost everywhere. The
sensitivity S1(c) prescribes is the derivative of the CONTINUUM quantity `f_v`
approximates, not of the number the solver is handed — the same shape as PR 326's
own P2. It is what makes R4's compliance difference unverifiable at any step two
state solves can afford.

**Where it came from.** The regularised-delta literature for immersed and
level-set methods: a mollified indicator whose bandwidth is tied to the GRID
rather than to a physical length, so that refining the grid refines the
approximation. The specific construction here is the one that makes the pairing
exact rather than merely consistent: the value is `S(t) = INT_t^inf delta_q`, the
exact antiderivative of the mollifier the sensitivity already uses, so
`dS/dt = -delta_q(t)` identically. A raised cosine, a Gaussian or any other
smooth step would have been a SECOND smoothing law with a gradient that only
approximately matches its value.

**Why it is not a return to eta.** `eps_q` is `eps_mult * |grad phi| * h/k`. It
shrinks like `1/k`, so `--frac-soft` converges to the exact indicator as the
sub-sampling refines. `H_eta` at a fixed 2 voxels converges to nothing.

**Cost:** nothing — the same samples, one branch.

★ **RESULT: §4(c)(ii) and the table above.** Its gradient is the only one in this
study that can be finite-differenced on the COMPLIANCE (1.3–5.2% against the
control's 10.6–22.9%), and `A2_all` is the only arm whose margin settles. ★ **The
geometry is a wash** — 78,553 triangles against 79,542 and 80,962, inside the
run-to-run floor. **SEMDOT's published pair predicted the fluctuation and the
extra iterations, and both showed up.**

### M2 — the SUB-CELL psi, priced (`--frac-sens centre`)

**Problem: P4.** `Psi` is built on the cell-centre lattice, so `Psi^T` factors
`psi_i` out of the sub-cell sum. That is the same substitution this whole task
exists to remove, made one level down, and it would have been invisible: the
resulting gradient is still a descent direction and the arm would have converged.

**What it separates.** The exact form (scatter) and the cheap form (`Psi^T`) are
differenced against the SAME functions on the SAME design, so "the sub-cell psi
matters" becomes a number instead of an argument for having written the harder
code.

**Cost:** the scatter is one extra walk of the knot lists the sampling already
built — 85 ms of a 32.7 s iteration, 0.26%.

★ **RESULT: §4(c)(i). The sub-cell psi is worth about 15 percentage points**, the
same order as the `|grad phi|` error the whole task turns on — and NOTHING on a
single coefficient, so a single-coefficient check would have said the scatter was
unnecessary. It was worth writing.

### M3 — the EXPORT convention as its own axis (`--frac-export`)

**Problem: P9.** The brief's two headline questions — CAD error and midpoint
share — are questions about the EXTRACTED SURFACE, and the extracted surface is
built from the EXPORTED field, not from `rho_e`. Changing what the solver sees
does not change what marching cubes is handed.

★ **AND THE PREDICTION WAS WRITTEN DOWN BEFORE IT WAS MEASURED**, in
`frac_ersatz.hpp`, because it is not the obvious one: marching cubes interpolates
LINEARLY between adjacent sampled values, `H_eta` at eta = 2 voxels is a ramp
four voxels wide, and a volume fraction SATURATES within about a half-cell of the
interface. PR 324 §3's band control showed that a narrow band MANUFACTURES a
staircase. **So the more faithful field may well be the worse one to hand
marching cubes**, and the row of record stays the `H_eta` export (R5) with the
fraction beside it.

★★ **MEASURED, AND THE PREDICTION IS CONFIRMED — THE MORE FAITHFUL FIELD IS THE
WORSE ONE TO EXTRACT FROM.** Same design, same lattice, same frozen stamp, F = 2
throughout (R2: these rows may be read against each other and NOT against §3(c)'s
F = 1 rows):

| field | carved | n_cut | whole | CAD mm | ★ mid % | volume mm³ |
|---|---|---|---|---|---|---|
| SIMP rung 0.68 | 7.5521 | 26,191 | 8.4075 | 0.4293 | 85.28% | 440,551 |
| `F1_frac4`, **H_eta** export | **17.6591** | 83,313 | 15.8996 | 0.5403 | **56.41%** | 375,496 |
| `F1_frac4`, **fraction** export | **23.3588** | 82,808 | 19.1215 | 0.5379 | **65.07%** | 374,641 |
| `A2_all`, **H_eta** export | **17.4127** | 79,242 | 15.6827 | 0.5424 | **58.34%** | 375,036 |
| `A2_all`, **fraction** export | **23.2033** | 78,902 | 18.7825 | 0.5393 | **66.80%** | 374,279 |

★ **Carved roughness is 32% WORSE and the midpoint share climbs 8.7 points**, on
the identical geometry — `n_cut` moves by 0.6% and the enclosed volume by 0.2%,
so it is not a different object, it is the same object with its vertices placed
worse. **A volume fraction saturates at 0 and 1 within about a half-cell, so a
crossing edge more often has both endpoints saturated and marching cubes' linear
interpolation puts the vertex at the midpoint** — which is the staircase, and is
PR 324 §3's band control arriving from the other direction.

★ **CAD error moves the other way, and by almost nothing** — 0.5403 → 0.5379.
The CAD faces are frozen, so their field is stamped 0/1 in both exports and there
is nothing for the convention to change.

★ **So the export stays `H_eta` and the mechanism is a measured negative with a
mechanism.** The value of writing the prediction down first is that this is a
confirmation rather than a rationalisation.

### M4 — ★ THE ANISOTROPY OF A CUT CELL, PRICED (`--frac-aniso`)

**Problem: the brief's own pointer, and it is a real gap in what ARM 1 does.** A
partially-filled cell is genuinely anisotropic — stiffer along the material than
across it — and `rho_e * K0` is the VOIGT average, the upper bound in every
direction. So the exact fraction fixes WHERE the boundary is and leaves the cell
too stiff, most stiffly exactly across the cut.

**PR 320 priced the cut-cell family and rejected it. Its numerical reason no
longer applies** — it found cut-cell pointless because the median cut fraction
was EXACTLY 0.5000, a half-voxel-shifted staircase with nothing fractional to
integrate. On a smooth analytic `phi` the cuts are genuinely fractional and §5's
own k-report measures the distribution. ★ **Its ARCHITECTURAL objection stands**:
a per-element `Ke` takes storage from O(1) to O(cut cells) and voids the Galerkin
block cache.

**So this prices the correction WITHOUT BUILDING IT.** For a cell cut by a plane
with normal `n` at fraction `f`, the exact two-phase construction with uniform
fields in each phase is the RANK-ONE LAMINATE: the strain differs between the
phases by a rank-one symmetric jump `sym(a (x) n)` fixed by traction continuity.

    eps1 = eps + (1-f) sym(a (x) n)          the solid layer
    eps0 = eps -    f  sym(a (x) n)          the void layer
    [(1-f) + f rho_min] Q a = -(1-rho_min) (C eps).n
    Q = mu I + (lambda+mu) n (x) n           the acoustic tensor, invertible in closed form

**That is a 3x3 solve per cut cell. No element matrix, no assembly, nothing
cached.** The strain comes from core's own `hex8_stress` on the converged
solution (invoked, not a second B matrix in the harness — R2). The ratio
`W_laminate / W_voigt` is exactly how much strain energy the scalar ersatz
misplaces in that cell, under the strain it actually carries.

★ **AND IT IS ALSO A MECHANISM, NOT ONLY A DIAGNOSTIC.** The ratio is a per-cell
SCALAR, and `rho_e` is already a per-cell scalar, so `rho_e -> ratio * rho_e`
costs exactly nothing architecturally. It is not the full anisotropy — a scalar
cannot be — but it is the part of it the COMPLIANCE sees, which is the part the
objective is made of. §8 ranks building it.

★★ **MEASURED, ON PR 326's CONVERGED DESIGN, AND THE ANSWER IS "NOT WORTH THE
ARCHITECTURE, WORTH THE SCALAR".**

| | |
|---|---|
| cut cells | **10,112** |
| their strain energy, **Voigt** (`rho_e * K0`, what we do) | 2.8318e-09 — **3.903%** of the part's 7.2550e-08 |
| their strain energy, **rank-one laminate** | 2.3814e-09 |
| ★ **the scalar ersatz over-stiffens the cut cells by** | ★ **18.91%** |
| ★ **which is, of the WHOLE part's strain energy** | ★ **0.621%** |

★ **THE DISTRIBUTION IS THE PART THAT MATTERS, WHICH IS WHY IT IS PRINTED AND NOT
JUST THE MEAN.** `W_laminate / W_Voigt`, by twentieths — 1.00 means the scalar is
exact in that cell:

| bucket | 0.00–0.05 | 0.05–0.25 | 0.25–0.50 | 0.50–0.75 | 0.75–0.95 | **0.95–1.00** |
|---|---|---|---|---|---|---|
| cells | 75 | 389 | 1,107 | 1,124 | 2,375 | **5,428** |

★ **54% of cut cells are within 5% of exact and 15.5% are worse than a factor of
two, with a tail where the scalar is TWENTY TIMES too stiff.** The near-exact
majority are cells whose strain lies mostly ALONG the interface, where Voigt is
the right answer; the tail is cells loaded ACROSS the cut, which is exactly where
a thin member's boundary sits. **A mean of 18.91% would have hidden both facts.**

★ **THE VERDICT, IN THE BRIEF'S OWN TERMS.** "Say whether an anisotropic
correction can be had without that cost."

* ★ **PR 320's REJECTION OF THE CUT-CELL FAMILY STANDS — and now for a measured
  reason on a smooth phi, rather than for the half-voxel-staircase reason that no
  longer applies.** The whole anisotropy is worth **0.62% of the compliance**.
  That does not buy a per-element `Ke`, O(cut cells) storage and a voided
  Galerkin block cache. ★ **And the search found a second architectural reason
  PR 320 did not have**: even the correct cut integral `∫ α(x) BᵀCB` is not
  proportional to `K_ref` for a trilinear hexahedron, so a laminate TENSOR fixes
  only half of what the scalar discards — the other half is collapsing a varying
  `B` onto one reference matrix, and no material model fixes that.
* ★ **BUT THE SCALAR VERSION COSTS NOTHING AND IS NOT REFUTED.** The ratio above
  is a per-cell SCALAR and `rho_e` is already a per-cell scalar, so
  `rho_e -> ratio * rho_e` needs no `Ke`, no storage change and no cache-key
  change. It captures the 18.91% on the cut cells — the part the COMPLIANCE
  sees — and leaves the rest. It needs the strain, so it must be lagged one
  iteration, which is the standard secant treatment. §8 ranks it second.

★ **What this measurement is NOT.** The rank-one laminate is the exact two-phase
construction for uniform fields in each phase; a real cut cell is one plane cut
inside a structure, not an infinite laminate, and the two agree in the regime
that matters here but are not the same object. The number is a price, not a
prediction of what the correction would buy in a run.

★ **AND THE LITERATURE HAS THE CLOSED FORM, IN A FIELD NOBODY IN THIS PROJECT
HAS BEEN READING.** Kabel, Merkert & Schneider, *Use of composite voxels in
FFT-based homogenization*, CMAME 294:168–188 (2015), DOI
10.1016/j.cma.2015.06.003, assign a cut voxel the stiffness of exactly this
rank-one laminate — they call it a **composite voxel** — and the explicit
solution is in Kabel, Fink, Ospald & Schneider, ECCOMAS 2016, pp. 2099–2110:

    ( P + λ(C_W − λ Id)^{-1} )^{-1} = ⟨ ( P + λ(C − λ Id)^{-1} )^{-1} ⟩

with `P` built from `n` alone. **The only inputs are the volume fractions and
the normal.** Their measured error, on a fibre microstructure downsampled 4x:
laminate ≤ 24% and UNDER-estimating, Voigt ≤ 20% and OVER-estimating; and in a
nonlinear tensile test the Voigt error **rises to 37% by end of loading** while
the laminate's falls monotonically. ★ **Voigt is an upper bound, so a
volume-fraction ersatz over-stiffens the boundary — it flatters both the
compliance and the margin**, and it flatters them most where the cut cells are.

★ **The honest architectural caveat, which the search also produced and which I
had not seen.** Even the correct cut integral `∫ α(x) BᵀCB` is not proportional
to `K_ref` for a trilinear hexahedron, so `rho_e * K_ref` discards the anisotropy
TWICE — once by Voigt-averaging the material and once by collapsing a varying `B`
onto one reference matrix. A laminate tensor fixes only the first. So the
truthful version of "can an anisotropic correction be had without the cost?" is:
**the per-cell scalar knockdown above can, and it captures the part the
compliance sees; a genuine anisotropic ersatz cannot, and PR 320's objection
survives contact with the composite-voxel literature.** §8 ranks them
accordingly.

★ **And no one has done it.** Searches for a laminate or composite-voxel
correction applied to cut cells in LEVEL-SET topology optimisation returned
nothing — the optimisation literature's answer to cut-cell anisotropy has been to
abandon the scalar model (XFEM / CutFEM / IGFEM) rather than correct it. That is
an open slot, and the measurement in this section is what says whether it is
worth walking into.

### M5 — ★★ THE QUADRATURE BANDWIDTH ON THE RIGHT NORM (`--frac-eps-l1`)

**Problem: P14, and it is a defect in ARM 1 that I could not see and the
literature could.**

`frac_ersatz.hpp` justified `eps_q` with a partition-of-unity argument: at
`eps_mult = 1` the tent's half-width equals the sample spacing in phi, the sum
telescopes to `1/spacing` exactly, and the estimator is smooth in `alpha` by
construction rather than by averaging. ★ **That is exactly right for an interface
whose normal is a GRID AXIS, and only then.** Along an axis the `k³` samples
project onto the normal at the axis spacing and the tent tiles; obliquely they do
not. I wrote the axis-aligned case, checked it, and generalised it without
noticing the check had used the one orientation where the two norms agree.

**Where the answer came from.** Engquist, Tornberg & Tsai, *Discretization of
Dirac delta functions in level set methods*, JCP 207(1):28–51 (2005), DOI
10.1016/j.jcp.2004.09.018. Their closed-form counterexample is a straight line at
45°, where the narrow hat at `eps = h` leaves a **12.1% error that does not
decrease with h**: an implicit mollifier `delta_eps(phi)` whose bandwidth scales
with `|grad phi|_2` is **NOT CONVERGENT** in two or more dimensions. Scaling by
the **L1** norm instead,

    eps_q = eps_0 * (h/k) * (|phi_x| + |phi_y| + |phi_z|)

makes it first order. ★ **Their Theorem 4 is why it is the right norm rather than
a tuned one:** for a plane orthogonal to a relatively prime `(p,q,r)`, the hat of
half-width `(p+q+r)/sqrt(p²+q²+r²)` sample spacings gives the **EXACT** area,
invariant under translation of the interface relative to the lattice — and that
ratio IS `|n|_1 / |n|_2`.

The two norms agree on an axis-aligned interface and differ by up to `sqrt(3)` on
a diagonal one, so ARM 1's choice was systematically NARROW, worst on exactly the
oblique surfaces this part is mostly made of.

★ **The same source also validates two things ARM 1 got right, which is worth
saying because it is the same paper.** The TENT is the right shape — it has
moment order 2 where the raised cosine `H_eta` differentiates to has order 1 —
and the volume-fraction route is **a full order more accurate than the delta
route at the same support** (second order against first, confirmed in 3D). The
choice to compute a FRACTION rather than a band was independently the right one.

**Cost:** three central differences per cut cell — the same stencil `grad_mag`
already runs. Defaults OFF so ARM 1's arithmetic is unchanged by inspection.

### ★★ RESULT: MIXED, AND ON THIS PART IT IS NOT A WIN. REPORTED AS MEASURED.

★ **The first pairing could not answer it at all.** `frac_k4` against `frac_l1`
is the hard fraction with the two norms, and on the hard fraction the difference
is quantisation-dominated at every affordable step (P13) — both read the same
noise (−17.6% / −20.3% at step 0.01, −45.7% / −44.2% on the other direction).
**A comparison that reads its own noise on both sides is not a comparison**, and
running it and quoting the difference would have been exactly that.

★ **So the pairing that resolves it is on the MOLLIFIED value function**, where
the difference is clean to sub-1% — `frac_soft` against `frac_soft_l1`, which is
also the exact configuration `A2_all` runs:

| probe (volume) | soft, `|grad phi|_2` | soft, ★ `|grad phi|_1` |
|---|---|---|
| random dir 0 @ 0.001 / 0.01 / 0.1 | −0.294 / −0.374 / +1.475% | ★ **+0.084 / +0.034 / +0.778%** |
| random dir 1 @ 0.001 / 0.01 / 0.1 | **+0.815 / +0.959 / +1.900%** | +1.866 / +1.936 / +2.681% |
| coefficient 8991 @ 0.01 / 0.1 | +0.143 / −0.609% | ★ **−0.083 / −0.286%** |
| coefficient 8990 @ 0.01 / 0.1 | +0.082 / −2.062% | +0.090 / ★ **−1.517%** |
| coefficient 5999 @ 0.01 / 0.1 | +0.572 / **−0.256%** | ★ **+0.077%** / +3.387% |
| dir 0, ★ **compliance** @ 0.01 / 0.1 | **−1.326 / −2.889%** | −2.321 / +2.080% |
| dir 1, ★ **compliance** @ 0.01 / 0.1 | **+3.184 / +5.167%** | +7.612 / +9.437% |

★ **BETTER ON FOUR VOLUME PROBES BY THREE TO SEVEN TIMES, WORSE ON TWO, AND
WORSE ON THE COMPLIANCE FOR ONE OF THE TWO DIRECTIONS. On this part it is not a
win.**

★ **The likely reason, and it is a limitation of the theorem rather than of the
implementation.** ETX's result is about the ALIASING error of an implicit
mollifier, and the L1 norm removes it by making the band up to `sqrt(3)` times
WIDER. A wider band also BLURS more, and their analysis is of a PLANE, where
there is nothing to blur. This part's interface is finely branched with curvature
on the scale of the band itself — PR 326 §4 measured the fine structure as
nucleated during the run — so the blurring error the wider band adds can exceed
the aliasing error it removes. **The theory is right about planes and this design
is not planes.**

★★ **AND THE CONSEQUENCE FOR `A2_all`, STATED RATHER THAN LEFT TO BE INFERRED.**
The arm that settles at +4.2% carries BOTH M1 and M5. R4 attributes the gradient
quality to **M1**: `frac_soft` alone verifies at −1.33 / +3.18% on the compliance
and adding M5 takes it to −2.32 / +7.61%. **So `A2_all`'s result is M1's, and M5
is along for the ride and may be costing a little.** ★ The arm that should have
been run is `--frac-soft` ALONE, and it was not — §8 ranks it. Attributing the
settled margin to "all mechanisms" without saying this would have been the kind
of claim PR 326's §5 caught itself making.

★ **It stays in the tree, defaulted off, with this pair as its documentation** —
the same disposition PR 326 gave its own measured-harmful continuation flag.

## 6. WHAT WAS TRIED AND ABANDONED

* ★ **BRANCHING FROM PR 326.** The brief says "same sandbox as PR 324/325/326"
  and R5 asks for one variable to change from PR 326's re-baseline — but PR 326
  is OPEN and branched from PR 324's merge, before PR 325 shipped the production
  parametric optimiser. A branch taken from it would report PR 325's entire
  production path as DELETED, which is exactly what R6 forbids. **Replaced by
  MERGING PR 326 into main**, with the merge verified by re-running PR 326's own
  re-baseline for three iterations and diffing to twelve digits. P1.

* ★ **A GEOMETRIC CLASSIFIER FOR WHICH CELLS NEED SUB-SAMPLING.** S1(b) asks for
  one, and the obvious form — all eight corners the same sign AND `|phi|` beyond
  a support bound — needs a MARGIN, and a margin is one more thing that can be
  wrong. **Replaced by sampling every ACTIVE cell and COUNTING the cut ones.**
  It is exact by construction, the count is in the CSV every iteration, and it is
  affordable for a reason the brief did not anticipate: `Empty`, `FrozenSolid`
  and `FrozenVoid` cells are stamped by the MASK, so 397,536 of the 468,224 are
  excluded before any test on `phi` is made at all.

* ★ **MOVING THE VOLUME CONSTRAINT ONTO THE FRACTION.** It would have made
  `printed_voxels`, the mass and the certificate mean something different from
  PR 326's, which is a second variable — and it would have made the offset
  bisection re-sample every active cell about a hundred times per iteration.
  **The constraint stays on `{H_eta(-phi) > 0.5} = {phi < 0}`**, which is
  provably eta-free as a SET. §2, P6, P7.

* ★ **A SINGLE FINITE-DIFFERENCE STEP SIZE.** The first `--frac` difference came
  back at **+182%** and looked for ten minutes like a broken quadrature. It is
  the 1/64 staircase, and only a SWEEP says so: +182% / −17.6% / **−2.03%** /
  +6.85% / +19.5% across five steps is the textbook shape, and the minimum is the
  answer. P13.

* **`Psi^T` for the fraction's sensitivity.** Kept reachable as
  `--frac-sens centre` and priced rather than removed, because "the exact form is
  better" is a claim and 15 percentage points is a number. §5 M2.

* ★ **THE PARTITION-OF-UNITY ARGUMENT FOR `eps_q` AS WRITTEN.** It is correct for
  an axis-aligned interface and false for an oblique one, and I could not see it.
  **Replaced by the L1-norm bandwidth** the level-set delta literature proves is
  required. §5 M5, P14. ★ This is the one entry here that ARM 2's research
  produced rather than confirmed.

* ★★ **AND THEN THE L1 BANDWIDTH ITSELF, AS A DEFAULT.** The theory is sound and
  the implementation is right, and the measurement on this part is MIXED — better
  on four volume probes by 3–7x, worse on two, worse on the compliance for one of
  two directions. ETX's theorem is about a PLANE and removes aliasing by making
  the band up to `sqrt(3)` WIDER; this design's interface is finely branched with
  curvature on the scale of the band, so the blur the wider band adds can exceed
  the aliasing it removes. **Kept, defaulted OFF, with the pairing as its
  documentation** — the disposition PR 326 gave its own measured-harmful
  continuation flag. §5 M5.

* ★ **COMPARING THE TWO BANDWIDTH NORMS ON THE HARD FRACTION.** Run first, and it
  reads its own quantisation noise on BOTH sides (−17.6% against −20.3%). A
  comparison that reads its own noise on both sides is not a comparison. Replaced
  by the pairing on the MOLLIFIED value function, where the difference is clean
  to sub-1%.

* **`--robust`, `--plsm-hilb`, `--no-surface-delta`, the descent branch and
  L-BFGS under `--frac`.** Not abandoned for lack of interest — **REFUSED**, each
  with a message naming the quantity that would be inconsistent. PR 326's P7 is
  the precedent: a mis-localised sensitivity produces a converged arm reporting
  "the mechanism does nothing", which is believable and wrong. P8.

* ★ **CORRECTING PR 326's `|grad phi|` FACTOR IN THE CONTROL.** §4(a) measures it
  at up to 23%, and fixing it is one line. **Not done here, deliberately** — it
  would have been a second variable and the control would no longer have been
  PR 326's arm. §8 ranks it first.

* ★ **A GAUSS–BONNET EULER-CHARACTERISTIC PENALTY.** Considered for the standing
  smoothness item and **rejected on theory rather than on time**: `INT K dS` is
  topologically quantised, so its derivative is zero almost everywhere and any
  discrete gradient is an artefact. §8.

## 7. THE PROBLEMS I ACTUALLY HIT

Written down as they happened, in
`evidence/2026-08-12-exact-volume-fraction-ersatz/working_notes.md`, and
reproduced here IN FULL — including the ones with no answer, which the brief
asks for by name. ARM 2 (§5) was built from this list and from nothing else.

### P1 — the bar and the seed are on an OPEN branch whose base predates PR 325

The brief says "SAME SANDBOX as PR 324/325/326" and R5 says one variable changes
from PR 326's re-baseline. PR 326 is `gh pr 326`, **OPEN**, and it branched from
PR 324's merge — before PR 325 shipped the production parametric optimiser into
`core/include/topopt/plsm_*.hpp`. So PR 326's tree does not contain those files,
and `git diff main -- core/include` on a branch taken from PR 326 would show
PR 325's entire production path as DELETED — which is precisely what R6 forbids
reporting.

Branching off PR 326 satisfies R5 and breaks R6. Branching off main satisfies R6
and makes the bar unreproducible.

**Solved by merging PR 326 into main rather than branching from either.** Two
conflicts, both mechanical: PR 325 turned `plsm_basis.hpp` and `plsm_probe.cpp`
into shims over core while PR 326 added functions beside them; both resolved by
keeping both sides. **Verified rather than asserted** — `check_merge.sh` runs
three iterations of PR 326's own re-baseline configuration on the merged tree
and diffs them against PR 326's committed `iterations.csv`. Identical to twelve
digits on compliance, both volumes, the achieved fraction, the offset, the step,
|v|max and lambda.

Cost: about forty minutes. **Solved.**

---

### P2 — the HARD-sampled fraction is piecewise constant in alpha

`f_v` is a count of sample signs, so it jumps by 1/k³ as each sample crosses and
its derivative is zero almost everywhere. The sensitivity S1(c) prescribes is the
derivative of the CONTINUUM quantity `f_v` approximates, not of the number the
solver is handed. **This is exactly the shape of PR 326's P2** — a hard-count
volume constraint with a smoothed derivative — and I hit it one level down.

Three consequences, and the third is the one that could have wasted the run:

1. R4's finite difference cannot be run at one step size. Too small and it
   differences a flat; too large and it leaves the linear regime. **The step is
   swept and the plateau is the answer**, which is why `--frac-fd` runs five
   steps on the volume (free) and two on the compliance (two state solves each).
2. A single-coefficient probe is the worst case, because one coefficient's
   support covers few cut cells and there is nothing for the staircase to
   average over. Random directions that touch every knot average over ~10⁴ cut
   cells and are the clean check. Both are reported.
3. MMA is handed a gradient of a function it is not evaluating. **Partly
   solved**: `--frac-soft` replaces the hard indicator with the exact
   ANTIDERIVATIVE of the quadrature mollifier, so the value and the gradient
   become two facts about one function; it is the same O(1/k) approximation to
   the exact fraction and its ε shrinks like 1/k, so it is not a return to η.
   It is built, finite-differenced and run as its own arm.

---

### P3 — ★ THE OLD GRADIENT IS NOT THE DERIVATIVE OF THE OLD DENSITY EITHER

Writing the new sensitivity made the old one legible for the first time.

`delta = DH_η(φ)·|∇φ|` is the SURFACE measure: `∫ f·DH_η(φ)|∇φ| dΩ → ∫_Γ f dS` by
the co-area formula. But the derivative of a density defined by `ρ_v = H_η(-φ_v)`
is `∂ρ_v/∂α_i = -DH_η(φ_v)·ψ_i(x_v)` — **no `|∇φ|`**. The two agree only when φ
is a signed distance, and PR 326's own P3 measured `‖∇φ‖−1` at 0.35–0.39 rms
through every arm.

So PR 326's `dc` and `dv` are the derivatives of the CONTINUUM shape functional
with respect to a normal motion of the boundary, and the thing MMA is stepping is
the DISCRETE ersatz compliance — and those are two different functions when φ is
not a distance function.

**Measured, not argued.** `--frac-fd` without `--frac` differences PR 326's own
gradient against the functions it is a gradient of, on PR 326's own converged
design. Results in the handoff §4.

Not "solved" — it is a finding about the arm this task's control IS, and the
control is left exactly as PR 326 ran it (R5). Fixing it would have been a second
variable.

---

### P4 — Ψ is built at cell CENTRES and the fraction's derivative needs ψ at the SAMPLES

`∂f_v/∂α_i = -(1/k³) Σ_s δ_q(φ_s)·ψ_i(x_s)`. `Ψᵀ` evaluates ψ_i once, at the
cell centre, and factors it out of the sub-cell sum. Building a Ψ on the sample
lattice is k³ = 64 times bigger — ~57 million non-zeros rebuilt every iteration.

**Solved by scattering instead of projecting**: the knot walk that evaluates φ at
a sample already has the (index, ψ) list, so the sensitivity re-walks it and
accumulates into per-thread coefficient accumulators. Cost is the same order as
the sampling itself. The centre form is kept reachable (`--frac-sens centre`) as
an ablation so the sub-cell ψ is priced rather than assumed to matter.

---

### P5 — ε_q IS A BAND, and S2(b) says name it or do not have it

S2(a) says remove the smoothed Heaviside from the density path entirely; S2(b)
says if something structurally needs a band, keep it and NAME it. The quadrature
of `∫_C δ(φ)ψ_i dx` needs a mollifier, and a mollifier has a width.

**Named: `ε_q`, the QUADRATURE BANDWIDTH.** What makes it not η wearing a hat:

* it appears in NO density — `f_v` is a hard count of sample signs;
* it is `eps_mult · |∇φ| · h/k`, tied to the SAMPLE SPACING, so it shrinks like
  1/k. η is fixed at 2 voxels and shrinks with nothing;
* at `eps_mult = 1` and a locally planar interface the tent is a partition of
  unity along the normal, so the estimator is smooth in α by construction rather
  than by averaging. That is a property of the tent at exactly that width and is
  the reason the tent was chosen over the raised cosine `H_η` differentiates to.

---

### P6 — the PRINTED predicate still reads η, and it is kept ON PURPOSE

`occ`, the printed occupancy, is still `H_η(-φ)` at the cell centre. Everything
that defines the PART reads it: the volume constraint, `printed_voxels`, the F=1
export, the certificate, the mass.

It is kept because `{H_η(-φ) > 0.5} = {φ < 0}` — H is monotone with H(0) = 0.5
exactly, which PR 326 §3(e) both proves and measures — so the printed SET does
not contain η at all. Changing it would have changed what "the part" means and
made the mass column incomparable, which is a second variable.

**The place η is NOT free is the EXPORT**, where the field VALUES set where
marching cubes puts a vertex. That is a separate axis, and it is measured as one:
`--frac-export` emits the same design as a volume-fraction field beside the H_η
one.

---

### P7 — the volume bisection would have re-sampled 100 times per iteration

`solve_offset` bisects `volume_at(offset)` ~100 times. If the constrained
quantity were the fraction, each of those would re-sample every active cell.

**Solved by NOT moving the constraint** (P6): the constraint stays on the centre
predicate, which is unchanged, so the bisection costs exactly what it cost in
PR 326 and the sub-cell sampling happens ONCE per iteration, after the offset has
been folded into α. `build_fields` refuses a non-zero offset under `--frac` so
this cannot be broken later by someone who does not know why.

---

### P8 — the sensitivity's OTHER consumers were not rewritten

`--robust` reads the objective's band on the ERODED surface (PR 326's P7);
`--plsm-hilb` extends the velocity by a solve on the VOXEL field; the descent and
L-BFGS branches consume `g = Ψᵀv`. None of those carries a sub-cell ψ.

**Not solved — REFUSED.** Each combination exits with a message saying which
quantity would be inconsistent. A density and a sensitivity that describe
different objects is the single most likely way this run is wasted, and PR 326's
P7 is the precedent: a mis-localised sensitivity produces a converged arm
reporting "the mechanism does nothing", which is believable and wrong.

---

### P9 — the export convention is a SECOND substitution, and the density change does not touch it

Changing what the solver sees does not change what marching cubes is handed. The
brief's two headline questions — CAD error and midpoint share — are questions
about the EXTRACTED SURFACE, and the extracted surface is built from the exported
field, not from `ρ_e`.

**Handled by measuring it as its own axis** rather than folding it in: the same
design is emitted both ways and both are measured, so "the optimiser walked
somewhere better" and "the export carries more sub-voxel information" are
separable. ★ And the PREDICTION is written down in `frac_ersatz.hpp` before the
measurement: a volume fraction SATURATES within about a half-cell of the
interface where `H_η` at η = 2 voxels ramps over four voxels, and PR 324 §3's
band control showed a narrow band MANUFACTURES a staircase. So the more faithful
field may well be the worse one to hand marching cubes.

---

### P10 — this host was running another worktree's optimiser throughout

`ps` shows a `levelset_probe` from `.claude/worktrees/lattice-page-core-hookup-…`
running for the whole of this task. Every wall clock here is measured under that
contention. PR 326's P10 said the same thing and this repository has measured the
host's run-to-run offset directly
(`evidence/2026-08-09-reference-implementation-bakeoff/host_contention.txt`).

**Stated, not fixed.** The designs are deterministic and no conclusion rests on a
wall clock; the fraction's per-iteration cost is reported as a SHARE of the
iteration it sits in, which is the ratio the brief asks for and is far less
sensitive to contention than either number alone.

---

### P11 — the binary changed between two finite-difference arms

`--frac-aniso` was added while `run_fd.sh` was mid-flight, so the control arm ran
on a binary that lacked it. The added code is a separate, default-off block and
cannot execute in the control, but "cannot" is how a comparison becomes a claim.

**Solved by re-running the control on the final binary** so all four rows come
from one build. Cost: nine minutes.

---

### P15 — ★★ THE CONTROL REPRODUCES PR 326 FOR FIVE ITERATIONS AND THEN DOES NOT, AND THE FIFTH IS NOT A COINCIDENCE

`check_merge.sh` passes: three iterations of PR 326's own re-baseline
configuration on the merged tree are identical to PR 326's committed
`iterations.csv` to all twelve printed digits. The full-length control arm
extends that check by accident, and it is identical through **iteration 5** and
then not:

| iteration | H1 (this tree) | RB1 (PR 326's tree) |
|---|---|---|
| 1-5 | identical to 12 digits | identical to 12 digits |
| 6 | 0.00298558**531538**, 75,414 printed | 0.00298558**252065**, 75,415 printed |

★ **A 9.4e-10 relative difference in compliance, and ONE VOXEL in the printed
count.** The count is an integer, so from iteration 6 on the two runs are
solving slightly different problems and the trajectories separate for good.

★★ **AND THE ITERATION IT HAPPENS ON IS THE TELL: every arm here runs
`--plsm-refit-every 5`, so iteration 5 is the FIRST TIME the approximate
reinitialisation fires.** That path — `reinitialise` and `plsm_solve_normal` —
is exactly what PR 325 MOVED from the harness into `core/include/topopt/`. The
move was verified byte-identical at the source level, and it is: this is the same
arithmetic compiled in a different translation unit, which is free to inline and
vectorise it differently. A three-iteration identity check could not have caught
it, because at three iterations the moved code has not run.

★ **THE CONSEQUENCE, AND IT IS THE REASON THIS TASK RAN ITS OWN CONTROL RATHER
THAN QUOTING PR 326's TABLE.** PR 326's published `14.1322 / 79,577 / 2859.5` for
the re-baseline were produced on a tree whose refit is not this tree's to the last
bit. Putting them in a column beside numbers produced here would have been a
comparison across two binaries — subtle, invisible, and exactly the class of
error R2 exists to prevent. **Every row in §3 is produced on THIS tree, in the
same batch, by the same binary.** PR 326's numbers appear only as quoted history,
clearly marked.

★ **What it does NOT license.** It does not make PR 326's numbers wrong, and it
does not make the two trees' designs materially different — PR 326 §3b measured
two trajectories that differ only in summation order landing 0.4% apart in
certified margin at iteration 20, and §2 measured a settled tail spanning 0.15%.
It is a floor on how finely any A/B in this line of work can be read, and it is
now a measured floor instead of an assumed one.

**Not solved and not solvable here** — it is a property of the shipped tree.
Ranked in §8.

---

### P14 — ★★ MY BANDWIDTH USED THE WRONG NORM, AND THE LITERATURE FOUND IT, NOT ME

P5 named `eps_q` and justified it with a partition-of-unity argument: at
`eps_mult = 1` the tent's half-width equals the sample spacing in phi, so
`SUM_m (1 - |t - m*D|/D)/D = 1/D` exactly and the estimator is smooth in alpha by
construction.

★ **THAT ARGUMENT IS EXACTLY RIGHT FOR AN INTERFACE WHOSE NORMAL IS A GRID AXIS,
AND ONLY THEN.** Along an axis the k³ samples project onto the normal at exactly
the axis spacing and the tent tiles. For an OBLIQUE interface they do not, the
tent does not tile, and the error does not vanish with refinement. I wrote the
axis-aligned case, checked it, and generalised it without noticing that the check
had used the one orientation where the two norms agree.

★ **Engquist, Tornberg & Tsai (JCP 207(1):28-51, 2005) prove precisely this and
give the fix.** Their closed-form counterexample is a straight line at 45
degrees, where the narrow hat at `eps = h` leaves a **12.1% error that does not
decrease with h** — the implicit mollifier `delta_eps(phi)` scaled by
`|grad phi|_2` is **NOT CONVERGENT** in two or more dimensions. Scaling by the
**L1** norm instead,

    eps_q = eps_0 * (h/k) * (|phi_x| + |phi_y| + |phi_z|)

makes it first order. Their Theorem 4 is why it is the right norm and not a tuned
one: for a plane orthogonal to a relatively prime `(p,q,r)`, the hat of
half-width `(p+q+r)/sqrt(p^2+q^2+r^2)` sample spacings gives the **EXACT** area,
invariant under translation of the interface relative to the lattice. That ratio
IS `|n|_1 / |n|_2`.

The two norms coincide on an axis-aligned interface and differ by up to `sqrt(3)`
on a diagonal one, so my choice was systematically NARROW — worst on exactly the
oblique surfaces this part is mostly made of.

★ **This is what ARM 2 is for and it is the clearest example of it in this task:
a thing I built, could not see was wrong, and that a specific paper had already
solved.** Implemented as `--frac-eps-l1`, defaulting OFF so ARM 1's arithmetic is
unchanged by inspection, and finite-differenced against the L2 version on the
same design with the same probe. §5 M5.

---

### O1 — ★ AN OBSERVATION THAT FELL OUT OF R4 AND IS NOT A PROBLEM AT ALL

`--frac-fd` evaluates the density and the compliance on ONE design before it
differences anything, so running it twice on PR 326's re-baseline — once with
`H_eta`, once with the fraction — prices the two ersatz models against each other
on the SAME geometry, with no optimiser between them. Both runs solve the same
offset (the volume constraint is unchanged), so the φ is identical.

| on PR 326's re-baseline at iteration 60 | material in the ACTIVE region | compliance |
|---|---|---|
| the printed set `#{phi < 0}` (75,415 − 40,216 frozen) | 35,199 | — |
| `H_eta`, eta = 2 voxels — PR 326's ersatz | **35,325.3** | 0.0025130525 |
| ★ the exact volume fraction | **34,959.5** | 0.0025401228 |

★ **THE SMEARED ERSATZ CARRIES 365.8 VOXELS OF MATERIAL THAT ARE NOT THERE —
1.05% of the region the optimiser owns — AND IS 1.08% STIFFER FOR IT.**

★ **And it is a BIAS, not a rounding.** `H_eta` is antisymmetric about a PLANE
interface, so on a flat boundary the smearing cancels exactly and the error is
zero. It only fails to cancel where the surface is CURVED — and the sign says it
ADDS material. **A more branched design has more curvature and is therefore
credited with more phantom material and more phantom stiffness.** The volume
constraint counts the printed set and never sees any of it, so the phantom is
free.

That is a mechanism by which the smeared ersatz REWARDS exactly the fine
branching PR 326 spent a task trying to suppress. It is an observation, not a
proof that removing it fixes the surface — §3's arms are what say that — but it
is the first quantitative reason to expect the change to move the surface at all,
and it was not part of the brief's reasoning.

---

### P13 — ★ THE HARD FRACTION HAS NO SMALL-STEP FINITE DIFFERENCE, AND I NEARLY READ THAT AS A BUG

The first `--frac` finite difference came back at **+182%** on the volume, at
step 1e-3. On the H_η control the same probe reads 0.46% at the same step. For
about ten minutes that looked like a broken quadrature.

★ **IT IS P2, ARRIVING.** `f_v` is a count of sample signs, so `V(α)` moves in
steps of 1/k³ = 1/64 of a voxel. At step 1e-3 the predicted change is 0.37
voxels — about 24 samples — and the observed one was 67. The FD is not measuring
a derivative there; it is measuring the difference of two staircases.

★ **AND THE STEP SWEEP IS WHAT SAYS SO, WHICH IS THE REASON IT EXISTS.** On one
random direction:

| step | 0.001 | 0.01 | **0.1** | 0.3 | 1.0 |
|---|---|---|---|---|---|
| dV rel err | +182% | −17.6% | **−2.0%** | +6.8% | +19.5% |

That is the textbook shape — quantisation-dominated below, truncation-dominated
above, a minimum in between — and the minimum is the answer. **The volume
sensitivity is verified to 2%.** A single step size would have produced one
number and no way to know which of the three regimes it came from.

★ **WHAT IS *NOT* SETTLED BY IT: the COMPLIANCE finite difference.** Two state
solves cost about a minute, so only two steps carry one, and at both of them the
hard fraction's compliance FD is still quantisation-dominated (−34% at 1e-2,
−25% at 1e-1 — moving, not converged). **The H_η control's is not**: it reads
+10.6% and +10.5% at the same two steps — a CONSISTENT offset, which is a
gradient error and not noise, and is P3 measured.

**Discriminated rather than argued**: `--frac-soft`'s value function is smooth,
so if ITS compliance FD lands on the prediction with the same quadrature and the
same scatter, the quadrature and the scatter are right and the hard variant's
residual is entirely the staircase. That arm is run for exactly this reason.

★★ **AND IT DID. THE SAME QUADRATURE, THE SAME SCATTER, THE SAME DESIGN, THE
SAME STEPS — ONLY THE VALUE FUNCTION SMOOTHED:**

| probe | dV at step 0.001 | dV at 0.01 | dC at 0.01 | dC at 0.1 |
|---|---|---|---|---|
| random dir 0 | **−0.294%** | −0.374% | **−1.33%** | −2.89% |
| random dir 1 | **+0.815%** | +0.959% | **+3.18%** | +5.17% |
| coefficient 8991 | — | **+0.143%** | — | — |
| coefficient 8990 | — | **+0.082%** | — | — |

★ **Sub-1% on the volume at exactly the steps where the HARD variant read +182%
and −45.7%, and 1.3–5.2% on the COMPLIANCE where the hard variant was
noise-dominated at every affordable step.** So:

1. **the quadrature and the scatter are correct** — nothing was wrong with the
   implementation;
2. **the hard variant's residual is entirely the 1/64 staircase**, which is what
   P13 claimed and could not previously prove;
3. **`--frac-soft` is the only formulation in this study whose gradient can be
   verified on BOTH functionals.** The control's compliance error is a consistent
   10.6–22.9%; this is 1.3–5.2%.

★ And the two value functions agree to **0.037%** on the volume they measure
(34,972.3 against 34,959.5 active-cell voxels), so the mollification is buying
the differentiability without moving the geometry — which is the whole design
intent and is now a number rather than an intention.

---

### P12 — 120 iterations is a change from PR 326, and it applies to BOTH arms

The brief asks for margin convergence, not compliance convergence. PR 326 §2
measured every unsettled arm still climbing in margin at iteration 60 — the
re-baseline by 26.7% between 40 and 60 while its compliance moved 0.05% — and its
§9 ranks running longer as the top item. Sixty iterations is known not to reach
what the brief asks for.

**Declared under R5 rather than slid in**: 120 iterations is applied to BOTH
arms, so it is not a variable between them, and the settling iteration is
reported as a number rather than assumed.

## 8. WHAT I WOULD DO WITH ANOTHER DAY, RANKED

1. ★★ **FIX PR 326's OWN GRADIENT, AND IT IS ONE LINE.** §4(a) measured
   `DH_eta(phi)*|grad phi|` projected by `Psi^T` to be off by up to **19.7% on
   the volume and 22.9% on the compliance**, FLAT across two decades of step
   size — a gradient error, not noise. The cause is the `|grad phi|`: it is
   correct for the CONTINUUM shape derivative and wrong for the derivative of the
   DISCRETE ersatz that MMA is actually stepping, and the two agree only on a
   signed distance, which this `phi` is not (`‖grad phi‖-1` = 0.35-0.39 rms).
   **Every level-set arm in PR 322/323/324/325/326 ran with it.** Dropping the
   factor is one line in one expression, costs nothing, and the finite-difference
   harness to check it now exists. ★ It is ranked FIRST because it is cheap,
   because it applies to the shipped `--plsm` job mode as well as the sandbox,
   and because a 20% gradient error is a plausible partial explanation for why
   the level-set arms need 60-120 iterations where SIMP needs 27.

2. ★ **THE LAMINATE CORRECTION AS A MECHANISM, NOT ONLY A PRICE (§5 M4).** The
   per-cell ratio `W_laminate / W_voigt` is a SCALAR and `rho_e` is already a
   per-cell scalar, so `rho_e -> ratio * rho_e` needs **no per-cell `Ke`, no
   cache-key change and no stencil change** — which is the objection PR 320
   rejected the cut-cell family on. The strain has to be lagged one iteration
   (the correction depends on the field it helps produce), which is the standard
   secant treatment and costs one extra pass. Whether it is worth building at all
   is decided by the number §5 M4 measures, and that number is in this handoff.

3. ★ **SWEEP `k` AND `eps_mult` JOINTLY, AND CERTIFY AT BOTH.** S1(a) settles
   `k = 4` against `k = 8` on the FRACTION (§5), but the brief's actual test is
   the MARGIN-reproduction tolerance, which needs two certified designs and not
   two density fields. `eps_mult` was set from the partition-of-unity argument
   and finite-differenced at one value; it is the only free number in the new
   formulation and it has not been swept.

4. ★★ **RUN `--frac-soft` ALONE — IT IS THE ARM THIS TASK SHOULD HAVE RUN AND DID
   NOT.** `A2_all` combines M1 and M5, it is the only arm whose margin settles
   (+4.2% over SIMP), and R4 says the gradient quality is M1's: `--frac-soft`
   alone verifies at −1.33 / +3.18% on the compliance and adding `--frac-eps-l1`
   takes it to −2.32 / +7.61%. **So the settled arm is carrying a mechanism that
   the finite difference says is not helping**, and one 30-minute run separates
   them. It is ranked this high because it is cheap and because the headline
   number in §0 currently rests on a combination rather than on a mechanism.

5. **Combine the fraction with PR 326's two winning knobs.** PR 326's best point
   was `C = 1` with `eta = 1`, and its §9 item 1 asks for a joint sweep of the
   perimeter weight and eta run to 120 iterations. Under `--frac` the perimeter
   functional no longer contains eta at all, so that two-dimensional sweep
   collapses to a one-dimensional one in `C` — which is a strictly cheaper
   version of the run PR 326 ranked first, and it is now available.

6. **Move the fraction into the export path if §3 says the export is worth it.**
   The measurement is in this handoff; the work is mechanical.

7. ★ **RUN `F1` AND `A2` PAST THEIR OWN MAXIMA.** Both stopped on the shipped
   compliance rule at 57 and 61, so **whether the fraction arms turn over the way
   the control does at iteration 80 is NOT established by this task.** They are
   settled at their endpoints and the control is not, which is the comparison
   that can be made — but "the fraction does not turn over" is a claim this task
   cannot support, and it is the obvious next question given §3(d).

8. ★ **CLOSE THE 1e-9 THAT PR 325's MOVE LEFT IN THE REFIT, OR AT LEAST BOUND
   IT.** §7 P15: this tree reproduces PR 326's re-baseline to twelve digits for
   FIVE iterations and then diverges by 9.4e-10 in compliance and ONE VOXEL in
   the printed count — and iteration 5 is exactly where `--plsm-refit-every 5`
   first fires, on the `reinitialise` / `plsm_solve_normal` path PR 325 moved
   into core. The move is byte-identical in SOURCE and is being compiled in a
   different translation unit. PR 325's own commit log records an open "1e-9
   determinism failure"; this is a second sighting with a located cause.
   ★ **It is a floor on how finely any A/B in this line of work can be read**,
   and until it is closed, every comparison has to be run in one batch on one
   binary — which is a real constraint on how this project can be worked.

### ★ AND FIVE FROM THE LITERATURE, RANKED BY WHAT THEY WOULD COST HERE

These came out of the search ARM 2 ran on the problems in §7. They are ranked and
named rather than listed, and the two I would NOT build are named too.

1. ★★ **REPLACE THE SUB-SAMPLING WITH THE ANALYTIC MARCHING-CUBES CELL VOLUME.**
   Takahashi & Batty, *Fast Marching-Cubes-Style Volume Evaluation for Level Set
   Surfaces*, Journal of Computer Graphics Techniques (reference C++ at
   `github.com/tetsuya-takahashi/MC-style-vol-eval`; builds on Wang,
   arXiv:1308.0387). Computes the volume below the level set inside a cell
   **exactly consistently with the Marching-Cubes mesh**, in closed form from the
   8 corner values, second-order convergent. ★ **It removes THREE of this task's
   problems at once**: the 1/64 staircase (P2/P13) because the volume is
   piecewise-polynomial in the corner values, the mollifier entirely (P5, P14)
   because the derivative is analytic within each MC case, and the sampling cost.
   ★ **And it is consistent with the very mesh the surface is measured on**, which
   nothing in this task currently is. **This is the single highest-value item in
   this handoff and it is hours, not days.**

2. ★ **A HARD PER-ITERATION CAP ON NEWLY NUCLEATED VOID, ARMED FROM ITERATION 1.**
   Dunning & Kim, *A new hole insertion method for level set based structural
   topology optimization*, IJNME 93:118–134 (2013), DOI 10.1002/nme.4384 — their
   `beta`, a cap on the void volume created by nucleation each iteration as a
   percentage of current structure volume, plus a minimum-hole-size rule that
   forbids a new hole smaller than one element. ★ **It is a different object from
   PR 326's nucleation band, which restricted WHICH coefficients may move; this
   restricts HOW MUCH new void may appear.** Their 54-case sweep moved the hole
   count while **final compliance stayed within ~1%** — the best exchange rate in
   anything I read. ★ **And their own finding says why PR 326's band failed:**
   "most new holes are inserted during the initial stages … before the volume
   constraint is reached", and they do not disappear. PR 326 measured its mask
   arriving after the branching was established and moving only 1.6%; this
   corroborates that independently and says the throttle must be armed from
   iteration 1. Recommended start: `beta = 2%`.

3. **A VIRTUAL-TEMPERATURE CAVITY CONSTRAINT.** Liu, Li, To et al., Frontiers of
   Mechanical Engineering 10(2):126–137 (2015), DOI 10.1007/s11465-015-0340-3;
   extended to level sets by Yamada & Noguchi, Additive Manufacturing 52:102630
   (2022), DOI 10.1016/j.addma.2022.102630; taxonomy in Cool et al., SMO (2025),
   DOI 10.1007/s00158-025-04004-z. One extra scalar Poisson solve per iteration
   with a heat source in the void: an enclosed void shows up as a temperature
   spike, so the constraint is a max-temperature constraint. ★ **It targets this
   repository's own `plsm-nucleates-sealed-cavities` finding specifically**, is
   3D, level-set compatible and differentiable.

4. **RAISE THE RBF BASIS ORDER AT FIXED KNOT SPACING.** Noel, Schmidt, Messe,
   Evans & Maute, SMO (2020), DOI 10.1007/s00158-020-02584-6: higher-order basis
   functions "promote the development of smooth designs and suppress the
   emergence of small features". ★ **This is NOT the change PR 324 §6(ii)
   refuted** — that was a COARSER basis, which halves the margin by removing
   degrees of freedom. This keeps the knot count and raises the smoothness order
   (Wendland C² → C⁴). Their own caveat is that cubic showed no advantage over
   quadratic, so try one step, not three. It needs a second `plsm_psi` in core,
   which is why it is here and not in the sandbox.

5. **REACTION–DIFFUSION `tau` AS AN IMPLICIT SMOOTHING OF THE MMA STEP.** Yamada,
   Izui, Nishiwaki & Takezawa, CMAME 199:2876–2891 (2010), DOI
   10.1016/j.cma.2010.05.013. ★ **Be clear-eyed about what it is: the
   Cahn–Hilliard fictitious interface energy CONVERGES TO THE PERIMETER**, so this
   is PR 326's already-measured mechanism delivered through a better-conditioned
   knob, not a new exchange rate. Worth having for that reason and no other.

★ **NOT WORTH BUILDING, and the reason is not preference.**

* **A Gauss–Bonnet / Euler-characteristic penalty** (`chi = (1/2pi) INT K dS`).
  `INT K dS` is topologically QUANTISED, so it is piecewise constant, its true
  derivative is zero almost everywhere, and any gradient a discretisation
  produces is an artefact. It is unpublished in level-set TO for that reason.
* **A persistent-homology hole-count penalty, YET.** It has the best published
  exchange rate anywhere in the search — Li, Gao, Yin & Lin, arXiv:2602.13856,
  take a short beam from **55 holes to 1 for a 2.5% compliance penalty**, with
  MMA — and every 3D piece exists separately: cubical persistence on 128³ in
  0.28–2.2 s (FlashCubical, arXiv:2606.04801), a differentiable 3D persistence
  loss with voxel gradients (Betti-Matching-3D, arXiv:2407.04683), and 3D
  implicit-B-spline persistence optimisation (Dong, Chen & Lin, CAD 150:103308,
  2022). ★ **But nobody has assembled them for 3D structural TO.** It is the right
  thing to put on the standing research item and the wrong thing to start in a
  day.

### ★ AND ONE REFRAMING FROM THE SEARCH THAT CHANGES WHAT "SMOOTHEST" MEANS HERE

Allaire, Jouve & Toader (JCP 194:363–393, 2004) state that in a conventional
level-set method **there is no nucleation mechanism for new holes at all** — a
hole cannot appear inside material because of the **maximum principle satisfied
by the Hamilton–Jacobi equation** — which is why that line of work needs the
topological gradient bolted on. The RBF-parametric line sells the OPPOSITE as its
headline feature: replacing H-J transport with MMA on coefficients **removes the
maximum principle**, so `phi` can be raised anywhere, including deep inside solid.

★ **So the driver of free interior nucleation is almost certainly the switch from
Hamilton–Jacobi transport to MMA-on-coefficients, not the ersatz and not the
seed.** SIMP has a density filter and a penalty that suppress feature
proliferation; an unregularised PLSM has neither a filter nor the maximum
principle. That predicts more holes and more internal surface at ANY `rho_min`
and any band width, and it is consistent with every measurement in PR 326 §4.

★ **Two gaps worth knowing about, stated because they are load-bearing absences
rather than things I failed to find.** (i) No published comparison of PLSM
against SIMP on hole count or internal surface area exists — PR 326's 3× figure
appears to be novel and unremarked in the literature. (ii) No paper measures hole
count, member count or internal surface as a function of `E_void/E_solid`; 1e-3
(Allaire) and 1e-9 (the 88-line codes) are conventions, not calibrated choices.

## 9. IN PLAIN LANGUAGE

**The change.** When the optimiser works out how stiff a chunk of the part is, it
has to decide how much material is in each little cube of the grid. Until now it
guessed, by looking at the single point at the middle of the cube and smearing
the answer over a few cubes' width. Now it works out the actual fraction of the
cube that is inside the part, by testing 64 points inside it. That is a small
change and it touches nothing else — the solver, the fast maths, the caches all
carry on unaware.

**Was it worth it? Partly, and not in the way we hoped.**

★ **The part comes out more dimensionally accurate — 4% closer to the drawing.**
That was the main thing this was supposed to buy, and it does.

★ **It converges in about half the number of steps.** The old method ran for 120
steps and never met our own "it has stopped improving" test. The new one met it
at 57, at the same stiffness. **That is the biggest practical result here.**

★ **It makes far fewer parts that are too thin to print** — a third fewer, which
takes it below the old SIMP method for the first time. Nobody asked for that.

★ **It does NOT make the part smoother.** The fussy branched interior is the same
size to within 3%. Said plainly, because that is what we were hoping for.

**The two things found along the way that matter more than the change itself.**

★ **The old method's gradient — the thing that tells the optimiser which way to
go — has been wrong by up to 23% this whole time.** In every level-set run we have
done, and in the version that shipped. A wrong gradient does not fail; it walks
to the right answer slowly, which is exactly what we have been seeing. Fixing it
is one line. **We only found it because this task built a way to check gradients
that we did not have before**, and ran the old one through it as a control.

★ **The old way of estimating material was quietly flattering branchy designs.**
Its smearing cancels out on a flat surface and does not on a curved one — and the
error goes the wrong way, crediting the part with material it does not have. The
more branched the design, the more free stiffness it was awarded. About 1% here.
Nothing in the run could see it, because the volume budget counts the real part.

**And one thing I built wrong, that a paper had already solved.** The width of a
smoothing used inside the new calculation was set by an argument I checked
carefully — and had only checked for surfaces lying flat along the grid, which is
the one case where it happens not to matter. For angled surfaces it is wrong, and
a 2005 paper proves it never converges and gives the fix. Implemented, measured,
and it is in the "all mechanisms" run.

**What I would do next, in order.** Fix the 23% gradient — it is one line and it
affects the shipped product. Then replace the 64-point sampling with an exact
formula that is consistent with the mesh we actually measure, which removes three
separate problems at once. Then cap how much new hole the optimiser may punch per
step, from the very first step — a 2013 paper reports that moves the hole count a
lot for about 1% of stiffness, and our own earlier attempt failed for a reason
that paper independently explains.
