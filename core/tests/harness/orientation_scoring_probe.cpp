// orientation_scoring_probe.cpp — IS BUILD ORIENTATION WORTH CHOOSING?
// (task 2026-08-01-orientation-scoring-probe.) PROBE ONLY: not production, not a
// CI test, not wired into anything, and it changes NOTHING. Same discipline as
// lattice_orientation_probe.cpp / lattice_dehomog_probe.cpp — it measures.
//
// THE QUESTION. core/src/orient/orient.cpp has carried candidate generation, the
// support proxy, the interlayer-tension metric AND a combined scorer since
// M4.3/M4.4. The ONLY caller of the scorer is the V5 validation gate; the only
// production callers of the two metrics are inside analyze_fixed_design, which is
// handed ONE build direction. run_job.cpp:648 derives that direction from the
// user's gravity setting, so orientation is an INPUT, never an outcome. This probe
// scores every candidate on six SEPARATE criteria against ONE solved field and
// reports the trade-off, so a GO/NO-GO on wiring a scorer can be made on numbers.
//
// THE CHEAP-SCORING CLAIM (bar S1), TESTED NOT ASSUMED. Rotating the part changes
// neither the load nor the geometry, only which direction is "up", so ONE solve
// should serve every candidate. This probe scores candidates BOTH ways — cheap
// (re-evaluate the shared field) and expensive (re-run the whole certification
// with that build direction) — and reports agreement per criterion, plus whether
// the solved FIELD itself moved.
//
// A CORRECTION WORTH NOT REPEATING. Off-axis orientations do NOT improve the
// strut interlayer bound. PR 263's bound is
//   il_bound(n) = [Kild*vm + Kilv*|p|]
//               + (2/sqrt(3))*(|nx ny| + |ny nz| + |nz nx|)*[Kd*vm + Kv*|p|]
// whose cross factor is ZERO on any cube axis, MAXIMAL on the body diagonal, and
// ADDS. All six cube axes therefore give an IDENTICAL strut interlayer bound
// (cubic symmetry) and off-axis is strictly worse. Bar S2 asserts both; an
// off-axis strut-interlayer IMPROVEMENT would be a bug in this file.
//
// THE SIX CRITERIA, REPORTED SEPARATELY (the trade-off IS the finding):
//   S-a support volume            support_overhang_voxels (M4.3 proxy)
//   S-b solid/macro interlayer    compute_stress_margin on max_interlayer_tension
//   S-c strut in-plane margin     evaluate_strut_strength (invariant in n)
//   S-d strut interlayer margin   evaluate_strut_strength (cross term)
//   S-e strut-angle histogram     octet strut axes MEASURED from the real
//                                 generator via LatticeGenObserver, vs n
//   S-f printability              min-feature (V3), build height, first-layer
//                                 footprint
//
// FIXTURES. The V5 hook (tests/fixtures/orient/hook.stl), read-only, with the grid
// and BC construction taken VERBATIM from tests/validation/test_v5.cpp — a real
// part with real flat faces (so the candidate set is the real one). An octet
// lattice posture over its interior supplies the latticed voxels S-c/S-d need.
// THREE cases are run so no conclusion rests on one load case or one resolution:
//   A  load pulls -y, resolution 32   (the V5 gate's own case; full detail)
//   B  load pulls -z, resolution 32   (a DIFFERENT load on the SAME geometry)
//   C  load pulls -y, resolution 48   (the same case, finer)
//
// Build (standalone; NOT wired into CTest), from core/:
//   cmake -S . -B build -DTOPOPT_USE_OCCT=OFF && cmake --build build -j
//   c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
//       -DORIENT_FIXTURE_DIR='"tests/fixtures/orient"' \
//       -DMATERIALS_JSON='"src/materials/materials.json"' \
//       tests/harness/orientation_scoring_probe.cpp build/libtopopt.a \
//       -o build/orientation_scoring_probe
// CSV sink: set TOPOPT_ORIENT_CSV_DIR to write the machine-readable tables there.

#include "topopt/analyze.hpp"
#include "topopt/fea.hpp"
#include "topopt/lattice.hpp"
#include "topopt/lattice_gen.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/orient.hpp"
#include "topopt/report.hpp"
#include "topopt/simp.hpp"
#include "topopt/stl.hpp"
#include "topopt/strut_strength.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <string>
#include <utility>
#include <vector>

using namespace topopt;

namespace {

int g_failures = 0;
int g_checks = 0;

#define CHECK(cond, msg)                                                       \
  do {                                                                         \
    ++g_checks;                                                                \
    if (!(cond)) {                                                             \
      ++g_failures;                                                            \
      std::fprintf(stderr, "SELF-CHECK FAIL (line %d): %s\n", __LINE__, msg);  \
    }                                                                          \
  } while (0)

// ---- small vector helpers -------------------------------------------------
double dot(const Vec3& a, const Vec3& b) {
  return a.x * b.x + a.y * b.y + a.z * b.z;
}
double norm(const Vec3& a) { return std::sqrt(dot(a, a)); }
Vec3 unit(const Vec3& a) {
  const double n = norm(a);
  return Vec3{a.x / n, a.y / n, a.z / n};
}
constexpr double kPi = 3.14159265358979323846;

// The probe's fixed constants. kIso mirrors analyze.cpp's file-local printed
// threshold (density > 0.5), so the printed grid this probe builds for the
// support proxy is the SAME set analyze_fixed_design builds internally.
constexpr double kIso = 0.5;
constexpr double kLatticeRho = 0.30;    // inside octet's certifiable band
constexpr double kLatticeCellMm = 4.0;  // recorded; not used in the macro math
constexpr double kCertTol = 1e-8;
constexpr double kHorizontalDeg = 10.0;  // "within 10 deg of horizontal" (S-e)

std::string env_or_empty(const char* k) {
  const char* v = std::getenv(k);
  return v ? std::string(v) : std::string();
}

std::string dir_label(const Vec3& n) {
  char buf[64];
  std::snprintf(buf, sizeof(buf), "(%+.3f,%+.3f,%+.3f)", n.x, n.y, n.z);
  return std::string(buf);
}

bool on_cube_axis(const Vec3& n) {
  const double a = std::fabs(n.x), b = std::fabs(n.y), c = std::fabs(n.z);
  return (a > 1.0 - 1e-9 && b < 1e-9 && c < 1e-9) ||
         (b > 1.0 - 1e-9 && a < 1e-9 && c < 1e-9) ||
         (c > 1.0 - 1e-9 && a < 1e-9 && b < 1e-9);
}

// =========================================================================
// FIXTURE — the V5 hook, its grid, BCs and loads. Grid and BC construction is
// verbatim tests/validation/test_v5.cpp so the probe measures the SAME part the
// existing orientation gate is validated on. The LOAD AXIS is a parameter: case
// A reproduces V5's downward pull, case B pulls along a different axis on the
// same geometry, to show whether the winner is a property of the SHAPE or of the
// LOAD.
// =========================================================================
struct Fixture {
  TriangleMesh mesh;
  VoxelGrid grid;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  std::vector<double> density;
  double part_solid = 0.0;
  // The service-load direction a job would declare as gravity. run_job.cpp:648
  // derives build_dir = -gravity from exactly this.
  Vec3 gravity_direction{0.0, -1.0, 0.0};
};

Fixture build_fixture(const std::string& fixture_dir, int resolution,
                      int load_axis) {
  Fixture f;
  f.mesh = import_stl_file(fixture_dir + "/hook.stl");
  f.grid = voxelize(f.mesh, resolution);
  f.gravity_direction = Vec3{load_axis == 0 ? -1.0 : 0.0,
                             load_axis == 1 ? -1.0 : 0.0,
                             load_axis == 2 ? -1.0 : 0.0};

  int fixture_voxels = 0, load_voxels = 0;
  for (int k = 0; k < f.grid.nz; ++k)
    for (int j = 0; j < f.grid.ny; ++j)
      for (int i = 0; i < f.grid.nx; ++i) {
        if (!f.grid.solid(i, j, k)) continue;
        const Vec3 c = f.grid.voxel_center(i, j, k);
        if (i == 0 && c.y >= 8.0 && c.y <= 40.0) {
          f.grid.set_tag(i, j, k, VoxelTag::Fixture);
          ++fixture_voxels;
        } else if (c.x >= 20.0 && c.x <= 27.0 && c.y >= 7.0 && c.y <= 15.0) {
          f.grid.set_tag(i, j, k, VoxelTag::Load);
          ++load_voxels;
        }
      }
  CHECK(fixture_voxels > 0, "fixture region has solid voxels");
  CHECK(load_voxels > 0, "load region has solid voxels");

  for (int n : fea_tagged_nodes(f.grid, VoxelTag::Fixture))
    for (int c = 0; c < 3; ++c) f.bcs.push_back(DirichletBC{n, c, 0.0});

  const std::vector<int> load_nodes = fea_tagged_nodes(f.grid, VoxelTag::Load);
  const double per_node = -60.0 / static_cast<double>(load_nodes.size());
  for (int n : load_nodes) f.loads.push_back(NodalLoad{n, load_axis, per_node});

  // A FIXED design: the part as imported. Solid voxels are printed material.
  f.density.assign(f.grid.voxel_count(), 0.0);
  std::size_t solid = 0;
  for (int k = 0; k < f.grid.nz; ++k)
    for (int j = 0; j < f.grid.ny; ++j)
      for (int i = 0; i < f.grid.nx; ++i)
        if (f.grid.solid(i, j, k)) {
          f.density[f.grid.index(i, j, k)] = 1.0;
          ++solid;
        }
  f.part_solid = static_cast<double>(solid);
  return f;
}

// The octet region: printed voxels with all 6 face-neighbours printed (a
// one-voxel erosion), so the lattice sits in the part's INTERIOR and the shell
// stays solid — the posture a real latticed part uses. Load/Fixture voxels are
// frozen anchors and are never latticed.
LatticePosture build_posture(const Fixture& f) {
  LatticePosture p;
  p.topology = LatticeTopology::Octet;
  p.cell_size_mm = kLatticeCellMm;
  const std::size_t nv = f.grid.voxel_count();
  p.mask.assign(nv, 0);
  p.relative_density.assign(nv, 0.0);
  auto printed = [&](int i, int j, int k) {
    if (i < 0 || i >= f.grid.nx || j < 0 || j >= f.grid.ny || k < 0 ||
        k >= f.grid.nz)
      return false;
    return f.density[f.grid.index(i, j, k)] > kIso;
  };
  for (int k = 0; k < f.grid.nz; ++k)
    for (int j = 0; j < f.grid.ny; ++j)
      for (int i = 0; i < f.grid.nx; ++i) {
        if (!printed(i, j, k)) continue;
        const VoxelTag t = f.grid.tags[f.grid.index(i, j, k)];
        if (t == VoxelTag::Load || t == VoxelTag::Fixture) continue;
        if (!printed(i - 1, j, k) || !printed(i + 1, j, k) ||
            !printed(i, j - 1, k) || !printed(i, j + 1, k) ||
            !printed(i, j, k - 1) || !printed(i, j, k + 1))
          continue;
        p.mask[f.grid.index(i, j, k)] = 1;
        p.relative_density[f.grid.index(i, j, k)] = kLatticeRho;
      }
  return p;
}

// The printed grid the support proxy runs on — built exactly as
// analyze_fixed_design builds it internally (non-printed voxels tagged Empty).
VoxelGrid printed_grid_of(const Fixture& f) {
  VoxelGrid g = f.grid;
  for (std::size_t e = 0; e < g.tags.size(); ++e)
    if (!(f.density[e] > kIso)) g.tags[e] = VoxelTag::Empty;
  return g;
}

// FixedDesignAnalysis carries the stress tensor field FLAT (6*n);
// max_interlayer_tension wants it as per-voxel arrays. Repack, once.
std::vector<std::array<double, 6>> repack(const std::vector<double>& flat,
                                          std::size_t n) {
  std::vector<std::array<double, 6>> out(n, std::array<double, 6>{});
  for (std::size_t e = 0; e < n; ++e)
    for (int c = 0; c < 6; ++c)
      out[e][static_cast<std::size_t>(c)] =
          flat[6 * e + static_cast<std::size_t>(c)];
  return out;
}

// =========================================================================
// S-e — the octet strut axes, MEASURED from the production generator.
// PR 201 reported the octet as having NO vertical struts for a +z build: 24/36
// at 45 deg and 12/36 HORIZONTAL bridges. Rather than transcribe that, tap
// generate_lattice with a read-only observer and derive the direction population
// from what the real generator actually emits.
// =========================================================================
struct StrutAxis {
  Vec3 dir;             // unit, sign-canonicalized (a strut has an axis, not a
                        // direction)
  double length = 0.0;  // total emitted centreline length in this direction
  int count = 0;        // number of emitted strut fragments
};

struct DiscardSink : TriangleSink {
  void add_triangle(const Vec3&, const Vec3&, const Vec3&) override {}
};

std::vector<StrutAxis> measure_octet_strut_axes(int cells, double cell_mm,
                                                long long* struts_out) {
  LatticeRegion region;
  region.origin = Vec3{0.0, 0.0, 0.0};
  region.nx = region.ny = region.nz = cells;
  region.cell_mm = cell_mm;
  LatticeRadiusField radius;
  radius.uniform_mm = 0.12 * cell_mm;

  std::vector<StrutAxis> axes;
  long long struts = 0;
  LatticeGenObserver obs;
  obs.on_element = [&](LatticeGenElement kind, const Vec3& a, const Vec3& b,
                       double) {
    if (kind != LatticeGenElement::InteriorStrut) return;  // nodes are balls
    const Vec3 d{b.x - a.x, b.y - a.y, b.z - a.z};
    const double len = norm(d);
    if (len <= 1e-12) return;
    Vec3 u{d.x / len, d.y / len, d.z / len};
    if (u.x < -1e-12 || (std::fabs(u.x) <= 1e-12 &&
                         (u.y < -1e-12 || (std::fabs(u.y) <= 1e-12 && u.z < 0))))
      u = Vec3{-u.x, -u.y, -u.z};
    ++struts;
    for (StrutAxis& s : axes)
      if (std::fabs(dot(s.dir, u)) > 1.0 - 1e-9) {
        s.length += len;
        ++s.count;
        return;
      }
    axes.push_back(StrutAxis{u, len, 1});
  };

  DiscardSink sink;
  generate_lattice(LatticeGenTopology::Octet, region, radius, sink,
                   LatticeSkinSpec{}, &obs);
  if (struts_out) *struts_out = struts;
  std::stable_sort(axes.begin(), axes.end(),
                   [](const StrutAxis& a, const StrutAxis& b) {
                     return a.length > b.length;
                   });
  return axes;
}

// The strut-angle picture for one build direction: elevation above the build
// plate, phi = asin(|axis . n|) in degrees. phi == 0 is a HORIZONTAL bridge
// (categorically needs support, which is impossible inside a lattice); phi == 90
// is a vertical column.
struct AngleReport {
  double horizontal_length_frac = 0.0;  // length fraction with phi <= 10 deg
  double horizontal_count_frac = 0.0;   // strut-fragment fraction, same test
  double min_phi_deg = 90.0;            // the flattest strut family present
  double mean_phi_deg = 0.0;            // length-weighted
  std::array<double, 9> hist{};         // length fraction in 10-deg bins [0,90)
};

AngleReport strut_angles(const std::vector<StrutAxis>& axes, const Vec3& n) {
  AngleReport r;
  double total_len = 0.0, total_cnt = 0.0, horiz_len = 0.0, horiz_cnt = 0.0;
  double wsum = 0.0;
  for (const StrutAxis& s : axes) {
    double c = std::fabs(dot(s.dir, n));
    c = c > 1.0 ? 1.0 : c;
    const double phi = std::asin(c) * 180.0 / kPi;
    total_len += s.length;
    total_cnt += s.count;
    if (phi <= kHorizontalDeg + 1e-9) {
      horiz_len += s.length;
      horiz_cnt += s.count;
    }
    if (phi < r.min_phi_deg) r.min_phi_deg = phi;
    wsum += phi * s.length;
    int bin = static_cast<int>(phi / 10.0);
    if (bin > 8) bin = 8;
    r.hist[static_cast<std::size_t>(bin)] += s.length;
  }
  if (total_len > 0.0) {
    r.horizontal_length_frac = horiz_len / total_len;
    r.mean_phi_deg = wsum / total_len;
    for (double& h : r.hist) h /= total_len;
  }
  if (total_cnt > 0.0) r.horizontal_count_frac = horiz_cnt / total_cnt;
  return r;
}

// =========================================================================
// The per-candidate score row: SIX criteria, never collapsed into one number.
// =========================================================================
struct Row {
  Vec3 n;
  std::string label;
  bool on_cube_axis = false;
  int support_voxels = 0;                 // S-a
  double macro_interlayer_tension = 0.0;  // S-b
  double macro_interlayer_margin = 0.0;   // S-b
  double macro_worst_case_margin = 0.0;   // S-b
  double strut_in_plane = 0.0;            // S-c
  double strut_interlayer = 0.0;          // S-d
  double strut_il_bound_mpa = 0.0;        // S-d
  double il_cross_factor = 0.0;           // S-d
  AngleReport angles;                     // S-e
  int min_feature_violations = 0;         // S-f
  int build_height_voxels = 0;            // S-f
  int footprint_voxels = 0;               // S-f
};

// S-f's two build-frame printability numbers. Layer count and first-layer
// footprint both move with n and both cost real print time / adhesion risk;
// min-feature (the V3 gate) does not move at all and is reported to show that.
void build_frame_metrics(const VoxelGrid& printed, const Vec3& n, int* height,
                         int* footprint) {
  double lo = std::numeric_limits<double>::infinity();
  double hi = -std::numeric_limits<double>::infinity();
  std::vector<double> s;
  s.reserve(printed.voxel_count());
  for (int k = 0; k < printed.nz; ++k)
    for (int j = 0; j < printed.ny; ++j)
      for (int i = 0; i < printed.nx; ++i) {
        if (!printed.solid(i, j, k)) continue;
        const double v = ((i + 0.5) * n.x + (j + 0.5) * n.y + (k + 0.5) * n.z) *
                         printed.spacing;
        s.push_back(v);
        lo = std::min(lo, v);
        hi = std::max(hi, v);
      }
  if (s.empty()) {
    *height = 0;
    *footprint = 0;
    return;
  }
  *height = static_cast<int>(std::ceil((hi - lo) / printed.spacing)) + 1;
  int fp = 0;
  for (double v : s)
    if (v - lo <= printed.spacing + 1e-9) ++fp;
  *footprint = fp;
}

// One scored case: the fixture, the ONE solve, and the full candidate sweep.
struct CaseResult {
  std::string name;
  int resolution = 0;
  int load_axis = 0;
  Vec3 maintainer_dir{0, 0, 1};  // build = -gravity, what run_job.cpp:648 gives
  std::vector<Row> rows;
  std::size_t maint_idx = 0;  // row for the -gravity direction
  std::size_t human_idx = 0;  // row for +z (the V5 fixture's known-correct one)
  double max_von_mises = 0.0;
  std::size_t lattice_voxels = 0;
  double base_seconds = 0.0;
  double sweep_seconds = 0.0;
};

const Row* find_row(const std::vector<Row>& rows, const Vec3& n) {
  for (const Row& r : rows)
    if (dot(r.n, n) > 1.0 - 1e-9) return &r;
  return nullptr;
}

// Best (and worst) row on one criterion. `lower_is_better` flips the sense.
std::pair<const Row*, const Row*> best_worst(const std::vector<Row>& rows,
                                             double (*get)(const Row&),
                                             bool lower_is_better) {
  const Row* best = &rows.front();
  const Row* worst = &rows.front();
  for (const Row& r : rows) {
    const double v = get(r), bv = get(*best), wv = get(*worst);
    if (lower_is_better ? (v < bv) : (v > bv)) best = &r;
    if (lower_is_better ? (v > wv) : (v < wv)) worst = &r;
  }
  return {best, worst};
}

// --- criterion accessors (function pointers so best_worst stays a plain fn) --
double get_support(const Row& r) { return static_cast<double>(r.support_voxels); }
double get_macro_il(const Row& r) { return r.macro_interlayer_margin; }
double get_macro_worst(const Row& r) { return r.macro_worst_case_margin; }
double get_strut_ip(const Row& r) { return r.strut_in_plane; }
double get_strut_il(const Row& r) { return r.strut_interlayer; }
double get_horiz(const Row& r) { return r.angles.horizontal_length_frac; }
double get_height(const Row& r) { return static_cast<double>(r.build_height_voxels); }
double get_footprint(const Row& r) { return static_cast<double>(r.footprint_voxels); }

CaseResult run_case(const std::string& name, const std::string& fixture_dir,
                    const Material& material, const std::vector<StrutAxis>& axes,
                    int resolution, int load_axis, bool verbose,
                    std::vector<std::string>* s1_lines,
                    const std::vector<std::pair<std::string, Vec3>>& extra_dirs) {
  CaseResult cr;
  cr.name = name;
  cr.resolution = resolution;
  cr.load_axis = load_axis;

  Fixture f = build_fixture(fixture_dir, resolution, load_axis);
  const LatticePosture posture = build_posture(f);
  for (char m : posture.mask) cr.lattice_voxels += (m != 0);

  SimpParams params;
  params.youngs_modulus = material.youngs_modulus_mpa;
  params.poisson = material.poisson;
  params.penalty = 3.0;
  KnockdownSpec knock;  // default posture: the plain scalar gate

  cr.maintainer_dir = unit(Vec3{-f.gravity_direction.x, -f.gravity_direction.y,
                                -f.gravity_direction.z});

  std::printf(
      "=== CASE %s: hook.stl @ res %d, load along axis %d, grid %dx%dx%d "
      "(spacing %.4f mm), %.0f solid, %zu latticed (octet rho %.2f)\n",
      name.c_str(), resolution, load_axis, f.grid.nx, f.grid.ny, f.grid.nz,
      f.grid.spacing, f.part_solid, cr.lattice_voxels, kLatticeRho);
  CHECK(cr.lattice_voxels > 0, "the octet posture covers at least one voxel");

  // ---- THE ONE SOLVE. Its build direction is the one PRODUCTION would pick:
  // run_job.cpp:648 sets build_dir = -gravity_direction.
  const auto solve_t0 = std::chrono::steady_clock::now();
  const FixedDesignAnalysis base = analyze_fixed_design(
      f.grid, params, f.density, f.bcs, f.loads, material, cr.maintainer_dir,
      kCertTol, 0, SolverKind::JacobiCG, 1.0, knock, /*load_path_ok=*/true,
      f.part_solid, &posture);
  cr.base_seconds = std::chrono::duration<double>(
      std::chrono::steady_clock::now() - solve_t0).count();
  CHECK(!base.non_convergent, "the base certification solve converged");
  CHECK(base.lattice_strut_report && base.lattice_strut.evaluated,
        "the strut-strength report rode along on the base solve");
  cr.max_von_mises = base.max_von_mises;
  std::printf(
      "    base solve build_dir = -gravity = %s | max_vm %.4f MPa | macro "
      "interlayer tension %.4f MPa | margin worst %.4f\n",
      dir_label(cr.maintainer_dir).c_str(), base.max_von_mises,
      base.max_interlayer_tension, base.margin.worst_case);

  const std::vector<std::array<double, 6>> stress =
      repack(base.stress_tensor_field, f.grid.voxel_count());
  const VoxelGrid printed = printed_grid_of(f);

  // ---- THE CHEAP SWEEP: every candidate, against the ONE solved field.
  // ONE scoring routine, used for both the candidate set and the off-candidate
  // directions below, so no comparison can drift between them.
  auto score = [&](const Vec3& raw) {
    const Vec3 n = unit(raw);
    Row r;
    r.n = n;
    r.label = dir_label(n);
    r.on_cube_axis = on_cube_axis(n);
    r.support_voxels = support_overhang_voxels(printed, n);
    r.macro_interlayer_tension = max_interlayer_tension(f.grid, stress, n);
    const StressMargin m = compute_stress_margin(
        material.yield_strength_mpa, material.z_knockdown, base.max_von_mises,
        r.macro_interlayer_tension);
    r.macro_interlayer_margin = m.interlayer;
    r.macro_worst_case_margin = m.worst_case;
    const StrutStrengthReport sr = evaluate_strut_strength(
        base.stress_tensor_field, posture.mask, posture.relative_density, n,
        material.yield_strength_mpa, material.z_knockdown);
    r.strut_in_plane = sr.margin_in_plane;
    r.strut_interlayer = sr.margin_interlayer;
    r.strut_il_bound_mpa = sr.il_bound_max_mpa;
    r.il_cross_factor = sr.il_cross_factor;
    r.angles = strut_angles(axes, n);
    r.min_feature_violations = base.v3.min_feature_violations;
    build_frame_metrics(printed, n, &r.build_height_voxels, &r.footprint_voxels);
    return r;
  };
  const std::vector<Vec3> candidates = orientation_candidates(f.mesh);
  cr.rows.reserve(candidates.size());
  // CAN THIS BE INTERACTIVE? Time the WHOLE candidate sweep against the ONE
  // solved field, and time the solve it rides on, so the ratio is measured
  // rather than asserted.
  const auto t0 = std::chrono::steady_clock::now();
  for (const Vec3& raw : candidates) cr.rows.push_back(score(raw));
  const auto t1 = std::chrono::steady_clock::now();
  cr.sweep_seconds =
      std::chrono::duration<double>(t1 - t0).count();
  std::printf(
      "    SWEEP COST: %zu candidates x 6 criteria in %.4f s (%.2f ms per "
      "candidate) against ONE solve costing %.4f s -> the whole sweep is %.1f%% "
      "of a single certification\n",
      candidates.size(), cr.sweep_seconds,
      1000.0 * cr.sweep_seconds / static_cast<double>(candidates.size()),
      cr.base_seconds, 100.0 * cr.sweep_seconds / cr.base_seconds);
  for (std::size_t i = 0; i < cr.rows.size(); ++i) {
    if (dot(cr.rows[i].n, cr.maintainer_dir) > 1.0 - 1e-9) cr.maint_idx = i;
    if (dot(cr.rows[i].n, Vec3{0, 0, 1}) > 1.0 - 1e-9) cr.human_idx = i;
  }
  CHECK(find_row(cr.rows, cr.maintainer_dir) != nullptr,
        "the -gravity build direction is in the candidate set");
  CHECK(find_row(cr.rows, Vec3{0, 0, 1}) != nullptr,
        "the +z build direction is in the candidate set");

  // ---- S2 SELF-CHECKS, run on EVERY case (not just the verbose one).
  {
    const double ip0 = cr.rows.front().strut_in_plane;
    bool ip_exact = true;
    for (const Row& r : cr.rows)
      if (r.strut_in_plane != ip0) ip_exact = false;
    CHECK(ip_exact,
          "S-c: strut IN-PLANE margin is bit-identical for every candidate");

    std::vector<const Row*> axis_rows;
    for (const Row& r : cr.rows)
      if (r.on_cube_axis) axis_rows.push_back(&r);
    CHECK(axis_rows.size() == 6, "all six cube axes are in the candidate set");
    bool sd_exact = true;
    for (const Row* r : axis_rows)
      if (r->strut_interlayer != axis_rows.front()->strut_interlayer ||
          r->il_cross_factor != 0.0)
        sd_exact = false;
    CHECK(sd_exact,
          "S-d: the six cube axes give an IDENTICAL strut interlayer margin");

    const double axis_sd = axis_rows.front()->strut_interlayer;
    int improved = 0, worse = 0;
    for (const Row& r : cr.rows) {
      if (r.on_cube_axis) continue;
      if (r.strut_interlayer > axis_sd + 1e-12) ++improved;
      if (r.strut_interlayer < axis_sd - 1e-12) ++worse;
    }
    CHECK(improved == 0,
          "S-d: NO off-axis candidate improves the strut interlayer margin");
    std::printf(
        "    S2: S-c EXACT (%.8f, 0 deviation) | S-d cube axes EXACT (%.8f, "
        "6 axes) | off-axis %d/%zu strictly worse, %d improved\n",
        ip0, axis_sd, worse, cr.rows.size() - axis_rows.size(), improved);
  }

  // ---- S1: CHEAP vs EXPENSIVE. Re-run the WHOLE certification with each of a
  // spread of build directions and compare every criterion, plus the field.
  if (s1_lines) {
    const std::vector<Vec3> resolve_dirs = {
        unit(Vec3{0, 0, 1}), unit(Vec3{0, 1, 0}), unit(Vec3{1, 0, 0}),
        unit(Vec3{1, 1, 0}), unit(Vec3{1, 1, 1})};
    for (const Vec3& n : resolve_dirs) {
      const Row* cheap = find_row(cr.rows, n);
      if (!cheap) continue;
      const FixedDesignAnalysis re = analyze_fixed_design(
          f.grid, params, f.density, f.bcs, f.loads, material, n, kCertTol, 0,
          SolverKind::JacobiCG, 1.0, knock, /*load_path_ok=*/true, f.part_solid,
          &posture);
      CHECK(!re.non_convergent, "the re-solve converged");
      const bool field_identical =
          re.stress_tensor_field == base.stress_tensor_field &&
          re.displacement_field == base.displacement_field &&
          re.von_mises_field == base.von_mises_field;
      CHECK(field_identical,
            "the solved field is BIT-IDENTICAL across build directions");
      const bool sa = (re.support_volume_voxels == cheap->support_voxels);
      const bool sb =
          (re.max_interlayer_tension == cheap->macro_interlayer_tension);
      const bool sc = (re.lattice_strut.margin_in_plane == cheap->strut_in_plane);
      const bool sd =
          (re.lattice_strut.margin_interlayer == cheap->strut_interlayer);
      CHECK(sa && sb && sc && sd,
            "cheap re-evaluation reproduces the re-solve on every criterion");
      char buf[512];
      std::snprintf(buf, sizeof(buf),
                    "  case %-3s %s  field %s | S-a %s (%d) | S-b %s (%.10f) | "
                    "S-c %s (%.10f) | S-d %s (%.10f)",
                    name.c_str(), dir_label(n).c_str(),
                    field_identical ? "BIT-IDENTICAL" : "DIFFERS",
                    sa ? "exact" : "MISMATCH", re.support_volume_voxels,
                    sb ? "exact" : "MISMATCH", re.max_interlayer_tension,
                    sc ? "exact" : "MISMATCH", re.lattice_strut.margin_in_plane,
                    sd ? "exact" : "MISMATCH",
                    re.lattice_strut.margin_interlayer);
      s1_lines->push_back(buf);
    }
  }

  // ---- The per-criterion winners (printed for every case; the full table only
  // for the verbose one).
  if (verbose) {
    std::printf(
        "\n%-24s %4s %8s %10s %10s %10s %8s %8s %8s %7s %7s %6s %8s\n",
        "build_dir n", "axis", "S-a sup", "S-b il_tns", "S-b il_mgn",
        "S-b worst", "S-c ip", "S-d il", "S-d xfac", "S-e h%", "S-e min",
        "S-f h", "S-f foot");
    for (const Row& r : cr.rows)
      std::printf(
          "%-24s %4s %8d %10.4f %10.4f %10.4f %8.4f %8.4f %8.4f %7.3f %7.2f "
          "%6d %8d\n",
          r.label.c_str(), r.on_cube_axis ? "yes" : "-", r.support_voxels,
          r.macro_interlayer_tension, r.macro_interlayer_margin,
          r.macro_worst_case_margin, r.strut_in_plane, r.strut_interlayer,
          r.il_cross_factor, r.angles.horizontal_length_frac,
          r.angles.min_phi_deg, r.build_height_voxels, r.footprint_voxels);
    std::printf("\n");
  }

  struct Crit {
    const char* name;
    double (*get)(const Row&);
    bool lower_better;
  };
  const Crit crits[] = {
      {"S-a support voxels", get_support, true},
      {"S-b macro il margin", get_macro_il, false},
      {"S-b macro worst margin", get_macro_worst, false},
      {"S-c strut in-plane", get_strut_ip, false},
      {"S-d strut interlayer", get_strut_il, false},
      {"S-e horizontal strut %", get_horiz, true},
      {"S-f build height", get_height, true},
      {"S-f first-layer footprint", get_footprint, false},
  };
  std::printf("    BEST / WORST / -gravity / +z per criterion:\n");
  const Row& maint = cr.rows[cr.maint_idx];
  const Row& human = cr.rows[cr.human_idx];
  for (const Crit& c : crits) {
    const auto bw = best_worst(cr.rows, c.get, c.lower_better);
    auto rel = [&](double reference) {
      const double b = c.get(*bw.first);
      if (c.lower_better) {
        if (!(b > 0.0) && !(reference > 0.0)) return 1.0;
        if (!(b > 0.0)) return std::numeric_limits<double>::infinity();
        return reference / b;
      }
      if (!(reference > 0.0)) return std::numeric_limits<double>::infinity();
      return b / reference;
    };
    std::printf(
        "      %-26s best %-24s %10.4f | -grav %10.4f (%7.2fx) | +z %10.4f "
        "(%7.2fx) | worst %10.4f (%7.2fx)\n",
        c.name, bw.first->label.c_str(), c.get(*bw.first), c.get(maint),
        rel(c.get(maint)), c.get(human), rel(c.get(human)), c.get(*bw.second),
        rel(c.get(*bw.second)));
  }

  // ---- THE BEST COMPROMISE. Each MOVING criterion is normalized to [0,1] over
  // the candidate set (1 = best on that criterion) and a candidate is ranked by
  // its WORST standing — the maximin choice, the honest pick when the criteria
  // disagree and no weighting is defensible. Deliberately NOT presented as "the
  // score": a weighted sum would launder the trade-off into one number.
  auto span = [&](double (*get)(const Row&)) {
    double lo = std::numeric_limits<double>::infinity();
    double hi = -std::numeric_limits<double>::infinity();
    for (const Row& r : cr.rows) {
      lo = std::min(lo, get(r));
      hi = std::max(hi, get(r));
    }
    return std::pair<double, double>{lo, hi};
  };
  auto nrm = [](double v, std::pair<double, double> s, bool lower_better) {
    if (!(s.second - s.first > 0.0)) return 1.0;  // criterion does not move
    const double t = (v - s.first) / (s.second - s.first);
    return lower_better ? 1.0 - t : t;            // 1 = best, 0 = worst
  };
  const auto span_a = span(get_support);
  const auto span_b = span(get_macro_il);
  const auto span_d = span(get_strut_il);
  const auto span_e = span(get_horiz);
  auto maximin = [&](const Row& r) {
    return std::min(std::min(nrm(get_support(r), span_a, true),
                             nrm(get_macro_il(r), span_b, false)),
                    std::min(nrm(get_strut_il(r), span_d, false),
                             nrm(get_horiz(r), span_e, true)));
  };
  const Row* compromise = &cr.rows.front();
  for (const Row& r : cr.rows)
    if (maximin(r) > maximin(*compromise)) compromise = &r;
  std::printf(
      "    BEST COMPROMISE (maximin over the four MOVING criteria): %s  "
      "worst-standing %.4f  [S-a %.3f S-b %.3f S-d %.3f S-e %.3f]\n",
      compromise->label.c_str(), maximin(*compromise),
      nrm(get_support(*compromise), span_a, true),
      nrm(get_macro_il(*compromise), span_b, false),
      nrm(get_strut_il(*compromise), span_d, false),
      nrm(get_horiz(*compromise), span_e, true));
  // Ties are REAL here and must not be read as disagreement: +z and -z both rest
  // the hook flat, all six cube axes tie on S-d, all six <110> edges tie on S-e,
  // and the gated worst-case margin SATURATES at the (direction-independent)
  // in-plane term once the interlayer term passes it. So a criterion "agrees"
  // with the compromise when the compromise ATTAINS the best value, not when it
  // happens to be the argmax the scan reported first.
  std::printf("    AGREEMENT with the single-criterion optima (ties counted):\n");
  for (const Crit& c : crits) {
    const auto bw = best_worst(cr.rows, c.get, c.lower_better);
    const double best_v = c.get(*bw.first);
    int tied = 0;
    for (const Row& r : cr.rows)
      if (c.get(r) == best_v) ++tied;
    const bool moves = (best_v != c.get(*bw.second));
    const bool attains = (c.get(*compromise) == best_v);
    std::printf("      %-26s optimum %-24s (%2d tied) %s\n", c.name,
                bw.first->label.c_str(), tied,
                !moves ? "criterion does not move — no preference"
                       : (attains ? "compromise ATTAINS it"
                                  : "compromise does NOT attain it  <-- DISAGREES"));
  }
  // ---- THE S-e vs S-d TRADE-OFF, PRICED. S-e asks whether an orientation that
  // eliminates the horizontal strut population would be worth more than the
  // margin terms. The direction that does so is NOT in the 26-candidate set, so
  // score it here against the SAME field with the SAME routine and put the bill
  // next to the benefit.
  if (!extra_dirs.empty()) {
    std::printf(
        "    S-e vs S-d PRICED (directions scored on this case's field; the "
        "starred one is NOT in the candidate set):\n");
    std::printf("      %-30s %-24s %8s %10s %8s %8s %8s %8s\n", "direction",
                "n", "S-a sup", "S-b il_mgn", "S-d il", "S-d xfac", "S-e h%",
                "S-e min");
    for (const auto& e : extra_dirs) {
      const Row r = score(e.second);
      std::printf("      %-30s %-24s %8d %10.4f %8.4f %8.4f %8.3f %8.2f\n",
                  e.first.c_str(), r.label.c_str(), r.support_voxels,
                  r.macro_interlayer_margin, r.strut_interlayer,
                  r.il_cross_factor, r.angles.horizontal_length_frac,
                  r.angles.min_phi_deg);
    }
  }
  std::printf("\n");
  return cr;
}

}  // namespace

int main() {
  const std::string fixture_dir = ORIENT_FIXTURE_DIR;
  const std::string materials_path = MATERIALS_JSON;
  const std::string csv_dir = env_or_empty("TOPOPT_ORIENT_CSV_DIR");

  std::printf(
      "=========================================================\n"
      " ORIENTATION SCORING PROBE (2026-08-01) -- PROBE ONLY\n"
      " nothing here is production; nothing here gates anything\n"
      "=========================================================\n\n");

  const MaterialLibrary lib = load_materials_file(materials_path);
  const Material material = lib.at("PLA");
  std::printf("material PLA: E=%.1f MPa  yield=%.1f MPa  z_knockdown=%.3f\n\n",
              material.youngs_modulus_mpa, material.yield_strength_mpa,
              material.z_knockdown);

  // =========================================================================
  // S-e INSTRUMENT: the octet strut axes, measured from the real generator, and
  // its convergence in block size (cell-local ownership means boundary cells own
  // fewer legs than interior ones, so the per-cell count rises with block size).
  // =========================================================================
  std::printf("---- S-e INSTRUMENT: octet strut axes from the REAL generator --\n");
  // The emitted-fragment count is EXACTLY 24n^3 + 12n^2 over an n^3 block: cell-
  // local ownership gives each cell 24 legs of its own, and each of the 6n^2
  // boundary faces contributes 2 more that an interior cell would have shared.
  // 24 owned + 12 shared per cell = 36 — PR 201's per-cell figure, reconciled.
  for (int cells : {2, 3, 4, 6, 8}) {
    long long struts = 0;
    const std::vector<StrutAxis> a =
        measure_octet_strut_axes(cells, kLatticeCellMm, &struts);
    const long long law = 24LL * cells * cells * cells + 12LL * cells * cells;
    CHECK(struts == law,
          "octet fragment count follows 24n^3 + 12n^2 (24 owned + 12 shared per "
          "cell = PR 201's 36)");
    std::printf("  %dx%dx%d cells: %lld interior strut fragments (%.2f per cell), "
                "%zu distinct axes  [24n^3+12n^2 = %lld %s]\n",
                cells, cells, cells, struts,
                static_cast<double>(struts) / (cells * cells * cells), a.size(),
                law, struts == law ? "MATCH" : "MISMATCH");
  }
  long long emitted = 0;
  const std::vector<StrutAxis> axes =
      measure_octet_strut_axes(8, kLatticeCellMm, &emitted);
  double axis_total = 0.0;
  for (const StrutAxis& a : axes) axis_total += a.length;
  std::printf("  the 8x8x8 population reduces to %zu axes:\n", axes.size());
  for (const StrutAxis& a : axes)
    std::printf("    (%+.4f,%+.4f,%+.4f)  %6d fragments  %6.2f%% of length\n",
                a.dir.x, a.dir.y, a.dir.z, a.count,
                100.0 * a.length / axis_total);
  CHECK(axes.size() == 6,
        "the octet strut population reduces to exactly 6 axes (the <110> family)");
  {
    const AngleReport z = strut_angles(axes, Vec3{0, 0, 1});
    std::printf(
        "  vs PR 201 (+z build, 'no vertical struts, 12/36 horizontal'): "
        "horizontal length fraction %.4f, fragment fraction %.4f, "
        "flattest family %.2f deg, steepest bin %.4f at 40-50 deg\n",
        z.horizontal_length_frac, z.horizontal_count_frac, z.min_phi_deg,
        z.hist[4]);
    CHECK(std::fabs(z.horizontal_length_frac - 1.0 / 3.0) < 1e-9,
          "S-e reproduces PR 201's 12/36 horizontal population for a +z build");
  }

  // -------- CAN ANY ORIENTATION KILL THE HORIZONTAL POPULATION? -------------
  // S-e asks this directly. The candidate set is only 26 directions; this is the
  // exhaustive answer over the WHOLE sphere, by dense sampling of the elevation
  // of the flattest strut family, max over n of min over axes of phi.
  Vec3 best_n{0, 0, 1};  // the flattest-strut-family maximizer, priced per case
  {
    const int kSamples = 400000;
    double best_min_phi = -1.0;
    const double ga = kPi * (3.0 - std::sqrt(5.0));  // golden-angle spiral
    for (int s = 0; s < kSamples; ++s) {
      const double zc = 1.0 - 2.0 * (s + 0.5) / kSamples;
      const double rr = std::sqrt(std::max(0.0, 1.0 - zc * zc));
      const double th = ga * s;
      const Vec3 n{rr * std::cos(th), rr * std::sin(th), zc};
      double mn = 90.0;
      for (const StrutAxis& a : axes) {
        double c = std::fabs(dot(a.dir, n));
        c = c > 1.0 ? 1.0 : c;
        mn = std::min(mn, std::asin(c) * 180.0 / kPi);
      }
      if (mn > best_min_phi) {
        best_min_phi = mn;
        best_n = n;
      }
    }
    const AngleReport br = strut_angles(axes, best_n);
    const double cross = (2.0 / std::sqrt(3.0)) *
                         (std::fabs(best_n.x * best_n.y) +
                          std::fabs(best_n.y * best_n.z) +
                          std::fabs(best_n.z * best_n.x));
    std::printf(
        "\n  EXHAUSTIVE (%d directions over the whole sphere): the flattest "
        "strut family can be raised to at most %.2f deg above the plate, at "
        "n = %s\n"
        "    at that n: horizontal(<=%.0f deg) length fraction %.4f, mean strut "
        "elevation %.2f deg, PR 263 cross factor %.4f\n"
        "    (a cube axis leaves %.2f deg / %.4f horizontal at cross factor 0; "
        "the 45-deg FDM self-support limit is NOT reachable in ANY orientation)\n",
        kSamples, best_min_phi, dir_label(best_n).c_str(), kHorizontalDeg,
        br.horizontal_length_frac, br.mean_phi_deg, cross,
        strut_angles(axes, Vec3{0, 0, 1}).min_phi_deg,
        strut_angles(axes, Vec3{0, 0, 1}).horizontal_length_frac);
    CHECK(best_min_phi < 45.0,
          "S-e: NO build direction lifts every octet strut family to the 45-deg "
          "self-supporting limit");
  }
  std::printf("\n");

  // =========================================================================
  // THE THREE CASES.
  // =========================================================================
  const std::vector<std::pair<std::string, Vec3>> extra_dirs = {
      {"cube axis +z (candidate)", Vec3{0, 0, 1}},
      {"<110> edge (candidate)", unit(Vec3{0, 1, 1})},
      {"body diagonal (candidate)", unit(Vec3{1, 1, 1})},
      {"* flattest-strut maximizer", best_n},
  };
  std::vector<std::string> s1_lines;
  const CaseResult a = run_case("A", fixture_dir, material, axes, 32, 1,
                                /*verbose=*/true, &s1_lines, extra_dirs);
  const CaseResult b = run_case("B", fixture_dir, material, axes, 32, 2,
                                /*verbose=*/false, &s1_lines, extra_dirs);
  const CaseResult c = run_case("C", fixture_dir, material, axes, 48, 1,
                                /*verbose=*/false, &s1_lines, extra_dirs);

  // =========================================================================
  // S1 — THE CHEAP-SCORING VERDICT, collected from all three cases.
  // =========================================================================
  std::printf("---- S1: CHEAP vs EXPENSIVE (a full re-solve per direction) ----\n");
  for (const std::string& l : s1_lines) std::printf("%s\n", l.c_str());
  std::printf(
      "\n  MECHANISM: build_dir enters analyze_fixed_design ONLY after the solve "
      "— at max_interlayer_tension, support_overhang_voxels and\n"
      "  evaluate_strut_strength. The element stiffness is isotropic "
      "(hex8_stiffness) or the lattice's cubic tensor; neither reads it.\n"
      "  hex8_stiffness_transverse (the layer-anisotropic element) exists in core "
      "and has ZERO production callers, so the solved field\n"
      "  cannot depend on n. Cheap scoring is therefore EXACT, not approximate — "
      "and would break the moment that element were armed.\n\n");

  // =========================================================================
  // S3/S4 — DOES THE WINNER SURVIVE A DIFFERENT LOAD AND A FINER GRID?
  // =========================================================================
  std::printf("---- S3/S4 CROSS-CASE: does the winner depend on the LOAD? -----\n");
  struct Crit2 {
    const char* name;
    double (*get)(const Row&);
    bool lower_better;
  };
  const Crit2 crits[] = {
      {"S-a support voxels", get_support, true},
      {"S-b macro il margin", get_macro_il, false},
      {"S-b macro worst margin", get_macro_worst, false},
      {"S-d strut interlayer", get_strut_il, false},
      {"S-e horizontal strut %", get_horiz, true},
  };
  std::printf("  %-26s %-26s %-26s %-26s\n", "criterion",
              "case A (load -y, res 32)", "case B (load -z, res 32)",
              "case C (load -y, res 48)");
  for (const Crit2& cc : crits) {
    const auto ba = best_worst(a.rows, cc.get, cc.lower_better);
    const auto bb = best_worst(b.rows, cc.get, cc.lower_better);
    const auto bc = best_worst(c.rows, cc.get, cc.lower_better);
    std::printf("  %-26s %-26s %-26s %-26s\n", cc.name, ba.first->label.c_str(),
                bb.first->label.c_str(), bc.first->label.c_str());
  }
  std::printf("\n");

  // =========================================================================
  // S5 — THE GRAVITY/BUILD CONFLATION, REPORTED NOT FIXED.
  // =========================================================================
  std::printf("---- S5: GRAVITY vs BUILD (reported, NOT fixed) ----------------\n");
  std::printf(
      "  THREE production sites derive the build direction from gravity, in TWO "
      "files (grep'd, evidence/01_call_graph.txt):\n"
      "    simp/minimize_plastic.cpp:270  const Vec3 build_dir = "
      "normalized(-options.gravity_direction)   <- the MAIN optimize path\n"
      "    cli/run_job.cpp:648            cx.build_dir = "
      "normalized(-options.gravity_direction)   <- lattice cert context\n"
      "    cli/run_job.cpp:1427           const Vec3 build_dir = "
      "normalized(-options.gravity_direction)   <- analyze / re-certify\n");
  std::printf("  'which way is down in service' and 'which way is up on the plate' "
              "are DIFFERENT questions. What the conflation costs, measured:\n");
  for (const CaseResult* cs : {&a, &b, &c}) {
    const Row& m = cs->rows[cs->maint_idx];
    const auto bb = best_worst(cs->rows, get_macro_il, false);
    const auto bs = best_worst(cs->rows, get_support, true);
    std::printf(
        "    case %s: gravity %s -> build %s | S-b il margin %.4f vs best %.4f "
        "(%.2fx) | S-a support %d vs best %d\n",
        cs->name.c_str(),
        dir_label(Vec3{-cs->maintainer_dir.x, -cs->maintainer_dir.y,
                       -cs->maintainer_dir.z})
            .c_str(),
        dir_label(cs->maintainer_dir).c_str(), get_macro_il(m),
        get_macro_il(*bb.first),
        get_macro_il(m) > 0.0 ? get_macro_il(*bb.first) / get_macro_il(m) : 0.0,
        m.support_voxels, bs.first->support_voxels);
  }
  std::printf("\n");

  // =========================================================================
  // CSV sink (machine-readable evidence) — case A, the detailed one.
  // =========================================================================
  if (!csv_dir.empty()) {
    const std::string path = csv_dir + "/orientation_scores.csv";
    std::FILE* fp = std::fopen(path.c_str(), "w");
    if (!fp) {
      std::fprintf(stderr, "WARN: could not write %s\n", path.c_str());
    } else {
      std::fprintf(fp,
                   "case,nx,ny,nz,on_cube_axis,support_voxels,"
                   "macro_il_tension_mpa,macro_il_margin,macro_worst_margin,"
                   "strut_in_plane,strut_interlayer,strut_il_bound_mpa,"
                   "il_cross_factor,horiz_len_frac,horiz_count_frac,"
                   "min_phi_deg,mean_phi_deg,build_height_voxels,"
                   "footprint_voxels,min_feature_violations\n");
      for (const CaseResult* cs : {&a, &b, &c})
        for (const Row& r : cs->rows)
          std::fprintf(fp,
                       "%s,%.9f,%.9f,%.9f,%d,%d,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,"
                       "%.9f,%.9f,%.9f,%.6f,%.6f,%d,%d,%d\n",
                       cs->name.c_str(), r.n.x, r.n.y, r.n.z,
                       r.on_cube_axis ? 1 : 0, r.support_voxels,
                       r.macro_interlayer_tension, r.macro_interlayer_margin,
                       r.macro_worst_case_margin, r.strut_in_plane,
                       r.strut_interlayer, r.strut_il_bound_mpa,
                       r.il_cross_factor, r.angles.horizontal_length_frac,
                       r.angles.horizontal_count_frac, r.angles.min_phi_deg,
                       r.angles.mean_phi_deg, r.build_height_voxels,
                       r.footprint_voxels, r.min_feature_violations);
      std::fclose(fp);
      std::printf("wrote %s\n", path.c_str());
    }
    const std::string hpath = csv_dir + "/strut_angle_histogram.csv";
    std::FILE* hf = std::fopen(hpath.c_str(), "w");
    if (hf) {
      std::fprintf(hf,
                   "nx,ny,nz,min_phi_deg,mean_phi_deg,bin_0_10,bin_10_20,"
                   "bin_20_30,bin_30_40,bin_40_50,bin_50_60,bin_60_70,"
                   "bin_70_80,bin_80_90\n");
      for (const Row& r : a.rows) {
        std::fprintf(hf, "%.9f,%.9f,%.9f,%.6f,%.6f", r.n.x, r.n.y, r.n.z,
                     r.angles.min_phi_deg, r.angles.mean_phi_deg);
        for (double h : r.angles.hist) std::fprintf(hf, ",%.9f", h);
        std::fprintf(hf, "\n");
      }
      std::fclose(hf);
      std::printf("wrote %s\n", hpath.c_str());
    }
  }

  std::printf("\n%d self-checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
