// test_strut_strength — the de-homogenized strut-strength REPORT (task
// 2026-07-31-lattice-strut-strength-report).
//
// What is pinned, and why:
//   1. TRANSCRIPTION — the embedded law table reproduces PR 259's kfit `*_cert`
//      envelope rows (evidence/2026-07-31-lattice-dehomogenization-probe/
//      kfit.csv) EXACTLY at every anchor. A silent table edit breaks here.
//   2. INTERPOLATION + CLAMP (bar L5) — piecewise-linear between rows; outside
//      the span the K's are CLAMPED to the endpoint row and FLAGGED, never
//      extrapolated (K_dev is 124 at the floor — extrapolating it is exactly how
//      a wrong number would look plausible).
//   3. TWO INVARIANTS, NOT ONE — a purely hydrostatic macro stress has ZERO von
//      Mises yet produces a NONZERO strut bound (the measured fact that killed
//      the scalar K·vm law; PR 259 J5).
//   4. BUILD DIRECTION (bar L8) — the evaluator takes the build direction as an
//      explicit argument and is direction-RESOLVED: on the same field, x/y/z
//      builds coincide EXACTLY (cubic symmetry — the law's own claim), while an
//      off-axis build changes the interlayer margin (conservative strut-shear
//      cross term) and NEVER the in-plane margin.
//   5. REPORT ONLY (bar L1) — through analyze_fixed_design, a latticed design
//      whose strut margin is far below 0.5 still receives exactly the verdict it
//      receives today; the report rides alongside, and
//      lattice_strength_uncertified stays true.
//   6. REGIME GUARD (bar L4) — cells-per-member is measured and compared to the
//      floor read from core; thin-domain postures are flagged out-of-regime.
//   7. NO LAW, NO NUMBER — a topology without a measured strut law (fcc) gets
//      NO strut report rather than octet's borrowed numbers.
//
// Self-contained CHECK harness (ARCHITECTURE §4), public API only.

#include "topopt/analyze.hpp"
#include "topopt/fea.hpp"
#include "topopt/lattice.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/strut_strength.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <limits>
#include <stdexcept>
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

// The kfit `*_cert` rows, VERBATIM from
// evidence/2026-07-31-lattice-dehomogenization-probe/kfit.csv — the independent
// transcription this test pins the embedded table against.
struct Row {
  double rho, Kd, Kv, Kild, Kilv;
};
constexpr Row kExpected[] = {
    {0.04762, 124.0930, 60.6036, 90.9946, 66.0605},
    {0.09505, 65.3739, 37.8932, 67.1207, 43.5009},
    {0.15524, 38.7510, 20.5053, 30.6208, 20.8223},
    {0.20414, 34.7623, 21.4607, 34.0004, 21.6227},
    {0.31619, 20.6863, 13.3207, 17.5533, 11.8537},
    {0.44394, 11.6092, 8.0827, 12.8386, 9.5626},
    {0.60004, 9.3845, 6.4616, 6.9696, 6.3297},
    {0.75210, 4.6847, 3.5686, 4.2797, 4.3419},
    {0.89598, 3.6882, 2.8571, 3.2186, 2.8771},
};
constexpr int kRows = static_cast<int>(sizeof(kExpected) / sizeof(kExpected[0]));

// One-voxel field helpers for the pure evaluator tests.
struct OneVoxel {
  std::vector<double> stress;  // 6
  std::vector<char> mask{1};
  std::vector<double> rho{0.31619};
};
OneVoxel voxel_with(double xx, double yy, double zz, double xy, double yz,
                    double zx, double rho) {
  OneVoxel v;
  v.stress = {xx, yy, zz, xy, yz, zx};
  v.rho[0] = rho;
  return v;
}

VoxelGrid make_solid_grid(int nx, int ny, int nz, double h) {
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = h;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  return g;
}

Material fdm_material() {
  Material m;
  m.youngs_modulus_mpa = 3500.0;
  m.yield_strength_mpa = 55.0;
  m.density_g_cm3 = 1.24;
  m.z_knockdown = 0.55;
  m.poisson = 0.33;
  m.family = "fdm";
  return m;
}

}  // namespace

int main() {
  const double kYield = 55.0, kZk = 0.55;

  // ── 1. transcription: every anchor row exact ────────────────────────────────
  {
    bool ok = true;
    for (int i = 0; i < kRows; ++i) {
      const StrutLawK k = strut_law_at(kExpected[i].rho);
      ok = ok && k.Kd == kExpected[i].Kd && k.Kv == kExpected[i].Kv &&
           k.Kild == kExpected[i].Kild && k.Kilv == kExpected[i].Kilv;
    }
    CHECK(ok, "all 9 kfit *_cert rows reproduced exactly at their anchors");
    CHECK(strut_law_rho_min() == kExpected[0].rho &&
              strut_law_rho_max() == kExpected[kRows - 1].rho,
          "law span == first/last kfit row");
  }

  // ── 2. interpolation is linear; out-of-span is clamped AND flagged (L5) ─────
  {
    const Row& a = kExpected[4];
    const Row& b = kExpected[5];
    const double mid = 0.5 * (a.rho + b.rho);
    const StrutLawK k = strut_law_at(mid);
    CHECK(std::fabs(k.Kd - 0.5 * (a.Kd + b.Kd)) < 1e-12 &&
              std::fabs(k.Kilv - 0.5 * (a.Kilv + b.Kilv)) < 1e-12,
          "midpoint interpolation is exactly linear");

    bool cl_lo = false, cl_hi = false, cl_in = false;
    const StrutLawK klo = strut_law_at(0.01, &cl_lo);
    const StrutLawK khi = strut_law_at(0.95, &cl_hi);
    strut_law_at(0.5, &cl_in);
    CHECK(cl_lo && klo.Kd == kExpected[0].Kd,
          "below-span rho clamps to the FLOOR row and is flagged");
    CHECK(cl_hi && khi.Kd == kExpected[kRows - 1].Kd,
          "above-span rho clamps to the CEILING row and is flagged");
    CHECK(!cl_in, "in-span rho is not flagged");
  }

  // ── 3. hydrostatic stress: zero macro vm, NONZERO strut bound ───────────────
  // The measured fact that makes the scalar K·vm law unbounded (PR 259 J5): a
  // hydrostatic macro state loads the struts while carrying zero macro von Mises.
  {
    OneVoxel v = voxel_with(-10.0, -10.0, -10.0, 0.0, 0.0, 0.0, 0.31619);
    const StrutStrengthReport r = evaluate_strut_strength(
        v.stress, v.mask, v.rho, Vec3{0, 0, 1}, kYield, kZk);
    CHECK(r.evaluated && r.max_macro_vm_mpa == 0.0,
          "hydrostatic state has zero macro von Mises");
    CHECK(std::fabs(r.vm_bound_max_mpa - kExpected[4].Kv * 10.0) < 1e-9,
          "strut vm bound = Kv·|p| — nonzero where the scalar law reads zero");
    CHECK(std::fabs(r.il_bound_max_mpa - kExpected[4].Kilv * 10.0) < 1e-9,
          "strut interlayer bound = Kilv·|p| on an axis build");
    CHECK(std::isfinite(r.margin_in_plane) && r.margin_in_plane > 0.0,
          "in-plane margin is finite under pure hydrostatic load");
  }

  // ── 4. build direction (bar L8): explicit, resolved, in-plane untouched ─────
  {
    OneVoxel v = voxel_with(12.0, -3.0, 5.0, 4.0, -2.0, 1.0, 0.31619);
    const StrutStrengthReport rz = evaluate_strut_strength(
        v.stress, v.mask, v.rho, Vec3{0, 0, 1}, kYield, kZk);
    const StrutStrengthReport rx = evaluate_strut_strength(
        v.stress, v.mask, v.rho, Vec3{1, 0, 0}, kYield, kZk);
    const StrutStrengthReport rd = evaluate_strut_strength(
        v.stress, v.mask, v.rho, Vec3{1, 1, 1}, kYield, kZk);

    CHECK(rz.build_dir_on_lattice_axis && rx.build_dir_on_lattice_axis &&
              !rd.build_dir_on_lattice_axis,
          "axis detection: x and z are lattice axes, (1,1,1) is not");
    CHECK(rz.margin_interlayer == rx.margin_interlayer &&
              rz.il_bound_max_mpa == rx.il_bound_max_mpa,
          "x and z builds coincide exactly (cubic symmetry of the measured law)");
    // THE bar-L8 assertion: same field, two build directions — the interlayer
    // margin CHANGES, the in-plane margin does NOT.
    CHECK(rd.margin_interlayer != rz.margin_interlayer,
          "off-axis build changes the interlayer margin on the same field");
    CHECK(rd.margin_interlayer < rz.margin_interlayer,
          "off-axis interlayer is more conservative (cross term only adds)");
    CHECK(rd.margin_in_plane == rz.margin_in_plane &&
              rd.vm_bound_max_mpa == rz.vm_bound_max_mpa,
          "in-plane margin identical across build directions");
    // The cross factor is the documented (2/sqrt(3))·(|nx ny|+|ny nz|+|nz nx|).
    CHECK(std::fabs(rd.il_cross_factor - 2.0 / std::sqrt(3.0)) < 1e-12,
          "cross factor at (1,1,1) is 2/sqrt(3)");
    CHECK(std::fabs(rd.il_bound_max_mpa -
                    (rz.il_bound_max_mpa +
                     rd.il_cross_factor * rz.vm_bound_max_mpa)) < 1e-9,
          "off-axis bound = axis bound + cross·(strut vm bound), exactly");
    // A build direction is a direction: scaling it changes nothing.
    const StrutStrengthReport rz2 = evaluate_strut_strength(
        v.stress, v.mask, v.rho, Vec3{0, 0, -7.5}, kYield, kZk);
    CHECK(rz2.margin_interlayer == rz.margin_interlayer,
          "build_dir is normalized (sign/scale invariant)");
  }

  // ── 5. argmax voxels + clamp count through the evaluator ────────────────────
  {
    // Voxel 0: modest stress, in-band rho. Voxel 1: much hotter, ABOVE-span rho
    // (hot enough that even the ceiling row's small K makes it the peak).
    std::vector<double> stress = {2.0, 0.0, 0.0, 0.0, 0.0, 0.0,    // vm = 2
                                  30.0, 0.0, 0.0, 0.0, 0.0, 0.0};  // vm = 30
    std::vector<char> mask = {1, 1};
    std::vector<double> rho = {0.31619, 0.95};
    const StrutStrengthReport r = evaluate_strut_strength(
        stress, mask, rho, Vec3{0, 0, 1}, kYield, kZk);
    CHECK(r.lattice_voxels == 2 && r.rho_clamped_voxels == 1,
          "one of two voxels sits above the law span and is counted (L5)");
    CHECK(r.vm_argmax_voxel == 1 && r.vm_argmax_rho == 0.95,
          "argmax voxel + its rho are reported");
    CHECK(r.vm_argmax_macro_vm_mpa == 30.0 &&
              std::fabs(r.vm_argmax_macro_pressure_mpa - 10.0) < 1e-12,
          "argmax macro invariants (vm, signed pressure) are reported");
    // The clamped voxel used the CEILING row's K, not an extrapolation.
    const double expect_bound =
        kExpected[kRows - 1].Kd * 30.0 + kExpected[kRows - 1].Kv * 10.0;
    CHECK(std::fabs(r.vm_bound_max_mpa - expect_bound) < 1e-9,
          "clamped voxel evaluated on the ceiling row (no extrapolation)");
    // Determinism: re-run bit-identical.
    const StrutStrengthReport r2 = evaluate_strut_strength(
        stress, mask, rho, Vec3{0, 0, 1}, kYield, kZk);
    CHECK(r2.vm_bound_max_mpa == r.vm_bound_max_mpa &&
              r2.margin_interlayer == r.margin_interlayer,
          "evaluator is deterministic");
  }

  // ── 6. malformed inputs are refused ─────────────────────────────────────────
  {
    OneVoxel v = voxel_with(1, 0, 0, 0, 0, 0, 0.3);
    bool threw = false;
    try {
      std::vector<char> bad_mask = {1, 1};
      evaluate_strut_strength(v.stress, bad_mask, v.rho, Vec3{0, 0, 1}, kYield,
                              kZk);
    } catch (const std::invalid_argument&) {
      threw = true;
    }
    CHECK(threw, "size mismatch throws");
    threw = false;
    try {
      evaluate_strut_strength(v.stress, v.mask, v.rho, Vec3{0, 0, 0}, kYield,
                              kZk);
    } catch (const std::invalid_argument&) {
      threw = true;
    }
    CHECK(threw, "zero build_dir throws");
    threw = false;
    try {
      evaluate_strut_strength(v.stress, v.mask, v.rho, Vec3{0, 0, 1}, kYield,
                              0.0);
    } catch (const std::invalid_argument&) {
      threw = true;
    }
    CHECK(threw, "non-positive z_knockdown throws");
  }

  // ── 7. bar L1 through analyze_fixed_design: REPORT ONLY, gate untouched ─────
  {
    // A thin latticed cantilever SLAB (2 voxels thick in z, void above — the
    // thickness EDT needs real void to measure a member): clamp x=0, tip load.
    // Latticed everywhere except the clamped root column.
    const VoxelGrid g = make_solid_grid(12, 6, 6, 1.0);
    const int kSlabZ = 2;  // printed thickness (voxels) -> 0.5 cells per member
    std::vector<double> density(g.voxel_count(), 0.0);
    for (int k = 0; k < kSlabZ; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) density[g.index(i, j, k)] = 1.0;
    std::vector<DirichletBC> bcs;
    for (int c = 0; c <= g.nz; ++c)
      for (int b = 0; b <= g.ny; ++b) {
        const int n = fea_node_index(g, 0, b, c);
        bcs.push_back({n, 0, 0.0});
        bcs.push_back({n, 1, 0.0});
        bcs.push_back({n, 2, 0.0});
      }
    std::vector<NodalLoad> loads;
    {
      std::vector<int> nodes;  // tip nodes attached to the printed slab only
      for (int c = 0; c <= kSlabZ; ++c)
        for (int b = 0; b <= g.ny; ++b)
          nodes.push_back(fea_node_index(g, g.nx, b, c));
      // Sized so the SOLID margin clears 0.5 comfortably while the ~20x strut
      // amplification at rho 0.316 pushes the strut margin well below 0.5 —
      // exactly the configuration bar L1 must prove harmless to the verdict.
      for (int n : nodes)
        loads.push_back({n, 2, -6.0 / static_cast<double>(nodes.size())});
    }
    const Material material = fdm_material();
    SimpParams params;
    params.youngs_modulus = material.youngs_modulus_mpa;
    params.poisson = material.poisson;
    params.penalty = 3.0;
    const KnockdownSpec kd;
    const double part_solid = static_cast<double>(g.solid_count());

    LatticePosture post;
    post.topology = LatticeTopology::Octet;
    post.cell_size_mm = 4.0;
    post.mask.assign(g.voxel_count(), 0);
    post.relative_density.assign(g.voxel_count(), 0.0);
    for (int k = 0; k < kSlabZ; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 1; i < g.nx; ++i) {
          const std::size_t e = g.index(i, j, k);
          post.mask[e] = 1;
          post.relative_density[e] = 0.31619;
        }

    // The verdict the design receives TODAY (margin_stop 0.5): solid-region
    // strength over the composite field.
    const FixedDesignAnalysis a = analyze_fixed_design(
        g, params, density, bcs, loads, material, Vec3{0, 0, 1}, 1e-8, 0,
        SolverKind::JacobiCG, 0.5, kd, /*load_path_ok=*/true, part_solid, &post);

    CHECK(a.lattice_certified && a.lattice_voxels > 0,
          "the composite certification ran with lattice voxels");
    CHECK(a.lattice_strut_report && a.lattice_strut.evaluated,
          "the strut-strength report rode along");
    CHECK(a.lattice_strut.margin_worst_case < 0.5,
          "this posture's strut margin IS below 0.5 (the bar's premise holds)");
    CHECK(a.accepted,
          "bar L1: a strut margin below 0.5 does NOT change today's verdict "
          "(the design is still accepted by the solid-strength gate)");
    CHECK(a.lattice_strength_uncertified,
          "strut strength stays flagged UNCERTIFIED — a report is not a gate");

    // The gate inputs are untouched by the report: margin_effective is still the
    // SOLID worst-case margin times the (solid/unset) infill knockdown.
    CHECK(a.margin_effective == a.margin.worst_case * kd.infill_knockdown,
          "margin_effective formula unchanged by the strut report");

    // Bar L4: the 6-voxel-thick domain under a 4 mm cell is ~1.5 cells per
    // member — far below the measured 5-cell floor, and flagged so.
    CHECK(a.lattice_min_cells_per_member > 0.0 &&
              a.lattice_min_cells_per_member <
                  lattice_cells_per_member_min(LatticeTopology::Octet),
          "cells-per-member measured below the floor read from core");
    CHECK(a.lattice_strut_out_of_regime,
          "bar L4: the strut numbers are flagged OUT OF REGIME, not printed "
          "as trustworthy");

    // Bar L8 on the REAL solved field: same analysis stress tensors, two build
    // directions, interlayer moves, in-plane does not.
    const StrutStrengthReport sz = evaluate_strut_strength(
        a.stress_tensor_field, post.mask, post.relative_density, Vec3{0, 0, 1},
        material.yield_strength_mpa, material.z_knockdown);
    const StrutStrengthReport sd = evaluate_strut_strength(
        a.stress_tensor_field, post.mask, post.relative_density, Vec3{1, 1, 1},
        material.yield_strength_mpa, material.z_knockdown);
    CHECK(sz.margin_in_plane == sd.margin_in_plane,
          "L8 (solved field): in-plane margin identical across build dirs");
    CHECK(sz.margin_interlayer != sd.margin_interlayer,
          "L8 (solved field): interlayer margin changes with build dir");
    CHECK(sz.margin_in_plane == a.lattice_strut.margin_in_plane &&
              sz.margin_interlayer == a.lattice_strut.margin_interlayer,
          "the standalone evaluator reproduces the analysis' own report "
          "(same field, same build dir -> same numbers)");

    // A latticed voxel's rho sits inside the certifiable band, which pokes above
    // the law span at the top — no clamp expected here at rho 0.316.
    CHECK(a.lattice_strut.rho_clamped_voxels == 0,
          "in-band rho: no law-span clamps counted");

    // 7b. NO LAW, NO NUMBER: fcc certifies (it has a tensor) but has no measured
    // strut law — the report must be ABSENT, not octet's numbers.
    LatticePosture fcc = post;
    fcc.topology = LatticeTopology::Fcc;
    const FixedDesignAnalysis af = analyze_fixed_design(
        g, params, density, bcs, loads, material, Vec3{0, 0, 1}, 1e-8, 0,
        SolverKind::JacobiCG, 0.5, kd, /*load_path_ok=*/true, part_solid, &fcc);
    CHECK(af.lattice_certified && !af.lattice_strut_report,
          "a topology without a measured strut law reports NO strut numbers");
  }

  std::fprintf(stderr, "%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
