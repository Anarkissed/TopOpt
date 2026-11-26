// The shared solve pieces of the optimiser (TO rebuild stage 5, workplan section 2):
// the penalised compliance and its sensitivity, the multi-scenario compliance, and
// the effective design mask. MOVED unchanged out of simp.cpp, which keeps the SIMP
// optimiser loops; this file is the solver lane's (TOSolver). Like simp.cpp it is
// compiled only when Eigen is available (core/CMakeLists.txt).

#include "topopt/simp.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "topopt/observability.hpp"

#include "../fea/fea_matfree.hpp"  // mf_parallel_ranges: the solver's worker pool

namespace topopt {

namespace {

// The two parameter helpers simp_compliance shares with simp.cpp's loops, copied
// verbatim from simp.cpp's anonymous namespace (a pure move leaves simp.cpp's own
// copies in place for its loops).
void validate_params(const SimpParams& p) {
  if (!(p.youngs_modulus > 0.0))
    throw std::invalid_argument("simp: youngs_modulus (E0) must be > 0");
  if (!(p.penalty > 0.0))
    throw std::invalid_argument("simp: penalty (p) must be > 0");
  if (!(p.density_min > 0.0 && p.density_min <= 1.0))
    throw std::invalid_argument("simp: density_min must be in (0, 1]");
}

// Clamp a design density to the admissible interval [rho_min, 1].
double clamp_density(const SimpParams& p, double density) {
  return std::min(1.0, std::max(p.density_min, density));
}

}  // namespace

// Penalized-solve counter (task 2026-08-02-iteration-phase-timing). Bumped on
// EVERY simp_compliance call — trajectory, certification and recovery alike —
// so "how many FEA solves did this design iteration run?" is a subtraction of
// two samples rather than a reading of the call graph. Not atomic, for the same
// reason as the matvec counter: one production run drives its solves from one
// thread, and the instrument must not tax what it measures.
namespace {
long long g_simp_compliance_calls = 0;
}  // namespace

long long simp_compliance_call_count() { return g_simp_compliance_calls; }

SimpCompliance simp_compliance(const VoxelGrid& grid, const SimpParams& params,
                               const std::vector<double>& density,
                               const std::vector<DirichletBC>& bcs,
                               const std::vector<NodalLoad>& loads,
                               double tolerance, int max_iterations,
                               const FeaSolution* initial_guess,
                               PenalizedSolver* solver,
                               SolverKind solver_kind,
                               const std::vector<char>* active_mask) {
  ++g_simp_compliance_calls;
  validate_params(params);
  if (density.size() != grid.voxel_count())
    throw std::invalid_argument(
        "simp_compliance: density vector size != voxel_count");
  if (active_mask != nullptr) {
    if (active_mask->size() != grid.voxel_count())
      throw std::invalid_argument(
          "simp_compliance: active_mask size != voxel_count");
    if (solver_kind != SolverKind::MultigridCG_Matfree)
      throw std::invalid_argument(
          "simp_compliance: active_mask requires SolverKind::MultigridCG_Matfree "
          "(the active domain is a matrix-free-operator feature)");
  }
  // MULTISCALE LATTICE MATERIAL (task multiscale-lattice-to). Null model = the
  // whole existing world, byte-for-byte: not one branch below is taken.
  const LatticeMaterialModel* const LM = params.lattice_material;
  if (LM != nullptr && params.lattice_region != nullptr &&
      params.lattice_region->size() != grid.voxel_count())
    throw std::invalid_argument(
        "simp_compliance: lattice_region size != voxel_count");
  // Task 2026-08-13-lattice-as-a-material: the relative-density override. Null on
  // every path that has not opted in, so `LR == nullptr` below is the whole
  // pre-existing world.
  const std::vector<double>* const LR = params.lattice_relative_density;
  if (LR != nullptr && LM == nullptr)
    throw std::invalid_argument(
        "simp_compliance: lattice_relative_density is set but lattice_material "
        "is null — there is no material law for it to be a density of");
  if (LR != nullptr && LR->size() != grid.voxel_count())
    throw std::invalid_argument(
        "simp_compliance: lattice_relative_density size != voxel_count");

  // Split this call into LINEAR SOLVE and SENSITIVITY SWEEP (task 2026-08-02-
  // iteration-phase-timing). The per-voxel modulus fill below is charged to the
  // solve — it exists only to feed it — so the two spans partition the call.
  const double t_solve0 = steady_clock_ms();

  // Per-voxel penalized Young's modulus E(rho_e) for the graded FEA solve. Empty
  // voxels contribute no element, so their entry is ignored by fea_solve_cg; we
  // still fill it (0) to keep the vector grid-indexed.
  std::vector<double> elem_youngs(grid.voxel_count(), 0.0);
  // MULTISCALE: the per-voxel cubic tensor of the latticed voxels. Left empty on
  // the classic path so nothing downstream can read it.
  std::vector<char> lat_mask;
  std::vector<double> lat_c11, lat_c12, lat_c44;
  if (LM != nullptr) {
    lat_mask.assign(grid.voxel_count(), 0);
    lat_c11.assign(grid.voxel_count(), 0.0);
    lat_c12.assign(grid.voxel_count(), 0.0);
    lat_c44.assign(grid.voxel_count(), 0.0);
  }
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        const std::size_t e = grid.index(i, j, k);
        const double rho = clamp_density(params, density[e]);
        // MULTISCALE: a voxel the run will lattice carries the MEASURED
        // homogenized cubic tensor at its own density; every other voxel keeps
        // rho^p * E0 exactly as before. This is the whole formulation change —
        // the optimizer now steers on the stiffness the printed lattice will
        // have, so it has no incentive to starve a member below the
        // cells-per-member floor.
        if (LM != nullptr &&
            (params.lattice_region == nullptr || (*params.lattice_region)[e])) {
          // The relative density the tensor is evaluated at. Normally the design
          // density; a declared frozen region overrides it per voxel (see
          // SimpParams::lattice_relative_density), because there the design
          // density is the ENVELOPE occupancy (1.0) and the lattice's own
          // relative density is a separate number.
          const double lat_rho =
              (LR != nullptr && (*LR)[e] >= 0.0) ? (*LR)[e] : rho;
          const CubicTensor C = LM->value(lat_rho);
          lat_mask[e] = 1;
          lat_c11[e] = C.C11;
          lat_c12[e] = C.C12;
          lat_c44[e] = C.C44;
          continue;  // youngs_per_voxel is IGNORED for a latticed voxel
        }
        elem_youngs[e] = std::pow(rho, params.penalty) * params.youngs_modulus;
      }

  SimpCompliance out;
  // Arm G (multigrid.cpp, safe retry): the voxels the matrix-free solve below
  // solved at the floor modulus, if any. Empty on every solve whose shipped MG
  // converged, so the energy loop further down is then byte-for-byte unchanged.
  std::vector<char> dropped;
  double dropped_e = 0.0;
  if (LM != nullptr) {
    // The COMPOSITE isotropic-or-cubic system (fea.hpp): a masked voxel is
    // hex8_stiffness_cubic(C11, C12, C44), every other solid voxel is the
    // identical graded isotropic element it has always been. Same DOF count —
    // the lattice is a softer, anisotropic MATERIAL on the same macro element,
    // which is exactly what the homogenization buys.
    //
    // ROUTE. MultigridCG_Matfree takes the matrix-free accelerator stack
    // directly (PR 257's armed route: multigrid + GenEO deflation + Krylov
    // recycling on the exact three-block operator), and is the only kind that
    // can carry an active-domain mask. Everything else goes to
    // fea_solve_cg_lattice, which itself routes to the same matrix-free path
    // when production has armed kProductionMatfreeCubicLattice and to the
    // assembled Jacobi-CG otherwise. The cached PenalizedSolver fast path does
    // not apply: it rescales ONE isotropic operator, and a composite system has
    // three independent per-voxel coefficients, so there is nothing to rescale.
    if (solver_kind == SolverKind::MultigridCG_Matfree) {
      out.solution = fea_solve_cg_lattice_matfree(
          grid, elem_youngs, lat_mask, lat_c11, lat_c12, lat_c44, params.poisson,
          bcs, loads, tolerance, max_iterations, &out.cg, active_mask);
    } else {
      out.solution = fea_solve_cg_lattice(grid, elem_youngs, lat_mask, lat_c11,
                                          lat_c12, lat_c44, params.poisson, bcs,
                                          loads, tolerance, max_iterations,
                                          &out.cg);
    }
  } else if (solver_kind == SolverKind::MultigridCG_Matfree) {
    // Matrix-free multigrid (handoff 078 + design-box on-device fix): the
    // memory-lean path — the assembled fine K (which OOMs on the design box) is
    // never built. Solves the identical system to the same tolerance; stateless,
    // so the cached PenalizedSolver / warm start are bypassed. out.cg.used_multigrid
    // reports whether MG ran or it fell back to the matrix-free Jacobi-CG.
    // ACTIVE DOMAIN: `active_mask` (may be null) restricts which solid voxels
    // contribute an element. Everything downstream of mf_build_elems — void
    // gate, kept-DOF numbering, Jacobi diagonal, hierarchy, V-cycle — is
    // unchanged code running exactly on the surviving system.
    // WARM START (task 2026-08-10-plsm-production, S3): `initial_guess` used to
    // stop here — the comment above still says "the cached PenalizedSolver /
    // warm start are bypassed", and for the PenalizedSolver it remains true. It
    // is now FORWARDED, and it is null on every path that has not opted in:
    // SimpOptions::matfree_warm_start gates the two trajectory call sites, and
    // the final compliance solve and every certification solve pass nullptr
    // unconditionally. So a default run reaches this line with
    // initial_guess == nullptr and is byte-for-byte what it was.
    // The safe retry may solve tiny floating solid islands at the floor
    // modulus (only after the shipped MG has stalled); this compliance accounts
    // for that below, so the permit is held here — and nowhere a solution is
    // read back at the true modulus without that accounting (analyze.cpp
    // forbids it for certification; the final compliance solves of
    // simp_optimize, its masked / SEMDOT overload and plsm_optimize forbid it
    // too, being certified numbers).
    {
      FeaIslandDropPermit permit;
      out.solution = fea_solve_mgcg_matfree(grid, elem_youngs, params.poisson,
                                            bcs, loads, tolerance,
                                            max_iterations, &out.cg,
                                            active_mask, initial_guess);
    }
    const std::vector<int>& dv = fea_matfree_last_dropped_islands();
    if (!dv.empty()) {
      dropped.assign(grid.voxel_count(), 0);
      for (int e : dv) dropped[static_cast<std::size_t>(e)] = 1;
      dropped_e = fea_matfree_last_dropped_floor_youngs();
    }
  } else if (solver_kind == SolverKind::MultigridCG) {
    // Opt-in accelerator (handoff 073): the geometric-multigrid-preconditioned
    // CG solves the identical system to the same tolerance. It is stateless, so
    // the cached PenalizedSolver fast path and warm start are bypassed;
    // out.cg.used_multigrid reports whether MG ran or it fell back to Jacobi-CG.
    out.solution = fea_solve_mgcg(grid, elem_youngs, params.poisson, bcs, loads,
                                  tolerance, max_iterations, &out.cg);
  } else if (solver != nullptr && solver->usable()) {
    // Cached fast path: rescale the pre-reduced operator + internal warm start.
    out.solution =
        solver->solve(elem_youngs, tolerance, max_iterations, &out.cg);
  } else {
    out.solution = fea_solve_cg(grid, elem_youngs, params.poisson, bcs, loads,
                                tolerance, max_iterations, &out.cg,
                                initial_guess);
  }

  const double t_sens0 = steady_clock_ms();
  out.t_solve_ms = t_sens0 - t_solve0;

  // Compliance c = sum_e E(rho_e) * (u_e^T K_unit u_e) and the self-adjoint
  // sensitivity dc/drho_e = -p * rho_e^(p-1) * E0 * (u_e^T K_unit u_e). K_unit is
  // the unit-modulus element (the isotropic Hex8 is exactly linear in E), so the
  // element stiffness at modulus E is E * K_unit and its strain energy density
  // per unit modulus is q_e = u_e^T K_unit u_e.
  const Hex8Stiffness Kunit = hex8_stiffness(1.0, params.poisson, grid.spacing);
  // MULTISCALE: the three FIXED reference blocks of the exact cubic decomposition
  // Ke = C11*K_A + C12*K_B + C44*K_C (PR 252, worst rel err 8.5e-16). Built once
  // per call, only when a lattice material is in play. Because Ke is exactly
  // LINEAR in (C11, C12, C44), a latticed element's strain energy and its
  // sensitivity both fall out of three scalars per element:
  //     q_A = u^T K_A u,  q_B = u^T K_B u,  q_C = u^T K_C u
  //     c_e     =  C11*q_A + C12*q_B + C44*q_C
  //     dc/drho = -(dC11*q_A + dC12*q_B + dC44*q_C)
  // — the same self-adjoint identity as the isotropic branch, with the scalar
  // (E, dE/drho) pair replaced by the triplets (C, dC/drho). No approximation
  // enters: the model's dC/drho is analytic (verified against central differences
  // to 9.6e-9 by the probe and again by test_lattice_material_model here).
  Hex8Stiffness KA, KB, KC;
  if (LM != nullptr) hex8_cubic_blocks(grid.spacing, KA, KB, KC);
  out.dcompliance.assign(grid.voxel_count(), 0.0);
  // S-05 (TO rebuild stage 5): the per-element energy and sensitivity on every
  // matrix-free worker, by contiguous z-slabs. Each element writes only its own
  // `ce[e]` (its compliance term) and `dcompliance[e]`, so the values do not
  // depend on the thread count; the compliance is then summed SERIALLY in the
  // same ascending voxel order as before, so it is byte-identical to the serial
  // loop this replaces (a skipped element contributes an exact +0.0).
  std::vector<double> ce(grid.voxel_count(), 0.0);
  fea_detail::mf_parallel_ranges(0, grid.nz, 2, [&](int k_lo, int k_hi) {
  for (int k = k_lo; k < k_hi; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        const std::size_t e = grid.index(i, j, k);
        // ACTIVE DOMAIN: an element the solve did not assemble is not part of
        // the system that was solved, so it contributes NO energy and NO
        // sensitivity. The compliance stays exactly f^T u = u^T K u for the K
        // that ran — including a fringe out-of-band element (whose nodes DO
        // carry displacement, being shared with in-band elements) would add
        // energy from a stiffness the solve never had. Zeroing the sensitivity
        // is also what makes the growth invariant true: an out-of-band voxel
        // sees dc/drho = 0 and the updater drives it to the density floor, so
        // it cannot grow before the band grows to admit it.
        if (active_mask != nullptr && (*active_mask)[e] == 0) continue;
        const std::array<int, 8> en = fea_element_nodes(grid, i, j, k);
        std::array<double, 24> ue;
        for (int a = 0; a < 8; ++a)
          for (int comp = 0; comp < 3; ++comp)
            ue[static_cast<std::size_t>(3 * a + comp)] =
                out.solution.at(en[a], comp);

        const double rho = clamp_density(params, density[e]);

        // MULTISCALE: a latticed element's energy and sensitivity from the three
        // reference-block quadratic forms. Its density enters ONLY through
        // C(rho) and dC/drho — there is no rho^p anywhere on this branch, which
        // is the entire point: intermediate density is a REAL, printable,
        // measured material here, not a penalised fiction.
        if (!lat_mask.empty() && lat_mask[e] != 0) {
          double qA = 0.0, qB = 0.0, qC = 0.0;
          for (int r = 0; r < 24; ++r) {
            double ka = 0.0, kb = 0.0, kc = 0.0;
            for (int c = 0; c < 24; ++c) {
              const double uc = ue[static_cast<std::size_t>(c)];
              ka += KA(r, c) * uc;
              kb += KB(r, c) * uc;
              kc += KC(r, c) * uc;
            }
            const double ur = ue[static_cast<std::size_t>(r)];
            qA += ur * ka;
            qB += ur * kb;
            qC += ur * kc;
          }
          // THE SAME relative density the tensor was BUILT at, by the same rule —
          // written once here and once in the fill loop above rather than cached,
          // because a cached triplet and a re-derived derivative that disagreed
          // about which rho they belong to is exactly the defect that would not
          // show up in the compliance and would silently poison the gradient.
          const double lat_rho =
              (LR != nullptr && (*LR)[e] >= 0.0) ? (*LR)[e] : rho;
          double Cv[3], Cd[3];
          LM->eval(lat_rho, Cv, Cd);
          ce[e] = Cv[0] * qA + Cv[1] * qB + Cv[2] * qC;
          // dc/d(lat_rho). On the multiscale path lat_rho IS the design density
          // and this is dc/d(design density), unchanged. On an overridden voxel it
          // is the derivative with respect to the LATTICE relative density — what
          // Mode 2 chains through d rho / d beta, and what no density updater ever
          // reads because an overridden voxel is frozen.
          out.dcompliance[e] = -(Cd[0] * qA + Cd[1] * qB + Cd[2] * qC);
          continue;
        }

        // q_e = u_e^T K_unit u_e (>= 0).
        double q = 0.0;
        for (int r = 0; r < 24; ++r) {
          double kr = 0.0;
          for (int c = 0; c < 24; ++c) kr += Kunit(r, c) * ue[static_cast<std::size_t>(c)];
          q += ue[static_cast<std::size_t>(r)] * kr;
        }

        // Arm G: a voxel the solve held at the floor modulus contributes the
        // energy of THAT system (so compliance stays f.u of what was solved)
        // and no sensitivity — the solved system does not depend on its
        // density, exactly as an out-of-domain voxel above (an unanchored
        // speck carries no load either way).
        if (!dropped.empty() && dropped[e]) {
          ce[e] = dropped_e * q;
          out.dcompliance[e] = 0.0;
          continue;
        }
        ce[e] = std::pow(rho, params.penalty) * params.youngs_modulus * q;
        out.dcompliance[e] = -params.penalty *
                             std::pow(rho, params.penalty - 1.0) *
                             params.youngs_modulus * q;
      }
  });
  double compliance = 0.0;
  for (const double c : ce) compliance += c;  // ascending voxel order, as before
  out.compliance = compliance;
  out.t_sensitivity_ms = steady_clock_ms() - t_sens0;
  return out;
}

SimpCompliance simp_scenarios_compliance(const VoxelGrid& grid, const SimpParams& params,
                                         const std::vector<double>& density,
                                         const std::vector<SimpScenario>& scenarios,
                                         double tolerance, int max_iterations,
                                         SolverKind solver_kind, ScenarioSolveState& state,
                                         bool warm_start) {
  const std::size_t ns = scenarios.size();
  if (ns == 0)
    throw std::invalid_argument("simp_scenarios_compliance: no scenario");
  if (state.c0.size() != ns) {
    state.c0.assign(ns, 0.0);
    state.warm.assign(ns, FeaSolution{});
    state.last.assign(ns, 0.0);
  }
  std::vector<SimpCompliance> cs(ns);
  for (std::size_t s = 0; s < ns; ++s) {
    const FeaSolution* guess =
        warm_start && !state.warm[s].u.empty() ? &state.warm[s] : nullptr;
    cs[s] = simp_compliance(grid, params, density, scenarios[s].bcs, scenarios[s].loads,
                            tolerance, max_iterations, guess, /*solver=*/nullptr,
                            solver_kind);
    state.warm[s] = cs[s].solution;
    state.last[s] = cs[s].compliance;
    if (!(state.c0[s] > 0.0)) state.c0[s] = cs[s].compliance > 0.0 ? cs[s].compliance : 1.0;
  }
  // ONE reference for every scenario (his ask, 2026-10-28): the first compliance of the
  // scenario with the LARGEST load (the 2-norm of its nodal load vector; a tie takes the
  // first). Compliance scales as load^2, so measured against its OWN first compliance a
  // scenario's load cancelled and a 0.5 kg twist pulled as hard as his 51 kg case. Now
  // each counts in proportion to its load: a light cross scenario still forces a
  // connection (its arm on weak springs starts orders of magnitude over the reference),
  // a thin one. Not the LARGEST first compliance: that is the unconnected cross scenario.
  std::size_t ref = 0;
  double ref_load = -1.0;
  for (std::size_t s = 0; s < ns; ++s) {
    double f2 = 0.0;
    for (const NodalLoad& l : scenarios[s].loads) f2 += l.value * l.value;
    if (f2 > ref_load) {
      ref_load = f2;
      ref = s;
    }
  }
  const double c_ref = state.c0[ref];
  const double p = kScenarioPNorm;
  std::size_t worst = 0;
  std::vector<double> r(ns);
  for (std::size_t s = 0; s < ns; ++s) {
    r[s] = cs[s].compliance / c_ref;
    if (r[s] > r[worst]) worst = s;
  }
  // J = (sum_s r_s^p)^(1/p), taken as rmax (sum_s (r_s / rmax)^p)^(1/p): an unconnected
  // cross scenario starts at r ~ 1e6 and more, and r^p must not overflow.
  const double rmax = r[worst];
  double sum = 0.0;
  for (std::size_t s = 0; s < ns; ++s) sum += rmax > 0.0 ? std::pow(r[s] / rmax, p) : 0.0;
  const double J = rmax > 0.0 ? rmax * std::pow(sum, 1.0 / p) : 0.0;
  SimpCompliance out;
  out.compliance = J;
  out.dcompliance.assign(density.size(), 0.0);
  out.cg.converged = true;
  for (std::size_t s = 0; s < ns; ++s) {
    const double w = (J > 0.0 ? std::pow(r[s] / J, p - 1.0) : 0.0) / c_ref;
    for (std::size_t e = 0; e < out.dcompliance.size() && e < cs[s].dcompliance.size(); ++e)
      out.dcompliance[e] += w * cs[s].dcompliance[e];
    out.cg.iterations += cs[s].cg.iterations;
    out.cg.converged = out.cg.converged && cs[s].cg.converged;
    out.cg.residual = std::max(out.cg.residual, cs[s].cg.residual);
    out.t_solve_ms += cs[s].t_solve_ms;
    out.t_sensitivity_ms += cs[s].t_sensitivity_ms;
  }
  out.cg.used_multigrid = cs[worst].cg.used_multigrid;
  out.cg.mg_levels = cs[worst].cg.mg_levels;
  out.solution = std::move(cs[worst].solution);
  return out;
}

// The effective mask actually optimized: the caller's mask with every Load and
// Fixture voxel forced to FrozenSolid (M1.6 tags are implicitly "keep-in", so
// the §7 V3 retention gate is structural). Empty voxels are left as-is (ignored).
//

// Declared in simp.hpp as `effective_design_mask` (task 2026-08-04-protect-freeze-
// vs-solidity) so the lattice receipt can name the SAME frozen set the loop held,
// rather than re-deriving one beside it. The body is unchanged.
//
// PUBLIC since task 2026-08-03-preflight-feasibility-and-divergence: the
// pre-flight load-path check must walk the SAME "may this voxel hold material?"
// set the optimizer works on, and a second, similar rule could refuse a job this
// one would have solved. See simp.hpp.
DesignMask effective_design_mask(const VoxelGrid& grid, const DesignMask& mask) {
  if (mask.size() != grid.voxel_count())
    throw std::invalid_argument(
        "effective_design_mask: mask size != grid.voxel_count()");
  DesignMask eff = mask;
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        const VoxelTag t = grid.tag(i, j, k);
        if (t == VoxelTag::Empty) {
          // Empty voxels are never design variables — their caller-supplied
          // mask entry is ignored (voxel.hpp). Normalizing them to FrozenVoid
          // here keeps them out of the Active-voxel budget: on a part that
          // does not fill its bounding grid (e.g. an imported model), an
          // Empty-counting budget makes volume_fraction * n_active exceed the
          // reachable volume, so the OC bisection saturates and every rung
          // collapses to the same all-solid design.
          eff[grid.index(i, j, k)] = MaskValue::FrozenVoid;
        } else if (t == VoxelTag::Load || t == VoxelTag::Fixture) {
          eff[grid.index(i, j, k)] = MaskValue::FrozenSolid;
        }
      }
  return eff;
}

}  // namespace topopt
