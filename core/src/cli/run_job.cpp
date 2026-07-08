#include "topopt/job.hpp"

#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <string>
#include <system_error>
#include <utility>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/report.hpp"
#include "topopt/step.hpp"
#include "topopt/stl.hpp"
#include "topopt/voxel.hpp"
#ifdef TOPOPT_HAVE_3MF
#include "topopt/threemf.hpp"
#endif

namespace topopt {
namespace {

// materials.json density is g/cm^3; the job's units are mm and mm/s^2 with
// material moduli in MPa (N/mm^2). The mm-MPa-consistent mass-density unit is
// t/mm^3, and 1 g/cm^3 = 1e-9 t/mm^3, so folding the 1e-9 into the gravity
// magnitude passed to minimize_plastic (which multiplies density_g_cm3 *
// gravity * voxel_volume) makes the load come out in N and every reported
// stress in MPa. The margin is a ratio, so only this PRODUCT matters.
constexpr double kGramPerCm3ToTonnePerMm3 = 1e-9;

std::string join_path(const std::string& dir, const std::string& name) {
  if (std::filesystem::path(name).is_absolute()) return name;
  return dir + "/" + name;
}

// <prefix>_<fraction*100, 3 digits>.<format>, per the demo fixture's
// _output_note (0.7 -> variant_070.3mf).
std::string mesh_file_name(const std::string& prefix, double requested_vf,
                           const std::string& format) {
  char digits[8];
  std::snprintf(digits, sizeof(digits), "%03d",
                static_cast<int>(std::lround(requested_vf * 100.0)));
  return prefix + "_" + digits + "." + format;
}

void write_text_file(const std::string& path, const std::string& text) {
  std::ofstream out(path, std::ios::binary);
  if (!out) throw JobError("cannot open output file for writing: " + path);
  out << text;
  out.flush();
  if (!out) throw JobError("failed writing output file: " + path);
}

}  // namespace

RunJobResult run_job(const JobDescription& job, const std::string& job_dir,
                     const std::string& out_dir,
                     const MaterialLibrary& materials,
                     const SettingsRules& rules) {
  // Fail fast on everything checkable before heavy work: the mode, the
  // material, and whether this build can write the requested mesh format.
  if (job.mode != "minimize_plastic")
    throw JobError("unsupported mode: " + job.mode);
  const auto mat_it = materials.find(job.material);
  if (mat_it == materials.end())
    throw JobError("material \"" + job.material +
                   "\" is not in the material library");
  const Material& material = mat_it->second;
#ifndef TOPOPT_HAVE_3MF
  if (job.output.mesh_format == "3mf")
    throw JobError(
        "this build has no 3MF support (lib3mf was not available): "
        "output.mesh_format \"3mf\" cannot be written, use \"stl\"");
#endif

  RunJobResult result;

  // §5 pipeline: STEP ──OCCT──▶ tessellated surface.
  result.model = import_step_file(join_path(job_dir, job.model));

  // Geometric fixture-face selection (locked rule, DECISIONS.md 2026-07-09).
  // Every selector must match at least one face — a job whose selector finds
  // nothing is a user error, not an empty no-op.
  for (const JobFaceSelector& sel : job.fixture_faces) {
    // parse_job admits only "cylindrical"; keep the check so a future selector
    // kind cannot silently select nothing.
    if (sel.kind != "cylindrical")
      throw JobError("unsupported fixture_faces selector kind: " + sel.kind);
    bool matched = false;
    for (int f = 0; f < result.model.face_count; ++f) {
      const StepFaceInfo& info = result.model.faces[static_cast<std::size_t>(f)];
      if (info.kind == StepSurfaceKind::Cylinder &&
          std::fabs(info.cylinder_radius_mm - sel.radius_mm) <=
              kJobFaceRadiusToleranceMm) {
        result.fixture_face_ids.push_back(f);
        matched = true;
      }
    }
    if (!matched)
      throw JobError("fixture_faces selector (cylindrical, radius_mm " +
                     std::to_string(sel.radius_mm) +
                     ") matched no face of the model");
  }

  // ──▶ watertight check.
  if (!check_watertight(result.model.mesh).watertight)
    throw JobError("model tessellation is not watertight: " + job.model);

  // ──▶ voxelize + tag the fixture voxels of every matched face.
  VoxelGrid grid = voxelize(result.model.mesh, job.resolution);
  std::size_t tagged = 0;
  for (const int f : result.fixture_face_ids)
    tagged += tag_step_face(grid, result.model, f, VoxelTag::Fixture);
  if (tagged == 0)
    throw JobError("fixture faces tagged no voxels (resolution too coarse "
                   "for the selected faces?)");

  // Mounting BCs: every node of every Fixture voxel is fully clamped.
  const std::vector<int> fixture_nodes =
      fea_tagged_nodes(grid, VoxelTag::Fixture);
  std::vector<DirichletBC> bcs;
  bcs.reserve(fixture_nodes.size() * 3);
  for (const int n : fixture_nodes)
    for (int c = 0; c < 3; ++c) bcs.push_back({n, c, 0.0});

  // ──▶ FEA + SIMP ladder + report assembly (the M5.3 driver).
  MinimizePlasticOptions options;
  options.volume_fraction_ladder = job.ladder;
  options.margin_stop = job.margin_stop;
  options.gravity = job.gravity.magnitude_mm_s2 * kGramPerCm3ToTonnePerMm3;
  options.gravity_direction = job.gravity.direction;
  if (job.simp_max_iterations > 0)
    options.simp.max_iterations = job.simp_max_iterations;
  result.pipeline =
      minimize_plastic(grid, material, job.material, bcs, rules, options);

  // ──▶ report + one exported mesh per ACCEPTED variant, into out_dir.
  {
    std::error_code ec;
    std::filesystem::create_directories(out_dir, ec);
    if (ec)
      throw JobError("cannot create output directory " + out_dir + ": " +
                     ec.message());
  }
  result.report_json = job_report_json(result.pipeline.report);
  result.report_path = join_path(out_dir, job.output.report);
  write_text_file(result.report_path, result.report_json);

  for (const MinimizePlasticVariant& variant : result.pipeline.evaluated) {
    if (!variant.accepted) continue;
    const std::string path = join_path(
        out_dir, mesh_file_name(job.output.mesh_prefix,
                                variant.requested_volume_fraction,
                                job.output.mesh_format));
    if (job.output.mesh_format == "3mf") {
#ifdef TOPOPT_HAVE_3MF
      write_3mf_file(path, variant.v3.mesh);
#else
      // Unreachable: rejected before the pipeline ran.
      throw JobError("3MF support unavailable in this build");
#endif
    } else {
      write_stl_file(path, variant.v3.mesh);
    }
    result.mesh_paths.push_back(path);
  }

  return result;
}

}  // namespace topopt
