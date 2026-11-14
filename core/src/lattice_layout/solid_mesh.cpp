// Lattice rebuild, stage F: the printable mesh made from the layout. See lattice_layout_mesh.hpp.
#include "topopt/lattice_layout_mesh.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <map>
#include <thread>
#include <unordered_map>

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

// One cell's open space, as boxes in its frame.
void open_boxes_of(const Layout& lay, const Domain::Probe& probe, const Cell& c, double pitch,
                   std::vector<OpenSpace::Box>& mine) {
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
  // A column read point by point: every point the cell holds is open.
  auto by_points = [&](int i, int j) {
    for (int z = 0; z < k; ++z)
      if (cell_holds(lay, probe, c, place(i, j, z))) pt(i, j, z) = kSpace | kBox;
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
    // Which cell of the layout this is (read_open_space passes the layout's own cells).
    const Cell* first = lay.cells.data();
    if (&c < first || &c >= first + lay.cells.size()) return;
    const std::size_t self = static_cast<std::size_t>(&c - first);
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
                  if (cell_holds_at(lay, probe, self, c.lo[0] + (u + 0.5) * s, c.lo[1] + (v + 0.5) * s, c.lo[2] + (w + 0.5) * s))
                    o |= kSpace;
                }
                touches = o & kSpace;
              }
          if (touches && !probe.part().inside(place(i, j, z))) pt(i, j, z) |= kBox;
        }
  };
  // Every run of such points down a column is a box.
  auto point_boxes = [&] {
    for (int j = 0; j < k; ++j)
      for (int i = 0; i < k; ++i) {
        int z0 = -1;
        for (int z = 0; z <= k; ++z) {
          const bool on = z < k && (pt(i, j, z) & kBox);
          if (on && z0 < 0) z0 = z;
          if (!on && z0 >= 0) {
            mine.push_back({c.frame, {c.lo[0] + i * s, c.lo[1] + j * s, c.lo[2] + z0 * s},
                            {c.lo[0] + (i + 1) * s, c.lo[1] + (j + 1) * s, c.lo[2] + z * s}});
            z0 = -1;
          }
        }
      }
  };
  if (!walls.flat) {
    // No flat face to read columns from: the cell's own shape point by point.
    for (int j = 0; j < k; ++j)
      for (int i = 0; i < k; ++i) by_points(i, j);
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
        whole = cell_holds(lay, probe, c, f.at(a, b, cz));
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
        if (cell_holds(lay, probe, c, place(i, j, z))) { o.kind = 3; break; }
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
  open_air();
  point_boxes();
}

}  // namespace

OpenSpace read_open_space(const Domain& domain, const Layout& layout, double pitch_mm, int threads,
                          const std::atomic<bool>* stop) {
  const auto t0 = std::chrono::steady_clock::now();
  OpenSpace out;
  out.pitch_mm = pitch_mm > 0.0 ? pitch_mm : 0.25;
  // Each cell on its own, put back in cell order: the same boxes for any number of threads.
  std::vector<std::vector<OpenSpace::Box>> of_cell(layout.cells.size());
  std::atomic<std::size_t> next{0};
  auto work = [&] {
    const Domain::Probe probe = domain.probe();
    for (std::size_t ci = next.fetch_add(1); ci < layout.cells.size() && !asked(stop); ci = next.fetch_add(1))
      open_boxes_of(layout, probe, layout.cells[ci], out.pitch_mm, of_cell[ci]);
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
  out.ms = ms_since(t0);
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
};
}  // namespace

Carved carve_part(const PartMeasure& pm, const Layout& lay, const OpenSpace& open_space, double grow,
                  const std::atomic<bool>* stop) {
  const auto t0 = std::chrono::steady_clock::now();
  Carved out;
  check(stop);
  auto made = std::make_shared<CarvedSolids>();
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
  std::vector<Bar> bars;
  bars.reserve(all_bars.bars.size());
  {
    std::vector<char> used(spec.drop_at.size(), 0);
    for (const Bar& x : all_bars.bars) {
      const double r = 0.5 * x.width;
      const Vec3 d{x.b.x - x.a.x, x.b.y - x.a.y, x.b.z - x.a.z};
      const double l2 = d.x * d.x + d.y * d.y + d.z * d.z;
      bool drop = false;
      for (std::size_t k = 0; k < spec.drop_at.size(); ++k) {
        const Vec3& s = spec.drop_at[k];
        if (std::fabs(std::min(x.a.z, x.b.z) - r - s.z) > 0.45) continue;
        const double t = l2 > 0 ? std::clamp(((s.x - x.a.x) * d.x + (s.y - x.a.y) * d.y + (s.z - x.a.z) * d.z) / l2, 0.0, 1.0) : 0.0;
        const double ex = x.a.x + t * d.x - s.x, ey = x.a.y + t * d.y - s.y, ez = x.a.z + t * d.z - s.z;
        if (std::sqrt(ex * ex + ey * ey + ez * ez) < r + 0.35) { drop = true; used[k] = 1; }
      }
      if (drop) { ++rep.bars_left_out; rep.bars_left_out_mm += std::sqrt(l2); continue; }
      bars.push_back(x);
    }
    for (char u : used) rep.drop_unanswered += !u;
  }

  Manifold struts;
  {
    std::vector<Manifold> solids;
    solids.reserve(bars.size() * 2);
    std::vector<Vec3> centres;   // where each one is, to join them block by block
    struct Ball { Vec3 at; double r = 0.0; };
    std::map<std::uint64_t, Ball> balls;   // ordered: the same mesh on every run
    for (const Bar& x : bars) {
      const double r = 0.5 * x.width;
      Vec3 d{x.b.x - x.a.x, x.b.y - x.a.y, x.b.z - x.a.z};
      const double len = std::sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
      if (len < 1e-9) continue;
      d = {d.x / len, d.y / len, d.z / len};
      // An end ON the part's surface runs past it (the part cuts it flush); every other
      // end gets a ball, so bars meeting at any angle close up.
      const double pa = x.end_a == Bar::End::Surface ? 2.0 * r + 0.3 : 0.0;
      const double pb = x.end_b == Bar::End::Surface ? 2.0 * r + 0.3 : 0.0;
      const Vec3 a{x.a.x - d.x * pa, x.a.y - d.y * pa, x.a.z - d.z * pa};
      if (bar_is_bridge(x, spec.bridge_rise)) {
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
        solids.push_back(Manifold::Cylinder(len + pa + pb, r * kRound, r * kRound, SEG)
                             .Transform(manifold::mat3x4(mv(e1), mv(e2), mv(d), mv(a))));
      }
      ++rep.bars;
      centres.push_back({0.5 * (x.a.x + x.b.x), 0.5 * (x.a.y + x.b.y), 0.5 * (x.a.z + x.b.z)});
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
      solids.push_back(Manifold::Sphere(kv.second.r * kRound, SEG).Translate(mv(kv.second.at)));
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
        bool drop = false;
        if (v < 20.0)
          for (const Vec3& sp : spec.drop_at)
            if (std::fabs(b.min.z - sp.z) < 0.45 && sp.x > b.min.x - 0.4 && sp.x < b.max.x + 0.4 && sp.y > b.min.y - 0.4 &&
                sp.y < b.max.y + 0.4)
              drop = true;
        if (!drop) continue;
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
