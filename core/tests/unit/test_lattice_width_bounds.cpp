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
// ── §6 helpers (notes29): the periodic cell on a voxel grid, N a side, every strut a round capsule. ──
// Distance from each voxel's centre to the nearest strut axis (the cell's struts and their 26 neighbours' translates,
// so the grid is periodic), in cell units; only within 0.75 of an axis (more than any limit read here).
std::vector<float> voxel_distance(const StrutCell& c, int N) {
  std::vector<Seg> segs;
  for (int dz = -1; dz <= 1; ++dz)
    for (int dy = -1; dy <= 1; ++dy)
      for (int dx = -1; dx <= 1; ++dx)
        for (const Seg& s : unit_struts(c))
          segs.push_back({{s.a[0] + dx, s.a[1] + dy, s.a[2] + dz}, {s.b[0] + dx, s.b[1] + dy, s.b[2] + dz}});
  std::vector<float> dist(static_cast<std::size_t>(N) * N * N, 1e9f);
  const double h = 1.0 / N, reach = 0.75;
  for (const Seg& s : segs) {
    int lo[3], hi[3];
    for (int k = 0; k < 3; ++k) {
      lo[k] = std::max(0, static_cast<int>(std::floor((std::min(s.a[k], s.b[k]) - reach) / h)));
      hi[k] = std::min(N - 1, static_cast<int>(std::ceil((std::max(s.a[k], s.b[k]) + reach) / h)));
    }
    V3 u;
    for (int k = 0; k < 3; ++k) u[k] = s.b[k] - s.a[k];
    const double uu = u[0] * u[0] + u[1] * u[1] + u[2] * u[2];
    for (int z = lo[2]; z <= hi[2]; ++z)
      for (int y = lo[1]; y <= hi[1]; ++y)
        for (int x = lo[0]; x <= hi[0]; ++x) {
          const V3 w{(x + 0.5) * h - s.a[0], (y + 0.5) * h - s.a[1], (z + 0.5) * h - s.a[2]};
          const double t = std::clamp((w[0] * u[0] + w[1] * u[1] + w[2] * u[2]) / uu, 0.0, 1.0);
          double d = 0.0;
          for (int k = 0; k < 3; ++k) d += (w[k] - t * u[k]) * (w[k] - t * u[k]);
          float& e = dist[(static_cast<std::size_t>(z) * N + y) * N + x];
          e = std::min(e, static_cast<float>(std::sqrt(d)));
        }
  }
  return dist;
}
// The void (voxels farther than r from every axis) runs through the lattice: a 6-connected void cluster of the
// periodic grid reaches the same voxel again a whole period away (its unwrapped coordinates differ).
bool void_runs_through(const std::vector<float>& dist, int N, double r) {
  const std::size_t n = static_cast<std::size_t>(N) * N * N;
  const int kNone = -(1 << 30);
  std::vector<int> ux(n, kNone), uy(n, 0), uz(n, 0);
  std::vector<std::size_t> stack;
  static const int D[6][3] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}};
  for (std::size_t s0 = 0; s0 < n; ++s0) {
    if (dist[s0] <= r || ux[s0] != kNone) continue;
    ux[s0] = static_cast<int>(s0 % N);
    uy[s0] = static_cast<int>((s0 / N) % N);
    uz[s0] = static_cast<int>(s0 / (static_cast<std::size_t>(N) * N));
    stack.assign(1, s0);
    while (!stack.empty()) {
      const std::size_t c = stack.back();
      stack.pop_back();
      for (const auto& d : D) {
        const int x = ux[c] + d[0], y = uy[c] + d[1], z = uz[c] + d[2];
        const std::size_t q =
            (static_cast<std::size_t>(((z % N) + N) % N) * N + ((y % N) + N) % N) * N + ((x % N) + N) % N;
        if (dist[q] <= r) continue;
        if (ux[q] == kNone) { ux[q] = x; uy[q] = y; uz[q] = z; stack.push_back(q); }
        else if (ux[q] != x || uy[q] != y || uz[q] != z) return true;
      }
    }
  }
  return false;
}
// Seen square-on to a cell face (each axis in turn), some line of sight through the cell is void all the way: the
// periodic lattice repeats along the view, so one cell's depth is any whole number of cells.
bool see_through_at(const std::vector<float>& dist, int N, double r) {
  for (int ax = 0; ax < 3; ++ax)
    for (int i = 0; i < N; ++i)
      for (int j = 0; j < N; ++j) {
        bool open = true;
        for (int k = 0; k < N && open; ++k) {
          int p[3];
          p[ax] = k; p[(ax + 1) % 3] = i; p[(ax + 2) % 3] = j;
          open = dist[(static_cast<std::size_t>(p[2]) * N + p[1]) * N + p[0]] > r;
        }
        if (open) return true;
      }
  return false;
}
// The diameter over cell at which `open_at` (given the radius) first fails, by bisection.
template <class F>
double closes_at(F open_at) {
  double lo = 0.0, hi = 1.5;
  for (int it = 0; it < 30; ++it) {
    const double m = 0.5 * (lo + hi);
    (open_at(0.5 * m) ? lo : hi) = m;
  }
  return 0.5 * (lo + hi);
}
}  // namespace

int main() {
  // §1 every strut type's touch is the smaller of its two gaps, recomputed from its cell.
  // (The tetragonal three since 2026-11-24: their cells are the family study's, laid by the new engine in Aesthetic.)
  for (LatticeTopology t : {LatticeTopology::Octet, LatticeTopology::SimpleCubic, LatticeTopology::Bcc,
                            LatticeTopology::Fcc, LatticeTopology::Diamond, LatticeTopology::Kelvin,
                            LatticeTopology::Rhombic, LatticeTopology::Bccz, LatticeTopology::Fccz,
                            LatticeTopology::Reentrant}) {
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

  // §5 the tetragonal three: their numbers as lattice.hpp states them (bccz bcc's own 1/sqrt 2; fccz 1/2 in 3D,
  // under fcc's 1/sqrt 3: a column passes nearer a leg than two legs pass; reentrant 1/3 in 3D, its face view 1/sqrt 5).
  check(lattice_width_bounds(LatticeTopology::Bccz).touch == lattice_width_bounds(LatticeTopology::Bcc).touch,
        "§5 bccz touches where bcc does");
  check(std::fabs(gap_3d(lattice_strut_cell(LatticeTopology::Fccz)) - 0.5) < 1e-12 &&
            std::fabs(gap_face_view(lattice_strut_cell(LatticeTopology::Fccz)) - 1.0 / std::sqrt(2.0)) < 1e-12,
        "§5 fccz: 3D gap 1/2, face view 1/sqrt 2");
  check(std::fabs(gap_3d(lattice_strut_cell(LatticeTopology::Reentrant)) - 1.0 / 3.0) < 1e-12 &&
            std::fabs(gap_face_view(lattice_strut_cell(LatticeTopology::Reentrant)) - 1.0 / std::sqrt(5.0)) < 1e-12,
        "§5 reentrant: 3D gap 1/3, face view 1/sqrt 5");
  // §6 (notes29, his notes on release 20: "find the EXACT density and size at which each lattice type becomes a quilt
  // and limit both when 'Allow quilt' is turned off"). Each strut type's three events, MEASURED on its own periodic
  // cell at 128 voxels a side (VOXEL: a window shuts on the grid when no voxel centre in it is farther than the strut's
  // radius from every axis, so a measured value is never above the exact one and at most two voxels under it), against
  // lattice_quilt_limits' closed forms; touch recomputed exactly from the segments (§1's). Then the quilt's order
  // (touch first), the open look under all three (Allow quilt off never fuses, closes or hides the view), and the two
  // cells each limit gives the thinnest strut at a 0.45 mm line (two lines, 0.90 mm).
  {
    const int N = 128;
    const double under = 2.0 / N, over = 0.25 / N;
    std::printf("§6 where each strut type becomes a quilt (strut diameter / cell; VOXEL %d a side vs EXACT):\n", N);
    std::printf("  %-9s %8s %8s %8s %8s %8s %8s %9s | %s\n", "type", "touch", "channels", "(voxel)", "see", "(voxel)",
                "open", "open cell", "quilt cell (0.90 mm strut)");
    for (LatticeTopology t : {LatticeTopology::Octet, LatticeTopology::SimpleCubic, LatticeTopology::Bcc,
                              LatticeTopology::Fcc, LatticeTopology::Diamond, LatticeTopology::Kelvin,
                              LatticeTopology::Rhombic, LatticeTopology::Bccz, LatticeTopology::Fccz,
                              LatticeTopology::Reentrant}) {
      const std::string name = lattice_topology_name(t);
      const StrutCell& c = lattice_strut_cell(t);
      const LatticeQuiltLimits q = lattice_quilt_limits(t);
      const std::vector<float> dist = voxel_distance(c, N);
      const double ch = closes_at([&](double r) { return void_runs_through(dist, N, r); });
      const double see = closes_at([&](double r) { return see_through_at(dist, N, r); });
      const double open_cell = lattice_open_cell_mm(t, 0.90), quilt_cell = lattice_quilt_cell_mm(t, 0.90);
      std::printf("  %-9s %8.5f %8.5f %8.5f %8.5f %8.5f %8.5f %6.2f mm | %.2f mm\n", name.c_str(), q.touch, q.channels,
                  ch, q.see_through, see, q.open_look, open_cell, quilt_cell);
      check(q.touch == lattice_width_bounds(t).touch &&
                std::fabs(q.touch - std::min(gap_face_view(c), gap_3d(c))) < 1e-12,
            "§6 " + name + ": the quilt is the touch, recomputed from its own cell");
      check(ch <= q.channels + over && ch >= q.channels - under,
            "§6 " + name + ": the channels close where lattice_quilt_limits says (voxel)");
      check(see <= q.see_through + over && see >= q.see_through - under,
            "§6 " + name + ": the view closes where lattice_quilt_limits says (voxel)");
      check(q.touch <= q.channels + 1e-12, "§6 " + name + ": the struts touch before (or as) the channels close");
      check(q.open_look < q.touch && q.open_look < q.channels && q.open_look < q.see_through,
            "§6 " + name + ": Allow quilt off (the open look) stays under all three");
      check(std::fabs(open_cell - 0.90 / kLatticeOpenLookStrutPerCell) < 1e-12 &&
                std::fabs(quilt_cell - 0.90 / q.touch) < 1e-12 && open_cell > quilt_cell,
            "§6 " + name + ": the open cell and the quilt cell at 0.90 mm");
    }
    // RED CONTROL: the measurement tells a wrong limit. The octet's view stated 0.02 wider than it is would be caught
    // (the voxel value lies more than two voxels under it), and so would its channels stated at its touch.
    {
      const LatticeQuiltLimits q = lattice_quilt_limits(LatticeTopology::Octet);
      const std::vector<float> dist = voxel_distance(lattice_strut_cell(LatticeTopology::Octet), N);
      const double see = closes_at([&](double r) { return see_through_at(dist, N, r); });
      const double ch = closes_at([&](double r) { return void_runs_through(dist, N, r); });
      check(!(see >= q.see_through + 0.02 - under), "§6 control: a view stated 0.02 too wide would be caught");
      check(!(ch <= q.touch + over), "§6 control: channels stated at the touch would be caught");
    }
    bool sheet_refused = false;
    try { (void)lattice_quilt_limits(LatticeTopology::Gyroid); } catch (const std::invalid_argument&) { sheet_refused = true; }
    check(sheet_refused, "§6 a sheet type has no strut quilt: refused, never another type's");
  }
  std::printf("%s: %d checks, %d failures\n", g_fail ? "FAIL" : "PASS", g_checks, g_fail);
  return g_fail ? 1 : 0;
}
