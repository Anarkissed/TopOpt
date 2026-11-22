// SPEED 11-22 (his "We need to speed everything up EXPONENTIALLY"): the print check's overhang read (weave_findings,
// WeaveFindingsIndex) finds the bars near a place on a grid (BarGrid) instead of reading every bar, and makes the joints
// once per pass instead of once per place. It must give EXACTLY what the every-bar form gives, place by place:
//   G1  random weaves (chains with shared joints, joined ends, solid ends, cube bars, left-out bars), places on and
//       around the bars and far from them: every count and flag equal to weave_findings_every_bar.
//   G2  the index read one place at a time equals the batch.
//   G3  edge cases: no bars, no places, a bar with a non-finite end, a zero-length bar, places exactly on a grid line.
//   G4  the grid files every bar that can read a place (a place on the bar's surface + 0.34 mm is in its cell list).
//   G5  end_joints: hashed, the same joint numbers as an ordered search would give (ends a hair apart are one).
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <limits>
#include <random>
#include <vector>

#include "topopt/lattice_layout.hpp"
#include "topopt/lattice_layout_mesh.hpp"

using namespace topopt;
using namespace topopt::lattice_layout;

static int g_fail = 0, g_checks = 0;
#define CHECK(cond)                                                                          \
  do {                                                                                       \
    ++g_checks;                                                                              \
    if (!(cond)) { ++g_fail; std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } \
  } while (0)

static bool same(const WeaveFinding& a, const WeaveFinding& b) {
  return a.reached == b.reached && a.cube == b.cube && a.held == b.held && a.level == b.level && a.on_weave == b.on_weave;
}

// A weave-like tangle: strands of short bars climbing from the bed, sharing their ends (Node), some ends Solid, some
// Joined into another bar, some cube-lattice bars (region 1), some left out.
static Bars tangle(std::mt19937& rng, int strands, std::vector<char>& present) {
  std::uniform_real_distribution<double> u(0.0, 1.0);
  Bars bars;
  for (int s = 0; s < strands; ++s) {
    Vec3 p{u(rng) * 40.0 - 20.0, u(rng) * 30.0 - 15.0, u(rng) * 2.0};
    const int steps = 3 + static_cast<int>(u(rng) * 10);
    const int region = u(rng) < 0.8 ? 7 : 1;
    for (int k = 0; k < steps; ++k) {
      Vec3 q{p.x + (u(rng) - 0.5) * 6.0, p.y + (u(rng) - 0.5) * 6.0, p.z + (u(rng) - 0.3) * 4.0};
      if (u(rng) < 0.15) q.z = p.z + (u(rng) - 0.5) * 0.15;   // level bars (within a layer)
      if (u(rng) < 0.05) q = p;                               // zero length
      Bar b;
      b.a = p;
      b.b = q;
      b.width = 0.6 + u(rng) * 1.4;
      b.region = region;
      b.end_a = k == 0 ? (u(rng) < 0.5 ? Bar::End::Solid : Bar::End::Node) : Bar::End::Node;
      b.end_b = u(rng) < 0.1 ? Bar::End::Joined : Bar::End::Node;
      if (b.end_b == Bar::End::Joined && !bars.bars.empty())
        b.into_b = static_cast<int>(u(rng) * static_cast<double>(bars.bars.size()));
      // an end a hair (under 1e-5 mm) from the last bar's end: the same joint
      if (k > 0 && u(rng) < 0.2) b.a = {p.x + 3e-6, p.y - 2e-6, p.z + 1e-6};
      bars.bars.push_back(b);
      p = q;
    }
  }
  present.assign(bars.bars.size(), 1);
  for (char& c : present) c = u(rng) < 0.1 ? 0 : 1;
  return bars;
}

static std::vector<Vec3> places_for(std::mt19937& rng, const Bars& bars, int n) {
  std::uniform_real_distribution<double> u(0.0, 1.0);
  std::vector<Vec3> out;
  for (int k = 0; k < n; ++k) {
    if (!bars.bars.empty() && u(rng) < 0.7) {   // near a bar: along it, pushed off its line by up to 1.6 mm
      const Bar& b = bars.bars[static_cast<std::size_t>(u(rng) * static_cast<double>(bars.bars.size())) % bars.bars.size()];
      const double t = u(rng);
      out.push_back({b.a.x + t * (b.b.x - b.a.x) + (u(rng) - 0.5) * 3.2, b.a.y + t * (b.b.y - b.a.y) + (u(rng) - 0.5) * 3.2,
                     std::min(b.a.z, b.b.z) - 0.5 * b.width + (u(rng) - 0.5) * 1.2});
    } else {
      out.push_back({u(rng) * 60.0 - 30.0, u(rng) * 50.0 - 25.0, u(rng) * 30.0 - 2.0});
    }
  }
  return out;
}

int main() {
  // G1, G2: random tangles against the every-bar form
  std::size_t places_read = 0, reached = 0;
  for (std::uint32_t seed = 1; seed <= 60; ++seed) {
    std::mt19937 rng(seed);
    std::vector<char> present;
    const Bars bars = tangle(rng, 40 + static_cast<int>(seed % 7) * 15, present);
    const std::vector<Vec3> places = places_for(rng, bars, 300);
    const std::vector<int> regions{7};
    for (const std::vector<char>& use : {present, std::vector<char>{}}) {
      for (const double layer : {0.2, 0.28, 0.0}) {
        const auto ref = weave_findings_every_bar(bars, regions, use, places, layer);
        const auto got = weave_findings(bars, regions, use, places, layer);
        CHECK(ref.size() == got.size());
        const WeaveFindingsIndex index(bars, regions, use, layer);
        for (std::size_t k = 0; k < places.size() && k < got.size(); ++k) {
          CHECK(same(ref[k], got[k]));
          CHECK(same(ref[k], index.at(places[k])));
          ++places_read;
          reached += ref[k].reached;
        }
      }
    }
  }
  CHECK(reached > 1000);   // the places really read bars (the comparison is not of zeros)

  // G3: edge cases
  {
    Bars none;
    CHECK(weave_findings(none, {7}, {}, {{0, 0, 0}}, 0.2).size() == 1);
    CHECK(weave_findings(none, {7}, {}, {{0, 0, 0}}, 0.2)[0].reached == 0);
    Bars one;
    Bar b;
    b.a = {0, 0, 0};
    b.b = {5, 0, 0};
    b.width = 1.0;
    b.region = 7;
    one.bars.push_back(b);
    CHECK(weave_findings(one, {7}, {}, {}, 0.2).empty());
    Bar bad = b;
    bad.b = {std::numeric_limits<double>::quiet_NaN(), 0, 0};
    one.bars.push_back(bad);
    Bar inf = b;
    inf.a = {-std::numeric_limits<double>::infinity(), 0, 0};
    one.bars.push_back(inf);
    std::vector<Vec3> on_lines;
    for (double x = -5.0; x <= 10.0; x += BarGrid::kCell / 2.0)
      for (double z = -2.5; z <= 2.5; z += BarGrid::kCell / 2.0) on_lines.push_back({x, 0.0, z});
    on_lines.push_back({std::numeric_limits<double>::quiet_NaN(), 0, 0});
    const auto ref = weave_findings_every_bar(one, {7}, {}, on_lines, 0.2);
    const auto got = weave_findings(one, {7}, {}, on_lines, 0.2);
    for (std::size_t k = 0; k < on_lines.size(); ++k) CHECK(same(ref[k], got[k]));
  }

  // G4: every bar that can read a place is filed in that place's cell
  {
    std::mt19937 rng(99);
    std::vector<char> present;
    const Bars bars = tangle(rng, 120, present);
    const BarGrid grid(bars);
    std::uniform_real_distribution<double> u(0.0, 1.0);
    for (std::size_t i = 0; i < bars.bars.size(); ++i) {
      const Bar& x = bars.bars[i];
      const double r = 0.5 * x.width + 0.34;
      for (int k = 0; k < 6; ++k) {
        const double t = u(rng);
        const Vec3 on{x.a.x + t * (x.b.x - x.a.x), x.a.y + t * (x.b.y - x.a.y), x.a.z + t * (x.b.z - x.a.z)};
        const Vec3 off[3] = {{on.x + r, on.y, on.z}, {on.x, on.y - r, on.z}, {on.x, on.y, on.z + r}};
        for (const Vec3& p : off) {
          bool found = false;
          for (std::uint32_t j : grid.near(p)) found = found || j == i;
          CHECK(found);
        }
      }
    }
  }

  // G5: end_joints — ends a hair apart are one joint, the numbering in order of first sight
  {
    Bars bars;
    Bar a;
    a.a = {0, 0, 0};
    a.b = {1, 0, 0};
    Bar b;
    b.a = {1 + 4e-6, 0, 0};
    b.b = {2, 0, 0};
    Bar c;
    c.a = {2, 3e-6, 0};
    c.b = {0, 0, 1e-6};
    bars.bars = {a, b, c};
    const auto j = end_joints(bars);
    CHECK(j.size() == 6);
    CHECK(j[0] == 0 && j[1] == 1 && j[2] == 1 && j[3] == 2 && j[4] == 2 && j[5] == 0);
  }

  std::printf("weave_findings_grid: %d checks, %d failed (%zu places compared)\n", g_checks, g_fail, places_read);
  return g_fail == 0 ? 0 : 1;
}
