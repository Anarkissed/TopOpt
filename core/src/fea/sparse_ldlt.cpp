#include "topopt/sparse_ldlt.hpp"

#include <cmath>
#include <cstdlib>

#if defined(TOPOPT_HAVE_ACCELERATE)
#include <Accelerate/Accelerate.h>
#endif
#if defined(TOPOPT_HAVE_EIGEN)
#include <Eigen/OrderingMethods>
#include <Eigen/SparseCholesky>
#include <Eigen/SparseCore>
#endif

namespace topopt {
namespace {

double measured_residual(const SymmetricLower& a, const std::vector<double>& b, const std::vector<double>& x) {
  std::vector<double> ax(static_cast<std::size_t>(a.n), 0.0);
  for (std::size_t k = 0; k < a.val.size(); ++k) {
    const std::size_t i = static_cast<std::size_t>(a.row[k]), j = static_cast<std::size_t>(a.col[k]);
    ax[i] += a.val[k] * x[j];
    if (i != j) ax[j] += a.val[k] * x[i];
  }
  double bn = 0.0, rr = 0.0;
  for (std::size_t i = 0; i < ax.size(); ++i) {
    bn += b[i] * b[i];
    rr += (b[i] - ax[i]) * (b[i] - ax[i]);
  }
  return bn > 0.0 ? std::sqrt(rr) / std::sqrt(bn) : 0.0;
}

void gate(SparseLdltResult& r, const SymmetricLower& a, const std::vector<double>& b, const SparseLdltOptions& o) {
  r.residual = o.residual ? o.residual(r.x) : measured_residual(a, b, r.x);
  r.ok = r.residual < o.accept_residual;
}

#if defined(TOPOPT_HAVE_ACCELERATE)
// As beam_network.cpp had it (2026-11-18): AMD order, LDLT unless Cholesky is asked, no pivot or zero tolerance.
SparseLdltResult solve_accelerate(const SymmetricLower& a, const std::vector<double>& b, const SparseLdltOptions& o) {
  SparseLdltResult r;
  r.backend = "Accelerate";
  const int n = a.n;
  SparseAttributes_t attr{};
  attr.kind = SparseSymmetric;
  attr.triangle = SparseLowerTriangle;
  SparseMatrix_Double m = SparseConvertFromCoordinate(n, n, static_cast<long>(a.val.size()), 1, attr, a.row.data(),
                                                      a.col.data(), a.val.data());
  SparseSymbolicFactorOptions sopt{};
  sopt.control = SparseDefaultControl;
  sopt.orderMethod = SparseOrderAMD;
  sopt.order = nullptr;
  sopt.ignoreRowsAndColumns = nullptr;
  sopt.malloc = malloc;
  sopt.free = free;
  sopt.reportError = nullptr;
  SparseFactorization_t ftype = o.try_cholesky ? SparseFactorizationCholesky : SparseFactorizationLDLT;
  SparseOpaqueSymbolicFactorization sym = SparseFactor(ftype, m.structure, sopt);
  if (sym.status != SparseStatusOK) {
    r.status = static_cast<int>(sym.status);
  } else {
    r.symbolic_ok = true;
    r.factor_gb = static_cast<double>(sym.factorSize_Double) / (1024.0 * 1024.0 * 1024.0);
    if (r.factor_gb > o.memory_limit_gb) {
      r.too_large = true;
    } else {
      SparseNumericFactorOptions nopt{};
      nopt.control = SparseDefaultControl;
      nopt.scalingMethod = SparseScalingDefault;
      nopt.scaling = nullptr;
      nopt.pivotTolerance = 0.0;
      nopt.zeroTolerance = 0.0;
      SparseOpaqueFactorization_Double fac = SparseFactor(sym, m, nopt);
      r.method = o.try_cholesky ? "Cholesky" : "LDLT";
      if (fac.status != SparseStatusOK && o.try_cholesky) {
        r.cholesky_refused = true;
        r.status = static_cast<int>(fac.status);
        SparseCleanup(fac);
        SparseCleanup(sym);
        sym = SparseFactor(SparseFactorizationLDLT, m.structure, sopt);
        fac = SparseFactor(sym, m, nopt);
        r.method = "LDLT";
      }
      if (fac.status == SparseStatusOK) {
        r.numeric_ok = true;
        r.x = b;
        DenseVector_Double xb{n, r.x.data()};
        SparseSolve(fac, xb);
        gate(r, a, b, o);
      } else {
        r.status = static_cast<int>(fac.status);
      }
      SparseCleanup(fac);
    }
    SparseCleanup(sym);
  }
  SparseCleanup(m);
  return r;
}
#endif

#if defined(TOPOPT_HAVE_EIGEN)
using EigenMatrix = Eigen::SparseMatrix<double, Eigen::ColMajor, int>;
// The symbolic stage lays out L's columns (their starts) before the numeric one; reading it needs the base's members.
struct EigenLdlt : Eigen::SimplicialLDLT<EigenMatrix, Eigen::Lower, Eigen::AMDOrdering<int>> {
  double predicted_entries() const {
    return this->m_matrix.outerIndexPtr() ? static_cast<double>(this->m_matrix.outerIndexPtr()[this->m_matrix.cols()])
                                          : 0.0;
  }
};

SparseLdltResult solve_eigen(const SymmetricLower& a, const std::vector<double>& b, const SparseLdltOptions& o) {
  SparseLdltResult r;
  r.backend = "Eigen";
  r.method = "LDLT";
  EigenMatrix m(a.n, a.n);
  {
    std::vector<Eigen::Triplet<double, int>> t;
    t.reserve(a.val.size());
    for (std::size_t k = 0; k < a.val.size(); ++k) t.emplace_back(a.row[k], a.col[k], a.val[k]);
    m.setFromTriplets(t.begin(), t.end());   // repeats summed
  }
  EigenLdlt f;
  f.analyzePattern(m);
  if (f.info() != Eigen::Success) {
    r.status = static_cast<int>(f.info());
    return r;
  }
  r.symbolic_ok = true;
  // L's entries (value + row index) and the diagonal.
  r.factor_gb = (f.predicted_entries() * (sizeof(double) + sizeof(int)) + a.n * (sizeof(double) + sizeof(int))) /
                (1024.0 * 1024.0 * 1024.0);
  if (r.factor_gb > o.memory_limit_gb) {
    r.too_large = true;
    return r;
  }
  f.factorize(m);
  if (f.info() != Eigen::Success) {
    r.status = static_cast<int>(f.info());
    return r;
  }
  r.numeric_ok = true;
  Eigen::Map<const Eigen::VectorXd> bv(b.data(), a.n);
  const Eigen::VectorXd x = f.solve(bv);
  r.x.assign(x.data(), x.data() + a.n);
  gate(r, a, b, o);
  return r;
}
#endif

}  // namespace

bool sparse_ldlt_available(SparseLdltBackend backend) {
  switch (backend) {
    case SparseLdltBackend::Accelerate:
#if defined(TOPOPT_HAVE_ACCELERATE)
      return true;
#else
      return false;
#endif
    case SparseLdltBackend::Eigen:
#if defined(TOPOPT_HAVE_EIGEN)
      return true;
#else
      return false;
#endif
    case SparseLdltBackend::Auto:
      return sparse_ldlt_available(SparseLdltBackend::Accelerate) || sparse_ldlt_available(SparseLdltBackend::Eigen);
  }
  return false;
}

SparseLdltResult sparse_ldlt_solve(const SymmetricLower& a, const std::vector<double>& b,
                                   const SparseLdltOptions& options) {
  SparseLdltBackend use = options.backend;
  if (use == SparseLdltBackend::Auto)
    use = sparse_ldlt_available(SparseLdltBackend::Accelerate) ? SparseLdltBackend::Accelerate
                                                                : SparseLdltBackend::Eigen;
  SparseLdltResult none;
  none.available = false;
  if (a.n <= 0 || b.size() != static_cast<std::size_t>(a.n) || a.row.size() != a.val.size() ||
      a.col.size() != a.val.size()) {
    none.available = sparse_ldlt_available(use);
    return none;
  }
#if defined(TOPOPT_HAVE_ACCELERATE)
  if (use == SparseLdltBackend::Accelerate) return solve_accelerate(a, b, options);
#endif
#if defined(TOPOPT_HAVE_EIGEN)
  if (use == SparseLdltBackend::Eigen) return solve_eigen(a, b, options);
#endif
  return none;
}

}  // namespace topopt
