// Every strut type on the lattice engine (the owner, 2026-11-24): what differs by type, read off each type's own
// canonical cell (strut_cell.hpp) or stated once here. See lattice_layout.hpp, PER TYPE, and cell_struts.
#include <cmath>
#include <cstdlib>
#include <limits>
#include <string>
#include <vector>

#include "topopt/lattice.hpp"
#include "topopt/lattice_layout.hpp"
#include "topopt/strut_cell.hpp"

namespace topopt::lattice_layout {
namespace {

bool tetragonal(LatticeTopology t) {
  return t == LatticeTopology::Bccz || t == LatticeTopology::Fccz || t == LatticeTopology::Reentrant;
}

}  // namespace

double level_strut_per_cell(LatticeTopology topo) {
  if (!lattice_has_strut_cell(topo)) return 0.0;
  const StrutCell& c = lattice_strut_cell(topo);
  double most = 0.0;
  for (const StrutCellStrut& s : c.struts) {
    if (s.a.z != s.b.z) continue;
    const double dx = s.b.x - s.a.x, dy = s.b.y - s.a.y;
    most = std::max(most, std::sqrt(dx * dx + dy * dy) / c.S);
  }
  return most;
}

double auto_cell_cap_mm(LatticeTopology topo) {
  const double span = topo == LatticeTopology::Octet ? 0.0 : level_strut_per_cell(topo);   // the octet: R9
  return span > 0.0 ? 2.0 * kBridgeReachLimitMm / span : std::numeric_limits<double>::infinity();
}

std::string structural_refusal(LatticeTopology topo) {
  if (tetragonal(topo))
    return "This lattice type is stiffer one way than the others, so its strength cannot be checked yet: pick it in "
           "Aesthetic, or pick another type for Structural.";
  return "";
}

std::string structural_note(LatticeTopology topo) {
  if (!lattice_topology_certifiable(topo) || lattice_topology_is_sheet(topo) || !lattice_has_strut_cell(topo)) return "";
  try {
    const double open = lattice_width_bounds(topo).open_look, cell = 8.0;   // a ratio: any cell gives the same answer
    if (lattice_density_from_strut(topo, cell, 0.5 * open * cell) >= lattice_rho_min(topo)) return "";
  } catch (const std::exception&) {
  }
  return "This lattice type's strength is measured only for denser struts than it lays, so its lattice gets no "
         "strength credit yet.";
}

std::vector<StrutCellStrut> cell_struts(LatticeTopology topo, const Frame& frame) {
  std::vector<StrutCellStrut> struts = strut_cell_closed_struts(lattice_strut_cell(topo));
  if (!tetragonal(topo)) return struts;
  // The frame's axis nearest up (+Z): the third on a tie, then the first.
  int up = 2;
  for (int k : {0, 1})
    if (std::fabs(frame.ax[k].z) > std::fabs(frame.ax[up].z) + 1e-9) up = k;
  if (up == 2) return struts;
  // The cell's z goes to `up`, its x and y to the two after it, in turn (a turn of the axes, never a mirror).
  const int ox = (up + 1) % 3, oy = (up + 2) % 3;
  for (StrutCellStrut& s : struts)
    for (StrutCellPoint* p : {&s.a, &s.b}) {
      int q[3];
      q[ox] = p->x;
      q[oy] = p->y;
      q[up] = p->z;
      *p = {q[0], q[1], q[2]};
    }
  return struts;
}

}  // namespace topopt::lattice_layout
