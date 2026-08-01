// test_gate_diagnosis — a gate rejection explains what bound it, and every
// recommendation is a MEASUREMENT through the real gate
// (task 2026-08-02-gate-diagnosis-recommendations).
//
// WHAT THIS PINS, bar by bar:
//
//   X1  *** NO VERDICT MOVES. *** The SAME run is walked twice, with the
//       diagnosis OFF and ON, and every gate field of every rung — accepted,
//       margin.in_plane / interlayer / worst_case, margin_effective,
//       margin_required, rejection_reason, the achieved fractions, the stresses
//       — must be BIT-IDENTICAL. Backed by a STRUCTURAL assert: the diagnosis
//       sources are grepped for any assignment to a gate field, because a future
//       edit that starts writing one would otherwise pass the numeric check on
//       the fixture it happened to be run on.
//
//   X2  THE MOTIVATING CASE, REPRODUCED. The real maintainer run (fingerprint
//       9f6738726016, WallMount bracket, PLA, 35% infill): max_stress 14.459
//       MPa, max_interlayer 10.876 MPa, margins 3.8038 / 2.7814 / 2.7814,
//       margin_effective 0.5759 against a required 1.5. The diagnosis must name
//       the KNOCKDOWN as binding, carry 2.7814 AND 0.5759 (the dialog showed
//       0.00, a max over an empty array), and recommend an infill that the REAL
//       GATE accepts.
//
//   X3  *** NO UNVERIFIED RECOMMENDATION CAN BE EMITTED. *** Two cases where the
//       obvious inversion picks something that does NOT pass:
//         (a) MATERIAL. "Try a stronger material" ranks by yield. A catalog
//             entry with a HIGHER yield and a lower z_knockdown is measurably
//             WEAKER where the interlayer term binds. It must not be emitted,
//             while a same-yield / better-z_knockdown entry must be.
//         (b) INFILL. The algebraic inverse of the f^1.5 curve on the motivating
//             case is 66.25%, and 66% does NOT clear the gate (1.4912 < 1.5).
//             An inversion-only implementation that rounds to 66 would emit a
//             setting that fails; this one evaluates and lands on 67.
//
//   X4  THE IRRELEVANT-ADVICE REGRESSION. A pure stress-margin rejection must
//       NOT recommend a resolution change (the canned string did). A min-feature
//       binding MUST.
//
//   X5  ORIENTATION ADVICE COMES FROM THE SCORER. On PR 266's rescue case the
//       orientation recommendation must be the row PR 271's ranking picked, must
//       carry that row's own gate-priced margin, and must be offered ONLY when
//       the interlayer term binds.
//
//   X6  ACCEPTED PARTS GET THE SAME TREATMENT: the infill headroom, computed by
//       the same machinery run downward.
//
//   X7  DETERMINISM. The same inputs produce a byte-identical diagnosis
//       document, twice.
//
// Self-contained CHECK harness (ARCHITECTURE §4), public API only. Needs the FEA
// solve for X1/X5, so it is Eigen-gated like test_build_direction, and it reads
// the same read-only hook fixture. It gates nothing in production.

#include "topopt/analyze.hpp"
#include "topopt/build_orientation.hpp"
#include "topopt/fea.hpp"
#include "topopt/gate_diagnosis.hpp"
#include "topopt/gate_diagnosis_eval.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/orient.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/report.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/stl.hpp"
#include "topopt/voxel.hpp"

#include <cctype>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

using namespace topopt;

static int g_failures = 0;
static int g_checks = 0;

static void check(bool ok, const char* what) {
  ++g_checks;
  if (!ok) {
    ++g_failures;
    std::printf("  FAIL: %s\n", what);
  }
}
#define CHECK(cond, msg) check((cond), (msg))

namespace {

constexpr double kIso = 0.5;
constexpr double kCertTol = 1e-8;

bool near(double a, double b, double tol) { return std::fabs(a - b) <= tol; }

const GateRecommendation* rec_for(const GateDiagnosis& d, GateLever l) {
  for (const GateRecommendation& r : d.recommendations)
    if (r.lever == l) return &r;
  return nullptr;
}

const GateLeverOutcome* lever_for(const GateDiagnosis& d, GateLever l) {
  for (const GateLeverOutcome& o : d.levers)
    if (o.lever == l) return &o;
  return nullptr;
}

std::string diagnosis_json(const GateDiagnosis& d) {
  std::string s;
  emit_gate_diagnosis(s, d, "");
  return s;
}

// ── THE MOTIVATING RUN, to the digit ────────────────────────────────────────
// fingerprint 9f6738726016, WallMount bracket, TO only, design box on, 1.5 h.
// report.json carried these on its ONE rejected_variants entry; `variants` was
// EMPTY, which is what produced the 0.00x the dialog showed.
constexpr double kWallMountMaxStress = 14.459;
constexpr double kWallMountMaxInterlayer = 10.876;
constexpr double kWallMountInfill = 35.0;
constexpr double kWallMountMarginStop = 1.5;

Material pla() {
  Material m;
  m.youngs_modulus_mpa = 3500.0;
  m.yield_strength_mpa = 55.0;
  m.density_g_cm3 = 1.24;
  m.z_knockdown = 0.55;
  m.poisson = 0.33;
  m.family = "fdm";
  return m;
}

// The motivating case as diagnose_gate inputs. Every gate number is computed by
// the PRODUCTION functions (compute_stress_margin / gate_margin_effective /
// knockdown_spec_for's formula), not typed in, so the fixture cannot drift away
// from the gate it claims to reproduce.
GateDiagnosisInputs wallmount_inputs() {
  GateDiagnosisInputs in;
  in.material = pla();
  in.material_name = "PLA";
  in.max_von_mises = kWallMountMaxStress;
  in.max_von_mises_effective = kWallMountMaxStress;
  in.max_interlayer = kWallMountMaxInterlayer;
  in.margin = compute_stress_margin(in.material.yield_strength_mpa,
                                    in.material.z_knockdown, in.max_von_mises,
                                    in.max_interlayer);
  in.infill_percent = kWallMountInfill;
  in.knockdown.infill_knockdown = infill_margin_knockdown(kWallMountInfill);
  in.knockdown.infill_percent = kWallMountInfill;
  in.margin_stop = kWallMountMarginStop;
  in.margin_effective = gate_margin_effective(
      in.material.yield_strength_mpa, in.material.z_knockdown, in.max_von_mises,
      in.max_von_mises_effective, in.max_interlayer, in.knockdown);
  in.accepted = in.margin_effective >= in.margin_stop;
  in.load_path_ok = true;
  in.this_volume_fraction = 0.30;
  return in;
}

// ── the hook fixture, verbatim test_build_direction's (which is verbatim the
// probe's), so X5's numbers are comparable to PR 266's ──────────────────────
struct Fixture {
  TriangleMesh mesh;
  VoxelGrid grid;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  std::vector<double> density;
  double part_solid = 0.0;
};

Fixture build_fixture(const std::string& fixture_dir, int resolution,
                      int load_axis) {
  Fixture f;
  f.mesh = import_stl_file(fixture_dir + "/hook.stl");
  f.grid = voxelize(f.mesh, resolution);

  int fixture_voxels = 0, load_voxels = 0;
  for (int k = 0; k < f.grid.nz; ++k)
    for (int j = 0; j < f.grid.ny; ++j)
      for (int i = 0; i < f.grid.nx; ++i) {
        if (!f.grid.solid(i, j, k)) continue;
        const Vec3 c = f.grid.voxel_center(i, j, k);
        if (i == 0 && c.y >= 8.0 && c.y <= 40.0) {
          f.grid.set_tag(i, j, k, VoxelTag::Fixture);
          ++fixture_voxels;
        } else if (c.x >= 20.0 && c.x <= 27.0 && c.y >= 7.0 && c.y <= 15.0) {
          f.grid.set_tag(i, j, k, VoxelTag::Load);
          ++load_voxels;
        }
      }
  CHECK(fixture_voxels > 0, "fixture region has solid voxels");
  CHECK(load_voxels > 0, "load region has solid voxels");

  for (int n : fea_tagged_nodes(f.grid, VoxelTag::Fixture))
    for (int c = 0; c < 3; ++c) f.bcs.push_back(DirichletBC{n, c, 0.0});

  const std::vector<int> load_nodes = fea_tagged_nodes(f.grid, VoxelTag::Load);
  const double per_node = -60.0 / static_cast<double>(load_nodes.size());
  for (int n : load_nodes) f.loads.push_back(NodalLoad{n, load_axis, per_node});

  f.density.assign(f.grid.voxel_count(), 0.0);
  std::size_t solid = 0;
  for (int k = 0; k < f.grid.nz; ++k)
    for (int j = 0; j < f.grid.ny; ++j)
      for (int i = 0; i < f.grid.nx; ++i)
        if (f.grid.solid(i, j, k)) {
          f.density[f.grid.index(i, j, k)] = 1.0;
          ++solid;
        }
  f.part_solid = static_cast<double>(solid);
  return f;
}

// ── X1's fixture: the cantilever bracket of test_minimize_plastic, with a low
// yield so the ladder actually crosses the margin stop ──────────────────────
VoxelGrid cantilever_bracket(std::vector<DirichletBC>& bcs) {
  const int nx = 20, ny = 4, nz = 5;
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = 2.0;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j) g.set_tag(0, j, k, VoxelTag::Fixture);
  bcs.clear();
  for (int c = 0; c <= nz; ++c)
    for (int b = 0; b <= ny; ++b) {
      const int n = fea_node_index(g, 0, b, c);
      bcs.push_back({n, 0, 0.0});
      bcs.push_back({n, 1, 0.0});
      bcs.push_back({n, 2, 0.0});
    }
  return g;
}

Material weak_fdm() {
  Material m = pla();
  m.yield_strength_mpa = 0.02;  // in-code test material (NOT materials.json)
  return m;
}

MinimizePlasticOptions ladder_options() {
  MinimizePlasticOptions o;
  o.volume_fraction_ladder = {0.7, 0.5, 0.3};
  o.margin_stop = 1.5;
  o.gravity = 1.0;
  o.gravity_direction = Vec3{0, 0, -1};
  o.simp.filter_radius = 1.5;
  o.simp.move = 0.2;
  o.simp.max_iterations = 40;
  o.simp.change_tol = 0.0;
  o.simp.cg_tolerance = 1e-8;
  return o;
}

std::string read_file(const std::string& path) {
  std::ifstream f(path);
  std::ostringstream ss;
  ss << f.rdbuf();
  return ss.str();
}

}  // namespace

int main() {
  std::printf("test_gate_diagnosis\n");

  // =========================================================================
  // X2 — THE MOTIVATING CASE, REPRODUCED.
  // =========================================================================
  {
    std::printf(" X2: the motivating WallMount run\n");
    const GateDiagnosisInputs in = wallmount_inputs();

    // The fixture must be the reported run, to the digit the report carried.
    CHECK(near(in.margin.in_plane, 3.8038, 5e-4), "X2: in_plane margin 3.8038");
    CHECK(near(in.margin.interlayer, 2.7814, 5e-4),
          "X2: interlayer margin 2.7814");
    CHECK(near(in.margin.worst_case, 2.7814, 5e-4),
          "X2: worst-case margin 2.7814");
    CHECK(near(in.margin_effective, 0.5759, 5e-4),
          "X2: margin_effective 0.5759 (the number the gate compared)");
    CHECK(!in.accepted, "X2: the run was REJECTED, as reported");

    const GateDiagnosis d = diagnose_gate(in);
    CHECK(d.evaluated, "X2: the diagnosis ran");
    CHECK(!d.accepted, "X2: it echoes the REJECTED verdict, never changes it");

    // (a) THE 0.00x FAULT. BOTH numbers are carried, and neither is zero.
    CHECK(near(d.margin_worst_case, 2.7814, 5e-4),
          "X2: the diagnosis carries the RAW worst case 2.7814");
    CHECK(near(d.margin_effective, 0.5759, 5e-4),
          "X2: the diagnosis carries the EFFECTIVE margin 0.5759");
    CHECK(d.margin_worst_case > 0.0 && d.margin_effective > 0.0,
          "X2: neither margin is the empty-array 0.00 the dialog showed");
    CHECK(near(d.margin_worst_case / d.margin_effective, 4.83, 0.02),
          "X2: the two differ by 4.8x — only one of them explains the refusal");

    // (b) WHAT BOUND IT. The part clears the requirement; the KNOCKDOWN does not.
    CHECK(d.binding == GateTerm::Knockdown,
          "X2: the KNOCKDOWN binds, not the material and not the resolution");
    CHECK(near(d.knockdown_factor, std::pow(0.35, 1.5), 1e-9),
          "X2: the binding value is the f^1.5 knockdown at 35% infill");
    CHECK(near(d.required_value, 1.5 / 2.78135, 1e-3),
          "X2: against the knockdown the part actually needed (0.5393)");
    CHECK(d.ratio < 1.0, "X2: binding_value / required_value < 1 == a rejection");
    CHECK(d.inherits_unsourced_z_knockdown && !d.provenance.empty(),
          "X2: the interlayer term governs, so the z_knockdown provenance rides "
          "along (ARCHITECTURE.md §6: unsourced for every material)");

    // (c) THE FIX IS INFILL, AND IT WAS VERIFIED.
    const GateRecommendation* inf = rec_for(d, GateLever::Infill);
    CHECK(inf != nullptr, "X2: infill is recommended");
    if (inf != nullptr) {
      std::printf("   computed figure: exact inverse %.4f%%, emitted %.0f%%\n",
                  100.0 * std::pow(1.5 / in.margin.worst_case, 2.0 / 3.0),
                  inf->proposed_value);
      CHECK(inf->proposed_value >= 66.0,
            "X2: the recommendation is >= 66% infill");
      CHECK(inf->verified_through_gate,
            "X2: the recommendation is flagged VERIFIED");
      CHECK(inf->margin_effective_at_proposal >= inf->margin_required,
            "X2: and it really does clear the gate at the proposal");
      // The claim is checkable independently: re-price the proposal here, with
      // the SAME production function, and get the SAME number.
      KnockdownSpec k = in.knockdown;
      k.infill_percent = inf->proposed_value;
      k.infill_knockdown = infill_margin_knockdown(inf->proposed_value);
      const double independent = gate_margin_effective(
          in.material.yield_strength_mpa, in.material.z_knockdown,
          in.max_von_mises, in.max_von_mises_effective, in.max_interlayer, k);
      CHECK(independent == inf->margin_effective_at_proposal,
            "X2: the emitted margin IS gate_margin_effective's, bit for bit");
      CHECK(inf->inherits_unsourced_z_knockdown,
            "X2: the infill figure divides by z_knockdown and says so");
    }

    // (d) X3(b) — WHERE INVERSION ALONE WOULD SHIP A FAILING SETTING.
    // The algebra says 66.25%. Rounded to 66 it does NOT pass.
    {
      const double f_exact = std::pow(1.5 / in.margin.worst_case, 2.0 / 3.0);
      CHECK(near(100.0 * f_exact, 66.25, 0.1),
            "X3(b): the algebraic inverse is 66.25% infill");
      KnockdownSpec k66 = in.knockdown;
      k66.infill_percent = 66.0;
      k66.infill_knockdown = infill_margin_knockdown(66.0);
      const double at66 = gate_margin_effective(
          in.material.yield_strength_mpa, in.material.z_knockdown,
          in.max_von_mises, in.max_von_mises_effective, in.max_interlayer, k66);
      CHECK(at66 < 1.5,
            "X3(b): 66% infill does NOT clear the gate (the inversion's answer)");
      CHECK(inf != nullptr && inf->proposed_value >= 67.0,
            "X3(b): so the EVALUATED recommendation is 67%, not 66% — an "
            "inversion-only implementation fails this check");
    }

    // (e) X4 first half — a pure stress-margin rejection offers NO resolution
    // change. This is the exact fault in the canned string.
    CHECK(rec_for(d, GateLever::Resolution) == nullptr,
          "X4: a stress-margin rejection does NOT recommend a resolution change");
    const GateLeverOutcome* res = lever_for(d, GateLever::Resolution);
    CHECK(res != nullptr && !res->passed,
          "X4: and the resolution lever is REPORTED as not offered, with a reason");

    // (f) the canned advice's other two-thirds, measured rather than asserted:
    // no material is needed, because the part is strong enough at solid infill.
    CHECK(d.margin_worst_case > 1.5,
          "X2: the part's own worst-case margin already exceeds the 1.5 minimum, "
          "so 'try a stronger material' was answering the wrong question");
  }

  // =========================================================================
  // X3(a) — NO UNVERIFIED RECOMMENDATION: the MATERIAL lever.
  //
  // "Try a stronger material" ranks by yield. Here the higher-yield entry is
  // measurably WEAKER, because the interlayer term is (z_knockdown * yield) /
  // tension and its z_knockdown is much lower. Ours prices it and drops it.
  // =========================================================================
  {
    std::printf(" X3(a): a higher-yield material that the gate rejects\n");
    MaterialLibrary lib;
    Material cur = pla();  // yield 55, z 0.55, nu 0.33
    Material high_yield = pla();
    high_yield.yield_strength_mpa = 60.0;  // STRONGER by the canned heuristic
    high_yield.z_knockdown = 0.40;         // ...and worse across layers
    Material better_z = pla();
    better_z.z_knockdown = 0.75;           // same yield, better layer bond
    Material passes_but_different_nu = pla();
    passes_but_different_nu.z_knockdown = 0.75;
    passes_but_different_nu.poisson = 0.37;  // a DIFFERENT stress field
    lib["CUR"] = cur;
    lib["HIGH_YIELD"] = high_yield;
    lib["BETTER_Z"] = better_z;
    lib["OTHER_NU"] = passes_but_different_nu;

    GateDiagnosisInputs in;
    in.material = cur;
    in.material_name = "CUR";
    in.max_von_mises = 20.0;    // in-plane 55/20  = 2.75 (never binds)
    in.max_von_mises_effective = 20.0;
    in.max_interlayer = 25.0;   // interlayer 0.55*55/25 = 1.21 (binds)
    in.margin = compute_stress_margin(cur.yield_strength_mpa, cur.z_knockdown,
                                      in.max_von_mises, in.max_interlayer);
    in.infill_percent = 100.0;  // solid: the knockdown is exactly 1.0
    in.knockdown.infill_knockdown = infill_margin_knockdown(100.0);
    in.knockdown.infill_percent = 100.0;
    in.margin_stop = 1.5;
    in.margin_effective = gate_margin_effective(
        cur.yield_strength_mpa, cur.z_knockdown, in.max_von_mises,
        in.max_von_mises_effective, in.max_interlayer, in.knockdown);
    in.accepted = false;
    in.materials = &lib;
    in.poisson_locked = true;

    CHECK(near(in.margin.interlayer, 1.21, 1e-9),
          "X3(a): the current material's interlayer margin is 1.21 (binds)");
    CHECK(high_yield.yield_strength_mpa > cur.yield_strength_mpa,
          "X3(a): the trap material IS stronger by yield");
    CHECK((high_yield.z_knockdown * high_yield.yield_strength_mpa) <
              (cur.z_knockdown * cur.yield_strength_mpa),
          "X3(a): ...and WEAKER across layers, which is what the gate tests");

    const GateDiagnosis d = diagnose_gate(in);
    CHECK(d.binding == GateTerm::Interlayer,
          "X3(a): the interlayer term binds");
    bool saw_high_yield = false, saw_better_z = false, saw_other_nu = false;
    for (const GateRecommendation& r : d.recommendations) {
      if (r.lever != GateLever::Material) continue;
      if (r.proposed_label == "HIGH_YIELD") saw_high_yield = true;
      if (r.proposed_label == "BETTER_Z") saw_better_z = true;
      if (r.proposed_label == "OTHER_NU") saw_other_nu = true;
      CHECK(r.verified_through_gate &&
                r.margin_effective_at_proposal >= r.margin_required,
            "X3(a): every emitted material really clears the gate");
    }
    CHECK(!saw_high_yield,
          "*** X3(a): the HIGHER-YIELD material is NOT recommended. An "
          "inversion on yield emits it; evaluating it through "
          "gate_margin_effective (0.96 < 1.5) drops it. ***");
    CHECK(saw_better_z,
          "X3(a): the material that DOES clear the gate is recommended, so the "
          "lever is not merely dead");
    CHECK(!saw_other_nu,
          "X3(a): a material that clears the gate but changes Poisson's ratio "
          "is NOT recommended — confirming it costs a re-solve");
    const GateLeverOutcome* mat = lever_for(d, GateLever::Material);
    CHECK(mat != nullptr && mat->evaluable && mat->candidates_tried == 3,
          "X3(a): all three candidates were PRICED, and it is reported");
  }

  // =========================================================================
  // X5 second half + "nothing passes" — an interlayer-bound case where no
  // catalog material and no infill can save it says so PLAINLY.
  // =========================================================================
  {
    std::printf(" X5b/X-none: when nothing passes, say so\n");
    MaterialLibrary lib;
    lib["CUR"] = pla();
    GateDiagnosisInputs in;
    in.material = pla();
    in.material_name = "CUR";
    in.max_von_mises = 20.0;
    in.max_von_mises_effective = 20.0;
    in.max_interlayer = 60.0;  // interlayer 30.25/60 = 0.504 — hopeless
    in.margin = compute_stress_margin(in.material.yield_strength_mpa,
                                      in.material.z_knockdown, in.max_von_mises,
                                      in.max_interlayer);
    in.infill_percent = 100.0;
    in.knockdown.infill_knockdown = infill_margin_knockdown(100.0);
    in.knockdown.infill_percent = 100.0;
    in.margin_stop = 1.5;
    in.margin_effective = gate_margin_effective(
        in.material.yield_strength_mpa, in.material.z_knockdown,
        in.max_von_mises, in.max_von_mises_effective, in.max_interlayer,
        in.knockdown);
    in.accepted = false;
    in.materials = &lib;

    const GateDiagnosis d = diagnose_gate(in);
    // The LOAD lever is the only honest one left, and it is framed as changing
    // the requirement. Everything else must have been tried and reported.
    const GateRecommendation* infill = rec_for(d, GateLever::Infill);
    CHECK(infill == nullptr,
          "X-none: no infill is recommended when 100% still fails");
    const GateLeverOutcome* io = lever_for(d, GateLever::Infill);
    CHECK(io != nullptr && !io->passed && !io->reason.empty(),
          "X-none: the infill lever REPORTS that nothing up to 100% clears it");
    const GateRecommendation* load = rec_for(d, GateLever::Load);
    CHECK(load != nullptr && load->margin_effective_at_proposal >= 1.5,
          "X-none: a lighter load is offered LAST, and it is priced");
    CHECK(load == nullptr || load->note.find("REQUIREMENT") != std::string::npos,
          "X-none: and framed as changing the requirement, not fixing the part");
    // With the load lever removed there is nothing at all — assert the plain
    // statement machinery on the no-lever variant.
    GateDiagnosisInputs hopeless = in;
    hopeless.max_von_mises = 1e5;   // nothing scales out of this
    hopeless.max_interlayer = 1e5;
    hopeless.margin = compute_stress_margin(
        hopeless.material.yield_strength_mpa, hopeless.material.z_knockdown,
        hopeless.max_von_mises, hopeless.max_interlayer);
    hopeless.margin_effective = gate_margin_effective(
        hopeless.material.yield_strength_mpa, hopeless.material.z_knockdown,
        hopeless.max_von_mises, hopeless.max_von_mises_effective,
        hopeless.max_interlayer, hopeless.knockdown);
    const GateDiagnosis hd = diagnose_gate(hopeless);
    CHECK(hd.recommendations.empty(),
          "X-none: nothing is recommended when nothing passes");
    CHECK(hd.no_setting_fixes_this && !hd.no_fix_reason.empty(),
          "X-none: 'no print setting fixes this' is stated explicitly");
    CHECK(hd.no_fix_reason.find("100% infill") != std::string::npos &&
              hd.no_fix_reason.find("MPa") != std::string::npos,
          "X-none: and the reason names the BINDING PHYSICAL QUANTITY");
  }

  // =========================================================================
  // X4 second half — a MIN-FEATURE binding DOES recommend a resolution change,
  // and it is the only lever offered there.
  // =========================================================================
  {
    std::printf(" X4: a min-feature binding recommends resolution\n");
    GateDiagnosisInputs in = wallmount_inputs();
    // Make the strength gate PASS so min-feature is what is left.
    in.infill_percent = 100.0;
    in.knockdown.infill_knockdown = infill_margin_knockdown(100.0);
    in.knockdown.infill_percent = 100.0;
    in.margin_effective = gate_margin_effective(
        in.material.yield_strength_mpa, in.material.z_knockdown,
        in.max_von_mises, in.max_von_mises_effective, in.max_interlayer,
        in.knockdown);
    in.accepted = true;
    in.min_feature_violations = 952;
    in.min_feature_warning_threshold = 1;
    in.min_member_thickness_mm = 2.4;  // measured thinnest printed member
    in.voxel_spacing_mm = 1.6;         // 2.4 / 1.6 = 1.5 voxels < the 2 floor
    in.min_feature_voxels = 2;

    const GateDiagnosis d = diagnose_gate(in);
    CHECK(d.binding == GateTerm::MinFeature,
          "X4: with the strength gate satisfied, MIN-FEATURE binds");
    CHECK(near(d.binding_value, 1.5, 1e-12) && near(d.required_value, 2.0, 1e-12),
          "X4: the binding value is the feature span in voxels vs the V3 floor");
    const GateRecommendation* r = rec_for(d, GateLever::Resolution);
    CHECK(r != nullptr, "*** X4: a min-feature binding DOES recommend a "
                        "resolution change ***");
    if (r != nullptr) {
      CHECK(near(r->proposed_value, 1.2, 1e-12),
            "X4: the proposed spacing clears the 2-voxel floor exactly "
            "(2.4 mm / 2)");
      CHECK(r->proposed_value < in.voxel_spacing_mm,
            "X4: FINER, not coarser — the canned string had the sign wrong");
      CHECK(!r->verified_through_gate && r->note.find("V3") != std::string::npos,
            "X4: it does NOT claim the strength gate's verification, and names "
            "the criterion it was checked against instead");
    }
    CHECK(rec_for(d, GateLever::Material) == nullptr &&
              rec_for(d, GateLever::Infill) == nullptr,
          "X4: no strength lever is offered for a reliability flag");
  }

  // =========================================================================
  // X6 — an ACCEPTED part reports its headroom, same machinery run downward.
  // =========================================================================
  {
    std::printf(" X6: accepted parts report headroom\n");
    GateDiagnosisInputs in = wallmount_inputs();
    in.infill_percent = 80.0;
    in.knockdown.infill_knockdown = infill_margin_knockdown(80.0);
    in.knockdown.infill_percent = 80.0;
    in.margin_effective = gate_margin_effective(
        in.material.yield_strength_mpa, in.material.z_knockdown,
        in.max_von_mises, in.max_von_mises_effective, in.max_interlayer,
        in.knockdown);
    in.accepted = in.margin_effective >= in.margin_stop;
    CHECK(in.accepted, "X6: at 80% infill the motivating part is ACCEPTED");

    const GateDiagnosis d = diagnose_gate(in);
    CHECK(d.binding == GateTerm::None, "X6: nothing binds on an accepted part");
    CHECK(d.headroom_evaluated, "X6: the headroom was computed");
    CHECK(near(d.headroom_min_infill_percent, 67.0, 1e-12),
          "X6: 'passes at 80%; would still pass at 67%' — the SAME lowest infill "
          "the rejection case landed on, from the same search run downward");
    // The headroom claim is checkable, and one percent lower must FAIL.
    KnockdownSpec k = in.knockdown;
    k.infill_percent = d.headroom_min_infill_percent - 1.0;
    k.infill_knockdown = infill_margin_knockdown(k.infill_percent);
    CHECK(gate_margin_effective(in.material.yield_strength_mpa,
                                in.material.z_knockdown, in.max_von_mises,
                                in.max_von_mises_effective, in.max_interlayer,
                                k) < in.margin_stop,
          "X6: and one percent below it the gate really does fail");
    CHECK(d.recommendations.empty(),
          "X6: an accepted part is told its headroom, not given advice");
  }

  // =========================================================================
  // A SEVERED LOAD PATH is named, and no setting is offered for it.
  // =========================================================================
  {
    std::printf(" belt: a severed load path gets no settings advice\n");
    GateDiagnosisInputs in = wallmount_inputs();
    in.load_path_ok = false;
    in.accepted = false;
    const GateDiagnosis d = diagnose_gate(in);
    CHECK(d.binding == GateTerm::LoadPath, "belt: the LOAD PATH binds");
    CHECK(d.recommendations.empty() && d.no_setting_fixes_this,
          "belt: no print setting reconnects a severed structure");
    CHECK(d.no_fix_reason.find("severed") != std::string::npos,
          "belt: and the reason says what the numbers on the line are worth");
  }

  // =========================================================================
  // X7 — DETERMINISM.
  // =========================================================================
  {
    std::printf(" X7: determinism\n");
    const GateDiagnosisInputs in = wallmount_inputs();
    CHECK(diagnosis_json(diagnose_gate(in)) == diagnosis_json(diagnose_gate(in)),
          "X7: the same inputs produce a byte-identical diagnosis document");
  }

  // =========================================================================
  // X1 — NO VERDICT MOVES. The same ladder, diagnosis OFF then ON.
  // =========================================================================
  {
    std::printf(" X1: verdicts and margins are bit-identical with the "
                "diagnosis armed\n");
    std::vector<DirichletBC> bcs;
    const VoxelGrid g = cantilever_bracket(bcs);
    const Material m = weak_fdm();
    const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);

    MaterialLibrary lib;
    lib["PLA_test"] = m;

    MinimizePlasticOptions off = ladder_options();
    off.gravity = 3.0e-8;  // crosses the margin stop partway down the ladder
    MinimizePlasticOptions on = off;
    on.gate_diagnosis = true;
    on.material_catalog = &lib;

    const MinimizePlasticResult a =
        minimize_plastic(g, m, "PLA_test", bcs, rules, off);
    const MinimizePlasticResult b =
        minimize_plastic(g, m, "PLA_test", bcs, rules, on);

    CHECK(a.evaluated.size() == b.evaluated.size(),
          "X1: the same rungs are walked");
    CHECK(a.stopped_on_margin == b.stopped_on_margin,
          "X1: the ladder stops in the same place");
    bool identical = a.evaluated.size() == b.evaluated.size();
    bool any_diagnosis = false;
    for (std::size_t i = 0; identical && i < a.evaluated.size(); ++i) {
      const VariantReport& x = a.evaluated[i].report;
      const VariantReport& y = b.evaluated[i].report;
      identical = identical && a.evaluated[i].accepted == b.evaluated[i].accepted;
      identical = identical && x.accepted == y.accepted;
      identical = identical && x.margin.in_plane == y.margin.in_plane;
      identical = identical && x.margin.interlayer == y.margin.interlayer;
      identical = identical && x.margin.worst_case == y.margin.worst_case;
      identical = identical && x.margin_effective == y.margin_effective;
      identical = identical && x.margin_required == y.margin_required;
      identical = identical && x.rejection_reason == y.rejection_reason;
      identical = identical && x.max_stress_mpa == y.max_stress_mpa;
      identical = identical &&
                  x.max_interlayer_tension_mpa == y.max_interlayer_tension_mpa;
      identical = identical && x.volume_fraction == y.volume_fraction;
      identical = identical && x.printed_fraction == y.printed_fraction;
      identical = identical && x.min_feature_violations == y.min_feature_violations;
      identical = identical && !x.diagnosis.evaluated;
      any_diagnosis = any_diagnosis || y.diagnosis.evaluated;
    }
    CHECK(identical,
          "*** X1: every gate field of every rung is BIT-IDENTICAL with the "
          "diagnosis armed ***");
    CHECK(any_diagnosis, "X1: ...and the armed run really did diagnose");
    CHECK(a.report.variants.size() == b.report.variants.size() &&
              a.report.rejected.size() == b.report.rejected.size(),
          "X1: the accepted/rejected partition is unchanged");

    // The DIAGNOSIS-OFF document is byte-for-byte the pre-diagnosis document:
    // nothing was added to it.
    CHECK(job_report_json(a.report).find("\"diagnosis\"") == std::string::npos,
          "X1: with the diagnosis off, report.json carries no diagnosis key");
    CHECK(job_report_json(b.report).find("\"diagnosis\"") != std::string::npos,
          "X1: with it on, report.json carries one");
    bool valid = true;
    try {
      validate_job_report_json(job_report_json(b.report));
    } catch (const std::exception&) {
      valid = false;
    }
    CHECK(valid, "X1: the diagnosed document still validates against the schema");

    // Every emitted recommendation on the real run is a verified one.
    for (const VariantReport& v : b.report.rejected)
      for (const GateRecommendation& r : v.diagnosis.recommendations)
        CHECK(r.lever == GateLever::Resolution ||
                  (r.verified_through_gate &&
                   r.margin_effective_at_proposal >= r.margin_required),
              "X1: on a real run too, every gate-priced recommendation passes");
  }

  // =========================================================================
  // X1 (structural) — the diagnosis sources cannot write a gate field.
  //
  // The numeric check above proves it on ONE fixture. This proves it for every
  // fixture: grep the two diagnosis translation units for an assignment to any
  // gate output. A future edit that starts writing one fails HERE.
  // =========================================================================
  {
    std::printf(" X1: structural — the diagnosis never assigns a gate field\n");
    const char* srcs[] = {
        TOPOPT_SRC_DIR "/src/simp/gate_diagnosis.cpp",
        TOPOPT_SRC_DIR "/src/settings/gate_diagnosis_report.cpp",
    };
    for (const char* src : srcs) {
      const std::string text = read_file(src);
      CHECK(!text.empty(), "X1: the diagnosis source is readable");
      // (1) It cannot reach around the const contract.
      CHECK(text.find("const_cast") == std::string::npos,
            "*** X1(structural): the diagnosis casts away const ***");
      // (2) It never writes to its INPUTS — the struct that carries the gate's
      // own verdict, margin_effective and margin_stop. Every assignment in these
      // files is to `d.` / `r.` / `o.` / `out.`, i.e. the diagnosis's own values.
      std::size_t at = text.find("in.");
      while (at != std::string::npos) {
        std::size_t e = at + 3;
        while (e < text.size() &&
               (std::isalnum(static_cast<unsigned char>(text[e])) ||
                text[e] == '_'))
          ++e;
        std::size_t sp = e;
        while (sp < text.size() && text[sp] == ' ') ++sp;
        const bool is_write = sp + 1 < text.size() && text[sp] == '=' &&
                              text[sp + 1] != '=';
        CHECK(!is_write,
              "*** X1(structural): the diagnosis writes to a gate input ***");
        at = text.find("in.", at + 1);
      }
    }
    // (3) The contract itself: diagnose_gate takes its inputs BY CONST
    // REFERENCE, so the compiler enforces (2) for any future edit too.
    const std::string hdr =
        read_file(TOPOPT_SRC_DIR "/include/topopt/gate_diagnosis_eval.hpp");
    CHECK(hdr.find("GateDiagnosis diagnose_gate(const GateDiagnosisInputs& in)") !=
              std::string::npos,
          "X1(structural): diagnose_gate's inputs are const by declaration");
    // (4) And the ONE caller wires it as a POST-PASS: in minimize_plastic the
    // diagnosis block writes exactly one field, `vr.diagnosis`.
    const std::string driver =
        read_file(TOPOPT_SRC_DIR "/src/simp/minimize_plastic.cpp");
    CHECK(driver.find("vr.diagnosis = diagnose_gate(gd);") != std::string::npos,
          "X1(structural): the driver assigns only vr.diagnosis from it");
    CHECK(driver.find("= diagnose_gate(") == driver.rfind("= diagnose_gate("),
          "X1(structural): there is exactly one call site");
  }

  // =========================================================================
  // X5 — ORIENTATION ADVICE COMES FROM THE SCORER.
  //
  // PR 266's rescue case: the hook loaded along -y. Built at build = -gravity =
  // +y the interlayer term binds and the part is REJECTED; the ranking's
  // gate-constrained pick clears it. The recommendation must be that row, with
  // that row's own priced margin.
  // =========================================================================
  {
    std::printf(" X5: orientation advice is the scorer's row\n");
    const Fixture f = build_fixture(ORIENT_FIXTURE_DIR, 48, /*load_axis=*/1);
    const MaterialLibrary lib = load_materials_file(MATERIALS_JSON_PATH);
    const auto it = lib.find("PLA");
    CHECK(it != lib.end(), "X5: PLA is in the catalog");
    const Material mat = it->second;

    SimpParams params;
    params.youngs_modulus = mat.youngs_modulus_mpa;
    params.poisson = mat.poisson;
    params.penalty = 3.0;

    const Vec3 as_built{0.0, 1.0, 0.0};  // build = -gravity, PR 266's case
    KnockdownSpec knockdown;             // solid: knockdown exactly 1.0
    const FixedDesignAnalysis fda = analyze_fixed_design(
        f.grid, params, f.density, f.bcs, f.loads, mat, as_built, kCertTol,
        20000, SolverKind::JacobiCG, /*margin_stop=*/1.5, knockdown,
        /*load_path_ok=*/true, f.part_solid, /*lattice=*/nullptr,
        /*score_build_orientation=*/true);
    CHECK(fda.build_orientation.evaluated, "X5: the ranking ran");
    CHECK(!fda.accepted, "X5: built at +y the part is REJECTED (PR 266's case)");

    GateDiagnosisInputs in;
    in.accepted = fda.accepted;
    in.load_path_ok = true;
    in.margin_stop = 1.5;
    in.margin_effective = fda.margin_effective;
    in.margin = fda.margin;
    in.material = mat;
    in.material_name = "PLA";
    in.knockdown = knockdown;
    in.max_von_mises = fda.max_von_mises;
    in.max_von_mises_effective = fda.max_von_mises;
    in.max_interlayer = fda.max_interlayer_tension;
    in.infill_percent = 100.0;
    in.orientation = &fda.build_orientation;
    in.materials = &lib;

    const GateDiagnosis d = diagnose_gate(in);
    CHECK(in.margin.interlayer <= in.margin.in_plane,
          "X5: the INTERLAYER term is the one that binds (the precondition)");
    const GateRecommendation* orient = rec_for(d, GateLever::BuildOrientation);
    CHECK(orient != nullptr, "X5: an orientation IS recommended");
    if (orient != nullptr) {
      const BuildOrientationReport& br = fda.build_orientation;
      const std::size_t idx = static_cast<std::size_t>(orient->proposed_value);
      CHECK(idx == br.auto_applied_index,
            "*** X5: the recommendation IS the ranking's own gate-constrained "
            "pick — not a guess and not a re-derivation ***");
      CHECK(br.candidates[idx].would_be_accepted,
            "X5: and that row clears the gate");
      CHECK(orient->margin_effective_at_proposal ==
                br.candidates[idx].margin_effective,
            "X5: the emitted margin is the ROW's, bit for bit — the scorer "
            "priced it with gate_margin_effective");
      CHECK(orient->inherits_unsourced_z_knockdown,
            "X5: an interlayer-driven recommendation carries the z_knockdown "
            "provenance");
    }

    // ...and it is offered ONLY when the interlayer term binds. Re-run the SAME
    // ranking against a case whose in-plane term is the min: no orientation.
    {
      GateDiagnosisInputs ip = in;
      ip.max_interlayer = 0.01;  // layer bond carries almost nothing
      ip.margin = compute_stress_margin(mat.yield_strength_mpa, mat.z_knockdown,
                                        ip.max_von_mises, ip.max_interlayer);
      ip.margin_effective = gate_margin_effective(
          mat.yield_strength_mpa, mat.z_knockdown, ip.max_von_mises,
          ip.max_von_mises_effective, ip.max_interlayer, ip.knockdown);
      ip.accepted = ip.margin_effective >= ip.margin_stop;
      if (!ip.accepted) {
        const GateDiagnosis dp = diagnose_gate(ip);
        CHECK(dp.binding == GateTerm::InPlane,
              "X5: the control case is in-plane bound");
        CHECK(rec_for(dp, GateLever::BuildOrientation) == nullptr,
              "*** X5: no orientation is offered when the interlayer term does "
              "not bind — the build direction enters the gate through that term "
              "alone ***");
      }
    }
  }

  // ── EVIDENCE ───────────────────────────────────────────────────────────────
  // The motivating run's diagnosis, as the CORE emits it into report.json. This
  // is the document the app decodes and the dialog is rendered from.
  {
    const GateDiagnosis d = diagnose_gate(wallmount_inputs());
    const std::string path = std::string(TOPOPT_EVIDENCE_DIR) +
                             "/wallmount_diagnosis.json";
    std::ofstream out(path);
    out << diagnosis_json(d) << "\n";
    std::printf("GATE-DIAGNOSIS-EVIDENCE wrote %s\n", path.c_str());
  }

  std::printf("%s (%d checks, %d failures)\n",
              g_failures == 0 ? "PASS" : "FAIL", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
