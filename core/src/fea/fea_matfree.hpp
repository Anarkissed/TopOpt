// Internal (non-installed) header shared by the matrix-free FEA translation
// units: matfree.cpp (the matrix-free operator + matrix-free Jacobi-CG) and
// multigrid.cpp (which reuses the matrix-free apply, diagonal, void gate and
// reduced-system build as the FINE level of the matrix-free multigrid solver).
//
// It exposes the element table, the element-by-element apply, the reduced,
// void-gated matrix-free system, and the matrix-free Jacobi-CG so the multigrid
// solver builds its FINEST level WITHOUT ever assembling the global stiffness K
// — that assembled fine K is what OOMs on large design-box grids. Everything
// here is deliberately Eigen-FREE (like matfree.cpp): no Eigen header, no sparse
// matrix; the only dense storage representing K is the single 24x24 reference
// element stiffness Ke (576 doubles), independent of grid size.
//
// This header is NOT part of the public topopt/ API (which stays Eigen-free per
// ARCHITECTURE §4); it is compiled only into the library.

#pragma once

#include <vector>

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

namespace topopt {
namespace fea_detail {

// Number of element colours: a 2x2x2 (parity of i,j,k) partition of the regular
// voxel grid. Two elements of the same colour differ by an even offset on at least
// one axis by construction, so on this axis they are >= 2 cells apart and their
// node spans are disjoint — no two same-colour elements share a node. Threading
// the apply one colour at a time is therefore race-free, and because each node is
// written by at most one element per colour, the scatter into that node happens in
// a FIXED colour order (0..7) independent of thread count or scheduling — the
// result is deterministic and identical for 1 vs N threads (see mf_apply_full).
constexpr int kNumColors = 8;

// One solid element: its per-voxel modulus scale and its 24 global DOF indices
// (node-major interleaved, matching hex8_stiffness). The element table is stored
// SORTED BY COLOUR (colour 0 first, then 1, .., 7); within a colour the elements
// keep grid-scan order. `color_offsets` (size kNumColors+1) delimits each colour's
// contiguous range: colour k spans [color_offsets[k], color_offsets[k+1]).
struct MfElem {
  double factor = 1.0;
  int edof[Hex8Stiffness::kDof];
};

// Build the solid-element table (edof + factor), SORTED BY COLOUR. `elem_youngs`
// selects the graded path (factor = per-voxel modulus, validated > 0) when
// non-null; otherwise the uniform path (factor = 1, the modulus already baked into
// Ke). If `color_offsets` is non-null it is filled with the kNumColors+1 range
// delimiters. `who` names the caller in thrown messages.
std::vector<MfElem> mf_build_elems(const VoxelGrid& grid,
                                   const std::vector<double>* elem_youngs,
                                   const char* who,
                                   std::vector<int>* color_offsets = nullptr);

// Set the worker-thread count for the matrix-free element apply. n<=0 selects an
// automatic count (hardware concurrency). Threading is deterministic (see
// kNumColors): the result never depends on the count. Returns the previous value.
int mf_set_thread_count(int n);
int mf_thread_count();  // effective count actually used (>= 1)

// Galerkin block cache toggle (handoff 090; public face:
// fea_set_matfree_galerkin_block_cache). Opt-in, default OFF. Read by the
// matrix-free multigrid's coarse-operator build in multigrid.cpp; it changes only
// HOW the purely geometric block W^T Ke W is obtained (compute-once-per-colour vs
// recompute-per-element), never its value, so A1 stays bit-identical.
bool mf_set_galerkin_block_cache(bool enable);
bool mf_galerkin_block_cache_enabled();

// Mixed-precision V-cycle toggle (handoff 092; public face:
// fea_set_matfree_mixed_precision). Opt-in, DEFAULT OFF. Read by the matrix-free
// multigrid solve in multigrid.cpp: when ON the V-cycle PRECONDITIONER runs in
// FP32 (fine apply, Jacobi smoother, restriction, prolongation) while the OUTER CG
// stays FP64 (residual, dot products, x/r/p, the convergence test) and the coarse
// direct solve stays FP64. The FP64 path is byte-unchanged when OFF.
bool mf_set_mixed_precision(bool enable);
bool mf_mixed_precision_enabled();

// y = K x over the FULL global stiffness, element-by-element, COLOUR by COLOUR in
// fixed order; each colour's elements are apply'd (optionally across threads, no
// races). `x` and `y` are full ndof vectors; `y` is overwritten (zeroed) then
// accumulated. No assembled K: only the reference Ke and the local 24-DOF
// gather/scatter. `color_offsets` (size kNumColors+1) must match `elems`.
void mf_apply_full(const std::vector<MfElem>& elems,
                   const std::vector<int>& color_offsets, const Hex8Stiffness& Ke,
                   const std::vector<double>& x, std::vector<double>& y);

// Single-precision twin of mf_apply_full (mixed-precision V-cycle, handoff 092).
// Same 8-colour fixed-order, race-free threading, so it is deterministic and
// bit-identical across thread counts; only the arithmetic width is FP32.
void mf_apply_full_f32(const std::vector<MfElem>& elems,
                       const std::vector<int>& color_offsets,
                       const Hex8Stiffness& Ke, const std::vector<float>& x,
                       std::vector<float>& y);

// The reduced, void-gated system in matrix-free form. `kept_global[kg]` is the
// global DOF of surviving free DOF kg; `apply_kgg` realises y_g = K_gg x_g by
// scatter -> full apply -> gather, reusing full-length scratch across iterations.
// This is exactly K restricted to the kept DOFs (fixed and void DOFs carry a zero
// in the scattered vector and are never read back), so it equals the assembled
// reduced operator DOF-for-DOF.
struct MatfreeReduced {
  std::vector<MfElem> elems;
  std::vector<int> color_offsets;   // kNumColors+1 delimiters into elems
  Hex8Stiffness Ke;
  int ndof = 0;
  int ng = 0;                       // surviving free-DOF count
  std::vector<int> kept_global;     // kg -> global DOF
  std::vector<double> up;           // full field seeded with prescribed values
  std::vector<double> rg;           // ng reduced RHS
  std::vector<double> invdiag;      // ng Jacobi inverse diagonal (matrix-free)
  // Reused full-length scratch for the matvec.
  mutable std::vector<double> xfull, yfull;
  // Reused full-length FP32 scratch for the mixed-precision matvec, sized lazily
  // on first use so the FP64-only path never allocates it (handoff 092).
  mutable std::vector<float> xfull_f, yfull_f;

  void apply_kgg(const std::vector<double>& xg, std::vector<double>& yg) const;
  // Raw-pointer core of apply_kgg: yg[0..ng) = K_gg xg[0..ng). `xg` and `yg` must
  // each point at ng contiguous doubles (yg is fully overwritten). Lets a caller
  // holding contiguous storage (e.g. an Eigen vector's .data()) drive the matvec
  // with NO marshalling copies — the multigrid fine matvec relies on this to reuse
  // the caller's buffers across CG/V-cycle iterations. Same arithmetic (and thus
  // same result, bit-for-bit) as the std::vector overload.
  void apply_kgg_raw(const double* xg, double* yg) const;
  // FP32 core of the reduced matvec: yg[0..ng) = K_gg xg[0..ng), driven off
  // contiguous float storage (handoff 092). Same operator, single precision.
  void apply_kgg_raw_f32(const float* xg, float* yg) const;
};

// Build the matrix-free reduced system. Mirrors assemble_reduced + the M3.1 gate
// (void_dof_survivors) but WITHOUT assembling a sparse matrix. On a void-gate
// rejection it sets `*info` (converged=false, 0 iterations) and throws, matching
// solve_reduced_cg. `who` names the caller in thrown messages.
MatfreeReduced mf_build_reduced(const VoxelGrid& grid, double youngs_modulus,
                                double poisson,
                                const std::vector<DirichletBC>& bcs,
                                const std::vector<NodalLoad>& loads,
                                const std::vector<double>* elem_youngs,
                                const char* who, CgInfo* info);

// Matrix-free Jacobi-preconditioned CG on the reduced system `m`, replicating
// Eigen's ConjugateGradient<..., DiagonalPreconditioner> algorithm and relative-
// residual criterion (sqrt(||r||^2/||rhs||^2) <= tolerance). `x` is seeded (warm
// start or zero) and holds the solution on the kept DOFs on return. This is the
// EXACT matrix-free solve; the multigrid path uses it as its exact fallback.
void mf_cg_solve(const MatfreeReduced& m, double tolerance, int max_iterations,
                 std::vector<double>& x, int& iters_out, double& error_out,
                 bool& converged_out);

}  // namespace fea_detail
}  // namespace topopt
