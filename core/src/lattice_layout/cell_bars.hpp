// Lattice rebuild, stage D: one cell's struts (lay_bars' per-cell rule). Internal to the engine. notes30 C2: the very
// rule lay_bars runs for every cell, given to the strut stream too (stream.cpp), so a strut the stream hands over is made
// by the same code, in the same order, from the same readings. See lattice_layout.hpp.
#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <map>
#include <vector>

#include "topopt/lattice_layout.hpp"
#include "topopt/strut_cell.hpp"
#include "bar_ends.hpp"

namespace topopt::lattice_layout::detail {

// A strut is read a hair inside its own cell: a strut lying IN the part's surface (the outermost layer of a face's
// lattice) or in the face two cells share is this cell's.
inline constexpr double kCellInward = 0.02;   // mm
// Along a strut of a cut cell, the cell's shape is read this often, and each place it starts or stops is then found to
// a ten-thousandth of a millimetre.
inline constexpr double kCellStep = 0.3;      // mm

// The re-entrant rule of lay_bars, on one cell's bars (`from`: the strut of `struts` each came from; `glo`, `unit`: the
// cell's integer grid in its frame). A waist strut joins a waist (not a corner of the cell) to a corner.
inline void hold_waists(std::vector<Bar>& bars, const std::vector<std::size_t>& from, const std::vector<StrutCellStrut>& struts,
                 const Frame& f, const double glo[3], const double unit[3]) {
  const auto corner = [&](const StrutCellPoint& q, int S) { return q.x % S == 0 && q.y % S == 0 && q.z % S == 0; };
  const int S = 4;
  const auto z_of = [&](const StrutCellPoint& q) {
    return f.at(glo[0] + q.x * unit[0], glo[1] + q.y * unit[1], glo[2] + q.z * unit[2]).z;
  };
  struct Waist { StrutCellPoint at; bool held = false; };
  std::vector<Waist> waists;
  const auto waist_of = [&](const StrutCellPoint& q) -> std::size_t {
    for (std::size_t k = 0; k < waists.size(); ++k)
      if (waists[k].at.x == q.x && waists[k].at.y == q.y && waists[k].at.z == q.z) return k;
    waists.push_back({q, false});
    return waists.size() - 1;
  };
  // Per bar: its waist (-1: a column), whether its strut lies below the waist, and whether its corner side is its end a.
  std::vector<long> waist(bars.size(), -1);
  std::vector<char> lower(bars.size(), 0), corner_is_a(bars.size(), 0), drop(bars.size(), 0);
  for (std::size_t i = 0; i < bars.size(); ++i) {
    const StrutCellStrut& s = struts[from[i]];
    const bool ca = corner(s.a, S), cb = corner(s.b, S);
    if (ca == cb) continue;   // a column (corner to corner)
    const StrutCellPoint& w = ca ? s.b : s.a;
    const StrutCellPoint& c = ca ? s.a : s.b;
    waist[i] = static_cast<long>(waist_of(w));
    lower[i] = z_of(c) < z_of(w);
    // The piece's end a is on the strut's s.a side (pieces keep the strut's direction).
    corner_is_a[i] = ca;
  }
  for (std::size_t i = 0; i < bars.size(); ++i) {
    if (waist[i] < 0 || !lower[i]) continue;
    const Bar& b = bars[i];
    const Bar::End low = corner_is_a[i] ? b.end_a : b.end_b, high = corner_is_a[i] ? b.end_b : b.end_a;
    const bool on_bed = (b.on_bed & (corner_is_a[i] ? Bar::kOnBedA : Bar::kOnBedB)) != 0;
    const bool rests = low == Bar::End::Node || low == Bar::End::Solid || (low == Bar::End::Surface && on_bed);
    if (!rests && low == Bar::End::Surface) drop[i] = 1;   // starts at a wall, in the air
    if (rests && high == Bar::End::Node) waists[static_cast<std::size_t>(waist[i])].held = true;
  }
  for (std::size_t i = 0; i < bars.size(); ++i)
    if (waist[i] >= 0 && !waists[static_cast<std::size_t>(waist[i])].held) drop[i] = 1;
  std::size_t k = 0;
  for (std::size_t i = 0; i < bars.size(); ++i)
    if (!drop[i]) bars[k++] = bars[i];
  bars.resize(k);
}

// The bars of cell `c` (laid on frame `f`, whose struts `struts` are cell_struts(type, f)), appended to `bars` in the
// order lay_bars lays them; `stubs` counts the pieces too short to keep (S4). `holds(a, b, c)`: is the point (a, b, c) of
// the cell's frame the cell's own lattice (cell_holds_at for the layout's cell); `solid_at(probe, p, w)` is SolidAt.
// `bed_z` the part's lowest plane (K6). Re-entrant (`reentrant`): its waists held as lay_bars holds them.
template <class Holds, class Solid>
void cell_bars(const Cell& c, const Frame& f, const std::vector<StrutCellStrut>& struts, const StrutCell& type,
               bool reentrant, const Domain::Probe& probe, const Solid& solid_at, const Holds& holds, double bed_z,
               std::vector<Bar>& bars, std::size_t& stubs) {
  constexpr double kInward = kCellInward;
  constexpr double kStep = kCellStep;
  // K8: the struts span the cube and what it reaches past it on to a square face (Cell::reach_lo, reach_hi).
  const double glo[3] = {c.lo[0] - c.reach_lo[0], c.lo[1] - c.reach_lo[1], c.lo[2] - c.reach_lo[2]};
  const double unit[3] = {(c.size + c.reach_lo[0] + c.reach_hi[0]) / type.S,
                          (c.size + c.reach_lo[1] + c.reach_hi[1]) / type.S,
                          (c.size + c.reach_lo[2] + c.reach_hi[2]) / type.S};
  const double mid[3] = {glo[0] + 0.5 * (c.size + c.reach_lo[0] + c.reach_hi[0]),
                         glo[1] + 0.5 * (c.size + c.reach_lo[1] + c.reach_hi[1]),
                         glo[2] + 0.5 * (c.size + c.reach_lo[2] + c.reach_hi[2])};
  // Re-entrant (below, after the cell's struts): which strut each of the cell's bars came from.
  std::vector<std::size_t> from_strut;
  // Each node of the cell, read once (a hair toward the cell's middle): -1 not yet.
  std::map<std::array<int, 3>, bool> node_read;
  auto node_is_mine = [&](const StrutCellPoint& n) {
    const std::array<int, 3> k{n.x, n.y, n.z};
    auto it = node_read.find(k);
    if (it != node_read.end()) return it->second;
    double q[3] = {glo[0] + n.x * unit[0], glo[1] + n.y * unit[1], glo[2] + n.z * unit[2]};
    double off[3], len = 0.0;
    for (int a = 0; a < 3; ++a) { off[a] = mid[a] - q[a]; len += off[a] * off[a]; }
    len = std::sqrt(len);
    if (len > 0.0)
      for (int a = 0; a < 3; ++a) q[a] += off[a] * std::min(1.0, kInward / len);
    const bool yes = holds(q[0], q[1], q[2]);
    node_read.emplace(k, yes);
    return yes;
  };
  for (const StrutCellStrut& s : struts) {
    const double qa[3] = {glo[0] + s.a.x * unit[0], glo[1] + s.a.y * unit[1], glo[2] + s.a.z * unit[2]};
    const double qb[3] = {glo[0] + s.b.x * unit[0], glo[1] + s.b.y * unit[1], glo[2] + s.b.z * unit[2]};
    const detail::BarLine line(f.at(qa[0], qa[1], qa[2]), f.at(qb[0], qb[1], qb[2]));
    const Vec3 &a = line.a, &b = line.b;
    const double length = line.length;
    // The strut's point at t (0 at a, 1 at b), a hair toward the cell's middle.
    auto inward = [&](double t, double q[3]) {
      double off[3], l = 0.0;
      for (int k = 0; k < 3; ++k) {
        q[k] = qa[k] + (qb[k] - qa[k]) * t;
        off[k] = mid[k] - q[k];
        l += off[k] * off[k];
      }
      l = std::sqrt(l);
      if (l > 0.0)
        for (int k = 0; k < 3; ++k) q[k] += off[k] * std::min(1.0, kInward / l);
    };
    // Is the strut, at t, in the cell's own shape?
    auto mine = [&](double t) {
      double q[3];
      inward(t, q);
      return holds(q[0], q[1], q[2]);
    };
    Bar bar;
    bar.width = c.strut;
    bar.cell = c.size;
    bar.region = c.region;
    {   // the one plane of the cell's grid the strut lies in, if there is exactly one
      const int along[3] = {s.b.x - s.a.x, s.b.y - s.a.y, s.b.z - s.a.z};
      const int none = (along[0] == 0) + (along[1] == 0) + (along[2] == 0);
      if (none == 1) bar.flat = f.ax[along[0] == 0 ? 0 : (along[1] == 0 ? 1 : 2)];
    }
    // A strut is whole when its two ends and its middle are the cell's (and, in a cell
    // the layout found cut, its quarter points too), and its own line, a hair inside
    // the cell, meets no surface of the part between its ends. That is asked of every
    // strut, in a cell the layout found whole as well: the layout looks a sixth of the
    // cell in from each face, and an edge can pass nearer the face than that. Only a
    // strut that fails it is read closely.
    const bool end_a = node_is_mine(s.a), end_b = node_is_mine(s.b);
    const bool middle = mine(0.5);
    const bool all = end_a && end_b && middle, none = !end_a && !end_b && !middle;
    // None of the five: the strut is not this cell's at all. (A piece between two of
    // them would be under a quarter of the strut long.)
    if (none && !mine(0.25) && !mine(0.75)) continue;
    if (all && (!c.cut || (mine(0.25) && mine(0.75)))) {
      double q0[3], q1[3];
      inward(0.0, q0);
      inward(1.0, q1);
      const Vec3 from = f.at(q0[0], q0[1], q0[2]), to = f.at(q1[0], q1[1], q1[2]);
      const Vec3 along{to.x - from.x, to.y - from.y, to.z - from.z};
      const double span = std::sqrt(along.x * along.x + along.y * along.y + along.z * along.z);
      const double clear = span > 0.0
          ? probe.part().reach_by_line(from, Vec3{along.x / span, along.y / span, along.z / span})
          : 0.0;
      if (clear < 0.0 || clear >= span - 1e-9) {
        bar.a = a;
        bar.b = b;
        bars.push_back(bar);
        if (reentrant) from_strut.push_back(static_cast<std::size_t>(&s - struts.data()));
        continue;
      }
    }
    // The point read past a cut end at t: on the strut, a hair toward the cell's middle.
    auto at = [&](double t) {
      double q[3];
      inward(std::clamp(t, 0.0, 1.0), q);
      return f.at(q[0], q[1], q[2]);
    };
    const int n = std::clamp(static_cast<int>(std::ceil(length / kStep)), 6, 24);
    std::vector<char> in(static_cast<std::size_t>(n) + 1);
    in[0] = node_is_mine(s.a);   // the two ends are nodes, read once per cell
    in[static_cast<std::size_t>(n)] = node_is_mine(s.b);
    for (int i = 1; i < n; ++i) in[static_cast<std::size_t>(i)] = mine(static_cast<double>(i) / n);
    for (int i = 0; i <= n; ++i) {
      if (!in[static_cast<std::size_t>(i)]) continue;
      int j = i;
      while (j < n && in[static_cast<std::size_t>(j) + 1]) ++j;
      Bar piece = bar;
      piece.piece = i > 0 || j < n;
      // Its cut ends finished (S4, S11): found between the last point held and the next not, then tagged.
      const bool kept = detail::finish_bar_ends(piece, line, static_cast<double>(i) / n, static_cast<double>(j) / n,
                                                i > 0, static_cast<double>(i - 1) / n, j < n,
                                                static_cast<double>(j + 1) / n, probe, solid_at, mine, at, bed_z);
      i = j;
      if (!kept) { ++stubs; continue; }
      bars.push_back(piece);
      if (reentrant) from_strut.push_back(static_cast<std::size_t>(&s - struts.data()));
    }
  }
  if (reentrant) hold_waists(bars, from_strut, struts, f, glo, unit);
}

}  // namespace topopt::lattice_layout::detail
