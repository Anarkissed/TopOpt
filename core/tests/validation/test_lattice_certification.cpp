// test_lattice_certification.cpp — lattice certification Phase 1
// (handoff 2026-07-27-lattice-certification).
//
// Covers the production capability this task adds:
//   1. hex8_stiffness_cubic with an isotropic tensor == hex8_stiffness bit-for-bit,
//      and hex8_stress_cubic likewise (the cubic path is a strict generalisation).
//   2. The octet lattice library returns the measured PR 198 tensors: anisotropic
//      (Zener != 1), monotone in rho, linear in Es, clamped to the resolved range.
//   3. fea_solve_cg_lattice with an all-zero mask == graded fea_solve_cg bit-for-bit
//      (the byte-identical-OFF invariant at the solver level).
//   4. analyze_fixed_design certifies a COMPOSITE object: a lattice posture carries
//      the tensor in the region (softer field, lighter mass), populates the lattice
//      report fields, flags strut strength uncertified, and — with no posture — is
//      byte-identical to the pre-lattice call (C1).
//   5. C4: the accept gate runs at the EXACT margin_stop constant on the composite;
//      a threshold a hair above the composite's worst-case margin REJECTS. Asserted
//      against the named value, not commented.

#include <cmath>
#include <cstdio>
#include <vector>

#include "topopt/analyze.hpp"
#include "topopt/fea.hpp"
#include "topopt/lattice.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {
int g_fail = 0;
void check(bool ok, const char* msg) {
  std::printf("  [%s] %s\n", ok ? "PASS" : "FAIL", msg);
  if (!ok) ++g_fail;
}

VoxelGrid solid_grid(int nx, int ny, int nz, double h) {
  VoxelGrid g;
  g.nx = nx; g.ny = ny; g.nz = nz; g.spacing = h; g.origin = Vec3{0, 0, 0};
  g.tags.assign((std::size_t)nx * ny * nz, VoxelTag::Interior);
  return g;
}
Material pla() {
  Material m;
  m.youngs_modulus_mpa = 3500.0; m.yield_strength_mpa = 50.0;
  m.density_g_cm3 = 1.24; m.z_knockdown = 0.8; m.poisson = 0.33; m.family = "fdm";
  return m;
}
double max_abs_uz(const FeaSolution& s) {
  double m = 0;
  for (std::size_t i = 2; i < s.u.size(); i += 3) m = std::max(m, std::fabs(s.u[i]));
  return m;
}
}  // namespace

int main() {
  const double E = 3500.0, nu = 0.33, h = 1.5;

  std::printf("== 1. cubic element / stress reduce to isotropic ==\n");
  {
    const double c = E / ((1 + nu) * (1 - 2 * nu));
    const double C11 = c * (1 - nu), C12 = c * nu, C44 = E / (2 * (1 + nu));
    Hex8Stiffness Ki = hex8_stiffness(E, nu, h);
    Hex8Stiffness Kc = hex8_stiffness_cubic(C11, C12, C44, h);
    double dK = 0;
    for (int i = 0; i < 576; ++i) dK = std::max(dK, std::fabs(Ki.k[i] - Kc.k[i]));
    check(dK == 0.0, "hex8_stiffness_cubic(iso tensor) == hex8_stiffness bit-for-bit");

    std::array<double, 24> u{};
    for (int i = 0; i < 24; ++i) u[i] = 0.001 * ((i * 7) % 5 - 2);
    Hex8Stress si = hex8_stress(E, nu, h, u);
    Hex8Stress scu = hex8_stress_cubic(C11, C12, C44, h, u);
    double dvm = std::fabs(si.von_mises - scu.von_mises);
    check(dvm == 0.0, "hex8_stress_cubic(iso tensor) == hex8_stress bit-for-bit");

    bool threw = false;
    try { hex8_stiffness_cubic(100.0, 200.0, 10.0, h); }  // C11 - C12 < 0
    catch (const std::invalid_argument&) { threw = true; }
    check(threw, "non-positive-definite cubic tensor is rejected");
  }

  std::printf("== 2. octet lattice library ==\n");
  {
    bool clamped = false;
    CubicTensor t = lattice_cubic_tensor(LatticeTopology::Octet, 0.30, E, &clamped);
    // PR 198 octet at rho~0.30: C11~374, C12~152, C44~135 at Es=3500 (interpolated).
    check(t.C11 > 300 && t.C11 < 450, "octet C11 at rho=0.30 in measured band");
    check(!clamped, "rho=0.30 is within the resolved range (not clamped)");
    double zener = 2.0 * t.C44 / (t.C11 - t.C12);
    check(zener > 1.05, "octet is anisotropic (Zener > 1.05 — a scalar would misrepresent)");

    // linear in Es
    CubicTensor t2 = lattice_cubic_tensor(LatticeTopology::Octet, 0.30, 7000.0, nullptr);
    check(std::fabs(t2.C11 - 2.0 * t.C11) < 1e-9 * t2.C11, "tensor scales linearly in Es");

    // monotone in rho
    CubicTensor lo = lattice_cubic_tensor(LatticeTopology::Octet, 0.20, E, nullptr);
    CubicTensor hi = lattice_cubic_tensor(LatticeTopology::Octet, 0.50, E, nullptr);
    check(lo.C11 < t.C11 && t.C11 < hi.C11, "C11 increases with relative density");

    // clamped below the resolved minimum
    lattice_cubic_tensor(LatticeTopology::Octet, 0.02, E, &clamped);
    check(clamped, "a rho below the resolved range is clamped and flagged");
    // PR 237 widened the certified OCTET band to ~0.05..0.90 (was ~0.148..0.591).
    check(lattice_rho_min(LatticeTopology::Octet) > 0.04 &&
          lattice_rho_min(LatticeTopology::Octet) < 0.10 &&
          lattice_rho_max(LatticeTopology::Octet) > 0.85, "resolved range reported");
  }

  std::printf("== 2a. nine-topology tensor library (2026-07-29-tensor-library-nine) ==\n");
  {
    // B2 — octet rows UNCHANGED: at the exact anchor rho the library returns the
    // shipped PR 198 numbers byte-for-byte (interpolation weight is 0 at an anchor).
    CubicTensor oc = lattice_cubic_tensor(LatticeTopology::Octet, 0.29731, E, nullptr);
    check(std::fabs(oc.C11 - 374.2029) < 1e-9 && std::fabs(oc.C12 - 151.9733) < 1e-9 &&
          std::fabs(oc.C44 - 135.0535) < 1e-9, "B2: octet anchor row is byte-identical");

    // The seven cubic topologies are certifiable; the three tetragonal ones are not.
    check(lattice_topology_certifiable(LatticeTopology::SimpleCubic) &&
          lattice_topology_certifiable(LatticeTopology::Bcc) &&
          lattice_topology_certifiable(LatticeTopology::Fcc) &&
          lattice_topology_certifiable(LatticeTopology::Diamond) &&
          lattice_topology_certifiable(LatticeTopology::Kelvin) &&
          lattice_topology_certifiable(LatticeTopology::Rhombic),
          "the six new cubic topologies are certifiable");
    check(!lattice_topology_certifiable(LatticeTopology::Bccz) &&
          !lattice_topology_certifiable(LatticeTopology::Fccz) &&
          !lattice_topology_certifiable(LatticeTopology::Reentrant),
          "the three tetragonal topologies are NOT certifiable");
    check(lattice_certifiable_topology_names().size() == 7,
          "certifiable-names accessor lists exactly the 7 cubic topologies");

    // A new cubic topology (diamond) returns a valid, anisotropic, monotone,
    // Es-linear tensor with a reported band.
    CubicTensor d = lattice_cubic_tensor(LatticeTopology::Diamond, 0.30, E, nullptr);
    check(d.C11 > d.C12 && d.C44 > 0, "diamond tensor positive-definite shape");
    check(std::fabs(2.0 * d.C44 / (d.C11 - d.C12) - 1.0) > 0.05,
          "diamond is anisotropic (Zener != 1)");
    CubicTensor dlo = lattice_cubic_tensor(LatticeTopology::Diamond, 0.20, E, nullptr);
    check(dlo.C11 < d.C11, "diamond C11 increases with rho");
    check(lattice_rho_min(LatticeTopology::Diamond) > 0.10 &&
          lattice_rho_max(LatticeTopology::Diamond) > 0.5, "diamond band reported");

    // fcc IS the shipped octet-legs geometry: at the shared anchor rho the tensors match.
    CubicTensor fc = lattice_cubic_tensor(LatticeTopology::Fcc, 0.29731, E, nullptr);
    check(std::fabs(fc.C11 - oc.C11) < 1e-9 && std::fabs(fc.C44 - oc.C44) < 1e-9,
          "fcc == octet-legs at the shared anchor row");

    // B3 — a tetragonal topology is REFUSED (a cubic tensor cannot represent it),
    // via a typed exception distinct from the out-of-band one.
    for (LatticeTopology tetr : {LatticeTopology::Bccz, LatticeTopology::Fccz,
                                 LatticeTopology::Reentrant}) {
      bool threw = false;
      try {
        lattice_cubic_tensor(tetr, 0.30, E, nullptr);
      } catch (const LatticeTopologyNotCertifiable&) {
        threw = true;
      } catch (...) {
      }
      check(threw, "B3: tetragonal topology throws LatticeTopologyNotCertifiable");
    }
  }

  std::printf("== 2b. octet_relative_density: printed geometry -> library rho ==\n");
  {
    // The map from a job's (cell_mm, strut_radius_mm) to the rho the tensor library
    // is keyed on (lattice certification E2E). Cell-size invariant (depends only on
    // r/L), monotone in radius, and bracketed by the band at representative radii.
    const double lo = lattice_rho_min(LatticeTopology::Octet);
    const double hi = lattice_rho_max(LatticeTopology::Octet);
    const double rho_075 = octet_relative_density(5.0, 0.75);  // r/L = 0.15
    check(rho_075 > lo && rho_075 < hi,
          "octet_relative_density(5,0.75) lands INSIDE the certifiable band");
    check(std::fabs(octet_relative_density(10.0, 1.5) - rho_075) < 1e-9,
          "octet_relative_density is cell-size invariant (depends only on r/L)");
    check(octet_relative_density(5.0, 0.50) < rho_075 &&
              rho_075 < octet_relative_density(5.0, 1.0),
          "octet_relative_density increases with strut radius");
    // Out-of-band probes, expressed as an r/L RATIO (cell = 1, so the second arg is
    // r/L). octet_relative_density is cell-invariant, so the ratio — not a bare radius
    // — is what places a strut relative to the band. Chosen with margin outside the
    // CURRENT octet band [~0.05, ~0.90]: r/L=0.03 -> rho~0.0148 (below rho_min ~0.05),
    // r/L=0.34 -> rho~0.963 (above rho_max ~0.90, still < 1). PR 237's band extension
    // is exactly what invalidated the previous 0.30 / 1.05 radii (they crept inside the
    // widened band); if the band moves again these ratios must be re-checked (handoff
    // 2026-07-29-octet-rows-land).
    check(octet_relative_density(1.0, 0.03) < lo,
          "a thin strut (r/L=0.03) maps BELOW the band (the E5 refusal case)");
    check(octet_relative_density(1.0, 0.34) > hi,
          "a fat strut (r/L=0.34) maps ABOVE the band (the E5 refusal case)");
    bool threw = false;
    try { octet_relative_density(5.0, 0.0); }
    catch (const std::invalid_argument&) { threw = true; }
    check(threw, "a non-positive strut radius is rejected");
  }

  std::printf("== 2c. E5: certification REFUSES an out-of-band density ==\n");
  {
    // The band is a HARD gate AT CERTIFICATION (bar E5): analyze_fixed_design refuses
    // an out-of-band posture rho rather than certify against a clamped tensor.
    VoxelGrid g = solid_grid(6, 4, 4, h);
    std::vector<double> density(g.voxel_count(), 1.0);
    std::vector<DirichletBC> bcs;
    for (int j = 0; j < g.ny; ++j)
      for (int k = 0; k < g.nz; ++k) {
        const std::array<int, 8> en = fea_element_nodes(g, 0, j, k);
        for (int n : {en[0], en[3], en[4], en[7]})
          for (int c = 0; c < 3; ++c) bcs.push_back({n, c, 0.0});
      }
    std::vector<NodalLoad> loads;
    { const std::array<int, 8> en = fea_element_nodes(g, g.nx - 1, 0, 0);
      loads.push_back({en[1], 2, -10.0}); }
    Material mat = pla();
    SimpParams params; params.youngs_modulus = mat.youngs_modulus_mpa;
    params.poisson = mat.poisson; params.penalty = 3.0;
    Vec3 build_dir{0, 0, 1};
    KnockdownSpec kd;
    const double lo = lattice_rho_min(LatticeTopology::Octet);
    const double hi = lattice_rho_max(LatticeTopology::Octet);
    auto certify_at = [&](double rho) {
      LatticePosture post;
      post.topology = LatticeTopology::Octet; post.cell_size_mm = 8.0;
      post.mask.assign(g.voxel_count(), 0);
      post.relative_density.assign(g.voxel_count(), 0.0);
      post.mask[g.index(g.nx - 1, 0, 0)] = 1;
      post.relative_density[g.index(g.nx - 1, 0, 0)] = rho;
      return analyze_fixed_design(g, params, density, bcs, loads, mat, build_dir,
                                  1e-8, 0, SolverKind::JacobiCG, 1.5, kd, true,
                                  (double)g.solid_count(), &post);
    };
    // In-band: certifies (no throw).
    bool inband_ok = true;
    try { certify_at(0.30); } catch (...) { inband_ok = false; }
    check(inband_ok, "an in-band rho (0.30) certifies without refusal");
    // Below the band: refused with the typed exception carrying the band.
    bool below_threw = false; LatticeDensityOutOfBand caught(0, 0, 0, "");
    try { certify_at(lo * 0.5); }
    catch (const LatticeDensityOutOfBand& e) { below_threw = true; caught = e; }
    check(below_threw, "a rho BELOW the band is REFUSED (LatticeDensityOutOfBand)");
    check(caught.rho_min == lo && caught.rho_max == hi,
          "the refusal carries the band read from core");
    // Above the band: also refused.
    bool above_threw = false;
    try { certify_at(hi * 1.5); }
    catch (const LatticeDensityOutOfBand&) { above_threw = true; }
    check(above_threw, "a rho ABOVE the band is REFUSED");
  }

  std::printf("== 3. lattice solver reduces to graded fea_solve_cg ==\n");
  {
    VoxelGrid g = solid_grid(6, 4, 4, h);
    std::vector<double> ey(g.voxel_count());
    for (std::size_t e = 0; e < g.voxel_count(); ++e) ey[e] = E * (0.5 + 0.02 * (e % 20));
    std::vector<char> mask(g.voxel_count(), 0);
    std::vector<double> z(g.voxel_count(), 0.0);
    std::vector<DirichletBC> bcs;
    for (int j = 0; j <= g.ny; ++j)
      for (int i = 0; i <= g.nx; ++i) {
        int n = fea_node_index(g, i, j, 0);
        bcs.push_back({n, 0, 0.0}); bcs.push_back({n, 1, 0.0}); bcs.push_back({n, 2, 0.0});
      }
    std::vector<NodalLoad> loads;
    for (int j = 0; j <= g.ny; ++j)
      for (int i = 0; i <= g.nx; ++i) loads.push_back({fea_node_index(g, i, j, g.nz), 2, -5.0});
    FeaSolution a = fea_solve_cg(g, ey, nu, bcs, loads, 1e-10, 0, nullptr, nullptr);
    FeaSolution b = fea_solve_cg_lattice(g, ey, mask, z, z, z, nu, bcs, loads, 1e-10, 0, nullptr);
    double du = 0;
    for (std::size_t i = 0; i < a.u.size(); ++i) du = std::max(du, std::fabs(a.u[i] - b.u[i]));
    check(du == 0.0, "fea_solve_cg_lattice(all-zero mask) == graded fea_solve_cg bit-for-bit");

    // A lattice region makes the block softer (larger tip deflection).
    std::vector<char> mask2(g.voxel_count(), 1);
    CubicTensor T = lattice_cubic_tensor(LatticeTopology::Octet, 0.30, E, nullptr);
    std::vector<double> c11(g.voxel_count(), T.C11), c12(g.voxel_count(), T.C12), c44(g.voxel_count(), T.C44);
    FeaSolution latt = fea_solve_cg_lattice(g, ey, mask2, c11, c12, c44, nu, bcs, loads, 1e-10, 0, nullptr);
    check(max_abs_uz(latt) > 3.0 * max_abs_uz(a), "an all-octet block is far softer than the solid block");
  }

  std::printf("== 4 & 5. composite certification + gate constant ==\n");
  {
    VoxelGrid g = solid_grid(16, 6, 6, 1.0);
    std::vector<double> density(g.voxel_count(), 1.0);  // fully printed
    std::vector<DirichletBC> bcs;
    for (int k = 0; k <= g.nz; ++k)
      for (int j = 0; j <= g.ny; ++j) {
        int n = fea_node_index(g, 0, j, k);
        bcs.push_back({n, 0, 0.0}); bcs.push_back({n, 1, 0.0}); bcs.push_back({n, 2, 0.0});
      }
    std::vector<NodalLoad> loads;
    for (int k = 0; k <= g.nz; ++k)
      for (int j = 0; j <= g.ny; ++j) loads.push_back({fea_node_index(g, g.nx, j, k), 2, -2.0});

    Material mat = pla();
    SimpParams params; params.youngs_modulus = E; params.poisson = nu; params.penalty = 3.0;
    const Vec3 build_dir{0, 0, 1};
    KnockdownSpec kd;  // default scalar, infill_knockdown = 1.0
    const double part_solid = double(g.solid_count());

    // Reference: no posture.
    FixedDesignAnalysis a0 = analyze_fixed_design(
        g, params, density, bcs, loads, mat, build_dir, 1e-8, 0, SolverKind::JacobiCG,
        0.0, kd, true, part_solid);
    check(!a0.lattice_certified && a0.lattice_voxels == 0,
          "no posture => lattice fields default (byte-identical path)");

    // Posture: the far half (x >= nx/2) is octet at rho = 0.30.
    LatticePosture post;
    post.topology = LatticeTopology::Octet;
    post.cell_size_mm = 8.0;
    post.mask.assign(g.voxel_count(), 0);
    post.relative_density.assign(g.voxel_count(), 0.0);
    std::size_t marked = 0;
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = g.nx / 2; i < g.nx; ++i) {
          std::size_t e = g.index(i, j, k);
          post.mask[e] = 1; post.relative_density[e] = 0.30; ++marked;
        }
    FixedDesignAnalysis a1 = analyze_fixed_design(
        g, params, density, bcs, loads, mat, build_dir, 1e-8, 0, SolverKind::JacobiCG,
        0.0, kd, true, part_solid, &post);

    check(a1.lattice_certified, "posture => lattice_certified");
    check(a1.lattice_voxels == marked, "all latticed printed voxels counted");
    check(std::fabs(a1.lattice_rho_min - 0.30) < 1e-12 &&
          std::fabs(a1.lattice_rho_max - 0.30) < 1e-12, "relative-density range recorded");
    check(a1.lattice_strength_uncertified,
          "strut-level strength flagged UNCERTIFIED (Phase 2 de-homogenization)");
    check(a1.lattice_max_effective_vm > 0.0, "effective (macro) lattice stress recorded");
    // Composite is lighter: half the part is at 30% relative density.
    check(a1.mass_grams < a0.mass_grams,
          "composite mass < solid mass (lattice region weighs its relative density)");
    // The composite really carried the softer tensor: it is a DIFFERENT solve, so the
    // solid-region peak stress differs from the solid-everywhere solve.
    check(a1.max_von_mises != a0.max_von_mises,
          "composite solve differs from the solid-everywhere solve (tensor is in the solve)");

    // ---- C4: the gate runs at the EXACT margin_stop; a hair above rejects. -------
    const double Mw = a1.margin.worst_case;   // the NAMED gate quantity for this part
    FixedDesignAnalysis accept = analyze_fixed_design(
        g, params, density, bcs, loads, mat, build_dir, 1e-8, 0, SolverKind::JacobiCG,
        Mw * 0.999, kd, true, part_solid, &post);
    FixedDesignAnalysis reject = analyze_fixed_design(
        g, params, density, bcs, loads, mat, build_dir, 1e-8, 0, SolverKind::JacobiCG,
        Mw * 1.001, kd, true, part_solid, &post);
    check(accept.accepted, "composite accepts at margin_stop just BELOW its worst-case margin");
    check(!reject.accepted, "composite REJECTS at margin_stop just ABOVE (gate unsoftened, exact)");
    // The reported/displayed margin is unchanged by the threshold — the gate scales
    // only what it TESTS, never the margin (as in the scalar path).
    check(accept.margin.worst_case == reject.margin.worst_case &&
          accept.margin.worst_case == Mw, "the reported margin is the same constant regardless of the gate");
  }

  std::printf("%s (%d failures)\n", g_fail == 0 ? "ALL PASS" : "FAILURES", g_fail);
  return g_fail == 0 ? 0 : 1;
}
