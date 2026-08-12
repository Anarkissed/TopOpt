// test_lattice_depth_tie.cpp — task 2026-08-12-lattice-page-redesign, the core
// bars.
//
//  §0a / R2  ONE CONTROL, ONE VALUE, ONE SLAB. A face's protection depth and its
//            lattice region depth are the SAME NUMBER, and a job that states two
//            different ones is REFUSED with both figures — it does not run into
//            the failure it encodes. Plus the per-face depth itself: two faces
//            dragged to two depths freeze two different slabs, and an empty
//            per-face list is the pre-task global behaviour exactly.
//
//  §1f       THE ANCHOR/LOAD PAD IS NOT A FACE PROTECTION. `face_protection_
//            reports` carries EXACTLY what the user declared — never a load or
//            anchor face — and the structural pad is counted separately, with a
//            POSITIVE CONTROL proving the pad is really there (a check that the
//            reports are clean is worthless if the pad silently vanished).
//
// Drives OCCT (STEP import) on the demo l-bracket, gated in CMake.

#include "topopt/job.hpp"
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
using topopt::JobError;
using topopt::MaskValue;
using topopt::ProductionLoadCase;
using topopt::ProductionRunSetup;
using topopt::StepModel;
using topopt::StepSurfaceKind;
using topopt::Vec3;

namespace { int g_failures = 0; int g_checks = 0; }
#define CHECK(cond, msg)                \
  do {                                  \
    ++g_checks;                         \
    if (!(cond)) {                      \
      std::printf("FAIL: %s\n", msg);   \
      ++g_failures;                     \
    }                                   \
  } while (0)

namespace {

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
  return lc;
}

std::vector<int> planes(const StepModel& model) {
  std::vector<int> out;
  for (int f = 0; f < model.face_count; ++f)
    if (model.faces[static_cast<std::size_t>(f)].kind == StepSurfaceKind::Plane)
      out.push_back(f);
  return out;
}

// Does a parse throw, and does the message name both numbers?
bool refuses_with(const std::string& json, const char* needle_a,
                  const char* needle_b) {
  try {
    topopt::parse_job(json);
  } catch (const JobError& e) {
    const std::string m = e.what();
    return m.find(needle_a) != std::string::npos &&
           m.find(needle_b) != std::string::npos;
  } catch (...) {
    return false;
  }
  return false;
}

std::string job_with(double protection_mm, double region_mm, bool with_face_id) {
  std::string s =
      "{\"model\": \"p.step\", \"material\": \"PLA\", "
      "\"mode\": \"minimize_plastic\", \"resolution\": 32, "
      "\"output\": {\"report\": \"r.json\", \"mesh_format\": \"stl\", "
      "\"mesh_prefix\": \"v\"}, "
      "\"loads\": {\"anchor_face_ids\": [1], "
      "\"groups\": [{\"face_ids\": [2], \"force\": [0, 0, -1]}], "
      "\"face_protections\": [16], \"face_protection_depth_mm\": " +
      std::to_string(protection_mm) +
      "}, \"lattice\": {\"topology\": \"octet\", \"cell_mm\": 2, "
      "\"strut_radius_mm\": 0.3, \"regions\": [{\"role\": \"include\", "
      "\"kind\": \"face\"";
  if (with_face_id) s += ", \"face_id\": 16";
  s += ", \"geometry\": {\"origin\": [0,0,0], \"normal\": [0,0,1], "
       "\"half_u_mm\": 5, \"half_w_mm\": 5, \"depth_mm\": " +
       std::to_string(region_mm) + "}}]}}";
  return s;
}

}  // namespace

int main() {
  const std::string demo_dir = DEMO_FIXTURE_DIR;
  const StepModel model = topopt::import_step_file(demo_dir + "/l-bracket.step");
  const int resolution = 24;
  const std::vector<int> pl = planes(model);
  CHECK(pl.size() >= 2, "the l-bracket exposes at least two planar faces");
  if (pl.size() < 2) { std::printf("%d/%d checks\n", g_checks - g_failures, g_checks); return 1; }

  // ── §0a / R2 — THE DEPTH TIE ──────────────────────────────────────────────
  //
  // A face that is BOTH protected and a lattice region at TWO depths is refused,
  // and the refusal names both numbers so the user can see which to change.
  CHECK(refuses_with(job_with(5.0, 7.0, /*with_face_id=*/true), "5.000000",
                     "7.000000"),
        "§0a: 5 mm of protection under a 7 mm lattice region is REFUSED, with "
        "BOTH depths in the message");

  // THE POSITIVE CONTROL: the same job with the depths MATCHED must parse. A
  // refusal test that refuses everything proves nothing.
  bool matched_parses = true;
  try {
    topopt::parse_job(job_with(7.0, 7.0, true));
  } catch (...) { matched_parses = false; }
  CHECK(matched_parses, "§0a: matched depths parse — the check is the MISMATCH, "
                        "not the pairing");

  // AND the pre-task freedom is intact: a region with no `face_id` names no
  // face, so nothing is tied and a hand-authored job is unchanged.
  bool unnamed_parses = true;
  try {
    topopt::parse_job(job_with(5.0, 7.0, /*with_face_id=*/false));
  } catch (...) { unnamed_parses = false; }
  CHECK(unnamed_parses, "§0a: a region that names no face is not tied to any "
                        "protection (the pre-task hand-authored job is intact)");

  // ── §0a — PER-FACE DEPTHS FREEZE DIFFERENT SLABS ──────────────────────────
  //
  // Two faces, two dragged depths, two different voxel counts. Without the
  // per-face list both would use the ONE global depth.
  {
    ProductionLoadCase lc = make_load_case(model);
    lc.face_protection_face_ids = {pl[0], pl[1]};
    lc.face_protection_depth_mm = 3.0;
    lc.face_protection_depths_mm = {3.0, 12.0};   // the second one dragged deeper
    ProductionRunSetup s = build_production_loadcase(model, resolution, lc);
    CHECK(s.face_protection_reports.size() == 2, "two protections, two reports");
    if (s.face_protection_reports.size() == 2) {
      const auto& a = s.face_protection_reports[0];
      const auto& b = s.face_protection_reports[1];
      CHECK(a.depth_requested_mm == 3.0 && b.depth_requested_mm == 12.0,
            "§0a: each report states the depth THAT face requested");
      CHECK(b.depth_voxels > a.depth_voxels,
            "§0a: the deeper drag freezes more voxel LAYERS");
      CHECK(a.depth_effective_mm > 0 && b.depth_effective_mm > 0,
            "§0a: and each states what those layers actually reach in mm");
      // The effective depth is layers x spacing — the number that made 5 mm of
      // protection into 5.115 mm on the maintainer's grid.
      CHECK(std::abs(a.depth_effective_mm - a.depth_voxels * s.grid.spacing) < 1e-9,
            "§0a: effective = layers x spacing, exactly");
    }
  }

  // AN EMPTY per-face list is the pre-task behaviour, EXACTLY: every protection
  // takes the global depth.
  {
    ProductionLoadCase lc = make_load_case(model);
    lc.face_protection_face_ids = {pl[0], pl[1]};
    lc.face_protection_depth_mm = 5.0;
    ProductionRunSetup s = build_production_loadcase(model, resolution, lc);
    bool same = s.face_protection_reports.size() == 2;
    if (same)
      same = s.face_protection_reports[0].depth_voxels ==
             s.face_protection_reports[1].depth_voxels;
    CHECK(same, "§0a: no per-face depths => the ONE global depth governs both, "
                "byte-identical to before the task");
    if (s.face_protection_reports.size() == 2)
      CHECK(s.face_protection_reports[0].depth_requested_mm == 5.0,
            "§0a: and the report states the global depth as the request");
  }

  // A per-face entry <= 0 means "use the global" for THAT face.
  {
    ProductionLoadCase lc = make_load_case(model);
    lc.face_protection_face_ids = {pl[0], pl[1]};
    lc.face_protection_depth_mm = 5.0;
    lc.face_protection_depths_mm = {-1.0, 5.0};
    ProductionRunSetup s = build_production_loadcase(model, resolution, lc);
    bool same = s.face_protection_reports.size() == 2 &&
                s.face_protection_reports[0].depth_voxels ==
                    s.face_protection_reports[1].depth_voxels;
    CHECK(same, "§0a: a per-face depth <= 0 falls back to the global depth");
  }

  // ── §1f — THE PAD IS NOT A PROTECTION ─────────────────────────────────────
  //
  // The maintainer protected ONE wall and read that 21 load faces were frozen at
  // depth 3. Those were the structural pad. The two are now counted apart.
  {
    ProductionLoadCase lc = make_load_case(model);
    lc.face_protection_face_ids = {pl[0]};
    lc.face_protection_depth_mm = 5.0;
    ProductionRunSetup s = build_production_loadcase(model, resolution, lc);

    CHECK(s.face_protection_reports.size() == 1,
          "§1f: ONE declared protection => ONE face-protection report");
    bool only_declared = true;
    for (const auto& r : s.face_protection_reports) {
      if (r.face_id == pl[0]) continue;
      only_declared = false;
    }
    CHECK(only_declared,
          "§1f: no anchor or load face is reported as a Face protection");

    // ★ THE POSITIVE CONTROL. If the pad had been quietly removed, the check
    // above would pass vacuously and the run's verdicts would move. It is HERE,
    // it is REAL, and it is reported as its own thing.
    CHECK(s.anchor_pad_report.applied,
          "§1f: the structural pad IS applied (it is not being disarmed)");
    CHECK(s.anchor_pad_report.voxels_frozen > 0,
          "§1f: and it freezes real voxels — the control that stops this test "
          "passing on an empty pad");
    CHECK(s.anchor_pad_report.depth_voxels == topopt::kProductionAnchorPadDepthVoxels,
          "§1f: at core's own pad depth, unchanged by this task");
    CHECK(s.anchor_pad_report.anchor_faces + s.anchor_pad_report.load_faces > 0,
          "§1f: over the anchor and retained load faces it has always covered");
    CHECK(s.anchor_pad_report.voxels_frozen >
              s.face_protection_reports.front().voxels_frozen ||
          s.anchor_pad_report.load_faces > 1,
          "§1f: the pad is the LARGER of the two on this part — which is exactly "
          "why reading them together said '21 faces frozen'");
  }

  std::printf("%d/%d checks passed\n", g_checks - g_failures, g_checks);
  return g_failures == 0 ? 0 : 1;
}
