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

int main() {
  test_mat_that_counts_feet_lays_floor();
  test_mat_survives_the_weld_raster();
  test_slenderness_reads_the_unsupported_span();
  test_stats_are_actually_populated();
  test_bundle_is_not_support();
  test_chain_and_tee_survive();
  test_node_merge_joins_near_misses();
  test_finish_does_not_change_the_structure();
  test_deterministic();
  test_one_cell_needs_a_finish();
  std::printf("%s: %d checks, %d failures\n",
              g_failures == 0 ? "PASS" : "FAIL", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
