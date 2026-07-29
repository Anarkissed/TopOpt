// void_dof_probe.cpp — measurement harness (NOT a CI test) for the void-DOF
// elimination Phase-0 feasibility study (docs/handoffs/2026-07-28-void-dof-
// elimination-phase0.md). READ-ONLY: it reconstructs the real design-box
// stagnation case through the PRODUCTION expand_design_domain path, runs the
// production MMA + matrix-free-multigrid SIMP per ladder rung, and then answers
// E1/E2/E4 with numbers on each rung's CONVERGED physical density field.
//
// The fixture is the canonical stagnation case draft_arming_gate::make_big_stagnation
// (l_bracket 24x24x6x6, box [-12,-13,-12]..[36,19,36] -> 48x32x48 = 73,728 voxels,
// the same grid ad_stag_mechanism_probe.cpp measures), NOT a toy (BAR B1).
//
// E1  per rung, per void-threshold rho_t: how many free DOFs are touched ONLY by
//     void elements (rho <= rho_t) -> can be eliminated; the free-DOF reduction;
//     and the contrast (maxE/minE) of the REMAINING (surviving-element) operator
//     vs the full operator.
// E2  reuse the handoff-169 connectivity belt (26-connectivity flood-fill,
//     load_path_connected's exact walk) to count FLOATING solid regions — surviving
//     solid components not reachable from a Fixture/Load anchor — per rung.
// E4  the stagnating case: full vs void-reduced (active_mask) Jacobi-CG AND
//     MG-matfree CG on each converged rung field — measured iteration + wall change.
//
// B2  rho_t is swept {1.5e-3 (=1.5*rho_min, the Active-Domain core threshold),
//     1e-2, 5e-2, 1e-1, 3e-1, 5e-1}; the tables ARE the sensitivity.
//
// Build (standalone, not wired to CTest):
//   c++ -std=c++17 -O3 -I core/include core/tests/harness/void_dof_probe.cpp \
//       core/build/libtopopt.a -pthread -o /tmp/void_dof_probe

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {

// ---- fixture (verbatim geometry from ad_stag_mechanism_probe / draft_arming_gate)
VoxelGrid l_bracket(std::vector<DirichletBC>& bcs, int arm, int span, int ny, int t,
                    double h) {
  VoxelGrid g;
  g.nx = span; g.ny = ny; g.nz = arm; g.spacing = h;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(span) * ny * arm, VoxelTag::Empty);
  for (int k = 0; k < arm; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < span; ++i)
        if (i < t || k < t) g.set_tag(i, j, k, VoxelTag::Interior);
  for (int j = 0; j < ny; ++j)
    for (int i = 0; i < t; ++i) g.set_tag(i, j, arm - 1, VoxelTag::Fixture);
  bcs.clear();
  for (int b = 0; b <= ny; ++b)
    for (int a = 0; a <= t; ++a) {
      const int n = fea_node_index(g, a, b, arm);
      bcs.push_back({n, 0, 0.0});
      bcs.push_back({n, 1, 0.0});
      bcs.push_back({n, 2, 0.0});
    }
  for (int k = 0; k < t; ++k)
    for (int j = 0; j < ny; ++j) g.set_tag(span - 1, j, k, VoxelTag::Load);
  return g;
}

// element Young's modulus under SIMP: E(rho)=clamp(rho,rho_min,1)^p * E0
double elem_E(double rho, double rho_min, double p, double E0) {
  double r = std::min(1.0, std::max(rho_min, rho));
  return std::pow(r, p) * E0;
}

// The 8 corner-node global ids of voxel (i,j,k) — thin wrapper for clarity.
std::array<int, 8> nodes_of(const VoxelGrid& g, int i, int j, int k) {
  return fea_element_nodes(g, i, j, k);
}

struct RungField {
  double vf = 0.0;
  double init_grey = 0.0;
  std::vector<double> rho;   // physical density, size voxel_count
  int iters = 0;
  double compliance = 0.0;
  bool converged = false;
};

// ---------- E1/E2 analysis on one field at one threshold -----------------------
struct ThreshStats {
  double rho_t = 0.0;
  std::size_t n_solid_elem = 0, n_survive_elem = 0;   // elements
  std::size_t free_dofs_full = 0, free_dofs_reduced = 0, dofs_eliminated = 0;
  double contrast_full = 0.0, contrast_reduced = 0.0;
  double min_survive_rho = 0.0;
  // E2
  int components = 0, anchored_components = 0, floating_components = 0;
  std::size_t floating_elems = 0;
  bool load_path_connected_reduced = false;
};

// Free-DOF set = the M3.1 void gate: a DOF survives iff some KEPT element touches
// it AND it is not a Dirichlet-fixed DOF. We count over the grid's node DOFs.
ThreshStats analyze(const VoxelGrid& g, const std::vector<double>& rho,
                    const std::vector<DirichletBC>& bcs, double rho_t,
                    double rho_min, double p, double E0) {
  ThreshStats s;
  s.rho_t = rho_t;
  const std::size_t nnode = static_cast<std::size_t>(fea_node_count(g));

  std::vector<char> fixed(3 * nnode, 0);
  for (const auto& bc : bcs)
    fixed[static_cast<std::size_t>(3 * bc.node + bc.component)] = 1;

  // node touched by >=1 SOLID element (full system) and by >=1 SURVIVING element.
  std::vector<char> touched_full(nnode, 0), touched_keep(nnode, 0);
  // survivor element flag per voxel (kept = solid AND rho>rho_t, plus BC pin so the
  // load gate is never handed a load on a stiffness-free DOF — the AD BC pin rule).
  std::vector<char> keep(g.voxel_count(), 0);

  double maxE = 0.0, minE_full = 1e300, minE_keep = 1e300;
  s.min_survive_rho = 1e300;

  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        if (!g.solid(i, j, k)) continue;
        const std::size_t e = g.index(i, j, k);
        ++s.n_solid_elem;
        const double E = elem_E(rho[e], rho_min, p, E0);
        maxE = std::max(maxE, E);
        minE_full = std::min(minE_full, E);
        const auto nd = nodes_of(g, i, j, k);
        for (int c = 0; c < 8; ++c) touched_full[static_cast<std::size_t>(nd[c])] = 1;
        const VoxelTag tg = g.tag(i, j, k);
        const bool bc_pin = (tg == VoxelTag::Load || tg == VoxelTag::Fixture);
        if (rho[e] > rho_t || bc_pin) {
          keep[e] = 1;
          ++s.n_survive_elem;
          minE_keep = std::min(minE_keep, E);
          s.min_survive_rho = std::min(s.min_survive_rho, rho[e]);
          for (int c = 0; c < 8; ++c) touched_keep[static_cast<std::size_t>(nd[c])] = 1;
        }
      }

  for (std::size_t nnid = 0; nnid < nnode; ++nnid)
    for (int c = 0; c < 3; ++c) {
      const std::size_t d = 3 * nnid + c;
      if (fixed[d]) continue;
      if (touched_full[nnid]) ++s.free_dofs_full;
      if (touched_keep[nnid]) ++s.free_dofs_reduced;
    }
  s.dofs_eliminated = s.free_dofs_full - s.free_dofs_reduced;
  s.contrast_full = (minE_full > 0) ? maxE / minE_full : 0.0;
  s.contrast_reduced = (minE_keep < 1e299 && minE_keep > 0) ? maxE / minE_keep : 0.0;
  if (s.min_survive_rho > 1e299) s.min_survive_rho = 0.0;

  // ---- E2: connected components of the KEPT element set, 26-connectivity ------
  // (the exact walk load_path_connected uses; voxel adjacency = node sharing.)
  std::vector<int> label(g.voxel_count(), -1);
  auto keep_at = [&](int i, int j, int k) {
    if (i < 0 || j < 0 || k < 0 || i >= g.nx || j >= g.ny || k >= g.nz) return false;
    return keep[g.index(i, j, k)] != 0;
  };
  std::vector<std::size_t> stack;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        if (!keep_at(i, j, k)) continue;
        const std::size_t root = g.index(i, j, k);
        if (label[root] != -1) continue;
        const int lab = s.components++;
        label[root] = lab;
        stack.clear();
        stack.push_back(root);
        bool anchored = false;
        std::size_t esz = 0;
        while (!stack.empty()) {
          const std::size_t idx = stack.back(); stack.pop_back();
          ++esz;
          const int ci = static_cast<int>(idx % g.nx);
          const int cj = static_cast<int>((idx / g.nx) % g.ny);
          const int ck = static_cast<int>(idx / (static_cast<std::size_t>(g.nx) * g.ny));
          const VoxelTag tg = g.tags[idx];
          if (tg == VoxelTag::Load || tg == VoxelTag::Fixture) anchored = true;
          for (int dk = -1; dk <= 1; ++dk)
            for (int dj = -1; dj <= 1; ++dj)
              for (int di = -1; di <= 1; ++di) {
                if (!di && !dj && !dk) continue;
                const int ni = ci + di, nj = cj + dj, nk = ck + dk;
                if (!keep_at(ni, nj, nk)) continue;
                const std::size_t nidx = g.index(ni, nj, nk);
                if (label[nidx] != -1) continue;
                label[nidx] = lab;
                stack.push_back(nidx);
              }
        }
        if (anchored) ++s.anchored_components;
        else { ++s.floating_components; s.floating_elems += esz; }
      }

  // Does a load path survive under this reduced set? (density=1 on kept, 0 else)
  std::vector<double> rho01(g.voxel_count(), 0.0);
  for (std::size_t e = 0; e < g.voxel_count(); ++e) rho01[e] = keep[e] ? 1.0 : 0.0;
  s.load_path_connected_reduced = load_path_connected(g, rho01, 0.5);
  return s;
}

std::string human(double x) {
  char b[32];
  if (x >= 1e6) std::snprintf(b, sizeof b, "%.2e", x);
  else std::snprintf(b, sizeof b, "%.0f", x);
  return b;
}

}  // namespace

int main(int argc, char** argv) {
  std::setvbuf(stdout, nullptr, _IOLBF, 0);
  fea_set_matfree_galerkin_block_cache(true);
  fea_set_krylov_recycling(false);  // isolate; recycling collision is analyzed in E3

  // ---- reconstruct the dilute stagnation domain -----------------------------
  // Proportionally-identical tractable reduction of the canonical 48^3 / 96x80x96
  // stagnation case (removal_probe.cpp's rationale: the dilute high-contrast
  // regime and its density trajectory are scale-invariant; the absolute CG cost
  // grows with N, which is exactly why the full grid is intractable to converge
  // here — 15,349 CG @48^3, ~11.5 h @128^3). Part is ~4% of the box, contrast
  // 1e-9, so this IS the stagnation mechanism, not a toy — the MG->Jacobi
  // fallback and CG counts printed below are the proof.
  const double h = 1.0;
  std::vector<DirichletBC> pbcs;
  VoxelGrid part = l_bracket(pbcs, /*arm=*/20, /*span=*/20, /*ny=*/8, /*t=*/4, h);
  DesignBox box;
  box.min = Vec3{0.0, 0.0, 0.0};
  box.max = Vec3{32.0, 24.0, 32.0};
  const DesignDomain dom =
      expand_design_domain(part, box, {}, /*freeze_part=*/false, kDesignBoxCoarsenAlign);
  const VoxelGrid& G = dom.grid;
  const DesignMask& mask = dom.mask;

  std::vector<DirichletBC> bcs;
  for (const auto& bc : pbcs)
    bcs.push_back({remap_node_to_domain(part, dom, bc.node), bc.component, bc.value});
  // Traction is computed on the PART grid (its Load faces are exposed) and then
  // node-remapped to the domain, exactly as minimize_plastic does with the box.
  std::vector<NodalLoad> loads =
      traction_loads(part, VoxelTag::Load, Vec3{0.0, 0.0, -30.0});
  for (auto& ld : loads) ld.node = remap_node_to_domain(part, dom, ld.node);

  const double rho_min = 1e-3, p = 3.0, E0 = 3500.0, nu = 0.33;
  const std::size_t nvox = G.voxel_count();
  const std::size_t nelem = G.solid_count();
  std::size_t n_active = 0, n_load = 0, n_fix = 0;
  double active_eff = 0.0, frozen_eff = 0.0;
  for (std::size_t e = 0; e < nvox; ++e) {
    const VoxelTag tg = G.tags[e];
    if (tg == VoxelTag::Load) ++n_load;
    if (tg == VoxelTag::Fixture) ++n_fix;
    if (tg == VoxelTag::Load || tg == VoxelTag::Fixture ||
        mask[e] == MaskValue::FrozenSolid) { frozen_eff += 1.0; continue; }
    if (mask[e] != MaskValue::Active) continue;
    if (tg == VoxelTag::Empty) continue;
    active_eff += 1.0;
    ++n_active;
  }
  const double est_dofs = 3.0 * (G.nx + 1) * (G.ny + 1) * (G.nz + 1);

  std::printf("======================================================================\n");
  std::printf("VOID-DOF ELIMINATION — PHASE 0 FEASIBILITY  (read-only measurement)\n");
  std::printf("======================================================================\n");
  std::printf("fixture: big-stagnation l-bracket, box->expanded grid %dx%dx%d = %zu voxels\n",
              G.nx, G.ny, G.nz, nvox);
  std::printf("part solid=%zu  domain elements(non-Empty)=%zu  Active=%zu  Load=%zu Fixture=%zu\n",
              (size_t)part.solid_count(), nelem, n_active, n_load, n_fix);
  std::printf("est total DOFs 3*(nx+1)(ny+1)(nz+1)=%.0f ; SIMP: rho_min=%.0e p=%.1f E0=%.0f nu=%.2f\n",
              est_dofs, rho_min, p, E0, nu);
  std::printf("full contrast at rho=rho_min: (rho_min)^-p = %.3e\n\n", std::pow(rho_min, -p));

  // ---- run the ladder, capture each rung's converged physical field ----------
  const std::vector<double> ladder = {0.68, 0.52, 0.38, 0.26};
  const int max_it = (argc > 1) ? std::atoi(argv[1]) : 25;

  std::vector<RungField> rungs;
  for (double vf : ladder) {
    double sf = vf;
    if (active_eff > 0.0) {
      const double target = vf * static_cast<double>(part.solid_count()) - frozen_eff;
      sf = std::min(1.0, std::max(rho_min, target / active_eff));
    }
    SimpParams params;
    params.youngs_modulus = E0; params.poisson = nu; params.penalty = p;
    params.density_min = rho_min;
    SimpOptions opt;
    opt.updater = SimpUpdater::MMA;                 // production updater (no Heaviside)
    opt.solver = SolverKind::MultigridCG_Matfree;   // production design-box solver
    opt.volume_fraction = sf;
    opt.filter_radius = 2.0;
    opt.move = 0.2;
    opt.max_iterations = max_it;
    opt.change_tol = 0.01;   // stop at plateau (dilute field has drained)
    opt.cg_tolerance = 1e-6; // feasibility field; loose enough to survive stagnation
    // Safety net: capture the last iterate so a rung whose LATER solve stagnates
    // (SolverNonConvergence — the very disease we study) still yields its field.
    std::vector<double> last_rho;
    int last_iter = 0;
    opt.keyframe_stride = 1;
    opt.keyframe = [&](const std::vector<double>& rho) { last_rho = rho; ++last_iter; };
    std::printf("--- optimizing rung vf=%.2f (rescaled grey=%.5f, cap=%d iters) ...\n",
                vf, sf, max_it);
    const auto t0 = std::chrono::steady_clock::now();
    RungField rf;
    rf.vf = vf; rf.init_grey = sf;
    bool threw = false; std::string msg;
    try {
      SimpOptimizeResult res = simp_optimize(G, params, bcs, loads, opt, mask);
      rf.rho = res.physical_density; rf.iters = res.iterations;
      rf.compliance = res.compliance; rf.converged = res.converged;
    } catch (const std::exception& e) {
      threw = true; msg = e.what();
      rf.rho = last_rho; rf.iters = last_iter; rf.compliance = 0.0; rf.converged = false;
    }
    const double wall = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - t0).count();
    if (rf.rho.empty()) { std::printf("    SKIP: no field captured (%s)\n", msg.c_str()); continue; }
    rungs.push_back(std::move(rf));
    std::printf("    done: iters=%d compliance=%.4e converged=%d (%.1fs)%s\n",
                rungs.back().iters, rungs.back().compliance, rungs.back().converged ? 1 : 0,
                wall, threw ? (" [STAGNATED->last iterate; " + msg + "]").c_str() : "");
  }

  const std::vector<double> thresholds = {1.5e-3, 1e-2, 5e-2, 1e-1, 3e-1, 5e-1};

  // =========================== E1 + E2 TABLE ==================================
  std::printf("\n======================================================================\n");
  std::printf("E1 (DOF elimination + contrast) + E2 (floating regions), per rung\n");
  std::printf("======================================================================\n");
  for (const auto& rf : rungs) {
    std::printf("\n### rung vf=%.2f  (converged iters=%d compliance=%.4e)\n",
                rf.vf, rf.iters, rf.compliance);
    std::printf("%-7s | %9s %9s %6s | %10s %10s %8s | %10s %10s | %6s %6s %6s %5s\n",
                "rho_t", "solidEl", "surviv", "surv%",
                "freeDOF", "reducDOF", "elim%", "contr_full", "contr_red",
                "comp", "anch", "float", "lpc");
    for (double rt : thresholds) {
      ThreshStats s = analyze(G, rf.rho, bcs, rt, rho_min, p, E0);
      std::printf("%-7.4g | %9zu %9zu %5.1f%% | %10zu %10zu %7.1f%% | %10s %10s | %6d %6d %6d %5s\n",
                  rt, s.n_solid_elem, s.n_survive_elem,
                  100.0 * s.n_survive_elem / std::max<std::size_t>(1, s.n_solid_elem),
                  s.free_dofs_full, s.free_dofs_reduced,
                  100.0 * s.dofs_eliminated / std::max<std::size_t>(1, s.free_dofs_full),
                  human(s.contrast_full).c_str(), human(s.contrast_reduced).c_str(),
                  s.components, s.anchored_components, s.floating_components,
                  s.load_path_connected_reduced ? "Y" : "N");
    }
  }

  // =========================== E4 MEASUREMENT =================================
  // For the stagnating rung fields, measure full vs void-reduced CG. The reduced
  // system is realized EXACTLY by the existing active_mask plumbing (the void-DOF
  // gate drops orphaned DOFs). We measure both Jacobi-CG (the stagnation regime)
  // and MG-matfree (production).
  std::printf("\n======================================================================\n");
  std::printf("E4 (stagnating case): full vs void-reduced CG per rung\n");
  std::printf("  reduced := active_mask = (solid AND rho>rho_t) OR Load/Fixture pin\n");
  std::printf("  Jacobi-CG cap=%d tol=1e-8 ; MG-matfree cap=2000 tol=1e-8\n",
              6000);
  std::printf("======================================================================\n");

  auto build_E = [&](const std::vector<double>& rho) {
    std::vector<double> E(nvox, 0.0);
    for (std::size_t e = 0; e < nvox; ++e)
      if (G.tags[e] != VoxelTag::Empty) E[e] = elem_E(rho[e], rho_min, p, E0);
    return E;
  };
  auto make_mask = [&](const std::vector<double>& rho, double rt) {
    std::vector<char> m(nvox, 0);
    for (std::size_t e = 0; e < nvox; ++e) {
      if (G.tags[e] == VoxelTag::Empty) continue;
      const VoxelTag tg = G.tags[e];
      if (rho[e] > rt || tg == VoxelTag::Load || tg == VoxelTag::Fixture) m[e] = 1;
    }
    return m;
  };

  // thresholds to actually solve at (keep it to a few: cheap ones + AD core)
  const std::vector<double> solve_rt = {1.5e-3, 1e-1, 3e-1};

  for (const auto& rf : rungs) {
    const std::vector<double> E = build_E(rf.rho);
    std::printf("\n### rung vf=%.2f\n", rf.vf);

    // FULL Jacobi-CG (the stagnation baseline)
    {
      CgInfo info;
      const auto t0 = std::chrono::steady_clock::now();
      bool ok = true; std::string err;
      try {
        fea_solve_cg_matfree(G, E, nu, bcs, loads, 1e-8, 6000, &info);
      } catch (const std::exception& e) { ok = false; err = e.what(); }
      const double wall = std::chrono::duration<double>(
          std::chrono::steady_clock::now() - t0).count();
      std::printf("  [Jacobi FULL   ] iters=%7d resid=%.2e conv=%d %.2fs%s\n",
                  info.iterations, info.residual, info.converged ? 1 : 0, wall,
                  ok ? "" : (" EXC:" + err).c_str());
    }
    // FULL MG-matfree
    {
      CgInfo info;
      const auto t0 = std::chrono::steady_clock::now();
      bool ok = true; std::string err;
      try {
        fea_solve_mgcg_matfree(G, E, nu, bcs, loads, 1e-8, 2000, &info);
      } catch (const std::exception& e) { ok = false; err = e.what(); }
      const double wall = std::chrono::duration<double>(
          std::chrono::steady_clock::now() - t0).count();
      std::printf("  [MG    FULL   ] iters=%7d resid=%.2e mg=%d cyc=%d %.2fs%s\n",
                  info.iterations, info.residual, info.used_multigrid ? 1 : 0,
                  info.mg_cycles_attempted, wall, ok ? "" : (" EXC:" + err).c_str());
    }
    for (double rt : solve_rt) {
      std::vector<char> m = make_mask(rf.rho, rt);
      std::size_t kept = 0; for (char c : m) kept += (c != 0);
      // REDUCED Jacobi-CG
      CgInfo ij; double wj; bool okj = true; std::string ej;
      {
        const auto t0 = std::chrono::steady_clock::now();
        try { fea_solve_cg_matfree(G, E, nu, bcs, loads, 1e-8, 6000, &ij, nullptr, &m); }
        catch (const std::exception& e) { okj = false; ej = e.what(); }
        wj = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
      }
      // REDUCED MG-matfree
      CgInfo im; double wm; bool okm = true; std::string em;
      {
        const auto t0 = std::chrono::steady_clock::now();
        try { fea_solve_mgcg_matfree(G, E, nu, bcs, loads, 1e-8, 2000, &im, &m); }
        catch (const std::exception& e) { okm = false; em = e.what(); }
        wm = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
      }
      std::printf("  [rho_t=%.4g kept_el=%zu]\n", rt, kept);
      std::printf("      Jacobi RED  iters=%7d resid=%.2e conv=%d %.2fs%s\n",
                  ij.iterations, ij.residual, ij.converged ? 1 : 0, wj,
                  okj ? "" : (" EXC:" + ej).c_str());
      std::printf("      MG     RED  iters=%7d resid=%.2e mg=%d cyc=%d %.2fs%s\n",
                  im.iterations, im.residual, im.used_multigrid ? 1 : 0,
                  im.mg_cycles_attempted, wm, okm ? "" : (" EXC:" + em).c_str());
    }
  }

  fea_set_matfree_galerkin_block_cache(false);
  std::printf("\n[done]\n");
  return 0;
}
