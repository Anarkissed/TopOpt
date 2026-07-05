// M3.6 multi-variant runner test — one job optimized at several volume
// fractions yields one design + printable mesh per fraction plus the per-variant
// compliance report (simp_optimize_variants).
//
// The contract asserted here:
//   * one variant per requested fraction, in input order, each tagged with its
//     own requested volume fraction;
//   * each variant actually optimized at its OWN fraction (achieved physical
//     volume fraction matches that variant's target, not a shared one);
//   * more material => stiffer => lower compliance, so with fractions listed
//     high-to-low the per-variant compliances strictly increase (this binds the
//     compliance report to physics and catches a runner that reuses one design);
//   * compliances() returns exactly the per-variant compliances;
//   * per the M3.5 mandate ("Gate V3 property suite wired to run on every
//     optimizer output in all future tests"), check_v3 is run on every variant's
//     output and the two gates the isotropic loop satisfies (watertight + single
//     component) are asserted on each — and the runner's own cleaned mesh matches
//     that V3 mesh;
//   * argument validation (empty fractions, out-of-range fraction) throws.
//
// No third-party test framework (ARCHITECTURE §4); same self-contained CHECK
// harness as test_v3.cpp / test_gate_v2.cpp, public API only.

#include "topopt/fea.hpp"
#include "topopt/mesh.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <stdexcept>
#include <vector>

using topopt::DirichletBC;
using topopt::MultiVariantResult;
using topopt::NodalLoad;
using topopt::SimpOptions;
using topopt::SimpParams;
using topopt::SimpVariant;
using topopt::V3Report;
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

int main() {
  // A clamped-root, tip-loaded cantilever — the same setup test_v3 exercises,
  // known to produce a watertight single-component design at these resolutions.
  const int nx = 24, ny = 8, nz = 8;
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = 1.0;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  // Tag the clamped root face as Fixture and the loaded tip face as Load.
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j) {
      g.set_tag(0, j, k, VoxelTag::Fixture);
      g.set_tag(nx - 1, j, k, VoxelTag::Load);
    }

  std::vector<DirichletBC> bcs;
  for (int c = 0; c <= nz; ++c)
    for (int b = 0; b <= ny; ++b) {
      const int n = topopt::fea_node_index(g, 0, b, c);
      bcs.push_back({n, 0, 0.0});
      bcs.push_back({n, 1, 0.0});
      bcs.push_back({n, 2, 0.0});
    }
  std::vector<NodalLoad> loads;
  const double fz = -1.0 / static_cast<double>((ny + 1) * (nz + 1));
  for (int c = 0; c <= nz; ++c)
    for (int b = 0; b <= ny; ++b)
      loads.push_back({topopt::fea_node_index(g, nx, b, c), 2, fz});

  SimpParams p;
  p.youngs_modulus = 1.0;
  p.poisson = 0.3;
  p.penalty = 3.0;
  p.density_min = 0.001;

  SimpOptions opt;
  opt.volume_fraction = 0.99;  // deliberately bogus: the runner must ignore it
  opt.filter_radius = 1.5;
  opt.move = 0.2;
  opt.max_iterations = 40;
  opt.change_tol = 0.0;  // run the full cap on these oscillating discrete designs
  opt.cg_tolerance = 1e-8;

  // The M3.6 job: three variants, listed high-to-low volume fraction.
  const std::vector<double> fractions = {0.7, 0.5, 0.3};
  const MultiVariantResult res =
      topopt::simp_optimize_variants(g, p, bcs, loads, opt, fractions);

  // --- Count + order + per-variant target -----------------------------------
  CHECK(res.variants.size() == fractions.size(),
        "variants: one variant per requested fraction");
  if (res.variants.size() == fractions.size()) {
    for (std::size_t v = 0; v < fractions.size(); ++v)
      CHECK(std::fabs(res.variants[v].requested_volume_fraction -
                      fractions[v]) < 1e-12,
            "variants: requested fraction preserved in input order");
  }

  // --- Each variant optimized at its OWN fraction ---------------------------
  // Achieved physical volume fraction matches that variant's target (abs 0.01,
  // the Gate V2 tolerance). If the runner shared one fraction across variants
  // (e.g. the bogus 0.99, or fraction[0]), this fails on the others.
  for (const SimpVariant& v : res.variants)
    CHECK(std::fabs(v.optimization.volume_fraction -
                    v.requested_volume_fraction) < 0.01,
          "variants: achieved volume fraction matches this variant's target");

  // --- Compliance report: monotone in volume fraction -----------------------
  const std::vector<double> comp = res.compliances();
  CHECK(comp.size() == res.variants.size(),
        "compliances(): one entry per variant");
  bool comp_matches = comp.size() == res.variants.size();
  for (std::size_t v = 0; v < comp.size() && comp_matches; ++v)
    comp_matches = comp[v] == res.variants[v].optimization.compliance;
  CHECK(comp_matches, "compliances(): equals each variant's final compliance");
  // Fractions are high-to-low, so compliance must be low-to-high (more material
  // is stiffer). Strict, and every variant's compliance is finite/positive.
  if (res.variants.size() == 3) {
    CHECK(comp[0] > 0.0 && std::isfinite(comp[0]) && std::isfinite(comp[1]) &&
              std::isfinite(comp[2]),
          "variants: compliances are finite and positive");
    CHECK(comp[0] < comp[1] && comp[1] < comp[2],
          "variants: lower volume fraction => higher compliance (monotone)");
  }

  // --- Meshes + Gate V3 on every optimizer output ---------------------------
  for (const SimpVariant& v : res.variants) {
    CHECK(!v.mesh.triangles.empty(), "variants: variant mesh is non-empty");
    // The runner's mesh is the cleaned isosurface: watertight + one component.
    CHECK(topopt::check_watertight(v.mesh).watertight,
          "variants: variant mesh is watertight");
    CHECK(topopt::count_components(v.mesh) == 1,
          "variants: variant mesh is a single component");

    // Re-run the full V3 suite on the variant's physical density (M3.5 mandate)
    // and confirm the two gates the isotropic loop satisfies, and that the
    // runner's cleaned mesh is the same surface V3 extracts.
    const V3Report r = topopt::check_v3(g, v.optimization.physical_density, 0.5);
    CHECK(r.gate_watertight(),
          "V3(variant): optimizer output mesh is watertight");
    CHECK(r.gate_single_component(),
          "V3(variant): cleaned optimizer output mesh is one component");
    CHECK(r.mesh.triangles.size() == v.mesh.triangles.size(),
          "variants: runner mesh matches the V3-cleaned mesh triangle count");
    std::printf(
        "[variant vf=%.2f] achieved=%.4f compliance=%.4f tris=%zu "
        "watertight=%d comps=%d\n",
        v.requested_volume_fraction, v.optimization.volume_fraction,
        v.optimization.compliance, v.mesh.triangles.size(),
        static_cast<int>(r.gate_watertight()), r.mesh_components);
  }

  // --- Argument validation --------------------------------------------------
  {
    bool threw = false;
    try {
      topopt::simp_optimize_variants(g, p, bcs, loads, opt, {});
    } catch (const std::invalid_argument&) {
      threw = true;
    }
    CHECK(threw, "variants: empty volume_fractions throws invalid_argument");
  }
  {
    bool threw = false;
    try {
      topopt::simp_optimize_variants(g, p, bcs, loads, opt, {0.5, 1.5});
    } catch (const std::invalid_argument&) {
      threw = true;
    }
    CHECK(threw, "variants: an out-of-range fraction (>1) throws");
  }
  {
    bool threw = false;
    try {
      topopt::simp_optimize_variants(g, p, bcs, loads, opt, {0.0});
    } catch (const std::invalid_argument&) {
      threw = true;
    }
    CHECK(threw, "variants: a zero fraction throws");
  }

  if (g_failures == 0) {
    std::printf("multi-variant runner: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "multi-variant runner: %d/%d checks FAILED\n", g_failures,
               g_checks);
  return 1;
}
