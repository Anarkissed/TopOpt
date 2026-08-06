// test_job_loadcase_copy.cpp — task 2026-08-06-strut-line-width-field, S0.
//
// THE TEST THAT WAS MISSING. `production_loadcase_from_job` is the job.json →
// ProductionLoadCase copy, and it silently lost `wall_line_width_outer_mm` for
// eight days: PR #227 added the assignment (84a1350, 2026-07-28 20:52) and PR
// #228's merge-conflict resolution 71 minutes later (fc6e95f) hoisted the block
// into a helper, re-typing five of its six trailing assignments and dropping the
// sixth. The whole suite stayed green, because:
//
//   * core/tests/unit/test_job.cpp asserts the PARSER — job.loads gets 0.42.
//     Still true after the drop; the parser was never the broken step.
//   * core/tests/validation/test_production_parity.cpp asserts
//     knockdown_spec_for() by setting MinimizePlasticOptions::
//     wall_line_width_outer_mm DIRECTLY ON THE STRUCT — the "tests on the value
//     type miss the call site" shape this repo has shipped defects on before.
//
// Nothing crossed the boundary the merge broke. This does: it drives a
// JobDescription through the real helper and asserts what comes out the far side.
//
// TWO HALVES, AND BOTH ARE LOAD-BEARING:
//
//   (1) THE VALUES — §1 below drives a job whose every scalar carries a
//       DISTINCTIVE value (nothing equal to a default, nothing equal to another
//       field) and asserts each one arrives. A field copied from the wrong source
//       fails here as loudly as a field not copied at all.
//   (2) THE COVERAGE — the helper itself now decomposes JobLoadCase by structured
//       binding, so a field ADDED to JobLoadCase and not handled stops the build
//       (see the ledger comment at the copy). This file cannot enforce that — a
//       hand-enumerated test is only marginally better than the hand-enumerated
//       copy it is checking — so the coverage half lives in the compiler and §3
//       here only documents where it lives, and re-asserts the ledger's own
//       "deliberately not carried" decision.
//
// Synthetic in-code StepModel, no OCCT, no solve. The helper resolves selectors
// against `model` and reads bore radii out of it; nothing else here needs geometry.

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#include "topopt/job.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/mesh.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/step.hpp"

using topopt::JobClearance;
using topopt::JobDescription;
using topopt::JobFaceSelector;
using topopt::JobLoadGroup;
using topopt::ProductionLoadCase;
using topopt::production_loadcase_from_job;
using topopt::StepModel;
using topopt::Vec3;

namespace {

int g_failures = 0;
#define CHECK(cond, msg)              \
  do {                                \
    if (!(cond)) {                    \
      std::printf("FAIL: %s\n", msg); \
      ++g_failures;                   \
    }                                 \
  } while (0)

bool near(double a, double b) { return std::fabs(a - b) <= 1e-12; }

// A model with four B-rep faces and one bore, enough for the helper to resolve a
// raw face id and read `cylinder_radius_mm` for an auto bolt clearance. No mesh
// is needed: the helper never voxelizes.
StepModel make_model() {
  StepModel m;
  m.face_count = 4;
  m.faces.resize(4);
  // Face 2 is a 3 mm-radius bore: the auto bolt clearance reads its radius, and
  // the cylindrical anchor selector below resolves to it.
  m.faces[2].kind = topopt::StepSurfaceKind::Cylinder;
  m.faces[2].cylinder_radius_mm = 3.0;
  m.solid_count = 1;
  return m;
}

// A job whose EVERY load-case scalar carries a value that is its own fingerprint:
// no default, no repeat. 0.42 / 0.45 are the maintainer's own outer / inner wall
// beads, and they are deliberately DIFFERENT — with equal widths the drop this
// test exists for is invisible (that is exactly the case S4 proves byte-identical).
JobDescription make_job() {
  JobDescription job;
  job.model = "synthetic";
  job.material = "PLA";
  job.mode = "minimize_plastic";
  job.resolution = 32;

  job.loads.present = true;
  job.loads.anchor_face_ids = {0};
  JobFaceSelector sel;  // resolves to face 2, the 3 mm bore
  sel.kind = "cylindrical";
  sel.radius_mm = 3.0;
  job.loads.anchors.push_back(sel);

  JobLoadGroup g;
  g.face_ids = {1};
  g.force = Vec3{0.0, 0.0, -250.0};
  job.loads.groups.push_back(g);

  JobClearance jc;
  jc.face_id = 2;
  jc.kind = "bolt";
  job.loads.clearances.push_back(jc);

  job.loads.face_protection_face_ids = {3};
  job.loads.face_protection_depth_mm = 7.25;
  job.loads.build_dir = Vec3{0.0, 1.0, 0.0};
  job.loads.infill_percent = 35.0;
  job.loads.minimize_plastic = false;
  job.loads.wall_loops = 5;
  job.loads.wall_line_width_mm = 0.45;        // INNER, the maintainer's
  job.loads.wall_line_width_outer_mm = 0.42;  // OUTER, the maintainer's
  return job;
}

// §1 — EVERY carried field survives the copy, at its own stated value.
void test_every_field_survives() {
  const StepModel model = make_model();
  const JobDescription job = make_job();
  const ProductionLoadCase lc = production_loadcase_from_job(job, model);

  // Anchors: the raw id and the resolved selector COMPOSE (the raw id first).
  CHECK(lc.anchor_face_ids.size() == 2 && lc.anchor_face_ids[0] == 0 &&
            lc.anchor_face_ids[1] == 2,
        "anchor_face_ids: raw id 0 and the cylindrical selector's face 2 COMPOSE");
  CHECK(lc.load_groups.size() == 1, "load_groups: the declared group is carried");
  if (lc.load_groups.size() == 1) {
    CHECK(lc.load_groups[0].face_ids.size() == 1 &&
              lc.load_groups[0].face_ids[0] == 1,
          "load_groups[0].face_ids carried");
    CHECK(near(lc.load_groups[0].force.z, -250.0),
          "load_groups[0].force carried");
  }
  CHECK(lc.clearances.size() == 1, "clearances: the declared clearance is carried");
  if (lc.clearances.size() == 1) {
    CHECK(lc.clearances[0].face_id == 2, "clearances[0].face_id carried");
    CHECK(lc.clearances[0].params.kind == topopt::ClearanceKind::Bolt,
          "clearances[0] resolved as a BOLT (kind is read, not defaulted)");
  }
  CHECK(lc.face_protection_face_ids.size() == 1 &&
            lc.face_protection_face_ids[0] == 3,
        "face_protection_face_ids carried");
  CHECK(near(lc.face_protection_depth_mm, 7.25),
        "face_protection_depth_mm carried");
  CHECK(near(lc.build_dir.y, 1.0), "build_dir carried");
  CHECK(near(lc.infill_percent, 35.0), "infill_percent carried");
  CHECK(lc.minimize_plastic == false, "minimize_plastic carried");
  CHECK(lc.wall_loops == 5, "wall_loops carried");
  CHECK(near(lc.wall_line_width_mm, 0.45), "wall_line_width_mm (INNER) carried");

  // ★ THE ASSERTION THE DROP FAILS. Before the fix this reads -1.0 — the
  // "mirror inner" sentinel — and every derivation downstream silently uses the
  // INNER width (0.45) in place of the outer width the job actually stated.
  CHECK(near(lc.wall_line_width_outer_mm, 0.42),
        "wall_line_width_outer_mm (OUTER) carried  <-- the PR #228 drop");
  if (!near(lc.wall_line_width_outer_mm, 0.42))
    std::printf("      job said %.6f, load case got %.6f (%s)\n",
                job.loads.wall_line_width_outer_mm, lc.wall_line_width_outer_mm,
                lc.wall_line_width_outer_mm < 0.0
                    ? "the mirror-inner sentinel: the value was DROPPED"
                    : "a wrong value");
}

// §2 — THE BLAST RADIUS, measured rather than asserted-by-eye: the wall ring the
// gate would size from this load case. t = outer + (loops-1)·inner. With the
// outer width carried that is 0.42 + 4·0.45 = 2.22 mm; with it dropped the
// sentinel mirrors the inner width and it becomes 5·0.45 = 2.25 mm.
//
// The number matters only when the width-aware gate is ARMED — the shipped
// posture is kProductionWidthAwareKnockdown = false (core/src/simp/production.cpp),
// so nothing reads t today. This locks the arithmetic anyway, because the day it
// is armed the drop would credit the part with 0.03 mm of wall it does not have.
void test_wall_ring_thickness() {
  const StepModel model = make_model();
  const JobDescription job = make_job();
  const ProductionLoadCase lc = production_loadcase_from_job(job, model);

  const double inner = lc.wall_line_width_mm;
  const double outer =
      lc.wall_line_width_outer_mm >= 0.0 ? lc.wall_line_width_outer_mm : inner;
  const double t = outer + static_cast<double>(lc.wall_loops - 1) * inner;
  std::printf("  wall ring t = %.4f mm  (loops %d, outer %.4f mm, inner %.4f mm)\n",
              t, lc.wall_loops, outer, inner);
  CHECK(near(t, 2.22),
        "wall ring t = 2.22 mm at outer 0.42 mm / inner 0.45 mm, 5 loops");
}

// §3 — THE SENTINEL IS STILL REACHABLE. A job that OMITS the outer width must
// still arrive at the load case as < 0, because "mirror the inner width" is the
// documented design (pipeline.hpp) and the pre-split behaviour depends on it.
// Restoring the assignment must not turn an absence into a 0.
//
// This is also the positive control for §1: it proves §1 is reading a copied
// value and not a coincidence of defaults, because the same field comes back
// DIFFERENT here on a job that differs only in whether it stated the key.
void test_omitted_outer_width_still_mirrors() {
  const StepModel model = make_model();
  JobDescription job = make_job();
  job.loads.wall_line_width_outer_mm = -1.0;  // as the parser leaves an omitted key
  const ProductionLoadCase lc = production_loadcase_from_job(job, model);
  CHECK(lc.wall_line_width_outer_mm < 0.0,
        "an OMITTED outer width still arrives as the mirror-inner sentinel");
  CHECK(near(lc.wall_line_width_mm, 0.45),
        "the inner width is unaffected by the outer being absent");
}

// §4 — `present` is DELIBERATELY NOT CARRIED, and the ledger says so. The copy
// names it (the structured binding must) and voids it: it answers the CALLER's
// question, "was a loads block given at all", which every call site checks before
// asking for a load case. ProductionLoadCase has no counterpart.
//
// The check here is that the copy does not accidentally start depending on it:
// a job with present=false and one with present=true produce the SAME load case.
void test_present_is_not_a_load_case_property() {
  const StepModel model = make_model();
  JobDescription on = make_job();
  JobDescription off = make_job();
  off.loads.present = false;
  const ProductionLoadCase a = production_loadcase_from_job(on, model);
  const ProductionLoadCase b = production_loadcase_from_job(off, model);
  CHECK(a.anchor_face_ids == b.anchor_face_ids &&
            a.load_groups.size() == b.load_groups.size() &&
            a.clearances.size() == b.clearances.size() &&
            a.wall_loops == b.wall_loops &&
            near(a.wall_line_width_mm, b.wall_line_width_mm) &&
            near(a.wall_line_width_outer_mm, b.wall_line_width_outer_mm) &&
            near(a.infill_percent, b.infill_percent) &&
            a.minimize_plastic == b.minimize_plastic,
        "`present` does not reach the load case (it is the caller's gate)");
}

}  // namespace

int main() {
  std::printf("job -> load case copy (task 2026-08-06-strut-line-width-field, S0)\n");
  test_every_field_survives();
  test_wall_ring_thickness();
  test_omitted_outer_width_still_mirrors();
  test_present_is_not_a_load_case_property();
  if (g_failures == 0) {
    std::printf("all job/load-case copy checks passed\n");
    return 0;
  }
  std::printf("%d check(s) failed\n", g_failures);
  return 1;
}
