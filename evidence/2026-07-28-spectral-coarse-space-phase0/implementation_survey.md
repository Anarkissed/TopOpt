# G3 — Implementation survey (PETSc PCHPDDM+SLEPc, HPDDM, dune-pdelab)

Compiled from a web-research pass (2024-2026 sources), for: 3D linear elasticity, hex8,
~8M DOF, SIMP with E_min void floor (contrast to 1e9), SINGLE macOS workstation (~6 cores),
CPU-only, existing solver = matrix-free geometric MG-CG.

## Cross-cutting fact that decides the study
**GenEO is a two-level overlapping-Schwarz method whose coarse space is built from a
*generalized eigenproblem in the overlap*:** `A_neu x = λ A_ovlp x`, where `A_neu` is the
subdomain-local stiffness with Neumann conditions at subdomain boundaries and `A_ovlp` is the
same matrix zeroed outside the partition-of-unity overlap. **Both operands are assembled sparse
matrices, and the eigenproblem needs a sparse-direct factorization of `A_neu` (shift-invert).
There is no matrix-free GenEO.** This constrains all three libraries identically.

## A) PETSc PCHPDDM + SLEPc
1. **macOS/CPU build:** buildable (Apple clang or brew gcc). Mandatory stack: **MPI**
   (`--download-mpich`), BLAS/LAPACK (Accelerate ok), **SLEPc required** ("PCHPDDM requires PETSc
   built with SLEPc"), plus a sparse direct solver (MUMPS → ScaLAPACK + gfortran, or SuiteSparse)
   for local factorizations + coarse solve. **MPI strictly required — subdomains map to ranks;
   a sequential run degenerates the overlap eigenproblem.** Run `mpirun -n K` on the one node.
2. **Operator interface:** accepts MATIS / assembled AIJ/BAIJ/SBAIJ / MATSHELL for the Krylov
   matvec, **but the GenEO coarse level needs an assembled auxiliary local Neumann matrix
   (`PCHPDDMSetAuxiliaryMat`)** (skipped only if Pmat is MATIS, which assembles internally). A
   matrix-free global MATSHELL **cannot** feed the coarse construction. **Assembly forced.**
3. **Local eigenproblem:** SLEPc, default shift-invert (`-pc_hpddm_levels_1_st_type sinvert`),
   or ARPACK. Needs assembled aux Neumann matrix + internally-formed PoU overlap matrix; shift-
   invert needs the local factorization (MUMPS/SuiteSparse).
4. **Maturity/elasticity:** strongest — ships 3D-elasticity tutorial `ex71.c` (MATIS), documented
   in Jolivet et al. 2021 (Comput. Math. Appl.). Single-node fully supported. **No published
   PCHPDDM demonstration at 1e9 SIMP contrast found.**
   Sources: petsc.org/release/manualpages/PC/PCHPDDM, .../PCHPDDMSetAuxiliaryMat,
   hal.science/hal-04751926v1, github.com/geneo4PETSc/geneo4PETSc.

## B) HPDDM directly (Jolivet & Nataf)
1. **macOS/CPU build:** buildable (it is PCHPDDM's engine). C++11 + MPI + OpenMP; links numeric
   backends. Mandatory: **MPI**, BLAS/LAPACK (Accelerate on macOS), a sparse direct solver
   (MUMPS/SuiteSparse/PARDISO/PaStiX), ARPACK or SLEPc for the eigensolve.
2. **Operator interface:** HPDDM does **not** discretize. Used directly you must supply per
   subdomain: assembled local Neumann matrix, restriction/PoU operators, neighbor-rank + shared-
   DOF maps, and a local direct-solver handle. **No matrix-free path.** Materially more
   integration than PCHPDDM (which builds the PoU/overlap from an index set).
3. **Local eigenproblem:** ARPACK/SLEPc; needs the assembled local Neumann matrix + overlap-
   weighted matrix (you build both).
4. **Maturity/elasticity:** mature (runs under PCHPDDM/FreeFEM/Feel++); GenEO originates here
   (Spillane et al. 2014). Standalone 3D-elasticity examples mostly routed via FreeFEM/PETSc.
   Same 1e9 caveat.
   Sources: github.com/hpddm/hpddm.

## C) dune-pdelab GenEO (dune-common/istl; dune-composites)
1. **macOS/CPU build:** buildable but heaviest scaffolding — DUNE core (common/geometry/grid/
   istl/localfunctions) + dune-pdelab (+ dune-composites for elasticity), CMake, MPI, BLAS/LAPACK,
   **ARPACK/ARPACK++**. Version-fragile (documented GenEO/pdelab test breakages).
2. **Operator interface:** assembled BCRSMatrix; PDELab is an assembly framework. Needs two
   matrices: Neumann-at-processor-boundaries + the same zeroed away from the overlap. No matrix-
   free option — most assembly-committed of the three.
3. **Local eigenproblem:** ARPACK (ARPACK++) shift-invert. `GenEOBasis(AF_neu, AF_ovlp, PoU,
   threshold, nev)`. Sequential/no-overlap run gives empty RHS → ARPACK fails; ≥2 ranks mandatory.
4. **Maturity/elasticity:** best-documented elasticity (dune-composites; 170-200M-DOF anisotropic
   elasticity) — but those are CLUSTER runs (2048-15000 cores). Non-cluster single-workstation use
   possible, not showcased. Same 1e9 caveat.
   Sources: dune-pdelab CHANGELOG (GenEO 2.6), dune-composites geneo.hh, arXiv 1901.05188,
   arXiv 1906.10944.

## Assembly-memory cost at 8M DOF (the decisive number)
8M DOF / 3 ≈ 2.67M nodes. Hex8 = 27-node stencil → 81 nnz/row. nnz ≈ 8e6 × 81 ≈ 6.5e8.
- **Global assembled K (CSR double, full not triangle):** values 5.2 GB + int32 cols 2.6 GB +
  rowptr 0.06 GB = **≈ 7.8 GB** (≈ 10.4 GB with 64-bit indices; symmetric-only ≈ 3.9 GB but most
  DD paths keep it full).
- **Per-subdomain assembled Neumann matrices:** global nnz × overlap-dup (~1.2-1.5×) ≈ **9-12 GB**,
  plus a second overlap-weighted matrix per subdomain of comparable size (a few GB more).
- **Local factorizations (the real sink):** 3D Cholesky fill ~ O(n_s^{4/3}). 64 subdomains
  (~125k DOF each) ≈ 7-16 GB; 512 subdomains (~16k DOF each) ≈ 5-13 GB — aggregate stays **~5-16 GB**
  either way. Plus ARPACK/SLEPc work vectors (sub-GB).
- **Grand total assembled GenEO path ≈ 20-35 GB** vs the **matrix-free MG-CG baseline ≈ tens-to-
  low-hundreds of MB**. On a 16-32 GB Mac the assembled path is at/over the RAM ceiling; even 64 GB
  leaves little headroom.

## Bottom line
All three build CPU-only on a single Mac, but **none supports matrix-free GenEO** — assembly of the
global system + per-subdomain Neumann + a second overlap matrix + their factorizations is intrinsic,
pushing memory from the tens-of-MB baseline into ~20-35 GB at 8M DOF and forcing a heavy MPI +
direct-solver + eigensolver stack. **PCHPDDM + SLEPc is the least-effort route** (builds PoU/overlap
for you, ships a 3D-elasticity example, needs only an assembled aux Neumann matrix). Caveats:
single-node MPI mandatory; **no published GenEO at 1e9 SIMP contrast** — coarse-space size grows with
the number of high-contrast channels a density field packs against the void, which is exactly the
open risk this Phase-0 quantifies (see G1). All three violate BAR B2 (new heavyweight dependency).
