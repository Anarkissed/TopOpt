#include "topopt/printed_mass.hpp"

#include <algorithm>
#include <stdexcept>

#include "topopt/analyze.hpp"  // wall_area_fraction

namespace topopt {

PrintedMass printed_mass(const VoxelGrid& grid, const std::vector<double>& density,
                         double iso, const std::vector<double>& member_width_mm,
                         double wall_thickness_mm, double infill_percent,
                         double material_density_g_cm3) {
  const std::size_t n = grid.voxel_count();
  if (density.size() != n || member_width_mm.size() != n)
    throw std::invalid_argument("printed_mass: field size != voxel_count");
  const double infill = std::min(std::max(infill_percent, 0.0), 100.0) / 100.0;
  const double voxel_cm3 = grid.spacing * grid.spacing * grid.spacing * 1e-3;
  double solid = 0.0, printed = 0.0, wall = 0.0;
  for (std::size_t i = 0; i < n; ++i) {
    if (!(density[i] >= iso)) continue;
    const double v = std::min(density[i], 1.0);
    const double fw = wall_area_fraction(member_width_mm[i], wall_thickness_mm);
    solid += v;
    wall += v * fw;
    printed += v * (fw + (1.0 - fw) * infill);
  }
  PrintedMass out;
  out.solid_grams = solid * voxel_cm3 * material_density_g_cm3;
  out.grams = printed * voxel_cm3 * material_density_g_cm3;
  out.wall_share = solid > 0.0 ? wall / solid : 0.0;
  return out;
}

}  // namespace topopt
