# Multiscale production wiring — the matrix-free cubic path ARMED

**Date:** 2026-08-01
**Branch:** `claude/matfree-cubic-multiscale-0e4f1e`
**Predecessors:** matrix-free cubic probe (`2026-07-30-matfree-cubic-probe`, PR 252
— the exact three-block decomposition and the combined-block kernel), multiscale
lattice feasibility (`2026-07-31-multiscale-lattice-feasibility`, PR 255 — the
formulation and the two solve regimes), GenEO arming (`2026-07-29-geneo-arming`),
Krylov recycling (handoff 133), lattice certification (`2026-07-27` /
`2026-07-29-lattice-certification-e2e`).
**Machine:** Apple M2 Pro (10 cores), 16 GB, Apple clang, library Release.
**Evidence:** `evidence/2026-08-01-multiscale-production-wiring/` (+ `reproduce.sh`).

**COORDINATION NOTE (Prompt H).** Prompt H had NOT merged when this branch was
cut (main tip = PR 255). Per the task instruction, **analyze.cpp and
run_job.cpp are untouched** (`git diff main -- core/src/simp/analyze.cpp
core/src/cli/run_job.cpp` is empty — `i2_gate_untouched.txt`). The
"analyze.cpp call site" item is delivered WITHOUT editing analyze.cpp: the
route lives inside `fea_solve_cg_lattice` itself (assembly.cpp, in fea/), so
the certification call site gains the armed path with zero edits to any file H
touches, and H's merge cannot conflict with this branch.

---

## Verdict in one paragraph

The lattice certification solve — until now the only production solve trapped
on the assembled Jacobi-CG path — rides the full matrix-free accelerator stack:
the exact three-block cubic operator (combined-block kernel, confirmed
2.6–2.7× per apply on this grid), a Galerkin multigrid hierarchy decomposed
over the same three blocks (**319–500 Jacobi iterations/solve → 20–34 MG
iterations, 12–16×, in BOTH regimes** of a real 120-iteration multiscale
design loop), GenEO deflation whose subdomain operators are assembled from the
true composite blocks and whose **moduli fingerprint now keys on all three
cubic fields** (the I5 correctness bar — proven by a negative control that
FAILS against the unfixed fingerprint), and Krylov recycling unchanged (its
exactness is unconditional by construction and was exercised, not assumed, on
the cubic operator). Library default OFF is byte-identical to main (stash-
rebuild sha256 on report.json + fields.bin + STLs + solver-field FNVs; 82/82
ctest); production arms the route via the ONE named constant. The gate's
verdict logic and tolerance are untouched; no verdict flips anywhere; margin
deltas sit at the certification solve's own 1e-8 tolerance scale against a
2e-9 negative-control floor. Every configuration is byte-identical on rerun.

---

## What shipped (all in core/src/fea/ + the production-config layer)

1. **Combined-block matrix-free cubic apply** (`matfree.cpp`, `fea_matfree.hpp`):
   a colour-sorted cubic element table (`MfCubElem`: three coefficients + 24
   DOFs) beside the iso table, and `mf_apply_cubic_add` — PR 252's winning
   kernel shape: fuse `a·K_A + b·K_B + c·K_C` into ONE element block, then the
   standard single-accumulator AXPY sweep (three separate accumulators spill
   the NEON register file; measured 3.3–3.8× there vs 2.4–2.7× combined). The
   reference blocks are integrated by the PRODUCTION Gauss rule
   (`hex8_cubic_reference_blocks`, hex_element.cpp, beside the integrator), and
   per-voxel tensors are validated by the SAME admissibility rule as the
   assembled path (`hex8_cubic_validate`, extracted from `cubic_D` — one rule,
   two callers). `mf_build_reduced` takes an optional lattice bundle: the M3.1
   void gate, the Jacobi diagonal (the cubic element's own decomposed diagonal,
   not a surrogate) and K·up all run over BOTH lists. The Active Domain mask
   composes uniformly (a masked voxel contributes no element from either list).
   The FP32 kernel carries no cubic pass and now throws if reached; the
   mixed-precision V-cycle is guarded off on cubic systems (production-blocked
   anyway, handoff 132 D).

2. **GenEO three-block `build_local`** (`geneo.cpp`): a latticed element in the
   subdomain Neumann operator applies `eA·K_A + eB·K_B + eC·K_C` instead of
   `eE·K0`, so the local pencil sees the true composite stiffness — the ~10-line
   same-shape extension PR 252 predicted, plus the diagonal. Scalar paths are
   element-for-element the old branch. No fallback to the scalar-surrogate
   basis was needed: the extension is in and stable (the eigensolve behaved —
   see I6's p6 phase, 24 engaged solves, mean 499.6 → 274.8).

3. **Galerkin coarse build over both lists** (`multigrid.cpp`): the
   element-local triple product runs iso elements first (path unchanged —
   bit-identical when cubic-free), then cubic elements as
   `W^T (a·K_A + b·K_B + c·K_C) W`, the coarse-block decomposition PR 252
   proved exact. The iso colour-cache stays iso-only (a cubic block depends on
   its own coefficients).

4. **The deflation-family fingerprint** (`geneo.cpp`): `moduli_fingerprint`
   hashes the lattice presence tag + mask + c11 + c12 + c44; `MfSolveContext`
   carries the lattice arrays. See "The recycle fingerprint, honestly."

5. **The route + arming**: `fea_solve_cg_lattice` (assembly.cpp) checks
   `fea_matfree_cubic_lattice_enabled()` — OFF (library default, static-asserted
   `kMatfreeCubicLatticeLibraryDefaultOff` in fea.hpp) is the assembled path
   byte-for-byte; ON routes to the new public `fea_solve_cg_lattice_matfree`
   (multigrid.cpp): MG-first, exact matrix-free Jacobi-CG fallback with GenEO +
   recycling — the scalar production solver's exact shape.
   `configure_production_options` arms it via the ONE named constant
   `kProductionMatfreeCubicLattice = true` (TRIPWIRE in production.cpp;
   accessor `production_matfree_cubic_lattice()`). Public apply face
   `fea_matfree_apply_lattice` for tests/tools. **No other production default
   changed; Active Domain's armed default untouched.**

Tests: `core/tests/unit/test_matfree_cubic.cpp` (29 checks — default-off,
apply exactness, all-scalar bit-identity, Jacobi/MG solve parity, the route,
the fingerprint invalidation, recycling exactness across a tensor change) and
two new before/after assertions in `test_production_parity.cpp`.

## The recycle fingerprint, honestly (bar I5 — the correctness bar)

The task premise said the recycle fingerprint "currently keys on the scalar
modulus field". The audit found:

* **`RecycleSession` carries NO modulus fingerprint at all.** Its carried basis
  keys on `(n, configured k)` only. At the production rebuild cycle (1 — the
  library default production leaves) EVERY solve harvests, and a harvesting
  solve re-forms `E = U^T A U` with k exact matvecs of the CURRENT operator —
  E is never stale. And `U E^{-1} U^T` is SPD for ANY carried U, so a stale U
  costs iterations, never the answer (recycle.hpp's documented exactness
  contract). This is EXERCISED on the cubic operator, not assumed:
  `test_matfree_cubic` §7 carries a basis across a tensor-only design change —
  the recycled solve matches the recycling-off field to 1.5e-10 rel L2 with
  the basis genuinely applied (dim 16, 933 → 697 iterations).

* **The modulus-keyed fingerprint of the deflation family is GenEO's
  `moduli_fingerprint`** — and it WAS the hazard. `geneo_solve_begin` compares
  it to decide REUSE (action 1 — held coarse operator untouched) vs the
  MANDATORY REFRESH (action 2 — rebuild `V^T A V`; a stale coarse operator "is
  not a deflation for the new system", phase 2 §P6 measured divergence). Blind
  to the cubic fields, two designs sharing the scalar field but differing in
  tensors silently reuse `V^T A_old V` against the new operator.

**MET, with the demanded negative control**
(`i5_fingerprint_negative_control.txt`): fixture = two 33³ high-contrast
cubic-band checkerboards with memcmp-IDENTICAL scalar fields and c44 ×1.5
apart. With the fix: A#1 builds (action 3, burn 500, Nt 608), A#2 reuses
(action 1), B#1 **refreshes (action 2)** and converges deflated in 229
iterations; deflated field matches the plain solve. With the fingerprint
hashing compiled out and nothing else changed: B#1 comes back **action 1 —
silent stale reuse — and the test FAILS at exactly that assertion** (29 checks,
1 failure). No RecycleSession restructuring was needed; the blocked-stop path
was not taken.

## Bars — MET / MISSED, with numbers

### I1 — OFF is byte-identical: MET (`i1_stash_rebuild.txt`)
Stash-rebuild in the same build dir. Demo production job (STL output; fixture
untouched): report.json, fields.bin and all three variant STLs sha256-IDENTICAL
branch vs main (and self-deterministic across reruns; run_info.json differs
only in wall-clock durations, the standing exclusion). Solver probe FNVs
identical to the byte: `fea_solve_cg_lattice` route-OFF (b97335b2…, 295
iters), `fea_solve_cg_matfree` (8bc8ce4a…, 275), `fea_solve_mgcg_matfree`
(62d91a63…, 19, MG). Note the CLI job runs with the route ARMED (it calls
configure_production_options) and is STILL byte-identical — a scalar job never
reaches `fea_solve_cg_lattice`. **Full ctest: 82/82 passed** (Release,
1504 s), including the new `matfree_cubic_lattice` guard and the parity test
asserting the toggle OFF before / ARMED after the config call.

### I2 — the gate never softens: MET (`i2_gate_untouched.txt`)
analyze.cpp and run_job.cpp byte-identical to main by diff. No verdict logic,
tolerance, fixture, materials.json, or assertion touched; the diff adds
assertions only (the FP32-cubic tripwire, input validation on new entries).

### I3 — the gate table vs the negative-control floor: MET (`i3_gate_table.csv`, `i3_flips.csv`)
Certified designs (48×24×8 multiscale loop, snapped): every row's VERDICT is
identical across assembled-OFF / matfree-ARMED / 1e-9-perturbed control —
ACCEPTED / ACCEPTED / E5-REFUSED exactly in the right places (the E5 band gate
precedes the solve and is route-blind: same offending ρ=0.983541 both routes).

| design | OFF margin | ARMED margin | \|ARMED−OFF\| | control floor \|CTL−OFF\| |
|---|---|---|---|---|
| plain_snapped | 1.955518974 | 1.955518977 | 3e-9 | 2e-9 |
| fullstack_snapped | 1.955850301 | 1.955850282 | 1.9e-8 | 2e-9 |

The fullstack row's 1.9e-8 exceeds the 2e-9 load-perturbation floor but is
exactly the certification solve's own 1e-8 relative-residual basin (margin
~1.96) — a different iteration route landing elsewhere in the same tolerance
ball, the accelerator-class difference the arming evidence expects. Max vm and
lattice vm identical to 6 decimals; lattice_voxels identical (4060). DESIGN
trajectory flips (full-stack loop vs plain loop, 9216 voxels): 28
void/gap/band/solid class flips vs the control's 24, with max|Δρ| 1.9e-2 UNDER
the control's 3.0e-2 — the accelerated trajectory moves the design no more
than a 1e-9 load perturbation does in magnitude, and by 4 voxels more in count
(boundary-layer voxels sitting on class edges). No STOP condition: nothing
beyond the floor in any verdict-bearing quantity.

### I4 — exactness: MET (test_matfree_cubic, evidence in the test log)
Matrix-free composite apply vs the per-element assembled operator on the mixed
void/iso/cubic fixture: worst rel diff **3.1e-16** (bar ≤ 1e-12), bit-identical
across 1/4/8 threads. Solve agreement vs assembled `fea_solve_cg_lattice`
(Jacobi regime, tol 1e-10): **371 vs 371 iterations** (bar: within 1), field
rel L2 8.6e-14. MG path: hierarchy builds on the composite operator
(used_multigrid, 3 levels), 26 iterations vs 363 assembled-Jacobi, field rel
L2 3.7e-11 at tol 1e-8. All-scalar (empty mask): apply AND solve bit-identical
to `fea_matfree_apply` / `fea_solve_mgcg_matfree` (memcmp).

### I5 — the fingerprint invalidates: MET (see the section above; negative control on file)

### I6 — the accelerators in a loop, both regimes: MET (`i6_summary.csv`, `i6_traces.csv`)
Real multiscale loop (PR 255's s3 continuation: 40 plain + 40 p3 + 40 p6),
48×24×8 = 33,075 DOF, all-cubic C(ρ) operator, in-loop tol 1e-6. CG per solve:

| config | mild (plain) mean | p3 mean | p6 (sharpened) mean | total |
|---|---|---|---|---|
| plain (Jacobi) | 319.1 | 391.5 | 499.6 | 48,410 |
| +multigrid | **19.9** | **32.8** | **34.0** | 3,466 |
| +GenEO (Jacobi regime) | 319.1 | 391.5 | **274.8** (24/40 engaged) | 39,418 |
| +recycling (Jacobi regime) | 324.0 | 369.1 | **352.4** | 41,818 |
| full stack | 19.9 | 32.8 | 34.0 | 3,466 |

The two regimes behave exactly as PR 255 shaped them: the sharpened p6 phase
costs the plain path 1.57× its mild cost, and that is where GenEO fires — it
never triggers in the mild regime (solves < the 500-iteration trigger, by
design) and cuts the sharpened regime 45% (499.6 → 274.8, engaging on 24/40
solves once a solve burns the trigger). Recycling helps most where the
operator drifts slowly (p6: −29%) and is ~neutral in the mild regime (+1.5%).
Multigrid dominates both regimes (12–16×) — the composite Galerkin hierarchy
contracts as well on the cubic operator as on scalar SIMP. **The full stack
equals the MG line because MG converged on every solve of this fixture — the
Jacobi fallback (where GenEO/recycling live) never ran.** That is the armed
production shape working as designed: MG when healthy, deflation + recycling
as the stagnation insurance (I6's geneo/recycle rows show exactly what that
insurance buys when the fallback IS the regime).

### I7 — the four-way interaction: MET, no pair degrades another (`i7_fourway.csv`)
2⁴ grid over GenEO × recycling × draft × AD (shortened 20+20+20 schedule,
MG-first production posture). Reading the 16 rows:
* **GenEO and recycling bits change NOTHING** — identical CG totals and
  identical final-design fingerprints within every draft/AD cell. With MG
  converging on every solve the fallback never runs, so they are structurally
  inert here; they cannot degrade (or be degraded by) anything in the healthy
  regime, and I6 shows each helping alone in the Jacobi regime.
* **Draft** (loose 1e-3 in-loop): −42% CG (p6 631 → 370 per 20 solves), final
  compliance +0.004% (135.897 → 135.903) — trajectory drift, certificate
  untouched (cert always 1e-8).
* **AD on the cubic operator: net-negative, again.** +11.6% CG in the mild
  phase (285 → 318), zero change in p6 (the band covers the spread design),
  final compliance +0.010%. Its scalar record (net-negative three separate
  times) carries over to the cubic operator; nothing here argues for changing
  its posture, and this task does not touch it.
* Draft×AD compose additively (171/283/370 — draft dominates); no
  super-additive degradation in any pair anywhere in the table.

### I8 — cost ratio in context: MET (`i8_apply_cost*.csv`)
Per-apply on this grid (9,216 elements, prebuilt tables, median of 40),
single-thread: **2.64× / 2.73×** in two replicates (0.52–0.54 ms scalar,
1.41–1.42 ms cubic) — confirming PR 252's 2.4–2.7× combined-block band; a
third replicate (3.33×) and the 10-thread numbers (1.79–3.09×) were taken
while other sessions ran solver probes on this machine (load ~21 on 10 cores)
and carry that caveat; the clean replicates bracket the PR 252 figure.
**The NET, which is what matters:** per design iteration on the armed stack,
the cubic solve costs ~20–34 MG iterations × ~4 fine applies × 2.5 premium
≈ **200–340 scalar-apply equivalents**, against the pre-wiring assembled
Jacobi posture's 319–500 cubic-cost iterations ≈ 800–1250 equivalents —
**~4× less total work per design iteration than the path multiscale was
previously trapped on**, and only ~2.5× (the pure flop premium, no iteration
penalty) above what an equivalent scalar-SIMP MG rung costs.

### I9 — memory: MET, not binding (`i9_memory.csv`)
From the real structs (`sizeof(MfCubElem)` = 112 B, +16 B over MfElem): this
grid 0.21 MB coefficients + 0.14 MB table delta. Projected to 8.44M DOF
(2.81M voxels): **64.4 MB coefficient arrays + 42.9 MB worst-case (all-cubic)
element-table delta + 9 KB reference blocks ≈ 107 MB** — matching PR 252's
projection, against the 16 GB machine and the GenEO basis cap alone of
2,048 MB. Does not bind.

### I10 — determinism: MET (`i10_determinism.csv`, `i7_fullstack_determinism.csv`)
Every I6 configuration rerun end-to-end: FNV of the final density field AND of
the full per-solve CG/diagnostic trace **byte-identical** in all five configs,
plus the geneo+recycle I7 stack. (The 8-colour apply, fixed LOBPCG seeds,
fixed merge order and the recycle module's fixed-order arithmetic carry their
determinism arguments onto the composite operator unchanged.)

## Blocked-stop paths — none taken

* Recycle fingerprint: no RecycleSession restructuring needed (see I5 — the
  correctness fix belonged to GenEO's fingerprint and is in, with the
  fail-against-unfixed control on file).
* GenEO build_local extension: stable; no scalar-surrogate fallback needed.
* Gate verdicts: no flip beyond the negative-control floor (I3); tolerance
  untouched.

## What this deliberately did NOT do

No analyze.cpp / run_job.cpp edit (Prompt H coordination — when H lands, the
armed route is already live via fea_solve_cg_lattice; if H's per-voxel band
work wants the route surfaced in run_info, that is a two-line echo of
`fea_matfree_cubic_lattice_enabled()` in the file H owns). No fixture,
materials.json, ARCHITECTURE/DECISIONS/ROADMAP change. No new production
default beyond the one named constant. AD's armed default untouched (its
cubic-operator showing in I7 is reported, not acted on). The FP32 V-cycle
still has no cubic pass (guarded + tripwired, not silently wrong). Draft on
the CERTIFICATION path stays structurally absent — the cert always runs tight.

## Files

* `core/src/fea/{matfree.cpp,fea_matfree.hpp,geneo.cpp,multigrid.cpp,assembly.cpp,hex_element.cpp}` — the path.
* `core/include/topopt/fea.hpp`, `core/include/topopt/production.hpp`,
  `core/src/simp/production.cpp` — the public faces + the ONE arming constant.
* `core/tests/unit/test_matfree_cubic.cpp` (+ CMake), extended
  `core/tests/validation/test_production_parity.cpp` — the guards.
* `core/tests/harness/multiscale_stack_probe.cpp` — the measurement harness.
* `evidence/2026-08-01-multiscale-production-wiring/` — gate table, both-regime
  traces, four-way table, fingerprint negative control, cost/memory,
  determinism, byte-identity records, `reproduce.sh`.

---

## Plain language

Until now, any part that contained lattice was solved by the slow, old-
fashioned route: build the whole stiffness matrix in memory and grind through
it with the most basic iterative solver. All the speed machinery built over
the last months — the memory-lean operator, the multigrid ladder that kills
iteration counts, the GenEO trick that rescues stalled solves, the recycling
that reuses work between design steps — only worked for ordinary solid
material. That was fine for certifying a finished lattice part once, but it
made an optimizer that reasons about lattice on every iteration impossibly
expensive.

This task moved lattice onto the fast machinery, using the mathematical fact
proven earlier: a lattice element's stiffness is exactly three fixed templates
weighted by its three material numbers. We taught the fast operator, the
multigrid ladder, and GenEO's local machinery to use those three templates.
Measured on a real lattice-optimization loop, the multigrid ladder cuts the
solver work about fifteen-fold in both of the loop's regimes — the easy early
phase and the hard late phase where the material curve gets steep — and GenEO
fires exactly where it should: only in that hard phase, where it roughly
halves what's left. A lattice element still costs about 2.6× a solid one per
operation (three numbers, nearly three times the work), but with fifteen times
fewer operations the net is a large win.

Two safety points. First, everything is off by default: with the switch off,
the entire program produces byte-for-byte the same output as before — we
proved that by rebuilding the old code and comparing checksums — and the whole
test suite passes. Production turns the switch on through one named constant,
and even then the certification rules, thresholds and verdicts are untouched:
the same designs pass, the same designs are refused, and the margins agree to
within the solver's own precision. Second, we closed a real trap: GenEO keeps
a reusable "cheat sheet" between solves and decides whether it's still valid
by fingerprinting the material field — but the fingerprint only looked at the
old single material number, so two designs with identical solid material and
different lattice stiffness would have silently reused a stale cheat sheet.
The fingerprint now covers all three lattice numbers, and we have a test that
provably fails on the old behavior. (The recycling machinery, which we audited
for the same disease, turned out immune by construction — it re-derives its
critical piece against the current problem on every solve — and we added a
test that exercises that on lattice problems rather than taking it on faith.)
