// Clearance parity + effect gate (handoff 100 — "Keep clear").
//
// Two guarantees, both on the SHARED build_production_loadcase seam the app and
// the CLI route through, driven on the demo l-bracket (two cylindrical bolt
// holes, a design box that expands the domain so the optimizer WOULD otherwise
// fill the bores):
//
//   (1) THE ONE RULE — no clearance declared => byte-identical to the pre-100
//       path. An empty `clearances` list leaves `options.clearance_void` empty,
//       so the minimize_plastic OR-step is skipped and NOTHING changes. Proven by
//       (a) the overlay is empty and (b) a full minimize_plastic run is
//       bit-identical to the same load case run with clearances untouched.
//
//   (2) A declared bolt clearance actually FORBIDS growth: the swept-cylinder
//       region is FrozenVoid on the solved grid, the reports say so honestly, and
//       the optimized density in the bore is pinned to void — so a clearance run
//       DIFFERS from the no-clearance run (the feature has a real effect).
//
// Drives OCCT (STEP import) + Eigen (minimize_plastic), gated on both in CMake.

#include "topopt/clearance.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

using topopt::build_production_loadcase;
using topopt::ClearanceKind;
using topopt::Material;
using topopt::MaterialLibrary;
using topopt::MinimizePlasticResult;
using topopt::ProductionLoadCase;
using topopt::ProductionRunSetup;
using topopt::SettingsRules;
using topopt::StepModel;
using topopt::StepSurfaceKind;
using topopt::Vec3;
using topopt::VoxelGrid;

namespace {
int g_failures = 0;
}
#define CHECK(cond, msg)             \
  do {                              \
    if (!(cond)) {                  \
      std::printf("FAIL: %s\n", msg); \
      ++g_failures;                 \
    }                               \
  } while (0)

namespace {

// The l-bracket load case shared by both runs: both holes anchored, the planar
// faces carry a downward force, reduction ladder + pad on, and a design box grown
// in +z so the domain genuinely expands (the same case the parity gate uses).
ProductionLoadCase make_load_case(const StepModel& model) {
  ProductionLoadCase lc;
  ProductionLoadCase::LoadGroup g;
  for (int f = 0; f < model.face_count; ++f) {
    const auto& info = model.faces[static_cast<std::size_t>(f)];
    if (info.kind == StepSurfaceKind::Cylinder)
      lc.anchor_face_ids.push_back(f);
    else if (info.kind == StepSurfaceKind::Plane)
      g.face_ids.push_back(f);
  }
  g.force = Vec3{0.0, 0.0, -50.0};
  lc.load_groups.push_back(g);
  lc.minimize_plastic = true;
  lc.build_dir = Vec3{0.0, 0.0, 1.0};
  lc.has_design_box = true;
  lc.design_box.min = Vec3{-30.0, -20.0, 0.0};
  lc.design_box.max = Vec3{30.0, 20.0, 75.0};
  return lc;
}

// The first cylindrical face id (a bolt hole).
int first_hole(const StepModel& model) {
  for (int f = 0; f < model.face_count; ++f)
    if (model.faces[static_cast<std::size_t>(f)].kind == StepSurfaceKind::Cylinder)
      return f;
  return -1;
}

// The mid-point of a cylindrical face's axial span, in model space: average of
// the axial projections of the face's tessellation vertices, along its axis.
Vec3 hole_mid(const StepModel& model, int face_id) {
  const auto& info = model.faces[static_cast<std::size_t>(face_id)];
  double t_lo = 0, t_hi = 0;
  bool any = false;
  for (std::size_t t = 0; t < model.mesh.triangles.size(); ++t) {
    if (model.triangle_face[t] != face_id) continue;
    for (int c = 0; c < 3; ++c) {
      const Vec3& v = model.mesh.vertices[static_cast<std::size_t>(model.mesh.triangles[t][c])];
      const double s = (v.x - info.axis_point.x) * info.axis_dir.x +
                       (v.y - info.axis_point.y) * info.axis_dir.y +
                       (v.z - info.axis_point.z) * info.axis_dir.z;
      if (!any) { t_lo = t_hi = s; any = true; }
      else { if (s < t_lo) t_lo = s; if (s > t_hi) t_hi = s; }
    }
  }
  const double tm = 0.5 * (t_lo + t_hi);
  return Vec3{info.axis_point.x + tm * info.axis_dir.x,
              info.axis_point.y + tm * info.axis_dir.y,
              info.axis_point.z + tm * info.axis_dir.z};
}

// Index of the voxel whose centre is nearest model point p, on `grid`.
std::size_t voxel_at(const VoxelGrid& grid, const Vec3& p) {
  auto clampi = [](int v, int n) { return v < 0 ? 0 : (v >= n ? n - 1 : v); };
  const int i = clampi(static_cast<int>((p.x - grid.origin.x) / grid.spacing), grid.nx);
  const int j = clampi(static_cast<int>((p.y - grid.origin.y) / grid.spacing), grid.ny);
  const int k = clampi(static_cast<int>((p.z - grid.origin.z) / grid.spacing), grid.nz);
  return grid.index(i, j, k);
}

bool densities_identical(const MinimizePlasticResult& a,
                         const MinimizePlasticResult& b) {
  if (a.evaluated.size() != b.evaluated.size()) return false;
  for (std::size_t i = 0; i < a.evaluated.size(); ++i) {
    const auto& ra = a.evaluated[i].optimization.physical_density;
    const auto& rb = b.evaluated[i].optimization.physical_density;
    if (ra.size() != rb.size()) return false;
    for (std::size_t k = 0; k < ra.size(); ++k)
      if (ra[k] != rb[k]) return false;
  }
  return true;
}

}  // namespace

int main() {
  const std::string demo_dir = DEMO_FIXTURE_DIR;
  const StepModel model = topopt::import_step_file(demo_dir + "/l-bracket.step");
  const MaterialLibrary materials = topopt::load_materials_file(MATERIALS_JSON_PATH);
  const Material material = materials.at("PLA");
  const SettingsRules rules = topopt::load_settings_rules_file(SETTINGS_RULES_PATH);
  const int resolution = 24;

  // ── (1) THE ONE RULE: no clearance => empty overlay, byte-identical run. ──
  ProductionLoadCase lc_none = make_load_case(model);
  ProductionRunSetup s_none = build_production_loadcase(model, resolution, lc_none);
  CHECK(s_none.options.clearance_void.empty(),
        "no clearance declared => clearance_void overlay is empty");
  CHECK(s_none.clearance_reports.empty(),
        "no clearance declared => no clearance reports");

  // ── (2) A bolt clearance on a hole forbids growth. ───────────────────────
  const int hole = first_hole(model);
  CHECK(hole >= 0, "l-bracket exposes a cylindrical bolt hole");
  ProductionLoadCase lc_clear = make_load_case(model);
  {
    ProductionLoadCase::Clearance c;
    c.face_id = hole;
    c.params.kind = ClearanceKind::Bolt;
    c.params.concentric_margin_mm = 2.5;  // keep-out radius = 2.5 (bore) + 2.5
    c.params.axial_clearance_mm = 6.0;    // sweep well past the part faces
    lc_clear.clearances.push_back(c);
  }
  ProductionRunSetup s_clear = build_production_loadcase(model, resolution, lc_clear);
  CHECK(!s_clear.options.clearance_void.empty(),
        "a declared clearance builds a non-empty overlay");
  CHECK(s_clear.options.clearance_void.size() == s_clear.solved_grid.voxel_count(),
        "the clearance overlay is indexed on the solved grid");
  CHECK(s_clear.clearance_reports.size() == 1, "one clearance report");
  if (!s_clear.clearance_reports.empty()) {
    const auto& rep = s_clear.clearance_reports.front();
    CHECK(rep.in_grid, "the bore clearance intersects the solved grid");
    CHECK(rep.voxels_frozen > 0, "the bore clearance froze voxels");
    CHECK(rep.kind == ClearanceKind::Bolt, "report records the Bolt kind");
  }

  // The bore-centre voxel (on the hole axis, at the hole's own mid-span) is
  // FrozenVoid in the overlay: the swept cylinder covers it.
  const Vec3 bore_centre = hole_mid(model, hole);
  const std::size_t bore_idx = voxel_at(s_clear.solved_grid, bore_centre);
  CHECK(s_clear.options.clearance_void[bore_idx] == topopt::MaskValue::FrozenVoid,
        "the bore-centre voxel is FrozenVoid in the clearance overlay");

  // ── Run both, capped identically. Clearance must CHANGE the design, and the
  // bore must be pinned void; no-clearance must be byte-identical run-to-run. ─
  s_none.options.simp.max_iterations = 8;
  s_clear.options.simp.max_iterations = 8;
  const MinimizePlasticResult r_none =
      topopt::minimize_plastic(s_none.grid, material, "PLA", s_none.bcs, rules, s_none.options);
  const MinimizePlasticResult r_clear =
      topopt::minimize_plastic(s_clear.grid, material, "PLA", s_clear.bcs, rules, s_clear.options);

  // Determinism of the no-clearance path (THE ONE RULE is only meaningful if the
  // baseline is itself reproducible).
  ProductionRunSetup s_none2 = build_production_loadcase(model, resolution, lc_none);
  s_none2.options.simp.max_iterations = 8;
  const MinimizePlasticResult r_none2 =
      topopt::minimize_plastic(s_none2.grid, material, "PLA", s_none2.bcs, rules, s_none2.options);
  CHECK(densities_identical(r_none, r_none2),
        "no-clearance run is bit-identical run-to-run (empty list == today)");

  // The clearance changed the design (it forbade growth somewhere).
  CHECK(!densities_identical(r_none, r_clear),
        "a declared clearance changes the optimized design");

  // The bore is pinned void in the clearance run's optimized density.
  if (!r_clear.evaluated.empty()) {
    const std::size_t bidx = voxel_at(r_clear.solved_grid, bore_centre);
    const auto& dens = r_clear.evaluated.front().optimization.physical_density;
    CHECK(bidx < dens.size() && dens[bidx] <= 0.5,
          "the bore stays open (void) under a bolt clearance");
  }

  if (g_failures == 0)
    std::printf("clearance parity (handoff 100): all checks passed\n");
  else
    std::printf("clearance parity: %d CHECK(s) FAILED\n", g_failures);
  return g_failures == 0 ? 0 : 1;
}
