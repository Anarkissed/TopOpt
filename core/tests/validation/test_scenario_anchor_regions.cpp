// LOAD SCENARIOS: a scenario's own REGION anchors (UI-Notes' ask, BuildGroup 2026-11-03
// 02:52; reviewer's routing 04:16). A scenario names the anchors ON in it by face id
// ("anchor_face_ids") and, now, by region ("anchor_region_ids": ids into
// loads.face_regions) — a cut piece of a face set as an anchor. Before, a scenario took
// only face ids, so a cut-piece anchor never reached scenario 2+, and a scenario whose
// only anchor was a cut piece was refused as "has no anchor switched on".
//
// A bar 40 x 10 x 10 mm loaded down on its top in both scenarios. Scenario 1 stands on
// its -x end (a face); scenario 2 stands only on the LOWER HALF of its +x end (a cut
// piece: the +x face cut at z = 5):
//   (a) the job parses (it was refused);
//   (b) the load case's region anchors are the scenarios' UNION, and each scenario
//       clamps exactly its own: scenario 2's clamped nodes are all on the cut piece,
//       and each scenario holds the other's anchor only by weak springs (OFF there);
//   (c) without the key in any scenario, today's rule: a region anchor is ON in every
//       scenario;
//   (d) a scenario naming a region that does not exist is refused, naming it;
//   (e) the run: scenario 2 HOLDS (its load reaches the cut piece; not "unheld") and a
//       version is accepted.

#include "topopt/job.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/part.hpp"
#include "topopt/settings.hpp"
#include "topopt/step.hpp"
#include "topopt/stl.hpp"

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

TriangleMesh box(double lx, double ly, double lz) {
  TriangleMesh m;
  for (int c = 0; c < 8; ++c)
    m.vertices.push_back({(c & 1) ? lx : 0.0, (c & 2) ? ly : 0.0, (c & 4) ? lz : 0.0});
  const int f[12][3] = {{0, 2, 1}, {1, 2, 3}, {4, 5, 6}, {5, 7, 6}, {0, 1, 4}, {1, 5, 4},
                        {2, 6, 3}, {3, 6, 7}, {0, 4, 2}, {2, 4, 6}, {1, 3, 5}, {3, 7, 5}};
  for (const auto& t : f) m.triangles.push_back({t[0], t[1], t[2]});
  return m;
}

int face_facing(const StepModel& model, double nx, double ny, double nz) {
  for (int f = 0; f < model.face_count; ++f) {
    const StepFaceInfo& fi = model.faces[static_cast<std::size_t>(f)];
    const Vec3& n = fi.plane_normal;
    if (fi.kind == StepSurfaceKind::Plane && n.x * nx + n.y * ny + n.z * nz > 0.99) return f;
  }
  return -1;
}

// The job: scenario 1's extra keys `s1_extra`, scenario 2's anchor keys `s2_anchor_keys`.
std::string job_json(int end_a, int end_b, int top, const std::string& top_level_regions,
                     const std::string& s1_extra, const std::string& s2_anchor_keys) {
  const std::string group =
      "[{\"face_ids\": [" + std::to_string(top) + "], \"force\": [0, 0, -50]}]";
  return "{\"model\": \"scenario_regions_bar.stl\", \"material\": \"PLA\", "
         "\"mode\": \"minimize_plastic\", \"resolution\": 32, \"loads\": {"
         "\"anchor_face_ids\": [" + std::to_string(end_a) + "], " + top_level_regions +
         "\"face_regions\": [{\"id\": 7, \"name\": \"lower half of the end\", \"add\": [" +
         std::to_string(end_b) +
         "], \"cuts\": [{\"point\": [40, 5, 5], \"normal\": [0, 0, -1]}]}], "
         "\"groups\": " + group + ", \"scenarios\": ["
         "{\"name\": \"on its end\", \"groups\": " + group + ", \"anchor_face_ids\": [" +
         std::to_string(end_a) + "]" + s1_extra + "}, "
         "{\"name\": \"on the cut piece\", \"groups\": " + group + ", " + s2_anchor_keys +
         "}]}, \"output\": {\"report\": \"report.json\", \"mesh_format\": \"stl\", "
         "\"mesh_prefix\": \"variant\"}}";
}

struct Holds {
  int clamped = 0;          // clamped nodes
  int clamped_off_end = 0;  // of them, not on the cut piece's voxels (x ~ 40, z <= 5)
  int weak = 0;             // weak-spring nodes
};
Holds holds(const ProductionRunSetup& s, std::size_t sc) {
  Holds h;
  const VoxelGrid& g = s.grid;
  const int nx1 = g.nx + 1, ny1 = g.ny + 1;
  for (const DirichletBC& b : s.options.scenarios[sc].bcs) {
    if (b.spring > 0.0) {
      ++h.weak;
      continue;
    }
    if (b.component != 0) continue;  // one count per node
    ++h.clamped;
    const int i = b.node % nx1, k = b.node / (nx1 * ny1);
    const double x = g.origin.x + i * g.spacing, z = g.origin.z + k * g.spacing;
    // An anchor voxel clamps its 8 corners: the end face's nodes and those one voxel in.
    h.clamped_off_end +=
        !(x >= 40.0 - 1.5 * g.spacing && x <= 40.0 + 0.5 * g.spacing && z <= 5.0 + g.spacing);
  }
  return h;
}

}  // namespace

int main() {
  const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  const std::string dir = TMP_DIR;
  write_stl_file(dir + "/scenario_regions_bar.stl", box(40.0, 10.0, 10.0));
  const StepModel bar = import_part(dir + "/scenario_regions_bar.stl").model;
  const int end_a = face_facing(bar, -1, 0, 0), end_b = face_facing(bar, 1, 0, 0),
            top = face_facing(bar, 0, 0, 1);
  CHECK(end_a >= 0 && end_b >= 0 && top >= 0, "precondition: the bar's ends and top");

  // ── (a) + (b) ──────────────────────────────────────────────────────────────
  const std::string with_key =
      job_json(end_a, end_b, top, "", ", \"anchor_region_ids\": []",
               "\"anchor_face_ids\": [], \"anchor_region_ids\": [7]");
  JobDescription job;
  bool parsed = false;
  try {
    job = parse_job(with_key);
    parsed = true;
  } catch (const std::exception& e) {
    std::fprintf(stderr, "  (a) refused: %s\n", e.what());
  }
  CHECK(parsed, "(a) a scenario whose only anchor is a cut piece parses");
  if (parsed) {
    try {
      const ProductionLoadCase lc = production_loadcase_from_job(job, bar);
      CHECK(lc.anchor_region_ids.size() == 1 && lc.anchor_region_ids[0] == 7,
            "(b) the load case's region anchors are the scenarios' union");
      const ProductionRunSetup s = build_production_loadcase(bar, job.resolution, lc);
      CHECK(s.options.scenarios.size() == 2, "(b) two scenarios");
      if (s.options.scenarios.size() == 2) {
        const Holds h1 = holds(s, 0), h2 = holds(s, 1);
        std::printf("[scenario-regions] (b) scenario 1: %d clamped, %d weak; scenario 2: %d "
                    "clamped (%d off the cut piece), %d weak\n",
                    h1.clamped, h1.weak, h2.clamped, h2.clamped_off_end, h2.weak);
        CHECK(h2.clamped > 0 && h2.clamped_off_end == 0,
              "(b) scenario 2 clamps the cut piece, and only it");
        CHECK(h1.weak > 0 && h2.weak > 0,
              "(b) each scenario holds the other's anchor by weak springs (OFF there)");
      }
    } catch (const std::exception& e) {
      ++g_failures;
      std::fprintf(stderr, "FAIL: (b) threw: %s\n", e.what());
    }
  }

  // ── (c) no key anywhere: today's rule ──────────────────────────────────────
  try {
    const JobDescription old = parse_job(
        job_json(end_a, end_b, top, "\"anchor_region_ids\": [7], ", "",
                 "\"anchor_face_ids\": [" + std::to_string(end_a) + "]"));
    const ProductionRunSetup s =
        build_production_loadcase(bar, old.resolution, production_loadcase_from_job(old, bar));
    const Holds h1 = holds(s, 0), h2 = holds(s, 1);
    // The same job with no region anchor at all: the face anchor alone.
    const JobDescription bare = parse_job(
        job_json(end_a, end_b, top, "", "", "\"anchor_face_ids\": [" + std::to_string(end_a) + "]"));
    const ProductionRunSetup s0 =
        build_production_loadcase(bar, bare.resolution, production_loadcase_from_job(bare, bar));
    const Holds f1 = holds(s0, 0);
    std::printf("[scenario-regions] (c) no key: scenario 1 %d clamped, scenario 2 %d clamped "
                "(the face anchor alone %d); weak %d / %d\n",
                h1.clamped, h2.clamped, f1.clamped, h1.weak, h2.weak);
    CHECK(h1.clamped == h2.clamped && h1.clamped > f1.clamped && h1.weak == 0 && h2.weak == 0,
          "(c) without the key a region anchor is ON in every scenario (today's rule)");
  } catch (const std::exception& e) {
    ++g_failures;
    std::fprintf(stderr, "FAIL: (c) threw: %s\n", e.what());
  }

  // ── (d) a region that does not exist ───────────────────────────────────────
  {
    std::string why;
    try {
      const JobDescription bad = parse_job(
          job_json(end_a, end_b, top, "", ", \"anchor_region_ids\": []",
                   "\"anchor_face_ids\": [], \"anchor_region_ids\": [9]"));
      (void)build_production_loadcase(bar, bad.resolution,
                                      production_loadcase_from_job(bad, bar));
    } catch (const std::exception& e) {
      why = e.what();
    }
    std::printf("[scenario-regions] (d) unknown region: \"%s\"\n", why.c_str());
    CHECK(why.find("on the cut piece") != std::string::npos && why.find('9') != std::string::npos,
          "(d) a scenario naming a missing region is refused, naming the scenario and the id");
  }

  // ── (e) the run ────────────────────────────────────────────────────────────
  if (parsed) {
    try {
      JobDescription j = job;
      j.ladder = {0.5};
      j.bake_build_orientation = "off";
      const RunJobResult r = run_job(j, dir, dir + "/scenario_regions_run", materials, rules);
      const std::string& rep = r.report_json;
      const std::size_t s2 = rep.find("\"name\": \"on the cut piece\"");
      const std::size_t un = s2 == std::string::npos ? s2 : rep.find("\"unheld\": ", s2);
      const bool unheld = un != std::string::npos && rep.compare(un + 10, 4, "true") == 0;
      std::printf("[scenario-regions] (e) %zu file(s); scenario 2 in the report: %s, unheld: %s\n",
                  r.mesh_paths.size(), s2 == std::string::npos ? "no" : "yes",
                  unheld ? "yes" : "no");
      CHECK(s2 != std::string::npos && !unheld, "(e) the scenario on the cut piece holds");
      CHECK(!r.mesh_paths.empty(), "(e) a version is accepted");
    } catch (const std::exception& e) {
      ++g_failures;
      std::fprintf(stderr, "FAIL: (e) threw: %s\n", e.what());
    }
  }

  if (g_failures == 0) {
    std::printf("scenario anchor regions: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "scenario anchor regions: %d/%d checks FAILED\n", g_failures, g_checks);
  return 1;
}
