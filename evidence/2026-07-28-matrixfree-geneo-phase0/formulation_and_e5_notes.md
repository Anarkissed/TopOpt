# Matrix-free GenEO — exact formulation, the singular-kernel crux, and E5 assessment

Grounded from the primary source arXiv **1912.13225** (Haferssas/Jolivet/Nataf-lineage;
"Mathematical Analysis of Robustness of Two-Level Domain Decomposition Methods w.r.t.
Inexact Coarse Solves"), the survey compiled in PR 230
(`evidence/2026-07-28-spectral-coarse-space-phase0/implementation_survey.md`), and
Spillane et al., Numer. Math. 126 (2014).

## 1. The exact pencil (== the task's pencil)

**Definition 3.1 (eq. 8) of 1912.13225**, verbatim structure:

    D_j R_j A R_j^T D_j  V_jk  =  tau_jk  Ã_j  V_jk

- `D_j` — partition-of-unity diagonal on subdomain j (entries in (0,1]).
- `R_j A R_j^T` — restriction of the **global** assembled operator to subdomain j's DOFs.
  This is the task's `A_i`.
- `Ã_j` — the **local "Neumann" matrix** (eq. 5): the bilinear form assembled over Ω_j
  only. This is the task's `A_i^Neu`.
- Coarse space `V_geneo^tau` = span of `R_j^T D_j V_jk` for **tau_jk > tau** (LARGEST tau).

The task writes the same pencil `D_i A_i D_i V = λ A_i^Neu V` but says "SMALLEST λ". These
are the SAME eigenvectors under λ = 1/tau: the survey's implementation form is
`A^Neu x = λ A_ovlp x` solved by **shift-invert** (SLEPc/HPDDM default `st_type sinvert`),
whose target is the small-magnitude end. "Smallest eigenvalues / shift-invert" and
"largest tau" are two names for one wanted set — the modes a Krylov eigensolver reaches
only at the hard end. The task's framing is correct; the shift-invert it fears is exactly
what we are trying to avoid.

**Harness variant.** We use the standard partition-of-unity Neumann form `A_i := A_i^Neu`
(the survey's `A_ovlp = D A^Neu D`), so both pencil operators are element-local matrix-free
applies over the agglomerate. The restricted-global refinement (`R_j A R_j^T` including the
one-element boundary coupling) changes the boundary layer only; it does not change the
singular-kernel crux below, which is the whole question. Stated as a modeling choice.

## 2. The crux: a shared singular kernel (rigid-body modes)

`A^Neu` has an **exact** 6-dimensional kernel — the subdomain rigid-body modes — and this
is true **even under soft-void SIMP** (floor E_min = rho_min^p > 0): a rigid-body motion
produces zero strain in every element for ANY positive modulus field, so `A^Neu·(rigid)=0`
exactly, independent of contrast. Consequence for the pencil `A^Neu V = λ (D A^Neu D) V`:

- Rigid modes are **λ = 0 eigenpairs** (numerator `A^Neu v = 0`) with **finite mass**
  (`D A^Neu D · v_rigid = A^Neu(D v_rigid) ≠ 0`, because `D v_rigid` is not rigid).
- Therefore the rigid modes sit at the very bottom of the spectrum, are well posed for a
  mass-defined eigensolver (finite B-norm), and are naturally captured — no separate
  nullspace treatment is forced.
- The contrast-induced modes (the coarse-space surcharge PR 230 measured) sit just above
  at small λ > 0.

This is the single reason a matrix-free route is even a candidate: the wanted subspace is
B-non-degenerate, so **LOBPCG-smallest is well posed on it without shift-and-invert.** The
harness verifies the "exactly 6 λ≈0" structure densely (self-check) before scoring LOBPCG.

The mass matrix `D A^Neu D` is itself singular (kernel `D^{-1}·rigid`) but those are the
λ = ∞ modes at the OPPOSITE (far) end from the wanted smallest — a robust B-orthonormaliser
that drops near-null directions keeps them out of the search.

## 3. E5(a) — the coarse operator V^T A V

Correct in structure, but the "small enough to factorize densely" claim needs a number.
With V the fine-space basis (columns = the kept `R_j^T D_j V_jk`), forming `A_c = V^T A V`
costs **N_t matrix-free global applies** `A v_i` (one per coarse vector) + `N_t^2` dot
products. At PR 230's projected coarse dimension:

| N_t (coarse dim) | dense A_c = N_t² doubles | dense Cholesky |
|---|---|---|
| 8k (large subdomains) | 0.5 GB | fine |
| 33k | 8.5 GB | at the edge |
| 66k (fine subdomains) | **35 GB** | **does NOT fit** |

So E5(a) holds at the LOW end (few large subdomains → 8k → 0.5 GB dense) and **breaks at
the HIGH end** (many small subdomains → 66k → 35 GB dense). A dense coarse factorization
is affordable only if the decomposition is chosen to keep N_t near the low end (fewer,
larger subdomains — which PR 230 already showed also SHRINKS N_t: 0.79% at core-6 →
0.10% at core-12). This is a design lever, not a blocker, but it is not free.

## 4. E5(b) — inexact coarse solves (the modification, and whether it applies)

**The modification (1912.13225 eq. 9).** Replace the exact coarse inverse `E^{-1}` by an
inexact `Ẽ^{-1}` in a **deflated / balanced** two-level preconditioner:

    M^{-1}_GenEO-ACS  =  Z Ẽ^{-1} Z^T  +  (I − P̃_0) ( Σ_i R_i^T (R_i A R_i^T)^{-1} R_i ) (I − P̃_0^T)

with `P̃_0 = Z Ẽ^{-1} Z^T A` (eq. 7). The one-level (local-solve) part is wrapped in the
deflation projector `(I − P̃_0)`. This is NOT the naive additive form
`Z Ẽ^{-1} Z^T + Σ_i R_i^T A_i^{-1} R_i`; the projector is the whole point.

**The robustness condition (Lemma 3.3 / eq. 17).** The bound depends on

    ε_a = max( |1 − λ_min(E Ẽ^{-1})| , |1 − λ_max(E Ẽ^{-1})| )

i.e. the inexact coarse solve only has to be **spectrally equivalent** to the exact one
(eigenvalues of `E Ẽ^{-1}` near 1) — it need NOT be accurate to a tight tolerance. A few
Krylov iterations, or an inexact/iterative coarse solve, preserve robustness **provided the
deflated form eq. 9 is used**. The naive additive preconditioner does not enjoy this.

**Does it apply to us?** Yes, and it is exactly the lever that rescues the 66k high-end
case in §3: when the coarse operator is too big to dense-factorize, solve it inexactly
(iteratively, or with an inner AMG/CG) and use eq. 9's deflated form. The modification is
architecture-preserving (it needs only `A·x`, the local solves, and `Z`/`Ẽ^{-1}` applies —
all matrix-free-compatible). The caveat is the deflation projector `(I − P̃_0)`: it applies
`Z Ẽ^{-1} Z^T A` on every preconditioner application, i.e. a coarse solve inside every
outer CG iteration — the coarse solve cost is paid per iteration, not once. That is the
real price and it must be counted in any full-build scoping.

## 5. What this closes / opens (feeds the verdict)

- Formulation and the singular-kernel structure are settled from the primary source.
- The wanted modes are B-non-degenerate ⇒ a matrix-free eigensolve is *not* excluded a
  priori; the empirical question is convergence/capture at 1e9 contrast (E1–E3).
- E5(a) is true only for coarse-dim near the low (8k) end; the high (66k) end needs E5(b).
- E5(b)'s theorem is real, published, and applies — at the cost of a coarse solve inside
  every outer iteration.
