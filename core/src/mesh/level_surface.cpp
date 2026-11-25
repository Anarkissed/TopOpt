// level_surface.cpp -- see level_surface.hpp.
#include "topopt/level_surface.hpp"

#include <chrono>
#include <cmath>
#include <cstdlib>
#include <sstream>

#ifdef TOPOPT_HAVE_MANIFOLD
#include "manifold/manifold.h"
#endif

namespace topopt {

bool plsm_parse_basis(const std::string& s, PlsmBasisKind& out) {
  if (s == "gaussian") out = PlsmBasisKind::Gaussian;
  else if (s == "wendland" || s == "wendland_c2") out = PlsmBasisKind::Wendland;
  else if (s == "wendland_c4") out = PlsmBasisKind::WendlandC4;
  else if (s == "bspline") out = PlsmBasisKind::BSpline3;
  else return false;
  return true;
}

SurfaceSwitch to_surface_switch() {
  SurfaceSwitch s;
  const char* v = std::getenv("TOPOPT_SURFACE");
  if (v == nullptr) return s;
  s.raw = v;
  if (s.raw.rfind("on", 0) != 0) return s;
  s.on = true;
  std::vector<std::string> parts;
  std::stringstream ss(s.raw);
  for (std::string p; std::getline(ss, p, ':');) parts.push_back(p);
  if (parts.size() >= 2 && plsm_parse_basis(parts[1], s.basis)) s.basis_set = true;
  if (parts.size() >= 3) s.reach = std::atof(parts[2].c_str());
  if (parts.size() >= 4) s.knot_line_widths = std::atof(parts[3].c_str());
  if (!(s.reach >= 1.0)) s.reach = 2.0;
  if (!(s.knot_line_widths >= 0.0)) s.knot_line_widths = 0.0;
  return s;
}

double PlsmFieldView::value(const Vec3& p, Vec3* grad) const {
  const double x = (p.x - origin.x) / h - 0.5;
  const double y = (p.y - origin.y) / h - 0.5;
  const double z = (p.z - origin.z) / h - 0.5;
  double g[3];
  const double v = plsm_value_grad(*lattice, basis, *alpha, x, y, z, grad ? g : nullptr);
  if (grad) *grad = Vec3{g[0] / h, g[1] / h, g[2] / h};
  return v;
}

TriangleMesh mesh_level_surface(const std::function<double(const Vec3&)>& f,
                                const Vec3& lo, const Vec3& hi, double cell_mm,
                                double tol_mm, LevelSurfaceStats* stats) {
  const auto t0 = std::chrono::steady_clock::now();
  TriangleMesh out;
#ifdef TOPOPT_HAVE_MANIFOLD
  long long n = 0;
  // Manifold's convention is positive INSIDE; ours is negative inside.
  auto sdf = [&](manifold::vec3 q) {
    ++n;
    return -f(Vec3{q.x, q.y, q.z});
  };
  const manifold::Box box(manifold::vec3(lo.x, lo.y, lo.z), manifold::vec3(hi.x, hi.y, hi.z));
  const manifold::Manifold M =
      manifold::Manifold::LevelSet(sdf, box, cell_mm, 0.0, tol_mm, /*canParallel=*/false);
  const manifold::MeshGL64 g = M.GetMeshGL64();
  out.vertices.reserve(g.NumVert());
  for (std::size_t v = 0; v < g.NumVert(); ++v)
    out.vertices.push_back({g.vertProperties[v * g.numProp], g.vertProperties[v * g.numProp + 1],
                            g.vertProperties[v * g.numProp + 2]});
  out.triangles.reserve(g.NumTri());
  for (std::size_t t = 0; t < g.NumTri(); ++t)
    out.triangles.push_back({static_cast<int>(g.triVerts[3 * t]),
                             static_cast<int>(g.triVerts[3 * t + 1]),
                             static_cast<int>(g.triVerts[3 * t + 2])});
  if (stats) {
    stats->evaluations = n;
    stats->used_manifold = true;
  }
#else
  (void)f; (void)lo; (void)hi; (void)cell_mm; (void)tol_mm;
#endif
  if (stats) {
    stats->vertices = static_cast<long long>(out.vertices.size());
    stats->triangles = static_cast<long long>(out.triangles.size());
    stats->seconds =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  }
  return out;
}

SurfaceError surface_error(const TriangleMesh& m,
                           const std::function<double(const Vec3&)>& sd,
                           const Vec3& lo, const Vec3& hi, double ignore_mm) {
  SurfaceError e;
  double s2 = 0.0;
  auto take = [&](const Vec3& p) {
    if (p.x < lo.x || p.x > hi.x || p.y < lo.y || p.y > hi.y || p.z < lo.z || p.z > hi.z) return;
    const double d = std::fabs(sd(p));
    if (d > ignore_mm) return;
    e.worst = std::max(e.worst, d);
    s2 += d * d;
    ++e.points;
  };
  auto mid = [](const Vec3& a, const Vec3& b) {
    return Vec3{0.5 * (a.x + b.x), 0.5 * (a.y + b.y), 0.5 * (a.z + b.z)};
  };
  for (const Vec3& v : m.vertices) take(v);
  for (const auto& t : m.triangles) {
    const Vec3 &a = m.vertices[t[0]], &b = m.vertices[t[1]], &c = m.vertices[t[2]];
    take(Vec3{(a.x + b.x + c.x) / 3.0, (a.y + b.y + c.y) / 3.0, (a.z + b.z + c.z) / 3.0});
    take(mid(a, b));
    take(mid(b, c));
    take(mid(c, a));
  }
  if (e.points > 0) e.rms = std::sqrt(s2 / static_cast<double>(e.points));
  return e;
}

}  // namespace topopt
