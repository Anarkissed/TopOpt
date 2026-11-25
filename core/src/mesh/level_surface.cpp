// level_surface.cpp -- see level_surface.hpp.
#include "topopt/level_surface.hpp"

#include <algorithm>
#include <array>
#include <map>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <sstream>

#include <memory>
#include <set>

#include "topopt/finish.hpp"
#include "topopt/frozen_sets.hpp"
#include "topopt/mesh_distance.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/plsm_kernel.hpp"
#include "topopt/step.hpp"
#include "topopt/stl.hpp"

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
  if (parts.size() >= 5) s.fit_band_voxels = std::atof(parts[4].c_str());
  if (!(s.reach >= 1.0)) s.reach = 2.0;
  if (!(s.knot_line_widths >= 0.0)) s.knot_line_widths = 0.0;
  return s;
}

bool to_surface_on() { return to_surface_switch().on; }

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

#ifdef TOPOPT_HAVE_MANIFOLD
namespace {
manifold::Manifold to_manifold64(const TriangleMesh& m) {
  manifold::MeshGL64 g;
  g.numProp = 3;
  g.vertProperties.reserve(3 * m.vertices.size());
  for (const Vec3& v : m.vertices) {
    g.vertProperties.push_back(v.x);
    g.vertProperties.push_back(v.y);
    g.vertProperties.push_back(v.z);
  }
  g.triVerts.reserve(3 * m.triangles.size());
  for (const auto& t : m.triangles)
    for (int k = 0; k < 3; ++k) g.triVerts.push_back(static_cast<uint64_t>(t[k]));
  return manifold::Manifold(g);
}
TriangleMesh from_manifold64(const manifold::Manifold& M) {
  const manifold::MeshGL64 g = M.GetMeshGL64();
  TriangleMesh out;
  out.vertices.reserve(g.NumVert());
  for (std::size_t v = 0; v < g.NumVert(); ++v)
    out.vertices.push_back({g.vertProperties[v * g.numProp], g.vertProperties[v * g.numProp + 1],
                            g.vertProperties[v * g.numProp + 2]});
  out.triangles.reserve(g.NumTri());
  for (std::size_t t = 0; t < g.NumTri(); ++t)
    out.triangles.push_back({static_cast<int>(g.triVerts[3 * t]),
                             static_cast<int>(g.triVerts[3 * t + 1]),
                             static_cast<int>(g.triVerts[3 * t + 2])});
  return out;
}
}  // namespace
#endif

TriangleMesh mesh_intersection(const TriangleMesh& a, const TriangleMesh& b, std::string* why) {
#ifdef TOPOPT_HAVE_MANIFOLD
  const manifold::Manifold A = to_manifold64(a), B = to_manifold64(b);
  if (A.Status() != manifold::Manifold::Error::NoError ||
      B.Status() != manifold::Manifold::Error::NoError) {
    if (why)
      *why = std::string("the ") +
             (A.Status() != manifold::Manifold::Error::NoError ? "surface" : "drawn part") +
             " mesh is not a closed manifold";
    return {};
  }
  return from_manifold64(A ^ B);
#else
  (void)a; (void)b;
  if (why) *why = "this build has no Manifold";
  return {};
#endif
}

namespace {
// One frozen body by true distance: within `depth` of its own drawn triangles and
// inside its cuts. Value < 0 inside, clamped at `cap` far from it (far values
// never decide a surface).
struct FrozenBody {
  TriangleMesh tri;  // its own triangles (an open surface; unsigned distance only)
  std::unique_ptr<MeshDistance> dist;
  std::vector<RegionCut> cuts;
  double depth = 0.0;
  bool solid = true;
  Vec3 lo, hi;  // the triangles' box grown by depth + cap
  double value(const Vec3& p, double cap) const {
    if (p.x < lo.x || p.y < lo.y || p.z < lo.z || p.x > hi.x || p.y > hi.y || p.z > hi.z)
      return cap;
    double v = dist->unsigned_distance(p) - depth;
    for (const RegionCut& c : cuts) {
      const double nn = std::sqrt(c.normal.x * c.normal.x + c.normal.y * c.normal.y +
                                  c.normal.z * c.normal.z);
      if (!(nn > 0.0)) continue;
      v = std::max(v, -((p.x - c.point.x) * c.normal.x + (p.y - c.point.y) * c.normal.y +
                        (p.z - c.point.z) * c.normal.z) / nn);
    }
    return std::min(v, cap);
  }
};

// The bodies of `sets`, each from the 0.01 mm copy of its faces when it holds
// whole faces and the copy exists (ledger I-02), else from the coarse triangles.
std::vector<FrozenBody> make_frozen_bodies(const std::vector<FrozenFaceSet>& sets,
                                           const StepModel& model, double cap) {
  std::vector<FrozenBody> out;
  // Coarse triangle count per face, to tell whole faces from parts of faces.
  std::vector<int> per_face;
  for (int f : model.triangle_face) {
    if (f >= static_cast<int>(per_face.size())) per_face.resize(static_cast<std::size_t>(f) + 1, 0);
    if (f >= 0) ++per_face[static_cast<std::size_t>(f)];
  }
  const bool fine = !model.export_mesh.empty() &&
                    model.export_triangle_face.size() == model.export_mesh.triangles.size();
  for (const FrozenFaceSet& fs : sets) {
    if (fs.triangles.empty() || !(fs.depth_mm > 0.0)) continue;
    FrozenBody b;
    b.cuts = fs.cuts;
    b.depth = fs.depth_mm;
    b.solid = fs.solid;
    std::map<int, int> count;  // face -> triangles of it in the set
    for (int t : fs.triangles)
      if (t >= 0 && t < static_cast<int>(model.triangle_face.size()))
        ++count[model.triangle_face[static_cast<std::size_t>(t)]];
    bool whole = fine;
    for (const auto& kv : count)
      if (kv.first < 0 || kv.second != per_face[static_cast<std::size_t>(kv.first)]) whole = false;
    const TriangleMesh& src = whole ? model.export_mesh : model.mesh;
    std::vector<int> pick;
    if (whole) {
      for (std::size_t t = 0; t < model.export_triangle_face.size(); ++t)
        if (count.count(model.export_triangle_face[t])) pick.push_back(static_cast<int>(t));
    } else {
      pick = fs.triangles;
    }
    std::map<int, int> remap;
    for (int t : pick) {
      if (t < 0 || t >= static_cast<int>(src.triangles.size())) continue;
      std::array<int, 3> tri{};
      for (int c = 0; c < 3; ++c) {
        const int vi = src.triangles[static_cast<std::size_t>(t)][c];
        auto it = remap.find(vi);
        if (it == remap.end()) {
          it = remap.emplace(vi, static_cast<int>(b.tri.vertices.size())).first;
          b.tri.vertices.push_back(src.vertices[static_cast<std::size_t>(vi)]);
        }
        tri[c] = it->second;
      }
      b.tri.triangles.push_back(tri);
    }
    if (b.tri.triangles.empty()) continue;
    bounding_box(b.tri, b.lo, b.hi);
    const double g = b.depth + cap;
    b.lo = Vec3{b.lo.x - g, b.lo.y - g, b.lo.z - g};
    b.hi = Vec3{b.hi.x + g, b.hi.y + g, b.hi.z + g};
    out.push_back(std::move(b));
    out.back().dist = std::make_unique<MeshDistance>(out.back().tri);
  }
  return out;
}
}  // namespace

TriangleMesh function_surface_mesh(const MinimizePlasticVariant& v, const VoxelGrid& sg,
                                   const TriangleMesh& part, int smooth_factor,
                                   double printed_iso, std::string* why,
                                   FunctionSurfaceReport* rep,
                                   const std::vector<FrozenFaceSet>* frozen,
                                   const StepModel* model) {
  FunctionSurfaceReport local;
  FunctionSurfaceReport& R = rep ? *rep : local;
  R = FunctionSurfaceReport{};
  auto fail = [&](const char* w) {
    if (why) *why = w;
    return TriangleMesh{};
  };
  const std::size_t n = sg.voxel_count();
  const std::vector<double>& rho = v.optimization.physical_density;
  if (v.plsm_alpha.empty()) return fail("the version has no analytic design");
  if (part.triangles.empty()) return fail("there is no drawn part");
  if (rho.size() != n) return fail("the density does not match the grid");
  const int nx = sg.nx, ny = sg.ny, nz = sg.nz;
  const double h = sg.spacing;
  const Vec3 o = sg.origin;
  const Vec3 top{o.x + nx * h, o.y + ny * h, o.z + nz * h};
  {  // A design-box run prints outside the drawn part: not this path (yet).
    Vec3 lo, hi;
    bounding_box(part, lo, hi);
    if (lo.x > o.x + 2 * h || lo.y > o.y + 2 * h || lo.z > o.z + 2 * h ||
        hi.x < top.x - 2 * h || hi.y < top.y - 2 * h || hi.z < top.z - 2 * h)
      return fail("a design-box run (the grid is larger than the drawn part)");
  }
  const PlsmKnotLattice& L = v.plsm_lattice;
  const PlsmBasisKind B = v.plsm_basis_kind;
  const std::vector<double>& alpha = v.plsm_alpha;
  auto phi_vox = [&](double x, double y, double z) {  // voxel coordinates
    return plsm_value_grad(L, B, alpha, x, y, z, nullptr);
  };

  // 0) The frozen bodies the run declared as drawn-face geometry, by true distance.
  const double cap = 2.0 * h;
  std::vector<FrozenBody> bodies;
  if (frozen != nullptr && model != nullptr && !frozen->empty())
    bodies = make_frozen_bodies(*frozen, *model, cap);
  R.frozen_sets = static_cast<int>(bodies.size());
  auto frozen_solid = [&](const Vec3& p) {
    double f = cap;
    for (const FrozenBody& b : bodies)
      if (b.solid) f = std::min(f, b.value(p, cap));
    return f;
  };
  auto frozen_void = [&](const Vec3& p) {
    double f = cap;
    for (const FrozenBody& b : bodies)
      if (!b.solid) f = std::min(f, b.value(p, cap));
    return f;
  };
  bool any_solid_body = false, any_void_body = false;
  for (const FrozenBody& b : bodies) (b.solid ? any_solid_body : any_void_body) = true;

  // 1) The stamped voxels the function does not explain, sample for sample on the
  //    optimiser's own sub-cell lattice (plsm_frac.hpp: x = i + (p + 0.5)/k - 0.5).
  //    A cell is stamped solid when its density is 1 and some sample of phi is not
  //    solid; stamped void when its density is the floor and some sample is solid.
  const int k = v.plsm_frac_samples > 0 ? v.plsm_frac_samples : 4;
  double rho_lo = 1.0;
  for (std::size_t c = 0; c < n; ++c)
    if (sg.tags[c] != VoxelTag::Empty) rho_lo = std::min(rho_lo, rho[c]);
  std::vector<char> st_solid(n, 0), st_void(n, 0);
  for (int kz = 0; kz < nz; ++kz)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        const std::size_t c = (static_cast<std::size_t>(kz) * ny + j) * nx + i;
        if (sg.tags[c] == VoxelTag::Empty) continue;
        const bool full = rho[c] >= 1.0 - 1e-9;
        const bool none = rho[c] <= rho_lo + 1e-12 && rho_lo < 0.5;
        if (!full && !none) continue;
        // A voxel a declared frozen body holds (its centre inside the body, the
        // rule the mask was made by) is that body's, by true distance, not a stamp.
        if (any_solid_body && full && frozen_solid(sg.voxel_center(i, j, kz)) <= 0.0) continue;
        if (any_void_body && none && frozen_void(sg.voxel_center(i, j, kz)) <= 0.0) continue;
        // The first sample that contradicts the stamp decides; most cells read all.
        bool stamped = false;
        for (int r = 0; r < k && !stamped; ++r)
          for (int q = 0; q < k && !stamped; ++q)
            for (int p = 0; p < k && !stamped; ++p) {
              const bool solid = phi_vox(i + (p + 0.5) / k - 0.5, j + (q + 0.5) / k - 0.5,
                                         kz + (r + 0.5) / k - 0.5) < 0.0;
              stamped = full ? !solid : solid;
            }
        if (stamped) (full ? st_solid : st_void)[c] = 1;
      }
  // A stamped-solid region on the drawn surface reaches two voxels past it, so the
  // cut by the drawn part, not the voxel, makes that face.
  for (int pass = 0; pass < 2; ++pass) {
    std::vector<char> grow = st_solid;
    for (int kz = 0; kz < nz; ++kz)
      for (int j = 0; j < ny; ++j)
        for (int i = 0; i < nx; ++i) {
          const std::size_t c = (static_cast<std::size_t>(kz) * ny + j) * nx + i;
          if (st_solid[c] || sg.tags[c] != VoxelTag::Empty) continue;
          const int d[6][3] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}};
          for (const auto& e : d) {
            const int a = i + e[0], b = j + e[1], cc = kz + e[2];
            if (a < 0 || b < 0 || cc < 0 || a >= nx || b >= ny || cc >= nz) continue;
            if (st_solid[(static_cast<std::size_t>(cc) * ny + b) * nx + a]) { grow[c] = 1; break; }
          }
        }
    st_solid.swap(grow);
  }
  std::vector<double> sdS, sdV;
  auto build_sd = [&](const std::vector<char>& m, std::vector<double>& sd) {
    sd.assign(n, 0.0);
    long long cnt = 0;
    for (std::size_t c = 0; c < n; ++c) {
      sd[c] = m[c] ? -0.5 * h : 0.5 * h;
      cnt += m[c];
    }
    if (cnt > 0) plsm_reinitialise(nx, ny, nz, sd, h, 2, false);
    return cnt;
  };
  R.stamped_solid = build_sd(st_solid, sdS);
  R.stamped_void = build_sd(st_void, sdV);
  auto trilinear = [&](const std::vector<double>& f, double x, double y, double z) {
    // x, y, z in voxel coordinates (centres at integers); clamped at the border.
    auto cl = [](double u, int m) { return std::min(std::max(u, 0.0), static_cast<double>(m - 1)); };
    x = cl(x, nx); y = cl(y, ny); z = cl(z, nz);
    const int i0 = std::min(static_cast<int>(x), nx - 2 < 0 ? 0 : nx - 2);
    const int j0 = std::min(static_cast<int>(y), ny - 2 < 0 ? 0 : ny - 2);
    const int k0 = std::min(static_cast<int>(z), nz - 2 < 0 ? 0 : nz - 2);
    const int i1 = std::min(i0 + 1, nx - 1), j1 = std::min(j0 + 1, ny - 1), k1 = std::min(k0 + 1, nz - 1);
    const double fx = x - i0, fy = y - j0, fz = z - k0;
    auto F = [&](int a, int b, int c) { return f[(static_cast<std::size_t>(c) * ny + b) * nx + a]; };
    const double c00 = F(i0, j0, k0) * (1 - fx) + F(i1, j0, k0) * fx;
    const double c10 = F(i0, j1, k0) * (1 - fx) + F(i1, j1, k0) * fx;
    const double c01 = F(i0, j0, k1) * (1 - fx) + F(i1, j0, k1) * fx;
    const double c11 = F(i0, j1, k1) * (1 - fx) + F(i1, j1, k1) * fx;
    return (c00 * (1 - fy) + c10 * fy) * (1 - fz) + (c01 * (1 - fy) + c11 * fy) * fz;
  };
  auto field = [&](const Vec3& p) {
    const double x = (p.x - o.x) / h - 0.5, y = (p.y - o.y) / h - 0.5, z = (p.z - o.z) / h - 0.5;
    double f = phi_vox(x, y, z);
    if (R.stamped_solid > 0) f = std::min(f, trilinear(sdS, x, y, z));
    // Far from zero the exact value never decides the surface: skip the distance
    // queries there.
    if (any_solid_body && f > -cap) f = std::min(f, frozen_solid(p));
    if (R.stamped_void > 0) f = std::max(f, -trilinear(sdV, x, y, z));
    if (any_void_body && f < cap) f = std::max(f, -frozen_void(p));
    return f;
  };

  // 2) Mesh the zero surface, one voxel past the grid on every side so the drawn
  //    part, not the box, closes it.
  const double cell = h / static_cast<double>(std::max(1, smooth_factor));
  LevelSurfaceStats ls;
  const TriangleMesh S = mesh_level_surface(field, Vec3{o.x - h, o.y - h, o.z - h},
                                            Vec3{top.x + h, top.y + h, top.z + h}, cell,
                                            1e-3, &ls);
  R.evaluations = ls.evaluations;
  R.mesh_s = ls.seconds;
  if (S.triangles.empty()) return fail(ls.used_manifold ? "the function has no solid"
                                                        : "this build has no Manifold");
  // The slope of phi at the surface (the band rule 4 of the stage asks for).
  {
    std::vector<double> sl;
    sl.reserve(S.vertices.size());
    for (std::size_t q = 0; q < S.vertices.size(); q += 7) {
      const Vec3& p = S.vertices[q];
      double g[3];
      (void)plsm_value_grad(L, B, alpha, (p.x - o.x) / h - 0.5, (p.y - o.y) / h - 0.5,
                            (p.z - o.z) / h - 0.5, g);
      sl.push_back(std::sqrt(g[0] * g[0] + g[1] * g[1] + g[2] * g[2]) / h);
    }
    if (!sl.empty()) {
      std::sort(sl.begin(), sl.end());
      R.slope_min = sl.front();
      R.slope_median = sl[sl.size() / 2];
      R.slope_max = sl.back();
    }
  }
  // 3) Cut by the drawn part: the drawn faces come from the part itself.
  const auto t1 = std::chrono::steady_clock::now();
  std::string w;
  TriangleMesh cut = mesh_intersection(S, part, &w);
  R.cut_s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t1).count();
  if (cut.triangles.empty()) {
    if (why) *why = w.empty() ? "nothing of the design lies inside the drawn part" : w;
    return {};
  }
  // 4) Only the bodies that carry a load or an anchor, as the voxel export keeps.
  BodyShells shells = carrying_body_shells(cut, sg, printed_bodies(sg, rho, printed_iso));
  if (std::getenv("TOPOPT_SURFACE_DEBUG") != nullptr) {
    auto say = [](const char* what, const TriangleMesh& m) {
      const WrittenAudit a = audit_as_written(m);
      const WatertightReport w = check_watertight(m);
      std::fprintf(stderr, "[surface debug] %s: %zu tris; as written: open %d, 3+ %d, point %d, "
                   "bodies %d; in double: open %zu, 3+ %zu\n", what, m.triangles.size(),
                   a.boundary_edges, a.non_manifold_edges, a.non_manifold_vertices, a.bodies,
                   static_cast<std::size_t>(w.boundary_edges), static_cast<std::size_t>(w.non_manifold_edges));
    };
    say("level set", S);
    say("cut by part", cut);
    say("carrying shells", shells.mesh);
    const std::string dir = std::getenv("TOPOPT_SURFACE_DEBUG");
    if (dir.size() > 1) {
      static int seq = 0;
      write_stl_file(dir + "/cut_" + std::to_string(seq++) + ".stl", cut);
    }
  }
  // 5) As written: the file stores float corners, and an exact cut can leave a
  //    sliver whose corners meet in float. Welded the way the finished file is.
  TriangleMesh out = weld_as_written(shells.mesh);
  R.triangles = static_cast<long long>(out.triangles.size());
  return out;
}

}  // namespace topopt
