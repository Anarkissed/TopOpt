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
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#include "topopt/lattice_layout.hpp"
#include "topopt/lattice_layout_file.hpp"
#include "topopt/lattice_layout_mesh.hpp"
#include "topopt/lattice_layout_organic.hpp"

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
    const std::uint64_t today[2] = {0x9a119fd417d400d7ULL, 0x235c732cf4f2f269ULL};
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
  Additions adds;
  adds.rounds = {round, second};
  // Replayed after a new lay (through the ask, as the file job and the preview lay it): the same lattice.
  OrganicAsk b2 = a;
  b2.additions = adds;
  Session s1(model);
  const Outcome replay = s1.lay_organic(traced_settings(), f, b2, 3);
  std::printf("OL-ADD replay: %zu rounds, %s, hash %s\n", replay.additions_rounds,
              replay.additions_refused.empty() ? "applied" : replay.additions_refused.c_str(),
              bars_hash(replay.bars) == second.hash ? "the same" : "DIFFERENT");
  CHECK(replay.additions_refused.empty() && replay.additions_rounds == 2 && bars_hash(replay.bars) == second.hash &&
        replay.bars.bars.size() == after2.bars.size());
  // The file, and strengthened.json version 2.
  const std::string dir = std::string(ORGANIC_RULES_TMP_DIR) + "/ol_add";
  std::filesystem::create_directories(dir);
  CHECK(write_additions_file(dir + "/additions.bin", adds));
  Strengthened st;
  st.version = 2;
  st.additions = "additions.bin";
  CHECK(write_strengthened_file(dir + "/strengthened.json", st, "  \"rounds\": 2"));
  {
    TensorField keep = f;
    OrganicAsk r = a;
    CHECK(apply_strengthened(dir + "/strengthened.json", keep, r, &why));
    CHECK(keep.voigt == f.voigt && r.additions.rounds.size() == 2 && r.additions.rounds[1].hash == second.hash &&
          r.additions.rounds[0].ops.size() == round.ops.size() && r.additions.rounds[0].ops[0].v == round.ops[0].v);
  }
  // Refused: a wrong hash; a bar not in the lattice; a kind not known.
  {
    OrganicAsk bad = b2;
    bad.additions.rounds[1].hash ^= 1;
    Session sx(model);
    const Outcome o = sx.lay_organic(traced_settings(), f, bad);
    CHECK(!o.additions_refused.empty() && o.bars.bars.empty());
    std::printf("OL-ADD wrong hash: %s\n", o.additions_refused.c_str());
    AddRound none;
    none.ops.push_back({2, {-99, -99, -99, -98, -98, -98, 1.0}});
    Bars x = base.bars;
    CHECK(!apply_add_round(x, dom, none, c, nullptr, &why) && why.find("not in the lattice") != std::string::npos);
    AddRound unknown;
    unknown.ops.push_back({3, {0.0}});
    CHECK(!apply_add_round(x, dom, unknown, c, nullptr, &why) && why.find("kind 3") != std::string::npos);
  }
}

int main() {
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
  std::printf("%d checks, %d failed\n", g_checks, g_fail);
  return g_fail ? 1 : 0;
}
