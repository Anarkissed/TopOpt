// MEASUREMENT-ONLY probe, task 2026-08-20-lattice-only-grading §4(b)(ii).
//
// "What FRACTION OF TRACED STRUTS VIOLATE THE OVERHANG LIMIT on his part?"
// An internal lattice strut CANNOT be supported — support cannot be removed from a
// sealed lattice — so the 45-degrees-from-vertical rule is a hard constraint on any
// traced (GRADED) lattice, and it must be applied DURING tracing.
//
// This is the GATE measurement for scoping graded. It builds the load case through
// CORE'S OWN seam (load_job_file -> production_loadcase_from_job ->
// build_production_loadcase -> analyze_fixed_design), so the field it traces is the
// field production solves.
//
// POSITIVE CONTROL, printed and checked first: the peak von Mises must reproduce the
// production analyze run's value. If it does not, the probe is describing a
// different load case and every angle below is meaningless.
//
// METHOD (the one §4(c) names, minus the lattice):
//   * eigen-decompose the per-voxel symmetric stress tensor (Jacobi, deterministic)
//   * RK4-trace along the MAJOR principal direction from seeds on a fixed lattice
//   * measure each traced step against the 45-degrees-from-vertical overhang limit
// No spacing field and no connectors: the question is only what fraction of traced
// arc-length is unbuildable, which does not depend on how the curves are thinned.

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "topopt/analyze.hpp"
#include "topopt/fea.hpp"
#include "topopt/job.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/materials.hpp"
#include "topopt/part.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {

// Symmetric 3x3 eigen-decomposition by cyclic Jacobi. Deterministic: a fixed sweep
// order, a fixed iteration cap, no RNG (bar §1b).
void jacobi3(const double A_in[6], double evec[3][3], double eval[3]) {
  double a[3][3] = {{A_in[0], A_in[3], A_in[5]},
                    {A_in[3], A_in[1], A_in[4]},
                    {A_in[5], A_in[4], A_in[2]}};
  for (int i = 0; i < 3; ++i)
    for (int j = 0; j < 3; ++j) evec[i][j] = (i == j) ? 1.0 : 0.0;
  for (int sweep = 0; sweep < 24; ++sweep) {
    double off = std::fabs(a[0][1]) + std::fabs(a[0][2]) + std::fabs(a[1][2]);
    if (off < 1e-18) break;
    for (int p = 0; p < 2; ++p)
      for (int q = p + 1; q < 3; ++q) {
        if (std::fabs(a[p][q]) < 1e-20) continue;
        const double theta = (a[q][q] - a[p][p]) / (2.0 * a[p][q]);
        const double t = (theta >= 0.0 ? 1.0 : -1.0) /
                         (std::fabs(theta) + std::sqrt(theta * theta + 1.0));
        const double c = 1.0 / std::sqrt(t * t + 1.0), s = t * c;
        for (int k = 0; k < 3; ++k) {
          const double akp = a[k][p], akq = a[k][q];
          a[k][p] = c * akp - s * akq;
          a[k][q] = s * akp + c * akq;
        }
        for (int k = 0; k < 3; ++k) {
          const double apk = a[p][k], aqk = a[q][k];
          a[p][k] = c * apk - s * aqk;
          a[q][k] = s * apk + c * aqk;
        }
        for (int k = 0; k < 3; ++k) {
          const double vkp = evec[k][p], vkq = evec[k][q];
          evec[k][p] = c * vkp - s * vkq;
          evec[k][q] = s * vkp + c * vkq;
        }
      }
  }
  for (int i = 0; i < 3; ++i) eval[i] = a[i][i];
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: %s <job.json> <materials.json> [expected_peak_mpa]\n", argv[0]);
    return 2;
  }
  const std::string job_path = argv[1];
  const std::string materials_path = argv[2];
  const double expected_peak = argc > 3 ? std::atof(argv[3]) : 0.0;

  const JobDescription job = load_job_file(job_path);
  const std::string dir = job_path.substr(0, job_path.find_last_of('/'));
  const StepModel model = import_part_file(dir + "/" + job.model);
  const MaterialLibrary lib = load_materials_file(materials_path);
  const auto mit = lib.find(job.material);
  if (mit == lib.end()) { std::fprintf(stderr, "no material %s\n", job.material.c_str()); return 2; }
  const Material mat = mit->second;

  const ProductionLoadCase lc = production_loadcase_from_job(job, model);
  ProductionRunSetup setup = build_production_loadcase(model, job.resolution, lc);
  const VoxelGrid& grid = setup.grid;

  std::vector<double> density(grid.voxel_count(), 0.0);
  std::size_t solid = 0;
  for (std::size_t i = 0; i < grid.tags.size(); ++i)
    if (grid.tags[i] != VoxelTag::Empty) { density[i] = 1.0; ++solid; }

  SimpParams sp;
  sp.youngs_modulus = mat.youngs_modulus_mpa;
  sp.poisson = mat.poisson;
  KnockdownSpec kd;
  const FixedDesignAnalysis a = analyze_fixed_design(
      grid, sp, density, setup.bcs, setup.options.external_loads, mat,
      Vec3{0.0, 0.0, 1.0}, 1e-8, 0, SolverKind::JacobiCG, 1.5, kd, true,
      static_cast<double>(solid));
  if (a.non_convergent) { std::fprintf(stderr, "REFUSING: non-convergent solve\n"); return 3; }

  double peak = 0.0;
  for (std::size_t e = 0; e < a.von_mises_field.size(); ++e)
    if (density[e] > 0.5 && a.von_mises_field[e] > peak) peak = a.von_mises_field[e];
  std::printf("grid %dx%dx%d  spacing %.6f  solid %zu\n", grid.nx, grid.ny, grid.nz,
              grid.spacing, solid);
  std::printf("peak von Mises %.10g MPa", peak);
  if (expected_peak > 0.0) {
    const double rel = std::fabs(peak - expected_peak) / expected_peak;
    std::printf("   expected %.10g   rel err %.3e\n", expected_peak, rel);
    if (rel > 1e-6) {
      std::fprintf(stderr, "REFUSING: this is not the production load case.\n");
      return 3;
    }
  } else { std::printf("\n"); }
  if (a.stress_tensor_field.size() != 6 * grid.voxel_count()) {
    std::fprintf(stderr, "REFUSING: no stress tensor field (size %zu)\n",
                 a.stress_tensor_field.size());
    return 3;
  }

  // ── the major principal direction per voxel ─────────────────────────────────
  // ALL THREE families, ordered by |eigenvalue| descending. The 45-degree limit
  // binds on EVERY family a graded lattice would trace, so reporting only the
  // major one would understate the constraint.
  std::vector<std::array<float, 3>> dir_fam[3] = {
      std::vector<std::array<float, 3>>(grid.voxel_count(), {0, 0, 0}),
      std::vector<std::array<float, 3>>(grid.voxel_count(), {0, 0, 0}),
      std::vector<std::array<float, 3>>(grid.voxel_count(), {0, 0, 0})};
  for (std::size_t e = 0; e < grid.voxel_count(); ++e) {
    if (density[e] <= 0.5) continue;
    double A[6];
    for (int c = 0; c < 6; ++c) A[c] = a.stress_tensor_field[6 * e + c];
    double V[3][3], w[3];
    jacobi3(A, V, w);
    int idx[3] = {0, 1, 2};
    for (int i = 0; i < 3; ++i)
      for (int j = i + 1; j < 3; ++j)
        if (std::fabs(w[idx[j]]) > std::fabs(w[idx[i]])) std::swap(idx[i], idx[j]);
    for (int f = 0; f < 3; ++f)
      dir_fam[f][e] = {static_cast<float>(V[0][idx[f]]),
                       static_cast<float>(V[1][idx[f]]),
                       static_cast<float>(V[2][idx[f]])};
  }
  const std::vector<std::array<float, 3>>* active = nullptr;

  auto sample = [&](const Vec3& p, Vec3& d) -> bool {
    const int i = static_cast<int>((p.x - grid.origin.x) / grid.spacing);
    const int j = static_cast<int>((p.y - grid.origin.y) / grid.spacing);
    const int k = static_cast<int>((p.z - grid.origin.z) / grid.spacing);
    if (i < 0 || j < 0 || k < 0 || i >= grid.nx || j >= grid.ny || k >= grid.nz) return false;
    const std::size_t e = grid.index(i, j, k);
    if (density[e] <= 0.5) return false;
    d = Vec3{(*active)[e][0], (*active)[e][1], (*active)[e][2]};
    const double n = std::sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
    if (!(n > 1e-12)) return false;
    d.x /= n; d.y /= n; d.z /= n;
    return true;
  };

  // ── RK4 trace from a fixed seed lattice; every step scored for overhang ─────
  // The overhang limit: a strut is buildable when its axis is within 45 degrees of
  // VERTICAL, i.e. |dz| >= cos(45) = sqrt(1/2) for a unit axis. Below that it is an
  // unsupportable bridge, and an internal lattice cannot be supported.
  const double kCos45 = std::sqrt(0.5);
  const double h = grid.spacing * 0.5;
  const int kMaxSteps = 400;
  const int kSeedStride = 4;
  const char* fam_name[3] = {"MAJOR  (largest |sigma|)", "MIDDLE", "MINOR  (smallest |sigma|)"};
  long long all_total = 0, all_viol = 0;
  for (int fam = 0; fam < 3; ++fam) {
  active = &dir_fam[fam];
  long long steps_total = 0, steps_violating = 0, seeds = 0;
  std::vector<long long> hist(9, 0);   // 0-10,10-20,...,80-90 degrees from vertical

  for (int k = 0; k < grid.nz; k += kSeedStride)
    for (int j = 0; j < grid.ny; j += kSeedStride)
      for (int i = 0; i < grid.nx; i += kSeedStride) {
        const std::size_t e = grid.index(i, j, k);
        if (density[e] <= 0.5) continue;
        ++seeds;
        for (int sgn = -1; sgn <= 1; sgn += 2) {
          Vec3 p{grid.origin.x + (i + 0.5) * grid.spacing,
                 grid.origin.y + (j + 0.5) * grid.spacing,
                 grid.origin.z + (k + 0.5) * grid.spacing};
          Vec3 prev{0, 0, 0};
          bool have_prev = false;
          for (int s = 0; s < kMaxSteps; ++s) {
            Vec3 k1, k2, k3, k4;
            if (!sample(p, k1)) break;
            // keep the field's sign continuous along the curve (eigenvectors have
            // no intrinsic sign; flipping mid-trace would fake a 180-degree turn)
            if (have_prev && (k1.x * prev.x + k1.y * prev.y + k1.z * prev.z) < 0.0)
              k1 = Vec3{-k1.x, -k1.y, -k1.z};
            const double sd = sgn * h;
            Vec3 p2{p.x + 0.5 * sd * k1.x, p.y + 0.5 * sd * k1.y, p.z + 0.5 * sd * k1.z};
            if (!sample(p2, k2)) break;
            if ((k2.x * k1.x + k2.y * k1.y + k2.z * k1.z) < 0.0) k2 = Vec3{-k2.x, -k2.y, -k2.z};
            Vec3 p3{p.x + 0.5 * sd * k2.x, p.y + 0.5 * sd * k2.y, p.z + 0.5 * sd * k2.z};
            if (!sample(p3, k3)) break;
            if ((k3.x * k1.x + k3.y * k1.y + k3.z * k1.z) < 0.0) k3 = Vec3{-k3.x, -k3.y, -k3.z};
            Vec3 p4{p.x + sd * k3.x, p.y + sd * k3.y, p.z + sd * k3.z};
            if (!sample(p4, k4)) break;
            if ((k4.x * k1.x + k4.y * k1.y + k4.z * k1.z) < 0.0) k4 = Vec3{-k4.x, -k4.y, -k4.z};
            Vec3 step{(k1.x + 2 * k2.x + 2 * k3.x + k4.x) / 6.0,
                      (k1.y + 2 * k2.y + 2 * k3.y + k4.y) / 6.0,
                      (k1.z + 2 * k2.z + 2 * k3.z + k4.z) / 6.0};
            const double n = std::sqrt(step.x * step.x + step.y * step.y + step.z * step.z);
            if (!(n > 1e-12)) break;
            step = Vec3{step.x / n, step.y / n, step.z / n};
            ++steps_total;
            const double absz = std::fabs(step.z);
            if (absz < kCos45) ++steps_violating;
            const double ang = std::acos(std::min(1.0, absz)) * 180.0 / 3.14159265358979;
            int b = static_cast<int>(ang / 10.0);
            if (b < 0) b = 0; if (b > 8) b = 8;
            ++hist[b];
            p = Vec3{p.x + sd * step.x, p.y + sd * step.y, p.z + sd * step.z};
            prev = step; have_prev = true;
          }
        }
      }

  std::printf("\n=== TRACED PRINCIPAL-DIRECTION CURVES - family %s ===\n", fam_name[fam]);
  std::printf("  seeds %lld   traced steps %lld   step length %.4f mm\n", seeds, steps_total, h);
  if (steps_total == 0) { std::fprintf(stderr, "no steps traced\n"); return 3; }
  all_total += steps_total; all_viol += steps_violating;
  std::printf("  OVERHANG VIOLATIONS (> 45 deg from vertical): %lld / %lld = %.2f %%\n",
              steps_violating, steps_total,
              100.0 * static_cast<double>(steps_violating) / static_cast<double>(steps_total));
  std::printf("\n  angle from vertical, by traced arc-length:\n");
  for (int b = 0; b < 9; ++b)
    std::printf("    %2d-%2d deg : %10lld  %6.2f %%%s\n", b * 10, b * 10 + 10, hist[b],
                100.0 * static_cast<double>(hist[b]) / static_cast<double>(steps_total),
                (b * 10 >= 45) ? "   <- unbuildable" : "");
  }
  std::printf("\n=== ALL THREE FAMILIES TOGETHER ===\n");
  std::printf("  OVERHANG VIOLATIONS: %lld / %lld = %.2f %% of traced arc-length\n",
              all_viol, all_total,
              100.0 * static_cast<double>(all_viol) / static_cast<double>(all_total));
  return 0;
}
