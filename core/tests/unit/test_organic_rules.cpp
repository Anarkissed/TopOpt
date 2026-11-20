// Organic rules D to T (brief L1): one pin per rule, each failing without it, on made-up blocks and fields (never the
// owner's part). Also the two faults brief L1 named: a stated reference at the engine's own resolved value lays what an
// unstated one lays, and the link width (S8) away from 1.0 (0.5 and 2.0) is run through the path and the file job.
// Numbered as in docs/design/lattice-rebuild/02-tests.md, section 12 (OL).
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <functional>
#include <limits>
#include <cstring>
#include <map>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#include "topopt/lattice_layout.hpp"
#include "topopt/lattice_layout_file.hpp"
#include "topopt/lattice_layout_frame.hpp"
#include "topopt/lattice_layout_mesh.hpp"
#include "topopt/lattice_layout_organic.hpp"
#include "topopt/lattice_sample.hpp"

using namespace topopt;
using namespace topopt::lattice_layout;

#ifndef ORGANIC_RULES_TMP_DIR
#define ORGANIC_RULES_TMP_DIR "."
#endif

static int g_fail = 0, g_checks = 0;
#define CHECK(cond)                                                                              \
  do {                                                                                           \
    ++g_checks;                                                                                  \
    if (!(cond)) { ++g_fail; std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); }   \
  } while (0)

static double dist(const Vec3& a, const Vec3& b) { return std::hypot(a.x - b.x, std::hypot(a.y - b.y, a.z - b.z)); }

static TriangleMesh box(double x, double y, double z) {
  MeshSink s;
  const Vec3 p[8] = {{0, 0, 0}, {x, 0, 0}, {x, y, 0}, {0, y, 0}, {0, 0, z}, {x, 0, z}, {x, y, z}, {0, y, z}};
  const int q[6][4] = {{0, 3, 2, 1}, {4, 5, 6, 7}, {0, 1, 5, 4}, {1, 2, 6, 5}, {2, 3, 7, 6}, {3, 0, 4, 7}};
  for (const auto& f : q) {
    s.add_triangle(p[f[0]], p[f[1]], p[f[2]]);
    s.add_triangle(p[f[0]], p[f[2]], p[f[3]]);
  }
  return s.mesh;
}
// A box as an imported model: six flat faces, 0 bottom, 1 top, 2..5 the sides.
static StepModel box_model(double x, double y, double z) {
  StepModel m;
  const Vec3 p[8] = {{0, 0, 0}, {x, 0, 0}, {x, y, 0}, {0, y, 0}, {0, 0, z}, {x, 0, z}, {x, y, z}, {0, y, z}};
  const int q[6][4] = {{0, 3, 2, 1}, {4, 5, 6, 7}, {0, 1, 5, 4}, {1, 2, 6, 5}, {2, 3, 7, 6}, {3, 0, 4, 7}};
  const Vec3 out[6] = {{0, 0, -1}, {0, 0, 1}, {0, -1, 0}, {1, 0, 0}, {0, 1, 0}, {-1, 0, 0}};
  for (int f = 0; f < 6; ++f) {
    StepFaceInfo info;
    info.kind = StepSurfaceKind::Plane;
    info.plane_normal = out[f];
    info.plane_origin = p[q[f][0]];
    m.faces.push_back(info);
    for (int second = 0; second < 2; ++second) {
      const int n = static_cast<int>(m.mesh.vertices.size());
      m.mesh.vertices.insert(m.mesh.vertices.end(), {p[q[f][0]], p[q[f][second ? 2 : 1]], p[q[f][second ? 3 : 2]]});
      m.mesh.triangles.push_back({n, n + 1, n + 2});
      m.triangle_face.push_back(f);
    }
  }
  m.face_count = 6;
  m.solid_count = 1;
  m.brep_volume = x * y * z;
  return m;
}
static Region face_region(int id, Vec3 origin, Vec3 inward, double half_u, double half_w, double depth) {
  ManualClearanceGeometry m;
  m.kind = ClearanceKind::Face;
  m.origin = origin;
  m.normal = inward;
  m.half_u_mm = half_u;
  m.half_w_mm = half_w;
  ClearanceParams p;
  p.kind = ClearanceKind::Face;
  p.slab_depth_mm = depth;
  Region r;
  r.id = id;
  r.role = Role::Lattice;
  r.prism = resolve_clearance_manual(m, p);
  r.prism.declared_region_id = id;
  return r;
}
using Field = std::function<std::array<double, 6>(const Vec3&)>;
static TensorField make_field(int nx, int ny, int nz, const Field& f) {
  TensorField t;
  t.nx = nx; t.ny = ny; t.nz = nz;
  t.spacing = 1.0;
  t.voigt.assign(6 * static_cast<std::size_t>(nx) * ny * nz, 0.0);
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        const std::array<double, 6> s = f(Vec3{i + 0.5, j + 0.5, k + 0.5});
        for (int c = 0; c < 6; ++c) t.voigt[6 * t.index(i, j, k) + static_cast<std::size_t>(c)] = s[static_cast<std::size_t>(c)];
      }
  return t;
}
// Uniaxial stress `s` along the unit direction d: sigma = s d d^T.
static std::array<double, 6> along(Vec3 d, double s) {
  const double l = std::hypot(d.x, std::hypot(d.y, d.z));
  d = {d.x / l, d.y / l, d.z / l};
  return {s * d.x * d.x, s * d.y * d.y, s * d.z * d.z, s * d.x * d.y, s * d.y * d.z, s * d.z * d.x};
}

// A block X x Y x Z on the bed, a solid floor `floor` mm thick, all above it one Grown weave region under the top face
// (inset `inset` mm from the sides: then its side walls are the part's solid).
struct Part {
  PartMeasure pm;
  Domain d;
  TensorField field;
  OrganicAsk ask;
  Part(double x, double y, double z, double fl, const Field& f, double inset = 0.0)
      : pm(weld_mesh(box(x, y, z))),
        d(pm,
          [&] {
            DomainSpec s;
            s.bead_mm = 0.45;
            s.min_strut_lines = 2.0;
            s.regions = {face_region(1, {x / 2, y / 2, z}, {0, 0, -1}, x / 2 - inset, y / 2 - inset, z - fl)};
            s.regions[0].weave = true;
            return s;
          }()) {
    field = make_field(static_cast<int>(x), static_cast<int>(y), static_cast<int>(z), f);
    ask.mode = OrganicMode::Grown;
    ask.spacing_min_mm = 3.0;
    ask.spacing_max_mm = 5.5;
    ask.shape_fit = false;
    ask.width_mm = 0.9;
    ask.layer_mm = 0.2;
  }
  std::vector<Strand> grow(GrowReport& rep) const { return grow_strands(d, 1, field, ask, &rep); }
};
// The stress grows along x: light at x = 0, heavy at x = X (the spacing's range follows it).
static Field ramp_up(double X) { return [X](const Vec3& p) { return along({0, 0, 1}, 0.1 + 2.0 * p.x / X); }; }
static Field ramp_lean(double X) { return [X](const Vec3& p) { return along({1, 0, 1}, 0.1 + 2.0 * p.x / X); }; }
template <class F>
static bool throws(F f) {
  try { f(); } catch (const std::invalid_argument&) { return true; }
  return false;
}

// ── OL-D: the stress lines are the goal (D2: one branch back from a side face) ───────────────────────────────────
static void test_d_stress_goal() {
  Part b(24, 24, 24, 3, ramp_lean(24), 3.0);
  GrowReport on, off;
  b.ask.stress_goal = true;
  (void)b.grow(on);
  b.ask.stress_goal = false;
  (void)b.grow(off);
  std::size_t sides_on = on.face_hits[0] + on.face_hits[1] + on.face_hits[2] + on.face_hits[3];
  std::printf("OL-D stress goal: D2 branches offered %zu (grown %zu, refused %zu, short %zu), side-face exits %zu; off: "
              "offered %zu\n", on.d2_offered, on.d2_grown, on.d2_refused, on.d2_short, sides_on, off.d2_offered);
  CHECK(on.d2_offered > 0 && on.d2_grown > 0 && on.d2_grown + on.d2_refused <= on.d2_offered);
  CHECK(off.d2_offered == 0 && off.d2_grown == 0);
}

// ── OL-E: bare-place ratio, re-seed rounds, wall seeds that connect, wall roots that compete ─────────────────────
static void test_e_try_keys() {
  Part b(24, 24, 24, 3, ramp_up(24), 3.0);
  GrowReport r0, r1, r2, wide;
  b.ask.reseed_rounds = 0;
  (void)b.grow(r0);
  b.ask.reseed_rounds = 2;
  (void)b.grow(r2);
  b.ask.reseed_rounds = 1;
  (void)b.grow(r1);
  b.ask.void_ratio = 3.0;
  (void)b.grow(wide);
  b.ask.void_ratio = 1.5;
  std::printf("OL-E rounds 0: %zu rounds, %zu bare; 1: %zu rounds, %zu bare; 2: %zu rounds; void ratio 3: %zu bare\n",
              r0.reseed_voids_round.size(), r0.reseed_voids, r1.reseed_voids_round.size(), r1.reseed_voids,
              r2.reseed_voids_round.size(), wide.reseed_voids);
  CHECK(r0.reseed_voids_round.empty() && r0.reseed_voids == 0);
  CHECK(r1.reseed_voids_round.size() == 1 && r2.reseed_voids_round.size() == 2);
  CHECK(r1.reseed_voids > 0 && wide.reseed_voids < r1.reseed_voids);
  CHECK(throws([&] { OrganicAsk a = b.ask; a.void_ratio = 0.0; (void)grow_strands(b.d, 1, b.field, a); }));
  // Wall seeds that connect.
  GrowReport con, plain;
  b.ask.walls_out = true;
  (void)b.grow(plain);
  b.ask.wall_connect = true;
  (void)b.grow(con);
  b.ask.wall_connect = false;
  std::printf("OL-E wall connect: wall tips %zu, joins %zu; off: %zu\n", con.wall_grown, con.wall_joins, plain.wall_grown);
  CHECK(con.wall_grown > 0 && con.wall_joins > 0 && plain.wall_grown == 0);
  // Wall roots that compete (wall_gap).
  GrowReport gap;
  b.ask.wall_gap = 2.5;
  (void)b.grow(gap);
  std::printf("OL-E wall gap 2.5: wall roots %zu, kept %zu; off: %zu roots\n", gap.wall_roots, gap.wall_roots_kept,
              plain.wall_roots);
  CHECK(gap.wall_roots > 0 && gap.wall_roots_kept > 0 && gap.wall_roots_kept < gap.wall_roots);
  CHECK(plain.wall_roots == 0);
}

// ── OL-F: crossing vines ─────────────────────────────────────────────────────
static void test_f_wall_cross() {
  Part b(24, 24, 24, 3, ramp_up(24), 3.0);
  b.ask.walls_out = true;
  GrowReport off, on;
  (void)b.grow(off);
  b.ask.wall_cross = 1;
  (void)b.grow(on);
  std::printf("OL-F crossing vines: seeded %zu, grown %zu (ended side %zu, top %zu); off: seeded %zu\n", on.cross_seeded,
              on.cross_grown, on.cross_ended_side, on.cross_ended_top, off.cross_seeded);
  CHECK(on.cross_seeded > 0 && on.cross_grown > 0 && on.cross_reach_mm.size() == on.cross_grown);
  CHECK(off.cross_seeded == 0 && off.cross_grown == 0);
  CHECK(throws([&] { OrganicAsk a = b.ask; a.walls_out = false; (void)grow_strands(b.d, 1, b.field, a); }));
  CHECK(throws([&] { OrganicAsk a = b.ask; a.wall_connect = true; (void)grow_strands(b.d, 1, b.field, a); }));
}

// ── OL-G: top runs and roots; OL-H: the magnet ─────────────────────────────────
static void test_g_h_runs() {
  Part b(24, 24, 24, 3, [](const Vec3&) { return along({0, 0, 1}, 1.0); });
  b.ask.reference_mpa = 2.0;
  GrowReport off, top, root, pull;
  (void)b.grow(off);
  b.ask.top_run = 4.0;
  b.ask.run_max = 2;
  (void)b.grow(top);
  std::printf("OL-G top runs: top ends %zu, runs to a vine %zu, a run %zu, the solid %zu; refused air %zu reach %zu\n",
              top.top_vines, top.top_runs_vine, top.top_runs_run, top.top_runs_solid, top.top_refused_air,
              top.top_refused_reach);
  CHECK(top.top_vines > 0 && !top.top_run_mm.empty() &&
        top.top_run_mm.size() == top.top_runs_vine + top.top_runs_run + top.top_runs_solid);
  CHECK(off.top_vines == 0 && off.top_run_mm.empty() && off.root_feet == 0);
  // Every made run is no longer than 4 local spacings (at most 5.5 mm each here).
  double longest = 0.0;
  for (double mm : top.top_run_mm) longest = std::max(longest, mm);
  CHECK(longest > 0.0 && longest <= 4.0 * 5.5 + 1e-6);
  b.ask.top_run = 0.0;
  b.ask.root_run = 3.0;
  (void)b.grow(root);
  std::printf("OL-G roots: feet %zu, made %zu (dipped %zu)\n", root.root_feet, root.root_run_mm.size(), root.root_runs_dip);
  CHECK(root.root_feet > 0 && !root.root_run_mm.empty());
  // H: in stripes 4 mm wide the stress is straight up (no level part to follow) and, between them, leans 45 degrees
  // (a level part to follow). A run in an upright stripe has no direction of its own; with the magnet on it finds the
  // leaning stress beside it and steps on the magnet; off, never.
  Part st(24, 24, 24, 3, [](const Vec3& p) {
    return static_cast<int>(std::floor(p.x / 4.0)) % 2 ? along({1, 0, 1}, 1.0) : along({0, 0, 1}, 1.0);
  });
  st.ask.reference_mpa = 2.0;
  st.ask.top_run = 4.0;
  st.ask.run_max = 2;
  (void)st.grow(top);
  st.ask.run_pull = 1.0;
  (void)st.grow(pull);
  b.ask.root_run = 0.0;
  std::printf("OL-H magnet: top steps on the magnet %zu (runs %zu), with no target %zu; off: %zu on the magnet\n",
              pull.top_steps_magnet, pull.top_runs_magnet, pull.top_steps_none, top.top_steps_magnet);
  CHECK(pull.top_steps_magnet > 0 && pull.top_runs_magnet > 0);
  CHECK(top.top_steps_magnet == 0 && top.top_runs_magnet == 0);
  CHECK(throws([&] { OrganicAsk a = st.ask; a.run_follow = 0.0; (void)grow_strands(b.d, 1, b.field, a); }));
}

// ── OL-I: Auto by stress, and strut width by stress ─────────────────────────────
static void test_i_auto() {
  // A uniform stress of 1 MPa: u = 1 / the reference everywhere. Reference 1: u = 1, Auto gives every top end
  // run_max (3) runs; reference 10: u = 0.1, round(0.3) = 0 runs. The random draw gives 1 to 3, never 0.
  Part b(24, 24, 24, 3, [](const Vec3&) { return along({0, 0, 1}, 1.0); });
  b.ask.top_run = 4.0;
  b.ask.run_max = 3;
  GrowReport drawn, all3, none;
  b.ask.reference_mpa = 1.0;
  (void)b.grow(drawn);
  b.ask.auto_by_stress = true;
  (void)b.grow(all3);
  b.ask.reference_mpa = 10.0;
  (void)b.grow(none);
  auto at = [](const GrowReport& g, std::size_t n) { return n < g.top_n.size() ? g.top_n[n] : std::size_t(0); };
  std::printf("OL-I Auto, top ends by runs (0, 1, 2, 3): u = 1: %zu %zu %zu %zu of %zu; u = 0.1: %zu of %zu with 0; "
              "drawn: %zu %zu %zu %zu\n", at(all3, 0), at(all3, 1), at(all3, 2), at(all3, 3), all3.top_vines, at(none, 0),
              none.top_vines, at(drawn, 0), at(drawn, 1), at(drawn, 2), at(drawn, 3));
  CHECK(all3.top_vines > 0 && at(all3, 3) == all3.top_vines);
  CHECK(none.top_vines > 0 && at(none, 0) == none.top_vines && none.top_run_mm.empty());
  CHECK(drawn.top_vines > 0 && at(drawn, 0) == 0 && at(drawn, 3) < drawn.top_vines);
  // Width by stress: every point from the light width to the heavy, the heavy half wider than the light half.
  Part c(24, 24, 24, 3, ramp_up(24));
  c.ask.width_heavy_mm = 1.8;
  GrowReport rep;
  const std::vector<Strand> ss = c.grow(rep);
  std::size_t out_of = 0, wider = 0, n = 0;
  double lo_sum = 0.0, hi_sum = 0.0;
  std::size_t lo_n = 0, hi_n = 0;
  for (const Strand& s : ss)
    for (std::size_t k = 0; k < s.points.size(); ++k) {
      const double w = s.width_mm[k];
      ++n;
      out_of += w < 0.9 - 1e-9 || w > 1.8 + 1e-9;
      wider += w > 1.0;
      (s.points[k].x < 12.0 ? lo_sum : hi_sum) += w;
      ++(s.points[k].x < 12.0 ? lo_n : hi_n);
    }
  const double lo_mean = lo_n ? lo_sum / lo_n : 0.0, hi_mean = hi_n ? hi_sum / hi_n : 0.0;
  std::printf("OL-I width by stress: %zu points, outside 0.9 .. 1.8 %zu, over 1.0 %zu; mean light half %.3f, heavy %.3f\n",
              n, out_of, wider, lo_mean, hi_mean);
  CHECK(n > 0 && out_of == 0 && wider > 0 && hi_mean > lo_mean + 0.1);
  CHECK(throws([&] { OrganicAsk a = c.ask; a.width_heavy_mm = 0.5; (void)grow_strands(c.d, 1, c.field, a); }));
}

// ── OL-J: the five-cell cap as a switch (J1), and the pruning (J2) ───────────────────────────────────────────────
static Bar jbar(Vec3 a, Vec3 b, Bar::End ea, Bar::End eb, int strand) {
  Bar x;
  x.a = a; x.b = b; x.width = 0.9; x.cell = 4.0; x.region = 1; x.end_a = ea; x.end_b = eb; x.strand = strand;
  return x;
}
static void test_j_prune_and_cap() {
  // J2 on made bars: a chain of 30 bars, 2 mm each, Solid at both its ends (the largest piece); a bar hanging off its
  // 10th joint with its far end Loose in the air (J2a takes it); a separate piece of two bars, 4 mm, Solid at both
  // ends (J2b takes it: under 20 x the median 4 mm and not the largest).
  Bars bars;
  for (int i = 0; i < 30; ++i)
    bars.bars.push_back(jbar({2.0 * i, 0, 5}, {2.0 * (i + 1), 0, 5}, i == 0 ? Bar::End::Solid : Bar::End::Node,
                             i == 29 ? Bar::End::Solid : Bar::End::Node, 0));
  bars.bars.push_back(jbar({20, 0, 5}, {20, 3, 7}, Bar::End::Node, Bar::End::Loose, 1));
  bars.bars.push_back(jbar({0, 20, 5}, {2, 20, 5}, Bar::End::Solid, Bar::End::Node, 2));
  bars.bars.push_back(jbar({2, 20, 5}, {4, 20, 5}, Bar::End::Node, Bar::End::Solid, 2));
  const std::vector<PruneCount> c = prune_weave(bars, {{1, 4.0}});
  std::printf("OL-J2 prune: %zu bars left; ends cut %zu, pieces removed %zu (%.1f mm)\n", bars.bars.size(),
              c.empty() ? 0 : c[0].bars_cut, c.empty() ? 0 : c[0].pieces_removed, c.empty() ? 0.0 : c[0].removed_mm);
  CHECK(c.size() == 1 && bars.bars.size() == 30);
  CHECK(c.size() == 1 && c[0].bars_cut == 1 && c[0].pieces_removed == 1 && std::fabs(c[0].removed_mm - 4.0) < 1e-9);
  bool loose_left = false;
  for (const Bar& x : bars.bars) loose_left = loose_left || x.end_a == Bar::End::Loose || x.end_b == Bar::End::Loose;
  CHECK(!loose_left);
  // J1: on a slender block (12 mm wide) the member cap (12 / 5 = 2.4 mm, under the 8 mm widest spacing) tightens the
  // spacing (held at the tightest, 3 mm); with member_cap off only the outline cap does: fewer tightened, wider.
  Part b(12, 40, 20, 3, ramp_up(12));
  // The member width is read on the field's grid: it must reach past the part (one voxel of air all round).
  b.field = make_field(14, 42, 22, [](const Vec3& p) { return along({0, 0, 1}, 0.1 + 2.0 * (p.x - 1.0) / 12.0); });
  b.field.origin = {-1, -1, -1};
  b.ask.spacing_max_mm = 8.0;
  b.ask.shape_fit = true;
  const OrganicSpacing capped = organic_spacing(b.d, 1, b.field, b.ask);
  b.ask.member_cap = false;
  const OrganicSpacing uncapped = organic_spacing(b.d, 1, b.field, b.ask);
  double wide_c = 0.0, wide_u = 0.0;
  for (std::size_t e = 0; e < capped.candidate.size(); ++e)
    if (capped.candidate[e]) { wide_c = std::max(wide_c, capped.spacing_mm[e]); wide_u = std::max(wide_u, uncapped.spacing_mm[e]); }
  std::printf("OL-J1 member cap: tightened %zu (widest %.2f mm); off: %zu (widest %.2f mm)\n", capped.shape_fit_tightened,
              wide_c, uncapped.shape_fit_tightened, wide_u);
  CHECK(capped.shape_fit_tightened > uncapped.shape_fit_tightened);
  CHECK(wide_c <= 3.0 + 1e-9 && wide_u > wide_c);   // 12 / 5 = 2.4 is under the tightest spacing (3): held at 3
}

// ── OL-K: a flat floor on the bed (weave regions only) ─────────────────────────────
static void test_k_floor() {
  const PartMeasure pm(weld_mesh(box(20, 20, 20)));
  auto where_at = [&](double floor_mm, bool weave, const Vec3& p) {
    DomainSpec s;
    s.bead_mm = 0.45;
    s.min_strut_lines = 2.0;
    s.regions = {face_region(1, {10, 10, 0}, {0, 0, 1}, 10, 10, 20)};   // under the bottom face, the whole height
    s.regions[0].weave = weave;
    s.bed_floor_mm = floor_mm;
    const Domain d(pm, std::move(s));
    return d.probe().where(p);
  };
  const Where in_floor = where_at(2.0, true, {10, 10, 1.0}), above = where_at(2.0, true, {10, 10, 2.5});
  const Where none = where_at(0.0, true, {10, 10, 1.0}), cells = where_at(2.0, false, {10, 10, 1.0});
  std::printf("OL-K floor 2 mm: at 1 mm why %d id %d; at 2.5 mm lattice %d; no floor: lattice %d; a cell region: lattice %d\n",
              static_cast<int>(in_floor.why), in_floor.id, above.lattice() ? 1 : 0, none.lattice() ? 1 : 0,
              cells.lattice() ? 1 : 0);
  CHECK(in_floor.why == Why::BedFloor && in_floor.id == 1 && !in_floor.lattice());
  CHECK(above.lattice() && none.lattice() && cells.lattice());
}

// ── OL-L: Grade to shape as a variable (L1), and Detect floating parts (L2) ─────────────────────────────────────
static void test_l_shape_reach_and_hold() {
  Part b(30, 30, 20, 3, ramp_up(30));
  b.ask.spacing_max_mm = 8.0;
  b.ask.shape_fit = true;
  b.ask.member_cap = false;
  std::size_t t[3];
  const double reach[3] = {0.0, 1.0, 2.0};
  for (int k = 0; k < 3; ++k) {
    b.ask.shape_reach = reach[k];
    t[k] = organic_spacing(b.d, 1, b.field, b.ask).shape_fit_tightened;
  }
  std::printf("OL-L1 shape reach 0, 1, 2: tightened %zu, %zu, %zu\n", t[0], t[1], t[2]);
  CHECK(t[0] < t[1] && t[1] < t[2]);
  // L2: the region under the bottom face, 14 mm of a 24 mm block: the solid above it hangs over its lattice.
  const PartMeasure pm(weld_mesh(box(30, 30, 24)));
  DomainSpec s;
  s.bead_mm = 0.45;
  s.min_strut_lines = 2.0;
  s.regions = {face_region(1, {15, 15, 0}, {0, 0, 1}, 15, 15, 14)};
  s.regions[0].weave = true;
  const Domain d(pm, std::move(s));
  const TensorField f = make_field(30, 30, 24, ramp_up(30));
  OrganicAsk a = b.ask;
  a.shape_fit = false;
  const OrganicSpacing off = organic_spacing(d, 1, f, a);
  a.hold_parts = true;
  const OrganicSpacing on = organic_spacing(d, 1, f, a);
  std::printf("OL-L2 floating parts: patches %zu, zone %zu, tightened %zu; off: %zu patches\n", on.hold_patches.size(),
              on.hold_zone, on.hold_tightened, off.hold_patches.size());
  CHECK(!on.hold_patches.empty() && on.hold_zone > 0 && on.hold_tightened > 0);
  CHECK(off.hold_patches.empty() && off.hold_tightened == 0);
}

// ── OL-M: wall seeding by stress; OL-N: the crossing-vine gap by stress; OL-O: the crossing vines' climb ─────────
static void test_m_n_o() {
  Part b(24, 24, 24, 3, ramp_up(24), 3.0);
  b.ask.walls_out = true;
  b.ask.wall_gap = 2.5;
  GrowReport m_on;
  b.ask.wall_gap_heavy = 1.0;
  (void)b.grow(m_on);
  CHECK(m_on.wall_thirds.size() == 1);
  if (m_on.wall_thirds.size() == 1) {
    const GrowReport::WallThirds& w = m_on.wall_thirds[0];
    std::printf("OL-M wall roots by third (light, middle, heavy): %zu %zu %zu; kept, rule M off: %zu %zu %zu; on: %zu %zu %zu\n",
                w.roots[0], w.roots[1], w.roots[2], w.kept_off[0], w.kept_off[1], w.kept_off[2], w.kept_on[0],
                w.kept_on[1], w.kept_on[2]);
    CHECK(w.roots[2] > 0 && w.kept_on[2] > w.kept_off[2]);
  }
  GrowReport m_off;
  b.ask.wall_gap_heavy = 0.0;
  (void)b.grow(m_off);
  if (m_off.wall_thirds.size() == 1)
    for (int k = 0; k < 3; ++k) CHECK(m_off.wall_thirds[0].kept_on[k] == m_off.wall_thirds[0].kept_off[k]);
  CHECK(throws([&] { OrganicAsk a = b.ask; a.wall_gap_heavy = 3.0; (void)grow_strands(b.d, 1, b.field, a); }));
  // N: crossing vines chosen by a gap that shrinks where the stress is heavy.
  b.ask.wall_gap = 0.0;
  b.ask.wall_cross = 1;
  GrowReport n_off, n_on;
  (void)b.grow(n_off);
  b.ask.cross_gap_heavy = 1.0;
  (void)b.grow(n_on);
  b.ask.cross_gap_heavy = 0.0;
  CHECK(n_off.cross_thirds.size() == 1 && n_on.cross_thirds.size() == 1);
  if (n_off.cross_thirds.size() == 1 && n_on.cross_thirds.size() == 1) {
    std::printf("OL-N crossing vines seeded in the heavy third: gap 2.5 everywhere %zu, 1.0 where heavy %zu (totals %zu, %zu)\n",
                n_off.cross_thirds[0].seeded[2], n_on.cross_thirds[0].seeded[2], n_off.cross_thirds[0].total,
                n_on.cross_thirds[0].total);
    CHECK(n_on.cross_thirds[0].seeded[2] > n_off.cross_thirds[0].seeded[2]);
  }
  CHECK(throws([&] { OrganicAsk a = b.ask; a.wall_cross = 0; a.cross_gap = 2.0; (void)grow_strands(b.d, 1, b.field, a); }));
  // O: held at 30 degrees from level, a crossing vine reaches farther across before the top than at 45.
  GrowReport o45, o30;
  (void)b.grow(o45);
  b.ask.cross_climb_max_deg = 30.0;
  (void)b.grow(o30);
  auto median = [](std::vector<double> v) {
    std::sort(v.begin(), v.end());
    return v.empty() ? 0.0 : v[v.size() / 2];
  };
  std::printf("OL-O crossing vines' level reach, median: climb 45 %.2f mm (%zu vines), climb 30 %.2f mm (%zu vines)\n",
              median(o45.cross_reach_mm), o45.cross_reach_mm.size(), median(o30.cross_reach_mm), o30.cross_reach_mm.size());
  CHECK(!o30.cross_reach_mm.empty() && median(o30.cross_reach_mm) > median(o45.cross_reach_mm));
  CHECK(throws([&] { OrganicAsk a = b.ask; a.cross_climb_max_deg = 25.0; (void)grow_strands(b.d, 1, b.field, a); }));
}

// ── OL-P: level ties (Grown) ─────────────────────────────────────────────────────
static void test_p_level_ties() {
  // A minor stress a half of the major: ties are seeded (G9's gate is a tenth).
  Part b(24, 24, 24, 3, [](const Vec3& p) {
    return std::array<double, 6>{0.5 * (0.2 + p.x / 24.0), 0.0, 0.2 + p.x / 24.0, 0, 0, 0};
  });
  GrowReport off, on;
  const std::vector<Strand> plain = b.grow(off);
  b.ask.tie_level = true;
  const std::vector<Strand> level = b.grow(on);
  std::size_t ties = 0, tilted = 0, plain_level = 0;
  for (const Strand& s : level) {
    if (!s.level_tie) continue;
    ++ties;
    double lo = s.points[0].z, hi = lo;
    for (const Vec3& p : s.points) { lo = std::min(lo, p.z); hi = std::max(hi, p.z); }
    tilted += hi - lo > 0.25 * 0.2 + 1e-9;
  }
  for (const Strand& s : plain) plain_level += s.level_tie;
  std::printf("OL-P level ties: %zu strands, more than a quarter layer from level %zu; largest height difference %.4f mm; "
              "off: %zu level ties (ties laid %zu)\n", ties, tilted, on.tie_level_dz_max_mm, plain_level, off.ties_laid);
  CHECK(ties > 0 && tilted == 0 && on.tie_level && on.tie_level_dz_max_unsnapped_mm <= 1e-9);
  CHECK(plain_level == 0 && off.ties_laid > 0 && !off.tie_level);
  CHECK(throws([&] { OrganicAsk a = b.ask; a.ties = false; (void)grow_strands(b.d, 1, b.field, a); }));
}

// ── The Traced block for Q, R, T and the faults: a 30 x 30 x 20 box, the weave under its top face 16 mm deep ────────
static Settings traced_settings(int face = 1, double depth = 16.0) {
  Settings s;
  s.regions = {{1, Role::Lattice, {face}, depth, 0.0, true}};
  return s;
}
static TensorField traced_field(double nx = 30, double ny = 30, double nz = 20) {
  return make_field(static_cast<int>(nx), static_cast<int>(ny), static_cast<int>(nz), [](const Vec3& p) {
    return std::array<double, 6>{0.4 + 0.02 * p.x, 0.1, 1.0 + 0.1 * p.x, 0.0, 0.0, 0.0};
  });
}
static OrganicAsk traced_ask() {
  OrganicAsk a;
  a.spacing_min_mm = 3.0;
  a.spacing_max_mm = 6.0;
  a.shape_fit = false;
  a.width_mm = 0.9;
  return a;
}

// ── OL-Q: the floor (Q1), width by stress (Q2), and floating parts' supports (Q3) in Traced ─────────────────────────
static void test_q_traced_full() {
  const StepModel model = box_model(30, 30, 20);
  const PartMeasure pm(weld_mesh(model.mesh));
  const TensorField f = traced_field();
  OrganicAsk a = traced_ask();
  // Q2 on trace_strands.
  DomainSpec ds;
  ds.bead_mm = 0.45;
  ds.min_strut_lines = 2.0;
  bool ok = false;
  ds.regions = {region_from_faces(model, {1}, 1, Role::Lattice, 16.0, 0.0, &ok)};
  ds.regions[0].weave = true;
  const Domain d(pm, ds);
  const std::vector<Strand> light = trace_strands(d, 1, f, a);
  a.width_heavy_mm = 1.8;
  const std::vector<Strand> heavy = trace_strands(d, 1, f, a);
  std::size_t lw = 0, hw = 0, out_of = 0;
  for (const Strand& s : light)
    for (double w : s.width_mm) lw += std::fabs(w - 0.9) > 1e-9;
  for (const Strand& s : heavy)
    for (double w : s.width_mm) { hw += w > 0.9 + 1e-6; out_of += w < 0.9 - 1e-9 || w > 1.8 + 1e-9; }
  std::printf("OL-Q2 traced width by stress: points wider than the light width %zu (outside 0.9 .. 1.8 %zu); off: %zu not 0.9\n",
              hw, out_of, lw);
  CHECK(ok && !light.empty() && lw == 0 && hw > 0 && out_of == 0);
  a.width_heavy_mm = 0.0;
  // Q1: the floor through lay_organic, Traced, on a region under the BOTTOM face (it reaches the bed).
  auto lowest = [](const Outcome& o) {
    double z = 1e300;
    for (const Bar& x : o.bars.bars)
      if (x.region == 1) z = std::min({z, x.a.z, x.b.z});
    return z;
  };
  Settings s = traced_settings(0, 14.0);
  Session plain(model);
  const Outcome no_floor = plain.lay_organic(s, f, a);
  s.bed_floor_mm = 2.0;
  Session floored(model);
  const Outcome floor2 = floored.lay_organic(s, f, a);
  std::printf("OL-Q1 traced floor 2 mm: lowest weave bar point %.3f mm (%zu bars); no floor %.3f mm\n", lowest(floor2),
              floor2.bars.bars.size(), lowest(no_floor));
  // A bar that ends in the floor runs on into it by its own width (S11, a Solid end): 0.9 mm here.
  CHECK(!floor2.bars.bars.empty() && lowest(floor2) >= 2.0 - 0.9 - 1e-6 && lowest(no_floor) < 2.0 - 0.9 - 0.1);
  // Q3: the solid above the 14 mm region hangs over it: supports are laid under it in Traced.
  s.bed_floor_mm = 0.0;
  a.hold_parts = true;
  Session held(model);
  const Outcome sup = held.lay_organic(s, f, a);
  std::size_t supports = 0, none = 0;
  for (const Bar& x : sup.bars.bars) supports += x.support;
  for (const Bar& x : no_floor.bars.bars) none += x.support;
  std::printf("OL-Q3 traced supports under floating parts: %zu bars; off: %zu\n", supports, none);
  CHECK(supports > 0 && none == 0);
}

// ── OL-R: level ties in Traced ─────────────────────────────────────────────────────
static void test_r_traced_ties() {
  const StepModel model = box_model(30, 30, 20);
  const PartMeasure pm(weld_mesh(model.mesh));
  DomainSpec ds;
  ds.bead_mm = 0.45;
  ds.min_strut_lines = 2.0;
  bool ok = false;
  ds.regions = {region_from_faces(model, {1}, 1, Role::Lattice, 16.0, 0.0, &ok)};
  ds.regions[0].weave = true;
  const Domain d(pm, ds);
  const TensorField f = traced_field();
  OrganicAsk a = traced_ask();
  a.strand_keep = 0.5;   // OG3 at the tracer's old constant: R's own ties, every one laid (OL-OG3 cuts them)
  OrganicTraceStats off, on;
  const std::vector<Strand> plain = trace_strands(d, 1, f, a, &off);
  a.tie_level = true;
  const std::vector<Strand> tied = trace_strands(d, 1, f, a, &on);
  std::size_t ties = 0, tilted = 0, plain_ties = 0;
  for (const Strand& s : tied) {
    if (!s.level_tie) continue;
    ++ties;
    double lo = s.points[0].z, hi = lo;
    for (const Vec3& p : s.points) { lo = std::min(lo, p.z); hi = std::max(hi, p.z); }
    tilted += hi - lo > 0.25 * 0.2 + 1e-9;
  }
  for (const Strand& s : plain) plain_ties += s.level_tie;
  std::printf("OL-R traced level ties: laid %zu (strands %zu, tilted %zu), vertices put %zu; off: laid %zu, strands %zu\n",
              on.ties_level_laid, ties, tilted, on.ties_level_vertices_put, off.ties_level_laid, plain_ties);
  CHECK(ok && on.tie_level && on.ties_level_laid > 0 && ties == on.ties_level_laid && tilted == 0);
  CHECK(!off.tie_level && off.ties_level_laid == 0 && plain_ties == 0);
}

// ── OL-S: the cut at crossings does not move or lengthen struts; the link and its width (S8) ─────────────────────
static double total_length(const Bars& b, int strand) {
  double l = 0.0;
  for (const Bar& x : b.bars)
    if (x.strand == strand && !x.link) l += dist(x.a, x.b);
  return l;
}
static void test_s_cut_fix() {
  // Bar A along x at z = 5 (width 0.9), bar B along y 0.5 mm above it (width wa): closest approach 0.5, under the
  // light width 0.9: a crossing. Each is cut at its OWN closest point, neither leaves its line or grows, and one link
  // joins (5, 0, 5) to (5, 0, 5.5).
  for (const double wb : {0.9, 1.5}) {
    for (const double lw : {0.5, 1.0, 2.0}) {
      Bars bars;
      bars.bars.push_back(jbar({0, 0, 5}, {10, 0, 5}, Bar::End::Solid, Bar::End::Solid, 0));
      Bar b = jbar({5, -5, 5.5}, {5, 5, 5.5}, Bar::End::Solid, Bar::End::Solid, 1);
      b.width = wb;
      bars.bars.push_back(b);
      CrossingCutStats st;
      split_at_crossings(bars, 0.9, 0.2, &st, lw);
      std::size_t links = 0;
      double link_w = 0.0, link_len = 0.0;
      for (const Bar& x : bars.bars)
        if (x.link) { ++links; link_w = x.width; link_len = dist(x.a, x.b); }
      // S8: link_width x the thinner (0.9), held between the light width (0.9) and the thicker (wb).
      const double want = std::clamp(lw * 0.9, 0.9, std::max(0.9, wb));
      std::printf("OL-S cut: B %.1f wide, link width %.1f: bars %zu, links %zu (%.3f mm long, %.3f wide; want %.3f), "
                  "off the line %zu, A %.4f mm, B %.4f mm\n", wb, lw, bars.bars.size(), links, link_len, link_w, want,
                  st.off_line, total_length(bars, 0), total_length(bars, 1));
      CHECK(links == 1 && st.links == 1 && std::fabs(link_len - 0.5) < 1e-9 && std::fabs(link_w - want) < 1e-9);
      CHECK(st.off_line == 0 && st.backwards == 0);
      CHECK(std::fabs(total_length(bars, 0) - 10.0) < 1e-9 && std::fabs(total_length(bars, 1) - 10.0) < 1e-9);
      CHECK(bars.bars.size() == 5);
    }
  }
  // Brief L2, item 1: the pairs are tried cell by cell with no pair list; a pair whose boxes share many cells (two
  // bars 40 mm long crossing at a shallow angle, 2 mm cells) is still tried ONCE: one contact, one link.
  {
    Bars two;
    two.bars.push_back(jbar({0, 0, 5}, {40, 0, 5}, Bar::End::Solid, Bar::End::Solid, 0));
    two.bars.push_back(jbar({0, -1, 5.5}, {40, 1, 5.5}, Bar::End::Solid, Bar::End::Solid, 1));
    CrossingCutStats st2;
    split_at_crossings(two, 0.9, 0.2, &st2, 1.0);
    std::printf("OL-S once: two long bars over many cells: contacts %zu, links %zu, bars %zu\n", st2.contacts, st2.links,
                two.bars.size());
    CHECK(st2.contacts == 1 && st2.kept == 1 && st2.links == 1 && two.bars.size() == 5);
  }
  // A level tie is never moved: two level ties 0.1 mm apart in height (more than a quarter of a 0.2 mm layer) do
  // not cross.
  Bars ties;
  ties.bars.push_back(jbar({0, 0, 5}, {10, 0, 5}, Bar::End::Solid, Bar::End::Solid, 0));
  ties.bars.push_back(jbar({5, -5, 5.1}, {5, 5, 5.1}, Bar::End::Solid, Bar::End::Solid, 1));
  ties.bars[0].level_tie = ties.bars[1].level_tie = true;
  CrossingCutStats tst;
  split_at_crossings(ties, 0.9, 0.2, &tst, 1.0);
  CHECK(ties.bars.size() == 2 && tst.links == 0);
}

// ── OL-T: no strut runs too far without a joint ─────────────────────────────────────
static void test_t_brace() {
  const StepModel model = box_model(30, 30, 20);
  const TensorField f = traced_field();
  OrganicAsk a = traced_ask();
  Session plain(model);
  const Outcome off = plain.lay_organic(traced_settings(), f, a);
  a.unbraced_max = 6.0;
  Session braced(model);
  const Outcome on = braced.lay_organic(traced_settings(), f, a);
  std::size_t braces = 0, off_braces = 0;
  for (const Bar& x : on.bars.bars) braces += x.brace;
  for (const Bar& x : off.bars.bars) off_braces += x.brace;
  auto over = [](const Bars& b) {
    std::size_t n = 0;
    for (const WeaveStrut& s : weave_struts(b)) n += s.length_mm > 6.0 * s.thinnest_mm + 1e-6;
    return n;
  };
  std::printf("OL-T braces: %zu laid; struts over 6 widths: %zu (off: %zu, braces %zu)\n", braces, over(on.bars),
              over(off.bars), off_braces);
  CHECK(braces > 0 && off_braces == 0);
  CHECK(over(on.bars) < over(off.bars));
}

// ── OL-F1: a stated reference at the engine's own resolved value lays what an unstated one lays ─────────────────────
static bool same_bars(const Bars& x, const Bars& y) {
  if (x.bars.size() != y.bars.size()) return false;
  for (std::size_t i = 0; i < x.bars.size(); ++i) {
    const Bar& a = x.bars[i];
    const Bar& b = y.bars[i];
    if (a.a.x != b.a.x || a.a.y != b.a.y || a.a.z != b.a.z || a.b.x != b.b.x || a.b.y != b.b.y || a.b.z != b.b.z ||
        a.width != b.width || a.region != b.region || a.end_a != b.end_a || a.end_b != b.end_b || a.link != b.link ||
        a.brace != b.brace || a.level_tie != b.level_tie || a.support != b.support)
      return false;
  }
  return true;
}
static void test_reference_stated_at_resolved() {
  const StepModel model = box_model(30, 30, 20);
  const PartMeasure pm(weld_mesh(model.mesh));
  const TensorField f = traced_field();
  for (const OrganicMode mode : {OrganicMode::Traced, OrganicMode::Grown}) {
    OrganicAsk a = traced_ask();
    a.mode = mode;
    a.width_heavy_mm = 1.6;   // every reader of the reference: the spacing, the widths, the ties, the braces
    a.tie_level = true;
    a.unbraced_max = 8.0;
    // The engine's own reference: the percentile of the weave's stress, as organic_spacing resolves it.
    DomainSpec ds;
    ds.bead_mm = 0.45;
    ds.min_strut_lines = 2.0;
    bool ok = false;
    ds.regions = {region_from_faces(model, {1}, 1, Role::Lattice, 16.0, 0.0, &ok)};
    ds.regions[0].weave = true;
    const Domain d(pm, ds);
    const double resolved = organic_spacing(d, 1, f, a).reference_mpa;
    Session s1(model);
    const Outcome unstated = s1.lay_organic(traced_settings(), f, a);
    a.reference_mpa = resolved;
    Session s2(model);
    const Outcome stated = s2.lay_organic(traced_settings(), f, a);
    // And as a job would state it: the value written with 9 digits.
    char nine[64];
    std::snprintf(nine, sizeof nine, "%.9g", resolved);
    a.reference_mpa = std::strtod(nine, nullptr);
    Session s3(model);
    const Outcome written = s3.lay_organic(traced_settings(), f, a);
    std::printf("OL-F1 %s: resolved reference %.17g MPa; bars unstated %zu, stated %zu (same %d), stated as %s %zu (same %d)\n",
                mode == OrganicMode::Grown ? "Grown" : "Traced", resolved, unstated.bars.bars.size(),
                stated.bars.bars.size(), same_bars(unstated.bars, stated.bars) ? 1 : 0, nine, written.bars.bars.size(),
                same_bars(unstated.bars, written.bars) ? 1 : 0);
    CHECK(ok && resolved > 0.0 && !unstated.bars.bars.empty());
    CHECK(same_bars(unstated.bars, stated.bars));
  }
}

// ── OL-F2: the link width away from 1.0 (S8) through the path and the file job: 0.5 and 2.0 ────────────────────────
static void test_link_width_run() {
  const StepModel model = box_model(30, 30, 20);
  const TensorField f = traced_field();
  for (const double lw : {0.5, 1.0, 2.0}) {
    OrganicAsk a = traced_ask();
    a.width_heavy_mm = 1.8;   // struts of different widths, so the link's rule has room to show
    a.link_width = lw;
    Session s(model);
    const Outcome o = s.lay_organic(traced_settings(), f, a);
    std::size_t links = 0, light = 0, wider = 0;
    double widest = 0.0;
    for (const Bar& x : o.bars.bars) {
      if (!x.link) continue;
      ++links;
      light += std::fabs(x.width - 0.9) < 1e-9;
      wider += x.width > 0.9 + 1e-9;
      widest = std::max(widest, x.width);
    }
    std::printf("OL-F2 link width %.1f: %zu bars, %zu links (at the light width %zu, wider %zu, widest %.3f)\n", lw,
                o.bars.bars.size(), links, light, wider, widest);
    CHECK(!o.cancelled && links > 0 && widest <= 1.8 + 1e-9);
    for (const Bar& x : o.bars.bars) {
      if (x.link) {
        CHECK(x.width >= 0.9 - 1e-9);
        break;
      }
    }
    if (lw == 0.5) CHECK(wider == 0 && light == links);   // 0.5 x the thinner is under the light width: held at it
    if (lw == 2.0) CHECK(wider > 0);
  }
  // Through the file job: organic_link_width 0.5 and 2.0 are read and the file is made.
  if (!mesh_available()) return;
  const auto field = std::make_shared<TensorField>(f);
  for (const char* lw : {"0.5", "2.0"}) {
    const std::string text = std::string(R"({"mode": "lattice_file", "model": "block.step", "layout": {
      "min_strut_lines": 2, "bead_mm": 0.45, "region_ids": [1], "region_no_lattice": [0], "region_depth_mm": [16],
      "region_expand_mm": [0], "region_face_counts": [1], "region_faces": [1], "region_weave": [true],
      "organic_spacing_min_mm": 3, "organic_spacing_max_mm": 6, "organic_shape_fit": false, "organic_width_mm": 0.9,
      "organic_width_heavy_mm": 1.8, "organic_link_width": )") + lw + "}}";
    FileJob job = parse_file_job(text);
    CHECK(std::fabs(job.organic.link_width - std::atof(lw)) < 1e-12);
    job.tensor_field = field;
    const std::string path = std::string(ORGANIC_RULES_TMP_DIR) + "/organic_link_width.stl";
    const FileResult r = make_lattice_file(box_model(30, 30, 20), job, path);
    std::printf("OL-F2 file job, organic_link_width %s: ok %d (%s), %zu weave bars, %zu bytes, print clean %d\n", lw,
                r.ok ? 1 : 0, r.code.c_str(), r.weave_bars, r.file_bytes, r.made.print_clean ? 1 : 0);
    CHECK(r.ok && r.weave_bars > 0 && r.file_bytes > 0);
    std::remove(path.c_str());
  }
  bool refused = false;
  try {
    parse_file_job(R"({"mode": "lattice_file", "model": "b.step", "layout": {"organic_link_width": 2.5}})");
  } catch (const std::exception&) {
    refused = true;
  }
  CHECK(refused);
}

// ── OL-RUN (brief L2, item 2): the weave handed over as runs ───────────────────────────────────────────────────────
static double polyline_mm(const std::vector<Vec3>& p) {
  double l = 0.0;
  for (std::size_t k = 1; k < p.size(); ++k) l += dist(p[k - 1], p[k]);
  return l;
}
static double to_polyline(const Vec3& q, const std::vector<Vec3>& p) {
  double best = 1e300;
  for (std::size_t k = 1; k < p.size(); ++k) {
    const Vec3 a = p[k - 1], b = p[k];
    const Vec3 d{b.x - a.x, b.y - a.y, b.z - a.z};
    const double l2 = d.x * d.x + d.y * d.y + d.z * d.z;
    const double t = l2 > 0 ? std::clamp(((q.x - a.x) * d.x + (q.y - a.y) * d.y + (q.z - a.z) * d.z) / l2, 0.0, 1.0) : 0.0;
    best = std::min(best, dist(q, Vec3{a.x + d.x * t, a.y + d.y * t, a.z + d.z * t}));
  }
  return best;
}
static void test_runs() {
  const StepModel model = box_model(30, 30, 20);
  const TensorField f = traced_field();
  OrganicAsk a = traced_ask();
  a.width_heavy_mm = 1.6;   // widths that change along a run
  a.tie_level = true;       // a mark (level ties)
  a.unbraced_max = 8.0;     // another (braces)
  Session s(model);
  const Outcome o = s.lay_organic(traced_settings(), f, a);
  const std::vector<int> regions{1};
  double bars_mm = 0.0;
  std::size_t weave_bars = 0;
  for (const Bar& b : o.bars.bars)
    if (!b.link && b.region == 1) { bars_mm += dist(b.a, b.b); ++weave_bars; }
  const std::vector<WeaveRun> raw = weave_runs(o.bars, regions, 0.0);
  const std::vector<WeaveRun> thin = weave_runs(o.bars, regions, 0.1);
  double raw_mm = 0.0, worst = 0.0;
  std::size_t raw_pts = 0, thin_pts = 0, marked = 0, bad_marks = 0, ends_moved = 0;
  for (const WeaveRun& r : raw) { raw_mm += polyline_mm(r.points); raw_pts += r.points.size(); marked += r.marks != 0; }
  bool same_count = raw.size() == thin.size();
  for (std::size_t i = 0; same_count && i < raw.size(); ++i) {
    thin_pts += thin[i].points.size();
    for (const Vec3& q : raw[i].points) worst = std::max(worst, to_polyline(q, thin[i].points));
    bad_marks += thin[i].marks != raw[i].marks || thin[i].region != raw[i].region;
    ends_moved += dist(thin[i].points.front(), raw[i].points.front()) > 0.0 || dist(thin[i].points.back(), raw[i].points.back()) > 0.0;
  }
  const std::vector<std::uint8_t> packed = pack_weave_runs(thin);
  std::printf("OL-RUN: %zu weave bars (links out), %.6f mm; runs %zu, %zu points (%zu segments), %.6f mm; thinned at 0.1 mm: "
              "%zu points (%zu segments), farthest original point %.4f mm; %zu runs marked; packed %zu bytes\n",
              weave_bars, bars_mm, raw.size(), raw_pts, raw_pts - raw.size(), raw_mm, thin_pts, thin_pts - thin.size(),
              worst, marked, packed.size());
  CHECK(!raw.empty() && raw.size() < weave_bars && std::fabs(raw_mm - bars_mm) <= 1e-6);
  CHECK(same_count && worst <= 0.1 + 1e-9 && thin_pts < raw_pts && bad_marks == 0 && ends_moved == 0 && marked > 0);
  CHECK(packed.size() == 12 * thin.size() + 20 * thin_pts);
  // Leg H: version 2, the 8-byte head and 28 bytes per run; version 1 unchanged; another version refused.
  {
    const std::vector<std::uint8_t> v2 = pack_weave_runs(thin, 2);
    bool same_points = v2.size() == 8 + 28 * thin.size() + 20 * thin_pts && std::memcmp(v2.data(), "WRN2", 4) == 0;
    std::size_t a1 = 0, a2 = 8;
    for (const WeaveRun& r : thin) {   // each run's 12-byte head and its points as version 1's; then the 16 new bytes
      if (!same_points) break;
      same_points = std::memcmp(v2.data() + a2, packed.data() + a1, 12) == 0 &&
                    std::memcmp(v2.data() + a2 + 28, packed.data() + a1 + 12, 20 * r.points.size()) == 0;
      std::int32_t face = 0;
      float pa = -1.0f;
      std::memcpy(&pa, v2.data() + a2 + 12, 4);
      std::memcpy(&face, v2.data() + a2 + 20, 4);
      same_points = same_points && pa == static_cast<float>(r.proud_a_mm) && face == r.along_face;
      a1 += 12 + 20 * r.points.size();
      a2 += 28 + 20 * r.points.size();
    }
    bool threw = false;
    try { (void)pack_weave_runs(thin, 3); } catch (const std::invalid_argument&) { threw = true; }
    std::printf("OL-RUN version 2: %zu bytes, heads and points as version 1's %d; version 3 refused %d\n", v2.size(),
                same_points ? 1 : 0, threw ? 1 : 0);
    CHECK(same_points && threw);
  }
  for (const WeaveRun& r : thin) CHECK(r.points.size() >= 2 && r.width_mm.size() == r.points.size() && r.spacing_mm.size() == r.points.size());
}

// ── OL-DRAFT (brief L2, item 3): exact against draft on a made part ─────────────────────────────────────────────────
static void test_draft() {
  const StepModel model = box_model(30, 30, 20);
  const TensorField f = traced_field();
  OrganicAsk a = traced_ask();
  a.hold_parts = true;   // the solid above the 14 mm region hangs over it: supports
  Settings st = traced_settings(0, 14.0);
  st.skin = true;        // the net skin on the open faces
  Session plain(model);
  const Outcome full = plain.lay_organic(st, f, a);
  Session se(model), sd(model);
  OrganicPreviewAsk pe, pd;
  pd.quality = PreviewQuality::Draft;
  const OrganicPreview exact = lay_organic_preview(se, st, f, a, pe);
  const OrganicPreview draft = lay_organic_preview(sd, st, f, a, pd);
  auto tally = [](const Outcome& o, double& mm, std::size_t& links, std::size_t& sup, std::size_t& net) {
    mm = 0.0; links = sup = net = 0;
    for (const Bar& b : o.bars.bars) {
      if (b.link) { ++links; continue; }
      mm += dist(b.a, b.b); sup += b.support; net += b.net;
    }
  };
  double em, dm, fm;
  std::size_t el, es, en, dl, ds, dn, fl, fs, fn;
  tally(exact.outcome, em, el, es, en);
  tally(draft.outcome, dm, dl, ds, dn);
  tally(full, fm, fl, fs, fn);
  std::printf("OL-DRAFT exact: %zu bars, %.1f mm (links %zu, supports %zu, net %zu), runs %zu; draft: %zu bars, %.1f mm "
              "(links %zu, supports %zu, net %zu), runs %zu: length %+.1f %%\n", exact.outcome.bars.bars.size(), em, el, es,
              en, exact.runs.size(), draft.outcome.bars.bars.size(), dm, dl, ds, dn, draft.runs.size(),
              em > 0.0 ? 100.0 * (dm - em) / em : 0.0);
  CHECK(exact.quality == PreviewQuality::Exact && draft.quality == PreviewQuality::Draft);
  CHECK(same_bars(exact.outcome.bars, full.bars));   // exact IS the full lay
  CHECK(el > 0 && dl == 0);                          // no cut at crossings in the draft: no links (braces off here)
  // What it differs by, shown (not pinned to a sign: nothing is dropped, but nothing is joined either, and the net skin
  // and the supports are laid on other bars): on this part -13.3 % length, supports 10 -> 18, net 1,544 -> 1,070.
  CHECK(es > 0 && ds > 0 && en > 0 && dn > 0 && std::fabs(dm - em) > 0.01 * em && (es != ds || en != dn));
  CHECK(!same_bars(exact.outcome.bars, draft.outcome.bars) && !draft.runs.empty());
}

// ── OL-SWEEP (brief L2, item 4): the Auto Sweep limits ────────────────────────────────────────────────────────────
static void test_sweep_limits() {
  // A 40 x 30 x 18 box, the weave under its top face the whole 18 mm: D = min(18, the mouth's narrowest 30) = 18.
  const StepModel model = box_model(40, 30, 18);
  const PartMeasure pm(weld_mesh(model.mesh));
  DomainSpec ds;
  ds.bead_mm = 0.45;
  ds.min_strut_lines = 2.0;
  bool ok = false;
  ds.regions = {region_from_faces(model, {1}, 1, Role::Lattice, 18.0, 0.0, &ok)};
  ds.regions[0].weave = true;
  const Domain d(pm, ds);
  const std::vector<SweepLimits> L = organic_sweep_limits(d, 0.45);
  CHECK(ok && L.size() == 1);
  if (L.size() != 1) return;
  const SweepLimits& s = L[0];
  std::printf("OL-SWEEP D %.3f (depth %.3f, mouth %.3f): strut %.2f to %.2f (Auto %.2f), cell %.2f to %.2f (Auto %.2f)\n",
              s.d_mm, s.depth_mm, s.mouth_width_mm, s.strut_lower_mm, s.strut_upper_mm, s.strut_auto_mm, s.cell_lower_mm,
              s.cell_upper_mm, s.cell_auto_mm);
  auto near = [](double x, double y) { return std::fabs(x - y) < 1e-9; };
  CHECK(s.measured && near(s.d_mm, 18.0) && near(s.mouth_width_mm, 30.0));
  CHECK(near(s.strut_lower_mm, 0.9) && near(s.strut_upper_mm, 1.8) && near(s.strut_auto_mm, 1.35));
  CHECK(near(s.cell_lower_mm, 2.0) && near(s.cell_upper_mm, 8.0) && near(s.cell_auto_mm, 5.0));
  // The narrowest width over all directions, not an axis box: a square of side 10 turned 45 degrees in the plane (its
  // box is 14.1 wide) under a 20 mm deep region: D = 10.
  DomainSpec rs = ds;
  rs.regions = {face_region(2, {20, 15, 18}, {0, 0, -1}, 10, 10, 20)};
  rs.regions[0].weave = true;
  const double h = 5.0 * std::sqrt(2.0);
  rs.regions[0].prism.outline_uv = {{{0.0, -h}, {h, 0.0}, {0.0, h}, {-h, 0.0}}};
  const Domain r(pm, rs);
  const std::vector<SweepLimits> R = organic_sweep_limits(r, 0.45);
  std::printf("OL-SWEEP turned square: mouth %.4f, D %.4f\n", R.empty() ? 0.0 : R[0].mouth_width_mm, R.empty() ? 0.0 : R[0].d_mm);
  CHECK(R.size() == 1 && std::fabs(R[0].mouth_width_mm - 10.0) < 1e-9 && std::fabs(R[0].d_mm - 10.0) < 1e-9);
  CHECK(kSweepStrutLower == 1.0 / 20.0 && kSweepStrutUpper == 1.0 / 10.0 && kSweepCellLower == 1.0 / 9.0 &&
        kSweepCellUpper == 4.0 / 9.0);
}

// ── OL-SWEEP-S (OP5, brief C1): the Auto Sweep limits before any lay ─────────────────────────────────────────────────
static std::uint64_t bars_fnv(const Outcome& o) {   // FNV-1a over every bar's ends, width and region, in order
  std::uint64_t h = 1469598103934665603ULL;
  auto eat = [&](const void* p, std::size_t n) {
    const unsigned char* c = static_cast<const unsigned char*>(p);
    for (std::size_t i = 0; i < n; ++i) { h ^= c[i]; h *= 1099511628211ULL; }
  };
  for (const Bar& b : o.bars.bars) {
    const double v[7] = {b.a.x, b.a.y, b.a.z, b.b.x, b.b.y, b.b.z, b.width};
    eat(v, sizeof v);
    eat(&b.region, sizeof b.region);
  }
  return h;
}
static void test_session_sweep_limits() {
  const StepModel model = box_model(30, 30, 20);
  const TensorField f = traced_field();
  const Settings st = traced_settings();
  Session before(model);
  const std::vector<SweepLimits> early = before.sweep_limits(st, 0.45);
  const Outcome after_ask = before.lay_organic(st, f, traced_ask());   // nothing was laid by the ask: read here
  Session plain(model);
  const Outcome laid = plain.lay_organic(st, f, traced_ask());
  const std::vector<SweepLimits> late = plain.domain() ? organic_sweep_limits(*plain.domain(), 0.45) : std::vector<SweepLimits>{};
  bool same = early.size() == late.size() && !early.empty();
  for (std::size_t i = 0; same && i < early.size(); ++i) {
    const SweepLimits& a = early[i];
    const SweepLimits& b = late[i];
    same = a.region == b.region && a.measured == b.measured && a.d_mm == b.d_mm && a.depth_mm == b.depth_mm &&
           a.mouth_width_mm == b.mouth_width_mm && a.strut_lower_mm == b.strut_lower_mm &&
           a.strut_upper_mm == b.strut_upper_mm && a.strut_auto_mm == b.strut_auto_mm &&
           a.cell_lower_mm == b.cell_lower_mm && a.cell_upper_mm == b.cell_upper_mm && a.cell_auto_mm == b.cell_auto_mm;
  }
  std::printf("OL-SWEEP-S before any lay: %zu regions, D %.3f, strut Auto %.2f, cell Auto %.2f; the same as after a lay %d; "
              "the next lay read the part %d, its bars as a fresh session's %d\n", early.size(),
              early.empty() ? 0.0 : early[0].d_mm, early.empty() ? 0.0 : early[0].strut_auto_mm,
              early.empty() ? 0.0 : early[0].cell_auto_mm, same ? 1 : 0, after_ask.read_again ? 1 : 0,
              bars_fnv(after_ask) == bars_fnv(laid) ? 1 : 0);
  CHECK(same && early[0].measured);
  CHECK(after_ask.read_again && !after_ask.bars.bars.empty() && bars_fnv(after_ask) == bars_fnv(laid));
}

// ── OL-FOLLOW (OP6, brief C1): stress and shape, or shape only ───────────────────────────────────────────────────────
static OrganicAsk follow_ask(bool grown) {
  OrganicAsk a = traced_ask();
  a.width_heavy_mm = 1.6;
  a.gap_lines = 0.0;        // OG1, OG2 off, OG3 at the tracer's old 0.5: the hashes pinned here are the lays before them
  a.face_relief_mm = 0.0;
  a.strand_keep = 0.5;
  if (grown) {
    a.mode = OrganicMode::Grown;
    a.layer_mm = 0.2;
    a.auto_by_stress = true;
    a.top_run = 4.0;
    a.run_max = 3;
    a.walls_out = true;
    a.wall_gap = 2.5;
    a.wall_gap_heavy = 1.0;
  }
  return a;
}
static bool same_strands(const std::vector<Strand>& a, const std::vector<Strand>& b) {
  if (a.size() != b.size()) return false;
  for (std::size_t i = 0; i < a.size(); ++i) {
    if (a[i].points.size() != b[i].points.size() || a[i].width_mm != b[i].width_mm) return false;
    for (std::size_t k = 0; k < a[i].points.size(); ++k)
      if (a[i].points[k].x != b[i].points[k].x || a[i].points[k].y != b[i].points[k].y || a[i].points[k].z != b[i].points[k].z)
        return false;
  }
  return true;
}
static void test_follow_stress() {
  // True (the default): the bars of two made lays are today's, by hash (8340a99f, before OP6), Traced and Grown.
  {
    const StepModel model = box_model(30, 30, 20);
    const TensorField f = traced_field();
    const std::uint64_t today[2] = {0x9a119fd417d400d7ULL, 0x033117e5fef14428ULL};  // G11 amended 2026-11-19 (was 0x235c732cf4f2f269, then 0xe8c60d9cd768769b); OG5 (brief E9): its roots' run-on into the floor
    for (int g = 0; g < 2; ++g) {
      OrganicAsk a = follow_ask(g == 1);
      Session s1(model), s2(model);
      const Outcome dflt = s1.lay_organic(traced_settings(), f, a);
      a.follow_stress = true;
      const Outcome on = s2.lay_organic(traced_settings(), f, a);
      std::printf("OL-FOLLOW true, %s: %zu bars, hash %016llx (today's %016llx)\n", g ? "Grown" : "Traced",
                  on.bars.bars.size(), static_cast<unsigned long long>(bars_fnv(on)), static_cast<unsigned long long>(today[g]));
      CHECK(bars_fnv(dflt) == today[g] && bars_fnv(on) == today[g]);
    }
  }
  // False, the spacing: the widest everywhere, then only where the shape fit tightens it.
  Part b(30, 30, 20, 3, ramp_up(30));
  const OrganicSpacing stress = organic_spacing(b.d, 1, b.field, b.ask);
  b.ask.follow_stress = false;
  const OrganicSpacing plain = organic_spacing(b.d, 1, b.field, b.ask);
  b.ask.shape_fit = true;
  const OrganicSpacing fit = organic_spacing(b.d, 1, b.field, b.ask);
  std::size_t not_widest = 0, f_set = 0, below = 0;
  double s_lo = 1e300, s_hi = 0.0;
  for (std::size_t e = 0; e < plain.candidate.size(); ++e) {
    if (plain.candidate[e]) { not_widest += plain.spacing_mm[e] != 5.5; f_set += plain.stress_f[e] != 0.0; }
    if (fit.candidate[e]) below += fit.spacing_mm[e] < 5.5;
    if (stress.candidate[e]) { s_lo = std::min(s_lo, stress.spacing_mm[e]); s_hi = std::max(s_hi, stress.spacing_mm[e]); }
  }
  std::printf("OL-FOLLOW false, spacing: %zu candidates, not the widest %zu, stress measure set %zu, reference %.3f; with "
              "the shape fit: under the widest %zu, the fit tightened %zu; true: %.2f to %.2f mm\n", plain.candidates,
              not_widest, f_set, plain.reference_mpa, below, fit.shape_fit_tightened, s_lo, s_hi);
  CHECK(plain.candidates > 0 && not_widest == 0 && f_set == 0 && plain.reference_mpa == 0.0);
  CHECK(below > 0 && below == fit.shape_fit_tightened && fit.reference_mpa == 0.0);
  CHECK(s_hi - s_lo > 1.0);
  // False, the width: the light width everywhere, the heavy end set.
  Part c(24, 24, 24, 3, ramp_up(24));
  c.ask.width_heavy_mm = 1.8;
  c.ask.follow_stress = false;
  GrowReport wr;
  std::size_t n = 0, off_light = 0;
  for (const Strand& s : c.grow(wr))
    for (double w : s.width_mm) { ++n; off_light += std::fabs(w - 0.9) > 1e-12; }
  std::printf("OL-FOLLOW false, width: %zu points, not the light width %zu\n", n, off_light);
  CHECK(n > 0 && off_light == 0);
  // False, the heavy gaps do not act (M, N, P): the strands with them set are the strands without them. True: they act.
  auto pair = [](Part& p, double OrganicAsk::*key, double heavy, bool follow) {
    p.ask.follow_stress = follow;
    GrowReport r0, r1;
    const std::vector<Strand> off = p.grow(r0);
    p.ask.*key = heavy;
    const std::vector<Strand> on = p.grow(r1);
    p.ask.*key = 0.0;
    return same_strands(off, on);
  };
  Part g(24, 24, 24, 3, ramp_up(24), 3.0);
  g.ask.walls_out = true;
  g.ask.wall_gap = 2.5;
  const bool m_f = pair(g, &OrganicAsk::wall_gap_heavy, 1.0, false), m_t = pair(g, &OrganicAsk::wall_gap_heavy, 1.0, true);
  Part t(24, 24, 24, 3, [](const Vec3& q) {   // OL-P's field: a minor stress a half of the major, so ties are laid
    return std::array<double, 6>{0.5 * (0.2 + q.x / 24.0), 0.0, 0.2 + q.x / 24.0, 0, 0, 0};
  });
  const bool p_f = pair(t, &OrganicAsk::tie_gap_heavy, 0.5, false), p_t = pair(t, &OrganicAsk::tie_gap_heavy, 0.5, true);
  g.ask.wall_gap = 0.0;
  g.ask.wall_cross = 1;
  const bool n_f = pair(g, &OrganicAsk::cross_gap_heavy, 1.0, false), n_t = pair(g, &OrganicAsk::cross_gap_heavy, 1.0, true);
  std::printf("OL-FOLLOW heavy gaps change nothing: false M %d N %d P %d; true M %d N %d P %d\n", m_f, n_f, p_f, m_t, n_t, p_t);
  CHECK(m_f && n_f && p_f);
  CHECK(!m_t && !n_t && !p_t);
  // False, Auto's runs per end: u = 0, no top end makes a run (true, u = 1: every one makes run_max).
  Part u(24, 24, 24, 3, [](const Vec3&) { return along({0, 0, 1}, 1.0); });
  u.ask.top_run = 4.0;
  u.ask.run_max = 3;
  u.ask.reference_mpa = 1.0;
  u.ask.auto_by_stress = true;
  GrowReport all3, none;
  (void)u.grow(all3);
  u.ask.follow_stress = false;
  (void)u.grow(none);
  auto at = [](const GrowReport& r, std::size_t k) { return k < r.top_n.size() ? r.top_n[k] : std::size_t(0); };
  std::printf("OL-FOLLOW Auto runs per top end: true %zu of %zu with 3; false %zu of %zu with 0\n", at(all3, 3),
              all3.top_vines, at(none, 0), none.top_vines);
  CHECK(all3.top_vines > 0 && at(all3, 3) == all3.top_vines);
  CHECK(none.top_vines > 0 && at(none, 0) == none.top_vines && none.top_run_mm.empty());
  // The file job reads the key.
  const std::string text = R"({"mode": "lattice_file", "model": "block.step", "layout": {
      "min_strut_lines": 2, "bead_mm": 0.45, "region_ids": [1], "region_no_lattice": [0], "region_depth_mm": [16],
      "region_expand_mm": [0], "region_face_counts": [1], "region_faces": [1], "region_weave": [true],
      "organic_spacing_min_mm": 3, "organic_spacing_max_mm": 6, "organic_follow_stress": false}})";
  const FileJob job = parse_file_job(text);
  CHECK(!job.organic.follow_stress);
}

// ── OL-ADD (brief E3a, OS10 to OS13): strengthening by adding. A round of brace points and widenings on a laid lattice
// keeps every old bar (whole, or cut on its own line, never thinner); the additions replayed after a new lay give the
// same lattice bar for bar (its hash); written and read back they are the same list; a wrong hash, a bar the lay does
// not hold, or a kind this engine does not know is refused; the lay is the same with 1 and with 4 threads.
static void test_additions() {
  const StepModel model = box_model(30, 30, 20);
  const TensorField f = traced_field();
  OrganicAsk a = traced_ask();
  a.width_heavy_mm = 1.6;
  Session s0(model);
  const Outcome base = s0.lay_organic(traced_settings(), f, a, 1);
  Session s4(model);
  const Outcome base4 = s4.lay_organic(traced_settings(), f, a, 4);
  CHECK(!base.bars.bars.empty() && bars_hash(base.bars) == bars_hash(base4.bars));
  CHECK(old_bars_kept(base.bars, base.bars).empty());
  // The round: the five longest non-link weave bars braced at their middles (as wide as they are) and widened by half.
  std::vector<std::size_t> idx;
  for (std::size_t i = 0; i < base.bars.bars.size(); ++i)
    if (!base.bars.bars[i].link && base.bars.bars[i].strand >= 0 && !base.bars.bars[i].net) idx.push_back(i);
  auto blen = [&](std::size_t i) { return dist(base.bars.bars[i].a, base.bars.bars[i].b); };
  std::sort(idx.begin(), idx.end(), [&](std::size_t x, std::size_t y) { return blen(x) != blen(y) ? blen(x) > blen(y) : x < y; });
  idx.resize(std::min<std::size_t>(5, idx.size()));
  AddRound braces;
  for (std::size_t i : idx) {
    const Bar& b = base.bars.bars[i];
    braces.ops.push_back({1, {b.a.x, b.a.y, b.a.z, b.b.x, b.b.y, b.b.z, 0.5, b.width}});
  }
  Bars after = base.bars;
  const Domain& dom = *s0.domain();
  AddContext c;
  c.light_mm = 0.9;
  c.layer_mm = a.layer_mm;
  c.link_width = a.link_width;
  AddReport rep;
  std::string why;
  CHECK(apply_add_round(after, dom, braces, c, &rep, &why));
  // Then the widenings, on the bars as they now are (each braced bar's pieces).
  std::vector<Bar> olds;
  for (std::size_t i : idx) olds.push_back(base.bars.bars[i]);
  const std::vector<std::vector<std::size_t>> on = pieces_on(after, olds);
  AddRound round = braces;
  for (const auto& ps : on)
    for (std::size_t j : ps) {
      const Bar& b = after.bars[j];
      round.ops.push_back({2, {b.a.x, b.a.y, b.a.z, b.b.x, b.b.y, b.b.z, 1.5 * b.width}});
    }
  AddRound widen;
  for (const AddOp& op : round.ops)
    if (op.kind == 2) widen.ops.push_back(op);
  AddReport rep2;
  CHECK(apply_add_round(after, dom, widen, c, &rep2, &why));
  std::size_t split = 0;
  const std::string kept = old_bars_kept(base.bars, after, 1e-5, &split);
  std::printf("OL-ADD round: %zu brace points, %zu braces, %zu bars widened, %zu links widened; old bars split %zu; "
              "invariant: %s\n", rep.brace_points, rep.braces, rep2.widened, rep2.links_widened, split,
              kept.empty() ? "held" : kept.c_str());
  CHECK(rep.braces > 0 && rep2.widened >= idx.size() && kept.empty() && split >= idx.size());
  CHECK(after.bars.size() > base.bars.bars.size());
  round.hash = bars_hash(after);
  // A bar of (almost) no length is found too (the stand's lattice has some: shorter than the 1e-5 mm tolerance).
  {
    Bars tiny;
    Bar t = base.bars.bars[idx[0]];
    t.b = {t.a.x + 2e-6, t.a.y, t.a.z};
    tiny.bars.push_back(t);
    CHECK(old_bars_kept(tiny, tiny).empty());
  }
  // A thinner bar of the same strand lying along an old bar (a strand running back over itself) does not hide it.
  {
    Bars two;
    Bar t = base.bars.bars[idx[0]];
    two.bars.push_back(t);
    Bar back = t;
    std::swap(back.a, back.b);
    back.width = 0.5 * t.width;
    Bars with = two;
    with.bars.insert(with.bars.begin(), back);
    CHECK(old_bars_kept(two, with).empty());
  }
  // The invariant catches a thinner bar and a moved end.
  {
    Bars thin = after;
    for (Bar& b : thin.bars)
      if (!b.link && b.strand == base.bars.bars[idx[0]].strand) { b.width *= 0.5; break; }
    CHECK(!old_bars_kept(base.bars, thin).empty());
    Bars moved = after;
    moved.bars[0].a.x += 0.01;
    CHECK(!old_bars_kept(base.bars, moved).empty());
  }
  // A second round on top: a widening of one more bar.
  AddRound second;
  {
    std::size_t k = 0;
    while (k < after.bars.size() && (after.bars[k].link || after.bars[k].strand < 0)) ++k;
    const Bar& b = after.bars[k];
    second.ops.push_back({2, {b.b.x, b.b.y, b.b.z, b.a.x, b.a.y, b.a.z, b.width + 0.2}});   // named b to a
  }
  Bars after2 = after;
  CHECK(apply_add_round(after2, dom, second, c, nullptr, &why));
  second.hash = bars_hash(after2);
  CHECK(old_bars_kept(base.bars, after2).empty() && old_bars_kept(after, after2).empty());
  // A third round: the bars widened in round 1 widened again; every earlier round's widths stay in force.
  AddRound third;
  {
    const std::vector<std::vector<std::size_t>> on2 = pieces_on(after2, olds);
    for (const auto& ps : on2)
      for (std::size_t j : ps) {
        const Bar& b = after2.bars[j];
        third.ops.push_back({2, {b.a.x, b.a.y, b.a.z, b.b.x, b.b.y, b.b.z, 1.2 * b.width}});
      }
  }
  Bars after3 = after2;
  CHECK(apply_add_round(after3, dom, third, c, nullptr, &why));
  third.hash = bars_hash(after3);
  CHECK(old_bars_kept(base.bars, after3).empty() && old_bars_kept(after, after3).empty() &&
        old_bars_kept(after2, after3).empty());
  {   // a round-1 widening undone in round 3 is caught against round 1 (never thinner), though round 0 would pass it
    Bars undone = after3;
    const std::vector<std::vector<std::size_t>> on3 = pieces_on(undone, olds);
    for (std::size_t j : on3[0]) undone.bars[j].width = base.bars.bars[idx[0]].width;
    CHECK(old_bars_kept(base.bars, undone).empty() && !old_bars_kept(after, undone).empty());
  }
  Additions adds;
  adds.rounds = {round, second, third};
  // Replayed after a new lay (through the ask, as the file job and the preview lay it): the same lattice.
  OrganicAsk b2 = a;
  b2.additions = adds;
  Session s1(model);
  const Outcome replay = s1.lay_organic(traced_settings(), f, b2, 3);
  std::printf("OL-ADD replay: %zu rounds, %s, hash %s\n", replay.additions_rounds,
              replay.additions_refused.empty() ? "applied" : replay.additions_refused.c_str(),
              bars_hash(replay.bars) == third.hash ? "the same" : "DIFFERENT");
  CHECK(replay.additions_refused.empty() && replay.additions_rounds == 3 && bars_hash(replay.bars) == third.hash &&
        replay.bars.bars.size() == after3.bars.size());
  // The file, and strengthened.json version 2.
  const std::string dir = std::string(ORGANIC_RULES_TMP_DIR) + "/ol_add";
  std::filesystem::create_directories(dir);
  CHECK(write_additions_file(dir + "/additions.bin", adds));
  Strengthened st;
  st.version = 2;
  st.additions = "additions.bin";
  CHECK(write_strengthened_file(dir + "/strengthened.json", st, "  \"rounds\": 3"));
  {
    TensorField keep = f;
    OrganicAsk r = a;
    CHECK(apply_strengthened(dir + "/strengthened.json", keep, r, &why));
    CHECK(keep.voigt == f.voigt && r.additions.rounds.size() == 3 && r.additions.rounds[1].hash == second.hash && r.additions.rounds[2].hash == third.hash &&
          r.additions.rounds[0].ops.size() == round.ops.size() && r.additions.rounds[0].ops[0].v == round.ops[0].v);
  }
  // Refused: a wrong hash; a bar not in the lattice; a kind not known.
  {
    OrganicAsk bad = b2;
    bad.additions.rounds[2].hash ^= 1;
    Session sx(model);
    const Outcome o = sx.lay_organic(traced_settings(), f, bad);
    CHECK(!o.additions_refused.empty() && o.bars.bars.empty());
    std::printf("OL-ADD wrong hash: %s\n", o.additions_refused.c_str());
    AddRound none;
    none.ops.push_back({2, {-99, -99, -99, -98, -98, -98, 1.0}});
    Bars x = base.bars;
    CHECK(!apply_add_round(x, dom, none, c, nullptr, &why) && why.find("not in the lattice") != std::string::npos);
    AddRound unknown;
    unknown.ops.push_back({4, {0.0}});   // (kind 3 is OS18's relief vine since brief E8: 4 is unknown)
    CHECK(!apply_add_round(x, dom, unknown, c, nullptr, &why) && why.find("kind 4") != std::string::npos);
    AddRound short3;   // a relief vine whose numbers do not match its point count
    short3.ops.push_back({3, {1.0, 0.9, 2.0, 0.0, 0.0, 3.0, 0, 0, 0}});
    CHECK(!apply_add_round(x, dom, short3, c, nullptr, &why) && why.find("relief vine") != std::string::npos);
  }
}

// ── OL-VALID (OP7, brief C2, E1): one validation call; the session path and the file job refuse alike ────────────────
// The two judged Auto asks (the app's defaults, sheet H; his stand's limits 2 to 8 mm and 0.9 to 1.8 mm, layer 0.2).
static OrganicAsk judged_ask(bool grown) {
  OrganicAsk a;
  a.mode = grown ? OrganicMode::Grown : OrganicMode::Traced;
  a.follow_stress = true;
  a.spacing_min_mm = 2.0;
  a.spacing_max_mm = 8.0;
  a.width_mm = 0.9;
  a.width_heavy_mm = 1.8;
  a.foot_gap = 2.5;
  a.walls_out = grown;
  a.wall_gap = grown ? 2.5 : 0.0;
  a.wall_gap_heavy = grown ? 1.0 : 0.0;
  a.wall_cross = grown ? 1 : 0;
  a.cross_gap = 2.5;
  a.cross_gap_heavy = grown ? 1.0 : 0.0;
  a.stress_goal = grown;
  a.ties = true;
  a.tie_level = true;
  a.tie_gap = 1.0;
  a.tie_gap_heavy = 0.5;
  a.shape_reach = 1.0;
  a.shape_fit = true;
  a.member_cap = false;
  a.hold_parts = true;
  a.part_to_floor = true;
  a.part_reach_mm = 1.5 * 8.0;
  a.part_support_mm = 0.75 * 2.0;
  a.link_width = 1.0;
  a.unbraced_max = 10.0;
  a.prune = true;
  a.run_max = 1;
  a.bed_floor_mm = 4.0 * 0.2;
  a.layer_mm = 0.2;
  return a;
}
static bool has_refusal(const std::vector<OrganicRefusal>& r, const std::string& setting, const std::string& code) {
  for (const OrganicRefusal& x : r)
    if (x.setting == setting && x.code == code) return true;
  return false;
}
static void test_validate() {
  const Settings st = traced_settings();
  const TensorField f = traced_field();
  for (int g = 0; g < 2; ++g) {
    const std::vector<OrganicRefusal> r = validate_organic(st, judged_ask(g == 1), &f);
    std::printf("OL-VALID judged Auto ask, %s: %zu refusals\n", g ? "Grown" : "Traced", r.size());
    for (const OrganicRefusal& x : r) std::printf("  (%s %s: %s)\n", x.setting.c_str(), x.code.c_str(), x.text.c_str());
    CHECK(r.empty());
  }
  CHECK(validate_organic(st, traced_ask(), &f).empty());
  const double nan = std::numeric_limits<double>::quiet_NaN();
  struct Case {
    bool grown;
    std::function<void(Settings&, OrganicAsk&)> change;
    const char* setting;
    const char* code;
  };
  using S = Settings;
  using A = OrganicAsk;
  const std::vector<Case> cases = {
      {true, [](S& s, A&) { s.bead_mm = 0.0; }, "bead_mm", "no_thinnest_strut"},
      {true, [](S&, A& a) { a.spacing_mm = -1.0; }, "spacing_mm", "not_above_zero"},
      {true, [](S&, A& a) { a.spacing_min_mm = 0.0; }, "spacing_min_mm", "not_above_zero"},
      {true, [](S&, A& a) { a.spacing_max_mm = 1.5; }, "spacing_max_mm", "under_other_end"},
      {true, [](S&, A& a) { a.spacing_exponent = 0.0; }, "spacing_exponent", "not_above_zero"},
      {true, [](S&, A& a) { a.width_mm = -1.0; }, "width_mm", "below_zero"},
      {true, [](S&, A& a) { a.width_mm = 0.6; }, "width_mm", "under_thinnest_strut"},
      {true, [](S&, A& a) { a.width_heavy_mm = 0.5; }, "width_heavy_mm", "under_other_end"},
      // (OG1's gap off: these pin the print floor; with the gap on its larger floor is the one refused, OL-OG1.)
      {true, [](S&, A& a) { a.spacing_min_mm = 1.0; a.gap_lines = 0.0; }, "spacing_min_mm", "under_smallest_cell"},
      {false, [](S&, A& a) { a.spacing_mm = 1.0; a.tie_gap_heavy = 0.0; a.gap_lines = 0.0; }, "spacing_mm", "under_smallest_cell"},
      {true, [](S&, A& a) { a.link_width = 3.0; }, "link_width", "out_of_range"},
      {true, [](S&, A& a) { a.unbraced_max = 2.0; }, "unbraced_max", "out_of_range"},
      {true, [](S&, A& a) { a.shape_reach = -1.0; }, "shape_reach", "below_zero"},
      {true, [](S&, A& a) { a.bed_floor_mm = -1.0; }, "bed_floor_mm", "below_zero"},
      {true, [](S&, A& a) { a.part_reach_mm = -1.0; }, "part_reach_mm", "below_zero"},
      {true, [](S&, A& a) { a.part_support_mm = -1.0; }, "part_support_mm", "below_zero"},
      {true, [](S&, A& a) { a.tie_swirl = 1.5; }, "tie_swirl", "out_of_range"},
      {true, [nan](S&, A& a) { a.foot_gap = nan; }, "foot_gap", "not_a_number"},
      {true, [](S&, A& a) { a.void_ratio = 0.0; }, "void_ratio", "not_above_zero"},
      {true, [](S&, A& a) { a.reseed_rounds = 101; }, "reseed_rounds", "out_of_range"},
      {true, [nan](S&, A& a) { a.wall_gap = nan; }, "wall_gap", "not_a_number"},
      {true, [nan](S&, A& a) { a.wall_gap_heavy = nan; }, "wall_gap_heavy", "not_a_number"},
      {true, [](S&, A& a) { a.wall_gap = 0.0; }, "wall_gap_heavy", "needs_light_end"},
      {true, [](S&, A& a) { a.wall_gap_heavy = 3.0; }, "wall_gap_heavy", "over_light_end"},
      {true, [](S&, A& a) { a.spacing_mm = 3.0; }, "wall_gap_heavy", "needs_range"},
      {true, [](S&, A& a) { a.wall_cross = 3; }, "wall_cross", "out_of_range"},
      {true, [](S&, A& a) { a.walls_out = false; }, "wall_cross", "needs_wall_seeds"},
      {true, [](S&, A& a) { a.wall_connect = true; }, "wall_cross", "with_wall_connect"},
      {true, [](S&, A& a) { a.cross_gap = 0.0; }, "cross_gap", "not_above_zero"},
      {false, [](S&, A& a) { a.cross_gap = 2.0; }, "cross_gap", "needs_crossing_vines"},
      {true, [nan](S&, A& a) { a.cross_gap_heavy = nan; }, "cross_gap_heavy", "not_a_number"},
      {false, [](S&, A& a) { a.cross_gap_heavy = 1.0; }, "cross_gap_heavy", "needs_crossing_vines"},
      {true, [](S&, A& a) { a.cross_gap_heavy = 3.0; }, "cross_gap_heavy", "over_light_end"},
      {true, [](S&, A& a) { a.spacing_mm = 3.0; }, "cross_gap_heavy", "needs_range"},
      {true, [](S&, A& a) { a.cross_climb_max_deg = 50.0; }, "cross_climb_max_deg", "out_of_range"},
      {false, [](S&, A& a) { a.cross_climb_max_deg = 40.0; }, "cross_climb_max_deg", "needs_crossing_vines"},
      {true, [](S&, A& a) { a.ties = false; }, "tie_level", "needs_ties"},
      {true, [](S&, A& a) { a.tie_gap = 0.0; }, "tie_gap", "not_above_zero"},
      {true, [](S&, A& a) { a.ties = false; a.tie_level = false; a.tie_gap = 0.8; }, "tie_gap", "needs_ties"},
      {true, [nan](S&, A& a) { a.tie_gap_heavy = nan; }, "tie_gap_heavy", "not_a_number"},
      {true, [](S&, A& a) { a.ties = false; a.tie_level = false; }, "tie_gap_heavy", "needs_ties"},
      {true, [](S&, A& a) { a.tie_gap_heavy = 2.0; }, "tie_gap_heavy", "over_light_end"},
      {false, [](S&, A& a) { a.spacing_mm = 3.0; }, "tie_gap_heavy", "needs_range"},
      {true, [](S&, A& a) { a.top_run = -1.0; }, "top_run", "below_zero"},
      {true, [](S&, A& a) { a.root_run = -1.0; }, "root_run", "below_zero"},
      {true, [](S&, A& a) { a.run_gap = -1.0; }, "run_gap", "below_zero"},
      {true, [](S&, A& a) { a.run_max = 0; }, "run_max", "out_of_range"},
      {true, [](S&, A& a) { a.run_follow = 0.0; }, "run_follow", "not_above_zero"},
      {true, [](S&, A& a) { a.run_pull = -1.0; }, "run_pull", "below_zero"},
      {true, [](S&, A& a) { a.run_seek = -1.0; }, "run_seek", "below_zero"},
      {true, [](S&, A& a) { a.run_min = -1.0; }, "run_min", "below_zero"},
      {true, [nan](S&, A& a) { a.root_gap = nan; }, "root_gap", "not_a_number"},
      {true, [](S&, A& a) { a.build_dir = {0, 0, 0}; }, "build_dir", "zero_direction"},
      {true, [](S&, A& a) { a.layer_mm = 0.0; }, "layer_mm", "not_above_zero"},
      {true, [](S&, A& a) { a.seed_stride = 0.0; }, "seed_stride", "not_above_zero"},
  };
  std::size_t hit = 0, plain = 0;
  for (const Case& c : cases) {
    Settings s = st;
    OrganicAsk a = judged_ask(c.grown);
    c.change(s, a);
    const std::vector<OrganicRefusal> r = validate_organic(s, a, &f);
    const bool found = has_refusal(r, c.setting, c.code);
    hit += found;
    bool clean = true;   // one sentence, no key name (no underscore), ends with a full stop
    for (const OrganicRefusal& x : r) {
      clean = clean && x.text.find('_') == std::string::npos && !x.text.empty() && x.text.back() == '.';
      if (x.setting == c.setting && x.code == c.code)
        std::printf("OL-VALID %-20s %-21s \"%s\"\n", x.setting.c_str(), x.code.c_str(), x.text.c_str());
    }
    plain += clean;
    if (!found) std::printf("  (not refused: %s %s)\n", c.setting, c.code);
  }
  std::printf("OL-VALID %zu of %zu cases refused as named, %zu with plain texts\n", hit, cases.size(), plain);
  CHECK(hit == cases.size() && plain == cases.size());
  // The numbers: the smallest printable cell named and carried (0.9 mm strut: 1.38 mm, shown 1.39).
  {
    OrganicAsk a = judged_ask(false);
    a.spacing_min_mm = 1.0;
    a.gap_lines = 0.0;   // OG1 off: the print floor itself
    const std::vector<OrganicRefusal> r = validate_organic(st, a, &f);
    const bool num = !r.empty() && r[0].has_min && std::fabs(r[0].allowed_min - 0.9 * kSmallestCellFactor) < 1e-12 &&
                     r[0].given == 1.0 && r[0].text.find("1.39 mm") != std::string::npos;
    CHECK(num);
    a.spacing_min_mm = 1.39;
    CHECK(validate_organic(st, a, &f).empty());
  }
  // No stress input with a weave region (the session path's own rule).
  {
    const std::vector<OrganicRefusal> r = validate_organic(st, judged_ask(true), new TensorField());
    CHECK(r.size() == 1 && has_refusal(r, "stress", "no_stress_result"));
    CHECK(validate_organic(st, judged_ask(true), nullptr).empty());
  }
  // The session path: refused cleanly (no throw), nothing laid, the kept domain untouched; the preview the same.
  {
    const StepModel model = box_model(30, 30, 20);
    Session s(model);
    OrganicAsk a = judged_ask(true);
    a.unbraced_max = 2.0;
    a.link_width = 3.0;
    bool threw = false;
    Outcome o;
    try { o = s.lay_organic(st, f, a); } catch (const std::exception&) { threw = true; }
    CHECK(!threw && o.refused.size() == 2 && o.bars.bars.empty() && s.domain() == nullptr);
    OrganicPreview p;
    try { p = lay_organic_preview(s, st, f, a, OrganicPreviewAsk{}); } catch (const std::exception&) { threw = true; }
    CHECK(!threw && p.outcome.refused.size() == 2 && p.runs.empty());
    const Outcome none = s.lay_organic(st, TensorField{}, judged_ask(true));
    CHECK(none.refused.size() == 1 && none.refused[0].setting == "stress");
    // Width under the thinnest strut: Traced threw from the old tracer, Grown from the Grower; now a refusal.
    a = traced_ask();
    a.width_mm = 0.6;
    try { o = s.lay_organic(st, f, a); } catch (const std::exception&) { threw = true; }
    CHECK(!threw && has_refusal(o.refused, "width_mm", "under_thinnest_strut"));
    std::printf("OL-VALID session path: refused without a throw %d\n", threw ? 0 : 1);
  }
  // The file job: the same rule, its key named in the detail, the plain sentence after it.
  {
    const std::string head = R"({"mode": "lattice_file", "model": "block.step", "layout": {
      "min_strut_lines": 2, "bead_mm": 0.45, "region_ids": [1], "region_no_lattice": [0], "region_depth_mm": [16],
      "region_expand_mm": [0], "region_face_counts": [1], "region_faces": [1], "region_weave": [true],
      "organic_spacing_min_mm": )";
    auto why = [&](const std::string& tail) {
      try { (void)parse_file_job(head + tail); } catch (const std::exception& e) { return std::string(e.what()); }
      return std::string();
    };
    const std::string small = why(R"(1, "organic_spacing_max_mm": 6, "organic_gap_lines": 0}})");   // OG1 off
    const std::string link = why(R"(3, "organic_spacing_max_mm": 6, "organic_link_width": 3}})");
    std::printf("OL-VALID file job: \"%s\"; \"%s\"\n", small.c_str(), link.c_str());
    CHECK(small.find("organic_spacing_min_mm") != std::string::npos && small.find("1.39 mm") != std::string::npos);
    CHECK(link.find("organic_link_width") != std::string::npos &&
          link.find("Link thickness: it must be from 0.5 to 2") != std::string::npos);
    CHECK(why(R"(3, "organic_spacing_max_mm": 6}})").empty());
  }
}

// ── OL-EQUAL (OP8, brief C2, E2): equal cell ends are accepted; the heavy ends then do not act, and a note says so ────
static void test_equal_ends() {
  const StepModel model = box_model(30, 30, 20);
  const TensorField f = traced_field();
  const Settings st = traced_settings();
  for (int g = 0; g < 2; ++g) {
    OrganicAsk heavy = judged_ask(g == 1);
    heavy.spacing_min_mm = heavy.spacing_max_mm = 4.0;
    OrganicAsk light = heavy;
    light.width_heavy_mm = light.wall_gap_heavy = light.cross_gap_heavy = light.tie_gap_heavy = 0.0;
    const std::vector<OrganicRefusal> r = validate_organic(st, heavy, &f);
    Session s1(model), s2(model);
    const Outcome a = s1.lay_organic(st, f, heavy);
    const Outcome b = s2.lay_organic(st, f, light);
    std::printf("OL-EQUAL %s, cell 4 to 4 with every heavy end set: %zu refusals, %zu bars (hash %016llx), without the "
                "heavy ends %zu bars (hash %016llx); notes %zu / %zu: \"%s\"\n", g ? "Grown" : "Traced", r.size(),
                a.bars.bars.size(), static_cast<unsigned long long>(bars_fnv(a)), b.bars.bars.size(),
                static_cast<unsigned long long>(bars_fnv(b)), a.notes.size(), b.notes.size(),
                a.notes.empty() ? "" : a.notes[0].c_str());
    CHECK(r.empty() && a.refused.empty() && !a.bars.bars.empty() && bars_fnv(a) == bars_fnv(b));
    CHECK(a.notes.size() == 1 && a.notes[0] == kNoteEqualEnds && b.notes.empty());
    // A grower or a level-tie walk given the same ask directly does not throw either.
    bool threw = false;
    try { (void)grow_strands(*s1.domain(), 1, f, heavy); } catch (const std::exception&) { threw = true; }
    CHECK(!threw);
  }
  // Ends that differ: nothing changes (the bars of OL-FOLLOW's two made lays, today's hashes from before OP6), no note.
  const std::uint64_t today[2] = {0x9a119fd417d400d7ULL, 0x033117e5fef14428ULL};  // G11 amended 2026-11-19 (was 0x235c732cf4f2f269, then 0xe8c60d9cd768769b); OG5 (brief E9): its roots' run-on into the floor
  for (int g = 0; g < 2; ++g) {
    Session s(model);
    const Outcome o = s.lay_organic(st, f, follow_ask(g == 1));
    std::printf("OL-EQUAL ends differ, %s: hash %016llx (today's %016llx), notes %zu\n", g ? "Grown" : "Traced",
                static_cast<unsigned long long>(bars_fnv(o)), static_cast<unsigned long long>(today[g]), o.notes.size());
    CHECK(bars_fnv(o) == today[g] && o.notes.empty());
  }
}

// ── OL-FLOOR-ASK (OP9, brief C2, E3): the session lays the flat floor from the ask, as the file job does ──────────────
static void test_floor_from_ask() {
  const StepModel model = box_model(30, 30, 20);
  const TensorField f = traced_field();
  const std::string job = R"({"mode": "lattice_file", "model": "block.step", "layout": {
      "min_strut_lines": 2, "bead_mm": 0.45, "region_ids": [1], "region_no_lattice": [0], "region_depth_mm": [14],
      "region_expand_mm": [0], "region_face_counts": [1], "region_faces": [0], "region_weave": [true],
      "organic_spacing_min_mm": 3, "organic_spacing_max_mm": 6, "organic_shape_fit": false, "organic_width_mm": 0.9,
      "organic_bed_floor_mm": 2, "organic_mode": ")";
  for (int g = 0; g < 2; ++g) {
    const FileJob fj = parse_file_job(job + (g ? "grown" : "traced") + "\"}}");
    Settings plain = fj.settings;
    plain.bed_floor_mm = 0.0;   // what the app's bridge sends: no floor in the settings, the floor in the ask
    Session by_job(model), by_ask(model), none(model);
    const Outcome a = by_job.lay_organic(fj.settings, f, fj.organic);
    const Outcome b = by_ask.lay_organic(plain, f, fj.organic);
    OrganicAsk off = fj.organic;
    off.bed_floor_mm = 0.0;
    const Outcome c = none.lay_organic(plain, f, off);
    double low = 1e300, low_none = 1e300;
    for (const Bar& x : b.bars.bars) low = std::min({low, x.a.z, x.b.z});
    for (const Bar& x : c.bars.bars) low_none = std::min({low_none, x.a.z, x.b.z});
    std::printf("OL-FLOOR-ASK %s, floor 2 mm in the ask only: %zu bars, hash %016llx; the file job's settings: %zu bars, "
                "hash %016llx; lowest bar point %.3f mm (no floor %.3f mm)\n", g ? "Grown" : "Traced",
                b.bars.bars.size(), static_cast<unsigned long long>(bars_fnv(b)), a.bars.bars.size(),
                static_cast<unsigned long long>(bars_fnv(a)), low, low_none);
    // A bar that ends in the floor runs on into it by its own width (S11, a Solid end): 0.9 mm here (as OL-Q1).
    CHECK(fj.settings.bed_floor_mm == 2.0 && !b.bars.bars.empty() && bars_fnv(a) == bars_fnv(b));
    CHECK(low >= 2.0 - 0.9 - 1e-6 && low_none < 2.0 - 0.9 - 0.1);
  }
}

// ── OL-SWEEP-FOR (OP10, brief C2, E4 and E7): a group's limits, the union over its measured regions ──────────────────
static void test_sweep_limits_for() {
  // A 40 x 30 x 18 box: region 1 under the top face 8 mm deep (D 8), region 2 under the +x side 20 mm deep (D = its
  // mouth's narrowest, 18), region 9 on a face the part does not have (not built: not measured).
  const StepModel model = box_model(40, 30, 18);
  Settings st;
  st.regions = {{1, Role::Lattice, {1}, 8.0, 0.0, true}, {2, Role::Lattice, {3}, 20.0, 0.0, true},
                {9, Role::Lattice, {99}, 5.0, 0.0, true}};
  Session s(model);
  // (OG1's gap off, 0 lines: these are the limits before it; OL-OG1 pins what the gap does to them.)
  const std::vector<SweepLimits> each = s.sweep_limits(st, 0.45, 0.0);
  for (const SweepLimits& x : each)
    std::printf("OL-SWEEP-FOR region %d: measured %d, D %.2f, strut %.2f to %.2f, cell %.2f to %.2f\n", x.region,
                x.measured ? 1 : 0, x.d_mm, x.strut_lower_mm, x.strut_upper_mm, x.cell_lower_mm, x.cell_upper_mm);
  const SweepLimitsUnion u = s.sweep_limits_for(st, {1, 2, 9}, 0.45, 0.0);
  std::printf("OL-SWEEP-FOR union of 1, 2, 9: measured %d (%zu measured, %zu not): strut %.2f to %.2f (Auto %.2f), cell "
              "%.2f to %.2f (Auto %.2f)\n", u.measured ? 1 : 0, u.measured_regions.size(), u.unmeasured.size(),
              u.strut_lower_mm, u.strut_upper_mm, u.strut_auto_mm, u.cell_lower_mm, u.cell_upper_mm, u.cell_auto_mm);
  auto near = [](double x, double y) { return std::fabs(x - y) < 1e-9; };
  CHECK(u.measured && u.measured_regions == std::vector<int>({1, 2}) && u.unmeasured == std::vector<int>({9}));
  CHECK(near(u.strut_lower_mm, 0.9) && near(u.strut_upper_mm, 1.8) && near(u.strut_auto_mm, 1.35));
  CHECK(near(u.cell_lower_mm, 1.5) && near(u.cell_upper_mm, 8.0) && near(u.cell_auto_mm, 5.0));
  const SweepLimitsUnion one = s.sweep_limits_for(st, {1}, 0.45, 0.0);
  CHECK(one.measured && near(one.cell_lower_mm, 1.5) && near(one.cell_upper_mm, 3.5) && near(one.strut_upper_mm, 0.9));
  const SweepLimitsUnion none = s.sweep_limits_for(st, {9}, 0.45, 0.0);
  CHECK(!none.measured && none.unmeasured.size() == 1 && none.cell_upper_mm == 0.0 && none.strut_auto_mm == 0.0);
}

// ── OL-GROUPS (OP11, brief C2, E7): Organic settings per group of weave regions ───────────────────────────────────────
static std::uint64_t region_fnv(const Outcome& o, int region) {
  std::uint64_t h = 1469598103934665603ULL;
  for (const Bar& b : o.bars.bars) {
    if (b.region != region) continue;
    const double v[7] = {b.a.x, b.a.y, b.a.z, b.b.x, b.b.y, b.b.z, b.width};
    const unsigned char* c = reinterpret_cast<const unsigned char*>(v);
    for (std::size_t i = 0; i < sizeof v; ++i) { h ^= c[i]; h *= 1099511628211ULL; }
  }
  return h;
}
static void test_groups() {
  // One group holding every weave region: today's one-ask lay, bar for bar (OL-FOLLOW's hashes).
  {
    const StepModel model = box_model(30, 30, 20);
    const TensorField f = traced_field();
    const std::uint64_t today[2] = {0x9a119fd417d400d7ULL, 0x033117e5fef14428ULL};  // G11 amended 2026-11-19 (was 0x235c732cf4f2f269, then 0xe8c60d9cd768769b); OG5 (brief E9): its roots' run-on into the floor
    for (int g = 0; g < 2; ++g) {
      Session s(model);
      const Outcome o = s.lay_organic(traced_settings(), f, std::vector<OrganicGroup>{{{1}, follow_ask(g == 1)}});
      std::printf("OL-GROUPS one group, %s: hash %016llx (today's %016llx), touches %zu\n", g ? "Grown" : "Traced",
                  static_cast<unsigned long long>(bars_fnv(o)), static_cast<unsigned long long>(today[g]),
                  o.cross_group_touches);
      CHECK(bars_fnv(o) == today[g] && o.cross_group_touches == 0 && o.refused.empty());
    }
  }
  // Two groups on a 30 x 30 x 40 box: region 1 under the top face, region 2 under the bottom face, 12 mm deep each (16
  // mm of solid between). Group 0 = {1} Traced, group 1 = {2} Grown, in one lay. Each region's bars are those of a lay
  // of that region alone with its group's ask.
  const StepModel model = box_model(30, 30, 40);
  const TensorField f = traced_field(30, 30, 40);
  Settings both;
  both.regions = {{1, Role::Lattice, {1}, 12.0, 0.0, true}, {2, Role::Lattice, {0}, 12.0, 0.0, true}};
  Settings only1 = both, only2 = both;
  only1.regions = {both.regions[0]};
  only2.regions = {both.regions[1]};
  const OrganicAsk traced = traced_ask(), grown = follow_ask(true);
  const std::vector<OrganicGroup> groups = {{{1}, traced}, {{2}, grown}};
  Session s(model), s1(model), s2(model);
  const Outcome o = s.lay_organic(both, f, groups);
  const Outcome a1 = s1.lay_organic(only1, f, traced);
  const Outcome a2 = s2.lay_organic(only2, f, grown);
  std::size_t n1 = 0, n2 = 0;
  for (const Bar& b : o.bars.bars) { n1 += b.region == 1; n2 += b.region == 2; }
  std::printf("OL-GROUPS two groups (Traced {1}, Grown {2}): %zu bars in 1, %zu in 2 (alone: %zu, %zu); region 1 the "
              "same %d, region 2 the same %d; grown report %d; touches %zu; refusals %zu\n", n1, n2, a1.bars.bars.size(),
              a2.bars.bars.size(), region_fnv(o, 1) == region_fnv(a1, 1) ? 1 : 0,
              region_fnv(o, 2) == region_fnv(a2, 2) ? 1 : 0, o.grown ? 1 : 0, o.cross_group_touches, o.refused.size());
  CHECK(o.refused.empty() && n1 > 0 && n2 > 0 && o.grown != nullptr);
  CHECK(region_fnv(o, 1) == region_fnv(a1, 1) && region_fnv(o, 2) == region_fnv(a2, 2));
  CHECK(o.cross_group_touches == 0);
  // The preview takes the groups: its runs carry both regions.
  {
    Session p(model);
    const OrganicPreview pv = lay_organic_preview(p, both, f, groups, OrganicPreviewAsk{});
    bool r1 = false, r2 = false;
    for (const WeaveRun& r : pv.runs) { r1 = r1 || r.region == 1; r2 = r2 || r.region == 2; }
    CHECK(r1 && r2 && bars_fnv(pv.outcome) == bars_fnv(o));
  }
  // Two touching regions (each 20 mm deep, meeting half way): the pairs of different groups that touch, reported.
  {
    Settings touch = both;
    touch.regions[0].depth_mm = touch.regions[1].depth_mm = 20.0;
    Session t(model);
    const Outcome ot = t.lay_organic(touch, f, groups);
    std::printf("OL-GROUPS two touching regions: %zu bars, cross-group touches %zu\n", ot.bars.bars.size(),
                ot.cross_group_touches);
    CHECK(ot.refused.empty() && !ot.bars.bars.empty());
  }
  // The list's own refusals, and a group's ask refused with its group named.
  {
    auto refusals = [&](const std::vector<OrganicGroup>& gs) { return validate_organic_groups(both, gs, &f); };
    auto has_group = [](const std::vector<OrganicRefusal>& r, const char* code, int group) {
      for (const OrganicRefusal& x : r)
        if (x.code == code && x.group == group) return true;
      return false;
    };
    OrganicAsk bad = grown;
    bad.link_width = 3.0;
    OrganicAsk floor2 = grown;
    floor2.bed_floor_mm = 2.0;
    const auto r1 = refusals({{{1}, traced}});
    const auto r2 = refusals({{{1, 2}, traced}, {{2}, grown}});
    const auto r3 = refusals({{{1, 7}, traced}, {{2}, grown}});
    const auto r4 = refusals({{{1}, traced}, {{2}, bad}});
    const auto r5 = refusals({{{1}, traced}, {{2}, floor2}});
    const auto r6 = refusals({{{1}, traced}, {{2}, grown}, {{}, grown}});
    for (const auto* r : {&r1, &r2, &r3, &r4, &r5, &r6})
      for (const OrganicRefusal& x : *r)
        std::printf("OL-GROUPS refused: group %d, %s %s \"%s\"\n", x.group, x.setting.c_str(), x.code.c_str(), x.text.c_str());
    CHECK(r1.size() == 1 && has_group(r1, "region_without_group", -1));
    CHECK(r2.size() == 1 && has_group(r2, "region_in_two_groups", -1));
    CHECK(r3.size() == 1 && has_group(r3, "not_a_weave_region", 0));
    CHECK(r4.size() == 1 && has_group(r4, "out_of_range", 1) && r4[0].setting == "link_width");
    CHECK(r5.size() == 1 && has_group(r5, "floors_differ", 1));
    CHECK(r6.size() == 1 && has_group(r6, "empty_group", 2));
    Session z(model);
    const Outcome no = z.lay_organic(both, f, std::vector<OrganicGroup>{{{1}, traced}});
    CHECK(no.refused.size() == 1 && no.bars.bars.empty() && z.domain() == nullptr);
  }
}

// ── OL-SYNTH (OP12, brief C2, E5): synthetic stress on walls without stress, and on a body with no solve ──────────────
static void eigen3(const double* m, double ev[3]) {   // a symmetric 3 x 3 in Voigt order, by Jacobi; by |value|, down
  double a[3][3] = {{m[0], m[3], m[5]}, {m[3], m[1], m[4]}, {m[5], m[4], m[2]}};
  for (int sweep = 0; sweep < 30; ++sweep)
    for (int p = 0; p < 2; ++p)
      for (int q = p + 1; q < 3; ++q) {
        if (std::fabs(a[p][q]) < 1e-300) continue;
        const double th = 0.5 * (a[q][q] - a[p][p]) / a[p][q];
        const double t = (th >= 0 ? 1.0 : -1.0) / (std::fabs(th) + std::sqrt(th * th + 1.0));
        const double c = 1.0 / std::sqrt(t * t + 1.0), sn = t * c;
        for (int k = 0; k < 3; ++k) { const double kp = a[k][p], kq = a[k][q]; a[k][p] = c * kp - sn * kq; a[k][q] = sn * kp + c * kq; }
        for (int k = 0; k < 3; ++k) { const double pk = a[p][k], qk = a[q][k]; a[p][k] = c * pk - sn * qk; a[q][k] = sn * pk + c * qk; }
      }
  ev[0] = a[0][0]; ev[1] = a[1][1]; ev[2] = a[2][2];
  std::sort(ev, ev + 3, [](double x, double y) { return std::fabs(x) > std::fabs(y); });
}
static double vm6(const double* t) {
  const double a = t[0] - t[1], b = t[1] - t[2], d = t[2] - t[0];
  return std::sqrt(std::max(0.0, 0.5 * (a * a + b * b + d * d) + 3.0 * (t[3] * t[3] + t[4] * t[4] + t[5] * t[5])));
}
static void test_synthetic() {
  // A 30 x 30 x 40 box: region 1 under the top face (loaded: OL-Q's field above z 20), region 2 under the bottom face
  // (no stress at all), 12 mm deep each. Both flagged with the default count: only region 2 is filled.
  const StepModel model = box_model(30, 30, 40);
  const TensorField in = make_field(30, 30, 40, [](const Vec3& p) {
    return p.z > 20.0 ? std::array<double, 6>{0.4 + 0.02 * p.x, 0.1, 1.0 + 0.1 * p.x, 0.0, 0.0, 0.0} : std::array<double, 6>{};
  });
  Settings st;
  st.regions = {{1, Role::Lattice, {1}, 12.0, 0.0, true}, {2, Role::Lattice, {0}, 12.0, 0.0, true}};
  OrganicAsk ask = traced_ask();
  const std::vector<OrganicGroup> one = {{{1, 2}, ask}};
  Session s(model);
  const SyntheticStress out = organic_synthetic_stress(s, st, in, {{1}, {2}}, one);
  CHECK(out.refused.empty() && out.regions.size() == 2);
  if (out.regions.size() != 2) return;
  const SyntheticRegionReport& r1 = out.regions[0];
  const SyntheticRegionReport& r2 = out.regions[1];
  for (const SyntheticRegionReport& r : out.regions)
    std::printf("OL-SYNTH region %d: flagged %d, without stress %d (p99 %.4f, threshold %.4f), foci %d, voxels %zu, filled "
                "%zu, reference %.4f, factor %.4g, peak %.4f\n", r.region, r.flagged, r.without_stress, r.p99_mpa,
                r.threshold_mpa, r.foci, r.voxels, r.filled, r.reference_mpa, r.factor, r.peak_after_mpa);
  CHECK(!r1.without_stress && r1.filled == 0 && r2.without_stress && r2.filled > 0 && r2.foci == kSyntheticFociDefault);
  // The reference the lay would use: the 95th percentile of region 1's real von Mises (the group's stressed regions).
  const Domain::Probe probe = s.domain()->probe();
  std::vector<double> seen;
  std::size_t in2 = 0, distinct = 0, ties = 0, changed1 = 0;
  double peak2 = 0.0;
  for (int k = 0; k < in.nz; ++k)
    for (int j = 0; j < in.ny; ++j)
      for (int i = 0; i < in.nx; ++i) {
        const Where w = probe.where({i + 0.5, j + 0.5, k + 0.5});
        if (!w.lattice()) continue;
        const std::size_t e = in.index(i, j, k);
        const double* t = &out.field.voigt[6 * e];
        if (w.id == 1) {
          seen.push_back(vm6(&in.voigt[6 * e]));
          for (int c = 0; c < 6; ++c) changed1 += t[c] != in.voigt[6 * e + static_cast<std::size_t>(c)];
        } else if (w.id == 2) {
          ++in2;
          peak2 = std::max(peak2, vm6(t));
          double ev[3];
          eigen3(t, ev);
          const double big = std::fabs(ev[0]);
          distinct += big > 0.0 && std::fabs(ev[0] - ev[1]) > 1e-3 * big && std::fabs(ev[1] - ev[2]) > 1e-3 * big &&
                      std::fabs(ev[0] - ev[2]) > 1e-3 * big;
          ties += big > 0.0 && std::fabs(ev[1]) / big >= 0.10;
        }
      }
  std::sort(seen.begin(), seen.end());
  const double ref = seen.empty() ? 0.0 : seen[static_cast<std::size_t>(std::floor(0.95 * static_cast<double>(seen.size() - 1)))];
  std::printf("OL-SYNTH region 2: %zu voxels, three distinct %zu, minor / major at least 0.10 %zu; peak %.6f, the "
              "reference %.6f; region 1 values changed %zu\n", in2, distinct, ties, peak2, ref, changed1);
  CHECK(in2 > 0 && distinct >= 0.95 * in2 && ties >= 0.95 * in2);
  CHECK(std::fabs(peak2 - ref) < 1e-9 * std::max(1.0, ref) && std::fabs(r2.reference_mpa - ref) < 1e-12 && changed1 == 0);
  // Refused: a count of 0 or 6, a region that is not a weave region.
  {
    const SyntheticStress bad = organic_synthetic_stress(s, st, in, {{2, 0}, {2, 6}, {9, 3}}, one);
    for (const OrganicRefusal& x : bad.refused) std::printf("OL-SYNTH refused: %s %s \"%s\"\n", x.setting.c_str(), x.code.c_str(), x.text.c_str());
    CHECK(bad.refused.size() == 3 && bad.field.empty() && bad.regions.empty());
  }
  // No input, one focus, a 30 mm cube latticed whole: Traced lays curves, Grown lays vines AND ties; the spacing varies.
  const StepModel cube = box_model(30, 30, 30);
  Settings cs;
  cs.regions = {{1, Role::Lattice, {1}, 30.0, 0.0, true}};
  for (int g = 0; g < 2; ++g) {
    OrganicAsk a = traced_ask();
    if (g) { a.mode = OrganicMode::Grown; a.layer_mm = 0.2; }
    const std::vector<OrganicGroup> gs = {{{1}, a}};
    Session c(cube);
    const SyntheticStress made = organic_synthetic_stress(c, cs, TensorField{}, {{1, 1}}, gs);
    const Outcome o = made.refused.empty() ? c.lay_organic(cs, made.field, gs) : Outcome{};
    const std::size_t ties_laid = o.grown ? o.grown->ties_laid : 0;
    std::printf("OL-SYNTH cube, no input, 1 focus, %s: grid %d x %d x %d at %.2f mm, filled %zu; %zu strands, %zu bars, "
                "ties %zu; spacing %.2f to %.2f mm\n", g ? "Grown" : "Traced", made.field.nx, made.field.ny,
                made.field.nz, made.field.spacing, made.regions.empty() ? 0 : made.regions[0].filled, o.strands,
                o.bars.bars.size(), ties_laid, o.spacing_smallest_mm, o.spacing_largest_mm);
    CHECK(made.from_empty && made.field.spacing == 1.0 && !made.regions.empty() && made.regions[0].foci == 1 &&
          std::fabs(made.regions[0].peak_after_mpa - 1.0) < 1e-12);
    CHECK(o.refused.empty() && o.strands > 0 && !o.bars.bars.empty() && o.spacing_largest_mm - o.spacing_smallest_mm > 0.5);
    if (g) CHECK(ties_laid > 0);
  }
  CHECK(kSyntheticFociDefault == 3);
}

// ── OL-BODY (brief C2, E8): the bare sample bodies, and a WHOLE body laid as weave (one box-zone region) ──────────────
static bool closed_outward(const TriangleMesh& m, double* volume) {
  std::map<std::pair<int, int>, int> edges;   // directed edge -> count
  double v = 0.0;
  for (const auto& t : m.triangles) {
    for (int k = 0; k < 3; ++k) ++edges[{t[static_cast<std::size_t>(k)], t[static_cast<std::size_t>((k + 1) % 3)]}];
    const Vec3 &a = m.vertices[static_cast<std::size_t>(t[0])], &b = m.vertices[static_cast<std::size_t>(t[1])],
               &c = m.vertices[static_cast<std::size_t>(t[2])];
    v += (a.x * (b.y * c.z - b.z * c.y) - a.y * (b.x * c.z - b.z * c.x) + a.z * (b.x * c.y - b.y * c.x)) / 6.0;
  }
  bool ok = !edges.empty();
  for (const auto& e : edges) ok = ok && e.second == 1 && edges.count({e.first.second, e.first.first}) == 1;
  if (volume) *volume = v;
  return ok;
}
static void box_of(const TriangleMesh& m, Vec3& lo, Vec3& hi) {
  lo = {1e300, 1e300, 1e300};
  hi = {-1e300, -1e300, -1e300};
  for (const Vec3& p : m.vertices) {
    lo = {std::min(lo.x, p.x), std::min(lo.y, p.y), std::min(lo.z, p.z)};
    hi = {std::max(hi.x, p.x), std::max(hi.y, p.y), std::max(hi.z, p.z)};
  }
}
// The whole body as ONE weave region: a box zone round the body's box, 1 mm margin (no face ids needed).
static Settings whole_body_weave(const TriangleMesh& body) {
  Vec3 lo, hi;
  box_of(body, lo, hi);
  Settings s;
  Settings::RegionAsk r;
  r.id = 1;
  r.role = Role::Lattice;
  r.weave = true;
  r.zone.kind = Zone::Kind::Box;
  r.zone.centre = {0.5 * (lo.x + hi.x), 0.5 * (lo.y + hi.y), 0.5 * (lo.z + hi.z)};
  r.zone.axis[0] = {1, 0, 0};
  r.zone.axis[1] = {0, 1, 0};
  r.zone.axis[2] = {0, 0, 1};
  r.zone.half[0] = 0.5 * (hi.x - lo.x) + 1.0;
  r.zone.half[1] = 0.5 * (hi.y - lo.y) + 1.0;
  r.zone.half[2] = 0.5 * (hi.z - lo.z) + 1.0;
  s.regions = {r};
  return s;
}
static StepModel one_face_model(const TriangleMesh& mesh) {   // the body as a model with one face (no face is read)
  StepModel m;
  m.mesh = mesh;
  m.triangle_face.assign(mesh.triangles.size(), 0);
  m.faces.resize(1);
  m.face_count = 1;
  m.solid_count = 1;
  return m;
}
static void test_sample_bodies() {
  for (const char* kind : {"cube", "coupon"}) {
    LatticeSampleSpec spec;
    spec.shape = kind;
    spec.topology = "octet";
    const TriangleMesh body = lattice_sample_body(spec);
    double vol = 0.0;
    const bool closed = closed_outward(body, &vol);
    Vec3 lo, hi, slo, shi;
    box_of(body, lo, hi);
    LatticeSampleReceipt rec;
    const TriangleMesh sample = lattice_sample_mesh(spec, &rec);
    box_of(sample, slo, shi);
    if (std::string(kind) == "cube") {   // its struts' round ends stand proud of the cube: the box as stated
      slo = {0.0, 0.0, 0.0};
      shi = {rec.size_mm, rec.size_mm, rec.plate_mm + rec.size_mm};
    }
    const double off = std::max({std::fabs(lo.x - slo.x), std::fabs(lo.y - slo.y), std::fabs(lo.z - slo.z),
                                 std::fabs(hi.x - shi.x), std::fabs(hi.y - shi.y), std::fabs(hi.z - shi.z)});
    std::printf("OL-BODY %s: %zu triangles, closed and outward %d, volume %.1f mm3, box %.2f x %.2f x %.2f (the "
                "sample's %.2f x %.2f x %.2f, apart %.4f mm)\n", kind, body.triangles.size(), closed ? 1 : 0, vol,
                hi.x - lo.x, hi.y - lo.y, hi.z - lo.z, shi.x - slo.x, shi.y - slo.y, shi.z - slo.z, off);
    CHECK(closed && vol > 0.0 && off < 0.05);
    // The whole body laid as weave from no stress input, one focus: Traced curves, Grown vines and ties.
    const Settings st = whole_body_weave(body);
    for (int g = 0; g < 2; ++g) {
      OrganicAsk a = traced_ask();
      if (g) { a.mode = OrganicMode::Grown; a.layer_mm = 0.2; }
      const std::vector<OrganicGroup> gs = {{{1}, a}};
      Session s(one_face_model(body));
      const SyntheticStress made = organic_synthetic_stress(s, st, TensorField{}, {{1, 1}}, gs);
      const Outcome o = made.refused.empty() ? s.lay_organic(st, made.field, gs) : Outcome{};
      const std::size_t ties = o.grown ? o.grown->ties_laid : 0;
      std::printf("OL-BODY %s whole-body weave, %s: filled %zu voxels, %zu strands, %zu bars, ties %zu, spacing %.2f to "
                  "%.2f, empty regions %zu\n", kind, g ? "Grown" : "Traced", made.regions.empty() ? 0 : made.regions[0].filled,
                  o.strands, o.bars.bars.size(), ties, o.spacing_smallest_mm, o.spacing_largest_mm, o.empty_regions.size());
      CHECK(made.refused.empty() && !made.regions.empty() && made.regions[0].filled > 0);
      CHECK(o.refused.empty() && o.empty_regions.empty() && o.strands > 0 && !o.bars.bars.empty());
      if (g) CHECK(ties > 0);
    }
  }
  bool threw = false;
  try { LatticeSampleSpec bad; bad.shape = "sphere"; (void)lattice_sample_body(bad); } catch (const std::invalid_argument&) { threw = true; }
  CHECK(threw);
}

// ── OL-G11 (G11 amended, the lead 2026-11-19): the re-seed's bare places and first steps are hashed, no repeating pattern ──
// The sample bodies (cube, coupon) laid Grown with the app's sample ask at Look 50 (362's probe's ask). Each stride cell's bare place is the candidate nearest
// a point placed in the cell by the hash (seed, region, cell), and a walked stub's first step is picked by the same hash
// among the descending neighbours within 20 % of the steepest. Kept: every bare place within 1.5 spacings is still filled,
// so the bare share after the re-seed is no worse than before the amendment, within 5 % (before: the pins below, read
// from the tip 2847ca91). The pattern gone: no more than 10 % of the stubs' nearest-neighbour distances within 5 % of the
// stride or of a whole multiple of it, and no more than 10 % of the stubs share a shape (a stub from a kept vertex: its
// vector to 0.5 mm; a walked stub: its first three voxel steps) with another.
static void test_g11_reseed_pattern() {
  struct Pin { const char* kind; double bare_after; std::size_t on_grid, shared; };
  const Pin before[2] = {{"cube", 0.0165, 36, 37}, {"coupon", 0.0241, 21, 17}};
  for (const Pin& pin : before) {
    LatticeSampleSpec spec;
    spec.shape = pin.kind;
    spec.topology = "octet";
    const TriangleMesh body = lattice_sample_body(spec);
    Settings st = whole_body_weave(body);
    st.bead_mm = 0.45;
    st.min_strut_lines = 2;
    Session s(one_face_model(body));
    // The app's sample ask at Look 50 (362's OrganicVineRunsProbe: the engine's limits, Auto Sweep, vine spacing off)
    const SweepLimitsUnion L = s.sweep_limits_for(st, {1}, 0.45);
    const auto half = [](double v) { return std::round(v * 2.0) / 2.0; };
    const double cl = std::max(half(L.cell_lower_mm), std::ceil(2.0 * 0.5 * std::sqrt(3.0 * M_PI) * L.strut_lower_mm) / 2.0);
    const double cu = std::max(cl, half(L.cell_upper_mm));
    OrganicAsk a;
    a.mode = OrganicMode::Grown;
    a.follow_stress = true;
    a.spacing_min_mm = cl;
    a.spacing_max_mm = cu;
    a.width_mm = L.strut_lower_mm;
    a.width_heavy_mm = L.strut_upper_mm;
    a.walls_out = true;
    a.wall_gap = 2.5;
    a.wall_gap_heavy = 1.0;
    a.wall_cross = 1;
    a.cross_gap = 2.5;
    a.cross_gap_heavy = 1.0;
    a.tie_level = true;
    a.ties = true;
    a.tie_gap = 1.0;
    a.tie_gap_heavy = 0.5;
    a.foot_gap = 2.5;
    a.root_run = 0;
    a.top_run = 0;
    a.run_max = 1;
    a.stress_goal = true;
    a.prune = true;
    a.shape_fit = true;
    a.shape_reach = 1;
    a.member_cap = false;
    a.hold_parts = true;
    a.part_to_floor = true;
    a.part_reach_mm = 1.5 * cu;
    a.part_support_mm = 0.75 * cl;
    a.link_width = 1;
    a.unbraced_max = 10;
    a.bed_floor_mm = 0.8;
    a.layer_mm = 0.2;
    a.percentile = 0.95;
    a.strand_keep = 0.5;
    const std::vector<OrganicGroup> gs = {{{1}, a}};
    const SyntheticStress made = organic_synthetic_stress(s, st, TensorField{}, {{1, 1}}, gs);
    CHECK(made.refused.empty());
    const Outcome o = s.lay_organic(st, made.field, gs);
    CHECK(o.refused.empty() && o.grown);
    if (!o.grown) continue;
    const GrowReport& g = *o.grown;
    const double hv = made.field.spacing;
    std::vector<double> spf;
    {
      const OrganicSpacing sp = organic_spacing(*s.domain(), 1, made.field, a);
      for (std::size_t e = 0; e < sp.candidate.size(); ++e)
        if (sp.candidate[e]) spf.push_back(sp.spacing_mm[e]);
    }
    std::sort(spf.begin(), spf.end());
    const double S = std::max(1, static_cast<int>(0.5 * (spf.empty() ? 0.0 : spf[spf.size() / 2]) / hv)) * hv;
    std::size_t on_grid = 0;
    for (std::size_t i = 0; i < g.stubs.size(); ++i) {
      double b = 1e300;
      for (std::size_t j = 0; j < g.stubs.size(); ++j)
        if (j != i) b = std::min(b, dist(g.stubs[i].top, g.stubs[j].top));
      const double m = std::round(b / S);
      on_grid += m >= 1 && std::fabs(b - m * S) <= 0.05 * S;
    }
    std::map<std::string, int> shapes;
    for (const GrowReport::Stub& u : g.stubs) {
      char buf[128];
      if (u.from_vertex || u.pts.size() < 4) {
        std::snprintf(buf, sizeof buf, "v%ld,%ld,%ld", std::lround(2 * (u.top.x - u.root.x)),
                      std::lround(2 * (u.top.y - u.root.y)), std::lround(2 * (u.top.z - u.root.z)));
      } else {
        const std::size_t n = u.pts.size();
        long q[9];
        for (int k = 0; k < 3; ++k) {
          const Vec3& p = u.pts[n - 1 - k];
          const Vec3& r = u.pts[n - 2 - k];
          q[3 * k] = std::lround((r.x - p.x) / hv);
          q[3 * k + 1] = std::lround((r.y - p.y) / hv);
          q[3 * k + 2] = std::lround((r.z - p.z) / hv);
        }
        std::snprintf(buf, sizeof buf, "w%ld,%ld,%ld;%ld,%ld,%ld;%ld,%ld,%ld", q[0], q[1], q[2], q[3], q[4], q[5], q[6],
                      q[7], q[8]);
      }
      ++shapes[buf];
    }
    std::size_t shared = 0;
    for (const auto& kv : shapes)
      if (kv.second > 1) shared += static_cast<std::size_t>(kv.second);
    const std::size_t n = g.stubs.size();
    std::printf("OL-G11 %s: stubs %zu (voids %zu, landed %zu, failed %zu); stride %.2f mm; nearest-neighbour distances on "
                "the stride grid %zu (before %zu); stubs sharing a shape %zu, %zu distinct (before %zu sharing); bare "
                "%.4f before re-seeding, %.4f after (before the amendment %.4f)\n",
                pin.kind, n, g.reseed_voids, g.reseed_landed, g.reseed_failed, S, on_grid, pin.on_grid, shared,
                shapes.size(), pin.shared, g.bare_before, g.bare_after, pin.bare_after);
    CHECK(n > 0);
    CHECK(10 * on_grid <= n);
    CHECK(10 * shared <= n);
    CHECK(g.bare_after <= 1.05 * pin.bare_after + 1e-12);
  }
}

// ── OL-OG1, OL-OG2 (brief E6): the gap between struts, and strut ends standing proud of an open face ───────────────────
// The made parts: the 30 x 30 x 20 box, a field whose stress grows along x and y, the weave under one face.
static TensorField gap_field() {
  TensorField t;
  t.nx = 30; t.ny = 30; t.nz = 20;
  t.spacing = 1.0;
  t.voigt.assign(6 * static_cast<std::size_t>(t.nx) * t.ny * t.nz, 0.0);
  for (int k = 0; k < t.nz; ++k)
    for (int j = 0; j < t.ny; ++j)
      for (int i = 0; i < t.nx; ++i) {
        const double x = i + 0.5, y = j + 0.5;
        const double v[6] = {0.4 + 0.02 * x + 0.03 * y, 0.1, 1.0 + 0.1 * x, 0.05 * y / t.ny, 0.0, 0.0};
        for (int c = 0; c < 6; ++c) t.voigt[6 * t.index(i, j, k) + static_cast<std::size_t>(c)] = v[c];
      }
  return t;
}
static OrganicAsk gap_ask(double heavy) {
  OrganicAsk a;
  a.spacing_min_mm = 2.0;
  a.spacing_max_mm = 6.0;
  a.width_mm = 0.9;
  a.width_heavy_mm = heavy;
  return a;
}
static OrganicAsk gap_judged(bool grown) {   // the Auto ask as judged (judged_ask's numbers)
  OrganicAsk a = judged_ask(grown);
  a.ties = true;
  a.tie_level = true;
  return a;
}
static Settings gap_settings(int face, double depth, bool drop) {
  Settings s;
  s.regions = {{1, Role::Lattice, {face}, depth, 0.0, true}};
  s.drop_loose = drop;
  return s;
}
static void test_og1_gap() {
  const StepModel model = box_model(30, 30, 20);
  const TensorField f = gap_field();
  // 1. Off: the lays are the old engine's, bar for bar (bars_hash on the made parts, the values the engine at 844157dd
  //    gives, before OG1 and OG2 existed), and the tubes file of one of them likewise.
  {
    struct Pin { int face; double depth; bool drop; OrganicAsk ask; std::uint64_t hash; };
    OrganicAsk grown = judged_ask(true);
    grown.ties = true;
    const Pin pins[] = {{1, 16.0, true, gap_ask(1.8), 0x5329efc15073f757ULL},
                        {1, 16.0, false, gap_ask(1.8), 0xd535900d484c8045ULL},
                        {2, 12.0, false, gap_ask(1.6), 0x1ef42835dc6f6173ULL},   // OG5 (brief E9): bars cut to the part
                        {1, 16.0, true, gap_ask(0.0), 0x60471813348d58e7ULL}};
    std::size_t same = 0, n = 0;
    for (const Pin& p : pins) {
      OrganicAsk a = p.ask;
      a.gap_lines = 0.0;
      a.face_relief_mm = 0.0;
      a.strand_keep = 0.5;   // OG3 at the tracer's old constant
      Session session(model);
      const Outcome o = session.lay_organic(gap_settings(p.face, p.depth, p.drop), f, a);
      ++n;
      same += bars_hash(o.bars) == p.hash && o.gap_capped == 0 && o.relief.proud == 0;
      if (bars_hash(o.bars) != p.hash) std::printf("  OL-OG1 off: hash %016llx, the old engine's %016llx\n",
                                                   static_cast<unsigned long long>(bars_hash(o.bars)),
                                                   static_cast<unsigned long long>(p.hash));
    }
    std::printf("OL-OG1 off: %zu of %zu made lays bar for bar the old engine's\n", same, n);
    CHECK(same == n);
  }
  // 2. On (the default, 1.5 lines): no strand point wider than (its local spacing - the gap), never under the thinnest
  //    strut, never wider than it was with the rule off; Traced and Grown.
  for (int g = 0; g < 2; ++g) {
    const bool grown = g == 1;
    DomainSpec ds;
    ds.bead_mm = 0.45;
    ds.min_strut_lines = 2.0;
    bool ok = false;
    ds.regions = {region_from_faces(model, {1}, 1, Role::Lattice, 16.0, 0.0, &ok)};
    ds.regions[0].weave = true;
    const PartMeasure pm(weld_mesh(model.mesh));
    const Domain d(pm, ds);
    OrganicAsk on = grown ? gap_judged(true) : gap_ask(1.8);
    on.hold_parts = false;
    OrganicAsk off = on;
    off.gap_lines = 0.0;
    CHECK(on.gap_lines == kOrganicGapLinesDefault);
    GrowReport r1, r2;
    OrganicTraceStats t1, t2;
    const std::vector<Strand> a = grown ? grow_strands(d, 1, f, off, &r1) : trace_strands(d, 1, f, off, &t1);
    const std::vector<Strand> b = grown ? grow_strands(d, 1, f, on, &r2) : trace_strands(d, 1, f, on, &t2);
    const double gap = 1.5 * 0.45, thinnest = 0.9;
    std::size_t points = 0, over = 0, wider = 0, under = 0, lowered = 0, moved = 0;
    double worst = -1e9;
    CHECK(a.size() == b.size());
    for (std::size_t i = 0; i < std::min(a.size(), b.size()); ++i) {
      CHECK(b[i].cap_mm.size() == b[i].points.size() && b[i].local_mm.size() == b[i].points.size() && a[i].cap_mm.empty());
      for (std::size_t q = 0; q < std::min(b[i].points.size(), b[i].local_mm.size()); ++q) {
        ++points;
        const double w = b[i].width_mm[q], allowed = std::max(thinnest, b[i].local_mm[q] - gap);
        worst = std::max(worst, w - allowed);
        over += w > allowed + 1e-12;
        wider += q < a[i].width_mm.size() && w > a[i].width_mm[q] + 1e-12;
        under += w < thinnest - 1e-12;
        lowered += q < a[i].width_mm.size() && w < a[i].width_mm[q] - 1e-12;
        moved += q < a[i].points.size() && dist(a[i].points[q], b[i].points[q]) > 0.0;
      }
    }
    const std::size_t said = grown ? r2.gap_capped : t2.gap_capped;
    std::printf("OL-OG1 %s on: %zu points, %zu over (local spacing - gap) (worst %.2e mm), %zu wider than off, %zu under the "
                "thinnest, %zu lowered (said %zu), %zu points moved\n",
                grown ? "Grown" : "Traced", points, over, worst, wider, under, lowered, said, moved);
    CHECK(ok && points > 0 && over == 0 && wider == 0 && under == 0 && lowered > 0 && lowered == said && moved == 0);
  }
  // 3. The two judged Auto asks are still valid with the gap on (the default); the refusal: a small end under the light
  //    width + the gap names the smallest allowed cell; off, the same cell is allowed.
  {
    const Settings st = traced_settings();
    for (int g = 0; g < 2; ++g) {
      const std::vector<OrganicRefusal> r = validate_organic(st, judged_ask(g == 1), nullptr);
      std::printf("OL-OG1 judged Auto ask, %s, gap on: %zu refusals\n", g ? "Grown" : "Traced", r.size());
      CHECK(r.empty());
    }
    OrganicAsk a = gap_ask(1.8);
    a.spacing_min_mm = 1.5;   // over the print floor (1.38 at 0.9) and under 0.9 + 0.675 = 1.575
    const std::vector<OrganicRefusal> r = validate_organic(st, a, nullptr);
    std::printf("OL-OG1 refusal: %s\n", r.empty() ? "(none)" : r.front().text.c_str());
    CHECK(r.size() == 1 && has_refusal(r, "spacing_min_mm", "under_gap_cell") && r.front().has_min &&
          std::fabs(r.front().allowed_min - 1.575) < 1e-9 && r.front().text.find("1.58 mm") != std::string::npos);
    a.gap_lines = 0.0;
    CHECK(validate_organic(st, a, nullptr).empty());
    a.gap_lines = 1.5;
    a.spacing_mm = 1.2;   // under both: one refusal, the larger floor's
    const std::vector<OrganicRefusal> r2 = validate_organic(st, a, nullptr);
    CHECK(r2.size() == 1 && has_refusal(r2, "spacing_mm", "under_gap_cell"));
    a.spacing_mm = 0.0;
    a.spacing_min_mm = 2.0;
    for (double bad : {-0.5, 4.5}) {
      a.gap_lines = bad;
      CHECK(has_refusal(validate_organic(st, a, nullptr), "gap_lines", "out_of_range"));
    }
    a.gap_lines = 4.0;   // 0.9 + 1.8 = 2.7 > 2: refused
    CHECK(has_refusal(validate_organic(st, a, nullptr), "spacing_min_mm", "under_gap_cell"));
    // The session refuses the same ask before laying.
    Session session(model);
    const Outcome o = session.lay_organic(st, f, a);
    CHECK(!o.refused.empty() && o.bars.bars.empty());
  }
  // 4. The Auto Sweep limits: the cell's lower end is at least the thin strut + the gap (up to 0.5 mm), said so; off,
  //    the old numbers. A shallow region (D 5): 0.9 + 0.675 = 1.575 -> 2.0, over the old 1.5. The Auto and the Auto Sweep
  //    asks made of them are valid.
  {
    const StepModel m5 = box_model(40, 30, 5);
    const PartMeasure pm(weld_mesh(m5.mesh));
    DomainSpec ds;
    ds.bead_mm = 0.45;
    ds.min_strut_lines = 2.0;
    bool ok = false;
    ds.regions = {region_from_faces(m5, {1}, 1, Role::Lattice, 5.0, 0.0, &ok)};
    ds.regions[0].weave = true;
    const Domain d(pm, ds);
    const std::vector<SweepLimits> on = organic_sweep_limits(d, 0.45), off = organic_sweep_limits(d, 0.45, 0.0);
    CHECK(ok && on.size() == 1 && off.size() == 1);
    if (on.size() == 1 && off.size() == 1) {
      const SweepLimits &x = on[0], &y = off[0];
      std::printf("OL-OG1 sweep limits, D %.2f: gap on cell %.2f to %.2f (Auto %.2f), raised %d, gap %.3f; off cell %.2f to "
                  "%.2f (Auto %.2f); strut %.2f to %.2f\n",
                  x.d_mm, x.cell_lower_mm, x.cell_upper_mm, x.cell_auto_mm, x.cell_lower_by_gap ? 1 : 0, x.gap_mm,
                  y.cell_lower_mm, y.cell_upper_mm, y.cell_auto_mm, x.strut_lower_mm, x.strut_upper_mm);
      CHECK(x.cell_lower_by_gap && std::fabs(x.cell_lower_mm - 2.0) < 1e-9 && x.cell_lower_mm >= x.strut_lower_mm + x.gap_mm &&
            std::fabs(y.cell_lower_mm - 1.5) < 1e-9 && !y.cell_lower_by_gap && y.gap_mm == 0.0 && x.cell_upper_mm >= x.cell_lower_mm);
      Settings st;
      st.regions = {{1, Role::Lattice, {1}, 5.0, 0.0, true}};
      OrganicAsk a1;   // Auto: one number each
      a1.spacing_mm = x.cell_auto_mm;
      a1.width_mm = x.strut_auto_mm;
      OrganicAsk a2;   // Auto Sweep: the ranges
      a2.spacing_min_mm = x.cell_lower_mm;
      a2.spacing_max_mm = x.cell_upper_mm;
      a2.width_mm = x.strut_lower_mm;
      a2.width_heavy_mm = x.strut_upper_mm;
      CHECK(validate_organic(st, a1, nullptr).empty() && validate_organic(st, a2, nullptr).empty());
      // The old limits with the gap on would be refused (that is what the rule changes).
      a2.spacing_min_mm = y.cell_lower_mm;
      CHECK(has_refusal(validate_organic(st, a2, nullptr), "spacing_min_mm", "under_gap_cell"));
    }
    // The session's union says it too.
    Session session(m5);
    Settings st;
    st.regions = {{1, Role::Lattice, {1}, 5.0, 0.0, true}};
    const SweepLimitsUnion u = session.sweep_limits_for(st, {1}, 0.45);
    CHECK(u.measured && u.cell_lower_by_gap && u.gap_mm > 0.0 && u.cell_lower_mm >= u.strut_lower_mm + u.gap_mm);
  }
  // 5. The strength loop may go over the cap; it is counted (gap_broken), never silent: the width floors at 1.8 mm over
  //    the whole block widen bars past their cap, and Outcome::gap_broken counts exactly those.
  {
    OrganicAsk a = gap_ask(1.8);
    Session s1(model);
    const Outcome plain = s1.lay_organic(gap_settings(1, 16.0, true), f, a);
    a.floors = {{Vec3{15, 15, 10}, 100.0, 1.8}};
    Session s2(model);
    const Outcome widened = s2.lay_organic(gap_settings(1, 16.0, true), f, a);
    std::size_t over = 0;
    for (const Bar& b : widened.bars.bars) over += b.gap_cap_mm > 0.0 && b.width > b.gap_cap_mm + 1e-9;
    std::printf("OL-OG1 gap broken: laid %zu (capped points %zu); after floors of 1.8 mm %zu bars widened, %zu over their cap, "
                "said %zu\n",
                plain.gap_broken, plain.gap_capped, widened.floors_widened, over, widened.gap_broken);
    CHECK(plain.gap_broken == 0 && plain.gap_capped > 0 && widened.floors_widened > 0 && over > 0 &&
          widened.gap_broken == over && gap_broken(widened.bars) == over);
    // An additive widening (kind 2) of one capped bar over its cap counts it.
    Bars b = plain.bars;
    std::size_t at = b.bars.size();
    for (std::size_t i = 0; i < b.bars.size() && at == b.bars.size(); ++i)
      if (b.bars[i].gap_cap_mm > 0.0 && !b.bars[i].link) at = i;
    CHECK(at < b.bars.size());
    if (at < b.bars.size()) {
      const Bar& x = b.bars[at];
      AddRound round;
      round.ops.push_back({2, {x.a.x, x.a.y, x.a.z, x.b.x, x.b.y, x.b.z, x.gap_cap_mm + 0.3}});
      AddContext c;
      c.light_mm = 0.9;
      std::string why;
      CHECK(apply_add_round(b, *s1.domain(), round, c, nullptr, &why) && gap_broken(b) == 1);
    }
  }
  // 6. The diagnosis, `tight`: (local spacing - width) under one line width, by what set the spacing; its parts add up.
  //    On the judged Traced ask the gap rule leaves fewer tight bars than off.
  {
    OrganicAsk on = gap_judged(false), off = on;
    off.gap_lines = 0.0;
    off.face_relief_mm = on.face_relief_mm = 0.0;
    Session s1(model), s2(model);
    const Outcome a = s1.lay_organic(traced_settings(), f, off), b = s2.lay_organic(traced_settings(), f, on);
    auto sum = [](const Outcome::Tight& t) { return t.stress + t.shape + t.hold + t.floor + t.uniform + t.unknown; };
    auto show = [](const char* w, const Outcome::Tight& t) {
      std::printf("OL-OG1 tight, %s: %zu of %zu weave bars (stress %zu, shape %zu, floating parts %zu, tracer floor %zu, "
                  "uniform %zu, not known %zu; supports %zu, links %zu, braces %zu)\n",
                  w, t.tight, t.bars, t.stress, t.shape, t.hold, t.floor, t.uniform, t.unknown, t.supports, t.links, t.braces);
    };
    show("gap off", a.tight);
    show("gap on", b.tight);
    std::size_t direct = 0;
    for (const Bar& x : a.bars.bars)
      direct += !x.net && x.region == 1 && (x.local_mm > 0.0 ? x.local_mm : x.cell) - x.width < 0.45;
    CHECK(a.tight.bars > 0 && a.tight.tight > 0 && sum(a.tight) == a.tight.tight && sum(b.tight) == b.tight.tight &&
          direct == a.tight.tight && b.tight.tight < a.tight.tight && a.tight.line_mm == 0.45);
  }
}

// OL-OG2: ends proud of the open faces. One made box, four lays: the weave under the top face, under a side face, under
// the bottom face (its normal points straight down), and under the top face with that face excluded. Drop loose off, so
// the Surface ends stay (with it on, Traced keeps none: drop_loose_bars takes every Surface end it did not see arrive).
static const std::uint64_t kDefaultLayHash = 0xc95c22baf294709aULL;   // OG2: the default lay at the tip e3640d24
static void test_og2_relief() {
  const StepModel model = box_model(30, 30, 20);
  const TensorField f = gap_field();
  struct Case { const char* name; int face; double depth; std::vector<int> exclude; };
  const Case cases[] = {{"top", 1, 16.0, {}}, {"side", 2, 12.0, {}}, {"bottom", 0, 12.0, {}}, {"top, excluded", 1, 16.0, {1}}};
  // Every case at 0.8 mm and at the ceiling, 1 mm (the owner, 2026-11-19: on/off, "limits to 1mm"; 5 mm withdrawn).
  for (const double relief : {0.8, kOrganicReliefMaxMm})
  for (const Case& c : cases) {
    OrganicAsk a = gap_ask(1.6);
    a.face_relief_mm = relief;
    a.relief_exclude_faces = c.exclude;
    const Settings st = gap_settings(c.face, c.depth, false);
    Session session(model);
    const Outcome o = session.lay_organic(st, f, a);
    OrganicAsk flat = a;
    flat.face_relief_mm = 0.0;
    Session plain(model);
    const Outcome p = plain.lay_organic(st, f, flat);
    const Outcome::Relief& r = o.relief;
    const PartMeasure::Probe pr = session.measure().probe();
    // Every proud end: on a face allowed, above the bed, at most the setting beyond the surface (measured from the part),
    // its bar the flush bar carried on along its own line; nothing below the bed.
    std::size_t proud = 0, bad = 0, low = 0, off_line = 0;
    double most = 0.0, most_out = 0.0;
    for (std::size_t i = 0; i < o.bars.bars.size(); ++i) {
      const Bar& x = o.bars.bars[i];
      for (int e = 0; e < 2; ++e) {
        const double pm = e == 0 ? x.proud_a : x.proud_b;
        const Vec3& end = e == 0 ? x.a : x.b;
        if (!(pm > 0.0)) continue;
        ++proud;
        if (end.z - 0.5 * x.width < -1e-9) ++low;   // the proud tip with its round cap: never below the bed
        // Never on an excluded face: the end carried back lies on no face of the list (top z 20, bottom z 0).
        const Bar flushed = without_relief(Bars{{x}}).bars.front();
        const double zb = e == 0 ? flushed.a.z : flushed.b.z;
        const Vec3 bk = e == 0 ? flushed.a : flushed.b;   // the end carried back onto the surface
        const bool edge = std::min({bk.x, 30.0 - bk.x, bk.y, 30.0 - bk.y}) < 1e-3;   // on a side face too: read either
        for (int ex : c.exclude) bad += !edge && ((ex == 1 && std::fabs(zb - 20.0) < 1e-6) || (ex == 0 && std::fabs(zb) < 1e-6));
        most = std::max(most, pm);
        // How far the tip stands out ALONG the surface's normal where the end was (the depth's gradient there): p. (Its
        // straight distance to the part can exceed p only past an edge, where the nearest surface is another face.)
        const double hh = 0.05;
        Vec3 nn{pr.depth({bk.x - hh, bk.y, bk.z}) - pr.depth({bk.x + hh, bk.y, bk.z}),
                pr.depth({bk.x, bk.y - hh, bk.z}) - pr.depth({bk.x, bk.y + hh, bk.z}),
                pr.depth({bk.x, bk.y, bk.z - hh}) - pr.depth({bk.x, bk.y, bk.z + hh})};
        const double nl = std::hypot(nn.x, std::hypot(nn.y, nn.z));
        const double out = nl > 0.0 ? ((end.x - bk.x) * nn.x + (end.y - bk.y) * nn.y + (end.z - bk.z) * nn.z) / nl : 0.0;
        most_out = std::max(most_out, out);
        bad += (e == 0 ? x.end_a : x.end_b) != Bar::End::Surface || pm > relief + 1e-12 || out > pm + 0.02 ||
               end.z <= 2.0 || x.net;
      }
      if (i < p.bars.bars.size()) {
        const Bar& y = p.bars.bars[i];   // the same bar laid flush: the proud one lies on its line, past its end
        const Bar back = without_relief(Bars{{x}}).bars.front();
        off_line += dist(back.a, y.a) > 1e-9 || dist(back.b, y.b) > 1e-9 || x.width != y.width;
      }
    }
    // OG2b (leg B): the bars along an allowed open face: given the setting (the cap), never on an excluded face, a face
    // whose normal points down more than 45 degrees, or within 2 mm of the bed (read where the bar comes nearest the
    // surface); never moved (the flush lay's bars, end relief carried back); the runs carry it.
    std::size_t along = 0, along_bad = 0;
    for (std::size_t i = 0; i < o.bars.bars.size(); ++i) {
      const Bar& x = o.bars.bars[i];
      if (!(x.along_proud > 0.0)) continue;
      ++along;
      const Bar back = without_relief(Bars{{x}}).bars.front();
      double least = 1e9;
      Vec3 at{};
      for (int q = 0; q <= 40; ++q) {
        const Vec3 pt{back.a.x + (back.b.x - back.a.x) * q / 40.0, back.a.y + (back.b.y - back.a.y) * q / 40.0,
                      back.a.z + (back.b.z - back.a.z) * q / 40.0};
        const double dd = pr.depth(pt);
        if (dd < least) { least = dd; at = pt; }
      }
      // The face nearest (the box's): the top when 20 - z is the depth, the bottom when z is, else a side.
      const bool top = std::fabs(20.0 - at.z - least) < 1e-3, bottom = std::fabs(at.z - least) < 1e-3;
      along_bad += x.along_proud != relief || !(least < 0.5 * x.width + 1e-6) || bottom ||
                   (!top && at.z <= 2.0) ||
                   (!c.exclude.empty() && top &&   // at the top's edge a side face is as near: either may be read
                    std::fabs(std::min({at.x, 30.0 - at.x, at.y, 30.0 - at.y}) - least) > 0.05);
    }
    std::size_t run_marked = 0;
    for (const WeaveRun& w : weave_runs(o.bars, {1}, 0.0)) run_marked += w.proud_mm > 0.0;
    std::printf("OL-OG2b %s, %.1f mm: %zu bars along an open face (setting %.2f), %zu not as the rule says; %zu runs carry it\n", c.name,
                relief, along, relief, along_bad, run_marked);
    CHECK(along_bad == 0 && (c.face == 0 || along > 0) && (along == 0) == (run_marked == 0));
    // The runs (the preview) are the bars: every proud tip is a run's end, exactly.
    const std::vector<WeaveRun> runs = weave_runs(o.bars, {1}, 0.0);
    std::size_t tips_in_runs = 0;
    for (const Bar& x : o.bars.bars)
      for (int e = 0; e < 2; ++e) {
        if (!((e == 0 ? x.proud_a : x.proud_b) > 0.0)) continue;
        const Vec3& end = e == 0 ? x.a : x.b;
        bool found = false;
        for (const WeaveRun& w : runs)
          found = found || (!w.points.empty() && (dist(w.points.front(), end) == 0.0 || dist(w.points.back(), end) == 0.0));
        tips_in_runs += found;
      }
    // The frame check reads the bars flush: the same frame as the flush lay's.
    const FrameModel fa = build_frame(o.bars, session.domain()), fb = build_frame(p.bars, plain.domain());
    bool same_frame = fa.nodes.size() == fb.nodes.size() && fa.pieces.size() == fb.pieces.size();
    for (std::size_t k = 0; same_frame && k < fa.nodes.size(); ++k) same_frame = dist(fa.nodes[k], fb.nodes[k]) < 1e-9;
    std::printf("OL-OG2 %s: %zu Surface ends, %zu proud (largest %.3f mm, %.3f mm outside measured), flush: excluded %zu, "
                "down %zu, bed %zu, along %zu; bad %zu, below the bed %zu, off the flush line %zu, tips in runs %zu; box grew "
                "%.2f %.2f %.2f %.2f %.2f %.2f; frame as flush %d\n",
                c.name, r.surface_ends, r.proud, r.largest_mm, most_out, r.flush_excluded, r.flush_down, r.flush_bed,
                r.flush_along, bad, low, off_line, tips_in_runs, r.grew_mm[0], r.grew_mm[1], r.grew_mm[2], r.grew_mm[3],
                r.grew_mm[4], r.grew_mm[5], same_frame ? 1 : 0);
    CHECK(o.refused.empty() && r.surface_ends > 0 && proud == r.proud && bad == 0 && low == 0 && off_line == 0 &&
          tips_in_runs == proud && most <= relief + 1e-12 && same_frame && o.bars.bars.size() == p.bars.bars.size());
    CHECK(r.surface_ends == r.proud + r.flush_excluded + r.flush_down + r.flush_bed + r.flush_along);
    for (double g : r.grew_mm) CHECK(g <= relief + 0.5 * 1.6 + 1e-9);
    if (c.face == 1 && c.exclude.empty()) CHECK(r.proud > 0 && r.grew_mm[5] > 0.0 && r.flush_down == 0);
    if (c.face == 2) CHECK(r.proud > 0 && r.grew_mm[2] > 0.0);
    if (c.face == 0) CHECK(r.flush_down > 0);   // its bottom face's ends stay flush; its open sides may stand proud
    if (!c.exclude.empty()) CHECK(r.flush_excluded > 0 && r.grew_mm[5] < 0.5 * 1.6 + 1e-9);
    // The file: the print check still clean, every shell closed and outward, the proud ends round, the trim leaving
    // their tubes out (within proud + one radius) and nothing else.
    if (c.face == 1 || c.face == 2) {
      FileOptions opt = file_options_for(FileOptions{}, true);
      opt.threads = 4;
      FileReport rep;
      const TriangleMesh mesh = make_file_mesh(session, o, opt, rep);
      const Domain& d = *session.domain();
      const OpenSpace open = read_open_space(d, o.layout, 0.25);
      const Carved carved = carve_part(session.measure(), o.layout, open);
      MeshSpec spec = file_mesh_defaults();
      spec.weave_mesh = MeshSpec::WeaveMesh::Tubes;
      const WeaveShells w = weave_shells(session.measure(), d, o.layout, o.bars, {}, carved, spec, true);
      std::size_t closed = 0;
      for (std::size_t sh = 0; sh < w.shells(); ++sh) {
        TriangleMesh one;
        int lo = 1 << 30, hi = -1;
        for (std::size_t t = w.first_tri[sh]; t < w.first_tri[sh + 1]; ++t)
          for (int k = 0; k < 3; ++k) { lo = std::min(lo, w.mesh.triangles[t][static_cast<std::size_t>(k)]); hi = std::max(hi, w.mesh.triangles[t][static_cast<std::size_t>(k)]); }
        one.vertices.assign(w.mesh.vertices.begin() + lo, w.mesh.vertices.begin() + hi + 1);
        for (std::size_t t = w.first_tri[sh]; t < w.first_tri[sh + 1]; ++t)
          one.triangles.push_back({w.mesh.triangles[t][0] - lo, w.mesh.triangles[t][1] - lo, w.mesh.triangles[t][2] - lo});
        double v = 0.0;
        closed += closed_outward(one, &v) && v > 0.0;
      }
      double out_most = 0.0, z_low = 1e9;
      for (const Vec3& v : w.mesh.vertices) { out_most = std::max(out_most, -pr.depth(v)); z_low = std::min(z_low, v.z); }
      std::printf("OL-OG2 %s file: print check clean %d (%d passes); tubes: %zu shells, %zu closed and outward, %zu proud "
                  "ends, %zu vertices left outside (farthest %.3f mm; anything else %.4f mm), lowest z %.3f; along the face "
                  "%zu bars, %zu vertices out (farthest %.3f mm); box grew %.2f %.2f %.2f %.2f %.2f %.2f\n",
                  c.name, rep.print_clean ? 1 : 0, rep.builds, w.shells(), closed, w.proud_ends, w.proud_vertices,
                  w.proud_outside_mm, w.outside_largest_mm, z_low, w.along_bars, w.along_vertices, w.along_outside_mm,
                  w.grew_mm[0], w.grew_mm[1], w.grew_mm[2], w.grew_mm[3], w.grew_mm[4], w.grew_mm[5]);
      CHECK(w.along_bars > 0 && w.along_vertices > 0 && w.along_outside_mm > 0.05 && w.along_outside_mm <= relief + 1e-3);
      // Leg H: the preview's runs (relief marks on) carry what the tubes route reads: a run is marked kRunAlong exactly
      // where its bars have along_proud (the tubes' `along`), the marked runs' bars are the tubes' along bars, the runs'
      // proud ends are the tubes' proud ends, and every marked run names the face it lies along.
      {
        std::vector<std::vector<std::size_t>> rb;
        const std::vector<WeaveRun> runs_h = weave_runs(o.bars, {1}, 0.0, &rb, true);
        std::size_t marked_bars = 0, wrong = 0, proud_run_ends = 0, faceless = 0, marked_runs = 0, off_face = 0;
        for (std::size_t q = 0; q < runs_h.size(); ++q) {
          const bool m = (runs_h[q].marks & kRunAlong) != 0;
          marked_runs += m;
          faceless += m && runs_h[q].along_face < 0;
          proud_run_ends += (runs_h[q].proud_a_mm > 0.0) + (runs_h[q].proud_b_mm > 0.0);
          for (std::size_t i : rb[q]) {
            const Bar& x = o.bars.bars[i];
            wrong += (x.along_proud > 0.0) != m;
            off_face += m && x.along_face != runs_h[q].along_face;
            marked_bars += m && dist(x.a, x.b) >= 1e-9;
          }
        }
        std::printf("OL-OG2 %s, %.1f mm, runs (leg H): %zu marked along a face (%zu bars; tubes %zu), %zu not as the bars, "
                    "%zu with no face, %zu off their face; proud run ends %zu (tubes %zu)\n", c.name, relief, marked_runs,
                    marked_bars, w.along_bars, wrong, faceless, off_face, proud_run_ends, w.proud_ends);
        CHECK(marked_runs > 0 && wrong == 0 && faceless == 0 && off_face == 0 && marked_bars == w.along_bars &&
              proud_run_ends == w.proud_ends);
        // Relief 0 (the same part laid flush): no mark, no proud length, no face; the runs as without the marks.
        const std::vector<WeaveRun> flat_runs = weave_runs(p.bars, {1}, 0.0, nullptr, true),
                                    old_runs = weave_runs(p.bars, {1}, 0.0);
        std::size_t any = 0;
        for (const WeaveRun& x : flat_runs)
          any += (x.marks & kRunAlong) != 0 || x.proud_a_mm != 0.0 || x.proud_b_mm != 0.0 || x.proud_mm != 0.0 || x.along_face != -1;
        const bool same = pack_weave_runs(flat_runs, 2) == pack_weave_runs(old_runs, 2);
        std::printf("OL-OG2 %s, relief 0, runs (leg H): %zu runs, %zu carry a relief fact; as without the marks %d\n", c.name,
                    flat_runs.size(), any, same ? 1 : 0);
        CHECK(any == 0 && same);
      }
      std::printf("OL-OG2 %s, %.1f mm, print check: clean %d, %zu bars made flush in %d rounds (OG2c), %zu findings left\n",
                  c.name, relief, rep.print_clean ? 1 : 0, rep.relief_flushed, rep.relief_rounds, rep.findings_at.size());
      CHECK((rep.print_clean || !rep.findings_at.empty()) && closed == w.shells() && w.proud_ends > 0 && w.proud_vertices > 0 &&
            w.proud_outside_mm <= relief + 0.5 * 1.6 * 1.42 + 1e-6 && w.outside_largest_mm <= 0.05 && z_low >= 0.0 &&
            out_most <= relief + 0.5 * 1.6 * 1.42 + 1e-6);
    }
  }
  // The default lay (relief 1 mm, every rule at its default) is the tip e3640d24's, bar for bar: the 5 mm ceiling only
  // widens what validation allows.
  {
    Session sd(model);
    const Outcome od = sd.lay_organic(gap_settings(1, 16.0, false), f, gap_ask(1.6));
    std::printf("OL-OG2 default lay: hash %016llx\n", static_cast<unsigned long long>(bars_hash(od.bars)));
    CHECK(bars_hash(od.bars) == kDefaultLayHash);
  }
  // The keys: the settings' ranges (the relief 0 to 5 mm, a face id 0 or more).
  {
    const Settings st = traced_settings();
    OrganicAsk a = gap_ask(1.8);
    CHECK(a.face_relief_mm == 1.0 && a.relief_exclude_faces.empty());
    for (double bad : {-0.1, 1.1}) {
      a.face_relief_mm = bad;
      CHECK(has_refusal(validate_organic(st, a, nullptr), "face_relief_mm", "out_of_range"));
    }
    a.face_relief_mm = 1.0;
    a.relief_exclude_faces = {3, -1};
    CHECK(has_refusal(validate_organic(st, a, nullptr), "relief_exclude_faces", "below_zero"));
  }
  // OP11 with both rules on (the defaults): two groups laid together give each region the bars it has laid alone (the
  // relief is fixed by the strand's number within its group). Drop loose off, so both regions keep Surface ends.
  {
    const StepModel model2 = box_model(30, 30, 40);
    const TensorField f2 = traced_field(30, 30, 40);
    Settings both;
    both.regions = {{1, Role::Lattice, {1}, 12.0, 0.0, true}, {2, Role::Lattice, {0}, 12.0, 0.0, true}};
    both.drop_loose = false;
    Settings only1 = both, only2 = both;
    only1.regions = {both.regions[0]};
    only2.regions = {both.regions[1]};
    OrganicAsk traced = traced_ask(), grown = follow_ask(true);
    grown.gap_lines = traced.gap_lines = kOrganicGapLinesDefault;
    grown.face_relief_mm = traced.face_relief_mm = 1.0;
    Session s(model2), s1(model2), s2(model2);
    const Outcome o = s.lay_organic(both, f2, std::vector<OrganicGroup>{{{1}, traced}, {{2}, grown}});
    const Outcome a1 = s1.lay_organic(only1, f2, traced);
    const Outcome a2 = s2.lay_organic(only2, f2, grown);
    std::printf("OL-OG2 two groups, both rules on: proud %zu (alone %zu + %zu); region 1 the same %d, region 2 the same %d\n",
                o.relief.proud, a1.relief.proud, a2.relief.proud, region_fnv(o, 1) == region_fnv(a1, 1) ? 1 : 0,
                region_fnv(o, 2) == region_fnv(a2, 2) ? 1 : 0);
    CHECK(o.relief.proud > 0 && o.relief.proud == a1.relief.proud + a2.relief.proud &&
          region_fnv(o, 1) == region_fnv(a1, 1) && region_fnv(o, 2) == region_fnv(a2, 2));
  }
  // OG3 (leg D): the strand distance. At the tracer's old 0.5 the lay is the old one (OL-OG1's pins); at the default
  // 0.9 a Traced lay has fewer bars and its level ties lose the segments lying along a strand within the gap; Grown is
  // not changed; the range 0.5 to 1 is refused outside, by name; the job key is read.
  {
    const TensorField f2 = traced_field();
    OrganicAsk old = judged_ask(false), on = old;
    old.strand_keep = 0.5;
    CHECK(on.strand_keep == kOrganicStrandKeepDefault && kOrganicStrandKeepDefault == 0.9);
    Session s1(model), s2(model);
    const Outcome a = s1.lay_organic(traced_settings(), f2, old), b = s2.lay_organic(traced_settings(), f2, on);
    DomainSpec ds;
    ds.bead_mm = 0.45;
    ds.min_strut_lines = 2.0;
    bool ok = false;
    ds.regions = {region_from_faces(model, {1}, 1, Role::Lattice, 16.0, 0.0, &ok)};
    ds.regions[0].weave = true;
    const PartMeasure pm(weld_mesh(model.mesh));
    const Domain d(pm, ds);
    OrganicTraceStats st;
    (void)trace_strands(d, 1, f2, on, &st);
    OrganicAsk g1 = judged_ask(true), g2 = g1;
    g1.strand_keep = 0.5;
    Session s3(model), s4(model);
    const Outcome ga = s3.lay_organic(traced_settings(), f2, g1), gb = s4.lay_organic(traced_settings(), f2, g2);
    std::printf("OL-OG3 judged Traced: %zu bars at 0.5, %zu at 0.9; level-tie segments taken out %zu (kept %zu); Grown "
                "the same %d\n", a.bars.bars.size(), b.bars.bars.size(), st.og3_tie_segments_cut, st.og3_tie_segments_kept,
                bars_hash(ga.bars) == bars_hash(gb.bars) ? 1 : 0);
    CHECK(ok && b.bars.bars.size() < a.bars.bars.size() && st.og3_tie_segments_cut > 0 && bars_hash(ga.bars) == bars_hash(gb.bars));
    for (double bad : {0.4, 1.1}) {
      OrganicAsk x = on;
      x.strand_keep = bad;
      CHECK(has_refusal(validate_organic(traced_settings(), x, nullptr), "strand_keep", "out_of_range"));
    }
  }
  // The job keys (OG1, OG2): absent, the defaults (1.5 lines, 1 mm, no face); given, read; out of range, refused by name.
  // A file job with them: the result says the gap, the diagnosis and the relief.
  {
    const std::string head = R"({"mode": "lattice_file", "model": "block.step", "layout": {
      "min_strut_lines": 2, "bead_mm": 0.45, "region_ids": [1], "region_no_lattice": [0], "region_depth_mm": [16],
      "region_expand_mm": [0], "region_face_counts": [1], "region_faces": [1], "region_weave": [true], "drop_loose": false,
      "organic_spacing_min_mm": 2, "organic_spacing_max_mm": 6, "organic_width_mm": 0.9, "organic_width_heavy_mm": 1.6)";
    const FileJob plain = parse_file_job(head + "}}");
    CHECK(plain.organic.gap_lines == 1.5 && plain.organic.face_relief_mm == 1.0 && plain.organic.relief_exclude_faces.empty() &&
          plain.organic.strand_keep == 0.9);
    CHECK(parse_file_job(head + R"(, "organic_strand_keep": 0.5}})").organic.strand_keep == 0.5);   // OG3
    FileJob job = parse_file_job(head + R"(, "organic_gap_lines": 2, "organic_face_relief_mm": 0.5,
      "organic_relief_exclude_faces": [0, 2]}})");
    CHECK(job.organic.gap_lines == 2.0 && job.organic.face_relief_mm == 0.5 &&
          job.organic.relief_exclude_faces == std::vector<int>({0, 2}));
    for (const char* bad : {R"(, "organic_gap_lines": 5)", R"(, "organic_face_relief_mm": 1.5)",
                            R"(, "organic_relief_exclude_faces": [-2])"}) {
      std::string why;
      try { (void)parse_file_job(head + bad + "}}"); } catch (const std::exception& e) { why = e.what(); }
      CHECK(why.find(std::string(bad).substr(3, 14)) != std::string::npos);
    }
    if (mesh_available()) {
      job.tensor_field = std::make_shared<TensorField>(f);
      const std::string path = std::string(ORGANIC_RULES_TMP_DIR) + "/organic_relief.stl";
      const FileResult r = make_lattice_file(box_model(30, 30, 20), job, path);
      const std::string js = file_result_json(r);
      std::printf("OL-OG2 file job: ok %d (%s), relief proud %zu of %zu Surface ends, tubes proud %zu, gap capped %zu, tight "
                  "%zu of %zu; result names them %d\n",
                  r.ok ? 1 : 0, r.code.c_str(), r.relief.proud, r.relief.surface_ends, r.made.shells.proud_ends, r.gap_capped,
                  r.tight.tight, r.tight.bars,
                  js.find("\"relief\"") != std::string::npos && js.find("\"tight\"") != std::string::npos ? 1 : 0);
      CHECK(r.ok && r.relief.proud > 0 && r.made.shells.proud_ends > 0 && r.gap_capped > 0 && r.tight.bars > 0 &&
            js.find("\"relief\"") != std::string::npos && js.find("\"tight\"") != std::string::npos &&
            js.find("\"box_grew_mm\"") != std::string::npos);
      std::remove(path.c_str());
    }
  }
}


// ── OL-OS18 (the twin, the owner 2026-11-19: "Yes, build it that way"): the twin vine maker and its addition (kind 3)
static void test_os18_relief_vines() {
  const StepModel model = box_model(30, 30, 20);
  const TensorField f = gap_field();
  Session session(model);
  OrganicAsk base = gap_ask(1.2);
  base.strand_keep = 0.5;   // the owner: vine spacing off is the main case
  base.spacing_min_mm = 8.0;   // long struts: room for the eye (4 s)
  base.spacing_max_mm = 12.0;
  const Outcome o = session.lay_organic(gap_settings(1, 16.0, true), f, base);
  CHECK(o.refused.empty() && !o.bars.bars.empty());
  if (o.bars.bars.empty()) return;
  const Domain& d = *session.domain();
  TwinAsk ta;
  ta.gap_mm = 1.5 * 0.45;
  const TwinVineMaker maker(o.bars, d, f, ta);
  // Stretches: the weave's struts (joint to joint), the longest first; the first one that takes a twin.
  std::vector<WeaveStrut> struts = weave_struts(o.bars);
  std::stable_sort(struts.begin(), struts.end(), [](const WeaveStrut& x, const WeaveStrut& y) { return x.length_mm > y.length_mm; });
  auto line_of = [&](const WeaveStrut& st) {
    std::vector<Vec3> line;
    for (std::size_t k = 0; k < st.bars.size(); ++k) {
      const Bar& b = o.bars.bars[st.bars[k]];
      const Vec3 a = st.flipped[k] ? b.b : b.a, e = st.flipped[k] ? b.a : b.b;
      if (line.empty()) line.push_back(a);
      line.push_back(e);
    }
    return line;
  };
  TwinVine tw;
  std::vector<Vec3> line;
  std::size_t tried = 0;
  for (const WeaveStrut& st : struts) {
    if (tried >= 60) break;
    const Bar& b0 = o.bars.bars[st.bars.front()];
    if (b0.link || b0.brace || b0.level_tie || b0.support) continue;
    ++tried;
    line = line_of(st);
    tw = maker.make(line, st.region, st.thinnest_mm, st.thinnest_mm, b0.cell, {});
    if (tw.laid) break;
  }
  std::printf("OL-OS18 twin: %zu stretches tried, laid %d (%zu points, offset %.3f mm, cross joined %zu, sides tried %zu)\n", tried,
              tw.laid ? 1 : 0, tw.points.size(), tw.offset_mm, tw.cross_joined, tw.sides_tried);
  CHECK(tw.laid && tw.op.kind == 3 && tw.points.size() >= 4 && dist(tw.points.front(), line.front()) == 0.0 &&
        dist(tw.points.back(), line.back()) == 0.0);
  if (!tw.laid) return;
  // The addition: laid, old bars kept (OS12), its ends exactly the stretch's joints; the same op twice: the same hash.
  Bars after = o.bars;
  AddRound round;
  round.ops.push_back(tw.op);
  AddContext c;
  c.light_mm = 0.9;
  AddReport rep;
  std::string why;
  CHECK(apply_add_round(after, d, round, c, &rep, &why));
  Bars again = o.bars;
  CHECK(apply_add_round(again, d, round, c, nullptr, &why) && bars_hash(again) == bars_hash(after));
  const std::string kept = old_bars_kept(o.bars, after);
  std::size_t at_j0 = 0, at_jn = 0, relief = 0;
  for (const Bar& b : after.bars) {
    if (!b.relief) continue;
    ++relief;
    at_j0 += dist(b.a, line.front()) == 0.0 || dist(b.b, line.front()) == 0.0;
    at_jn += dist(b.a, line.back()) == 0.0 || dist(b.b, line.back()) == 0.0;
  }
  std::printf("OL-OS18 twin laid: %zu bars, old bars kept: %s; a bar ends exactly at J0 %zu, at Jn %zu\n", relief,
              kept.empty() ? "yes" : kept.c_str(), at_j0, at_jn);
  CHECK(relief > 0 && rep.relief_vines == 1 && kept.empty() && at_j0 >= 1 && at_jn >= 1);
  // Too short for the eye (under 4 s): no_room "too_short"; a side already taken is not tried again.
  {
    const std::vector<Vec3> short_line{line.front(), Vec3{line.front().x + 1.0, line.front().y, line.front().z}};
    const TwinVine ts = maker.make(short_line, 1, 1.6, 1.6, 4.0, {});
    const TwinVine ta2 = maker.make(line, 1, 1.6, 1.6, 4.0, {tw.side});
    std::printf("OL-OS18 too short: laid %d, why %s; the same stretch with its side taken: laid %d, side %s\n", ts.laid ? 1 : 0,
                ts.no_room.c_str(), ta2.laid ? 1 : 0,
                ta2.laid ? (ta2.side.x * tw.side.x + ta2.side.y * tw.side.y + ta2.side.z * tw.side.z < 0.71 ? "another" : "the same") : ta2.no_room.c_str());
    CHECK(!ts.laid && ts.no_room == "too_short");
    CHECK(!ta2.laid || ta2.side.x * tw.side.x + ta2.side.y * tw.side.y + ta2.side.z * tw.side.z < 0.71);
  }
  // The additions file carries kind 3 (written, read back, the same numbers), replayed to the same hash.
  {
    Additions adds;
    round.hash = bars_hash(after);
    adds.rounds.push_back(round);
    const std::string path = std::string(ORGANIC_RULES_TMP_DIR) + "/os18_additions.bin";
    Additions back;
    CHECK(write_additions_file(path, adds) && read_additions_file(path, back) && back.rounds.size() == 1 &&
          back.rounds[0].ops.size() == 1 && back.rounds[0].ops[0].kind == 3 && back.rounds[0].ops[0].v == tw.op.v);
    Bars replay = o.bars;
    CHECK(apply_additions(replay, d, back, c, &why) && bars_hash(replay) == bars_hash(after));
    std::remove(path.c_str());
  }
}

// ── OG5 (brief E9; the owner, 2026-11-19: "That CAN'T happen"): no Organic bar outside the part or through protected
// solid. What a lay's bars break of it: centre-line points outside the part (relief ends aside); points in solid that
// are not part of an end's run-on (mid-bar solid); points in protected skin whose tube surface comes within one line
// width of the part's outer surface.
struct Og5Count { std::size_t outside = 0, mid_solid = 0, near_face = 0, bars = 0, run_pts_outside = 0; };
static Og5Count og5_count(const Session& s, const Bars& bars, const std::vector<int>& regions) {
  Og5Count c;
  const Domain::Probe probe = s.domain()->probe();
  const double line = s.domain()->spec().bead_mm;
  for (const Bar& b : bars.bars) {
    if (!(b.net || b.support || std::find(regions.begin(), regions.end(), b.region) != regions.end())) continue;
    ++c.bars;
    const double L = dist(b.a, b.b);
    if (!(L > 0.0)) continue;
    const double t0 = std::min(b.relief_a, L), t1 = std::max(t0, L - b.relief_b);
    const int n = std::max(2, static_cast<int>(std::ceil((t1 - t0) / 0.05)));
    std::string seq;
    for (int k = 0; k <= n; ++k) {
      const double t = t0 + (t1 - t0) * k / n;
      const Vec3 p{b.a.x + (b.b.x - b.a.x) * t / L, b.a.y + (b.b.y - b.a.y) * t / L, b.a.z + (b.b.z - b.a.z) * t / L};
      const Where w = probe.where(p);
      const char ch = w.lattice() ? 'L' : w.why == Why::Outside ? 'O' : 'S';
      if (seq.empty() || seq.back() != ch) seq.push_back(ch);
      if (ch == 'O') { ++c.outside; }
      // Rule 3 on the run-on: a point of the bar inside protected skin (the end itself aside: with a skin thinner than
      // the radius plus a line, the end stops at the skin, run-on 0) keeps its tube a line width off the outer face.
      const bool at_end = t < 0.02 || t > L - 0.02;
      if (!at_end && w.why == Why::ProtectSkin && probe.part().depth(p) - 0.5 * b.width < line - 2e-3) ++c.near_face;
    }
    // solid only at the ends: the run of letters is S?L..L S? with no S between two L
    const std::size_t first_l = seq.find('L'), last_l = seq.rfind('L');
    if (first_l != std::string::npos && seq.substr(first_l, last_l - first_l + 1).find('S') != std::string::npos) ++c.mid_solid;
  }
  std::vector<Vec3> relief_ends;   // OG2's ends carried proud of an open face on purpose
  for (const Bar& b : bars.bars) {
    if (b.relief_a > 0.0) relief_ends.push_back(b.a);
    if (b.relief_b > 0.0) relief_ends.push_back(b.b);
  }
  for (const WeaveRun& r : weave_runs(bars, regions, 0.0))
    for (const Vec3& q : r.points) {
      if (probe.where(q).why != Why::Outside) continue;
      bool relief = false;
      for (const Vec3& e : relief_ends) relief = relief || dist(e, q) < 1e-9;
      c.run_pts_outside += !relief;
    }
  return c;
}

static void test_og5_inside() {
  // A 30 x 30 x 20 block, the weave under its top face (open) 20 mm deep; a 0.8 mm Protect skin on its bottom (the bed
  // floor) and a 4 mm one on a side; Traced and Grown, the net skin off and on.
  const StepModel model = box_model(30, 30, 20);
  const TensorField f = traced_field();
  for (const bool grown : {false, true})
    for (const bool net : {false, true}) {
      Settings st;
      st.regions = {{1, Role::Lattice, {1}, 20.0, 0.0, true}};
      Settings::ProtectAsk floor, side;
      floor.id = 2; floor.faces = {0}; floor.depth_mm = 0.8;
      side.id = 3; side.faces = {3}; side.depth_mm = 4.0;
      st.protect = {floor, side};
      st.skin = net;
      OrganicAsk a = traced_ask();
      if (grown) a.mode = OrganicMode::Grown;
      Session s(model);
      const Outcome o = s.lay_organic(st, f, a);
      const Og5Count c = og5_count(s, o.bars, {1});
      std::printf("OG5 %s net %d: %zu weave bars; outside %zu, mid-bar solid %zu, within a line of a protected face %zu, run points "
                  "outside %zu; guard: moved in %zu, outside cut %zu, in solid cut %zu, removed %zu\n", grown ? "Grown" : "Traced",
                  net ? 1 : 0, c.bars, c.outside, c.mid_solid, c.near_face, c.run_pts_outside, o.guard.ends_moved_in,
                  o.guard.outside_cut, o.guard.in_solid_cut, o.guard.in_solid_removed);
      CHECK(c.bars > 0 && c.outside == 0 && c.mid_solid == 0 && c.near_face == 0 && c.run_pts_outside == 0);
      if (!grown && !net) {
        // The strengthen additions case: a round widening every strut ending in the floor skin to 3 x its width, replayed
        // with the guard (AddContext::line_mm): the run-ons are cut back to the rule.
        Bars bars = o.bars;
        AddRound rd;
        for (const Bar& b : bars.bars)
          if (b.region == 1 && !b.link && (b.end_a == Bar::End::Solid || b.end_b == Bar::End::Solid) && std::min(b.a.z, b.b.z) < 1.0)
            rd.ops.push_back({2, {b.a.x, b.a.y, b.a.z, b.b.x, b.b.y, b.b.z, 3.0 * b.width}});
        Bars probe_bars = bars;
        CHECK(apply_add_round(probe_bars, *s.domain(), rd, AddContext{}));
        rd.hash = bars_hash(probe_bars);   // the hash without the guard: a mismatch would refuse; set it after the guard
        AddContext ctx;
        ctx.light_mm = 0.9;
        ctx.weave_regions = {1};
        ctx.line_mm = s.domain()->spec().bead_mm;
        GuardReport g;
        ctx.guard = &g;
        Bars guarded = probe_bars;
        guard_bars(guarded, *s.domain(), ctx.weave_regions, ctx.line_mm, &g);
        rd.hash = bars_hash(guarded);
        Additions adds;
        adds.rounds.push_back(rd);
        GuardReport g2;
        ctx.guard = &g2;
        std::string why;
        const bool ok = apply_additions(bars, *s.domain(), adds, ctx, &why);
        const Og5Count c2 = og5_count(s, bars, {1});
        std::printf("OG5 additions: %zu floor struts widened 3x; guard cut %zu in solid, %zu outside; replayed %d (%s); outside %zu, "
                    "mid-bar solid %zu, within a line of a protected face %zu\n", rd.ops.size(), g2.in_solid_cut, g2.outside_cut, ok ? 1 : 0,
                    why.c_str(), c2.outside, c2.mid_solid, c2.near_face);
        CHECK(!rd.ops.empty() && ok && c2.outside == 0 && c2.mid_solid == 0 && c2.near_face == 0);
        // After additions the guard also drops what its cut leaves hanging (apply_additions and the strengthen job pass
        // drop_cut_free): a bar run out through the open top is cut at the part; the piece left with a free end is kept
        // at the lay (its drop follows) and dropped after additions.
        Bars poke = o.bars;
        Bar x = poke.bars.front();
        x.a = {15, 15, 10};
        x.b = {15, 15, 23};
        x.end_a = x.end_b = Bar::End::Node;
        x.relief_a = x.relief_b = 0.0;
        x.region = 1;
        x.net = x.support = x.link = x.level_tie = x.brace = false;
        x.width = 0.9;
        poke.bars.push_back(x);
        Bars kept_poke = poke, dropped_poke = poke;
        GuardReport gk, gd;
        guard_bars(kept_poke, *s.domain(), {1}, s.domain()->spec().bead_mm, &gk, false);
        guard_bars(dropped_poke, *s.domain(), {1}, s.domain()->spec().bead_mm, &gd, true);
        std::printf("OG5 cut and dropped: at the lay %zu bars (outside cut %zu, dropped %zu); after additions %zu bars (outside cut %zu, "
                    "dropped %zu)\n", kept_poke.bars.size(), gk.outside_cut, gk.cut_dropped, dropped_poke.bars.size(), gd.outside_cut, gd.cut_dropped);
        CHECK(gk.outside_cut == 1 && gk.cut_dropped == 0 && kept_poke.bars.size() == poke.bars.size());
        CHECK(gd.cut_dropped == 1 && dropped_poke.bars.size() == poke.bars.size() - 1);
      }
    }
  // A concave (L-shaped) part: the weave under the top of an L, where a straight link or tie could chord the solid corner.
  {
    StepModel m;
    const std::vector<std::array<double, 2>> xy = {{0, 0}, {30, 0}, {30, 12}, {12, 12}, {12, 30}, {0, 30}};
    const int n = static_cast<int>(xy.size());
    auto add_face = [&](const std::vector<Vec3>& poly, Vec3 normal, int face) {
      StepFaceInfo info;
      info.kind = StepSurfaceKind::Plane;
      info.plane_normal = normal;
      info.plane_origin = poly[0];
      m.faces.push_back(info);
      for (std::size_t k = 1; k + 1 < poly.size(); ++k) {
        const int v = static_cast<int>(m.mesh.vertices.size());
        m.mesh.vertices.insert(m.mesh.vertices.end(), {poly[0], poly[k], poly[k + 1]});
        m.mesh.triangles.push_back({v, v + 1, v + 2});
        m.triangle_face.push_back(face);
      }
    };
    // bottom (as two convex pieces' fan from the inner corner), top, sides
    const std::vector<Vec3> bot1{{12, 12, 0}, {12, 0, 0}, {0, 0, 0}, {0, 30, 0}, {12, 30, 0}};
    const std::vector<Vec3> bot2{{12, 12, 0}, {30, 12, 0}, {30, 0, 0}, {12, 0, 0}};
    const std::vector<Vec3> top1{{12, 12, 20}, {12, 30, 20}, {0, 30, 20}, {0, 0, 20}, {12, 0, 20}};
    const std::vector<Vec3> top2{{12, 12, 20}, {12, 0, 20}, {30, 0, 20}, {30, 12, 20}};
    add_face(bot1, {0, 0, -1}, 0);
    {   // the second bottom piece is the same face 0
      for (std::size_t k = 1; k + 1 < bot2.size(); ++k) {
        const int v = static_cast<int>(m.mesh.vertices.size());
        m.mesh.vertices.insert(m.mesh.vertices.end(), {bot2[0], bot2[k], bot2[k + 1]});
        m.mesh.triangles.push_back({v, v + 1, v + 2});
        m.triangle_face.push_back(0);
      }
    }
    add_face(top1, {0, 0, 1}, 1);
    for (std::size_t k = 1; k + 1 < top2.size(); ++k) {
      const int v = static_cast<int>(m.mesh.vertices.size());
      m.mesh.vertices.insert(m.mesh.vertices.end(), {top2[0], top2[k], top2[k + 1]});
      m.mesh.triangles.push_back({v, v + 1, v + 2});
      m.triangle_face.push_back(1);
    }
    for (int i = 0; i < n; ++i) {
      const auto& p = xy[static_cast<std::size_t>(i)];
      const auto& q = xy[static_cast<std::size_t>((i + 1) % n)];
      const double dx = q[0] - p[0], dy = q[1] - p[1], l = std::hypot(dx, dy);
      add_face({{p[0], p[1], 0}, {q[0], q[1], 0}, {q[0], q[1], 20}, {p[0], p[1], 20}}, {dy / l, -dx / l, 0}, 2 + i);
    }
    m.face_count = 2 + n;
    m.solid_count = 1;
    m.brep_volume = (30.0 * 30.0 - 18.0 * 18.0) * 20.0;
    for (const bool tie : {false, true}) {
      Settings st;
      st.regions = {{1, Role::Lattice, {1}, 20.0, 0.0, true}};
      OrganicAsk a = traced_ask();
      a.tie_level = tie;
      Session s(m);
      const Outcome o = s.lay_organic(st, f, a);
      const Og5Count c = og5_count(s, o.bars, {1});
      std::printf("OG5 L-shaped, ties %d: %zu weave bars; outside %zu, mid-bar solid %zu, run points outside %zu; guard: moved in %zu, "
                  "outside cut %zu, in solid cut %zu, removed %zu\n", tie ? 1 : 0, c.bars, c.outside, c.mid_solid, c.run_pts_outside,
                  o.guard.ends_moved_in, o.guard.outside_cut, o.guard.in_solid_cut, o.guard.in_solid_removed);
      CHECK(c.bars > 0 && c.outside == 0 && c.mid_solid == 0 && c.run_pts_outside == 0);
    }
  }
}

// ── OL-FIN (leg J item 1; the owner: the Finish per group "should just be None/Skin/Solid. Rim should be hidden."):
// each weave region's own Skin and width; Rim refused on an Organic area.
static void test_finish_per_region() {
  const StepModel model = box_model(30, 30, 20);
  const TensorField f = gap_field();
  OrganicAsk a = gap_ask(1.6);
  Settings st;
  st.regions = {{1, Role::Lattice, {1}, 8.0, 0.0, true}, {2, Role::Lattice, {2}, 8.0, 0.0, true}};
  st.drop_loose = false;
  st.skin = true;   // the part's Skin: on
  const std::vector<OrganicGroup> gs = {{{1, 2}, a}};
  auto nets = [](const Outcome& o, int region, double* wmin, double* wmax) {
    std::size_t n = 0;
    *wmin = 1e9; *wmax = 0.0;
    for (const Bar& b : o.bars.bars)
      if (b.net && b.region == region) { ++n; *wmin = std::min(*wmin, b.width); *wmax = std::max(*wmax, b.width); }
    return n;
  };
  double lo1, hi1, lo2, hi2;
  Session s0(model);
  const Outcome both = s0.lay_organic(st, f, gs);
  const std::size_t b1 = nets(both, 1, &lo1, &hi1), b2 = nets(both, 2, &lo2, &hi2);
  Settings own = st;
  own.regions[0].skin = true;
  own.regions[0].skin_width_mm = 0.8;
  own.regions[1].skin = false;   // area 2: None
  Session s1(model);
  const Outcome o = s1.lay_organic(own, f, gs);
  double w1lo, w1hi, w2lo, w2hi;
  const std::size_t n1 = nets(o, 1, &w1lo, &w1hi), n2 = nets(o, 2, &w2lo, &w2hi);
  std::printf("OL-FIN part Skin, both areas: net struts %zu and %zu; area 1 Skin 0.8 mm, area 2 None: %zu (widths %.3f to %.3f) and %zu\n",
              b1, b2, n1, w1lo, w1hi, n2);
  CHECK(both.refused.empty() && o.refused.empty() && b1 > 0 && b2 > 0 && n1 > 0 && n2 == 0 && w1lo == 0.8 && w1hi == 0.8);
  // The part's Skin off, area 2's own Skin on: a net on area 2 only.
  Settings only2 = st;
  only2.skin = false;
  only2.regions[1].skin = true;
  Session s2(model);
  const Outcome o2 = s2.lay_organic(only2, f, gs);
  const std::size_t m1 = nets(o2, 1, &w1lo, &w1hi), m2 = nets(o2, 2, &w2lo, &w2hi);
  std::printf("OL-FIN part Skin off, area 2 Skin: net struts %zu and %zu\n", m1, m2);
  CHECK(o2.refused.empty() && m1 == 0 && m2 > 0);
  // Area 1 Skin, area 2 Solid (its cover): the net on area 1 only; the part's Covered: no net at all.
  Settings mixed = st;
  mixed.regions[0].skin = true;
  mixed.regions[1].cover_mm = 1.2;
  Session s4(model);
  const Outcome o4 = s4.lay_organic(mixed, f, gs);
  const std::size_t k1 = nets(o4, 1, &w1lo, &w1hi), k2 = nets(o4, 2, &w2lo, &w2hi);
  Settings covered = st;
  covered.cover_mm = -1.0;
  Session s5(model);
  const Outcome o5 = s5.lay_organic(covered, f, gs);
  std::printf("OL-FIN area 1 Skin, area 2 Solid: net struts %zu and %zu; the part Covered (Skin on): %zu\n", k1, k2, o5.net_struts);
  CHECK(o4.refused.empty() && k1 > 0 && k2 == 0 && o5.refused.empty() && o5.net_struts == 0);
  // Rim on an Organic area: refused, by name.
  Settings rim = st;
  rim.regions[0].rim_mm = 1.0;
  Session s3(model);
  const Outcome r = s3.lay_organic(rim, f, gs);
  std::printf("OL-FIN Rim on area 1: %s (%s)\n", r.refused.empty() ? "laid" : r.refused[0].code.c_str(),
              r.refused.empty() ? "" : r.refused[0].text.c_str());
  CHECK(!r.refused.empty() && r.refused[0].code == "rim_under_organic" && r.refused[0].setting == "rim_mm");
}

// ── OL-SOLID (leg J item 2, OJ2): an Organic area's Solid closes its open face only; depth variation off there.
static void test_solid_open_face() {
  const StepModel model = box_model(30, 30, 20);
  const TensorField f = gap_field();
  OrganicAsk a = gap_ask(1.6);
  a.face_relief_mm = 1.0;
  Settings st = gap_settings(1, 8.0, false);   // the weave under the top face (z = 20), 8 mm deep
  st.regions[0].cover_mm = 1.2;               // Solid, 1.2 mm
  Session s(model);
  const Outcome o = s.lay_organic(st, f, a);
  const Domain::Probe pr = s.domain()->probe();
  // Under the open face: solid within 1.2 mm; the side walls the area meets: lattice up to the face.
  const Where under = pr.where({15.0, 15.0, 19.5}), deeper = pr.where({15.0, 15.0, 18.0}), side = pr.where({0.5, 15.0, 15.0});
  std::size_t in_cover = 0, along = 0, proud = 0, bars1 = 0;
  double top_z = 0.0;
  for (const Bar& b : o.bars.bars) {
    if (b.region != 1) continue;
    ++bars1;
    // An end that meets the cover ends in it as in any solid (run on up to its radius, O4): none reaches further.
    for (const Vec3& p : {b.a, b.b}) { in_cover += p.z > 20.0 - 1.2 + 0.5 * b.width + 1e-6; top_z = std::max(top_z, p.z); }
    along += b.along_proud > 0.0;
    proud += b.proud_a > 0.0 || b.proud_b > 0.0;
  }
  // The same area without the Solid: relief laid (the switch is the cover's, not the relief's).
  Settings open = gap_settings(1, 8.0, false);
  Session s2(model);
  const Outcome o2 = s2.lay_organic(open, f, a);
  std::printf("OL-SOLID: 0.5 mm under the open face %s, 2 mm under it %s, 0.5 mm in from a side wall %s; area 1 bars %zu, "
              "ends more than a radius inside the cover %zu (highest end z %.4f), along-face relief %zu, proud ends %zu; without Solid: along %zu, proud %zu\n",
              under.why == Why::Cover ? "cover" : "not cover", deeper.lattice() ? "lattice" : "not lattice",
              side.lattice() ? "lattice" : "not lattice", bars1, in_cover, top_z, along, proud, o2.relief.along, o2.relief.proud);
  CHECK(o.refused.empty() && under.why == Why::Cover && deeper.lattice() && side.lattice() && bars1 > 0 && in_cover == 0 &&
        along == 0 && proud == 0 && o2.relief.along + o2.relief.proud > 0);
}

// ── OL-GROUPS-FILE (leg J item 3, OJ3): the file job's organic_groups, each group its own ask.
static void test_file_groups() {
  const std::string head = R"({"mode": "lattice_file", "model": "block.step", "layout": {
      "min_strut_lines": 2, "bead_mm": 0.45, "region_ids": [1, 2], "region_no_lattice": [0, 0], "region_depth_mm": [8, 8],
      "region_expand_mm": [0, 0], "region_face_counts": [1, 1], "region_faces": [1, 2], "region_weave": [true, true],
      "drop_loose": false, "organic_spacing_min_mm": 3, "organic_spacing_max_mm": 6, "organic_width_mm": 0.9)";
  const FileJob job = parse_file_job(head + R"(, "organic_groups": [{"regions": [1]},
      {"regions": [2], "organic_spacing_min_mm": 5, "organic_spacing_max_mm": 8, "organic_width_mm": 1.2}]}})");
  const bool parsed = job.organic_groups.size() == 2 && job.organic_groups[0].regions == std::vector<int>{1} &&
                      job.organic_groups[0].ask.spacing_min_mm == 3.0 && job.organic_groups[1].ask.spacing_min_mm == 5.0 &&
                      job.organic_groups[1].ask.spacing_max_mm == 8.0 && job.organic_groups[1].ask.width_mm == 1.2 &&
                      job.organic_groups[1].ask.layer_mm == job.organic.layer_mm;
  std::string bad_key, bad_value;
  try { (void)parse_file_job(head + R"(, "organic_groups": [{"regions": [1]}, {"regions": [2], "cell_mm": 4}]}})"); }
  catch (const std::exception& e) { bad_key = e.what(); }
  try { (void)parse_file_job(head + R"(, "organic_groups": [{"regions": [1]}, {"regions": [2], "organic_spacing_min_mm": 9, "organic_spacing_max_mm": 5}]}})"); }
  catch (const std::exception& e) { bad_value = e.what(); }
  std::printf("OL-GROUPS-FILE parsed %d; a foreign key: %s; a bad value: %s\n", parsed ? 1 : 0, bad_key.c_str(), bad_value.c_str());
  CHECK(parsed && bad_key.find("organic_groups[1].cell_mm") != std::string::npos &&
        bad_value.find("organic_groups[1]") != std::string::npos);
  // The file job lays what Session::lay_organic lays with the same groups.
  if (mesh_available()) {
    FileJob j2 = job;
    j2.tensor_field = std::make_shared<TensorField>(gap_field());
    const std::string path = std::string(ORGANIC_RULES_TMP_DIR) + "/organic_groups.stl";
    const FileResult r = make_lattice_file(box_model(30, 30, 20), j2, path);
    Session s(box_model(30, 30, 20));
    const Outcome o = s.lay_organic(job.settings, gap_field(), job.organic_groups);
    std::size_t w1 = 0, w2 = 0;
    for (const Bar& b : o.bars.bars) { w1 += b.region == 1; w2 += b.region == 2; }
    std::printf("OL-GROUPS-FILE file job: ok %d (%s), bars %zu; the session's lay: %zu bars (area 1 %zu, area 2 %zu)\n", r.ok ? 1 : 0,
                r.code.c_str(), r.bars, o.bars.bars.size(), w1, w2);
    CHECK(r.ok && r.bars == o.bars.bars.size() && w1 > 0 && w2 > 0);
    std::remove(path.c_str());
  }
}

// ── OL-GROUPS-ADD (leg J item 4, OJ4): floors and additions on a lay of two groups.
static void test_groups_floors_additions() {
  const StepModel model = box_model(30, 30, 20);
  const TensorField f = gap_field();
  Settings st;
  st.regions = {{1, Role::Lattice, {1}, 8.0, 0.0, true}, {2, Role::Lattice, {2}, 8.0, 0.0, true}};
  st.drop_loose = false;
  OrganicAsk a1 = gap_ask(1.2), a2 = gap_ask(1.8);
  a2.width_mm = 1.0;
  std::vector<OrganicGroup> gs = {{{1}, a1}, {{2}, a2}};
  // Floors over the whole box at 5 mm: each group's bars floored to its own upper width.
  gs[0].ask.floors = {{{15.0, 15.0, 10.0}, 40.0, 5.0}};
  Session s(model);
  const Outcome o = s.lay_organic(st, f, gs);
  double w1 = 0.0, w2 = 0.0, w1min = 1e9, w2min = 1e9;
  for (const Bar& b : o.bars.bars) {
    if (b.link || b.net) continue;
    if (b.region == 1) { w1 = std::max(w1, b.width); w1min = std::min(w1min, b.width); }
    if (b.region == 2) { w2 = std::max(w2, b.width); w2min = std::min(w2min, b.width); }
  }
  std::printf("OL-GROUPS-ADD floors: %zu bars widened (%zu links); area 1 widths %.3f to %.3f (its upper 1.2), area 2 %.3f to %.3f (its upper 1.8)\n",
              o.floors_widened, o.floor_links_widened, w1min, w1, w2min, w2);
  CHECK(o.refused.empty() && o.floors_widened > 0 && std::fabs(w1 - 1.2) < 1e-9 && std::fabs(w1min - 1.2) < 1e-9 &&
        std::fabs(w2 - 1.8) < 1e-9 && std::fabs(w2min - 1.8) < 1e-9);
  // Additions on the two-group lay: a widening of one bar in each area, replayed with the round's hash.
  gs[0].ask.floors.clear();
  Session s0(model);
  const Outcome plain = s0.lay_organic(st, f, gs);
  AddRound round;
  for (int want : {1, 2})
    for (const Bar& b : plain.bars.bars)
      if (b.region == want && !b.link && !b.net && dist(b.a, b.b) > 1.0) {
        round.ops.push_back({2, {b.a.x, b.a.y, b.a.z, b.b.x, b.b.y, b.b.z, b.width + 0.3}});
        break;
      }
  round.hash = 0;
  gs[0].ask.additions.rounds = {round};
  Session s1(model);
  const Outcome first = s1.lay_organic(st, f, gs);
  const std::size_t at = first.additions_refused.find("hash is ");
  CHECK(at != std::string::npos);
  if (at == std::string::npos) return;
  gs[0].ask.additions.rounds[0].hash = std::stoull(first.additions_refused.substr(at + 8, 16), nullptr, 16);
  Session s2(model);
  const Outcome again = s2.lay_organic(st, f, gs);
  std::size_t widened = 0;
  for (const AddOp& op : round.ops)
    for (const Bar& b : again.bars.bars)
      widened += dist(b.a, Vec3{op.v[0], op.v[1], op.v[2]}) < 1e-9 && dist(b.b, Vec3{op.v[3], op.v[4], op.v[5]}) < 1e-9 &&
                 std::fabs(b.width - op.v[6]) < 1e-12;
  std::printf("OL-GROUPS-ADD additions: refused first with the wrong hash (%s); replayed: %zu round(s), refused '%s', the two widenings laid %zu\n",
              first.additions_refused.substr(0, 40).c_str(), again.additions_rounds, again.additions_refused.c_str(), widened);
  CHECK(again.additions_rounds == 1 && again.additions_refused.empty() && widened == 2);
}

// ── OL-NET-APART (leg J, OJ7; the lead's ruling 6: the net skin kept apart): no net strut passes through another.
static std::size_t net_crossings(const Bars& bars, double extra) {
  std::vector<const Bar*> net;
  for (const Bar& b : bars.bars) if (b.net) net.push_back(&b);
  auto key = [](const Vec3& p) { return std::array<double, 3>{p.x, p.y, p.z}; };
  std::size_t n = 0;
  for (std::size_t i = 0; i < net.size(); ++i)
    for (std::size_t j = i + 1; j < net.size(); ++j) {
      const Bar &x = *net[i], &y = *net[j];
      if (key(x.a) == key(y.a) || key(x.a) == key(y.b) || key(x.b) == key(y.a) || key(x.b) == key(y.b)) continue;
      const double lim = 0.5 * (x.width + y.width) + extra;
      if (std::min(x.a.x, x.b.x) - lim > std::max(y.a.x, y.b.x) || std::min(y.a.x, y.b.x) - lim > std::max(x.a.x, x.b.x) ||
          std::min(x.a.y, x.b.y) - lim > std::max(y.a.y, y.b.y) || std::min(y.a.y, y.b.y) - lim > std::max(x.a.y, x.b.y) ||
          std::min(x.a.z, x.b.z) - lim > std::max(y.a.z, y.b.z) || std::min(y.a.z, y.b.z) - lim > std::max(x.a.z, x.b.z))
        continue;
      double least = 1e9;
      for (int q = 0; q <= 40; ++q) {
        const Vec3 p{x.a.x + (x.b.x - x.a.x) * q / 40.0, x.a.y + (x.b.y - x.a.y) * q / 40.0, x.a.z + (x.b.z - x.a.z) * q / 40.0};
        const Vec3 d{y.b.x - y.a.x, y.b.y - y.a.y, y.b.z - y.a.z};
        const double l2 = d.x * d.x + d.y * d.y + d.z * d.z;
        const double t = l2 > 0 ? std::clamp(((p.x - y.a.x) * d.x + (p.y - y.a.y) * d.y + (p.z - y.a.z) * d.z) / l2, 0.0, 1.0) : 0.0;
        least = std::min(least, dist(p, Vec3{y.a.x + d.x * t, y.a.y + d.y * t, y.a.z + d.z * t}));
      }
      n += least < lim - 1e-6;
    }
  return n;
}
static void test_net_kept_apart() {
  const StepModel model = box_model(30, 30, 20);
  const TensorField f = gap_field();
  Settings st;
  st.regions = {{1, Role::Lattice, {1}, 8.0, 0.0, true}};
  st.drop_loose = false;
  st.skin = false;
  for (int grown = 0; grown < 2; ++grown) {
    OrganicAsk a = gap_ask(1.6);
    if (grown) { a.mode = OrganicMode::Grown; a.layer_mm = 0.2; }
    Session s(model);
    const Outcome o = s.lay_organic(st, f, a);
    const double gap = 1.5 * 0.45;
    Bars before = o.bars, after = o.bars;
    std::size_t refused = 0;
    const std::size_t made0 = lay_net_skin(before, *s.domain(), {{1, 4.0}}, 0.0, nullptr, nullptr, false);
    const std::vector<double> gaps{gap};
    const std::size_t made1 = lay_net_skin(after, *s.domain(), {{1, 4.0}}, 0.0, nullptr, &gaps, true, &refused);
    const std::size_t c0 = net_crossings(before, 0.0), c1 = net_crossings(after, 0.0), g1 = net_crossings(after, gap);
    // Through the session (Skin on): kept apart by default.
    Settings sk = st;
    sk.skin = true;
    Session s2(model);
    const Outcome o2 = s2.lay_organic(sk, f, a);
    const std::size_t c2 = net_crossings(o2.bars, 0.0), g2 = net_crossings(o2.bars, gap);
    std::printf("OL-NET-APART %s: net struts %zu before (passing through one another %zu), %zu kept apart (%zu joins not laid; "
                "through %zu, within the gap %zu); the session's Skin: %zu net struts, %zu kept apart, through %zu, within the gap %zu\n",
                grown ? "Grown" : "Traced", made0, c0, made1, refused, c1, g1, o2.net_struts, o2.net_kept_apart, c2, g2);
    CHECK(made0 > 0 && made1 > 0 && c1 == 0 && g1 == 0 && c2 == 0 && g2 == 0 && o2.net_struts > 0 && refused > 0);
  }
}

int main() {
  test_net_kept_apart();
  test_groups_floors_additions();
  test_file_groups();
  test_solid_open_face();
  test_finish_per_region();
  test_og5_inside();
  test_s_cut_fix();
  test_k_floor();
  test_j_prune_and_cap();
  test_l_shape_reach_and_hold();
  test_d_stress_goal();
  test_e_try_keys();
  test_f_wall_cross();
  test_g_h_runs();
  test_i_auto();
  test_m_n_o();
  test_p_level_ties();
  test_q_traced_full();
  test_r_traced_ties();
  test_t_brace();
  test_reference_stated_at_resolved();
  test_link_width_run();
  test_runs();
  test_draft();
  test_sweep_limits();
  test_session_sweep_limits();
  test_follow_stress();
  test_additions();
  test_validate();
  test_equal_ends();
  test_floor_from_ask();
  test_sweep_limits_for();
  test_groups();
  test_synthetic();
  test_sample_bodies();
  test_g11_reseed_pattern();
  test_og1_gap();
  test_og2_relief();
  test_os18_relief_vines();
  std::printf("%d checks, %d failed\n", g_checks, g_fail);
  return g_fail ? 1 : 0;
}
