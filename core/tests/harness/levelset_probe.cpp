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
// ★ AT FILE SCOPE, DELIBERATELY. `plsm_basis.hpp` below is a SHIM over this
// header and is included from inside an anonymous namespace; core's basis must
// keep EXTERNAL linkage so this probe and the production optimiser share one
// definition of the function they fit.
#include "topopt/plsm_basis.hpp"
#include "topopt/plsm_kernel.hpp"
#include "topopt/plsm_mma.hpp"
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
#include <memory>
#include <string>
#include <thread>
#include <vector>

using namespace topopt;

namespace {
// ── THE FIELD KERNEL ────────────────────────────────────────────────────────
// Dims, heaviside, dheaviside, grad_mag, eikonal_update, fast_sweep and
// reinitialise used to be written out here. They were MOVED VERBATIM to
// `levelset_kernel.hpp` when `plsm_probe` needed the same seed path — it turns a
// density into a signed distance exactly as this file's `--simp` seed does, and
// two copies of a reinitialisation is how the two stop agreeing. Included from
// INSIDE this anonymous namespace, so nothing about linkage changes.
//
// ★ The move is verified, not asserted: `evidence/2026-08-10-parametric-level-set/
// s0_kernel_move/` holds a 3-iteration trajectory from before it and one from
// after, and they are byte-identical.
#include "levelset_kernel.hpp"

// ── ARM 2 (task 2026-08-10-parametric-level-set): THE PARAMETRIC LEVEL SET.
// phi stops being a per-voxel array and becomes phi(x) = sum_i alpha_i psi_i(x).
// The basis is the SAME header `plsm_probe` fits with, so the function ARM 2
// optimises over and the function ARM 1 measured are the same function.
// `--plsm` arms it; without the flag not one line of it executes and every
// earlier arm reproduces byte for byte.
#include "plsm_basis.hpp"
#include "plsm_mma.hpp"

// ── ★ TASK 2026-08-12: THE ERSATZ DENSITY AS THE EXACT VOLUME FRACTION.
// `rho_e = H_eta(-phi(x_centre))` becomes `rho_e = |{phi<0} cap cell| / |cell|`,
// computed by sub-cell sampling of the SAME analytic phi, with the SAME
// sub-cell lattice `plsm_evaluate` and `marching_cubes_resampled` use. The
// sensitivity moves with it — a mismatched gradient here looks like slow
// convergence and is believed. `--frac` arms it; without the flag not one line
// of it executes and PR 326's arms reproduce bit for bit (`--frac 0` is the
// control that proves it).
#include "frac_ersatz.hpp"


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
  // --seed-period P   the hole array's period in VOXELS. 8 is PR 324's ARM 2
  //                   and is the default, so every earlier run reproduces.
  double seed_period = 8.0;
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
  bool respect_frozen = false;
  std::string dump_masked;
  std::string dump_mask;
  // ── ARM 2: the parametric level set ───────────────────────────────────────
  bool plsm = false;               // phi = sum alpha_i psi_i, alpha is the design
  bool plsm_mma = false;           // drive alpha with MMA rather than descent
  bool plsm_hilb = false;          // keep the Hilbertian extension (an ablation)
  std::string plsm_basis = "wendland";
  double plsm_dx = 2.0, plsm_dy = 2.0, plsm_dz = 2.0;   // knots, VOXELS, PER AXIS
  double plsm_support = 2.0;       // support radius = support * spacing, per axis
  double plsm_ridge = 1e-6;
  double plsm_band_weight = 1.0;
  double plsm_clamp = 6.0;
  double plsm_move = 0.05;         // MMA move limit, fraction of the alpha range
  double plsm_bound = 4.0;         // alpha box = +- bound * max|alpha_seed|
  int plsm_refit_every = 0;        // approximate re-initialisation, 0 = never
  std::vector<int> plsm_export;    // export the ANALYTIC surface at these factors
  int plsm_cg_iters = 2000;
  // ★ THE STATE SOLVE'S INITIAL GUESS. `simp_compliance` has taken one since it
  // was written — `const FeaSolution* initial_guess` — and every level-set arm
  // in PR 322/323/324/325 and in ARM 2 above passes nullptr, so every solve
  // starts from zero. Measured on A1: 2817 CG iterations per solve, FLAT across
  // all 40 iterations, and 99.5% of the wall clock. A design that moves by a
  // bounded 2.4 voxels of interface per iteration has a displacement field that
  // barely moves with it, so the previous one should be a very good guess.
  bool warm_start = false;
  // ── THE THREE SPEED PROBES (task 2026-08-10-parametric-level-set, S17) ─────
  //
  // ★ 99.5% OF AN ITERATION IS THE STATE SOLVE. Measured on A1: 25.412 s of
  // 25.526, with the whole parametric machinery — basis evaluation, two sparse
  // applies, MMA over 85,680 variables, the volume bisection — costing 0.114 s.
  // So there is nothing to win in the representation, and every speed idea has
  // to attack the solve or the NUMBER of solves. These three do, and none of
  // them touches a line of production code.
  int solver_kind = -1;         // -1 = whatever build_production_loadcase armed
  bool penalized_solver = false;  // core's cached solver, which warm-starts itself
  double cg_tol_early = 0.0;    // inexact early solves; 0 = off
  int cg_tol_until = 0;         // ... for this many iterations
  int plsm_lbfgs = 0;           // L-BFGS memory on the coefficients; 0 = MMA
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

  // ── S1 (task 2026-08-11-plsm-minimise-extra-surface): THE HONEST VOLUME
  // CONSTRAINT. ★ PR 324 §6 found the defect and did not fix it, on the grounds
  // that fixing it would make ARM 2 incomparable to everything it was measured
  // against. This task re-baselines ARM 2, so it is fixed here.
  //
  // The constraint measures `∫ H_eta(-phi)` — a SMOOTHED volume. The part that
  // gets printed, that `analyze_fixed_design` certifies and that the mass is
  // computed from, is `#{rho > 0.5}` = `#{phi + c < 0}`. Those two agree only
  // when the band is symmetric about the interface; as INTERFACE AREA grows they
  // diverge, because a band cell contributes its H value to one and a hard 0/1
  // to the other. Measured in PR 324: one arm held `occupancy_volume` pinned at
  // 75,414.7 for 30 consecutive iterations — the bisection doing its job to the
  // digit — while `achieved_vf` slid 0.6839 -> 0.6634, giving up 3.0% of the
  // printed material and 12.3 g without ever violating its own constraint.
  //
  // ★ AND THE DRIFT IS IN THE DIRECTION THAT MATTERS FOR THIS TASK: it is
  // proportional to interface area, so left in it silently REWARDS the very
  // thing S3 is trying to suppress. Every measurement downstream of here is
  // about interface area. That is why it is fixed first.
  //
  // `--volume-count` makes the constrained quantity the hard count. It is one
  // line in `volume_at` (below); everything else — the bisection, MMA's g0, the
  // reported `occupancy_volume` — reads that one function and follows.
  bool volume_count = false;

  // ── S3: PERIMETER CONTINUATION ────────────────────────────────────────────
  //
  // ★ THE LITERATURE IS CONSISTENT THAT AN AREA TERM MUST BE RELAXED EARLY.
  // A perimeter penalty inhibits topological change — it is a cost on creating
  // interface, and nucleating a hole creates interface before it creates any
  // compliance benefit. Allaire, Jouve & Toader (2004) §5 note the perimeter
  // term "penalizes" topology changes and use small or vanishing weights;
  // Osher & Santosa (2001), who introduced it, ramp it. ★ AND FOR THIS ARM IT
  // MATTERS MORE THAN USUAL: hole nucleation from a plain array is exactly what
  // makes the parametric form able to replace SIMP with no seed (PR 324 §6). A
  // full-strength penalty from iteration 1 would buy smoothness by taking away
  // the property the method was adopted for.
  //
  // `--perimeter-ramp START,LEN`: the weight is 0 for it < START, ramps
  // linearly to the full `--perimeter` value at it = START+LEN, and holds. The
  // default 0,0 is a step at iteration 1 — i.e. exactly the fixed weight, so
  // the flag defaulted off changes nothing.
  int perimeter_ramp_start = 0;
  int perimeter_ramp_len = 0;

  // ── ARM 2 MECHANISM — LOCAL PERIMETER / CURVATURE CONCENTRATION ───────────
  //
  // ★ THE PROBLEM THIS EXISTS FOR, NAMED FIRST. PR 325 measured what a global
  // perimeter penalty costs: at C=2 it took interface area down 22% and the
  // certified margin down 6.4%; at C=8, area −30% and margin −66%. It taxes
  // EVERY square millimetre of interface at the same rate, including the large,
  // smooth, load-bearing outer shell, which is exactly the surface we want to
  // keep. The structure it removes is load-bearing — PR 325 checked, and its own
  // prediction that margin had saturated was refuted by the certificate.
  //
  // ★ THE LITERATURE'S ANSWER IS TO PRICE CURVATURE, NOT AREA. The Willmore
  // energy W = ∫_Γ kappa^2 ds is the standard curvature-concentration
  // functional; the survey framing is that it "controls curvature concentration
  // and promotes smoothness WITHOUT inducing shrinkage, in contrast to area
  // minimisation which risks topological collapse". A smooth shell of large
  // radius costs almost nothing under W and its full area under Per.
  //
  // For a functional ∫_Γ f ds with f a field defined on the whole level-set
  // family, the shape derivative is ∫_Γ (∂f/∂n + f*kappa) v_n ds. With f =
  // kappa^2 that is ∫ (2*kappa*∂_n kappa + kappa^3) v_n ds. So
  //
  //     ell * kappa * (1 + beta * (kappa/kappa_rms)^2)          [--perimeter-local]
  //
  // is the gradient of  Per + (beta/kappa_rms^2) * W  WITH THE ∂_n kappa TERM
  // DROPPED — and that dropped term is the expensive, noisy one on a 128^3 grid,
  // because it differentiates a quantity that is already two differences deep.
  // ★ THE OMISSION IS MEASURED RATHER THAN ASSUMED: `--willmore-full` puts
  // 2*kappa*(grad kappa . n) back, by central differences on the curvature field
  // this loop already builds, so the two can be run against each other.
  //
  // kappa is normalised by the band's own rms curvature (the `kappa_rms` the CSV
  // has always carried), so beta is dimensionless and needs no retuning per part
  // — the same discipline `--perimeter`'s ell = C*lambda*h follows.
  double perimeter_local = 0.0;
  bool willmore_full = false;

  // ── ARM 2 MECHANISM — THE ROBUST FORMULATION (Sigmund 2009) ───────────────
  //
  // ★ THE PROBLEM: fine branching pays. A thin member contributes stiffness in
  // proportion to its area and surface in proportion to its perimeter, and
  // nothing in the formulation notices that it is thin. A perimeter penalty
  // prices its SURFACE; this prices its FRAGILITY instead.
  //
  // Sigmund (2009) "Manufacturing tolerant topology optimization" and Wang,
  // Lazarov & Sigmund (2011) optimise the WORST of three designs — eroded,
  // intermediate and dilated — so a member that disappears under erosion buys
  // nothing at all. In a density method that needs three projections of a
  // filtered field; ★ ON A LEVEL SET IT IS FREE OF MACHINERY, because eroding by
  // delta is just {phi < -delta}: one constant, the same phi, no filter and no
  // projection. That is the reason to try it here rather than there.
  //
  // ★ AND IT IS NOT A MINIMUM-FEATURE CONSTRAINT, which this task's brief rules
  // out on the evidence that the measured problem is AREA and that min-feature
  // violations already IMPROVE in the level-set arms (4,717 against SIMP's
  // 5,464). A thickness rule FORBIDS thin members. This one lets the optimiser
  // build them and declines to pay for them, so it acts on the branching rate
  // rather than on a width.
  //
  // ★ WHAT IT COSTS: three state solves per iteration instead of one, so ~3x the
  // wall clock. Speed is out of scope for this task and this is said plainly
  // rather than hidden.
  //
  // ★ ONE DEVIATION FROM THE PAPER, DECLARED. The robust formulation normally
  // puts the volume constraint on the DILATED design and rescales so the
  // intermediate lands on target. Here the constraint stays on the INTERMEDIATE,
  // because the intermediate is the part that gets printed, certified and
  // weighed, and every other row in this task's tables holds that same volume.
  // Moving the constraint would make the mass column incomparable, which is the
  // one thing the brief's bar is written against.
  double robust = 0.0;   // erosion/dilation depth in VOXELS; 0 = off

  // ── ARM 2 MECHANISM — THE NUCLEATION BAND (`--nucleation-band W`) ─────────
  //
  // ★ THIS TASK'S OWN §4 FOUND THE CAUSE: the surface is NUCLEATED, not seeded.
  // Eight times fewer seed holes removed only 8.9% of it, so the fine structure
  // is created during the run. The mechanism is the one PR 324 celebrated as the
  // reason this method needs no SIMP seed — a coefficient away from the
  // interface can be driven negative on its own and open a hole. ★THE CAPABILITY
  // AND THE DEFECT ARE THE SAME MECHANISM. This is the knob that separates them.
  //
  // Luo & Tong (2008, IJNME 76(6):862-892) is the reference point, via Dunning &
  // Kim (IJNME 93(1):118-134): holes "can also emerge NEAR THE BOUNDARY in an RBF
  // type approach if a VOLUME INTEGRAL METHOD is used to compute shape
  // sensitivities WITHIN A NARROW BAND around the boundary." Everywhere against
  // band is the distinction, and it is a statement about WHICH COEFFICIENTS MOVE.
  //
  // ★★ AND IT HAS TO BE APPLIED IN COEFFICIENT SPACE, NOT TO THE INTEGRAND —
  // WHICH IS AN OVERRIDE OF THE RECOMMENDATION AS IT WAS GIVEN TO ME, AND THE
  // REASON IS ONE LINE OF `levelset_kernel.hpp`:
  //
  //     double dheaviside(double t, double eta) {
  //       if (t <= -eta || t >= eta) return 0.0;   // <- compact support
  //
  // The shape-derivative integrand here is ALREADY exactly zero outside
  // |phi| < eta = 2 voxels. Masking it to a tube |phi| < omega with the
  // recommended omega >= 2*eta = 4 voxels is a SUPERSET of where it is already
  // non-zero: it would change nothing, on any arm, at any weight.
  //
  // ★ THE LEAK IS THE SUPPORT RADIUS, NOT THE BAND. The gradient MMA consumes is
  // g = Psi^T v. A knot contributes iff its SUPPORT overlaps the band, and the
  // support radius here is 2 x spacing = 4 voxels. So every knot whose CENTRE is
  // up to 4 voxels inside solid receives a gradient and can be driven negative —
  // and once it opens a hole, the knots 4 voxels beyond THAT become live, so
  // nucleation marches inward. Masking by knot-to-interface distance is what
  // closes it, and to bite at all W must be BELOW the support radius of 4.
  //
  // ★ IT IS A RESTRICTION, NOT A FALSIFIED GRADIENT. Zeroing components of g
  // makes each iteration a search over the SUBSPACE of near-interface
  // coefficients — a restricted problem, which is exactly what a band method is.
  // The masked coefficients are held EXACTLY (the MMA result is overwritten with
  // their current value) rather than left to drift on the regulariser alone.
  // The volume offset is still added to every coefficient, because that is a
  // rigid move of the surface and not a design change.
  double nucleation_band = 0.0;   // VOXELS from the interface; 0 = off

  // ── ★ A MARGIN-AWARE STOPPING RULE, AND A WALL-CLOCK CAP ──────────────────
  //
  // ★ THIS EXISTS BECAUSE THIS TASK MEASURED THAT THE STOPPING RULE WE HAVE IS
  // WATCHING THE WRONG THING. Every arm here stops on a compliance plateau
  // (window 10, tol 1e-3, the shipped MMA termination). But the certified
  // MARGIN settles far later than the compliance does: the re-baseline moved
  // 27% in margin between iterations 40 and 60 while its compliance moved
  // 0.05%, and C=8 DOUBLED its margin over the same span. So a compliance
  // plateau is not evidence that the design is finished, and every arm in §3
  // stopped while its margin was still climbing.
  //
  //   --certify-every N   certify the CURRENT design every N iterations, with
  //                       the posture disarmed exactly as a re-certification
  //                       disarms it, and RE-ARMED afterwards so the trajectory
  //                       is not altered by having been measured.
  //   --margin-stop M     stop as soon as that certified margin reaches M.
  //   --wall-cap S        stop when the run has used S seconds. Checked after
  //                       an iteration completes, so the cap is a floor on the
  //                       wall clock, not a guillotine mid-solve.
  //
  // ★ THE CERTIFICATION IS NOT FREE AND ITS COST IS REPORTED SEPARATELY, so a
  // timing produced with this on is not silently inflated.
  int certify_every = 0;
  // ★ AND A FLOOR ON WHEN TO START. Certifying an unconverged design costs 26x
  // what certifying a converged one costs (20.9 s at iteration 5 against
  // 537.9 s at iteration 10, measured), and an early certificate cannot pass
  // the target anyway. Starting the cadence late is what makes a margin-aware
  // stopping rule affordable at all.
  int certify_from = 0;
  double margin_stop = 0.0;
  double wall_cap = 0.0;
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

  // ══ TASK 2026-08-12 — THE EXACT VOLUME FRACTION ERSATZ ═══════════════════
  //
  // ★ THE ONE CHANGE. `rho_e = H_eta(-phi(x_centre))` becomes the exact fraction
  // of the cell inside {phi < 0}, by k x k x k sub-cell sampling of the SAME
  // analytic phi. Everything about the solver is untouched: the cell stiffness
  // is still rho_e * K0, so the 24x24 reference block, the matrix-free stencil,
  // the multigrid, GenEO, the recycler and the Galerkin block cache never learn
  // that anything changed. What changes is that rho_e now varies CONTINUOUSLY as
  // the interface moves inside a cell instead of stepping when it crosses the
  // centre. `frac_ersatz.hpp` holds the sampling, the band and the projection.
  //
  //   --frac K            arm it, with K sub-samples per axis (K=0 is OFF and is
  //                       the control: every PR 326 arm reproduces bit for bit)
  //   --frac-eps M        the QUADRATURE bandwidth multiplier. eps_q =
  //                       M * |grad phi| * h/K — tied to the SAMPLE SPACING, so
  //                       it shrinks like 1/K. It is not eta wearing a hat and
  //                       `frac_ersatz.hpp` says why at length.
  //   --frac-sens MODE    `exact` (default) evaluates psi_i AT THE SAMPLES and
  //                       scatters; `centre` factors psi_i out at the cell
  //                       centre and reuses Psi^T. The second is the ablation
  //                       that prices the sub-cell psi.
  //   --frac-soft         the CONSISTENTLY MOLLIFIED variant: the hard sample
  //                       indicator becomes the exact antiderivative of the
  //                       quadrature mollifier, so the value and the gradient
  //                       are two facts about ONE function. It removes the
  //                       piecewise-constant wart; see frac_ersatz.hpp.
  //   --frac-export       ALSO write the emitted occupancy as the volume
  //                       fraction, beside the H_eta one. R5 keeps the H_eta
  //                       export as the row of record; this is the named
  //                       control for what the EXPORT convention is worth.
  //   --frac-kreport      k = 2/4/8 on THIS design, then exit. S1(a).
  //   --frac-fd N         ★ R4. Finite-difference the volume and the compliance
  //                       sensitivities against the analytic ones on N
  //                       coefficients and on random directions, then exit.
  int frac = 0;
  double frac_eps = 1.0;
  std::string frac_sens = "exact";
  bool frac_soft = false;
  bool frac_export = false;
  bool frac_kreport = false;
  int frac_fd = 0;
  // --frac-aniso   ARM 2: price the cut cell's ANISOTROPY against the scalar
  //                volume fraction, by the rank-one laminate. A 3x3 solve per
  //                cut cell; no element matrix anywhere.
  bool frac_aniso = false;
  // --alpha PREFIX   read `<PREFIX>.f64` as this basis's coefficients, in place
  //                  of the seed fit. `plsm_probe` has had this since PR 326 and
  //                  this file has not, so every question about a FINISHED
  //                  design needed the run that produced it re-run.
  std::string alpha_in;
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
        "  ARM 2 — THE PARAMETRIC LEVEL SET (phi = sum alpha_i psi_i):\n"
        "       [--plsm] [--plsm-mma] [--plsm-hilb]\n"
        "       [--plsm-basis wendland|gaussian] [--plsm-knots dx,dy,dz]\n"
        "       [--plsm-support S] [--plsm-ridge L] [--plsm-band-weight W]\n"
        "       [--plsm-move M] [--plsm-bound B] [--plsm-refit-every N]\n"
        "  ★ THE EXACT VOLUME FRACTION ERSATZ (task 2026-08-12):\n"
        "       [--frac K]           rho_e = |{phi<0} cap cell| / |cell| by KxKxK\n"
        "                            sub-cell sampling, instead of H_eta at the\n"
        "                            cell CENTRE. 0 = off (the control).\n"
        "       [--frac-eps M]       quadrature bandwidth eps_q = M*|grad phi|*h/K\n"
        "       [--frac-sens exact|centre]   psi_i at the SAMPLES (default) or\n"
        "                            factored out at the cell centre (ablation)\n"
        "       [--frac-soft]        consistently mollified: the value is the\n"
        "                            antiderivative of the gradient's mollifier\n"
        "       [--frac-export]      also emit the fraction field beside H_eta's\n"
        "       [--frac-kreport]     K = 2/4/8 on this design, then exit\n"
        "       [--frac-fd N]        finite-difference the sensitivity, then exit\n"
        "  SMOOTHNESS (task 2026-08-11-plsm-minimise-extra-surface):\n"
        "       [--volume-count]     constrain #{phi + c < 0} — the PRINTED\n"
        "                            count — instead of the smoothed integral\n"
        "                            int H_eta(-phi). Closes PR 324 §6's silent\n"
        "                            drift, which grows with INTERFACE AREA.\n"
        "       [--perimeter C]      the perimeter penalty, ell = C*lambda*h\n"
        "       [--perimeter-ramp START,LEN]  ramp C on from 0: zero until\n"
        "                            START, linear to full over LEN. An area\n"
        "                            term inhibits hole nucleation, which is the\n"
        "                            property that lets this arm replace SIMP.\n"
        "       [--perimeter-local B] price CURVATURE, not area: the Willmore\n"
        "                            gradient with the d_n(kappa) term dropped\n"
        "       [--willmore-full]     put that dropped term back, so the\n"
        "                            omission is measured rather than assumed\n"
        "       [--robust DELTA]      Sigmund 2009: optimise the WORST of the\n"
        "                            eroded/intermediate/dilated designs. DELTA\n"
        "                            in voxels. THREE state solves per iteration.\n"
        "       [--nucleation-band W] only coefficients within W voxels of the\n"
        "                            interface may move. Closes interior hole\n"
        "                            nucleation, which is what generates the\n"
        "                            surface. Must be < the RBF support radius.\n"
        "       [--seed-period P]     the hole array's period in voxels (8 =\n"
        "                            PR 324's ARM 2). The seed's topology scale.\n"
        "  SPEED PROBES (S17) — none of them touches production:\n"
        "       [--warm-start]       seed each state solve with the PREVIOUS\n"
        "                            iteration's displacement field\n"
        "       [--solver-kind N]    0 JacobiCG / 1 MultigridCG / 2 matrix-free\n"
        "       [--penalized-solver] core's cached PenalizedSolver, which warm\n"
        "                            starts itself\n"
        "       [--cg-tol-early T --cg-tol-until N]   INEXACT early solves\n"
        "       [--plsm-lbfgs M]     L-BFGS on the coefficients instead of MMA\n"
        "       [--plsm-export F]    write the ANALYTIC surface on the F-refined\n"
        "                            lattice, not a resample of the voxel field\n"
        "       [--certify-field <prefix> [--binarize] [--respect-frozen]]\n"
        "                            a re-cert control; --respect-frozen restores\n"
        "                            the FrozenSolid/FrozenVoid mask first\n");
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
    else if (s == "--perimeter-ramp" && i + 1 < argc) {
      if (std::sscanf(argv[++i], "%d,%d", &a.perimeter_ramp_start,
                      &a.perimeter_ramp_len) != 2) {
        std::printf("FATAL: --perimeter-ramp wants START,LEN (iterations)\n");
        std::exit(1);
      }
      if (a.perimeter_ramp_start < 0 || a.perimeter_ramp_len < 0) {
        std::printf("FATAL: --perimeter-ramp START and LEN must be >= 0\n");
        std::exit(1);
      }
    }
    else if (s == "--volume-count") a.volume_count = true;
    // ── the exact volume fraction ersatz (task 2026-08-12)
    else if (s == "--frac") nexti(a.frac);
    else if (s == "--frac-eps") next(a.frac_eps);
    else if (s == "--frac-sens" && i + 1 < argc) a.frac_sens = argv[++i];
    else if (s == "--frac-soft") a.frac_soft = true;
    else if (s == "--frac-export") a.frac_export = true;
    else if (s == "--frac-kreport") a.frac_kreport = true;
    else if (s == "--frac-fd") nexti(a.frac_fd);
    else if (s == "--frac-aniso") a.frac_aniso = true;
    else if (s == "--alpha" && i + 1 < argc) a.alpha_in = argv[++i];
    else if (s == "--perimeter-local") next(a.perimeter_local);
    else if (s == "--willmore-full") a.willmore_full = true;
    else if (s == "--robust") next(a.robust);
    else if (s == "--nucleation-band") next(a.nucleation_band);
    else if (s == "--certify-every") nexti(a.certify_every);
    else if (s == "--certify-from") nexti(a.certify_from);
    else if (s == "--margin-stop") next(a.margin_stop);
    else if (s == "--wall-cap") next(a.wall_cap);
    else if (s == "--seed-period") next(a.seed_period);
    else if (s == "--reinit-substeps") a.reinit_substeps = true;
    else if (s == "--weno") a.weno = true;
    else if (s == "--rk3") a.rk3 = true;
    else if (s == "--no-surface-delta") a.no_surface_delta = true;
    else if (s == "--damp-factor") next(a.damp_factor);
    else if (s == "--damp-window") nexti(a.damp_window);
    else if (s == "--gridap-auto" && i + 1 < argc) a.gridap_auto = argv[++i];
    else if (s == "--rules" && i + 1 < argc) a.rules = argv[++i];
    else if (s == "--certify-field" && i + 1 < argc) a.certify_field.push_back(argv[++i]);
    else if (s == "--respect-frozen") a.respect_frozen = true;
    else if (s == "--dump-masked" && i + 1 < argc) a.dump_masked = argv[++i];
    else if (s == "--dump-mask" && i + 1 < argc) a.dump_mask = argv[++i];
    else if (s == "--plsm") a.plsm = true;
    else if (s == "--plsm-mma") { a.plsm = true; a.plsm_mma = true; }
    else if (s == "--plsm-hilb") a.plsm_hilb = true;
    else if (s == "--plsm-basis" && i + 1 < argc) a.plsm_basis = argv[++i];
    else if (s == "--plsm-knots" && i + 1 < argc) {
      if (std::sscanf(argv[++i], "%lf,%lf,%lf", &a.plsm_dx, &a.plsm_dy,
                      &a.plsm_dz) != 3) {
        std::printf("FATAL: --plsm-knots wants dx,dy,dz (VOXELS, PER AXIS)\n");
        std::exit(1);
      }
    }
    else if (s == "--plsm-support") next(a.plsm_support);
    else if (s == "--plsm-ridge") next(a.plsm_ridge);
    else if (s == "--plsm-band-weight") next(a.plsm_band_weight);
    else if (s == "--plsm-clamp") next(a.plsm_clamp);
    else if (s == "--plsm-move") next(a.plsm_move);
    else if (s == "--plsm-bound") next(a.plsm_bound);
    else if (s == "--plsm-refit-every") nexti(a.plsm_refit_every);
    else if (s == "--plsm-export" && i + 1 < argc)
      a.plsm_export.push_back(std::atoi(argv[++i]));
    else if (s == "--plsm-cg-iters") nexti(a.plsm_cg_iters);
    else if (s == "--warm-start") a.warm_start = true;
    else if (s == "--solver-kind") nexti(a.solver_kind);
    else if (s == "--penalized-solver") a.penalized_solver = true;
    else if (s == "--cg-tol-early") next(a.cg_tol_early);
    else if (s == "--cg-tol-until") nexti(a.cg_tol_until);
    else if (s == "--plsm-lbfgs") nexti(a.plsm_lbfgs);
    else if (s == "--seed" && i + 1 < argc) a.seed = argv[++i];
    else { std::printf("FATAL: unknown argument %s\n", s.c_str()); return 2; }
  }
  // ★ REFUSED, NOT IGNORED — the lesson PR 324 §9 paid for. `--plsm-hilb` under
  // `--plsm-mma` changed nothing at all, to twelve digits, and would have been
  // written up as an ablation that "measured no effect" if the run had not been
  // read closely. A flag that cannot act must say so.
  if (a.perimeter_local > 0.0 && !(a.perimeter > 0.0)) {
    std::printf(
        "FATAL: --perimeter-local scales the SAME ell as --perimeter\n"
        "       (ell = C*lambda*h, term = ell*kappa*(1 + beta*(kappa/kappa_rms)^2)),\n"
        "       so with C = 0 it multiplies zero and would measure nothing.\n"
        "       Give it a --perimeter C > 0.\n");
    return 2;
  }
  if (a.willmore_full && !(a.perimeter_local > 0.0)) {
    std::printf(
        "FATAL: --willmore-full restores the 2*kappa*(grad kappa . n) term that\n"
        "       --perimeter-local drops. With beta = 0 there is no Willmore term\n"
        "       to complete. Give it a --perimeter-local BETA > 0.\n");
    return 2;
  }
  if (!(a.seed_period > 1.0)) {
    std::printf("FATAL: --seed-period must be > 1 voxel (got %.4g); at or below\n"
                "       one voxel the cosine array is not resolved by the grid\n"
                "       and the seed is aliasing, not holes.\n", a.seed_period);
    return 2;
  }
  if (a.robust < 0.0) {
    std::printf("FATAL: --robust takes an erosion depth in VOXELS >= 0\n");
    return 2;
  }
  if (a.margin_stop > 0.0 && a.certify_every <= 0) {
    std::printf(
        "FATAL: --margin-stop needs --certify-every N. The margin is not\n"
        "       computed by the optimisation loop — it comes from\n"
        "       analyze_fixed_design, which has to be CALLED. Without a\n"
        "       cadence there is nothing for the rule to read and the flag\n"
        "       would silently never fire.\n");
    return 2;
  }
  // ★ REFUSED RATHER THAN IGNORED, and the number it is checked against is the
  // RBF support radius, because that is what the mask has to beat. A knot
  // contributes to the gradient iff its support reaches the band; with support
  // = `--plsm-support` x spacing, a mask at or above that radius cannot remove
  // a single non-zero component and would measure nothing at all. This is
  // exactly the trap PR 324 §9 hit with `--plsm-hilb` under `--plsm-mma`.
  if (a.nucleation_band > 0.0) {
    const double support_vox =
        a.plsm_support * std::max({a.plsm_dx, a.plsm_dy, a.plsm_dz});
    if (a.nucleation_band >= support_vox) {
      std::printf(
          "FATAL: --nucleation-band %.4g voxels is at or beyond the RBF support\n"
          "       radius (%.4g x max spacing %.4g = %.4g voxels). Every knot with a\n"
          "       non-zero gradient already lies inside that radius, so the mask\n"
          "       would zero nothing and the arm would measure the control.\n",
          a.nucleation_band, a.plsm_support,
          std::max({a.plsm_dx, a.plsm_dy, a.plsm_dz}), support_vox);
      return 2;
    }
  }
  if (a.simp && a.rules.empty()) {
    std::printf("FATAL: --simp needs --rules <settings/rules.json> (the shipped\n"
                "       ladder takes the rule table the CLI takes)\n");
    return 2;
  }

  // ── ★ THE EXACT-FRACTION ERSATZ REFUSES WHAT IT HAS NOT MADE CONSISTENT ───
  //
  // A density and a sensitivity that describe different objects is the single
  // most likely way this run is wasted, so every combination whose gradient this
  // task has NOT rewritten is refused outright rather than run and believed.
  if (a.frac > 0) {
    if (!a.plsm) {
      std::printf(
          "FATAL: --frac needs --plsm. The fraction is an integral of the\n"
          "       ANALYTIC phi over the cell; a per-voxel phi has no value\n"
          "       between its samples to integrate, and interpolating one would\n"
          "       measure the interpolant. The voxel arms keep H_eta.\n");
      return 2;
    }
    if (a.frac < 2 || a.frac > 16) {
      std::printf("FATAL: --frac K must be between 2 and 16 (K=%d given). K=1 is\n"
                  "       the cell centre, i.e. the H_eta arm with a hard step.\n",
                  a.frac);
      return 2;
    }
    if (!a.plsm_mma && a.frac_fd == 0 && !a.frac_kreport) {
      std::printf(
          "FATAL: --frac needs --plsm-mma. The steepest-descent and L-BFGS\n"
          "       branches consume `g = Psi^T v`, which evaluates psi_i at the\n"
          "       CELL CENTRE — the approximation the fraction's derivative\n"
          "       exists to remove. Refused rather than run with a gradient that\n"
          "       does not belong to the density.\n");
      return 2;
    }
    if (a.frac_sens != "exact" && a.frac_sens != "centre") {
      std::printf("FATAL: --frac-sens must be `exact` or `centre` (got '%s')\n",
                  a.frac_sens.c_str());
      return 2;
    }
    if (a.robust > 0.0) {
      std::printf(
          "FATAL: --frac and --robust are not consistent in this build. The\n"
          "       robust formulation reads the objective's sensitivity on the\n"
          "       ERODED surface {phi = -delta} (PR 326 P7), which needs a second\n"
          "       shifted quadrature this task has not written. Refused rather\n"
          "       than run with the intermediate's band, which is the exact bug\n"
          "       PR 326 caught by reading.\n");
      return 2;
    }
    if (a.plsm_hilb) {
      std::printf(
          "FATAL: --frac and --plsm-hilb are not consistent in this build. The\n"
          "       Hilbertian extension is a solve on the VOXEL field, so the\n"
          "       sensitivity it returns cannot carry the sub-cell psi the\n"
          "       fraction's derivative is an integral of.\n");
      return 2;
    }
    if (a.no_surface_delta) {
      std::printf(
          "FATAL: --frac and --no-surface-delta contradict each other. The\n"
          "       second replaces the surface measure by a volume one over the\n"
          "       whole active domain; the first IS a surface measure.\n");
      return 2;
    }
    if (!(a.frac_eps > 0.0)) {
      std::printf("FATAL: --frac-eps must be > 0 (the quadrature mollifier would\n"
                  "       have zero width and the sum would alias to nothing)\n");
      return 2;
    }
  } else if (a.frac_kreport || a.frac_soft || a.frac_export) {
    std::printf("FATAL: --frac-kreport / --frac-soft / --frac-export all need\n"
                "       --frac K.\n");
    return 2;
  } else if (a.frac_fd > 0 && !a.plsm) {
    // ★ --frac-fd WITHOUT --frac IS DELIBERATELY ALLOWED, and it is the control
    // that makes R4 worth reading: it differences PR 326's OWN gradient —
    // DH_eta(phi)*|grad phi| projected by Psi^T — against the same functions, on
    // the same design, with the same steps. "The new gradient checks out" means
    // nothing without knowing what the old one does.
    std::printf("FATAL: --frac-fd needs --plsm (there are no coefficients to\n"
                "       differentiate with respect to otherwise)\n");
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
  // ★ A REFUSAL ADDED BECAUSE THE ABLATION IT GUARDS WAS RUN AND WAS A NO-OP.
  //
  // `--plsm-hilb` puts the Hilbertian velocity extension back, to test the
  // literature's claim that the RBF support already does that job. Under
  // `--plsm-mma` it did NOTHING, and the run that proved it is on disk: A4_hilb's
  // compliance matched A1's to twelve digits at every iteration.
  //
  // The reason is structural, not a slip. The MMA branch needs the SENSITIVITIES
  // dJ/dalpha and dV/dalpha, which it builds from `raw_vel` and `delta` by the
  // chain rule; the extended field `vel` is a DESCENT DIRECTION, not a gradient,
  // and feeding it to MMA would hand the subproblem something that is not the
  // derivative of anything. So the extension is meaningful only against steepest
  // descent, where a velocity is a velocity — and the honest ablation is
  // `--plsm --plsm-hilb` against `--plsm`.
  //
  // Refusing is better than silently ignoring: a flag that appears in a command
  // line and changes nothing is how an ablation gets reported as a result.
  if (a.plsm_mma && a.plsm_hilb) {
    std::printf(
        "FATAL: --plsm-hilb has no meaning under --plsm-mma and will not be\n"
        "       silently ignored. MMA consumes the SENSITIVITIES, which are built\n"
        "       from the un-extended field by the chain rule; the Hilbertian\n"
        "       extension produces a DESCENT DIRECTION, which is not a derivative.\n"
        "       Run the extension ablation against steepest descent:\n"
        "         --plsm --plsm-hilb   against   --plsm\n");
    return 1;
  }

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

  // ── THE DESIGN MASK ITSELF, AS A FIELD ────────────────────────────────────
  //
  // ★ SO THE FROZEN SET CAN BE COMBINED WITH AN ANALYTIC PHI ANALYTICALLY,
  // INSTEAD OF STAMPED OVER IT. Stamping 40,216 voxels to hard 0/1 is a
  // staircase by construction, and it costs the parametric representation about
  // a fifth of its measured advantage and pins `midpoint_share` at 51%. The
  // alternative is a boolean on the level sets — phi_eff = min(phi, phi_frozen)
  // is the UNION, and it needs the frozen set as a FUNCTION rather than a set of
  // tags. This writes the tags; `plsm_probe --frozen-*` turns them into one.
  //
  // 1.0 = FrozenSolid, 0.5 = Active, 0.0 = FrozenVoid or Empty.
  if (!a.dump_mask.empty()) {
    std::vector<double> mk(n, 0.5);
    for (std::size_t v = 0; v < n; ++v) {
      if (grid.tags[v] == VoxelTag::Empty || eff[v] == MaskValue::FrozenVoid)
        mk[v] = 0.0;
      else if (eff[v] == MaskValue::FrozenSolid) mk[v] = 1.0;
    }
    std::ofstream f(a.dump_mask + ".f64", std::ios::binary);
    f.write(reinterpret_cast<const char*>(mk.data()),
            static_cast<std::streamsize>(n * sizeof(double)));
    std::ofstream m(a.dump_mask + ".meta");
    m.precision(17);
    m << "rung 0.68\nrequested_vf 0.68\n";
    m << "nx " << d.nx << "\nny " << d.ny << "\nnz " << d.nz << "\n";
    m << "spacing " << h << "\n";
    m << "ox " << grid.origin.x << "\noy " << grid.origin.y << "\noz "
      << grid.origin.z << "\n";
    m << "iso 0.5\nfactor 2\ninterp tricubic\nachieved_vf 0\n";
    m << "iterations 0\nwall_s 0\ncompliance 0\n";
    m << "# 1.0 FrozenSolid (" << n_fsolid << "), 0.5 Active (" << n_active
      << "), 0.0 FrozenVoid/Empty (" << n_fvoid << ")\n";
    std::printf("wrote the design mask to %s.f64\n", a.dump_mask.c_str());
  }

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
          "load_path_connected,frozen_solid_below_iso,frozen_solid_total,"
          "frozen_void_above_iso,frozen_restored,mass_grams\n";
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

    // ── THE FROZEN SET, MEASURED AND (OPTIONALLY) RESTORED ────────────────
    //
    // ★ ADDED BY task 2026-08-10-parametric-level-set, ARM 1, BECAUSE EVERY
    // FITTED FIELD CAME BACK "REJECTED — load path not connected" AND THE
    // MARGIN NUMBER DID NOT SAY WHY. A field this program produces itself
    // always honours the mask (the ersatz composes it at line ~1442), so until
    // an EXTERNAL field arrived that did not, there was nothing here to see.
    //
    // His job freezes material: the Load/Fixture pad, the anchor (face 18) and
    // face protection 16 are the voxels core tags FrozenSolid, 10554 of them.
    // A level set stored per voxel can hold that set exactly. An ANALYTIC phi
    // cannot — a smooth function has no way to be discontinuous at the pad's
    // boundary — so a fitted phi drops some of those voxels below the iso, and
    // `load_path_connected` walks from the anchor set and finds no route.
    //
    // The counts below are reported for EVERY field, always. `--respect-frozen`
    // then restores the mask before certifying, which is exactly the masking
    // Arm 2(e) proposes for the coefficient update; running both is what turns
    // "REJECTED" into an ATTRIBUTION.
    std::size_t fs_lost = 0, fv_gained = 0;
    for (std::size_t v = 0; v < n; ++v) {
      if (eff[v] == MaskValue::FrozenSolid && !(f[v] > cert_iso)) ++fs_lost;
      else if (eff[v] == MaskValue::FrozenVoid && f[v] > cert_iso) ++fv_gained;
    }
    if (a.respect_frozen) {
      for (std::size_t v = 0; v < n; ++v) {
        if (eff[v] == MaskValue::FrozenSolid) f[v] = 1.0;
        else if (eff[v] == MaskValue::FrozenVoid) f[v] = 0.0;
      }
    }
    // ★ WRITE THE FIELD THE CERTIFICATE ACTUALLY READ, so the SURFACE can be
    // measured on the SAME OBJECT the margin belongs to.
    //
    // This exists because ARM 2's exports came back rougher than SIMP while
    // ARM 1's fits came back far smoother, and the two differ by exactly this:
    // ARM 1's fitted fields were measured WITHOUT the frozen mask — which is
    // why they were REJECTED — and ARM 2's carry it. 40,216 voxels stamped hard
    // to 0 or 1 is 53% of the printed material, and a hard stamp is a staircase
    // by construction. A roughness number measured on the unmasked field is a
    // number about an object that does not certify.
    if (!a.dump_masked.empty()) {
      char pfx[512];
      std::snprintf(pfx, sizeof pfx, "%s/%s", a.dump_masked.c_str(),
                    cf.substr(cf.find_last_of('/') + 1).c_str());
      std::ofstream mf(std::string(pfx) + ".f64", std::ios::binary);
      mf.write(reinterpret_cast<const char*>(f.data()),
               static_cast<std::streamsize>(n * sizeof(double)));
      std::ofstream mm(std::string(pfx) + ".meta");
      mm.precision(17);
      char rl[32];
      std::snprintf(rl, sizeof rl, "%.2f", a.rung);
      mm << "rung " << rl << "\nrequested_vf " << a.rung << "\n";
      mm << "nx " << d.nx << "\nny " << d.ny << "\nnz " << d.nz << "\n";
      mm << "spacing " << h << "\n";
      mm << "ox " << grid.origin.x << "\noy " << grid.origin.y << "\noz "
         << grid.origin.z << "\n";
      mm << "iso 0.5\nfactor 2\ninterp tricubic\n";
      std::size_t masked_printed = 0;
      for (std::size_t v2 = 0; v2 < n; ++v2)
        if (f[v2] > cert_iso) ++masked_printed;
      mm << "achieved_vf " << (masked_printed / part_solid) << "\n";
      mm << "iterations 0\nwall_s 0\ncompliance 0\n";
      mm << "# THE FIELD THE CERTIFICATE READ" << (a.respect_frozen
             ? ", frozen mask restored" : ", mask NOT restored") << "\n";
    }

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
                  "printed voxels       %zu of %.0f  (vf %.6f)\n"
                  "FrozenSolid BELOW iso %zu of %zu   FrozenVoid above %zu\n"
                  "frozen set restored  %s\n",
                  cf.c_str(), a.binarize ? "YES (0/1 at iso 0.5)" : "no",
                  frac, params.penalty, cprinted, part_solid,
                  cprinted / part_solid, fs_lost, n_fsolid, fv_gained,
                  a.respect_frozen ? "YES (--respect-frozen)" : "no");
    std::string cs = cbuf;
    if (cdone && !ca.non_convergent) {
      std::snprintf(cbuf, sizeof cbuf,
                    "max von Mises        %.9f MPa\n"
                    "MARGIN worst case    %.9f\n"
                    "margin effective     %.9f   (gate: >= %.4g)\n"
                    "VERDICT              %s\n"
                    "min-feature viols    %d\n"
                    "mass                 %.4f g\n"
                    "load path connected  %s\n",
                    ca.max_von_mises, ca.margin.worst_case, ca.margin_effective,
                    options.margin_stop, ca.accepted ? "ACCEPTED" : "REJECTED",
                    ca.v3.min_feature_violations, ca.mass_grams,
                    cok ? "yes" : "NO");
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
           << ca.v3.min_feature_violations << ',' << (cok ? 1 : 0) << ',';
    else
      mcsv << ",,,,," << (cok ? 1 : 0) << ',';
    mcsv << fs_lost << ',' << n_fsolid << ',' << fv_gained << ','
         << (a.respect_frozen ? 1 : 0) << ',';
    // The task asks for MASS beside the margin. It is `analyze_fixed_design`'s
    // own `mass_grams` — the same field the trajectory's summary prints — and not
    // a printed-voxel count multiplied by a density recovered from an old log.
    if (cdone && !ca.non_convergent) mcsv << ca.mass_grams;
    mcsv << '\n';
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
    //
    // ★ ARM 2 MECHANISM — THE SEED'S TOPOLOGY SCALE, AND IT IS NOT THE BASIS.
    // PR 324 §6(ii) refuted a COARSER BASIS as a smoothness lever: 24,480
    // coefficients against 85,680 moved carved share only 42.9% -> 40.9% and
    // HALVED the margin. That is a statement about the DESIGN SPACE. This is a
    // statement about the STARTING POINT, which is a different object: at period
    // 8 on a 128 x 31 x 118 grid the seed contains on the order of a thousand
    // holes, and a level set — parametric or not — is initial-design dependent.
    // Wei, Li, Wang & Gao claim the parametric form has "LESS dependency on
    // initial designs", not none. So the run inherits a topology roughly as fine
    // as its seed, and every one of those interfaces is surface.
    //
    // ★ AND IT COSTS NOTHING. It adds no term, no state solve and no constraint,
    // so unlike the perimeter penalty it cannot buy smoothness by removing
    // load-bearing material — whatever it does to the margin it does by finding
    // a different structure, not by taxing the one it found.
    const double per = a.seed_period;
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

  // ── ARM 2: THE REPRESENTATION CHANGE, AND THE ONLY PLACE IT HAPPENS ───────
  //
  // ★ FROM HERE ON, IN --plsm MODE, phi IS NOT A DESIGN VARIABLE. It is the
  // VALUE of an analytic function, phi(x) = sum_i alpha_i psi_i(x), on this
  // grid, and `alpha` is what the optimiser moves. Everything downstream — the
  // ersatz, the mask, the state solve, the shape derivative, the volume target,
  // `analyze_fixed_design` — reads `phi` and `rho` exactly as it did before and
  // does not know the difference. That is the task's constraint (c) and it is
  // enforced structurally: `phi` is only ever WRITTEN by `plsm_sync` below.
  //
  // What the change DELETES, and this is the point: no Hamilton-Jacobi PDE, no
  // Godunov or WENO gradient, no CFL sub-stepping, no gamma damper, and no
  // reinitialisation. `--plsm-refit-every` is available as the literature's
  // "approximate re-initialisation" and is OFF by default, so the default arm
  // runs with none of it and the claim can be tested rather than assumed.
  KnotLattice L;
  Basis pbasis = Basis::Wendland;
  Csr Psi, PsiT;
  std::vector<double> alpha, psi_sum;
  const int plsm_threads = a.threads > 0 ? a.threads : 3;
  // The offset the volume constraint bisects is added to EVERY coefficient, so
  // it moves phi by offset * psi_sum(x) and STAYS IN THE SPAN OF THE BASIS. In
  // the voxel mode `off_shape` is all ones and `phi + offset * 1` is the
  // existing line, unchanged — which is why the generalisation is a no-op there.
  std::vector<double> off_shape(n, 1.0);
  // ★ THE NUCLEATION BAND's bookkeeping: which coefficients were allowed to
  // move this iteration, and how many were held. `nuc_frozen` goes in the CSV
  // so a mask that froze nothing (or everything) is visible rather than assumed.
  std::vector<char> nuc_mask;
  std::size_t nuc_frozen = 0;
  auto plsm_sync = [&]() {
    spmv(Psi, alpha, phi, plsm_threads);
  };
  if (a.plsm) {
    if (a.plsm_basis == "gaussian") pbasis = Basis::Gaussian;
    else if (a.plsm_basis != "wendland") {
      std::printf("FATAL: --plsm-basis must be wendland or gaussian\n");
      return 1;
    }
    // ★ R4 — PER AXIS, NOT MINIMUM. The knot spacing is three numbers and the
    // support is an ellipsoid R_a = support * Delta_a. Deriving one spacing from
    // min(nx,ny,nz) on this 128 x 31 x 118 slab is the trap that cost PR 324 a
    // day, and nothing here can do it: there is no minimum taken anywhere.
    L = make_lattice(d, a.plsm_dx, a.plsm_dy, a.plsm_dz, a.plsm_support);
    const double t_p0 = now_s();
    Psi = build_A(d, L, pbasis, plsm_threads);
    PsiT = transpose(Psi, plsm_threads);
    nuc_mask.assign(L.count(), 1);
    psi_sum.assign(n, 0.0);
    {
      const std::vector<double> ones(L.count(), 1.0);
      spmv(Psi, ones, psi_sum, plsm_threads);
    }
    off_shape = psi_sum;
    // The seed: the SAME weighted least-squares fit `plsm_probe` runs, on the
    // SAME clamped target, from `plsm_basis.hpp`. So ARM 2 starts from exactly
    // the object ARM 1 measured.
    std::vector<double> target(n, 0.0), wts(n, 1.0);
    for (std::size_t v = 0; v < n; ++v) {
      target[v] = std::max(-a.plsm_clamp * h, std::min(a.plsm_clamp * h, phi[v]));
      if (a.plsm_band_weight != 1.0) {
        const double t = phi[v] / eta;
        wts[v] = 1.0 + (a.plsm_band_weight - 1.0) * std::exp(-std::min(60.0, t * t));
      }
    }
    const FitResult fr = solve_normal(Psi, PsiT, target, wts, a.plsm_ridge,
                                      a.plsm_cg_iters, 1e-10, plsm_threads);
    alpha = fr.alpha;
    plsm_sync();
    double rb = 0.0;
    std::size_t bn = 0;
    for (std::size_t v = 0; v < n; ++v)
      if (std::fabs(target[v]) <= eta) { rb += (phi[v] - target[v]) * (phi[v] - target[v]); ++bn; }
    double smin = 1e30, smax = -1e30;
    for (std::size_t v = 0; v < n; ++v) {
      if (grid.tags[v] == VoxelTag::Empty) continue;
      smin = std::min(smin, psi_sum[v]);
      smax = std::max(smax, psi_sum[v]);
    }
    std::printf(
        "PLSM        phi = sum alpha_i psi_i  —  %s basis, knots (%.3g, %.3g, "
        "%.3g) voxels PER AXIS\n"
        "            %d x %d x %d = %zu COEFFICIENTS against %zu voxels "
        "(compression %.1fx)\n"
        "            support %.3g x spacing = (%.3f, %.3f, %.3f) mm, "
        "nnz(Psi) %zu (%.1f per voxel)\n"
        "            seed fit: %d CG iterations, rel resid %.2e, band rms "
        "%.5f mm, %.1f s\n"
        "            volume offset moves phi by offset * sum_i psi_i, which is "
        "%.4f..%.4f in the part\n"
        "            update: %s;  Hilbertian extension: %s;  "
        "approximate re-init: %s\n",
        a.plsm_basis.c_str(), a.plsm_dx, a.plsm_dy, a.plsm_dz, L.mx, L.my, L.mz,
        L.count(), n, static_cast<double>(n) / static_cast<double>(L.count()),
        a.plsm_support, L.rx * h, L.ry * h, L.rz * h, Psi.nnz(),
        static_cast<double>(Psi.nnz()) / static_cast<double>(n), fr.cg_iters,
        fr.rel_resid, bn ? std::sqrt(rb / static_cast<double>(bn)) : 0.0,
        now_s() - t_p0, smin, smax,
        a.plsm_mma ? "MMA on the coefficients" : "steepest descent on the coefficients",
        a.plsm_hilb ? "ON (ablation)" : "off — the RBF support is the extension",
        a.plsm_refit_every > 0 ? "every N iterations" : "off");
    std::fflush(stdout);
  }

  // ── the ersatz, and the volume it measures ────────────────────────────────
  //
  // `occ` is the OCCUPANCY (0..1) the volume target and every downstream
  // instrument read; `rho` is that clamped into the SIMP admissible band. They
  // are separate because the volume constraint is a statement about the OBJECT
  // and rho_min is a statement about the SOLVER.
  std::vector<double> occ(n, 0.0), rho(n, 0.0);
  const double rho_min = params.density_min;

  // ══ ★ THE EXACT VOLUME FRACTION ERSATZ (task 2026-08-12) ═════════════════
  //
  // ★ TWO OCCUPANCIES, AND KEEPING THEM APART IS WHAT MAKES R5 HOLD.
  //
  //   occ[v]   the PRINTED occupancy. H_eta(-phi) at the cell centre, exactly
  //            as PR 326 wrote it. It is what the volume constraint counts,
  //            what `printed_voxels` counts, what is EXPORTED at F=1 and what
  //            `analyze_fixed_design` certifies. ★ IT IS UNCHANGED, DELIBERATELY:
  //            the printed set is `{H_eta(-phi) > 0.5}` = `{phi < 0}` — provably
  //            eta-free, because H_eta is monotone with H(0) = 0.5 exactly (PR
  //            326 §3(e) proves and measures it) — so the part this run makes,
  //            weighs and certifies is defined bit-identically to PR 326's. One
  //            variable changes and it is not the definition of the part.
  //
  //   frho[v]  the ERSATZ the STATE SOLVE sees. The exact fraction of the cell
  //            inside {phi < 0}, sampled k x k x k. THIS is the one variable.
  //
  // Everything about the solver is untouched — the cell stiffness is still
  // rho_e * K0 — but rho_e now moves continuously as the interface crosses the
  // cell instead of stepping when it passes the centre.
  const bool frac_on = a.frac > 0;
  FracCache fcache;
  std::vector<char> frac_sample(n, 0);
  std::vector<double> frac_gm(n, 0.0);      // |grad phi| per cell, for eps_q
  std::vector<double> dfrac(n, 0.0);        // the quadrature band, 1/mm
  std::size_t frac_boundary = 0;
  double frac_build_s = 0.0, frac_sens_s = 0.0, frac_area = 0.0;
  {
    // ★ ONLY THE ACTIVE CELLS ARE EVER SAMPLED, and S1(b)'s "a few per cent" is
    // an understatement on this part: `Empty`, `FrozenSolid` and `FrozenVoid`
    // cells are stamped by the MASK and the optimiser has no say over them, so
    // 397,536 of the 468,224 are excluded before any test on phi. The cells that
    // are actually CUT are then COUNTED every iteration (`FracCache::n_boundary`)
    // rather than bounded by a classifier — a classifier would need a margin,
    // and a margin is one more thing that can be wrong.
    for (std::size_t v = 0; v < n; ++v)
      frac_sample[v] = (grid.tags[v] != VoxelTag::Empty &&
                        eff[v] == MaskValue::Active) ? 1 : 0;
  }
  // Rebuilt from the CURRENT alpha, after the volume offset has been folded in
  // and phi resynced, so the samples describe the phi the solve is about to see.
  auto frac_refresh = [&]() {
    if (!frac_on) return;
    frac_build(d, L, pbasis, alpha, frac_sample, a.frac, plsm_threads, fcache);
    frac_boundary = fcache.n_boundary;
    frac_build_s = fcache.build_s;
    for (int k = 0; k < d.nz; ++k)
      for (int j = 0; j < d.ny; ++j)
        for (int i = 0; i < d.nx; ++i) {
          const std::size_t v = d.at(i, j, k);
          frac_gm[v] = frac_sample[v] ? grad_mag(d, phi, i, j, k, h) : 0.0;
        }
  };

  auto build_fields = [&](double offset) {
    for (std::size_t v = 0; v < n; ++v) {
      double o;
      if (grid.tags[v] == VoxelTag::Empty || eff[v] == MaskValue::FrozenVoid) o = 0.0;
      else if (eff[v] == MaskValue::FrozenSolid) o = 1.0;
      else o = heaviside(-(phi[v] + offset * off_shape[v]), eta);
      occ[v] = o;
      // ★ rho FOLLOWS THE FRACTION WHEN IT IS ARMED, occ NEVER DOES. The frozen
      // classes are stamped identically in both — they are the mask's statement
      // and not the level set's — so the fraction only ever touches the 70,688
      // cells the optimiser actually owns.
      double e = o;
      if (frac_on && offset != 0.0) {
        // The cache is sampled from the CURRENT alpha, so a non-zero offset here
        // would apply to `occ` and not to the fraction and the two would
        // describe different surfaces. The loop folds the offset into alpha and
        // calls this with 0; nothing else may.
        std::printf("\n*** FATAL: build_fields(%.17g) under --frac. The fraction "
                    "is sampled from\n*** alpha, so the offset must be folded in "
                    "before this is called.\n", offset);
        std::exit(3);
      }
      if (frac_on && grid.tags[v] != VoxelTag::Empty &&
          eff[v] == MaskValue::Active) {
        e = a.frac_soft
                ? frac_of_soft(fcache, v,
                               frac_eps(frac_gm[v], h, a.frac, a.frac_eps))
                : frac_of(fcache, v);
      }
      rho[v] = rho_min + (1.0 - rho_min) * e;
    }
  };

  // ★ S1 — WHAT THE CONSTRAINT ACTUALLY MEASURES. This is the one line PR 324
  // §6 named and did not change.
  //
  // ★ AND THE PREDICATE IS `H_eta(-p) > 0.5`, NOT `p < 0`, WHICH IS NOT THE SAME
  // TEST IN FLOATING POINT AND THE FIRST RUN CAUGHT IT. Mathematically the two
  // sets are identical: `heaviside` is monotone with H(0) = 0.5 exactly. But for
  // |p| below about 1e-16*eta the smoothed form evaluates
  // 0.5*(1 + p/eta + sin(...)/pi) and ROUNDS BACK TO EXACTLY 0.5, so a voxel a
  // rounding error inside the surface counts as printed by one test and not by
  // the other. The re-baseline stopped on iteration 1 with 75,415 against
  // 75,414 — one voxel — and the assertion is what stopped it.
  //
  // Writing the constraint as the printed predicate ITSELF is also the more
  // honest statement of intent: PR 324 §6 says "the part is #{rho > 0.5}", the
  // extraction takes iso 0.5, `analyze_fixed_design` reads that same field, and
  // this now constrains exactly that set rather than an algebraically equal
  // surrogate. `occupancy_volume` and `printed_voxels` agree bit for bit, which
  // the loop asserts every iteration; without the flag they are free to
  // separate and the CSV shows them doing it.
  // ★ ARM 2 — THE ERODED AND DILATED DESIGNS, and the ONE thing that makes the
  // robust formulation cheap on a level set. `build_fields` scales its offset by
  // `off_shape` (which is `psi_sum` in parametric mode) because the volume
  // offset has to stay inside the span of the basis. An EROSION must not: it is
  // a rigid inward move of the surface by `dphi` millimetres, the same everywhere,
  // and it is never a design — it is evaluated, solved, and thrown away. So this
  // adds a plain constant. The frozen classes are copied through untouched:
  // frozen material is not the optimiser's to erode, and eroding it would break
  // the load path for a reason that has nothing to do with the design.
  std::vector<double> rho_eroded(n, 0.0), rho_dilated(n, 0.0);
  auto build_rho_shift = [&](double dphi, std::vector<double>& out) {
    for (std::size_t v = 0; v < n; ++v) {
      double o;
      if (grid.tags[v] == VoxelTag::Empty || eff[v] == MaskValue::FrozenVoid) o = 0.0;
      else if (eff[v] == MaskValue::FrozenSolid) o = 1.0;
      else o = heaviside(-(phi[v] + dphi), eta);
      out[v] = rho_min + (1.0 - rho_min) * o;
    }
  };

  auto volume_at = [&](double offset) {
    double s = 0.0;
    for (std::size_t v = 0; v < n; ++v) {
      if (grid.tags[v] == VoxelTag::Empty || eff[v] == MaskValue::FrozenVoid) continue;
      if (eff[v] == MaskValue::FrozenSolid) { s += 1.0; continue; }
      const double o = heaviside(-(phi[v] + offset * off_shape[v]), eta);
      s += a.volume_count ? (o > 0.5 ? 1.0 : 0.0) : o;
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
  {
    std::error_code ec;
    std::filesystem::create_directories(a.out, ec);
  }
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
         // ★ S3 — the two columns that make the penalty legible per iteration.
         // `perim_weight` is the RAMPED weight actually applied (not the flag),
         // so a continuation shows up in the file rather than only in the
         // command line. `interface_area_mm2` is the quantity being penalised,
         // measured as the functional itself: Per = ∫ DH_eta(phi)|grad phi| dΩ,
         // which is `sum_v delta[v] * h^3` — `delta` is exactly that integrand
         // and is already built for the shape derivative. So the objective term
         // and its diagnostic are the same expression, not two.
         "perim_weight,interface_area_mm2,"
         // ARM 2: which of the eroded / intermediate / dilated designs the
         // worst-case objective landed on (0/1/2), and its compliance against
         // the intermediate's. Both are 1 when --robust is off.
         "robust_worst,robust_ratio,nuc_frozen,"
         // ★ THE EXACT-FRACTION COLUMNS (task 2026-08-12). All zero when --frac
         // is off, so a PR 326 arm's file gains four zero columns and nothing
         // else. `frac_cut_cells` is S1(b)'s question answered by COUNTING it
         // every iteration; `frac_area_mm2` is the interface area measured on
         // the new band (dfrac * |grad phi| * h^3), which is what
         // `interface_area_mm2` means on the OLD one — the two columns are the
         // same physical quantity through two different measures and are
         // reported side by side rather than one being silently redefined.
         // `frac_ms` is the whole per-iteration cost of the fraction: the
         // sampling, the band and the scatter.
         "frac_cut_cells,frac_area_mm2,frac_build_ms,frac_sens_ms,"
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
  // The band's mean-curvature field, built once per iteration when the perimeter
  // term is on. Held out here rather than allocated inside the loop because the
  // curvature-concentration term reads NEIGHBOURS of it (`--willmore-full`), so
  // it has to exist as a field and not as a per-voxel scalar.
  std::vector<double> curv_field(n, 0.0);
  // The perimeter/curvature term, held apart from the energy so the two can
  // ride DIFFERENT bands when --robust moves the objective's surface.
  std::vector<double> pen(n, 0.0);
  // The band of whichever design the objective landed on. Equal to `delta`
  // unless --robust is on; see where it is filled.
  std::vector<double> delta_obj(n, 0.0);
  // ARM 2's optimiser state. The coefficient box is sized from the SEED, because
  // an RBF coefficient is scaled like the distance it interpolates (mm here) and
  // there is no universal bound to write down; +-4x the largest seed coefficient
  // is wide enough that the box is never the active constraint on this part, and
  // `--plsm-bound` moves it.
  PlsmMmaState mma_state;
  int plsm_mma_iter = 0;
  // L-BFGS history (PROBE 3): the last `--plsm-lbfgs` (step, gradient-change)
  // pairs, plus the previous step and gradient the next pair is built from.
  std::vector<std::vector<double>> lb_hist_s, lb_hist_y, lb_s, lb_y;
  std::vector<double> lb_prev_step, lb_prev_g;
  double plsm_alpha_bound = 1.0, plsm_psi_max = 1.0;
  if (a.plsm) {
    for (double c : alpha) plsm_alpha_bound = std::max(plsm_alpha_bound, std::fabs(c));
    plsm_alpha_bound *= a.plsm_bound;
    plsm_psi_max = 0.0;
    for (std::size_t v = 0; v < n; ++v)
      if (grid.tags[v] != VoxelTag::Empty)
        plsm_psi_max = std::max(plsm_psi_max, psi_sum[v]);
    if (!(plsm_psi_max > 0.0)) plsm_psi_max = 1.0;
    std::printf("PLSM        coefficient box +-%.4f (%.3gx the largest seed "
                "coefficient); a unit move of every\n"
                "            coefficient carries phi by at most %.4f mm, which is "
                "what sizes the MMA move\n", plsm_alpha_bound, a.plsm_bound,
                plsm_psi_max);
  }
  // ★ SAID OUT LOUD IN THE LOG, because both of these change what the run
  // OPTIMISES rather than only how fast it gets there, and a table row is
  // meaningless without knowing which convention produced it.
  std::printf("VOLUME      constraint measures %s\n",
              a.volume_count
                  ? "#{phi + c < 0} — the PRINTED count (S1: occupancy_volume "
                    "and printed_voxels agree by construction)"
                  : "int H_eta(-phi) — the SMOOTHED integral (PR 324's "
                    "convention; drifts from the printed part with area)");
  if (a.perimeter > 0.0) {
    if (a.perimeter_ramp_start > 0 || a.perimeter_ramp_len > 0)
      std::printf("PERIMETER   C = %.4g, RAMPED: zero until iteration %d, full "
                  "at %d\n", a.perimeter, a.perimeter_ramp_start,
                  a.perimeter_ramp_start + a.perimeter_ramp_len);
    else
      std::printf("PERIMETER   C = %.4g, FIXED from iteration 1\n", a.perimeter);
  }
  // ★ SAID OUT LOUD, BECAUSE IT IS THE ONE VARIABLE. A table row produced with
  // this on and one produced with it off are two different formulations, and the
  // log must not leave that to be inferred from a command line.
  if (frac_on) {
    std::size_t nact = 0;
    for (std::size_t v = 0; v < n; ++v) nact += frac_sample[v] ? 1 : 0;
    std::printf(
        "★ ERSATZ    THE EXACT VOLUME FRACTION, not H_eta at the cell centre.\n"
        "            rho_e = |{phi<0} cap cell| / |cell|, by %d x %d x %d = %d\n"
        "            sub-samples of the ANALYTIC phi per cell, on the SAME\n"
        "            sub-cell lattice marching_cubes_resampled uses.\n"
        "            %zu of %zu cells are sampled (the ACTIVE ones); the rest are\n"
        "            stamped 0/1 by the mask and were never the level set's.\n"
        "            value    %s\n"
        "            gradient %s\n"
        "            eps_q    %.4g x |grad phi| x h/%d = %.5f mm at |grad phi| = 1\n"
        "                     — a QUADRATURE bandwidth tied to the sample spacing,\n"
        "                       so it shrinks like 1/K. It is not eta: eta is a\n"
        "                       fixed 2 voxels and appears in the density; this\n"
        "                       appears in no density at all.\n"
        "            export   %s\n",
        a.frac, a.frac, a.frac, a.frac * a.frac * a.frac, nact, n,
        a.frac_soft ? "MOLLIFIED — the antiderivative of the gradient's own "
                      "mollifier (--frac-soft)"
                    : "the HARD sample count (piecewise constant in alpha; see "
                      "frac_ersatz.hpp)",
        a.frac_sens == "exact"
            ? "EXACT — psi_i evaluated AT THE SAMPLES and scattered"
            : "CENTRE — psi_i factored out at the cell centre, Psi^T (ABLATION)",
        a.frac_eps, a.frac, frac_eps(1.0, h, a.frac, a.frac_eps),
        a.frac_export ? "H_eta (the row of record, R5) AND the fraction, side by side"
                      : "H_eta only — R5, bit-identical to PR 326's convention");
    std::printf(
        "            ★ WHAT STILL READS eta, stated rather than left to be found:\n"
        "              * the PRINTED predicate {H_eta(-phi) > 0.5}. Provably\n"
        "                eta-free as a SET (H is monotone, H(0) = 0.5 exactly),\n"
        "                so the part, its mass and its certificate are defined\n"
        "                identically to PR 326's. R5.\n"
        "              * the F>=1 EXPORT's field values, where eta DOES move\n"
        "                vertex placement. Kept as the row of record; --frac-export\n"
        "                emits the fraction beside it as the named control.\n"
        "              * the reinit residual's reporting band and the refit's fit\n"
        "                weight — diagnostics and the approximate reinitialisation,\n"
        "                neither of which is the variable under test.\n"
        "              * Per = INT DH_eta(phi)|grad phi| — GONE with the density.\n"
        "                Under --frac the perimeter term rides the QUADRATURE band\n"
        "                and no longer contains eta at all.\n");
  }

  std::vector<double> best_occ, best_rho;
  double best_compliance = std::numeric_limits<double>::infinity();
  int best_iter = -1;
  // In-loop certification bookkeeping, so its cost is reported apart from the
  // optimisation's and a timing produced with it on is not silently inflated.
  double cert_wall_inloop = 0.0;
  long long cert_calls_inloop = 0;
  double margin_stop_hit = 0.0;
  int margin_stop_iter = -1;
  bool wall_cap_hit = false;

  // The previous iterate's displacement field, for --warm-start.
  FeaSolution warm;
  bool have_warm = false;

  // ★ PROBE 1 — WARM START, AND WHERE IT IS ACTUALLY HONOURED. `simp_compliance`
  // has taken an `initial_guess` since it was written, and core ALSO has a
  // `PenalizedSolver` whose header says it "warm-starts from the previous solve
  // automatically". Neither reaches the solver this project runs:
  // `simp.cpp` dispatches MultigridCG_Matfree FIRST and that branch takes
  // neither argument. So a --warm-start measured on the production path is
  // exactly a no-op — which is what it measured, to the digit, over six
  // iterations — and the honest test is to run the paths that DO honour it and
  // report what warm starting is worth, so the value of wiring it into the
  // matrix-free solver is a number rather than a hope.
  const SolverKind solver_now =
      a.solver_kind < 0 ? options.simp.solver
                        : static_cast<SolverKind>(a.solver_kind);
  std::unique_ptr<PenalizedSolver> pen_solver;
  if (a.penalized_solver) {
    pen_solver = std::make_unique<PenalizedSolver>(grid, traj_params.poisson,
                                                   bcs, loads);
    std::printf("PROBE       PenalizedSolver constructed, usable = %s\n",
                pen_solver->usable() ? "yes" : "NO");
  }
  if (a.solver_kind >= 0 || a.cg_tol_early > 0.0 || a.warm_start)
    std::printf("PROBE       solver kind %d, warm start %s, early tol %.3g for "
                "%d iterations\n",
                static_cast<int>(solver_now), a.warm_start ? "ON" : "off",
                a.cg_tol_early, a.cg_tol_until);

  // ══ ★ --alpha: READ A DESIGN'S COEFFICIENTS BACK IN ══════════════════════
  //
  // `plsm_probe` has had this since PR 326 and this file has not, so every
  // question about a FINISHED design had to be answered by re-running the
  // optimiser that produced it. The two report modes below are exactly such
  // questions — S1(a)'s k-convergence and R4's finite difference are both
  // statements about ONE design — and asking them of a converged arm costs
  // nothing this way and an hour the other.
  if (!a.alpha_in.empty()) {
    if (!a.plsm) {
      std::printf("FATAL: --alpha needs --plsm; there are no coefficients "
                  "otherwise\n");
      return 2;
    }
    std::ifstream ain(a.alpha_in + ".f64", std::ios::binary);
    if (!ain) {
      std::printf("FATAL: cannot read %s.f64\n", a.alpha_in.c_str());
      return 2;
    }
    std::vector<double> ain_v(L.count(), 0.0);
    ain.read(reinterpret_cast<char*>(ain_v.data()),
             static_cast<std::streamsize>(ain_v.size() * sizeof(double)));
    // ★ THE COUNT IS CHECKED, NOT ASSUMED. A coefficient file from a different
    // knot spacing would load silently, fit nothing, and produce a plausible
    // table. It is exactly the shape of failure R2 exists to prevent.
    if (static_cast<std::size_t>(ain.gcount()) != ain_v.size() * sizeof(double)) {
      std::printf("FATAL: %s.f64 is %lld bytes; this knot lattice (%d x %d x %d)\n"
                  "       needs %zu. The coefficients are not this basis's.\n",
                  a.alpha_in.c_str(), static_cast<long long>(ain.gcount()), L.mx,
                  L.my, L.mz, ain_v.size() * sizeof(double));
      return 2;
    }
    alpha = ain_v;
    plsm_sync();
    std::printf("ALPHA       %zu coefficients read from %s.f64 — the seed fit "
                "above is DISCARDED\n", alpha.size(), a.alpha_in.c_str());
  }

  // ══ ★ S1(a) — THE k-CONVERGENCE REPORT ═══════════════════════════════════
  //
  // The fraction against k = 2, 4 and 8 on ONE fixed design, so the sub-sampling
  // error and its cost are a measurement rather than a choice. Nothing is
  // optimised here.
  if (a.frac_kreport) {
    const int ks[3] = {2, 4, 8};
    std::vector<double> f[3];
    double wall[3] = {0.0, 0.0, 0.0};
    std::size_t cut[3] = {0, 0, 0};
    std::printf("\n══ THE FRACTION AGAINST k ══════════════════════════════════\n");
    for (int q = 0; q < 3; ++q) {
      FracCache C;
      frac_build(d, L, pbasis, alpha, frac_sample, ks[q], plsm_threads, C);
      wall[q] = C.build_s;
      cut[q] = C.n_boundary;
      f[q].assign(n, 0.0);
      for (std::size_t v = 0; v < n; ++v)
        if (frac_sample[v]) f[q][v] = frac_of(C, v);
      double sum = 0.0;
      for (std::size_t v = 0; v < n; ++v) sum += f[q][v];
      std::printf("k = %-2d  %8zu cut cells of %8zu sampled   sum f_v = %14.6f"
                  "   %.3f s\n",
                  ks[q], C.n_boundary, C.ncell, sum, C.build_s);
    }
    std::printf("\n  differences, over the CUT cells only (an uncut cell is 0 or "
                "1 at every k):\n");
    for (int q = 1; q < 3; ++q) {
      double s2 = 0.0, mx = 0.0, dsum = 0.0;
      std::size_t cnt = 0;
      for (std::size_t v = 0; v < n; ++v) {
        if (!frac_sample[v]) continue;
        const double e = f[q][v] - f[q - 1][v];
        dsum += e;
        if (f[q][v] > 0.0 && f[q][v] < 1.0) { s2 += e * e; mx = std::max(mx, std::fabs(e)); ++cnt; }
      }
      std::printf("  k=%d against k=%d: rms %.6f, max %.6f over %zu cells; "
                  "sum f_v moves %+.4f voxels (%.4f%% of the part)\n",
                  ks[q], ks[q - 1], cnt ? std::sqrt(s2 / static_cast<double>(cnt)) : 0.0,
                  mx, cnt, dsum, 100.0 * dsum / target_volume);
    }
    std::printf("\n  cut cells: %zu / %zu / %zu at k = 2 / 4 / 8; "
                "build %.3f / %.3f / %.3f s\n",
                cut[0], cut[1], cut[2], wall[0], wall[1], wall[2]);
    std::ofstream kc(a.out + "/frac_kreport.csv");
    kc.precision(12);
    kc << "k,cut_cells,sampled_cells,sum_f,build_s\n";
    for (int q = 0; q < 3; ++q) {
      double sum = 0.0;
      for (std::size_t v = 0; v < n; ++v) sum += f[q][v];
      kc << ks[q] << ',' << cut[q] << ',' << fcache.ncell << ',' << sum << ','
         << wall[q] << '\n';
    }
    std::printf("wrote %s/frac_kreport.csv\n", a.out.c_str());
  }

  // ══ ★ R4 — THE SENSITIVITY AGAINST A FINITE DIFFERENCE ═══════════════════
  //
  // ★ A WRONG GRADIENT HERE IS THE SINGLE MOST LIKELY WAY THIS RUN IS WASTED,
  // and it would not announce itself: a mismatched derivative converges, just
  // slowly and to somewhere else. So both sensitivities MMA consumes are
  // differenced against the functions they claim to be derivatives of.
  //
  //   dV/dalpha  V(alpha) = SUM over ACTIVE cells of f_v. No state solve.
  //   dC/dalpha  C(alpha) = the compliance of the ersatz. Two state solves per
  //              probe direction, which is why N is small.
  //
  // ★ THE SIGN CONVENTION, WRITTEN OUT SO IT CANNOT BE THE BUG. MMA's design is
  // beta = -alpha, so `dv` and `dc` are derivatives with respect to BETA:
  //     dV/dalpha_i = -dv_i
  //     dC/dalpha_i = -(1 - rho_min) * E0 * dc_i
  // the second because `energy_from` un-does the SIMP interpolation, so
  // dC/drho_v = -e_v * E0 and drho_v/dalpha_i = (1-rho_min) * df_v/dalpha_i.
  //
  // ★ AND THE STEP SIZE IS SWEPT RATHER THAN CHOSEN, because the HARD-sampled
  // fraction is PIECEWISE CONSTANT in alpha: it jumps by 1/k^3 as each sample
  // crosses. A step too small differences a flat, a step too large leaves the
  // linear regime, and the plateau between them is the answer. A single step
  // would have produced one number and no way to know which of the three it was.
  // `--frac-soft` has no staircase and its plateau should reach machine
  // precision; that difference IS the measurement.
  if (a.frac_fd > 0) {
    // The design as it stands, on the constraint surface, exactly as an
    // iteration would see it.
    const double off0 = solve_offset(target_volume);
    for (double& c : alpha) c += off0;
    plsm_sync();
    frac_refresh();
    build_fields(0.0);

    // V and C, and the analytic gradients of both, at this point.
    auto volume_functional = [&]() {
      double s = 0.0;
      for (std::size_t v = 0; v < n; ++v) {
        if (!frac_sample[v]) continue;
        s += frac_on ? (a.frac_soft
                            ? frac_of_soft(fcache, v,
                                           frac_eps(frac_gm[v], h, a.frac, a.frac_eps))
                            : frac_of(fcache, v))
                     : heaviside(-phi[v], eta);
      }
      return s;
    };
    auto compliance_now = [&]() {
      const SimpCompliance s =
          simp_compliance(grid, traj_params, rho, bcs, loads,
                          options.simp.cg_tolerance,
                          options.simp.cg_max_iterations, nullptr,
                          pen_solver.get(), solver_now);
      return s;
    };

    const SimpCompliance sc0 = compliance_now();
    const double V0 = volume_functional();

    // The band and the two projections, built exactly as the loop builds them.
    if (frac_on) frac_band(fcache, frac_gm, h, a.frac_eps, dfrac, plsm_threads);
    std::vector<double> dlt(n, 0.0), ev(n, 0.0);
    for (int k = 0; k < d.nz; ++k)
      for (int j = 0; j < d.ny; ++j)
        for (int i = 0; i < d.nx; ++i) {
          const std::size_t v = d.at(i, j, k);
          if (grid.tags[v] == VoxelTag::Empty || eff[v] != MaskValue::Active) continue;
          dlt[v] = frac_on ? dfrac[v]
                           : (dheaviside(phi[v], eta) > 0.0
                                  ? dheaviside(phi[v], eta) *
                                        grad_mag(d, phi, i, j, k, h)
                                  : 0.0);
          ev[v] = energy_from(sc0.dcompliance[v], rho[v], traj_params.penalty,
                              traj_params.youngs_modulus);
        }
    std::vector<double> dc(L.count(), 0.0), dv(L.count(), 0.0);
    if (frac_on && a.frac_sens == "exact") {
      std::vector<double> wv(n, 0.0);
      for (std::size_t v = 0; v < n; ++v) wv[v] = dlt[v] > 0.0 ? 1.0 : 0.0;
      frac_scatter(fcache, d, L, pbasis, frac_gm, h, a.frac_eps, ev, dc, wv, dv,
                   plsm_threads);
    } else {
      std::vector<double> ed(n, 0.0);
      for (std::size_t v = 0; v < n; ++v) ed[v] = ev[v] * dlt[v];
      spmv(PsiT, ed, dc, plsm_threads);
      spmv(PsiT, dlt, dv, plsm_threads);
    }
    for (double& c : dc) c = -c;   // MMA's convention: material IN lowers C

    const double e0_mod = traj_params.youngs_modulus;
    auto pred_V = [&](const std::vector<double>& u) {
      double s = 0.0;
      for (std::size_t i2 = 0; i2 < L.count(); ++i2) s -= dv[i2] * u[i2];
      return s;
    };
    auto pred_C = [&](const std::vector<double>& u) {
      double s = 0.0;
      for (std::size_t i2 = 0; i2 < L.count(); ++i2) s -= dc[i2] * u[i2];
      return s * (1.0 - rho_min) * e0_mod;
    };

    const std::vector<double> alpha0 = alpha;
    // Perturb, WITHOUT re-solving the offset: the finite difference is of the
    // UNCONSTRAINED functions, which is what the gradients are gradients of.
    auto at = [&](const std::vector<double>& u, double s, bool want_c,
                  double& Vout, double& Cout) {
      for (std::size_t i2 = 0; i2 < L.count(); ++i2)
        alpha[i2] = alpha0[i2] + s * u[i2];
      plsm_sync();
      frac_refresh();
      build_fields(0.0);
      Vout = volume_functional();
      Cout = want_c ? compliance_now().compliance : 0.0;
    };

    std::ofstream fd(a.out + "/frac_fd.csv");
    fd.precision(12);
    fd << "kind,which,step,pred_dV,fd_dV,relerr_V,pred_dC,fd_dC,relerr_C\n";
    std::printf("\n══ R4 — THE SENSITIVITY AGAINST A CENTRAL DIFFERENCE ═══════\n");
    std::printf("design: %s ersatz, %s gradient, k = %d, eps_q mult %.3g\n",
                frac_on ? (a.frac_soft ? "MOLLIFIED FRACTION" : "EXACT FRACTION")
                        : "H_eta AT THE CELL CENTRE (PR 326's)",
                frac_on && a.frac_sens == "exact" ? "sample-scatter" : "Psi^T",
                a.frac, a.frac_eps);
    std::printf("C0 = %.12g   V0 = %.6f (active cells only)\n\n", sc0.compliance, V0);

    // ── (i) RANDOM DIRECTIONS. The cleanest check, because a direction that
    // touches every knot averages the staircase over ~10^4 cut cells.
    // ★ THE DIRECTIONS ARE DETERMINISTIC (a fixed LCG seeded per index), so this
    // report reproduces exactly. A random_device here would make R4 unrepeatable.
    const double steps[5] = {1e-3, 1e-2, 1e-1, 3e-1, 1.0};
    for (int r = 0; r < 2; ++r) {
      std::vector<double> u(L.count(), 0.0);
      unsigned long long st = 88172645463325252ULL + static_cast<unsigned long long>(r) * 7919ULL;
      double nrm = 0.0;
      for (std::size_t i2 = 0; i2 < L.count(); ++i2) {
        st ^= st << 13; st ^= st >> 7; st ^= st << 17;
        u[i2] = (static_cast<double>(st >> 11) * (1.0 / 9007199254740992.0)) - 0.5;
        nrm += u[i2] * u[i2];
      }
      nrm = std::sqrt(nrm / static_cast<double>(L.count()));
      for (double& x : u) x /= nrm;   // unit RMS, so a step is "mm of coefficient"
      const double pV = pred_V(u), pC = pred_C(u);
      for (double s : steps) {
        // ★ THE VOLUME DIFFERENCE IS FREE AND THE COMPLIANCE ONE COSTS TWO STATE
        // SOLVES, so the step sweep is run in full on the volume — which is the
        // sharper test, because it isolates d f_v / d alpha with no energy chain
        // in the way — and the compliance is differenced only where the volume
        // sweep says the linear regime is. Both are reported; neither is
        // extrapolated from the other.
        const bool want_c = (s == 1e-2 || s == 1e-1);
        double Vp, Cp, Vm, Cm;
        at(u, +s, want_c, Vp, Cp);
        at(u, -s, want_c, Vm, Cm);
        const double fV = (Vp - Vm) / (2.0 * s);
        const double fC = want_c ? (Cp - Cm) / (2.0 * s) : 0.0;
        const double rV = pV != 0.0 ? (fV - pV) / pV : 0.0;
        const double rC = (want_c && pC != 0.0) ? (fC - pC) / pC : 0.0;
        if (want_c)
          std::printf("random dir %d  step %8.3g   dV pred %14.6g  fd %14.6g  "
                      "rel %+9.3f%%   dC pred %13.6g  fd %13.6g  rel %+9.3f%%\n",
                      r, s, pV, fV, 100.0 * rV, pC, fC, 100.0 * rC);
        else
          std::printf("random dir %d  step %8.3g   dV pred %14.6g  fd %14.6g  "
                      "rel %+9.3f%%   (no state solve at this step)\n",
                      r, s, pV, fV, 100.0 * rV);
        fd << "random," << r << ',' << s << ',' << pV << ',' << fV << ',' << rV
           << ',' << (want_c ? pC : 0.0) << ',' << fC << ',' << rC << '\n';
        fd.flush();
      }
    }

    // ── (ii) SINGLE COEFFICIENTS, near the interface, where the derivative is
    // non-zero. The staircase is at its worst here — one coefficient moves only
    // the cells inside ONE support — and it is reported rather than avoided.
    std::vector<std::pair<double, std::size_t>> rank;
    for (std::size_t i2 = 0; i2 < L.count(); ++i2)
      rank.emplace_back(std::fabs(dv[i2]), i2);
    std::sort(rank.begin(), rank.end(),
              [](const std::pair<double, std::size_t>& x,
                 const std::pair<double, std::size_t>& y) { return x.first > y.first; });
    const int nfd = std::min<int>(a.frac_fd, static_cast<int>(rank.size()));
    for (int q = 0; q < nfd; ++q) {
      const std::size_t i2 = rank[static_cast<std::size_t>(q * 37 % std::max(1, nfd))].second;
      std::vector<double> u(L.count(), 0.0);
      u[i2] = 1.0;
      const double pV = pred_V(u), pC = pred_C(u);
      for (double s : {1e-2, 1e-1, 1.0}) {
        const bool want_c = (s == 1.0);   // one solve pair per coefficient
        double Vp, Cp, Vm, Cm;
        at(u, +s, want_c, Vp, Cp);
        at(u, -s, want_c, Vm, Cm);
        const double fV = (Vp - Vm) / (2.0 * s);
        const double fC = want_c ? (Cp - Cm) / (2.0 * s) : 0.0;
        const double rV = pV != 0.0 ? (fV - pV) / pV : 0.0;
        const double rC = (want_c && pC != 0.0) ? (fC - pC) / pC : 0.0;
        if (want_c)
          std::printf("coeff %6zu  step %8.3g   dV pred %14.6g  fd %14.6g  "
                      "rel %+9.3f%%   dC pred %13.6g  fd %13.6g  rel %+9.3f%%\n",
                      i2, s, pV, fV, 100.0 * rV, pC, fC, 100.0 * rC);
        else
          std::printf("coeff %6zu  step %8.3g   dV pred %14.6g  fd %14.6g  "
                      "rel %+9.3f%%   (no state solve at this step)\n",
                      i2, s, pV, fV, 100.0 * rV);
        fd << "coeff," << i2 << ',' << s << ',' << pV << ',' << fV << ',' << rV
           << ',' << (want_c ? pC : 0.0) << ',' << fC << ',' << rC << '\n';
        fd.flush();
      }
    }
    alpha = alpha0;
    plsm_sync();
    std::printf("\nwrote %s/frac_fd.csv\n", a.out.c_str());
  }
  // ══ ★ ARM 2 — WHAT THE SCALAR ERSATZ COSTS: THE ANISOTROPY, PRICED ═══════
  //
  // ★ THE PROBLEM. A partially-filled cell is genuinely ANISOTROPIC — stiffer
  // ALONG the material than ACROSS it — and a scalar volume fraction cannot
  // represent that. Using rho_e * K0 is the VOIGT (arithmetic) average, which is
  // the upper bound on the cell's stiffness in every direction, so a cut cell is
  // modelled STIFFER than it is, and most stiffly exactly across the cut, which
  // is where a thin member's boundary lies.
  //
  // ★ PR 320 PRICED THE CUT-CELL FAMILY AND REJECTED IT, and its architectural
  // objection stands: a per-element Ke takes storage from O(1) to O(cut cells)
  // and voids the Galerkin block cache. ★ BUT ITS *NUMERICAL* REASON NO LONGER
  // APPLIES — it found cut-cell pointless because the median cut fraction was
  // EXACTLY 0.5000, a half-voxel-shifted staircase with nothing fractional to
  // integrate. On a smooth analytic phi the cuts are genuinely fractional, and
  // the k-report above measures the distribution.
  //
  // ★ SO THIS PRICES THE CORRECTION WITHOUT BUILDING IT. For a cell cut by a
  // plane with normal n at fraction f, the exact two-phase construction with
  // uniform fields in each phase is the RANK-ONE LAMINATE: the strain differs
  // between the phases by a rank-one symmetric jump sym(a (x) n), fixed by
  // traction continuity across the interface. That is a 3x3 solve per cell —
  // NO 24x24 anything, no assembly, no element matrix.
  //
  //     eps1 = eps + (1-f) sym(a (x) n)        (the solid layer)
  //     eps0 = eps -    f  sym(a (x) n)        (the void layer)
  //     [(1-f) Q + f rho_min Q] a = -(1-rho_min) (C eps) . n
  //     Q_ik = C_ijkl n_j n_l = mu I + (lambda+mu) n (x) n   (isotropic)
  //
  // and the ratio W_laminate / W_voigt is exactly "how much strain energy the
  // scalar ersatz misplaces in this cell, under the strain it actually carries".
  // Summed over the cut cells and against the whole part, that is the number the
  // brief asks for: whether an anisotropic correction is worth having, and how
  // much of the compliance is at stake.
  //
  // ★ AND IT IS ALSO A MECHANISM, NOT ONLY A DIAGNOSTIC. The ratio is a per-cell
  // SCALAR. rho_e is ALREADY a per-cell scalar. So the correction rho_e ->
  // ratio * rho_e costs exactly nothing architecturally — no per-cell Ke, no
  // cache-key change, no stencil change. It is not the full anisotropy (a scalar
  // cannot be), but it is the part of it the compliance actually sees.
  if (a.frac_aniso) {
    const double off0 = solve_offset(target_volume);
    for (double& c : alpha) c += off0;
    plsm_sync();
    frac_refresh();
    build_fields(0.0);
    const SimpCompliance scA =
        simp_compliance(grid, traj_params, rho, bcs, loads,
                        options.simp.cg_tolerance, options.simp.cg_max_iterations,
                        nullptr, pen_solver.get(), solver_now);
    const double nu = traj_params.poisson;
    // Lame constants at E = 1: the strain is recovered with a UNIT modulus, so
    // rho never enters twice.
    const double lam = nu / ((1.0 + nu) * (1.0 - 2.0 * nu));
    const double mu = 1.0 / (2.0 * (1.0 + nu));
    std::ofstream ac(a.out + "/frac_aniso.csv");
    ac.precision(12);
    ac << "voxel,f,nx,ny,nz,W_voigt,W_lam,ratio\n";
    double sumW_voigt = 0.0, sumW_lam = 0.0, sumW_all = 0.0;
    std::size_t ncut = 0;
    // The ratio's distribution, in twenty buckets, so a mean cannot hide a tail.
    std::size_t hist[20] = {0};
    for (int k = 0; k < d.nz; ++k)
      for (int j = 0; j < d.ny; ++j)
        for (int i = 0; i < d.nx; ++i) {
          const std::size_t v = d.at(i, j, k);
          if (grid.tags[v] == VoxelTag::Empty) continue;
          // ── the element's 24 nodal displacements, in core's own ordering
          const int cx[8] = {0, 1, 1, 0, 0, 1, 1, 0};
          const int cy[8] = {0, 0, 1, 1, 0, 0, 1, 1};
          const int cz[8] = {0, 0, 0, 0, 1, 1, 1, 1};
          std::array<double, 24> ue{};
          for (int q = 0; q < 8; ++q) {
            const int nd = fea_node_index(grid, i + cx[q], j + cy[q], k + cz[q]);
            for (int c = 0; c < 3; ++c)
              ue[static_cast<std::size_t>(3 * q + c)] = scA.solution.at(nd, c);
          }
          // sigma = C(1, nu) : eps, so eps is recovered by the unit-modulus
          // compliance. `hex8_stress` is core's own recovery — INVOKED, not a
          // second B matrix in this file (R2).
          const Hex8Stress st = hex8_stress(1.0, nu, h, ue);
          const double sxx = st.sigma[0], syy = st.sigma[1], szz = st.sigma[2];
          const double txy = st.sigma[3], tyz = st.sigma[4], tzx = st.sigma[5];
          double e[3][3];
          e[0][0] = sxx - nu * (syy + szz);
          e[1][1] = syy - nu * (sxx + szz);
          e[2][2] = szz - nu * (sxx + syy);
          e[0][1] = e[1][0] = (1.0 + nu) * txy;
          e[1][2] = e[2][1] = (1.0 + nu) * tyz;
          e[2][0] = e[0][2] = (1.0 + nu) * tzx;
          const double tr = e[0][0] + e[1][1] + e[2][2];
          double ee = 0.0;
          for (int p = 0; p < 3; ++p)
            for (int q = 0; q < 3; ++q) ee += e[p][q] * e[p][q];
          const double W_solid = 0.5 * (lam * tr * tr + 2.0 * mu * ee);
          const double rho_v = rho[v];
          sumW_all += rho_v * W_solid;
          if (eff[v] != MaskValue::Active) continue;
          const double f = frac_on ? frac_of(fcache, v) : heaviside(-phi[v], eta);
          if (!(f > 0.0 && f < 1.0)) continue;   // not a cut cell
          // the interface normal, from the same phi everything else reads
          double gx = 0.0, gy = 0.0, gz = 0.0;
          {
            auto P = [&](int A, int B, int C) {
              A = std::min(std::max(A, 0), d.nx - 1);
              B = std::min(std::max(B, 0), d.ny - 1);
              C = std::min(std::max(C, 0), d.nz - 1);
              return phi[d.at(A, B, C)];
            };
            gx = (P(i + 1, j, k) - P(i - 1, j, k)) / (2.0 * h);
            gy = (P(i, j + 1, k) - P(i, j - 1, k)) / (2.0 * h);
            gz = (P(i, j, k + 1) - P(i, j, k - 1)) / (2.0 * h);
          }
          const double gn = std::sqrt(gx * gx + gy * gy + gz * gz);
          if (!(gn > 1e-12)) continue;
          const double nvec[3] = {gx / gn, gy / gn, gz / gn};
          // t = (C eps) . n
          double t[3];
          for (int p = 0; p < 3; ++p) {
            double s = lam * tr * nvec[p];
            for (int q = 0; q < 3; ++q) s += 2.0 * mu * e[p][q] * nvec[q];
            t[p] = s;
          }
          // a = -(1-rho_min)/[(1-f) + f rho_min] * Q^{-1} t,
          // Q^{-1} = (1/mu)[I - ((lambda+mu)/(lambda+2mu)) n (x) n]
          const double den = (1.0 - f) + f * rho_min;
          const double coef = -(1.0 - rho_min) / (den > 1e-300 ? den : 1e-300);
          const double tn = t[0] * nvec[0] + t[1] * nvec[1] + t[2] * nvec[2];
          double av[3];
          for (int p = 0; p < 3; ++p)
            av[p] = coef * (t[p] - ((lam + mu) / (lam + 2.0 * mu)) * tn * nvec[p]) / mu;
          double jump[3][3];
          for (int p = 0; p < 3; ++p)
            for (int q = 0; q < 3; ++q)
              jump[p][q] = 0.5 * (av[p] * nvec[q] + av[q] * nvec[p]);
          auto energy_of = [&](double scale) {
            double tr2 = 0.0, ee2 = 0.0;
            for (int p = 0; p < 3; ++p) {
              const double dpp = e[p][p] + scale * jump[p][p];
              tr2 += dpp;
            }
            for (int p = 0; p < 3; ++p)
              for (int q = 0; q < 3; ++q) {
                const double dpq = e[p][q] + scale * jump[p][q];
                ee2 += dpq * dpq;
              }
            return 0.5 * (lam * tr2 * tr2 + 2.0 * mu * ee2);
          };
          const double W_lam = f * energy_of(1.0 - f) +
                               (1.0 - f) * rho_min * energy_of(-f);
          const double W_voigt = rho_v * W_solid;
          const double ratio = W_voigt > 0.0 ? W_lam / W_voigt : 1.0;
          sumW_voigt += W_voigt;
          sumW_lam += W_lam;
          ++ncut;
          int b = static_cast<int>(ratio * 20.0);
          hist[std::min(19, std::max(0, b))]++;
          ac << v << ',' << f << ',' << nvec[0] << ',' << nvec[1] << ','
             << nvec[2] << ',' << W_voigt << ',' << W_lam << ',' << ratio << '\n';
        }
    std::printf("\n══ ARM 2 — THE ANISOTROPY OF A CUT CELL, PRICED ════════════\n");
    std::printf("cut cells                       %zu\n", ncut);
    std::printf("their strain energy, VOIGT      %.10g  (%.3f%% of the part's "
                "%.10g)\n", sumW_voigt,
                sumW_all > 0.0 ? 100.0 * sumW_voigt / sumW_all : 0.0, sumW_all);
    std::printf("their strain energy, LAMINATE   %.10g\n", sumW_lam);
    std::printf("★ the scalar ersatz over-stiffens the cut cells by %.2f%%, which "
                "is %.3f%%\n  of the whole part's strain energy\n",
                sumW_lam > 0.0 ? 100.0 * (sumW_voigt / sumW_lam - 1.0) : 0.0,
                sumW_all > 0.0 ? 100.0 * (sumW_voigt - sumW_lam) / sumW_all : 0.0);
    std::printf("\n  W_lam / W_voigt, by twentieths (1.00 = the scalar is exact, "
                "0 = it is all error):\n");
    for (int b = 0; b < 20; ++b)
      if (hist[b])
        std::printf("    %.2f - %.2f : %6zu\n", b * 0.05, (b + 1) * 0.05, hist[b]);
    std::printf("\nwrote %s/frac_aniso.csv\n", a.out.c_str());
  }

  if (a.frac_kreport || a.frac_fd > 0 || a.frac_aniso) return 0;

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
    // Which of the three robust designs the objective landed on this iteration,
    // and how much worse it is than the intermediate. 1 / 1.0 when --robust is
    // off, which is what the CSV then carries.
    int robust_worst = 1;
    double robust_ratio = 1.0;
    // How far the OBJECTIVE's surface sits from the printed one, in mm. Zero
    // unless --robust picked the eroded or dilated design; see the assignment.
    double delta_shift = 0.0;
    // The density field the SENSITIVITY belongs to. `energy_from` un-does the
    // SIMP interpolation to recover a strain energy density, so it must be given
    // the rho the dcompliance was computed on — which under --robust is the
    // argmax design, not the intermediate. Getting this wrong would silently
    // mis-scale the whole velocity, so it is a pointer with one assignment.
    const std::vector<double>* rho_sens = &rho;

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
    if (a.plsm) {
      // ★ IN --plsm MODE THE OFFSET IS ADDED TO EVERY COEFFICIENT, not to phi.
      // That keeps phi inside the span of the basis — the whole representation
      // claim would be void if the design carried a per-voxel term beside it —
      // and it moves the surface by offset * sum_i psi_i, which the header above
      // reports as a range so the reader can see how near a rigid move it is.
      for (double& c : alpha) c += offset;
      plsm_sync();
    } else {
      for (std::size_t v = 0; v < n; ++v) phi[v] += offset;
    }
    // ★ AND THE SUB-CELL SAMPLES ARE REBUILT HERE, after the fold and before the
    // ersatz, so the fraction, the printed occupancy, the band, the sensitivity
    // and the reinitialiser all refer to ONE surface — the same reason PR 323
    // folded the offset into phi in the first place.
    frac_refresh();
    build_fields(0.0);

    // ── THE STATE SOLVE. Core's, unmodified. ────────────────────────────────
    SimpCompliance sc;
    const double t_s0 = now_s();
    try {
      // ★ traj_params, not params — difference 2. At penalty 1 this is
      // E(rho) = rho * E0, their linear interpolation. The certificate below is
      // the only place `params` (penalty 3) is used, and it is untouched.
      // ★ PROBE 2 — INEXACT EARLY SOLVES. The literature reports up to 2.32x
      // from loosening the state solve while the design is still far from
      // converged. Nothing about this needs production to change: the tolerance
      // is already an argument, and the CERTIFICATION is a separate call that
      // keeps the production tolerance regardless. What has to be checked is
      // that the design it lands on is the same one, which is why every arm is
      // certified and measured, not just timed.
      const double tol_now =
          (a.cg_tol_early > 0.0 && it <= a.cg_tol_until) ? a.cg_tol_early
                                                        : options.simp.cg_tolerance;
      sc = simp_compliance(grid, traj_params, rho, bcs, loads, tol_now,
                           options.simp.cg_max_iterations,
                           (a.warm_start && have_warm) ? &warm : nullptr,
                           pen_solver.get(), solver_now);

      // ══ ARM 2 — THE ROBUST WORST-CASE OBJECTIVE (Sigmund 2009) ═══════════
      //
      // Two more state solves, on the ERODED and DILATED versions of the SAME
      // phi. Eroding by delta is `{phi < -delta}`, so the eroded rho is
      // `H_eta(-(phi + delta))` and the dilated is `H_eta(-(phi - delta))` —
      // one constant each, no filter, no projection, no second design variable.
      // The frozen classes are untouched in both, because frozen material is
      // not the optimiser's to erode.
      //
      // The objective becomes max(J_e, J_i, J_d) and its sensitivity is the
      // ARGMAX's — a valid subgradient of a max of smooth functions, and the
      // standard choice. `robust_worst` records which one won so the log can
      // say whether the erosion is actually binding or the flag is decoration.
      if (a.robust > 0.0) {
        const double dlt = a.robust * h;
        build_rho_shift(+dlt, rho_eroded);   // ERODED: phi + delta, smaller solid
        const SimpCompliance sc_e = simp_compliance(
            grid, traj_params, rho_eroded, bcs, loads, tol_now,
            options.simp.cg_max_iterations, nullptr, pen_solver.get(), solver_now);
        build_rho_shift(-dlt, rho_dilated);  // DILATED: phi - delta, larger solid
        const SimpCompliance sc_d = simp_compliance(
            grid, traj_params, rho_dilated, bcs, loads, tol_now,
            options.simp.cg_max_iterations, nullptr, pen_solver.get(), solver_now);
        solves_total += 2;
        if (sc_e.cg.used_multigrid) ++solves_multigrid;
        if (sc_d.cg.used_multigrid) ++solves_multigrid;
        // ★ WHICH DESIGN WINS IS RECORDED, NOT ASSUMED. The eroded one should
        // dominate — that is the whole mechanism — but "should" is how a flag
        // becomes decoration. `robust_worst` goes in the CSV every iteration, so
        // an arm where the erosion never binds is visible rather than inferred.
        robust_worst = 1;                       // 0 eroded / 1 intermediate / 2 dilated
        double worst = sc.compliance;
        if (sc_e.compliance > worst) { worst = sc_e.compliance; robust_worst = 0; }
        if (sc_d.compliance > worst) { worst = sc_d.compliance; robust_worst = 2; }
        robust_ratio = sc.compliance > 0.0 ? worst / sc.compliance : 1.0;
        if (robust_worst == 0) {
          sc.compliance = sc_e.compliance;
          sc.dcompliance = sc_e.dcompliance;
          rho_sens = &rho_eroded;
          // ★ AND THE SURFACE THE SENSITIVITY LIVES ON MOVES WITH IT. This is
          // the one line that decides whether the mechanism works at all, and
          // it was wrong in the first draft — caught by reading, before the arm
          // ever ran, which is the only reason it is not a table of nulls.
          //
          // The eroded design's boundary is {phi = -delta}, not {phi = 0}. Its
          // shape derivative is an integral OVER THAT SURFACE: the eroded and
          // intermediate surfaces are rigid offsets of one another, so a change
          // in phi moves both by the same normal amount, and the energy density
          // that multiplies it must be read where the eroded MATERIAL is.
          // Localising it with the intermediate's band instead samples the
          // eroded design at {phi = 0} — which is delta OUTSIDE its solid, in
          // its ersatz void, where the strain energy is ~rho_min noise. The arm
          // would have converged, reported "the robust formulation does
          // nothing", and been believed.
          delta_shift = +dlt;
        } else if (robust_worst == 2) {
          sc.compliance = sc_d.compliance;
          sc.dcompliance = sc_d.dcompliance;
          rho_sens = &rho_dilated;
          delta_shift = -dlt;
        }
      }
    } catch (const std::exception& e) {
      std::printf("\n*** STATE SOLVE FAILED at iteration %d: %s\n"
                  "*** Stopping here; everything already written stands.\n", it,
                  e.what());
      break;
    }
    const double solve_wall = now_s() - t_s0;
    if (a.warm_start) { warm = sc.solution; have_warm = true; }
    total_solve_wall += solve_wall;
    ++solves_total;
    if (sc.cg.used_multigrid) ++solves_multigrid;

    std::size_t printed = 0;
    for (std::size_t v = 0; v < n; ++v) if (occ[v] > 0.5) ++printed;
    const double occ_vol = volume_at(0.0);  // the offset is already IN phi

    // ★ S1's INVARIANT, CHECKED EVERY ITERATION RATHER THAN ARGUED ONCE. Under
    // `--volume-count` the constrained quantity IS the printed count, so the two
    // columns the PR 324 defect showed drifting apart must be the same number.
    // If they are not, the flag is not doing what this task claims it does and
    // the run must stop rather than produce a table.
    if (a.volume_count && occ_vol != static_cast<double>(printed)) {
      std::printf("\n*** FATAL at iteration %d: --volume-count is on but the\n"
                  "*** constrained volume %.10g != printed voxels %zu. The\n"
                  "*** constraint and the part have separated, which is exactly\n"
                  "*** the defect this flag exists to close.\n",
                  it, occ_vol, printed);
      return 3;
    }

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
    //
    // ══ ★ AND THIS IS WHERE THE SENSITIVITY FOLLOWS THE DENSITY ═════════════
    //
    // ★ S1(c). Leaving `DH_eta(phi)*|grad phi|` in place against a volume-
    // fraction density would be a MISMATCHED GRADIENT — it would look like slow
    // convergence and would be believed, and it is the single most likely way
    // this run is wasted. The fraction's derivative is a surface integral over
    // the part of the interface inside the cell, which the co-area formula turns
    // into a volume integral of a Dirac in phi:
    //
    //     d f_v / d alpha_i = -(1/|C|) INT_{Gamma cap C} psi_i / |grad phi| dS
    //                       = -(1/|C|) INT_C delta(phi) psi_i dx
    //                      ~= -(1/k^3) SUM_s delta_q(phi_s) psi_i(x_s)
    //
    // `dfrac[v]` is that sum WITHOUT psi — the per-cell factor the old `delta`
    // played — and it is what lambda is weighted by, what the perimeter term
    // rides and what the CSV's band column counts. ★ THE `|grad phi|` IS GONE
    // AND ITS ABSENCE IS THE CORRECTION: the old measure is `dS`, this one is
    // `dS/|grad phi|`, and the second is what the derivative of a VOLUME
    // fraction actually is. On a true signed distance they coincide; this phi
    // is not one (‖∇φ‖−1 runs 0.35–0.39 rms here, PR 326 P3), so the difference
    // is real and it is the reason the projection is a scatter and not Psi^T.
    if (frac_on) {
      const double t_fs = now_s();
      frac_band(fcache, frac_gm, h, a.frac_eps, dfrac, plsm_threads);
      frac_sens_s = now_s() - t_fs;
      // The interface AREA on this measure. `dfrac` integrates to dS/|grad phi|
      // by the co-area formula, so the area is the |grad phi|-weighted sum — the
      // same physical quantity `interface_area_mm2` reports on the old band, and
      // reported beside it rather than in place of it.
      frac_area = 0.0;
      for (std::size_t v = 0; v < n; ++v) frac_area += dfrac[v] * frac_gm[v];
      frac_area *= h * h * h;
    }
    std::size_t band_n = 0;
    for (int k = 0; k < d.nz; ++k)
      for (int j = 0; j < d.ny; ++j)
        for (int i = 0; i < d.nx; ++i) {
          const std::size_t v = d.at(i, j, k);
          if (grid.tags[v] == VoxelTag::Empty || eff[v] != MaskValue::Active) {
            delta[v] = 0.0;
            delta_obj[v] = 0.0;
            raw_vel[v] = 0.0;
            continue;
          }
          if (frac_on) {
            delta[v] = dfrac[v];
            delta_obj[v] = dfrac[v];   // --robust is refused under --frac
            if (delta[v] > 0.0) ++band_n;
            raw_vel[v] = energy_from(sc.dcompliance[v], (*rho_sens)[v],
                                     traj_params.penalty,
                                     traj_params.youngs_modulus);
            continue;
          }
          if (a.no_surface_delta) {
            // PR 322's measure: a VOLUME field over the whole active domain.
            delta[v] = 1.0;
            delta_obj[v] = 1.0;
          } else {
            const double gm = grad_mag(d, phi, i, j, k, h);
            const double dh = dheaviside(phi[v], eta);  // the offset is IN phi
            delta[v] = dh > 0.0 ? dh * gm : 0.0;
            // ★ THE OBJECTIVE'S BAND. Identical to `delta` unless --robust put
            // the worst case on the eroded or dilated design, whose interface
            // is {phi = -delta_shift}. Same |grad phi| — the two surfaces are a
            // rigid offset apart, so a change in phi moves them by the same
            // normal amount and only WHERE the energy is read changes.
            if (delta_shift == 0.0) {
              delta_obj[v] = delta[v];
            } else {
              const double dho = dheaviside(phi[v] + delta_shift, eta);
              delta_obj[v] = dho > 0.0 ? dho * gm : 0.0;
            }
          }
          if (delta[v] > 0.0) ++band_n;
          raw_vel[v] = energy_from(sc.dcompliance[v], (*rho_sens)[v],
                                   traj_params.penalty,
                                   traj_params.youngs_modulus);
        }

    // ★ LAMBDA UNDER THE SAME MEASURE. PR 322 used the mean energy over a flat
    // two-voxel band. Now that the descent is weighted by `delta`, the multiplier
    // that makes the flow volume-neutral to first order is the DELTA-WEIGHTED
    // mean — the unique lambda for which ∫ (e - lambda) * DH * |grad phi| = 0,
    // which is exactly the statement that dJ + lambda*dVol has no volume
    // component. The residual it leaves is what the offset bisection removes at
    // the top of the next iteration, so the two pieces still do not fight.
    // ★ THE NUMERATOR IS OVER delta_obj AND THE DENOMINATOR OVER delta, and the
    // two are the same vector unless --robust is on. lambda is the multiplier
    // that makes the flow volume-neutral to first order: the value for which
    // ∫ e*delta_obj - lambda*delta vanishes. The VOLUME term is a statement
    // about the printed part, so it is measured on the printed part's band; the
    // OBJECTIVE term is a statement about whichever design the worst case
    // landed on. With --robust off, delta_obj == delta and this is the identical
    // expression PR 324 ran — which `C0_control` checks to twelve digits.
    double wsum = 0.0, w = 0.0;
    for (std::size_t v = 0; v < n; ++v) {
      wsum += raw_vel[v] * delta_obj[v];
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
    //
    // ★ S3(b) — THE WEIGHT IS RAMPED, NOT FIXED, AND `perim_now` IS WHAT THE
    // CSV RECORDS. `--perimeter-ramp START,LEN` holds the weight at zero for
    // the first START iterations, ramps it linearly to `--perimeter` over the
    // next LEN, and holds it there. The default 0,0 makes `frac` 1 from
    // iteration 1, which is the fixed weight the flag replaced.
    double perim_now = a.perimeter;
    if (a.perimeter > 0.0 && (a.perimeter_ramp_start > 0 || a.perimeter_ramp_len > 0)) {
      const double over = static_cast<double>(it - a.perimeter_ramp_start);
      double frac;
      if (over <= 0.0) frac = 0.0;
      else if (a.perimeter_ramp_len <= 0) frac = 1.0;
      else frac = std::min(1.0, over / static_cast<double>(a.perimeter_ramp_len));
      perim_now = a.perimeter * frac;
    }
    double kappa_rms = 0.0;
    std::fill(pen.begin(), pen.end(), 0.0);
    if (perim_now > 0.0) {
      const double ell = perim_now * lambda * h;
      // ★ TWO PASSES, BECAUSE THE LOCAL WEIGHT NEEDS kappa_rms AND kappa_rms
      // NEEDS THE FIELD. Pass 1 builds the curvature field over the band and its
      // rms; pass 2 applies the term. With `--perimeter-local 0` pass 2 is
      // ell*kappa exactly, so the split changes no arithmetic — the fixed
      // penalty is bit-for-bit what PR 325 ran, and `C0_control` proves it.
      std::vector<double>& kfield = curv_field;   // reused across iterations
      double k2 = 0.0;
      std::size_t kn = 0;
      for (int k = 0; k < d.nz; ++k)
        for (int j = 0; j < d.ny; ++j)
          for (int i = 0; i < d.nx; ++i) {
            const std::size_t v = d.at(i, j, k);
            if (delta[v] <= 0.0) { kfield[v] = 0.0; continue; }
            const double kap = mean_curvature(d, phi, i, j, k, h);
            kfield[v] = kap;
            k2 += kap * kap;
            ++kn;
          }
      kappa_rms = kn ? std::sqrt(k2 / static_cast<double>(kn)) : 0.0;
      const double kref = kappa_rms > 0.0 ? kappa_rms : 1.0;
      for (int k = 0; k < d.nz; ++k)
        for (int j = 0; j < d.ny; ++j)
          for (int i = 0; i < d.nx; ++i) {
            const std::size_t v = d.at(i, j, k);
            if (delta[v] <= 0.0) continue;
            const double kap = kfield[v];
            // Per + (beta/kappa_rms^2) * Willmore, gradient, ∂_n kappa dropped.
            double term = kap;
            if (a.perimeter_local > 0.0) {
              const double kn2 = (kap / kref) * (kap / kref);
              term = kap * (1.0 + a.perimeter_local * kn2);
              if (a.willmore_full) {
                // ★ THE DROPPED TERM, PUT BACK SO THE OMISSION IS A NUMBER.
                // 2*kappa*(grad kappa . n) with n = grad phi / |grad phi|, by
                // central differences on `kfield`. Off the band kfield is zero,
                // so this is one-sided there by construction — which is correct:
                // outside the band the functional has no integrand.
                auto K = [&](int A, int B, int C) {
                  A = std::min(std::max(A, 0), d.nx - 1);
                  B = std::min(std::max(B, 0), d.ny - 1);
                  C = std::min(std::max(C, 0), d.nz - 1);
                  return kfield[d.at(A, B, C)];
                };
                auto P = [&](int A, int B, int C) {
                  A = std::min(std::max(A, 0), d.nx - 1);
                  B = std::min(std::max(B, 0), d.ny - 1);
                  C = std::min(std::max(C, 0), d.nz - 1);
                  return phi[d.at(A, B, C)];
                };
                const double kx = (K(i+1,j,k) - K(i-1,j,k)) / (2.0 * h);
                const double ky = (K(i,j+1,k) - K(i,j-1,k)) / (2.0 * h);
                const double kz = (K(i,j,k+1) - K(i,j,k-1)) / (2.0 * h);
                const double px = (P(i+1,j,k) - P(i-1,j,k)) / (2.0 * h);
                const double py = (P(i,j+1,k) - P(i,j-1,k)) / (2.0 * h);
                const double pz = (P(i,j,k+1) - P(i,j,k-1)) / (2.0 * h);
                const double gm = std::sqrt(px*px + py*py + pz*pz);
                if (gm > 1e-12) {
                  const double dnk = (kx*px + ky*py + kz*pz) / gm;
                  term += a.perimeter_local * 2.0 * kap * dnk / (kref * kref);
                }
              }
            }
            // ★ THE PENALTY IS HELD SEPARATELY FROM THE ENERGY, and under
            // --robust that is not bookkeeping. The energy belongs to whichever
            // design the worst case landed on and rides `delta_obj`; the
            // perimeter belongs to the PRINTED part — it is the area of the
            // thing that gets made — and rides `delta`. Folding the penalty
            // into `raw_vel` would put it on the eroded surface instead.
            pen[v] = ell * term;
          }
      // With --robust off the two bands coincide and this is the ORIGINAL
      // expression, grouped exactly as PR 325 grouped it, so the fixed-weight
      // penalty is bit-for-bit what that arm ran. The branch exists to keep
      // that true rather than to save arithmetic.
      double wsum2 = 0.0;
      if (delta_shift == 0.0) {
        for (std::size_t v = 0; v < n; ++v)
          wsum2 += (raw_vel[v] - pen[v]) * delta[v];
      } else {
        for (std::size_t v = 0; v < n; ++v)
          wsum2 += raw_vel[v] * delta_obj[v] - pen[v] * delta[v];
      }
      lambda = w > 0.0 ? wsum2 / w : 0.0;
    }

    for (std::size_t v = 0; v < n; ++v)
      raw_vel[v] = (delta_shift == 0.0)
                       ? (raw_vel[v] - pen[v] - lambda) * delta[v]
                       : raw_vel[v] * delta_obj[v] - (pen[v] + lambda) * delta[v];

    // ── (d) + (4) THE VELOCITY EXTENSION ────────────────────────────────────
    int hilb_it = 0;
    double hilb_rel = 0.0;
    const double t_h0 = now_s();
    if (a.plsm && !a.plsm_hilb) {
      // ★ ARM 2 DELETES DIFFERENCE 4, AND THE LITERATURE SAYS WHY. The step
      // below is alpha <- alpha - dt * Psi^T v, so the motion of phi is
      // Psi Psi^T v — the velocity spread over every knot whose support the
      // interface passes through, which is a positive semi-definite smoothing of
      // v and therefore still a descent direction. Gao et al. state it directly
      // of the parametric form: the velocity "is naturally extended to the whole
      // design domain, and there is no need to employ additional schemes to
      // extend the velocity field." `--plsm-hilb` puts the Hilbertian solve back
      // so the claim is ABLATABLE rather than believed.
      vel = raw_vel;
    } else if (a.alpha_coeff > 0.0) {
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
    if (a.plsm) {
      // ══ ARM 2: THE COEFFICIENT UPDATE ═══════════════════════════════════
      //
      // The chain rule the task states, and nothing else:
      //
      //     dJ/dalpha_i = integral (C:eps(u):eps(u)) psi_i DH_eta(phi) |grad phi|
      //     dV/dalpha_i = integral            -1     psi_i DH_eta(phi) |grad phi|
      //
      // Both carry the identical factor, which is exactly `delta` — the SAME
      // `delta` the voxel arms built two blocks up, unchanged. So the two
      // sensitivities differ only in replacing the energy by a constant, the
      // multiplier lambda is the delta-weighted mean that was already computed,
      // and `raw_vel` = (e - lambda) * delta IS the combined shape derivative in
      // phi-space. Projecting it onto the basis is one transpose apply.
      std::vector<double> g(L.count(), 0.0);
      spmv(PsiT, vel, g, plsm_threads);

      // ── ★ THE NUCLEATION BAND. Which coefficients are allowed to move. ─────
      //
      // `phi` at the knot's own centre, trilinearly off the grid it was just
      // synced onto, clamped at the faces because the lattice is padded by a
      // full ring of knots that sit OUTSIDE the domain (`make_lattice`).
      //
      // ★ |phi| IS USED AS THE DISTANCE AND THAT IS APPROXIMATE, SAID PLAINLY.
      // phi here is not a signed distance — | |grad phi| - 1 | runs about 0.35
      // to 0.43 rms — so W is a distance only up to that factor. It is a knob
      // to sweep, not a length to trust, and the CSV records how many
      // coefficients it actually froze so the setting is legible after the fact.
      if (a.nucleation_band > 0.0) {
        const double wmm = a.nucleation_band * h;
        auto phi_at = [&](double x, double y, double z) {
          x = std::min(std::max(x, 0.0), static_cast<double>(d.nx - 1));
          y = std::min(std::max(y, 0.0), static_cast<double>(d.ny - 1));
          z = std::min(std::max(z, 0.0), static_cast<double>(d.nz - 1));
          const int i0 = static_cast<int>(x), j0 = static_cast<int>(y),
                    k0 = static_cast<int>(z);
          const int i1 = std::min(i0 + 1, d.nx - 1),
                    j1 = std::min(j0 + 1, d.ny - 1),
                    k1 = std::min(k0 + 1, d.nz - 1);
          const double fx = x - i0, fy = y - j0, fz = z - k0;
          double acc = 0.0;
          for (int dk = 0; dk < 2; ++dk)
            for (int dj = 0; dj < 2; ++dj)
              for (int di = 0; di < 2; ++di) {
                const double w3 = (di ? fx : 1.0 - fx) * (dj ? fy : 1.0 - fy) *
                                  (dk ? fz : 1.0 - fz);
                acc += w3 * phi[d.at(di ? i1 : i0, dj ? j1 : j0, dk ? k1 : k0)];
              }
          return acc;
        };
        nuc_frozen = 0;
        for (int c = 0; c < L.mz; ++c)
          for (int b = 0; b < L.my; ++b)
            for (int aa = 0; aa < L.mx; ++aa) {
              const std::size_t i2 = L.at(aa, b, c);
              nuc_mask[i2] =
                  std::fabs(phi_at(L.ux(aa), L.uy(b), L.uz(c))) <= wmm ? 1 : 0;
              if (!nuc_mask[i2]) ++nuc_frozen;
            }
        for (std::size_t i2 = 0; i2 < L.count(); ++i2)
          if (!nuc_mask[i2]) g[i2] = 0.0;
      }

      if (a.plsm_lbfgs > 0) {
        // ══ PROBE 3 — L-BFGS ON THE COEFFICIENTS ═══════════════════════════
        //
        // ★ THIS LEVER EXISTS ONLY BECAUSE THE REPRESENTATION IS PARAMETRIC.
        // A voxel level set has 468,224 design variables and a second-order
        // method is out of the question; the coefficients are 85,680 at the
        // finest lattice here and 3,040 at the coarsest that still fits, which
        // is small enough to carry curvature. If it halves the ITERATION COUNT
        // it halves the wall clock, because 99.5% of an iteration is one state
        // solve and L-BFGS needs exactly one per iteration too.
        //
        // Limited-memory BFGS, two-loop recursion, on the same descent
        // direction MMA is given: g = Psi^T v with v = (e - lambda) * delta, so
        // the volume multiplier is already folded in and the constraint is held
        // by the SAME offset bisection every other arm uses. That keeps this a
        // test of the SEARCH DIRECTION and nothing else.
        lb_s.push_back(std::vector<double>());   // filled after the step
        lb_y.push_back(std::vector<double>());
        std::vector<double> q = g;
        const int m = static_cast<int>(lb_hist_s.size());
        std::vector<double> al(static_cast<std::size_t>(m), 0.0);
        for (int kk = m - 1; kk >= 0; --kk) {
          const auto& sv = lb_hist_s[static_cast<std::size_t>(kk)];
          const auto& yv = lb_hist_y[static_cast<std::size_t>(kk)];
          double sy = 0.0, sq = 0.0;
          for (std::size_t i2 = 0; i2 < sv.size(); ++i2) { sy += sv[i2]*yv[i2]; sq += sv[i2]*q[i2]; }
          if (std::fabs(sy) < 1e-300) continue;
          al[static_cast<std::size_t>(kk)] = sq / sy;
          for (std::size_t i2 = 0; i2 < sv.size(); ++i2) q[i2] -= al[static_cast<std::size_t>(kk)] * yv[i2];
        }
        if (m > 0) {
          const auto& sv = lb_hist_s.back();
          const auto& yv = lb_hist_y.back();
          double sy = 0.0, yy = 0.0;
          for (std::size_t i2 = 0; i2 < sv.size(); ++i2) { sy += sv[i2]*yv[i2]; yy += yv[i2]*yv[i2]; }
          const double gamma_bfgs = (yy > 0.0) ? sy / yy : 1.0;
          for (double& v2 : q) v2 *= gamma_bfgs;
        }
        for (int kk = 0; kk < m; ++kk) {
          const auto& sv = lb_hist_s[static_cast<std::size_t>(kk)];
          const auto& yv = lb_hist_y[static_cast<std::size_t>(kk)];
          double sy = 0.0, yq = 0.0;
          for (std::size_t i2 = 0; i2 < sv.size(); ++i2) { sy += sv[i2]*yv[i2]; yq += yv[i2]*q[i2]; }
          if (std::fabs(sy) < 1e-300) continue;
          const double beta_bfgs = yq / sy;
          for (std::size_t i2 = 0; i2 < sv.size(); ++i2)
            q[i2] += (al[static_cast<std::size_t>(kk)] - beta_bfgs) * sv[i2];
        }
        lb_s.pop_back(); lb_y.pop_back();
        // The SAME step normalisation the descent branch uses, so the two are
        // comparable and the only difference is the direction.
        std::vector<double> pfield(n, 0.0);
        spmv(Psi, q, pfield, plsm_threads);
        double smax2 = 0.0;
        for (int k = 0; k < d.nz; ++k)
          for (int j = 0; j < d.ny; ++j)
            for (int i = 0; i < d.nx; ++i) {
              const std::size_t v = d.at(i, j, k);
              if (delta[v] <= 0.0) continue;
              const double gm = grad_mag(d, phi, i, j, k, h);
              if (gm > 1e-12) smax2 = std::max(smax2, std::fabs(pfield[v]) / gm);
            }
        if (smax2 > 0.0) {
          const int steps = a.hj_steps > 0 ? a.hj_steps : 1;
          dt = gamma_now * steps * h / smax2;
          std::vector<double> step(L.count());
          for (std::size_t i2 = 0; i2 < L.count(); ++i2) {
            step[i2] = -dt * q[i2];
            alpha[i2] += step[i2];
          }
          if (!lb_prev_g.empty()) {
            std::vector<double> yv(L.count());
            for (std::size_t i2 = 0; i2 < L.count(); ++i2) yv[i2] = g[i2] - lb_prev_g[i2];
            lb_hist_s.push_back(lb_prev_step);
            lb_hist_y.push_back(yv);
            while (static_cast<int>(lb_hist_s.size()) > a.plsm_lbfgs) {
              lb_hist_s.erase(lb_hist_s.begin());
              lb_hist_y.erase(lb_hist_y.begin());
            }
          }
          lb_prev_step = step;
          lb_prev_g = g;
          hj_done = steps;
        }
      } else if (a.plsm_mma) {
        // ── MMA on the coefficients (plsm_mma.hpp — core's mma_update step for
        // step, with the design set changed). beta = -alpha so that "design up"
        // means "material in", which is the sign convention core's MMA assumes.
        //
        // dc and dv are recovered from `raw_vel` without a second pass: at this
        // point raw_vel = (e - lambda) * delta, so e * delta = raw_vel +
        // lambda * delta exactly.
        std::vector<double> edelta(n, 0.0);
        for (std::size_t v = 0; v < n; ++v) edelta[v] = raw_vel[v] + lambda * delta[v];
        std::vector<double> dc(L.count(), 0.0), dv(L.count(), 0.0);
        if (frac_on && a.frac_sens == "exact") {
          // ★ THE SCATTER. `Psi^T` evaluates psi_i at the CELL CENTRE and factors
          // it out of the sub-cell sum; the fraction's derivative has psi_i
          // INSIDE that sum, at the samples. The two weights ride the same
          // measure — the identity the whole level-set formulation rests on — so
          // one pass over the samples produces both.
          //
          // `edelta` and `delta` already carry the per-cell factor `dfrac`, and
          // the scatter recomputes delta_q itself, so the weights handed over are
          // the ENERGY-like ones with dfrac divided back out. Cells where dfrac
          // is zero contribute nothing either way.
          const double t_fs = now_s();
          std::vector<double> wc(n, 0.0), wv(n, 0.0);
          for (std::size_t v = 0; v < n; ++v) {
            if (!(delta[v] > 0.0)) continue;
            wc[v] = edelta[v] / delta[v];   // = e_v - pen_v
            wv[v] = 1.0;
          }
          frac_scatter(fcache, d, L, pbasis, frac_gm, h, a.frac_eps, wc, dc, wv,
                       dv, plsm_threads);
          frac_sens_s += now_s() - t_fs;
        } else {
          spmv(PsiT, edelta, dc, plsm_threads);
          spmv(PsiT, delta, dv, plsm_threads);
        }
        for (double& c : dc) c = -c;   // material IN lowers compliance
        // ★ THE SAME RESTRICTION, ON THE SENSITIVITIES MMA ACTUALLY READS. `g`
        // above drives the descent branch; MMA is handed dc and dv separately,
        // so masking only `g` would leave this branch unrestricted — which is
        // the shape of bug PR 324 §9 caught, a flag that silently does nothing.
        if (a.nucleation_band > 0.0)
          for (std::size_t i2 = 0; i2 < L.count(); ++i2)
            if (!nuc_mask[i2]) { dc[i2] = 0.0; dv[i2] = 0.0; }
        std::vector<double> beta(L.count(), 0.0);
        for (std::size_t i2 = 0; i2 < L.count(); ++i2) beta[i2] = -alpha[i2];
        // g0 is the constraint residual. The offset bisection at the top of this
        // iteration has already driven it to ~0, so MMA is optimising ON the
        // constraint surface and its multiplier sets the trade-off within the
        // step; the bisection then re-projects at the top of the next one. The
        // two do not fight: one is a projection, the other a search direction.
        const double g0 = occ_vol - target_volume;
        // ★ THE MOVE LIMIT IS A LENGTH, NOT A FRACTION, AND THE FIRST MMA RUN IS
        // WHY. Core's MMA takes `move` as a fraction of the design range because
        // its design range is [rho_min, 1] — a fraction of it is a density step
        // and means something. An RBF coefficient's range is set by the SEED and
        // is ~1365 mm wide on this part, so the inherited default of 0.05 is a
        // 68 mm step per coefficient per iteration. Measured: compliance went
        // 0.00287 -> 0.00848 in ONE iteration and | |grad phi|-1 | reached 86.
        //
        // So the fraction is DERIVED from the motion a step is meant to buy — the
        // same gamma * hj_steps * h the descent branch uses — divided by how far a
        // unit coefficient move carries phi, which is max_i sum psi (`psi_max`).
        // `--plsm-move` then multiplies that, defaulting to 1, so the flag means
        // "how many voxel-arm steps' worth" rather than a number with no scale.
        const int steps = a.hj_steps > 0 ? a.hj_steps : 1;
        const double want_dphi = gamma_now * steps * h;
        const double xrange = 2.0 * plsm_alpha_bound;
        const double mv = a.plsm_move * want_dphi / (xrange * plsm_psi_max);
        const std::vector<double> beta_before = beta;
        beta = plsm_mma_update(mma_state, ++plsm_mma_iter, beta, dc, dv, g0,
                               -plsm_alpha_bound, plsm_alpha_bound, mv);
        // ★ HELD EXACTLY, not left to the regulariser. With dc = dv = 0 the MMA
        // minimiser lands back on x only up to its raa0 term and its asymptote
        // asymmetry; restoring the value makes "frozen" mean frozen.
        if (a.nucleation_band > 0.0)
          for (std::size_t i2 = 0; i2 < L.count(); ++i2)
            if (!nuc_mask[i2]) beta[i2] = beta_before[i2];
        for (std::size_t i2 = 0; i2 < L.count(); ++i2) alpha[i2] = -beta[i2];
        dt = mv * xrange;   // the coefficient move limit actually applied, in mm
        hj_done = steps;
      } else {
        // ── Steepest descent in the coefficients, with the SAME step rule the
        // voxel arms use: the largest movement of phi anywhere is gamma * h. In
        // the voxel arms that is dt = gamma*h/max|v| because |grad phi| = 1; here
        // the step moves phi by -dt * Psi Psi^T v, so the normalisation is taken
        // on THAT field and the two arms take comparable-sized steps.
        std::vector<double> q(n, 0.0);
        spmv(Psi, g, q, plsm_threads);
        // ★ THE STEP IS NORMALISED ON INTERFACE DISPLACEMENT, NOT ON |Delta phi|,
        // AND THE FIRST SMOKE RUN IS WHY. The voxel arms move the interface by
        // gamma*h per Hamilton-Jacobi sub-step and take `hj_steps` of them on one
        // state solve, so a state solve buys hj_steps*gamma*h of motion. Sizing
        // the parametric step by max|Delta phi| instead gave one sub-step's worth
        // and the objective fell about a third as fast per solve — which would
        // have been reported as "the parametric arm converges slowly" when it was
        // only taking a smaller step.
        //
        // A level set moves its interface by Delta phi / |grad phi|, and the
        // parametric phi is NOT a distance function (|grad phi| - 1 measured 0.32
        // on the seed, and there is no reinitialisation to fix it), so the
        // division is not optional here the way it is in the voxel arms. It is
        // taken over the BAND only: outside it Delta phi moves no surface, and
        // |grad phi| there can be small enough to dominate a maximum meaninglessly.
        double smax = 0.0;
        for (int k = 0; k < d.nz; ++k)
          for (int j = 0; j < d.ny; ++j)
            for (int i = 0; i < d.nx; ++i) {
              const std::size_t v = d.at(i, j, k);
              if (delta[v] <= 0.0) continue;
              const double gm = grad_mag(d, phi, i, j, k, h);
              if (gm <= 1e-12) continue;
              smax = std::max(smax, std::fabs(q[v]) / gm);
            }
        if (smax > 0.0) {
          const int steps = a.hj_steps > 0 ? a.hj_steps : 1;
          dt = gamma_now * steps * h / smax;
          for (std::size_t i2 = 0; i2 < L.count(); ++i2) alpha[i2] -= dt * g[i2];
          hj_done = steps;   // the motion this step is worth, for the CSV
        }
      }
      plsm_sync();
      hj_done = 0;
    } else if (vmax > 0.0 && a.hj_steps > 0) {
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
    if (a.plsm) {
      // ★ NO REINITIALISATION, AND THE RESIDUAL IS REPORTED ANYWAY. The claim
      // being tested is that a parametric level set does not need one; the honest
      // way to test it is to keep measuring | |grad phi| - 1 | and let the number
      // say whether phi drifts. `--plsm-refit-every N` is the literature's
      // "approximate re-initialisation": re-distance phi ON THE GRID and then
      // RE-PROJECT it onto the basis, so the design variable stays the
      // coefficients. OFF by default.
      if (a.plsm_refit_every > 0 && it % a.plsm_refit_every == 0) {
        std::vector<double> pr = phi;
        reinitialise(d, pr, h, a.sweeps, false);
        std::vector<double> tgt(n, 0.0), wts(n, 1.0);
        for (std::size_t v = 0; v < n; ++v)
          tgt[v] = std::max(-a.plsm_clamp * h, std::min(a.plsm_clamp * h, pr[v]));
        const FitResult rf = solve_normal(Psi, PsiT, tgt, wts, a.plsm_ridge,
                                          a.plsm_cg_iters, 1e-10, plsm_threads);
        alpha = rf.alpha;
        plsm_sync();
      }
      rresid = reinit_residual(d, phi, h, eta);
      last_rresid = rresid;
    } else if (a.reinit_every > 0 && it % a.reinit_every == 0) {
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
        << ',' << gamma_now << ',' << kappa_rms << ',' << perim_now << ','
        << (w * h * h * h) << ',' << robust_worst << ',' << robust_ratio << ','
        << nuc_frozen << ',' << frac_boundary << ',' << frac_area << ','
        << (frac_build_s * 1000.0) << ',' << (frac_sens_s * 1000.0) << ','
        << it_wall << '\n';
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

    // ── ★ THE MARGIN-AWARE STOP, AND THE WALL CAP ──────────────────────────
    //
    // The certification is `analyze_fixed_design` at the PRODUCTION penalty on
    // the CURRENT design, with recycling / GenEO / mixed precision disarmed —
    // the same isolation a re-certification uses — and RE-ARMED immediately
    // afterwards. ★ Re-arming is not tidiness: leaving the posture disarmed
    // would change every state solve after the first certification, so an arm
    // measured this way would not be the arm without it.
    if (a.certify_every > 0 && it >= a.certify_from && it % a.certify_every == 0) {
      const double t_c0 = now_s();
      std::vector<double> crho(n, 0.0);
      for (std::size_t v = 0; v < n; ++v)
        crho[v] = params.density_min + (1.0 - params.density_min) * occ[v];
      fea_set_krylov_recycling(false);
      fea_set_geneo_twolevel(false);
      fea_set_matfree_mixed_precision(false);
      // ★ THE SAME CALL, WITH THE SAME ARGUMENTS, AS THE END-OF-RUN
      // CERTIFICATION BELOW — production tolerance, production solver,
      // production penalty. A stopping rule that certified on a cheaper path
      // than the certificate would stop on a number the certificate does not
      // agree with.
      const bool cok = load_path_connected(grid, crho, 0.5);
      double cm = 0.0;
      bool cacc = false;
      try {
        const FixedDesignAnalysis ca = analyze_fixed_design(
            grid, params, crho, bcs, loads, material, options.build_direction,
            options.simp.cg_tolerance, options.simp.cg_max_iterations,
            options.simp.solver, options.margin_stop, knockdown_spec_for(options),
            cok, part_solid);
        cm = ca.margin.worst_case;
        cacc = ca.accepted && !ca.non_convergent;
      } catch (const std::exception& e) {
        std::printf("   ↳ certification at iteration %d failed: %s\n", it, e.what());
      }
      fea_set_krylov_recycling(prev_recycle);
      fea_set_geneo_twolevel(prev_geneo);
      fea_set_matfree_mixed_precision(prev_mixed);
      cert_wall_inloop += now_s() - t_c0;
      ++cert_calls_inloop;
      std::printf("   ↳ certified at iteration %d: margin %.2f  %s  "
                  "(%.1f s, %.1f s of run so far is certification)\n",
                  it, cm, cacc ? "ACCEPTED" : "not accepted",
                  now_s() - t_c0, cert_wall_inloop);
      std::fflush(stdout);
      if (a.margin_stop > 0.0 && cm >= a.margin_stop && cacc) {
        // ★ AND THE DESIGN THAT MET THE BAR IS THE ONE THAT GETS CERTIFIED AND
        // WRITTEN, not the best-compliance iterate. Otherwise the summary would
        // report a different design from the one the stopping rule fired on —
        // which is exactly the mismatch that cost this task its first set of
        // tables (§2).
        best_occ = occ;
        best_rho = rho;
        best_iter = it;
        best_compliance = sc.compliance;
        margin_stop_hit = cm;
        margin_stop_iter = it;
        std::printf("\n★ STOPPING: certified margin %.2f reached the target "
                    "%.2f at iteration %d.\n", cm, a.margin_stop, it);
        done_iters = it;
        break;
      }
    }
    // ★ THE CAP EXCLUDES THE IN-LOOP CERTIFICATION, AND THE FIRST ATTEMPT AT
    // THIS RUN IS WHY. Certifying an UNCONVERGED design is wildly expensive —
    // measured here, 20.9 s at iteration 5 and 537.9 s at iteration 10, a 26x
    // spread — so a cap on total wall clock is a cap on the MEASURING
    // INSTRUMENT, not on the method. The first attempt spent 559 s of its 1912 s
    // budget on two certifications and would have reported the optimiser as
    // slow. The cap is on optimisation time; the instrument's cost is reported
    // beside it and never inside it.
    const double opt_wall = (now_s() - t_run0) - cert_wall_inloop;
    if (a.wall_cap > 0.0 && opt_wall >= a.wall_cap) {
      std::printf("\n★ STOPPING: wall cap %.1f s of OPTIMISATION reached at "
                  "iteration %d (%.1f s optimisation, %.1f s certification).\n",
                  a.wall_cap, it, opt_wall, cert_wall_inloop);
      wall_cap_hit = true;
      done_iters = it;
      break;
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

  // ── ARM 2's REAL OUTPUT: THE SURFACE OF THE FUNCTION ─────────────────────
  //
  // ★ `rho.f64` above is the design SAMPLED ONTO THE VOXEL GRID, which is what
  // every arm since PR 322 has been measured on and is therefore the row that
  // belongs beside them in the handoff's table. But it is NOT what a parametric
  // level set is for. phi here is an analytic function; it can be evaluated
  // anywhere, and the surface that should be exported is ITS zero set, not the
  // zero set of a tricubic interpolation of its samples. `--plsm-export F`
  // writes exactly that, at the lattice `external_field_surface_probe` reads
  // with `factor 1` / `interp none`, so that probe extracts the function and
  // interpolates nothing.
  //
  // ★ THE FROZEN MASK IS STAMPED AT THE REFINED LATTICE TOO, by the containing
  // coarse voxel. It has to be: `build_fields` stamps it on every iteration of
  // every arm, the certificate reads a field that has it, and an exported
  // surface that omitted it would be a different object from the certified one —
  // which is the gap this project has been bitten by before. The mask is a VOXEL
  // object, so the stamp is voxel-blocky at its boundary at any refinement. That
  // is a true statement about the job, not an artefact of this export.
  if (a.plsm && !alpha.empty()) {
    for (int F : a.plsm_export) {
      if (F < 1) continue;
      const int fx = d.nx * F, fy = d.ny * F, fz = d.nz * F;
      const std::vector<double> pf =
          evaluate(L, pbasis, alpha, fx, fy, fz, F, plsm_threads);
      std::vector<double> fo(pf.size(), 0.0);
      for (int k = 0; k < fz; ++k)
        for (int j = 0; j < fy; ++j)
          for (int i = 0; i < fx; ++i) {
            const std::size_t fv =
                static_cast<std::size_t>(i) +
                static_cast<std::size_t>(fx) *
                    (static_cast<std::size_t>(j) +
                     static_cast<std::size_t>(fy) * static_cast<std::size_t>(k));
            const std::size_t cv = d.at(i / F, j / F, k / F);
            if (grid.tags[cv] == VoxelTag::Empty ||
                eff[cv] == MaskValue::FrozenVoid) fo[fv] = 0.0;
            else if (eff[cv] == MaskValue::FrozenSolid) fo[fv] = 1.0;
            else fo[fv] = heaviside(-pf[fv], eta);
          }
      char stem[512];
      std::snprintf(stem, sizeof stem, "%s/plsm_f%d", a.out.c_str(), F);
      std::ofstream f(std::string(stem) + ".f64", std::ios::binary);
      f.write(reinterpret_cast<const char*>(fo.data()),
              static_cast<std::streamsize>(fo.size() * sizeof(double)));
      std::ofstream m(std::string(stem) + ".meta");
      m.precision(17);
      char rung_label[32];
      std::snprintf(rung_label, sizeof rung_label, "%.2f", a.rung);
      m << "rung " << rung_label << "\nrequested_vf " << a.rung << "\n";
      m << "nx " << fx << "\nny " << fy << "\nnz " << fz << "\n";
      m << "spacing " << (h / F) << "\n";
      m << "ox " << grid.origin.x << "\noy " << grid.origin.y << "\noz "
        << grid.origin.z << "\n";
      m << "iso 0.5\nfactor 1\ninterp none\n";
      m << "achieved_vf " << achieved_vf << "\niterations " << done_iters
        << "\nwall_s " << run_wall << "\ncompliance " << compliance_final << "\n";
      m << "# ANALYTIC: phi = sum alpha_i psi_i evaluated at the F=" << F
        << " lattice; " << L.count() << " coefficients; frozen mask stamped by "
        << "the containing coarse voxel\n";
      std::printf("analytic    %s.f64  (%d x %d x %d, spacing %.6f mm)\n", stem,
                  fx, fy, fz, h / F);

      // ── ★ THE SAME SURFACE, EXPORTED AS A VOLUME FRACTION ────────────────
      //
      // Identical design, identical lattice, identical frozen stamp; the ONE
      // difference is what number each fine cell carries. So the pair isolates
      // the EXPORT convention from the design, which is the only way to say
      // whether the sub-voxel position the fraction carries survives marching
      // cubes or is thrown away by it.
      if (a.frac_export) {
        std::vector<double> ff;
        const double t_fe = now_s();
        frac_export_field(L, pbasis, alpha, fx, fy, fz, F, a.frac, ff,
                          plsm_threads);
        for (int k = 0; k < fz; ++k)
          for (int j = 0; j < fy; ++j)
            for (int i = 0; i < fx; ++i) {
              const std::size_t fv =
                  static_cast<std::size_t>(i) +
                  static_cast<std::size_t>(fx) *
                      (static_cast<std::size_t>(j) +
                       static_cast<std::size_t>(fy) * static_cast<std::size_t>(k));
              const std::size_t cv = d.at(i / F, j / F, k / F);
              if (grid.tags[cv] == VoxelTag::Empty ||
                  eff[cv] == MaskValue::FrozenVoid) ff[fv] = 0.0;
              else if (eff[cv] == MaskValue::FrozenSolid) ff[fv] = 1.0;
            }
        char fstem[512];
        std::snprintf(fstem, sizeof fstem, "%s/plsmfrac_f%d", a.out.c_str(), F);
        std::ofstream ffo(std::string(fstem) + ".f64", std::ios::binary);
        ffo.write(reinterpret_cast<const char*>(ff.data()),
                  static_cast<std::streamsize>(ff.size() * sizeof(double)));
        std::ofstream fm(std::string(fstem) + ".meta");
        fm.precision(17);
        fm << "rung " << rung_label << "\nrequested_vf " << a.rung << "\n";
        fm << "nx " << fx << "\nny " << fy << "\nnz " << fz << "\n";
        fm << "spacing " << (h / F) << "\n";
        fm << "ox " << grid.origin.x << "\noy " << grid.origin.y << "\noz "
           << grid.origin.z << "\n";
        fm << "iso 0.5\nfactor 1\ninterp none\n";
        fm << "achieved_vf " << achieved_vf << "\niterations " << done_iters
           << "\nwall_s " << run_wall << "\ncompliance " << compliance_final << "\n";
        fm << "# ANALYTIC, VOLUME FRACTION: each fine cell carries the fraction "
           << "of ITSELF inside {phi<0}, by " << a.frac << "^3 sub-samples; "
           << "same design and same frozen stamp as plsm_f" << F << "\n";
        std::printf("fraction    %s.f64  (%d x %d x %d, %.1f s)\n", fstem, fx, fy,
                    fz, now_s() - t_fe);
      }
    }
    // The coefficients themselves, so the design can be re-evaluated at any
    // resolution later without re-running the optimisation.
    std::ofstream af(a.out + "/alpha.f64", std::ios::binary);
    af.write(reinterpret_cast<const char*>(alpha.data()),
             static_cast<std::streamsize>(alpha.size() * sizeof(double)));
    std::ofstream am(a.out + "/alpha.meta");
    am.precision(17);
    am << "basis " << a.plsm_basis << "\n";
    am << "knots_vox " << a.plsm_dx << " " << a.plsm_dy << " " << a.plsm_dz << "\n";
    am << "support " << a.plsm_support << "\n";
    am << "counts " << L.mx << " " << L.my << " " << L.mz << "\n";
    am << "pad " << L.padx << " " << L.pady << " " << L.padz << "\n";
    am << "n_coeff " << L.count() << "\nn_voxels " << n << "\n";
    am << "compression " << (static_cast<double>(n) / static_cast<double>(L.count()))
       << "\n";
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
      "★ IN-LOOP CERT       %lld calls, %.1f s total (%.1f%% of the run)\n"
      "★ OPTIMISATION ONLY  %.1f s   (run wall minus in-loop certification —\n"
      "                     THIS is the method's cost; the certifications are a\n"
      "                     stopping rule and would not be paid in production)\n"
      "★ STOPPED BECAUSE    %s\n"
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
      cert_calls_inloop, cert_wall_inloop,
      run_wall > 0.0 ? 100.0 * cert_wall_inloop / run_wall : 0.0,
      run_wall - cert_wall_inloop,
      margin_stop_iter > 0
          ? "the certified margin reached the target"
          : (wall_cap_hit ? "the wall-clock cap was reached"
                          : (converged_early ? "the compliance plateau"
                                             : "the iteration count ran out")),
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
