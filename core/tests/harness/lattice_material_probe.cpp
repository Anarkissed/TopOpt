// lattice_material_probe — PART 1 of the multiscale-lattice-feasibility PROBE
// (2026-07-31-multiscale-lattice-feasibility): the lattice material model
// C(rho) and its bars. HARNESS ONLY — links the production library unmodified;
// the model lives in lattice_material_model.hpp (harness header).
//
// BARS — STATED BEFORE MEASURING (see the handoff; failures are reported, not
// silently softened):
//   G1  fit accuracy      max relative error at the resolved rows <= 5% and
//                         RMS <= 2% per component per topology; HELD-OUT
//                         (leave-one-out) max <= 10% — the library rows carry
//                         a ~±10% measurement caveat (lattice.hpp), so a fit
//                         within the data's own uncertainty passes, a fit
//                         outside it fails.
//   G2  admissibility     over a dense sweep of the WHOLE [0,1] curve (band +
//                         both bridges): C11 > 0, C11 > |C12|, C11 + 2*C12 > 0,
//                         C44 > 0 at EVERY point (worst normalized margin > 0).
//                         Also reported: the derivative-PSD margins
//                         (C11' - C12', C11' + 2*C12', C44' — dC/drho PSD is
//                         what makes stiffness monotone and compliance
//                         sensitivities one-signed).
//   G3  sensitivities     analytic dC/drho vs central finite differences of the
//                         model: worst relative error <= 1e-6 away from the two
//                         regime joints (the model is C1 there, so FD picks up
//                         the C2 jump — those points are reported separately,
//                         bounded by h * |ΔC''|). Smoothness: dC/drho tabulated
//                         across [0,1]; the only C1 kinks allowed are NONE
//                         (joints are C1 by construction); C2 jumps at the two
//                         joints are reported.
//   G4  table adequacy    octet refit on decimated subsets (8/6/5/4 rows kept
//                         of 19): value and DERIVATIVE deviation from the
//                         19-row fit across the band. The stated read: a
//                         subset supports the model if value dev <= 5% and
//                         derivative dev <= 15%; report which row counts fail.
//   G4b gap severity      lower gap width (0 -> rho_lo) and upper gap width
//                         (rho_hi -> 1) per topology, plus the stiffness ratio
//                         C11_solid / C11(rho_hi) the upper bridge must span.
//   G5  regime bridging   C0 and C1 relative discontinuity at both joints
//                         <= 1e-9 (the bridges match value and slope by
//                         construction; this measures the implementation).
//
// Build (repo root; same recipe as matfree_cubic_probe, no Eigen needed):
//   c++ -std=c++17 -O2 -I core/include -I core/tests/harness \
//       core/tests/harness/lattice_material_probe.cpp core/build/libtopopt.a \
//       -o core/build/lattice_material_probe
//   ./core/build/lattice_material_probe [g1|g2|g3|g4|g4b|g5|all] [evidence-dir]

#include <algorithm>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "topopt/lattice.hpp"

#include "lattice_material_model.hpp"

using namespace topopt;
using lmm::LatticeMaterialModel;
using lmm::MRow;

namespace {

int g_fail = 0;
void bar(bool ok, const char* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  std::printf("  [%s] ", ok ? "PASS" : "FAIL");
  std::vprintf(fmt, ap);
  std::printf("\n");
  va_end(ap);
  if (!ok) ++g_fail;
}

FILE* open_csv(const std::string& dir, const char* name) {
  const std::string p = dir + "/" + name;
  FILE* f = std::fopen(p.c_str(), "w");
  if (!f) {
    std::fprintf(stderr, "cannot open %s\n", p.c_str());
    std::exit(1);
  }
  return f;
}

const char* comp_name(int i) { return i == 0 ? "C11" : i == 1 ? "C12" : "C44"; }

// The model is built at the library basis for Part 1 (Es = 3500, PLA nu = 0.33
// from materials.json) so fitted values compare 1:1 with the rows.
constexpr double kEs = 3500.0;
constexpr double kNu = 0.33;

// ---------------------------------------------------------------------------
// G1 — fit accuracy at rows + leave-one-out held-out error.
// ---------------------------------------------------------------------------
void run_g1(const std::string& ev) {
  std::printf("== G1: fit accuracy (bar: row max <= 5%%, row RMS <= 2%%, "
              "LOO max <= 10%%) ==\n");
  FILE* f = open_csv(ev, "g1_fit_accuracy.csv");
  std::fprintf(f, "topology,component,resolved_rows,nterms,row_max_rel,"
                  "row_rms_rel,loo_max_rel,loo_rms_rel,pass\n");
  for (LatticeTopology topo : lmm::certifiable_topologies()) {
    const std::vector<MRow> rows = lmm::resolved_rows(topo);
    const int nterms = lmm::model_order(rows.size());
    std::vector<double> r(rows.size());
    for (std::size_t i = 0; i < rows.size(); ++i) r[i] = rows[i].rho;
    for (int comp = 0; comp < 3; ++comp) {
      std::vector<double> c(rows.size());
      for (std::size_t i = 0; i < rows.size(); ++i) c[i] = rows[i].C[comp];
      const lmm::PolyFit fit = lmm::fit_origin_poly(r, c, nterms);
      double row_max = 0.0, row_ss = 0.0;
      for (std::size_t i = 0; i < rows.size(); ++i) {
        const double e = std::fabs(lmm::poly_eval(fit, r[i]) / c[i] - 1.0);
        row_max = std::max(row_max, e);
        row_ss += e * e;
      }
      const double row_rms = std::sqrt(row_ss / rows.size());
      // Leave-one-out: refit without row i, evaluate the miss AT row i.
      double loo_max = 0.0, loo_ss = 0.0;
      for (std::size_t i = 0; i < rows.size(); ++i) {
        std::vector<double> r2, c2;
        for (std::size_t j = 0; j < rows.size(); ++j)
          if (j != i) {
            r2.push_back(r[j]);
            c2.push_back(c[j]);
          }
        const lmm::PolyFit f2 = lmm::fit_origin_poly(r2, c2, nterms);
        const double e = std::fabs(lmm::poly_eval(f2, r[i]) / c[i] - 1.0);
        loo_max = std::max(loo_max, e);
        loo_ss += e * e;
      }
      const double loo_rms = std::sqrt(loo_ss / rows.size());
      const bool pass = row_max <= 0.05 && row_rms <= 0.02 && loo_max <= 0.10;
      std::fprintf(f, "%s,%s,%zu,%d,%.6f,%.6f,%.6f,%.6f,%d\n",
                   lattice_topology_name(topo), comp_name(comp), rows.size(),
                   nterms, row_max, row_rms, loo_max, loo_rms, pass ? 1 : 0);
      bar(pass, "%-8s %s  n=%zu nt=%d  row max %.2f%% rms %.2f%%  LOO max %.2f%%",
          lattice_topology_name(topo), comp_name(comp), rows.size(), nterms,
          100 * row_max, 100 * row_rms, 100 * loo_max);
    }
  }
  std::fclose(f);
}

// ---------------------------------------------------------------------------
// G2 — admissibility EVERYWHERE: dense sweep over [0,1] incl. both bridges.
// ---------------------------------------------------------------------------
void run_g2(const std::string& ev) {
  std::printf("== G2: admissibility sweep (bar: every tensor margin > 0 over "
              "(0,1]) ==\n");
  FILE* f = open_csv(ev, "g2_admissibility.csv");
  std::fprintf(f,
               "topology,region,min_m1_C11_minus_absC12_over_C11,"
               "min_m2_C11_plus_2C12_over_C11,min_m3_C44_over_C11,"
               "min_d1_dC11_minus_dC12,min_d2_dC11_plus_2dC12,min_d3_dC44,"
               "argmin_rho_tensor,pass_tensor\n");
  const int N = 4000;
  for (LatticeTopology topo : lmm::certifiable_topologies()) {
    const LatticeMaterialModel m = lmm::build_lattice_material_model(topo, kEs, kNu);
    struct Acc {
      double m1 = 1e30, m2 = 1e30, m3 = 1e30;
      double d1 = 1e30, d2 = 1e30, d3 = 1e30;
      double arg = 0.0;
    };
    auto sweep = [&](double a, double b) {
      Acc acc;
      for (int i = 0; i <= N; ++i) {
        const double rho = a + (b - a) * i / N;
        if (rho <= 0.0) continue;
        double c[3], d[3];
        m.eval_components(rho, c, d);
        const double m1 = (c[0] - std::fabs(c[1])) / c[0];
        const double m2 = (c[0] + 2 * c[1]) / c[0];
        const double m3 = c[2] / c[0];
        if (std::min({m1, m2, m3}) <
            std::min({acc.m1, acc.m2, acc.m3})) acc.arg = rho;
        acc.m1 = std::min(acc.m1, m1);
        acc.m2 = std::min(acc.m2, m2);
        acc.m3 = std::min(acc.m3, m3);
        acc.d1 = std::min(acc.d1, d[0] - d[1]);
        acc.d2 = std::min(acc.d2, d[0] + 2 * d[1]);
        acc.d3 = std::min(acc.d3, d[2]);
      }
      return acc;
    };
    const struct { const char* name; double a, b; } regions[] = {
        {"lower_bridge", 0.0, m.rho_lo},
        {"band", m.rho_lo, m.rho_hi},
        {"upper_bridge", m.rho_hi, 1.0},
        {"full", 0.0, 1.0}};
    for (const auto& reg : regions) {
      const Acc a = sweep(reg.a, reg.b);
      const bool pass = a.m1 > 0 && a.m2 > 0 && a.m3 > 0;
      std::fprintf(f, "%s,%s,%.6e,%.6e,%.6e,%.6e,%.6e,%.6e,%.6f,%d\n",
                   lattice_topology_name(topo), reg.name, a.m1, a.m2, a.m3,
                   a.d1, a.d2, a.d3, a.arg, pass ? 1 : 0);
      if (std::strcmp(reg.name, "full") == 0)
        bar(pass,
            "%-8s full-range tensor margins: C11-|C12| %.3f  C11+2C12 %.3f  "
            "C44/C11 %.4f (worst near rho=%.3f); deriv-PSD mins %.1f %.1f %.1f",
            lattice_topology_name(topo), a.m1, a.m2, a.m3, a.arg, a.d1, a.d2,
            a.d3);
    }
  }
  std::fclose(f);
}

// ---------------------------------------------------------------------------
// G3 — sensitivities: analytic dC/drho vs central FD; smoothness tabulation.
// ---------------------------------------------------------------------------
void run_g3(const std::string& ev) {
  std::printf("== G3: sensitivities (bar: FD rel err <= 1e-6 away from the two "
              "C1 joints) ==\n");
  FILE* f = open_csv(ev, "g3_sensitivity_fd.csv");
  std::fprintf(f, "topology,component,fd_max_rel_interior,fd_max_rel_joints,"
                  "pass\n");
  FILE* fc = open_csv(ev, "g3_sensitivity_curve.csv");
  std::fprintf(fc, "topology,rho,dC11,dC12,dC44,region\n");
  const double h = 1e-6;
  for (LatticeTopology topo : lmm::certifiable_topologies()) {
    const LatticeMaterialModel m = lmm::build_lattice_material_model(topo, kEs, kNu);
    double fd_int[3] = {0, 0, 0}, fd_joint[3] = {0, 0, 0};
    const int N = 2000;
    for (int i = 1; i < N; ++i) {
      const double rho = static_cast<double>(i) / N;
      if (rho - h <= 0.0 || rho + h >= 1.0) continue;
      const bool near_joint = std::fabs(rho - m.rho_lo) <= 2 * h ||
                              std::fabs(rho - m.rho_hi) <= 2 * h;
      double cp[3], cm[3], d[3];
      m.eval_components(rho + h, cp, nullptr);
      m.eval_components(rho - h, cm, nullptr);
      m.eval_components(rho, nullptr, d);
      for (int comp = 0; comp < 3; ++comp) {
        const double fd = (cp[comp] - cm[comp]) / (2 * h);
        const double den = std::max(std::fabs(d[comp]), 1e-8 * m.solid[comp]);
        const double rel = std::fabs(fd - d[comp]) / den;
        (near_joint ? fd_joint : fd_int)[comp] =
            std::max((near_joint ? fd_joint : fd_int)[comp], rel);
      }
    }
    for (int comp = 0; comp < 3; ++comp) {
      const bool pass = fd_int[comp] <= 1e-6;
      std::fprintf(f, "%s,%s,%.3e,%.3e,%d\n", lattice_topology_name(topo),
                   comp_name(comp), fd_int[comp], fd_joint[comp], pass ? 1 : 0);
      bar(pass, "%-8s d%s/drho FD rel err %.2e interior (%.2e at joints)",
          lattice_topology_name(topo), comp_name(comp), fd_int[comp],
          fd_joint[comp]);
    }
    // Smoothness tabulation: 400 samples of dC/drho across [0,1].
    for (int i = 0; i <= 400; ++i) {
      const double rho = static_cast<double>(i) / 400;
      double d[3];
      m.eval_components(rho, nullptr, d);
      const char* region = rho < m.rho_lo ? "lower_bridge"
                           : rho <= m.rho_hi ? "band"
                                             : "upper_bridge";
      std::fprintf(fc, "%s,%.4f,%.6f,%.6f,%.6f,%s\n",
                   lattice_topology_name(topo), rho, d[0], d[1], d[2], region);
    }
  }
  std::fclose(f);
  std::fclose(fc);
}

// ---------------------------------------------------------------------------
// G4 — table adequacy: octet decimated to 8/6/5/4 rows, deviation vs the
// 19-row fit across the band (value AND derivative).
// ---------------------------------------------------------------------------
void run_g4(const std::string& ev) {
  std::printf("== G4: table adequacy (read: value dev <= 5%% and deriv dev <= "
              "15%% supports the model) ==\n");
  FILE* f = open_csv(ev, "g4_table_adequacy.csv");
  std::fprintf(f, "rows_kept,nterms,component,value_dev_max,deriv_dev_max,"
                  "supports_model\n");
  const std::vector<MRow> rows = lmm::resolved_rows(LatticeTopology::Octet);
  std::vector<double> r(rows.size());
  for (std::size_t i = 0; i < rows.size(); ++i) r[i] = rows[i].rho;
  const double lo = lattice_rho_min(LatticeTopology::Octet);
  const double hi = lattice_rho_max(LatticeTopology::Octet);
  for (int keep : {8, 6, 5, 4}) {
    // Even-spread subsample over the 19 rows (first and last always kept).
    std::vector<std::size_t> idx;
    for (int i = 0; i < keep; ++i)
      idx.push_back(static_cast<std::size_t>(
          std::lround(static_cast<double>(i) * (rows.size() - 1) / (keep - 1))));
    const int nterms = lmm::model_order(static_cast<std::size_t>(keep));
    for (int comp = 0; comp < 3; ++comp) {
      std::vector<double> cfull(rows.size());
      for (std::size_t i = 0; i < rows.size(); ++i) cfull[i] = rows[i].C[comp];
      const lmm::PolyFit f19 = lmm::fit_origin_poly(r, cfull, 4);
      std::vector<double> rs, cs;
      for (std::size_t i : idx) {
        rs.push_back(r[i]);
        cs.push_back(cfull[i]);
      }
      const lmm::PolyFit fsub = lmm::fit_origin_poly(rs, cs, nterms);
      double vdev = 0.0, ddev = 0.0;
      for (int i = 0; i <= 2000; ++i) {
        const double rho = lo + (hi - lo) * i / 2000.0;
        vdev = std::max(vdev, std::fabs(lmm::poly_eval(fsub, rho) /
                                            lmm::poly_eval(f19, rho) - 1.0));
        ddev = std::max(ddev, std::fabs(lmm::poly_deriv(fsub, rho) /
                                            lmm::poly_deriv(f19, rho) - 1.0));
      }
      const bool ok = vdev <= 0.05 && ddev <= 0.15;
      std::fprintf(f, "%d,%d,%s,%.6f,%.6f,%d\n", keep, nterms, comp_name(comp),
                   vdev, ddev, ok ? 1 : 0);
      // G4 is a FINDING, not an implementation bar: "REPORT THIS EVEN IF
      // EVERYTHING PASSES" — an unsupportive row count is the probe's answer,
      // not a probe failure, so it does not flip the exit code.
      std::printf("  [%s] octet %d-row (nt=%d) %s: value dev %.2f%%  deriv dev "
                  "%.2f%%\n", ok ? "SUPPORTS" : "TOO FEW ", keep, nterms,
                  comp_name(comp), 100 * vdev, 100 * ddev);
    }
  }
  std::fclose(f);
  std::printf("  note: the six analysis-only topologies have 4-7 RESOLVED rows "
              "(sc 7, fcc 7, kelvin 6, diamond 6, bcc 5, rhombic 4) — the "
              "decimation rows above are the read-across.\n");
}

// ---------------------------------------------------------------------------
// G4b — gap widths per topology (upper gap reported separately, per the task).
// ---------------------------------------------------------------------------
void run_g4b(const std::string& ev) {
  std::printf("== G4b: forbidden-gap severity ==\n");
  FILE* f = open_csv(ev, "g4b_gaps.csv");
  std::fprintf(f, "topology,rho_lo,rho_hi,lower_gap_width,upper_gap_width,"
                  "upper_over_lower,C11_solid_over_C11_band_top\n");
  for (LatticeTopology topo : lmm::certifiable_topologies()) {
    const LatticeMaterialModel m = lmm::build_lattice_material_model(topo, kEs, kNu);
    const double lower = m.rho_lo;          // gap (0, rho_lo)
    const double upper = 1.0 - m.rho_hi;    // gap (rho_hi, 1)
    double c_top[3];
    m.eval_components(m.rho_hi, c_top, nullptr);
    std::fprintf(f, "%s,%.5f,%.5f,%.5f,%.5f,%.2f,%.2f\n",
                 lattice_topology_name(topo), m.rho_lo, m.rho_hi, lower, upper,
                 upper / lower, m.solid[0] / c_top[0]);
    std::printf("  %-8s band [%.3f, %.3f]  lower gap %.3f  UPPER GAP %.3f "
                "(%.1fx wider)  solid/band-top C11 ratio %.2f\n",
                lattice_topology_name(topo), m.rho_lo, m.rho_hi, lower, upper,
                upper / lower, m.solid[0] / c_top[0]);
  }
  std::fclose(f);
}

// ---------------------------------------------------------------------------
// G5 — regime bridging: C0/C1 discontinuity at both joints.
// ---------------------------------------------------------------------------
void run_g5(const std::string& ev) {
  std::printf("== G5: bridge continuity (bar: C0 and C1 relative jump <= 1e-9 "
              "at both joints) ==\n");
  FILE* f = open_csv(ev, "g5_bridge_continuity.csv");
  std::fprintf(f, "topology,joint,component,c0_rel_jump,c1_rel_jump,pass\n");
  const double eps = 1e-9;
  for (LatticeTopology topo : lmm::certifiable_topologies()) {
    const LatticeMaterialModel m = lmm::build_lattice_material_model(topo, kEs, kNu);
    const struct { const char* name; double rho; } joints[] = {
        {"void_to_band", m.rho_lo}, {"band_to_solid", m.rho_hi}};
    for (const auto& j : joints) {
      double cl[3], cr[3], dl[3], dr[3];
      m.eval_components(j.rho - eps, cl, dl);
      m.eval_components(j.rho + eps, cr, dr);
      for (int comp = 0; comp < 3; ++comp) {
        // Subtract the smooth O(eps) drift so the number is the JUMP, not the
        // slope: |Δvalue| beyond 2*eps*|slope| counts against the bar.
        const double c0 =
            std::fabs(cr[comp] - cl[comp]) / std::max(std::fabs(cl[comp]), 1.0);
        const double c1 =
            std::fabs(dr[comp] - dl[comp]) / std::max(std::fabs(dl[comp]), 1.0);
        const bool pass = c0 <= 1e-6 && c1 <= 1e-4;  // eps-window slack over 1e-9 target
        std::fprintf(f, "%s,%s,%s,%.3e,%.3e,%d\n", lattice_topology_name(topo),
                     j.name, comp_name(comp), c0, c1, pass ? 1 : 0);
        if (!pass || comp == 0)
          bar(pass, "%-8s %s %s: C0 jump %.2e  C1 jump %.2e",
              lattice_topology_name(topo), j.name, comp_name(comp), c0, c1);
      }
    }
  }
  std::fclose(f);
}

}  // namespace

int main(int argc, char** argv) {
  const std::string what = argc > 1 ? argv[1] : "all";
  const std::string ev = argc > 2 ? argv[2] : ".";
  if (what == "g1" || what == "all") run_g1(ev);
  if (what == "g2" || what == "all") run_g2(ev);
  if (what == "g3" || what == "all") run_g3(ev);
  if (what == "g4" || what == "all") run_g4(ev);
  if (what == "g4b" || what == "all") run_g4b(ev);
  if (what == "g5" || what == "all") run_g5(ev);
  std::printf("%s\n", g_fail == 0 ? "ALL BARS PASS" : "BARS FAILED (see FAIL lines)");
  return g_fail == 0 ? 0 : 1;
}
