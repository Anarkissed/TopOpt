// levelset_probe — task 2026-08-09-levelset-match-the-reference, which SUPERSEDES
// the arm this file was first written for (2026-08-09-levelset-on-our-solver,
// PR 322).
//
// A WORKING LEVEL-SET TOPOLOGY OPTIMIZER driven by OUR OWN matrix-free solver,
// in a sandbox target. Nothing in core/src or core/include changes; the shipped
// SIMP path is untouched.
//
//   cmake --build build --target levelset_probe
//   ./build/levelset_probe <part.step> <materials.json> <ref_design.bin> <out_dir>
//        [--rung 0.68] [--iters 300] [--eta 2.0] [--gamma 0.1] [--hj-steps 6]
//        [--alpha-coeff 2.4] [--traj-penalty 1.0] [--threads 3]
//        [--seed simp|holes] [--fp32] [--isolate] [--reinit-every 1]
//        [--snapshot-every 10] [--simp] [--rules <rules.json>]
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
// does. PR 322 found out what it actually costs on our solver by being it:
// 25.09 s/iteration at 6 threads, and a roughness win of 11.2%.
//
// ── AND WHY IT IS NOW DIFFERENT: THE FIVE DIFFERENCES ───────────────────────
//
// 11.2% is a QUARTER of Gridap's 46.9%. A line-by-line re-read of GridapTopOpt
// (repo + arXiv 2405.10478) found five places where PR 322's optimizer was not
// the same algorithm. All five are implemented here. In the order the task ranks
// them, with the identifier each carries in the code below:
//
//  (1) ★★★ THE SURFACE DELTA. Theirs is
//        dJ(q,u,φ) = ∫ (C ⊙ ε(u) ⊙ ε(u)) q (DH ∘ φ) (norm ∘ ∇φ) dΩ
//      PR 322's velocity was the strain energy density over the WHOLE active
//      domain, less a scalar λ. That is a VOLUME field; theirs is CONCENTRATED
//      AT THE INTERFACE by DH_η(φ)·|∇φ|. `surface_delta` below is that factor,
//      and it multiplies the compliance term AND the volume term — their volume
//      sensitivity carries the identical factor,
//        dVol(q,u,φ) = ∫ -1/vol_D q (DH ∘ φ) (norm ∘ ∇φ) dΩ
//      so the two differ only in replacing the energy density by a constant, and
//      the common factor comes out front: v = (energy − λ)·DH_η(φ)·|∇φ|.
//
//  (2) ★★ NO SIMP PENALTY ON THE ERSATZ. Theirs is LINEAR in the Heaviside:
//        I(φ) = (1 − H(φ)) + ϵ H(φ),  ϵ = 1e-3   (src/Utilities.jl:34-43)
//      Our rho is already ϵ + (1−ϵ)·occ, so their I(φ) IS our rho — the
//      difference is that our FEA then raised it to the penalty. `--traj-penalty`
//      defaults to 1.0, at which E(rho) = rho·E0 is EXACTLY their interpolation
//      and ρ_min = 1e-3 already matches their ϵ.
//      ★ THE CERTIFICATION IS UNCHANGED: `analyze_fixed_design` runs at the
//      PRODUCTION penalty 3 on the final design, as it always has. The trajectory
//      law and the certification law are allowed to differ and here they do; the
//      handoff says so plainly rather than leaving it to be inferred.
//
//  (3) ★★ SIX HJ STEPS PER SOLVE, NOT ONE. Theirs is
//        max_steps = floor(order·min(el_size)/5) → 6 on his 128 x 31 x 118
//        γ = 0.1, γ_reinit = 0.5
//      advected max_steps times per optimiser iteration on ONE velocity field.
//      `--hj-steps 6 --gamma 0.1`. PR 322 took one step at CFL 0.4.
//
//  (4) ★ HILBERTIAN VELOCITY EXTENSION, replacing PR 322's [1 2 1] passes:
//        find v̄ with  ∫_D (α² ∇v̄·∇w + v̄ w) = <raw velocity, w>  ∀w
//        α = α_coeff · max(el_Δ),  α_coeff = 4·max_steps·γ = 2.4
//      with HOMOGENEOUS DIRICHLET v̄ = 0 on the load boundary (theirs:
//      `V_reg = TestFESpace(...; dirichlet_tags=["Gamma_N"])`), and on the anchor
//      (face 18) and face-protection (face 16) sets too. On this regular grid
//      that is a 7-point screened-Poisson solve; see `hilbertian_extend`.
//
//  (5) ★ η = 2 VOXELS, NOT 1. η_coeff = 2, so H_η spans [−η, +η] and the
//      transition is FOUR voxels wide. `--eta` now defaults to 2.0.
//
// ── WHAT COULD NOT BE MADE THE SAME, AND WHY ────────────────────────────────
//
// γ_reinit = 0.5 and their reinitialisation tolerance 1/(5·order²)/min(el_size)
// = 0.00645 are parameters of a reinitialisation-by-PDE — they integrate a
// second Hamilton-Jacobi equation to steady state. Ours is FAST SWEEPING, a
// direct Eikonal solve with no time step, so neither number has anything to
// apply to. What matters is the property both schemes are reaching for, so this
// program MEASURES it instead of asserting it: `reinit_resid` in the CSV is
// max| |∇φ| − 1 | over the band after sweeping, to be read against their 0.00645.
//
// Their optimiser is a true Augmented Lagrangian carrying the constraint
// sensitivity above. This keeps PR 322's mean-band-energy λ plus offset
// bisection, which the task permits if (1)-(4) land — but λ is now the
// DH·|∇φ|-WEIGHTED mean energy, the ratio that makes ∫(e−λ)·DH·|∇φ| vanish, so
// the multiplier is taken under the same measure the surface delta introduced
// rather than over a flat band.
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
//                   Heaviside over a band eta (★ DIFFERENCE 5: DEFAULT NOW 2
//                   VOXELS, their eta_coeff, so the transition is four voxels
//                   wide). rho(phi = 0) = 0.5 exactly, which is the iso every
//                   downstream instrument already reads. ★ DIFFERENCE 2: the FEA
//                   reads it through penalty `--traj-penalty` (default 1.0 =
//                   their LINEAR interpolation), not the production 3.
//  (c) shape deriv  ★ DIFFERENCE 1: the velocity is the per-element strain energy
//                   density less the volume multiplier, MULTIPLIED BY THE SURFACE
//                   DELTA DH_eta(phi) * |grad phi| so it is concentrated at the
//                   interface instead of spread over the whole active domain.
//                   `simp_compliance` already returns dc/drho_e per voxel; the
//                   energy is recovered from it algebraically (see `energy_from`
//                   below). Nothing exotic is derived.
//  (d) extension    ★ DIFFERENCE 4: HILBERTIAN. v-bar solves the screened Poisson
//                   (I - alpha^2 Lap) v-bar = v on the grid, alpha = 2.4 voxels,
//                   with v-bar = 0 pinned on the load / anchor / face-protection
//                   sets. Jacobi-preconditioned CG, rtol 1e-12 as theirs. PR 322's
//                   separable [1 2 1]/4 passes are still reachable by
//                   `--smooth N --alpha-coeff 0` as a control.
//  (e) advection    ★ DIFFERENCE 3: SIX explicit upwind Hamilton-Jacobi steps per
//                   state solve, not one — phi <- phi - dt * v * |grad phi| with
//                   the Godunov gradient re-evaluated each sub-step, on ONE
//                   velocity field, dt = gamma * h / max|v| with gamma = 0.1.
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
// ── TWO MATERIAL LAWS, AND THE LINE BETWEEN THEM ────────────────────────────
//
// ★ THE TRAJECTORY LAW AND THE CERTIFICATION LAW ARE DIFFERENT, ON PURPOSE.
//
// THE TRAJECTORY runs at `--traj-penalty`, default 1.0, which makes
// E(rho) = rho * E0 — algebraically identical to GridapTopOpt's
// I(φ) = (1 − H(φ)) + ϵ H(φ) with ϵ = ρ_min = 1e-3 (difference 2). PR 322 used
// the production penalty 3 here, at which a band voxel at rho = 0.5 is stiffness
// 0.125 rather than 0.5 — a systematic sub-voxel thinning of the interface, one
// band wide, and precisely the term a level set is not supposed to have.
//
// THE CERTIFICATION IS UNCHANGED AND IS NOT NEGOTIABLE. `analyze_fixed_design`
// runs on the final design at the PRODUCTION SimpParams (penalty 3, density_min
// 1e-3), isolated exactly as production isolates it, so the margin row below is
// produced by the same law and the same solver path as every other certificate
// in this repository and is comparable to SIMP's. Nothing about the trajectory
// reaches it.
//
// The consequence a reader must not have to infer: the TRAJECTORY compliance
// this program prints is on a different material law from SIMP's converged
// compliance and from PR 322's, and the three are NOT directly comparable. The
// margin, the roughness and the volume are, because they are measured on the
// geometry.
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
#include "topopt/settings.hpp"
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
#include <filesystem>
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

// ── (1) THE SURFACE DELTA: DH_eta, their DERIVATIVE of the same Heaviside ────
//
// GridapTopOpt, src/Utilities.jl:
//     H_eta(t, eta)  = 1/2 (1 + t/eta + sin(pi t/eta)/pi)   for |t| <= eta
//     DH_eta(t, eta) = 1/(2 eta) (1 + cos(pi t/eta))        for |t| <= eta, else 0
// and DH is exactly d/dt of H, which is the consistency this file relies on:
// `heaviside` above IS their H_eta, so the delta below is its own derivative and
// there is no second smoothing law anywhere in this program.
//
// DH is EVEN in t, so it does not matter whether it is evaluated at phi (their
// sign convention) or at -phi (the argument `heaviside` takes here). It is
// written at phi, as theirs is.
double dheaviside(double t, double eta) {
  if (t <= -eta || t >= eta) return 0.0;
  return (1.0 + std::cos(kPi * t / eta)) / (2.0 * eta);
}

// |grad phi|, central differences, one-sided at the box face. This is their
// `norm ∘ ∇(φ)`. After reinitialisation it is ~1 by construction — which is the
// point: it is carried anyway so the delta stays a correct surface measure on
// the iterations where phi has drifted from a true distance.
double grad_mag(const Dims& d, const std::vector<double>& phi, int i, int j,
                int k, double h) {
  const double xm = phi[d.at(i > 0 ? i - 1 : 0, j, k)];
  const double xp = phi[d.at(i + 1 < d.nx ? i + 1 : d.nx - 1, j, k)];
  const double ym = phi[d.at(i, j > 0 ? j - 1 : 0, k)];
  const double yp = phi[d.at(i, j + 1 < d.ny ? j + 1 : d.ny - 1, k)];
  const double zm = phi[d.at(i, j, k > 0 ? k - 1 : 0)];
  const double zp = phi[d.at(i, j, k + 1 < d.nz ? k + 1 : d.nz - 1)];
  // The divisor is the ACTUAL span sampled: 2h in the interior, h against a face
  // where the two reads collapsed onto the same cell.
  const double sx = (i > 0 && i + 1 < d.nx) ? 2.0 * h : h;
  const double sy = (j > 0 && j + 1 < d.ny) ? 2.0 * h : h;
  const double sz = (k > 0 && k + 1 < d.nz) ? 2.0 * h : h;
  const double gx = (xp - xm) / sx, gy = (yp - ym) / sy, gz = (zp - zm) / sz;
  return std::sqrt(gx * gx + gy * gy + gz * gz);
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
void reinitialise(const Dims& d, std::vector<double>& phi, double h, int passes,
                  bool russo_smereka = false) {
  const std::size_t n = d.count();
  std::vector<char> frozen(n, 0);
  std::vector<double> mag(n, kFar);

  for (int k = 0; k < d.nz; ++k)
    for (int j = 0; j < d.ny; ++j)
      for (int i = 0; i < d.nx; ++i) {
        const std::size_t v = d.at(i, j, k);
        const double pv = phi[v];
        bool crosses = false;
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
          crosses = true;
          const double denom = std::fabs(pv) + std::fabs(pw);
          // A crossing with both ends at zero carries no sub-voxel information;
          // half a cell is the only defensible reading of it.
          const double t = denom > 0.0 ? std::fabs(pv) / denom : 0.5;
          best = std::min(best, t * h);
        }
        if (!crosses) continue;
        if (russo_smereka) {
          // ── RUSSO-SMEREKA SUBCELL FIX (J. Comput. Phys. 163:51-67, 2000) ──
          //
          // ★ WHY THE EDGE RATIO IS NOT GOOD ENOUGH, AND WHY IT SHOWS UP IN THE
          // SUB-VOXEL METRIC. The `best` above is the smallest ALONG-AXIS
          // distance to a crossing. For an interface that runs obliquely through
          // the cell — which on this part is most of it — the axis distance
          // OVERESTIMATES the true perpendicular distance by up to sqrt(3). The
          // sweep then propagates that overestimate outward, and the whole field
          // ends up with |grad phi| < 1: measured RMS error 0.20 on the run of
          // record, against the reference's own reinitialisation tolerance of
          // 0.00645.
          //
          // That is not cosmetic. rho = H_eta(-phi) maps phi linearly through the
          // band, so a phi whose gradient is 20% wrong puts the iso-0.5 crossing
          // in the wrong place inside the cell — and "where the crossing sits
          // inside the cell" IS the sub-voxel measurement (`midpoint_share`).
          // PR 321's Gridap arm spread its crossings 0.5790 mm rms against our
          // 0.2601 on the same lattice with the same band, which is the
          // signature of a cleaner distance function.
          //
          // Russo-Smereka's fix replaces the axis distance with the FIRST-ORDER
          // PERPENDICULAR one, |phi| / |grad phi|, using a robust one-sided
          // gradient so a crossing on either side is seen:
          //
          //     D_i = h * phi_i / max(|phi_{i+1}-phi_{i-1}|/2,
          //                           |phi_{i+1}-phi_i|, |phi_i-phi_{i-1}|)
          //
          // generalised to 3D by taking that per axis and combining in L2. The
          // result is the distance to the LINEARISED interface through the cell,
          // which is exact for a plane and is what the sweep should propagate.
          double g2 = 0.0;
          const int ax[3][3] = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}};
          for (const auto& a3 : ax) {
            const int im = i - a3[0], jm = j - a3[1], km = k - a3[2];
            const int ip = i + a3[0], jp = j + a3[1], kp = k + a3[2];
            const bool okm = im >= 0 && jm >= 0 && km >= 0;
            const bool okp = ip < d.nx && jp < d.ny && kp < d.nz;
            const double pm = okm ? phi[d.at(im, jm, km)] : pv;
            const double pp = okp ? phi[d.at(ip, jp, kp)] : pv;
            // ★ CENTRAL, NOT THE MAX — AND THIS WAS MEASURED, NOT ASSUMED.
            // Russo-Smereka's Delta_i takes max(central, forward, backward),
            // but that is a STABILISER for their reinitialisation PDE, where an
            // over-large denominator damps the update. Used here as a direct
            // distance seed it is BIASED: at a kink the max overshoots the true
            // |grad phi|, so |phi|/|grad phi| undershoots the true distance, and
            // the sweep propagates the shortfall over the whole field. Measured
            // with the max, 6 iterations: interface area 28073 -> 26606 against
            // the baseline's 24057, and | |grad phi|-1 | rising 0.173 -> 0.190
            // against 0.171 — both the signature of a uniformly shrunk distance
            // field (phi too flat, so more cells fall inside the band). The
            // central difference is the unbiased estimate for the smooth field
            // this is applied to.
            const double gc = (okm && okp) ? std::fabs(pp - pm) / 2.0
                                           : std::max(okp ? std::fabs(pp - pv) : 0.0,
                                                      okm ? std::fabs(pv - pm) : 0.0);
            g2 += gc * gc;
          }
          const double gmag = std::sqrt(g2);
          // The clamp is the degenerate case only: a cell whose neighbours are
          // all equal carries no direction, and the axis reading is all there is.
          if (gmag > 1e-30) best = std::min(best, std::fabs(pv) * h / gmag);
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

// ── A PERIMETER PENALTY, VIA MEAN CURVATURE ─────────────────────────────────
//
// ★ WHY. PR 324 measured the mechanism behind the roughness: the level set does
// NOT roughen the surface SIMP already has — over a fixed region of space it is
// slightly SMOOTHER than SIMP — it ADDS internal cut surface, roughly doubling
// it (18.4% of triangles -> 36.8%), and the added surface is what is rough.
// Raising alpha halves the rate of addition and does not stop it.
//
// Nothing in GridapTopOpt's formulation prices surface area: the paper has no
// perimeter term and no feature-size constraint, and alpha — a regularity
// length on the VELOCITY — only limits how fast fine structure can be driven,
// not whether it pays for itself. So this adds the term the formulation is
// missing, which is classical for level-set topology optimisation (Allaire,
// Jouve & Toader 2004; Osher & Santosa 2001): penalise the perimeter
//
//     J_total(Omega) = J(Omega) + ell * Per(Omega)
//
// whose shape derivative on the interface is the MEAN CURVATURE kappa, so the
// velocity picks up a -ell*kappa term and the flow resists creating interface.
//
// ★ THIS IS NOT THE SMOOTHING THIS PROJECT HAS ALREADY REFUSED. The two prior
// curvature no-gos (MCF, and the closing flow) were POST-PROCESSING operators
// applied to a finished design, and were refused because the staircase is in the
// GRID and no curvature operator can remove it without eating real features.
// This is a term in the OBJECTIVE: it changes which design the optimiser walks
// to, so no already-earned geometry is smoothed away — the structure is never
// built. Whether that is worth its stiffness is a MEASUREMENT, and the margin
// column is what answers it.
//
// kappa = div(grad phi / |grad phi|), the standard conservative 3D form:
//
//   kappa = [ pxx(py^2+pz^2) + pyy(px^2+pz^2) + pzz(px^2+py^2)
//             - 2(px py pxy + px pz pxz + py pz pyz) ] / (px^2+py^2+pz^2)^{3/2}
//
// Curvature is capped at 1/h: on a grid, a radius below one voxel is not
// resolvable, and an uncapped kappa there is noise amplified by a division by a
// vanishing gradient.
double mean_curvature(const Dims& d, const std::vector<double>& phi, int i, int j,
                      int k, double h) {
  auto P = [&](int a, int b, int c) {
    a = std::min(std::max(a, 0), d.nx - 1);
    b = std::min(std::max(b, 0), d.ny - 1);
    c = std::min(std::max(c, 0), d.nz - 1);
    return phi[d.at(a, b, c)];
  };
  const double c0 = P(i, j, k);
  const double px = (P(i + 1, j, k) - P(i - 1, j, k)) / (2.0 * h);
  const double py = (P(i, j + 1, k) - P(i, j - 1, k)) / (2.0 * h);
  const double pz = (P(i, j, k + 1) - P(i, j, k - 1)) / (2.0 * h);
  const double pxx = (P(i + 1, j, k) - 2.0 * c0 + P(i - 1, j, k)) / (h * h);
  const double pyy = (P(i, j + 1, k) - 2.0 * c0 + P(i, j - 1, k)) / (h * h);
  const double pzz = (P(i, j, k + 1) - 2.0 * c0 + P(i, j, k - 1)) / (h * h);
  const double pxy = (P(i + 1, j + 1, k) - P(i + 1, j - 1, k) -
                      P(i - 1, j + 1, k) + P(i - 1, j - 1, k)) / (4.0 * h * h);
  const double pxz = (P(i + 1, j, k + 1) - P(i + 1, j, k - 1) -
                      P(i - 1, j, k + 1) + P(i - 1, j, k - 1)) / (4.0 * h * h);
  const double pyz = (P(i, j + 1, k + 1) - P(i, j + 1, k - 1) -
                      P(i, j - 1, k + 1) + P(i, j - 1, k - 1)) / (4.0 * h * h);
  const double g2 = px * px + py * py + pz * pz;
  if (g2 < 1e-24) return 0.0;
  const double num = pxx * (py * py + pz * pz) + pyy * (px * px + pz * pz) +
                     pzz * (px * px + py * py) -
                     2.0 * (px * py * pxy + px * pz * pxz + py * pz * pyz);
  const double kap = num / std::pow(g2, 1.5);
  const double cap = 1.0 / h;
  return std::max(-cap, std::min(cap, kap));
}

// ── (4) HILBERTIAN VELOCITY EXTENSION ───────────────────────────────────────
//
// GridapTopOpt regularises and extends the raw shape derivative by solving, for
// v-bar in a space with homogeneous Dirichlet data on the load boundary,
//
//     ∫_D ( alpha^2 grad(v-bar) . grad(w) + v-bar w ) dD = < g, w >   for all w
//
// with alpha = alpha_coeff * max(el_delta) and alpha_coeff = 4 * max_steps *
// gamma = 2.4. That is a SCREENED POISSON problem, and on this regular grid it
// discretises to the 7-point stencil
//
//     (1 + alpha^2 |N(c)| / h^2) v_c  -  (alpha^2 / h^2) sum_{n in N(c)} v_n = g_c
//
// where N(c) is the EXISTING neighbours of c. Dropping a missing neighbour from
// both the diagonal and the off-diagonals is the zero-flux (natural) condition
// their weak form already has on the parts of the boundary that carry no
// Dirichlet tag, so the box faces need no special case beyond that omission.
//
// ★ WHICH CELLS ARE PINNED. Theirs is `V_reg = TestFESpace(...;
// dirichlet_tags=["Gamma_N"])`, `U_reg = TrialFESpace(V_reg, 0)` — the LOAD
// boundary. On his job the load pad, the anchor (face 18) and the face
// protection (face 16) are exactly the voxels core tags FrozenSolid, so that set
// is the pin, and it covers all three the task names. A pinned cell holds
// v-bar = 0: it contributes to a free neighbour's diagonal and nothing to its
// right-hand side, which is what makes the extension DECAY into the pinned
// region rather than being clipped at its edge the way PR 322's post-hoc
// zeroing did.
//
// ★ WHAT IS NOT MODELLED, STATED. This is a COLLOCATION reading: the right-hand
// side is g at the cell rather than the consistent FE load vector ∫ g w, so the
// two differ by a mass-matrix scaling. It cannot affect the trajectory, because
// the only use of v-bar is a direction and a CFL time step dt = gamma*h/max|v|
// that normalises its amplitude away exactly. The SHAPE — which is the whole
// content of a Hilbertian extension — is the same operator either way.
//
// SPD (identity plus a Dirichlet-trimmed graph Laplacian), so a
// Jacobi-preconditioned CG is unconditionally convergent and needs no tuning.
// They solve to rtol 1e-12 with CG + GAMG; the same 1e-12 is the default here.
// Returns the iterations taken; `out_relres` receives the achieved relative
// residual so the run REPORTS its extension solve rather than assuming it.
int hilbertian_extend(const Dims& d, const std::vector<char>& pinned,
                      const std::vector<double>& g, std::vector<double>& v,
                      double alpha, double h, double rtol, int max_it,
                      double* out_relres) {
  const std::size_t n = d.count();
  const double a2 = alpha * alpha / (h * h);

  // The diagonal, and the neighbour count, computed once.
  std::vector<double> diag(n, 1.0);
  for (int k = 0; k < d.nz; ++k)
    for (int j = 0; j < d.ny; ++j)
      for (int i = 0; i < d.nx; ++i) {
        const std::size_t c = d.at(i, j, k);
        if (pinned[c]) continue;
        int nb = 0;
        if (i > 0) ++nb;
        if (i + 1 < d.nx) ++nb;
        if (j > 0) ++nb;
        if (j + 1 < d.ny) ++nb;
        if (k > 0) ++nb;
        if (k + 1 < d.nz) ++nb;
        diag[c] = 1.0 + a2 * static_cast<double>(nb);
      }

  // y <- A x, over the FREE cells only; pinned rows are the identity on a vector
  // that is zero there, so they stay zero throughout and never enter the Krylov
  // space.
  auto apply = [&](const std::vector<double>& x, std::vector<double>& y) {
    for (int k = 0; k < d.nz; ++k)
      for (int j = 0; j < d.ny; ++j)
        for (int i = 0; i < d.nx; ++i) {
          const std::size_t c = d.at(i, j, k);
          if (pinned[c]) { y[c] = 0.0; continue; }
          double s = 0.0;
          if (i > 0) s += x[d.at(i - 1, j, k)];
          if (i + 1 < d.nx) s += x[d.at(i + 1, j, k)];
          if (j > 0) s += x[d.at(i, j - 1, k)];
          if (j + 1 < d.ny) s += x[d.at(i, j + 1, k)];
          if (k > 0) s += x[d.at(i, j, k - 1)];
          if (k + 1 < d.nz) s += x[d.at(i, j, k + 1)];
          y[c] = diag[c] * x[c] - a2 * s;
        }
  };

  std::vector<double> r(n), z(n), p(n), Ap(n);
  std::fill(v.begin(), v.end(), 0.0);  // cold start: v-bar is a pure function of g
  for (std::size_t c = 0; c < n; ++c) r[c] = pinned[c] ? 0.0 : g[c];

  double rnorm0 = 0.0;
  for (std::size_t c = 0; c < n; ++c) rnorm0 += r[c] * r[c];
  rnorm0 = std::sqrt(rnorm0);
  if (out_relres) *out_relres = 0.0;
  if (rnorm0 == 0.0) return 0;

  for (std::size_t c = 0; c < n; ++c) z[c] = r[c] / diag[c];
  p = z;
  double rz = 0.0;
  for (std::size_t c = 0; c < n; ++c) rz += r[c] * z[c];

  int it = 0;
  double rel = 1.0;
  for (; it < max_it; ++it) {
    apply(p, Ap);
    double pAp = 0.0;
    for (std::size_t c = 0; c < n; ++c) pAp += p[c] * Ap[c];
    if (pAp <= 0.0) break;  // cannot happen for an SPD operator; not assumed
    const double al = rz / pAp;
    double rnorm = 0.0;
    for (std::size_t c = 0; c < n; ++c) {
      v[c] += al * p[c];
      r[c] -= al * Ap[c];
      rnorm += r[c] * r[c];
    }
    rel = std::sqrt(rnorm) / rnorm0;
    if (rel < rtol) { ++it; break; }
    for (std::size_t c = 0; c < n; ++c) z[c] = r[c] / diag[c];
    double rz_new = 0.0;
    for (std::size_t c = 0; c < n; ++c) rz_new += r[c] * z[c];
    const double beta = rz_new / rz;
    rz = rz_new;
    for (std::size_t c = 0; c < n; ++c) p[c] = z[c] + beta * p[c];
  }
  if (out_relres) *out_relres = rel;
  return it;
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

// ── WENO5 + TVD-RK3: the sharp-interface Hamilton-Jacobi scheme ─────────────
//
// ★ WHY. The advection so far is FIRST-ORDER upwind (Godunov with plain one-sided
// differences) and forward Euler in time. That is the scheme GridapTopOpt uses
// too — its `FirstOrderStencil` — so matching it was right for PR 323/324. But
// first order is DIFFUSIVE: each sub-step smears the level set by O(h), and the
// interface's sub-voxel position is exactly what the roughness and midpoint
// metrics read. With 24 sub-steps per iteration the smearing compounds before
// reinitialisation gets a chance to correct it.
//
// WENO5 (Jiang & Peng 2000; Osher & Fedkiw, "Level Set Methods and Dynamic
// Implicit Surfaces", §3.4) is the standard fix: a fifth-order essentially
// non-oscillatory reconstruction of the one-sided derivatives, which keeps the
// interface sharp without ringing at kinks — and a level set of a real part is
// all kinks, so the non-oscillatory part is not optional. TVD-RK3 (Shu & Osher)
// is its time-stepping partner; forward Euler would throw away the spatial order.
//
// This is a DEPARTURE from the reference, not a match to it, and it is the one
// piece of the max-effort arm that no longer claims to be what Gridap does.
double weno_deriv(double v1, double v2, double v3, double v4, double v5) {
  const double s1 = 13.0 / 12.0 * (v1 - 2.0 * v2 + v3) * (v1 - 2.0 * v2 + v3) +
                    0.25 * (v1 - 4.0 * v2 + 3.0 * v3) * (v1 - 4.0 * v2 + 3.0 * v3);
  const double s2 = 13.0 / 12.0 * (v2 - 2.0 * v3 + v4) * (v2 - 2.0 * v3 + v4) +
                    0.25 * (v2 - v4) * (v2 - v4);
  const double s3 = 13.0 / 12.0 * (v3 - 2.0 * v4 + v5) * (v3 - 2.0 * v4 + v5) +
                    0.25 * (3.0 * v3 - 4.0 * v4 + v5) * (3.0 * v3 - 4.0 * v4 + v5);
  // Jiang-Peng's scale-aware epsilon: relative to the local magnitude, so the
  // weights do not collapse on a flat stretch or blow up on a steep one.
  double m = v1 * v1;
  m = std::max(m, v2 * v2);
  m = std::max(m, v3 * v3);
  m = std::max(m, v4 * v4);
  m = std::max(m, v5 * v5);
  const double eps = 1e-6 * m + 1e-99;
  const double a1 = 0.1 / ((s1 + eps) * (s1 + eps));
  const double a2 = 0.6 / ((s2 + eps) * (s2 + eps));
  const double a3 = 0.3 / ((s3 + eps) * (s3 + eps));
  const double sum = a1 + a2 + a3;
  return (a1 * (v1 / 3.0 - 7.0 * v2 / 6.0 + 11.0 * v3 / 6.0) +
          a2 * (-v2 / 6.0 + 5.0 * v3 / 6.0 + v4 / 3.0) +
          a3 * (v3 / 3.0 + 5.0 * v4 / 6.0 - v5 / 6.0)) / sum;
}

// |grad phi| by the Godunov selection, with WENO5 one-sided derivatives.
// Upwinding follows sign(v), exactly as the first-order `godunov_grad` does —
// only the derivative estimates change.
double weno_grad(const Dims& d, const std::vector<double>& phi, int i, int j,
                 int k, double v, double h) {
  auto P = [&](int a, int b, int c) {
    a = std::min(std::max(a, 0), d.nx - 1);
    b = std::min(std::max(b, 0), d.ny - 1);
    c = std::min(std::max(c, 0), d.nz - 1);
    return phi[d.at(a, b, c)];
  };
  auto sq = [](double x) { return x * x; };
  double g2 = 0.0;
  const int ax[3][3] = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}};
  for (const auto& e : ax) {
    // The seven samples the two five-point stencils are built from.
    double s[7];
    for (int m = -3; m <= 3; ++m)
      s[m + 3] = P(i + e[0] * m, j + e[1] * m, k + e[2] * m);
    double dd[6];
    for (int m = 0; m < 6; ++m) dd[m] = (s[m + 1] - s[m]) / h;
    const double dm = weno_deriv(dd[0], dd[1], dd[2], dd[3], dd[4]);  // backward
    const double dp = weno_deriv(dd[5], dd[4], dd[3], dd[2], dd[1]);  // forward
    if (v > 0.0) g2 += sq(std::max(dm, 0.0)) + sq(std::min(dp, 0.0));
    else         g2 += sq(std::min(dm, 0.0)) + sq(std::max(dp, 0.0));
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

// The reinitialisation's OWN residual: | |grad phi| - 1 | over the band, the
// property fast sweeping and their reinitialisation-by-PDE are both reaching
// for. Reported per iteration so "our sweeping reaches what their
// tol = 1/(5 order^2)/min(el_size) = 0.00645 reaches" is a MEASUREMENT and not a
// claim.
//
// ★ RMS, AND THE MAX BESIDE IT — NOT THE MAX ALONE. The exact signed distance
// function of any solid has KINKS: on the medial axis the nearest boundary point
// changes discontinuously and the discrete central difference of |grad phi| is
// 0, so the error there is exactly 1. His part's thinnest members are near the
// minimum feature size, so their medial axes lie INSIDE the two-voxel band and
// the max is pinned at 1.0 by geometry that is CORRECT — measured on the
// 3-iteration smoke run, exactly 1.00e+00 on every iteration. A statistic that
// saturates on the right answer measures nothing. The RMS is the one to read;
// the max is carried rather than dropped so nobody has to wonder what it was.
struct ReinitResidual {
  double rms = -1.0;
  double max = -1.0;
};

ReinitResidual reinit_residual(const Dims& d, const std::vector<double>& phi,
                               double h, double band) {
  ReinitResidual r;
  double sum2 = 0.0, worst = 0.0;
  std::size_t cnt = 0;
  for (int k = 0; k < d.nz; ++k)
    for (int j = 0; j < d.ny; ++j)
      for (int i = 0; i < d.nx; ++i) {
        if (std::fabs(phi[d.at(i, j, k)]) > band) continue;
        const double e = std::fabs(grad_mag(d, phi, i, j, k, h) - 1.0);
        sum2 += e * e;
        worst = std::max(worst, e);
        ++cnt;
      }
  if (cnt) {
    r.rms = std::sqrt(sum2 / static_cast<double>(cnt));
    r.max = worst;
  }
  return r;
}

// ── THE OSCILLATION DAMPER (arXiv 2405.10478 §4.1.8) ────────────────────────
//
// A SIXTH difference, which the task's five did not name and which only reading
// the paper surfaced:
//
//   "We slightly modify the method to include a check for oscillations of the
//    Lagrangian using the has_oscillations function. If oscillations are
//    detected we reduce the CFL number gamma for the Hamilton-Jacobi evolution
//    equation by 25%."
//
// Our gamma is otherwise FIXED at 0.1 for the whole run, so an explicit
// Hamilton-Jacobi step that starts to ring has nothing pulling it back.
//
// ★ THIS IS AN EQUIVALENT, NOT A TRANSCRIPTION, and the difference is stated
// because it matters: their `has_oscillations` is a function of the AUGMENTED
// LAGRANGIAN, which we do not carry (we use the delta-weighted lambda plus the
// offset bisection instead — see the handoff). This reads the same signal off
// the objective we DO carry.
//
// ★ TWO CONDITIONS, AND THE SECOND WAS LEARNED THE HARD WAY. Sign flips alone
// are NOT enough. A first cut of this fired on every window and annealed gamma
// geometrically (0.1 -> 0.075 -> 0.05625 -> 0.042 in twenty iterations), which
// would have frozen the design short of its fixed point and then let the plateau
// test call that "converged". The trajectory it fired on was a noisy DESCENT —
// compliance 0.0025450 falling to 0.0025402 across the window while rippling
// +-0.2% on the way. That is not an oscillation, and damping it only slows the
// run down.
//
// So the trigger is: the objective makes NO NET PROGRESS across the window
// (their check is for a Lagrangian that has stopped descending — one that is
// still going down is not oscillating), AND its increments change sign at least
// twice inside it.
bool has_oscillations(const std::vector<double>& hist, int window) {
  const int n = static_cast<int>(hist.size());
  if (n < window + 1) return false;
  // Condition 1: no net progress across the window.
  const double net = hist[static_cast<std::size_t>(n - 1)] -
                     hist[static_cast<std::size_t>(n - 1 - window)];
  if (net < 0.0) return false;
  // Condition 2: the increments alternate.
  int flips = 0, prev = 0;
  for (int i = n - window; i < n; ++i) {
    const double diff = hist[static_cast<std::size_t>(i)] -
                        hist[static_cast<std::size_t>(i - 1)];
    const int s = diff > 0.0 ? 1 : (diff < 0.0 ? -1 : 0);
    if (s != 0) {
      if (prev != 0 && s != prev) ++flips;
      prev = s;
    }
  }
  return flips >= 2;
}

struct Args {
  std::string step, materials, ref_design, out;
  double rung = 0.68;
  // ★ 300, the task's budget. PR 322 ran 120 and had not converged; with six HJ
  // steps per solve this should need FEWER, not more.
  int iters = 300;
  // ★ DIFFERENCE 5: their eta_coeff = 2, so H_eta spans four voxels.
  double eta_voxels = 2.0;
  // ★ DIFFERENCE 3: their gamma and their max_steps =
  // floor(order * min(el_size) / 5) = floor(1 * 31 / 5) = 6 on his grid.
  double gamma = 0.1;
  int hj_steps = 6;
  // ★ DIFFERENCE 4: their alpha_coeff = 4 * max_steps * gamma = 2.4, in units of
  // max(el_delta) — the grid is isotropic here, so that is 2.4 voxels. 0 DISARMS
  // the Hilbertian solve and falls back to PR 322's [1 2 1] passes, as a control.
  double alpha_coeff = 2.4;
  double hilb_rtol = 1e-12;
  int hilb_max_it = 2000;
  int smooth = 4;  // only reachable with --alpha-coeff 0
  // ★ DIFFERENCE 2: 1.0 is their LINEAR interpolation. The CERTIFICATION is
  // unaffected — it always runs at the production penalty 3.
  double traj_penalty = 1.0;
  // ★ 3 THREADS. He needs his Mac during the day. The matrix-free apply is
  // bit-identical at any count (production.hpp: the 8-colour partition fixes the
  // accumulation order), so this can only change the wall clock.
  int threads = 3;
  std::string seed = "simp";
  bool fp32 = false;
  bool isolate = false;
  int reinit_every = 1;
  int sweeps = 8;
  // Every N iterations, write the occupancy so external_field_surface_probe can
  // measure the ROUGHNESS CURVE afterwards — the instrument invoked, never
  // retyped. 0 disables.
  int snapshot_every = 10;
  // The 3-THREAD SIMP BASELINE: run the SHIPPED ladder at a single rung in this
  // same posture, so the seconds-per-iteration comparison is between two numbers
  // measured on the same machine at the same thread count.
  bool simp = false;
  std::string rules;
  // ── A CONTROL, NOT THE RUN OF RECORD ──────────────────────────────────────
  // Re-certify an occupancy already on disk (`<prefix>.f64` + `.meta`, the same
  // pair external_field_surface_probe eats) at the PRODUCTION penalty. With
  // --binarize the field is thresholded at the iso first.
  //
  // ★ WHY IT EXISTS. The run of record certifies the ERSATZ field, band and all,
  // exactly as PR 322 did and exactly as R3 requires. But at eta = 2 voxels that
  // band is FOUR voxels wide, and the object that actually gets printed is
  // BINARY. So "the margin moved because the design is weaker" and "the margin
  // moved because the certificate is reading a wider gray band" are two different
  // findings with the same number, and nothing in the run of record separates
  // them. This does, for the price of one analyze_fixed_design call on a file.
  std::vector<std::string> certify_field;
  bool binarize = false;

  // ── THEIR OWN PARAMETER RULE, MADE EXECUTABLE ─────────────────────────────
  //
  // arXiv 2405.10478, Appendix B line 18 and §4.1.6:
  //     max_steps = floor(order * minimum(el_size) / 10)   [DOUBLED in 3D:
  //         "we double the number of max_steps ... as we have found that this
  //          yields better convergence for three-dimensional problems"]
  //     alpha     = 4 * max_steps * gamma * maximum(el_delta)
  // and, in their words, alpha is "the so-called REGULARISATION LENGTH SCALE",
  // chosen so that "the number of elements over which we regularise the gradient
  // is increased" as the mesh is refined.
  //
  // ★ THE RULE DOES NOT TRANSFER TO A SLAB, AND THAT IS THE FINDING. Since
  // gamma = 0.1, the regularisation length in VOXELS is just 0.4 * max_steps.
  // Their examples:
  //     2D  200 x 200        -> max_steps 20 -> alpha  8.0 voxels
  //     3D  150 x 150 x 150  -> max_steps 30 -> alpha 12.0 voxels
  // His part is 128 x 31 x 118. `minimum(el_size)` is 31 — the THIN axis, not
  // the resolution — so the rule returns max_steps 6 and alpha 2.4 voxels, FIVE
  // TIMES less regularisation than their own 3D example, on a mesh with 15x the
  // elements of a 31^3 one. On their cubic meshes the minimum axis IS the
  // resolution and the proxy is sound; on a 4:1 slab it is not.
  //
  //   --gridap-auto min   their formula as written  -> 6 steps, alpha 2.4
  //                       (a POSITIVE CONTROL: it must reproduce the run of
  //                        record's parameters exactly)
  //   --gridap-auto max   the same formula keyed to the RESOLUTION axis
  //                       -> 24 steps, alpha 9.6, inside their 8-12 range
  //
  // The coupling alpha = 4 * max_steps * gamma * h is preserved either way, so
  // this is their rule with one substitution, not a tuned number.
  std::string gridap_auto;

  // ── THE MAX-EFFORT ARM'S PIECES, each independently switchable so the arm
  // can be ATTRIBUTED afterwards rather than only celebrated. All default OFF,
  // so every earlier run reproduces byte-for-byte.
  //
  // --russo-smereka   the subcell-fix reinitialisation (see `reinitialise`)
  // --perimeter C     the mean-curvature / perimeter penalty. C is
  //                   DIMENSIONLESS: the term enters as ell*kappa with
  //                   ell = C * lambda * h, so it is scaled to the energy
  //                   multiplier the flow is already using and to the grid. C=0
  //                   is off; C=1 makes a one-voxel-radius feature cost about
  //                   what one band-mean of strain energy buys.
  // --reinit-substeps reinitialise between HJ sub-steps, not only after the
  //                   last one — keeps |grad phi| near 1 through a 24-step
  //                   advection instead of letting it drift and correcting once.
  bool russo_smereka = false;
  double perimeter = 0.0;
  bool reinit_substeps = false;
  // --weno   WENO5 one-sided derivatives in the Godunov gradient (5th order,
  //          essentially non-oscillatory) instead of plain first-order ones.
  // --rk3    TVD-RK3 time stepping instead of forward Euler. Pairs with --weno;
  //          Euler would throw away WENO5's spatial order. Costs 3 gradient
  //          evaluations per sub-step.
  bool weno = false;
  bool rk3 = false;
  // --no-surface-delta  restore PR 322's VOLUME velocity: v = (energy - lambda)
  //   over the whole active domain, WITHOUT the DH_eta(phi)*|grad phi| factor.
  //   ★ Why this exists: PR 322 — written before the reference paper was read —
  //   still owns the best surface of any arm (cut 6.7080, whole 8.1797) at
  //   margin 3378.49, and DOMINATES both SIMP and every arm from the three
  //   sessions spent matching the reference. It ran 120 iterations and never
  //   converged, and PR 325 then showed margin saturates around iteration 20.
  //   So the best configuration we own has never been run with the stopping
  //   rule, nor without the offset defect PR 323 fixed. This flag makes that
  //   run possible.
  bool no_surface_delta = false;

  // Their gamma damper (see has_oscillations above). Off by default so the run
  // of record is unchanged.
  bool damp = false;
  double damp_factor = 0.75;  // theirs: "reduce ... by 25%"
  int damp_window = 5;        // theirs: the 5-iteration stopping window
};

}  // namespace

int main(int argc, char** argv) {
  Args a;
  if (argc < 5) {
    std::printf(
        "usage: levelset_probe <part.step> <materials.json> <ref_design.bin> "
        "<out_dir>\n"
        "       [--rung R] [--iters N] [--eta VOXELS] [--gamma G] "
        "[--hj-steps N]\n"
        "       [--alpha-coeff A] [--hilb-rtol T] [--traj-penalty P] "
        "[--threads N]\n"
        "       [--seed simp|holes] [--fp32] [--isolate] [--reinit-every N]\n"
        "       [--sweeps N] [--snapshot-every N] [--smooth N]\n"
        "       [--gridap-auto min|max]  their max_steps/alpha rule, evaluated\n"
        "       [--damp] [--damp-factor 0.75] [--damp-window 5]  their gamma "
        "damper\n"
        "       [--simp --rules <rules.json>]   the 3-thread SIMP baseline\n"
        "       [--certify-field <prefix> [--binarize]]   a re-cert control\n");
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
    else if (s == "--gamma") next(a.gamma);
    else if (s == "--hj-steps") nexti(a.hj_steps);
    else if (s == "--alpha-coeff") next(a.alpha_coeff);
    else if (s == "--hilb-rtol") next(a.hilb_rtol);
    else if (s == "--hilb-max-it") nexti(a.hilb_max_it);
    else if (s == "--traj-penalty") next(a.traj_penalty);
    else if (s == "--threads") nexti(a.threads);
    else if (s == "--smooth") nexti(a.smooth);
    else if (s == "--reinit-every") nexti(a.reinit_every);
    else if (s == "--sweeps") nexti(a.sweeps);
    else if (s == "--snapshot-every") nexti(a.snapshot_every);
    else if (s == "--fp32") a.fp32 = true;
    else if (s == "--isolate") a.isolate = true;
    else if (s == "--simp") a.simp = true;
    else if (s == "--binarize") a.binarize = true;
    else if (s == "--damp") a.damp = true;
    else if (s == "--russo-smereka") a.russo_smereka = true;
    else if (s == "--perimeter") next(a.perimeter);
    else if (s == "--reinit-substeps") a.reinit_substeps = true;
    else if (s == "--weno") a.weno = true;
    else if (s == "--rk3") a.rk3 = true;
    else if (s == "--no-surface-delta") a.no_surface_delta = true;
    else if (s == "--damp-factor") next(a.damp_factor);
    else if (s == "--damp-window") nexti(a.damp_window);
    else if (s == "--gridap-auto" && i + 1 < argc) a.gridap_auto = argv[++i];
    else if (s == "--rules" && i + 1 < argc) a.rules = argv[++i];
    else if (s == "--certify-field" && i + 1 < argc) a.certify_field.push_back(argv[++i]);
    else if (s == "--seed" && i + 1 < argc) a.seed = argv[++i];
    else { std::printf("FATAL: unknown argument %s\n", s.c_str()); return 2; }
  }
  if (a.simp && a.rules.empty()) {
    std::printf("FATAL: --simp needs --rules <settings/rules.json> (the shipped\n"
                "       ladder takes the rule table the CLI takes)\n");
    return 2;
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

  // ── THE TWO MATERIAL LAWS (difference 2) ──────────────────────────────────
  //
  // `params` is PRODUCTION'S, penalty 3, and it is what CERTIFIES. It is built
  // first and never modified, so no later line can reach the certificate.
  SimpParams params;
  params.youngs_modulus = material.youngs_modulus_mpa;
  params.poisson = material.poisson;
  params.penalty = 3.0;

  // `traj_params` is the TRAJECTORY's, and at the default penalty 1.0 it is
  // E(rho) = rho * E0 — GridapTopOpt's linear I(phi) exactly, with rho_min = 1e-3
  // already equal to their epsilon.
  SimpParams traj_params = params;
  traj_params.penalty = a.traj_penalty;

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

  // ── THEIR PARAMETER RULE, EVALUATED ON THIS GRID ──────────────────────────
  //
  // See Args::gridap_auto for the rule, the quotes it comes from, and why the
  // axis choice is the whole finding. `order` is 1 (trilinear hexes, as their
  // order = 1), and the 3D doubling is theirs.
  if (!a.gridap_auto.empty()) {
    const int axis_min = std::min({d.nx, d.ny, d.nz});
    const int axis_max = std::max({d.nx, d.ny, d.nz});
    int axis;
    if (a.gridap_auto == "min") axis = axis_min;
    else if (a.gridap_auto == "max") axis = axis_max;
    else {
      std::printf("FATAL: --gridap-auto must be min or max\n");
      return 2;
    }
    const int order = 1;
    // floor(order * axis / 10), DOUBLED for 3D — both theirs.
    const int steps = 2 * static_cast<int>(std::floor(order * axis / 10.0));
    a.hj_steps = steps;
    a.alpha_coeff = 4.0 * steps * a.gamma;
    std::printf("\n-- --gridap-auto %s: their rule, evaluated here --\n",
                a.gridap_auto.c_str());
    std::printf("   el_size            %d x %d x %d   (min %d, max %d)\n", d.nx,
                d.ny, d.nz, axis_min, axis_max);
    std::printf("   axis used          %d  %s\n", axis,
                a.gridap_auto == "min"
                    ? "= their minimum(el_size) — THE THIN AXIS on this part"
                    : "= the RESOLUTION axis (the corrected transfer)");
    std::printf("   max_steps          2*floor(%d*%d/10) = %d\n", order, axis,
                steps);
    std::printf("   alpha              4*%d*%.4g = %.4g voxels   "
                "(their 2D example 8.0, their 3D example 12.0)\n\n",
                steps, a.gamma, a.alpha_coeff);
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

  // ── THE THREAD COUNT, AND WHY IT IS 3 AND NOT PRODUCTION'S 6 ──────────────
  //
  // He needs his Mac during the day. production.hpp names the one safe way to do
  // this — "call fea_set_matfree_threads AFTER configure_production_options" —
  // and `build_production_loadcase` has already run that, so this is the
  // documented override and not a fight with it.
  //
  // ★ IT CANNOT CHANGE AN ANSWER. The matrix-free apply threads a deterministic
  // 8-colour (2x2x2) partition: no two threads touch the same node and the
  // accumulation order is set by the colour scheme, NOT the thread count, so the
  // computed field is bit-identical at any count (fea.hpp,
  // fea_set_matfree_threads). It can only change the wall clock — which is
  // exactly why the SIMP baseline has to be re-measured at the SAME count before
  // any seconds-per-iteration row is put beside another.
  const int prev_threads = fea_matfree_thread_count();
  if (a.threads > 0) fea_set_matfree_threads(a.threads);
  const int threads_now = fea_matfree_thread_count();

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
  // ── the five differences, echoed so the log says what ran ─────────────────
  //
  // NOT in --simp mode: the SIMP baseline is the shipped ladder and runs none of
  // them, so printing them there would describe a run that did not happen.
  if (!a.simp) {
  std::printf("\n-- the five differences from PR 322 --\n");
  std::printf("(1) surface delta  DH_eta(phi) * |grad phi| on BOTH the compliance "
              "and volume terms\n");
  std::printf("(2) trajectory law penalty %.4g  %s   (certification stays at %.4g)\n",
              a.traj_penalty,
              a.traj_penalty == 1.0 ? "= their LINEAR I(phi)" : "(NOT theirs)",
              params.penalty);
  std::printf("(3) HJ steps       %d per state solve, gamma %.4g  "
              "(their floor(order*min(el_size)/5) = %d)\n",
              a.hj_steps, a.gamma,
              static_cast<int>(std::floor(std::min({d.nx, d.ny, d.nz}) / 5.0)));
  std::printf("(4) extension      %s\n",
              a.alpha_coeff > 0.0 ? "HILBERTIAN screened-Poisson"
                                  : "[1 2 1] passes (PR 322's, a control)");
  if (a.alpha_coeff > 0.0)
    std::printf("                   alpha = %.4g voxels = %.6f mm, rtol %.3g, "
                "Dirichlet v=0 on %zu FrozenSolid cells\n",
                a.alpha_coeff, a.alpha_coeff * h, a.hilb_rtol, n_fsolid);
  else
    std::printf("                   %d separable [1 2 1]/4 passes\n", a.smooth);
  std::printf("(5) band eta       %.4g voxels (their eta_coeff = 2)\n\n",
              a.eta_voxels);
  }
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

  // ── A CONTROL: RE-CERTIFY A FIELD ALREADY ON DISK ─────────────────────────
  //
  // Reads `<prefix>.f64` as an occupancy on this grid and certifies it at the
  // PRODUCTION penalty, isolated exactly as production isolates a
  // re-certification. `--binarize` thresholds it at the iso first, which is what
  // makes the pair of runs an ATTRIBUTION: same design, band vs no band.
  //
  // This does not touch and cannot change the run of record's certificate — it
  // is a separate invocation on a file the run of record already wrote.
  // ★ MANY FIELDS PER PROCESS. `--certify-field` may be repeated. Each
  // invocation of this program pays ~40 s to import the STEP, voxelize and build
  // the load case before it can certify anything, and a margin CURVE needs
  // twenty-odd certifications — so the setup is amortised rather than paid
  // twenty-odd times. The certifications themselves are independent and
  // identical to one-per-process: the posture is disarmed once, below, and
  // `analyze_fixed_design` carries no state between calls once recycling and
  // GenEO are off, which is exactly the isolation production certifies under.
  // A `margin_curve.csv` is written alongside so the curve is one file.
  if (!a.certify_field.empty()) {
  std::ofstream mcsv(a.out + "/margin_curve.csv");
  mcsv.precision(12);
  mcsv << "field,printed_voxels,achieved_vf,fractional_samples,max_von_mises_mpa,"
          "margin_worst_case,margin_effective,accepted,min_feature_violations,"
          "load_path_connected\n";
  for (const std::string& cf : a.certify_field) {
    std::vector<double> f(n, 0.0);
    {
      std::ifstream in(cf + ".f64", std::ios::binary);
      if (!in) {
        std::printf("FATAL: cannot read %s.f64\n", cf.c_str());
        return 2;
      }
      in.read(reinterpret_cast<char*>(f.data()),
              static_cast<std::streamsize>(n * sizeof(double)));
      if (static_cast<std::size_t>(in.gcount()) != n * sizeof(double)) {
        std::printf("FATAL: %s.f64 is %lld bytes, this grid needs %zu\n",
                    cf.c_str(),
                    static_cast<long long>(in.gcount()), n * sizeof(double));
        return 2;
      }
    }
    const double cert_iso = 0.5;
    std::size_t frac = 0;
    for (std::size_t v = 0; v < n; ++v)
      if (f[v] > 0.0 && f[v] < 1.0) ++frac;
    if (a.binarize)
      for (std::size_t v = 0; v < n; ++v) f[v] = f[v] > cert_iso ? 1.0 : 0.0;

    std::vector<double> crho(n, 0.0);
    for (std::size_t v = 0; v < n; ++v)
      crho[v] = params.density_min + (1.0 - params.density_min) * f[v];
    std::size_t cprinted = 0;
    for (std::size_t v = 0; v < n; ++v)
      if (f[v] > cert_iso) ++cprinted;

    fea_set_krylov_recycling(false);
    fea_set_geneo_twolevel(false);
    fea_set_matfree_mixed_precision(false);
    const bool cok = load_path_connected(grid, crho, cert_iso);
    const KnockdownSpec ck = knockdown_spec_for(options);
    FixedDesignAnalysis ca;
    bool cdone = false;
    try {
      ca = analyze_fixed_design(grid, params, crho, bcs, loads, material,
                                options.build_direction, options.simp.cg_tolerance,
                                options.simp.cg_max_iterations, options.simp.solver,
                                options.margin_stop, ck, cok, part_solid);
      cdone = true;
    } catch (const std::exception& e) {
      std::printf("CERTIFICATION FAILED: %s\n", e.what());
    }
    char cbuf[2048];
    std::snprintf(cbuf, sizeof cbuf,
                  "== re-certification control ==\n"
                  "field                %s.f64\n"
                  "binarized            %s\n"
                  "fractional samples   %zu (before any thresholding)\n"
                  "certification penalty %.4g (production)\n"
                  "printed voxels       %zu of %.0f  (vf %.6f)\n",
                  cf.c_str(), a.binarize ? "YES (0/1 at iso 0.5)" : "no",
                  frac, params.penalty, cprinted, part_solid,
                  cprinted / part_solid);
    std::string cs = cbuf;
    if (cdone && !ca.non_convergent) {
      std::snprintf(cbuf, sizeof cbuf,
                    "max von Mises        %.9f MPa\n"
                    "MARGIN worst case    %.9f\n"
                    "margin effective     %.9f   (gate: >= %.4g)\n"
                    "VERDICT              %s\n"
                    "min-feature viols    %d\n"
                    "load path connected  %s\n",
                    ca.max_von_mises, ca.margin.worst_case, ca.margin_effective,
                    options.margin_stop, ca.accepted ? "ACCEPTED" : "REJECTED",
                    ca.v3.min_feature_violations, cok ? "yes" : "NO");
      cs += cbuf;
    } else if (cdone) {
      cs += "certification        NON-CONVERGENT — NOT a certificate\n";
    } else {
      cs += "certification        DID NOT RUN\n";
    }
    std::printf("\n%s", cs.c_str());
    std::fflush(stdout);
    // One row per field, so the CURVE is one file rather than N directories.
    mcsv << cf << ',' << cprinted << ',' << (cprinted / part_solid) << ','
         << frac << ',';
    if (cdone && !ca.non_convergent)
      mcsv << ca.max_von_mises << ',' << ca.margin.worst_case << ','
           << ca.margin_effective << ',' << (ca.accepted ? 1 : 0) << ','
           << ca.v3.min_feature_violations << ',' << (cok ? 1 : 0) << '\n';
    else
      mcsv << ",,,,," << (cok ? 1 : 0) << '\n';
    mcsv.flush();
    // `recert.txt` keeps its single-field meaning: the LAST field certified.
    // The curve is `margin_curve.csv`.
    { std::ofstream s(a.out + "/recert.txt"); s << cs; }
  }
    fea_set_matfree_threads(prev_threads);
    fea_set_matfree_mixed_precision(prev_mixed);
    fea_set_geneo_twolevel(prev_geneo);
    fea_set_krylov_recycling(prev_recycle);
    return 0;
  }

  // ── THE 3-THREAD SIMP BASELINE ────────────────────────────────────────────
  //
  // ★ WHY THIS MODE EXISTS. PR 322's 25.09 s/iteration was measured at SIX
  // threads against a SIMP baseline also measured at six (its `run_info.json`:
  // `matfree_threads: 6`). This task runs at THREE, and a 3-thread level set put
  // beside a 6-thread SIMP is not a comparison. So the baseline is re-measured
  // HERE, at the same count, in the same process posture, on the same machine.
  //
  // ★ IT IS THE SHIPPED LADDER, INVOKED AND NOT RETYPED. `minimize_plastic` is
  // core's own public entry — the one `topopt-cli run` calls at run_job.cpp:8254
  // — handed `build_production_loadcase`'s options verbatim with the ladder
  // narrowed to the single rung under test. Not one line of the optimizer is
  // restated in this file. The only thing that differs from the production run
  // that produced `s2_simp_baseline` is the ladder length and the thread count,
  // and neither can change a design (the ladder rungs after the first are
  // independent runs seeded from it, and the thread count is bit-identical by
  // construction).
  if (a.simp) {
    SettingsRules rules;
    try {
      rules = load_settings_rules_file(a.rules);
    } catch (const std::exception& e) {
      std::printf("FATAL: could not load %s: %s\n", a.rules.c_str(), e.what());
      return 2;
    }
    MinimizePlasticOptions sopts = setup.options;
    sopts.volume_fraction_ladder = {a.rung};

    std::ofstream scsv(a.out + "/simp_iterations.csv");
    scsv.precision(12);
    scsv << "iteration,compliance,achieved_vf,change,cg_iterations,"
            "used_multigrid,iteration_wall_s\n";

    double t_prev = 0.0;
    int simp_iters = 0;
    double simp_traj_wall = 0.0;
    sopts.on_iteration = [&](std::size_t, std::size_t,
                             const SimpIterationObservation& obs) {
      const double t = now_s();
      const double dtw = t - t_prev;
      t_prev = t;
      simp_traj_wall += dtw;
      simp_iters = obs.iteration;
      scsv << obs.iteration << ',' << obs.compliance << ',' << obs.volume_fraction
           << ',' << obs.change << ',' << obs.cg_iterations << ','
           << (obs.cg_used_multigrid ? 1 : 0) << ',' << dtw << '\n';
      scsv.flush();
      std::printf("simp it %3d  c = %.10g  vf = %.6f  cg %d%s  %.2f s\n",
                  obs.iteration, obs.compliance, obs.volume_fraction,
                  obs.cg_iterations, obs.cg_used_multigrid ? " MG" : "", dtw);
      std::fflush(stdout);
    };

    std::printf("\n== SIMP BASELINE: the shipped minimize_plastic, ladder [%.4g], "
                "%d threads ==\n\n", a.rung, threads_now);
    const double t0 = now_s();
    t_prev = t0;
    MinimizePlasticResult mr;
    try {
      mr = minimize_plastic(grid, material, "PLA", bcs, rules, sopts);
    } catch (const std::exception& e) {
      std::printf("FATAL: the shipped ladder threw: %s\n", e.what());
      fea_set_matfree_threads(prev_threads);
      fea_set_matfree_mixed_precision(prev_mixed);
      return 3;
    }
    const double call_wall = now_s() - t0;

    // The TRAJECTORY wall is the sum of the per-iteration deltas — the same
    // quantity PR 321 summed out of the CLI's own iterations.csv `total_ms`
    // column — so this row and that one measure the same thing. The rung's
    // ANALYSIS (V3 suite, stress solve, settings) is the remainder of the call
    // and is charged separately rather than smeared across the iterations.
    const double per_iter = simp_iters ? simp_traj_wall / simp_iters : 0.0;
    char sbuf[3072];
    const MinimizePlasticVariant* v0 =
        mr.evaluated.empty() ? nullptr : &mr.evaluated.front();
    std::snprintf(
        sbuf, sizeof(sbuf),
        "== SIMP baseline (the shipped minimize_plastic) ==\n"
        "rung                 %.4g\n"
        "threads              %d\n"
        "iterations           %d\n"
        "WALL PER ITERATION   %.3f s   (trajectory %.1f s over %d iterations)\n"
        "whole-call wall      %.1f s   (of which analysis %.1f s)\n"
        "compliance           %.12g\n"
        "achieved vf          %.6f\n"
        "MARGIN worst case    %.9f\n"
        "margin effective     %.9f\n"
        "VERDICT              %s\n"
        "max von Mises        %.9f MPa\n"
        "printed fraction     %.6f\n",
        a.rung, threads_now, simp_iters, per_iter, simp_traj_wall, simp_iters,
        call_wall, call_wall - simp_traj_wall,
        v0 ? v0->optimization.compliance : 0.0,
        v0 ? v0->optimization.volume_fraction : 0.0,
        v0 ? v0->report.margin.worst_case : 0.0,
        v0 ? v0->report.margin_effective : 0.0,
        v0 ? (v0->accepted ? "ACCEPTED" : "REJECTED") : "no rung evaluated",
        v0 ? v0->report.max_stress_mpa : 0.0,
        v0 ? v0->report.printed_fraction : 0.0);
    std::printf("\n%s", sbuf);
    { std::ofstream s(a.out + "/simp_summary.txt"); s << sbuf; }

    if (v0) {
      std::vector<const MinimizePlasticVariant*> vs{v0};
      try {
        write_design_file(a.out + "/design.bin", vs, mr.solved_grid);
      } catch (const std::exception& e) {
        std::printf("WARNING: could not write design.bin: %s\n", e.what());
      }
    }
    fea_set_matfree_threads(prev_threads);
    fea_set_matfree_mixed_precision(prev_mixed);
    fea_set_geneo_twolevel(prev_geneo);
    fea_set_krylov_recycling(prev_recycle);
    std::printf("\nwrote %s/{simp_iterations.csv,simp_summary.txt,design.bin}\n",
                a.out.c_str());
    return 0;
  }

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
  // ★ NOT russo_smereka HERE. The seed is phi = 0.5 - rho, a near-binary step
  // field saturated at +-0.5: its per-cell differences are ~1.0 rather than ~h,
  // so |phi|/|grad phi| is not a distance and returns ~0.29h where the true
  // distance is ~0.5h on an oblique interface. The edge-ratio crossing
  // interpolation is well defined for ANY monotone field and is what the seed
  // needs; RS applies from the first advected reinitialisation onward, once phi
  // genuinely is a distance function.
  reinitialise(d, phi, h, a.sweeps, false);

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
  if (a.snapshot_every > 0) {
    std::error_code ec;
    std::filesystem::create_directories(a.out + "/snap", ec);
    if (ec) {
      std::printf("FATAL: could not create %s/snap: %s\n", a.out.c_str(),
                  ec.message().c_str());
      return 2;
    }
  }
  std::ofstream csv(a.out + "/iterations.csv");
  csv.precision(12);
  csv << "iteration,compliance,occupancy_volume,printed_voxels,achieved_vf,"
         "offset_mm,dt_mm_per_unit_v,max_abs_v,lambda,cg_iterations,converged,"
         "used_multigrid,solve_ms,sensitivity_ms,band_cells,hilb_iterations,"
         "hilb_relres,reinit_rms,reinit_max,hj_steps,gamma,kappa_rms,"
         "iteration_wall_s\n";

  // ── THE DIRICHLET SET FOR THE HILBERTIAN EXTENSION (difference 4) ──────────
  //
  // Theirs pins v-bar = 0 on Gamma_N, the load boundary. On his job the load pad,
  // the anchor (face 18) and the face protection (face 16) are exactly what core
  // tags FrozenSolid, so that one set is all three the task names. Computed once:
  // it is geometry, not a function of the design.
  std::vector<char> pinned(n, 0);
  for (std::size_t v = 0; v < n; ++v)
    if (eff[v] == MaskValue::FrozenSolid) pinned[v] = 1;

  std::vector<double> vel(n, 0.0), raw_vel(n, 0.0), delta(n, 0.0);
  std::vector<double> best_occ, best_rho;
  double best_compliance = std::numeric_limits<double>::infinity();
  int best_iter = -1;

  const double t_run0 = now_s();
  double total_solve_wall = 0.0, total_hilb_wall = 0.0;
  ReinitResidual last_rresid;
  long long solves_multigrid = 0, solves_total = 0;
  std::vector<double> history;
  int done_iters = 0;
  bool converged_early = false;
  double gamma_now = a.gamma;   // the damper may pull this in; a.gamma never moves
  int last_damp = -1000;
  int damp_events = 0;

  for (int it = 1; it <= a.iters; ++it) {
    const double t_it0 = now_s();

    // ── (g) THE VOLUME CONSTRAINT, AND WHY THE OFFSET IS FOLDED IN ──────────
    //
    // ★ THE OFFSET IS ADDED TO PHI, NOT CARRIED BESIDE IT. PR 322 held the
    // correction as a separate scalar and read the ersatz at phi + offset. That
    // is a defect once the velocity is concentrated at the interface by the
    // surface delta, and it is worth naming because it is invisible until then:
    //
    //   * the interface is {phi = -offset}, and difference 1 puts ALL of the
    //     velocity there, so {phi = 0} is the one surface that barely moves;
    //   * reinitialisation re-distances about {phi = 0} — it pins the band
    //     around PHI's OWN zero set and sweeps outward — so every iteration
    //     REBUILT phi from the surface that had not been advected and DISCARDED
    //     the motion at the surface that had.
    //
    // Measured on the 3-iteration smoke run before the fix: `offset_mm` sat at
    // +3.57, +3.58, +3.58 mm instead of shrinking, and the achieved volume
    // fraction moved 0.0017 in three iterations.
    //
    // Adding the constant is exact and costs nothing: a signed distance plus a
    // constant still has |grad phi| = 1, so {phi = 0} after folding is a genuine
    // offset surface of the old one and the reinitialiser, the Godunov gradient
    // and the delta now all refer to the SAME interface. It is also the
    // structure the reference has, where there is no offset at all and the
    // interface is always {phi = 0}.
    const double offset = solve_offset(target_volume);
    for (std::size_t v = 0; v < n; ++v) phi[v] += offset;
    build_fields(0.0);

    // ── THE STATE SOLVE. Core's, unmodified. ────────────────────────────────
    SimpCompliance sc;
    const double t_s0 = now_s();
    try {
      // ★ traj_params, not params — difference 2. At penalty 1 this is
      // E(rho) = rho * E0, their linear interpolation. The certificate below is
      // the only place `params` (penalty 3) is used, and it is untouched.
      sc = simp_compliance(grid, traj_params, rho, bcs, loads,
                           options.simp.cg_tolerance,
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
    const double occ_vol = volume_at(0.0);  // the offset is already IN phi

    if (sc.compliance < best_compliance) {
      best_compliance = sc.compliance;
      best_occ = occ;
      best_rho = rho;
      best_iter = it;
    }

    // ── (c) + (1) THE SHAPE DERIVATIVE, WITH THE SURFACE DELTA ──────────────
    //
    // ★ THIS IS DIFFERENCE 1, AND IT IS THE WHOLE POINT OF THE TASK. PR 322 set
    // the velocity to the strain energy density over the entire active domain —
    // a VOLUME field. Theirs is
    //
    //     dJ(q,u,phi)   = ∫ (C ⊙ eps(u) ⊙ eps(u)) q (DH ∘ phi) (norm ∘ grad phi)
    //     dVol(q,u,phi) = ∫ -1/vol_D          q (DH ∘ phi) (norm ∘ grad phi)
    //
    // The two sensitivities carry the IDENTICAL factor and differ only in
    // replacing the energy density by a constant, so the factor comes out front
    // and the velocity is (energy - lambda) * DH_eta(phi) * |grad phi|. `delta`
    // is that factor, held separately because lambda is taken UNDER IT.
    //
    // The delta is evaluated at phi ITSELF, because the volume offset has
    // already been folded into it above — so {phi = 0} IS the interface the
    // ersatz, the volume constraint, the reinitialiser and this delta all read.
    // That single interface is the point of folding it in.
    std::size_t band_n = 0;
    for (int k = 0; k < d.nz; ++k)
      for (int j = 0; j < d.ny; ++j)
        for (int i = 0; i < d.nx; ++i) {
          const std::size_t v = d.at(i, j, k);
          if (grid.tags[v] == VoxelTag::Empty || eff[v] != MaskValue::Active) {
            delta[v] = 0.0;
            raw_vel[v] = 0.0;
            continue;
          }
          if (a.no_surface_delta) {
            // PR 322's measure: a VOLUME field over the whole active domain.
            delta[v] = 1.0;
          } else {
            const double dh = dheaviside(phi[v], eta);  // the offset is IN phi
            delta[v] = dh > 0.0 ? dh * grad_mag(d, phi, i, j, k, h) : 0.0;
          }
          if (delta[v] > 0.0) ++band_n;
          raw_vel[v] = energy_from(sc.dcompliance[v], rho[v], traj_params.penalty,
                                   traj_params.youngs_modulus);
        }

    // ★ LAMBDA UNDER THE SAME MEASURE. PR 322 used the mean energy over a flat
    // two-voxel band. Now that the descent is weighted by `delta`, the multiplier
    // that makes the flow volume-neutral to first order is the DELTA-WEIGHTED
    // mean — the unique lambda for which ∫ (e - lambda) * DH * |grad phi| = 0,
    // which is exactly the statement that dJ + lambda*dVol has no volume
    // component. The residual it leaves is what the offset bisection removes at
    // the top of the next iteration, so the two pieces still do not fight.
    double wsum = 0.0, w = 0.0;
    for (std::size_t v = 0; v < n; ++v) {
      wsum += raw_vel[v] * delta[v];
      w += delta[v];
    }
    double lambda = w > 0.0 ? wsum / w : 0.0;

    // ── THE PERIMETER PENALTY (see mean_curvature above) ────────────────────
    //
    // ell = perimeter * lambda * h makes the coefficient DIMENSIONLESS and ties
    // it to the energy scale the flow is already working in, so it needs no
    // retuning per part or per rung. Zero by default.
    //
    // ★ ORDER MATTERS AND IT IS NOT THE OBVIOUS ONE. lambda is the multiplier
    // that makes the flow volume-neutral: the unique value for which
    // integral (v - lambda) * DH * |grad phi| vanishes. Subtracting the
    // curvature AFTER fixing lambda leaves a residual -ell * integral kappa*delta,
    // which is not zero for a general surface — the penalty would then fight the
    // volume constraint and the offset bisection would spend every iteration
    // undoing it. So ell is sized from the ENERGY-ONLY lambda (breaking the
    // circularity), the curvature is folded into the driving field, and lambda
    // is RECOMPUTED on the combined field before it is applied.
    double kappa_rms = 0.0;
    if (a.perimeter > 0.0) {
      const double ell = a.perimeter * lambda * h;
      double k2 = 0.0;
      std::size_t kn = 0;
      for (int k = 0; k < d.nz; ++k)
        for (int j = 0; j < d.ny; ++j)
          for (int i = 0; i < d.nx; ++i) {
            const std::size_t v = d.at(i, j, k);
            if (delta[v] <= 0.0) continue;
            const double kap = mean_curvature(d, phi, i, j, k, h);
            raw_vel[v] -= ell * kap;
            k2 += kap * kap;
            ++kn;
          }
      kappa_rms = kn ? std::sqrt(k2 / static_cast<double>(kn)) : 0.0;
      double wsum2 = 0.0;
      for (std::size_t v = 0; v < n; ++v) wsum2 += raw_vel[v] * delta[v];
      lambda = w > 0.0 ? wsum2 / w : 0.0;
    }

    for (std::size_t v = 0; v < n; ++v)
      raw_vel[v] = (raw_vel[v] - lambda) * delta[v];

    // ── (d) + (4) THE VELOCITY EXTENSION ────────────────────────────────────
    int hilb_it = 0;
    double hilb_rel = 0.0;
    const double t_h0 = now_s();
    if (a.alpha_coeff > 0.0) {
      // ★ DIFFERENCE 4. A velocity that is zero off the interface — which is what
      // difference 1 just made it — cannot advect a level set on its own: the
      // Godunov step would only move the band and would leave phi's far field
      // frozen. The Hilbertian solve is what puts it back, and it is not a blur:
      // it is the Riesz map of the shape derivative in the inner product their
      // regularity requires, so the descent direction stays a descent direction.
      hilb_it = hilbertian_extend(d, pinned, raw_vel, vel, a.alpha_coeff * h, h,
                                  a.hilb_rtol, a.hilb_max_it, &hilb_rel);
    } else {
      // PR 322's separable [1 2 1]/4 passes, kept reachable as a control.
      vel = raw_vel;
      smooth_field(d, vel, a.smooth);
    }
    total_hilb_wall += now_s() - t_h0;
    // The flow must not spend itself pushing a wall it cannot move. The pinned
    // set is already zero out of the solve; this is the Empty / FrozenVoid half.
    for (std::size_t v = 0; v < n; ++v)
      if (grid.tags[v] == VoxelTag::Empty || eff[v] != MaskValue::Active) vel[v] = 0.0;

    double vmax = 0.0;
    for (std::size_t v = 0; v < n; ++v) vmax = std::max(vmax, std::fabs(vel[v]));

    // ── (e) + (3) ADVECTION: SIX HAMILTON-JACOBI STEPS, NOT ONE ─────────────
    //
    // ★ DIFFERENCE 3. Theirs advects max_steps = floor(order*min(el_size)/5) = 6
    // times per optimiser iteration on ONE velocity field, with
    // dt = gamma * h / max|v| and gamma = 0.1. The velocity is held fixed across
    // the sub-steps (it is a function of the state solve, which is not repeated);
    // the GODUNOV GRADIENT is re-evaluated at the new phi on every one, which is
    // what makes six small steps a better-resolved motion than one large one
    // rather than merely a longer one.
    double dt = 0.0;
    int hj_done = 0;
    if (vmax > 0.0 && a.hj_steps > 0) {
      // gamma_now, not a.gamma: the oscillation damper below may have pulled it
      // in on a previous iteration, exactly as theirs does.
      dt = gamma_now * h / vmax;
      std::vector<double> next(n), rk1(n), rk2(n);
      // L(phi) = -v * |grad phi|, with the gradient scheme the arm selected.
      auto apply_L = [&](const std::vector<double>& src, std::vector<double>& dst) {
        for (int k = 0; k < d.nz; ++k)
          for (int j = 0; j < d.ny; ++j)
            for (int i = 0; i < d.nx; ++i) {
              const std::size_t v = d.at(i, j, k);
              const double vv = vel[v];
              if (vv == 0.0) { dst[v] = 0.0; continue; }
              dst[v] = -vv * (a.weno ? weno_grad(d, src, i, j, k, vv, h)
                                     : godunov_grad(d, src, i, j, k, vv, h));
            }
      };
      for (int step = 0; step < a.hj_steps; ++step) {
        if (a.rk3) {
          // ── TVD-RK3 (Shu & Osher). Three L evaluations per step; forward
          // Euler would discard WENO5's spatial order, so the two go together.
          apply_L(phi, next);
          for (std::size_t v = 0; v < n; ++v) rk1[v] = phi[v] + dt * next[v];
          apply_L(rk1, next);
          for (std::size_t v = 0; v < n; ++v)
            rk2[v] = 0.75 * phi[v] + 0.25 * (rk1[v] + dt * next[v]);
          apply_L(rk2, next);
          for (std::size_t v = 0; v < n; ++v)
            next[v] = phi[v] / 3.0 + 2.0 / 3.0 * (rk2[v] + dt * next[v]);
        } else {
          apply_L(phi, next);
          for (std::size_t v = 0; v < n; ++v) next[v] = phi[v] + dt * next[v];
        }
        phi.swap(next);
        ++hj_done;
        // ── REINITIALISE BETWEEN SUB-STEPS ──────────────────────────────────
        // With 24 sub-steps the interface travels ~2.4 voxels on ONE velocity
        // field, and |grad phi| drifts the whole way; correcting once at the end
        // means the last sub-steps advected a field that was no longer a
        // distance function, and the Godunov gradient they used was wrong by
        // that much. This keeps it near 1 throughout. Costs one sweep per
        // sub-step — pure grid work, no FEA.
        if (a.reinit_substeps && step + 1 < a.hj_steps)
          reinitialise(d, phi, h, a.sweeps, a.russo_smereka);
      }
    }

    // ── (f) reinitialisation ────────────────────────────────────────────────
    ReinitResidual rresid;
    if (a.reinit_every > 0 && it % a.reinit_every == 0) {
      reinitialise(d, phi, h, a.sweeps, a.russo_smereka);
      // Their reinitialisation-by-PDE runs to tol = 1/(5 order^2)/min(el_size) =
      // 0.00645 on his grid. Ours is a direct Eikonal sweep with no time step, so
      // that tolerance has nothing to apply to — this is the PROPERTY both are
      // after, measured, so the two schemes can be compared on the thing that
      // matters instead of on a parameter only one of them has.
      rresid = reinit_residual(d, phi, h, eta);
      last_rresid = rresid;
    }

    const double it_wall = now_s() - t_it0;
    done_iters = it;

    csv << it << ',' << sc.compliance << ',' << occ_vol << ',' << printed << ','
        << (printed / part_solid) << ',' << offset << ',' << dt << ',' << vmax << ','
        << lambda << ',' << sc.cg.iterations << ',' << (sc.cg.converged ? 1 : 0)
        << ',' << (sc.cg.used_multigrid ? 1 : 0) << ',' << sc.t_solve_ms << ','
        << sc.t_sensitivity_ms << ',' << band_n << ',' << hilb_it << ','
        << hilb_rel << ',' << rresid.rms << ',' << rresid.max << ',' << hj_done
        << ',' << gamma_now << ',' << kappa_rms << ',' << it_wall << '\n';
    csv.flush();

    std::printf("it %3d  c = %.10g  vf = %.6f (occ %.1f)  offset %+.4f mm  "
                "|v|max %.3g  band %zu  hilb %d (%.1e)  |grad|-1 %.2e  cg %d%s  "
                "%.2f s\n",
                it, sc.compliance, printed / part_solid, occ_vol, offset, vmax,
                band_n, hilb_it, hilb_rel, rresid.rms, sc.cg.iterations,
                sc.cg.used_multigrid ? " MG" : "", it_wall);
    std::fflush(stdout);

    // ── THE ROUGHNESS CURVE'S RAW MATERIAL ──────────────────────────────────
    //
    // The task wants midpoint fraction and cut roughness every 10 iterations, and
    // the ONLY instrument allowed to produce either is
    // `external_field_surface_probe` (R2). So this writes the occupancy in that
    // probe's own input convention and the curve is measured by INVOKING it on
    // the snapshots afterwards. Nothing about a roughness number is computed
    // here.
    if (a.snapshot_every > 0 && (it % a.snapshot_every == 0 || it == 1)) {
      char stem[512];
      std::snprintf(stem, sizeof stem, "%s/snap/it%04d", a.out.c_str(), it);
      std::ofstream f(std::string(stem) + ".f64", std::ios::binary);
      if (f) {
        f.write(reinterpret_cast<const char*>(occ.data()),
                static_cast<std::streamsize>(occ.size() * sizeof(double)));
        std::ofstream m(std::string(stem) + ".meta");
        m.precision(17);
        char rung_label[32];
        std::snprintf(rung_label, sizeof rung_label, "%.2f", a.rung);
        m << "rung " << rung_label << "\nrequested_vf " << a.rung << "\n";
        m << "nx " << d.nx << "\nny " << d.ny << "\nnz " << d.nz << "\n";
        m << "spacing " << h << "\n";
        m << "ox " << grid.origin.x << "\noy " << grid.origin.y << "\noz "
          << grid.origin.z << "\n";
        m << "iso 0.5\nfactor 2\ninterp tricubic\n";
        m << "achieved_vf " << (printed / part_solid) << "\n";
        m << "iterations " << it << "\n";
        m << "compliance " << sc.compliance << "\n";
      }
    }

    // ── convergence: the compliance plateau, on the same window/tolerance the
    // shipped MMA termination uses (handoff: window 10, tol 1e-3).
    history.push_back(sc.compliance);

    // ── THE OSCILLATION DAMPER (their §4.1.8) ───────────────────────────────
    // Fires AFTER this iteration's advection, so it governs the NEXT one —
    // the same place in the cycle theirs sits. The cooldown is ours: their
    // check runs on a Lagrangian that moves once per multiplier update, while
    // ours reads the objective every iteration, and without it a single ringing
    // stretch would collapse gamma geometrically over consecutive iterations.
    if (a.damp && it - last_damp >= a.damp_window &&
        has_oscillations(history, a.damp_window)) {
      const double was = gamma_now;
      gamma_now *= a.damp_factor;
      last_damp = it;
      ++damp_events;
      std::printf("   ↳ oscillation detected: gamma %.5g -> %.5g\n", was,
                  gamma_now);
      std::fflush(stdout);
    }

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
    fea_set_matfree_threads(prev_threads);
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
  fea_set_matfree_threads(prev_threads);

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
      "THREADS              %d\n"
      "iterations run       %d%s\n"
      "WALL PER ITERATION   %.3f s   (total %.1f s over %d iterations)\n"
      "  of which solve     %.3f s/iteration (%.1f s total)\n"
      "  of which extension %.3f s/iteration (%.1f s total)\n"
      "certification wall   %.1f s\n"
      "state solves         %lld, of which the V-cycle engaged on %lld\n"
      "trajectory posture   %s\n"
      "mixed precision      %s\n"
      "-- the five differences, as they ran --\n"
      "(1) surface delta    DH_eta(phi)*|grad phi| on the compliance AND volume "
      "terms\n"
      "(2) trajectory law   penalty %.4g%s;  CERTIFICATION penalty %.4g "
      "(production, unchanged)\n"
      "(3) HJ steps         %d per state solve at gamma %.4g -> %.5g "
      "(damper %s, fired %d)\n"
      "(4) extension        %s\n"
      "(5) band eta         %.4g voxels = %.6f mm\n"
      "reinit |grad phi|-1  rms %.6g in band at the last reinitialisation\n"
      "                     (their reinit-by-PDE tolerance is 0.00645; the MAX is\n"
      "                     %.6g and is pinned at 1 by medial-axis kinks, which\n"
      "                     the exact distance function has too)\n"
      "compliance (best)    %.12g   ★ ON THE TRAJECTORY LAW — not comparable to\n"
      "                     SIMP's or to PR 322's, which are penalty 3\n"
      "compliance (cert)    %.12g\n"
      "achieved vf          %.6f  (target %.4g, printed %zu of %.0f part voxels)\n"
      "load path connected  %s\n",
      a.seed.c_str(), a.rung, threads_now, done_iters,
      converged_early ? " (converged)" : "", per_iter, run_wall, done_iters,
      done_iters ? total_solve_wall / done_iters : 0.0, total_solve_wall,
      done_iters ? total_hilb_wall / done_iters : 0.0, total_hilb_wall, cert_wall,
      solves_total, solves_multigrid,
      a.isolate ? "ISOLATED (recycling/geneo OFF) — a control"
                : "PRODUCTION (recycling/geneo as configure_production_options "
                  "armed them)",
      a.fp32 ? "ARMED (FP32 V-cycle) on the trajectory; the certificate is FP64"
             : "off (FP64)",
      a.traj_penalty,
      a.traj_penalty == 1.0 ? " = their LINEAR I(phi)" : " (NOT theirs)",
      params.penalty, a.hj_steps, a.gamma, gamma_now,
      a.damp ? "ARMED" : "off", damp_events,
      a.alpha_coeff > 0.0 ? "HILBERTIAN screened-Poisson, Dirichlet on the "
                            "load/anchor/protection set"
                          : "[1 2 1] passes (PR 322's, a control)",
      a.eta_voxels, eta, last_rresid.rms, last_rresid.max, best_compliance,
      compliance_final,
      achieved_vf, a.rung, printed, part_solid, load_path_ok ? "yes" : "NO");
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
