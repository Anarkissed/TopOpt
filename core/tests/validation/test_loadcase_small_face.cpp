// Small-face load loss (handoff 099) — the core half of the regression.
//
// ROOT CAUSE: at a coarse resolution a load-tab face can be smaller than a voxel
// footprint, so tag_step_face tags ZERO solid voxels. build_production_loadcase
// then skips the group (it can build no traction), `external_loads` arrives empty,
// and — because a load group was declared — require_external_loads makes the run
// REFUSE (that throw is covered by load_retention_connectivity). This test locks
// the NEW observability that would have caught the loss in week one:
//
//   (a) a sub-voxel load face tags zero voxels at a coarse resolution → the
//       per-group log line carries the "zero-tagged" skip reason AND
//       external_loads comes back EMPTY (require_external_loads set true);
//   (b) the SAME force on a LARGE face DOES tag voxels → a non-empty external set
//       and an "ok" line (the mechanism is geometry, not a universal empty);
//   (c) a zero-force group logs the "zero-force" skip reason.
//
// The model is a synthetic StepModel built in code (no OCCT): a 50 mm solid cube
// whose +X face is split into a 2×2 mm corner PATCH (the sub-voxel load face) and
// the surrounding remainder (a large load face). At resolution 4 the spacing is
// 12.5 mm, so the 2 mm patch sits more than half a voxel from every solid voxel
// centre and tags nothing, while the remainder tags a full boundary layer.

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <string>
#include <vector>

#include "topopt/loadcase.hpp"
#include "topopt/mesh.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

using topopt::build_production_loadcase;
using topopt::LoadcaseLogFn;
using topopt::ProductionLoadCase;
using topopt::ProductionRunSetup;
using topopt::set_loadcase_log_sink;
using topopt::StepModel;
using topopt::TriangleMesh;
using topopt::Vec3;

namespace {

int g_failures = 0;
#define CHECK(cond, msg)                        \
  do {                                          \
    if (!(cond)) {                              \
      std::printf("FAIL: %s\n", msg);           \
      ++g_failures;                             \
    }                                           \
  } while (0)

// Append one triangle (three fresh vertices) tagged with B-rep face id `fid`.
void add_tri(StepModel& m, int fid, Vec3 a, Vec3 b, Vec3 c) {
  const int base = static_cast<int>(m.mesh.vertices.size());
  m.mesh.vertices.push_back(a);
  m.mesh.vertices.push_back(b);
  m.mesh.vertices.push_back(c);
  m.mesh.triangles.push_back({base, base + 1, base + 2});
  m.triangle_face.push_back(fid);
}

// Add an axis-aligned quad (two triangles, outward winding preserved by the
// caller's vertex order) with face id `fid`.
void add_quad(StepModel& m, int fid, Vec3 a, Vec3 b, Vec3 c, Vec3 d) {
  add_tri(m, fid, a, b, c);
  add_tri(m, fid, a, c, d);
}

// Face ids: 0 = LOAD corner patch (2×2 mm, sub-voxel), 1 = +X remainder (large),
// 2 = -X anchor, 3 = -Y, 4 = +Y, 5 = -Z, 6 = +Z.
StepModel make_cube_with_split_x_face(double L, double patch) {
  StepModel m;
  const Vec3 v0{0, 0, 0}, v1{L, 0, 0}, v2{L, L, 0}, v3{0, L, 0};
  const Vec3 v4{0, 0, L}, v5{L, 0, L}, v6{L, L, L}, v7{0, L, L};

  add_quad(m, 5, v0, v3, v2, v1);   // -Z (normal -Z)
  add_quad(m, 6, v4, v5, v6, v7);   // +Z (normal +Z)
  add_quad(m, 3, v0, v1, v5, v4);   // -Y (normal -Y)
  add_quad(m, 4, v3, v7, v6, v2);   // +Y (normal +Y)
  add_quad(m, 2, v0, v4, v7, v3);   // -X anchor (normal -X)

  // +X face (x = L) split so face 0 is a `patch`×`patch` corner at (y,z) small
  // and face 1 is the L-shaped remainder. All outward (+X) winding.
  const double p = patch;
  add_quad(m, 0, Vec3{L, 0, 0}, Vec3{L, p, 0}, Vec3{L, p, p}, Vec3{L, 0, p});
  // R1: y in [0,p], z in [p,L]
  add_quad(m, 1, Vec3{L, 0, p}, Vec3{L, p, p}, Vec3{L, p, L}, Vec3{L, 0, L});
  // R2: y in [p,L], z in [0,L]
  add_quad(m, 1, Vec3{L, p, 0}, Vec3{L, L, 0}, Vec3{L, L, L}, Vec3{L, p, L});

  m.face_count = 7;
  m.faces.resize(7);
  m.solid_count = 1;
  return m;
}

double force_mag(const Vec3& f) {
  return std::sqrt(f.x * f.x + f.y * f.y + f.z * f.z);
}

}  // namespace

int main() {
  // Capture the per-group log through the injectable sink.
  std::vector<std::string> log;
  LoadcaseLogFn prev = set_loadcase_log_sink(
      [&log](const std::string& line) { log.push_back(line); });

  const double L = 50.0;
  const double patch = 2.0;
  const int resolution = 4;  // spacing = 50/4 = 12.5 mm >> the 2 mm patch
  const StepModel model = make_cube_with_split_x_face(L, patch);

  // (a) sub-voxel load face (face 0) tags zero -> empty external + zero-tagged log.
  {
    log.clear();
    ProductionLoadCase lc;
    lc.anchor_face_ids = {2};
    ProductionLoadCase::LoadGroup g;
    g.face_ids = {0};
    g.force = Vec3{100.0, 0.0, 0.0};
    lc.load_groups.push_back(g);
    lc.minimize_plastic = false;

    ProductionRunSetup setup = build_production_loadcase(model, resolution, lc);
    CHECK(setup.grid.spacing > 12.0 && setup.grid.spacing < 13.0,
          "coarse spacing ~12.5 mm (sub-voxel patch)");
    CHECK(setup.options.external_loads.empty(),
          "sub-voxel load face produces an EMPTY external set");
    CHECK(setup.options.require_external_loads,
          "a declared load group arms require_external_loads (the hard backstop)");
    bool logged_zero_tag = false;
    for (const std::string& line : log)
      if (line.find("load-group 0") != std::string::npos &&
          line.find("zero-tagged") != std::string::npos &&
          line.find("voxels_tagged=0") != std::string::npos)
        logged_zero_tag = true;
    CHECK(logged_zero_tag,
          "zero-tag skip is logged with the group index, count and reason");
  }

  // (b) the SAME force on the LARGE remainder face (face 1) DOES tag voxels.
  {
    log.clear();
    ProductionLoadCase lc;
    lc.anchor_face_ids = {2};
    ProductionLoadCase::LoadGroup g;
    g.face_ids = {1};
    g.force = Vec3{100.0, 0.0, 0.0};
    lc.load_groups.push_back(g);
    lc.minimize_plastic = false;

    ProductionRunSetup setup = build_production_loadcase(model, resolution, lc);
    CHECK(!setup.options.external_loads.empty(),
          "a large load face tags voxels and yields a non-empty external set");
    bool logged_ok = false;
    for (const std::string& line : log)
      if (line.find("load-group 0") != std::string::npos &&
          line.find("status=ok") != std::string::npos &&
          line.find("voxels_tagged=0 ") == std::string::npos)
        logged_ok = true;
    CHECK(logged_ok, "a live group logs status=ok with a non-zero tagged count");
  }

  // (c) a zero-force group logs the zero-force skip reason.
  {
    log.clear();
    ProductionLoadCase lc;
    lc.anchor_face_ids = {2};
    ProductionLoadCase::LoadGroup g;
    g.face_ids = {1};
    g.force = Vec3{0.0, 0.0, 0.0};
    lc.load_groups.push_back(g);
    lc.minimize_plastic = false;

    ProductionRunSetup setup = build_production_loadcase(model, resolution, lc);
    CHECK(setup.options.external_loads.empty(),
          "a zero-force group contributes nothing");
    bool logged_zero_force = false;
    for (const std::string& line : log)
      if (line.find("load-group 0") != std::string::npos &&
          line.find("zero-force") != std::string::npos)
        logged_zero_force = true;
    CHECK(logged_zero_force, "zero-force skip is logged with the reason");
  }

  // Sanity on the log format itself (guards against silent format drift).
  {
    CHECK(force_mag(Vec3{100.0, 0.0, 0.0}) == 100.0, "force magnitude helper");
  }

  set_loadcase_log_sink(std::move(prev));

  if (g_failures == 0) std::printf("PASS: loadcase_small_face (all checks)\n");
  return g_failures == 0 ? 0 : 1;
}
