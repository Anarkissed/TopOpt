// tpms_probe.cpp — the sheet types' measurements on the PRODUCTION wall (lattice types
// round 1, K2: docs/design/lattice-types/02-core-spec.md §3). MEASUREMENT ONLY.
//
// The July rows (PR 198, evidence/2026-07-26-lattice-homog-phase0/tensor_library.csv) were
// measured on |f| < level, a wall whose thickness varies over the sheet. Production builds
// the gradient-normalised band |f|/|grad f| <= t/2 (topopt/tpms.hpp, R7), one thickness.
// So the rows are RE-MEASURED here on that wall, by the same periodic homogenisation the
// strut rows used (tensor_library_nine_probe.cpp's homogenize, compiled from its source).
//
//   law  <kind>                  the wall law: t/L bisected (50 steps) on the wall's
//                                CONVERGED solid fraction (2^20 Halton points, the strut
//                                law's estimator) over rho 0.05..0.60, plus the TRUE normal
//                                thickness measured on the sheet (marching out along the
//                                normal from points on the zero set) against the nominal t.
//   perc <kind>                  members 0.5 / 0.75 / 1 / 1.5 / 2 cells across at rho 0.15 /
//                                0.35 / 0.60, window placements 0 / .25 / .5 / .75 cell,
//                                vpc32, 4 cells long, 6-connected: does a component touch
//                                both ends at every placement (lattice_types_probe's rule).
//   bend <kind>                  PR 235's C2b guided cantilever on the sheet: resolved wall
//                                vs one cubic macro element per cell (the periodic tensor of
//                                the same wall at the same vpc), vpc24 (the wall is ~3.4
//                                voxels at rho 0.40, the strut study's ~3), S = 5 mm, 6 long.
//   rows <kind> <vpc_row> <vpc_ref>
//                                PR 198/237's sweep: at each target rho, t calibrated on the
//                                voxelised wall at each vpc, the periodic tensor, and the
//                                drift of the row's E100 against the reference curve at the
//                                ROW's own rho. VALID := |drift| < 2.4 % AND the wall is at
//                                least TOPOPT_TP_WALL_VOX voxels thick (default 4, PR 198's
//                                floor) AND the solve converged.
//   tris <kind>                  the generator's triangle cost: generate_tpms on 2/3/4-cell
//                                blocks (no part, uniform wall at rho 0.20 / 0.40, L 8 mm)
//                                at DC cells L/10, L/20, L/30; count = a n^3 + b n^2 + c n
//                                solved for a, the cost of one interior cell, and a / (L/h)^2.
//
// kind: gyroid | schwarz_d. CSVs land in TOPOPT_LATTICE_CSV_DIR.
// Build (from core/, after the library):
//   c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
//       tests/harness/tpms_probe.cpp build/libtopopt.a -o build/tpms_probe

#define main tensor_library_nine_probe_main
#include "tensor_library_nine_probe.cpp"
#undef main

#include "topopt/tpms.hpp"
#include "topopt/tpms_gen.hpp"

namespace {

using topopt::TpmsKind;

TpmsKind kind_of(const std::string& s) {
  if (s == "gyroid") return TpmsKind::Gyroid;
  if (s == "schwarz_d") return TpmsKind::SchwarzD;
  std::fprintf(stderr, "unknown sheet kind %s\n", s.c_str());
  std::exit(2);
}

double halton(unsigned i, unsigned base) {
  double f = 1.0, r = 0.0;
  while (i > 0) { f /= base; r += f * (i % base); i /= base; }
  return r;
}
// The wall's solid fraction on the unit cell (L = 1), t in units of L.
double solid_fraction(TpmsKind k, double t, int samples = 1 << 20) {
  long long in = 0;
  for (int n = 1; n <= samples; ++n)
    if (topopt::tpms_in_wall(k, halton(n, 2), halton(n, 3), halton(n, 5), 1.0, t)) ++in;
  return double(in) / samples;
}
double calibrate_t(TpmsKind k, double target) {
  double lo = 1e-4, hi = 1.5;
  for (int it = 0; it < 50; ++it) {
    const double mid = 0.5 * (lo + hi);
    (solid_fraction(k, mid) < target ? lo : hi) = mid;
  }
  return 0.5 * (lo + hi);
}
// The voxelised wall of one periodic cell (voxel centres), L mm, t in mm.
VoxelGrid wall_cell(TpmsKind k, double L, int vpc, double t) {
  VoxelGrid g;
  g.nx = g.ny = g.nz = vpc;
  g.spacing = L / vpc;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(std::size_t(vpc) * vpc * vpc, VoxelTag::Empty);
  for (int kk = 0; kk < vpc; ++kk)
    for (int j = 0; j < vpc; ++j)
      for (int i = 0; i < vpc; ++i) {
        const Vec3 c = g.voxel_center(i, j, kk);
        if (topopt::tpms_in_wall(k, c.x, c.y, c.z, L, t)) g.set_tag(i, j, kk, VoxelTag::Interior);
      }
  return g;
}
double calibrate_t_vox(TpmsKind k, double L, double target, int vpc) {
  double lo = 1e-4 * L, hi = 1.5 * L;
  for (int it = 0; it < 34; ++it) {
    const double mid = 0.5 * (lo + hi);
    (volume_fraction(wall_cell(k, L, vpc, mid)) < target ? lo : hi) = mid;
  }
  return 0.5 * (lo + hi);
}

// The true normal thickness of the wall at sample points of the sheet: project a point onto
// f = 0 (Newton along the gradient), then march along +-n in fine steps until the point
// leaves the wall; the two distances summed. Unit cell, t in units of L.
void true_thickness(TpmsKind k, double t, double* mean, double* lo, double* hi) {
  double sum = 0, mn = 1e30, mx = 0;
  int n = 0;
  for (int s = 1; s <= 4000; ++s) {
    double p[3] = {halton(s, 2), halton(s, 3), halton(s, 5)};
    bool ok = false;
    for (int it = 0; it < 30; ++it) {
      const topopt::TpmsValue v = topopt::tpms_eval(k, p[0], p[1], p[2], 1.0);
      const double g2 = v.gx * v.gx + v.gy * v.gy + v.gz * v.gz;
      if (g2 < 1e-12) break;
      p[0] -= v.f * v.gx / g2; p[1] -= v.f * v.gy / g2; p[2] -= v.f * v.gz / g2;
      if (std::fabs(v.f) < 1e-12) { ok = true; break; }
    }
    if (!ok) continue;
    const topopt::TpmsValue v = topopt::tpms_eval(k, p[0], p[1], p[2], 1.0);
    const double g = std::sqrt(v.gx * v.gx + v.gy * v.gy + v.gz * v.gz);
    const double nrm[3] = {v.gx / g, v.gy / g, v.gz / g};
    double width = 0;
    for (int dir = -1; dir <= 1; dir += 2) {
      double a = 0, b = t;  // bisect the exit distance on [0, t]
      if (topopt::tpms_in_wall(k, p[0] + dir * b * nrm[0], p[1] + dir * b * nrm[1],
                               p[2] + dir * b * nrm[2], 1.0, t))
        b = 2 * t;
      for (int it = 0; it < 40; ++it) {
        const double m = 0.5 * (a + b);
        (topopt::tpms_in_wall(k, p[0] + dir * m * nrm[0], p[1] + dir * m * nrm[1],
                              p[2] + dir * m * nrm[2], 1.0, t) ? a : b) = m;
      }
      width += 0.5 * (a + b);
    }
    sum += width; mn = std::min(mn, width); mx = std::max(mx, width); ++n;
  }
  *mean = sum / n; *lo = mn; *hi = mx;
}

int mode_law(const std::string& name) {
  const TpmsKind k = kind_of(name);
  const std::vector<double> rhos = env_doubles("TOPOPT_TP_RHOS",
      {0.05, 0.08, 0.10, 0.15, 0.20, 0.25, 0.30, 0.35, 0.40, 0.50, 0.60});
  FILE* csv = csv_open(name + "_wall_law.csv");
  if (csv) std::fprintf(csv, "rho_target,t_over_L,rho_converged,true_t_mean_over_L,true_t_min_over_L,"
                             "true_t_max_over_L,rho_over_t_per_L\n");
  std::printf("WALL LAW %s (tpms.hpp production wall |f|/|grad f| <= t/2): t/L bisected on the "
              "converged solid fraction (2^20 Halton); true normal thickness on 4000 sheet points\n",
              name.c_str());
  std::printf("  %-6s %-10s %-9s | %-9s %-9s %-9s | %-8s\n", "rho", "t/L", "rho", "true mean",
              "true min", "true max", "rho/(t/L)");
  for (double rho : rhos) {
    const double t = calibrate_t(k, rho);
    const double got = solid_fraction(k, t);
    double mean, lo, hi;
    true_thickness(k, t, &mean, &lo, &hi);
    std::printf("  %-6.2f %-10.6f %-9.5f | %-9.6f %-9.6f %-9.6f | %-8.4f\n", rho, t, got, mean, lo,
                hi, got / t);
    if (csv) std::fprintf(csv, "%.2f,%.8f,%.6f,%.8f,%.8f,%.8f,%.5f\n", rho, t, got, mean, lo, hi, got / t);
  }
  if (csv) std::fclose(csv);
  return 0;
}

struct SRow { double rho = 0, t = 0, wall_vox = 0; Cubic c; bool converged = true; double ms = 0; long ndof = 0; };
SRow solve_row(TpmsKind k, double L, double target, int vpc, double tol) {
  SRow r;
  r.t = calibrate_t_vox(k, L, target, vpc);
  const VoxelGrid g = wall_cell(k, L, vpc, r.t);
  r.rho = volume_fraction(g);
  r.wall_vox = r.t / (L / vpc);
  const HomogResult H = homogenize(g, {0, 2, 3, 4}, tol);
  r.c = cubic_of(H);
  r.converged = H.converged;
  r.ms = H.solve_ms;
  r.ndof = H.ndof_active;
  return r;
}

VoxelGrid wall_block(TpmsKind k, double L, double t, double wx, double wy, int ncz, int vpc,
                     double ox, double oy) {
  VoxelGrid g;
  const double h = L / vpc;
  g.nx = std::max(1, int(std::lround(wx / h)));
  g.ny = std::max(1, int(std::lround(wy / h)));
  g.nz = ncz * vpc;
  g.spacing = h; g.origin = Vec3{0, 0, 0};
  g.tags.assign(std::size_t(g.nx) * g.ny * g.nz, VoxelTag::Empty);
  for (int kk = 0; kk < g.nz; ++kk)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        const Vec3 c = g.voxel_center(i, j, kk);
        if (topopt::tpms_in_wall(k, c.x + ox, c.y + oy, c.z, L, t)) g.set_tag(i, j, kk, VoxelTag::Interior);
      }
  return g;
}

#include "lattice_types_probe_shared.inc"

int mode_perc(const std::string& name) {
  const TpmsKind k = kind_of(name);
  const double L = 5.0;
  const int vpc = 32;
  FILE* csv = csv_open(name + "_perc.csv");
  if (csv) std::fprintf(csv, "rho,cells_across,offset_cells,components,spanning,debris_frac\n");
  std::printf("PERC %s: vpc%d, S=5 mm, 4 cells long, 6-connected, placements x=y in {0,.25,.5,.75}\n",
              name.c_str(), vpc);
  for (double rho : {0.15, 0.35, 0.60}) {
    const double t = calibrate_t(k, rho) * L;
    for (double nc : {0.5, 0.75, 1.0, 1.5, 2.0}) {
      bool all = true;
      std::string line;
      for (double off : {0.0, 0.25, 0.5, 0.75}) {
        const VoxelGrid g = wall_block(k, L, t, nc * L, nc * L, 4, vpc, off * L, off * L);
        const Comp cp = components(g);
        all = all && cp.spanning;
        const double debris = cp.solid ? 1.0 - double(cp.largest) / cp.solid : 0.0;
        char b[64];
        std::snprintf(b, sizeof b, " off%.2f:%d%s", off, cp.n, cp.spanning ? "" : " NOT SPANNING");
        line += b;
        if (csv) std::fprintf(csv, "%.2f,%.2f,%.2f,%d,%d,%.4f\n", rho, nc, off, cp.n, cp.spanning ? 1 : 0, debris);
      }
      std::printf("  rho %.2f  %.2f cells: %s |%s\n", rho, nc, all ? "PERCOLATES" : "no", line.c_str());
    }
  }
  if (csv) std::fclose(csv);
  return 0;
}

int mode_bend(const std::string& name) {
  const TpmsKind k = kind_of(name);
  const double S = 5.0;
  const int vpc = env_ints("TOPOPT_TP_BEND_VPC", {24})[0];
  const double tvf = env_doubles("TOPOPT_TP_BEND_VF", {0.40})[0];
  const int Lb = 6;
  const std::vector<int> ncs = env_ints("TOPOPT_TP_BEND_NC", {1, 2, 3, 4, 5, 6});
  const double t = calibrate_t_vox(k, S, tvf, vpc);
  const VoxelGrid cell = wall_cell(k, S, vpc, t);
  const double rho_cell = volume_fraction(cell);
  const Cubic pt = cubic_of(homogenize(cell, {0, 1, 2, 3, 4, 5}, 1e-9));
  std::printf("BEND %s: S=%.1f mm, vpc=%d, %d cells long, target rho %.2f -> cell rho %.4f "
              "(wall %.2f voxels), C11=%.2f C12=%.2f C44=%.2f Zener=%.3f\n", name.c_str(), S,
              vpc, Lb, tvf, rho_cell, t / (S / vpc), pt.C11, pt.C12, pt.C44, pt.zener);
  FILE* csv = csv_open(name + "_bend.csv");
  if (csv) std::fprintf(csv, "cells_across,cell_rho,block_rho,K_resolved,K_homog_macro,bend_err_pct,resolved_dof,resolved_ms,verdict\n");
  for (int nc : ncs) {
    const VoxelGrid g = wall_block(k, S, t, nc * S, nc * S, Lb, vpc, 0.0, 0.0);
    std::vector<double> ey(g.voxel_count(), 0.0);
    for (std::size_t e = 0; e < g.voxel_count(); ++e) if (g.tags[e] != VoxelTag::Empty) ey[e] = kE;
    double msR = 0; long ndR = 0;
    const double Kres = transverse_K(g, ey, {}, {}, {}, {}, false, &msR, &ndR);
    const VoxelGrid mg = macro_grid(S, nc, nc, Lb);
    std::vector<double> mey(mg.voxel_count(), kE);
    std::vector<char> mask(mg.voxel_count(), 1);
    std::vector<double> c11(mg.voxel_count(), pt.C11), c12(mg.voxel_count(), pt.C12),
        c44(mg.voxel_count(), pt.C44);
    const double Khom = transverse_K(mg, mey, mask, c11, c12, c44, true);
    const double err = (Kres > 0 && Khom > 0) ? 100.0 * (Khom - Kres) / Kres : NAN;
    const char* v = Kres <= 0 ? "SOLVE-FAIL" : (std::fabs(err) <= 2.4 ? "GO" : "NO-GO");
    std::printf("    nc=%d  block rho %.4f  K_res %.4f  K_hom %.4f  err %+.2f %%  dof %ld  %.0f ms  %s\n",
                nc, volume_fraction(g), Kres, Khom, err, ndR, msR, v);
    if (csv) { std::fprintf(csv, "%d,%.4f,%.4f,%.4f,%.4f,%.2f,%ld,%.0f,%s\n", nc, rho_cell,
                            volume_fraction(g), Kres, Khom, err, ndR, msR, v); std::fflush(csv); }
  }
  if (csv) std::fclose(csv);
  return 0;
}

int mode_rows(const std::string& name, int vpc_row, int vpc_ref) {
  const TpmsKind k = kind_of(name);
  const double L = 5.0;
  const double tol = env_double("TOPOPT_TL_TOL", 1e-8);
  const double wall_floor = env_double("TOPOPT_TP_WALL_VOX", 4.0);
  const std::vector<double> vfs = env_doubles("TOPOPT_TP_VFS",
      {0.10, 0.15, 0.20, 0.25, 0.30, 0.40, 0.50, 0.60});
  std::printf("ROWS %s on the production wall: rows @ vpc%d, reference curve @ vpc%d, L=%.0f mm; "
              "VALID := |drift| < 2.4%% AND wall >= %.1f voxels AND converged\n",
              name.c_str(), vpc_row, vpc_ref, L, wall_floor);
  std::vector<std::pair<double, double>> refE;
  for (double tv : vfs) {
    const SRow r = solve_row(k, L, tv, vpc_ref, tol);
    refE.push_back({r.rho, r.c.E100});
    std::printf("  ref vpc%d target %.3f: rho %.5f E100 %.3f (wall %.2f vox, %.0f ms)\n", vpc_ref,
                tv, r.rho, r.c.E100, r.wall_vox, r.ms);
  }
  std::sort(refE.begin(), refE.end());
  FILE* csv = csv_open(name + "_rows_vpc" + std::to_string(vpc_row) + ".csv");
  if (csv) std::fprintf(csv, "target_vf,vpc_row,vpc_ref,rho_row,t_mm,wall_vox,C11,C12,C44,C33,C44_yz,"
                             "E100,E100_ref_interp,drift_pct,zener,axial_aniso_pct,shear_aniso_pct,"
                             "ndof_active,solve_ms,converged,validated\n");
  for (double tv : vfs) {
    const SRow r = solve_row(k, L, tv, vpc_row, tol);
    const double eref = interp_curve(refE, r.rho);
    const double drift = eref != 0 ? 100.0 * (r.c.E100 - eref) / eref : 0.0;
    const bool valid = std::fabs(drift) < 2.4 && r.wall_vox >= wall_floor && r.converged;
    std::printf("  row vpc%d target %.3f: rho %.5f C11 %.3f C12 %.3f C44 %.3f E100 %.3f drift %+.2f%% "
                "zener %.3f wall %.2f vox %s\n", vpc_row, tv, r.rho, r.c.C11, r.c.C12, r.c.C44,
                r.c.E100, drift, r.c.zener, r.wall_vox, valid ? "VALID" : "-");
    if (csv) std::fprintf(csv, "%.3f,%d,%d,%.5f,%.6f,%.3f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%+.3f,"
                               "%.4f,%.3f,%.3f,%ld,%.0f,%d,%d\n",
                          tv, vpc_row, vpc_ref, r.rho, r.t, r.wall_vox, r.c.C11, r.c.C12, r.c.C44,
                          r.c.C33, r.c.C44_yz, r.c.E100, eref, drift, r.c.zener,
                          r.c.axial_aniso * 100, r.c.shear_aniso * 100, r.ndof, r.ms,
                          r.converged ? 1 : 0, valid ? 1 : 0);
    if (csv) std::fflush(csv);
  }
  if (csv) std::fclose(csv);
  return 0;
}

struct CountSink : topopt::TriangleSink {
  long long n = 0;
  void add_triangle(const topopt::Vec3&, const topopt::Vec3&, const topopt::Vec3&) override { ++n; }
};

int mode_tris(const std::string& name) {
  const TpmsKind k = kind_of(name);
  const double L = 8.0;
  std::printf("TRIS %s: generate_tpms, blocks of 2/3/4 cells, no part, L %.0f mm, uniform wall; "
              "per interior cell = a in a n^3 + b n^2 + c n\n", name.c_str(), L);
  for (double rho : {0.20, 0.40}) {
    const double t = calibrate_t(k, rho) * L;
    for (double r : {10.0, 20.0, 30.0}) {
      double c[5] = {0, 0, 0, 0, 0};
      for (int n = 2; n <= 4; ++n) {
        topopt::TpmsRegion reg;
        reg.nx = reg.ny = reg.nz = n;
        reg.cell_mm = L;
        topopt::TpmsWallField w;
        w.uniform_mm = t;
        topopt::TpmsGenOptions o;
        o.dc_cell_mm = L / r;
        CountSink s;
        topopt::generate_tpms(k, reg, w, s, o);
        c[n] = double(s.n);
      }
      // [8 4 2; 27 9 3; 64 16 4] (a b c)^T = (c2 c3 c4)^T, solved for a by Cramer's rule.
      auto det = [](const double m[3][3]) {
        return m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) -
               m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) +
               m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
      };
      const double M[3][3] = {{8, 4, 2}, {27, 9, 3}, {64, 16, 4}};
      const double Ma[3][3] = {{c[2], 4, 2}, {c[3], 9, 3}, {c[4], 16, 4}};
      const double a = det(Ma) / det(M);
      std::printf("  rho %.2f  t %.3f mm  L/h %2.0f  blocks %.0f %.0f %.0f  per cell %6.0f  "
                  "per cell / (L/h)^2 %.2f\n", rho, t, r, c[2], c[3], c[4], a, a / (r * r));
    }
  }
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  std::setvbuf(stdout, nullptr, _IONBF, 0);
  if (argc < 3) {
    std::fprintf(stderr, "usage: %s law <kind> | rows <kind> <vpc_row> <vpc_ref>\n", argv[0]);
    return 2;
  }
  const std::string cmd = argv[1];
  if (cmd == "law") return mode_law(argv[2]);
  if (cmd == "perc") return mode_perc(argv[2]);
  if (cmd == "bend") return mode_bend(argv[2]);
  if (cmd == "tris") return mode_tris(argv[2]);
  if (cmd == "rows" && argc >= 5) return mode_rows(argv[2], std::atoi(argv[3]), std::atoi(argv[4]));
  std::fprintf(stderr, "bad arguments\n");
  return 2;
}
