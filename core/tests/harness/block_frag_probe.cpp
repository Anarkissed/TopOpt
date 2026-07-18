// block_frag_probe.cpp — diagnosis harness (NOT a CI test) for the 3D
// solid-block cantilever fragmentation report. Reproduces the "test Tendrils"
// device case: a long solid block, anchored on one end face, a small LOAD TAB
// at the far end, run through the SAME production configuration minimize_plastic
// uses (MMA updater, plateau window=10, physical rmin floored at 1.5 vox, the
// 3-voxel FrozenSolid anchor+load pad, Load/Fixture forced FrozenSolid), one
// independent simp_optimize per ladder rung.
//
// It instruments what the render cannot show:
//   * density AT the load-face voxels (STEP 0b)
//   * 6-connectivity of the PRINTED field: #components, largest fraction, and
//     whether the load voxels and the anchor voxels sit in ONE component
//   * the rmin actually used and the density transition width
//
// argv[1] = plateau window (10 = production plateau; 0 = cap-60 restore, STEP 1)
// argv[2] = cap when window==0 (default 60)

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <queue>
#include <string>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {

constexpr double kIso = 0.5;

// A long solid block: nx along the cantilever, ny x nz cross-section. Fixture
// on the whole i=0 end face; a small LOAD tab (tw x tw cross-section, td deep)
// centred on the far i=nx-1 end face.
struct Geom {
  VoxelGrid grid;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  DesignMask pad;                 // Active + FrozenSolid anchor/load pad
  std::vector<std::size_t> load_vox;
  std::vector<std::size_t> fix_vox;
};

// Geometry: a solid block of full ny x nz cross-section for i in [0, lblock),
// then a PROTRUDING load tab (tw x tw central patch) for i in [lblock, nx); the
// rest of the tab layers are Empty. This mirrors the device case: a 20x20x15 tab
// sticking out beyond the 250mm block, joined to it only by the tw x tw neck.
// `embedded=true` restores the old fully-embedded tab (block fills the whole nx).
Geom make_block(int nx, int ny, int nz, double h, int tw, int td,
                double tip_force, int pad_depth, bool self_weight,
                bool embedded) {
  Geom G;
  VoxelGrid& g = G.grid;
  g.nx = nx; g.ny = ny; g.nz = nz; g.spacing = h;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Empty);

  const int lblock = embedded ? nx : nx - td;  // block occupies i in [0, lblock)
  const int j0 = (ny - tw) / 2, k0 = (nz - tw) / 2;

  // Block body: full cross-section, Interior.
  for (int i = 0; i < lblock; ++i)
    for (int k = 0; k < nz; ++k)
      for (int j = 0; j < ny; ++j)
        g.set_tag(i, j, k, VoxelTag::Interior);

  // Protruding tab: tw x tw central patch for i in [lblock, nx).
  if (!embedded)
    for (int i = lblock; i < nx; ++i)
      for (int k = k0; k < k0 + tw; ++k)
        for (int j = j0; j < j0 + tw; ++j)
          g.set_tag(i, j, k, VoxelTag::Interior);

  // Anchor: whole i=0 face -> Fixture (clamped).
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j) {
      g.set_tag(0, j, k, VoxelTag::Fixture);
      G.fix_vox.push_back(g.index(0, j, k));
    }
  for (int c = 0; c <= nz; ++c)
    for (int b = 0; b <= ny; ++b) {
      const int n = fea_node_index(g, 0, b, c);
      G.bcs.push_back({n, 0, 0.0});
      G.bcs.push_back({n, 1, 0.0});
      G.bcs.push_back({n, 2, 0.0});
    }

  // Load tab surface -> Load: the tab's far face (last td layers over the patch).
  for (int i = nx - td; i < nx; ++i)
    for (int k = k0; k < k0 + tw; ++k)
      for (int j = j0; j < j0 + tw; ++j) {
        g.set_tag(i, j, k, VoxelTag::Load);
        G.load_vox.push_back(g.index(i, j, k));
      }

  if (self_weight) {
    // Self-weight only: NO external load, and the tab is NOT tagged Load (so it
    // is a free design variable, exactly as a pure self-weight run would see it).
    for (std::size_t idx : G.load_vox) g.tags[idx] = VoxelTag::Interior;
    G.load_vox.clear();
    G.loads = self_weight_loads(g, 1.24e-3, 9810.0 * 1e-9, Vec3{0, 0, -1});
  } else {
    // Traction load over the exposed Load faces, downward (-z): a tip shear.
    G.loads = traction_loads(g, VoxelTag::Load, Vec3{0, 0, -tip_force});
  }

  // The bridge's anchor+load structural pad: first `pad_depth` solid layers
  // behind each anchor/load face, FrozenSolid (mask_step_face walks solid layers
  // inward). Anchor: i in [0,pad_depth) full cross-section. Load: the outer
  // `pad_depth` tab layers over the patch — this leaves the NECK (the tab layer
  // adjacent to the block, plus the block boundary) as ACTIVE design variables,
  // exactly as the real pad does.
  G.pad = make_active_mask(g);
  for (int d = 0; d < pad_depth; ++d)
    for (int k = 0; k < nz; ++k)
      for (int j = 0; j < ny; ++j)
        G.pad[g.index(d, j, k)] = MaskValue::FrozenSolid;             // anchor
  if (!self_weight)
    for (int d = 0; d < pad_depth; ++d)
      for (int k = k0; k < k0 + tw; ++k)
        for (int j = j0; j < j0 + tw; ++j) {
          const int i = nx - 1 - d;
          if (i >= 0 && g.solid(i, j, k))
            G.pad[g.index(i, j, k)] = MaskValue::FrozenSolid;
        }
  return G;
}

// 6-connectivity flood fill over the printed set (rho > iso). Returns component
// id per voxel (-1 if not printed) and the component sizes.
struct Components {
  std::vector<int> id;
  std::vector<std::size_t> size;
};
Components connected(const VoxelGrid& g, const std::vector<double>& rho) {
  const int nx = g.nx, ny = g.ny, nz = g.nz;
  Components C;
  C.id.assign(g.voxel_count(), -1);
  auto printed = [&](int i, int j, int k) {
    return rho[g.index(i, j, k)] > kIso;
  };
  int next = 0;
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        if (!printed(i, j, k) || C.id[g.index(i, j, k)] >= 0) continue;
        std::size_t sz = 0;
        std::queue<std::array<int, 3>> q;
        q.push({i, j, k});
        C.id[g.index(i, j, k)] = next;
        while (!q.empty()) {
          auto [ci, cj, ck] = q.front(); q.pop();
          ++sz;
          const int dd[6][3] = {{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}};
          for (auto& d : dd) {
            const int ni = ci+d[0], nj = cj+d[1], nk = ck+d[2];
            if (ni<0||nj<0||nk<0||ni>=nx||nj>=ny||nk>=nz) continue;
            if (!printed(ni,nj,nk)) continue;
            if (C.id[g.index(ni,nj,nk)] >= 0) continue;
            C.id[g.index(ni,nj,nk)] = next;
            q.push({ni,nj,nk});
          }
        }
        C.size.push_back(sz);
        ++next;
      }
  return C;
}

void analyze(const char* tag, const Geom& G, const std::vector<double>& rho) {
  const VoxelGrid& g = G.grid;
  // Load-face density.
  double lmin = 1e9, lmax = -1e9, lsum = 0;
  int lprinted = 0;
  for (std::size_t idx : G.load_vox) {
    const double d = rho[idx];
    lmin = std::min(lmin, d); lmax = std::max(lmax, d); lsum += d;
    if (d > kIso) ++lprinted;
  }
  const std::size_t nl = G.load_vox.size();

  // Printed count + connectivity.
  std::size_t printed = 0;
  for (double d : rho) if (d > kIso) ++printed;
  Components C = connected(g, rho);
  std::size_t largest = 0; int largest_id = -1;
  for (std::size_t c = 0; c < C.size.size(); ++c)
    if (C.size[c] > largest) { largest = C.size[c]; largest_id = c; }

  // Which component holds the load voxels? the anchor voxels?
  auto comp_of_set = [&](const std::vector<std::size_t>& set) {
    // majority component among printed voxels of the set
    std::vector<std::size_t> tally(C.size.size(), 0);
    for (std::size_t idx : set) if (C.id[idx] >= 0) tally[C.id[idx]]++;
    int best = -1; std::size_t bn = 0;
    for (std::size_t c = 0; c < tally.size(); ++c) if (tally[c] > bn) { bn = tally[c]; best = c; }
    return best;
  };
  const int lc = comp_of_set(G.load_vox);
  const int fc = comp_of_set(G.fix_vox);

  std::printf("[%s] printed=%zu  components=%zu  largest=%zu (%.1f%% of printed)\n",
              tag, printed, C.size.size(), largest,
              printed ? 100.0 * largest / printed : 0.0);
  std::printf("[%s] LOAD-face voxels=%zu  printed>iso=%d  rho[min=%.4f mean=%.4f max=%.4f]\n",
              tag, nl, lprinted, lmin, nl ? lsum / nl : 0.0, lmax);
  std::printf("[%s] load-comp=%d (size %zu)  fixture-comp=%d (size %zu)  "
              "SAME-COMPONENT=%s  load-comp-is-largest=%s\n",
              tag, lc, lc>=0?C.size[lc]:0, fc, fc>=0?C.size[fc]:0,
              (lc>=0 && lc==fc) ? "YES" : "NO",
              (lc>=0 && lc==largest_id) ? "YES" : "NO");
  // How many components would a keep-largest mesh drop, and do they carry load?
  std::size_t dropped = 0, dropped_vox = 0;
  for (std::size_t c = 0; c < C.size.size(); ++c)
    if ((int)c != largest_id) { ++dropped; dropped_vox += C.size[c]; }
  std::printf("[%s] keep-largest would DROP %zu components (%zu voxels); "
              "load tab in a dropped comp=%s\n",
              tag, dropped, dropped_vox,
              (lc>=0 && lc!=largest_id) ? "YES (tab vanishes from render)" : "no");
  std::fflush(stdout);
}

}  // namespace

int main(int argc, char** argv) {
  const int window = argc > 1 ? std::atoi(argv[1]) : 10;
  const int cap = argc > 2 ? std::atoi(argv[2]) : 60;
  // Solver: "mf" (matrix-free MG-CG, production, threaded) or "jc" (JacobiCG).
  const char* solver_env = std::getenv("TOPOPT_SOLVER");
  const bool use_mf = !(solver_env && std::string(solver_env) == "jc");
  // Optional hard cap override (quick timing / smoke); 0 = use config default.
  const char* capovr_env = std::getenv("TOPOPT_CAPOVR");
  const int cap_override = capovr_env ? std::atoi(capovr_env) : 0;
  // Optional single-rung mode (quick): run only the vf given by TOPOPT_ONEVF.
  const char* onevf_env = std::getenv("TOPOPT_ONEVF");
  const double one_vf = onevf_env ? std::atof(onevf_env) : 0.0;

  // Geometry ~ device case: 64 x 20 x 20 at h=4.1mm (block ~262 x 82 x 82),
  // load tab 5x5x4 vox (~20x20x16mm) on the far end, anchored on the i=0 face.
  const double h = 4.1;
  const int pad_depth = 3;  // kAnchorPadDepthVoxels
  const bool self_weight = std::getenv("TOPOPT_SELFWEIGHT") != nullptr;
  const bool embedded = std::getenv("TOPOPT_EMBEDDED") != nullptr;
  Geom G = make_block(64, 20, 20, h, 5, 4, 100.0, pad_depth, self_weight,
                      embedded);
  std::printf("== geom: %s tab  load=%s ==\n", embedded ? "EMBEDDED" : "PROTRUDING",
              self_weight ? "SELF-WEIGHT (tab NOT frozen)" : "external tip shear");

  // Physical rmin exactly like the bridge: min_feature_mm = 2.5, floor 1.5 vox.
  const double rmin = physical_filter_radius(2.5, h);  // -> 1.5 (floored)
  std::printf("== config: window=%d cap=%d  h=%.3f  rmin=%.4f vox (%.2f mm)  "
              "pad_depth=%d ==\n",
              window, cap, h, rmin, rmin * h, pad_depth);
  std::printf("== grid %dx%dx%d  solid=%zu  load_vox=%zu  fix_vox=%zu ==\n",
              G.grid.nx, G.grid.ny, G.grid.nz, G.grid.solid_count(),
              G.load_vox.size(), G.fix_vox.size());

  SimpParams params;
  params.youngs_modulus = 2000.0;   // MPa (PLA-ish; only scales compliance)
  params.poisson = 0.35;
  params.penalty = 3.0;

  std::vector<double> ladder = {0.68, 0.52, 0.38, 0.26};
  if (one_vf > 0.0) ladder = {one_vf};
  std::printf("== solver=%s ==\n", use_mf ? "MultigridCG_Matfree" : "JacobiCG");
  for (double vf : ladder) {
    SimpOptions opt;
    opt.volume_fraction = vf;
    opt.filter_radius = rmin;
    opt.move = 0.2;
    opt.updater = SimpUpdater::MMA;
    opt.solver = use_mf ? SolverKind::MultigridCG_Matfree : SolverKind::JacobiCG;
    opt.cg_tolerance = 1e-8;
    if (window > 0) {
      opt.max_iterations = 200;
      opt.mma_plateau_window = window;
      opt.mma_plateau_tol = 1e-3;
      opt.mma_plateau_min_drop = 0.05;
      opt.change_tol = 0.0;
    } else {
      opt.max_iterations = cap;          // cap-60 restore
      opt.mma_plateau_window = 0;
      opt.change_tol = 0.0;              // run the full cap
    }
    if (cap_override > 0) opt.max_iterations = cap_override;
    SimpOptimizeResult r =
        simp_optimize(G.grid, params, G.bcs, G.loads, opt, G.pad);
    char tag[64];
    std::snprintf(tag, sizeof(tag), "vf%.2f w%d", vf, window);
    std::printf("\n[%s] iters=%d converged=%d compliance=%.6e vf_ach=%.4f\n",
                tag, r.iterations, (int)r.converged, r.compliance,
                r.volume_fraction);
    analyze(tag, G, r.physical_density);
  }
  return 0;
}
