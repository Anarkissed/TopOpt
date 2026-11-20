#pragma once
// ── A SPARSE SYMMETRIC SOLVE AS ONE CALL (brief E2, item 1) ─────────────────────────
// The direct factorisation that was inline in solve_coupled_lattice (beam_network.cpp), lifted out so the Organic
// frame check (lattice_layout_frame.hpp) solves its frame with the same code. Matrix in, solution out:
//   - the matrix is the LOWER triangle of a symmetric n x n matrix in coordinate form (row >= col; a repeated (row,
//     col) is summed);
//   - the factor's size is predicted by the symbolic stage first and the solve is refused, before any numeric work,
//     when it would pass `memory_limit_gb`;
//   - Apple: Accelerate's sparse LDLT (AMD order; Cholesky first only when asked), as beam_network.cpp had it;
//     elsewhere (or when asked): Eigen's SimplicialLDLT (AMD order);
//   - the answer is MEASURED: ||b - A x|| / ||b|| must be under `accept_residual`, or it is not kept.
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace topopt {

struct SymmetricLower {
  int n = 0;
  std::vector<int> row, col;   // row >= col
  std::vector<double> val;
};

enum class SparseLdltBackend : std::uint8_t { Auto, Accelerate, Eigen };

struct SparseLdltOptions {
  SparseLdltBackend backend = SparseLdltBackend::Auto;   // Auto: Accelerate where built, Eigen otherwise
  double memory_limit_gb = 24.0;    // the predicted factor above this: refused (beam_network.cpp's kMaxFactorGb)
  bool try_cholesky = false;        // Accelerate only: Cholesky first, LDLT when it refuses
  double accept_residual = 1e-6;    // beam_network.cpp's kDirectAcceptResidual
  // The residual to gate on, when the caller has a better one (beam_network.cpp measures with its own full matrix);
  // empty: measured here from the lower triangle.
  std::function<double(const std::vector<double>& x)> residual;
};

struct SparseLdltResult {
  bool ok = false;              // solved and the residual is under the gate
  bool available = true;        // the asked backend is in this build
  bool symbolic_ok = false;     // the symbolic stage ran
  bool too_large = false;       // refused: the predicted factor passes the limit
  bool numeric_ok = false;      // the numeric factorisation ran
  bool cholesky_refused = false;
  int status = 0;               // the backend's own status when a stage failed
  double factor_gb = 0.0;       // the predicted factor, GB
  double residual = 0.0;        // ||b - A x|| / ||b||
  std::string method;           // "LDLT" or "Cholesky"
  std::string backend;          // "Accelerate" or "Eigen"
  std::vector<double> x;        // the solution (also when the residual gate refused it)
};

bool sparse_ldlt_available(SparseLdltBackend backend);
SparseLdltResult sparse_ldlt_solve(const SymmetricLower& a, const std::vector<double>& b,
                                   const SparseLdltOptions& options = {});

}  // namespace topopt
