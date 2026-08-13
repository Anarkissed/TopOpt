// plsm_frac_fd_probe.cpp — ★ R2. THE PRODUCTION VOLUME-FRACTION SENSITIVITY,
// AGAINST A CENTRAL DIFFERENCE, ON BOTH FUNCTIONALS.
//
// ★★ IT DIFFERENCES `core/include/topopt/plsm_frac.hpp` — THE SHIPPED HEADER —
// AND NOT A COPY OF IT. Every call below is `plsm_frac_build`,
// `plsm_frac_of_soft`, `plsm_frac_band`, `plsm_frac_scatter` and `energy_from`'s
// arithmetic, in the same order and with the same arguments `plsm_optimize` uses
// them in. A probe that reimplemented the gradient would verify the probe.
//
// ★ WHY THIS EXISTS AT ALL. PR 327 §4 measured that the gradient the shipped
// `--plsm` mode was using — `DH_eta(phi)*|grad phi|` projected by `Psi^T` — is
// WRONG BY UP TO 23%, FLAT ACROSS TWO DECADES OF STEP SIZE, and that a
// 20%-wrong descent direction does not fail: it converges slowly and is
// believed. Replacing it without differencing the replacement would be the same
// mistake with a different sign.
//
// ── ★ WHAT IS DIFFERENCED, AND THE SIGN CONVENTION WRITTEN OUT ──────────────
//
// `plsm_frac_scatter(w -> out)` returns
//
//     out_i = SUM_v w_v (1/k^3) SUM_s delta_q(phi_s) psi_i(x_s)
//           = -SUM_v w_v * d f_v / d alpha_i
//
// because `d f_v/d alpha_i = -(1/k^3) SUM_s delta_q psi_i`. `plsm_optimize`
// negates the compliance side once ("material IN lowers compliance"), so after
// that negation
//
//     dV/dalpha_i = -dv[i],      dC/dalpha_i = -dc[i]
//
// and those two are what is compared against the central differences of
//
//     V(alpha) = SUM_{v ACTIVE} f_v            (no state solve; sweep freely)
//     C(alpha) = compliance(rho(alpha))        (two solves per point)
//
// ★ THE OFFSET IS NOT RE-SOLVED BETWEEN THE PLUS AND MINUS POINTS. The finite
// difference is of the UNCONSTRAINED functions, which is what the gradients are
// gradients of.
//
// ── ★ AND THE THIRD ROW, WHICH IS NOT IN PR 327 AND WHICH THIS TASK ADDS ────
//
// The compliance sensitivity is the CONTINUUM shape derivative's: it weights the
// measure by the strain-energy density `e_v = q_v E0`, which is the energy
// released when material appears at the interface as a 0 -> 1 jump. The DISCRETE
// ersatz's derivative is a different expression,
//
//     dC/dalpha_i = SUM_v (dC/drho_v) (1 - rho_min) d f_v/d alpha_i
//                 = -p (1 - rho_min) SUM_v rho_v^(p-1) e_v d f_v/d alpha_i
//
// and the two coincide only at penalty p = 1. ★ PRODUCTION RUNS THE TRAJECTORY
// AT p = 3, so on this path they do NOT coincide, and the difference is a
// per-voxel factor `p (1-rho_min) rho_v^(p-1)` that is about 0.75 at rho = 0.5
// and varies across the band. That is a question about the SHIPPED gradient that
// nobody has differenced, so both forms are computed here against the SAME
// finite difference and the answer is a number.
//
// ── the control ─────────────────────────────────────────────────────────────
//
// `--heaviside` differences PR 324/325/326's gradient against ITS OWN density on
// the same design, so "the new one checks out" has something to be better than.

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <limits>
#include <string>
#include <vector>

#include "topopt/analyze.hpp"
#include "topopt/face_overrides.hpp"  // import_part_file_resolved
#include "topopt/fea.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/plsm.hpp"
#include "topopt/plsm_basis.hpp"
#include "topopt/plsm_frac.hpp"
#include "topopt/plsm_kernel.hpp"
#include "topopt/simp.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {

struct Args {
  std::string step, materials, out;
  std::string alpha_file;          // optional: a converged design to read back
  double rung = 0.68;
  int k = 4;
  double eps_mult = 1.0;
  bool mollified = true;
  bool sens_exact = true;
  bool eps_l1 = false;
  bool heaviside = false;          // the control
  double eta_voxels = 1.0;
  int threads = 3;
  int n_dirs = 2;                  // random directions
  int n_coeffs = 3;                // single coefficients, ranked by |dV|
  bool compliance = false;         // arm the two-solve rows
  std::vector<double> steps{0.001, 0.01, 0.1, 0.3, 1.0};
  std::vector<double> csteps{0.01, 0.1};
};

[[noreturn]] void die(const std::string& m) {
  std::printf("FATAL: %s\n", m.c_str());
  std::exit(2);
}

// A deterministic direction. No <random>: the same integer seed must give the
// same direction on every host, or a re-run is not the same experiment.
double lcg(unsigned& s) {
  s = s * 1664525u + 1013904223u;
  return static_cast<double>(s >> 8) / static_cast<double>(1u << 24) - 0.5;
}

}  // namespace

int main(int argc, char** argv) {
  Args a;
  if (argc < 4) {
    std::printf(
        "usage: plsm_frac_fd_probe <part.step> <materials.json> <out_dir>\n"
        "       [--alpha FILE.f64] [--rung R] [--k N] [--eps-mult X]\n"
        "       [--hard] [--centre] [--eps-l1] [--heaviside] [--eta V]\n"
        "       [--threads N] [--dirs N] [--coeffs N] [--compliance]\n");
    return 2;
  }
  a.step = argv[1];
  a.materials = argv[2];
  a.out = argv[3];
  for (int i = 4; i < argc; ++i) {
    const std::string s = argv[i];
    auto nextd = [&](double& d) { if (i + 1 < argc) d = std::atof(argv[++i]); };
    auto nexti = [&](int& d) { if (i + 1 < argc) d = std::atoi(argv[++i]); };
    if (s == "--alpha" && i + 1 < argc) a.alpha_file = argv[++i];
    else if (s == "--rung") nextd(a.rung);
    else if (s == "--k") nexti(a.k);
    else if (s == "--eps-mult") nextd(a.eps_mult);
    else if (s == "--hard") a.mollified = false;
    else if (s == "--centre") a.sens_exact = false;
    else if (s == "--eps-l1") a.eps_l1 = true;
    else if (s == "--heaviside") a.heaviside = true;
    else if (s == "--eta") nextd(a.eta_voxels);
    else if (s == "--threads") nexti(a.threads);
    else if (s == "--dirs") nexti(a.n_dirs);
    else if (s == "--coeffs") nexti(a.n_coeffs);
    else if (s == "--compliance") a.compliance = true;
    else die("unknown argument \"" + s + "\"");
  }

  // ── THE PRODUCTION SETUP. His captured load case, verbatim, through
  // `build_production_loadcase` — the same entry point the shipped run uses, so
  // the mask, the frozen faces and the solver posture are production's and not a
  // probe's opinion of them.
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
  lc.infill_percent = 35.0;
  lc.wall_loops = 5;
  lc.wall_line_width_mm = 0.45;
  lc.wall_line_width_outer_mm = 0.42;
  lc.face_protection_face_ids = {16};
  lc.face_protection_depth_mm = 5.0;

  const StepModel model = import_part_file_resolved(a.step);
  if (model.mesh.vertices.empty()) die("the STEP imported empty — OCCT required");
  const ProductionRunSetup setup =
      build_production_loadcase(model, resolution, lc);
  const VoxelGrid& grid = setup.grid;
  const MinimizePlasticOptions& mopts = setup.options;
  const std::vector<DirichletBC>& bcs = setup.bcs;
  const std::vector<NodalLoad>& loads = mopts.external_loads;

  const MaterialLibrary lib = load_materials_file(a.materials);
  const auto mit = lib.find("PLA");
  if (mit == lib.end()) die("PLA not in " + a.materials);
  const Material& material = mit->second;

  SimpParams params;
  params.youngs_modulus = material.youngs_modulus_mpa;
  params.poisson = material.poisson;
  params.penalty = 3.0;  // ★ PRODUCTION'S. See the header note on p != 1.
  const double rho_min = params.density_min;

  const int nx = grid.nx, ny = grid.ny, nz = grid.nz;
  const std::size_t n = grid.voxel_count();
  const double h = grid.spacing;
  const double eta = a.eta_voxels * h;
  const DesignMask eff = effective_design_mask(grid, mopts.design_mask);

  // ── the basis, EXACTLY as plsm_optimize builds it ─────────────────────────
  const PlsmKnots kn = plsm_knots_for_grid(grid);
  const PlsmKnotLattice L = plsm_make_lattice(nx, ny, nz, kn.dx, kn.dy, kn.dz, 2.0);
  const PlsmBasisKind basis = PlsmBasisKind::Gaussian;
  const PlsmCsr Psi = plsm_build_A(nx, ny, nz, L, basis, a.threads);
  const PlsmCsr PsiT = plsm_transpose(Psi, a.threads);
  std::vector<double> psi_sum(n, 0.0);
  {
    const std::vector<double> ones(L.count(), 1.0);
    plsm_spmv(Psi, ones, psi_sum, a.threads);
  }
  const PlsmFrozenBoolean fb = plsm_build_frozen_boolean(grid, eff, 2);

  // ── alpha: read back a converged design, or seed + fit as the optimiser does
  std::vector<double> alpha;
  if (!a.alpha_file.empty()) {
    std::ifstream f(a.alpha_file, std::ios::binary);
    if (!f) die("cannot open " + a.alpha_file);
    alpha.assign(L.count(), 0.0);
    f.read(reinterpret_cast<char*>(alpha.data()),
           static_cast<std::streamsize>(alpha.size() * sizeof(double)));
    if (static_cast<std::size_t>(f.gcount()) != alpha.size() * sizeof(double))
      die("alpha file is the wrong size for this lattice (" +
          std::to_string(L.count()) + " coefficients expected)");
    std::printf("alpha: read %zu coefficients from %s\n", alpha.size(),
                a.alpha_file.c_str());
  } else {
    std::vector<double> phi0(n, 0.0);
    for (int k3 = 0; k3 < nz; ++k3)
      for (int j = 0; j < ny; ++j)
        for (int i = 0; i < nx; ++i)
          phi0[plsm_at(nx, ny, i, j, k3)] =
              -0.4 + std::cos(2.0 * kPlsmPi * i / 8.0) *
                         std::cos(2.0 * kPlsmPi * j / 8.0) *
                         std::cos(2.0 * kPlsmPi * k3 / 8.0);
    plsm_reinitialise(nx, ny, nz, phi0, h, 2, false);
    std::vector<double> tgt(n, 0.0);
    const std::vector<double> w(n, 1.0);
    for (std::size_t v = 0; v < n; ++v)
      tgt[v] = std::max(-6.0 * h, std::min(6.0 * h, phi0[v]));
    alpha = plsm_solve_normal(Psi, PsiT, tgt, w, 1e-6, 2000, 1e-10, a.threads).alpha;
    std::printf("alpha: seeded from holes and fitted (%zu coefficients)\n",
                alpha.size());
  }

  std::vector<char> sample(n, 0);
  std::size_t n_active = 0;
  for (std::size_t v = 0; v < n; ++v) {
    sample[v] = (grid.tags[v] != VoxelTag::Empty && eff[v] == MaskValue::Active)
                    ? 1 : 0;
    if (sample[v]) ++n_active;
  }

  std::vector<double> phi(n, 0.0);
  auto sync = [&]() { plsm_spmv(Psi, alpha, phi, a.threads); };
  sync();

  PlsmFracCache C;
  std::vector<double> gs(n, 0.0);
  auto refresh_gs = [&]() {
    plsm_parallel_for(n, a.threads, [&](std::size_t v) {
      if (!sample[v]) { gs[v] = 0.0; return; }
      const int i = static_cast<int>(v % static_cast<std::size_t>(nx));
      const int j = static_cast<int>((v / static_cast<std::size_t>(nx)) %
                                     static_cast<std::size_t>(ny));
      const int k3 = static_cast<int>(v / (static_cast<std::size_t>(nx) *
                                           static_cast<std::size_t>(ny)));
      gs[v] = a.eps_l1 ? plsm_frac_grad_l1(nx, ny, nz, phi, i, j, k3, h)
                       : plsm_grad_mag(nx, ny, nz, phi, i, j, k3, h);
    });
  };

  // ── the ersatz, at a given alpha. THE SAME BRANCHES plsm_optimize takes. ──
  const bool have_void = fb.n_void > 0;
  auto occ_of = [&](std::vector<double>& occ) {
    if (a.heaviside) {
      for (std::size_t v = 0; v < n; ++v) {
        if (grid.tags[v] == VoxelTag::Empty) { occ[v] = 0.0; continue; }
        double p = std::min(phi[v], fb.phi_solid[v]);
        if (have_void) p = std::max(p, -fb.phi_void[v]);
        occ[v] = plsm_heaviside(-p, eta);
      }
      return;
    }
    for (std::size_t v = 0; v < n; ++v) {
      if (grid.tags[v] == VoxelTag::Empty) occ[v] = 0.0;
      else if (eff[v] == MaskValue::FrozenSolid) occ[v] = 1.0;
      else if (eff[v] == MaskValue::FrozenVoid) occ[v] = 0.0;
      else
        occ[v] = a.mollified
                     ? plsm_frac_of_soft(
                           C, v, plsm_frac_eps(gs[v], h, a.k, a.eps_mult))
                     : plsm_frac_of(C, v);
    }
  };
  // The whole state at the CURRENT alpha, rebuilt from scratch. Used for every
  // finite-difference point, so a perturbed point is never evaluated against a
  // stale cache.
  std::vector<double> occ(n, 0.0), rho(n, 0.0);
  auto rebuild = [&]() {
    sync();
    if (!a.heaviside) {
      plsm_frac_build(nx, ny, nz, L, basis, alpha, sample, a.k, a.threads, C);
      refresh_gs();
    }
    occ_of(occ);
    for (std::size_t v = 0; v < n; ++v) rho[v] = rho_min + (1.0 - rho_min) * occ[v];
  };
  auto volume_now = [&]() {
    double s = 0.0;
    for (std::size_t v = 0; v < n; ++v) if (sample[v]) s += occ[v];
    return s;
  };
  auto compliance_now = [&]() {
    const SimpCompliance sc =
        simp_compliance(grid, params, rho, bcs, loads, 1e-8, 20000, nullptr,
                        nullptr, mopts.simp.solver);
    return sc;
  };

  rebuild();
  const double V0 = volume_now();
  std::printf(
      "\n== the design ==\n"
      "  grid            %d x %d x %d   spacing %.6f mm\n"
      "  active cells    %zu of %zu\n"
      "  ersatz          %s%s\n"
      "  k               %d  (%d samples per cell)\n"
      "  eps_mult        %.4g   bandwidth norm  L%d\n"
      "  projection      %s\n"
      "  V(alpha)        %.6f active-cell voxels  (rung target %.6f)\n",
      nx, ny, nz, h, n_active, n,
      a.heaviside ? "H_eta at the cell centre — THE CONTROL"
                  : (a.mollified ? "MOLLIFIED volume fraction"
                                 : "HARD volume fraction"),
      a.heaviside ? "" : "",
      a.k, a.k * a.k * a.k, a.eps_mult, a.eps_l1 ? 1 : 2,
      a.heaviside ? "Psi^T (the control's)"
                  : (a.sens_exact ? "sample SCATTER" : "Psi^T (centre ablation)"),
      V0, a.rung * static_cast<double>(n_active));
  if (!a.heaviside)
    std::printf("  cut cells       %zu   full %zu   empty %zu\n", C.n_boundary,
                C.n_full, C.n_empty);

  // ── THE ANALYTIC GRADIENTS, from the shipped headers ──────────────────────
  std::vector<double> delta(n, 0.0), raw_vel(n, 0.0), raw_vel_disc(n, 0.0);
  SimpCompliance sc0;
  bool have_sc0 = false;
  if (a.compliance) {
    sc0 = compliance_now();
    have_sc0 = true;
  }
  if (a.heaviside) {
    for (int k3 = 0; k3 < nz; ++k3)
      for (int j = 0; j < ny; ++j)
        for (int i = 0; i < nx; ++i) {
          const std::size_t v = plsm_at(nx, ny, i, j, k3);
          if (!sample[v]) { delta[v] = 0.0; continue; }
          const double dh = plsm_dheaviside(phi[v], eta);
          delta[v] = dh > 0.0 ? dh * plsm_grad_mag(nx, ny, nz, phi, i, j, k3, h)
                              : 0.0;
        }
  } else {
    plsm_frac_band(C, gs, h, a.eps_mult, delta, a.threads);
    for (std::size_t v = 0; v < n; ++v) if (!sample[v]) delta[v] = 0.0;
  }
  if (have_sc0) {
    for (std::size_t v = 0; v < n; ++v) {
      if (!sample[v]) continue;
      const double r = std::max(rho[v], 0.1);
      const double e =
          -sc0.dcompliance[v] / (params.penalty * std::pow(r, params.penalty - 1.0) *
                                 params.youngs_modulus) * params.youngs_modulus;
      raw_vel[v] = e;
      // ★ THE DISCRETE FORM: dC/drho * (1-rho_min), i.e. the same measure
      // weighted by the derivative of the ACTUAL stiffness law rather than by
      // the continuum energy release. See the header.
      raw_vel_disc[v] = -sc0.dcompliance[v] * (1.0 - rho_min);
    }
  }

  std::vector<double> dc(L.count(), 0.0), dv(L.count(), 0.0),
      dc_disc(L.count(), 0.0), dvtmp(L.count(), 0.0);
  if (!a.heaviside && a.sens_exact) {
    std::vector<double> wv(n, 0.0);
    for (std::size_t v = 0; v < n; ++v) if (delta[v] > 0.0) wv[v] = 1.0;
    plsm_frac_scatter(C, nx, ny, nz, L, basis, gs, h, a.eps_mult, raw_vel, dc,
                      wv, dv, a.threads);
    if (have_sc0)
      plsm_frac_scatter(C, nx, ny, nz, L, basis, gs, h, a.eps_mult,
                        raw_vel_disc, dc_disc, wv, dvtmp, a.threads);
  } else {
    std::vector<double> ed(n, 0.0);
    for (std::size_t v = 0; v < n; ++v) ed[v] = raw_vel[v] * delta[v];
    plsm_spmv(PsiT, ed, dc, a.threads);
    plsm_spmv(PsiT, delta, dv, a.threads);
    if (have_sc0) {
      for (std::size_t v = 0; v < n; ++v) ed[v] = raw_vel_disc[v] * delta[v];
      plsm_spmv(PsiT, ed, dc_disc, a.threads);
    }
  }
  for (double& c : dc) c = -c;        // as plsm_optimize negates it
  for (double& c : dc_disc) c = -c;
  // dV/dalpha_i = -dv[i];  dC/dalpha_i = -dc[i]  (see the header)

  // ── the probe directions ─────────────────────────────────────────────────
  struct Dir { std::string name; std::vector<double> d; };
  std::vector<Dir> dirs;
  for (int q = 0; q < a.n_dirs; ++q) {
    unsigned s = 12345u + static_cast<unsigned>(q) * 7919u;
    Dir D;
    D.name = "random dir " + std::to_string(q);
    D.d.assign(L.count(), 0.0);
    double nrm = 0.0;
    for (std::size_t i = 0; i < L.count(); ++i) { D.d[i] = lcg(s); nrm += D.d[i] * D.d[i]; }
    nrm = std::sqrt(nrm);
    if (nrm > 0.0) for (double& x : D.d) x /= nrm;
    dirs.push_back(std::move(D));
  }
  {
    // The coefficients the volume is most sensitive to — the ones a general
    // direction is dominated by, and the ones a single-coefficient check would
    // pick. Ranked from the analytic dV so the ranking costs nothing extra.
    // A selection of the top n_coeffs, not a full sort: it is what is wanted,
    // and it is deterministic without depending on a comparator's tie-breaking.
    std::vector<char> taken(L.count(), 0);
    for (int q = 0; q < a.n_coeffs; ++q) {
      std::size_t best = L.count();
      double bestv = -1.0;
      for (std::size_t i = 0; i < L.count(); ++i) {
        if (taken[i]) continue;
        const double m = std::fabs(dv[i]);
        if (m > bestv) { bestv = m; best = i; }
      }
      if (best >= L.count()) break;
      taken[best] = 1;
      Dir D;
      D.name = "coefficient " + std::to_string(best);
      D.d.assign(L.count(), 0.0);
      D.d[best] = 1.0;
      dirs.push_back(std::move(D));
    }
  }

  std::string csv = "functional,probe,step,analytic,central_difference,rel_error_pct\n";
  auto rel = [](double an, double fd) {
    return fd != 0.0 ? (an - fd) / std::fabs(fd) * 100.0
                     : std::numeric_limits<double>::quiet_NaN();
  };

  std::printf("\n== dV/dalpha — the VOLUME, central difference, swept ==\n");
  std::printf("%-22s", "probe");
  for (double st : a.steps) std::printf("%12.4g", st);
  std::printf("\n");
  const std::vector<double> alpha0 = alpha;
  for (const Dir& D : dirs) {
    double an = 0.0;
    for (std::size_t i = 0; i < L.count(); ++i) an += -dv[i] * D.d[i];
    std::printf("%-22s", D.name.c_str());
    for (double st : a.steps) {
      for (std::size_t i = 0; i < L.count(); ++i) alpha[i] = alpha0[i] + st * D.d[i];
      rebuild();
      const double vp = volume_now();
      for (std::size_t i = 0; i < L.count(); ++i) alpha[i] = alpha0[i] - st * D.d[i];
      rebuild();
      const double vm = volume_now();
      const double fd = (vp - vm) / (2.0 * st);
      std::printf("%11.3f%%", rel(an, fd));
      char buf[256];
      std::snprintf(buf, sizeof(buf), "V,%s,%.6g,%.10g,%.10g,%.4f\n",
                    D.name.c_str(), st, an, fd, rel(an, fd));
      csv += buf;
    }
    std::printf("      analytic %.6g\n", an);
    alpha = alpha0;
  }

  if (a.compliance) {
    std::printf(
        "\n== dC/dalpha — the COMPLIANCE, two state solves per point ==\n"
        "   'continuum' is the shipped weight (the strain-energy density e_v).\n"
        "   'discrete'  is dC/drho_v * (1 - rho_min) — the derivative of the\n"
        "               ACTUAL stiffness law, which differs from the continuum\n"
        "               form by p (1-rho_min) rho^(p-1) and coincides at p = 1.\n");
    std::printf("%-22s%10s%14s%14s\n", "probe", "step", "continuum", "discrete");
    for (const Dir& D : dirs) {
      double an = 0.0, an_d = 0.0;
      for (std::size_t i = 0; i < L.count(); ++i) {
        an += -dc[i] * D.d[i];
        an_d += -dc_disc[i] * D.d[i];
      }
      for (double st : a.csteps) {
        for (std::size_t i = 0; i < L.count(); ++i) alpha[i] = alpha0[i] + st * D.d[i];
        rebuild();
        const double cp = compliance_now().compliance;
        for (std::size_t i = 0; i < L.count(); ++i) alpha[i] = alpha0[i] - st * D.d[i];
        rebuild();
        const double cm = compliance_now().compliance;
        const double fd = (cp - cm) / (2.0 * st);
        std::printf("%-22s%10.4g%13.3f%%%13.3f%%\n", D.name.c_str(), st,
                    rel(an, fd), rel(an_d, fd));
        char buf[320];
        std::snprintf(buf, sizeof(buf), "C_continuum,%s,%.6g,%.10g,%.10g,%.4f\n",
                      D.name.c_str(), st, an, fd, rel(an, fd));
        csv += buf;
        std::snprintf(buf, sizeof(buf), "C_discrete,%s,%.6g,%.10g,%.10g,%.4f\n",
                      D.name.c_str(), st, an_d, fd, rel(an_d, fd));
        csv += buf;
      }
      alpha = alpha0;
    }
  }

  {
    const std::string path = a.out + "/frac_fd.csv";
    std::ofstream f(path);
    if (!f) die("cannot write " + path);
    f << csv;
    std::printf("\nwrote %s\n", path.c_str());
  }
  return 0;
}
