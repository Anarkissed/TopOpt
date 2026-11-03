// ENGINE BATCH E1, through run_job and analyze_job:
//   (e) EVERY CHECK ON THE FINISHED SHAPE. A reduction run of a bar (40 x 10.6 x 10.6
//       mm, held at one end, 50 N down on the other): every accepted version carries
//       report.json "finish" with its re-check, the exported file IS the finished
//       shape (its volume is the re-check's), and a changed verdict carries its plain
//       reason. Where the finished margin reads under the loop's, the margin required
//       set between the two flips the verdict: the version moves to rejected_variants
//       with the plain reason (on this bar it reads higher, so nothing is refused).
//   (w) THE WRITTEN FILE IS CLEAN (ruling 2026-11-03 02:46). The same bar with exact
//       Protect regions — a box over the held end reaching a voxel into the air, and a
//       cylinder through the middle (his squish rig's shape: a Protect cylinder whose
//       ends meet the voxel surface): every finished file has 0 edges on more than two
//       triangles, no open edge, no point contact, one shell per body, and imports
//       through the normal import (the re-check reads it that way); each "finish"
//       block says its style and whether it fell back.
//   (s) a STREAMED run says, per streamed version, how (e) decided (FINISH lines).
//   (f) "PRINT IT THIS WAY". An L (a 40 mm base, a 30 mm post on its end) pushed
//       sideways at the post's top, re-checked upright (+Z) and lying on its end (+X):
//       the interlayer margins differ, the overhang areas differ (the post's back
//       hangs 30 mm over the bed lying down), both reported with a plain reason.

#include "topopt/face_overrides.hpp"
#include "topopt/finish.hpp"
#include "topopt/job.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/part.hpp"
#include "topopt/settings.hpp"
#include "topopt/step.hpp"
#include "topopt/stl.hpp"
#ifdef TOPOPT_HAVE_3MF
#include "topopt/threemf.hpp"
#endif

#include <manifold/manifold.h>

#include <cmath>
#include <fcntl.h>
#include <unistd.h>
#include <filesystem>
#include <stdexcept>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
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

TriangleMesh from_manifold(const manifold::Manifold& man) {
  const manifold::MeshGL g = man.GetMeshGL();
  TriangleMesh out;
  for (std::size_t v = 0; v < g.NumVert(); ++v)
    out.vertices.push_back({g.vertProperties[v * g.numProp], g.vertProperties[v * g.numProp + 1],
                            g.vertProperties[v * g.numProp + 2]});
  for (std::size_t t = 0; t < g.NumTri(); ++t)
    out.triangles.push_back({static_cast<int>(g.triVerts[3 * t]),
                             static_cast<int>(g.triVerts[3 * t + 1]),
                             static_cast<int>(g.triVerts[3 * t + 2])});
  return out;
}

int face_facing(const StepModel& model, double nx, double ny, double nz, double at = NAN,
                int axis = -1) {
  for (int f = 0; f < model.face_count; ++f) {
    const StepFaceInfo& fi = model.faces[static_cast<std::size_t>(f)];
    const Vec3& n = fi.plane_normal;
    if (fi.kind != StepSurfaceKind::Plane || n.x * nx + n.y * ny + n.z * nz < 0.99) continue;
    if (axis >= 0) {
      const double o = axis == 0 ? fi.plane_origin.x : axis == 1 ? fi.plane_origin.y : fi.plane_origin.z;
      if (std::fabs(o - at) > 1e-3) continue;
    }
    return f;
  }
  return -1;
}

std::string slurp(const std::string& p) {
  std::ifstream in(p);
  return std::string((std::istreambuf_iterator<char>(in)), {});
}
double num_after(const std::string& s, const std::string& key, std::size_t from = 0) {
  const std::size_t p = s.find("\"" + key + "\": ", from);
  return p == std::string::npos ? NAN : std::atof(s.c_str() + p + key.size() + 4);
}

JobDescription bar_job(const StepModel& model, double margin_stop) {
  JobDescription job;
  job.model = "finish_bar.stl";
  job.material = "PLA";
  job.mode = "minimize_plastic";
  job.resolution = 32;
  job.has_plsm = true;
  job.plsm_enabled = true;
  job.plsm_max_iterations = 6;
  job.loads.present = true;
  job.loads.minimize_plastic = true;
  job.loads.anchor_face_ids = {face_facing(model, -1, 0, 0)};
  JobLoadGroup g;
  g.face_ids = {face_facing(model, 1, 0, 0)};
  g.force = Vec3{0.0, 0.0, -50.0};
  job.loads.groups.push_back(g);
  job.loads.build_dir = Vec3{0.0, 0.0, 1.0};
  job.ladder = {0.5};
  job.margin_stop = margin_stop > 0.0 ? margin_stop : 1.5;
  job.loads.safety_margin = margin_stop;  // 0 = the default 150 %
  job.bake_build_orientation = "off";
  job.output.report = "report.json";
  job.output.mesh_format = "stl";
  job.output.mesh_prefix = "variant";
  job.output.smooth_factor = 2;
  return job;
}

}  // namespace

int main() {
  const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  const std::string dir = TMP_DIR;
  using manifold::Manifold;

  // ── (e) ────────────────────────────────────────────────────────────────────
  write_stl_file(dir + "/finish_bar.stl", from_manifold(Manifold::Cube({40.0, 10.6, 10.6})));
  const StepModel bar = import_part(dir + "/finish_bar.stl").model;
  double m_loop = NAN, m_fin = NAN;
  try {
    const RunJobResult r = run_job(bar_job(bar, 0.0), dir, dir + "/finish_run_a", materials,
                                   rules, false, RunObservability{});
    const std::string rep = r.report_json;
    const std::size_t f = rep.find("\"finish\": ");
    std::printf("[finish-run] (e) %zu file(s); finish block %s\n", r.mesh_paths.size(),
                f == std::string::npos ? "MISSING" : "present");
    CHECK(!r.mesh_paths.empty() && f != std::string::npos, "(e) report.json carries \"finish\"");
    CHECK(rep.find("\"verdict_changed\": true") == std::string::npos ||
              rep.find("After finishing") != std::string::npos,
          "(e) a changed verdict always carries its plain reason");
    if (f != std::string::npos && !r.mesh_paths.empty()) {
      m_fin = num_after(rep, "margin", rep.find("\"recheck\": ", f));
      m_loop = num_after(rep, "margin_before", f);
      const double mass = num_after(rep, "mass_grams", rep.find("\"recheck\": ", f));
      const TriangleMesh file = read_stl_file(r.mesh_paths.front()).mesh;
      const double vol = std::fabs(signed_volume(file));
      const double rho = materials.at("PLA").density_g_cm3;
      std::printf("[finish-run] (e) margin %.4g in the loop, %.4g on the finished file; "
                  "mass %.4g g from the report, %.4g g from the file; %d fixed, stair-step "
                  "%.1f %%; %.2f s\n",
                  m_loop, m_fin, mass, rho * vol / 1000.0,
                  rep.find("\"thin_spots_fixed\": []", f) == std::string::npos ? 1 : 0,
                  num_after(rep, "stair_step_removed_pct", f), num_after(rep, "seconds", f));
      CHECK(std::isfinite(m_fin) && m_fin > 0.0, "(e) the finished shape is re-certified");
      CHECK(std::fabs(mass - rho * vol / 1000.0) <= 1e-6 * mass + 1e-9,
            "(e) the exported file IS the finished shape (its mass is the re-check's)");
    }
  } catch (const std::exception& e) {
    ++g_failures;
    std::fprintf(stderr, "FAIL: (e) threw: %s\n", e.what());
  }
  // The flip: the margin required between the two margins.
  if (std::isfinite(m_loop) && std::isfinite(m_fin) && std::fabs(m_loop - m_fin) > 1e-6) {
    const double lo = std::min(m_loop, m_fin), hi = std::max(m_loop, m_fin);
    if (m_fin < m_loop) {
      try {
        const RunJobResult r = run_job(bar_job(bar, 0.5 * (lo + hi)), dir, dir + "/finish_run_b",
                                       materials, rules, false, RunObservability{});
        const std::string rep = r.report_json;
        const std::size_t rej = rep.find("\"rejected_variants\"");
        const std::size_t why = rep.find("After finishing, the margin is", rej == std::string::npos ? 0 : rej);
        std::printf("[finish-run] (e) margin required %.4g: %zu file(s); the refusal: %s\n",
                    0.5 * (lo + hi), r.mesh_paths.size(),
                    why == std::string::npos ? "MISSING" : rep.substr(why, 60).c_str());
        CHECK(r.mesh_paths.empty() && why != std::string::npos,
              "(e) a verdict the finishing flips is refused with its plain reason");
      } catch (const std::exception& e) {
        ++g_failures;
        std::fprintf(stderr, "FAIL: (e) flip threw: %s\n", e.what());
      }
    } else {
      // Measured 2026-11-02: the finished file re-certifies ABOVE the loop on this bar
      // (2.475 -> 3.416; 5.663 -> 5.897 with PLSM off): finishing adds material only and
      // moves a cut surface at most half a cell, so it does not weaken it. No version is
      // then refused for it (the refusal lines are test_finish (e)).
      std::printf("[finish-run] (e) the finished margin is HIGHER (%.4g > %.4g): nothing to "
                  "refuse on this fixture\n", m_fin, m_loop);
    }
  }

  // ── (w) ────────────────────────────────────────────────────────────────────
  try {
    JobDescription job = bar_job(bar, 0.0);
    KeepRegion end;
    end.min = Vec3{-1.9, -1.0, -1.0};
    end.max = Vec3{3.0, 11.6, 11.6};
    KeepRegion rod;
    rod.cylinder = true;
    rod.axis = 0;
    rod.min = Vec3{14.0, 2.3, 2.3};
    rod.max = Vec3{26.0, 8.3, 8.3};
    job.keep_regions = {end, rod};
    const RunJobResult r = run_job(job, dir, dir + "/finish_run_w", materials, rules, false,
                                   RunObservability{});
    const std::string rep = r.report_json;
    int dirty = 0, unimportable = 0;
    for (const std::string& path : r.mesh_paths) {
      const WrittenAudit w = audit_as_written(read_stl_file(path).mesh);
      std::printf("[finish-run] (w) %s: %d edge(s) on more than two triangles, %d open, %d "
                  "point contact(s), %d shell(s), %d body(ies)\n",
                  path.substr(path.find_last_of('/') + 1).c_str(), w.non_manifold_edges,
                  w.boundary_edges, w.non_manifold_vertices, w.shells, w.bodies);
      dirty += w.non_manifold_edges > 0 || w.boundary_edges > 0 || w.non_manifold_vertices > 0 ||
               w.shells != w.bodies;
      try {
        (void)import_part_file_resolved(path);
      } catch (const std::exception& e) {
        ++unimportable;
        std::fprintf(stderr, "  the normal import refuses it: %s\n", e.what());
      }
    }
    CHECK(!r.mesh_paths.empty() && dirty == 0, "(w) every finished file is clean as written");
    CHECK(unimportable == 0, "(w) every finished file passes the normal import");
    CHECK(rep.find("\"style\": ") != std::string::npos &&
              rep.find("\"finish_fallback\": ") != std::string::npos,
          "(w) the finish block says its style and whether it fell back");
  } catch (const std::exception& e) {
    ++g_failures;
    std::fprintf(stderr, "FAIL: (w) threw: %s\n", e.what());
  }

  // ── (s) a STREAMED run: one FINISH line per streamed version, files final ──
  try {
    const std::string log = dir + "/finish_stream_stdout.txt";
    std::fflush(stdout);
    const int saved = dup(1);
    const int fd = open(log.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
    dup2(fd, 1);
    close(fd);
    RunJobResult r;
    std::string err;
    try {
      r = run_job(bar_job(bar, 0.0), dir, dir + "/finish_run_s", materials, rules, true,
                  RunObservability{});
    } catch (const std::exception& e) {
      err = e.what();
    }
    std::fflush(stdout);
    dup2(saved, 1);
    close(saved);
    if (!err.empty()) throw std::runtime_error(err);
    const std::string out = slurp(log);
    int variants = 0, finishes = 0, slim = 0;
    for (std::size_t p = 0; (p = out.find("VARIANT vf=", p)) != std::string::npos; ++p) ++variants;
    for (std::size_t p = 0; (p = out.find("FINISH vf=", p)) != std::string::npos; ++p) ++finishes;
    for (std::size_t p = 0; (p = out.find("status=slim", p)) != std::string::npos; ++p) ++slim;
    std::printf("[finish-run] (s) streamed: %d VARIANT line(s), %d FINISH line(s) (%d slim), %zu "
                "file(s)\n", variants, finishes, slim, r.mesh_paths.size());
    CHECK(variants > 0 && finishes == variants,
          "(s) every streamed version gets one FINISH line once (e) has decided");
    CHECK(static_cast<int>(r.mesh_paths.size()) == slim,
          "(s) the files listed are the versions that kept their file");
  } catch (const std::exception& e) {
    ++g_failures;
    std::fprintf(stderr, "FAIL: (s) threw: %s\n", e.what());
  }

  // ── (f) ────────────────────────────────────────────────────────────────────
  {
    write_stl_file(dir + "/finish_L.stl",
                   from_manifold(Manifold::Cube({40.0, 10.0, 10.0}) +
                                 Manifold::Cube({10.0, 10.0, 30.0}).Translate({30.0, 0.0, 10.0})));
    const StepModel L = import_part(dir + "/finish_L.stl").model;
    const int anchor = face_facing(L, -1, 0, 0), top = face_facing(L, 0, 0, 1, 40.0, 2);
    CHECK(anchor >= 0 && top >= 0, "precondition: the L's end and the post's top");
    double margin[2] = {NAN, NAN}, il[2] = {NAN, NAN}, over[2] = {NAN, NAN};
    const Vec3 dirs[2] = {{0.0, 0.0, 1.0}, {1.0, 0.0, 0.0}};
    for (int q = 0; q < 2 && anchor >= 0 && top >= 0; ++q) {
      JobDescription j;
      j.model = "finish_L.stl";
      j.material = "PLA";
      j.mode = "analyze";
      j.resolution = 48;
      j.loads.present = true;
      j.loads.anchor_face_ids = {anchor};
      JobLoadGroup g;
      g.face_ids = {top};
      g.force = Vec3{-200.0, 0.0, 0.0};
      j.loads.groups.push_back(g);
      j.loads.build_dir = Vec3{0.0, 0.0, 1.0};
      j.has_orientation_recheck = true;
      j.orientation_recheck_mesh = "finish_L.stl";
      j.orientation_recheck_dir = dirs[q];
      j.output.report = "analysis_report.json";
      j.output.mesh_format = "stl";
      j.output.mesh_prefix = "variant";
      try {
        const AnalyzeJobResult a = analyze_job(j, dir, dir + "/finish_orient_" + std::to_string(q),
                                               materials, rules, "", {});
        const std::string js = slurp(a.provenance_path);
        const std::size_t b = js.find("\"orientation_recheck\": ");
        margin[q] = num_after(js, "margin", b);
        il[q] = num_after(js, "interlayer_margin", b);
        over[q] = num_after(js, "overhang_area_mm2", b);
        std::printf("[finish-run] (f) build %s: margin %.4g, interlayer %.4g, overhang %.1f "
                    "mm^2; \"%s\"\n", q == 0 ? "+Z (upright)" : "+X (on its end)", margin[q],
                    il[q], over[q], a.orientation_recheck_reason.c_str());
        CHECK(b != std::string::npos && !a.orientation_recheck_reason.empty(),
              "(f) analysis.json carries the orientation re-check and its reason");
      } catch (const std::exception& e) {
        ++g_failures;
        std::fprintf(stderr, "FAIL: (f) threw: %s\n", e.what());
      }
    }
    CHECK(std::isfinite(il[0]) && std::isfinite(il[1]) &&
              std::fabs(il[0] - il[1]) > 1e-3 * std::max(il[0], il[1]),
          "(f) upright and on its end give different interlayer margins");
    CHECK(std::isfinite(over[0]) && std::isfinite(over[1]) && over[1] > over[0] + 100.0,
          "(f) lying on its end, the post's back hangs over the bed (more overhang)");

    // The mesh path is relative to the job folder, and the job folder may be relative:
    // the same re-check from a relative folder, with the version's file in it.
    auto recheck = [&](const std::string& job_dir, const std::string& mesh, const char* what) {
      JobDescription j;
      j.model = "finish_L.stl";
      j.material = "PLA";
      j.mode = "analyze";
      j.resolution = 48;
      j.loads.present = true;
      j.loads.anchor_face_ids = {anchor};
      JobLoadGroup g;
      g.face_ids = {top};
      g.force = Vec3{-200.0, 0.0, 0.0};
      j.loads.groups.push_back(g);
      j.loads.build_dir = Vec3{0.0, 0.0, 1.0};
      j.has_orientation_recheck = true;
      j.orientation_recheck_mesh = mesh;
      j.orientation_recheck_dir = dirs[1];
      j.output.report = "analysis_report.json";
      try {
        const AnalyzeJobResult a = analyze_job(j, job_dir, dir + "/finish_orient_" + what,
                                               materials, rules, "", {});
        std::printf("[finish-run] (f) %s: overhang %.1f mm^2\n", what,
                    a.orientation_recheck_overhang_mm2);
        return a.orientation_recheck_overhang_mm2;
      } catch (const std::exception& e) {
        std::fprintf(stderr, "  (f) %s threw: %s\n", what, e.what());
        return -1.0;
      }
    };
    if (anchor >= 0 && top >= 0) {
      std::filesystem::create_directories(dir + "/finish_rel");
      std::filesystem::copy_file(dir + "/finish_L.stl", dir + "/finish_rel/finish_L.stl",
                                 std::filesystem::copy_options::overwrite_existing);
      std::filesystem::current_path(dir);
      const double rel = recheck("finish_rel", "finish_L.stl", "relative folder");
      CHECK(std::fabs(rel - over[1]) < 1e-6, "(f) a relative job folder re-checks the same file");
#ifdef TOPOPT_HAVE_3MF
      write_3mf_file(dir + "/finish_rel/finish_L.3mf", read_stl_file(dir + "/finish_L.stl").mesh);
      const double tmf = recheck("finish_rel", "finish_L.3mf", "3MF file");
      CHECK(std::fabs(tmf - over[1]) < 1e-3 * over[1], "(f) a 3MF version re-checks like its STL");
#endif
    }
  }

  if (g_failures == 0) {
    std::printf("finish run (E1): all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "finish run (E1): %d/%d checks FAILED\n", g_failures, g_checks);
  return 1;
}
