// lattice_types_probe.cpp — the per-type measurements a strut type needs before it goes
// live (lattice types round 1: docs/design/lattice-types/02-core-spec.md §2.2-§2.4).
// MEASUREMENT ONLY: not a CI test; it writes CSVs, the numbers are landed by hand in
// lattice.cpp with this file named as their source.
//
// THE THESIS: every number here is a REPEAT of a measurement already made for octet, on
// the type's own canonical cell (topopt/strut_cell.hpp — the cell test_strut_cell
// proves equal to the tensor probe's). Nothing is new method:
//
//   law   <id>  the density -> strut-diameter table over rho 0.05..0.60, diameter at a
//               4 mm cell. Measured TWO ways, both reported: PR 235's B3 way (bisect r on
//               the cell voxelised at vpc48, 34 steps) and on the CONVERGED solid
//               fraction (strut_cell_solid_fraction: 2^20 Halton samples, 50 steps). The
//               converged one is the law core lands: vpc48 is a lattice-aligned staircase
//               (law_resolution.txt). Also the low-density K(r/L)^2 check, and the
//               AS-BUILT solid fraction of the production solids (8-gon prisms +
//               icosahedral nodes, same Halton samples) at the landed radius — the
//               "n-gon prism versus cylinder" gap the spec asks to report.
//   bend  <id>  PR 235's C2b guided cantilever, verbatim in method (transverse_K is
//               copied from graded_cell_size_probe.cpp): resolved struts vs a
//               homogenised macro beam (one cubic element per cell, the periodic tensor
//               of the SAME cell at the SAME vpc), nc x nc cells across, 6 cells long.
//   perc  <id>  connected components of a member 0.5 / 0.75 / 1 / 1.5 / 2 cells across
//               at the band's low, middle and high rho, at several placements of the
//               member window against the lattice (6-connected voxels, vpc16, 4 cells
//               long). Percolates = a component touching BOTH ends exists at EVERY
//               placement (the member carries load end to end). The window also cuts
//               struts into slivers that join nothing inside it; that DEBRIS is
//               reported separately as the solid outside the largest component, because
//               it appears at every width (it is the clip's, not the lattice's) and a
//               one-component rule would call a 2-cell member unconnected for it.
//   spans <SPANS.txt> [<SOLID.stl> <part.stl> <shell_mm>]
//               go-live item 7 on a REAL run: read a run's <prefix>_SPANS.txt (every
//               emitted primitive, written by lattice.emit_organic_spans +
//               emit_welded_stl) and count its solid-overlap components the same way
//               `step` does. On a part whose lattice regions are pockets joined through
//               solid, many components is normal; the failure is a FLOATING one: no cut
//               end (the clip stops a strut on the allowed region's surface), no end
//               inside or within r + 0.05 mm of the solid companion, and none within the
//               shell wall + r of the part surface.
//   step  <id>  R4's size-step connectivity on the PRODUCTION generator: a Doubled
//               (S | S/2) block and one Stepped (S | 2S/3) interface. Every emitted
//               primitive is tapped by the observer; components are counted by solid
//               OVERLAP (two primitives join when their axes come within the sum of
//               their INSCRIBED radii), and a strut end is DANGLING when no other
//               primitive's inscribed solid covers it.
//
// Build (from core/, after the library):
//   c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
//       tests/harness/lattice_types_probe.cpp build/libtopopt.a -o build/lattice_types_probe
// CSVs land in TOPOPT_LATTICE_CSV_DIR.

#define main tensor_library_nine_probe_main
#include "tensor_library_nine_probe.cpp"
#undef main

#include <map>
#include <numeric>

#include "topopt/lattice_gen.hpp"
#include "topopt/mesh_distance.hpp"
#include "topopt/stl.hpp"
#include "topopt/strut_cell.hpp"

namespace {

using topopt::LatticeTopology;
using topopt::StrutCell;

LatticeTopology topo_of(const std::string& id) { return topopt::lattice_topology_from_id(id); }

// ------------------------------------------------------------------ geometry
// Unit-cell segments of the infinite tiling that can reach [0,1]^3 within `reach`.
struct USeg { double a[3], b[3]; };
std::vector<USeg> tiling_segs(const StrutCell& c, double reach) {
  std::vector<USeg> out;
  const double inv = 1.0 / c.S;
  for (const auto& s : c.struts)
    for (int dz = -1; dz <= 1; ++dz)
      for (int dy = -1; dy <= 1; ++dy)
        for (int dx = -1; dx <= 1; ++dx) {
          USeg u{{s.a.x * inv + dx, s.a.y * inv + dy, s.a.z * inv + dz},
                 {s.b.x * inv + dx, s.b.y * inv + dy, s.b.z * inv + dz}};
          bool far = false;
          for (int k = 0; k < 3; ++k)
            if (std::max(u.a[k], u.b[k]) < -reach || std::min(u.a[k], u.b[k]) > 1 + reach)
              far = true;
          if (!far) out.push_back(u);
        }
  return out;
}
double seg_d2(const double p[3], const USeg& s) {
  double e[3] = {s.b[0] - s.a[0], s.b[1] - s.a[1], s.b[2] - s.a[2]};
  double l2 = e[0] * e[0] + e[1] * e[1] + e[2] * e[2];
  double t = l2 > 0 ? ((p[0] - s.a[0]) * e[0] + (p[1] - s.a[1]) * e[1] + (p[2] - s.a[2]) * e[2]) / l2 : 0;
  t = t < 0 ? 0 : (t > 1 ? 1 : t);
  double d[3] = {p[0] - s.a[0] - t * e[0], p[1] - s.a[1] - t * e[1], p[2] - s.a[2] - t * e[2]};
  return d[0] * d[0] + d[1] * d[1] + d[2] * d[2];
}
// Is a point (model mm) inside the tiling's capsule solid of cell L, radius r (mm),
// lattice anchored at the origin?
bool tiling_solid(const std::vector<USeg>& segs, double L, double r, double x, double y,
                  double z) {
  auto frac = [](double v) { double f = v - std::floor(v); return f; };
  const double p[3] = {frac(x / L), frac(y / L), frac(z / L)};
  const double r2 = (r / L) * (r / L);
  for (const USeg& s : segs)
    if (seg_d2(p, s) < r2) return true;
  return false;
}
// A block of ncx x ncy x ncz cells, origin at 0 (cubic voxels h = L/vpc).
VoxelGrid build_block(const StrutCell& c, double L, double r, int ncx, int ncy, int ncz,
                      int vpc, double ox = 0.0, double oy = 0.0) {
  VoxelGrid g;
  g.nx = ncx * vpc; g.ny = ncy * vpc; g.nz = ncz * vpc;
  g.spacing = L / vpc; g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(g.nx) * g.ny * g.nz, VoxelTag::Empty);
  const auto segs = tiling_segs(c, r / L + 1e-9);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        Vec3 q = g.voxel_center(i, j, k);
        if (tiling_solid(segs, L, r, q.x + ox, q.y + oy, q.z))
          g.set_tag(i, j, k, VoxelTag::Interior);
      }
  return g;
}
double calibrate_converged(const StrutCell& c, double target) {
  double lo = 0.0005, hi = 0.45;
  for (int it = 0; it < 50; ++it) {
    const double mid = 0.5 * (lo + hi);
    (topopt::strut_cell_solid_fraction(c, mid) < target ? lo : hi) = mid;
  }
  return 0.5 * (lo + hi);
}
double calibrate(const StrutCell& c, double target, int vpc) {
  double lo = 0.0005, hi = 0.45;
  for (int it = 0; it < 34; ++it) {
    const double mid = 0.5 * (lo + hi);
    (topopt::strut_cell_voxel_density(c, mid, vpc) < target ? lo : hi) = mid;
  }
  return 0.5 * (lo + hi);
}

// ------------------------------------------------------- the production solids
// lattice_emit_strut's 8-gon prism and lattice_emit_node's icosahedron, as inside tests
// (the same frame construction, so the facets are where the emitter puts them).
struct Prism { double p0[3], ax[3], u[3], v[3], len, r; int n; };
Prism make_prism(const double a[3], const double b[3], double r, int n) {
  Prism P;
  double d[3] = {b[0] - a[0], b[1] - a[1], b[2] - a[2]};
  P.len = std::sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
  for (int k = 0; k < 3; ++k) { P.p0[k] = a[k]; P.ax[k] = d[k] / P.len; }
  double ref[3] = {0, 0, 1};
  if (!(std::fabs(P.ax[2]) < 0.9)) { ref[0] = 1; ref[2] = 0; }
  double u[3] = {P.ax[1] * ref[2] - P.ax[2] * ref[1], P.ax[2] * ref[0] - P.ax[0] * ref[2],
                 P.ax[0] * ref[1] - P.ax[1] * ref[0]};
  double un = std::sqrt(u[0] * u[0] + u[1] * u[1] + u[2] * u[2]);
  for (int k = 0; k < 3; ++k) P.u[k] = u[k] / un;
  P.v[0] = P.ax[1] * P.u[2] - P.ax[2] * P.u[1];
  P.v[1] = P.ax[2] * P.u[0] - P.ax[0] * P.u[2];
  P.v[2] = P.ax[0] * P.u[1] - P.ax[1] * P.u[0];
  P.r = r; P.n = n;
  return P;
}
bool in_prism(const Prism& P, const double q[3]) {
  double w[3] = {q[0] - P.p0[0], q[1] - P.p0[1], q[2] - P.p0[2]};
  const double t = w[0] * P.ax[0] + w[1] * P.ax[1] + w[2] * P.ax[2];
  if (t < 0 || t > P.len) return false;
  const double wu = w[0] * P.u[0] + w[1] * P.u[1] + w[2] * P.u[2];
  const double wv = w[0] * P.v[0] + w[1] * P.v[1] + w[2] * P.v[2];
  const double apo = P.r * std::cos(M_PI / P.n);
  for (int i = 0; i < P.n; ++i) {
    const double th = 2.0 * M_PI * (i + 0.5) / P.n;  // edge normal between vertices i, i+1
    if (wu * std::cos(th) + wv * std::sin(th) > apo) return false;
  }
  return true;
}
// Icosahedron of circumradius r: inside iff within every face plane (inradius ratio).
const std::vector<std::array<double, 3>>& ico_normals() {
  static const std::vector<std::array<double, 3>> N = [] {
    const double t = (1.0 + std::sqrt(5.0)) / 2.0;
    const double V[12][3] = {{-1, t, 0}, {1, t, 0}, {-1, -t, 0}, {1, -t, 0},
                             {0, -1, t}, {0, 1, t}, {0, -1, -t}, {0, 1, -t},
                             {t, 0, -1}, {t, 0, 1}, {-t, 0, -1}, {-t, 0, 1}};
    const int F[20][3] = {{0, 11, 5}, {0, 5, 1}, {0, 1, 7}, {0, 7, 10}, {0, 10, 11},
                          {1, 5, 9},  {5, 11, 4}, {11, 10, 2}, {10, 7, 6}, {7, 1, 8},
                          {3, 9, 4},  {3, 4, 2},  {3, 2, 6},  {3, 6, 8},  {3, 8, 9},
                          {4, 9, 5},  {2, 4, 11}, {6, 2, 10}, {8, 6, 7},  {9, 8, 1}};
    std::vector<std::array<double, 3>> out;
    for (auto& f : F) {
      double c[3] = {0, 0, 0};
      for (int k = 0; k < 3; ++k)
        for (int j = 0; j < 3; ++j) c[j] += V[f[k]][j] / 3.0;
      double n = std::sqrt(c[0] * c[0] + c[1] * c[1] + c[2] * c[2]);
      out.push_back({c[0] / n, c[1] / n, c[2] / n});
    }
    return out;
  }();
  return N;
}
constexpr double kIcoInOverCirc = 0.7946544722917661;
bool in_ico(const double c[3], double r, const double q[3]) {
  const double w[3] = {q[0] - c[0], q[1] - c[1], q[2] - c[2]};
  for (const auto& n : ico_normals())
    if (w[0] * n[0] + w[1] * n[1] + w[2] * n[2] > r * kIcoInOverCirc) return false;
  return true;
}
double halton_q(unsigned i, unsigned base) {
  double f = 1.0, r = 0.0;
  while (i > 0) { f /= base; r += f * (i % base); i /= base; }
  return r;
}
// The as-built solid fraction of the production solids on the periodic cell (unit
// coords), on the SAME Halton samples strut_cell_solid_fraction uses.
double asbuilt_density(const StrutCell& c, double r_unit, int samples) {
  std::vector<Prism> prisms;
  const double inv = 1.0 / c.S;
  for (const auto& s : c.struts)
    for (int dz = -1; dz <= 1; ++dz)
      for (int dy = -1; dy <= 1; ++dy)
        for (int dx = -1; dx <= 1; ++dx) {
          double a[3] = {s.a.x * inv + dx, s.a.y * inv + dy, s.a.z * inv + dz};
          double b[3] = {s.b.x * inv + dx, s.b.y * inv + dy, s.b.z * inv + dz};
          prisms.push_back(make_prism(a, b, r_unit, 8));
        }
  std::vector<std::array<double, 3>> nodes;
  for (const auto& n : c.nodes)
    for (int dz = -1; dz <= 1; ++dz)
      for (int dy = -1; dy <= 1; ++dy)
        for (int dx = -1; dx <= 1; ++dx)
          nodes.push_back({n.x * inv + dx, n.y * inv + dy, n.z * inv + dz});
  long long solid = 0;
  for (int n = 1; n <= samples; ++n) {
    const double q[3] = {halton_q(n, 2), halton_q(n, 3), halton_q(n, 5)};
    bool in = false;
    for (const auto& P : prisms) if (in_prism(P, q)) { in = true; break; }
    if (!in) for (const auto& nd : nodes) if (in_ico(nd.data(), r_unit, q)) { in = true; break; }
    if (in) ++solid;
  }
  return double(solid) / samples;
}

// ===================================================================== law
double low_density_K(LatticeTopology t) {
  // evidence/2026-07-27-strut-lattice-family/density.txt, K in rho ~= K (r/L)^2.
  switch (t) {
    case LatticeTopology::SimpleCubic: return 8.4853;
    case LatticeTopology::Bcc: return 19.5959;
    case LatticeTopology::Fcc: return 24.0;
    case LatticeTopology::Diamond: return 19.5959;
    case LatticeTopology::Kelvin: return 24.0;
    case LatticeTopology::Rhombic: return 39.1918;
    case LatticeTopology::Octet: return 48.0;
    default: return 0;
  }
}
int mode_law(const std::string& id) {
  const LatticeTopology t = topo_of(id);
  const StrutCell& c = topopt::lattice_strut_cell(t);
  const int vpc = 48;
  const int nsamp = 1 << 20;
  const std::vector<double> rhos = env_doubles("TOPOPT_LT_RHOS",
                                               {0.05, 0.08, 0.10, 0.15, 0.20, 0.30, 0.40, 0.60});
  std::printf("LAW %s: S=%d, %zu struts/cell. CONVERGED = 50-step bisection on the solid "
              "fraction (2^20 Halton samples) -> the landed table; B3 = 34-step bisection on "
              "the vpc48 voxel density (octet's method), for comparison\n", id.c_str(), c.S,
              c.struts.size());
  FILE* csv = csv_open(id + "_law.csv");
  if (csv) std::fprintf(csv, "rho_target,r_over_L,rho_converged,d_mm_cell4,b3_r_over_L,b3_rho_vpc48,"
                             "b3_d_mm_cell4,b3_vs_converged_d_pct,K_check_rho,K_gap_pct,asbuilt_rho,"
                             "asbuilt_gap_pct,vox_per_strut_vpc48\n");
  std::printf("  %-6s %-9s %-9s %-8s | %-8s %-9s %-7s | %-9s %-7s | %-9s %-7s\n", "rho", "r/L",
              "rho", "d@4mm", "B3 d", "B3 rho48", "B3 gap", "K-rho", "K gap", "as-built", "gap");
  for (double rho : rhos) {
    const double r = calibrate_converged(c, rho);
    const double got = topopt::strut_cell_solid_fraction(c, r, nsamp);
    const double rb = calibrate(c, rho, vpc);
    const double gotb = topopt::strut_cell_voxel_density(c, rb, vpc);
    const double kr = low_density_K(t) * r * r;
    const double ab = asbuilt_density(c, r, nsamp);
    const double d4 = 2 * r * 4, db = 2 * rb * 4;
    std::printf("  %-6.2f %-9.6f %-9.5f %-8.4f | %-8.4f %-9.5f %+-7.2f | %-9.5f %+-7.2f | %-9.5f %+-7.2f\n",
                rho, r, got, d4, db, gotb, 100 * (db / d4 - 1), kr, 100 * (kr - got) / got, ab,
                100 * (ab - got) / got);
    if (csv) std::fprintf(csv, "%.2f,%.8f,%.6f,%.4f,%.8f,%.6f,%.4f,%.3f,%.6f,%.3f,%.6f,%.3f,%.2f\n",
                          rho, r, got, d4, rb, gotb, db, 100 * (db / d4 - 1), kr,
                          100 * (kr - got) / got, ab, 100 * (ab - got) / got, 2 * r * vpc);
  }
  if (csv) std::fclose(csv);
  return 0;
}

// ===================================================================== bend
#include "lattice_types_probe_shared.inc"

int mode_bend(const std::string& id) {
  const LatticeTopology t = topo_of(id);
  const StrutCell& c = topopt::lattice_strut_cell(t);
  const int vpc = env_ints("TOPOPT_LT_BEND_VPC", {12})[0];
  const double S = 5.0;
  const double tvf = env_doubles("TOPOPT_LT_BEND_VF", {0.30})[0];
  const int Lb = 6;
  const std::vector<int> ncs = env_ints("TOPOPT_LT_BEND_NC", {1, 2, 3, 4, 5, 6});
  const double r_unit = calibrate(c, tvf, vpc);
  const double r = r_unit * S;
  const VoxelGrid cell = build_block(c, S, r, 1, 1, 1, vpc);
  const double rho_cell = volume_fraction(cell);
  const Cubic pt = cubic_of(homogenize(cell, {0, 1, 2, 3, 4, 5}, 1e-9));
  std::printf("BEND %s: cell S=%.1f mm, vpc=%d, cantilever %d cells long, target rho %.2f -> "
              "periodic cell rho %.4f (r/L %.5f, %.1f vox/strut), C11=%.2f C12=%.2f C44=%.2f "
              "Zener=%.3f\n", id.c_str(), S, vpc, Lb, tvf, rho_cell, r_unit, 2 * r_unit * vpc,
              pt.C11, pt.C12, pt.C44, pt.zener);
  FILE* csv = csv_open(id + "_bend.csv");
  if (csv) std::fprintf(csv, "cells_across,cell_rho,block_rho,K_resolved,K_homog_macro,bend_err_pct,"
                             "resolved_dof,resolved_ms,verdict\n");
  for (int nc : ncs) {
    const VoxelGrid g = build_block(c, S, r, nc, nc, Lb, vpc);
    const double rho = volume_fraction(g);
    std::vector<double> ey(g.voxel_count(), 0.0);
    for (std::size_t e = 0; e < g.voxel_count(); ++e) if (g.tags[e] != VoxelTag::Empty) ey[e] = kE;
    double msR = 0; long ndR = 0;
    const double Kres = transverse_K(g, ey, {}, {}, {}, {}, false, &msR, &ndR);
    const VoxelGrid mg = macro_grid(S, nc, nc, Lb);
    std::vector<double> mey(mg.voxel_count(), kE);
    std::vector<char> mask(mg.voxel_count(), 1);
    std::vector<double> mc11(mg.voxel_count(), pt.C11), mc12(mg.voxel_count(), pt.C12),
        mc44(mg.voxel_count(), pt.C44);
    const double Khom = transverse_K(mg, mey, mask, mc11, mc12, mc44, true);
    const double err = (Kres > 0 && Khom > 0) ? 100.0 * (Khom - Kres) / Kres : NAN;
    const bool go = std::isfinite(err) && std::fabs(err) <= 2.4;
    const char* v = Kres <= 0 ? "SOLVE-FAIL" : (go ? "GO" : "NO-GO");
    std::printf("    nc=%d  block rho %.4f  K_res %.4f  K_hom %.4f  err %+.2f %%  dof %ld  %.0f ms  %s\n",
                nc, rho, Kres, Khom, err, ndR, msR, v);
    if (csv) std::fprintf(csv, "%d,%.4f,%.4f,%.4f,%.4f,%.2f,%ld,%.0f,%s\n", nc, rho_cell, rho, Kres,
                          Khom, err, ndR, msR, v);
    if (csv) std::fflush(csv);
  }
  if (csv) std::fclose(csv);
  return 0;
}

// ===================================================================== perc
int mode_perc(const std::string& id) {
  const LatticeTopology t = topo_of(id);
  const StrutCell& c = topopt::lattice_strut_cell(t);
  const int vpc = 16;
  const double S = 5.0;
  const int m_long = 4;
  const double lo = topopt::lattice_rho_min(t), hi = topopt::lattice_rho_max(t);
  const std::vector<double> rhos = {lo, 0.5 * (lo + hi), hi};
  const std::vector<double> cpm = env_doubles("TOPOPT_LT_PERC_CPM", {0.5, 0.75, 1.0, 1.5, 2.0});
  const std::vector<double> offs = {0.0, 0.25, 0.5, 0.75};  // window placement, in cells
  std::printf("PERC %s: vpc%d, S=%.0f mm, %d cells long, 6-connected, placements x=y in "
              "{0, .25, .5, .75} cell; band [%.4f, %.4f]\n", id.c_str(), vpc, S, m_long, lo, hi);
  FILE* csv = csv_open(id + "_perc.csv");
  if (csv) std::fprintf(csv, "rho,cells_across,offset_cells,components,spanning,largest_frac,percolates\n");
  for (double rho : rhos) {
    const double r = calibrate_converged(c, rho) * S;  // the landed law's radius
    for (double nc : cpm) {
      bool all = true;
      std::string line;
      for (double off : offs) {
        // A member nc cells across, m_long long, its window shifted by `off` cells.
        VoxelGrid g;
        const double h = S / vpc;
        g.nx = g.ny = std::max(1, int(std::lround(nc * S / h)));
        g.nz = m_long * vpc;
        g.spacing = h; g.origin = Vec3{0, 0, 0};
        g.tags.assign(std::size_t(g.nx) * g.ny * g.nz, VoxelTag::Empty);
        const auto segs = tiling_segs(c, r / S + 1e-9);
        for (int k = 0; k < g.nz; ++k)
          for (int j = 0; j < g.ny; ++j)
            for (int i = 0; i < g.nx; ++i) {
              Vec3 q = g.voxel_center(i, j, k);
              if (tiling_solid(segs, S, r, q.x + off * S, q.y + off * S, q.z))
                g.set_tag(i, j, k, VoxelTag::Interior);
            }
        const Comp cp = components(g);
        const bool ok = cp.spanning;
        all = all && ok;
        const double debris = cp.solid ? 1.0 - double(cp.largest) / cp.solid : 0.0;
        char buf[80];
        std::snprintf(buf, sizeof buf, " off%.2f:%d%s(debris %.1f%%)", off, cp.n,
                      cp.spanning ? "" : " NOT SPANNING", 100 * debris);
        line += buf;
        if (csv) std::fprintf(csv, "%.4f,%.2f,%.2f,%d,%d,%.4f,%d\n", rho, nc, off, cp.n,
                              cp.spanning ? 1 : 0, cp.solid ? double(cp.largest) / cp.solid : 0.0,
                              ok ? 1 : 0);
      }
      std::printf("  rho %.4f  %.2f cells: %s |%s\n", rho, nc, all ? "PERCOLATES" : "no", line.c_str());
    }
  }
  if (csv) std::fclose(csv);
  return 0;
}

// ===================================================================== step
struct Prim { bool ball; double a[3], b[3], r; };
struct DSU {
  std::vector<int> p;
  explicit DSU(std::size_t n) : p(n) { std::iota(p.begin(), p.end(), 0); }
  int f(int x) { while (p[x] != x) x = p[x] = p[p[x]]; return x; }
  void u(int a, int b) { a = f(a); b = f(b); if (a != b) p[std::max(a, b)] = std::min(a, b); }
};
double seg_seg_dist(const double p1[3], const double q1[3], const double p2[3], const double q2[3]) {
  // Ericson, Real-Time Collision Detection 5.1.9 (closest points of two segments).
  double d1[3], d2[3], r[3];
  for (int k = 0; k < 3; ++k) { d1[k] = q1[k] - p1[k]; d2[k] = q2[k] - p2[k]; r[k] = p1[k] - p2[k]; }
  auto dot = [](const double* x, const double* y) { return x[0] * y[0] + x[1] * y[1] + x[2] * y[2]; };
  const double a = dot(d1, d1), e = dot(d2, d2), f = dot(d2, r);
  double s, t;
  if (a <= 1e-18 && e <= 1e-18) { s = t = 0; }
  else if (a <= 1e-18) { s = 0; t = std::clamp(f / e, 0.0, 1.0); }
  else {
    const double c = dot(d1, r);
    if (e <= 1e-18) { t = 0; s = std::clamp(-c / a, 0.0, 1.0); }
    else {
      const double b = dot(d1, d2), den = a * e - b * b;
      s = den != 0 ? std::clamp((b * f - c * e) / den, 0.0, 1.0) : 0.0;
      t = (b * s + f) / e;
      if (t < 0) { t = 0; s = std::clamp(-c / a, 0.0, 1.0); }
      else if (t > 1) { t = 1; s = std::clamp((b - c) / a, 0.0, 1.0); }
    }
  }
  double d = 0;
  for (int k = 0; k < 3; ++k) { const double x = p1[k] + d1[k] * s - (p2[k] + d2[k] * t); d += x * x; }
  return std::sqrt(d);
}
double inscribed(const Prim& p) { return p.ball ? p.r * kIcoInOverCirc : p.r * std::cos(M_PI / 8); }
struct Conn { std::size_t prims = 0; int components = 0; long dangling = 0; long ends = 0; };
Conn connectivity(const std::vector<Prim>& P) {
  Conn out;
  out.prims = P.size();
  // spatial hash on primitive bounding boxes
  double rmax = 0, lmax = 0;
  for (const auto& p : P) {
    rmax = std::max(rmax, p.r);
    double l = 0;
    for (int k = 0; k < 3; ++k) l += (p.b[k] - p.a[k]) * (p.b[k] - p.a[k]);
    lmax = std::max(lmax, std::sqrt(l));
  }
  const double h = std::max(1e-6, lmax + 2 * rmax);
  std::map<std::array<long, 3>, std::vector<int>> grid;
  auto key = [h](const double* x) {
    return std::array<long, 3>{long(std::floor(x[0] / h)), long(std::floor(x[1] / h)), long(std::floor(x[2] / h))};
  };
  for (std::size_t i = 0; i < P.size(); ++i) grid[key(P[i].a)].push_back(int(i));
  DSU dsu(P.size());
  auto neighbours = [&](const double* x, const std::function<void(int)>& fn) {
    const auto k0 = key(x);
    for (long dz = -1; dz <= 1; ++dz)
      for (long dy = -1; dy <= 1; ++dy)
        for (long dx = -1; dx <= 1; ++dx) {
          auto it = grid.find({k0[0] + dx, k0[1] + dy, k0[2] + dz});
          if (it == grid.end()) continue;
          for (int j : it->second) fn(j);
        }
  };
  for (std::size_t i = 0; i < P.size(); ++i)
    neighbours(P[i].a, [&](int j) {
      if (j <= int(i)) return;
      if (seg_seg_dist(P[i].a, P[i].b, P[j].a, P[j].b) <= inscribed(P[i]) + inscribed(P[j]))
        dsu.u(int(i), j);
    });
  std::set<int> roots;
  for (std::size_t i = 0; i < P.size(); ++i) roots.insert(dsu.f(int(i)));
  out.components = int(roots.size());
  for (std::size_t i = 0; i < P.size(); ++i) {
    if (P[i].ball) continue;
    for (const double* end : {P[i].a, P[i].b}) {
      ++out.ends;
      bool covered = false;
      neighbours(end, [&](int j) {
        if (covered || j == int(i)) return;
        const USeg s{{P[j].a[0], P[j].a[1], P[j].a[2]}, {P[j].b[0], P[j].b[1], P[j].b[2]}};
        if (seg_d2(end, s) <= inscribed(P[j]) * inscribed(P[j])) covered = true;
      });
      if (!covered) ++out.dangling;
    }
  }
  return out;
}
struct Collect : topopt::TriangleSink {
  void add_triangle(const Vec3&, const Vec3&, const Vec3&) override {}
};
std::vector<Prim> tap(const std::function<void(const topopt::LatticeGenObserver*)>& run) {
  std::vector<Prim> P;
  topopt::LatticeGenObserver obs;
  obs.on_element = [&P](topopt::LatticeGenElement k, const Vec3& a, const Vec3& b, double r) {
    Prim p;
    p.ball = (k == topopt::LatticeGenElement::Node || k == topopt::LatticeGenElement::AnchorNode);
    p.a[0] = a.x; p.a[1] = a.y; p.a[2] = a.z; p.b[0] = b.x; p.b[1] = b.y; p.b[2] = b.z; p.r = r;
    P.push_back(p);
  };
  run(&obs);
  return P;
}
int mode_spans(const std::string& path, const std::string& solid_path,
               const std::string& part_path, double shell_mm) {
  std::vector<Prim> P;
  std::FILE* f = std::fopen(path.c_str(), "r");
  if (!f) { std::fprintf(stderr, "cannot open %s\n", path.c_str()); return 1; }
  char line[512];
  while (std::fgets(line, sizeof line, f)) {
    Prim p;
    if (std::sscanf(line, "SEG %lf %lf %lf %lf %lf %lf %lf", &p.a[0], &p.a[1], &p.a[2], &p.b[0],
                    &p.b[1], &p.b[2], &p.r) != 7)
      continue;
    p.ball = p.a[0] == p.b[0] && p.a[1] == p.b[1] && p.a[2] == p.b[2];
    P.push_back(p);
  }
  std::fclose(f);
  const Conn cn = connectivity(P);
  // component sizes, largest first
  DSU dsu(P.size());
  // (recompute the partition to report sizes: connectivity() keeps only the count)
  std::map<std::array<long, 3>, std::vector<int>> grid;
  double rmax = 0, lmax = 0;
  for (const auto& p : P) {
    rmax = std::max(rmax, p.r);
    double l = 0;
    for (int k = 0; k < 3; ++k) l += (p.b[k] - p.a[k]) * (p.b[k] - p.a[k]);
    lmax = std::max(lmax, std::sqrt(l));
  }
  const double h = std::max(1e-6, lmax + 2 * rmax);
  auto key = [h](const double* x) {
    return std::array<long, 3>{long(std::floor(x[0] / h)), long(std::floor(x[1] / h)), long(std::floor(x[2] / h))};
  };
  for (std::size_t i = 0; i < P.size(); ++i) grid[key(P[i].a)].push_back(int(i));
  for (std::size_t i = 0; i < P.size(); ++i) {
    const auto k0 = key(P[i].a);
    for (long dz = -1; dz <= 1; ++dz)
      for (long dy = -1; dy <= 1; ++dy)
        for (long dx = -1; dx <= 1; ++dx) {
          auto it = grid.find({k0[0] + dx, k0[1] + dy, k0[2] + dz});
          if (it == grid.end()) continue;
          for (int j : it->second)
            if (j > int(i) && seg_seg_dist(P[i].a, P[i].b, P[j].a, P[j].b) <=
                                  inscribed(P[i]) + inscribed(P[j]))
              dsu.u(int(i), j);
        }
  }
  std::map<int, int> size;
  for (std::size_t i = 0; i < P.size(); ++i) ++size[dsu.f(int(i))];
  // A cut end (a strut end no other primitive covers) is where the clip stopped the strut
  // at the allowed region's surface -- the part's skin or the solid companion -- so a
  // component with one is held by the part. A component with NONE touches nothing: that
  // is floating debris, the real failure on a part whose lattice regions are pockets
  // joined only through solid.
  std::map<int, long> cut_ends;
  for (std::size_t i = 0; i < P.size(); ++i) {
    if (P[i].ball) continue;
    for (const double* end : {P[i].a, P[i].b}) {
      bool covered = false;
      const auto k0 = key(end);
      for (long dz = -1; dz <= 1 && !covered; ++dz)
        for (long dy = -1; dy <= 1 && !covered; ++dy)
          for (long dx = -1; dx <= 1 && !covered; ++dx) {
            auto it = grid.find({k0[0] + dx, k0[1] + dy, k0[2] + dz});
            if (it == grid.end()) continue;
            for (int j : it->second) {
              if (j == int(i)) continue;
              const USeg s{{P[j].a[0], P[j].a[1], P[j].a[2]}, {P[j].b[0], P[j].b[1], P[j].b[2]}};
              if (seg_d2(end, s) <= inscribed(P[j]) * inscribed(P[j])) { covered = true; break; }
            }
          }
      if (!covered) ++cut_ends[dsu.f(int(i))];
    }
  }
  int floating = 0;
  long floating_prims = 0;
  for (const auto& kv : size)
    if (!cut_ends.count(kv.first)) { ++floating; floating_prims += kv.second; }
  // With the run's SOLID companion body (<prefix>_lattice_SOLID.stl): a component is
  // HELD when one of its primitives' solids reaches the solid body (an end or a node
  // centre inside it, or within its own radius + 0.05 mm of its surface).
  int unheld = -1;
  long unheld_prims = 0;
  if (!solid_path.empty()) {
    const topopt::TriangleMesh solid = topopt::import_stl_file(solid_path);
    const topopt::MeshDistance md(solid);
    std::map<int, bool> held;
    for (std::size_t i = 0; i < P.size(); ++i) {
      const int c = dsu.f(int(i));
      if (held[c]) continue;
      for (const double* p : {P[i].a, P[i].b}) {
        const double sd = md.signed_distance(Vec3{p[0], p[1], p[2]});
        if (sd > 0.0 || std::fabs(sd) <= P[i].r + 0.05) { held[c] = true; break; }
      }
    }
    // ...or the run's solid SHELL: a wall `shell_mm` thick inside the part's own surface
    // (<prefix>.stl, the variant the lattice was cut into; run_info wall_thickness_mm).
    if (!part_path.empty()) {
      const topopt::TriangleMesh part = topopt::import_stl_file(part_path);
      const topopt::MeshDistance pd(part);
      for (std::size_t i = 0; i < P.size(); ++i) {
        const int c = dsu.f(int(i));
        if (held[c]) continue;
        for (const double* p : {P[i].a, P[i].b})
          if (std::fabs(pd.signed_distance(Vec3{p[0], p[1], p[2]})) <=
              shell_mm + P[i].r + 0.05) { held[c] = true; break; }
      }
    }
    unheld = 0;
    for (const auto& kv : size)
      if (!held[kv.first] && !cut_ends.count(kv.first)) { ++unheld; unheld_prims += kv.second; }
  }
  std::vector<int> sizes;
  for (const auto& kv : size) sizes.push_back(kv.second);
  std::sort(sizes.rbegin(), sizes.rend());
  std::printf("SPANS %s: %zu primitives, %d components, %ld of %ld strut ends cut (no other "
              "primitive covers them)\n", path.c_str(), cn.prims, cn.components, cn.dangling,
              cn.ends);
  std::printf("  components with no cut end: %d (%ld primitives)\n", floating, floating_prims);
  if (unheld >= 0)
    std::printf("  FLOATING (no cut end, not touching the solid companion%s): %d components, "
                "%ld primitives\n", part_path.empty() ? "" : " or the shell", unheld, unheld_prims);
  std::printf("  component sizes (primitives), largest first:");
  for (std::size_t i = 0; i < sizes.size() && i < 40; ++i) std::printf(" %d", sizes[i]);
  std::printf("%s\n", sizes.size() > 40 ? " ..." : "");
  return 0;
}

int mode_step(const std::string& id) {
  const topopt::LatticeGenTopology gt = topopt::lattice_gen_topology_from_id(id);
  const LatticeTopology t = topopt::lattice_gen_certificate_topology(gt);
  const double S = 8.0;
  const double rho = 0.5 * (topopt::lattice_rho_min(t) + topopt::lattice_rho_max(t));
  auto rad = [&](double cell) { return 0.5 * topopt::lattice_strut_diameter_mm(t, rho, cell); };
  FILE* csv = csv_open(id + "_step.csv");
  if (csv) std::fprintf(csv, "case,primitives,components,strut_ends,dangling_ends,verdict\n");
  std::printf("STEP %s at rho %.4f (band middle), S=%.0f mm, production generator\n", id.c_str(), rho, S);
  auto report = [&](const char* name, const Conn& cn) {
    const bool pass = cn.components == 1 && cn.dangling == 0;
    std::printf("  %-26s prims %6zu  components %3d  ends %6ld  dangling %4ld  -> %s\n", name,
                cn.prims, cn.components, cn.ends, cn.dangling, pass ? "PASS" : "FAIL");
    if (csv) std::fprintf(csv, "%s,%zu,%d,%ld,%ld,%s\n", name, cn.prims, cn.components, cn.ends,
                          cn.dangling, pass ? "PASS" : "FAIL");
  };
  Collect sink;
  // Uniform control: one cell size, 4 x 4 x 4.
  {
    topopt::LatticeRegion R;
    R.nx = R.ny = R.nz = 4; R.cell_mm = S;
    topopt::LatticeRadiusField G; G.uniform_mm = rad(S);
    report("uniform_4x4x4", connectivity(tap([&](const topopt::LatticeGenObserver* o) {
             topopt::generate_lattice(gt, R, G, sink, {}, o); })));
  }
  // DOUBLED: base grid S/2, 8 x 4 x 4; fine level on x < 2S, coarse (S) on x >= 2S.
  {
    topopt::LatticeRegion base;
    base.nx = 8; base.ny = 4; base.nz = 4; base.cell_mm = S / 2;
    std::vector<topopt::LatticeLevelSpec> lv(2);
    lv[0].level = 0; lv[0].cell_mm = S / 2;
    lv[0].latticed = [](int i, int, int) { return i < 4; };
    lv[0].radius.uniform_mm = rad(S / 2);
    lv[1].level = 1; lv[1].cell_mm = S;
    lv[1].latticed = [](int i, int, int) { return i >= 2; };
    lv[1].radius.uniform_mm = rad(S);
    report("doubled_S|S/2", connectivity(tap([&](const topopt::LatticeGenObserver* o) {
             topopt::generate_lattice_multilevel(gt, base, lv, sink, {}, o); })));
  }
  // STEPPED: S cells on x in [0, 2S], 2S/3 cells on x in [2S, 4S], same 2S x 2S face.
  {
    std::vector<topopt::LatticeSteppedPass> passes(2);
    passes[0].region.nx = 2; passes[0].region.ny = 2; passes[0].region.nz = 2;
    passes[0].region.cell_mm = S;
    passes[0].radius.uniform_mm = rad(S);
    const double s2 = 2.0 * S / 3.0;
    passes[1].region.origin = Vec3{2 * S, 0, 0};
    passes[1].region.nx = 3; passes[1].region.ny = 3; passes[1].region.nz = 3;
    passes[1].region.cell_mm = s2;
    passes[1].radius.uniform_mm = rad(s2);
    report("stepped_S|2S/3", connectivity(tap([&](const topopt::LatticeGenObserver* o) {
             topopt::generate_lattice_stepped(gt, passes, sink, {}, o); })));
  }
  if (csv) std::fclose(csv);
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  std::setvbuf(stdout, nullptr, _IONBF, 0);
  if (argc < 3) {
    std::fprintf(stderr, "usage: %s {law|bend|perc|step} <topology id>\n", argv[0]);
    return 2;
  }
  const std::string cmd = argv[1], id = argv[2];
  if (cmd == "law") return mode_law(id);
  if (cmd == "bend") return mode_bend(id);
  if (cmd == "perc") return mode_perc(id);
  if (cmd == "step") return mode_step(id);
  if (cmd == "spans")
    return mode_spans(id, argc > 3 ? argv[3] : "", argc > 4 ? argv[4] : "",
                      argc > 5 ? std::atof(argv[5]) : 0.0);
  std::fprintf(stderr, "unknown subcommand %s\n", cmd.c_str());
  return 2;
}
