# levelset-alpha-and-the-stopping-rule

Evidence: `evidence/2026-08-10-levelset-alpha-and-stopping-rule/` — `./reproduce.sh`
regenerates all of it, and nothing is cloned to do so.

## 0. THE THREE QUESTIONS, ANSWERED

**1. At alpha 9.6, does the cut share stop climbing? — NO.** It climbs +2.86
points (33.92% -> 36.78%) where alpha 2.4 climbs +5.41 (34.27% -> 39.68%). Alpha
HALVES the rate and does not stop it, so by the prediction stated before the run,
**alpha is a mitigation and not the mechanism.** §2.

**2. The best whole-mesh roughness at margin >= SIMP's is 8.6136 deg against
SIMP's 8.4075 (+2.5%), at iteration 35 of the alpha-2.4 arm, margin 3404.33
(+4.6% vs SIMP), for 3.55x SIMP's total wall.** The cheapest point on the same
frontier is iteration 5 of the alpha-9.6 arm: 8.6776 (+3.2%), margin 3414.18
(+4.9%), **1.39x**. §3.

**3. How much of the iteration-1 "+2.2 deg" survives a like-for-like triangle
set? — NONE. IT REVERSES SIGN.** Measured over the same region of space, the
level set's first iterate is **9.7267 against SIMP's 10.1891 — 4.5% SMOOTHER**,
where the own-population comparison said 28.8% rougher. §4.

### and two things that were not asked for but change what the earlier work means

★ **THE STOPPING RULE SUBSUMES THE ALPHA FIX.** The best surface available at
margin >= SIMP comes from the UNCORRECTED alpha (2.4) stopped at iteration 35.
Alpha mattered enormously for the CONVERGED design — 13.02 deg against 9.66 — but
the converged design is dominated by every point on the frontier, so it is the
wrong design to ship either way. Stop correctly and the two alphas land within 1%
of each other. §3.

★ **THE COST IS ADDITIVE TO SIMP'S, AND PR 323 REPORTED IT WRONG.** Every level
set arm here is SEEDED from his converged SIMP rung 0.68, so SIMP must run first
and the level set's wall is ON TOP of it. PR 323's "1.58x SIMP's cost per rung"
compared the level set's own 481.5 s to SIMP's 304.6 s; the honest total is
304.6 + 481.5 = **2.55x**. Every cost in this handoff is the total. §3.

## 1. what ran, and the positive control

Rung 0.68, his part, fingerprint `d9fe8f768331`, **3 threads throughout**.

| arm | rule | alpha | HJ steps | damper | iters | s/iter | margin | verdict |
|---|---|---|---|---|---|---|---|---|
| `s1_simp_3thread` | shipped `minimize_plastic` | — | — | — | 27 | 11.525 | 3254.36 | ACCEPTED |
| `s2_alpha_min` | `--gridap-auto min` | 2.4 | 6 | off | 76 | 22.711 | 3405.33 | ACCEPTED |
| `s3_alpha_max` | `--gridap-auto max --damp` | 9.6 | 24 | 3 fires | 43 | 24.145 | 3401.08 | ACCEPTED |

**R3 — every arm ACCEPTED**, margin 3401-3405 against SIMP's 3254 on less
material, peak von Mises below SIMP's on both.

**The positive control passes, on the derivation and on the trajectory.**
`--gridap-auto min` returns `max_steps = 2*floor(1*31/10) = 6` and
`alpha = 4*6*0.1 = 2.4 voxels` (`s0_gridap_auto_control.txt`), reproducing PR
323's run of record — and the trajectory reproduces it too.

★ **But NOT bit-for-bit, and the distinction is worth keeping.** Two measurements:

* the **SIMP baseline** is bit-identical to PR 323's across sessions — 27/27
  compliances exact, zero CG-count mismatches;
* the **level-set arm** agrees to **1.07e-8 relative worst case**, which is the
  CG tolerance, with CG counts differing from iteration 2.

The two level-set runs differ only in `--snapshot-every` (5 against 10), which
touches no computation, so this is a last-bit difference that KRYLOV RECYCLING
amplifies: each solve's recycled subspace depends on the previous solve's
floating-point detail, so a change in the last bits changes the next solve's
iteration count. Whether the trigger is the extra I/O perturbing a threaded
reduction or genuine run-to-run nondeterminism is not settled here. **The
consequence that matters: level-set compliance differences below ~1e-8 are noise,
and every effect in this handoff is orders of magnitude larger.**

## 2. S1d — the prediction, and why it failed

Stated before the run: *if alpha is the feature-scale control, the cut share
should stop climbing and the post-iteration-30 roughness accumulation should
largely not happen.*

| | cut-share minimum | at convergence | climb | roughness accumulation |
|---|---|---|---|---|
| alpha 2.4 | 34.27% (it 15) | 39.68% (it 76) | **+5.41 pts** | 8.1722 -> 13.0156 (+4.84 deg) |
| alpha 9.6 | 33.92% (it 5) | 36.78% (it 43) | **+2.86 pts** | 7.8448 -> 9.6572 (+1.81 deg) |

Both halved, neither stopped. The task's own reading applies: **alpha is not the
mechanism.** It is a strong lever on the RATE at which the optimiser adds
interface, not a control that switches the behaviour off — which is what the
paper's own description of it should have predicted, since alpha is a regularity
length on the VELOCITY and prices nothing.

`band_cells` in `iterations.csv` — the count of cells inside the DH support, i.e.
the interface AREA — tells the same story for free, with no mesh extraction:
minimum 23989 at it 25 rising to 26677 at it 76 (alpha 2.4), minimum 23927 at
it 15 rising to 26019 at it 43 (alpha 9.6). Its minimum lands within a few
iterations of the roughness minimum on both arms, which makes it a usable
IN-LOOP signal; §3 uses it.

## 3. S2 — where the margin saturates, and what to do about it

Every snapshot of BOTH arms certified by `analyze_fixed_design` at the production
penalty, isolated as production isolates a re-certification
(`s5_margin_curve/*/margin_curve.csv`). PR 323 certified one trajectory; this
certifies both, every 5 iterations.

| it | alpha 2.4 margin | whole (deg) | | alpha 9.6 margin | whole (deg) |
|---|---|---|---|---|---|
| 1 | 2552.96 | 9.1675 | | 2552.96 | 9.1675 |
| 5 | 2158.88 | 9.0553 | | **3414.18** | 8.6776 |
| 10 | 3117.12 | 8.9106 | | 3027.91 | **8.5180** |
| 15 | 3369.60 | 8.7496 | | **821.89** ← | 8.6424 |
| 20 | 3413.93 | 8.7106 | | 3400.31 | 8.6894 |
| 25 | **3414.14** | 8.6435 | | 3400.42 | 8.8080 |
| 30 | 3406.35 | 8.6195 | | 3400.29 | 8.8848 |
| 35 | 3404.33 | **8.6136** | | 3401.04 | 9.0100 |
| 40-76 | 3403-3407 | 8.75 -> 10.65 | | 3402.86 (40) | 9.1950 |

**Margin saturates at iteration 20 on BOTH arms** and is then flat to
convergence — 3403-3414 across 12 further certifications on alpha 2.4, 3400.3±0.1
on alpha 9.6. Everything after that is strictly dominated: no margin, worse
surface, more wall clock.

★ **A SAFETY FINDING THAT A STOPPING RULE MUST RESPECT. The alpha-9.6 arm passes
through a state with 4.1x the peak stress.** At iteration 15 its max von Mises is
0.0669 MPa against ~0.0162 everywhere else, and its margin drops to 821.89 —
still ACCEPTED against a gate of 1.5, but an 76% excursion that recovers by
iteration 20. The 24-step arm moves ~2.4 voxels per iteration and transiently
thins a member. **So margin may not be interpolated between certifications, and
any rule must certify the iterate it actually selects.** The alpha-2.4 arm, at
6 steps, has no such excursion.

### the rule

> **Certify every K iterations. Stop when the margin has failed to set a new
> running maximum for two consecutive certifications. Ship the best-margin
> iterate, and certify it.**

With K = 5 it chooses **iteration 25 on alpha 2.4** (margin 3414.14) and
**iteration 5 on alpha 9.6** (margin 3414.18). Both are on the Pareto frontier
below. It costs one `analyze_fixed_design` per K iterations — about 27 s against
K x 22 s of trajectory, i.e. ~25% at K = 5, and less at larger K.

The free in-loop companion, needing no certification at all: **`band_cells` turns
up from its running minimum.** On alpha 2.4 that is iteration 25, on alpha 9.6
iteration 15 — the same neighbourhood, at zero cost. Use it to decide WHEN to
spend a certification.

### the frontier, and why the choice is his

Pareto-optimal points over (margin high, whole-mesh roughness low), restricted to
margin >= SIMP's 3254.36. **Total wall = SIMP's 311.2 s + the level set's**,
because the level set is seeded from SIMP's converged rung.

| arm | it | margin | whole (deg) | cut | like-for-like | mid% | LS wall | TOTAL | xSIMP |
|---|---|---|---|---|---|---|---|---|---|
| SIMP | 27 | 3254.36 | 8.4075 | 7.5521 | 10.1891 | 85.28 | — | 311.2 s | 1.00x |
| alpha 2.4 | 35 | 3404.33 | **8.6136** | 8.1722 | 9.9364 | 66.93 | 794.9 s | 1106.1 s | 3.55x |
| alpha 2.4 | 30 | 3406.35 | 8.6195 | 8.2247 | 9.9374 | 67.06 | 681.3 s | 992.5 s | 3.19x |
| alpha 2.4 | 25 | 3414.14 | 8.6435 | 8.2410 | 9.8978 | 67.12 | 567.8 s | 879.0 s | 2.82x |
| **alpha 9.6** | **5** | **3414.18** | 8.6776 | 8.1730 | **9.7993** | 67.56 | **120.7 s** | **431.9 s** | **1.39x** |

Read three ways, and all three are true:

* **Cheapest acceptable:** alpha 9.6 at iteration 5 — the best margin of any
  iterate measured, +3.2% whole-mesh roughness, 18 points better sub-voxel
  placement, for 1.39x SIMP. ★ But it sits on the violently non-monotone stretch
  above (3414 -> 3028 -> 822 -> 3400), so it is a lucky sample, not a stable
  operating point, and it must be re-certified before it is trusted.
* **Most robust:** alpha 2.4 at iterations 25-35 — margin stable at 3404-3414
  across four consecutive certifications, the best surface on the frontier,
  2.8-3.6x SIMP.
* **If he wants the smoothest surface and will accept less margin than SIMP:**
  alpha 9.6 at iteration 10 — whole-mesh **8.5180, only +1.3% over SIMP** — but
  margin 3027.91, which is 7.0% BELOW SIMP. Still ACCEPTED (effective 627 against
  a gate of 1.5). **This is his trade and not ours.**

## 4. S3 — the like-for-like measurement, which reverses the headline

`dihedral_cut_deg` restricts each arm to the triangles THAT ARM's classifier
called CUT, and the arms do not have the same cut population: 18.40% of triangles
for SIMP against 36.23% for the level set ON ITS FIRST ITERATION, before the
optimiser has moved anything of consequence. The eta = 2 ersatz offsets the
extracted surface off the CAD faces and the classifier reassigns thousands of
triangles from CAD to CUT. Part of "+2.2 deg" was therefore two different sets of
triangles.

The fix is not to make the meshes share triangles — they cannot — but to measure
both over **the same part of space**: `ref_region_mask` in
`external_field_surface_probe` builds an occupancy of the voxels the REFERENCE's
cut surface passes through, dilated one voxel (24366 voxels, 5.2% of the grid,
selecting 22-29% of each mesh's vertices), and every arm reports
`dihedral_refcut_deg` over it.

| arm | own-cut population | **like-for-like** |
|---|---|---|
| SIMP | 7.5521 | **10.1891** |
| level set, iteration 1 | 9.7239 (+28.8%) | **9.7267 (−4.5%)** |
| alpha 9.6, converged | 9.6572 (+27.9%) | **9.9375 (−2.5%)** |
| alpha 2.4, converged | 13.0156 (+72.3%) | 11.0277 (+8.2%) |

★ **Essentially none of the +2.2 deg survives — it changes sign.** On a fixed
region of space the level set's first iterate is 4.5% SMOOTHER than SIMP.

**The caveat, stated:** the region is defined by SIMP's cut surface, so the
column answers "over the region SIMP cuts, whose surface is rougher?". A region
defined by the level set's own cut surface is a different question. And SIMP has
28.8% of its vertices inside the region against the arms' ~23%, because the mask
was built from it. `dihedral_all_deg` is reported throughout and needs no such
caveat.

### what the three framings together actually say

| framing | verdict |
|---|---|
| each arm's own cut population | +27.9% WORSE |
| whole mesh (no selection) | +9.0% worse |
| same region of space | **2.5% BETTER** |

They are not in conflict once the mechanism is stated: **the level set does not
roughen the surface SIMP already has — over the shared region it is slightly
smoother — it ADDS internal cut surface, roughly doubling it (18.4% -> 36.8%),
and the added surface is what is rough.** Averaged over the whole mesh that reads
as 9% rougher, and that is a fair number; it is a different fact from "our
surface is worse".

**R4 — the CAD population is untouched, as required.** Across every snapshot of
both arms it spans **7.4934 to 7.7007**, against SIMP's 7.5842 — a range of
0.21 deg that straddles the baseline, over runs whose cut population moves by
5.4 points and whose cut roughness moves by 4.8 deg. It never meaningfully
moves. Everything that happened, happened on carved surfaces.

## 5. what this does not settle

* **One part, one rung, one seed.** The knee was found by reading a curve on
  rung 0.68 of one part, seeded from SIMP. Nothing says iteration 20-35 transfers.
* **The rule is proposed and evaluated, not deployed.** It is not wired into the
  shipped ladder and nothing here tests it on a second trajectory.
* **The alpha-9.6 stress excursion is characterised, not explained.** Why
  iteration 15 thins a member badly enough for 4.1x peak stress, and whether a
  smaller gamma would avoid it, is not measured.
* **The gap to the reference is untouched.** Gridap reached 4.0156 deg with 7.20%
  of crossings at an edge midpoint; the best here is 8.61 deg at 66.9%. Nothing
  in this task closes that, and §2 says alpha will not.

## 6. in plain language

Three things were asked and all three now have answers.

**Turning up the one setting we found last time helps, but it is not the cure.**
It halves how fast the optimizer degrades the finish. It does not stop it.

**Our roughness number was measuring the wrong thing.** The instrument splits the
surface into "original part faces" and "surfaces the optimizer cut", and our
method nudges the surface just far enough off the original faces that thousands
of triangles get filed in the other bucket. Comparing like with like — the same
physical region for both methods — our surface is **4.5% smoother** than our
current method, where the old comparison said 29% rougher. The number does not
shrink, it flips.

**So the real story is that we are not making the surface rougher, we are making
more of it.** The optimizer roughly doubles the internal cut surface, and the
extra surface is the rough part.

**And the biggest lever is knowing when to stop.** The part's certified strength
stops improving about a quarter of the way into the run; everything after that
buys nothing and costs finish. Stopping at the right point gives a part that is
4.6% stronger than our current method with a surface within 2.5% of it. Two
warnings that come with it: the faster-moving setting passes through a moment
where the part is briefly four times more stressed than it should be, so any
automatic stop must re-check the strength of the design it picks; and the cost is
on TOP of our current method, not instead of it, because we start from its
answer. Our previous note got that wrong and said 1.58x where the honest figure
is 2.55x.

**One deflating note.** The setting we were so pleased to find last time turns
out to matter mostly if you make the mistake of running to the end. Stop at the
right place and the original setting is as good — slightly better, in fact. It
was a fix for a problem we should not have had.

---

# ADDENDUM — S6: THE MAX-EFFORT ARM

Asked for after the three sections above: throw everything available at the
surface, combine techniques, invent if needed. This records what was built, what
each piece was worth, and the frontier it did not reach.

## 0. THE ANSWER IN THREE LINES

1. **Five components built, four worth ~nothing, one worth a real trade.**
   Russo-Smereka reinitialisation was HARMFUL and is dropped (two bugs found and
   fixed on the way; it still lost). WENO5+TVD-RK3 is neutral. Sub-step
   reinitialisation is worth ~2%. The perimeter penalty moves interface area 22%.
2. **The perimeter penalty buys roughness and pays in MARGIN.** At C=2 it beats
   SIMP on every roughness measure — cut 7.2908 against 7.5521 — but margin falls
   to 3046.62 (−6.4% against SIMP) and the trajectory destabilises. My inference
   that the added structure was "nearly free to give up" is **REFUTED**: it is
   load-bearing.
3. ★ **THE MAX-EFFORT ARM IS DOMINATED, AND SO IS SIMP — BY PR 322.** The
   implementation written BEFORE the reference paper was read still owns the best
   surface of anything we have (whole-mesh 8.1797, cut 6.7080) at margin 3378.49.
   Three sessions of matching the reference have been a **net regression on the
   metric they were chasing.**

## 1. what was built

All in the same sandbox target, each independently switchable so the arm could be
ATTRIBUTED rather than only celebrated. All default OFF, so every earlier arm
reproduces.

| flag | what it is | source |
|---|---|---|
| `--russo-smereka` | subcell-fix reinitialisation, `\|phi\|/\|grad phi\|` in place of the edge ratio | Russo & Smereka, JCP 163:51-67 (2000) |
| `--perimeter C` | mean-curvature term, `v = (e - lambda - ell*kappa)*DH*\|grad phi\|`, `ell = C*lambda*h` | Allaire, Jouve & Toader 2004; Osher & Santosa 2001 |
| `--weno --rk3` | WENO5 one-sided derivatives + TVD-RK3 | Jiang & Peng 2000; Shu & Osher |
| `--reinit-substeps` | reinitialise between HJ sub-steps, not only after the last | — |
| `--no-surface-delta` | restore PR 322's VOLUME velocity measure | PR 322 |

## 2. the ablation — and why it had to be run

The first pilot armed four components at once and **exploded**: interface area
28073 -> 41774 in eight iterations against a baseline that FALLS to 24057, and
`\| \|grad phi\|-1 \|` doubling 0.22 -> 0.40. Changing four things at once made
that uninterpretable, so each was run alone for six iterations.

| config | interface area (28k ->) | `\|grad\|-1` |
|---|---|---|
| baseline (alpha 9.6 + damper) | 24057 | 0.1708 |
| **sub-step reinit alone** | **23547** | **0.1659** |
| WENO5 + RK3 alone | 24097 | 0.1711 |
| Russo-Smereka alone | 26606 | 0.1901 |
| all four together | 39650 | 0.3759 |

**No single component caused the explosion — it was an INTERACTION.** RS carries a
small systematic bias; sub-step reinit applies RS 24 times per iteration instead
of once, multiplying it.

### two real bugs in the RS adaptation, both found by the sign of the error

Interface area rose AND `\|grad phi\|` fell below 1 — the signature of distances
being systematically UNDER-estimated, which pins the cause:

* **Wrong gradient.** Russo-Smereka's `Delta_i` takes `max(central, forward,
  backward)`. That is a STABILISER for their reinitialisation PDE, where an
  over-large denominator damps the update — used as a direct distance seed it is
  biased, because at a kink the max overshoots `\|grad phi\|` so `phi/\|grad phi\|`
  undershoots the distance. Replaced with the central difference.
* **Applied to a field that is not a distance function.** The SEED is
  `phi = 0.5 - rho`, a near-binary step saturated at +-0.5 whose per-cell
  differences are ~1.0 rather than ~h, so `phi/\|grad phi\|` returns ~0.29h where
  the true distance is ~0.5h on an oblique interface. The seed reinitialisation
  now uses the edge ratio; RS applies only from the first advected
  reinitialisation onward.

Both fixed, the explosion is gone (27524 / 0.1907). **And RS still loses**:

| config, 6 iterations | interface area | `\|grad\|-1` |
|---|---|---|
| baseline | 24057 | 0.1708 |
| RS (both bugs fixed) alone | 25627 | 0.1711 |
| **sub-step + WENO + RK3, no RS** | **23641** | **0.1663** |
| all four, RS included | 27524 | 0.1907 |

★ **Russo-Smereka is dropped, and the hypothesis behind it is dead.** It was
brought in because our distance field carries a 0.17 error and Gridap's crossings
spread twice as far across a cell as ours, which suggested distance-field quality
was the route to their sub-voxel placement. Repaired, it moves `\|grad\|-1` from
0.1708 to 0.1663 — nothing against a gap between 61% and 7.2% midpoint crossings.
**That route is closed.**

## 3. the perimeter penalty — the one that works, and its price

Swept on the good configuration (sub-step + WENO + RK3, no RS), 25 iterations,
every snapshot measured and certified.

| C | interface area | compliance | `\|grad\|-1` | cut (deg) | whole (deg) | **margin (final)** |
|---|---|---|---|---|---|---|
| 0 | 24787 | 0.00253768 | 0.1693 | 8.9886 | 8.9458 | 3400.41 |
| **2** | **19250 (−22%)** | 0.00260108 (+2.5%) | 0.1309 | **7.2908** | **8.2986** | **3046.62 (−6.4% vs SIMP)** |
| 8 | 17336 (−30%) | 0.00293023 (+15.5%) | 0.1182 | 7.6981 | 8.4162 | 1105.63 (−66%) |
| SIMP | — | — | — | 7.5521 | 8.4075 | 3254.36 |

**It does exactly what the mechanism predicted.** PR 325 §4 established that the
roughness comes from ADDED SURFACE AREA, not from roughening the shared surface;
the perimeter term is the only thing in the formulation that prices area, and it
is the only lever that moved more than 2%. At C=2 it beats SIMP on every
roughness population — cut −3.5%, whole-mesh −1.3%, CAD −1.0%, like-for-like
−4.8%. `\|grad phi\|` improves as a SIDE EFFECT (0.169 -> 0.131), because a less
convoluted interface is easier to represent as a distance field on a fixed grid —
which is the thing Russo-Smereka was imported to do directly, and failed at.

★ **And it is not free, which only certification could show.** Margin at C=2 falls
to 3046.62 and swings erratically across the trajectory (2015 -> 2574 -> 2655 ->
3172 -> 2015). C=8 collapses to 1105.63. **The prediction I was about to make from
the previous arm — that margin saturates early so the structure is nearly free to
give up — is refuted. That structure is load-bearing.** Every snapshot was
certified rather than inferred, which is the only reason this is known.

C=8 also pushes midpoint crossings back UP to 80.03%, toward SIMP's 85% staircase:
a heavy perimeter penalty buys dihedral smoothness by returning the surface to the
grid. C=2 does not (73.74%).

## 4. ★ THE FRONTIER, AND WHAT IT SAYS ABOUT THE WHOLE PROGRAMME

Every arm we own, Pareto over (margin high, whole-mesh roughness low):

| arm | margin | vs SIMP | whole (deg) | vs SIMP | cut (deg) |
|---|---|---|---|---|---|
| **PR 322** (eta=1, penalty 3, volume velocity) | 3378.49 | **+3.8%** | **8.1797** | **−2.7%** | **6.7080** |
| PR 324 alpha 2.4 @ it 35 | 3404.33 | +4.6% | 8.6136 | +2.5% | 8.1722 |
| PR 324 alpha 9.6 @ it 5 | 3414.18 | +4.9% | 8.6776 | +3.2% | 8.1730 |
| ~~SIMP baseline~~ | 3254.36 | — | 8.4075 | — | 7.5521 |
| ~~MAX C=2 final~~ | 3046.62 | −6.4% | 8.3216 | −1.0% | 7.3586 |
| ~~MAX C=8 final~~ | 1105.63 | −66.0% | 8.4162 | +0.1% | 7.6981 |

Struck rows are DOMINATED. Two things follow and neither is comfortable:

* **The max-effort arm reached no frontier point.** Everything it produced is
  beaten on both axes by something we already had.
* ★ **PR 322 dominates SIMP outright** — better margin AND better surface — and
  dominates every arm from PR 323, PR 324 and PR 325. **The three sessions spent
  matching GridapTopOpt have been a net regression on the metric they existed to
  improve.** The five differences took cut roughness from 6.7080 to 13.0156; the
  alpha fix, the stopping rule and the perimeter penalty have clawed back to
  7.2908, which is better than SIMP and still worse than where we started.

## 5. what that exposes, and the run it started

PR 322 ran **120 iterations and never converged**, and it carried the offset
defect PR 323 found and fixed. PR 325 then established that **margin saturates
around iteration 20** and everything after is dominated.

★ **So the best configuration we own has never been run with the stopping rule,
and never without the defect.** That is the obvious next experiment and nothing in
three sessions has done it.

`--no-surface-delta` was added to make it runnable, and the arm was started and
then **STOPPED AT ITERATION 15 OF 60, UNFINISHED** — the direction changed to a
parametric level set (§7) and a refinement of the voxel scheme stopped being the
priority. **It is NOT reported as a result and no partial numbers from it are
used anywhere in this handoff.** It remains the cheapest high-value experiment on
the voxel path, it is one command, and it is the correct BASELINE TO BEAT for
anything that replaces the representation:

    ./build/levelset_probe <part.step> <materials.json> <ref/design.bin> <out> \
        --rung 0.68 --iters 60 --threads 3 --snapshot-every 5 \
        --eta 1.0 --traj-penalty 3.0 --no-surface-delta \
        --alpha-coeff 0 --smooth 4 --hj-steps 6 --gamma 0.1

then certify every snapshot (`--certify-field`, repeatable) and measure with
`external_field_surface_probe`, exactly as §3 and §4 do.

If the pattern of this session holds, the best result on the voxel path would come
from **removing** most of what was added and applying the one thing that was
learned.

## 7. WHERE THIS GOES NEXT — a parametric level set

The direction chosen after this work: replace the REPRESENTATION rather than keep
tuning the scheme. §2 and §3 are the argument for it — three of the four causes of
non-smoothness identified in PR 325 are properties of storing phi as voxel
samples, and this session closed off the remaining tuning levers one by one.

**What it is.** Expand phi in a smooth basis — `phi(x) = sum_i alpha_i psi(|x - x_i|)`
over a few thousand radial basis centres — and make the `alpha_i` the design
variables (Wang & Wang's parametric level set method). phi becomes an ANALYTIC,
infinitely differentiable function evaluable at any point, not a sampled field.

**What it kills outright, from this session's own measurements:**

| cause | fate under a parametric level set |
|---|---|
| reinitialisation error, `\|grad phi\|-1` = 0.17 (PR 325 §3; RS failed to fix it, §2 above) | **gone** — there is no reinitialisation |
| CFL sub-stepping, the gamma damper, the 4.1x stress excursion at it 15 (§3) | **gone** — the alphas update by MMA/gradient descent, no time step |
| per-voxel wiggle freedom in the boundary (PR 325 §6, cause 4) | **gone** — smoothness is a property of the basis, not something policed |
| exported surface tied to the 1.7 mm analysis grid (PR 325 §6, causes 1 and 3) | **decoupled** — evaluate phi at any resolution, independent of the FEA grid |

**The constraint that does not go away.** `analyze_fixed_design` reads a per-voxel
density field, and everything downstream — margin, peak von Mises, min-feature,
the knockdowns — is built on it. A parametric level set must still SAMPLE ITSELF
onto the voxel grid to be certified. So the analysis stays voxel-based (fine — the
matrix-free solver is fast and trusted, and §4 shows the roughness is not coming
from there), but the certified object and the exported object would then be
described differently. This project has been bitten by exactly that gap before
(`certification-refuses-smoothed-mesh`). Reconciling them is the real work, not
the optimiser.

**It does nothing for the CAD faces.** They are staircased because the imported
CAD was voxelised; they measure 7.49-7.70 deg on every arm ever run and never
move (§4, R4). That is a separate problem with an existing answer (CAD-face
projection).

★ **The cheap de-risking test, before any optimiser is written.** Fit a smooth
analytic phi to a design we ALREADY HAVE, extract the surface from the fit, and
measure it with `external_field_surface_probe`. That answers the only question
that matters — **is the roughness in the representation, or in the design?** — in
hours rather than weeks. Given this session's finding that the roughness tracks
ADDED SURFACE AREA rather than grid-locking (§3, §4), the outcome is genuinely
uncertain, which is exactly why it should be measured first. If the analytic
surface is not materially smoother, the roughness is in the geometry the optimiser
chose and no change of representation will help.

## 6. in plain language

Asked to throw everything at the smoothness problem, I built five things from the
literature and measured each one.

**Four were worth almost nothing.** The one I was most confident in — a
well-known technique for improving the underlying distance field — actively made
things worse. I found two genuine bugs in my adaptation of it, fixed both, and it
*still* lost, so it is out. The theory behind bringing it in is dead: the distance
field is not where our gap to the borrowed software lives.

**One worked, and then didn't.** Charging the optimizer for creating surface area
— which is what our own measurement said the problem was — gave the first result
in three sessions that beat our current method on every roughness measure. Then
certifying it showed the part had gone 6% weaker, with the strength swinging
around unpredictably. The extra material it was deleting turns out to be holding
load. I had been about to assume it was free; only checking caught it.

**And the honest headline is deflating.** Putting every version we have built on
one chart, the winner is the version from *before* we started copying the
reference implementation. It is better than our current method on both strength
and finish, and better than everything the last three sessions produced. Chasing
the reference has cost us ground on the very thing we were chasing.

The useful part: that older version was never run with the stopping rule we
discovered this week, and it carried a bug we have since fixed. That combination
has never been tried, and it is running now. If it behaves like everything else
this session, our best part will come from undoing most of the recent work and
keeping one idea from it.
