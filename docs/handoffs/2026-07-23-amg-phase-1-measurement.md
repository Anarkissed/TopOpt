# AMG Phase 1 — the second measurement: does the win survive a MEMORY-LEAN rebuild?

**Status:** Measurement complete. **NO production code changed** — `git diff main --
core/src core/include app` is **empty**; `git status` shows two new files under
`core/tests/harness/`, this handoff, and its evidence directory. Deliverable =
this handoff + a committed, reproducible harness.

**VERDICT: NO-GO on the bars as written** — B1 (memory) fails at every extent,
B2's iteration-win band is missed on 2 of 5 fixtures, and B3 fails on the one
real-optimizer-output fixture. **Per the task's own rule the Phase-2 wiring
sketch is NOT written here;** §7c states what would have to change instead.

**The substance moved a long way, and §7b states it separately from the verdict:**

- **131 §7a option A is feasible and VERIFIED.** A fully matrix-free fine level
  works — no fine matrix exists at any point, 078's property restored — and every
  new element-local kernel is checked against an assembled reference: strength
  graph and `A·T` **bit-identical**, Galerkin to **4.4e-15** relative (§0c).
- **Memory fell 9.8×**: 131 §6c's **2 071.6 MB / 23.3×** → **210.7 MB / 2.37×** at
  804 864 DOF. The 2.0× bar is missed by 0.37×, and §3c shows the miss is
  structural: P₀ + bookkeeping is already 1.19× of the baseline before a single
  coarse operator exists, because an algebraic hierarchy must *materialise* the
  interpolation a geometric one gets for free as a stencil.
- **The 131 §2d developed-field collapse is CURED — and the cure is the
  UNSMOOTHED prolongator, not the coarsening caps** (§2b). Coarsening ratios stop
  collapsing (2.98 at the bottom, not 1.35), coarse stencils *shrink* with depth
  (106 → 43 nnz/row, not 322 → 3 600 fully dense), setup is **31× cheaper**,
  memory **14.2× smaller**, and the developed-field wall-clock goes from
  **1.11× SLOWER to 2.95× FASTER**. 131 §6d's measured lead was the right lead,
  and promoting it to a first-class configuration is what this rebuild turned on.
- **The carry property survives, 5 of 5** — but at 1.8–2.7× more cycles than
  131's assembled prototype, traceable to the one substitution a matrix-free fine
  level forces: **Chebyshev instead of Gauss-Seidel** (§4c, §5d).
- **A REGIME SPLIT is now measured, not assumed** (§6b). On the one fixture whose
  field is real optimizer output — the shared ultra-dilute ACTIVE-DOMAIN box at
  48.8× dilution — **geometric multigrid does not stagnate at all** (`used_mg=1`,
  26 cycles) and lean AMG is **2.2× slower**. Every fixture where AMG wins is one
  where geometric has already failed.

**Track:** core measurement only. **Parallel-legal:** adds files, edits none —
`git status` shows exactly two new sources under `core/tests/harness/` plus this
handoff and its evidence directory. `amg_sa.hpp` and `amg_probe.cpp` (handoff
131's harness) are **not touched**, so every Phase-0 number stays reproducible
from its own source.

**Naming:** this is the first handoff under the new convention —
`docs/handoffs/YYYY-MM-DD-<task-slug>.md`, evidence under
`docs/handoffs/evidence/YYYY-MM-DD-<task-slug>/`. No number is taken.

**Lineage note, because the task's pointer was one hop off.** The task names
"handoff 135 §7 option A". There is no handoff 135; the AMG Phase-0 handoff is
[`131-amg-phase-0-feasibility.md`](131-amg-phase-0-feasibility.md), and its §7a
option A is the section meant — *element-local AMG, the only shippable shape*.
Everything below cites 131 by section.

---

## 0. WHAT WAS BUILT

Two files, both harness-only, neither compiled into `libtopopt.a`, neither
referenced by CTest, neither included by any production translation unit:

| file | what it is |
|---|---|
| `core/tests/harness/amg_lean.hpp` | The **memory-lean** aggregation AMG. Level 0 is **fully matrix-free**: the operator is the production `fea_detail::MatfreeReduced` and every fine-level action — smoothing, residual, CG matvec — goes through its element-by-element `apply_kgg_raw`. The three setup quantities that classically need `A`'s rows are streamed from the element table through a node→element incidence list, one node row at a time. Only levels ≥ 1 are assembled CSR. |
| `core/tests/harness/amg_lean_probe.cpp` | The driver: fixtures, the production geometric/Jacobi baselines, the kernel-verification gate, and the four bars. Modes: `verify correctness memory memsweep nullspace coarsening stagnation developed ultradilute determinism all`. |

### 0a. What is and is NOT assembled — the whole point of Phase 1

131 §6c named the blocker: its prototype assembled the fine matrix, i.e. put back
exactly the object 078 removed because it OOMs on design-box grids, and paid
**2 071.6 MB** for a hierarchy against the production matrix-free hierarchy's
**88.9 MB** at 804 864 DOF (**23.3×**).

In this rebuild **no fine matrix exists at any point**:

* **Smoothing** — matrix-free. Gauss-Seidel needs `A`'s rows, so the fine level
  uses **Chebyshev** (degree 2 by default) over `[λ/8, 1.1λ]`, driven by matvecs
  and the Jacobi diagonal `mf_build_reduced` already computes. Damped Jacobi is
  available at degree 0. This is a real substitution and it is charged honestly:
  the coarse levels still use symmetric Gauss-Seidel, the fine level cannot.
* **Residual and CG matvec** — the production `apply_kgg_raw`.
* **Strength graph** — streamed. For each node in ascending order the harness
  accumulates that node's assembled 3×3 blocks from its ≤ 8 incident elements,
  takes the block Frobenius norms, applies the same Vanek test 131 used, emits
  the strong neighbours, and **throws the blocks away**. O(1) extra memory per
  node.
* **The Gershgorin bound of `D⁻¹A`** — from the same stream, exactly (not an
  element-wise upper bound).
* **`A·T`, the only product a SMOOTHED prolongator needs** — the same stream.
* **The coarse operator `A1 = P₀ᵀ A P₀`** — the **element-local triple product**,
  `Σ_e Pe ᵀ Ke Pe`, which is the trick 078/090 already pull for the geometric
  hierarchy.

The element table, the reduced bookkeeping and the Jacobi diagonal are the
production solver's **own** cost (`mf_build_reduced` builds them for the geometric
path too), so they are reported separately from what AMG *adds*.

### 0b. The unsmoothed variant is FIRST CLASS, as the task required

131 §6d measured that dropping prolongator smoothing (`P = T`) costs 1.76× the
cycles but **12× less setup and 2.2× less memory**, and still carries the
stagnating solve. Forming `T` needs only the aggregation — never `A`'s rows —
which is precisely the property a matrix-free fine level wants. So
`LeanOptions::smooth_prolongator` **defaults to FALSE** here (it defaults to
true in `amg_sa.hpp`), every table below reports the unsmoothed variant as the
headline configuration, and the smoothed variant is measured beside it.

### 0c. The kernels are VERIFIED, not asserted

This is the gate that makes the rebuild trustworthy. `./amg_lean_probe verify`
builds a reference `A` by applying the **production matrix-free operator** to
unit vectors — so no separate assembler exists to drift — and compares every new
element-local kernel against the assembled computation on the same system:

```
   fixture 10x10x10, reduced DOF = 3630
   reference A built from 3630 matrix-free applies: nnz=242172 (66.7/row)
   [1] strength graph      : IDENTICAL (19042 strong edges; nnz/row lean=66.7 ref=66.7)
   [2] Gershgorin lambda   : lean=5.930693069 ref=5.930693069 rel=0.00e+00 PASS
       aggregates=64 coarse DOF=384
   [3] A*T (smoothing)     : pattern IDENTICAL, max|diff|=0.000e+00 relative=0.000e+00 PASS
   [4] Galerkin P=unsmoothed: lean nnz=35640 ref nnz=35245 | max|diff|=1.251e-12 relative=1.870e-15 PASS
   [4] Galerkin P=smoothed  : lean nnz=62352 ref nnz=62323 | max|diff|=1.705e-12 relative=4.406e-15 PASS
```

The strength graph and `A·T` are **bit-identical** to the assembled reference.
The Galerkin operator agrees to **1.9e-15 / 4.4e-15** relative — floating-point
summation order only, which is expected because the element-local product sums
in element order and the assembled one sums in row order. The lean Galerkin's
nnz is slightly **higher** (35 640 vs 35 245) because it emits the full aggregate
block including entries that cancel to exactly zero; the value comparison above
walks both patterns and charges every unmatched lean entry as a difference, so
those extra structural zeros are inside the 4.4e-15.

### 0d. Correctness against the library's own solver

```
   reference matrix-free Jacobi-CG: iters=172 resid=7.79e-11 converged=yes
   P=unsmoothed LEAN-PCG cycles=31 resid=6.79e-11 | relative=5.385e-12  PASS (bar <= 1e-8)
   P=smoothed   LEAN-PCG cycles=62 resid=9.23e-11 | relative=1.702e-12  PASS (bar <= 1e-8)
```

Relative difference **5.4e-12 / 1.7e-12** against a **1e-8** bar, on a 16³ solid
box at tolerance 1e-10.

### 0e. B4 DETERMINISM — PASS, every case

Two independent setups **and** two independent solves per case, `memcmp` on every
level's `A`/`P`, on the residual history and on the solution vector:

```
   solid32                     P=unsmoothed : IDENTICAL   P=smoothed : IDENTICAL
   occ0.40+bore0.40 100x96x96  P=unsmoothed : IDENTICAL   P=smoothed : IDENTICAL
   LATTICE solid_box_48        P=unsmoothed : IDENTICAL   P=smoothed : IDENTICAL
   B4 VERDICT: PASS
```

Bit-identity, not agreement-to-tolerance. Determinism is by construction — no
randomness, ascending traversal everywhere, smallest-index tie-breaks, sorted
column emission, a closed-form Gershgorin scale rather than a power iteration —
and the one threaded kernel is the production `mf_apply_full`, whose 8-colour
fixed-order scatter is documented and tested identical across thread counts.

---

---

## 1. THE BARS, AND THE FIXTURES

### 1a. The bars, stated before measuring

They are printed by the harness itself (`amg_lean_probe.cpp`, top of file) and
the B1 baseline is printed **before** any AMG number, as the task required.

| bar | statement |
|---|---|
| **B1 MEMORY** | peak AMG memory ≤ **2.0×** the matrix-free baseline at real extents. Baseline = what the production geometric matrix-free hierarchy stores, via `fea_matfree_mgcg_assembled_operator_nonzeros × 12 bytes` — the **same estimator 131 §6c used** for its 88.9 MB. That header documents this count as **coarse-only** on the matrix-free path, so the comparison is like for like: *what AMG adds* against *what the geometric hierarchy stores*. |
| **B2 CARRY** | the 131 §5d property must survive the lean rebuild: on every fixture where the geometric path cannot converge, lean AMG builds and carries, with an outer-iteration win in 131's 23–103× band. |
| **B3 END-TO-END** | on **developed** fields, lean AMG total (setup + solve) ≥ **1.0×** the current solver's total — no regression. |
| **B4 DETERMINISM** | bit-identical twice-run: two independent setups **and** two independent solves, `memcmp` on operators, residual histories and solutions. |

**Any bar failed = honest NO-GO with the table, and the Phase-2 wiring sketch
stays unwritten.** §6 says which way it went.

### 1b. Fixtures

* **The 131 family**, re-derived by the identical rule. The fixture builder in
  `amg_lean_probe.cpp` is a copy of `amg_probe.cpp`'s, so Phase-0 tables stay
  directly comparable and 131's harness is not edited. Provenance is checked the
  same way 131 checked its own: the geometric baseline must reproduce 125's
  signature, and it does (§3, §4).
* **The developed-field fixtures** are 131 §2d's synthetic lattice, verbatim:
  thin axial columns on an 8-voxel pitch, 2 voxels thick, a tie layer every 16 in
  z, ρ=1.0 against ρ=0.02, giving ≈1.25×10⁵ modulus contrast on sub-coarse-cell
  members. **Synthetic, not optimizer output** — 131's scope note applies here
  unchanged.
* **The shared ULTRA-DILUTE fixture** (§5), which *is* optimizer output.

### 1c. The ultra-dilute fixture, and an honest scope correction

The task says to consume the ultra-dilute capture committed by **ACTIVE DOMAIN
Phase 1 step 1**. **That artifact does not exist.** At the time of measurement the
`claude/active-domain-phase-1-580ef7` lane has uncommitted production edits and
**no capture, committed or otherwise** — checked directly, not inferred.

What this handoff consumes instead is the **committed ACTIVE DOMAIN Phase-0
artifact**, which is the same fixture one phase earlier:

* the fixture rule, from the committed
  `core/tests/harness/active_domain_probe.cpp` —
  `dilute_box(bx 48, by 32, bz 48, arm 24, span 24, ny 6, t 6, h 1.0, tip 30.0)`;
* the capture it must match, `docs/handoffs/evidence/134/ultradilute_stdout.txt`:
  *"box 48x32x48 = 73728 elements, part 1512 voxels (2.05% fill, 48.8x
  dilution)"*;
* the field recipe, from the same source: 40 OC iterations at the **part-relative**
  rung `vf 0.26`, `physical_filter_radius(2.5, spacing)`, move 0.2, CG tol 1e-8,
  `SolverKind::MultigridCG_Matfree`.

§5 reproduces those numbers digit-for-digit before it measures anything, so the
provenance is checkable. **What is lost by the substitution:** handoff 134 §1c is
explicit that the AD Phase-0 ultra-dilute row is *"a harness OC run, not a driver
MMA run"*, and that a converged well-resolved ultra-dilute **driver** capture is
the single biggest gap in that Phase 0. That gap is inherited here verbatim. When
AD Phase 1 commits its driver capture, §5 is the section to re-run against it —
one fixture swap, no other change.

### 1d. COARSENING CONTROL — the stated rule

131 §2d diagnosed the developed-field failure mode precisely: the coarsening ratio
collapses down the hierarchy (10.6× → 5.1× → 3.1× → **1.35×**) and the coarse
operators fill in until a level is **100 % dense** (3 600 nnz/row on 3 600 rows),
which is what makes setup explode 6.7× and memory reach 3.3 GB. 131 §4b records
the levers as **not swept**. This is the rule that bounds it, applied at **every**
level including level 1 (`amg_lean.hpp:admit_level`):

> A candidate coarse level is **ADMITTED** iff
> **(1)** coarsening ratio `n_fine / n_coarse ≥ min_coarsening_ratio`, **AND**
> **(2)** *either* it is small enough to be the bottom
> (`n_coarse ≤ coarse_dof_cap`, where a dense operator is cheap and gets a direct
> dense LDLᵀ), *or* all of
> **(2a)** stencil `nnz/n ≤ max_nnz_per_row`,
> **(2b)** density `nnz/n² ≤ max_level_density`,
> **(2c)** growth `(nnz/n) / (parent nnz/n) ≤ max_stencil_growth`.
> A rejected candidate is **discarded** and its parent becomes the bottom level.

Defaults: `min_coarsening_ratio 2.0`, `max_nnz_per_row 400`,
`max_level_density 0.10`, `max_stencil_growth 8.0`, `coarse_dof_cap 1200`.

Phase 0 had only clause (1), at **1.15** — which is exactly why it tolerated a
1.35× ratio and a 100 %-dense level. Clause (2a) names 131's 3 600 nnz/row
directly; (2b) catches the same failure scale-free; (2c) catches the fill-in ramp
before it completes.

**One wording note on the evidence.** `coarsening_out.txt`'s printed header
describes an earlier three-clause draft of this rule (it predates the
`max_nnz_per_row` clause and the bottom-level exemption). The committed
`admit_level` is the rule quoted above and is what produced every number in the
table; the sweep's own columns carry the actual `max_nnz_per_row` value per row.

---

## 2. COARSENING CONTROL — the 131 §2d disease, and what actually cures it

**Fixture: the 131 §2d developed-field lattice on the clean `48³` box** — the one
131 §2e reports AMG carrying at **4.1× SLOWER** than the failing geometric path.
Geometric baseline here: `hier=1 used_mg=0 mg_cycles=300 cg_iters=3565`, 29.74 s.
**That is 131's number digit-for-digit** (131 §2d: `mg_cycles=300 cg_iters=3565`),
so the fixture is provably the same one.

| configuration | levels | worst nnz/row | PCG cycles | setup s | solve s | AMG MB | vs 43.8 MB baseline |
|---|---:|---:|---:|---:|---:|---:|---:|
| **PHASE-0 SETTINGS** (smoothed P, ratio 1.15, no caps) | 5 | **2 256** | 89 | **67.71** | 18.90 | **972.6** | **22.20×** |
| phase-0 knobs, **unsmoothed P** | 4 | **113** | 160 | **1.20** | 8.52 | **102.3** | 2.34× |
| control ON (ratio 2.0, 400 nnz/row, 0.10) | 4 | 113 | 160 | 1.22 | 7.67 | 102.3 | 2.34× |
| control ON + θ 0.02 | 4 | 113 | 183 | 1.08 | 8.63 | 95.8 | 2.19× |
| control ON + θ 0.04 | 4 | 113 | 182 | 1.08 | 8.42 | 97.3 | 2.22× |
| control ON + θ 0.16 | 2 | 129 | 310 | 1.66 | **75.22** | 171.3 | 3.91× |
| **control TIGHT** (ratio 4.0, 200 nnz/row, 0.02) | 2 | 113 | 245 | 1.17 | 22.93 | **85.4** | **1.95×** |
| control ON, **smoothed P** | 2 | 353 | 178 | 18.11 | 54.17 | 337.3 | 7.70× |
| control LOOSE (ratio 1.5, 1200 nnz/row) | 4 | 113 | 160 | 1.24 | 7.80 | 102.3 | 2.34× |

### 2a. The first row is the control, and it reproduces 131 exactly

Run at Phase-0's settings the lean rebuild reproduces the disease: **5 levels, a
2 256-nnz/row level, 67.7 s of setup, 972.6 MB.** 131 §2d measured the same
hierarchy shape on the same fixture (level 3 at 2 256 nnz/row) and **88 cycles**
against this run's 89. The only difference is memory — 972.6 MB here against
131's 1 464.7 MB — and the difference is exactly the fine matrix that no longer
exists. **The rebuild is measuring the same object 131 measured.**

One wall-clock discrepancy, disclosed rather than smoothed: 131 §2d measured this
fixture's geometric baseline at **18.70 s**, this run at **29.74 s**. The
*deterministic* parts agree exactly (300 cycles, 3 565 Jacobi iterations); only
the seconds differ, which is the ±30 % band 131 §6a already documented on a
contended box. Every wall-clock ratio below is computed against the baseline
measured **in the same process on the same run**, never against 131's seconds.

### 2b. What cures the collapse is the UNSMOOTHED prolongator, not the caps

This is the honest reading of the table and it is not the one the section title
predicted. Compare rows 1 and 2 — **the only change is `P = T`**:

| | smoothed P | unsmoothed P | factor |
|---|---:|---:|---:|
| worst coarse stencil | 2 256 nnz/row | **113 nnz/row** | **20× sparser** |
| setup | 67.71 s | **1.20 s** | **56× cheaper** |
| memory | 972.6 MB | **102.3 MB** | **9.5× less** |
| PCG cycles | 89 | 160 | 1.80× worse |
| **total (setup + solve)** | **86.6 s** | **9.7 s** | **8.9× faster** |

131 §6d predicted the direction from the iteration-0 field (12× setup, 2.2×
memory, 1.76× cycles). On the **developed** field — the case 131 §2d could not
fix — the same lever is worth **56× setup and 9.5× memory** for the same 1.8×
cycle penalty, and it is what turns 131's *4.1× slower* into **3.06× faster**
(9.7 s against the geometric path's 29.74 s).

**The coarsening-control clauses, at the default setting, never fire.** Rows 2, 3
and 9 are identical to the decimal: with an unsmoothed prolongator the coarsening
simply does not degenerate — the ratio stays above 2 and the stencil stays at 113
nnz/row, so `min_ratio 1.15`, `2.0` and `1.5` all produce the same hierarchy. The
rule is therefore a **guard, not the cure**, and the handoff says so rather than
claiming credit for it.

### 2c. Where the guard DOES earn its place

Three rows show it firing, and each is a failure it caught:

* **smoothed P**: `level 2 REJECTED: stencil 1496.0 nnz/row > 400.0`. Without the
  cap this is the Phase-0 fill-in ramp resuming; with it the hierarchy stops at 2
  levels and 337 MB instead of continuing to 972 MB.
* **θ 0.16**: `level 2 REJECTED: coarsening ratio 1.882 < 2.0`. Weak coupling
  admits too few strong edges, aggregates come out small, and the ratio collapses
  — 131 §2d's exact signature, caught at the first level it appears.
* **TIGHT**: `level 2 REJECTED: operator density 0.0224 > 0.0200`, which is what
  buys the 1.95× memory in §3.

So the rule is doing real work; it is simply not the thing that repaired the
developed-field economics. The measured order of importance is
**prolongator smoothing ≫ strength threshold > the density caps**.

### 2d. The cost the guard imposes, stated plainly

A rejected level leaves a bottom too big for a dense direct solve, and the
harness says so (`bottom level n=30450 > dense cap: smoothed, not solved
exactly`). That bottom is then only smoothed, which is why TIGHT needs 245 cycles
against the default's 160 and θ 0.16 needs 310 with a 75 s solve. **Memory bought
by rejecting a level is paid for in cycles**, and §3 shows the exchange rate at
real extents.

---

## 3. B1 — MEMORY, with the hard number

### 3a. The baseline, stated first

```
  Baseline = what the PRODUCTION geometric matrix-free hierarchy stores
  (fea_matfree_mgcg_assembled_operator_nonzeros x 12 bytes — the same
  estimator 131 §6c used for its 88.9 MB figure).
```

`fea.hpp` documents that count as **coarse-only** on the matrix-free path (the
fine level stores just the 576-double reference `Ke`), so the comparison is
*what AMG adds* against *what the geometric hierarchy stores* — like for like.
At the real padded extents `192×112×128`, `occ 0.40 + bore 0.40`, **804 864
reduced DOF**, that baseline is **88.9 MB** — the same number 131 §6c quotes.

### 3b. The result, against the 2.0× bar

| fixture | red. DOF | matfree baseline | **AMG unsmoothed** | AMG smoothed | ratio | B1 |
|---|---:|---:|---:|---:|---:|---|
| `192×112×128` occ0.40+bore0.40 | 804 864 | **88.9 MB** | **210.7 MB** | 676.9 MB | **2.37×** | **FAIL** |
| `100×96×96` occ0.40+bore0.40 | 142 848 | 11.2 MB | 35.7 MB | 88.6 MB | 3.18× | FAIL |
| healthy `48³` | 345 744 | 43.8 MB | 104.4 MB | 316.7 MB | 2.38× | FAIL |

**B1 FAILS as literally written, at 2.37× on the fixture the bar names.** That is
stated first and without softening.

What it fails *from* matters as much as the verdict: 131 §6c measured **2 071.6 MB
at 23.3×** on this exact fixture. The lean rebuild is **210.7 MB at 2.37×** — a
**9.8× reduction**, and 078's property is genuinely restored (no fine matrix
exists at any point; §0c proves the kernels that replaced it are exact). The bar
is missed by **0.37×**, not by an order of magnitude.

### 3c. Why it is missed — the number that explains it

The `memsweep` breakdown decomposes the 210.7 MB:

| component | MB | what it is |
|---|---:|---|
| **P₀** | **61.4** | the prolongator. Unavoidable: an algebraic hierarchy must **materialise** its interpolation; a geometric one gets it as a stencil for free. 6 near-nullspace modes × 804 864 rows is its floor. |
| coarse operators (3 levels) | 104.8 | the only part the coarsening control can move |
| AMG-side bookkeeping | 44.5 | node→element incidence, the reduced↔node maps, three `ng`-length work vectors |
| **total** | **210.7** | **2.37×** |

**P₀ + bookkeeping alone is 105.9 MB = 1.19× the baseline before a single coarse
operator exists.** The 2.0× bar therefore leaves ~71 MB for the whole coarse
hierarchy, and three levels of it cost 104.8 MB. That is the structural reason
the bar is tight, and it is not a tuning failure: it is the price of algebraic
interpolation.

(The bookkeeping column is charged to AMG even though the production solver pays
its own equivalents — the three `ng`-length work vectors in particular are CG
scratch that any solver needs. That is the conservative choice; excluding just
those 19.3 MB would read 2.15×, still a fail.)

**On the two RSS figures the fixture reports print.** `RSS delta over setup` is
the resident-set change across `lean_setup` alone, and it is *smaller* than the
hierarchy bytes (88.3 MB against 210.7 MB) because the allocator reuses pages the
baselines had already touched — it is a floor, not the cost. `process peak` is
`getrusage`'s high-water mark for the **whole process**, so it accumulates across
the geometric baseline, the Jacobi baseline and every fixture run before it; it
is reported for transparency and is **not** a per-hierarchy number. The claim in
this section is the byte accounting, which is exact and deterministic.

### 3d. Is the bar reachable? — the θ sweep at real extents

`192×112×128` occ0.40+bore0.40, 804 864 DOF, baseline 88.9 MB:

| θ | levels | P₀ MB | coarse MB | book MB | **AMG MB** | vs base | cycles | setup s |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0.02 | 4 | 61.4 | 112.4 | 44.5 | 218.3 | 2.46× | 79 | 2.3 |
| 0.04 | 4 | 61.4 | 121.8 | 44.5 | 227.7 | 2.56× | 70 | 2.4 |
| **0.08** (default) | 4 | 61.4 | 104.8 | 44.5 | **210.7** | **2.37×** | **66** | 2.6 |

`100×96×96`, 142 848 DOF, baseline 11.2 MB:

| θ | levels | P₀ MB | coarse MB | book MB | AMG MB | vs base | cycles | setup s |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **0.02** | 3 | 10.9 | 24.2 | 7.4 | 42.4 | 3.78× | **60** | 0.5 |
| 0.04 | 4 | 10.9 | 16.8 | 7.4 | 35.0 | 3.12× | 140 | 0.3 |
| 0.08 (default) | 4 | 10.9 | 17.4 | 7.4 | 35.7 | 3.18× | 142 | 0.3 |

`192×112×128` **LATTICE** (developed), 804 864 DOF, baseline 88.9 MB:

| θ | levels | P₀ MB | coarse MB | book MB | AMG MB | vs base | cycles | setup s |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0.02 | 5 | 61.4 | 117.1 | 44.5 | 223.0 | 2.51× | **400\*** | 2.4 |
| 0.04 | 5 | 61.4 | 117.8 | 44.5 | 223.6 | 2.52× | 362 | 2.4 |
| 0.08 (default) | 5 | 61.4 | 126.6 | 44.5 | 232.5 | 2.62× | 362 | 2.5 |

(\* did not converge within 400 cycles.)

**The strength threshold does not reach the memory bar at any extent or on any
field** — it moves memory by ±8 % on the big fixtures and *upward* on the small
one, and it never approaches 2.0×.

**But it does repair §4b's band miss, and that is the more useful finding.** On
`100×96×96` the default needs 142 cycles (11.3× over the Jacobi fallback, below
131's band); **θ 0.02 needs 60 — a 26.8× win, inside the band** — for 19 % more
memory. So B2's band miss on that fixture is a **tuning artifact of an unswept
knob**, not a property of the lean rebuild. The same knob is harmful on the
developed lattice (θ 0.02 fails to converge in 400 cycles there), so it is not a
new default — it is evidence that θ wants to be measured per regime, which
131 §4b already listed as unswept.

### 3e. The lever that DOES reach the bar — and why taking it is the wrong trade

The memory floor of an algebraic hierarchy is P₀, and its width is set by the
near-nullspace size `k`. `k = 6` is 3 translations + 3 rotations; `k = 3` is
translations only, which halves P₀ and shrinks every coarse operator ~4×.

`192×112×128` occ0.40+bore0.40, 804 864 DOF, baseline 88.9 MB:

| k | control | P₀ MB | coarse MB | **AMG MB** | vs base | **B1** | cycles | setup s |
|---:|---|---:|---:|---:|---:|---|---:|---:|
| 6 | default | 61.4 | 104.8 | 210.7 | 2.37× | FAIL | **66** | 2.6 |
| 6 | TIGHT | 61.4 | 104.8 | 210.7 | 2.37× | FAIL | 66 | 2.6 |
| **3** | default | 33.8 | **25.1** | **103.3** | **1.16×** | **PASS** | **226** | 1.4 |
| 3 | TIGHT | 33.8 | 25.1 | 103.3 | 1.16× | PASS | 226 | 1.3 |

**B1 is reachable — comfortably — at `k = 3`: 103.3 MB, 1.16× the baseline.** It
costs **3.4× the cycles** (66 → 226).

`192×112×128` **LATTICE** (developed), 804 864 DOF, baseline 88.9 MB:

| k | control | P₀ MB | coarse MB | **AMG MB** | vs base | **B1** | cycles | setup s |
|---:|---|---:|---:|---:|---:|---|---:|---:|
| 6 | default | 61.4 | 126.6 | 232.5 | 2.62× | FAIL | **362** | 2.6 |
| 6 | TIGHT | 61.4 | 116.2 | 222.1 | 2.50× | FAIL | 530 | 2.6 |
| **3** | default | 33.8 | 41.0 | **119.3** | **1.34×** | **PASS** | **600\*** | 2.6 |

| 3 | TIGHT | 33.8 | 41.0 | 119.3 | 1.34× | PASS | 600\* | 3.2 |

`48³` **LATTICE** (developed), 345 744 DOF, baseline 43.8 MB:

| k | control | P₀ MB | coarse MB | **AMG MB** | vs base | **B1** | cycles | setup s |
|---:|---|---:|---:|---:|---:|---|---:|---:|
| 6 | default | 26.4 | 56.5 | 102.3 | 2.34× | FAIL | **160** | 1.2 |
| 6 | **TIGHT** | 26.4 | 39.6 | **85.4** | **1.95×** | **PASS** | 245 | 1.2 |
| 3 | default | 14.5 | 14.3 | 48.3 | 1.10× | PASS | 283 | 0.6 |
| 3 | TIGHT | 14.5 | 10.0 | **43.9** | **1.00×** | PASS | 285 | 0.6 |

(\* did not converge within 600 cycles.)

**On the big developed field the `k = 3` trade is not merely expensive — it does
not converge at all** within 600 cycles, while `k = 6` converges in 362. On the
smaller `48³` lattice it does converge, at 1.8× the cycles. TIGHT, where it binds,
buys 0.12–0.39× of memory for 1.46–1.53× the cycles.

Two things this settles:

1. **The coarsening control cannot reach B1 at the real extents, and the
   near-nullspace can.** TIGHT is byte-identical to default on the 804 864-DOF
   stagnation fixture — the caps never bind there, because with an unsmoothed
   prolongator the hierarchy is already well-behaved (§2b). It *does* bind on the
   two developed fixtures and reaches **1.95×** on the `48³` one, but never on the
   fixture the bar names. The *entire* remaining B1 gap is P₀ plus the coarse
   operators P₀'s width implies — which is why `k` moves it and the caps do not.
2. **Taking it contradicts the reason AMG was tried at all.** 131's structural
   argument for AMG over geometric MG is that the tentative prolongator carries
   the **6 rigid-body modes exactly** to the coarse level, so the low-energy
   *bending* modes of a thin ligament stay representable — which trilinear
   geometric prolongation cannot do once the ligament is thinner than a coarse
   cell. `k = 3` throws the three rotations away. The **3.4× cycle penalty on the
   iteration-0 field and the outright non-convergence on the developed one** are
   that argument being confirmed by measurement, on the exact pathology it was
   made about.

So B1 as written is satisfiable, but only by giving up the property that
motivated the method — and on developed fields, giving it up costs convergence
itself. §7c takes that as evidence about the **bar**, not about the method.

---

## 4. B2 — does the CARRY property survive the lean rebuild? (iteration-0 field)

Both fixtures are 131's R1 stagnation regime, read through 128's diagnostics
directly: `hier_built=1, used_mg=0` means the geometric builder *built* a
hierarchy and then exhausted its 300-cycle budget and fell back to Jacobi.

### 4a. `192×112×128`, occ 0.40 + bore 0.40 — 804 864 reduced DOF

```
   GEOMETRIC: hier_built=1 used_mg=0 levels=0 mg_cycles=300 cg_iters=3602 resid=9.97e-07  56.82s
      -> geometric FELL BACK (STAGNATION: hierarchy built)
   JACOBI-CG baseline: iters=3602  40.02s
    level      n        nnz    nnz/row   ratio   note
        0   804864          -     75.5       -   MATRIX-FREE (no A stored)
        1    67260    6697512     99.6   11.97
        2     6522     530731     81.4   10.31
        3      732      43344     59.2    8.91
    coarsest n=732 dense-LDL^T=yes | P0 61.4 MB + coarse ops 104.8 MB + bookkeeping 44.5 MB = AMG ADDS 210.7 MB
   LEAN-PCG: cycles=66 converged=yes rho_eff=0.811 | setup 2.70s (strength 0.25 agg 0.00
             prolong 0.08 galerkin 2.12 coarse 0.23), solve 7.20s, 0.109s/cycle
   END-TO-END: geometric 56.82s vs lean AMG 9.90s = 5.74x  [B3 >= 1.00x: PASS]
   DETERMINISM (B4): IDENTICAL
```

`cg_iters=3602` is **131 §2a's number digit-for-digit**, so this is the same
system. Three readings:

1. **It carries: 66 PCG cycles against 3 602 Jacobi iterations — a 54.6×
   outer-iteration win**, inside 131's 23–103× band.
2. **The hierarchy is healthy where 131's degenerated.** Coarsening ratios
   **11.97 / 10.31 / 8.91** — no collapse — and the stencil *shrinks* down the
   hierarchy (99.6 → 81.4 → 59.2 nnz/row) instead of filling in. Compare 131
   §2d's 10.6 → 5.1 → 3.1 → **1.35** with a 100 %-dense level.
3. **Setup is 6.3× cheaper than 131's** (2.70 s against 17.0 s) and the
   end-to-end win rises from 131's **2.1×** to **5.74×**. Two things changed: no
   fine matrix to assemble, and the fine level now runs on the **production
   threaded apply** rather than a single-threaded CSR.

Setup is dominated by the element-local Galerkin (2.12 s of 2.70 s), which is the
expected shape — the aggregation itself is free (0.00 s) and the strength graph
is 0.25 s.

### 4b. `100×96×96`, occ 0.40 + bore 0.40 — 142 848 reduced DOF

```
   GEOMETRIC: hier_built=1 used_mg=0 mg_cycles=300 cg_iters=1607  7.61s   -> FELL BACK
   JACOBI-CG baseline: iters=1607  3.61s
    level 1: n=13902 nnz/row=80.7 ratio=10.28 | level 2: n=1698 50.9 8.19 | level 3: n=252 32.6 6.74
   LEAN-PCG: cycles=142 converged=yes rho_eff=0.907 | setup 0.33s, solve 3.31s
   END-TO-END: geometric 7.61s vs lean AMG 3.65s = 2.09x  [B3 >= 1.00x: PASS]
   DETERMINISM (B4): IDENTICAL
```

`cg_iters=1607` again matches 131 §3a exactly. **It carries — but the win band is
missed here, and that is stated plainly: 1607/142 = 11.3×, against 131's 23–103×
band (131 measured 63 cycles = 25× on this fixture).** The lean rebuild needs
**2.25× more cycles** than 131's assembled prototype on the same system.

### 4c. The one thing the rebuild gave up, named

The cause is identifiable and it is the substitution §0a disclosed: **the fine
smoother.** 131 used symmetric Gauss-Seidel at every level; a matrix-free fine
level cannot, so this rebuild uses Chebyshev(2). The price shows up exactly where
theory says it should — in the *per-cycle* quality, not in the carry:

| | 131 (assembled, SGS) | lean (matrix-free, Chebyshev) |
|---|---:|---:|
| stationary sustained contraction, `192×112×128` | 0.902 | **0.969** |
| CG-accelerated ρ_eff | 0.688 | **0.811** |
| PCG cycles | 37 | 66 |
| setup | 17.0 s | **2.70 s** |
| end-to-end vs the failing geometric path | 2.1× | **5.74×** |

**The preconditioner is weaker per cycle and the solve is faster anyway**, because
each cycle is cheaper and the setup is 6.3× cheaper. That trade is the whole
character of the lean rebuild, and it is why §4b's smaller fixture — where setup
is nearly free and cycles dominate — is the one that loses the band.

---

## 5. B3 — DEVELOPED fields: the 131 §2d result, reversed

This is the section 131 §5e said Phase 1 exists to re-measure. 131's finding was
that on a developed-design field AMG **carries but does not pay for itself** —
1.11× and 4.1× *slower* than the failing geometric path, setup up 6.7×, coarse
operators 100 % dense, 3.3 GB of hierarchy.

### 5a. `192×112×128` lattice — 804 864 DOF

```
   GEOMETRIC: hier_built=1 used_mg=0 mg_cycles=300 cg_iters=13741 resid=9.72e-07  169.21s
   JACOBI-CG baseline: iters=13741  211.88s
    level      n        nnz    nnz/row   ratio   note
        0   804864          -     75.5       -   MATRIX-FREE (no A stored)
        1    76086    8073108    106.1   10.58
        2    11640    1033748     88.8    6.54
        3     2322     170593     73.5    5.01
        4      780      33374     42.8    2.98
    coarsest n=780 dense-LDL^T=yes | P0 61.4 MB + coarse 126.6 MB + book 44.5 MB = AMG ADDS 232.5 MB
   LEAN-PCG: cycles=362 converged=yes rho_eff=0.963 | setup 3.70s (galerkin 2.98), solve 53.76s
   END-TO-END: geometric 169.21s vs lean AMG 57.46s = 2.95x  [B3 >= 1.00x: PASS]
```

`cg_iters=13741` is 131 §2d's number exactly. Side by side with it:

| | 131 (assembled, smoothed P) | **lean (matrix-free, unsmoothed P)** |
|---|---:|---:|
| level-1 → 4 coarsening ratios | 10.6 / 5.1 / 3.1 / **1.35** | **10.58 / 6.54 / 5.01 / 2.98** |
| coarse stencils (nnz/row) | 322 → 1 149 → 2 373 → **3 600 (100 % DENSE)** | **106 → 89 → 74 → 43 (shrinking)** |
| setup | 113.85 s | **3.70 s** — **31× cheaper** |
| solve | 99.99 s | 53.76 s |
| hierarchy memory | 3 296 MB | **232.5 MB** — **14.2× less** |
| PCG cycles | 133 | 362 |
| **vs the failing geometric path** | **1.11× SLOWER** | **2.95× FASTER** |

**The 131 §2d collapse does not occur.** The ratio does not collapse, the coarse
operators do not densify — they get *sparser* with depth — and the setup
explosion is gone. §2 identified the lever: the prolongator smoothing, not the
caps.

### 5b. `48³` solid box with the lattice field — 345 744 DOF (clean geometry)

```
   GEOMETRIC: hier_built=1 used_mg=0 mg_cycles=300 cg_iters=3565  21.26s   -> FELL BACK
   JACOBI-CG baseline: iters=3565  13.82s
    level 1: n=30450 112.9 nnz/row ratio 11.35 | level 2: n=4434 99.1 6.87 | level 3: n=750 92.9 5.91
    P0 26.4 MB + coarse 56.5 MB + book 19.5 MB = AMG ADDS 102.3 MB
   LEAN-PCG: cycles=160 converged=yes rho_eff=0.917 | setup 1.27s, solve 6.99s
   END-TO-END: geometric 21.26s vs lean AMG 8.26s = 2.57x  [B3 >= 1.00x: PASS]
```

131 §2e measured this fixture at **4.1× SLOWER** (76.1 s against 18.7 s) with
1 464.7 MB. Lean: **2.57× FASTER** with **102.3 MB** — a **10.5×** memory
reduction and a **10.5×** swing in the wall-clock ratio.

### 5c. B3 on the two 131 §2d fixtures — PASS, and it is a reversal

| developed fixture | red. DOF | geometric | lean AMG | 131's ratio | **this ratio** |
|---|---:|---|---:|---:|---:|
| `192×112×128` lattice | 804 864 | 300 cycles → 13 741 Jacobi, 169.2 s | 362 cycles, 57.5 s | 1.11× slower | **2.95× faster** |
| `48³` lattice | 345 744 | 300 cycles → 3 565 Jacobi, 21.3 s | 160 cycles, 8.3 s | 4.1× slower | **2.57× faster** |

**B3 asked for ≥ 1.0× — no regression. On both of 131's developed fixtures the
measurement is 2.57–2.95×, and it is the single most decision-relevant reversal
in this handoff:** 131 §5a's warning that "the wall-clock win measured at
iteration 0 must not be extrapolated to a developed field" no longer holds for
the lean configuration. On these fixtures the developed-field economics are now
*better* than the iteration-0 economics were in Phase 0.

**The qualification belongs here, not later: there is a third developed fixture
and it FAILS B3.** §6 measures the shared ultra-dilute box — the one developed
field that is real optimizer output — at **0.46×**. Both fixtures above are ones
where geometric multigrid *stagnates*; that one is a field where it does not. §6b
draws the line.

### 5d. What got worse, stated in the same breath

Cycles. 131 needed 133 on the big lattice; this needs **362** (2.7×), and 160
against 88 on the `48³` (1.8×). Same cause as §4c — Chebyshev instead of
Gauss-Seidel on the fine level, plus the unsmoothed prolongator. The stationary
V-cycle barely contracts at all (sustained **0.995**), so essentially all of the
convergence here is **CG doing the work with AMG as a cheap preconditioner**
rather than a strong multigrid iteration. That is a real characterisation of what
this configuration is, and §7 lists the two things that would strengthen it.

---

## 6. THE SHARED ULTRA-DILUTE FIXTURE — the one field that is optimizer output

Everything in §4 and §5 rides on either the iteration-0 field or 131 §2d's
**synthetic** lattice. This section is the one point in the study whose density
field a real optimizer produced, and it is the production complaint's own shape:
a **48.8× dilute** design box at **2.05 % part fill**.

**What it is, and where it comes from** (§1c states the scope correction in
full): the fixture rule and the field recipe are the committed ACTIVE DOMAIN
Phase-0 artifact —
`active_domain_probe.cpp:dilute_box(48, 32, 48, arm 24, span 24, ny 6, t 6,
h 1.0, tip 30.0)`, driven by 40 OC iterations at the **part-relative** rung
`vf 0.26` with `physical_filter_radius(2.5, spacing)`, move 0.2, CG tolerance
1e-8, `SolverKind::MultigridCG_Matfree`. The harness prints the fixture's counts
before it measures anything so the match against
`evidence/134/ultradilute_stdout.txt` can be checked by eye.

**What it is not:** a driver (MMA) capture. Handoff 134 §1c is explicit that its
ultra-dilute row is a harness OC run and that a converged, well-resolved
ultra-dilute **driver** capture is the biggest gap in that Phase 0. That gap is
inherited here unchanged.

### 6a. Provenance, then the measurement

```
  box 48x32x48 = 73728 elements, part 1512 voxels (2.05% fill, 48.8x dilution)
      — matches evidence/134/ultradilute_stdout.txt
  developing the field: 40 OC iterations at part-relative rung vf 0.26, 2.5 mm filter,
  MultigridCG_Matfree, tol 1e-8 ...
  ... developed in 52.0s (last solve CG iters = 32)
  developed field: 0.55% of the domain above rho 0.3, 1.75% gray (1.5*rho_min < rho < 0.3)
```

The element count, part-voxel count, fill fraction and dilution factor reproduce
134's committed capture exactly.

```
   GEOMETRIC: hier_built=1 used_mg=1 levels=3 mg_cycles=26 cg_iters=26 resid=9.23e-07  1.18s
   JACOBI-CG baseline: iters=1273  3.59s
   reduced DOF = 237552 | production matfree hierarchy = 30.3 MB (B1 baseline)
    level 1: n=20442 107.7 nnz/row ratio 11.62 | level 2: n=2865 90.2 7.14 | level 3: n=1067 77.0 2.69
    P0 18.1 MB + coarse 41.9 MB + book 13.3 MB = AMG ADDS 73.3 MB
   LEAN-PCG: cycles=55 converged=yes rho_eff=0.778 | setup 1.00s, solve 1.60s
   MEMORY: 73.3 MB vs 30.3 MB = 2.42x   [B1 <= 2.00x: FAIL]
   END-TO-END: geometric 1.18s vs lean AMG 2.60s = 0.46x  [B3 >= 1.00x: FAIL]
   DETERMINISM (B4): IDENTICAL
```

### 6b. The result that matters most, and it is not the one this lane wanted

**`used_mg=1`.** On the one fixture in this study whose field is real optimizer
output, and whose geometry is the production complaint's own shape — a 48.8×
dilute design box at 2 % fill — **geometric multigrid does not stagnate at all.
It builds three levels and converges in 26 cycles.** Lean AMG needs 55 cycles and
**2.2× the wall-clock (0.46×). B3 FAILS here.**

Two things follow, and neither is comfortable for a general AMG switch:

1. **The 125 pathology is not universal on developed fields.** This handoff's
   other developed fixtures (§5) stagnate geometric MG completely; this one does
   not. The difference is what the contrast sits on: §5's synthetic lattice
   carries ~10⁵ contrast on *sub-coarse-cell members* by construction, whereas a
   real OC design in a dilute box is a thin skeleton (0.55 % of the domain above
   ρ 0.3, 1.75 % gray) floating in a sea of near-`rho_min` filler that a coarse
   grid represents perfectly well. **The filler is what keeps the V-cycle
   healthy** —
   which is the same mechanism handoff 134 §4a found from the other direction
   when it measured that *removing* the filler makes the restricted system
   1.4–2.0× harder for the V-cycle.
2. **AMG must not be a general replacement.** Where geometric carries, AMG is
   measurably worse — 2.2× slower here, and §7 of 131 already predicted this
   shape. The honest deployment target is the one 131 §7b item 5 named: **the
   latch's replacement**, tried only when geometric has already failed.

For completeness, against the *Jacobi fallback* rather than the working geometric
path, AMG is still 23.1× fewer outer iterations (1 273 → 55) and 1.38× faster —
but the geometric path is what production would actually run here, and it wins.

---

## 7. THE VERDICT

### 7a. Against the four bars, as literally written

| bar | statement | result |
|---|---|---|
| **B1 MEMORY** | ≤ 2.0× the matfree baseline at real extents | **FAIL** — **2.34–3.18×** at the default knobs across six fixtures; best at the extents the bar names is **2.37×** (210.7 MB against 88.9 MB). Two settings reach it (§3e): TIGHT control on the two developed fixtures (**1.95×**, 1.53× the cycles) and a 3-mode near-nullspace (**1.16×**) — the latter at the cost of non-convergence on the developed field. |
| **B2 CARRY** | carries where geometric fails, win in 131's 23–103× band | **CARRY: PASS, 5 of 5.** **BAND: MISS on 2 of 5** at the default knobs — 54.6×, 38× and 23.1× are in band; **22.3×** (`48³` lattice) and **11.3×** (`100×96×96`) are below it. §3d shows the `100×96×96` miss is a **tuning artifact**: θ 0.02 gives 60 cycles = **26.8×**, back in band. |
| **B3 END-TO-END** | developed-field total ≥ 1.0× the current solver | **PASS on 2 of 3 developed fixtures** (2.95×, 2.57×) — a reversal of 131's 1.11×/4.1× slower — but **FAIL on the ultra-dilute one (0.46×)**, where geometric does not stagnate. |
| **B4 DETERMINISM** | bit-identical twice-run | **PASS**, every case, operators *and* solutions. |

**Three of four bars have a failing row. This is therefore a NO-GO on the bars as
written, and per the task's own rule the Phase-2 wiring sketch is NOT written
here.** §7c says what would have to change to reach a GO.

### 7b. What the measurement actually established, stated separately from the verdict

The NO-GO is on the bars; it is not a null result. Four things are now measured
that were open before:

1. **131 §7a option A is FEASIBLE, and the kernels are verified.** A fully
   matrix-free fine level works: strength graph, Gershgorin bound and `A·T`
   streamed element-locally (**bit-identical** to the assembled reference), and
   the Galerkin operator by the element-local triple product (**4.4e-15**
   relative). 078's property is restored — no fine matrix exists at any point.
2. **Memory fell 9.8×** on the fixture the bar names: 131's **2 071.6 MB /
   23.3×** → **210.7 MB / 2.37×**. The bar is missed by 0.37×, and §3c shows why
   it is structurally tight: P₀ plus bookkeeping is already 1.19× before a single
   coarse operator, because an algebraic hierarchy must materialise the
   interpolation a geometric one gets free as a stencil.
3. **The 131 §2d developed-field collapse is CURED, and the cure is the
   unsmoothed prolongator, not the coarsening caps** (§2b). On the big lattice:
   ratios no longer collapse (2.98 at the bottom, not 1.35), coarse stencils
   *shrink* with depth (106 → 43, not 322 → 3 600 dense), setup is **31×**
   cheaper, memory **14.2×** smaller, and the wall-clock goes from **1.11×
   slower to 2.95× faster**. The coarsening-control rule is a real guard that
   fires on three configurations (§2c) but never binds at the default setting.
4. **A regime split is now measured, not assumed** (§6b). Where geometric
   stagnates, lean AMG is 2.6–5.7× faster. Where geometric carries — including
   on the one real-optimizer-output field in the study — it is **2.2× slower**.

### 7c. What would have to change for a GO

Two bars, two levers, and both are measurable without production code:

* **B1 (memory) — this one is a decision, not an experiment.** §3e measured both
  levers at real extents. The coarsening control **cannot** reach the bar (TIGHT
  is byte-identical to default on the 804 864-DOF stagnation fixture; it did
  reach 1.95× on the `48³` lattice and 2.50× on the developed one, each time by
  rejecting a level and paying 1.46–1.53× the cycles). The near-nullspace **can**,
  and comfortably — `k = 3` gives **1.16×** — but it costs **3.4× the cycles on
  the iteration-0 field and fails to converge in 600 cycles on the developed
  one**, because it works by discarding the three rigid **rotations** that are
  131's whole structural argument for preferring AMG on thin ligaments.
  **Meeting B1 that way would delete the reason the method was tried.**

  The honest reading is therefore that **the bar is mis-set, not the method
  mis-tuned.** 2.0× charges algebraic interpolation against a baseline that gets
  its interpolation for free as a stencil, and §3c shows P₀ + bookkeeping is
  1.19× before any coarse operator exists — so the bar reserves ~0.8× for the
  entire coarse hierarchy. A maintainer who wants a memory bar should re-state it
  against something comparable — the **solver's total working set**, or an
  absolute ceiling tied to the smallest target device — and this handoff should
  then be re-read against that number, which it already prints (`AMG MB` and the
  P₀/coarse/bookkeeping split are in every table).
* **B2 (the band) — half of it is already closed.** §3d shows θ 0.02 turns the
  `100×96×96` miss (11.3×) into **26.8×**, inside the band, for 19 % more memory,
  while the same θ is *harmful* on the developed lattice. So the strength
  threshold wants to be selected per regime rather than fixed at 0.08 — which is
  a knob 131 §4b already flagged as unswept, and it is now swept on three
  fixtures. The `48³` lattice's 22.3× (against a 23× floor) is inside the noise
  of that choice.

* **B2's remainder and B3 (the ultra-dilute row).** Both trace to one substitution:
  **Chebyshev instead of Gauss-Seidel on the fine level** (§4c, §5d). The
  stationary V-cycle sustained contraction is 0.969–0.995, so this configuration
  is a cheap preconditioner for CG rather than a strong multigrid iteration. Two
  untried things would strengthen it and neither needs an assembled fine matrix:
  a **higher-degree Chebyshev** (degree 3–4, trading matvecs for cycles), and a
  **matrix-free multicolour Gauss-Seidel** on the fine level, which the existing
  8-colour element partition (`kNumColors`, `fea_matfree.hpp`) already makes
  race-free and deterministic. That second one is the direct repair for the
  substitution this rebuild had to make, and it is the single highest-value
  measurement left.

**And one scoping conclusion that does not depend on either:** §6b makes the
deployment question narrower than Phase 0 left it. Even at a GO, AMG should be
wired as **the latch's replacement target** (131 §7b item 5) — tried only when
128's stagnation latch would otherwise drop a doomed solve to Jacobi — and not as
a general preconditioner. Every fixture where lean AMG wins is a fixture where
geometric has already failed; the one fixture where geometric works is the one
where AMG loses.

### 7d. What this handoff must NOT be read as claiming

* No end-to-end optimizer run was performed. Everything here is per-solve.
* The developed fields in §5 are 131's **synthetic** lattice. The one real
  optimizer field (§6) is a harness OC run, not a driver MMA run, and it is the
  fixture that fails B3.
* The setup's aggregation, Galerkin and coarse-level kernels are still
  **single-threaded prototype code**; only the fine level runs on the production
  threaded apply. The setup seconds would improve with threading and the cycle
  counts would not.
* Wall-clock carries 113's ±30 % band. Cycle counts, nnz, ratios and memory bytes
  are deterministic and are what the claims rest on.

---

## 8. REPRODUCE — every number above

The harness is **committed**, so this is a two-command reproduction.

```bash
cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release
cmake --build core/build --target topopt -j8
c++ -std=c++17 -O2 -I core/include -I core/src/fea \
    core/tests/harness/amg_lean_probe.cpp core/build/libtopopt.a -o amg_lean_probe
```

| command | what it prints | cost |
|---|---|---|
| `./amg_lean_probe verify` | §0c — the element-local kernels against an assembled reference | ~5 s |
| `./amg_lean_probe correctness` | §0d — the solution gate at tol 1e-10 | ~2 s |
| `./amg_lean_probe determinism` | §0e — B4 | ~75 s |
| `./amg_lean_probe memory` | §3 — B1, baseline printed first | ~1 min |
| `./amg_lean_probe memsweep` | §3 — the θ sweep with the memory breakdown | ~20 min |
| `./amg_lean_probe nullspace` | §3 — the two B1 levers at real extents | ~25 min |
| `./amg_lean_probe coarsening` | §2 — the coarsening-control sweep | ~20 min |
| `./amg_lean_probe stagnation` | §4 — B2 on the iteration-0 field | ~15 min |
| `./amg_lean_probe developed` | §5 — B2/B3 where a real run lives | ~20 min |
| `./amg_lean_probe ultradilute` | §6 — the shared ACTIVE-DOMAIN fixture | ~10 min |

Run the modes **sequentially**, never concurrently (thermal protocol, 113). Raw
captures are committed under
`docs/handoffs/evidence/2026-07-23-amg-phase-1-measurement/`, one file per mode,
with a `README.md` mapping file → mode → claim.
