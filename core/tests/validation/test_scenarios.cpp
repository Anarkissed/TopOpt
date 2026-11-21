// LOAD SCENARIOS, engine (the reviewer's overnight ruling of 2026-10-26 03:45). Every
// optimizer iteration solves every scenario and the worst governs (a smooth max of the
// normalised compliances); every scenario is certified and the worst sets the margin;
// an anchor OFF in a scenario is held by weak springs, never removed, and a scenario
// whose weak springs carry its load is "unheld" (its load has no path to its anchors).
//
// Two blocks with a gap of free design space between them, both standing on their
// own anchor and loaded on top (cf. Cool, Aage & Sigmund 2025, a load case whose only
// path is the connection):
//   (a) ONE scenario, both blocks anchored, printed for context only: compliance always
//       gains a little from more material and the gap is the only free space, so even
//       one load case fills it here (measured 2026-10-26: one body at vf 0.70-0.80). It
//       is not a control; the checks are on (b);
//   (b) TWO scenarios: (1) the same; (2) block B's anchor OFF and a push on block B.
//       The push can only reach an anchor through the gap, so the design joins the
//       blocks: one body, scenario 2 held (its weak springs carry < 5 %), and the
//       report carries both scenarios with the worst governing;
//   (c) the schema: one scenario is today's job (ignored); a scenario with no anchor ON
//       and scenarios with bearing anchors are refused.
// Eigen (minimize_plastic), OCCT-free.

#include "topopt/fea.hpp"
#include "topopt/job.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/report.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

using namespace topopt;

static int g_failures = 0;
static int g_checks = 0;
#define CHECK(cond, msg)                                            \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

namespace {

Material fdm() {
  Material m;
  m.youngs_modulus_mpa = 3500.0; m.yield_strength_mpa = 55.0;
  m.density_g_cm3 = 1.24; m.z_knockdown = 0.55; m.poisson = 0.33; m.family = "fdm";
  return m;
}

void clamp_voxel_nodes(const VoxelGrid& g, int i, int j, int k, std::vector<DirichletBC>& bcs) {
  for (int c = 0; c < 8; ++c) {
    const int n = fea_node_index(g, i + (c & 1), j + ((c >> 1) & 1), k + ((c >> 2) & 1));
    for (int d = 0; d < 3; ++d) bcs.push_back({n, d, 0.0});
  }
}

void weak_voxel_nodes(const VoxelGrid& g, int i, int j, int k, std::vector<DirichletBC>& bcs) {
  const double kw = 1.0;  // a placeholder, as the load case's: minimize_plastic sizes it
  for (int c = 0; c < 8; ++c) {
    DirichletBC b;
    b.node = fea_node_index(g, i + (c & 1), j + ((c >> 1) & 1), k + ((c >> 2) & 1));
    b.spring = kw;
    b.spring_tangent = kw;
    b.normal = Vec3{1.0, 0.0, 0.0};
    b.contact = false;
    bcs.push_back(b);
  }
}

int carrying_bodies(const MinimizePlasticResult& r) {
  const PrintedBodies pb =
      printed_bodies(r.solved_grid, r.evaluated.front().optimization.physical_density, 0.5);
  int n = 0;
  for (const PrintedBody& b : pb.bodies) n += b.carries();
  return n;
}

bool refused(const std::string& scenarios_json, const std::string& extra = "") {
  const std::string path = std::string(TMP_DIR) + "/scenarios_schema_job.json";
  std::ofstream(path) << "{\"model\": \"plate_bore.stl\", \"material\": \"PLA\", "
                         "\"mode\": \"minimize_plastic\", \"resolution\": 32, "
                         "\"loads\": {\"anchor_face_ids\": [0], " << extra
                      << "\"groups\": [{\"face_ids\": [1], \"force\": [1, 0, 0]}], "
                         "\"scenarios\": " << scenarios_json
                      << "}, \"output\": {\"report\": \"r.json\", \"mesh_format\": \"stl\", "
                         "\"mesh_prefix\": \"v\"}}";
  try {
    const JobDescription j = load_job_file(path);
    return false;
  } catch (const std::exception&) {
    return true;
  }
}

}  // namespace

int main() {
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);

  // The bar: blocks A (i < 4) and B (i >= 8), frozen, each anchored at its foot and
  // loaded on its head; the gap between them (4 <= i < 8) is free design space.
  VoxelGrid g;
  g.nx = 12; g.ny = 3; g.nz = 6; g.spacing = 2.0;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(g.nx) * g.ny * g.nz, VoxelTag::Interior);
  DesignMask frozen(g.voxel_count(), MaskValue::Active);
  std::vector<DirichletBC> both, a_only;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        const bool a = i < 4, b = i >= 8;
        if (!a && !b) continue;
        frozen[g.index(i, j, k)] = MaskValue::FrozenSolid;
        if (k == 0) {
          g.set_tag(i, j, k, VoxelTag::Fixture);
          clamp_voxel_nodes(g, i, j, k, both);
          if (a) clamp_voxel_nodes(g, i, j, k, a_only);
          else weak_voxel_nodes(g, i, j, k, a_only);
        }
        if (k == g.nz - 1) g.set_tag(i, j, k, VoxelTag::Load);
      }
  const std::vector<NodalLoad> on_both = traction_loads(g, VoxelTag::Load, Vec3{0.0, 0.0, -4.0});
  VoxelGrid only_b = g;
  for (int j = 0; j < g.ny; ++j)
    for (int i = 0; i < 4; ++i) only_b.set_tag(i, j, g.nz - 1, VoxelTag::Interior);
  const std::vector<NodalLoad> push_b =
      traction_loads(only_b, VoxelTag::Load, Vec3{0.0, 0.0, -4.0});

  auto run = [&](bool two) {
    MinimizePlasticOptions o;
    o.volume_fraction_ladder = {0.75};
    o.margin_stop = 1.5;
    o.external_loads = on_both;
    o.gravity = 9810.0 * 1e-9;
    o.gravity_direction = Vec3{0.0, 0.0, -1.0};
    o.updater = SimpUpdater::MMA;
    o.infill_percent = 100.0;
    o.bake_build_orientation = BakeBuildOrientation::Off;
    o.design_box = DesignBox{g.origin, Vec3{g.origin.x + g.nx * g.spacing,
                                            g.origin.y + g.ny * g.spacing,
                                            g.origin.z + g.nz * g.spacing}};
    o.design_mask = frozen;
    // The gap starts EMPTY (the density floor), so only a reason to join the blocks
    // puts material there: one load case has none, the push on B does.
    o.initial_design.assign(g.voxel_count(), 1e-3);
    for (std::size_t e = 0; e < frozen.size(); ++e)
      if (frozen[e] == MaskValue::FrozenSolid) o.initial_design[e] = 1.0;
    if (two) {
      o.scenarios.push_back(SimpScenario{"both anchored", both, on_both});
      o.scenarios.push_back(SimpScenario{"B unanchored, pushed", a_only, push_b});
    }
    return minimize_plastic(g, fdm(), "fdm", both, rules, o);
  };

  try {
    // ── (a) one scenario, for context ─────────────────────────────────────────
    const MinimizePlasticResult one = run(false);
    std::printf("[scenarios] one scenario (context): %d carrying bodies, margin %.3f\n",
                carrying_bodies(one), one.evaluated.front().report.margin_effective);

    // ── (b) two scenarios ─────────────────────────────────────────────────────
    const MinimizePlasticResult two = run(true);
    const VariantReport& r = two.evaluated.front().report;
    std::printf("[scenarios] two scenarios: %d carrying bodies, %s%s%s, margin %.3f\n",
                carrying_bodies(two), two.evaluated.front().accepted ? "accepted" : "rejected",
                r.rejection_reason.empty() ? "" : " - ", r.rejection_reason.c_str(),
                r.margin_effective);
    for (const ScenarioReport& s : r.scenarios)
      std::printf("[scenarios]   \"%s\": margin %.3f, peak %.3f MPa at (%.1f, %.1f, %.1f), "
                  "weak springs %.2f %%%s%s\n", s.name.c_str(), s.margin, s.peak_mpa,
                  s.peak_mm.x, s.peak_mm.y, s.peak_mm.z, 100.0 * s.weak_share,
                  s.governs ? ", GOVERNS" : "", s.unheld ? ", UNHELD" : "");
    CHECK(carrying_bodies(two) == 1, "(b) the push on B joins the blocks: one body");
    CHECK(r.scenarios.size() == 2, "(b) the line carries both scenarios");
    if (r.scenarios.size() == 2) {
      CHECK(!r.scenarios[1].unheld && r.scenarios[1].weak_share < 0.05,
            "(b) scenario 2's push reaches block A's anchor (held)");
      CHECK(r.scenarios[0].governs != r.scenarios[1].governs,
            "(b) exactly one scenario governs");
      const ScenarioReport& gov = r.scenarios[0].governs ? r.scenarios[0] : r.scenarios[1];
      CHECK(gov.margin <= r.scenarios[0].margin && gov.margin <= r.scenarios[1].margin &&
                std::fabs(gov.margin - r.margin_effective) < 1e-12,
            "(b) the worst scenario's margin is the line's");
    }
    CHECK(two.evaluated.front().accepted, "(b) the joined design is accepted");
    const std::string json = job_report_json([&] {
      JobReport jr;
      jr.material = "fdm";
      jr.variants.push_back(r);
      return jr;
    }());
    CHECK(json.find("\"scenarios\": [{\"name\": \"both anchored\"") != std::string::npos &&
              json.find("\"governs\": true") != std::string::npos &&
              json.find("\"unheld\": false") != std::string::npos,
          "(b) report.json carries \"scenarios\" with the shared key");
  } catch (const std::exception& e) {
    ++g_failures;
    std::fprintf(stderr, "FAIL: threw: %s\n", e.what());
  }

  // ── (c) the schema ──────────────────────────────────────────────────────────
  CHECK(!refused("[{\"name\": \"one\", \"groups\": [{\"face_ids\": [1], \"force\": [1, 0, 0]}], "
                 "\"anchor_face_ids\": [0]}]"),
        "(c) one scenario parses (today's job)");
  CHECK(refused("[{\"name\": \"a\", \"groups\": [{\"face_ids\": [1], \"force\": [1, 0, 0]}], "
                "\"anchor_face_ids\": [0]}, {\"name\": \"b\", \"groups\": [{\"face_ids\": [1], "
                "\"force\": [0, 1, 0]}], \"anchor_face_ids\": []}]"),
        "(c) a scenario with no anchor ON is refused");
  CHECK(refused("[{\"name\": \"a\", \"groups\": [{\"face_ids\": [1], \"force\": [1, 0, 0]}], "
                "\"anchor_face_ids\": [0]}, {\"name\": \"b\", \"groups\": [{\"face_ids\": [1], "
                "\"force\": [0, 1, 0]}], \"anchor_face_ids\": [0]}]",
                "\"anchor_model\": \"bearing\", "),
        "(c) scenarios with bearing anchors are refused (not supported yet)");

  if (g_failures == 0) {
    std::printf("scenarios (load scenarios, engine): all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "scenarios (load scenarios, engine): %d/%d checks FAILED\n", g_failures,
               g_checks);
  return 1;
}
