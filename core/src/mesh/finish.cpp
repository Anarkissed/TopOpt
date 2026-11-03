#include "topopt/finish.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
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
                    const Vec3& p, const Vec3& n, double cap_mm) {
  double r = 0.5 * cap_mm;
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
            if (d < best) { best = d; q = cp; found = true; }
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
  if (ctx.keeps != nullptr)
    for (std::size_t v = 0; v < pin.size(); ++v)
      for (const KeepRegion& k : *ctx.keeps)
        if (k.contains(m.vertices[v])) { pin[v] = 1; break; }
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

std::vector<double> vertex_local_thickness_mm(const TriangleMesh& mesh, double cap_mm) {
  std::vector<double> t(mesh.vertices.size(), cap_mm);
  if (mesh.empty() || !(cap_mm > 0.0)) return t;
  TriGrid g;
  g.build(mesh, cap_mm);
  const std::vector<Vec3> fn = face_normals(mesh), vn = vertex_normals(mesh);
  for (std::size_t v = 0; v < t.size(); ++v)
    if (len(vn[v]) > 0.5) t[v] = thickness_at(mesh, g, fn, mesh.vertices[v], vn[v], cap_mm);
  return t;
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
  std::vector<int> thin;
  for (std::size_t v = 0; v < nv; ++v)
    if (t[v] < ok) thin.push_back(static_cast<int>(v));
  if (thin.empty()) return m;
  const std::vector<double> before = t;
  std::vector<std::string> why(nv);
  for (const int v : thin)
    if (pinned[static_cast<std::size_t>(v)]) why[static_cast<std::size_t>(v)] = "on a face of your part";
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
  SurfaceConstraints k;
  k.cell_mm = ctx.cell_mm;
  k.trust_voxels = 0.5;
  k.sign = sign;
  k.preserve_volume = true;
  MeanCurvatureParams mp;
  mp.steps = ctx.mcf_steps;
  mp.dt_scale = kFinishMcfDtScale;
  // Roughness: the RMS normal offset of each free vertex from its 1-ring mean — the
  // step a staircase leaves, independent of an analytic reference.
  // Measured away from the pins (two rings clear): the seam where a moving surface
  // meets a pinned CAD edge is a kink of its own, not stair-step.
  const auto nb = vertex_neighbours(mesh);
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
  // surface its staircase approximates, taken as the input low-passed by a long
  // Taubin lambda/mu filter (no shrink; 100 pairs, the pins held).
  TriangleMesh ref = mesh;
  {
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
  }
  const std::vector<Vec3> ref_n = vertex_normals(ref);
  auto roughness = [&](const TriangleMesh& mm) {
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
  if (report) {
    report->surface_applied = true;
    const double r1 = roughness(res.mesh);
    report->roughness_before_mm = r0;
    report->roughness_after_mm = r1;
    report->stair_step_removed_pct = r0 > 0.0 ? std::max(0.0, 100.0 * (1.0 - r1 / r0)) : 0.0;
    report->pinned_vertices = static_cast<std::size_t>(
        std::count(sign.begin(), sign.end(), TrustSign::Pinned));
  }
  return res.mesh;
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
  if (r.volume_after_mm3 < r.volume_before_mm3 && r.volume_before_mm3 > 0.0) {
    // A uniform outward shift of the free cut vertices that stay in their trust box.
    const std::vector<Vec3> vn = vertex_normals(m);
    const double box = 0.5 * ctx.cell_mm;
    double area = 0.0;
    for (const auto& t : m.triangles) {
      const Vec3& a = m.vertices[static_cast<std::size_t>(t[0])];
      area += 0.5 * len(cross(sub(m.vertices[static_cast<std::size_t>(t[1])], a),
                              sub(m.vertices[static_cast<std::size_t>(t[2])], a)));
    }
    const double d = area > 0.0 ? 1.01 * (r.volume_before_mm3 - r.volume_after_mm3) / area : 0.0;
    if (d > 0.0 && d < 0.05 * std::max(ctx.cell_mm, 1e-3)) {
      for (std::size_t v = 0; v < m.vertices.size(); ++v) {
        if (pins[v] || moved[v]) continue;
        const Vec3 to = add(m.vertices[v], mul(vn[v], d));
        const Vec3 off = sub(to, after_c.vertices[v]);
        if (std::fabs(off.x) > box || std::fabs(off.y) > box || std::fabs(off.z) > box) continue;
        if (blocked_reason(ctx, to).empty()) m.vertices[v] = to;
      }
      r.volume_after_mm3 = signed_volume(m);
    }
  }
  r.seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  return m;
}

}  // namespace topopt
