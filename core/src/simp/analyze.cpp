#include "topopt/analyze.hpp"

#include <algorithm>
#include <array>
#include <cassert>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <limits>
#include <string>
#include <vector>

#include "topopt/build_orientation.hpp"
#include "topopt/fea.hpp"
#include "topopt/orient.hpp"
#include "topopt/printed_mass.hpp"      // TO rebuild stage 2
#include "topopt/report.hpp"
#include "topopt/simp.hpp"
#include "topopt/material_length.hpp"  // kAcrossLayerLengthFactor
#include "topopt/stress_measure.hpp"   // TO rebuild stage 2
#include "topopt/to_stage_switch.hpp"  // TO rebuild stage 2
#include "topopt/voxel.hpp"

namespace topopt {

namespace {

// The M3.5 iso threshold: a voxel is "printed" (solid material) when its physical
// density exceeds this. Same constant the optimizer's recovery block uses.
constexpr double kIso = 0.5;

// M7.infill-margin seed curve. Kept identical to the optimizer's original
// file-local copy so the acceptance gate is byte-for-byte the pre-extraction gate.
constexpr double kKnockdownExponent = 1.5;
constexpr double kKnockdownFloor = 1e-3;

// Width-aware gate (handoff 2026-07-26-width-aware-knockdown): the local-thickness
// distance transform sweeps ball radii up to this many voxels. It BOUNDS the cost
// (one seeded EDT per level → O(cap · voxel_count), bar K6) and it sets the
// "thick" cutoff: a voxel still solid under the radius-`cap` opening is at least
// 2·cap·spacing mm thick, gets +inf thickness, and therefore NO wall rescue — the
// conservative treatment of envelope-scale solid regions (bar K4). At production
// spacing (1.5–3 mm on a 200 mm part) 2·32·spacing ≈ 96–192 mm comfortably spans
// 191's ~59–98 mm crossover; at finer spacing the cutoff drops, which only makes
// the thick-region gate MORE conservative.
constexpr int kWidthAwareThicknessCapVoxels = 32;
// Install 3: the strength check's knobs default to these constants, exactly.
static_assert(AnalysisKnobs{}.thickness_cap_voxels == kWidthAwareThicknessCapVoxels);
static_assert(AnalysisKnobs{}.sliding_share_max == kAnchorsSlidingShare);
static_assert(AnalysisKnobs{}.contact_rounds == 6);
static_assert(KnockdownSpec{}.infill_exponent == kKnockdownExponent);
static_assert(KnockdownSpec{}.infill_floor == kKnockdownFloor);

// Gather one element's 24 nodal displacements from the global solution, in the
// hex8_stiffness DOF order (node-major interleaved). Same helper the recovery
// block used; moved here with the stress loop.
std::array<double, 24> element_dofs(const VoxelGrid& grid, const FeaSolution& sol,
                                    int i, int j, int k) {
  const std::array<int, 8> en = fea_element_nodes(grid, i, j, k);
  std::array<double, 24> ue{};
  for (int a = 0; a < 8; ++a)
    for (int c = 0; c < 3; ++c)
      ue[static_cast<std::size_t>(3 * a + c)] = sol.at(en[a], c);
  return ue;
}

}  // namespace

double infill_margin_knockdown(double infill_percent) {
  return infill_margin_knockdown(infill_percent, kKnockdownExponent, kKnockdownFloor);
}

double infill_margin_knockdown(double infill_percent, double exponent, double floor) {
  const double f = infill_percent / 100.0;
  if (f >= 1.0) return 1.0;  // solid / unset: exact 1.0, byte-identical gate
  if (f <= 0.0) return floor;
  return std::max(std::pow(f, exponent), floor);
}

double margin_reproduction_relative_delta(double recorded, double reproduced) {
  // Exact equality first, so two infinities (a zero-stress posture) and two
  // zeros read as a perfect reproduction rather than falling into the guards.
  if (recorded == reproduced) return 0.0;
  if (!std::isfinite(recorded) || !std::isfinite(reproduced))
    return std::numeric_limits<double>::infinity();
  const double scale = std::abs(recorded);
  if (!(scale > 0.0)) return std::numeric_limits<double>::infinity();
  return std::abs(reproduced - recorded) / scale;
}

bool margin_reproduces(double recorded, double reproduced, double cg_tolerance) {
  const double band = kMarginReproductionResidualFactor * cg_tolerance;
  // No declared convergence bound -> no derived band. Fall back to the exact
  // comparison rather than invent one: the band's whole justification is that it
  // is a multiple of the residual tolerance both solves actually met.
  if (!(band > 0.0)) return recorded == reproduced;
  return margin_reproduction_relative_delta(recorded, reproduced) <= band;
}

double gate_margin_effective(double yield_strength_mpa, double z_knockdown,
                             double max_von_mises,
                             double max_von_mises_effective,
                             double max_interlayer,
                             const KnockdownSpec& knockdown) {
  // THE ONE accept-gate expression. Lifted VERBATIM out of analyze_fixed_design
  // (handoff 2026-08-01-build-direction-separation) so the orientation scorer
  // prices a candidate's verdict with this exact arithmetic instead of a second
  // copy. analyze_fixed_design now calls this, so the real gate and the
  // counterfactual are the same code by construction.
  if (knockdown.width_aware) {
    // --- Width-aware posture (handoff 2026-07-26-width-aware-knockdown) --------
    // In-plane: the worst SOLID-EQUIVALENT von Mises max(vm/k(W)) over the printed
    // field already folds the per-voxel wall rescue in, so the in-plane effective
    // margin is yield / max_von_mises_effective. Interlayer: 191/192 measured axial
    // and bending only — NOT z-bonding — so the interlayer term keeps the UNMODIFIED
    // f^1.5 (infill_knockdown); passing max_interlayer / infill_knockdown through
    // compute_stress_margin reproduces margin.interlayer * infill_knockdown exactly,
    // so the gate is never made LESS conservative than today on interlayer (bar K4).
    // With no walls (wall_thickness_mm == 0) k(W) == f^1.5 for every voxel, so this
    // collapses to margin.worst_case * infill_knockdown (the scalar path) to within
    // floating point — the armed-but-unconfigured run matches the default posture.
    const double il_scaled = knockdown.infill_knockdown > 0.0
                                 ? max_interlayer / knockdown.infill_knockdown
                                 : max_interlayer;
    return compute_stress_margin(yield_strength_mpa, z_knockdown,
                                 max_von_mises_effective, il_scaled)
        .worst_case;
  }
  // Default posture: the pure scalar f^1.5 gate, byte-for-byte the pre-width gate
  // (infill_knockdown == 1.0 for solid/unset infill → the pre-M7.infill gate).
  return compute_stress_margin(yield_strength_mpa, z_knockdown, max_von_mises,
                               max_interlayer)
             .worst_case *
         knockdown.infill_knockdown;
}

double wall_area_fraction(double member_width_mm, double wall_thickness_mm) {
  const double W = member_width_mm;
  // An unbounded/degenerate width (the "thicker than we measured" sentinel, or a
  // non-member) gets NO wall rescue — the conservative choice (bar K4/K5).
  if (!std::isfinite(W) || W <= 0.0) return 0.0;
  double t = wall_thickness_mm;
  if (!(t > 0.0)) return 0.0;                 // no walls → no rescue
  if (t > 0.5 * W) t = 0.5 * W;               // a ring can't exceed the half-width:
                                              // a member thinner than 2t is all wall
  const double f = 4.0 * t * (W - t) / (W * W);
  return f < 0.0 ? 0.0 : (f > 1.0 ? 1.0 : f);
}

double width_aware_knockdown(double infill_percent, double member_width_mm,
                             double wall_thickness_mm) {
  return width_aware_knockdown(infill_percent, member_width_mm, wall_thickness_mm,
                               kKnockdownExponent, kKnockdownFloor);
}

double width_aware_knockdown(double infill_percent, double member_width_mm,
                             double wall_thickness_mm, double exponent, double floor) {
  // The infill core term is the SAME Gibson-Ashby curve the scalar gate uses — ONE
  // definition of f^1.5 (bar K7). Solid infill → 1.0, so the composite is 1.0 too.
  const double core = infill_margin_knockdown(infill_percent, exponent, floor);
  const double fw = wall_area_fraction(member_width_mm, wall_thickness_mm);
  const double k = fw + (1.0 - fw) * core;    // Voigt: walls in parallel with core
  return k > 1.0 ? 1.0 : k;                    // both terms in (0,1] → k in (0,1]
}

FixedDesignAnalysis analyze_fixed_design(
    const VoxelGrid& grid_in, const SimpParams& params,
    const std::vector<double>& density_in, const std::vector<DirichletBC>& bcs,
    const std::vector<NodalLoad>& loads, const Material& material,
    const Vec3& build_dir, double cg_tolerance, int cg_max_iterations,
    SolverKind solver_kind, double margin_stop, const KnockdownSpec& knockdown,
    bool load_path_ok, double part_solid, const LatticePosture* lattice,
    bool score_build_orientation, bool build_direction_inferred,
    bool auto_apply_build_orientation, double printed_iso,
    bool gate_on_strut_strength, const AnalysisKnobs* knobs, const StressView* stress_view) {
  const AnalysisKnobs kn = knobs ? *knobs : AnalysisKnobs{};
  // THE STRESS VIEW (TOPOPT_STRENGTH=surface; null = today, `grid` and `density` are
  // then the arguments themselves). Everything below solves and reads stress on
  // `grid` / `density`; the mass, printed counts, support proxy and V3 read
  // `grid_in` / `density_in`, the design as it will be printed.
  const bool use_view = stress_view != nullptr && lattice == nullptr;
  if (use_view && (stress_view->grid.nx != grid_in.nx || stress_view->grid.ny != grid_in.ny ||
                   stress_view->grid.nz != grid_in.nz ||
                   stress_view->density.size() != density_in.size()))
    throw std::invalid_argument("analyze_fixed_design: stress view size != the grid's");
  const VoxelGrid& grid = use_view ? stress_view->grid : grid_in;
  const std::vector<double>& density = use_view ? stress_view->density : density_in;
  // THE PRINTED-SET THRESHOLD for this analysis. Shadows the file-scope M3.5
  // constant so every "is there material here" test in this function asks the
  // caller's question — 0.5 for every classic run (identical to the constant it
  // shadows, so those paths are byte-for-byte unchanged), below the band floor
  // for a MULTISCALE one, where a 30%-dense voxel is real printable lattice and
  // not a half-empty solid voxel. See analyze.hpp for the full rationale.
  if (!(printed_iso > 0.0 && printed_iso < 1.0))
    throw std::invalid_argument(
        "analyze_fixed_design: printed_iso must be in (0, 1)");
  const double kIso = printed_iso;
  FixedDesignAnalysis out;
  // The orientation this analysis describes. Reassigned at the very end IF the
  // caller armed auto-apply and the scorer chose a different direction; until
  // then, and on every existing caller's path, it is the direction passed in.
  out.applied_build_dir = build_dir;

  // --- Lattice certification (handoff 2026-07-27-lattice-certification) --------
  // When a LatticePosture is supplied, the certification solve carries each latticed
  // voxel's homogenized effective cubic tensor (fea_solve_cg_lattice) instead of the
  // scalar-penalized isotropic modulus, so the solve is of the REAL composite object.
  // A null posture (the default, every current caller) skips ALL of this and the
  // function is byte-for-byte the pre-lattice path. Validate the posture arrays here.
  const bool has_lattice = (lattice != nullptr);
  std::vector<char> lat_mask;
  std::vector<double> lat_c11, lat_c12, lat_c44;
  if (has_lattice) {
    const std::size_t nv = grid.voxel_count();
    if (lattice->mask.size() != nv || lattice->relative_density.size() != nv)
      throw std::invalid_argument(
          "analyze_fixed_design: LatticePosture mask/relative_density size != "
          "voxel_count");
    lat_mask = lattice->mask;
    lat_c11.assign(nv, 0.0);
    lat_c12.assign(nv, 0.0);
    lat_c44.assign(nv, 0.0);
    // Density band enforced AT CERTIFICATION (lattice certification E2E, bar E5).
    // The band [lattice_rho_min, lattice_rho_max] is the RESOLVED span of PR 198's
    // sweep — the only densities the tensor library is trustworthy at. Outside it,
    // lattice_cubic_tensor would silently CLAMP to the endpoint and certify against
    // a tensor for a DIFFERENT density than the exported file carries. That is the
    // conflation this feature exists to prevent, so a posture asking to certify an
    // out-of-band density is REFUSED here — read from core (lattice_rho_min/max),
    // not hardcoded — rather than certified against a clamped/stale tensor. The band
    // gates the CERTIFICATION, independently of any check the generator made.
    const double rho_min = lattice_rho_min(lattice->topology);
    const double rho_max = lattice_rho_max(lattice->topology);
    for (std::size_t e = 0; e < nv; ++e) {
      if (!lat_mask[e]) continue;
      bool clamped = false;
      const CubicTensor T =
          lattice_cubic_tensor(lattice->topology, lattice->relative_density[e],
                               params.youngs_modulus, &clamped);
      if (clamped)
        throw LatticeDensityOutOfBand(
            lattice->relative_density[e], rho_min, rho_max,
            "analyze_fixed_design: lattice relative density " +
                std::to_string(lattice->relative_density[e]) +
                " is outside the certifiable " +
                std::string(lattice_topology_name(lattice->topology)) + " band [" +
                std::to_string(rho_min) + ", " + std::to_string(rho_max) +
                "] — refusing to certify against a clamped tensor (bar E5)");
      lat_c11[e] = T.C11;
      lat_c12[e] = T.C12;
      lat_c44[e] = T.C44;
    }
  }

  // Penalized solve on the FIXED density to recover the displacement field. No
  // warm start and no cached solver is passed here. Solver selection matches the
  // originating run via `solver_kind`.
  //
  // *** THIS IS NOT A PURE FUNCTION OF ITS ARGUMENTS, AND THE COMMENT THAT SAID
  // SO WAS WRONG (task 2026-08-08-lattice-variant-margin-tolerance). *** The
  // Krylov recycling subspace (core/src/fea/recycle.cpp:83) is thread-local,
  // production-armed and deliberately carried BETWEEN solves, so two calls with
  // byte-identical arguments can take different Krylov paths and land at two
  // different points inside the same residual ball. The ladder's certification
  // runs with it warm; every re-certification runs with it disabled by
  // ScopedLadderSolverIsolation. Measured on the maintainer's own run: the
  // margins agree to nine significant figures and no further. That is why
  // "reproduces the recorded margin" is `margin_reproduces` (analyze.hpp) and not
  // `==`. With recycling DISARMED — the library default, which is what
  // test_analyze_fixed_design runs under — a re-analysis of the same field IS
  // bit-identical, and that test still asserts exactly that.
  //
  // Handoff 2026-07-27-nonconvergence-rejection — the certification solve runs at the
  // caller's tight `cg_tolerance`, UNCHANGED. If it fails to converge we do NOT soften
  // it, retry it, or let its throw abort the run: we record the failure and return an
  // analysis with `accepted` left FALSE. A design whose certification solve the CG
  // cannot resolve is never certified — the caller rejects that rung. Genuine
  // malformed-problem throws (bad index, void-only system) are NOT caught and still
  // propagate.
  SimpCompliance sc;
  // REAL BOLTS (bearing anchors, the reviewer's brief of 2026-10-25 20:10): which side
  // of each anchor presses is not known in advance, so solve, release the springs in
  // tension, and re-solve until the contact set stops changing, at most
  // kContactRounds solves. Glued anchors (no spring entry): one solve, as before.
  const int kContactRounds = kn.contact_rounds;   // 6 unless the strength check's settings say otherwise
  const bool bearing = has_contact_springs(bcs);
  std::vector<DirichletBC> contact_bcs;
  if (bearing) contact_bcs = bcs;
  const std::vector<DirichletBC>& B = bearing ? contact_bcs : bcs;
  // The voxels the solve held at the floor as LOOSE (empty when none, and on
  // every path that is not the matrix-free solve). With bearing anchors, the LAST
  // contact solve's: the set it was solved with is the one the field belongs to.
  std::vector<char> loose;
  try {
   for (;;) {
    loose.clear();
    if (has_lattice) {
      // Composite solve: solid voxels use the scalar-penalized isotropic modulus
      // E(rho) (bit-identical to what simp_compliance builds for them); latticed
      // voxels use their cubic tensor. This is the ASSEMBLED Jacobi-CG path
      // (fea_solve_cg_lattice) — the production accelerator paths (matrix-free,
      // multigrid) remain scalar-modulus, so a latticed certification is assembled
      // regardless of `solver_kind` (see the handoff's scope note). The gate still
      // runs at the caller's tight `cg_tolerance`, UNCHANGED.
      std::vector<double> elem_youngs(grid.voxel_count(), 0.0);
      for (int k = 0; k < grid.nz; ++k)
        for (int j = 0; j < grid.ny; ++j)
          for (int i = 0; i < grid.nx; ++i) {
            if (!grid.solid(i, j, k)) continue;
            const std::size_t e = grid.index(i, j, k);
            if (!lat_mask[e]) elem_youngs[e] = simp_youngs(params, density[e]);
          }
      sc.solution = fea_solve_cg_lattice(grid, elem_youngs, lat_mask, lat_c11,
                                         lat_c12, lat_c44, params.poisson, B,
                                         loads, cg_tolerance, cg_max_iterations,
                                         &sc.cg);
    } else {
      // THE CONNECTION RULE (ruling 2026-10-25), CERTIFIED: under this forbid
      // scope the matrix-free solve calls a piece LOOSE only if it is not even
      // 26-connected (edge / corner contacts included) to a support or a load —
      // the connectivity load_path_connected accepts the part on — so a piece
      // hinged to the body is solved at its true stiffness and its stress is
      // read here (review 2026-10-26, R4). A loose piece is solved at the floor
      // modulus and carries no load, so the stress loop below reads ZERO there
      // (at the floor its strain is the void's, which E_solid would turn into a
      // stress the piece does not carry).
      FeaIslandDropForbid no_island_drop;
      // TO rebuild stage 2 (ledger A-01): a voxel cut by the surface is solved at
      // the stiffness of the material it holds (E x fill), not E x fill^3, which
      // makes it far too soft and its stress far too high (76 % on the textbook
      // ring). Only with the stage's switch; the lattice posture above is untouched.
      // Reviewer's ruling 2026-11-26: real stiffness ALONE reads low (unsafe), so
      // in the shipped form ("size") it applies only together with a reading
      // size; a material with no published length keeps today's solve and
      // reading whole. "stiff" stays as a measuring arm only.
      // 2026-11-27 (the reviewer's ruling, item 2): in the size form the MAIN solve
      // stays today's, because thin members fall back to today's one-voxel reading;
      // the reading over a size gets its own real-stiffness solve further down.
      SimpParams solve_params = params;
      if (strength_mode() == StrengthMode::Stiff) solve_params.penalty = 1.0;
      sc = simp_compliance(grid, solve_params, density, B, loads, cg_tolerance,
                           cg_max_iterations, /*initial_guess=*/nullptr,
                           /*solver=*/nullptr, solver_kind);
      if (solver_kind == SolverKind::MultigridCG_Matfree) {
        const std::vector<int>& lv = fea_matfree_last_dropped_islands();
        if (!lv.empty()) {
          loose.assign(grid.voxel_count(), 0);
          for (int e : lv) loose[static_cast<std::size_t>(e)] = 1;
        }
      }
    }
    out.solve_iterations += sc.cg.iterations;
    out.solve_ms += sc.t_solve_ms;
    if (!bearing) break;
    ++out.contact_rounds;
    std::vector<DirichletBC> next = contact_bcs;
    const ContactUpdate cu = contact_update(next, sc.solution.u);
    std::fprintf(stderr, "[contact] certification solve %d: %d pressing, %d let go, %d changed%s\n",
                 out.contact_rounds, cu.engaged, cu.released, cu.changed,
                 cu.kept_last ? " (every anchor pulled away: last set kept)" : "");
    out.contact_kept_last = out.contact_kept_last || cu.kept_last;
    if (cu.changed == 0) break;  // settled: the field below is this set's
    if (out.contact_rounds >= kContactRounds) {
      out.contact_settled = false;  // reported, never passed silently
      break;
    }
    contact_bcs = std::move(next);
   }
  } catch (const SolverNonConvergence& e) {
    out.non_convergent = true;
    out.non_convergent_iteration = e.iterations;
    out.non_convergent_residual = e.residual;
    // Invariant (asserted, not commented): a non-converged certification solve can
    // NEVER yield an accepted design. `accepted` is default-false and the early
    // return leaves it untouched, below every gate.
    assert(out.accepted == false &&
           "non-convergence rejection: a failed certification solve must never "
           "certify a design");
    return out;
  }

  if (bearing) {
    // The set the field was solved with, and how much of the load its engaged
    // springs carry (the rest is the stabilisation's: near 1 when the supports hold).
    Vec3 R{0.0, 0.0, 0.0}, T{0.0, 0.0, 0.0}, F{0.0, 0.0, 0.0};
    for (const DirichletBC& b : contact_bcs) {
      if (!(b.spring > 0.0) || !b.contact) continue;
      if (b.released) { ++out.contact_released; continue; }
      ++out.contact_engaged;
      const std::size_t d = 3 * static_cast<std::size_t>(b.node);
      const std::vector<double>& u = sc.solution.u;
      const double un = u[d] * b.normal.x + u[d + 1] * b.normal.y + u[d + 2] * b.normal.z;
      R.x += b.spring * un * b.normal.x;
      R.y += b.spring * un * b.normal.y;
      R.z += b.spring * un * b.normal.z;
      T.x += b.spring_tangent * (u[d] - un * b.normal.x);
      T.y += b.spring_tangent * (u[d + 1] - un * b.normal.y);
      T.z += b.spring_tangent * (u[d + 2] - un * b.normal.z);
    }
    const Vec3 RT{R.x + T.x, R.y + T.y, R.z + T.z};
    const double rt = std::sqrt(RT.x * RT.x + RT.y * RT.y + RT.z * RT.z);
    out.contact_tangent_share =
        rt > 0.0 ? std::sqrt(T.x * T.x + T.y * T.y + T.z * T.z) / rt : 0.0;
    out.contact_held_by_sliding = out.contact_tangent_share > kn.sliding_share_max;
    for (const NodalLoad& l : loads)
      (l.component == 0 ? F.x : l.component == 1 ? F.y : F.z) += l.value;
    const double fm = std::sqrt(F.x * F.x + F.y * F.y + F.z * F.z);
    out.contact_load_share = fm > 0.0 ? std::sqrt(R.x * R.x + R.y * R.y + R.z * R.z) / fm : 0.0;
  }

  // Peak stresses over the PRINTED material (density > iso), using the solid
  // modulus. Empty/void voxels stay at zero stress. The per-voxel von Mises is
  // retained grid-indexed (M7.0b field (a)); printed voxels are counted for mass.
  std::vector<std::array<double, 6>> stress(grid.voxel_count(),
                                            std::array<double, 6>{});
  out.von_mises_field.assign(grid.voxel_count(), 0.0);
  out.stress_tensor_field.assign(6 * grid.voxel_count(), 0.0);
  const int node_count = fea_node_count(grid);
  std::vector<char> node_printed(static_cast<std::size_t>(node_count), 0);
  std::size_t printed_voxels = 0;
  double max_von_mises = 0.0;

  // --- Width-aware knockdown, part 1: the local member width (handoff
  // 2026-07-26-width-aware-knockdown). When armed, measure the printed field's local
  // thickness ONCE (bar K6) so the gate can credit the slicer's solid wall loops per
  // element. The OFF path never enters here and stays byte-identical. `max_von_mises_eff`
  // is the peak of the SOLID-EQUIVALENT von Mises vm/k(W) — dividing each voxel's
  // stress by its own width-aware knockdown inflates it to the stress a solid part
  // would show, so a thin walled rib (k→1, little inflation) and a thick region
  // (k→f^1.5, large inflation) compete for the worst effective point on the SAME
  // scale. This is what keeps caution on thick sections (bar K4): a thick region
  // whose real stress is only a fraction of the rib peak can still govern once
  // inflated by its small knockdown.
  std::vector<double> member_width_mm;
  double max_von_mises_eff = 0.0;
  // TO rebuild stage 2: the wall-aware stress per voxel, kept only when it is to
  // be read over a size (empty otherwise, so today's path allocates nothing).
  // TOPOPT_STRENGTH=surface does everything "size" does; it differs only where "size"
  // falls back to today's one-voxel reading (every new line sits under surface_mode).
  const bool surface_mode = strength_mode() == StrengthMode::Surface;
  const bool read_over_size =
      (strength_mode() == StrengthMode::Size || surface_mode) &&
      stress_is_read_over_size(knockdown.stress_reading_mm, grid.spacing);
  std::vector<double> von_mises_eff_field;
  if (read_over_size && knockdown.width_aware)
    von_mises_eff_field.assign(grid.voxel_count(), 0.0);
  if (knockdown.width_aware)
    member_width_mm = local_member_thickness_mm(grid, density, kIso,
                                                kn.thickness_cap_voxels);

  // Lattice accounting (all inert when has_lattice is false). `effective_material`
  // is the mass-bearing volume in voxel-equivalents: a solid printed voxel counts 1,
  // a latticed printed voxel counts its relative density (the lattice fills only that
  // fraction of the envelope). A latticed voxel's stress is the EFFECTIVE (macro)
  // stress and is EXCLUDED from the solid strength maxima (max_von_mises,
  // max_von_mises_eff) and from the interlayer field — its strut-level strength is read
  // by the per-type strut law below, not from the macro stress. It IS recorded in the fields.
  double effective_material = 0.0;
  std::size_t lattice_voxels = 0;
  double lat_rho_lo = 1e300, lat_rho_hi = -1e300, lat_max_vm = 0.0;

  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        const std::size_t idx = grid.index(i, j, k);
        if (!(density[idx] > kIso)) continue;
        ++printed_voxels;
        const bool is_lat = has_lattice && lat_mask[idx];
        const std::array<int, 8> en = fea_element_nodes(grid, i, j, k);
        for (int n : en) node_printed[static_cast<std::size_t>(n)] = 1;
        const std::array<double, 24> ue = element_dofs(grid, sc.solution, i, j, k);
        const std::size_t base = 6 * idx;
        if (is_lat) {
          // EFFECTIVE (macro) stress of the latticed element — its own cubic tensor.
          const Hex8Stress st = hex8_stress_cubic(lat_c11[idx], lat_c12[idx],
                                                  lat_c44[idx], grid.spacing, ue);
          out.von_mises_field[idx] = st.von_mises;
          for (int c = 0; c < 6; ++c)
            out.stress_tensor_field[base + static_cast<std::size_t>(c)] =
                st.sigma[static_cast<std::size_t>(c)];
          // `stress[idx]` stays zero -> excluded from interlayer. Excluded from the
          // solid strength maxima too. Tracked separately.
          ++lattice_voxels;
          const double rho = lattice->relative_density[idx];
          lat_rho_lo = std::min(lat_rho_lo, rho);
          lat_rho_hi = std::max(lat_rho_hi, rho);
          lat_max_vm = std::max(lat_max_vm, st.von_mises);
          effective_material += rho;
        } else if (!loose.empty() && loose[idx]) {
          // LOOSE: printed (it counts toward the mass) but connected through
          // solid to no support or load, so it carries no load: zero stress,
          // left out of the strength maxima and the interlayer field. The
          // export's bridge / item-47 rules decide what happens to it.
          effective_material += 1.0;
        } else {
          const Hex8Stress st = hex8_stress(params.youngs_modulus, params.poisson,
                                            grid.spacing, ue);
          stress[idx] = st.sigma;
          out.von_mises_field[idx] = st.von_mises;
          if (knockdown.width_aware) {
            // k_v in (0, 1] (wall_area_fraction in [0,1], core knockdown >= floor),
            // so vm/k_v never divides by zero and only ever inflates the stress.
            const double k_v = width_aware_knockdown(
                knockdown.infill_percent, member_width_mm[idx],
                knockdown.wall_thickness_mm, knockdown.infill_exponent,
                knockdown.infill_floor);
            const double vm_eff = st.von_mises / k_v;
            if (vm_eff > max_von_mises_eff) max_von_mises_eff = vm_eff;
            if (!von_mises_eff_field.empty()) von_mises_eff_field[idx] = vm_eff;
            // Record the pair this max was taken over, so a diagnosis can reprice
            // the SAME population at a candidate infill / wall ring without a
            // re-solve (handoff 2026-08-02-gate-diagnosis-recommendations). This
            // branch only ever runs in the width-aware posture, so the default
            // path is untouched and the vectors stay empty there.
            out.gate_printed_von_mises.push_back(st.von_mises);
            out.gate_printed_member_width_mm.push_back(member_width_mm[idx]);
          }
          for (int c = 0; c < 6; ++c)
            out.stress_tensor_field[base + static_cast<std::size_t>(c)] =
                st.sigma[static_cast<std::size_t>(c)];
          if (st.von_mises > max_von_mises) max_von_mises = st.von_mises;
          effective_material += 1.0;
        }
      }
  // TO rebuild stage 2 (ledger A-02): the stress that decides is read over the
  // material's length, not at one voxel. The one-voxel peak is kept beside it.
  // The wall-aware maximum (what production's gate reads) is read the same way.
  // Not yet done here: the interlayer reading (its length is a fifth of this one,
  // under a voxel so far).
  const double max_von_mises_one_voxel = max_von_mises;
  const int ndi[6] = {1, -1, 0, 0, 0, 0}, ndj[6] = {0, 0, 1, -1, 0, 0}, ndk[6] = {0, 0, 0, 0, 1, -1};
  // The stress of the MATERIAL in every voxel that holds some (printed voxels and
  // the voxels the surface cuts; stress_measure.hpp, "the edge of the part"), read
  // from `sol` with the full modulus. Lattice and loose voxels are left at zero.
  auto material_stress = [&](const decltype(sc.solution)& sol, std::vector<double>& vm,
                             std::vector<std::array<double, 6>>* tensor) {
    vm.assign(grid.voxel_count(), 0.0);
    if (tensor) tensor->assign(grid.voxel_count(), std::array<double, 6>{0, 0, 0, 0, 0, 0});
    for (int k = 0; k < grid.nz; ++k)
      for (int j = 0; j < grid.ny; ++j)
        for (int i = 0; i < grid.nx; ++i) {
          if (!grid.solid(i, j, k)) continue;
          const std::size_t idx = grid.index(i, j, k);
          if (!(density[idx] >= kStressMaterialFloor)) continue;
          if (has_lattice && lat_mask[idx]) continue;
          if (!loose.empty() && loose[idx]) continue;
          const Hex8Stress st = hex8_stress(params.youngs_modulus, params.poisson, grid.spacing,
                                            element_dofs(grid, sol, i, j, k));
          vm[idx] = st.von_mises;
          if (tensor) (*tensor)[idx] = st.sigma;
        }
  };
  // Tests ask for the material field of the solve they made (their own stiffness).
  if (knockdown.record_material_stress && !read_over_size)
    material_stress(sc.solution, out.von_mises_material_field, nullptr);

  // TO rebuild stage 2 (ledger A-02), THE SIZE FORM. The stress that decides is read
  // over the material's length where the member is thick enough for that reading to
  // mean something, and at one voxel by today's form where it is not:
  //   * the reading over a size comes from its OWN solve on real stiffness (E x
  //     fill), averaged over the size with the ball free to sit on the part's edge;
  //   * where the member under the ball is thinner than TWICE the size, the ball
  //     would reach across it (in bending it averages across the neutral line and
  //     reads low; the critical-distance method is not meant for sections as thin
  //     as its own length: Taylor 2007), so that voxel keeps TODAY'S solve and
  //     one-voxel reading (the reviewer's ruling 2026-11-27, item 2);
  //   * the wall-aware maximum and the across-layer check are read the same way.
  double max_interlayer = max_interlayer_tension(grid, stress, build_dir);
  const double max_interlayer_one_voxel = max_interlayer;
  bool size_form_used = false;
  if (read_over_size) {
    SimpParams real = params;
    real.penalty = 1.0;
    bool solved = true;
    SimpCompliance sc_real;
    try {
      sc_real = simp_compliance(grid, real, density, B, loads, cg_tolerance, cg_max_iterations,
                                /*initial_guess=*/nullptr, /*solver=*/nullptr, solver_kind);
    } catch (const SolverNonConvergence&) {
      solved = false;  // today's reading stands, whole
    }
    if (solved) {
      const double size = knockdown.stress_reading_mm;
      std::vector<double> vm_real;
      std::vector<std::array<double, 6>> tensor_real;
      material_stress(sc_real.solution, vm_real, &tensor_real);
      out.von_mises_material_field = vm_real;
      // How thick the member is at each voxel (the largest ball inside the part
      // that holds it); a cut voxel takes its thickest printed face neighbour's.
      // Measured HERE with the outside of the grid as air: the grid is the part's
      // bounding box, and with the default (outside not air) a member lying against
      // the box, or a part that fills it, reads as thick as the measure reaches and
      // would never fall back (found on the beam test, 2026-11-27).
      // CONVEX CORNERS JOIN THEIR MEMBER (lattice_member_width_mm, the rule made for
      // the lattice's cells-per-member floor): the largest ball that holds an edge
      // or corner voxel of a THICK member is small, so without this every edge of
      // every part read as thin and fell back (the beam test, 2026-11-27).
      const std::vector<double> width = lattice_member_width_mm(
          grid, density, kIso, kn.thickness_cap_voxels, kStressThinMemberSizes * size,
          grid.spacing);
      auto width_at = [&](int i, int j, int k) {
        const std::size_t idx = grid.index(i, j, k);
        if (density[idx] > kIso) return width[idx];
        double w = 0.0;
        for (int q = 0; q < 6; ++q) {
          const int a = i + ndi[q], b = j + ndj[q], c = k + ndk[q];
          if (a < 0 || b < 0 || c < 0 || a >= grid.nx || b >= grid.ny || c >= grid.nz) continue;
          const std::size_t u = grid.index(a, b, c);
          if (density[u] > kIso && width[u] > w) w = width[u];
        }
        return w;
      };
      // The wall-aware stress of the real-stiffness solve (a cut voxel takes the
      // knockdown of its thinnest-walled printed face neighbour).
      std::vector<double> eff_real;
      if (!von_mises_eff_field.empty()) {
        eff_real.assign(grid.voxel_count(), 0.0);
        for (int k = 0; k < grid.nz; ++k)
          for (int j = 0; j < grid.ny; ++j)
            for (int i = 0; i < grid.nx; ++i) {
              const std::size_t idx = grid.index(i, j, k);
              if (!(vm_real[idx] > 0.0)) continue;
              double k_v = 1.0;
              if (density[idx] > kIso) {
                k_v = width_aware_knockdown(knockdown.infill_percent, member_width_mm[idx],
                                            knockdown.wall_thickness_mm, knockdown.infill_exponent,
                                            knockdown.infill_floor);
              } else {
                bool found = false;
                for (int q = 0; q < 6; ++q) {
                  const int a = i + ndi[q], b = j + ndj[q], c = k + ndk[q];
                  if (a < 0 || b < 0 || c < 0 || a >= grid.nx || b >= grid.ny || c >= grid.nz)
                    continue;
                  const std::size_t u = grid.index(a, b, c);
                  if (!(density[u] > kIso)) continue;
                  const double kq = width_aware_knockdown(
                      knockdown.infill_percent, member_width_mm[u], knockdown.wall_thickness_mm,
                      knockdown.infill_exponent, knockdown.infill_floor);
                  if (!found || kq < k_v) k_v = kq;
                  found = true;
                }
              }
              eff_real[idx] = vm_real[idx] / k_v;
            }
      }
      // Each reading: the ball centred on voxel centres AND on the part's surface
      // nodes (stress_measure.hpp), the larger of the two voxel by voxel.
      auto over_size = [&](const std::vector<double>& f, double d) {
        std::vector<double> r = stress_over_size(grid, f, density, kStressMaterialFloor, d);
        const std::vector<double> s =
            stress_over_size_on_surface(grid, f, density, kStressMaterialFloor, d);
        for (std::size_t q = 0; q < r.size(); ++q)
          if (s[q] > r[q]) r[q] = s[q];
        return r;
      };
      const std::vector<double> r_vm = over_size(vm_real, size);
      const std::vector<double> r_eff =
          eff_real.empty() ? std::vector<double>() : over_size(eff_real, size);
      const double across_size = kAcrossLayerLengthFactor * size;
      const std::vector<double> r_across =
          over_size(interlayer_tension_field(grid, tensor_real, build_dir), across_size);
      const std::vector<double> across_today = interlayer_tension_field(grid, stress, build_dir);
      double m_vm = 0.0, m_eff = 0.0, m_across = 0.0;
      std::size_t thick = 0, thin = 0;
      // SURFACE: the voxels of thin members, read at the true surface below.
      std::vector<char> thin_only;
      if (surface_mode) thin_only.assign(grid.voxel_count(), 0);
      std::size_t surface_thin = 0;
      for (int k = 0; k < grid.nz; ++k)
        for (int j = 0; j < grid.ny; ++j)
          for (int i = 0; i < grid.nx; ++i) {
            const std::size_t idx = grid.index(i, j, k);
            if (!grid.solid(i, j, k) || !(density[idx] >= kStressMaterialFloor)) continue;
            const double w = width_at(i, j, k);  // +infinity = thicker than the measure reaches
            const bool printed = density[idx] > kIso;
            if (w >= kStressThinMemberSizes * size) {
              ++thick;
              m_vm = std::max(m_vm, r_vm[idx]);
              if (!r_eff.empty()) m_eff = std::max(m_eff, r_eff[idx]);
            } else if (printed) {
              ++thin;
              if (!surface_mode) m_vm = std::max(m_vm, out.von_mises_field[idx]);
              if (!von_mises_eff_field.empty()) m_eff = std::max(m_eff, von_mises_eff_field[idx]);
            }
            if (w >= kStressThinMemberSizes * across_size) m_across = std::max(m_across, r_across[idx]);
            else if (printed) m_across = std::max(m_across, across_today[idx]);
            if (surface_mode) {
              if (!(w >= kStressThinMemberSizes * size)) thin_only[idx] = 1;
              if (printed && w < kSurfaceResolvedThroughVoxels * grid.spacing) ++surface_thin;
            }
          }
      if (surface_mode) {
        // SURFACE: the thin members' voxels are read on the real-stiffness solve at the
        // true surface (shape 1), not by today's solve at one voxel.
        const SurfaceCarry sc_surf =
            stress_carried_to_surface(grid, vm_real, density, 1, &thin_only);
        m_vm = std::max(m_vm, sc_surf.peak);
        out.surface_tight_points = sc_surf.tight_points;
        out.surface_unresolved_points = sc_surf.unresolved;
        out.surface_loaded_points = sc_surf.loaded_points;
        out.surface_read_peak = sc_surf.peak;
        out.surface_thin_voxels = surface_thin;
      }
      max_von_mises = m_vm;
      if (!von_mises_eff_field.empty()) max_von_mises_eff = m_eff;
      if (max_interlayer > 0.0) max_interlayer = m_across;
      size_form_used = thick > 0;
      out.stress_thin_member_voxels = thin;
      out.stress_thick_member_voxels = thick;
    }
  }
  // SURFACE, the whole part under the switch point (where "size" keeps today's solve
  // and one-voxel reading whole): the real-stiffness solve read at the true surface.
  if (surface_mode && !read_over_size) {
    SimpParams real = params;
    real.penalty = 1.0;
    bool solved = true;
    SimpCompliance sc_real;
    try {
      sc_real = simp_compliance(grid, real, density, B, loads, cg_tolerance, cg_max_iterations,
                                /*initial_guess=*/nullptr, /*solver=*/nullptr, solver_kind);
    } catch (const SolverNonConvergence&) {
      solved = false;  // today's reading stands, whole
    }
    if (solved) {
      std::vector<double> vm_real;
      material_stress(sc_real.solution, vm_real, nullptr);
      out.von_mises_material_field = vm_real;
      const SurfaceCarry sc_surf = stress_carried_to_surface(grid, vm_real, density, 1);
      max_von_mises = sc_surf.peak;
      out.surface_tight_points = sc_surf.tight_points;
      out.surface_unresolved_points = sc_surf.unresolved;
      out.surface_loaded_points = sc_surf.loaded_points;
      out.surface_read_peak = sc_surf.peak;
      // Member widths exist on this path only in the wall-aware posture.
      if (!member_width_mm.empty())
        for (std::size_t idx = 0; idx < density.size(); ++idx)
          if (density[idx] > kIso && grid.tags[idx] != VoxelTag::Empty &&
              member_width_mm[idx] < kSurfaceResolvedThroughVoxels * grid.spacing)
            ++out.surface_thin_voxels;
    }
  }
  (void)max_interlayer_one_voxel;

  // Per-node displacement of the SAME solve — no new solve. DOF-ordered; exposed
  // on printed nodes exactly as solved, zeroed on nodes attached only to
  // non-printed voxels (mirrors von_mises_field). Model units (mm).
  out.displacement_field.assign(static_cast<std::size_t>(3 * node_count), 0.0);
  for (int n = 0; n < node_count; ++n) {
    if (!node_printed[static_cast<std::size_t>(n)]) continue;
    for (int c = 0; c < 3; ++c)
      out.displacement_field[static_cast<std::size_t>(3 * n + c)] =
          sc.solution.at(n, c);
  }

  // With a stress view the printed counts come from the design itself, not the
  // view (no lattice here: a view is ignored when one is given).
  if (use_view) {
    printed_voxels = 0;
    effective_material = 0.0;
    for (std::size_t idx = 0; idx < density_in.size(); ++idx)
      if (grid_in.tags[idx] != VoxelTag::Empty && density_in[idx] > kIso) {
        ++printed_voxels;
        effective_material += 1.0;
      }
  }
  // Printed mass = material density (g/cm^3) * printed volume. Volumes are mm^3;
  // 1 cm^3 = 1000 mm^3, so divide by 1000 to land in grams. Spacing-aware.
  // `effective_material` is the mass-bearing volume in voxel-equivalents: a solid
  // printed voxel contributes 1, a latticed one contributes its relative density.
  // With no lattice region it equals printed_voxels exactly (a sum of 1.0's), so the
  // mass is byte-identical to the pre-lattice path.
  out.mass_grams = material.density_g_cm3 *
                   (effective_material * grid.voxel_volume()) / 1000.0;
  // TO rebuild stage 2 (ledger M-07; the maintainer, 2026-11-25: "Never the solid
  // unless the user set infill to 100%"): the grams really printed at the job's
  // walls and infill, by the same wall-and-core model the margin uses. Only with
  // the stage's switch, only where the member widths were measured (the
  // wall-aware posture) and no voxel is lattice (a lattice's mass is its own
  // relative density, counted above). The solid figure is kept beside it.
  out.mass_grams_solid = out.mass_grams;
  if (to_stage2_on() && lattice_voxels == 0) {
    // The shell model (printed_mass.hpp): walls by distance from the side surface,
    // solid skins under up-facing and over down-facing surfaces, the rest at the
    // infill. Within 3 % of a real slicer on the made sample bracket. The skins
    // are counted only when the part is printed along the grid's z (a tilted
    // build direction gets walls only, which reads a little low). Skin
    // thicknesses are the job's own when it states them, else the slicer's usual ones.
    std::vector<double> printed_density(density_in.size(), 0.0);
    for (std::size_t idx = 0; idx < density_in.size(); ++idx)
      if (grid_in.tags[idx] != VoxelTag::Empty && density_in[idx] > kIso) printed_density[idx] = 1.0;
    const double blen = std::sqrt(build_dir.x * build_dir.x + build_dir.y * build_dir.y +
                                  build_dir.z * build_dir.z);
    const bool along_z = blen > 0.0 && std::fabs(build_dir.z) > 0.99 * blen;
    const bool up = build_dir.z >= 0.0;
    // The job's own skins when it states them (#362's notes30 keys), else the usual.
    const double skin_top = knockdown.top_skin_mm >= 0.0 ? knockdown.top_skin_mm : kStage2TopSkinMm;
    const double skin_bottom =
        knockdown.bottom_skin_mm >= 0.0 ? knockdown.bottom_skin_mm : kStage2BottomSkinMm;
    const double top_mm = along_z ? (up ? skin_top : skin_bottom) : 0.0;
    const double bottom_mm = along_z ? (up ? skin_bottom : skin_top) : 0.0;
    out.mass_grams = printed_mass_shell(grid_in, printed_density, 0.5, knockdown.wall_thickness_mm,
                                        top_mm, bottom_mm, knockdown.infill_percent,
                                        material.density_g_cm3)
                         .grams;
  }

  // Support-volume proxy for the analysed build direction over THIS design's
  // printed geometry: mark non-printed voxels Empty in a copy and count overhangs.
  VoxelGrid printed_grid = grid_in;
  for (std::size_t idx = 0; idx < printed_grid.tags.size(); ++idx)
    if (!(density_in[idx] > kIso)) printed_grid.tags[idx] = VoxelTag::Empty;
  out.support_volume_voxels = support_overhang_voxels(printed_grid, build_dir);

  // Printed / thresholded count basis (the SAME voxel count the reported mass is
  // built from): #{density>0.5} / part_solid.
  const double printed_fraction =
      part_solid > 0.0 ? static_cast<double>(printed_voxels) / part_solid : 0.0;

  // Worst-case stress margin (M5.2 locked definition).
  const StressMargin margin = compute_stress_margin(
      material.yield_strength_mpa, material.z_knockdown, max_von_mises,
      max_interlayer);

  // §7 V3 property suite on this fixed design (min-feature count, watertight mesh).
  out.v3 = check_v3(grid_in, density_in, kIso);

  // Gate on the INFILL-ADJUSTED worst-case margin (the stored/displayed margin
  // stays the SOLID margin; the knockdown scales ONLY what the acceptance test
  // compares). THE CONNECTIVITY BELT ACTS HERE: a severed design is rejected however
  // good its (meaningless, near-zero-stress) margin.
  const double margin_effective = gate_margin_effective(
      material.yield_strength_mpa, material.z_knockdown, max_von_mises,
      knockdown.width_aware ? max_von_mises_eff : max_von_mises, max_interlayer,
      knockdown);
  const bool margin_ok = margin_effective >= margin_stop;

  out.printed_voxels = printed_voxels;
  out.printed_fraction = printed_fraction;
  out.max_von_mises = max_von_mises;
  out.max_von_mises_one_voxel = max_von_mises_one_voxel;
  out.stress_read_over_mm = size_form_used ? knockdown.stress_reading_mm : 0.0;
  out.max_interlayer_tension = max_interlayer;
  out.margin = margin;
  out.margin_effective = margin_effective;
  out.margin_effective_solid_only = margin_effective;
  out.accepted = load_path_ok && margin_ok;

  // Lattice reporting (all default when no posture was applied). `margin`/`accepted`
  // above are the SOLID region's strength over the real composite field; the lattice
  // region contributed its true (softer) stiffness to that field; its strut-level
  // strength is the strut law's (below), gated only as FixedDesignAnalysis says.
  if (has_lattice) {
    out.lattice_certified = true;
    out.lattice_topology = lattice->topology;
    out.lattice_cell_size_mm = lattice->cell_size_mm;
    out.lattice_voxels = lattice_voxels;
    out.lattice_rho_min = lattice_voxels ? lat_rho_lo : 0.0;
    out.lattice_rho_max = lattice_voxels ? lat_rho_hi : 0.0;
    out.lattice_max_effective_vm = lat_max_vm;
    out.lattice_strength_uncertified = (lattice_voxels > 0);

    // --- Strut-strength REPORT (task 2026-07-31-lattice-strut-strength-report).
    // REPORT ONLY, evaluated strictly AFTER `accepted`/`margin_effective` were
    // sealed above: the measured PR 259 law (strut_strength.hpp) applied to the
    // latticed voxels' macro stress TENSORS from this same solve. Each type with
    // its OWN measured law (strut_law_measured; ruling 11-08 (B)) is evaluated
    // from it; a type without one reports nothing (and 2(a) below says so). The build
    // direction is passed through EXPLICITLY (bar L8) — the evaluator never reads
    // it from options, so an orientation scorer can re-call it per direction.
    if (lattice_voxels > 0 && strut_law_measured(lattice->topology)) {
      out.lattice_strut = evaluate_strut_strength(
          lattice->topology, out.stress_tensor_field, lat_mask, lattice->relative_density,
          build_dir, material.yield_strength_mpa, material.z_knockdown);
      out.lattice_strut_report = out.lattice_strut.evaluated;
      // Cells-per-member regime guard (bar L4): thinnest LATTICED member's span
      // in cells vs the floor homogenization needs. Reuses the width-aware
      // thickness field when that posture already measured it.
      if (lattice->cell_size_mm > 0.0) {
        // ★ The width the grading law measured on the part's own surface, when it did
        // (ruling 11-09): the staircase reads the steps of a curved face as thin
        // members. Else the staircase, as before.
        // ★ Rulings 11-09: the grading law's own width when the posture carries it; else
        // the same measure (lattice_member_width_mm: the grid's outside void, convex
        // corners joined to their member). Never the knockdown's field, which keeps its
        // old, conservative reading.
        const bool own_widths = lattice->member_width_mm.size() == lat_mask.size();
        std::vector<double> guard_own;
        if (!own_widths)
          guard_own = lattice_member_width_mm(
              grid, density, kIso, kn.thickness_cap_voxels,
              lattice_cells_per_member_min(lattice->topology) * lattice->cell_size_mm,
              lattice->cell_size_mm);
        const std::vector<double>& guard_width =
            own_widths ? lattice->member_width_mm : guard_own;
        // SWEPT postures (handoff 2026-08-01-lattice-cell-size-sweep) carry a
        // per-voxel cell size, and then the honest question is each voxel's span at
        // ITS OWN cell rather than one number for the part. An EMPTY field is the
        // uniform posture and this is the scalar test, byte-for-byte as before.
        const bool per_voxel_cell =
            lattice->cell_size_field.size() == lat_mask.size();
        double min_cpm = std::numeric_limits<double>::infinity();
        for (std::size_t e = 0; e < lat_mask.size(); ++e) {
          if (!lat_mask[e] || !(density[e] > kIso)) continue;
          const double ce = per_voxel_cell ? lattice->cell_size_field[e]
                                           : lattice->cell_size_mm;
          if (!(ce > 0.0)) continue;
          const double cpm = guard_width[e] / ce;
          if (cpm < min_cpm) min_cpm = cpm;
        }
        out.lattice_min_cells_per_member = min_cpm;
        out.lattice_strut_out_of_regime =
            min_cpm < lattice_cells_per_member_min(lattice->topology);
      }

      // ── ★ THE STRUT TERM IN THE GATE (task 2026-08-13-lattice-as-a-material,
      // §1c). OFF by default, and bar L1 stands for every caller that leaves it
      // off: the block above is a report and `accepted` is already sealed.
      //
      // Armed, the acceptance test takes the WORSE of the solid region's
      // effective margin and the measured de-homogenised strut bound, so a
      // latticed region can no longer pass by not being looked at. Nothing else
      // is recomputed — this is a `min` over two numbers the same solve already
      // produced — and `margin_effective_solid_only` keeps the number the gate
      // would have used, so the term's cost is on the receipt rather than folded
      // invisibly into one figure.
      //
      // The out-of-regime case is NOT special-cased here into a pass: if the
      // homogenisation floor is missed, `lattice_strut_out_of_regime` is set and
      // the CALLER refuses on it. Quietly widening the gate for a region whose
      // macro stress is out of regime would be this term pretending to certify
      // something it cannot.
      if (gate_on_strut_strength && out.lattice_strut_report) {
        out.strut_gated = true;
        out.lattice_strength_uncertified = false;
        const double strut_margin = out.lattice_strut.margin_worst_case;
        if (strut_margin < out.margin_effective)
          out.margin_effective = strut_margin;
        out.accepted = load_path_ok && (out.margin_effective >= margin_stop);
      }
    }
  }

  // --- BUILD-ORIENTATION RANKING (handoff 2026-08-01-build-direction-separation)
  // A POST-PASS. It runs LAST, after `accepted` and `margin_effective` above were
  // sealed from `build_dir` — the orientation ACTUALLY USED — and it writes only
  // to `out.build_orientation`. That ordering is the whole safety property (bar
  // U5): the verdict this analysis reports can never be the verdict of an
  // orientation the caller did not choose.
  //
  // It re-reads what the solve already produced (`stress`, `printed_grid`,
  // `out.stress_tensor_field`, `lat_mask`, `max_von_mises`, the V3 count) and
  // re-solves nothing. PR 266 proved that exact: `build_dir` enters this function
  // at three places, ALL after the solve, and the element stiffness never reads it.
  if (score_build_orientation) {
    // The candidate set is derived HERE, from the one function every path calls,
    // so a run's report, its lattice receipt and a later re-analysis rank the
    // identical set (PR 266's S5 inconsistency risk).
    const std::vector<Vec3> candidates = build_orientation_candidates(build_dir);
    const BuildOrientationSolveFacts facts{
        grid,
        printed_grid,
        stress,
        out.stress_tensor_field,
        max_von_mises,
        knockdown.width_aware ? max_von_mises_eff : max_von_mises,
        out.v3.min_feature_violations,
        lattice,
        has_lattice ? &lat_mask : nullptr,
        lattice_voxels};
    out.build_orientation = score_build_orientations(
        facts, candidates, build_dir, material, knockdown, margin_stop,
        load_path_ok, build_direction_inferred);
    // The gate is computed from the orientation ACTUALLY USED, never from the
    // recommendation. Asserted, not merely commented (bar U5): the as-built row's
    // priced verdict must agree with the verdict this analysis reports, because
    // both come from gate_margin_effective on the same `build_dir`.
    assert(out.build_orientation.candidates[out.build_orientation.as_built_index]
                   .would_be_accepted == out.accepted &&
           "U5: the reported verdict must be the as-built orientation's verdict");

    // ── AUTO-APPLY: THE RECOMMENDATION BECOMES THE ORIENTATION ────────────────
    // (handoff 2026-08-01-bake-build-orientation.) Armed ONLY when the caller's
    // bake plan says so, which in turn requires that NO build direction was
    // declared. PR 271's U5 rule — "a recommendation never silently changes a
    // verdict" — is intact in the word that carries it: SILENTLY. Here the
    // orientation is applied, the verdict is recomputed FOR THE ORIENTATION THE
    // FILE WILL BE IN, and the receipt is required to say so (bar V7).
    //
    // What re-seals: exactly the fields that depend on the build direction. They
    // are taken from the candidate row the scorer ALREADY priced, so there is no
    // second arithmetic path to drift from the gate — the row's number IS the
    // gate's number, by construction (gate_margin_effective).
    if (auto_apply_build_orientation) {
      if (!build_direction_inferred)
        throw std::invalid_argument(
            "analyze_fixed_design: auto_apply_build_orientation requires an "
            "UNDECLARED build direction — a recommendation may never override a "
            "direction the user chose");
      apply_recommended_orientation(&out.build_orientation);
      const OrientationCriteria& applied =
          out.build_orientation.candidates[out.build_orientation.as_built_index];
      out.applied_build_dir = applied.build_dir;
      out.build_direction_auto_applied = true;

      // The direction-dependent gate outputs, re-sealed at the applied
      // orientation. `margin` is recomputed through compute_stress_margin so the
      // ONE margin definition still owns it; the assert below pins it against
      // the scorer's independently-carried copy of the same numbers.
      out.max_interlayer_tension = applied.macro_interlayer_tension_mpa;
      out.margin = compute_stress_margin(material.yield_strength_mpa,
                                         material.z_knockdown, max_von_mises,
                                         out.max_interlayer_tension);
      out.margin_effective = applied.margin_effective;
      out.margin_effective_solid_only = applied.margin_effective;
      out.accepted = applied.would_be_accepted;
      out.support_volume_voxels = applied.support_voxels;
      assert(out.margin.interlayer == applied.macro_interlayer_margin &&
             out.margin.worst_case == applied.macro_worst_case_margin &&
             "the re-sealed margin must equal the row the scorer priced");
      assert(out.build_orientation.candidates[out.build_orientation.as_built_index]
                     .would_be_accepted == out.accepted &&
             "U5 still holds after auto-apply: the reported verdict is the "
             "as-built (now: the APPLIED) orientation's verdict");

      // The strut REPORT is direction-bearing too (its interlayer term is), so
      // it is re-evaluated at the applied direction by the SAME evaluator. The
      // in-plane term is invariant and comes back identical — U7's own check.
      if (out.lattice_strut_report) {
        out.lattice_strut = evaluate_strut_strength(
            lattice->topology, out.stress_tensor_field, lat_mask, lattice->relative_density,
            out.applied_build_dir, material.yield_strength_mpa,
            material.z_knockdown);
        out.lattice_strut_report = out.lattice_strut.evaluated;
      }
      // ★ AND THE STRUT TERM GOES BACK IN. The scorer's candidate row prices the
      // SOLID-region gate expression only, so the re-seal three lines up would
      // otherwise DROP the strut term that `gate_on_strut_strength` put in — a
      // latticed part would be gated at one orientation and not at the one it is
      // actually certified at. Re-folded here, from the report just re-evaluated
      // at the APPLIED direction, so the two features compose instead of one
      // silently undoing the other.
      if (out.strut_gated && out.lattice_strut_report) {
        const double strut_margin = out.lattice_strut.margin_worst_case;
        if (strut_margin < out.margin_effective)
          out.margin_effective = strut_margin;
        out.accepted = load_path_ok && (out.margin_effective >= margin_stop);
      }
      // NOTHING ELSE MOVES. von_mises_field, stress_tensor_field,
      // displacement_field, mass_grams, printed_voxels/fraction, max_von_mises,
      // v3, the lattice rho/cells-per-member accounting and the non-convergence
      // flags are all independent of the build direction — PR 266 measured that
      // over 15 full re-solves — so they are already correct for the applied
      // orientation and are deliberately left alone.
    }
  }
  // ── ★ A LATTICE IS NEVER "MARGIN INF, ACCEPTED" (ruling 11-06 2(a)) ──────────
  // The margin above is the SOLID region's; latticed voxels are left out of it. With
  // no solid voxel under stress it is unbounded, and a part latticed through read
  // "margin inf, ACCEPTED" without its lattice ever being looked at (1,536 of 1,536
  // voxels latticed, test_lattice_no_solid). There the latticed voxels carry the load,
  // so they are certified by the measured strut law over the posture this solve read
  // (on the run path, each voxel at min(the law's density, what the file holds)),
  // folded in exactly as `gate_on_strut_strength` folds it. Where the law cannot apply
  // (no measured law for the type, or below the cells-per-member floor) the answer is
  // NOT CERTIFIED, in words. Last, after the orientation post-pass, so the scorer's
  // as-built row still matches the verdict it priced; a job with any solid voxel under
  // stress never enters.
  if (has_lattice && out.lattice_voxels > 0 &&
      !std::isfinite(out.margin_effective_solid_only)) {
    const char* type = lattice_topology_name(lattice->topology);
    char why[400];
    why[0] = '\0';
    if (!out.lattice_strut_report) {
      std::snprintf(why, sizeof why,
                    "Not certified: no solid part carries the load, so the lattice's own "
                    "strength decides, and %s has no measured strut-strength law to check "
                    "it with.",
                    type);
    } else if (out.lattice_strut_out_of_regime) {
      std::snprintf(why, sizeof why,
                    "Not certified: no solid part carries the load, so the lattice's own "
                    "strength decides, and its thinnest latticed member is %.1f cells "
                    "across, below the %.0f the strut-strength law is valid for.",
                    out.lattice_min_cells_per_member,
                    lattice_cells_per_member_min(lattice->topology));
    } else if (!out.strut_gated) {
      out.strut_gated = true;
      out.lattice_strength_uncertified = false;
      out.margin_effective = out.lattice_strut.margin_worst_case;
      out.accepted = load_path_ok && (out.margin_effective >= margin_stop);
    }
    if (why[0] != '\0') {
      out.lattice_not_certified = true;
      out.lattice_not_certified_reason = why;
      out.accepted = false;
    }
  }
  // REAL BOLTS: anchors that hold the load only through the weak sliding springs are
  // no support at all in that direction, so no margin measured on them is a pass.
  if (out.contact_held_by_sliding) out.accepted = false;
  return out;
}

}  // namespace topopt
