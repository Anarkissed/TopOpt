// cavity_convergence_probe — ★ THE POSITIVE CONTROL for task
// 2026-08-19-peak-stress-convergence (§2b).
//
//   cmake --build core/build --target cavity_convergence_probe
//   ./core/build/cavity_convergence_probe <resolution> <csv_out>
//        [--arm smooth|staircase] [--samples K] [--radius FRAC] [--side MM]
//
// ── WHY IT EXISTS ───────────────────────────────────────────────────────────
//
// S1 measures an exponent q in sigma_peak ~ h^-q on the maintainer's part and
// asks whether it has collapsed to zero. A number near zero is only believable
// if the same instrument RETURNS zero on a geometry whose peak stress is known
// to be finite. Otherwise "q = 0" is indistinguishable from a sweep that has
// stopped resolving anything.
//
// ★ THE FIXTURE, AND WHY THIS ONE. A SPHERICAL CAVITY in a bar under uniform
// uniaxial tension. Its stress concentration is classical and FINITE — for a
// cavity in an infinite medium the peak sits on the equator and is
//
//     K = (27 - 15 nu) / (2 (7 - 5 nu))            [Southwell & Gough 1926]
//
// which is 2.0714 at nu = 0.35. There is no re-entrant corner anywhere on the
// geometry: the surface is C-infinity and its curvature is bounded by 1/R. So the
// true peak exists, the discrete peak must converge to it, and q must come out
// at zero. Nothing else in this repository has a KNOWN finite peak, which is why
// the fixture is built here rather than borrowed.
//
// ★ AND IT IS THE SAME INSTRUMENT, NOT A SECOND ONE. The cavity is delivered as
// an ANALYTIC phi — phi(x) = |x - c| - R, material where phi < 0 — read through
// the SAME two arms `smooth_convergence_probe` uses:
//
//   --arm smooth      rho = the exact volume fraction of the cell inside
//                     {phi < 0}, k^3 sub-cell samples, mollified at
//                     eps_q = |grad phi| h / k (plsm_frac_soft_step /
//                     plsm_frac_eps — core's own functions, not a copy).
//   --arm staircase   rho = 1 iff phi(cell centre) < 0.
//
// and the SAME certification call, `analyze_fixed_design`. So a q of zero here
// and a q of zero on his part are the same measurement of the same pipeline.
//
// ★ THE SUPPORTS ARE STATICALLY DETERMINATE, DELIBERATELY. A clamped end is a
// Dirichlet-to-free corner and is itself singular — it would put a second,
// unknown singularity into the control and destroy its whole point. Instead:
//
//   * u_z = 0 on every node of the z = 0 face          (a roller, not a clamp)
//   * u_x = u_y = 0 at ONE node, the origin corner
//   * u_y = 0 at ONE more node, the far corner of the same edge
//
// which removes the six rigid-body modes and NOTHING else — the Poisson
// contraction is free everywhere, so with no cavity the exact solution is a
// uniform uniaxial stress that trilinear hexes reproduce to machine precision.
// The `--radius 0` arm runs exactly that, and its peak must be F/A at every
// resolution: the control's own control.
//
// ── WHAT IT IS NOT ──────────────────────────────────────────────────────────
//
// It is not a claim that his part's peak should equal 2.0714 sigma. The bar is
// finite (K rises with R/L) and the mesh is a voxel grid. The measurement is the
// EXPONENT and the spread, and the analytic K is quoted only as the order of
// magnitude the extrapolated peak should land near.

#include "topopt/analyze.hpp"
#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/plsm_basis.hpp"
#include "topopt/plsm_frac.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

using namespace topopt;

namespace {
double now_s() {
  return std::chrono::duration<double>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}
}  // namespace

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr,
                 "usage: %s <resolution> <csv_out> [--arm smooth|staircase] "
                 "[--samples K] [--radius FRAC] [--side MM]\n",
                 argv[0]);
    return 2;
  }
  const int N = std::atoi(argv[1]);
  const std::string csv_out = argv[2];
  std::string arm = "smooth";
  int fk = 4;
  double rfrac = 1.0 / 6.0;   // R / L
  double side = 60.0;         // L, mm
  for (int i = 3; i < argc; ++i) {
    if (std::strcmp(argv[i], "--arm") == 0 && i + 1 < argc) arm = argv[++i];
    else if (std::strcmp(argv[i], "--samples") == 0 && i + 1 < argc)
      fk = std::atoi(argv[++i]);
    else if (std::strcmp(argv[i], "--radius") == 0 && i + 1 < argc)
      rfrac = std::atof(argv[++i]);
    else if (std::strcmp(argv[i], "--side") == 0 && i + 1 < argc)
      side = std::atof(argv[++i]);
    else {
      std::fprintf(stderr, "PRECONDITION FAILED: unknown argument \"%s\"\n",
                   argv[i]);
      return 1;
    }
  }
  if (N < 8) { std::fprintf(stderr, "PRECONDITION FAILED: resolution >= 8\n"); return 1; }
  if (arm != "smooth" && arm != "staircase") {
    std::fprintf(stderr, "PRECONDITION FAILED: --arm must be smooth|staircase\n");
    return 1;
  }
  if (fk < 2 || fk > 16) {
    std::fprintf(stderr, "PRECONDITION FAILED: --samples in [2,16]\n");
    return 1;
  }
  if (rfrac < 0.0 || rfrac > 0.45) {
    std::fprintf(stderr,
                 "PRECONDITION FAILED: --radius is R/L and must be in [0, 0.45] "
                 "(0 is the no-cavity uniform-stress arm)\n");
    return 1;
  }

  // ── the grid: a cube, every voxel solid.
  VoxelGrid g;
  g.nx = g.ny = g.nz = N;
  g.spacing = side / N;
  g.origin = Vec3{0.0, 0.0, 0.0};
  const std::size_t n = static_cast<std::size_t>(N) * N * N;
  g.tags.assign(n, VoxelTag::Interior);
  const double h = g.spacing;
  const Vec3 c{0.5 * side, 0.5 * side, 0.5 * side};
  const double R = rfrac * side;

  MaterialLibrary lib = load_materials_file(MATERIALS_JSON_PATH);
  const auto mit = lib.find("PLA");
  if (mit == lib.end()) {
    std::fprintf(stderr, "PRECONDITION FAILED: PLA not in catalog\n");
    return 1;
  }
  const Material material = mit->second;
  SimpParams params;
  params.youngs_modulus = material.youngs_modulus_mpa;
  params.poisson = material.poisson;
  params.penalty = 3.0;
  const double rho_min = params.density_min;

  // ── the ersatz. phi = |x - c| - R, so material is phi < 0 OUTSIDE the cavity:
  // the occupancy of the BAR is 1 - (fraction inside the sphere), which is the
  // fraction of the cell inside {psi < 0} for psi = R - |x - c|. That is the sign
  // the level-set convention wants, so psi is what is sampled.
  auto psi_at = [&](double x, double y, double z) {
    const double dx = x - c.x, dy = y - c.y, dz = z - c.z;
    return R - std::sqrt(dx * dx + dy * dy + dz * dz);
  };
  std::vector<double> occ(n, 0.0), rho(n, 0.0);
  std::size_t n_cut = 0;
  const int threads = plsm_hw_threads(0);
  const double t_occ0 = now_s();
  std::vector<int> incount(n, 0);
  plsm_parallel_for(n, threads, [&](std::size_t v) {
    const int i = static_cast<int>(v % static_cast<std::size_t>(N));
    const int j = static_cast<int>((v / static_cast<std::size_t>(N)) %
                                   static_cast<std::size_t>(N));
    const int k = static_cast<int>(v / (static_cast<std::size_t>(N) *
                                        static_cast<std::size_t>(N)));
    const double cx = g.origin.x + (i + 0.5) * h;
    const double cy = g.origin.y + (j + 0.5) * h;
    const double cz = g.origin.z + (k + 0.5) * h;
    if (arm == "staircase") {
      occ[v] = psi_at(cx, cy, cz) < 0.0 ? 1.0 : 0.0;
      incount[v] = occ[v] > 0.5 ? fk * fk * fk : 0;
      return;
    }
    // |grad psi| is 1 everywhere off the centre (psi is a signed distance), so
    // the bandwidth is the sample spacing exactly — the derived value, through
    // core's own `plsm_frac_eps` rather than a number written here.
    const double eps = plsm_frac_eps(1.0, h, fk, 1.0);
    const double inv = 1.0 / fk;
    double acc = 0.0;
    int in = 0;
    for (int r = 0; r < fk; ++r)
      for (int q = 0; q < fk; ++q)
        for (int p = 0; p < fk; ++p) {
          const double x = g.origin.x + (i + (p + 0.5) * inv) * h;
          const double y = g.origin.y + (j + (q + 0.5) * inv) * h;
          const double z = g.origin.z + (k + (r + 0.5) * inv) * h;
          const double s = psi_at(x, y, z);
          in += s < 0.0 ? 1 : 0;
          acc += plsm_frac_soft_step(s, eps);
        }
    const int kk = fk * fk * fk;
    occ[v] = acc / kk;
    incount[v] = in;
  });
  const double occ_wall = now_s() - t_occ0;
  {
    const int kk = fk * fk * fk;
    for (std::size_t v = 0; v < n; ++v)
      if (incount[v] > 0 && incount[v] < kk) ++n_cut;
  }
  for (std::size_t v = 0; v < n; ++v) rho[v] = rho_min + (1.0 - rho_min) * occ[v];

  const double cell_mm3 = h * h * h;
  double vol = 0.0;
  for (std::size_t v = 0; v < n; ++v) vol += occ[v] * cell_mm3;
  const double vol_exact =
      side * side * side - (4.0 / 3.0) * 3.14159265358979323846 * R * R * R;

  // ── the supports: a roller plane plus exactly enough to kill rigid-body modes.
  const int nnx = N + 1, nny = N + 1;
  auto node = [&](int i, int j, int k) {
    return i + nnx * (j + nny * k);
  };
  std::vector<DirichletBC> bcs;
  for (int j = 0; j <= N; ++j)
    for (int i = 0; i <= N; ++i) bcs.push_back({node(i, j, 0), 2, 0.0});
  bcs.push_back({node(0, 0, 0), 0, 0.0});
  bcs.push_back({node(0, 0, 0), 1, 0.0});
  bcs.push_back({node(N, 0, 0), 1, 0.0});

  // ── the traction: a uniform pressure sigma0 on the z = L face, spread over the
  // face nodes by the trilinear consistent rule (corner 1/4, edge 1/2, interior
  // 1) so the resultant is EXACTLY sigma0 * L^2 and the far-field stress is
  // sigma0 whatever the resolution.
  const double sigma0 = 1.0;  // MPa
  const double total_F = sigma0 * side * side;
  std::vector<NodalLoad> loads;
  double wsum = 0.0;
  std::vector<double> w((static_cast<std::size_t>(nnx) * nny), 0.0);
  for (int j = 0; j <= N; ++j)
    for (int i = 0; i <= N; ++i) {
      const double wi = (i == 0 || i == N) ? 0.5 : 1.0;
      const double wj = (j == 0 || j == N) ? 0.5 : 1.0;
      w[static_cast<std::size_t>(i + nnx * j)] = wi * wj;
      wsum += wi * wj;
    }
  for (int j = 0; j <= N; ++j)
    for (int i = 0; i <= N; ++i)
      loads.push_back({node(i, j, N), 2,
                       total_F * w[static_cast<std::size_t>(i + nnx * j)] / wsum});

  const KnockdownSpec knockdown;  // neutral: infill_knockdown 1.0, not width-aware
  const bool prev_recycle = fea_set_krylov_recycling(false);
  const bool prev_geneo = fea_set_geneo_twolevel(false);

  double fz = 0.0;
  for (const NodalLoad& l : loads) if (l.component == 2) fz += l.value;

  std::printf("== cavity_convergence_probe (POSITIVE CONTROL) ==\n");
  std::printf("arm        : %s  (samples %d^3)\n", arm.c_str(),
              arm == "smooth" ? fk : 1);
  std::printf("bar        : %.6g mm cube, cavity R = %.6g mm (R/L = %.6g)\n", side,
              R, rfrac);
  std::printf("grid       : %dx%dx%d @ %.17g mm  (%zu voxels, %d dofs)\n", N, N, N,
              h, n, 3 * fea_node_count(g));
  std::printf("R/h        : %.6g voxels across the cavity radius\n", R / h);
  std::printf("cut cells  : %zu\n", n_cut);
  std::printf("volume     : %.10f mm^3   exact %.10f   error %.6g%%\n", vol,
              vol_exact, 100.0 * (vol - vol_exact) / vol_exact);
  std::printf("supports   : %zu dirichlet dofs (a roller plane + 3 scalar "
              "constraints; NO clamp)\n",
              bcs.size());
  std::printf("traction   : %zu nodal loads, resultant Fz = %.17g N "
              "(sigma0 * L^2 = %.17g)\n",
              loads.size(), fz, total_F);
  std::fflush(stdout);

  fea_matvec_count_reset();
  const double t0 = now_s();
  FixedDesignAnalysis a;
  try {
    a = analyze_fixed_design(g, params, rho, bcs, loads, material,
                             Vec3{0.0, 0.0, 1.0}, 1e-8, 0, SolverKind::MultigridCG,
                             1.5, knockdown, /*load_path_ok=*/true,
                             static_cast<double>(n));
  } catch (const std::exception& e) {
    std::fprintf(stderr, "SOLVE FAILED: %s\n", e.what());
    fea_set_geneo_twolevel(prev_geneo);
    fea_set_krylov_recycling(prev_recycle);
    return 1;
  }
  const double wall = now_s() - t0;
  const long long matvecs = fea_matvec_count();
  fea_set_geneo_twolevel(prev_geneo);
  fea_set_krylov_recycling(prev_recycle);
  if (a.non_convergent) {
    std::printf("\n*** SOLVE DID NOT CONVERGE at iteration %d, residual %.6g. "
                "Nothing below is a measurement. ***\n",
                a.non_convergent_iteration, a.non_convergent_residual);
    return 3;
  }

  // Where the peak sits, and how far it is from the cavity surface — the
  // classical peak is ON the equator, so a peak anywhere else is a finding.
  std::size_t am = 0;
  for (std::size_t v = 1; v < a.von_mises_field.size(); ++v)
    if (a.von_mises_field[v] > a.von_mises_field[am]) am = v;
  const int pk = static_cast<int>(am / (static_cast<std::size_t>(N) * N));
  const int pj = static_cast<int>((am / static_cast<std::size_t>(N)) %
                                  static_cast<std::size_t>(N));
  const int pi = static_cast<int>(am % static_cast<std::size_t>(N));
  const Vec3 pc = g.voxel_center(pi, pj, pk);
  const double r_peak = std::sqrt((pc.x - c.x) * (pc.x - c.x) +
                                  (pc.y - c.y) * (pc.y - c.y) +
                                  (pc.z - c.z) * (pc.z - c.z));
  const double nu = params.poisson;
  const double K_inf = (27.0 - 15.0 * nu) / (2.0 * (7.0 - 5.0 * nu));

  std::printf("\n-- THE PEAK ------------------------------------------------\n");
  std::printf("  peak von Mises          : %.17g MPa\n", a.max_von_mises);
  std::printf("  sigma0                  : %.17g MPa\n", sigma0);
  std::printf("  K = peak / sigma0       : %.17g\n", a.max_von_mises / sigma0);
  std::printf("  Southwell K (infinite)  : %.17g  (nu = %.6g)\n", K_inf, nu);
  std::printf("  peak voxel (%d,%d,%d) rho=%.10g, |x-c| = %.6g mm (R = %.6g, "
              "%.4g voxels off the surface)\n",
              pi, pj, pk, rho[am], r_peak, R, (r_peak - R) / h);
  std::printf("  printed voxels          : %zu\n", a.printed_voxels);
  std::printf("  occupancy wall %.3f s, analyze wall %.3f s, applies %lld\n",
              occ_wall, wall, matvecs);

  const bool exists = [&] {
    std::ifstream f(csv_out);
    return f.good();
  }();
  std::ofstream csv(csv_out, std::ios::app);
  if (!csv) { std::fprintf(stderr, "cannot write %s\n", csv_out.c_str()); return 1; }
  if (!exists)
    csv << "arm,resolution,side_mm,radius_frac,spacing_mm,dofs,samples,"
           "peak_vm_mpa,sigma0_mpa,K,K_southwell,vol_mm3,vol_exact_mm3,n_cut,"
           "printed_voxels,peak_i,peak_j,peak_k,peak_r_mm,peak_rho,wall_s,"
           "matvecs\n";
  csv.setf(std::ios::fmtflags(0), std::ios::floatfield);
  csv.precision(17);
  csv << arm << ',' << N << ',' << side << ',' << rfrac << ',' << h << ','
      << 3 * fea_node_count(g) << ',' << (arm == "smooth" ? fk : 1) << ','
      << a.max_von_mises << ',' << sigma0 << ',' << a.max_von_mises / sigma0 << ','
      << K_inf << ',' << vol << ',' << vol_exact << ',' << n_cut << ','
      << a.printed_voxels << ',' << pi << ',' << pj << ',' << pk << ',' << r_peak
      << ',' << rho[am] << ',' << wall << ',' << matvecs << '\n';
  csv.close();
  std::printf("\nwrote CSV row -> %s\n", csv_out.c_str());
  return 0;
}
