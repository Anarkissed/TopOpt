// LOAD SCENARIOS COUNT IN PROPORTION TO THEIR LOAD (his ask, 2026-10-28: "I want the
// tendrils to connect the two arms together, not have hard lines, but organic ones").
// The smooth max over scenarios measured each scenario against its OWN first compliance,
// and compliance scales as load^2, so a scenario's load cancelled: a 0.5 kg twist pulled
// as hard as his 51 kg main case and grew a full-strength bridge, and without the twist
// the arms never joined. Now every scenario is measured against ONE reference (the first
// compliance of the scenario with the largest load), so a light cross scenario still
// forces a connection, a thin one, and the connection follows its load.
//
// Two arms (6 x 4 x 12 voxels) 12 voxels apart in one free box, each held at its foot and
// pushed down on its head (the main scenario); two CROSS scenarios each push one arm's
// head with only the OTHER arm's foot held (the first arm's foot OFF, on weak springs),
// at 1 / 5 / 20 % of the main load. The connection is the material between the arms:
//   (a) one scenario only, for context: the arms stay apart (two columns);
//   (b) at 1 %, one carrying body and no fallback bridge;
//   (c) the connection's material grows with the cross load, 1 % < 5 % < 20 %;
//   (d) at every cross load each scenario is HELD (its connection, not the weak springs
//       of its OFF anchor, carries it) and the design is accepted.
// Eigen (minimize_plastic), OCCT-free.

#include "topopt/fea.hpp"
#include "topopt/job.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/production.hpp"
#include "topopt/report.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstdio>
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

constexpr int kNx = 24, kNy = 4, kNz = 12;
constexpr int kArm = 6;  // arm A at i < 6, arm B at i >= 18; the gap between is free

bool arm_a(int i) { return i < kArm; }
bool arm_b(int i) { return i >= kNx - kArm; }

void clamp_voxel_nodes(const VoxelGrid& g, int i, int j, int k, std::vector<DirichletBC>& bcs) {
  for (int c = 0; c < 8; ++c) {
    const int n = fea_node_index(g, i + (c & 1), j + ((c >> 1) & 1), k + ((c >> 2) & 1));
    for (int d = 0; d < 3; ++d) bcs.push_back({n, d, 0.0});
  }
}

void weak_voxel_nodes(const VoxelGrid& g, int i, int j, int k, std::vector<DirichletBC>& bcs) {
  for (int c = 0; c < 8; ++c) {
    DirichletBC b;
    b.node = fea_node_index(g, i + (c & 1), j + ((c >> 1) & 1), k + ((c >> 2) & 1));
    b.spring = 1.0;  // a placeholder, as the load case's: minimize_plastic sizes it
    b.spring_tangent = 1.0;
    b.normal = Vec3{1.0, 0.0, 0.0};
    b.contact = false;
    bcs.push_back(b);
  }
}

struct Outcome {
  int bodies = 0;
  int bridges = 0;
  double connection = 0.0;  // sum of the physical density between the arms
  long long connection_printed = 0;
  bool accepted = false;
  bool all_held = true;
  std::string governs;
  std::string margins;  // "name margin (weak share %)" per scenario
};

}  // namespace

int main() {
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  VoxelGrid g;
  g.nx = kNx; g.ny = kNy; g.nz = kNz; g.spacing = 1.0;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(g.nx) * g.ny * g.nz, VoxelTag::Interior);
  DesignMask frozen(g.voxel_count(), MaskValue::Active);
  std::vector<DirichletBC> both, a_held, b_held;  // b_held: A's foot OFF, B's held
  for (int j = 0; j < g.ny; ++j)
    for (int i = 0; i < g.nx; ++i) {
      if (!arm_a(i) && !arm_b(i)) continue;
      frozen[g.index(i, j, 0)] = MaskValue::FrozenSolid;
      frozen[g.index(i, j, g.nz - 1)] = MaskValue::FrozenSolid;
      g.set_tag(i, j, 0, VoxelTag::Fixture);
      g.set_tag(i, j, g.nz - 1, VoxelTag::Load);
      clamp_voxel_nodes(g, i, j, 0, both);
      if (arm_a(i)) {
        clamp_voxel_nodes(g, i, j, 0, a_held);
        weak_voxel_nodes(g, i, j, 0, b_held);
      } else {
        weak_voxel_nodes(g, i, j, 0, a_held);
        clamp_voxel_nodes(g, i, j, 0, b_held);
      }
    }
  const Vec3 main_push{0.0, 0.0, -20.0};
  const std::vector<NodalLoad> on_both = traction_loads(g, VoxelTag::Load, main_push);
  auto head_of = [&](bool a) {
    VoxelGrid only = g;
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i)
        if ((a ? arm_b(i) : arm_a(i)) && only.tag(i, j, g.nz - 1) == VoxelTag::Load)
          only.set_tag(i, j, g.nz - 1, VoxelTag::Interior);
    return only;
  };
  const VoxelGrid only_a = head_of(true), only_b = head_of(false);

  auto run = [&](double cross) {
    MinimizePlasticOptions o;
    configure_production_options(o);  // the production solver (matrix-free multigrid)
    o.volume_fraction_ladder = {0.30};
    o.margin_stop = 0.0;
    o.external_loads = on_both;
    o.gravity = 0.0;
    o.updater = SimpUpdater::MMA;
    o.infill_percent = 100.0;
    o.bake_build_orientation = BakeBuildOrientation::Off;
    o.bridge_pieces = true;  // the fallback the production load case arms
    o.design_box = DesignBox{g.origin, Vec3{g.origin.x + g.nx * g.spacing,
                                            g.origin.y + g.ny * g.spacing,
                                            g.origin.z + g.nz * g.spacing}};
    o.design_mask = frozen;
    if (cross > 0.0) {
      const Vec3 f{cross * main_push.x, cross * main_push.y, cross * main_push.z};
      o.scenarios.push_back(SimpScenario{"both held", both, on_both});
      // Arm A pushed, only B's foot held; and the mirror.
      o.scenarios.push_back(SimpScenario{"A pushed, B held", b_held,
                                         traction_loads(only_a, VoxelTag::Load, f)});
      o.scenarios.push_back(SimpScenario{"B pushed, A held", a_held,
                                         traction_loads(only_b, VoxelTag::Load, f)});
    }
    const MinimizePlasticResult r = minimize_plastic(g, fdm(), "fdm", both, rules, o);
    Outcome out;
    const MinimizePlasticVariant& v = r.evaluated.front();
    const std::vector<double>& rho = v.optimization.physical_density;
    const VoxelGrid& G = r.solved_grid;
    const PrintedBodies pb = printed_bodies(G, rho, 0.5);
    for (const PrintedBody& b : pb.bodies) out.bodies += b.carries();
    out.bridges = v.report.bridges;
    out.accepted = v.accepted;
    for (const ScenarioReport& s : v.report.scenarios) {
      if (s.governs) out.governs = s.name;
      out.all_held = out.all_held && !s.unheld;
      char buf[160];
      std::snprintf(buf, sizeof buf, "%s\"%s\" %.2f (weak %.2f %%)",
                    out.margins.empty() ? "" : ", ", s.name.c_str(), s.margin,
                    100.0 * s.weak_share);
      out.margins += buf;
    }
    for (int k = 0; k < G.nz; ++k)
      for (int j = 0; j < G.ny; ++j)
        for (int i = 0; i < G.nx; ++i) {
          const double x = G.voxel_center(i, j, k).x;
          if (x < kArm || x > kNx - kArm) continue;
          const double d = rho[G.index(i, j, k)];
          out.connection += d;
          out.connection_printed += d > 0.5;
        }
    return out;
  };

  try {
    const Outcome one = run(0.0);
    std::printf("[weights] main scenario only (context): %d carrying bodies, %d bridge(s), "
                "connection %.2f (%lld printed voxels)\n",
                one.bodies, one.bridges, one.connection, one.connection_printed);
    CHECK(one.bodies + one.bridges >= 2, "(a) one load case alone leaves the arms apart");

    const double crosses[] = {0.01, 0.05, 0.20};
    Outcome at[3];
    for (int c = 0; c < 3; ++c) {
      at[c] = run(crosses[c]);
      std::printf("[weights] cross scenarios at %.0f %%: %d carrying bodies, %d bridge(s), "
                  "connection %.2f (%lld printed voxels), governs \"%s\"\n",
                  100.0 * crosses[c], at[c].bodies, at[c].bridges, at[c].connection,
                  at[c].connection_printed, at[c].governs.c_str());
      std::printf("[weights]   margins: %s; %s\n", at[c].margins.c_str(),
                  at[c].accepted ? "accepted" : "NOT accepted");
    }
    CHECK(at[0].bodies == 1 && at[0].bridges == 0,
          "(b) a light cross load joins the arms itself: one body, no fallback bridge");
    CHECK(at[0].connection < at[1].connection && at[1].connection < at[2].connection,
          "(c) the connection grows with the cross load");
    for (int c = 0; c < 3; ++c)
      CHECK(at[c].all_held && at[c].accepted,
            "(d) every scenario is held by the connection and the design is accepted");
  } catch (const std::exception& e) {
    ++g_failures;
    std::fprintf(stderr, "FAIL: threw: %s\n", e.what());
  }

  if (g_failures == 0) {
    std::printf("scenario weights: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "scenario weights: %d/%d checks FAILED\n", g_failures, g_checks);
  return 1;
}
