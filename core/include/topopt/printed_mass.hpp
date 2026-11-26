// printed_mass.hpp -- the grams a part really takes on the printer, at the
// user's walls and infill (TO rebuild stage 2; ledger M-07).
//
// Today the margin assumes the user's infill while "grams" and "saved" are the
// SOLID volume. The maintainer's decision (2026-11-25): grams and "saved" count
// the plastic really used, "Never the solid unless the user set infill to 100%".
//
// The model is the one the strength check already uses for stiffness
// (wall_area_fraction, analyze.hpp): a member of local width W is wrapped by a
// solid wall ring of thickness t, and its core is filled at the infill
// percentage. So a voxel's printed share of its own material is
//     f_wall + (1 - f_wall) * infill / 100,   f_wall = wall_area_fraction(W, t)
// A member thinner than two walls is all wall (share 1). Infill 100 gives the
// solid mass exactly. Solid top and bottom layers are NOT modelled (they add
// plastic on flat, wide parts); the number is a floor on the printed grams, and
// says so where it is shown.
//
// Pure arithmetic over fields the caller already has; nothing is solved.
#pragma once

#include <vector>

#include "topopt/voxel.hpp"

namespace topopt {

struct PrintedMass {
  double grams = 0.0;        // at the user's walls and infill
  double solid_grams = 0.0;  // the same material printed solid (today's number)
  double wall_share = 0.0;   // share of the solid volume that is wall ring
};

// `density` is each voxel's fill (grid.voxel_count()); a voxel is printed when
// its fill is at least `iso`. `member_width_mm` is local_member_thickness_mm's
// field for the same design (a non-finite or <= 0 width means "too thick to
// measure": a wide body, whose wall share is taken as 0, the same conservative
// reading the strength check makes). Throws std::invalid_argument on a size
// mismatch.
PrintedMass printed_mass(const VoxelGrid& grid, const std::vector<double>& density,
                         double iso, const std::vector<double>& member_width_mm,
                         double wall_thickness_mm, double infill_percent,
                         double material_density_g_cm3);

}  // namespace topopt
