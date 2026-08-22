// Unit tests for ORGANIC's printability passes (task 2026-08-21-organic-lattice):
// the node MERGE, the SUPPORT-based prune, the stranded-piece drop, and the rule that
// a BOUNDARY FINISH is a look and never a structural intervention.
//
// Same self-contained CHECK harness as test_lattice_gen.cpp (ARCHITECTURE §4 locks the
// dependency set).
//
// ★ WHY THESE FOUR AND NOT A GOLDEN MESH. Every one of these bars encodes a defect the
// MAINTAINER found by looking at a shipped STL, after a measurement of mine had reported
// the geometry was fine. They are written against the smallest fixture that reproduces
// the shape of each defect, so a regression names the pass rather than the file.
//
//   B1 BUNDLE      — struts that all END at one point support nothing, however many of
//                    them there are. The old test ("is the tip inside another span's
//                    solid") passed on exactly this and left the whiskers in the file.
//   B2 CHAIN/TEE   — and the fix must NOT eat what is genuinely held: a polyline
//                    continuing, and a strut landing on another's body, both survive.
//   B3 MERGE       — endpoints within one bead are ONE node (Daynes et al.'s "merged
//                    or deleted"; deleting alone left the bundles behind).
//   B4 FINISH      — the structural passes are identical whatever finish is asked for.

#include "topopt/lattice_boundary.hpp"
#include "topopt/mesh.hpp"
#include "topopt/organic_lattice.hpp"

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

using namespace topopt;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                            \
  do {                                                              \
    ++g_checks;                                                     \
    if (!(cond)) {                                                  \
      ++g_failures;                                                 \
      std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, (msg));   \
    }                                                               \
  } while (0)

namespace {

// A sink that only counts, so a bar can talk about what was EMITTED without a mesh.
struct CountingSink : TriangleSink {
  std::uint64_t triangles = 0;
  void add_triangle(const Vec3&, const Vec3&, const Vec3&) override { ++triangles; }
};

OrganicLattice one_curve(const std::vector<Vec3>& pts, double r) {
  OrganicLattice lat;
  OrganicCurve c;
  c.family = 0;
  c.points = pts;
  c.radius_mm = r;
  double len = 0.0;
  for (std::size_t i = 1; i < pts.size(); ++i) {
    const Vec3 d{pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y,
                 pts[i].z - pts[i - 1].z};
    len += std::sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
  }
  c.length_mm = len;
  lat.curves.push_back(c);
  return lat;
}

void add_curve(OrganicLattice& lat, const std::vector<Vec3>& pts, double r) {
  OrganicLattice tmp = one_curve(pts, r);
  lat.curves.push_back(tmp.curves.front());
}

std::vector<OrganicSpan> run(const OrganicLattice& lat, OrganicGenStats& st) {
  CountingSink sink;
  std::vector<OrganicSpan> out;
  st = generate_organic_lattice(lat, sink, nullptr, 8, nullptr, &out);
  return out;
}

double seg_len(const OrganicSpan& s) {
  const Vec3 d{s.b.x - s.a.x, s.b.y - s.a.y, s.b.z - s.a.z};
  return std::sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
}

// ── B1: a BUNDLE supports nothing ──────────────────────────────────────────────
// Six struts fanning up from a common base plane and all ENDING at the same point
// in the air. Every tip lies inside its siblings' solids, so the containment test
// this file used to apply called all six supported. They are cantilevers and the
// support test must cut them.
void test_bundle_is_not_support() {
  const double r = 0.21;
  OrganicLattice lat;
  const Vec3 apex{0.0, 0.0, 6.0};
  for (int k = 0; k < 6; ++k) {
    const double a = k * (2.0 * 3.14159265358979323846 / 6.0);
    const Vec3 base{2.0 * std::cos(a), 2.0 * std::sin(a), 0.0};
    add_curve(lat, {base, apex}, r);
  }
  OrganicGenStats st;
  const std::vector<OrganicSpan> spans = run(lat, st);
  CHECK(st.free_ends == 0, "B1: a bundle must leave no free end behind");
  double zmax = 0.0;
  for (const OrganicSpan& s2 : spans) zmax = std::max(zmax, std::max(s2.a.z, s2.b.z));
  CHECK(spans.empty(),
        "B1: six struts meeting only each other at one tip hold nothing up and must "
        "all be cut");
  CHECK(zmax <= 0.5,
        "B1: nothing may be left standing in the air once the bundle is cut");
  CHECK(st.pruned_spans > 0, "B1: the prune must report what it cut");
}

// ── B2: what IS held must survive ──────────────────────────────────────────────
// (a) a polyline continuing through its own interior vertices, and
// (b) a strut landing on the BODY of a long member (a T on a beam).
// Both are supported and neither may be pruned. This is the bar that stops the
// support test from being "delete everything with a tip".
void test_chain_and_tee_survive() {
  const double r = 0.21;
  OrganicLattice lat;
  // A PORTAL FRAME, so that everything in it is genuinely held and the prune has no
  // honest reason to touch any of it:
  //   beam   -8..+8 at z = 3, as a polyline THROUGH its own interior vertex
  //   legs   from the plate up to each beam end   (tip-to-tip, leading away)
  //   stem   from the plate up to the beam's interior vertex
  //   tee    from the plate up to the MIDDLE of the beam's right span — an interior
  //          contact, the other way a tip can be supported
  add_curve(lat, {{-8.0, 0.0, 3.0}, {0.0, 0.0, 3.0}, {8.0, 0.0, 3.0}}, r);
  add_curve(lat, {{-8.0, 0.0, 0.0}, {-8.0, 0.0, 3.0}}, r);
  add_curve(lat, {{8.0, 0.0, 0.0}, {8.0, 0.0, 3.0}}, r);
  add_curve(lat, {{0.0, 0.0, 0.0}, {0.0, 0.0, 3.0}}, r);
  add_curve(lat, {{4.0, 0.0, 0.0}, {4.0, 0.0, 3.0}}, r);
  OrganicGenStats st;
  const std::vector<OrganicSpan> spans = run(lat, st);
  double total = 0.0;
  for (const OrganicSpan& s2 : spans) total += seg_len(s2);
  CHECK(st.free_ends == 0, "B2: a portal frame has no free end");
  CHECK(st.pruned_spans == 0,
        "B2: nothing in a fully-held frame may be cut — this is the bar that stops "
        "the support test degenerating into 'delete anything with a tip'");
  CHECK(spans.size() >= 6,
        "B2: two beam spans, two legs, the stem and the tee must all survive");
  CHECK(total > 24.0,
        "B2: beam 16 mm + legs 6 mm + stem 3 mm + tee 3 mm must still be emitted");
}

// ── B3: endpoints within one bead are ONE node ─────────────────────────────────
// Two curves whose ends miss each other by a third of a bead. Un-merged they are two
// tips near each other — which is precisely the shape the bundle bar rejects. Merged
// they are a joint, and the structure survives.
void test_node_merge_joins_near_misses() {
  const double r = 0.21;
  const double gap = 0.6 * r;   // well inside kOrganicNodeMergeRatio * r
  OrganicLattice lat;
  add_curve(lat, {{-6.0, 0.0, 0.0}, {0.0, 0.0, 0.0}}, r);
  add_curve(lat, {{gap, 0.0, 0.0}, {6.0, 0.0, 0.0}}, r);
  OrganicGenStats st;
  const std::vector<OrganicSpan> spans = run(lat, st);
  CHECK(st.merge_clusters > 0, "B3: the near-miss pair must be merged into one node");
  CHECK(st.nodes_merged >= 2, "B3: both endpoints are snapped");
  CHECK(!spans.empty(), "B3: merging must not delete the structure");
  CHECK(st.free_ends == 0, "B3: after merging there is no free end");
}

// ── B4: a FINISH is a look ─────────────────────────────────────────────────────
// The structural passes must produce the same spans whichever finish is asked for.
// This is the maintainer's ruling, and it was FALSE for a while: the finish ran before
// the prune and changed what got cut (1,588 spans against 1,210 for the same part).
void test_finish_does_not_change_the_structure() {
  const double r = 0.21;
  OrganicLattice base;
  add_curve(base, {{-8.0, 0.0, 0.0}, {0.0, 0.0, 0.0}, {8.0, 0.0, 0.0}}, r);
  add_curve(base, {{0.0, -8.0, 0.0}, {0.0, 0.0, 0.0}, {0.0, 8.0, 0.0}}, r);
  add_curve(base, {{0.0, 0.0, 6.0}, {0.0, 0.0, 0.0}}, r);

  std::vector<std::vector<OrganicSpan>> got;
  for (int mode = 0; mode < 3; ++mode) {
    OrganicLattice lat = base;
    lat.net_skin_finish = mode == 0   ? OrganicLattice::Finish::Clean
                          : mode == 1 ? OrganicLattice::Finish::Rim
                                      : OrganicLattice::Finish::Skin;
    lat.net_skin_reach_mm = 3.0;
    OrganicGenStats st;
    got.push_back(run(lat, st));
  }
  // With no boundary there are no surface nodes, so no finish can add anything and
  // all three must be identical span for span — the strongest form of the bar.
  CHECK(got[0].size() == got[1].size() && got[1].size() == got[2].size(),
        "B4: the three finishes must emit the same number of structural spans");
  bool same = got[0].size() == got[2].size();
  for (std::size_t i = 0; same && i < got[0].size(); ++i)
    same = got[0][i].a.x == got[2][i].a.x && got[0][i].a.y == got[2][i].a.y &&
           got[0][i].a.z == got[2][i].a.z && got[0][i].b.x == got[2][i].b.x &&
           got[0][i].b.y == got[2][i].b.y && got[0][i].b.z == got[2][i].b.z;
  CHECK(same, "B4: clean and skin must agree span for span on the structure");
}

// ── B5: determinism ────────────────────────────────────────────────────────────
void test_deterministic() {
  const double r = 0.21;
  OrganicLattice lat;
  add_curve(lat, {{-8.0, 0.0, 0.0}, {0.0, 0.0, 0.0}, {8.0, 0.0, 0.0}}, r);
  add_curve(lat, {{0.0, 0.0, 4.0}, {0.0, 0.0, 0.0}}, r);
  OrganicGenStats s1, s2;
  const std::vector<OrganicSpan> a = run(lat, s1);
  const std::vector<OrganicSpan> b = run(lat, s2);
  bool same = a.size() == b.size();
  for (std::size_t i = 0; same && i < a.size(); ++i)
    same = a[i].a.x == b[i].a.x && a[i].a.y == b[i].a.y && a[i].a.z == b[i].a.z &&
           a[i].b.x == b[i].b.x && a[i].b.y == b[i].b.y && a[i].b.z == b[i].b.z &&
           a[i].r == b[i].r;
  CHECK(same, "B5: two runs of the same lattice must be identical span for span");
  CHECK(s1.pruned_spans == s2.pruned_spans && s1.merge_clusters == s2.merge_clusters,
        "B5: the pass counters must be identical too");
}

}  // namespace

int main() {
  test_bundle_is_not_support();
  test_chain_and_tee_survive();
  test_node_merge_joins_near_misses();
  test_finish_does_not_change_the_structure();
  test_deterministic();
  std::printf("%s: %d checks, %d failures\n",
              g_failures == 0 ? "PASS" : "FAIL", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
