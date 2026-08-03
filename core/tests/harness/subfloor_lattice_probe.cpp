// subfloor_lattice_probe.cpp — task 2026-08-04-protect-freeze-vs-solidity, item 8:
// SHOULD THE CELLS-PER-MEMBER FLOOR BE STRESS-CONDITIONAL?
//
// THE PROPOSAL, as posed. The floor (n* = 5 cells across a member) is an ACCURACY
// requirement, not a printability one: below it the homogenized tensor stops
// describing reality. But accuracy only matters where it changes the verdict — in
// a region at near-zero macro stress the tensor error multiplies by ~zero. So:
// relax the floor where the region's macro stress is below a stated fraction of
// the part's peak, keep it where the region carries load.
//
// WHAT THIS PROBE MEASURES, and it is the whole point that it MEASURES rather
// than assumes:
//
//   8a THE ERROR BEING ACCEPTED. A design with a genuinely unloaded region,
//      latticed BELOW the floor, against the same design with that region solid.
//      Reported: the certified margin, both ways, and the movement between them.
//
//   8b THE NON-LOCAL EFFECT. Stiffness errors are not local: a wrong member
//      stiffness shifts the global displacement field and moves stress elsewhere.
//      Reported: peak von Mises AND ITS ARGMAX LOCATION, both ways. If the argmax
//      moves, that is the finding and the relaxation is not safe as stated.
//
// THE GEOMETRY. A loaded cantilever beam plus a thin flange that carries nothing:
//
//     z
//     ^        flange (thin in z, sticks out in +y) — carries no external load
//     |    +--------------------+
//     |    |                    |
//     +----+====================+---------> x
//          beam: anchored at x=0, loaded -Z at x=nx
//
// The flange is welded to the beam so it is part of the same solid (a detached
// region would be an under-constrained system, not an unloaded one) — which is
// exactly the maintainer's case: "the back wall carries NO load, it exists for
// geometry".
//
// THE FLOOR IS NOT A GATE TODAY, and the probe is built on that fact. Nothing
// refuses a sub-floor lattice: `grade_lattice` filters such voxels out of its
// CANDIDATE set (they stay solid), and `analyze_fixed_design` only RAISES
// `lattice_strut_out_of_regime` — a reported flag. So a uniform posture can put a
// lattice below the floor today and be certified, flagged. That is what makes
// this measurable at all, and it is also why "relax the floor" is the wrong shape
// for the answer: there is no gate to relax, only an accuracy claim to price.
//
// Prints a table; asserts nothing. A measured NO is a valid outcome (item 8c).

#include "topopt/analyze.hpp"
#include "topopt/fea.hpp"
#include "topopt/lattice.hpp"
#include "topopt/materials.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstdio>
#include <limits>
#include <string>
#include <vector>

using namespace topopt;

namespace {

// Grid: 1 mm voxels. Beam 60 x 16 x 16; flange 40 x 24 x FLANGE_T, welded to the
// beam's +y face, centred in z.
constexpr int kNX = 60, kNY = 40, kNZ = 16;
constexpr int kBeamNY = 16;
// The flange sits at the cantilever's TIP, where the bending moment is ~0 — the
// first attempt put it across the ROOT and it picked up 30% of the peak stress,
// which is not "genuinely unloaded" and would have measured the wrong thing.
constexpr int kFlangeX0 = 44;
constexpr int kFlangeZ0 = 6, kFlangeT = 4;  // 4 mm thick

bool in_beam(int i, int j, int k) {
  (void)i; (void)k;
  return j < kBeamNY;
}
// The flange's x station is swept: moving it from the tip toward the clamped
// root raises the stress it carries, which is exactly the axis the proposal is
// stated on ("below a stated fraction of the part's peak").
int g_flange_x0 = kFlangeX0;
constexpr int kFlangeLen = 14;

bool in_flange(int i, int j, int k) {
  return j >= kBeamNY && i >= g_flange_x0 && i < g_flange_x0 + kFlangeLen &&
         k >= kFlangeZ0 && k < kFlangeZ0 + kFlangeT;
}

struct Result {
  double margin_worst = 0.0;
  double margin_effective = 0.0;
  bool accepted = false;
  double max_vm = 0.0;
  int argmax_i = -1, argmax_j = -1, argmax_k = -1;
  double mass = 0.0;
  double min_cpm = 0.0;
  bool out_of_regime = false;
  double flange_peak_vm = 0.0;  // the region's OWN macro stress
};

}  // namespace

int main() {
  const MaterialLibrary lib = load_materials_file(MATERIALS_JSON_PATH);
  const Material mat = lib.at("PLA");
  SimpParams params;
  params.youngs_modulus = mat.youngs_modulus_mpa;
  params.poisson = 0.35;
  params.penalty = 3.0;
  const Vec3 build_dir{0.0, 0.0, 1.0};
  KnockdownSpec kd;

  std::printf("=== item 8 — sub-floor lattice on a genuinely unloaded region ===\n");
  std::printf("cantilever %dx%dx%d mm, clamped at x=0, loaded -Z at x=%d.\n",
              kNX, kBeamNY, kNZ, kNX);
  std::printf("A %d mm-thick flange (%d mm long) is welded to the beam's +y face\n"
              "at a swept x station: near the TIP it carries almost nothing, near\n"
              "the ROOT it carries real load. floor n* = %.1f cells per member.\n\n",
              kFlangeT, kFlangeLen,
              lattice_cells_per_member_min(LatticeTopology::Octet));

  // ── one station: build the grid, solve solid, then solve latticed at a series
  // of cells. Everything is rebuilt per station because the geometry moves.
  struct Station { double stress_frac; double d_margin_subfloor; bool argmax_moved;
                   double margin_solid; double margin_sub; double peak_solid;
                   double peak_sub; double min_cpm; };
  std::vector<Station> stations;

  std::printf("%8s %12s %14s %14s %12s %14s %s\n", "flange_x", "region_vM%",
              "margin_solid", "margin_sub", "d_margin", "cpm_sub", "argmax");
  for (const int x0 : {44, 36, 28, 20, 12, 4}) {
    g_flange_x0 = x0;
    VoxelGrid g;
    g.nx = kNX; g.ny = kNY; g.nz = kNZ;
    g.spacing = 1.0;
    g.origin = Vec3{0.0, 0.0, 0.0};
    g.tags.assign(static_cast<std::size_t>(kNX) * kNY * kNZ, VoxelTag::Empty);
    for (int k = 0; k < kNZ; ++k)
      for (int j = 0; j < kNY; ++j)
        for (int i = 0; i < kNX; ++i)
          if (in_beam(i, j, k) || in_flange(i, j, k))
            g.tags[g.index(i, j, k)] = VoxelTag::Interior;
    std::vector<double> density(g.voxel_count(), 0.0);
    std::size_t solid_voxels = 0;
    for (std::size_t e = 0; e < g.voxel_count(); ++e)
      if (g.tags[e] != VoxelTag::Empty) { density[e] = 1.0; ++solid_voxels; }

    std::vector<DirichletBC> bcs;
    for (int k = 0; k <= kNZ; ++k)
      for (int j = 0; j <= kBeamNY; ++j) {
        const int n = fea_node_index(g, 0, j, k);
        bcs.push_back({n, 0, 0.0});
        bcs.push_back({n, 1, 0.0});
        bcs.push_back({n, 2, 0.0});
      }
    std::vector<NodalLoad> loads;
    for (int k = 0; k <= kNZ; ++k)
      for (int j = 0; j <= kBeamNY; ++j)
        loads.push_back({fea_node_index(g, kNX, j, k), 2, -3.0});
    const double part_solid = static_cast<double>(solid_voxels);

    auto analyse = [&](const LatticePosture* post) {
      const FixedDesignAnalysis a = analyze_fixed_design(
          g, params, density, bcs, loads, mat, build_dir, 1e-9, 0,
          SolverKind::JacobiCG, 0.0, kd, true, part_solid, post);
      Result r;
      r.margin_worst = a.margin.worst_case;
      r.accepted = a.accepted;
      r.max_vm = a.max_von_mises;
      r.mass = a.mass_grams;
      r.min_cpm = a.lattice_min_cells_per_member;
      r.out_of_regime = a.lattice_strut_out_of_regime;
      double best = -1.0, fp = 0.0;
      for (int k = 0; k < kNZ; ++k)
        for (int j = 0; j < kNY; ++j)
          for (int i = 0; i < kNX; ++i) {
            const std::size_t e = g.index(i, j, k);
            if (!(density[e] > 0.5)) continue;
            if (in_flange(i, j, k)) fp = std::max(fp, a.von_mises_field[e]);
            if (post && !post->mask.empty() && post->mask[e]) continue;
            const double vm = a.von_mises_field[e];
            if (vm > best) { best = vm; r.argmax_i = i; r.argmax_j = j; r.argmax_k = k; }
          }
      r.flange_peak_vm = fp;
      return r;
    };

    const Result S = analyse(nullptr);
    // Sub-floor: cell 3.0 mm over a 4 mm member => 1.33 cells per member.
    LatticePosture post;
    post.topology = LatticeTopology::Octet;
    post.cell_size_mm = 3.0;
    post.mask.assign(g.voxel_count(), 0);
    post.relative_density.assign(g.voxel_count(), 0.0);
    for (int k = 0; k < kNZ; ++k)
      for (int j = 0; j < kNY; ++j)
        for (int i = 0; i < kNX; ++i)
          if (in_flange(i, j, k)) {
            const std::size_t e = g.index(i, j, k);
            post.mask[e] = 1;
            post.relative_density[e] = 0.30;
          }
    const Result L = analyse(&post);
    const bool moved = L.argmax_i != S.argmax_i || L.argmax_j != S.argmax_j ||
                       L.argmax_k != S.argmax_k;
    const double frac = S.max_vm > 0.0 ? 100.0 * S.flange_peak_vm / S.max_vm : 0.0;
    const double dm = S.margin_worst > 0.0
        ? 100.0 * (L.margin_worst - S.margin_worst) / S.margin_worst : 0.0;
    std::printf("%8d %11.3f%% %14.6f %14.6f %+11.4f%% %14.2f %s\n", x0, frac,
                S.margin_worst, L.margin_worst, dm, L.min_cpm,
                moved ? "MOVED" : "same");
    stations.push_back({frac, dm, moved, S.margin_worst, L.margin_worst,
                        S.max_vm, L.max_vm, L.min_cpm});
  }

  // ── THE CONTROL that says whether the certification can see the CELL at all.
  // Same geometry, same rho, cell swept across the floor. If the margin is
  // identical at every cell, the gate is blind to cells-per-member — which
  // decides what a relaxation can and cannot be justified by.
  g_flange_x0 = 44;
  {
    VoxelGrid g;
    g.nx = kNX; g.ny = kNY; g.nz = kNZ;
    g.spacing = 1.0;
    g.origin = Vec3{0.0, 0.0, 0.0};
    g.tags.assign(static_cast<std::size_t>(kNX) * kNY * kNZ, VoxelTag::Empty);
    for (int k = 0; k < kNZ; ++k)
      for (int j = 0; j < kNY; ++j)
        for (int i = 0; i < kNX; ++i)
          if (in_beam(i, j, k) || in_flange(i, j, k))
            g.tags[g.index(i, j, k)] = VoxelTag::Interior;
    std::vector<double> density(g.voxel_count(), 0.0);
    std::size_t solid_voxels = 0;
    for (std::size_t e = 0; e < g.voxel_count(); ++e)
      if (g.tags[e] != VoxelTag::Empty) { density[e] = 1.0; ++solid_voxels; }
    std::vector<DirichletBC> bcs;
    for (int k = 0; k <= kNZ; ++k)
      for (int j = 0; j <= kBeamNY; ++j) {
        const int n = fea_node_index(g, 0, j, k);
        bcs.push_back({n, 0, 0.0}); bcs.push_back({n, 1, 0.0}); bcs.push_back({n, 2, 0.0});
      }
    std::vector<NodalLoad> loads;
    for (int k = 0; k <= kNZ; ++k)
      for (int j = 0; j <= kBeamNY; ++j)
        loads.push_back({fea_node_index(g, kNX, j, k), 2, -3.0});
    const double part_solid = static_cast<double>(solid_voxels);
    std::printf("\nCONTROL — can the gate see the CELL at all? (tip flange, rho=0.30)\n");
    std::printf("%8s %8s %18s %18s %8s\n", "cell_mm", "cpm", "margin.worst",
                "peak_vM", "regime");
    for (const double cell : {0.80, 1.00, 2.00, 3.00, 4.00}) {
      LatticePosture post;
      post.topology = LatticeTopology::Octet;
      post.cell_size_mm = cell;
      post.mask.assign(g.voxel_count(), 0);
      post.relative_density.assign(g.voxel_count(), 0.0);
      for (int k = 0; k < kNZ; ++k)
        for (int j = 0; j < kNY; ++j)
          for (int i = 0; i < kNX; ++i)
            if (in_flange(i, j, k)) {
              const std::size_t e = g.index(i, j, k);
              post.mask[e] = 1; post.relative_density[e] = 0.30;
            }
      const FixedDesignAnalysis a = analyze_fixed_design(
          g, params, density, bcs, loads, mat, build_dir, 1e-9, 0,
          SolverKind::JacobiCG, 0.0, kd, true, part_solid, &post);
      std::printf("%8.2f %8.2f %18.10f %18.10f %8s\n", cell,
                  a.lattice_min_cells_per_member, a.margin.worst_case,
                  a.max_von_mises,
                  a.lattice_strut_out_of_regime ? "OUT" : "in");
    }
  }

  std::printf(
      "\nREAD IT LIKE THIS.\n"
      "  FIRST TABLE (8a/8b) — d_margin is how far the CERTIFIED margin moves\n"
      "  when a region carrying region_vM%% of the part peak is latticed at 1.33\n"
      "  cells per member instead of left solid, and `argmax` is whether the\n"
      "  peak stress changed WHERE it is (the non-local effect, 8b).\n"
      "\n"
      "  SECOND TABLE — the margin at a FIXED rho with the cell swept across the\n"
      "  floor. The homogenized tensor C is a function of rho ALONE; cell size\n"
      "  never enters the composite solve. So if these rows are identical, the\n"
      "  certification is STRUCTURALLY BLIND to cells-per-member, and no d_margin\n"
      "  in the first table — however small — is evidence that a sub-floor\n"
      "  lattice is ACCURATE. It is only evidence that substituting C(rho) for\n"
      "  solid did not move this part's margin. The accuracy question the floor\n"
      "  exists to answer needs direct FEA of the real strut geometry, which the\n"
      "  lattice Phase-0 probe measured at a 44-276x cost ceiling.\n");
  return 0;
}
