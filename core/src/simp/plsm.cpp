// plsm.cpp — THE PARAMETRIC LEVEL-SET OPTIMISER, on the production path.
//
// See plsm.hpp for what this is and why it exists. This file is the loop; the
// basis, the field kernel and the coefficient-space MMA step are in
// `topopt/plsm_basis.hpp`, `topopt/plsm_kernel.hpp` and `topopt/plsm_mma.hpp` —
// the SAME headers `plsm_probe` and `levelset_probe --plsm` use, so there is one
// implementation of the representation in the repository and not two.
//
// ★ WHAT IS CARRIED ACROSS FROM PR 324's ARM 2, AND WHAT IS NOT.
//
// CARRIED: the seed fit, the volume offset added to EVERY COEFFICIENT (so phi
// stays inside the span of the basis), the surface-delta shape derivative, the
// delta-weighted multiplier, the projection onto the basis by one transpose
// apply, MMA on the coefficients with the move limit DERIVED from interface
// motion, and the approximate re-initialisation. Each of those is a measured
// decision in that handoff's §6 and §9; none is re-decided here.
//
// NOT CARRIED, and each says why at its site: the Hamilton-Jacobi advection (the
// coefficient step IS the motion), the Hilbertian extension (a no-op under MMA —
// PR 324 measured it matching the control to twelve digits, because MMA consumes
// SENSITIVITIES and the extension produces a DESCENT DIRECTION), and the hard
// stamp of the frozen mask (S1(b): it is a smooth boolean, mandatorily).
//
// ★ TWO THINGS ARE DELIBERATELY DIFFERENT FROM THE PROBE, because production has
// a contract the probe does not:
//
//   (1) THE VOLUME CONSTRAINT IS SIMP'S. The probe targets `rung * part_solid`
//       over every non-Empty voxel. `simp_optimize`'s mask-aware overload targets
//       `volume_fraction * n_active` over the ACTIVE set, with the frozen solid
//       outside the budget. A ladder rung has to mean the same thing on both
//       paths or the ladder is comparing two different requests, so this file
//       uses simp's.
//
//   (2) THE FROZEN VOID IS THE KEEP-OUTS, NOT THE EMPTY SPACE. PR 324's boolean
//       put Empty voxels into the frozen-VOID distance, which pulls the ersatz
//       down to 0.74 in the part's own outermost solid layer and moves the
//       exported skin inward by ~0.2 voxels — a CAD-error cost with nothing to
//       buy. Empty is not a keep-out the optimiser must respect; it is OUTSIDE
//       THE DOMAIN, contributes no element, and every other path in this
//       repository writes 0 there. So it is 0 here too, and the smooth boolean
//       governs the sets that are genuinely INSIDE the domain and frozen: the
//       load pad, the anchor, the face protection, the clearances and any
//       design-box keep-out.

#include "topopt/plsm.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <string>

#include "topopt/plsm_frac.hpp"
#include "topopt/plsm_kernel.hpp"
#include "topopt/plsm_mma.hpp"
#include "topopt/plsm_topology.hpp"

namespace topopt {
namespace {

double steady_s() {
  return std::chrono::duration<double>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

// ── ★★ THE TWO COMPLIANCE WEIGHTS, AND WHY THE DEFAULT CHANGED ─────────────
//
// The measure (`delta`) says WHERE the boundary moves; the weight says WHAT THAT
// COSTS. They are separate choices and only one of them was ever verified.
//
// `energy_from` is the CONTINUUM one: the strain-energy density `q E0` that the
// classical shape derivative integrates, recovered from core's `dcompliance`.
// It is correct when material appears across the interface as a 0 -> 1 JUMP —
// which is the continuum picture, and which is also the DISCRETE picture when
// the stiffness law is linear. GridapTopOpt's is: E(rho) = rho E0, p = 1.
//
// ★★ PRODUCTION'S IS NOT. The trajectory runs SIMP at penalty p = 3, so the
// derivative of the ersatz compliance the solver actually minimises is
//
//     dC/dalpha_i = SUM_v (dC/drho_v) (1 - rho_min) d f_v/d alpha_i
//
// and the continuum weight differs from it by a per-voxel factor
// `p (1 - rho_min) rho_v^(p-1)` — about 0.75 at rho = 0.5, and VARYING across
// the band, so it is not even a constant rescaling a step size could absorb.
//
// ★★ R2 MEASURED IT AND IT IS LARGE: on this part the continuum weight
// finite-differences at +56.0% and +45.0% on two random directions, FLAT to five
// digits across a factor of ten in step size, while the discrete weight reads
// −0.31% and +0.97% on the same directions and the same solves. Flatness is what
// makes it a gradient error rather than noise — the criterion PR 327 established
// for the `|grad phi|` defect, applied to the other half of the same expression.
//
// ★ AND SINGLE COEFFICIENTS DO NOT SHOW IT: the continuum weight reads 6-7%
// there against the discrete form's 1.5-1.8%. This is the same trap PR 327's
// sub-cell-psi ablation fell into — a single-coefficient check would have passed
// it. Only a general direction, where many knots combine over the band, separates
// the two.
//
// So `PlsmSensWeight::Discrete` is the default and `Continuum` is kept reachable,
// because it is what PR 324/325/326/327 and the shipped `--plsm` mode all ran and
// the control arm has to be able to reproduce it exactly.
double energy_from(double dc, double rho, double p, double e0) {
  const double r = std::max(rho, 0.1);
  return -dc / (p * std::pow(r, p - 1.0) * e0);
}

// The DISCRETE weight: the derivative of the ACTUAL stiffness law. `dc` is
// `dC/drho_v` as core computes it, and `rho = rho_min + (1 - rho_min) * f_v`, so
// `drho/df = 1 - rho_min`. The sign is flipped for the same reason
// `energy_from`'s is — the scatter's convention is that a POSITIVE weight is
// material coming IN.
double discrete_weight_from(double dc, double rho_min) {
  return -dc * (1.0 - rho_min);
}

PlsmBasisKind parse_basis(const std::string& s) {
  if (s == "gaussian") return PlsmBasisKind::Gaussian;
  if (s == "wendland") return PlsmBasisKind::Wendland;
  throw std::invalid_argument(
      "plsm_optimize: basis must be \"gaussian\" or \"wendland\", got \"" + s +
      "\"");
}

}  // namespace

// ── THE PRODUCTION KNOT LATTICE ─────────────────────────────────────────────
//
// ★ R4 — PER AXIS, AND NOT A MINIMUM OVER THEM. The rule is stated as a rule and
// not as a number, because the number that ships has to follow the grid: a job
// at resolution 192 has voxels 1.5x smaller and a spacing of "2 voxels" would be
// a 1.5x finer FEATURE SCALE at the same nominal setting, which is not what a
// production default should mean.
//
// THE RULE: the knot spacing is a LENGTH — the smallest structure the basis can
// express — held at kPlsmKnotMm millimetres, converted to voxels on each axis
// through that axis's own spacing, and floored at 2 voxels so the basis can
// never out-resolve the lattice its ersatz is sampled on. The voxels are cubic,
// so the three numbers come out equal on every grid this repository makes; they
// are carried separately anyway, because the day a non-cubic voxel exists the
// rule must not silently start reading one axis.
//
// ★ NOTHING HERE TAKES A MINIMUM OR A MAXIMUM OVER THE AXES. That is the trap
// PR 323 lost a day to (GridapTopOpt's alpha rule reads `minimum(el_size)` and
// sized a regularity length for a 31³ mesh on his 128 x 31 x 118 slab) and the
// one PR 324 reproduced on purpose to measure. A rule keyed to the EXTENT of the
// thin axis would give 1 voxel on a 128 x 8 x 118 slab and blow the coefficient
// count past the voxel count; a rule keyed to the SPACING cannot, because the
// spacing is a property of the voxel and not of the part's aspect ratio.
//
// The VALUE — 3.4 mm, two voxels at his production resolution — is the S2
// frontier's chosen point. See the task handoff for the four lattices it was
// chosen from and what each cost on carved roughness, margin and mass.
namespace {
constexpr double kPlsmKnotMm = 3.410558;  // = 2 x 1.705279 mm, his voxel
constexpr double kPlsmKnotMinVoxels = 2.0;
}  // namespace

PlsmKnots plsm_knots_for_grid(const VoxelGrid& grid) {
  const double h = grid.spacing;
  const double per_axis =
      h > 0.0 ? std::max(kPlsmKnotMinVoxels, kPlsmKnotMm / h) : kPlsmKnotMinVoxels;
  PlsmKnots k;
  k.dx = per_axis;
  k.dy = per_axis;
  k.dz = per_axis;
  return k;
}

// ── THE FROZEN SET AS A SMOOTH BOOLEAN ──────────────────────────────────────
PlsmFrozenBoolean plsm_build_frozen_boolean(const VoxelGrid& grid,
                                            const DesignMask& effective,
                                            int sweeps) {
  const std::size_t n = grid.voxel_count();
  if (effective.size() != n)
    throw std::invalid_argument(
        "plsm_build_frozen_boolean: mask size != voxel_count");
  PlsmFrozenBoolean fb;
  fb.phi_solid.assign(n, 0.0);
  fb.phi_void.assign(n, 0.0);
  const double h = grid.spacing;
  fb.spacing_mm = h;
  for (std::size_t v = 0; v < n; ++v) {
    const bool empty = grid.tags[v] == VoxelTag::Empty;
    const bool solid = !empty && effective[v] == MaskValue::FrozenSolid;
    // ★ EMPTY IS NOT A KEEP-OUT (see the file header). A voxel outside the part
    // contributes no element and is written 0 unconditionally below; folding it
    // into the void distance would carve the part's own skin for nothing.
    const bool keepout = !empty && effective[v] == MaskValue::FrozenVoid;
    // Half a voxel is the only defensible signed distance for a cell-centred
    // indicator: the boundary runs through the shared face.
    fb.phi_solid[v] = solid ? -0.5 * h : 0.5 * h;
    fb.phi_void[v] = keepout ? -0.5 * h : 0.5 * h;
    if (solid) ++fb.n_solid;
    if (keepout) ++fb.n_void;
    if (!empty && effective[v] == MaskValue::Active) ++fb.n_active;
  }
  // The SAME reinitialisation the optimiser's own re-fit uses, so the frozen
  // boundary and the design boundary are described by one distance function and
  // not by two conventions.
  plsm_reinitialise(grid.nx, grid.ny, grid.nz, fb.phi_solid, h, sweeps, false);
  if (fb.n_void > 0)
    plsm_reinitialise(grid.nx, grid.ny, grid.nz, fb.phi_void, h, sweeps, false);
  return fb;
}

double plsm_frozen_floor_occupancy(const PlsmFrozenBoolean& fb, double eta_voxels) {
  if (fb.n_solid == 0) return 1.0;  // nothing frozen: the guarantee is vacuous
  // phi_eff <= phi_solid at every frozen-solid voxel BY CONSTRUCTION (it is a
  // `min`), so the worst case is the LARGEST phi_solid over that set — the
  // shallowest frozen voxel — and the floor is H_eta of its negation.
  double worst = -std::numeric_limits<double>::infinity();
  for (std::size_t v = 0; v < fb.phi_solid.size(); ++v)
    if (fb.phi_solid[v] < 0.0) worst = std::max(worst, fb.phi_solid[v]);
  if (!(worst > -std::numeric_limits<double>::infinity())) return 1.0;
  // `worst` and eta are both in the field's own length unit (mm): the distances
  // were built with the grid spacing, so eta_voxels converts through it.
  return plsm_heaviside(-worst, eta_voxels * fb.spacing_mm);
}

PlsmRunResult plsm_optimize(const VoxelGrid& grid, const SimpParams& params,
                            const std::vector<DirichletBC>& bcs,
                            const std::vector<NodalLoad>& loads,
                            const SimpOptions& options, const DesignMask& mask,
                            const PlsmOptions& plsm) {
  const std::size_t n = grid.voxel_count();
  if (mask.size() != n)
    throw std::invalid_argument("plsm_optimize: mask size != voxel_count");
  if (!(options.volume_fraction > 0.0))
    throw std::invalid_argument("plsm_optimize: volume_fraction must be > 0");
  if (!(plsm.support >= 1.0))
    throw std::invalid_argument("plsm_optimize: support must be >= 1");
  if (!(plsm.eta_voxels > 0.0))
    throw std::invalid_argument("plsm_optimize: eta_voxels must be > 0");
  const bool frac = plsm.ersatz == PlsmErsatz::VolumeFraction;
  // ★ REFUSED RATHER THAN CLAMPED. k = 1 is the cell centre — the substitution
  // the fraction exists to remove, silently reinstated — and a large k is O(k^3)
  // per active cell with nothing measured above 4. A caller that writes a number
  // outside the band gets told, not corrected.
  if (frac && (plsm.frac_samples < 2 || plsm.frac_samples > 16))
    throw std::invalid_argument(
        "plsm_optimize: frac_samples is the SUB-CELL sampling per axis and must "
        "be in [2, 16], got " + std::to_string(plsm.frac_samples) +
        " — 1 would put the only sample back at the cell centre, which is the "
        "approximation the volume fraction replaces.");
  if (frac && !(plsm.frac_eps_mult > 0.0))
    throw std::invalid_argument(
        "plsm_optimize: frac_eps_mult must be > 0 (it is the quadrature "
        "bandwidth in units of the sample spacing; 1.0 is the derived value)");

  const int nx = grid.nx, ny = grid.ny, nz = grid.nz;
  const double h = grid.spacing;
  const double eta = plsm.eta_voxels * h;
  const int threads = plsm_hw_threads(plsm.threads);
  const PlsmBasisKind basis = parse_basis(plsm.basis);
  const int fk = plsm.frac_samples;

  // ★ THE MASK THE RUN ACTUALLY HOLDS FROZEN, not a second opinion about it.
  // `effective_design_mask` is the SAME function `simp_optimize`'s loop calls, so
  // the Load/Fixture voxels this path pins are exactly the ones SIMP pins.
  const DesignMask eff = effective_design_mask(grid, mask);

  // ★ ALL THREE ZERO MEANS "DERIVE FROM THE GRID"; A PARTIAL SPEC IS REFUSED.
  // Silently substituting the derived rule for the two axes a job forgot would
  // be the worst of both — the run would honour one number the job wrote and
  // invent the other two, and the receipt would report a spacing nobody chose.
  // Three numbers or none.
  PlsmKnots knots = plsm.knots;
  const bool any = knots.dx != 0.0 || knots.dy != 0.0 || knots.dz != 0.0;
  const bool all = knots.dx > 0.0 && knots.dy > 0.0 && knots.dz > 0.0;
  if (any && !all)
    throw std::invalid_argument(
        "plsm_optimize: the knot spacing is THREE numbers, PER AXIS, in voxels, "
        "and all three must be > 0 — or all three zero to derive them from the "
        "grid. A partial spec would honour one axis and invent the others.");
  if (!any) knots = plsm_knots_for_grid(grid);

  PlsmRunResult out;
  out.lattice = plsm_make_lattice(nx, ny, nz, knots.dx, knots.dy, knots.dz,
                                  plsm.support);
  out.basis_kind = basis;
  out.eta_voxels = plsm.eta_voxels;
  out.ersatz = plsm.ersatz;
  out.sens_weight = plsm.sens_weight;
  out.frac_samples = frac ? fk : 0;
  out.spacing_mm = h;
  const PlsmKnotLattice& L = out.lattice;

  const double t_run0 = steady_s();

  // ── the frozen boolean, and the load-path guarantee, BEFORE the first solve ──
  const PlsmFrozenBoolean fb =
      plsm_build_frozen_boolean(grid, eff, plsm.reinit_sweeps);
  out.frozen_solid_voxels = fb.n_solid;
  out.frozen_void_voxels = fb.n_void;
  out.active_voxels = fb.n_active;
  out.frozen_floor_occupancy = plsm_frozen_floor_occupancy(fb, plsm.eta_voxels);
  // ★ THE ASSERTION PR 324 §5 PAID FOR. Every fit it ran was REJECTED on the LOAD
  // PATH, not on the margin, because an analytic phi leaked 40 frozen voxels of
  // 40,216 below the iso and `load_path_connected` then found no route from the
  // anchor to the load. Under the smooth boolean that cannot happen — phi_eff is
  // a `min` with a field that is <= -h/2 on the whole frozen set — and this is
  // where that stops being an argument and becomes a check the run cannot pass
  // without. It is a property of (eta, the mask), so it is decidable here, once,
  // before any wall clock is spent.
  if (fb.n_solid > 0 && !(out.frozen_floor_occupancy > 0.5))
    throw std::invalid_argument(
        "plsm_optimize: the smooth frozen boolean does not hold the frozen set "
        "above the 0.5 iso at this band width (floor occupancy " +
        std::to_string(out.frozen_floor_occupancy) + " over " +
        std::to_string(fb.n_solid) +
        " FrozenSolid voxels) — the anchor-to-load walk would break and every "
        "certification would be rejected on the LOAD PATH. Reduce eta_voxels "
        "below 2.0 or widen the frozen pad.");

  // ── ★ THE PROPERTY THE VOLUME-FRACTION PATH REPLACES THE BOOLEAN WITH ─────
  //
  // Under `VolumeFraction` the ersatz is sampled ONLY on the ACTIVE cells and
  // the frozen ones are STAMPED (1 for FrozenSolid, 0 for FrozenVoid), so the
  // load-path guarantee stops being a band-width argument and becomes exact. The
  // reason that is legitimate — rather than the boolean being quietly dropped —
  // is a property of the two distance fields, and it is CHECKED here rather than
  // asserted in a comment:
  //
  //   `phi_eff = max(min(phi, phi_solid), -phi_void)` can only change the SIGN
  //   of phi at a voxel where `phi_solid < 0` (a FrozenSolid voxel) or
  //   `phi_void < 0` (a keep-out). Both distances are STRICTLY POSITIVE
  //   everywhere else by construction — `plsm_build_frozen_boolean` seeds them
  //   at +h/2 and `plsm_reinitialise` preserves the sign — so on every ACTIVE
  //   cell the smooth boolean is a no-op on the sign, and a volume fraction
  //   counts SIGNS. Stamping the frozen cells is therefore not an approximation
  //   of the boolean; on this partition it IS the boolean.
  //
  // If that ever stops holding, the fraction would silently start ignoring a
  // frozen region, which is exactly the failure PR 324 §5 spent a day on.
  if (frac) {
    std::size_t bad = 0;
    for (std::size_t v = 0; v < n; ++v) {
      if (grid.tags[v] == VoxelTag::Empty) continue;
      if (eff[v] != MaskValue::FrozenSolid && !(fb.phi_solid[v] > 0.0)) ++bad;
      if (eff[v] != MaskValue::FrozenVoid && !(fb.phi_void[v] > 0.0)) ++bad;
    }
    if (bad > 0)
      throw std::invalid_argument(
          "plsm_optimize: the frozen distance fields are not strictly positive "
          "off their own sets (" + std::to_string(bad) +
          " voxels) — the volume-fraction ersatz stamps the frozen cells and "
          "relies on the smooth boolean being sign-neutral on the ACTIVE ones, "
          "so a frozen region could be silently ignored. This is the load-path "
          "failure PR 324 section 5 diagnosed, one representation later.");
  }

  // ── the basis ─────────────────────────────────────────────────────────────
  const PlsmCsr Psi = plsm_build_A(nx, ny, nz, L, basis, threads);
  const PlsmCsr PsiT = plsm_transpose(Psi, threads);
  std::vector<double> psi_sum(n, 0.0);
  {
    const std::vector<double> ones(L.count(), 1.0);
    plsm_spmv(Psi, ones, psi_sum, threads);
  }

  // ── (a) PHI, SEEDED ───────────────────────────────────────────────────────
  //
  // "inherit" takes the driver's warm-start seed when there is one — which on the
  // ladder is the PREVIOUS RUNG's converged design, exactly what
  // SimpOptions::initial_design carries on the SIMP path — and falls back to the
  // hole array when there is not. So rung 0 starts from holes with no SIMP
  // anywhere (PR 324's Arm 2) and rung k+1 starts from rung k, which is the
  // ladder's own warm start and costs nothing to honour.
  std::vector<double> phi(n, 0.0);
  bool seeded_from_design = false;
  if (plsm.seed == "inherit" && options.initial_design.size() == n) {
    for (std::size_t v = 0; v < n; ++v) phi[v] = 0.5 - options.initial_design[v];
    seeded_from_design = true;
  } else if (plsm.seed != "inherit" && plsm.seed != "holes") {
    throw std::invalid_argument(
        "plsm_optimize: seed must be \"inherit\" or \"holes\", got \"" +
        plsm.seed + "\"");
  }
  if (!seeded_from_design) {
    // A regular array of holes, the classic level-set start: phi is a product of
    // cosines, negative (solid) between the holes. Centred on the lattice, so the
    // start is the same object at any resolution of the part.
    const double per = plsm.hole_period_voxels > 0.0 ? plsm.hole_period_voxels : 8.0;
    for (int k = 0; k < nz; ++k)
      for (int j = 0; j < ny; ++j)
        for (int i = 0; i < nx; ++i)
          phi[plsm_at(nx, ny, i, j, k)] =
              -0.4 + std::cos(2.0 * kPlsmPi * i / per) *
                         std::cos(2.0 * kPlsmPi * j / per) *
                         std::cos(2.0 * kPlsmPi * k / per);
  }
  // ★ NOT russo_smereka HERE. The seed is a near-binary step field saturated at
  // +-0.5: its per-cell differences are ~1 rather than ~h, so |phi|/|grad phi| is
  // not a distance. The edge-ratio crossing interpolation is well defined for ANY
  // monotone field and is what the seed needs; RS applies from the first re-fit
  // onward, once phi genuinely is a distance function.
  plsm_reinitialise(nx, ny, nz, phi, h, plsm.reinit_sweeps, false);

  // ── the seed fit: the SAME weighted least squares plsm_probe runs ─────────
  std::vector<double> alpha;
  {
    std::vector<double> target(n, 0.0);
    const std::vector<double> w(n, 1.0);
    for (std::size_t v = 0; v < n; ++v)
      target[v] = std::max(-plsm.clamp_voxels * h,
                           std::min(plsm.clamp_voxels * h, phi[v]));
    const PlsmFitResult fr =
        plsm_solve_normal(Psi, PsiT, target, w, plsm.ridge,
                          plsm.fit_cg_iterations, 1e-10, threads);
    alpha = fr.alpha;
  }
  auto sync = [&]() { plsm_spmv(Psi, alpha, phi, threads); };
  sync();

  // The coefficient box, sized from the SEED: an RBF coefficient is scaled like
  // the distance it interpolates (mm here) and there is no universal bound to
  // write down.
  double alpha_bound = 1.0;
  for (double c : alpha) alpha_bound = std::max(alpha_bound, std::fabs(c));
  alpha_bound *= plsm.bound;
  double psi_max = 0.0;
  for (std::size_t v = 0; v < n; ++v)
    if (grid.tags[v] != VoxelTag::Empty) psi_max = std::max(psi_max, psi_sum[v]);
  if (!(psi_max > 0.0)) psi_max = 1.0;

  // ── the ersatz, and the volume it measures ────────────────────────────────
  //
  // ★ THE SMOOTH BOOLEAN, which is where the frozen set enters and the only place
  // it does. With solid = {phi < 0}, union is `min` and intersection is `max`:
  //
  //     phi_eff = max( min(phi + c*psi_sum, phi_solid), -phi_void )
  //
  // "what the optimiser chose, PLUS the frozen material, MINUS the keep-outs" —
  // exactly, smoothly, with no tags surviving into the result.
  const double rho_min = params.density_min;
  std::vector<double> occ(n, 0.0), rho(n, 0.0);
  const bool have_void = fb.n_void > 0;

  auto phi_eff_at = [&](std::size_t v, double offset) {
    double p = phi[v] + offset * psi_sum[v];
    p = std::min(p, fb.phi_solid[v]);
    if (have_void) p = std::max(p, -fb.phi_void[v]);
    return p;
  };

  // ── ★ THE VOLUME FRACTION'S OWN STATE ────────────────────────────────────
  //
  // `sample` is the set the sub-cell lattice is ever laid over: the ACTIVE
  // cells, and nothing else. On his part that is 70,688 of 468,224 voxels — the
  // other 397,536 are stamped by the mask and the optimiser never had any say
  // over them.
  std::vector<char> sample(n, 0);
  if (frac)
    for (std::size_t v = 0; v < n; ++v)
      sample[v] = (grid.tags[v] != VoxelTag::Empty && eff[v] == MaskValue::Active)
                      ? 1
                      : 0;
  PlsmFracCache fcache;
  // The scale the quadrature bandwidth is tied to, per cell. L2 by default; L1
  // when the (measured, and losing) Engquist-Tornberg-Tsai variant is armed.
  std::vector<double> frac_gs(frac ? n : 0, 0.0);
  auto refresh_frac_gradscale = [&]() {
    if (!frac) return;
    plsm_parallel_for(n, threads, [&](std::size_t v) {
      if (!sample[v]) { frac_gs[v] = 0.0; return; }
      const int i = static_cast<int>(v % static_cast<std::size_t>(nx));
      const int j = static_cast<int>((v / static_cast<std::size_t>(nx)) %
                                     static_cast<std::size_t>(ny));
      const int k = static_cast<int>(v / (static_cast<std::size_t>(nx) *
                                          static_cast<std::size_t>(ny)));
      frac_gs[v] = plsm.frac_eps_l1
                       ? plsm_frac_grad_l1(nx, ny, nz, phi, i, j, k, h)
                       : plsm_grad_mag(nx, ny, nz, phi, i, j, k, h);
    });
  };
  // f_v at one ACTIVE cell, at a rigid offset of the level set. The mollified
  // value is the default; both agree on the volume they measure to 0.037%.
  auto frac_at = [&](std::size_t v, double offset) {
    return plsm.frac_mollified
               ? plsm_frac_of_soft(
                     fcache, v,
                     plsm_frac_eps(frac_gs[v], h, fk, plsm.frac_eps_mult), offset)
               : plsm_frac_of(fcache, v, offset);
  };

  // ★ THE OCCUPANCY. Under `VolumeFraction` the frozen cells are STAMPED and the
  // active ones carry the exact fraction; under `Heaviside` this is PR 324's
  // smooth boolean, unmoved, so the A/B changes one thing.
  auto build_fields = [&](double offset) {
    for (std::size_t v = 0; v < n; ++v) {
      double o;
      if (grid.tags[v] == VoxelTag::Empty) {
        o = 0.0;
      } else if (!frac) {
        o = plsm_heaviside(-phi_eff_at(v, offset), eta);
      } else if (eff[v] == MaskValue::FrozenSolid) {
        o = 1.0;
      } else if (eff[v] == MaskValue::FrozenVoid) {
        o = 0.0;
      } else {
        o = frac_at(v, offset);
      }
      occ[v] = o;
      rho[v] = rho_min + (1.0 - rho_min) * o;
    }
  };
  // ★ THE CONSTRAINT IS SIMP'S: the occupancy summed over the ACTIVE set against
  // `volume_fraction * n_active`. Frozen solid is printed either way and is
  // outside the budget, exactly as `simp_optimize`'s mask-aware overload has it.
  //
  // ★ AND UNDER THE FRACTION IT IS THE SAME FIELD THE DENSITY IS. That closes a
  // drift the smeared ersatz carried: `H_eta` is antisymmetric about a PLANE, so
  // summing it credited material that is not there wherever the boundary is
  // CURVED — PR 327 §7 measured 365.8 voxels, 1.08% of extra stiffness, biased
  // toward branched designs and invisible to a volume constraint that summed the
  // same smeared field. Summing `f_v` IS summing the volume.
  // ★ THE FRACTION'S BRANCH IS A DETERMINISTIC PARALLEL REDUCTION, AND BOTH
  // WORDS ARE LOAD-BEARING. The bisection below evaluates this 100 times per
  // iteration, and on his part each evaluation is 70,688 cells x 64 samples =
  // 4.5 million mollified steps — serially that is over a second per iteration,
  // several times the sampling it is meant to ride along with. Fixed chunks with
  // the partials summed IN CHUNK ORDER make it reproducible run to run: a
  // reduction whose combination order followed thread completion would move the
  // seventh digit of the volume between two runs of the same job, and the
  // constraint is compared against a target to that precision.
  std::vector<double> vol_partial(
      static_cast<std::size_t>(std::max(1, threads)), 0.0);
  auto active_volume_at = [&](double offset) {
    double s = 0.0;
    if (frac) {
      std::fill(vol_partial.begin(), vol_partial.end(), 0.0);
      // `plsm_frac_parallel` hands the body its THREAD INDEX and chunks the
      // range CONTIGUOUSLY, so partial `q` always covers the same cells in the
      // same order however the threads are scheduled.
      plsm_frac_parallel(fcache.ncell, threads, [&](std::size_t sl, int tid) {
        vol_partial[static_cast<std::size_t>(tid)] +=
            frac_at(static_cast<std::size_t>(fcache.cell[sl]), offset);
      });
      for (double p : vol_partial) s += p;
      return s;
    }
    for (std::size_t v = 0; v < n; ++v) {
      if (grid.tags[v] == VoxelTag::Empty) continue;
      if (eff[v] != MaskValue::Active) continue;
      s += plsm_heaviside(-phi_eff_at(v, offset), eta);
    }
    return s;
  };
  const double target_volume =
      options.volume_fraction * static_cast<double>(fb.n_active);

  // `active_volume_at` is non-increasing in `offset` by construction (psi_sum >= 0
  // for both bases, and raising phi can only move material out of a sub-level
  // set), so a bisection is unconditionally convergent and needs no tuning. The
  // bracket is far wider than the part; 100 halvings take it to machine
  // precision.
  auto solve_offset = [&](double want) {
    double lo = -400.0, hi = 400.0;
    if (active_volume_at(lo) < want) return lo;
    if (active_volume_at(hi) > want) return hi;
    for (int it = 0; it < 100; ++it) {
      const double mid = 0.5 * (lo + hi);
      if (active_volume_at(mid) > want) lo = mid; else hi = mid;
    }
    return 0.5 * (lo + hi);
  };

  // ── the run ───────────────────────────────────────────────────────────────
  PlsmMmaState mma_state;
  int mma_iter = 0;
  std::vector<double> delta(n, 0.0), raw_vel(n, 0.0);
  std::vector<double> best_rho, best_occ, best_alpha;
  double best_compliance = std::numeric_limits<double>::infinity();
  int best_iter = -1;
  // ── ★ THE MARGIN PEAK — a SECOND candidate design, and the one that ships
  //    when a probe is attached. Held separately from the best-compliance
  //    iterate because the two are not the same iterate: PR 326 measured a
  //    margin that DOUBLED between iterations 40 and 60 while compliance moved
  //    2%, and PR 327 measured a margin that PEAKED at 80 and fell 19.4% by 120
  //    while compliance was flat.
  std::vector<double> peak_rho, peak_occ, peak_alpha;
  double peak_margin = -std::numeric_limits<double>::infinity();
  int peak_iter = -1;
  int stale_probes = 0;
  bool margin_stop_now = false;
  const bool margin_rule =
      static_cast<bool>(plsm.margin_probe) && plsm.margin_probe_every > 0;
  FeaSolution warm;
  bool have_warm = false;
  bool non_convergent = false;
  int non_convergent_iteration = 0;
  double non_convergent_residual = 0.0;
  bool cancelled = false;
  int done_iters = 0;

  // Bound BEFORE the loop, because the per-iteration record is part of
  // `SimpOptimizeResult`'s contract and is filled as the loop runs.
  SimpOptimizeResult& r = out.optimization;

  const double tol_tight = options.cg_tolerance;
  const double tol_loose = plsm.cg_tolerance_loose > tol_tight
                               ? plsm.cg_tolerance_loose
                               : tol_tight;

  for (int it = 1; it <= plsm.max_iterations; ++it) {
    if (options.cancel && *options.cancel) { cancelled = true; break; }
    const double t_it0 = steady_s();

    // ★ THE OFFSET IS ADDED TO EVERY COEFFICIENT, NOT TO PHI. That keeps phi
    // inside the span of the basis — the whole representation claim would be void
    // if the design carried a per-voxel term beside it — and it moves the surface
    // by offset * sum_i psi_i, which is a near-rigid move because psi_sum is
    // nearly constant in the interior.
    // ── ★ THE SUB-CELL SAMPLE CACHE, BUILT ONCE PER ITERATION ──────────────
    //
    // Before the offset, so the bisection can evaluate a candidate THROUGH the
    // cache (phi = Psi alpha, so alpha_i += c moves every sample by c * SUM psi
    // exactly) instead of re-evaluating the basis a hundred times. The chosen
    // offset is then folded into the cache by that same identity, so the samples
    // the density and the sensitivity read are the samples of the alpha the
    // state solve is about to run on — not a rebuild that could differ.
    if (frac) {
      const double t_fb = steady_s();
      plsm_frac_build(nx, ny, nz, L, basis, alpha, sample, fk, threads, fcache);
      out.frac_sample_wall_s += steady_s() - t_fb;
      refresh_frac_gradscale();
    }
    const double offset = solve_offset(target_volume);
    for (double& c : alpha) c += offset;
    if (frac) plsm_frac_shift(fcache, offset);
    sync();
    if (frac) {
      // |grad phi| moved with the offset (psi_sum is not exactly constant), and
      // the bandwidth is a function of it. One more pass rather than a stale
      // field: it is 468k central differences against a 28 s state solve.
      refresh_frac_gradscale();
      out.frac_cut_cells = fcache.n_boundary;
      out.frac_full_cells = fcache.n_full;
      out.frac_empty_cells = fcache.n_empty;
    }
    build_fields(0.0);

    // ── THE STATE SOLVE. Core's, unmodified. ────────────────────────────────
    //
    // S3: LOOSE + WARM. The tolerance is already an argument and the warm start
    // is now honoured by the matrix-free path (SimpOptions::matfree_warm_start
    // wires it for SIMP; here it is passed directly). PR 324 measured the pair at
    // 76% fewer solver steps and 59% less wall on the same design to seven
    // significant figures. The FINAL compliance solve below and every
    // certification solve stay TIGHT and COLD.
    SimpCompliance sc;
    try {
      sc = simp_compliance(grid, params, rho, bcs, loads, tol_loose,
                           options.cg_max_iterations,
                           (plsm.warm_start && have_warm) ? &warm : nullptr,
                           nullptr, options.solver);
    } catch (const SolverNonConvergence& e) {
      non_convergent = true;
      non_convergent_iteration = it;
      non_convergent_residual = e.residual;
      break;
    }
    if (plsm.warm_start) { warm = sc.solution; have_warm = true; }
    out.total_solve_wall_s += sc.t_solve_ms / 1000.0;

    double active_sum = 0.0;
    for (std::size_t v = 0; v < n; ++v)
      if (grid.tags[v] != VoxelTag::Empty && eff[v] == MaskValue::Active)
        active_sum += occ[v];
    const double achieved =
        fb.n_active > 0 ? active_sum / static_cast<double>(fb.n_active) : 0.0;

    if (sc.compliance < best_compliance) {
      best_compliance = sc.compliance;
      best_rho = rho;
      best_occ = occ;
      best_alpha = alpha;
      best_iter = it;
    }

    // ── ★★ THE MARGIN PROBE, ON ITS CADENCE ─────────────────────────────────
    //
    // HERE, and not at the bottom of the loop, because `rho`, `occ` and `alpha`
    // describe ONE design at exactly this point: the MMA update below moves
    // alpha, and a probe taken after it would certify a field that no longer
    // belongs to the coefficients stored beside it.
    //
    // ★ A PROBE THAT IS NOT LOAD-PATH CONNECTED IS DISCARDED, NOT RECORDED AS A
    // PEAK. A severed design measures ~zero stress and therefore an enormous and
    // meaningless margin; taking the maximum over margins without that guard
    // would make the rule select the worst design in the run. The same is true
    // of a certification solve that did not converge.
    if (margin_rule && it % plsm.margin_probe_every == 0) {
      const PlsmMarginProbe mp = plsm.margin_probe(rho);
      out.margin_probe_iterations.push_back(it);
      out.margin_probe_values.push_back(mp.margin);
      out.margin_probe_load_path_ok.push_back(
          static_cast<char>(mp.load_path_ok && !mp.non_convergent ? 1 : 0));
      out.margin_probe_wall_s += mp.wall_s;
      if (mp.load_path_ok && !mp.non_convergent) {
        const bool improved =
            peak_iter < 0 ||
            mp.margin > peak_margin * (1.0 + plsm.margin_plateau_tol);
        if (improved) {
          peak_margin = mp.margin;
          peak_iter = it;
          peak_rho = rho;
          peak_occ = occ;
          peak_alpha = alpha;
          stale_probes = 0;
        } else {
          // ★ The peak is KEPT even when a later probe is nominally higher but
          // inside the tolerance: the design that ships is the one whose margin
          // was measured, and re-selecting on noise would make the shipped
          // design depend on the reproduction floor.
          ++stale_probes;
          if (stale_probes >= plsm.margin_plateau_probes) margin_stop_now = true;
        }
      }
    }

    // ── THE SHAPE DERIVATIVE, WITH THE SURFACE DELTA ────────────────────────
    //
    // dJ/dalpha_i     = integral (C:eps(u):eps(u)) psi_i DH_eta(phi) |grad phi|
    // dV/dalpha_i     = integral            -1     psi_i DH_eta(phi) |grad phi|
    //
    // Both carry the IDENTICAL factor, so it comes out front: `delta` is that
    // factor and the two sensitivities differ only in replacing the energy
    // density by a constant. The delta is evaluated at phi ITSELF because the
    // volume offset has already been folded into the coefficients, so {phi = 0}
    // is the one interface the ersatz, the constraint and this delta all read.
    // ★ UNDER THE FRACTION THE MEASURE CHANGES AND THE `|grad phi|` GOES AWAY.
    // `dfrac[v] = (1/k^3) SUM_s delta_q(phi_s)` is the derivative of f_v with
    // respect to a rigid shift of phi, which is `dS/|grad phi|` by the co-area
    // formula — and `dS/|grad phi|` is what the derivative of a VOLUME FRACTION
    // actually is. The old `DH_eta(phi)*|grad phi|` is `dS`, the CONTINUUM shape
    // derivative's measure, and the two agree only on a true signed distance.
    // This phi is not one, and PR 327 §4 measured what that was costing: up to
    // 23%, flat across two decades of step size.
    if (frac) {
      const double t_fs = steady_s();
      plsm_frac_band(fcache, frac_gs, h, plsm.frac_eps_mult, delta, threads);
      out.frac_sens_wall_s += steady_s() - t_fs;
    }
    for (int k = 0; k < nz; ++k)
      for (int j = 0; j < ny; ++j)
        for (int i = 0; i < nx; ++i) {
          const std::size_t v = plsm_at(nx, ny, i, j, k);
          if (grid.tags[v] == VoxelTag::Empty || eff[v] != MaskValue::Active) {
            delta[v] = 0.0;
            raw_vel[v] = 0.0;
            continue;
          }
          if (!frac) {
            const double dh = plsm_dheaviside(phi[v], eta);
            delta[v] =
                dh > 0.0 ? dh * plsm_grad_mag(nx, ny, nz, phi, i, j, k, h) : 0.0;
          }
          // ★ THE WEIGHT. See the two functions at the top of this file: the
          // continuum strain-energy density is right for a LINEAR stiffness law
          // and production's trajectory is SIMP at p = 3. R2 measured the
          // difference at 45-56% on a general direction, flat across step size.
          raw_vel[v] =
              plsm.sens_weight == PlsmSensWeight::Continuum
                  ? energy_from(sc.dcompliance[v], rho[v], params.penalty,
                                params.youngs_modulus)
                  : discrete_weight_from(sc.dcompliance[v], rho_min);
        }

    // ★ THERE IS NO EXPLICIT VOLUME MULTIPLIER HERE, AND PR 324's DESCENT ARM IS
    // WHY THERE WOULD BE. A steepest-descent step needs the delta-weighted mean
    // energy subtracted to make the flow volume-neutral to first order. MMA does
    // not: it is handed dc and dv SEPARATELY and solves its own dual for the
    // multiplier that fits inside this step's asymptotes. Computing a second one
    // here and folding it into dc would price the constraint twice. The residual
    // MMA leaves is what the offset bisection removes at the top of the next
    // iteration, so the two do not fight: one is a projection, the other a
    // search direction.

    // ── THE COEFFICIENT UPDATE: MMA (plsm_mma.hpp — core's mma_update step) ──
    //
    // beta = -alpha so that "design up" means "material in", which is the sign
    // convention core's MMA assumes. dc and dv are the two projections; no
    // Hilbertian extension, because the step alpha <- alpha - dt Psi^T v already
    // moves phi by Psi Psi^T v — the velocity spread over every knot whose
    // support the interface passes through, a positive semi-definite smoothing
    // and therefore still a descent direction. PR 324 ablated the extension under
    // MMA and it changed NOTHING to twelve digits, for a structural reason: MMA
    // consumes SENSITIVITIES and an extension produces a DESCENT DIRECTION, which
    // is not a derivative.
    {
      std::vector<double> dc(L.count(), 0.0), dv(L.count(), 0.0);
      if (frac && plsm.frac_sens_exact) {
        // ★ THE SCATTER, NOT `Psi^T`. `Psi` is built on the CELL-CENTRE lattice,
        // so `Psi^T` evaluates psi_i at the centre and factors it out of the
        // sub-cell sum — the same substitution this change exists to remove,
        // made one level down, and it would have been INVISIBLE (still a descent
        // direction, still converges). PR 327 §4(c)(i) priced it: ~15 percentage
        // points of gradient accuracy on a general direction, and NOTHING on a
        // single coefficient, so a single-coefficient check would have said the
        // scatter was unnecessary.
        //
        // The two weights ride the SAME measure and differ only in w — the
        // identity the whole level-set formulation rests on — so one pass over
        // the samples produces both. `raw_vel` is the energy density already
        // recovered above; the volume's weight is 1.
        const double t_fs = steady_s();
        std::vector<double> wc(n, 0.0), wv(n, 0.0);
        for (std::size_t v = 0; v < n; ++v) {
          if (!(delta[v] > 0.0)) continue;
          wc[v] = raw_vel[v];
          wv[v] = 1.0;
        }
        plsm_frac_scatter(fcache, nx, ny, nz, L, basis, frac_gs, h,
                          plsm.frac_eps_mult, wc, dc, wv, dv, threads);
        out.frac_sens_wall_s += steady_s() - t_fs;
      } else {
        std::vector<double> edelta(n, 0.0);
        for (std::size_t v = 0; v < n; ++v) edelta[v] = raw_vel[v] * delta[v];
        plsm_spmv(PsiT, edelta, dc, threads);
        plsm_spmv(PsiT, delta, dv, threads);
      }
      for (double& c : dc) c = -c;  // material IN lowers compliance
      std::vector<double> beta(L.count(), 0.0);
      for (std::size_t i2 = 0; i2 < L.count(); ++i2) beta[i2] = -alpha[i2];
      const double g0 = active_sum - target_volume;
      // ★ THE MOVE LIMIT IS A LENGTH, NOT A FRACTION, AND PR 324's FIRST MMA RUN
      // IS WHY. Core's MMA takes `move` as a fraction of the design range because
      // its range is [rho_min, 1] and a fraction of that is a density step. An
      // RBF coefficient's range is set by the seed and is ~1365 mm wide on his
      // part, so the inherited default of 0.05 is a 68 mm step per coefficient
      // per iteration: compliance went 0.00287 -> 0.00848 in ONE iteration. So
      // the fraction is DERIVED from the motion a step should buy — gamma *
      // substeps * h of interface displacement — divided by how far a unit
      // coefficient move carries phi.
      const int steps = plsm.step_substeps > 0 ? plsm.step_substeps : 1;
      const double want_dphi = plsm.gamma * steps * h;
      const double xrange = 2.0 * alpha_bound;
      const double mv = plsm.move * want_dphi / (xrange * psi_max);
      beta = plsm_mma_update(mma_state, ++mma_iter, beta, dc, dv, g0,
                             -alpha_bound, alpha_bound, mv);
      for (std::size_t i2 = 0; i2 < L.count(); ++i2) alpha[i2] = -beta[i2];
    }
    sync();

    // ── the approximate re-initialisation ───────────────────────────────────
    //
    // Re-distance phi ON THE GRID, then RE-PROJECT it onto the basis, so the
    // design variable stays the coefficients. PR 324's ablation measured this as
    // what holds |grad phi| near 1 — which keeps the band the width eta claims,
    // which keeps the volume measure from drifting.
    if (plsm.refit_every > 0 && it % plsm.refit_every == 0) {
      std::vector<double> pr = phi;
      plsm_reinitialise(nx, ny, nz, pr, h, plsm.reinit_sweeps, false);
      std::vector<double> tgt(n, 0.0);
      const std::vector<double> w(n, 1.0);
      for (std::size_t v = 0; v < n; ++v)
        tgt[v] = std::max(-plsm.clamp_voxels * h,
                          std::min(plsm.clamp_voxels * h, pr[v]));
      const PlsmFitResult rf =
          plsm_solve_normal(Psi, PsiT, tgt, w, plsm.ridge,
                            plsm.fit_cg_iterations, 1e-10, threads);
      alpha = rf.alpha;
      sync();
    }

    done_iters = it;
    // ── ★ THE APP'S TWO READ-ONLY FEEDS, WHICH A NEW OPTIMISER SILENTLY LOSES ─
    //
    // Found by wiring this path into the front-end: `run_minimize_plastic` in
    // the app bridge sets `keyframe_count = 12` and the driver turns that into a
    // `keyframe` callback plus a stride, so the app can play the shape back as it
    // evolves. `simp_optimize` calls it (simp.cpp:2444); an optimiser that did
    // not would hand the app an EMPTY playback and nothing would say why.
    // `density_observer` is the same story for the CLI's `--snapshots`.
    //
    // Both are READ-ONLY — they take the field by const reference and cannot
    // change the design — and both fire on the SAME schedule the SIMP loop uses:
    // the keyframe on iteration 1 and every `keyframe_stride` after it, the
    // observer every iteration. `occ` is the analysis field at this point (the
    // ersatz the certificate will read), which is what both consumers want.
    if (options.keyframe && options.keyframe_stride > 0 &&
        (it == 1 || it % options.keyframe_stride == 0))
      options.keyframe(rho);
    if (options.density_observer) options.density_observer(it, rho);
    // ── OBSERVABILITY: the SAME hook the SIMP loop fills ────────────────────
    //
    // ★ A RUN THAT REPORTS NOTHING IS NOT A PRODUCTION PATH. `iterations.csv` is
    // written from `options.observe`, so a PLSM rung that skipped it would ship a
    // CSV with a header and no rows — and this repository has been bitten before
    // by a run whose only record of why it did something was gone. The fields
    // that have no analogue here are left at their defaults rather than filled
    // with a lookalike: there is no filter, so `change` is the largest ersatz
    // move this step made rather than a design-variable move, and it is named as
    // such in the handoff. Read-only, exactly as on the SIMP path.
    if (options.observe) {
      SimpIterationObservation ob;
      ob.iteration = it;
      ob.compliance = sc.compliance;
      ob.volume_fraction = achieved;
      ob.change = 0.0;
      ob.cg_iterations = sc.cg.iterations;
      ob.cg_used_multigrid = sc.cg.used_multigrid;
      ob.cg_mg_levels = sc.cg.mg_levels;
      ob.cg_hier_built = sc.cg.hier_built;
      ob.cg_mg_cycles_attempted = sc.cg.mg_cycles_attempted;
      ob.cg_recycle_dim = sc.cg.recycle_dim;
      ob.cg_recycle_setup_matvecs = sc.cg.recycle_setup_matvecs;
      // ── ★★ THE TIMING BLOCK, WHICH THIS PATH LEFT BLANK FROM PR 325 UNTIL
      //    2026-08-13 ─────────────────────────────────────────────────────────
      //
      // `iterations.csv` has `total_ms`, `solve_ms`, `fea_ms`, `sens_ms` and
      // `analysis_ms`; the SIMP path fills them (94,613.450 on his rung 0.68's
      // first iteration) and THIS PATH WROTE 0.000 IN ALL OF THEM ON EVERY ROW
      // OF EVERY RUN. The block above was filled and this one was not, so a
      // parametric run's record carried its compliance and its CG counters and
      // nothing at all about where its time went.
      //
      // ★ IT WAS FOUND BY NEEDING THE NUMBER, NOT BY READING THE CODE: the
      // task's own cost table divided by `total_ms` and got a zero. That is the
      // shape of gap this file's own comment warns about six lines up — "a run
      // that reports nothing is not a production path" — and the loop had got
      // the ROWS right and left the COLUMNS blank, which reads as "measured, and
      // it was zero" rather than "never measured".
      //
      // ★ ONLY THE TERMS THIS LOOP ACTUALLY HAS ARE FILLED. There is no density
      // filter and no projection on this path, so `filter_ms` and `project_ms`
      // stay 0 — that is a true statement about the trajectory, not a gap. The
      // sub-cell sampling and the sensitivity scatter have no SIMP analogue and
      // are reported on the receipt (`frac_sample_wall_s`, `frac_sens_wall_s`)
      // rather than folded into a column that would then mean two things.
      // ★ `residual_ms` IS FILLED HONESTLY AND IS THE POINT OF THE PARTITION.
      // `IterationPhaseTimes`' own contract is that the named phases are
      // subtracted from the iteration's wall and whatever is left is REPORTED,
      // so time going somewhere unnamed is visible in the CSV instead of
      // inferred. On this path the unnamed part is the offset bisection, the
      // sub-cell sampling, the MMA step and the re-fit — real work with no SIMP
      // analogue — and it belongs in the residual rather than in a column that
      // would then mean two different things on two paths.
      ob.phases.total_ms = (steady_s() - t_it0) * 1000.0;
      ob.phases.solve_ms = sc.t_solve_ms;
      ob.phases.fea_ms = sc.t_solve_ms;
      ob.phases.residual_ms = ob.phases.total_ms - ob.phases.solve_ms;
      options.observe(ob);
    }
    // `SimpOptimizeResult::history` is part of the contract — "history has
    // `iterations` entries" — and a consumer that found it empty would read a
    // parametric rung as a rung that never ran. `change` has no analogue here
    // (there is no per-voxel design variable to difference) and is left at 0
    // rather than filled with a lookalike; the handoff says so.
    {
      SimpIteration h;
      h.compliance = sc.compliance;
      h.change = 0.0;
      h.volume_fraction = achieved;
      r.history.push_back(h);
    }
    out.history_compliance.push_back(sc.compliance);
    out.history_volume_fraction.push_back(achieved);
    out.history_cg_iterations.push_back(sc.cg.iterations);
    out.history_wall_s.push_back(steady_s() - t_it0);
    if (options.progress) options.progress(it, sc.compliance, 0.0);

    // ── ★★ THE STOPPING RULE ────────────────────────────────────────────────
    //
    // The margin plateau, when a probe is attached. It fires here rather than at
    // the probe so this iteration's observability, history and keyframe are all
    // emitted first — a stopped run must not be missing its last row.
    if (margin_stop_now) {
      out.optimization.converged = true;
      out.stop_reason = "margin-plateau";
      break;
    }

    // The compliance plateau, on the window and tolerance the shipped MMA
    // termination uses (window 10, tol 1e-3).
    //
    // ★ IT IS DISARMED WHEN A MARGIN PROBE IS ATTACHED, AND THAT IS THE POINT OF
    // THE ITEM. PR 326 measured one arm's margin DOUBLE between iterations 40
    // and 60 while its compliance moved 2%; another task's control arm was
    // halted by this rule at iteration 56 while its margin was still climbing
    // 3195 -> 3395. Compliance is not a convergence proxy for the margin, so
    // where the margin is being watched this rule may not pre-empt it.
    if (!margin_rule && out.history_compliance.size() >= 10) {
      const std::size_t m = out.history_compliance.size();
      double lo = out.history_compliance[m - 10], hi = lo;
      for (std::size_t q = m - 10; q < m; ++q) {
        lo = std::min(lo, out.history_compliance[q]);
        hi = std::max(hi, out.history_compliance[q]);
      }
      if (hi > 0.0 && (hi - lo) / hi < 1e-3) {
        out.optimization.converged = true;
        out.stop_reason = "compliance-plateau";
        break;
      }
    }
  }

  out.total_wall_s = steady_s() - t_run0;
  out.best_iteration = best_iter;
  out.margin_peak_iteration = peak_iter > 0 ? peak_iter : 0;
  out.margin_peak = peak_iter > 0 ? peak_margin : 0.0;
  if (cancelled) out.stop_reason = "cancelled";
  else if (non_convergent) out.stop_reason = "non-convergent";

  r.iterations = done_iters;
  r.cancelled = cancelled;
  r.non_convergent = non_convergent;
  r.non_convergent_iteration = non_convergent_iteration;
  r.non_convergent_residual = non_convergent_residual;
  if (best_iter < 0) {
    // Not one state solve completed. There is no design to ship, and saying so
    // through the same flags `simp_optimize` uses is what lets the ladder driver
    // reject this rung and keep the run.
    r.converged = false;
    r.physical_density.assign(n, 0.0);
    r.design = r.physical_density;
    return out;
  }

  // ── ★★ WHICH ITERATE SHIPS ────────────────────────────────────────────────
  //
  // WITHOUT a margin probe: the BEST-COMPLIANCE iterate, not whatever the loop
  // stopped on — an MMA step can overshoot, and shipping an overshoot would
  // report the scheme's worst moment as its result. That is the historical rule
  // and it is unchanged on that path.
  //
  // ★ WITH a margin probe: THE PEAK-MARGIN ITERATE. Returning the last design,
  // or the best-compliance one, is what the whole item is about: the endpoint
  // understates the run's own best margin by 16-19% on every curve measured, and
  // compliance does not find the peak because it is flat across it. If no probe
  // was ever accepted — every one severed or non-convergent — this falls back to
  // best-compliance and the stop reason says so, rather than shipping a design
  // no certificate stands behind.
  const bool ship_peak = peak_iter > 0 && !peak_rho.empty();
  if (margin_rule && !ship_peak) out.stop_reason += "+no-accepted-probe";
  const std::vector<double>& ship_rho = ship_peak ? peak_rho : best_rho;
  const std::vector<double>& ship_occ = ship_peak ? peak_occ : best_occ;
  r.physical_density = ship_rho;
  // An RBF coefficient has no voxel, so there is no honest per-voxel "design
  // variable" to report; `design` is a copy of the physical field, and the actual
  // design — the coefficients — is `out.alpha` beside it.
  r.design = ship_rho;
  out.alpha = ship_peak ? peak_alpha : best_alpha;
  out.best_iteration = ship_peak ? peak_iter : best_iter;

  double active_sum = 0.0;
  for (std::size_t v = 0; v < n; ++v)
    if (grid.tags[v] != VoxelTag::Empty && eff[v] == MaskValue::Active)
      active_sum += ship_occ[v];
  r.volume_fraction =
      fb.n_active > 0 ? active_sum / static_cast<double>(fb.n_active) : 0.0;

  // ── ★ THE TOPOLOGY COUNTERS, ON THE DESIGN THAT SHIPS ────────────────────
  // Milliseconds, on the same printed set the certificate and the export read.
  // The CONSTRAINT that produced these does not ship (it bought 1.7% of the
  // internal surface where a change of seed bought 9.4%); the counters do,
  // because they are what made the finding legible in the first place.
  {
    std::vector<char> in_part(n, 0);
    for (std::size_t v = 0; v < n; ++v)
      in_part[v] = grid.tags[v] != VoxelTag::Empty ? 1 : 0;
    out.topology = plsm_void_topology(nx, ny, nz, h, ship_occ, 0.5, in_part);
  }

  // ── THE FINAL COMPLIANCE, TIGHT AND COLD ────────────────────────────────
  //
  // `simp_optimize`'s contract is that `compliance == compliance(physical_density)`
  // — a final solve on the converged field at the TIGHT tolerance, not the last
  // trajectory value. It is honoured here for the same reason it exists there:
  // the number a caller reads must belong to the field it reads beside it. It is
  // also the only compliance a loosened trajectory may be compared against, which
  // is what makes the S3 accuracy table meaningful.
  try {
    const SimpCompliance fc =
        simp_compliance(grid, params, r.physical_density, bcs, loads, tol_tight,
                        options.cg_max_iterations, nullptr, nullptr,
                        options.solver);
    r.compliance = fc.compliance;
  } catch (const SolverNonConvergence& e) {
    r.non_convergent = true;
    r.non_convergent_iteration = done_iters;
    r.non_convergent_residual = e.residual;
    r.compliance = best_compliance;
  }
  r.initial_compliance =
      out.history_compliance.empty() ? 0.0 : out.history_compliance.front();
  // The FINAL converged state, as `simp_optimize` emits it (simp.cpp:2631): the
  // playback's last frame is the design that is actually shipped, not whatever
  // iteration the stride last landed on.
  if (options.keyframe && options.keyframe_stride > 0)
    options.keyframe(r.physical_density);
  return out;
}

}  // namespace topopt
