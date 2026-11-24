// THE PRINT ORIENTATION RANKING (print_orientation.hpp; his print orientation, spec 2e, P4).
#include "topopt/print_orientation.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <limits>

#include "topopt/build_orientation.hpp"   // recommend_print_orientation: the one rule
#include "topopt/print_frame.hpp"
#include "topopt/voxel.hpp"

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

}  // namespace topopt
