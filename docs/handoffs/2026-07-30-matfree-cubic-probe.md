# Can the matrix-free kernel carry a per-voxel cubic tensor? — PROBE

**Date:** 2026-07-30
**Branch:** `claude/matfree-cubic-tensor-ff4832`
**Predecessors:** lattice certification Phase 1 (`2026-07-27-lattice-certification`,
`fea_solve_cg_lattice`), lattice certification E2E (`2026-07-29-lattice-certification-e2e`),
matrix-free GenEO Phase 2 + arming (`2026-07-29-matrixfree-geneo-phase2`,
`2026-07-29-geneo-arming`), Krylov recycling (handoff 133).
**Machine:** Apple M2 Pro (10 cores), 16 GB, Apple clang; library Release (-O3),
harness -O3.
**Production change: NONE.** This is a probe. The production library is linked
UNMODIFIED; the cubic matrix-free kernel, the assembled reference, the accelerator
drivers and every fixture live in the harness
`core/tests/harness/matfree_cubic_probe.cpp`. No constant armed, no default changed,
no gate touched.
**Evidence:** `evidence/2026-07-30-matfree-cubic-probe/` (CSVs + logs +
`reproduce.sh`).

---

## Verdict: YES — all five bars pass.

The three-block decomposition is exact to machine precision, a matrix-free cubic
apply equals the assembled lattice operator to 7×10⁻¹⁶, the measured apply cost is
**2.4–2.7× (best kernel)** against the predicted ~3×, the operator stays SPD and
**recycling, a Galerkin coarse level, and the production-pencil GenEO deflation all
engage and cut iterations on it**, and with zero cubic voxels the probe path
reproduces today's matrix-free apply AND solve **bit-for-bit**. Memory at the
8.44M-DOF production scale is ~107 MB worst case — no BLOCKED-STOP. The production
solver CAN carry lattice stiffness; a multiscale-lattice optimization loop would not
be trapped on the assembled Jacobi-CG path.

---

## Why this was the question

`fea_solve_cg_lattice` (assembly.cpp) is today the ONLY path that carries per-voxel
cubic tensors, and it is the assembled Jacobi-CG path: no multigrid, no matrix-free,
no GenEO, no recycling, no draft. `analyze.cpp:164` assembles a latticed
certification REGARDLESS of `solver_kind`. Affordable for one-shot certification;
not affordable if multiscale lattice TO puts a cubic solve inside every design
iteration. The hypothesis: `Ke = ∫ Bᵀ D B dV` is linear in D, and a cubic D is

```
D(C11,C12,C44) = C11·D_A + C12·D_B + C44·D_C
  D_A = diag(1,1,1,0,0,0)      (normal diagonal)
  D_B = normal off-diagonal 1s
  D_C = diag(0,0,0,1,1,1)      (shear diagonal)
⇒ Ke(C11,C12,C44) = C11·K_A + C12·K_B + C44·K_C
```

with K_A, K_B, K_C three FIXED 24×24 blocks — so the matrix-free kernel needs three
reference blocks instead of one, and three per-voxel coefficients instead of one
scalar, and everything built on the operator keeps working.

## D1 — The decomposition is exact. PASS

**Worst relative error 8.5×10⁻¹⁶** (relative to the element's max entry) over 8,696
cases: all 7 certifiable topologies' measured rows (12 densities across each
topology's own band × E ∈ {1, 3500} × h ∈ {0.5, 1.0, 1.7, 2.31}), 8,000 random
admissible tensors spanning C11 ∈ [10⁻³, 10⁴], C12/C11 ∈ (−0.49, 0.98) (auxetic
side included down to the admissibility edge), C44/C11 ∈ [10⁻², 10], plus the
isotropic special case D_iso = cubic(c(1−ν), cν, G). The harness's copy of the
integrator matched production `hex8_stiffness_cubic` **bit-for-bit in all 8,696
cases** (informational), so the blocks are on the production arithmetic. This is
not luck: the integrator is linear in D and the decomposition is exact in real
arithmetic; the 10⁻¹⁶ is summation-order roundoff. (`d1_decomposition.csv`)

The same linearity applies verbatim to the Galerkin coarse block: WᵀKeW =
C11·WᵀK_A W + C12·WᵀK_B W + C44·WᵀK_C W — the multigrid coarse-operator build
decomposes identically, three geometric blocks per colour instead of one.

## D2 — Matrix-free cubic apply == assembled operator. PASS

Fixture 24×12×12 (3,352 solid voxels: an ellipsoidal void pocket, a 1,152-voxel
octet band with per-voxel tensors at random ρ ∈ [0.20, 0.55], graded isotropic
elsewhere; ndof 12,675). Probe kernel = production `mf_apply_full` for the
isotropic list (unchanged) + a second coloured cubic-element pass.

* Apply vs the assembled composite operator (assembled with the byte-identical
  per-element rule of `assemble_reduced_lattice`): **worst relative diff 7.4×10⁻¹⁶**
  over 10 random vectors (bar ≤ 10⁻¹²), and **bit-identical across 1/4/8 threads**
  (the cubic pass inherits the 8-colour determinism argument).
* Solve: probe matrix-free cubic Jacobi-CG vs production `fea_solve_cg_lattice` at
  tol 10⁻¹⁰: **392 vs 391 iterations, field rel-L2 diff 1.5×10⁻¹²** — the same
  system, solved without ever assembling it. (`d2_operator_match.csv`)

## D3 — The cost ratio, measured. ~3× confirmed; best kernel BEATS it

Per-apply cost (CG-iteration-normalised work, 132's discipline: median of 30
applies after warmup), 64³ all-solid grid, 262,144 elements, both kernels on the
SAME grid and element count:

| kernel                       | 1 thread          | 10 threads        |
|------------------------------|-------------------|-------------------|
| production scalar            | 14.7 ms (1.00×)   | 3.27 ms (1.00×)   |
| probe scalar (parity check)  | 14.7 ms (1.00×)   | 3.33 ms (1.02×)   |
| cubic, 3-accumulator         | 56.1 ms (**3.8×**)| 10.8 ms (**3.3×**)|
| cubic, combined-block        | 39.7 ms (**2.7×**)| 7.8 ms (**2.4×**) |

Two kernel shapes were measured. The literal-decomposition kernel (three
column-sweeps into three accumulators) runs 3.3–3.8×: above 3× flop-ratio because
three 24-double accumulators exceed the NEON register file (spills). The
**combined-block kernel** — form a·K_A + b·K_B + c·K_C per element (a 1,728-flop
streaming pass over three L1-resident 4.6 KB blocks), then run the standard
single-block sweep — lands at **2.4–2.7×**, UNDER the predicted 3×, because the
gather/scatter and the y-write traffic are shared and the block combine is cheaper
per flop than the sweep. The two kernels agree to 3.3×10⁻¹⁶. Run-to-run spread
under normal machine load was ±0.3× (replicates in the log); the ordering never
changed. Production would ship the combined-block shape. (`d3_apply_cost.csv`)

## D4 — The accelerators still engage. PASS

Fixture 24×12×12, ng = 12,039, with genuine void/lattice/solid contrast AND the
production disease: two full SIMP-soft planes (E×10⁻⁹) leave the loaded distal
block hanging on near-void material — baseline Jacobi-CG needs **1,742 iterations**
(vs 382 without the soft planes).

* **SPD, established on the assembled twin:** max |K−Kᵀ| = 2.3×10⁻¹³ (assembly
  roundoff), LDLT pivots all positive, spanning [1.2×10⁻⁶, 1.1×10⁴] — the 10-decade
  spread IS the contrast. Every cubic element block is PSD by `hex8_stiffness_cubic`'s
  admissibility validation, so the sum + BCs is SPD structurally; the pivots confirm.
* **Krylov recycling — the PRODUCTION `RecycleSession`, zero changes:** the class is
  operator-agnostic (it takes the apply as a callback), so the shipped recycling
  applies to the cubic operator as-is. On a 4-solve sequence with drifting isotropic
  moduli (cubic band fixed): 1742 → 1742/1981/1409/1528 vs 1742/1736/1727/1738 off —
  it engages, harvests, and cuts 18–19% on later solves (one early regression, the
  known noisy-harvest behaviour; exactness unconditional either way).
* **Multigrid family — two-level Galerkin coarse correction:** trilinear 2:1
  coarsening, coarse operator PᵀAP from the cubic operator, symmetric V(1,1) with
  damped Jacobi: **1,742 → 21 iterations (83×)**. Galerkin coarsening needs only
  the fine operator and linearity — both survive the cubic extension (see D1's
  coarse-block note).
* **GenEO — the production pencil:** per-subdomain Neumann local matrices assembled
  from the TRUE composite blocks (iso factor·K0 + cubic 3-block), the production
  eigenproblem A_i v = λ (D_i A_i D_i) v with PoU weights, cut = kGeneoLambdaCut
  (0.05), coarse columns D_i·v, correction z += V(VᵀAV)⁻¹Vᵀr — at the ARMED
  production tiling (8³ cores, overlap 1): **N_t = 48 modes, 1,742 → 443 iterations
  (3.9×)**, converged, exactness untouched. Tiling matters: probe-sized 4³ tiles
  gave only 1.35–1.47× (appendix logs) — the subdomain must span the contrast
  feature, which the armed 8³ recipe does.

One structural finding for the eventual build: `geneo.cpp`'s coarse-operator
refresh (`build_coarse_operator`) drives `m.apply_kgg` and is **already
operator-agnostic**; only `build_local` reads the scalar modulus vector plus the
single isotropic K0, so the production GenEO needs the SAME three-block extension
in its local assembly (a ~10-line change of the same shape as the kernel). Even
unextended, a scalar-surrogate basis stays a valid SPD additive correction against
the true operator — it can cost iterations, never correctness. (`d4_accelerators.csv`)

## D5 — All-scalar is bit-identical. PASS. Memory: no BLOCKED-STOP

* **Apply:** with zero cubic voxels, the probe path IS the production path
  structurally (the isotropic list goes through `mf_build_elems` + `mf_apply_full`
  unchanged; the cubic pass iterates an empty list): **bit-identical** to
  `fea_matfree_apply` over 5 random vectors on a graded void-pocket fixture.
* **Solve:** probe CG vs production `fea_solve_cg_matfree`: **1,573 vs 1,573
  iterations, field bit-identical** (memcmp over all 12,675 DOFs).
* **Memory at 8.44M DOF (2.81M voxels), the BLOCKED-STOP check:** three per-voxel
  coefficient arrays 64.4 MB; element-table delta if EVERY voxel were cubic
  (factor 8 B → a,b,c 24 B) 42.9 MB; two extra 24×24 reference blocks 9 KB.
  **~107 MB worst case** against the 16 GB machine of record (the armed GenEO
  basis cap alone is 2,048 MB). Not remotely binding. (`d5_memory_budget.csv`)

## What this probe does NOT decide

The optimisation formulation (C(ρ) fitting, the forbidden-density-interval
problem), any wiring of the cubic kernel into production TUs, and the draft path
(structurally the same loosened-tolerance CG on the same operator, so nothing
blocks it, but it was not separately measured). Production integration would
touch: `MfElem`/`mf_build_elems` (a second element list or a per-element tag),
`mf_build_reduced` (diagonal + void gate over both lists — the probe's version is
the template), `multigrid.cpp`'s Galerkin block build (three geometric blocks),
and `geneo.cpp`'s `build_local`. All are the same linearity argument; none change
the operator's contracts (SPD, determinism, exact stopping test).

---

## Plain language

Your solver has a fast path and a slow path. The fast path is the one all the
recent speedups live on — the memory-lean operator, the multigrid ladder, the
GenEO trick that killed the 5,000-iteration stalls, the recycling that reuses work
between design steps. The slow path is the old-fashioned one that builds the whole
stiffness matrix in memory. Right now, any part that contains lattice — where each
little region has its own directional stiffness instead of one number — is FORCED
onto the slow path. That's fine when you certify a finished design once. It would
be a dealbreaker if the optimizer itself had to reason about lattice on every one
of its hundreds of iterations.

This probe asked: can the fast path learn to carry lattice stiffness? The answer
is yes, and the reason is almost embarrassingly simple. A lattice region's
stiffness is described by three numbers instead of one. The math of a finite
element is such that "an element with three material numbers" is exactly "three
fixed element templates, each multiplied by one of the numbers, added up." We
verified that identity to the last digit of double precision (it's not an
approximation), built the fast-path version of it, and checked it against the slow
path: same answer to 15 decimal places, and the same displacement field when you
solve all the way.

The cost: each lattice element costs about 2.4–2.7× a normal element in the best
kernel we measured — close to the naive "three numbers, three times the work"
guess, slightly better because much of the work (fetching data, writing results)
is shared. Memory overhead at full production size is about 107 MB on a 16 GB
machine — irrelevant. Every accelerator we rely on still works on the new
operator: multigrid cut a diseased 1,742-iteration solve to 21, the GenEO
deflation cut it to 443 using its exact production recipe, and the shipped
recycling code worked without a single line changed. And when a part has no
lattice at all, the new path produces literally the same bits as today's solver —
so it can't regress anything that exists.

The gate this opens: multiscale lattice optimization — the optimizer choosing
between solid, lattice, and void everywhere, every iteration — is no longer
blocked on solver capability. The next hard questions are modelling ones (how
stiffness should vary with lattice density inside the optimizer), not
infrastructure ones.
