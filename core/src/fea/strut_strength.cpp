#include "topopt/strut_strength.hpp"

#include <array>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <string>

#include "topopt/lattice.hpp"

namespace topopt {

namespace {

// OCTET strut-strength law — the `*_cert` columns of
// evidence/2026-07-31-lattice-dehomogenization-probe/kfit.csv, VERBATIM (PR 259).
// Per rho: the ENVELOPE over bulk (periodic interior), free-surface and cut-cell
// strut populations of the exact worst-case amplifications
//   Kd  — strut vm per unit macro vm (deviatoric worst case, exact 5x5 eigen)
//   Kv  — strut vm per unit macro |pressure| (hydrostatic ratio)
//   Kild/Kilv — the layer-normal (interlayer) analogues, build dir on a cube axis.
// Rows are keyed on the SAME rho scale the tensor library uses (each probe radius
// was calibrated through the production octet_relative_density). Resolution
// caveat (carried): the peak is a voxelized joint peak, ~log-divergent in micro
// resolution; rows quote the finest measured vpc, and the band-floor row
// (rho 0.048, wall 2 voxels at vpc48) is a still-rising LOWER bound.
struct LawRow {
  double rho, Kd, Kv, Kild, Kilv;
};
constexpr std::array<LawRow, 9> kOctetStrutLaw = {{
    {0.04762, 124.0930, 60.6036, 90.9946, 66.0605},
    {0.09505, 65.3739, 37.8932, 67.1207, 43.5009},
    {0.15524, 38.7510, 20.5053, 30.6208, 20.8223},
    {0.20414, 34.7623, 21.4607, 34.0004, 21.6227},
    {0.31619, 20.6863, 13.3207, 17.5533, 11.8537},
    {0.44394, 11.6092, 8.0827, 12.8386, 9.5626},
    {0.60004, 9.3845, 6.4616, 6.9696, 6.3297},
    {0.75210, 4.6847, 3.5686, 4.2797, 4.3419},
    {0.89598, 3.6882, 2.8571, 3.2186, 2.8771},
}};

// ── ★ THE OTHER EIGHT TYPES' LAWS (reviewer's ruling 11-08 (B), R10) ──────────────────────
// Each table is the `*_cert` columns of
// evidence/2026-11-09-lattice-type-strut-laws/<type>/kfit.csv, VERBATIM (generated from the
// CSV, not typed; test_lattice_type_strut_law pins every row). Measured exactly the PR 259
// way, by tests/harness/lattice_dehomog_probe.cpp with TOPOPT_DEHOMOG_TYPE=<type>:
//   * exact K_dev (the 5x5 generalized eigenproblem), K_vol, and the interlayer pair;
//   * per rho the ENVELOPE of the bulk (periodic cell, finest vpc 48) and the free-surface
//     and cut-cell populations (finite sandwich and cut blocks, N4 vpc16, thin rows N3 vpc24);
//   * the aliasing guard (>15 % off the library rho drops a row), with each dropped boundary
//     case RE-MEASURED one pitch finer, as PR 259 re-measured its low band (11-09: sc 0.087
//     cut at vpc32, diamond 0.20 at vpc24, rhombic 0.172 at vpc32, Schwarz-D 0.20 at vpc24);
//   * across the type's whole certified band (first/last row == lattice_rho_min/max);
//   * the sheets (gyroid, Schwarz-D) on the production wall (R7).
// Each type passes the probe's selfcheck S1-S6 (S6: the bound holds on 64 mixed states).
// PR 259's caveats, carried unchanged: the peak is a voxelized joint peak that grows ~log
// with resolution (bulk rows quote vpc 48; the boundary blocks are coarser, so they read low
// by that growth); the finite blocks are 3-4 cells across, under most types'
// cells-per-member floors; z_knockdown is unsourced.
constexpr std::array<LawRow, 7> kScStrutLaw = {{
    {0.08659, 593.3318, 47.4848, 333.0303, 46.7385},  // vpc 48, wall 4.0 vox
    {0.10000, 428.9544, 47.2712, 292.3672, 41.3218},  // vpc 48, wall 5.0 vox
    {0.15700, 149.1965, 25.5308, 138.0702, 24.6725},  // vpc 48, wall 6.0 vox
    {0.20000, 101.8976, 27.1812, 94.4943, 19.8687},  // vpc 48, wall 6.0 vox
    {0.31300, 41.1879, 13.5243, 39.9817, 12.4742},  // vpc 48, wall 8.0 vox
    {0.45000, 22.9183, 9.3766, 21.6776, 9.1313},  // vpc 48, wall 11.0 vox
    {0.49638, 20.9140, 9.1517, 19.4363, 8.7827},  // vpc 48, wall 11.0 vox
}};
constexpr std::array<LawRow, 4> kBccStrutLaw = {{
    {0.21050, 124.9008, 21.2407, 91.8965, 20.0861},  // vpc 48, wall 11.0 vox
    {0.31300, 50.9631, 16.5243, 54.8097, 15.7056},  // vpc 48, wall 13.0 vox
    {0.45000, 20.6504, 10.5115, 25.4605, 10.5675},  // vpc 48, wall 16.0 vox
    {0.59288, 12.0090, 8.5199, 14.2409, 8.0370},  // vpc 48, wall 18.0 vox
}};
constexpr std::array<LawRow, 6> kFccStrutLaw = {{
    {0.09505, 76.2700, 41.9867, 66.3738, 42.9039},  // vpc 48, wall 3.0 vox
    {0.15700, 41.0503, 24.8834, 40.3815, 26.4019},  // vpc 48, wall 4.0 vox
    {0.20000, 35.3615, 21.7717, 34.0848, 21.9361},  // vpc 48, wall 5.0 vox
    {0.31300, 20.9917, 13.5233, 23.4315, 14.9961},  // vpc 48, wall 6.0 vox
    {0.45000, 13.8613, 8.9162, 14.3575, 10.5389},  // vpc 48, wall 8.0 vox
    {0.59093, 9.6701, 6.6837, 8.6745, 7.7568},  // vpc 48, wall 9.0 vox
}};
constexpr std::array<LawRow, 5> kDiamondStrutLaw = {{
    {0.15712, 108.3321, 32.6702, 64.2847, 23.7821},  // vpc 48, wall 9.0 vox
    {0.20000, 73.7044, 28.0786, 44.1802, 16.4015},  // vpc 48, wall 11.0 vox
    {0.31300, 29.2723, 14.5723, 19.4339, 9.5788},  // vpc 48, wall 13.0 vox
    {0.45000, 15.2812, 10.2739, 10.6518, 5.4090},  // vpc 48, wall 16.0 vox
    {0.59201, 11.7411, 7.0800, 6.4476, 4.2725},  // vpc 48, wall 17.0 vox
}};
constexpr std::array<LawRow, 6> kKelvinStrutLaw = {{
    {0.09375, 194.2387, 38.3710, 169.9450, 44.8666},  // vpc 48, wall 5.0 vox
    {0.15700, 76.8369, 22.1329, 68.3977, 21.6660},  // vpc 48, wall 7.0 vox
    {0.20000, 57.5873, 19.9116, 48.9405, 19.6264},  // vpc 48, wall 7.0 vox
    {0.31300, 28.4539, 10.9693, 20.4612, 10.5699},  // vpc 48, wall 9.0 vox
    {0.45000, 15.0392, 9.4489, 10.7408, 7.7688},  // vpc 48, wall 10.0 vox
    {0.50521, 11.8701, 7.7287, 8.3668, 6.3720},  // vpc 48, wall 11.0 vox
}};
constexpr std::array<LawRow, 5> kRhombicStrutLaw = {{
    {0.17245, 137.4248, 25.9003, 95.8865, 25.5076},  // vpc 48, wall 7.0 vox
    {0.20000, 59.2958, 22.4689, 52.4511, 15.8969},  // vpc 48, wall 8.0 vox
    {0.31300, 29.3597, 12.7806, 29.8240, 11.7617},  // vpc 48, wall 10.0 vox
    {0.45000, 18.4019, 12.0298, 14.9753, 8.2050},  // vpc 48, wall 13.0 vox
    {0.51331, 11.9578, 8.5043, 12.8638, 7.8547},  // vpc 48, wall 16.0 vox
}};
constexpr std::array<LawRow, 5> kGyroidStrutLaw = {{
    {0.15010, 59.5961, 25.0944, 26.8422, 16.6698},  // vpc 48, wall 4.0 vox
    {0.20000, 34.0397, 16.2927, 14.9027, 10.1190},  // vpc 48, wall 5.0 vox
    {0.31300, 23.8671, 14.0171, 9.7103, 6.7171},  // vpc 48, wall 7.0 vox
    {0.45000, 14.2794, 9.2541, 6.8894, 4.5842},  // vpc 48, wall 10.0 vox
    {0.60069, 9.4540, 6.4042, 4.9169, 3.3624},  // vpc 48, wall 13.0 vox
}};
constexpr std::array<LawRow, 4> kSchwarzDStrutLaw = {{
    {0.20038, 36.7040, 18.8765, 17.1223, 10.2175},  // vpc 48, wall 4.0 vox
    {0.31300, 21.7224, 13.9827, 8.8494, 7.0903},  // vpc 48, wall 6.0 vox
    {0.45000, 14.8663, 10.5162, 5.9560, 5.2856},  // vpc 48, wall 8.0 vox
    {0.60012, 9.2370, 6.4731, 3.8683, 3.3242},  // vpc 48, wall 11.0 vox
}};

// ★ PER TYPE (ruling 11-08 (B)): each type's OWN law, measured exactly the PR 259 way
// (tests/harness/lattice_dehomog_probe.cpp with TOPOPT_DEHOMOG_TYPE), never octet's
// borrowed. A type with no table has no law: strut_law_measured is false and the
// evaluator refuses it.
struct LawTable {
  const LawRow* rows = nullptr;
  int n = 0;
};
LawTable law_table(LatticeTopology topo) {
  switch (topo) {
    case LatticeTopology::Octet:
      return {kOctetStrutLaw.data(), static_cast<int>(kOctetStrutLaw.size())};
    case LatticeTopology::SimpleCubic:
      return {kScStrutLaw.data(), static_cast<int>(kScStrutLaw.size())};
    case LatticeTopology::Bcc:
      return {kBccStrutLaw.data(), static_cast<int>(kBccStrutLaw.size())};
    case LatticeTopology::Fcc:
      return {kFccStrutLaw.data(), static_cast<int>(kFccStrutLaw.size())};
    case LatticeTopology::Diamond:
      return {kDiamondStrutLaw.data(), static_cast<int>(kDiamondStrutLaw.size())};
    case LatticeTopology::Kelvin:
      return {kKelvinStrutLaw.data(), static_cast<int>(kKelvinStrutLaw.size())};
    case LatticeTopology::Rhombic:
      return {kRhombicStrutLaw.data(), static_cast<int>(kRhombicStrutLaw.size())};
    case LatticeTopology::Gyroid:
      return {kGyroidStrutLaw.data(), static_cast<int>(kGyroidStrutLaw.size())};
    case LatticeTopology::SchwarzD:
      return {kSchwarzDStrutLaw.data(), static_cast<int>(kSchwarzDStrutLaw.size())};
    default:
      return {};
  }
}
LawTable law_table_or_throw(LatticeTopology topo, const char* who) {
  const LawTable t = law_table(topo);
  if (t.rows == nullptr)
    throw std::invalid_argument(std::string(who) + ": \"" + lattice_topology_name(topo) +
                                "\" has no measured strut-strength law");
  return t;
}

StrutLawK law_at(const LawTable& T, double rho, bool* clamped) {
  const LawRow* L = T.rows;
  const int n = T.n;
  bool cl = false;
  double r = rho;
  if (!(r > L[0].rho)) {
    cl = (r < L[0].rho);
    r = L[0].rho;
  } else if (!(r < L[n - 1].rho)) {
    cl = (r > L[n - 1].rho);
    r = L[n - 1].rho;
  }
  if (clamped) *clamped = cl;

  int a = 0;
  while (a + 2 < n && L[a + 1].rho <= r) ++a;
  const LawRow& r0 = L[a];
  const LawRow& r1 = L[a + 1];
  const double t = r1.rho > r0.rho ? (r - r0.rho) / (r1.rho - r0.rho) : 0.0;
  // Lerp in the (1-t)/t form so an anchor row (t == 0 or t == 1) reproduces the
  // measured value EXACTLY — the transcription test pins this.
  StrutLawK k;
  k.Kd = (1.0 - t) * r0.Kd + t * r1.Kd;
  k.Kv = (1.0 - t) * r0.Kv + t * r1.Kv;
  k.Kild = (1.0 - t) * r0.Kild + t * r1.Kild;
  k.Kilv = (1.0 - t) * r0.Kilv + t * r1.Kilv;
  return k;
}

constexpr double kAxisTol = 1e-9;  // cross factor below this counts as on-axis

// Von Mises of a Voigt [xx,yy,zz,xy,yz,zx] tensor with TRUE shear (the
// stress_tensor_field convention).
double voigt_von_mises(const double s[6]) {
  const double dxy = s[0] - s[1], dyz = s[1] - s[2], dzx = s[2] - s[0];
  const double v2 = 0.5 * (dxy * dxy + dyz * dyz + dzx * dzx) +
                    3.0 * (s[3] * s[3] + s[4] * s[4] + s[5] * s[5]);
  return std::sqrt(v2 > 0.0 ? v2 : 0.0);
}

double voigt_pressure(const double s[6]) { return (s[0] + s[1] + s[2]) / 3.0; }

}  // namespace

double strut_law_rho_min() { return kOctetStrutLaw.front().rho; }
double strut_law_rho_max() { return kOctetStrutLaw.back().rho; }

StrutLawK strut_law_at(double rho, bool* clamped) {
  return law_at(law_table(LatticeTopology::Octet), rho, clamped);
}

bool strut_law_measured(LatticeTopology topo) { return law_table(topo).rows != nullptr; }
double strut_law_rho_min(LatticeTopology topo) {
  return law_table_or_throw(topo, "strut_law_rho_min").rows[0].rho;
}
double strut_law_rho_max(LatticeTopology topo) {
  const LawTable t = law_table_or_throw(topo, "strut_law_rho_max");
  return t.rows[t.n - 1].rho;
}
StrutLawK strut_law_at(LatticeTopology topo, double rho, bool* clamped) {
  return law_at(law_table_or_throw(topo, "strut_law_at"), rho, clamped);
}

namespace {
StrutStrengthReport evaluate_with(const LawTable& T,
    const std::vector<double>& stress_tensor_field,
    const std::vector<char>& lattice_mask,
    const std::vector<double>& relative_density, const Vec3& build_dir,
    double yield_strength_mpa, double z_knockdown);
}  // namespace

StrutStrengthReport evaluate_strut_strength(
    const std::vector<double>& stress_tensor_field,
    const std::vector<char>& lattice_mask,
    const std::vector<double>& relative_density, const Vec3& build_dir,
    double yield_strength_mpa, double z_knockdown) {
  return evaluate_with(law_table(LatticeTopology::Octet), stress_tensor_field, lattice_mask,
                       relative_density, build_dir, yield_strength_mpa, z_knockdown);
}

StrutStrengthReport evaluate_strut_strength(
    LatticeTopology topo, const std::vector<double>& stress_tensor_field,
    const std::vector<char>& lattice_mask,
    const std::vector<double>& relative_density, const Vec3& build_dir,
    double yield_strength_mpa, double z_knockdown) {
  return evaluate_with(law_table_or_throw(topo, "evaluate_strut_strength"),
                       stress_tensor_field, lattice_mask, relative_density, build_dir,
                       yield_strength_mpa, z_knockdown);
}

std::string strut_law_source(LatticeTopology topo) {
  (void)law_table_or_throw(topo, "strut_law_source");
  if (topo == LatticeTopology::Octet)
    return "PR 259 kfit *_cert envelope (bulk/free-surface/cut "
           "populations), evidence/2026-07-31-lattice-dehomogenization-probe/"
           "kfit.csv; strut_vm <= Kd(rho)*vm(Sigma) + Kv(rho)*|p(Sigma)|, "
           "interlayer analogue Kild/Kilv";
  const std::string id = lattice_topology_name(topo);
  return id + "'s own law, measured the PR 259 way: kfit *_cert envelope "
              "(bulk/free-surface/cut populations), "
              "evidence/2026-11-09-lattice-type-strut-laws/" +
         id + "/kfit.csv; strut_vm <= Kd(rho)*vm(Sigma) + Kv(rho)*|p(Sigma)|, "
              "interlayer analogue Kild/Kilv";
}

std::string strut_law_resolution_note(LatticeTopology topo) {
  (void)law_table_or_throw(topo, "strut_law_resolution_note");
  // Bulk K_dev, vpc 32 -> 48, over each type's rows (its k_exact_bulk.csv).
  const char* drift = nullptr;
  switch (topo) {
    case LatticeTopology::Octet:
      return "joint-peak law rows are mesh-divergent "
             "(~log in micro resolution, +10-18% per 32->48 step where measured); "
             "the band-floor row is a still-rising lower bound";
    case LatticeTopology::SimpleCubic: drift = "-11% to +50%"; break;
    case LatticeTopology::Bcc:         drift = "+5% to +47%"; break;
    case LatticeTopology::Fcc:         drift = "+8% to +20%"; break;
    case LatticeTopology::Diamond:     drift = "+8% to +34%"; break;
    case LatticeTopology::Kelvin:      drift = "+11% to +39%"; break;
    case LatticeTopology::Rhombic:     drift = "+23% to +48%"; break;
    case LatticeTopology::Gyroid:      drift = "-1% to +11%"; break;
    case LatticeTopology::SchwarzD:    drift = "-4% to +7%"; break;
    default: break;
  }
  const bool sheet =
      topo == LatticeTopology::Gyroid || topo == LatticeTopology::SchwarzD;
  return std::string(sheet ? "the law rows are the finest measured (vpc 48); this "
                             "sheet's smooth wall moved "
                           : "joint-peak law rows are mesh-divergent (~log in micro "
                             "resolution); this type's bulk peak moved ") +
         (drift ? drift : "an unmeasured amount") +
         " per 32->48 step, so the rows are lower bounds and the band-floor row "
         "is a still-rising one";
}

namespace {
StrutStrengthReport evaluate_with(const LawTable& T,
    const std::vector<double>& stress_tensor_field,
    const std::vector<char>& lattice_mask,
    const std::vector<double>& relative_density, const Vec3& build_dir,
    double yield_strength_mpa, double z_knockdown) {
  const std::size_t n = lattice_mask.size();
  if (relative_density.size() != n || stress_tensor_field.size() != 6 * n)
    throw std::invalid_argument(
        "evaluate_strut_strength: field sizes disagree (need mask n, rho n, "
        "stress 6n)");
  if (!(yield_strength_mpa > 0.0) || !std::isfinite(yield_strength_mpa))
    throw std::invalid_argument(
        "evaluate_strut_strength: yield_strength_mpa must be finite and > 0");
  if (!(z_knockdown > 0.0) || !std::isfinite(z_knockdown))
    throw std::invalid_argument(
        "evaluate_strut_strength: z_knockdown must be finite and > 0");
  const double bn = std::sqrt(build_dir.x * build_dir.x +
                              build_dir.y * build_dir.y +
                              build_dir.z * build_dir.z);
  if (!(bn > 0.0) || !std::isfinite(bn))
    throw std::invalid_argument(
        "evaluate_strut_strength: build_dir must be nonzero and finite");
  const double nx = build_dir.x / bn, ny = build_dir.y / bn,
               nz = build_dir.z / bn;

  StrutStrengthReport out;
  out.z_knockdown_used = z_knockdown;
  // Off-axis interlayer resolution (see the header): the axis law misses strut
  // SHEAR components for a build direction off the lattice cube axes; they are
  // rigorously bounded by the strut vm bound via |sigma_ab| <= vm/sqrt(3).
  out.il_cross_factor =
      (2.0 / std::sqrt(3.0)) * (std::fabs(nx * ny) + std::fabs(ny * nz) +
                                std::fabs(nz * nx));
  out.build_dir_on_lattice_axis = out.il_cross_factor <= kAxisTol;

  for (std::size_t e = 0; e < n; ++e) {
    if (!lattice_mask[e]) continue;
    ++out.lattice_voxels;
    double s[6];
    for (int c = 0; c < 6; ++c)
      s[c] = stress_tensor_field[6 * e + static_cast<std::size_t>(c)];
    const double vm = voigt_von_mises(s);
    const double pr = voigt_pressure(s);
    const double p = std::fabs(pr);
    const double rho = relative_density[e];
    bool clamped = false;
    const StrutLawK K = law_at(T, rho, &clamped);
    if (clamped) ++out.rho_clamped_voxels;
    const double vm_bound = K.Kd * vm + K.Kv * p;
    const double il_bound =
        K.Kild * vm + K.Kilv * p + out.il_cross_factor * vm_bound;
    if (vm > out.max_macro_vm_mpa) out.max_macro_vm_mpa = vm;
    if (vm_bound > out.vm_bound_max_mpa) {
      out.vm_bound_max_mpa = vm_bound;
      out.vm_argmax_voxel = e;
      out.vm_argmax_rho = rho;
      out.vm_argmax_macro_vm_mpa = vm;
      out.vm_argmax_macro_pressure_mpa = pr;
    }
    if (il_bound > out.il_bound_max_mpa) {
      out.il_bound_max_mpa = il_bound;
      out.il_argmax_voxel = e;
      out.il_argmax_rho = rho;
      out.il_argmax_macro_vm_mpa = vm;
      out.il_argmax_macro_pressure_mpa = pr;
    }
  }
  out.evaluated = out.lattice_voxels > 0;

  const double inf = std::numeric_limits<double>::infinity();
  out.margin_in_plane = out.vm_bound_max_mpa > 0.0
                            ? yield_strength_mpa / out.vm_bound_max_mpa
                            : inf;
  out.margin_interlayer =
      out.il_bound_max_mpa > 0.0
          ? (z_knockdown * yield_strength_mpa) / out.il_bound_max_mpa
          : inf;
  out.margin_worst_case = std::min(out.margin_in_plane, out.margin_interlayer);
  if (out.max_macro_vm_mpa > 0.0) {
    out.amplification_vm = out.vm_bound_max_mpa / out.max_macro_vm_mpa;
    out.amplification_il = out.il_bound_max_mpa / out.max_macro_vm_mpa;
  }
  return out;
}

}  // namespace

}  // namespace topopt
