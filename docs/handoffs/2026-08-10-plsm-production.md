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

**The knot lattice that ships, and the rule that derives it.** _[filled by
`run_s2_frontier.sh`; see §3.]_ The RULE is `plsm_knots_for_grid`
(`core/src/simp/plsm.cpp`): the knot spacing is a **LENGTH** — 3.410558 mm, the
smallest structure the basis may express — converted to voxels **through each
axis's own spacing**, floored at 2 voxels. ★ **It takes no minimum and no maximum
over the axes**, because it keys on the voxel SPACING and not on the part's
extent: a rule keyed to the thin axis gives 1 voxel on a 128 × 8 × 118 slab and
blows the coefficient count past the voxel count, which is the trap PR 323 lost a
day to and PR 324 reproduced on purpose.

**Carved roughness, margin and mass against SIMP's 7.5521 / 3254.34 / 543.7 g.**
_[§3.]_

**What the solver win is worth on SIMP.** _[§4.]_

**Does a PLSM design still lattice and certify.** _[§5.]_

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

### ★ TWO DEFECTS THE PRODUCTION PATH EXPOSED THAT READING IT WOULD NOT HAVE

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

| consumer | file:line | what it reads |
|---|---|---|
| the ladder's certification | `core/src/simp/minimize_plastic.cpp:1768`, `:1840` | `variant.optimization.physical_density`, passed to `analyze_fixed_design` — a density per voxel |
| `achieved_vf` | `minimize_plastic.cpp:1961`, `:1984` | `#{ρ > 0.5}/part_solid` and `optimization.volume_fraction` (`Σρ/n_active`) |
| the frozen / protect masks | `plsm.cpp` calls `effective_design_mask` | the SAME function `simp_optimize`'s loop calls |
| the clearances | `minimize_plastic.cpp:283-285` | folded into the mask as `FrozenVoid` before the optimiser; the boolean's void term |
| the design box | `minimize_plastic.cpp:660` (`design_domain_mask`) | one mask; part Active-or-FrozenSolid, keep-outs FrozenVoid |
| `lattice_variant` re-certification | `core/src/cli/run_job.cpp:5959-6003` | **re-certifies from the restored field and REFUSES** unless the recorded margin reproduces inside `kMarginReproductionResidualFactor × cg_tolerance` |
| the certification solve | `core/src/simp/analyze.cpp:269` | passes `initial_guess = nullptr` **unconditionally** — no certificate is ever warm-started |

## 3. S2 — THE KNOT LATTICE

_[filled by `run_s2_frontier.sh`.]_

## 4. S3 — THE SOLVER WIN, ON BOTH PATHS

_[filled by `run_s3_simp.sh`.]_

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

## 5. S4 — IT MUST STILL LATTICE

_[filled by `run_s4_lattice.sh`.]_

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
worth _[§4]_ on his own four-rung run.
