// test_tpms — THE SHEET LATTICES (lattice types round 1, K2: 02-core-spec §3).
//
//   1. tpms.hpp: the gradient is the field's exact derivative; the wall is the
//      gradient-normalised band, so on the zero set the wall distance is -t/2.
//   2. generate_tpms on a box with a hole in the cell set, clipped by a LatticeBoundary and
//      graded in thickness: the mesh is CLOSED AND MANIFOLD (every edge in exactly two
//      triangles), deterministic, and stays inside the part.
//   3. Its volume against the exact solid fraction of the same wall (2^18 Halton points):
//      the DC cell the generator picks keeps it within 1 %.
//
// Self-contained CHECK harness (ARCHITECTURE §4).

#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <initializer_list>
#include <map>
#include <string>
#include <vector>

#include "topopt/lattice_boundary.hpp"
#include "topopt/tpms.hpp"
#include "topopt/tpms_gen.hpp"

using namespace topopt;

static int g_checks = 0, g_failures = 0;
#define CHECK(cond, msg)                                         \
  do {                                                           \
    ++g_checks;                                                  \
    if (!(cond)) {                                               \
      ++g_failures;                                              \
      std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, msg);  \
    }                                                            \
  } while (0)

namespace {
struct Soup : TriangleSink {
  std::vector<std::array<Vec3, 3>> t;
  unsigned long long h = 1469598103934665603ull;
  void add_triangle(const Vec3& a, const Vec3& b, const Vec3& c) override {
    t.push_back({a, b, c});
    for (const Vec3* p : {&a, &b, &c})
      for (double v : {p->x, p->y, p->z}) {
        unsigned char bb[sizeof v];
        std::memcpy(bb, &v, sizeof v);
        for (unsigned char ch : bb) h = (h ^ ch) * 1099511628211ull;
      }
  }
  double volume() const {
    double v = 0;
    for (const auto& q : t) {
      const Vec3 &a = q[0], &b = q[1], &c = q[2];
      v += (a.x * (b.y * c.z - b.z * c.y) - a.y * (b.x * c.z - b.z * c.x) +
            a.z * (b.x * c.y - b.y * c.x)) / 6.0;
    }
    return v;
  }
  long bad_edges() const {
    std::map<std::array<long, 6>, int> e;
    auto k = [](const Vec3& p) {
      return std::array<long, 3>{std::lround(p.x * 1e6), std::lround(p.y * 1e6), std::lround(p.z * 1e6)};
    };
    for (const auto& q : t)
      for (int i = 0; i < 3; ++i) {
        auto a = k(q[i]), b = k(q[(i + 1) % 3]);
        if (b < a) std::swap(a, b);
        ++e[{a[0], a[1], a[2], b[0], b[1], b[2]}];
      }
    long bad = 0;
    for (const auto& kv : e) if (kv.second != 2) ++bad;
    return bad;
  }
};
double halton(unsigned i, unsigned b) {
  double f = 1, r = 0;
  while (i) { f /= b; r += f * (i % b); i /= b; }
  return r;
}
}  // namespace

int main() {
  for (TpmsKind k : {TpmsKind::Gyroid, TpmsKind::SchwarzD}) {
    const std::string id = tpms_id(k);
    // 1. the field
    double worst_g = 0, worst_w = 0;
    for (int i = 1; i <= 500; ++i) {
      const double x = 7.3 * halton(i, 2), y = 7.3 * halton(i, 3), z = 7.3 * halton(i, 5), L = 7.3, e = 1e-6;
      const TpmsValue v = tpms_eval(k, x, y, z, L);
      const double gx = (tpms_eval(k, x + e, y, z, L).f - tpms_eval(k, x - e, y, z, L).f) / (2 * e);
      const double gy = (tpms_eval(k, x, y + e, z, L).f - tpms_eval(k, x, y - e, z, L).f) / (2 * e);
      const double gz = (tpms_eval(k, x, y, z + e, L).f - tpms_eval(k, x, y, z - e, L).f) / (2 * e);
      worst_g = std::fmax(worst_g, std::fabs(gx - v.gx) + std::fabs(gy - v.gy) + std::fabs(gz - v.gz));
      // project to the zero set; the wall distance there is -t/2
      double p[3] = {x, y, z};
      for (int it = 0; it < 30; ++it) {
        const TpmsValue w = tpms_eval(k, p[0], p[1], p[2], L);
        const double g2 = w.gx * w.gx + w.gy * w.gy + w.gz * w.gz;
        if (g2 < 1e-12) break;
        p[0] -= w.f * w.gx / g2; p[1] -= w.f * w.gy / g2; p[2] -= w.f * w.gz / g2;
      }
      worst_w = std::fmax(worst_w, std::fabs(tpms_wall_distance(k, p[0], p[1], p[2], L, 0.6) + 0.3));
    }
    CHECK(worst_g < 1e-6, (id + ": the gradient is the field's derivative").c_str());
    CHECK(worst_w < 1e-9, (id + ": on the zero set the wall distance is -t/2").c_str());

    // 2. a clipped, holed, graded block: closed, manifold, deterministic, inside the part
    LatticeBoundary B;
    B.add_box({0.7, 0.3, 0.5}, {15.1, 14.6, 15.9});
    TpmsRegion R;
    R.nx = R.ny = R.nz = 2;
    R.cell_mm = 8.0;
    R.boundary = &B;
    R.latticed = [](int i, int j, int kk) { return !(i == 1 && j == 1 && kk == 1); };
    TpmsWallField W;
    W.field = [](const Vec3& p) { return 0.6 + 0.02 * p.x; };
    TpmsGenOptions o;
    o.min_wall_mm = 0.6;
    Soup s1, s2;
    const TpmsGenStats st = generate_tpms(k, R, W, s1, o);
    generate_tpms(k, R, W, s2, o);
    CHECK(st.latticed_cells == 7, (id + ": seven of eight cells latticed").c_str());
    CHECK(!s1.t.empty() && s1.bad_edges() == 0,
          (id + ": the sheet is closed and manifold (every edge in two triangles)").c_str());
    CHECK(st.dc.quads_dropped == 0, (id + ": no quad dropped").c_str());
    CHECK(s1.h == s2.h && s1.t.size() == s2.t.size(), (id + ": deterministic").c_str());
    double outside = 0;
    for (const auto& q : s1.t)
      for (const Vec3& v : q) outside = std::fmax(outside, -B.signed_distance(v));
    std::printf("  %s: worst vertex outside the part %.4f mm (DC cell %.3f)\n", id.c_str(), outside, st.dc_cell_mm);
    CHECK(outside <= 0.0, (id + ": every vertex inside the part (the clip erodes by one DC cell)").c_str());
    CHECK(s1.volume() > 0, (id + ": outward-wound (positive volume)").c_str());

    // 3. volume against the exact solid fraction (an unclipped 2x2x2 block, uniform wall)
    TpmsRegion R2;
    R2.nx = R2.ny = R2.nz = 2;
    R2.cell_mm = 8.0;
    TpmsWallField W2;
    W2.uniform_mm = 0.8;
    TpmsGenOptions o2;
    o2.min_wall_mm = 0.8;
    Soup s3;
    generate_tpms(k, R2, W2, s3, o2);
    long in = 0;
    const int N = 1 << 18;
    for (int n = 1; n <= N; ++n)
      if (tpms_in_wall(k, 16 * halton(n, 2), 16 * halton(n, 3), 16 * halton(n, 5), 8.0, 0.8)) ++in;
    const double exact = double(in) / N * 4096.0;
    char msg[160];
    std::snprintf(msg, sizeof msg, "%s: mesh volume %.1f within 1 %% of the solid fraction's %.1f",
                  id.c_str(), s3.volume(), exact);
    CHECK(std::fabs(s3.volume() / exact - 1.0) < 0.01, msg);
  }
  std::printf("\n%s: %d checks, %d failures\n", g_failures == 0 ? "PASS" : "FAIL", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
