// Lattice rebuild: how a bar's cut end is finished (S4, S11), for any stage that lays bars (the cells' struts in
// lay_bars, a weave's strands in weave_bars). Internal to the engine. See lattice_layout.hpp.
#pragma once

#include <algorithm>
#include <cmath>
#include <limits>

#include "topopt/lattice_layout.hpp"

namespace topopt::lattice_layout::detail {

// The straight line of one strut or strand segment, from `a` (t = 0) to `b` (t = 1).
struct BarLine {
  Vec3 a{}, b{}, ab{}, dir{};
  double length = 0.0;
  BarLine(const Vec3& from, const Vec3& to) : a(from), b(to) {
    ab = Vec3{b.x - a.x, b.y - a.y, b.z - a.z};
    length = std::sqrt(ab.x * ab.x + ab.y * ab.y + ab.z * ab.z);
    dir = Vec3{ab.x / length, ab.y / length, ab.z / length};
  }
};

// Where a bar is looked past at a cut end: this far beyond it, along the line (three times the hair a cell's strut is
// read inside its cell).
inline constexpr double kPastEnd = 3.0 * 0.02;   // mm

// One run [t0, t1] of a line that lies in its bar's own lattice becomes `piece` (whose width, cell, region and
// `piece` flag the caller has set). An end with `cut_*` set is finished; the other stays as `piece` has it (a Node).
//   held(t)  is the line at t its bar's own lattice (for a cell: read a hair inside the cell)
//   at(t)    the point read to tell what lies past an end; t may be outside 0 .. 1 (the caller holds it where it must)
//   solid_at(probe, p, w)  is `p` (read as `w`, inside the part) solid: a SolidAt for a layout's bars
//   out_*    the nearest t known NOT to be held, beyond that end: the end is found between it and t0 (t1) first.
//            NaN: t0 (t1) is the end itself (a strand's own free end), nothing to find.
// A finished end is tagged by what lies just past it: Surface (outside the part: the end is moved onto the part's own
// surface along the line), Solid (inside the part and solid by `solid_at`: the bar runs on into it by its own width,
// S11, never past t = 0 or 1) or Loose (open lattice). Returns false for a stub: a piece (piece.piece) shorter than
// its own width (S4), which the caller does not keep. K6: `bed_z` given (a cell lattice), an end cut flat ON the bed (a
// Surface end within a layer of the part's lowest plane, `bed_z`) is marked (Bar::on_bed), and its piece is kept however
// short: it stands on the bed and holds what is above it.
inline constexpr double kBedLayerMM = 0.2;   // mm: a layer
template <class Held, class At, class Solid>
bool finish_bar_ends(Bar& piece, const BarLine& line, double t0, double t1, bool cut_a, double out_a, bool cut_b,
                     double out_b, const Domain::Probe& probe, const Solid& solid_at, Held held, At at,
                     double bed_z = std::numeric_limits<double>::quiet_NaN()) {
  const Vec3& a = line.a;
  const Vec3& b = line.b;
  const Vec3& ab = line.ab;
  const Vec3& dir = line.dir;
  const double length = line.length;
  // What lies just past a cut end, a little farther along the line.
  auto past = [&](double t, double step) {
    const Vec3 p = at(t + step / length);
    const Where w = probe.where(p);
    if (w.why == Why::Outside) return Bar::End::Surface;
    // Solid, or lattice that no cell holds, which is solid too (D14); only lattice that another cell holds (or a
    // weave's open lattice, O1) leaves the end loose.
    return solid_at(probe, p, w) ? Bar::End::Solid : Bar::End::Loose;
  };
  // Between a point that is held and its neighbour that is not: where it changes.
  auto edge = [&](double t_in, double t_out) {
    // To a few thousandths of a millimetre: the reading itself is taken a fiftieth of a millimetre inside the cell,
    // so nothing finer is being found.
    for (int k = 0; k < 7; ++k) {
      const double m = 0.5 * (t_in + t_out);
      if (held(m)) t_in = m; else t_out = m;
    }
    return t_in;
  };
  // A bar the part's surface cuts ends ON the surface (S11). Its own lattice was read a hair inside, so the end found
  // is within that hair of the surface: the line itself is now followed to the surface itself, between a point a
  // tenth of a millimetre back (in the part) and one as far on (not).
  auto to_surface = [&](double t_edge, double sign) {
    auto in_part = [&](double t) {
      return probe.part().depth(Vec3{a.x + ab.x * t, a.y + ab.y * t, a.z + ab.z * t}) >= -1e-7;
    };
    double in_t = std::clamp(t_edge - sign * 0.1 / length, 0.0, 1.0);
    double out_t = std::clamp(t_edge + sign * 0.1 / length, 0.0, 1.0);
    if (!in_part(in_t) || in_part(out_t)) return t_edge;
    // One straight line finds it, unless the line lies IN a surface of the part (then it runs along that surface
    // and the answer is searched for).
    {
      const Vec3 from{a.x + ab.x * in_t, a.y + ab.y * in_t, a.z + ab.z * in_t};
      const double reach = probe.part().reach_by_line(from, Vec3{dir.x * sign, dir.y * sign, dir.z * sign});
      const double hit = in_t + sign * reach / length;
      if (reach >= 0.0 && (hit - in_t) * sign <= (out_t - in_t) * sign && in_part(hit) &&
          !in_part(hit + sign * 1e-6 / length))
        return hit;
    }
    for (int k = 0; k < 26; ++k) {
      const double m = 0.5 * (in_t + out_t);
      if (in_part(m)) in_t = m; else out_t = m;
    }
    return in_t;
  };
  if (cut_a) {
    if (!std::isnan(out_a)) t0 = edge(t0, out_a);
    piece.end_a = past(t0, -kPastEnd);
    if (piece.end_a == Bar::End::Surface) t0 = to_surface(t0, -1.0);
  }
  if (cut_b) {
    if (!std::isnan(out_b)) t1 = edge(t1, out_b);
    piece.end_b = past(t1, kPastEnd);
    if (piece.end_b == Bar::End::Surface) t1 = to_surface(t1, 1.0);
  }
  // K6 (his 11-24: "why can't we just extend cells and cut them off where the bed is?"): an end cut flat on the bed
  // stands there and holds the struts above it (the bottom row of a grid the bed cuts thin).
  piece.on_bed = 0;
  if (std::isfinite(bed_z)) {
    if (piece.end_a == Bar::End::Surface && a.z + ab.z * t0 <= bed_z + kBedLayerMM) piece.on_bed |= Bar::kOnBedA;
    if (piece.end_b == Bar::End::Surface && a.z + ab.z * t1 <= bed_z + kBedLayerMM) piece.on_bed |= Bar::kOnBedB;
  }
  if ((t1 - t0) * length < piece.width) {   // S4: a stub shorter than one strut width, unless it stands on the bed
    if (piece.piece && !piece.on_bed) return false;
  }
  // S11: where the solid begins the bar runs on into it by its own width.
  if (piece.end_a == Bar::End::Solid) t0 = std::max(0.0, t0 - piece.width / length);
  if (piece.end_b == Bar::End::Solid) t1 = std::min(1.0, t1 + piece.width / length);
  piece.a = Vec3{a.x + dir.x * t0 * length, a.y + dir.y * t0 * length, a.z + dir.z * t0 * length};
  piece.b = Vec3{a.x + dir.x * t1 * length, a.y + dir.y * t1 * length, a.z + dir.z * t1 * length};
  if (t0 == 0.0) piece.a = a;   // a node, exactly
  if (t1 == 1.0) piece.b = b;
  return true;
}

}  // namespace topopt::lattice_layout::detail
