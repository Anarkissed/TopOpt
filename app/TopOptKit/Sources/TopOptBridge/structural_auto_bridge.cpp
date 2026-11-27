// structural_auto_bridge.cpp — ★ notes30 SA1 (Structural Auto, REMOVE.md): the strength check's strut law for the app's
// Structural Auto, through bridge.cpp's one guard (bridge_guard_run: a core throw becomes a value, never a crash). Declared in
// TopOptBridge.hpp's "notes30 SA1" block. Its own file, so taking Structural Auto out is deleting it and that block.
#include "TopOptBridge.hpp"
#include "bridge_guard.hpp"

#include <string>

#include "topopt/lattice.hpp"
#include "topopt/strut_strength.hpp"

namespace topoptbridge {

StrutSizeFieldSummary lattice_strut_size_field(const std::string& topology, const double* tensor, std::size_t tensor_count,
                                               double build_x, double build_y, double build_z, double yield_mpa,
                                               double z_knockdown, double target, float* ratio_out, float* rho_out,
                                               std::uint8_t* short_out) {
  StrutSizeFieldSummary o;
  const std::string why = bridge_guard_run("lattice_strut_size_field", [&] {
    const topopt::LatticeTopology topo = topopt::lattice_topology_from_id(topology);
    const topopt::StrutLawSizeSummary s = topopt::strut_size_field(
        topo, tensor, tensor_count, topopt::Vec3{build_x, build_y, build_z}, yield_mpa, z_knockdown, target, ratio_out,
        rho_out, short_out);
    o.voxels = s.voxels;
    o.loaded = s.loaded;
    o.at_floor = s.at_floor;
    o.short_of_target = s.short_of_target;
    o.rho_floor = s.rho_floor;
    o.rho_ceiling = s.rho_ceiling;
    o.ratio_floor = s.ratio_floor;
    o.ratio_ceiling = s.ratio_ceiling;
    o.highest_ratio = s.highest_ratio;
    o.rho_sum = s.rho_sum;
    const topopt::LatticeWidthBounds b = topopt::lattice_width_bounds(topo);
    o.touch = b.touch;
    o.open_look = b.open_look;
    o.ok = true;
  });
  if (!why.empty()) {
    o = StrutSizeFieldSummary{};
    o.reason = why;
  }
  return o;
}

double lattice_strut_law_margin(const std::string& topology, double rho, double vm, double pressure, double build_x,
                                double build_y, double build_z, double yield_mpa, double z_knockdown) {
  double m = 0.0;   // 0 with a refusal (its reason in bridge_last_refusal)
  bridge_guard_run("lattice_strut_law_margin", [&] {
    m = topopt::strut_law_margin_at(topopt::lattice_topology_from_id(topology), rho, vm, pressure,
                                    topopt::Vec3{build_x, build_y, build_z}, yield_mpa, z_knockdown);
  });
  return m;
}

}  // namespace topoptbridge
