#include "topopt/lattice.hpp"

#include <array>
#include <cmath>
#include <stdexcept>
#include <vector>

namespace topopt {

namespace {

// --- Octet unit-cell geometry (rho basis) ----------------------------------
// The octet strut segments of a UNIT cell (edge 1), copied operation-for-operation
// from PR 198's homogenization probe (lattice_homog_probe.cpp `octet_struts`): the
// 6 face-centre nodes each join the 4 cube corners of their face. This is the SAME
// geometry the tensor library rows were measured on, so voxelizing it recovers the
// library's rho scale exactly. Struts are cylinders of radius r (the point-segment
// distance field), matching `octet_dist2 < r*r`.
std::vector<std::array<std::array<double, 3>, 2>> octet_unit_struts() {
  std::vector<std::array<double, 3>> nodes;
  for (int z = 0; z <= 1; ++z)
    for (int y = 0; y <= 1; ++y)
      for (int x = 0; x <= 1; ++x)
        nodes.push_back({double(x), double(y), double(z)});
  const std::array<std::array<double, 3>, 6> fc = {{{0.5, 0.5, 0.0},
                                                    {0.5, 0.5, 1.0},
                                                    {0.5, 0.0, 0.5},
                                                    {0.5, 1.0, 0.5},
                                                    {0.0, 0.5, 0.5},
                                                    {1.0, 0.5, 0.5}}};
  std::vector<std::array<double, 3>> all(nodes);
  for (const auto& f : fc) all.push_back(f);
  std::vector<std::array<std::array<double, 3>, 2>> segs;
  for (std::size_t fi = 8; fi < all.size(); ++fi)
    for (std::size_t ci = 0; ci < 8; ++ci) {
      double d2 = 0.0;
      for (int k = 0; k < 3; ++k) {
        const double v = all[fi][k];
        if (v == 0.0 || v == 1.0) d2 += (all[ci][k] - v) * (all[ci][k] - v);
      }
      if (d2 < 1e-9) segs.push_back({all[fi], all[ci]});
    }
  return segs;
}

// Squared distance from unit-cell point (x,y,z) to the nearest strut segment.
double octet_point_dist2(
    double x, double y, double z,
    const std::vector<std::array<std::array<double, 3>, 2>>& segs) {
  double best = 1e30;
  for (const auto& s : segs) {
    const double ax = s[0][0], ay = s[0][1], az = s[0][2];
    const double bx = s[1][0], by = s[1][1], bz = s[1][2];
    const double ex = bx - ax, ey = by - ay, ez = bz - az;
    const double len2 = ex * ex + ey * ey + ez * ez;
    double t = 0.0;
    if (len2 > 0.0)
      t = ((x - ax) * ex + (y - ay) * ey + (z - az) * ez) / len2;
    if (t < 0.0) t = 0.0;
    if (t > 1.0) t = 1.0;
    const double dx = x - (ax + t * ex), dy = y - (ay + t * ey),
                 dz = z - (az + t * ez);
    const double d2 = dx * dx + dy * dy + dz * dz;
    if (d2 < best) best = d2;
  }
  return best;
}

// The solid modulus PR 198's library was measured at (materials.json PLA E).
// Effective stiffness is exactly linear in the solid modulus (linear elasticity),
// so a query at any Es scales these rows by Es / kLibraryEs.
constexpr double kLibraryEs = 3500.0;

struct Row {
  double rho, C11, C12, C44;  // MPa at Es = 3500
  bool resolved;              // wall >= 4 voxels at vpc48
};

// OCTET — the homogenized cubic tensor per MEASURED (voxelised) relative density
// (L=5 mm, Es=3500), ordered by rho. Three provenance bands:
//   MID  (0.148..0.591): PR 198's original library, vpc48. Reproduced bit-for-bit
//        (PR 234 validated 0.15..0.54 within +-2.4%). UNCHANGED here — these rows are
//        byte-identical to the shipped library (the B2 anchor test asserts it).
//   LOW  (0.050..0.119): PR 237, vpc128 converged truth (analyze_low.txt,
//        evidence/2026-07-28-density-band-extension). Extends the floor 0.148 -> 0.05.
//        vox/strut 11.4..18.6; resolution drift < 2.4%. Supersedes PR 198's single
//        under-resolved 0.103 row (dropped: it was excluded from every fit).
//   HIGH (0.615..0.900): PR 237, vpc48 validated vs vpc64 (high_end.csv); drift
//        < 2.4%. Replaces the old frozen clamp at 0.591 (which read up to -153% low).
// Every row here is resolved & validated (PR 237's verdict), so the interpolation
// range spans the full 0.050..0.900 band. Values transcribed VERBATIM from
// evidence/2026-07-28-density-band-extension/proposed_octet_rows.txt. This is the
// ONLY topology PR 237 re-measured; the eight tables below keep their own bands.
constexpr std::array<Row, 19> kOctet = {{
    // --- LOW rows (PR 237, vpc128; floor 0.148 -> 0.05) ---
    {0.05047, 37.0649, 18.3510, 16.8552, true},
    {0.06355, 48.3025, 23.7203, 21.6214, true},
    {0.08109, 64.4784, 31.2998, 28.2686, true},
    {0.09882, 81.7907, 39.2954, 35.2762, true},
    {0.11908, 102.9136, 48.7092, 43.5388, true},
    // --- MID rows (PR 198, vpc48; UNCHANGED) ---
    {0.14764, 136.9621, 64.0645, 56.6726, true},
    {0.20414, 213.7779, 94.5363, 83.3612, true},
    {0.25297, 295.1031, 124.0143, 109.1889, true},
    {0.29731, 374.2029, 151.9733, 135.0535, true},
    {0.39786, 611.4884, 226.3148, 204.0181, true},
    {0.50644, 974.8665, 328.8413, 297.3223, true},
    {0.59093, 1344.7034, 443.6894, 392.1883, true},
    // --- HIGH rows (PR 237, vpc48 validated vs vpc64; clamp 0.591 -> 0.90) ---
    {0.61509, 1464.0552, 485.7181, 423.7420, true},
    {0.65502, 1677.7877, 562.6095, 480.4917, true},
    {0.69871, 1975.2811, 676.0779, 550.7189, true},
    {0.75210, 2351.3476, 842.3622, 650.7516, true},
    {0.79753, 2720.7120, 1018.8917, 743.9973, true},
    {0.85120, 3276.6604, 1312.7907, 878.5398, true},
    {0.89988, 3832.0119, 1640.8200, 1011.6316, true},
}};

// ─── the nine-topology extension (handoff 2026-07-29-tensor-library-nine) ───────
// Measured by tensor_library_nine_probe.cpp: the SAME periodic homogenization PR 198
// used, run over the strut-lattice family table. vpc48 row (the library basis, like
// kOctet), converged against vpc64 (matched rho, clean interpolated drift metric).
// A row is `resolved` when it sits in the CONTIGUOUS validated block (drift < 2.4% vs
// vpc64 AND strut diameter >= 6 voxels); rows outside are kept for provenance. Only
// the CUBIC-symmetric topologies are here — the three tetragonal variants (bccz/fccz/
// reentrant) get NO table (rows_of returns empty) and are refused by lattice_cubic_
// tensor (bar B3). NOTE: kFcc is geometrically the legs-only octet, so its rows match
// kOctet where the density sampling coincides (rho 0.297, 0.591 are byte-identical) —
// the live proof this driver reproduces the shipped octet. See the handoff for the
// shipped-"octet"-is-legs-only finding.

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
                            LatticeTopology::Fccz, LatticeTopology::Reentrant})
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

double lattice_cells_per_member_min(LatticeTopology topo) {
  // MEASURED for octet (bending ceiling, handoff 2026-07-28-graded-cell-size-phase0
  // C2b): the 2.4% band is crossed between 4 and 5 cells across, so 5. For the other
  // certifiable topologies the bending floor is NOT independently measured here — that
  // needs the PR 235 guided-cantilever finite-block study (handoff
  // 2026-07-29-tensor-library-nine, T4). octet's 5 is forwarded as a documented
  // placeholder; it is representative for the stretch-dominated lattices (fcc, rhombic)
  // and is expected to be an UNDER-estimate for the bending-dominated ones (bcc, kelvin,
  // diamond, sc), so re-measure before grading those. It is load-bearing only for the
  // grading law, which is octet-only in production — no other topology is graded against
  // it today. Change the number HERE, per topology, once measured.
  (void)topo;
  return 5.0;
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

// The printed octet strut DIAMETER at cell edge 4 mm, per relative density, measured
// at vpc48 — evidence/2026-07-28-graded-cell-size-phase0/b3_printability.csv, column
// d_mm_cell4, VERBATIM. Diameter is exactly linear in cell size (that CSV's cell8/16/
// 32 columns are 2/4/8x these to four digits), so a query at any cell scales by
// cell/4. Ordered by rho; the span (0.05..0.60) brackets the certifiable band.
struct DiaRow { double rho, d_at_cell4_mm; };
constexpr double kOctetDiaCellMm = 4.0;
constexpr std::array<DiaRow, 8> kOctetDia = {{
    {0.05, 0.3632},
    {0.08, 0.4787},
    {0.10, 0.5336},
    {0.15, 0.6401},
    {0.20, 0.7592},
    {0.30, 0.9754},
    {0.40, 1.1815},
    {0.60, 1.5343},
}};

}  // namespace

double octet_strut_diameter_mm(double rho, double cell_size_mm) {
  if (!(cell_size_mm > 0.0))
    throw std::invalid_argument(
        "octet_strut_diameter_mm: cell_size_mm must be > 0");
  if (!(std::isfinite(rho) && rho >= 0.0))
    throw std::invalid_argument(
        "octet_strut_diameter_mm: rho must be finite and >= 0");

  const std::array<DiaRow, 8>& rows = kOctetDia;
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

double lattice_cell_printability_floor_mm(LatticeTopology topo,
                                          double min_extrudable_width_mm) {
  if (!(std::isfinite(min_extrudable_width_mm) && min_extrudable_width_mm > 0.0))
    throw std::invalid_argument(
        "lattice_cell_printability_floor_mm: min_extrudable_width_mm must be "
        "finite and > 0");
  // The thinnest strut at any cell size occurs at the band's LOW end (diameter is
  // monotone in rho), and diameter is exactly linear in cell size, so the floor is
  // the stated width divided by the diameter at a UNIT cell.
  const double phi_lo = octet_strut_diameter_mm(lattice_rho_min(topo), 1.0);
  return min_extrudable_width_mm / phi_lo;
}

double lattice_min_density_for_strut(LatticeTopology topo, double cell_size_mm,
                                     double min_extrudable_width_mm) {
  if (!(cell_size_mm > 0.0))
    throw std::invalid_argument(
        "lattice_min_density_for_strut: cell_size_mm must be > 0");
  if (!(std::isfinite(min_extrudable_width_mm) && min_extrudable_width_mm > 0.0))
    throw std::invalid_argument(
        "lattice_min_density_for_strut: min_extrudable_width_mm must be finite "
        "and > 0");
  const double rho_lo = lattice_rho_min(topo);
  const double rho_hi = lattice_rho_max(topo);
  if (!(rho_hi > 0.0))
    throw std::invalid_argument(
        "lattice_min_density_for_strut: topology has no certifiable band");

  // The band floor already prints — nothing lighter is admissible anyway.
  if (octet_strut_diameter_mm(rho_lo, cell_size_mm) >= min_extrudable_width_mm)
    return rho_lo;
  // Not even the band ceiling prints at this cell — there is no in-band answer, and
  // returning the ceiling would be a silent lie about a strut that comes out under
  // one bead. The contract is a negative sentinel the caller must test.
  if (octet_strut_diameter_mm(rho_hi, cell_size_mm) < min_extrudable_width_mm)
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
    if (octet_strut_diameter_mm(mid, cell_size_mm) >= min_extrudable_width_mm)
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
    double min_extrudable_width_mm, double cells_per_member_floor) {
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

  // The two bounds. phi is monotone in rho, so the band's top gives the smallest
  // printable cell; N* against the measured width gives the largest homogenizable one.
  const double phi_hi = octet_strut_diameter_mm(d.band_rho_max, 1.0);
  d.min_printable_cell_mm = min_extrudable_width_mm / phi_hi;
  d.min_member_width_mm = d.cells_per_member_floor * d.min_printable_cell_mm;
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
      octet_strut_diameter_mm(d.densest_relative_density, d.densest_cell_size_mm);
  d.densest_cells_per_member = member_width_mm / d.densest_cell_size_mm;

  // ── COARSEST end: exactly N* cells across, at the lightest density that still
  // prints there — the MINIMUM-MASS certified lattice for this member. On an +inf
  // member width there is no upper bound, so both ends coincide at the frontier.
  if (std::isfinite(d.max_homogenizable_cell_mm)) {
    d.lightest_cell_size_mm = d.max_homogenizable_cell_mm;
    d.lightest_relative_density = lightest_or_ceiling(d.lightest_cell_size_mm);
    d.lightest_strut_diameter_mm = octet_strut_diameter_mm(
        d.lightest_relative_density, d.lightest_cell_size_mm);
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

double octet_relative_density(double cell_mm, double strut_radius_mm) {
  if (!(cell_mm > 0.0) || !std::isfinite(cell_mm))
    throw std::invalid_argument(
        "octet_relative_density: cell_mm must be finite and > 0");
  if (!(strut_radius_mm > 0.0) || !std::isfinite(strut_radius_mm))
    throw std::invalid_argument(
        "octet_relative_density: strut_radius_mm must be finite and > 0");

  // Voxelize ONE cell on the library's basis (vpc48). The field depends only on
  // the ratio r/L (a unit cell with unit-cell radius), so cell_mm cancels and the
  // result is cell-size invariant — the whole reason a homogenized cell adds no DOF.
  const double r_unit = strut_radius_mm / cell_mm;
  const auto segs = octet_unit_struts();
  const int vpc = kLatticeLibraryVpc;
  const double r2 = r_unit * r_unit;
  long long solid = 0;
  const long long total = static_cast<long long>(vpc) * vpc * vpc;
  for (int k = 0; k < vpc; ++k)
    for (int j = 0; j < vpc; ++j)
      for (int i = 0; i < vpc; ++i) {
        // Voxel centre in unit-cell coordinates (matches build_lattice's
        // voxel_center on a cell of edge 1).
        const double x = (i + 0.5) / vpc;
        const double y = (j + 0.5) / vpc;
        const double z = (k + 0.5) / vpc;
        if (octet_point_dist2(x, y, z, segs) < r2) ++solid;
      }
  const double rho = static_cast<double>(solid) / static_cast<double>(total);
  if (!(rho > 0.0) || rho >= 1.0)
    throw std::invalid_argument(
        "octet_relative_density: strut radius produced a degenerate cell "
        "(rho outside (0,1)) — check cell_mm / strut_radius_mm");
  return rho;
}

}  // namespace topopt
