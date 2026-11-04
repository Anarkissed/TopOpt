// Finding 8 (ruling 2026-11-02): bounded simplification of a contoured field.
//
//   §1 a sphere contoured and simplified to 0.02 mm: closed, manifold, consistently wound,
//      far fewer triangles, and an INDEPENDENT dense sampling of the output against the
//      exact distance stays within the bound;
//   §2 streamed in small slabs (several flushes): still closed and manifold, still bounded;
//   §3 the same input gives the same output (deterministic);
//   §4 max_in = 0 (a wall at the bead): contoured half the bound outward, the output never
//      cuts INTO the true surface;
//   §5 the sheet generator's simplified gyroid block: closed, manifold, the bound measured
//      on every written triangle, and under 4,000 triangles per interior cell.
//   §6 ★ a block graded PER VOXEL, as a run grades (the wall jumps at a voxel's face), its
//      lightest wall at the bead: it finishes with no split, the sheet's own surface within
//      the bound, the steps measured on their own, and an INDEPENDENT dense check, clear of
//      the cuts: no wall past its floor where no step is in reach, and under 5 um outside
//      the step's band where one is. With TpmsGenOptions::true_wall_steps off this block
//      had not finished after 180 s (1.6 s on), and the M2 stand's rung 0.52 ran 1.5 h.

// Self-contained CHECK harness (ARCHITECTURE §4 locks the dependency set).

#include "topopt/lattice.hpp"
#include "topopt/lattice_dc.hpp"
#include "topopt/mesh_simplify.hpp"
#include "topopt/tpms_gen.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <tuple>
#include <vector>

using namespace topopt;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                           \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

namespace {

struct Capture : TriangleSink {
  std::vector<std::array<Vec3, 3>> t;
  void add_triangle(const Vec3& a, const Vec3& b, const Vec3& c) override { t.push_back({a, b, c}); }
};

// Closed and manifold: every undirected edge used by exactly two triangles, and every
// DIRECTED edge exactly once (consistent winding).
bool closed_manifold(const std::vector<std::array<Vec3, 3>>& tris) {
  std::map<std::tuple<double, double, double>, int> id;
  auto v = [&](const Vec3& p) {
    auto k = std::make_tuple(p.x, p.y, p.z);
    auto it = id.find(k);
    if (it != id.end()) return it->second;
    const int i = static_cast<int>(id.size());
    id.emplace(k, i);
    return i;
  };
  std::map<std::pair<int, int>, int> directed;
  for (const auto& T : tris) {
    const int a = v(T[0]), b = v(T[1]), c = v(T[2]);
    for (auto e : {std::make_pair(a, b), std::make_pair(b, c), std::make_pair(c, a)}) ++directed[e];
  }
  for (const auto& kv : directed) {
    if (kv.second != 1) return false;
    auto it = directed.find({kv.first.second, kv.first.first});
    if (it == directed.end() || it->second != 1) return false;
  }
  return !tris.empty();
}

// The furthest a dense sample of the triangles sits on each side of the field's zero set.
void deviation(const std::vector<std::array<Vec3, 3>>& tris,
               const std::function<double(const Vec3&)>& f, double* out, double* in) {
  *out = 0.0;
  *in = 0.0;
  for (const auto& T : tris)
    for (int i = 0; i <= 8; ++i)
      for (int j = 0; j <= 8 - i; ++j) {
        const double u = i / 8.0, w = j / 8.0;
        const Vec3 p{T[0].x + (T[1].x - T[0].x) * u + (T[2].x - T[0].x) * w,
                     T[0].y + (T[1].y - T[0].y) * u + (T[2].y - T[0].y) * w,
                     T[0].z + (T[1].z - T[0].z) * u + (T[2].z - T[0].z) * w};
        const double d = f(p);
        *out = std::max(*out, d);
        *in = std::max(*in, -d);
      }
}

std::uint64_t hash_of(const std::vector<std::array<Vec3, 3>>& tris) {
  std::uint64_t h = 1469598103934665603ull;
  for (const auto& T : tris)
    for (const Vec3& p : T)
      for (double d : {p.x, p.y, p.z}) {
        std::uint64_t b;
        std::memcpy(&b, &d, sizeof b);
        h = (h ^ b) * 1099511628211ull;
      }
  return h;
}

// A sphere of radius `r` about (5, 5, 5): exact distance, negative inside.
std::function<double(const Vec3&)> sphere(double r) {
  return [r](const Vec3& p) {
    const double dx = p.x - 5, dy = p.y - 5, dz = p.z - 5;
    return std::sqrt(dx * dx + dy * dy + dz * dz) - r;
  };
}
std::function<Vec3(const Vec3&)> sphere_grad() {
  return [](const Vec3& p) {
    const double dx = p.x - 5, dy = p.y - 5, dz = p.z - 5, l = std::sqrt(dx * dx + dy * dy + dz * dz);
    return l > 0 ? Vec3{dx / l, dy / l, dz / l} : Vec3{0, 0, 1};
  };
}

std::vector<std::array<Vec3, 3>> run_sphere(double slab, BoundedSimplifyStats* st, long long* dc_tris,
                                            double contour_r = 3.0, double max_in = -1.0) {
  Capture cap;
  BoundedSimplifyOptions o;
  o.max_out_mm = 0.02;
  if (max_in >= 0.0) o.max_in_mm = [max_in](const Vec3&) { return max_in; };
  o.sample_spacing_mm = 0.05;
  o.slab_mm = slab;
  o.front_margin_mm = 3 * 0.1;
  BoundedSimplifySink s(cap, sphere(3.0), o);
  const LatticeDcFieldStats d =
      lattice_dual_contour_field(sphere(contour_r), sphere_grad(), {1, 1, 1}, {9, 9, 9}, 0.1, s);
  s.finish();
  *st = s.stats();
  *dc_tris = static_cast<long long>(d.triangles);
  return cap.t;
}

}  // namespace

int main() {
  // ── §1 / §2 / §3 ──────────────────────────────────────────────────────────────────
  {
    BoundedSimplifyStats a, b, c;
    long long dca = 0, dcb = 0, dcc = 0;
    const auto one = run_sphere(0.0, &a, &dca);
    const auto slabs = run_sphere(1.0, &b, &dcb);
    const auto again = run_sphere(1.0, &c, &dcc);
    double out1, in1, out2, in2;
    deviation(one, sphere(3.0), &out1, &in1);
    deviation(slabs, sphere(3.0), &out2, &in2);
    std::printf("[§1] sphere r 3, DC cell 0.1: %lld -> %zu triangles in one flush, %zu in %lld "
                "slabs; independent deviation out %.4f in %.4f / out %.4f in %.4f mm\n",
                dca, one.size(), slabs.size(), b.flushes, out1, in1, out2, in2);
    CHECK(closed_manifold(one), "§1 closed, manifold, consistently wound");
    CHECK(static_cast<long long>(one.size()) * 4 < dca, "§1 at least 4x fewer triangles");
    CHECK(out1 <= 0.0205 && in1 <= 0.0205, "§1 within 0.02 mm of the true surface (dense check)");
    CHECK(a.max_out_measured_mm <= 0.02 + 1e-12 && a.max_in_measured_mm <= 0.02 + 1e-12,
          "§1 and the sink's own measurement says so");
    CHECK(b.flushes >= 4, "§2 streamed in several slabs");
    CHECK(closed_manifold(slabs), "§2 closed and manifold across the slab seams");
    CHECK(out2 <= 0.0205 && in2 <= 0.0205, "§2 still within the bound");
    CHECK(hash_of(slabs) == hash_of(again), "§3 the same input gives the same output");
  }

  // ── §4 a wall at the bead: contoured outward, never cut into ─────────────────────
  {
    BoundedSimplifyStats st;
    long long dc = 0;
    const auto t = run_sphere(1.0, &st, &dc, 3.0 + 0.01, 0.0);
    double out, in;
    deviation(t, sphere(3.0), &out, &in);
    std::printf("[§4] max_in 0, contoured 0.01 outward: %zu triangles, out %.4f in %.5f mm, "
                "%lld samples past max_in\n", t.size(), out, in, st.samples_past_max_in);
    CHECK(closed_manifold(t), "§4 closed and manifold");
    CHECK(in <= 1e-4 && st.samples_past_max_in == 0, "§4 the true surface is never cut into");
    CHECK(out <= 0.0205, "§4 and the outward side stays within the bound");
  }

  // ── §5 the sheet generator, simplified ─────────────────────────────────────────────
  {
    const double L = 8.0, rho = 0.375;
    const LatticeTopology t = LatticeTopology::Gyroid;
    const double wall = lattice_strut_diameter_mm(t, rho, L);
    TpmsRegion R;
    R.anchor = {0, 0, 0};
    R.nx = R.ny = R.nz = 3;
    R.cell_mm = L;
    TpmsWallField W;
    W.uniform_mm = lattice_sheet_wall_param_mm(t, wall, L);
    TpmsGenOptions o;
    o.min_wall_mm = wall;
    o.max_deviation_mm = kSheetMaxDeviationMm;
    o.bead_mm = 0.42;
    o.true_wall_mm = [wall](const Vec3&) { return wall; };
    o.wall_param_of = [t, L](double w) { return lattice_sheet_wall_param_mm(t, w, L); };
    Capture cap;
    const TpmsGenStats ts = generate_tpms(TpmsKind::Gyroid, R, W, cap, o);
    long long middle = 0;
    for (const auto& T : cap.t) {
      const double cx = (T[0].x + T[1].x + T[2].x) / 3, cy = (T[0].y + T[1].y + T[2].y) / 3,
                   cz = (T[0].z + T[1].z + T[2].z) / 3;
      if (cx >= L && cx < 2 * L && cy >= L && cy < 2 * L && cz >= L && cz < 2 * L) ++middle;
    }
    std::printf("[§5] gyroid 3x3x3 at 8 mm, rho %.3f: contoured %lld -> %zu triangles; the middle "
                "cell %lld; sheet deviation %.4f / %.4f mm, cuts %.4f mm\n",
                rho, ts.simplify.triangles_in, cap.t.size(), middle, ts.simplify.max_out_measured_mm,
                ts.simplify.max_in_measured_mm,
                std::max(ts.simplify.cut_max_out_mm, ts.simplify.cut_max_in_mm));
    std::printf("[§5] worst sheet excess %.4f at (%.3f, %.3f, %.3f); snapped %lld, splits %lld\n",
                ts.simplify.worst_excess_mm, ts.simplify.worst_at.x, ts.simplify.worst_at.y,
                ts.simplify.worst_at.z, ts.simplify.snapped, ts.simplify.splits);
    CHECK(ts.simplified && closed_manifold(cap.t), "§5 closed and manifold");
    CHECK(ts.simplify.max_out_measured_mm <= kSheetMaxDeviationMm + 1e-12 &&
              ts.simplify.max_in_measured_mm <= kSheetMaxDeviationMm + 1e-12,
          "§5 the sheet's own surface within 0.02 mm, measured on every written triangle");
    CHECK(ts.simplify.samples_past_max_in == 0, "§5 no wall cut below the bead");
    CHECK(middle < 4000, "§5 the interior cell is under 4,000 triangles");
  }

  // ── §6 ★ a wall graded per voxel: the steps ─────────────────────────────────────────
  {
    const double L = 4.0, vox = 2.5, bead = 0.42, dev = kSheetMaxDeviationMm;
    const LatticeTopology t = LatticeTopology::Gyroid;
    // The lightest density prints exactly one bead (the law's floor): max_in is 0 there.
    const double rlo = lattice_min_density_for_strut(t, L, bead), rhi = 0.54;
    auto true_wall = [=](const Vec3& p) {
      const long i = static_cast<long>(std::floor(p.x / vox)),
                 j = static_cast<long>(std::floor(p.y / vox)),
                 k = static_cast<long>(std::floor(p.z / vox));
      const unsigned long hv =
          static_cast<unsigned long>(i * 73856093L ^ j * 19349663L ^ k * 83492791L);
      const double rho = (i + j + k) % 2 == 0 ? rlo : rlo + (rhi - rlo) * ((hv % 1000) / 999.0);
      return lattice_strut_diameter_mm(t, rho, L);
    };
    auto param = [t, L](double w) { return lattice_sheet_wall_param_mm(t, w, L); };
    TpmsRegion R;
    R.anchor = {0, 0, 0};
    R.nx = R.ny = R.nz = 1;
    R.cell_mm = L;
    TpmsWallField W;
    W.field = [=](const Vec3& p) { return param(true_wall(p)); };
    TpmsGenOptions o;
    o.min_wall_mm = bead;
    o.max_deviation_mm = dev;
    o.bead_mm = bead;
    o.true_wall_mm = true_wall;
    o.wall_param_of = param;
    o.true_wall_steps = true;
    // The premise, in arithmetic: somewhere a face separates walls whose surfaces are more
    // than twice the bound apart, so on that face no mesh is within the bound of both.
    double jump = 0.0;
    for (int a = 0; a < 2; ++a)
      for (int b = 0; b < 2; ++b)
        for (int c = 0; c < 2; ++c) {
          const Vec3 m{(a + 0.5) * vox, (b + 0.5) * vox, (c + 0.5) * vox};
          jump = std::max({jump, std::abs(true_wall(m) - true_wall({m.x + vox, m.y, m.z})),
                           std::abs(true_wall(m) - true_wall({m.x, m.y + vox, m.z})),
                           std::abs(true_wall(m) - true_wall({m.x, m.y, m.z + vox}))});
        }
    Capture cap;
    const TpmsGenStats ts = generate_tpms(TpmsKind::Gyroid, R, W, cap, o);
    const auto& s = ts.simplify;
    // INDEPENDENT of the sink's step test: every dense sample of the output against the
    // thinnest wall in a cube of half-side three DC cells (the step's reach) about it. The
    // block's faces are cuts, with a band of their own out to that reach, and a triangle
    // reaching into it can leave a few microns between the sink's samples just past it
    // (measured 5 um at 0.42 mm from the x = 4 face); in a run every cut lies under solid.
    // So the walls are judged clear of the cuts by two reaches, and that edge is printed.
    const double h = ts.dc_cell_mm, reach = 3.0 * h;
    double worst_floor = 0.0, worst_out = 0.0, plain_floor = 0.0, under_bead = -1e9;
    double cut_edge_under_bead = -1e9;
    long long sampled = 0, past_floor = 0;
    for (const auto& T : cap.t)
      for (int i = 0; i <= 8; ++i)
        for (int j = 0; j <= 8 - i; ++j) {
          const double u = i / 8.0, w = j / 8.0;
          const Vec3 p{T[0].x + (T[1].x - T[0].x) * u + (T[2].x - T[0].x) * w,
                       T[0].y + (T[1].y - T[0].y) * u + (T[2].y - T[0].y) * w,
                       T[0].z + (T[1].z - T[0].z) * u + (T[2].z - T[0].z) * w};
          const double to_cut = std::min({p.x, p.y, p.z, L - p.x, L - p.y, L - p.z});
          if (to_cut < reach) continue;
          const bool cut_edge = to_cut < 2.0 * reach;
          if (!cut_edge) ++sampled;
          double thin = true_wall(p), thick = thin;
          for (int q = 0; q < 27; ++q) {
            const double wq = true_wall({p.x + reach * (q % 3 - 1), p.y + reach * (q / 3 % 3 - 1),
                                         p.z + reach * (q / 9 - 1)});
            thin = std::min(thin, wq);
            thick = std::max(thick, wq);
          }
          TpmsWallField TN, TK;
          TN.uniform_mm = param(thin);
          TK.uniform_mm = param(thick);
          const double floor_in = std::clamp(0.5 * (thin - bead), 0.0, dev);
          const double under = -tpms_clipped_field(TpmsKind::Gyroid, R, TN, h, p) - floor_in;
          // THE BEAD itself, unclamped: inside the thinnest wall in reach by more than half
          // its margin over the bead leaves that wall under one bead.
          if (cut_edge) {
            cut_edge_under_bead = std::max(cut_edge_under_bead, under + floor_in - 0.5 * (thin - bead));
            continue;
          }
          under_bead = std::max(under_bead, under + floor_in - 0.5 * (thin - bead));
          if (!(thick > thin)) {  // no step in reach: the plain floor of its own wall
            plain_floor = std::max(plain_floor, under);
            continue;
          }
          past_floor += under > 1e-9 ? 1 : 0;
          worst_floor = std::max(worst_floor, under);
          worst_out = std::max(worst_out, tpms_clipped_field(TpmsKind::Gyroid, R, TK, h, p) - dev);
        }
    std::printf("[§6] per-voxel gyroid, one 4 mm cell, voxels 2.5 mm, rho %.4f..%.2f (largest "
                "wall jump %.3f mm): contoured %lld -> %zu triangles, splits %lld; sheet %.4f / "
                "%.4f mm, past the floor %lld; steps %lld samples, %.4f / %.4f mm off their own "
                "surface, %lld outside the step's band (worst %.5f mm); independent, %lld samples "
                "clear of the cuts: with no step in reach the deepest past its own floor %.6f mm; at a "
                "step %lld past the thinnest floor in reach (deepest %.6f mm), furthest past the "
                "thickest wall's bound %.6f mm; deepest under the bead %.6f mm (at a cut's edge, "
                "under solid in a run: %.6f mm)\n",
                rlo, rhi, jump, s.triangles_in, cap.t.size(), s.splits, s.max_out_measured_mm,
                s.max_in_measured_mm, s.samples_past_max_in, s.step_samples, s.step_max_out_mm,
                s.step_max_in_mm, s.step_samples_outside_band, s.step_worst_outside_band_mm,
                sampled, plain_floor, past_floor, worst_floor, worst_out, under_bead,
                cut_edge_under_bead);
    CHECK(jump > 4.0 * dev, "§6 premise: a voxel face separates surfaces > twice the bound apart");
    CHECK(ts.simplified && closed_manifold(cap.t), "§6 closed and manifold");
    CHECK(s.splits == 0, "§6 no step is refined (no split there converges)");
    CHECK(s.max_out_measured_mm <= dev + 1e-12 && s.max_in_measured_mm <= dev + 1e-12,
          "§6 the sheet's own surface within 0.02 mm wherever no step is in reach");
    CHECK(s.samples_past_max_in == 0, "§6 no sheet sample under the bead");
    CHECK(s.step_samples > 0 && s.step_max_out_mm > dev,
          "§6 the steps are measured on their own, off their own surface by more than the bound");
    CHECK(plain_floor <= 1e-4,
          "§6 independent: with no step in reach no sample cuts its wall past its floor");
    // What contouring a JUMP leaves (the crossing's gradient is taken across it) is kept as
    // contoured, since no collapse may leave the step's band and no split mends it: on this
    // block under a micron either side (0.54 um by the sink's own samples; 0.11 um inward and
    // 0.8 um outward by this denser check). The floor here is the clamped one, so it also
    // bounds the depth under the bead. Bounded at a quarter of the bound; the receipt states it.
    CHECK(s.step_worst_outside_band_mm <= 0.25 * dev && worst_floor <= 0.25 * dev &&
              worst_out <= 0.25 * dev,
          "§6 at a step, what the contouring left outside the step's band is under 5 um");
  }

  std::printf("%s: %d checks, %d failures\n", g_failures ? "FAIL" : "PASS", g_checks, g_failures);
  return g_failures ? 1 : 0;
}
