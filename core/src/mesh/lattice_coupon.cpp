// ★ THE COUPON (ruling 2026-11-02, the addition): one sample shape that is both the app's
// Lattice preview and the block he prints. topopt/lattice_sample.hpp states the contract;
// this file builds it.
//
// THE SHAPE (mm, Z up, printed as it stands, no supports):
//     x  0 -  3   a SOLID WALL, the joint between lattice and solid
//     x  3 - 33   the lattice body, the full 40 mm width
//     x 33 - 45   a TONGUE 12 mm wide (y 14 - 26): the thin section beside the thick one
//     z  0 - 1.5  the solid base plate under all of it (today's blocks' plate)
//     the cross-section in y-z: vertical sides to z 15, then a HALF-CYLINDER of radius 20
//     about the x axis through (y 20, z 15), so the top is at z 35 and the lattice is cut at
//     every angle along it, as at a rounded edge of a real part.
//
// THE LATTICE:
//   * density graded along x from the band's bottom at the wall to its top at the tongue's
//     end, and never below the density whose strut (or wall) is one bead at the local cell,
//     so the thinnest PRINTABLE member shows;
//   * the type's normal cell (`cell_mm`, 8 mm), and a cell-size STEP to half of it at
//     x 19 where the type allows one: Doubled (the dyadic ladder, nodes shared) or, where
//     only that is allowed, Stepped (independent passes). A type allowed neither, and the
//     sheets (R5), keep one cell;
//   * a section narrower than the type's AESTHETIC hard floor (cells across its thinnest
//     dimension) goes SOLID, as in a run: the tongue at 8 mm cells is 1.5 cells across and
//     goes solid; at 4 mm it is 3 and is latticed. (The Structural bending floor depends
//     on the load and is certified only in a run.)
//   * the lattice reaches 1.5 mm into the plate, the wall and a solid tongue, so it bonds;
//   * any piece of lattice the cut leaves touching no solid is dropped and counted (a loose
//     speck would print as a loose speck).

#include "topopt/lattice_sample.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <functional>
#include <map>
#include <numeric>
#include <stdexcept>
#include <tuple>
#include <unordered_map>

#include "topopt/lattice.hpp"
#include "topopt/lattice_boundary.hpp"
#include "topopt/lattice_gen.hpp"
#include "topopt/lattice_types.hpp"
#include "topopt/tpms_gen.hpp"

namespace topopt {
namespace {

constexpr double kPi = 3.14159265358979323846;

// The coupon's numbers, stated once.
constexpr double kWallX = 3.0, kBodyEndX = 33.0, kEndX = 45.0;
constexpr double kWidthY = 40.0, kTongueY0 = 14.0, kTongueY1 = 26.0;
constexpr double kSpringZ = 15.0, kArcR = 20.0, kArcY = 20.0;
constexpr double kBond = 1.5;  // how far the lattice reaches into the solid beside it

double top_z(double y) {
  const double d = y - kArcY;
  return kSpringZ + std::sqrt(std::max(0.0, kArcR * kArcR - d * d));
}

// The y stations of the cross-section: the arc in 1-degree steps (chord error under a
// micron), with the tongue's edges inserted exactly.
std::vector<double> y_stations() {
  std::vector<double> ys;
  for (int k = 0; k <= 180; ++k) ys.push_back(kArcY - kArcR * std::cos(kPi * k / 180.0));
  ys.front() = 0.0;
  ys.back() = kWidthY;
  ys.push_back(kTongueY0);
  ys.push_back(kTongueY1);
  std::sort(ys.begin(), ys.end());
  std::vector<double> out;
  for (double y : ys)
    if (out.empty() || y - out.back() > 1e-6) out.push_back(y);
  return out;
}

// A closed, consistently wound, welded solid: the cross-section profile over y (vertical
// sides, arc top) from `zb` up, over x in [x0, xe(y)] where xe depends on the y strip.
// Built from strips between y stations; every strip uses the same x breakpoints (those
// inside its extent), so neighbouring strips share their edges and no T-junction arises.
struct Prism {
  TriangleMesh mesh;
  std::map<std::tuple<double, double, double>, int> id;
  int v(const Vec3& p) {
    const auto k = std::make_tuple(p.x, p.y, p.z);
    auto it = id.find(k);
    if (it != id.end()) return it->second;
    const int i = static_cast<int>(mesh.vertices.size());
    mesh.vertices.push_back(p);
    id.emplace(k, i);
    return i;
  }
  void tri(const Vec3& a, const Vec3& b, const Vec3& c, const Vec3& out) {
    const Vec3 u{b.x - a.x, b.y - a.y, b.z - a.z}, w{c.x - a.x, c.y - a.y, c.z - a.z};
    const Vec3 n{u.y * w.z - u.z * w.y, u.z * w.x - u.x * w.z, u.x * w.y - u.y * w.x};
    const double l = std::sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
    if (!(l > 1e-14)) return;
    if (n.x * out.x + n.y * out.y + n.z * out.z >= 0.0)
      mesh.triangles.push_back({v(a), v(b), v(c)});
    else
      mesh.triangles.push_back({v(a), v(c), v(b)});
  }
  void quad(const Vec3& a, const Vec3& b, const Vec3& c, const Vec3& d, const Vec3& out) {
    tri(a, b, c, out);
    tri(a, c, d, out);
  }
};

TriangleMesh profile_prism(double y_lo, double y_hi, double x0,
                           const std::function<double(double)>& xe_of, double zb,
                           const std::vector<double>& xbreaks) {
  std::vector<double> ys;
  for (double y : y_stations())
    if (y >= y_lo - 1e-9 && y <= y_hi + 1e-9) ys.push_back(y);
  Prism P;
  auto xs_in = [&](double xe) {
    std::vector<double> xs{x0};
    for (double x : xbreaks)
      if (x > x0 + 1e-9 && x < xe - 1e-9) xs.push_back(x);
    xs.push_back(xe);
    return xs;
  };
  const Vec3 up{0, 0, 1}, down{0, 0, -1}, mx{-1, 0, 0}, px{1, 0, 0}, my{0, -1, 0}, py{0, 1, 0};
  for (std::size_t s = 0; s + 1 < ys.size(); ++s) {
    const double ya = ys[s], yb = ys[s + 1];
    const double xe = xe_of(0.5 * (ya + yb));
    const std::vector<double> xs = xs_in(xe);
    const double za = top_z(ya), zb2 = top_z(yb);
    // The top's outward normal leans with the arc; its z component is always positive.
    const Vec3 top_out{0.0, -(zb2 - za), yb - ya};
    for (std::size_t i = 0; i + 1 < xs.size(); ++i) {
      P.quad({xs[i], ya, za}, {xs[i + 1], ya, za}, {xs[i + 1], yb, zb2}, {xs[i], yb, zb2},
             top_out);
      P.quad({xs[i], ya, zb}, {xs[i + 1], ya, zb}, {xs[i + 1], yb, zb}, {xs[i], yb, zb}, down);
    }
    P.quad({x0, ya, zb}, {x0, yb, zb}, {x0, yb, zb2}, {x0, ya, za}, mx);
    P.quad({xe, ya, zb}, {xe, yb, zb}, {xe, yb, zb2}, {xe, ya, za}, px);
    // The y faces: the outer two, and a step where the next strip's extent differs.
    auto yface = [&](double y, double xa, double xb, const Vec3& out) {
      const std::vector<double> xs2 = xs_in(xb);
      for (std::size_t i = 0; i + 1 < xs2.size(); ++i) {
        if (xs2[i + 1] <= xa + 1e-9) continue;
        P.quad({xs2[i], y, zb}, {xs2[i + 1], y, zb}, {xs2[i + 1], y, top_z(y)},
               {xs2[i], y, top_z(y)}, out);
      }
    };
    if (s == 0) yface(ya, x0, xe, my);
    if (s + 2 == ys.size()) yface(yb, x0, xe, py);
    if (s + 2 < ys.size()) {
      const double xn = xe_of(0.5 * (yb + ys[s + 2]));
      if (xn > xe + 1e-9) yface(yb, xe, xn, my);       // the next strip reaches further
      else if (xn < xe - 1e-9) yface(yb, xn, xe, py);  // this one does
    }
  }
  return P.mesh;
}

void emit_mesh(TriangleSink& sink, const TriangleMesh& m) {
  for (const auto& t : m.triangles)
    sink.add_triangle(m.vertices[static_cast<std::size_t>(t[0])],
                      m.vertices[static_cast<std::size_t>(t[1])],
                      m.vertices[static_cast<std::size_t>(t[2])]);
}

void emit_box(TriangleSink& sink, const Vec3& lo, const Vec3& hi) {
  const Vec3 p[8] = {{lo.x, lo.y, lo.z}, {hi.x, lo.y, lo.z}, {hi.x, hi.y, lo.z},
                     {lo.x, hi.y, lo.z}, {lo.x, lo.y, hi.z}, {hi.x, lo.y, hi.z},
                     {hi.x, hi.y, hi.z}, {lo.x, hi.y, hi.z}};
  const int f[12][3] = {{0, 2, 1}, {0, 3, 2}, {4, 5, 6}, {4, 6, 7}, {0, 1, 5}, {0, 5, 4},
                        {2, 3, 7}, {2, 7, 6}, {1, 2, 6}, {1, 6, 5}, {3, 0, 4}, {3, 4, 7}};
  for (const auto& t : f) sink.add_triangle(p[t[0]], p[t[1]], p[t[2]]);
}

std::string num(double v) {
  char b[64];
  std::snprintf(b, sizeof b, "%.6g", v);
  return b;
}

// Buffers the lattice, element by element (struts) or as one welded surface (sheets), so
// a piece touching no solid can be dropped before anything is written.
struct Buffer : TriangleSink {
  std::vector<std::array<Vec3, 3>> tris;
  std::vector<std::size_t> element_end;  // struts: the triangle count after each element
  struct Element { Vec3 a, b; double r; };
  std::vector<Element> elements;
  void add_triangle(const Vec3& a, const Vec3& b, const Vec3& c) override {
    tris.push_back({a, b, c});
  }
};

struct UnionFind {
  std::vector<int> p;
  explicit UnionFind(std::size_t n) : p(n) { std::iota(p.begin(), p.end(), 0); }
  int find(int x) {
    while (p[static_cast<std::size_t>(x)] != x) {
      p[static_cast<std::size_t>(x)] = p[static_cast<std::size_t>(p[static_cast<std::size_t>(x)])];
      x = p[static_cast<std::size_t>(x)];
    }
    return x;
  }
  void unite(int a, int b) {
    a = find(a);
    b = find(b);
    if (a != b) p[static_cast<std::size_t>(std::max(a, b))] = std::min(a, b);
  }
};

double seg_seg_distance(const Vec3& p1, const Vec3& q1, const Vec3& p2, const Vec3& q2) {
  // Ericson, Real-Time Collision Detection, 5.1.9.
  const Vec3 d1{q1.x - p1.x, q1.y - p1.y, q1.z - p1.z}, d2{q2.x - p2.x, q2.y - p2.y, q2.z - p2.z};
  const Vec3 r{p1.x - p2.x, p1.y - p2.y, p1.z - p2.z};
  auto dot = [](const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; };
  const double a = dot(d1, d1), e = dot(d2, d2), f = dot(d2, r);
  double s = 0.0, t = 0.0;
  if (a <= 1e-18 && e <= 1e-18) {
  } else if (a <= 1e-18) {
    t = std::clamp(f / e, 0.0, 1.0);
  } else {
    const double c = dot(d1, r);
    if (e <= 1e-18) {
      s = std::clamp(-c / a, 0.0, 1.0);
    } else {
      const double b = dot(d1, d2), den = a * e - b * b;
      s = den > 1e-18 ? std::clamp((b * f - c * e) / den, 0.0, 1.0) : 0.0;
      t = (b * s + f) / e;
      if (t < 0.0) { t = 0.0; s = std::clamp(-c / a, 0.0, 1.0); }
      else if (t > 1.0) { t = 1.0; s = std::clamp((b - c) / a, 0.0, 1.0); }
    }
  }
  const Vec3 c1{p1.x + d1.x * s, p1.y + d1.y * s, p1.z + d1.z * s};
  const Vec3 c2{p2.x + d2.x * t, p2.y + d2.y * t, p2.z + d2.z * t};
  return std::sqrt(dot({c1.x - c2.x, c1.y - c2.y, c1.z - c2.z}, {c1.x - c2.x, c1.y - c2.y, c1.z - c2.z}));
}

}  // namespace

// ★ The coupon's OUTLINE as one closed solid (ruling 11-08 (A)): the shape a run lattices
// when the coupon is the part -- the wall, the body and the tongue under one surface, plate
// included -- so the rim on its sharp edges can be printed and checked on the same block.
TriangleMesh lattice_coupon_solid() {
  return profile_prism(
      0.0, kWidthY, 0.0,
      [](double y) { return y > kTongueY0 && y < kTongueY1 ? kEndX : kBodyEndX; }, 0.0,
      {kWallX, kBodyEndX});
}

LatticeSampleReceipt write_lattice_coupon(const LatticeSampleSpec& spec, TriangleSink& sink) {
  const LatticeGenTopology gt = lattice_gen_topology_from_id(spec.topology);
  const LatticeTopology t = lattice_gen_certificate_topology(gt);
  const bool sheet = lattice_gen_is_sheet(gt);
  const double L = spec.cell_mm;
  if (!(L > 0.0) || !(spec.plate_mm >= 0.0))
    throw std::invalid_argument("lattice-sample: cell must be > 0 and plate >= 0");
  const LatticeTypeFacts facts = lattice_type_facts(spec.topology);
  const double floor_cells = facts.aesthetic_hard_floor_cells;
  const double body_member = std::min(kWidthY, top_z(kArcY) - spec.plate_mm);
  if (body_member / L < floor_cells)
    throw std::invalid_argument(
        "lattice-sample: a " + num(L) + " mm cell leaves the coupon's body " +
        num(body_member / L) + " cells across its thinnest dimension, under " +
        spec.topology + "'s floor of " + num(floor_cells) + " cells. Use a smaller --cell.");
  const double bead = spec.bead_mm > 0.0 ? spec.bead_mm : 0.42;
  const double plate = spec.plate_mm;
  const double z0 = plate;  // the lattice body stands on the plate

  LatticeSampleReceipt r;
  r.topology = spec.topology;
  r.shape = "coupon";
  r.band_min = lattice_rho_min(t);
  r.band_max = lattice_rho_max(t);
  r.cell_mm = L;
  r.plate_mm = plate;
  r.bead_mm = bead;
  r.size_mm = kEndX;
  r.coupon_dims_mm = {kEndX, kWidthY, top_z(kArcY)};
  r.rho_lo = spec.rho_lo > 0.0 ? spec.rho_lo : r.band_min;
  r.rho_hi = spec.rho_hi > 0.0 ? spec.rho_hi : r.band_max;
  if (!(r.rho_lo >= r.band_min - 1e-12 && r.rho_hi <= r.band_max + 1e-12 && r.rho_lo <= r.rho_hi))
    throw std::invalid_argument("lattice-sample: the coupon's density range must lie in " +
                                spec.topology + "'s band [" + num(r.band_min) + ", " +
                                num(r.band_max) + "]");

  // The cell-size step: Doubled where allowed, else Stepped where allowed, else none.
  const double fine = 0.5 * L, x_step = kWallX + 2.0 * L;
  if (spec.step && !sheet && facts.doubled.allowed) r.step = "doubled";
  else if (spec.step && !sheet && facts.stepped.allowed) r.step = "stepped";
  else r.step = "none";
  if (r.step != "none" && x_step >= kEndX - fine)
    r.step = "none";  // a cell so large that no fine cell would fit past the step
  r.step_at_x_mm = r.step == "none" ? 0.0 : x_step;
  r.step_reason = r.step != "none" ? ""
                  : sheet ? "a sheet keeps one cell per region (R5)"
                  : !spec.step ? "not asked for"
                  : facts.stepped.reason.empty() ? facts.doubled.reason : facts.stepped.reason;
  const double tongue_cell = r.step == "none" ? L : fine;
  const double tongue_w = kTongueY1 - kTongueY0;
  r.tongue_latticed = tongue_w / tongue_cell >= floor_cells;
  r.tongue_reason =
      r.tongue_latticed ? ""
                        : "the tongue is " + num(tongue_w / tongue_cell) + " cells across (" +
                              num(tongue_w) + " mm at " + num(tongue_cell) + " mm), under " +
                              spec.topology + "'s floor of " + num(floor_cells) +
                              " cells, so it is solid, as in a run";

  // The density at a point: graded along x, never below one bead at the local cell.
  auto rho_bead = [&](double cell) {
    return std::clamp(lattice_density_from_strut(t, cell, 0.5 * bead), r.band_min, r.band_max);
  };
  const double rb_coarse = rho_bead(L), rb_fine = rho_bead(fine);
  auto rho_at = [&, rb_coarse, rb_fine](double x, double cell) {
    const double f = std::clamp((x - kWallX) / (kEndX - kWallX), 0.0, 1.0);
    const double lin = r.rho_lo + (r.rho_hi - r.rho_lo) * f;
    return std::clamp(std::max(lin, cell < L ? rb_fine : rb_coarse), r.band_min, r.band_max);
  };
  r.rho = rho_at(kWallX, L);
  r.strut_diameter_mm = lattice_strut_diameter_mm(t, r.rho, L);  // the thinnest, at the wall

  // ── the solid parts ─────────────────────────────────────────────────────────────
  const std::vector<double> xb{kWallX, kBodyEndX, kBodyEndX + kBond, kEndX};
  if (plate > 0.0) {
    emit_box(sink, {0.0, 0.0, 0.0}, {kBodyEndX, kWidthY, plate});
    emit_box(sink, {kBodyEndX, kTongueY0, 0.0}, {kEndX, kTongueY1, plate});
    r.triangles += 24;
  }
  {
    const TriangleMesh wall =
        profile_prism(0.0, kWidthY, 0.0, [](double) { return kWallX; }, z0, xb);
    emit_mesh(sink, wall);
    r.triangles += wall.triangles.size();
  }
  if (!r.tongue_latticed) {
    const TriangleMesh tongue = profile_prism(
        kTongueY0, kTongueY1, kBodyEndX, [](double) { return kEndX; }, z0, xb);
    emit_mesh(sink, tongue);
    r.triangles += tongue.triangles.size();
  }

  // ── the lattice's region: the body (and a latticed tongue), reaching kBond into the
  //    plate, the wall and a solid tongue so it bonds to each ─────────────────────
  const bool tl = r.tongue_latticed;
  const TriangleMesh body = profile_prism(
      0.0, kWidthY, kWallX - kBond,
      [tl](double y) {
        const bool in_tongue = y > kTongueY0 && y < kTongueY1;
        return in_tongue ? (tl ? kEndX : kBodyEndX + kBond) : kBodyEndX;
      },
      z0 - 0.5 * kBond, xb);
  LatticeBoundary B;
  B.set_shell_base(&body);
  auto in_solid = [&](const Vec3& p, double r_) {
    if (p.z - r_ < z0) return true;      // the plate
    if (p.x - r_ < kWallX) return true;  // the wall
    if (!tl && p.x + r_ > kBodyEndX && p.y + r_ > kTongueY0 && p.y - r_ < kTongueY1)
      return true;                       // the solid tongue
    return false;
  };

  Buffer buf;
  const double ox = kWallX - L, oz = z0 - L;
  const int ny = static_cast<int>(std::ceil(kWidthY / L));
  const int nx = static_cast<int>(std::ceil((kEndX + kBond - ox) / L));
  const int nz = static_cast<int>(std::ceil((top_z(kArcY) - oz) / L));
  if (sheet) {
    // One cell; shifted an eighth of a cell as the cube is, so the cut planes x 3, y 0 and
    // z (plate) sit mid-channel.
    const double s = L / 8.0;
    TpmsRegion TR;
    TR.anchor = {ox - s, -s, oz - s};
    TR.nx = nx + 1; TR.ny = ny + 1; TR.nz = nz + 1;
    TR.cell_mm = L;
    // The body as an analytic distance (positive inside): the arc-topped profile, the floor,
    // and the plan (the body's rectangle and the tongue's, a union). The exact distance to
    // its mesh would be evaluated at every one of the contouring's samples.
    const double x0 = kWallX - kBond, xt = tl ? kEndX : kBodyEndX + kBond, zb = z0 - 0.5 * kBond;
    TR.clip = [x0, xt, zb](const Vec3& p) {
      const double dz = std::max(p.z - kSpringZ, 0.0);
      const double prof = kArcR - std::sqrt((p.y - kArcY) * (p.y - kArcY) + dz * dz);
      const double a = std::min({p.x - x0, kBodyEndX - p.x, p.y, kWidthY - p.y});
      const double b = std::min({p.x - x0, xt - p.x, p.y - kTongueY0, kTongueY1 - p.y});
      return std::min({prof, p.z - zb, std::max(a, b)});
    };
    auto true_wall = [&](const Vec3& p) { return lattice_strut_diameter_mm(t, rho_at(p.x, L), L); };
    TpmsWallField W;
    W.field = [&](const Vec3& p) { return lattice_sheet_wall_param_mm(t, true_wall(p), L); };
    TpmsGenOptions o;
    o.min_wall_mm = r.strut_diameter_mm;
    o.dc_cell_mm = r.strut_diameter_mm / 3.0;
    o.max_deviation_mm = kSheetMaxDeviationMm;
    o.bead_mm = bead;
    o.true_wall_mm = true_wall;
    o.wall_param_of = [t, L](double w) { return lattice_sheet_wall_param_mm(t, w, L); };
    const TpmsGenStats ts = generate_tpms(
        gt == LatticeGenTopology::Gyroid ? TpmsKind::Gyroid : TpmsKind::SchwarzD, TR, W, buf, o);
    r.lattice_triangles_contoured = static_cast<unsigned long long>(ts.simplify.triangles_in);
    r.max_deviation_mm = std::max(ts.simplify.max_out_measured_mm, ts.simplify.max_in_measured_mm);
    r.cut_max_deviation_mm = std::max(ts.simplify.cut_max_out_mm, ts.simplify.cut_max_in_mm);
    // Pieces: triangles joined through shared (welded) vertices.
    std::unordered_map<std::uint64_t, std::vector<std::pair<Vec3, int>>> weld;
    UnionFind uf(buf.tris.size());
    std::vector<char> anchored(buf.tris.size(), 0);
    for (std::size_t i = 0; i < buf.tris.size(); ++i)
      for (const Vec3& p : buf.tris[i]) {
        std::uint64_t h = 1469598103934665603ull;
        for (double d : {p.x, p.y, p.z}) {
          std::uint64_t b;
          std::memcpy(&b, &d, sizeof b);
          h = (h ^ b) * 1099511628211ull;
        }
        auto& bucket = weld[h];
        bool found = false;
        for (auto& [q, ti] : bucket)
          if (q.x == p.x && q.y == p.y && q.z == p.z) {
            uf.unite(static_cast<int>(i), ti);
            found = true;
            break;
          }
        if (!found) bucket.push_back({p, static_cast<int>(i)});
        if (in_solid(p, 0.0)) anchored[i] = 1;
      }
    std::vector<char> root_ok(buf.tris.size(), 0);
    for (std::size_t i = 0; i < buf.tris.size(); ++i)
      if (anchored[i]) root_ok[static_cast<std::size_t>(uf.find(static_cast<int>(i)))] = 1;
    std::vector<char> seen(buf.tris.size(), 0);
    for (std::size_t i = 0; i < buf.tris.size(); ++i) {
      const std::size_t root = static_cast<std::size_t>(uf.find(static_cast<int>(i)));
      if (root_ok[root]) {
        sink.add_triangle(buf.tris[i][0], buf.tris[i][1], buf.tris[i][2]);
        ++r.lattice_triangles;
      } else {
        ++r.loose_triangles_dropped;
        if (!seen[root]) { seen[root] = 1; ++r.loose_pieces_dropped; }
      }
    }
  } else {
    LatticeGenObserver obs;
    obs.on_element = [&buf](LatticeGenElement, const Vec3& a, const Vec3& b, double rr) {
      buf.elements.push_back({a, b, rr});
      buf.element_end.push_back(buf.tris.size());
    };
    auto radius_for = [&](double cell) {
      LatticeRadiusField G;
      G.uniform_mm = 0.5 * lattice_strut_diameter_mm(t, rho_at(kWallX, cell), cell);
      G.field = [&, cell](Vec3 p) {
        return 0.5 * lattice_strut_diameter_mm(t, rho_at(p.x, cell), cell);
      };
      return G;
    };
    LatticeGenStats st;
    if (r.step == "doubled") {
      LatticeRegion base;
      base.origin = {ox, 0.0, oz};
      base.nx = 2 * nx; base.ny = 2 * ny; base.nz = 2 * nz;
      base.cell_mm = fine;
      base.boundary = &B;
      std::vector<LatticeLevelSpec> levels(2);
      levels[0].level = 0;
      levels[0].cell_mm = fine;
      levels[0].latticed = [ox, fine, x_step](int i, int, int) { return ox + i * fine >= x_step - 1e-9; };
      levels[0].radius = radius_for(fine);
      levels[1].level = 1;
      levels[1].cell_mm = L;
      levels[1].latticed = [ox, L, x_step](int i, int, int) { return ox + (i + 1) * L <= x_step + 1e-9; };
      levels[1].radius = radius_for(L);
      st = generate_lattice_multilevel(gt, base, levels, buf, LatticeSkinSpec{}, &obs);
    } else if (r.step == "stepped") {
      std::vector<LatticeSteppedPass> passes(2);
      for (int k = 0; k < 2; ++k) {
        const double c = k == 0 ? L : fine;
        LatticeRegion& R = passes[static_cast<std::size_t>(k)].region;
        R.origin = {ox, 0.0, oz};
        R.cell_mm = c;
        R.nx = k == 0 ? nx : 2 * nx; R.ny = k == 0 ? ny : 2 * ny; R.nz = k == 0 ? nz : 2 * nz;
        R.boundary = &B;
        if (k == 0) R.latticed = [ox, c, x_step](int i, int, int) { return ox + (i + 1) * c <= x_step + 1e-9; };
        else R.latticed = [ox, c, x_step](int i, int, int) { return ox + i * c >= x_step - 1e-9; };
        passes[static_cast<std::size_t>(k)].radius = radius_for(c);
      }
      st = generate_lattice_stepped(gt, passes, buf, LatticeSkinSpec{}, &obs);
    } else {
      LatticeRegion R;
      R.origin = {ox, 0.0, oz};
      R.nx = nx; R.ny = ny; R.nz = nz;
      R.cell_mm = L;
      R.boundary = &B;
      st = generate_lattice(gt, R, radius_for(L), buf, LatticeSkinSpec{}, &obs);
    }
    // Pieces: elements that touch (the prism's flat sides lie 0.924 r from its axis, so
    // two elements touch where their axes are closer than 0.92 of their radii's sum).
    const std::size_t ne = buf.elements.size();
    UnionFind uf(ne);
    const double hcell = std::max(fine, 1.0);
    std::unordered_map<long long, std::vector<int>> hash;
    auto key = [&](int i, int j, int k) {
      return (static_cast<long long>(i) * 73856093LL) ^ (static_cast<long long>(j) * 19349663LL) ^
             (static_cast<long long>(k) * 83492791LL);
    };
    for (std::size_t e = 0; e < ne; ++e) {
      const auto& E = buf.elements[e];
      const int i0 = static_cast<int>(std::floor((std::min(E.a.x, E.b.x) - E.r) / hcell)),
                i1 = static_cast<int>(std::floor((std::max(E.a.x, E.b.x) + E.r) / hcell));
      const int j0 = static_cast<int>(std::floor((std::min(E.a.y, E.b.y) - E.r) / hcell)),
                j1 = static_cast<int>(std::floor((std::max(E.a.y, E.b.y) + E.r) / hcell));
      const int k0 = static_cast<int>(std::floor((std::min(E.a.z, E.b.z) - E.r) / hcell)),
                k1 = static_cast<int>(std::floor((std::max(E.a.z, E.b.z) + E.r) / hcell));
      for (int i = i0; i <= i1; ++i)
        for (int j = j0; j <= j1; ++j)
          for (int k = k0; k <= k1; ++k) {
            auto& cellv = hash[key(i, j, k)];
            for (int o : cellv) {
              const auto& F = buf.elements[static_cast<std::size_t>(o)];
              if (seg_seg_distance(E.a, E.b, F.a, F.b) < 0.92 * (E.r + F.r))
                uf.unite(static_cast<int>(e), o);
            }
            cellv.push_back(static_cast<int>(e));
          }
    }
    std::vector<char> root_ok(ne, 0);
    for (std::size_t e = 0; e < ne; ++e) {
      const auto& E = buf.elements[e];
      if (in_solid(E.a, E.r) || in_solid(E.b, E.r))
        root_ok[static_cast<std::size_t>(uf.find(static_cast<int>(e)))] = 1;
    }
    std::vector<char> seen(ne, 0);
    std::size_t from = 0;
    for (std::size_t e = 0; e < ne; ++e) {
      const std::size_t to = buf.element_end[e];
      const std::size_t root = static_cast<std::size_t>(uf.find(static_cast<int>(e)));
      for (std::size_t i = from; i < to; ++i) {
        if (root_ok[root]) {
          sink.add_triangle(buf.tris[i][0], buf.tris[i][1], buf.tris[i][2]);
          ++r.lattice_triangles;
        } else {
          ++r.loose_triangles_dropped;
        }
      }
      if (!root_ok[root] && !seen[root]) { seen[root] = 1; ++r.loose_pieces_dropped; }
      from = to;
    }
    r.struts = st.struts;
    r.nodes = st.nodes;
  }
  r.triangles += r.lattice_triangles;
  r.cells_per_side = 0;
  return r;
}

}  // namespace topopt
