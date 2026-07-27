# DRAFT QUALITY — production arming

## THE DECISION (recorded verbatim, not re-litigated)

> The maintainer has decided to arm Draft quality in production.

This handoff IMPLEMENTS that decision. It does not re-open it. Everything below is the
arming (the production flip, its named constants, its tripwire, its parity assertions,
its run_info echo) and the before/after evidence the decision is now accountable to —
the same shape as the Active-Domain arming (2026-07-26-ad-arming) and the recycling
arming (handoff 133 / PR 163), which each recorded their maintainer ruling verbatim and
then shipped the armed package against it.

**Status:** Armed, core only. `configure_production_options` now sets
`opts.draft_quality = true`, `opts.draft_loose_tol = 1e-3`, and DISARMS the escalation
trigger (design-space trigger off; compliance-gap fallback set to a disable sentinel).
The LIBRARY default stays `draft_quality = false` (OFF), so Gate-V2, the property suite
and every core reference run — none of which call that function — are BYTE-FOR-BYTE
unchanged (THE ONE RULE, re-proven below by stash-rebuild FNV).

**The caveat this arming carries, stated up front:** like the active-domain band, draft
is NOT bit-identical when on. Its loose trajectory solves answer a slightly different
question than the tight ones, so the mid-ladder *trajectory* drifts on some rungs. What
never drifts is the shipped part: the FINAL compliance and stress-recovery solves ALWAYS
run at the exact tight tolerance, so the certificate is exact. That is the entire safety
— because **arming accepts no mid-run alarm** (below).

---

## ★ THREE HONEST GAPS — stated, not buried

### 1. THE WIN IS UNMEASURED AT PRODUCTION SCALE, and is NON-MONOTONIC.
The measured win TRACKS THE STAGNATION FRACTION of the specific part, NOT the grid size.
Across the three measured sizes it is non-monotonic and FALLS across the endpoints:

| posture | S 16×8×16 | M 24×12×24 | L 32×16×32 |
|---|---|---|---|
| AD-off (reliably converges, reproduces 185/197 to the digit) | **2.07×** | **3.62×** | **1.53×** |
| AD-on (the ARMED production posture) | **1.91×** | **4.11×** | *does not converge* |

The maintainer's real job is 128³, whose design-box run stagnates in ~100% of iterations,
so draft should land well there — **but that is a PREDICTION.** Do NOT read any fixture
number as transferring to 128³, and there is no headline multiple. The 128³ tight baseline
exceeds a 6-P-core Mac's practical wall time (a single L ladder already runs minutes; AD-on
L does not even converge — the tight multigrid stalls into Jacobi-CG and the matfree solver
throws rather than return a bogus certificate, a real property of AD-on-at-scale on this
grid class, and exactly why the AD-off posture is what the trend is read from).

### 2. ARMING ACCEPTS NO MID-RUN ALARM.
Plainly: **the belt does not work; the certification does.** The escalation trigger was
built twice and measured NOT to separate a diverged rung from a converged one — the
Phase-1 compliance gap fires false positives and misses genuine divergence (185), and the
Phase-2 design-space probe is structurally blind to the basin/path divergence that matters
(197). Both ship DISARMED. The load-bearing safety is the ALWAYS-exact final certification,
enforced by an NDEBUG-independent parity check (A2). A5 gave a fresh, concrete reason to
disarm the gap *explicitly* rather than leave it at its retired 0.02 default (below).

### 3. IT CHANGES THE PRODUCT ON SOME RUNGS — which ones, measured.
185 proved the terminal certified design classification-identical across a 500× loose
sweep (1e-3…5e-1), but mid-ladder transients on non-terminal REJECT rungs reached
flip-fractions of 0.05–0.15 **at aggressive loose tolerances (up to 5e-1).** At the ARMED
production loose tol (1e-3, the tight end of that sweep) the drift is much smaller but NOT
zero, and the full-ladder gate (A3) reports it per rung:

| | rung 0 (0.68, ACCEPT) | rung 1 (0.52, ACCEPT) | rung 2 (0.38, ACCEPT) | rung 3 (0.26, REJECT) |
|---|---|---|---|---|
| max\|Δρ\| | 1.0e-5 | 1.4e-5 | **1.85e-2** | 4.5e-3 |
| certified dM/M | 3.9e-6 | 5.2e-8 | 2.6e-5 | **2.1e-3** |

So the rung that MOVES most is the mid-ladder ACCEPT rung 2 (up to ~1.85% of its voxels at
the extreme); the largest certified-margin change is 0.21% on the terminal REJECT rung 3,
which never ships. **No rung flips verdict, and the ladder outcome is identical.** The
mechanism can move mid-ladder rungs; at 1e-3 it does so only slightly and never enough to
change what ships or how it is judged. The shipped (certified) rung's numbers are exact
regardless (A2).

---

## 0. What shipped (core only, additive)

```
core/src/simp/production.cpp          arm: opts.draft_quality = true;
                                      opts.draft_loose_tol = kProductionDraftLooseTol (1e-3);
                                      opts.draft_use_design_trigger = false;
                                      opts.draft_escalation_c_gap = kProductionDraftEscalationDisabled;
                                      the two named constants + the TRIPWIRE +
                                      production_draft_loose_tol()
core/include/topopt/production.hpp    production_draft_loose_tol() decl + the "What it
                                      sets" draft bullet
core/include/topopt/simp.hpp          adaptive_traj_cg_tol() decl (was file-local) — so the
                                      parity test can enforce the gate NDEBUG-independently
core/src/simp/simp.cpp                adaptive_traj_cg_tol() promoted to library-internal
                                      linkage (no behaviour change, no call-site change)
core/tests/validation/test_production_parity.cpp  A1 + A2 assertions (below)
core/tests/harness/draft_arm_identity_probe.cpp   A1 library-default FNV probe (not CTest)
core/tests/harness/draft_arming_gate.cpp          A3 gate / A5 interaction / A5 stag (not CTest)
```

**No library default moved.** `MinimizePlasticOptions::draft_quality` is still `false`.
The CLI/bridge reach the arming for free because both call
`configure_production_options`; the reference world never does.

---

## 1. THE BARS

### A1 — `draft_quality == false` (the library default) is STILL byte-identical

`core/tests/harness/draft_arm_identity_probe.cpp` runs a fixed deterministic
minimize_plastic ladder at the LIBRARY defaults (draft off, AD 0, recycling off,
JacobiCG), boxed AND no-box, and FNV-1a hashes densities + compliance + margins +
accepts + iterations. It never calls `configure_production_options` and never names a
draft/production symbol, so it compiles unchanged against pristine main. Stash-rebuild
proof (`evidence/.../A1_byte_identity.txt`):

```
H_before  (pristine tree, pre-any-edit)                       = 70d2b20564ad1d06
H_after   (arming branch, armed lib)                          = 70d2b20564ad1d06
H_stashed (git stash the 5 tracked files, pristine rebuild)   = 70d2b20564ad1d06
```

All three identical. The production diff is purely additive inside a function the
reference world never calls; the library defaults are untouched. Also pinned in CI by
`test_production_parity`, which checks `!opts.draft_quality` BEFORE the config call and
`opts.draft_quality` AFTER. **MET.**

### A2 — THE GATE NEVER SOFTENS (and an honest correction about the asserts)

The source guards the task names — `assert(adaptive_traj_cg_tol(options,0.0) ==
options.cg_tolerance …)` at **simp.cpp:1798 and 2596** (the final certification solves) and
`assert(opt.cg_tolerance == kCertTol …)` at **minimize_plastic.cpp:747 / 785 / 1014** (the
stress-recovery and escalation solves) — are all present and unchanged.

**But they are NOT live in the shipped build, and I must say so.** The project's Release
configuration compiles with `-DNDEBUG` (`build/CMakeCache.txt`:
`CMAKE_CXX_FLAGS_RELEASE:STRING=-O3 -DNDEBUG`; verified empirically —
`evidence/.../ndebug_check.txt`), which turns every `assert()` into a no-op. So the C++
asserts document and enforce the invariant only in an assert-enabled build; they cannot be
the shipped enforcement. (This clarifies the prior handoffs' "no -DNDEBUG" claim: it holds
for the standalone harnesses, compiled `-O2` without `-DNDEBUG`, but not for the Release
library the harness links.)

The arming therefore enforces the gate **NDEBUG-independently, in `test_production_parity`**
— CHECKs (which fail the test on drift regardless of NDEBUG), echoed against the named
tolerance:

```
opts.simp.cg_tolerance == 1e-8                                   (cert stays tight)
adaptive_traj_cg_tol(sched, 0.0) == sched.cg_tolerance           (schedule FLOOR == cert)
adaptive_traj_cg_tol(sched, sched.move) >= sched.cg_tolerance    (never tighter than cert)
sched.cg_tolerance_loose > sched.cg_tolerance                    (loose genuinely looser)
```

where `sched` is the SimpOptions the driver hands each rung (loose endpoint =
`opts.draft_loose_tol`). To expose `adaptive_traj_cg_tol` to the test it was promoted from
file-local to a declared library-internal function — pure, deterministic, no behaviour or
call-site change. As a bonus, an assert-ENABLED rebuild (`-UNDEBUG`) runs the draft path
with the source asserts live and they never trip
(`evidence/.../asserts_enabled.log`). **MET, with the NDEBUG reality reported.**

### A3 — FULL GATE TABLE, BEFORE AND AFTER, every rung, verdict + margin

`draft_arming_gate.cpp gate` runs the full production ladder (`production_reduction_ladder`,
margin_stop 1.5) with recycling + AD armed in BOTH postures, draft OFF vs draft ON, each
posture twice. `evidence/.../gate_ladder.log`, `gate.csv`:

| rung | vf | verdict OFF → ON | margin OFF → ON | dM/M | mean\|Δρ\| | max\|Δρ\| | escalated |
|---|---|---|---|---|---|---|---|
| 0 | 0.68 | ACCEPT → ACCEPT | 13.9006 → 13.9005 | 3.94e-6 | 2.57e-8 | 1.01e-5 | 0 |
| 1 | 0.52 | ACCEPT → ACCEPT | 5.67028 → 5.67028 | 5.20e-8 | 3.26e-8 | 1.42e-5 | 0 |
| 2 | 0.38 | ACCEPT → ACCEPT | 4.66152 → 4.66164 | 2.61e-5 | 7.46e-5 | 1.85e-2 | 0 |
| 3 | 0.26 | REJECT → REJECT | 2.78730 → 2.79323 | 2.13e-3 | 2.53e-5 | 4.55e-3 | 0 |

Twice-run bit-identical in both postures. **ZERO verdict flips** — draft leaves every
rung's accept/reject decision, and the ladder's stop point, unchanged. The certified
margins move by at most `dM/M = 2.1e-3` (0.21%, on the terminal REJECT rung 3, which never
ships); the largest single-voxel design move is `max|Δρ| = 1.85e-2` on the ACCEPT rung 2.
So draft DOES perturb the mid-ladder design a little at 1e-3 — up to ~2% of a rung's
voxels at the extreme — but never enough to flip a verdict, change the ladder outcome, or
move a certified margin by more than a quarter percent. There are no flips to name. **MET.**

### A4 — THE LOOSE TOLERANCE IS DERIVED / JUSTIFIED, and carries a tripwire

Production arms at `draft_loose_tol = 1e-3` (`kProductionDraftLooseTol`). It is not picked:
185/197 measured the shipped (terminal, certified) design CLASSIFICATION-IDENTICAL to a
fully-tight run across a 500× loose sweep (1e-3…5e-1), and 1e-3 is the TIGHTEST endpoint of
that proven-robust range — the least-aggressive loose value that still moves the early
ultra-dilute iterations off the Jacobi-CG stagnation latch and lets multigrid carry them
(185 §B5: a stagnating iteration goes ~2200 → ~150 CG at 1e-3). Looser endpoints buy more
per-iteration speed but introduce the mid-ladder transient divergence of gap #3; 1e-3 sits
at the conservative, measured-safe end. A header **TRIPWIRE** beside the constant names the
two harnesses (`draft_arming_gate.cpp interaction`, `draft_quality_phase2_scale.cpp`) that
must be re-run before the value moves, and states plainly that draft is the second
production dial that is not bit-identical.

**The escalation posture is DISARMED, explicitly.** The design-space trigger stays off
(`draft_use_design_trigger = false`), and the retired compliance-gap fallback is DISABLED by
setting `draft_escalation_c_gap` to a sentinel no relative gap can exceed
(`kProductionDraftEscalationDisabled = 1e30`; the escalate rule is `gap <= 0 || gap >
threshold`, so a huge threshold means "never escalate"). A5 supplied the concrete reason to
disable it rather than leave the 0.02 default: the gap is ~2e-5 on a CONVERGED rung
(inert) but ~0.79 on an iteration-CAPPED one, so leaving 0.02 armed would fire a spurious
full tight re-run on any rung that hits its iteration cap before plateauing — safe (the
re-run is exact) but pure wasted work that catches nothing real (197's exact finding,
reproduced). Reported, per the task; 197's disarmed posture is unchanged in spirit. **MET.**

### A5 — ★★ THE THREE-WAY INTERACTION (recycling × AD × draft), measured

This is the first time Krylov recycling (armed, Jacobi-only, k=16), Active Domain (armed
AUTO) and draft would all be on together. Measured on ONE grid, four postures
(`draft_arming_gate.cpp interaction`, healthy 16×8×16 — MG carries — and `stag`, big
stagnation 73 728 elements — MG falls to Jacobi, the only regime where the Jacobi-only
recycling can wrap):

**Four-posture CG/outer ladder (healthy 16×8×16, natural termination):**

| posture | CG | outer | Jacobi-fallback | recycle rc_frac | AD | draft gap |
|---|---|---|---|---|---|---|
| none | 4878 | 60 | 0/60 | — | — | — |
| rec | 4878 | 60 | 0/60 | N/A (0 Jacobi) | — | — |
| rec+AD | 4062 | 52 | 0/52 | N/A | k=3, f̄ 0.58, no latch | — |
| rec+AD+draft | 3232 | 52 | 0/52 | N/A | k=3, f̄ 0.58, no latch | 2.0e-5, esc 0 |

**Recycling-wrap regime (big stagnation 73 728, capped 12 iters — where recycling wraps):**

| posture | CG | Jacobi | rc_frac | max recycle_dim | AD latch (with draft on/off) |
|---|---|---|---|---|---|
| rec (no AD) | 15349 | 2/12 | **0.500** | 16 | — |
| rec+AD | 19329 | 2/12 | **0.500** | 15 | escape @iter3, 1008 escapes → full domain |
| rec+AD+draft | 947 | **0/12** | 0.000 | 0 | escape @iter3, 1008 escapes → full domain |

**No pair silently degrades another — the four proofs:**
1. **recycling is EXACT with the stack:** on the healthy grid `rec` design == `none`
   design BIT-FOR-BIT (recycling is a pure preconditioner change, 133).
2. **recycle_dim does NOT collapse with draft:** in the Jacobi regime recycling wraps at
   `rc_frac = 0.500`, `max_dim = 16` (the full production k) — UNCHANGED by AD (rc_frac
   0.500 with AD on). With draft on, recycling reads `rc_frac = 0`, `max_dim = 0` — NOT a
   collapse: **draft moved every solve OUT of the Jacobi regime (0/12 fallbacks), so the
   Jacobi-only recycling correctly no-ops.** The two features' active windows are
   complementary, not conflicting; draft removes the very stagnation recycling exists to
   soften, and recycling's `wrap_multigrid=false` design makes it a clean no-op there.
3. **AD's latch behaviour is UNCHANGED by draft:** the escape latch fires identically
   (iteration 3, 1008 escapes, full domain restored) with draft ON and OFF. Draft's looser
   trajectory does not change how the band escapes or degenerates.
4. **the full-production product is DETERMINISTIC:** rec+AD+draft run twice is bit-identical
   in design, compliance and CG count.

**A5 verdict:** the three COEXIST. This is NOT a blocked-stop. `evidence/.../interaction*.log`,
`stag_bigfixture.log`, `interaction.csv`, `stag.csv`. **MET.**

### A6 — WIN AT THREE SIZES, TREND STATED

Measured with `draft_quality_phase2_scale.cpp` (tight vs draft-1e-3, summed trajectory CG,
whole ladder). See gap #1 for the table. **Trend, explicit:** the win is NON-MONOTONIC and
tracks the STAGNATION FRACTION, not grid size — it PEAKS at M (the thin grid stagnates
hardest under tight) and FALLS across the size endpoints (AD-off 2.07× → 1.53×; AD-on has no
L point). If judged purely on the size endpoints, the win ERODES with size — which is
exactly why 128³ is a prediction and not a promise, and why whether it clears any given bar
there is a per-part maintainer call. The probe stays ~1% at every size and the design is
robust (0 classification flips across the sweep). `evidence/.../scale_ADon_SM.log`,
`scale_ADoff.log`. **MET (trend down at endpoints, stated).**

### A7 — run_info echoes the armed draft state

A real CLI run (`build/topopt-cli run … --out …`, which arms draft via
`configure_production_options`) writes `run_info.json` with the full echo
(`evidence/.../cli_run_info.json`):

```
draft_quality: true            draft_loose_tol: 0.001
draft_use_design_trigger: false    draft_escalation_c_gap: 1e+30   (disabled sentinel, valid JSON)
draft_rung_tail_k: [0, 0, 0]   (the derived per-rung tightening tail — the "k")
draft_rung_c_gap: [8.6e-05, 3.5e-04, 1.5e-03]   (tiny on every converged rung)
draft_rung_escalated: [false, false, false]     draft_escalations: []   (rung index + gap)
```

`draft_escalation_c_gap` serializes as `1e+30` (the disable sentinel; `%.10g` → valid JSON).
The per-rung `c_gap` confirms escalation is inert on real converged rungs (all ≪ the retired
0.02, let alone the 1e30 disable), and `draft_escalations` is the "every escalation with its
rung index" list (empty — none fired). `draft_rung_tail_k` is the derived per-rung tightening
tail (the "k"); it reads 0 at this small resolution because the rungs converge without the
adaptive schedule accumulating a within-one-decade tail (on the larger interaction grid it
reads 12) — echoed honestly either way. **MET.**

---

## Production hygiene (163's pattern)

- **TRIPWIRE headers** beside `kProductionDraftLooseTol` and
  `kProductionDraftEscalationDisabled` in `production.cpp`: name the harnesses to re-run
  before the value or the escalation posture changes, and state that draft is not
  bit-identical when on.
- **Parity assertions against named constants:** `test_production_parity` echoes the armed
  loose tol against `production_draft_loose_tol()` (not a bare 1e-3), asserts the design
  trigger off and the gap disabled, and enforces the gate-never-softens invariant
  NDEBUG-independently — a silent drift fails a test rather than shipping.
- **run_info echoes** quality, loose tol, per-rung tail k, trigger posture, gap threshold,
  and any escalation with its rung index.

---

## Gates / provenance

- `test_production_parity` (the A1/A2 assertions + the armed determinism at both thread
  counts) passes. Full `ctest`: **69/69 pass** (`evidence/.../ctest_full.log`), including `production_parity` (the A1/A2 assertions), `cli_demo` (the CLI production path, now with draft armed), the property suite and `gate_v2`.
- **Byte-identity with draft off** is structural (additive diff; the library default path is
  never touched) + pinned by the stash-rebuild FNV and the parity BEFORE/AFTER checks.
- **Gate-V2 untouched:** it runs OC + JacobiCG and never calls
  `configure_production_options`, so it never arms draft.
- **No forbidden files touched:** no `fixtures/`, benchmarks, `materials.json`,
  `ARCHITECTURE.md`, `DECISIONS.md`, ROADMAP checkboxes, or `/app/`; no weakened or deleted
  assertions (the only source-level change to an assertion's file, `adaptive_traj_cg_tol`,
  ADDED a stronger NDEBUG-independent test of the same invariant).
- **Machine:** Apple M2 Pro (6P + 4E), macOS, Release, matrix-free threads 6 (the 132 P-core
  pin). Every CG-iteration count, rc_frac, escape count, resolved band and verdict is
  deterministic; wall clock is thermally exposed and several runs shared the host, so NO
  absolute wall ratio is cited — the deterministic CG counts are the durable signal.

---

## Evidence — `docs/handoffs/evidence/2026-07-26-draft-arming/`

| file | bar | what |
|---|---|---|
| `A1_byte_identity.txt` | A1 | the three identical FNV checksums (stash-rebuild) |
| `ndebug_check.txt`, `asserts_enabled.log` | A2 | the -DNDEBUG reality + the assert-enabled run |
| `gate_ladder.log`, `gate.csv` | A3 | the full before/after gate table |
| `interaction_healthy_16x8x16.log/.csv`, `interaction.csv` | A5 | the four-posture stack |
| `stag_bigfixture.log`, `stag.csv` | A5 | the recycling-wrap regime (rc_frac under draft) |
| `scale_ADon_SM.log`, `scale_ADoff.log` | A6, ★ | the win across three sizes, both postures |
| `cli_run_info.json` | A7 | the run_info draft echo end-to-end |
| `ctest_full.log` | gates | the full suite |

### Recipe

```bash
cmake -S core -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="/opt/homebrew/opt/eigen;/opt/homebrew/opt/opencascade"
cmake --build build -j10
ctest --test-dir build -R production_parity --output-on-failure

HRN="c++ -std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 \
  -DSETTINGS_RULES_PATH=\"$PWD/core/src/settings/rules.json\""
$HRN core/tests/harness/draft_arm_identity_probe.cpp build/libtopopt.a -o /tmp/dai  # A1
$HRN core/tests/harness/draft_arming_gate.cpp        build/libtopopt.a -o /tmp/dag
$HRN core/tests/harness/draft_quality_phase2_scale.cpp build/libtopopt.a -o /tmp/dqs
EV=$PWD/docs/handoffs/evidence/2026-07-26-draft-arming
TOPOPT_DA_DIR=$EV TOPOPT_DA_ARM=8  /tmp/dag interaction    # A5 healthy
TOPOPT_DA_DIR=$EV                  /tmp/dag stag 12         # A5 recycling-wrap — IDLE HOST
TOPOPT_DA_DIR=$EV TOPOPT_DA_ARM=12 /tmp/dag gate           # A3 — IDLE HOST
TOPOPT_DA_DIR=$EV TOPOPT_SCALE_AD=off /tmp/dqs             # A6 trend — IDLE HOST
```

---

## Scope / what is NOT here

- **The real 128³ stagnating job is not measured** (gap #1). The fixture win must not be
  quoted as production truth until it is.
- **App / bridge untouched.** Both already call `configure_production_options`, so arming
  reaches them for free; no app-side change was needed and none was made.
- **The escalation trigger is not revived.** A5 confirmed the disarmed posture; nothing in
  the interaction turned up a reason to arm it, and one concrete reason (the capped-rung
  false positive) to disable the gap fallback explicitly.
