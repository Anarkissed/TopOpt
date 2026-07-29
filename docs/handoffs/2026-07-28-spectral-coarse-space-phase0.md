# 2026-07-28 — Spectral / GenEO coarse space (Phase 0, feasibility / sizing)

**Track:** offline measurement + literature/implementation survey. **NO production code, NO
`/app/`, NO gate change, NO knockdown-law change, NO solver wiring, NO new build dependency.**
One new standalone harness (`core/tests/harness/spectral_coarse_probe.cpp`, the sanctioned
`cg_tol_probe.cpp` / `lattice_homog_probe.cpp` pattern — standalone build, NOT wired into CTest),
this report, and its evidence directory. The harness uses only the already-present Homebrew
Eigen (`<Eigen/Eigenvalues>`) and the production `libtopopt.a`; no SLEPc / HPDDM / Spectra. The
`git status` at the end shows exactly the additive files; nothing under `core/src`, `core/include`,
`docs/ARCHITECTURE.md`, `docs/DECISIONS.md`, `docs/ROADMAP.md` or `materials.json` was touched.

**What this is.** A Phase-0 answer to one question the literature cannot answer for our feature
density: **how big does the spectral (GenEO / MsFEM) coarse space get on a REAL SIMP design at
our 1e9 void contrast, and is it affordable on a single ~6-core macOS workstation at ~8M DOF?**
It delivers the coarse-space sizing on real developed fields (G1), a setup-cost / amortization
analysis (G2), an implementation survey of PETSc-PCHPDDM+SLEPc / HPDDM / dune-pdelab (G3), and
the coarse-size interaction with void-DOF elimination and a raised `rho_min` (G4). Per BAR B3, a
full prototype is out of scope; the sizing + survey is the decision input.

---

## 0. The two anchor works, and the two gaps this task closes

**Alexandersen & Lazarov, CMAME 290:156-182 (2015), arXiv 1411.3923** — the only spectral
preconditioner demonstrated FOR SIMP topology optimization. Coarse space (§2.4, their eq. 9): per
coarse-node **agglomerate** `ω_i`, solve the local generalized eigenproblem
`K^{ω_i} ψ = λ diag(K^{ω_i}) ψ`, keep every eigenvector with `λ < λ_Ω`, multiply by a
partition of unity. Total coarse dim `N_t = Σ_i N_i`. SIMP `K_e = (E_min + (E_max−E_min)ρ^p)K_0`,
`E_max=1`. Applied as a coarse solve inside a multigrid-like preconditioner wrapped in GMRES.

**Spillane, Dolean, Hauret, Nataf, Pechstein & Scheichl, Numer. Math. 126(4):741-770 (2014)** —
THE THEORY: a per-subdomain generalized eigenproblem in the overlap gives a two-level Schwarz
condition-number bound independent of contrast and subdomain count, PROVIDED every sub-threshold
eigenmode is in the coarse space. The price: coarse-space size grows with the number of
high-contrast features crossing subdomain boundaries.

**★ Two claims in the task brief, corrected against the primary source (evidence
`paper_notes_alexandersen_lazarov_2015.md`):**
1. **The 26M-DOF / 26h / single-thread headline is 2D.** A&L §2.1: "the considered problems are
   two-dimensional." §6.1.1: Mx=64 double-clamped beam, 13,107,200 elements, **26,229,762 DOF**,
   ~26h/200 iters, single Matlab thread. It is a single **periodic** cross microstructure with only
   **3 unique agglomerates** (§2.4.1). Periodicity is what makes the eigensolves affordable there.
2. **Contrast independence WAS shown to 1e-9 and 1e-12** (A&L §3.1, Fig 3-4: `E_min ∈
   {1e-3,1e-6,1e-9,1e-12}`, contrast-independent for `E_min ≤ 1e-6`) — but on a 2D single-feature
   cell, not many 3D ligaments. So the two genuinely-open gaps this task targets stand:
   **(a) 1e9 contrast with many sub-coarse-cell ligaments in 3D; (b) a single-workstation (~6-core,
   non-MPI) ~8M-DOF 3D-elasticity GenEO run.** Neither is in the literature.

**Our contrast is exactly the paper's design-example contrast.** Production uses `rho_min=1e-3`,
`p=3`, no additive `E_min`, so the void floor is `rho_min^p·E0 = 1e-9·E0` → **contrast 1e9**,
identical to A&L §6's `E_min=1e-9`. The real 8M-DOF extent is 192×112×128 elements = **8.44M DOF**.

---

## METHOD — what the harness measures, and why it is exact

For a subdomain (agglomerate) it assembles the local Neumann stiffness `K^ω` (production
`hex8_stiffness`, `E(ρ)=clamp(ρ,ρ_min,1)^3` with `Emax=1` normalization so `λ` and the threshold
are directly comparable to A&L; global Dirichlet DOFs eliminated), forms `D^ω = diag(K^ω)`, and
solves the **dense** symmetric-definite generalized eigenproblem `(K^ω, D^ω)` with Eigen's
`GeneralizedSelfAdjointEigenSolver` (eigenvalues-only). Because `D^ω` is SPD, the pencil is
symmetric-definite and the solve returns the EXACT spectrum — so `N_i = #(λ < λ_Ω)` is exact, and
we also see the gap structure (does a threshold cleanly separate the contrast-induced near-null
modes from the bulk). Fields are developed by the FULL production OC recipe (E0=3500 MPa, p=3,
MultigridCG_Matfree, 2.5 mm filter, 40 iters) at each ladder rung — the fields are real (BAR B1).

Dense eigenvalues-only is a SIZING instrument (O(n_s^3), capped at n_s≤12k), not the production
eigensolver; the real method would use shift-invert Lanczos (SLEPc/ARPACK) — see G2/G3.

### Self-check (bar before any measurement) — `evidence/probe_stdout.txt`
| case | expected | measured |
|---|---|---|
| uniform solid block | exactly 6 rigid-body modes < λ_Ω | 6 ✓ |
| uniform soft block (ρ=ρ_min) | 6 (pure scale of solid) | 6 ✓ |
| uniform ρ=0.5 (global E scale) | 6 (λ invariant to global E) | 6 ✓ |
| two disjoint stiff cubes in 1e-9 soft | ~12 (2 near-rigid bodies) | 12, λ[6]=1.7e-10, λ[7]=2.6e-10 ✓ |

The two-inclusion case validates that the machinery detects and correctly counts the
contrast-induced near-null modes GenEO exists to capture.

---

## G1 — ★ HOW BIG DOES THE COARSE SPACE GET (the deliverable)

Measured on REAL OC-developed fields (`evidence/coarse_size_summary.csv`, `subdomain_detail.csv`,
`probe_stdout.txt`). Threshold = A&L's `λ_Ω = 6.5e-4`, contrast 1e9, overlap 1 element. "modes/sub"
= per-subdomain mode count (min/median/max); `N_t` = total coarse dimension. `N_t(8.44M)` extrapolates
by holding subdomain size fixed and scaling to the real 192×112×128 run.

**★ Headline finding: the coarse space does NOT blow up. It is governed by the ~6 rigid-body modes
per subdomain; the high-contrast surcharge is small and roughly size-independent.** Across every rung
and every decomposition the MEDIAN modes/subdomain is **6** (the rigid-body floor) and the MEAN is
**5.3-5.9** (below 6 because subdomains anchored to the Dirichlet face lose rigid modes). The contrast
surcharge shows only in the MAX (6→12) and grows as the design gets sparser — exactly the GenEO
signature (a wispier field has more weakly-coupled ligaments crossing subdomain boundaries) — but it
never dominates.

### G1a — the four production ladder rungs (cantilever 48×24×48, 180,075 fine DOF, core=8)
| rung | N_t | % of fine | modes/sub min·med·max | basis MB | coarseOp ceil MB | **N_t(8.44M)** | **basis MB(8.44M)** |
|---:|---:|---:|:--:|---:|---:|---:|---:|
| 0.68 | 579 | 0.32% | 0·6·7  | 15.6 | 2.6 | 27,137 | 732 |
| 0.52 | 574 | 0.32% | 0·6·6  | 15.5 | 2.5 | 26,903 | 727 |
| 0.38 | 602 | 0.33% | 0·6·12 | 16.3 | 2.8 | 28,215 | 764 |
| 0.26 | 633 | 0.35% | 0·6·12 | 17.1 | 3.1 | 29,668 | 802 |

The coarse space is **0.32-0.35% of the fine DOF** and barely moves across the ladder — the sparser
rungs cost slightly MORE (more ligaments), but only ~10%.

### G1b — subdomain-size sweep (rung 0.68 — "a few decompositions")
| core (elem) | #subdomains | N_t | % of fine | **modes/subdomain (mean)** | basis MB | coarseOp ceil MB | N_t(8.44M) |
|---:|---:|---:|---:|:--:|---:|---:|---:|
| 6³  | 256 | 1414 | 0.79% | 5.5 | 21.2 | 15.3 | 66,273 |
| 8³  | 108 | 579  | 0.32% | 5.4 | 15.6 | 2.6  | 27,137 |
| 10³ | 75  | 394  | 0.22% | 5.3 | 13.8 | 1.2  | 18,466 |
| 12³ | 32  | 178  | 0.099%| 5.6 | 11.9 | 0.24 | 8,342  |

**The mean modes/subdomain is invariant (~5.3-5.6) across a 4× range of subdomain volume.** Total
coarse size therefore scales like (#subdomains × ~6), so FEWER, LARGER subdomains give a much SMALLER
coarse space (0.79%→0.10%) — at the price of larger local eigensolves/factorizations (G2). At the real
8.44M-DOF scale the projected coarse dimension spans **~8,300 (core-12) to ~66,000 (core-6)**, i.e.
0.1-0.8% of fine — a coarse operator of ~0.5 GB (dense-ceiling, core-12) and basis ~0.5-1.0 GB. This is
**bounded and affordable in isolation** — the coarse space is not the killer.

### G1c — threshold robustness and the per-subdomain distribution (`threshold_sweep.csv`, `subdomain_detail.csv`)
**The threshold sits in a wide safe plateau — there is a clean spectral gap.** Sweeping `λ_Ω` on
rung 0.68 (core=8): N_t = 565 (1e-5), 569 (1e-4), **579 (6.5e-4, A&L)**, 586 (1e-3), 627 (3e-3),
704 (1e-2) — then a jump to 1244 (3e-2) and 4243 (1e-1). Across a **full decade** (1e-5→1e-2) the
coarse space only grows ~25%; the explosion at 1e-1 is where the threshold starts swallowing the
bulk elastic spectrum. So the method is NOT threshold-fragile at our feature density — a decade-wide
window all yields a small coarse space.

**The distribution is the GenEO signature exactly.** At the wispiest rung (0.26), of 108 subdomains:
**76 need exactly 6** (rigid-body only, zero contrast surcharge), 9 need 0 (Dirichlet-anchored), and
only a **tail of 17 need >6** (up to 12) — the ones straddling thin ligaments. The contrast surcharge
is rare and concentrated, and it tracks sparsity: subdomains with >6 modes number 2/108 (rung 0.68),
0/108 (0.52), 14/108 (0.38), 17/108 (0.26). The dilute L-bracket fixture agrees (0.36% of fine at
both rungs), confirming the result is not specific to the cantilever.

---

## G2 — Setup cost + amortization

Full analysis in `evidence/g2_setup_cost_notes.md`. Summary: per-subdomain setup is dominated by
ONE sparse-direct factorization of the local Neumann matrix (3D nested-dissection Cholesky, flops
~O(n_s^2), fill ~O(n_s^{4/3})), reused across the shift-invert Lanczos applies; the survey brackets
the aggregate factor memory at ~5-16 GB and the one-time setup wall-time at minutes on 6 cores.
Setup is embarrassingly parallel and **amortizes**: A&L rebuilt the basis only **7×/200 design
iterations**; our ladder + slow within-rung design change gives a single-digit rebuild count per
run (~5-10% overhead per state solve). **But** A&L amortized over 3 unique agglomerates
(periodicity); our 3D general field makes every subdomain unique, so each rebuild is
O(n_subdomains) eigensolves. Amortization across iterations holds; across subdomains it does not —
so coarse-space SIZE, not rebuild frequency, governs. **R-GenEO** (Spillane: eigenproblems only in
a boundary ring) is the published lever to cut both setup and size for Phase 1.

---

## G3 — Implementation survey (PETSc PCHPDDM+SLEPc / HPDDM / dune-pdelab)

Full survey in `evidence/implementation_survey.md`. **Decisive cross-cutting fact: there is no
matrix-free GenEO.** The coarse space is built from a generalized eigenproblem
`A_neu x = λ A_ovlp x` whose operands are assembled sparse matrices, and shift-invert needs a
sparse-direct factorization of `A_neu`. All three libraries therefore force assembly of the global
system + per-subdomain Neumann + a second overlap matrix + their factorizations.

| | macOS CPU-only build | operator interface | local eigensolve | elasticity/contrast |
|---|---|---|---|---|
| **PCHPDDM+SLEPc** | yes; needs MPI + BLAS/LAPACK + **SLEPc** + MUMPS/SuiteSparse | assembled aux Neumann matrix required (MATSHELL can't feed coarse) | SLEPc shift-invert | 3D-elasticity `ex71.c`; **no published 1e9** |
| **HPDDM direct** | yes; MPI + BLAS/LAPACK + direct solver + ARPACK/SLEPc | you supply assembled local matrices + PoU/overlap plumbing | ARPACK/SLEPc | mature via FreeFEM/PETSc; same 1e9 caveat |
| **dune-pdelab** | yes, heaviest; DUNE stack + MPI + ARPACK; version-fragile | assembled BCRSMatrix (Neumann + overlap) | ARPACK shift-invert | best-documented (dune-composites) but CLUSTER; same caveat |

**Single-node MPI is mandatory** for all three (subdomains are ranks; a sequential run degenerates
the overlap eigenproblem). **Assembly memory at 8M DOF ≈ 20-35 GB** (global K ~7.8 GB CSR-double +
per-subdomain Neumann ~9-12 GB + factor fill ~5-16 GB) vs the current **matrix-free MG-CG baseline
of tens-to-low-hundreds of MB** — at or over a 16-32 GB Mac's RAM ceiling. **PCHPDDM+SLEPc is the
least-effort route** if Phase 1 proceeds, but all three violate BAR B2 (heavyweight new dependency:
MPI + direct solver + eigensolver).

---

## G4 — Void-DOF elimination / raised rho_min interaction

Both levers were measured on the SAME rung-0.38 cantilever, core=8 (`coarse_size_summary.csv`
tags `G4soft`/`G4voidcut`/`G4rhomin`, plus the `CONTRAST` rows at rung 0.52):

| variant | contrast | subdomains solved | N_t | % of fine | basis MB (8.44M proj) | vs baseline |
|---|---:|---:|---:|---:|---:|---|
| soft-void (production) | 1e9 | 108/108 | 602 | 0.334% | 764 | baseline |
| **void-ELIMINATED** (ρ<0.1 removed) | 1e9 | **90/108** | 507 | 0.282% | **393** | N_t −16%, memory **−49%** |
| raised ρ_min (→1e6) | 1e6 | 108/108 | 584 | 0.324% | 742 | N_t −3%, memory −3% |
| contrast sweep (rung 0.52) | 1e9→1e6 | — | 574→571 | 0.319→0.317% | 727→724 | **~0% — size is contrast-insensitive** |

**Two clean findings:**
1. **Raising ρ_min (lowering contrast) barely shrinks the coarse space** (−3%), because the coarse
   space is rigid-body-dominated, not contrast-dominated. The independent contrast sweep confirms
   it: 1e9→1e6 moves N_t by <1%. So the "lower the contrast to shrink the coarse space" hypothesis
   is REFUTED at our feature density — the two interact only weakly.
2. **Void-DOF elimination is the real lever, and it acts on MEMORY more than count.** Removing the
   soft-void elements cuts N_t 16% but nearly HALVES the projected basis memory (764→393 MB), and it
   also makes **18 of 108 subdomains vanish entirely** (fully-void core blocks) — a direct win that
   compounds with the void-DOF reduction the maintainer already gets from a matrix-free active
   domain. This is the interaction worth a number: **void elimination + GenEO co-operate; a raised
   ρ_min does not.**

---

## VERDICT

**On the question this Phase-0 was built to answer — the coarse-space SIZE — the answer is
FAVORABLE, and it closes gap (a) with a number the literature did not have.** At 1e9 contrast, on
REAL OC-developed 3D fields with many sub-coarse-cell ligaments, the spectral/GenEO coarse space
does NOT blow up: it is dominated by the ~6 rigid-body modes per subdomain, the high-contrast
surcharge is rare (0-17% of subdomains) and concentrated near thin ligaments, the total is
**0.1-0.8% of fine DOF** (tunable down by using fewer/larger subdomains), the threshold has a
decade-wide safe window, and at the real 8.44M-DOF scale the coarse dimension projects to
**~8k-66k** (basis ~0.5-1.0 GB, coarse operator ~0.5 GB at large subdomains). The A&L
contrast-independence extends to our regime FOR SIZE — and independently, dropping contrast 1e9→1e6
barely moves it, because the space is rigid-body-dominated, not contrast-dominated.

**But adoption is gated by G3, not G1.** The blocker is architectural, not spectral:
- **No matrix-free GenEO exists.** Every library (PCHPDDM+SLEPc, HPDDM, dune-pdelab) forces
  assembly of the global system + per-subdomain Neumann + overlap matrices + their sparse-direct
  factorizations — **~20-35 GB at 8M DOF**, versus the maintainer's matrix-free MG-CG baseline of
  tens-to-low-hundreds of MB. Adopting any of them means abandoning the matrix-free architecture
  that makes 8M DOF fit on the workstation in the first place.
- **Heavyweight new dependency + mandatory single-node MPI** (MPI + BLAS/LAPACK + MUMPS/SuiteSparse
  + SLEPc/ARPACK). This violates **BAR B2** outright.

**Setup cost (G2) is not the bottleneck** — it is embarrassingly parallel and amortizes across
design iterations (A&L: 7 rebuilds/200 iters); it does NOT amortize across subdomains the way A&L's
2D periodic case did (every 3D subdomain is unique), but the coarse SIZE, not the rebuild count,
governs. **G4:** void-DOF elimination co-operates with GenEO (−16% count, −49% memory, and 18/108
subdomains vanish); a raised ρ_min does not (−3%).

**Recommendation: NO-GO for a near-term production build via off-the-shelf libraries** (B2 +
matrix-free abandonment). The one architecture-preserving path is a **bespoke two-level Schwarz with
a GenEO coarse space where the FINE operator stays matrix-free and only the SMALL per-subdomain
Neumann matrices (~16k DOF each) are assembled** for the local eigensolves — the measured coarse
space is small enough (this report) that this is a plausible, bounded Phase-1 prototype. It targets
exactly the regime the existing geometric-MG/AMG track cannot: the DEVELOPED, high-contrast field,
where geometric MG degrades monotonically (deepest rung = hardest) while GenEO's coarse space is
provably — and now measurably — small. That prototype should be weighed against the dependency-free
`amg_lean` track already in flight (which already carries the dilute regime); GenEO is the
theoretically-right tool for the developed regime, and its price is assembly of the local operators,
not an exploding coarse space. **Per BAR B3, the sizing + survey delivered here is the decision
input; no prototype was built.**

---

## Evidence
- `evidence/2026-07-28-spectral-coarse-space-phase0/`
  - `paper_notes_alexandersen_lazarov_2015.md` — primary-source extraction (the 2D/periodic caveat).
  - `implementation_survey.md` — G3 full survey with source URLs.
  - `g2_setup_cost_notes.md` — G2 analysis.
  - `code_map.md` — the production anchors the harness reuses.
  - `spectral_coarse_probe.cpp` — copy of the harness as run.
  - `probe_stdout.txt` — self-check + full measurement stdout.
  - `coarse_size_summary.csv`, `subdomain_detail.csv`, `threshold_sweep.csv` — the measured data.
- `core/tests/harness/spectral_coarse_probe.cpp` — the harness (additive; not wired into CTest).

## git status
Additive only — no production file touched:
```
?? core/tests/harness/spectral_coarse_probe.cpp
?? docs/handoffs/2026-07-28-spectral-coarse-space-phase0.md
?? evidence/2026-07-28-spectral-coarse-space-phase0/
```
The harness is standalone (built by hand against `build/libtopopt.a` + Homebrew Eigen), NOT wired
into CMake/CTest, and adds no dependency to the build. Nothing under `core/src`, `core/include`,
`docs/ARCHITECTURE.md`, `docs/DECISIONS.md`, `docs/ROADMAP.md` or `materials.json` was modified.
