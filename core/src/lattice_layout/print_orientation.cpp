// THE PRINT ORIENTATION RANKING (print_orientation.hpp; his print orientation, spec 2e, P4).
#include "topopt/print_orientation.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <limits>

#include <map>
#include <set>
#include <unordered_map>

#include "topopt/build_orientation.hpp"   // recommend_print_orientation: the one rule
#include "topopt/print_frame.hpp"
#include "topopt/voxel.hpp"

#ifdef TOPOPT_HAVE_MANIFOLD
#include <manifold/manifold.h>   // Phase 2: the part's convex hull
#endif

namespace topopt {
namespace {

std::string num(double v) {
  if (!std::isfinite(v)) return "null";
  char b[40];
  std::snprintf(b, sizeof b, "%.10g", v);
  return b;
}
std::string str(const std::string& s) { return "\"" + s + "\""; }
double at(const Vec3& v, int a) { return a == 0 ? v.x : a == 1 ? v.y : v.z; }
// Candidate k: its axis (0 x, 1 y, 2 z) and its sign.
int axis_of(int k) { return k < 2 ? 2 : k < 4 ? 0 : 1; }
int sign_of(int k) { return k % 2 == 0 ? 1 : -1; }

double cross2(const std::array<double, 2>& o, const std::array<double, 2>& a, const std::array<double, 2>& b) {
  return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
}
std::vector<std::array<double, 2>> hull_of(std::vector<std::array<double, 2>> p) {
  std::sort(p.begin(), p.end());
  p.erase(std::unique(p.begin(), p.end()), p.end());
  if (p.size() < 3) return p;
  std::vector<std::array<double, 2>> h(2 * p.size());
  std::size_t k = 0;
  for (std::size_t i = 0; i < p.size(); ++i) {
    while (k >= 2 && cross2(h[k - 2], h[k - 1], p[i]) <= 0.0) --k;
    h[k++] = p[i];
  }
  for (std::size_t i = p.size() - 1, t = k + 1; i > 0; --i) {
    while (k >= t && cross2(h[k - 2], h[k - 1], p[i - 1]) <= 0.0) --k;
    h[k++] = p[i - 1];
  }
  h.resize(k - 1);
  return h;
}

}  // namespace

const std::array<Vec3, 6>& orientation_axes() {
  static const std::array<Vec3, 6> a{Vec3{0, 0, 1}, Vec3{0, 0, -1}, Vec3{1, 0, 0}, Vec3{-1, 0, 0}, Vec3{0, 1, 0}, Vec3{0, -1, 0}};
  return a;
}

double support_along_axis(const VoxelGrid& g, const std::vector<char>& in_part, const std::vector<char>& solid, int axis,
                          int up_sign) {
  const int n[3] = {g.nx, g.ny, g.nz};
  const std::size_t nv = g.voxel_count();
  if (nv == 0 || in_part.size() != nv || solid.size() != nv) return 0.0;
  const int b = (axis + 1) % 3, c = (axis + 2) % 3;
  const int na = n[axis];
  // height along the up -> the index along the axis
  const auto ia_of = [&](int h) { return up_sign > 0 ? h : na - 1 - h; };
  const auto idx = [&](int h, int ib, int ic) {
    int q[3];
    q[axis] = ia_of(h);
    q[b] = ib;
    q[c] = ic;
    return g.index(q[0], q[1], q[2]);
  };
  int bed = na;
  for (int h = 0; h < na && bed == na; ++h)
    for (int ib = 0; ib < n[b] && bed == na; ++ib)
      for (int ic = 0; ic < n[c]; ++ic)
        if (in_part[idx(h, ib, ic)]) { bed = h; break; }
  std::size_t count = 0;
  for (int ib = 0; ib < n[b]; ++ib)
    for (int ic = 0; ic < n[c]; ++ic)
      for (int h = bed + 1; h < na; ++h) {
        if (!solid[idx(h, ib, ic)] || in_part[idx(h - 1, ib, ic)]) continue;
        bool held = false;
        for (int db = -1; db <= 1 && !held; ++db)
          for (int dc = -1; dc <= 1; ++dc) {
            const int jb = ib + db, jc = ic + dc;
            if ((db == 0 && dc == 0) || jb < 0 || jc < 0 || jb >= n[b] || jc >= n[c]) continue;
            if (in_part[idx(h - 1, jb, jc)]) { held = true; break; }
          }
        if (held) continue;
        for (int hh = h - 1; hh >= bed && !in_part[idx(hh, ib, ic)]; --hh) ++count;
      }
  return static_cast<double>(count) * g.voxel_volume();
}

std::array<OrientationGeometry, 6> orientation_geometry(const TriangleMesh& m) {
  std::array<OrientationGeometry, 6> out{};
  if (m.vertices.empty()) return out;
  double lo[3] = {1e300, 1e300, 1e300}, hi[3] = {-1e300, -1e300, -1e300};
  for (const Vec3& v : m.vertices)
    for (int a = 0; a < 3; ++a) {
      lo[a] = std::min(lo[a], at(v, a));
      hi[a] = std::max(hi[a], at(v, a));
    }
  const double flat = std::cos(M_PI / 180.0), tol = 0.01;
  std::array<std::vector<std::array<double, 2>>, 6> pts;
  for (const auto& t : m.triangles) {
    const Vec3& p0 = m.vertices[static_cast<std::size_t>(t[0])];
    const Vec3& p1 = m.vertices[static_cast<std::size_t>(t[1])];
    const Vec3& p2 = m.vertices[static_cast<std::size_t>(t[2])];
    const Vec3 u{p1.x - p0.x, p1.y - p0.y, p1.z - p0.z}, w{p2.x - p0.x, p2.y - p0.y, p2.z - p0.z};
    const Vec3 cr{u.y * w.z - u.z * w.y, u.z * w.x - u.x * w.z, u.x * w.y - u.y * w.x};
    const double l = std::sqrt(cr.x * cr.x + cr.y * cr.y + cr.z * cr.z);
    if (!(l > 0.0)) continue;
    for (int k = 0; k < 6; ++k) {
      const int a = axis_of(k), s = sign_of(k);
      // facing straight down along this up: its normal along -up
      if (!(-s * at(cr, a) / l >= flat)) continue;
      // at the lowest point along this up
      const double bed = s > 0 ? lo[a] : hi[a];
      if (std::fabs(at(p0, a) - bed) > tol || std::fabs(at(p1, a) - bed) > tol || std::fabs(at(p2, a) - bed) > tol) continue;
      out[static_cast<std::size_t>(k)].contact_mm2 += 0.5 * l;
      const int b = (a + 1) % 3, c = (a + 2) % 3;
      for (const Vec3* p : {&p0, &p1, &p2}) pts[static_cast<std::size_t>(k)].push_back({at(*p, b), at(*p, c)});
    }
  }
  for (int k = 0; k < 6; ++k) {
    const int a = axis_of(k);
    out[static_cast<std::size_t>(k)].height_mm = hi[a] - lo[a];
    out[static_cast<std::size_t>(k)].hull = hull_of(std::move(pts[static_cast<std::size_t>(k)]));
  }
  return out;
}

bool stands_over(const OrientationGeometry& g, int k, const Vec3& p, double tol) {
  const int a = axis_of(k), b = (a + 1) % 3, c = (a + 2) % 3;
  const std::array<double, 2> q{at(p, b), at(p, c)};
  const std::size_t n = g.hull.size();
  if (n < 3) return false;
  for (std::size_t i = 0; i < n; ++i) {
    const auto& e0 = g.hull[i];
    const auto& e1 = g.hull[(i + 1) % n];
    const double ex = e1[0] - e0[0], ey = e1[1] - e0[1], len = std::hypot(ex, ey);
    if (!(len > 0.0)) continue;
    // counter-clockwise: inside is to the left; beyond `tol` to the right is outside
    if (cross2(e0, e1, q) / len < -tol) return false;
  }
  return true;
}

std::string print_orientation_json(const OrientationStrengths& s, const std::array<OrientationGeometry, 6>& g,
                                   const PrintFrame& frame, double layer_mm) {
  const double nan = std::numeric_limits<double>::quiet_NaN();
  const std::array<Vec3, 6>& ax = orientation_axes();
  std::vector<OrientationCandidateIn> in(6);
  std::vector<double> guessed(6, nan);
  std::vector<char> stands(6, 1);
  for (int k = 0; k < 6; ++k) {
    const std::size_t q = static_cast<std::size_t>(k);
    OrientationCandidateIn& c = in[q];
    c.up = frame.dir_to_model(ax[q]);
    c.incumbent = k == 0;
    c.flat = g[q].contact_mm2 > 0.0;
    if (s.known) {
      const OrientationStrength& t = s.by_axis[q];
      guessed[q] = std::isfinite(t.struts) ? std::min(t.solid, t.struts) : t.solid;
      c.support_mm3 = t.support_mm3;
    }
    c.strength = guessed[q];
    c.contact_mm2 = g[q].contact_mm2;
    stands[q] = !s.has_centre_of_mass || stands_over(g[q], k, s.centre_of_mass);
    c.stands = stands[q] != 0;
    c.height_mm = g[q].height_mm;
  }
  const OrientationRecommendation r = recommend_print_orientation(in, s.required_margin);
  std::string o = "{\"estimate\": true, \"required_margin\": " + num(s.required_margin) + ", \"as_placed\": 0, \"recommended\": " +
                  std::to_string(r.recommended) + ", \"change\": " + (r.change ? "true" : "false") + ", \"headline\": " +
                  str(r.headline) + ", \"none_passes\": " + (r.none_passes ? "true" : "false") + ", \"why\": [";
  for (std::size_t i = 0; i < r.why.size(); ++i) o += (i ? ", " : "") + str(r.why[i]);
  o += "],\n    \"candidates\": [";
  for (int k = 0; k < 6; ++k) {
    const std::size_t q = static_cast<std::size_t>(k);
    const OrientationCandidateIn& c = in[q];
    const OrientationCandidateOut& co = r.candidates[q];
    const OrientationStrength t = s.known ? s.by_axis[q] : OrientationStrength{nan, nan, nan, 0, nan};
    const double layers = layer_mm > 0.0 ? std::ceil(g[q].height_mm / layer_mm - 1e-9) : nan;
    o += std::string(k ? "," : "") + "\n      {\"up\": [" + num(c.up.x) + ", " + num(c.up.y) + ", " + num(c.up.z) +
         "], \"as_placed\": " + (k == 0 ? "true" : "false") + ", \"offered\": " + (co.offered ? "true" : "false") +
         ", \"dropped\": " + (co.dropped.empty() ? std::string("null") : str(co.dropped)) +
         ", \"passes\": " + (co.passes ? "true" : "false") + ", \"strength\": {\"guessed\": " + num(guessed[q]) +
         ", \"solid\": " + num(t.solid) + ", \"solid_interlayer\": " + num(t.solid_interlayer) + ", \"struts\": " +
         num(t.struts) + ", \"struts_under\": " + std::to_string(t.struts_under) + ", \"struts_estimate\": true}" +
         ", \"support_mm3\": " + num(s.known ? t.support_mm3 : nan) + ", \"height_mm\": " + num(g[q].height_mm) +
         ", \"layers\": " + num(layers) + ", \"bed_contact_mm2\": " + num(g[q].contact_mm2) +
         ", \"stands\": " + (stands[q] ? "true" : "false") + "}";
  }
  o += "\n    ]}";
  return o;
}

// ── PHASE 2: hull faces and edges ─────────────────────────────────────────────────────────────────────────────────
namespace {
Vec3 v_sub(const Vec3& a, const Vec3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
Vec3 v_add(const Vec3& a, const Vec3& b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
Vec3 v_mul(const Vec3& a, double s) { return {a.x * s, a.y * s, a.z * s}; }
double v_dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
Vec3 v_cross(const Vec3& a, const Vec3& b) { return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}; }
double v_len(const Vec3& a) { return std::sqrt(v_dot(a, a)); }
Vec3 v_unit(const Vec3& a) {
  const double l = v_len(a);
  return l > 0.0 ? v_mul(a, 1.0 / l) : Vec3{0.0, 0.0, 1.0};
}
// Two unit axes square to `n` (and to each other).
void basis_of(const Vec3& n, Vec3& a1, Vec3& a2) {
  const Vec3 h = std::fabs(n.x) < 0.9 ? Vec3{1, 0, 0} : Vec3{0, 1, 0};
  a1 = v_unit(v_cross(n, h));
  a2 = v_cross(n, a1);
}
// The minimum width of a convex polygon (counter-clockwise), by its edges.
double min_width(const std::vector<std::array<double, 2>>& h) {
  const std::size_t n = h.size();
  if (n < 3) return 0.0;
  double best = std::numeric_limits<double>::infinity();
  for (std::size_t i = 0; i < n; ++i) {
    const auto& a = h[i];
    const auto& b = h[(i + 1) % n];
    const double ex = b[0] - a[0], ey = b[1] - a[1], l = std::hypot(ex, ey);
    if (!(l > 0.0)) continue;
    double far = 0.0;
    for (const auto& p : h) far = std::max(far, std::fabs((p[0] - a[0]) * ey - (p[1] - a[1]) * ex) / l);
    best = std::min(best, far);
  }
  return best;
}
// Point in a convex counter-clockwise polygon, at least `margin` inside (a negative margin: that far outside allowed).
bool inside_poly(const std::vector<std::array<double, 2>>& h, const std::array<double, 2>& q, double margin) {
  const std::size_t n = h.size();
  if (n < 3) return false;
  for (std::size_t i = 0; i < n; ++i) {
    const auto& a = h[i];
    const auto& b = h[(i + 1) % n];
    const double ex = b[0] - a[0], ey = b[1] - a[1], l = std::hypot(ex, ey);
    if (!(l > 0.0)) continue;
    if (cross2(a, b, q) / l < margin) return false;
  }
  return true;
}
// The part's triangles lying on the plane n.x = d (normal within 1 degree, every corner within tol): their area.
double contact_on(const TriangleMesh& m, std::size_t np, const Vec3& n, double d, double tol) {
  const double flat = std::cos(M_PI / 180.0);
  double area = 0.0;
  for (std::size_t t = 0; t < np; ++t) {
    const auto& tri = m.triangles[t];
    const Vec3& a = m.vertices[static_cast<std::size_t>(tri[0])];
    const Vec3& b = m.vertices[static_cast<std::size_t>(tri[1])];
    const Vec3& c = m.vertices[static_cast<std::size_t>(tri[2])];
    const Vec3 cr = v_cross(v_sub(b, a), v_sub(c, a));
    const double l = v_len(cr);
    if (!(l > 0.0) || v_dot(cr, n) / l < flat) continue;
    if (std::fabs(v_dot(a, n) - d) > tol || std::fabs(v_dot(b, n) - d) > tol || std::fabs(v_dot(c, n) - d) > tol) continue;
    area += 0.5 * l;
  }
  return area;
}
}  // namespace

OrientationCandidates print_candidates(const TriangleMesh& mesh, std::size_t part_triangles,
                                             const CandidateRule& rule) {
  OrientationCandidates out;
  const std::size_t np = part_triangles > 0 ? std::min(part_triangles, mesh.triangles.size()) : mesh.triangles.size();
  if (np == 0) return out;
  std::vector<char> used(mesh.vertices.size(), 0);
  for (std::size_t t = 0; t < np; ++t)
    for (int k = 0; k < 3; ++k) used[static_cast<std::size_t>(mesh.triangles[t][static_cast<std::size_t>(k)])] = 1;
  std::vector<Vec3> pts;
  for (std::size_t i = 0; i < mesh.vertices.size(); ++i)
    if (used[i]) pts.push_back(mesh.vertices[i]);
  // The hull: its vertices and triangles.
  std::vector<Vec3> hv;
  std::vector<std::array<std::size_t, 3>> ht;
#ifdef TOPOPT_HAVE_MANIFOLD
  {
    std::vector<manifold::vec3> mp;
    mp.reserve(pts.size());
    for (const Vec3& p : pts) mp.push_back(manifold::vec3{p.x, p.y, p.z});
    const manifold::MeshGL64 g = manifold::Manifold::Hull(mp).GetMeshGL64();
    const std::size_t stride = g.numProp;
    for (std::size_t i = 0; i + 2 < g.vertProperties.size(); i += stride)
      hv.push_back({g.vertProperties[i], g.vertProperties[i + 1], g.vertProperties[i + 2]});
    for (std::size_t i = 0; i + 2 < g.triVerts.size(); i += 3)
      ht.push_back({static_cast<std::size_t>(g.triVerts[i]), static_cast<std::size_t>(g.triVerts[i + 1]),
                    static_cast<std::size_t>(g.triVerts[i + 2])});
  }
#endif
  double z_lo = std::numeric_limits<double>::infinity();
  for (const Vec3& p : pts) z_lo = std::min(z_lo, p.z);
  const auto height_along = [&](const Vec3& u) {
    double lo = std::numeric_limits<double>::infinity(), hi = -lo;
    for (const Vec3& p : (hv.empty() ? pts : hv)) {
      const double s = v_dot(p, u);
      lo = std::min(lo, s);
      hi = std::max(hi, s);
    }
    return hi - lo;
  };
  // As placed (the job's own +Z): which face or edge it rests on, below.
  OrientationCandidate placed;
  placed.as_placed = true;
  placed.up = {0.0, 0.0, 1.0};
  placed.height_mm = height_along(placed.up);
  placed.contact_mm2 = contact_on(mesh, np, {0.0, 0.0, -1.0}, -z_lo, rule.coplanar_mm);
  {   // its lowest points' outline (when it rests on neither a hull face nor an edge)
    std::vector<std::array<double, 2>> low;
    for (const Vec3& p : pts)
      if (p.z - z_lo <= rule.coplanar_mm) low.push_back({p.x, p.y});
    for (const auto& q : hull_of(low)) placed.plate.push_back({q[0], q[1], z_lo});
  }
  if (ht.empty()) {   // no hull: the six axes (Phase 1)
    out.list.push_back(placed);
    const std::array<OrientationGeometry, 6> g6 = orientation_geometry(mesh);
    for (int k = 1; k < 6; ++k) {
      OrientationCandidate c;
      c.kind = OrientationCandidate::Kind::Face;
      c.up = orientation_axes()[static_cast<std::size_t>(k)];
      c.contact_mm2 = g6[static_cast<std::size_t>(k)].contact_mm2;
      c.plate_mm2 = c.contact_mm2;
      c.height_mm = g6[static_cast<std::size_t>(k)].height_mm;
      if (c.contact_mm2 > 0.0) out.list.push_back(c);
    }
    return out;
  }
  out.hull = true;
  // Faces: the hull's facets merged by plane.
  struct Plate { Vec3 n; double d = 0.0, area = 0.0; std::vector<std::size_t> tris; };
  std::vector<Plate> plates;
  std::vector<int> plate_of(ht.size(), -1);
  const double same = std::cos(rule.coplanar_deg * M_PI / 180.0);
  for (std::size_t t = 0; t < ht.size(); ++t) {
    const Vec3& a = hv[ht[t][0]];
    const Vec3 cr = v_cross(v_sub(hv[ht[t][1]], a), v_sub(hv[ht[t][2]], a));
    const double l = v_len(cr);
    if (!(l > 0.0)) continue;
    const Vec3 n = v_mul(cr, 1.0 / l);
    const double d = v_dot(n, a);
    int found = -1;
    for (std::size_t p = 0; p < plates.size() && found < 0; ++p)
      if (v_dot(plates[p].n, n) >= same && std::fabs(plates[p].d - d) <= rule.coplanar_mm) found = static_cast<int>(p);
    if (found < 0) {
      plates.push_back({n, d, 0.0, {}});
      found = static_cast<int>(plates.size() - 1);
    }
    Plate& P = plates[static_cast<std::size_t>(found)];
    P.area += 0.5 * l;
    P.tris.push_back(t);
    plate_of[t] = found;
  }
  // Each plate's outline (2D hull in its plane), its width; which plates are faces.
  std::vector<std::vector<Vec3>> outline(plates.size());
  std::vector<char> is_face(plates.size(), 0);
  std::vector<double> plate_d(plates.size(), 0.0);
  for (std::size_t p = 0; p < plates.size(); ++p) {
    Plate& P = plates[p];
    // the supporting plane: every hull point on or behind it
    double dmax = -std::numeric_limits<double>::infinity();
    for (std::size_t t : P.tris)
      for (std::size_t k : ht[t]) dmax = std::max(dmax, v_dot(P.n, hv[k]));
    plate_d[p] = dmax;
    Vec3 a1, a2;
    basis_of(P.n, a1, a2);
    std::vector<std::array<double, 2>> q;
    for (std::size_t t : P.tris)
      for (std::size_t k : ht[t]) q.push_back({v_dot(hv[k], a1), v_dot(hv[k], a2)});
    const std::vector<std::array<double, 2>> h2 = hull_of(q);
    for (const auto& w : h2) outline[p].push_back(v_add(v_add(v_mul(a1, w[0]), v_mul(a2, w[1])), v_mul(P.n, dmax)));
    const bool big = P.area >= rule.plate_min_mm2 && min_width(h2) >= rule.plate_min_side_mm;
    is_face[p] = big;
    if (!big) ++out.faces_small;
  }
  // Edges: hull edges between two different faces, merged per pair.
  struct Pair { std::vector<Vec3> ends; };
  std::map<std::pair<int, int>, Pair> pairs;
  {
    std::unordered_map<std::uint64_t, std::vector<std::size_t>> by_edge;
    for (std::size_t t = 0; t < ht.size(); ++t)
      for (int k = 0; k < 3; ++k) {
        const std::uint64_t u = ht[t][static_cast<std::size_t>(k)], v = ht[t][static_cast<std::size_t>((k + 1) % 3)];
        by_edge[std::min(u, v) << 32 | std::max(u, v)].push_back(t);
      }
    for (const auto& [key, ts] : by_edge) {
      if (ts.size() != 2) continue;
      const int p = plate_of[ts[0]], q = plate_of[ts[1]];
      if (p < 0 || q < 0 || p == q) continue;
      const std::size_t u = static_cast<std::size_t>(key >> 32), v = static_cast<std::size_t>(key & 0xffffffffULL);
      Pair& pr = pairs[{std::min(p, q), std::max(p, q)}];
      pr.ends.push_back(hv[u]);
      pr.ends.push_back(hv[v]);
    }
  }
  // Face candidates, the largest first.
  std::vector<std::size_t> order;
  for (std::size_t p = 0; p < plates.size(); ++p)
    if (is_face[p]) order.push_back(p);
  std::sort(order.begin(), order.end(), [&](std::size_t a, std::size_t b) {
    return plates[a].area != plates[b].area ? plates[a].area > plates[b].area : a < b;
  });
  if (order.size() > static_cast<std::size_t>(rule.faces_max)) {
    out.faces_over_cap = order.size() - static_cast<std::size_t>(rule.faces_max);
    order.resize(static_cast<std::size_t>(rule.faces_max));
  }
  std::vector<OrientationCandidate> faces, edges;
  for (std::size_t p : order) {
    OrientationCandidate c;
    c.kind = OrientationCandidate::Kind::Face;
    c.up = v_mul(plates[p].n, -1.0);
    c.plate_mm2 = plates[p].area;
    c.plate = outline[p];
    c.contact_mm2 = contact_on(mesh, np, plates[p].n, plate_d[p], rule.coplanar_mm);
    c.height_mm = height_along(c.up);
    faces.push_back(c);
  }
  // Edge candidates, the longest first.
  for (const auto& [pq, pr] : pairs) {
    const std::size_t p = static_cast<std::size_t>(pq.first), q = static_cast<std::size_t>(pq.second);
    if (!is_face[p] || !is_face[q]) continue;
    const Vec3 e = v_unit(v_cross(plates[p].n, plates[q].n));
    double lo = std::numeric_limits<double>::infinity(), hi = -lo;
    Vec3 e0{}, e1{};
    for (const Vec3& w : pr.ends) {
      const double s = v_dot(w, e);
      if (s < lo) { lo = s; e0 = w; }
      if (s > hi) { hi = s; e1 = w; }
    }
    if (hi - lo < rule.edge_min_mm) {
      ++out.edges_short;
      continue;
    }
    OrientationCandidate c;
    c.kind = OrientationCandidate::Kind::Edge;
    c.held_by_supports = true;
    c.up = v_unit(v_mul(v_add(plates[p].n, plates[q].n), -1.0));
    c.e0 = e0;
    c.e1 = e1;
    c.n1 = plates[p].n;
    c.n2 = plates[q].n;
    const auto reach = [&](std::size_t r) {
      double far = 0.0;
      for (const Vec3& w : outline[r]) {
        const Vec3 d = v_sub(w, e0);
        far = std::max(far, v_len(v_sub(d, v_mul(e, v_dot(d, e)))));
      }
      return far;
    };
    c.w1 = reach(p);
    c.w2 = reach(q);
    c.height_mm = height_along(c.up);
    c.plate_mm2 = hi - lo;   // an edge: its length here
    edges.push_back(c);
  }
  std::sort(edges.begin(), edges.end(), [](const OrientationCandidate& a, const OrientationCandidate& b) {
    return a.plate_mm2 > b.plate_mm2;
  });
  if (edges.size() > static_cast<std::size_t>(rule.edges_max)) {
    out.edges_over_cap = edges.size() - static_cast<std::size_t>(rule.edges_max);
    edges.resize(static_cast<std::size_t>(rule.edges_max));
  }
  // As placed: the face or edge it rests on becomes the first candidate (else its lowest points).
  const double tilt = std::cos(M_PI / 180.0);
  bool matched = false;
  for (std::size_t i = 0; i < faces.size() && !matched; ++i)
    if (faces[i].up.z >= tilt) {
      OrientationCandidate c = faces[i];
      c.as_placed = true;
      faces.erase(faces.begin() + static_cast<std::ptrdiff_t>(i));
      out.list.push_back(c);
      matched = true;
    }
  for (std::size_t i = 0; i < edges.size() && !matched; ++i)
    if (edges[i].up.z >= tilt) {
      OrientationCandidate c = edges[i];
      c.as_placed = true;
      edges.erase(edges.begin() + static_cast<std::ptrdiff_t>(i));
      out.list.push_back(c);
      matched = true;
    }
  if (!matched) out.list.push_back(placed);
  for (const OrientationCandidate& c : faces) out.list.push_back(c);
  for (const OrientationCandidate& c : edges) out.list.push_back(c);
  return out;
}

void orientation_stand(OrientationCandidate& c, const Vec3& com, const CandidateRule& rule) {
  c.band1_mm = c.band2_mm = c.stand_area_mm2 = c.stand_support_mm3 = 0.0;
  const Vec3 u = v_unit(c.up);
  Vec3 a1, a2;
  basis_of(u, a1, a2);
  if (c.kind != OrientationCandidate::Kind::Edge) {
    // A face (or the lowest points): the centre of mass seen along the up, over the outline.
    std::vector<std::array<double, 2>> poly;
    for (const Vec3& w : c.plate) poly.push_back({v_dot(w, a1), v_dot(w, a2)});
    c.stands = inside_poly(hull_of(poly), {v_dot(com, a1), v_dot(com, a2)}, -rule.face_stands_tol_mm);
    return;
  }
  // An edge, held by supports: along the edge, the centre of mass at least the margin from either end; across it, the
  // bands on the two faces reach far enough on each side.
  const Vec3 e = v_unit(v_sub(c.e1, c.e0));
  const double L = v_len(v_sub(c.e1, c.e0));
  const Vec3 r = v_sub(com, c.e0);
  const double s = v_dot(r, e);
  const Vec3 m = v_unit(v_cross(u, e));   // across the edge, level
  const double y = v_dot(r, m);
  // Each face's way from the edge, in the face (into the face) and its rise and level reach per mm.
  double rise[2], level[2], side[2];
  const Vec3 ns[2] = {c.n1, c.n2};
  const double wmax[2] = {c.w1, c.w2};
  for (int f = 0; f < 2; ++f) {
    Vec3 d = v_unit(v_cross(ns[f], e));
    // into the face: away from the other face's side (the face's outline lies on that side of the edge)
    if (v_dot(d, ns[1 - f]) > 0.0) d = v_mul(d, -1.0);
    rise[f] = v_dot(d, u);
    const Vec3 hz = v_sub(d, v_mul(u, rise[f]));
    level[f] = v_len(hz);
    side[f] = v_dot(hz, m) >= 0.0 ? 1.0 : -1.0;
  }
  bool ok = s >= rule.stand_margin_mm && s <= L - rule.stand_margin_mm;
  double band[2] = {0.0, 0.0};
  for (int f = 0; f < 2 && ok; ++f) {
    // the level reach this face's band must give on its side
    const double need = std::max(0.0, side[f] * y + rule.stand_margin_mm);
    double w = rule.band_min_mm;
    if (level[f] > 0.0) w = std::max(w, need / level[f]);
    w = rule.band_step_mm * std::ceil(w / rule.band_step_mm - 1e-9);
    if (w > wmax[f] + 1e-9) {
      if (need / std::max(level[f], 1e-12) > wmax[f] + 1e-9) ok = false;   // even the whole face does not reach
      w = wmax[f];
    }
    band[f] = w;
  }
  // both sides must hold it: the other side of the centre of mass too
  if (ok)
    for (int f = 0; f < 2; ++f) {
      const double reach_pos = (side[0] > 0 ? band[0] * level[0] : 0.0) + (side[1] > 0 ? band[1] * level[1] : 0.0);
      const double reach_neg = (side[0] < 0 ? band[0] * level[0] : 0.0) + (side[1] < 0 ? band[1] * level[1] : 0.0);
      ok = ok && y + rule.stand_margin_mm <= reach_pos + 1e-9 && y - rule.stand_margin_mm >= -reach_neg - 1e-9;
    }
  c.stands = ok;
  if (!ok) return;
  c.band1_mm = band[0];
  c.band2_mm = band[1];
  for (int f = 0; f < 2; ++f) {
    c.stand_area_mm2 += L * band[f];
    c.stand_support_mm3 += L * rise[f] * level[f] * band[f] * band[f] / 2.0;   // a wedge under the band, down to the bed
  }
}

double support_along(const VoxelGrid& g, const std::vector<char>& in_part, const std::vector<char>& solid, const Vec3& up0) {
  const std::size_t nv = g.voxel_count();
  if (nv == 0 || in_part.size() != nv || solid.size() != nv) return 0.0;
  const Vec3 u = v_unit(up0);
  Vec3 a1, a2;
  basis_of(u, a1, a2);
  const double h = g.spacing;
  const auto part_at = [&](const Vec3& p) {
    const int i = static_cast<int>(std::floor((p.x - g.origin.x) / h)), j = static_cast<int>(std::floor((p.y - g.origin.y) / h)),
              k = static_cast<int>(std::floor((p.z - g.origin.z) / h));
    if (i < 0 || j < 0 || k < 0 || i >= g.nx || j >= g.ny || k >= g.nz) return false;
    return in_part[g.index(i, j, k)] != 0;
  };
  double bed = std::numeric_limits<double>::infinity();
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i)
        if (in_part[g.index(i, j, k)]) bed = std::min(bed, v_dot(g.voxel_center(i, j, k), u));
  std::size_t count = 0;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        const std::size_t e = g.index(i, j, k);
        if (!solid[e]) continue;
        const Vec3 c = g.voxel_center(i, j, k);
        if (v_dot(c, u) - bed < 0.5 * h) continue;   // on the bed
        const Vec3 b = v_sub(c, v_mul(u, h));
        if (part_at(b)) continue;
        bool held = false;
        for (const Vec3& a : {a1, v_mul(a1, -1.0), a2, v_mul(a2, -1.0)})
          held = held || part_at(v_add(b, v_mul(a, h)));
        if (held) continue;
        for (int step = 1;; ++step) {
          const Vec3 p = v_sub(c, v_mul(u, step * h));
          if (v_dot(p, u) < bed - 0.5 * h || part_at(p)) break;
          ++count;
          if (step > 100000) break;
        }
      }
  return static_cast<double>(count) * g.voxel_volume();
}

Vec3 mesh_centroid(const TriangleMesh& m, std::size_t part_triangles) {
  const std::size_t np = part_triangles > 0 ? std::min(part_triangles, m.triangles.size()) : m.triangles.size();
  double vol = 0.0;
  Vec3 c{0.0, 0.0, 0.0};
  for (std::size_t t = 0; t < np; ++t) {
    const Vec3& a = m.vertices[static_cast<std::size_t>(m.triangles[t][0])];
    const Vec3& b = m.vertices[static_cast<std::size_t>(m.triangles[t][1])];
    const Vec3& d = m.vertices[static_cast<std::size_t>(m.triangles[t][2])];
    const double v = v_dot(a, v_cross(b, d)) / 6.0;
    vol += v;
    c = v_add(c, v_mul(v_add(v_add(a, b), d), v / 4.0));
  }
  return vol != 0.0 ? v_mul(c, 1.0 / vol) : Vec3{0.0, 0.0, 0.0};
}

std::string print_orientation_json(const OrientationStrengthsN& s, OrientationCandidates& cs, const PrintFrame& frame,
                                   double layer_mm, const CandidateRule& rule) {
  const double nan = std::numeric_limits<double>::quiet_NaN();
  const std::size_t n = cs.list.size();
  std::vector<OrientationCandidateIn> in(n);
  std::vector<double> guessed(n, nan), support(n, nan);
  for (std::size_t q = 0; q < n; ++q) {
    OrientationCandidate& c = cs.list[q];
    if (s.has_centre_of_mass) orientation_stand(c, s.centre_of_mass, rule);
    OrientationCandidateIn& ci = in[q];
    ci.up = frame.dir_to_model(c.up);
    ci.incumbent = c.as_placed;
    ci.flat = c.kind != OrientationCandidate::Kind::Edge && c.contact_mm2 > 0.0;
    ci.held_by_supports = c.kind == OrientationCandidate::Kind::Edge;
    if (s.known && q < s.by_up.size()) {
      const OrientationStrength& t = s.by_up[q];
      guessed[q] = std::isfinite(t.struts) ? std::min(t.solid, t.struts) : t.solid;
      support[q] = t.support_mm3 + c.stand_support_mm3;   // the stand supports count: least support wins honestly
      ci.support_mm3 = support[q];
    }
    ci.strength = guessed[q];
    ci.contact_mm2 = c.contact_mm2;
    ci.stands = c.stands;
    ci.height_mm = c.height_mm;
  }
  const OrientationRecommendation r = recommend_print_orientation(in, s.required_margin);
  std::string o = "{\"estimate\": true, \"required_margin\": " + num(s.required_margin) + ", \"as_placed\": 0, \"recommended\": " +
                  std::to_string(r.recommended) + ", \"change\": " + (r.change ? "true" : "false") + ", \"headline\": " +
                  str(r.headline) + ", \"none_passes\": " + (r.none_passes ? "true" : "false") + ", \"why\": [";
  for (std::size_t i = 0; i < r.why.size(); ++i) o += (i ? ", " : "") + str(r.why[i]);
  o += "], \"hull\": " + std::string(cs.hull ? "true" : "false") + ", \"not_offered\": {\"faces_too_small\": " +
       std::to_string(cs.faces_small) + ", \"faces_over_cap\": " + std::to_string(cs.faces_over_cap) +
       ", \"edges_too_short\": " + std::to_string(cs.edges_short) + ", \"edges_over_cap\": " + std::to_string(cs.edges_over_cap) +
       "},\n    \"candidates\": [";
  for (std::size_t q = 0; q < n; ++q) {
    const OrientationCandidate& c = cs.list[q];
    const OrientationCandidateIn& ci = in[q];
    const OrientationCandidateOut& co = r.candidates[q];
    const OrientationStrength t = s.known && q < s.by_up.size() ? s.by_up[q] : OrientationStrength{nan, nan, nan, 0, nan};
    const double layers = layer_mm > 0.0 ? std::ceil(c.height_mm / layer_mm - 1e-9) : nan;
    const char* rests = c.kind == OrientationCandidate::Kind::Edge ? "edge" : c.kind == OrientationCandidate::Kind::Face ? "face" : "lowest";
    o += std::string(q ? "," : "") + "\n      {\"up\": [" + num(ci.up.x) + ", " + num(ci.up.y) + ", " + num(ci.up.z) +
         "], \"rests_on\": " + str(rests) + ", \"as_placed\": " + (c.as_placed ? "true" : "false") +
         ", \"offered\": " + (co.offered ? "true" : "false") +
         ", \"dropped\": " + (co.dropped.empty() ? std::string("null") : str(co.dropped)) +
         ", \"passes\": " + (co.passes ? "true" : "false") + ", \"strength\": {\"guessed\": " + num(guessed[q]) +
         ", \"solid\": " + num(t.solid) + ", \"solid_interlayer\": " + num(t.solid_interlayer) + ", \"struts\": " +
         num(t.struts) + ", \"struts_under\": " + std::to_string(t.struts_under) + ", \"struts_estimate\": true}" +
         ", \"support_mm3\": " + num(support[q]) + ", \"part_support_mm3\": " + num(t.support_mm3) +
         ", \"height_mm\": " + num(c.height_mm) + ", \"layers\": " + num(layers) + ", \"bed_contact_mm2\": " +
         num(c.contact_mm2) + ", \"stands\": " + (c.stands ? "true" : "false");
    if (c.kind == OrientationCandidate::Kind::Edge)
      o += ", \"held_by_supports\": true, \"edge_mm\": " + num(c.plate_mm2) + ", \"stand_supports\": {\"band_mm\": [" +
           num(c.band1_mm) + ", " + num(c.band2_mm) + "], \"area_mm2\": " + num(c.stand_area_mm2) + ", \"volume_mm3\": " +
           num(c.stand_support_mm3) + "}";
    else if (c.kind == OrientationCandidate::Kind::Face)
      o += ", \"face_mm2\": " + num(c.plate_mm2);
    o += "}";
  }
  o += "\n    ]}";
  return o;
}

// ── STAND SUPPORTS: the bands on an edge's two faces, cut into the mesh and painted ────────────────────────────────────
StandPaint paint_stand_supports(TriangleMesh& m, std::size_t part_triangles, const OrientationCandidate& c) {
  StandPaint out;
  if (c.kind != OrientationCandidate::Kind::Edge || !c.stands) return out;
  const std::size_t np = part_triangles > 0 ? std::min(part_triangles, m.triangles.size()) : m.triangles.size();
  const Vec3 e = v_unit(v_sub(c.e1, c.e0));
  const Vec3 ns[2] = {c.n1, c.n2};
  const double band[2] = {c.band1_mm, c.band2_mm};
  Vec3 into[2];
  for (int f = 0; f < 2; ++f) {
    Vec3 d = v_unit(v_cross(ns[f], e));
    if (v_dot(d, ns[1 - f]) > 0.0) d = v_mul(d, -1.0);
    into[f] = d;
  }
  const double flat = std::cos(M_PI / 180.0), tol = 0.02;
  // which face each part triangle lies on (-1: neither)
  std::vector<int> face_of(np, -1);
  for (std::size_t t = 0; t < np; ++t) {
    const auto& tri = m.triangles[t];
    const Vec3& a = m.vertices[static_cast<std::size_t>(tri[0])];
    const Vec3& b = m.vertices[static_cast<std::size_t>(tri[1])];
    const Vec3& d = m.vertices[static_cast<std::size_t>(tri[2])];
    const Vec3 cr = v_cross(v_sub(b, a), v_sub(d, a));
    const double l = v_len(cr);
    if (!(l > 0.0)) continue;
    for (int f = 0; f < 2; ++f)
      if (v_dot(cr, ns[f]) / l >= flat && std::fabs(v_dot(v_sub(a, c.e0), ns[f])) <= tol &&
          std::fabs(v_dot(v_sub(b, c.e0), ns[f])) <= tol && std::fabs(v_dot(v_sub(d, c.e0), ns[f])) <= tol)
        face_of[t] = f;
  }
  // the band's edge on each face: s(x) = (x - e0).into - band; an edge of a face triangle crossing it is cut once
  const auto s_of = [&](int f, const Vec3& x) { return v_dot(v_sub(x, c.e0), into[f]) - band[f]; };
  std::unordered_map<std::uint64_t, int> cut;   // edge -> new vertex
  for (std::size_t t = 0; t < np; ++t) {
    const int f = face_of[t];
    if (f < 0) continue;
    for (int k = 0; k < 3; ++k) {
      const int i = m.triangles[t][static_cast<std::size_t>(k)], j = m.triangles[t][static_cast<std::size_t>((k + 1) % 3)];
      const std::uint64_t key = static_cast<std::uint64_t>(std::min(i, j)) << 32 | static_cast<std::uint64_t>(std::max(i, j));
      if (cut.count(key)) continue;
      const Vec3 vi = m.vertices[static_cast<std::size_t>(std::min(i, j))], vj = m.vertices[static_cast<std::size_t>(std::max(i, j))];
      const double si = s_of(f, vi), sj = s_of(f, vj);
      if (!((si < 0.0 && sj > 0.0) || (si > 0.0 && sj < 0.0))) continue;
      const double w = si / (si - sj);
      m.vertices.push_back(v_add(vi, v_mul(v_sub(vj, vi), w)));
      cut[key] = static_cast<int>(m.vertices.size() - 1);
    }
  }
  // every part triangle with a cut edge split (so no neighbour is left with a point on its edge)
  std::vector<std::array<int, 3>> extra;
  std::vector<int> extra_face;
  std::vector<int> face_new(np, -1);
  const auto cut_at = [&](int i, int j) {
    const auto it = cut.find(static_cast<std::uint64_t>(std::min(i, j)) << 32 | static_cast<std::uint64_t>(std::max(i, j)));
    return it == cut.end() ? -1 : it->second;
  };
  for (std::size_t t = 0; t < np; ++t) {
    std::array<int, 3> v = m.triangles[t];
    int cs[3] = {cut_at(v[0], v[1]), cut_at(v[1], v[2]), cut_at(v[2], v[0])};
    const int n_cut = (cs[0] >= 0) + (cs[1] >= 0) + (cs[2] >= 0);
    face_new[t] = face_of[t];
    if (n_cut == 0) continue;
    // turn the corners so the cuts are on (0,1) [and (1,2)]
    int r = 0;
    if (n_cut == 1) r = cs[0] >= 0 ? 0 : cs[1] >= 0 ? 1 : 2;
    else r = cs[2] < 0 ? 0 : cs[0] < 0 ? 1 : 2;
    const std::array<int, 3> w{v[static_cast<std::size_t>(r)], v[static_cast<std::size_t>((r + 1) % 3)], v[static_cast<std::size_t>((r + 2) % 3)]};
    const int c01 = cut_at(w[0], w[1]), c12 = cut_at(w[1], w[2]);
    if (n_cut == 1) {
      m.triangles[t] = {w[0], c01, w[2]};
      extra.push_back({c01, w[1], w[2]});
      extra_face.push_back(face_of[t]);
    } else {
      m.triangles[t] = {c01, w[1], c12};
      extra.push_back({w[0], c01, c12});
      extra.push_back({w[0], c12, w[2]});
      extra_face.push_back(face_of[t]);
      extra_face.push_back(face_of[t]);
    }
  }
  // the part's triangles, then the new pieces, then everything after the part (the lattice's shells)
  std::vector<std::array<int, 3>> tris(m.triangles.begin(), m.triangles.begin() + static_cast<std::ptrdiff_t>(np));
  tris.insert(tris.end(), extra.begin(), extra.end());
  tris.insert(tris.end(), m.triangles.begin() + static_cast<std::ptrdiff_t>(np), m.triangles.end());
  m.triangles.swap(tris);
  face_new.insert(face_new.end(), extra_face.begin(), extra_face.end());
  out.added = extra.size();
  out.painted.assign(m.triangles.size(), 0);
  for (std::size_t t = 0; t < face_new.size(); ++t) {
    const int f = face_new[t];
    if (f < 0) continue;
    const auto& tri = m.triangles[t];
    const Vec3& a = m.vertices[static_cast<std::size_t>(tri[0])];
    const Vec3& b = m.vertices[static_cast<std::size_t>(tri[1])];
    const Vec3& d = m.vertices[static_cast<std::size_t>(tri[2])];
    const Vec3 g{(a.x + b.x + d.x) / 3.0, (a.y + b.y + d.y) / 3.0, (a.z + b.z + d.z) / 3.0};
    if (s_of(f, g) > 0.0) continue;
    out.painted[t] = 1;
    ++out.triangles;
    out.area_mm2 += 0.5 * v_len(v_cross(v_sub(b, a), v_sub(d, a)));
  }
  return out;
}

}  // namespace topopt
