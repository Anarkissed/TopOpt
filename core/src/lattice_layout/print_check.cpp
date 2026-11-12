// Lattice rebuild, stage F: his print rules judged layer by layer, and the mesh made again
// until it passes them. See lattice_layout_mesh.hpp (P8).
#include "topopt/lattice_layout_mesh.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <thread>

namespace topopt::lattice_layout {
namespace {

bool asked(const std::atomic<bool>* stop) { return stop && stop->load(std::memory_order_relaxed); }

struct Grid {
  int W = 0, H = 0;
  double x0 = 0.0, y0 = 0.0, px = 0.05;
};

// One layer's cross-section: per row of pixels, the columns at which "inside" flips, sorted.
// A pixel is inside when an odd number of flips lie at or before it.
struct Section {
  std::vector<int> start;   // H + 1
  std::vector<int> cols;
  bool any() const { return !cols.empty(); }
};

void paint(const Section& s, const Grid& g, std::vector<unsigned char>& img) {
  img.assign(static_cast<std::size_t>(g.W) * g.H, 0);
  if (s.start.empty()) return;
  for (int r = 0; r < g.H; ++r) {
    unsigned char* row = img.data() + static_cast<std::size_t>(r) * g.W;
    for (int i = s.start[static_cast<std::size_t>(r)]; i < s.start[static_cast<std::size_t>(r) + 1]; i += 2) {
      const int c0 = s.cols[static_cast<std::size_t>(i)];
      const int c1 = i + 1 < s.start[static_cast<std::size_t>(r) + 1] ? s.cols[static_cast<std::size_t>(i) + 1] : g.W;
      for (int c = c0; c < c1; ++c) row[c] = 1;
    }
  }
}
// Is any pixel of rows r0..r1, columns c0..c1 inside?
bool any_in(const Section& s, const Grid& g, int r0, int r1, int c0, int c1) {
  if (s.start.empty()) return false;
  r0 = std::max(r0, 0); r1 = std::min(r1, g.H - 1);
  c0 = std::max(c0, 0); c1 = std::min(c1, g.W - 1);
  for (int r = r0; r <= r1; ++r)
    for (int i = s.start[static_cast<std::size_t>(r)]; i < s.start[static_cast<std::size_t>(r) + 1]; i += 2) {
      const int a = s.cols[static_cast<std::size_t>(i)];
      const int b = i + 1 < s.start[static_cast<std::size_t>(r) + 1] ? s.cols[static_cast<std::size_t>(i) + 1] : g.W;
      if (a <= c1 && b > c0 && b > a) return true;
    }
  return false;
}

// The cross-section of `mesh` at height z, from the triangles listed.
Section cut(const TriangleMesh& mesh, const std::vector<std::uint32_t>& tris, double z, const Grid& g,
            std::vector<std::vector<int>>& rows) {
  for (auto& r : rows) r.clear();
  for (std::uint32_t ti : tris) {
    const auto& t = mesh.triangles[ti];
    const Vec3* v[3] = {&mesh.vertices[static_cast<std::size_t>(t[0])], &mesh.vertices[static_cast<std::size_t>(t[1])],
                        &mesh.vertices[static_cast<std::size_t>(t[2])]};
    // Each triangle crossing the plane gives one segment between two of its edges.
    bool cross[3];
    double px[3] = {0, 0, 0}, py[3] = {0, 0, 0};
    int count = 0;
    for (int e = 0; e < 3; ++e) {
      const Vec3 &a = *v[e], &b = *v[(e + 1) % 3];
      cross[e] = (a.z < z && b.z > z) || (a.z > z && b.z < z);
      if (!cross[e]) continue;
      ++count;
      const double s = (z - a.z) / (b.z - a.z);
      px[e] = a.x + s * (b.x - a.x);
      py[e] = a.y + s * (b.y - a.y);
    }
    if (count != 2) continue;
    const int ia = cross[0] ? 0 : 1, ib = cross[2] ? 2 : 1;
    const double ya = (py[ia] - g.y0) / g.px - 0.5, yb = (py[ib] - g.y0) / g.px - 0.5;
    const int r0 = static_cast<int>(std::ceil(std::min(ya, yb))), r1 = static_cast<int>(std::ceil(std::max(ya, yb))) - 1;
    for (int r = std::max(r0, 0); r <= r1 && r < g.H; ++r) {
      const double s = (r - ya) / (yb - ya);
      const double x = px[ia] + s * (px[ib] - px[ia]);
      const int c = std::max(0, static_cast<int>(std::ceil((x - g.x0) / g.px - 0.5)));
      if (c < g.W) rows[static_cast<std::size_t>(r)].push_back(c);
    }
  }
  Section out;
  out.start.assign(static_cast<std::size_t>(g.H) + 1, 0);
  std::size_t total = 0;
  for (auto& r : rows) total += r.size();
  out.cols.reserve(total);
  for (int r = 0; r < g.H; ++r) {
    auto& row = rows[static_cast<std::size_t>(r)];
    std::sort(row.begin(), row.end());
    out.start[static_cast<std::size_t>(r)] = static_cast<int>(out.cols.size());
    // Two flips at one column undo each other.
    for (std::size_t i = 0; i < row.size();) {
      if (i + 1 < row.size() && row[i] == row[i + 1]) { i += 2; continue; }
      out.cols.push_back(row[i]);
      ++i;
    }
  }
  out.start[static_cast<std::size_t>(g.H)] = static_cast<int>(out.cols.size());
  return out;
}

const double kFar = 1e18;

// d2[p] = the squared distance, in pixels, from p to the nearest pixel where `feat` is set
// (exact Euclidean); kFar where there is none.
struct Distance {
  std::vector<double> f, z;
  std::vector<int> v;
  void run(const std::vector<unsigned char>& feat, int W, int H, std::vector<double>& d2) {
    d2.assign(static_cast<std::size_t>(W) * H, kFar);
    // Down each column: the distance to the nearest feature in the column, squared.
    for (int x = 0; x < W; ++x) {
      double d = kFar;
      for (int y = 0; y < H; ++y) {
        const std::size_t i = static_cast<std::size_t>(y) * W + x;
        d = feat[i] ? 0.0 : (d >= kFar ? kFar : d + 1.0);
        d2[i] = d;
      }
      d = kFar;
      for (int y = H - 1; y >= 0; --y) {
        const std::size_t i = static_cast<std::size_t>(y) * W + x;
        d = feat[i] ? 0.0 : (d >= kFar ? kFar : d + 1.0);
        d2[i] = std::min(d2[i], d);
      }
    }
    // Along each row: the lowest of the parabolas standing on the column distances.
    f.resize(static_cast<std::size_t>(W));
    z.resize(static_cast<std::size_t>(W) + 1);
    v.resize(static_cast<std::size_t>(W));
    for (int y = 0; y < H; ++y) {
      double* row = d2.data() + static_cast<std::size_t>(y) * W;
      int k = -1;
      for (int q = 0; q < W; ++q) {
        f[static_cast<std::size_t>(q)] = row[q] >= kFar ? kFar : row[q] * row[q];
        if (f[static_cast<std::size_t>(q)] >= kFar) continue;
        if (k < 0) { k = 0; v[0] = q; z[0] = -kFar; z[1] = kFar; continue; }
        double s = 0.0;
        for (;;) {
          const int p = v[static_cast<std::size_t>(k)];
          s = ((f[static_cast<std::size_t>(q)] + static_cast<double>(q) * q) - (f[static_cast<std::size_t>(p)] + static_cast<double>(p) * p)) /
              (2.0 * q - 2.0 * p);
          if (s <= z[static_cast<std::size_t>(k)] && k > 0) { --k; continue; }
          break;
        }
        ++k;
        v[static_cast<std::size_t>(k)] = q;
        z[static_cast<std::size_t>(k)] = s;
        z[static_cast<std::size_t>(k) + 1] = kFar;
      }
      if (k < 0) continue;   // no feature in any column: the row stays far
      int j = 0;
      for (int q = 0; q < W; ++q) {
        while (z[static_cast<std::size_t>(j) + 1] < q) ++j;
        const int p = v[static_cast<std::size_t>(j)];
        row[q] = static_cast<double>(q - p) * (q - p) + f[static_cast<std::size_t>(p)];
      }
    }
  }
};

struct LayerFound {
  std::vector<LayerReport::MidAir> mid_air;
  std::vector<LayerReport::OneEnded> one_ended;
  double reach = 0.0;
  std::size_t thin = 0;
};

// What one thread needs to judge a layer.
struct Bench {
  std::vector<unsigned char> below, here, sup, ring;
  std::vector<double> d2, inside2;
  std::vector<int> label, stack;
  Distance distance;
};

// `s_below` null: the first layer (it rests on the bed; only its thin islands are counted).
LayerFound judge(const Section* s_below, const Section& s_here, double z, const Grid& g, int grow_px, const LayerSpec& spec, Bench& b) {
  LayerFound out;
  if (!s_here.any()) return out;
  const double over_mm = spec.one_ended_over_mm;
  const int W = g.W, H = g.H;
  const std::size_t N = static_cast<std::size_t>(W) * H;
  paint(s_here, g, b.here);
  b.sup.assign(N, 0);
  bool any_over = false, any_sup = false;
  if (s_below) {
    paint(*s_below, g, b.below);
    // Under: the layer below, grown by one layer height.
    b.distance.run(b.below, W, H, b.d2);
    const double grow2 = static_cast<double>(grow_px) * grow_px;
    for (std::size_t i = 0; i < N; ++i) {
      if (!b.here[i]) continue;
      if (b.d2[i] <= grow2) { b.sup[i] = 1; any_sup = true; } else any_over = true;
    }
  } else {
    b.sup = b.here;
    any_sup = true;
  }
  // How deep inside its island each pixel is (the distance to the nearest pixel outside).
  b.below.assign(N, 0);
  for (std::size_t i = 0; i < N; ++i) b.below[i] = !b.here[i];
  b.distance.run(b.below, W, H, b.inside2);
  // Islands of this layer (corner neighbours count); one with nothing under it starts in mid-air.
  b.label.assign(N, 0);
  int islands = 0;
  for (std::size_t i0 = 0; i0 < N; ++i0) {
    if (!b.here[i0] || b.label[i0]) continue;
    ++islands;
    long count = 0, sx = 0, sy = 0;
    int x_lo = W, x_hi = -1, y_lo = H, y_hi = -1;
    bool held = false;
    double deepest2 = 0.0;
    b.stack.clear();
    b.stack.push_back(static_cast<int>(i0));
    b.label[i0] = islands;
    while (!b.stack.empty()) {
      const int i = b.stack.back();
      b.stack.pop_back();
      const int x = i % W, y = i / W;
      ++count; sx += x; sy += y;
      x_lo = std::min(x_lo, x); x_hi = std::max(x_hi, x);
      y_lo = std::min(y_lo, y); y_hi = std::max(y_hi, y);
      held = held || b.sup[static_cast<std::size_t>(i)];
      deepest2 = std::max(deepest2, b.inside2[static_cast<std::size_t>(i)]);
      for (int dy = -1; dy <= 1; ++dy)
        for (int dx = -1; dx <= 1; ++dx) {
          const int xx = x + dx, yy = y + dy;
          if (xx < 0 || yy < 0 || xx >= W || yy >= H) continue;
          const std::size_t j = static_cast<std::size_t>(yy) * W + xx;
          if (!b.here[j] || b.label[j]) continue;
          b.label[j] = islands;
          b.stack.push_back(static_cast<int>(j));
        }
    }
    // Its thickness: twice the deepest pixel's distance to the outside, less the pixel itself.
    if ((2.0 * std::sqrt(deepest2) - 1.0) * g.px < spec.thin_under_mm && count * g.px * g.px >= spec.thin_min_mm2) ++out.thin;
    if (held) continue;
    LayerReport::MidAir m;
    m.z = z;
    m.mm2 = count * g.px * g.px;
    m.x = g.x0 + (static_cast<double>(sx) / count + 0.5) * g.px;
    m.y = g.y0 + (static_cast<double>(sy) / count + 0.5) * g.px;
    m.size_x = (x_hi - x_lo + 1) * g.px;
    m.size_y = (y_hi - y_lo + 1) * g.px;
    out.mid_air.push_back(m);
  }
  if (!any_over || !any_sup) return out;
  // How far each overhanging pixel is from the nearest held material of its own layer.
  b.distance.run(b.sup, W, H, b.d2);
  // Overhanging patches; one that reaches more than `over_mm` and is held at one place only is one-ended.
  b.label.assign(N, 0);
  std::vector<int> patch;
  for (std::size_t i0 = 0; i0 < N; ++i0) {
    if (!b.here[i0] || b.sup[i0] || b.label[i0]) continue;
    patch.clear();
    b.stack.clear();
    b.stack.push_back(static_cast<int>(i0));
    b.label[i0] = 1;
    int x_lo = W, x_hi = -1, y_lo = H, y_hi = -1;
    double far2 = 0.0;
    int far_at = static_cast<int>(i0);
    while (!b.stack.empty()) {
      const int i = b.stack.back();
      b.stack.pop_back();
      patch.push_back(i);
      const int x = i % W, y = i / W;
      x_lo = std::min(x_lo, x); x_hi = std::max(x_hi, x);
      y_lo = std::min(y_lo, y); y_hi = std::max(y_hi, y);
      const double d = b.d2[static_cast<std::size_t>(i)];
      if (d > far2 || (d == far2 && i < far_at)) { far2 = d; far_at = i; }
      for (int dy = -1; dy <= 1; ++dy)
        for (int dx = -1; dx <= 1; ++dx) {
          const int xx = x + dx, yy = y + dy;
          if (xx < 0 || yy < 0 || xx >= W || yy >= H) continue;
          const std::size_t j = static_cast<std::size_t>(yy) * W + xx;
          if (!b.here[j] || b.sup[j] || b.label[j]) continue;
          b.label[j] = 1;
          b.stack.push_back(static_cast<int>(j));
        }
    }
    const double reach = std::sqrt(far2) * g.px;
    out.reach = std::max(out.reach, reach);
    if (!(reach > over_mm)) continue;
    // The held material within two pixels of the patch: in how many separate places?
    const int wx0 = std::max(x_lo - 3, 0), wx1 = std::min(x_hi + 3, W - 1), wy0 = std::max(y_lo - 3, 0), wy1 = std::min(y_hi + 3, H - 1);
    const int ww = wx1 - wx0 + 1, wh = wy1 - wy0 + 1;
    b.ring.assign(static_cast<std::size_t>(ww) * wh, 0);
    for (int i : patch) {
      const int x = i % W, y = i / W;
      for (int dy = -2; dy <= 2; ++dy)
        for (int dx = -2; dx <= 2; ++dx) {
          const int xx = x + dx, yy = y + dy;
          if (xx < wx0 || yy < wy0 || xx > wx1 || yy > wy1) continue;
          if (b.sup[static_cast<std::size_t>(yy) * W + xx]) b.ring[static_cast<std::size_t>(yy - wy0) * ww + (xx - wx0)] = 1;
        }
    }
    int places = 0;
    std::vector<int> walk;
    for (int i0r = 0; i0r < ww * wh && places < 2; ++i0r) {
      if (b.ring[static_cast<std::size_t>(i0r)] != 1) continue;
      ++places;
      walk.clear();
      walk.push_back(i0r);
      b.ring[static_cast<std::size_t>(i0r)] = 2;
      while (!walk.empty()) {
        const int i = walk.back();
        walk.pop_back();
        const int x = i % ww, y = i / ww;
        for (int dy = -1; dy <= 1; ++dy)
          for (int dx = -1; dx <= 1; ++dx) {
            const int xx = x + dx, yy = y + dy;
            if (xx < 0 || yy < 0 || xx >= ww || yy >= wh) continue;
            const std::size_t j = static_cast<std::size_t>(yy) * ww + xx;
            if (b.ring[j] != 1) continue;
            b.ring[j] = 2;
            walk.push_back(static_cast<int>(j));
          }
      }
    }
    if (places >= 2) continue;   // a bridge: held at two places or more
    LayerReport::OneEnded o;
    o.reach_mm = reach;
    o.z = z;
    o.x = g.x0 + (far_at % W + 0.5) * g.px;
    o.y = g.y0 + (far_at / W + 0.5) * g.px;
    out.one_ended.push_back(o);
  }
  return out;
}

}  // namespace

LayerReport check_layers(const TriangleMesh& mesh, const LayerSpec& spec) {
  LayerReport rep;
  if (mesh.triangles.empty()) return rep;
  const double L = spec.layer_mm > 0.0 ? spec.layer_mm : 0.2, PX = spec.pixel_mm > 0.0 ? spec.pixel_mm : 0.05;
  double lo[3] = {1e300, 1e300, 1e300}, hi[3] = {-1e300, -1e300, -1e300};
  for (const auto& t : mesh.triangles)
    for (int q = 0; q < 3; ++q) {
      const Vec3& p = mesh.vertices[static_cast<std::size_t>(t[static_cast<std::size_t>(q)])];
      const double c[3] = {p.x, p.y, p.z};
      for (int a = 0; a < 3; ++a) { lo[a] = std::min(lo[a], c[a]); hi[a] = std::max(hi[a], c[a]); }
    }
  const double zmin = lo[2];
  rep.z_bed = zmin;
  // The bed face: what lies flat on the bed, and what faces down within the first layer without lying on it.
  for (const auto& t : mesh.triangles) {
    const Vec3 &a = mesh.vertices[static_cast<std::size_t>(t[0])], &b = mesh.vertices[static_cast<std::size_t>(t[1])],
               &c = mesh.vertices[static_cast<std::size_t>(t[2])];
    const double e1[3] = {b.x - a.x, b.y - a.y, b.z - a.z}, e2[3] = {c.x - a.x, c.y - a.y, c.z - a.z};
    const double n[3] = {e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0]};
    const double area = 0.5 * std::sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
    const bool flat = std::fabs(a.z - zmin) < 1e-4 && std::fabs(b.z - zmin) < 1e-4 && std::fabs(c.z - zmin) < 1e-4;
    if (flat) { rep.bed_mm2 += area; continue; }
    if (std::min(a.z, std::min(b.z, c.z)) < zmin + L && n[2] < -1e-9 * std::max(area, 1e-12)) rep.sloped_mm2 += std::fabs(0.5 * n[2]);
  }
  Grid g;
  g.px = PX;
  g.W = static_cast<int>(std::ceil((hi[0] - lo[0]) / PX)) + 8;
  g.H = static_cast<int>(std::ceil((hi[1] - lo[1]) / PX)) + 8;
  g.x0 = lo[0] - 4 * PX;
  g.y0 = lo[1] - 4 * PX;
  const int nl = static_cast<int>(std::ceil((hi[2] - zmin) / L - 1e-9));
  rep.layers = nl;
  if (nl <= 0) return rep;
  auto z_of = [&](int k) { return zmin + (k + 0.5) * L + 1e-5; };
  // Which triangles each layer's plane passes through.
  std::vector<std::vector<std::uint32_t>> through(static_cast<std::size_t>(nl));
  for (std::size_t ti = 0; ti < mesh.triangles.size(); ++ti) {
    const auto& t = mesh.triangles[ti];
    const double za = mesh.vertices[static_cast<std::size_t>(t[0])].z, zb = mesh.vertices[static_cast<std::size_t>(t[1])].z,
                 zc = mesh.vertices[static_cast<std::size_t>(t[2])].z;
    const double tmin = std::min(za, std::min(zb, zc)), tmax = std::max(za, std::max(zb, zc));
    int k = std::max(0, static_cast<int>(std::floor((tmin - zmin) / L - 0.5)) - 1);
    for (; k < nl && z_of(k) < tmax; ++k)
      if (z_of(k) > tmin) through[static_cast<std::size_t>(k)].push_back(static_cast<std::uint32_t>(ti));
  }
  const int nt = std::max(1, std::min(nl, spec.threads > 0 ? spec.threads : static_cast<int>(std::thread::hardware_concurrency())));
  // Every layer's cross-section, then every layer judged against the one below it. Each
  // layer on its own: the same answer for any number of threads.
  std::vector<Section> sections(static_cast<std::size_t>(nl));
  {
    std::atomic<int> next{0};
    auto work = [&] {
      std::vector<std::vector<int>> rows(static_cast<std::size_t>(g.H));
      for (int k = next.fetch_add(1); k < nl && !asked(spec.stop); k = next.fetch_add(1))
        sections[static_cast<std::size_t>(k)] = cut(mesh, through[static_cast<std::size_t>(k)], z_of(k), g, rows);
    };
    std::vector<std::thread> pool;
    for (int t = 1; t < nt; ++t) pool.emplace_back(work);
    work();
    for (std::thread& t : pool) t.join();
    if (asked(spec.stop)) throw LayCancelled{};
  }
  through.clear();
  through.shrink_to_fit();
  {
    std::vector<unsigned char> first;
    paint(sections[0], g, first);
    std::size_t n = 0;
    for (unsigned char c : first) n += c;
    rep.first_layer_mm2 = n * PX * PX;
  }
  const int grow_px = std::max(1, static_cast<int>(std::lround(L / PX)));
  std::vector<LayerFound> found(static_cast<std::size_t>(nl));
  {
    std::atomic<int> next{0};
    auto work = [&] {
      Bench bench;
      for (int k = next.fetch_add(1); k < nl && !asked(spec.stop); k = next.fetch_add(1))
        found[static_cast<std::size_t>(k)] = judge(k > 0 ? &sections[static_cast<std::size_t>(k) - 1] : nullptr, sections[static_cast<std::size_t>(k)],
                                                   z_of(k), g, grow_px, spec, bench);
    };
    std::vector<std::thread> pool;
    for (int t = 1; t < nt; ++t) pool.emplace_back(work);
    work();
    for (std::thread& t : pool) t.join();
    if (asked(spec.stop)) throw LayCancelled{};
  }
  // The first material below a place: the highest layer under it with anything within 0.45 mm.
  const int near_px = static_cast<int>(std::lround(0.45 / PX));
  auto below = [&](double x, double y, int k, double* z) {
    const int cx = static_cast<int>((x - g.x0) / PX), cy = static_cast<int>((y - g.y0) / PX);
    for (int j = k - 1; j >= 0; --j)
      if (any_in(sections[static_cast<std::size_t>(j)], g, cy - near_px, cy + near_px, cx - near_px, cx + near_px)) { *z = z_of(j); return true; }
    return false;
  };
  for (int k = 0; k < nl; ++k) {
    LayerFound& f = found[static_cast<std::size_t>(k)];
    rep.longest_reach_mm = std::max(rep.longest_reach_mm, f.reach);
    rep.thin_islands += f.thin;
    rep.thin_layers += f.thin > 0;
    for (LayerReport::MidAir& m : f.mid_air) { m.anything_below = below(m.x, m.y, k, &m.below_z); rep.mid_air.push_back(m); }
    for (LayerReport::OneEnded& o : f.one_ended) { o.anything_below = below(o.x, o.y, k, &o.below_z); rep.one_ended.push_back(o); }
  }
  return rep;
}

TriangleMesh build_printable_mesh(const PartMeasure& part, const Domain& domain, const Layout& layout, const Bars& bars,
                                  const OpenSpace& open, const PrintableSpec& spec, PrintableReport* report) {
  const auto t0 = std::chrono::steady_clock::now();
  PrintableReport rep;
  MeshSpec ms = spec.mesh;
  TriangleMesh mesh;
  bool posting = !spec.leave_out;
  int last = -1;
  const int most = std::max(1, spec.most_passes);
  // The part less the open space is the same on every pass: carved once.
  const Carved carved = carve_part(part, layout, open, ms.grow_mm, ms.stop);
  rep.ms_carve = carved.ms;
  const double half_layer = 0.5 * (spec.layers.layer_mm > 0.0 ? spec.layers.layer_mm : 0.2);
  for (int pass = 1; pass <= most; ++pass) {
    rep.passes = pass;
    mesh = build_mesh(part, domain, layout, bars, carved, ms, &rep.mesh);
    if (!rep.mesh.ok) { mesh = TriangleMesh{}; break; }
    rep.layers = check_layers(mesh, spec.layers);
    const int n = static_cast<int>(rep.layers.mid_air.size() + rep.layers.one_ended.size());
    rep.found_per_pass.push_back(n);
    if (n == 0) { rep.clean = true; break; }
    if (pass == most) break;
    auto post_all = [&] {
      for (const LayerReport::MidAir& m : rep.layers.mid_air)
        ms.posts.push_back({m.x, m.y, m.z, m.anything_below ? std::max(m.below_z, rep.layers.z_bed) : rep.layers.z_bed});
      for (const LayerReport::OneEnded& o : rep.layers.one_ended)
        ms.posts.push_back({o.x, o.y, o.z, o.anything_below ? std::max(o.below_z, rep.layers.z_bed) : rep.layers.z_bed});
    };
    if (!posting) {
      // First answer: leave out what starts there (the bottom of that layer).
      for (const LayerReport::MidAir& m : rep.layers.mid_air) ms.drop_at.push_back({m.x, m.y, m.z - half_layer});
      for (const LayerReport::OneEnded& o : rep.layers.one_ended) ms.drop_at.push_back({o.x, o.y, o.z - half_layer});
      // When leaving out no longer helps, tie down what is left with posts.
      if (n == last) { posting = true; post_all(); }
    } else {
      post_all();
    }
    last = n;
  }
  rep.drop_at = ms.drop_at;
  rep.posts = ms.posts;
  rep.ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
  if (report) *report = rep;
  return mesh;
}

}  // namespace topopt::lattice_layout
