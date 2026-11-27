// The sample COUPON (ruling 2026-11-02, the addition): one shape that is both the app's
// Lattice preview and the block he prints (lattice_coupon.cpp states it).
//
//   §1 every live type builds it: the stated dimensions, the step its verdicts allow
//      (Doubled, else Stepped, else none; the sheets none, R5), and the tongue solid
//      exactly when it is under the type's floor in cells at the tongue's own cell;
//   §2 everything written lies inside the coupon's box, the lattice is not empty, and
//      no piece is left loose (each dropped piece is counted, never written);
//   §3 deterministic: the same spec writes the same bytes;
//   §4 a cell too coarse for the body's floor is refused with the reason;
//   §5 the bridge entry (lattice_sample_mesh) returns exactly what the file gets.

// Self-contained CHECK harness (ARCHITECTURE §4 locks the dependency set).

#include "topopt/lattice.hpp"
#include "topopt/lattice_gen.hpp"
#include "topopt/lattice_sample.hpp"
#include "topopt/lattice_types.hpp"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <string>

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

struct Box : TriangleSink {
  Vec3 lo{1e300, 1e300, 1e300}, hi{-1e300, -1e300, -1e300};
  long long n = 0;
  std::uint64_t h = 1469598103934665603ull;
  void add_triangle(const Vec3& a, const Vec3& b, const Vec3& c) override {
    ++n;
    for (const Vec3& p : {a, b, c}) {
      lo = {std::min(lo.x, p.x), std::min(lo.y, p.y), std::min(lo.z, p.z)};
      hi = {std::max(hi.x, p.x), std::max(hi.y, p.y), std::max(hi.z, p.z)};
      for (double d : {p.x, p.y, p.z}) {
        std::uint64_t b;
        std::memcpy(&b, &d, sizeof b);
        h = (h ^ b) * 1099511628211ull;
      }
    }
  }
};

}  // namespace

int main() {
  for (const std::string& id : lattice_gen_topology_names()) {
    const LatticeTypeFacts f = lattice_type_facts(id);
    const bool sheet = f.family == "sheet";
    LatticeSampleSpec spec;
    spec.topology = id;
    spec.shape = "coupon";
    spec.cell_mm = sheet ? 16.0 : 8.0;  // a sheet at 8 mm takes minutes; the logic is the same
    Box box;
    LatticeSampleReceipt r;
    try {
      r = write_lattice_sample(spec, box);
    } catch (const std::exception& e) {
      CHECK(false, (id + ": the coupon builds (" + e.what() + ")").c_str());
      continue;
    }
    const std::string want_step = sheet ? "none"
                                  : f.doubled.allowed ? "doubled"
                                  : f.stepped.allowed ? "stepped" : "none";
    const double tongue_cell = want_step == "none" ? spec.cell_mm : 0.5 * spec.cell_mm;
    const bool want_tongue = 12.0 / tongue_cell >= f.aesthetic_hard_floor_cells;
    std::printf("[§1] %-9s step %-8s tongue %-8s %8llu triangles, %llu loose pieces dropped, "
                "box (%.2f %.2f %.2f)-(%.2f %.2f %.2f)\n",
                id.c_str(), r.step.c_str(), r.tongue_latticed ? "latticed" : "solid",
                static_cast<unsigned long long>(r.triangles),
                static_cast<unsigned long long>(r.loose_pieces_dropped), box.lo.x, box.lo.y,
                box.lo.z, box.hi.x, box.hi.y, box.hi.z);
    CHECK(r.shape == "coupon" && r.coupon_dims_mm[0] == 45.0 && r.coupon_dims_mm[1] == 40.0 &&
              r.coupon_dims_mm[2] == 35.0,
          (id + ": §1 the coupon's dimensions").c_str());
    CHECK(r.step == want_step, (id + ": §1 the step the type's verdicts allow").c_str());
    CHECK(r.tongue_latticed == want_tongue && (want_tongue || !r.tongue_reason.empty()),
          (id + ": §1 the tongue solid exactly under the floor, with the reason").c_str());
    CHECK(r.rho_lo == f.rho_min && r.rho_hi == f.rho_max,
          (id + ": §1 graded across the band by default").c_str());
    const double eps = 1e-6;
    CHECK(box.lo.x >= -eps && box.lo.y >= -eps && box.lo.z >= -eps && box.hi.x <= 45.0 + eps &&
              box.hi.y <= 40.0 + eps && box.hi.z <= 35.0 + eps,
          (id + ": §2 everything inside the coupon's box").c_str());
    CHECK(r.lattice_triangles > 0 && box.n == static_cast<long long>(r.triangles),
          (id + ": §2 a lattice is written and the receipt counts every triangle").c_str());
    if (id == "octet" || id == "rhombic") {
      Box again;
      (void)write_lattice_sample(spec, again);
      CHECK(again.h == box.h, (id + ": §3 the same spec writes the same bytes").c_str());
      LatticeSampleReceipt rm;
      const TriangleMesh m = lattice_sample_mesh(spec, &rm);
      CHECK(m.triangles.size() == static_cast<std::size_t>(box.n) && rm.triangles == r.triangles,
            (id + ": §5 the bridge entry returns what the file gets").c_str());
    }
  }

  // §4 too coarse a cell for the body's floor.
  {
    LatticeSampleSpec spec;
    spec.topology = "octet";
    spec.shape = "coupon";
    spec.cell_mm = 20.0;
    bool refused = false;
    std::string why;
    Box box;
    try { (void)write_lattice_sample(spec, box); } catch (const std::invalid_argument& e) {
      refused = true;
      why = e.what();
    }
    CHECK(refused && why.find("floor") != std::string::npos,
          "§4 a 20 mm cell leaves the body under its floor and is refused with the reason");
  }

  std::printf("%s: %d checks, %d failures\n", g_failures ? "FAIL" : "PASS", g_checks, g_failures);
  return g_failures ? 1 : 0;
}
