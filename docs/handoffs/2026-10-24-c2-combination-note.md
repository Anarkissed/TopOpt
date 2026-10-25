# Design note: ONE lattice for every squeeze group (item 17, his ruling of 2026-10-24 15:33)

> "The goal is to try to make all squeezes applicable to the same lattice. … the job of the app is to create a lattice that allows
> for ALL of these squishes to happen. Not a compromise, but a combination."

No code is written until the reviewer rules on this note.

## 0. What I read his ruling to mean (Q-C1 confirms it)

- **Each squeeze group is its own LOAD CASE.** Its force alone (all its faces and presses together, one hand) must produce ITS
  drawn depths. The groups are squeezed one at a time: "separate squeezes" stays from D-R4-14, and only "the firmer wins" is
  retired.
- **One printed density field** must satisfy every case. For every group g and every column c of g, the column's depth under g's
  own pressure, through that one field, must equal g's target there to within a tolerance τ (Q-C2).
- **Inside one group**, crossing columns press at once, so today's nearest-face handover stays. A pinch (two faces of one group on
  one stack) is item 9(a)'s force balance. The combination is ACROSS groups.

## 1. The structure in core's model

In core's 1-D column model (02 §5), B1b's series formula is already the general case. A column's depth is the integral of the
strain along its run:

    d_{g,c}(ρ) = Σ_{v on c's run} L_{c,v} · ε(p_{g,c}; ρ_v)

Here L_{c,v} is the length of c's run inside voxel v. So **a column's depth depends only on the voxels along its run**. Build the
bipartite graph of columns and voxels and take its connected components:

- **A component with ONE group** is designed exactly as today, and stays **byte-identical**.
- **A component with two or more groups** is the joint problem: unknowns ρ_v on its voxels, in [ρ_min, ρ_max] of the tested rows;
  one equation per column per group. Typically voxels ≫ equations, so it is underdetermined. That is a family of solutions, and
  the method picks one.

## 2. (a) THE BASELINE

**Step 0, the start.** Today's independent designs give a voxel field ρ⁰: each column at its own single ρ, assembled as now. It
is the initializer, and the "minimal change" anchor.

**Step 1, exact feasibility where columns coincide (a same-axis shared run), BEFORE solving.** For a run traversed by columns of
k groups along one line, write γ(ρ) = (ε(p₁; ρ), …, ε(p_k; ρ)) for ρ ∈ [ρ_min, ρ_max].
- The normalized target vector (t₁/L, …, t_k/L) is reachable **if and only if** it lies in the **convex hull** of the curve γ.
- A point in the hull is reached with at most k + 1 constant-ρ segments (Carathéodory).
- So for two groups it is a 2-D convex hull of a curve: an exact yes/no, plus "by how much" (the distance to the hull, in mm).
- A necessary condition that often binds: if p_A < p_B on the same run, then t_A ≤ t_B, because every voxel squishes more under
  more pressure.

**Step 2, the joint solve (the general case: columns that cross or share only part of their run).** Projected Gauss–Newton
(Levenberg–Marquardt) on the RELATIVE residuals r_{g,c} = (d_{g,c}(ρ) − t_{g,c}) / t_{g,c}, so a 0.3 mm target counts as much as a
9 mm one. Two regularizers:
- (i) closeness to ρ⁰ (minimal change; mass as the tie-break);
- (ii) smoothness: R14's buildable smoothing as a density filter (Bourdin 2001), so the printed ladder follows the design.

The box is enforced by projection. The Jacobian J_{(g,c),v} = L_{c,v} · ∂ε/∂ρ (p_{g,c}; ρ_v) is sparse, and exact from the
piecewise-linear tables. The normal equations are solved matrix-free by CG. ε is monotone in ρ, so the problem is well behaved.
Iterate to a fixed point: max |r| < τ, or no progress.
- The reviewer's suggestion, "fix the shared segments, solve each group's own, iterate", is the FIRST sweep. It is exact whenever
  every column has an own segment. It stalls when a group's columns lie wholly inside another group's material, and the red case
  is likely that (Group 1's material is 86 % shared: 45,831 of 53,248 voxels). So Gauss–Newton is the baseline, with the sweep as
  its start.

**Step 3, before the run: verify and report, never pick silently.** After the solve and the smoothing, for each group:
- achieved vs target per column (17's receipt, built in B2);
- the worst miss;
- for every component that did not reach τ: the groups, the columns and voxels, and the miss in mm and %.

For a same-axis run, the hull certificate goes with it: "needs (a, b) mm; the nearest reachable is (a′, b′) mm". A combination
that cannot be met is a coded refusal **`combination_not_reachable`** carrying all of that.

**Tests, red first.**
1. **His pad (the red case).** The app's job for his 10-21 pad (pending from #362) has:
   - Group 1 = the pinch on faces 3 + 5 (stamp and curves, 2.27 kg);
   - Group 2 = the two edge presses (3.18 kg).
   
   Under today's assembly, each group's ACHIEVED depth under its own force through the assembled field is measured per column.
   Group 1 misses; the app saw 2.6 → about 0.3 mm. After the change, every column of both groups is within τ, or the refusal
   names the groups, the columns and the mm. It needs B2's 16 (groups) and 9(a) (the pinch), so it lands after them.
2. **Synthetic controls:**
   - (i) two groups on one same-axis column with a reachable pair: the hull says yes, and the solver meets both;
   - (ii) an unreachable pair (p_A < p_B but t_A > t_B): refused, with the hull distance;
   - (iii) a top press and a side press crossing at 90° on a cube, with targets the independent designs miss in the overlap: met;
   - (iv) a group sharing nothing: byte-identical to today.

**Size:** about 600–800 lines of core plus tests. It goes in a batch **B2b**, right after B2, because it needs B2's groups and pinch.

## 3. (b) THE BEST: the problems this raises, how others solved each, what I would add

| problem | prior work (by name) | what I would add |
|---|---|---|
| **Is it reachable at all?** | Bickel et al. 2010 describe the space of behaviours that combinations of measured base materials can reach, and fit one object to several target deformations. Schumacher et al. 2015 measure the coverage ("gamut") of elasticity tensors their microstructure families reach. | The exact 1-D gamut (§2 step 1) per shared run, in the receipt. Later, the 3-D gamut once core has its own 3-D squish (B9). |
| **What to optimise when it is near the edge** | Bendsøe & Sigmund 2003: multiple load cases as a weighted sum or a min–max. The min–max is solved through the bound formulation (Bendsøe, Olhoff & Taylor 1983) with MMA (Svanberg 1987). | His rule forbids silently choosing. So: refuse when it is unreachable. But where Gauss–Newton leaves a miss above τ, a second stage finds the min–max design (the worst group's miss smallest) and REPORTS it, as the "closest combination", with each group's miss. It is never applied without being said. |
| **1-D columns are not the 3-D part** (item 30: his Covered pad's 3-D sim is 3.6× stiffer) | Bickel 2010 and Schumacher 2015 both close the loop with FEM: the target deformation is evaluated by simulation, and the material per region or cell is optimised against it. | After B9: the combination's residual evaluated in core's 3-D squish, with one adjoint per load case (the standard multi-load-case sensitivity, Bendsøe & Sigmund ch. 1–2), per-voxel ρ as the variable, and the 1-D solution as the start. This is research scale, and it touches the solver files, so it waits for the solver cure. |
| **Neighbouring densities must print and join** | Schumacher 2015 keeps neighbouring cells compatible through interpolable families. Panetta et al. 2015 ("Elastic textures for additive fabrication", ACM TOG 34(4)) tile microstructures with compatible boundaries. Bourdin 2001 ("Filters in topology optimization", IJNME 50) adds the density filter. | The R14 smoothing as the solve's filter (above). A minimum segment length of one cell along a column, so a series segment is printable. The gyroid ladder and the seam rules (batch H, pressSeam) do the joining in the field, as now. |
| **One voxel squeezed along two directions** | Our tables are build-Z only, so a side press is "estimated" (R6). Gyroid has cubic symmetry; honeycomb is strongly anisotropic. | Each case's load direction is recorded per shared voxel. A crossing region is marked "estimated" and honeycomb there is flagged. A9's angled coupons make it exact when they exist. |
| **Many solutions** | Topology optimisation regularises an underdetermined design (filters, a minimum mass or compliance objective). | Minimal change from today's designs (stable for the app and for groups that share nothing), mass as the tie-break, mass reported per group (26). |

## 4. Questions for him

- **Q-C1:** are the groups squeezed SEPARATELY (one at a time: the load-case reading above)? Or can some be squeezed together? Two
  groups squeezed together would be ONE load case, their pressures summed where they share material.
- **Q-C2:** "hits its target" means |achieved − target| ≤ τ per column. I propose τ = max(0.05 mm, 2 % of the target). Or the
  group's ± band?
- **Q-C3:** until B9, "hits" is judged in core's 1-D columns, which are about 3.6× softer than the app's 3-D sim on his Covered
  pad. Is that acceptable, said in the receipt, until the 3-D check exists?
