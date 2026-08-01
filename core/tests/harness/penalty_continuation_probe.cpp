// penalty_continuation_probe.cpp — MEASURE SIMP penalization continuation
// (task 2026-08-02-simp-penalization-continuation) against the shipped constant
// p = 3, on the fixture that actually stagnates. NOT a CTest target; a
// standalone measurement harness, sibling of draft_arming_gate.cpp whose
// `make_big_stagnation` fixture, l_bracket/traction helpers and posture-runner
// shape it reproduces so the grid is the SAME grid those measurements used.
//
// WHY A PROBE AND NOT THE CLI. The schedule is a SimpOptions field and this task
// owns simp.cpp/simp.hpp only; plumbing it to job.json would mean editing
// minimize_plastic.cpp / run_job.cpp, which this task does not own. So the probe
// drives minimize_plastic() DIRECTLY with options.simp.penalty_continuation set
// — the same driver, the same ladder, the same gate — and reads the verdicts off
// MinimizePlasticResult. Nothing is simulated.
//
// WHAT IT PRINTS, one block per posture, then the comparison tables:
//   * per design iteration: p, beta, CG count, whether multigrid CARRIED, whether
//     a hierarchy BUILT, V-cycles burned — so a STAGNATING iteration (built but
//     did not carry) is a direct read, not an inference (AD2, AD6).
//   * per rung: design iterations, stagnating iterations, latched (no-build)
//     iterations, summed CG, wall seconds (AD2, AD3).
//   * the gate table: every evaluated rung's verdict + margin, final compliance,
//     achieved volume fraction, min-feature violations (AD4, AD5).
//
//   c++ -std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 \
//     -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" \
//     core/tests/harness/penalty_continuation_probe.cpp build/libtopopt.a \
//     -o build/penalty_continuation_probe
//   ./build/penalty_continuation_probe [iters] [csv-out-dir]

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/observability.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/production.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {

Material fdm() {
  Material m;
  m.youngs_modulus_mpa = 3500.0;
  m.yield_strength_mpa = 55.0;
  m.density_g_cm3 = 1.24;
  m.z_knockdown = 0.55;
  m.poisson = 0.33;
  m.family = "fdm";
  return m;
}

// verbatim from draft_arming_gate.cpp / ad_stag_mechanism_probe.cpp
VoxelGrid l_bracket(std::vector<DirichletBC>& bcs, int arm, int span, int ny,
                    int t, double h) {
  VoxelGrid g;
  g.nx = span;
  g.ny = ny;
  g.nz = arm;
  g.spacing = h;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(span) * ny * arm, VoxelTag::Empty);
  for (int k = 0; k < arm; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < span; ++i)
        if (i < t || k < t) g.set_tag(i, j, k, VoxelTag::Interior);
  auto solid = [&](int i, int j, int k) {
    if (i < 0 || j < 0 || k < 0 || i >= span || j >= ny || k >= arm) return false;
    return g.tag(i, j, k) != VoxelTag::Empty;
  };
  for (int k = 0; k < arm; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < span; ++i) {
        if (!solid(i, j, k)) continue;
        if (!solid(i - 1, j, k) || !solid(i + 1, j, k) || !solid(i, j - 1, k) ||
            !solid(i, j + 1, k) || !solid(i, j, k - 1) || !solid(i, j, k + 1))
          g.set_tag(i, j, k, VoxelTag::Surface);
      }
  for (int j = 0; j < ny; ++j)
    for (int i = 0; i < t; ++i) g.set_tag(i, j, arm - 1, VoxelTag::Fixture);
  bcs.clear();
  for (int b = 0; b <= ny; ++b)
    for (int a = 0; a <= t; ++a) {
      const int n = fea_node_index(g, a, b, arm);
      bcs.push_back({n, 0, 0.0});
      bcs.push_back({n, 1, 0.0});
      bcs.push_back({n, 2, 0.0});
    }
  for (int k = 0; k < t; ++k)
    for (int j = 0; j < ny; ++j) g.set_tag(span - 1, j, k, VoxelTag::Load);
  return g;
}

struct Fixture {
  VoxelGrid part;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  DesignBox box;
};

// The AD gate's Stagnation regime, verbatim (24x6x24 mm part in a ~48x32x48 box
// = 73 728 elements, 48.8x dilution, spacing 1.0 mm) — the grid on which the
// geometric V-cycle measurably falls to Jacobi-CG. That fall is the phenomenon
// this task exists to test, so this is the fixture.
Fixture make_big_stagnation(double pad_scale) {
  Fixture f;
  f.part = l_bracket(f.bcs, 24, 24, 6, 6, 1.0);
  f.loads = traction_loads(f.part, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});
  // The canonical box is the part's 24x6x24 mm envelope padded by (12, 13, 12)
  // mm on each side. `pad_scale` scales that PAD only (1.0 = verbatim), so a
  // scouting run can trade dilution (which drives the stagnation) against the
  // connectivity the gate needs, and the trade is a stated number rather than a
  // hand-edited literal.
  const double px = 12.0 * pad_scale, py = 13.0 * pad_scale, pz = 12.0 * pad_scale;
  f.box.min = Vec3{-px, -py, -pz};
  f.box.max = Vec3{24.0 + px, 6.0 + py, 24.0 + pz};
  return f;
}

// A cheaper sibling on the SAME construction, for the scouting/repeat runs (its
// stagnation is reported, never assumed — if it does not stagnate the probe says
// so and the measurement belongs on `big`).
Fixture make_small_stagnation() {
  Fixture f;
  f.part = l_bracket(f.bcs, 16, 16, 4, 4, 1.5);
  f.loads = traction_loads(f.part, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});
  f.box.min = Vec3{-12.0, -9.0, -12.0};
  f.box.max = Vec3{36.0, 15.0, 36.0};
  return f;
}

struct IterRow {
  int rung = 0;
  int iteration = 0;
  double penalty = 0.0;
  double beta = 0.0;
  int cg = 0;
  int mg = 0;    // multigrid CARRIED this solve
  int hier = 0;  // a hierarchy BUILT this solve
  int cycles = 0;
  double compliance = 0.0;
  double change = 0.0;
  double vf = 0.0;
};

struct RungRow {
  double vf_requested = 0.0;
  double vf_achieved = 0.0;
  int iterations = 0;
  int stagnating = 0;  // hierarchy BUILT but multigrid did NOT carry
  int latched = 0;     // no hierarchy built at all (127 latch, or not coarsenable)
  long long cg = 0;
  double compliance = 0.0;
  double margin = 0.0;
  int accepted = 0, infeasible = 0, non_convergent = 0;
  int min_feature = 0;
  int components = 0;
  double margin_effective = 0.0;
  std::string reason;  // report.rejection_reason ("" when accepted)
};

struct Posture {
  std::string label;
  std::vector<PenaltyStage> schedule;  // empty = OFF (the shipped p = 3)
  double wall = 0.0;
  long long cg_total = 0;
  long long iters_total = 0;
  int stagnating_total = 0;
  int latched_total = 0;
  std::vector<RungRow> rungs;
  std::vector<IterRow> trace;
  std::vector<double> density;  // terminal rung's field, for cross-posture deltas
};

const char* verdict(const RungRow& r) {
  if (r.infeasible) return "INFEAS";
  if (r.non_convergent) return "NONCONV";
  return r.accepted ? "ACCEPT" : "REJECT";
}

Posture run_posture(const std::string& label,
                    const std::vector<PenaltyStage>& schedule,
                    const Fixture& f, int iters,
                    const std::vector<double>& ladder, const SettingsRules& rules,
                    const Material& material) {
  MinimizePlasticOptions o;
  configure_production_options(o);  // the ARMED production stack, as it ships
  o.simp.penalty_continuation = schedule;  // <- the only axis this probe moves
  o.volume_fraction_ladder = ladder;
  o.margin_stop = 1.5;  // the real production stop, so verdict FLIPS are visible
  o.external_loads = f.loads;
  o.gravity = 9810.0 * 1e-9;
  o.gravity_direction = Vec3{0.0, 0.0, -1.0};
  o.infill_percent = 100.0;
  o.design_box = f.box;
  o.simp.max_iterations = iters;
  // PC_NOPROJ disarms the handoff-123 CONDITIONAL MMA-projection gate. It exists
  // to isolate ONE mechanism: with the gate armed a rung is TWO simp_optimize
  // calls (grayscale, then beta-projection seeded from it), and the penalty
  // schedule is PER CALL, so it REPLAYS from stage 1 in the projection phase.
  // Disarming the gate makes a rung one call, so the schedule runs exactly once
  // and the replay is removed as a variable. Nothing else about the posture
  // changes.
  if (std::getenv("PC_NOPROJ")) o.conditional_mma_projection_mnd_threshold = 0.0;

  Posture p;
  p.label = label;
  p.schedule = schedule;
  o.on_iteration = [&](std::size_t rung, std::size_t,
                       const SimpIterationObservation& ob) {
    IterRow r;
    r.rung = static_cast<int>(rung);
    r.iteration = ob.iteration;
    r.penalty = ob.penalty;
    r.beta = ob.beta;
    r.cg = ob.cg_iterations;
    r.mg = ob.cg_used_multigrid ? 1 : 0;
    r.hier = ob.cg_hier_built ? 1 : 0;
    r.cycles = ob.cg_mg_cycles_attempted;
    r.compliance = ob.compliance;
    r.change = ob.change;
    r.vf = ob.volume_fraction;
    p.trace.push_back(r);
    p.cg_total += ob.cg_iterations;
    ++p.iters_total;
    if (!ob.cg_used_multigrid && ob.cg_hier_built) ++p.stagnating_total;
    if (!ob.cg_hier_built) ++p.latched_total;
  };

  const auto t0 = std::chrono::steady_clock::now();
  const MinimizePlasticResult r =
      minimize_plastic(f.part, material, "fdm", f.bcs, rules, o);
  p.wall = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0)
               .count();

  for (std::size_t i = 0; i < r.evaluated.size(); ++i) {
    const MinimizePlasticVariant& v = r.evaluated[i];
    RungRow rr;
    rr.vf_requested = v.requested_volume_fraction;
    rr.vf_achieved = v.optimization.volume_fraction;
    rr.iterations = v.optimization.iterations;
    rr.compliance = v.optimization.compliance;
    rr.margin = v.report.margin.worst_case;
    rr.accepted = v.accepted ? 1 : 0;
    rr.infeasible = v.infeasible ? 1 : 0;
    rr.non_convergent = v.non_convergent ? 1 : 0;
    rr.min_feature = v.v3.min_feature_violations;
    rr.components = v.v3.mesh_components;
    rr.margin_effective = v.report.margin_effective;
    rr.reason = v.report.rejection_reason;
    for (const IterRow& t : p.trace)
      if (t.rung == static_cast<int>(i)) {
        rr.cg += t.cg;
        if (!t.mg && t.hier) ++rr.stagnating;
        if (!t.hier) ++rr.latched;
      }
    p.rungs.push_back(rr);
    if (i + 1 == r.evaluated.size()) p.density = v.optimization.physical_density;
  }
  return p;
}

void print_trace(const Posture& p) {
  std::printf("\n===== %s =====\n", p.label.c_str());
  std::printf(" rung iter |    p  | beta |    CG | carried | built | cycles |"
              " compliance\n");
  for (const IterRow& r : p.trace)
    std::printf(" %4d %4d | %5.2f | %4.1f | %5d |   %s    |   %s   | %6d | %.6g\n",
                r.rung, r.iteration, r.penalty, r.beta, r.cg,
                r.mg ? "MG" : "Jc", r.hier ? "Y" : "n", r.cycles, r.compliance);
}

void print_summary(const std::vector<Posture>& ps) {
  // AD2 + AD3: stagnation, iterations and wall, separately, per rung.
  std::printf("\n---- AD2/AD3: stagnation, iterations, CG and wall (per rung) ----\n");
  std::printf(" %-26s | rung |  vf  | iters | stagnating | latched |      CG\n",
              "posture");
  for (const Posture& p : ps) {
    for (std::size_t i = 0; i < p.rungs.size(); ++i) {
      const RungRow& r = p.rungs[i];
      std::printf(" %-26s | %4zu | %.2f | %5d | %10d | %7d | %7lld\n",
                  i == 0 ? p.label.c_str() : "", i, r.vf_requested, r.iterations,
                  r.stagnating, r.latched, r.cg);
    }
    std::printf(" %-26s | ALL  |      | %5lld | %10d | %7d | %7lld   wall %.1f s\n",
                "", p.iters_total, p.stagnating_total, p.latched_total,
                p.cg_total, p.wall);
  }

  // AD4 + AD5: the gate table, every rung, both verdict and margin, plus the
  // design quality numbers a verdict does not carry.
  std::printf("\n---- AD4/AD5: gate table (every evaluated rung) ----\n");
  std::printf(" %-26s | rung |  vf  | verdict |        margin |     margin_eff |"
              "    compliance | achieved vf | minfeat | comps | reason\n", "posture");
  for (const Posture& p : ps)
    for (std::size_t i = 0; i < p.rungs.size(); ++i) {
      const RungRow& r = p.rungs[i];
      std::printf(" %-26s | %4zu | %.2f | %-7s | %13.6g | %14.6g | %13.6g | %11.6f |"
                  " %7d | %5d | %s\n",
                  i == 0 ? p.label.c_str() : "", i, r.vf_requested, verdict(r),
                  r.margin, r.margin_effective, r.compliance, r.vf_achieved,
                  r.min_feature, r.components, r.reason.c_str());
    }

  // AD4's BLOCKED-STOP: any verdict flip against the OFF baseline.
  if (!ps.empty()) {
    const Posture& base = ps.front();
    std::printf("\n---- AD4 BLOCKED-STOP check: verdict flips vs the OFF baseline ----\n");
    for (std::size_t k = 1; k < ps.size(); ++k) {
      int flips = 0;
      const std::size_t n = std::min(base.rungs.size(), ps[k].rungs.size());
      for (std::size_t i = 0; i < n; ++i) {
        const RungRow& a = base.rungs[i];
        const RungRow& b = ps[k].rungs[i];
        if (a.accepted != b.accepted || a.infeasible != b.infeasible ||
            a.non_convergent != b.non_convergent) {
          ++flips;
          std::printf("   FLIP  rung %zu (vf %.2f): %s -> %s   [%s]\n", i,
                      a.vf_requested, verdict(a), verdict(b), ps[k].label.c_str());
        }
      }
      if (base.rungs.size() != ps[k].rungs.size())
        std::printf("   RUNG COUNT differs: OFF %zu -> %zu   [%s]\n",
                    base.rungs.size(), ps[k].rungs.size(), ps[k].label.c_str());
      std::printf("   %-26s verdict flips: %d\n", ps[k].label.c_str(), flips);
    }
  }

  // AD5: is the design better or worse? Compliance, summed over the rungs both
  // postures actually evaluated (lower is stiffer = better).
  if (!ps.empty()) {
    const Posture& base = ps.front();
    std::printf("\n---- AD5: final compliance per rung, OFF vs each schedule ----\n");
    for (std::size_t k = 1; k < ps.size(); ++k) {
      const std::size_t n = std::min(base.rungs.size(), ps[k].rungs.size());
      std::printf("   %s\n", ps[k].label.c_str());
      for (std::size_t i = 0; i < n; ++i) {
        const double a = base.rungs[i].compliance, b = ps[k].rungs[i].compliance;
        const double rel = (std::isfinite(a) && a != 0.0) ? (b - a) / a : 0.0;
        std::printf("     rung %zu vf %.2f : OFF %.6g -> ON %.6g  (%+.2f%%  %s)\n",
                    i, base.rungs[i].vf_requested, a, b, 100.0 * rel,
                    b < a ? "continuation WINS" : (b > a ? "OFF wins" : "tie"));
      }
    }
  }

  // AD6: when is each continuation active? A row-count of the (p, beta) pairs
  // actually observed, per posture — the overlap stated rather than assumed.
  std::printf("\n---- AD6: p-continuation vs beta-continuation overlap ----\n");
  for (const Posture& p : ps) {
    std::printf("   %s\n", p.label.c_str());
    int p_ramping_beta_off = 0, p_ramping_beta_on = 0;
    int p_held_beta_off = 0, p_held_beta_on = 0;
    double p_final = p.schedule.empty() ? 0.0 : p.schedule.back().penalty;
    for (const IterRow& r : p.trace) {
      const bool ramping = !p.schedule.empty() && r.penalty != p_final;
      const bool beta_on = r.beta > 0.0;
      if (ramping && !beta_on) ++p_ramping_beta_off;
      if (ramping && beta_on) ++p_ramping_beta_on;
      if (!ramping && !beta_on) ++p_held_beta_off;
      if (!ramping && beta_on) ++p_held_beta_on;
    }
    std::printf("     p RAMPING & beta off : %4d iterations\n", p_ramping_beta_off);
    std::printf("     p RAMPING & beta on  : %4d iterations   <- the OVERLAP\n",
                p_ramping_beta_on);
    std::printf("     p held    & beta off : %4d iterations\n", p_held_beta_off);
    std::printf("     p held    & beta on  : %4d iterations\n", p_held_beta_on);
  }
}

void write_csv(const std::vector<Posture>& ps, const std::string& dir) {
  {
    const std::string path = dir + "/iterations.csv";
    FILE* fp = std::fopen(path.c_str(), "w");
    if (!fp) { std::fprintf(stderr, "cannot write %s\n", path.c_str()); return; }
    std::fprintf(fp, "posture,rung,iter,penalty,beta,cg,carried_mg,hier_built,"
                     "cycles,compliance,change,achieved_vf\n");
    for (const Posture& p : ps)
      for (const IterRow& r : p.trace)
        std::fprintf(fp, "%s,%d,%d,%.4f,%.4f,%d,%d,%d,%d,%.12g,%.12g,%.9g\n",
                     p.label.c_str(), r.rung, r.iteration, r.penalty, r.beta,
                     r.cg, r.mg, r.hier, r.cycles, r.compliance, r.change, r.vf);
    std::fclose(fp);
    std::printf("\nwrote %s\n", path.c_str());
  }
  {
    const std::string path = dir + "/rungs.csv";
    FILE* fp = std::fopen(path.c_str(), "w");
    if (!fp) { std::fprintf(stderr, "cannot write %s\n", path.c_str()); return; }
    std::fprintf(fp, "posture,rung,vf_requested,verdict,margin,margin_effective,"
                     "compliance,achieved_vf,iterations,stagnating,latched,cg,"
                     "min_feature_violations,mesh_components,wall_s_run,reason\n");
    for (const Posture& p : ps)
      for (std::size_t i = 0; i < p.rungs.size(); ++i) {
        const RungRow& r = p.rungs[i];
        std::fprintf(fp,
                     "%s,%zu,%.4f,%s,%.12g,%.12g,%.12g,%.9g,%d,%d,%d,%lld,%d,%d,%.3f,%s\n",
                     p.label.c_str(), i, r.vf_requested, verdict(r), r.margin,
                     r.margin_effective, r.compliance, r.vf_achieved,
                     r.iterations, r.stagnating, r.latched, r.cg, r.min_feature,
                     r.components, p.wall, r.reason.c_str());
      }
    std::fclose(fp);
    std::printf("wrote %s\n", path.c_str());
  }
}

}  // namespace

int main(int argc, char** argv) {
  std::setvbuf(stdout, nullptr, _IOLBF, 0);
  const int iters = argc > 1 ? std::atoi(argv[1]) : 16;
  const std::string csv_dir = argc > 2 ? argv[2] : "";
  const bool small = std::getenv("PC_SMALL") != nullptr;
  const bool trace = std::getenv("PC_TRACE") != nullptr;
  const char* only = std::getenv("PC_ONLY");  // run one posture by label prefix

  SettingsRules rules;
  try {
    rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "rules: %s\n", e.what());
    return 1;
  }
  const Material material = fdm();
  const char* pad_env = std::getenv("PC_PAD");
  const double pad_scale = pad_env ? std::atof(pad_env) : 1.0;
  const Fixture f = small ? make_small_stagnation() : make_big_stagnation(pad_scale);
  // The ladder. PC_LADDER overrides it (comma-separated, strictly descending) so
  // a scouting run can find a ladder whose rungs all produce a CONNECTED design
  // on this fixture — a gate table built on severed rungs compares nothing.
  std::vector<double> ladder = {0.68, 0.52, 0.38};
  if (const char* lad = std::getenv("PC_LADDER")) {
    ladder.clear();
    std::string t(lad), cur;
    for (char ch : t + ",") {
      if (ch == ',') { if (!cur.empty()) ladder.push_back(std::atof(cur.c_str())); cur.clear(); }
      else cur.push_back(ch);
    }
  }

  std::printf("SIMP penalization-continuation probe — %s stagnation fixture, "
              "%d-iteration rung budget, margin_stop 1.5, ladder",
              small ? "small" : "big", iters);
  for (double v : ladder) std::printf(" %.2f", v);
  std::printf("\n");
  std::printf("part %dx%dx%d @ %.2f mm; design box [%.1f %.1f %.1f]-[%.1f %.1f %.1f] "
              "(pad scale %.2f) gives the dilute regime the V-cycle stagnates on.\n",
              f.part.nx, f.part.ny, f.part.nz, f.part.spacing, f.box.min.x,
              f.box.min.y, f.box.min.z, f.box.max.x, f.box.max.y, f.box.max.z,
              pad_scale);
  std::printf("EXPECTED, stated before the numbers: with p ramped from 1, the "
              "early high-contrast solves are softer, so the multigrid V-cycle "
              "should carry MORE early iterations -> FEWER stagnating iterations "
              "and (if the CG saved exceeds the ramp's cost) less wall. The "
              "design WILL differ; the certified compliance is the test of "
              "whether it is better.\n");

  // The postures. S1/S2 are the published schedules; S3 is Amir & Sigmund's
  // stated 1.0 -> 3.0 ramp instantiated at a dwell that FITS this project's rung
  // budget (they publish no dwell); S4 is this task's own, justified in the
  // handoff by the MEASURED stagnation window.
  // NOTE: labels are written verbatim into the CSV `posture` column, so they must
  // stay COMMA-FREE — a comma here silently shifts every later column.
  struct Spec { const char* label; std::vector<PenaltyStage> sched; };
  std::vector<Spec> specs = {
      {"S0 OFF (shipped p=3)", {}},
      {"S1 Peetz literal 20it-per-val", penalty_continuation_peetz()},
      {"S2 Peetz values 1it-per-val", penalty_continuation_ramp(1.0, 4.0, 0.25, 1)},
      {"S3 Amir-Sigmund 1to3 1it-per-val",
       penalty_continuation_ramp(1.0, 3.0, 0.25, 1)},
      {"S4 stagnation-window 1to3",
       penalty_continuation_ramp(1.0, 3.0, 0.5, 2)},
  };

  std::vector<Posture> ps;
  for (const Spec& s : specs) {
    if (only && std::string(s.label).rfind(only, 0) != 0) continue;
    std::printf("\n### %s — schedule:", s.label);
    if (s.sched.empty()) std::printf(" (empty = OFF, constant p = 3)\n");
    else {
      for (const PenaltyStage& st : s.sched)
        std::printf(" %.2fx%d", st.penalty, st.iterations);
      std::printf("  (last value HELD past the end)\n");
    }
    ps.push_back(run_posture(s.label, s.sched, f, iters, ladder, rules, material));
    if (trace) print_trace(ps.back());
  }

  print_summary(ps);
  if (!csv_dir.empty()) write_csv(ps, csv_dir);
  return 0;
}
