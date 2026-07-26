// knockdown_member_probe.cpp — measurement harness (NOT a CI test) for handoff
// 2026-07-26-knockdown-member-scale. FOLLOW-UP to 2026-07-26-knockdown-check
// (handoff 191 / knockdown_probe.cpp).
//
// THE QUESTION. 191 found the Gibson-Ashby f^1.5 knockdown the accept gate
// applies (minimize_plastic.cpp:69, margin x f^1.5 >= margin_stop) is
// SIZE-DEPENDENT: solid slicer wall loops make f^1.5 CONSERVATIVE on narrow
// cross-sections and NON-CONSERVATIVE on wide ones, crossover W* ~= 98 mm at
// 30% infill / 5 loops. But 191 modelled a SOLID RECTANGULAR BAR of width W and
// swept W across ENVELOPE-scale values (up to 200 mm). A topology-optimized part
// is NOT a solid bar: it is a set of thin RIBS/MEMBERS (this project's min-
// feature floor puts members near 9.4 mm) with voids between them, and an FDM
// slicer wraps wall loops around EACH RIB's local cross-section, not around the
// overall envelope. So the wall fraction phi_wall = 4 t (W - t)/W^2 should be
// evaluated at the MEMBER width, not the envelope width. This harness answers:
//   which width governs the knockdown -- envelope or member?
// and, because the maintainer's parts are BRACKETS loaded in BENDING (not the
// pure TENSION 191 measured), it adds a BENDING instrument: in bending the
// material far from the neutral axis dominates, which is exactly where the solid
// walls are, so the wall rescue should be even LARGER in bending than in tension.
//
// READ-ONLY / MEASUREMENT ONLY. Builds NOTHING into production. Same sanctioned
// standalone pattern as knockdown_probe.cpp / lattice_probe.cpp: VoxelGrids built
// programmatically, no fixtures, NOT wired into CTest. The AXIAL instrument is
// the SAME displacement-controlled uniaxial test 191 validated (verbatim). The
// BENDING instrument is its pure-bending analog, self-checked the same way.
//
// PLAN
//   SELF-CHECK-A   solid block -> E_solid to 4 digits, 3 axes (the 191 check).
//   SELF-CHECK-B   solid slender beam under pure-bending BCs -> E_bend, reported
//                  against E_solid; the composite bending knockdown is normalized
//                  by a MATCHED solid-beam bending solve so trilinear-hex
//                  discretization / shear locking cancel in the ratio.
//   M-AXIAL        191's wall-and-core composite, DIRECTLY RESOLVED, at MEMBER
//                  widths W in {5,10,15} mm (K = 1,2,3 cells), wall loops in
//                  {0,3,5}, full infill band. assumed/measured (f^1.5 / E) with
//                  SIGN, and the margin-at-1.5 decision number, at member scale.
//   BEND-vs-AXIAL  prismatic wall-and-core MEMBER (no end caps), measured in
//                  BENDING and TENSION on the SAME cross-section; report how the
//                  knockdown error and its SIGN differ between the two.
//
// Build (standalone; NOT wired into CTest), from core/:
//   c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
//     tests/harness/knockdown_member_probe.cpp build/libtopopt.a -o build/knockdown_member_probe
// CSV sink: set TOPOPT_MEMBER_CSV_DIR to write machine-readable tables there.
// Subset: TOPOPT_MEMBER_ONLY in {selfcheck, axial, bend}.

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <unordered_set>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {

constexpr double kE = 3500.0;    // PLA solid modulus (materials.json), MPa
constexpr double kNu = 0.33;     // PLA Poisson
constexpr double kStrain = 1e-3; // applied nominal strain (axial, and max fiber)
constexpr double kCellL = 5.0;   // gyroid cell edge, mm (lattice_probe baseline)
constexpr double kCgTol = 1e-6;

// Slicer print parameters (the Print Parameters panel).
constexpr double kLineWidth = 0.45;   // mm per wall loop (0.4 mm nozzle)
constexpr double kLayerHeight = 0.20; // mm per top/bottom shell layer
constexpr int kShellLayers = 5;       // default top/bottom shell layers

// -------------------------------------------------------------- gyroid field
double gyroid_val(double x, double y, double z, double L) {
  const double a = 2.0 * M_PI / L;
  return std::sin(a * x) * std::cos(a * y) + std::sin(a * y) * std::cos(a * z) +
         std::sin(a * z) * std::cos(a * x);
}

double volume_fraction(const VoxelGrid& g) {
  return static_cast<double>(g.solid_count()) /
         static_cast<double>(g.voxel_count());
}

// -------------------------------------------------------------- specimen build
// A Kx x Ky x Kz-cell box (edges Wx=Kx*L, Wy=Ky*L, Lz=Kz*L). Solid where ANY of:
//   * within t_cap of the z=0 or z=Lz plane   (top/bottom shell layers), OR
//   * within t_wall of an x or y side plane    (wall loops / perimeters), OR
//   * the gyroid |field| < level at infill f   (the infill core).
// t_wall=0 gives the bare core. The load / beam axis is always z; the side walls
// run the FULL z length -- as parallel columns under tension, and as the outer
// flanges (farthest from the neutral axis) under bending about y.
struct Specimen {
  int Kx, Ky, Kz;
  double level;    // gyroid |field| threshold for target infill
  double t_wall;   // side-wall thickness, mm (0 = bare core)
  double t_cap;    // top/bottom (z) cap thickness, mm (0 = prismatic, no caps)
};

VoxelGrid build_specimen(const Specimen& s, int vpc) {
  VoxelGrid g;
  g.nx = s.Kx * vpc;
  g.ny = s.Ky * vpc;
  g.nz = s.Kz * vpc;
  g.spacing = kCellL / vpc;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(g.nx) * g.ny * g.nz, VoxelTag::Empty);
  const double Wx = s.Kx * kCellL, Wy = s.Ky * kCellL, Lz = s.Kz * kCellL;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        Vec3 c = g.voxel_center(i, j, k);
        bool cap = s.t_cap > 0 && ((c.z < s.t_cap) || (c.z > Lz - s.t_cap));
        bool wall = s.t_wall > 0 &&
                    ((c.x < s.t_wall) || (c.x > Wx - s.t_wall) ||
                     (c.y < s.t_wall) || (c.y > Wy - s.t_wall));
        bool core = std::fabs(gyroid_val(c.x, c.y, c.z, kCellL)) < s.level;
        if (cap || wall || core) g.set_tag(i, j, k, VoxelTag::Interior);
      }
  return g;
}

// Solid cross-sectional area fraction of the side walls on a z-mid slice
// (walls only, no core) -- the phi_wall the Voigt tension model needs.
double measured_wall_fraction(const Specimen& s, int vpc) {
  Specimen walls_only = s;
  walls_only.level = 0.0;
  walls_only.t_cap = 0.0;
  VoxelGrid g = build_specimen(walls_only, vpc);
  const int kmid = g.nz / 2;
  long solid = 0, total = 0;
  for (int j = 0; j < g.ny; ++j)
    for (int i = 0; i < g.nx; ++i) {
      ++total;
      if (g.solid(i, j, kmid)) ++solid;
    }
  return static_cast<double>(solid) / static_cast<double>(total);
}

// Bisect the gyroid |field| level to hit target core volume fraction on a single
// bare cell at the given resolution (identical to 191).
double calibrate_level(double target_vf, int vpc) {
  double lo = 0.01, hi = 1.5;
  for (int it = 0; it < 26; ++it) {
    double mid = 0.5 * (lo + hi);
    Specimen s{1, 1, 1, mid, 0.0, 0.0};
    VoxelGrid g = build_specimen(s, vpc);
    if (volume_fraction(g) < target_vf)
      lo = mid;
    else
      hi = mid;
  }
  return 0.5 * (lo + hi);
}

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

struct SolveOut {
  double value = 0; // E_app (axial) or E_bend (bending)
  int cg_iters = 0;
  bool converged = false;
  bool used_mg = false;
};

// ---------------------------------------------------------- AXIAL apparent E
// Displacement-controlled uniaxial test along `axis`, VERBATIM instrument from
// knockdown_probe.cpp / lattice_probe.cpp: end planes Dirichlet at 0 and delta,
// three transverse DOFs pinned, lateral faces free -> recovers E. End reaction =
// sum(K u) on the max-face nodes via fea_assembled_apply. E relative to A_bbox.
SolveOut apparent_E(const VoxelGrid& g, int axis) {
  SolveOut out;
  const int N[3] = {g.nx, g.ny, g.nz};
  const double h = g.spacing;
  const int t1 = (axis + 1) % 3, t2 = (axis + 2) % 3;
  auto solids = solid_nodes(g);
  const double delta = kStrain * (N[axis] * h);
  std::vector<DirichletBC> bcs;
  std::vector<std::array<int, 3>> maxface;
  int pinA = -1, pinB = -1;
  double pinB_t1 = -1;
  int minA_key = 1 << 30;
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
        if (c1 + c2 * (nt1 + 1) < minA_key) {
          minA_key = c1 + c2 * (nt1 + 1);
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
    sol = fea_solve_mgcg(g, kE, kNu, bcs, {}, kCgTol, 0, &info);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "  [apparent_E axis %d failed: %s]\n", axis, e.what());
    return out;
  }
  out.cg_iters = info.iterations;
  out.converged = info.converged;
  out.used_mg = info.used_multigrid;
  std::vector<double> Ku = fea_assembled_apply(g, kE, kNu, sol.u);
  double F = 0;
  for (auto& m : maxface) F += Ku[3 * m[0] + axis];
  const double A = (nt1 * h) * (nt2 * h);
  out.value = std::fabs(F) / (A * kStrain);
  return out;
}

// ---------------------------------------------------------- BENDING apparent E
// Pure-bending analog of apparent_E, beam axis = z, bending about y (curvature in
// the x-z plane, neutral axis x_c = Wx/2). Prescribe u_z on BOTH z end faces to
// the Euler-Bernoulli bending profile u_z = kappa (x - x_c) z (so the z=0 face is
// all u_z=0 and the z=Lz face is linear in x); leave u_x,u_y FREE on the end
// faces (same "lateral free" philosophy as the axial test); pin x/y rigid-body
// modes. Curvature kappa set so the max fiber strain kappa*(Wx/2) = kStrain.
// Reaction moment M = sum over the z=Lz face of (x - x_c) * F_z, and
//   E_bend = M / (I_bbox * kappa),  I_bbox = Wy * Wx^3 / 12.
// A solid beam self-check returns E_bend near E_solid; the composite knockdown is
// taken relative to a MATCHED solid-beam bending solve so any residual trilinear-
// hex / shear-locking bias cancels in the ratio.
SolveOut apparent_E_bending(const VoxelGrid& g) {
  SolveOut out;
  const double h = g.spacing;
  const double Wx = g.nx * h, Wy = g.ny * h, Lz = g.nz * h;
  const double xc = 0.5 * Wx;
  const double kappa = kStrain / (0.5 * Wx); // max fiber strain = kStrain
  auto solids = solid_nodes(g);

  std::vector<DirichletBC> bcs;
  std::vector<std::array<int, 3>> topface; // {node, ix} on z=Lz face
  // pinA: a solid node on z=0 face -> pin x and y (kills x/y translation).
  // pinB: a different-x solid node on z=0 face -> pin y (kills rot about z).
  int pinA = -1, pinB = -1, pinA_ix = 1 << 30, pinB_ix = -1;
  for (int b = 0; b <= g.ny; ++b)
    for (int a = 0; a <= g.nx; ++a) {
      const double x = a * h;
      int nlo = fea_node_index(g, a, b, 0);
      if (solids.count(nlo)) {
        bcs.push_back({nlo, 2, 0.0}); // u_z = kappa*(x-xc)*0 = 0
        if (a < pinA_ix) { pinA_ix = a; pinA = nlo; }
        if (a > pinB_ix) { pinB_ix = a; pinB = nlo; }
      }
      int nhi = fea_node_index(g, a, b, g.nz);
      if (solids.count(nhi)) {
        bcs.push_back({nhi, 2, kappa * (x - xc) * Lz});
        topface.push_back({nhi, a, 0});
      }
    }
  if (pinA >= 0) {
    bcs.push_back({pinA, 0, 0.0});
    bcs.push_back({pinA, 1, 0.0});
  }
  if (pinB >= 0 && pinB != pinA) bcs.push_back({pinB, 1, 0.0});

  CgInfo info;
  FeaSolution sol;
  try {
    sol = fea_solve_mgcg(g, kE, kNu, bcs, {}, kCgTol, 0, &info);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "  [apparent_E_bending failed: %s]\n", e.what());
    return out;
  }
  out.cg_iters = info.iterations;
  out.converged = info.converged;
  out.used_mg = info.used_multigrid;
  std::vector<double> Ku = fea_assembled_apply(g, kE, kNu, sol.u);
  double M = 0;
  for (auto& m : topface) {
    const double x = m[1] * h;
    M += (x - xc) * Ku[3 * m[0] + 2];
  }
  const double I = Wy * Wx * Wx * Wx / 12.0;
  out.value = std::fabs(M) / (I * kappa);
  return out;
}

double now_ms() {
  return std::chrono::duration<double, std::milli>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

FILE* csv_open(const std::string& name) {
  const char* dir = std::getenv("TOPOPT_MEMBER_CSV_DIR");
  if (!dir) return nullptr;
  std::string path = std::string(dir) + "/" + name;
  FILE* f = std::fopen(path.c_str(), "w");
  if (f) std::printf("  [writing %s]\n", path.c_str());
  return f;
}

const std::vector<double> kInfills = {0.15, 0.20, 0.25, 0.30, 0.40, 0.50, 0.60};

// ================================================================= SELF-CHECKS
void self_check_axial() {
  std::printf("\n===== SELF-CHECK A (axial): solid block must recover E_solid "
              "=====\n");
  VoxelGrid g;
  g.nx = g.ny = g.nz = 16;
  g.spacing = 1.0;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(16 * 16 * 16, VoxelTag::Interior);
  for (int axis = 0; axis < 3; ++axis) {
    SolveOut r = apparent_E(g, axis);
    std::printf("  axis %d: E_app=%.4f MPa  E_solid=%.1f  ratio=%.6f  cg=%d\n",
                axis, r.value, kE, r.value / kE, r.cg_iters);
  }
}

// Solid slender beam under the pure-bending BCs, several slenderness ratios, so
// the reader sees how close the trilinear-hex bending instrument gets to E_solid
// and how it depends on aspect ratio (shear + anticlastic-curvature discretization).
void self_check_bending(int vpc) {
  std::printf("\n===== SELF-CHECK B (bending): solid slender beam, vpc=%d "
              "=====\n", vpc);
  std::printf("  E_bend reported vs E_solid=%.0f; composite knockdown is "
              "normalized by the MATCHED solid E_bend below, so this bias "
              "cancels in the ratio.\n", kE);
  std::printf("  %-6s %-6s %-10s %-10s %-8s %-6s\n", "Kxy", "Kz", "Wx_mm",
              "E_bend", "ratio", "cg");
  FILE* csv = csv_open("Bself_bending.csv");
  if (csv) std::fprintf(csv, "Kxy,Kz,Wx_mm,E_bend,ratio,cg_iters\n");
  struct KK { int Kxy, Kz; };
  for (KK kk : {KK{1, 2}, KK{1, 4}, KK{1, 6}, KK{2, 4}, KK{2, 6}}) {
    Specimen s{kk.Kxy, kk.Kxy, kk.Kz, 1.5, 0.0, 0.0}; // level big => all solid
    VoxelGrid g = build_specimen(s, vpc);
    // force fully solid
    std::fill(g.tags.begin(), g.tags.end(), VoxelTag::Interior);
    SolveOut r = apparent_E_bending(g);
    std::printf("  %-6d %-6d %-10.1f %-10.4f %-8.5f %-6d\n", kk.Kxy, kk.Kz,
                kk.Kxy * kCellL, r.value, r.value / kE, r.cg_iters);
    if (csv)
      std::fprintf(csv, "%d,%d,%.1f,%.4f,%.6f,%d\n", kk.Kxy, kk.Kz,
                   kk.Kxy * kCellL, r.value, r.value / kE, r.cg_iters);
  }
  if (csv) std::fclose(csv);
}

// =============================================== M-AXIAL: member-scale composite
// 191's wall-and-core composite, directly resolved, at MEMBER widths. Every row
// carries width, wall-loop count, infill, phi_wall; reports assumed/measured
// (f^1.5 / E_meas, the gate error WITH SIGN) and the margin a part certified at
// EXACTLY 1.5 truly has at this member width (= 1.5 * E_meas / f^1.5).
void member_axial(const std::vector<int>& Ks, const std::vector<int>& loops_opts,
                  const std::vector<double>& infills, int vpc) {
  std::printf("\n===== M-AXIAL: wall+core MEMBER, DIRECT resolution, TENSION, "
              "vpc=%d (h=%.3f mm) =====\n", vpc, kCellL / vpc);
  std::printf("  walls=loops*%.2fmm on x/y perimeter (full-height columns), "
              "caps=%d*%.2fmm z-shells; load axis z\n",
              kLineWidth, kShellLayers, kLayerHeight);
  std::printf("  asm/meas = f^1.5 / E_meas (gate error, SIGN); margin@1.5 = "
              "1.5*E_meas/f^1.5 (true margin of a part the gate passes at 1.5)\n");
  std::printf("  %-4s %-6s %-6s %-7s %-8s %-10s %-8s %-9s %-8s %-10s\n", "K",
              "W_mm", "loops", "infill", "phi_wall", "E_meas/Es", "f^1.5",
              "asm/meas", "sign", "margin@1.5");
  FILE* csv = csv_open("M_axial.csv");
  if (csv)
    std::fprintf(csv, "K,W_mm,wall_loops,infill,phi_wall,E_meas_Es,f15,"
                      "assumed_over_meas,sign,margin_at_1p5,cg_iters,solve_ms\n");
  for (int K : Ks) {
    double W = K * kCellL;
    double t_cap = kShellLayers * kLayerHeight;
    for (double f : infills) {
      double level = calibrate_level(f, vpc);
      for (int loops : loops_opts) {
        double t_wall = loops * kLineWidth;
        Specimen s{K, K, K, level, t_wall, t_cap};
        double phi = loops == 0 ? 0.0 : measured_wall_fraction(s, vpc);
        VoxelGrid g = build_specimen(s, vpc);
        double t0 = now_ms();
        SolveOut r = apparent_E(g, 2);
        double ms = now_ms() - t0;
        double E = r.value / kE;
        double f15 = std::pow(f, 1.5);
        double asm_meas = f15 / E;
        const char* sign = E >= f15 ? "CONS" : "NON-CONS";
        double margin = 1.5 * E / f15;
        std::printf("  %-4d %-6.0f %-6d %-7.2f %-8.4f %-10.5f %-8.5f %-9.3f "
                    "%-8s %-10.3f\n",
                    K, W, loops, f, phi, E, f15, asm_meas, sign, margin);
        if (csv)
          std::fprintf(csv, "%d,%.1f,%d,%.2f,%.5f,%.6f,%.6f,%.4f,%s,%.4f,%d,%.0f\n",
                       K, W, loops, f, phi, E, f15, asm_meas, sign, margin,
                       r.cg_iters, ms);
      }
    }
  }
  if (csv) std::fclose(csv);
}

// ============================================ BEND-vs-AXIAL controlled comparison
// The SAME prismatic wall+core member cross-section (no z end caps), measured in
// BENDING (slender beam, Kz = slender*Kxy) and TENSION (Kz = Kxy cube; axial E is
// length-independent). Both knockdowns are normalized by a MATCHED SOLID solve of
// the same grid so the trilinear-hex bending bias cancels. Reports the gate error
// (f^1.5 / r) and SIGN for each mode side by side -- the task's item 2.
void bend_vs_axial(const std::vector<int>& Ks, const std::vector<int>& loops_opts,
                   const std::vector<double>& infills, int beam_cells, int vpc) {
  std::printf("\n===== BEND-vs-AXIAL: prismatic wall+core MEMBER (no caps), "
              "beam_len=%d cells (%.0f mm), vpc=%d (h=%.3f mm) =====\n",
              beam_cells, beam_cells * kCellL, vpc, kCellL / vpc);
  std::printf("  (bending stiffness is length-independent for a solid -- "
              "self-check B; fixed length bounds cost + averages the core)\n");
  std::printf("  r_axial, r_bend = stiffness relative to a MATCHED SOLID beam "
              "(same grid/BC), so discretization cancels.\n");
  std::printf("  gate error = f^1.5 / r (>1 NON-CONS, <1 CONS). Bending weights "
              "the outer walls by distance^2 -> expect MORE conservative.\n");
  std::printf("  %-4s %-6s %-6s %-7s %-8s %-9s %-9s %-9s %-9s %-9s %-9s\n", "K",
              "W_mm", "loops", "infill", "phi_wall", "r_axial", "asm/ax",
              "r_bend", "asm/bnd", "mgn@1.5ax", "mgn@1.5bnd");
  FILE* csv = csv_open("BendAxial.csv");
  if (csv)
    std::fprintf(csv, "K,W_mm,wall_loops,infill,phi_wall,f15,r_axial,"
                      "assumed_over_axial,margin_axial,r_bend,"
                      "assumed_over_bend,margin_bend,cg_axial,cg_bend,ms_bend\n");
  for (int K : Ks) {
    double W = K * kCellL;
    // Matched SOLID references (same grids), measured once per K.
    Specimen solid_cs{K, K, K, 1.5, 0.0, 0.0};
    VoxelGrid gsa = build_specimen(solid_cs, vpc);
    std::fill(gsa.tags.begin(), gsa.tags.end(), VoxelTag::Interior);
    double E_solid_axial = apparent_E(gsa, 2).value;
    Specimen solid_bm{K, K, beam_cells, 1.5, 0.0, 0.0};
    VoxelGrid gsb = build_specimen(solid_bm, vpc);
    std::fill(gsb.tags.begin(), gsb.tags.end(), VoxelTag::Interior);
    double E_solid_bend = apparent_E_bending(gsb).value;
    std::printf("  [K=%d matched solid: E_axial=%.2f  E_bend=%.2f MPa]\n", K,
                E_solid_axial, E_solid_bend);
    for (double f : infills) {
      double level = calibrate_level(f, vpc);
      for (int loops : loops_opts) {
        double t_wall = loops * kLineWidth;
        double phi = loops == 0
                         ? 0.0
                         : measured_wall_fraction(Specimen{K, K, K, level,
                                                           t_wall, 0.0}, vpc);
        double f15 = std::pow(f, 1.5);
        // axial on the cube cross-section (length-independent)
        Specimen ax{K, K, K, level, t_wall, 0.0};
        VoxelGrid ga = build_specimen(ax, vpc);
        SolveOut ra = apparent_E(ga, 2);
        double r_axial = ra.value / E_solid_axial;
        // bending on the slender beam, same cross-section
        Specimen bm{K, K, beam_cells, level, t_wall, 0.0};
        VoxelGrid gb = build_specimen(bm, vpc);
        double t0 = now_ms();
        SolveOut rb = apparent_E_bending(gb);
        double ms = now_ms() - t0;
        double r_bend = rb.value / E_solid_bend;
        double asm_ax = f15 / r_axial, asm_bn = f15 / r_bend;
        double mgn_ax = 1.5 * r_axial / f15, mgn_bn = 1.5 * r_bend / f15;
        std::printf("  %-4d %-6.0f %-6d %-7.2f %-8.4f %-9.5f %-9.3f %-9.5f "
                    "%-9.3f %-9.3f %-9.3f\n",
                    K, W, loops, f, phi, r_axial, asm_ax, r_bend, asm_bn, mgn_ax,
                    mgn_bn);
        if (csv)
          std::fprintf(csv, "%d,%.1f,%d,%.2f,%.5f,%.6f,%.6f,%.4f,%.4f,%.6f,%.4f,"
                            "%.4f,%d,%d,%.0f\n",
                       K, W, loops, f, phi, f15, r_axial, asm_ax, mgn_ax, r_bend,
                       asm_bn, mgn_bn, ra.cg_iters, rb.cg_iters, ms);
      }
    }
  }
  if (csv) std::fclose(csv);
}

} // namespace

int main() {
  std::printf("KNOCKDOWN MEMBER PROBE — member-scale + bending vs f^1.5 gate\n");
  std::printf("  E_solid=%.0f MPa  nu=%.2f  strain=%.0e  cell L=%.1f mm\n", kE,
              kNu, kStrain, kCellL);
  fea_set_matfree_threads(6);

  const char* only = std::getenv("TOPOPT_MEMBER_ONLY");
  std::string sel = only ? only : "";

  const int vpc_axial = 16; // 191's standard member resolution
  const int vpc_bend = 12;  // coarser; bending is wall-dominated + normalized

  self_check_axial();
  self_check_bending(vpc_bend);
  if (sel == "selfcheck") { std::printf("\n(selfcheck-only)\n"); return 0; }

  if (sel.empty() || sel == "axial") {
    // Member widths W in {5,10,15} mm (K=1,2,3), wall loops {0,3,5}, full band.
    member_axial({1, 2, 3}, {0, 3, 5}, kInfills, vpc_axial);
  }
  if (sel == "axial") { std::printf("\n(axial-only)\n"); return 0; }

  // Bending vs tension on the same prismatic member. K=2,3 (W=10,15 mm), a fixed
  // 6-cell (30 mm) beam length (bending stiffness is length-independent, self-
  // check B), three infills spanning the band, loops {0,3,5}.
  bend_vs_axial({2, 3}, {0, 3, 5}, {0.15, 0.30, 0.60}, 6, vpc_bend);

  std::printf("\nDONE.\n");
  return 0;
}
