// Lattice layout, stage C: the cells. See lattice_layout.hpp.
#include "topopt/lattice_layout.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <memory>
#include <mutex>
#include <thread>

#include "topopt/stepped_plan.hpp"  // stepped_size_menu, kSteppedPrintsOpenMaxStrutPerCell

namespace topopt::lattice_layout {

long WallMap::bin_of(double width) { return std::lround(width / kBin); }

int WallMap::find(double u, double w, double start, double width) const {
  if (walls.empty()) return -1;
  const long b = bin_of(width), sb = bin_of(start);
  const int i = static_cast<int>(std::floor((u - u0) / kPitch));
  const int j = static_cast<int>(std::floor((w - w0) / kPitch));
  for (int dj = 0; dj <= 1; ++dj)
    for (int di = 0; di <= 1; ++di) {
      const int a = i + di, c = j + dj;
      if (a < 0 || c < 0 || a >= nu || c >= nw) continue;
      for (int k = 0; k < kDeep; ++k) {
        const std::size_t n = (static_cast<std::size_t>(c) * nu + a) * kDeep + k;
        if (wall[n] >= 0 && std::labs(bin[n] - b) <= 1 && std::labs(sbin[n] - sb) <= 1)
          return wall[n];
      }
    }
  return -1;
}

namespace {
// How closely a wall's width is read, with margin: 10 nanometres on a half-width.
constexpr double kReadingSlack = 1e-5;   // mm

// The lattice's column through a point `c` below a flat region's face, from what the
// Domain read there. It starts at the face; or at a Protect skin's inner side (D5, D15);
// or, with a pocket under the face, where the material the point is in begins. It ends at
// the far surface, a skin on it, or the region's depth (C12). The wall the cells divide
// is that column and nothing else (C2): not material beyond a pocket, nor beyond the depth.
void column_of(const Domain::Probe::Room& room, double c, double depth, double* start,
               double* width) {
  const double lo = c - (room.skin_back ? room.back : room.part_back);
  const double hi = std::min(c + (room.skin_on ? room.on : room.part_on), depth);
  *start = room.skin_back || lo > kReadingSlack ? lo : 0.0;
  *width = hi - *start;
}
}  // namespace

Reading read_at(const Domain::Probe& probe, const Frame& frame, const WallMap& walls,
                double a, double b, double c) {
  Reading r;
  Domain::Probe::Room room;
  r.where = probe.where(frame.at(a, b, c), &r.width, walls.flat ? &room : nullptr);
  if (!r.where.lattice()) return r;
  if (walls.flat) {
    column_of(room, c, walls.depth, &r.start, &r.width);
    r.wall = walls.find(a, b, r.start, r.width);
  } else {
    r.width = std::min(r.width, walls.depth);   // C12: never more than the region's depth
  }
  return r;
}

bool cell_holds(const Layout& layout, const Domain::Probe& probe, const Cell& cell, const Vec3& p) {
  const Frame& f = layout.frames[static_cast<std::size_t>(cell.frame)];
  const Vec3 rel{p.x - f.origin.x, p.y - f.origin.y, p.z - f.origin.z};
  double q[3];
  for (int a = 0; a < 3; ++a) {
    q[a] = rel.x * f.ax[a].x + rel.y * f.ax[a].y + rel.z * f.ax[a].z;
    if (q[a] < cell.lo[a] || q[a] >= cell.lo[a] + cell.size) return false;
  }
  const WallMap& walls = layout.walls[static_cast<std::size_t>(cell.frame)];
  const Reading r = read_at(probe, f, walls, q[0], q[1], q[2]);
  return r.where.lattice() && r.where.id == cell.region && (!walls.flat || r.wall == cell.wall);
}

namespace {

// One region's pass.
struct Pass {
  const Domain::Probe* probe;
  const CellSpec* spec;
  int region;
  int frame_index;
  Frame frame;
  std::vector<double> sizes;   // the sizes this region may use, largest first
  std::vector<int> divisors;   // Stepped: the fractions of the base whose unit prints open
  Layout* out;
  RegionCells* tally;
  const WallMap* walls = nullptr;   // this frame's walls (flat = false where it has none)
  int wall = -1;                    // the wall this pass lays; -1 = what no wall holds
  const Region* band_region = nullptr;   // a flat region with Grade to shape on
  double base_mm = 0.0;             // this lay's own cell (S_base)
  double finest_mm = 0.0;           // the smallest cell its ladder allows (f)
  double floor_mm = 0.0;            // the smallest cell that may stand in this pass at all
  double skin_most = 0.0;           // the deepest Protect skin or cover of the domain

  // 0 at the region's outline, 1 at the band's inner edge and beyond (G2, G5).
  double band_t(const double lo[3], double s) const {
    if (!band_region) return 1.0;
    const double d = region_edge_distance(*band_region, frame.at(lo[0] + 0.5 * s, lo[1] + 0.5 * s, lo[2] + 0.5 * s));
    return std::clamp(d / spec->band_mm, 0.0, 1.0);
  }
  bool is_finest(double s) const { return s <= finest_mm * (1.0 + 1e-9); }
  double edge_distance(double a, double b, double c) const {
    return region_edge_distance(*band_region, frame.at(a, b, c));
  }
  // G1-G3, the preview's centre rule: a cell of size s may stand where its centre is at
  // least band (s - f) / (S_base - f) inside the outline. The region's own cell keeps its
  // centre a whole band in; the finest always may.
  bool band_allows(const double lo[3], double s) const {
    if (!band_region || is_finest(s)) return true;
    const double d = std::max(0.0, edge_distance(lo[0] + 0.5 * s, lo[1] + 0.5 * s, lo[2] + 0.5 * s));
    return d >= spec->band_mm * (s - finest_mm) / (base_mm - finest_mm) - 1e-9;
  }
  // G10: with Grade to shape on, only the finest cell may be cut by the outline. Any
  // larger cell must lie whole inside it (read at its corners, edge middles and centre).
  bool whole_in_outline(const double lo[3], double s) const {
    if (!band_region || is_finest(s)) return true;
    for (int b = 0; b < 3; ++b)
      for (int a = 0; a < 3; ++a)
        if (edge_distance(lo[0] + 0.5 * s * a, lo[1] + 0.5 * s * b, lo[2] + 0.5 * s) < -1e-6)
          return false;
    return true;
  }
  // G11: a cell below the open look's floor exists only inside the band.
  // C14: a cell too small to print does not stand, whatever it fits. (A region whose own
  // depth is under the floor has a base cell that small.)
  bool prints(const double lo[3], double s) const {
    return s >= floor_mm * (1.0 - 1e-9) && fine_allowed(lo, s);
  }
  bool fine_allowed(const double lo[3], double s) const {
    if (s >= out->floor_cell_mm * (1.0 - 1e-9)) return true;
    if (!band_region) return false;
    return edge_distance(lo[0] + 0.5 * s, lo[1] + 0.5 * s, lo[2] + 0.5 * s) - 0.5 * s < spec->band_mm;
  }

  bool allowed(double s) const {
    for (double a : sizes)
      if (std::fabs(a - s) <= 1e-9 * std::max(a, s)) return true;
    return false;
  }

  // One point: does lattice of this pass go here, and how big a cell does the wall at
  // this spot allow? A point counts when the layout's one Domain says lattice goes there
  // AND this region owns it (D13: ownership is the Domain's answer at the point, never
  // the order of work) AND, under a flat face, it is in the wall this pass lays.
  bool sample(double a, double b, double c, double* fit) const {
    const Reading r = read_at(*probe, frame, *walls, a, b, c);
    if (!r.where.lattice() || r.where.id != region) return false;
    if (walls->flat && r.wall != wall) return false;
    const double width = r.width;
    // C2, C12: never wider than the wall; the wall is the material at this spot along the
    // region's own direction, and never more than the region's depth.
    // C3-C5 (reviewer's ruling 2026-11-11): the cells a wall must hold are counted across
    // the member's NARROWEST width, whichever way that lies. A rib one cell wide across
    // the face and two deep is one across, not two.
    const double narrow = walls->flat ? narrowest(a, b, r) : width;
    *fit = std::min(width, narrow / spec->min_cells_across);
    return true;
  }

  // The member's narrowest width, for the lattice's column through (a, b): read ONCE per
  // column, at the column's middle (the point of it farthest from both faces, where a
  // groove or a chamfer on either face cannot pass for a narrow member), and kept for
  // every other point of the column in this base cell. Twice the depth below the surface
  // is a ball that fits, so when the middle is half the column deep nothing through it is
  // narrower and no width is measured at all: the case on any plain wall.
  struct Column { double a, b, start, width, narrow; };
  mutable std::vector<Column> columns;   // of the base cell being laid; emptied per cell
  double narrowest(double a, double b, const Reading& r) const {
    for (std::size_t i = columns.size(); i-- > 0;) {
      const Column& c = columns[i];
      if (c.a == a && c.b == b && std::fabs(c.start - r.start) < 1e-6 &&
          std::fabs(c.width - r.width) < 1e-6)
        return c.narrow;
    }
    const Vec3 mid = frame.at(a, b, r.start + 0.5 * r.width);
    double narrow = r.width;
    // Only whether it is narrower than the column is asked, so the measure may stop early.
    // (Between skins: a skin takes at most its own depth off each end of the ball.)
    if (2.0 * (probe->part().depth(mid) - skin_most) < r.width - kReadingSlack)
      narrow = std::min(r.width, probe->room_through(mid, r.width));
    columns.push_back({a, b, r.start, r.width, narrow});
    return narrow;
  }

  // D14: a strip of this pass's lattice thinner than the spacing of a cube's own sample
  // points slips between them (a ledge under a millimetre wide at the foot of a side
  // wall; the seam between a protected and an unprotected part of a face). The face's
  // map saw it: read again at the map's own nodes inside the cube's footprint.
  bool look_at_nodes(const double lo[3], double s, double* fit) const {
    if (!walls->flat || walls->nu == 0) return false;
    const double P = WallMap::kPitch;
    const int i0 = std::max(0, static_cast<int>(std::ceil((lo[0] - walls->u0) / P - 1e-9)));
    const int j0 = std::max(0, static_cast<int>(std::ceil((lo[1] - walls->w0) / P - 1e-9)));
    bool seen = false;
    for (int j = j0; j < walls->nw && walls->w0 + j * P < lo[1] + s; ++j)
      for (int i = i0; i < walls->nu && walls->u0 + i * P < lo[0] + s; ++i)
        for (int k = 0; k < WallMap::kDeep; ++k) {
          const std::size_t n = (static_cast<std::size_t>(j) * walls->nu + i) * WallMap::kDeep + k;
          if (walls->bin[n] < 0 || walls->wall[n] != wall) continue;
          // The part of the cube's depth this stretch runs through (all of it, for a
          // stretch that spans the cube).
          const double top = walls->sbin[n] * WallMap::kBin;
          const double end = top + walls->bin[n] * WallMap::kBin;
          const bool spans = top - WallMap::kBin <= lo[2] && end + WallMap::kBin >= lo[2] + s;
          const double d0 = spans ? lo[2] : std::max(lo[2], top);
          const double d1 = spans ? lo[2] + s : std::min(lo[2] + s, end);
          if (d1 - d0 < 1e-3) continue;
          for (int c = 0; c < 3; ++c) {
            double f = 0.0;
            const double at = spans ? lo[2] + s * (1 + 2 * c) / 6.0 : d0 + (d1 - d0) * (1 + 2 * c) / 6.0;
            if (!sample(walls->u0 + i * P, walls->w0 + j * P, at, &f)) continue;
            seen = true;
            *fit = std::min(*fit, f);
          }
        }
    return seen;
  }

  void emit(const double lo[3], double s, bool cut, bool as_cell) {
    Cell cell;
    cell.region = region;
    cell.frame = frame_index;
    cell.lo[0] = lo[0]; cell.lo[1] = lo[1]; cell.lo[2] = lo[2];
    cell.size = s;
    cell.cut = cut;
    cell.wall = wall;
    cell.own = base_mm;
    if (as_cell) {
      cell.band = band_t(lo, s);
      cell.finest = is_finest(s);
      out->cells.push_back(cell);
      ++tally->cells;
    } else {
      // D8, D14: lattice was asked for, and no allowed cell fits the wall here. Solid.
      out->solid.push_back(cell);
      ++tally->solid;
    }
  }

  // A cube of the frame: emit it as a cell, split it, or record it as solid.
  void place(const double lo[3], double s, bool top = true) {
    // 27 points: the centre and a 3 x 3 x 3 grid a third of the cell apart.
    int inside = 0;
    double fits = 1e300;   // the largest cell every counted point's wall allows
    for (int c = 0; c < 3; ++c)
      for (int b = 0; b < 3; ++b)
        for (int a = 0; a < 3; ++a) {
          double fit = 0.0;
          if (!sample(lo[0] + s * (1 + 2 * a) / 6.0, lo[1] + s * (1 + 2 * b) / 6.0,
                      lo[2] + s * (1 + 2 * c) / 6.0, &fit))
            continue;
          ++inside;
          fits = std::min(fits, fit);
        }
    if (inside == 0 && !look_at_nodes(lo, s, &fits)) return;   // nothing of this pass here
    const bool cut = inside < 27;   // D3: a whole cell, cut by the edge
    // A width is read to about a micron (PartMeasure::reach), so a cell that fits its
    // wall exactly must not be refused over the last digits of the reading.
    const bool fitting = s <= fits + kReadingSlack;
    // Too large this close to the outline, or cut by it (G1-G3, G10).
    const bool held = !band_allows(lo, s) || !whole_in_outline(lo, s);
    const bool printable = prints(lo, s);
    if (fitting && !held && printable) {
      emit(lo, s, cut, true);
      return;
    }
    const double h = 0.5 * s;
    // C7. Below the open look's floor a cell is divided for the band alone (G11).
    if (spec->algorithm == Algorithm::DefaultGrade && allowed(h) &&
        (held || h >= out->floor_cell_mm * (1.0 - 1e-9))) {
      for (int c = 0; c < 2; ++c)
        for (int b = 0; b < 2; ++b)
          for (int a = 0; a < 2; ++a) {
            const double q[3] = {lo[0] + a * h, lo[1] + b * h, lo[2] + c * h};
            place(q, h, false);
          }
      return;
    }
    if (spec->algorithm == Algorithm::Stepped && top && pack(lo, s, held)) return;
    // G6: a cell that cannot be divided further stands; nothing goes solid for the band.
    // (Unless it is too small to print: C8, C14.)
    emit(lo, s, cut, fitting && printable);
  }

  // ── STEPPED: pack one base cell from one shared unit (C6-C6c, C13) ────────────
  // The base cell S did not fit. For each fraction n whose unit t = S/n prints open,
  // the base cell is n x n x n units; cells of m units (m = n-1 .. 1), each starting on
  // a whole unit, are placed largest first wherever the wall allows them (C1). Of the
  // fractions, the one that covers the most of the lattice here wins, then the one with
  // the fewest cells (C6c). Returns false when no fraction places anything.
  struct Packed {
    int n = 0;
    long covered = 0, asked = 0;   // sample points with lattice asked: in a cell / in all
    std::vector<std::array<int, 4>> cubes;   // i, j, k, m (in units)
    std::vector<std::array<int, 3>> bare;    // units with lattice asked and no cell
    std::vector<unsigned char> cut;          // per cube
  };
  bool pack(const double lo[3], double S, bool held) {
    Packed best;
    for (int n : divisors) {
      if (n < 2) continue;
      const double t = S / n;
      // Each unit read at 8 points (a 2 x 2 x 2 grid half a unit apart).
      const std::size_t N = static_cast<std::size_t>(n) * n * n;
      std::vector<unsigned char> in(N, 0);
      std::vector<double> fit(N, 1e300);
      for (int k = 0; k < n; ++k)
        for (int j = 0; j < n; ++j)
          for (int i = 0; i < n; ++i) {
            const std::size_t u = (static_cast<std::size_t>(k) * n + j) * n + i;
            for (int c = 0; c < 2; ++c)
              for (int b = 0; b < 2; ++b)
                for (int a = 0; a < 2; ++a) {
                  double f = 0.0;
                  if (!sample(lo[0] + t * (i + 0.25 + 0.5 * a), lo[1] + t * (j + 0.25 + 0.5 * b),
                              lo[2] + t * (k + 0.25 + 0.5 * c), &f))
                    continue;
                  ++in[u];
                  fit[u] = std::min(fit[u], f);
                }
            if (in[u]) continue;
            // None of the eight: look again just inside the unit's corners, so a sliver
            // of lattice at its edge is seen, and is a cut cell or listed as solid (D14)
            // rather than left out of the layout.
            for (int c = 0; c < 2 && !in[u]; ++c)
              for (int b = 0; b < 2 && !in[u]; ++b)
                for (int a = 0; a < 2 && !in[u]; ++a) {
                  double f = 0.0;
                  if (!sample(lo[0] + t * (i + 0.04 + 0.92 * a), lo[1] + t * (j + 0.04 + 0.92 * b),
                              lo[2] + t * (k + 0.04 + 0.92 * c), &f))
                    continue;
                  in[u] = 1;
                  fit[u] = f;
                }
            const double at[3] = {lo[0] + t * i, lo[1] + t * j, lo[2] + t * k};
            if (!in[u] && look_at_nodes(at, t, &fit[u])) in[u] = 1;
          }
      Packed p;
      p.n = n;
      std::vector<unsigned char> taken(N, 0);
      std::vector<std::pair<double, std::array<int, 3>>> spots;
      for (int m = n - 1; m >= 1; --m) {
        const double size = m * t;
        spots.clear();
        for (int k = 0; k + m <= n; ++k)
          for (int j = 0; j + m <= n; ++j)
            for (int i = 0; i + m <= n; ++i) {
              double deep = 0.0;
              if (band_region)
                deep = edge_distance(lo[0] + (i + 0.5 * m) * t, lo[1] + (j + 0.5 * m) * t,
                                     lo[2] + (k + 0.5 * m) * t);
              spots.push_back({std::round(deep * 1e6) / 1e6, {i, j, k}});
            }
        // In a band the larger cells take the places farthest from the outline, so the
        // smaller ones are left toward it (G1). Elsewhere, the order they are read in.
        if (band_region)
          std::stable_sort(spots.begin(), spots.end(),
                           [](const auto& x, const auto& y) { return x.first > y.first; });
        for (const auto& spot : spots) {
          const int i = spot.second[0], j = spot.second[1], k = spot.second[2];
          bool free = true;
          int some = 0, all = 0;
          double f = 1e300;
          for (int c = k; c < k + m && free; ++c)
            for (int b = j; b < j + m && free; ++b)
              for (int a = i; a < i + m; ++a) {
                const std::size_t u = (static_cast<std::size_t>(c) * n + b) * n + a;
                if (taken[u]) { free = false; break; }
                some += in[u];
                all += 8;
                f = std::min(f, fit[u]);
              }
          if (!free || some == 0 || size > f + kReadingSlack) continue;
          const double at[3] = {lo[0] + i * t, lo[1] + j * t, lo[2] + k * t};
          if (!band_allows(at, size) || !whole_in_outline(at, size) || !fine_allowed(at, size))
            continue;
          for (int c = k; c < k + m; ++c)
            for (int b = j; b < j + m; ++b)
              for (int a = i; a < i + m; ++a)
                taken[(static_cast<std::size_t>(c) * n + b) * n + a] = 1;
          p.covered += some;
          p.cubes.push_back({i, j, k, m});
          p.cut.push_back(some < all);
        }
      }
      for (int k = 0; k < n; ++k)
        for (int j = 0; j < n; ++j)
          for (int i = 0; i < n; ++i) {
            const std::size_t u = (static_cast<std::size_t>(k) * n + j) * n + i;
            p.asked += in[u];
            if (in[u] && !taken[u]) p.bare.push_back({i, j, k});
          }
      if (p.cubes.empty()) continue;
      // Most covered, then fewest cells, then the coarser unit (the smaller n).
      // C1 before C6c: "largest cells, fewest cells ... the smallest only where no
      // larger cell fits". A finer unit always hugs an edge a little closer, and would
      // win every time on coverage alone; so coverage within a tenth counts as the same,
      // and the fewer, larger cells are kept. What the larger cells leave at the edge is
      // a sliver, which is solid (C8).
      // Coverage is the share of the lattice asked for here that ends up in a cell.
      const long mine = p.covered * best.asked, theirs = best.covered * p.asked;
      // Inside a Grade to shape band the finest cells are wanted at the outline, so there
      // coverage is compared exactly (G3, G6).
      const bool more = held ? mine > theirs : mine * 100 > theirs * 110;
      const bool same = !more && (held ? mine == theirs : mine * 110 >= theirs * 100);
      if (best.n == 0 || more || (same && p.cubes.size() < best.cubes.size()))
        best = std::move(p);
    }
    if (best.n == 0) return false;
    const double t = S / best.n;
    for (std::size_t q = 0; q < best.cubes.size(); ++q) {
      const auto& c = best.cubes[q];
      const double at[3] = {lo[0] + c[0] * t, lo[1] + c[1] * t, lo[2] + c[2] * t};
      emit(at, c[3] * t, best.cut[q] != 0, true);
    }
    for (const auto& u : best.bare) {
      const double at[3] = {lo[0] + u[0] * t, lo[1] + u[1] * t, lo[2] + u[2] * t};
      emit(at, t, true, false);
    }
    return true;
  }
};

// Slots along one axis covering [lo, hi] with cells of `s`, the leftover shared equally
// between the two ends (C9: a symmetric extent gets a symmetric layout).
void centred(double lo, double hi, double s, double* start, int* count) {
  const double ext = hi - lo;
  *count = std::max(1, static_cast<int>(std::ceil(ext / s - 1e-9)));
  *start = 0.5 * (lo + hi) - 0.5 * *count * s;
}


// What is read under one flat region's face and kept with the domain: it depends on the
// part, the region and the Protect skins, never on a cell size, so every layout of the
// same domain (a cell-size or band slider being dragged) reuses it.
struct FaceReadings {
  WallMap map;   // nodes and their stretches (bin, sbin); `wall` and `walls` left empty
  struct Stretch {
    std::vector<std::size_t> entries;   // its (node, stretch) places in the map
    double start = 0.0, width = 0.0;    // exact, read at its first node
    double lo[2] = {0, 0}, hi[2] = {0, 0};   // its extent on the face: the nodes' own ...
    bool edged = false;                 // ... or, once set, its true edges, searched for
  };
  // The true edges are searched for the first time a layout needs them (a stretch that
  // could be a wall at that layout's cell size), then kept like the rest.
  mutable std::vector<Stretch> stretches;
  mutable std::mutex edging;
};

// The lattice's columns under a flat region's face at (u, w): where each starts below the
// face and how wide it is. Read just under the face, or just behind a Protect skin on it
// (D5); then, through a pocket, just inside the next material; and so on down to the
// region's depth. Returns how many (at most kDeep).
int face_columns(const Domain::Probe& pr, const Region& r, const Frame& f, double u, double w,
                 double* start, double* width) {
  const double depth = r.prism.depth, under = std::min(0.02, 0.25 * depth);
  const int deep = WallMap::kDeep;
  int n = 0;
  double z = under;
  for (int hop = 0; hop < 4 * deep && n < deep && z < depth; ++hop) {
    double wall = 0.0;
    Domain::Probe::Room room;
    const Vec3 at = f.at(u, w, z);
    const Where h = pr.where(at, &wall, &room);
    if (h.lattice() && h.id == r.id) {
      column_of(room, z, depth, &start[n], &width[n]);
      z = start[n] + width[n] + under;
      ++n;
    } else if (h.why == Why::ProtectSkin || h.why == Why::Cover) {
      // Straight in through the skin, by its own gap: such a step cannot pass its inner side.
      for (int it = 0; it < 200 && z < depth; ++it) {
        const double gap = pr.skin_gap(f.at(u, w, z));
        if (gap > 0.0) break;
        z += std::max(-gap, 1e-3);
      }
      z += under;
    } else if (h.why == Why::Outside) {
      // Air (a pocket, or a step down beside the face): straight on to the next surface.
      const double t = pr.part().reach_by_line(at, f.ax[2]);
      if (t < 0.0) break;
      z += t + under;
    } else {
      break;   // kept clear, another region's, too thin: nothing of this region's below
    }
  }
  return n;
}

// Of the columns at (u, w), the one that is the stretch of these bins.
bool face_column_of(const Domain::Probe& pr, const Region& r, const Frame& f, long want,
                    long want_start, double u, double w, double* start_out, double* width_out) {
  double start[WallMap::kDeep], width[WallMap::kDeep];
  const int n = face_columns(pr, r, f, u, w, start, width);
  for (int k = 0; k < n; ++k)
    if (std::labs(WallMap::bin_of(width[k]) - want) <= 1 &&
        std::labs(WallMap::bin_of(start[k]) - want_start) <= 1) {
      if (start_out) *start_out = start[k];
      if (width_out) *width_out = width[k];
      return true;
    }
  return false;
}

std::shared_ptr<const FaceReadings> read_face(const Domain& domain, const Region& r,
                                              const Frame& f, const double lo[3],
                                              const double hi[3], int thread_count) {
  const ClearanceGeometry& g = r.prism;
  const Domain::Probe probe = domain.probe();
  auto made = std::make_shared<FaceReadings>();
  FaceReadings& out = *made;
  WallMap& map = out.map;
  map.flat = true;
  map.depth = g.depth;
  map.u0 = lo[0]; map.w0 = lo[1];
  map.nu = static_cast<int>(std::ceil((hi[0] - lo[0]) / WallMap::kPitch)) + 1;
  map.nw = static_cast<int>(std::ceil((hi[1] - lo[1]) / WallMap::kPitch)) + 1;
  const int deep = WallMap::kDeep;
  map.bin.assign(static_cast<std::size_t>(map.nu) * map.nw * deep, -1);
  map.sbin.assign(map.bin.size(), 0);
  map.wall.assign(map.bin.size(), -1);
  auto node_u = [&](std::size_t e) { return map.u0 + ((e / deep) % map.nu) * WallMap::kPitch; };
  auto node_w = [&](std::size_t e) { return map.w0 + ((e / deep) / map.nu) * WallMap::kPitch; };
  // Each row of nodes on its own: shared between threads, the result the same for any number.
  {
    std::atomic<int> next{0};
    auto rows = [&](const Domain::Probe& pr) {
      for (int j = next.fetch_add(1); j < map.nw; j = next.fetch_add(1))
        for (int i = 0; i < map.nu; ++i) {
          double start[WallMap::kDeep], width[WallMap::kDeep];
          const int n = face_columns(pr, r, f, map.u0 + i * WallMap::kPitch,
                                     map.w0 + j * WallMap::kPitch, start, width);
          for (int k = 0; k < n; ++k) {
            const std::size_t e = (static_cast<std::size_t>(j) * map.nu + i) * deep + k;
            map.bin[e] = WallMap::bin_of(width[k]);
            map.sbin[e] = WallMap::bin_of(start[k]);
          }
        }
    };
    std::vector<std::thread> pool;
    for (int t = 1; t < std::min(thread_count, map.nw); ++t)
      pool.emplace_back([&]() { rows(domain.probe()); });
    rows(probe);
    for (std::thread& t : pool) t.join();
  }
  std::vector<int> mark(map.bin.size(), 0);
  std::vector<std::size_t> stack;
  for (std::size_t n0 = 0; n0 < map.bin.size(); ++n0) {
    if (map.bin[n0] < 0 || mark[n0]) continue;
    // One stretch: neighbours that start at the same depth and are the same width.
    FaceReadings::Stretch st;
    stack.assign(1, n0);
    mark[n0] = 1;
    while (!stack.empty()) {
      const std::size_t n = stack.back();
      stack.pop_back();
      st.entries.push_back(n);
      const int i = static_cast<int>((n / deep) % map.nu), j = static_cast<int>((n / deep) / map.nu);
      const int nb[4][2] = {{i - 1, j}, {i + 1, j}, {i, j - 1}, {i, j + 1}};
      for (const auto& q : nb) {
        if (q[0] < 0 || q[1] < 0 || q[0] >= map.nu || q[1] >= map.nw) continue;
        for (int k = 0; k < deep; ++k) {
          const std::size_t m = (static_cast<std::size_t>(q[1]) * map.nu + q[0]) * deep + k;
          if (mark[m] || map.bin[m] != map.bin[n0] || map.sbin[m] != map.sbin[n0]) continue;
          mark[m] = 1;
          stack.push_back(m);
        }
      }
    }
    // The exact width, not the bin's: read it again at the stretch's first node ...
    {
      double start = 0.0, width = 0.0;
      face_column_of(probe, r, f, map.bin[n0], map.sbin[n0], node_u(n0), node_w(n0), &start, &width);
      // ... to the precision it is read at: a 12 mm wall is 12, not 11.9999995.
      st.start = std::round(start * 1e5) / 1e5;
      st.width = std::round((start + width) * 1e5) / 1e5 - st.start;
    }
    st.lo[0] = st.lo[1] = 1e300;
    st.hi[0] = st.hi[1] = -1e300;
    for (std::size_t n : st.entries) {
      const double u = node_u(n), w = node_w(n);
      st.lo[0] = std::min(st.lo[0], u); st.hi[0] = std::max(st.hi[0], u);
      st.lo[1] = std::min(st.lo[1], w); st.hi[1] = std::max(st.hi[1], w);
    }
    out.stretches.push_back(std::move(st));
  }
  return made;
}

// The map's nodes stop short of a stretch's true edge by up to one step. Find the edge
// itself, outward from the outermost nodes, so the cells are centred on the real stretch
// (and a symmetric one gets a symmetric layout, exactly). Once per stretch, then kept.
void find_edges(const FaceReadings& kept, std::size_t which, const Domain& domain,
                const Domain::Probe& probe, std::vector<std::unique_ptr<Domain::Probe>>& spare,
                const Region& r, const Frame& f) {
  std::lock_guard<std::mutex> lock(kept.edging);
  FaceReadings::Stretch& st = kept.stretches[which];
  if (st.edged) return;
  const WallMap& map = kept.map;
  const int deep = WallMap::kDeep;
  const long want = map.bin[st.entries.front()], want_start = map.sbin[st.entries.front()];
  // Each outermost node, each way it is outermost: one search, on its own. Shared between
  // threads; the edge is the farthest any of them found, the same for any number.
  struct Search { double at[2]; int axis, side; double found = 0.0; };
  std::vector<Search> searches;
  for (std::size_t n : st.entries) {
    const double at[2] = {map.u0 + ((n / deep) % map.nu) * WallMap::kPitch,
                          map.w0 + ((n / deep) / map.nu) * WallMap::kPitch};
    for (int axis = 0; axis < 2; ++axis)
      for (int side = 0; side < 2; ++side) {
        const double extreme = side ? st.hi[axis] : st.lo[axis];
        if (std::fabs(at[axis] - extreme) > 1e-9) continue;
        searches.push_back({{at[0], at[1]}, axis, side});
      }
  }
  std::atomic<std::size_t> next{0};
  auto work = [&](int who) {
    if (who > 0 && !spare[static_cast<std::size_t>(who)])
      spare[static_cast<std::size_t>(who)] = std::make_unique<Domain::Probe>(domain.probe());
    const Domain::Probe& mine = who > 0 ? *spare[static_cast<std::size_t>(who)] : probe;
    for (std::size_t i = next.fetch_add(1); i < searches.size(); i = next.fetch_add(1)) {
      Search& q = searches[i];
      double in = q.at[q.axis], outside = q.at[q.axis] + (q.side ? WallMap::kPitch : -WallMap::kPitch);
      for (int it = 0; it < 50; ++it) {
        const double m = 0.5 * (in + outside);
        const bool yes = q.axis == 0 ? face_column_of(mine, r, f, want, want_start, m, q.at[1], nullptr, nullptr)
                                     : face_column_of(mine, r, f, want, want_start, q.at[0], m, nullptr, nullptr);
        if (yes) in = m; else outside = m;
      }
      q.found = std::round(0.5 * (in + outside) * 1e7) / 1e7;
    }
  };
  {
    const int nt = static_cast<int>(std::min<std::size_t>(spare.size(), std::max<std::size_t>(1, searches.size() / 4)));
    std::vector<std::thread> pool;
    for (int t = 1; t < nt; ++t) pool.emplace_back(work, t);
    work(0);
    for (std::thread& t : pool) t.join();
  }
  double edge[2][2] = {{st.lo[0], st.hi[0]}, {st.lo[1], st.hi[1]}};
  for (const Search& q : searches)
    edge[q.axis][q.side] = q.side ? std::max(edge[q.axis][q.side], q.found) : std::min(edge[q.axis][q.side], q.found);
  st.lo[0] = edge[0][0]; st.hi[0] = edge[0][1];
  st.lo[1] = edge[1][0]; st.hi[1] = edge[1][1];
  st.edged = true;
}

}  // namespace

Layout lay_cells(const Domain& domain, const CellSpec& spec, int threads) {
  Layout out;
  const int thread_count =
      threads > 0 ? threads : std::max(1, static_cast<int>(std::thread::hardware_concurrency()));
  const DomainSpec& ds = domain.spec();
  // R5, C14: the thinnest strut is a number of line widths (two), and the smallest cell is
  // the one that strut leaves open. Core's own open-look rule is asked with that strut.
  const double min_strut = std::max(1.0, ds.min_strut_lines) * ds.bead_mm;
  // Each type's own open look and quilt (throws, naming the type, for one with no cell).
  const LatticeWidthBounds bounds = lattice_width_bounds(spec.topology);
  out.open_look = bounds.open_look;
  out.touch = bounds.touch;
  // C14, R2: the smallest cell is the one the thinnest strut leaves open; with Allow quilt
  // on, the one it draws without closing (the quilt's cell), on any wall that needs it.
  out.floor_cell_mm = min_strut / (spec.allow_quilt ? bounds.touch : bounds.open_look);
  out.bead_mm = ds.bead_mm;
  out.min_strut_mm = min_strut;
  out.topology = spec.topology;
  // A hair above the bound itself, so the floor cell is a size core's own menu admits.
  const double smallest = std::max(out.floor_cell_mm * (1.0 + 1e-9), spec.cell_min_mm);
  const double target = spec.cell_mm > 0.0 ? spec.cell_mm : spec.cell_max_mm;
  const Domain::Probe probe = domain.probe();
  // A probe serves one thread; each worker makes its own once and keeps it for every lay.
  std::vector<std::unique_ptr<Domain::Probe>> spare(static_cast<std::size_t>(thread_count));
  const PartMeasure& part = domain.measure();
  const int k_min = std::max(1, spec.min_cells_across);

  // Lay one pass over the box [lo, hi] of its frame, in slots of `base`.
  auto lay = [&](Pass& pass, double base, const double lo[3], const double hi[3],
                 bool depth_from_zero) {
    // G11: a band is a size gradient down to the smallest cell allowed (the floor above).
    // A typed smallest cell for the band (Manual) is held at that floor.
    const double band_floor = pass.band_region != nullptr && spec.band_cell_mm > 0.0
        ? std::max(spec.band_cell_mm, out.floor_cell_mm) : out.floor_cell_mm;
    // Core's own menus check the open look; with Allow quilt the floor here stands in for it.
    const bool fine = spec.allow_quilt;
    const double tile_min = std::max(spec.cell_min_mm, band_floor);
    if (spec.algorithm == Algorithm::DefaultGrade)
      // The halving ladder and its printable floor are core's own (ruling A, C7, C14).
      pass.sizes = stepped_size_menu(spec.topology, base, min_strut, tile_min, !fine,
                                     SteppedMenu::Halves);
    else
      pass.sizes = {base};
    pass.divisors.clear();
    if (spec.algorithm == Algorithm::Stepped)
      // Which fractions' units print open is core's own rule (C6a).
      pass.divisors = stepped_admitted_divisors(spec.topology, base, min_strut, tile_min,
                                                !fine, SteppedMenu::AnyStep);
    pass.base_mm = base;
    pass.skin_most = domain.skin_most_mm();
    pass.floor_mm = std::max(spec.cell_min_mm, out.floor_cell_mm);
    pass.finest_mm = base;
    for (double a : pass.sizes) pass.finest_mm = std::min(pass.finest_mm, a);
    for (int n : pass.divisors)
      if (n >= 2) pass.finest_mm = std::min(pass.finest_mm, base / n);
    double start[3];
    int count[3];
    for (int a = 0; a < 3; ++a) centred(lo[a], hi[a], base, &start[a], &count[a]);
    if (depth_from_zero) {   // C15: the face is a cell boundary
      start[2] = lo[2];
      count[2] = std::max(1, static_cast<int>(std::llround((hi[2] - lo[2]) / base)));
    }
    // Each base cell is laid on its own, so they are shared between threads and put
    // back in the order one thread would have laid them: the layout is the same for any
    // number of threads (D18). A probe serves one thread, so each takes its own.
    const std::size_t total = static_cast<std::size_t>(count[0]) * count[1] * count[2];
    auto slot = [&](std::size_t i, double q[3]) {
      const std::size_t a = i % count[0], b = (i / count[0]) % count[1], c = i / (static_cast<std::size_t>(count[0]) * count[1]);
      q[0] = start[0] + a * base; q[1] = start[1] + b * base; q[2] = start[2] + c * base;
    };
    const int nt = static_cast<int>(std::min<std::size_t>(static_cast<std::size_t>(thread_count), total));
    if (nt <= 1) {
      for (std::size_t i = 0; i < total; ++i) {
        double q[3];
        slot(i, q);
        pass.columns.clear();
        pass.place(q, base);
      }
      return;
    }
    struct Piece { std::vector<Cell> cells, solid; };
    std::vector<Piece> pieces(total);
    std::atomic<std::size_t> next{0};
    auto work = [&](int who) {
      if (who > 0 && !spare[static_cast<std::size_t>(who)])
        spare[static_cast<std::size_t>(who)] = std::make_unique<Domain::Probe>(domain.probe());
      const Domain::Probe& mine = who > 0 ? *spare[static_cast<std::size_t>(who)] : probe;
      Layout local;
      local.floor_cell_mm = out.floor_cell_mm;
      RegionCells count_here;
      Pass p = pass;
      p.probe = &mine;
      p.out = &local;
      p.tally = &count_here;
      for (std::size_t i = next.fetch_add(1); i < total; i = next.fetch_add(1)) {
        double q[3];
        slot(i, q);
        p.columns.clear();
        p.place(q, base);
        pieces[i].cells.swap(local.cells);
        pieces[i].solid.swap(local.solid);
        local.cells.clear();
        local.solid.clear();
      }
    };
    std::vector<std::thread> pool;
    for (int t = 1; t < nt; ++t) pool.emplace_back(work, t);
    work(0);
    for (std::thread& t : pool) t.join();
    for (const Piece& piece : pieces) {
      out.cells.insert(out.cells.end(), piece.cells.begin(), piece.cells.end());
      out.solid.insert(out.solid.end(), piece.solid.begin(), piece.solid.end());
      pass.tally->cells += piece.cells.size();
      pass.tally->solid += piece.solid.size();
    }
  };
  // A region's frame and its tally; returns the pass to lay with.
  auto open = [&](int region, const Frame& frame, double depth_cap, double base) {
    Pass pass;
    pass.probe = &probe;
    pass.spec = &spec;
    pass.region = region;
    pass.frame_index = static_cast<int>(out.frames.size());
    pass.frame = frame;
    pass.out = &out;
    out.frames.push_back(frame);
    out.walls.emplace_back();
    out.walls.back().depth = depth_cap;
    RegionCells tally;
    tally.region = region;
    tally.frame = pass.frame_index;
    tally.base_cell_mm = base;
    out.regions.push_back(tally);
    return pass;
  };
  auto run = [&](int region, const Frame& frame, double depth_cap, double base,
                 const double lo[3], const double hi[3], bool depth_from_zero) {
    Pass pass = open(region, frame, depth_cap, base);
    pass.tally = &out.regions.back();
    const WallMap none = out.walls.back();   // not a flat region: no walls
    pass.walls = &none;
    lay(pass, base, lo, hi, depth_from_zero);
  };
  // C15, C2, C3-C5, C1: the cell that divides a wall of `width` exactly, never wider than
  // it, holding at least the cells it must, otherwise as few and as large as allowed.
  auto divide = [&](double width, int* layers) {
    *layers = std::max(k_min, static_cast<int>(std::ceil(width / target - 1e-9)));
    return width / *layers;
  };

  // The part's own frame, centred on it (C9). Used by the whole part and by curved regions.
  Frame world;
  world.origin = Vec3{0.5 * (part.lo().x + part.hi().x), 0.5 * (part.lo().y + part.hi().y),
                      0.5 * (part.lo().z + part.hi().z)};
  const double wlo[3] = {part.lo().x - world.origin.x, part.lo().y - world.origin.y,
                         part.lo().z - world.origin.z};
  const double whi[3] = {-wlo[0], -wlo[1], -wlo[2]};
  // The base cell where no wall names it. Auto under Default Grade: the largest size
  // not above the target whose halves land exactly on the smallest cell, so the ladder
  // reaches the floor instead of stopping a fraction above it (C17).
  auto world_base = [&]() {
    if (spec.algorithm != Algorithm::DefaultGrade || spec.cell_mm > 0.0) return target;
    double s = smallest;
    while (s * 2.0 <= target * (1.0 + 1e-9)) s *= 2.0;
    return s;
  };

  // Regions are already in id order (D13), the whole part last.
  for (const Region& r : ds.regions) {
    if (r.role != Role::Lattice) continue;
    if (r.is_shell()) {
      run(r.id, world, r.shell_depth_mm, world_base(), wlo, whi, false);
      continue;
    }
    const ClearanceGeometry& g = r.prism;
    if (!g.valid || g.kind != ClearanceKind::Face) continue;
    int k = 0;
    const double base = divide(g.depth, &k);
    Frame f;
    f.origin = g.origin;
    f.ax[0] = g.u; f.ax[1] = g.w; f.ax[2] = g.normal;
    const double e = std::max(0.0, r.expand_mm);
    const double lo[3] = {g.u_lo - e, g.w_lo - e, 0.0};
    const double hi[3] = {g.u_hi + e, g.w_hi + e, g.depth};

    // The walls under this face, from the readings kept with the domain: every stretch of
    // material under each node of a coarse map of the face (a wall, a pocket and the wall
    // behind the pocket are two), gathered where they start at one depth and are one width.
    const std::shared_ptr<const FaceReadings> kept = domain.kept<FaceReadings>(
        r.id, [&]() { return read_face(domain, r, f, lo, hi, thread_count); });
    WallMap map = kept->map;
    for (std::size_t which = 0; which < kept->stretches.size(); ++which) {
      WallMap::Wall wall;
      double area = 0.0;
      {
        std::lock_guard<std::mutex> lock(kept->edging);
        const FaceReadings::Stretch& st = kept->stretches[which];
        wall.start = st.start;
        wall.width = st.width;
        area = st.entries.size() * WallMap::kPitch * WallMap::kPitch;
      }
      wall.cell = divide(wall.width, &wall.layers);
      // A wall is a stretch wide enough for its own cells (two by two of them) whose
      // cell prints. Anything else is left to the pass below, cell by cell.
      if (wall.cell < smallest || area < 4.0 * wall.cell * wall.cell) continue;
      find_edges(*kept, which, domain, probe, spare, r, f);
      const FaceReadings::Stretch& st = kept->stretches[which];   // edged: no longer written
      wall.lo[0] = st.lo[0]; wall.lo[1] = st.lo[1];
      wall.hi[0] = st.hi[0]; wall.hi[1] = st.hi[1];
      // Its true extent must hold one of its cells each way as well: a ledge a tenth of
      // a millimetre wide catches a whole row of map nodes and is not a wall. (One, not
      // two: a rib one cell wide along the face is still a wall of its own depth.)
      if (wall.hi[0] - wall.lo[0] < wall.cell - kReadingSlack ||
          wall.hi[1] - wall.lo[1] < wall.cell - kReadingSlack)
        continue;
      for (std::size_t e : st.entries) map.wall[e] = static_cast<int>(map.walls.size());
      map.walls.push_back(wall);
    }

    Pass pass = open(r.id, f, g.depth, base);
    pass.tally = &out.regions.back();
    pass.walls = &map;
    if (spec.grade_to_shape && spec.band_mm > 0.0) pass.band_region = &r;
    for (std::size_t i = 0; i < map.walls.size(); ++i) {
      const WallMap::Wall& wall = map.walls[i];
      pass.wall = static_cast<int>(i);
      // Centred on the wall's own stretch (C9, per wall).
      const double wlo3[3] = {wall.lo[0], wall.lo[1], wall.start};
      const double whi3[3] = {wall.hi[0], wall.hi[1], wall.start + wall.width};
      lay(pass, wall.cell, wlo3, whi3, true);
    }
    pass.wall = -1;   // what no wall holds: cell by cell from the region's own base
    lay(pass, base, lo, hi, true);
    out.walls[static_cast<std::size_t>(pass.frame_index)] = std::move(map);
  }
  if (ds.start == Start::AllLattice) run(0, world, 1e300, world_base(), wlo, whi, false);
  return out;
}

}  // namespace topopt::lattice_layout
