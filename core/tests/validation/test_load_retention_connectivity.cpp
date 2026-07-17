// Diagnosis 095 — 3D-block fragmentation. Regression guards for the two facts the
// diagnosis established:
//
//   (1) An EXTERNALLY LOADED tab is retained AND connected. When the driver runs
//       under a real external load case, the tab (tagged Load -> FrozenSolid, plus
//       the anchor/load structural pad) is pinned to density 1 and its load-bearing
//       neck stays solid, so the PRINTED field (rho > iso) is a single connected
//       body containing BOTH the load and the anchor. This is the healthy result
//       the device expects; it is the invariant the fragmented report violated.
//
//   (2) The silent-self-weight-fall-through is REFUSED. A load-case caller sets
//       require_external_loads; an empty external_loads then throws instead of
//       silently optimizing under self-weight (which strips the unloaded tab and
//       fragments the design — the reported symptom). A genuine self-weight run
//       (require_external_loads == false, the default) is unaffected.
//
// Same self-contained CHECK harness / public-API-only style as the other core
// tests (ARCHITECTURE §4); Eigen-gated in CMake like the other optimizer gates.
// The settings rule table's absolute path is injected (SETTINGS_RULES_PATH).

#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <array>
#include <cstddef>
#include <cstdio>
#include <queue>
#include <stdexcept>
#include <string>
#include <vector>

using topopt::DesignMask;
using topopt::DirichletBC;
using topopt::make_active_mask;
using topopt::MaskValue;
using topopt::Material;
using topopt::MinimizePlasticOptions;
using topopt::MinimizePlasticResult;
using topopt::NodalLoad;
using topopt::Vec3;
using topopt::VoxelGrid;
using topopt::VoxelTag;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                            \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

namespace {

constexpr double kIso = 0.5;

Material pla_material() {
  Material m;
  m.youngs_modulus_mpa = 2000.0;
  m.yield_strength_mpa = 55.0;
  m.density_g_cm3 = 1.24;
  m.z_knockdown = 0.55;
  m.poisson = 0.35;
  m.family = "fdm";
  return m;
}

const topopt::SettingsRules& rules() {
  static const topopt::SettingsRules table =
      topopt::load_settings_rules_file(std::string(SETTINGS_RULES_PATH));
  return table;
}

// A block [0,lblock) of full ny x nz section, plus a PROTRUDING tw x tw tab for
// i in [lblock, nx) (the rest of those layers Empty). Fixture on the i=0 face;
// the tab's far face tagged Load. Returns the pad (anchor + load-face FrozenSolid)
// and the load/anchor voxel index sets.
struct Geom {
  VoxelGrid grid;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
  DesignMask pad;
  std::vector<std::size_t> load_vox, fix_vox;
};

Geom make_tab_cantilever(int nx, int ny, int nz, double h, int tw, int td,
                         int pad_depth, double tip_force) {
  Geom G;
  VoxelGrid& g = G.grid;
  g.nx = nx; g.ny = ny; g.nz = nz; g.spacing = h; g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Empty);
  const int lblock = nx - td;
  const int j0 = (ny - tw) / 2, k0 = (nz - tw) / 2;
  for (int i = 0; i < lblock; ++i)
    for (int k = 0; k < nz; ++k)
      for (int j = 0; j < ny; ++j) g.set_tag(i, j, k, VoxelTag::Interior);
  for (int i = lblock; i < nx; ++i)
    for (int k = k0; k < k0 + tw; ++k)
      for (int j = j0; j < j0 + tw; ++j) g.set_tag(i, j, k, VoxelTag::Interior);
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j) {
      g.set_tag(0, j, k, VoxelTag::Fixture);
      G.fix_vox.push_back(g.index(0, j, k));
    }
  for (int c = 0; c <= nz; ++c)
    for (int b = 0; b <= ny; ++b) {
      const int n = topopt::fea_node_index(g, 0, b, c);
      G.bcs.push_back({n, 0, 0.0});
      G.bcs.push_back({n, 1, 0.0});
      G.bcs.push_back({n, 2, 0.0});
    }
  for (int i = nx - td; i < nx; ++i)
    for (int k = k0; k < k0 + tw; ++k)
      for (int j = j0; j < j0 + tw; ++j) {
        g.set_tag(i, j, k, VoxelTag::Load);
        G.load_vox.push_back(g.index(i, j, k));
      }
  G.loads = topopt::traction_loads(g, VoxelTag::Load, Vec3{0, 0, -tip_force});
  // Anchor + load-face FrozenSolid pad (mirrors mask_step_face, depth pad_depth).
  G.pad = make_active_mask(g);
  for (int d = 0; d < pad_depth; ++d)
    for (int k = 0; k < nz; ++k)
      for (int j = 0; j < ny; ++j)
        G.pad[g.index(d, j, k)] = MaskValue::FrozenSolid;
  for (int d = 0; d < pad_depth; ++d)
    for (int k = k0; k < k0 + tw; ++k)
      for (int j = j0; j < j0 + tw; ++j) {
        const int i = nx - 1 - d;
        if (i >= 0 && g.solid(i, j, k)) G.pad[g.index(i, j, k)] = MaskValue::FrozenSolid;
      }
  return G;
}

// 6-connected component id per voxel over the printed set (rho > iso); -1 off.
std::vector<int> components(const VoxelGrid& g, const std::vector<double>& rho,
                            int& count) {
  std::vector<int> id(g.voxel_count(), -1);
  auto on = [&](int i, int j, int k) { return rho[g.index(i, j, k)] > kIso; };
  const int nx = g.nx, ny = g.ny, nz = g.nz;
  int next = 0;
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        if (!on(i, j, k) || id[g.index(i, j, k)] >= 0) continue;
        std::queue<std::array<int, 3>> q;
        q.push({i, j, k});
        id[g.index(i, j, k)] = next;
        while (!q.empty()) {
          auto c = q.front(); q.pop();
          const int d[6][3] = {{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}};
          for (auto& o : d) {
            const int ni = c[0]+o[0], nj = c[1]+o[1], nk = c[2]+o[2];
            if (ni<0||nj<0||nk<0||ni>=nx||nj>=ny||nk>=nz) continue;
            if (!on(ni,nj,nk) || id[g.index(ni,nj,nk)] >= 0) continue;
            id[g.index(ni,nj,nk)] = next;
            q.push({ni,nj,nk});
          }
        }
        ++next;
      }
  count = next;
  return id;
}

// The majority printed component id of a voxel set (-1 if none printed).
int majority_component(const std::vector<int>& id,
                       const std::vector<std::size_t>& set, int count) {
  std::vector<std::size_t> tally(static_cast<std::size_t>(count), 0);
  for (std::size_t x : set)
    if (id[x] >= 0) tally[static_cast<std::size_t>(id[x])]++;
  int best = -1; std::size_t bn = 0;
  for (int c = 0; c < count; ++c)
    if (tally[static_cast<std::size_t>(c)] > bn) { bn = tally[static_cast<std::size_t>(c)]; best = c; }
  return best;
}

MinimizePlasticOptions base_options() {
  MinimizePlasticOptions o;
  o.volume_fraction_ladder = {0.26};  // the lightest rung — max stripping pressure
  o.margin_stop = 0.0;                // walk the whole (1-rung) ladder
  o.updater = topopt::SimpUpdater::MMA;
  o.gravity = 9810.0 * 1e-9;
  o.gravity_direction = Vec3{0, 0, -1};
  o.simp.move = 0.2;
  o.simp.max_iterations = 60;
  o.simp.mma_plateau_window = 10;
  o.simp.mma_plateau_tol = 1e-3;
  o.simp.cg_tolerance = 1e-8;
  o.keyframe_count = 0;
  return o;
}

// (1) An externally loaded tab is retained at density 1 AND the printed field is
// a single connected body containing both the load and the anchor.
void test_external_load_retained_and_connected() {
  const int nx = 28, ny = 10, nz = 10, tw = 3, td = 2, pad_depth = 3;
  Geom G = make_tab_cantilever(nx, ny, nz, 4.0, tw, td, pad_depth, 100.0);

  MinimizePlasticOptions o = base_options();
  o.external_loads = G.loads;
  o.require_external_loads = true;  // load-case run
  o.design_mask = G.pad;
  o.simp.filter_radius = topopt::physical_filter_radius(2.5, 4.0);  // -> 1.5 floor

  MinimizePlasticResult r =
      topopt::minimize_plastic(G.grid, pla_material(), "pla", G.bcs, rules(), o);
  CHECK(!r.evaluated.empty(), "load-case run produced a terminal variant");
  const std::vector<double>& rho = r.evaluated.back().optimization.physical_density;

  // Load face RETAINED at density 1 (Load tag -> FrozenSolid + the pad).
  double load_min = 1e9;
  for (std::size_t x : G.load_vox) load_min = std::min(load_min, rho[x]);
  CHECK(load_min >= 0.999,
        "external load: every load-face voxel is retained at density 1");

  // Printed field CONNECTED: the load and anchor sit in the SAME printed
  // component, and it is the LARGEST (a single load-carrying body, not a
  // frozen-but-floating island the render would drop).
  int ncomp = 0;
  const std::vector<int> id = components(G.grid, rho, ncomp);
  std::vector<std::size_t> sizes(static_cast<std::size_t>(ncomp), 0);
  for (int v : id) if (v >= 0) sizes[static_cast<std::size_t>(v)]++;
  int largest = -1; std::size_t big = 0;
  for (int c = 0; c < ncomp; ++c)
    if (sizes[static_cast<std::size_t>(c)] > big) { big = sizes[static_cast<std::size_t>(c)]; largest = c; }
  const int lc = majority_component(id, G.load_vox, ncomp);
  const int fc = majority_component(id, G.fix_vox, ncomp);
  CHECK(lc >= 0, "external load: the load face is printed");
  CHECK(lc == fc,
        "external load: load and anchor are in the SAME printed component "
        "(a connected load path, not a severed/floating tab)");
  CHECK(lc == largest,
        "external load: the load-carrying body is the largest printed component "
        "(the tab is not a minority island the display would drop)");
}

// (2a) The guard: a load-case caller (require_external_loads) with an empty
// external_loads THROWS instead of silently running self-weight.
void test_empty_external_loads_refused() {
  const int nx = 12, ny = 6, nz = 6;
  Geom G = make_tab_cantilever(nx, ny, nz, 4.0, 3, 2, 3, 100.0);
  MinimizePlasticOptions o = base_options();
  o.require_external_loads = true;
  o.external_loads.clear();  // the lost-force case
  bool threw = false;
  try {
    topopt::minimize_plastic(G.grid, pla_material(), "pla", G.bcs, rules(), o);
  } catch (const std::invalid_argument&) {
    threw = true;
  }
  CHECK(threw,
        "guard: require_external_loads + empty external_loads throws (no silent "
        "self-weight fall-through)");
}

// (2b) The guard does NOT fire for a genuine self-weight run (default false), and
// does NOT fire when a real external load IS present.
void test_selfweight_and_present_load_not_refused() {
  const int nx = 12, ny = 6, nz = 6;
  Geom G = make_tab_cantilever(nx, ny, nz, 4.0, 3, 2, 3, 100.0);

  // Self-weight run: require_external_loads default false, empty external -> OK.
  MinimizePlasticOptions sw = base_options();
  sw.simp.max_iterations = 5;  // just prove it does not throw
  bool sw_threw = false;
  try {
    topopt::minimize_plastic(G.grid, pla_material(), "pla", G.bcs, rules(), sw);
  } catch (const std::exception&) {
    sw_threw = true;
  }
  CHECK(!sw_threw,
        "guard: a genuine self-weight run (require_external_loads == false) is "
        "unaffected");

  // Present external load with the flag set -> OK.
  MinimizePlasticOptions ld = base_options();
  ld.simp.max_iterations = 5;
  ld.require_external_loads = true;
  ld.external_loads = G.loads;
  ld.design_mask = G.pad;
  bool ld_threw = false;
  try {
    topopt::minimize_plastic(G.grid, pla_material(), "pla", G.bcs, rules(), ld);
  } catch (const std::exception&) {
    ld_threw = true;
  }
  CHECK(!ld_threw,
        "guard: require_external_loads with a non-empty load does NOT throw");
}

}  // namespace

int main() {
  test_external_load_retained_and_connected();
  test_empty_external_loads_refused();
  test_selfweight_and_present_load_not_refused();
  std::fprintf(stderr, "load_retention_connectivity: %d checks, %d failures\n",
               g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
