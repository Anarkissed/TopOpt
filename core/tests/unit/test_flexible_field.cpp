// F6, F7, F8 and the handover of task 2026-09-28-flexible-squish-maths: squish maps,
// target -> clamped -> buildable, stamps (design and check), the 3D density field,
// stack conflicts (one profile per stack) and the handover between axes.

#include "topopt/flexible/curve.hpp"
#include "topopt/flexible/field.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#include "flexible_test_boxes.hpp"

using namespace topopt;
using namespace topopt::flexible;
using flexible_test::box;
using flexible_test::one_region_per_face;
using flexible_test::region;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                            \
  do {                                                              \
    ++g_checks;                                                     \
    if (!(cond)) {                                                  \
      ++g_failures;                                                 \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg);  \
    }                                                               \
  } while (0)

static bool near(double a, double b, double rel, double abs_tol = 1e-12) {
  return std::fabs(a - b) <= rel * std::max(std::fabs(a), std::fabs(b)) + abs_tol;
}

static const FlexibleData& data() {
  static FlexibleData d = load_flexible_data(FLEXIBLE_MATERIALS_JSON_PATH);
  return d;
}
static CurveSet set220() { return curve_set(data(), "varioshore_tpu", 220, "gyroid").set; }
static const Vec3 kZ{0, 0, 1};

static std::vector<char> all_solid(const VoxelGrid& g) {
  std::vector<char> m(g.voxel_count(), 0);
  for (std::size_t i = 0; i < g.tags.size(); ++i) m[i] = g.tags[i] != VoxelTag::Empty;
  return m;
}

struct Pad {
  StepModel model = box(100, 100, 20);
  VoxelGrid grid = voxelize(model.mesh, 100);
  std::vector<ResolvedFaceRegion> regions = resolve_face_regions(model, one_region_per_face());
  std::vector<char> lattice = all_solid(grid);
  Stack top = build_stack(model, region(regions, 101), regions, grid, lattice, 0, kZ, 1.0);
};

static SquishMap map_both(double d, std::vector<double> xx, std::vector<double> xy) {
  SquishMap m;
  m.mode = "both";
  m.x_x = xx;
  m.x_y = xy;
  m.y_x = xx;
  m.y_y = xy;
  m.deepest_squish_mm = d;
  return m;
}

static const BuildParams kGyroid1{"gyroid", 1, 0.42};

static void test_maps(const Pad& p) {
  SquishMap m = map_both(4, {0, 0.5, 1}, {0.2, 1, 0.2});
  const std::vector<double> s = squish_fraction(p.top, m);
  const PenCurve X({0, 0.5, 1}, {0.2, 1, 0.2});
  bool exact = s.size() == p.top.columns.size();
  for (std::size_t i = 0; exact && i < s.size(); ++i) {
    const StackColumn& c = p.top.columns[i];
    exact = s[i] == X(c.u_mm / p.top.frame.u_extent_mm) * X(c.v_mm / p.top.frame.v_extent_mm);
  }
  CHECK(exact, "both: S = X(u)·Y(v) at every column");
  m.mode = "either";
  m.y_y = {1, 0.1, 1};
  const std::vector<double> e = squish_fraction(p.top, m);
  const PenCurve Y({0, 0.5, 1}, {1, 0.1, 1});
  exact = true;
  for (std::size_t i = 0; exact && i < e.size(); ++i) {
    const StackColumn& c = p.top.columns[i];
    exact = e[i] == std::max(X(c.u_mm / 100.0), Y(c.v_mm / 100.0));
  }
  CHECK(exact, "either: S = max(X(u), Y(v))");

  const std::vector<double> t = edge_fraction(p.top);
  double tmax = 0.0, tmin = 1.0;
  for (double v : t) {
    tmax = std::max(tmax, v);
    tmin = std::min(tmin, v);
  }
  CHECK(tmax == 1.0, "centre->edge: t = 1 at the most-inside column");
  const int corner = p.top.column_at(0, 50), mid = p.top.column_at(49, 49);
  CHECK(near(t[static_cast<std::size_t>(corner)], 0.5 / 49.5, 1e-12),
        "an edge column is half a pitch from the boundary");
  CHECK(near(t[static_cast<std::size_t>(mid)], 1.0, 1e-12), "the centre column is t = 1");
  SquishMap c;
  c.mode = "centre_edge";
  c.c_x = {0, 1};
  c.c_y = {1, 0};
  c.deepest_squish_mm = 3;
  const std::vector<double> ce = squish_fraction(p.top, c);
  exact = true;
  for (std::size_t i = 0; exact && i < ce.size(); ++i) exact = near(ce[i], 1.0 - t[i], 1e-12);
  CHECK(exact, "centre->edge: S = C(t) (edges soft here)");

  bool threw = false;
  try {
    SquishMap bad = m;
    bad.mode = "diagonal";
    squish_fraction(p.top, bad);
  } catch (const FlexibleError&) {
    threw = true;
  }
  CHECK(threw, "an unknown mode is refused");
  threw = false;
  try {
    SquishMap bad = m;
    bad.x_x = {0, 0.6, 0.5, 1};
    bad.x_y = {0, 1, 1, 0};
    squish_fraction(p.top, bad);
  } catch (const FlexibleError&) {
    threw = true;
  }
  CHECK(threw, "a bad pen curve is refused");
}

static void test_design(const Pad& p) {
  const CurveSet s = set220();
  const TierBand tier = tier_band(data().catalogue.error_bands, s.tier, false, 1);
  const double W = 30 * 9.81;  // 30 kg
  // A flat map: every column wants 2 mm. Buildable must EQUAL target (a Gaussian of
  // a constant is the constant).
  const FaceDesign flat = design_face(s, p.top, map_both(4, {0, 1}, {0.5, 0.5}), W, nullptr,
                                      kGyroid1, tier);
  CHECK(flat.columns.size() == p.top.columns.size(), "one design per column");
  CHECK(flat.ok == static_cast<int>(flat.columns.size()), "a reachable flat map: all ok");
  CHECK(near(flat.design_pressure_even_mpa, W / 10000.0, 1e-12), "even pressure = W / A");
  bool same = true, consistent = true;
  for (const ColumnDesign& c : flat.columns) {
    if (!near(c.target_depth_mm, 1.0, 1e-12)) same = false;  // S = 0.5·0.5 = 0.25 of 4
    if (!near(c.buildable_density, c.target_density, 1e-12) ||
        !near(c.buildable_depth_mm, c.target_depth_mm, 1e-9))
      same = false;
    const StressResult sr = stress_at(s, c.target_strain, c.target_density);
    if (!sr.ok || !near(sr.stress_mpa, c.pressure_mpa, 1e-9)) consistent = false;
  }
  CHECK(same, "flat map: buildable == target exactly");
  CHECK(consistent, "the target density carries the design pressure at the target strain");
  CHECK(flat.tier.tier == "literature" && flat.tier.band == 0.40, "literature ±40 %");
  CHECK(flat.max_smoothing_change_mm < 1e-9, "no smoothing change on a flat map");

  // Centre-soft: target varies; buildable is the clamped density smoothed.
  const FaceDesign cs = design_face(s, p.top, map_both(4, {0, 0.5, 1}, {0.45, 1, 0.45}), W,
                                    nullptr, kGyroid1, tier);
  CHECK(cs.ok == static_cast<int>(cs.columns.size()), "centre-soft 1.2..4 mm is reachable");
  bool bounded = true, sig = true, fwd = true;
  for (const ColumnDesign& c : cs.columns) {
    if (c.buildable_density < s.density_min() - 1e-12 ||
        c.buildable_density > s.density_max() + 1e-12)
      bounded = false;
    if (!near(c.sigma_mm, 0.5 * cell_size_mm("gyroid", c.clamped_density, 1, 0.42), 1e-12))
      sig = false;
    const StrainResult f = strain_under(s, c.pressure_mpa, c.buildable_density);
    if (!f.ok || !near(c.buildable_depth_mm, f.strain * c.height_mm, 1e-9)) fwd = false;
    if (!near(c.cell_mm, cell_size_mm("gyroid", c.buildable_density, 1, 0.42), 1e-12))
      sig = false;
  }
  CHECK(bounded, "buildable density stays inside the table");
  CHECK(sig, "σ = half the local cell (gyroid L = 3.0915 t / ρ)");
  CHECK(fwd, "buildable depth = the forward solve at the buildable density");
  CHECK(cs.max_smoothing_change_mm > 0.0, "a graded map is changed by smoothing");
  const int centre = p.top.column_at(50, 50), edge = p.top.column_at(0, 0);
  CHECK(cs.columns[static_cast<std::size_t>(centre)].buildable_depth_mm >
            cs.columns[static_cast<std::size_t>(edge)].buildable_depth_mm + 1.0,
        "the centre stays softer than the corner after smoothing");
  CHECK(cs.material_volume_mm3 > 0.0 && cs.near_edge >= 0, "volume and edge counts reported");

  // Clamping: each way the data runs out.
  FaceDesign d = design_face(s, p.top, map_both(8, {0, 1}, {1, 1}), W, nullptr, kGyroid1, tier);
  CHECK(d.beyond_data == static_cast<int>(d.columns.size()), "8 mm of 20 is past 0.25: beyond");
  CHECK(d.columns[0].clamped_density == s.density_min(),
        "beyond the data clamps to the strain limit (here: the softest row)");
  d = design_face(s, p.top, map_both(0.1, {0, 1}, {1, 1}), W, nullptr, kGyroid1, tier);
  CHECK(d.too_soft == static_cast<int>(d.columns.size()), "0.1 mm under 30 kg: too soft");
  const StrainResult firm = strain_under(s, W / 10000.0, s.density_max());
  CHECK(d.columns[0].clamped_density == s.density_max() && d.columns[0].nearest_known &&
            near(d.columns[0].nearest_depth_mm, firm.strain * d.columns[0].height_mm, 1e-9),
        "too soft clamps to the firmest, and reports its depth as the nearest achievable");
  d = design_face(s, p.top, map_both(4, {0, 1}, {1, 1}), 10.0, nullptr, kGyroid1, tier);
  CHECK(d.too_firm == static_cast<int>(d.columns.size()), "4 mm under 1 kg: too firm");
  CHECK(d.columns[0].clamped_density == s.density_min(), "too firm clamps to the softest");

  // A design stamp: its pressure under it, the even spread elsewhere; force conserved.
  StampGrid st;
  st.name = "square";
  st.origin_u_mm = 40;
  st.origin_v_mm = 40;
  st.cell_mm = 0.5;
  st.nu = st.nv = 40;  // 20 x 20 mm
  st.values_mpa.assign(1600, 0.05);
  st.force_n = 0.05 * 400;
  const FaceDesign ds = design_face(s, p.top, map_both(4, {0, 0.5, 1}, {0.45, 1, 0.45}), W, &st,
                                    kGyroid1, tier);
  CHECK(ds.design_stamp_used && !ds.design_stamp_rigid_averaged, "the design stamp is used");
  double under = 0.0;
  int outside_even = 0, outside = 0;
  for (std::size_t i = 0; i < ds.columns.size(); ++i) {
    const StackColumn& c = p.top.columns[i];
    const bool in = c.u_mm > 40 && c.u_mm < 60 && c.v_mm > 40 && c.v_mm < 60;
    if (in) under += ds.columns[i].pressure_mpa * c.area_mm2;
    if (!in) {
      ++outside;
      if (near(ds.columns[i].pressure_mpa, W / 10000.0, 1e-12)) ++outside_even;
    }
  }
  CHECK(near(under, 20.0, 1e-9), "the stamp's 20 N lands under it");
  CHECK(outside_even == outside, "outside the stamp: the weight spread evenly");

  // B3: a stamp covering a quarter of a column adds to that column's even-spread share of
  // the rest; it does not replace the whole column's load with a sliver.
  {
    StampGrid q;
    q.name = "corner";
    q.origin_u_mm = 40;
    q.origin_v_mm = 40;
    q.cell_mm = 0.5;
    q.nu = q.nv = 1;
    q.values_mpa = {1e-4};
    q.force_n = 1e-4 * 0.25;
    const FaceDesign dq = design_face(s, p.top, map_both(1, {0, 1}, {1, 1}), W, &q, kGyroid1, tier);
    const int kk = p.top.column_at(40, 40);  // the column over u 40..41, v 40..41
    CHECK(near(dq.columns[static_cast<std::size_t>(kk)].pressure_mpa, 1e-4 * 0.25 + (W / 10000.0) * 0.75, 1e-12),
          "B3: p = stamp average + even x (1 - covered / area)");
  }
  // B1 (design): a rigid design stamp half off the face reads the STATED force over the
  // area that lands, and says some of it missed.
  {
    StampGrid rd = st;
    rd.origin_u_mm = 90;
    rd.rigid = true;
    const FaceDesign dr = design_face(s, p.top, map_both(4, {0, 1}, {1, 1}), W, &rd, kGyroid1, tier);
    const int k = p.top.column_at(95, 50);
    CHECK(near(dr.columns[static_cast<std::size_t>(k)].pressure_mpa, 20.0 / 200.0, 1e-12) &&
              dr.design_stamp_off_face,
          "B1: rigid design stamp half off: 20 N over the 200 mm2 on the face, flagged");
  }
  // H1: a column whose nearest achievable depth is itself past the data carries NO depth
  // (NaN), never a placeholder.
  {
    const FaceDesign dh = design_face(s, p.top, map_both(0.1, {0, 1}, {1, 1}), 5.0e4, nullptr, kGyroid1, tier);
    const ColumnDesign& c0 = dh.columns[0];
    CHECK(c0.status == "too_soft" && !c0.nearest_known && std::isnan(c0.clamped_depth_mm),
          "H1: unknown nearest depth is NaN, not 0.25 x h");
  }
}

static void test_stamps(const Pad& p) {
  StampGrid st;
  st.name = "sq";
  st.origin_u_mm = 30;
  st.origin_v_mm = 30;
  st.cell_mm = 1;
  st.nu = st.nv = 20;
  st.values_mpa.assign(400, 0.02);
  st.force_n = 8.0;
  CHECK(stamp_grid_error(st).empty() && near(stamp_force_n(st), 8.0, 1e-12), "a valid stamp");
  st.force_n = 8.0 * 1.006;
  CHECK(!stamp_grid_error(st).empty(), "0.6 % force mismatch refused");
  st.force_n = 8.0 * 1.004;
  CHECK(stamp_grid_error(st).empty(), "0.4 % mismatch accepted");
  st.force_n = 8.0;
  st.values_mpa[5] = -0.01;
  CHECK(!stamp_grid_error(st).empty(), "a negative pressure refused");
  st.values_mpa[5] = 0.02;
  st.values_mpa.pop_back();
  CHECK(!stamp_grid_error(st).empty(), "a grid of the wrong size refused");
  st.values_mpa.push_back(0.02);
  CHECK(std::fabs(stamp_width_mm(st) - 20.0) <= st.cell_mm + 1e-12,
        "a 20 mm square is 20 mm wide, to one stamp cell");

  // Check mode on a uniform lattice: every fully covered column sinks by the
  // forward solve at 0.02 MPa.
  const CurveSet s = set220();
  const TierBand tier = tier_band(data().catalogue.error_bands, s.tier, false, 1);
  const std::vector<double> rho(p.top.columns.size(), 0.2);
  StampCheck c = check_stamp(s, p.top, rho, st, kGyroid1, tier);
  const double h = p.top.columns[0].lattice_mm;
  const double expect = strain_under(s, 0.02, 0.2).strain * h;
  CHECK(c.ok && c.pressed_columns == 400, "a 20 x 20 soft stamp presses 400 columns");
  bool all = true;
  for (std::size_t i = 0; i < c.depth_mm.size(); ++i)
    if (c.depth_mm[i] >= 0.0 && !near(c.depth_mm[i], expect, 1e-9)) all = false;
  CHECK(all && near(c.max_depth_mm, expect, 1e-9), "soft: depth = forward(p) × h per column");
  const double cell = cell_size_mm("gyroid", 0.2, 1, 0.42);
  CHECK(near(c.local_cell_mm, cell, 1e-12) && c.narrow == (c.stamp_width_mm < 3 * cell),
        "narrow iff the stamp is under 3 local cells");
  // A 10 mm stamp is narrow (3 cells of 6.5 mm = 19.5 mm).
  StampGrid small = st;
  small.nu = small.nv = 10;
  small.values_mpa.assign(100, 0.02);
  small.force_n = 2.0;
  CHECK(check_stamp(s, p.top, rho, small, kGyroid1, tier).narrow, "a 10 mm stamp is flagged");
  // Rigid: the whole footprint sinks by one depth.
  StampGrid rig = st;
  rig.rigid = true;
  c = check_stamp(s, p.top, rho, rig, kGyroid1, tier);
  CHECK(c.ok && near(c.rigid_depth_mm, expect, 1e-9), "rigid on uniform lattice = soft depth");
  // A rigid stamp only part-covering its edge columns: each column takes the stamp
  // over the area it covers, so the depth is the soft depth at the stamp's pressure.
  {
    StampGrid half = st;
    half.origin_u_mm = 30.5;
    half.origin_v_mm = 30.5;
    half.rigid = true;
    c = check_stamp(s, p.top, rho, half, kGyroid1, tier);
    CHECK(c.ok && near(c.rigid_depth_mm, expect, 1e-9),
          "rigid over part-covered columns: the covered area carries the stamp");
  }
  // A rigid stamp partly on solid (no lattice) is refused, not sunk into the lattice.
  {
    std::vector<double> some = rho;
    for (std::size_t k = 0; k < some.size(); ++k)
      if (p.top.columns[k].u_mm < 40) some[k] = 0.0;
    StampGrid r2 = st;
    r2.rigid = true;
    c = check_stamp(s, p.top, some, r2, kGyroid1, tier);
    CHECK(!c.ok && c.refusal.code == "rigid_over_solid", "a rigid stamp on solid is refused");
  }
  // A rigid press past the data is refused, named.
  rig.values_mpa.assign(400, 2.0);
  rig.force_n = 800.0;
  c = check_stamp(s, p.top, rho, rig, kGyroid1, tier);
  CHECK(!c.ok && c.refusal.code == "beyond_data", "a rigid press past the data is refused");
  // A soft press past the data flags its columns.
  StampGrid hard = st;
  hard.values_mpa.assign(400, 2.0);
  hard.force_n = 800.0;
  c = check_stamp(s, p.top, rho, hard, kGyroid1, tier);
  CHECK(c.ok && c.beyond_data_columns == 400, "soft past the data: every column flagged");
  // A stamp hanging off the face reports the force that missed it.
  StampGrid off = st;
  off.origin_u_mm = 90;
  c = check_stamp(s, p.top, rho, off, kGyroid1, tier);
  CHECK(near(c.force_off_face_n, 4.0, 1e-9) && c.off_face, "half the stamp off the face: 4 N missed, flagged");
  // B1: a RIGID plate half off the face still carries its whole 8 N, on the 200 mm2
  // that lands: never a quietly lighter load.
  {
    StampGrid roff = off;
    roff.rigid = true;
    c = check_stamp(s, p.top, rho, roff, kGyroid1, tier);
    const double full = strain_under(s, 8.0 / 200.0, 0.2).strain * h;
    CHECK(c.ok && near(c.rigid_depth_mm, full, 1e-9) && c.off_face && near(c.force_off_face_n, 4.0, 1e-9),
          "B1: rigid half off the face: the stated 8 N on the covered 200 mm2, flagged off-face");
  }
}

// B5: two sectors of ONE face, side by side (same axis, footprints not overlapping), are
// not a one-profile-per-stack conflict, whatever the pitch or the cut position.
static void test_side_by_side_sectors() {
  StepModel m = box(100, 60, 20);
  const VoxelGrid g = voxelize(m.mesh, 73);
  std::vector<FaceRegionSpec> sp = one_region_per_face();
  FaceRegionSpec a, b;
  a.id = 200;
  a.add = {1};
  a.cuts = {RegionCut{{41, 0, 0}, {-1, 0, 0}, true}};
  b.id = 201;
  b.add = {1};
  b.cuts = {RegionCut{{41, 0, 0}, {1, 0, 0}, false}};
  sp.push_back(a);
  sp.push_back(b);
  const std::vector<ResolvedFaceRegion> rs = resolve_face_regions(m, sp);
  const std::vector<char> lat = all_solid(g);
  const Stack sa = build_stack(m, region(rs, 200), rs, g, lat, 0, kZ, g.spacing);
  const Stack sb = build_stack(m, region(rs, 201), rs, g, lat, 0, kZ, g.spacing);
  const std::vector<StackConflict> cf = find_stack_conflicts(g, lat, {&sa, &sb});
  CHECK(cf.empty(), "B5: side-by-side sectors (cut at x = 41, resolution 73) are not a conflict");
  const Stack bottom = build_stack(m, region(rs, 100), rs, g, lat, 0, kZ, g.spacing);
  CHECK(find_stack_conflicts(g, lat, {&sa, &bottom}).size() == 1, "... a sector over a loaded bottom still is");
}

static void test_field_and_handover() {
  StepModel m = box(100, 100, 60);
  const VoxelGrid g = voxelize(m.mesh, 50);  // 2 mm voxels
  const std::vector<ResolvedFaceRegion> rs = resolve_face_regions(m, one_region_per_face());
  const std::vector<char> lat = all_solid(g);
  const Stack top = build_stack(m, region(rs, 101), rs, g, lat, 0, kZ, 2.0);
  const Stack side = build_stack(m, region(rs, 103), rs, g, lat, 0, kZ, 2.0);
  const Stack bottom = build_stack(m, region(rs, 100), rs, g, lat, 0, kZ, 2.0);

  // One profile per stack: top + bottom push the same material along Z.
  std::vector<StackConflict> cf = find_stack_conflicts(g, lat, {&top, &bottom});
  CHECK(cf.size() == 1 && ((cf[0].face_a == 101 && cf[0].face_b == 100) ||
                           (cf[0].face_a == 100 && cf[0].face_b == 101)),
        "top + bottom loaded: a conflict naming both");
  CHECK(!cf.empty() && near(cf[0].overlap_mm3, 100.0 * 100 * 60, 0.02),
        "... over the whole block");
  cf = find_stack_conflicts(g, lat, {&top, &side});
  CHECK(cf.empty(), "top + side are different axes: no conflict");

  const CurveSet s = set220();
  const TierBand tier = tier_band(data().catalogue.error_bands, s.tier, false, 1);
  const FaceDesign dt =
      design_face(s, top, map_both(6, {0, 1}, {1, 1}), 60 * 9.81, nullptr, kGyroid1, tier);
  const TierBand side_tier = tier_band(data().catalogue.error_bands, s.tier, true, 1);
  CHECK(side_tier.tier == "estimated", "the side stack is estimated");
  const FaceDesign dsd =
      design_face(s, side, map_both(10, {0, 1}, {1, 1}), 25 * 9.81, nullptr, kGyroid1, side_tier);
  CHECK(dt.ok > 0 && dsd.ok > 0, "both faces reachable");
  const double rt = dt.columns[0].buildable_density, rsd = dsd.columns[0].buildable_density;
  CHECK(std::fabs(rt - rsd) > 0.02, "the two faces want different densities");

  const DensityField f = assemble_density_field(g, lat, {{&top, &dt}, {&side, &dsd}}, kGyroid1);
  CHECK(f.lattice_voxels == static_cast<long long>(g.solid_count()), "every solid voxel is lattice");
  CHECK(f.unassigned_voxels == 0, "every lattice voxel sits under a loaded stack");
  CHECK(f.handovers.size() == 1 && f.handovers[0].overlap_mm3 > 0.0 &&
            f.handovers[0].blended_mm3 > 0.0 &&
            f.handovers[0].blended_mm3 < f.handovers[0].overlap_mm3,
        "one handover pair, with a blended band inside the overlap");
  // Near the top, far from the side: the top's density. Near the side, far from the
  // top: the side's. Equidistant: the average.
  auto at = [&](double x, double y, double z) {
    const int i = static_cast<int>((x - g.origin.x) / g.spacing);
    const int j = static_cast<int>((y - g.origin.y) / g.spacing);
    const int k = static_cast<int>((z - g.origin.z) / g.spacing);
    return g.index(i, j, k);
  };
  CHECK(near(f.density[at(11, 51, 59)], rt, 1e-12) && f.owner[at(11, 51, 59)] == 101,
        "just under the top, far from the side: the top's density");
  CHECK(near(f.density[at(99, 51, 11)], rsd, 1e-12) && f.owner[at(99, 51, 11)] == 103,
        "just inside the side, far from the top: the side's density");
  CHECK(near(f.density[at(69, 51, 29)], 0.5 * (rt + rsd), 1e-9),
        "equidistant from both faces: the average");
  {
    // The blend's WIDTH: 4 mm nearer the top than the side, w = 0.5 + 4 / (2 L) with L
    // one cell of the larger local cell size (R11).
    const double L = std::max(cell_size_mm("gyroid", rt, 1, 0.42), cell_size_mm("gyroid", rsd, 1, 0.42));
    // Across the boundary (the plane d_top = d_side) the distance is (d_B - d_A) / |l_A - l_B|
    // = 4 / sqrt(2) mm here; one cell L of blend measured ACROSS it (review H3).
    const double w = 0.5 + 4.0 / (L * std::sqrt(2.0));
    CHECK(near(f.density[at(65, 51, 29)], w * rt + (1 - w) * rsd, 1e-9),
          "H3: the blend is one cell wide measured across the boundary");
  }
  // Density is between the two everywhere in the overlap.
  bool between = true;
  for (std::size_t i = 0; i < f.density.size(); ++i)
    if (f.density[i] > 0.0 &&
        (f.density[i] < std::min(rt, rsd) - 1e-12 || f.density[i] > std::max(rt, rsd) + 1e-12))
      between = false;
  CHECK(between, "the blend never leaves the two faces' densities");

  bool threw = false;
  try {
    assemble_density_field(g, lat, {{&top, &dt}, {&bottom, &dt}}, kGyroid1);
  } catch (const FlexibleError&) {
    threw = true;
  }
  CHECK(threw, "assembling a conflicting pair throws");
}

int main() {
  const Pad p;
  test_maps(p);
  test_design(p);
  test_stamps(p);
  test_field_and_handover();
  test_side_by_side_sectors();
  std::printf("test_flexible_field: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
