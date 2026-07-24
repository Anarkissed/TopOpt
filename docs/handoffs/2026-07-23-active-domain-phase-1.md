# ACTIVE DOMAIN Phase 1 — implement + gate (opt-in; NOT armed)

**Status:** Shipped opt-in, default OFF, byte-identical when off. The Phase 0
handoff (`134-active-domain-phase-0`, cited below as *134*) closed **GO** with four
binding conditions; all four are implemented and three of the four gate bars are
**met**. **One bar is MISSED** — the design-motion budget, on a rung that both
postures REJECT — and that is reported here as a miss, not rounded off.

**Production arming is deliberately NOT in this PR**, per the task and the 133
lesson: arming posture is a maintainer call, made with the table in hand.

---

## The verdict in five lines

- **The mask works and is exact on what survives.** `band == 0` is byte-identical;
  a band wide enough to cover the domain is **bit-for-bit** equal to `band == 0`.
- **The shipped variant barely moves.** On the accepted (terminal) rung,
  `mean|Δρ| = 3.94e-06`, `max|Δρ| = 1.19e-03`, margin delta **0.0055 %**.
- **The rejected rung moves 75× more** — `mean|Δρ| = 2.95e-04` against a stated
  `≤ 1e-4` bar. **That is a MISS.** Gate verdicts, terminal recommendation and
  margins are nonetheless identical/inside 0.1 %.
- **Measured end-to-end win at 46.5× dilution, k=4: 1.79× wall clock**, with the
  CG-iteration penalty charged (1.33× more CG iterations). 134's projection for
  this regime was 4.1×; the honest number is 2.3× smaller, because the **measured**
  `f_bar` under the real MMA driver is 2.5× worse than 134's harness OC estimate.
- **The growth invariant is NOT unconditional.** Zero escapes over 250 full-length
  MMA steps on a healthy trajectory — and **6 979 escapes** on a stagnating,
  divergent one. 134 stated the invariant as if it held generally. It does not.

---

## The four conditions of 134 §5, and where each stands

| # | 134's condition | Status |
|---|---|---|
| 1 | `k = ceil(rmin) + 1`, cadence 1, core rule `ρ > 1.5·ρ_min` | **DONE** — `active_domain_auto_band()`; cadence 1 by construction (the mask is re-derived inside the solve call); the threshold is the shipped constant. `k = 4` on the production 1.0 mm grid, pinned by `test_active_domain`. |
| 2 | Framed as an approximation with a measured budget; default OFF; byte-identical off | **DONE** — the header says "approximation, not a byte-identical accelerator" in those words; `active_domain_band = 0` is the default and touches nothing. |
| 3 | Full-length-rung `\|Δρ\|` under MMA at production dilution, as the gate | **DONE, and one bar MISSED** — §5. |
| 4 | The latch, so a band that buys nothing says so | **DONE** — §3, with the threshold and window stated and tested. |

---

## 0. What shipped

`git diff main --stat` over `core/`:

```
core/include/topopt/fea.hpp             |  22 +-   optional active_mask on the two graded matfree entry points
core/include/topopt/observability.hpp   |  17 +-   RunInfo active-domain echo
core/include/topopt/simp.hpp            | 161 +-   the option, the mask contract, the auto rule, the latch constants
core/src/fea/fea_matfree.hpp            |  20 +-   mf_build_elems / mf_build_reduced take the mask
core/src/fea/matfree.cpp                |  30 +-   ONE `continue` is the whole feature
core/src/fea/multigrid.cpp              |  18 +-   pass-through
core/src/simp/simp.cpp                  | 301 +-   the mask function, the per-run state, the latch, the fallback
core/src/simp/observability.cpp         |  38 +-   active_fraction CSV column + run_info serialization
core/src/cli/run_job.cpp                |  37 +-   run_info finalize + loud latch warning
core/CMakeLists.txt                     |  15 +-   the new test target
core/tests/unit/test_observability.cpp  |  12 +-   golden CSV schema
core/tests/validation/test_active_domain.cpp   NEW  41 checks
core/tests/harness/active_domain_gate.cpp      NEW  the measurement harness (not a CTest target)
```

**No option default moved.** `SimpOptions::active_domain_band` is `0`, and `0`
means "not one element is skipped, no mask is derived". The CLI has **no job.json
key** for it, deliberately: 134 §6 says the band "is a solver-internal accelerator
and must not become a user-visible knob".

---

## 1. STEP ONE — the shared capture

134 §5 called a converged, well-resolved, ultra-dilute **driver** capture "the
single biggest gap" in Phase 0: both of its real CLI captures at 1.7 % fill were
compromised (one budget-truncated by the 125 stagnation at ~3 min/iteration, one
under-resolved and failing the stress gate), so its only ultra-dilute evidence was
a harness OC loop.

**Delivered:** `evidence/2026-07-23-active-domain-phase-1/capture/`.

```
part 14x4x14 (528 solid voxels)  ->  analysis grid 32x24x32 (24 576 elements)
fill 2.148 %   dilution 46.5x   spacing 1.00 mm
min_feature 2.5 mm -> rmin 2.500 voxels -> AUTO band 4
production config (configure_production_options), production_reduction_ladder,
MMA, MultigridCG_Matfree, margin_stop 1.5, Galerkin cache on, 6 P-core threads
```

It **converged, carried multigrid on every solve, and produced a real gate
verdict**:

```
rung 0  vf 0.68  38 iters  ACCEPT  margin 1.759  printed 0.5152  compliance 4.63900268
rung 1  vf 0.52  59 iters  REJECT  margin 0.8423 printed 0.3712  compliance 8.71832621
                                   -> ladder stops; rung 0 is the shipped variant
97 iterations, 3 454 CG iterations, 0 Jacobi-fallback solves, 33.8 s (idle host)
```

Artifacts, all committed: `iterations.csv` (117 schema **plus the new
`active_fraction` column**), `run_info.json`, and 20 float16 density snapshots
(every 10 iterations + per-rung boundaries, 520 KB). This is the fixture the gate
runs on, and it is a usable input for the AMG Phase 1 lane as intended.

### 1a. Why this fixture and not 134's own 73 728-element one

The campaign was **first built and run at exactly 134's 49× fixture** (l-bracket
`arm/span 24, ny 6, t 6` in a box expanding to 48×32×48 = 73 728 elements, 48.8×
dilution). It is committed as `probe_73728_stagnation.txt` and it does **not**
converge — it reproduces the 125 stagnation immediately:

```
iter 1  cg=    54  mg=1  compliance 2.51e5
iter 2  cg=    51  mg=1  compliance 1.53e7
iter 3  cg=  5056  mg=0  hier=1  cycles=300   <- V-cycle stagnation, Jacobi fallback
iter 4  cg= 12746  mg=0  hier=1  cycles=300   compliance 4.16e8
iter 5  cg=    99  mg=1
iter 6  cg= 17151  mg=0  hier=1  cycles=300   compliance 4.49e8
                                      26.3 s/iteration
```

An intermediate size (46 400 elements, 51.6× dilution,
`probe_46400_stagnation.txt`) stagnates too, at 10.3 s/iteration. **24 576 is the
largest ultra-dilute size on this shape at which the production driver is
healthy.** Element count was therefore traded down ~3× to buy the FULL LENGTH the
gate is stated on; **dilution, spacing, the filter radius (hence `k = 4`) and the
entire production configuration are unchanged**, and those are the axes 134 §2e /
§4b showed the error and the win both scale with.

This is a real limitation and §7 says what it costs. It is also, independently, a
**citable reproduction of the 125 stagnation on a plain ultra-dilute design box
with no clearance hole**, at two sizes, on the current `main`.

---

## 2. The mechanism — one `continue`

Exactly 134 §6.2, no more:

```cpp
// core/src/fea/matfree.cpp, mf_build_elems
if (!grid.solid(i, j, k)) continue;
if (active_mask != nullptr && (*active_mask)[grid.index(i, j, k)] == 0) continue;
```

Everything downstream **follows for free and stays exact on the surviving
system**: the M3.1 void-DOF gate drops every DOF no surviving element touches, the
reduced numbering, the Jacobi diagonal, `apply_kgg`, and the multigrid hierarchy
(which is built from `MatfreeReduced`'s element table and kept DOFs, not from the
grid tags) all operate unchanged on the smaller system. **No new solver, no new
boundary-condition code** — the band boundary is the existing traction-free free
surface. That is why Phase 0 could prototype the whole thing with a re-tagged copy
of the grid.

**Ownership.** The mask is derived in `simp.cpp` (`active_domain_mask`, public and
unit-tested) and passed down beside `elem_youngs` as a `const std::vector<char>*`.
The FEA layer stays stateless and the mask stays a pure function of a field the
optimizer already holds. Mask rule, verbatim from 134 §3a:

```
active(e) = solid(e) AND [ rho_e > 1.5*rho_min            (core)
                           OR e is tagged Load or Fixture (BC pin)
                           OR cheb_dist(e, core) <= band ](growth band)
```

Separable Chebyshev max-filter, x → y → z, three integer passes, fixed order.
Nothing in it can reorder and no floating-point value is touched.

**One decision 134 §6 did not spell out, made here and stated:** the compliance /
sensitivity loop in `simp_compliance` **also skips masked-out elements**. It has
to. Compliance is `f^T u = u^T K u` for the `K` that actually ran; a fringe
out-of-band element's nodes *do* carry displacement (they are shared with in-band
elements), so summing its energy would add energy from a stiffness the solve never
had. Zeroing its sensitivity is also what makes the growth invariant true at all.
This reproduces Phase 0's prototype semantics exactly (it re-tagged out-of-band
voxels `Empty`, which excluded them from both), so 134's error measurements carry
over unchanged.

**Two scoping decisions, both refusals rather than silent no-ops** (125 §0's
lesson):

- A non-zero band with any solver but `MultigridCG_Matfree` **throws**.
- A non-zero band on the stress path (`simp_optimize_stress`) **throws**.

**Trajectory-only.** The mask applies to trajectory solves; the FINAL / certified
compliance solve always runs on the full domain. This is the discipline of 128
(`cg_tolerance_loose`) and 110 (warm starts): the accelerator changes the path,
never the certificate.

---

## 3. The latch (134 §6.5 / task condition 4)

```cpp
constexpr double kActiveDomainLatchFraction = 0.85;
constexpr int    kActiveDomainLatchWindow   = 5;
```

If the measured active fraction stays **at or above 0.85 for 5 consecutive
iterations**, the mask is disabled for the rest of the run, one-way, and the reason
is recorded. A restricted solve that **throws** latches the same way, re-solves the
same field on the full domain, and records the exception's message — the throw is
never propagated.

**Why 0.85 and not break-even.** 134 §4a's law is `speedup ≈ 0.65 / f`, so a band
covering `f > 0.65` is already a net loss. The latch is set deliberately *above*
that: it is a **degeneracy detector** ("this band covers the domain and buys
nothing" — 134's snug-part and gray-cloud cases), not a performance tuner.
Latching at break-even would flip the posture mid-run on ordinary trajectory
noise, and a run whose solver configuration changes under it is much harder to
read than a run that is merely slower than hoped.

**Why the window cannot false-positive on a healthy dilute run.** Iteration 1
always reads `f = 1.0` (the uniform start is above the threshold everywhere), but
by iteration 2 a genuinely dilute run has condensed — measured on the gate fixture:
`1.000 → 0.580 → 0.519 → 0.495 → … → 0.358`. The streak breaks at iteration 2.
Both gate ON runs completed all 97 iterations **unlatched**.

`test_active_domain` asserts the latch fires at *exactly* iteration 5 on a
domain-covering band, records a reason containing "buys nothing", and that the
throw path latches with reason `restricted solve failed: fea_solve_mgcg_matfree:
under-constrained system (load applied to a void DOF with no stiffness …)` and
still returns a real full-domain result.

---

## 4. Observability (task item 4)

- **`iterations.csv` gains one column, `active_fraction`**, appended last (schema
  in `observability.hpp`, golden test updated). It reads exactly `1.000000` when
  the feature is off, when it has latched, and on any solve that fell back — so
  the column is comparable across every run ever recorded.
- **`run_info.json` echoes** `active_domain_band` (config, written up-front) plus
  three per-rung OUTCOME vectors filled at finalize: `active_domain_latched`,
  `active_domain_latch_reason`, `active_domain_fraction_mean`.
- **Finalize-only discipline**, exactly as `cg_multigrid_observed` and
  `rung_infeasible`: the outcome is written once, after the run, so an unfinished
  run asserts *nothing* about what the band did.
- The CLI emits a **loud latch WARNING** per latched rung. It is unreachable from
  a plain `topopt-cli run` today (no job key, by design) and is written anyway so
  it is live the moment any front-end arms the band.

---

## 5. THE GATE

### 5a. The bars

The bars were fixed **by the task statement, before any Phase 1 measurement
existed**, and are recorded here verbatim rather than re-derived after the fact:

| bar | value |
|---|---|
| design motion | `mean\|Δρ\|` within the 134-measured budget — **≤ 1e-4** (134's own measurement at 49× / k=4 was `3.6e-6`) |
| margins | **≤ 0.1 %** relative |
| gate verdicts | **IDENTICAL** |
| repeatability | twice-run **bit-identical**, both postures |
| accounting | honest net, with the 1.4–2.0× CG-iteration penalty **charged** |

Protocol: the **full production ladder** on the step-1 capture's job, `k = 4` vs
OFF, each posture run **twice**, all four runs in one process so `|Δρ|` is computed
on the driver's own double vectors (the committed snapshots are float16, ~5e-4
quantisation — a disk comparison could not see a 1e-6 signal).

### 5b. The result

```
rung  vf    f_bar  | iters off/on | mean|Δρ|    max|Δρ|    | dC/C     | margin OFF -> ON        dM/M
 0    0.68  0.4170 |   38 / 39    | 3.9406e-06  1.1885e-03 | 9.08e-06 | 1.759474 -> 1.759376   5.54e-05
 1    0.52  0.3944 |   59 / 58    | 2.9522e-04  1.2656e-01 | 9.54e-04 | 0.842343 -> 0.841741   7.15e-04
```

| bar | measured | verdict |
|---|---|---|
| `mean\|Δρ\| ≤ 1e-4` | **2.95e-04** (worst rung) / **3.94e-06** (accepted rung) | **MISS on the worst rung**; met with 25× headroom on the rung that ships |
| margins ≤ 0.1 % | worst **0.0715 %** | **MET** |
| gate verdicts identical | rung 0 ACCEPT / rung 1 REJECT in **both** postures; ladder stops at the same rung; terminal recommendation identical (`fdm walls=4 top=5 bottom=4 infill=45 % gyroid`) | **MET** |
| twice-run bit-identical | OFF **YES**, ON **YES** (design, compliance, margin, iteration count, accept flag — all bit-for-bit) | **MET** |

### 5c. Reading the miss honestly

Three things are true at once and none of them cancels the others.

1. **The bar is missed by ~3×, on rung 1.** `2.95e-04` vs `1e-4`. It is also **82×
   above** 134's own 49×/k=4 measurement of `3.6e-6` — so 134's OC-based number
   was optimistic for MMA, and this handoff's job was to find that out.
2. **Rung 1 is a rung BOTH postures reject** (margin 0.842 < the 1.5 stop), so it
   is never exported, never inherited, never shipped. The rung that *is* shipped
   moves by `3.94e-06`. A reader deciding whether to arm should weigh the shipped
   variant's number; a reader deciding whether the feature is *understood* should
   weigh the worst one.
3. **Part of rung 1's motion is a one-iteration termination difference** (59 vs
   58): the 086 plateau detector fires one step apart because the objective curve
   is perturbed. That is a legitimate consequence, not an artifact to subtract —
   but it does mean the number is "two trajectories that stopped at different
   points", not purely "two trajectories that drifted apart".

Against the project's calibrated bar — 130's `mean|Δρ| ≤ 0.03` on the shipped part,
the bar that BLOCKED the loose-CG flip — the worst rung is **100× inside** and the
shipped rung **7 600× inside**. The single worst voxel (`max|Δρ| = 0.127` on rung
1) is, however, **4.2× ABOVE** 0.03; on the shipped rung the worst voxel is
`1.19e-3`, 25× inside.

### 5d. The accumulation axis 134 §2d could not close

134 measured `|Δρ|` over 40 OC steps, watched `max|Δρ|` grow sub-linearly, wrote a
linear extrapolation to 250 steps (`~5.3e-3`) and said plainly that an
extrapolation "is not enough to ship on". Measured directly here: rung 0 with the
086 plateau **disarmed** and `change_tol = 0`, so it runs a fixed **250 MMA
iterations**, ON and OFF, capturing every iteration's physical density
(`length/drho_vs_iteration.csv`, 250 rows):

```
iter      1     4(peak)    25       50      100      150      200      250
mean   0.0e0   3.36e-5   1.45e-5  3.35e-7  6.09e-8  1.06e-5  1.25e-7  4.30e-9
max    0.0e0   ...       4.95e-3  7.61e-5  2.75e-5  2.92e-3  6.66e-5  2.41e-6
                                          peak max|Δρ| 8.80e-3 at iteration 167
```

**It does not accumulate.** The divergence is transient — it spikes when the design
reorganises (iterations ~4, ~150, ~167) and decays back; the mean over the last 50
iterations is `3.5e-8`, and at iteration 250 it is `4.3e-9`. 134's linear
extrapolation is **refuted in the right direction**: the real behaviour is bounded
and self-correcting, not growing.

Same run, same length: **the growth invariant asserted under MMA at production
dilution — 0 escapes over 250 full-domain steps at `k = 4`**, upgrading 134's
40-step OC measurement.

---

## 6. THE ARITHMETIC — net, with the penalty charged

Measured on the gate fixture (24 576 elements, 46.5× dilution, `k = 4`, healthy
multigrid, 6 P-core threads, macOS, Release):

| | OFF | ON (k=4) | ratio |
|---|---|---|---|
| **wall, full ladder** (repeat 3: OFF 35.2 / 35.0 s, ON 19.5 / 19.5 s) | **35.0 s** | **19.5 s** | **1.79× faster** |
| **CG iterations**, full ladder | 3 454 | 4 577 | **1.325× MORE** (charged) |
| CG iterations, 250-iteration length run | 8 049 | 10 428 | 1.296× MORE (charged) |
| optimizer iterations | 97 | 97 | — |
| Jacobi-fallback solves | 0 | 0 | — |
| mean `f_bar` | 1.000 | **0.406** | — |

**The wall figure is quoted from ONE repeat, and here is why.** This host is
shared — a sibling worktree's `ctest` ran during parts of the campaign — and
contention on it is worth up to 2×, i.e. LARGER than the effect being measured.
Six OFF and six ON ladder runs were taken across three `gate` invocations:

```
OFF  65.7  43.8 | 56.9  50.5 | 35.2  35.0      (+ the idle capture run, 33.8)
ON   23.1  21.7 | 20.7  20.8 | 19.5  19.5
                              ^^^^^^^^^^^  repeat 3: quiet host, <1 % spread
```

**Repeat 3 is the only self-consistent quadruple** (all four runs within 1 % of
their posture's mean) and is the one cited. A naive "cleanest pair" across
repeats would have given 2.02×, and the min/min estimate gives 1.73×; the
interleaved quadruple gives **1.79×**, and that is the number to carry. **No
single absolute wall figure from repeats 1–2 should be cited.** The CG-iteration
counts are deterministic, identical in every repeat, and cannot be contended —
which is why they are quoted next to every wall figure.

**Efficiency constant.** 134's law is `speedup ≈ C / f` with `C ∈ [0.55, 0.76]`
measured across its fixtures. Measured here: `1.79 × 0.406 = 0.73` — **inside
134's range, near its top**. That is the strongest corroboration in this handoff:
an independently-derived law, applied to an independently-measured `f_bar`,
predicts `0.65 / 0.406 = 1.60×` where the driver measures 1.79×. In the stagnation
regime (§7) the same constant collapses.

### 6a. The regime table

| regime | source | `f_bar` at k=4 | speedup |
|---|---|---|---|
| snug part, no box | 134 F1 | 1.00 | **latches off; 1.0×** |
| design box 10× | 134 F2 (driver, MMA) | 0.639 | ~1.0× (134's projection) |
| harness box 25× | 134 (OC, 40 steps) | 0.275 | ~2.4× (134's projection) |
| harness box 49× | 134 (OC, 40 steps) | 0.160 | ~4.1× (134's projection) |
| **box 46.5×, healthy MG** | **this handoff, driver + MMA, full ladder** | **0.406** | **1.79× MEASURED** |
| box 51.6×, stagnating | this handoff, 40 steps | — | **1.30× MEASURED**, CG **2.06× worse** |

**The correction this table carries:** at comparable dilution, the `f_bar` the real
MMA driver produces (**0.406**) is **2.5× worse** than the harness OC loop 134
projected from (0.160). 134 §4b's "~4× at 49×" is therefore **optimistic by 2.3×**,
and the honest measured figure in this regime is **1.79×**. Grayscale MMA simply
condenses less than OC does, so more of the domain stays above `1.5·ρ_min`.

---

## 7. WHERE IT BREAKS — the stagnation regime

Run at 46 400 elements / 51.6× dilution (the fixture whose multigrid stagnates and
whose objective diverges to ~1e8), 40 MMA steps, ON vs OFF —
`stagnation_length40_46400.txt`:

```
wall            89.7 s -> 69.2 s     1.30x faster   (vs 1.79x in the healthy regime)
CG iterations   20 982 -> 43 113     2.055x WORSE   (above 134's 1.4-2.0x band)
mean|drho|      4.47e-3 at iter 25,  9.34e-4 at iter 40
max |drho|      4.93e-1
GROWTH INVARIANT: 6 979 ESCAPES over 40 full-domain steps
                  (worst out-of-band density 0.173)
```

**This is the most important negative result in this handoff.** 134 §3b reported
"ZERO band escapes on every iteration of all ten configurations" and offered an
argument for why it must hold: the density filter has radius `rmin`, so the
physical field can only become non-floor within `~rmin` of existing non-floor
material. **That argument is weaker than it reads.** It assumes the updater does
not *raise* a floored design variable far from material — true for the OC ratio
update (which is multiplicative, so a floored variable stays floored unless the
ratio is large) and true for MMA on a well-behaved trajectory (sensitivities far
from material are ~0 because `u ≈ 0` there). It is **not** true for MMA on a
trajectory whose displacement field is garbage: there the sensitivity field is
chaotic, MMA's additive step raises floored variables far from material, and the
band derived one iteration earlier does not contain them.

So the invariant is an **empirical property of a converging run**, not a theorem.
Consequences, stated plainly:

- Arming the band on runs that can stagnate (which, per §1a, is exactly the
  ultra-dilute regime the feature exists for at production scale) means arming it
  where its soundness argument does not hold.
- The 1.4–2.0× CG penalty is **2.06×** there — worse than 134's band — while the
  win collapses to 1.30× (and that pair was taken back to back, so the ratio is
  sound even though its absolutes are not). Restriction does not rescue the stagnation regime; 134
  §4b speculated it "plausibly helps that regime MORE". **Measured: it helps
  less.**
- A production flip should be conditioned on the run being in the multigrid-carried
  regime, or on fixing the stagnation first. Neither is decided here.

---

## 8. Where this is weakest (read before acting on it)

1. **The gate fixture is 24 576 elements, not the ~5 M of the reference job.**
   Dilution, spacing, filter radius and the entire production config match; the
   absolute scale does not, and §1a explains why (the larger ultra-dilute sizes do
   not converge at all on this shape).
2. **`mean|Δρ| = 2.95e-04` misses the stated `1e-4` bar.** It is 100× inside the
   calibrated 0.03 bar, on a rung both postures reject, but it is a miss.
3. **`max|Δρ| = 0.127` on that rung is 4.2× ABOVE the 0.03 bar.** 130's bar is
   stated on the mean, so this is not a bar violation — it is a number a reader
   should see before arming anything.
4. **The growth invariant fails in the stagnation regime** (§7), and that regime is
   where the production complaint lives.
5. **Only one part shape was gated.** Everything here is the l-bracket-in-a-box
   family, at one dilution, one band width, one resolution.
6. **The band was not measured against a STEP-imported part.** At this dilution a
   STEP l-bracket needs either ~0.9 M elements (to keep `rmin` above its 1.5-voxel
   floor) or a mesh too coarse to represent its 8 mm plate — 134 §1c hit exactly
   that wall twice, and this handoff did not solve it either.
7. **The higher-threshold question 134 §1d flagged is still unmeasured.** The core
   rule stays at `1.5·ρ_min`, so a genuinely gray run still gets no speedup.

---

## 9. Production arming — deliberately not here

Not armed, per the task and the 133 precedent. What a maintainer would need to
decide it, in one place:

- **Arm it and you buy ~1.8× at ~46× dilution**, ~1.0× at 10×, ~1.3× when the
  solver has stagnated.
- **You pay** a design that differs by `3.9e-6` (mean) on the shipped variant,
  `2.95e-4` on a rejected one, with identical gate verdicts and margins inside
  0.1 %.
- **You accept** that the soundness argument (the growth invariant) is empirical
  and is measurably violated on divergent trajectories.
- The latch protects the low-dilution end automatically: it turns the feature off
  and says so, rather than silently costing.

If it is armed, `configure_production_options` is the one line
(`opts.simp.active_domain_band = -1` for AUTO), and `run_info.json` already echoes
what happened.

---

## 10. Gates / provenance

- **Full `ctest`: 65/65 pass**, including the new `active_domain` target.
- **Byte-identity with the feature off** is structural — `band == 0` derives no
  mask and calls the same `simp_compliance` overload with a null pointer — and is
  additionally pinned by `test_active_domain`, which proves that a band wide enough
  to cover the domain gives a **bit-identical** design, physical density,
  compliance and iteration count.
- **Gate-V2 untouched.** It runs OC + `JacobiCG` and never sets the band; the only
  file it shares is `simp.cpp`, where every added line is behind
  `active_domain.band > 0`.
- **`test_active_domain`: 41 checks**, covering 134 §6.6 (a)–(d) plus the auto
  rule's exact values, the Chebyshev geometry, the BC pin, monotonicity in the
  band, and both scoping refusals.
- **No app-side change.** The one CSV consumer outside core is the worker README's
  prose description; the new column is appended last.
- **Machine:** Apple M2 Pro (6 P + 4 E), macOS, Release, matrix-free threads 6
  (the 132 P-core pin). Every `|Δρ|`, CG-iteration count, escape count and verdict
  here is deterministic; only wall clock is thermally exposed, the host was NOT
  exclusively idle, and §6 says exactly which repeat the one quoted wall ratio
  comes from and why the others are not cited.

---

## 11. Evidence

`docs/handoffs/evidence/2026-07-23-active-domain-phase-1/` (612 KB total)

| file | what |
|---|---|
| `capture/iterations.csv` | §1 — the shared capture's per-iteration record, 117 schema + `active_fraction` |
| `capture/run_info.json` | §1 — solver/config/outcome provenance, incl. the active-domain echo |
| `capture/snapshots/` | §1 — 20 float16 density snapshots (every 10 iters + rung boundaries) |
| `capture.log` | §1 — the capture's console record |
| `gate/gate.csv` | §5b — the per-rung ON-vs-OFF comparison |
| `gate/{off1,off2,on1,on2}_iterations.csv` | §5b — all four runs' per-iteration records |
| `gate/{off,on}_run_info.json` | §5b — both postures' provenance |
| `gate.log` | §5b/§6 — the gate console output incl. the bit-identity verdict |
| `gate_timing_repeat2.log`, `gate_timing_repeat3.log` | §6 — the two further interleaved timing repeats; **repeat 3 is the quiet-host quadruple the wall ratio is quoted from** |
| `length/drho_vs_iteration.csv` | §5d — `\|Δρ\|` per iteration over 250 MMA steps |
| `length.log` | §5d — incl. the 250-step growth-invariant escape count |
| `stagnation_length40_46400.txt` | §7 — the regime where the invariant breaks |
| `probe_73728_stagnation.txt` | §1a — 134's own 49× fixture reproducing the 125 stagnation |
| `probe_46400_stagnation.txt` | §1a — the intermediate size, same result |
| `summarize_gate.py` | renders §5b's table from `gate/gate.csv` |

### Recipe

```bash
# 1. Build the library in this worktree
cmake -S core -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="/opt/homebrew/opt/eigen;/opt/homebrew/opt/opencascade"
cmake --build build -j10

# 2. Build the harness (standalone, NOT a CTest target)
c++ -std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 \
  -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" \
  core/tests/harness/active_domain_gate.cpp build/libtopopt.a -o /tmp/adg

EV=$PWD/docs/handoffs/evidence/2026-07-23-active-domain-phase-1
/tmp/adg probe                          # fixture + a 6-iteration timing sample
TOPOPT_AD_DIR=$EV /tmp/adg capture      # STEP 1 (~70 s)
TOPOPT_AD_DIR=$EV /tmp/adg gate         # STEP 2, 4 ladders (~3 min) — IDLE MACHINE
TOPOPT_AD_DIR=$EV /tmp/adg length 250   # the accumulation curve (~2 min)
python3 $EV/summarize_gate.py

# 3. The unit/validation seam
ctest --test-dir build -R active_domain --output-on-failure
```

To reproduce §1a / §7, edit `make_fixture()`'s `l_bracket(...)` arguments and box
to the sizes named in the comment there (the 73 728 and 46 400 variants) and re-run
`probe` / `length 40`.
