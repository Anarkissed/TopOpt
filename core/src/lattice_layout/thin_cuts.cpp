// Lattice rebuild, print rule P8 (f): a cut piece of lattice thinner than its own strut, lying against solid, is
// solid. See lattice_layout.hpp (solidify_thin_cuts).
#include "topopt/lattice_layout.hpp"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <thread>

namespace topopt::lattice_layout {
namespace {

// Does the cell's cube face air? Asked a hair inside its faces, edges and corners and at its 27 points, as the laying
// asks it of a sliver (D14b). These 53 points are also the cube's own sample points (`points`).
const double kHair[3] = {0.04, 0.5, 0.96};
template <class F>
bool each_point(const Cell& c, F f) {   // stops, returning false, when f does
  for (int k = 0; k < 3; ++k)
    for (int j = 0; j < 3; ++j)
      for (int i = 0; i < 3; ++i) {
        if (i == 1 && j == 1 && k == 1) continue;
        if (!f(c.lo[0] + c.size * kHair[i], c.lo[1] + c.size * kHair[j], c.lo[2] + c.size * kHair[k])) return false;
      }
  for (int k = 0; k < 3; ++k)
    for (int j = 0; j < 3; ++j)
      for (int i = 0; i < 3; ++i)
        if (!f(c.lo[0] + c.size * (1 + 2 * i) / 6.0, c.lo[1] + c.size * (1 + 2 * j) / 6.0,
               c.lo[2] + c.size * (1 + 2 * k) / 6.0))
          return false;
  return true;
}
bool faces_air(const Domain::Probe& probe, const Frame& f, const Cell& c) {
  return !each_point(c, [&](double a, double b, double cc) { return probe.where(f.at(a, b, cc)).why != Why::Outside; });
}

// What lies a hair past the end of a run.
enum class Past { Solid, Lattice, Air };
constexpr double kPast = 0.02;   // mm

// One axis of one cell: its own lattice (cell_holds_at: what it takes in from another region counts) along that axis.
struct Axis {
  bool held = false;     // some line found a run of held lattice
  bool thick = false;    // a run reached the strut: not thin this way
  double most = 0.0;     // the longest run, mm
  int lines = 0;         // lines that found a run
  int solid_end = 0;     // ... of which at least one end of the longest run is solid
};

struct Reader {
  const Layout& layout;
  const Domain::Probe& probe;
  std::size_t ci;
  const Cell& c;
  const Frame& f;
  double strut;
  int n;
  double step;

  bool held(const double x[3]) const { return cell_holds_at(layout, probe, ci, x[0], x[1], x[2]); }
  // Between a held place and one that is not, along `axis`: the edge, to a few thousandths of a millimetre.
  double edge(double x[3], int axis, double in, double out) const {
    for (int k = 0; k < 9; ++k) {
      const double m = 0.5 * (in + out);
      x[axis] = m;
      if (held(x)) in = m; else out = m;
    }
    return in;
  }
  Past past(double x[3], int axis, double t) const {
    const double keep = x[axis];
    x[axis] = t;
    const Where w = probe.where(f.at(x[0], x[1], x[2]));
    x[axis] = keep;
    if (w.why == Why::Outside) return Past::Air;
    return w.lattice() ? Past::Lattice : Past::Solid;
  }
  // The run [a, b] on the line `x` (its other two coordinates set) along `axis`, grown from the held place `t` to its
  // edges (or the cube's faces). Adds it to `ax`. Returns false when it reaches the strut (the axis is not thin).
  bool run_from(double x[3], int axis, double t, Axis& ax) const {
    const double lo = c.lo[axis], hi = c.lo[axis] + c.size;
    double a = t, b = t;
    for (;;) {   // down
      const double next = a - step;
      if (next <= lo) { x[axis] = lo + 1e-9 * c.size; a = held(x) ? lo : edge(x, axis, a, lo); break; }
      x[axis] = next;
      if (!held(x)) { a = edge(x, axis, a, next); break; }
      a = next;
    }
    for (;;) {   // up
      const double next = b + step;
      if (next >= hi) { x[axis] = hi - 1e-9 * c.size; b = held(x) ? hi : edge(x, axis, b, hi); break; }
      x[axis] = next;
      if (!held(x)) { b = edge(x, axis, b, next); break; }
      b = next;
    }
    const double len = b - a;
    ax.held = true;
    if (len >= strut) { ax.thick = true; ax.most = std::max(ax.most, len); return false; }
    ax.most = std::max(ax.most, len);
    ++ax.lines;
    if (past(x, axis, a - kPast) == Past::Solid || past(x, axis, b + kPast) == Past::Solid) ++ax.solid_end;
    return true;
  }
  // On the line `x` along `axis`: the longest run of held samples, grown to its true edges. False when it reaches
  // the strut.
  bool line(double x[3], int axis, Axis& ax) const {
    int run = 0, longest = 0, end = -1;
    for (int k = 0; k < n; ++k) {
      x[axis] = c.lo[axis] + step * (k + 0.5);
      if (!held(x)) { run = 0; continue; }
      if (++run > longest) { longest = run; end = k; }
      if (longest * step >= strut) { ax.held = true; ax.thick = true; ax.most = std::max(ax.most, longest * step); return false; }
    }
    if (longest == 0) return true;
    return run_from(x, axis, c.lo[axis] + step * (end + 0.5), ax);
  }
  Axis read(int axis) const {
    Axis ax;
    const int p = (axis + 1) % 3, q = (axis + 2) % 3;
    static const int kOrder[5] = {2, 1, 3, 0, 4};   // the middle line first: a piece that is not thin shows it soonest
    for (int i : kOrder)
      for (int j : kOrder) {
        double x[3];
        x[p] = c.lo[p] + c.size * (2 * i + 1) / 10.0;
        x[q] = c.lo[q] + c.size * (2 * j + 1) / 10.0;
        if (!line(x, axis, ax)) return ax;
      }
    if (ax.held) return ax;
    // A piece the 5 x 5 lines miss: the lines along this axis through each of the cube's own sample points that is
    // held, once per line.
    std::vector<std::pair<double, double>> done;
    each_point(c, [&](double a, double b, double cc) {
      double x[3] = {a, b, cc};
      if (!held(x)) return true;
      for (const auto& d : done)
        if (d.first == x[p] && d.second == x[q]) return true;
      done.emplace_back(x[p], x[q]);
      return run_from(x, axis, x[axis], ax);
    });
    return ax;
  }
};

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
      const Frame& f = layout.frames[static_cast<std::size_t>(c.frame)];
      if (faces_air(probe, f, c)) continue;   // the lattice runs out to an open surface: left open
      // Thin along an axis, and against solid along it: on more than half the lines that found a run, an end of the
      // run lies against solid. A piece between lattice on both sides (a seam between two regions, or two walls of
      // one region) is left open, however thin.
      const int n = std::max(1, static_cast<int>(std::ceil(c.size / (0.25 * c.strut) - 1e-9)));
      const Reader rd{layout, probe, ci, c, f, c.strut, n, c.size / n};
      double least = c.strut;
      int which = -1;
      for (int axis = 0; axis < 3; ++axis) {
        const Axis ax = rd.read(axis);
        if (!ax.held || ax.thick || ax.lines == 0) continue;
        if (2 * ax.solid_end <= ax.lines) continue;
        if (ax.most < least) { least = ax.most; which = axis; }
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
