#include "topopt/printed_mass.hpp"

#include <algorithm>
#include <cmath>
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

PrintedMass printed_mass_shell(const VoxelGrid& grid, const std::vector<double>& density,
                               double iso, double wall_mm, double top_mm, double bottom_mm,
                               double infill_percent, double material_density_g_cm3) {
  const std::size_t n = grid.voxel_count();
  if (density.size() != n) throw std::invalid_argument("printed_mass_shell: field size != voxel_count");
  const double h = grid.spacing;
  const double infill = std::min(std::max(infill_percent, 0.0), 100.0) / 100.0;
  const int nx = grid.nx, ny = grid.ny, nz = grid.nz;
  auto printed = [&](int i, int j, int k) {
    if (i < 0 || j < 0 || k < 0 || i >= nx || j >= ny || k >= nz) return false;
    return density[(static_cast<std::size_t>(k) * ny + j) * nx + i] >= iso;
  };
  // A voxel's centre is within d of the surface when a non-printed voxel's centre
  // is within d + h/2 of it (the surface lies half a voxel short of that centre).
  const double wall_reach = wall_mm > 0.0 ? wall_mm + 0.5 * h : 0.0;
  const int rw = wall_reach > 0.0 ? static_cast<int>(std::ceil(wall_reach / h)) : 0;
  const int rt = top_mm > 0.0 ? static_cast<int>(std::ceil((top_mm + 0.5 * h) / h)) : 0;
  const int rb = bottom_mm > 0.0 ? static_cast<int>(std::ceil((bottom_mm + 0.5 * h) / h)) : 0;
  double solid = 0.0, shell = 0.0, out_printed = 0.0;
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        if (!printed(i, j, k)) continue;
        const double v = std::min(density[(static_cast<std::size_t>(k) * ny + j) * nx + i], 1.0);
        bool is_shell = false;
        for (int dj = -rw; dj <= rw && !is_shell; ++dj)
          for (int di = -rw; di <= rw && !is_shell; ++di) {
            if (di == 0 && dj == 0) continue;
            if (h * std::sqrt(static_cast<double>(di * di + dj * dj)) > wall_reach) continue;
            if (!printed(i + di, j + dj, k)) is_shell = true;
          }
        for (int dk = 1; dk <= rt && !is_shell; ++dk)
          if (h * dk <= top_mm + 0.5 * h && !printed(i, j, k + dk)) is_shell = true;
        for (int dk = 1; dk <= rb && !is_shell; ++dk)
          if (h * dk <= bottom_mm + 0.5 * h && !printed(i, j, k - dk)) is_shell = true;
        solid += v;
        if (is_shell) shell += v;
        out_printed += is_shell ? v : v * infill;
      }
  const double voxel_cm3 = h * h * h * 1e-3;
  PrintedMass out;
  out.solid_grams = solid * voxel_cm3 * material_density_g_cm3;
  out.grams = out_printed * voxel_cm3 * material_density_g_cm3;
  out.wall_share = solid > 0.0 ? shell / solid : 0.0;
  return out;
}

}  // namespace topopt
