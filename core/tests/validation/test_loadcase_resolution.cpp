// Load-case face-id RESOLUTION legibility (task analyze-loadcase-resolution).
//
// THE DEVICE FAILURE (maintainer report, 2026-07-31): RUN SIM died with
//   "tag_step_face: face_id out of range"            — and, on other attempts —
//   "analyze: the load case resolved to no external load (...) nothing to
//    certify under"
// Both are surfaces of ONE defect class: the page-one face-id selectors were
// resolved against a model import that does not carry the id space they were
// authored on. The raw out-of-range throw (face_tag.cpp) named neither the id,
// nor the count available, nor the mesh; the empty-load-case refusal (bridge /
// run_job) discarded the per-group reasons build_production_loadcase had
// already computed. Neither message was actionable.
//
// This test pins the fix, on a synthetic in-code StepModel (no OCCT):
//   R1  an out-of-range ANCHOR id throws, and the message names the id, the
//       face count available, and the valid range;
//   R2  an out-of-range LOAD face id (in a live group) throws, and the message
//       additionally names the GROUP;
//   R3  a ZERO-FORCE group with an out-of-range id still does NOT throw — the
//       zero-force skip precedes resolution, exactly as before the fix (the
//       builder's observable semantics are unchanged);
//   R4  ProductionRunSetup carries structured per-group reports (index, faces,
//       |F|, voxels tagged, status) mirroring the log lines, so a front-end can
//       compose a legible refusal;
//   R5  the shared refusal composer (no_external_load_message) names EVERY
//       skipped group and WHY (zero force vs tagged-no-voxels-at-resolution),
//       so "nothing to certify under" is never the whole story;
//   R6  a face-id-LESS model (face_count == 0 — an exported variant mesh, or a
//       stored model whose face-overrides sidecar was lost) is called out
//       explicitly: the message says the mesh carries no face ids.

#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>

#include "topopt/loadcase.hpp"
#include "topopt/mesh.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

using topopt::build_production_loadcase;
using topopt::ProductionLoadCase;
using topopt::ProductionRunSetup;
using topopt::StepModel;
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

void add_quad(StepModel& m, int fid, Vec3 a, Vec3 b, Vec3 c, Vec3 d) {
  add_tri(m, fid, a, b, c);
  add_tri(m, fid, a, c, d);
}

// The loadcase_small_face cube: face ids 0 = 2×2 mm corner patch on +X
// (sub-voxel at resolution 4), 1 = +X remainder, 2 = -X anchor, 3..6 = the rest.
StepModel make_cube_with_split_x_face(double L, double patch) {
  StepModel m;
  const Vec3 v0{0, 0, 0}, v1{L, 0, 0}, v2{L, L, 0}, v3{0, L, 0};
  const Vec3 v4{0, 0, L}, v5{L, 0, L}, v6{L, L, L}, v7{0, L, L};

  add_quad(m, 5, v0, v3, v2, v1);   // -Z
  add_quad(m, 6, v4, v5, v6, v7);   // +Z
  add_quad(m, 3, v0, v1, v5, v4);   // -Y
  add_quad(m, 4, v3, v7, v6, v2);   // +Y
  add_quad(m, 2, v0, v4, v7, v3);   // -X anchor

  const double p = patch;
  add_quad(m, 0, Vec3{L, 0, 0}, Vec3{L, p, 0}, Vec3{L, p, p}, Vec3{L, 0, p});
  add_quad(m, 1, Vec3{L, 0, p}, Vec3{L, p, p}, Vec3{L, p, L}, Vec3{L, 0, L});
  add_quad(m, 1, Vec3{L, p, 0}, Vec3{L, L, 0}, Vec3{L, L, L}, Vec3{L, p, L});

  m.face_count = 7;
  m.faces.resize(7);
  m.solid_count = 1;
  return m;
}

// Run the builder expecting a throw; return the message ("" if none thrown).
std::string builder_error(const StepModel& model, int resolution,
                          const ProductionLoadCase& lc) {
  try {
    build_production_loadcase(model, resolution, lc);
  } catch (const std::exception& e) {
    return e.what();
  }
  return "";
}

bool contains(const std::string& s, const std::string& sub) {
  return s.find(sub) != std::string::npos;
}

}  // namespace

int main() {
  const double L = 50.0;
  const int resolution = 4;  // spacing 12.5 mm — the 2 mm patch is sub-voxel
  const StepModel model = make_cube_with_split_x_face(L, 2.0);

  // R1 — an out-of-range ANCHOR id fails loudly AND legibly: the id, the count
  // available, and the valid range are all in the message.
  {
    ProductionLoadCase lc;
    lc.anchor_face_ids = {137};
    ProductionLoadCase::LoadGroup g;
    g.face_ids = {1};
    g.force = Vec3{100.0, 0.0, 0.0};
    lc.load_groups.push_back(g);
    lc.minimize_plastic = false;

    const std::string what = builder_error(model, resolution, lc);
    CHECK(!what.empty(), "R1: an out-of-range anchor id throws");
    CHECK(contains(what, "out of range"), "R1: message says out of range");
    CHECK(contains(what, "137"), "R1: message names the offending id (137)");
    CHECK(contains(what, "7 faces"),
          "R1: message names the count available (7 faces)");
    CHECK(contains(what, "0..6"), "R1: message names the valid id range (0..6)");
    CHECK(contains(what, "anchor"), "R1: message says it was an ANCHOR face");
  }

  // R2 — an out-of-range LOAD face id (live group) names the GROUP too.
  {
    ProductionLoadCase lc;
    lc.anchor_face_ids = {2};
    ProductionLoadCase::LoadGroup g;
    g.face_ids = {9};
    g.force = Vec3{100.0, 0.0, 0.0};
    lc.load_groups.push_back(g);
    lc.minimize_plastic = false;

    const std::string what = builder_error(model, resolution, lc);
    CHECK(!what.empty(), "R2: an out-of-range load face id throws");
    CHECK(contains(what, "out of range"), "R2: message says out of range");
    CHECK(contains(what, "9"), "R2: message names the offending id (9)");
    CHECK(contains(what, "7 faces"),
          "R2: message names the count available (7 faces)");
    CHECK(contains(what, "load group 0"),
          "R2: message names the group the id came from");
  }

  // R3 — a ZERO-FORCE group with a bad id still does NOT throw: the zero-force
  // skip precedes resolution (pre-fix semantics preserved exactly).
  {
    ProductionLoadCase lc;
    lc.anchor_face_ids = {2};
    ProductionLoadCase::LoadGroup dead;
    dead.face_ids = {9999};
    dead.force = Vec3{0.0, 0.0, 0.0};
    lc.load_groups.push_back(dead);
    ProductionLoadCase::LoadGroup live;
    live.face_ids = {1};
    live.force = Vec3{100.0, 0.0, 0.0};
    lc.load_groups.push_back(live);
    lc.minimize_plastic = false;

    const std::string what = builder_error(model, resolution, lc);
    CHECK(what.empty(),
          "R3: a zero-force group's ids are never resolved (no throw)");
  }

  // R4 — structured per-group reports mirror the log: statuses, counts, |F|.
  {
    ProductionLoadCase lc;
    lc.anchor_face_ids = {2};
    ProductionLoadCase::LoadGroup sub;    // sub-voxel patch: tags nothing
    sub.face_ids = {0};
    sub.force = Vec3{100.0, 0.0, 0.0};
    lc.load_groups.push_back(sub);
    ProductionLoadCase::LoadGroup dead;   // zero force
    dead.face_ids = {1};
    dead.force = Vec3{0.0, 0.0, 0.0};
    lc.load_groups.push_back(dead);
    lc.minimize_plastic = false;

    const ProductionRunSetup setup =
        build_production_loadcase(model, resolution, lc);
    CHECK(setup.options.external_loads.empty(),
          "R4: both groups contribute nothing (empty external set)");
    CHECK(setup.load_group_reports.size() == 2,
          "R4: one report per declared group");
    if (setup.load_group_reports.size() == 2) {
      const auto& r0 = setup.load_group_reports[0];
      CHECK(r0.index == 0 && r0.voxels_tagged == 0 &&
                r0.status == topopt::LoadGroupReport::Status::ZeroTagged,
            "R4: group 0 reports zero-tagged with 0 voxels");
      CHECK(r0.face_ids == std::vector<int>{0} &&
                std::fabs(r0.force_mag - 100.0) < 1e-12,
            "R4: group 0 report carries its faces and |F|");
      const auto& r1 = setup.load_group_reports[1];
      CHECK(r1.index == 1 &&
                r1.status == topopt::LoadGroupReport::Status::ZeroForce,
            "R4: group 1 reports zero-force");
    }

    // R5 — the shared refusal composer names every group and why.
    const std::string msg =
        topopt::no_external_load_message(setup, resolution);
    CHECK(contains(msg, "group 0"), "R5: refusal names group 0");
    CHECK(contains(msg, "no voxels"),
          "R5: refusal says group 0's faces tagged no voxels");
    CHECK(contains(msg, "resolution 4"),
          "R5: refusal names the resolution the tagging ran at");
    CHECK(contains(msg, "group 1"), "R5: refusal names group 1");
    CHECK(contains(msg, "zero force"),
          "R5: refusal says group 1 has zero force");
  }

  // R4b — a HEALTHY group reports Ok with a non-zero tagged count.
  {
    ProductionLoadCase lc;
    lc.anchor_face_ids = {2};
    ProductionLoadCase::LoadGroup g;
    g.face_ids = {1};
    g.force = Vec3{100.0, 0.0, 0.0};
    lc.load_groups.push_back(g);
    lc.minimize_plastic = false;

    const ProductionRunSetup setup =
        build_production_loadcase(model, resolution, lc);
    CHECK(!setup.options.external_loads.empty(),
          "R4b: the large face yields a non-empty external set");
    CHECK(setup.load_group_reports.size() == 1 &&
              setup.load_group_reports[0].status ==
                  topopt::LoadGroupReport::Status::Ok &&
              setup.load_group_reports[0].voxels_tagged > 0,
          "R4b: a live group reports Ok with its tagged voxel count");
  }

  // R6 — a face-id-less model (face_count == 0: an exported variant mesh, or a
  // stored model whose face-overrides sidecar was lost) is called out as such.
  {
    StepModel bare = model;
    bare.face_count = 0;   // the mesh survives; the id space does not
    bare.faces.clear();
    ProductionLoadCase lc;
    lc.anchor_face_ids = {3};
    ProductionLoadCase::LoadGroup g;
    g.face_ids = {1};
    g.force = Vec3{100.0, 0.0, 0.0};
    lc.load_groups.push_back(g);
    lc.minimize_plastic = false;

    const std::string what = builder_error(bare, resolution, lc);
    CHECK(!what.empty(), "R6: ids against a face-id-less model throw");
    CHECK(contains(what, "no face ids"),
          "R6: message says the mesh carries NO face ids at all");
  }

  if (g_failures == 0)
    std::printf("PASS: loadcase_resolution (all checks)\n");
  return g_failures == 0 ? 0 : 1;
}
