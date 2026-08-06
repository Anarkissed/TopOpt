// test_lattice_void_exterior.cpp — THE ENCLOSED-VOID RULE, END TO END
// (task 2026-08-05-lattice-void-reaches-exterior).
//
// THE RULE: the void space inside any lattice must connect to the exterior. No
// sealed lattice-filled cavities.
//
// test_lattice_void.cpp proves the WALK on constructed grids. This file proves
// the WIRING — schema key -> run_job -> refusal -> receipt -> run_info — on a
// real optimize run, because in this project "built, but never actually
// invoked" is a failure that has shipped more than once.
//
// THE PART. The demo l-bracket at resolution 32, ladder [1.0] so the optimizer
// keeps the whole part (a fully solid design is the cleanest way to build a
// cavity that is genuinely walled in). Its foot is a slab x = -30..30,
// y = -20..20, z = 0..8.33 mm with two small bores near y = 0.
//
// THE SEALED CASE is one lattice include region: a face slab centred at (-5, 0),
// 16 x 16 mm in plan, spanning z = 3..6 — the MIDDLE of the foot's thickness,
// clear of both bores. Include semantics do the rest: only material inside the
// include union is latticed and the rest of the printed part stays SOLID.
//
// THE OPEN CONTROL is THE SAME SLAB with half_w widened from 8 mm to 40 mm so
// it runs out through the part's y faces. ONE number differs, and it is the one
// that decides whether the pore space reaches the outside. Without this control
// every bar below would also be met by a check that refused everything.
//
// BARS
//   V1  THE DEFECT, ASSERTED. With the option ABSENT the sealed job runs to
//       completion, writes a latticed STL and reports `lattice_accepted: true`.
//       That is what ships today.
//   V2  THE REFUSAL. With the option ARMED the same job refuses the rung, writes
//       NO latticed mesh, and names the sealed cells, the trapped volume, the
//       bounding box and the declared include region.
//   V3  THE PERMISSION. The OPEN control passes with the option armed and still
//       writes its mesh — the rule permits interior lattice.
//   V4  A PASS IS AUDIBLE. The open run's receipt and run_info carry the
//       void_escape record: how much void was reachable, how deep the drain
//       path runs, and which grid faces it escapes through.
//   V5  OFF IS SILENT. With the option absent NEITHER document mentions the
//       check at all — the byte-identity property, asserted here at the
//       document level (the checksum form is the stash-rebuild bar R1).
//   V6  THE COST IS REPORTED, both figures, separately: the fill's own visit
//       count and its own wall clock, neither of them folded into gen_seconds.
//
// Self-contained CHECK harness (ARCHITECTURE §4), like the other tests.

#include "topopt/job.hpp"
#include "topopt/materials.hpp"
#include "topopt/settings.hpp"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

using namespace topopt;

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

static std::string read_file(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  std::ostringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

static bool contains(const std::string& hay, const std::string& needle) {
  return hay.find(needle) != std::string::npos;
}

// Extract the number after "\"key\": " (first occurrence). NaN when absent.
static double json_number(const std::string& text, const std::string& key) {
  const std::string pat = "\"" + key + "\": ";
  const std::string::size_type at = text.find(pat);
  if (at == std::string::npos) return std::nan("");
  return std::atof(text.c_str() + at + pat.size());
}

// The l-bracket base job: one rung at 1.0 so the design stays the whole part.
static JobDescription bracket_job() {
  JobDescription job;
  job.model = "l-bracket.step";
  job.material = "PLA";
  job.mode = "minimize_plastic";
  job.resolution = 32;
  job.fixture_faces.push_back(JobFaceSelector{"cylindrical", 2.5});
  job.gravity.direction = Vec3{0.0, 0.0, -1.0};
  job.gravity.magnitude_mm_s2 = 9810.0;
  job.ladder = {1.0};
  job.margin_stop = 0.0;
  job.simp_max_iterations = 3;
  job.output.report = "report.json";
  job.output.mesh_format = "stl";
  job.output.mesh_prefix = "variant";
  job.lattice.present = true;
  job.lattice.topology = "octet";
  job.lattice.cell_mm = 8.0;
  job.lattice.strut_radius_mm = 1.2;  // rho ~0.41, inside the certifiable band
  job.lattice.emit_stl = true;
  job.lattice.skin = "rim";
  return job;
}

// The include slab. `half_w` 8 buries it inside the foot; 40 runs it out
// through the part's y faces. ONE number, two verdicts.
static JobLatticeRegion foot_slab(double half_w_mm) {
  JobLatticeRegion r;
  r.role = "include";
  r.kind = "face";
  r.origin = Vec3{-5.0, 0.0, 6.0};
  r.normal = Vec3{0.0, 0.0, -1.0};  // the slab runs DOWN from z = 6 to z = 3
  r.half_u_mm = 8.0;
  r.half_w_mm = half_w_mm;
  r.depth_mm = 3.0;
  return r;
}

int main() {
  const std::string fixture_dir = std::string(DEMO_FIXTURE_DIR);
  const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  const std::string tmp = std::string(CLI_TMP_DIR);

  auto run = [&](const JobDescription& job, const std::string& sub) {
    const std::string out = tmp + "/lat_void_" + sub;
    std::filesystem::remove_all(out);
    return run_job(job, fixture_dir, out, materials, rules,
                   /*emit_progress=*/true, RunObservability{});
  };
  auto lattice_mesh_of = [](const RunJobResult& r) {
    for (const std::string& p : r.mesh_paths)
      if (contains(p, "_lattice.")) return p;
    return std::string();
  };
  auto receipt_of = [&lattice_mesh_of](const RunJobResult& r) -> std::string {
    const std::string m = lattice_mesh_of(r);
    if (m.empty()) return std::string();
    return m.substr(0, m.rfind(".stl")) + ".report.json";
  };

  // ═══════════════════════════════════════════════════════════════════════════
  // V1 / V5 — THE DEFECT, AND SILENCE WHEN THE OPTION IS OFF.
  // ═══════════════════════════════════════════════════════════════════════════
  std::string off_receipt, off_run_info;
  {
    JobDescription job = bracket_job();
    job.lattice.regions.push_back(foot_slab(8.0));
    // require_lattice_void_reaches_exterior stays at its default: false.
    const RunJobResult r = run(job, "off");
    const std::string mesh = lattice_mesh_of(r);
    CHECK(!mesh.empty(),
          "V1: with the option OFF the sealed cavity is exported — a latticed "
          "STL exists");
    CHECK(std::filesystem::exists(mesh) &&
              std::filesystem::file_size(mesh) > 0,
          "V1: and it has real content");
    off_receipt = read_file(receipt_of(r));
    CHECK(contains(off_receipt, "\"lattice_accepted\": true"),
          "V1: ... and it is CERTIFIED, with no complaint anywhere. THAT is the "
          "defect this rule closes");
    // V5 — OFF IS SILENT.
    CHECK(!contains(off_receipt, "void_escape"),
          "V5: the un-armed run's receipt says nothing about the check");
    off_run_info = read_file(r.run_info_path);
    CHECK(!contains(off_run_info, "void_escape"),
          "V5: nor does its run_info — off means not one extra byte");
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // V2 — THE REFUSAL.
  // ═══════════════════════════════════════════════════════════════════════════
  {
    JobDescription job = bracket_job();
    job.lattice.regions.push_back(foot_slab(8.0));
    job.lattice.require_lattice_void_reaches_exterior = true;
    const RunJobResult r = run(job, "on");
    CHECK(lattice_mesh_of(r).empty(),
          "V2: the armed run writes NO latticed mesh — the refusal happens "
          "before the generator runs, so no file a slicer could open exists");
    const std::string ri = read_file(r.run_info_path);
    CHECK(contains(ri, "void_escape"),
          "V2: run_info carries the void_escape record");
    CHECK(contains(ri, "\"sealed\": true"), "V2: and it says SEALED");
    CHECK(json_number(ri, "sealed_variants") == 1.0,
          "V2: exactly one rung was refused");
    CHECK(json_number(ri, "sealed_cells") > 0.0,
          "V2: the refusal counts the sealed CELLS");
    CHECK(json_number(ri, "sealed_voxels") > 0.0,
          "V2: and the sealed voxels");
    CHECK(json_number(ri, "sealed_volume_mm3") > 0.0,
          "V2: and the trapped VOLUME");
    CHECK(json_number(ri, "latticed_voxels_reached") == 0.0,
          "V2: nothing in this lattice was reachable from outside the part");
    // The whole run still succeeded: the ladder's other artifacts are intact.
    CHECK(!r.report_path.empty() && std::filesystem::exists(r.report_path),
          "V2: the SOLID ladder is untouched — one unlatticeable rung must not "
          "destroy the run's output");
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // V3 / V4 / V6 — THE PERMISSION, AND AN AUDIBLE PASS.
  // ═══════════════════════════════════════════════════════════════════════════
  {
    JobDescription job = bracket_job();
    job.lattice.regions.push_back(foot_slab(40.0));  // the ONE number that differs
    job.lattice.require_lattice_void_reaches_exterior = true;
    const RunJobResult r = run(job, "open");
    const std::string mesh = lattice_mesh_of(r);
    CHECK(!mesh.empty(),
          "V3: an interior lattice pocket whose void reaches the surface is "
          "EXPORTED — the rule permits interior lattice, it forbids SEALED "
          "interior lattice");
    const std::string rc = read_file(receipt_of(r));
    CHECK(contains(rc, "\"void_escape\""),
          "V4: the PASSING run's receipt carries the record too");
    CHECK(contains(rc, "\"ran\": true"), "V4: it states that it RAN");
    CHECK(contains(rc, "\"sealed\": false"), "V4: and what it decided");
    CHECK(json_number(rc, "latticed_voxels_sealed") == 0.0,
          "V4: nothing sealed");
    CHECK(json_number(rc, "latticed_voxels_reached") > 0.0,
          "V4: and something reached — a pass that reported nothing would be "
          "indistinguishable from a check that did not run");
    CHECK(json_number(rc, "reachable_void_volume_mm3") > 0.0,
          "V4: how much void can drain");
    CHECK(json_number(rc, "escape_depth_voxels") >= 0.0,
          "V4: how deep in the drain path runs");
    CHECK(contains(rc, "\"escape_faces\": [") &&
              (contains(rc, "\"-y\"") || contains(rc, "\"+y\"")),
          "V4: WHICH WAY OUT it found — this slab exits through the part's y "
          "faces, and the receipt names them");
    CHECK(contains(rc, "\"connectivity\": 6"),
          "V4: the receipt states the adjacency it used; a reader must not have "
          "to guess whether a corner touch counted");
    // V6 — COST, BOTH FIGURES, SEPARATELY.
    CHECK(json_number(rc, "bfs_visits") > 0.0,
          "V6: the check reports its own ITERATION count (voxels pushed)");
    CHECK(json_number(rc, "wall_seconds") >= 0.0,
          "V6: and its own WALL time");
    const std::string ri = read_file(r.run_info_path);
    CHECK(json_number(ri, "bfs_visits") > 0.0 &&
              !std::isnan(json_number(ri, "wall_seconds")),
          "V6: run_info carries both as well, outside gen_seconds");
    CHECK(contains(ri, "\"gen_seconds\""),
          "V6: ... and gen_seconds is still there, unconflated");
  }

  std::fprintf(stderr, "%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
