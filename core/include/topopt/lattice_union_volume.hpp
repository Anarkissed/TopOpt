#pragma once
// ── The union volume of a beam lattice, measured without meshing it ───────────
//
// WHY THIS EXISTS. The bead calibration needs the lattice's true volume, and every
// route we had to it was compromised: the naive sum of the spans' cylinders counts
// every joint overlap twice (35,792 mm3 against a truth near 21,000 on the M2 stand);
// the marching-cubes weld silently DROPS struts thinner than its voxel (9,490 mm3 at a
// 0.45 mm pitch against struts 0.84 mm across); and the analytic mesh, while closed,
// carries 28,642 non-manifold edges, so the divergence theorem over-counts wherever its
// surface overlaps itself. A volume that depends on a mesh inherits the mesh's defects.
//
// So measure the SET, not a surface of it. The lattice is the union of capsules
// U_i C_i, and each capsule's own volume is exact:
//
//     V_i = pi * r_i^2 * L_i  +  (4/3) * pi * r_i^3        (cylinder + two hemispheres)
//
// A union is not the sum of those, but it decomposes exactly by OWNERSHIP: assign every
// point of the union to the LOWEST-INDEXED capsule containing it, and the parts are
// disjoint and cover it. So
//
//     V = sum_i V_i * P(a point drawn uniformly from C_i lies in no C_j with j < i)
//
// and each probability is estimated by sampling inside C_i itself. That is importance
// sampling with the ideal proposal -- every sample lands in material, none is wasted on
// the 99 % of the bounding box that is air -- so it converges where plain Monte Carlo
// over the box would not. It is unbiased, its error is a binomial standard error that
// can be REPORTED rather than assumed, and it never asks whether the mesh is sound.

#include <cstddef>
#include <cstdint>
#include <vector>

#include "topopt/organic_lattice.hpp"

namespace topopt {

struct LatticeUnionVolume {
  double volume_mm3 = 0.0;
  double std_error_mm3 = 0.0;     // 1 sigma, from the per-capsule binomial variances
  double naive_sum_mm3 = 0.0;     // sum of the capsules, overlaps counted twice
  double overlap_fraction = 0.0;  // 1 - volume/naive_sum: how much of the sum was overlap
  std::size_t capsules = 0;
  std::size_t samples = 0;
  std::size_t samples_owned = 0;
};

// `samples` is the TOTAL budget, split across capsules in proportion to their volume.
// `seed` fixes the draw, so the measurement is reproducible.
LatticeUnionVolume lattice_union_volume(const std::vector<OrganicSpan>& spans,
                                        std::size_t samples = 4000000,
                                        std::uint64_t seed = 0x9E3779B97F4A7C15ull);

}  // namespace topopt
