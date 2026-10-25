// REAL BOLTS (the reviewer's brief of 2026-10-25 20:10) — the contact set of bearing
// anchors. See DirichletBC::spring and contact_update in fea.hpp.
#include <algorithm>
#include <cmath>
#include <vector>

#include "topopt/fea.hpp"

namespace topopt {

bool has_contact_springs(const std::vector<DirichletBC>& bcs) {
  for (const DirichletBC& b : bcs)
    if (b.spring > 0.0) return true;
  return false;
}

ContactUpdate contact_update(std::vector<DirichletBC>& bcs, const std::vector<double>& u) {
  ContactUpdate r;
  auto gap = [&](const DirichletBC& b) {
    const std::size_t d = 3 * static_cast<std::size_t>(b.node);
    return u[d] * b.normal.x + u[d + 1] * b.normal.y + u[d + 2] * b.normal.z;
  };
  double umax = 0.0;
  for (const DirichletBC& b : bcs)
    if (b.spring > 0.0)
      for (int c = 0; c < 3; ++c)
        umax = std::max(umax, std::fabs(u[3 * static_cast<std::size_t>(b.node) + c]));
  // Pulling away by more than roundoff releases; a node that does not move stays.
  const double tol = 1e-12 * umax;
  int engaged_next = 0;
  for (const DirichletBC& b : bcs)
    if (b.spring > 0.0 && !(gap(b) < -tol)) ++engaged_next;
  if (engaged_next == 0) r.kept_last = true;
  for (DirichletBC& b : bcs) {
    if (!(b.spring > 0.0)) continue;
    const bool next = !r.kept_last && gap(b) < -tol;
    if (next != b.released) {
      b.released = next;
      ++r.changed;
    }
    (b.released ? r.released : r.engaged) += 1;
  }
  if (r.changed > 0) {
    fea_reset_krylov_recycle_space();
    fea_reset_geneo_basis();
    fea_matfree_reset_mg_safe_failures();
  }
  return r;
}

}  // namespace topopt
