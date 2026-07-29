# Anchor-paper notes — Alexandersen & Lazarov, CMAME 290:156-182 (2015), arXiv 1411.3923

Read from the arXiv v1 PDF (47pp). Facts extracted verbatim/near-verbatim with page anchors.

## Method — spectral coarse basis (this IS the measurable quantity)
- **§2.4, p.7-9.** Fine mesh is a refinement of a coarse mesh `T_H = {K_j}`. Around each
  coarse node `y_i`, an **agglomerate** `ω_i` = union of coarse cells sharing `y_i`
  (overlapping neighbourhoods, overlap δ). Coarse basis functions `φ_{i,j} = ψ^{ω_i}_j · χ_i`
  where `χ_i` is a partition of unity (`|∇χ_i| ≤ 1/H`).
- **Local generalised eigenproblem (eq. 9), per agglomerate:**
  `K^{ω_i} ψ_j = λ_j M^{ω_i} ψ_j`, eigenvalues ascending. Keep every eigenvector with
  `λ_j < λ_Ω` (a single global threshold). `N_i` = #(eigenvalues below λ_Ω) for agglomerate i.
  **Total coarse dimension `N_t = Σ_i N_i`.** ← THIS is the G1 deliverable, per subdomain.
- **§3.2, p.13.** The weight matrix `M^{ω_i}` is taken as **`diag(K^{ω_i})`** (spectrally
  equivalent to the stiffness-based mass matrix, `λ_diag ≈ C h² λ_M`; cheaper). Used throughout.
- **§2.4.2.** Applied as a two-level additive-Schwarz-like coarse solve inside a multigrid-like
  preconditioner, one pre/post symmetric-Gauss-Seidel smooth, wrapped in **GMRES** (authors
  find GMRES beats PCG here though the system is SPD).
- Coarse operator: `K_c = R_c K R_c^T`, `R_c^T = [φ_1 … φ_{N_t}]`.

## SIMP / contrast
- **eq. 5, p.6.** `K_e(ρ_e) = (E_min + (E_max − E_min) ρ_e^p) K_0`, `E_max = 1`. Modified SIMP.
- **§3.1, p.12 (Fig 3-4).** Contrast swept via `E_min ∈ {1e-3, 1e-6, 1e-9, 1e-12}`.
  **Behaviour is contrast-INDEPENDENT for E_min ≤ 1e-6, INCLUDING 1e-9 and 1e-12.**
  → The literature (this paper) DOES reach contrast 1e9–1e12 — but see caveat below.
- **§6, p.27.** Design examples all use `E_max=1, E_min=1e-9` (contrast 1e9), `p`-continuation 1→5.

## ★ CRITICAL CAVEATS (reframe the two gaps this task must close)
1. **The 26M-DOF / 26h / single-thread headline is 2D.** §2.1 p.5: "The considered problems
   are two-dimensional." §6.1.1 p.29: Mx=64 double-clamped beam, **13,107,200 elements,
   26,229,762 DOF, ~26 h for 200 design iters**, single Matlab thread, Dell T7500 2×Xeon X5650.
   It is a **single PERIODIC cross microstructure** → only **3 unique agglomerates**
   (§2.4.1: left-BC, right-BC, interior); the eigen-cost is paid 3× and reused everywhere.
   Our target is **3D, general (non-periodic) topology** → every subdomain is unique.
2. **Contrast 1e-12 was shown on a 2D single-feature cross cell**, not "many sub-coarse-cell
   ligaments." Gap (a) — 1e9 with many ligaments per subdomain in 3D — is genuinely unmeasured.
3. Authors state (§2.4.1, §7.4) the eigenproblem "is computationally very expensive" and that
   periodicity is what makes it affordable; 3D general is "currently being pursued" (§7.4) —
   i.e. NOT demonstrated in this paper. Gap (b) stands.

## Amortization across design iterations (feeds G2)
- **§5.1-5.2, p.22-25, Fig 8.** Basis reuse via a heuristic keyed to GMRES-iteration change.
  Over **200 design iterations the basis was recomputed only 7 times** (1 initial + 4 forced by
  `p`-continuation + 2 heuristic). "Constant" (rebuild every iter) = 768.5 s; "heuristic" = 444 s;
  "heuristic + seeded initial guess" faster; **"heuristic-initialised low-λΩ" = 298.7 s, beating
  the direct solver's 306.5 s.** Mnd (non-discreteness) tracks contrast; design barely moves in
  early/late stages → basis rebuild is rare. Strong amortization evidence.
- **Threshold values used:** λΩ = 6.5e-4 (typical, §6.1.1/§6.2); range 6.69e-4 → 4.64e-5 (§5.2);
  ε_rel = 1e-6 solver tol (1e-5 when relaxed). p continuation 1..5. rmin=4h, vf=0.5, β up to 64-128.
- Robust formulation: build the basis for the **dilated** realisation, reuse for eroded/intermediate.

## Cross-refs
- MsFEM spectral basis origin: Efendiev–Galvis (refs [24,25]); elasticity extension Lazarov [18].
- Related theory = Spillane/Dolean/Nataf/Pechstein/Scheichl GenEO (Numer. Math. 126(4), 2014):
  per-subdomain generalised eigenproblem in the overlap, coarse-space size grows with #high-contrast
  features crossing subdomain boundaries; condition-number bound independent of contrast & #subdomains
  provided all sub-threshold modes are in the coarse space.
