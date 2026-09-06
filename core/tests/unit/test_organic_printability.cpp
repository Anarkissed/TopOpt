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
#include "topopt/grading.hpp"
#include "topopt/lattice.hpp"
#include "topopt/observability.hpp"
#include "topopt/organic_lattice.hpp"

#include <cmath>
#include <functional>
#include <map>
#include <set>
#include <cstdio>
#include <cstdlib>
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
// Fraction of total span length lying in components (welded by node contact within
// r+r, the solver's rule) that have at least one endpoint on the plate -- the
// lowest z in the set, within one radius. "Rooted" in a fixture without part solid.
double rooted_length_fraction(const std::vector<OrganicSpan>& spans) {
  const std::size_t n = spans.size();
  if (n == 0) return 0.0;
  std::vector<int> par(2 * n);
  for (std::size_t i = 0; i < 2 * n; ++i) par[i] = static_cast<int>(i);
  std::function<int(int)> find = [&](int a) {
    while (par[static_cast<std::size_t>(a)] != a) {
      par[static_cast<std::size_t>(a)] = par[static_cast<std::size_t>(par[static_cast<std::size_t>(a)])];
      a = par[static_cast<std::size_t>(a)];
    }
    return a;
  };
  auto unite = [&](int a, int b) { par[static_cast<std::size_t>(find(a))] = find(b); };
  double zmin = spans[0].a.z;
  for (const OrganicSpan& s : spans) zmin = std::min(zmin, std::min(s.a.z, s.b.z));
  auto pt = [&](std::size_t k) { return (k & 1) ? spans[k >> 1].b : spans[k >> 1].a; };
  for (std::size_t i = 0; i < n; ++i) unite(static_cast<int>(2 * i), static_cast<int>(2 * i + 1));
  for (std::size_t i = 0; i < 2 * n; ++i)
    for (std::size_t j = i + 1; j < 2 * n; ++j) {
      const Vec3 p = pt(i), q = pt(j);
      const double reach = spans[i >> 1].r + spans[j >> 1].r;
      const Vec3 d{p.x - q.x, p.y - q.y, p.z - q.z};
      if (d.x * d.x + d.y * d.y + d.z * d.z <= reach * reach)
        unite(static_cast<int>(i), static_cast<int>(j));
    }
  std::map<int, double> len;
  std::set<int> rooted;
  double total = 0.0;
  for (std::size_t i = 0; i < n; ++i) {
    const int root = find(static_cast<int>(2 * i));
    const double L = seg_len(spans[i]);
    len[root] += L; total += L;
    if (std::min(spans[i].a.z, spans[i].b.z) - zmin <= spans[i].r) rooted.insert(root);
  }
  double ok = 0.0;
  for (int r : rooted) ok += len[r];
  return total > 0.0 ? ok / total : 0.0;
}

// ── B1: a BUNDLE supports nothing -- but a TEPEE stands ───────────────────────
// Six struts fanning up from a common base and all ENDING at the same point in the
// air. Every tip lies inside its siblings' solids, so the containment test this file
// used to apply called all six supported. The first version of this test then asked
// for all six to be CUT -- and that was wrong physics: their bases are on the plate,
// so each strut is held at one end and the six together are a tepee, which prints.
// What the bundle cannot do is hold anything ELSE up, and a bundle whose bases are in
// the air is held nowhere. Two cases, both measured (2026-09-05, after the prune
// became "doomed only when NEITHER end is held").
// ── S1: a dead wall gets a coherent synthetic field; a live one is untouched ────
// ── P1: the probe's rooting measure ─────────────────────────────────────────────
void test_probe_rooting() {
  OrganicLattice lat;
  lat.grid_origin = Vec3{0, 0, 0}; lat.grid_h = 1.0; lat.grid_nx = 20; lat.grid_ny = 4; lat.grid_nz = 12;
  lat.part_solid.assign(static_cast<std::size_t>(20 * 4 * 12), 0);
  for (int k = 0; k < 12; ++k) for (int j = 0; j < 4; ++j) for (int i = 0; i < 2; ++i)
    lat.part_solid[(static_cast<std::size_t>(k) * 4 + j) * 20 + i] = 1;
  add_curve(lat, {Vec3{2.2, 2.0, 1.0}, Vec3{6.0, 2.0, 1.0}}, 0.3);     // A touches the slab
  add_curve(lat, {Vec3{10.0, 2.0, 1.0}, Vec3{14.0, 2.0, 1.0}}, 0.3);   // B floats
  add_curve(lat, {Vec3{14.1, 2.0, 1.0}, Vec3{18.0, 2.0, 1.0}}, 0.3);   // C touches B
  std::vector<int> rid(static_cast<std::size_t>(20 * 4 * 12), 1);
  const OrganicProbeResult pr = probe_organic_rooting(lat, rid);
  CHECK(pr.curves == 3, "P1: three curves measured");
  CHECK(pr.components == 2, "P1: A alone, B+C welded by contact = two components");
  CHECK(std::fabs(pr.rooted_mm - 3.8) < 1e-6, "P1: only A's 3.8 mm is rooted (touches the slab)");
  CHECK(std::fabs(pr.traced_mm - (3.8 + 4.0 + 3.9)) < 1e-6, "P1: traced length is the sum");
  CHECK(pr.regions.size() == 1 && pr.regions[0].region_id == 1 && pr.regions[0].curves == 3,
        "P1: one region, id 1, holding all three curves");
}

void test_synthetic_focal_stress() {
  VoxelGrid grid;
  grid.nx = 20; grid.ny = 4; grid.nz = 12; grid.spacing = 1.0;
  grid.origin = Vec3{0, 0, 0};
  grid.tags.assign(static_cast<std::size_t>(20 * 4 * 12), VoxelTag::Interior);  // voxel_count() is tags.size()
  const std::size_t n = grid.voxel_count();
  std::vector<char> cand(n, 1);
  std::vector<int> rid(n, 0);
  std::vector<double> stress(6 * n, 0.0);
  // region 1: x < 10 DEAD (zero tensor); region 2: x >= 10 LIVE (uniaxial 1.0 in z)
  for (std::size_t e = 0; e < n; ++e) {
    const int i = static_cast<int>(e % 20);
    rid[e] = i < 10 ? 1 : 2;
    if (i >= 10) stress[6 * e + 2] = 1.0;
  }
  std::vector<SyntheticStressRegion> cfg;
  { SyntheticStressRegion c; c.region_id = 1; c.face_id = 7; c.foci = 4; cfg.push_back(c); }
  const std::vector<double> before = stress;
  const SyntheticStressReport rep =
      synthesize_focal_stress(grid, cand, rid, cfg, 0.02, stress);
  CHECK(rep.regions == 1, "S1: one configured region found");
  CHECK(rep.per_region.size() == 1 && rep.per_region[0].face_id == 7 &&
            rep.per_region[0].foci == 4 && rep.per_region[0].voxels == n / 2 &&
            rep.per_region[0].fully_synthetic == n / 2 && rep.per_region[0].soft_mm > 0.0,
        "S1: the per-region entry carries the face id, foci, counts and the resolved softening");
  CHECK(rep.voxels_in_regions == n / 2, "S1: the region holds half the voxels");
  CHECK(rep.voxels_fully_synthetic == n / 2,
        "S1: every dead voxel is fully synthetic (real weight < 0.05)");
  // the live region is byte-identical
  bool live_same = true;
  for (std::size_t e = 0; e < n; ++e)
    if (rid[e] == 2)
      for (int c = 0; c < 6; ++c)
        if (stress[6 * e + c] != before[6 * e + c]) live_same = false;
  CHECK(live_same, "S1: a live region is untouched");
  // every dead voxel now has a non-degenerate principal frame, at LOW magnitude.
  // (von Mises > 0 is exactly "not hydrostatic", i.e. the eigenvalues are not all
  // equal and a principal direction exists -- the tracer's eigen routine is its own
  // internal, so the test reads the invariant rather than the routine.)
  std::size_t framed = 0, low = 0;
  for (std::size_t e = 0; e < n; ++e) {
    if (rid[e] != 1) continue;
    double m[6]; for (int c = 0; c < 6; ++c) m[c] = stress[6 * e + c];
    const double sxx = m[0], syy = m[1], szz = m[2];
    const double vm = std::sqrt(std::max(0.0, 0.5 * ((sxx - syy) * (sxx - syy) +
        (syy - szz) * (syy - szz) + (szz - sxx) * (szz - sxx)) +
        3.0 * (m[3] * m[3] + m[4] * m[4] + m[5] * m[5])));
    if (vm > 0.0) ++framed;
    if (vm > 0.0 && vm <= 0.02 * 1.0 + 1e-9) ++low;
  }
  CHECK(framed == n / 2, "S1: every dead voxel has a principal direction after synthesis");
  CHECK(low == n / 2, "S1: the synthetic magnitude is the dead threshold, not the peak");
  // foci count is honoured: 1 focus gives a pure radial field -- the major direction
  // at a voxel points along the ray from the focus, so two voxels on opposite sides of
  // the region centre have major directions that differ; with the same seed the
  // report says one region either way
  std::vector<SyntheticStressRegion> cfg1;
  { SyntheticStressRegion c; c.region_id = 1; c.foci = 1; cfg1.push_back(c); }
  std::vector<double> s1(6 * n, 0.0);
  const SyntheticStressReport r1 = synthesize_focal_stress(grid, cand, rid, cfg1, 0.02, s1);
  CHECK(r1.regions == 1 && r1.voxels_fully_synthetic == n / 2,
        "S1: a single focus is accepted and fills the dead region");
  // nothing dead anywhere: no voxel changes
  std::vector<double> live(6 * n, 0.0);
  for (std::size_t e = 0; e < n; ++e) live[6 * e + 2] = 1.0;
  const std::vector<double> live_before = live;
  const SyntheticStressReport r2 = synthesize_focal_stress(grid, cand, rid, cfg, 0.02, live);
  CHECK(r2.voxels_fully_synthetic == 0 && r2.voxels_blended == 0 && live == live_before,
        "S1: a region that carries load is not touched at all");
}
void test_bundle_is_not_support() {
  const double r = 0.21;
  const double kPi = 3.14159265358979323846;
  {
    // (a) rooted tepee: six legs on the plate meeting at an apex. Stands.
    OrganicLattice lat;
    const Vec3 apex{0.0, 0.0, 6.0};
    for (int k = 0; k < 6; ++k) {
      const double a = k * (2.0 * kPi / 6.0);
      const Vec3 base{2.0 * std::cos(a), 2.0 * std::sin(a), 0.0};
      add_curve(lat, {base, apex}, r);
    }
    OrganicGenStats st;
    const std::vector<OrganicSpan> spans = run(lat, st);
    double zmax = 0.0, total = 0.0;
    for (const OrganicSpan& s2 : spans) {
      zmax = std::max(zmax, std::max(s2.a.z, s2.b.z));
      total += seg_len(s2);
    }
    CHECK(!spans.empty(), "B1a: a tepee of six legs rooted on the plate must survive");
    CHECK(zmax > 5.5, "B1a: the tepee must still reach its apex -- nothing unravelled");
    CHECK(total > 0.9 * 6.0 * std::sqrt(2.0 * 2.0 + 6.0 * 6.0),
          "B1a: essentially all six legs must be there (rooted material is not pruned)");
  }
  {
    // (b) floating bundle: the same six struts lifted 3 mm off the plate, beside one
    // rooted post that defines the plate. The bundle's bases are in the air and its
    // apex is held only by its siblings folding back -- no end is held, so it is cut,
    // and the post is not.
    OrganicLattice lat;
    add_curve(lat, {Vec3{10.0, 10.0, 0.0}, Vec3{10.0, 10.0, 6.0}}, r);
    const Vec3 apex{0.0, 0.0, 9.0};
    for (int k = 0; k < 6; ++k) {
      const double a = k * (2.0 * kPi / 6.0);
      const Vec3 base{2.0 * std::cos(a), 2.0 * std::sin(a), 3.0};
      add_curve(lat, {base, apex}, r);
    }
    OrganicGenStats st;
    const std::vector<OrganicSpan> spans = run(lat, st);
    if (std::getenv("B1_DEBUG")) {
      std::fprintf(stderr, "[B1b] pruned %zu stranded %zu cut %zu legs %zu out %zu\n",
                   st.pruned_spans, st.stranded_spans_dropped, st.support_spans_cut,
                   st.repair_legs_added, spans.size());
      for (const OrganicSpan& s2 : spans)
        std::fprintf(stderr, "[B1b]   (%.2f,%.2f,%.2f)-(%.2f,%.2f,%.2f) r %.2f\n",
                     s2.a.x, s2.a.y, s2.a.z, s2.b.x, s2.b.y, s2.b.z, s2.r);
    }
    double zmax_bundle = 0.0;
    for (const OrganicSpan& s2 : spans)
      if (std::fabs(s2.a.x - 10.0) > 1.0 || std::fabs(s2.a.y - 10.0) > 1.0)
        zmax_bundle = std::max(zmax_bundle, std::max(s2.a.z, s2.b.z));
    CHECK(zmax_bundle <= 0.5,
          "B1b: six struts in the air meeting only each other at one tip hold nothing "
          "up and are held by nothing -- all six must be cut");
    CHECK(st.pruned_spans + st.stranded_spans_dropped + st.support_spans_cut > 0,
          "B1b: the pass that removed the floating bundle must report it");
    bool post = false;
    for (const OrganicSpan& s2 : spans)
      if (std::fabs(s2.a.x - 10.0) <= 1.0 && std::fabs(s2.a.y - 10.0) <= 1.0 &&
          std::max(s2.a.z, s2.b.z) > 5.5) post = true;
    CHECK(post, "B1b: the rooted post beside the bundle must survive untouched");
  }
}
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

// ── B6: ONE CELL PER MEMBER IS REACHABLE ONLY WITH A BOUNDARY FINISH ───────────
// The maintainer's call, and the measurement behind it is in
// evidence/2026-08-21-organic-lattice/cpm/README.md: a BARE 1-cell member is 18x
// softer than its certificate at a quarter-cell phase shift (+1917 %), and a skin on
// the cut faces collapses that spread to ~10 points AND flips the model to the
// conservative side. So the relaxation is tied to the finish, never to the intent
// alone, and a caller that says nothing gets the safe floor.
void test_one_cell_needs_a_finish() {
  const LatticeTopology t = LatticeTopology::Octet;
  CHECK(aesthetic_cells_per_member_hard_floor(t, true) == 1.0,
        "B6: with a finish written the hard floor is one cell");
  CHECK(aesthetic_cells_per_member_hard_floor(t, false) == 2.0,
        "B6: bare, it stays at the measured bending point of two");
  CHECK(aesthetic_cells_per_member_hard_floor(t) == 2.0,
        "B6: the no-argument form must give the SAFE answer — relaxing by omission is "
        "how a bare 1-cell member ships");
  // A heavily loaded voxel must NOT reach one cell just because a finish exists: the
  // accuracy floor still governs the rows the budget applies to.
  const double loaded = aesthetic_cells_per_member_floor(t, 1.0, 0.01, true);
  const double idle = aesthetic_cells_per_member_floor(t, 0.0, 0.01, true);
  CHECK(idle == 1.0, "B6: material carrying nothing reaches one cell with a finish");
  CHECK(aesthetic_cells_per_member_floor(t, kUnloadedUtilisationMax, 0.01, true) == 1.0,
        "B6: one cell holds right up to the unloaded threshold");
  CHECK(aesthetic_cells_per_member_floor(t, 2.0 * kUnloadedUtilisationMax, 0.01, true) > 1.0,
        "B6: and stops immediately past it — the skinned measurement is one fixture, "
        "not a licence at any load");
  CHECK(loaded > 1.0,
        "B6: material at full utilisation must not reach one cell even with a finish");
  CHECK(aesthetic_cells_per_member_floor(t, 0.0, 0.01, false) == 2.0,
        "B6: the same idle voxel stops at two cells when nothing is written on the "
        "boundary");
}

}  // namespace

// ══════════════════════════════════════════════════════════════════════════════════
// ★★★ B7-B10: THE BARS THIS SESSION'S DEFECTS WOULD HAVE FAILED ★★★
//
// Every one of these encodes a pass that reported success while emitting nothing, or a
// measurement that answered a different question than the one asked. All four were
// found by the maintainer looking at a slice after my numbers said the geometry was
// fine — the same way B1-B4 were found — and all four presented as ACCEPTED, converged,
// one component, with the defect fully present.

// ── THE FIXTURE THE MAT BARS NEED ────────────────────────────────────────────────
// Reaching the base mat at all takes more than "some struts on a plane", and finding
// that out cost four failed fixtures. The base-plane rule wants THREE things at once:
//   * `layer_height_mm > 0` — without it the trim never runs (it rasters Z at the
//     machine's pitch, and refuses to invent one);
//   * a layer whose area is >= half the fattest layer's — so stilts are skipped;
//   * whose largest CONNECTED cross-section is >= half that layer — so a field of
//     separate uprights never qualifies, however many there are.
// Hence a connected slab (uprights tied horizontally) standing on thin stilts: the
// stilts are the thin layers the rule steps over, the slab is the base it lands on.
OrganicLattice mat_fixture(int n = 5, double pitch = 2.0, double r = 0.35,
                           int stilts = 3, double drop = 2.0) {
  OrganicLattice lat;
  for (int i = 0; i < n; ++i)
    for (int j = 0; j < n; ++j)
      add_curve(lat, {Vec3{pitch * i, pitch * j, 0.0}, Vec3{pitch * i, pitch * j, 6.0}}, r);
  for (double z : {0.0, 3.0, 6.0}) {
    for (int i = 0; i < n; ++i)
      add_curve(lat, {Vec3{pitch * i, 0.0, z}, Vec3{pitch * i, pitch * (n - 1), z}}, r);
    for (int j = 0; j < n; ++j)
      add_curve(lat, {Vec3{0.0, pitch * j, z}, Vec3{pitch * (n - 1), pitch * j, z}}, r);
  }
  for (int k = 0; k < stilts; ++k)
    add_curve(lat, {Vec3{pitch * k, 0.0, -drop}, Vec3{pitch * k, 0.0, 0.0}}, r);
  lat.base_mat = true;
  lat.trim_below_base = true;
  lat.layer_height_mm = 0.2;
  return lat;
}

// ── B7: A MAT THAT COUNTS FEET MUST LAY FLOOR ─────────────────────────────────────
// On one grading the base mat reported 1336 touchdowns and emitted 0 struts: the debug
// line looked healthy, the verdict was ACCEPTED, and the part had no foundation at all.
// A pass that finds work and then does none of it is what this file exists to catch.
//
// ★ THE PRECONDITION IS ASSERTED, NOT ASSUMED. Written as `if (touchdowns > 0) CHECK`,
// this bar passed VACUOUSLY on a fixture that never reached the mat — the same "green
// run measuring nothing" it was written to prevent, reproduced inside the test.
void test_mat_that_counts_feet_lays_floor() {
  const OrganicLattice lat = mat_fixture();
  OrganicGenStats st;
  run(lat, st);
  CHECK(st.base_trim_found,
        "B7 precondition: the fixture must actually reach the base trim, or every "
        "check below passes by not running");
  CHECK(st.base_mat_touchdowns > 0,
        "B7 precondition: a slab standing on the base plane has feet");
  CHECK(st.base_mat_struts > 0,
        "B7: the mat found touchdowns and must emit struts for them — reporting feet "
        "while laying no floor is how a cube shipped with no foundation");
  CHECK(st.base_mat_length_mm > 0.0,
        "B7: mat struts must carry length; a count without length is not geometry");
}

// ── B8: THE MAT MAY NOT BE THINNER THAN THE RASTER THAT MESHES IT ────────────────
// Halving the mat radius on measured grounds drove its height to 0.273 mm against a
// weld pitch of 0.28 — under one voxel — and the mat VANISHED from the slice while
// every statistic still read green. With the pitch declared, the mat must still be
// emitted; the generator raises the radius rather than emitting into nothing.
void test_mat_survives_the_weld_raster() {
  OrganicLattice lat = mat_fixture();
  lat.weld_pitch_hint_mm = 0.28;
  OrganicGenStats st;
  run(lat, st);
  CHECK(st.base_trim_found, "B8 precondition: the fixture must reach the base trim");
  CHECK(st.base_mat_struts > 0,
        "B8: a mat must survive the raster that will mesh it — below two weld voxels "
        "it is erased outright, and the generator must raise it rather than emit it");
}

// ── B9: SLENDERNESS IS THE UNSUPPORTED SPAN, NOT THE WHOLE STRUT ─────────────────
// Measured on total length the check called 1541 struts too slender and then found
// "nothing beneath" for every one of them — material WAS there, it just was not being
// counted as support. A bar lying across a bed of struts is not a bridge of its own
// length. Same bar, twice: propped along its run, and spanning free air.
void test_slenderness_reads_the_unsupported_span() {
  const double r = 0.30;
  const double span = 24.0;

  OrganicLattice held;
  add_curve(held, {Vec3{0.0, 0.0, 6.0}, Vec3{span, 0.0, 6.0}}, r);
  for (double x = 0.0; x <= span + 1e-9; x += 3.0)
    add_curve(held, {Vec3{x, 0.0, 0.0}, Vec3{x, 0.0, 6.0}}, r);
  OrganicGenStats st_held;
  run(held, st_held);

  OrganicLattice bridge;
  add_curve(bridge, {Vec3{0.0, 0.0, 6.0}, Vec3{span, 0.0, 6.0}}, r);
  add_curve(bridge, {Vec3{0.0, 0.0, 0.0}, Vec3{0.0, 0.0, 6.0}}, r);
  add_curve(bridge, {Vec3{span, 0.0, 0.0}, Vec3{span, 0.0, 6.0}}, r);
  OrganicGenStats st_bridge;
  run(bridge, st_bridge);

  CHECK(st_held.slenderness_violating <= st_bridge.slenderness_violating,
        "B9: a bar propped along its length is not more slender than the same bar "
        "spanning free air — reading total length instead of the unsupported run "
        "flagged 1541 struts and could prop none of them");
}

// ── B10: A COUNTER THAT IS SET MUST BE NON-ZERO WHERE IT APPLIES ─────────────────
// `base_mat_touchdowns` read 0 in the receipt for hours while the generator was
// measured carrying 684 — a stat wired into three of the four hops it must travel.
// This bar cannot see the JSON, but it holds the generator end honest: a silent zero
// is caught here rather than in a slice.
void test_stats_are_actually_populated() {
  const OrganicLattice lat = mat_fixture();
  OrganicGenStats st;
  run(lat, st);
  CHECK(st.base_trim_found, "B10 precondition: the fixture must reach the base trim");
  CHECK(st.base_trim_z_mm != 0.0,
        "B10: a found base trim carries a plane; a zero here is an unset field");
  CHECK(st.base_mat_touchdowns > 0,
        "B10: a slab standing on the base plane has touchdowns and they must be "
        "counted — a stat that is always zero is indistinguishable from a pass that "
        "never ran");
}

// ══════════════════════════════════════════════════════════════════════════════════
// ★★★ G1-G5: THE GROWTH GENERATOR ★★★
//
// `grow_organic_lattice` lays curves down in LAYER ORDER from the base and refuses any
// step whose underside is unsupported, so mid-air starts and free ends are not repaired
// but INEXPRESSIBLE. These five bars are the failures it actually produced while being
// built — every one of them returned a healthy-looking run with no geometry in it.
//
//   G1 PRODUCES      — it returned 0 curves FOUR separate ways (raster overrun, "no
//                      stress" read as "outside the part", the separation counting a
//                      tip's own trail, and again counting its parent's). A generator
//                      that silently makes nothing is the failure mode here.
//   G2 NO FALLBACK   — and when it made nothing it KEPT THE TRACED CURVES, so a total
//                      failure reported ACCEPTED with 13,342 spans and busy repairs.
//   G3 SUPPORTED     — every emitted point must have material beneath it. This is the
//                      whole claim: printability as a construction rule.
//   G4 CONE          — no step may fall below the printable angle from the plate.
//   G5 JOINS         — a crowded tip must REACH its neighbour, not stop 2 mm short in
//                      open air; stopping there is what left free ends for the prune to
//                      erode (2260 spans emitted, 2520 pruned).

// A block of candidate voxels with a simple uniaxial stress field: enough for the
// growth rule to have somewhere to grow and a direction to prefer.
struct GrowFixture {
  VoxelGrid grid;
  std::vector<char> cand;
  std::vector<double> stress;
  std::vector<double> spacing;
  OrganicParams params;
};

GrowFixture grow_fixture(int nx = 12, int ny = 12, int nz = 24, double h = 1.0) {
  GrowFixture f;
  f.grid.nx = nx; f.grid.ny = ny; f.grid.nz = nz;
  f.grid.spacing = h;
  f.grid.origin = Vec3{0, 0, 0};
  const std::size_t n = static_cast<std::size_t>(nx) * ny * nz;
  f.grid.tags.assign(n, VoxelTag::Interior);
  f.cand.assign(n, 1);
  f.stress.assign(6 * n, 0.0);
  for (std::size_t e = 0; e < n; ++e) f.stress[6 * e + 2] = 1.0;   // sigma_zz
  f.spacing.assign(n, 4.0);
  f.params.layer_hint_mm = 0.2;
  f.params.min_extrudable_width_mm = 0.4;
  f.params.strut_diameter_mm = 0.8;
  f.params.build_dir = Vec3{0, 0, 1};
  return f;
}

// ── G1: THE GENERATOR MUST PRODUCE GEOMETRY ─────────────────────────────────────
void test_growth_produces_curves() {
  GrowFixture f = grow_fixture();
  OrganicGenStats gs;
  const OrganicLattice lat =
      grow_organic_lattice(f.grid, f.cand, f.stress, f.spacing, nullptr, f.params, &gs);
  CHECK(gs.growth_seeds > 0,
        "G1: the region's floor must yield seeds — seeding off traced points gave NINE "
        "on a 40 mm cube");
  CHECK(gs.growth_steps > 0,
        "G1: tips must advance — every seed sat in a zero-stress voxel and 'no "
        "principal direction' was read as 'left the part', so each died after one step");
  CHECK(!lat.curves.empty(),
        "G1: growth must produce curves; four separate bugs made it return none while "
        "the run still reported ACCEPTED");
}

// ── G2: NO SILENT FALLBACK TO THE TRACED CURVES ─────────────────────────────────
void test_growth_does_not_fall_back() {
  GrowFixture f = grow_fixture();
  OrganicGenStats gs;
  const OrganicLattice grown =
      grow_organic_lattice(f.grid, f.cand, f.stress, f.spacing, nullptr, f.params, &gs);
  const OrganicLattice traced =
      trace_organic_lattice(f.grid, f.cand, f.stress, f.spacing, nullptr, f.params);
  if (gs.growth_curves == 0)
    CHECK(grown.curves.empty(),
          "G2: growth that produced nothing must RETURN nothing — keeping the traced "
          "curves made a total failure read as ACCEPTED with 13,342 spans");
  else
    CHECK(grown.curves.size() != traced.curves.size() ||
              grown.curves.front().points.size() != traced.curves.front().points.size(),
          "G2: grown curves must not be the traced ones passed through");
}

// ── G3: EVERY POINT IS SUPPORTED FROM BELOW ─────────────────────────────────────
// The architectural claim in one bar. A grown curve may only advance onto material
// that is already there, so no vertex may sit in open air above the base.
void test_growth_is_supported() {
  GrowFixture f = grow_fixture();
  OrganicGenStats gs;
  const OrganicLattice lat =
      grow_organic_lattice(f.grid, f.cand, f.stress, f.spacing, nullptr, f.params, &gs);
  if (lat.curves.empty()) { CHECK(false, "G3: no curves to check"); return; }
  double zmin = lat.curves.front().points.front().z;
  for (const OrganicCurve& c : lat.curves)
    for (const Vec3& p : c.points) zmin = std::min(zmin, p.z);
  // ★ A BRANCH LEGITIMATELY STARTS ABOVE THE FLOOR — on its parent, which is material
  // that already exists. So "every curve starts at z_min" is the WRONG bar and this one
  // asserted it. What must hold is that every start coincides with existing geometry:
  // either the floor, or a point on another curve.
  std::size_t rootless = 0;
  for (const OrganicCurve& c : lat.curves) {
    const Vec3 s0 = c.points.front();
    if (s0.z <= zmin + 3.0) continue;                  // on the floor
    bool on_another = false;
    for (const OrganicCurve& o : lat.curves) {
      if (&o == &c) continue;
      for (const Vec3& q : o.points) {
        const double dx = q.x - s0.x, dy = q.y - s0.y, dz = q.z - s0.z;
        // within a strut radius: a branch roots at its parent's CURRENT position,
        // which lies on the parent's centreline but not necessarily at a recorded
        // vertex. Coincidence is the wrong test; contact is the right one.
        if (dx * dx + dy * dy + dz * dz < 4.0) { on_another = true; break; }
      }
      if (on_another) break;
    }
    if (!on_another) ++rootless;
  }
  CHECK(rootless == 0,
        "G3: a curve starting above the floor must start ON another curve — growth "
        "advances only onto material that already exists, so a rootless start in open "
        "air cannot be produced");
}

// ── G4: NO STEP BELOW THE PRINTABLE ANGLE ───────────────────────────────────────
// ★★ TWO POPULATIONS, TWO BARS. The old form measured every segment together and
// allowed 25 % below the cone, on a SPARSE fixture chosen so that joins would be rare.
// Both halves of that were wrong. A blended bar cannot fail for the reason it exists:
// measured on the DEFAULT fixture (12x12x24, spacing 4.0), 68.2 % of segments sit
// below the cone and 66.8 % of material length is in them, so the 25 % bar would fail
// there — not because the cone is violated but because joins dominate. And the sparse
// fixture reads 18.2 %, passing while never exercising the regime that ships.
//
// The generator knows which segments are which, so ask it. A CLIMB is cone-clamped
// and must obey the cone with NO tolerance. A JOIN or DEFLECT lands on material at
// both ends — it is a bridge, not an overhang — so its bar is the horizontal RUN
// against kOrganicMaxCantileverMm, which is the limit this codebase already commits to.
void test_growth_respects_the_cone() {
  GrowFixture f = grow_fixture();            // ★ DEFAULT: the regime that ships
  OrganicGenStats gs;
  const OrganicLattice lat =
      grow_organic_lattice(f.grid, f.cand, f.stress, f.spacing, nullptr, f.params, &gs);
  const double cone = std::sin(kOrganicGrowthMinAngleDeg * 3.14159265358979323846 /
                               180.0);
  std::size_t climbs = 0, climb_below = 0, joins = 0, join_over = 0;
  double worst_run = 0.0, worst_climb_deficit = 0.0;
  for (const OrganicCurve& c : lat.curves) {
    // the tags must describe the segments they are parallel to, or every number
    // below is measured against the wrong geometry
    CHECK(c.seg_kind.size() + 1 == c.points.size(),
          "G4: seg_kind must be parallel to the segments of points");
    for (std::size_t i = 1; i < c.points.size(); ++i) {
      const Vec3 d{c.points[i].x - c.points[i - 1].x, c.points[i].y - c.points[i - 1].y,
                   c.points[i].z - c.points[i - 1].z};
      const double L = std::sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
      if (L < 1e-9) continue;
      const auto kind = static_cast<OrganicCurve::Seg>(c.seg_kind[i - 1]);
      if (kind == OrganicCurve::Seg::Climb) {
        ++climbs;
        if (d.z / L < cone - 1e-6) {
          ++climb_below;
          worst_climb_deficit = std::max(worst_climb_deficit, cone - d.z / L);
        }
      } else {
        ++joins;
        const double run = std::sqrt(d.x * d.x + d.y * d.y);
        if (run > worst_run) worst_run = run;
        if (run > kOrganicMaxCantileverMm + 1e-9) ++join_over;
      }
    }
  }
  CHECK(climbs > 0, "G4: there must be climbing segments to judge");
  CHECK(climb_below == 0,
        "G4: a CLIMBING step is cone-clamped and must never fall below the printable "
        "angle — no tolerance, because there is no mechanism that would produce one");
  CHECK(join_over == 0,
        "G4: a JOIN or DEFLECTION span lands on material at both ends, so it is a "
        "BRIDGE — its horizontal run must not exceed kOrganicMaxCantileverMm. Nothing "
        "checked this before: the run was bounded only by d_test, half the local "
        "SEPARATION (2.00 mm here = spacing 4.0 / 2). Measured, separation 8.0 puts "
        "d_test at 4.0 mm and yields 2406 joins over the 3.0 mm cap");
  (void)worst_run; (void)worst_climb_deficit; (void)joins;
}

// ── G5: A CROWDED TIP JOINS RATHER THAN STOPPING SHORT ──────────────────────────
void test_growth_joins_neighbours() {
  GrowFixture f = grow_fixture(16, 16, 20, 1.0);
  OrganicGenStats gs;
  grow_organic_lattice(f.grid, f.cand, f.stress, f.spacing, nullptr, f.params, &gs);
  if (gs.growth_curves > 1)
    CHECK(gs.growth_joins > 0,
          "G5: with many curves in one region some tip must crowd a neighbour and REACH "
          "it — stopping 2 mm short on a 0.66 mm strut left free ends the prune then "
          "ate, 2260 spans emitted against 2520 pruned");
}

// ── G8: CONNECTEDNESS, AND THE MATERIAL IT IS MEASURED ON ───────────────────────
// ★★ A RATIO IS PERFECT WHEN BOTH ITS TERMS ARE NEARLY ZERO. The first version of
// this test asserted components and largest-fraction alone, and sampled {4.0, 6.0,
// 8.0}. Both halves were too weak, and the sweep below is why:
//
//   sep 4.0 : 4086.2 mm grown ->  4199.0 mm written (102.8 %)  comp 1  largest 1.0000
//   sep 4.5 : 3736.7 mm grown ->   193.2 mm written (  5.2 %)  comp 5  largest 0.8628
//   sep 5.0 : 3878.8 mm grown ->    15.0 mm written (  0.4 %)  comp 2  largest 0.5995
//   sep 7.0 : 1248.1 mm grown ->   140.9 mm written ( 11.3 %)  comp 1  largest 1.0000
//
// Separation 7.0 reports ONE component and largest-fraction 1.0000 on ELEVEN PER CENT
// of the material. Separation 5.0 passed the old bars (comp <= 2, largest >= 0.54)
// with FIFTEEN MILLIMETRES of lattice. So every connectivity assertion here is now
// paired with a SURVIVAL bar, and the sweep is a sweep: 5.0 and 7.0 are both invisible
// from {4.0, 6.0, 8.0}, and the curve between them is not monotone.
//
// ★ Measured on the EMITTED SPANS via the existing union-find (segment distance <=
// sum of radii), never on the curve graph.
void test_growth_stays_connected() {
  // ★ THE FLOOR IS SET FROM THE MEASUREMENT, NOT GUESSED. Separation 4.0 survives at
  // 102.8 %; the failing separations sit at 0.4-15 %. 0.80 sits an order of magnitude
  // above the failures and comfortably below the one regime that works, so it fails
  // for the reason it exists rather than on noise.
  const double kSurvivalFloor = 0.80;

  auto measure = [](double sep, OrganicGenStats& grow_out, OrganicGenStats& emit_out) {
    GrowFixture f = grow_fixture();
    for (double& sp : f.spacing) sp = sep;
    const OrganicLattice lat = grow_organic_lattice(f.grid, f.cand, f.stress, f.spacing,
                                                   nullptr, f.params, &grow_out);
    return run(lat, emit_out);               // the EMITTER decides what ships
  };

  // ── the sweep. Reported for every point, asserted where the bar applies. ────────
  bool any_survived = false;
  for (double sep : {4.0, 4.5, 5.0, 5.5, 6.0, 6.5, 7.0, 8.0}) {
    OrganicGenStats gs, es;
    const std::vector<OrganicSpan> spans = measure(sep, gs, es);
    const double grown = es.census_grown_len_mm;
    const double wrote = es.census_len_mm[OrganicGenStats::CensusWritten];
    const double survival = grown > 0.0 ? wrote / grown : 0.0;
    std::fprintf(stderr,
                 "[G8] sep %.1f: grown %8.1f -> written %8.1f mm (%5.1f %%)  comp %2zu "
                 "largest %.4f  | joins %zu refused %zu\n",
                 sep, grown, wrote, 100.0 * survival, es.emitted_components,
                 es.emitted_largest_length_fraction, gs.growth_joins,
                 gs.growth_join_refused_span);
    if (survival >= kSurvivalFloor) {
      any_survived = true;
      // ★ CONNECTIVITY IS ONLY ASSERTED WHERE THERE IS MATERIAL TO CONNECT. Asserting
      // it on 0.4 % of the lattice is what let separation 5.0 pass at 15 mm.
      // ★ ROOTED, NOT ONE. This bar used to demand a single component, which was a
      // proxy for "nothing adrift" that also forbade what a grown lattice IS: pillars
      // that stand on the plate and never join each other. Since 2026-09-05 the
      // stranded drop keeps a rooted component, so the honest bar is the proxy's
      // meaning: every millimetre that ships stands on the plate (this fixture has no
      // part solid, so the plate is the part).
      CHECK(rooted_length_fraction(spans) > 0.99,
            "G8: where the material survives, essentially all of it must be in "
            "components rooted on the plate -- nothing adrift");
      CHECK(es.emitted_largest_length_fraction > 0.0,
            "G8: the largest-component fraction must still be reported");
    }
  }
  CHECK(any_survived,
        "G8: at least one separation must survive emission above the floor — if none "
        "does, the pipeline deletes every lattice and the connectivity bars above "
        "would be vacuous");

  // ── the survival bar itself, at the one separation known to work ───────────────
  {
    OrganicGenStats gs, es;
    measure(4.0, gs, es);
    const double survival =
        es.census_len_mm[OrganicGenStats::CensusWritten] / es.census_grown_len_mm;
    CHECK(survival >= kSurvivalFloor,
          "G8: at the default separation the emitter must ship what growth grew — "
          "measured 102.8 % when this bar was written; the floor is 0.80 because the "
          "failing separations sit at 0.4-15 %, and a connectivity ratio cannot see "
          "the difference");
  }

  // ── WHERE THE MILLIMETRES GO. Diagnosis only; this task does not repair it. ─────
  // MEASURED 2026-08-28, Release: the SUPPORT PRUNE is the sole deleter. Every other
  // pass either did not run or passed material through unchanged.
  //
  //   sep 4.0: into prune 4298.2 -> out 4199.0  (2.3 % removed)
  //   sep 4.5: into prune 3967.1 -> out  193.2  (95.1 % removed)
  //   sep 5.0: into prune 4194.1 -> out   15.0  (99.6 % removed)
  //
  // WHY 4.0 ESCAPES: the emitter's prune is a SPAN-TO-SPAN contact test (a tip is
  // supported if it lands on another span's interior, or on a tip that leads away).
  // Growth's guarantee is different in kind — an occupancy raster in layer order that
  // counts the BUILD PLATE. A curve climbing from the floor is supported under growth
  // and has no neighbouring span at its tip, so the emitter prunes it and the erosion
  // walks back down the curve. At separation 4.0 there are 1520 joins, so nearly every
  // tip is a T-joint and the emitter's test is satisfied INCIDENTALLY. The two support
  // criteria disagree; density hides the disagreement.
  {
    OrganicGenStats gs, es;
    measure(5.0, gs, es);
    const double in_prune = es.census_len_mm[OrganicGenStats::CensusNodeMerge];
    const double out_prune = es.census_len_mm[OrganicGenStats::CensusSupportPrune];
    CHECK(in_prune > 0.0 && out_prune >= 0.0,
          "G8 census precondition: both sides of the support prune must be measured, "
          "not defaulted — a -1 stage means the pass did not run");
    std::fprintf(stderr, "[G8] sep 5.0 support prune: %.1f -> %.1f mm (%.1f %% removed)\n",
                 in_prune, out_prune, 100.0 * (1.0 - out_prune / in_prune));
  }
}

// ── G7: THE GROWTH COUNTERS REACH THE RECEIPT ───────────────────────────────────
// ★★ THE TELEMETRY WAS DEAD. `run_organic_step` filled `oo.growth` and nothing ever
// read it, so every growth counter was discarded on both the analyze and the geometry
// path. The consequence that matters: `growth_tip_budget_hit` is the receipt's only
// way of saying a run TRUNCATED at 20,000 tips rather than finishing, and a truncated
// run was indistinguishable from a complete one.
//
// This test is at the RunInfo -> json seam rather than end-to-end because that is
// where the loss was, and because a unit test cannot run the full job pipeline. It
// asserts the two facts a receipt must carry: the counters appear when growth ran, and
// `growth_ran` is FALSE — not merely absent, and not a zero — when it did not.
void test_growth_stats_reach_the_receipt() {
  {
    RunInfo gi;
    gi.grading_present = true;   // the receipt's grading block gates the rest
    gi.organic_present = true;
    gi.organic_growth_ran = true;
    gi.organic_growth_seeds = 41;
    gi.organic_growth_curves = 7;
    gi.organic_growth_steps = 1234;
    gi.organic_growth_blocked = 5;
    gi.organic_growth_clamped = 99;
    gi.organic_growth_clamp_max_deg = 12.5;
    gi.organic_growth_joins = 3;
    gi.organic_growth_join_refused_span = 2;
    gi.organic_growth_tip_budget_hit = true;
    gi.organic_growth_layer_height_mm = 0.2;
    const std::string j = run_info_json(gi);
    CHECK(j.find("\"growth_ran\": true") != std::string::npos,
          "G7: growth_ran must be reported true when growth ran");
    CHECK(j.find("\"growth_seeds\": 41") != std::string::npos,
          "G7: growth_seeds must reach the receipt — it was discarded entirely");
    CHECK(j.find("\"growth_steps\": 1234") != std::string::npos,
          "G7: growth_steps must reach the receipt");
    CHECK(j.find("\"growth_clamped\": 99") != std::string::npos,
          "G7: growth_clamped must reach the receipt — the clamp is the event that "
          "growth_blocked was wrongly documented as counting");
    CHECK(j.find("\"growth_join_refused_span\": 2") != std::string::npos,
          "G7: joins refused for span must reach the receipt");
    CHECK(j.find("\"growth_tip_budget_hit\": true") != std::string::npos,
          "G7: a run TRUNCATED at the tip budget must say so — the header promises "
          "the receipt reports this 'rather than silently truncating'");
    CHECK(j.find("\"growth_layer_height_mm\"") != std::string::npos,
          "G7: the layer height the result was computed in must be recorded");
  }
  {
    // A TRACED organic run: growth_ran false, and no growth counter may appear at all.
    // A zero that was never measured is not a passing zero.
    RunInfo gi;
    gi.grading_present = true;   // the receipt's grading block gates the rest
    gi.organic_present = true;
    gi.organic_growth_ran = false;
    const std::string j = run_info_json(gi);
    CHECK(j.find("\"growth_ran\": false") != std::string::npos,
          "G7: a traced run must report growth_ran false, so 'growth measured zero' "
          "and 'growth never ran' are distinguishable");
    CHECK(j.find("\"growth_seeds\"") == std::string::npos,
          "G7: no growth counter may be emitted on a traced run — an unmeasured zero "
          "would read as a passing zero");
    CHECK(j.find("\"growth_tip_budget_hit\"") == std::string::npos,
          "G7: no growth counter may be emitted on a traced run");
  }
}

// ── G9: THE COPY CHAIN, NOT THE SERIALIZER ──────────────────────────────────────
// ★★ G7 HAND-FILLS A RunInfo AND CHECKS THE JSON. That locks the absent-keys rule but
// it cannot see a DROPPED FIELD, because it never runs the copy that would drop it.
// The original defect was exactly of that shape: the counters were filled by the
// generator and never read, and every serializer test in the world would have passed.
//
// So: give OrganicGenStats a DISTINCT non-zero value in every growth field, push it
// through `copy_growth_stats` — the one path both receipts now use — and assert each
// value arrives. A thirteenth counter wired in four places out of five fails here.
void test_growth_copy_path_drops_nothing() {
  OrganicGenStats g;
  g.growth_seeds = 11;
  g.growth_curves = 22;
  g.growth_steps = 33;
  g.growth_blocked = 44;
  g.growth_clamped = 55;
  g.growth_clamp_max_deg = 6.5;
  g.growth_branches = 77;
  g.growth_branch_refused = 88;
  g.growth_joins = 99;
  g.growth_join_refused_span = 111;
  g.growth_tip_budget_hit = true;
  g.growth_layer_height_mm = 0.125;

  RunInfo gi;
  copy_growth_stats(gi, g, /*ran=*/true);

  CHECK(gi.organic_growth_ran, "G9: growth_ran must arrive");
  CHECK(gi.organic_growth_seeds == 11, "G9: growth_seeds dropped by the copy path");
  CHECK(gi.organic_growth_curves == 22, "G9: growth_curves dropped by the copy path");
  CHECK(gi.organic_growth_steps == 33, "G9: growth_steps dropped by the copy path");
  CHECK(gi.organic_growth_blocked == 44, "G9: growth_blocked dropped by the copy path");
  CHECK(gi.organic_growth_clamped == 55, "G9: growth_clamped dropped by the copy path");
  CHECK(gi.organic_growth_clamp_max_deg == 6.5,
        "G9: growth_clamp_max_deg dropped by the copy path");
  CHECK(gi.organic_growth_branches == 77, "G9: growth_branches dropped");
  CHECK(gi.organic_growth_branch_refused == 88, "G9: growth_branch_refused dropped");
  CHECK(gi.organic_growth_joins == 99, "G9: growth_joins dropped");
  CHECK(gi.organic_growth_join_refused_span == 111,
        "G9: growth_join_refused_span dropped");
  CHECK(gi.organic_growth_tip_budget_hit, "G9: growth_tip_budget_hit dropped");
  CHECK(gi.organic_growth_layer_height_mm == 0.125,
        "G9: growth_layer_height_mm dropped");

  // ★ and the values must SURVIVE to the receipt, so the chain is checked end to end
  // rather than only at its first hop.
  gi.grading_present = true;
  gi.organic_present = true;
  const std::string j = run_info_json(gi);
  CHECK(j.find("\"growth_join_refused_span\": 111") != std::string::npos,
        "G9: a value copied in must still be the value serialized out");
  CHECK(j.find("\"growth_clamped\": 55") != std::string::npos,
        "G9: a value copied in must still be the value serialized out");

  // ran=false must zero nothing and claim nothing: the counters are meaningless, and
  // the receipt suppresses them, but the flag is the thing that says so.
  RunInfo gf;
  copy_growth_stats(gf, g, /*ran=*/false);
  CHECK(!gf.organic_growth_ran,
        "G9: growth_ran must follow the argument, never be inferred from a counter");
}

// ── ★ THE CENSUS MUST COUNT PIECES, NOT ONLY MILLIMETRES ────────────────────────
// A LENGTH census is blind to a pass that changes topology without moving material.
// The node merge welds coincident endpoints: it fuses components and deletes almost
// nothing, so a length-only census reports it as a no-op and "the support prune is
// the sole deleter" gets read as "nothing else re-wired anything". The first claim is
// true; the second does not follow from it.
//
// MEASURED on this fixture at separation 4.0: emitted 4331 mm / 26 components ->
// node merge 4298 mm / 9 components. It removed 0.8% of the length and two thirds of
// the pieces.
// ── ★ A STAGE THAT RAN MUST NOT REPORT NULL ─────────────────────────────────────
// -1 in the census is documented to mean THE PASS DID NOT RUN, and differencing
// without checking is how an unrun pass reads as having deleted everything. Three
// stages were declared in the enum with NO site ever calling census_at for them --
// CensusGroundTie, CensusBranchSupport, CensusFillMat -- so they read -1 forever and
// the receipt rendered null beside their own nonzero counters. Measured on the
// maintainer's device: four stages doing it at once (ground_tie legs 8/22,
// branch_support seeds 537/286, fill_mat struts 415/24, finish fillets 72/2).
//
// This fails if any stage is left unrecorded again: every declared stage must have a
// call site, so a pass that runs can always say so.
void test_every_census_stage_is_recorded() {
  GrowFixture f = grow_fixture();
  for (double& v : f.spacing) v = 4.0;
  OrganicGenStats gs;
  const OrganicLattice lat =
      grow_organic_lattice(f.grid, f.cand, f.stress, f.spacing, nullptr, f.params, &gs);
  OrganicGenStats st;
  const std::vector<OrganicSpan> spans = run(lat, st);
  CHECK(!spans.empty(), "census precondition: the fixture must emit geometry");
  if (spans.empty()) return;

  // Every stage that this run actually executed must carry BOTH numbers. A stage the
  // run genuinely skipped may stay -1; a stage that recorded a length must also have
  // recorded components, and vice versa -- a half-populated stage is the same defect
  // wearing a different face.
  int recorded = 0;
  for (int i = 0; i < OrganicGenStats::kCensusStages; ++i) {
    const bool has_len = st.census_len_mm[i] >= 0.0;
    const bool has_comp = st.census_components[i] >= 0;
    if (has_len || has_comp) ++recorded;
    CHECK(has_len == has_comp,
          "a census stage records LENGTH and COMPONENTS together, never one alone");
    if (has_len != has_comp)
      std::fprintf(stderr, "  stage %s: len %.1f components %d\n",
                   organic_census_stage_name(i), st.census_len_mm[i],
                   st.census_components[i]);
  }
  std::printf("  census: %d of %d stages recorded on this fixture\n", recorded,
              static_cast<int>(OrganicGenStats::kCensusStages));
  CHECK(recorded >= 4,
        "a real run records several stages -- if only one or two appear, the census "
        "is not being written and 'null' has stopped meaning 'did not run'");
}

void test_census_counts_components_not_only_length() {
  GrowFixture f = grow_fixture();
  for (double& v : f.spacing) v = 4.0;
  OrganicGenStats gs;
  const OrganicLattice lat =
      grow_organic_lattice(f.grid, f.cand, f.stress, f.spacing, nullptr, f.params, &gs);
  OrganicGenStats st;
  const std::vector<OrganicSpan> spans = run(lat, st);
  CHECK(!spans.empty(), "census precondition: the fixture must emit geometry");
  if (spans.empty()) return;

  // every stage that recorded a length must also have recorded a component count:
  // a half-populated census is what let a topology change go unseen.
  int with_len = 0, with_comps = 0;
  for (int i = 0; i < OrganicGenStats::kCensusStages; ++i) {
    if (st.census_len_mm[i] < 0.0) continue;
    ++with_len;
    if (st.census_components[i] >= 0) ++with_comps;
  }
  std::printf("  census: %d stage(s) with a length, %d of them with components\n",
              with_len, with_comps);
  CHECK(with_len > 0, "the census records at least one stage");
  CHECK(with_comps == with_len,
        "every stage with a length also has a component count -- a stage missing one "
        "is a stage where a re-wiring pass cannot be seen");

  const double len_emit = st.census_len_mm[OrganicGenStats::CensusEmitted];
  const double len_merge = st.census_len_mm[OrganicGenStats::CensusNodeMerge];
  const int c_emit = st.census_components[OrganicGenStats::CensusEmitted];
  const int c_merge = st.census_components[OrganicGenStats::CensusNodeMerge];
  if (len_emit > 0.0 && c_emit > 0 && c_merge > 0) {
    std::printf("  node merge: %.0f mm / %d comps -> %.0f mm / %d comps\n",
                len_emit, c_emit, len_merge, c_merge);
    CHECK(c_merge < c_emit,
          "the node merge FUSES components -- the property a length census cannot "
          "see, and the reason this census reports both");
    CHECK(std::fabs(len_merge - len_emit) / len_emit < 0.10,
          "...while moving under 10% of the length, which is why it reads as a no-op "
          "in the length dimension");
  }
}


// ── R1-R3: THE CELL-SIZE RECOMMENDATION, pure parts ─────────────────────────────
void test_recommend_band_from_the_model() {
  using namespace topopt;
  // A 3 m tall, 1 m wide part with 100 mm walls, bead 0.4 (print floor 0.61 mm),
  // 128^3 -> 23.4 mm voxels, 1 voxels per cell at the resolution floor.
  std::vector<OrganicRecommendRegion> big{{1, 100.0, 1000.0, 1.0, 4.0}};
  const OrganicRecommendBand b = organic_recommend_band(big, 0.61, 23.4, 1, 2.0, 8.0, 5);
  std::printf("  R1 big part @128^3: band %.1f-%.1f (print %.2f, res %.1f, member %.1f, extent %.1f) look %.1f g %.2f, %zu cands\n",
              b.lo_mm, b.hi_mm, b.printability_floor_mm, b.resolution_floor_mm, b.member_ceiling_mm,
              b.extent_ceiling_mm, b.look_cell_mm, b.grade_ratio, b.candidates.size());
  CHECK(std::fabs(b.member_ceiling_mm - 50) < 1e-9,
        "R1: a 100 mm wall at two cells across gives a 50 mm ceiling -- the grade on a big part is tens of mm");
  CHECK(std::fabs(b.resolution_floor_mm - 23.4) < 0.05,
        "R1: the RESOLUTION floor binds on a big part: 1 voxels x 23.4 mm, not the 0.61 mm bead floor");
  CHECK(!b.collapsed && std::fabs(b.hi_mm - 50.0) < 1e-9,
        "R1: at 128^3 the band is 23.4-50 mm on this part");
  CHECK(std::fabs(b.look_cell_mm - 50.0) < 1e-9,
        "R1: 8 cells across a 1000 mm face wants 125 mm; clamped to the 50 mm ceiling");
  CHECK(std::fabs(b.grade_ratio - 2.0) < 1e-9, "R1: stress spread p99/p50 = 4 -> grade ratio sqrt(4) = 2");
  bool has_look = false, has_pair = false, has_step = false; std::size_t pair = 0;
  std::string tags;
  for (const auto& c : b.candidates) {
    tags += c.source + " ";
    if (c.source == "pair") ++pair;
    has_look |= c.source == "look"; has_pair |= c.source == "look_pair"; has_step |= c.source == "look_step";
  }
  std::printf("  R1 tags: %s\n", tags.c_str());
  CHECK(pair == 4 && has_look && has_pair && has_step && b.candidates.size() >= 9,
        "R1: 5 uniform steps, 3 two-apart pairs + the full band, and look / look_pair / look_step");
  // The same part at 512^3 (5.9 mm voxels): the resolution floor drops, the ceiling stays the wall's.
  const OrganicRecommendBand b2 = organic_recommend_band(big, 0.61, 5.86, 1, 2.0, 8.0, 5);
  CHECK(!b2.collapsed && std::fabs(b2.lo_mm - 5.86) < 0.05 && std::fabs(b2.hi_mm - 50.0) < 1e-9,
        "R1: 512^3 opens the band to 5.9-50 mm; the wall, not the grid, sets the ceiling");
  // The STAND's 12 mm wall at 1.707 mm voxels: band 1.71-6.0 -- the 4.5-5.5 window that certifies sits inside it.
  std::vector<OrganicRecommendRegion> stand{{2, 12.0, 97.0, 1.0, 3.0}};
  const OrganicRecommendBand b4 = organic_recommend_band(stand, 0.61, 1.707, 1, 2.0, 8.0, 5);
  std::printf("  R1 STAND wall: band %.2f-%.2f look %.2f\n", b4.lo_mm, b4.hi_mm, b4.look_cell_mm);
  CHECK(!b4.collapsed && b4.lo_mm <= 4.5 && b4.hi_mm >= 5.5,
        "R1: the STAND's certified 4.5-5.5 window lies inside its band -- the band must not exclude what runs");
  // A thin wall: 3 mm depth -> 1.5 mm ceiling, 0.26 mm voxels: band 0.61-1.5.
  std::vector<OrganicRecommendRegion> thin{{3, 3.0, 40.0, 1.0, 1.1}};
  const OrganicRecommendBand b3 = organic_recommend_band(thin, 0.61, 0.26, 1, 2.0, 8.0, 5);
  CHECK(!b3.collapsed && std::fabs(b3.hi_mm - 1.5) < 1e-9 && std::fabs(b3.lo_mm - std::max(0.61, 1 * 0.26)) < 1e-9,
        "R1: a 3 mm wall gets a ~0.6-1.5 mm band -- smaller part, smaller cell, by the wall not the height");
  CHECK(b3.grade_ratio < kOrganicRecommendGradeMin,
        "R1: a flat stress field (p99/p50 = 1.1) earns NO grade");
  bool thin_pair = false; for (const auto& c : b3.candidates) thin_pair = thin_pair || c.source == "look_pair";
  CHECK(!thin_pair, "R1: ...so no look_pair candidate is generated");
  std::vector<OrganicRecommendRegion> none{{4, 1.0, 40.0, 1.0, 1.0}};
  CHECK(organic_recommend_band(none, 0.61, 0.26, 1, 2.0, 8.0, 5).collapsed,
        "R1: a 1 mm wall (0.5 mm ceiling under the 0.61 floor) collapses the band: the honest answer is solid");
}

void test_recommend_select_structural() {
  using namespace topopt;
  std::vector<OrganicRecommendRow> rows;
  auto row = [&](double lo, double hi, const char* src, bool rooted, bool cert, double margin, double traced) {
    OrganicRecommendRow r; r.lo = lo; r.hi = hi; r.source = src; r.rooted_ok = rooted; r.certified = cert;
    r.margin = margin; r.traced_mm = traced; rows.push_back(r); };
  row(3.0, 3.0, "grid", true, true, 4.0, 9000);
  row(4.5, 4.5, "grid", true, true, 2.1, 6000);
  row(6.0, 6.0, "grid", true, true, 1.2, 4000);     // certifies but under the 1.5 target
  row(8.0, 8.0, "grid", false, false, 0.0, 2500);   // not rooted
  row(3.0, 6.0, "pair", true, true, 1.8, 5200);     // graded: certifies AND saves material vs the fit
  row(4.5, 8.0, "pair", true, false, 0.7, 3500);    // refused
  const OrganicRecommendation r = organic_recommend_select(rows, "structural", 1.5, 0.0);
  std::printf("  R2 structural: fit %.1f (m %.2f) auto %.1f-%.1f (%s, m %.2f, traced %.0f) rejected %zu\n",
              r.fit_mm, r.fit_margin, r.auto_lo_mm, r.auto_hi_mm, r.auto_source.c_str(), r.auto_margin,
              r.auto_traced_mm, r.rejected.size());
  CHECK(r.fit_found && r.fit_mm == 4.5, "R2: FIT = the largest uniform cell certifying at >= target");
  CHECK(r.auto_found && r.auto_lo_mm == 3.0 && r.auto_hi_mm == 6.0,
        "R2: AUTO = the certifying candidate with the least material: the 3-6 grade beats the 4.5 fit");
  CHECK(r.rejected.size() == 3, "R2: three rejected, each with a reason");
  bool has_margin_reason = false, has_root = false, has_cert = false;
  for (const auto& pr : r.rejected) {
    has_margin_reason |= pr.second.find("below target") != std::string::npos;
    has_root |= pr.second == "not rooted";
    has_cert |= pr.second == "refused by the certificate";
  }
  CHECK(has_margin_reason && has_root && has_cert, "R2: the reasons name the gate that failed");
  // If no grade saves material, AUTO collapses to the fit as a uniform window.
  rows.clear();
  row(4.5, 4.5, "grid", true, true, 2.1, 6000);
  row(3.0, 6.0, "pair", true, true, 1.8, 7000);
  const OrganicRecommendation r2 = organic_recommend_select(rows, "structural", 1.5, 0.0);
  CHECK(r2.auto_lo_mm == 4.5 && r2.auto_hi_mm == 4.5, "R2: a grade that saves nothing is not chosen");
}

void test_recommend_select_aesthetic() {
  using namespace topopt;
  std::vector<OrganicRecommendRow> rows;
  auto row = [&](double lo, double hi, const char* src, bool rooted) {
    OrganicRecommendRow r; r.lo = lo; r.hi = hi; r.source = src; r.rooted_ok = rooted; rows.push_back(r); };
  row(3.0, 3.0, "grid", true); row(5.0, 5.0, "grid", true); row(7.0, 7.0, "grid", false);
  row(6.0, 6.0, "look", true); row(4.2, 8.5, "look_pair", true); row(5.2, 5.2, "look_step", true);
  const OrganicRecommendation r = organic_recommend_select(rows, "aesthetic", 1.5, 6.0);
  CHECK(r.fit_found && r.fit_mm == 6.0 && r.fit_source == "look",
        "R3: aesthetic FIT = the look cell when it roots -- a look-driven target, not the largest cell");
  CHECK(r.auto_found && r.auto_lo_mm == 4.2 && r.auto_hi_mm == 8.5,
        "R3: aesthetic AUTO = the look pair, spread by the stress range");
  rows.clear();
  row(3.0, 3.0, "grid", true); row(6.0, 6.0, "look", false); row(4.2, 8.5, "look_pair", false);
  row(5.2, 5.2, "look_step", true);
  const OrganicRecommendation r2 = organic_recommend_select(rows, "aesthetic", 1.5, 6.0);
  CHECK(r2.fit_mm == 5.2 && r2.auto_lo_mm == 5.2 && r2.auto_hi_mm == 5.2,
        "R3: when the look cell does not root, one step below; and AUTO falls back to that uniform");
  CHECK(r2.rejected.size() == 2, "R3: the unrooted look and pair are rejected with a reason");
}

int main() {
  test_growth_produces_curves();
  test_growth_does_not_fall_back();
  test_growth_is_supported();
  test_growth_respects_the_cone();
  test_growth_joins_neighbours();
  test_growth_stays_connected();
  test_growth_stats_reach_the_receipt();
  test_growth_copy_path_drops_nothing();
  test_mat_that_counts_feet_lays_floor();
  test_mat_survives_the_weld_raster();
  test_slenderness_reads_the_unsupported_span();
  test_stats_are_actually_populated();
  test_probe_rooting();
  test_recommend_band_from_the_model();
  test_recommend_select_structural();
  test_recommend_select_aesthetic();
  test_synthetic_focal_stress();
  test_bundle_is_not_support();
  test_chain_and_tee_survive();
  test_node_merge_joins_near_misses();
  test_finish_does_not_change_the_structure();
  test_deterministic();
  test_one_cell_needs_a_finish();
  test_every_census_stage_is_recorded();
  test_census_counts_components_not_only_length();
  std::printf("%s: %d checks, %d failures\n",
              g_failures == 0 ? "PASS" : "FAIL", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
