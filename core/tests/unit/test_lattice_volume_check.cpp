// Finding 7 (ruling 2026-11-02): the cover rule and the lattice volume check.
//
//   §1 cells_covering_span: a cell finer than the voxel gets every covering cell; an
//      aligned grid (cell = whole voxels, same origin) gets exactly the centre's cell;
//      a shared face is not an overlap.
//   §2 the probe measures the EMITTED solids: one prism and one icosahedral node read
//      their analytic volumes (lattice_prism_volume_mm3 / lattice_node_volume_mm3), which
//      since (b) are the round strut's and the sphere's; two coincident struts read once
//      (a union, not a sum).
//   §3 a sheet-style inside test (a ball) reads its volume.
//   §4 pockets: two separate blobs are two pockets; an empty pocket refuses with a plain
//      reason; a full one does not; the same input gives the same numbers.

// Self-contained CHECK harness (ARCHITECTURE §4 locks the dependency set).

#include "topopt/cell_plan.hpp"
#include "topopt/lattice_gen.hpp"
#include "topopt/lattice_volume_check.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstdio>
#include <string>
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

VoxelGrid grid_of(int n, double s) {
  VoxelGrid g;
  g.nx = g.ny = g.nz = n;
  g.spacing = s;
  g.origin = {0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(n) * n * n, VoxelTag{});
  return g;
}

double rel(double a, double b) { return std::abs(a / b - 1.0); }

}  // namespace

int main() {
  // ── §1 the cover rule ───────────────────────────────────────────────────────────
  {
    int lo = 0, hi = 0;
    // The stand's case: 3.41 mm voxels, 2 mm cells. Voxel 1 spans 3.41-6.82 mm, which
    // meets cells 1 (2-4), 2 (4-6) and 3 (6-8); its centre (5.115) is in cell 2 only.
    cells_covering_span(3.41, 3.41, 0.0, 2.0, 100, &lo, &hi);
    CHECK(lo == 1 && hi == 3, "a 3.41 mm voxel meets three 2 mm cells");
    // Aligned: 8 mm cells over 2 mm voxels on one origin -> exactly the centre's cell.
    for (int i = 0; i < 16; ++i) {
      cells_covering_span(i * 2.0, 2.0, 0.0, 8.0, 100, &lo, &hi);
      CHECK(lo == i / 4 && hi == i / 4, "an aligned grid gives the centre's cell alone");
    }
    // A shared face is not an overlap: voxel [4, 6) against 2 mm cells is cell 2 only.
    cells_covering_span(4.0, 2.0, 0.0, 2.0, 100, &lo, &hi);
    CHECK(lo == 2 && hi == 2, "a voxel exactly one cell wide is that cell");
    // Clamped at the grid's ends.
    cells_covering_span(-1.0, 3.0, 0.0, 2.0, 3, &lo, &hi);
    CHECK(lo == 0 && hi == 0, "clamped below");
    cells_covering_span(5.5, 3.0, 0.0, 2.0, 3, &lo, &hi);
    CHECK(lo == 2 && hi == 2, "clamped above");
  }

  // ── §2 the emitted solids ───────────────────────────────────────────────────────
  {
    const VoxelGrid g = grid_of(6, 1.0);
    std::vector<char> mask(g.voxel_count(), 1);
    auto one = [](std::size_t) { return 1.0; };

    LatticeSolidProbe strut;
    strut.add_strut({0.5, 3.0, 3.0}, {5.5, 3.0, 3.0}, 0.6, 8);
    const LatticeVolumeCheck a = lattice_volume_check(g, mask, one, strut);
    const double prism = lattice_prism_volume_mm3(0.6, 5.0, 8);
    const double capsule = 3.14159265358979 * 0.36 * 5.0;
    std::printf("[§2] prism: measured %.4f, analytic %.4f, round cylinder %.4f mm3\n",
                a.exported_mm3, prism, capsule);
    CHECK(a.ran && a.pockets.size() == 1, "one pocket");
    CHECK(rel(a.exported_mm3, prism) < 0.01, "a prism reads its own volume (1 %)");
    // (b): the prism is emitted at the round strut's AREA, so it reads the round cylinder's.
    CHECK(rel(a.exported_mm3, capsule) < 0.01, "and that is the round cylinder's (equal area)");

    LatticeSolidProbe node;
    node.add_ball({3.0, 3.0, 3.0}, 1.5);
    const LatticeVolumeCheck b = lattice_volume_check(g, mask, one, node);
    std::printf("[§2] node: measured %.4f, analytic %.4f mm3\n", b.exported_mm3,
                lattice_node_volume_mm3(1.5));
    CHECK(rel(b.exported_mm3, lattice_node_volume_mm3(1.5)) < 0.01,
          "an icosahedral node reads its own volume (1 %)");

    LatticeSolidProbe twice;
    twice.add_strut({0.5, 3.0, 3.0}, {5.5, 3.0, 3.0}, 0.6, 8);
    twice.add_strut({0.5, 3.0, 3.0}, {5.5, 3.0, 3.0}, 0.6, 8);
    const LatticeVolumeCheck c = lattice_volume_check(g, mask, one, twice);
    CHECK(c.exported_mm3 == a.exported_mm3, "two coincident struts read once (a union)");

    const LatticeVolumeCheck a2 = lattice_volume_check(g, mask, one, strut);
    CHECK(a2.exported_mm3 == a.exported_mm3 && a2.points == a.points,
          "the same input gives the same numbers");
  }

  // ── §3 an inside test (the sheets' form) ────────────────────────────────────────
  {
    const VoxelGrid g = grid_of(8, 1.0);
    std::vector<char> mask(g.voxel_count(), 1);
    LatticeSolidProbe ball;
    ball.set_inside([](const Vec3& p) {
      const double dx = p.x - 4.0, dy = p.y - 4.0, dz = p.z - 4.0;
      return dx * dx + dy * dy + dz * dz < 9.0;
    });
    const LatticeVolumeCheck v =
        lattice_volume_check(g, mask, [](std::size_t) { return 0.25; }, ball);
    const double exact = 4.0 / 3.0 * 3.14159265358979 * 27.0;
    std::printf("[§3] ball: measured %.3f, exact %.3f mm3; certified %.1f, gap %+.2f %%\n",
                v.exported_mm3, exact, v.certified_mm3, 100.0 * v.worst_gap);
    CHECK(rel(v.exported_mm3, exact) < 0.01, "a field's inside test reads its volume (1 %)");
    CHECK(rel(v.certified_mm3, 0.25 * 512.0) < 1e-12, "certified = rho x the pocket volume");
  }

  // ── §4 pockets and the refusal ──────────────────────────────────────────────────
  {
    const VoxelGrid g = grid_of(8, 1.0);
    std::vector<char> mask(g.voxel_count(), 0);
    // Pocket A: x 0-3, filled by a solid block of struts; pocket B: x 6-7, empty.
    for (int k = 0; k < 8; ++k)
      for (int j = 0; j < 8; ++j) {
        for (int i = 0; i < 3; ++i) mask[g.index(i, j, k)] = 1;
        for (int i = 6; i < 8; ++i) mask[g.index(i, j, k)] = 1;
      }
    LatticeSolidProbe p;
    p.set_inside([](const Vec3& q) { return q.x < 3.0; });
    const LatticeVolumeCheck v =
        lattice_volume_check(g, mask, [](std::size_t) { return 1.0; }, p);
    CHECK(v.pockets.size() == 2, "two separate blobs are two pockets");
    CHECK(v.pockets.size() == 2 && std::abs(v.pockets[0].gap) < 1e-9,
          "the full pocket matches its certificate");
    CHECK(v.pockets.size() == 2 && v.pockets[1].gap == -1.0, "the empty pocket reads -100 %");
    CHECK(v.refused(), "an empty pocket refuses");
    const std::string why = lattice_volume_refusal(v);
    std::printf("[§4] %s\n", why.c_str());
    CHECK(why.find("128 voxels") != std::string::npos &&
              why.find("-100.0 %") != std::string::npos,
          "the refusal names the pocket and the gap");

    std::vector<char> only_a(mask);
    for (int k = 0; k < 8; ++k)
      for (int j = 0; j < 8; ++j)
        for (int i = 6; i < 8; ++i) only_a[g.index(i, j, k)] = 0;
    const LatticeVolumeCheck w =
        lattice_volume_check(g, only_a, [](std::size_t) { return 1.0; }, p);
    CHECK(!w.refused() && lattice_volume_refusal(w).empty(), "a full pocket does not refuse");

    // (a): ONE-SIDED. A pocket holding MORE than certified is reported, never refused.
    const LatticeVolumeCheck over =
        lattice_volume_check(g, only_a, [](std::size_t) { return 0.5; }, p);
    std::printf("[§4] over-full: gap %+.1f %%, refused %d\n", 100.0 * over.highest_gap,
                int(over.refused()));
    CHECK(over.highest_gap > 0.9 && !over.refused(), "a file heavier than certified does not refuse");
  }

  std::printf("%s: %d checks, %d failures\n", g_failures ? "FAIL" : "PASS", g_checks,
              g_failures);
  return g_failures ? 1 : 0;
}
