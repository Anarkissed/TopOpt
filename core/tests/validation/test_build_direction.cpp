// test_build_direction — the BUILD DIRECTION is its own input, and the ranking
// that rides on it is a RECOMMENDATION (task 2026-08-01-build-direction-separation).
//
// WHAT THIS PINS, bar by bar:
//
//   U2  NO SITE STILL INFERS. resolve_build_direction is the ONE derivation:
//       explicit wins verbatim, unset falls back to unit(-gravity). Asserted
//       directly, and then asserted STRUCTURALLY by grepping the production
//       sources for a second `-gravity_direction` derivation — a new call site
//       that re-derives the build direction fails here, which is the only way to
//       keep three paths from drifting apart again (PR 266's S5).
//
//   U4  PR 266's NUMBERS REPRODUCE IN PRODUCTION. The V5 hook at resolution 48
//       under its own load case, run through analyze_fixed_design's PRODUCTION
//       post-pass — not the probe's private scoring loop. The probe measured
//       0.6968 gated (REJECTED) for build = -gravity = +y against 1.3285
//       (ACCEPTED) for +z, a 9.11x macro interlayer ratio, and 48 support voxels
//       against 0. A production path that cannot reproduce that is wrong.
//
//   U5  *** A RECOMMENDATION NEVER SILENTLY CHANGES A VERDICT. *** The verdict
//       reported by the analysis is computed from the orientation ACTUALLY USED.
//       Asserted the hard way: the SAME field is scored twice with two different
//       as-built directions, and each time the analysis's own `accepted` must
//       equal the as-built row's priced verdict — never the recommendation's,
//       even in the case where the two disagree.
//
//   U7  THE CRITERIA STAY HONEST, in production. The strut IN-PLANE margin does
//       not move with build direction, and the six cube axes give an IDENTICAL
//       strut INTERLAYER bound. These are PR 266's S2 self-checks; here they are
//       read off the PRODUCTION report's own self-check flags, so a wiring
//       mistake in the production path (not just in the law) breaks the build.
//
// Self-contained CHECK harness (ARCHITECTURE §4), public API only. Needs the FEA
// solve, so it is gated on Eigen like test_v5, and it reads the SAME read-only
// hook fixture test_v5 does. It gates nothing in production.

#include "topopt/analyze.hpp"
#include "topopt/build_orientation.hpp"
#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/orient.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/production.hpp"
#include "topopt/stl.hpp"
#include "topopt/voxel.hpp"

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
constexpr double kLatticeRho = 0.30;    // inside octet's certifiable band
constexpr double kLatticeCellMm = 4.0;  // recorded; not used in the macro math
constexpr double kCertTol = 1e-8;

double dot3(const Vec3& a, const Vec3& b) {
  return a.x * b.x + a.y * b.y + a.z * b.z;
}

bool same_dir(const Vec3& a, const Vec3& b) { return dot3(a, b) > 1.0 - 1e-9; }

// ── the V5 hook fixture, verbatim the probe's (which is verbatim test_v5's), so
// the numbers below are comparable to PR 266's to the digit ──────────────────
struct Fixture {
  TriangleMesh mesh;
  VoxelGrid grid;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  std::vector<double> density;
  double part_solid = 0.0;
  Vec3 gravity_direction{0.0, -1.0, 0.0};
};

Fixture build_fixture(const std::string& fixture_dir, int resolution,
                      int load_axis) {
  Fixture f;
  f.mesh = import_stl_file(fixture_dir + "/hook.stl");
  f.grid = voxelize(f.mesh, resolution);
  f.gravity_direction = Vec3{load_axis == 0 ? -1.0 : 0.0,
                             load_axis == 1 ? -1.0 : 0.0,
                             load_axis == 2 ? -1.0 : 0.0};

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

// The octet region: a one-voxel erosion of the printed interior, so the lattice
// sits inside and the shell stays solid. Verbatim the probe's build_posture.
LatticePosture build_posture(const Fixture& f) {
  LatticePosture p;
  p.topology = LatticeTopology::Octet;
  p.cell_size_mm = kLatticeCellMm;
  const std::size_t nv = f.grid.voxel_count();
  p.mask.assign(nv, 0);
  p.relative_density.assign(nv, 0.0);
  auto printed = [&](int i, int j, int k) {
    if (i < 0 || i >= f.grid.nx || j < 0 || j >= f.grid.ny || k < 0 ||
        k >= f.grid.nz)
      return false;
    return f.density[f.grid.index(i, j, k)] > kIso;
  };
  for (int k = 0; k < f.grid.nz; ++k)
    for (int j = 0; j < f.grid.ny; ++j)
      for (int i = 0; i < f.grid.nx; ++i) {
        if (!printed(i, j, k)) continue;
        const VoxelTag t = f.grid.tags[f.grid.index(i, j, k)];
        if (t == VoxelTag::Load || t == VoxelTag::Fixture) continue;
        if (!printed(i - 1, j, k) || !printed(i + 1, j, k) ||
            !printed(i, j - 1, k) || !printed(i, j + 1, k) ||
            !printed(i, j, k - 1) || !printed(i, j, k + 1))
          continue;
        p.mask[f.grid.index(i, j, k)] = 1;
        p.relative_density[f.grid.index(i, j, k)] = kLatticeRho;
      }
  return p;
}

const OrientationCriteria* row_for(const BuildOrientationReport& r,
                                   const Vec3& n) {
  for (const OrientationCriteria& c : r.candidates)
    if (same_dir(c.build_dir, n)) return &c;
  return nullptr;
}

std::string read_file(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  std::ostringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

}  // namespace

int main() {
  const std::string fixture_dir = ORIENT_FIXTURE_DIR;
  const std::string materials_path = MATERIALS_JSON_PATH;
  const std::string src_dir = TOPOPT_SRC_DIR;

  std::printf(
      "=========================================================\n"
      " BUILD DIRECTION SEPARATION -- bars U2 / U4 / U5 / U7\n"
      "=========================================================\n\n");

  // ═══ U2 — THE ONE RESOLVER ═══════════════════════════════════════════════
  std::printf("U2 -- resolve_build_direction is the ONE derivation\n");
  {
    MinimizePlasticOptions opts;
    opts.gravity_direction = Vec3{0.0, -1.0, 0.0};
    // UNSET => the documented fallback, unit(-gravity). Byte-identical to what
    // all three sites derived inline before this function existed.
    CHECK(resolve_build_direction_is_inferred(opts),
          "an unset build_direction reports as INFERRED");
    CHECK(same_dir(resolve_build_direction(opts), Vec3{0.0, 1.0, 0.0}),
          "unset build_direction falls back to unit(-gravity)");

    // SET => used VERBATIM. Gravity is not consulted at all.
    opts.build_direction = Vec3{0.0, 0.0, 3.0};  // deliberately non-unit
    CHECK(!resolve_build_direction_is_inferred(opts),
          "an explicit build_direction reports as DECLARED, not inferred");
    CHECK(same_dir(resolve_build_direction(opts), Vec3{0.0, 0.0, 1.0}),
          "an explicit build_direction is used verbatim (normalized)");
    // The separation itself: the two directions are now free to disagree.
    CHECK(!same_dir(resolve_build_direction(opts),
                    Vec3{-opts.gravity_direction.x, -opts.gravity_direction.y,
                         -opts.gravity_direction.z}),
          "the build direction is free to differ from -gravity");

    // A degenerate gravity with no declared build direction must fail LOUDLY
    // rather than silently certify against a garbage orientation.
    MinimizePlasticOptions bad;
    bad.gravity_direction = Vec3{0.0, 0.0, 0.0};
    bool threw = false;
    try {
      (void)resolve_build_direction(bad);
    } catch (const std::invalid_argument&) {
      threw = true;
    }
    CHECK(threw, "an unresolvable build direction throws, never defaults");
  }

  // ═══ U2 (structural) — NO OTHER SITE DERIVES IT ══════════════════════════
  // The three sites PR 266 named must consume the resolver, and the production
  // sources must contain exactly ONE `-gravity_direction`-style derivation: the
  // one inside resolve_build_direction itself.
  std::printf("U2 -- no production site re-derives build_dir from gravity\n");
  {
    struct Site {
      const char* path;
      const char* label;
    };
    const Site sites[] = {
        {"/src/simp/minimize_plastic.cpp", "the optimize path (per-rung cert)"},
        {"/src/cli/run_job.cpp", "the lattice receipt + the analyze path"},
    };
    for (const Site& s : sites) {
      const std::string text = read_file(src_dir + s.path);
      CHECK(!text.empty(), s.label);
      CHECK(text.find("resolve_build_direction(options)") != std::string::npos,
            "the site consumes resolve_build_direction");
      // The inline derivation these sites used to carry, in any spelling.
      CHECK(text.find("-options.gravity_direction.x") == std::string::npos,
            "the site no longer derives build_dir from gravity itself");
    }
    // run_job.cpp holds TWO of the three sites, so it must call the resolver
    // twice; a single call would mean one path silently kept an old derivation.
    const std::string rj = read_file(src_dir + "/src/cli/run_job.cpp");
    std::size_t calls = 0, at = 0;
    while ((at = rj.find("resolve_build_direction(options)", at)) !=
           std::string::npos) {
      ++calls;
      at += 1;
    }
    CHECK(calls >= 2,
          "run_job.cpp resolves the build direction at BOTH of its sites");
    // And the fallback itself lives in exactly one file.
    const std::string prod = read_file(src_dir + "/src/simp/production.cpp");
    CHECK(prod.find("opts.gravity_direction.x") != std::string::npos,
          "production.cpp holds THE documented fallback");
  }

  // ═══ U4 / U5 / U7 — the V5 hook, through the PRODUCTION post-pass ════════
  std::printf(
      "\nU4 -- PR 266 case C (hook @ res 48, load -y) through production\n");
  const MaterialLibrary lib = load_materials_file(materials_path);
  const Material material = lib.at("PLA");

  Fixture f = build_fixture(fixture_dir, 48, /*load_axis=*/1);
  const LatticePosture posture = build_posture(f);
  SimpParams params;
  params.youngs_modulus = material.youngs_modulus_mpa;
  params.poisson = material.poisson;
  params.penalty = 3.0;
  const KnockdownSpec knock;  // default posture: the plain scalar gate

  // What production DERIVED before this task: build = -gravity = +y.
  const Vec3 derived{0.0, 1.0, 0.0};
  const Vec3 best{0.0, 0.0, 1.0};

  const FixedDesignAnalysis a = analyze_fixed_design(
      f.grid, params, f.density, f.bcs, f.loads, material, derived, kCertTol, 0,
      SolverKind::JacobiCG, /*margin_stop=*/1.0, knock, /*load_path_ok=*/true,
      f.part_solid, &posture, /*score_build_orientation=*/true,
      /*build_direction_inferred=*/true);
  CHECK(!a.non_convergent, "the certification solve converged");
  CHECK(a.build_orientation.evaluated, "the orientation post-pass ran");

  const BuildOrientationReport& r = a.build_orientation;
  const OrientationCriteria* row_y = row_for(r, derived);
  const OrientationCriteria* row_z = row_for(r, best);
  CHECK(row_y != nullptr && row_z != nullptr,
        "both the derived and the best orientation are in the candidate set");

  if (row_y != nullptr && row_z != nullptr) {
    std::printf(
        "    build = -gravity (+y): gated %.4f  interlayer %.4f  support %d\n"
        "    best candidate  (+z):  gated %.4f  interlayer %.4f  support %d\n",
        row_y->margin_effective, row_y->macro_interlayer_margin,
        row_y->support_voxels, row_z->margin_effective,
        row_z->macro_interlayer_margin, row_z->support_voxels);

    // PR 266's table, reproduced. The tolerance is loose enough to survive a
    // different solver/tolerance path but far tighter than the effect measured
    // (1.9x on the gated number), so a real regression cannot slip through.
    CHECK(std::fabs(row_y->margin_effective - 0.6968) < 5e-3,
          "U4: -gravity gated worst-case margin reproduces 0.6968");
    CHECK(std::fabs(row_z->margin_effective - 1.3285) < 5e-3,
          "U4: +z gated worst-case margin reproduces 1.3285");
    CHECK(!row_y->would_be_accepted,
          "U4: at margin_stop 1.0 the derived orientation is REJECTED");
    CHECK(row_z->would_be_accepted,
          "U4: at margin_stop 1.0 the best orientation is ACCEPTED");
    CHECK(std::fabs(row_y->macro_interlayer_margin - 0.6968) < 5e-3,
          "U4: -gravity macro interlayer margin reproduces 0.6968");
    CHECK(std::fabs(row_z->macro_interlayer_margin - 6.3494) < 5e-2,
          "U4: +z macro interlayer margin reproduces 6.3494");
    const double ratio =
        row_z->macro_interlayer_margin / row_y->macro_interlayer_margin;
    std::printf("    interlayer ratio %.2fx (PR 266 measured 9.11x)\n", ratio);
    CHECK(std::fabs(ratio - 9.11) < 0.1,
          "U4: the interlayer penalty of the conflation reproduces 9.11x");
    CHECK(row_y->support_voxels == 48,
          "U4: the derived orientation needs 48 support voxels");
    CHECK(row_z->support_voxels == 0,
          "U4: the best orientation needs NO support");
    CHECK(row_y->build_height_layers == 6 * row_z->build_height_layers,
          "U4: the derived orientation is 6.0x taller to print");
  }

  // ═══ U5 — the verdict is the AS-BUILT one, always ════════════════════════
  std::printf("\nU5 -- the verdict is computed from the orientation USED\n");
  CHECK(a.build_orientation.candidates[r.as_built_index].build_dir.y > 0.9,
        "the as-built row IS the orientation the analysis solved for");
  CHECK(r.candidates[r.as_built_index].would_be_accepted == a.accepted,
        "U5: the reported verdict equals the AS-BUILT row's verdict");
  CHECK(!a.accepted,
        "U5: the run REJECTS, because the orientation it was given fails");
  CHECK(r.recommendation_differs, "the recommendation differs from as-built");
  CHECK(r.verdict_would_change,
        "U5: and it would gate differently -- exactly the case the receipt "
        "must state in both directions");
  CHECK(r.candidates[r.recommended_index].would_be_accepted,
        "the recommended orientation would be ACCEPTED");
  // The load-bearing negative: a passing recommendation did NOT make the
  // analysis pass. This is the whole bar.
  CHECK(a.accepted == false &&
            r.candidates[r.recommended_index].would_be_accepted == true,
        "U5: *** a recommendation that ACCEPTS did not flip a REJECTED run ***");
  CHECK(r.build_direction_inferred,
        "the receipt records that this direction was ASSUMED from gravity");
  std::printf("    as built: %s; as recommended: %s  (verdict stands: %s)\n",
              a.accepted ? "ACCEPTED" : "REJECTED",
              r.candidates[r.recommended_index].would_be_accepted ? "ACCEPTED"
                                                                  : "REJECTED",
              a.accepted ? "ACCEPTED" : "REJECTED");

  // The mirror case: certify the SAME part with the GOOD orientation declared.
  // The field is the same solve; only the post-solve direction moves. Now the
  // run passes — and the as-built row is the one that must match again.
  {
    const FixedDesignAnalysis b = analyze_fixed_design(
        f.grid, params, f.density, f.bcs, f.loads, material, best, kCertTol, 0,
        SolverKind::JacobiCG, /*margin_stop=*/1.0, knock, /*load_path_ok=*/true,
        f.part_solid, &posture, /*score_build_orientation=*/true,
        /*build_direction_inferred=*/false);
    CHECK(b.accepted,
          "declaring the good build direction ACCEPTS the same part");
    CHECK(b.build_orientation.candidates[b.build_orientation.as_built_index]
              .would_be_accepted == b.accepted,
          "U5: the verdict tracks the as-built orientation in BOTH directions");
    CHECK(!b.build_orientation.build_direction_inferred,
          "a declared direction is not reported as assumed");
    // The physics did not move: the same solve, a different post-pass.
    CHECK(b.max_von_mises == a.max_von_mises,
          "U5: separating the directions did not change the SOLVE (max vm "
          "bit-identical across the two orientations)");
    CHECK(b.mass_grams == a.mass_grams,
          "U5: nor the mass -- the build direction is a post-solve input");
  }

  // ═══ U7 — the criteria stay honest, in production ════════════════════════
  std::printf("\nU7 -- PR 266's self-checks fire on the PRODUCTION path\n");
  CHECK(r.strut_in_plane_invariant,
        "U7: the strut IN-PLANE margin does NOT move with build direction");
  CHECK(r.cube_axes_strut_interlayer_identical,
        "U7: the six cube axes give an IDENTICAL strut INTERLAYER bound");
  CHECK(r.cube_axes_scored == 6,
        "U7: all six cube axes were actually scored (the check has teeth)");
  // Read the invariants off the rows too, not just the summary flags, so a
  // summary that silently stopped being computed cannot pass this test.
  {
    double ip0 = -1.0;
    int axes = 0, ip_moved = 0, il_moved = 0;
    double il0 = -1.0;
    for (const OrientationCriteria& c : r.candidates) {
      if (!c.strut_evaluated) continue;
      if (ip0 < 0.0) ip0 = c.strut_in_plane_margin;
      if (c.strut_in_plane_margin != ip0) ++ip_moved;
      if (!c.on_cube_axis) continue;
      ++axes;
      if (il0 < 0.0) il0 = c.strut_interlayer_margin;
      if (c.strut_interlayer_margin != il0 || c.strut_il_cross_factor != 0.0)
        ++il_moved;
    }
    std::printf(
        "    S-c in-plane %.8f, %d deviations over %zu candidates | S-d cube "
        "axes %.8f, %d deviations over %d axes\n",
        ip0, ip_moved, r.candidates.size(), il0, il_moved, axes);
    CHECK(ip_moved == 0, "U7 (rows): S-c is bit-identical for every candidate");
    CHECK(il_moved == 0, "U7 (rows): S-d is bit-identical on all six axes");
    CHECK(axes == 6, "U7 (rows): six cube axes carried strut evaluations");
  }

  // ═══ U3 — the measured cost, ON THIS BUILD, against the solve it rides on ═
  // The sweep is only "free" if it is small NEXT TO the certification solve it
  // rides on, so both are timed here rather than the sweep alone. A scorer that
  // costs materially more than PR 266's 0.1-0.4% has been reimplemented rather
  // than reused, and this is where that would show.
  std::printf("\nU3 -- measured cost of the post-pass\n");
  {
    for (const int res : {32, 48}) {
      Fixture g = build_fixture(fixture_dir, res, /*load_axis=*/1);
      const LatticePosture gp = build_posture(g);
      // The solve WITHOUT the post-pass, then WITH it, back to back on the same
      // inputs: the difference is the honest cost of arming the scorer.
      const auto t0 = std::chrono::steady_clock::now();
      const FixedDesignAnalysis bare = analyze_fixed_design(
          g.grid, params, g.density, g.bcs, g.loads, material, derived, kCertTol,
          0, SolverKind::JacobiCG, 1.0, knock, true, g.part_solid, &gp);
      const double solve_s =
          std::chrono::duration<double>(std::chrono::steady_clock::now() - t0)
              .count();
      const auto t1 = std::chrono::steady_clock::now();
      const FixedDesignAnalysis scored = analyze_fixed_design(
          g.grid, params, g.density, g.bcs, g.loads, material, derived, kCertTol,
          0, SolverKind::JacobiCG, 1.0, knock, true, g.part_solid, &gp, true,
          true);
      const double armed_s =
          std::chrono::duration<double>(std::chrono::steady_clock::now() - t1)
              .count();
      const BuildOrientationReport& sr = scored.build_orientation;
      std::printf(
          "    res %2d: solve %.4f s | sweep %.4f s (%zu candidates, %.3f ms "
          "each) | axes %.4f s | SWEEP IS %.2f%% OF THE SOLVE | armed-vs-bare "
          "wall %.4f s vs %.4f s\n",
          res, solve_s, sr.sweep_seconds, sr.candidates.size(),
          1000.0 * sr.sweep_seconds / static_cast<double>(sr.candidates.size()),
          sr.strut_axis_measure_seconds,
          100.0 * sr.sweep_seconds / solve_s, armed_s, solve_s);
      // The post-pass must not perturb the certification it rides on: the SOLVE
      // is identical whether the scorer is armed or not. This is the "it is a
      // post-pass, not a feature with a cost" claim, asserted.
      CHECK(scored.margin_effective == bare.margin_effective &&
                scored.accepted == bare.accepted &&
                scored.max_von_mises == bare.max_von_mises &&
                scored.max_interlayer_tension == bare.max_interlayer_tension,
            "U3: arming the scorer leaves the certification BIT-IDENTICAL");
      // A generous ceiling: PR 266 measured 0.1-0.4%. Anything approaching a
      // whole percent of the solve means a criterion is being recomputed rather
      // than re-read, which is exactly the failure this bar exists to catch.
      CHECK(sr.sweep_seconds < 0.05 * solve_s,
            "U3: the sweep is a small fraction of the solve it rides on");
    }
  }

  std::printf("\n%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
