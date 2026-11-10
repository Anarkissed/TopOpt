#include <cstdio>
#include "topopt/lattice.hpp"

// kUnloadedUtilisationMax — the project's one definition of "this material carries
// nothing". grading.hpp includes lattice.hpp, never the other way round, so taking it
// here in the .cpp adds no header cycle and avoids a second copy of the number, which
// is how the app's strut law drifted 1.4x from core's.
#include "topopt/grading.hpp"
#include "topopt/strut_cell.hpp"
#include "topopt/tpms.hpp"

#include <array>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <vector>

namespace topopt {

namespace {

// The solid modulus PR 198's library was measured at (materials.json PLA E).
// Effective stiffness is exactly linear in the solid modulus (linear elasticity),
// so a query at any Es scales these rows by Es / kLibraryEs.
constexpr double kLibraryEs = 3500.0;

struct Row {
  double rho, C11, C12, C44;  // MPa at Es = 3500
  bool resolved;              // wall >= 4 voxels at vpc48
};

// OCTET — the homogenized cubic tensor per MEASURED (voxelised) relative density
// (L=5 mm, Es=3500), ordered by rho.
//
// ★ OCTET MADE HONEST (ruling 2026-11-02 (c)). These rows used to be PR 198's library with
// PR 237's band extension, all measured on the LEGS-ONLY cell, which is geometrically FCC
// (kFcc below matches it byte for byte where the densities coincide), while the generator
// lays the FULL octet, legs and braces, 24 struts a cell. They are now the full octet's,
// measured with the same periodic homogenization (tensor_library_nine_probe `sweep octet`,
// PR 246's driver) and judged by its rule: |drift| < 2.4 % against a finer resolution's
// curve at the row's own rho, >= 6 voxels across the strut, CG converged. Three blocks:
//   LOW  (0.0496..0.1512): vpc96 rows vs the vpc128 curve, measured 2026-11-03.
//   MID  (0.2066..0.4800): PR 246's validated rows, vpc48 vs vpc64
//        (evidence/2026-07-29-tensor-library-nine/csv/octet_sweep.csv), measured then but
//        never landed.
//   HIGH (0.5411..0.9003): vpc64 rows vs the vpc96 curve, measured 2026-11-03.
// The sweep ran one density per process (each under the heavy lock's hour), so each
// process's reference curve held ONE point and its own drift column compared two
// different densities; the drift here is re-judged on each set's whole reference curve,
// which is what one process would have printed (c_octet_tensor_rows.txt). One row fails:
// 0.18522, which lies past the end of its reference curve (the rule does not extrapolate),
// and is left out. Every row here is resolved and validated; the band is 0.0496..0.9003.
constexpr std::array<Row, 18> kOctet = {{
    // --- LOW rows (vpc96 vs vpc128) ---
    {0.04959, 36.2534, 18.4178, 17.2190, true},
    {0.06058, 45.6481, 23.2077, 21.5912, true},
    {0.07794, 60.9315, 30.9432, 28.6375, true},
    {0.10532, 87.3471, 43.8564, 40.2300, true},
    {0.11748, 99.5680, 50.0693, 45.9761, true},
    {0.15115, 136.6541, 68.0589, 62.3069, true},
    // --- MID rows (PR 246, vpc48 vs vpc64) ---
    {0.20660, 213.3453, 103.9827, 94.3391, true},
    {0.29543, 355.6757, 169.5095, 155.3239, true},
    {0.42245, 638.9053, 285.3390, 264.5521, true},
    {0.48003, 811.3576, 354.8678, 330.5264, true},
    // --- HIGH rows (vpc64 vs vpc96) ---
    {0.54114, 1006.9295, 429.2955, 398.0499, true},
    {0.58484, 1186.9047, 497.8077, 457.7308, true},
    {0.64856, 1516.5063, 630.9997, 561.0512, true},
    {0.70178, 1863.4078, 781.5637, 661.6485, true},
    {0.74805, 2217.3259, 936.1863, 749.7789, true},
    {0.80078, 2711.0987, 1169.5786, 859.8464, true},
    {0.85071, 3293.6552, 1464.3333, 972.4855, true},
    {0.90027, 3861.9111, 1764.7180, 1076.4927, true},
}};

// ─── the nine-topology extension (handoff 2026-07-29-tensor-library-nine) ───────
// Measured by tensor_library_nine_probe.cpp: the SAME periodic homogenization PR 198
// used, run over the strut-lattice family table. vpc48 row (the library basis, like
// kOctet), converged against vpc64 (matched rho, clean interpolated drift metric).
// A row is `resolved` when it sits in the CONTIGUOUS validated block (drift < 2.4% vs
// vpc64 AND strut diameter >= 6 voxels); rows outside are kept for provenance. Only
// the CUBIC-symmetric topologies are here — the three tetragonal variants (bccz/fccz/
// reentrant) get NO table (rows_of returns empty) and are refused by lattice_cubic_
// tensor (bar B3). NOTE: kFcc is geometrically the legs-only octet, so its rows matched
// octet's OLD rows where the density sampling coincided (rho 0.297, 0.591 byte-identical)
// -- the live proof this driver reproduces PR 198's library, and how the shipped octet
// was found to be legs-only. kOctet is the full octet's since ruling 2026-11-02 (c).

// sc: cubic, extreme LOW shear (Zener 0.045-0.60). Worst in-band drift 0.71%.
constexpr std::array<Row, 8> kSimpleCubic = {{
    {0.08659, 124.1566, 7.4660, 2.6536, true},
    {0.10749, 158.5235, 10.8871, 4.4241, true},
    {0.15184, 234.9730, 19.8418, 9.6988, true},
    {0.20095, 328.7364, 33.6360, 19.3835, true},
    {0.30107, 549.8922, 75.8114, 54.8253, true},
    {0.40271, 820.7973, 142.6197, 117.1334, true},
    {0.49638, 1122.1090, 233.9830, 201.3808, true},
    {0.60171, 1567.5924, 404.5519, 346.1360, false},
}};
// bcc: cubic, extreme HIGH Zener (1.56-34.7, bending). Worst in-band drift 1.75%.
constexpr std::array<Row, 8> kBcc = {{
    {0.06684, 33.4693, 31.7886, 29.1699, false},
    {0.09288, 52.1153, 48.2770, 43.9143, false},
    {0.15755, 102.6131, 88.9380, 79.5135, false},
    {0.21050, 156.4198, 127.3111, 113.1794, true},
    {0.30729, 288.2758, 205.7559, 182.7549, true},
    {0.38932, 447.0414, 281.7155, 252.5690, true},
    {0.50043, 754.6963, 399.8495, 361.9060, true},
    {0.59288, 1125.8347, 522.3899, 470.7912, true},
}};
// fcc: cubic (== the shipped octet-legs geometry). Worst in-band drift 1.94%.
constexpr std::array<Row, 8> kFcc = {{
    {0.07812, 62.2005, 30.5343, 27.5372, false},
    {0.09505, 79.1299, 38.1537, 34.1013, true},
    {0.15524, 147.2712, 67.8645, 59.9030, true},
    {0.19611, 205.2342, 90.3098, 79.2466, true},
    {0.29731, 374.2029, 151.9733, 135.0535, true},
    {0.40958, 645.8690, 235.1929, 212.4952, true},
    {0.49732, 933.7064, 317.7636, 288.2518, true},
    {0.59093, 1344.7034, 443.6894, 392.1883, true},
}};
// diamond: cubic (Zener 1.57-2.92). Worst in-band drift 2.02%.
constexpr std::array<Row, 8> kDiamond = {{
    {0.06655, 36.4377, 30.8178, 8.2156, false},
    {0.09259, 57.5708, 46.1752, 16.5792, false},
    {0.15712, 119.1238, 83.4693, 47.9097, true},
    {0.21007, 185.0863, 118.3592, 84.1557, true},
    {0.30671, 339.7180, 190.8679, 167.0811, true},
    {0.38860, 522.8239, 268.4643, 256.3348, true},
    {0.49971, 843.5858, 401.4833, 390.5869, true},
    {0.59201, 1222.7132, 557.3286, 520.9273, true},
}};
// kelvin: cubic (Zener 0.68-0.89). Worst in-band drift 3.20% (one interior node at
// rho~0.21; <=2.0% elsewhere) — disclosed in the handoff, kept as an interp node
// because E100(rho) is convex and dropping it over-estimates across the gap.
constexpr std::array<Row, 8> kKelvin = {{
    {0.07726, 51.2160, 36.8961, 5.8569, false},
    {0.09375, 69.5508, 44.6326, 8.7574, true},
    {0.15191, 144.1969, 73.4013, 23.9669, true},
    {0.20660, 234.3606, 102.4685, 45.4661, true},
    {0.30469, 470.5138, 159.9250, 104.8460, true},
    {0.39149, 734.2983, 229.6667, 177.5998, true},
    {0.50521, 1157.2768, 376.2459, 314.8977, true},
    {0.60764, 1638.2366, 576.4350, 473.0362, false},
}};
// rhombic: cubic (Zener 1.23-2.78); 32 struts -> thin at low rho, narrower band.
// Worst in-band drift 1.72%.
constexpr std::array<Row, 8> kRhombic = {{
    {0.09317, 54.3000, 47.1262, 9.9597, false},
    {0.10995, 70.0522, 58.8325, 15.0200, false},
    {0.12558, 82.0597, 66.7054, 19.8245, false},
    {0.17245, 134.1116, 100.7815, 40.7273, true},
    {0.28299, 299.5816, 184.9281, 115.2281, true},
    {0.39236, 556.9667, 290.3696, 223.0394, true},
    {0.51331, 998.3655, 448.7741, 377.5713, true},
    {0.59925, 1446.0481, 612.3678, 511.1671, false},
}};

// ── THE SHEETS (lattice types round 1, K2), RE-MEASURED ON THE PRODUCTION WALL ──────
// The July rows (PR 198) were measured on |f| < level, whose thickness varies over the
// sheet; these are on tpms.hpp's |f|/|grad f| <= t/2, the wall the generator builds (R7).
// core/tests/harness/tpms_probe.cpp `rows`, L = 5 mm, the PR 198/246 periodic
// homogenisation; evidence docs/handoffs/evidence/2026-11-01-lattice-types-k1/
// <sheet>_rows_vpc{48,96}.{csv,txt}. A row is resolved when its E100 is within 2.4 % of a
// finer reference curve at the row's own rho AND its wall is >= 4 voxels (PR 198's floor).
// The low rows are vpc96 against vpc128, the high ones vpc48 against vpc64 (PR 237's
// mixed-resolution precedent). Gyroid's E100/Es at rho 0.30 is 0.113 against July's 0.114:
// the wall change moves the density -> thickness law far more than the tensor.
constexpr std::array<Row, 9> kGyroid = {{
    {0.10008, 164.8816, 84.8909, 44.2575, false},    // vpc96, wall 3.1 vox
    {0.15010, 256.7294, 130.0176, 71.6195, true},    // vpc96, drift -0.89 %
    {0.20005, 353.8641, 175.2038, 102.0082, true},   // vpc96, -0.33 %
    {0.24996, 456.8889, 222.1241, 136.1484, true},   // vpc96, -0.36 %
    {0.30002, 570.4769, 270.4755, 175.0008, true},   // vpc96, +0.14 %
    {0.34993, 692.6102, 321.0779, 218.1758, true},   // vpc96, +0.14 %
    {0.39988, 816.9401, 371.4404, 264.8958, true},   // vpc48, -0.92 %
    {0.50058, 1138.8644, 496.9424, 376.0255, true},  // vpc48, -0.40 %
    {0.60069, 1537.4855, 650.1203, 507.1088, true},  // vpc48, -0.11 %
}};
constexpr std::array<Row, 9> kSchwarzD = {{
    {0.10012, 181.3303, 75.5420, 36.2826, false},    // vpc96, wall 2.6 vox
    {0.15025, 282.4526, 116.1866, 60.2473, false},   // vpc96, wall 3.9 vox
    {0.20038, 387.5145, 158.1366, 88.5665, true},    // vpc96, drift +0.62 %
    {0.24993, 495.2768, 202.1085, 122.1545, true},   // vpc96, -0.34 %
    {0.29962, 611.1977, 248.3459, 160.2463, true},   // vpc96, -0.19 %
    {0.35004, 738.3611, 299.4426, 205.2824, true},   // vpc96, -0.57 %
    {0.40336, 887.9079, 350.8664, 254.6653, true},   // vpc48, +2.38 %
    {0.49769, 1168.9725, 472.4790, 366.4813, true},  // vpc48, -0.87 %
    {0.60012, 1587.8055, 641.3626, 506.5710, true},  // vpc48, -1.00 %
}};

// A view over one topology's row table (variable length — octet has 8, others differ).
struct RowTable {
  const Row* data;
  int n;
  bool empty() const { return data == nullptr || n == 0; }
};

// The certifiable topologies carry a table; the tetragonal ones (and any not covered)
// return an EMPTY table, which every accessor below treats as "refuse / not certifiable".
RowTable rows_of(LatticeTopology topo) {
  switch (topo) {
    case LatticeTopology::Octet:       return {kOctet.data(), (int)kOctet.size()};
    case LatticeTopology::SimpleCubic: return {kSimpleCubic.data(), (int)kSimpleCubic.size()};
    case LatticeTopology::Bcc:         return {kBcc.data(), (int)kBcc.size()};
    case LatticeTopology::Fcc:         return {kFcc.data(), (int)kFcc.size()};
    case LatticeTopology::Diamond:     return {kDiamond.data(), (int)kDiamond.size()};
    case LatticeTopology::Kelvin:      return {kKelvin.data(), (int)kKelvin.size()};
    case LatticeTopology::Rhombic:     return {kRhombic.data(), (int)kRhombic.size()};
    case LatticeTopology::Bccz:
    case LatticeTopology::Fccz:
    case LatticeTopology::Reentrant:   return {nullptr, 0};  // tetragonal: not certifiable
    case LatticeTopology::Gyroid:      return {kGyroid.data(), (int)kGyroid.size()};
    case LatticeTopology::SchwarzD:    return {kSchwarzD.data(), (int)kSchwarzD.size()};
  }
  return {nullptr, 0};
}

// Index range [lo, hi] of the RESOLVED rows (the interpolation domain). Requires a
// non-empty table (callers guard with rows_of(...).empty()).
void resolved_span(const RowTable& t, int& lo, int& hi) {
  lo = 0;
  while (lo < t.n && !t.data[lo].resolved) ++lo;
  hi = t.n - 1;
  while (hi > lo && !t.data[hi].resolved) --hi;
}

}  // namespace

const char* lattice_topology_name(LatticeTopology topo) {
  switch (topo) {
    case LatticeTopology::Octet:       return "octet";
    case LatticeTopology::SimpleCubic: return "sc";
    case LatticeTopology::Bcc:         return "bcc";
    case LatticeTopology::Fcc:         return "fcc";
    case LatticeTopology::Diamond:     return "diamond";
    case LatticeTopology::Kelvin:      return "kelvin";
    case LatticeTopology::Rhombic:     return "rhombic";
    case LatticeTopology::Bccz:        return "bccz";
    case LatticeTopology::Fccz:        return "fccz";
    case LatticeTopology::Reentrant:   return "reentrant";
    case LatticeTopology::Gyroid:      return "gyroid";
    case LatticeTopology::SchwarzD:    return "schwarz_d";
  }
  return "?";
}

bool lattice_topology_certifiable(LatticeTopology topo) {
  return !rows_of(topo).empty();
}

std::vector<std::string> lattice_certifiable_topology_names() {
  std::vector<std::string> out;
  for (LatticeTopology t : {LatticeTopology::Octet, LatticeTopology::SimpleCubic,
                            LatticeTopology::Bcc, LatticeTopology::Fcc,
                            LatticeTopology::Diamond, LatticeTopology::Kelvin,
                            LatticeTopology::Rhombic, LatticeTopology::Bccz,
                            LatticeTopology::Fccz, LatticeTopology::Reentrant,
                            LatticeTopology::Gyroid, LatticeTopology::SchwarzD})
    if (lattice_topology_certifiable(t)) out.emplace_back(lattice_topology_name(t));
  return out;
}

double lattice_rho_min(LatticeTopology topo) {
  RowTable t = rows_of(topo);
  if (t.empty()) return 0.0;  // not certifiable — band is meaningless (gate refuses)
  int lo, hi;
  resolved_span(t, lo, hi);
  return t.data[lo].rho;
}

double lattice_rho_max(LatticeTopology topo) {
  RowTable t = rows_of(topo);
  if (t.empty()) return 0.0;
  int lo, hi;
  resolved_span(t, lo, hi);
  return t.data[hi].rho;
}

std::vector<LatticeResolvedRow> lattice_resolved_rows(LatticeTopology topo) {
  RowTable t = rows_of(topo);
  if (t.empty()) return {};  // not certifiable — no measured rows to hand out
  int lo, hi;
  resolved_span(t, lo, hi);
  std::vector<LatticeResolvedRow> out;
  out.reserve(static_cast<std::size_t>(hi - lo + 1));
  for (int i = lo; i <= hi; ++i) {
    // Only the CONTIGUOUS validated block is handed out; resolved_span already
    // trimmed the unresolved head/tail, and by construction (PR 237's verdict) the
    // rows between lo and hi are resolved. Assert it rather than assume it — an
    // unresolved row slipping into a fit would skew the derivative the optimizer
    // steers on, which is exactly the failure this accessor exists to avoid.
    if (!t.data[i].resolved)
      throw std::logic_error(
          "lattice_resolved_rows: unresolved row inside the validated span");
    out.push_back({t.data[i].rho, t.data[i].C11, t.data[i].C12, t.data[i].C44});
  }
  return out;
}

double lattice_library_youngs_modulus() { return kLibraryEs; }

// ── ★ THE SHEET WALL LAW (K2) ─────────────────────────────────────────────────
// docs/handoffs/evidence/2026-11-01-lattice-types-k1/<sheet>_wall_law.{csv,txt}, from
// core/tests/harness/tpms_probe.cpp `law` on the PRODUCTION wall (tpms.hpp): the wall's
// field parameter t bisected (50 steps) on its converged solid fraction (2^20 Halton
// points), and the TRUE normal thickness measured on 4,000 points of the sheet (marching out
// along the normal from the zero set). Both at a 4 mm cell; both linear in the cell. The
// true wall is uniform to +-1-3 % over the sheet at every density, which is what R7 asked of
// the gradient-normalised band; it runs below t as the wall thickens (-16 % at rho 0.60),
// because |f|/|grad f| is a first-order distance.
// One row type with every type's diameter table (type_measured, below): a sheet's TRUE wall
// is its "diameter" there, so the table is read through that block, not copied into it.
namespace {
struct TypeDiaRow { double rho, d_at_cell4_mm; };
}  // namespace
using SheetWallRow = TypeDiaRow;
constexpr SheetWallRow kGyroidTrueWall[] = {
    {0.05, 0.06469}, {0.08, 0.10366}, {0.10, 0.12956}, {0.15, 0.19467},
    {0.20, 0.26028}, {0.25, 0.32650}, {0.30, 0.39356}, {0.35, 0.46154},
    {0.40, 0.53073}, {0.50, 0.67386}, {0.60, 0.82634},
};
constexpr SheetWallRow kGyroidWallParam[] = {
    {0.05, 0.06475}, {0.08, 0.10393}, {0.10, 0.13008}, {0.15, 0.19643},
    {0.20, 0.26453}, {0.25, 0.33497}, {0.30, 0.40861}, {0.35, 0.48621},
    {0.40, 0.56898}, {0.50, 0.75621}, {0.60, 0.98931},
};
constexpr SheetWallRow kSchwarzDTrueWall[] = {
    {0.05, 0.05214}, {0.08, 0.08338}, {0.10, 0.10440}, {0.15, 0.15681},
    {0.20, 0.20978}, {0.25, 0.26302}, {0.30, 0.31697}, {0.35, 0.37164},
    {0.40, 0.42772}, {0.50, 0.54291}, {0.60, 0.66583},
};
constexpr SheetWallRow kSchwarzDWallParam[] = {
    {0.05, 0.05219}, {0.08, 0.08358}, {0.10, 0.10479}, {0.15, 0.15813},
    {0.20, 0.21297}, {0.25, 0.26936}, {0.30, 0.32819}, {0.35, 0.38997},
    {0.40, 0.45610}, {0.50, 0.60335}, {0.60, 0.78374},
};
constexpr int kSheetWallRows = 11;

// ── ★ EACH LIVE TYPE'S OWN MEASUREMENTS, IN ONE PLACE (lattice types round 1) ──
// R1: a type goes live only when every number it uses is its OWN measurement. They
// live here, one block per type, each number beside the run that produced it. Octet's
// numbers are NOT here: they stay where they always were, untouched (R9). A type with
// no block keeps today's behaviour, and the per-type entry points below refuse it
// rather than read octet's.
namespace {

struct TypeCpmPoint { double cells, stiffness_error; };

struct TypeMeasurements {
  // density -> strut diameter at a 4 mm cell (diameter is exactly linear in cell).
  const TypeDiaRow* dia;
  int ndia;
  // the BENDING accuracy floor (cells per member), PERCOLATION floor, and the aesthetic
  // hard floor. No "with a finish" relaxation: octet's 1-cell skinned measurement is
  // octet's (evidence/2026-08-21-organic-lattice/cpm), so a new type keeps the bare
  // floor until its own skinned member is measured.
  double cells_per_member_min;
  double percolation_cells_per_member_min;
  double aesthetic_hard_floor;
  // the bending error curve the adaptive aesthetic floor reads.
  const TypeCpmPoint* curve;
  int ncurve;
};

// FCC — docs/handoffs/evidence/2026-11-01-lattice-types-k1/fcc_*.{csv,txt}, from
// core/tests/harness/lattice_types_probe.cpp on the canonical cell (strut_cell.hpp).
//
// DIAMETER (`law fcc`): r/L bisected 50 steps on the cell's CONVERGED solid fraction
// (strut_cell_solid_fraction, 2^20 Halton samples -- see its note for why not the vpc48
// voxel staircase), diameter at a 4 mm cell, VERBATIM. The same bisection on the vpc48
// voxels (octet's B3 method) reproduced octet's OLD kOctetDia to all four digits, because
// that table was measured on the LEGS-ONLY cell, which is geometrically FCC; this
// converged table sits within -2.7 / +2.5 % of it (fcc_law.txt, column "B3 gap"). Octet's
// table is its own full cell's since ruling 2026-11-02 (c).
constexpr TypeDiaRow kFccDia[] = {
    {0.05, 0.3639}, {0.08, 0.4670}, {0.10, 0.5265}, {0.15, 0.6580},
    {0.20, 0.7739}, {0.30, 0.9807}, {0.40, 1.1712}, {0.60, 1.5434},
};
// BENDING (`bend fcc`): PR 235's C2b guided cantilever on FCC's cell, S = 5 mm, vpc12,
// 6 cells long, periodic cell rho 0.1991 (target 0.30 at vpc12, the same achieved rho
// as octet's C2b): +54.01 / +8.92 / +4.15 / +2.58 / +1.80 / +1.32 % at 1..6 cells. The
// 2.4 % band is crossed between 4 and 5 cells -> 5.
constexpr TypeCpmPoint kFccCurve[] = {
    {1.0, 0.5401}, {2.0, 0.0892}, {3.0, 0.0415}, {4.0, 0.0258}, {5.0, 0.0180}};
// PERCOLATION (`perc fcc`): members 0.5 / 0.75 / 1 / 1.5 / 2 cells across, at rho
// 0.0950 / 0.3430 / 0.5909 (band low, middle, high), window placed at 0, 0.25, 0.5 and
// 0.75 cell, vpc16, 4 cells long, 6-connected: 0.5 cells fails to span at the 0.25
// placement at every rho; from 0.75 cells up a spanning network exists at every
// placement and rho -> 0.75. (Window-cut debris, <= 1.7 % of the solid, is reported
// there and is the clip's, not the lattice's.)
// AESTHETIC HARD FLOOR: 2 cells is +8.92 % in bending and percolates -> 2.
constexpr TypeMeasurements kFccMeasured = {
    kFccDia, 8, 5.0, 0.75, 2.0, kFccCurve, 5};

// KELVIN -- docs/handoffs/evidence/2026-11-01-lattice-types-k1/kelvin_*.{csv,txt}, the
// same harness and conditions as FCC's block above.
// DIAMETER (`law kelvin`): bisected on the converged solid fraction; within the band the
// vpc48 B3 table differs by at most 3.9 % (kelvin_law.txt, "B3 gap").
constexpr TypeDiaRow kKelvinDia[] = {
    {0.05, 0.3658}, {0.08, 0.4704}, {0.10, 0.5315}, {0.15, 0.6661}, {0.20, 0.7858},
    {0.30, 1.0027}, {0.40, 1.2077}, {0.60, 1.6343},
};
// BENDING (`bend kelvin`, kelvin_bend.txt + kelvin_bend_wide.txt): C2b guided
// cantilever, S = 5 mm, vpc12, 6 cells long, periodic cell rho 0.1944: +62.30 / +32.90 /
// +18.14 / +11.00 / +7.06 / +4.64 / +3.03 / +1.89 % at 1..8 cells (+1.04 at 9, +0.38 at
// 10, -0.57 at 12). The 2.4 % band is crossed between 7 and 8 cells -> 8.
constexpr TypeCpmPoint kKelvinCurve[] = {
    {1.0, 0.6230}, {2.0, 0.3290}, {3.0, 0.1814}, {4.0, 0.1100}, {5.0, 0.0706},
    {6.0, 0.0464}, {7.0, 0.0303}, {8.0, 0.0189},
};
// PERCOLATION (`perc kelvin`): members 0.5 / 0.75 / 1 / 1.5 / 2 cells across at rho
// 0.0938 / 0.2995 / 0.5052 (band low, middle, high), placements 0 / .25 / .5 / .75 cell,
// vpc16, 4 cells long, 6-connected: a spanning network at every placement and rho from
// 0.75 cells -> 0.75.
// AESTHETIC HARD FLOOR: 2 cells is +32.90 % in bending and percolates -> 2.
constexpr TypeMeasurements kKelvinMeasured = {
    kKelvinDia, 8, 8.0, 0.75, 2.0, kKelvinCurve, 8};

// RHOMBIC DODECAHEDRON -- docs/handoffs/evidence/2026-11-01-lattice-
// types-k1/rhombic_*.{csv,txt}, the same harness and conditions as FCC's block above.
// DIAMETER (`law rhombic`): bisected on the converged solid fraction; within the band
// the vpc48 B3 table differs by at most 5.0 % (rhombic_law.txt, "B3 gap").
constexpr TypeDiaRow kRhombicDia[] = {
    {0.05, 0.2849}, {0.08, 0.3667}, {0.10, 0.4132}, {0.15, 0.5166}, {0.20, 0.6081},
    {0.30, 0.7724}, {0.40, 0.9247}, {0.60, 1.2271},
};
// BENDING (`bend rhombic`, rhombic_bend.txt + rhombic_bend_wide.txt): C2b guided
// cantilever, S = 5 mm, vpc12, 6 cells long, periodic cell rho 0.2963: +119.63 / +31.98
// / +16.34 / +10.40 / +7.33 / +5.49 / +4.27 / +3.42 / +2.80 / +2.34 % at 1..10 cells
// (+1.70 at 12). The 2.4 % band is crossed between 9 and 10 cells -> 10.
constexpr TypeCpmPoint kRhombicCurve[] = {
    {1.0, 1.1963}, {2.0, 0.3198}, {3.0, 0.1634}, {4.0, 0.1040}, {5.0, 0.0733},
    {6.0, 0.0549}, {7.0, 0.0427}, {8.0, 0.0342}, {9.0, 0.0280}, {10.0, 0.0234},
};
// PERCOLATION (`perc rhombic`): members 0.5 / 0.75 / 1 / 1.5 / 2 cells across at rho
// 0.1724 / 0.3429 / 0.5133 (band low, middle, high), placements 0 / .25 / .5 / .75 cell,
// vpc16, 4 cells long, 6-connected: a spanning network at every placement and rho from
// 0.75 cells -> 0.75.
// AESTHETIC HARD FLOOR: 2 cells is +31.98 % in bending and percolates -> 2.
constexpr TypeMeasurements kRhombicMeasured = {
    kRhombicDia, 8, 10.0, 0.75, 2.0, kRhombicCurve, 10};

// DIAMOND -- docs/handoffs/evidence/2026-11-01-lattice-types-k1/diamond_*.{csv,txt}, the
// same harness and conditions as FCC's block above.
// DIAMETER (`law diamond`): bisected on the converged solid fraction; within the band
// the vpc48 B3 table differs by at most 4.9 % (diamond_law.txt, "B3 gap").
constexpr TypeDiaRow kDiamondDia[] = {
    {0.05, 0.4021}, {0.08, 0.5158}, {0.10, 0.5819}, {0.15, 0.7261}, {0.20, 0.8533},
    {0.30, 1.0796}, {0.40, 1.2866}, {0.60, 1.6864},
};
// BENDING (`bend diamond`, diamond_bend.txt + diamond_bend_wide.txt): C2b guided
// cantilever, S = 5 mm, vpc12, 6 cells long, periodic cell rho 0.2685: +907.89 / +98.17
// / +37.40 / +19.03 / +11.11 / +7.07 / +4.76 / +3.35 / +2.42 / +1.77 % at 1..10 cells
// (+0.93 at 12). 9 cells reads +2.42 %, just outside the 2.4 % band, so the crossing is
// between 9 and 10 -> 10.
constexpr TypeCpmPoint kDiamondCurve[] = {
    {1.0, 9.0789}, {2.0, 0.9817}, {3.0, 0.3740}, {4.0, 0.1903}, {5.0, 0.1111},
    {6.0, 0.0707}, {7.0, 0.0476}, {8.0, 0.0335}, {9.0, 0.0242}, {10.0, 0.0177},
};
// PERCOLATION (`perc diamond`): members 0.5 / 0.75 / 1 / 1.5 / 2 cells across at rho
// 0.1571 / 0.3746 / 0.5920 (band low, middle, high), placements 0 / .25 / .5 / .75 cell,
// vpc16, 4 cells long, 6-connected: a spanning network at every placement and rho from
// 0.75 cells -> 0.75.
// AESTHETIC HARD FLOOR: 2 cells is +98.17 % in bending and percolates -> 2.
constexpr TypeMeasurements kDiamondMeasured = {
    kDiamondDia, 8, 10.0, 0.75, 2.0, kDiamondCurve, 10};

// BCC -- docs/handoffs/evidence/2026-11-01-lattice-types-k1/bcc_*.{csv,txt}, the same
// harness and conditions as FCC's block above.
// DIAMETER (`law bcc`): bisected on the converged solid fraction; within the band the
// vpc48 B3 table differs by at most 4.9 % (bcc_law.txt, "B3 gap").
constexpr TypeDiaRow kBccDia[] = {
    {0.05, 0.4018}, {0.08, 0.5157}, {0.10, 0.5817}, {0.15, 0.7262}, {0.20, 0.8531},
    {0.30, 1.0795}, {0.40, 1.2869}, {0.60, 1.6864},
};
// BENDING (`bend bcc`, bcc_bend.txt + bcc_bend_wide.txt): C2b guided cantilever, S = 5
// mm, vpc12, 6 cells long, periodic cell rho 0.2778: +220.05 / +49.68 / +22.62 / +12.95
// / +8.35 / +5.78 / +4.20 / +3.18 / +2.48 / +1.98 % at 1..10 cells (+1.32 at 12). The
// 2.4 % band is crossed between 9 and 10 cells -> 10.
constexpr TypeCpmPoint kBccCurve[] = {
    {1.0, 2.2005}, {2.0, 0.4968}, {3.0, 0.2262}, {4.0, 0.1295}, {5.0, 0.0835},
    {6.0, 0.0578}, {7.0, 0.0420}, {8.0, 0.0318}, {9.0, 0.0248}, {10.0, 0.0198},
};
// PERCOLATION (`perc bcc`): members 0.5 / 0.75 / 1 / 1.5 / 2 cells across at rho 0.2105
// / 0.4017 / 0.5929 (band low, middle, high), placements 0 / .25 / .5 / .75 cell, vpc16,
// 4 cells long, 6-connected: a spanning network at every placement and rho from 0.75
// cells -> 0.75.
// AESTHETIC HARD FLOOR: 2 cells is +49.68 % in bending and percolates -> 2.
constexpr TypeMeasurements kBccMeasured = {
    kBccDia, 8, 10.0, 0.75, 2.0, kBccCurve, 10};

// SIMPLE CUBIC -- docs/handoffs/evidence/2026-11-01-lattice-types-k1/sc_*.{csv,txt}, the
// same harness and conditions as FCC's block above.
// DIAMETER (`law sc`): bisected on the converged solid fraction; within the band the
// vpc48 B3 table differs by at most 4.0 % (sc_law.txt, "B3 gap").
constexpr TypeDiaRow kScDia[] = {
    {0.05, 0.6113}, {0.08, 0.7847}, {0.10, 0.8849}, {0.15, 1.1051}, {0.20, 1.2988},
    {0.30, 1.6445}, {0.40, 1.9620}, {0.60, 2.5777},
};
// BENDING (`bend sc`, sc_bend.txt + sc_bend_wide.txt): C2b guided cantilever, S = 5 mm,
// vpc12, 6 cells long, periodic cell rho 0.2593: -3.72 / +12.49 / +6.03 / +2.08 % at
// 1..4 cells (-0.12 at 5, -1.48 at 6). The 2.4 % band is crossed between 3 and 4 cells
// -> 4. Measured with the cell axes ALONG the member (C2b's orientation): SC is strongly
// directional (R3) and this floor says nothing about an off-axis member.
constexpr TypeCpmPoint kScCurve[] = {
    {1.0, -0.0372}, {2.0, 0.1249}, {3.0, 0.0603}, {4.0, 0.0208},
};
// PERCOLATION (`perc sc`): members 0.5 / 0.75 / 1 / 1.5 / 2 cells across at rho 0.0866 /
// 0.2915 / 0.4964 (band low, middle, high), placements 0 / .25 / .5 / .75 cell, vpc16, 4
// cells long, 6-connected: a spanning network at every placement and rho from 0.75 cells
// -> 0.75.
// AESTHETIC HARD FLOOR: 2 cells is +12.49 % in bending and percolates -> 2.
constexpr TypeMeasurements kScMeasured = {
    kScDia, 8, 4.0, 0.75, 2.0, kScCurve, 4};

// THE SHEETS (K2) -- docs/handoffs/evidence/2026-11-01-lattice-types-k1/<sheet>_*.{csv,txt},
// from core/tests/harness/tpms_probe.cpp on the production wall (tpms.hpp).
// "DIAMETER": a sheet's is its TRUE wall thickness (k<Sheet>TrueWall above, `law`), the
// thickness a printer must lay, so every printability reader (wall >= bead) reads it as is.
// BENDING (`bend`): PR 235's C2b guided cantilever on the sheet, S = 5 mm, vpc24 (the wall
// ~3 voxels), 6 cells long, target rho 0.40. From 7 cells across the resolved solve runs
// matrix-free (TOPOPT_BEND_MATFREE=1, the same system and criterion: it reproduces the
// 3-cell runs to every printed digit, 643.4300 and 745.4677), because the assembled K of a
// 9-cell block (~20M dof) does not fit in 16 GB.
// PERCOLATION (`perc`): members 0.5 / 0.75 / 1 / 1.5 / 2 cells across at rho 0.15 / 0.35 /
// 0.60, placements x = y in 0 / .25 / .5 / .75 cell, vpc32, 4 cells long, 6-connected: the
// sheet spans at every placement and rho from 0.5 cells, the smallest member measured -> 0.5.
// AESTHETIC HARD FLOOR: 2 cells percolates (in bending +43.56 % gyroid, +20.48 % Schwarz-D)
// -> 2, the strut types' floor.
//
// GYROID (`bend gyroid`, gyroid_bend.txt + gyroid_bend_wide.txt), cell rho 0.4051:
// +227.08 / +43.56 / +20.84 / +12.39 / +8.25 / +5.90 / +4.43 / +3.45 / +2.76 / +2.24 % at
// 1..10 cells. The 2.4 % band is crossed between 9 and 10 cells -> 10.
constexpr TypeCpmPoint kGyroidCurve[] = {
    {1.0, 2.2708}, {2.0, 0.4356}, {3.0, 0.2084}, {4.0, 0.1239}, {5.0, 0.0825},
    {6.0, 0.0590}, {7.0, 0.0443}, {8.0, 0.0345}, {9.0, 0.0276}, {10.0, 0.0224},
};
constexpr TypeMeasurements kGyroidMeasured = {
    kGyroidTrueWall, kSheetWallRows, 10.0, 0.5, 2.0, kGyroidCurve, 10};
// SCHWARZ-D (`bend schwarz_d`, schwarz_d_bend.txt + schwarz_d_bend_wide.txt), cell rho
// 0.4074: +65.60 / +20.48 / +11.53 / +7.71 / +5.56 / +4.20 / +3.26 / +2.59 / +2.09 % at
// 1..9 cells. The 2.4 % band is crossed between 8 and 9 cells -> 9.
constexpr TypeCpmPoint kSchwarzDCurve[] = {
    {1.0, 0.6560}, {2.0, 0.2048}, {3.0, 0.1153}, {4.0, 0.0771}, {5.0, 0.0556},
    {6.0, 0.0420}, {7.0, 0.0326}, {8.0, 0.0259}, {9.0, 0.0209},
};
constexpr TypeMeasurements kSchwarzDMeasured = {
    kSchwarzDTrueWall, kSheetWallRows, 9.0, 0.5, 2.0, kSchwarzDCurve, 9};

const TypeMeasurements* type_measured(LatticeTopology topo) {
  switch (topo) {
    case LatticeTopology::Fcc:
      return &kFccMeasured;
    case LatticeTopology::SimpleCubic:
      return &kScMeasured;
    case LatticeTopology::Bcc:
      return &kBccMeasured;
    case LatticeTopology::Diamond:
      return &kDiamondMeasured;
    case LatticeTopology::Rhombic:
      return &kRhombicMeasured;
    case LatticeTopology::Kelvin:
      return &kKelvinMeasured;
    case LatticeTopology::Gyroid:
      return &kGyroidMeasured;
    case LatticeTopology::SchwarzD:
      return &kSchwarzDMeasured;
    case LatticeTopology::Octet:  // octet's numbers are where they always were (R9)
    case LatticeTopology::Bccz:
    case LatticeTopology::Fccz:
    case LatticeTopology::Reentrant:
      return nullptr;
  }
  return nullptr;
}

// Octet's interpolation, operation for operation (octet_strut_diameter_mm): clamp to
// the end rows, linear between.
double type_table_diameter_mm(const TypeMeasurements& m, double rho, double cell_size_mm,
                              const char* who) {
  if (!(cell_size_mm > 0.0))
    throw std::invalid_argument(std::string(who) + ": cell_size_mm must be > 0");
  if (!(std::isfinite(rho) && rho >= 0.0))
    throw std::invalid_argument(std::string(who) + ": rho must be finite and >= 0");
  const TypeDiaRow* rows = m.dia;
  const int n = m.ndia;
  double d4;
  if (rho <= rows[0].rho) {
    d4 = rows[0].d_at_cell4_mm;
  } else if (rho >= rows[n - 1].rho) {
    d4 = rows[n - 1].d_at_cell4_mm;
  } else {
    int a = 0;
    while (a + 1 < n && rows[a + 1].rho < rho) ++a;
    const TypeDiaRow& r0 = rows[a];
    const TypeDiaRow& r1 = rows[a + 1];
    const double t = r1.rho > r0.rho ? (rho - r0.rho) / (r1.rho - r0.rho) : 0.0;
    d4 = r0.d_at_cell4_mm + t * (r1.d_at_cell4_mm - r0.d_at_cell4_mm);
  }
  return d4 * (cell_size_mm / 4.0);
}

}  // namespace

bool lattice_topology_is_sheet(LatticeTopology topo) {
  return topo == LatticeTopology::Gyroid || topo == LatticeTopology::SchwarzD;
}

double lattice_sheet_wall_param_mm(LatticeTopology topo, double true_wall_mm, double cell_mm) {
  if (!lattice_topology_is_sheet(topo))
    throw std::invalid_argument(std::string("lattice_sheet_wall_param_mm: \"") +
                                lattice_topology_name(topo) + "\" is not a sheet lattice");
  if (!(cell_mm > 0.0) || !(true_wall_mm > 0.0))
    throw std::invalid_argument("lattice_sheet_wall_param_mm: wall and cell must be > 0");
  const SheetWallRow* tw = topo == LatticeTopology::Gyroid ? kGyroidTrueWall : kSchwarzDTrueWall;
  const SheetWallRow* tp = topo == LatticeTopology::Gyroid ? kGyroidWallParam : kSchwarzDWallParam;
  // the same density on both tables: invert the TRUE wall, read the parameter there (both
  // are linear in the cell, so this is done at the tables' 4 mm cell and scaled back)
  const double w4 = true_wall_mm * (4.0 / cell_mm);
  const int n = kSheetWallRows;
  if (w4 <= tw[0].d_at_cell4_mm) return tp[0].d_at_cell4_mm / tw[0].d_at_cell4_mm * true_wall_mm;
  if (w4 >= tw[n - 1].d_at_cell4_mm)
    return tp[n - 1].d_at_cell4_mm / tw[n - 1].d_at_cell4_mm * true_wall_mm;
  int a = 0;
  while (a + 1 < n - 1 && tw[a + 1].d_at_cell4_mm < w4) ++a;
  const double t = (w4 - tw[a].d_at_cell4_mm) / (tw[a + 1].d_at_cell4_mm - tw[a].d_at_cell4_mm);
  return (tp[a].d_at_cell4_mm + t * (tp[a + 1].d_at_cell4_mm - tp[a].d_at_cell4_mm)) * (cell_mm / 4.0);
}

namespace {
// A sheet's solid fraction on the unit cell at field parameter t (units of L): the method
// its wall table was bisected on (tpms_probe.cpp `law`): the 3-D Halton points (bases 2, 3,
// 5; indices 1..2^20) inside tpms.hpp's production wall. Deterministic, continuous in t.
double sheet_solid_fraction(LatticeTopology topo, double t_unit) {
  auto halton = [](unsigned i, unsigned base) {
    double f = 1.0, r = 0.0;
    while (i > 0) { f /= base; r += f * (i % base); i /= base; }
    return r;
  };
  const TpmsKind kind = topo == LatticeTopology::Gyroid ? TpmsKind::Gyroid : TpmsKind::SchwarzD;
  const int samples = 1 << 20;
  long long in = 0;
  for (int n = 1; n <= samples; ++n)
    if (tpms_in_wall(kind, halton(n, 2), halton(n, 3), halton(n, 5), 1.0, t_unit)) ++in;
  return double(in) / samples;
}
}  // namespace

bool lattice_type_numbers_measured(LatticeTopology topo) {
  return topo == LatticeTopology::Octet || type_measured(topo) != nullptr;
}

double lattice_cells_per_member_min(LatticeTopology topo) {
  if (const TypeMeasurements* m = type_measured(topo)) return m->cells_per_member_min;
  // MEASURED for octet (bending ceiling, handoff 2026-07-28-graded-cell-size-phase0
  // C2b): the 2.4% band is crossed between 4 and 5 cells across, so 5. For the other
  // certifiable topologies the bending floor is NOT independently measured here — that
  // needs the PR 235 guided-cantilever finite-block study (handoff
  // 2026-07-29-tensor-library-nine, T4). octet's 5 is forwarded as a documented
  // placeholder; it is representative for the stretch-dominated lattices (fcc, rhombic)
  // and is expected to be an UNDER-estimate for the bending-dominated ones (bcc, kelvin,
  // diamond, sc), so re-measure before grading those. It is load-bearing only for the
  // grading law, which is octet-only in production — no other topology is graded against
  // it today. Change the number HERE, per topology, once measured (type_measured).
  return 5.0;
}

double lattice_percolation_cells_per_member_min(LatticeTopology topo) {
  if (const TypeMeasurements* m = type_measured(topo))
    return m->percolation_cells_per_member_min;
  // MEASURED for octet, from the SAME study as the accuracy floor above
  // (handoff 2026-07-28-graded-cell-size-phase0, the C2 AXIAL table):
  //   0.5 cells across -> DISCONNECTED: the member does not percolate at all
  //   1   cell         -> +2.36 % axial error, CONNECTED
  //   2   cells        -> +1.20 %
  //   3   cells        -> +0.81 %
  // So one cell is where the geometry first holds together. This is a DIFFERENT
  // FLOOR FROM A DIFFERENT FAILURE MODE and the two must not be confused: the
  // accuracy floor above protects the CERTIFICATE (a homogenized tensor stops
  // describing the member), while this protects the OBJECT (below it there is no
  // connected strut network to print). A member between the two is buildable and
  // uncertifiable — that is exactly the regime sub-floor retention exists for, and
  // it is not the same thing as un-latticeable.
  //
  // ★ PLACEHOLDER STATUS, stated because three numbers on this project have already
  // been quoted without their conditions. This is measured for OCTET, at rho ~= 0.199
  // and AXIALLY. It is NOT measured at the top of the band (rho ~ 0.60), where the
  // derived-cell route puts it, and NOT in bending. It is forwarded for the other
  // topologies with no independent measurement at all. Re-measure before treating a
  // near-1.0 result as safe; and note the empirical end of the argument, which IS
  // measured: the maintainer's shipped mesh ran at 0.4263 cells per member and
  // produced 123 isolated fragments at the line-width threshold. Below percolation
  // you do not get a thin lattice, you get debris.
  return 1.0;
}

double lattice_subfloor_retention_stress_fraction() {
  // MEASURED — handoff 2026-08-04-protect-freeze-vs-solidity §10, the six-station
  // flange sweep in `item8_subfloor_floor.txt`. The certified-margin movement from
  // latticing a region at 1.33 cells per member stays within +0.0008 % up to a region
  // carrying 19.37 % of the part's peak von Mises, then jumps 25x to +0.0203 % at
  // 22.09 %. 0.20 is the threshold in that knee: it admits every station measured flat
  // and excludes every station measured steep. The full derivation, and the CONTROL
  // that says what this number is NOT evidence for, are in lattice.hpp above the
  // declaration — read them before moving it.
  return 0.20;
}

double lattice_subfloor_aggregate_cap_fraction() {
  // POLICY, not a measurement — see lattice.hpp's ★★★ note. A stated ~3.2x multiple
  // of the one end-to-end verified configuration (822 of 88,424 printed voxels =
  // 0.930 % of the part). Bounding exposure is all it does; it makes no claim that
  // the retained material is accurate, and the certification cannot check whether it
  // is. Revisit the moment a direct-FEA strut measurement exists (currently a
  // 44-276x cost ceiling).
  return 0.03;
}

namespace {

// The printed octet strut DIAMETER at cell edge 4 mm, per relative density.
//
// ★ OCTET MADE HONEST (ruling 2026-11-02 (c)). This used to be PR 198's B3 table,
// measured on the LEGS-ONLY cell (geometrically FCC: lattice_types_probe reproduces it
// to all four digits on FCC) while the generator lays the FULL octet, legs and braces,
// 24 struts a cell: at the same density the file held +50 to +90 % more lattice than the
// certificate counted (c_gapcell_before_c.txt; +0.1 to +0.3 % on this law,
// c_gapcell_after_c.txt). It is now octet's OWN law, measured the way
// every other type's is (Finding 1): `lattice_types_probe law octet` on the full cell,
// r/L bisected 50 steps on the cell's CONVERGED solid fraction (strut_cell_solid_fraction,
// 2^20 Halton samples), diameter at a 4 mm cell, VERBATIM
// (docs/handoffs/evidence/2026-11-01-lattice-types-k1/c_octet_law.{csv,txt}). The vpc48
// bisection on the same full cell sits within -6.5 / +5.2 % of it ("B3 gap"). Since (b)
// the emitted strut holds the round strut's area, so this is the density the file holds.
// Diameter is exactly linear in cell size; a query at any cell scales by cell/4. Ordered
// by rho; the span brackets the certifiable band 0.0496..0.9003 (its two end rows, 0.045 and
// 0.95, were measured the same way when the tensor rows landed: c_octet_law_ends.txt).
struct DiaRow { double rho, d_at_cell4_mm; };
constexpr double kOctetDiaCellMm = 4.0;
constexpr std::array<DiaRow, 17> kOctetDia = {{
    {0.045, 0.2435}, {0.050, 0.2573}, {0.065, 0.2956}, {0.080, 0.3300}, {0.100, 0.3724}, {0.120, 0.4116},
    {0.150, 0.4653}, {0.200, 0.5473}, {0.250, 0.6226}, {0.300, 0.6934}, {0.400, 0.8286},
    {0.500, 0.9591}, {0.600, 1.0913}, {0.700, 1.2318}, {0.800, 1.3918}, {0.900, 1.6104},
    {0.950, 1.8202},
}};

}  // namespace

double octet_strut_diameter_mm(double rho, double cell_size_mm) {
  if (!(cell_size_mm > 0.0))
    throw std::invalid_argument(
        "octet_strut_diameter_mm: cell_size_mm must be > 0");
  if (!(std::isfinite(rho) && rho >= 0.0))
    throw std::invalid_argument(
        "octet_strut_diameter_mm: rho must be finite and >= 0");

  const std::array<DiaRow, 17>& rows = kOctetDia;
  const int n = static_cast<int>(rows.size());
  double d4;  // diameter at the reference 4 mm cell
  if (rho <= rows[0].rho) {
    d4 = rows[0].d_at_cell4_mm;
  } else if (rho >= rows[n - 1].rho) {
    d4 = rows[n - 1].d_at_cell4_mm;
  } else {
    int a = 0;
    while (a + 1 < n && rows[a + 1].rho < rho) ++a;
    const DiaRow& r0 = rows[a];
    const DiaRow& r1 = rows[a + 1];
    const double t =
        r1.rho > r0.rho ? (rho - r0.rho) / (r1.rho - r0.rho) : 0.0;
    d4 = r0.d_at_cell4_mm + t * (r1.d_at_cell4_mm - r0.d_at_cell4_mm);
  }
  return d4 * (cell_size_mm / kOctetDiaCellMm);
}

namespace {
// width / phi(rho) is the cell whose strut at rho is exactly the stated width, but only
// to rounding: on octet's full-cell law 0.42 / phi(rho_max) builds a 0.41999999999999993
// mm strut, which every strut-vs-width test in core reads as UNDER the width (FIT derives
// exactly this cell for a thin wall, and grade_lattice's audit threw). So the cell is
// nudged up by ulps until its strut provably prints: a cell core calls printable prints.
double cell_whose_strut_prints(LatticeTopology topo, double rho, double width_mm,
                               double phi_per_mm) {
  double cell = width_mm / phi_per_mm;
  for (int i = 0; i < 8 && lattice_strut_diameter_mm(topo, rho, cell) < width_mm; ++i)
    cell = std::nextafter(cell, std::numeric_limits<double>::infinity());
  return cell;
}
}  // namespace

double lattice_min_printable_cell_mm(LatticeTopology topo,
                                     double min_extrudable_width_mm,
                                     double max_relative_density) {
  if (!(std::isfinite(min_extrudable_width_mm) && min_extrudable_width_mm > 0.0))
    throw std::invalid_argument(
        "lattice_min_printable_cell_mm: min_extrudable_width_mm must be finite and > 0");
  const double band_top = lattice_rho_max(topo);
  if (!(band_top > 0.0))
    throw std::invalid_argument(
        "lattice_min_printable_cell_mm: " + std::string(lattice_topology_name(topo)) +
        " has no certifiable density band, so it has no densest printable cell");
  // A cap of 0 or non-finite is NOT SENT -- the uncapped dense floor, which is what every
  // path that had no cap parameter was computing.
  const double rho_hi =
      (std::isfinite(max_relative_density) && max_relative_density > 0.0)
          ? std::min(band_top, max_relative_density)
          : band_top;
  // ★ A cap under the band's own floor leaves NO admissible density. Evaluating phi there
  // would read outside the measured table and hand back a cell size derived from a
  // density core has never measured. Named, not substituted.
  const double band_lo = lattice_rho_min(topo);
  if (rho_hi < band_lo) {
    char msg[256];
    std::snprintf(msg, sizeof msg,
                  "lattice_min_printable_cell_mm: a cap of %.6g is below %s's band floor "
                  "%.6g, so no density this job allows is one core has measured -- there "
                  "is no smallest printable cell to report",
                  max_relative_density, lattice_topology_name(topo), band_lo);
    throw std::invalid_argument(msg);
  }
  const double per_mm = lattice_strut_diameter_mm(topo, rho_hi, 1.0);
  if (!(per_mm > 0.0))
    throw std::invalid_argument(
        "lattice_min_printable_cell_mm: the diameter law returned no width at the capped "
        "band top");
  return cell_whose_strut_prints(topo, rho_hi, min_extrudable_width_mm, per_mm);
}

double lattice_cell_printability_floor_mm(LatticeTopology topo,
                                          double min_extrudable_width_mm) {
  if (!(std::isfinite(min_extrudable_width_mm) && min_extrudable_width_mm > 0.0))
    throw std::invalid_argument(
        "lattice_cell_printability_floor_mm: min_extrudable_width_mm must be "
        "finite and > 0");
  // The thinnest strut at any cell size occurs at the band's LOW end (diameter is
  // monotone in rho), and diameter is exactly linear in cell size, so the floor is
  // the stated width divided by the diameter at a UNIT cell.
  const double rho_lo = lattice_rho_min(topo);
  const double phi_lo = lattice_strut_diameter_mm(topo, rho_lo, 1.0);
  return cell_whose_strut_prints(topo, rho_lo, min_extrudable_width_mm, phi_lo);
}

double lattice_min_density_for_strut(LatticeTopology topo, double cell_size_mm,
                                     double min_extrudable_width_mm,
                                     double max_relative_density) {
  if (!(cell_size_mm > 0.0))
    throw std::invalid_argument(
        "lattice_min_density_for_strut: cell_size_mm must be > 0");
  if (!(std::isfinite(min_extrudable_width_mm) && min_extrudable_width_mm > 0.0))
    throw std::invalid_argument(
        "lattice_min_density_for_strut: min_extrudable_width_mm must be finite "
        "and > 0");
  const double rho_lo = lattice_rho_min(topo);
  const double band_top = lattice_rho_max(topo);
  if (!(band_top > 0.0))
    throw std::invalid_argument(
        "lattice_min_density_for_strut: topology has no certifiable band");
  // ★ D1: the ceiling this bisects against is the job's, not the band's. Uncapped it
  // could return a density the job forbids, which grade_lattice then clamps -- so the
  // floor it was handed and the floor it applied disagreed. 0 = not sent.
  const double rho_hi = (std::isfinite(max_relative_density) && max_relative_density > 0.0)
                            ? std::min(band_top, max_relative_density)
                            : band_top;
  if (rho_hi < rho_lo) {
    char m[224];
    std::snprintf(m, sizeof m,
                  "lattice_min_density_for_strut: a cap of %.6g is below %s's band floor "
                  "%.6g, so no density this job allows is one core has measured",
                  max_relative_density, lattice_topology_name(topo), rho_lo);
    throw std::invalid_argument(m);
  }

  // The band floor already prints — nothing lighter is admissible anyway.
  if (lattice_strut_diameter_mm(topo, rho_lo, cell_size_mm) >= min_extrudable_width_mm)
    return rho_lo;
  // Not even the band ceiling prints at this cell — there is no in-band answer, and
  // returning the ceiling would be a silent lie about a strut that comes out under
  // one bead. The contract is a negative sentinel the caller must test.
  if (lattice_strut_diameter_mm(topo, rho_hi, cell_size_mm) < min_extrudable_width_mm)
    return -1.0;

  // BISECT on the piecewise-linear measured table. It is monotone non-decreasing in
  // rho, so bisection converges on the exact breakpoint to machine precision; a
  // closed-form inversion would have to special-case the CLAMPED region above the
  // table's last measured row (rho 0.60), where phi is flat and the inverse is a
  // whole interval. Bisection returns that interval's LOW end, which is the lightest
  // density reaching the required diameter — exactly the contract.
  double lo = rho_lo, hi = rho_hi;
  for (int it = 0; it < 200; ++it) {
    const double mid = 0.5 * (lo + hi);
    if (lattice_strut_diameter_mm(topo, mid, cell_size_mm) >= min_extrudable_width_mm)
      hi = mid;
    else
      lo = mid;
  }
  // Return the side that SATISFIES the constraint. `hi` is the admissible end by the
  // loop invariant; a caller that fed it back into octet_strut_diameter_mm must not
  // see a strut one ULP under the bead width.
  return hi;
}

LatticeCellDerivation lattice_derive_cell_for_member(
    LatticeTopology topo, double member_width_mm,
    double min_extrudable_width_mm, double cells_per_member_floor,
    double max_relative_density) {
  // NaN fails every comparison, so `> 0.0` rejects it — deliberate: a member width
  // that is not a number must not be silently read as "thick enough".
  if (!(member_width_mm > 0.0))
    throw std::invalid_argument(
        "lattice_derive_cell_for_member: member_width_mm must be > 0");
  if (!(std::isfinite(min_extrudable_width_mm) && min_extrudable_width_mm > 0.0))
    throw std::invalid_argument(
        "lattice_derive_cell_for_member: min_extrudable_width_mm must be finite "
        "and > 0");

  LatticeCellDerivation d;
  d.member_width_mm = member_width_mm;
  d.min_extrudable_width_mm = min_extrudable_width_mm;
  d.band_rho_min = lattice_rho_min(topo);
  d.band_rho_max = lattice_rho_max(topo);
  if (!(d.band_rho_max > 0.0))
    throw std::invalid_argument(
        "lattice_derive_cell_for_member: topology '" +
        std::string(lattice_topology_name(topo)) +
        "' has no certifiable density band");
  d.cells_per_member_floor = cells_per_member_floor > 0.0
                                 ? cells_per_member_floor
                                 : lattice_cells_per_member_min(topo);
  d.floor_in_force_is_accuracy =
      !(cells_per_member_floor > 0.0) ||
      cells_per_member_floor == lattice_cells_per_member_min(topo);

  // The two bounds. phi is monotone in rho, so the band's top gives the smallest
  // printable cell; N* against the measured width gives the largest homogenizable one.
  // ★ D1: ONE function for the smallest printable cell, and it takes the job's cap.
  // This was `min_extrudable_width_mm / phi(band_rho_max, 1)` inline -- the UNCAPPED
  // floor -- so every bound derived below was finer than the job could print.
  d.min_printable_cell_mm =
      lattice_min_printable_cell_mm(topo, min_extrudable_width_mm, max_relative_density);
  d.min_member_width_mm = d.cells_per_member_floor * d.min_printable_cell_mm;
  // BOTH floors, always — see the declaration. The caller must never have to know
  // which question it asked in order to read the answer.
  d.min_member_width_certifiable_mm =
      lattice_cells_per_member_min(topo) * d.min_printable_cell_mm;
  d.min_member_width_buildable_mm =
      lattice_percolation_cells_per_member_min(topo) * d.min_printable_cell_mm;
  d.cells_per_member_at_finest = member_width_mm / d.min_printable_cell_mm;
  // GENUINE un-latticeability: does any pair clear printability AND percolation? A
  // member that fails THIS cannot be built at any setting. A member that clears it
  // but fails `feasible` below is buildable and uncertifiable, which is a different
  // verdict with a different remedy (M8c).
  d.feasible_percolation =
      member_width_mm >= d.min_member_width_buildable_mm;
  // +inf member width (voxel.hpp's "thicker than the EDT cap" sentinel) propagates to
  // +inf here, which is the honest reading: nothing bounds the cell from above.
  d.max_homogenizable_cell_mm = member_width_mm / d.cells_per_member_floor;

  d.feasible = d.max_homogenizable_cell_mm >= d.min_printable_cell_mm;
  if (!d.feasible) return d;  // every window field stays 0 — there is no window

  // `min_printable_cell_mm` is w/phi(rho_max) by construction, so the strut at
  // rho_max there is w EXACTLY — in real arithmetic. In floating point the product
  // can land one ULP low and make lattice_min_density_for_strut return its "no
  // in-band answer" sentinel at the very cell that defines the frontier. Resolve it
  // to the band ceiling, which is the true answer in the limit; anywhere the cell is
  // genuinely too fine this helper is never reached, because `feasible` is false.
  auto lightest_or_ceiling = [&](double cell) {
    const double r =
        lattice_min_density_for_strut(topo, cell, min_extrudable_width_mm);
    return r >= 0.0 ? r : d.band_rho_max;
  };

  // ── FINEST end: the smallest admissible cell. Report the LIGHTEST density that
  // reaches it rather than band_rho_max, because phi is CLAMPED above the measured
  // table's last row (see the ★ note on the declaration) and every density in that
  // flat region gives the identical cell — quoting the heaviest of them would add
  // mass for nothing.
  d.densest_cell_size_mm = d.min_printable_cell_mm;
  d.densest_relative_density = lightest_or_ceiling(d.densest_cell_size_mm);
  d.densest_strut_diameter_mm =
      lattice_strut_diameter_mm(topo, d.densest_relative_density,
                                d.densest_cell_size_mm);
  d.densest_cells_per_member = member_width_mm / d.densest_cell_size_mm;

  // ── COARSEST end: exactly N* cells across, at the lightest density that still
  // prints there — the MINIMUM-MASS certified lattice for this member. On an +inf
  // member width there is no upper bound, so both ends coincide at the frontier.
  if (std::isfinite(d.max_homogenizable_cell_mm)) {
    d.lightest_cell_size_mm = d.max_homogenizable_cell_mm;
    d.lightest_relative_density = lightest_or_ceiling(d.lightest_cell_size_mm);
    d.lightest_strut_diameter_mm = lattice_strut_diameter_mm(
        topo, d.lightest_relative_density, d.lightest_cell_size_mm);
    d.lightest_cells_per_member = member_width_mm / d.lightest_cell_size_mm;
  } else {
    d.lightest_cell_size_mm = d.densest_cell_size_mm;
    d.lightest_relative_density = d.densest_relative_density;
    d.lightest_strut_diameter_mm = d.densest_strut_diameter_mm;
    d.lightest_cells_per_member = d.densest_cells_per_member;
  }
  return d;
}

CubicTensor lattice_cubic_tensor(LatticeTopology topo, double rho,
                                 double youngs_modulus_solid, bool* rho_clamped) {
  if (!(youngs_modulus_solid > 0.0))
    throw std::invalid_argument(
        "lattice_cubic_tensor: youngs_modulus_solid must be > 0");
  RowTable tbl = rows_of(topo);
  // A topology the cubic library does not carry a validated tensor for — the
  // tetragonal variants (bccz/fccz/reentrant), whose effective tensor is not cubic —
  // is REFUSED, never certified against a wrong-symmetry or default tensor (bar B3).
  if (tbl.empty())
    throw LatticeTopologyNotCertifiable(
        std::string("lattice_cubic_tensor: topology '") +
        lattice_topology_name(topo) +
        "' has no validated cubic tensor (it is tetragonal / generate-but-not-certify);"
        " the certification gate refuses it — a cubic (C11,C12,C44) tensor cannot"
        " represent it. See handoff 2026-07-29-tensor-library-nine.");
  int lo, hi;
  resolved_span(tbl, lo, hi);

  bool clamped = false;
  double r = rho;
  if (r <= tbl.data[lo].rho) {
    r = tbl.data[lo].rho;
    clamped = (rho < tbl.data[lo].rho);
  } else if (r >= tbl.data[hi].rho) {
    r = tbl.data[hi].rho;
    clamped = (rho > tbl.data[hi].rho);
  }
  if (rho_clamped) *rho_clamped = clamped;

  // Piecewise-linear interpolation in rho between the two bracketing resolved rows.
  int a = lo;
  while (a < hi && tbl.data[a + 1].rho < r) ++a;
  const Row& r0 = tbl.data[a];
  const Row& r1 = tbl.data[a + 1 <= hi ? a + 1 : hi];
  double t = 0.0;
  if (r1.rho > r0.rho) t = (r - r0.rho) / (r1.rho - r0.rho);
  const double scale = youngs_modulus_solid / kLibraryEs;

  CubicTensor out;
  out.C11 = (r0.C11 + t * (r1.C11 - r0.C11)) * scale;
  out.C12 = (r0.C12 + t * (r1.C12 - r0.C12)) * scale;
  out.C44 = (r0.C44 + t * (r1.C44 - r0.C44)) * scale;
  return out;
}

bool lattice_stated_density_unprintable(LatticeTopology topo,
                                        double stated_relative_density,
                                        double cell_mm,
                                        double min_extrudable_width_mm) {
  // ★ THE UNREACHABILITY, AND IT IS THE FIRST LINE ON PURPOSE. Nothing below can
  // run for a job that states no density, so no later change to the arithmetic
  // can make an absent override refusable. It is also what keeps this function from
  // THROWING for a type with no diameter law when nothing was stated: an absent
  // override is not a question about the type.
  if (!(stated_relative_density > 0.0)) return false;
  if (!(cell_mm > 0.0) || !(min_extrudable_width_mm > 0.0)) return false;
  const double strut =
      lattice_strut_diameter_mm(topo, stated_relative_density, cell_mm);
  return strut + 1e-12 < min_extrudable_width_mm;
}


// ── ★ ONE PLACE THAT TURNS A JOB'S TOPOLOGY STRING INTO THE ENUM ───────────
// run_job.cpp hard-codes `LatticeTopology::Octet` in 23 places with the comment "job
// schema restricts topology to octet" (K0 inventory §3). That comment is true today
// and stops being true the moment the first type goes live, and every one of those
// sites is inside an anonymous namespace where no test can reach it. This is the seam:
// the ids are the ones `lattice_topology_name` emits, so the mapping is that function's
// inverse and cannot drift from it -- `test_strut_diameter_per_type` asserts the round
// trip over all ten.
//
// An unknown id REFUSES, naming what it was given. It never falls back to octet.
double lattice_density_from_strut(LatticeTopology topo, double cell_mm,
                                double strut_radius_mm) {
  switch (topo) {
    case LatticeTopology::Octet:
      return octet_relative_density(cell_mm, strut_radius_mm);
    case LatticeTopology::Fcc:
      break;  // type_measured, below
    case LatticeTopology::SimpleCubic:
    case LatticeTopology::Bcc:
    case LatticeTopology::Diamond:
    case LatticeTopology::Kelvin:
    case LatticeTopology::Rhombic:
    case LatticeTopology::Bccz:
    case LatticeTopology::Fccz:
    case LatticeTopology::Reentrant:
    case LatticeTopology::Gyroid:
    case LatticeTopology::SchwarzD:
      break;
  }
  if (const TypeMeasurements* m = type_measured(topo)) {
    // ONE measurement, read in the other direction. The table IS the converged solid
    // fraction bisected at its rows, so inside the table the inverse of its linear
    // interpolation is that same law -- and it makes the round trip exact, which a
    // second sampling would not. It is also microseconds: the app's prints-open
    // crossing bisects this ~60 times (the checker's finding), and a 2^20-point
    // integration per call was a multi-second stall. Off the table (a radius thinner
    // than the 0.05 row or fatter than the 0.60 one) it integrates the solid fraction.
    if (!(cell_mm > 0.0) || !std::isfinite(cell_mm))
      throw std::invalid_argument(
          "lattice_density_from_strut: cell_mm must be finite and > 0");
    if (!(strut_radius_mm > 0.0) || !std::isfinite(strut_radius_mm))
      throw std::invalid_argument(
          "lattice_density_from_strut: strut_radius_mm must be finite and > 0");
    const double d4 = 2.0 * strut_radius_mm * (4.0 / cell_mm);
    const TypeDiaRow* rows = m->dia;
    const int n = m->ndia;
    if (d4 >= rows[0].d_at_cell4_mm && d4 <= rows[n - 1].d_at_cell4_mm) {
      int a = 0;
      while (a + 1 < n - 1 && rows[a + 1].d_at_cell4_mm < d4) ++a;
      const TypeDiaRow& r0 = rows[a];
      const TypeDiaRow& r1 = rows[a + 1];
      const double t = (d4 - r0.d_at_cell4_mm) / (r1.d_at_cell4_mm - r0.d_at_cell4_mm);
      return r0.rho + t * (r1.rho - r0.rho);
    }
    // A sheet has no strut cell: its wall's own solid fraction, at the field parameter its
    // wall law gives this true wall (beyond the table that law scales by its end row).
    const double rho =
        lattice_topology_is_sheet(topo)
            ? sheet_solid_fraction(
                  topo, lattice_sheet_wall_param_mm(topo, 2.0 * strut_radius_mm, cell_mm) /
                            cell_mm)
            : strut_cell_solid_fraction(lattice_strut_cell(topo), strut_radius_mm / cell_mm);
    if (!(rho > 0.0) || rho >= 1.0)
      throw std::invalid_argument(
          "lattice_density_from_strut: strut radius produced a degenerate cell "
          "(rho outside (0,1)) -- check cell_mm / strut_radius_mm");
    return rho;
  }
  throw LatticeDiameterLawNotMeasured(
      std::string("lattice_density_from_strut: no measured density law for \"") +
      lattice_topology_name(topo) +
      "\" yet. This is the (cell, radius) -> rho direction of the same measurement as "
      "lattice_strut_diameter_mm, and octet's voxelisation is NOT used for another "
      "type (R1): the type's own cell has to be voxelised and landed first.");
}

double lattice_aesthetic_density_ceiling(LatticeTopology topo) {
  switch (topo) {
    case LatticeTopology::Octet:
      return octet_aesthetic_density_ceiling();
    case LatticeTopology::Fcc:
      break;  // type_measured, below
    case LatticeTopology::SimpleCubic:
    case LatticeTopology::Bcc:
    case LatticeTopology::Diamond:
    case LatticeTopology::Kelvin:
    case LatticeTopology::Rhombic:
    case LatticeTopology::Bccz:
    case LatticeTopology::Fccz:
    case LatticeTopology::Reentrant:
    case LatticeTopology::Gyroid:
    case LatticeTopology::SchwarzD:
      break;
  }
  if (type_measured(topo)) {
    // Sheets: "prints open" has no strut-per-cell reading for a wall, so the ceiling is the
    // band maximum until Q1 is ruled (00-decisions.md R11 / Q1).
    if (lattice_topology_is_sheet(topo)) return lattice_rho_max(topo);
    // Octet's bisection (octet_aesthetic_density_ceiling), through THIS type's table.
    const double cell = 4.0;
    const double want = kOctetAestheticStrutPerCell * cell;
    double lo = 0.01, hi = 0.90;
    for (int it = 0; it < 200; ++it) {
      const double mid = 0.5 * (lo + hi);
      (lattice_strut_diameter_mm(topo, mid, cell) < want ? lo : hi) = mid;
    }
    return 0.5 * (lo + hi);
  }
  throw LatticeAestheticCeilingNotMeasured(
      std::string("lattice_aesthetic_density_ceiling: no measured aesthetic density "
                  "ceiling for \"") +
      lattice_topology_name(topo) +
      "\" yet (R11). The ceiling is the same geometry ruling D set for octet -- strut "
      "diameter at 20 % of the cell -- bisected through THIS type's own measured "
      "diameter table, so it cannot be stated until that table exists. Octet's "
      "ceiling is not used for another type.");
}

LatticeTopologyChoice resolve_lattice_topology(const std::string& lattice_id,
                                               bool lattice_stated,
                                               const std::string& grading_id,
                                               bool grading_stated) {
  LatticeTopologyChoice out;
  out.lattice_id = lattice_id;
  out.grading_id = grading_id;
  if (lattice_stated && grading_stated) {
    if (lattice_id == grading_id) {
      out.id = lattice_id;
    } else {
      out.conflict = true;   // the caller refuses, naming both
    }
    return out;
  }
  if (lattice_stated) { out.id = lattice_id; return out; }
  if (grading_stated) { out.id = grading_id; return out; }
  out.id = "octet";          // neither stated: today's behaviour
  return out;
}

const char* lattice_type_readiness_name(LatticeTypeReadiness r) {
  switch (r) {
    case LatticeTypeReadiness::Live:           return "live";
    case LatticeTypeReadiness::NotGeneratable: return "certifiable, not yet generatable";
    case LatticeTypeReadiness::NotCertifiable: return "generatable, not yet certifiable";
    case LatticeTypeReadiness::NotEither:      return "neither generatable nor certifiable";
    case LatticeTypeReadiness::UnknownId:      return "not a lattice topology core knows";
  }
  return "unknown";
}

const char* lattice_type_readiness_plain(LatticeTypeReadiness r) {
  // Maintainer-facing wording, given by the reviewer 2026-09-30. "Strength-checked"
  // is the plain word for CERTIFIABLE and "buildable" for GENERATABLE, in that order,
  // because that is the order the picker greys them out in.
  switch (r) {
    case LatticeTypeReadiness::Live:           return "Ready to use";
    case LatticeTypeReadiness::NotGeneratable: return "Strength-checked, but not buildable yet";
    case LatticeTypeReadiness::NotCertifiable: return "Buildable, but not strength-checked yet";
    case LatticeTypeReadiness::NotEither:      return "Not buildable or strength-checked yet";
    case LatticeTypeReadiness::UnknownId:      return "Not a lattice type";
  }
  return "Not a lattice type";
}

LatticeTypeReadiness lattice_type_readiness(
    const std::string& id, const std::vector<std::string>& generatable,
    const std::vector<std::string>& certifiable) {
  bool known = false;
  for (LatticeTopology t : {LatticeTopology::Octet, LatticeTopology::SimpleCubic,
                            LatticeTopology::Bcc, LatticeTopology::Fcc,
                            LatticeTopology::Diamond, LatticeTopology::Kelvin,
                            LatticeTopology::Rhombic, LatticeTopology::Bccz,
                            LatticeTopology::Fccz, LatticeTopology::Reentrant,
                            LatticeTopology::Gyroid, LatticeTopology::SchwarzD})
    if (id == lattice_topology_name(t)) { known = true; break; }
  bool gen = false, cert = false;
  for (const std::string& n : generatable) if (n == id) { gen = true; break; }
  for (const std::string& n : certifiable) if (n == id) { cert = true; break; }
  // An id in either set is a type core knows, whatever the enum says -- the sets are
  // built from the enum, and a test may hand in its own.
  if (!known && !gen && !cert) return LatticeTypeReadiness::UnknownId;
  if (gen && cert) return LatticeTypeReadiness::Live;
  if (cert) return LatticeTypeReadiness::NotGeneratable;
  if (gen) return LatticeTypeReadiness::NotCertifiable;
  return LatticeTypeReadiness::NotEither;
}

LatticeTopology lattice_topology_from_id(const std::string& id) {
  for (LatticeTopology t : {LatticeTopology::Octet, LatticeTopology::SimpleCubic,
                            LatticeTopology::Bcc, LatticeTopology::Fcc,
                            LatticeTopology::Diamond, LatticeTopology::Kelvin,
                            LatticeTopology::Rhombic, LatticeTopology::Bccz,
                            LatticeTopology::Fccz, LatticeTopology::Reentrant,
                            LatticeTopology::Gyroid, LatticeTopology::SchwarzD})
    if (id == lattice_topology_name(t)) return t;
  throw std::invalid_argument(
      "lattice_topology_from_id: unknown lattice topology \"" + id +
      "\". It is not one of the ids lattice_topology_name emits, and there is no "
      "default: guessing octet would size another type with octet's measured table.");
}

// ── ★ THE ONE DEFINITION of density -> strut diameter, PER TYPE ─────────────
// R1 (docs/design/lattice-types/00-decisions.md): a type goes live only when every
// number it uses is its OWN measurement. This is where that is enforced for the
// density -> strut-diameter law, because it is the law with the most consumers (44
// call sites, K0 inventory) and the one whose misuse is invisible: a borrowed diameter
// does not throw, it prints a strut at the wrong size.
//
// Octet returns EXACTLY octet_strut_diameter_mm -- the same double, not an equivalent
// one -- which is what keeps R9's byte-identity true while every consumer moves onto
// this function. `test_strut_diameter_per_type` asserts that with `==`, over 180
// (rho, cell) pairs spanning the measured table and past both of its clamped ends.
//
// Every other topology REFUSES, by name. As each type's table is measured it gets a
// branch here and nowhere else.
double lattice_strut_diameter_mm(LatticeTopology topo, double rho,
                                 double cell_size_mm) {
  switch (topo) {
    case LatticeTopology::Octet:
      return octet_strut_diameter_mm(rho, cell_size_mm);
    case LatticeTopology::Fcc:
      break;  // type_measured, below
    case LatticeTopology::SimpleCubic:
    case LatticeTopology::Bcc:
    case LatticeTopology::Diamond:
    case LatticeTopology::Kelvin:
    case LatticeTopology::Rhombic:
    case LatticeTopology::Bccz:
    case LatticeTopology::Fccz:
    case LatticeTopology::Reentrant:
    case LatticeTopology::Gyroid:
    case LatticeTopology::SchwarzD:
      break;
  }
  // Every live type's OWN table (type_measured, one block per type, with its source).
  if (const TypeMeasurements* m = type_measured(topo))
    return type_table_diameter_mm(*m, rho, cell_size_mm, "lattice_strut_diameter_mm");
  // No default: a topology added to the enum without a block lands on this refusal
  // rather than on octet's table, which is the safe direction.
  throw LatticeDiameterLawNotMeasured(
      std::string("lattice_strut_diameter_mm: no measured diameter law for \"") +
      lattice_topology_name(topo) +
      "\" yet. Octet's measured table is NOT used for another type (R1): the "
      "density -> strut-diameter law has to be measured for this topology and "
      "landed in lattice.cpp before it can be generated or sized.");
}

double octet_relative_density(double cell_mm, double strut_radius_mm) {
  if (!(cell_mm > 0.0) || !std::isfinite(cell_mm))
    throw std::invalid_argument(
        "octet_relative_density: cell_mm must be finite and > 0");
  if (!(strut_radius_mm > 0.0) || !std::isfinite(strut_radius_mm))
    throw std::invalid_argument(
        "octet_relative_density: strut_radius_mm must be finite and > 0");

  // ★ OCTET MADE HONEST (ruling 2026-11-02 (c)): the SAME measurement as kOctetDia, read
  // the other way, exactly as every other type's lattice_density_from_strut is. This
  // used to voxelise the LEGS-ONLY cell at vpc48 (PR 198's basis), while the generator
  // lays the full octet; the two octet tables were then also not each other's inverse
  // (0.211733 against 0.218871 at strut/cell 0.20). Inside the table the inverse of its
  // linear interpolation makes the round trip exact; off it (a radius thinner than the
  // 0.05 row or fatter than the 0.90 one) it integrates the full cell's converged solid
  // fraction, the measurement the table was bisected on.
  const double d4 = 2.0 * strut_radius_mm * (kOctetDiaCellMm / cell_mm);
  const int n = static_cast<int>(kOctetDia.size());
  if (d4 >= kOctetDia[0].d_at_cell4_mm && d4 <= kOctetDia[n - 1].d_at_cell4_mm) {
    int a = 0;
    while (a + 1 < n - 1 && kOctetDia[a + 1].d_at_cell4_mm < d4) ++a;
    const DiaRow& r0 = kOctetDia[a];
    const DiaRow& r1 = kOctetDia[a + 1];
    const double t = (d4 - r0.d_at_cell4_mm) / (r1.d_at_cell4_mm - r0.d_at_cell4_mm);
    return r0.rho + t * (r1.rho - r0.rho);
  }
  const double rho = strut_cell_solid_fraction(lattice_strut_cell(LatticeTopology::Octet),
                                               strut_radius_mm / cell_mm);
  if (!(rho > 0.0) || rho >= 1.0)
    throw std::invalid_argument(
        "octet_relative_density: strut radius produced a degenerate cell "
        "(rho outside (0,1)) — check cell_mm / strut_radius_mm");
  return rho;
}


// ── ★ the measured error curve, and the adaptive floor computed from it ─────────
// (amendment to 2026-08-20-lattice-only-grading — AESTHETIC intent only.)
namespace {
struct CpmErrorPoint { double cells; double stiffness_error; };
// handoff 2026-07-28-graded-cell-size-phase0, C2b. Bending, "as deployed".
// VERBATIM — this IS the measurement, not a fit to it. If the running
// re-measurement moves these, they change HERE, in the one place.
constexpr CpmErrorPoint kCpmErrorCurve[] = {
    {1.0, 0.485}, {2.0, 0.085}, {3.0, 0.041}, {4.0, 0.0259}, {5.0, 0.0178}};
}  // namespace

double aesthetic_cells_per_member_hard_floor(LatticeTopology topo) {
  // No statement about the finish => the SAFE answer. Relaxing by omission is how a
  // caller that never thought about the boundary ends up shipping a bare 1-cell
  // member, which is the +1917 % case.
  return aesthetic_cells_per_member_hard_floor(topo, false);
}

double aesthetic_cells_per_member_hard_floor(LatticeTopology topo,
                                             bool boundary_finish_written) {
  // A measured type's own hard floor, with no finish relaxation (type_measured).
  if (const TypeMeasurements* m = type_measured(topo)) return m->aesthetic_hard_floor;
  return boundary_finish_written ? 1.0 : 2.0;
}

double lattice_member_floor_cells(LatticeTopology topo, bool aesthetic,
                                  bool single_cell_members, bool boundary_finish_written) {
  if (!aesthetic) return lattice_cells_per_member_min(topo);
  return aesthetic_cells_per_member_hard_floor(topo,
                                               single_cell_members && boundary_finish_written);
}

double aesthetic_cells_per_member_floor(LatticeTopology topo, double utilisation,
                                        double error_budget) {
  return aesthetic_cells_per_member_floor(topo, utilisation, error_budget, false);
}

double aesthetic_cells_per_member_floor(LatticeTopology topo, double utilisation,
                                        double error_budget,
                                        bool boundary_finish_written) {
  const double accuracy = lattice_cells_per_member_min(topo);
  // ★ ABSENCE OF MEASUREMENT IS NOT PERMISSION. An unusable utilisation keeps the
  // full accuracy floor rather than relaxing on a number nobody measured — the same
  // posture sub-floor retention takes when handed an all-zero demand field.
  if (!std::isfinite(utilisation) || utilisation < 0.0) return accuracy;
  if (!(error_budget > 0.0)) return accuracy;
  const double hard = aesthetic_cells_per_member_hard_floor(topo, boundary_finish_written);
  // A measured type reads ITS OWN bending curve; it has no skinned 1-cell row, and its
  // hard floor never admits one.
  if (const TypeMeasurements* m = type_measured(topo)) {
    for (int i = 0; i < m->ncurve; ++i) {
      const TypeCpmPoint& p = m->curve[i];
      if (p.cells < hard) continue;
      if (p.cells >= accuracy) break;
      if (p.stiffness_error * utilisation <= error_budget) return p.cells;
    }
    return accuracy;
  }
  for (const CpmErrorPoint& p : kCpmErrorCurve) {
    if (p.cells < hard) continue;          // never below the measured bending point
    if (p.cells >= accuracy) break;        // relaxing to the floor itself is a no-op
    // ★ THE 1-CELL ROW IS ONLY REACHABLE WITH A FINISH, AND IT IS READ FROM THE
    // SKINNED MEASUREMENT. `kCpmErrorCurve`'s 1-cell entry (+48.5 %) is the BARE
    // member, and bare is exactly the case a finish removes: skinned, that member
    // measures -67 to -87 %, i.e. the homogenized model UNDER-predicts its stiffness.
    // An under-predicting model is a lower bound on the truth, so the utilisation
    // budget — which exists to cap how far an OPTIMISTIC model may mislead — does not
    // bind on it. The budget is applied to the over-predicting rows only.
    if (p.cells < 2.0) {
      // ★ AND IT IS STILL BOUNDED, by the SAME threshold the rest of the codebase
      // uses for "this material carries nothing": kUnloadedUtilisationMax. The skinned
      // measurement is one topology, one density, one bending mode and one skin — the
      // conservative SIGN is what it establishes, not a licence at any load. A unit bar
      // caught this: without the bound a fully-utilised voxel reached one cell across
      // merely because a finish existed somewhere on the part.
      if (boundary_finish_written && utilisation <= kUnloadedUtilisationMax)
        return p.cells;
      continue;
    }
    // The perturbation this cell count introduces, weighted by what the material
    // ACTUALLY carries. Inside the budget => this many cells across is enough.
    if (p.stiffness_error * utilisation <= error_budget) return p.cells;
  }
  return accuracy;
}


double recommended_layer_height_mm(double min_strut_diameter_mm,
                                   double steepest_stacking_angle_deg,
                                   double line_width_mm) {
  if (!(min_strut_diameter_mm > 0.0) || !std::isfinite(min_strut_diameter_mm))
    return 0.0;
  // 1. resolve the THINNEST strut
  double h = min_strut_diameter_mm / kLayersAcrossStrut;
  // 2. the overhang step, when a stacking angle is known
  if (steepest_stacking_angle_deg > 0.0 && steepest_stacking_angle_deg < 90.0 &&
      line_width_mm > 0.0) {
    const double t = std::tan(steepest_stacking_angle_deg * M_PI / 180.0);
    if (t > 1e-9) h = std::min(h, kOverhangStepFraction * line_width_mm / t);
  }
  return h;
}

}  // namespace topopt
