// THE EXPORTED SHELL IS CUT AT THE RUN'S OWN PRINTED ISO (task
// 2026-08-09-shell-at-runs-printed-iso).
//
// ★ THIS FILE EXISTS BECAUSE THE FACT WAS GOT WRONG BY READING THE CODE.
//
// A follow-up task was filed claiming that `check_v3` is called with the
// file-scope constant `kIso = 0.5` (analyze.cpp:25) "unconditionally", so a
// MULTISCALE run — whose printed set extends down to `multiscale_printed_iso()`,
// about 0.0252 for octet — would export a shell cut at 0.5 that does not contain
// its own printed material.
//
// The claim is FALSE. `analyze.cpp:143` declares
//
//     const double kIso = printed_iso;
//
// INSIDE `analyze_fixed_design`, SHADOWING the file-scope constant, and :389's
// `check_v3(grid, density, kIso)` binds to the shadowing local. The two names are
// identical, 246 lines apart, and only a brace-match tells them apart — which is
// exactly why an assertion is worth more here than a careful reading.
//
// WHAT THIS PINS, so the same wrong conclusion cannot be drawn twice:
//   1. `v3.mesh` is the isosurface at the printed iso the CALLER passed, exactly
//      — compared mesh-to-mesh against `marching_cubes` at that iso, not by
//      triangle count;
//   2. it MOVES with that argument — the same design at two isos gives two
//      different shells, so case 1 cannot be passing vacuously;
//   3. the fixture's field genuinely straddles the two isos, so there is
//      something to tell apart in the first place.
//
// Self-contained CHECK harness (ARCHITECTURE §4 locks the dependency set).

#include "topopt/analyze.hpp"
#include "topopt/lattice.hpp"
#include "topopt/lattice_material.hpp"
#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/simp.hpp"
#include "topopt/mesh.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstdio>
#include <vector>

using namespace topopt;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                           \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

namespace {

// A cantilever block whose density is GRADED across the span: a solid core, a
// mid-density shoulder that sits between the multiscale iso and 0.5, and void
// outside. The shoulder is the whole point — it is the material a 0.5 cut throws
// away and a multiscale cut keeps.
struct Fixture {
  VoxelGrid grid;
  std::vector<double> density;
};

Fixture make_graded(int n) {
  Fixture f;
  f.grid.nx = f.grid.ny = f.grid.nz = n;
  f.grid.spacing = 1.0;
  f.grid.origin = Vec3{0, 0, 0};
  f.grid.tags.assign(static_cast<std::size_t>(n) * n * n, VoxelTag::Empty);
  f.density.assign(f.grid.tags.size(), 0.0);
  const int lo = n / 4, hi = n - n / 4 - 1;
  for (int k = lo; k <= hi; ++k)
    for (int j = lo; j <= hi; ++j)
      for (int i = lo; i <= hi; ++i) {
        // Solid core, then a shoulder ring at 0.20 — above the octet multiscale
        // iso (~0.0252) and below 0.5.
        const bool core = i > lo + 1 && i < hi - 1 && j > lo + 1 && j < hi - 1 &&
                          k > lo + 1 && k < hi - 1;
        f.grid.tags[f.grid.index(i, j, k)] = VoxelTag::Interior;
        f.density[f.grid.index(i, j, k)] = core ? 1.0 : 0.20;
      }
  return f;
}

bool same_mesh(const TriangleMesh& a, const TriangleMesh& b) {
  if (a.vertices.size() != b.vertices.size()) return false;
  if (a.triangles.size() != b.triangles.size()) return false;
  for (std::size_t i = 0; i < a.vertices.size(); ++i) {
    const Vec3 &p = a.vertices[i], &q = b.vertices[i];
    if (p.x != q.x || p.y != q.y || p.z != q.z) return false;
  }
  for (std::size_t i = 0; i < a.triangles.size(); ++i)
    if (a.triangles[i] != b.triangles[i]) return false;
  return true;
}

}  // namespace

int main() {
  const Fixture f = make_graded(16);
  const double ms = multiscale_printed_iso(LatticeTopology::Octet);
  std::printf("  octet multiscale printed iso = %.7f   (classic 0.5)\n", ms);

  // ── 0. THE FIXTURE MUST STRADDLE BOTH ISOS, or everything below is vacuous.
  {
    long long above = 0, in_band = 0;
    for (double d : f.density) {
      if (d >= 0.5) ++above;
      else if (d >= ms) ++in_band;
    }
    std::printf("  fixture: %lld voxels >= 0.5, %lld more in [%.5f, 0.5)\n",
                above, in_band, ms);
    CHECK(above > 0 && in_band > 0,
          "the fixture must carry material BETWEEN the multiscale iso and 0.5 — "
          "otherwise the two cuts describe the same object and every assertion "
          "below passes for the wrong reason");
  }

  // ── 1. `check_v3`'s mesh IS the isosurface at the iso it was handed, exactly.
  // Compared mesh-to-mesh (vertices and triangles), not by triangle count.
  {
    for (const double iso : {0.5, ms}) {
      const V3Report r = check_v3(f.grid, f.density, iso);
      const TriangleMesh direct =
          keep_largest_component(marching_cubes(f.grid, f.density, iso));
      std::printf("  check_v3(iso=%.7f): %zu tris   marching_cubes: %zu tris\n",
                  iso, r.mesh.triangles.size(), direct.triangles.size());
      CHECK(same_mesh(r.mesh, direct),
            "check_v3's mesh must BE the isosurface at the iso it was given — "
            "this is the shell the latticed export pushes and the strut clip is "
            "evaluated against");
    }
  }

  // ── 2. ★ AND IT MOVES WITH THE ARGUMENT. If the iso were hardcoded, case 1
  // would still pass for whichever value happened to be hardcoded; this is what
  // makes case 1 mean something.
  {
    const V3Report classic = check_v3(f.grid, f.density, 0.5);
    const V3Report multi = check_v3(f.grid, f.density, ms);
    CHECK(!same_mesh(classic.mesh, multi.mesh),
          "the shell must DIFFER between the classic and multiscale isos on a "
          "design that straddles them — if it does not, the iso argument is "
          "being ignored somewhere");
    CHECK(multi.mesh.triangles.size() > classic.mesh.triangles.size(),
          "the multiscale cut is BELOW 0.5, so its shell must enclose MORE "
          "material, not less — the direction matters: a bigger shell is why "
          "the no-protrusion invariant gets EASIER on a multiscale run, never "
          "harder");
  }

  // ── 3. THE FULL PATH, through the public entry point the run actually uses.
  // `analyze_fixed_design` is where the shadowing local is DECLARED, so this is
  // the assertion that the argument survives the trip to check_v3 rather than
  // being replaced by the file-scope constant 246 lines above it.
  {
    Material mat;
    mat.youngs_modulus_mpa = 2200.0;
    mat.poisson = 0.35;
    mat.density_g_cm3 = 1.24;
    mat.yield_strength_mpa = 45.0;
    mat.z_knockdown = 0.5;
    SimpParams params;
    params.youngs_modulus = mat.youngs_modulus_mpa;
    params.poisson = mat.poisson;
    params.penalty = 3.0;
    // Pin the whole k = 0 node plane and pull down on one node of the top plane:
    // enough to make the solve well posed; the VERDICT is irrelevant here, only
    // which iso v3.mesh came out at.
    // DirichletBC and NodalLoad are (node, component, value) triples — one entry
    // per constrained/loaded DOF, not one per node.
    // Both the pin and the load must land on nodes of the SOLID block (its voxel
    // range is [lo, hi]), or the solve refuses with "load applied to a void DOF".
    const int lo = 16 / 4, hi = 16 - 16 / 4 - 1;
    std::vector<DirichletBC> bcs;
    for (int j = lo; j <= hi + 1; ++j)
      for (int i = lo; i <= hi + 1; ++i)
        for (int c = 0; c < 3; ++c)
          bcs.push_back({fea_node_index(f.grid, i, j, lo), c, 0.0});
    std::vector<NodalLoad> loads;
    loads.push_back(
        {fea_node_index(f.grid, (lo + hi) / 2, (lo + hi) / 2, hi + 1), 2, -1.0});

    for (const double iso : {0.5, ms}) {
      const FixedDesignAnalysis a = analyze_fixed_design(
          f.grid, params, f.density, bcs, loads, mat, Vec3{0, 0, 1}, 1e-8, 2000,
          SolverKind::JacobiCG, 0.0, KnockdownSpec{}, true,
          static_cast<double>(f.grid.solid_count()), nullptr, false, false,
          false, iso);
      const TriangleMesh direct =
          keep_largest_component(marching_cubes(f.grid, f.density, iso));
      std::printf("  analyze_fixed_design(printed_iso=%.7f) -> v3.mesh %zu tris\n",
                  iso, a.v3.mesh.triangles.size());
      CHECK(same_mesh(a.v3.mesh, direct),
            "\u2605 analyze_fixed_design's v3.mesh must be the isosurface at the "
            "printed_iso it was PASSED — the file-scope kIso = 0.5 it shadows "
            "must not reach check_v3");
    }
  }

  std::printf("test_shell_iso_provenance: %d checks, %d failures\n", g_checks,
              g_failures);
  return g_failures == 0 ? 0 : 1;
}
