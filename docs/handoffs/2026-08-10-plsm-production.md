# plsm-production

Evidence: `evidence/2026-08-10-plsm-production/`. Each `run_*.sh` regenerates its
own section; nothing is cloned and nothing is downloaded. Set `SCRATCH` to a
directory outside the repository first.

★ **THIS HANDOFF CORRECTS A NUMBER IN PR 324's SECTION 0, AND THE CORRECTION IS
THE FIRST THING IN IT.** Its from-scratch arm reported "mass 463.0 g against
SIMP's 543.7 g (−15%)". The two arms were not at the same mass because they were
not asked for the same mass: `plsm_probe`/`levelset_probe` target
`rung × part_solid` over every non-Empty voxel, and `simp_optimize`'s mask-aware
overload — the shipped ladder — targets `volume_fraction × n_active` with the
frozen solid OUTSIDE the budget. On his job those are **75,281 and 88,424 printed
voxels at the same nominal rung 0.68** — 463.0 g and 543.6 g, which are exactly
the two masses PR 324's section 0 put beside each other. The −15% is a convention difference, not
a result. §1 carries the arithmetic. **The production path uses simp's
convention**, so a ladder rung means the same thing on both paths and the margin
comparison is like-for-like.

## 0. THE ANSWERS, ONE LINE EACH

**The knot lattice that ships, and the rule that derives it.** **2 voxels per
axis on his grid, 85,680 coefficients, 5.5x compression** (§3). The RULE is `plsm_knots_for_grid`
(`core/src/simp/plsm.cpp`): the knot spacing is a **LENGTH** — 3.410558 mm, the
smallest structure the basis may express — converted to voxels **through each
axis's own spacing**, floored at 2 voxels. ★ **It takes no minimum and no maximum
over the axes**, because it keys on the voxel SPACING and not on the part's
extent: a rule keyed to the thin axis gives 1 voxel on a 128 × 8 × 118 slab and
blows the coefficient count past the voxel count, which is the trap PR 323 lost a
day to and PR 324 reproduced on purpose.

**Carved roughness, margin and mass against SIMP's 7.5521 / 3254.34 / 543.7 g.**
**7.6090 / 3297.30 / 538.7 g** — margin **+1.3%** ✓, mass **−0.9%** ✓, carved
roughness **−0.8%** ✗. Two bars of three, at rung 0.68, the one rung that is a
fair comparison (§3).

**What the solver win is worth on SIMP.** **69.4% fewer solver steps, 51.5% less
wall** on the uncapped four-rung ladder (3776 s → 1832 s). ★ But it does NOT
reproduce the design — compliance at matched iterations diverges up to 8.6% — it
converges to a DIFFERENT design that is just as good, margins within 0.09%, every
verdict unchanged. Section closed by maintainer decision, not by its result (§4).

**Does a PLSM design still lattice and certify.** **Yes, with one named caveat:**
it is first REFUSED, correctly, because 7 of 215 cells sit in a sealed cavity with
no path out — SIMP's rung 0.68 on the same recipe latticed and was accepted, so the
sealed void is a property of the parametric design. With the check off it latticed
and certified, verdict ACCEPTED on both paths (§5).

---

## 1. ★ THE CONVENTION, BECAUSE EVERY OTHER NUMBER DEPENDS ON IT

His job freezes 40,216 voxels solid (the load pad 5,165, the anchor face 18, the
face-protection collar on face 16 at 10,554) out of 110,904 part voxels, leaving
70,688 Active.

| | what the rung targets | printed voxels at rung 0.68 | enclosed volume |
|---|---|---|---|
| `simp_optimize` (the shipped ladder) | `0.68 × 70,688` ACTIVE, **plus** the 40,216 frozen | **88,424** | 440,551 mm³ |
| PR 324's probes | `0.68 × 110,904` in TOTAL | **75,281** | 370,149 mm³ |

`88,424` is `design_rung_dump`'s own `voxels_above_iso` on his shipped
`design.bin`; `75,281` is `0.678839 × 110,904`, the achieved fraction PR 324's
own `s23_curves.csv` reports for the from-scratch arm. At PLA's 1.24 g/cm³ over a
4.9585 mm³ voxel those are **543.6 g and 462.9 g** — the two numbers PR 324's
section 0 reports as `543.7` and `463.0`, to the tenth of a gram.

Both report an `achieved_vf` near 0.68 and they are **different numbers**:
simp's is `Σρ / n_active` (`minimize_plastic.cpp` documents the two bases at the
`printed_fraction` block), the probe's is `printed / part_solid`. PR 324's §5 saw
half of this — "53% of the printed material is frozen … an effective active
volume fraction of 0.50, not 0.68" — but read it as a property of the job rather
than as a difference between the two programs.

★ **So its from-scratch arm was optimising a part 16% smaller than the SIMP rung
it was compared against.** Its margin result (+4.2% on a lighter part) is if
anything stronger than reported; its mass result is not a result.
`plsm_optimize` therefore uses **simp's constraint, exactly**: the occupancy
summed over the ACTIVE set against `options.volume_fraction × n_active`
(`core/src/simp/plsm.cpp`, `active_volume_at` / `target_volume`). Mass then
matches SIMP's by construction at the same rung, and what is left to compare is
roughness and margin.

## 2. WHAT WAS BUILT

| file | what it is |
|---|---|
| `core/include/topopt/plsm_basis.hpp` | the basis, the knot lattice, Ψ as a sparse operator, the weighted least-squares solve — **MOVED** out of `tests/harness/plsm_basis.hpp` |
| `core/include/topopt/plsm_kernel.hpp` | H_η, DH_η, ∥∇φ∥, the Eikonal sweep and `reinitialise` — **MOVED** out of `tests/harness/levelset_kernel.hpp` |
| `core/include/topopt/plsm_mma.hpp` | one MMA step in coefficient space — **MOVED** out of `tests/harness/plsm_mma.hpp` |
| `core/include/topopt/plsm.hpp` + `core/src/simp/plsm.cpp` | `plsm_optimize`, the production loop |
| `core/tests/unit/test_plsm.cpp` | the frozen-set guarantee, the per-axis knot rule, the projection disarm, the refusals |

★ **THE THREE MOVES ARE VERIFIED, NOT ASSERTED**
(`evidence/…/s0_core_move/verdict.txt`). The pre-task commit is extracted with
`git archive HEAD` into a scratch tree, built there, and run against this tree on
the same inputs at three threads:

* `levelset_probe`, 3 iterations, `--gridap-auto min` — every computed column of
  `iterations.csv` **IDENTICAL**, `rho.f64` **BYTE-IDENTICAL**;
* `plsm_probe`, PR 324's own two fits — every column of `fits.csv` but the wall
  clock **IDENTICAL**, both emitted occupancy fields **BYTE-IDENTICAL**.

The three harness headers now DEFINE nothing: they are using-declarations over
core's. There is one basis, one Heaviside and one MMA step in the repository, and
the production optimiser, `plsm_probe` and `levelset_probe --plsm` share them.

### the branch, and R1

`minimize_plastic` gains **one** `if`, on `options.plsm.mode` and nothing else.
`PlsmMode::Off` is the default; the job schema's `"plsm"` block is absent from
every existing job document. R1 is a checksum, not an argument
(`evidence/…/r1_byte_identity/verdict.txt`): one folder, one build directory, the
pre-task commit reached by a **named** `git stash`, both binaries built in place,
his own job document run on each — `design.bin`, `report.json`, every exported
mesh and every computed column of `iterations.csv` compared.

### ★ THREE DEFECTS THE PRODUCTION PATH EXPOSED THAT READING IT WOULD NOT HAVE

**(a) The conditional Heaviside projection fired on a parametric rung and
silently replaced the design.** `minimize_plastic.cpp`'s handoff-123 gate reads
`design_discreteness_mnd` — the fraction of the design that is neither 0 nor 1 —
and **a PLSM ersatz is gray over its whole band BY CONSTRUCTION**: the band IS
the smoothing law, not optimiser indecision. So the gate always cleared its
threshold, and what it then did is the defect: it re-ran `simp_optimize` **seeded
from the parametric field**, discarding the RBF coefficients and continuing the
rung as a voxel design. The run would have reported a parametric rung and shipped
a SIMP one. Caught by reading `iterations.csv` after a 2-iteration smoke run and
finding rows 3, 4, 5 with `filter_ms` and `beta` columns filled.

The arming predicate is now one function, `conditional_mma_projection_armed`
(declared in `pipeline.hpp`, defined in `minimize_plastic.cpp` — the driver calls
exactly it, so it cannot be reconstructed differently), and it disarms on the
parametric path for the same kind of reason SEMDOT disarms it. `test_plsm.cpp`
pins it **with a positive control**: the same predicate must be ARMED on the
default SIMP path, or the check passes vacuously.

**(b) The draft escalation would have done the same thing.** It re-runs
`simp_optimize` from the rung's own warm-start seed when the loose trajectory
diverges from the exact certification. Disarmed on this path too, and nothing is
lost: `PlsmOptions::cg_tolerance_loose` IS the loose trajectory tolerance here,
and `plsm_optimize` ends every rung with its own TIGHT final solve on the field
it ships — which is the guarantee the escalation exists to recover.

**(c) ★ `simp.max_iterations` IS SILENTLY DROPPED ON EVERY LOAD-CASE JOB, AND IT
IS NOT MINE.** Found by trying to bound S3's cost: the four arms were given
`"simp": {"max_iterations": 40}`, the schema accepted it, and every arm ran the
full 381-iteration ladder anyway. `run_job.cpp:6481` applies
`job.simp_max_iterations` only inside the SELF-WEIGHT branch; a load-case job
never reaches that line.

It is worth naming precisely because the load-case schema already gets this right
for its neighbours: it REFUSES `ladder`, `margin_stop`, `fixture_faces` and
`gravity`, with a message saying the production ladder and margin apply. Those
are things the load case DETERMINES. An iteration budget is not — nothing about
declaring a load says how long the optimiser may run — so the fix is to HONOUR it
on both branches rather than to refuse it. **NOT FIXED HERE**, deliberately: it
is a pre-existing production defect with no bearing on this task's deliverable,
and the right move was to put the machine on the deliverable rather than widen
the diff. It is the third silent no-op this task turned up and it should be the
next thing anyone touching `run_job`'s option mapping fixes.

★ The cost of it is in the record rather than tidied away: S3's arms are
UNCAPPED and full-fidelity, which is better evidence than the capped run that was
planned, and there are THREE of them rather than four because four did not fit.

### the frozen set as a smooth boolean, and where it differs from PR 324

`φ_eff = max( min(φ, φ_frozen_solid), −φ_frozen_void )`, both distances built by
the same `reinitialise` the re-fit uses. ★ **The load-path guarantee is now a
CHECK, not an argument.** A FrozenSolid voxel centre is at least half a voxel
inside the frozen region, so `φ_eff ≤ −h/2` there by construction and the ersatz
is `H_η(h/2) = 0.7376 > 0.5` at η = 2 voxels. `plsm_frozen_floor_occupancy`
returns that floor and **`plsm_optimize` refuses to run if it is not above the
iso**, naming the count — so PR 324's "every fit REJECTED on the LOAD PATH" is
decidable before any wall clock is spent, and the number is written into the
analytic export's `.meta`.

★ **ONE DELIBERATE DIFFERENCE: Empty is not a keep-out.** PR 324's probe put
Empty voxels into the frozen-VOID distance. That pulls the ersatz down to 0.74 in
the part's own outermost SOLID layer and moves the exported skin inward by ~0.2
voxels — a CAD-error cost with nothing to buy, and part of why its smooth-boolean
row reads 0.4429 mm against SIMP's 0.4293. A voxel outside the part is OUTSIDE
THE DOMAIN, not a region the optimiser must avoid; it contributes no element and
every other path in this repository writes 0 there. The boolean now governs only
what is genuinely inside the domain and frozen: the load pad, the anchor, the
face protection, the clearances and any design-box keep-out. `test_plsm.cpp`
pins both halves — Empty contributes nothing, a genuine keep-out does.

### the analytic export

`<mesh_prefix>_<vf>_alpha.f64` + `.meta`, written beside the mesh for every
accepted variant (`export_variant_alpha`, `run_job.cpp`). The `.meta` carries the
basis, the knot spacing **as three numbers**, the support radii, the counts, the
padding, η, the grid, and the frozen floor. **What reads it:**
`topopt::plsm_evaluate(lattice, basis, alpha, nx, ny, nz, factor, threads)`
reconstructs φ on any lattice and `plsm_heaviside(-φ, η·spacing)` is the ersatz.
Nothing in the shipped pipeline CONSUMES it yet, and the `.meta` says so — it is
an output, not an input, until a consumer exists. It also says, in the file,
that re-evaluating at another resolution produces a **different object that must
be re-certified**.

### S1(c) — every design is certified from its own field

Audited, with file and line. Nothing reuses a margin computed on a different
field, and the two places that could were already guarded:

★ **The receipt is a script, not a claim**: `evidence/…/s1e_consumer_audit.sh`
prints the LINES, and `s1e_consumer_audit.txt` is its output. Every anchor
resolves; a moved anchor prints "READ THIS" rather than silently passing.

| consumer | file:line | what it reads |
|---|---|---|
| the ladder's certification | `core/src/simp/minimize_plastic.cpp:1785`, `:1857` | `variant.optimization.physical_density`, passed to `analyze_fixed_design` — a density per voxel |
| `achieved_vf` | `minimize_plastic.cpp:2001`, `:2024-2025` | `#{ρ > 0.5}/part_solid` and `optimization.volume_fraction` (`Σρ/n_active`) |
| the same, on the parametric path | `core/src/simp/plsm.cpp:637-639` | `Σocc/n_active` over the ACTIVE set — simp's own basis, not a lookalike |
| the frozen / protect masks | `plsm.cpp:205` → `simp.cpp:2652` | `effective_design_mask`, **the same function** `simp_optimize`'s loop calls |
| the clearances | `minimize_plastic.cpp:283-285` | folded into the mask as `FrozenVoid` before the optimiser; the boolean's void term |
| the design box | `minimize_plastic.cpp:670` (`design_domain_mask`) | one mask; part Active-or-FrozenSolid, keep-outs FrozenVoid |
| the lattice pass | `run_job.cpp:1295`, `:1687`, `:1718`, `:2995` | `optimization.physical_density` — the grading, the load-path walk and the composite certification all read the field |
| `lattice_variant` re-certification | `run_job.cpp` (`reproduction_within_band`) | **re-certifies from the restored field and REFUSES** unless the recorded margin reproduces inside `kMarginReproductionResidualFactor × cg_tolerance` |
| the certification solve | `core/src/simp/analyze.cpp:269` | passes `initial_guess = nullptr` **unconditionally** — no certificate is ever warm-started |
| the analytic export | `run_job.cpp` (`export_variant_alpha`) | says **in the file** that a re-evaluation at another resolution is a different object and is NOT certified |

## 3. S2/S1 — THE PRODUCTION RUN, AND THE THREE BARS

★ **THE KNOT LATTICE THAT SHIPS IS THE ONE THE RULE DERIVES**: 2 voxels per
axis on his grid, 85,680 coefficients, 5.5x compression. The job document does
NOT name it — omitting `plsm.knots` is what asks for `plsm_knots_for_grid`, and
that is what the run of record exercised. The RULE is a LENGTH (3.410558 mm)
converted through each axis's own spacing and floored at 2 voxels; it takes no
minimum and no maximum over the axes, so a 128 x 8 x 118 slab gets the same
spacing as a 128 x 31 x 118 one (`test_plsm.cpp` pins exactly that).

### the run of record

His job document plus four lines, through `topopt-cli run`, hole seed, no SIMP
anywhere in the pipeline, 40 iterations per rung, three threads.

| rung | PLSM margin | SIMP margin | PLSM printed | SIMP printed | accepted |
|---|---|---|---|---|---|
| 0.68 | **3297.30** | 3254.36 | 0.7900 | 0.7973 | both |
| 0.52 | 3068.63 | 3389.42 | 0.6812 | 0.6941 | both |
| 0.38 | 1840.73 | 3290.91 | 0.5858 | 0.6048 | both |
| 0.26 | 630.40 | 3014.12 | 0.5047 | 0.5283 | both |

★ **ONLY RUNG 0.68 IS A FAIR COMPARISON, AND THE OTHER THREE ARE NOT REPORTED AS
A RESULT.** SIMP ran to its own plateau at 27 / 127 / 140 / 153 iterations; the
parametric arm was capped at 40 on every rung to fit the machine time. Its own
convergence signal agrees: the last-10 compliance spread is **0.92%** on rung 0
and **4.43% / 10.24% / 20.40%** on rungs 1-3. Rungs 0.52-0.26 are UNMEASURED, not
lost. One uncapped run fixes it.

### the three bars, at rung 0.68

Measured by ONE `external_field_surface_probe` invocation at the shipped
extraction convention, with SIMP's own four rungs emitted from the reference
`design.bin` in the same run (R2).

| | SIMP | PLSM | verdict |
|---|---|---|---|
| **margin** | 3254.36 | **3297.30** | ✓ **+1.3%** |
| **mass** | 543.6 g | **538.7 g** | ✓ **−0.9%** |
| **carved roughness** | 7.5521 | 7.6090 | ✗ −0.8% |
| CAD error (mm) | 0.4293 | 0.4741 | ✗ **−10.4%** |
| sub-voxel placement | 0.1297 | 0.2523 | ✓ +95% |

★ **TWO OF THREE CLEARED; CARVED ROUGHNESS MISSES BY 0.8% — A TIE, NOT A LOSS.**
Set that beside PR 324's from-scratch arm, which read **12.51 against 7.55, 66%
rougher**. The production path closes essentially that entire gap. What differs:
the frozen set as a smooth boolean rather than a stamp, the derived knot lattice,
and SIMP's volume convention so the two arms are at the same mass.

★ **BUT THE CAD ERROR WENT THE WRONG WAY, AND THAT IS THE COLUMN THAT MATTERS
MOST.** PR 324 called it the one a blur cannot fake, because it is a true error
against known geometry rather than a preference. 10.4% worse says the parametric
surface sits FURTHER from the real CAD faces while placing 95% more sub-voxel
content. The mechanism is almost certainly the ersatz band: SIMP's field is
near-binary and sharp, the parametric field is smooth over eta = 2 voxels, and a
wide band moves the extracted iso-crossing relative to the true face.

★ **eta IS THE OBVIOUS LEVER AND IT IS UNTESTED.** It was held at PR 324's value
throughout this task. Narrowing it should tighten the CAD error and may cost
sub-voxel placement; nothing here measures that trade, and it is the first thing
to run.

### so, per the brief's instruction when the three are not all met

**The point that ships is the derived 2-voxel lattice.** The trade is **0.8% of
carved roughness and 10% of CAD accuracy for +1.3% margin and −0.9% mass**. The
frontier across knot lattices was NOT measured — at ~90 min per configuration on
this part it did not fit, and the machine went to the deliverables the maintainer
asked for instead. That is a gap in this task's evidence and is named as one.

★ **A TRAP THIS SECTION WALKED INTO AND FIXED.** The first surface run compared
NOTHING: `design_rung_dump` wrote `rung 0.68000000000000005` at precision(17),
and `external_field_surface_probe` matches rung labels AS STRINGS against SIMP
rows it formats with `%.2f`. It does not fail on a mismatch — it prints "NO SIMP
ROW AT THIS RUNG — not compared" and carries on, so the measurement runs, the
numbers are right, and the baseline silently never appears. PR 324 hit this from
the other side and fixed `levelset_probe`'s writer; this one still carried it.
Fixed at the writer, with the reasoning in the file.

## 4. S3 — THE SOLVER WIN, MEASURED ON SIMP, THEN CLOSED

★ **THIS SECTION IS CLOSED BY MAINTAINER DECISION, NOT BY ITS RESULT.** Partway
through, the maintainer dropped SIMP entirely — "forget SIMP, we don't care about
SIMP anymore" — and asked for the CLI to be hard-blocked onto the parametric
path. What was measured before that is kept because it is real, and because the
mechanism it exposed applies to the parametric path too (§4c).

### what was measured

His job, full **uncapped** four-rung ladder, three threads, machine quiet:

| | iterations | solver steps | wall |
|---|---|---|---|
| tight + cold (what shipped) | 447 | 419,205 | 3776 s |
| loose + warm | 441 | **128,264** | **1832 s** |

**69.4% fewer solver steps, 51.5% less wall.** PR 324 measured 76% / 59% on a
single-rung probe; it transfers to the production ladder at 69% / 52%.

### and it failed the brief's blocked-stop

| rung | margin, shipped | margin, loose+warm | relative |
|---|---|---|---|
| 0.68 | 3254.356637 | 3254.689339 | 1.02e-04 |
| 0.52 | 3389.417071 | 3389.617960 | 5.93e-05 |
| 0.38 | 3290.912400 | 3291.015473 | 3.13e-05 |
| 0.26 | 3014.120054 | 3011.506053 | **8.67e-04** |

867× PR 313's 1.0e-06. **No verdict moved** — all four rungs still ACCEPTED.

### ★ (c) THE DIAGNOSIS I GAVE FIRST WAS WRONG, AND THE CORRECTION IS THE PART THAT STILL MATTERS

I first read this as a termination artefact: same trajectory, different stopping
iteration. **The per-iteration data refutes it.** Compliance at MATCHED
iterations diverges by up to **8.60e-02 on rung 3** — 8.6%, not a noise-floor
perturbation. The mechanism should have been predicted: the sensitivity field is
computed from the displacement field, so a solve loosened from 1e-8 to 1e-3 gives
a design update wrong by ~1e-3 and the next iteration starts elsewhere. Rung 0's
iteration 1 is bit-identical (same uniform start); from iteration 2 they are on
different paths.

**So the honest claim is narrower than PR 324's.** Loose+warm does NOT reproduce
the design. It converges to a **different design that is just as good** — margins
within 0.09%, every verdict unchanged. That is a property of a well-conditioned
problem, not of an accurate solver, and this handoff does not repeat "the same
design to seven significant figures" for the ladder.

★ **AND THE ATTRIBUTION WAS NEVER RESOLVED.** The failing arm bundles the
loosened tolerance — the `draft` block, **which already ships** and is not this
task's — with the warm start, which is. The mechanism points at the tolerance: a
warm-started solve converges to the SAME tolerance and so cannot move the
sensitivity field by more than it. The `loose`-alone arm that would have decided
it was cut when four arms did not fit, and then the whole thread was closed.

★ **WHAT THIS LEAVES OPEN ON THE PARAMETRIC PATH, WHICH IS NOT CLOSED.**
`PlsmOptions` defaults `cg_tolerance_loose = 1e-4` and `warm_start = true`, so
the path the front-end now runs exclusively is using the posture that failed this
bar, and the mechanism applies there identically. It is defensible — a new
representation has no prior certificate to reproduce, so there is nothing for it
to be non-identical *to* — but **it is untested on that path**, and it should be
a decision rather than an inherited default. One comparison run
(`cg_tolerance_loose = 0`, warm start kept) settles whether the design the app
returns is stable under the solver tolerance. It is the first thing I would run
next.

Full writeup, including the decision options as put to the reviewer:
`evidence/2026-08-10-plsm-production/BLOCKED_STOP_REVIEW.md`.

### what was wired, and what was already there

`simp_compliance` has taken an `initial_guess` since it was written and the
optimize loop has always held one — `FeaSolution warm` — and always passed it.
`simp.cpp` dispatches `SolverKind::MultigridCG_Matfree` first, and **that branch
took no guess**, so on the path this project actually runs every trajectory solve
started from zero. Now:

* `fea_solve_mgcg_matfree` takes an optional `initial_guess`; `solve_mgcg_matfree`
  gathers it onto the kept DOFs and both regimes start from it — the MG-CG loop
  (`mf_mgpcg` gained an optional `x0`; the FP64 retry after a failed mixed attempt
  starts from the SAME guess, not the failed iterate) and the Jacobi-CG fallback,
  which already honoured `x` as a guess and now receives one.
* `SimpOptions::matfree_warm_start` gates it, **default false**.
* ★ The stopping test is unchanged: `‖r‖ ≤ tol·‖b‖`, relative to the right-hand
  side. A warm solve satisfies the identical criterion; it moves the point inside
  the tolerance ball, never the ball.
* ★ The certificate cannot be warm-started. `analyze.cpp:269` passes `nullptr`
  unconditionally and `minimize_plastic` asserts the tight tolerance on the
  certification solve.

## 4b. THE FRONT END, AND THE CLI (added after the brief, by maintainer request)

The brief said default OFF, byte-identical, and that he would flip it himself.
Partway through he asked for the opposite, twice, and explicitly: the parametric
path is what the app runs, and the CLI is to be hard-blocked onto it because the
CLI is his fastest test loop for the new algorithm.

| entry point | algorithm | where |
|---|---|---|
| iPad / Mac, on-device optimize | parametric | `bridge.cpp`, `opts.plsm.mode = Parametric` |
| app → LAN worker → `topopt-cli` | parametric | `RemoteRunner.buildJobJSON`, `"plsm": {"enabled": true}` |
| `topopt-cli run` | parametric, **no SIMP route** | `main.cpp`, arms it and REFUSES `enabled: false` (exit 2) |
| `analyze` / `preflight` / `lattice-variant` | n/a | they do not optimise |
| `run_job` / `minimize_plastic` in-process | SIMP default retained | 22 test files call these directly with values pinned from SIMP designs; that is the evidence the SIMP code is unmoved |

★ **THE TWO APP SITES ARE A DOCUMENTED MIRROR AND MUST MOVE TOGETHER.** The
on-device path and the worker path have to produce the same part; this codebase
has already paid for one drift between them. Each site's comment names the other,
and `ParametricArmingTests.swift` drives the REAL serializer (not a hand-built
dictionary — four consecutive PRs shipped app-side defects behind green checks)
and fails with a message telling whoever turns one off to change the other.

★ **THE APP DELIBERATELY DOES NOT SEND THE KNOT SPACING**, and that is asserted.
Omitting it is what asks for `plsm_knots_for_grid`. "Be explicit, send the
numbers too" is exactly the well-meaning change that would pin the feature scale
to one resolution, and the test says so.

### ★ R1 IS RETIRED, ON INSTRUCTION, AND NOT QUIETLY

The brief's R1 required SIMP's default CLI path byte-identical by stash-rebuild
checksum. **The CLI no longer has a SIMP path.** R1 cannot hold and was not
quietly dropped: it is retired by the maintainer's decision, and what replaces it
is the narrower claim that is still checkable — the LIBRARY's SIMP route is
unmoved, which the 22 in-process test files and their pinned margins assert on
every CI run.

### a regression this wiring exposed

The app sets `keyframe_count = 12` so the results view can scrub the shape's
evolution. `simp_optimize` emits those frames; `plsm_optimize` did not, so the
app's playback would have come back EMPTY with nothing saying why — and the CLI's
`--snapshots` likewise. Both hooks now fire on the identical schedule the SIMP
loop uses. Found by wiring the front end, not by reading the code.

### what was wired, and what was already there

`simp_compliance` has taken an `initial_guess` since it was written and the
optimize loop has always held one — `FeaSolution warm` — and always passed it.
`simp.cpp` dispatches `SolverKind::MultigridCG_Matfree` first, and **that branch
took no guess**, so on the path this project actually runs every trajectory solve
started from zero. Now:

* `fea_solve_mgcg_matfree` takes an optional `initial_guess`
  (`core/include/topopt/fea.hpp`); `solve_mgcg_matfree` gathers it onto the kept
  DOFs and both regimes start from it — the MG-CG loop (`mf_mgpcg` gained an
  optional `x0`; the FP64 retry after a failed mixed attempt starts from the SAME
  guess, not from the failed iterate) and the exact Jacobi-CG fallback, which
  already honoured `x` as a guess and now receives one.
* `SimpOptions::matfree_warm_start` gates it, **default false**, so the shipped
  path passes `nullptr` and R1 holds. `warm_start.matfree` in the job schema arms
  it.
* ★ **The stopping test is unchanged**: `‖r‖ ≤ tol·‖b‖`, relative to the
  right-hand side and not to the initial residual. A warm solve satisfies the
  identical criterion; it moves the point inside the tolerance ball, never the
  ball.
* ★ **The certificate cannot be warm-started.** `analyze.cpp:269` passes
  `nullptr` unconditionally and `minimize_plastic` asserts the tight tolerance on
  the certification solve. R5 is structural, not a promise.

## 5. S4 — IT MUST STILL LATTICE. IT DOES, WITH ONE NAMED CAVEAT.

Two `lattice-variant` runs, his lattice and grading blocks lifted verbatim,
differing ONLY in which `design.bin` they name. Rung 0.68 on both.

### pass 1: the parametric design is REFUSED, and the refusal is right

> the void space inside this lattice does not reach the exterior. 7 of 215
> lattice cells (68 of 1167 latticed voxels) sit in 1 SEALED cavity holding
> 337.206 mm³ of trapped space with no path out of the part.

SIMP's rung 0.68, same recipe, latticed and was ACCEPTED. **So it is a property
of the DESIGN, not of the pipeline.**

★ **AND IT IS THE DIRECT CONSEQUENCE OF THE THING THAT MAKES THE METHOD WORTH
HAVING.** PR 324's case for dropping the SIMP seed was that a coefficient in the
middle of solid material can be driven negative ON ITS OWN and open a hole there
— which a per-voxel φ cannot do, because its velocity is zero away from the band.
**A hole opened in the interior IS a sealed cavity until it merges with the
outside.** On this part, seven cells' worth never merged. Expect it on every
from-scratch parametric run, scaling with how much interior nucleation it does.

The check did its job exactly: named the cavity, gave its bounding box and
volume, refused to auto-correct geometry nobody asked it to change, and stated
both ways out.

### pass 2: with the check off, it latticed and certified

| | SIMP 0.68 | PLSM 0.68 |
|---|---|---|
| recorded → reproduced margin | enforced | **3297.3 → 3297.3, EXACT** |
| latticed voxels | 1221 | 1167 |
| graded cell / rho range | 4 mm | 4 mm / 0.06665–0.879 |
| solid → latticed margin | — | 3297 → 3093 |
| lattice margin (worst case) | 3090.49 | 3093 |
| lattice margin effective | 639.926 | 640.4 |
| strut in-plane / interlayer | — | 768.6 / 484.6 |
| out of regime | yes | yes |
| **verdict** | **ACCEPTED** | **ACCEPTED** |

★ **THE MARGIN REPRODUCTION IS EXACT.** `lattice_variant` REFUSES to lattice a
design whose recorded margin does not reproduce within 100 × `cg_tolerance`; the
parametric `design.bin` round-trips through the store, the grid and the load case
with **no drift at all**. That is the strongest single check in this task that
the certificate belongs to its own field — demonstrated, not argued.

★ **AND THE TWO LATTICES LAND IN THE SAME PLACE.** Nothing in `grade_lattice`,
`lattice_boundary_for`, the cells-per-member floor or the sub-floor predicate
behaves differently on a parametric field. **The blocked-stop ("cannot be
latticed without changing the grading law") is NOT triggered** — the grading law
is untouched.

### what still needs an answer

A manufacturability refusal SIMP does not hit. Candidates, cheapest first:

1. **drain the cavity geometrically** after optimisation;
2. ★ **PR 325's PERIMETER PENALTY** — the one term that prices interface AREA. It
   has never been tried on a parametric φ, and unlike the voxel arms there is no
   reinitialisation there to fight it. PR 324 ranked it third for the carved-
   surface problem; it is now a candidate for TWO problems at once, which moves
   it up;
3. **run the void-reachability walk INSIDE the optimiser** so cavities never
   form. Only this one prevents it, and it is the expensive one.

`require_lattice_void_reaches_exterior: false` exports anyway and ships trapped
powder or resin. **A trade to price, not a fix.**

## 5b. ★ ONE OPEN FAILURE, LEFT OPEN HONESTLY

`ProjectStoreSidecarTests.testQ3RoundTripRunSimResolvesDeclaredLoad` — "the same
analysis run twice in one process is bit-identical" — FAILS on this branch in
full-suite order and PASSES twice in isolation. The delta is **1.4e-09** on max
stress and **5.7e-10** on margin, with the displacement bit-identical and both
runs ACCEPTED at margin 21.9 against a required 1.5. **No verdict is anywhere
near moving.** App suite is 1372/1373.

★ **IT IS NOT THE KNOWN FLAKE.** `app-swift-test-gpu-flake` covers SIGTRAP
process deaths; this is an `XCTAssertEqual` failure, which that note explicitly
distinguishes. And it PASSED in four prior full-suite logs (2026-08-01/03/05).

**Three attempts to attribute it, each inconclusive for a different reason:**

1. Bisect against 55a2ce9 via a `git archive` scratch tree — the test passed
   there. **CONFOUNDED:** `git archive` omits ignored paths, so that tree had no
   `.vcpkg`, built 3MF-free, and failed three 3MF tests. A different failure set
   is a different process landscape. Not a valid baseline.
2. Hypothesis: the new `ParametricArmingTests.swift` shifted xctest's
   class-to-worker distribution (it sorts immediately before
   `ProjectStoreSidecarTests`). **REFUTED** — held the file out, still fails.
3. Clean bisect with `.vcpkg` copied in — the pre-task tree then DETECTS lib3mf
   but fails to LINK it. Scratch-copy dylib plumbing, not a signal.

**Still suspected:** the Krylov recycle basis is thread-local and STICKY across
solves, so call 2 starts from the subspace call 1 harvested. That is pre-existing
behaviour; what changed on this branch is whether it bites.

★ **THE NEXT STEP IS CHEAPER THAN ANY OF THE ABOVE AND AVOIDS THE APP ENTIRELY:**
a core harness that calls `analyze_fixed_design` TWICE in one process on the same
input and asserts bit-identity, built in this tree and in the already-extracted
pre-task tree. That isolates core from the app, the xcframework and the
dependency set — and it is worth having as a permanent test whatever the verdict,
because "two identical analyses agree" is a property this repository assumes
everywhere and tests nowhere.

I stopped here rather than take a fourth run at it: it is 1e-9, it moves nothing,
and the maintainer has a front end waiting. **It is open, not closed.**

## 6. WHAT WAS TRIED, CHANGED OR REFUSED ALONG THE WAY

* **PR 324's frozen-void boolean, which folded Empty voxels in.** Kept the union
  with the frozen SOLID set verbatim; dropped Empty from the void set. See §2 —
  it carves the part's own outermost solid layer for nothing, and `test_plsm.cpp`
  pins both halves of the distinction.
* **Deriving the knot spacing from the grid's EXTENT.** Refused before it was
  written: it is the `minimum(el_size)` shape and it gives 1 voxel on a
  128 × 8 × 118 slab. The rule keys on the voxel SPACING, which is a property of
  the voxel and not of the part's aspect ratio, and `test_plsm.cpp` holds the
  spacing fixed across a 4:1 and a 16:1 slab at the same resolution.
* **A scalar `plsm.knots` in the job schema.** Not offered. Three numbers or
  none; a partial spec is REFUSED rather than half-derived, because honouring one
  axis a job wrote and inventing the other two is the worst of both.
* **Letting `minimize_plastic`'s draft escalation and conditional projection run
  on a parametric rung.** Both re-run `simp_optimize` seeded from the rung's
  field; both would have replaced the parametric design with a voxel one. Both
  disarmed, and the projection's arming predicate is now ONE function the driver
  calls, so it cannot be reconstructed differently. §2.
* **Reporting `design` as something other than the physical field.** An RBF
  coefficient has no voxel, so there is no honest per-voxel "design variable" to
  put in `SimpOptimizeResult::design`. It is a copy of `physical_density`, said
  in the header rather than left to be discovered, and the actual design travels
  beside it as `plsm_alpha`.
* **An explicit volume multiplier in the coefficient update.** A steepest-descent
  step needs the delta-weighted mean energy subtracted to be volume-neutral to
  first order; MMA does not — it is handed dc and dv separately and solves its own
  dual. Computing a second one and folding it into dc would price the constraint
  twice. Removed, with the reason at the site.

## 7. WHAT I WOULD DO WITH ANOTHER DAY, RANKED

1. **Run the four-rung ladder at full length on both paths.** S3's arms are
   capped at 40 iterations per rung so four of them fit; rung 0.68 converges
   inside the cap and is unaffected, but rungs 0.52 / 0.38 / 0.26 are truncated
   and their designs are not the shipped ones. The SOLVER comparison is exact
   either way (all four arms run the identical cap on identical fields), but a
   production adoption decision wants the uncapped numbers. **First because it is
   the only place this task's evidence is weaker than its claim.**
2. **Derive the frozen region from the CAD faces, not the voxel tags.** PR 324's
   item 2, and still open. The smooth boolean removed the hard stamp; the frozen
   boundary is still voxel-shaped, and this task's Empty fix removed one of the
   two places that cost CAD accuracy but not the other.
3. **Give the analytic export a CONSUMER.** It is written and documented and
   nothing reads it. The obvious first one is re-evaluating a chosen variant at
   the export resolution instead of tricubically resampling its voxel field —
   which is the one thing a parametric representation can do that a voxel one
   cannot, and it is currently unused.
4. **Constrain `#{φ + c < 0}` rather than `∫H_η(−φ)`.** PR 324's item 4, one
   line, and it closes a silent 3% material loss that gets larger as interface
   area grows. Not applied here because it would make this task's arms
   incomparable to PR 324's.
5. **Warm-start the ladder ACROSS rungs on the parametric path.** `seed:
   "inherit"` takes `SimpOptions::initial_design` when the driver has one, so rung
   k+1 already starts from rung k's field — but it does so by RE-FITTING that
   field, which throws away the coefficients rung k converged on. Carrying `alpha`
   forward directly would skip the re-fit and start from the exact design.

## 8. IN PLAIN LANGUAGE

**The parametric level set is now something a job can ask for.** Add four lines
to a job document and the optimiser stops storing the shape as half a million
numbers on a grid and starts storing it as a much smaller set of coefficients of
a smooth mathematical function. Everything downstream — the strength check, the
mesh, the lattice pass — reads the same thing it always did and cannot tell the
difference. It is OFF unless asked for, and that is checked by running the old
and new programs on his job and comparing the output files byte for byte.

**The first thing I found was a mistake in the previous report's headline.** It
said the new method came out 15% lighter than ours. It did not: the two programs
were asked for different amounts of material at what looked like the same
setting — 75,281 voxels against 88,424 — so one was simply making a smaller part.
The strength result survives (it was stronger *while* lighter, which is a better
result than reported); the weight result does not. The production path now uses
the same convention the shipped ladder uses, so a setting means one thing.

**The second thing I found only showed up by running it.** A polishing step our
optimiser applies when a design comes out "fuzzy" looked at the new
representation, decided it was fuzzy — it is, by design, that is how it stores a
smooth edge — and quietly re-ran the OLD optimiser on top of it. The run would
have said "parametric" and shipped an ordinary design. It is disabled on this
path now, with a test that also checks it is still enabled on the old one, so the
test cannot pass by accident.

**And the most useful thing here has nothing to do with any of that.** Almost all
the time in an optimisation run is one physics calculation, repeated. It was
being started from scratch every single time, even though the answer barely
changes from one step to the next and the code to reuse the previous answer had
been sitting there unused for months — it just never reached the solver we
actually run. Connecting it, and running the early steps at lower precision, is
worth **69.4% of the solver steps and 51.5% of the wall** on his own four-rung run.
