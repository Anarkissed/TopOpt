#include "topopt/strut_strength.hpp"

#include <array>
#include <cmath>
#include <limits>
#include <stdexcept>

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
  const int n = static_cast<int>(kOctetStrutLaw.size());
  bool cl = false;
  double r = rho;
  if (!(r > kOctetStrutLaw.front().rho)) {
    cl = (r < kOctetStrutLaw.front().rho);
    r = kOctetStrutLaw.front().rho;
  } else if (!(r < kOctetStrutLaw.back().rho)) {
    cl = (r > kOctetStrutLaw.back().rho);
    r = kOctetStrutLaw.back().rho;
  }
  if (clamped) *clamped = cl;

  int a = 0;
  while (a + 2 < n && kOctetStrutLaw[static_cast<std::size_t>(a + 1)].rho <= r)
    ++a;
  const LawRow& r0 = kOctetStrutLaw[static_cast<std::size_t>(a)];
  const LawRow& r1 = kOctetStrutLaw[static_cast<std::size_t>(a + 1)];
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

StrutStrengthReport evaluate_strut_strength(
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
    const StrutLawK K = strut_law_at(rho, &clamped);
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

}  // namespace topopt
