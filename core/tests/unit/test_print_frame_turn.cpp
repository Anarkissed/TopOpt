// ★ notes29 (P8, his print orientation on the iPad): after he keeps a print orientation, the iPad's Organic preview is
// laid as the print file is (the part standing on the kept face: up IS +Z) and drawn turned back to the part's own
// coordinates (lattice_layout_file.hpp: open_in_print_frame, turn_organic_asks, turn_outcome_to_model,
// turn_preview_to_model, turn_growth_to_model).
//   1  The turns are a rigid motion, exactly inverted: every place and direction of an outcome, a preview and a growth
//      read, turned to the model frame and back, for each of the six axes (with the base's shift), a 45 degree side, an
//      edge and a corner; against a turn written here by hand for +X; off, not a byte moves.
//      RED CONTROL: turned to the model frame twice, it is not the original.
//   2  The turned lay's struts ARE the print file's: a block whose sides all differ, woven under its +X face, laid Grown
//      by the file job with "print_frame": {"up": [1, 0, 0]} (its own lay, as handed to its strength check) and by the
//      iPad's path (the part opened through the same door, its settings and tensor turned, the ask's up +Z, the preview
//      turned back): the same bars, end for end. RED CONTROLS: the old iPad lay (the part as placed, growing along its
//      own +Z) is not the file's; the turned lay NOT turned back is not either.
//   3  The growth runs along the kept up: the pieces the iPad watches, turned back, climb along +X (the kept up).
//      RED CONTROL: the old lay's pieces climb along +Z, not along +X.
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "topopt/face_overrides.hpp"
#include "topopt/lattice_layout_file.hpp"
#include "topopt/lattice_layout_mesh.hpp"
#include "topopt/lattice_layout_organic.hpp"
#include "topopt/print_frame.hpp"
#include "topopt/stl.hpp"

#ifndef TMP_DIR
#define TMP_DIR "."
#endif

using namespace topopt;
using namespace topopt::lattice_layout;

static int g_fail = 0, g_checks = 0;
#define CHECK(cond)                                                                        \
  do {                                                                                     \
    ++g_checks;                                                                            \
    if (!(cond)) { ++g_fail; std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } \
  } while (0)

namespace {

// ── 1. THE TURNS ───────────────────────────────────────────────────────────────────────────────────────────────────

std::uint64_t g_seed = 0x9e3779b97f4a7c15ull;
double rnd(double lo, double hi) {   // a fixed sequence (xorshift), so every run checks the same numbers
  g_seed ^= g_seed << 13;
  g_seed ^= g_seed >> 7;
  g_seed ^= g_seed << 17;
  return lo + (hi - lo) * static_cast<double>(g_seed >> 11) / static_cast<double>(1ull << 53);
}
Vec3 rp() { return {rnd(-20, 40), rnd(-20, 40), rnd(-20, 40)}; }
Vec3 unit(Vec3 v) {
  const double l = std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
  return {v.x / l, v.y / l, v.z / l};
}
Vec3 cross(const Vec3& a, const Vec3& b) { return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}; }
double dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
Vec3 sub(const Vec3& a, const Vec3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
double dist(const Vec3& a, const Vec3& b) { const Vec3 d = sub(a, b); return std::sqrt(dot(d, d)); }
bool same_bits(const Vec3& a, const Vec3& b) { return std::memcmp(&a, &b, sizeof(Vec3)) == 0; }

// An outcome and a preview holding every kind of place the turns move (and what they must not).
OrganicPreview sample() {
  OrganicPreview p;
  Outcome& o = p.outcome;
  for (int i = 0; i < 40; ++i) {
    Bar b;
    b.a = rp();
    b.b = rp();
    b.width = rnd(0.4, 2.0);
    b.cell = rnd(2, 8);
    b.region = i % 3;
    if (i % 2) b.flat = unit({rnd(-1, 1), rnd(-1, 1), rnd(-1, 1)});
    o.bars.bars.push_back(b);
  }
  for (int i = 0; i < 3; ++i) o.bars.cut_in_air.push_back({rp(), i, 4.0});
  for (int i = 0; i < 3; ++i) {   // frames on a random rotation
    Frame f;
    f.origin = rp();
    const Vec3 u = unit({rnd(-1, 1), rnd(-1, 1), rnd(-1, 1)});
    const Vec3 v = unit(cross(u, unit({rnd(-1, 1), rnd(-1, 1), rnd(-1, 1)})));
    f.ax[0] = u;
    f.ax[1] = v;
    f.ax[2] = cross(u, v);
    o.layout.frames.push_back(f);
  }
  for (int i = 0; i < 12; ++i) {
    Cell c;
    c.frame = i % 3;
    c.lo[0] = rnd(-10, 10);
    c.lo[1] = rnd(-10, 10);
    c.lo[2] = rnd(-10, 10);
    c.size = rnd(2, 6);
    o.layout.cells.push_back(c);
  }
  o.layout.index = index_cells(o.layout);
  for (int i = 0; i < 2; ++i) {
    SteppedEdge e;
    e.at = rp();
    e.lo = {-3, -2, -1};
    e.hi = {4, 5, 6};
    e.ends = 3;
    o.stepped_edges.push_back(e);
  }
  for (int i = 0; i < 2; ++i) {
    o.guard.outside_at.push_back(rp());
    o.guard.in_solid_at.push_back(rp());
    o.guard.removed_at.push_back(rp());
    o.relief.thin_zone_solid_dropped_at.push_back(rp());
  }
  for (int q = 0; q < 6; ++q) o.relief.grew_mm[q] = q + 1;
  auto g = std::make_shared<GrowReport>();
  g->wall_refused_at.push_back({rp(), 1});
  GrowReport::Stub s;
  s.root = rp();
  s.top = rp();
  s.pts = {rp(), rp(), rp()};
  g->stubs.push_back(s);
  for (int q = 0; q < 6; ++q) g->face_hits[q] = static_cast<std::size_t>(q + 1);
  o.grown = g;
  for (int r = 0; r < 3; ++r) {
    WeaveRun w;
    w.region = r;
    for (int k = 0; k < 4; ++k) {
      w.points.push_back(rp());
      w.width_mm.push_back(0.9);
      w.spacing_mm.push_back(4.0);
    }
    p.runs.push_back(w);
  }
  p.flat_ends = {rp(), rp()};
  return p;
}

// Every place of two previews, in one list (a, b, origin, ... in a fixed order), and every direction. A stepped edge's box
// is a box round its ends: a general turn gives the box round the turned box (box_to_model), which no turn back undoes,
// so `boxes` false leaves it out (it is checked on its own).
void places(const OrganicPreview& p, std::vector<Vec3>& at, std::vector<Vec3>& dir, bool boxes = true) {
  const Outcome& o = p.outcome;
  for (const Bar& b : o.bars.bars) { at.push_back(b.a); at.push_back(b.b); dir.push_back(b.flat); }
  for (const Bars::CutEnd& c : o.bars.cut_in_air) at.push_back(c.at);
  for (const Frame& f : o.layout.frames) { at.push_back(f.origin); for (const Vec3& a : f.ax) dir.push_back(a); }
  for (const SteppedEdge& e : o.stepped_edges) {
    at.push_back(e.at);
    if (boxes) { at.push_back(e.lo); at.push_back(e.hi); }
  }
  for (const auto* v : {&o.guard.outside_at, &o.guard.in_solid_at, &o.guard.removed_at, &o.relief.thin_zone_solid_dropped_at})
    at.insert(at.end(), v->begin(), v->end());
  for (const auto& w : o.grown->wall_refused_at) at.push_back(w.at);
  for (const auto& s : o.grown->stubs) { at.push_back(s.root); at.push_back(s.top); at.insert(at.end(), s.pts.begin(), s.pts.end()); }
  for (const WeaveRun& r : p.runs) at.insert(at.end(), r.points.begin(), r.points.end());
  at.insert(at.end(), p.flat_ends.begin(), p.flat_ends.end());
}
// What no turn may touch: widths, cells' own corners, counts.
bool rest_same(const OrganicPreview& x, const OrganicPreview& y) {
  bool ok = x.outcome.bars.bars.size() == y.outcome.bars.bars.size() && x.outcome.layout.cells == y.outcome.layout.cells;
  for (std::size_t i = 0; ok && i < x.outcome.bars.bars.size(); ++i)
    ok = x.outcome.bars.bars[i].width == y.outcome.bars.bars[i].width && x.outcome.bars.bars[i].region == y.outcome.bars.bars[i].region;
  for (std::size_t r = 0; ok && r < x.runs.size(); ++r) ok = x.runs[r].width_mm == y.runs[r].width_mm;
  return ok;
}
// The largest distance between matching places, and whether every one is the same to the bit.
double gap(const OrganicPreview& x, const OrganicPreview& y, bool* bits = nullptr, bool boxes = true) {
  std::vector<Vec3> xa, xd, ya, yd;
  places(x, xa, xd, boxes);
  places(y, ya, yd, boxes);
  if (xa.size() != ya.size() || xd.size() != yd.size()) return 1e300;
  double worst = 0.0;
  bool all = true;
  for (std::size_t i = 0; i < xa.size(); ++i) { worst = std::max(worst, dist(xa[i], ya[i])); all = all && same_bits(xa[i], ya[i]); }
  for (std::size_t i = 0; i < xd.size(); ++i) { worst = std::max(worst, dist(xd[i], yd[i])); all = all && same_bits(xd[i], yd[i]); }
  if (bits) *bits = all;
  return worst;
}

void test_turns() {
  const OrganicPreview base = sample();
  // The base's shift: a part whose lowest point along each up is not 0.
  TriangleMesh m;
  m.vertices = {{-7, -3, -5}, {30, 22, 18}, {4, -9, 11}};
  m.triangles = {{0, 1, 2}};
  const Vec3 ups[] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1},
                      {1, 0, 1}, {1, 1, 0}, {1, 1, 1}, {-0.3, 0.8, -0.5}};
  for (const Vec3& up : ups) {
    PrintFrame f;
    CHECK(print_frame_for_up(up, f));
    print_frame_set_base(f, m);
    OrganicPreview p = base;
    turn_preview_to_model(f, p);
    const double moved = gap(p, base);
    // A rigid motion: the length of every bar, and the angle between frame axes, are kept.
    double len = 0.0, ortho = 0.0;
    for (std::size_t i = 0; i < p.outcome.bars.bars.size(); ++i) {
      const Bar& a = p.outcome.bars.bars[i];
      const Bar& b = base.outcome.bars.bars[i];
      len = std::max(len, std::fabs(dist(a.a, a.b) - dist(b.a, b.b)));
    }
    for (const Frame& fr : p.outcome.layout.frames)   // still orthonormal and right-handed (a turn, never a mirror)
      ortho = std::max({ortho, std::fabs(dot(fr.ax[0], fr.ax[1])), std::fabs(dot(fr.ax[1], fr.ax[2])),
                        std::fabs(dot(fr.ax[0], fr.ax[2])), std::fabs(dot(cross(fr.ax[0], fr.ax[1]), fr.ax[2]) - 1.0)});
    // The cells' index is made again in the model frame: the same as one made there.
    const auto again = index_cells(p.outcome.layout, p.outcome.layout.index->pitch);
    const bool index_ok = again->grid == p.outcome.layout.index->grid;
    // A cell's world corner moves with its frame (its own corner does not).
    double corner = 0.0;
    for (std::size_t c = 0; c < base.outcome.layout.cells.size(); ++c) {
      const Cell& cl = base.outcome.layout.cells[c];
      const Vec3 w0 = base.outcome.layout.frames[static_cast<std::size_t>(cl.frame)].at(cl.lo[0], cl.lo[1], cl.lo[2]);
      const Vec3 w1 = p.outcome.layout.frames[static_cast<std::size_t>(cl.frame)].at(cl.lo[0], cl.lo[1], cl.lo[2]);
      corner = std::max(corner, dist(f.point_to_model(w0), w1));
    }
    // Back: the original.
    OrganicPreview q = p;
    turn_preview_to_print(f, q);
    bool bits = false;
    const double back = gap(q, base, &bits, f.exact);
    // A stepped edge's box, turned: the box round its turned corners (exact: the same box, its corners re-sorted).
    bool boxed = true;
    for (std::size_t i = 0; i < base.outcome.stepped_edges.size(); ++i) {
      const SteppedEdge& e0 = base.outcome.stepped_edges[i];
      const SteppedEdge& e1 = p.outcome.stepped_edges[i];
      for (int c = 0; c < 8; ++c) {
        const Vec3 k = f.point_to_model({c & 1 ? e0.hi.x : e0.lo.x, c & 2 ? e0.hi.y : e0.lo.y, c & 4 ? e0.hi.z : e0.lo.z});
        boxed = boxed && k.x >= e1.lo.x - 1e-9 && k.x <= e1.hi.x + 1e-9 && k.y >= e1.lo.y - 1e-9 && k.y <= e1.hi.y + 1e-9 &&
                k.z >= e1.lo.z - 1e-9 && k.z <= e1.hi.z + 1e-9;
      }
      const double v0 = (e0.hi.x - e0.lo.x) * (e0.hi.y - e0.lo.y) * (e0.hi.z - e0.lo.z);
      const double v1 = (e1.hi.x - e1.lo.x) * (e1.hi.y - e1.lo.y) * (e1.hi.z - e1.lo.z);
      boxed = boxed && (f.exact ? std::fabs(v1 - v0) < 1e-9 : v1 >= v0 - 1e-9);
    }
    const bool six_ok = f.exact ? std::equal(std::begin(q.outcome.relief.grew_mm), std::end(q.outcome.relief.grew_mm),
                                             std::begin(base.outcome.relief.grew_mm))
                                : std::equal(std::begin(p.outcome.relief.grew_mm), std::end(p.outcome.relief.grew_mm),
                                             std::begin(base.outcome.relief.grew_mm));
    // The growth's pieces turn as the places do.
    GrowthTap::Read r;
    for (const Bar& b : base.outcome.bars.bars)
      for (const Vec3& v : {b.a, b.b}) {
        r.xyz.push_back(static_cast<float>(v.x));
        r.xyz.push_back(static_cast<float>(v.y));
        r.xyz.push_back(static_cast<float>(v.z));
      }
    turn_growth_to_model(f, r);
    double grow = 0.0;
    for (std::size_t i = 0; i < p.outcome.bars.bars.size(); ++i) {
      const Bar& b = p.outcome.bars.bars[i];
      const Vec3 ga{r.xyz[6 * i], r.xyz[6 * i + 1], r.xyz[6 * i + 2]}, gb{r.xyz[6 * i + 3], r.xyz[6 * i + 4], r.xyz[6 * i + 5]};
      grow = std::max({grow, dist(ga, b.a), dist(gb, b.b)});
    }
    std::printf("turns: up (%g, %g, %g) %s, t.z %g: moved %.3g, lengths %.2g, axes %.2g, corners %.2g, back %.2g%s, "
                "growth %.2g\n", up.x, up.y, up.z, f.exact ? "exact" : "general", f.t.z, moved, len, ortho, corner, back,
                bits ? " (to the bit)" : "", grow);
    CHECK(moved > 1.0);   // it turned (+Z: the base's shift alone, 5 mm)
    CHECK(len < 1e-9 && ortho < 1e-9 && corner < 1e-9);
    CHECK(index_ok);
    CHECK(back < 1e-9);
    CHECK(boxed);
    CHECK(six_ok);
    CHECK(rest_same(p, base) && rest_same(q, base));
    CHECK(grow < 1e-4);   // float32 pieces
    CHECK(q.outcome.grown->face_hits[0] == 1 && q.outcome.grown->face_hits[5] == 6);
  }
  // Against a turn written here by hand: up +X, print = (-z, y, x + t), so model = (q.z - t, q.y, -q.x); a direction
  // (d.z, d.y, -d.x); the six sides (-x, +x, -y, +y, -z, +z) of the print frame are the model's (+z, -z, +y, -y, -x, +x).
  {
    PrintFrame f;
    CHECK(print_frame_for_up({1, 0, 0}, f));
    print_frame_set_base(f, m);
    CHECK(f.exact && f.t.z == 7.0);
    OrganicPreview p = base;
    turn_preview_to_model(f, p);
    double worst = 0.0;
    for (std::size_t i = 0; i < base.outcome.bars.bars.size(); ++i) {
      const Bar& b = base.outcome.bars.bars[i];
      const Bar& t = p.outcome.bars.bars[i];
      const Vec3 ha{b.a.z - 7.0, b.a.y, 0.0 - b.a.x}, hf{b.flat.z, b.flat.y, 0.0 - b.flat.x};
      worst = std::max({worst, dist(ha, t.a), dist(hf, t.flat)});
    }
    const double* g = p.outcome.relief.grew_mm;
    std::printf("by hand (+X): worst %.3g; sides %g %g %g %g %g %g\n", worst, g[0], g[1], g[2], g[3], g[4], g[5]);
    CHECK(worst == 0.0);
    CHECK(g[0] == 5 && g[1] == 6 && g[2] == 3 && g[3] == 4 && g[4] == 2 && g[5] == 1);
    // RED CONTROL: turned to the model frame twice is not the original (the check above can fail).
    OrganicPreview twice = p;
    turn_preview_to_model(f, twice);
    CHECK(gap(twice, base) > 1.0);
  }
  // Off: not a byte moves.
  {
    PrintFrame off;
    OrganicPreview p = base;
    turn_preview_to_model(off, p);
    turn_outcome_to_model(off, p.outcome);
    bool bits = false;
    CHECK(gap(p, base, &bits) == 0.0 && bits);
    CHECK(p.outcome.layout.index == base.outcome.layout.index);   // not even made again
    GrowthTap::Read r;
    r.xyz = {1.5f, -2.25f, 3.0f};
    turn_growth_to_model(off, r);
    CHECK((r.xyz == std::vector<float>{1.5f, -2.25f, 3.0f}));
    OrganicAsk a;
    a.build_dir = {0.3, 0.4, 0.5};
    turn_organic_asks(off, &a, nullptr);
    CHECK(a.build_dir.x == 0.3 && a.build_dir.z == 0.5);
  }
}

// ── 2 and 3. THE PRINT FILE'S LAY AND THE iPAD'S ───────────────────────────────────────────────────────────────────

// A block as an imported model (six flat faces).
StepModel box_model(double x, double y, double z) {
  StepModel m;
  const Vec3 p[8] = {{0, 0, 0}, {x, 0, 0}, {x, y, 0}, {0, y, 0}, {0, 0, z}, {x, 0, z}, {x, y, z}, {0, y, z}};
  const int q[6][4] = {{0, 3, 2, 1}, {4, 5, 6, 7}, {0, 1, 5, 4}, {1, 2, 6, 5}, {2, 3, 7, 6}, {3, 0, 4, 7}};
  const Vec3 out[6] = {{0, 0, -1}, {0, 0, 1}, {0, -1, 0}, {1, 0, 0}, {0, 1, 0}, {-1, 0, 0}};
  for (int f = 0; f < 6; ++f) {
    StepFaceInfo info;
    info.kind = StepSurfaceKind::Plane;
    info.plane_normal = out[f];
    info.plane_origin = p[q[f][0]];
    m.faces.push_back(info);
    for (const int* t : {&q[f][0], &q[f][1]}) {
      const int n = static_cast<int>(m.mesh.vertices.size());
      const bool second = t != &q[f][0];
      m.mesh.vertices.insert(m.mesh.vertices.end(), {p[q[f][0]], p[q[f][second ? 2 : 1]], p[q[f][second ? 3 : 2]]});
      m.mesh.triangles.push_back({n, n + 1, n + 2});
      m.triangle_face.push_back(f);
    }
  }
  m.face_count = 6;
  m.solid_count = 1;
  m.brep_volume = x * y * z;
  return m;
}

// The largest distance between two lists of bars, end for end (1e300 when their counts differ), and the widths.
double bars_gap(const std::vector<Bar>& x, const std::vector<Bar>& y, bool* widths = nullptr) {
  if (x.size() != y.size() || x.empty()) return 1e300;
  double worst = 0.0;
  bool w = true;
  for (std::size_t i = 0; i < x.size(); ++i) {
    worst = std::max({worst, dist(x[i].a, y[i].a), dist(x[i].b, y[i].b)});
    w = w && x[i].width == y[i].width && x[i].region == y[i].region && x[i].end_a == y[i].end_a && x[i].end_b == y[i].end_b;
  }
  if (widths) *widths = w;
  return worst;
}
// The mean climb of growth pieces along `up` (each piece's unit direction), and how many.
double climb(const std::vector<float>& xyz, const Vec3& up, std::size_t* n = nullptr) {
  double sum = 0.0;
  std::size_t k = 0;
  for (std::size_t i = 0; i + 5 < xyz.size(); i += 6) {
    const Vec3 d{static_cast<double>(xyz[i + 3]) - xyz[i], static_cast<double>(xyz[i + 4]) - xyz[i + 1],
                 static_cast<double>(xyz[i + 5]) - xyz[i + 2]};
    const double l = std::sqrt(dot(d, d));
    if (!(l > 1e-6)) continue;
    sum += dot(d, up) / l;
    ++k;
  }
  if (n) *n = k;
  return k ? sum / static_cast<double>(k) : 0.0;
}

void test_the_print_files_lay() {
  const std::string dir = std::string(TMP_DIR) + "/print_frame_turn";
  std::system(("mkdir -p " + dir).c_str());
  // A block whose three sides all differ; woven under its +X face (the face it stands up to when +X is up).
  const double X = 24, Y = 20, Z = 16;
  write_stl_file(dir + "/block.stl", box_model(X, Y, Z).mesh);
  int face_x = -1;
  {
    const StepModel m = import_part_file_resolved(dir + "/block.stl");
    for (int f = 0; f < m.face_count; ++f) {
      const StepFaceInfo& i = m.faces[static_cast<std::size_t>(f)];
      if (i.kind == StepSurfaceKind::Plane && i.plane_normal.x > 0.99) face_x = f;
    }
  }
  CHECK(face_x >= 0);
  // A made-up stress, in the part's own coordinates: a compression along X growing with X, and shears.
  TensorField tf;
  tf.spacing = 1.0;
  tf.nx = 24; tf.ny = 20; tf.nz = 16;
  tf.voigt.assign(6 * static_cast<std::size_t>(tf.nx * tf.ny * tf.nz), 0.0);
  for (int k = 0; k < tf.nz; ++k)
    for (int j = 0; j < tf.ny; ++j)
      for (int i = 0; i < tf.nx; ++i) {
        double* v = &tf.voigt[6 * tf.index(i, j, k)];
        v[0] = -(1.0 + 2.0 * i / 23.0);
        v[1] = -0.3;
        v[2] = -0.4 - 0.2 * k / 15.0;
        v[3] = 0.1;
        v[4] = 0.05 * j / 19.0;
        v[5] = 0.15;
      }
  CHECK(write_tensor_file(dir + "/stress.tensor", tf));
  const auto job_text = [&](const std::string& frame) {
    return std::string(R"({"mode": "lattice_file", "model": "block.stl", "tensor": "stress.tensor", "strength_job": "none.json")") +
           frame + R"(, "mesh": {"keep_if_not_clean": true}, "layout": {"min_strut_lines": 2, "bead_mm": 0.45,
           "region_ids": [1], "region_no_lattice": [0], "region_depth_mm": [10], "region_expand_mm": [-2],
           "region_face_counts": [1], "region_faces": [)" + std::to_string(face_x) + R"(], "region_weave": [true],
           "organic_mode": "grown", "organic_spacing_min_mm": 3, "organic_spacing_max_mm": 6, "organic_width_mm": 0.9}})";
  };
  std::ofstream(dir + "/job.json") << job_text(R"(, "print_frame": {"up": [1, 0, 0]})");
  // THE PRINT FILE: the job as the Mac runs it (load_file_job: the part opened standing on +X, every input turned), its
  // own lay as handed to its strength check (make_lattice_file), in the print frame.
  FileJob job;
  StepModel model;
  FileResult lr;
  if (!load_file_job(dir + "/job.json", 0, job, model, lr)) {
    std::printf("FAIL the job: %s %s %s\n", lr.code.c_str(), lr.why.c_str(), lr.detail.c_str());
    ++g_fail;
    return;
  }
  CHECK(job.print_frame.on && job.print_frame.exact && job.organic.build_dir.z == 1.0);
  std::vector<Bar> file_bars;   // the print frame's
  {
    const StepModel kept = model;
    StepModel lay_copy = kept;
    Session fs(std::move(lay_copy));
    const Outcome fo = fs.lay_organic(job.settings, *job.tensor_field, job.organic, job.options.threads);
    file_bars = fo.bars.bars;
    if (mesh_available()) {   // and it IS the file's: the lay its strength check was handed
      std::vector<Bar> got;
      StrengthCheck cap;
      cap.before = [](const std::string&) { StrengthDone d; d.ok = true; return d; };
      cap.run = [](const StrengthAsk&) { StrengthDone d; d.ok = true; d.json = "{}"; return d; };
      cap.run_organic = [&](const StrengthAsk& ask) {
        got = ask.outcome->bars.bars;
        StrengthDone d;
        d.ok = true;
        d.json = "{}";
        return d;
      };
      StepModel file_copy = kept;
      const FileResult made = make_lattice_file(std::move(file_copy), job, dir + "/out.stl", nullptr, nullptr, &cap);
      if (!made.ok) std::printf("  (the file: %s %s %s)\n", made.code.c_str(), made.why.c_str(), made.detail.c_str());
      CHECK(made.ok && made.strength_ran);
      CHECK(bars_gap(got, file_bars) == 0.0);
      std::remove(made.file.c_str());
    } else {
      std::printf("  (no mesh library: the file job's lay is checked by its own call only)\n");
    }
  }
  // THE iPAD: what the bridge's framed session does — the settings and tensor in the part's own coordinates (as the app
  // sends them: the same job with no frame), the part opened through the file job's door, every lay input turned, the
  // ask growing along +Z, the Exact preview turned back.
  std::ofstream(dir + "/job_plain.json") << job_text("");
  std::string text;
  {
    std::ifstream in(dir + "/job_plain.json");
    text.assign(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
  }
  const FileJob plain = parse_file_job(text);
  TensorField tread;
  CHECK(read_tensor_file(dir + "/stress.tensor", tread));
  PrintFrame f;
  CHECK(print_frame_for_up({1, 0, 0}, f));
  StepModel opened = import_part_file_resolved(dir + "/block.stl");
  open_in_print_frame(f, opened);
  CHECK(f.t.x == job.print_frame.t.x && f.t.y == job.print_frame.t.y && f.t.z == job.print_frame.t.z);
  Session s(std::move(opened));
  GrowthTap tap;
  s.growth_tap(&tap);
  Settings st = plain.settings;
  std::shared_ptr<const TensorField> tensor = std::make_shared<TensorField>(tread);
  turn_layout_inputs(f, st, tensor);
  OrganicAsk ask = plain.organic;
  turn_organic_asks(f, &ask, nullptr);
  OrganicPreviewAsk pa;
  pa.quality = PreviewQuality::Exact;
  OrganicPreview pv = lay_organic_preview(s, st, *tensor, ask, pa);
  s.growth_tap(nullptr);
  GrowthTap::Read grew = tap.read(0);
  const OrganicPreview not_back = pv;
  turn_preview_to_model(f, pv);
  turn_growth_to_model(f, grew);
  // The file's bars in the part's own coordinates.
  std::vector<Bar> file_model = file_bars;
  for (Bar& b : file_model) {
    b.a = job.print_frame.point_to_model(b.a);
    b.b = job.print_frame.point_to_model(b.b);
  }
  bool widths = false;
  const double match = bars_gap(pv.outcome.bars.bars, file_model, &widths);
  // RED CONTROL 1: the old iPad lay — the part as placed, the ask growing along the part's own +Z.
  Session old(import_part_file_resolved(dir + "/block.stl"));
  GrowthTap old_tap;
  old.growth_tap(&old_tap);
  const OrganicPreview was = lay_organic_preview(old, plain.settings, tread, plain.organic, pa);
  old.growth_tap(nullptr);
  const GrowthTap::Read old_grew = old_tap.read(0);
  const double red_old = bars_gap(was.outcome.bars.bars, file_model);
  // RED CONTROL 2: the turned lay, not turned back.
  const double red_back = bars_gap(not_back.outcome.bars.bars, file_model);
  // Its runs and flat ends came back with it: every run point lies on the part (inside its box, give or take a tube).
  bool runs_in = !pv.runs.empty();
  for (const WeaveRun& r : pv.runs)
    for (const Vec3& p : r.points)
      runs_in = runs_in && p.x > -1.5 && p.x < X + 1.5 && p.y > -1.5 && p.y < Y + 1.5 && p.z > -1.5 && p.z < Z + 1.5;
  std::printf("the print file's lay: %zu bars; the iPad's, turned back: %zu (worst end %.3g mm, widths %s); RED the old lay: "
              "%zu bars (%.3g); RED not turned back: %.3g\n", file_bars.size(), pv.outcome.bars.bars.size(), match,
              widths ? "the same" : "DIFFER", was.outcome.bars.bars.size(), red_old, red_back);
  CHECK(file_bars.size() > 50);
  CHECK(match < 1e-9 && widths);
  CHECK(runs_in);
  CHECK(red_old > 1e-3);    // RED CONTROL: the old lay is not the print file's
  CHECK(red_back > 1e-3);   // RED CONTROL: turned, it must be turned back
  // 3. The growth runs along the kept up (+X), turned back; the old lay's climbs the part's own +Z.
  std::size_t n_new = 0, n_old = 0;
  const double up_new = climb(grew.xyz, {1, 0, 0}, &n_new), z_new = climb(grew.xyz, {0, 0, 1});
  const double up_old = climb(old_grew.xyz, {1, 0, 0}, &n_old), z_old = climb(old_grew.xyz, {0, 0, 1});
  std::printf("growth: %zu pieces turned back climb %.3f along the kept up (+X), %.3f along +Z; RED the old lay's %zu "
              "pieces climb %.3f along +X, %.3f along +Z\n", n_new, up_new, z_new, n_old, up_old, z_old);
  CHECK(n_new > 50 && n_old > 50);
  const auto climbs_the_up = [](double up, double z) { return up > 0.5 && std::fabs(z) < 0.25 * up; };
  CHECK(climbs_the_up(up_new, z_new));
  CHECK(!climbs_the_up(up_old, z_old));   // RED CONTROL: the old growth does not climb the kept up ...
  CHECK(z_old > 0.3);                     // ... it climbs the part's own +Z
  // And the pieces are the part's: inside its box.
  bool inside = true;
  for (std::size_t i = 0; i + 2 < grew.xyz.size(); i += 3)
    inside = inside && grew.xyz[i] > -1.0f && grew.xyz[i] < X + 1.0f && grew.xyz[i + 1] > -1.0f && grew.xyz[i + 1] < Y + 1.0f &&
             grew.xyz[i + 2] > -1.0f && grew.xyz[i + 2] < Z + 1.0f;
  CHECK(inside);
}

// ── 4. ★ notes29 H3 (his "Yes, definitely go for the cell lattices now too"): A CELL LATTICE ─────────────────────────
// The iPad's path for a cell (strut) lattice, as the bridge's framed session does it (lattice_layout_bridge.cpp): the part
// opened through the file job's door, the settings and the stress result turned through it (turn_layout_inputs, the
// stress once as set), Session::lay, the lay turned back (turn_outcome_to_model) — against the print file's own lay as
// handed to its strength check (make_lattice_file): the same struts end for end, the same cells and solid pieces (every
// cube's corners, through their frames), and the flat bridges judged in the print frame are the file's.
// RED CONTROLS: the lay as placed; the turned lay not turned back; the bridges judged on the bars turned back.

// Every corner of a list of cubes on frames (a cell's cube, a solid piece), in the frames' space.
std::vector<Vec3> corners(const Layout& L, const std::vector<Cell>& cubes) {
  std::vector<Vec3> out;
  for (const Cell& c : cubes)
    for (int k = 0; k < 8; ++k)
      out.push_back(L.frames[static_cast<std::size_t>(c.frame)].at(c.lo[0] + (k & 1 ? c.size : 0.0),
                                                                     c.lo[1] + (k & 2 ? c.size : 0.0),
                                                                     c.lo[2] + (k & 4 ? c.size : 0.0)));
  return out;
}
double points_gap(const std::vector<Vec3>& x, const std::vector<Vec3>& y) {
  if (x.size() != y.size() || x.empty()) return 1e300;
  double worst = 0.0;
  for (std::size_t i = 0; i < x.size(); ++i) worst = std::max(worst, dist(x[i], y[i]));
  return worst;
}
std::size_t bridges(const std::vector<Bar>& bars) {
  std::size_t n = 0;
  for (const Bar& b : bars) n += bar_is_bridge(b) ? 1 : 0;
  return n;
}

void test_the_print_files_cell_lay() {
  const std::string dir = std::string(TMP_DIR) + "/print_frame_turn_cells";
  std::system(("mkdir -p " + dir).c_str());
  const double X = 24, Y = 20, Z = 16;
  write_stl_file(dir + "/block.stl", box_model(X, Y, Z).mesh);
  // A made-up stress, in the part's own coordinates: rising along its own Z (0.5 to 4 MPa).
  DemandField d;
  d.origin = {-1, -1, -1};
  d.spacing = 1.0;
  d.nx = 26; d.ny = 22; d.nz = 18;
  d.mpa.assign(static_cast<std::size_t>(d.nx * d.ny * d.nz), 0.0f);
  for (int k = 0; k < d.nz; ++k)
    for (int j = 0; j < d.ny; ++j)
      for (int i = 0; i < d.nx; ++i)
        d.mpa[d.index(i, j, k)] = static_cast<float>(0.5 + 3.5 * std::min(std::max((k - 1) / 16.0, 0.0), 1.0));
  CHECK(write_demand_file(dir + "/stress.demand", d));
  const auto job_text = [&](const std::string& frame) {
    return std::string(R"({"mode": "lattice_file", "model": "block.stl", "demand": "stress.demand", "strength_job": "none.json")") +
           frame + R"(, "mesh": {"keep_if_not_clean": true}, "layout": {"all_lattice": true, "min_strut_lines": 2,
           "bead_mm": 0.45, "topology": "octet", "algorithm": "uniform", "cell_mm": 7, "by_stress": true,
           "reference_mpa": 4, "dial_light": 0.15, "dial_heavy": 0.85}})";
  };
  std::ofstream(dir + "/job.json") << job_text(R"(, "print_frame": {"up": [1, 0, 0]})");
  // THE PRINT FILE: the job as the Mac runs it, its own lay as handed to its strength check, in the print frame.
  FileJob job;
  StepModel model;
  FileResult lr;
  if (!load_file_job(dir + "/job.json", 0, job, model, lr)) {
    std::printf("FAIL the cell job: %s %s %s\n", lr.code.c_str(), lr.why.c_str(), lr.detail.c_str());
    ++g_fail;
    return;
  }
  CHECK(job.print_frame.on && job.print_frame.exact && job.settings.stress.demand != nullptr);
  Outcome file;   // the print frame's
  {
    StepModel lay_copy = model;
    Session fs(std::move(lay_copy));
    file = fs.lay(job.settings, job.options.threads);
    if (mesh_available()) {   // and it IS the file's: the lay its strength check was handed
      std::vector<Bar> got;
      std::size_t cells = 0, written_bridges = 0;
      StrengthCheck cap;
      cap.before = [](const std::string&) { StrengthDone x; x.ok = true; return x; };
      cap.run = [&](const StrengthAsk& ask) {
        got = ask.outcome->bars.bars;
        cells = ask.outcome->layout.cells.size();
        written_bridges = ask.made ? ask.made->mesh.bridges : 0;
        StrengthDone x;
        x.ok = true;
        x.json = "{}";
        return x;
      };
      StepModel file_copy = model;
      const FileResult made = make_lattice_file(std::move(file_copy), job, dir + "/out.stl", nullptr, nullptr, &cap);
      if (!made.ok) std::printf("  (the cell file: %s %s %s)\n", made.code.c_str(), made.why.c_str(), made.detail.c_str());
      CHECK(made.ok && made.strength_ran);
      CHECK(bars_gap(got, file.bars.bars) == 0.0);
      CHECK(cells == file.layout.cells.size());
      std::printf("the cell file wrote %zu bridges (%zu bars left out); the lay's bars judged in the print frame: %zu\n",
                  written_bridges, made.made.mesh.bars_left_out, bridges(file.bars.bars));
      if (made.made.mesh.bars_left_out == 0) CHECK(written_bridges == bridges(file.bars.bars));
      std::remove(made.file.c_str());
    } else {
      std::printf("  (no mesh library: the cell file job's lay is checked by its own call only)\n");
    }
  }
  // THE iPAD: the bridge's framed session — the settings and the stress as the app sends them (the job with no frame),
  // the part through the file job's door, the settings turned and the stress turned once (lattice_layout_set_demand),
  // Session::lay, turned back for the drawing.
  std::ofstream(dir + "/job_plain.json") << job_text("");
  std::string text;
  {
    std::ifstream in(dir + "/job_plain.json");
    text.assign(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
  }
  const FileJob plain = parse_file_job(text);
  auto demand = std::make_shared<DemandField>();
  CHECK(read_demand_file(dir + "/stress.demand", *demand));
  PrintFrame f;
  CHECK(print_frame_for_up({1, 0, 0}, f));
  StepModel opened = import_part_file_resolved(dir + "/block.stl");
  open_in_print_frame(f, opened);
  Session s(std::move(opened));
  Settings st = plain.settings;
  std::shared_ptr<const TensorField> none;
  turn_layout_inputs(f, st, none);
  {
    Settings door;
    door.stress.demand = demand;
    turn_layout_inputs(f, door, none);
    st.stress.demand = door.stress.demand;
  }
  Outcome ipad = s.lay(st, 0);
  const Outcome not_back = ipad;
  turn_outcome_to_model(f, ipad);
  // The file's lay in the part's own coordinates.
  Outcome file_model = file;
  turn_outcome_to_model(job.print_frame, file_model);
  bool widths = false;
  const double match = bars_gap(ipad.bars.bars, file_model.bars.bars, &widths);
  const double cells_match = points_gap(corners(ipad.layout, ipad.layout.cells), corners(file_model.layout, file_model.layout.cells));
  const double solid_match = file_model.layout.solid.empty()
                                 ? (ipad.layout.solid.empty() ? 0.0 : 1e300)
                                 : points_gap(corners(ipad.layout, ipad.layout.solid), corners(file_model.layout, file_model.layout.solid));
  // RED CONTROL 1: the lay as placed (before H3).
  Session old(import_part_file_resolved(dir + "/block.stl"));
  Settings ost = plain.settings;
  ost.stress.demand = demand;
  const Outcome was = old.lay(ost, 0);
  const double red_old = bars_gap(was.bars.bars, file_model.bars.bars);
  const double red_old_cells = points_gap(corners(was.layout, was.layout.cells), corners(file_model.layout, file_model.layout.cells));
  // RED CONTROL 2: the turned lay, not turned back.
  const double red_back = bars_gap(not_back.bars.bars, file_model.bars.bars);
  // The bridges: judged where they are laid (the print frame's +Z) they are the file's; judged on the bars turned back
  // (the part's own +Z, as the bridge's fill did before H3) they are other bars.
  const std::size_t b_print = bridges(not_back.bars.bars), b_file = bridges(file.bars.bars), b_model = bridges(ipad.bars.bars);
  std::printf("cells: the print file's lay %zu bars, %zu cells, %zu solid; the iPad's turned back %zu bars (worst end %.3g mm, "
              "widths %s), %zu cells (worst corner %.3g mm), solid %.3g mm; RED as placed %zu bars (%.3g), cells %.3g; RED not "
              "turned back %.3g; bridges in the print frame %zu, the file's %zu, RED judged turned back %zu\n",
              file.bars.bars.size(), file.layout.cells.size(), file.layout.solid.size(), ipad.bars.bars.size(), match,
              widths ? "the same" : "DIFFER", ipad.layout.cells.size(), cells_match, solid_match, was.bars.bars.size(), red_old,
              red_old_cells, red_back, b_print, b_file, b_model);
  CHECK(file.bars.bars.size() > 100 && file.layout.cells.size() > 10);
  CHECK(match < 1e-9 && widths);   // ★ the same struts, end for end, the same widths (the dial read the same stress)
  CHECK(cells_match < 1e-9);       // ★ the same cells, every corner
  CHECK(solid_match < 1e-9);       // ★ the same solid pieces
  CHECK(red_old > 1e-3);           // RED CONTROL: the lay as placed is not the file's
  CHECK(red_back > 1e-3);          // RED CONTROL: turned, it must be turned back
  CHECK(b_print == b_file && b_print > 0);   // ★ the bridges, judged in the print frame
  CHECK(b_model != b_print);                 // RED CONTROL: judged on the part's own +Z, other bars
  // The cells' index, made again in the part's own coordinates: every cell found at its own cube's middle.
  CHECK(ipad.layout.index != nullptr);
  bool found = ipad.layout.index != nullptr;
  for (std::size_t c = 0; found && c < ipad.layout.cells.size(); c += 7) {
    const Cell& cell = ipad.layout.cells[c];
    const Vec3 mid = ipad.layout.frames[static_cast<std::size_t>(cell.frame)].at(
        cell.lo[0] + cell.size / 2, cell.lo[1] + cell.size / 2, cell.lo[2] + cell.size / 2);
    const double p = ipad.layout.index->pitch;
    const std::array<long long, 3> key{static_cast<long long>(std::floor(mid.x / p)),
                                       static_cast<long long>(std::floor(mid.y / p)),
                                       static_cast<long long>(std::floor(mid.z / p))};
    const auto it = ipad.layout.index->grid.find(key);
    found = it != ipad.layout.index->grid.end() &&
            std::find(it->second.begin(), it->second.end(), static_cast<std::uint32_t>(c)) != it->second.end();
  }
  CHECK(found);
}

}  // namespace

int main() {
  test_turns();
  test_the_print_files_lay();
  test_the_print_files_cell_lay();
  std::printf("%s: %d checks, %d failed\n", g_fail ? "FAIL" : "PASS", g_checks, g_fail);
  return g_fail ? 1 : 0;
}
