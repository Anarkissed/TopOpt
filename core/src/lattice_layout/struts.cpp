// Lattice rebuild, stage C: each cell's strut width (rules R1, R2, R5, R6, R9, R10, R11).
#include "topopt/lattice_layout.hpp"

#include <algorithm>
#include <cmath>
#include <map>
#include <stdexcept>
#include <string>

#include "topopt/stepped_plan.hpp"  // kSteppedPrintsOpenMaxStrutPerCell

namespace topopt::lattice_layout {

StrutReport set_struts(Layout& layout, const StrutSpec& spec) {
  // The two ratios below (open look, quilt) are octet's. Another type's own pair is a
  // per-type fact this file does not hold yet: refuse rather than draw octet's widths
  // under another type's name.
  if (layout.topology != LatticeTopology::Octet)
    throw std::invalid_argument(std::string("lattice_layout: strut widths are not stated for ") +
                                lattice_topology_name(layout.topology) + " yet");

  StrutReport rep;
  const double bead = layout.bead_mm;
  const double ceiling = spec.allow_quilt ? kQuiltStrutPerCell : kSteppedPrintsOpenMaxStrutPerCell;

  // The dial is read on the largest cell: of the part (Uniform), or of each region.
  double part_ref = 0.0;
  std::map<int, double> region_ref;
  for (const Cell& c : layout.cells) {
    part_ref = std::max(part_ref, c.size);
    double& r = region_ref[c.region];
    r = std::max(r, c.size);
  }
  // R10: 1% is one line, 100% is the widest allowed, even steps of width between.
  const auto ratio_at = [&](double dial, double ref) {
    const double t = std::clamp((dial - 0.01) / 0.99, 0.0, 1.0);
    const double lo = bead, hi = std::max(bead, ceiling * ref);
    return (lo + t * (hi - lo)) / ref;
  };
  const double part_ratio = part_ref > 0.0 ? ratio_at(spec.dial, part_ref) : 0.0;
  std::map<int, double> region_ratio;
  if (spec.mode == Density::PerRegion) {
    for (const auto& [id, ref] : region_ref) {
      double dial = spec.dial;
      for (const RegionDial& d : spec.region_dial)
        if (d.region == id) dial = d.dial;
      region_ratio[id] = ratio_at(dial, ref);
    }
  }

  const double amount = std::pow(2.0, std::clamp(spec.strength, -1.0, 1.0));   // G4
  constexpr double kCoarseCellBandRaise = 0.35;   // the run's own share (grading.cpp)
  for (Cell& c : layout.cells) {
    if (c.band < 1.0 && spec.width_mm <= 0.0) {
      // Inside a Grade to shape band (G8, R3, G4; the run's band law, in width). The
      // strut keeps the width it has on the region's own cell while the cell shrinks,
      // then is raised toward the quilt by (1 - t) x share x amount, and to whole lines.
      // The band is exempt from the open look; the quilt still tops it.
      const double ratio = spec.mode == Density::PerRegion ? region_ratio[c.region] : part_ratio;
      const double own = c.own > 0.0 ? c.own : c.size;
      const double q = std::max(bead, kQuiltStrutPerCell * c.size);
      double w = std::clamp(ratio * own, bead, q);
      const double share = c.finest ? 1.0 : kCoarseCellBandRaise;
      w = std::max(w, std::min(q, w + (q - w) * (1.0 - c.band) * share * amount));
      w = std::min(q, std::ceil(w / bead - 1e-9) * bead);
      c.strut = std::max(bead, w);
      continue;
    }
    double want = 0.0;
    if (spec.width_mm > 0.0) want = spec.width_mm;                       // R11
    else if (spec.mode == Density::PerRegion) want = region_ratio[c.region] * c.size;
    else want = part_ratio * c.size;                                     // R6
    // R3: a Grade to shape band is exempt from the open look; the quilt still tops it.
    const double top = std::max(bead, (c.band < 1.0 ? kQuiltStrutPerCell : ceiling) * c.size);
    double w = want;
    if (w < bead * (1.0 - 1e-12)) { w = bead; ++rep.at_bead; }           // R5
    else if (w > top * (1.0 + 1e-12)) { w = top; ++rep.at_ceiling; }     // R2, R9
    c.strut = std::clamp(w, bead, top);
  }
  return rep;
}

}  // namespace topopt::lattice_layout
