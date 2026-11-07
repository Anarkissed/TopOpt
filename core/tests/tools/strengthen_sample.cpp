// strengthen_sample — a PREVIEW of CORE LIST item 50's "Redesign to strengthen"
// (his ask of 2026-10-24 21:58: "I want to be able to see what it is we're
// building"), ahead of the driver. Version 1 only, at the job's resolution:
//   1. the reference: the part's verified margin as drawn, or margin_required if
//      that is higher (analyze_job, the same certification `topopt-cli analyze` runs);
//   2. the ceiling: the domain (box, minus keep-outs and Keep Clears, plus every
//      frozen voxel; domain_box_only) filled solid, certified the same way;
//   3. version 1: target = reference x 4/3 (25 % less worst stress), started fresh
//      at vf0 = (target / ceiling)^(1/1.5) of the domain, at most two runs (the
//      second after one update vf <- vf (1.1 target / margin)^0.75, capped +-0.05);
//      certified by the run's own (in-loop) margin, as the preview allows.
// Writes original.stl, sample_v1.stl and summary.json into <out_dir>.
//
//   cmake --build core/build --target strengthen_sample
//   ./core/build/strengthen_sample <job.json> <out_dir> <materials.json> <rules.json> [res]
#include "topopt/job.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/part.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/settings.hpp"
#include "topopt/stl.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

using namespace topopt;

int main(int argc, char** argv) {
  if (argc < 5) {
    std::fprintf(stderr, "usage: %s <job.json> <out_dir> <materials> <rules> [res]\n",
                 argv[0]);
    return 2;
  }
  const auto t0 = std::chrono::steady_clock::now();
  const std::string job_path = argv[1], out = argv[2];
  const std::string job_dir = std::filesystem::path(job_path).parent_path().string();
  std::filesystem::create_directories(out);
  JobDescription job = load_job_file(job_path);
  if (argc > 5) job.resolution = std::atoi(argv[5]);
  job.loads.redesign = "strengthen";
  const MaterialLibrary materials = load_materials_file(argv[3]);
  const SettingsRules rules = load_settings_rules_file(argv[4]);
  const Material& material = materials.at(job.material);

  const StepModel model = import_part_file(job_dir + "/" + job.model);
  write_stl_file(out + "/original.stl", model.mesh, StlFormat::Binary);
  const ProductionLoadCase lc = production_loadcase_from_job(job, model);
  const ProductionRunSetup setup =
      build_production_loadcase(model, job.resolution, lc);
  MinimizePlasticOptions base = setup.options;
  if (job.has_plsm && job.plsm_enabled) {
    base.plsm.mode = PlsmMode::Parametric;
    base.plsm.max_iterations = job.plsm_max_iterations;
  }

  // 1. The reference.
  const AnalyzeJobResult drawn =
      analyze_job(job, job_dir, out + "/as_drawn", materials, rules, "", {});
  const double required = drawn.margin_required;
  const double ref = std::max(drawn.analysis.margin_effective, required);
  std::printf("[50] as drawn: margin %.4g (required %.4g) -> reference %.4g, "
              "mass %.4g g\n",
              drawn.analysis.margin_effective, required, ref, drawn.voxel_mass_grams);

  // 2. The ceiling: the domain filled solid.
  const SolvedDesignDomain dom = resolve_design_domain(setup.grid, setup.bcs, base);
  const DesignMask mask = design_domain_mask(dom, base);
  std::vector<double> filled(dom.grid.voxel_count(), 0.0);
  long long domain_voxels = 0;
  for (std::size_t i = 0; i < filled.size(); ++i)
    if (dom.grid.tags[i] != VoxelTag::Empty && mask[i] != MaskValue::FrozenVoid) {
      filled[i] = 1.0;
      ++domain_voxels;
    }
  write_stl_file(job_dir + "/strengthen_ceiling.stl",
                 keep_largest_component(marching_cubes(dom.grid, filled, 0.5)),
                 StlFormat::Binary);
  const AnalyzeJobResult ceiling = analyze_job(
      job, job_dir, out + "/ceiling", materials, rules, "strengthen_ceiling.stl", {});
  const double margin_max = ceiling.analysis.margin_effective;
  const double target = ref * 4.0 / 3.0;
  std::printf("[50] ceiling (domain filled, %lld voxels): margin %.4g, %.4g g; "
              "version 1 target %.4g%s\n",
              domain_voxels, margin_max, ceiling.voxel_mass_grams, target,
              target > 0.95 * margin_max ? "  UNREACHABLE" : "");
  if (target > 0.95 * margin_max) return 0;

  // 3. Version 1: fresh, at most two runs.
  auto run = [&](double vf) {
    MinimizePlasticOptions o = base;
    o.volume_fraction_ladder = {vf};
    MinimizePlasticResult r =
        minimize_plastic(setup.grid, material, job.material, setup.bcs, rules, o);
    std::printf("[50] run at vf %.4f: in-loop margin %.4g, %.4g g, %s%s\n", vf,
                r.evaluated.front().report.margin_effective,
                r.evaluated.front().mass_grams,
                r.evaluated.front().accepted ? "accepted" : "rejected: ",
                r.evaluated.front().report.rejection_reason.c_str());
    return r;
  };
  double vf = std::clamp(std::pow(target / margin_max, 1.0 / 1.5), 0.05, 1.0);
  MinimizePlasticResult r = run(vf);
  double m = r.evaluated.front().report.margin_effective;
  int runs = 1;
  if (!(m >= target && m <= 1.25 * target)) {
    const double next = std::clamp(vf * std::pow(1.1 * target / m, 0.75),
                                   std::max(0.02, vf - 0.05), std::min(1.0, vf + 0.05));
    MinimizePlasticResult r2 = run(next);
    const double m2 = r2.evaluated.front().report.margin_effective;
    ++runs;
    // Keep the lighter run that meets the target, else the stronger one.
    const bool keep2 = (m2 >= target && (m < target || next < vf)) ||
                       (m < target && m2 > m);
    if (keep2) {
      r = std::move(r2);
      vf = next;
      m = m2;
    }
  }
  const MinimizePlasticVariant& v = r.evaluated.front();

  // The export, as run_job writes it at smooth_factor 2: every carrying body.
  const VoxelGrid& sg = r.solved_grid;
  const TriangleMesh fine = marching_cubes_resampled(
      sg.nx, sg.ny, sg.nz, sg.spacing, sg.origin, v.optimization.physical_density,
      0.5, 2, ResampleInterp::Tricubic);
  const BodyShells shells = carrying_body_shells(
      fine, sg, printed_bodies(sg, v.optimization.physical_density, 0.5));
  write_stl_file(out + "/sample_v1.stl", shells.mesh, StlFormat::Binary);

  const double secs = std::chrono::duration<double>(
                          std::chrono::steady_clock::now() - t0).count();
  std::ofstream js(out + "/summary.json");
  js << "{\n  \"resolution\": " << job.resolution
     << ",\n  \"as_drawn_margin\": " << drawn.analysis.margin_effective
     << ",\n  \"margin_required\": " << required << ",\n  \"reference_margin\": " << ref
     << ",\n  \"ceiling_margin\": " << margin_max << ",\n  \"target_margin\": " << target
     << ",\n  \"volume_fraction_of_domain\": " << vf << ",\n  \"runs\": " << runs
     << ",\n  \"in_loop_margin\": " << m << ",\n  \"accepted\": "
     << (v.accepted ? "true" : "false") << ",\n  \"rejection_reason\": \""
     << v.report.rejection_reason << "\",\n  \"mass_grams\": " << v.mass_grams
     << ",\n  \"original_mass_grams\": " << drawn.voxel_mass_grams
     << ",\n  \"bodies_exported\": " << shells.bodies_exported
     << ",\n  \"seconds\": " << secs << "\n}\n";
  std::printf("[50] version 1: vf %.4f, in-loop margin %.4g vs target %.4g, mass "
              "%.4g g = %.1f %% of the original; %d run(s), %.0f s\n",
              vf, m, target, v.mass_grams,
              100.0 * v.mass_grams / drawn.voxel_mass_grams, runs, secs);
  return 0;
}
