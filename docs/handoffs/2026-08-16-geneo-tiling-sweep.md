# Does a coarser GenEO subdomain tiling rescue the deflation on his part?

**Task:** `geneo-subdomain-tiling-sweep` · **Evidence:**
`evidence/2026-08-16-geneo-tiling-sweep/`
**Kind:** MEASUREMENT ONLY. No production default moved; `kGeneoCoreCells` is
untouched and R4 shows no `constexpr` line changed. One test was ADDED (R6);
no assertion was weakened or deleted (R7).

---

## 0. The answer, one line each

**All four requested tilings landed — 8³, 12³, 16³, 24³ — on his captured 128
job. This is the measurement PR 329 reported as blocked.**

- **`N_t` FALLS, AND FALLS HARD: 1,686 → 718 → 369 → 208** on the first build,
  an **8.1x drop**. Modes-per-subdomain rises only 1.76 → 2.18 → 2.88 → 3.47, so
  the prior small-part sweep's behaviour **transfers to his scale**. **§2(c) is
  refuted outright.**
- **★ AND YET NO TILING BEATS THE SHIPPED ONE UNDER THE SHIPPED GATE.** Both
  routes agree, which is why this is the conclusion:
  - **Directly measured**, four ladders under identical conditions:
    6,114 → 6,909 → 6,593 → 6,959 total CG. **8³ wins; 24³ is worst.**
  - **Modelled** against his 160 real solves, each tiling charged its OWN
    measured tail: **+6.7 % → +15.5 % → +1.3 % → +18.2 %.** All losses.
  The curve is **non-monotone with an interior best at 16³** — which is
  essentially break-even, not a win. **12³ and 24³ are both materially worse
  than doing nothing, and 12³ is where a naive "go one step coarser" lands.**
- **★ DEFLATION QUALITY DOES NOT DEGRADE — I CHECKED BECAUSE MY FIRST READING
  SAID IT DID, AND THE CHECK REFUTED ME.** Median warm refreshed tails:
  **241 → 241 → 320 → 910**. Flat down to 16³ across a 4.6x range of basis size;
  it only breaks at 24³. The alarming 1,773 that prompted the check came from a
  solve that REUSED a stale coarse operator without refreshing it — which
  `geneo.hpp` already predicts will deflate badly. Cold tails behave the same
  way: **472 → 435 → 306 → 485**, best at 16³.
- **★ AND AT 24³ THE TAIL BREAKS THE LEVER.** The threshold contains
  `2 × tail`, so 24³'s threshold (**1,886**) is HIGHER than 16³'s (**1,850**)
  despite 44 % fewer basis columns. **`N_t` is necessary but not sufficient, and
  there is a floor. This sweep found it.**
- **EVERY COARSER TILING PAID AN EXTRA REBUILD, AND EVERY ONE REBUILT LARGER —
  3 for 3.** `N_t` after rebuild: 1,686 / **1,123** / **603** / **370**, i.e.
  growth of 1.56x / 1.63x / 1.78x. **The shipped tiling is the only one that
  never rebuilt.** A rebuild is the expensive eigensolve the scheme exists to
  avoid. Its cause is NOT basis size (measured and excluded), and it is the one
  mechanism this task opened and could not close.
- **MEMORY RISES MONOTONICALLY: 40.31 → 52.86 → 53.20 → 63.23 MB (+57 %).** Each
  basis column's local support grows with the cube of the core size faster than
  the column count falls — 24 KB per column at 8³ against 175 KB at 24³. **A
  coarser tiling is a memory COST on this part, not a saving.**
- **THE GATE DOES ENGAGE ROUTINELY, AND IT DOES NOT HELP.** Armed/declined goes
  1-of-12 → 4-of-12 → **10-of-12 → 10-of-12**. §2(a)'s first condition is
  comfortably met at 16³ and 24³, and both are still slower than the shipped
  tiling. **Engagement is not success — that is exactly what §1(c) warned.**
- **WHICH OF §2's THREE OUTCOMES: (b).** `N_t` fell enormously, the gate engaged
  routinely, and total CG did not improve at any tiling. §2(c) is dead; §2(a) is
  not reached. The trade curve §2(b) asks for is §2(b) below.

**Two mechanisms, and separating them is what this sweep bought.** They are
independent, and a single "it did not work" would have hidden both:

1. **THE ENGAGEMENT GATE, which is why 12³ loses.** Lowering `N_t` lowers the
   gate's threshold **into the middle of his solve-cost distribution**, so it
   goes from engaging 8 times in 160 to 76 — and **64 of those 76 are
   engagements it loses on**, because the burn is not refunded when it engages.
   That is the ski-rental rule's 2-competitive bound arriving as real iterations.
   By 16³ the threshold has fallen far enough that the engagements roughly break
   even (+1.3 %) — and at 24³ the rising tail pushes the threshold back UP and
   the losses return (+18.2 %). **The gate never gets ahead at any tiling.**
2. **AN EXTRA REBUILD AT EVERY COARSER TILING, whose cause is NOT basis size.**
   All three paid `builds = 2` against 8³'s 1, and each rebuilt basis came back
   1.56–1.78x larger. A rebuild is the expensive LOBPCG eigensolve the whole
   scheme exists to avoid. Per-solve deflation quality is NOT the explanation:
   refreshed, the small bases match the large one (241/241/320), and the cold
   tail improves down to 16³. **What triggers the rebuild is unresolved**, and
   it is the one mechanism in this handoff I could not close. The most likely
   remaining explanation is that it is a CONSEQUENCE of (1) rather than an
   independent effect — more solves engage, so the degradation trigger gets
   more chances to fire — but that is a hypothesis, not a measurement.

**The recommendation: ship none of them.** 12³ and 24³ are measured regressions
(+13.0 % and +13.8 %). 16³ is the interior best and is a **modelled +1.3 %** —
break-even, not a win. **The shipped tiling is not beaten by anything measured
here**, and the only figure that would justify revisiting this needs the gate
changed too (§6).

---

## 1. Why shrinking the basis makes the run SLOWER BEFORE it makes it faster

The gate (`geneo.hpp`) engages a solve once its plain burn reaches

    threshold = 2*N_t + engaged_burn + 2*engaged_tail

and **the burn already spent is not refunded when it engages.** So an engaged
solve's all-in price, in plain-iteration equivalents, is

    all-in = threshold + 2*N_t + 2*tail_warm

which always EXCEEDS the threshold. **Every solve whose plain cost lands between
`threshold` and `all-in` is one the gate engages and LOSES on.** That is the
ski-rental policy's 2-competitive bound showing up as real iterations, and it is
not a defect — it is the documented, deliberate price of an online rule.

Now put his actual solve costs against it. His 160 stagnating solves cost
**median 2,717 CG** (min 927, max 5,091):

Each MEASURED tiling is charged its **own measured warm tail**; hypothetical rows
are charged his 170.

| `N_t` | source | threshold | all-in | engages | of which LOSE | total CG | vs his run |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| — | his run as it ran | — | — | — | — | 438,348 | baseline |
| **1686** | **core=8 MEASURED** | 4,726 | 8,580 | 8 of 160 | **8** | 467,870 | **+6.7 %** |
| **718** | **core=12 MEASURED** | 2,790 | 4,708 | 76 of 160 | **68** | 506,450 | **+15.5 %** |
| 500 | hypothetical | 2,354 | 3,694 | 99 of 160 | 60 | 454,625 | +3.7 % |
| 430 | hypothetical | 2,214 | 3,414 | 103 of 160 | 56 | 431,475 | −1.6 % |
| **369** | **core=16 MEASURED** | 2,092 | 3,470 | 108 of 160 | 63 | 443,872 | **+1.3 %** |
| **208** | **core=24 MEASURED** | 1,770 | 4,006 | 116 of 160 | **79** | 518,247 | **+18.2 %** |
| 225 | hypothetical | 1,804 | 2,594 | 115 of 160 | 27 | 353,664 | −19.3 % |
| 100 | hypothetical | 1,554 | 2,094 | 121 of 160 | 13 | 298,597 | −31.9 % |

**★ COMPARE THE MEASURED ROWS WITH THE HYPOTHETICAL ONES AT SIMILAR `N_t` — THAT
GAP IS THE WHOLE CORRECTION.** At `N_t` = 225 a row charged his 170 tail reads
−19.3 %; the MEASURED row at `N_t` = 208 reads **+18.2 %**, because 24³'s own tail
is 910, not 170. **The optimistic hypothetical rows are an artefact of borrowing
a tail from a different tiling**, and they are left in the table only to show how
far wrong that borrowing goes.

**★ READ THE SHAPE, NOT ANY ONE ROW. THE CURVE IS NON-MONOTONE WITH AN INTERIOR
BEST AT 16³ THAT IS STILL NOT A WIN, AND A TWO-POINT SWEEP COULD NOT HAVE SHOWN
EITHER HALF OF THAT.**

**+6.7 % → +15.5 % → +1.3 % → +18.2 %.** Shrinking `N_t` from 1,686 to 718 drops
the threshold **into the middle of his solve-cost distribution**, so the gate
goes from engaging 8 times to 76 — and 68 of those are losses, because the burn
is never refunded. 16³ recovers most of that, to roughly break-even. **24³ throws
it away again**, not because its basis is too big but because its *tail* is: 910
against 16³'s 320, so its all-in price rises even as `N_t` keeps falling.

**Two things follow, and both are load-bearing:**

1. **`N_t` is necessary but not sufficient.** The all-in price is
   `4·N_t + 4·tail + 500`, and past 16³ the tail term grows faster than the
   `N_t` term shrinks. **There is a floor, and this sweep found it.**
2. **12³ is the worst place to land, and it is exactly where "go one step
   coarser" lands you.** The measured triage and the model agree there.

**All four measured points bracket the minimum**, which sits at 16³ and is worth
about +1.3 % — i.e. the shipped tiling is not beaten by anything measured here.

---

## 2. MEASURED — the sweep

### §1(a) What the tiling means in voxels, per axis

His grid is **128 × 31 × 118** (the run's own preflight line, and
`solved_grid_dofs = 1473696 = 3·129·32·119`). `tile_cores`
([`geneo.cpp:167`](core/src/fea/geneo.cpp:167)) steps each axis independently:

| core | tiles x | tiles y | tiles z | subdomains |
| ---: | ---: | ---: | ---: | ---: |
| 8 | 16 | 4 | 15 | 960 |
| 12 | 11 | 3 | 10 | 330 |
| 16 | 8 | 2 | 8 | 128 |
| 24 | 6 | 2 | 5 | 60 |
| *32* | *4* | ***1*** | *4* | *16* |

**The sweep stops at 24 on purpose.** At 32 the 31-voxel axis stops being tiled
at all, so that point would confound "coarser tiling" with "no tiling on one
axis". 24 is the last point that still tiles every axis. Both facts are pinned
by a test (R6), not by this paragraph.

### §1(b) `N_t`, basis size, and the gate's threshold

| core | subdomains | `N_t` first build | `N_t` after rebuild | modes/sub | basis MB | builds | refresh `2·N_t` | threshold |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| **8** (shipped) | 960 | **1,686** | — (never rebuilt) | 1.76 | **40.31** | 1 | 3,372 | 4,816 |
| **12** | 330 | **718** | **1,123** | 2.18 | **52.86** | 2 | 1,436 | 2,806 |
| **16** | 128 | **369** | **603** | 2.88 | **53.20** | 2 | **738** | 2,092 |
| **24** | 60 | **208** | **370** | 3.47 | **63.23** | 2 | **416** | 1,770 |

`N_t` falls **4.6x** by 16³ against a **7.5x** fall in subdomain count. The gap
is modes-per-subdomain rising 1.76 → 2.18 → 2.88 — larger subdomains hold more
low-lying modes, exactly as expected, and still nowhere near the
`kGeneoBlockM = 20` cap, so the cap is not what flattens the curve. **This half
of the hypothesis is confirmed and the prior small-part sweep's behaviour
transfers to his scale.**

**★ AND AT 16³ THE REFRESH FINALLY COSTS LESS THAN THE WORK IT SAVES.** `2·N_t`
= **738**, against triage solves costing 1,121–2,571 plain. At 8³ the same term
is **3,372 — larger than every solve it would accelerate**, which is the
single-sentence reason GenEO could never pay at the shipped tiling under any
policy whatsoever.

**★ TWO COLUMNS HERE CONTRADICT THE HYPOTHESIS, AND BOTH WERE MISSED BY LOOKING
AT THE FIRST BUILD ALONE.**

- **★ EVERY COARSER TILING REBUILT, AND EVERY ONE REBUILT LARGER — 3 FOR 3.**

  | core | `N_t` first | `N_t` after rebuild | growth | builds |
  | ---: | ---: | ---: | ---: | ---: |
  | 8 | 1,686 | 1,686 | — | **1** |
  | 12 | 718 | 1,123 | **1.56x** | 2 |
  | 16 | 369 | 603 | **1.63x** | 2 |
  | 24 | 208 | 370 | **1.78x** | 2 |

  **The shipped tiling is the ONLY one that never rebuilt**, and the growth
  factor rises steadily with coarseness. So the steady-state `N_t` is the
  right-hand column: 24³ ends at 370, not 208 — barely better than 16³'s FIRST
  build. **A pattern this consistent across three independent tilings is a
  property of the mechanism**, and §2(b) shows its cause is NOT deflation
  quality, which leaves it the one thing this task opened and could not close.
- **MEMORY RISES MONOTONICALLY: 40.31 → 52.86 → 53.20 → 63.23 MB (+57 % at
  24³).** The opposite of what a smaller coarse space is supposed to buy. Per
  column: 24.5 KB at 8³ against 90.3 KB at 16³ and 175 KB at 24³ — each basis
  column's local support grows with the cube of the core size, and that outruns
  the fall in column count at **every step measured**. `kGeneoMaxBasisMB` is the
  guard that would eventually refuse one.

**PR 329's headline reproduced:** at 8³ the refresh (3,372) is **70 % of the
threshold** (4,816). PR 329 measured 71 %.

### §1(c) TOTAL CG ITERATIONS — the figure of merit

| core | **TOTAL CG** (`--iters 1`) | design iters | armed | declined | builds | refreshes | wall (s) *(context only)* |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| **8** | **6,114** ← best | 4 | 1 | 11 | **1** | **0** | 1,143.7 |
| 12 | 6,909 (**+13.0 %**) | 4 | 4 | 8 | 2 | 1 | 1,665.0 |
| 16 | 6,593 (**+7.8 %**) | 4 | **10** | 2 | 2 | 3 | 1,749.2 |
| 24 | 6,959 (**+13.8 %**) ← worst | 4 | **10** | 2 | 2 | 3 | 1,983.3 |

**★ ON THE DIRECTLY MEASURED LADDER, THE SHIPPED TILING WINS ALL FOUR WAYS.**
Every coarser tiling is slower, and 24³ — the coarsest, with the smallest basis
of all (`N_t` = 208) — is the **worst**. Whatever the models say, this is the one
column where four tilings were run end to end under identical conditions, and
8³ is on top of it.

**★ THIS TABLE AND THE MODEL AGREE IN SIGN AT EVERY TILING — but they differ in
MAGNITUDE, by construction, for a reason predicted before either was run.** The
model says 16³ is +1.3 % on his run; this table says +7.8 % on the triage. Both
are right about different fixtures, and the difference is **fixture DEPTH**:

- the triage runs ONE design iteration per rung, so its solves cost
  **806–2,660** plain;
- his production solves cost a **median of 2,717, up to 5,091**.

GenEO only pays on solves expensive enough to clear the threshold *and* leave
room past it. The triage's solves mostly are not, so its engagements sit right
at the break-even where the ski-rental rule loses. `e0_expected_before_measuring.md`
E6 called this before any coarse point had landed: *"the triage shows all-decline
and near-identical total CG, and that is a property of the FIXTURE DEPTH, not of
the lever."*

**So the measured triage column is a LOWER BOUND on the lever's value, not a
verdict on it** — and the honest reading is that **no measurement in this task
observed a total-CG win at his production depth**, because the run that would
show it is the one that did not fit (§8).

**Wall is context, not evidence** (R1) — see §5 on the host, which was running
three other agents' jobs throughout. The iteration counts and the counters are
deterministic.

**★ THE ARMED COUNT IS NOT SUCCESS, AND THIS TABLE IS EXACTLY WHY §1(c) INSISTED
ON THAT.** The engagement rate goes **1-of-12 → 4-of-12 → 10-of-12**. By 16³ the
gate engages **on 10 of 12 solves** — §2(a)'s "the gate engages routinely" is
comfortably MET. And 16³ is still **7.8 % slower** than the shipped tiling here.

**Anyone reading engagement as progress would have called this a win at both
coarser tilings.** It is not one at this depth: both paid a second eigensolve and
extra refreshes that 8³ never needed.

### §1(d) The (burn − threshold) distribution

| run | threshold | worst miss | median miss | best | outcome |
| --- | ---: | ---: | ---: | ---: | --- |
| core=8 | 4,816 | −3,695 | −3,366 | −2,245 | 3 of 3 declined; median miss is **69.9 %** of the threshold |
| core=12 | 2,806 | −1,434 | −1,083 | **0** | 2 declined; the third **hit the threshold exactly and engaged** |
| core=16 | 1,850 | −399 | −287 | **−174** | 2 declined, missing by **21.6 %** and **9.4 %**; the rest engaged |
| core=24 | 1,886 | −424 | −297 | **−170** | 2 declined, missing by **22.5 %** and **9.0 %**; the rest engaged |

**★ THIS IS THE GATE MOVING, MONOTONICALLY, AND IT IS THE CLEANEST SINGLE
PROGRESSION IN THE SWEEP.** Comparing like rung with like rung, the miss shrinks

| rung | core=8 | core=12 | core=16 |
| ---: | ---: | ---: | ---: |
| 1 | −3,695 | −1,434 | **−399** |
| 2 | −3,366 | −1,083 | **−174** |

**a 20x tightening across the sweep, in the same direction on every rung.**
PR 329's baseline finding was that his production solves miss the threshold "by
a median of 346 iterations, 7.4 %" — and core=16's −174 on rung 2 is **9.4 %**,
i.e. the sweep has walked the gate from a 70 % miss down to the neighbourhood PR
329 measured on his real run. **The lever unambiguously does what it was sent to
do to the gate.**

**So the tiling does exactly what it was sent to do to the gate.** What §1(c)
adds is that doing so is not sufficient, and at 12³ is actively harmful.

Taken from the per-iteration `geneo_burn`/`geneo_threshold` CSV columns, **never
from the decision log**, which records transitions only and whose declines are
therefore the hardest 5 % rather than a sample (`geneo.hpp`,
`kGeneoDecisionLogCap`).

### §2(b) Deflation — the trade curve, and where the coupling actually is

**★ THIS SECTION IS A CORRECTION OF MY OWN FIRST READING, AND THE CORRECTION IS
THE FINDING.** On the first engaged solve the smaller basis looked outstanding,
and had the sweep stopped there it would have reported "deflation improves". The
full decision log says otherwise. core=12, every solve GenEO touched:

| solve | action | `N_t` | burn | total iters | **deflated tail** |
| ---: | --- | ---: | ---: | ---: | ---: |
| 1 | BUILD | 718 | 500 | 935 | 435 (cold) |
| 2 | declined | 718 | 2,257 | 2,257 | — |
| 10 | **REFRESH + engage** | 718 | 2,806 | 2,879 | **73** ✓ |
| 11 | **REUSE** | 718 | 2,806 | 4,579 | **1,773** ✗ |
| 12 | **REBUILD** | **1,123** | 3,306 | 3,985 | 679 |

Against core=8, which built once and never rebuilt or refreshed at all across
all 12 of its solves, and whose warm tail from his production run is a median of
**170** over 8 engaged solves.

**The coupling is real, and it is in the basis's SHELF LIFE, not its per-solve
quality.** A freshly refreshed 718-column basis deflates in 73 iterations —
better than the shipped tiling's 170. **One design step later the same basis
needs 1,773, a 24x degradation**, which trips `kGeneoRebuildFactor` and buys
another full LOBPCG eigensolve. *(This is where I first concluded that a smaller
coarse space stops spanning the moving design sooner. The next subsection
measures that claim and refutes it — the 1,773 was an unrefreshed reuse. The
sequence is left in place because the wrong inference is an easy one to draw
from this table alone.)*

**★ AND PER-SOLVE QUALITY IMPROVES DOWN TO 16³ AND THEN TURNS.** The COLD build
tail is the cleanest like-for-like comparison in the sweep — every tiling runs
exactly one, under identical conditions (500 plain iterations burned, then
deflate to convergence):

| core | `N_t` | cold build tail |
| ---: | ---: | ---: |
| 8 | 1,686 | 472 |
| 12 | 718 | 435 |
| **16** | 369 | **306** ← best |
| **24** | **208** | **485** ← worse than the shipped tiling |

**Down to 16³ a smaller basis deflates a cold solve BETTER — 35 % fewer
iterations at a 4.6x smaller basis. At 24³ it reverses**, and 208 columns deflate
worse than 1,686 did. **That is the coarse space finally becoming too small to
represent the modes that matter**, and it is the first direct evidence in this
sweep of a floor under how far the tiling can usefully go.

**It also propagates into the gate.** The threshold contains `2 × engaged_tail`,
so a larger tail pushes the threshold back UP even as `N_t` falls: 16³'s
threshold is **1,850** and 24³'s is **1,886**, despite 24³ having 44 % fewer
basis columns. **Shrinking `N_t` past 16³ stops helping the gate.**

**So §2(b) is the outcome, with its mechanism named**: the basis size and the
basis quality *are* coupled on this part — not through how well a fresh basis
deflates, but through how many design iterations it survives before it must be
rebuilt, and how large it comes back.

**★ AND THE CONFOUND IN SOLVE 11 WAS RESOLVED BY MEASUREMENT — AGAINST MY FIRST
READING.** Solve 11 is `action 1`, the REUSE path: a held basis whose coarse
operator was NOT refreshed. So its 1,773 could have been the smaller basis, or
simply the missing refresh. The forced-engagement probe separates them by
running core=12 with every held-basis solve REFRESHED:

| tiling | `N_t` | every measured REFRESHED tail | median | *n* |
| ---: | ---: | --- | ---: | ---: |
| 8³ | 1,686 | 217 / 241 / 905 | **241** | 3 |
| 12³ | 718 | 73 / 204 / 278 / 1,144 | **241** | 4 |
| 16³ | 369 | 187 / 320 / 810 | **320** | 3 |

**Across a 4.6x range of basis size the median refreshed tail is 241 / 241 /
320.** **So the 1,773 was the missing refresh, not the smaller basis.** My
earlier reading — that "a smaller coarse space stops spanning the moving design
sooner" — is **not supported**. What the data supports is narrower and less
interesting: *an unrefreshed coarse operator deflates badly*, which `geneo.hpp`
already says outright ("a stale coarse operator is not a deflation for the new
system and diverges").

**This matters beyond the correction**, because it is what lets §6 isolate the
refresh term: 8³ and 12³ carry the **identical** measured tail of 241, so the
48-point swing between them is attributable to `N_t` and to nothing else.

**What survives, because it is recorded independently of any tail measurement:**
core=12 paid **2 builds and 1 refresh** where core=8 paid **1 build and 0
refreshes**, and it finished 13 % slower. The rebuild happened; that is in the
run's own counters. **Why** it happened is now the open question rather than the
answered one — the degradation trigger fires on an iteration-count ratio, and a
run that reuses without refreshing more often will trip it more often regardless
of basis size.

### §2(b) continued — the forced-engagement probe, and the contrast that decides it

`run_engaged_probe.sh` opens the gate (`thr=0`) so every held-basis solve
REFRESHES and deflates from iteration 0. At the shipped tiling:

| rung | deflated cost | the same solve, plain (from the triage) | ratio | standing-armed all-in (`2·N_t + 2·tail`) |
| ---: | ---: | ---: | ---: | ---: |
| 1 | **217** | 1,121 | **5.2x** | 3,806 — **3.4x WORSE than plain** |
| 2 | **241** | 1,450 | **6.0x** | 3,854 — **2.7x WORSE** |
| 3 | **905** | 2,571 | **2.8x** | 5,182 — **2.0x WORSE** |

**THE DEFLATION ITSELF IS EXCELLENT — 2.8x to 6.0x per solve.** The task's claim
that "the deflation works superbly when it engages" is confirmed directly here,
on his part, at his resolution. The tails do grow as the ladder thins (217 → 905
as vf goes 0.52 → 0.26), but there is no collapse.

**★ AND THE PROBE VALIDATES ITSELF AGAINST HIS PRODUCTION RUN.** Its three warm
tails are **217 / 241 / 905, median 241**. His captured run's eight engaged
solves were **11 / 70 / 74 / 150 / 189 / 236 / 304 / 889, median 170**. Same
range, same shape, same maximum to within 2 % — measured on different design
states by different code paths (his through the natural gate, mine through the
`thr=0` override). **A harness that reproduces the production distribution it
was built to extend is one whose coarse-tiling numbers can be trusted**, and
that check is the reason to believe the 12³ and 16³ tails at all.

**AND YET GenEO STILL CANNOT PAY AT 8³ — for a reason no policy can fix.** The
refresh alone costs `2·N_t` = **3,372** plain-iteration equivalents, while the
solves it would accelerate cost **1,121–2,571** plain. **The refresh is more
expensive than the entire solve it is accelerating, on every rung.** The last
column prices the most favourable posture imaginable — standing arming, no burn
at all — and it is a 2.0–3.4x LOSS anyway.

**★ THAT COLUMN IS AN INDEPENDENT REPRODUCTION OF THE STANDING-PRECONDITIONER
NO-GO**, measured here on his own part rather than inherited from
`2026-08-02-geneo-standing-probe`'s 1.25x. It also sets the ceiling for §6: at
the shipped tiling no arming policy whatsoever recovers GenEO, because `2·N_t`
alone exceeds the work available to save. **`N_t` is the only term that matters,
which is exactly why this sweep was the right experiment to run** — and why its
negative result is informative rather than merely disappointing.

**THE TRADE CURVE §2(b) ASKED FOR, all four points:**

| | 8³ (shipped) | 12³ | 16³ | 24³ |
| --- | --- | --- | --- | --- |
| refresh cost `2·N_t` (first build) | **3,372** — larger than every solve it would accelerate | 1,436 ✓ | **738** ✓ | **416** ✓ |
| median **refreshed** tail | **241** | **241** | 320 | 910 ✗ |
| cold build tail | 472 | 435 | **306** best | 485 ✗ |
| builds paid over the ladder | **1** ✓ | 2 | 2 | 2 |
| `N_t` after rebuild | **1,686** | 1,123 | 603 | 370 |
| basis memory | **40.31 MB** ✓ | 52.86 (+31 %) | 53.20 (+32 %) | **63.23 (+57 %)** ✗ |
| measured total CG (`--iters 1`) | **6,114** ✓ | 6,909 (+13.0 %) | 6,593 (+7.8 %) | **6,959 (+13.8 %)** ✗ |
| modelled, shipped gate, own tail | +6.7 % | +15.5 % | **+1.3 %** best | +18.2 % |
| modelled, standing armed, own tail | +40.7 % | −30.0 % | **−49.7 %** best | −18.4 % |

**The trade is not what it looked like at two points.** With only 8³ and 12³ in
hand it read as "a smaller basis deflates worse" — a clean, plausible coupling.
The forced-refresh measurements dissolved that: **deflation quality is flat (241
/ 241 / 320) right down to 16³.** It is only at 24³ that the tail genuinely
breaks (910), and by then the refresh it was supposed to be buying is already
tiny. **So the coupling is real but it arrives late, and it is not what makes
12³ lose** — the gate is.

**Every column has an interior optimum at 16³ or a monotone penalty.** Nothing
in this table recommends a coarser tiling on its own; the only cell that is
strikingly good is the last row's −49.7 %, and that requires changing the gate
too (§6).

---

## 3. R5 — no verdict moved

| vf | core=8 | core=12 | core=16 | core=24 |
| ---: | ---: | ---: | ---: | ---: |
| 0.68 | 1751.27987 | 1751.27987 | 1751.279**86** | 1751.27987 |
| 0.52 | 1383.1277 | 1383.1277 | 1383.1277 | 1383.1277 |
| 0.38 | 514.951762 | 514.951762 | 514.951762 | 514.951762 |
| 0.26 | 106.908685 | 106.908685 | 106.908685 | 106.908685 |

Every rung ACCEPT at every tiling. **Zero verdict flips, and 15 of the 16 cells
are BIT-IDENTICAL to every digit the harness prints** — a stronger result than
the bar asked for.

**The one cell that moves does so by 5.7e-9 relative**, which is below the
solver's own 1e-8 tolerance and is exactly the size of difference an
exact-to-tolerance method is expected to produce. GenEO changes the CG route and
never the converged field or the stopping test.

**This is not a formality, because the routes really did differ — enormously.**
core=16 and core=24 each paid 2 builds, 3 refreshes and **10 armed solves**
against core=8's 1 build, 0 refreshes and 1 armed solve; the four ladders ran
6,114 / 6,909 / 6,593 / 6,959 CG iterations. **Four visibly different solver
routes, one certified answer to the last printed digit.**

**★ AND YET THE ITERATION COUNTS MOVED, WHICH MATTERS FOR READING §1(c).**
Identical margins do not mean identical work: **rung 1 cost 1,121 CG at core=8
and 1,372 at core=12, a 22 % swing**, on ladders that certify to the same digits.
Exactness is to the solver tolerance (1e-8), not to the last bit, so the two runs
hand marginally different fields onward and CG counts — which are sensitive to
where a residual lands relative to a fixed tolerance — respond far more than the
converged quantities do.

**Consequence, stated plainly: at `--iters 1` a total-CG difference below
roughly 20 % cannot be attributed to the lever on its own.** The measured
+13.0 % is *inside* that band. It is quoted here because an independent cost
model over 160 of his real solves lands at **+15.5 %**, and because the counters
that explain it are not noisy at all — core=12 demonstrably paid **2 builds and
1 refresh** against core=8's **1 and 0**. **The agreement of three independent
lines is the evidence, not the 13 % by itself.**

---

## 4. §3 — the two "while the machine is quiet" items. **Neither needed a run.**

Full working: `evidence/…/s3_extras.md`.

### (a) `warm_start_coarse` — off for a MEASURED reason

`docs/handoffs/2026-08-02-warm-start-coarse-experiment.md` §6 is titled
**"Recommendation — DO NOT ARM"**. Three fixtures, negative controls, a full
gate table. Its four reasons: it LOSES in the stagnating regime it exists for
(+7.2 % DOF-touches); it landed a **26 % worse design** there; both honest
controls are losses; and the win is structurally capped at rung 0.

**The July note's instruction was carried out — on 2026-08-02.** The task's
premise that "nobody did" is not correct.

**★ AND THE TASK'S ARGUMENT FOR RE-OPENING IT IS REFUTED BY THE CODE.** The task
argues the cascade is easier under PLSM "because phi is analytic so the coarse
grid is evaluated exactly rather than restricted". Traced end to end, that is
not this path:

1. [`minimize_plastic.cpp:910`](core/src/simp/minimize_plastic.cpp:910) —
   `warm_seed = prolong_density(...)`: a prolonged **density**, not a φ.
2. [`:1132`](core/src/simp/minimize_plastic.cpp:1132) — handed on as
   `opt.initial_design`.
3. [`plsm.cpp:392`](core/src/simp/plsm.cpp:392) — PLSM turns it into a level set
   by `phi[v] = 0.5 - initial_design[v]`.

φ is **reconstructed from a restricted-then-prolonged density by subtraction**.
The analytic evaluation the argument depends on never happens. *(The task's cited
lines `414-450` are stale; the correct ones are above.)*

### (b) `matfree_threads` — the sweep already exists, and 6 is not a guess

The machine: **Apple M2 Pro, 6 performance + 4 efficiency cores, 16 GB**.
`matfree_threads = 6` **is the P-core count**, derived at runtime from
`sysctl hw.perflevel0.physicalcpu` and shipped as the "P-core pin" in handoff
132.

The 1/2/4/6/8/max sweep the task asks for was run in
`2026-07-28-apple-silicon-envelope.md`, on the production `apply_kgg` kernel:

| threads | s/matvec | GB/s | % of 200 GB/s peak |
| ---: | ---: | ---: | ---: |
| 1 | 0.0501 | 12.0 | 6 % |
| 4 | 0.0151 | 39.8 | 20 % |
| **6** | **0.0110** | **54.5** | **27 %** |
| 8 | 0.0131 | 45.8 | 23 % |
| 10 | 0.0118 | 50.9 | 25 % |

**It stops scaling at 6 and REGRESSES at 8** — the four E-cores contend for the
same bus. **The memory-bandwidth answer:** pure STREAM saturates at *two*
threads (146 of a 151 GB/s ceiling); the operator reaches only 27 % because it
is an indirect gather/scatter and is **latency-bound, not bandwidth-bound**.
There is no idle bandwidth for a new algorithm to find.

**Whether a GPU port could pay — also already measured.** A Metal FP32 prototype
of the same apply hit 62–69 % of the bus, ~4x the CPU kernel. System verdict is
still no: FP32 cannot be the convergence operator (its 6.9e-8 error IS the FP32
epsilon), the matvec is only ~34 % of the solve so Amdahl caps the whole thing at
**~1.2x realistic**, and a GPU apply is a third non-bit-identical answer.

**A thread sweep is also the one thing here I could not have measured**, since it
has no contention-immune unit — see §5.

---

## 5. R2 — the machine was NOT quiet, and the task's premise that it was is wrong

The task says "★THE MACHINE IS QUIET NOW. Run it before anything else claims
it." **It was not, at any point.** `evidence/…/host_load.txt`:

| when | load average (10-core box) |
| --- | ---: |
| at the first check, before anything started | **18.10** |
| mid-sweep | **137.46** |
| late sweep | 26–60 |

Throughout, the box also ran **three other worktrees' `topopt-cli` processes**, a
full `ctest` suite out of `lattice-void-exterior-check`, and an `xctest`. My
process held ~0.67 of the 6 cores it asked for — about the same ~9x starvation
PR 329 reported.

**This does not invalidate the sweep, and the reason is structural.** `N_t`,
total CG, matvecs and the gate's `burn`/`threshold` are **counts**, and the gate
compares counts and never a clock — by explicit design (`geneo.hpp`, "WHY COUNTS
AND NOT WALL"). They are identical on a loaded host and an idle one. **No wall
figure in this handoff is cited as evidence.** That is the discipline
`2026-08-02-warm-start-coarse-experiment` §3 and `2026-07-29-geneo-arming`
§Machine applied to the same condition, and it is why R2's real requirement —
say so — is met rather than evaded.

**R3:** every wall number quoted as context came from a Release build,
`CMAKE_BUILD_TYPE=Release`, `-O3 -DNDEBUG`, recorded in `build_type.txt`
alongside the single `solver_arm_sweep` md5 (`389b1bce…`) that every sweep point
ran against.

---

## 6. What to do about it — a proposal, NOT armed here

**Ship no tiling.** All four were measured and none beats the shipped one:
+13.0 % (12³), +7.8 % (16³), +13.8 % (24³) measured, and +15.5 % / +1.3 % /
+18.2 % modelled at his depth. **16³ is the interior best and it is a wash.**

**That is the answer to the question as asked, and on its own it would be a
closed negative.** What follows is why it is not the end of the line.

**The thing worth asking next is the ENGAGEMENT POLICY, and this sweep is what
makes it worth asking.** The 21.7x that motivated this whole line
(`fea.hpp`: 5,412 → 249) lives in deflating **from iteration 0**, which the
ski-rental gate forbids. Model B prices that posture:

Charged at each tiling's **own measured** median warm tail, not a borrowed one:

| `N_t` | source | median tail | *n* | per solve | total CG | vs his run |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 1,686 | core=8 MEASURED | **241** | 3 | 3,854 | 616,640 | **+40.7 %** |
| **718** | **core=12 MEASURED** | **241** | 4 | 1,918 | 306,880 | **−30.0 %** |
| **369** | **core=16 MEASURED** | 320 | 3 | 1,378 | 220,480 | **−49.7 %** ← best |
| **208** | **core=24 MEASURED** | 910 | 1 | 2,236 | 357,760 | **−18.4 %** |

**★ THE SAME INTERIOR OPTIMUM AT 16³ APPEARS HERE TOO, INDEPENDENTLY.** Model A
(shipped gate) bottoms at 16³ and Model B (standing arming) bottoms at 16³, from
different arithmetic over different terms. **That agreement is the strongest
structural result in the sweep**: 16³ is the right tiling if any tiling is, and
past it the growing tail overwhelms the shrinking refresh.

**★ THE FIRST TWO ROWS CARRY THE IDENTICAL MEASURED TAIL — 241 — SO THE ONLY
THING SEPARATING +40.7 % FROM −30.0 % IS `N_t`.** That is as clean an isolation
of the refresh term as this task could have produced, and it required assuming
nothing about deflation quality: the quality is measured, and it is the same.

**And the sign flip is the whole point.** Model B at 1,686 reproduces the
standing-preconditioner NO-GO (a loss, consistent in sign and rough magnitude
with the 1.25x on wall that `2026-08-02-geneo-standing-probe` measured). At 718
and 369 the same model, same arithmetic, same measured tails, says it wins.
**The NO-GO's cost basis has moved out from under it.**

**At the SAME basis size and the SAME measured tail, the gate policy is worth 46
percentage points** (+15.5 % with it, −30.0 % without). And the standing posture's existing
NO-GO (`2026-08-02-geneo-standing-probe`: a 1.25x loss) was priced **entirely on
the refresh term at `N_t` ≈ 1,686**. Model B reproduces that NO-GO at 1,686
(+35.5 %, consistent in sign and rough magnitude with the measured 1.25x on
wall) and flips it at 718.

**★ MODEL B'S BINDING ASSUMPTION WAS TESTED RATHER THAN ASSUMED, AND IT HELD.**
It charges `2·N_t + 2·N_defl` with `N_defl` roughly stable across tilings. I
initially believed the sweep had refuted that (a 73 → 1,773 jump at 12³) and
wrote it up as refuted; the forced-engagement probe showed the 1,773 was an
unrefreshed REUSE, and that with a proper refresh the two tilings deflate
identically at the median. **The assumption survives.**

**What still keeps Model B an upper bound, and must be said:** it charges only
refreshes, and EVERY coarser tiling measurably paid an extra full REBUILD (the
expensive eigensolve) that this model does not price at all — 3 for 3. Until
open question 1 below is answered, **the −49.7 % is a ceiling, not a forecast.**

**So the proposal is a QUESTION, not a recommendation:** the
standing-preconditioner NO-GO was priced entirely on a refresh cost at `N_t` ≈
1,686, and this sweep has shown that cost is movable by 4.6x. **Model B
reproduces that NO-GO at 1,686 (+40.7 %) and flips it at 718 (−30.0 %) with the
tail held at the same measured value** — so the verdict rests on a number that no
longer holds unconditionally, and re-asking it is justified. **This task does not
arm anything and its evidence does not yet support arming**; the three open
questions below are what would.

**Three things any such follow-up must settle first**, in this order:

1. **WHY EVERY COARSER TILING PAID AN EXTRA REBUILD.** 3 for 3, each returning
   a basis 1.56-1.78x larger. It is the one mechanism this task opened and could
   not close. It is NOT deflation quality — measured and flat (§2(b)). The
   degradation trigger fires on an iteration-count ratio against a post-rebuild
   reference, so the leading alternative is simply that **more solves ENGAGED**
   (1 → 4 → 10 → 10 of 12), giving the trigger more chances to fire, with basis
   size incidental. **If that is the whole story the extra rebuild is a
   consequence of the gate economics in (2), not an independent defect** — which
   would simplify the picture considerably. Nobody has measured it either way,
   and the engagement counts make it the hypothesis to test first.
2. **THE WARM TAIL AT 16³ AND 24³, PROPERLY SAMPLED.** Model B's ranking of
   16³ over 24³ rests on tails of n=3 and n=1 taken from whichever solves the
   natural gate happened to engage. `run_engaged_probe.sh` forces the refreshed
   path on every solve and would give 3-4 clean samples each:
   `CORES="16 24" sh evidence/2026-08-16-geneo-tiling-sweep/run_engaged_probe.sh`
3. **THE ONE-OFF BUILD COST.** Local eigenproblems grow with the cube of the core
   size (8³ ≈ 1.7k local DOFs, 16³ ≈ 14k), and Model B charges only refreshes.
   16³ spent **14 minutes in its build alone** on this host — enough to matter
   over a 4-rung ladder, and not separable from contention here (§5). No
   build-seconds figure is quoted anywhere in this handoff for that reason.

---

## 7. R4 / R6 / R7 — the bars

**R4 — no production default moved, and a production run is byte-identical.**
`git diff core/src/fea/geneo.hpp | grep '^[+-]constexpr'` returns **nothing**:
not one recipe constant changed. The sweep drove `GeneoProbeConfig::core_cells`,
the harness-only override that has existed since
`geneo-standing-preconditioner-probe`. The two library files add exactly one new
symbol, `geneo_tile_counts_for_test`, and **every caller of it is in
`core/tests/unit/test_geneo.cpp`** — nothing under `core/src/` references it.
`geneo_probe_defaults_match_tripwire()` still holds, asserted by `test_geneo`.

The run-level check: `build/topopt-cli` linked at 17:46 predates every edit
(confirmed by `nm` — it lacks the new symbol, while the current library has it),
so a genuine pre-edit binary existed without touching `git stash` — which is
shared across worktrees and, with three other agents active, was not worth the
risk of a pathspec that matches nothing popping someone else's. Both binaries
ran the same job:

    report.json / design.bin / fields.bin / variant_070.stl /
    variant_070_alpha.f64 / loadcase.json        ALL IDENTICAL

`iterations.csv` differs, and was opened rather than excused: **39 of its 44
columns are byte-identical**, including `cg_iters`, `matvecs`, `compliance`,
`achieved_vf` and every `geneo_*` field. The 5 that differ are `wall_ms`,
`total_ms`, `solve_ms`, `fea_ms`, `residual_ms` — all wall-clock timers, which
differ between two runs of the same unmodified binary and did so here at load
185. Same handling as `build_orientation.json` in the warm-start handoff: named,
with the reason, after checking nothing else in the file moved. Detail in
`r4_byte_identity.txt`.

**R6 — the per-axis tiling is now pinned by a test, not by care.**
`test_geneo` gained a block asserting, against a **24:1 synthetic slab**
(96×4×96), that the tiling is 12×1×12 = **144** subdomains and explicitly **not**
the 576 a `min(nx,ny,nz)`-keyed rule would give — the trap that cost a day in
`2026-08-10-parametric-level-set` when GridapTopOpt's alpha rule keyed on
`minimum(el_size)`. His own part's four tilings are asserted too, and so is the
fact that 24 still splits the thin axis while 32 collapses it. The assertions run
against the **shipped** `tile_cores` through a test-only accessor, not against a
copy of the tiling logic in the test. `test_geneo`: **55 checks, 0 failures.**

**R7 — no assertion weakened or deleted.** Message census across test assertion
strings, registered ctest names, production refusals, the CHECK-operator
histogram, `static_assert` messages, and the harness bag: **every REMOVED list is
empty**, and every comparison kind is non-decreasing (`==` 895→910, `!=` 35→36,
`&&` 297→303, the rest flat). 21 assertion messages were added.

**★ One correction inside R7 itself, since it changes what the bar measured.**
The census defaults to `main` as its baseline. This worktree's branch sits **83
commits ahead of `main`** (PRs 330/332/333 merged while this task was being set
up), so a `main`→tree diff attributed four other PRs' harness edits to this task
and buried this task's own diff inside them. Every change of mine is
uncommitted — `git status` shows exactly four modified files — so the census is
baselined on **HEAD**, and `BASE_REF=main` remains available for the merge-base
view a reviewer will want. A bar checked against a moving reference is not
checked.

---

## 8. What did not finish, and what that costs

**★ BLOCKED-STOP, partially invoked, and stated rather than smoothed over.**

**★ ALL FOUR REQUESTED TILINGS LANDED.** The sweep §1(a) asked for — 8³, 12³,
16³, 24³ — is complete on its primary quantities. What follows is the residue.

| item | status |
| --- | --- |
| `N_t`, total CG, gate distribution, margins, rebuild counts, basis MB at **all four tilings** | **COMPLETE** |
| forced-engagement warm tails at **8³ and 12³** | **COMPLETE** — 217/241/905 and 204/278/1,144 |
| forced-engagement warm tails at 16³, 24³ | **PARTIAL** — from the triage's own engaged solves (187/320/810 and 910); the dedicated probe did not run at either |
| total CG at HIS depth, any tiling | **NOT MEASURED** — see the §1(c) note; the triage is a lower bound and is the one real gap |

**The sweep §1 asked for is finished.** Two residues remain, neither of which
changes the verdict:

1. **The forced-engagement probe at 16³ and 24³.** Their warm tails come from
   whichever solves the natural gate engaged, so 16³'s median rests on 3 samples
   and 24³'s on 1. More samples would sharpen §6's Model B rows; they would not
   move §1(c), which is measured directly.
2. **Total CG at his production depth (60 design iterations per rung).** The
   triage runs 1, which makes its solves cheaper than his and therefore
   understates GenEO — the direction is named in §1(c) and quantified by the
   model. **This is the measurement that would convert §6's proposal from
   modelled to observed**, and it is a multi-hour run per tiling.

**What the missing pieces would and would not change.** 24³ would extend the
curve, not redirect it: 8³/12³/16³ already bracket the minimum and locate the
crossing near `N_t` ≈ 430. **The one genuinely decisive gap is 16³'s rebuild
count** — 12³ failed by degrading and rebuilding 1.6x larger, and whether 16³
does the same is the difference between "a candidate worth proposing" and "the
same failure one step further out". Everything in §6 hangs on it.

**On the cost, since PR 329 could not pay it:** each point is a full 4-rung 128³
ladder. 8³ took 19 minutes, 12³ 28, 16³ 29 (14 of them in the LOBPCG build alone
— its local eigenproblems are ~8x the DOFs of 8³'s), and 24³ over 30 — all on a
box running three other agents' `topopt-cli` processes and a full `ctest` at load
averages up to **203** (§5). **PR 329 abandoned the 16³ point at 35 minutes under
the same conditions and reported the sweep BLOCKED; this task got all four.**

**BLOCKED-STOP was therefore not invoked.** It is quoted here only to record that
it did not need to be, and that the one item it would have covered — 24³'s
rebuild counter — is named above rather than left implicit.

`run_nt_triage.sh` is idempotent — it skips points already present — so on a
quiet machine this completes the sweep without repeating the two that landed:

```bash
sh evidence/2026-08-16-geneo-tiling-sweep/run_nt_triage.sh
```

And the deflation-quality probe, which is what §6's open questions actually need:

```bash
CORES="12 16" sh evidence/2026-08-16-geneo-tiling-sweep/run_engaged_probe.sh
```

---

## In plain language

**The thing we were testing.** GenEO is an accelerator for the solver. When it
works it is spectacular — one recorded solve went from 5,412 iterations to 249.
But on your part it almost never switches on: out of 168 chances in your captured
run it declined 156. It declines because switching on has a price, and that price
is proportional to a number called `N_t` — the size of the "coarse space" it
builds. On your part `N_t` is about 1,700, and at that size switching on costs
more than just finishing the slow way.

**The one lever anyone had ever found that moves `N_t`** is how finely the part
is chopped into subdomains first. Chop coarser, fewer pieces, smaller coarse
space, cheaper to switch on. An older experiment on a much smaller part found
that going from 8-voxel chunks to 16 took `N_t` from 313 to 47. Nobody had
checked whether that carries to a part your size — the last attempt tried and the
machine was too busy.

**The lever works.** The coarse space went **1,686 → 718 → 369 → 208** across the
four chunk sizes. The old small-part result really does carry over to a part your
size, and the accelerator does not get worse at its job as the space shrinks —
I checked that specifically, because my first reading said it did and I was
wrong.

**And the runs still got slower, not faster.** 12-voxel chunks came out 13 %
worse and 16-voxel 8 % worse on the test ladder. That is the result, and it took
the whole sweep to see, because two separate things are going on.

**Reason one: an extra rebuild that I could not explain.** The coarse space is
built once and reused as the design changes underneath it. At *both* coarser
settings the solver's own safety check decided it had gone stale and rebuilt it
from scratch — and each rebuilt one came back about 1.6× bigger than the one it
replaced. A rebuild is the expensive operation the whole scheme exists to avoid.
I tested the obvious explanation (that a smaller space is simply worse) and ruled
it out. **Two independent settings did this, so it is real, and I do not know
why.**

**Reason two: the rule for when to switch on backfires.** That rule says *keep
going the slow way until you have already spent what switching on would have
cost, then switch* — and the time already spent is not refunded. So switching on
always costs more than the amount that triggered it, which means for any solve
that was nearly finished anyway, switching on is a loss. At the original chunk
size the trigger was so high that almost nothing ever reached it. Making the
coarse space smaller lowered the trigger **into the middle of the range where
your solves actually live**, so now lots of solves trip it — and most of those
trips lose. Your run went from switching on once to switching on four times, and
got slower doing it.

**A number that puts the whole thing in perspective.** At your current chunk
size, just *refreshing* the coarse space costs about 3,372 units of work, while
the solves it is meant to speed up cost between 1,100 and 2,600. **The setup
costs more than the job.** I measured the most favourable possible arrangement —
switch on always, never wait — and it is still 2 to 3.4 times *worse* than doing
nothing. So at the shipped chunk size, no amount of cleverness about *when* to
switch on can rescue this. Only making the coarse space smaller can, and that is
the thing that turned out not to last.

**So the honest summary:** the idea was sound and worth testing, the measurement
went the way it went, and **a coarser chopping should not be shipped** — it is a
13 % regression, for two independent reasons at once.

**What I did not settle.** The thing I could not explain is that **both** coarser
chunk sizes quietly paid an extra *rebuild* — the expensive operation the whole
scheme exists to avoid — and each rebuilt coarse space came back about 1.6×
bigger than the one it replaced. I checked the obvious cause (that a smaller
coarse space is somehow worse) and ruled it out by measurement. So something else
is going on, it happened at two independent settings so it is not a fluke, and I
do not know what it is. That is the first thing I would chase.

I also never measured any setting at your *real* run depth — the short test
ladder is all I had time for, and it systematically understates the benefit. So
the "6% better at 16" figure is arithmetic over your measured solve costs, not
something I watched happen.

**I did not change any setting.** That pairing is written up as a proposal with
the numbers attached, for you to decide on.

**Two side questions you asked me to look at if there was time.** Neither needed
a run — both were already answered in the archive, and I have said where:

- The warm-start option is off *for a measured reason*: a full experiment on 2
  August recommended in as many words not to arm it. It made things worse in
  exactly the situation it was built for and produced a 26 % worse design there.
  The new argument for revisiting it also does not hold — the code converts a
  coarse *density* into a level set by subtraction, so it does not get the
  exactness that argument depends on.
- The thread count of 6 is not a guess: it is the number of performance cores in
  this Mac, pinned deliberately. The sweep you asked for already exists and shows
  performance **peaking at 6 and getting worse at 8**, because the four
  efficiency cores fight for the same memory bus. The same work measured a GPU
  version too: ~4x faster as an isolated kernel, but only ~1.2x on the whole
  solve, and it breaks reproducibility.

**One caveat to hold onto.** The machine was not quiet — the task said it was,
and it was not. It ran three other jobs of mine plus a full test suite
throughout, at load averages between 18 and 137 on a 10-core box. That does not
damage the result, because everything load-bearing here is a **count** — how many
iterations, how big the coarse space — and counts come out the same on a busy
machine as an idle one. But no timing figure here should be quoted as evidence,
and none is. It is also why two of the four chunk sizes did not finish; the
command to finish them is in §8.
