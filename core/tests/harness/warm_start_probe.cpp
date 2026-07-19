// warm_start_probe.cpp — measurement harness (NOT a CI test) for handoff 110.
//
// Drives minimize_plastic on two fixtures — the thin L-bracket LOADCASE (the same
// part the 080/082/ladder gates build) and a SELF-WEIGHT block — and prints, per
// rung: iterations-to-termination, wall-clock, achieved fraction, worst-case
// margin, and a density-difference summary against the cold run. Modes:
//   cold   : the shipping path (both warm-start features OFF) — the STEP 0 baseline.
//   warmA  : rung-to-rung inheritance ON (Part A).
//   warmB  : coarse-to-fine cascade ON (Part B).
//   warmAB : both ON.
// With no argument it runs all four and prints a cold-vs-warm comparison table.
//
// This file lives under tests/harness and is compiled standalone (see the handoff
// build line); it is not wired into CTest. It reads rules.json from SETTINGS_RULES_PATH.

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {

// The thin L-bracket the 080/082/ladder gates build (test_ladder_rung_count).
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

// A cantilever block fixed on one face, optimized under SELF-WEIGHT (no external
// load). Deliberately a different load mode than the L-bracket.
VoxelGrid self_weight_block(std::vector<DirichletBC>& bcs, int nx, int ny, int nz,
                            double h) {
  VoxelGrid g;
  g.nx = nx; g.ny = ny; g.nz = nz; g.spacing = h;
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

Material fdm_material() {
  Material m;
  m.youngs_modulus_mpa = 3500.0; m.yield_strength_mpa = 55.0;
  m.density_g_cm3 = 1.24; m.z_knockdown = 0.55; m.poisson = 0.33; m.family = "fdm";
  return m;
}

struct Mode { bool inherit; bool coarse; const char* name; };

// mean |rho_a - rho_b| over the two fields (same length assumed).
double mean_abs_diff(const std::vector<double>& a, const std::vector<double>& b) {
  if (a.size() != b.size() || a.empty()) return -1.0;
  double s = 0.0;
  for (std::size_t i = 0; i < a.size(); ++i) s += std::fabs(a[i] - b[i]);
  return s / static_cast<double>(a.size());
}

void run_fixture(const char* label, const VoxelGrid& part,
                 const std::vector<DirichletBC>& bcs,
                 const std::vector<NodalLoad>& loads, const SettingsRules& rules,
                 const Material& material) {
  const std::vector<Mode> modes = {
      {false, false, "cold  "},
      {true, false, "warmA "},
      {false, true, "warmB "},
      {true, true, "warmAB"},
  };

  std::printf("\n===== %s (grid %dx%dx%d, %zu solid voxels) =====\n", label,
              part.nx, part.ny, part.nz, part.solid_count());

  std::vector<double> cold_last_density;  // for density-difference summary
  for (const Mode& m : modes) {
    MinimizePlasticOptions o;
    o.volume_fraction_ladder = {0.68, 0.52, 0.38, 0.26};
    o.margin_stop = 1.5;
    o.external_loads = loads;         // empty => self-weight
    o.gravity = 9810.0 * 1e-9;
    o.gravity_direction = Vec3{0.0, 0.0, -1.0};
    o.updater = SimpUpdater::MMA;
    o.infill_percent = 100.0;
    o.warm_start_inherit = m.inherit;
    o.warm_start_coarse = m.coarse;

    const auto t0 = std::chrono::steady_clock::now();
    const MinimizePlasticResult r =
        minimize_plastic(part, material, "fdm", bcs, rules, o);
    const auto t1 = std::chrono::steady_clock::now();
    const double wall =
        std::chrono::duration<double>(t1 - t0).count();

    int total_iters = 0;
    for (const auto& v : r.evaluated) total_iters += v.optimization.iterations;
    const int coarse_iters = r.warm_start_coarse_iterations;
    const int grand_total = total_iters + coarse_iters;

    std::printf("[%s] rungs=%zu fine_iters=%d coarse_iters=%d GRAND_TOTAL=%d wall=%.2fs\n",
                m.name, r.evaluated.size(), total_iters, coarse_iters,
                grand_total, wall);
    for (std::size_t i = 0; i < r.evaluated.size(); ++i) {
      const auto& v = r.evaluated[i];
      std::printf("    rung %zu vf=%.2f: iters=%3d  achieved=%.4f  margin=%.3f  %s\n",
                  i, v.requested_volume_fraction, v.optimization.iterations,
                  v.optimization.volume_fraction, v.report.margin.worst_case,
                  v.accepted ? "accept" : "REJECT");
    }
    if (!r.evaluated.empty()) {
      const std::vector<double>& last =
          r.evaluated.back().optimization.physical_density;
      if (!m.inherit && !m.coarse) {
        cold_last_density = last;
      } else if (!cold_last_density.empty()) {
        const double d = mean_abs_diff(cold_last_density, last);
        std::printf("    density-diff vs cold (terminal rung): mean|drho|=%.5f\n", d);
      }
    }
  }
}

}  // namespace

int main(int argc, char** argv) {
  (void)argc; (void)argv;
  SettingsRules rules;
  try {
    rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "FAIL: could not load rules.json: %s\n", e.what());
    return 1;
  }
  const Material material = fdm_material();

  // Fixture 1: the L-bracket LOADCASE (external tip load).
  {
    const int arm = 8, span = 8, ny = 3, t = 2;
    const double h = 2.0;
    std::vector<DirichletBC> bcs;
    VoxelGrid part = l_bracket(bcs, arm, span, ny, t, h);
    const std::vector<NodalLoad> tip =
        traction_loads(part, VoxelTag::Load, Vec3{0.0, 0.0, -5.0});
    run_fixture("L-BRACKET LOADCASE", part, bcs, tip, rules, material);
  }

  // Fixture 2: SELF-WEIGHT cantilever block (no external load).
  {
    std::vector<DirichletBC> bcs;
    VoxelGrid part = self_weight_block(bcs, 16, 8, 8, 2.0);
    run_fixture("SELF-WEIGHT BLOCK", part, bcs, /*loads=*/{}, rules, material);
  }

  return 0;
}
