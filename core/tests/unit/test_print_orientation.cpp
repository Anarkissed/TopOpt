// P4, his print orientation: the six candidates (print_orientation.hpp) and the one rule (recommend_print_orientation,
// build_orientation.hpp, decision D1).
//   §1 the rule: strength first, then standing, then least part support (10 % ties), then strength, then height; his
//      placement kept unless the winner is 10 % stronger (or fixes a fail) or needs 30 % less support without being
//      weaker; "none passes yet"; strength not known.
//   §2 the bed: the L-bracket's flat face and height along each of its six axes, and whether its centre stands over it.
//   §3 the part's own support (voxels): a shelf over air is supported to the bed, a 45 degree step is not, the lattice
//      (part, not solid) holds what is above it.
#include <cmath>
#include <cstdio>
#include <limits>
#include <string>
#include <vector>

#include "topopt/build_orientation.hpp"
#include "topopt/print_orientation.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

static int g_fail = 0, g_checks = 0;
#define CHECK(cond)                                                                        \
  do {                                                                                     \
    ++g_checks;                                                                            \
    if (!(cond)) { ++g_fail; std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } \
  } while (0)

namespace {
OrientationCandidateIn cand(double strength, double support, double contact, double height, bool inc = false) {
  OrientationCandidateIn c;
  c.strength = strength;
  c.support_mm3 = support;
  c.contact_mm2 = contact;
  c.height_mm = height;
  c.incumbent = inc;
  return c;
}
bool has_why(const OrientationRecommendation& r, const std::string& w) {
  for (const std::string& x : r.why)
    if (x == w) return true;
  return false;
}
// The L-bracket of test_print_frame.cpp: a plate x 0..40, y 0..24, z 0..6 and a wall x 0..8 to z = 30.
TriangleMesh bracket() {
  const std::vector<double> xs{0, 8, 40}, ys{0, 24}, zs{0, 6, 30};
  const auto full = [](int i, int, int k) { return k == 0 || i == 0; };
  const int nx = 3, ny = 2, nz = 3;
  TriangleMesh tm;
  const auto vid = [&](int i, int j, int k) { return (k * ny + j) * nx + i; };
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) tm.vertices.push_back({xs[i], ys[j], zs[k]});
  const auto quad = [&](int a, int b, int c, int d) {
    tm.triangles.push_back({a, b, c});
    tm.triangles.push_back({a, c, d});
  };
  const auto in = [&](int i, int j, int k) { return i >= 0 && j >= 0 && k >= 0 && i < nx - 1 && j < ny - 1 && k < nz - 1 && full(i, j, k); };
  for (int i = 0; i + 1 < nx; ++i)
    for (int j = 0; j + 1 < ny; ++j)
      for (int k = 0; k + 1 < nz; ++k) {
        if (!in(i, j, k)) continue;
        if (!in(i - 1, j, k)) quad(vid(i, j, k), vid(i, j, k + 1), vid(i, j + 1, k + 1), vid(i, j + 1, k));
        if (!in(i + 1, j, k)) quad(vid(i + 1, j, k), vid(i + 1, j + 1, k), vid(i + 1, j + 1, k + 1), vid(i + 1, j, k + 1));
        if (!in(i, j - 1, k)) quad(vid(i, j, k), vid(i + 1, j, k), vid(i + 1, j, k + 1), vid(i, j, k + 1));
        if (!in(i, j + 1, k)) quad(vid(i, j + 1, k), vid(i, j + 1, k + 1), vid(i + 1, j + 1, k + 1), vid(i + 1, j + 1, k));
        if (!in(i, j, k - 1)) quad(vid(i, j, k), vid(i, j + 1, k), vid(i + 1, j + 1, k), vid(i + 1, j, k));
        if (!in(i, j, k + 1)) quad(vid(i, j, k + 1), vid(i + 1, j, k + 1), vid(i + 1, j + 1, k + 1), vid(i, j + 1, k + 1));
      }
  return tm;
}
}  // namespace

int main() {
  const double nan = std::numeric_limits<double>::quiet_NaN();
  // ── §1 the rule
  {
    // As placed is good: kept, even when another needs a little less support.
    OrientationRecommendation r = recommend_print_orientation(
        {cand(3.0, 1000, 900, 40, true), cand(3.1, 800, 900, 30)}, 1.5);
    CHECK(r.recommended == 0 && !r.change && r.headline == "best_orientation" && has_why(r, "Prints best as placed"));
    // 30 % less support and not weaker: change.
    r = recommend_print_orientation({cand(3.0, 1000, 900, 40, true), cand(3.0, 600, 900, 30)}, 1.5);
    CHECK(r.recommended == 1 && r.change && r.headline == "new_orientation_may_be_stronger" && has_why(r, "Less support needed"));
    // 30 % less support but weaker: kept.
    r = recommend_print_orientation({cand(3.0, 1000, 900, 40, true), cand(2.9, 600, 900, 30)}, 1.5);
    CHECK(r.recommended == 0 && !r.change);
    // As placed fails, another passes: change, whatever the support.
    r = recommend_print_orientation({cand(1.2, 0, 900, 40, true), cand(1.8, 5000, 900, 30)}, 1.5);
    CHECK(r.recommended == 1 && r.change && has_why(r, "Stronger across the layers"));
    CHECK(r.candidates[0].dropped == "too_weak" && r.candidates[1].offered && r.candidates[1].passes);
    // Too small a face: cannot stand (300 mm2, and 25 % of the largest).
    r = recommend_print_orientation({cand(3.0, 1000, 900, 40, true), cand(3.0, 0, 200, 30), cand(3.0, 0, 2000, 30)}, 1.5);
    CHECK(r.candidates[1].dropped == "cannot_stand" && r.recommended == 2);
    // A candidate with no flat face is never offered.
    {
      std::vector<OrientationCandidateIn> v{cand(3.0, 1000, 900, 40, true), cand(9.0, 0, 900, 30)};
      v[1].flat = false;
      r = recommend_print_orientation(v, 1.5);
      CHECK(r.candidates[1].dropped == "no_flat_face" && r.recommended == 0);
    }
    // Ties within 10 % of the least support: the stronger, then the lower.
    r = recommend_print_orientation({cand(2.0, 1000, 900, 40, true), cand(4.0, 650, 900, 50), cand(3.0, 600, 900, 30)}, 1.5);
    CHECK(r.recommended == 1);   // 650 is within 10 % of 600 and stronger; 2x as strong as placed
    r = recommend_print_orientation({cand(2.0, 1000, 900, 40, true), cand(3.0, 620, 900, 50), cand(3.0, 600, 900, 30)}, 1.5);
    CHECK(r.recommended == 2);   // equal strength: the lower
    // None passes: the strongest only, said so.
    r = recommend_print_orientation({cand(1.0, 0, 900, 40, true), cand(1.2, 0, 900, 30)}, 1.5);
    CHECK(r.none_passes && r.recommended == 1 && has_why(r, "None passes yet"));
    // Strength not known: support decides, his placement kept unless 30 % less.
    r = recommend_print_orientation({cand(nan, 1000, 900, 40, true), cand(nan, 500, 900, 30)}, 1.5);
    CHECK(r.recommended == 1 && r.change && !r.candidates[1].passes);
    for (const std::string& w : {std::string("Prints best as placed"), std::string("Stronger across the layers"),
                                 std::string("Less support needed"), std::string("Stands on a larger face"),
                                 std::string("None passes yet")}) {
      int words = 1;
      for (char ch : w) words += ch == ' ';
      CHECK(words <= 5);   // his rule: at most 5 words
    }
  }
  // ── §2 the bed
  {
    const std::array<OrientationGeometry, 6> g = orientation_geometry(bracket());
    const double want_contact[6] = {960, 192, 720, 144, 432, 432}, want_height[6] = {30, 30, 40, 40, 24, 24};
    for (int k = 0; k < 6; ++k) {
      std::printf("[bed] candidate %d: contact %.6g height %.6g hull %zu\n", k, g[k].contact_mm2, g[k].height_mm, g[k].hull.size());
      CHECK(std::fabs(g[k].contact_mm2 - want_contact[k]) < 1e-9 && std::fabs(g[k].height_mm - want_height[k]) < 1e-12);
    }
    // Its centre of mass (the plate's and the wall's): over the base, the wall's end, and both sides; NOT over the wall's top
    // (-Z: x 0..8) nor the plate's end (-X: y 0..24, z 0..6).
    const double vp = 40 * 24 * 6, vw = 8 * 24 * 24;
    const Vec3 com{(vp * 20 + vw * 4) / (vp + vw), 12, (vp * 3 + vw * 18) / (vp + vw)};
    CHECK(stands_over(g[0], 0, com) && stands_over(g[2], 2, com) && stands_over(g[4], 4, com) && stands_over(g[5], 5, com));
    CHECK(!stands_over(g[1], 1, com) && !stands_over(g[3], 3, com));
  }
  // ── §3 the part's own support
  {
    VoxelGrid g;
    g.nx = 10; g.ny = 1; g.nz = 10;
    g.spacing = 1.0;
    g.tags.assign(100, VoxelTag::Empty);
    std::vector<char> part(100, 0), solid(100, 0);
    const auto set = [&](int i, int k, bool s) { part[g.index(i, 0, k)] = 1; solid[g.index(i, 0, k)] = s; };
    for (int k = 0; k < 10; ++k) set(0, k, true);        // a column at x = 0
    for (int i = 1; i < 10; ++i) set(i, 9, true);        // a shelf at z = 9 over air, x 1..9
    // up +Z: the shelf's voxels x 2..9 hang over air (x 1 is held by the column within the 45 degree cone): 8 columns of 9
    CHECK(support_along_axis(g, part, solid, 2, 1) == 8 * 9);
    // the lattice under part of the shelf (part, not solid) holds it there: x 6..9 at z 0..8
    for (int i = 6; i < 10; ++i)
      for (int k = 0; k < 9; ++k) set(i, k, false);
    CHECK(support_along_axis(g, part, solid, 2, 1) == 3 * 9);   // x 2..4 hang (x 5 is held by the lattice's cone)
    // upside down (up -Z): the column's and the lattice's tops stand on the bed at z = 9; nothing hangs
    CHECK(support_along_axis(g, part, solid, 2, -1) == 0);
  }
  std::printf("%d checks, %d failed\n", g_checks, g_fail);
  return g_fail == 0 ? 0 : 1;
}
