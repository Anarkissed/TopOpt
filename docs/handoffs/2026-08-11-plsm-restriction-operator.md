# plsm-restriction-operator

Evidence: `evidence/2026-08-11-plsm-restriction-operator/`.

★ **§0's PREMISE, ACCEPTED.** PR 326 concluded "the surface and the capability
are the same mechanism". That was wrong and the brief's correction is right:
**SIMP nucleates freely too** — its density may fall anywhere, which is why it
needs no seed either — and it does not produce SIMP-times-three surface because
it has a **restriction operator**. I had conflated nucleation with *unrestricted*
nucleation. This task tests three restriction operators against that corrected
premise.

---

## 0. THE ANSWERS

**1. Which operator moved the internal surface most, and to what? — NONE OF THE
THREE. The perimeter penalty, which is not a restriction operator, beat all of
them.** At matched iteration 50, against 75,488 with no operator:
filter r=1 **65,863 (−12.8%)** · robust triple **53,378 (−29.3%)** · diffusion
**76,848 (+1.8%, it makes it worse)** · **perimeter C=1 53,175 (−29.6%)**.
★ *Do not read these against SIMP's 26,191 — different volume convention, see
answer 5.*

**2. What did it cost in margin? — THE ONLY OPERATOR THAT CLEARS R4 IS THE
FILTER AT r=1.** Filter r=2/r=3 and the robust triple all fall below SIMP's
3254.3. The perimeter penalty clears it at 3383.7 (+4.0%).

**3. Does any arm clear carved ≤ 7.5521 with margin ≥ 3254.3? — NO.** The best
carved is the perimeter penalty's 9.1077, +20.6% over SIMP.

**4. Does a filter make the perimeter penalty unnecessary? — NO, AND THEY DO NOT
COMPOUND.** Together: 56,281 triangles, WORSE than the penalty alone at 53,175.

★★ **5. AND THE PREMISE OF PR 326 AND OF THIS BRIEF IS WRONG BY A FACTOR OF
FIVE. THE SHIPPED PLSM, WHICH HAS NO RESTRICTION OPERATOR AT ALL, CARRIES +20.4%
INTERNAL SURFACE OVER SIMP — NOT 3×.** This is not an estimate and not a
normalisation. It is on disk, in
`evidence/2026-08-10-plsm-production/s2_surface/surface.txt`, measured by the same
`external_field_surface_probe` in the same invocation as SIMP's own row:

| rung 0.68 | enclosed volume | ★ CUT triangles | carved | CAD err |
|---|---|---|---|---|
| SIMP | 440,550.9 mm³ (88,840 vox) | **26,191** | 7.5521 | 0.4293 |
| ★ **PLSM, as shipped** | 436,387.2 mm³ (88,001 vox) | **31,528** | 7.6090 | 0.4741 |
| | **−0.9%** | ★ **+20.4%** | −0.8% | −10.4% |

★ **The volumes match to within 0.9%, so no normalisation is needed and none is
applied.** The "3× the surface" figure came from comparing a PLSM that prints
75,016 voxels against a SIMP that prints 88,840 — **17.1% less material and
therefore far more void to bound.** Per thousand printed voxels the internal
surface is 295 (SIMP), **358 (shipped PLSM, +21%)**, and 1,006 (this task's
control arm, +241%).

★★ **SO THIS TASK MEASURED THE WRONG BASELINE.** Every arm in §1 sits at the
probe convention, where the control carries +188% over SIMP; the shipped path
carries +20.4%. **The within-task ordering survives intact** — all ten arms share
one convention, so "the perimeter penalty beats all three candidates" stands. What
does not survive is the motivation: **a restriction operator was being sought for
a 3× problem that is, on the path that ships, a 1.2× problem.** Whether any of
these operators is worth its cost at +20% is UNMEASURED and is now the ranked-first
next step (§7).

---

## 1. THE TABLE

★ Matched iteration 50, ONE `external_field_surface_probe` invocation, SIMP's
rows produced in the same run at the same extraction factor (R2). Iteration 50
and not 60 because the control arm stopped at 56 on the shipped compliance
plateau and has no it0060 snapshot — see §4.

| arm | what | carved | ★ n_cut | vs none | tri/1000vox | CAD err mm | margin | vs SIMP |
|---|---|---|---|---|---|---|---|---|
| **SIMP** | the bar | **7.5521** | **26,191** | — | **295** | 0.4293 | **3254.3** | — |
| ★ **PROD** | **PLSM as shipped** | **7.6090** | **31,528** | — | **358** | 0.4741 | **3297.3** | **+1.3%** |
| | ★ *the two rows above are the only like-for-like pair here — same volume to 0.9%. Everything below is at the probe convention, 17.1% less material, and is NOT comparable to them.* ||||||||
| F0_none | no operator | 14.3167 | 75,488 | — | 1,006 | 0.4726 | 3394.6 | +4.3% |
| FA_r1 | **A** filter r=1 | 12.4014 | 65,863 | −12.8% | 878 | 0.4614 | 3332.3 | +2.4% ✓ |
| FA_r2 | A filter r=2 | 11.6480 | 62,728 | −16.9% | 836 | 0.4901 | 2095.4 | −35.6% ✗ |
| FA_r3 | A filter r=3 | 11.0810 | 57,471 | −23.9% | 766 | 0.5331 | 1837.3 | −43.5% ✗ |
| FB_robust | **B** robust triple | 12.3516 | 53,378 | −29.3% | 711 | 0.4726 | 3212.6 | −1.3% ✗ |
| FC_r03 | **C** diffusion T=0.03 | 14.5449 | 76,848 | **+1.8%** | 1,024 | 0.4694 | 3385.3 | +4.0% |
| FC_r30 | C diffusion T=0.30 | 15.4396 | 81,144 | **+7.5%** | 1,082 | 0.4807 | 3378.3 | +3.8% |
| ★ **FP_perim1** | **perimeter C=1** | **9.1077** | **53,175** | **−29.6%** | **709** | **0.4261** | **3383.7** | **+4.0%** ✓ |
| FX_best_perim | A r=1 + perimeter | 10.4316 | 56,281 | −25.4% | 750 | 0.4311 | 3367.9 | +3.5% ✓ |

## 2. ★ CANDIDATE A — THE BRIEF'S TOP PICK, REFUTED BY MEASUREMENT

The Helmholtz filter is a faithful transplant: `(I − r²∇²)ρ̃ = ρ` on the ersatz
density, projected back to a part, with the sensitivity chained through both.
**F is self-adjoint, so its adjoint is the same solve** — that is a property of
the PDE form, not an approximation, and getting it wrong would have been
invisible in the objective. It costs **12% of a run**: one scalar unknown per
voxel against elasticity's three per node.

★ **It is beaten on every column by the global scalar tax it was meant to
replace**, and only r=1 clears the margin bar while delivering less than half the
surface reduction.

★ **AND IT DEGRADES CAD ACCURACY AS THE RADIUS GROWS** — 0.4614 → 0.4901 →
0.5331 against SIMP's 0.4293. A filter is a smear and it does not know which
surfaces matter: it erodes the part's outer skin along with the interior. That
was predicted when the frozen re-imposition was written and it is what happened.

★ **The two operators are doing different things, and `midpoint_share` shows
it.** The filter takes it DOWN (63.9% → 53.2%); the penalty takes it UP (→
80.9%). The filter smears and lets the surface sit anywhere; the penalty prices
interface and lets it settle onto the grid. On THIS part the grid-aligned answer
is also the CAD-accurate one, because these CAD faces are largely planar and
axis-aligned — **that is a property of this part and should not be read as a
general verdict on filters.**

## 3. ★ CANDIDATE C — THE FIRST SWEEP WAS INVALID AND IT WAS MY ERROR

**Reported plainly because the rebuilt answer means nothing without it.** I
scaled the diffusion term the way the perimeter penalty is scaled — `τ = T·λ·h`,
a formula I invented — and swept T at 1, 4, 16. The arms certified at **467 and
830** against SIMP's 3254, and the diffusion energy the term is supposed to
minimise **rose for thirty iterations**. I reported at the time that I could not
separate "wrong for this part" from "scaled wrong".

★ **Reading Yamada (2010) settled it in one sentence:** τ is *"a regularization
parameter representing the ratio of the fictitious interface energy and the
objective functional"*, and §3.2 adds that they *"introduce a characteristic
length L and an extended parameter Cₜ to normalize the sensitivities"*. τ is a
**ratio against dimensionless sensitivities**, swept in that paper between 1e-5
and 5e-4. Rebuilt as a true gradient-norm ratio, with the probe **refusing any
value ≥ 1** and the achieved ratio written to the CSV every iteration.

★ **The rebuilt version holds the margin (3385, 3378) and still does not work:
it INCREASES the surface, +1.8% and +7.5%.** A clean negative with the mechanism
intact. The mis-scaled arms are kept under `misscaled/` as evidence.

★ **I had not read the paper when I first built it**, though the brief said to
read the papers rather than its transcription of them. It was on the author's
server the whole time. Two 30-minute arms and a wrong conclusion.

## 4. ★ THE STOPPING RULE STOPPED THE CONTROL ARM MID-CLIMB

`F0_none` halted at iteration 56 on the shipped compliance plateau (window 10,
tol 1e-3) while its certified margin was still rising — **3194.81 at iteration 40
to 3394.56 at 50**. That is the brief's S(c) warning met in the first arm of the
task. `--no-compliance-stop` was added for everything after, and the comparison
is matched at iteration 50 because that is the last snapshot every arm reaches.

## 5. ★★ THE CONVENTION, AND WHY IT OUTRANKS EVERYTHING ELSE HERE

`docs/handoffs/2026-08-10-plsm-production.md` §1 corrects PR 324 and I had not
read it: the probe path targets `rung × part_solid` over every non-Empty voxel;
the shipped ladder targets `volume_fraction × n_active` with the 40,216 frozen
voxels OUTSIDE the budget. **88,424 and 75,281 printed voxels at the same nominal
rung 0.68.** My own measurements confirm it independently — SIMP encloses 440,551
mm³, every arm in §1 encloses ~372,000 mm³.

★ **The correction is bigger than the effect this task was chasing.** Answer 5
above has the table. Restated as the three numbers that matter:

- The premise: PLSM has **3×** SIMP's internal surface.
- What the shipped PLSM actually has, at SIMP's volume: **+20.4%**.
- What the best operator in this task bought, at the probe volume: **−29.6%**.

**The correction (−80 percentage points of premise) is an order of magnitude
larger than the treatment (−29.6% of an inflated baseline).**

★ **What this does and does not invalidate.**

- **Survives:** every within-task comparison. One convention across ten arms, so
  perimeter-beats-filter, filter-r2/r3-fails-the-margin-bar, diffusion-makes-it-
  worse, and filter-plus-penalty-does-not-compound are all real.
- **Does not survive:** every cross-convention claim. "−15% mass", "3× the
  surface", and "CAD error better than SIMP" are not results. PR 324, PR 325, PR
  326 and this task's own brief all contain at least one of them.
- **Newly open:** whether a restriction operator earns its keep at +20%. My
  arms cannot answer it — they are at the wrong volume.

★ **One caveat I will not paper over.** Production runs η=2, 40 iterations and
hole period 8; my arms run η=1, 50 iterations and periods 8–16. So the gap between
358 and 1,006 triangles per thousand voxels is volume AND configuration, and I
cannot split them from data on disk. **The 17.1% volume difference is established;
its share of the surface gap is not.** That is precisely what the ranked-first arm
in §7 measures, and it is why I have not launched it as a footnote to this task —
it deserves to be the whole of the next one.

## 6. ★ THE PROBLEMS I HIT — the list ARM 2 was built from

**P1 — the recommended mask was an exact no-op, and one line of the file said so.**
The addendum asked me to mask the shape-derivative integrand to a tube |φ| < ω
with ω ≥ 2η. `dheaviside` returns 0 for |t| ≥ η, so the integrand is ALREADY zero
outside |φ| < η; a tube at ω ≥ 4 voxels is a superset of where it is non-zero.
**Solved by implementing the intent instead** — the leak is the RBF support
radius, not the band, so the mask has to be in coefficient space and W must be
below the support radius to bite. (That was PR 326's arm; 1.6%.)

**P2 — I invented a scaling for Candidate C and destroyed three arms with it.**
§3. **Solved, by reading the paper**, plus a refusal so the units cannot be
misread twice.

**P3 — the volume constraint had to re-filter inside the bisection.** The filter
is not linear in the offset, so there is no closed form. The bisection now calls
`build_fields`, which means a filter solve per trial; halvings drop from 100 to
30 when a filter is active (7.5e-7 mm, five orders below a voxel). **Solved, cost
measured and reported: 12% of a run.**

**P4 — the filter smears across the part's outer boundary.** Predicted when the
frozen re-imposition was written, and it happened: CAD error degrades with
radius. **Not solved** — a filter that respected the CAD boundary would need the
frozen field inside the PDE's coefficients, which is a different operator.

**P5 — the compliance stopping rule is wrong for these arms.** §4. **Solved** with
`--no-compliance-stop`, but only after it had already truncated the control.

**P6 — `main` moved under the task and PLSM shipped to production.** Five commits
including a full production implementation with files of the same names as the
harness's. **Solved**: merged, and main had already converged the harness headers
into shims over core, so the duplication resolved itself. Note that
`plsm_basis.hpp` now DEFINES only `occupancy`, `occupancy_fine`, `inside_count`
and `match_offset` — everything else is a using-declaration over
`topopt::plsm_*`. There is one basis in the repository, not two.

**P7 — I told the reviewer a handoff did not exist when it did.** It was on
`main`, which this worktree lacked. **My error**: I checked the worktree and not
the repository.

**P8 — ★ ONE ASSERTION MESSAGE CHANGED, and R7 requires me to say which.**
`FATAL: --seed must be simp or holes` is now `FATAL: --seed must be simp, holes,
gyroid or stress`. **That is a WIDENING, not a weakening** — the same predicate
rejects the same bad input and two more spellings are accepted, for the monotone
task's seed families. No assertion was removed or loosened: the harness went from
18 to 32 in `levelset_probe.cpp` and 12 to 21 in `plsm_probe.cpp`, and every other
message from `main` is present verbatim (`assertion_census.sh`).

**P9 — the convention.** §5. **Not solved in this task** — it needs the
matched-volume arm ranked first below.

## 7. WHAT I WOULD DO WITH ANOTHER DAY, RANKED

1. ★★ **Run this configuration at production's volume and find out whether any
   restriction operator is still worth having.** The shipped PLSM carries +20.4%
   internal surface over SIMP, not 3×. A −29.6% treatment measured against a
   +188% baseline may be worth almost nothing against a +20% one, or it may close
   the gap entirely — **both are consistent with everything measured here.** One
   arm at rung 0.7973 (which the production run confirms targets 88,424 printed
   voxels on the probe path), with and without the perimeter penalty. ~1 h.
   ★ **Until this runs, this task has no actionable recommendation for production**,
   and I would rather say that than let §1's ordering be read as one.
2. ★ **Propose the three production defaults as a separate change, with
   measurements.** As shipped, the first time PLSM is switched on it runs
   η = 2, hole period 8, 60 iterations and **no restriction operator** — on
   every axis measured here, the worst configuration of those tried. η = 1 and
   period 16 are one-line changes and both were free in PR 326.
3. ~~**Give production the perimeter penalty at C=1.**~~ ★ **WITHDRAWN, by my own
   §5.** I drafted this recommendation before reading the matched-convention
   numbers. −29.6% was measured against a baseline 9× too rough; I do not know
   what it buys at production's volume, and recommending a change to shipped code
   on that basis would be exactly the cross-convention error §5 is about.
   Reinstate it, or drop it, on the result of item 1.
4. **A filter that knows about the CAD boundary** (P4) — the only way Candidate A
   gets a fair test at r ≥ 2.
5. **Sweep the robust triple's threshold offset.** It ran at one value (0.15) and
   matched the penalty on triangle count; it may have a better point, though at
   3× the compute it has to win by a lot.

## 8. IN PLAIN LANGUAGE

**The idea was sound and it lost.** The old method keeps its interiors tidy with
a *filter* — it blurs the material field slightly each step, which quietly makes
tiny fiddly features not worth building. I built that filter, faithfully, from
the paper that put it on a level set at sixty million elements. It works, it is
cheap, and **the crude alternative we already had beats it on every measure**:
more surface removed, less strength given up, and a shape closer to the CAD
drawing.

Two more mechanisms were built and both lost too — one matched the crude method
but cost three times the computing, and one made the surface *worse*.

★★ **And then it turned out the problem was barely there.** Our method and the
old one both report "68% full" and they mean different things. When I finally
compared them at the *same amount of material* — using a measurement that was
already sitting on disk, from work that landed while I was busy — the extra
interior surface is **20% more, not three times more**. Everything in this task
was aimed at a gap five times bigger than the real one.

**So the honest bottom line is that I cannot recommend any of this to production
yet.** The mechanism that won here won by a large margin *against a bad
baseline*. Whether it wins anything at all against the real one is a one-hour
experiment I have not run, and I would rather hand you that sentence than a
recommendation I would have to withdraw.

**Three mistakes of mine are in here, in full.** I invented a scaling for one
mechanism, destroyed three runs with it, and only found out by reading the paper
I had been told to read. I told the reviewer a document did not exist when it did
— it was on the main branch, which my copy did not have. And that same document
contained the number that reframes this entire task; **it had been on disk for a
day before I opened it.**
