// lattice_width_bounds (lattice.hpp): each type's open look and the width at which its
// lattice closes up, both as width over cell. Every strut type's "touch" is RECOMPUTED here
// from its canonical cell (strut_cell.hpp), so the stated numbers cannot drift from the
// geometry the generator lays; the sheets' are pinned to their own field (tpms.hpp).
#include "topopt/lattice.hpp"
#include "topopt/stepped_plan.hpp"
#include "topopt/strut_cell.hpp"
#include "topopt/tpms.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>

using namespace topopt;

static int g_fail = 0, g_checks = 0;
static void check(bool ok, const std::string& what) {
  ++g_checks;
  if (!ok) { ++g_fail; std::printf("FAIL: %s\n", what.c_str()); }
}

namespace {
using V3 = std::array<double, 3>;
struct Seg { V3 a, b; };

double d2(const V3& p, const V3& q) {
  return (p[0] - q[0]) * (p[0] - q[0]) + (p[1] - q[1]) * (p[1] - q[1]) + (p[2] - q[2]) * (p[2] - q[2]);
}

// Exact distance between two segments: the convex quadratic's minimum over the unit
// square, at its interior stationary point or on one of the four edges.
double seg_dist(const V3& p0, const V3& p1, const V3& q0, const V3& q1) {
  V3 u, v, w;
  for (int k = 0; k < 3; ++k) { u[k] = p1[k] - p0[k]; v[k] = q1[k] - q0[k]; w[k] = p0[k] - q0[k]; }
  auto dot = [](const V3& x, const V3& y) { return x[0] * y[0] + x[1] * y[1] + x[2] * y[2]; };
  const double a = dot(u, u), b = dot(u, v), c = dot(v, v), d = dot(u, w), e = dot(v, w);
  auto at = [&](double s, double t) {
    double r = 0;
    for (int k = 0; k < 3; ++k) { const double x = w[k] + s * u[k] - t * v[k]; r += x * x; }
    return std::sqrt(std::max(0.0, r));
  };
  auto cl = [](double x) { return std::min(1.0, std::max(0.0, x)); };
  double best = 1e300;
  const double den = a * c - b * b;
  if (den > 1e-12) {
    const double s = (b * e - c * d) / den, t = (a * e - b * d) / den;
    if (s >= 0 && s <= 1 && t >= 0 && t <= 1) best = at(s, t);
  }
  for (double s : {0.0, 1.0}) best = std::min(best, at(s, cl((b * s + e) / c)));
  for (double t : {0.0, 1.0}) best = std::min(best, at(cl((b * t - d) / a), t));
  return best;
}

std::vector<Seg> unit_struts(const StrutCell& c) {
  std::vector<Seg> out;
  const double S = c.S;
  for (const auto& s : c.struts)
    out.push_back({{s.a.x / S, s.a.y / S, s.a.z / S}, {s.b.x / S, s.b.y / S, s.b.z / S}});
  return out;
}

// In 3D: the smallest gap between two struts that share no node, over the cell and its
// 26 neighbours.
double gap_3d(const StrutCell& c) {
  const auto base = unit_struts(c);
  double best = 1e300;
  for (int dz = -1; dz <= 1; ++dz)
    for (int dy = -1; dy <= 1; ++dy)
      for (int dx = -1; dx <= 1; ++dx)
        for (std::size_t i = 0; i < base.size(); ++i)
          for (std::size_t j = 0; j < base.size(); ++j) {
            if (dx == 0 && dy == 0 && dz == 0 && j <= i) continue;
            const V3 o{double(dx), double(dy), double(dz)};
            V3 b0, b1;
            for (int k = 0; k < 3; ++k) { b0[k] = base[j].a[k] + o[k]; b1[k] = base[j].b[k] + o[k]; }
            const V3& a0 = base[i].a; const V3& a1 = base[i].b;
            if (d2(a0, b0) < 1e-18 || d2(a0, b1) < 1e-18 || d2(a1, b0) < 1e-18 || d2(a1, b1) < 1e-18)
              continue;  // a shared node is a junction, not a collision
            const double g = seg_dist(a0, a1, b0, b1);
            if (g > 1e-9) best = std::min(best, g);
          }
  return best;
}

// The face view: seen square-on to a cell face (each axis in turn), the smallest gap
// between two neighbouring PARALLEL struts of the front cell layer (depth 0..1) that run
// alongside one another. A strut along the view axis is a point there and is skipped.
double gap_face_view(const StrutCell& c) {
  const auto base = unit_struts(c);
  double best = 1e300;
  for (int ax = 0; ax < 3; ++ax) {
    const int o0 = (ax + 1) % 3, o1 = (ax + 2) % 3;
    struct S2 { double p[2], q[2]; };
    std::vector<S2> segs;
    for (int dz = -1; dz <= 2; ++dz)
      for (int dy = -1; dy <= 2; ++dy)
        for (int dx = -1; dx <= 2; ++dx)
          for (const Seg& s : base) {
            const V3 o{double(dx), double(dy), double(dz)};
            V3 A, B;
            for (int k = 0; k < 3; ++k) { A[k] = s.a[k] + o[k]; B[k] = s.b[k] + o[k]; }
            if (std::min(A[ax], B[ax]) < -1e-9 || std::max(A[ax], B[ax]) > 1 + 1e-9) continue;
            S2 t{{A[o0], A[o1]}, {B[o0], B[o1]}};
            if (std::fabs(t.p[0] - t.q[0]) < 1e-12 && std::fabs(t.p[1] - t.q[1]) < 1e-12) continue;
            segs.push_back(t);
          }
    for (std::size_t i = 0; i < segs.size(); ++i) {
      const S2& P = segs[i];
      if (std::min(P.p[0], P.q[0]) < 0 || std::min(P.p[0], P.q[0]) > 1 ||
          std::min(P.p[1], P.q[1]) < 0 || std::min(P.p[1], P.q[1]) > 1)
        continue;  // one copy of each strut: the one starting in the face's own square
      double u[2] = {P.q[0] - P.p[0], P.q[1] - P.p[1]};
      const double lu = std::hypot(u[0], u[1]);
      u[0] /= lu; u[1] /= lu;
      for (std::size_t j = 0; j < segs.size(); ++j) {
        if (i == j) continue;
        const S2& Q = segs[j];
        double v[2] = {Q.q[0] - Q.p[0], Q.q[1] - Q.p[1]};
        const double lv = std::hypot(v[0], v[1]);
        v[0] /= lv; v[1] /= lv;
        if (std::fabs(u[0] * v[1] - u[1] * v[0]) > 1e-9) continue;  // parallel only
        const double n[2] = {-u[1], u[0]};
        const double g = std::fabs((Q.p[0] - P.p[0]) * n[0] + (Q.p[1] - P.p[1]) * n[1]);
        if (g < 1e-9) continue;  // collinear: one line, not two struts side by side
        const double s0 = (Q.p[0] - P.p[0]) * u[0] + (Q.p[1] - P.p[1]) * u[1];
        const double s1 = (Q.q[0] - P.p[0]) * u[0] + (Q.q[1] - P.p[1]) * u[1];
        if (std::max(s0, s1) <= 1e-9 || std::min(s0, s1) >= lu - 1e-9) continue;  // alongside
        best = std::min(best, g);
      }
    }
  }
  return best;
}

// The true distance from p to the sheet's mid-surface (f = 0), period 1: the first zero
// crossing along each of n directions (the nearest surface point is reached by a straight
// ray), the shortest kept.
double distance_to_surface(TpmsKind kind, const V3& p, int n) {
  const double f0 = tpms_eval(kind, p[0], p[1], p[2], 1.0).f;
  double best = 1e300;
  const double golden = M_PI * (1.0 + std::sqrt(5.0));
  for (int i = 0; i < n; ++i) {
    const double ph = std::acos(1.0 - 2.0 * (i + 0.5) / n), th = golden * (i + 0.5);
    const V3 d{std::cos(th) * std::sin(ph), std::sin(th) * std::sin(ph), std::cos(ph)};
    auto f = [&](double s) { return tpms_eval(kind, p[0] + s * d[0], p[1] + s * d[1], p[2] + s * d[2], 1.0).f; };
    double s = 0.0;
    const double ds = 0.002;
    while (s < std::min(best, 0.5)) {
      if ((f(s + ds) > 0) != (f0 > 0)) {
        double lo = s, hi = s + ds;
        for (int k = 0; k < 60; ++k) { const double m = 0.5 * (lo + hi); ((f(m) > 0) != (f0 > 0) ? hi : lo) = m; }
        best = std::min(best, 0.5 * (lo + hi));
        break;
      }
      s += ds;
    }
  }
  return best;
}
}  // namespace

int main() {
  // §1 every strut type's touch is the smaller of its two gaps, recomputed from its cell.
  for (LatticeTopology t : {LatticeTopology::Octet, LatticeTopology::SimpleCubic, LatticeTopology::Bcc,
                            LatticeTopology::Fcc, LatticeTopology::Diamond, LatticeTopology::Kelvin,
                            LatticeTopology::Rhombic}) {
    const StrutCell& c = lattice_strut_cell(t);
    const double f = gap_face_view(c), q = gap_3d(c);
    const LatticeWidthBounds b = lattice_width_bounds(t);
    std::printf("%-8s face view %.6f  3D %.6f  touch %.6f  open look %.6f\n", lattice_topology_name(t), f,
                q, b.touch, b.open_look);
    check(std::fabs(b.touch - std::min(f, q)) < 1e-12,
          std::string("§1 ") + lattice_topology_name(t) + ": touch is the smaller gap of its own cell");
    // §2 the open look is one geometry for every strut type, the stepped bound's own number.
    check(b.open_look == kSteppedPrintsOpenMaxStrutPerCell,
          std::string("§2 ") + lattice_topology_name(t) + ": open look == kSteppedPrintsOpenMaxStrutPerCell");
    check(b.open_look < b.touch, std::string("§2 ") + lattice_topology_name(t) + ": open look under the touch");
  }
  // §1' octet's is the quilt the rebuild already holds (1/(2 sqrt 2)), and in 3D its struts
  // that share no node meet only at 1/2.
  check(lattice_width_bounds(LatticeTopology::Octet).touch == 1.0 / (2.0 * std::sqrt(2.0)),
        "§1' octet touch is 1/(2 sqrt 2)");
  check(std::fabs(gap_3d(lattice_strut_cell(LatticeTopology::Octet)) - 0.5) < 1e-12, "§1' octet 3D gap is 1/2");

  // §3 sheets: the open look is the true wall at the top of the resolved band.
  for (LatticeTopology t : {LatticeTopology::Gyroid, LatticeTopology::SchwarzD}) {
    const LatticeWidthBounds b = lattice_width_bounds(t);
    const double w = lattice_strut_diameter_mm(t, lattice_rho_max(t), 1.0);
    std::printf("%-9s open look %.6f (true wall at rho %.5f)  touch %.6f\n", lattice_topology_name(t),
                b.open_look, lattice_rho_max(t), b.touch);
    check(b.open_look == w, std::string("§3 ") + lattice_topology_name(t) + ": open look is the band-top wall");
    check(b.open_look < b.touch, std::string("§3 ") + lattice_topology_name(t) + ": open look under the touch");
  }
  // §4 the channels' throats, measured on the field itself.
  const double node = distance_to_surface(TpmsKind::Gyroid, {0.375, 0.125, 0.875}, 20000);
  const double edge = distance_to_surface(TpmsKind::Gyroid, {0.75, 0.375, 0.0}, 20000);
  std::printf("gyroid: clearance %.6f at a channel node, %.6f at an edge midpoint\n", node, edge);
  // 20,000 directions can only OVER-read the nearest surface point (each is a ray, the
  // nearest is between two): by up to ~2e-5 here, so the bound is one-sided at 1e-4.
  check(node >= std::sqrt(3.0) / 8.0 - 1e-9 && node < std::sqrt(3.0) / 8.0 + 1e-4,
        "§4 gyroid: the node's clearance is sqrt 3 / 8");
  check(edge > node + 0.01, "§4 gyroid: the channel widens from its node to its edge midpoint");
  check(std::fabs(lattice_width_bounds(LatticeTopology::Gyroid).touch - 2.0 * std::sqrt(3.0) / 8.0) < 1e-15,
        "§4 gyroid: touch is twice the node's clearance");
  const double saddle = distance_to_surface(TpmsKind::SchwarzD, {0.5, 0.25, 0.5}, 20000);
  std::printf("schwarz_d: clearance %.6f at a channel edge midpoint\n", saddle);
  const double dt = lattice_width_bounds(LatticeTopology::SchwarzD).touch;
  check(dt <= 2.0 * saddle && dt > 2.0 * saddle - 0.002,
        "§4 schwarz_d: touch is at most twice the edge midpoint's clearance, and within 0.002 of it");

  // §5 the tetragonal three have no cell: refused, by name.
  for (LatticeTopology t : {LatticeTopology::Bccz, LatticeTopology::Fccz, LatticeTopology::Reentrant}) {
    bool threw = false;
    try { (void)lattice_width_bounds(t); } catch (const std::invalid_argument& e) {
      threw = std::string(e.what()).find(lattice_topology_name(t)) != std::string::npos;
    }
    check(threw, std::string("§5 ") + lattice_topology_name(t) + " is refused by name");
  }
  std::printf("%s: %d checks, %d failures\n", g_fail ? "FAIL" : "PASS", g_checks, g_fail);
  return g_fail ? 1 : 0;
}
