// test_nonconvergence_rejection — handoff 2026-07-27-nonconvergence-rejection.
//
// A linear solve that fails to converge (CG reaches its iteration cap without
// meeting the requested relative-residual tolerance) used to THROW out of
// simp_optimize / analyze_fixed_design and destroy the ENTIRE minimize_plastic
// run — including rungs that had already passed the gate and produced exportable
// variants. This suite proves the fix: non-convergence rejects the RUNG, not the
// run.
//
// The bars it pins (BARS N1–N5 of the handoff):
//   N1  Byte-identical on every run that does not hit non-convergence — shown here
//       as INERTNESS (a healthy run has an all-false non_convergent surface and
//       behaves as a normal ladder); the byte-identity at large is the unchanged
//       pre-existing suite (production_parity, rung_infeasible, minimize_plastic,
//       analyze_fixed_design, simp, warm_start*) which all still pass.
//   N2  The certification solve is NEVER softened, and this change cannot certify a
//       part on a solve that failed to converge — proven by feeding ONE fixed
//       density to analyze_fixed_design twice: a starved cap rejects it
//       (non_convergent, accepted==false); a generous cap CERTIFIES the identical
//       field at the identical tolerance (accepted==true). The tolerance never
//       changed; only convergence did.
//   N3  Warm-start inheritance across a rejected rung still obeys handoff 131's
//       rule — the rung AFTER a trajectory-non-convergent rung inherits the SAME
//       seed it would have inherited had the failing rung not run (bit-for-bit).
//   N4  It FIRES: a genuinely non-converging rung is rejected, the run COMPLETES,
//       and a previously-accepted variant is still present and EXPORTABLE (written
//       to disk as an STL and read back).
//   N5  The rejection is DISTINGUISHABLE from "solved and failed the gate": a
//       distinct rejection_reason string, and the assembled report still validates.
//
// Deterministic construction of a genuine non-convergence: the CG cap. On the
// 24×5×6 cantilever a cold solve of a dense field converges in ~300 CG iterations,
// while a sparse/near-severed field is near-singular and needs thousands (measured:
// docs/handoffs/evidence/2026-07-27-nonconvergence-rejection/). A cap of 800 sits
// comfortably between: the heavy rung converges and accepts, the light rung's very
// first (near-singular) solve runs to the cap and is rejected. No wall clock, no
// randomness — a function of the operator's conditioning alone.

#include <cassert>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#include "topopt/analyze.hpp"
#include "topopt/fea.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/report.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/stl.hpp"
#include "topopt/voxel.hpp"

using topopt::analyze_fixed_design;
using topopt::DirichletBC;
using topopt::FixedDesignAnalysis;
using topopt::KnockdownSpec;
using topopt::Material;
using topopt::MinimizePlasticOptions;
using topopt::MinimizePlasticResult;
using topopt::MinimizePlasticVariant;
using topopt::NodalLoad;
using topopt::SettingsRules;
using topopt::SimpCompliance;
using topopt::SimpOptimizeResult;
using topopt::SimpParams;
using topopt::SimpUpdater;
using topopt::SolverKind;
using topopt::SolverNonConvergence;
using topopt::Vec3;
using topopt::VoxelGrid;
using topopt::VoxelTag;

namespace {

int g_checks = 0;
int g_failures = 0;

void check(bool ok, const std::string& what) {
  ++g_checks;
  if (!ok) {
    ++g_failures;
    std::printf("  FAIL: %s\n", what.c_str());
  }
}

// The same fixture handoff 131 used: a fixed cantilever whose two ends are the
// Fixture (anchor) and the Load, with the design region between them the only load
// path. Small (24×5×6) on purpose.
VoxelGrid cantilever_bar(std::vector<DirichletBC>& bcs) {
  const int nx = 24, ny = 5, nz = 6;
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = 2.0;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j) {
      g.set_tag(0, j, k, VoxelTag::Fixture);
      g.set_tag(nx - 1, j, k, VoxelTag::Load);
    }
  bcs.clear();
  for (int c = 0; c <= nz; ++c)
    for (int b = 0; b <= ny; ++b) {
      const int n = topopt::fea_node_index(g, 0, b, c);
      bcs.push_back({n, 0, 0.0});
      bcs.push_back({n, 1, 0.0});
      bcs.push_back({n, 2, 0.0});
    }
  return g;
}

Material fdm_material() {
  Material m;
  m.youngs_modulus_mpa = 3500.0;
  m.yield_strength_mpa = 55.0;
  m.density_g_cm3 = 1.24;
  m.z_knockdown = 0.55;
  m.poisson = 0.33;
  m.family = "fdm";
  return m;
}

std::vector<NodalLoad> tip_loads(const VoxelGrid& g) {
  std::vector<NodalLoad> loads;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      loads.push_back({topopt::fea_node_index(g, g.nx, j, k), 2, -50.0});
  return loads;
}

// margin_stop = 0 accepts every rung that is analysed (so nothing but the failure
// being tested ends the ladder), infeasibility DISARMED (window 0) so the ONLY way
// a rung is rejected here is non-convergence — the signal under test in isolation.
MinimizePlasticOptions base_options(const VoxelGrid& g) {
  MinimizePlasticOptions o;
  o.margin_stop = 0.0;
  o.gravity = 9810.0;
  o.gravity_direction = Vec3{0, 0, -1};
  o.warm_start_inherit = true;
  o.updater = SimpUpdater::MMA;
  o.simp.filter_radius = 1.5;
  o.simp.move = 0.2;
  o.simp.max_iterations = 40;
  o.simp.change_tol = 0.0;
  o.simp.cg_tolerance = 1e-8;
  o.simp.infeasible_window = 0;  // isolate non-convergence from infeasibility
  o.external_loads = tip_loads(g);
  return o;
}

SimpParams cantilever_params() {
  SimpParams p;
  p.youngs_modulus = 3500.0;
  p.poisson = 0.33;
  p.penalty = 3.0;
  p.density_min = 1e-3;
  return p;
}

// ---------------------------------------------------------------------------
// GROUP 1 — the mechanism fires at every layer (deterministic, starved cap).
// ---------------------------------------------------------------------------
void group1_layers() {
  std::printf("[group 1] mechanism fires at each layer\n");
  std::vector<DirichletBC> bcs;
  const VoxelGrid g = cantilever_bar(bcs);
  const SimpParams params = cantilever_params();
  const std::vector<NodalLoad> loads = tip_loads(g);
  const std::size_t n = g.voxel_count();
  std::vector<double> dense(n, 0.6);

  // 1a — the SOLVER throws SolverNonConvergence (a distinct type, NOT a bare
  // runtime_error), carrying the iteration and residual a rejection needs.
  bool threw = false;
  try {
    simp_compliance(g, params, dense, bcs, loads, 1e-12, /*cap=*/1, nullptr,
                    nullptr, SolverKind::JacobiCG);
  } catch (const SolverNonConvergence& e) {
    threw = true;
    check(e.iterations >= 1, "1a: exception carries a positive iteration count");
    check(std::isfinite(e.residual) && e.residual > 1e-12,
          "1a: exception carries a residual above the requested tolerance");
    check(std::string(e.what()).find("did not reach the requested tolerance") !=
              std::string::npos,
          "1a: what() is the identical non-convergence message");
  }
  check(threw, "1a: a starved CG solve throws SolverNonConvergence");
  // It IS-A std::runtime_error, so old catch sites keep working byte-for-byte.
  bool caught_as_runtime = false;
  try {
    simp_compliance(g, params, dense, bcs, loads, 1e-12, 1, nullptr, nullptr,
                    SolverKind::JacobiCG);
  } catch (const std::runtime_error&) {
    caught_as_runtime = true;
  }
  check(caught_as_runtime,
        "1a: SolverNonConvergence is still catchable as std::runtime_error");

  // 1b — simp_optimize does NOT throw on a trajectory non-convergence; it RETURNS
  // with non_convergent set, converged false, and the numbers populated.
  MinimizePlasticOptions o = base_options(g);
  topopt::SimpOptions so = o.simp;
  so.volume_fraction = 0.6;
  so.cg_max_iterations = 1;  // starve every solve
  bool opt_threw = false;
  SimpOptimizeResult res;
  try {
    res = topopt::simp_optimize(g, params, bcs, loads, so);
  } catch (...) {
    opt_threw = true;
  }
  check(!opt_threw, "1b: simp_optimize does not throw on non-convergence");
  check(res.non_convergent, "1b: simp_optimize reports non_convergent");
  check(!res.converged, "1b: a non_convergent result is not 'converged'");
  check(res.non_convergent_iteration >= 1,
        "1b: the reported firing iteration count is populated");
  check(std::isfinite(res.non_convergent_residual) &&
            res.non_convergent_residual > so.cg_tolerance,
        "1b: the reported residual exceeds the requested tolerance");

  // 1c — N2: analyze_fixed_design cannot certify a design whose CERTIFICATION solve
  // did not converge. Same fixed density, two caps: starved rejects, generous
  // certifies — the tolerance is identical in both, only convergence differs.
  const Material mat = fdm_material();
  const Vec3 build_dir{0, 0, 1};
  const double part_solid = static_cast<double>(g.solid_count());
  const KnockdownSpec kd;  // default (solid infill), so the gate is the scalar path
  std::vector<double> field(n, 1.0);  // a fully-solid, trivially-strong design

  FixedDesignAnalysis starved = analyze_fixed_design(
      g, params, field, bcs, loads, mat, build_dir, /*cg_tolerance=*/1e-12,
      /*cg_max_iterations=*/1, SolverKind::JacobiCG, /*margin_stop=*/0.0, kd,
      /*load_path_ok=*/true, part_solid);
  check(starved.non_convergent,
        "1c: a starved certification solve reports non_convergent");
  check(!starved.accepted,
        "1c: a non-converged certification NEVER certifies (accepted==false)");
  check(starved.non_convergent_iteration >= 1 &&
            std::isfinite(starved.non_convergent_residual),
        "1c: the failed certification carries its iteration and residual");

  FixedDesignAnalysis good = analyze_fixed_design(
      g, params, field, bcs, loads, mat, build_dir, /*cg_tolerance=*/1e-12,
      /*cg_max_iterations=*/500000, SolverKind::JacobiCG, /*margin_stop=*/0.0, kd,
      /*load_path_ok=*/true, part_solid);
  check(!good.non_convergent,
        "1c: the identical field at a generous cap DOES converge");
  check(good.accepted,
        "1c: and IS certified at the identical tolerance — the gate never softened");
}

// ---------------------------------------------------------------------------
// GROUP 2 — the driver: run completes, accepted survives + exportable, reason
// distinguishable (N4 + N5).
// ---------------------------------------------------------------------------
void group2_driver(const SettingsRules& rules) {
  std::printf("[group 2] driver: run completes, accepted variant survives\n");
  std::vector<DirichletBC> bcs;
  const VoxelGrid g = cantilever_bar(bcs);
  const Material mat = fdm_material();

  MinimizePlasticOptions o = base_options(g);
  o.simp.cg_max_iterations = 800;         // heavy converges, light does not
  o.volume_fraction_ladder = {0.6, 0.02};

  bool driver_threw = false;
  MinimizePlasticResult r;
  try {
    r = minimize_plastic(g, mat, "PLA", bcs, rules, o);
  } catch (...) {
    driver_threw = true;
  }
  check(!driver_threw,
        "2: the run COMPLETES — a non-convergent rung no longer aborts it");
  check(r.evaluated.size() == 2, "2: both rungs were evaluated");
  check(!r.cancelled, "2: the run was not cancelled");

  // Rung 0 — accepted and its variant present.
  const MinimizePlasticVariant& rung0 = r.evaluated[0];
  check(rung0.accepted, "2: rung 0 (vf 0.60) is accepted");
  check(!rung0.non_convergent, "2: rung 0 converged");
  check(!rung0.mesh().triangles.empty(),
        "2: the accepted variant carries a non-empty mesh");

  // N4 — EXPORTABLE ON DISK: write the accepted mesh out and read it back.
  const std::string stl_path =
      std::string(NONCONV_OUT_DIR) + "/nonconv_accepted_rung0.stl";
  bool wrote = false, read_back_ok = false;
  std::size_t tri_out = rung0.mesh().triangles.size(), tri_in = 0;
  try {
    topopt::write_stl_file(stl_path, rung0.mesh());
    wrote = true;
    const topopt::StlMesh got = topopt::read_stl_file(stl_path);
    tri_in = got.mesh.triangles.size();
    read_back_ok = true;
  } catch (...) {
    // leave flags false
  }
  check(wrote, "2/N4: the accepted variant is exportable — STL written to disk");
  check(read_back_ok && tri_in == tri_out,
        "2/N4: the exported STL reads back with the same triangle count");

  // Rung 1 — non-convergent, rejected, NOT certified, in the rejected report.
  const MinimizePlasticVariant& rung1 = r.evaluated[1];
  check(rung1.non_convergent, "2: rung 1 (vf 0.02) is non_convergent");
  check(!rung1.accepted, "2: a non-convergent rung is never accepted");
  check(!rung1.infeasible,
        "2: non-convergence is DISTINCT from infeasibility (not both)");
  check(rung1.mesh().triangles.empty(),
        "2: a non-convergent rung is not analysed — no mesh");
  check(rung1.report.rejection_reason == topopt::kRungNonConvergentReason,
        "2: the rejected line names non-convergence as the reason");

  // The per-rung run_info surface: which rungs, the iteration, the residual.
  check(r.rung_non_convergent.size() == 2 && r.rung_non_convergent[0] == 0 &&
            r.rung_non_convergent[1] == 1,
        "2: rung_non_convergent == {0, 1}");
  check(r.rung_non_convergent_iteration.size() == 2 &&
            r.rung_non_convergent_iteration[1] > 0,
        "2: the failing rung records the iteration it reached");
  check(r.rung_non_convergent_residual.size() == 2 &&
            r.rung_non_convergent_residual[1] > o.simp.cg_tolerance,
        "2: the failing rung records a residual above tolerance");
  // All-zero on the converged rung — the positive statement per rung.
  check(r.rung_non_convergent_iteration[0] == 0 &&
            r.rung_non_convergent_residual[0] == 0.0,
        "2: the converged rung records no non-convergence numbers");

  // N5 — DISTINGUISHABLE from every other rejection, and the report validates.
  const std::string reason = rung1.report.rejection_reason;
  check(reason != topopt::kMarginBelowRequiredReason &&
            reason != topopt::kLoadPathNotConnectedReason &&
            reason != topopt::kRungInfeasibleReason,
        "2/N5: the non-convergence reason differs from all three other reasons");
  bool report_ok = false;
  try {
    topopt::validate_job_report_json(topopt::job_report_json(r.report));
    report_ok = true;
  } catch (...) {
  }
  check(report_ok,
        "2/N5: the assembled report validates with the non-convergence reason");
  // The rejected variant is in the report, once, with the right reason.
  int found = 0;
  for (const topopt::VariantReport& vr : r.report.rejected)
    if (vr.rejection_reason == topopt::kRungNonConvergentReason) ++found;
  check(found == 1,
        "2/N5: the report's rejected_variants carries exactly the one non-conv line");
}

// ---------------------------------------------------------------------------
// GROUP 3 — N3: warm-start inheritance across a rejected (trajectory-non-convergent)
// rung obeys handoff 131's rule. The rung AFTER a non-convergent rung inherits the
// SAME seed it would inherit had the failing rung never run — proven bit-for-bit.
// ---------------------------------------------------------------------------
void group3_warm_start(const SettingsRules& rules) {
  std::printf("[group 3] N3 — warm-start unchanged across a rejected rung\n");
  std::vector<DirichletBC> bcs;
  const VoxelGrid g = cantilever_bar(bcs);
  const Material mat = fdm_material();

  // L2: {0.6, 0.015}. Rung 0 accepts; rung 1 (0.015) fails at its FIRST trajectory
  // solve (near-singular from the very first solve), so the seed guard (which runs
  // only after a rung's simp_optimize returns AND clears the connectivity/feasibility
  // checks) is never reached — warm_seed still holds rung 0's converged density.
  MinimizePlasticOptions o2 = base_options(g);
  o2.simp.cg_max_iterations = 800;
  o2.volume_fraction_ladder = {0.6, 0.015};
  const MinimizePlasticResult L2 = minimize_plastic(g, mat, "PLA", bcs, rules, o2);

  // L1: {0.6, 0.02, 0.015}. An EXTRA non-convergent rung (0.02) is inserted before
  // the last one. If the intervening failing rung leaves the seed untouched (131's
  // rule), the LAST rung of L1 (0.015) inherits exactly what the SECOND rung of L2
  // (also 0.015) inherited — rung 0's density — and, being deterministic, produces a
  // bit-for-bit identical result. The two successors target the identical vf, so any
  // difference could only come from a different inherited seed.
  MinimizePlasticOptions o1 = o2;
  o1.volume_fraction_ladder = {0.6, 0.02, 0.015};
  const MinimizePlasticResult L1 = minimize_plastic(g, mat, "PLA", bcs, rules, o1);

  check(L1.evaluated.size() == 3 && L2.evaluated.size() == 2,
        "3: both ladders ran to completion (no rung aborted the run)");

  // The accepted prefix is untouched by the failing rung(s).
  const bool prefix_same =
      L1.evaluated[0].optimization.physical_density ==
          L2.evaluated[0].optimization.physical_density &&
      L1.evaluated[0].optimization.compliance ==
          L2.evaluated[0].optimization.compliance;
  check(prefix_same, "3: rung 0 is identical with and without the failing rung");

  // THE INHERITANCE PROOF: L1's rung 2 (after the extra non-convergent rung 1)
  // equals L2's rung 1 (right after rung 0) bit-for-bit. Same verdict, same firing
  // numbers, same field — so both inherited the SAME seed. An intervening
  // non-convergent rung changed nothing about what the next rung starts from.
  const MinimizePlasticVariant& succ_L1 = L1.evaluated[2];
  const MinimizePlasticVariant& succ_L2 = L2.evaluated[1];
  check(succ_L1.non_convergent && succ_L2.non_convergent,
        "3: both successors are themselves non_convergent (lightest rung)");
  check(L1.rung_non_convergent_iteration[2] ==
                L2.rung_non_convergent_iteration[1] &&
            L1.rung_non_convergent_residual[2] ==
                L2.rung_non_convergent_residual[1],
        "3: the successor reaches the identical iteration and residual either way");
  check(succ_L1.optimization.physical_density ==
            succ_L2.optimization.physical_density,
        "3: the successor's field is bit-for-bit identical — same inherited seed");
  check(succ_L1.optimization.initial_compliance ==
            succ_L2.optimization.initial_compliance,
        "3: the successor's starting compliance is identical — 131's rule holds");
}

// ---------------------------------------------------------------------------
// GROUP 4 — N1: inert on a healthy run. A generous cap never triggers the path;
// the ladder behaves as a normal run and the non_convergent surface is all-false.
// ---------------------------------------------------------------------------
void group4_inert(const SettingsRules& rules) {
  std::printf("[group 4] N1 — inert on a run that never hits non-convergence\n");
  std::vector<DirichletBC> bcs;
  const VoxelGrid g = cantilever_bar(bcs);
  const Material mat = fdm_material();

  MinimizePlasticOptions o = base_options(g);
  o.simp.cg_max_iterations = 500000;  // generous: every solve converges
  o.volume_fraction_ladder = {0.6, 0.5};
  const MinimizePlasticResult r = minimize_plastic(g, mat, "PLA", bcs, rules, o);

  check(r.evaluated.size() == 2, "4: both rungs evaluated");
  bool any_nc = false;
  for (const MinimizePlasticVariant& v : r.evaluated)
    if (v.non_convergent) any_nc = true;
  check(!any_nc, "4: no rung is non_convergent on a healthy run");
  check(r.rung_non_convergent.size() == 2 && r.rung_non_convergent[0] == 0 &&
            r.rung_non_convergent[1] == 0,
        "4: the non_convergent surface is all-false — 'every solve converged'");
  for (const MinimizePlasticVariant& v : r.evaluated) {
    check(v.report.rejection_reason.empty() || v.accepted == false,
          "4: reason honesty preserved");
  }
  check(r.evaluated[0].accepted && !r.evaluated[0].mesh().triangles.empty(),
        "4: the healthy run still produces accepted, meshed variants");
}

}  // namespace

int main() {
  const SettingsRules rules = topopt::load_settings_rules_file(SETTINGS_RULES_PATH);

  group1_layers();
  group2_driver(rules);
  group3_warm_start(rules);
  group4_inert(rules);

  std::printf("\n%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
