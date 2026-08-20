// topopt-cli — the canonical headless entry point (ARCHITECTURE §9 M6):
//
//   topopt-cli run job.json [--out DIR] [--materials PATH] [--rules PATH]
//
// Runs the full §5 pipeline described by job.json (schema: the maintainer-
// authored demo fixture core/tests/fixtures/demo/job.json) and writes the M5.2
// report plus one exported mesh per accepted variant into --out (default: the
// current directory). --materials / --rules default to the committed
// materials.json / settings rules.json paths injected at build time (this
// binary is the repo's dev/CI driver, not an installed product).
//
// Exit codes: 0 success; 1 any job/pipeline failure (diagnostic on stderr);
// 2 usage error.

#include <cstdio>
#include <cstdlib>
#include <exception>
#include <string>

#include "topopt/job.hpp"
#include "topopt/materials.hpp"
#include "topopt/part.hpp"
#include "topopt/settings.hpp"
#include "topopt/version.hpp"

// A build fingerprint (typically the core git commit SHA), injected by CMake. A
// LAN worker exposes it via /health so the iPad app can REFUSE a worker whose
// core differs from its own — the version-skew guard (handoff 093 STEP 3d): two
// cores that differ silently produce different parts. Defaults to "dev" for an
// un-instrumented local build.
#ifndef TOPOPT_BUILD_FINGERPRINT
#define TOPOPT_BUILD_FINGERPRINT "dev"
#endif

namespace {

int usage(const char* argv0) {
  std::fprintf(stderr,
               "usage: %s run <job.json> [--out DIR] [--materials PATH] "
               "[--rules PATH]\n"
               "              [--no-iteration-csv] [--snapshots] "
               "[--snapshot-every N] [--snapshot-cap N]\n"
               "              [--threads N]\n"
               "       %s analyze <job.json> [--mesh PATH] [--smooth S] "
               "[--no-min-feature] [--out DIR]\n"
               "              [--materials PATH] [--rules PATH]\n"
               "       %s preflight <job.json> [--materials PATH]\n"
               "       %s lattice-variant <job.json> [--out DIR] "
               "[--materials PATH] [--rules PATH]\n"
               "       %s --version\n"
               "\n"
               "preflight\n"
               "         the PRE-FLIGHT LOAD-PATH CHECK alone, no solve: can the\n"
               "         load reach the anchors through material the optimizer is\n"
               "         ALLOWED to place? Exit 0 = yes (or nothing to decide),\n"
               "         3 = `run` would REFUSE this job, with the reason.\n"
               "run      optimize the job's ladder and export accepted variants\n"
               "         (mode \"minimize_plastic\" only — `run` REFUSES an\n"
               "         \"analyze\"-mode job).\n"
               "analyze  ONE FEA analysis solve on a FIXED design, no optimization\n"
               "         (a job.json with \"mode\": \"analyze\" belongs here — the\n"
               "         LAN worker routes it here automatically).\n"
               "         (the re-certification 'receipt'). Without --mesh it certifies\n"
               "         the job's model as a solid part; with --mesh PATH it re-voxelizes\n"
               "         that mesh (e.g. a smoothed variant) onto the run's grid and\n"
               "         re-analyzes it. Writes analysis_report.json + analysis.json\n"
               "         (provenance + both mass figures) + fields.bin to --out.\n"
               "         --smooth S (0<S<=1) constrained-Taubin-smooths the --mesh\n"
               "         input first (bores/pads frozen, min-feature enforced), writes\n"
               "         <mesh>_smoothed.stl, and re-certifies THAT; --no-min-feature\n"
               "         disables the thinning constraint (for the S2 demo).\n"
               "lattice-variant\n"
               "         LATTICE A FINISHED VARIANT of a completed run (mode\n"
               "         \"lattice_variant\"). NO optimization ladder runs: the job's\n"
               "         \"variant\" block names that run's design.bin + which rung,\n"
               "         the design is restored from it, re-certified (its RECORDED\n"
               "         margin must reproduce exactly or the job refuses), graded from\n"
               "         its own recovered stress field, emitted as a latticed mesh and\n"
               "         certified as the composite. Writes the latticed mesh(es),\n"
               "         <prefix>_<vf>_lattice.report.json, lattice_variant_report.json,\n"
               "         lattice_variant.json (provenance), loadcase.json, run_info.json\n"
               "         and fields.bin to --out.\n"
               "\n"
               "Observability (handoff 114), written to --out by `run`:\n"
               "  run_info.json      version + config record (always)\n"
               "  iterations.csv     per-iteration trace (default ON; "
               "--no-iteration-csv disables)\n"
               "  snapshots/*.f16    float16 density snapshots (opt-in "
               "--snapshots; ~10.8 MB each at 5.4M voxels)\n",
               argv0, argv0, argv0, argv0, argv0);
  return 2;
}

std::string dirname_of(const std::string& path);  // defined below

// `analyze` subcommand — parse its flags and run analyze_job. Returns the process
// exit code.
int run_analyze(int argc, char** argv, const std::string& materials_default,
                const std::string& rules_default) {
  if (argc < 3) return usage(argv[0]);
  const std::string job_path = argv[2];
  std::string out_dir = ".";
  std::string materials_path = materials_default;
  std::string rules_path = rules_default;
  std::string mesh_path;
  topopt::SmoothRequest smooth;
  for (int i = 3; i < argc; ++i) {
    const std::string arg = argv[i];
    // Value-less flags first.
    if (arg == "--no-min-feature") {
      smooth.enforce_min_feature = false;
      continue;
    }
    if (i + 1 >= argc) return usage(argv[0]);
    if (arg == "--out") {
      out_dir = argv[++i];
    } else if (arg == "--materials") {
      materials_path = argv[++i];
    } else if (arg == "--rules") {
      rules_path = argv[++i];
    } else if (arg == "--mesh") {
      mesh_path = argv[++i];
    } else if (arg == "--smooth") {
      smooth.enabled = true;
      smooth.strength = std::atof(argv[++i]);
    } else {
      return usage(argv[0]);
    }
  }

  try {
    const topopt::JobDescription job = topopt::load_job_file(job_path);
    const topopt::MaterialLibrary materials =
        topopt::load_materials_file(materials_path);
    const topopt::SettingsRules rules =
        topopt::load_settings_rules_file(rules_path);

    const topopt::AnalyzeJobResult r = topopt::analyze_job(
        job, dirname_of(job_path), out_dir, materials, rules, mesh_path, smooth);
    const topopt::FixedDesignAnalysis& a = r.analysis;

    std::printf("analyze: %s (fixed design, ONE analysis solve, no optimization)\n",
                r.analyzed_mesh ? ("mesh " + r.analyzed_mesh_path).c_str()
                                : (job.model + " as solid part").c_str());
    if (r.smoothed) {
      const topopt::SmoothStats& s = r.smooth_stats;
      std::printf("  smoothed \xC2\xB7 re-analyzed: strength %.3g  pairs %d/%d  "
                  "frozen %zu/%zu\n",
                  r.smooth_strength, s.applied_pairs, s.requested_pairs,
                  s.frozen_vertices, s.total_vertices);
      std::printf("  volume drift: %.4g%% (bound %.4g%%)   min-feature %d->%d%s\n",
                  100.0 * s.volume_drift_fraction, 100.0 * s.volume_drift_bound,
                  s.min_feature_baseline, s.min_feature_after,
                  s.min_feature_limited ? "  [constraint STOPPED smoothing]" : "");
      std::printf("  smoothed mesh: %s\n", r.smoothed_mesh_path.c_str());
    }
    std::printf("  peak stress: %.4g MPa   worst-case margin: %.4g "
                "(required %.4g)\n",
                a.max_von_mises, a.margin.worst_case, r.margin_required);
    std::printf("  load case: %s\n",
                job.loads.present ? "declared external load" : "self-weight");
    std::printf("  verdict: %s\n", a.accepted ? "ACCEPTED" : "REJECTED");
    std::printf("  voxel mass: %.4g g", r.voxel_mass_grams);
    if (r.analyzed_mesh)
      std::printf("   mesh mass: %.4g g", r.mesh_mass_grams);
    std::printf("\n  min-feature violations: %d\n", a.v3.min_feature_violations);
    std::printf("report: %s\n", r.report_path.c_str());
    std::printf("provenance: %s\n", r.provenance_path.c_str());
    std::printf("fields: %s\n", r.fields_path.c_str());
    return 0;
  } catch (const std::exception& e) {
    std::fprintf(stderr, "topopt-cli: %s\n", e.what());
    return 1;
  }
}

// `preflight` subcommand — the PRE-FLIGHT LOAD-PATH CHECK alone (task
// 2026-08-03-preflight-feasibility-and-divergence). Imports the model, builds
// the identical setup `run` builds, and answers in milliseconds whether the load
// can reach the anchors through material the optimizer is allowed to place. NO
// solve, NO output directory, nothing written.
//
// Exit code 0 = a load path exists (or there is none to decide: a self-weight
// job tags no load faces); 3 = `run` WOULD REFUSE this job, and the actionable
// reason is printed. 1 = the job could not be read at all.
int run_preflight(int argc, char** argv, const std::string& materials_default) {
  if (argc < 3) return usage(argv[0]);
  const std::string job_path = argv[2];
  std::string materials_path = materials_default;
  for (int i = 3; i < argc; ++i) {
    const std::string arg = argv[i];
    if (i + 1 >= argc) return usage(argv[0]);
    if (arg == "--materials") materials_path = argv[++i];
    else return usage(argv[0]);
  }
  try {
    const topopt::JobDescription job = topopt::load_job_file(job_path);
    const topopt::MaterialLibrary materials =
        topopt::load_materials_file(materials_path);
    const topopt::PreflightJobResult r =
        topopt::preflight_job(job, dirname_of(job_path), materials);
    const topopt::LoadPathWalk& w = r.preflight.walk;
    if (!w.decidable) {
      std::printf("preflight: VACUOUS — this job tags %zu load and %zu anchor "
                  "voxels, so there is no load path to decide (a self-weight "
                  "run declares no load faces). check %.2f ms, total %.1f ms\n",
                  w.load_voxels, w.anchor_voxels, r.preflight.wall_ms,
                  r.wall_ms);
      return 0;
    }
    std::printf("preflight: load path %s\n",
                w.connected ? "CONNECTED" : "SEVERED");
    std::printf("  %zu load voxels, %zu anchor voxels; %zu of %zu voxels may "
                "hold material (%zu forbidden)\n",
                w.load_voxels, w.anchor_voxels, w.printed_voxels,
                w.printed_voxels + r.preflight.forbidden_voxels,
                r.preflight.forbidden_voxels);
    if (w.connected)
      std::printf("  narrowest separating cross-section: %d voxels (%.4g mm^2) "
                  "at step %d of %d from the anchor\n"
                  "  (INFORMATION, not a verdict — connectivity is NECESSARY, "
                  "not sufficient)\n",
                  w.narrowest_separator_voxels, w.narrowest_separator_mm2,
                  w.narrowest_separator_level, w.geodesic_levels);
    std::printf("  check %.2f ms; import + setup + check %.1f ms\n",
                r.preflight.wall_ms, r.wall_ms);
    if (r.would_refuse) {
      std::fprintf(stderr, "%s\n", r.refusal.c_str());
      return 3;
    }
    return 0;
  } catch (const std::exception& e) {
    std::fprintf(stderr, "topopt-cli: %s\n", e.what());
    return 1;
  }
}

// `lattice-variant` subcommand — LATTICE A FINISHED VARIANT (task
// 2026-08-02-lattice-a-variant). Returns the process exit code.
int run_lattice_variant(int argc, char** argv,
                        const std::string& materials_default,
                        const std::string& rules_default) {
  if (argc < 3) return usage(argv[0]);
  const std::string job_path = argv[2];
  std::string out_dir = ".";
  std::string materials_path = materials_default;
  std::string rules_path = rules_default;
  for (int i = 3; i < argc; ++i) {
    const std::string arg = argv[i];
    if (i + 1 >= argc) return usage(argv[0]);
    if (arg == "--out") {
      out_dir = argv[++i];
    } else if (arg == "--materials") {
      materials_path = argv[++i];
    } else if (arg == "--rules") {
      rules_path = argv[++i];
    } else {
      return usage(argv[0]);
    }
  }

  try {
    const topopt::JobDescription job = topopt::load_job_file(job_path);
    const topopt::MaterialLibrary materials =
        topopt::load_materials_file(materials_path);
    const topopt::SettingsRules rules =
        topopt::load_settings_rules_file(rules_path);

    const topopt::LatticeVariantJobResult r = topopt::lattice_variant_job(
        job, dirname_of(job_path), out_dir, materials, rules);

    // ★ TWO MODES THROUGH ONE ENTRY POINT (task
    // 2026-08-17-lattice-stage-repair). `lattice_part` names no design and no
    // rung, so it must not print `job.variant.design` — which is empty there.
    if (job.mode == "lattice_part")
      std::printf(
          "lattice-part: the imported part, solid vf=%.4g — NO ladder ran, "
          "NO optimization\n",
          r.requested_volume_fraction);
    else
      std::printf(
          "lattice-variant: rung vf=%.4g (index %d of %s) — NO ladder ran\n",
          r.requested_volume_fraction, r.variant_index,
          job.variant.design.c_str());
    std::printf("  design: fingerprint %llu, %d optimizer iterations originally\n",
                static_cast<unsigned long long>(r.design_fingerprint),
                r.optimizer_iterations);
    std::printf("  reproduction: recorded margin %.6g == reproduced %.6g "
                "(enforced)\n",
                r.recorded_margin_worst_case, r.reproduced_margin_worst_case);
    std::printf("  solves: %d certification (design iterations %d, variant "
                "meshes %d)\n",
                r.analysis_solves, r.design_iterations,
                r.variant_meshes_written);
    std::printf("  lattice: %s cell %.4g mm, rho %.4g..%.4g over %lld voxels\n",
                r.graded ? "graded" : "uniform", r.cell_size_mm, r.rho_min_used,
                r.rho_max_used, r.latticed_voxels);
    std::printf("  solid margin %.4g -> latticed margin %.4g (effective %.4g)\n",
                r.solid.margin.worst_case, r.lattice.margin.worst_case,
                r.lattice.margin_effective);
    if (r.lattice.lattice_strut_report) {
      const topopt::StrutStrengthReport& ss = r.lattice.lattice_strut;
      std::printf("  strut strength (REPORT, not gated): in-plane %.4g   "
                  "interlayer %.4g%s\n",
                  ss.margin_in_plane, ss.margin_interlayer,
                  r.lattice.lattice_strut_out_of_regime ? "   [OUT OF REGIME]"
                                                        : "");
    }
    std::printf("  verdict: %s\n",
                r.lattice.accepted ? "ACCEPTED" : "REJECTED");
    for (const std::string& m : r.mesh_paths)
      std::printf("mesh: %s\n", m.c_str());
    std::printf("receipt: %s\n", r.lattice_receipt_path.c_str());
    std::printf("report: %s\n", r.report_path.c_str());
    std::printf("provenance: %s\n", r.provenance_path.c_str());
    std::printf("loadcase: %s\n", r.loadcase_receipt_path.c_str());
    std::printf("fields: %s\n", r.fields_path.c_str());
    std::printf("wall: %.2f s\n", r.wall_seconds);
    return 0;
  } catch (const std::exception& e) {
    std::fprintf(stderr, "topopt-cli: %s\n", e.what());
    return 1;
  }
}

std::string dirname_of(const std::string& path) {
  const std::string::size_type slash = path.find_last_of('/');
  if (slash == std::string::npos) return ".";
  if (slash == 0) return "/";
  return path.substr(0, slash);
}

}  // namespace

int main(int argc, char** argv) {
  // Version / build fingerprint, one parseable line, for the worker /health probe.
  if (argc >= 2 &&
      (std::string(argv[1]) == "--version" || std::string(argv[1]) == "version")) {
    std::printf("topopt-cli version=%s fingerprint=%s\n", topopt::version(),
                TOPOPT_BUILD_FINGERPRINT);
    return 0;
  }
  // `analyze` — ONE analysis solve on a fixed design, no optimization.
  if (argc >= 2 && std::string(argv[1]) == "analyze")
    return run_analyze(argc, argv, TOPOPT_CLI_DEFAULT_MATERIALS,
                       TOPOPT_CLI_DEFAULT_RULES);
  // `preflight` — the load-path connectivity check ALONE, no solve (task
  // 2026-08-03-preflight-feasibility-and-divergence).
  if (argc >= 2 && std::string(argv[1]) == "preflight")
    return run_preflight(argc, argv, TOPOPT_CLI_DEFAULT_MATERIALS);
  // `lattice-variant` — lattice a FINISHED variant, no optimization at all.
  if (argc >= 2 && std::string(argv[1]) == "lattice-variant")
    return run_lattice_variant(argc, argv, TOPOPT_CLI_DEFAULT_MATERIALS,
                               TOPOPT_CLI_DEFAULT_RULES);
  if (argc < 3 || std::string(argv[1]) != "run") return usage(argv[0]);
  const std::string job_path = argv[2];
  std::string out_dir = ".";
  std::string materials_path = TOPOPT_CLI_DEFAULT_MATERIALS;
  std::string rules_path = TOPOPT_CLI_DEFAULT_RULES;
  // Handoff 114 — observability config. The build fingerprint (this binary's
  // TOPOPT_BUILD_FINGERPRINT) is stamped into run_info.json so the era is provable.
  topopt::RunObservability obs;
  obs.fingerprint = TOPOPT_BUILD_FINGERPRINT;
  // ★ --threads N: HOW MUCH OF THE MACHINE THIS RUN MAY TAKE. 0 (the DEFAULT)
  // leaves the production rule alone — production_matfree_thread_count(), the
  // performance-core pin. It is a PURE PERFORMANCE CONTROL and cannot move a
  // number: the matrix-free apply threads a deterministic 8-colour partition of
  // the voxel grid, so no two threads ever touch the same node and the
  // accumulation order is fixed regardless of the count (fea.hpp on
  // fea_set_matfree_threads: "BIT-IDENTICAL for any thread count"). It exists
  // because a run that pins every performance core makes the machine unusable
  // for the hours it takes, and "wait until tonight" is not a setting.
  int threads = 0;
  for (int i = 3; i < argc; ++i) {
    const std::string arg = argv[i];
    // Value-less flags first.
    if (arg == "--no-iteration-csv") {
      obs.iteration_csv = false;
      continue;
    }
    if (arg == "--snapshots") {
      obs.density_snapshots = true;
      continue;
    }
    // Every remaining flag takes a value.
    if (i + 1 >= argc) return usage(argv[0]);
    if (arg == "--out") {
      out_dir = argv[++i];
    } else if (arg == "--materials") {
      materials_path = argv[++i];
    } else if (arg == "--rules") {
      rules_path = argv[++i];
    } else if (arg == "--snapshot-every") {
      obs.snapshot_every = std::atoi(argv[++i]);
      if (obs.snapshot_every < 1) return usage(argv[0]);
    } else if (arg == "--snapshot-cap") {
      obs.snapshot_cap = std::atoi(argv[++i]);
    } else if (arg == "--threads") {
      threads = std::atoi(argv[++i]);
      if (threads < 1) return usage(argv[0]);
    } else {
      return usage(argv[0]);
    }
  }

  try {
    topopt::JobDescription job = topopt::load_job_file(job_path);
    // ── ★ THIS VERB RUNS THE PARAMETRIC LEVEL SET AND NOTHING ELSE ──────────
    // (task 2026-08-10-plsm-production; maintainer instruction, confirmed.)
    //
    // `topopt-cli run` has NO SIMP ROUTE. The maintainer's reason, in his words:
    // the CLI is the fastest test loop for the new algorithm, and leaving it on
    // the old one leaves that loop unusable for the thing being tested. The
    // front-end already runs the parametric path exclusively — on-device via
    // TopOptBridge and remotely via this binary — so this closes the last gap
    // rather than opening one.
    //
    // ★ IT IS A HARD BLOCK, NOT A DEFAULT. A job asking for `plsm.enabled:
    // false` is REFUSED, loudly, rather than silently overridden. This task has
    // already turned up three settings that were accepted and dropped on the
    // floor (`simp.max_iterations` on a load-case job among them), and adding a
    // fourth — one that silently ran a DIFFERENT ALGORITHM than the job asked
    // for — would be the worst of the set.
    //
    // ★ SCOPE IS THIS VERB. `analyze`, `preflight` and `lattice-variant` do not
    // optimise, so there is nothing in them to select. `run_job` and
    // `minimize_plastic` keep their `PlsmMode::Off` default, because 22 test
    // files call them IN-PROCESS with values pinned from SIMP designs (margins,
    // masses, reproduction bands) and those tests are the evidence that the SIMP
    // code is unmoved. Nothing a user or the app can invoke reaches that default.
    if (job.has_plsm && !job.plsm_enabled) {
      std::fprintf(stderr,
                   "topopt-cli run: \"plsm.enabled\": false was requested, but "
                   "this CLI has no SIMP route to fall back to — it runs the "
                   "parametric level set only. Remove the key (or set it true) "
                   "to run; the \"plsm\" block's other keys still tune it.\n");
      return 2;
    }
    job.has_plsm = true;
    job.plsm_enabled = true;
    const topopt::MaterialLibrary materials =
        topopt::load_materials_file(materials_path);
    const topopt::SettingsRules rules =
        topopt::load_settings_rules_file(rules_path);

    // emit_progress = true: stream PROGRESS/VARIANT checkpoint lines to stdout and
    // export each accepted variant as it completes, so a wrapper (the LAN worker,
    // handoff 093) can forward live progress + progressive artifacts.
    // Applied AFTER the job is loaded and BEFORE the run, which is where
    // fea.hpp says a caller wanting a non-default count applies it: run_job
    // calls configure_production_options (which sets the production count) at
    // its start, so setting it here would be overwritten. The override therefore
    // rides RunObservability's sibling channel — an explicit field on the run —
    // rather than a global set at the wrong moment.
    topopt::RunObservability obs_run = obs;
    obs_run.matfree_threads = threads;
    const topopt::RunJobResult result =
        topopt::run_job(job, dirname_of(job_path), out_dir, materials, rules,
                        /*emit_progress=*/true, obs_run);

    // "B-rep faces" only for a STEP part; an STL/3MF part carries manufactured
    // PSEUDO-faces (handoff 2026-07-24-mesh-optimize-path), so name them honestly.
    const bool is_mesh =
        topopt::part_format_for_path(job.model) != topopt::PartFormat::Step;
    std::printf("model: %s (%d %s faces, %zu fixture faces matched)\n",
                job.model.c_str(), result.model.face_count,
                is_mesh ? "pseudo" : "B-rep", result.fixture_face_ids.size());
    // Count ACCEPTED VARIANTS, not mesh files: a latticed run writes extra
    // companion meshes per variant (handoff 2026-07-28-lattice-generation), so
    // mesh_paths.size() no longer equals the accepted-variant count.
    std::size_t accepted_variants = 0;
    for (const topopt::MinimizePlasticVariant& v : result.pipeline.evaluated)
      if (v.accepted) ++accepted_variants;
    // Task 2026-08-03-growth-ladder — NAME THE MODE, before any number. The two
    // ladders optimize for opposite things and their variant tables look alike;
    // a reader who does not know which one ran cannot read the table.
    std::printf("ladder: %s\n",
                result.pipeline.growth_ladder
                    ? "GROWTH [1.55, 1.25, 1.10 x the part] — add as little "
                      "plastic as possible to reach the required margin"
                    : "REDUCTION [0.68, 0.52, 0.38, 0.26 x the part] — remove "
                      "as much plastic as possible while holding it");
    std::printf("variants: %zu evaluated, %zu accepted%s\n",
                result.pipeline.evaluated.size(), accepted_variants,
                result.pipeline.stopped_on_margin
                    ? " (stopped on margin)"
                    : "");
    for (const topopt::MinimizePlasticVariant& v : result.pipeline.evaluated) {
      // Handoff 131 — an infeasible rung has NO measured margin (its analysis was
      // skipped), so printing one would be a fabricated number: print the reason.
      if (v.infeasible) {
        std::printf("  vf %.2f: %s — ended at iteration %d, not analysed\n",
                    v.requested_volume_fraction, topopt::kRungInfeasibleReason,
                    v.optimization.infeasible_iteration);
        continue;
      }
      // Handoff 2026-07-27-nonconvergence-rejection — a non-convergent rung also has
      // NO measured margin (its analysis was skipped): print the reason, not a
      // fabricated number, and distinctly from the infeasible line above.
      if (v.non_convergent) {
        std::printf("  vf %.2f: %s — not certified\n",
                    v.requested_volume_fraction, topopt::kRungNonConvergentReason);
        continue;
      }
      std::printf(
          "  vf %.2f: margin %.3g, %s\n", v.requested_volume_fraction,
          v.report.margin.worst_case,
          v.accepted ? "accepted" : "rejected (below margin_stop)");
      // Task 2026-08-03-growth-ladder — on a growth run the accounting IS the
      // result: how much plastic this rung adds, and how much of the object you
      // are about to print was never in your model.
      const topopt::AddedMaterialReport& a = v.report.added_material;
      if (a.evaluated)
        std::printf(
            "        +%.4g g added (%lld of %lld printed voxels outside the "
            "part = %.1f%%, %.4g mm^3)%s\n",
            a.net_added_mass_grams, a.outside_part, a.printed_voxels,
            100.0 * a.outside_fraction, a.outside_volume_mm3,
            v.report.growth_target_saturated
                ? "  [SATURATED: the design box could not hold this rung's ask]"
                : "");
    }
    // THE RECOMMENDATION, said out loud. The last accepted rung is the design the
    // user prints; on a growth ladder that is the SMALLEST addition that passed,
    // and on a run where nothing passed there is no recommendation to make — say
    // that with the numbers rather than handing back the largest rung.
    if (result.pipeline.growth_ladder) {
      const topopt::MinimizePlasticVariant* rec = nullptr;
      for (const topopt::MinimizePlasticVariant& v : result.pipeline.evaluated)
        if (v.accepted) rec = &v;
      if (rec != nullptr)
        std::printf(
            "recommended: +%.0f%% (vf %.2f) — the SMALLEST addition that "
            "passes: +%.4g g, effective margin %.4g >= %.4g\n",
            100.0 * (rec->requested_volume_fraction - 1.0),
            rec->requested_volume_fraction,
            rec->report.added_material.net_added_mass_grams,
            rec->report.margin_effective, rec->report.margin_required);
      else if (!result.pipeline.evaluated.empty())
        std::printf(
            "recommended: NONE — no rung on the growth ladder passes. The "
            "largest (+%.0f%%) reached effective margin %.4g against a required "
            "%.4g. Growing is not the lever for this part; see report.json's "
            "per-variant diagnosis for the term that binds.\n",
            100.0 * (result.pipeline.evaluated.front().requested_volume_fraction -
                     1.0),
            result.pipeline.evaluated.front().report.margin_effective,
            result.pipeline.evaluated.front().report.margin_required);
    }
    std::printf("report: %s\n", result.report_path.c_str());
    for (const std::string& p : result.mesh_paths)
      std::printf("mesh: %s\n", p.c_str());
    // Handoff 114 — surface the observability artifacts (forwarded to the worker
    // log / SSE as plain log lines; they do not affect the SSE protocol).
    if (!result.run_info_path.empty())
      std::printf("run_info: %s\n", result.run_info_path.c_str());
    if (!result.iteration_csv_path.empty())
      std::printf("iterations: %s\n", result.iteration_csv_path.c_str());
    if (result.snapshot_count > 0)
      std::printf("snapshots: %zu written\n", result.snapshot_count);
    return 0;
  } catch (const std::exception& e) {
    std::fprintf(stderr, "topopt-cli: %s\n", e.what());
    return 1;
  }
}
