# Self-weight must not be applied to material a keep-clear has removed

Slug: `selfweight-clearance-void-crash` ·
Evidence: `evidence/2026-08-03-selfweight-clearance-void-crash/`

Scope: `core/` only. No fixture, `materials.json`, `ARCHITECTURE.md` or
`DECISIONS.md` was touched. The gate was not changed. No assertion was weakened
or deleted.

**Sequencing note, stated up front.** The brief said to start from `main` after
PR 285 merges. PR 285 was still **open** when this work ran, and
`design_domain_loads` — the function the brief names as the fix site — exists
only on its branch. This branch therefore merges `origin/claude/design-box-lattice-recert-f09ced`
(commit `0ea1440`) into `main` (`2a425d3`) and builds on top. The fix itself is
one helper and two call sites in `core/src/simp/minimize_plastic.cpp`; if PR 285
changes before it lands, rebasing this is trivial. **The reproduction was done
first, on `main` alone, with none of PR 285's code present** — see SW1.

---

## The reviewer was right to ask: is it there, and whose is it?

**It reproduces.** Twice, independently, before anything was changed.

**It is PRE-EXISTING, not new in PR 285, and not inherited from anywhere
recent.** PR 285's `design_domain_loads` is a pure *move* of a block
`minimize_plastic` already had; the defect is in what that block computes, and it
computed the same thing before the move. The defect became reachable on
**2026-07-17**, at `289a6a3` ("Shape-aware clearance regions (Keep clear) —
handoff 100"), the commit that introduced the third of the three ingredients it
needs. It has been reachable for **17 days**.

---

## 1. The defect

Three things have to be true at once, and each arrived separately:

| ingredient | what it does | since |
|---|---|---|
| a **design box** | `expand_design_domain` tags every in-box Active voxel `Interior` — i.e. **SOLID** | `bc0fbff`, 2026-07-13 |
| **no declared load** | `minimize_plastic` falls to self-weight, and `self_weight_loads` keys on the grid's **TAGS**, so it weighs the whole growth region | predates the box |
| a **keep-clear reaching into the growth region** | the overlay pins those same voxels `FrozenVoid` in the effective **MASK** — a *different* structure, applied *later* | `289a6a3`, 2026-07-17 |

A `FrozenVoid` voxel is driven to `rho_min` and its DOFs are eliminated by the
M3.1 void-DOF gate. Body force was already sitting on those DOFs. The gate does
the right thing and refuses the whole run:

```
fea_solve_mgcg_matfree: under-constrained system
(load applied to a void DOF with no stiffness — no equilibrium possible)
```

The load is built from tags; the material is removed from the mask; nothing
reconciled the two.

**Why a keep-out box never had this problem.** `expand_design_domain` handles
its own `keep_out_boxes` by tagging the voxel `Empty` — its comment says so in
as many words: *"Tag Empty so it carries no FEA element and no self-weight."* A
clearance arrives later, as a mask overlay, and could not reach the tags. The fix
is to make the clearance do what the keep-out already did.

### SW1 — reproduced first, on unfixed code

**(a) On `main` alone (`2a425d3`), no PR 285 code present.** A public-API probe:
a 16×8×4 plate, a design box growing to z = 12 mm, and a manual face-slab
clearance at z ∈ [8, 11] — entirely in the growth region, so the rasterizer's
part-precedence guard cannot skip it. No declared load.

```
part grid   16x8x4
solved grid 16x8x16
clearance: region_voxels=144 voxels_frozen=144 in_grid=1
voxels BOTH clearance-voided AND tagged solid: 144
THREW: fea_solve_cg: under-constrained system (load applied to a void DOF ...)
```

**(b) At CLI level**, on the merged tree, job
`jobs/X_preexisting_selfweight_clearance_crash.json` — a design box, four bolt
keep-clears, no force group:

```
[loadcase] clearance face=-1 kind=bolt voxels_frozen=64 status=ok   (x4)
topopt-cli: fea_solve_mgcg_matfree: under-constrained system (load applied to a void DOF ...)
```

That is the reported message verbatim.

**(c) The new test fails on unfixed logic.** After writing the fix, its body was
neutered (the mask ignored, signatures kept) and the suite re-run —
`evidence/.../sw1_test_fails_before_fix.txt`:

```
[SW1]  threw: fea_solve_cg: under-constrained system (load applied to a void DOF ...)
[SW1b] threw: fea_solve_cg: under-constrained system (load applied to a void DOF ...)
[SW3]  drop 0.000000000000e+00 N; expected 1.751673600000e+03 N
[SW3]  orphaned load DOFs: pre-fix definition 90, fixed 90
23 checks, 4 failures
```

---

## 2. The fix, in the ONE definition — and a fifth site the audit found

`core/src/simp/minimize_plastic.cpp` gains one file-local helper:

```cpp
// Self-weight is the weight of the material that is THERE.
std::vector<NodalLoad> masked_self_weight_loads(grid, mask, density, gravity, direction);
```

It copies the grid, sets `Empty` on every voxel the mask pins `FrozenVoid`, and
weighs that — precisely what `expand_design_domain` already does for a keep-out.
**Every self-weight load case in the file now goes through it.**

Two public definitions in `topopt/pipeline.hpp` sit on top:

* **`design_domain_mask(domain, options)` — new.** The effective mask, composed
  once: the base classification plus the keep-clear overlay under the existing
  FrozenSolid-wins precedence. This is `minimize_plastic`'s own inline block,
  lifted verbatim; `minimize_plastic` now *consumes* it. The point is that the
  mask a run **optimises under** and the load it **solves under** are now derived
  from the same object, so they cannot describe different material.
* **`design_domain_loads(domain, options, density)` — changed.** Self-weight now
  goes through `masked_self_weight_loads` against that mask. The declared-load
  branch is untouched: a traction is a surface load on the part's own faces, and
  a clearance has nothing to say about it.

### The fifth site — the coarse warm-start pre-solve

Auditing the callers turned up a second instance of the same defect that the
brief's four-caller framing does not cover. `minimize_plastic`'s
`warm_start_coarse` pre-solve built **its own** self-weight, on
`coarsen_grid(G)`:

* `coarsen_grid` tags a coarse cell solid if **any** child is solid;
* `coarsen_mask` votes that cell `FrozenVoid` when **every** solid child is.

So a clearance-voided region produces coarse cells that are tag-solid and
mask-void — the identical mismatch, one level up. It is off by default, which is
the only reason it had not been seen. It now calls `masked_self_weight_loads(Gc,
mask_c, ...)`, and bar **SW1(b)** arms the flag and runs the specimen through it.

### The other four sites, audited and reported honestly

| site | what it weighs | verdict |
|---|---|---|
| `minimize_plastic` (`minimize_plastic.cpp:415`) | `design_domain_loads` | **FIXED** |
| run_job's latticed certification (`run_job.cpp:797`) | `design_domain_loads` | **FIXED** |
| `lattice_variant_job` (`run_job.cpp:3033`) | `design_domain_loads` | **FIXED** |
| `analyze_job` (`run_job.cpp:2470`) | `design_domain_loads` — but only on the **loadcase** branch (declared tractions) | unreachable by this defect |
| `analyze_job` self-weight (`run_job.cpp:2477`) | `self_weight_loads(design_grid, ...)` — a fixed design's **own** occupancy | immune by construction, see below |
| `bridge.cpp:940` (`app/`, out of scope) | the same design-grid form | immune by the same argument |

`analyze_job`'s self-weight branch deliberately weighs the design's own grid — a
substitute or smoothed mesh carries its own mass, which is a different question
from "what did the run solve under". That grid's tags come from the mesh
(material that is genuinely there) or, with no `--mesh`, from the **part** grid,
never the expanded one. It carries no clearance overlay, so there is nothing for
it to disagree with. It is left alone, and SW2 asserts in the sources that it is
the *only* `self_weight_loads` call left in `run_job.cpp` and that no site there
weighs a resolved **domain** grid.

---

## 3. Bars

New test: `core/tests/validation/test_selfweight_clearance_void.cpp`
(ctest `selfweight_clearance_void`), **26 checks, 0 failures**.

### SW3 — self-weight is still correct where it should apply

**Total self-weight force, same specimen, before and after:**

| | total | Δ |
|---|---|---|
| no clearance (and the pre-fix definition, bit for bit) | **18 684.5184 N** | — |
| with the keep-clear | **16 932.8448 N** | **−1 751.6736 N** |

and the expected drop is exact, not approximate:

```
144 voided voxels  x  g·rho·V = 12.1644 N/voxel  =  1 751.6736 N
```

Three separate bars, not one:

* **SW3(a)** with no clearance the load vector is **bit-identical** to the
  pre-fix definition (`self_weight_loads` on the resolved grid) — node, component
  and value compared with `==`, not a tolerance. THE ONE RULE.
* **SW3(b)** the drop equals the voided material's weight to 1e-9 relative; the
  x/y components stay exactly zero under −z gravity.
* **SW3(c)** *not an arbitrary amount*: no surviving load entry names a DOF whose
  every incident voxel is void. The pre-fix definition stranded **90** such DOFs;
  the fix strands **0**. The bar is live in both directions.

### SW3 — byte-identity, stash-rebuild checksum

`checksums.sh` hashes every artefact of every run — `report.json`, the exported
STLs, `design.bin`, `fields.bin`, the lattice receipts, `iterations.csv` — from a
binary built at the pre-fix commit and from the fixed one. `run_info.json` is
hashed separately with two fields blanked and *only* two: `fingerprint` (the git
commit, which differs by construction) and the wall-clock millisecond counters.
Nothing else is excused.

```
JOB                                            HEAD               NEW                VERDICT                            RAW (nothing normalized)
A_nobox_lattice                                e7febb75a4b736ad   e7febb75a4b736ad   BYTE-IDENTICAL                     differs (wall clocks only)
B_box_nolattice                                93ecb17a89bea89c   93ecb17a89bea89c   BYTE-IDENTICAL                     differs (wall clocks only)
C_box_keepclear_lattice                        b0afe51296ac9b86   b0afe51296ac9b86   BYTE-IDENTICAL                     differs (wall clocks only)
D_box_selfweight_lattice                       16e10f21baecead9   16e10f21baecead9   BYTE-IDENTICAL                     differs (wall clocks only)
Y_nobox_clearance_selfweight                   fc74c2b831cf81e2   fc74c2b831cf81e2   BYTE-IDENTICAL                     differs (wall clocks only)
ZQ_analyze_loadcase_no_groups                  REFUSED            REFUSED            both REFUSED (unchanged)           identical even raw
X_preexisting_selfweight_clearance_crash       REFUSED            2ec548287d47cd1b   HEAD REFUSED -> NEW RAN (THE FIX)  -
Z_box_clearance_selfweight_lattice             REFUSED            c033e08ad1880de3   HEAD REFUSED -> NEW RAN (THE FIX)  -
ZV_lattice_variant                             REFUSED            4ce840da4e501a7d   HEAD REFUSED -> NEW RAN (THE FIX)  -
ZA_analyze_on_Z_mesh                           REFUSED            c0994bff50301844   HEAD REFUSED -> NEW RAN (THE FIX)  -
```

Every identity bar is **BYTE-IDENTICAL**. The RAW column shows the same
comparison with *nothing* normalized, so the exclusions can be checked rather
than trusted: raw differences exist and are wall clocks only.

### SW4 — the same load case, not merely a valid one

`resolve_design_domain` + `design_domain_loads` is the exact pair each
re-certification site runs. Re-resolving the domain the way they do and rebuilding
the load reproduces `minimize_plastic`'s load vector **entry for entry, bit for
bit** — 1 899 entries, compared with `==`, not a tolerance. A declared load case
comes back verbatim, untouched by the clearance.

End to end on the same fixture, all three re-certification callers now reach a
design that HEAD could not produce at all:

| job | caller | HEAD | NEW |
|---|---|---|---|
| **X** | `minimize_plastic` | REFUSED | 4 rungs, all ACCEPTED |
| **Z** | run_job's latticed certification | REFUSED | 4 rungs + lattice receipts |
| **ZV** | `lattice_variant_job` re-lattices Z's stored design | skipped (no design) | ran, 0.89 s |
| **ZA** | `analyze` re-certifies Z's exported mesh | skipped (no mesh) | ran, report written |

X and Z produce the **identical** four-rung table (same printed fractions, same
margins to ten digits), which is the SW4 statement in its strongest form: adding
a lattice block did not change the load case the run certified under.

### SW5 — full gate table, before and after

```
==============================================================================
 FULL GATE TABLE — HEAD vs NEW   (floor: relative delta <= 1e-09)
==============================================================================

A  no design box + lattice, self-weight, NO clearance
    HEAD   printed_fr   verdict     margin_worst_case  margin_effective   required   max_stress_mpa
            0.8025723   ACCEPTED         34732.24587        34732.24587          0   0.001583542861  
            0.7279743   ACCEPTED         31991.90649        31991.90649          0    0.00171918482  
            0.5903537   ACCEPTED         28597.06713        28597.06713          0   0.001923274151  
    NEW    printed_fr   verdict     margin_worst_case  margin_effective   required   max_stress_mpa
            0.8025723   ACCEPTED         34732.24587        34732.24587          0   0.001583542861  
            0.7279743   ACCEPTED         31991.90649        31991.90649          0    0.00171918482  
            0.5903537   ACCEPTED         28597.06713        28597.06713          0   0.001923274151  
    -> IDENTICAL    flips=0 worst_rel_delta=0  (rung-for-rung)

B  design box, no lattice, self-weight, NO clearance
    HEAD   printed_fr   verdict     margin_worst_case  margin_effective   required   max_stress_mpa
            0.4135048   ACCEPTED         16013.15016        16013.15016          0    0.00343467709  
            0.2334405   ACCEPTED         10180.36257        10180.36257          0   0.005402558075  
            0.1157556   ACCEPTED         7475.920599        7475.920599          0   0.007356953471  
    NEW    printed_fr   verdict     margin_worst_case  margin_effective   required   max_stress_mpa
            0.4135048   ACCEPTED         16013.15016        16013.15016          0    0.00343467709  
            0.2334405   ACCEPTED         10180.36257        10180.36257          0   0.005402558075  
            0.1157556   ACCEPTED         7475.920599        7475.920599          0   0.007356953471  
    -> IDENTICAL    flips=0 worst_rel_delta=0  (rung-for-rung)

C  design box + 4 keep-clears + DECLARED LOAD + lattice
    HEAD   printed_fr   verdict     margin_worst_case  margin_effective   required   max_stress_mpa
            0.6636656   ACCEPTED         7.238580468        7.238580468        1.5      7.598174842  
            0.6514469   ACCEPTED         8.025392377        8.025392377        1.5      6.674598377  
            0.6514469   ACCEPTED         8.025392377        8.025392377        1.5      6.674598377  
            0.6514469   ACCEPTED         8.025392377        8.025392377        1.5      6.674598377  
    NEW    printed_fr   verdict     margin_worst_case  margin_effective   required   max_stress_mpa
            0.6636656   ACCEPTED         7.238580468        7.238580468        1.5      7.598174842  
            0.6514469   ACCEPTED         8.025392377        8.025392377        1.5      6.674598377  
            0.6514469   ACCEPTED         8.025392377        8.025392377        1.5      6.674598377  
            0.6514469   ACCEPTED         8.025392377        8.025392377        1.5      6.674598377  
    -> IDENTICAL    flips=0 worst_rel_delta=0  (rung-for-rung)

D  design box + self-weight + lattice, NO clearance
    HEAD   printed_fr   verdict     margin_worst_case  margin_effective   required   max_stress_mpa
            0.4135048   ACCEPTED         16013.15016        16013.15016          0    0.00343467709  
            0.2334405   ACCEPTED         10180.36257        10180.36257          0   0.005402558075  
            0.1157556   ACCEPTED         7475.920599        7475.920599          0   0.007356953471  
    NEW    printed_fr   verdict     margin_worst_case  margin_effective   required   max_stress_mpa
            0.4135048   ACCEPTED         16013.15016        16013.15016          0    0.00343467709  
            0.2334405   ACCEPTED         10180.36257        10180.36257          0   0.005402558075  
            0.1157556   ACCEPTED         7475.920599        7475.920599          0   0.007356953471  
    -> IDENTICAL    flips=0 worst_rel_delta=0  (rung-for-rung)

Y  NO box + 4 keep-clears + self-weight
    HEAD   printed_fr   verdict     margin_worst_case  margin_effective   required   max_stress_mpa
            0.6942122   ACCEPTED          33569.1413         33569.1413        1.5     0.0016384095  
            0.5385852   ACCEPTED         30724.50785        30724.50785        1.5   0.001790101904  
            0.3861736   ACCEPTED         26415.62266        26415.62266        1.5   0.002082101214  
            0.2614148   ACCEPTED         13712.18727        13712.18727        1.5   0.004011030401  
    NEW    printed_fr   verdict     margin_worst_case  margin_effective   required   max_stress_mpa
            0.6942122   ACCEPTED          33569.1413         33569.1413        1.5     0.0016384095  
            0.5385852   ACCEPTED         30724.50785        30724.50785        1.5   0.001790101904  
            0.3861736   ACCEPTED         26415.62266        26415.62266        1.5   0.002082101214  
            0.2614148   ACCEPTED         13712.18727        13712.18727        1.5   0.004011030401  
    -> IDENTICAL    flips=0 worst_rel_delta=0  (rung-for-rung)

X  design box + 4 keep-clears + self-weight  [THE DEFECT]
    HEAD   (no report.json — the run REFUSED)
    NEW    printed_fr   verdict     margin_worst_case  margin_effective   required   max_stress_mpa
            0.4379421   ACCEPTED         13685.73152        13685.73152        1.5   0.004018784084  
            0.2627010   ACCEPTED         7993.380597        7993.380597        1.5    0.00688069326  
            0.2067524   ACCEPTED         1760.593161        1760.593161        1.5    0.03123947157  
            0.1318328   ACCEPTED         947.6743811        947.6743811        1.5    0.05803681212  
    -> FIXED        flips=0 worst_rel_delta=n/a  (HEAD REFUSED, NEW produced 4 rung(s) — THE FIX)

Z  X + lattice (latticed certification)
    HEAD   (no report.json — the run REFUSED)
    NEW    printed_fr   verdict     margin_worst_case  margin_effective   required   max_stress_mpa
            0.4379421   ACCEPTED         13685.73152        13685.73152        1.5   0.004018784084  
            0.2627010   ACCEPTED         7993.380597        7993.380597        1.5    0.00688069326  
            0.2067524   ACCEPTED         1760.593161        1760.593161        1.5    0.03123947157  
            0.1318328   ACCEPTED         947.6743811        947.6743811        1.5    0.05803681212  
    -> FIXED        flips=0 worst_rel_delta=n/a  (HEAD REFUSED, NEW produced 4 rung(s) — THE FIX)

==============================================================================
 SUMMARY
==============================================================================
  IDENTICAL    A  no design box + lattice, self-weight, NO clearance rung-for-rung
  IDENTICAL    B  design box, no lattice, self-weight, NO clearance rung-for-rung
  IDENTICAL    C  design box + 4 keep-clears + DECLARED LOAD + lattice rung-for-rung
  IDENTICAL    D  design box + self-weight + lattice, NO clearance rung-for-rung
  IDENTICAL    Y  NO box + 4 keep-clears + self-weight      rung-for-rung
  FIXED        X  design box + 4 keep-clears + self-weight  [THE DEFECT] HEAD REFUSED, NEW produced 4 rung(s) — THE FIX
  FIXED        Z  X + lattice (latticed certification)      HEAD REFUSED, NEW produced 4 rung(s) — THE FIX

  TOTAL VERDICT FLIPS: 0

==============================================================================
 NEGATIVE CONTROL — the comparison must be able to FAIL
==============================================================================
  comparing two DIFFERENT jobs -- A  no design box + lattice, self-weight, NO clearance  vs  B  design box, no lattice, self-weight, NO clearance
  -> flips=0 worst_rel_delta=0.738577  (rung-for-rung)
  the comparator DOES detect a difference at this floor: the IDENTICAL verdicts above are real.
```

**TOTAL VERDICT FLIPS: 0.** Every identity bar matches rung for rung with a
worst relative delta of **exactly 0** — not "within the floor", zero. X and Z go
from REFUSED to four ACCEPTED rungs. The negative control fires (relative delta
0.738577 between two genuinely different jobs), so the comparator can fail and
the IDENTICAL verdicts mean something.

### SW6 — determinism and the suite

```
SW6 DETERMINISM — the fixed binary, same job twice, on this machine
==================================================================

unit test (test_selfweight_clearance_void), run twice:
  IDENTICAL output, both runs
29 checks, 0 failures

JOB                                      RUN-1              RUN-2              VERDICT
D                                        341fb509eeaf2623   341fb509eeaf2623   IDENTICAL
Y                                        48687b9a1a600e41   48687b9a1a600e41   IDENTICAL
ZV                                       1f9db01075f5035e   1f9db01075f5035e   IDENTICAL
ZA                                       d8705509cc102b23   d8705509cc102b23   IDENTICAL
```

Four jobs and the unit test, each run **twice with the same fixed binary**, every
artefact compared: identical. `ZV` (lattice_variant) and `ZA` (analyze) are the
two re-certification callers exercised end to end; `Y` and `D` are the
byte-identity bars re-run against themselves.

The expensive specimen `X` is not in this table, deliberately — its later rungs
sit in the stagnation regime described below and two full passes cost more wall
than the bar is worth. Its determinism is covered anyway: **X and Z are separate
CLI invocations of different jobs that share one load case, and they produced
the identical four-rung table to ten significant digits** (see SW5). That is the
same claim from two independent runs.

**Full suite: `ctest` 99/99, 100% passed** (372.84 s). The count is 99 because
this task adds one test to the 98 the branch inherits (97 on `main` + 1 from
PR 285).

### What the fix does NOT buy: X is now slow, and that is a separate problem

The run completes; it is not fast. On the res-32 specimen the later rungs fall
into the **documented multigrid stagnation** on dilute design-box fields — the
per-run latch fires, `cg_multigrid` flips to 0, and the solve reverts to
Jacobi-CG:

| rung | `cg_multigrid` | CG iterations per MMA step | wall per step |
|---|---|---|---|
| 0 | 1 | ~98–100 | ~0.28 s |
| 2 | **0** | **~1 100–1 600** | **~0.9–1.3 s** |

That is the adversarial-coefficient regime `multigrid.cpp` and
`expand_design_domain`'s own comments already warn about (a large clearance
keep-out void against a ~1e-9-contrast SIMP field), and it is **pre-existing and
unrelated to this change** — the pre-fix binary never reached it because it
crashed at the very first solve. Nothing here makes it worse; it simply becomes
visible now that the run gets that far. Stated plainly so nobody reads "the crash
is fixed" as "the job is quick".

---

## 4. Something else the audit found, which is NOT this defect

`analyze` in **loadcase form with anchors and zero force groups** refuses on this
fixture:

```
--mesh   : fea_solve_mgcg_matfree: under-constrained system (load applied to a void DOF ...)
no --mesh: recommend_settings: worst_case_stress_margin must be finite and >= 0
```

It is **not** this task's defect and the fix does not touch it. Three
independent reasons, each checkable:

* it reproduces with the clearances **removed**;
* it refuses **identically on both binaries** — job `ZQ` in the harness, given
  byte-identical arguments, prints the same message before and after
  (`both REFUSED (unchanged)`, `identical even raw`, in the checksum table);
* the same analyze in the `fixture_faces` + `gravity` self-weight form
  **succeeds** on both — that is job `ZA`, which certifies the mesh job `Z`
  produced.

Recorded as `jobs/ZQ_analyze_loadcase_no_groups.json` so the claim is checkable
rather than asserted, and filed as its own task.

One caveat on how it was measured: the first harness pass gave the two binaries
*different* arguments here (HEAD had no mesh to pass, because `Z` refuses there),
which made HEAD and NEW print different messages for what looked like the same
job. The harness now runs `ZQ` without `--mesh` on both sides deliberately, and
the messages match. Flagging it because the first reading looked like a
difference and was not one.

---

## 5. In plain language

**What was broken.** When you draw a design box so the optimizer can *add*
material, and you also mark a "keep clear" region inside that added space, and
you have not told the app which way you are pushing on the part — so it falls
back to weighing the part under gravity — the run died with a message about an
"under-constrained system". No result, no partial answer, just a refusal.

**Why.** Two different parts of the code disagreed about whether material was
there. The part that computes weight looked at the design box and said "the whole
box is full of plastic, weigh all of it". The part that decides where material is
allowed looked at your keep-clear and said "not here". So gravity was being
applied to plastic that had already been deleted — and the solver, correctly,
refused to pretend that hanging weight on nothing has an answer.

**How long.** Since 17 July, when keep-clear regions were added. It is not a new
bug and it is not caused by the design-box work now in review; that work moved
this code, it did not break it.

**What changed.** One shared piece of code now decides both questions, so they
cannot disagree. Weight is applied to the material that is actually there, and
nowhere else. The audit found the same mistake in a second place — an optional
speed-up path that builds its own gravity load — and fixed that too.

**What did not change.** A run with no keep-clear produces byte-for-byte the same
files as before — same meshes, same report, same numbers. A run that declares an
actual load (a force you pointed at a face) never used gravity for this in the
first place and is untouched. **No accept/reject verdict moved anywhere in the
gate table.** The weight that disappears is exactly the weight of the plastic the
keep-clear removed: 1 751.6736 N on the test specimen, which is 144 voxels times
the weight of one voxel — not a fudge factor, the actual arithmetic.

**What to expect when you run it.** The job now finishes, but on the test part it
is **slow** — several minutes, not seconds. That is a different, older weakness:
on a design box with a large keep-clear hole in it, the fast solver gives up
partway down the ladder and falls back to a much slower one. Nothing here caused
that; the old code simply never got far enough to meet it, because it crashed on
the very first calculation. Worth knowing so "the crash is fixed" is not read as
"the job is quick".

**One thing to know.** Separately, `analyze` refuses when it is given anchors but
no forces. That is an older, different problem — it happens with keep-clears
switched off and it happens the same way before and after this change — and it
deserves its own fix.

---

Related: [[designbox-recert-shipped]] (PR 285, which this stacks on),
[[clearance-regions-shipped-100]] (which introduced the overlay),
[[designbox-whole-domain-optimize-080]].
