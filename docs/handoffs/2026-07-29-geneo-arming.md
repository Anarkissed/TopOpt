# MATRIX-FREE GENEO — production arming

## THE DECISION (recorded verbatim, not re-litigated)

> The maintainer has decided to arm it.

This handoff IMPLEMENTS that decision. It does not re-open it. Everything below is
the arming (the production flip, its named constants, its tripwires, its parity
assertions, its run_info echo) and the before/after evidence the decision is now
accountable to — the same shape as the recycling arming (handoff 133 / PR 163),
the Active-Domain arming (2026-07-26-ad-arming) and the draft arming
(2026-07-26-draft-arming), each of which recorded its maintainer ruling verbatim
and shipped the armed package against it.

**Status:** Armed, core only. `configure_production_options` now calls
`fea_set_geneo_twolevel(true)` (`kProductionGeneoTwoLevel`). The LIBRARY default
stays OFF, so Gate-V2, the property suite and every core reference run — none of
which call that function — are BYTE-FOR-BYTE unchanged (THE ONE RULE, re-proven
below by stash-rebuild FNV through the very loop the arming edited).

**What is armed.** The Phase-2 winner (2026-07-29-matrixfree-geneo-phase2),
moved from the measurement harness into the library (`src/fea/geneo.{hpp,cpp}`,
Eigen PRIVATE like multigrid.cpp — the fine system is never assembled): the
DEFLATION form `M^-1 = D^-1 + V (V^T A V)^-1 V^T` on the matrix-free Jacobi-CG
**stagnation fallback only** (`mf_cg_solve`), with V the capture-LOBPCG GenEO
coarse basis. The local additive-Schwarz term (measured useless, phase 2 §P7b)
was NOT ported. Three policy pieces make it a production feature rather than a
harness:

1. **The stagnation trigger** (`kGeneoTriggerIters = 500`): with no basis held, a
   fallback solve runs plain and pays the eigensolve ONLY after burning 500
   iterations unconverged — ~1.5× the measured healthy-fallback ceiling (~327,
   phase 2 §P7) and ~0.3× the measured stagnation floor (1.7k–41k). A healthy
   rung never pays; conditional-on-stagnation is structural (placement +
   trigger), not configured.
2. **The reuse policy** (phase 2 §P6, armed): the basis is kept across solves;
   each new system pays only a coarse-operator refresh (`V^T A V`, N_t matvecs +
   a small dense factor — mandatory, a stale coarse operator is not a deflation
   for the new system); the basis is dropped on a DOF-set change and rebuilt on
   measured degradation (`kGeneoRebuildFactor = 2.0` × the post-build reference
   count).
3. **The memory guard** (`kGeneoMaxBasisMB = 2048`): a build whose stored basis
   would exceed the cap is refused and the solve stays plain Jacobi-CG (exact,
   just slower), recorded as `geneo_action = 4`.

**The caveat this arming carries, stated up front.** LIKE recycling (and unlike
AD/draft), the deflation is an EXACT accelerator — every added term is SPD, so it
changes CG iteration counts, never the stopping test, and the certification gate
is untouched (A2). But like recycling-when-it-wraps, it is NOT bit-identical when
it ENGAGES: a different iteration path lands elsewhere in the same 1e-8 basin,
and the MMA trajectory can amplify that basin-level difference chaotically on a
rung whose trajectory engaged it. A4 measures exactly that, negative control
first, and the gate table (A3) shows what it does and does not move.

---

## The result in six lines

- **OFF is byte-identical, re-proven**: the armed build and a stash-rebuilt
  pre-change build produce the SAME FNV (`dfc4292199f3eda8`) over a
  boxed + no-box + matfree-MG-fallback ladder triple at library defaults (A1).
- **The armed path pays on the real rung**: the Phase-2 developed 40×32×40
  stagnating rung's cold solve drops **5,412 → 754 total iterations (7.2×,
  trigger burn + build charged in-band)**, and the two follow-on design
  iterations **738 → 118** and **564 → 129** on a cheap refresh — within 1
  iteration of the hook-built Phase-2 preconditioner (which measured 21.7× on
  the cold solve without the production trigger charge).
- **The full production gate ladder gets faster and judges identically**: total
  CG 111,073 → 62,933 (**0.567×**), 0 verdict flips, identical ladder stop,
  twice-run bit-identical in both postures (A3).
- **The four-way stack composes** (★★): rc_frac unchanged (0.500) with GenEO on;
  the AD escape latch fires identically; draft × GenEO are complementary by
  regime; full production posture deterministic run-to-run. No BLOCKED-STOP.
- **Two findings from the stack, said plainly**: recycling's marginal value on
  top of GenEO is now small (−1 to −3% CG); and AD remains a measured DRAG on
  stagnating fixtures (+7% to +54% CG across this campaign's tables, worst on
  the deepest fixture) — a fresh,
  independent sample supporting 2026-07-27-ad-arming-review's DISARM
  recommendation. GenEO does NOT make draft redundant, nor draft GenEO.
- **Memory is a non-issue at fixture scale**: basis 22.9–36.1 MB, peak RSS
  ≤ 418 MB on the 16 GB machine (≥ 15.9 GB headroom), 2 GB hard cap with an
  exact-fallback refusal path (A5).

---

## 0. What shipped (core only, additive)

```
core/src/fea/geneo.hpp                internal Eigen-free interface + the RECIPE
                                      TRIPWIRE (core=8, ov=1, block_m=20, cut=0.05,
                                      dense cap 6000, trigger 500, rebuild 2.0,
                                      mem cap 2048 MB — each with its derivation)
core/src/fea/geneo.cpp                the provider: decomposition + PoU +
                                      capture-LOBPCG basis + V^T A V (dense LDLT /
                                      capped inner CG) + the lifecycle state machine
core/src/fea/matfree.cpp              mf_cg_solve: geneo_solve_begin / trigger-build
                                      + PCG restart / geneo_apply / geneo_solve_end
                                      (all dead branches when OFF); public
                                      fea_set_geneo_twolevel + diagnostics
core/src/fea/multigrid.cpp            fallback-site CgInfo geneo diagnostics
core/include/topopt/fea.hpp           public API + CgInfo geneo fields +
                                      kGeneoTwoLevelLibraryDefaultOff static_assert;
                                      the phase-2 EXTERNAL-hook tripwire SURVIVES
                                      (production arms the internal provider, not
                                      the hook — kMatfreeExternalPrecondDefaultOff
                                      stays true and asserted)
core/include/topopt/simp.hpp          SimpIterationObservation cg_geneo_dim/_action
core/src/simp/simp.cpp                forward CgInfo -> observation (both updaters)
core/src/simp/minimize_plastic.cpp    run-start fea_reset_geneo_basis() (the
                                      recycle-space lifecycle discipline)
core/src/simp/production.cpp          arm: fea_set_geneo_twolevel(true);
                                      kProductionGeneoTwoLevel + the TRIPWIRE
core/include/topopt/production.hpp    production_geneo_twolevel() + "What it sets"
core/include/topopt/observability.hpp RunInfo geneo echo fields
core/src/simp/observability.cpp       run_info.json serialization
core/src/cli/run_job.cpp              config echo + post-run lifecycle finalize
core/tests/unit/test_geneo.cpp        CTest `geneo_twolevel`: default-off inertness,
                                      trigger, exactness (1e-6), reuse/refresh,
                                      determinism
core/tests/validation/test_production_parity.cpp  BEFORE/AFTER + named-constant echo
core/tests/harness/geneo_arming_gate.cpp          gate/interaction/stag/healthy/
                                                  amort/fast/mem (NOT CTest)
core/tests/harness/geneo_arm_identity_probe.cpp   A1 probe (NOT CTest)
core/tests/harness/geneo_twolevel_probe*.inc      two additive lines: keep the
                                      develop library-plain under the arming;
                                      TL_GENEO=1 arms the baseline column
```

**No library default moved.** Nothing outside `configure_production_options`
enables the feature; the CLI has no job.json key for it. The bridge and CLI reach
the arming for free because both call `configure_production_options` — the exact
discipline of the recycling / AD / draft armings.

---

## 1. THE BARS

### A1 — OFF IS BYTE-IDENTICAL (stash-rebuild FNV, boxed and no-box). ✓

`geneo_arm_identity_probe` runs THREE deterministic library-default ladders —
no-box, boxed, and boxed with `solver = MultigridCG_Matfree` (a library options
field), the third of which drives the dilute design-box fallback STRAIGHT THROUGH
the edited `mf_cg_solve` loop — and FNV-hashes densities + compliance + margins +
accepts + iterations. It never names a geneo/production symbol, so it compiles
unchanged against the pre-arming tree:

```
H_after   (arming branch, armed lib)                      = dfc4292199f3eda8
H_before  (git stash of all 13 tracked edits, rebuilt)    = dfc4292199f3eda8
```

Identical (`A1_before.txt` / `A1_after.txt`). With the flag OFF both new branches
in the CG loop are dead booleans; the arming moved the PRODUCTION default only.
Also pinned in CI: `test_production_parity` checks `!fea_geneo_twolevel_enabled()`
(+ zero basis/builds) BEFORE the config call and the named-constant echo AFTER,
and `test_geneo` re-proves off-inertness every run. **MET.**

### A2 — THE GATE NEVER SOFTENS. ✓

The deflation adds a term to the preconditioned residual `z`; it never touches a
tolerance, a stopping test, or an accept decision. The certification-tolerance
asserts are UNTOUCHED (verified: zero assert lines in the arming diff) —
`minimize_plastic.cpp:783/821/1113` (`opt.cg_tolerance == kCertTol`, 1e-8) and
`simp.cpp:1942/2801` (`adaptive_traj_cg_tol(options,0) == options.cg_tolerance`).
The NDEBUG reality is as the draft arming documented: Release compiles `-DNDEBUG`,
so the LIVE enforcement is `test_production_parity`'s CHECKs (NDEBUG-independent),
which still assert `opts.simp.cg_tolerance == 1e-8` after the (now
GenEO-arming) config call, plus the draft schedule floor identities. All pass
(`ctest_full.log`). **MET.**

### A3 — FULL GATE TABLE, before and after, every rung, verdict + margin. ✓

`geneo_arming_gate gate`: the FULL production ladder
(`production_reduction_ladder`, margin_stop 1.5, recycling + AD + draft armed in
BOTH postures — only GenEO differs), each posture run twice
(`gate.log`, `gate.csv`). This ladder walks deep rungs whose trajectory falls to
Jacobi-CG 235–266 times, so the deflation genuinely engages (3 basis builds, 270
deflated solves in the ON posture):

| rung | vf | verdict OFF → ON | margin OFF → ON | dM/M | mean\|Δρ\| | max\|Δρ\| |
|---|---|---|---|---|---|---|
| 0 | 0.68 | **ACCEPT → ACCEPT** | 13.9005 → 13.9005 | 0 | 0 | 0 |
| 1 | 0.52 | **ACCEPT → ACCEPT** | 5.67028 → 5.67028 | 0 | 0 | 0 |
| 2 | 0.38 | **ACCEPT → ACCEPT** | 4.66164 → 4.66151 | 2.90e-5 | 9.49e-4 | 2.64e-1 |
| 3 | 0.26 | **REJECT → REJECT** | 2.79323 → 2.77503 | 6.52e-3 | 3.17e-5 | 5.76e-3 |

```
twice-run bit-identical:  OFF YES   ON YES
verdict flips: 0    ladder stop: identical (rung 3 REJECT, both)
ladder CG: OFF 111,073 -> ON 62,933  (0.567x — the armed ladder is 43% cheaper)
```

**The rungs that move, named.** Rungs 0–1 are BIT-IDENTICAL — their trajectories
never engaged the deflation. Rung 2 (ACCEPT) engaged it and drifted: certified
margin by 0.0029% (35× inside the 0.1% bar), density mean 9.5e-4 with one voxel
region reaching max|Δρ| 0.264 — trajectory chaos amplifying a basin-level solve
difference, the same class as draft's rung-2 drift (its arming measured
max|Δρ| 1.85e-2 there). Rung 3 (the terminal, non-shipping REJECT) moved its
margin 0.65% — larger than draft's 0.21% on the same rung class, reported as
such; it never ships and its verdict is unchanged. **MET: zero flips, identical
outcome, drift quantified per rung.**

### A4 — THE ANSWER IS THE SAME ANSWER (negative control FIRST). ✓ with the chaos charged

**Solve level.** Phase 2's control on the real developed rung stands and is the
foundation: basin floor (Jacobi 1e-9 vs 1e-8) `max|du|/max|u| = 4.9e-12`;
two-level vs Jacobi at 1e-8 `= 1.4e-8` — the same field to the tolerance. The
ARMED path re-proves it in CI on the high-contrast checkerboard: deflated vs
plain `max|du|/max|u| = 2.4e-9` (`test_geneo`), and every `fast`-mode row's
armed-vs-plain field agrees to ≤ 2.8e-9 across violent design motion.

**Design level, through the REAL production ladder** (`gate.log`), classification
flips over solid voxels (grid 24×8×24, 4,608 solid per rung), NEGATIVE CONTROL
FIRST — the same GenEO-OFF ladder re-run with cert tol 1e-9 (a pure
tolerance-perturbation of every solve, including each rung's certificate):

| rung | solid | control 1e-9 vs OFF (floor) | GenEO ON vs OFF |
|---|---|---|---|
| 0 | 4,608 | 0 flips; Δρ 2.0e-9 / 8.9e-7 | **0 flips; Δρ 0 / 0 (bit-identical)** |
| 1 | 4,608 | 0 flips; Δρ 8.5e-10 / 3.6e-7 | **0 flips; Δρ 0 / 0 (bit-identical)** |
| 2 | 4,608 | 0 flips; Δρ 3.6e-5 / 1.9e-2 | **7 flips (1.5e-3); Δρ 9.5e-4 / 2.6e-1** |
| 3 | 4,608 | 0 flips; Δρ 3.3e-5 / 5.5e-3 | 0 flips; Δρ 3.2e-5 / 5.8e-3 |

(Δρ columns are mean/max over solid voxels.)

**Read honestly, rung by rung.** Where the deflation never engages (rungs 0–1)
the armed design is BIT-IDENTICAL — cleaner than the control, which perturbs
every rung slightly. Rung 3's drift sits AT the control floor (3.2e-5/5.8e-3 vs
the control's 3.3e-5/5.5e-3 — indistinguishable from a tolerance tweak). Rung 2
— the one ACCEPT rung whose trajectory engaged the deflation — EXCEEDS the
floor: mean Δρ 26× the control's, 7 of 4,608 voxels (0.15%) flipping
classification where the control flips none. The mechanism: the in-solve
build + PCG restart changes the iterate path more than a 10× tolerance change
does, and ~100 MMA iterations amplify that basin-level kick chaotically on that
rung. What it does NOT change: the per-solve answer (exact to tolerance, the
solve-level controls above), the certified margin beyond 0.0029% on that rung,
any verdict, or the ladder outcome. This is the same product-changing class the
maintainer already accepted for draft (which measured flip fractions up to 0.15
on non-terminal rungs at aggressive tolerances); GenEO's measured footprint at
the armed posture is 7 voxels on one mid-ladder rung, and zero everywhere it
does not engage. **MET, with rung 2 charged to the feature above the control
floor, not rounded away.**

### A5 — MEMORY IN BUDGET. ✓

Measured peak RSS of whole armed runs (`mem.log`, `p2_armed.log`), 16,384 MB
machine of record:

| run | ng / elements | basis (N_t) | peak RSS | headroom |
|---|---|---|---|---|
| big fixture, full prod posture | 73,728 el | — (draft emptied the fallback) | 352 MB | 16.0 GB |
| big fixture, basis engaged | 73,728 el | 35.4 MB (N_t 864) | **418 MB** | **15.97 GB** |
| real rung, armed baseline | ng 156,198 | 22.9 MB (N_t 595) | 300 MB | 16.1 GB |

The armed footprint = basis + N_t² coarse operator (2.8 MB at N_t 595); the
subdomain LocalOps are build-transients (coarse-only form — the local term was
not ported). The 8.44M-DOF projection stays phase 1/2's ~1.2 GB basis, inside
the `kGeneoMaxBasisMB = 2048` hard cap with the measured per-subdomain size
invariance behind it; a build that would exceed the cap is REFUSED and the solve
stays plain Jacobi-CG (exact), recorded as `geneo_action=4` and echoed in
run_info. **MET.**

### A6 — THE REUSE POLICY IS ARMED AND MEASURED. ✓ (with one unfired backstop)

**The armed policy end-to-end** (`amort.log`, big stagnation fixture, draft off
so the fallback regime exists, per-trajectory-solve record):

| step | regime | CG off | CG armed | action | N_t |
|---|---|---|---|---|---|
| 0–1, 3–4, 6–11 | MG carries | 52–240 | 52–239 | none (0) | — |
| 2 | **Jacobi fallback** | 6,299 | **889** | **BUILD (3)** in-solve @500 | 864 |
| 5 | **Jacobi fallback** | 11,987 | **2,716** | **REFRESH (2)** | 864 |

Trajectory total 19,329 → 4,639 (**0.240×**); one eigensolve for the whole run,
one refresh. **The refresh economics, explicit:** step 5's refresh charged N_t =
864 setup matvecs and saved 9,271 iterations — a 10.7× return; on the real rung
the refreshed solves hit 118/129 vs the hook harness's fully-rebuilt 117/129
(`p2_armed.log` vs `p2_plain.log`) — **a refresh matches a full rebuild to ~1
iteration at ~1/40th the setup cost** (phase 2 §P6 measured refresh ≈ rebuild/18
in wall; here 0.2–1.1 s vs 14–20 s).

**The rebuild trigger.** Rebuild fires on (a) DOF-set change (basis dropped,
trigger policy re-applies — exercised in `test_geneo` via reset) and (b)
degradation: a reused solve exceeding `2.0×` the post-build reference. On amort
step 5 the condition was REACHED (2,716 > 2 × 889) and a rebuild was scheduled;
no later solve fell to Jacobi in the capped run (builds stayed 1), so the
scheduled rebuild was never consumed — reported, not glossed.

**What happens when the design moves faster than expected** (`fast.log`,
`fast_cell2.log`): violent random moduli jumps every solve, then a WORST-CASE
injected rot — inverting the 1e9-contrast checkerboard phase so every near-null
mode moves:

```
random jumps:  armed 362-455 vs plain twin 976-1,352   (refresh only, 2.7-3.0x)
PHASE INVERT:  armed 247     vs plain twin 628          (refresh only, 2.5x)
exactness      every row max|du|/max|u| <= 2.8e-9
```

The refreshed basis is measurably ROBUST — even the constructed worst case never
degraded it enough to fire the 2× trigger, and every solve stays exact
regardless (the preconditioner cannot change the answer; a rotted basis costs
iterations, never correctness — and if it ever costs more than 2× it rebuilds
one solve later). **MET, with the degradation path honest: armed, reached once,
never consumed on a physical fixture.**

### A7 — WHERE IT DOES NOT HELP, SAY SO. ✓

- **Healthy regime (MG carries)** (`healthy.log`): full production posture on
  the small healthy fixture — 0/52 fallbacks, **0 builds, CG 3,232 = 3,232,
  design BIT-IDENTICAL**. GenEO is structurally inert where multigrid carries:
  the hook lives on the Jacobi fallback only.
- **Healthy-ish fallback (converges under the trigger)**: a fallback solve that
  converges in < 500 iterations never pays the eigensolve (`test_geneo` pins
  this: the 338-iteration near-disconnection fallback engages nothing).
- **Draft-rescued stagnation** (`stag.log`): on the capped big fixture the full
  production posture (with draft) has 0 fallbacks — GenEO engaged nothing and
  the CG total is IDENTICAL to the GenEO-off posture (947 = 947). Where draft
  already moves the solves out of the stagnation regime, GenEO costs literally
  zero.
- **The conditional-arming recommendation is therefore already implemented
  structurally**: placement (fallback-only) + trigger (500 unconverged
  iterations) + reuse. There is no regime in the table where the armed feature
  pays a cost without a stagnating solve on the bill. Arming ALWAYS (e.g. on the
  MG path, or without the trigger) would regress the healthy regime — phase 2
  §P7 measured the two-level route far more expensive than a carrying V-cycle —
  and this arming deliberately does not do that.

### A8 — Production hygiene, 163's pattern. ✓

- **TRIPWIREs**: beside `kProductionGeneoTwoLevel` (production.cpp — names both
  harnesses and the four-way re-measure obligation) and beside the recipe
  constants (`geneo.hpp` — every value carries its derivation). The phase-2
  external-hook tripwire (`kMatfreeExternalPrecondDefaultOff`) SURVIVES
  unchanged: production arms the internal provider, the hook stays uninstalled.
  A new `kGeneoTwoLevelLibraryDefaultOff` static_assert pins the library
  default.
- **Parity assertions against named constants**: `test_production_parity` checks
  OFF + zero-state BEFORE the config call; AFTER, it echoes
  `fea_geneo_twolevel_enabled() == production_geneo_twolevel()`, trigger == 500
  and rebuild factor == 2.0 via the accessors (never literals in the test body
  alone), alongside the untouched recycling/AD/draft/tolerance checks.
- **run_info echoes the armed posture and the reuse state** (verified end-to-end
  on a real `topopt-cli run`, `cli_run_info.json`): `geneo_twolevel: true`,
  `geneo_trigger_iters: 500`, `geneo_rebuild_factor: 2`, and the post-run
  lifecycle `geneo_basis_builds / geneo_coarse_refreshes / geneo_armed_solves /
  geneo_basis_dim / geneo_basis_mb` (all 0 on the healthy demo job — the honest
  "it never fired" record, the 132 discipline). Per-solve `geneo_dim` /
  `geneo_action` ride CgInfo and the iteration observation for the harnesses.

---

## ★★ THE FOUR-WAY INTERACTION — the bar that matters most

This is the FOURTH armed solver feature. Both fixtures, all the task's postures
and ablations, CG + outer iterations (`interaction.log`/`.csv`,
`stag.log`/`.csv`):

**Small stagnation fixture** (24×8×24 expanded, 18.3× dilution, natural
termination — the trajectory runs to its own plateau):

| posture | CG | outer | vs none | Jacobi fallbacks | rc_frac | GenEO |
|---|---|---|---|---|---|---|
| none | 17,605 | 59 | 1.000× | 2/59 | — | — |
| rec | 17,661 | 59 | 1.003× | 2/59 | 0.500, dim 11 | — |
| rec+AD | 18,921 | 57 | 1.075× | 3/57 | 0.667, dim 16 | — |
| rec+AD+draft | 11,574 | 57 | 0.657× | 2/57 | 0.500, dim 11 | — |
| **rec+AD+draft+GenEO** | **10,473** | 57 | **0.595×** | 2/57 | 0.500, dim 12 | 1 build, 1 refresh, N_t 48 |
| GenEO alone | 13,515 | 59 | 0.768× | 2/59 | — | 1 build, 1 refresh |
| GenEO+rec | 13,385 | 59 | 0.760× | 2/59 | 0.500, dim 8 | 1 build, 1 refresh |
| rec+AD+GenEO | 16,547 | 57 | 0.940× | 3/57 | 0.667, dim 16 | 1 build, 2 refreshes |

**Big stagnation fixture** (48×32×48, 73,728 elements, 48.8× dilution — the
recycling-wrap regime; capped 12 iterations, cert always exact):

| posture | CG | vs none | Jacobi fallbacks | rc_frac | GenEO |
|---|---|---|---|---|---|
| none | 13,079 | 1.000× | 2/12 | — | — |
| rec | 15,349 | 1.174× | 2/12 | 0.500, dim 16 | — |
| rec+AD | 19,329 | 1.478× | 2/12 | 0.500, dim 15 | — |
| rec+AD+draft | 947 | 0.072× | **0/12** | — (no Jacobi) | — |
| **rec+AD+draft+GenEO** | **947** | **0.072×** | **0/12** | — | **0 builds — inert, CG identical** |
| GenEO alone | 3,100 | 0.237× | 2/12 | — | 1 build, 1 refresh, N_t 878, 36.1 MB |
| GenEO+rec | 3,014 | 0.230× | 2/12 | 0.500, dim 10 | 1 build, 1 refresh |
| rec+AD+GenEO | 4,639 | 0.355× | 2/12 | 0.500, dim 8 | 1 build, 1 refresh, N_t 864 |

(The `rec` and `rec+AD` rows reproduce the draft-arming/PR-209 records — 15,349
and 19,329 — to the digit.)

**The five interaction verdicts, measured:**

1. **recycling × GenEO — coexist; recycling's marginal value is now small.**
   rc_frac is UNCHANGED with GenEO on (0.500 both fixtures — the carried
   subspace neither collapses nor is starved), and recycling on top of GenEO
   buys −86 CG (−2.8%) big-fixture, −130 (−1.0%) small. The two deflations
   overlap exactly as the task predicted (same augmented-subspace structure;
   GenEO's N_t ≈ 48–878 coarse space largely subsumes the k=16 recycle space),
   but they do not conflict: both SPD-additive, determinism holds, and the
   composition is mildly positive. **Finding:** in the armed stack, recycling's
   remaining value in its own target regime is marginal — kept armed because it
   is cheap and never harmful ON TOP of GenEO, but its 133-era 45% headline no
   longer describes the stacked production posture (on these fixtures its SOLO
   effect on a stagnating trajectory was already a coin-flip: +0.3%/+17.4%).
2. **draft × GenEO — complementary by regime, neither redundant.** Where draft
   rescues the stagnation (the capped big fixture: 0/12 fallbacks), GenEO is
   inert at zero cost (947 = 947, bit-identical). Where stagnation SURVIVES
   draft — the small fixture's loose-but-still-stagnating solves (1 build under
   the full posture, 11,574 → 10,473 = −9.5%) and above all the ALWAYS-TIGHT
   certification/final solves draft may never loosen (the real rung's 5,412 →
   754) — GenEO is the payer. Draft removes stagnation where it can; GenEO
   catches what still falls. Neither replaces the other.
3. **AD × GenEO — no mutual degradation, but AD remains the stack's drag, and
   it now also taxes GenEO's basis lifecycle.** The escape latch fires
   identically with GenEO on (iter 3, 30/1,008 escapes, both fixtures), and a
   mask flip can never make the deflation WRONG — the DOF-set fingerprint
   detects the changed kept set and drops the basis safely. But that safety has
   a measured price: on the gate ladder the AD mask window at each rung's start
   changes the kept set, so a basis built inside the window is dropped when the
   latch reverts to the full domain and must be RE-TRIGGERED (another
   500-iteration burn + eigensolve). Action-stream proof
   (`gate_actions_{ad,noad}.log`): AD off = **1 build** for the whole 4-rung
   ladder; AD on = **3 builds**, including rung 3 building against the
   restricted set (N_t = 12) at iter 2 and rebuilding post-latch (N_t = 48) at
   iter 3. On top of that, AD costs +54% CG over GenEO+rec (3,014 → 4,639) and
   +26% over rec (15,349 → 19,329) in the big-fixture stagnation regime — a
   fresh, independent sample of exactly what 2026-07-27-ad-arming-review
   measured (+26% coin-flip) when it recommended **DISARM AD**. This campaign's
   tables support that recommendation; per that review's R4 discipline, this PR
   does not change AD's armed default — the maintainer decides, and now has a
   four-way table.
4. **The full production posture is deterministic**: rec+AD+draft+GenEO run
   twice is bit-identical (design + compliance + CG), both fixtures.
5. **BLOCKED-STOP assessment: NOT triggered.** No pair of armed features
   degrades EACH OTHER: GenEO composes cleanly with all three (exact, inert
   where they win, additive where they don't). The one negative interaction in
   the tables — AD making every stagnating posture worse — is AD's own
   pre-existing, already-documented property (it predates GenEO and appears
   identically without it), not an interaction created by this arming.

---

## Honest limitations

1. **128³ remains projected, not run.** The armed headline is measured on the
   real developed 40×32×40 rung (5,412 → 754 cold, 7.2× with the trigger
   charged; 6.3×/4.4× warm) and the mode-count-flat scaling to 345k DOF is
   phase 2's; the ~41k-iteration 128³ rung projection (armed ≈ 500 + low
   hundreds ⇒ tens-of-× on the cold solve) rests on that flat curve. Same
   posture as every prior arming: the fixture numbers must not be quoted as
   production truth for the 128³ job until it is run.
2. **The trigger halves the cold-solve headline by design.** 21.7× (hook, no
   trigger) becomes 7.2× armed, because 500 plain iterations are burned proving
   stagnation before the eigensolve is paid. That is the price of never charging
   a healthy fallback; on the 128³ class (41k-iteration solves) the burn is
   ~1.2% and the two numbers converge.
3. **Not bit-identical when engaged** — charged in A3/A4: 7/4,608 voxels flipped
   classification on the one engaged ACCEPT rung (control floor 0), certified
   margin moved ≤ 0.0029% on ACCEPT rungs, 0.65% on the terminal non-shipping
   REJECT rung, zero verdict flips. The third non-bit-identical production dial
   (after AD and draft) — but unlike those two, the per-SOLVE answer is exact.
4. **The degradation rebuild was never consumed on a physical fixture** — the
   condition fired once (amort step 5) but no later fallback existed to rebuild
   on, and two constructed worst-case rot scenarios (violent random jumps; full
   checkerboard phase inversion, `fast*.log`) could NOT rot the basis below a
   2.5× win. The backstop is armed and reachable; its full fire-and-recover
   cycle is exercised only at the state-machine level, not end-to-end.
5. **The coarse-solve conditioning caveat at production extents is unchanged
   from phase 2** (`cond(V^T A V) ≈ 6.8e9` measured; N_t ≈ 22–28k at 8.44M DOF
   exceeds the dense cap and falls to the capped inner CG, implemented but not
   stress-tested there).

---

## Gates / provenance

- **Full `ctest`: 78/78 pass** (`ctest_full.log`) — includes the new
  `geneo_twolevel` test, `production_parity` (the A1/A2/A8 assertions),
  `krylov_recycling`, the property suite and `cli_demo` (the CLI production
  path, now with GenEO armed).
- **Byte-identity with GenEO off** is structural (dead branches behind a
  default-false flag) + pinned by the stash-rebuild FNV, the parity
  BEFORE/AFTER checks, and `test_geneo`'s inertness section.
- **Gate-V2 untouched**: OC + JacobiCG, never calls
  `configure_production_options`, never arms the deflation.
- **No forbidden files touched**: no `fixtures/`, benchmarks, `materials.json`,
  `ARCHITECTURE.md`, `DECISIONS.md`, ROADMAP checkboxes, or `/app/`; no weakened
  or deleted assertions (the arming diff contains zero assert-line changes).
- **Machine:** Apple M2 Pro (6P+4E), 16 GB, macOS; Release library (-O3),
  harnesses -O2; matrix-free threads 6 (the 132 P-core pin). Every CG count,
  action code, N_t, rc_frac, escape count, FNV and verdict is deterministic
  (fixed LOBPCG seeds, fixed merge order, thread-count-independent — proven in
  `test_geneo`); several campaign runs shared the host, so NO wall ratio is
  cited as evidence — the deterministic CG counts are the signal (132's
  discipline).

---

## Evidence — `evidence/2026-07-29-geneo-arming/`

| file | bar | what |
|---|---|---|
| `A1_before.txt`, `A1_after.txt` | A1 | the identical stash-rebuild FNVs |
| `gate.log`, `gate.csv` | A3, A4 | the full before/after gate table + flip table with negative control |
| `interaction.log`, `interaction.csv` | ★★ | the 8-posture stack, small fixture |
| `stag.log`, `stag.csv` | ★★ | the 8-posture stack, recycling-wrap regime |
| `p2_plain.log`, `p2_armed.log` | ★, A6 | the real developed rung: plain 5,412/738/564 vs armed 754/118/129 |
| `amort.log`, `amort.csv` | A6 | the armed reuse policy end-to-end (build/refresh economics) |
| `fast.log`, `fast_cell2.log` | A6 | fast-moving design + worst-case injected rot, exactness per row |
| `gate_actions_ad.log`, `gate_actions_noad.log` | ★★(3) | per-solve action stream: AD's mask window forces basis re-triggers (3 builds vs 1) |
| `healthy.log`, `healthy.csv` | A7 | structural inertness where MG carries |
| `mem.log` | A5 | peak RSS, basis resident, headroom |
| `cli_run_info.json` | A8 | the end-to-end run_info echo |
| `ctest_full.log` | gates | the full suite |
| `reproduce.sh` | — | the whole campaign, in order |

---

## Scope / what is NOT here

- **The real 128³ stagnating job is not measured** (limitation 1). Owed before
  any armed multiple is quoted as production truth.
- **App / bridge untouched.** Both call `configure_production_options`, so the
  arming reaches them for free. The new run_info fields are JSON-only (no CSV
  schema change).
- **AD's armed default is not changed** — the four-way tables independently
  support 2026-07-27-ad-arming-review's DISARM recommendation, and that decision
  stays with the maintainer (finding 3 above).
- **The external phase-2 hook is untouched** and still ships default-off; the
  harness ablations (local term, hook-vs-armed comparisons) remain reproducible.
