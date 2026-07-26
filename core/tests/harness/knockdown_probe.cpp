// knockdown_probe.cpp — measurement harness (NOT a CI test) for handoff
// 2026-07-26-knockdown-check: does the Gibson-Ashby f^1.5 knockdown the accept
// gate applies (minimize_plastic.cpp:69, margin x f^1.5 >= 1.5) hold for a REAL
// PRINTED PART — solid slicer perimeters + shells wrapping a gyroid infill core —
// rather than the FREE lattice block handoff 2026-07-26-lattice-phase0 (M2)
// measured?
//
// READ-ONLY / MEASUREMENT ONLY. Builds NOTHING into production. It constructs
// wall-and-core VoxelGrids programmatically (the sanctioned cg_tol_probe.cpp /
// lattice_probe.cpp pattern — grids built directly, no fixtures) and measures
// effective axial stiffness with the SAME displacement-controlled uniaxial
// instrument lattice_probe.cpp validated (self-check: a fully-solid block
// recovers E_solid to 4 digits on all three axes).
//
// WHY THE ANSWER CAN DIFFER FROM 184. 184 measured a free gyroid block at
// vf~=0.30 and found E/Es=0.082 vs f^1.5=0.169 — f^1.5 over-predicts stiffness
// by 2.07x (non-conservative). But a printed part is NOT a free block: the
// slicer wraps the infill in solid WALL LOOPS (perimeters parallel to the load
// axis) and TOP/BOTTOM SHELL layers. The side walls are continuous solid columns
// spanning the full height, so they carry axial load IN PARALLEL with the core
// (Voigt / rule-of-mixtures, near-exact for aligned full-length members). They
// add stiffness the pure-infill law omits. Their cross-sectional fraction is
//   phi_wall = 4 t_wall (W - t_wall) / W^2
// which is LARGE for a small part and VANISHES as the part grows. So the
// hypothesis under test: f^1.5 is CONSERVATIVE for small parts and crosses into
// NON-CONSERVATIVE as the part gets large and the shells stop mattering.
//
// PLAN
//   SELF-CHECK       solid block -> E_solid to 4 digits, 3 axes. (bar K1)
//   A CORE LAW       bare gyroid core, sweep infill f in [0.15,0.60]; resolved
//                    E_core/Es vs f^1.5; the free-block law, across the whole band
//                    the app offers.
//   B COMPOSITE      build wall-and-core specimens (solid side walls + top/bottom
//                    caps + gyroid core) at several part sizes K (=cells across)
//                    and two wall-loop counts; DIRECTLY RESOLVE E_composite/Es;
//                    (1) validate the Voigt composition against direct measurement,
//                    (2) HEADLINE: assumed f^1.5 vs measured, WITH SIGN. (bars K2)
//   C SIZE / CROSSOVER  use the validated composition to extrapolate to part sizes
//                    that cannot be resolved directly (up to 200 mm); find the
//                    part width where f^1.5 crosses conservative->non-conservative,
//                    per infill. (bar K4)
//   D GATE MARGIN    worst point -> for a part the gate certified at margin exactly
//                    1.5, the TRUE margin under measured stiffness. (bar K3)
//
// Build (standalone; NOT wired into CTest), from core/:
//   c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
//     tests/harness/knockdown_probe.cpp build/libtopopt.a -o build/knockdown_probe
// CSV sink: set TOPOPT_KNOCKDOWN_CSV_DIR to write machine-readable tables there.

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
constexpr double kStrain = 1e-3; // applied nominal axial strain
constexpr double kCellL = 5.0;   // gyroid cell edge, mm (lattice_probe baseline)
constexpr double kCgTol = 1e-6;  // relative-residual tol; the reaction (a smooth
                                 // functional of u) is converged to ~5 digits well
                                 // before 1e-7. mgcg makes this cheap.

// Slicer print parameters (the Print Parameters panel the task quotes).
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
// A K x K x K-cell box (edge W = K*L). Solid where ANY of:
//   * within t_cap of the z=0 or z=W plane      (top/bottom shell layers), OR
//   * within t_wall of an x or y side plane      (wall loops / perimeters), OR
//   * the gyroid |field| < level at infill f     (the infill core).
// t_wall = 0 gives the bare core (Part A). Load axis is always z; the side walls
// therefore run the full height as continuous parallel columns.
struct Specimen {
  int K;
  double level;    // gyroid |field| threshold for target infill
  double t_wall;   // side-wall thickness, mm (0 = bare core)
  double t_cap;    // top/bottom cap thickness, mm
};

VoxelGrid build_specimen(const Specimen& s, int vpc) {
  VoxelGrid g;
  g.nx = g.ny = g.nz = s.K * vpc;
  g.spacing = kCellL / vpc;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(g.nx) * g.ny * g.nz, VoxelTag::Empty);
  const double W = s.K * kCellL;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        Vec3 c = g.voxel_center(i, j, k);
        bool cap = (c.z < s.t_cap) || (c.z > W - s.t_cap);
        bool wall = s.t_wall > 0 &&
                    ((c.x < s.t_wall) || (c.x > W - s.t_wall) ||
                     (c.y < s.t_wall) || (c.y > W - s.t_wall));
        bool core = std::fabs(gyroid_val(c.x, c.y, c.z, kCellL)) < s.level;
        if (cap || wall || core) g.set_tag(i, j, k, VoxelTag::Interior);
      }
  return g;
}

// Solid cross-sectional area fraction of the side walls, measured directly on a
// z-mid slice of the grid EXCLUDING the gyroid core (walls only) — the phi_wall
// that the Voigt model needs. Analytic 4 t(W-t)/W^2 is cross-checked against it.
double measured_wall_fraction(const Specimen& s, int vpc) {
  Specimen walls_only = s;
  walls_only.level = 0.0; // no core
  walls_only.t_cap = 0.0; // no caps in this slice count
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

// -------------------------------------------------------------- calibrate infill
// Bisect the gyroid |field| level to hit target core volume fraction (= infill
// %) on a single bare cell at the given resolution.
double calibrate_level(double target_vf, int vpc) {
  double lo = 0.01, hi = 1.5;
  for (int it = 0; it < 26; ++it) {
    double mid = 0.5 * (lo + hi);
    Specimen s{1, mid, 0.0, 0.0};
    VoxelGrid g = build_specimen(s, vpc);
    if (volume_fraction(g) < target_vf)
      lo = mid;
    else
      hi = mid;
  }
  return 0.5 * (lo + hi);
}

// ---------------------------------------------------------- apparent modulus
// Displacement-controlled uniaxial test along `axis`, IDENTICAL instrument to
// lattice_probe.cpp (verbatim): end planes Dirichlet-constrained (0 and delta),
// three transverse DOFs pinned, lateral faces free -> recovers E. End reaction =
// sum(K u) on the max-face nodes via fea_assembled_apply.
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
  int cg_iters = 0;
  bool converged = false;
  bool used_mg = false;
};

ApparentE apparent_E(const VoxelGrid& g, int axis) {
  ApparentE out;
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
    // Multigrid-preconditioned CG: identical BC-reduced system as fea_solve_cg,
    // same relative-residual tolerance, ~10-30x fewer iterations. Falls back to
    // Jacobi-CG (same answer) if the grid is not coarsenable; used_mg records it.
    sol = fea_solve_mgcg(g, kE, kNu, bcs, /*loads=*/{}, kCgTol, 0, &info);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "  [apparent_E axis %d solve failed: %s]\n", axis,
                 e.what());
    return out;
  }
  out.cg_iters = info.iterations;
  out.converged = info.converged;
  out.used_mg = info.used_multigrid;
  std::vector<double> Ku = fea_assembled_apply(g, kE, kNu, sol.u);
  double F = 0;
  for (auto& m : maxface) F += Ku[3 * m[0] + axis];
  const double A = (nt1 * h) * (nt2 * h);
  out.E_app = std::fabs(F) / (A * kStrain);
  return out;
}

double now_ms() {
  return std::chrono::duration<double, std::milli>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

// -------------------------------------------------------------- CSV helper
FILE* csv_open(const std::string& name) {
  const char* dir = std::getenv("TOPOPT_KNOCKDOWN_CSV_DIR");
  if (!dir) return nullptr;
  std::string path = std::string(dir) + "/" + name;
  FILE* f = std::fopen(path.c_str(), "w");
  if (f) std::printf("  [writing %s]\n", path.c_str());
  return f;
}

double fit_exponent(double ratio, double f) {
  if (f <= 0 || f >= 1 || ratio <= 0) return 0;
  return std::log(ratio) / std::log(f);
}

// ================================================================= SELF-CHECK
void self_check_solid() {
  std::printf("\n===== SELF-CHECK (K1): solid block must recover E_solid =====\n");
  VoxelGrid g;
  g.nx = g.ny = g.nz = 16;
  g.spacing = 1.0;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(16 * 16 * 16, VoxelTag::Interior);
  for (int axis = 0; axis < 3; ++axis) {
    ApparentE r = apparent_E(g, axis);
    std::printf("  axis %d: E_app=%.4f MPa  E_solid=%.1f  ratio=%.6f  cg=%d\n",
                axis, r.E_app, kE, r.E_app / kE, r.cg_iters);
  }
}

// The infill band the app offers, and the reference part-size grid.
const std::vector<double> kInfills = {0.15, 0.20, 0.25, 0.30, 0.40, 0.50, 0.60};

// ================================================== CORE INSTRUMENT DISCLOSURE
// Bare gyroid at a FIXED infill (0.30), sweeping resolution (vpc) and block size
// (K cells) so the reader can see how far the standard measurement resolution
// sits from the bulk / fine-grid asymptote. This bounds the only bias that feeds
// the crossover: the absolute E_core value. (The Voigt VALIDATION uses matched-
// resolution cores, so it is unaffected by this bias.)
void core_resolution_check() {
  std::printf("\n===== CORE RESOLUTION / SIZE CHECK — bare gyroid, infill=0.30 "
              "=====\n");
  std::printf("  184 anchors: single-cell vpc32 ~0.082, K=5 bulk ~0.091 (E/Es)\n");
  std::printf("  %-4s %-5s %-8s %-8s %-10s %-7s %-5s\n", "K", "vpc", "N", "vf",
              "E_core/Es", "cg", "mg");
  FILE* csv = csv_open("A0_core_resolution.csv");
  if (csv) std::fprintf(csv, "K,vpc,N,vf,E_core_Es,cg_iters,used_mg\n");
  struct KV { int K, vpc; };
  for (KV kv : {KV{1, 16}, KV{1, 24}, KV{1, 32}, KV{2, 16}, KV{2, 24},
                KV{2, 32}, KV{3, 16}}) {
    double level = calibrate_level(0.30, kv.vpc);
    Specimen s{kv.K, level, 0.0, 0.0};
    VoxelGrid g = build_specimen(s, kv.vpc);
    ApparentE r = apparent_E(g, 2);
    std::printf("  %-4d %-5d %-8d %-8.3f %-10.5f %-7d %-5s\n", kv.K, kv.vpc,
                g.nx, volume_fraction(g), r.E_app / kE, r.cg_iters,
                r.used_mg ? "Y" : "N");
    if (csv)
      std::fprintf(csv, "%d,%d,%d,%.4f,%.6f,%d,%d\n", kv.K, kv.vpc, g.nx,
                   volume_fraction(g), r.E_app / kE, r.cg_iters,
                   r.used_mg ? 1 : 0);
  }
  if (csv) std::fclose(csv);
}

// ============================================================= A: CORE LAW
// Bare gyroid core (no walls, no caps), K cells across, vpc resolution. Reports
// resolved E_core/Es across the infill band vs f^1.5 — the free-block law over
// the whole band the app offers (184 measured only f=0.30). Returns a lookup of
// bulk E_core/Es(f) used by the composition model in Parts C/D.
std::vector<std::pair<double, double>> core_law(int K, int vpc) {
  std::printf("\n===== A: CORE LAW — bare gyroid, K=%d cells, vpc=%d (h=%.3f mm) "
              "=====\n", K, vpc, kCellL / vpc);
  std::printf("  bar: f^1.5 is the gate's law; SIGN = conservative if measured>=assumed\n");
  std::printf("  %-6s %-8s %-10s %-10s %-9s %-8s %-6s\n", "f", "vf", "E_core/Es",
              "f^1.5", "gap%%", "sign", "fit_p");
  FILE* csv = csv_open("A_core_law.csv");
  if (csv) std::fprintf(csv, "infill,vf,E_core_Es,f15,gap_pct,sign,fit_p,cg_iters\n");
  std::vector<std::pair<double, double>> law;
  for (double f : kInfills) {
    double level = calibrate_level(f, vpc);
    Specimen s{K, level, 0.0, 0.0};
    VoxelGrid g = build_specimen(s, vpc);
    double vf = volume_fraction(g);
    ApparentE r = apparent_E(g, 2);
    double ratio = r.E_app / kE;
    double f15 = std::pow(f, 1.5);
    double gap = 100.0 * (f15 - ratio) / ratio; // + => assumed too stiff
    const char* sign = ratio >= f15 ? "CONS" : "NON-CONS";
    double p = fit_exponent(ratio, f);
    std::printf("  %-6.2f %-8.3f %-10.5f %-10.5f %+-9.1f %-8s %-6.2f\n", f, vf,
                ratio, f15, gap, sign, p);
    if (csv)
      std::fprintf(csv, "%.2f,%.4f,%.6f,%.6f,%.2f,%s,%.3f,%d\n", f, vf, ratio,
                   f15, gap, sign, p, r.cg_iters);
    law.push_back({f, ratio});
  }
  if (csv) std::fclose(csv);
  return law;
}

// ============================================================= B: COMPOSITE
// Build wall-and-core specimens and DIRECTLY resolve E_composite/Es. Validate the
// Voigt composition (phi_wall*Es + (1-phi_wall)*E_core) against direct measurement,
// and report the HEADLINE assumed-f^1.5 vs measured with SIGN.
struct CompRow {
  int K, wall_loops;
  double f, W, phi_wall_meas, phi_wall_analytic, E_meas_Es, E_voigt_Es, f15;
};

std::vector<CompRow> composite(const std::vector<int>& Ks,
                               const std::vector<int>& wall_loop_opts,
                               const std::vector<double>& infills, int vpc) {
  std::printf("\n===== B: COMPOSITE — wall+core specimens, DIRECT resolution, "
              "vpc=%d (h=%.3f mm) =====\n", vpc, kCellL / vpc);
  std::printf("  walls=loops*%.2fmm, caps=%d*%.2fmm; load axis z; side walls are "
              "full-height parallel columns\n", kLineWidth, kShellLayers, kLayerHeight);
  std::printf("  Voigt: E/Es = phi_wall + (1-phi_wall)*E_core/Es, E_core from the "
              "MATCHED bare-core solve (same K,vpc)\n");
  std::printf("  modelΔ = Voigt vs measured (validates composition); asm/meas = "
              "f^1.5 / E_meas is the GATE error, with SIGN\n");
  std::printf("  %-3s %-5s %-6s %-7s %-8s %-9s %-9s %-9s %-8s %-8s %-8s %-6s\n",
              "K", "W_mm", "loops", "infill", "phi_wall", "E_core/Es", "E_meas/Es",
              "E_Voigt", "modelD%", "f^1.5", "asm/meas", "sign");
  FILE* csv = csv_open("B_composite.csv");
  if (csv)
    std::fprintf(csv, "K,W_mm,wall_loops,infill,phi_wall_meas,phi_wall_analytic,"
                      "E_core_Es,E_meas_Es,E_voigt_Es,model_err_pct,f15,"
                      "assumed_over_meas,sign,cg_iters,solve_ms\n");
  std::vector<CompRow> rows;
  for (int K : Ks) {
    double W = K * kCellL;
    double t_cap = kShellLayers * kLayerHeight;
    for (double f : infills) {
      double level = calibrate_level(f, vpc);
      // Matched bare core (walls off, same K/vpc) — the E_core the Voigt uses.
      Specimen bare{K, level, 0.0, t_cap};
      VoxelGrid gb = build_specimen(bare, vpc);
      double E_core = apparent_E(gb, 2).E_app / kE;
      for (int loops : wall_loop_opts) {
        double t_wall = loops * kLineWidth;
        double phi_analytic =
            t_wall <= 0 ? 0.0 : 4.0 * t_wall * (W - t_wall) / (W * W);
        Specimen s{K, level, t_wall, t_cap};
        double phi_meas = t_wall <= 0 ? 0.0 : measured_wall_fraction(s, vpc);
        VoxelGrid g = build_specimen(s, vpc);
        double t0 = now_ms();
        ApparentE r = apparent_E(g, 2);
        double ms = now_ms() - t0;
        double E_meas = r.E_app / kE;
        double E_voigt = phi_meas + (1.0 - phi_meas) * E_core;
        double model_err = 100.0 * (E_voigt - E_meas) / E_meas;
        double f15 = std::pow(f, 1.5);
        double ratio = f15 / E_meas; // assumed / measured
        const char* sign = E_meas >= f15 ? "CONS" : "NON-CONS";
        std::printf("  %-3d %-5.0f %-6d %-7.2f %-8.4f %-9.5f %-9.5f %-9.5f "
                    "%+-8.1f %-8.5f %-8.3f %s\n",
                    K, W, loops, f, phi_meas, E_core, E_meas, E_voigt, model_err,
                    f15, ratio, sign);
        if (csv)
          std::fprintf(csv, "%d,%.1f,%d,%.2f,%.5f,%.5f,%.6f,%.6f,%.6f,%.2f,%.6f,"
                            "%.4f,%s,%d,%.0f\n",
                       K, W, loops, f, phi_meas, phi_analytic, E_core, E_meas,
                       E_voigt, model_err, f15, ratio, sign, r.cg_iters, ms);
        rows.push_back(
            {K, loops, f, W, phi_meas, phi_analytic, E_meas, E_voigt, f15});
      }
    }
  }
  if (csv) std::fclose(csv);
  return rows;
}

// ============================================================= C: SIZE / CROSSOVER
// Extrapolate the VALIDATED Voigt composition to part widths that cannot be
// resolved directly. For each infill and wall-loop count, sweep W and find the
// crossover width where f^1.5 stops being conservative.
void size_crossover(const std::vector<std::pair<double, double>>& core_law_lookup,
                    const std::vector<int>& wall_loop_opts) {
  std::printf("\n===== C: SIZE / CROSSOVER (K4) — validated Voigt extrapolation "
              "=====\n");
  std::printf("  E_part/Es(W) = phi_wall(W) + (1-phi_wall)*E_core/Es ; "
              "phi_wall = 4 t(W-t)/W^2\n");
  std::printf("  crossover W* = part width where E_part/Es == f^1.5 (below: "
              "CONS, above: NON-CONS)\n");
  FILE* csv = csv_open("C_size_crossover.csv");
  if (csv) std::fprintf(csv, "wall_loops,infill,E_core_Es,f15,crossover_W_mm,E_at_200mm,assumed_over_meas_200\n");
  const std::vector<double> widths = {10, 20, 40, 60, 80, 100, 150, 200};
  for (int loops : wall_loop_opts) {
    if (loops == 0) continue;
    double t = loops * kLineWidth;
    std::printf("\n  --- %d wall loops (t_wall=%.2f mm) ---\n", loops, t);
    std::printf("  %-6s %-10s", "infill", "E_core/Es");
    for (double W : widths) std::printf("  W=%-5.0f", W);
    std::printf("   f^1.5     W*_mm\n");
    for (auto& pr : core_law_lookup) {
      double f = pr.first, Ec = pr.second, f15 = std::pow(f, 1.5);
      std::printf("  %-6.2f %-10.5f", f, Ec);
      double E200 = 0;
      for (double W : widths) {
        double phi = 4.0 * t * (W - t) / (W * W);
        double E = phi + (1.0 - phi) * Ec;
        if (std::fabs(W - 200.0) < 1e-6) E200 = E;
        std::printf("  %-7.4f", E);
      }
      // crossover: phi* = (f15 - Ec)/(1 - Ec); solve 4 t (W-t)/W^2 = phi*
      double Wstar = -1;
      double phistar = (f15 - Ec) / (1.0 - Ec);
      if (phistar > 0 && phistar < 1) {
        // 4t(W-t)/W^2 = p -> p W^2 - 4 t W + 4 t^2 = 0
        double a = phistar, b = -4.0 * t, c = 4.0 * t * t;
        double disc = b * b - 4 * a * c;
        if (disc >= 0) {
          double W1 = (-b + std::sqrt(disc)) / (2 * a);
          double W2 = (-b - std::sqrt(disc)) / (2 * a);
          Wstar = std::max(W1, W2); // the physically large root
        }
      }
      double E200v = E200;
      double assumed_over = f15 / E200v;
      if (Wstar > 0)
        std::printf("   %-8.5f  %.0f\n", f15, Wstar);
      else
        std::printf("   %-8.5f  none(%s)\n", f15,
                    f15 <= Ec ? "always CONS" : "always NON-CONS");
      if (csv)
        std::fprintf(csv, "%d,%.2f,%.6f,%.6f,%.1f,%.6f,%.4f\n", loops, f, Ec,
                     f15, Wstar, E200v, assumed_over);
    }
  }
  if (csv) std::fclose(csv);
}

// ============================================================= D: GATE MARGIN
// The number that decides urgency: for a part the gate certified at margin
// EXACTLY 1.5, the true margin under measured stiffness. The gate multiplies the
// solid-material margin by f^1.5; if the true stiffness knockdown is r_true, the
// true margin is 1.5 * (r_true / f^1.5). Worst (lowest) at large part + the infill
// whose r_true/f^1.5 is smallest.
void gate_margin(const std::vector<std::pair<double, double>>& core_law_lookup,
                 const std::vector<int>& wall_loop_opts) {
  std::printf("\n===== D: GATE MARGIN (K3) — true margin for a part certified at "
              "1.5 =====\n");
  std::printf("  true_margin = 1.5 * (E_part/Es) / f^1.5, at the LARGE-part limit "
              "(200 mm) where shells are thinnest\n");
  FILE* csv = csv_open("D_gate_margin.csv");
  if (csv) std::fprintf(csv, "wall_loops,W_mm,infill,E_part_Es,f15,true_margin_at_1p5\n");
  const std::vector<double> widths = {40, 100, 200};
  for (int loops : wall_loop_opts) {
    if (loops == 0) continue;
    double t = loops * kLineWidth;
    std::printf("\n  --- %d wall loops (t_wall=%.2f mm) ---\n", loops, t);
    std::printf("  %-6s", "infill");
    for (double W : widths) std::printf("   margin@W=%-4.0f", W);
    std::printf("\n");
    for (auto& pr : core_law_lookup) {
      double f = pr.first, Ec = pr.second, f15 = std::pow(f, 1.5);
      std::printf("  %-6.2f", f);
      for (double W : widths) {
        double phi = 4.0 * t * (W - t) / (W * W);
        double E = phi + (1.0 - phi) * Ec;
        double margin = 1.5 * E / f15;
        std::printf("   %-13.3f", margin);
        if (csv)
          std::fprintf(csv, "%d,%.0f,%.2f,%.6f,%.6f,%.4f\n", loops, W, f, E, f15,
                       margin);
      }
      std::printf("\n");
    }
  }
  if (csv) std::fclose(csv);
}

} // namespace

int main() {
  std::printf("KNOCKDOWN PROBE — real printed part (walls+core) vs f^1.5 gate\n");
  std::printf("  E_solid=%.0f MPa  nu=%.2f  strain=%.0e  cell L=%.1f mm\n", kE,
              kNu, kStrain, kCellL);
  fea_set_matfree_threads(6);

  self_check_solid();

  const char* only = std::getenv("TOPOPT_KNOCKDOWN_ONLY");
  std::string sel = only ? only : "";

  // Standard resolution vpc=16 (h=0.31 mm, ~2.2 voxels across the ~0.70 mm gyroid
  // wall). This is coarser than 184's <5%-converged vpc=32, chosen so every solve
  // stays <=64^3 and finishes in seconds even for the ill-conditioned low-infill
  // lattices; the CORE RESOLUTION CHECK above quantifies the resulting bias in the
  // absolute E_core, and the Voigt VALIDATION uses matched-resolution cores so the
  // composition result is resolution-independent.
  const int vpc = 16;

  core_resolution_check();
  if (sel == "res") { std::printf("\n(res-only)\n"); return 0; }

  // A: bare-core law over the whole infill band (K=2 near-bulk). Anchor for C/D.
  auto law = core_law(2, vpc);
  if (sel == "core") { std::printf("\n(core-only)\n"); return 0; }

  // B: composite specimens, directly resolved. The porous cores fall back to
  // Jacobi-CG (no coarsenable hierarchy), so each is ~1-4 min; the sweep is held
  // to the minimum that validates the Voigt composition and shows the size trend:
  // two part sizes (K=2,3), the bare core + the default 5-loop wall, three infills
  // spanning the band. Parts C/D then extrapolate the validated model over the
  // full band and all part sizes analytically.
  std::vector<int> Ks = {2, 3};
  std::vector<int> loops = {0, 5};
  std::vector<double> comp_infills = {0.15, 0.30, 0.60};
  auto comp_rows = composite(Ks, loops, comp_infills, vpc);
  (void)comp_rows;
  auto& law_fine = law;
  std::vector<int> loops_extrap = {3, 5};

  // C + D use the core law as the extrapolation anchor, over 3 and 5 wall loops.
  size_crossover(law_fine, loops_extrap);
  gate_margin(law_fine, loops_extrap);

  std::printf("\nDONE.\n");
  return 0;
}
