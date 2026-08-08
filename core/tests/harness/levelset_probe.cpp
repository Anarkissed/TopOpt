// levelset_probe — S1/S2/S3 of task 2026-08-09-levelset-on-our-solver.
//
// A WORKING LEVEL-SET TOPOLOGY OPTIMIZER driven by OUR OWN matrix-free solver,
// in a sandbox target. Nothing in core/src or core/include changes; the shipped
// SIMP path is untouched.
//
//   cmake --build build --target levelset_probe
//   ./build/levelset_probe <part.step> <materials.json> <ref_design.bin> <out_dir>
//        [--rung 0.68] [--iters 80] [--eta 1.0] [--cfl 0.4] [--smooth 4]
//        [--seed simp|holes] [--fp32] [--reinit-every 1]
//
// ── WHY THIS EXISTS ─────────────────────────────────────────────────────────
//
// PR 321 measured GridapTopOpt's level set at 4.0156 deg cut-population dihedral
// RMS against SIMP's 7.5521 deg on his rung 0.68 — 46.9% smoother, the first win
// in six attempts — and proved it was the REPRESENTATION and not a blur (the win
// survives a half-voxel ersatz band, its CTRL-eta0.5 arm). It also measured
// 277.7 s per iteration against SIMP's 11.2 s. That 25x is Gridap being a
// general-purpose unstructured FEM library, not a cost of the level set: the
// physics is identical either way — same grid, same trilinear hexes, same ersatz
// densities. A level set changes WHAT THE DESIGN VARIABLE IS, not what the FEA
// does. This program finds out what it actually costs on our solver by being it.
//
// ── THE ONE RULE THIS FILE OBEYS ────────────────────────────────────────────
//
// ★ IT WRITES NO FEA. `simp_compliance` runs every state solve and
// `analyze_fixed_design` runs the certification — the same two calls the shipped
// ladder makes, on the same matrix-free operator, at the same tolerances. What
// is new here is only the DESIGN VARIABLE in front of them: a scalar phi whose
// zero level set is the boundary, in place of a density the optimality criterion
// updates voxel by voxel.
//
// The problem itself is not re-derived either. `build_production_loadcase` — the
// same builder `topopt-cli run` and the iPad bridge both call — supplies the
// grid, the tags, the clamped DOFs and the nodal loads, exactly as
// `portable_problem_export` does for the bakeoff. Every voxel tag and every load
// is core's own, byte for byte.
//
// ── THE SIX PIECES ──────────────────────────────────────────────────────────
//
//  (a) phi          a scalar on his grid (128 x 31 x 118), signed distance, mm,
//                   NEGATIVE INSIDE the material. Seeded from his own converged
//                   SIMP rung (`--seed simp`, the default) or from a regular
//                   array of holes (`--seed holes`).
//  (b) ersatz rho   rho = rho_min + (1 - rho_min) * H_eta(-phi), the C1 smoothed
//                   Heaviside over a band eta (DEFAULT 1 VOXEL — PR 321 measured
//                   the win surviving at half a voxel, so a narrow band is not a
//                   risk). rho(phi = 0) = 0.5 exactly, which is the iso every
//                   downstream instrument already reads.
//  (c) shape deriv  the velocity is the per-element strain energy density,
//                   negated into a growth direction, plus the volume multiplier.
//                   `simp_compliance` already returns dc/drho_e per voxel; the
//                   energy is recovered from it algebraically (see `energy_from`
//                   below). Nothing exotic is derived.
//  (d) extension    the velocity is extended off the interface by separable
//                   [1 2 1]/4 smoothing passes (`--smooth`, default 4). The
//                   fallback the task names, and it is good enough.
//  (e) advection    explicit upwind Hamilton-Jacobi, phi <- phi - dt * v * |grad
//                   phi| with the Godunov gradient, CFL-limited on dt.
//  (f) reinit       fast sweeping to |grad phi| = 1, 8 sweeps in 3D. ★ THIS IS
//                   THE PIECE THAT MAKES IT COHERENT. PR 319 established that
//                   sub-voxel content is worthless unless it is spatially
//                   COHERENT, and PR 321 measured a signed distance function
//                   delivering exactly that (2.35-7.20% of crossings at an edge
//                   midpoint against SIMP's 85-99%). It is not skipped, and its
//                   own control arm in PR 321 (CTRL-EDT-noreinit) is what says
//                   so.
//  (g) volume       a constant offset on phi, bisected each iteration until the
//                   ersatz volume hits the rung's target. Robust, monotone by
//                   construction (phi is a signed distance, so raising the
//                   offset can only shrink the solid), and there is no
//                   Lagrangian to tune. The task names this as the fallback and
//                   as probably the right choice; it is what runs.
//
// ── WHAT THE MASK DOES, AND WHY IT IS NOT PART OF THE LEVEL SET ─────────────
//
// His job freezes material: the Load/Fixture pad and face protection 16 are
// FrozenSolid, and Empty voxels (outside the CAD) are FrozenVoid. Those are
// constraints on the OBJECT, not on the representation, so they are applied when
// phi is turned into rho and not by deforming phi:
//
//     FrozenSolid -> rho = 1        FrozenVoid / Empty -> rho = rho_min
//
// exactly as the shipped mask-aware SIMP path composes them (pipeline
// effective_mask). The velocity is zeroed there too, so the flow does not spend
// itself pushing against a wall it cannot move. This is also what keeps the
// extracted surface clipped to his CAD, so PR 307's classifier sees the same
// CAD/cut split it sees on a SIMP design and the roughness rows are comparable.
//
// ── PENALTY 3, DELIBERATELY ─────────────────────────────────────────────────
//
// The ersatz band is fed through the PRODUCTION SimpParams (penalty 3,
// density_min 1e-3), not a linear interpolation, so the trajectory solve and the
// certification solve are the same law the shipped ladder uses and the margin
// row is comparable to SIMP's. A band voxel at rho = 0.5 is therefore stiffness
// 0.125 rather than 0.5 — a systematic sub-voxel thinning of the interface, one
// band wide, and a bias that is stated rather than hidden. It is not an
// instability: the volume target is met on the ersatz measure regardless.
//
// ── S1, MIXED PRECISION ─────────────────────────────────────────────────────
//
// `--fp32` calls `fea_set_matfree_mixed_precision(true)`. The capability shipped
// complete in handoff 092 and is opt-in; nothing production-side has ever called
// the setter, which is why `run_info` honestly echoes mixed_precision:false. It
// is armed HERE, on the sandbox path only — no production file changes.
//
// ★ WHAT IT CAN AND CANNOT REACH, STATED UP FRONT so the number is read
// correctly. FP32 in this codebase is the V-CYCLE PRECONDITIONER: the fine
// apply, the Jacobi smoother, restriction and prolongation. The OUTER CG stays
// FP64 by design (residual, dot products, x/r/p, the convergence test), and so
// does the coarse direct solve. So on a run where the multigrid hierarchy never
// engages, arming the flag is a genuine no-op — and his part is exactly such a
// run: his `run_info.json` records `cg_multigrid: false`, `mg_levels: 0`,
// `mg_mode: "stagnated-latched"`. This program therefore REPORTS the V-cycle's
// engagement (`solves_multigrid` in the CSV and the summary) beside the wall
// time, so "FP32 made no difference" can be distinguished from "FP32 was never
// asked to do anything". Reporting which one it was is the honest S1.
//
// ── WHAT COMES OUT ──────────────────────────────────────────────────────────
//
//   iterations.csv   per iteration: compliance, volume, offset, dt, |v|, CG
//                    iterations, multigrid engagement, wall split
//   design.bin       the final design, in the shipped container, so
//                    `design_rung_dump --stl` and every viewer can read it
//   rho.f64          the final ersatz occupancy as raw float64, x-fastest
//   rho.meta         its lattice/spacing/origin/iso, for
//                    `external_field_surface_probe` — so the roughness row is
//                    produced by the SAME binary that produced PR 321's, and is
//                    INCLUDED rather than retyped (R2)
//   summary.txt      the three numbers section 0 of the handoff states

#include "topopt/analyze.hpp"
#include "topopt/design_store.hpp"
#include "topopt/face_overrides.hpp"
#include "topopt/fea.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/production.hpp"
#include "topopt/report.hpp"
#include "topopt/simp.hpp"
#include "topopt/step.hpp"
#include "topopt/stl.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <limits>
#include <string>
#include <vector>

using namespace topopt;

namespace {

constexpr double kPi = 3.14159265358979323846;
// Larger than any distance on his part (the grid is ~218 x 53 x 201 mm), so an
// unreached cell is unambiguously "far" and the sweep's min() always improves.
constexpr double kFar = 1e30;

double now_s() {
  return std::chrono::duration<double>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

// ── the grid index, x-fastest then y then z: core's own ordering ────────────
struct Dims {
  int nx = 0, ny = 0, nz = 0;
  std::size_t at(int i, int j, int k) const {
    return static_cast<std::size_t>(i) +
           static_cast<std::size_t>(nx) *
               (static_cast<std::size_t>(j) +
                static_cast<std::size_t>(ny) * static_cast<std::size_t>(k));
  }
  std::size_t count() const {
    return static_cast<std::size_t>(nx) * static_cast<std::size_t>(ny) *
           static_cast<std::size_t>(nz);
  }
};

// ── (b) THE SMOOTHED HEAVISIDE ──────────────────────────────────────────────
// C1, compactly supported on [-eta, eta], H(0) = 0.5 exactly. `s` is -phi, so
// s > 0 is inside the material.
double heaviside(double s, double eta) {
  if (s <= -eta) return 0.0;
  if (s >= eta) return 1.0;
  return 0.5 * (1.0 + s / eta + std::sin(kPi * s / eta) / kPi);
}

// ── (f) REINITIALISATION: fast sweeping for the Eikonal |grad d| = 1 ────────
//
// The Godunov update at one cell, given the smallest |d| already known across
// each axis. Standard 3D form: try the 1-D solution, and only bring in the
// second and third axes when the candidate overtakes them.
double eikonal_update(double a, double b, double c, double h) {
  // sort ascending
  if (a > b) std::swap(a, b);
  if (b > c) std::swap(b, c);
  if (a > b) std::swap(a, b);

  double x = a + h;
  if (x <= b) return x;

  // two-axis solution
  const double s2 = 2.0 * h * h - (a - b) * (a - b);
  if (s2 < 0.0) return x;  // no real two-axis root; keep the one-axis value
  x = 0.5 * (a + b + std::sqrt(s2));
  if (x <= c) return x;

  // three-axis solution
  const double sum = a + b + c;
  const double disc = sum * sum - 3.0 * (a * a + b * b + c * c - h * h);
  if (disc < 0.0) return x;
  return (sum + std::sqrt(disc)) / 3.0;
}

// Fill |phi| by fast sweeping, holding the cells flagged in `frozen` (the
// interface band) at the values they already carry. 8 sweep directions in 3D,
// `passes` times over the whole set of 8.
void fast_sweep(const Dims& d, std::vector<double>& mag,
                const std::vector<char>& frozen, double h, int passes) {
  const int dirs[8][3] = {{1, 1, 1},   {-1, 1, 1},  {1, -1, 1},  {-1, -1, 1},
                          {1, 1, -1},  {-1, 1, -1}, {1, -1, -1}, {-1, -1, -1}};
  for (int p = 0; p < passes; ++p) {
    for (const auto& dir : dirs) {
      const int i0 = dir[0] > 0 ? 0 : d.nx - 1, i1 = dir[0] > 0 ? d.nx : -1;
      const int j0 = dir[1] > 0 ? 0 : d.ny - 1, j1 = dir[1] > 0 ? d.ny : -1;
      const int k0 = dir[2] > 0 ? 0 : d.nz - 1, k1 = dir[2] > 0 ? d.nz : -1;
      for (int k = k0; k != k1; k += dir[2])
        for (int j = j0; j != j1; j += dir[1])
          for (int i = i0; i != i1; i += dir[0]) {
            const std::size_t v = d.at(i, j, k);
            if (frozen[v]) continue;
            // The domain boundary is an OPEN boundary, not a wall: an
            // out-of-range neighbour contributes no constraint (kFar), so the
            // distance is measured to the interface and never to the box.
            const double ax =
                std::min(i > 0 ? mag[d.at(i - 1, j, k)] : kFar,
                         i + 1 < d.nx ? mag[d.at(i + 1, j, k)] : kFar);
            const double ay =
                std::min(j > 0 ? mag[d.at(i, j - 1, k)] : kFar,
                         j + 1 < d.ny ? mag[d.at(i, j + 1, k)] : kFar);
            const double az =
                std::min(k > 0 ? mag[d.at(i, j, k - 1)] : kFar,
                         k + 1 < d.nz ? mag[d.at(i, j, k + 1)] : kFar);
            const double cand = eikonal_update(ax, ay, az, h);
            if (cand < mag[v]) mag[v] = cand;
          }
    }
  }
}

// Re-make `phi` a signed distance, keeping its SIGN and its zero set. The band
// is pinned first by linear interpolation of phi's own crossings — so the
// interface does not drift while it is being re-distanced — and the sweep fills
// outward from there.
void reinitialise(const Dims& d, std::vector<double>& phi, double h, int passes) {
  const std::size_t n = d.count();
  std::vector<char> frozen(n, 0);
  std::vector<double> mag(n, kFar);

  for (int k = 0; k < d.nz; ++k)
    for (int j = 0; j < d.ny; ++j)
      for (int i = 0; i < d.nx; ++i) {
        const std::size_t v = d.at(i, j, k);
        const double pv = phi[v];
        double best = kFar;
        const int off[6][3] = {{-1, 0, 0}, {1, 0, 0}, {0, -1, 0},
                               {0, 1, 0},  {0, 0, -1}, {0, 0, 1}};
        for (const auto& o : off) {
          const int ii = i + o[0], jj = j + o[1], kk = k + o[2];
          if (ii < 0 || ii >= d.nx || jj < 0 || jj >= d.ny || kk < 0 ||
              kk >= d.nz)
            continue;
          const double pw = phi[d.at(ii, jj, kk)];
          if ((pv > 0.0) == (pw > 0.0)) continue;  // no crossing on this edge
          const double denom = std::fabs(pv) + std::fabs(pw);
          // A crossing with both ends at zero carries no sub-voxel information;
          // half a cell is the only defensible reading of it.
          const double t = denom > 0.0 ? std::fabs(pv) / denom : 0.5;
          best = std::min(best, t * h);
        }
        if (best < kFar) {
          frozen[v] = 1;
          mag[v] = best;
        }
      }

  fast_sweep(d, mag, frozen, h, passes);

  for (std::size_t v = 0; v < n; ++v)
    phi[v] = (phi[v] > 0.0 ? 1.0 : -1.0) * (mag[v] >= kFar ? 1e6 : mag[v]);
}

// ── (d) VELOCITY EXTENSION: separable [1 2 1]/4, `passes` times ─────────────
void smooth_field(const Dims& d, std::vector<double>& f, int passes) {
  std::vector<double> tmp(f.size());
  for (int p = 0; p < passes; ++p) {
    // x
    for (int k = 0; k < d.nz; ++k)
      for (int j = 0; j < d.ny; ++j)
        for (int i = 0; i < d.nx; ++i) {
          const double a = f[d.at(i > 0 ? i - 1 : 0, j, k)];
          const double b = f[d.at(i, j, k)];
          const double c = f[d.at(i + 1 < d.nx ? i + 1 : d.nx - 1, j, k)];
          tmp[d.at(i, j, k)] = 0.25 * (a + 2.0 * b + c);
        }
    f.swap(tmp);
    // y
    for (int k = 0; k < d.nz; ++k)
      for (int j = 0; j < d.ny; ++j)
        for (int i = 0; i < d.nx; ++i) {
          const double a = f[d.at(i, j > 0 ? j - 1 : 0, k)];
          const double b = f[d.at(i, j, k)];
          const double c = f[d.at(i, j + 1 < d.ny ? j + 1 : d.ny - 1, k)];
          tmp[d.at(i, j, k)] = 0.25 * (a + 2.0 * b + c);
        }
    f.swap(tmp);
    // z
    for (int k = 0; k < d.nz; ++k)
      for (int j = 0; j < d.ny; ++j)
        for (int i = 0; i < d.nx; ++i) {
          const double a = f[d.at(i, j, k > 0 ? k - 1 : 0)];
          const double b = f[d.at(i, j, k)];
          const double c = f[d.at(i, j, k + 1 < d.nz ? k + 1 : d.nz - 1)];
          tmp[d.at(i, j, k)] = 0.25 * (a + 2.0 * b + c);
        }
    f.swap(tmp);
  }
}

// ── (e) ADVECTION: the Godunov gradient magnitude for phi_t + v|grad phi| = 0 ─
//
// Upwinding follows the SIGN OF v, which is what makes the scheme stable: an
// outward-moving interface reads the gradient from the side it is moving into.
double godunov_grad(const Dims& d, const std::vector<double>& phi, int i, int j,
                    int k, double v, double h) {
  const std::size_t c = d.at(i, j, k);
  const double p = phi[c];
  const double dxm = (p - phi[d.at(i > 0 ? i - 1 : 0, j, k)]) / h;
  const double dxp = (phi[d.at(i + 1 < d.nx ? i + 1 : d.nx - 1, j, k)] - p) / h;
  const double dym = (p - phi[d.at(i, j > 0 ? j - 1 : 0, k)]) / h;
  const double dyp = (phi[d.at(i, j + 1 < d.ny ? j + 1 : d.ny - 1, k)] - p) / h;
  const double dzm = (p - phi[d.at(i, j, k > 0 ? k - 1 : 0)]) / h;
  const double dzp = (phi[d.at(i, j, k + 1 < d.nz ? k + 1 : d.nz - 1)] - p) / h;

  auto sq = [](double x) { return x * x; };
  double g2 = 0.0;
  if (v > 0.0) {
    g2 += sq(std::max(dxm, 0.0)) + sq(std::min(dxp, 0.0));
    g2 += sq(std::max(dym, 0.0)) + sq(std::min(dyp, 0.0));
    g2 += sq(std::max(dzm, 0.0)) + sq(std::min(dzp, 0.0));
  } else {
    g2 += sq(std::min(dxm, 0.0)) + sq(std::max(dxp, 0.0));
    g2 += sq(std::min(dym, 0.0)) + sq(std::max(dyp, 0.0));
    g2 += sq(std::min(dzm, 0.0)) + sq(std::max(dzp, 0.0));
  }
  return std::sqrt(g2);
}

// ── (c) THE SHAPE DERIVATIVE, recovered from the sensitivity core returns ───
//
// `simp_compliance` documents dc/drho_e = -p * rho_e^(p-1) * E0 * (u_e^T K_unit
// u_e), so the element strain energy on the UNIT-modulus element is
//
//     u_e^T K_unit u_e = -(dc/drho_e) / (p * rho_e^(p-1) * E0)
//
// which is the per-element strain energy density the shape derivative wants, up
// to the constant element volume. It is READ OFF the shipped sensitivity rather
// than recomputed, so there is no second definition of the energy in this file.
//
// The divisor is clamped away from the void floor: at rho = rho_min = 1e-3 the
// numerator is already ~1e-6 of solid and the quotient is a ratio of two
// vanishing numbers with no information in it. Clamping at 0.1 leaves the whole
// interface band (rho ~ 0.5) untouched and turns the void into a clean zero
// instead of numerical noise that the smoothing would then spread.
double energy_from(double dc, double rho, double p, double e0) {
  const double r = std::max(rho, 0.1);
  return -dc / (p * std::pow(r, p - 1.0) * e0);
}

struct Args {
  std::string step, materials, ref_design, out;
  double rung = 0.68;
  int iters = 80;
  double eta_voxels = 1.0;
  double cfl = 0.4;
  int smooth = 4;
  std::string seed = "simp";
  bool fp32 = false;
  bool isolate = false;
  int reinit_every = 1;
  int sweeps = 8;
};

}  // namespace

int main(int argc, char** argv) {
  Args a;
  if (argc < 5) {
    std::printf(
        "usage: levelset_probe <part.step> <materials.json> <ref_design.bin> "
        "<out_dir>\n"
        "       [--rung R] [--iters N] [--eta VOXELS] [--cfl C] [--smooth N]\n"
        "       [--seed simp|holes] [--fp32] [--isolate] [--reinit-every N]\n"
        "       [--sweeps N]\n");
    return 2;
  }
  a.step = argv[1];
  a.materials = argv[2];
  a.ref_design = argv[3];
  a.out = argv[4];
  for (int i = 5; i < argc; ++i) {
    const std::string s = argv[i];
    auto next = [&](double& dst) { if (i + 1 < argc) dst = std::atof(argv[++i]); };
    auto nexti = [&](int& dst) { if (i + 1 < argc) dst = std::atoi(argv[++i]); };
    if (s == "--rung") next(a.rung);
    else if (s == "--iters") nexti(a.iters);
    else if (s == "--eta") next(a.eta_voxels);
    else if (s == "--cfl") next(a.cfl);
    else if (s == "--smooth") nexti(a.smooth);
    else if (s == "--reinit-every") nexti(a.reinit_every);
    else if (s == "--sweeps") nexti(a.sweeps);
    else if (s == "--fp32") a.fp32 = true;
    else if (s == "--isolate") a.isolate = true;
    else if (s == "--seed" && i + 1 < argc) a.seed = argv[++i];
    else { std::printf("FATAL: unknown argument %s\n", s.c_str()); return 2; }
  }

  // ── HIS PROBLEM, from the PRODUCTION builder ──────────────────────────────
  //
  // Transcribed from evidence/2026-08-09-reference-implementation-bakeoff/
  // job_simp.json, exactly as portable_problem_export transcribes it and for the
  // same reason: `production_loadcase_from_job` lives inside run_job.cpp's
  // translation unit and is not on a public header. The transcription is proved
  // right by the counts this program prints, which must reproduce that probe's.
  const int resolution = 128;
  ProductionLoadCase lc;
  lc.anchor_face_ids = {18};
  ProductionLoadCase::LoadGroup g;
  g.face_ids = {20, 1, 4, 19, 21, 22, 25, 26, 27, 32, 41, 42,
                43, 44, 45, 46, 47, 49, 75, 76, 24, 31};
  g.force = Vec3{0.0, 0.0, -22.241134643554688};
  lc.load_groups.push_back(g);
  lc.minimize_plastic = true;
  lc.build_dir = Vec3{0.0, 0.0, 1.0};
  lc.build_orientation_report = true;
  lc.infill_percent = 35.0;
  lc.wall_loops = 5;
  lc.wall_line_width_mm = 0.45;
  lc.wall_line_width_outer_mm = 0.42;
  lc.face_protection_face_ids = {16};
  lc.face_protection_depth_mm = 5.0;

  const StepModel model = import_part_file_resolved(a.step);
  if (model.mesh.vertices.empty()) {
    std::printf("FATAL: the STEP imported empty — OCCT is required\n");
    return 2;
  }
  const ProductionRunSetup setup = build_production_loadcase(model, resolution, lc);
  const VoxelGrid& grid = setup.grid;
  const MinimizePlasticOptions& options = setup.options;
  const std::vector<DirichletBC>& bcs = setup.bcs;
  const std::vector<NodalLoad>& loads = options.external_loads;

  const MaterialLibrary lib = load_materials_file(a.materials);
  const auto mit = lib.find("PLA");
  if (mit == lib.end()) { std::printf("FATAL: PLA not in %s\n", a.materials.c_str()); return 2; }
  const Material& material = mit->second;

  SimpParams params;
  params.youngs_modulus = material.youngs_modulus_mpa;
  params.poisson = material.poisson;
  params.penalty = 3.0;

  const Dims d{grid.nx, grid.ny, grid.nz};
  const std::size_t n = grid.voxel_count();
  const double h = grid.spacing;
  const double eta = a.eta_voxels * h;
  const double part_solid = static_cast<double>(grid.solid_count());
  const double target_volume = a.rung * part_solid;

  // ── the mask, composed exactly as the shipped path composes it ────────────
  const DesignMask eff = effective_design_mask(grid, options.design_mask);
  std::size_t n_active = 0, n_fsolid = 0, n_fvoid = 0;
  for (std::size_t v = 0; v < n; ++v) {
    if (eff[v] == MaskValue::Active) ++n_active;
    else if (eff[v] == MaskValue::FrozenSolid) ++n_fsolid;
    else ++n_fvoid;
  }

  // ── THE SOLVER POSTURE, AND WHY IT IS PRODUCTION'S ────────────────────────
  //
  // ★ THE TRAJECTORY RUNS IN THE POSTURE SIMP'S 11.2 s/ITERATION WAS MEASURED
  // IN, because otherwise the comparison this task exists to make is not a
  // comparison. `build_production_loadcase` has already run
  // `configure_production_options`, which arms the Galerkin block cache, Krylov
  // recycling (dim 16, wrap_multigrid false), GenEO two-level and the production
  // thread count — globally, on the FEA layer. Those are in force right now and
  // are deliberately LEFT ALONE.
  //
  // An earlier cut of this file disarmed recycling and GenEO at this point,
  // copying the re-certifying probes. On his part that cost 2.5x per iteration
  // (28.4 s against 11.2 s) and it was measuring the handicap, not the level
  // set: his run is the Jacobi regime the recycler was armed FOR (his
  // `run_info.json`: `krylov_recycling: true`, `recycle_dim: 16`,
  // `cg_multigrid: false`, `mg_mode: "stagnated-latched"`), and handoff 133
  // measured 45.4% fewer CG iterations there. `--isolate` restores the disarmed
  // posture for anyone who wants that control; it is not the run of record.
  //
  // THE CERTIFICATION IS ISOLATED SEPARATELY, below, exactly as production
  // isolates it (`ScopedLadderSolverIsolation`, run_job.cpp:2847) — recycling
  // and GenEO off, and FP64 — so the certificate is produced on the same solver
  // path every other certificate in this repository was.
  const bool prev_recycle = a.isolate ? fea_set_krylov_recycling(false)
                                      : fea_krylov_recycling_enabled();
  const bool prev_geneo =
      a.isolate ? fea_set_geneo_twolevel(false) : fea_geneo_twolevel_enabled();
  const bool prev_mixed = fea_set_matfree_mixed_precision(a.fp32);

  std::printf("== levelset_probe — a level set on our own solver ==\n\n");
  std::printf("part        %s (%zu B-rep faces)\n", a.step.c_str(), model.faces.size());
  std::printf("grid        %d x %d x %d = %zu voxels, spacing %.9f mm\n", d.nx, d.ny,
              d.nz, n, h);
  std::printf("origin      (%.9f, %.9f, %.9f) mm\n", grid.origin.x, grid.origin.y,
              grid.origin.z);
  std::printf("dofs        %d nodes, %d displacement DOFs\n", fea_node_count(grid),
              3 * fea_node_count(grid));
  std::printf("bcs         %zu clamped DOFs\n", bcs.size());
  {
    double fz = 0.0;
    for (const auto& l : loads) if (l.component == 2) fz += l.value;
    std::printf("loads       %zu nodal loads, Fz = %.8f N\n", loads.size(), fz);
  }
  std::printf("part solid  %.0f voxels;  mask Active %zu / FrozenSolid %zu / "
              "FrozenVoid %zu\n", part_solid, n_active, n_fsolid, n_fvoid);
  std::printf("rung        %.4g  ->  target %.1f printed voxels\n", a.rung,
              target_volume);
  std::printf("band eta    %.4g voxels = %.6f mm      seed: %s\n", a.eta_voxels, eta,
              a.seed.c_str());
  std::printf("posture     %s: recycling %s (dim %d), geneo %s, galerkin cache %s,\n"
              "            threads %d, solver=%d, cg_tol=%.3g, cg_max=%d\n",
              a.isolate ? "ISOLATED (a control, not the run of record)"
                        : "PRODUCTION (as SIMP's 11.2 s/iteration was measured)",
              fea_krylov_recycling_enabled() ? "ON" : "off",
              production_krylov_recycle_dim(),
              fea_geneo_twolevel_enabled() ? "ON" : "off",
              fea_matfree_galerkin_block_cache_enabled() ? "ON" : "off",
              fea_matfree_thread_count(), static_cast<int>(options.simp.solver),
              options.simp.cg_tolerance, options.simp.cg_max_iterations);
  std::printf("mixed prec  %s  (V-cycle preconditioner only; the outer CG is FP64 "
              "by design)\n", fea_matfree_mixed_precision_enabled() ? "ARMED (FP32)"
                                                                   : "off (FP64)");
  std::fflush(stdout);

  // ── (a) PHI, INITIALISED ──────────────────────────────────────────────────
  std::vector<double> phi(n, 0.0);
  if (a.seed == "simp") {
    // His own converged rung, re-read as a level set. phi starts as (0.5 - rho),
    // which has the right SIGN everywhere and the right zero set; the
    // reinitialiser then makes it a true signed distance. That is piece (f)
    // doing the seeding, which is the point: the coherence PR 321 measured comes
    // from the distance property, not from where the boundary started.
    const DesignStore store = read_design_file(a.ref_design);
    if (store.nx != d.nx || store.ny != d.ny || store.nz != d.nz) {
      std::printf("FATAL: %s is %dx%dx%d, this grid is %dx%dx%d\n",
                  a.ref_design.c_str(), store.nx, store.ny, store.nz, d.nx, d.ny,
                  d.nz);
      return 2;
    }
    const StoredDesign* pick = nullptr;
    for (const auto& s : store.variants)
      if (std::fabs(s.requested_volume_fraction - a.rung) < 1e-9) pick = &s;
    if (!pick) {
      std::printf("FATAL: no rung %.4g in %s (it has:", a.rung, a.ref_design.c_str());
      for (const auto& s : store.variants)
        std::printf(" %.4g", s.requested_volume_fraction);
      std::printf(")\n");
      return 2;
    }
    std::printf("seed        SIMP rung %.4g from %s (achieved %.6f)\n",
                pick->requested_volume_fraction, a.ref_design.c_str(),
                pick->achieved_volume_fraction);
    for (std::size_t v = 0; v < n; ++v) phi[v] = 0.5 - pick->density[v];
  } else if (a.seed == "holes") {
    // A regular array of holes, the classic level-set start: phi is a product of
    // cosines, negative (solid) between the holes. The period is 8 voxels and the
    // holes are centred on the lattice, so the start is the same object at any
    // resolution of his part.
    const double per = 8.0;
    for (int k = 0; k < d.nz; ++k)
      for (int j = 0; j < d.ny; ++j)
        for (int i = 0; i < d.nx; ++i)
          phi[d.at(i, j, k)] =
              -0.4 + std::cos(2.0 * kPi * i / per) * std::cos(2.0 * kPi * j / per) *
                         std::cos(2.0 * kPi * k / per);
    std::printf("seed        regular hole array, period %.0f voxels\n", per);
  } else {
    std::printf("FATAL: --seed must be simp or holes\n");
    return 2;
  }
  reinitialise(d, phi, h, a.sweeps);

  // ── the ersatz, and the volume it measures ────────────────────────────────
  //
  // `occ` is the OCCUPANCY (0..1) the volume target and every downstream
  // instrument read; `rho` is that clamped into the SIMP admissible band. They
  // are separate because the volume constraint is a statement about the OBJECT
  // and rho_min is a statement about the SOLVER.
  std::vector<double> occ(n, 0.0), rho(n, 0.0);
  const double rho_min = params.density_min;

  auto build_fields = [&](double offset) {
    for (std::size_t v = 0; v < n; ++v) {
      double o;
      if (grid.tags[v] == VoxelTag::Empty || eff[v] == MaskValue::FrozenVoid) o = 0.0;
      else if (eff[v] == MaskValue::FrozenSolid) o = 1.0;
      else o = heaviside(-(phi[v] + offset), eta);
      occ[v] = o;
      rho[v] = rho_min + (1.0 - rho_min) * o;
    }
  };

  auto volume_at = [&](double offset) {
    double s = 0.0;
    for (std::size_t v = 0; v < n; ++v) {
      if (grid.tags[v] == VoxelTag::Empty || eff[v] == MaskValue::FrozenVoid) continue;
      if (eff[v] == MaskValue::FrozenSolid) { s += 1.0; continue; }
      s += heaviside(-(phi[v] + offset), eta);
    }
    return s;
  };

  // ── (g) THE VOLUME CONSTRAINT: bisect the offset ──────────────────────────
  //
  // volume_at is non-increasing in `offset` by construction (raising phi can only
  // move material out of the sub-level set), so a bisection is unconditionally
  // convergent and needs no tuning. The bracket is far wider than the part, so it
  // always contains the root; 100 halvings take it to machine precision.
  auto solve_offset = [&](double target) {
    double lo = -400.0, hi = 400.0;
    if (volume_at(lo) < target) return lo;   // cannot fill enough: fullest wins
    if (volume_at(hi) > target) return hi;   // cannot empty enough: emptiest wins
    for (int it = 0; it < 100; ++it) {
      const double mid = 0.5 * (lo + hi);
      if (volume_at(mid) > target) lo = mid; else hi = mid;
    }
    return 0.5 * (lo + hi);
  };

  // ── the run ───────────────────────────────────────────────────────────────
  std::ofstream csv(a.out + "/iterations.csv");
  csv.precision(12);
  csv << "iteration,compliance,occupancy_volume,printed_voxels,achieved_vf,"
         "offset_mm,dt_mm_per_unit_v,max_abs_v,lambda,cg_iterations,converged,"
         "used_multigrid,solve_ms,sensitivity_ms,iteration_wall_s\n";

  std::vector<double> vel(n, 0.0);
  std::vector<double> best_occ, best_rho;
  double best_compliance = std::numeric_limits<double>::infinity();
  int best_iter = -1;

  const double t_run0 = now_s();
  double total_solve_wall = 0.0;
  long long solves_multigrid = 0, solves_total = 0;
  std::vector<double> history;
  int done_iters = 0;
  bool converged_early = false;

  for (int it = 1; it <= a.iters; ++it) {
    const double t_it0 = now_s();

    const double offset = solve_offset(target_volume);
    build_fields(offset);

    // ── THE STATE SOLVE. Core's, unmodified. ────────────────────────────────
    SimpCompliance sc;
    const double t_s0 = now_s();
    try {
      sc = simp_compliance(grid, params, rho, bcs, loads, options.simp.cg_tolerance,
                           options.simp.cg_max_iterations, nullptr, nullptr,
                           options.simp.solver);
    } catch (const std::exception& e) {
      std::printf("\n*** STATE SOLVE FAILED at iteration %d: %s\n"
                  "*** Stopping here; everything already written stands.\n", it,
                  e.what());
      break;
    }
    const double solve_wall = now_s() - t_s0;
    total_solve_wall += solve_wall;
    ++solves_total;
    if (sc.cg.used_multigrid) ++solves_multigrid;

    std::size_t printed = 0;
    for (std::size_t v = 0; v < n; ++v) if (occ[v] > 0.5) ++printed;
    const double occ_vol = volume_at(offset);

    if (sc.compliance < best_compliance) {
      best_compliance = sc.compliance;
      best_occ = occ;
      best_rho = rho;
      best_iter = it;
    }

    // ── (c) the velocity: strain energy density, less the volume multiplier ──
    double band_sum = 0.0;
    std::size_t band_n = 0;
    const double band = 2.0 * h;
    for (std::size_t v = 0; v < n; ++v) {
      if (grid.tags[v] == VoxelTag::Empty || eff[v] != MaskValue::Active) {
        vel[v] = 0.0;
        continue;
      }
      const double e = energy_from(sc.dcompliance[v], rho[v], params.penalty,
                                   params.youngs_modulus);
      vel[v] = e;
      if (std::fabs(phi[v] + offset) <= band) { band_sum += e; ++band_n; }
    }
    // The multiplier is the MEAN band energy: the interface then grows where the
    // structure is working harder than average and retreats where it is idling,
    // which is a volume-neutral descent to first order. The residual volume error
    // it leaves is exactly what the offset bisection removes at the top of the
    // next iteration, so the two pieces do not fight.
    const double lambda = band_n ? band_sum / static_cast<double>(band_n) : 0.0;
    for (std::size_t v = 0; v < n; ++v) {
      if (grid.tags[v] == VoxelTag::Empty || eff[v] != MaskValue::Active) {
        vel[v] = 0.0;
        continue;
      }
      vel[v] -= lambda;
    }

    // ── (d) extension ───────────────────────────────────────────────────────
    smooth_field(d, vel, a.smooth);
    for (std::size_t v = 0; v < n; ++v)
      if (grid.tags[v] == VoxelTag::Empty || eff[v] != MaskValue::Active) vel[v] = 0.0;

    double vmax = 0.0;
    for (std::size_t v = 0; v < n; ++v) vmax = std::max(vmax, std::fabs(vel[v]));

    // ── (e) advection, CFL-limited ──────────────────────────────────────────
    double dt = 0.0;
    if (vmax > 0.0) {
      dt = a.cfl * h / vmax;
      std::vector<double> next(n);
      for (int k = 0; k < d.nz; ++k)
        for (int j = 0; j < d.ny; ++j)
          for (int i = 0; i < d.nx; ++i) {
            const std::size_t v = d.at(i, j, k);
            const double vv = vel[v];
            next[v] = vv == 0.0
                          ? phi[v]
                          : phi[v] - dt * vv * godunov_grad(d, phi, i, j, k, vv, h);
          }
      phi.swap(next);
    }

    // ── (f) reinitialisation ────────────────────────────────────────────────
    if (a.reinit_every > 0 && it % a.reinit_every == 0)
      reinitialise(d, phi, h, a.sweeps);

    const double it_wall = now_s() - t_it0;
    done_iters = it;

    csv << it << ',' << sc.compliance << ',' << occ_vol << ',' << printed << ','
        << (printed / part_solid) << ',' << offset << ',' << dt << ',' << vmax << ','
        << lambda << ',' << sc.cg.iterations << ',' << (sc.cg.converged ? 1 : 0)
        << ',' << (sc.cg.used_multigrid ? 1 : 0) << ',' << sc.t_solve_ms << ','
        << sc.t_sensitivity_ms << ',' << it_wall << '\n';
    csv.flush();

    std::printf("it %3d  c = %.10g  vf = %.6f (occ %.1f)  offset %+.4f mm  "
                "|v|max %.3g  cg %d%s  %.2f s\n",
                it, sc.compliance, printed / part_solid, occ_vol, offset, vmax,
                sc.cg.iterations, sc.cg.used_multigrid ? " MG" : "", it_wall);
    std::fflush(stdout);

    // ── convergence: the compliance plateau, on the same window/tolerance the
    // shipped MMA termination uses (handoff: window 10, tol 1e-3).
    history.push_back(sc.compliance);
    if (history.size() >= 10) {
      double lo = history[history.size() - 10], hi = lo;
      for (std::size_t q = history.size() - 10; q < history.size(); ++q) {
        lo = std::min(lo, history[q]);
        hi = std::max(hi, history[q]);
      }
      if (hi > 0.0 && (hi - lo) / hi < 1e-3) {
        std::printf("\nconverged: compliance flat within 1e-3 over the last 10 "
                    "iterations\n");
        converged_early = true;
        break;
      }
    }
  }

  const double run_wall = now_s() - t_run0;

  if (best_iter < 0) {
    std::printf("\nFATAL: not one state solve completed. Nothing to certify.\n");
    fea_set_krylov_recycling(prev_recycle);
    fea_set_geneo_twolevel(prev_geneo);
    fea_set_matfree_mixed_precision(prev_mixed);
    return 3;
  }

  // The design that is certified and written is the BEST-COMPLIANCE iterate, not
  // whatever the loop happened to stop on: an explicit Hamilton-Jacobi step can
  // overshoot, and certifying an overshoot would report the scheme's worst moment
  // as its result. `best_iter` records which one it was.
  occ = best_occ;
  rho = best_rho;
  std::printf("\ncertifying iteration %d (best compliance %.10g of %d run)\n",
              best_iter, best_compliance, done_iters);

  // ── S3(b): THE CERTIFICATION. Core's own, at the production tolerance. ────
  //
  // ISOLATED exactly as production isolates every re-certification
  // (`ScopedLadderSolverIsolation`, run_job.cpp:2847): recycling and GenEO off,
  // and FP64 regardless of `--fp32`. The trajectory may run in whatever posture
  // is fastest; the CERTIFICATE is produced on the same solver path, in the same
  // arithmetic, as every other certificate in this repository, so the margin row
  // below is comparable to SIMP's and not to nothing.
  const bool traj_recycle = fea_set_krylov_recycling(false);
  const bool traj_geneo = fea_set_geneo_twolevel(false);
  const bool traj_mixed = fea_set_matfree_mixed_precision(false);

  const double iso = 0.5;
  const bool load_path_ok = load_path_connected(grid, rho, iso);
  const KnockdownSpec knockdown = knockdown_spec_for(options);

  FixedDesignAnalysis an;
  bool analysed = false;
  const double t_c0 = now_s();
  try {
    an = analyze_fixed_design(grid, params, rho, bcs, loads, material,
                              options.build_direction, options.simp.cg_tolerance,
                              options.simp.cg_max_iterations, options.simp.solver,
                              options.margin_stop, knockdown, load_path_ok,
                              part_solid);
    analysed = true;
  } catch (const std::exception& e) {
    std::printf("CERTIFICATION FAILED: %s\n", e.what());
  }
  const double cert_wall = now_s() - t_c0;

  fea_set_matfree_mixed_precision(traj_mixed);
  fea_set_geneo_twolevel(traj_geneo);
  fea_set_krylov_recycling(traj_recycle);
  fea_set_matfree_mixed_precision(prev_mixed);
  fea_set_geneo_twolevel(prev_geneo);
  fea_set_krylov_recycling(prev_recycle);

  std::size_t printed = 0;
  for (std::size_t v = 0; v < n; ++v) if (occ[v] > 0.5) ++printed;
  const double achieved_vf = printed / part_solid;

  double compliance_final = 0.0;
  if (analysed && !an.non_convergent)
    for (const NodalLoad& l : loads)
      compliance_final += l.value * an.displacement_field[static_cast<std::size_t>(
                                        3 * l.node + l.component)];

  // ── WHAT COMES OUT ────────────────────────────────────────────────────────

  // The raw occupancy, for external_field_surface_probe — R2's instrument,
  // INCLUDED (invoked) rather than retyped. The convention it demands is an
  // OCCUPANCY with 0 = void, 1 = solid, iso between and background 0 outside the
  // lattice; `occ` is exactly that by construction, and phi is deliberately NOT
  // what is written (that probe says why: marching cubes' zero pad would read
  // phi's positive background as solid).
  {
    std::ofstream f(a.out + "/rho.f64", std::ios::binary);
    f.write(reinterpret_cast<const char*>(occ.data()),
            static_cast<std::streamsize>(occ.size() * sizeof(double)));
    if (!f) { std::printf("FATAL: could not write rho.f64\n"); return 2; }
  }
  {
    std::ofstream m(a.out + "/rho.meta");
    m.precision(17);
    // `rung` is a LABEL, and external_field_surface_probe matches it as a STRING
    // against the SIMP rows it formats with "%.2f". Writing the double at full
    // precision spells 0.68 as "0.68000000000000005", which that probe cannot
    // match — it reports "NO SIMP ROW AT THIS RUNG" and the arm loses its
    // comparison row even though the measurement itself is correct. Two digits,
    // to match the bar.
    char rung_label[32];
    std::snprintf(rung_label, sizeof rung_label, "%.2f", a.rung);
    m << "rung " << rung_label << "\n";
    m << "requested_vf " << a.rung << "\n";
    m << "nx " << d.nx << "\nny " << d.ny << "\nnz " << d.nz << "\n";
    m << "spacing " << h << "\n";
    // A CELL-centred field on his lattice passes his origin unchanged (that
    // probe's own rule).
    m << "ox " << grid.origin.x << "\noy " << grid.origin.y << "\noz "
      << grid.origin.z << "\n";
    m << "iso 0.5\nfactor 2\ninterp tricubic\n";
    m << "achieved_vf " << achieved_vf << "\n";
    m << "iterations " << done_iters << "\n";
    m << "wall_s " << run_wall << "\n";
    m << "compliance " << compliance_final << "\n";
  }

  // The design in the shipped container, so design_rung_dump and every viewer
  // can read it without a new reader existing anywhere.
  {
    MinimizePlasticVariant var;
    var.requested_volume_fraction = a.rung;
    var.optimization.physical_density = rho;
    var.optimization.volume_fraction = achieved_vf;
    var.optimization.iterations = done_iters;
    var.applied_build_dir = options.build_direction;
    if (analysed && !an.non_convergent) {
      var.report.margin = an.margin;
      var.report.margin_effective = an.margin_effective;
      var.report.max_stress_mpa = an.max_von_mises;
    }
    var.accepted = analysed && an.accepted;
    std::vector<const MinimizePlasticVariant*> vs{&var};
    try {
      write_design_file(a.out + "/design.bin", vs, grid);
    } catch (const std::exception& e) {
      std::printf("WARNING: could not write design.bin: %s\n", e.what());
    }
  }

  // And the surface itself, at the shipped export settings, so he can open it.
  try {
    const TriangleMesh mesh = keep_largest_component(marching_cubes_resampled(
        d.nx, d.ny, d.nz, h, grid.origin, occ, iso, 2, ResampleInterp::Tricubic));
    write_stl_file(a.out + "/levelset.stl", mesh, StlFormat::Binary);
    std::printf("mesh        %zu vertices, %zu triangles -> levelset.stl\n",
                mesh.vertices.size(), mesh.triangles.size());
  } catch (const std::exception& e) {
    std::printf("WARNING: could not write levelset.stl: %s\n", e.what());
  }

  // ── the summary: the three numbers section 0 of the handoff states ────────
  const double per_iter = done_iters ? run_wall / done_iters : 0.0;
  char buf[4096];
  std::snprintf(
      buf, sizeof(buf),
      "== levelset_probe summary ==\n"
      "seed                 %s\n"
      "rung                 %.4g\n"
      "iterations run       %d%s\n"
      "WALL PER ITERATION   %.3f s   (total %.1f s over %d iterations)\n"
      "  of which solve     %.3f s/iteration (%.1f s total)\n"
      "certification wall   %.1f s\n"
      "state solves         %lld, of which the V-cycle engaged on %lld\n"
      "trajectory posture   %s\n"
      "mixed precision      %s\n"
      "compliance (best)    %.12g\n"
      "compliance (cert)    %.12g\n"
      "achieved vf          %.6f  (target %.4g, printed %zu of %.0f part voxels)\n"
      "load path connected  %s\n",
      a.seed.c_str(), a.rung, done_iters, converged_early ? " (converged)" : "",
      per_iter, run_wall, done_iters,
      done_iters ? total_solve_wall / done_iters : 0.0, total_solve_wall, cert_wall,
      solves_total, solves_multigrid,
      a.isolate ? "ISOLATED (recycling/geneo OFF) — a control"
                : "PRODUCTION (recycling/geneo as configure_production_options "
                  "armed them)",
      a.fp32 ? "ARMED (FP32 V-cycle) on the trajectory; the certificate is FP64"
             : "off (FP64)",
      best_compliance, compliance_final, achieved_vf, a.rung, printed, part_solid,
      load_path_ok ? "yes" : "NO");
  std::string summary = buf;

  if (!analysed) {
    summary += "certification        DID NOT RUN (the solve threw)\n";
  } else if (an.non_convergent) {
    std::snprintf(buf, sizeof(buf),
                  "certification        NON-CONVERGENT at iteration %d, residual "
                  "%.6g — NOT a certificate\n",
                  an.non_convergent_iteration, an.non_convergent_residual);
    summary += buf;
  } else {
    std::snprintf(buf, sizeof(buf),
                  "max von Mises        %.9f MPa\n"
                  "margin in-plane      %.9f\n"
                  "margin interlayer    %.9f\n"
                  "MARGIN worst case    %.9f\n"
                  "margin effective     %.9f   (gate: >= %.4g)\n"
                  "VERDICT              %s\n"
                  "min-feature viols    %d\n"
                  "mass                 %.4f g\n",
                  an.max_von_mises, an.margin.in_plane, an.margin.interlayer,
                  an.margin.worst_case, an.margin_effective, options.margin_stop,
                  an.accepted ? "ACCEPTED" : "REJECTED",
                  an.v3.min_feature_violations, an.mass_grams);
    summary += buf;
  }

  std::printf("\n%s", summary.c_str());
  { std::ofstream s(a.out + "/summary.txt"); s << summary; }

  std::printf("\nwrote %s/{iterations.csv,design.bin,rho.f64,rho.meta,"
              "levelset.stl,summary.txt}\n", a.out.c_str());
  std::printf("\nfor the roughness row, on the SAME binary that produced PR 321's:\n"
              "  ./build/external_field_surface_probe <ref/design.bin> <part.step> "
              "<dir> LS=%s/rho\n", a.out.c_str());
  return 0;
}
