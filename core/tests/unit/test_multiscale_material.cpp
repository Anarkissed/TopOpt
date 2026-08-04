// test_multiscale_material.cpp — unit tests for the PRODUCTION multiscale lattice
// material model (topopt/lattice_material.hpp) and the exact three-block element
// decomposition the SIMP loop differentiates against (hex8_cubic_blocks).
//
// This is the production sibling of test_lattice_material_model.cpp, which pins the
// HARNESS prototype the probe measured. The two differ in one load-bearing way: the
// harness header TRANSCRIBED the library rows and needed a pinning test to catch
// drift; production READS them (lattice_resolved_rows), so drift is impossible by
// construction — and bar 1 below asserts that the rows it reads are the rows
// lattice_cubic_tensor interpolates.
//
// The bars:
//   1. ROWS COME FROM CORE — every row lattice_resolved_rows hands out reproduces
//      lattice_cubic_tensor at the row's own rho exactly (interpolation weight is 0
//      at an anchor), and the first/last row rho equal lattice_rho_min/max.
//   2. REACHES THE ENDS — C(0) is the zero tensor; C(1) is the exact isotropic
//      solid triplet, so an optimizer can hold void and solid.
//   3. C0/C1 AT BOTH JOINTS — the bridges match value AND slope by construction.
//   4. SENSITIVITIES vs CENTRAL DIFFERENCES — the analytic dC/drho the optimizer
//      steers on, checked against central FD away from the two joints. This is the
//      task's item-2 bar.
//   5. FIT ACCURACY — every resolved row reproduced within the probe's stated G1
//      bar (5% max relative error).
//   6. ADMISSIBILITY over (0, 1] — cubic-admissible AND accepted by the production
//      element's own check, with dC/drho PSD (monotone stiffness => one-signed
//      compliance sensitivities), for every certifiable topology.
//   7. REFUSAL — a topology with no validated rows is refused, and
//      lattice_material_model_trustworthy admits ONLY octet.
//   8. THE THREE-BLOCK DECOMPOSITION — C11*K_A + C12*K_B + C44*K_C recomposes
//      hex8_stiffness_cubic to summation roundoff, on the model's own curve. This
//      is what makes the multiscale compliance and sensitivity exact rather than
//      approximate.
//   9. THE FEASIBLE-SET PROJECTION — nearest-feasible, idempotent, deterministic
//      tie-break, and a CHARGE that accounts exactly (before + delta == after).

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/lattice.hpp"
#include "topopt/lattice_material.hpp"

using namespace topopt;

namespace {
int g_fail = 0;
void check(bool ok, const char* msg) {
  std::printf("  [%s] %s\n", ok ? "PASS" : "FAIL", msg);
  if (!ok) ++g_fail;
}
constexpr double kEs = 3500.0;
constexpr double kNu = 0.33;

std::vector<LatticeTopology> certifiable() {
  using T = LatticeTopology;
  return {T::Octet, T::SimpleCubic, T::Bcc,    T::Fcc,
          T::Diamond, T::Kelvin,    T::Rhombic};
}

double rel(double a, double b) {
  const double d = std::fabs(a - b);
  const double m = std::max(std::fabs(a), std::fabs(b));
  return m > 0.0 ? d / m : d;
}

}  // namespace

int main() {
  // ── 1. the rows production fits come FROM CORE ─────────────────────────────
  {
    std::printf("rows_from_core\n");
    double worst = 0.0;
    bool endpoints_ok = true, nonempty = true;
    for (LatticeTopology t : certifiable()) {
      const std::vector<LatticeResolvedRow> rows = lattice_resolved_rows(t);
      if (rows.empty()) { nonempty = false; continue; }
      for (const LatticeResolvedRow& r : rows) {
        const CubicTensor c = lattice_cubic_tensor(t, r.rho, kEs);
        worst = std::max(worst, rel(c.C11, r.C11));
        worst = std::max(worst, rel(c.C12, r.C12));
        worst = std::max(worst, rel(c.C44, r.C44));
      }
      endpoints_ok = endpoints_ok && rows.front().rho == lattice_rho_min(t) &&
                     rows.back().rho == lattice_rho_max(t);
    }
    check(nonempty, "every certifiable topology hands out resolved rows");
    std::printf("    worst row-vs-library rel err = %.3g\n", worst);
    check(worst < 1e-12,
          "lattice_resolved_rows reproduces lattice_cubic_tensor at every row");
    check(endpoints_ok,
          "first/last row rho equal lattice_rho_min / lattice_rho_max");
    check(lattice_library_youngs_modulus() == kEs,
          "library basis modulus is the PLA 3500 MPa the rows are measured at");
  }

  // ── 2. the curve REACHES void and solid ────────────────────────────────────
  {
    std::printf("reaches_ends\n");
    const LatticeMaterialModel m =
        build_lattice_material_model(LatticeTopology::Octet, kEs, kNu);
    const CubicTensor at0 = m.value(0.0);
    const CubicTensor at1 = m.value(1.0);
    const double c = kEs / ((1 + kNu) * (1 - 2 * kNu));
    check(at0.C11 == 0.0 && at0.C12 == 0.0 && at0.C44 == 0.0,
          "C(0) is the zero tensor");
    const double worst = std::max({rel(at1.C11, c * (1 - kNu)),
                                   rel(at1.C12, c * kNu),
                                   rel(at1.C44, kEs / (2 * (1 + kNu)))});
    std::printf("    worst solid-corner rel err = %.3g\n", worst);
    check(worst < 1e-14, "C(1) is the exact isotropic solid triplet");
    // ... and that triplet IS what hex8_stiffness reduces to.
    const Hex8Stiffness Kc =
        hex8_stiffness_cubic(at1.C11, at1.C12, at1.C44, 1.0);
    const Hex8Stiffness Ki = hex8_stiffness(kEs, kNu, 1.0);
    double kw = 0.0;
    for (int r = 0; r < 24; ++r)
      for (int cc = 0; cc < 24; ++cc) kw = std::max(kw, rel(Kc(r, cc), Ki(r, cc)));
    std::printf("    worst Ke(solid triplet) vs hex8_stiffness rel err = %.3g\n", kw);
    check(kw < 1e-12, "the solid corner reproduces the isotropic element");
  }

  // ── 3. C0 / C1 at both regime joints ───────────────────────────────────────
  {
    std::printf("joint_continuity\n");
    const double h = 1e-9;
    double worst_c0 = 0.0, worst_c1 = 0.0;
    for (LatticeTopology t : certifiable()) {
      const LatticeMaterialModel m = build_lattice_material_model(t, kEs, kNu);
      for (double joint : {m.rho_lo, m.rho_hi}) {
        double cl[3], cr[3], dl[3], dr[3];
        m.eval(joint - h, cl, dl);
        m.eval(joint + h, cr, dr);
        for (int i = 0; i < 3; ++i) {
          worst_c0 = std::max(worst_c0, rel(cl[i], cr[i]));
          worst_c1 = std::max(worst_c1, rel(dl[i], dr[i]));
        }
      }
    }
    std::printf("    worst C0 jump = %.3g, worst C1 jump = %.3g\n", worst_c0,
                worst_c1);
    // The residual is the smooth slope drift across the 2e-9 window, not a
    // discontinuity — the joints are C1 by construction.
    check(worst_c0 < 1e-6, "value is continuous at both joints");
    check(worst_c1 < 1e-6, "slope is continuous at both joints");
  }

  // ── 4. SENSITIVITIES vs CENTRAL DIFFERENCES (task item 2) ──────────────────
  {
    std::printf("sensitivity_fd\n");
    const double h = 1e-6;
    double worst_interior = 0.0, worst_joint = 0.0;
    long n_interior = 0;
    for (LatticeTopology t : certifiable()) {
      const LatticeMaterialModel m = build_lattice_material_model(t, kEs, kNu);
      for (int s = 1; s < 2000; ++s) {
        const double rho = static_cast<double>(s) / 2000.0;
        double cp[3], cm[3], d[3];
        m.eval(rho + h, cp, nullptr);
        m.eval(rho - h, cm, nullptr);
        m.eval(rho, nullptr, d);
        // Near a C1 joint central differences straddle a curvature jump, so the
        // O(h |dC''|) error there is EXPECTED and is reported separately rather
        // than folded into the interior bar (the probe did the same).
        const bool near_joint = std::fabs(rho - m.rho_lo) < 2 * h ||
                                std::fabs(rho - m.rho_hi) < 2 * h;
        for (int i = 0; i < 3; ++i) {
          const double fd = (cp[i] - cm[i]) / (2 * h);
          const double e = rel(fd, d[i]);
          if (near_joint) worst_joint = std::max(worst_joint, e);
          else { worst_interior = std::max(worst_interior, e); ++n_interior; }
        }
      }
    }
    std::printf("    worst interior FD rel err = %.3g over %ld samples\n",
                worst_interior, n_interior);
    std::printf("    worst at-joint FD rel err = %.3g (expected O(h*|dC''|))\n",
                worst_joint);
    check(worst_interior <= 1e-6,
          "analytic dC/drho matches central differences away from the joints");
  }

  // ── 5. fit accuracy (the probe's G1 bar) ───────────────────────────────────
  {
    std::printf("fit_accuracy\n");
    double worst = 0.0;
    const char* worst_topo = "";
    for (LatticeTopology t : certifiable()) {
      const LatticeMaterialModel m = build_lattice_material_model(t, kEs, kNu);
      for (const LatticeResolvedRow& r : lattice_resolved_rows(t)) {
        const CubicTensor c = m.value(r.rho);
        const double e = std::max({rel(c.C11, r.C11), rel(c.C12, r.C12),
                                   rel(c.C44, r.C44)});
        if (e > worst) { worst = e; worst_topo = lattice_topology_name(t); }
      }
    }
    std::printf("    worst row error = %.3f%% (%s)\n", 100 * worst, worst_topo);
    check(worst <= 0.05, "every resolved row is reproduced within 5%");
  }

  // ── 6. admissibility + derivative PSD over (0, 1] ──────────────────────────
  {
    std::printf("admissibility\n");
    bool ok = true, deriv_psd = true, element_ok = true;
    double worst_margin = 1e30;
    for (LatticeTopology t : certifiable()) {
      const LatticeMaterialModel m = build_lattice_material_model(t, kEs, kNu);
      for (int s = 1; s <= 4000; ++s) {
        const double rho = static_cast<double>(s) / 4000.0;
        double c[3], d[3];
        m.eval(rho, c, d);
        ok = ok && c[0] > 0.0 && c[0] > std::fabs(c[1]) &&
             c[0] + 2 * c[1] > 0.0 && c[2] > 0.0;
        worst_margin = std::min(worst_margin,
                                std::min({(c[0] - std::fabs(c[1])) / c[0],
                                          (c[0] + 2 * c[1]) / c[0], c[2] / c[0]}));
        // dC/drho PSD is what makes stiffness monotone in rho and the compliance
        // sensitivity one-signed — the property the optimizer needs to steer.
        deriv_psd = deriv_psd && d[0] - d[1] > 0.0 && d[0] + 2 * d[1] > 0.0 &&
                    d[2] > 0.0;
        try {
          (void)hex8_stiffness_cubic(c[0], c[1], c[2], 1.0);
        } catch (const std::exception&) {
          element_ok = false;
        }
      }
    }
    std::printf("    worst normalized admissibility margin = %.4f\n", worst_margin);
    check(ok, "the tensor is cubic-admissible at every point of (0, 1]");
    check(element_ok, "hex8_stiffness_cubic ACCEPTS the whole curve");
    check(deriv_psd, "dC/drho is PSD at every point of (0, 1]");
  }

  // ── 7. refusals ────────────────────────────────────────────────────────────
  {
    std::printf("refusals\n");
    bool threw = false;
    try {
      (void)build_lattice_material_model(LatticeTopology::Bccz, kEs, kNu);
    } catch (const LatticeTopologyNotCertifiable&) {
      threw = true;
    }
    check(threw, "a tetragonal topology is REFUSED, not silently defaulted");
    std::string why;
    check(lattice_material_model_trustworthy(LatticeTopology::Octet, &why) &&
              why.empty(),
          "octet is trustworthy to steer a design loop on");
    int untrusted = 0;
    for (LatticeTopology t : certifiable()) {
      if (t == LatticeTopology::Octet) continue;
      std::string r;
      if (!lattice_material_model_trustworthy(t, &r)) {
        ++untrusted;
        if (r.empty()) { check(false, "a refusal must carry a reason"); }
      }
    }
    std::printf("    %d of the 6 non-octet certifiable topologies refused\n",
                untrusted);
    check(untrusted == 6,
          "only octet may steer a design loop today (the others need rows "
          "above ~0.6)");
    check(!lattice_material_model_trustworthy(LatticeTopology::Bccz),
          "a non-certifiable topology is never trustworthy");
  }

  // ── 8. the exact three-block decomposition on the model's own curve ────────
  {
    std::printf("three_block_decomposition\n");
    const double hspacing = 1.7;  // a non-unit element, so scaling is exercised
    Hex8Stiffness KA, KB, KC;
    hex8_cubic_blocks(hspacing, KA, KB, KC);
    const LatticeMaterialModel m =
        build_lattice_material_model(LatticeTopology::Octet, kEs, kNu);
    double worst = 0.0;
    for (int s = 1; s <= 200; ++s) {
      const double rho = static_cast<double>(s) / 200.0;
      const CubicTensor c = m.value(rho);
      const Hex8Stiffness Ke =
          hex8_stiffness_cubic(c.C11, c.C12, c.C44, hspacing);
      for (int r = 0; r < 24; ++r)
        for (int cc = 0; cc < 24; ++cc) {
          const double blocks =
              c.C11 * KA(r, cc) + c.C12 * KB(r, cc) + c.C44 * KC(r, cc);
          worst = std::max(worst, rel(blocks, Ke(r, cc)));
        }
    }
    std::printf("    worst recomposition rel err = %.3g\n", worst);
    check(worst < 1e-12,
          "C11*K_A + C12*K_B + C44*K_C recomposes hex8_stiffness_cubic "
          "(the identity the multiscale sensitivity leans on)");
  }

  // ── 9. the feasible-set projection and its CHARGE ──────────────────────────
  {
    std::printf("projection\n");
    const LatticeMaterialModel m =
        build_lattice_material_model(LatticeTopology::Octet, kEs, kNu);
    const double vb = 1e-3, sa = 1.0 - vb;
    // Nearest-feasible, on hand-picked points either side of each gap's midpoint.
    const double mid_lo = 0.5 * m.rho_lo;
    const double mid_up = 0.5 * (m.rho_hi + 1.0);
    check(lattice_project_density(m, mid_lo * 0.5, vb, sa) == 0.0,
          "a low lower-gap density snaps to void");
    check(lattice_project_density(m, m.rho_lo * 0.99, vb, sa) == m.rho_lo,
          "a high lower-gap density snaps to the band floor");
    check(lattice_project_density(m, m.rho_hi * 1.001, vb, sa) == m.rho_hi,
          "a low upper-gap density snaps to the band ceiling");
    check(lattice_project_density(m, 1.0 - (1.0 - mid_up) * 0.5, vb, sa) == 1.0,
          "a high upper-gap density snaps to solid");
    // Deterministic tie-break: exactly mid-gap goes DOWN (the lighter choice).
    check(lattice_project_density(m, mid_lo, vb, sa) == 0.0,
          "an exact lower-gap tie resolves downward");
    check(lattice_project_density(m, mid_up, vb, sa) == m.rho_hi,
          "an exact upper-gap tie resolves downward");
    // In-band and already-feasible values are UNTOUCHED.
    const double inband = 0.5 * (m.rho_lo + m.rho_hi);
    check(lattice_project_density(m, inband, vb, sa) == inband,
          "an in-band density is returned unchanged");

    // The charge accounts exactly, and the projection is IDEMPOTENT.
    std::vector<double> d;
    for (int s = 0; s <= 1000; ++s) d.push_back(static_cast<double>(s) / 1000.0);
    std::vector<double> d2 = d;
    const LatticeProjectionReport p1 = lattice_project_field(
        m, d2, nullptr, vb, sa, static_cast<double>(d2.size()), 0.5);
    check(std::fabs((p1.volume_before + p1.volume_delta) - p1.volume_after) <
              1e-9 * std::max(1.0, p1.volume_after),
          "the projection charge accounts exactly (before + delta == after)");
    check(p1.voxels_considered == d2.size(),
          "every voxel was considered when no mask is supplied");
    check(p1.projected_lower + p1.projected_upper > 0,
          "the sweep really did cross both gaps");
    std::printf("    projected %zu lower + %zu upper; dV = %+.4f; "
                "violation = %+.4f%%\n",
                p1.projected_lower, p1.projected_upper, p1.volume_delta,
                100 * p1.volume_constraint_violation);
    std::vector<double> d3 = d2;
    const LatticeProjectionReport p2 = lattice_project_field(
        m, d3, nullptr, vb, sa, static_cast<double>(d3.size()), 0.5);
    check(p2.projected_lower == 0 && p2.projected_upper == 0 &&
              p2.volume_delta == 0.0 && d3 == d2,
          "projecting a feasible field is the identity (idempotent)");
    // Nothing survives in a gap.
    std::size_t survivors = 0;
    for (double v : d2) {
      const LatticeDensityClass c = lattice_density_class(m, v, vb, sa);
      if (c == LatticeDensityClass::LowerGap || c == LatticeDensityClass::UpperGap)
        ++survivors;
    }
    check(survivors == 0, "no voxel survives inside a forbidden interval");

    // A mask restricts the projection to the region — voxels outside it keep the
    // ordinary SIMP grayscale the non-lattice path already handles.
    std::vector<double> d4(4, mid_lo);
    const std::vector<char> mask{1, 0, 1, 0};
    const LatticeProjectionReport p3 =
        lattice_project_field(m, d4, &mask, vb, sa, 0.0, 0.0);
    check(p3.voxels_considered == 2 && d4[0] == 0.0 && d4[1] == mid_lo &&
              d4[2] == 0.0 && d4[3] == mid_lo,
          "a mask confines the projection to the lattice region");
    check(p3.volume_constraint_violation == 0.0,
          "no target supplied => no violation claimed");
  }

  std::printf("%s\n", g_fail == 0 ? "ALL PASS" : "FAILURES");
  return g_fail == 0 ? 0 : 1;
}
