// REAL BOLTS (the reviewer's brief of 2026-10-25 20:10, approved by him). An anchored
// hole is held only where the part PRESSES on the bolt: along the surface normal only,
// compression-only, frictionless. The bolt is a stiff penalty spring, not a clamp. Which
// side presses is not known in advance, so the solve is repeated, releasing the springs
// in tension, until the set stops changing (at most 6 rounds). Behind the job key
// loads.anchor_model: "bearing"; absent (or "glued"), today's clamp, byte for byte.
//
// The committed plate with a bore (24 x 16 x 4 mm, an r 3 bore through z at the
// centre), anchored at the bore ONLY and pulled along +x on its +x end face:
//   (a) the schema accepts "glued" / "bearing" and refuses anything else; without the
//       key the load case clamps the bore exactly as before (no spring anywhere);
//   (b) with bearing the bore carries springs and no clamp; the contact loop keeps the
//       quarter the plate presses (normals within 45 degrees of +x: the -x side of the
//       hole) and releases the quarter it pulls away from, in 2..6 solves (the sides,
//       where Poisson squeezes the hole onto the pin, may go either way);
//   (c) Jacobi-CG, multigrid and matrix-free multigrid solve the same spring system,
//       and a contact-set change mid-run (Krylov recycling on, so a basis is carried
//       across solves) gives the same field as a cold solve of the new set: the change
//       drops the caches built on the old operator (#362's condition 1);
//   (d) the bearing margin converges: under 5 % change from res 96 to res 128, the
//       springs carrying the load (not the tangential stabilisation), and the glued
//       margin printed beside it. (Since the corner fix, 2026-10-26, every margin is
//       read on the stress averaged over a 1.44 mm radius, which settles once the voxel
//       is well under it: the pair moved from 64 / 96 to 96 / 128, measured 0.7 %.)
//   (e) THE SLIDING GUARD (the reviewer's ruling of 2026-10-25 21:45): pulled along the
//       bore's own axis, a frictionless pin holds nothing, so the reaction sits in the
//       weak sliding springs; over 5 % of it there, the design is NOT accepted and the
//       line says why. The side pull of (d) stays under 5 %.
// Eigen + the mesh importer; OCCT-free.

#include "topopt/fea.hpp"
#include "topopt/job.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/materials.hpp"
#include "topopt/part.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/settings.hpp"
#include "topopt/step.hpp"

#include <algorithm>
#include <cmath>
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

int plane_facing(const StepModel& m, const Vec3& d) {
  for (int f = 0; f < m.face_count; ++f) {
    const StepFaceInfo& i = m.faces[static_cast<std::size_t>(f)];
    if (i.kind != StepSurfaceKind::Plane) continue;
    const Vec3& n = i.plane_normal;
    const double l = std::sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
    if (l > 0.0 && (n.x * d.x + n.y * d.y + n.z * d.z) / l > 0.99) return f;
  }
  return -1;
}

int bore_face(const StepModel& m) {
  for (int f = 0; f < m.face_count; ++f)
    if (m.faces[static_cast<std::size_t>(f)].kind == StepSurfaceKind::Cylinder) return f;
  return -1;
}

JobDescription plate_job(const StepModel& m, int resolution, const std::string& model,
                         Vec3 force = Vec3{100.0, 0.0, 0.0}) {
  JobDescription job;
  job.model = "plate_bore.stl";
  job.material = "PLA";
  job.mode = "minimize_plastic";
  job.resolution = resolution;
  job.loads.present = true;
  job.loads.build_dir = Vec3{0.0, 0.0, 1.0};
  job.loads.anchor_face_ids = {bore_face(m)};
  JobLoadGroup g;
  g.face_ids = {plane_facing(m, Vec3{1.0, 0.0, 0.0})};
  g.force = force;
  job.loads.groups.push_back(g);
  job.loads.anchor_model = model;
  job.output.report = "report.json";
  job.output.mesh_format = "stl";
  job.output.mesh_prefix = "variant";
  return job;
}

bool refused(const std::string& model) {
  const std::string path = std::string(TMP_DIR) + "/bearing_schema_job.json";
  std::ofstream(path) << "{\"model\": \"plate_bore.stl\", \"material\": \"PLA\", "
                         "\"mode\": \"minimize_plastic\", \"resolution\": 32, "
                         "\"loads\": {\"anchor_face_ids\": [0], \"anchor_model\": \""
                      << model
                      << "\", \"groups\": [{\"face_ids\": [1], \"force\": [1, 0, 0]}]}, "
                         "\"output\": {\"report\": \"r.json\", \"mesh_format\": \"stl\", "
                         "\"mesh_prefix\": \"v\"}}";
  try {
    (void)load_job_file(path);
    return false;
  } catch (const std::exception&) {
    return true;
  }
}

int springs(const std::vector<DirichletBC>& bcs) {
  int n = 0;
  for (const DirichletBC& b : bcs) n += b.spring > 0.0;
  return n;
}

double max_abs_diff(const std::vector<double>& a, const std::vector<double>& b) {
  double d = 0.0, s = 0.0;
  for (std::size_t i = 0; i < a.size() && i < b.size(); ++i) {
    d = std::max(d, std::fabs(a[i] - b[i]));
    s = std::max(s, std::fabs(a[i]));
  }
  return s > 0.0 ? d / s : d;
}

}  // namespace

int main() {
  const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  const std::string dir = MESH_FIXTURE_DIR;
  const PartModel part = import_part(dir + "/plate_bore.stl");
  const StepModel& model = part.model;
  CHECK(bore_face(model) >= 0 && plane_facing(model, Vec3{1.0, 0.0, 0.0}) >= 0,
        "fixture: the plate has its bore and its +x end face");
  const Material& pla = materials.at("PLA");

  // ── (a) the schema, and today's clamp without the key ────────────────────────
  CHECK(!refused("glued") && !refused("bearing"), "(a) glued and bearing parse");
  CHECK(refused("hinged"), "(a) an unknown anchor model is refused");
  {
    const ProductionRunSetup glued = build_production_loadcase(
        model, 32, production_loadcase_from_job(plate_job(model, 32, ""), model));
    CHECK(springs(glued.bcs) == 0 && !glued.bcs.empty(),
          "(a) without the key the bore is clamped, as before");
  }

  // ── (b) + (c) the springs, the contact loop, three solvers ───────────────────
  try {
    const ProductionRunSetup s = build_production_loadcase(
        model, 32, production_loadcase_from_job(plate_job(model, 32, "bearing"), model));
    const int n_springs = springs(s.bcs);
    CHECK(n_springs > 0 && static_cast<std::size_t>(n_springs) == s.bcs.size(),
          "(b) with bearing the bore carries springs and no clamp");
    const std::vector<NodalLoad>& loads = s.options.external_loads;
    std::vector<DirichletBC> live = s.bcs;
    int rounds = 0;
    for (;;) {
      const FeaSolution u = fea_solve_mgcg_matfree(s.grid, pla.youngs_modulus_mpa, pla.poisson,
                                                   live, loads, 1e-8);
      ++rounds;
      if (contact_update(live, u.u).changed == 0 || rounds >= 6) break;
    }
    int engaged = 0, released = 0, wrong_side = 0;
    for (const DirichletBC& b : live) {
      if (b.released) ++released; else ++engaged;
      if (!b.released && b.normal.x < -0.7) ++wrong_side;  // pressing the far quarter
      if (b.released && b.normal.x > 0.7) ++wrong_side;    // let go of the near quarter
    }
    std::printf("[bearing] res 32: %d springs; %d engaged, %d released after %d solve(s); "
                "%d on the wrong side\n", n_springs, engaged, released, rounds, wrong_side);
    CHECK(rounds >= 2 && rounds <= 6, "(b) the contact set settles in 2..6 solves");
    CHECK(engaged > 0 && released > 0 && wrong_side == 0,
          "(b) the plate presses the -x side of the bore and lets go of the +x side");

    CgInfo ij, im, iw;
    const FeaSolution uj = fea_solve_cg(s.grid, pla.youngs_modulus_mpa, pla.poisson, live,
                                        loads, 1e-10, 0, &ij);
    const FeaSolution um = fea_solve_mgcg(s.grid, pla.youngs_modulus_mpa, pla.poisson, live,
                                          loads, 1e-10, 0, &im);
    const FeaSolution uw = fea_solve_mgcg_matfree(s.grid, pla.youngs_modulus_mpa,
                                                  pla.poisson, live, loads, 1e-10, 0, &iw);
    const double dm = max_abs_diff(uj.u, um.u), dw = max_abs_diff(uj.u, uw.u);
    std::printf("[bearing] solvers: multigrid %s vs Jacobi-CG %.2e, matrix-free %s %.2e\n",
                im.used_multigrid ? "(MG)" : "(fell back)", dm,
                iw.used_multigrid ? "(MG)" : "(fell back)", dw);
    CHECK(ij.converged && im.converged && iw.converged && im.used_multigrid &&
              iw.used_multigrid && dm < 1e-5 && dw < 1e-5,
          "(c) the three solvers solve the same spring system");

    const bool was_on = fea_set_krylov_recycling(true);
    const bool was_wrap = fea_set_krylov_recycle_wrap_multigrid(true);
    fea_reset_krylov_recycle_space();
    std::vector<DirichletBC> mid = s.bcs;  // every spring engaged
    (void)fea_solve_mgcg_matfree(s.grid, pla.youngs_modulus_mpa, pla.poisson, mid, loads, 1e-10);
    const FeaSolution u0 = fea_solve_mgcg_matfree(s.grid, pla.youngs_modulus_mpa, pla.poisson,
                                                  mid, loads, 1e-10);
    const ContactUpdate cu = contact_update(mid, u0.u);  // the set changes mid-run
    const FeaSolution warm = fea_solve_mgcg_matfree(s.grid, pla.youngs_modulus_mpa,
                                                    pla.poisson, mid, loads, 1e-10);
    fea_reset_krylov_recycle_space();
    (void)fea_set_krylov_recycling(false);
    const FeaSolution cold = fea_solve_mgcg_matfree(s.grid, pla.youngs_modulus_mpa,
                                                    pla.poisson, mid, loads, 1e-10);
    (void)fea_set_krylov_recycling(was_on);
    (void)fea_set_krylov_recycle_wrap_multigrid(was_wrap);
    const double dc = max_abs_diff(cold.u, warm.u);
    std::printf("[bearing] a set change mid-run (%d springs changed) vs a cold solve: %.2e\n",
                cu.changed, dc);
    CHECK(cu.changed > 0 && dc < 1e-6,
          "(c) a set change mid-run gives the cold solve's field (caches dropped)");
  } catch (const std::exception& e) {
    ++g_failures;
    std::fprintf(stderr, "FAIL: (b)/(c) threw: %s\n", e.what());
  }

  // ── (d) the margin converges ─────────────────────────────────────────────────
  try {
    double bearing[3] = {0, 0, 0}, glued[3] = {0, 0, 0};
    const int res[3] = {64, 96, 128};
    for (int r = 0; r < 3; ++r) {
      const std::string out = std::string(TMP_DIR) + "/bearing_plate_" + std::to_string(res[r]);
      const AnalyzeJobResult b =
          analyze_job(plate_job(model, res[r], "bearing"), dir, out + "_b", materials, rules);
      const AnalyzeJobResult g =
          analyze_job(plate_job(model, res[r], "glued"), dir, out + "_g", materials, rules);
      bearing[r] = b.analysis.margin_effective;
      glued[r] = g.analysis.margin_effective;
      std::printf("[bearing] res %d: margin bearing %.4f (%d contact solve(s), springs carry "
                  "%.1f %% of the load), glued %.4f\n",
                  res[r], bearing[r], b.analysis.contact_rounds,
                  100.0 * b.analysis.contact_load_share, glued[r]);
      CHECK(b.analysis.contact_rounds >= 2 && b.analysis.contact_rounds <= 6 &&
                b.analysis.contact_settled,
            "(d) the certification ran the contact loop and it settled");
      CHECK(b.analysis.contact_load_share > 0.95 &&
                b.analysis.contact_tangent_share < kAnchorsSlidingShare &&
                !b.analysis.contact_held_by_sliding,
            "(d) the springs carry the load, not the sliding springs");
    }
    const double change = std::fabs(bearing[2] - bearing[1]) / bearing[1];
    std::printf("[bearing] change 96 -> 128: bearing %.2f %%, glued %.2f %%\n", 100.0 * change,
                100.0 * std::fabs(glued[2] - glued[1]) / glued[1]);
    CHECK(change < 0.05, "(d) the bearing margin changes under 5 % from res 96 to 128");
  } catch (const std::exception& e) {
    ++g_failures;
    std::fprintf(stderr, "FAIL: (d) threw: %s\n", e.what());
  }

  // ── (e) the sliding guard ─────────────────────────────────────────────────────
  try {
    const AnalyzeJobResult z =
        analyze_job(plate_job(model, 48, "bearing", Vec3{0.0, 0.0, 100.0}), dir,
                    std::string(TMP_DIR) + "/bearing_plate_axial", materials, rules);
    const std::string report = z.report_json;
    std::printf("[bearing] pulled along the bore's axis: %.1f %% of the reaction sliding, %s\n",
                100.0 * z.analysis.contact_tangent_share,
                z.analysis.accepted ? "accepted" : "rejected");
    CHECK(z.analysis.contact_held_by_sliding && !z.analysis.accepted,
          "(e) a load the anchors cannot hold is not a pass");
    CHECK(report.find(kAnchorsSlidingReason) != std::string::npos &&
              report.find("\"held_by_sliding\": true") != std::string::npos,
          "(e) the report says why");
  } catch (const std::exception& e) {
    ++g_failures;
    std::fprintf(stderr, "FAIL: (e) threw: %s\n", e.what());
  }

  if (g_failures == 0) {
    std::printf("bearing (real bolts): all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "bearing (real bolts): %d/%d checks FAILED\n", g_failures, g_checks);
  return 1;
}
