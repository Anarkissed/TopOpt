# The Krylov recycler, re-measured in the posture that ships

**Task:** `krylov-recycle-reassessment` ·
**Evidence:** `evidence/2026-08-03-krylov-recycle-reassessment/`
**Branch:** `claude/krylov-recycler-cost-reassess-656021`, from `main` after PR 281.
**Machine:** Apple M2 Pro (10 cores), 16 GB, Apple clang `-O2`, Release,
`TOPOPT_USE_OCCT=OFF`. **The host was shared and heavily loaded throughout** — a
concurrent task owned the multigrid coarsening probe. 1-minute load average is
printed beside every wall table below (range **11.4 – 57.6** on 10 cores). Every
wall claim comes from postures **interleaved inside one process**; the one table
whose host load made its wall column meaningless is marked as such and its wall
column is not used.
**Kind:** MEASUREMENT + INSTRUMENT. **No production default moved.** No gate
touched, no solver behaviour changed, no assertion weakened or deleted;
`test_recycle` goes from 43 checks to **53**. Proven bit-identical (§AG8).

---

## The answer, first

**There is no single verdict, and writing one is how the 2026-07-28 measurement
went stale.** The recycler pays in one of the three fixture classes, is
structurally *absent* in a second, and splits in the third:

| class | does recycling still earn it? | DOF-weighted work | wall |
| --- | --- | ---: | ---: |
| **(a) latched / Jacobi fallback** | **thinly, at the shipped k=16** | **0.603x** | **0.979–0.983x** |
| **(b) healthy multigrid** | **neither — it is ABSENT** | 1.000x | 1.000x (bit-identical) |
| **(c) cert, WARM basis** | **yes — its best case anywhere** | 0.539x | 0.806x |
| **(c) cert, COLD basis** (`analyze`) | **no — pure cost** | 1.000x | ~50 ms/solve, route bit-identical |

Read the first row carefully, because it is the whole task:

> On the latched path the recycler removes **40 % of the operator applies** and
> returns **2 % of the wall**, while consuming **34–38 % of the solve's timed
> phases**. The iteration saving is real, deterministic and large. It is almost
> entirely eaten by the cost of producing it.

**And the 30.3 % is not "30.3 % of a solve" in general.** `mf_mgpcg` constructs
its `RecycleSession` with `allowed = rc_wrap_multigrid()`, which production pins
false — so on a solve that multigrid carries, the session returns from its
constructor before `begin()`. Nothing allocated, no matvec, no correction. The
recycling-ON and recycling-OFF postures on the healthy path are not merely close;
they are **bit-identical, measured** (§AG1b). The recycler's entire bill lives on
the plain-Jacobi fallback — the exact path PR 273/278 showed the campaign is
already trying to eliminate.

**Recommendation: RETUNE, not disarm** — `kProductionRecycleDim` **16 → 8**, which
is worth **3–9 % of wall** over today (measured in three sweeps at two operating points) and cuts the recycler's own share of the
solve from 36.1 % to 23.4 %. That is a production-default change and therefore
belongs to a **follow-up task, not to this one** (§AG6).

---

## 1. What was built

Two things, neither of them a behaviour.

### 1a. `recycle_ms` split into phases a maintainer can act on

PR 273 gave the recycler one column, `recycle_ms`. PR 278 made that column the
whole remaining accelerator bill. A single aggregate cannot say whether the lever
is the cadence, the dimension or the mechanism — those live in different phases
and answer to different knobs. So `recycle_ms` is now split the same way PR 273
split the iteration, one level down: `begin`, `setup_matvec`, `setup_other`,
`augment`, `observe`, `commit`, plus deterministic call counts
(`src/fea/recycle.hpp`, `RcPhaseTimes`).

**The split is exhaustive and it closes.** Every line of every `RecycleSession`
entry point lands in exactly one bucket, so `sum(phases)` reconciles against the
call site's own `recycle_ms` rather than approximating it — measured closure
**99.95 %** over a full trajectory (§AG2). That reconciliation is the point: it is
what makes "45.3 % of the bill is cadence-addressable" a measurement rather than a
model.

**Default OFF, and off means off.** The flag is one relaxed atomic load guarding
every clock read; the per-iteration guards are inlined inside `recycle.cpp`; the
two hooks that must live in the header (the setup matvec loop is templated on the
operator) run O(k) times per *solve*, never per iteration. Nothing here can change
an arithmetic result in either state — the clock is read, never used as an input.
Asserted, not argued: arming the instrument leaves the converged field
**bit-identical** and the CG route unchanged (`test_recycle`, tripwire).

The instrument lives **inside `recycle.cpp`**, which turned out to matter: it sees
*both* call sites, including the multigrid one, which has no phase spans of its
own. §AG5 uses that.

### 1b. The reassessment harness

`core/tests/harness/recycle_reassess.cpp` (+ `_modes.inc`) — a standalone
measurement harness in the shape of `geneo_disarm_gate.cpp`, deliberately: same
ABBA protocol, same interleaving discipline, same bracket fixture
(40x16x41, 85,680 free DOFs), so the numbers here sit directly beside PR 278's.
Not a CTest target; not linked into any production path.

**The BLOCKED-STOP condition did not arise.** Recycling has a first-class OFF
(`fea_set_krylov_recycling(false)`) under which every call site is inert by
construction. ON and OFF are two settings of one binary and are interleaved
whole-trajectory-by-whole-trajectory inside a single process. **No baseline in
this handoff is estimated, modelled or reconstructed.**

### 1c. The two bars, never averaged

* **DOF-weighted work** — deterministic, machine- and load-independent:
  `(CG iterations + recycle setup matvecs) x free DOFs`, summed over the run.
  Operator applies are the unit because that is what a matrix-free solve is made
  of; the DOF weight lets fixtures of different size be compared without pooling
  them. It does **not** charge the per-iteration correction's streaming traffic.
* **Wall** — machine-dependent, so taken only from interleaved postures, pooled,
  as medians, with the spread printed.

That the first bar deliberately omits the correction's traffic is *why* the second
one is always printed beside it. This project has been burned twice by
iteration-count-only decisions (GenEO's arming; PR 273's finding that 88 % of the
cost was invisible to `cg_iters`). Two columns, side by side, is the response —
and on the latched path they **disagree by a factor of twenty** (0.603x work,
0.98x wall). That disagreement is the finding.

---

## AG1 — The honest A/B, in today's posture

GenEO armed with the shipped engagement gate in **both** arms. Whole trajectories
alternating in ABBA order. Three classes, reported separately, never averaged.

### (a) The latched / Jacobi-fallback path — where the 30.3 % was measured

Bracket 40x16x41, 8 design iterations per trajectory, first (bootstrap) solve
excluded from the steady-state pool. Two independent runs:

| | run 1 (3 ABBA blocks) | run 2 (4 ABBA blocks) |
| --- | ---: | ---: |
| CG median/solve, ON → OFF | 499 → 886 | 499 → 886 |
| **DOF-weighted work, ON vs OFF** | **0.603x** | **0.603x** |
| **wall/solve, ON vs OFF** | **0.983x** | **0.979x** |
| ON wall spread | 1.116..1.506 s | 1.213..1.930 s |
| OFF wall spread | 1.017..1.561 s | 1.215..1.931 s |
| recycle share of the ON solve's timed phases | 38.0 % | 34.3 % |
| host load during the run | 14.2 – 16.5 | 13.5 – 14.4 |

`evidence/…/ab.txt`, `ab_rep2.txt`, `ab.csv`, `ab_raw.csv`.

**The work column is identical to three digits across runs** — it is a count, so
it is *supposed* to be. The wall column agrees to 0.4 % across two runs on a
shared host. So the headline is solid in both currencies, and they say different
things: **40 % less work, 2 % less wall.**

Note the spreads overlap almost completely. A 2 % wall win with those spreads is
real only because it is a median of pooled interleaved solves and it reproduced;
it is not a number anyone should quote to two decimal places, and this handoff
does not treat "2 %" and "0 %" as meaningfully different.

### (b) The healthy multigrid path — recycling is not cheap, it is absent

Same geometry, coarsenable grid, hierarchy built on 4/4 and 8/8 solves:

```
ON   CG total 660   setup_mv 0   recycle_ms 0.0   DOF-work 5.5202e+07
OFF  CG total 660   setup_mv 0   recycle_ms 0.0   DOF-work 5.5202e+07
healthy-path identity: fields BIT-IDENTICAL, CG totals equal      (both runs)
```

Predicted from the source before measuring, and confirmed to the bit. **There is
nothing to decide on this path.** The only way to put a recycle bill on it is to
flip `wrap_multigrid`, and §AG5 measures what that costs.

### (c) The certification solves — the class that splits

A certification solve is not a trajectory solve: it is one tight solve on a design
the carried basis was never harvested from. It comes in two shapes that behave
oppositely, and pooling them would have produced a meaningless average.

| shape | CG ON / OFF | DOF-work | wall | what it means |
| --- | ---: | ---: | ---: | --- |
| **WARM** (a rung's cert, basis as production leaves it) | 1395 / 2679 | **0.539x** | **0.806x** | the recycler's **best result anywhere** |
| **COLD** (an `analyze` job: the space is reset at entry) | **1872 / 1872** | **1.000x** | 0.968x (noise) | **pure cost**: ~50 ms of harvest + Rayleigh-Ritz, zero benefit |

`evidence/…/cert.txt`, `cert.csv`. On the healthy grid both shapes are identical
ON vs OFF, for the reason in (b).

Two things worth stating plainly:

* The COLD row's CG counts are **exactly equal**, 1872 = 1872. That is not luck —
  with no carried basis the session can only *harvest*, and harvesting cannot
  change the route. It is also a live check that the instrument is not perturbing
  what it measures.
* The COLD cert solve's 13.7 s wall is dominated by **GenEO's first basis build**,
  not by anything in this handoff. A cold analyze job pays that build; the
  recycler's ~50 ms is 0.4 % of it. Recorded so nobody reads the 13.7 s as a
  recycling number.
* The WARM row's advantage is partly a knock-on: the ON trajectory converges in
  fewer CG iterations, so GenEO's engagement gate sees a different history and the
  cert solve inherits a different GenEO posture. Both arms are complete, faithful
  postures — this is what production actually does — but the 0.806x is
  *recycling plus its effect on GenEO*, not recycling alone.

---

## AG2 — Where the 30.3 % goes

Latched path, k=16, cycle=1, 8 design iterations. `evidence/…/phases.txt`,
`phases.csv`.

| phase | wall | share | counts |
| --- | ---: | ---: | --- |
| `begin` | 0.0 ms | 0.0 % | |
| `setup_matvec` — the k exact FP64 applies forming E | 160.6 ms | 4.9 % | 112 matvecs |
| `setup_other` — promote / dot / Cholesky | 146.0 ms | 4.4 % | |
| **`augment` — the PER-CG-ITERATION correction** | **1774.0 ms** | **53.9 %** | 3,474 calls, **0.511 ms/call** |
| `observe` — the decimating harvest sample | 24.8 ms | 0.8 % | 643 stores |
| **`commit` — the Rayleigh-Ritz rebuild** | **1185.8 ms** | **36.0 %** | 8 harvest solves, **~148 ms each** |
| | | | |
| `recycle_ms` reported by the call site | 3292.7 ms | | |
| `sum(phases)` | 3291.2 ms | | **closure 99.95 %** |

**The bill has two owners, not one:**

```
CADENCE-ADDRESSABLE  (setup_matvec + setup_other + commit)   45.3 %
DIMENSION-ONLY       (augment)                               53.9 %
```

Three things a maintainer can act on that the aggregate number hid:

1. **`commit` is 36 % of the bill and it is a FLAT cost.** It is `O(c²n)` with
   `c = 2k = 32` — ~148 ms per harvest solve **regardless of how many CG
   iterations that solve ran**. On a 1.2 s latched solve that is 12 %. On a 450 ms
   healthy solve it would be 33 % *by itself*. **The recycler's economics get
   worse as the campaign succeeds at shortening solves.**
2. **`augment` at 0.511 ms/call against a ~1.5 ms CG iteration is a ~34 %
   per-iteration surcharge at k=16.** That is why a 44 % iteration cut becomes a
   2 % wall win. It is addressable only by the dimension (§AG3) or by disarming.
3. `observe` is 0.8 %. The decimating harvest is genuinely free, as designed.
   Nothing to do there.

---

## AG3 — The dimension sweep

Latched path, round-robin with the setting order reversed on alternate repeats
(ABBA generalised past two arms). `evidence/…/dim.txt`, `dim_rep2.txt`, `dim.csv`.

| k | CG total | setup mv | DOF-work | vs off | wall/solve run 1 | run 2 | recycle_ms | recycle share |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 (off) | 17,799 | 0 | 1.5250e+09 | 1.000x | 1.000x | 1.000x | 0.1 | 0.0 % |
| 4 | 14,433 | 84 | 1.2438e+09 | 0.816x | 0.845x | 0.959x | 194.5 | 15.7 % |
| **8** | 12,573 | 168 | 1.0916e+09 | 0.716x | **0.833x** | **0.897x** | 279.0 | 23.4 % |
| **16 (SHIPS)** | 10,401 | 336 | 9.1995e+08 | 0.603x | 0.917x | 0.926x | 482.9 | 36.1 % |
| 32 | 9,483 | 672 | 8.7008e+08 | 0.571x | 1.349x | 1.323x | 1254.2 | 63.7 % |

**The dimension is NOT inert.** PR 275's W3 found GenEO's threshold made no
difference; the recycle dimension is the opposite — it trades, sharply, and in
opposite directions in the two currencies:

* **Work falls monotonically with k** and is still falling at 32.
* **Wall is U-shaped with its minimum at k = 8**, in both runs, and by k = 32 the
  recycler is *losing* — 1.32–1.35x slower than not recycling at all, while doing
  43 % less work. That row alone refutes any work-only reading of this feature.
* **k = 8 beats the shipped k = 16 by 3–9 % of wall** while cutting the recycler's
  own share of the solve from 36.1 % to 23.4 %.

CG counts are byte-identical between the two runs (17,799 / 14,433 / 12,573 /
10,401 / 9,483) — the determinism claim, incidentally re-proven.

**Second operating point.** The same sweep at `vf = 0.20` — a more dilute, harder
latched fixture (`evidence/…/dim_vf020_rep2.txt`):

| k | DOF-work vs off | wall/solve vs off | recycle_ms | recycle share |
| ---: | ---: | ---: | ---: | ---: |
| 0 (off) | 1.000x | 1.000x | 0.1 | 0.0 % |
| 4 | 0.856x | 0.927x | 205.2 | 14.6 % |
| **8** | 0.730x | **0.887x** | 286.2 | 21.1 % |
| 16 (SHIPS) | 0.580x | 0.915x | 513.0 | 36.8 % |
| 32 | 0.559x | 1.362x | 1273.5 | 61.0 % |

**Same shape, same optimum.** Work still falls monotonically; wall is still
U-shaped; **k = 8 still beats k = 16**, here by 3 %. Three sweeps at two
operating points, and k = 8 wins all three.

**One sweep was discarded and it is worth saying which.** An earlier `vf = 0.20`
attempt (2 repeats) ran while the host hit load **57.6** — 5.8x oversubscription —
and its wall column came out non-monotone (k=4 slower than k=8), which is not a
result, it is the host. Its deterministic work column reproduced the table above
to three digits, which is exactly what a count should do under any load.
`evidence/…/dim_vf020.txt` keeps the raw output including the unusable column, so
a reader can see what was thrown away and why rather than take the word for it.

---

## AG4 — The cadence sweep

`rc_cycle()` is **1** in production — it has never been set away from its default,
so **every** solve harvests, pays k setup matvecs and runs a Rayleigh-Ritz over 32
columns. Latched path. `evidence/…/cycle.txt`, `cycle.csv`. (Host load 18–21
during this sweep; the ratios are interleaved, the absolute walls are inflated.)

| cadence | CG total | setup mv | DOF-work | vs off | wall/solve vs off | recycle_ms | recycle share |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| off | 17,799 | 0 | 1.5250e+09 | 1.000x | 1.000x | 0.1 | 0.0 % |
| **1 (SHIPS)** | 10,401 | 336 | 9.1995e+08 | 0.603x | 0.809x | 627.4 | 35.3 % |
| **2** | 11,388 | 144 | 9.8806e+08 | 0.648x | **0.801x** | **457.5** | 26.6 % |
| 4 | 11,922 | 48 | 1.0256e+09 | 0.673x | 0.922x | 485.5 | 24.4 % |
| 8 | 12,453 | 0 | 1.0670e+09 | 0.700x | 0.926x | 557.0 | 27.9 % |

**Cadence 2 is the free-ish lever and cadence 4+ is not.** At 2 the wall is
indistinguishable from 1 (0.801 vs 0.809) while the recycler's own bill drops
**27 %** and the rebuild's memory peak — `2*(k+m)` float columns, the binding
memory number — is paid half as often. At 4 and 8 the wall clearly regresses, and
handoff 133's finding that "a 4-solve-old basis was worth almost nothing" is
corroborated rather than overturned.

One counter-intuitive detail worth naming, because it looks like an error:
**`recycle_ms` goes back UP at cadence 4 and 8** (485, 557) after falling at 2
(458). It is not an error. A staler basis costs more CG iterations, and `augment`
is charged per iteration — so what the cadence saves in `commit` it hands back in
`augment`. This is the phase split earning its keep: the aggregate number alone
would have looked like noise.

---

## AG5 — The multigrid interaction

`krylov_recycle_wrap_multigrid` is false in production. With it false the
multigrid call site's session is constructed `allowed = false` and is completely
inert. Healthy path, interleaved. `evidence/…/wrapmg.txt`, `wrapmg.csv`.

| setting | CG total | setup mv | DOF-work | vs off | wall/solve vs off |
| --- | ---: | ---: | ---: | ---: | ---: |
| recycling off | 660 | 0 | 5.5202e+07 | 1.000x | 1.000x |
| **wrap=0 (SHIPS)** | 660 | 0 | 5.5202e+07 | **1.000x** | 0.964x |
| **wrap=1** | 690 | 333 | 8.5564e+07 | **1.550x** | **1.493x** |

**Flipping it loses on both bars at once**, which is rare and unambiguous: 55 %
more DOF-weighted work and 49 % more wall, and the CG count goes *up* (660 → 690)
rather than down. Handoff 133 §10's mechanism — the +1 spectral lift is right when
M is weak and *widens* the spectrum when M is a V-cycle — is confirmed on the path
that matters, with a larger margin than the ruling was made on.

**And it would be nearly invisible.** Running the phase instrument with `wrap=1`
(`evidence/…/phases_wrap1.txt`):

```
recycle_ms reported by the multigrid call site : 0.0 ms
sum(phases) measured inside recycle.cpp        : 1610.3 ms   (201 ms/solve,
                                                  ~45 % of a 450 ms solve)
      commit  1162.9 ms   72.2 %      <-- the flat O(c^2 n) cost, unchanged
      setup   296.5 ms    18.4 %
      augment 141.6 ms     8.8 %
```

`mf_mgpcg` has no phase spans — only `mf_cg_solve` wraps its recycle calls — so
`recycle_ms` reads **0.0 while the recycler burns 201 ms per solve**. Anyone who
flips this flag will see PR 273's instrument report zero recycle cost. The
instrument added by this task lives inside `recycle.cpp` and therefore sees both
call sites, which is the only reason that number exists. **Adding spans to
`multigrid.cpp` is the obvious fix and is deliberately NOT done here — that file
is owned by the concurrent coarsening task.** It is left as a named gap.

This is also the sharpest argument for the tripwire: the flag's cost is real, its
observability is zero, and its default is load-bearing.

---

## AG6 — The recommendation, with numbers

**RETUNE.** Not disarm, and not keep-as-is.

**By class, since a single verdict is exactly what went stale:**

| class | verdict | by how much |
| --- | --- | --- |
| (a) latched / Jacobi fallback | **pays, thinly, today** | 2 % of wall for 34–38 % of the solve's timed phases; **10–17 % at k=8** |
| (b) healthy multigrid | **neither pays nor costs** | bit-identical; keep it that way (AG5: flipping costs 1.49x) |
| (c) cert, warm basis | **pays best** | 0.806x wall, 0.539x work |
| (c) cert, cold basis (`analyze`) | **pure cost** | ~50 ms/solve, ~0.4 % of that solve; route bit-identical |

**The change to make, and it belongs to a follow-up task, not this one** (AG8
forbids a production change here, and a default move deserves its own gate run
regardless):

1. **`kProductionRecycleDim` 16 → 8.** Measured twice: **0.833x / 0.897x** wall
   against **0.917x / 0.926x** at k=16, i.e. **3–9 % faster than today**, while
   cutting the recycler's share of the solve **36.1 % → 23.4 %**. The price is
   explicit and paid in the other currency: DOF-weighted work rises 0.603x →
   0.716x (still 28 % below recycling-off). That trade is the right way round —
   the work the recycler saves is *Jacobi-fallback work*, which the campaign's own
   direction (fix the multigrid) is trying to delete anyway; the wall is what a
   user waits for.
   **This owes a second fixture FAMILY before it ships.** k=8 won all three
   sweeps run here (two at `vf=0.50`, one at `vf=0.20`), but all three are the same
   bracket geometry. Handoff 133 chose 16 from a sweep across two *regime*
   fixtures. Re-run `recycle_reassess dim` on the stagnation-class fixture (a solid
   part pinned inside a near-void box — `geneo_disarm_gate.cpp`'s
   `make_stagnation_case`, the 1,685–41,063-iteration band) before moving the
   constant. If the optimum there is also 8, ship it; if it is 16, the right answer
   is a per-regime dimension and that is a bigger piece of work.

2. **Optionally `rc_cycle` 1 → 2**, worth a further ~27 % off the recycler's own
   bill at neutral wall and half as many rebuild memory peaks. Smaller, less
   certain, and **its interaction with (1) is unmeasured** — at k=8 the commit is
   cheaper, so the cadence has less to save. Sweep it *at k=8* or leave it at 1.

**Why not disarm.** It never loses on the path where it runs (0.98x, twice), it is
free on the healthy path by construction, and it is worth 19 % on warm cert
solves. Disarming would trade a small win for nothing.

**Why not keep-as-is.** k=16 was chosen in the GenEO-stacked posture, where
recycling only had to add value on top of a deflation that was already flattening
the spectrum. That posture is gone. In the posture that ships, k=16 is on the
wrong side of the U.

**The forward-looking caveat the follow-up should carry.** `commit` is a flat
~148 ms per harvest solve, independent of iteration count. Every hour the campaign
spends shortening solves makes that fixed cost a larger share of one. If the
multigrid work lands and the Jacobi fallback stops being reached, the recycler's
remaining bill goes to **zero by construction** — and the right action at that
point is to leave it exactly where it is, armed and unreachable, not to tune it
further.

---

## AG7 — Correctness

`evidence/…/exact.txt`. Two forms of the bar, because they answer different
questions.

**The sharp form — one solve, one design, warm basis, latched path:**

```
CG  OFF 624  (final relative residual 9.957e-09)
    ON  658  (final relative residual 9.793e-09)
worst relative displacement deviation : 2.022e-06
compliance relative deviation         : 1.005e-09
```

**The trajectory form — 6 design iterations, latched path:**

```
worst relative displacement deviation ON vs OFF : 2.162e-06
worst relative density deviation                : 2.379e-08
final compliance relative deviation             : 1.390e-10
determinism (same posture rerun): u BIT-IDENTICAL   x BIT-IDENTICAL
CG totals: OFF 4706  ON 3110   (ON rerun equal)
```

**Healthy path: 0.000e+00 on every line, both forms.**

**I predicted ≤ 1e-6 and measured 2.0e-6. That prediction was wrong, and the
reason matters more than the miss.** The two numbers are not comparable
quantities. CG's stopping test is a relative **residual** at 1e-8; the relative
**error** it implies is amplified by the operator's conditioning, and this is a
near-void SIMP system with ~1e9 modulus contrast. A ~200x amplification of a 1e-8
residual tolerance is exactly what the system's conditioning predicts. Both solves
satisfy the *same* stopping test to the same tolerance; they are two points inside
one tolerance ball, and which point you land on depends on the route — which is
precisely what recycling changes and all it changes.

The quantity the gate actually acts on is unaffected: **compliance agrees to
1.0e-9 (single solve) and 1.4e-10 (trajectory)**, four to six orders below the
residual tolerance. `test_recycle`'s own long-standing exactness bar
(`max|du|/max|u| <= 1e-6` on its own fixtures) passes untouched — it was not
weakened, and it is not the same fixture.

**Determinism:** bit-identical fields, bit-identical densities, equal CG totals on
rerun, on both paths. Nothing in the recycler reads a clock, a thread id or a
random number, and the phase instrument does not either.

---

## AG8 — No production change

**Stash-rebuild fingerprint.** `geneo_byteid_xbuild` (public API only) runs a
2-rung production ladder and hashes the certified outputs — densities, compliance,
margins, accepts:

```
with the branch's changes reverted (git stash) : rungs=2 fnv=2318d4342a24861e
with the branch's changes applied              : rungs=2 fnv=2318d4342a24861e
```

`evidence/…/byteid_before.txt`, `byteid_after.txt`. Identical. (It is also the
same fingerprint PR 278 recorded, which is the expected result of a branch that
changes no behaviour.)

**Full ctest: 94/94 passed**, 1632 s. `evidence/…/ctest.txt`.

**`test_recycle`: 43 → 53 checks, 0 failures.** The ten added checks are the
**shipped-defaults tripwire** (the PR 275 / PR 280 pattern): `k = 16`,
`cycle = 1`, `wrap_multigrid = false`, library default OFF, production dim 16, and
phase timing OFF — plus a *proof*, not an assertion, that arming the instrument
leaves the field bit-identical and the CG route unchanged. The tripwire does not
forbid a change; it forbids an **unmeasured** one. Every table in this handoff is a
statement about that exact configuration, and anyone moving a value must re-run
`recycle_reassess` and update this document in the same change. No existing
assertion was weakened, relaxed or removed.

---

## 2. Predictions, graded

Recorded in `evidence/…/00-predictions.md` before any measurement on this branch.

| # | predicted | measured | |
| --- | --- | --- | --- |
| structural | healthy path bit-identical, recycler absent | bit-identical, 0 matvecs, 0 ms | ✅ |
| AG1(a) | 30–55 % CG cut; wall 0.85–1.15x | 44 % cut; wall 0.979–0.983x | ✅ |
| AG1(b) | bit-identical | bit-identical | ✅ |
| AG1(c) | 0–20 % iteration cut, wall in noise | **warm: 48 % cut, 0.806x wall**; cold: 0 % and pure cost | ❌ under-called the warm case badly |
| AG2 | augment ≥ 55 %, commit 10–25 %, setup 15–30 %, observe < 5 % | augment 53.9 %, **commit 36.0 %**, setup 9.3 %, observe 0.8 % | ⚠️ right about which phase leads, wrong about the runner-up |
| AG3 | a real trade, U-shaped, optimum at or below 16, most likely 8 | exactly that; optimum at 8 | ✅ |
| AG4 | cadence 2 neutral, 4+ loses | 2 neutral (0.801 vs 0.809), 4/8 lose | ✅ |
| AG5 | regress 1.05–1.4x | 1.49x wall, 1.55x work | ⚠️ direction right, magnitude under-called |
| AG6 | retune, not disarm | retune, k 16 → 8 | ✅ |
| AG7 | ≤ 1e-6 displacement deviation | **2.0e-6** | ❌ wrong bar (residual ≠ error under 1e9 contrast) |
| AG8 | byte-identical, ctest green | identical fnv, 94/94 | ✅ |

**The two real misses both cut the same way: I under-estimated the fixed,
iteration-independent costs.** `commit` is 36 % of the bill, not 10–25 %, because
its `O(c²n)` Rayleigh-Ritz is single-threaded FP64 over 1,024 column pairs — I
priced it by flop count against a *threaded* `augment` and got the ratio wrong.
The same error made me under-call `wrap=1`'s regression, which is 72 % `commit`.
It is a good thing the split was measured rather than reasoned about; that was the
point of building it.

---

## 3. What this did NOT measure

Stated so nobody reads a bound that is not here:

* **The production ladder through `minimize_plastic` and the gate.** No verdict
  can move — this branch changes no behaviour and §AG8 proves the ladder
  fingerprint is unchanged — so the gate was not re-run as a comparison. If the
  follow-up moves `kProductionRecycleDim`, it *must* run one, because a dimension
  change moves the CG route and therefore the converged field within tolerance.
* **One fixture family, one grid size (40x16x41), two dilutions.** The k=8
  recommendation owes a second family — the stagnation-class fixture — before it
  ships. Said again in AG6 because it is the one place this handoff's evidence is
  thinner than its recommendation.
* **Interaction between the dimension and the cadence.** Swept independently only.
* **`rc_metric_diagonal`** — the extraction-metric research knob was left at its
  default and not swept; out of scope.
* **`multigrid.cpp`'s missing phase spans** — named in AG5, not fixed, because
  that file belongs to the concurrent coarsening task.

---

## 4. Files

| file | what changed |
| --- | --- |
| `core/src/fea/recycle.hpp` | `RcPhaseTimes` + the phase-timing API and its two header hooks; the default-OFF contract documented beside them |
| `core/src/fea/recycle.cpp` | the `Span` guard and the phase/counter accounting; **no arithmetic touched** |
| `core/tests/unit/test_recycle.cpp` | +10 checks: the shipped-defaults tripwire and the instrument's bit-identity proof |
| `core/CMakeLists.txt` | `src/` on `test_recycle`'s include path (the `test_geneo` precedent) so the tripwire can read the internal dials |
| `core/tests/harness/recycle_reassess.cpp` `_modes.inc` | new measurement harness, 8 modes; not a CTest target |

---

## In plain language

The solver has an accelerator called the **Krylov recycler**. Every time the
optimiser solves the same structure again with slightly different material, the
recycler remembers the handful of directions that were hardest to figure out last
time and hands them to the next solve, so it doesn't have to rediscover them.

Last year we measured it while a *second* accelerator (GenEO) was also running,
and concluded it was cheap and mildly useful. Then we switched that second
accelerator off, and the recycler was suddenly the only overhead left — about a
third of every slow solve. So: is it still worth it?

**Here is the honest answer. The recycler does exactly what it claims: it removes
40 % of the arithmetic. But producing that saving costs almost as much as the
saving is worth — so the user waits about 2 % less. It is not a fraud and it is
not a bargain.**

Three more things we found, and one of them is the most useful:

* **On fast solves, the recycler isn't running at all.** When the good solver
  (multigrid) is working, the recycler is switched off by design — we verified the
  results are identical down to the last bit. So the "third of every solve" only
  ever applies to the *slow* solves, which is the same problem the team is already
  working on fixing. Fix that, and this cost disappears without anyone touching
  the recycler.
* **It's tuned one size too big.** It currently remembers 16 directions. At 8 it
  remembers less, saves less arithmetic — and is *faster*, by 3–9 %, because
  applying 16 remembered directions to every single step costs more than the extra
  ones save. We recommend changing 16 to 8. That's a change to a shipped default,
  so it belongs to a separate piece of work with its own testing — not this one.
* **There is one place it genuinely shines**: the final "certify this design"
  solve at the end of a run, where it cuts about 19 % off. And one place it is
  pure waste: a one-off analysis job, where it does bookkeeping for a next solve
  that never comes — about 50 milliseconds, which is 0.4 % of that job.

**Nothing shipped changed in this task.** We added a measuring instrument (off by
default, proven not to alter a single number), a guard that will trip if anyone
quietly moves one of the four settings these measurements were made against, and
this report. All 94 tests pass, and a real production run produces a
byte-for-byte identical result to before.
