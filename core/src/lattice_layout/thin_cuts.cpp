// Lattice rebuild, print rule P8 (f): a cut piece of lattice thinner than its own strut, lying against solid, is
// solid. See lattice_layout.hpp (solidify_thin_cuts).
#include "topopt/lattice_layout.hpp"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <thread>

namespace topopt::lattice_layout {
namespace {

// Does the cell's cube lie against solid and not face air? Asked a hair inside its faces, edges and corners and at
// its 27 points, as the laying asks it of a sliver (D14b): no point reads Outside, and at least one reads inside the
// part and lattice of no region (a cap, a skin, the region's edge inside the part). A cube that holds only lattice,
// its own and other regions', is not against solid.
bool against_solid(const Domain::Probe& probe, const Frame& f, const Cell& c) {
  bool solid = false;
  auto look = [&](double a, double b, double cc) {
    const Why why = probe.where(f.at(a, b, cc)).why;
    if (why == Why::Outside) return false;
    if (why != Why::Lattice) solid = true;
    return true;
  };
  const double e[3] = {0.04, 0.5, 0.96};
  for (int k = 0; k < 3; ++k)
    for (int j = 0; j < 3; ++j)
      for (int i = 0; i < 3; ++i) {
        if (i == 1 && j == 1 && k == 1) continue;
        if (!look(c.lo[0] + c.size * e[i], c.lo[1] + c.size * e[j], c.lo[2] + c.size * e[k])) return false;
      }
  for (int k = 0; k < 3; ++k)
    for (int j = 0; j < 3; ++j)
      for (int i = 0; i < 3; ++i)
        if (!look(c.lo[0] + c.size * (1 + 2 * i) / 6.0, c.lo[1] + c.size * (1 + 2 * j) / 6.0,
                  c.lo[2] + c.size * (1 + 2 * k) / 6.0))
          return false;
  return solid;
}

// The cell's own lattice (cell_holds_at: what it takes in from another region counts) along one axis of its frame:
// on each of a 5 x 5 grid of lines through the cube that way, the longest unbroken run of held points, read at steps
// of a quarter of the strut or finer; the largest of those runs. It stops as soon as a run reaches `strut` (the
// piece is then not thin that way) and returns that run.
double thickness_along(const Layout& layout, const Domain::Probe& probe, std::size_t ci, int axis, double strut) {
  const Cell& c = layout.cells[ci];
  const int n = std::max(1, static_cast<int>(std::ceil(c.size / (0.25 * strut) - 1e-9)));
  const double step = c.size / n;
  const int p = (axis + 1) % 3, q = (axis + 2) % 3;
  static const int kOrder[5] = {2, 1, 3, 0, 4};   // the middle line first: a piece that is not thin shows it soonest
  double most = 0.0;
  for (int i : kOrder)
    for (int j : kOrder) {
      double x[3];
      x[p] = c.lo[p] + c.size * (2 * i + 1) / 10.0;
      x[q] = c.lo[q] + c.size * (2 * j + 1) / 10.0;
      int run = 0, longest = 0;
      for (int k = 0; k < n; ++k) {
        x[axis] = c.lo[axis] + step * (k + 0.5);
        if (!cell_holds_at(layout, probe, ci, x[0], x[1], x[2])) { run = 0; continue; }
        longest = std::max(longest, ++run);
        if (longest * step >= strut) return longest * step;
      }
      most = std::max(most, longest * step);
    }
  return most;
}

}  // namespace

std::size_t solidify_thin_cuts(Layout& layout, const Domain& domain, int threads, std::vector<ThinCut>* found) {
  if (found) found->clear();
  const std::size_t total = layout.cells.size();
  if (total == 0) return 0;
  const int thread_count =
      threads > 0 ? threads : std::max(1, static_cast<int>(std::thread::hardware_concurrency()));
  // Per cell: the piece's thickness along its thinnest axis when it is thin, -1 when it is not (or not asked).
  std::vector<double> thin(total, -1.0);
  std::vector<int> thin_axis(total, 0);
  std::atomic<std::size_t> next{0};
  auto work = [&]() {
    const Domain::Probe probe = domain.probe();
    for (std::size_t ci = next.fetch_add(1); ci < total && !domain.stop_asked(); ci = next.fetch_add(1)) {
      const Cell& c = layout.cells[ci];
      if (!c.cut || !(c.strut > 0.0)) continue;
      // Facing air, or lying only against lattice (a seam): left open.
      if (!against_solid(probe, layout.frames[static_cast<std::size_t>(c.frame)], c)) continue;
      double least = c.strut;
      int which = -1;
      for (int axis = 0; axis < 3; ++axis) {
        const double t = thickness_along(layout, probe, ci, axis, c.strut);
        if (t < least) { least = t; which = axis; }
      }
      if (which >= 0) { thin[ci] = least; thin_axis[ci] = which; }
    }
  };
  {
    const int nt = static_cast<int>(std::min<std::size_t>(static_cast<std::size_t>(thread_count), total));
    std::vector<std::thread> pool;
    for (int t = 1; t < nt; ++t) pool.emplace_back(work);
    work();
    for (std::thread& t : pool) t.join();
  }
  domain.check_stop();   // cells left unread

  std::size_t count = 0;
  for (double t : thin) count += t >= 0.0;
  if (count == 0) return 0;   // the layout is left exactly as it was
  // Each thin piece leaves the cells, in cell order, and joins the solid list (D14): lattice space no cell holds is
  // solid, so whoever draws or builds from the layout sees it solid without knowing this rule.
  std::vector<Cell> kept;
  kept.reserve(total - count);
  for (std::size_t ci = 0; ci < total; ++ci) {
    const Cell& c = layout.cells[ci];
    if (thin[ci] < 0.0) { kept.push_back(c); continue; }
    if (found) found->push_back({layout.solid.size(), thin[ci], thin_axis[ci]});
    layout.thin_solid.push_back(static_cast<std::uint32_t>(layout.solid.size()));
    layout.solid.push_back(c);
    // D14c: a sliver, as thick as it is, where a strut needs its own width.
    SolidWhy why;
    why.why = NoCell::Sliver;
    why.have_mm = static_cast<float>(thin[ci]);
    why.need_mm = static_cast<float>(c.strut);
    layout.solid_why.push_back(why);
    for (RegionCells& r : layout.regions)
      if (r.frame == c.frame && r.region == c.region) {
        if (r.cells > 0) --r.cells;
        ++r.solid;
        break;
      }
  }
  layout.cells.swap(kept);
  if (layout.index) layout.index = index_cells(layout, layout.index->pitch);   // cell numbers moved
  return count;
}

}  // namespace topopt::lattice_layout
