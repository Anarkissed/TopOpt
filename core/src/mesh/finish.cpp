#include "topopt/finish.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <map>
#include <unordered_map>

#include "topopt/cad_project.hpp"
#include "topopt/surface_operator.hpp"

namespace topopt {
namespace {

Vec3 add(const Vec3& a, const Vec3& b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
Vec3 sub(const Vec3& a, const Vec3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
Vec3 mul(const Vec3& a, double s) { return {a.x * s, a.y * s, a.z * s}; }
double dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
Vec3 cross(const Vec3& a, const Vec3& b) {
  return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}
double len(const Vec3& a) { return std::sqrt(dot(a, a)); }

// Closest point on triangle abc to p (Ericson, Real-Time Collision Detection 5.1.5).
Vec3 closest_on_triangle(const Vec3& p, const Vec3& a, const Vec3& b, const Vec3& c) {
  const Vec3 ab = sub(b, a), ac = sub(c, a), ap = sub(p, a);
  const double d1 = dot(ab, ap), d2 = dot(ac, ap);
  if (d1 <= 0.0 && d2 <= 0.0) return a;
  const Vec3 bp = sub(p, b);
  const double d3 = dot(ab, bp), d4 = dot(ac, bp);
  if (d3 >= 0.0 && d4 <= d3) return b;
  const double vc = d1 * d4 - d3 * d2;
  if (vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0) return add(a, mul(ab, d1 / (d1 - d3)));
  const Vec3 cp = sub(p, c);
  const double d5 = dot(ab, cp), d6 = dot(ac, cp);
  if (d6 >= 0.0 && d5 <= d6) return c;
  const double vb = d5 * d2 - d1 * d6;
  if (vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0) return add(a, mul(ac, d2 / (d2 - d6)));
  const double va = d3 * d6 - d5 * d4;
  if (va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0)
    return add(b, mul(sub(c, b), (d4 - d3) / ((d4 - d3) + (d5 - d6))));
  const double den = 1.0 / (va + vb + vc);
  return add(a, add(mul(ab, vb * den), mul(ac, vc * den)));
}

// A uniform hash of triangle bounding boxes, cell `h`.
struct TriGrid {
  double h = 1.0;
  std::unordered_map<long long, std::vector<int>> cells;
  static long long key(long long i, long long j, long long k) {
    return (i * 73856093LL) ^ (j * 19349663LL) ^ (k * 83492791LL);
  }
  long long cell(double v) const { return static_cast<long long>(std::floor(v / h)); }
  void build(const TriangleMesh& m, double cell_mm) {
    h = cell_mm;
    cells.clear();
    for (std::size_t t = 0; t < m.triangles.size(); ++t) {
      const auto& tr = m.triangles[t];
      Vec3 lo = m.vertices[static_cast<std::size_t>(tr[0])], hi = lo;
      for (int c = 1; c < 3; ++c) {
        const Vec3& v = m.vertices[static_cast<std::size_t>(tr[c])];
        lo = {std::min(lo.x, v.x), std::min(lo.y, v.y), std::min(lo.z, v.z)};
        hi = {std::max(hi.x, v.x), std::max(hi.y, v.y), std::max(hi.z, v.z)};
      }
      for (long long i = cell(lo.x); i <= cell(hi.x); ++i)
        for (long long j = cell(lo.y); j <= cell(hi.y); ++j)
          for (long long k = cell(lo.z); k <= cell(hi.z); ++k)
            cells[key(i, j, k)].push_back(static_cast<int>(t));
    }
  }
};

std::vector<Vec3> face_normals(const TriangleMesh& m) {
  std::vector<Vec3> n(m.triangles.size());
  for (std::size_t t = 0; t < m.triangles.size(); ++t) {
    const auto& tr = m.triangles[t];
    const Vec3& a = m.vertices[static_cast<std::size_t>(tr[0])];
    const Vec3 c = cross(sub(m.vertices[static_cast<std::size_t>(tr[1])], a),
                         sub(m.vertices[static_cast<std::size_t>(tr[2])], a));
    const double l = len(c);
    n[t] = l > 0.0 ? mul(c, 1.0 / l) : Vec3{0.0, 0.0, 0.0};
  }
  return n;
}

// The largest ball tangent at p (inside, normal n) that holds no opposing facet:
// shrink from cap_mm / 2, each time to the ball through p and the closest opposing
// point inside it. Returns its diameter (cap_mm when nothing opposes).
double thickness_at(const TriangleMesh& m, const TriGrid& g, const std::vector<Vec3>& fn,
                    const Vec3& p, const Vec3& n, double cap_mm, int* limit = nullptr) {
  double r = 0.5 * cap_mm;
  if (limit) *limit = -1;
  for (int it = 0; it < 40 && r > 1e-6; ++it) {
    const Vec3 c = sub(p, mul(n, r));
    double best = r * (1.0 - 1e-9);
    Vec3 q{0.0, 0.0, 0.0};
    bool found = false;
    for (long long i = g.cell(c.x - r); i <= g.cell(c.x + r); ++i)
      for (long long j = g.cell(c.y - r); j <= g.cell(c.y + r); ++j)
        for (long long k = g.cell(c.z - r); k <= g.cell(c.z + r); ++k) {
          const auto f = g.cells.find(TriGrid::key(i, j, k));
          if (f == g.cells.end()) continue;
          for (const int t : f->second) {
            if (dot(fn[static_cast<std::size_t>(t)], n) > -0.866) continue;  // not opposing
            const auto& tr = m.triangles[static_cast<std::size_t>(t)];
            const Vec3 cp = closest_on_triangle(c, m.vertices[static_cast<std::size_t>(tr[0])],
                                                m.vertices[static_cast<std::size_t>(tr[1])],
                                                m.vertices[static_cast<std::size_t>(tr[2])]);
            const double d = len(sub(cp, c));
            if (d < best) {
              best = d;
              q = cp;
              found = true;
              if (limit) *limit = t;
            }
          }
        }
    if (!found) break;
    const Vec3 pq = sub(p, q);
    const double along = dot(pq, n);
    if (!(along > 1e-12)) break;
    const double r2 = dot(pq, pq) / (2.0 * along);
    if (!(r2 < r)) break;
    r = r2;
  }
  return std::min(2.0 * r, cap_mm);
}

// The solve-grid voxel of a point, or -1 outside.
long long voxel_of(const VoxelGrid& g, const Vec3& p) {
  const double h = g.spacing;
  const int i = static_cast<int>(std::floor((p.x - g.origin.x) / h));
  const int j = static_cast<int>(std::floor((p.y - g.origin.y) / h));
  const int k = static_cast<int>(std::floor((p.z - g.origin.z) / h));
  if (i < 0 || j < 0 || k < 0 || i >= g.nx || j >= g.ny || k >= g.nz) return -1;
  return static_cast<long long>(g.index(i, j, k));
}

// The context's own pins: CAD faces (attributed or on a CAD edge) and keep regions.
std::vector<char> context_pins(const TriangleMesh& m, const FinishContext& ctx) {
  std::vector<char> pin(m.vertices.size(), 0);
  if (ctx.cad != nullptr && !ctx.cad->faces.empty() && ctx.cad_spacing_mm > 0.0) {
    CadProjectOptions po = cad_project_options_for_grid(ctx.cad_spacing_mm);
    po.enabled = true;
    const CadAttribution att = attribute_to_cad_faces(m, *ctx.cad, po);
    for (std::size_t v = 0; v < pin.size(); ++v)
      if ((v < att.face_of_vertex.size() && att.face_of_vertex[v] >= 0) || att.ambiguous_at(v))
        pin[v] = 1;
  }
  // Inside a keep region, AND on its boundary: the exact-Protect boolean cuts the
  // voxel surface there (the part side reaches 0.05 mm past it, keep_regions_exact's
  // fuse), leaving needles along the cut up to 17 mm long and 0.06 mm wide (his
  // 6d9b535f, a Protect box's edge) that any move turns over. They are the seam of the
  // exact geometry and stay where the boolean put them.
  if (ctx.keeps != nullptr) {
    constexpr double kSeam = 0.1;  // mm
    std::vector<KeepRegion> grown = *ctx.keeps;
    for (KeepRegion& k : grown) {
      k.min = {k.min.x - kSeam, k.min.y - kSeam, k.min.z - kSeam};
      k.max = {k.max.x + kSeam, k.max.y + kSeam, k.max.z + kSeam};
      k.half = {k.half.x + kSeam, k.half.y + kSeam, k.half.z + kSeam};
    }
    for (std::size_t v = 0; v < pin.size(); ++v)
      for (const KeepRegion& k : grown)
        if (k.contains(m.vertices[v])) { pin[v] = 1; break; }
  }
  return pin;
}

// Why a vertex may not move to `to` ("" = it may).
std::string blocked_reason(const FinishContext& ctx, const Vec3& to) {
  if (ctx.keeps != nullptr)
    for (const KeepRegion& k : *ctx.keeps)
      if (k.contains(to)) return "blocked by a Protected face";
  if (ctx.grid != nullptr) {
    const long long v = voxel_of(*ctx.grid, to);
    if (ctx.forbidden != nullptr && !ctx.forbidden->empty() && v >= 0 &&
        (*ctx.forbidden)[static_cast<std::size_t>(v)] == MaskValue::FrozenVoid)
      return "blocked by a Keep clear";
    if (!ctx.growth && ctx.part_solid != nullptr && !ctx.part_solid->empty() &&
        (v < 0 || !(*ctx.part_solid)[static_cast<std::size_t>(v)]))
      return "would grow outside your part";
  }
  if (ctx.growth && ctx.has_box &&
      (to.x < ctx.box.min.x || to.x > ctx.box.max.x || to.y < ctx.box.min.y ||
       to.y > ctx.box.max.y || to.z < ctx.box.min.z || to.z > ctx.box.max.z))
    return "at the edge of the design box";
  return "";
}

std::vector<std::vector<int>> vertex_neighbours(const TriangleMesh& m) {
  std::vector<std::vector<int>> nb(m.vertices.size());
  for (const auto& t : m.triangles)
    for (int e = 0; e < 3; ++e) {
      nb[static_cast<std::size_t>(t[e])].push_back(t[(e + 1) % 3]);
      nb[static_cast<std::size_t>(t[(e + 1) % 3])].push_back(t[e]);
    }
  for (auto& v : nb) {
    std::sort(v.begin(), v.end());
    v.erase(std::unique(v.begin(), v.end()), v.end());
  }
  return nb;
}

}  // namespace

namespace {
// The thickness at each vertex along the given normals (the mesh's own when null), and
// the facet that limits each ball (-1: none within the cap).
std::vector<double> thickness_along(const TriangleMesh& mesh, double cap_mm,
                                    const std::vector<Vec3>* normals, std::vector<int>* limit) {
  std::vector<double> t(mesh.vertices.size(), cap_mm);
  if (limit) limit->assign(mesh.vertices.size(), -1);
  if (mesh.empty() || !(cap_mm > 0.0)) return t;
  TriGrid g;
  g.build(mesh, cap_mm);
  const std::vector<Vec3> fn = face_normals(mesh);
  const std::vector<Vec3> own = normals ? std::vector<Vec3>{} : vertex_normals(mesh);
  const std::vector<Vec3>& vn = normals ? *normals : own;
  for (std::size_t v = 0; v < t.size() && v < vn.size(); ++v)
    if (len(vn[v]) > 0.5)
      t[v] = thickness_at(mesh, g, fn, mesh.vertices[v], vn[v], cap_mm,
                          limit ? &(*limit)[v] : nullptr);
  return t;
}
}  // namespace

std::vector<double> vertex_local_thickness_mm(const TriangleMesh& mesh, double cap_mm) {
  return thickness_along(mesh, cap_mm, nullptr, nullptr);
}

std::vector<double> vertex_local_thickness_mm(const TriangleMesh& mesh, double cap_mm,
                                              const TriangleMesh& normals_from) {
  if (normals_from.vertices.size() != mesh.vertices.size())
    return thickness_along(mesh, cap_mm, nullptr, nullptr);
  const std::vector<Vec3> n = vertex_normals(normals_from);
  return thickness_along(mesh, cap_mm, &n, nullptr);
}

TriangleMesh thin_spot_cleanup(const TriangleMesh& mesh, const FinishContext& ctx,
                               const std::vector<char>& pinned_in, FinishReport* report,
                               std::vector<char>* moved_out) {
  TriangleMesh m = mesh;
  const std::size_t nv = m.vertices.size();
  if (moved_out) moved_out->assign(nv, 0);
  const double tmin = ctx.min_thickness_mm;
  if (!(tmin > 0.0) || m.empty()) return m;
  // The context's pins (CAD faces, keep regions) unless the caller already has them.
  std::vector<char> pinned = pinned_in.size() == nv ? pinned_in : context_pins(m, ctx);
  const double ok = tmin * (1.0 - 1e-3);
  std::vector<double> t = vertex_local_thickness_mm(m, tmin);
  // Thin spots on the optimizer's CUT surfaces only: a vertex on a CAD face or in a
  // keep region is the part as drawn (a thin wall he drew is his), and a thin
  // member that meets a CAD face is still found through its cut side.
  std::vector<int> thin;
  for (std::size_t v = 0; v < nv; ++v)
    if (t[v] < ok && !pinned[v]) thin.push_back(static_cast<int>(v));
  if (thin.empty()) return m;
  const std::vector<double> before = t;
  std::vector<std::string> why(nv);
  for (int pass = 0; pass < kFinishThinPasses; ++pass) {
    const std::vector<Vec3> vn = vertex_normals(m);
    bool any = false;
    for (const int vi : thin) {
      const std::size_t v = static_cast<std::size_t>(vi);
      if (t[v] >= ok || !why[v].empty()) continue;
      const double delta = 0.51 * (tmin - t[v]);
      const Vec3 to = add(m.vertices[v], mul(vn[v], delta));
      const std::string r = blocked_reason(ctx, to);
      if (!r.empty()) { why[v] = r; continue; }
      m.vertices[v] = to;
      if (moved_out) (*moved_out)[v] = 1;
      any = true;
    }
    if (!any) break;
    // Re-measure the thin vertices on the moved shape.
    TriGrid g;
    g.build(m, tmin);
    const std::vector<Vec3> fn = face_normals(m), vn2 = vertex_normals(m);
    for (const int vi : thin) {
      const std::size_t v = static_cast<std::size_t>(vi);
      if (len(vn2[v]) > 0.5) t[v] = thickness_at(m, g, fn, m.vertices[v], vn2[v], tmin);
    }
  }
  if (report) {
    // Places: the thin vertices joined along mesh edges.
    const auto nb = vertex_neighbours(m);
    std::vector<char> is_thin(nv, 0);
    for (const int v : thin) is_thin[static_cast<std::size_t>(v)] = 1;
    std::vector<int> comp(nv, -1);
    int nc = 0;
    for (const int seed : thin) {
      if (comp[static_cast<std::size_t>(seed)] >= 0) continue;
      std::vector<int> stack{seed};
      comp[static_cast<std::size_t>(seed)] = nc;
      Vec3 sum{0.0, 0.0, 0.0};
      int count = 0;
      double b = tmin, a = tmin;
      std::map<std::string, int> reasons;
      while (!stack.empty()) {
        const std::size_t v = static_cast<std::size_t>(stack.back());
        stack.pop_back();
        sum = add(sum, mesh.vertices[v]);
        ++count;
        b = std::min(b, before[v]);
        a = std::min(a, t[v]);
        if (t[v] < ok) ++reasons[why[v].empty() ? "too tight to thicken" : why[v]];
        for (const int w : nb[v])
          if (is_thin[static_cast<std::size_t>(w)] && comp[static_cast<std::size_t>(w)] < 0) {
            comp[static_cast<std::size_t>(w)] = nc;
            stack.push_back(w);
          }
      }
      ThinSpot s;
      s.centre_mm = mul(sum, 1.0 / count);
      s.before_mm = b;
      if (a >= tmin * 0.98) {
        s.after_mm = a;
        report->fixed.push_back(s);
      } else {
        s.after_mm = a;
        int most = -1;
        for (const auto& kv : reasons)
          if (kv.second > most) { most = kv.second; s.reason = kv.first; }
        report->left.push_back(s);
      }
      ++nc;
    }
  }
  return m;
}

TriangleMesh surface_finish(const TriangleMesh& mesh, const FinishContext& ctx,
                            const std::vector<char>& pinned_in,
                            const std::vector<char>& outward_only, FinishReport* report) {
  if (!(ctx.cell_mm > 0.0) || mesh.empty() || ctx.mcf_steps <= 0) return mesh;
  const std::size_t nv = mesh.vertices.size();
  std::vector<char> pinned = pinned_in.size() == nv ? pinned_in : context_pins(mesh, ctx);
  std::vector<TrustSign> sign(nv, TrustSign::Both);
  if (ctx.grid != nullptr && ctx.density != nullptr &&
      ctx.density->size() == ctx.grid->voxel_count()) {
    TrustSignPolicy pol;
    pol.has_design_box = ctx.growth && ctx.has_box;
    pol.box_min = ctx.box.min;
    pol.box_max = ctx.box.max;
    if (ctx.slim_line_mm > 0.0) pol.thin_section_mm = ctx.slim_line_mm;  // slim: 2 x printable min
    sign = classify_trust_sign(mesh, *ctx.grid, *ctx.density, pol);
  }
  auto combine = [](TrustSign a, TrustSign b) {
    if (a == TrustSign::Both) return b;
    if (b == TrustSign::Both || a == b) return a;
    return TrustSign::Pinned;
  };
  for (std::size_t v = 0; v < nv; ++v) {
    if (pinned[v]) { sign[v] = TrustSign::Pinned; continue; }
    if (v < outward_only.size() && outward_only[v]) sign[v] = combine(sign[v], TrustSign::OutwardOnly);
    if (ctx.grid != nullptr && ctx.forbidden != nullptr && !ctx.forbidden->empty()) {
      // At or next to a Keep clear / Protect's reach: never further out.
      const Vec3& p = mesh.vertices[v];
      const double s = 0.5 * ctx.cell_mm;
      for (int c = 0; c < 8; ++c) {
        const Vec3 q{p.x + ((c & 1) ? s : -s), p.y + ((c & 2) ? s : -s), p.z + ((c & 4) ? s : -s)};
        const long long vx = voxel_of(*ctx.grid, q);
        if (vx >= 0 && (*ctx.forbidden)[static_cast<std::size_t>(vx)] == MaskValue::FrozenVoid) {
          sign[v] = combine(sign[v], TrustSign::InwardOnly);
          break;
        }
      }
    }
  }
  // THE SEAM: a free vertex next to a pinned one sits on a crease (a cut surface
  // meeting a CAD face or a keep region), where its normal is the average of the two
  // and a move along it crosses the small pinned-side triangle beside it (his
  // 6d9b535f: ~1,100 triangles turned over). It is held with the pins; the stair-step
  // measure below already leaves the seam out.
  const auto nb = vertex_neighbours(mesh);
  {
    std::vector<char> seam(nv, 0);
    for (std::size_t v = 0; v < nv; ++v)
      if (sign[v] != TrustSign::Pinned)
        for (const int w : nb[v])
          if (pinned[static_cast<std::size_t>(w)]) { seam[v] = 1; break; }
    for (std::size_t v = 0; v < nv; ++v)
      if (seam[v]) sign[v] = TrustSign::Pinned;
  }
  // SLIM: below the line on the mesh itself (the voxel thickness above cannot see a
  // member thinner than a voxel), outward-only.
  const bool slim = ctx.slim_line_mm > 0.0;
  const double line = ctx.slim_line_mm, under = line * (1.0 - 1e-3);
  std::vector<double> t0;
  std::size_t guarded = 0;
  if (slim) {
    t0 = vertex_local_thickness_mm(mesh, line);
    for (std::size_t v = 0; v < nv; ++v)
      if (t0[v] < under && sign[v] != TrustSign::Pinned && sign[v] != TrustSign::OutwardOnly) {
        sign[v] = combine(sign[v], TrustSign::OutwardOnly);
        ++guarded;
      }
  }
  SurfaceConstraints k;
  k.cell_mm = ctx.cell_mm;
  k.trust_voxels = 0.5;
  k.sign = sign;
  k.c2_hold = true;  // a one-sided vertex never slides (surface_operator.hpp)
  k.preserve_volume = true;
  MeanCurvatureParams mp;
  mp.steps = ctx.mcf_steps;
  mp.dt_scale = kFinishMcfDtScale;
  // Roughness: the RMS normal offset of each free vertex from its 1-ring mean — the
  // step a staircase leaves, independent of an analytic reference.
  // Measured away from the pins (two rings clear): the seam where a moving surface
  // meets a pinned CAD edge is a kink of its own, not stair-step.
  std::vector<char> near_pin(nv, 0);
  for (std::size_t v = 0; v < nv; ++v)
    if (sign[v] == TrustSign::Pinned) {
      near_pin[v] = 1;
      for (const int w : nb[v]) {
        near_pin[static_cast<std::size_t>(w)] = 1;
        for (const int x : nb[static_cast<std::size_t>(w)]) near_pin[static_cast<std::size_t>(x)] = 1;
      }
    }
  // The stair-step amplitude: the RMS distance of each free vertex from the smooth
  // surface ITS OWN staircase approximates — the surface low-passed by a long Taubin
  // lambda/mu filter (the pins held), along that low-pass's normal. Each shape is
  // measured against its own low-pass, so a uniform offset (the slim flow moves a thin
  // shell's two faces as a whole) is not read as roughness: the input-referenced
  // measure read 0.0 % on a 3.6 mm shell the flow took from 3.8 % to 22.5 % closer to
  // its analytic spheres.
  auto low_pass = [&](const TriangleMesh& in) {
    TriangleMesh ref = in;
    const double lam = 0.33, mu = -0.34;
    std::vector<Vec3> next(nv);
    for (int it = 0; it < kFinishRefIterations; ++it) {
      const double f = (it % 2 == 0) ? lam : mu;
      for (std::size_t v = 0; v < nv; ++v) {
        next[v] = ref.vertices[v];
        if (sign[v] == TrustSign::Pinned || nb[v].empty()) continue;
        Vec3 c{0.0, 0.0, 0.0};
        for (const int w : nb[v]) c = add(c, ref.vertices[static_cast<std::size_t>(w)]);
        c = mul(c, 1.0 / static_cast<double>(nb[v].size()));
        next[v] = add(ref.vertices[v], mul(sub(c, ref.vertices[v]), f));
      }
      ref.vertices.swap(next);
    }
    return ref;
  };
  auto roughness = [&](const TriangleMesh& mm) {
    const TriangleMesh ref = low_pass(mm);
    const std::vector<Vec3> ref_n = vertex_normals(ref);
    double s2 = 0.0;
    std::size_t n = 0;
    for (std::size_t v = 0; v < nv; ++v) {
      if (near_pin[v] || nb[v].empty()) continue;
      const double d = dot(sub(mm.vertices[v], ref.vertices[v]), ref_n[v]);  // normal part only
      s2 += d * d;
      ++n;
    }
    if (report) report->roughness_vertices = n;
    return n > 0 ? std::sqrt(s2 / static_cast<double>(n)) : 0.0;
  };
  const double r0 = roughness(mesh);
  SurfaceOperatorResult res = mean_curvature_flow(mesh, mp, k);
  // THE GUARDS.
  //  - NO FOLD: the flow can turn a triangle over (PR 306's A x20 does it to 164 of the
  //    analytic sphere's 22,460, most over a fifth of a cell across; a 4 mm slab's
  //    rims, 20). The corners of every turned triangle walk back toward where they
  //    started, halving their move, until none is turned (held where they were after
  //    kFoldHalvings). Halving keeps each move inside its box and on its side (C1, C2).
  //  - SLIM's 1.8 mm: a vertex the flow took under the line (and thinner than it was)
  //    turns outward-only, with its ring, and the flow re-runs from the start.
  // A slim finish that cannot keep its line falls back to the safe one.
  const std::vector<Vec3> fn0 = face_normals(mesh);
  std::size_t fold_moved = 0;
  auto unfold = [&](TriangleMesh& out) {
    constexpr int kFoldHalvings = 10;
    std::vector<char> seen(nv, 0);
    for (int h = 0; h <= kFoldHalvings; ++h) {
      const std::vector<Vec3> fn1 = face_normals(out);
      std::vector<std::size_t> corners;
      for (std::size_t t = 0; t < fn0.size(); ++t) {
        if (len(fn0[t]) < 0.5) continue;  // degenerate on the way in
        if (len(fn1[t]) > 0.5 && dot(fn0[t], fn1[t]) > 0.0) continue;
        for (int c = 0; c < 3; ++c) corners.push_back(static_cast<std::size_t>(mesh.triangles[t][c]));
      }
      if (corners.empty()) return;
      std::sort(corners.begin(), corners.end());
      corners.erase(std::unique(corners.begin(), corners.end()), corners.end());
      for (const std::size_t v : corners) {
        if (!seen[v]) { seen[v] = 1; ++fold_moved; }
        out.vertices[v] = h == kFoldHalvings
                              ? mesh.vertices[v]
                              : add(mesh.vertices[v], mul(sub(out.vertices[v], mesh.vertices[v]), 0.5));
      }
    }
  };
  unfold(res.mesh);
  int rounds = 0;
  // Measured along the INPUT's normals, before and after: the flow turns a normal, and
  // a ball along the turned one reads thinner with nothing having moved in.
  const std::vector<Vec3> n_in = slim ? vertex_normals(mesh) : std::vector<Vec3>{};
  for (; slim; ++rounds) {
    std::vector<int> lim;
    const std::vector<double> t1 = thickness_along(res.mesh, line, &n_in, &lim);
    std::size_t changed = 0, bad = 0;
    auto hold = [&](std::size_t v) {
      if (k.sign[v] == TrustSign::Pinned || k.sign[v] == TrustSign::OutwardOnly) return;
      k.sign[v] = combine(k.sign[v], TrustSign::OutwardOnly);
      ++changed;
      ++guarded;
    };
    for (std::size_t v = 0; v < nv; ++v)
      if (t1[v] < under && t1[v] < t0[v] - 1e-6) {
        ++bad;
        hold(v);
        for (const int w : nb[v]) hold(static_cast<std::size_t>(w));
        if (lim[v] >= 0)  // and the far side that came in
          for (int c = 0; c < 3; ++c)
            hold(static_cast<std::size_t>(mesh.triangles[static_cast<std::size_t>(lim[v])][c]));
      }
    if (bad == 0) break;
    if (changed == 0 || rounds + 1 >= kFinishSlimRounds) {
      // It cannot keep every member at its line: the safe finish, said.
      FinishContext safe = ctx;
      safe.slim_line_mm = 0.0;
      TriangleMesh out = surface_finish(mesh, safe, pinned_in, outward_only, report);
      if (report) {
        report->fallback = true;
        char b[160];
        std::snprintf(b, sizeof b, "The slim finish would take a member under %.1f mm", line);
        report->fallback_reason = b;
      }
      return out;
    }
    res = mean_curvature_flow(mesh, mp, k);
    unfold(res.mesh);
  }
  if (report) {
    report->slim = slim;
    report->slim_rounds = rounds;
    report->slim_guarded_vertices = guarded;
    report->fold_held_vertices = fold_moved;
    report->surface_applied = true;
    const double r1 = roughness(res.mesh);
    report->roughness_before_mm = r0;
    report->roughness_after_mm = r1;
    report->stair_step_removed_pct = r0 > 0.0 ? std::max(0.0, 100.0 * (1.0 - r1 / r0)) : 0.0;
    report->pinned_vertices = static_cast<std::size_t>(
        std::count(k.sign.begin(), k.sign.end(), TrustSign::Pinned));
    report->outward_only_vertices = static_cast<std::size_t>(
        std::count(k.sign.begin(), k.sign.end(), TrustSign::OutwardOnly));
  }
  return res.mesh;
}

int positive_volume_bodies(const TriangleMesh& m) {
  const std::size_t nv = m.vertices.size();
  std::vector<int> par(nv);
  for (std::size_t v = 0; v < nv; ++v) par[v] = static_cast<int>(v);
  auto find = [&](int x) {
    while (par[static_cast<std::size_t>(x)] != x)
      x = par[static_cast<std::size_t>(x)] = par[static_cast<std::size_t>(par[static_cast<std::size_t>(x)])];
    return x;
  };
  for (const auto& t : m.triangles) {
    const int a = find(t[0]);
    par[static_cast<std::size_t>(find(t[1]))] = a;
    par[static_cast<std::size_t>(find(t[2]))] = a;
  }
  std::map<int, double> vol;
  for (const auto& t : m.triangles) {
    const Vec3& a = m.vertices[static_cast<std::size_t>(t[0])];
    const Vec3& b = m.vertices[static_cast<std::size_t>(t[1])];
    const Vec3& c = m.vertices[static_cast<std::size_t>(t[2])];
    vol[find(t[0])] += dot(a, cross(b, c)) / 6.0;
  }
  int n = 0;
  for (const auto& kv : vol) n += kv.second > 0.0;
  return n;
}

WrittenAudit audit_as_written(const TriangleMesh& m) {
  WrittenAudit a;
  std::map<std::array<float, 3>, int> at;
  std::vector<int> id(m.vertices.size());
  for (std::size_t v = 0; v < m.vertices.size(); ++v) {
    const std::array<float, 3> k{static_cast<float>(m.vertices[v].x),
                                 static_cast<float>(m.vertices[v].y),
                                 static_cast<float>(m.vertices[v].z)};
    id[v] = at.emplace(k, static_cast<int>(at.size())).first->second;
  }
  const std::size_t nt = m.triangles.size();
  auto corner = [&](std::size_t t, int k) { return id[static_cast<std::size_t>(m.triangles[t][k])]; };
  std::map<std::pair<int, int>, std::vector<int>> uses;
  for (std::size_t t = 0; t < nt; ++t)
    for (int e = 0; e < 3; ++e) {
      const int p = corner(t, e), q = corner(t, (e + 1) % 3);
      uses[{std::min(p, q), std::max(p, q)}].push_back(static_cast<int>(t));
    }
  // Shells: triangles joined through two-triangle edges (a pinch joins nothing).
  // Fans: each triangle corner joined to the same vertex's corner across such an edge;
  // a vertex with corners in more than one fan is where shells touch at a point.
  std::vector<int> tp(nt), cp(3 * nt);
  for (std::size_t t = 0; t < nt; ++t) tp[t] = static_cast<int>(t);
  for (std::size_t c = 0; c < cp.size(); ++c) cp[c] = static_cast<int>(c);
  auto find = [](std::vector<int>& par, int x) {
    while (par[static_cast<std::size_t>(x)] != x)
      x = par[static_cast<std::size_t>(x)] = par[static_cast<std::size_t>(par[static_cast<std::size_t>(x)])];
    return x;
  };
  auto corner_of = [&](int t, int vid) {
    for (int k = 0; k < 3; ++k)
      if (corner(static_cast<std::size_t>(t), k) == vid) return 3 * t + k;
    return 3 * t;
  };
  std::vector<std::array<float, 3>> pos(at.size());
  for (const auto& kv : at) pos[static_cast<std::size_t>(kv.second)] = kv.first;
  for (const auto& kv : uses) {
    if (kv.second.size() == 1) ++a.boundary_edges;
    if (kv.second.size() > 2) {
      ++a.non_manifold_edges;
      if (a.bad_edge_midpoints.size() < 8) {
        const auto& p = pos[static_cast<std::size_t>(kv.first.first)];
        const auto& q = pos[static_cast<std::size_t>(kv.first.second)];
        a.bad_edge_midpoints.push_back({0.5 * (double(p[0]) + q[0]), 0.5 * (double(p[1]) + q[1]),
                                        0.5 * (double(p[2]) + q[2])});
      }
      continue;
    }
    if (kv.second.size() != 2) continue;
    const int t1 = kv.second[0], t2 = kv.second[1];
    tp[static_cast<std::size_t>(find(tp, t1))] = find(tp, t2);
    for (const int vid : {kv.first.first, kv.first.second})
      cp[static_cast<std::size_t>(find(cp, corner_of(t1, vid)))] = find(cp, corner_of(t2, vid));
  }
  std::map<int, double> vol;
  for (std::size_t t = 0; t < nt; ++t) {
    const Vec3& p = m.vertices[static_cast<std::size_t>(m.triangles[t][0])];
    const Vec3& q = m.vertices[static_cast<std::size_t>(m.triangles[t][1])];
    const Vec3& r = m.vertices[static_cast<std::size_t>(m.triangles[t][2])];
    vol[find(tp, static_cast<int>(t))] += dot(p, cross(q, r)) / 6.0;
  }
  a.shells = static_cast<int>(vol.size());
  for (const auto& kv : vol) a.bodies += kv.second > 0.0;
  std::vector<int> fan_of(at.size(), -1);
  std::vector<char> bad(at.size(), 0);
  for (std::size_t c = 0; c < cp.size(); ++c) {
    const std::size_t vid = static_cast<std::size_t>(corner(c / 3, static_cast<int>(c % 3)));
    const int f = find(cp, static_cast<int>(c));
    if (fan_of[vid] < 0) fan_of[vid] = f;
    else if (fan_of[vid] != f && !bad[vid]) { bad[vid] = 1; ++a.non_manifold_vertices; }
  }
  return a;
}

TriangleMesh weld_as_written(const TriangleMesh& m) {
  std::map<std::array<float, 3>, int> first;
  std::vector<int> to(m.vertices.size());
  bool merged = false;
  for (std::size_t v = 0; v < m.vertices.size(); ++v) {
    const std::array<float, 3> k{static_cast<float>(m.vertices[v].x),
                                 static_cast<float>(m.vertices[v].y),
                                 static_cast<float>(m.vertices[v].z)};
    const auto ins = first.emplace(k, static_cast<int>(v));
    to[v] = ins.first->second;
    merged = merged || !ins.second;
  }
  if (!merged) return m;
  std::vector<std::array<int, 3>> tris;
  for (const auto& t : m.triangles) {
    const std::array<int, 3> r{to[static_cast<std::size_t>(t[0])], to[static_cast<std::size_t>(t[1])],
                               to[static_cast<std::size_t>(t[2])]};
    if (r[0] != r[1] && r[1] != r[2] && r[2] != r[0]) tris.push_back(r);  // a collapsed sliver goes
  }
  // A fin: two triangles on the same three vertices, opposite windings. Both go.
  auto rotated = [](std::array<int, 3> t) {
    while (t[0] != std::min({t[0], t[1], t[2]})) t = {t[1], t[2], t[0]};
    return t;
  };
  std::map<std::array<int, 3>, std::vector<std::size_t>> by_set;
  for (std::size_t t = 0; t < tris.size(); ++t) {
    std::array<int, 3> k = tris[t];
    std::sort(k.begin(), k.end());
    by_set[k].push_back(t);
  }
  std::vector<char> gone(tris.size(), 0);
  for (const auto& kv : by_set) {
    const std::vector<std::size_t>& g = kv.second;
    for (std::size_t x = 0; x < g.size(); ++x)
      for (std::size_t y = x + 1; y < g.size(); ++y)
        if (!gone[g[x]] && !gone[g[y]] && rotated(tris[g[x]]) != rotated(tris[g[y]])) {
          gone[g[x]] = gone[g[y]] = 1;
        }
  }
  TriangleMesh out;
  std::vector<int> nid(m.vertices.size(), -1);
  for (std::size_t t = 0; t < tris.size(); ++t) {
    if (gone[t]) continue;
    std::array<int, 3> r{};
    for (int k = 0; k < 3; ++k) {
      int& n = nid[static_cast<std::size_t>(tris[t][k])];
      if (n < 0) {
        n = static_cast<int>(out.vertices.size());
        out.vertices.push_back(m.vertices[static_cast<std::size_t>(tris[t][k])]);
      }
      r[k] = n;
    }
    out.triangles.push_back(r);
  }
  return out;
}

TriangleMesh drop_fragment_shells(const TriangleMesh& mesh, double min_volume_mm3,
                                  int keep_bodies, int* dropped) {
  if (dropped) *dropped = 0;
  const TriangleMesh clean = clean_degenerate_triangles(mesh);
  int n = 0;
  const std::vector<int> root = triangle_component_roots(clean, n);
  if (n <= 1) return mesh;
  std::map<int, double> vol;
  for (std::size_t t = 0; t < clean.triangles.size(); ++t) {
    const Vec3& p = clean.vertices[static_cast<std::size_t>(clean.triangles[t][0])];
    const Vec3& q = clean.vertices[static_cast<std::size_t>(clean.triangles[t][1])];
    const Vec3& r = clean.vertices[static_cast<std::size_t>(clean.triangles[t][2])];
    vol[root[t]] += dot(p, cross(q, r)) / 6.0;
  }
  std::vector<std::pair<double, int>> pos;
  for (const auto& kv : vol)
    if (kv.second > 0.0) pos.push_back({kv.second, kv.first});
  std::sort(pos.begin(), pos.end(), [](const auto& a, const auto& b) {
    return a.first != b.first ? a.first > b.first : a.second < b.second;
  });
  std::vector<char> keep(clean.triangles.size() + 1, 0);
  int gone = 0;
  for (const auto& kv : vol) {
    bool k = std::fabs(kv.second) >= min_volume_mm3;
    for (int b = 0; b < keep_bodies && b < static_cast<int>(pos.size()); ++b)
      k = k || pos[static_cast<std::size_t>(b)].second == kv.first;
    if (static_cast<std::size_t>(kv.first) >= keep.size()) keep.resize(static_cast<std::size_t>(kv.first) + 1, 0);
    keep[static_cast<std::size_t>(kv.first)] = k;
    gone += !k;
  }
  if (dropped) *dropped = gone;
  if (gone == 0) return mesh;
  return rebuild_from_components(clean, root, keep);
}

int file_thin_joints(const VoxelGrid& g, const std::vector<char>& occ) {
  const std::size_t nv = static_cast<std::size_t>(g.nx) * static_cast<std::size_t>(g.ny) *
                         static_cast<std::size_t>(g.nz);
  if (occ.size() != nv) return 0;
  const int nx = g.nx, ny = g.ny, nz = g.nz;
  auto at = [&](int i, int j, int k) {
    return (static_cast<std::size_t>(k) * static_cast<std::size_t>(ny) + static_cast<std::size_t>(j)) *
               static_cast<std::size_t>(nx) + static_cast<std::size_t>(i);
  };
  std::vector<int> label(nv, -1);
  std::vector<std::size_t> queue;
  int id = 0;
  for (std::size_t seed = 0; seed < nv; ++seed) {
    if (!occ[seed] || label[seed] >= 0) continue;
    queue.assign(1, seed);
    label[seed] = id;
    for (std::size_t q = 0; q < queue.size(); ++q) {
      const std::size_t e = queue[q];
      const int i = static_cast<int>(e % static_cast<std::size_t>(nx));
      const int j = static_cast<int>((e / static_cast<std::size_t>(nx)) % static_cast<std::size_t>(ny));
      const int k = static_cast<int>(e / (static_cast<std::size_t>(nx) * static_cast<std::size_t>(ny)));
      const int nb[6][3] = {{i - 1, j, k}, {i + 1, j, k}, {i, j - 1, k},
                            {i, j + 1, k}, {i, j, k - 1}, {i, j, k + 1}};
      for (const auto& c : nb) {
        if (c[0] < 0 || c[0] >= nx || c[1] < 0 || c[1] >= ny || c[2] < 0 || c[2] >= nz) continue;
        const std::size_t f = at(c[0], c[1], c[2]);
        if (occ[f] && label[f] < 0) {
          label[f] = id;
          queue.push_back(f);
        }
      }
    }
    ++id;
  }
  std::vector<std::uint64_t> pairs;
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        const int le = label[at(i, j, k)];
        if (le < 0) continue;
        for (int dz = -1; dz <= 1; ++dz)
          for (int dy = -1; dy <= 1; ++dy)
            for (int dx = -1; dx <= 1; ++dx) {
              if (std::abs(dx) + std::abs(dy) + std::abs(dz) < 2) continue;  // self / face
              const int a = i + dx, b = j + dy, c = k + dz;
              if (a < 0 || a >= nx || b < 0 || b >= ny || c < 0 || c >= nz) continue;
              const int lf = label[at(a, b, c)];
              if (lf < 0 || lf == le) continue;
              pairs.push_back((static_cast<std::uint64_t>(std::min(lf, le)) << 32) |
                              static_cast<std::uint64_t>(std::max(lf, le)));
            }
      }
  std::sort(pairs.begin(), pairs.end());
  return static_cast<int>(std::unique(pairs.begin(), pairs.end()) - pairs.begin());
}

std::string finish_verdict_reason(const FinishRecheck& r) {
  if (!r.ran) return "";
  auto x = [](double v) {
    char b[32];
    std::snprintf(b, sizeof b, "%.2f", v);
    std::string s = b;
    while (s.size() > 1 && s.back() == '0') s.pop_back();
    if (s.back() == '.') s.pop_back();
    return s + "\u00D7";
  };
  if (r.margin < r.margin_required * (1.0 - 1e-12))
    return "After finishing, the margin is " + x(r.margin) + " (needs " + x(r.margin_required) + ")";
  if (r.keep_clear_voxels > 0) return "After finishing, a Keep clear has material in it";
  if (r.pieces > 1) return "After finishing, it prints in " + std::to_string(r.pieces) + " pieces";
  if (r.loose_pieces > 0) return "After finishing, a piece is loose";
  if (r.thin_joints > r.thin_joints_before)
    return "After finishing, a joint holds only along an edge or at a corner";
  return "";
}

TriangleMesh finish_shape(const TriangleMesh& mesh, const FinishContext& ctx,
                          FinishReport* report) {
  const auto t0 = std::chrono::steady_clock::now();
  FinishReport local;
  FinishReport& r = report ? *report : local;
  r = FinishReport{};
  if (!(ctx.min_thickness_mm > 0.0) && !(ctx.cell_mm > 0.0)) return mesh;
  r.ran = true;
  r.min_thickness_mm = ctx.min_thickness_mm;
  r.min_thickness_source = ctx.min_thickness_source;
  r.volume_before_mm3 = signed_volume(mesh);
  const std::vector<char> pins = context_pins(mesh, ctx);  // once: (c) moves no index
  std::vector<char> moved;
  TriangleMesh m = thin_spot_cleanup(mesh, ctx, pins, &r, &moved);
  const TriangleMesh after_c = m;
  m = surface_finish(m, ctx, pins, moved, &r);
  r.volume_after_mm3 = signed_volume(m);
  // Never remove material: the volume restoration of the flow can land a hair under.
  // A uniform outward shift of the free cut vertices that stay in their trust box,
  // sized by the area that can move (a vertex's third of its triangles), iterated.
  for (int it = 0; it < 12 && r.volume_after_mm3 < r.volume_before_mm3 && r.volume_before_mm3 > 0.0;
       ++it) {
    const std::vector<Vec3> vn = vertex_normals(m);
    const double box = 0.5 * ctx.cell_mm;
    std::vector<double> va(m.vertices.size(), 0.0);
    for (const auto& t : m.triangles) {
      const Vec3& a = m.vertices[static_cast<std::size_t>(t[0])];
      const double ar = 0.5 * len(cross(sub(m.vertices[static_cast<std::size_t>(t[1])], a),
                                        sub(m.vertices[static_cast<std::size_t>(t[2])], a)));
      for (int c = 0; c < 3; ++c) va[static_cast<std::size_t>(t[c])] += ar / 3.0;
    }
    std::vector<char> can(m.vertices.size(), 0);
    double area = 0.0;
    for (std::size_t v = 0; v < m.vertices.size(); ++v) {
      if (pins[v] || moved[v]) continue;
      can[v] = 1;
      area += va[v];
    }
    const double d = area > 0.0 ? 1.01 * (r.volume_before_mm3 - r.volume_after_mm3) / area : 0.0;
    if (!(d > 0.0 && d < 0.05 * std::max(ctx.cell_mm, 1e-3))) break;
    for (std::size_t v = 0; v < m.vertices.size(); ++v) {
      if (!can[v]) continue;
      const Vec3 to = add(m.vertices[v], mul(vn[v], d));
      const Vec3 off = sub(to, after_c.vertices[v]);
      if (std::fabs(off.x) > box || std::fabs(off.y) > box || std::fabs(off.z) > box) continue;
      if (blocked_reason(ctx, to).empty()) m.vertices[v] = to;
    }
    r.volume_after_mm3 = signed_volume(m);
  }
  for (std::size_t v = 0; v < m.vertices.size() && v < pins.size(); ++v)
    r.pinned_moved += pins[v] && (m.vertices[v].x != mesh.vertices[v].x ||
                                  m.vertices[v].y != mesh.vertices[v].y ||
                                  m.vertices[v].z != mesh.vertices[v].z);
  r.seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  return m;
}

}  // namespace topopt
