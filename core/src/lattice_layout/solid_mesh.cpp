// Lattice rebuild, stage F: the printable mesh made from the layout. See lattice_layout_mesh.hpp.
#include "topopt/lattice_layout_mesh.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <mutex>
#include <thread>
#include <unordered_map>

#include "topopt/lattice.hpp"
#include "topopt/tpms_gen.hpp"

#ifdef TOPOPT_HAVE_MANIFOLD
#include "manifold/manifold.h"
#endif

namespace topopt::lattice_layout {
namespace {

double ms_since(std::chrono::steady_clock::time_point t0) {
  return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
}
bool asked(const std::atomic<bool>* stop) { return stop && stop->load(std::memory_order_relaxed); }
void check(const std::atomic<bool>* stop) { if (asked(stop)) throw LayCancelled{}; }
int thread_count(int threads) {
  return threads > 0 ? threads : std::max(1, static_cast<int>(std::thread::hardware_concurrency()));
}
// A place, to a twentieth of a micron: bars that meet at a node share it exactly.
std::uint64_t place_key(const Vec3& p) {
  const std::uint64_t a = static_cast<std::uint64_t>(std::llround(p.x * 20000) + (1LL << 30)),
                      b = static_cast<std::uint64_t>(std::llround(p.y * 20000) + (1LL << 30)),
                      c = static_cast<std::uint64_t>(std::llround(p.z * 20000) + (1LL << 30));
  return (a * 0x9E3779B97F4A7C15ULL) ^ (b * 0xC2B2AE3D27D4EB4FULL) ^ (c * 0x165667B19E3779F9ULL);
}

// One cube's open space, as boxes in its frame. `holds(p)` is whether the cube's own lattice is at `p` (a point of the
// cube); `holds_near(a, b, c)` the same at a point of its frame just past the cube, asked only when `near_too` is set
// (for a cell: what cell_holds asks, less the cube). A cell's cube, or a cube of a weave region's open space (O1).
template <class Holds, class HoldsNear>
void open_boxes_with(const Layout& lay, const Domain::Probe& probe, const Cell& c, double pitch, bool merge, bool keep_edge,
                     std::vector<OpenSpace::Box>& mine, Holds holds, HoldsNear holds_near, bool near_too) {
  const Frame& f = lay.frames[static_cast<std::size_t>(c.frame)];
  const WallMap& walls = lay.walls[static_cast<std::size_t>(c.frame)];
  const int k = std::max(1, static_cast<int>(std::ceil(c.size / pitch - 1e-9)));
  const double s = c.size / k;
  auto at = [&](int i, int j) { return static_cast<std::size_t>(j) * k + i; };
  // The cube's own points (0 .. k-1 each way) and one more all round it (-1 and k). A
  // point outside the cube is never opened; it is only asked what stands there.
  //   kSpace: open space of this cell (a point it holds, or one inside an open column's
  //           stretch); outside the cube: lattice the cell would hold were its cube larger;
  //   kBox:   written as a box from the points themselves (a point read as held, or a
  //           point of air opened beside the space);
  //   kAsked: a point outside the cube that has been read;
  //   kOpen:  open already and not the cell's space (air an open column took with it):
  //           nothing opens for touching it.
  enum : unsigned char { kSpace = 1, kBox = 2, kAsked = 4, kOpen = 8 };
  const int n = k + 2;
  std::vector<unsigned char> pts(static_cast<std::size_t>(n) * n * n, 0);
  auto pt = [&](int i, int j, int z) -> unsigned char& {
    return pts[(static_cast<std::size_t>(z + 1) * n + static_cast<std::size_t>(j + 1)) * n + static_cast<std::size_t>(i + 1)];
  };
  auto place = [&](int i, int j, int z) {
    return f.at(c.lo[0] + (i + 0.5) * s, c.lo[1] + (j + 0.5) * s, c.lo[2] + (z + 0.5) * s);
  };
  // NEVER PAST AN EDGE AGAINST SOLID (reviewer, 2026-11-14). A point or a column is opened when its middle is held,
  // so its footprint can reach up to half a point past the lattice's true edge. Against air that is wanted (no crust
  // at an open surface). Against SOLID it opened a slit under his v3 stand's caps, the full thickness of the wall,
  // and thinned Protect skins by up to 0.11 mm. So where opened space ends, a point (or a column) one of whose
  // footprint's corners, or a half step along the column, reads solid (inside the part and lattice of no region) is
  // not opened: against solid the file keeps up to one point more solid than the true edge, never less. A corner
  // that reads air or lattice of any region changes nothing.
  const double inset = 0.5 * s - std::min(0.01, 0.1 * s);   // a hair inside the footprint, off its own edge
  auto solid_at = [&](double a, double b, double z) {
    const Why w = probe.where(f.at(a, b, z)).why;
    return w != Why::Lattice && w != Why::Outside;
  };
  auto corner_solid = [&](double a, double b, double z, bool along) {
    for (int q = 0; q < 4; ++q)
      if (solid_at(a + ((q & 1) ? inset : -inset), b + ((q & 2) ? inset : -inset), z)) return true;
    return along && (solid_at(a, b, z - inset) || solid_at(a, b, z + inset));
  };
  // A neighbour past the cube's face counts as not opened only where it is solid (what stands there otherwise is
  // another cell's lattice, or air).
  auto beyond_solid = [&](int i, int j, double z) {
    return solid_at(c.lo[0] + (i + 0.5) * s, c.lo[1] + (j + 0.5) * s, z);
  };
  // The points read point by point that the cell holds, at the edge of what is opened, against solid: not opened.
  auto keep_solid_points = [&] {
    if (!keep_edge) return;
    const std::vector<unsigned char> was = pts;   // edges read on the points as they were, for any order
    auto was_at = [&](int i, int j, int z) {
      return was[(static_cast<std::size_t>(z + 1) * n + static_cast<std::size_t>(j + 1)) * n + static_cast<std::size_t>(i + 1)];
    };
    for (int z = 0; z < k; ++z)
      for (int j = 0; j < k; ++j)
        for (int i = 0; i < k; ++i) {
          unsigned char& p = pt(i, j, z);
          if (!(p & kSpace) || !(p & kBox)) continue;
          const double a = c.lo[0] + (i + 0.5) * s, b = c.lo[1] + (j + 0.5) * s, cz = c.lo[2] + (z + 0.5) * s;
          bool edge = false;
          const int d6[6][3] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}};
          for (int q = 0; q < 6 && !edge; ++q) {
            const int u = i + d6[q][0], v = j + d6[q][1], w = z + d6[q][2];
            if (u >= 0 && v >= 0 && w >= 0 && u < k && v < k && w < k) {
              edge = !(was_at(u, v, w) & (kSpace | kOpen));
            } else {
              edge = solid_at(c.lo[0] + (u + 0.5) * s, c.lo[1] + (v + 0.5) * s, c.lo[2] + (w + 0.5) * s);
            }
          }
          if (edge && corner_solid(a, b, cz, true)) p = 0;
        }
  };
  // A column read point by point: every point the cell holds is open.
  auto by_points = [&](int i, int j) {
    for (int z = 0; z < k; ++z)
      if (holds(place(i, j, z))) pt(i, j, z) = kSpace | kBox;
  };
  // NO CRUST (his major flaw, 2026-11-12). The points stop at their own grid, the part's
  // surface does not: a point whose middle is in the AIR while its cube pokes into the
  // part is not held, and next to open space it was left standing as a film of the part's
  // own surface over the lattice (slats, where a curved wall crosses the grid). So a point
  // of air in the cube that touches the cell's space, by a face, an edge or a corner, opens
  // with it. Against a surface at any angle that is every cube that pokes in: the point
  // one step inward on each axis lies deeper in the part than the poking one lies out of
  // it. It also carries a run of held points one point past the surface it ends on.
  // The space it touches may lie past the cube's face (the next cell's, read as this
  // cell's own lattice but for the cube): the film is this cell's all the same.
  // Only AIR opens (the question `where` answers Why::Outside by). A point inside the part
  // that this cell does not hold (a Protect skin, a No lattice region, lattice no cell
  // holds, another cell's) is never opened here, whatever it touches.
  // Nothing opens outside the cube: what stands past its face is another cell's to open,
  // or lattice no cell holds, which is solid (D14). A cube face lying in the part's
  // surface is passed by the boxes' own overlap alone, as it always was.
  auto open_air = [&] {
    if (!near_too) return;
    // Nothing of the part's surface near the cube: no air to open, nothing to ask.
    const double reach = 1.001 * std::sqrt(3.0) * (0.5 * c.size + s);
    const double h = 0.5 * c.size;
    if (probe.part().depth_up_to(f.at(c.lo[0] + h, c.lo[1] + h, c.lo[2] + h), reach) >= reach * (1.0 - 1e-9)) return;
    for (int z = 0; z < k; ++z)
      for (int j = 0; j < k; ++j)
        for (int i = 0; i < k; ++i) {
          if (pt(i, j, z) & (kSpace | kOpen)) continue;
          bool touches = false;
          for (int dz = -1; dz <= 1 && !touches; ++dz)
            for (int dj = -1; dj <= 1 && !touches; ++dj)
              for (int di = -1; di <= 1 && !touches; ++di) {
                const int u = i + di, v = j + dj, w = z + dz;
                unsigned char& o = pt(u, v, w);
                if (u >= 0 && v >= 0 && w >= 0 && u < k && v < k && w < k) { touches = o & kSpace; continue; }
                if (!(o & kAsked)) {
                  o |= kAsked;
                  // What cell_holds asks, less the cube.
                  if (holds_near(c.lo[0] + (u + 0.5) * s, c.lo[1] + (v + 0.5) * s, c.lo[2] + (w + 0.5) * s))
                    o |= kSpace;
                }
                touches = o & kSpace;
              }
          if (touches && !probe.part().inside(place(i, j, z))) pt(i, j, z) |= kBox;
        }
  };
  // Every run of such points down a column is a box; then, as few boxes as hold exactly
  // those points: neighbouring columns of a row whose runs are the same (to the point) are
  // one box, and neighbouring rows whose boxes are the same are one slab. Every edge of a
  // box is c.lo + a whole number of points, read the same way for every box, so the boxes
  // hold the same points as the runs did, and touch where the runs touched.
  auto point_boxes = [&] {
    struct Slab { int i0, i1, z0, z1, j0, j1; };
    std::vector<Slab> open_slabs, done;
    std::vector<unsigned char> used(static_cast<std::size_t>(k) * k, 0);   // (i, z) of this row taken by a box
    for (int j = 0; j <= k; ++j) {
      std::vector<Slab> row;
      if (j < k) {
        std::fill(used.begin(), used.end(), 0);
        auto on = [&](int i, int z) { return (pt(i, j, z) & kBox) != 0; };
        for (int i = 0; i < k; ++i)
          for (int z = 0; z < k;) {
            if (!on(i, z) || used[at(z, i)]) { ++z; continue; }
            int z1 = z;
            while (z1 < k && on(i, z1)) ++z1;
            // The same run in the next column: its ends there, and nothing more.
            auto same = [&](int e) {
              if (used[at(z, e)] || (z > 0 && on(e, z - 1))) return false;
              for (int q = z; q < z1; ++q) if (!on(e, q)) return false;
              return z1 == k || !on(e, z1);
            };
            int e = i + 1;
            while (merge && e < k && same(e)) ++e;
            for (int u = i; u < e; ++u)
              for (int q = z; q < z1; ++q) used[at(q, u)] = 1;
            row.push_back({i, e, z, z1, j, j + 1});
            z = z1;
          }
      }
      std::vector<Slab> keep;
      for (const Slab& r : row) {
        bool grew = false;
        for (Slab& p : open_slabs)
          if (merge && p.j1 == j && p.i0 == r.i0 && p.i1 == r.i1 && p.z0 == r.z0 && p.z1 == r.z1) {
            p.j1 = j + 1;
            keep.push_back(p);
            p.j1 = -1;
            grew = true;
            break;
          }
        if (!grew) keep.push_back(r);
      }
      for (const Slab& p : open_slabs)
        if (p.j1 != -1) done.push_back(p);
      open_slabs = keep;
    }
    for (const Slab& b : done)
      mine.push_back({c.frame, {c.lo[0] + b.i0 * s, c.lo[1] + b.j0 * s, c.lo[2] + b.z0 * s},
                      {c.lo[0] + b.i1 * s, c.lo[1] + b.j1 * s, c.lo[2] + b.z1 * s}});
  };
  if (!walls.flat) {
    // No flat face to read columns from: the cell's own shape point by point.
    for (int j = 0; j < k; ++j)
      for (int i = 0; i < k; ++i) by_points(i, j);
    keep_solid_points();
    open_air();
    point_boxes();
    return;
  }
  // One reading per column: open over the column's own stretch inside the cube.
  // `past0`, `past1`: how far past the part's surface each end of the stretch was opened.
  struct Col { int kind = 0; double c0 = 0, c1 = 0, past0 = 0, past1 = 0; };   // 0 other, 1 open, 2 air, 3 crossed
  std::vector<Col> col(static_cast<std::size_t>(k) * k);
  const double cm = c.lo[2] + 0.5 * c.size;
  for (int j = 0; j < k; ++j)
    for (int i = 0; i < k; ++i) {
      const double a = c.lo[0] + (i + 0.5) * s, b = c.lo[1] + (j + 0.5) * s;
      const Reading r = read_at(probe, f, walls, a, b, cm);
      Col& o = col[at(i, j)];
      if (r.where.why == Why::Outside) { o.kind = 2; continue; }
      if (!r.where.lattice()) continue;
      if (r.where.id != c.region || r.wall != c.wall) {
        // D14b: lattice of ANOTHER region inside this cell's cube may be the cell's all the same (it takes in what
        // no cell of that region holds). Which points are is asked point by point down the column, below.
        if (lay.absorb && r.where.id != c.region) o.kind = 3;
        continue;
      }
      o.c0 = std::max(c.lo[2], r.start);
      o.c1 = std::min(c.lo[2] + c.size, r.start + r.width);
      if (!(o.c1 > o.c0 + 1e-6)) continue;
      // The stretch is the cell's own all the way only if nothing crosses the column
      // sideways (a skin under a face that is not this region's, a keep-solid shell).
      // Checked point by point down the column; where it is not, the column is left to
      // the point-by-point reading below.
      bool whole = true;
      for (int z = 0; z < k && whole; ++z) {
        const double cz = c.lo[2] + (z + 0.5) * s;
        if (cz <= o.c0 || cz >= o.c1) continue;
        whole = holds(f.at(a, b, cz));
      }
      if (!whole) { o.kind = 3; continue; }
      o.kind = 1;
      // Where the stretch ends on the part's own surface, open a little past it: a cut
      // exactly in the surface's plane is asking for a paper-thin leftover.
      if (probe.where(f.at(a, b, o.c0 - 0.05)).why == Why::Outside) { o.c0 -= 0.3; o.past0 = 0.3; }
      if (probe.where(f.at(a, b, o.c1 + 0.05)).why == Why::Outside) { o.c1 += 0.3; o.past1 = 0.3; }
    }
  // The reading above is taken once, at the cube's mid-depth. A column whose mid-depth is
  // not the cell's own lattice (a Protect skin, a pocket's air, other solid) may still hold
  // the cell's lattice above or below that one point, where the skin or the pocket ends
  // part-way down the cell. Where the cell holds any point of such a column, the column is
  // read point by point (below) instead of being left solid as a whole.
  for (int j = 0; j < k; ++j)
    for (int i = 0; i < k; ++i) {
      Col& o = col[at(i, j)];
      if (o.kind != 0 && o.kind != 2) continue;
      for (int z = 0; z < k; ++z)
        if (holds(place(i, j, z))) { o.kind = 3; break; }
    }
  // A column of air beside an open one opens with it, so no film is left along the
  // part's side where the grid stops short of the surface.
  std::vector<Col> grown = col;
  for (int j = 0; j < k; ++j)
    for (int i = 0; i < k; ++i) {
      if (col[at(i, j)].kind != 2) continue;
      const int di[4] = {1, -1, 0, 0}, dj[4] = {0, 0, 1, -1};
      for (int n = 0; n < 4; ++n) {
        const int ii = i + di[n], jj = j + dj[n];
        if (ii < 0 || jj < 0 || ii >= k || jj >= k) continue;
        const Col& o = col[at(ii, jj)];
        if (o.kind == 1) { grown[at(i, j)] = o; break; }
      }
    }
  // A strip of solid one or two columns wide (0.5 mm at most: thinner than a wall of two
  // lines, and often a pillar hanging from above) between open columns is opened with
  // them. It could not print as solid.
  for (int pass = 0; pass < 2; ++pass)
    for (int j = 0; j < k; ++j)
      for (int i = 0; i < k;) {
        auto g = [&](int u, int v) -> Col& { return pass == 0 ? grown[at(u, v)] : grown[at(v, u)]; };
        if (g(i, j).kind == 1) { ++i; continue; }
        int e = i;
        while (e < k && g(e, j).kind != 1) ++e;
        if (i > 0 && e < k && e - i <= 2)
          for (int q = i; q < e; ++q) g(q, j) = g(i - 1, j);
        i = e;
      }
  // An open column (read open, not grown or filled) at the edge of what is opened, with solid at a corner of its
  // footprint anywhere down its stretch, is read point by point instead, and its points are judged one by one.
  if (keep_edge) {
    std::vector<int> to_points;
    for (int j = 0; j < k; ++j)
      for (int i = 0; i < k; ++i) {
        const Col& o = grown[at(i, j)];
        if (o.kind != 1 || col[at(i, j)].kind != 1) continue;
        const double mid = 0.5 * (o.c0 + o.c1);
        bool edge = false;
        const int di[4] = {1, -1, 0, 0}, dj[4] = {0, 0, 1, -1};
        for (int q = 0; q < 4 && !edge; ++q) {
          const int u = i + di[q], v = j + dj[q];
          edge = (u < 0 || v < 0 || u >= k || v >= k) ? beyond_solid(u, v, mid) : grown[at(u, v)].kind != 1;
        }
        if (!edge) continue;
        const double a = c.lo[0] + (i + 0.5) * s, b = c.lo[1] + (j + 0.5) * s;
        for (int z = 0; z < k; ++z) {
          const double cz = c.lo[2] + (z + 0.5) * s;
          if (!(cz > o.c0 && cz < o.c1)) continue;
          if (corner_solid(a, b, cz, false)) { to_points.push_back(static_cast<int>(at(i, j))); break; }
        }
      }
    for (int x : to_points) { grown[static_cast<std::size_t>(x)].kind = 3; col[static_cast<std::size_t>(x)].kind = 3; }
  }
  // Rows of equal columns, then equal rows stacked.
  struct Run { int i0, i1; double c0, c1; int j0, j1; };
  std::vector<Run> open_runs, done;
  for (int j = 0; j <= k; ++j) {
    std::vector<Run> row;
    if (j < k)
      for (int i = 0; i < k;) {
        const Col& o = grown[at(i, j)];
        if (o.kind != 1) { ++i; continue; }
        int e = i + 1;
        while (e < k && grown[at(e, j)].kind == 1 && grown[at(e, j)].c0 == o.c0 && grown[at(e, j)].c1 == o.c1) ++e;
        row.push_back({i, e, o.c0, o.c1, j, j + 1});
        i = e;
      }
    std::vector<Run> keep;
    for (Run& r : row) {
      bool grew = false;
      for (Run& p : open_runs)
        if (p.j1 == j && p.i0 == r.i0 && p.i1 == r.i1 && p.c0 == r.c0 && p.c1 == r.c1) {
          p.j1 = j + 1;
          keep.push_back(p);
          p.j1 = -1;
          grew = true;
          break;
        }
      if (!grew) keep.push_back(r);
    }
    for (const Run& p : open_runs)
      if (p.j1 != -1) done.push_back(p);
    open_runs = keep;
  }
  for (const Run& r : done)
    mine.push_back({c.frame, {c.lo[0] + r.i0 * s, c.lo[1] + r.j0 * s, r.c0}, {c.lo[0] + r.i1 * s, c.lo[1] + r.j1 * s, r.c1}});
  // The crossed columns point by point; then the air beside all of it, the open columns'
  // own stretches included (a wall that crosses the columns on a slant). A column of air
  // that opened with its neighbour, and the little an open column runs on past the
  // surface, are open and no more: only what the cell holds brings air with it.
  for (int j = 0; j < k; ++j)
    for (int i = 0; i < k; ++i) {
      const Col& o = grown[at(i, j)];
      if (o.kind == 1) {
        const bool air = col[at(i, j)].kind == 2;
        for (int z = 0; z < k; ++z) {
          const double cz = c.lo[2] + (z + 0.5) * s;
          if (!(cz > o.c0 && cz < o.c1)) continue;
          pt(i, j, z) = !air && cz > o.c0 + o.past0 && cz < o.c1 - o.past1 ? kSpace : kOpen;
        }
      } else if (col[at(i, j)].kind == 3) {
        by_points(i, j);
      }
    }
  keep_solid_points();
  open_air();
  point_boxes();
}

// One cell's open space, as boxes in its frame.
void open_boxes_of(const Layout& lay, const Domain::Probe& probe, const Cell& c, double pitch, bool merge, bool keep_edge,
                   std::vector<OpenSpace::Box>& mine) {
  // Which cell of the layout this is (read_open_space passes the layout's own cells): the air past its cube is read
  // only for one of them.
  const Cell* first = lay.cells.data();
  const bool own = &c >= first && &c < first + lay.cells.size();
  const std::size_t self = own ? static_cast<std::size_t>(&c - first) : 0;
  open_boxes_with(
      lay, probe, c, pitch, merge, keep_edge, mine, [&](const Vec3& p) { return cell_holds(lay, probe, c, p); },
      [&](double a, double b, double z) { return cell_holds_at(lay, probe, self, a, b, z); }, own);
}

// O1: the cubes a weave region's open space is read in: cubes of `size` on its frame (the part's own axes) over the
// box round the region, cut to the part's own box. In order: the same for any number of threads.
std::vector<Cell> weave_cubes(const Domain& domain, const Layout& lay, const Layout::Weave& wv, double size) {
  std::vector<Cell> out;
  const Region* r = nullptr;
  for (const Region& x : domain.spec().regions)
    if (x.id == wv.region) r = &x;
  if (!r) return out;
  double lo[3] = {1e300, 1e300, 1e300}, hi[3] = {-1e300, -1e300, -1e300};
  auto take = [&](const Vec3& p, double grow) {
    const double v[3] = {p.x, p.y, p.z};
    for (int a = 0; a < 3; ++a) { lo[a] = std::min(lo[a], v[a] - grow); hi[a] = std::max(hi[a], v[a] + grow); }
  };
  if (r->is_shell()) {
    for (const Vec3& v : r->shell.vertices) take(v, r->shell_depth_mm);
  } else {
    const ClearanceGeometry& g = r->prism;
    if (!g.valid) return out;
    const double e = std::max(0.0, r->expand_mm);
    for (int k = 0; k < 8; ++k) {
      const double u = (k & 1) ? g.u_hi + e : g.u_lo - e, w = (k & 2) ? g.w_hi + e : g.w_lo - e, d = (k & 4) ? g.depth : 0.0;
      take(Vec3{g.origin.x + g.u.x * u + g.w.x * w + g.normal.x * d, g.origin.y + g.u.y * u + g.w.y * w + g.normal.y * d,
                g.origin.z + g.u.z * u + g.w.z * w + g.normal.z * d},
           0.0);
    }
  }
  const PartMeasure& part = domain.measure();
  const double plo[3] = {part.lo().x, part.lo().y, part.lo().z}, phi[3] = {part.hi().x, part.hi().y, part.hi().z};
  const Frame& f = lay.frames[static_cast<std::size_t>(wv.frame)];
  const double o[3] = {f.origin.x, f.origin.y, f.origin.z};
  long n0[3], n1[3];
  for (int a = 0; a < 3; ++a) {
    const double l = std::max(lo[a], plo[a]) - o[a], h = std::min(hi[a], phi[a]) - o[a];
    if (!(h > l)) return out;
    n0[a] = static_cast<long>(std::floor(l / size));
    n1[a] = static_cast<long>(std::ceil(h / size));
  }
  for (long z = n0[2]; z < n1[2]; ++z)
    for (long y = n0[1]; y < n1[1]; ++y)
      for (long x = n0[0]; x < n1[0]; ++x) {
        Cell c;
        c.region = wv.region;
        c.frame = wv.frame;
        c.lo[0] = x * size; c.lo[1] = y * size; c.lo[2] = z * size;
        c.size = size;
        c.cut = true;
        out.push_back(c);
      }
  return out;
}

}  // namespace

OpenSpace read_open_space(const Domain& domain, const Layout& layout, double pitch_mm, int threads,
                          const std::atomic<bool>* stop, bool merge, bool keep_edge) {
  const auto t0 = std::chrono::steady_clock::now();
  OpenSpace out;
  out.pitch_mm = pitch_mm > 0.0 ? pitch_mm : 0.25;
  // Each cell on its own, put back in cell order: the same boxes for any number of threads.
  std::vector<std::vector<OpenSpace::Box>> of_cell(layout.cells.size());
  std::atomic<std::size_t> next{0};
  auto work = [&] {
    const Domain::Probe probe = domain.probe();
    for (std::size_t ci = next.fetch_add(1); ci < layout.cells.size() && !asked(stop); ci = next.fetch_add(1))
      open_boxes_of(layout, probe, layout.cells[ci], out.pitch_mm, merge, keep_edge, of_cell[ci]);
  };
  {
    const int nt = static_cast<int>(std::min<std::size_t>(static_cast<std::size_t>(thread_count(threads)),
                                                           std::max<std::size_t>(1, layout.cells.size())));
    std::vector<std::thread> pool;
    for (int t = 1; t < nt; ++t) pool.emplace_back(work);
    work();
    for (std::thread& t : pool) t.join();
  }
  check(stop);
  for (const auto& v : of_cell) out.boxes.insert(out.boxes.end(), v.begin(), v.end());
  // O1: a weave region's open space, read from the domain itself at the same pitch, point by point as a curved
  // region's cells are (with the same rule at an edge against solid, S11b, and the same air opened beside it), in
  // cubes of sixteen points; after the cells' boxes.
  for (const Layout::Weave& wv : layout.weave) {
    const std::vector<Cell> cubes = weave_cubes(domain, layout, wv, 16.0 * out.pitch_mm);
    std::vector<std::vector<OpenSpace::Box>> of_cube(cubes.size());
    std::atomic<std::size_t> next_cube{0};
    auto work_weave = [&] {
      const Domain::Probe probe = domain.probe();
      for (std::size_t k = next_cube.fetch_add(1); k < cubes.size() && !asked(stop); k = next_cube.fetch_add(1)) {
        const Cell& c = cubes[k];
        const Frame& f = layout.frames[static_cast<std::size_t>(c.frame)];
        auto here = [&](const Vec3& p) {
          const Where w = probe.where(p);
          return w.lattice() && w.id == c.region;
        };
        open_boxes_with(layout, probe, c, out.pitch_mm, merge, keep_edge, of_cube[k], here,
                        [&](double a, double b, double z) { return here(f.at(a, b, z)); }, true);
      }
    };
    const int nt = static_cast<int>(std::min<std::size_t>(static_cast<std::size_t>(thread_count(threads)),
                                                           std::max<std::size_t>(1, cubes.size())));
    std::vector<std::thread> pool;
    for (int t = 1; t < nt; ++t) pool.emplace_back(work_weave);
    work_weave();
    for (std::thread& t : pool) t.join();
    check(stop);
    for (const auto& v : of_cube) out.boxes.insert(out.boxes.end(), v.begin(), v.end());
  }
  out.ms = ms_since(t0);
  return out;
}

// ── the owner's bridge rules for a weave (O6 to O9) ──────────────────────────
namespace {
using PointKey = std::array<double, 3>;
PointKey key_of(const Vec3& p) { return {p.x, p.y, p.z}; }
double bar_length(const Bar& b) {
  return std::sqrt((b.b.x - b.a.x) * (b.b.x - b.a.x) + (b.b.y - b.a.y) * (b.b.y - b.a.y) + (b.b.z - b.a.z) * (b.b.z - b.a.z));
}
double to_bar(const Vec3& p, const Bar& x, double* along = nullptr) {
  const Vec3 d{x.b.x - x.a.x, x.b.y - x.a.y, x.b.z - x.a.z};
  const double l2 = d.x * d.x + d.y * d.y + d.z * d.z;
  const double t = l2 > 0 ? std::clamp(((p.x - x.a.x) * d.x + (p.y - x.a.y) * d.y + (p.z - x.a.z) * d.z) / l2, 0.0, 1.0) : 0.0;
  if (along) *along = t;
  const double ex = x.a.x + t * d.x - p.x, ey = x.a.y + t * d.y - p.y, ez = x.a.z + t * d.z - p.z;
  return std::sqrt(ex * ex + ey * ey + ez * ez);
}
bool in_regions(const std::vector<int>& regions, int r) { return std::find(regions.begin(), regions.end(), r) != regions.end(); }
}  // namespace

std::vector<std::size_t> end_joints(const Bars& bars) {
  // Ends within a hundredth of a micron of a point already seen are that point (as drop_loose_bars reads a joint).
  constexpr double kSame = 1e-5;
  using Cell = std::array<long long, 3>;
  // SPEED 11-22: hashed, not ordered (the 27 neighbours are read by key, so the joints are the same numbers)
  struct CellHash {
    std::size_t operator()(const Cell& c) const noexcept {
      std::uint64_t h = static_cast<std::uint64_t>(c[0]) * 0x9E3779B97F4A7C15ull;
      h ^= static_cast<std::uint64_t>(c[1]) + 0x7F4A7C159E3779B9ull + (h << 6) + (h >> 2);
      h ^= static_cast<std::uint64_t>(c[2]) + 0x94D049BB133111EBull + (h << 6) + (h >> 2);
      return static_cast<std::size_t>(h);
    }
  };
  std::unordered_map<Cell, std::vector<std::pair<Vec3, std::size_t>>, CellHash> seen;
  seen.reserve(2 * bars.bars.size());
  std::size_t points = 0;
  auto joint_of = [&](const Vec3& p) {
    const Cell k{std::llround(p.x / kSame), std::llround(p.y / kSame), std::llround(p.z / kSame)};
    for (long long dx = -1; dx <= 1; ++dx)
      for (long long dy = -1; dy <= 1; ++dy)
        for (long long dz = -1; dz <= 1; ++dz) {
          const auto it = seen.find({k[0] + dx, k[1] + dy, k[2] + dz});
          if (it == seen.end()) continue;
          for (const auto& [q, id] : it->second)
            if ((q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y) + (q.z - p.z) * (q.z - p.z) <= kSame * kSame) return id;
        }
    seen[k].push_back({p, points});
    return points++;
  };
  std::vector<std::size_t> out(2 * bars.bars.size());
  for (std::size_t i = 0; i < bars.bars.size(); ++i) {
    out[2 * i] = joint_of(bars.bars[i].a);
    out[2 * i + 1] = joint_of(bars.bars[i].b);
  }
  return out;
}

namespace {
// Where each bar has an end, by joint (end_joints): the bars ending there.
std::vector<std::vector<std::size_t>> bars_at_joints(const std::vector<std::size_t>& joints, std::size_t n) {
  std::size_t most = 0;
  for (std::size_t j : joints) most = std::max(most, j + 1);
  std::vector<std::vector<std::size_t>> at(most);
  for (std::size_t i = 0; i < n; ++i) {
    at[joints[2 * i]].push_back(i);
    if (joints[2 * i + 1] != joints[2 * i]) at[joints[2 * i + 1]].push_back(i);
  }
  return at;
}
// O10 (a finding at a held end): is end e of weave bar i held, by the bars still `present`? In the solid, or on a
// present bar that reaches that point from below or level: a Node end where another present bar ends whose other end
// is less than one layer above it, a Joined end in a present bar whose lowest end is less than one layer above it.
bool held_from_below(const Bars& all, const std::vector<std::size_t>& joints, const std::vector<std::vector<std::size_t>>& at,
                     const std::vector<char>& present, std::size_t i, int e, double layer) {
  const Bar& x = all.bars[i];
  const Bar::End end = e == 0 ? x.end_a : x.end_b;
  const Vec3& p = e == 0 ? x.a : x.b;
  if (end == Bar::End::Solid) return true;
  const std::size_t n = all.bars.size();
  if (end == Bar::End::Joined) {
    const int into = e == 0 ? x.into_a : x.into_b;
    if (into < 0 || static_cast<std::size_t>(into) >= n || static_cast<std::size_t>(into) == i ||
        !present[static_cast<std::size_t>(into)])
      return false;
    const Bar& y = all.bars[static_cast<std::size_t>(into)];
    return std::min(y.a.z, y.b.z) < p.z + layer;
  }
  if (end != Bar::End::Node) return false;
  const std::size_t joint = joints[2 * i + static_cast<std::size_t>(e)];
  for (std::size_t j : at[joint]) {
    if (j == i || !present[j]) continue;
    const Bar& y = all.bars[j];
    if (joints[2 * j] == joints[2 * j + 1]) continue;
    const Vec3& other = joints[2 * j] == joint ? y.b : y.a;
    if (other.z < p.z + layer) return true;
  }
  return false;
}
// The lowest end of a bar (a at a tie).
int low_end(const Bar& x) { return x.b.z < x.a.z ? 1 : 0; }
// As build_mesh has always read a place against a bar: the bar's lowest point within 0.45 mm of it in height, and
// the place within half its width + 0.35 mm of its line.
bool place_reaches(const Vec3& s, const Bar& x) {
  const double r = 0.5 * x.width;
  if (std::fabs(std::min(x.a.z, x.b.z) - r - s.z) > 0.45) return false;
  return to_bar(s, x) < r + 0.35;
}
}  // namespace

std::vector<char> bars_present(const Bars& bars, const std::vector<Vec3>& drop_at) { return bars_present(bars, drop_at, {}); }

std::vector<char> bars_present(const Bars& bars, const std::vector<Vec3>& drop_at, const std::vector<int>& weave_regions,
                               double layer_mm, std::vector<char>* used) {
  // As build_mesh leaves a strut out: its lowest point at one of the places.
  const std::size_t n = bars.bars.size();
  std::vector<char> out(n, 1);
  if (used) used->assign(drop_at.size(), 0);
  std::vector<std::vector<std::size_t>> reached(weave_regions.empty() ? 0 : n);   // a weave bar: the places reaching it
  for (std::size_t i = 0; i < n; ++i) {
    const Bar& x = bars.bars[i];
    const bool weave = in_regions(weave_regions, x.region);
    for (std::size_t k = 0; k < drop_at.size(); ++k) {
      if (!place_reaches(drop_at[k], x)) continue;
      if (weave) { reached[i].push_back(k); continue; }
      out[i] = 0;
      if (!used) break;
      (*used)[k] = 1;
    }
  }
  if (weave_regions.empty()) return out;
  // O10 (a finding at a held end, a level end): a place leaves a weave bar out only when the bar's own lowest end is
  // not held from below or level; an end less than one layer below a held other end of the same bar is at that end's
  // level. What is left out can leave another bar unheld: judged again until nothing changes.
  const double layer = layer_mm > 0.0 ? layer_mm : 0.2;
  const std::vector<std::size_t> joints = end_joints(bars);
  const std::vector<std::vector<std::size_t>> at = bars_at_joints(joints, n);
  for (bool changed = true; changed;) {
    changed = false;
    for (std::size_t i = 0; i < n; ++i) {
      if (reached[i].empty() || !out[i]) continue;
      const Bar& x = bars.bars[i];
      const int lo = low_end(x);
      if (held_from_below(bars, joints, at, out, i, lo, layer)) continue;
      const double rise = std::fabs(x.b.z - x.a.z);
      if (rise < layer && held_from_below(bars, joints, at, out, i, 1 - lo, layer)) continue;
      out[i] = 0;
      changed = true;
    }
  }
  if (used)
    for (std::size_t i = 0; i < n; ++i)
      if (!out[i])
        for (std::size_t k : reached[i]) (*used)[k] = 1;
  return out;
}

// The reference form: every bar read for every place, the joints made per call (as before 11-22).
std::vector<WeaveFinding> weave_findings_every_bar(const Bars& bars, const std::vector<int>& weave_regions,
                                                   const std::vector<char>& present, const std::vector<Vec3>& places,
                                                   double layer_mm) {
  std::vector<WeaveFinding> out(places.size());
  if (places.empty()) return out;
  const double layer = layer_mm > 0.0 ? layer_mm : 0.2;
  const std::size_t n = bars.bars.size();
  const std::vector<char> here(present.empty() ? std::vector<char>(n, 1) : present);
  const std::vector<std::size_t> joints = end_joints(bars);
  const std::vector<std::vector<std::size_t>> at = bars_at_joints(joints, n);
  for (std::size_t k = 0; k < places.size(); ++k) {
    WeaveFinding& f = out[k];
    const Vec3& place = places[k];
    for (std::size_t i = 0; i < n; ++i) {
      if (!here[i]) continue;
      const Bar& x = bars.bars[i];
      const bool weave = in_regions(weave_regions, x.region);
      if (weave && to_bar(place, x) < 0.5 * x.width + 0.35) f.on_weave = true;
      if (!place_reaches(place, x)) continue;
      ++f.reached;
      if (!weave) { ++f.cube; continue; }
      const int lo = low_end(x);
      if (held_from_below(bars, joints, at, here, i, lo, layer)) { ++f.held; continue; }
      if (std::fabs(x.b.z - x.a.z) < layer && held_from_below(bars, joints, at, here, i, 1 - lo, layer)) ++f.level;
    }
  }
  return out;
}

// SPEED 11-22: a cell's key from its three numbers (21 bits each, offset so a negative number keeps its place).
namespace {
std::uint64_t grid_key(long long i, long long j, long long k) {
  constexpr long long kOff = 1LL << 20;
  const auto f = [](long long v) { return static_cast<std::uint64_t>((v + kOff) & 0x1FFFFF); };
  return f(i) << 42 | f(j) << 21 | f(k);
}
bool grid_cell(double v, long long& c) {
  if (!std::isfinite(v)) return false;
  const double q = std::floor(v / BarGrid::kCell);
  if (std::fabs(q) > static_cast<double>((1LL << 20) - 2)) return false;
  c = static_cast<long long>(q);
  return true;
}
}  // namespace

BarGrid::BarGrid(const Bars& bars, const std::vector<char>& use) {
  for (std::size_t i = 0; i < bars.bars.size(); ++i) {
    if (!use.empty() && i < use.size() && !use[i]) continue;
    const Bar& x = bars.bars[i];
    // the farthest a place can lie from the bar's line and read it, and a hair more for the rounding of the box
    const double r = std::max(0.0, 0.5 * x.width + 0.35) + 1e-6;
    long long lo[3], hi[3];
    if (!grid_cell(std::min(x.a.x, x.b.x) - r, lo[0]) || !grid_cell(std::max(x.a.x, x.b.x) + r, hi[0]) ||
        !grid_cell(std::min(x.a.y, x.b.y) - r, lo[1]) || !grid_cell(std::max(x.a.y, x.b.y) + r, hi[1]) ||
        !grid_cell(std::min(x.a.z, x.b.z) - r, lo[2]) || !grid_cell(std::max(x.a.z, x.b.z) + r, hi[2]))
      continue;   // not finite: no place reads it (every comparison with it is false)
    for (long long a = lo[0]; a <= hi[0]; ++a)
      for (long long b = lo[1]; b <= hi[1]; ++b)
        for (long long c = lo[2]; c <= hi[2]; ++c) cells_[grid_key(a, b, c)].push_back(static_cast<std::uint32_t>(i));
  }
}

const std::vector<std::uint32_t>& BarGrid::near(const Vec3& p) const {
  long long a, b, c;
  if (!grid_cell(p.x, a) || !grid_cell(p.y, b) || !grid_cell(p.z, c)) return none_;
  const auto it = cells_.find(grid_key(a, b, c));
  return it == cells_.end() ? none_ : it->second;
}

WeaveFindingsIndex::WeaveFindingsIndex(const Bars& bars, const std::vector<int>& weave_regions,
                                       const std::vector<char>& present, double layer_mm)
    : bars_(bars),
      regions_(weave_regions),
      here_(present.empty() ? std::vector<char>(bars.bars.size(), 1) : present),
      layer_(layer_mm > 0.0 ? layer_mm : 0.2),
      joints_(end_joints(bars)),
      at_(bars_at_joints(joints_, bars.bars.size())),
      grid_(bars, here_) {}

WeaveFinding WeaveFindingsIndex::at(const Vec3& place) const {
  // As weave_findings_every_bar reads one place, over the bars filed in its cell (every other bar can neither reach it
  // nor have it on its line, so it counted nothing there).
  WeaveFinding f;
  for (const std::uint32_t u : grid_.near(place)) {
    const std::size_t i = u;
    if (i >= here_.size() || !here_[i]) continue;
    const Bar& x = bars_.bars[i];
    const bool weave = in_regions(regions_, x.region);
    if (weave && to_bar(place, x) < 0.5 * x.width + 0.35) f.on_weave = true;
    if (!place_reaches(place, x)) continue;
    ++f.reached;
    if (!weave) { ++f.cube; continue; }
    const int lo = low_end(x);
    if (held_from_below(bars_, joints_, at_, here_, i, lo, layer_)) { ++f.held; continue; }
    if (std::fabs(x.b.z - x.a.z) < layer_ && held_from_below(bars_, joints_, at_, here_, i, 1 - lo, layer_)) ++f.level;
  }
  return f;
}

std::vector<WeaveFinding> weave_findings(const Bars& bars, const std::vector<int>& weave_regions, const std::vector<char>& present,
                                         const std::vector<Vec3>& places, double layer_mm) {
  std::vector<WeaveFinding> out(places.size());
  if (places.empty()) return out;
  const WeaveFindingsIndex index(bars, weave_regions, present, layer_mm);
  for (std::size_t k = 0; k < places.size(); ++k) out[k] = index.at(places[k]);
  return out;
}

WeaveHolds weave_holds(const Bars& all, const std::vector<int>& regions, const std::vector<char>& present, double rise) {
  WeaveHolds h;
  const std::size_t n = all.bars.size();
  h.kept.assign(n, 1);
  h.shallow.assign(n, 0);
  std::vector<char> weave(n, 0);
  for (std::size_t i = 0; i < n; ++i) {
    if (!present.empty() && !present[i]) h.kept[i] = 0;
    weave[i] = in_regions(regions, all.bars[i].region);
    h.shallow[i] = weave[i] && bar_is_bridge(all.bars[i], rise);
  }
  // Every bar's ends by joint: ends within a hundredth of a micron are one point, as drop_loose_bars reads them (O6).
  const std::vector<std::size_t> joints = end_joints(all);
  const std::vector<std::vector<std::size_t>> at = bars_at_joints(joints, n);
  auto held = [&](std::size_t i, int e) {
    const Bar& x = all.bars[i];
    const Bar::End end = e == 0 ? x.end_a : x.end_b;
    if (end == Bar::End::Solid) return true;
    if (end == Bar::End::Joined) {
      const int into = e == 0 ? x.into_a : x.into_b;
      return into >= 0 && static_cast<std::size_t>(into) < n && static_cast<std::size_t>(into) != i &&
             h.kept[static_cast<std::size_t>(into)] != 0;
    }
    if (end != Bar::End::Node) return false;
    for (std::size_t j : at[joints[2 * i + static_cast<std::size_t>(e)]])
      if (j != i && h.kept[j]) return true;
    return false;
  };
  // Left out one by one until nothing changes: what a left-out bar held is judged again. A shallow weave bar needs
  // both ends held (O9); every other weave bar its lowest end (O9, every weave bar).
  for (bool changed = true; changed;) {
    changed = false;
    for (std::size_t i = 0; i < n; ++i) {
      if (!weave[i] || !h.kept[i]) continue;
      if (h.shallow[i] ? held(i, 0) && held(i, 1) : held(i, low_end(all.bars[i]))) continue;
      h.kept[i] = 0;
      changed = true;
    }
  }
  for (std::size_t i = 0; i < n; ++i) {
    if (!weave[i] || (!present.empty() && !present[i])) continue;
    if (h.kept[i]) h.kept_any_length += h.shallow[i];
    else ++h.left_unheld;
  }
  return h;
}

std::vector<WeaveStand> weave_stands_wanted(const Bars& all, const std::vector<int>& regions, const std::vector<char>& kept,
                                            double every_mm, double rise) {
  std::vector<WeaveStand> out;
  if (!(every_mm > 0.0)) return out;
  const std::size_t n = all.bars.size();
  auto is_kept = [&](std::size_t i) { return i < kept.size() ? kept[i] != 0 : true; };
  std::vector<std::size_t> sb;   // the kept shallow weave bars
  std::vector<int> slot(n, -1);
  for (std::size_t i = 0; i < n; ++i)
    if (is_kept(i) && in_regions(regions, all.bars[i].region) && bar_is_bridge(all.bars[i], rise)) {
      slot[i] = static_cast<int>(sb.size());
      sb.push_back(i);
    }
  if (sb.empty()) return out;
  // Every kept bar's ends by exact point, and the shallow ones among them.
  std::map<PointKey, std::vector<std::size_t>> ends, shallow_ends;
  for (std::size_t i = 0; i < n; ++i) {
    if (!is_kept(i)) continue;
    ends[key_of(all.bars[i].a)].push_back(i);
    ends[key_of(all.bars[i].b)].push_back(i);
  }
  for (std::size_t i : sb) {
    shallow_ends[key_of(all.bars[i].a)].push_back(i);
    shallow_ends[key_of(all.bars[i].b)].push_back(i);
  }
  // Chained as stage 1c's table chains them: exactly two shallow bars end at the point, in line within 15 degrees.
  const double in_line = std::cos(15.0 * 3.14159265358979323846 / 180.0);
  auto chained = [&](const PointKey& k) {
    const auto it = shallow_ends.find(k);
    if (it == shallow_ends.end() || it->second.size() != 2 || it->second[0] == it->second[1]) return false;
    const Bar &x = all.bars[it->second[0]], &y = all.bars[it->second[1]];
    const Vec3 p{k[0], k[1], k[2]};
    const Vec3& px = key_of(x.a) == k ? x.b : x.a;
    const Vec3& py = key_of(y.a) == k ? y.b : y.a;
    const Vec3 u{p.x - px.x, p.y - px.y, p.z - px.z}, v{py.x - p.x, py.y - p.y, py.z - p.z};
    const double lu = std::sqrt(u.x * u.x + u.y * u.y + u.z * u.z), lv = std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
    return lu > 0.0 && lv > 0.0 && (u.x * v.x + u.y * v.y + u.z * v.z) / (lu * lv) >= in_line;
  };
  // Where other kept bars' Joined ends land in a shallow bar.
  std::map<std::size_t, std::vector<Vec3>> landed;
  for (std::size_t i = 0; i < n; ++i) {
    if (!is_kept(i)) continue;
    const Bar& x = all.bars[i];
    for (int e = 0; e < 2; ++e) {
      if ((e == 0 ? x.end_a : x.end_b) != Bar::End::Joined) continue;
      const int into = e == 0 ? x.into_a : x.into_b;
      if (into < 0 || static_cast<std::size_t>(into) >= n || slot[static_cast<std::size_t>(into)] < 0) continue;
      landed[static_cast<std::size_t>(into)].push_back(e == 0 ? x.a : x.b);
    }
  }
  std::vector<char> done(sb.size(), 0);
  for (std::size_t s0 = 0; s0 < sb.size(); ++s0) {
    if (done[s0]) continue;
    // Walk back from this bar to an end of its run (round a closed ring, back to it), then along the run.
    std::size_t start = sb[s0];
    bool from_a = true;   // the run enters `start` at its a end
    {
      std::size_t cur = sb[s0];
      PointKey back = key_of(all.bars[cur].a);
      for (std::size_t steps = 0; steps <= sb.size(); ++steps) {
        start = cur;
        from_a = key_of(all.bars[cur].a) == back;
        if (!chained(back)) break;
        const auto& two = shallow_ends.at(back);
        const std::size_t nxt = two[0] == cur ? two[1] : two[0];
        if (nxt == sb[s0]) break;
        back = key_of(all.bars[nxt].a) == back ? key_of(all.bars[nxt].b) : key_of(all.bars[nxt].a);
        cur = nxt;
      }
    }
    struct Step { std::size_t bar; Vec3 p0, p1; double s0, len; };
    std::vector<Step> path;
    bool closed = false;
    double s = 0.0;
    {
      std::size_t cur = start;
      bool enter_a = from_a;
      for (std::size_t steps = 0; steps <= sb.size(); ++steps) {
        done[static_cast<std::size_t>(slot[cur])] = 1;
        const Bar& x = all.bars[cur];
        const Vec3 p0 = enter_a ? x.a : x.b, p1 = enter_a ? x.b : x.a;
        const double len = bar_length(x);
        path.push_back({cur, p0, p1, s, len});
        s += len;
        const PointKey k1 = key_of(p1);
        if (!chained(k1)) break;
        const auto& two = shallow_ends.at(k1);
        const std::size_t nxt = two[0] == cur ? two[1] : two[0];
        if (nxt == start) { closed = true; break; }
        if (done[static_cast<std::size_t>(slot[nxt])]) break;
        enter_a = key_of(all.bars[nxt].a) == k1;
        cur = nxt;
      }
    }
    const double total = s;
    auto in_run = [&](std::size_t j) {
      for (const Step& st : path) if (st.bar == j) return true;
      return false;
    };
    // A joint of the run is a stand when an end of the run there is Solid or Joined, or another kept bar ends there.
    auto joint_stands = [&](const PointKey& k) {
      for (std::size_t j : ends[k]) {
        if (!in_run(j)) return true;
        const Bar& x = all.bars[j];
        const Bar::End e = key_of(x.a) == k ? x.end_a : x.end_b;
        if (e == Bar::End::Solid || e == Bar::End::Joined) return true;
      }
      return false;
    };
    std::vector<double> stand;   // positions along the run
    for (std::size_t q = 0; q < path.size(); ++q) {
      const Step& st = path[q];
      if (q == 0 && joint_stands(key_of(st.p0))) stand.push_back(st.s0);
      if (joint_stands(key_of(st.p1))) stand.push_back(st.s0 + st.len);
      const auto it = landed.find(st.bar);
      if (it == landed.end()) continue;
      const bool forward = key_of(all.bars[st.bar].a) == key_of(st.p0);
      for (const Vec3& p : it->second) {
        double t = 0.0;
        (void)to_bar(p, all.bars[st.bar], &t);
        stand.push_back(st.s0 + (forward ? t : 1.0 - t) * st.len);
      }
    }
    if (stand.empty()) continue;
    std::sort(stand.begin(), stand.end());
    std::vector<std::pair<double, double>> gaps;
    for (std::size_t q = 0; q + 1 < stand.size(); ++q) gaps.push_back({stand[q], stand[q + 1]});
    if (closed) gaps.push_back({stand.back(), stand.front() + total});
    for (const auto& g : gaps) {
      if (!(g.second - g.first > every_mm)) continue;
      double m = 0.5 * (g.first + g.second);
      if (closed && m >= total) m -= total;
      const Step* st = &path.back();
      for (const Step& c : path)
        if (m <= c.s0 + c.len) { st = &c; break; }
      const double t = st->len > 0.0 ? std::clamp((m - st->s0) / st->len, 0.0, 1.0) : 0.0;
      const Bar& x = all.bars[st->bar];
      WeaveStand w;
      w.at = {st->p0.x + t * (st->p1.x - st->p0.x), st->p0.y + t * (st->p1.y - st->p0.y), st->p0.z + t * (st->p1.z - st->p0.z)};
      w.width = x.width;
      // The bridge's underside straight under its centre line, less the fall over 0.45 mm along it and a hair.
      const double horiz = std::hypot(x.b.x - x.a.x, x.b.y - x.a.y);
      const double cosv = st->len > 0.0 ? horiz / st->len : 1.0, tanv = horiz > 0.0 ? std::fabs(x.b.z - x.a.z) / horiz : 0.0;
      w.below_z = w.at.z - 0.5 * x.width / std::max(cosv, 1e-6) - 0.45 * tanv - 0.1;
      out.push_back(w);
    }
  }
  return out;
}

#ifndef TOPOPT_HAVE_MANIFOLD

bool mesh_available() { return false; }

namespace {
const char* const kNoLibrary = "this build has no mesh library (Manifold), so the lattice file cannot be made";
}

Carved carve_part(const PartMeasure&, const Layout&, const OpenSpace&, double, const std::atomic<bool>*) {
  Carved c;
  c.why = kNoLibrary;
  return c;
}

TriangleMesh build_mesh(const PartMeasure&, const Domain&, const Layout&, const Bars&, const Carved&, const MeshSpec&,
                        MeshReport* report) {
  if (report) {
    *report = MeshReport{};
    report->why = kNoLibrary;
  }
  return {};
}

TriangleMesh build_mesh(const PartMeasure& pm, const Domain& domain, const Layout& lay, const Bars& bars, const OpenSpace&,
                        const MeshSpec& spec, MeshReport* report) {
  return build_mesh(pm, domain, lay, bars, Carved{}, spec, report);
}

double strut_run_on_mm(const Carved&, const MeshSpec& spec) {
  return spec.strut_reach_mm >= 0.0 ? spec.strut_reach_mm : 0.5 * 0.25 + 0.02 + 0.05;
}
void weave_bar_shells(const Domain&, const Layout&, const Bars&, const std::vector<char>&, const std::vector<char>&,
                      const Carved&, const MeshSpec&, TriangleMesh&, std::vector<std::size_t>&, MeshReport&) {}
std::vector<char> solid_slivers_left_out(const Carved&, const std::vector<Vec3>&) { return {}; }
TriangleMesh carved_solid_mesh(const Carved&) { return {}; }
bool cut_shell_at_bed(TriangleMesh&, double) { return false; }

#else

namespace {
using manifold::Manifold;
manifold::vec3 mv(const Vec3& v) { return manifold::vec3{v.x, v.y, v.z}; }
// The same solid, holding on to nothing it was made from (so that can be freed).
Manifold fresh(const Manifold& m) {
  const manifold::MeshGL64 g = m.GetMeshGL64();
  return Manifold(g);
}
struct FloatPlace {
  float x, y, z;
  bool operator==(const FloatPlace& o) const { return x == o.x && y == o.y && z == o.z; }
};
struct FloatPlaceHash {
  std::size_t operator()(const FloatPlace& k) const {
    std::uint32_t a, b, c;
    std::memcpy(&a, &k.x, 4);
    std::memcpy(&b, &k.y, 4);
    std::memcpy(&c, &k.z, 4);
    return (a * 0x9E3779B97F4A7C15ULL) ^ (b * 0xC2B2AE3D27D4EB4FULL) ^ (c * 0x165667B19E3779F9ULL);
  }
};
}  // namespace

bool mesh_available() { return true; }

namespace {
// What a carving keeps: the part, the part less the open space, and that body's separate pieces.
struct CarvedSolids {
  Manifold part, solid;
  std::vector<Manifold> pieces;
  double part_mm3 = 0.0;
  double pitch_mm = 0.25;   // the open space's own pitch and the overlap it was carved with: MeshSpec::strut_reach_mm
  double grow_mm = 0.02;    // reads them, so a carving gives the same mesh whatever the build's own grow_mm
  // SHEETS: the open boxes (a sheet layout's only: each sheet is cut to its region's boxes grown by the run-on), and
  // the sheets made once for every build of the make-check-make loop (only the posts change between its passes).
  std::vector<OpenSpace::Box> open_boxes;
  struct SheetsMade {
    const void* key = nullptr;     // the MeshSpec::sheets they were made from
    std::size_t seams_key = 0;
    Manifold body;                 // every sheet, cut and joined (not yet to the solid)
    Manifold with_solid;           // the solid and the sheets, joined (made on the first build with no drop_at)
    bool joined = false;
    bool ok = false;
    std::string why;
    std::size_t blocks = 0, triangles = 0, places = 0, seams_blended = 0, seams_fell_back = 0;
    double deviation_mm = 0.0, mm3 = 0.0, ms = 0.0, ms_union = 0.0;
  };
  mutable std::mutex sheets_mu;
  mutable std::shared_ptr<SheetsMade> sheets;
};
// A small separate piece of the solid body whose lowest point is one of the mid-air places (`drop_at`) is left out.
bool sliver_dropped(const manifold::Box& b, double v, const std::vector<Vec3>& drop_at) {
  bool drop = false;
  if (v < 20.0)
    for (const Vec3& sp : drop_at)
      if (std::fabs(b.min.z - sp.z) < 0.45 && sp.x > b.min.x - 0.4 && sp.x < b.max.x + 0.4 && sp.y > b.min.y - 0.4 &&
          sp.y < b.max.y + 0.4)
        drop = true;
  return drop;
}
}  // namespace

bool cut_shell_at_bed(TriangleMesh& shell, double bed) {
  manifold::MeshGL64 g;
  g.numProp = 3;
  for (const Vec3& v : shell.vertices) { g.vertProperties.push_back(v.x); g.vertProperties.push_back(v.y); g.vertProperties.push_back(v.z); }
  for (const auto& t : shell.triangles)
    for (int k = 0; k < 3; ++k) g.triVerts.push_back(static_cast<std::uint64_t>(t[static_cast<std::size_t>(k)]));
  const Manifold m(g);
  if (m.Status() != Manifold::Error::NoError) return false;
  const Manifold above = m.TrimByPlane({0.0, 0.0, 1.0}, bed);
  if (above.Status() != Manifold::Error::NoError || above.IsEmpty()) return false;
  const manifold::MeshGL64 h = above.GetMeshGL64();
  TriangleMesh out;
  for (std::size_t v = 0; v < h.NumVert(); ++v)
    out.vertices.push_back({h.vertProperties[v * h.numProp], h.vertProperties[v * h.numProp + 1], std::max(bed, h.vertProperties[v * h.numProp + 2])});
  for (std::size_t t = 0; t < h.NumTri(); ++t)
    out.triangles.push_back({static_cast<int>(h.triVerts[3 * t]), static_cast<int>(h.triVerts[3 * t + 1]), static_cast<int>(h.triVerts[3 * t + 2])});
  shell = std::move(out);
  return true;
}

std::vector<char> solid_slivers_left_out(const Carved& carved, const std::vector<Vec3>& drop_at) {
  std::vector<char> out;
  if (!carved.kept) return out;
  for (const Manifold& piece : static_cast<const CarvedSolids*>(carved.kept.get())->pieces)
    out.push_back(drop_at.empty() ? 0 : sliver_dropped(piece.BoundingBox(), piece.Volume(), drop_at) ? 1 : 0);
  return out;
}

TriangleMesh carved_solid_mesh(const Carved& carved) {
  TriangleMesh out;
  if (!carved.ok || !carved.kept) return out;
  const manifold::MeshGL64 g = static_cast<const CarvedSolids*>(carved.kept.get())->solid.GetMeshGL64();
  out.vertices.reserve(g.NumVert());
  for (std::size_t v = 0; v < g.NumVert(); ++v)
    out.vertices.push_back({g.vertProperties[v * g.numProp], g.vertProperties[v * g.numProp + 1], g.vertProperties[v * g.numProp + 2]});
  out.triangles.reserve(g.NumTri());
  for (std::size_t t = 0; t < g.NumTri(); ++t)
    out.triangles.push_back({static_cast<int>(g.triVerts[3 * t]), static_cast<int>(g.triVerts[3 * t + 1]), static_cast<int>(g.triVerts[3 * t + 2])});
  return out;
}

Carved carve_part(const PartMeasure& pm, const Layout& lay, const OpenSpace& open_space, double grow,
                  const std::atomic<bool>* stop) {
  const auto t0 = std::chrono::steady_clock::now();
  Carved out;
  check(stop);
  auto made = std::make_shared<CarvedSolids>();
  if (open_space.pitch_mm > 0.0) made->pitch_mm = open_space.pitch_mm;
  made->grow_mm = grow;
  made->part = [&] {
    manifold::MeshGL64 g;
    g.numProp = 3;
    for (const Vec3& v : pm.mesh().vertices) {
      g.vertProperties.push_back(v.x);
      g.vertProperties.push_back(v.y);
      g.vertProperties.push_back(v.z);
    }
    for (const auto& t : pm.mesh().triangles)
      for (int k = 0; k < 3; ++k) g.triVerts.push_back(static_cast<std::uint64_t>(t[k]));
    return Manifold(g);
  }();
  if (made->part.Status() != Manifold::Error::NoError) {
    out.why = "the part is not one closed surface, so the lattice file cannot be made from it";
    return out;
  }
  made->part_mm3 = made->part.Volume();
  made->solid = made->part;
  if (sheet_kind_of(lay.topology)) made->open_boxes = open_space.boxes;   // SHEETS: each sheet is cut to these
  if (!open_space.boxes.empty()) {
    std::vector<Manifold> open;
    open.reserve(open_space.boxes.size());
    // Boxes overlap their neighbours instead of only touching, by enough that two solid
    // columns meeting corner to corner come out clearly apart, not sharing a line.
    for (const OpenSpace::Box& b : open_space.boxes) {
      const Frame& f = lay.frames[static_cast<std::size_t>(b.frame)];
      open.push_back(Manifold::Cube({b.hi[0] - b.lo[0] + 2 * grow, b.hi[1] - b.lo[1] + 2 * grow, b.hi[2] - b.lo[2] + 2 * grow})
                         .Translate({b.lo[0] - grow, b.lo[1] - grow, b.lo[2] - grow})
                         .Transform(manifold::mat3x4(mv(f.ax[0]), mv(f.ax[1]), mv(f.ax[2]), mv(f.origin))));
    }
    const Manifold open_all = Manifold::BatchBoolean(open, manifold::OpType::Add);
    open.clear();
    open.shrink_to_fit();
    check(stop);
    made->solid = fresh(made->part - open_all);
  }
  if (made->solid.Status() != Manifold::Error::NoError) {
    out.why = "opening the cells failed";
    return out;
  }
  made->pieces = made->solid.Decompose();
  check(stop);
  out.ok = true;
  out.kept = made;
  out.ms = ms_since(t0);
  return out;
}

TriangleMesh build_mesh(const PartMeasure& pm, const Domain& domain, const Layout& lay, const Bars& bars, const OpenSpace& open,
                        const MeshSpec& spec, MeshReport* report) {
  const Carved carved = carve_part(pm, lay, open, spec.grow_mm, spec.stop);
  MeshReport rep;
  const TriangleMesh mesh = build_mesh(pm, domain, lay, bars, carved, spec, &rep);
  rep.ms_solid += carved.ms;
  if (report) *report = rep;
  return mesh;
}

namespace {
// The shapes build_mesh writes for one bar: its strut (round, a square bridge, or a weave's D section, O14) carried
// `reach` past its ends, and a weave bar's blended feet (O11). build_mesh joins them; the tubes route (OF2) writes a
// weave's shallow struts and its feet as closed shells of their own from the same shapes, never joined.
// The sides of a round strut, and of the ball, at a joint where a level bar meets a vertical one (StrutMaker::add).
constexpr int kFineSides = 16;
struct StrutMaker {
  const MeshSpec& spec;
  int SEG = 12, HALF = 6;
  double kPi = 3.14159265358979323846, kRound = 1.0, reach = 0.0;
  std::vector<int> foot_regions, round_top_regions;
  std::unique_ptr<const SolidAt> wall_at;
  std::optional<Domain::Probe> wall_probe;
  StrutMaker(const Domain& domain, const Layout& lay, const MeshSpec& s, const CarvedSolids& kept) : spec(s) {
    SEG = std::max(3, spec.bar_sides);
    // A bar of SEG flat sides with the same cross-section AREA as the round strut.
    kRound = std::sqrt(2.0 * kPi / (SEG * std::sin(2.0 * kPi / SEG)));
    // Every strut is written a little longer than its bar (MeshSpec::strut_reach_mm): each end is carried on along the
    // bar's own line, so a strut that ends on solid is fused into it across the open space's last column.
    reach = spec.strut_reach_mm < 0.0 ? 0.5 * kept.pitch_mm + kept.grow_mm + 0.05 : spec.strut_reach_mm;
    // O11: the blended foot, only where a weave bar runs into the solid. With f = 0 or no weave region: nothing here.
    if (spec.weave_foot_mm != 0.0)
      for (const Layout::Weave& w : lay.weave) foot_regions.push_back(w.region);
    if (!foot_regions.empty()) wall_at = std::make_unique<const SolidAt>(lay);
    // O14: a weave's shallow struts are written with a round top (a D section) when asked; cube-lattice bridges never.
    if (spec.weave_round_top)
      for (const Layout::Weave& w : lay.weave) round_top_regions.push_back(w.region);
    HALF = std::max(2, SEG / 2);   // the half round's flat facets: half a round strut's sides
    if (wall_at) wall_probe.emplace(domain.probe());
  }
  // The D section in a bridge's frame, at `at`: its underside at up = -r from the bar's line, `half` either side, its
  // sides straight up to the line, its top a half round of radius `half` about the line (corners on the round).
  void d_section(std::vector<manifold::vec3>& pts, const Vec3& at, const Vec3& side, const Vec3& up, double r, double half) const {
    auto put = [&](double s, double v) {
      pts.push_back(mv(Vec3{at.x + side.x * s + up.x * v, at.y + side.y * s + up.y * v, at.z + side.z * s + up.z * v}));
    };
    put(-half, -r);
    put(half, -r);
    for (int k = 0; k <= HALF; ++k) {
      const double t = kPi * k / HALF;
      put(half * std::cos(t), half * std::sin(t));
    }
  }
  // The D section's area: the straight lower half and the faceted half round.
  double d_area(double r, double half) const { return 2.0 * half * r + 0.5 * HALF * half * half * std::sin(kPi / HALF); }
  // `want_bar`: the strut itself (counted in rep.bars, its middle in `centres`); `want_feet`: its feet. False for a bar
  // of no length (nothing is written).
  // `fine` (2026-11-24, every strut type): a round strut at a joint where a level bar (a bridge's square bar) meets a
  // VERTICAL one, written with kFineSides sides: with the usual twelve, Manifold's union of the square bar, the 12-sided
  // leg beside it and the column left a thin web hanging into the cell (fccz's coupon: three mid-air starts the print
  // loop could not clear). No octet strut is vertical, so no octet joint is one of these: its file is as it was.
  bool add(const Bar& x, bool want_bar, bool want_feet, std::vector<Manifold>& solids, std::vector<Vec3>& centres,
           MeshReport& rep, bool fine = false) {
    const double r = 0.5 * x.width;
    Vec3 d{x.b.x - x.a.x, x.b.y - x.a.y, x.b.z - x.a.z};
    const double len = std::sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
    if (len < 1e-9) return false;
    d = {d.x / len, d.y / len, d.z / len};
    // An end ON the part's surface runs past it (the part cuts it flush); every other
    // end gets a ball, so bars meeting at any angle close up, and runs on by `reach`.
    const double pa = x.end_a == Bar::End::Surface ? std::max(2.0 * r + 0.3, reach) : reach;
    const double pb = x.end_b == Bar::End::Surface ? std::max(2.0 * r + 0.3, reach) : reach;
    const Vec3 a{x.a.x - d.x * pa, x.a.y - d.y * pa, x.a.z - d.z * pa};
    const bool round_top = bar_is_bridge(x, spec.bridge_rise) && in_regions(round_top_regions, x.region);
    if (want_bar) {
      if (round_top) {
        // O14: a weave's shallow strut, its underside the square bar's exactly (the same frame, the same plane, the
        // same width), its top a half round: a D section from end to end.
        Vec3 side{-d.y, d.x, 0.0};
        const double ls = std::sqrt(side.x * side.x + side.y * side.y);
        side = {side.x / ls, side.y / ls, 0.0};
        Vec3 up{d.y * side.z - d.z * side.y, d.z * side.x - d.x * side.z, d.x * side.y - d.y * side.x};
        if (up.z < 0) { up = {-up.x, -up.y, -up.z}; side = {-side.x, -side.y, 0.0}; }
        const Vec3 b{x.b.x + d.x * pb, x.b.y + d.y * pb, x.b.z + d.z * pb};
        std::vector<manifold::vec3> pts;
        d_section(pts, a, side, up, r, r);
        d_section(pts, b, side, up, r, r);
        solids.push_back(Manifold::Hull(pts));
        ++rep.bridges;
      } else if (bar_is_bridge(x, spec.bridge_rise)) {
        // A strut that lies flat (under 30 degrees) is printed as a BRIDGE: a square bar as
        // wide and as tall as the strut, its underside level and flat, so the first layer
        // across the gap is one straight full-width line and not the belly of a round bar.
        Vec3 side{-d.y, d.x, 0.0};
        const double ls = std::sqrt(side.x * side.x + side.y * side.y);
        side = {side.x / ls, side.y / ls, 0.0};
        Vec3 up{d.y * side.z - d.z * side.y, d.z * side.x - d.x * side.z, d.x * side.y - d.y * side.x};
        if (up.z < 0) { up = {-up.x, -up.y, -up.z}; side = {-side.x, -side.y, 0.0}; }
        solids.push_back(Manifold::Cube({2.0 * r, 2.0 * r, len + pa + pb})
                             .Translate({-r, -r, 0.0})
                             .Transform(manifold::mat3x4(mv(side), mv(up), mv(d), mv(a))));
        ++rep.bridges;
      } else {
        const Vec3 ref = std::fabs(d.x) < 0.9 ? Vec3{1, 0, 0} : Vec3{0, 1, 0};
        Vec3 e1{d.y * ref.z - d.z * ref.y, d.z * ref.x - d.x * ref.z, d.x * ref.y - d.y * ref.x};
        const double l1 = std::sqrt(e1.x * e1.x + e1.y * e1.y + e1.z * e1.z);
        e1 = {e1.x / l1, e1.y / l1, e1.z / l1};
        const Vec3 e2{d.y * e1.z - d.z * e1.y, d.z * e1.x - d.x * e1.z, d.x * e1.y - d.y * e1.x};
        const int sides = fine ? std::max(SEG, kFineSides) : SEG;
        const double round = fine ? std::sqrt(2.0 * kPi / (sides * std::sin(2.0 * kPi / sides))) : kRound;
        solids.push_back(Manifold::Cylinder(len + pa + pb, r * round, r * round, sides)
                             .Transform(manifold::mat3x4(mv(e1), mv(e2), mv(d), mv(a))));
      }
      ++rep.bars;
      centres.push_back({0.5 * (x.a.x + x.b.x), 0.5 * (x.a.y + x.b.y), 0.5 * (x.a.z + x.b.z)});
    }
    // O11: a foot at each end of a weave bar that runs into the solid.
    if (want_feet && wall_at && in_regions(foot_regions, x.region))
      for (int e = 0; e < 2; ++e) {
        if ((e == 0 ? x.end_a : x.end_b) != Bar::End::Solid) continue;
        const Vec3 E = e == 0 ? x.a : x.b;
        const double sg = e == 0 ? 1.0 : -1.0;   // along d, from the end into the bar
        const Vec3 u{d.x * sg, d.y * sg, d.z * sg};
        double f = spec.weave_foot_mm < 0.0 ? r : spec.weave_foot_mm;
        if (f > r) { f = r; ++rep.feet_held; }
        // Where it meets the wall: the first point back from the end, along the bar, that is not solid (as the end
        // was tagged: SolidAt, or outside the part). Not found within twice its width and a half millimetre: one
        // width back (S11's run-in).
        auto solid_here = [&](double t) {
          const Vec3 p{E.x + u.x * t, E.y + u.y * t, E.z + u.z * t};
          const Where w = wall_probe->where(p);
          return w.why != Why::Outside && (*wall_at)(*wall_probe, p, w);
        };
        double tw = std::min(x.width, len);
        {
          const double most = std::min(len, 2.0 * x.width + 0.5);
          double in = 0.0;
          bool found = false;
          for (double t = 0.0; t <= most + 1e-12; t += 0.05) {
            if (!solid_here(t)) { found = true; tw = t; break; }
            in = t;
          }
          if (found && tw > 0.0) {
            double out = tw;
            for (int k = 0; k < 14; ++k) {
              const double m = 0.5 * (in + out);
              if (solid_here(m)) in = m; else out = m;
            }
            tw = out;
          }
        }
        // The taper: 3 f, never past the bar's other end.
        const double L = std::min(3.0 * f, len - tw);
        if (!(L > 1e-6)) continue;
        const double g = 1.0 - L / (3.0 * f);   // the share of f left where the taper stops (0 unless cut short)
        const Vec3 W{E.x + u.x * tw, E.y + u.y * tw, E.z + u.z * tw};
        const double run = tw + (e == 0 ? pa : pb);   // from the wall on into the solid, as far as the strut runs
        const Vec3 deep{W.x - u.x * run, W.y - u.y * run, W.z - u.z * run};
        // Added between the wall and the taper's end, less the strut there (Simpson: the area is quadratic in s).
        auto added = [&](double area0, double areaM, double areaL, double strut) {
          return L / 6.0 * (area0 + 4.0 * areaM + areaL) - strut * L;
        };
        if (round_top) {
          // O14 with O11: the D section widened by f each side and f upward (its round's radius r + f), the
          // underside (up = -r) kept exactly, in the same straight tapers as the square bar's foot.
          Vec3 side{-d.y, d.x, 0.0};
          const double ls = std::sqrt(side.x * side.x + side.y * side.y);
          side = {side.x / ls, side.y / ls, 0.0};
          Vec3 up{d.y * side.z - d.z * side.y, d.z * side.x - d.x * side.z, d.x * side.y - d.y * side.x};
          if (up.z < 0) up = {-up.x, -up.y, -up.z};
          std::vector<manifold::vec3> pts;
          d_section(pts, deep, side, up, r, r + f);
          d_section(pts, W, side, up, r, r + f);
          d_section(pts, Vec3{W.x + u.x * L, W.y + u.y * L, W.z + u.z * L}, side, up, r, r + f * g);
          solids.push_back(Manifold::Hull(pts));
          rep.feet_mm3 += added(d_area(r, r + f), d_area(r, r + f * (1.0 + g) * 0.5), d_area(r, r + f * g), d_area(r, r));
        } else if (bar_is_bridge(x, spec.bridge_rise)) {
          // The bridge's own frame, as above; its underside (up = -r) is kept exactly.
          Vec3 side{-d.y, d.x, 0.0};
          const double ls = std::sqrt(side.x * side.x + side.y * side.y);
          side = {side.x / ls, side.y / ls, 0.0};
          Vec3 up{d.y * side.z - d.z * side.y, d.z * side.x - d.x * side.z, d.x * side.y - d.y * side.x};
          if (up.z < 0) up = {-up.x, -up.y, -up.z};
          std::vector<manifold::vec3> pts;
          auto section = [&](const Vec3& at, double grow) {
            for (int q = 0; q < 4; ++q) {
              const double s = (q & 1) ? r + grow : -(r + grow), v = (q & 2) ? r + grow : -r;
              pts.push_back(mv(Vec3{at.x + side.x * s + up.x * v, at.y + side.y * s + up.y * v, at.z + side.z * s + up.z * v}));
            }
          };
          section(deep, f);
          section(W, f);
          section(Vec3{W.x + u.x * L, W.y + u.y * L, W.z + u.z * L}, f * g);
          solids.push_back(Manifold::Hull(pts));
          auto area = [&](double grow) { return (2.0 * r + 2.0 * grow) * (2.0 * r + grow); };
          rep.feet_mm3 += added(area(f), area(f * (1.0 + g) * 0.5), area(f * g), 4.0 * r * r);
        } else {
          // The strut's own frame, as above, so the cone's sides meet the strut's.
          const Vec3 ref = std::fabs(d.x) < 0.9 ? Vec3{1, 0, 0} : Vec3{0, 1, 0};
          Vec3 e1{d.y * ref.z - d.z * ref.y, d.z * ref.x - d.x * ref.z, d.x * ref.y - d.y * ref.x};
          const double l1 = std::sqrt(e1.x * e1.x + e1.y * e1.y + e1.z * e1.z);
          e1 = {e1.x / l1, e1.y / l1, e1.z / l1};
          const Vec3 e2{d.y * e1.z - d.z * e1.y, d.z * e1.x - d.x * e1.z, d.x * e1.y - d.y * e1.x};
          const double rw = (r + f) * kRound, rt = (r + f * g) * kRound;
          Manifold cone, in;
          if (e == 0) {
            cone = Manifold::Cylinder(L, rw, rt, SEG).Transform(manifold::mat3x4(mv(e1), mv(e2), mv(d), mv(W)));
            in = Manifold::Cylinder(run, rw, rw, SEG).Transform(manifold::mat3x4(mv(e1), mv(e2), mv(d), mv(deep)));
          } else {
            const Vec3 top{W.x + u.x * L, W.y + u.y * L, W.z + u.z * L};
            cone = Manifold::Cylinder(L, rt, rw, SEG).Transform(manifold::mat3x4(mv(e1), mv(e2), mv(d), mv(top)));
            in = Manifold::Cylinder(run, rw, rw, SEG).Transform(manifold::mat3x4(mv(e1), mv(e2), mv(d), mv(W)));
          }
          solids.push_back(Manifold::Hull(std::vector<Manifold>{cone, in}));
          auto area = [&](double grow) { return kPi * (r + grow) * (r + grow); };
          rep.feet_mm3 += added(area(f), area(f * (1.0 + g) * 0.5), area(f * g), kPi * r * r);
        }
        centres.push_back(W);
        ++rep.feet;
      }
    return true;
  }
};
}  // namespace

double strut_run_on_mm(const Carved& carved, const MeshSpec& spec) {
  if (spec.strut_reach_mm >= 0.0) return spec.strut_reach_mm;
  const CarvedSolids* kept = carved.kept ? static_cast<const CarvedSolids*>(carved.kept.get()) : nullptr;
  return kept ? 0.5 * kept->pitch_mm + kept->grow_mm + 0.05 : 0.5 * 0.25 + 0.02 + 0.05;
}

// -- SHEETS (notes28 sheets SPEC section 4) --------------------------------------------------------------------
namespace {
// A sheet block's cells, as many a side as fit in this (and never fewer than two): the block is contoured with one
// ring of cells round it and cut at its own box grown by the run-on, so two blocks overlap and are joined by Manifold
// without a seam (a block cut flush at a cell face would meet its neighbour face to face).
constexpr double kSheetBlockMm = 30.0;
// How far a block's sheet runs past its own box into its neighbours' (beyond the run-on): the two overlap by this.
constexpr double kSheetBlockOverlapMm = 0.05;

Manifold manifold_of(const TriangleMesh& soup_or_mesh, const Frame* frame) {
  // Corners at one place are one corner (generate_tpms writes each triangle's own three); turned into the part.
  manifold::MeshGL64 g;
  g.numProp = 3;
  std::map<std::array<double, 3>, std::uint64_t> at;
  std::vector<std::uint64_t> idx(soup_or_mesh.vertices.size());
  for (std::size_t v = 0; v < soup_or_mesh.vertices.size(); ++v) {
    const Vec3& q = soup_or_mesh.vertices[v];
    const auto it = at.emplace(std::array<double, 3>{q.x, q.y, q.z}, at.size());
    idx[v] = it.first->second;
    if (it.second) {
      const Vec3 p = frame ? frame->at(q.x, q.y, q.z) : q;
      g.vertProperties.push_back(p.x);
      g.vertProperties.push_back(p.y);
      g.vertProperties.push_back(p.z);
    }
  }
  for (const auto& t : soup_or_mesh.triangles) {
    const std::uint64_t a = idx[static_cast<std::size_t>(t[0])], b = idx[static_cast<std::size_t>(t[1])],
                        c = idx[static_cast<std::size_t>(t[2])];
    if (a == b || b == c || a == c) continue;
    g.triVerts.push_back(a);
    g.triVerts.push_back(b);
    g.triVerts.push_back(c);
  }
  return Manifold(g);
}

std::shared_ptr<CarvedSolids::SheetsMade> make_sheets(const Domain& domain, const Layout& lay, const CarvedSolids& kept,
                                                      const MeshSpec& spec, double run_on) {
  const auto t0 = std::chrono::steady_clock::now();
  auto made = std::make_shared<CarvedSolids::SheetsMade>();
  made->key = spec.sheets;
  made->seams_key = spec.sheet_seams ? spec.sheet_seams->size() : 0;
  const std::vector<SheetField>& sheets = *spec.sheets;
  const double dev = std::max(0.0, spec.sheet_deviation_mm);   // 0: the mesh as contoured
  struct Job {
    std::size_t field = 0;
    long long b[3] = {0, 0, 0};   // the block's first and last grid index (cells laid) along each axis
    long long e[3] = {0, 0, 0};
  };
  std::vector<Job> jobs;
  for (std::size_t fi = 0; fi < sheets.size(); ++fi) {
    const SheetField& f = sheets[fi];
    if (!(f.cell_mm > 0.0)) continue;
    const int k = std::max(2, static_cast<int>(std::floor(kSheetBlockMm / f.cell_mm + 0.5)));
    // Each block: the laid cells' own extent inside it (a block is never contoured past the cells it holds).
    std::map<std::array<long long, 3>, std::array<long long, 6>> blocks;   // ordered: the same jobs every run
    for (const Cell& c : lay.cells) {
      if (c.region != f.region || c.frame != f.frame) continue;
      std::array<long long, 3> b{}, i{};
      for (int a = 0; a < 3; ++a) {
        i[static_cast<std::size_t>(a)] = std::llround((c.lo[a] - f.anchor[a]) / f.cell_mm);
        b[static_cast<std::size_t>(a)] = static_cast<long long>(std::floor(static_cast<double>(i[static_cast<std::size_t>(a)]) / k)) * k;
      }
      const auto it = blocks.find(b);
      if (it == blocks.end()) {
        blocks.emplace(b, std::array<long long, 6>{i[0], i[1], i[2], i[0], i[1], i[2]});
      } else {
        for (int a = 0; a < 3; ++a) {
          it->second[static_cast<std::size_t>(a)] = std::min(it->second[static_cast<std::size_t>(a)], i[static_cast<std::size_t>(a)]);
          it->second[static_cast<std::size_t>(a + 3)] = std::max(it->second[static_cast<std::size_t>(a + 3)], i[static_cast<std::size_t>(a)]);
        }
      }
    }
    for (const auto& kv : blocks)
      jobs.push_back({fi, {kv.second[0], kv.second[1], kv.second[2]}, {kv.second[3], kv.second[4], kv.second[5]}});
  }
  // Each frame's open boxes, by frame.
  std::map<int, std::vector<const OpenSpace::Box*>> boxes_of;
  for (const OpenSpace::Box& b : kept.open_boxes) boxes_of[b.frame].push_back(&b);

  std::vector<Manifold> pieces(jobs.size());
  std::vector<std::size_t> tris(jobs.size(), 0);
  std::vector<double> devs(jobs.size(), 0.0);
  std::vector<std::string> whys(jobs.size());
  std::atomic<std::size_t> next{0};
  const std::atomic<bool>* stop = spec.stop;
  auto work = [&] {
    for (;;) {
      const std::size_t j = next.fetch_add(1);
      if (j >= jobs.size() || asked(stop)) break;
      const Job& job = jobs[j];
      const SheetField& f = sheets[job.field];
      const Frame& fr = lay.frames[static_cast<std::size_t>(f.frame)];
      const double L = f.cell_mm;
      const LatticeTopology topo = sheet_topology(f.kind);
      double lo[3], hi[3];
      for (int a = 0; a < 3; ++a) {
        lo[a] = f.anchor[a] + static_cast<double>(job.b[a]) * L;
        hi[a] = f.anchor[a] + static_cast<double>(job.e[a] + 1) * L;
      }
      // The DC cell: a third of the thinnest wall (the old run's), and never coarser than a 24th of the cell. Coarser, the
      // contouring misses the sheet's own curve and the bounded simplifier refines what it left without end, and not
      // the same way twice (measured, gyroid in an 8 mm cell: at the open look's 1.65 mm wall a third of it is 0.55 mm,
      // 4k triangles contoured and 2k to 107k out for walls 0.003 mm apart; at 0.33 mm 12.7k in and 2.6k out, steady).
      const double h = std::max(1e-3, std::min(f.wall_min_mm / 3.0, L / 24.0));
      const double g = run_on + kSheetBlockOverlapMm;           // the block's own sheet runs this far past its box
      TpmsRegion R;
      R.anchor = {lo[0] - L, lo[1] - L, lo[2] - L};
      R.nx = static_cast<int>(job.e[0] - job.b[0]) + 3;
      R.ny = static_cast<int>(job.e[1] - job.b[1]) + 3;
      R.nz = static_cast<int>(job.e[2] - job.b[2]) + 3;
      R.cell_mm = L;
      // Lipschitz-1, positive inside the block's box grown by g (and by h: the generator erodes its clip by one DC cell).
      const double cl[3] = {lo[0] - g - h, lo[1] - g - h, lo[2] - g - h}, ch[3] = {hi[0] + g + h, hi[1] + g + h, hi[2] + g + h};
      R.clip = [cl, ch](const Vec3& q) {
        return std::min({q.x - cl[0], ch[0] - q.x, q.y - cl[1], ch[1] - q.y, q.z - cl[2], ch[2] - q.z});
      };
      // The floor (two lines, SPEC 2): the file never cuts a wall below it. The generator's bead guard lets the mesh sit
      // up to `max_in` = half the wall's margin over the bead inside the true surface; at a margin near 0 its simplifier
      // refines without end (measured: a 0.905 mm wall over a 0.9 mm bead, 6.5 s and 39k triangles a cell against 2.4 s
      // and 2.9k at 0.92; at 0.9 it did not finish). So within two bounds of the floor the wall is contoured raised,
      // by the bound at the floor to nothing two bounds above it: the guard's inward margin is then at least half the
      // bound everywhere, and the thinnest the mesh can be is the floor exactly.
      const double floor_mm = lay.min_strut_mm;
      const auto raised = [floor_mm, dev](double w) {
        return dev > 0.0 ? w + dev * std::clamp(1.0 - (w - floor_mm) / (2.0 * dev), 0.0, 1.0) : w;
      };
      TpmsWallField W;
      W.field = [&f, topo, L, raised](const Vec3& q) {
        return lattice_sheet_wall_param_mm(topo, raised(sheet_wall_at_local(f, q)), L);
      };
      TpmsGenOptions o;
      o.min_wall_mm = f.wall_min_mm;
      o.dc_cell_mm = h;
      o.max_deviation_mm = dev;
      o.bead_mm = floor_mm;
      o.true_wall_mm = [&f, raised](const Vec3& q) { return raised(sheet_wall_at_local(f, q)); };
      o.wall_param_of = [topo, L](double w) { return lattice_sheet_wall_param_mm(topo, w, L); };
      o.true_wall_steps = false;   // the wall is blended trilinearly: no step anywhere (SPEC 1.4)
      MeshSink sink;
      TpmsGenStats st;
      try {
        st = generate_tpms(f.kind, R, W, sink, o);
      } catch (const std::exception& e) {
        whys[j] = std::string("a sheet block could not be contoured: ") + e.what();
        continue;
      }
      tris[j] = sink.mesh.triangles.size();
      devs[j] = st.simplified ? std::max(st.simplify.max_out_measured_mm, st.simplify.max_in_measured_mm) : 0.0;
      if (sink.mesh.triangles.empty()) continue;
      Manifold sheet = manifold_of(sink.mesh, &fr);
      sink.mesh = TriangleMesh{};
      if (sheet.Status() != Manifold::Error::NoError) {
        whys[j] = "a sheet block's surface is not closed";
        continue;
      }
      // The region's open space near the block, each box grown by the run-on.
      std::vector<Manifold> cut;
      const auto it = boxes_of.find(f.frame);
      if (it != boxes_of.end())
        for (const OpenSpace::Box* b : it->second) {
          bool meets = true;
          for (int a = 0; a < 3 && meets; ++a) meets = b->lo[a] - run_on < ch[a] && b->hi[a] + run_on > cl[a];
          if (!meets) continue;
          cut.push_back(Manifold::Cube({b->hi[0] - b->lo[0] + 2 * run_on, b->hi[1] - b->lo[1] + 2 * run_on,
                                        b->hi[2] - b->lo[2] + 2 * run_on})
                            .Translate({b->lo[0] - run_on, b->lo[1] - run_on, b->lo[2] - run_on})
                            .Transform(manifold::mat3x4(mv(fr.ax[0]), mv(fr.ax[1]), mv(fr.ax[2]), mv(fr.origin))));
        }
      if (cut.empty()) continue;
      const Manifold open = Manifold::BatchBoolean(cut, manifold::OpType::Add);
      pieces[j] = fresh((sheet ^ open) ^ kept.part);
    }
  };
  const int nt = static_cast<int>(std::min<std::size_t>(static_cast<std::size_t>(thread_count(spec.threads)), std::max<std::size_t>(1, jobs.size())));
  std::vector<std::thread> pool;
  for (int t = 1; t < nt; ++t) pool.emplace_back(work);
  work();
  for (std::thread& t : pool) t.join();
  check(stop);
  for (std::size_t j = 0; j < jobs.size(); ++j) {
    made->triangles += tris[j];
    made->deviation_mm = std::max(made->deviation_mm, devs[j]);
    if (!whys[j].empty() && made->why.empty()) made->why = whys[j];
  }
  made->blocks = jobs.size();
  for (const Job& job : jobs)
    made->places += static_cast<std::size_t>((job.e[0] - job.b[0] + 1) * (job.e[1] - job.b[1] + 1) * (job.e[2] - job.b[2] + 1));
  // E's blend bands (SPEC 1.5): each seam asked as a blend and not fallen back.
  if (spec.sheet_seams)
    for (const SheetSeamBand& seam : *spec.sheet_seams) {
      if (seam.solid_wall) continue;
      const SeamBand band = mesh_sheet_seam_band(domain, lay, sheets, seam, spec);
      if (!band.ok || band.mesh.triangles.empty()) { ++made->seams_fell_back; continue; }
      const Manifold m = manifold_of(band.mesh, nullptr);
      if (m.Status() != Manifold::Error::NoError) { ++made->seams_fell_back; continue; }
      pieces.push_back(fresh(m ^ kept.part));
      ++made->seams_blended;
    }
  if (!made->why.empty()) {
    made->ok = false;
    made->ms = ms_since(t0);
    return made;
  }
  std::vector<Manifold> some;
  for (Manifold& m : pieces)
    if (!m.IsEmpty()) some.push_back(std::move(m));
  pieces.clear();
  made->body = some.empty() ? Manifold() : fresh(Manifold::BatchBoolean(some, manifold::OpType::Add));
  if (made->body.Status() != Manifold::Error::NoError) {
    made->why = "joining the sheet blocks failed";
    made->ms = ms_since(t0);
    return made;
  }
  made->mm3 = made->body.Volume();
  made->ok = true;
  made->ms = ms_since(t0);
  return made;
}
}  // namespace

void weave_bar_shells(const Domain& domain, const Layout& lay, const Bars& bars, const std::vector<char>& strut,
                      const std::vector<char>& feet, const Carved& carved, const MeshSpec& spec, TriangleMesh& out,
                      std::vector<std::size_t>& first_tri, MeshReport& rep) {
  CarvedSolids none;
  const CarvedSolids& kept = carved.kept ? *static_cast<const CarvedSolids*>(carved.kept.get()) : none;
  StrutMaker maker(domain, lay, spec, kept);
  std::vector<Manifold> solids;
  std::vector<Vec3> centres;
  auto put = [&](const Manifold& m) {
    const manifold::MeshGL64 g = m.GetMeshGL64();
    if (g.NumTri() == 0) return;
    const int base = static_cast<int>(out.vertices.size());
    first_tri.push_back(out.triangles.size());
    for (std::size_t v = 0; v < g.NumVert(); ++v)
      out.vertices.push_back({g.vertProperties[v * g.numProp], g.vertProperties[v * g.numProp + 1], g.vertProperties[v * g.numProp + 2]});
    for (std::size_t t = 0; t < g.NumTri(); ++t)
      out.triangles.push_back({base + static_cast<int>(g.triVerts[3 * t]), base + static_cast<int>(g.triVerts[3 * t + 1]),
                               base + static_cast<int>(g.triVerts[3 * t + 2])});
  };
  for (std::size_t i = 0; i < bars.bars.size(); ++i) {
    const bool s = i < strut.size() && strut[i], f = i < feet.size() && feet[i];
    if (!s && !f) continue;
    maker.add(bars.bars[i], s, f, solids, centres, rep);
    for (const Manifold& m : solids) put(m);
    solids.clear();
    check(spec.stop);
  }
  // The posts, as build_mesh writes them.
  for (const MeshSpec::Post& p : spec.posts) {
    if (!(p.z_top > p.z_bottom)) continue;
    const double w = spec.post_mm;
    put(Manifold::Cube({w, w, p.z_top - p.z_bottom + 0.5}).Translate({p.x - 0.5 * w, p.y - 0.5 * w, p.z_bottom - 0.25}));
    ++rep.posts;
    rep.posts_mm += p.z_top - p.z_bottom;
  }
}

TriangleMesh build_mesh(const PartMeasure& pm, const Domain& domain, const Layout& lay, const Bars& all_bars,
                        const Carved& carved, const MeshSpec& spec, MeshReport* report) {
  (void)domain;
  (void)pm;
  MeshReport rep;
  auto fail = [&](const std::string& why) {
    rep.ok = false;
    rep.why = why;
    if (report) *report = rep;
    return TriangleMesh{};
  };
  const std::atomic<bool>* stop = spec.stop;
  check(stop);
  auto t0 = std::chrono::steady_clock::now();
  const int SEG = std::max(3, spec.bar_sides);
  const double kPi = 3.14159265358979323846;
  // A bar of SEG flat sides with the same cross-section AREA as the round strut.
  const double kRound = std::sqrt(2.0 * kPi / (SEG * std::sin(2.0 * kPi / SEG)));

  if (!carved.ok || !carved.kept) return fail(carved.why.empty() ? "the part was not carved before its mesh was asked for" : carved.why);
  const CarvedSolids& kept = *static_cast<const CarvedSolids*>(carved.kept.get());
  const Manifold& part = kept.part;
  rep.part_mm3 = kept.part_mm3;

  // ── the struts ────────────────────────────────────────────────────────────
  // Left out first: every strut whose LOWEST point is at a place the layer check found
  // something starting in mid-air (a strut hanging from above with nothing under its tip).
  // A weave's bar only when its lowest end is not held (O10: bars_present with the weave regions).
  std::vector<int> weave_regions;
  for (const Layout::Weave& w : lay.weave) weave_regions.push_back(w.region);
  std::vector<Bar> bars;
  bars.reserve(all_bars.bars.size());
  std::vector<char> used;
  const std::vector<char> present = bars_present(all_bars, spec.drop_at, weave_regions, spec.layer_mm, &used);
  for (std::size_t i = 0; i < all_bars.bars.size(); ++i) {
    const Bar& x = all_bars.bars[i];
    if (!present[i]) {
      ++rep.bars_left_out;
      rep.bars_left_out_mm += std::sqrt((x.b.x - x.a.x) * (x.b.x - x.a.x) + (x.b.y - x.a.y) * (x.b.y - x.a.y) + (x.b.z - x.a.z) * (x.b.z - x.a.z));
      continue;
    }
    bars.push_back(x);
  }
  for (char u : used) rep.drop_unanswered += !u;
  // The owner's bridge rules for a weave (O6, O7, O9): of what is left, a weave bar held by nothing kept is left out
  // too (weave_holds), never posted instead. No weave region: nothing here.
  if (!weave_regions.empty()) {
    const WeaveHolds holds = weave_holds(all_bars, weave_regions, present, spec.bridge_rise);
    rep.kept_any_length = holds.kept_any_length;
    rep.weave_left_unheld = holds.left_unheld;
    if (holds.left_unheld) {
      bars.clear();
      for (std::size_t i = 0; i < all_bars.bars.size(); ++i)
        if (holds.kept[i]) bars.push_back(all_bars.bars[i]);
    }
  }

  StrutMaker maker(domain, lay, spec, kept);
  Manifold struts;
  {
    std::vector<Manifold> solids;
    solids.reserve(bars.size() * 2);
    std::vector<Vec3> centres;   // where each one is, to join them block by block
    struct Ball { Vec3 at; double r = 0.0; };
    std::map<std::uint64_t, Ball> balls;   // ordered: the same mesh on every run
    // The joints where a level strut (a bridge) and a vertical strut both end (struts of the cells: skin bars, which may
    // stand upright on a wall, and weave bars are not read): their round struts and their ball are written
    // finer (StrutMaker::add, `fine`). A lattice with no vertical strut (the octet) has none, and its mesh is as before.
    std::set<std::uint64_t> fine_joints;
    {
      std::set<std::uint64_t> level, upright;
      for (const Bar& x : bars) {
        const double dx = x.b.x - x.a.x, dy = x.b.y - x.a.y, dz = x.b.z - x.a.z;
        const double len = std::sqrt(dx * dx + dy * dy + dz * dz);
        if (!(len > 0.0) || x.skin || x.net || x.strand >= 0) continue;
        std::set<std::uint64_t>* into = bar_is_bridge(x, spec.bridge_rise) ? &level
                                        : std::fabs(dz) > 0.999 * len         ? &upright
                                                                              : nullptr;
        if (!into) continue;
        into->insert(place_key(x.a));
        into->insert(place_key(x.b));
      }
      for (const std::uint64_t k : level)
        if (upright.count(k)) fine_joints.insert(k);
    }
    for (const Bar& x : bars) {
      const bool fine = !fine_joints.empty() && (fine_joints.count(place_key(x.a)) || fine_joints.count(place_key(x.b)));
      if (!maker.add(x, true, true, solids, centres, rep, fine)) continue;
      const double r = 0.5 * x.width;
      for (int e = 0; e < 2; ++e) {
        if ((e == 0 ? x.end_a : x.end_b) == Bar::End::Surface) continue;
        const Vec3& p = e == 0 ? x.a : x.b;
        Ball& ball = balls[place_key(p)];
        ball.at = p;
        ball.r = std::max(ball.r, r);
      }
    }
    // A post from the first material below, up to what the layer check found starting in
    // mid-air or reaching out held at one end only. It ties it down.
    for (const MeshSpec::Post& p : spec.posts) {
      if (!(p.z_top > p.z_bottom)) continue;
      const double w = spec.post_mm;
      solids.push_back(Manifold::Cube({w, w, p.z_top - p.z_bottom + 0.5}).Translate({p.x - 0.5 * w, p.y - 0.5 * w, p.z_bottom - 0.25}));
      centres.push_back({p.x, p.y, 0.5 * (p.z_top + p.z_bottom)});
      ++rep.posts;
      rep.posts_mm += p.z_top - p.z_bottom;
    }
    for (const auto& kv : balls) {
      if (fine_joints.count(kv.first)) {
        const int sides = std::max(SEG, kFineSides);
        const double round = std::sqrt(2.0 * kPi / (sides * std::sin(2.0 * kPi / sides)));
        solids.push_back(Manifold::Sphere(kv.second.r * round, sides).Translate(mv(kv.second.at)));
      } else {
        solids.push_back(Manifold::Sphere(kv.second.r * kRound, SEG).Translate(mv(kv.second.at)));
      }
      centres.push_back(kv.second.at);
    }
    rep.balls = balls.size();
    check(stop);
    if (!solids.empty()) {
      // Joined block by block on every core, then the blocks joined: the same union, and
      // the memory it takes stays near one block's.
      const double block = spec.block_mm > 0.0 ? spec.block_mm : 12.0;
      std::map<std::array<int, 3>, std::vector<std::size_t>> by_block;
      for (std::size_t i = 0; i < solids.size(); ++i)
        by_block[{static_cast<int>(std::floor(centres[i].x / block)), static_cast<int>(std::floor(centres[i].y / block)),
                  static_cast<int>(std::floor(centres[i].z / block))}].push_back(i);
      std::vector<const std::vector<std::size_t>*> todo;
      for (const auto& kv : by_block) todo.push_back(&kv.second);
      // The fullest blocks first (they take longest); equal ones keep the map's order.
      std::stable_sort(todo.begin(), todo.end(), [](const auto* a, const auto* b) { return a->size() > b->size(); });
      std::vector<Manifold> joined(todo.size());
      std::atomic<std::size_t> next_block{0};
      auto work = [&] {
        for (;;) {
          const std::size_t b = next_block.fetch_add(1);
          if (b >= todo.size() || asked(stop)) break;
          std::vector<Manifold> some;
          some.reserve(todo[b]->size());
          for (std::size_t i : *todo[b]) { some.push_back(solids[i]); solids[i] = Manifold(); }
          // Joined and cut to the part here, on this thread; the bars it came from are let go.
          joined[b] = fresh(Manifold::BatchBoolean(some, manifold::OpType::Add) ^ part);
        }
      };
      const int nt = static_cast<int>(std::min<std::size_t>(static_cast<std::size_t>(thread_count(spec.threads)), todo.size()));
      std::vector<std::thread> pool;
      for (int t = 1; t < nt; ++t) pool.emplace_back(work);
      work();
      for (std::thread& t : pool) t.join();
      check(stop);
      solids.clear();
      solids.shrink_to_fit();
      struts = fresh(Manifold::BatchBoolean(joined, manifold::OpType::Add));
      if (struts.Status() != Manifold::Error::NoError) return fail("joining the struts failed");
    }
  }
  rep.struts_mm3 = struts.Volume();
  rep.ms_struts = ms_since(t0);
  check(stop);

  // ── the part, less the open cell space ────────────────────────────────────
  t0 = std::chrono::steady_clock::now();
  // Carved once (carve_part); here only what the layer check asked to be left out.
  Manifold solid = kept.solid;
  {
    const std::vector<Manifold>& pieces = kept.pieces;
    rep.solid_pieces = pieces.size();
    if (!spec.drop_at.empty()) {
      // A small separate piece of the solid body whose lowest point is one of the mid-air
      // places (a sliver of lattice space no cell holds, hanging from above) is left out.
      std::vector<Manifold> cutters;
      for (const Manifold& piece : pieces) {
        const manifold::Box b = piece.BoundingBox();
        const double v = piece.Volume();
        if (!sliver_dropped(b, v, spec.drop_at)) continue;
        ++rep.slivers_left_out;
        rep.slivers_mm3 += v;
        // Cut it away with its own hull, a hair larger (so no skin of it is left).
        const manifold::vec3 c{0.5 * (b.min.x + b.max.x), 0.5 * (b.min.y + b.max.y), 0.5 * (b.min.z + b.max.z)};
        cutters.push_back(piece.Hull().Translate({-c.x, -c.y, -c.z}).Scale({1.02, 1.02, 1.02}).Translate(c));
      }
      if (!cutters.empty()) solid = fresh(solid - Manifold::BatchBoolean(cutters, manifold::OpType::Add));
    }
  }
  rep.solid_mm3 = solid.Volume();
  rep.ms_solid = ms_since(t0);
  check(stop);

  // -- SHEETS (notes28 sheets SPEC section 4): each field block by block, cut to its region's open space grown by
  // the run-on and to the part, then joined to the solid. Made once for every pass of the make-check-make loop (the
  // carving keeps them); the solid and the sheets joined once too, while nothing of the solid is left out.
  if (spec.sheets && !spec.sheets->empty()) {
    std::shared_ptr<CarvedSolids::SheetsMade> made;
    {
      std::lock_guard<std::mutex> lock(kept.sheets_mu);
      const std::size_t seams_key = spec.sheet_seams ? spec.sheet_seams->size() : 0;
      if (!kept.sheets || kept.sheets->key != spec.sheets || kept.sheets->seams_key != seams_key)
        kept.sheets = make_sheets(domain, lay, kept, spec, strut_run_on_mm(carved, spec));
      made = kept.sheets;
      if (made->ok && !made->joined && spec.drop_at.empty()) {
        const auto tu = std::chrono::steady_clock::now();
        made->with_solid = made->body.IsEmpty() ? kept.solid : fresh(kept.solid + made->body);
        made->joined = true;
        made->ms_union = ms_since(tu);
      }
    }
    check(stop);
    rep.sheet_blocks = made->blocks;
    rep.sheet_triangles = made->triangles;
    rep.sheet_places = made->places;
    rep.sheet_deviation_mm = made->deviation_mm;
    rep.sheet_mm3 = made->mm3;
    rep.ms_sheets = made->ms;
    rep.ms_sheet_union = made->ms_union;
    rep.seams_blended = made->seams_blended;
    rep.seams_fell_back = made->seams_fell_back;
    if (!made->ok) return fail(made->why.empty() ? "the sheets could not be made" : made->why);
    if (spec.drop_at.empty() && made->joined) solid = made->with_solid;
    else if (!made->body.IsEmpty()) solid = fresh(solid + made->body);
    if (solid.Status() != Manifold::Error::NoError) return fail("joining the sheets to the part failed");
  }

  // ── one mesh ──────────────────────────────────────────────────────────────
  t0 = std::chrono::steady_clock::now();
  Manifold whole = struts.IsEmpty() ? solid : solid + struts;
  if (whole.Status() != Manifold::Error::NoError) return fail("joining the struts to the part failed");
  {
    // No edge shorter than the tolerance, no sliver triangles, so nothing collapses when
    // the corners are written as 32-bit numbers.
    const Manifold cleaned = whole.Simplify(spec.clean_mm);
    if (cleaned.Status() == Manifold::Error::NoError && cleaned.NumTri() > 0) whole = cleaned;
  }
  check(stop);
  manifold::MeshGL g = whole.GetMeshGL();
  whole = Manifold();
  struts = Manifold();
  solid = Manifold();   // only the mesh is needed now
  const std::size_t nv = g.NumVert(), nt = g.NumTri();
  auto place = [&](std::uint32_t v) {
    return FloatPlace{g.vertProperties[v * g.numProp], g.vertProperties[v * g.numProp + 1], g.vertProperties[v * g.numProp + 2]};
  };
  {
    // The mesh is closed corner by corner, but two of its surfaces can TOUCH: separate
    // corners at exactly the same place (two solids meeting along a line or at a point).
    // A slicer joins corners by place and then sees an edge with four faces. Every corner
    // that shares its place with another is drawn back into its own solid by a few
    // microns, each by a different distance, so the surfaces part.
    std::unordered_map<FloatPlace, std::vector<std::uint32_t>, FloatPlaceHash> at;
    for (std::uint32_t v = 0; v < nv; ++v) at[place(v)].push_back(v);   // each list in corner order
    std::vector<float> rank(nv, 0.0f);   // 0 = alone at its place
    for (const auto& kv : at)
      if (kv.second.size() > 1) {
        ++rep.touching_places;
        float q = 1.0f;
        for (std::uint32_t v : kv.second) { rank[v] = q; q += 0.6f; }
      }
    if (rep.touching_places) {
      std::vector<double> nrm(3 * nv, 0.0);
      for (std::size_t t = 0; t < nt; ++t) {
        double v[3][3];
        for (int q = 0; q < 3; ++q)
          for (int a = 0; a < 3; ++a) v[q][a] = g.vertProperties[g.triVerts[3 * t + q] * g.numProp + a];
        const double e1[3] = {v[1][0] - v[0][0], v[1][1] - v[0][1], v[1][2] - v[0][2]},
                     e2[3] = {v[2][0] - v[0][0], v[2][1] - v[0][1], v[2][2] - v[0][2]};
        const double n[3] = {e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0]};
        for (int q = 0; q < 3; ++q)
          for (int a = 0; a < 3; ++a) nrm[3 * g.triVerts[3 * t + q] + a] += n[a];
      }
      const double back = spec.part_mm;
      for (std::uint32_t v = 0; v < nv; ++v) {
        if (rank[v] == 0.0f) continue;
        const double l = std::sqrt(nrm[3 * v] * nrm[3 * v] + nrm[3 * v + 1] * nrm[3 * v + 1] + nrm[3 * v + 2] * nrm[3 * v + 2]);
        if (l < 1e-12) { g.vertProperties[v * g.numProp] += static_cast<float>(0.5 * back * rank[v]); continue; }
        for (int a = 0; a < 3; ++a) g.vertProperties[v * g.numProp + a] -= static_cast<float>(back * rank[v] * nrm[3 * v + a] / l);
      }
    }
  }
  // Separate surfaces, counted on the mesh itself: corners at the same place are one corner,
  // triangles that share a corner are one surface. A piece of material that is not the main
  // one is loose (it would print in mid-air) and is left out. A closed space inside the
  // material is one of two things: a speck of air too small to print as a hole (a leftover
  // between a strut and a wall), which is filled, its surface left out; or lattice sealed
  // in behind skins on every side, which is the part's own and stays.
  std::vector<char> skip(nt, 0);
  {
    std::unordered_map<FloatPlace, std::uint32_t, FloatPlaceHash> first_at;
    std::vector<std::uint32_t> same(nv);
    for (std::uint32_t v = 0; v < nv; ++v) same[v] = first_at.emplace(place(v), v).first->second;
    std::vector<std::uint32_t> up(same);
    auto find = [&](std::uint32_t v) {
      v = same[v];
      while (up[v] != v) { up[v] = up[up[v]]; v = up[v]; }
      return v;
    };
    for (std::size_t t = 0; t < nt; ++t) {
      const std::uint32_t a = find(g.triVerts[3 * t]), b = find(g.triVerts[3 * t + 1]), c = find(g.triVerts[3 * t + 2]);
      up[b] = a;
      up[find(c)] = a;
    }
    std::map<std::uint32_t, double> vol;   // ordered: ties are settled the same way every run
    for (std::size_t t = 0; t < nt; ++t) {
      double v[3][3];
      for (int q = 0; q < 3; ++q)
        for (int a = 0; a < 3; ++a) v[q][a] = g.vertProperties[g.triVerts[3 * t + q] * g.numProp + a];
      vol[find(g.triVerts[3 * t])] += (v[0][0] * (v[1][1] * v[2][2] - v[1][2] * v[2][1]) - v[0][1] * (v[1][0] * v[2][2] - v[1][2] * v[2][0]) +
                                       v[0][2] * (v[1][0] * v[2][1] - v[1][1] * v[2][0])) / 6.0;
    }
    std::uint32_t main_piece = 0;
    double biggest = 0.0;
    for (const auto& kv : vol)
      if (kv.second > biggest) { biggest = kv.second; main_piece = kv.first; }
    rep.mm3 = biggest;
    double fill_under = spec.fill_under_mm3;
    if (fill_under < 0.0) {
      double smallest = 0.0;
      for (const Cell& c : lay.cells) smallest = smallest > 0.0 ? std::min(smallest, c.size) : c.size;
      // O2: a weave's smallest spacing stands where a cell's size stands.
      for (const Layout::Weave& w : lay.weave)
        if (w.spacing_mm > 0.0) smallest = smallest > 0.0 ? std::min(smallest, w.spacing_mm) : w.spacing_mm;
      fill_under = std::max(1.0, smallest * smallest * smallest);
    }
    rep.filled_under_mm3 = fill_under;
    std::map<std::uint32_t, char> stays;
    stays[main_piece] = 1;
    for (const auto& kv : vol) {
      if (kv.first == main_piece) continue;
      if (kv.second < 0 && -kv.second >= fill_under) {
        stays[kv.first] = 1;   // sealed lattice: a space inside the part, with its struts
        ++rep.sealed_spaces;
        rep.mm3 += kv.second;
      } else if (kv.second < 0) {
        ++rep.air_pockets;
        rep.air_pockets_mm3 -= kv.second;
      } else if (spec.keep_pieces) {
        stays[kv.first] = 1;   // OF4: a piece of the solid the unmerged tubes tie on
        rep.mm3 += kv.second;
      } else {
        ++rep.loose_bits;
        rep.loose_mm3 += kv.second;
      }
    }
    for (std::size_t t = 0; t < nt; ++t)
      if (!stays.count(find(g.triVerts[3 * t]))) skip[t] = 1;
  }
  // The mesh: corners as they stand (32-bit places), nothing merged; a triangle with two
  // corners at one place is left out.
  TriangleMesh out;
  std::vector<int> moved(nv, -1);
  for (std::size_t t = 0; t < nt; ++t) {
    if (skip[t]) continue;
    const std::uint32_t c[3] = {g.triVerts[3 * t], g.triVerts[3 * t + 1], g.triVerts[3 * t + 2]};
    const FloatPlace p[3] = {place(c[0]), place(c[1]), place(c[2])};
    if (p[0] == p[1] || p[1] == p[2] || p[0] == p[2]) { ++rep.flat_triangles; continue; }
    std::array<int, 3> tri{};
    for (int q = 0; q < 3; ++q) {
      int& m = moved[c[q]];
      if (m < 0) {
        m = static_cast<int>(out.vertices.size());
        out.vertices.push_back(Vec3{p[q].x, p[q].y, p[q].z});
      }
      tri[static_cast<std::size_t>(q)] = m;
    }
    out.triangles.push_back(tri);
  }
  rep.triangles = out.triangles.size();
  rep.ms_finish = ms_since(t0);
  rep.ok = !out.triangles.empty();
  if (!rep.ok) rep.why = "the lattice file came out empty";
  if (report) *report = rep;
  return out;
}

#endif

}  // namespace topopt::lattice_layout
