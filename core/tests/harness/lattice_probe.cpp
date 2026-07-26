// lattice_probe.cpp — measurement harness (NOT a CI test) for the lattice-mode
// Phase-0 feasibility study (handoff 2026-07-26-lattice-phase0).
//
// READ-ONLY / MEASUREMENT ONLY. This file builds NOTHING into production. It
// constructs lattice VoxelGrids programmatically (the sanctioned cg_tol_probe.cpp
// pattern — grids built directly, no fixtures) and measures, for three in-scope
// lattices (Gyroid, Schwarz-D, Octet truss):
//
//   M1 RESOLUTION  — effective axial stiffness of ONE unit cell vs voxel
//                    resolution; the voxels-per-wall needed for <5% change on a
//                    doubling. Then the implied grid for a 200 mm part.
//   M2 HOMOGENIZATION GAP — resolved E_eff/E_solid vs the Gibson-Ashby f^1.5
//                    knockdown production already uses (bar: 10%). Also the
//                    best-fit exponent p (deformation mode).
//   M3 SCALE SEPARATION — apparent modulus of a K x K x K block (free lateral)
//                    vs K; how many cells across a member before it matches the
//                    single-cell homogenized value within M2's bar.
//   M4 GENERATION  — marching-cubes triangle count / time / STL bytes over a
//                    representative volume at printable cell sizes.
//   M6 ISOTROPY    — effective modulus along x/y/z; anisotropy ratio max/min.
//
// Effective modulus is measured with a displacement-controlled UNIAXIAL test:
// the two end planes normal to the load axis are Dirichlet-constrained (min = 0,
// max = delta = 1e-3 * length) on the axis component; three transverse DOFs are
// pinned to remove the in-plane rigid modes; the lateral surfaces are FREE
// (uniaxial-stress state, so the recovered modulus is E, not the confined
// oedometric modulus). The end reaction is recovered as sum of (K u) on the max-
// face nodes via the assembled operator (fea_assembled_apply), and
//   E_app = F / (A_bbox * strain),   strain = delta / length.
// A_bbox is the FULL bounding cross-section, so E_app/E_solid is the cellular
// solid's effective stiffness relative to its envelope — the quantity the
// knockdown claims to model. A fully-solid block recovers E_solid (self-check).
//
// Build (standalone; NOT wired into CTest), from core/:
//   c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
//     tests/harness/lattice_probe.cpp build/libtopopt.a -o build/lattice_probe
// CSV sink: set TOPOPT_LATTICE_CSV_DIR to write machine-readable tables there.

#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <unordered_set>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/mesh.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {

constexpr double kE = 3500.0;   // PLA solid modulus (materials.json), MPa
constexpr double kNu = 0.33;    // PLA Poisson
constexpr double kStrain = 1e-3;  // applied nominal axial strain

// ------------------------------------------------------------------ lattices
enum class Lattice { Gyroid, SchwarzD, Octet };
const char* name_of(Lattice l) {
  switch (l) {
    case Lattice::Gyroid: return "gyroid";
    case Lattice::SchwarzD: return "schwarzD";
    case Lattice::Octet: return "octet";
  }
  return "?";
}

// TPMS level fields, argument scaled so one period == cell edge L.
double gyroid_val(double x, double y, double z, double L) {
  const double a = 2.0 * M_PI / L;
  return std::sin(a * x) * std::cos(a * y) + std::sin(a * y) * std::cos(a * z) +
         std::sin(a * z) * std::cos(a * x);
}
double schwarzD_val(double x, double y, double z, double L) {
  const double a = 2.0 * M_PI / L;
  return std::sin(a * x) * std::sin(a * y) * std::sin(a * z) +
         std::sin(a * x) * std::cos(a * y) * std::cos(a * z) +
         std::cos(a * x) * std::sin(a * y) * std::cos(a * z) +
         std::cos(a * x) * std::cos(a * y) * std::sin(a * z);
}

// Octet truss: distance to the strut skeleton of one FCC-style unit cell. Struts
// connect the 8 corners and 6 face-centres (the standard octet edge+face-diagonal
// graph). A voxel is solid if its centre lies within strut radius r of any strut
// segment. r is chosen to hit a target volume fraction (see calibrate_octet).
double point_seg_dist2(double px, double py, double pz, const double a[3],
                       const double b[3]) {
  double ab[3] = {b[0] - a[0], b[1] - a[1], b[2] - a[2]};
  double ap[3] = {px - a[0], py - a[1], pz - a[2]};
  double denom = ab[0] * ab[0] + ab[1] * ab[1] + ab[2] * ab[2];
  double t = denom > 0 ? (ap[0] * ab[0] + ap[1] * ab[1] + ap[2] * ab[2]) / denom
                       : 0.0;
  t = t < 0 ? 0 : (t > 1 ? 1 : t);
  double c[3] = {a[0] + t * ab[0], a[1] + t * ab[1], a[2] + t * ab[2]};
  double d[3] = {px - c[0], py - c[1], pz - c[2]};
  return d[0] * d[0] + d[1] * d[1] + d[2] * d[2];
}

// Struts of the octet cell in unit coords [0,1]^3 (corners + face centres).
std::vector<std::array<std::array<double, 3>, 2>> octet_struts() {
  // 8 corners
  std::vector<std::array<double, 3>> nodes;
  for (int z = 0; z <= 1; ++z)
    for (int y = 0; y <= 1; ++y)
      for (int x = 0; x <= 1; ++x)
        nodes.push_back({double(x), double(y), double(z)});
  // 6 face centres
  const std::array<std::array<double, 3>, 6> fc = {{{0.5, 0.5, 0.0},
                                                    {0.5, 0.5, 1.0},
                                                    {0.5, 0.0, 0.5},
                                                    {0.5, 1.0, 0.5},
                                                    {0.0, 0.5, 0.5},
                                                    {1.0, 0.5, 0.5}}};
  for (auto& f : fc) nodes.push_back(f);
  // Connect each face centre to the four corners of its face (octet edges).
  std::vector<std::array<std::array<double, 3>, 2>> segs;
  auto add = [&](const std::array<double, 3>& p, const std::array<double, 3>& q) {
    segs.push_back({p, q});
  };
  for (std::size_t fi = 8; fi < nodes.size(); ++fi) {
    for (std::size_t ci = 0; ci < 8; ++ci) {
      // corner shares the face if it matches the fixed coordinate of the centre
      double d2 = 0;
      for (int k = 0; k < 3; ++k) {
        double v = nodes[fi][k];
        if (v == 0.0 || v == 1.0)  // the fixed axis of this face
          d2 += (nodes[ci][k] - v) * (nodes[ci][k] - v);
      }
      if (d2 < 1e-9) add(nodes[fi], nodes[ci]);
    }
  }
  return segs;
}

double octet_dist2(double x, double y, double z, double L,
                   const std::vector<std::array<std::array<double, 3>, 2>>& segs) {
  // fold into the [0,L) cell then to unit coords
  double u = std::fmod(x, L) / L, v = std::fmod(y, L) / L, w = std::fmod(z, L) / L;
  if (u < 0) u += 1;
  if (v < 0) v += 1;
  if (w < 0) w += 1;
  double best = 1e30;
  for (auto& s : segs) {
    double d2 = point_seg_dist2(u, v, w, s[0].data(), s[1].data());
    if (d2 < best) best = d2;
  }
  return best * L * L;  // back to model units^2
}

struct GenParams {
  Lattice kind;
  double L;        // cell edge, mm
  double level;    // TPMS |field| threshold (sheet) — controls wall thickness
  double octet_r;  // octet strut radius, mm
};

bool is_solid(const GenParams& g, double x, double y, double z,
              const std::vector<std::array<std::array<double, 3>, 2>>& segs) {
  switch (g.kind) {
    case Lattice::Gyroid:
      return std::fabs(gyroid_val(x, y, z, g.L)) < g.level;
    case Lattice::SchwarzD:
      return std::fabs(schwarzD_val(x, y, z, g.L)) < g.level;
    case Lattice::Octet:
      return octet_dist2(x, y, z, g.L, segs) < g.octet_r * g.octet_r;
  }
  return false;
}

// Build a Ncx x Ncy x Ncz cell block at `vpc` voxels per cell edge.
VoxelGrid build_lattice(const GenParams& g, int ncx, int ncy, int ncz, int vpc) {
  VoxelGrid grid;
  grid.nx = ncx * vpc;
  grid.ny = ncy * vpc;
  grid.nz = ncz * vpc;
  grid.spacing = g.L / vpc;
  grid.origin = Vec3{0, 0, 0};
  grid.tags.assign(static_cast<std::size_t>(grid.nx) * grid.ny * grid.nz,
                   VoxelTag::Empty);
  auto segs = octet_struts();
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        Vec3 c = grid.voxel_center(i, j, k);
        if (is_solid(g, c.x, c.y, c.z, segs))
          grid.set_tag(i, j, k, VoxelTag::Interior);
      }
  return grid;
}

double volume_fraction(const VoxelGrid& g) {
  return static_cast<double>(g.solid_count()) /
         static_cast<double>(g.voxel_count());
}

// Median solid-run length along x, over all (j,k) scan lines — an empirical
// "voxels per wall" measured directly from the generated grid.
double median_wall_voxels(const VoxelGrid& g) {
  std::vector<int> runs;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j) {
      int run = 0;
      for (int i = 0; i < g.nx; ++i) {
        if (g.solid(i, j, k)) {
          ++run;
        } else if (run > 0) {
          runs.push_back(run);
          run = 0;
        }
      }
      if (run > 0 && run < g.nx) runs.push_back(run);  // drop full-span (not a wall)
    }
  if (runs.empty()) return 0;
  std::sort(runs.begin(), runs.end());
  return runs[runs.size() / 2];
}

// ------------------------------------------------------------- effective E
// Set of node ids that are corners of at least one solid voxel.
std::unordered_set<int> solid_nodes(const VoxelGrid& g) {
  std::unordered_set<int> s;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i)
        if (g.solid(i, j, k)) {
          auto ns = fea_element_nodes(g, i, j, k);
          for (int n : ns) s.insert(n);
        }
  return s;
}

struct ApparentE {
  double E_app = 0;
  int min_nodes = 0, max_nodes = 0;
  int cg_iters = 0;
  bool converged = false;
};

// Uniaxial displacement-controlled apparent modulus along `axis` (0=x,1=y,2=z).
ApparentE apparent_E(const VoxelGrid& g, int axis) {
  ApparentE out;
  const int N[3] = {g.nx, g.ny, g.nz};
  const double h = g.spacing;
  const int t1 = (axis + 1) % 3, t2 = (axis + 2) % 3;  // transverse axes
  auto solids = solid_nodes(g);
  // Enumerate face nodes (a,b,c) on min (axis-index 0) and max (axis-index N).
  const double delta = kStrain * (N[axis] * h);
  std::vector<DirichletBC> bcs;
  std::vector<std::array<int, 3>> maxface;  // (id, t1coord, t2coord)
  // pin candidates on the min face
  int pinA = -1, pinB = -1;
  double pinB_t1 = -1;
  int minA_t1 = 1 << 30;
  // Iterate the 2D face grid generically over the two transverse axes.
  const int nt1 = N[t1], nt2 = N[t2];
  auto make_coord = [&](int face_index, int c1, int c2) {
    std::array<int, 3> co{};
    co[axis] = face_index;
    co[t1] = c1;
    co[t2] = c2;
    return co;
  };
  for (int c2 = 0; c2 <= nt2; ++c2)
    for (int c1 = 0; c1 <= nt1; ++c1) {
      auto lo = make_coord(0, c1, c2);
      int nlo = fea_node_index(g, lo[0], lo[1], lo[2]);
      if (solids.count(nlo)) {
        bcs.push_back({nlo, axis, 0.0});
        ++out.min_nodes;
        // pick pins: pinA = smallest (c1,c2); pinB = largest c1 at c2==0-ish
        if (c1 + c2 * (nt1 + 1) < minA_t1) {
          minA_t1 = c1 + c2 * (nt1 + 1);
          pinA = nlo;
        }
        if (c1 > pinB_t1) {
          pinB_t1 = c1;
          pinB = nlo;
        }
      }
      auto hi = make_coord(N[axis], c1, c2);
      int nhi = fea_node_index(g, hi[0], hi[1], hi[2]);
      if (solids.count(nhi)) {
        bcs.push_back({nhi, axis, delta});
        maxface.push_back({nhi, c1, c2});
        ++out.max_nodes;
      }
    }
  if (pinA >= 0) {
    bcs.push_back({pinA, t1, 0.0});
    bcs.push_back({pinA, t2, 0.0});
  }
  if (pinB >= 0 && pinB != pinA) bcs.push_back({pinB, t2, 0.0});

  CgInfo info;
  FeaSolution sol;
  try {
    sol = fea_solve_cg(g, kE, kNu, bcs, /*loads=*/{}, 1e-7, 0, &info);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "  [apparent_E axis %d solve failed: %s]\n", axis,
                 e.what());
    return out;
  }
  out.cg_iters = info.iterations;
  out.converged = info.converged;
  // Reaction on the max face = sum of (K u)_axis over max-face nodes.
  std::vector<double> Ku = fea_assembled_apply(g, kE, kNu, sol.u);
  double F = 0;
  for (auto& m : maxface) F += Ku[3 * m[0] + axis];
  const double A = (nt1 * h) * (nt2 * h);
  out.E_app = std::fabs(F) / (A * kStrain);
  return out;
}

// -------------------------------------------------------------- CSV helpers
FILE* csv_open(const std::string& name) {
  const char* dir = std::getenv("TOPOPT_LATTICE_CSV_DIR");
  if (!dir) return nullptr;
  std::string path = std::string(dir) + "/" + name;
  FILE* f = std::fopen(path.c_str(), "w");
  if (f) std::printf("  [writing %s]\n", path.c_str());
  return f;
}

double best_fit_exponent(double ratio, double f) {
  if (f <= 0 || f >= 1 || ratio <= 0) return 0;
  return std::log(ratio) / std::log(f);
}

// ------------------------------------------------------------------- self-check
void self_check_solid() {
  std::printf("\n===== SELF-CHECK: solid block must recover E_solid =====\n");
  VoxelGrid g;
  g.nx = g.ny = g.nz = 16;
  g.spacing = 1.0;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(16 * 16 * 16, VoxelTag::Interior);
  for (int axis = 0; axis < 3; ++axis) {
    ApparentE r = apparent_E(g, axis);
    std::printf("  axis %d: E_app=%.1f MPa  (E_solid=%.1f)  ratio=%.4f  cg=%d\n",
                axis, r.E_app, kE, r.E_app / kE, r.cg_iters);
  }
}

// -------------------------------------------------------- calibrate TPMS level
// Bisect the TPMS |field| level to hit a target volume fraction at a reference
// resolution (so all lattices are compared at the same porosity).
double calibrate_level(Lattice kind, double L, double target_vf, int vpc) {
  GenParams g{kind, L, 0.0, 0.0};
  double lo = 0.01, hi = 1.5;
  for (int it = 0; it < 24; ++it) {
    double mid = 0.5 * (lo + hi);
    g.level = mid;
    VoxelGrid grid = build_lattice(g, 1, 1, 1, vpc);
    double vf = volume_fraction(grid);
    if (vf < target_vf)
      lo = mid;
    else
      hi = mid;
  }
  return 0.5 * (lo + hi);
}
double calibrate_octet_r(double L, double target_vf, int vpc) {
  GenParams g{Lattice::Octet, L, 0.0, 0.0};
  double lo = 0.001 * L, hi = 0.25 * L;
  for (int it = 0; it < 24; ++it) {
    double mid = 0.5 * (lo + hi);
    g.octet_r = mid;
    VoxelGrid grid = build_lattice(g, 1, 1, 1, vpc);
    double vf = volume_fraction(grid);
    if (vf < target_vf)
      lo = mid;
    else
      hi = mid;
  }
  return 0.5 * (lo + hi);
}

GenParams calibrated(Lattice kind, double L, double target_vf, int vpc) {
  GenParams g{kind, L, 0.0, 0.0};
  if (kind == Lattice::Octet)
    g.octet_r = calibrate_octet_r(L, target_vf, vpc);
  else
    g.level = calibrate_level(kind, L, target_vf, vpc);
  return g;
}

// ================================================================== M1
void M1_resolution(Lattice kind, double L, double target_vf) {
  std::printf("\n===== M1 RESOLUTION — %s, cell L=%.1f mm, target vf=%.2f =====\n",
              name_of(kind), L, target_vf);
  FILE* csv = csv_open(std::string("m1_") + name_of(kind) + ".csv");
  if (csv) std::fprintf(csv, "lattice,L_mm,vpc,spacing_mm,voxels,vf,wall_voxels,E_ratio,cg_iters,converged\n");
  const int vpcs[] = {8, 12, 16, 24, 32, 48, 64};
  double prev = -1;
  std::printf("  %-5s %-8s %-9s %-6s %-9s %-6s %-9s\n", "vpc", "h(mm)", "voxels",
              "vf", "wall_vox", "E/Es", "d%%");
  // Calibrate the geometry ONCE for THIS lattice at a fine reference resolution,
  // so the physical shape (level / strut radius) is fixed in mm and only the
  // voxel resolution changes across the sweep.
  const GenParams gref = calibrated(kind, L, target_vf, 48);
  for (int vpc : vpcs) {
    GenParams g{kind, L, gref.level, gref.octet_r};
    VoxelGrid grid = build_lattice(g, 1, 1, 1, vpc);
    double vf = volume_fraction(grid);
    double wall = median_wall_voxels(grid);
    ApparentE r = apparent_E(grid, 2);
    double ratio = r.E_app / kE;
    double dpct = prev > 0 ? 100.0 * std::fabs(ratio - prev) / prev : 0.0;
    std::printf("  %-5d %-8.4f %-9zu %-6.3f %-9.1f %-9.5f %.2f\n", vpc,
                grid.spacing, grid.voxel_count(), vf, wall, ratio, dpct);
    if (csv)
      std::fprintf(csv, "%s,%.3f,%d,%.5f,%zu,%.5f,%.2f,%.6f,%d,%d\n",
                   name_of(kind), L, vpc, grid.spacing, grid.voxel_count(), vf,
                   wall, ratio, r.cg_iters, r.converged ? 1 : 0);
    prev = ratio;
  }
  if (csv) std::fclose(csv);
}

// ================================================================== M2 + M6
void M2_M6(Lattice kind, double L, double target_vf, int vpc, FILE* csv) {
  GenParams g = calibrated(kind, L, target_vf, vpc);
  VoxelGrid grid = build_lattice(g, 1, 1, 1, vpc);
  double f = volume_fraction(grid);
  ApparentE rx = apparent_E(grid, 0);
  ApparentE ry = apparent_E(grid, 1);
  ApparentE rz = apparent_E(grid, 2);
  double ex = rx.E_app / kE, ey = ry.E_app / kE, ez = rz.E_app / kE;
  double emin = std::min({ex, ey, ez}), emax = std::max({ex, ey, ez});
  double aniso = emin > 0 ? 100.0 * (emax - emin) / emin : 0.0;
  double emean = (ex + ey + ez) / 3.0;
  double ga = std::pow(f, 1.5);  // Gibson-Ashby f^1.5 knockdown
  double gap = 100.0 * std::fabs(emean - ga) / ga;
  double pexp = best_fit_exponent(emean, f);
  std::printf(
      "  %-9s vf=%.3f  E/Es[x,y,z]=%.4f,%.4f,%.4f  aniso=%.1f%%  "
      "mean=%.4f  f^1.5=%.4f  gap=%.1f%%  fit_p=%.2f\n",
      name_of(kind), f, ex, ey, ez, aniso, emean, ga, gap, pexp);
  if (csv)
    std::fprintf(csv, "%s,%.3f,%d,%.5f,%.6f,%.6f,%.6f,%.2f,%.6f,%.6f,%.2f,%.3f\n",
                 name_of(kind), L, vpc, f, ex, ey, ez, aniso, emean, ga, gap,
                 pexp);
}

// ================================================================== M3
void M3_scale(Lattice kind, double L, double target_vf, int vpc, int maxK) {
  std::printf(
      "\n===== M3 SCALE SEPARATION — %s, cell L=%.1f mm, vpc=%d =====\n",
      name_of(kind), L, vpc);
  FILE* csv = csv_open(std::string("m3_") + name_of(kind) + ".csv");
  if (csv) std::fprintf(csv, "lattice,K_cells,vpc,voxels,vf,E_ratio,cg_iters\n");
  GenParams g = calibrated(kind, L, target_vf, vpc);
  std::printf("  %-4s %-10s %-6s %-9s %-8s\n", "K", "voxels", "vf", "E/Es", "cg");
  double asymptote = -1;
  std::vector<std::pair<int, double>> pts;
  for (int K = 1; K <= maxK; ++K) {
    VoxelGrid grid = build_lattice(g, K, K, K, vpc);
    double vf = volume_fraction(grid);
    ApparentE r = apparent_E(grid, 2);
    double ratio = r.E_app / kE;
    pts.push_back({K, ratio});
    std::printf("  %-4d %-10zu %-6.3f %-9.5f %-8d\n", K, grid.voxel_count(), vf,
                ratio, r.cg_iters);
    if (csv)
      std::fprintf(csv, "%s,%d,%d,%zu,%.5f,%.6f,%d\n", name_of(kind), K, vpc,
                   grid.voxel_count(), vf, ratio, r.cg_iters);
    asymptote = ratio;  // largest K = best estimate of bulk
  }
  // cells-to-within-10%-of-asymptote
  int kconv = -1;
  for (auto& p : pts)
    if (asymptote > 0 && 100.0 * std::fabs(p.second - asymptote) / asymptote <= 10.0) {
      kconv = p.first;
      break;
    }
  std::printf("  -> bulk(K=%d) E/Es=%.4f ; first K within 10%% of bulk = %d\n",
              maxK, asymptote, kconv);
  if (csv) std::fclose(csv);
}

// ================================================================== M4
void M4_generation(Lattice kind, double L, double target_vf, double vol_mm) {
  // Representative cube of edge vol_mm at a printable cell size L.
  int ncx = std::max(1, (int)std::lround(vol_mm / L));
  int vpc = 12;  // enough to resolve a printable wall at this cell size
  GenParams g = calibrated(kind, L, target_vf, vpc);
  VoxelGrid grid = build_lattice(g, ncx, ncx, ncx, vpc);
  // Build an occupancy field for marching cubes (1 solid, 0 empty).
  std::vector<double> field(grid.voxel_count(), 0.0);
  for (std::size_t i = 0; i < field.size(); ++i)
    field[i] = grid.tags[i] == VoxelTag::Empty ? 0.0 : 1.0;
  auto t0 = std::chrono::steady_clock::now();
  TriangleMesh mesh = marching_cubes(grid.nx, grid.ny, grid.nz, grid.spacing,
                                     grid.origin, field, 0.5);
  auto t1 = std::chrono::steady_clock::now();
  double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
  std::size_t tris = mesh.triangle_count();
  double stl_mb = (84.0 + 50.0 * tris) / 1e6;
  double vol_cm3 = std::pow(vol_mm / 10.0, 3);
  double edge_cm = vol_mm / 10.0;
  std::printf(
      "  %-9s L=%.2f mm  cube=%.0fmm(%d^3 cells)  grid=%d^3  vf=%.3f  "
      "tris=%zu  %.2f MB  MC=%.0f ms  |  %.0f tris/cm^3\n",
      name_of(kind), L, vol_mm, ncx, grid.nx, volume_fraction(grid), tris,
      stl_mb, ms, tris / vol_cm3);
  // Scale to a 200x100x150 mm part (the 089 reference envelope), 30% occupied.
  double part_cm3 = 20.0 * 10.0 * 15.0 * 0.30;
  double part_tris = (tris / vol_cm3) * part_cm3;
  std::printf("      -> 200x100x150mm @30%% occ: ~%.1f M tris, ~%.0f MB STL\n",
              part_tris / 1e6, (84 + 50 * part_tris) / 1e6);
}

}  // namespace

int main() {
  std::printf("LATTICE PHASE-0 PROBE — E_solid=%.0f MPa nu=%.2f strain=%.0e\n",
              kE, kNu, kStrain);
  fea_set_matfree_threads(6);

  self_check_solid();

  // Representative printable geometry. A 0.4mm nozzle prints a gyroid wall at
  // ~1-2 extrusion widths; a slicer gyroid at ~30% infill in a small part uses
  // cells of a few mm. We use cell L=5mm at vf=0.30 as the baseline, and also
  // probe a smaller L=2.5mm cell (the size that would fit inside a 9.4mm member).
  const double target_vf = 0.30;
  const char* only = std::getenv("TOPOPT_LATTICE_ONLY");  // "m1" = M1 only

  // ---- M1: resolution convergence, per lattice, at L=5mm ----
  for (Lattice l : {Lattice::Gyroid, Lattice::SchwarzD, Lattice::Octet})
    M1_resolution(l, 5.0, target_vf);
  if (only && std::string(only) == "m1") { std::printf("\n(M1-only)\n"); return 0; }

  // ---- M2 + M6: homogenization gap & isotropy, single cell at vpc=32 ----
  std::printf("\n===== M2 HOMOGENIZATION GAP + M6 ISOTROPY (single cell, vpc=32) =====\n");
  std::printf("  bar: M2 gap <=10%% for f^1.5 to carry a margin; M6 aniso >15%% needs a tensor\n");
  {
    FILE* csv = csv_open("m2_m6.csv");
    if (csv) std::fprintf(csv, "lattice,L_mm,vpc,vf,Ex,Ey,Ez,aniso_pct,E_mean,ga_f15,gap_pct,fit_p\n");
    for (Lattice l : {Lattice::Gyroid, Lattice::SchwarzD, Lattice::Octet})
      M2_M6(l, 5.0, target_vf, 32, csv);
    if (csv) std::fclose(csv);
  }

  // ---- M3: scale separation, gyroid + schwarzD, vpc=16, up to 5 cells ----
  M3_scale(Lattice::Gyroid, 5.0, target_vf, 16, 5);
  M3_scale(Lattice::SchwarzD, 5.0, target_vf, 16, 5);

  // ---- M4: generation cost / triangle count ----
  std::printf("\n===== M4 GENERATION COST + TRIANGLE COUNT =====\n");
  std::printf("  viewer budget ~125k tris (089); shipped bracket variants 22k-37k tris (134)\n");
  for (Lattice l : {Lattice::Gyroid, Lattice::SchwarzD, Lattice::Octet})
    M4_generation(l, 5.0, target_vf, 40.0);   // 40mm cube, 5mm cells
  std::printf("  --- finer cells (2.5mm — fits inside a 9.4mm member) ---\n");
  for (Lattice l : {Lattice::Gyroid, Lattice::SchwarzD, Lattice::Octet})
    M4_generation(l, 2.5, target_vf, 40.0);

  std::printf("\nDONE.\n");
  return 0;
}
