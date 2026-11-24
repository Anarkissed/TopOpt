// Lattice rebuild, stage F: his print rules judged layer by layer, and the mesh made again
// until it passes them. See lattice_layout_mesh.hpp (P8).
#include "topopt/lattice_layout_mesh.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <map>
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
// NonZero (OF1): each crossing is kept as 2 * column + (1 when it enters, the triangle's normal facing back along the
// row), and the flips are where the running sum of +1 / -1 rises above 0 or falls back to it.
Section cut(const TriangleMesh& mesh, const std::vector<std::uint32_t>& tris, double z, const Grid& g,
            std::vector<std::vector<int>>& rows, bool nonzero = false) {
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
    int enter = 0;
    if (nonzero) {
      const double nx = (v[1]->y - v[0]->y) * (v[2]->z - v[0]->z) - (v[1]->z - v[0]->z) * (v[2]->y - v[0]->y);
      enter = nx < 0.0 ? 1 : 0;
    }
    const int ia = cross[0] ? 0 : 1, ib = cross[2] ? 2 : 1;
    const double ya = (py[ia] - g.y0) / g.px - 0.5, yb = (py[ib] - g.y0) / g.px - 0.5;
    const int r0 = static_cast<int>(std::ceil(std::min(ya, yb))), r1 = static_cast<int>(std::ceil(std::max(ya, yb))) - 1;
    for (int r = std::max(r0, 0); r <= r1 && r < g.H; ++r) {
      const double s = (r - ya) / (yb - ya);
      const double x = px[ia] + s * (px[ib] - px[ia]);
      const int c = std::max(0, static_cast<int>(std::ceil((x - g.x0) / g.px - 0.5)));
      if (c < g.W) rows[static_cast<std::size_t>(r)].push_back(nonzero ? 2 * c + enter : c);
    }
  }
  if (nonzero) {
    // The crossings as flips of "the sum is above 0": the rest reads them as before.
    for (auto& row : rows) {
      std::sort(row.begin(), row.end());
      std::vector<int> flips;
      int sum = 0;
      for (std::size_t i = 0; i < row.size();) {
        const int c = row[i] >> 1;
        const bool was = sum > 0;
        for (; i < row.size() && (row[i] >> 1) == c; ++i) sum += (row[i] & 1) ? 1 : -1;
        if ((sum > 0) != was) flips.push_back(c);
      }
      row.swap(flips);
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
  std::vector<LayerReport::OneEnded> one_ended, long_bridges;
  double reach = 0.0;
  std::size_t thin = 0;
};
}  // namespace

// SPEED 11-22: what the last check judged (its sections and judgements as judge made them, before the "below" reading),
// and everything a judgement reads besides the two sections.
struct LayerCache {
  bool valid = false;
  int W = 0, H = 0, nl = 0, grow_px = 0;
  double x0 = 0.0, y0 = 0.0, px = 0.0, zmin = 0.0, L = 0.0;
  double over = 0.0, reach = 0.0, thin_under = 0.0, thin_min = 0.0;
  int fill = 0;
  bool keep = false;   // K1: the findings hold their pixels
  std::vector<Section> sections;
  std::vector<LayerFound> found;
};

namespace {

// What one thread needs to judge a layer.
struct Bench {
  std::vector<unsigned char> below, here, sup, ring;
  std::vector<double> d2, inside2;
  std::vector<int> label, stack, island;
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
    b.island.clear();
    b.stack.push_back(static_cast<int>(i0));
    b.label[i0] = islands;
    while (!b.stack.empty()) {
      const int i = b.stack.back();
      b.stack.pop_back();
      if (spec.keep_pixels) b.island.push_back(i);   // K1
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
    if (spec.keep_pixels) m.pixels.assign(b.island.begin(), b.island.end());   // K1
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
    auto far_point = [&] {
      LayerReport::OneEnded o;
      o.reach_mm = reach;
      o.z = z;
      o.x = g.x0 + (far_at % W + 0.5) * g.px;
      o.y = g.y0 + (far_at / W + 0.5) * g.px;
      if (spec.keep_pixels) o.pixels.assign(patch.begin(), patch.end());   // K1: its overhanging patch
      return o;
    };
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
    if (places >= 2) {   // a bridge: held at two places or more. Fine, unless it reaches too far (rule e).
      if (spec.reach_limit_mm > 0.0 && reach > spec.reach_limit_mm) {
        LayerReport::OneEnded o = far_point();
        if (spec.keep_pixels) {
          // K1: every place of the patch that would still reach past the limit once the far point is held, one after
          // another (farthest first), so one try can hold the whole bridge (his stand: a strip of lattice 118 mm long
          // floating 1.2 mm over the bed took a post a try and ran out of tries).
          const double lim2 = (spec.reach_limit_mm / g.px) * (spec.reach_limit_mm / g.px);
          std::vector<double> left(patch.size());
          for (std::size_t q = 0; q < patch.size(); ++q) left[q] = b.d2[static_cast<std::size_t>(patch[q])];
          int px = far_at % W, py = far_at / W;
          for (int k = 0; k < 256; ++k) {
            double most = 0.0;
            std::size_t at = 0;
            for (std::size_t q = 0; q < patch.size(); ++q) {
              const int x = patch[q] % W, y = patch[q] / W;
              const double d = static_cast<double>(x - px) * (x - px) + static_cast<double>(y - py) * (y - py);
              if (d < left[q]) left[q] = d;
              if (left[q] > most) { most = left[q]; at = q; }
            }
            if (!(most > lim2)) break;
            px = patch[at] % W;
            py = patch[at] / W;
            o.more.push_back({g.x0 + (px + 0.5) * g.px, g.y0 + (py + 0.5) * g.px});
          }
        }
        out.long_bridges.push_back(o);
      }
      continue;
    }
    out.one_ended.push_back(far_point());
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
  rep.grid_w = g.W; rep.grid_h = g.H; rep.grid_x0 = g.x0; rep.grid_y0 = g.y0; rep.grid_px = g.px;   // K1
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
        sections[static_cast<std::size_t>(k)] = cut(mesh, through[static_cast<std::size_t>(k)], z_of(k), g, rows,
                                                    spec.fill == LayerSpec::Fill::NonZero);
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
    if (spec.fill == LayerSpec::Fill::NonZero) {
      // OF1 with the owner's flat bottom (the lead's ruling, 2026-11-18): overlapping shells are counted once, on the
      // filled first layer. Bed contact: the pixels of the first layer under a triangle lying flat on the bed. Sloped:
      // the footprint of the downward faces within the first layer that are not flat on it, less the pixels resting on
      // the bed (a face over material on the bed is inside the material, not an underside).
      std::vector<unsigned char> on_bed(first.size(), 0), down(first.size(), 0);
      for (const auto& t : mesh.triangles) {
        const Vec3 &a = mesh.vertices[static_cast<std::size_t>(t[0])], &b = mesh.vertices[static_cast<std::size_t>(t[1])],
                   &c = mesh.vertices[static_cast<std::size_t>(t[2])];
        const bool flat = std::fabs(a.z - zmin) < 1e-4 && std::fabs(b.z - zmin) < 1e-4 && std::fabs(c.z - zmin) < 1e-4;
        const double nz = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
        if (!flat && !(std::min(a.z, std::min(b.z, c.z)) < zmin + L && nz < -1e-12)) continue;
        std::vector<unsigned char>& into = flat ? on_bed : down;
        const int c0 = std::max(0, static_cast<int>(std::floor((std::min(a.x, std::min(b.x, c.x)) - g.x0) / PX)));
        const int c1 = std::min(g.W - 1, static_cast<int>(std::ceil((std::max(a.x, std::max(b.x, c.x)) - g.x0) / PX)));
        const int r0 = std::max(0, static_cast<int>(std::floor((std::min(a.y, std::min(b.y, c.y)) - g.y0) / PX)));
        const int r1 = std::min(g.H - 1, static_cast<int>(std::ceil((std::max(a.y, std::max(b.y, c.y)) - g.y0) / PX)));
        if (std::fabs(nz) < 1e-18) continue;
        for (int r = r0; r <= r1; ++r)
          for (int col = c0; col <= c1; ++col) {
            const double x = g.x0 + (col + 0.5) * PX, y = g.y0 + (r + 0.5) * PX;
            const double w0 = ((b.x - x) * (c.y - y) - (b.y - y) * (c.x - x)) / nz;
            const double w1 = ((c.x - x) * (a.y - y) - (c.y - y) * (a.x - x)) / nz;
            const double w2 = 1.0 - w0 - w1;
            if (w0 >= -1e-9 && w1 >= -1e-9 && w2 >= -1e-9) into[static_cast<std::size_t>(r) * g.W + col] = 1;
          }
      }
      std::size_t nb = 0, ns = 0;
      for (std::size_t i = 0; i < first.size(); ++i) {
        const bool bed_here = on_bed[i] && first[i];
        nb += bed_here;
        ns += down[i] && !on_bed[i];
      }
      rep.bed_mm2 = nb * PX * PX;
      rep.sloped_mm2 = ns * PX * PX;
    }
  }
  if (spec.layer_areas) {
    rep.layer_mm2.assign(static_cast<std::size_t>(nl), 0.0);
    for (int k = 0; k < nl; ++k) {
      const Section& s = sections[static_cast<std::size_t>(k)];
      long n = 0;
      if (!s.start.empty())
        for (int r = 0; r < g.H; ++r)
          for (int i = s.start[static_cast<std::size_t>(r)]; i < s.start[static_cast<std::size_t>(r) + 1]; i += 2)
            n += (i + 1 < s.start[static_cast<std::size_t>(r) + 1] ? s.cols[static_cast<std::size_t>(i) + 1] : g.W) -
                 s.cols[static_cast<std::size_t>(i)];
      rep.layer_mm2[static_cast<std::size_t>(k)] = n * PX * PX;
    }
  }
  const int grow_px = std::max(1, static_cast<int>(std::lround(L / PX)));
  std::vector<LayerFound> found(static_cast<std::size_t>(nl));
  // SPEED 11-22: the last check's judgement of a layer stands when its section and the one below are the same
  LayerCache* cache = spec.cache;
  const bool kept = cache && cache->valid && cache->W == g.W && cache->H == g.H && cache->x0 == g.x0 &&
                    cache->y0 == g.y0 && cache->px == g.px && cache->nl == nl && cache->zmin == zmin && cache->L == L &&
                    cache->grow_px == grow_px && cache->over == spec.one_ended_over_mm &&
                    cache->reach == spec.reach_limit_mm && cache->thin_under == spec.thin_under_mm &&
                    cache->thin_min == spec.thin_min_mm2 && cache->fill == static_cast<int>(spec.fill) &&
                    cache->keep == spec.keep_pixels &&
                    cache->sections.size() == sections.size() && cache->found.size() == found.size();
  auto same = [&](int k) {
    const Section& a = sections[static_cast<std::size_t>(k)];
    const Section& b = cache->sections[static_cast<std::size_t>(k)];
    return a.start == b.start && a.cols == b.cols;
  };
  {
    std::atomic<int> next{0};
    auto work = [&] {
      Bench bench;
      for (int k = next.fetch_add(1); k < nl && !asked(spec.stop); k = next.fetch_add(1)) {
        if (kept && same(k) && (k == 0 || same(k - 1))) {
          found[static_cast<std::size_t>(k)] = cache->found[static_cast<std::size_t>(k)];
          continue;
        }
        found[static_cast<std::size_t>(k)] = judge(k > 0 ? &sections[static_cast<std::size_t>(k) - 1] : nullptr, sections[static_cast<std::size_t>(k)],
                                                   z_of(k), g, grow_px, spec, bench);
      }
    };
    std::vector<std::thread> pool;
    for (int t = 1; t < nt; ++t) pool.emplace_back(work);
    work();
    for (std::thread& t : pool) t.join();
    if (asked(spec.stop)) throw LayCancelled{};
  }
  if (cache) {   // SPEED 11-22: for the next pass
    cache->valid = true;
    cache->W = g.W; cache->H = g.H; cache->x0 = g.x0; cache->y0 = g.y0; cache->px = g.px;
    cache->nl = nl; cache->zmin = zmin; cache->L = L; cache->grow_px = grow_px;
    cache->over = spec.one_ended_over_mm; cache->reach = spec.reach_limit_mm;
    cache->thin_under = spec.thin_under_mm; cache->thin_min = spec.thin_min_mm2;
    cache->fill = static_cast<int>(spec.fill);
    cache->keep = spec.keep_pixels;
    cache->sections = sections;
    cache->found = found;
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
    for (LayerReport::OneEnded& o : f.long_bridges) { o.anything_below = below(o.x, o.y, k, &o.below_z); rep.long_bridges.push_back(o); }
  }
  // What lies straight below each place asked: from the highest layer whose middle is under the height given.
  for (const Vec3& q : spec.below_of) {
    LayerReport::Below b;
    const int k = std::min(nl, std::max(0, static_cast<int>(std::ceil((q.z - zmin - 1e-5) / L - 0.5))));
    b.anything = below(q.x, q.y, k, &b.z);
    rep.below.push_back(b);
  }
  return rep;
}

namespace {
// K1 (his rule, 2026-11-24; PrintableSpec::only_app_made): does a finding's island hold an overhang the app made?
// Read pixel by pixel on the check's own grid, at the layer's middle. A pixel is the app's when it is
//   - material the app put in: material of the file two pixels or more from the carved solid's own cross-section there
//     (a kept bar, a weave's tube, a post: what fills the open space), or
//   - a finish the layout added: material of the carved solid at least 0.3 mm inside its cross-section (clear of the
//     open space's 0.25 mm reading at its edge) where the domain says rim (S1), cover (S9) or Organic bed floor;
// and the app took away what held it: the part's own material runs on under it, a layer and 1 mm more down (inside the
// part by more than 0.05 mm there). Material the layout only left in place (the part's walls, a Protect skin, what no
// region asked for, a wall too thin, lattice space no cell holds) is the part's own; so is the app's material at the
// part's own underside (within a layer and 1 mm of it: the carving's 0.25 mm reading and the stubs it drops lift the
// file's underside off the part's by up to that), which the slicer holds as it holds the part's.
class AppMade {
 public:
  AppMade(const PartMeasure& part, const Domain& domain, const Carved& carved, double layer_mm)
      : part_(part.probe()), probe_(domain.probe()), carved_(&carved), layer_(layer_mm) {}
  // `underside`: the app's material at the part's own underside is the part's (a cell lattice); false, any of the app's
  // material is the app's (a weave: Organic changes only where a finding lay on the part alone).
  bool any(const LayerReport& rep, const std::vector<std::int32_t>& pixels, double z, bool underside = true) {
    if (pixels.empty() || rep.grid_w <= 0) return true;   // nothing to read it by: judged as before
    const Grid g = grid_of(rep);
    const Section& solid = solid_at(g, z);
    const double under = z - layer_ - kUnderMM;
    const auto held_by_part = [&](double x, double y) {   // the part's material runs on under (x, y)
      if (!underside) return true;
      const Vec3 q{x, y, under};
      return part_.inside(q) && part_.depth_up_to(q, kDeep) >= kDeep;
    };
    for (const std::int32_t i : pixels) {   // material the app put in (cheap first)
      const int c = i % g.W, r = i / g.W;
      if (!any_in(solid, g, r - 2, r + 2, c - 2, c + 2) && held_by_part(g.x0 + (c + 0.5) * g.px, g.y0 + (r + 0.5) * g.px))
        return true;
    }
    for (const std::int32_t i : pixels) {   // then a finish the layout added
      const int c = i % g.W, r = i / g.W;
      if (!all_in(solid, g, r - kEdge, r + kEdge, c - kEdge, c + kEdge)) continue;
      const double x = g.x0 + (c + 0.5) * g.px, y = g.y0 + (r + 0.5) * g.px;
      const Why w = probe_.where({x, y, z}).why;
      if ((w == Why::Rim || w == Why::Cover || w == Why::BedFloor) && held_by_part(x, y)) return true;
    }
    return false;
  }

 private:
  static constexpr double kDeep = 0.05;     // mm: deeper than the pixel the file's surface is read to
  static constexpr double kUnderMM = 1.0;   // mm under the layer below: the part's own underside, read with its lift
  static constexpr int kEdge = 6;   // pixels: 0.3 mm at 0.05 mm, past the open space's 0.25 mm reading at its edge
  static Grid grid_of(const LayerReport& rep) {
    Grid g;
    g.W = rep.grid_w; g.H = rep.grid_h; g.x0 = rep.grid_x0; g.y0 = rep.grid_y0; g.px = rep.grid_px;
    return g;
  }
  // Is every pixel of rows r0..r1, columns c0..c1 inside? (Off the grid is not inside.)
  static bool all_in(const Section& s, const Grid& g, int r0, int r1, int c0, int c1) {
    if (s.start.empty() || r0 < 0 || c0 < 0 || r1 >= g.H || c1 >= g.W) return false;
    for (int r = r0; r <= r1; ++r) {
      bool covered = false;
      for (int i = s.start[static_cast<std::size_t>(r)]; i < s.start[static_cast<std::size_t>(r) + 1] && !covered; i += 2) {
        const int a = s.cols[static_cast<std::size_t>(i)];
        const int b = i + 1 < s.start[static_cast<std::size_t>(r) + 1] ? s.cols[static_cast<std::size_t>(i) + 1] : g.W;
        covered = a <= c0 && b > c1;
      }
      if (!covered) return false;
    }
    return true;
  }
  const Section& solid_at(const Grid& g, double z) {
    if (!(g.W == grid_.W && g.H == grid_.H && g.x0 == grid_.x0 && g.y0 == grid_.y0 && g.px == grid_.px)) {
      grid_ = g;
      sections_.clear();
    }
    const auto it = sections_.find(z);
    if (it != sections_.end()) return it->second;
    if (!made_) {
      made_ = true;
      solid_ = carved_solid_mesh(*carved_);
      zlo_.resize(solid_.triangles.size());
      zhi_.resize(solid_.triangles.size());
      for (std::size_t t = 0; t < solid_.triangles.size(); ++t) {
        const auto& tri = solid_.triangles[t];
        const double a = solid_.vertices[static_cast<std::size_t>(tri[0])].z, b = solid_.vertices[static_cast<std::size_t>(tri[1])].z,
                     c = solid_.vertices[static_cast<std::size_t>(tri[2])].z;
        zlo_[t] = std::min(a, std::min(b, c));
        zhi_[t] = std::max(a, std::max(b, c));
      }
    }
    std::vector<std::uint32_t> through;
    for (std::size_t t = 0; t < zlo_.size(); ++t)
      if (zlo_[t] < z && zhi_[t] > z) through.push_back(static_cast<std::uint32_t>(t));
    std::vector<std::vector<int>> rows(static_cast<std::size_t>(g.H));
    return sections_.emplace(z, cut(solid_, through, z, g, rows)).first->second;
  }
  PartMeasure::Probe part_;
  Domain::Probe probe_;
  const Carved* carved_;
  double layer_;
  bool made_ = false;
  TriangleMesh solid_;
  std::vector<double> zlo_, zhi_;
  Grid grid_;
  std::map<double, Section> sections_;
};

bool has_any_relief(const Bars& bars) {   // OG2c: any bar with a proud end or a bulge along a face
  for (const Bar& b : bars.bars)
    if (b.along_proud > 0.0 || b.proud_a > 0.0 || b.proud_b > 0.0) return true;
  return false;
}
}  // namespace

TriangleMesh build_printable_mesh(const PartMeasure& part, const Domain& domain, const Layout& layout, const Bars& laid,
                                  const OpenSpace& open, const PrintableSpec& spec, PrintableReport* report) {
  const auto t0 = std::chrono::steady_clock::now();
  PrintableReport rep;
  // O17, O18: a weave's sags, once, on the layout's bars before the writer; every pass is made of what this leaves.
  if (!layout.weave.empty() && (spec.mesh.weave_sag_lift_mm > 0.0 || spec.mesh.weave_sag_legs)) {
    auto sagged = std::make_shared<Bars>(laid);
    rep.sags = lift_weave_sags(domain, layout, *sagged, spec.mesh.weave_sag_lift_mm, spec.mesh.weave_sag_legs,
                               spec.layers.layer_mm > 0.0 ? spec.layers.layer_mm : 0.2);
    if (rep.sags.changed()) rep.sagged = std::move(sagged);
  }
  const Bars& bars = rep.sagged ? *rep.sagged : laid;
  MeshSpec ms = spec.mesh;
  TriangleMesh mesh;
  bool posting = !spec.leave_out;
  int last = -1;
  const int most = std::max(1, spec.most_passes);
  // The part less the open space is the same on every pass: carved once.
  const Carved carved = carve_part(part, layout, open, ms.grow_mm, ms.stop);
  rep.ms_carve = carved.ms;
  const double half_layer = 0.5 * (spec.layers.layer_mm > 0.0 ? spec.layers.layer_mm : 0.2);
  ms.layer_mm = 2.0 * half_layer;   // O10: a weave bar's level end is read at the check's own layer height
  // The owner's bridge rules for a weave (O5 to O10); with no weave region nothing below changes.
  std::vector<int> weave_regions;
  for (const Layout::Weave& w : layout.weave) weave_regions.push_back(w.region);
  std::vector<Vec3> stands_asked;   // O8: the middles of long stretches already asked about (posted or not)
  // OF4, the tubes route: the solid, with any cube lattice joined to it, is made apart from the weave's shells.
  rep.tubes = spec.mesh.weave_mesh == MeshSpec::WeaveMesh::Tubes && !weave_regions.empty();
  Bars cube_bars;
  TriangleMesh base;
  MeshReport base_rep;
  std::vector<char> base_present, base_slivers;
  if (rep.tubes)
    for (const Bar& x : bars.bars)
      if (std::find(weave_regions.begin(), weave_regions.end(), x.region) == weave_regions.end()) cube_bars.bars.push_back(x);
  LayerCache layer_cache;   // SPEED 11-22: each pass judges only the layers its changes touched
  AppMade app_made(part, domain, carved, 2.0 * half_layer);   // K1: what the app made, read once per layer asked
  for (int pass = 1; pass <= most; ++pass) {
    rep.passes = pass;
    rep.part_overhang_at.clear();   // P3: this pass's (the last pass's are the file's)
    if (spec.said) {   // ★ 362 11-23
      char line[96];
      std::snprintf(line, sizeof line, "checking it prints: try %d of at most %d", pass, most);
      spec.said(line);
    }
    LayerSpec layers = spec.layers;
    layers.cache = &layer_cache;
    layers.keep_pixels = spec.only_app_made;   // K1
    WeaveHolds holds;
    std::vector<char> present;
    std::vector<WeaveStand> stands;
    if (!weave_regions.empty()) {
      // The bars the writer keeps on this pass (weave_holds after `drop_at`).
      present = bars_present(bars, ms.drop_at, weave_regions, ms.layer_mm);
      holds = weave_holds(bars, weave_regions, present, ms.bridge_rise);
    }
    if (rep.tubes) {
      // The solid again only when the cube bars left in, or the slivers left out, changed.
      const std::vector<char> cp = bars_present(cube_bars, ms.drop_at), sl = solid_slivers_left_out(carved, ms.drop_at);
      rep.pass_ms.push_back({});
      if (rep.base_builds == 0 || cp != base_present || sl != base_slivers) {
        const auto ts = std::chrono::steady_clock::now();
        MeshSpec bs = ms;
        bs.posts.clear();
        bs.keep_pieces = true;
        base = build_mesh(part, domain, layout, cube_bars, carved, bs, &base_rep);
        base_present = cp;
        base_slivers = sl;
        ++rep.base_builds;
        rep.pass_ms.back().solid_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - ts).count();
      }
      rep.mesh = base_rep;
      if (!rep.mesh.ok) { mesh = TriangleMesh{}; break; }
      // The weave's shells from the bars as they now stand (OF2, OF3), and the posts.
      rep.shells = weave_shells(part, domain, layout, bars, holds.kept, carved, ms, true);
      rep.ms_shells += rep.shells.ms;
      rep.pass_ms.back().shells_ms = rep.shells.ms;
      mesh = base;
      rep.base_triangles = base.triangles.size();
      rep.shell_first_tri.clear();
      const int vb = static_cast<int>(mesh.vertices.size());
      mesh.vertices.insert(mesh.vertices.end(), rep.shells.mesh.vertices.begin(), rep.shells.mesh.vertices.end());
      for (const auto& t : rep.shells.mesh.triangles) mesh.triangles.push_back({t[0] + vb, t[1] + vb, t[2] + vb});
      for (std::size_t f : rep.shells.first_tri) rep.shell_first_tri.push_back(rep.base_triangles + f);
      rep.shells.mesh = TriangleMesh{};
      // The writer's counts for the whole file: the weave bars left out, the shells' shapes, the triangles.
      for (std::size_t i = 0; i < bars.bars.size(); ++i) {
        const Bar& x = bars.bars[i];
        if (std::find(weave_regions.begin(), weave_regions.end(), x.region) == weave_regions.end() || present[i]) continue;
        ++rep.mesh.bars_left_out;
        rep.mesh.bars_left_out_mm += std::sqrt((x.b.x - x.a.x) * (x.b.x - x.a.x) + (x.b.y - x.a.y) * (x.b.y - x.a.y) + (x.b.z - x.a.z) * (x.b.z - x.a.z));
      }
      rep.mesh.kept_any_length = holds.kept_any_length;
      rep.mesh.weave_left_unheld = holds.left_unheld;
      rep.mesh.bridges += rep.shells.bridges;
      rep.mesh.feet = rep.shells.feet;
      rep.mesh.posts = rep.shells.posts;
      rep.mesh.posts_mm = 0.0;
      for (const MeshSpec::Post& p : ms.posts)
        if (p.z_top > p.z_bottom) rep.mesh.posts_mm += p.z_top - p.z_bottom;
      rep.mesh.triangles = mesh.triangles.size();
      rep.mesh.mm3 += rep.shells.mm3;
      layers.fill = LayerSpec::Fill::NonZero;
    } else {
      mesh = build_mesh(part, domain, layout, bars, carved, ms, &rep.mesh);
      if (!rep.mesh.ok) { mesh = TriangleMesh{}; break; }
    }
    if (!weave_regions.empty()) {
      // Their runs' long stretches.
      for (const WeaveStand& w : weave_stands_wanted(bars, weave_regions, holds.kept, ms.weave_stand_every_mm, ms.bridge_rise)) {
        bool before = false;
        for (const Vec3& p : stands_asked) before = before || (p.x == w.at.x && p.y == w.at.y && p.z == w.at.z);
        if (before) continue;
        stands.push_back(w);
        layers.below_of.push_back({w.at.x, w.at.y, w.below_z});
      }
    }
    const auto tl = std::chrono::steady_clock::now();
    rep.layers = check_layers(mesh, layers);
    if (rep.tubes) rep.pass_ms.back().layers_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - tl).count();
    const std::vector<LayerReport::Below> below = std::move(rep.layers.below);
    rep.layers.below.clear();
    // The part's own findings out of the check (counted in part_overhangs, their places in part_overhang_at for P3).
    // K1 (his rule, 2026-11-24): with only_app_made, a finding is the part's own when its island holds no pixel the app
    // made (AppMade); `far_own` (F1 / OS17, read at the far point) then only counts how the two readings differ.
    // Without, `far_own` decides, as before.
    const auto take_own = [&](const auto& far_own, bool underside) {
      const std::size_t before = rep.layers.mid_air.size() + rep.layers.one_ended.size() + rep.layers.long_bridges.size();
      const auto own = [&](double x, double y, double z, const std::vector<std::int32_t>& pixels) {
        const bool far = far_own(x, y, z);
        if (!spec.only_app_made || far) return far;   // what F1 / OS17 left to the slicer stays the slicer's
        const bool mine = !app_made.any(rep.layers, pixels, z, underside);
        rep.own_by_k1 += mine && !far;
        return mine;
      };
      // P3: each finding taken as the part's own keeps its place (the predicate runs once per finding)
      rep.layers.mid_air.erase(std::remove_if(rep.layers.mid_air.begin(), rep.layers.mid_air.end(),
                                              [&](const LayerReport::MidAir& m) {
                                                const bool w = own(m.x, m.y, m.z, m.pixels);
                                                if (w) rep.part_overhang_at.push_back({m.x, m.y, m.z});
                                                return w;
                                              }),
                               rep.layers.mid_air.end());
      for (std::vector<LayerReport::OneEnded>* v : {&rep.layers.one_ended, &rep.layers.long_bridges})
        v->erase(std::remove_if(v->begin(), v->end(), [&](const LayerReport::OneEnded& o) {
                   const bool w = own(o.x, o.y, o.z, o.pixels);
                   if (w) rep.part_overhang_at.push_back({o.x, o.y, o.z});
                   return w;
                 }), v->end());
      rep.part_overhangs += before - (rep.layers.mid_air.size() + rep.layers.one_ended.size() + rep.layers.long_bridges.size());
    };
    if (!weave_regions.empty()) {
      // O7: a shallow weave bar the rules keep is kept at any length: what the check finds ON it held at one end, or
      // reaching past the limit, is not a finding (read on the bar as `drop_at` is: within its half width + 0.35 mm).
      // SPEED 11-22: only the kept shallow bars filed on a grid, each finding read against those in its cell
      std::vector<char> kept_shallow(bars.bars.size(), 0);
      for (std::size_t i = 0; i < bars.bars.size(); ++i)
        kept_shallow[i] = i < holds.shallow.size() && i < holds.kept.size() && holds.shallow[i] && holds.kept[i];
      const BarGrid shallow_grid(bars, kept_shallow);
      auto on_kept_shallow = [&](const LayerReport::OneEnded& o) {
        for (const std::uint32_t u : shallow_grid.near({o.x, o.y, o.z})) {
          const std::size_t i = u;
          if (!holds.shallow[i] || !holds.kept[i]) continue;
          const Bar& x = bars.bars[i];
          const Vec3 d{x.b.x - x.a.x, x.b.y - x.a.y, x.b.z - x.a.z};
          const double l2 = d.x * d.x + d.y * d.y + d.z * d.z;
          const double t = l2 > 0 ? std::clamp(((o.x - x.a.x) * d.x + (o.y - x.a.y) * d.y + (o.z - x.a.z) * d.z) / l2, 0.0, 1.0) : 0.0;
          const double ex = x.a.x + t * d.x - o.x, ey = x.a.y + t * d.y - o.y, ez = x.a.z + t * d.z - o.z;
          if (std::sqrt(ex * ex + ey * ey + ez * ez) < 0.5 * x.width + 0.35) return true;
        }
        return false;
      };
      for (std::vector<LayerReport::OneEnded>* v : {&rep.layers.one_ended, &rep.layers.long_bridges})
        v->erase(std::remove_if(v->begin(), v->end(), on_kept_shallow), v->end());
      // O10: two kinds of mid-air finding are not findings for a weave. A speck: an island smaller than half a line
      // width both ways (no printer lays it down), lying on a weave bar, that reaches no cube-lattice bar. A held
      // start: a place that would leave out no bar, because every bar it reaches is a weave bar that starts where it
      // is held (its lowest end held from below or level, or less than a layer below its held other end).
      // Read where `drop_at` would put the place (the bottom of its layer), against the bars the writer kept.
      std::vector<Vec3> places;
      for (const LayerReport::MidAir& m : rep.layers.mid_air) places.push_back({m.x, m.y, m.z - half_layer});
      // SPEED 11-22: the joints and the grid made ONCE for this pass (they were made again for every place below)
      const WeaveFindingsIndex findings(bars, weave_regions, holds.kept, ms.layer_mm);
      std::vector<WeaveFinding> wf(places.size());
      for (std::size_t q = 0; q < places.size(); ++q) wf[q] = findings.at(places[q]);
      const double speck = 0.5 * layout.bead_mm;
      std::vector<LayerReport::MidAir> still, specks;
      for (std::size_t q = 0; q < rep.layers.mid_air.size(); ++q) {
        const LayerReport::MidAir& m = rep.layers.mid_air[q];
        const WeaveFinding& f = wf[q];
        if (m.size_x < speck && m.size_y < speck && f.on_weave && f.cube == 0) {
          ++rep.weave_specks_ignored;
          specks.push_back(m);
          continue;
        }
        if (f.reached > 0 && f.cube == 0 && f.held + f.level == f.reached) { ++rep.weave_held_ignored; continue; }
        still.push_back(m);
      }
      rep.layers.mid_air.swap(still);
      // The part's own overhangs (the lead's ruling, 2026-11-19, OS17): reaching no bar, on no weave bar, and outside
      // the part right under it. Counted, never answered. K1 (his rule, 2026-11-24): with only_app_made, OS17 is his
      // rule, read on the finding's whole island (take_own); the far-point reading is kept for the record.
      {
        const Domain::Probe probe = domain.probe();
        const double layer = 2.0 * half_layer;
        const auto far_own = [&](double x, double y, double z) {
          const WeaveFinding f = findings.at({x, y, z - half_layer});
          return f.reached == 0 && !f.on_weave && probe.where({x, y, z - layer}).why == Why::Outside;
        };
        take_own(far_own, false);   // the weave: only an island with none of the app's material is the part's own
      }
      // A speck held by nothing below is also seen as an overhang held at one place: the same island, in the same
      // layer within half a line width of the speck's middle, is not a finding either.
      auto at_speck = [&](const LayerReport::OneEnded& o) {
        for (const LayerReport::MidAir& m : specks)
          if (o.z == m.z && std::hypot(o.x - m.x, o.y - m.y) < speck) return true;
        return false;
      };
      rep.layers.one_ended.erase(std::remove_if(rep.layers.one_ended.begin(), rep.layers.one_ended.end(), at_speck),
                                 rep.layers.one_ended.end());
    }
    if (weave_regions.empty()) {
      // ★ 362 11-23, F1 (his regular lattice refused every time on his stand: the stand's OWN top tab, a flat bar bridged
      // about 13.5 mm behind a slot, was judged as the lattice's and "answered" with a post from the bed that the cut to
      // the part deletes, ten times): the lead's ruling of 2026-11-19 (OS17) for every lattice, as for a weave. A finding
      // that reaches no bar the writer keeps (within its half width + 0.35 mm, read at the bottom of its layer as
      // `drop_at` is) and has the outside of the part right under it, a layer down, is the PART'S OWN overhang: the
      // slicer's business, counted, never left out, never propped, never a reason the file is not clean.
      const std::vector<char> kept = bars_present(bars, ms.drop_at);
      const BarGrid grid(bars, kept);
      const PartMeasure::Probe exact = part.probe();   // the part's own surface, exact (the domain's map is coarse at a face)
      const double layer = 2.0 * half_layer;
      const auto reaches_bar = [&](double x, double y, double z) {
        const Vec3 p{x, y, z - half_layer};
        for (const std::uint32_t u : grid.near(p)) {
          const Bar& b = bars.bars[u];
          const Vec3 d{b.b.x - b.a.x, b.b.y - b.a.y, b.b.z - b.a.z};
          const double l2 = d.x * d.x + d.y * d.y + d.z * d.z;
          const double t = l2 > 0 ? std::clamp(((p.x - b.a.x) * d.x + (p.y - b.a.y) * d.y + (p.z - b.a.z) * d.z) / l2, 0.0, 1.0) : 0.0;
          const double ex = b.a.x + t * d.x - p.x, ey = b.a.y + t * d.y - p.y, ez = b.a.z + t * d.z - p.z;
          if (std::sqrt(ex * ex + ey * ey + ez * ez) < 0.5 * b.width + 0.35) return true;
        }
        return false;
      };
      const auto far_own = [&](double x, double y, double z) {
        return exact.depth({x, y, z - layer}) < 0.0 && !reaches_bar(x, y, z);
      };
      take_own(far_own, true);   // K1: his rule on the finding's island with only_app_made (F1 at its far point without)
    }
    // OS1 B (his ruling R2): a finding on a shallow run's rounded end (within its half width + 0.35 mm of its place in
    // plan, from a layer under its underside to its top) is not answered by leaving bars out: that end is made flat
    // again (MeshSpec::flat_domes_at) and the pass made again; counted.
    if (rep.tubes && !rep.shells.dome_ends.empty()) {
      std::size_t flattened = 0;
      auto on_dome = [&](double x, double y, double z) {
        for (const auto& d : rep.shells.dome_ends) {
          const double r = d[3];
          if (std::hypot(x - d[0], y - d[1]) > r + 0.35 || z < d[2] - r - 2.0 * half_layer || z > d[2] + r + 2.0 * half_layer) continue;
          const Vec3 at{d[0], d[1], d[2]};
          bool listed = false;
          for (const Vec3& f : ms.flat_domes_at) listed = listed || (f.x == at.x && f.y == at.y && f.z == at.z);
          if (!listed) { ms.flat_domes_at.push_back(at); ++flattened; }
          return true;
        }
        return false;
      };
      const std::size_t before = flattened;
      for (const LayerReport::MidAir& m : rep.layers.mid_air) on_dome(m.x, m.y, m.z);
      for (std::vector<LayerReport::OneEnded>* v : {&rep.layers.one_ended, &rep.layers.long_bridges})
        for (const LayerReport::OneEnded& o : *v) on_dome(o.x, o.y, o.z);
      // Leg T (OS1 R2 completed, the lead's ruling 2026-11-21): a round that flattens domes is not one of the check's
      // passes: the passes left to leave out and post are as many as with no domes (it converges where it converged
      // without them, release 12); at most `most` such rounds.
      if (flattened > before && rep.dome_rounds < most) {
        rep.domes_flattened += flattened - before;
        ++rep.dome_rounds;
        --pass;
        continue;
      }
    }
    // O8: a post at the middle of each long stretch that has material straight below it, from that material up into
    // the bar. With nothing below, the run stands as it is.
    std::vector<MeshSpec::Post> stand_posts;
    for (std::size_t i = 0; i < stands.size(); ++i) {
      stands_asked.push_back(stands[i].at);
      if (i < below.size() && below[i].anything)
        stand_posts.push_back({stands[i].at.x, stands[i].at.y, stands[i].at.z, std::max(below[i].z, rep.layers.z_bed)});
    }
    const int n = static_cast<int>(rep.layers.mid_air.size() + rep.layers.one_ended.size() + rep.layers.long_bridges.size());
    rep.found_per_pass.push_back(n);
    if (n == 0 && stand_posts.empty()) { rep.clean = true; break; }
    if (pass == most) { rep.clean = n == 0; break; }
    for (const MeshSpec::Post& p : stand_posts) ms.posts.push_back(p);
    rep.stands_added += stand_posts.size();
    if (n == 0) { last = n; continue; }   // only the stands to add: made again with them
    // ★ 362 11-23, F2 and F3: what this try adds. A post whose column leaves the part is never added (the cut to the
    // part deletes what of it is outside, so it could hold nothing: F2); a post or a place to leave out that is already
    // there is not added again (F3). When a try adds nothing at all, the next try would make the same file again: the
    // loop stops there (F3), instead of making it again up to the last try (his stand: the same post, nine times).
    // Cell lattices only: a weave's loop (Organic) is left exactly as released (its own rules, OS17, already keep the
    // part's own overhangs out of it).
    const bool cells_only = weave_regions.empty();
    std::size_t added = stand_posts.size();
    const PartMeasure::Probe column_probe = part.probe();
    const auto add_post = [&](const MeshSpec::Post& p) {
      if (cells_only) {
        for (const MeshSpec::Post& q : ms.posts)
          if (q.x == p.x && q.y == p.y && q.z_top == p.z_top && q.z_bottom == p.z_bottom) return;
        // read against the part's own surface (exact): most of the column outside it = a post the cut deletes
        int samples = 0, outside = 0;
        for (double z = p.z_bottom + 0.25; z < p.z_top - 0.5; z += 0.5, ++samples)
          outside += column_probe.depth({p.x, p.y, z}) < 0.0;
        if (samples > 0 && 2 * outside > samples) { ++rep.posts_outside; return; }
      }
      ms.posts.push_back(p);
      ++added;
    };
    const auto add_drop = [&](const Vec3& v) {
      if (cells_only)
        for (const Vec3& q : ms.drop_at)
          if (q.x == v.x && q.y == v.y && q.z == v.z) return;
      ms.drop_at.push_back(v);
      ++added;
    };
    auto post_all = [&] {
      for (const LayerReport::MidAir& m : rep.layers.mid_air)
        add_post({m.x, m.y, m.z, m.anything_below ? std::max(m.below_z, rep.layers.z_bed) : rep.layers.z_bed});
      for (const LayerReport::OneEnded& o : rep.layers.one_ended)
        add_post({o.x, o.y, o.z, o.anything_below ? std::max(o.below_z, rep.layers.z_bed) : rep.layers.z_bed});
    };
    // A bridge that reaches too far is never cured by leaving a strut out: it gets a post under its far point.
    // K1 (cell lattices): and under every other place of it that would still reach too far, from the bed (a post whose
    // column leaves the part is not added, F2), so one try holds the whole bridge.
    for (const LayerReport::OneEnded& o : rep.layers.long_bridges) {
      add_post({o.x, o.y, o.z, o.anything_below ? std::max(o.below_z, rep.layers.z_bed) : rep.layers.z_bed});
      if (cells_only)
        for (const auto& m : o.more) add_post({m[0], m[1], o.z, rep.layers.z_bed});
    }
    if (!posting) {
      // First answer: leave out what starts there (the bottom of that layer).
      for (const LayerReport::MidAir& m : rep.layers.mid_air) add_drop({m.x, m.y, m.z - half_layer});
      for (const LayerReport::OneEnded& o : rep.layers.one_ended) add_drop({o.x, o.y, o.z - half_layer});
      // When leaving out no longer helps, tie down what is left with posts.
      if (n == last) { posting = true; post_all(); }
    } else {
      post_all();
    }
    if (cells_only && added == 0 && !posting) { posting = true; post_all(); }   // leaving out no longer helps: posts
    if (cells_only && added == 0) { rep.stopped_repeating = true; rep.clean = false; break; }
    last = n;
  }
  rep.drop_at = ms.drop_at;
  rep.posts = ms.posts;
  // O18: a leg the hold rules or the layer check left out (with the bar it landed on) is no leg: its sag is unsupported.
  if (rep.sagged && !rep.sags.leg_at.empty()) {
    const std::vector<char> present = bars_present(bars, ms.drop_at, weave_regions, ms.layer_mm);
    const WeaveHolds holds = weave_holds(bars, weave_regions, present, ms.bridge_rise);
    for (const auto& [first, count] : rep.sags.leg_at) {
      bool kept = true;
      for (std::size_t i = first; i < first + count && i < bars.bars.size(); ++i) kept = kept && holds.kept[i];
      if (kept) continue;
      ++rep.sags.legs_left_out;
      ++rep.sags.unsupported;
      --rep.sags.legs;
      rep.sags.leg_bars -= count;
      for (std::size_t i = first; i < first + count && i < bars.bars.size(); ++i) {
        const Bar& x = bars.bars[i];
        rep.sags.legs_mm -= std::sqrt((x.b.x - x.a.x) * (x.b.x - x.a.x) + (x.b.y - x.a.y) * (x.b.y - x.a.y) + (x.b.z - x.a.z) * (x.b.z - x.a.z));
      }
    }
  }
  // OG2c (brief E6, leg C): a bulge the check flags is not worth a refusal. The final findings' places; a bar whose
  // relief (along an open face, OG2b, or a proud end, OG2) has a finding on or within one radius of its proud part
  // (the place no deeper than its radius into the part, and within two radii of its line) is cut flush as before the
  // rule, that bar only, and the whole loop is run again; until clean, or no proud bar is near a finding.
  for (const LayerReport::MidAir& m : rep.layers.mid_air) rep.findings_at.push_back({m.x, m.y, m.z});
  for (const LayerReport::OneEnded& o : rep.layers.one_ended) rep.findings_at.push_back({o.x, o.y, o.z});
  for (const LayerReport::OneEnded& o : rep.layers.long_bridges) rep.findings_at.push_back({o.x, o.y, o.z});
  if (!rep.clean && !rep.findings_at.empty() && has_any_relief(laid)) {
    const PartMeasure::Probe pr = part.probe();
    std::vector<std::size_t> flush;
    for (std::size_t i = 0; i < bars.bars.size() && i < laid.bars.size(); ++i) {
      const Bar& x = bars.bars[i];
      if (!(x.along_proud > 0.0 || x.proud_a > 0.0 || x.proud_b > 0.0)) continue;
      const double r = 0.5 * x.width;
      const Vec3 d{x.b.x - x.a.x, x.b.y - x.a.y, x.b.z - x.a.z};
      const double l2 = d.x * d.x + d.y * d.y + d.z * d.z;
      bool near = false;
      for (const Vec3& f : rep.findings_at) {
        const double t = l2 > 0 ? std::clamp(((f.x - x.a.x) * d.x + (f.y - x.a.y) * d.y + (f.z - x.a.z) * d.z) / l2, 0.0, 1.0) : 0.0;
        const double ex = x.a.x + t * d.x - f.x, ey = x.a.y + t * d.y - f.y, ez = x.a.z + t * d.z - f.z;
        if (std::sqrt(ex * ex + ey * ey + ez * ez) <= 2.0 * r && pr.depth(f) <= r) { near = true; break; }
      }
      if (near) flush.push_back(i);
    }
    if (!flush.empty()) {
      Bars again = laid;
      for (std::size_t i : flush) {
        Bar& x = again.bars[i];
        if (x.relief_a > 0.0 || x.relief_b > 0.0) x = without_relief(Bars{{x}}).bars.front();
        x.along_proud = 0.0;
        x.along_face = -1;
      }
      PrintableReport sub;
      TriangleMesh m2 = build_printable_mesh(part, domain, layout, again, open, spec, &sub);
      sub.relief_flushed += flush.size();
      for (std::size_t i : flush) sub.relief_flushed_at.push_back({bars.bars[i].a, bars.bars[i].b});   // OJ6
      sub.relief_rounds += 1;
      sub.ms += std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
      if (report) *report = sub;
      return m2;
    }
  }
  rep.flat_domes_at = ms.flat_domes_at;   // OS1 B, leg U: the held-flat ends, for the Exact preview
  rep.ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
  if (report) *report = rep;
  return mesh;
}

}  // namespace topopt::lattice_layout
