// P4, his print orientation: the six candidates (print_orientation.hpp) and the one rule (recommend_print_orientation,
// build_orientation.hpp, decision D1).
//   §1 the rule: strength first, then standing, then least part support (10 % ties), then strength, then height; his
//      placement kept unless the winner is 10 % stronger (or fixes a fail) or needs 30 % less support without being
//      weaker; "none passes yet"; strength not known.
//   §2 the bed: the L-bracket's flat face and height along each of its six axes, and whether its centre stands over it.
//   §3 the part's own support (voxels): a shelf over air is supported to the bed, a 45 degree step is not, the lattice
//      (part, not solid) holds what is above it.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <limits>
#include <string>
#include <utility>
#include <vector>

#include "../../src/flexible/json.hpp"   // reads the block back
#include "topopt/build_orientation.hpp"
#include "topopt/print_frame.hpp"
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
// A closed box [0, L] x [0, W] x [0, H], outward.
TriangleMesh box_mesh(double L, double W, double H) {
  TriangleMesh m;
  for (const Vec3& v : std::vector<Vec3>{{0, 0, 0}, {L, 0, 0}, {L, W, 0}, {0, W, 0}, {0, 0, H}, {L, 0, H}, {L, W, H}, {0, W, H}})
    m.vertices.push_back(v);
  const int t[12][3] = {{0, 2, 1}, {0, 3, 2}, {4, 5, 6}, {4, 6, 7}, {0, 1, 5}, {0, 5, 4},
                        {3, 7, 6}, {3, 6, 2}, {0, 4, 7}, {0, 7, 3}, {1, 2, 6}, {1, 6, 5}};
  for (const auto& tri : t) m.triangles.push_back({tri[0], tri[1], tri[2]});
  return m;
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
    // None passes and the strongest is only 4 % stronger (his stand of 11-23: 1.34 as placed, 1.397 on an edge): kept.
    r = recommend_print_orientation({cand(1.34, 2000, 3120, 70, true), cand(1.397, 18669, 3120, 60)}, 1.5);
    CHECK(r.none_passes && r.recommended == 0 && !r.change && has_why(r, "Prints best as placed") &&
          has_why(r, "None passes yet") && r.candidates[0].offered && r.candidates[0].dropped.empty());
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
  // ── Phase 2 (his 11-23 evening: the 45 degree sides, and "Both - flat sides and edges held by supports") ──────────
  // The strength each candidate gets: the solid's layer criterion under a uniform stress `s` (Voigt), the in-plane
  // margin 3.0, the layer margin 0.75 x 38 / (b.s.b) (PA12's numbers): exactly what the check computes per up.
  const auto ranked = [&](const TriangleMesh& m, const double s[6], const Vec3& com, const char* tag) {
    OrientationCandidates cs = print_candidates(m);
    OrientationStrengthsN st;
    st.known = true;
    st.required_margin = 1.5;
    st.has_centre_of_mass = true;
    st.centre_of_mass = com;
    for (const OrientationCandidate& c : cs.list) {
      const Vec3& b = c.up;
      const double t = b.x * b.x * s[0] + b.y * b.y * s[1] + b.z * b.z * s[2] + 2 * b.x * b.y * s[3] + 2 * b.y * b.z * s[4] +
                       2 * b.z * b.x * s[5];
      OrientationStrength o;
      o.solid = std::min(3.0, t > 1e-9 ? 0.75 * 38.0 / t : std::numeric_limits<double>::infinity());
      o.solid_interlayer = t > 1e-9 ? 0.75 * 38.0 / t : std::numeric_limits<double>::infinity();
      o.struts = std::numeric_limits<double>::quiet_NaN();
      o.support_mm3 = 0.0;
      st.by_up.push_back(o);
    }
    const std::string js = print_orientation_json(st, cs, PrintFrame{}, 0.2);
    std::printf("[%s] %zu candidates (hull %d; faces small %zu, over cap %zu; edges short %zu, over cap %zu)\n", tag,
                cs.list.size(), cs.hull, cs.faces_small, cs.faces_over_cap, cs.edges_short, cs.edges_over_cap);
    return std::make_pair(cs, topopt::flexible::json::parse(js, tag));
  };
  namespace fj = topopt::flexible::json;
  // §4 a 30 mm cube whose stress is weakest across the layers on every face (tension T along each axis) but has none
  // across (1, 1, 0): only edge-down along that diagonal passes; it is recommended, held by stand supports.
  {
    TriangleMesh cube = box_mesh(30, 30, 30);
    const double T = 23.75;   // a face's layer margin 0.75 x 38 / 23.75 = 1.2 (fails 1.5)
    const double s[6] = {T, T, T, -T, 0.0, 0.0};
    const auto [cs, j] = ranked(cube, s, {15, 15, 15}, "cube");
    std::size_t faces = 0, edges = 0;
    for (const OrientationCandidate& c : cs.list) (c.kind == OrientationCandidate::Kind::Edge ? edges : faces) += 1;
    CHECK(cs.hull && faces == 6 && edges == 12 && cs.list.front().as_placed && cs.list.front().up.z > 0.999);
    const int rec = static_cast<int>(fj::require(j, "recommended", "j").num);
    const fj::Value& c = fj::require(j, "candidates", "j").arr.at(static_cast<std::size_t>(rec));
    const fj::Value& up = fj::require(c, "up", "c");
    const double along = std::fabs(up.arr[0].num + up.arr[1].num) / std::sqrt(2.0);
    std::printf("[cube] recommended %d: rests on %s, up (%.3f, %.3f, %.3f), stands %d, bands %s\n", rec,
                fj::require(c, "rests_on", "c").str.c_str(), up.arr[0].num, up.arr[1].num, up.arr[2].num,
                fj::require(c, "stands", "c").boolean, fj::to_text(fj::require(c, "stand_supports", "c")).c_str());
    CHECK(fj::require(j, "change", "j").boolean && fj::require(c, "rests_on", "c").str == "edge");
    CHECK(std::fabs(along - 1.0) < 1e-6 && fj::require(c, "stands", "c").boolean);
    const fj::Value& sb = fj::require(c, "stand_supports", "c");
    CHECK(fj::require(sb, "band_mm", "sb").arr[0].num >= 2.0 && fj::require(sb, "volume_mm3", "sb").num > 0.0);
    CHECK(fj::require(c, "support_mm3", "c").num == fj::require(sb, "volume_mm3", "sb").num);   // they count
    bool why = false;
    for (const fj::Value& w : fj::require(j, "why", "j").arr) why = why || w.str == "Stronger across the layers";
    CHECK(why);
  }
  // §5 a 4 x 4 x 100 rod: its long edges' faces are too narrow to hold its centre of mass 5 mm inside: "cannot_stand";
  // its 4 mm edges are no candidates (under 10 mm).
  {
    TriangleMesh rod = box_mesh(4, 4, 100);
    const double s[6] = {1.0, 1.0, 1.0, 0.0, 0.0, 0.0};
    const auto [cs, j] = ranked(rod, s, {2, 2, 50}, "rod");
    CHECK(cs.edges_short == 8);
    std::size_t edges = 0, refused = 0;
    const fj::Value& cands = fj::require(j, "candidates", "j");
    for (std::size_t i = 0; i < cs.list.size(); ++i)
      if (cs.list[i].kind == OrientationCandidate::Kind::Edge) {
        ++edges;
        refused += !cs.list[i].stands && fj::require(cands.arr[i], "dropped", "c").is_string() &&
                   fj::require(cands.arr[i], "dropped", "c").str == "cannot_stand";
      }
    CHECK(edges == 4 && refused == 4);
  }
  // §6 a right-triangle prism (30 x 30, 20 deep) whose stress has no tension across its 45 degree face: the 45 degree
  // face is a candidate (a flat face of the hull) and is recommended over the right-angle edge (the same strength, but
  // the edge needs stand supports: least support wins).
  {
    TriangleMesh prism;
    const Vec3 p[6] = {{0, 0, 0}, {30, 0, 0}, {0, 0, 30}, {0, 20, 0}, {30, 20, 0}, {0, 20, 30}};
    for (const Vec3& v : p) prism.vertices.push_back(v);
    const int t[8][3] = {{0, 1, 2}, {3, 5, 4}, {0, 3, 4}, {0, 4, 1}, {0, 2, 5}, {0, 5, 3}, {1, 4, 5}, {1, 5, 2}};
    for (const auto& q : t) prism.triangles.push_back({q[0], q[1], q[2]});
    // tension 60 along (1, 0, -1)/sqrt2 and along y
    const double a = 1.0 / std::sqrt(2.0), tt = 60.0;
    const double s[6] = {tt * a * a, tt, tt * a * a, 0.0, 0.0, -tt * a * a};
    const auto [cs, j] = ranked(prism, s, {10, 10, 10}, "prism");
    const int rec = static_cast<int>(fj::require(j, "recommended", "j").num);
    const fj::Value& c = fj::require(j, "candidates", "j").arr.at(static_cast<std::size_t>(rec));
    const fj::Value& up = fj::require(c, "up", "c");
    std::printf("[prism] recommended %d: rests on %s, up (%.3f, %.3f, %.3f), face %.6g mm2, contact %.6g mm2\n", rec,
                fj::require(c, "rests_on", "c").str.c_str(), up.arr[0].num, up.arr[1].num, up.arr[2].num,
                fj::require(c, "face_mm2", "c").num, fj::require(c, "bed_contact_mm2", "c").num);
    CHECK(fj::require(c, "rests_on", "c").str == "face" && std::fabs(up.arr[0].num + a) < 1e-9 && std::fabs(up.arr[2].num + a) < 1e-9);
    CHECK(std::fabs(fj::require(c, "face_mm2", "c").num - 30.0 * std::sqrt(2.0) * 20.0) < 1e-6);
    CHECK(fj::require(c, "stands", "c").boolean && fj::require(j, "change", "j").boolean);
  }
  // §7 the door for any up (print_frame.hpp, Phase 2): a rotation; points and tensors there and back; a linear stress
  // field resampled exactly (trilinear), within its grid.
  {
    PrintFrame f;
    const Vec3 up{1.0 / std::sqrt(2.0), 0.0, 1.0 / std::sqrt(2.0)};
    CHECK(print_frame_for_up(up, f) && !f.exact);
    const Vec3 z = f.dir_to_print(up);
    CHECK(std::fabs(z.x) < 1e-12 && std::fabs(z.y) < 1e-12 && std::fabs(z.z - 1.0) < 1e-12);
    const Vec3 q = f.point_to_model(f.point_to_print({3.5, -2.0, 7.25}));
    CHECK(std::fabs(q.x - 3.5) < 1e-12 && std::fabs(q.y + 2.0) < 1e-12 && std::fabs(q.z - 7.25) < 1e-12);
    // a field linear in place: resampled in the print frame it is the turned field at each place (trilinear is exact)
    const int n[3] = {20, 12, 16};
    const Vec3 o{-2.0, -3.0, -1.0};
    const double h = 1.0;
    std::vector<double> v(6 * 20 * 12 * 16);
    const auto field = [](const Vec3& p, double s[6]) {
      s[0] = 1 + 0.1 * p.x; s[1] = 2 + 0.05 * p.y; s[2] = 3 - 0.02 * p.z; s[3] = 0.3 * p.z; s[4] = -0.2 + 0.01 * p.x; s[5] = 0.5;
    };
    for (int k = 0; k < n[2]; ++k)
      for (int jj = 0; jj < n[1]; ++jj)
        for (int i = 0; i < n[0]; ++i) field({o.x + i + 0.5, o.y + jj + 0.5, o.z + k + 0.5}, &v[6 * ((k * n[1] + jj) * n[0] + i)]);
    int no[3];
    Vec3 oo;
    const std::vector<double> r = turn_grid_values(f, true, n, o, h, v, 6, no, oo);
    double worst = 0.0;
    std::size_t read = 0;
    for (int k = 0; k < no[2]; ++k)
      for (int jj = 0; jj < no[1]; ++jj)
        for (int i = 0; i < no[0]; ++i) {
          const Vec3 qp{oo.x + (i + 0.5) * h, oo.y + (jj + 0.5) * h, oo.z + (k + 0.5) * h};
          const Vec3 pm = f.point_to_model(qp);
          // only well inside the source's voxel centres (the edge voxels hold their value out to the box)
          if (pm.x < o.x + 0.5 || pm.y < o.y + 0.5 || pm.z < o.z + 0.5 || pm.x > o.x + n[0] - 0.5 || pm.y > o.y + n[1] - 0.5 ||
              pm.z > o.z + n[2] - 0.5)
            continue;
          double s0[6], s1[6];
          field(pm, s0);
          f.tensor_to_print(s0, s1);
          for (int c = 0; c < 6; ++c) worst = std::max(worst, std::fabs(r[6 * ((static_cast<std::size_t>(k) * no[1] + jj) * no[0] + i) + c] - s1[c]));
          ++read;
        }
    std::printf("[door] general up: resampled %d x %d x %d, %zu voxels read, worst %.3g MPa\n", no[0], no[1], no[2], read, worst);
    CHECK(read > 1000 && worst < 1e-9);
  }
  std::printf("%d checks, %d failed\n", g_checks, g_fail);
  return g_fail == 0 ? 0 : 1;
}
