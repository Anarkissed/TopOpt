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
  StrutReport rep;
  const double line = layout.bead_mm;
  // R5: the thinnest strut. Two line widths (his print, 2026-11-11), never under one.
  const double bead = std::max(line, layout.min_strut_mm);
  // R2: the widest strut is the type's open look; its quilt only with Allow quilt. (A layout
  // made before the type's limits were kept reads them here.)
  double open_look = layout.open_look, touch = layout.touch;
  if (!(open_look > 0.0) || !(touch > 0.0)) {
    const LatticeWidthBounds bounds = lattice_width_bounds(layout.topology);
    open_look = bounds.open_look;
    touch = bounds.touch;
  }
  const double ceiling = spec.allow_quilt ? touch : open_look;

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
      // Inside a Grade to shape band (G8, G4; the run's band law, in width). The strut
      // keeps the width it has on the region's own cell while the cell shrinks, then is
      // raised toward the widest strut allowed by (1 - t) x share x amount, and to whole
      // lines. The widest allowed is the open look; the quilt only with Allow quilt (R2,
      // his rule of 2026-11-12: without it the band thickens but never quilts).
      const double ratio = spec.mode == Density::PerRegion ? region_ratio[c.region] : part_ratio;
      const double own = c.own > 0.0 ? c.own : c.size;
      const double q = std::max(bead, ceiling * c.size);
      double w = std::clamp(ratio * own, bead, q);
      const double share = c.finest ? 1.0 : kCoarseCellBandRaise;
      w = std::max(w, std::min(q, w + (q - w) * (1.0 - c.band) * share * amount));
      w = std::min(q, std::ceil(w / line - 1e-9) * line);   // to whole lines
      c.strut = std::max(bead, w);
      continue;
    }
    double want = 0.0;
    if (spec.width_mm > 0.0) want = spec.width_mm;                       // R11
    else if (spec.mode == Density::PerRegion) want = region_ratio[c.region] * c.size;
    else want = part_ratio * c.size;                                     // R6
    // R2: the widest strut allowed, in a band as anywhere else.
    const double top = std::max(bead, ceiling * c.size);
    double w = want;
    if (w < bead * (1.0 - 1e-12)) { w = bead; ++rep.at_bead; }           // R5
    else if (w > top * (1.0 + 1e-12)) { w = top; ++rep.at_ceiling; }     // R2, R9
    c.strut = std::clamp(w, bead, top);
  }
  return rep;
}

}  // namespace topopt::lattice_layout
