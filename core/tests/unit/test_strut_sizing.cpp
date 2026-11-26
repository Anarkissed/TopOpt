// notes30 STRUCTURAL AUTO (his 11-24 vision: "work backwards from the amount the user wants to beat the load capacity and
// guess at the best possible settings for the least possible plastic to get that requirement (150/175/200%)"; his 11-26
// decisions: D1 the target is the part's own Safety margin, D2 "If all else fails, you can quilt, but get as thin as
// possible - do not go to straight full quilt").
//
// What is pinned, and why:
//   §1 THE LAW TURNED ROUND, against the law itself, for every type with a measured law (the 7 strut types and the 2
//      sheets: 9), on a grid of stresses (von Mises x pressure, the pure-pressure voxel with vm 0 among them), two build
//      directions (a cube axis, and off-axis: the cross term) and the three targets he named (150 / 175 / 200 %):
//        * the margin the FORWARD law (strut_law_margin_at, the check's formula) gives at the returned density reaches the
//          target, and within 1 % of it unless the floor set it (the lightest, not merely a passing one);
//        * it stays at or over the target at every heavier density up to the ceiling (a heavier cell never fails);
//        * just under it the target is not reached (nothing lighter would do), unless the floor set it;
//        * never lighter for a higher target or a higher stress; octet never under 0.10 (its bulk-only row);
//        * short_of_target exactly when the ceiling's own margin is under the target;
//        * the ratio lays the density the check credits (lattice_density_from_strut reaches it; a hair less does not).
//      The three tetragonal types (no law) are refused, naming the type.
//      RED control: today's Structural Auto ramp (reference = printed yield / margin, 19 MPa for PA12 at 150 %; the
//      thinnest strut at no stress, the open look at the reference) fails the same check on loaded voxels.
//   §2 The field form (what the app calls) agrees with the voxel form: its ratio is the voxel's or one table step over,
//      never under; its density the voxel's; the summary's counts.
//   §3 THE LAY (demand_is_ratio): on a wing plate, a field asking one ratio lays that ratio in every cell (held only by
//      the thinnest strut); a ratio past the quilt-off limit is held at the limit with quilt_where_short off, and with it
//      on (D2) laid as asked — past the limit, never at the touch — in exactly those cells, the cells themselves the same
//      as without it; quilt_where_short alone (no demand_is_ratio) changes nothing. RED control: the same field read as
//      a stress over a reference (today's By stress) does not lay the asked ratio.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#include "topopt/lattice.hpp"
#include "topopt/lattice_layout.hpp"
#include "topopt/strut_strength.hpp"

using namespace topopt;
using namespace topopt::lattice_layout;

static int g_fail = 0, g_checks = 0;
#define CHECK(cond)                                                                            \
  do {                                                                                         \
    ++g_checks;                                                                                \
    if (!(cond)) { ++g_fail; std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); }     \
  } while (0)

namespace {

const LatticeTopology kLawTypes[] = {LatticeTopology::Octet,   LatticeTopology::SimpleCubic, LatticeTopology::Bcc,
                                     LatticeTopology::Fcc,     LatticeTopology::Diamond,     LatticeTopology::Kelvin,
                                     LatticeTopology::Rhombic, LatticeTopology::Gyroid,      LatticeTopology::SchwarzD};
const LatticeTopology kStrutTypes[] = {LatticeTopology::Octet,   LatticeTopology::SimpleCubic, LatticeTopology::Bcc,
                                       LatticeTopology::Fcc,     LatticeTopology::Diamond,     LatticeTopology::Kelvin,
                                       LatticeTopology::Rhombic};

// PA12 as the app's materials state it (yield 38 MPa, the layer factor 0.75 the check divides the interlayer margin by).
constexpr double kYield = 38.0, kZk = 0.75;

// Today's Structural Auto ramp (the RED control): reference = printed yield / margin; f = vm / reference held to 0..1;
// ratio = thinnest + f (open look - thinnest) on an 8 mm cell with two 0.45 mm lines.
double ramp_ratio(double vm, double target) {
  const double reference = kYield * kZk / target;
  const double f = std::clamp(vm / reference, 0.0, 1.0);
  const double thin = 0.9 / 8.0, open = kLatticeOpenLookStrutPerCell;
  return thin + f * (open - thin);
}

double density_of(LatticeTopology t, double ratio) {
  try { return lattice_density_from_strut(t, 1.0, 0.5 * ratio); } catch (const std::exception&) { return 1.0; }
}

void test_law_turned_round() {
  const double vms[] = {0.0, 0.05, 0.2, 0.5, 1.0, 2.0, 4.0, 8.0};
  const double ps[] = {0.0, 0.1, 0.5, 2.0};
  const Vec3 dirs[] = {{0, 0, 1}, {1, 1, 2}};
  const double targets[] = {1.5, 1.75, 2.0};
  std::size_t sized = 0, floored = 0, shorts = 0, control_fails = 0, control_loaded = 0;
  for (LatticeTopology t : kLawTypes) {
    const double lo = strut_sizing_rho_floor(t), hi = strut_sizing_rho_ceiling(t);
    CHECK(lo > 0.0 && hi >= lo);
    if (t == LatticeTopology::Octet) CHECK(lo >= 0.10 - 1e-12);
    for (const Vec3& d : dirs)
      for (double vm : vms)
        for (double p : ps) {
          if (vm == 0.0 && p == 0.0) {
            const StrutLawSize s = strut_size_for_margin(t, 0, 0, d, kYield, kZk, 1.5);
            CHECK(s.at_floor && s.rho == lo && !s.short_of_target);   // nothing loads it: the floor
            continue;
          }
          double last_rho = 0.0;
          for (double target : targets) {
            const StrutLawSize s = strut_size_for_margin(t, vm, p, d, kYield, kZk, target);
            ++sized;
            const double m = strut_law_margin_at(t, s.rho, vm, p, d, kYield, kZk);
            CHECK(s.rho >= lo - 1e-12 && s.rho <= hi + 1e-12);
            CHECK(s.rho >= last_rho - 1e-12);   // a higher target: never lighter
            last_rho = s.rho;
            const bool ceiling_short = strut_law_margin_at(t, hi, vm, p, d, kYield, kZk) < target;
            CHECK(s.short_of_target == ceiling_short);
            if (s.short_of_target) { ++shorts; CHECK(s.rho == hi); continue; }
            CHECK(m >= target * (1.0 - 1e-9));
            if (s.at_floor) ++floored;
            else {
              CHECK(m <= target * 1.01);   // the lightest, not merely a passing one
              CHECK(strut_law_margin_at(t, s.rho - 1e-6, vm, p, d, kYield, kZk) < target);
            }
            for (int k = 1; k <= 40; ++k) {   // it stays: every heavier density up to the ceiling holds
              const double r = s.rho + (hi - s.rho) * k / 40.0;
              if (strut_law_margin_at(t, r, vm, p, d, kYield, kZk) < target * (1.0 - 1e-9)) {
                CHECK(false);
                std::printf("  %s vm %.3g p %.3g target %.2f: rho %.5f holds but %.5f does not\n",
                            lattice_topology_name(t), vm, p, target, s.rho, r);
                break;
              }
            }
            // a higher stress: never lighter
            const StrutLawSize s2 = strut_size_for_margin(t, vm * 1.5, p * 1.5, d, kYield, kZk, target);
            CHECK(s2.rho >= s.rho - 1e-12);
            // the ratio lays the density the check credits; a hair less does not (unless held at the touch)
            if (t != LatticeTopology::Gyroid && t != LatticeTopology::SchwarzD) {
              const double touch = lattice_width_bounds(t).touch;
              CHECK(s.ratio <= touch + 1e-12);
              if (s.ratio < touch - 1e-9) {
                CHECK(density_of(t, s.ratio) >= s.rho * (1.0 - 1e-6));
                CHECK(density_of(t, s.ratio - 1e-6) < s.rho);
              }
            }
            // RED control (strut types, the cube axis, 150 %): today's ramp ratio does not give this margin
            if (target == 1.5 && d.z == 1.0 && d.x == 0.0 && t != LatticeTopology::Gyroid &&
                t != LatticeTopology::SchwarzD && vm > 0.0) {
              ++control_loaded;
              // the same predicate the sizing passes: the target reached, and the lightest unless at the floor
              const double rr = std::clamp(density_of(t, ramp_ratio(vm, 1.5)), lo, hi);
              const double mr = strut_law_margin_at(t, rr, vm, p, d, kYield, kZk);
              const bool passes = mr >= target * (1.0 - 1e-9) && (rr <= lo + 1e-12 || mr <= target * 1.01);
              if (!passes) ++control_fails;
            }
          }
        }
  }
  for (LatticeTopology t : {LatticeTopology::Bccz, LatticeTopology::Fccz, LatticeTopology::Reentrant}) {
    bool threw = false;
    try { (void)strut_size_for_margin(t, 1, 0, {0, 0, 1}, kYield, kZk, 1.5); } catch (const std::invalid_argument& e) {
      threw = std::string(e.what()).find(lattice_topology_name(t)) != std::string::npos;
    }
    CHECK(threw);
  }
  std::printf("[§1] %zu sizings over 9 types (the lightest that holds, every heavier one holding): %zu at the floor, %zu "
              "short even at the ceiling; RED control (today's ramp) misses the target on %zu of %zu loaded voxels\n",
              sized, floored, shorts, control_fails, control_loaded);
  CHECK(sized > 0 && control_loaded > 0);
  CHECK(control_fails * 2 >= control_loaded);   // the check fails today's ramp on most loaded voxels (all but the lightest)
}

void test_field_form() {
  std::size_t compared = 0;
  for (LatticeTopology t : kStrutTypes) {
    std::vector<double> tensor;
    // a strip of states: tension, shear, pure pressure, nothing
    for (int i = 0; i < 64; ++i) {
      const double a = 0.05 * i;
      tensor.insert(tensor.end(), {a, 0.2 * a, -0.1 * a, 0.3 * a, 0.0, 0.05 * a});
    }
    tensor.insert(tensor.end(), {1.0, 1.0, 1.0, 0, 0, 0});   // pure pressure: vm 0, the struts still load
    tensor.insert(tensor.end(), {0, 0, 0, 0, 0, 0});
    const std::size_t n = tensor.size() / 6;
    std::vector<float> ratio(n), rho(n);
    std::vector<unsigned char> sh(n);
    const Vec3 up{0.2, 0.1, 1.0};
    const StrutLawSizeSummary sum =
        strut_size_field(t, tensor.data(), tensor.size(), up, kYield, kZk, 1.75, ratio.data(), rho.data(), sh.data());
    CHECK(sum.voxels == n && sum.loaded == n - 1);
    const double step_rho = (sum.rho_ceiling - sum.rho_floor) / kStrutSizingTableSteps;
    std::size_t shorts = 0;
    for (std::size_t e = 0; e < n; ++e) {
      const double* s = tensor.data() + 6 * e;
      const double vm = std::sqrt(0.5 * ((s[0] - s[1]) * (s[0] - s[1]) + (s[1] - s[2]) * (s[1] - s[2]) +
                                         (s[2] - s[0]) * (s[2] - s[0])) +
                                  3.0 * (s[3] * s[3] + s[4] * s[4] + s[5] * s[5]));
      const double p = (s[0] + s[1] + s[2]) / 3.0;
      const StrutLawSize v = strut_size_for_margin(t, vm, p, up, kYield, kZk, 1.75);
      CHECK(std::fabs(rho[e] - v.rho) <= 1e-6 * std::max(1.0, v.rho));
      CHECK(ratio[e] >= v.ratio * (1.0 - 1e-7));                       // never under the voxel's own
      CHECK(density_of(t, ratio[e]) <= v.rho + 2.0 * step_rho + 1e-6);   // at most a table step over
      CHECK((sh[e] != 0) == v.short_of_target);
      shorts += sh[e] != 0;
      ++compared;
    }
    CHECK(shorts == sum.short_of_target);
    // the pure-pressure voxel is sized (the two-invariant law), above the floor of the unloaded one
    CHECK(rho[n - 2] >= rho[n - 1]);
    CHECK(rho[n - 1] >= static_cast<float>(sum.rho_floor) * (1.0f - 1e-6f));   // the unloaded voxel: the floor
  }
  std::printf("[§2] the field form against the voxel form: %zu voxels over the 7 strut types\n", compared);
}

// ── §3 the lay ───────────────────────────────────────────────────────────────────────────────────────────────────────
struct ModelBuilder {
  StepModel m;
  int face(Vec3 outward, Vec3 origin) {
    StepFaceInfo f;
    f.kind = StepSurfaceKind::Plane;
    f.plane_normal = outward;
    f.plane_origin = origin;
    m.faces.push_back(f);
    return m.face_count++;
  }
  void tri(int f, Vec3 a, Vec3 b, Vec3 c) {
    const int n = static_cast<int>(m.mesh.vertices.size());
    m.mesh.vertices.insert(m.mesh.vertices.end(), {a, b, c});
    m.mesh.triangles.push_back({n, n + 1, n + 2});
    m.triangle_face.push_back(f);
  }
  void quad(int f, Vec3 a, Vec3 b, Vec3 c, Vec3 d) { tri(f, a, b, c); tri(f, a, c, d); }
};
// A plate 120 x 60 (x, z), 40 thick along y: face 0 is the front (y = 0).
constexpr double kW = 120, kH = 60, kT = 40;
StepModel plate() {
  ModelBuilder b;
  const Vec3 f0{0, 0, 0}, f1{kW, 0, 0}, f2{kW, 0, kH}, f3{0, 0, kH};
  const Vec3 b0{0, kT, 0}, b1{kW, kT, 0}, b2{kW, kT, kH}, b3{0, kT, kH};
  const int front = b.face({0, -1, 0}, f0);
  b.quad(front, f0, f1, f2, f3);
  const int back = b.face({0, 1, 0}, b0);
  b.quad(back, b0, b3, b2, b1);
  const int bottom = b.face({0, 0, -1}, f0);
  b.quad(bottom, f0, b0, b1, f1);
  const int top = b.face({0, 0, 1}, f3);
  b.quad(top, f3, f2, b2, b3);
  const int right = b.face({1, 0, 0}, f1);
  b.quad(right, f1, b1, b2, f2);
  const int left = b.face({-1, 0, 0}, f0);
  b.quad(left, f0, f3, b3, b0);
  b.m.solid_count = 1;
  return b.m;
}
// A field asking `inner` strut / cell in the plate's left half and `outer` in its right half.
std::shared_ptr<DemandField> ratios(double left, double right) {
  auto f = std::make_shared<DemandField>();
  f->origin = {-2, -2, -2};
  f->spacing = 1.0;
  f->nx = static_cast<int>(kW) + 4;
  f->ny = static_cast<int>(kT) + 4;
  f->nz = static_cast<int>(kH) + 4;
  f->mpa.assign(static_cast<std::size_t>(f->nx) * f->ny * f->nz, 0.0f);
  for (int k = 0; k < f->nz; ++k)
    for (int j = 0; j < f->ny; ++j)
      for (int i = 0; i < f->nx; ++i)
        f->mpa[f->index(i, j, k)] = static_cast<float>(f->origin.x + i + 0.5 < kW / 2 ? left : right);
  return f;
}
Settings sized(LatticeTopology t, std::shared_ptr<DemandField> field, bool quilt_short, bool demand_is_ratio = true) {
  Settings st;
  st.bead_mm = 0.45;
  st.min_strut_lines = 2;
  st.rim_mm = -1;
  st.regions = {{1, Role::Lattice, {0}, 30.0, 0.0}};
  st.cells.topology = t;
  st.cells.algorithm = Algorithm::DefaultGrade;
  st.cells.cell_max_mm = 8;
  st.cells.min_cells_across = 1;
  st.struts.mode = Density::ByStress;
  st.struts.demand_is_ratio = demand_is_ratio;
  st.struts.quilt_where_short = quilt_short;
  st.struts.allow_quilt = false;
  st.stress.demand = field;
  st.stress.reference_mpa = 1.0;
  st.stress.response = 1.0;
  return st;
}

void test_the_lay() {
  const StepModel model = plate();
  Session session(model);
  std::size_t types = 0, quilted_types = 0, control_misses = 0;
  for (LatticeTopology t : kStrutTypes) {
    const LatticeWidthBounds b = lattice_width_bounds(t);
    const double line = 0.45, bead = 0.9;
    // a ratio between the thinnest on the largest cell and the open look; and one between the limit and the touch
    const double r_in = std::max(bead / 8.0 + 0.02, 0.5 * (bead / 8.0 + b.open_look));
    const double r_past = b.touch - 0.25 * line / 8.0;   // past the quilt-off limit (touch - line / cell) on an 8 mm cell
    // (a) one ratio everywhere: laid as asked in every cell, held only by the thinnest strut
    {
      const Outcome o = session.lay(sized(t, ratios(r_in, r_in), false));
      std::size_t off = 0;
      for (const Cell& c : o.layout.cells) {
        const double want = std::clamp(r_in * c.size, bead, lattice_quilt_off_strut_mm(t, c.size, line));
        if (std::fabs(c.strut - std::max(bead, want)) > 1e-9) ++off;
      }
      CHECK(!o.layout.cells.empty() && off == 0);
      if (off) std::printf("  %s: %zu of %zu cells not laid as asked\n", lattice_topology_name(t), off, o.layout.cells.size());
      // RED control: the same field read as a stress over a reference (today's By stress): not the asked ratio
      const Outcome c = session.lay(sized(t, ratios(r_in, r_in), false, /*demand_is_ratio=*/false));
      std::size_t same = 0;
      for (const Cell& cell : c.layout.cells)
        if (std::fabs(cell.strut - std::max(bead, r_in * cell.size)) <= 1e-9) ++same;
      control_misses += same < c.layout.cells.size();
    }
    // (b) the right half asks past the quilt-off limit
    const Outcome held = session.lay(sized(t, ratios(r_in, r_past), false));
    const Outcome quilt = session.lay(sized(t, ratios(r_in, r_past), true));
    const Outcome alone = session.lay(sized(t, ratios(r_in, r_past), true, /*demand_is_ratio=*/false));
    const Outcome plain = session.lay(sized(t, ratios(r_in, r_past), false, /*demand_is_ratio=*/false));
    CHECK(held.layout.cells.size() == quilt.layout.cells.size());
    std::size_t past_held = 0, past_quilt = 0, fused = 0, left_changed = 0, cells_moved = 0;
    for (std::size_t i = 0; i < held.layout.cells.size() && i < quilt.layout.cells.size(); ++i) {
      const Cell& h = held.layout.cells[i];
      const Cell& q = quilt.layout.cells[i];
      if (h.size != q.size || h.lo[0] != q.lo[0] || h.lo[1] != q.lo[1] || h.lo[2] != q.lo[2]) ++cells_moved;
      const double limit = lattice_quilt_off_strut_mm(t, h.size, line);
      if (h.strut > limit + 1e-9) ++past_held;
      if (q.strut > limit + 1e-9) {
        ++past_quilt;
        CHECK(std::fabs(q.strut - r_past * q.size) <= 1e-9);   // as asked: the thinnest that reaches it
      } else if (std::fabs(q.strut - h.strut) > 1e-9) {
        ++left_changed;   // a cell not asking past the limit is laid as without D2
      }
      if (q.strut >= b.touch * q.size * (1.0 - 1e-12)) ++fused;
    }
    CHECK(cells_moved == 0 && past_held == 0 && left_changed == 0 && fused == 0);
    CHECK(quilt.struts.quilted_where_short == past_quilt && held.struts.quilted_where_short == 0);
    // quilt_where_short alone (no demand_is_ratio) changes nothing
    bool same = alone.layout.cells.size() == plain.layout.cells.size();
    for (std::size_t i = 0; same && i < alone.layout.cells.size(); ++i)
      same = alone.layout.cells[i].strut == plain.layout.cells[i].strut && alone.layout.cells[i].size == plain.layout.cells[i].size;
    CHECK(same);
    ++types;
    quilted_types += past_quilt > 0;
    std::printf("  %s: %zu cells, %zu laid past the quilt-off limit with D2 (as asked, never fused), 0 without\n",
                lattice_topology_name(t), quilt.layout.cells.size(), past_quilt);
  }
  std::printf("[§3] the sized lay over %zu strut types: as asked in every cell; D2 went past the limit in %zu (only where "
              "asked, the cells unchanged); RED control (read as a stress) missed the asked ratio in %zu\n", types,
              quilted_types, control_misses);
  CHECK(quilted_types == types);
  CHECK(control_misses == types);
}

}  // namespace

int main() {
  test_law_turned_round();
  test_field_form();
  test_the_lay();
  std::printf("%s: %d checks, %d failed\n", g_fail ? "FAIL" : "PASS", g_checks, g_fail);
  return g_fail ? 1 : 0;
}
