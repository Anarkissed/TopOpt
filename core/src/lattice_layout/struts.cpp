// Lattice rebuild, stage C: each cell's strut width (rules R1, R2, R5, R6, R9, R10, R11).
#include "topopt/lattice_layout.hpp"

#include <algorithm>
#include <cmath>
#include <map>
#include <optional>
#include <stdexcept>
#include <string>

#include "topopt/stepped_plan.hpp"  // kSteppedPrintsOpenMaxStrutPerCell

namespace topopt::lattice_layout {

StrutReport set_struts(Layout& layout, const StrutSpec& spec, const AreaOwnMap* own) {
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
  const double ceiling = spec.allow_quilt ? touch : open_look;   // Allow quilt is the part's only (R19)
  // ★ notes29b (his notes on release 20, 2026-11-25: "limit both when 'Allow quilt' is turned off", at the EXACT point each
  // type becomes a quilt): `ceiling` is what the lattice lays on its own (the dial's 1, the band's aim): the open look with
  // Allow quilt off, as before. The LIMIT is the quilt's: with Allow quilt off no strut is at or past the touch, it stops
  // one printed line short of it (lattice_quilt_off_strut_mm: a line of air between the closest struts); with it on, the
  // touch itself. Only an ask past the open look (a dial past 1, a typed strut, the ends in mm, the thinnest strut in a
  // thin wall's small cell) reaches it. The open look itself always stands (it is under every type's touch): with a
  // one-line strut on the smallest open cells it is the wider of the two, and is kept, as before.
  const double gap = spec.allow_quilt ? 0.0 : kQuiltOffGapLines * line;
  const auto widest = [&](double cell) { return std::max({bead, touch * cell - gap, ceiling * cell}); };

  // The dial is read on the largest cell: of the part (Uniform), or of each region.
  double part_ref = 0.0;
  std::map<int, double> region_ref;
  for (const Cell& c : layout.cells) {
    part_ref = std::max(part_ref, c.size);
    double& r = region_ref[c.region];
    r = std::max(r, c.size);
  }
  // R10: 1% is one line, 100% is the widest allowed, even steps of width between. ★ notes29b: with Allow quilt off 1 is the
  // open look, as before, and a dial past 1 goes on in the same steps of width past it, up to the limit (the app's Density
  // percent past the open look); with it on, 1 is the touch and nothing is past it.
  const auto ratio_at = [&](double dial, double ref) {
    const double t = std::max(0.0, (dial - 0.01) / 0.99);
    const double lo = bead, hi = std::max(bead, ceiling * ref);
    return std::min(lo + t * (hi - lo), std::max(hi, widest(ref))) / ref;
  };

  // What one region's cells are set by (R19): the part's settings, with the region's stated values over them.
  struct Rule {
    bool by_stress = false, in_mm = false, graded = false;
    double ratio = 0.0;                     // not by stress: strut / cell
    double width_mm = 0.0;                  // R11
    double r_light = 0.0, r_heavy = 0.0, w_light = 0.0, w_heavy = 0.0;
    double reference = 0.0, response = 1.0;
    double amount = 1.0;                    // G4
  };
  const auto rule_for = [&](int id, double ref_here, const AreaOwn* o) {
    Rule u;
    const auto pick = [&](const std::optional<double>& v, double part) { return o && v ? *v : part; };
    // Not by stress: the region's stated dial on its own largest cell; else the part's, as today (Per region: the
    // region's entry or the dial, on the region's largest cell; Uniform: the dial, on the part's largest cell).
    if (o && o->dial) {
      u.ratio = ratio_at(*o->dial, ref_here);
    } else if (spec.mode == Density::PerRegion) {
      double dial = spec.dial;
      for (const RegionDial& d : spec.region_dial)
        if (d.region == id) dial = d.dial;
      u.ratio = ratio_at(dial, ref_here);
    } else {
      u.ratio = part_ref > 0.0 ? ratio_at(spec.dial, part_ref) : 0.0;
    }
    u.width_mm = pick(o ? o->width_mm : std::nullopt, spec.width_mm);
    u.amount = std::pow(2.0, std::clamp(pick(o ? o->strength : std::nullopt, spec.strength), -1.0, 1.0));
    u.by_stress = o && o->by_stress ? *o->by_stress : spec.mode == Density::ByStress;
    if (u.by_stress) {
      // By stress (R7, R8, R12, R16, R18): the two ends, and whether there is a stress to grade by at all.
      const double wl = pick(o ? o->width_light_mm : std::nullopt, spec.width_light_mm);
      const double wh = pick(o ? o->width_heavy_mm : std::nullopt, spec.width_heavy_mm);
      u.in_mm = wl > 0.0 && wh > 0.0;
      if (u.in_mm) {
        u.w_light = std::min(wl, wh);
        u.w_heavy = std::max(wl, wh);
      } else {
        // Ends the region states are read on its own largest cell; the part's on the part's largest.
        const bool mine = o && (o->dial_light || o->dial_heavy);
        const double at = mine ? ref_here : part_ref;
        const double dl = pick(o ? o->dial_light : std::nullopt, spec.dial_light);
        const double dh = pick(o ? o->dial_heavy : std::nullopt, spec.dial_heavy);
        if (at > 0.0) {
          u.r_light = ratio_at(std::min(dl, dh), at);
          u.r_heavy = ratio_at(std::max(dl, dh), at);
        }
      }
      u.reference = o && o->reference_mpa && *o->reference_mpa > 0.0 ? *o->reference_mpa : spec.reference_mpa;
      u.graded = spec.demand && !spec.demand->empty() && u.reference > 0.0;
      const double resp = pick(o ? o->response : std::nullopt, spec.response);
      u.response = std::clamp(std::isfinite(resp) ? resp : 1.0, 0.25, 4.0);
      if (!u.graded) rep.no_stress = true;
    }
    return u;
  };
  if (spec.mode == Density::ByStress) {
    rep.no_stress = !(spec.demand && !spec.demand->empty() && spec.reference_mpa > 0.0);
    rep.reference_mpa = spec.reference_mpa > 0.0 ? spec.reference_mpa : 0.0;
  }
  std::map<int, Rule> rules;
  for (const auto& [id, ref] : region_ref) {
    const AreaOwn* o = nullptr;
    if (own) {
      const auto it = own->find(id);
      if (it != own->end() && id > 0 && it->second.any()) o = &it->second;
    }
    rules[id] = rule_for(id, ref, o);
  }

  // A cell's place between the two ends, 0 .. 1: its stress over the reference, to the response.
  const auto stress_t = [&](const Cell& c, const Rule& u) {
    if (!u.graded) { ++rep.at_light; return 0.0; }
    const Frame& fr = layout.frames.at(static_cast<std::size_t>(c.frame));
    Vec3 lo{0, 0, 0}, hi{0, 0, 0};
    bool first = true;
    for (int corner = 0; corner < 8; ++corner) {
      const Vec3 p = fr.at(c.lo[0] + ((corner & 1) ? c.size : 0.0), c.lo[1] + ((corner & 2) ? c.size : 0.0),
                           c.lo[2] + ((corner & 4) ? c.size : 0.0));
      if (first) { lo = hi = p; first = false; continue; }
      lo = {std::min(lo.x, p.x), std::min(lo.y, p.y), std::min(lo.z, p.z)};
      hi = {std::max(hi.x, p.x), std::max(hi.y, p.y), std::max(hi.z, p.z)};
    }
    const double d = spec.demand->highest_in(lo, hi);
    rep.highest_mpa = std::max(rep.highest_mpa, d);
    const double f = std::clamp(d / u.reference, 0.0, 1.0);
    if (f == 0.0) ++rep.at_light;
    if (f == 1.0) ++rep.at_heavy;
    return std::pow(f, u.response);
  };

  constexpr double kCoarseCellBandRaise = 0.35;   // the run's own share (grading.cpp)
  for (Cell& c : layout.cells) {
    const Rule& u = rules[c.region];
    // By stress: this cell's strut / cell (dials) or its width in mm, before any limit.
    double stress_ratio = 0.0, stress_mm = 0.0;
    if (u.by_stress) {
      const double t = stress_t(c, u);
      if (u.in_mm) stress_mm = u.w_light + t * (u.w_heavy - u.w_light);
      else stress_ratio = u.r_light + t * (u.r_heavy - u.r_light);
    }
    if (c.band < 1.0 && (u.by_stress || u.width_mm <= 0.0)) {
      // Inside a Grade to shape band (G8, G4; the run's band law, in width). The strut
      // keeps the width it has on the region's own cell while the cell shrinks, then is
      // raised toward the widest strut allowed by (1 - t) x share x amount, and to whole
      // lines. The widest allowed is the open look; the quilt only with Allow quilt (R2,
      // his rule of 2026-11-12: without it the band thickens but never quilts).
      // By stress, it starts from the cell's own by-stress width (G8: the band only raises).
      const double ratio = u.by_stress ? stress_ratio : u.ratio;
      const double own_cell = c.own > 0.0 ? c.own : c.size;
      const double q = std::max(bead, ceiling * c.size);
      const bool in_mm = u.by_stress && u.in_mm;
      const double asked = in_mm ? stress_mm : ratio * own_cell;
      // ★ notes29b: asked past the open look on purpose (a dial past 1: its ratio is past it; the ends in mm: past it on
      // this cell, as out of the band): the strut keeps that width while the cell shrinks, to whole lines, never past the
      // limit, and the band does not raise it further. At or under the open look: as before (the band's own thickening of
      // a strut kept while its cell shrinks still stops at the open look).
      const bool past = !spec.allow_quilt && (in_mm ? stress_mm > std::max(bead, ceiling * c.size) * (1.0 + 1e-12)
                                                    : ratio > ceiling * (1.0 + 1e-12));
      if (past) {
        const double most = widest(c.size);
        double w = std::clamp(asked, bead, most);
        w = std::min(most, std::ceil(w / line - 1e-9) * line);
        if (asked > most * (1.0 + 1e-12)) ++rep.at_ceiling;
        c.strut = std::max(bead, w);
        continue;
      }
      double w = std::clamp(asked, bead, q);
      const double share = c.finest ? 1.0 : kCoarseCellBandRaise;
      w = std::max(w, std::min(q, w + (q - w) * (1.0 - c.band) * share * u.amount));
      w = std::min(q, std::ceil(w / line - 1e-9) * line);   // to whole lines
      c.strut = std::max(bead, w);
      continue;
    }
    double want = 0.0;
    if (u.by_stress) want = u.in_mm ? stress_mm : stress_ratio * c.size;   // R12, R16
    else if (u.width_mm > 0.0) want = u.width_mm;                         // R11
    else want = u.ratio * c.size;                                         // R6
    // R2: the widest strut allowed, in a band as anywhere else. ★ notes29b: with Allow quilt off, one printed line short of
    // the touch (it was the open look: an ask past it was held there); with it on, the touch, as before.
    const double top = widest(c.size);
    double w = want;
    if (w < bead * (1.0 - 1e-12)) { w = bead; ++rep.at_bead; }           // R5
    else if (w > top * (1.0 + 1e-12)) { w = top; ++rep.at_ceiling; }     // R2, R9
    c.strut = std::clamp(w, bead, top);
  }
  return rep;
}

}  // namespace topopt::lattice_layout
