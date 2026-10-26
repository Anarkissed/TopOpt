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
  // A HYSTERESIS BAND: a pressing node is released only when it clearly pulls away
  // (u . n < -tol), a released one engages again only when it clearly presses
  // (u . n > +tol); a node inside the band keeps its state. Without it, nodes at the
  // edge of the contact flip back and forth and the set never settles (his Carriage
  // Arms at res 48: still changing after 6 solves). tol = 1e-3 of the largest |u . n|.
  double gmax = 0.0;
  for (const DirichletBC& b : bcs)
    if (b.spring > 0.0) gmax = std::max(gmax, std::fabs(gap(b)));
  const double tol = 1e-3 * gmax;
  auto next_released = [&](const DirichletBC& b) {
    const double g = gap(b);
    return b.released ? !(g > tol) : g < -tol;
  };
  int engaged_next = 0;
  for (const DirichletBC& b : bcs)
    if (b.spring > 0.0 && !next_released(b)) ++engaged_next;
  if (engaged_next == 0) r.kept_last = true;
  for (DirichletBC& b : bcs) {
    if (!(b.spring > 0.0)) continue;
    const bool next = !r.kept_last && next_released(b);
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
