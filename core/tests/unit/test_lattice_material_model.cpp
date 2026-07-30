// test_lattice_material_model.cpp — unit tests for the HARNESS lattice
// material model C(rho) (multiscale-lattice-feasibility probe,
// 2026-07-31-multiscale-lattice-feasibility;
// core/tests/harness/lattice_material_model.hpp).
//
// The model is harness-side (no production file consumes it); these tests pin
// the properties Part 2 of the probe leans on:
//   1. TRANSCRIPTION — every resolved row in the harness header reproduces the
//      PRODUCTION library (lattice_cubic_tensor at the row rho returns the row
//      exactly: interpolation weight is 0 at an anchor), and the model's band
//      endpoints equal lattice_rho_min/lattice_rho_max read from core. A core
//      table change breaks this test instead of silently skewing the fit.
//   2. REACHES THE ENDS — C(0) is the zero tensor and C(1) is the exact
//      isotropic solid triplet (the triplet hex8_stiffness_cubic reduces to
//      hex8_stiffness with), so an optimizer can hold void and solid.
//   3. CONTINUITY — C0 and C1 at both regime joints (the bridges match value
//      and slope by construction; this catches an implementation slip).
//   4. SENSITIVITIES — analytic dC/drho matches central finite differences of
//      the model away from the joints.
//   5. FIT ACCURACY — the in-band fit reproduces every resolved row within the
//      probe's stated G1 bar (5% max relative error).
//   6. ADMISSIBILITY — on a dense sweep of (0, 1] the tensor stays
//      cubic-admissible (C11 > 0, C11 > |C12|, C11 + 2*C12 > 0, C44 > 0) and
//      hex8_stiffness_cubic ACCEPTS it (the production element's own check),
//      and dC/drho stays PSD (monotone stiffness — one-signed compliance
//      sensitivities), for every certifiable topology. Measured first by the
//      probe's G2 sweep; asserted here so a regression is loud.
//   7. REFUSAL — a topology with no validated rows (tetragonal) is refused.

#include <cmath>
#include <cstdio>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/lattice.hpp"

#include "../harness/lattice_material_model.hpp"

using namespace topopt;
using lmm::LatticeMaterialModel;
using lmm::MRow;

namespace {
int g_fail = 0;
void check(bool ok, const char* msg) {
  std::printf("  [%s] %s\n", ok ? "PASS" : "FAIL", msg);
  if (!ok) ++g_fail;
}
constexpr double kEs = 3500.0;
constexpr double kNu = 0.33;
}  // namespace

int main() {
  std::printf("== 1. transcription pins to the production library ==\n");
  for (LatticeTopology topo : lmm::certifiable_topologies()) {
    const std::vector<MRow> rows = lmm::resolved_rows(topo);
    bool rows_ok = !rows.empty();
    for (const MRow& r : rows) {
      const CubicTensor t = lattice_cubic_tensor(topo, r.rho, lmm::kLibraryEs);
      rows_ok = rows_ok && std::fabs(t.C11 - r.C[0]) <= 1e-9 &&
                std::fabs(t.C12 - r.C[1]) <= 1e-9 &&
                std::fabs(t.C44 - r.C[2]) <= 1e-9;
    }
    char msg[128];
    std::snprintf(msg, sizeof msg,
                  "%s: every resolved row == lattice_cubic_tensor at the anchor",
                  lattice_topology_name(topo));
    check(rows_ok, msg);
    const bool band_ok = rows.front().rho == lattice_rho_min(topo) &&
                         rows.back().rho == lattice_rho_max(topo);
    std::snprintf(msg, sizeof msg,
                  "%s: first/last row rho == core band endpoints",
                  lattice_topology_name(topo));
    check(band_ok, msg);
  }

  std::printf("== 2. the model reaches 0 and 1 ==\n");
  {
    const LatticeMaterialModel m =
        lmm::build_lattice_material_model(LatticeTopology::Octet, kEs, kNu);
    const CubicTensor z = m.value(0.0);
    check(z.C11 == 0.0 && z.C12 == 0.0 && z.C44 == 0.0,
          "C(0) is the zero tensor");
    const CubicTensor s = m.value(1.0);
    const double c = kEs / ((1 + kNu) * (1 - 2 * kNu));
    check(std::fabs(s.C11 - c * (1 - kNu)) <= 1e-9 &&
              std::fabs(s.C12 - c * kNu) <= 1e-9 &&
              std::fabs(s.C44 - kEs / (2 * (1 + kNu))) <= 1e-9,
          "C(1) is the exact isotropic solid triplet");
    // ... and that triplet is the one the production element treats as
    // isotropic (hex8_stiffness_cubic docs: identical D -> identical Ke).
    const Hex8Stiffness Ki = hex8_stiffness(kEs, kNu, 1.0);
    const Hex8Stiffness Kc = hex8_stiffness_cubic(s.C11, s.C12, s.C44, 1.0);
    double dK = 0.0;
    for (int i = 0; i < 576; ++i) dK = std::max(dK, std::fabs(Ki.k[i] - Kc.k[i]));
    check(dK == 0.0, "C(1) element == hex8_stiffness(E, nu) bit-for-bit");
  }

  std::printf("== 3. C0/C1 continuity at both joints ==\n");
  for (LatticeTopology topo : lmm::certifiable_topologies()) {
    const LatticeMaterialModel m = lmm::build_lattice_material_model(topo, kEs, kNu);
    bool ok = true;
    for (double joint : {m.rho_lo, m.rho_hi}) {
      double cl[3], cr[3], dl[3], dr[3];
      m.eval_components(joint - 1e-9, cl, dl);
      m.eval_components(joint + 1e-9, cr, dr);
      for (int i = 0; i < 3; ++i) {
        ok = ok && std::fabs(cr[i] - cl[i]) <= 1e-6 * std::fabs(cl[i]) + 1e-9;
        ok = ok && std::fabs(dr[i] - dl[i]) <= 1e-4 * std::fabs(dl[i]) + 1e-6;
      }
    }
    char msg[96];
    std::snprintf(msg, sizeof msg, "%s: C0 and C1 hold at both joints",
                  lattice_topology_name(topo));
    check(ok, msg);
  }

  std::printf("== 4. analytic dC/drho == central FD ==\n");
  {
    const LatticeMaterialModel m =
        lmm::build_lattice_material_model(LatticeTopology::Octet, kEs, kNu);
    const double h = 1e-6;
    double worst = 0.0;
    for (int i = 1; i < 200; ++i) {
      const double rho = i / 200.0;
      if (std::fabs(rho - m.rho_lo) <= 2 * h || std::fabs(rho - m.rho_hi) <= 2 * h)
        continue;
      double cp[3], cm[3], d[3];
      m.eval_components(rho + h, cp, nullptr);
      m.eval_components(rho - h, cm, nullptr);
      m.eval_components(rho, nullptr, d);
      for (int comp = 0; comp < 3; ++comp) {
        const double fd = (cp[comp] - cm[comp]) / (2 * h);
        const double den = std::max(std::fabs(d[comp]), 1e-8 * m.solid[comp]);
        worst = std::max(worst, std::fabs(fd - d[comp]) / den);
      }
    }
    check(worst <= 1e-6, "octet dC/drho matches FD to 1e-6 away from joints");
  }

  std::printf("== 5. in-band fit reproduces the rows (G1 bar: 5%%) ==\n");
  for (LatticeTopology topo : lmm::certifiable_topologies()) {
    const LatticeMaterialModel m = lmm::build_lattice_material_model(
        topo, lmm::kLibraryEs, kNu);
    double worst = 0.0;
    for (const MRow& r : lmm::resolved_rows(topo)) {
      double c[3];
      m.eval_components(r.rho, c, nullptr);
      for (int comp = 0; comp < 3; ++comp)
        worst = std::max(worst, std::fabs(c[comp] / r.C[comp] - 1.0));
    }
    char msg[96];
    std::snprintf(msg, sizeof msg, "%s: worst row error %.2f%% <= 5%%",
                  lattice_topology_name(topo), 100 * worst);
    check(worst <= 0.05, msg);
  }

  std::printf("== 6. admissibility + monotonicity over (0, 1] ==\n");
  for (LatticeTopology topo : lmm::certifiable_topologies()) {
    const LatticeMaterialModel m = lmm::build_lattice_material_model(topo, kEs, kNu);
    bool adm = true, mono = true, elem_ok = true;
    for (int i = 1; i <= 1000; ++i) {
      const double rho = i / 1000.0;
      double c[3], d[3];
      m.eval_components(rho, c, d);
      adm = adm && c[0] > 0 && c[0] > std::fabs(c[1]) && c[0] + 2 * c[1] > 0 &&
            c[2] > 0;
      mono = mono && d[0] - d[1] > -1e-9 && d[0] + 2 * d[1] > -1e-9 &&
             d[2] > -1e-9;
      if (i % 100 == 0) {  // the production element's own check, sampled
        try {
          hex8_stiffness_cubic(c[0], c[1], c[2], 1.0);
        } catch (...) {
          elem_ok = false;
        }
      }
    }
    char msg[112];
    std::snprintf(msg, sizeof msg,
                  "%s: cubic-admissible everywhere, dC/drho PSD, element accepts",
                  lattice_topology_name(topo));
    check(adm && mono && elem_ok, msg);
  }

  std::printf("== 7. tetragonal topologies are refused ==\n");
  {
    bool threw = false;
    try {
      lmm::build_lattice_material_model(LatticeTopology::Bccz, kEs, kNu);
    } catch (const std::invalid_argument&) {
      threw = true;
    }
    check(threw, "bccz (no validated cubic rows) is refused");
  }

  std::printf("%s\n", g_fail == 0 ? "ALL PASS" : "FAILURES");
  return g_fail == 0 ? 0 : 1;
}
