# ACTIVE DOMAIN — disarmed in production

**Task slug:** active-domain-disarm
**Evidence:** `evidence/2026-08-01-active-domain-disarm/`
**Decision:** the maintainer's (2026-08-01). This handoff records the before/after
with the rigour the arming PRs used. It does not re-litigate the call.

## THE DECISION

`kProductionActiveDomainBand` moves from `-1` (AUTO) to `0` (OFF). Every production
trajectory penalized solve now runs the FULL domain. ONE named constant moved. The
tripwire, the AUTO derivation (`active_domain_auto_band` = ceil(rmin)+1), the escape
latch, the degeneracy latch, the library default (already 0) and every
`active_domain_*` observability field are untouched. Re-arming is one constant.

## TL;DR (measured, not asserted)

1. **The gate is safe.** Full production ladder, every rung, disarmed vs armed vs a
   1e-9 negative control: **verdicts IDENTICAL** (rung 0 ACCEPT, rung 1 REJECT, the
   ladder stops there), terminal recommendation identical, every posture bit-identical
   on re-run. **No BLOCKED-STOP condition was met.**
2. **Against the control floor, the ARMED posture is the one that moves.** Disarming
   restores the exact reference; arming perturbs it. Rung 1's margin moves
   `dM/M = 1.097e-3` armed vs `8.13e-10` for the control — **six orders of magnitude
   above the floor** — and arming flips **2 of 24 576 voxels** across the print
   threshold where the control flips **0**. Reported, not rounded away. Neither
   changed a verdict.
3. **T3's premise does not hold, and the reason is structural, not statistical.** AD's
   cost was NOT measured in a world the odd-axis fix has since changed, because **AD
   and the parity pad operate on disjoint grid classes**. AD needs dilution; dilution
   comes from a design box; `expand_design_domain` rounds every axis up to
   `kDesignBoxCoarsenAlign = 8` — so **no design-box grid can carry an odd axis**.
   Measured two ways: a box sweep (10 box heights, 0 odd grids) and the arming fixture
   run under both pad modes — **BIT-IDENTICAL, CG 212 vs 212 (AD off) and 248 vs 248
   (AD on)**. Every prior AD number stands exactly as taken. **Nothing here reverses
   the three reviews.**
4. **The one number that deserved more weight than it got, stated loudly.** On the
   healthy gate fixture the armed posture is **~18% FASTER IN WALL** (30.0 s → 24.7 s,
   replicated) while running **9.8% MORE CG iterations** — the restricted solves carry
   fewer DOFs, so cheaper iterations beat fewer iterations. **Disarming gives that wall
   win up.** It is real, it is reproducible, and it is confined to the healthy no-latch
   regime; §T3 has the reason it does not transfer to the job AD was armed for.
5. **Full CTest green: 88/88, 0 failed.** Every posture measured is bit-identical on
   re-run, and the observability survives the disarm — proven on a real CLI run and
   pinned in `test_production_parity`.

---

## T1 — THE FLIP: ONE NAMED CONSTANT

`core/src/simp/production.cpp`

```
-constexpr int kProductionActiveDomainBand = -1;  // AUTO
+constexpr int kProductionActiveDomainBand = 0;   // DISARMED (OFF)
```

The arming shape, in reverse:

| the arming did | the disarm does |
|---|---|
| flipped ONE named production constant | flips the SAME constant back |
| left the library default at 0 | library default still 0 — untouched |
| kept the TRIPWIRE naming the harnesses to re-run | TRIPWIRE kept, and now names `ad_disarm_gate.cpp` too, and forbids the change **in either direction** |
| asserted the echo in `test_production_parity` | same test, asserting 0 and the disarmed run |
| wrote `active_domain_*` into `run_info.json` | still written — T4 |

Nothing else in `/core/` changed behaviour. The rest of the diff is comment and
assertion text: `production.hpp`'s enumerated-settings list, the two places that
called draft "the SECOND non-bit-identical dial" (it is now the **only** one), and
the parity test's AD block.

**The mechanism is not deleted.** `resolve_active_domain_band`, `active_domain_mask`,
`active_domain_auto_band`, the escape latch and the degeneracy latch are all still
there, still exercised by `test_active_domain` and by all four harnesses. The parity
test deliberately still pins the AUTO derivation (`expected_k > 0`) beside the
disarmed assertion, so a future re-arming finds that bar already standing.

---

## T2 — THE FULL GATE TABLE, BEFORE AND AFTER, EVERY RUNG

Full production ladder on the arming gate fixture (24 576 elements, 46.5× dilution,
2.15% fill, rmin = 2.5 voxels → AUTO k = 4 — the *same* fixture the arming was gated
on, so these rows are directly comparable to PR 187's A3). Three postures, **each run
twice**: `OFF` = band 0 (what ships now), `ON` = band −1 AUTO (what shipped before),
`CTL` = band 0 under a **1e-9 relative load perturbation** — the negative-control
floor, the 2026-08-01 multiscale-wiring I3 discipline.
Sources: `gate_table.log`, `gate_table.csv`, `flips.csv`.

### Verdicts and margins — every evaluated rung

| rung | vf | verdict OFF → ON | margin OFF | margin ON | dM/M | CTL margin | dM/M (control) |
|---|---|---|---|---|---|---|---|
| 0 | 0.68 | ACCEPT → ACCEPT | 1.75947361399 | 1.75937620829 | **5.536e-05** | 1.75947361248 | 8.572e-10 |
| 1 | 0.52 | REJECT → REJECT | 0.842343074324 | 0.841419043679 | **1.097e-03** | 0.842343073639 | 8.128e-10 |

The ladder evaluates rung 0 and rung 1 and stops at rung 1 in **all three** postures.

```
twice-run bit-identical:  OFF YES   ON YES   CTL YES
gate verdicts  OFF vs ON : IDENTICAL
gate verdicts  OFF vs CTL: IDENTICAL
terminal recommendation:   IDENTICAL in all three
                           "fdm walls=4 top=5 bottom=4 infill=45%gyroid"
```

### Design motion against the 1e-9 negative-control floor

Classification flips are counted two ways per rung, over all 24 576 elements: the
**PRINTED** class (`#{ρ > kIso = 0.5}` — the classification that decides the shipped
part) and a **5-class** split (void / low-gray / mid / high-gray / solid).

| rung | comparison | class flips | **printed flips** | max\|Δρ\| | mean\|Δρ\| |
|---|---|---|---|---|---|
| 0 | control 1e-9 vs OFF | 0 | 0 | 2.579e-09 | 7.877e-12 |
| 0 | **armed ON vs OFF** | 0 | **0** | 1.188e-03 | 3.940e-06 |
| 1 | control 1e-9 vs OFF | 0 | 0 | 1.162e-09 | 2.746e-12 |
| 1 | **armed ON vs OFF** | 0 | **2** | 1.398e-03 | 6.815e-06 |

**Read the direction correctly.** OFF is the reference — with the band at 0 the
production trajectory is bit-identical to the library default, so disarming *removes*
this motion rather than causing it. What the table shows is the size of the
approximation the armed posture was paying:

* **`dM/M = 1.097e-3` on rung 1 EXCEEDS the control floor (8.13e-10) by ~6 orders of
  magnitude.** It also exceeds the arming's own 0.1% margin bar. Not rounded away.
* **2 voxels of 24 576 cross the print threshold** on rung 1 where the control crosses
  0. Small, real, and above the floor. Reported.
* **max\|Δρ\| is ~1e-3 armed vs ~1e-9 control** — six orders again.
* No verdict, and no terminal recommendation, moved anywhere.

These reproduce PR 187's A3 margins (`1.75947…` / `0.842343…`) and the 2026-07-27
review's armed margins to the digit.

### Cost on this fixture — and the honest counterweight

```
CG iterations   OFF 2384  ->  ON 2618   (1.098x — armed costs 9.8% MORE)
wall            OFF 30.0s ->  ON 24.7s  (0.822x — armed is 18% FASTER)
optimizer iters OFF 97    ->  ON 98
Jacobi fallback OFF 0/97      ON 0/98   (healthy multigrid, both)
GenEO           OFF armed=0 builds=0    ON armed=0 builds=0  (never engages here)
ARMED latch     rung 0: k=4, held, 0 escapes, f_bar 0.417
                rung 1: k=4, LATCHED @iter 3, 50 escapes, f_bar 0.991
```

Replicates: OFF 30.0 / 30.2 s, ON 24.7 / 24.2 s — the wall gap is ~5 s against ~0.2 s
of run-to-run spread, so it is signal, not noise. **The armed posture is faster in
wall on this fixture and the disarm gives that up.** §T3 covers why it does not
transfer.

**No BLOCKED-STOP.** The stop condition was "if disarming changes any gate verdict
beyond the control floor". No verdict changed at all, in any posture.

---

## T3 — THE WIN, RE-MEASURED POST-262

The task's premise: every prior AD measurement predates the odd-axis parity pad
(2026-07-31), which turned multigrid on for ~75% of grids; AD's cost was therefore
measured in a Jacobi-dominated world, and if AD is now neutral or helpful under
healthy multigrid that reverses three reviews and the maintainer must hear it before
shipping.

**The premise does not hold — and the reason is structural, so it is stronger than a
re-measurement would have been.**

### The two features cannot meet: disjoint grid classes

* **AD needs dilution.** `active_domain_mask` counts over NON-EMPTY voxels: the band
  is (material above 1.5·ρ_min) dilated by k, over the non-Empty set. On a grid with no
  design box the non-Empty set *is* the part, every voxel starts above threshold, the
  active fraction is 1.0 from iteration 1, and the degeneracy latch turns the feature
  off. **AD only does anything when a design box (or keep-out) dilutes the domain.**
* **A design box can never be odd.** `expand_design_domain` (voxelize.cpp) ends with
  `round_up_to(raw_n{x,y,z}, coarsen_align)`, and the driver passes
  `kDesignBoxCoarsenAlign = 8` unconditionally — from `minimize_plastic` and from
  `minimize_plastic_solved_grid` alike. **Every axis of every design-box grid is a
  multiple of 8.**
* **The pad only engages on an odd fine axis.** By its own scope guard: all-even grids
  take the legacy path, byte-identical by construction.

Measured, not just argued (`dims.log`) — sweeping the arming fixture's box height:

| box y-extent (mm) | 24 | 25 | 26 | 27 | 28 | 29 | 30 | 31 | 32 | 33 |
|---|---|---|---|---|---|---|---|---|---|---|
| solved grid ny | 24 | 32 | 32 | 32 | 32 | 32 | 32 | 32 | 32 | 40 |
| odd axis? | no | no | no | no | no | no | no | no | no | no |

**0 of 10 box heights produced an odd axis.** The real 128×31×118 run that motivated
the pad was, necessarily, a no-design-box run.

### The pad is inert on the AD fixture class — measured

The arming gate fixture, rung 0, 10 iterations, under pad mode 0 (legacy rejection)
and pad mode 1 (today's AUTO), with AD off and on (`pad_inert.log`,
`pad_inert.csv`):

| cell | grid | mg | CG | bit-identical to pad 1 |
|---|---|---|---|---|
| pad0 / AD-off | 32×24×32 | carried | 212 | **YES** |
| pad1 / AD-off | 32×24×32 | carried | 212 | — |
| pad0 / AD-on | 32×24×32 | carried | 248 | **YES** |
| pad1 / AD-on | 32×24×32 | carried | 248 | — |

Bit-identical densities, compliances, margins and iteration counts in both pairs.
**The parity pad cannot have changed any AD measurement ever taken on this class.**

*(Rung 0 at fixed length is the honest scope and it is sufficient: the pad is a
hierarchy-construction choice made at the first solve of a run. If it engaged, the
first solve would already differ.)*

### What made the old measurements Jacobi-dominated was a DIFFERENT mechanism

The Jacobi fallback in the arming review's stagnating fixtures (ARM12, big-stag, L)
is the **multigrid stagnation latch** (handoff 127): the hierarchy *builds* and then
stops contracting on the high-contrast ultra-dilute field. That is not the odd-axis
cliff — 262 rejects a hierarchy it cannot build; 127 abandons one it built. **The
parity pad does nothing for stagnation**, by its own design note. So the regime AD's
coin-flip lives in is untouched by 262.

### The class the pad DID rescue — and AD cannot reach it

The odd-axis fixture (`odd_axis_25iter_partial.log`): the same L-bracket built directly
at **33×25×33** with no design box, so the odd axes survive to the solver. Rung 0, the
same fixed length in every cell.

| cell | mg | CG | Jacobi solves | GenEO armed / builds | AD f_bar | AD latched |
|---|---|---|---|---|---|---|
| pad0 / AD-off | NOT-carried | 5652 | 50/50 | 53 / 1 | 1.0000 | — |
| pad0 / AD-on | NOT-carried | **5652** | 50/50 | **53 / 1** | **1.0000** | **YES** |
| pad1 / AD-off | NOT-carried | 5898 | 48/50 | 51 / 1 | 1.0000 | — |

**AD is exactly inert here, measured.** With the band armed the run is identical to the
disarmed run in every digit — CG 5652 vs 5652, margin `2.709101995` vs `2.709101995`,
compliance `48.2214482481` vs `48.2214482481`, GenEO `armed=53 builds=1` both. The
active fraction is **1.0000** and the **degeneracy latch fires**: with no design box the
band's denominator is the part itself, so the band covers the domain from iteration 1,
buys nothing, and turns itself off saying so. Exactly what the feature is designed to
do — and exactly why AD cannot be affected by a fix that only touches this class.

**A finding for PR 262's ledger, not this one.** On *this* fixture the parity pad does
not help: it converts a clean build-rejection into build-then-stagnate (2 of 50 solves
managed multigrid, the other 48 fell back anyway), costing **+4.4% CG (5652 → 5898)**
and more wall. That is the 122/127 pathology the pad's own scope note warns about, on a
high-contrast whole-domain field. One fixture is not a verdict — PR 262 measured its win
on the real l-bracket res-47 case and that stands — but it is worth a look, and it is
**orthogonal to the disarm**, since AD is inert in all of these cells.

**Not completed:** the fourth cell (pad1 / AD-on). The host was saturated throughout
this task by other worktrees running solver suites in parallel (load average was ~280
on 10 cores while this probe ran, and passed 500 later) and the cell was cut rather
than left to thrash. It is not
load-bearing: AD is measured inert on this class in the pad0 pair and its latch fires on
the same grid, so the missing cell would differ from `pad1 / AD-off` only by whatever
the latch does before it fires. Re-run with `ad_disarm_gate odd 25` on an idle host.

### GenEO basis rebuilds — the mechanism, named exactly

One of the three stated reasons for the disarm is that AD multiplied GenEO basis
builds "by invalidating the moduli fingerprint each time the mask window moved". The
effect is real and the code documents it, but the fingerprint is the **structure**
one, not the moduli one — and naming it correctly makes the reason *stronger*:

* `structure_fingerprint` (geneo.cpp) hashes the grid dims and **`kept_global`** — the
  kept-DOF set. An AD mask move changes that set, and `geneo_prepare` then **DROPS the
  basis outright**: its own comment reads "DOF-set changed (rung/grid/BC change, **an AD
  mask flip**): the basis columns index a different kept set and are meaningless".
* `moduli_fingerprint` hashes the modulus field and lattice tensors. A change there
  triggers only a **cheap coarse-operator refresh**, not a rebuild.

So AD does not cause refreshes — it causes **basis invalidation and full re-eigensolve**,
which is the strictly more expensive of the two paths. The mechanism is confirmed by
inspection.

**A direct measurement of this in the stagnating regime was attempted and cut.** It
needs a fixture where GenEO engages *and* the band stays armed (the 48×32×48
ultra-dilute box), and the host was saturated by three other worktrees running solver
suites concurrently (load average peaked at 535 on 10 cores). Take it on an idle host
with `ad_disarm_gate stag 12`; the harness reports `geneo_armed_solves` and
`geneo_basis_builds` per posture. It is supplementary — **T3's requested healthy-multigrid
re-measure is the gate table above, and that is complete** — and the disarm does not
rest on it.

### Verdict on T3, stated plainly

**AD is NOT newly neutral or helpful under healthy multigrid.** The healthy-multigrid
measurement was always available and is re-taken above on today's build: on the gate
fixture, with multigrid carrying every one of 97/98 solves, the armed posture costs
**+9.8% CG** and buys **−18% wall**. That is the same trade the arming measured, on
the same fixture, post-262, unchanged. **The three reviews are not reversed.**

The one thing this section does add to the record, and the maintainer should have it
in front of them: **the CG-iteration metric that all three reviews led with understates
AD on healthy fixtures.** AD trades more iterations for cheaper iterations, and on
this fixture the trade pays in wall clock. What kills it is not that trade — it is
that the trade only exists while the band holds, and in the stagnating design-box
regime that dominates production the escape latch drops the band after ~2 iterations,
leaving the cost and none of the benefit.

---

## T4 — THE OBSERVABILITY STAYS

The instrumentation is **not** deleted with the default. A disarmed run records "the
whole domain was active" as a **positive statement**, so a future re-arming diffs
against this posture instead of against an absent field.

**Proven on a real `topopt-cli run`** (l-bracket STEP, resolution 24, four rungs —
`cli_run_info.json`):

```json
  "active_domain_band": 0,
  "active_domain_band_resolved": [0, 0, 0, 0],
  "active_domain_latched": [false, false, false, false],
  "active_domain_latch_iteration": [0, 0, 0, 0],
  "active_domain_escape_count": [0, 0, 0, 0],
  "active_domain_latch_reason": ["", "", "", ""],
  "active_domain_fraction_mean": [1, 1, 1, 1],
```

All seven fields present, one entry per evaluated rung. Compare the armed record from
`evidence/2026-07-29-geneo-arming/cli_run_info.json` (`band: -1`, `resolved: [3,3,3]`,
`latched: [true,…]`, `fraction_mean: [1,1,1]`) — same shape, different posture, directly
diffable. `active_domain_fraction_mean = 1` is the honest reading: with no band, 100% of
the domain was active.

**Why it survives structurally, not by accident.** The finalize loop in `run_job.cpp`
that copies these onto `RunInfo` is **unconditional** — it runs over every evaluated
variant regardless of the band — and `observability.cpp` serialises all seven fields
unconditionally. The only band-gated code is the LOUD LATCH warning
(`if (options.simp.active_domain_band != 0)`), which is correct: a disarmed run has no
latch to warn about. Nothing was touched here.

`test_production_parity` now pins this in CI: it asserts each rung of a real production
ladder reports `active_domain_band == 0`, `!latched`, `escape_count == 0`, an empty
latch reason, **and `active_fraction_mean == 1.0`** — that last one specifically so a
future refactor cannot quietly stop computing the field just because it is disarmed.

---

## T5 — DETERMINISM + CTEST

**Determinism: MET, on every posture measured.** The gate harness runs each posture
twice and compares physical density, compliance, margin, iteration count and verdict:

```
twice-run bit-identical:  OFF YES   ON YES   CTL YES
```

Beyond that, three separate bit-identity results in this task's evidence:

* `pad0` vs `pad1` on the AD fixture class — bit-identical, AD off **and** on
  (`pad_inert.csv`).
* The odd-axis fixture, AD off vs AD on — identical to every digit printed
  (CG 5652/5652, margin `2.709101995`, compliance `48.2214482481`), because the
  degeneracy latch makes AD a no-op there.
* The post-flip build reproduces the pre-flip `off#1` ladder exactly — 2384 CG, margin
  `1.759473614`, compliance `4.63900268409` (`gate_table_postflip_partial.log`).

`test_production_parity`'s own determinism section (bit-identical designs run-to-run,
and at both thread counts) is unchanged by this task and runs in the suite below.

**Full CTest: GREEN — 88/88, 0 failed** (`ctest_full.log`):

```
100% tests passed out of 88

Total Test time (real) = 3231.68 sec
```

The 54-minute wall time is host contention, not this change: three other worktrees
(`graded-cell-size-phase-0`, `matrix-free-gene-phase-1`) plus an Xcode `xctest` session
ran solver suites concurrently for the whole of this task, driving the load average from
~24 to **777 on 10 cores**. Tests that normally take ~1 s were taking 30-65 s. Nothing
was skipped, retried or excluded — it is the plain `ctest --output-on-failure` over all
88 targets.

This change's CI face is **test 81, `production_parity`, Passed (57.51 s)**. It was also
run standalone (`test_production_parity.log`) for its printed record — it asserts the
named constant is 0, that every rung of a real production ladder ran with band 0, that
the latch never fired and nothing escaped, and that the `active_domain_*` observability
is still written:

```
  [AD disarm] production band DISARMED: every rung ran band=0 (the AUTO derivation
              would have given k=3 at rmin=1.500 voxels, spacing=2.500 mm) on 4 rung(s)
  [132 (C)] design bit-identical at 6 and 10 threads
production parity (handoff 093): all checks passed
```

Note what that line proves twice over: the run really was disarmed (band=0 on all four
rungs), AND the AUTO derivation is still alive and would still resolve k=3 on this grid
— the mechanism kept, the request withdrawn.

---

## Scope / forbidden files

* **Changed:** `core/src/simp/production.cpp` (the constant + its tripwire and
  apply-site comments), `core/include/topopt/production.hpp` (comments only),
  `core/tests/validation/test_production_parity.cpp` (assertions).
* **Added:** `core/tests/harness/ad_disarm_gate.cpp` — a standalone measurement
  harness, NOT a CTest target, a sibling of `active_domain_gate.cpp` /
  `active_domain_escape.cpp`. Plus `evidence/2026-08-01-active-domain-disarm/`.
* **Not touched:** `fixtures/`, `materials.json`, `ARCHITECTURE.md`, `DECISIONS.md`,
  benchmarks, ROADMAP checkboxes, `/app/`. **The gate is untouched** — no tolerance,
  no margin rule, no verdict logic, no fixture, no assertion softened anywhere; the
  parity-test diff adds assertions and changes one from "== −1" to "== 0".

## Provenance

Apple M2 Pro (6P + 4E), macOS, Release (`-O3 -DNDEBUG`), matrix-free threads pinned to
the P-core count. **CG counts, gate verdicts, margins, latch iterations, escape counts,
resolved bands and every |Δρ| are deterministic and reproduce to the digit.**

**Wall clock is not, and one caveat is owed.** The T2 gate table's wall figures were
taken on a quiet machine and replicate to ~0.2 s. Several later captures ran while
another worktree executed its full ctest suite in parallel (load average peaked above
200); those logs' wall figures are inflated and are marked where they appear. Their CG
counts are unaffected — that is the point of leading with CG.

## Evidence — `evidence/2026-08-01-active-domain-disarm/`

| file | what |
|---|---|
| `gate_table.log`, `gate_table.csv` | **T2** — the full gate table, OFF / ON / CTL, ×2 each |
| `flips.csv` | **T2** — class + printed flips per rung vs the 1e-9 control floor |
| `dims.log` | **T3** — the box-height sweep: no design-box grid is odd |
| `pad_inert.log`, `pad_inert.csv` | **T3** — the parity pad is bit-identical on the AD class |
| `odd_axis_25iter_partial.log` | **T3** — the class the pad rescued: 3 of the 4 pad × AD cells (see the note in §T3 for the cut cell) |
| `gate_table_postflip_partial.log` | the post-flip build reproducing `off#1` to the digit (2384 CG, margin 1.759473614) |
| `cli_run_info.json` | **T4** — `active_domain_*` still written by a real CLI run |
| `ctest_full.log` | **T5** — the full suite, 88/88 passed |
| `test_production_parity.log` | **T5** — this change's CI face, run standalone |
| `job_ad_disarm.json`, `reproduce.sh` | inputs + the recipe |

**Not in this directory, and why:** `stagnation.csv` / `odd_axis.csv`. Both probes were
started and cut when the host went to load 535+ under three other worktrees' solver
suites. Neither is load-bearing — §T3 says exactly what each would have added and gives
the command to take it on an idle host. Everything the task's bars require is present.

---

## PLAIN LANGUAGE

**What the Active Domain was.** When the optimizer works inside a design box, most of
the box is empty air. Solving for all that air is wasted effort, so the Active Domain
drew a boundary around the material — plus a safety margin — and solved only inside it.
Faster, because the problem is smaller.

**Why it is being switched off.** It was never *exactly* the same answer. The skipped
air is not truly weightless (it carries a whisper of stiffness), so a run with the
boundary on wanders down a very slightly different path than a run with it off. That
was accepted because it was supposed to buy a lot of speed on the big, slow jobs.

It doesn't. On those big slow jobs the safety net built into the feature — the one that
notices material trying to grow outside the boundary and switches the whole thing off —
trips after about two steps. So the run pays for the boundary, gets the wobble, and
then runs without the boundary anyway. Across the measurements the speed effect on
those jobs ranges from 25% faster to 26% slower with no way to tell in advance which
you'll get. That's a coin toss, not a feature.

**How much does the wobble actually matter?** We measured it against a deliberately
meaningless control: run the same job again with the load nudged by one part in a
billion, far below anything physical. Whatever that nudge moves is pure noise, and it
sets the bar. The Active Domain moves the answer about a *billion times more* than the
noise bar, and on one rung it pushes two voxels out of 24 576 across the line between
"printed" and "not printed". Nothing that changed any pass/fail verdict, and nothing
that changed the recommended print settings — but it is a real difference, it is above
the noise bar, and it is written down here rather than rounded away.

**The thing you specifically asked us to check.** A recent fix (the odd-axis fix) turned
the fast solver back on for a lot of grids where it had been silently disabled. If the
Active Domain's bad reputation had been earned only in that broken world, switching it
off now could be a mistake. **It wasn't, and here's why it couldn't have been:** the two
things can never meet. The Active Domain only does anything when there's a design box,
and design boxes always get rounded up to a multiple of 8 in every direction — so a
design-box grid can never have an odd side. The odd-axis fix only fires on odd sides.
We checked this by running the same job under both the old and new solver settings: the
results came out **bit for bit identical**. Every earlier measurement stands exactly as
taken. **Nothing here reverses the three reviews that recommended switching it off.**

**One thing that deserves to be said out loud, because it argues the other way.** On the
healthy test job, the Active Domain runs about **18% faster on the clock** even though
it needs ~10% more solver steps — smaller steps, more of them, less total time. All
three prior reviews led with the step count, which makes it look purely bad; on the
clock it isn't. Switching it off gives that 18% up on jobs of that shape. The reason
that isn't enough to keep it: the speed-up only lasts while the boundary holds, and on
the big production jobs the boundary drops out after two steps.

**What did NOT change.** The safety checks are untouched — nothing about how a part is
judged strong enough was altered. All the machinery is still there and still tested; the
run reports still record what the Active Domain *would* have done, so if anyone wants
to switch it back on later they can compare like for like. Turning it back on is a
one-line change.

**The bottom line.** Production now solves the whole problem every time, exactly, with
no approximation and no coin toss. It gives up a real speed win on small healthy jobs to
do it. Every pass/fail verdict is unchanged.
