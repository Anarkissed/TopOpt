// Per-type gap between the EMITTED strut solid and the certified density, on an unclipped
// block: generate a 5x5x5 uniform block, measure the central 3x3x3 cells with the volume
// check (exact prisms + nodes), against the law's rho.
#include "topopt/lattice.hpp"
#include "topopt/lattice_gen.hpp"
#include "topopt/lattice_volume_check.hpp"
#include <cstdio>
#include <string>
using namespace topopt;
struct Null : TriangleSink { void add_triangle(const Vec3&, const Vec3&, const Vec3&) override {} };
int main() {
  const double L = 8.0;
  for (const char* id : {"octet", "fcc", "kelvin", "rhombic", "diamond", "bcc", "sc"}) {
    const LatticeGenTopology gt = lattice_gen_topology_from_id(id);
    const LatticeTopology ct = lattice_topology_from_id(id);
    for (double rho : {lattice_rho_min(ct), 0.5 * (lattice_rho_min(ct) + lattice_rho_max(ct)), lattice_rho_max(ct)}) {
      LatticeRegion R; R.origin = {0, 0, 0}; R.nx = R.ny = R.nz = 5; R.cell_mm = L;
      LatticeRadiusField G; G.uniform_mm = 0.5 * lattice_strut_diameter_mm(ct, rho, L);
      LatticeSolidProbe probe;
      LatticeGenObserver obs;
      obs.on_element = [&](LatticeGenElement k, const Vec3& a, const Vec3& b, double r) {
        if (k == LatticeGenElement::Node || k == LatticeGenElement::AnchorNode) probe.add_ball(a, r);
        else probe.add_strut(a, b, r, G.nseg);
      };
      Null sink;
      generate_lattice(gt, R, G, sink, LatticeSkinSpec{}, &obs);
      VoxelGrid g; g.nx = g.ny = g.nz = 9; g.spacing = 8.0 / 3.0; g.origin = {8, 8, 8};
      g.tags.assign(9 * 9 * 9, VoxelTag{});
      std::vector<char> mask(g.voxel_count(), 1);
      const LatticeVolumeCheck v = lattice_volume_check(g, mask, [rho](std::size_t) { return rho; }, probe);
      std::printf("%-8s rho %.4f  strut d/L %.4f  exported rho %.4f  gap %+6.2f %%\n", id, rho,
                  2.0 * G.uniform_mm / L, v.exported_mm3 / (27.0 * L * L * L), 100.0 * v.worst_gap);
    }
  }
}
