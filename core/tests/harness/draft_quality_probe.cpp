// draft_quality_probe.cpp — measurement harness (NOT a CI test) for the DRAFT
// QUALITY posture (handoff 2026-07-25-draft-quality; MinimizePlasticOptions::
// draft_quality). It is the decision instrument for the approximate-trajectory /
// exact-certification flip: loose early trajectory solves (a), progressive
// tightening over the last k (b), one exact certification (c), and AUTO-ESCALATION
// when the certified result diverges (d).
//
// It builds its grids PROGRAMMATICALLY (fixtures/ is maintainer-only and untouched),
// the sanctioned pattern cg_tol_probe established. Everything it measures is
// DETERMINISTIC — CG-iteration counts, |Δρ|, classification flips, gate verdicts
// (verified: a repeated run reproduces the terminal design bit-for-bit) — so each
// configuration runs ONCE; wall-clock is thermally contaminated (113) and reported
// only as corroboration. Build (standalone; NOT wired into CTest):
//   c++ -std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 \
//     -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" \
//     core/tests/harness/draft_quality_probe.cpp build/libtopopt.a -o build/draft_quality_probe
//
// Sections, each a stated BAR scored honestly:
//   B3 NOISE FLOOR   tight@1e-8 vs tight@1e-9 (benign perturbation, both far tighter
//                    than discretization) — the basin-noise floor every design-diff
//                    number is reported as a MULTIPLE of.
//   B5 THE WIN       draft vs tight summed trajectory CG on a STAGNATING grid
//                    (hier_built=1, cg_multigrid=0, thousands of CG). Bar: >= 2x.
//   B6 NO REGRESSION draft vs tight on a HEALTHY multigrid grid — no rung's CG rises.
//   B4 THE BELT      draft genuinely diverges; escalation fires and RECOVERS the
//                    certified-correct (tight) design.
//   GAP SEPARATION   does the certified-vs-trajectory compliance gap separate
//                    diverged rungs from converged ones? (the one thing that could
//                    derail the trigger.)
//
// Per-iteration regime CSV (B7: hier_built, cg_multigrid, mg_mode, traj_tol) is
// written to $TOPOPT_DRAFT_CSV_DIR when set.

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/production.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {

constexpr double kIso = 0.5;

// The thin L-bracket cg_tol_probe / the ladder gates build.
VoxelGrid l_bracket(std::vector<DirichletBC>& bcs, int arm, int span, int ny,
                    int t, double h) {
  VoxelGrid g;
  g.nx = span; g.ny = ny; g.nz = arm; g.spacing = h;
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
        if (!solid(i-1,j,k)||!solid(i+1,j,k)||!solid(i,j-1,k)||!solid(i,j+1,k)||
            !solid(i,j,k-1)||!solid(i,j,k+1))
          g.set_tag(i, j, k, VoxelTag::Surface);
      }
  for (int j = 0; j < ny; ++j)
    for (int i = 0; i < t; ++i) g.set_tag(i, j, arm - 1, VoxelTag::Fixture);
  bcs.clear();
  for (int b = 0; b <= ny; ++b)
    for (int a = 0; a <= t; ++a) {
      const int node = fea_node_index(g, a, b, arm);
      bcs.push_back({node, 0, 0.0});
      bcs.push_back({node, 1, 0.0});
      bcs.push_back({node, 2, 0.0});
    }
  for (int k = 0; k < t; ++k)
    for (int j = 0; j < ny; ++j) g.set_tag(span - 1, j, k, VoxelTag::Load);
  return g;
}

Material fdm_material() {
  Material m;
  m.youngs_modulus_mpa = 3500.0; m.yield_strength_mpa = 55.0;
  m.density_g_cm3 = 1.24; m.z_knockdown = 0.55; m.poisson = 0.33; m.family = "fdm";
  return m;
}

double mean_abs_diff(const std::vector<double>& a, const std::vector<double>& b) {
  if (a.size() != b.size() || a.empty()) return -1.0;
  double s = 0.0;
  for (std::size_t i = 0; i < a.size(); ++i) s += std::fabs(a[i] - b[i]);
  return s / static_cast<double>(a.size());
}
double max_abs_diff(const std::vector<double>& a, const std::vector<double>& b) {
  if (a.size() != b.size() || a.empty()) return -1.0;
  double m = 0.0;
  for (std::size_t i = 0; i < a.size(); ++i) m = std::max(m, std::fabs(a[i] - b[i]));
  return m;
}
// B8 metric: the number of voxels that CHANGE printed<->void classification (iso
// 0.5) between two designs, and the reference design's printed-voxel count (the
// "solid-voxel count" the flips are a fraction of). Scale travels with the number.
struct ClassDiff { long long flips = 0; long long ref_solid = 0; double frac = 0.0; };
ClassDiff class_diff(const std::vector<double>& ref, const std::vector<double>& b) {
  ClassDiff d;
  if (ref.size() != b.size() || ref.empty()) return d;
  for (std::size_t i = 0; i < ref.size(); ++i) {
    const bool ra = ref[i] > kIso, rb = b[i] > kIso;
    if (ra) ++d.ref_solid;
    if (ra != rb) ++d.flips;
  }
  d.frac = d.ref_solid > 0 ? double(d.flips) / double(d.ref_solid) : 0.0;
  return d;
}

const char* mg_mode(bool used_mg, bool built) {
  if (used_mg) return "carried";
  return built ? "stagnated" : "build-rejected";
}

// One rung's captured outcome.
struct RungOut {
  double vf = 0.0;
  int iters = 0;
  long long cg = 0;          // summed trajectory CG (this run's on_iteration rows)
  double achieved = 0.0;
  double margin = 0.0;
  double compliance = 0.0;   // certified (tight final solve)
  bool accepted = false;
  int stag_iters = 0;        // iterations this rung ran with cg_multigrid=0 & built
  int mg_iters = 0;          // iterations with cg_multigrid=1
  long long stag_cg = 0;     // CG spent in stagnated iterations
  std::vector<double> density;
  // draft outcome (empty/sentinel unless draft armed)
  int tail_k = -1;
  double gap = -1.0;
  int escalated = 0;
};

struct RunOut {
  std::vector<RungOut> rungs;
  std::vector<double> terminal_density;
  long long total_cg = 0;
  int total_iters = 0;
  double wall_s = 0.0;
};

struct RunCfg {
  double cg_tol = 1e-8;       // certification tolerance (noise-floor perturbation)
  bool draft = false;
  double loose_tol = 1e-3;
  double esc_gap = 1e30;      // default: never escalate (pure loose measurement)
  const char* csv_name = nullptr;  // per-iteration CSV sink (optional)
};

FILE* open_csv(const char* name) {
  const char* dir = std::getenv("TOPOPT_DRAFT_CSV_DIR");
  if (!dir || !name) return nullptr;
  const std::string path = std::string(dir) + "/" + name;
  FILE* f = std::fopen(path.c_str(), "w");
  if (f)
    std::fprintf(f, "rung,iter,cg_iters,cg_multigrid,hier_built,mg_mode,traj_tol,"
                    "compliance,change,achieved_vf\n");
  return f;
}

// Run one full ladder under `cfg` on the given part/box, capturing per-rung and
// per-iteration data. margin_stop=0 forces the WHOLE ladder to run (the dilute
// stagnating rungs live at the bottom).
RunOut run(const RunCfg& cfg, const VoxelGrid& part,
           const std::vector<DirichletBC>& bcs,
           const std::vector<NodalLoad>& loads, const SettingsRules& rules,
           const Material& material, bool with_box, const DesignBox& box,
           const std::vector<double>& ladder) {
  MinimizePlasticOptions o;
  configure_production_options(o);
  o.volume_fraction_ladder = ladder;
  o.margin_stop = 0.0;                 // run every rung; the win lives at the bottom
  o.external_loads = loads;
  o.gravity = 9810.0 * 1e-9;
  o.gravity_direction = Vec3{0.0, 0.0, -1.0};
  o.infill_percent = 100.0;
  if (with_box) o.design_box = box;
  o.simp.cg_tolerance = cfg.cg_tol;
  o.draft_quality = cfg.draft;
  o.draft_loose_tol = cfg.loose_tol;
  o.draft_escalation_c_gap = cfg.esc_gap;

  RunOut out;
  std::vector<long long> cg_per_rung, stagcg_per_rung;
  std::vector<int> stag_per_rung, mg_per_rung, iters_per_rung;
  FILE* csv = open_csv(cfg.csv_name);
  o.on_iteration = [&](std::size_t rung, std::size_t, const SimpIterationObservation& ob) {
    auto grow = [&](auto& v){ if (rung >= v.size()) v.resize(rung + 1, 0); };
    grow(cg_per_rung); grow(stagcg_per_rung); grow(stag_per_rung);
    grow(mg_per_rung); grow(iters_per_rung);
    cg_per_rung[rung] += ob.cg_iterations;
    ++iters_per_rung[rung];
    const bool stag = !ob.cg_used_multigrid && ob.cg_hier_built;
    if (ob.cg_used_multigrid) ++mg_per_rung[rung];
    if (stag) { ++stag_per_rung[rung]; stagcg_per_rung[rung] += ob.cg_iterations; }
    if (csv)
      std::fprintf(csv, "%zu,%d,%d,%d,%d,%s,%.3e,%.10g,%.6g,%.6f\n", rung,
                   ob.iteration, ob.cg_iterations, ob.cg_used_multigrid ? 1 : 0,
                   ob.cg_hier_built ? 1 : 0,
                   mg_mode(ob.cg_used_multigrid, ob.cg_hier_built),
                   ob.cg_trajectory_tol, ob.compliance, ob.change,
                   ob.volume_fraction);
  };

  const auto t0 = std::chrono::steady_clock::now();
  const MinimizePlasticResult r =
      minimize_plastic(part, material, "fdm", bcs, rules, o);
  const auto t1 = std::chrono::steady_clock::now();
  out.wall_s = std::chrono::duration<double>(t1 - t0).count();
  if (csv) std::fclose(csv);

  for (std::size_t i = 0; i < r.evaluated.size(); ++i) {
    const auto& v = r.evaluated[i];
    RungOut row;
    row.vf = v.requested_volume_fraction;
    row.iters = i < iters_per_rung.size() ? iters_per_rung[i] : 0;
    row.cg = i < cg_per_rung.size() ? cg_per_rung[i] : 0;
    row.stag_iters = i < stag_per_rung.size() ? stag_per_rung[i] : 0;
    row.mg_iters = i < mg_per_rung.size() ? mg_per_rung[i] : 0;
    row.stag_cg = i < stagcg_per_rung.size() ? stagcg_per_rung[i] : 0;
    row.achieved = v.optimization.volume_fraction;
    row.margin = v.report.margin.worst_case;
    row.compliance = v.optimization.compliance;
    row.accepted = v.accepted;
    row.density = v.optimization.physical_density;
    if (i < r.draft_rung_tail_k.size()) row.tail_k = r.draft_rung_tail_k[i];
    if (i < r.draft_rung_c_gap.size()) row.gap = r.draft_rung_c_gap[i];
    if (i < r.draft_rung_escalated.size()) row.escalated = r.draft_rung_escalated[i];
    out.total_cg += row.cg;
    out.total_iters += row.iters;
    out.rungs.push_back(std::move(row));
  }
  if (!r.evaluated.empty())
    out.terminal_density = r.evaluated.back().optimization.physical_density;
  return out;
}

void print_rungs(const char* tag, const RunOut& m) {
  std::printf("[%s] rungs=%zu total_iters=%d total_traj_cg=%lld wall=%.2fs\n",
              tag, m.rungs.size(), m.total_iters, m.total_cg, m.wall_s);
  for (const RungOut& r : m.rungs)
    std::printf("    vf=%.2f iters=%3d cg=%7lld stag=%d/%d stagCG=%lld achieved=%.4f "
                "margin=%.3f C=%.6g %s%s\n",
                r.vf, r.iters, r.cg, r.stag_iters, r.iters, r.stag_cg, r.achieved,
                r.margin, r.compliance, r.accepted ? "accept" : "REJECT",
                r.escalated ? " [ESCALATED]" : "");
}

}  // namespace

int main() {
  SettingsRules rules;
  try { rules = load_settings_rules_file(SETTINGS_RULES_PATH); }
  catch (const std::exception& e) {
    std::fprintf(stderr, "FAIL rules.json: %s\n", e.what()); return 1;
  }
  const Material material = fdm_material();
  const DesignBox no_box{};
  const double h = 2.0;

  // ---- Stagnation grid S: whole-domain box (2x) around the 8x3x8 L-bracket, a
  // dilute ladder that reaches the cg_multigrid=0 / hier_built=1 grind. -------
  const int Sa = 8, Ss = 8, Sny = 3, St = 2;
  std::vector<DirichletBC> Sbcs;
  VoxelGrid Spart = l_bracket(Sbcs, Sa, Ss, Sny, St, h);
  const std::vector<NodalLoad> Sload =
      traction_loads(Spart, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});
  DesignBox Sbox; Sbox.min = Vec3{0,0,0};
  Sbox.max = Vec3{Ss*h*2.0, Sny*h*2.0, Sa*h*2.0};
  const std::vector<double> Sladder = {0.50, 0.35, 0.24, 0.16};

  // ---- Healthy grid H: no box, MG carries every solve (B6). -----------------
  const int Ha = 32, Hs = 32, Hny = 12, Ht = 8;
  std::vector<DirichletBC> Hbcs;
  VoxelGrid Hpart = l_bracket(Hbcs, Ha, Hs, Hny, Ht, h);
  const std::vector<NodalLoad> Hload =
      traction_loads(Hpart, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});
  const std::vector<double> Hladder = production_reduction_ladder();

  auto stag_run = [&](const RunCfg& c){ return run(c, Spart, Sbcs, Sload, rules, material, true, Sbox, Sladder); };
  auto heal_run = [&](const RunCfg& c){ return run(c, Hpart, Hbcs, Hload, rules, material, false, no_box, Hladder); };

  // =====================================================================
  // B3 — NOISE FLOOR: tight@1e-8 vs tight@1e-9 on grid S. Both far tighter than
  // discretization, so any design difference between them is BASIN NOISE. Every
  // draft-vs-tight number below is reported as a MULTIPLE of this floor.
  // =====================================================================
  std::printf("\n########## B3 NOISE FLOOR (grid S, tight 1e-8 vs 1e-9) ##########\n");
  RunCfg c_tight8; c_tight8.cg_tol = 1e-8; c_tight8.csv_name = "S_tight_1e8.csv";
  RunCfg c_tight9; c_tight9.cg_tol = 1e-9;
  RunOut S8 = stag_run(c_tight8);
  RunOut S9 = stag_run(c_tight9);
  print_rungs("tight 1e-8", S8);
  print_rungs("tight 1e-9", S9);
  double noise_floor = 0.0, noise_mean = 0.0;
  {
    const std::size_t n = std::min(S8.rungs.size(), S9.rungs.size());
    std::printf("  per-rung basin noise (1e-8 vs 1e-9):\n");
    for (std::size_t i = 0; i < n; ++i) {
      ClassDiff d = class_diff(S8.rungs[i].density, S9.rungs[i].density);
      double md = mean_abs_diff(S8.rungs[i].density, S9.rungs[i].density);
      std::printf("    vf=%.2f  flips=%lld / %lld solid = %.4f  (mean|drho|=%.5f)\n",
                  S8.rungs[i].vf, d.flips, d.ref_solid, d.frac, md);
      noise_floor = std::max(noise_floor, d.frac);
      noise_mean = std::max(noise_mean, md);
    }
  }
  if (noise_floor <= 0.0) noise_floor = 1e-9;  // avoid divide-by-zero in multiples
  std::printf("  >> NOISE FLOOR = %.4f (classification-flip fraction), mean|drho| floor = %.5f\n",
              noise_floor, noise_mean);

  // =====================================================================
  // B5 — THE WIN: draft (loose 1e-3, escalation OFF) vs tight, on grid S. The
  // headline is the summed-trajectory-CG RATIO. Grid S is proven stagnating below
  // (stag>0 rungs). B8: design diff reported as flip-fraction AND multiples of the
  // noise floor, with dims + solid count. B6-partner: name any rung whose CG rises.
  // =====================================================================
  MinimizePlasticOptions Sdims_opt; Sdims_opt.design_box = Sbox;
  const VoxelGrid Sgrid = minimize_plastic_solved_grid(Spart, Sdims_opt);
  std::printf("\n########## B5 THE WIN (grid S solved=%dx%dx%d, %zu vox) ##########\n",
              Sgrid.nx, Sgrid.ny, Sgrid.nz, Sgrid.voxel_count());
  RunCfg c_draft; c_draft.draft = true; c_draft.loose_tol = 1e-3; c_draft.esc_gap = 1e30;
  c_draft.csv_name = "S_draft_noesc.csv";
  RunOut Sd = stag_run(c_draft);
  print_rungs("tight (draft off)", S8);
  print_rungs("draft loose=1e-3 (escalation OFF)", Sd);
  {
    const double ratio = Sd.total_cg > 0 ? double(S8.total_cg)/double(Sd.total_cg) : 0.0;
    std::printf("  >> summed trajectory CG: tight=%lld draft=%lld  RATIO=%.2fx  (bar: >= 2.0x)\n",
                S8.total_cg, Sd.total_cg, ratio);
    std::printf("  per-rung CG (tight -> draft), design diff vs tight, gap, tail_k:\n");
    const std::size_t n = std::min(S8.rungs.size(), Sd.rungs.size());
    int rose = 0;
    for (std::size_t i = 0; i < n; ++i) {
      ClassDiff d = class_diff(S8.rungs[i].density, Sd.rungs[i].density);
      double md = mean_abs_diff(S8.rungs[i].density, Sd.rungs[i].density);
      const double rr = Sd.rungs[i].cg>0 ? double(S8.rungs[i].cg)/double(Sd.rungs[i].cg) : 0.0;
      const bool up = Sd.rungs[i].cg > S8.rungs[i].cg;
      if (up) ++rose;
      std::printf("    vf=%.2f  cg %7lld -> %7lld (%.2fx)%s  flips=%.4f (%.1fx floor) mean|drho|=%.5f  gap=%.4f tail_k=%d\n",
                  S8.rungs[i].vf, S8.rungs[i].cg, Sd.rungs[i].cg, rr,
                  up ? " RISES" : "", d.frac, d.frac/noise_floor, md,
                  Sd.rungs[i].gap, Sd.rungs[i].tail_k);
    }
    std::printf("  rungs whose CG ROSE under draft: %d (B6-partner: name them above)\n", rose);
  }

  // =====================================================================
  // B6 — NO REGRESSION on a HEALTHY multigrid grid H. Draft must not increase CG.
  // =====================================================================
  std::printf("\n########## B6 NO REGRESSION (healthy grid H) ##########\n");
  RunCfg h_tight; h_tight.csv_name = "H_tight.csv";
  RunCfg h_draft; h_draft.draft = true; h_draft.loose_tol = 1e-3; h_draft.esc_gap = 1e30;
  h_draft.csv_name = "H_draft.csv";
  RunOut H8 = heal_run(h_tight);
  RunOut Hd = heal_run(h_draft);
  print_rungs("tight", H8);
  print_rungs("draft loose=1e-3 (esc off)", Hd);
  {
    const std::size_t n = std::min(H8.rungs.size(), Hd.rungs.size());
    int rose = 0;
    std::printf("  per-rung CG (tight -> draft):\n");
    for (std::size_t i = 0; i < n; ++i) {
      const bool up = Hd.rungs[i].cg > H8.rungs[i].cg;
      if (up) ++rose;
      std::printf("    vf=%.2f  cg %7lld -> %7lld  stag=%d/%d%s\n", H8.rungs[i].vf,
                  H8.rungs[i].cg, Hd.rungs[i].cg, Hd.rungs[i].stag_iters,
                  Hd.rungs[i].iters, up ? "  RISES" : "");
    }
    std::printf("  >> rungs that ROSE: %d (bar: 0, and name any)\n", rose);
  }

  // =====================================================================
  // B4 — THE BELT: on grid S the loose trajectory genuinely DIVERGES (shown in B5).
  // Turn escalation ON at a threshold at/above the noise floor's gap and show it
  // FIRES on the diverging rungs and RECOVERS the tight design (flips vs tight
  // collapse toward the noise floor). Threshold picked from the measured gaps.
  // =====================================================================
  std::printf("\n########## B4 THE BELT (grid S, escalation ON) ##########\n");
  // Pick the belt threshold as the midpoint between the noise-floor gap and the
  // diverged gap, derived from the B5 draft run's per-rung gaps (not hand-tuned).
  double gap_min = 1e30, gap_max = 0.0;
  for (const RungOut& r : Sd.rungs)
    if (r.gap >= 0) { gap_min = std::min(gap_min, r.gap); gap_max = std::max(gap_max, r.gap); }
  const double belt_thr = (gap_min < 1e29) ? 0.5 * (gap_min + gap_max) : 0.01;
  std::printf("  measured draft gaps: min=%.4f max=%.4f -> belt threshold=%.4f\n",
              gap_min < 1e29 ? gap_min : -1.0, gap_max, belt_thr);
  RunCfg c_belt; c_belt.draft = true; c_belt.loose_tol = 1e-3; c_belt.esc_gap = belt_thr;
  c_belt.csv_name = "S_draft_esc.csv";
  RunOut Sb = stag_run(c_belt);
  print_rungs("draft loose=1e-3 (escalation ON)", Sb);
  {
    const std::size_t n = std::min(S8.rungs.size(), Sb.rungs.size());
    std::printf("  per-rung: escalated?  design diff vs tight (draft-noesc -> draft-esc):\n");
    long long net_cg = 0;
    for (std::size_t i = 0; i < n; ++i) {
      ClassDiff dn = class_diff(S8.rungs[i].density, Sd.rungs[i].density);   // no-esc vs tight
      ClassDiff de = class_diff(S8.rungs[i].density, Sb.rungs[i].density);   // esc vs tight
      std::printf("    vf=%.2f  gap=%.4f %s  flips-vs-tight: noesc=%.4f (%.1fx) -> esc=%.4f (%.1fx)\n",
                  S8.rungs[i].vf, Sb.rungs[i].gap,
                  Sb.rungs[i].escalated ? "ESCALATED" : "trusted",
                  dn.frac, dn.frac/noise_floor, de.frac, de.frac/noise_floor);
      // Net-of-escalation win accounting: escalated rungs cost the TIGHT rung's CG
      // (re-run from the same uniform seed, warm-start off), trusted rungs keep the
      // draft CG. (draft-esc's on_iteration CG excludes the re-run, so substitute.)
      net_cg += Sb.rungs[i].escalated ? S8.rungs[i].cg : Sd.rungs[i].cg;
    }
    const double net_ratio = net_cg > 0 ? double(S8.total_cg)/double(net_cg) : 0.0;
    std::printf("  >> NET-of-escalation win at belt threshold: tight=%lld net=%lld RATIO=%.2fx\n",
                S8.total_cg, net_cg, net_ratio);
    // Recovery check: the escalated design must match the tight design to the floor.
    ClassDiff term = class_diff(S8.terminal_density, Sb.terminal_density);
    std::printf("  >> terminal design (draft-esc vs tight): flips=%.4f (%.1fx floor)  [recovered if ~1x]\n",
                term.frac, term.frac/noise_floor);
  }

  // =====================================================================
  // GAP SEPARATION — the one thing that could derail the trigger. Tabulate, per
  // rung, (design flip-fraction vs tight) against (certified-vs-trajectory gap).
  // If a large gap tracks a large design difference and a small gap a small one,
  // the trigger separates. If not, ship the conservative posture (threshold at the
  // noise floor / final-rung), stated in the handoff.
  // =====================================================================
  std::printf("\n########## GAP SEPARATION (grid S, draft rungs) ##########\n");
  std::printf("  rung | gap (C_cert vs C_traj) | flip-frac vs tight | multiples of floor\n");
  for (std::size_t i = 0; i < Sd.rungs.size(); ++i) {
    ClassDiff d = class_diff(S8.rungs[i].density, Sd.rungs[i].density);
    std::printf("   %2zu  |   %.4f   |   %.4f   |  %.1fx\n", i, Sd.rungs[i].gap,
                d.frac, d.frac/noise_floor);
  }

  std::printf("\n########## DONE ##########\n");
  return 0;
}
