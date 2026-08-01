// mg_component_sweep.cpp — WHY multigrid stagnates: sweep levels, smoother and
// cycle (task: multigrid-component-sweep).
//
// NOT a CI test, NOT in CTest, NOT linked into any production path. It links the
// production library and drives the PRODUCTION solver
// (fea_solve_mgcg_matfree) through the harness-only tuning surface added in
// src/fea/fea_matfree.hpp (fea_detail::mg_set_tuning). Nothing here changes a
// default: the tripwire tests/unit/test_mg_tuning.cpp asserts every effective
// default is still its shipped literal, and this probe restores the shipped
// recipe between every cell.
//
// WHAT IS BEING TESTED. PR 273 measured the prize: healthy multigrid ~0.45 s per
// solve against ~1.1 s for plain Jacobi-CG. But on real design-box runs the
// V-cycle stagnates, burns the full 300-cycle budget, and after
// kMgLatchThreshold == 3 consecutive stagnations the latch turns multigrid off
// for the rest of the run. Three hypotheses from the literature:
//
//   (1) TOO MANY LEVELS. Ferrari & co. (SMO 2025, doi 10.1007/s00158-025-04102-y)
//       report iteration counts "totally exploding" going from two grids to
//       four, blaming fine-grid detail that the coarse grid cannot represent —
//       this project's regime exactly (PR 230 recorded ligaments thinner than a
//       coarse cell).
//   (2) MORE COARSE SMOOTHING or a W-CYCLE — the same paper's stated fix.
//   (3) POINT-BLOCK SMOOTHING. Peetz & Elbanna (SMO 63:835-853, arXiv
//       2001.01655) smooth with WEIGHTED POINT-BLOCK JACOBI, one 3x3 nodal block
//       per node at weight 0.5. Inverting the nodal block couples the three
//       displacement components; the scalar diagonal this codebase uses cannot.
//   (4) CONTRAST. Amir & Sigmund's canonical MGCG-for-TO runs at Emax/Emin =
//       1e6; production here runs 1e9.
//
// ITERATIONS AND WALL, ALWAYS BOTH. This project was just burned by judging an
// accelerator on iteration count alone (PR 273: 88 % of the cost was invisible
// to that counter). Every cell below reports V-CYCLES and MEASURED WALL, with
// the HIERARCHY BUILD reported SEPARATELY from the cycle loop — because fewer
// levels makes the build cheaper while more smoothing does not, and the
// maintainer needs to see which lever moves which cost. A configuration that
// cuts cycles and raises wall is a LOSS and is printed as one.
//
// BUILD (library built Release first; OCCT off, tests off):
//   cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release -DTOPOPT_USE_OCCT=OFF -DTOPOPT_BUILD_TESTS=OFF
//   cmake --build core/build --target topopt -j
//   c++ -std=c++17 -O2 -I core/include -I core/src -I /opt/homebrew/include/eigen3 \
//       -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" \
//       core/tests/harness/mg_component_sweep.cpp core/build/libtopopt.a \
//       -o core/build/mg_component_sweep
// RUN: ./core/build/mg_component_sweep <stag|sweep|healthy|latch|det> [csvdir]

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <cstdlib>
#include <string>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/production.hpp"
#include "topopt/settings.hpp"
#include "topopt/step.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include "fea/fea_matfree.hpp"

using namespace topopt;
using topopt::fea_detail::MgSmoother;
using topopt::fea_detail::MgTuning;

namespace {

// ---------------- production recipe constants (== geneo_twolevel_probe) -------
constexpr double kE0 = 3500.0;        // PLA, MPa
constexpr double kNu = 0.33;
constexpr int kSimpP = 3;
constexpr double kRhoMinProd = 1e-3;  // production void floor => contrast 1e9
constexpr double kCertTol = 1e-8;     // production simp.cg_tolerance

double now_ms() {
  struct timespec t;
  timespec_get(&t, TIME_UTC);
  return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

// HOST LOAD, recorded rather than assumed away. This machine runs other
// campaigns concurrently; PR 273's handoff records how a shared host corrupted
// an earlier judgement. Printing the 1/5/15-minute load average at the start and
// end of every measurement puts the contention IN THE EVIDENCE, so a reader can
// see how much to trust a wall number instead of guessing.
void print_load(const char* when) {
  double la[3] = {0, 0, 0};
  if (getloadavg(la, 3) < 0) { std::printf("   [%s: load unavailable]\n", when); return; }
  std::printf("   [%s host load average: %.2f %.2f %.2f]\n", when, la[0], la[1], la[2]);
}

// FNV-1a over raw bytes — the determinism fingerprint.
struct Fnv {
  std::uint64_t h = 1469598103934665603ULL;
  void add(const void* p, std::size_t n) {
    const auto* b = static_cast<const unsigned char*>(p);
    for (std::size_t i = 0; i < n; ++i) { h ^= b[i]; h *= 1099511628211ULL; }
  }
  void add_d(double d) { add(&d, sizeof d); }
};

// ============================================================================
// THE FIXTURE — the same L-bracket-in-a-dilute-design-box that every stagnation
// study in this repo has used (geneo_twolevel_probe, deflation_probe,
// draft_arming_gate). A thin part inside a box drawn ~2x its bbox, developed
// through the REAL production ladder so the min-feature filter and the Heaviside
// projection produce the thin, near-disconnecting members whose high-contrast
// multigrid stagnates. A bare OC develop does NOT produce that field.
// ============================================================================
VoxelGrid l_bracket(std::vector<DirichletBC>& bcs, int arm, int span, int ny,
                    int t, double h, double hole_frac) {
  VoxelGrid g;
  g.nx = span; g.ny = ny; g.nz = arm; g.spacing = h; g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(span) * ny * arm, VoxelTag::Empty);
  // `hole_frac` removes a cylindrical clearance hole — handoff 125's
  // near-disconnection ingredient, and the reason the genuinely pathological
  // corner of that study was "occ0.4 + hole" rather than dilution alone.
  const double cz = arm * 0.55, cy = ny * 0.5, rr = hole_frac * arm;
  for (int k = 0; k < arm; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < span; ++i) {
        if (!(i < t || k < t)) continue;
        if (rr > 0) {
          const double dz = k + 0.5 - cz, dy = j + 0.5 - cy;
          if (std::sqrt(dz * dz + dy * dy) < rr) continue;
        }
        g.set_tag(i, j, k, VoxelTag::Interior);
      }
  auto solid = [&](int i, int j, int k) {
    if (i < 0 || j < 0 || k < 0 || i >= span || j >= ny || k >= arm) return false;
    return g.tag(i, j, k) != VoxelTag::Empty;
  };
  for (int k = 0; k < arm; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < span; ++i) {
        if (!solid(i, j, k)) continue;
        if (!solid(i-1,j,k) || !solid(i+1,j,k) || !solid(i,j-1,k) ||
            !solid(i,j+1,k) || !solid(i,j,k-1) || !solid(i,j,k+1))
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

DesignBox stagnation_box(int arm, int span, int ny, double h) {
  DesignBox box;
  box.min = Vec3{-span * h * 0.5, -arm * h * 0.54, -arm * h * 0.5};
  box.max = Vec3{ span * h * 1.5, ny * h + arm * h * 0.54, arm * h * 1.5};
  return box;
}

std::vector<double> penalized_youngs(const VoxelGrid& g,
                                     const std::vector<double>& density) {
  std::vector<double> y(g.voxel_count(), 0.0);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        if (!g.solid(i, j, k)) continue;
        const std::size_t e = g.index(i, j, k);
        const double rho = std::min(1.0, std::max(kRhoMinProd, density[e]));
        y[e] = std::pow(rho, kSimpP) * kE0;
      }
  return y;
}

Material fdm_material() {
  Material m;
  m.youngs_modulus_mpa = kE0; m.yield_strength_mpa = 55.0; m.density_g_cm3 = 1.24;
  m.z_knockdown = 0.55; m.poisson = kNu; m.family = "fdm";
  return m;
}

// The developed case: the solved (design-box) grid, its BCs/loads, and the
// density TRAJECTORY — one snapshot per design iteration. The trajectory is what
// makes the latch-rate measurement (AB3) possible without re-running the
// optimiser once per configuration.
struct Case {
  VoxelGrid grid;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  std::vector<std::vector<double>> traj;  // physical density per design iteration
};

bool cache_load(const std::string& path, Case& C) {
  FILE* f = std::fopen(path.c_str(), "rb");
  if (!f) return false;
  int dims[3]; double sp; std::size_t nb, nl, nt;
  bool ok = std::fread(dims, sizeof(int), 3, f) == 3 &&
            std::fread(&sp, sizeof(double), 1, f) == 1;
  C.grid.nx = dims[0]; C.grid.ny = dims[1]; C.grid.nz = dims[2];
  C.grid.spacing = sp; C.grid.origin = Vec3{0, 0, 0};
  C.grid.tags.resize(static_cast<std::size_t>(dims[0]) * dims[1] * dims[2]);
  ok = ok && std::fread(C.grid.tags.data(), sizeof(VoxelTag), C.grid.tags.size(), f) ==
                 C.grid.tags.size();
  ok = ok && std::fread(&nb, sizeof nb, 1, f) == 1; C.bcs.resize(ok ? nb : 0);
  ok = ok && std::fread(C.bcs.data(), sizeof(DirichletBC), nb, f) == nb;
  ok = ok && std::fread(&nl, sizeof nl, 1, f) == 1; C.loads.resize(ok ? nl : 0);
  ok = ok && std::fread(C.loads.data(), sizeof(NodalLoad), nl, f) == nl;
  ok = ok && std::fread(&nt, sizeof nt, 1, f) == 1;
  if (ok) {
    C.traj.resize(nt);
    for (std::size_t i = 0; ok && i < nt; ++i) {
      std::size_t n;
      ok = ok && std::fread(&n, sizeof n, 1, f) == 1;
      C.traj[i].resize(ok ? n : 0);
      ok = ok && std::fread(C.traj[i].data(), sizeof(double), n, f) == n;
    }
  }
  std::fclose(f);
  return ok && !C.traj.empty() && C.traj.back().size() == C.grid.voxel_count();
}

void cache_save(const std::string& path, const Case& C) {
  FILE* f = std::fopen(path.c_str(), "wb");
  if (!f) return;
  int dims[3] = {C.grid.nx, C.grid.ny, C.grid.nz};
  double sp = C.grid.spacing;
  std::size_t nb = C.bcs.size(), nl = C.loads.size(), nt = C.traj.size();
  std::fwrite(dims, sizeof(int), 3, f);
  std::fwrite(&sp, sizeof(double), 1, f);
  std::fwrite(C.grid.tags.data(), sizeof(VoxelTag), C.grid.tags.size(), f);
  std::fwrite(&nb, sizeof nb, 1, f);
  std::fwrite(C.bcs.data(), sizeof(DirichletBC), nb, f);
  std::fwrite(&nl, sizeof nl, 1, f);
  std::fwrite(C.loads.data(), sizeof(NodalLoad), nl, f);
  std::fwrite(&nt, sizeof nt, 1, f);
  for (const std::vector<double>& s : C.traj) {
    std::size_t n = s.size();
    std::fwrite(&n, sizeof n, 1, f);
    std::fwrite(s.data(), sizeof(double), n, f);
  }
  std::fclose(f);
}

// ---------------------------------------------------------------------------
// THE "occ0.4 + hole" REGIME — the case multigrid.cpp's own latch comment names
// as the genuinely pathological one ("does not converge even at 2000 cycles",
// handoff 125 §1d), and the fixture conditioning_probe.cpp was built around.
//
// A whole-domain design box: every voxel is a design variable except a
// rectangular through-hole carved where geometric coarsening hurts most. The
// x=0 face is clamped, a downward traction loads the far face. Developed with
// the PRODUCTION penalized solver and updater down the production reduction
// ladder, so each rung's terminal field is a real dilute design, not a
// synthetic pattern.
//
// It is small and develops in minutes, which is the point: it makes the sweep
// affordable on the case that is hardest for the V-cycle.
// ---------------------------------------------------------------------------
VoxelGrid occhole_grid(int nx, int ny, int nz, double h,
                       std::vector<DirichletBC>& bcs) {
  VoxelGrid g;
  g.nx = nx; g.ny = ny; g.nz = nz; g.spacing = h; g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  const int hx0 = nx * 5 / 16, hx1 = nx * 9 / 16;
  const int hz0 = nz * 9 / 16, hz1 = nz * 13 / 16;
  for (int k = hz0; k < hz1; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = hx0; i < hx1; ++i) g.set_tag(i, j, k, VoxelTag::Empty);
  bcs.clear();
  for (int c = 0; c <= nz; ++c)
    for (int b = 0; b <= ny; ++b) {
      const int node = fea_node_index(g, 0, b, c);
      bcs.push_back({node, 0, 0.0});
      bcs.push_back({node, 1, 0.0});
      bcs.push_back({node, 2, 0.0});
    }
  for (int k = 0; k < nz / 2; ++k)
    for (int j = 0; j < ny; ++j)
      if (g.tag(nx - 1, j, k) != VoxelTag::Empty)
        g.set_tag(nx - 1, j, k, VoxelTag::Load);
  return g;
}

Case develop_occhole(int nx, int ny, int nz, double h, int maxit,
                     const std::string& cache_path) {
  Case C;
  if (!cache_path.empty() && cache_load(cache_path, C)) {
    std::printf("   [cache hit %s: %zu trajectory snapshots]\n",
                cache_path.c_str(), C.traj.size());
    return C;
  }
  C.grid = occhole_grid(nx, ny, nz, h, C.bcs);
  C.loads = traction_loads(C.grid, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});
  std::printf("   grid %dx%dx%d, %zu solid of %zu (occ %.3f)\n", nx, ny, nz,
              C.grid.solid_count(), C.grid.voxel_count(),
              static_cast<double>(C.grid.solid_count()) /
                  static_cast<double>(C.grid.voxel_count()));
  SimpParams params;
  params.youngs_modulus = kE0;
  params.poisson = kNu;
  params.penalty = static_cast<double>(kSimpP);
  params.density_min = kRhoMinProd;
  // Production derives the voxel filter radius from a physical min-feature
  // length (2.5 mm) and the grid spacing; mirror that so the design is
  // representative rather than arbitrarily smooth.
  const double filter_radius = std::max(1.5, 2.5 / h);
  fea_set_krylov_recycling(false); fea_reset_krylov_recycle_space();
  fea_set_geneo_twolevel(false); fea_reset_geneo_basis();
  for (double vf : production_reduction_ladder()) {
    SimpOptions o;
    o.updater = SimpUpdater::MMA;                 // production default
    o.solver = SolverKind::MultigridCG_Matfree;   // production penalized solver
    o.volume_fraction = vf;
    o.filter_radius = filter_radius;
    o.cg_tolerance = kCertTol;
    o.max_iterations = maxit;
    // Capture EVERY design iteration, not just the rung's terminal field: the
    // V-cycle's trouble is a property of particular fields along the way.
    o.density_observer = [&C](int, const std::vector<double>& d) {
      C.traj.push_back(d);
    };
    fea_matfree_reset_mg_stagnation_latch();
    try {
      SimpOptimizeResult r = simp_optimize(C.grid, params, C.bcs, C.loads, o);
      std::printf("   rung vf=%.2f -> achieved %.4f (%zu snapshots so far)\n", vf,
                  r.volume_fraction, C.traj.size());
    } catch (const std::exception& e) {
      std::printf("   rung vf=%.2f FAILED: %s\n", vf, e.what());
    }
  }
  C.traj.erase(std::remove_if(C.traj.begin(), C.traj.end(),
                              [&](const std::vector<double>& s) {
                                return s.size() != C.grid.voxel_count();
                              }),
               C.traj.end());
  if (!cache_path.empty() && !C.traj.empty()) cache_save(cache_path, C);
  return C;
}

// ---------------------------------------------------------------------------
// THE MAINTAINER'S OWN REGIME, reproduced: PR 273's `ladder32.json`, which is
// committed evidence (evidence/2026-08-02-iteration-phase-timing/ladder32.json)
// of a run whose multigrid BUILDS and then STAGNATES, latching off at rung 0
// iteration 9. Rather than invent a fixture and hope it stagnates, this
// reassembles that job from the same public pieces run_job uses:
//
//   l-bracket.step @ resolution 32, fixture_faces = every cylindrical face of
//   radius 2.5 mm (the two O5 screw holes), gravity -Z at 9810 mm/s^2, whole-
//   domain design box [-35,-27.5,-6]..[45,27.5,64] with freeze_imported_part
//   false, ladder [0.68, 0.52, 0.38, 0.26], simp.max_iterations 16.
//
// The design box is ~9.2 part-volumes, so the optimiser drives the field to
// ~2-5 % density: thin, near-disconnecting members inside a mostly-void
// envelope, with ligaments below a coarse cell's width. That is the regime the
// task names, and it is where the shipped V-cycle is known to fail.
// ---------------------------------------------------------------------------
Case develop_stepbox(const std::string& step_path, int resolution,
                     const std::string& cache_path) {
  Case C;
  if (!cache_path.empty() && cache_load(cache_path, C)) {
    std::printf("   [cache hit %s: %zu trajectory snapshots]\n",
                cache_path.c_str(), C.traj.size());
    return C;
  }
  StepModel model = import_step_file(step_path);
  VoxelGrid part = voxelize(model.mesh, resolution);
  // fixture_faces: { kind: cylindrical, radius_mm: 2.5 } — the same geometric
  // rule the job schema specifies, applied to the imported face table.
  std::size_t tagged = 0;
  int matched = 0;
  for (int f = 0; f < model.face_count; ++f) {
    const StepFaceInfo& fi = model.faces[static_cast<std::size_t>(f)];
    if (fi.kind != StepSurfaceKind::Cylinder) continue;
    if (std::fabs(fi.cylinder_radius_mm - 2.5) > 1e-6) continue;
    ++matched;
    tagged += tag_step_face(part, model, f, VoxelTag::Fixture);
  }
  std::printf("   fixture_faces: %d cylindrical r=2.5 faces matched, %zu voxels "
              "tagged FIXTURE\n", matched, tagged);
  if (tagged == 0) {
    std::printf("   [no FIXTURE voxels tagged — resolution too coarse for the "
                "selected faces]\n");
    return C;
  }
  std::vector<DirichletBC> pbcs;
  for (const int n : fea_tagged_nodes(part, VoxelTag::Fixture))
    for (int c = 0; c < 3; ++c) pbcs.push_back({n, c, 0.0});

  DesignBox box;
  box.min = Vec3{-35.0, -27.5, -6.0};
  box.max = Vec3{45.0, 27.5, 64.0};

  MinimizePlasticOptions o;
  configure_production_options(o);
  o.volume_fraction_ladder = {0.68, 0.52, 0.38, 0.26};
  o.margin_stop = 1.5;
  o.gravity = 9810.0 * 1e-9;  // mm/s^2 x (g/cm^3 -> t/mm^3), as run_job folds it
  o.gravity_direction = Vec3{0.0, 0.0, -1.0};
  o.design_box = box;
  o.freeze_imported_part = false;
  o.simp.max_iterations = 16;
  // The trajectory must be the plain reference one: no accelerator may shape
  // the fields this sweep is then measured on.
  fea_set_krylov_recycling(false); fea_reset_krylov_recycle_space();
  fea_set_geneo_twolevel(false); fea_reset_geneo_basis();
  o.on_density_snapshot = [&C](const DensitySnapshotEvent& ev) {
    if (!ev.boundary && ev.density) C.traj.push_back(*ev.density);
  };
  SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  // PR 273 recorded that this job ABORTS in certification with a non-finite
  // margin once a rung goes ultra-dilute — a pre-existing defect of the
  // whole-domain box path, not of anything here. The trajectory captured up to
  // that point is exactly the stagnating material this sweep needs, so the
  // abort is caught and reported rather than allowed to end the probe.
  try {
    MinimizePlasticResult r =
        minimize_plastic(part, fdm_material(), "fdm", pbcs, rules, o);
    C.grid = r.solved_grid;
  } catch (const std::exception& e) {
    std::printf("   [ladder ended early: %s]\n", e.what());
  }
  // The pipeline's OWN node remap (not a tag re-scan): the expanded grid buries
  // the fixture voxels, so their node indices must be carried across, not
  // rediscovered. Built once — expand_design_domain is not cheap.
  const DesignDomain domain =
      expand_design_domain(part, box, {}, false, kDesignBoxCoarsenAlign);
  if (C.grid.voxel_count() == 0) C.grid = domain.grid;
  for (const DirichletBC& b : pbcs)
    C.bcs.push_back(
        {remap_node_to_domain(part, domain, b.node), b.component, b.value});
  // Self-weight is the design load, computed on the SOLVED grid exactly as the
  // pipeline computes it.
  C.loads = self_weight_loads(C.grid, fdm_material().density_g_cm3, o.gravity,
                              o.gravity_direction);
  C.traj.erase(std::remove_if(C.traj.begin(), C.traj.end(),
                              [&](const std::vector<double>& s) {
                                return s.size() != C.grid.voxel_count();
                              }),
               C.traj.end());
  if (!cache_path.empty() && !C.traj.empty()) cache_save(cache_path, C);
  return C;
}

// Develop the stagnating field through the REAL production ladder. The
// trajectory is captured by an observation sink, so it is the optimiser's own
// per-iteration physical density, not a reconstruction.
Case develop(int arm, int span, int ny, int t, double h, double vf, int max_iters,
             double hole_frac, const std::string& cache_path) {
  Case C;
  if (!cache_path.empty() && cache_load(cache_path, C)) {
    std::printf("   [cache hit %s: %zu trajectory snapshots]\n",
                cache_path.c_str(), C.traj.size());
    return C;
  }
  std::vector<DirichletBC> pbcs;
  VoxelGrid part = l_bracket(pbcs, arm, span, ny, t, h, hole_frac);
  const std::vector<NodalLoad> ploads =
      traction_loads(part, VoxelTag::Load, Vec3{0, 0, -30});
  const DesignBox box = stagnation_box(arm, span, ny, h);
  DesignDomain domain =
      expand_design_domain(part, box, {}, /*freeze_part=*/false, kDesignBoxCoarsenAlign);
  C.grid = domain.grid;
  for (const DirichletBC& b : pbcs)
    C.bcs.push_back({remap_node_to_domain(part, domain, b.node), b.component, b.value});
  for (const NodalLoad& l : ploads)
    C.loads.push_back({remap_node_to_domain(part, domain, l.node), l.component, l.value});

  MinimizePlasticOptions o;
  configure_production_options(o);
  o.volume_fraction_ladder = {vf};
  o.margin_stop = 0.0;
  o.external_loads = ploads;
  o.gravity = 0.0; o.gravity_direction = Vec3{0, 0, -1}; o.infill_percent = 100.0;
  o.design_box = box; o.freeze_imported_part = false;
  o.simp.max_iterations = max_iters;
  o.simp.mma_plateau_window = 0; o.simp.change_tol = 0.0;
  // The DEVELOPED FIELD must be the plain reference one: no accelerator may
  // shape the trajectory this sweep is then measured on.
  fea_set_krylov_recycling(false); fea_reset_krylov_recycle_space();
  fea_set_geneo_twolevel(false); fea_reset_geneo_basis();
  // The per-iteration ANALYSIS DENSITY snapshot: the same field the solver is
  // handed each design iteration, so the replayed trajectory is the optimiser's
  // own, not a reconstruction. It must go through the PIPELINE's event
  // (on_density_snapshot) — minimize_plastic installs its own
  // simp.density_observer and would overwrite one set directly.
  o.on_density_snapshot = [&C](const DensitySnapshotEvent& ev) {
    if (!ev.boundary && ev.density) C.traj.push_back(*ev.density);
  };
  SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  MinimizePlasticResult r =
      minimize_plastic(part, fdm_material(), "fdm", pbcs, rules, o);
  C.grid = r.solved_grid;
  if (C.traj.empty() && !r.evaluated.empty())
    C.traj.push_back(r.evaluated.back().optimization.physical_density);
  // Drop any snapshot that does not match the solved grid (a defensive guard;
  // the observer runs on the solved grid throughout).
  C.traj.erase(std::remove_if(C.traj.begin(), C.traj.end(),
                              [&](const std::vector<double>& s) {
                                return s.size() != C.grid.voxel_count();
                              }),
               C.traj.end());
  if (!cache_path.empty()) cache_save(cache_path, C);
  return C;
}

// ============================================================================
// A HEALTHY CONTROL (AB6): a well-connected, domain-filling cantilever whose
// multigrid converges today. Same instrument, same cells — the question it
// answers is whether a configuration that rescues stagnation HURTS the runs
// that already work.
// ============================================================================
Case healthy_case(int nx, int ny, int nz, double rho) {
  Case C;
  VoxelGrid& g = C.grid;
  g.nx = nx; g.ny = ny; g.nz = nz; g.spacing = 1.0; g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  for (int c = 0; c <= nz; ++c)
    for (int b = 0; b <= ny; ++b) {
      const int nd = fea_node_index(g, 0, b, c);
      C.bcs.push_back({nd, 0, 0.0});
      C.bcs.push_back({nd, 1, 0.0});
      C.bcs.push_back({nd, 2, 0.0});
    }
  for (int b = 0; b <= ny; ++b)
    C.loads.push_back({fea_node_index(g, nx, b, 0), 2, -100.0 / (ny + 1)});
  C.traj.push_back(std::vector<double>(g.voxel_count(), rho));
  return C;
}

// ============================================================================
// THE SWEEP GRID
// ============================================================================
struct Cfg {
  const char* name;
  MgTuning t;
};

// The harness's DIRECT-SOLVE BUDGET for the coarsest level. Capping hierarchy
// depth at 2 or 3 levels leaves a much larger coarsest operator, and the
// coarsest level is solved by a sparse LDLT factorisation whose fill-in grows
// far faster than its DOF count. Above this size the factorisation is not
// affordable on the machine of record, so the cell is REJECTED and reported as
// NOBUILD with its predicted size rather than being allowed to exhaust memory.
// That rejection is itself a finding: at production grid sizes a two-grid
// hierarchy is not expressible, whatever the iteration count would have been.
int direct_budget() {
  return std::getenv("MG_MAX_DIRECT") ? std::atoi(std::getenv("MG_MAX_DIRECT"))
                                      : 60000;
}

// Print the hierarchy geometry the builder will walk, so a NOBUILD cell can be
// read as "the coarsest level is this big" rather than as an unexplained gap.
void print_level_ladder(const VoxelGrid& g) {
  std::printf("   hierarchy geometry (upper-bound DOFs = 3 x nodes; the actual\n"
              "   active count is lower where DOFs are fixed or void):\n");
  int ex = g.nx, ey = g.ny, ez = g.nz;
  for (int L = 0; L < 8; ++L) {
    const long long dofs = 3LL * (ex + 1) * (ey + 1) * (ez + 1);
    std::printf("      level %d: %3dx%3dx%3d elems, <= %lld DOFs%s\n", L, ex, ey,
                ez, dofs,
                L == 0 ? "  (matrix-free; never factored)" : "");
    if ((ex & 1) || (ey & 1) || (ez & 1)) break;
    if (ex / 2 < 2 || ey / 2 < 2 || ez / 2 < 2) break;
    ex /= 2; ey /= 2; ez /= 2;
  }
  std::printf("   harness direct-solve budget: %d DOFs (MG_MAX_DIRECT)\n",
              direct_budget());
}

// Sweep A (levels), B (smoothing sweeps, uniform and coarse-only), C (cycle),
// D (smoother). E (omega) is applied only to the A-D winner, per the task.
std::vector<Cfg> sweep_grid() {
  std::vector<Cfg> v;
  auto add = [&](const char* name, MgTuning t) { v.push_back({name, t}); };

  MgTuning base;  // the shipped recipe

  // --- baseline -------------------------------------------------------------
  add("SHIPPED (4-ish lvl, V, 1+1, scalar w0.6)", base);

  // --- A. LEVELS ------------------------------------------------------------
  // The DOF cap must be raised for the shallow cells: at 2 or 3 levels the
  // coarsest operator is far larger than the shipped 6000-DOF cap, which would
  // reject the hierarchy outright and make the cell unmeasurable. Raising the
  // cap is what puts the SMO paper's two-grid claim on the table at all — and
  // the direct factorisation it implies is a REAL cost, reported in the build
  // column rather than hidden.
  for (int L : {2, 3, 4, 5}) {
    MgTuning t = base;
    t.max_levels = L;
    // `deepest` is what makes the DEPTH REQUEST binding. Without it the builder
    // stops at the first level under `coarse_dof_cap`, so raising that cap for
    // the shallow cells would silently prevent the DEEP ones from reaching the
    // depth they asked for — every cell would collapse onto the same hierarchy.
    // With it, `max_levels` alone decides where the walk stops and the cap
    // becomes purely an AFFORDABILITY test on the coarsest operator.
    t.deepest = true;
    t.coarse_dof_cap = direct_budget();
    char* nm = new char[64];
    std::snprintf(nm, 64, "A: levels=%d", L);
    add(nm, t);
  }
  { MgTuning t = base; t.deepest = true;
    add("A: levels=MAX (coarsen until an axis blocks)", t); }

  // --- B. SMOOTHING SWEEPS --------------------------------------------------
  for (int s : {2, 3}) {
    MgTuning t = base; t.pre_smooth = s; t.post_smooth = s;
    char* nm = new char[64];
    std::snprintf(nm, 64, "B: sweeps=%d+%d uniform", s, s);
    add(nm, t);
  }
  for (int e : {1, 2}) {
    MgTuning t = base; t.coarse_extra_smooth = e;
    char* nm = new char[64];
    std::snprintf(nm, 64, "B: sweeps=1+1 fine, +%d COARSE-ONLY", e);
    add(nm, t);
  }

  // --- C. CYCLE -------------------------------------------------------------
  { MgTuning t = base; t.cycle_gamma = 2; add("C: W-cycle (gamma=2)", t); }

  // --- D. SMOOTHER ----------------------------------------------------------
  { MgTuning t = base; t.smoother = MgSmoother::PointBlockJacobi; t.omega = 0.5;
    add("D: POINT-BLOCK Jacobi w0.5 (Peetz & Elbanna)", t); }
  { MgTuning t = base; t.smoother = MgSmoother::PointBlockJacobi; t.omega = 0.6;
    add("D: point-block w0.6 (weight held at shipped)", t); }

  return v;
}

// One measured cell.
//
// SHARED HOST. This machine runs other campaigns concurrently, and PR 273's
// handoff records exactly how that corrupted an earlier judgement ("several
// campaign runs shared the host, so NO wall ratio is cited as evidence"). Two
// defences are built in rather than assumed away:
//   * `matvecs` — the operator-apply count, DETERMINISTIC and load-independent.
//     It is the honest work unit, and it corroborates (or contradicts) the wall.
//   * repeats — every cell is measured MG_REPEATS times, ROUND-ROBIN across the
//     whole grid rather than back to back, so a burst of load cannot land on one
//     configuration. The MINIMUM wall is the least-contaminated sample and is
//     what the tables report; the spread is printed beside it so the reader can
//     see how noisy the host was.
struct Cell {
  std::string name;
  bool carried = false;   // MG reached tolerance (did NOT fall back)
  bool built = false;
  int levels = 0;
  int cycles = 0;
  long long matvecs = 0;  // deterministic work unit
  double build_ms = 0;    // hierarchy build (minimum over repeats)
  double cycle_ms = 0;    // the MG-CG V/W-cycle loop (minimum over repeats)
  double total_ms = 0;    // whole solve, entry to exit (minimum over repeats)
  double total_ms_max = 0;
  double resid = 0;
  double worst_du = 0;    // vs the exact reference field
  double rel_du = 0;
  int fallback_iters = 0;  // Jacobi-CG iterations after a stagnated MG attempt
  int samples = 0;
  // Keep the FASTEST repeat WHOLE rather than taking a per-column minimum: a
  // column-wise minimum can mix phases from different repeats, and then the
  // build + cycle columns no longer add up to the total they sit beside.
  void absorb(const Cell& r) {
    const int prior = samples;
    const double prior_max = total_ms_max;
    if (prior == 0 || r.total_ms < total_ms) {
      const std::string keep = name;
      *this = r;
      name = keep;
    }
    samples = prior + 1;
    total_ms_max = prior == 0 ? r.total_ms : std::max(prior_max, r.total_ms);
  }
};

// WHICH design iteration's field the sweep solves. Defaults to the trajectory's
// last snapshot; MG_SNAP picks one by index, which matters when the fixture
// LATCHES — after the latch fires the solver stops attempting multigrid, so the
// later snapshots carry no evidence about whether the V-cycle would have coped.
// The right field to sweep is one the SHIPPED configuration is known to stagnate
// on, and `stag` mode's per-iteration table is what identifies it.
const std::vector<double>& sweep_field(const Case& C) {
  std::size_t i = C.traj.size() - 1;
  if (const char* s = std::getenv("MG_SNAP")) {
    const long v = std::atol(s);
    if (v >= 0 && static_cast<std::size_t>(v) < C.traj.size())
      i = static_cast<std::size_t>(v);
  }
  std::printf("   sweeping design-iteration snapshot %zu of %zu\n", i,
              C.traj.size());
  return C.traj[i];
}

// Solve ONE frozen system at ONE configuration. The latch is reset first so
// every cell gets a genuine attempt, and the tuning is restored after.
Cell run_cell(const Cfg& c, const VoxelGrid& g, const std::vector<double>& ey,
              const Case& C, const std::vector<double>& ref, double ref_scale) {
  Cell out;
  out.name = c.name;
  fea_matfree_reset_mg_stagnation_latch();
  fea_detail::mg_set_tuning(c.t);
  CgInfo info;
  FeaSolution sol;
  bool threw = false;
  try {
    sol = fea_solve_mgcg_matfree(g, ey, kNu, C.bcs, C.loads, kCertTol, 0, &info);
  } catch (const std::exception& e) {
    threw = true;
    std::printf("      [%s THREW: %s]\n", c.name, e.what());
  }
  fea_detail::mg_reset_tuning();
  out.carried = info.used_multigrid;
  out.built = info.hier_built;
  out.levels = info.mg_levels;
  out.cycles = info.mg_cycles_attempted;
  out.build_ms = info.t_mg_build_ms;
  out.cycle_ms = info.t_mg_ms;
  out.total_ms = info.t_total_ms;
  out.total_ms_max = info.t_total_ms;
  out.matvecs = info.matvecs;
  out.fallback_iters = info.used_multigrid ? 0 : info.iterations;
  out.samples = 1;
  out.resid = info.residual;
  if (!threw && !ref.empty()) {
    for (std::size_t i = 0; i < ref.size(); ++i)
      out.worst_du = std::max(out.worst_du, std::fabs(sol.u[i] - ref[i]));
    out.rel_du = ref_scale > 0 ? out.worst_du / ref_scale : 0.0;
  }
  return out;
}

void print_header() {
  std::printf("\n%-46s %4s %7s %8s %10s %8s %8s %8s %8s %9s\n", "configuration",
              "lvls", "cycles", "carried", "matvecs", "build_s", "cycle_s",
              "TOTAL_s", "spread", "rel |du|");
  std::printf("%s\n", std::string(124, '-').c_str());
}

void print_cell(const Cell& c, double baseline_total_s) {
  const double tot = c.total_ms / 1e3;
  char verdict[40] = "";
  if (baseline_total_s > 0 && tot > 0) {
    const double r = baseline_total_s / tot;
    std::snprintf(verdict, sizeof verdict, "  %.2fx %s", r,
                  r >= 1.0 ? "" : "LOSS");
  }
  std::printf("%-46s %4d %7d %8s %10lld %8.3f %8.3f %8.3f %7.0f%% %9.2e%s\n",
              c.name.c_str(), c.levels, c.cycles,
              c.carried ? "YES" : (c.built ? "stag" : "NOBUILD"), c.matvecs,
              c.build_ms / 1e3, c.cycle_ms / 1e3, tot,
              tot > 0 ? 100.0 * (c.total_ms_max - c.total_ms) / c.total_ms : 0.0,
              c.rel_du, verdict);
}

void write_csv(FILE* f, const char* fixture, const Cell& c) {
  if (!f) return;
  std::fprintf(f, "%s,%s,%d,%d,%d,%d,%d,%lld,%.3f,%.3f,%.3f,%.3f,%d,%.6e,%.6e\n",
               fixture, c.name.c_str(), c.built ? 1 : 0, c.carried ? 1 : 0,
               c.levels, c.cycles, c.fallback_iters, c.matvecs, c.build_ms,
               c.cycle_ms, c.total_ms, c.total_ms_max, c.samples, c.resid,
               c.rel_du);
}

// The exact reference field for this system: the matrix-free Jacobi-CG path, the
// same exact solve production falls back to, at the same tolerance. Every
// configuration must reach this to solver tolerance (AB7).
std::vector<double> exact_reference(const VoxelGrid& g,
                                    const std::vector<double>& ey, const Case& C,
                                    double& scale_out, double& wall_s, int& iters) {
  fea_matfree_reset_mg_stagnation_latch();
  fea_detail::mg_reset_tuning();
  CgInfo info;
  const double t0 = now_ms();
  FeaSolution sol = fea_solve_cg_matfree(g, ey, kNu, C.bcs, C.loads, kCertTol, 0, &info);
  wall_s = (now_ms() - t0) / 1e3;
  iters = info.iterations;
  scale_out = 0;
  for (double v : sol.u) scale_out = std::max(scale_out, std::fabs(v));
  return sol.u;
}

// ============================================================================
// MODES
// ============================================================================
struct Fixture {
  Case C;
  std::vector<double> ey;
  std::vector<double> ref;
  double ref_scale = 0;
};

Case load_stag(const std::string& dir) {
  const int arm = std::getenv("MG_ARM") ? std::atoi(std::getenv("MG_ARM")) : 24;
  const int span = std::getenv("MG_SPAN") ? std::atoi(std::getenv("MG_SPAN")) : 24;
  const int ny = std::getenv("MG_NY") ? std::atoi(std::getenv("MG_NY")) : 6;
  const int t = std::getenv("MG_T") ? std::atoi(std::getenv("MG_T")) : 6;
  const double vf = std::getenv("MG_VF") ? std::atof(std::getenv("MG_VF")) : 0.26;
  const int iters = std::getenv("MG_ITERS") ? std::atoi(std::getenv("MG_ITERS")) : 20;
  const double hole = std::getenv("MG_HOLE") ? std::atof(std::getenv("MG_HOLE")) : 0.0;
  if (std::getenv("MG_OCCHOLE")) {
    const int nx = std::getenv("MG_NX") ? std::atoi(std::getenv("MG_NX")) : 32;
    const int nyy = std::getenv("MG_NYY") ? std::atoi(std::getenv("MG_NYY")) : 16;
    const int nz = std::getenv("MG_NZ") ? std::atoi(std::getenv("MG_NZ")) : 32;
    const int maxit = std::getenv("MG_MAXIT") ? std::atoi(std::getenv("MG_MAXIT")) : 60;
    char k3[256];
    std::snprintf(k3, sizeof k3, "%s/mg_occhole_%dx%dx%d_i%d.bin", dir.c_str(),
                  nx, nyy, nz, maxit);
    std::printf("   fixture: occ0.4+hole whole-domain design box %dx%dx%d, "
                "production ladder, max_iterations %d\n", nx, nyy, nz, maxit);
    return develop_occhole(nx, nyy, nz, 2.0, maxit, k3);
  }
  if (const char* sp = std::getenv("MG_STEP")) {
    const int res = std::getenv("MG_RES") ? std::atoi(std::getenv("MG_RES")) : 32;
    char k2[256];
    std::snprintf(k2, sizeof k2, "%s/mg_stepbox_r%d.bin", dir.c_str(), res);
    std::printf("   fixture: PR 273's ladder32 reproduction — %s @ resolution %d\n",
                sp, res);
    return develop_stepbox(sp, res, k2);
  }
  // The cache key carries every fixture parameter, so changing one can never
  // silently reuse a field developed for another.
  char key[256];
  std::snprintf(key, sizeof key, "%s/mg_stag_a%d_s%d_n%d_t%d_vf%.3f_i%d_h%.3f.bin",
                dir.c_str(), arm, span, ny, t, vf, iters, hole);
  std::printf("   fixture: arm=%d span=%d ny=%d t=%d vf=%.2f develop_iters=%d hole=%.2f\n",
              arm, span, ny, t, vf, iters, hole);
  return develop(arm, span, ny, t, 1.0, vf, iters, hole, key);
}

// STAG (AB2) — confirm the SHIPPED configuration genuinely stagnates here,
// BEFORE anything is swept. It walks the WHOLE design trajectory with the
// production latch live, because stagnation is a property of the field the
// optimiser reaches, not of one arbitrary snapshot: an early, fat design
// converges in tens of cycles and a late, dilute one may not converge at all.
// The per-iteration table is also the SHIPPED row of the latch-rate measurement.
int mode_stag(const std::string& dir) {
  std::printf("## STAG — does the SHIPPED configuration stagnate on this fixture?\n");
  const double t0 = now_ms();
  Case C = load_stag(dir);
  std::printf("   solved grid %dx%dx%d (%zu vox, %zu solid), %zu trajectory "
              "snapshots, develop wall %.1f s\n",
              C.grid.nx, C.grid.ny, C.grid.nz, C.grid.voxel_count(),
              C.grid.solid_count(), C.traj.size(), (now_ms() - t0) / 1e3);
  fea_set_krylov_recycling(false);
  fea_set_geneo_twolevel(false);
  fea_detail::mg_reset_tuning();
  fea_matfree_reset_mg_stagnation_latch();

  FILE* csv = std::fopen((dir + "/stag_trajectory.csv").c_str(), "w");
  if (csv)
    std::fprintf(csv, "design_iter,hier_built,levels,mg_cycles,carried,"
                      "build_ms,cycle_ms,fallback_ms,total_ms,fallback_iters,"
                      "latched\n");
  std::printf("\n%6s %6s %5s %8s %8s %9s %9s %9s %9s %8s\n", "iter", "built",
              "lvls", "cycles", "carried", "build_s", "cycle_s", "fallbk_s",
              "total_s", "latched");
  std::printf("%s\n", std::string(90, '-').c_str());

  int carried = 0, stagnated = 0, latched_at = -1;
  double tot = 0, build = 0, cyc = 0, fb = 0;
  for (std::size_t i = 0; i < C.traj.size(); ++i) {
    const std::vector<double> ey = penalized_youngs(C.grid, C.traj[i]);
    CgInfo info;
    try {
      FeaSolution s = fea_solve_mgcg_matfree(C.grid, ey, kNu, C.bcs, C.loads,
                                             kCertTol, 0, &info);
      (void)s;
    } catch (const std::exception& e) {
      std::printf("   [iter %zu THREW: %s]\n", i, e.what());
    }
    if (info.used_multigrid) ++carried;
    else if (info.hier_built) ++stagnated;
    const bool now_latched = fea_matfree_mg_stagnation_latched();
    if (latched_at < 0 && now_latched) latched_at = static_cast<int>(i);
    build += info.t_mg_build_ms / 1e3;
    cyc += info.t_mg_ms / 1e3;
    fb += info.t_cg_ms / 1e3;
    tot += info.t_total_ms / 1e3;
    std::printf("%6zu %6d %5d %8d %8s %9.2f %9.2f %9.2f %9.2f %8s\n", i,
                info.hier_built ? 1 : 0, info.mg_levels,
                info.mg_cycles_attempted, info.used_multigrid ? "YES" : "no",
                info.t_mg_build_ms / 1e3, info.t_mg_ms / 1e3,
                info.t_cg_ms / 1e3, info.t_total_ms / 1e3,
                now_latched ? "LATCHED" : "");
    if (csv)
      std::fprintf(csv, "%zu,%d,%d,%d,%d,%.3f,%.3f,%.3f,%.3f,%d,%d\n", i,
                   info.hier_built ? 1 : 0, info.mg_levels,
                   info.mg_cycles_attempted, info.used_multigrid ? 1 : 0,
                   info.t_mg_build_ms, info.t_mg_ms, info.t_cg_ms,
                   info.t_total_ms, info.iterations, now_latched ? 1 : 0);
    std::fflush(stdout);
  }
  if (csv) std::fclose(csv);

  const std::size_t n = C.traj.size();
  std::printf("\n   SHIPPED over %zu design iterations: carried %d, STAGNATED %d, "
              "latch %s\n", n, carried, stagnated,
              latched_at < 0 ? "never fired"
                             : ("fired at design iteration " +
                                std::to_string(latched_at)).c_str());
  std::printf("   wall: hierarchy build %.1f s | V-cycle loop %.1f s | Jacobi "
              "fallback %.1f s | TOTAL %.1f s\n", build, cyc, fb, tot);
  if (n)
    std::printf("   stagnations per 50 design iterations: %.1f\n",
                stagnated * 50.0 / static_cast<double>(n));
  const bool ok = stagnated > 0;
  std::printf("   => %s\n",
              ok ? "STAGNATES: the shipped V-cycle burns its full budget without "
                   "converging on real fields from this trajectory — the target regime"
                 : "does NOT stagnate on this fixture (wrong fixture for the sweep)");
  return ok ? 0 : 2;
}

int mode_sweep(const std::string& dir, bool healthy) {
  // The healthy control is scale-matched to the stagnating fixture by default,
  // so "does the winner hurt healthy runs?" is not answered at a different size.
  const int hx = std::getenv("MG_HX") ? std::atoi(std::getenv("MG_HX")) : 96;
  const int hy = std::getenv("MG_HY") ? std::atoi(std::getenv("MG_HY")) : 48;
  const int hz = std::getenv("MG_HZ") ? std::atoi(std::getenv("MG_HZ")) : 96;
  const double hrho = std::getenv("MG_HRHO") ? std::atof(std::getenv("MG_HRHO")) : 0.6;
  Case C = healthy ? healthy_case(hx, hy, hz, hrho) : load_stag(dir);
  const char* fixture = healthy ? "healthy" : "stagnating";
  std::printf("## SWEEP on the %s fixture: grid %dx%dx%d (%zu vox)\n", fixture,
              C.grid.nx, C.grid.ny, C.grid.nz, C.grid.voxel_count());
  print_level_ladder(C.grid);
  fea_set_krylov_recycling(false);
  fea_set_geneo_twolevel(false);
  const std::vector<double> ey = penalized_youngs(C.grid, sweep_field(C));

  double scale = 0, ref_s = 0;
  int ref_it = 0;
  std::printf("   building the EXACT reference field (matrix-free Jacobi-CG)...\n");
  const std::vector<double> ref = exact_reference(C.grid, ey, C, scale, ref_s, ref_it);
  std::printf("   reference: %d Jacobi-CG iterations, %.2f s, max|u| = %.4e\n",
              ref_it, ref_s, scale);

  FILE* csv = std::fopen((dir + "/sweep_" + fixture + ".csv").c_str(), "w");
  if (csv)
    std::fprintf(csv, "fixture,config,built,carried,levels,cycles,"
                      "fallback_iters,matvecs,build_ms,cycle_ms,total_ms_min,"
                      "total_ms_max,samples,residual,rel_du\n");

  print_load("sweep start");
  const std::vector<Cfg> grid = sweep_grid();
  const int repeats = std::getenv("MG_REPEATS") ? std::atoi(std::getenv("MG_REPEATS")) : 3;
  std::printf("   %d repeats, ROUND-ROBIN across the grid (shared host: the "
              "minimum wall is the least-contaminated sample)\n", repeats);
  std::vector<Cell> cells(grid.size());
  for (std::size_t i = 0; i < grid.size(); ++i) cells[i].name = grid[i].name;
  for (int r = 0; r < repeats; ++r) {
    std::printf("   [round %d/%d]\n", r + 1, repeats);
    for (std::size_t i = 0; i < grid.size(); ++i) {
      Cell one = run_cell(grid[i], C.grid, ey, C, ref, scale);
      cells[i].absorb(one);
      std::fflush(stdout);
    }
  }
  print_header();
  double baseline_s = cells.empty() ? 0 : cells[0].total_ms / 1e3;
  double worst_rel = 0;
  for (std::size_t i = 0; i < cells.size(); ++i) {
    print_cell(cells[i], i == 0 ? 0 : baseline_s);
    write_csv(csv, fixture, cells[i]);
    if (cells[i].carried) worst_rel = std::max(worst_rel, cells[i].rel_du);
  }

  // Sweep E: omega, on the A-D winner only (fastest total wall among the cells
  // that CARRIED; if none carried, the sweep has no winner and E is skipped —
  // which is itself the result).
  int best = -1;
  for (std::size_t i = 0; i < cells.size(); ++i)
    if (cells[i].carried && (best < 0 || cells[i].total_ms < cells[best].total_ms))
      best = static_cast<int>(i);
  if (best >= 0) {
    std::printf("\n   E. OMEGA on the A-D winner (%s):\n", cells[best].name.c_str());
    print_header();
    for (double w : {0.6, 0.5}) {
      Cfg c = grid[static_cast<std::size_t>(best)];
      c.t.omega = w;
      char nm[80];
      std::snprintf(nm, sizeof nm, "E: winner @ omega=%.2f", w);
      c.name = nm;
      Cell cell;
      cell.name = nm;
      for (int r = 0; r < repeats; ++r)
        cell.absorb(run_cell(c, C.grid, ey, C, ref, scale));
      cell.name = nm;
      print_cell(cell, baseline_s);
      write_csv(csv, fixture, cell);
      if (cell.carried) worst_rel = std::max(worst_rel, cell.rel_du);
      std::fflush(stdout);
    }
  } else {
    std::printf("\n   E. OMEGA skipped: NO configuration carried multigrid on "
                "this fixture, so there is no A-D winner to refine.\n");
  }

  if (csv) std::fclose(csv);
  print_load("sweep end");
  std::printf("\n   AB7 EXACTNESS: worst relative displacement deviation across "
              "every CARRYING cell = %.3e (bar: solver tolerance %.1e)\n",
              worst_rel, kCertTol);
  return 0;
}

// RESCUE — the question the task ends on: once a configuration IS stagnating,
// does ANY lever bring it back?
//
// Sweep A established that hierarchy DEPTH is what stagnates this solver: on the
// dilute design-box field, 3 levels converges in 70 cycles, 4 in 195, and 5
// burns the whole 300-cycle budget without converging. That last one is a
// genuinely stagnating configuration on a REAL field — the maintainer's
// signature (hier_built=1, cg_multigrid=0) reproduced by moving one variable.
//
// So it is the right patient. Every lever B/C/D/E offers is applied ON TOP of
// it, and the answer is simply whether the solve converges inside the budget.
// A lever that cannot rescue this cannot rescue the maintainer's run either.
int mode_rescue(const std::string& dir) {
  Case C = load_stag(dir);
  std::printf("## RESCUE — can any lever save a STAGNATING configuration?\n");
  print_level_ladder(C.grid);
  fea_set_krylov_recycling(false);
  fea_set_geneo_twolevel(false);
  const std::vector<double> ey = penalized_youngs(C.grid, sweep_field(C));
  double scale = 0, ref_s = 0;
  int ref_it = 0;
  const std::vector<double> ref = exact_reference(C.grid, ey, C, scale, ref_s, ref_it);
  std::printf("   reference: %d Jacobi-CG iterations, %.2f s, max|u| = %.4e\n",
              ref_it, ref_s, scale);

  // The patient: the DEEPEST hierarchy the builder can express, which sweep A
  // measured as stagnating on this field.
  MgTuning sick;
  sick.deepest = true;
  sick.coarse_dof_cap = direct_budget();

  std::vector<Cfg> v;
  auto add = [&](const char* n, MgTuning t) { v.push_back({n, t}); };
  add("STAGNATING BASELINE (deepest hierarchy)", sick);
  { MgTuning t = sick; t.pre_smooth = 2; t.post_smooth = 2; add("+ 2+2 uniform smoothing", t); }
  { MgTuning t = sick; t.pre_smooth = 3; t.post_smooth = 3; add("+ 3+3 uniform smoothing", t); }
  { MgTuning t = sick; t.coarse_extra_smooth = 1; add("+ 1 extra COARSE-ONLY sweep", t); }
  { MgTuning t = sick; t.coarse_extra_smooth = 2; add("+ 2 extra COARSE-ONLY sweeps", t); }
  { MgTuning t = sick; t.cycle_gamma = 2; add("+ W-cycle", t); }
  { MgTuning t = sick; t.smoother = MgSmoother::PointBlockJacobi; t.omega = 0.5;
    add("+ POINT-BLOCK Jacobi w0.5", t); }
  { MgTuning t = sick; t.smoother = MgSmoother::PointBlockJacobi; t.omega = 0.6;
    add("+ point-block w0.6", t); }
  { MgTuning t = sick; t.omega = 0.5; add("+ omega 0.5", t); }
  { MgTuning t = sick; t.cycle_gamma = 2;
    t.smoother = MgSmoother::PointBlockJacobi; t.omega = 0.5;
    add("+ W-cycle AND point-block w0.5", t); }
  { MgTuning t = sick; t.cycle_gamma = 2; t.coarse_extra_smooth = 1;
    t.smoother = MgSmoother::PointBlockJacobi; t.omega = 0.5;
    add("+ W-cycle AND point-block AND coarse sweep", t); }
  // The control: the lever sweep A says works — one level shallower.
  { MgTuning t; t.deepest = true; t.max_levels = 3; t.coarse_dof_cap = direct_budget();
    add("CONTROL: one level SHALLOWER (levels=3)", t); }

  FILE* csv = std::fopen((dir + "/rescue.csv").c_str(), "w");
  if (csv)
    std::fprintf(csv, "config,built,carried,levels,cycles,fallback_iters,matvecs,"
                      "build_ms,cycle_ms,total_ms,rel_du\n");
  print_header();
  for (const Cfg& c : v) {
    Cell cell = run_cell(c, C.grid, ey, C, ref, scale);
    print_cell(cell, 0);
    if (csv)
      std::fprintf(csv, "%s,%d,%d,%d,%d,%d,%lld,%.3f,%.3f,%.3f,%.6e\n", c.name,
                   cell.built ? 1 : 0, cell.carried ? 1 : 0, cell.levels,
                   cell.cycles, cell.fallback_iters, cell.matvecs, cell.build_ms,
                   cell.cycle_ms, cell.total_ms, cell.rel_du);
    std::fflush(stdout);
  }
  if (csv) std::fclose(csv);
  std::printf("\n   READ: 'carried YES' = the lever RESCUED the stagnating "
              "configuration.\n   'stag' = it did not.\n");
  return 0;
}

// LATCH (AB3) — replay the DESIGN TRAJECTORY under each configuration with the
// production latch live, and report stagnations per 50 design iterations and
// whether the latch fired. This is the headline number: the goal is not fewer
// cycles, it is MG STAYING ALIVE.
int mode_latch(const std::string& dir) {
  Case C = load_stag(dir);
  // A CONTIGUOUS window of the trajectory, not a strided sample: the latch fires
  // on CONSECUTIVE stagnations, so skipping iterations would change the very
  // quantity being measured. The default window is the TAIL — the most dilute,
  // thinnest-membered designs, where stagnation lives.
  const std::size_t total = C.traj.size();
  std::size_t win = std::getenv("MG_LATCH_N")
                        ? static_cast<std::size_t>(std::atoi(std::getenv("MG_LATCH_N")))
                        : 12;
  if (win > total) win = total;
  const std::size_t from = total - win;
  const std::size_t n = win;
  std::printf("## LATCH RATE on the stagnating trajectory: design iterations "
              "[%zu, %zu) of %zu (a contiguous TAIL window), grid %dx%dx%d\n",
              from, total, total, C.grid.nx, C.grid.ny, C.grid.nz);
  print_level_ladder(C.grid);
  std::printf("   LIMIT, stated plainly: the trajectory was DEVELOPED under the "
              "shipped configuration.\n"
              "   A configuration that rescued multigrid would steer a slightly "
              "different design.\n"
              "   What is compared here is every configuration against the SAME "
              "sequence of real fields.\n");
  fea_set_krylov_recycling(false);
  fea_set_geneo_twolevel(false);

  FILE* csv = std::fopen((dir + "/latch_rate.csv").c_str(), "w");
  if (csv)
    std::fprintf(csv, "config,iters,carried,stagnated,latched_at,total_s,"
                      "build_s,cycle_s,fallback_s\n");

  std::printf("\n%-46s %7s %9s %10s %10s %10s %10s\n", "configuration", "carried",
              "stagnated", "latched@", "build_s", "cycle_s", "TOTAL_s");
  std::printf("%s\n", std::string(106, '-').c_str());

  for (const Cfg& c : sweep_grid()) {
    fea_matfree_reset_mg_stagnation_latch();
    int carried = 0, stagnated = 0, latched_at = -1;
    double build_s = 0, cycle_s = 0, fb_s = 0, tot_s = 0;
    for (std::size_t w = 0; w < n; ++w) {
      const std::size_t i = from + w;
      const std::vector<double> ey = penalized_youngs(C.grid, C.traj[i]);
      fea_detail::mg_set_tuning(c.t);
      CgInfo info;
      try {
        FeaSolution s = fea_solve_mgcg_matfree(C.grid, ey, kNu, C.bcs, C.loads,
                                               kCertTol, 0, &info);
        (void)s;
      } catch (const std::exception&) {
      }
      fea_detail::mg_reset_tuning();
      if (info.used_multigrid) ++carried;
      else if (info.hier_built) ++stagnated;
      if (latched_at < 0 && fea_matfree_mg_stagnation_latched())
        latched_at = static_cast<int>(w);
      build_s += info.t_mg_build_ms / 1e3;
      cycle_s += info.t_mg_ms / 1e3;
      fb_s += info.t_cg_ms / 1e3;
      tot_s += info.t_total_ms / 1e3;
    }
    std::printf("%-46s %7d %9d %10s %10.2f %10.2f %10.2f\n", c.name,
                carried, stagnated,
                latched_at < 0 ? "never" : std::to_string(latched_at).c_str(),
                build_s, cycle_s, tot_s);
    if (csv)
      std::fprintf(csv, "%s,%zu,%d,%d,%d,%.3f,%.3f,%.3f,%.3f\n", c.name, n,
                   carried, stagnated, latched_at, tot_s, build_s, cycle_s, fb_s);
    std::fflush(stdout);
  }
  if (csv) std::fclose(csv);
  std::printf("\n   Scaled to 50 design iterations: multiply the stagnated column "
              "by %.2f.\n", 50.0 / (n ? static_cast<double>(n) : 1.0));
  return 0;
}

// DET (AB8) — byte-identical rerun at a named configuration.
int mode_det(const std::string& dir) {
  Case C = load_stag(dir);
  fea_set_krylov_recycling(false);
  fea_set_geneo_twolevel(false);
  const std::vector<double> ey = penalized_youngs(C.grid, C.traj.back());
  const char* which = std::getenv("MG_DET_CFG");
  const std::vector<Cfg> grid = sweep_grid();
  Cfg chosen = grid.front();
  if (which)
    for (const Cfg& c : grid)
      if (std::strstr(c.name, which)) { chosen = c; break; }
  std::printf("## DET at configuration: %s\n", chosen.name);
  auto run = [&](std::uint64_t& h, int& cycles, bool& carried) {
    Cell cell;
    fea_matfree_reset_mg_stagnation_latch();
    fea_detail::mg_set_tuning(chosen.t);
    CgInfo info;
    FeaSolution s = fea_solve_mgcg_matfree(C.grid, ey, kNu, C.bcs, C.loads,
                                           kCertTol, 0, &info);
    fea_detail::mg_reset_tuning();
    Fnv f;
    for (double v : s.u) f.add_d(v);
    h = f.h;
    cycles = info.mg_cycles_attempted;
    carried = info.used_multigrid;
    (void)cell;
  };
  std::uint64_t h1, h2;
  int c1, c2;
  bool m1, m2;
  run(h1, c1, m1);
  run(h2, c2, m2);
  std::printf("   run 1: fnv=%016llx cycles=%d carried=%d\n",
              (unsigned long long)h1, c1, m1);
  std::printf("   run 2: fnv=%016llx cycles=%d carried=%d\n",
              (unsigned long long)h2, c2, m2);
  const bool ok = (h1 == h2) && (c1 == c2) && (m1 == m2);
  std::printf("   => %s\n", ok ? "BYTE-IDENTICAL" : "NOT DETERMINISTIC");
  return ok ? 0 : 1;
}

}  // namespace

int main(int argc, char** argv) {
  const std::string mode = argc > 1 ? argv[1] : "stag";
  const std::string dir = argc > 2 ? argv[2] : ".";
  std::setvbuf(stdout, nullptr, _IOLBF, 0);
  if (mode == "stag") return mode_stag(dir);
  if (mode == "sweep") return mode_sweep(dir, /*healthy=*/false);
  if (mode == "healthy") return mode_sweep(dir, /*healthy=*/true);
  if (mode == "latch") return mode_latch(dir);
  if (mode == "rescue") return mode_rescue(dir);
  if (mode == "det") return mode_det(dir);
  std::printf("usage: mg_component_sweep <stag|sweep|healthy|latch|rescue|det> [csvdir]\n");
  return 2;
}
