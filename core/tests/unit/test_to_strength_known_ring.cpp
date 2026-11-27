// TO rebuild, repo test E (docs/design/to-rebuild/04-tests.md), second half.
//
// A thick ring with pressure on its inner face: inner radius 6 mm, outer 12 mm,
// free top and bottom. The stress is known from the textbook (Lame): at the
// inner face the hoop stress is p (ro^2 + ri^2) / (ro^2 - ri^2) = 5/3 p and the
// radial stress is -p, so the von Mises stress there is 7/3 p = 2.333 p. That
// is the peak. Unlike the plate with a hole, the whole loaded face is curved, so
// every part of it is stair-stepped in the grid.
//
// The pressure is put on by stage 1's drawn-face loader (face_loads.hpp): the
// inner cylinder is given as triangles, each node gets the area of drawn face it
// stands for, and the node force is pressure x that area along the face normal.
// Today's path has no way to put a pressure on a curved face, which is why this
// half waited for stage 1.
//
// Same resolutions (inner radius 3, 4, 5, 6 voxels), same three ways of
// treating a cut voxel, same fixed-size readings and same two forms (measure /
// --gate) as test_to_strength_known_stress.cpp.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#include "to_reference_reading.hpp"
#include "topopt/analyze.hpp"
#include "topopt/face_loads.hpp"
#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/simp.hpp"
#include "topopt/step.hpp"
#include "topopt/stress_measure.hpp"
#include "topopt/voxel.hpp"

using topopt::DirichletBC;
using topopt::NodalLoad;
using topopt::Vec3;
using topopt::VoxelGrid;

namespace {

// THE SWITCH POINT (the reviewer's ruling 2026-11-26, item 2): extra sizes read on
// the same solve, set by main() for one resolution at a time (mm in, reading out).
std::vector<double> g_switch_sizes_mm;
std::vector<double> g_switch_readings;

constexpr double kPressure = 10.0;  // MPa
constexpr double kTextbook = 7.0 / 3.0;
constexpr int kThickness = 2;       // voxels
constexpr int kSub = 8;
constexpr double kInnerMm = 6.0, kOuterMm = 12.0;
constexpr double kSizesMm[3] = {0.9, 1.8, 3.6};
constexpr int kSegments = 180;

struct Row {
  int radius_voxels = 0;
  double binary = 0.0, fill_cubed = 0.0, fill_linear = 0.0;
  double over_size[3] = {0.0, 0.0, 0.0};
  double area_error = 0.0;  // placed / drawn area - 1, worst arm
};

// The inner cylinder as triangles whose normal points OUT of the part, which
// for a hole is toward the axis.
topopt::StepModel inner_face(double cx, double cy, double height) {
  topopt::StepModel model;
  const double pi = std::acos(-1.0);
  for (int s = 0; s < kSegments; ++s) {
    const double a0 = 2.0 * pi * s / kSegments, a1 = 2.0 * pi * (s + 1) / kSegments;
    const Vec3 p00{cx + kInnerMm * std::cos(a0), cy + kInnerMm * std::sin(a0), 0.0};
    const Vec3 p10{cx + kInnerMm * std::cos(a1), cy + kInnerMm * std::sin(a1), 0.0};
    const Vec3 p01{p00.x, p00.y, height}, p11{p10.x, p10.y, height};
    const int b = static_cast<int>(model.mesh.vertices.size());
    for (const Vec3& p : {p00, p10, p01, p11}) model.mesh.vertices.push_back(p);
    // (p01 - p00) x (p10 - p00) = z x tangent = -radial: toward the axis.
    model.mesh.triangles.push_back({b, b + 2, b + 1});
    model.mesh.triangles.push_back({b + 1, b + 2, b + 3});
    model.triangle_face.push_back(0);
    model.triangle_face.push_back(0);
  }
  model.face_count = 1;
  return model;
}

// MEASURING ARM (stage 4's question, measured ahead 2026-11-27; not in the engine):
// the stress of the first FULL voxels behind the inner face carried out to the TRUE
// inner radius, along 32 rays: by a straight line through two voxels and by a curve
// through three. The largest over the rays, over the pressure. Filled by peak_ratio.
double g_carry_line = 0.0, g_carry_curve = 0.0;
// The engine's carry (stress_carried_to_surface) over the pressure, and its unresolved count.
double g_engine_carry = 0.0;
std::size_t g_engine_unresolved = 0;

double peak_ratio(int rv, bool exact_fill, double penalty, bool* ok, double* area_error,
                  double* over_size = nullptr) {
  const double h = kInnerMm / rv;
  const int w = 4 * rv + 4;  // outer diameter plus two voxels of air each side
  VoxelGrid g;
  g.nx = w;
  g.ny = w;
  g.nz = kThickness;
  g.spacing = h;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(w) * w * kThickness, topopt::VoxelTag::Empty);

  // Centre off the grid lines (in voxels), so nothing is symmetric by luck.
  const double cxv = 0.5 * w + 0.29, cyv = 0.5 * w - 0.41;
  const double ri = rv, ro = rv * kOuterMm / kInnerMm;
  std::vector<double> density(g.tags.size(), 0.0);
  for (int j = 0; j < w; ++j)
    for (int i = 0; i < w; ++i) {
      double v;
      if (exact_fill) {
        int in = 0;
        for (int b = 0; b < kSub; ++b)
          for (int a = 0; a < kSub; ++a) {
            const double r = std::hypot(i + (a + 0.5) / kSub - cxv, j + (b + 0.5) / kSub - cyv);
            if (r > ri && r < ro) ++in;
          }
        v = static_cast<double>(in) / (kSub * kSub);
      } else {
        const double r = std::hypot(i + 0.5 - cxv, j + 0.5 - cyv);
        v = (r > ri && r < ro) ? 1.0 : 0.0;
      }
      for (int k = 0; k < kThickness; ++k) {
        const std::size_t idx = (static_cast<std::size_t>(k) * w + j) * w + i;
        density[idx] = v;
        if (v > 0.0) g.tags[idx] = topopt::VoxelTag::Interior;
      }
    }

  // Pressure on the drawn inner face.
  const topopt::StepModel model = inner_face(cxv * h, cyv * h, kThickness * h);
  topopt::FaceAreaReport rep;
  const std::vector<topopt::NodeArea> areas =
      topopt::face_node_areas(g, topopt::face_pieces(model, {0}, 0.5 * h), &rep);
  *area_error = rep.drawn_area > 0.0 ? rep.placed_area / rep.drawn_area - 1.0 : -1.0;
  std::vector<NodalLoad> loads;
  for (const topopt::NodeArea& a : areas) {
    const double f = -kPressure * a.area;  // pressure pushes against the outward normal
    loads.push_back({a.node, 0, f * a.normal.x});
    loads.push_back({a.node, 1, f * a.normal.y});
  }

  // The pressure balances itself; hold only the six rigid motions, at three
  // nodes in the middle of the wall (angles 0, 180 and 90 degrees).
  const double rm = 1.5 * rv;
  auto node_at = [&](double xv, double yv) {
    return topopt::fea_node_index(g, static_cast<int>(std::lround(xv)),
                                  static_cast<int>(std::lround(yv)), 0);
  };
  const int a = node_at(cxv + rm, cyv), b = node_at(cxv - rm, cyv), c = node_at(cxv, cyv + rm);
  std::vector<DirichletBC> bcs;
  bcs.push_back({a, 0, 0.0});
  bcs.push_back({a, 1, 0.0});
  bcs.push_back({a, 2, 0.0});
  bcs.push_back({b, 1, 0.0});
  bcs.push_back({b, 2, 0.0});
  bcs.push_back({c, 2, 0.0});

  topopt::Material m;
  m.youngs_modulus_mpa = 3500.0;
  m.yield_strength_mpa = 55.0;
  m.density_g_cm3 = 1.24;
  m.z_knockdown = 1.0;
  m.poisson = 0.33;
  m.family = "fdm";

  topopt::SimpParams params;
  params.youngs_modulus = m.youngs_modulus_mpa;
  params.poisson = m.poisson;
  params.penalty = penalty;

  topopt::KnockdownSpec knockdown;
  // The cut voxels' stress too: a size is read with the ball free to sit on the
  // part's edge (stress_measure.hpp, "the edge of the part").
  knockdown.record_material_stress = true;
  const topopt::FixedDesignAnalysis res = topopt::analyze_fixed_design(
      g, params, density, bcs, loads, m, Vec3{0.0, 0.0, 1.0}, 1e-8, 20000,
      topopt::SolverKind::MultigridCG_Matfree, 0.0, knockdown, true,
      static_cast<double>(g.tags.size()));
  *ok = res.max_von_mises > 0.0 && std::isfinite(res.max_von_mises);
  g_switch_readings.clear();
  if (res.von_mises_material_field.size() == density.size())
    for (double mm : g_switch_sizes_mm)
      g_switch_readings.push_back(topopt::peak_stress_over_size_edge_and_surface(
                                      g, res.von_mises_material_field, density,
                                      topopt::kStressMaterialFloor, mm) /
                                  kPressure);
  if (over_size != nullptr && res.von_mises_material_field.size() == density.size())
    for (int q = 0; q < 3; ++q)
      over_size[q] = topopt::peak_stress_over_size(g, res.von_mises_material_field, density,
                                                   topopt::kStressMaterialFloor,
                                                   kSizesMm[q]) /
                     kPressure;
  g_carry_line = g_carry_curve = 0.0;
  if (res.von_mises_material_field.size() == density.size()) {
    const double pi = std::acos(-1.0);
    const int k = kThickness / 2;
    for (int s = 0; s < 32; ++s) {
      const double ang = 2.0 * pi * (s + 0.37) / 32.0;
      double rr[3] = {0, 0, 0}, vv[3] = {0, 0, 0};
      int got = 0, li = -1, lj = -1;
      for (double r = ri; r < ro && got < 3; r += 0.2) {
        const int i = static_cast<int>(std::floor(cxv + r * std::cos(ang)));
        const int j = static_cast<int>(std::floor(cyv + r * std::sin(ang)));
        if (i < 0 || j < 0 || i >= w || j >= w || (i == li && j == lj)) continue;
        const std::size_t idx = (static_cast<std::size_t>(k) * w + j) * w + i;
        if (density[idx] < 1.0) continue;
        li = i;
        lj = j;
        rr[got] = std::hypot(i + 0.5 - cxv, j + 0.5 - cyv);
        vv[got] = res.von_mises_material_field[idx];
        ++got;
      }
      if (got >= 2 && rr[1] > rr[0]) {
        const double line = vv[0] + (vv[1] - vv[0]) * (ri - rr[0]) / (rr[1] - rr[0]);
        g_carry_line = std::max(g_carry_line, line / kPressure);
      }
      if (got == 3 && rr[1] > rr[0] && rr[2] > rr[1]) {
        double curve = 0.0;  // the curve through three points, at ri
        for (int a2 = 0; a2 < 3; ++a2) {
          double l = 1.0;
          for (int b2 = 0; b2 < 3; ++b2)
            if (b2 != a2) l *= (ri - rr[b2]) / (rr[a2] - rr[b2]);
          curve += l * vv[a2];
        }
        g_carry_curve = std::max(g_carry_curve, curve / kPressure);
      }
    }
  }
  g_engine_carry = 0.0;
  g_engine_unresolved = 0;
  if (res.von_mises_material_field.size() == density.size()) {
    const topopt::SurfaceCarry sc =
        topopt::stress_carried_to_surface(g, res.von_mises_material_field, density);
    g_engine_carry = sc.peak / kPressure;
    g_engine_unresolved = sc.unresolved;
  }
  return res.max_von_mises / kPressure;
}

}  // namespace

int main(int argc, char** argv) {
  const bool gate = argc > 1 && std::strcmp(argv[1], "--gate") == 0;
  int failures = 0;
  std::vector<Row> rows;
  std::printf("[test E, ring] thick ring, pressure on the inner face; peak von Mises / "
              "pressure, textbook %.3f\n",
              kTextbook);
  std::printf("%-12s %9s %14s %16s %14s %9s %9s %9s %10s\n", "inner radius", "voxel mm",
              "all-or-nothing", "fill, E x fill^3", "fill, E x fill", "over 0.9", "over 1.8",
              "over 3.6", "area off %");
  for (int r : {3, 4, 5, 6}) {
    Row row;
    row.radius_voxels = r;
    bool ok1 = false, ok2 = false, ok3 = false;
    double e1 = 0.0, e2 = 0.0, e3 = 0.0;
    row.binary = peak_ratio(r, false, 3.0, &ok1, &e1);
    const double cb_line = g_carry_line, cb_curve = g_carry_curve;
    row.fill_cubed = peak_ratio(r, true, 3.0, &ok2, &e2);
    const double cc_line = g_carry_line, cc_curve = g_carry_curve;
    row.fill_linear = peak_ratio(r, true, 1.0, &ok3, &e3, row.over_size);
    std::printf("[carry] inner radius %d voxels: carried to the true inner face, straight line / curve, percent against the textbook: "
                "all-or-nothing %+.1f / %+.1f; E x fill^3 %+.1f / %+.1f; E x fill %+.1f / %+.1f; "
                "ENGINE (E x fill only): %+.1f %%, unresolved %zu\n",
                r, 100.0 * (cb_line / kTextbook - 1.0), 100.0 * (cb_curve / kTextbook - 1.0),
                100.0 * (cc_line / kTextbook - 1.0), 100.0 * (cc_curve / kTextbook - 1.0),
                100.0 * (g_carry_line / kTextbook - 1.0), 100.0 * (g_carry_curve / kTextbook - 1.0),
                100.0 * (g_engine_carry / kTextbook - 1.0), g_engine_unresolved);
    row.area_error = std::max({std::fabs(e1), std::fabs(e2), std::fabs(e3)});
    if (!ok1 || !ok2 || !ok3) ++failures;
    std::printf("%-12d %9.3f %14.3f %16.3f %14.3f %9.3f %9.3f %9.3f %10.2f\n", r,
                kInnerMm / r, row.binary, row.fill_cubed, row.fill_linear, row.over_size[0],
                row.over_size[1], row.over_size[2], 100.0 * row.area_error);
    rows.push_back(row);
  }
  auto band = [&](double Row::*f, const char* name) {
    double lo = 1e300, hi = 0.0, worst = 0.0;
    for (const Row& r : rows) {
      lo = std::min(lo, r.*f);
      hi = std::max(hi, r.*f);
      worst = std::max(worst, std::fabs(r.*f / kTextbook - 1.0));
    }
    const double spread = lo > 0.0 ? hi / lo - 1.0 : 9.99;
    const bool pass = worst <= 0.05 && spread <= 0.10;
    std::printf("%-18s worst miss from textbook %5.1f %%, spread across resolutions "
                "%5.1f %%  %s\n",
                name, 100.0 * worst, 100.0 * spread, pass ? "ok" : "outside rule 5");
    if (gate && !pass) ++failures;
  };
  band(&Row::binary, "all-or-nothing");
  band(&Row::fill_cubed, "fill, E x fill^3");
  band(&Row::fill_linear, "fill, E x fill");
  for (int q = 0; q < 3; ++q) {
    double lo = 1e300, hi = 0.0;
    for (const Row& r : rows) {
      lo = std::min(lo, r.over_size[q]);
      hi = std::max(hi, r.over_size[q]);
    }
    std::printf("read over %.1f mm   spread across resolutions %5.1f %%\n", kSizesMm[q],
                lo > 0.0 ? 100.0 * (hi / lo - 1.0) : 0.0);
  }
  // The pressure must reach the part whole: the loader's own rule (stage 1).
  for (const Row& r : rows)
    if (r.area_error > 0.01) {
      std::printf("inner radius %d: the loaded area is %.2f %% off the drawn face\n",
                  r.radius_voxels, 100.0 * r.area_error);
      ++failures;
    }
  // THE BAR (reviewer, 2026-11-26): the shipped reading may never read more than
  // 5 % BELOW the textbook at any resolution; stiffness and reading size are
  // judged together. Every pair of (how a cut voxel's stiffness goes with its
  // fill, the size the stress is read over), over the four resolutions.
  std::printf("\n[bar] lowest and highest reading against the textbook over the four resolutions, "
              "and their spread\n");
  std::printf("%-22s %-10s %10s %10s %10s  %s\n", "cut voxel stiffness", "read over", "lowest %",
              "highest %", "spread %", "never more than 5 % low?");
  for (double pen : {1.0, 2.0, 3.0}) {
    double lo[4] = {1e300, 1e300, 1e300, 1e300}, hi[4] = {0.0, 0.0, 0.0, 0.0};
    // Against the reading's OWN true value (the same average on the exact
    // solution): the lowest and highest miss over the resolutions.
    double own_lo[4] = {1e300, 1e300, 1e300, 1e300}, own_hi[4] = {-1e300, -1e300, -1e300, -1e300};
    for (int r : {3, 4, 5, 6}) {
      bool ok = false;
      double ae = 0.0;
      (void)ae;
      double os[3] = {0.0, 0.0, 0.0};
      const double peak = peak_ratio(r, true, pen, &ok, &ae, os);
      const double v[4] = {peak, os[0], os[1], os[2]};
      for (int q = 0; q < 4; ++q) {
        lo[q] = std::min(lo[q], v[q]);
        hi[q] = std::max(hi[q], v[q]);
        const double truth = q == 0 ? kTextbook : to_reference::ring_reading(kInnerMm, kOuterMm, kSizesMm[q - 1], kThickness * kInnerMm / r);
        own_lo[q] = std::min(own_lo[q], v[q] / truth - 1.0);
        own_hi[q] = std::max(own_hi[q], v[q] / truth - 1.0);
      }
    }
    const char* names[4] = {"one voxel", "0.9 mm", "1.8 mm", "3.6 mm"};
    for (int q = 0; q < 4; ++q)
      std::printf("E x fill^%-12.0f %-10s %+10.1f %+10.1f %10.1f  %s\n", pen, names[q],
                  100.0 * (lo[q] / kTextbook - 1.0), 100.0 * (hi[q] / kTextbook - 1.0),
                  100.0 * (hi[q] / lo[q] - 1.0), lo[q] >= 0.95 * kTextbook ? "yes" : "NO");
    for (int q = 1; q < 4; ++q)
      std::printf("E x fill^%-12.0f %-10s against the reading's own true value: %+6.1f to %+6.1f %%  %s\n",
                  pen, names[q], 100.0 * own_lo[q], 100.0 * own_hi[q],
                  own_lo[q] >= -0.05 ? "never more than 5 % low" : "more than 5 % low somewhere");
  }

  // THE SWITCH POINT: real stiffness (E x fill), the size chosen to span a stated
  // number of voxels at each resolution, against the reading's own true value.
  // The smallest span from which every resolution is inside the bar (never more
  // than 5 % low, within 10 % of one another) is where the reading over a size
  // may take over from the one-voxel form.
  {
    const double kSpans[8] = {1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0};
    const int kRes[4] = {3, 4, 5, 6};
    double off[8][4];
    for (int ri = 0; ri < 4; ++ri) {
      const int r = kRes[ri];
      const double voxel = kInnerMm / r;
      g_switch_sizes_mm.clear();
      for (double s : kSpans) g_switch_sizes_mm.push_back(s * voxel);
      bool ok = false;
      double unused[3] = {0.0, 0.0, 0.0}, ae = 0.0;
      (void)peak_ratio(r, true, 1.0, &ok, &ae, unused);
      for (int s = 0; s < 8; ++s) {
        const double mm = kSpans[s] * voxel;
        const double truth = to_reference::ring_reading(kInnerMm, kOuterMm, mm, kThickness * kInnerMm / r);
        off[s][ri] = s < static_cast<int>(g_switch_readings.size())
                         ? 100.0 * (g_switch_readings[static_cast<std::size_t>(s)] / truth - 1.0)
                         : -999.0;
      }
    }
    g_switch_sizes_mm.clear();
    std::printf("\n[switch] E x fill read over a size (voxel centres and surface nodes), by the voxels the size spans; percent against the "
                "reading's own true value at radius 3 / 4 / 5 / 6 voxels\n");
    for (int s = 0; s < 8; ++s) {
      double lo = 1e9, hi = -1e9;
      for (int ri = 0; ri < 4; ++ri) {
        lo = std::min(lo, off[s][ri]);
        hi = std::max(hi, off[s][ri]);
      }
      std::printf("[switch] %4.2f voxels across: %+6.1f %+6.1f %+6.1f %+6.1f   lowest %+6.1f, spread %5.1f  %s\n",
                  kSpans[s], off[s][0], off[s][1], off[s][2], off[s][3], lo, hi - lo,
                  lo >= -5.0 && hi - lo <= 10.0 ? "inside the bar" : "outside");
    }
  }

  std::printf("[test E, ring] %s: %d failure(s)\n", gate ? "gate" : "measure only", failures);
  return failures == 0 ? 0 : 1;
}
