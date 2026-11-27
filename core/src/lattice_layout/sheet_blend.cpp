// SHEETS, where two sheet regions meet (notes28 sheets SPEC 1.5): builder E's file.
//   sheet_seams_across   where the two regions' spaces meet, as a grid (SheetSeamAcross), from the domain's own answer
//   sheet_seam_mm        that grid read at a point: the signed distance across the seam (+ toward b)
//   sheet_blend_distance_at   the blended field (the preview's and the Swift copy's form)
//   mesh_sheet_seam_band THE BAND: its true wall measured on the field it is contoured from (the tpms_probe march,
//                        along the blended field's normal both ways), raised in its middle until it is two lines
//                        everywhere (up to the touch), contoured with lattice_dc.hpp and simplified to the sheets' bound.
//                        One call per seam per file (the file's make_file_mesh); a band that cannot be raised to two
//                        lines falls back to the solid wall, with one plain line why.
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <map>
#include <string>
#include <thread>
#include <vector>

#include "topopt/lattice.hpp"
#include "topopt/lattice_dc.hpp"
#include "topopt/lattice_layout_mesh.hpp"
#include "topopt/mesh_simplify.hpp"
#include "topopt/tpms_gen.hpp"

namespace topopt::lattice_layout {

namespace {
double ms_since(std::chrono::steady_clock::time_point t0) {
  return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
}
int threads_of(int threads) {
  return threads > 0 ? threads : static_cast<int>(std::max(1u, std::thread::hardware_concurrency()));
}
constexpr double kInf = std::numeric_limits<double>::infinity();

struct Box3 { double lo[3], hi[3]; };
Box3 cell_box(const Layout& layout, const Cell& c, double grow) {
  const Frame& f = layout.frames[static_cast<std::size_t>(c.frame)];
  Box3 b;
  for (int a = 0; a < 3; ++a) { b.lo[a] = 1e300; b.hi[a] = -1e300; }
  for (int k = 0; k < 8; ++k) {
    const Vec3 v = f.at(c.lo[0] + ((k & 1) ? c.size : 0.0), c.lo[1] + ((k & 2) ? c.size : 0.0),
                        c.lo[2] + ((k & 4) ? c.size : 0.0));
    const double xyz[3] = {v.x, v.y, v.z};
    for (int a = 0; a < 3; ++a) { b.lo[a] = std::min(b.lo[a], xyz[a] - grow); b.hi[a] = std::max(b.hi[a], xyz[a] + grow); }
  }
  return b;
}
bool meet(const Box3& p, const Box3& q) {
  for (int a = 0; a < 3; ++a)
    if (p.lo[a] > q.hi[a] || q.lo[a] > p.hi[a]) return false;
  return true;
}

// The squared distance transform of one line (Felzenszwalb and Huttenlocher, 2012): f in, d out, node units.
void edt_line(const float* f, float* d, int n, std::vector<int>& v, std::vector<double>& z) {
  v.assign(static_cast<std::size_t>(n), 0);
  z.assign(static_cast<std::size_t>(n) + 1, 0.0);
  // The envelope starts at the first finite sample (1e20: no source along the line so far).
  int first = 0;
  while (first < n && !(f[first] < 1e19f)) ++first;
  if (first == n) {
    for (int q = 0; q < n; ++q) d[q] = 1e20f;
    return;
  }
  const auto cross = [&](int q, int p) {
    return ((static_cast<double>(f[q]) + static_cast<double>(q) * q) - (static_cast<double>(f[p]) + static_cast<double>(p) * p)) /
           (2.0 * (q - p));
  };
  int k = 0;
  v[0] = first;
  z[0] = -1e300;
  z[1] = 1e300;
  for (int q = first + 1; q < n; ++q) {
    if (!(f[q] < 1e19f)) continue;
    double s = cross(q, v[static_cast<std::size_t>(k)]);
    while (s <= z[static_cast<std::size_t>(k)]) {   // z[0] is -inf: stops at k = 0
      --k;
      s = cross(q, v[static_cast<std::size_t>(k)]);
    }
    ++k;
    v[static_cast<std::size_t>(k)] = q;
    z[static_cast<std::size_t>(k)] = s;
    z[static_cast<std::size_t>(k) + 1] = 1e300;
  }
  k = 0;
  for (int q = 0; q < n; ++q) {
    while (z[static_cast<std::size_t>(k) + 1] < static_cast<double>(q)) ++k;
    const int p = v[static_cast<std::size_t>(k)];
    d[q] = static_cast<float>(static_cast<double>(q - p) * (q - p) + f[p]);
  }
}
// The squared distance (node units) of every node of the grid to the nearest node where `src`: three passes.
void edt3(const std::vector<std::uint8_t>& label, std::uint8_t src, const int n[3], std::vector<float>& d2, int threads) {
  const std::size_t N = static_cast<std::size_t>(n[0]) * n[1] * n[2];
  d2.assign(N, 1e20f);
  for (std::size_t i = 0; i < N; ++i)
    if (label[i] == src) d2[i] = 0.0f;
  const auto idx = [&](int i, int j, int k) { return (static_cast<std::size_t>(k) * n[1] + j) * n[0] + i; };
  for (int axis = 0; axis < 3; ++axis) {
    const int len = n[axis];
    const int o1 = axis == 0 ? 1 : 0, o2 = axis == 2 ? 1 : 2;   // the other two axes
    const int lines = n[o1] * n[o2];
    std::atomic<int> next{0};
    auto work = [&] {
      std::vector<float> f(static_cast<std::size_t>(len)), d(static_cast<std::size_t>(len));
      std::vector<int> v;
      std::vector<double> z;
      for (int line = next++; line < lines; line = next++) {
        int c[3] = {0, 0, 0};
        c[o1] = line % n[o1];
        c[o2] = line / n[o1];
        for (int q = 0; q < len; ++q) {
          c[axis] = q;
          f[static_cast<std::size_t>(q)] = d2[idx(c[0], c[1], c[2])];
        }
        edt_line(f.data(), d.data(), len, v, z);
        for (int q = 0; q < len; ++q) {
          c[axis] = q;
          d2[idx(c[0], c[1], c[2])] = std::min(d[static_cast<std::size_t>(q)], 1e20f);
        }
      }
    };
    std::vector<std::thread> pool;
    for (int t = 1; t < threads; ++t) pool.emplace_back(work);
    work();
    for (std::thread& t : pool) t.join();
  }
}

// The grid read at p: the cubic B-spline over its nodes (smooth to the second derivative, so the blend's weight and its
// slope have no crease at the nodes' planes; it reproduces a flat meeting exactly), and its gradient. +infinity off it.
double across_at(const SheetSeamAcross& A, const Vec3& p, Vec3* grad = nullptr) {
  if (grad) *grad = {0.0, 0.0, 0.0};
  if (!A.ok || A.mm.empty() || !(A.h > 0.0)) return kInf;
  const double u[3] = {(p.x - A.origin.x) / A.h, (p.y - A.origin.y) / A.h, (p.z - A.origin.z) / A.h};
  int i0[3];
  double w[3][4], dw[3][4];
  for (int k = 0; k < 3; ++k) {
    if (!(u[k] >= 0.0) || u[k] > A.n[k] - 1) return kInf;
    int i = static_cast<int>(std::floor(u[k]));
    if (i > A.n[k] - 2) i = std::max(0, A.n[k] - 2);
    i0[k] = i;
    const double t = A.n[k] > 1 ? u[k] - i : 0.0, s = 1.0 - t;
    w[k][0] = s * s * s / 6.0;
    w[k][1] = (3.0 * t * t * t - 6.0 * t * t + 4.0) / 6.0;
    w[k][2] = (-3.0 * t * t * t + 3.0 * t * t + 3.0 * t + 1.0) / 6.0;
    w[k][3] = t * t * t / 6.0;
    dw[k][0] = -0.5 * s * s;
    dw[k][1] = 0.5 * (3.0 * t * t - 4.0 * t);
    dw[k][2] = 0.5 * (-3.0 * t * t + 2.0 * t + 1.0);
    dw[k][3] = 0.5 * t * t;
  }
  const auto node = [&](int k, int c) { return std::clamp(i0[k] - 1 + c, 0, A.n[k] - 1); };
  double v = 0.0, gx = 0.0, gy = 0.0, gz = 0.0;
  for (int c = 0; c < 4; ++c) {
    const std::size_t kk = static_cast<std::size_t>(node(2, c));
    for (int b = 0; b < 4; ++b) {
      const std::size_t jj = static_cast<std::size_t>(node(1, b));
      const double wyz = w[1][b] * w[2][c];
      const double dyz = dw[1][b] * w[2][c], ydz = w[1][b] * dw[2][c];
      for (int a = 0; a < 4; ++a) {
        const double m = A.mm[(kk * static_cast<std::size_t>(A.n[1]) + jj) * static_cast<std::size_t>(A.n[0]) +
                              static_cast<std::size_t>(node(0, a))];
        v += w[0][a] * wyz * m;
        gx += dw[0][a] * wyz * m;
        gy += w[0][a] * dyz * m;
        gz += w[0][a] * ydz * m;
      }
    }
  }
  if (grad) *grad = {gx / A.h, gy / A.h, gz / A.h};
  return v;
}
// The node nearest p: its label (255 off the grid).
std::uint8_t across_label(const SheetSeamAcross& A, const Vec3& p) {
  if (A.label.empty() || !(A.h > 0.0)) return 255;
  const long long i = std::llround((p.x - A.origin.x) / A.h), j = std::llround((p.y - A.origin.y) / A.h),
                  k = std::llround((p.z - A.origin.z) / A.h);
  if (i < 0 || j < 0 || k < 0 || i >= A.n[0] || j >= A.n[1] || k >= A.n[2]) return 255;
  return A.label[(static_cast<std::size_t>(k) * A.n[1] + static_cast<std::size_t>(j)) * A.n[0] + static_cast<std::size_t>(i)];
}

std::shared_ptr<const SheetSeamAcross> make_across(const Domain& domain, const Layout& layout,
                                                   const std::vector<SheetField>& sheets, const SheetSeamBand& seam,
                                                   int threads) {
  const auto t0 = std::chrono::steady_clock::now();
  auto out = std::make_shared<SheetSeamAcross>();
  if (seam.a < 0 || seam.b < 0 || static_cast<std::size_t>(seam.a) >= sheets.size() ||
      static_cast<std::size_t>(seam.b) >= sheets.size())
    return out;
  const SheetField& fa = sheets[static_cast<std::size_t>(seam.a)];
  const SheetField& fb = sheets[static_cast<std::size_t>(seam.b)];
  const double band = seam.band_mm > 0.0 ? seam.band_mm : std::max(fa.cell_mm, fb.cell_mm);
  double h = std::clamp(band / 12.0, 0.4, 1.2);
  // Each side's cells, and of them those within half a band and two nodes of a cell of the other.
  std::vector<Box3> A, B;
  for (const Cell& c : layout.cells) {
    if (c.region == fa.region && c.frame == fa.frame) A.push_back(cell_box(layout, c, 0.0));
    else if (c.region == fb.region && c.frame == fb.frame) B.push_back(cell_box(layout, c, 0.0));
  }
  if (A.empty() || B.empty()) return out;
  const auto near_of = [&](const std::vector<Box3>& mine, const std::vector<Box3>& other, double R) {
    const double pitch = std::max(4.0, R);
    const auto slot = [&](double x) { return static_cast<long long>(std::floor(x / pitch)); };
    std::map<std::array<long long, 3>, std::vector<std::uint32_t>> grid;
    for (std::size_t i = 0; i < other.size(); ++i)
      for (long long x = slot(other[i].lo[0]); x <= slot(other[i].hi[0]); ++x)
        for (long long y = slot(other[i].lo[1]); y <= slot(other[i].hi[1]); ++y)
          for (long long z = slot(other[i].lo[2]); z <= slot(other[i].hi[2]); ++z)
            grid[{x, y, z}].push_back(static_cast<std::uint32_t>(i));
    std::vector<char> on(mine.size(), 0);
    for (std::size_t i = 0; i < mine.size() ; ++i) {
      Box3 g = mine[i];
      for (int a = 0; a < 3; ++a) { g.lo[a] -= R; g.hi[a] += R; }
      for (long long x = slot(g.lo[0]); x <= slot(g.hi[0]) && !on[i]; ++x)
        for (long long y = slot(g.lo[1]); y <= slot(g.hi[1]) && !on[i]; ++y)
          for (long long z = slot(g.lo[2]); z <= slot(g.hi[2]) && !on[i]; ++z) {
            const auto it = grid.find({x, y, z});
            if (it == grid.end()) continue;
            for (std::uint32_t j : it->second)
              if (meet(g, other[j])) { on[i] = 1; break; }
          }
    }
    return on;
  };
  const double R = 0.5 * band + 3.0 * h;
  std::vector<Box3> zone;
  {
    const std::vector<char> na = near_of(A, B, R), nb = near_of(B, A, R);
    for (std::size_t i = 0; i < A.size(); ++i)
      if (na[i]) zone.push_back(A[i]);
    for (std::size_t i = 0; i < B.size(); ++i)
      if (nb[i]) zone.push_back(B[i]);
  }
  if (zone.empty()) return out;
  for (Box3& z : zone)
    for (int a = 0; a < 3; ++a) { z.lo[a] -= R; z.hi[a] += R; }
  double lo[3] = {1e300, 1e300, 1e300}, hi[3] = {-1e300, -1e300, -1e300};
  for (const Box3& z : zone)
    for (int a = 0; a < 3; ++a) { lo[a] = std::min(lo[a], z.lo[a]); hi[a] = std::max(hi[a], z.hi[a]); }
  // At most this many nodes (memory: a float and a byte each, two floats more while it is made); the pitch grows to fit.
  constexpr double kMostNodes = 4.0e6;
  int n[3];
  for (;;) {
    double total = 1.0;
    for (int a = 0; a < 3; ++a) {
      n[a] = static_cast<int>(std::ceil((hi[a] - lo[a]) / h)) + 1;
      total *= n[a];
    }
    if (total <= kMostNodes) break;
    h *= 1.15;
  }
  out->origin = {lo[0], lo[1], lo[2]};
  out->h = h;
  for (int a = 0; a < 3; ++a) out->n[a] = n[a];
  const std::size_t N = static_cast<std::size_t>(n[0]) * n[1] * n[2];
  std::vector<std::uint8_t>& label = out->label;
  label.assign(N, 255);
  constexpr std::uint8_t kToRead = 254;
  const auto idx = [&](int i, int j, int k) { return (static_cast<std::size_t>(k) * n[1] + j) * n[0] + i; };
  for (const Box3& z : zone) {
    int i0[3], i1[3];
    for (int a = 0; a < 3; ++a) {
      i0[a] = std::max(0, static_cast<int>(std::ceil((z.lo[a] - lo[a]) / h - 1e-9)));
      i1[a] = std::min(n[a] - 1, static_cast<int>(std::floor((z.hi[a] - lo[a]) / h + 1e-9)));
    }
    for (int k = i0[2]; k <= i1[2]; ++k)
      for (int j = i0[1]; j <= i1[1]; ++j)
        for (int i = i0[0]; i <= i1[0]; ++i) label[idx(i, j, k)] = kToRead;
  }
  // Whose lattice each node is, by the domain (each thread its own probe; slabs of z, the same answer any way round).
  const int nt = threads_of(threads);
  std::atomic<int> next{0};
  std::atomic<std::size_t> read{0};
  auto work = [&] {
    const Domain::Probe probe = domain.probe();
    std::size_t mine = 0;
    for (int k = next++; k < n[2]; k = next++)
      for (int j = 0; j < n[1]; ++j)
        for (int i = 0; i < n[0]; ++i) {
          std::uint8_t& l = label[idx(i, j, k)];
          if (l != kToRead) continue;
          ++mine;
          const Where w = probe.where({lo[0] + i * h, lo[1] + j * h, lo[2] + k * h});
          l = !w.lattice() ? 0 : w.id == fa.region ? 1 : w.id == fb.region ? 2 : 0;
        }
    read += mine;
  };
  {
    std::vector<std::thread> pool;
    for (int t = 1; t < nt; ++t) pool.emplace_back(work);
    work();
    for (std::thread& t : pool) t.join();
  }
  out->nodes_read = read.load();
  std::size_t na = 0, nb = 0;
  for (std::uint8_t l : label) { na += l == 1; nb += l == 2; }
  if (!na || !nb) {
    out->ms = ms_since(t0);
    return out;   // the two never meet here: no blend
  }
  std::vector<float> da2, db2;
  edt3(label, 1, n, da2, nt);
  edt3(label, 2, n, db2, nt);
  std::vector<float>& v = out->mm;
  v.assign(N, 0.0f);
  for (std::size_t e = 0; e < N; ++e) {
    const double da = std::sqrt(static_cast<double>(da2[e])) * h, db = std::sqrt(static_cast<double>(db2[e])) * h;
    double x;
    if (label[e] == 1) x = -(db - 0.5 * h);
    else if (label[e] == 2) x = da - 0.5 * h;
    else x = da - db;
    v[e] = static_cast<float>(x);
  }
  da2 = {};
  db2 = {};
  // One [1 2 1] / 4 pass per axis: a flat meeting (a linear field) is kept exactly; a slanted one loses its steps.
  {
    std::vector<float> t(N);
    for (int axis = 0; axis < 3; ++axis) {
      const std::size_t stride = axis == 0 ? 1 : axis == 1 ? static_cast<std::size_t>(n[0]) : static_cast<std::size_t>(n[0]) * n[1];
      for (int k = 0; k < n[2]; ++k)
        for (int j = 0; j < n[1]; ++j)
          for (int i = 0; i < n[0]; ++i) {
            const std::size_t e = idx(i, j, k);
            const int c = axis == 0 ? i : axis == 1 ? j : k;
            const float m = v[e];
            const float l = c > 0 ? v[e - stride] : m;
            const float r = c < n[axis] - 1 ? v[e + stride] : m;
            t[e] = 0.25f * l + 0.5f * m + 0.25f * r;
          }
      v.swap(t);
    }
  }
  out->ok = true;
  out->ms = ms_since(t0);
  return out;
}
}  // namespace

// ── the blend's weights ─────────────────────────────────────────────────────────────────────────────────────────
double sheet_seam_weight(double seam_mm, double band_mm) {
  if (!(band_mm > 0.0)) return seam_mm >= 0.0 ? 1.0 : 0.0;
  const double t = std::clamp((seam_mm + 0.5 * band_mm) / band_mm, 0.0, 1.0);
  return t * t * (3.0 - 2.0 * t);
}

double sheet_seam_bump(double seam_mm, double band_mm) {
  if (!(band_mm > 0.0)) return 0.0;
  const double x = std::clamp((seam_mm + 0.5 * band_mm) / band_mm, 0.0, 1.0);
  const double q = 4.0 * x * (1.0 - x);
  return q * q;
}

namespace {
// The smaller of two clips with their crease rounded over `k` (the polynomial smooth minimum): never above min(a, b).
double soft_min(double a, double b, double k) {
  const double t = std::max(k - std::fabs(a - b), 0.0) / k;
  return std::min(a, b) - 0.25 * t * t * k;
}
// The smoothstep's slope across the seam, per mm.
double seam_weight_slope(double seam_mm, double band_mm) {
  if (!(band_mm > 0.0)) return 0.0;
  const double x = (seam_mm + 0.5 * band_mm) / band_mm;
  if (!(x > 0.0) || !(x < 1.0)) return 0.0;
  return 6.0 * x * (1.0 - x) / band_mm;
}
}  // namespace

namespace {
// A field's own function in mm (f x L / 2 pi: tpms_eval's f, whose gradient is about one per mm near its sheet) and its
// gradient, in the part's axes.
struct Raw { double g = 0.0; Vec3 grad{0.0, 0.0, 0.0}; };
Raw raw_at(const SheetField& f, const Vec3& p) {
  Raw r;
  if (!(f.cell_mm > 0.0)) return r;
  const Vec3 q = sheet_local(f, p);
  const TpmsValue v = tpms_eval(f.kind, q.x - f.anchor[0], q.y - f.anchor[1], q.z - f.anchor[2], f.cell_mm);
  const double k = f.cell_mm / (2.0 * 3.14159265358979323846);
  const Frame& fr = f.axes;
  r.g = v.f * k;
  r.grad = {k * (v.gx * fr.ax[0].x + v.gy * fr.ax[1].x + v.gz * fr.ax[2].x),
            k * (v.gx * fr.ax[0].y + v.gy * fr.ax[1].y + v.gz * fr.ax[2].y),
            k * (v.gx * fr.ax[0].z + v.gy * fr.ax[1].z + v.gz * fr.ax[2].z)};
  return r;
}
// THE BLENDED MID-SURFACE DISTANCE: the two fields' own functions mixed, phi = (1 - s) g_a + s g_b (the hybrid-TPMS
// literature's sigmoid transition: a mix of the level-set functions, smooth and bounded everywhere), over the length of
// phi's own gradient, (1 - s) grad g_a + s grad g_b + (g_b - g_a) grad s, grad s = s'(m) grad m: a distance to first
// order, so the wall |F| < t / 2 is t thick across the band as it is in each region. At s = 0 it is
// sheet_mid_distance_at(a) exactly (f / |grad f| does not see the scale), at s = 1 b's. (Mixing the two f / |grad f|
// instead mixes in a field read far from its own sheet, where it runs away near its nodes: walls 0.07 mm thick, measured
// on the cube's seam; leaving grad s out thins the wall where the weight changes fastest, to 0.5 mm there.)
// The gradient's length is read no shorter than kBlendGradFloor: where the mix's gradient all but vanishes (a neck, where
// the blended surface changes how it joins) phi / |grad phi| is no distance at all and the bounded simplifier refined
// there without end (measured, Schwarz-D 6 / 8 mm on the cube); read so, the wall there is only thicker, and every
// region's own sheet is the same (its gradient on its sheet is never under sqrt 2, f x L / 2 pi; measured).
constexpr double kBlendGradFloor = 0.5;
double blend_mid(const SheetField& a, const SheetField& b, double s, const Vec3& grad_s, const Vec3& p) {
  const Raw ra = s < 1.0 ? raw_at(a, p) : Raw{}, rb = s > 0.0 ? raw_at(b, p) : Raw{};
  const double phi = (1.0 - s) * ra.g + s * rb.g;
  const double dg = rb.g - ra.g;
  const Vec3 G{(1.0 - s) * ra.grad.x + s * rb.grad.x + dg * grad_s.x, (1.0 - s) * ra.grad.y + s * rb.grad.y + dg * grad_s.y,
               (1.0 - s) * ra.grad.z + s * rb.grad.z + dg * grad_s.z};
  const double gl = std::sqrt(G.x * G.x + G.y * G.y + G.z * G.z);
  return phi / std::max(gl, kBlendGradFloor);
}
}  // namespace

double sheet_blend_mid_at(const SheetField& a, const SheetField& b, const SheetSeamBand& seam, double seam_mm,
                          const Vec3& seam_grad, const Vec3& p) {
  const double s = sheet_seam_weight(seam_mm, seam.band_mm);
  const double ds = seam_weight_slope(seam_mm, seam.band_mm);
  return blend_mid(a, b, s, {ds * seam_grad.x, ds * seam_grad.y, ds * seam_grad.z}, p);
}

double sheet_blend_distance_at(const SheetField& a, const SheetField& b, const SheetSeamBand& seam, double seam_mm,
                               const Vec3& seam_grad, const Vec3& p) {
  const double s = sheet_seam_weight(seam_mm, seam.band_mm);
  const double ds = seam_weight_slope(seam_mm, seam.band_mm);
  const double F = blend_mid(a, b, s, {ds * seam_grad.x, ds * seam_grad.y, ds * seam_grad.z}, p);
  const double ta = s < 1.0 ? sheet_param_at(a, p) : 0.0;
  const double tb = s > 0.0 ? sheet_param_at(b, p) : 0.0;
  const double t = (1.0 - s) * ta + s * tb + seam.raise_mm * sheet_seam_bump(seam_mm, seam.band_mm);
  return std::fabs(F) - 0.5 * t;
}

double sheet_seam_mm(const Domain& domain, const SheetSeamBand& seam, const Vec3& p, Vec3* grad) {
  (void)domain;
  if (grad) *grad = {0.0, 0.0, 0.0};
  if (!seam.across) return kInf;
  return across_at(*seam.across, p, grad);
}

void sheet_seams_across(const Domain& domain, const Layout& layout, const std::vector<SheetField>& sheets,
                        std::vector<SheetSeamBand>& seams, int threads) {
  for (SheetSeamBand& s : seams) {
    if (s.solid_wall) continue;
    s.across = make_across(domain, layout, sheets, s, threads);
  }
}

// ── THE BAND (SPEC 1.5) ─────────────────────────────────────────────────────────────────────────────────────────
namespace {
std::string region_name(int r) { return r == 0 ? std::string("the whole part") : "region " + std::to_string(r); }
}  // namespace

SeamBand mesh_sheet_seam_band(const Domain& domain, const Layout& layout, const std::vector<SheetField>& sheets,
                              const SheetSeamBand& seam, const MeshSpec& spec) {
  const auto t0 = std::chrono::steady_clock::now();
  SeamBand out;
  out.ok = false;
  if (seam.a < 0 || seam.b < 0 || static_cast<std::size_t>(seam.a) >= sheets.size() ||
      static_cast<std::size_t>(seam.b) >= sheets.size()) {
    out.why = "Two lattices meet where no blend could be made, so a solid wall joins them.";
    return out;
  }
  const std::string who = "The lattices of " + region_name(seam.region_a) + " and " + region_name(seam.region_b);
  std::shared_ptr<const SheetSeamAcross> across = seam.across;
  if (!across) across = make_across(domain, layout, sheets, seam, spec.threads);   // a seam made by hand
  if (!across->ok) {
    out.why = who + " do not meet anywhere a blend could run, so a solid wall joins them.";
    return out;
  }
  const SheetSeamAcross& X = *across;
  const SheetField& A = sheets[static_cast<std::size_t>(seam.a)];
  const SheetField& B = sheets[static_cast<std::size_t>(seam.b)];
  const LatticeTopology ta_topo = sheet_topology(A.kind), tb_topo = sheet_topology(B.kind);
  const double band = seam.band_mm > 0.0 ? seam.band_mm : std::max(A.cell_mm, B.cell_mm);
  const double dev = std::max(0.0, spec.sheet_deviation_mm);
  const double floor_mm = layout.min_strut_mm > 0.0 ? layout.min_strut_mm : 0.9;
  const double bead = dev > 0.0 ? floor_mm / (1.0 - kSheetWallUnevenness) : 0.0;
  // Each region's own sheet is contoured at its print wall (make_sheets): the band contours each side's the same way,
  // so where its weight is 0 or 1 it IS that sheet, and the two meet in their overlap with no step.
  const auto param_of = [&](const SheetField& f, LatticeTopology topo, double w) {
    if (!(w > 0.0)) return 0.0;
    const double raised = sheet_print_wall_mm(w, floor_mm, dev);
    const double contoured = dev > 0.0 ? tpms_contoured_wall_mm(raised, bead, dev) : raised;
    return lattice_sheet_wall_param_mm(topo, contoured, f.cell_mm);
  };
  // (one wall all over a region: its parameter once)
  const double one_a = A.wall_mm.size() == 1 ? param_of(A, ta_topo, A.wall_mm.front()) : -1.0;
  const double one_b = B.wall_mm.size() == 1 ? param_of(B, tb_topo, B.wall_mm.front()) : -1.0;
  const auto file_param = [&](const SheetField& f, LatticeTopology topo, const Vec3& p) {
    const double one = &f == &A ? one_a : one_b;
    return one >= 0.0 ? one : param_of(f, topo, sheet_wall_at(f, p));
  };
  struct At { double d = 0, F = 0, T = 0, bump = 0, m = 0; bool on = false; };
  const auto at = [&](const Vec3& p, double raise) {
    At r;
    Vec3 gm;
    r.m = across_at(X, p, &gm);
    if (!std::isfinite(r.m)) return r;
    r.on = true;
    const double s = sheet_seam_weight(r.m, band), ds = seam_weight_slope(r.m, band);
    r.bump = sheet_seam_bump(r.m, band);
    const double pa = s < 1.0 ? file_param(A, ta_topo, p) : 0.0, pb = s > 0.0 ? file_param(B, tb_topo, p) : 0.0;
    r.F = blend_mid(A, B, s, {ds * gm.x, ds * gm.y, ds * gm.z}, p);
    r.T = (1.0 - s) * pa + s * pb + raise * r.bump;
    r.d = std::fabs(r.F) - 0.5 * r.T;
    return r;
  };
  const auto grad_F = [&](const Vec3& p, double raise) {
    const double e = 1e-3;
    const double gx = at({p.x + e, p.y, p.z}, raise).F - at({p.x - e, p.y, p.z}, raise).F;
    const double gy = at({p.x, p.y + e, p.z}, raise).F - at({p.x, p.y - e, p.z}, raise).F;
    const double gz = at({p.x, p.y, p.z + e}, raise).F - at({p.x, p.y, p.z - e}, raise).F;
    return Vec3{gx / (2 * e), gy / (2 * e), gz / (2 * e)};
  };

  // ── (a) THE TRUE WALL in the band: points of its blended mid-surface (F = 0) in either region's lattice, within
  // half a band of the seam; at each, the wall along the field's normal both ways (where |F| reaches half the wall). ──
  struct Sample { Vec3 q, n; double T0 = 0, bump = 0, w = 0; bool ok = false; };
  std::vector<Sample> samples;
  {
    std::size_t cand = 0;
    const std::size_t N = X.label.size();
    for (std::size_t e = 0; e < N; ++e)
      cand += (X.label[e] == 1 || X.label[e] == 2) && std::fabs(X.mm[e]) < 0.5 * band;
    constexpr double kStarts = 6000.0;
    const int stride = std::max(1, static_cast<int>(std::ceil(std::cbrt(static_cast<double>(cand) / kStarts))));
    for (int k = 0; k < X.n[2]; k += stride)
      for (int j = 0; j < X.n[1]; j += stride)
        for (int i = 0; i < X.n[0]; i += stride) {
          const std::size_t e = (static_cast<std::size_t>(k) * X.n[1] + j) * X.n[0] + i;
          if (!(X.label[e] == 1 || X.label[e] == 2) || !(std::fabs(X.mm[e]) < 0.5 * band)) continue;
          Sample s;
          s.q = {X.origin.x + i * X.h, X.origin.y + j * X.h, X.origin.z + k * X.h};
          samples.push_back(s);
        }
  }
  const int nt = threads_of(spec.threads);
  // Onto the mid-surface (Newton on F), each start on its own: the same points any way round.
  {
    std::atomic<std::size_t> next{0};
    auto work = [&] {
      for (std::size_t i = next++; i < samples.size(); i = next++) {
        Sample& s = samples[i];
        Vec3 q = s.q;
        bool on = false;
        for (int it = 0; it < 16; ++it) {
          const At v = at(q, 0.0);
          if (!v.on) break;
          const Vec3 g = grad_F(q, 0.0);
          const double g2 = g.x * g.x + g.y * g.y + g.z * g.z;
          if (!(g2 > 1e-8)) break;
          if (std::fabs(v.F) / std::sqrt(g2) < 1e-5) { on = true; break; }
          const double t = v.F / g2;
          q = {q.x - t * g.x, q.y - t * g.y, q.z - t * g.z};
        }
        if (!on) continue;
        const double dx = q.x - s.q.x, dy = q.y - s.q.y, dz = q.z - s.q.z;
        if (dx * dx + dy * dy + dz * dz > 4.0 * X.h * X.h) continue;
        const std::uint8_t l = across_label(X, q);
        if (l != 1 && l != 2) continue;
        const At v = at(q, 0.0);
        if (!v.on || !(std::fabs(v.m) < 0.5 * band)) continue;
        const Vec3 g = grad_F(q, 0.0);
        const double gl = std::sqrt(g.x * g.x + g.y * g.y + g.z * g.z);
        if (!(gl > 1e-6)) continue;
        s.q = q;
        s.n = {g.x / gl, g.y / gl, g.z / gl};
        s.T0 = v.T;
        s.bump = v.bump;
        s.ok = true;
      }
    };
    std::vector<std::thread> pool;
    for (int t = 1; t < nt; ++t) pool.emplace_back(work);
    work();
    for (std::thread& t : pool) t.join();
    std::vector<Sample> kept;
    for (const Sample& s : samples)
      if (s.ok) kept.push_back(s);
    samples.swap(kept);
  }
  // The wall at every sample with the band raised by `raise`: the reach to |F| = T / 2 along +n and -n (0.02 mm steps
  // to 4 mm, then a bisection); a sample whose wall does not end within 4 mm both ways is a lump, not a thin place.
  const auto measure = [&](double raise) {
    std::atomic<std::size_t> next{0};
    auto work = [&] {
      for (std::size_t i = next++; i < samples.size(); i = next++) {
        Sample& s = samples[i];
        double w = 0.0;
        bool ends = true;
        for (int side = -1; side <= 1 && ends; side += 2) {
          const Vec3 n{side * s.n.x, side * s.n.y, side * s.n.z};
          double a = 0.0, b = -1.0;
          for (double t = 0.02; t <= 4.0 + 1e-9; t += 0.02) {
            const At v = at({s.q.x + t * n.x, s.q.y + t * n.y, s.q.z + t * n.z}, raise);
            if (!v.on || v.d > 0.0) { b = t; break; }
            a = t;
          }
          if (b < 0.0) { ends = false; break; }
          for (int it = 0; it < 12; ++it) {
            const double m = 0.5 * (a + b);
            const At v = at({s.q.x + m * n.x, s.q.y + m * n.y, s.q.z + m * n.z}, raise);
            if (!v.on || v.d > 0.0) b = m; else a = m;
          }
          w += 0.5 * (a + b);
        }
        s.w = ends ? w : kInf;
      }
    };
    std::vector<std::thread> pool;
    for (int t = 1; t < nt; ++t) pool.emplace_back(work);
    work();
    for (std::thread& t : pool) t.join();
    double thinnest = kInf;
    for (const Sample& s : samples) thinnest = std::min(thinnest, s.w);
    return thinnest;
  };
  // ── (b) THE RAISE: in the band's middle (sheet_seam_bump), until the thinnest wall is two lines with 0.6 of the bound
  // to spare on each face (the least the simplifier is then let in by: nearer the floor its refining runs away, as the
  // sheets' own guard found), never past the touch (the two cells' touch walls' mean in the middle). Each region's own
  // sheet at the floor is contoured 0.06 mm over it (its print wall, uneven by up to 3 %: 0.931 at a 0.9 floor): the
  // band's edges, which are those sheets, pass. ──
  const double target = floor_mm + 1.2 * dev + 0.005;
  const auto touch_param = [](const SheetField& f, LatticeTopology topo) {
    return lattice_sheet_wall_param_mm(topo, lattice_width_bounds(topo).touch * f.cell_mm, f.cell_mm) -
           lattice_sheet_wall_param_mm(topo, f.wall_max_mm, f.cell_mm);
  };
  double cap = 0.5 * touch_param(A, ta_topo) + 0.5 * touch_param(B, tb_topo);
  if (spec.sheet_seam_raise_cap_mm >= 0.0) cap = std::min(cap, spec.sheet_seam_raise_cap_mm);
  double raise = 0.0;
  double thinnest = samples.empty() ? kInf : measure(0.0);
  if (spec.sheet_seam_raise) {
    for (int round = 0; round < 8 && thinnest < target; ++round) {
      double need = 0.0;
      for (const Sample& s : samples) {
        if (!(s.w < target)) continue;
        const double T = s.T0 + raise * s.bump;
        need = std::max(need, (target - s.w) * (T / std::max(s.w, 1e-3)) / std::max(s.bump, 0.1));
      }
      raise += 1.1 * need + 0.005;
      if (raise > cap) break;
      thinnest = measure(raise);
    }
    if (thinnest < target) {
      char b[160];
      std::snprintf(b, sizeof b, " (its thinnest wall %.2f mm; raised %.2f mm, the most before its channels close %.2f mm)",
                    thinnest, raise, cap);
      out.why = who + " could not be blended into each other with a wall two lines thick everywhere, so a solid wall "
                "joins them." + b;
      out.raise_mm = raise;
      out.thinnest_mm = thinnest;
      out.samples = samples.size();
      out.ms = ms_since(t0);
      return out;
    }
  }
  out.raise_mm = raise;
  out.thinnest_mm = thinnest;
  // The simplifier may sit inside each face by half of what the thinnest wall has over the floor, never more than the
  // bound (and never under 0.6 of it, which the target spared): the file's band wall is never under two lines. The band
  // is CONTOURED each face out by half of what that leaves of the bound (the sheets' own way, tpms_contoured_wall_mm),
  // so the contouring's chords have the same room both ways about what it contours.
  const double max_in =
      std::clamp(0.5 * ((std::isfinite(thinnest) ? thinnest : floor_mm + 2.0 * dev) - floor_mm - 0.002), 0.6 * dev, dev);
  const double offset = dev - max_in;   // added to the band's parameter where it is contoured

  // ── (c) THE BAND'S MESH: dual contouring of the blended field over the band (and as far past each edge as a sheet
  // block runs into its neighbour, so it overlaps each region's own sheet, which stops that far inside the band),
  // simplified against the same field to the sheets' bound: out by `dev`, in by `max_in`. ──
  const double h = std::max(1e-3, std::min({std::min(A.wall_min_mm, B.wall_min_mm) / 3.0, A.cell_mm / 24.0,
                                            B.cell_mm / 24.0}));
  const double run_on = spec.strut_reach_mm >= 0.0 ? spec.strut_reach_mm : 0.5 * 0.25 + 0.02 + 0.05;
  const double g = run_on + 3.0 * h + 0.05;
  const double reach = 0.5 * band + g;
  double lo[3] = {1e300, 1e300, 1e300}, hi[3] = {-1e300, -1e300, -1e300};
  {
    bool any = false;
    for (int k = 0; k < X.n[2]; ++k)
      for (int j = 0; j < X.n[1]; ++j)
        for (int i = 0; i < X.n[0]; ++i) {
          const std::size_t e = (static_cast<std::size_t>(k) * X.n[1] + j) * X.n[0] + i;
          if (!(X.label[e] == 1 || X.label[e] == 2) || !(std::fabs(X.mm[e]) <= reach + X.h)) continue;
          const double p[3] = {X.origin.x + i * X.h, X.origin.y + j * X.h, X.origin.z + k * X.h};
          for (int a = 0; a < 3; ++a) { lo[a] = std::min(lo[a], p[a] - X.h); hi[a] = std::max(hi[a], p[a] + X.h); }
          any = true;
        }
    if (!any) {
      out.ok = true;   // nothing of either region lies within the band: nothing to blend, nothing to mesh
      return out;
    }
  }
  // In blocks (as the sheets are: kSheetBlockMm a side at most), each contoured and simplified on its own thread,
  // each running `gb` past its own box into its neighbours (clear of its own crease there), so the union joins them
  // with no seam. Each block's field: the band's, cut by the band's reach and by its own box grown by `gb`.
  constexpr double kBlockMm = 30.0;
  const double gb = 3.0 * h + 0.05;
  int nb[3];
  for (int a = 0; a < 3; ++a) nb[a] = std::max(1, static_cast<int>(std::ceil((hi[a] - lo[a]) / kBlockMm - 1e-9)));
  struct Block { double lo[3], hi[3]; };
  std::vector<Block> blocks;
  for (int k = 0; k < nb[2]; ++k)
    for (int j = 0; j < nb[1]; ++j)
      for (int i = 0; i < nb[0]; ++i) {
        Block b;
        const int ix[3] = {i, j, k};
        for (int a = 0; a < 3; ++a) {
          const double step = (hi[a] - lo[a]) / nb[a];
          b.lo[a] = lo[a] + ix[a] * step - (ix[a] > 0 ? gb : h);
          b.hi[a] = lo[a] + (ix[a] + 1) * step + (ix[a] + 1 < nb[a] ? gb : h);
        }
        blocks.push_back(b);
      }
  // Is a block's mesh one closed, oriented surface, as build_mesh's union reads it (corners at one place welded,
  // two-corner triangles left out)? Dual contouring can pinch where two walls of the blend all but touch (an edge of
  // four triangles): such a block is contoured again on a grid moved by a fraction of a cell (at most five times;
  // measured on the cube, Schwarz-D 6 / 8 mm: closed on the third).
  const auto closed_mesh = [](const TriangleMesh& m) {
    std::map<std::array<double, 3>, std::uint64_t> at;
    std::map<std::pair<std::uint64_t, std::uint64_t>, int> edges;
    std::vector<std::uint64_t> idx(m.vertices.size());
    for (std::size_t v = 0; v < m.vertices.size(); ++v)
      idx[v] = at.emplace(std::array<double, 3>{m.vertices[v].x, m.vertices[v].y, m.vertices[v].z}, at.size()).first->second;
    for (const auto& t : m.triangles) {
      const std::uint64_t c[3] = {idx[static_cast<std::size_t>(t[0])], idx[static_cast<std::size_t>(t[1])],
                                  idx[static_cast<std::size_t>(t[2])]};
      if (c[0] == c[1] || c[1] == c[2] || c[0] == c[2]) continue;
      for (int k = 0; k < 3; ++k) ++edges[{c[k], c[(k + 1) % 3]}];
    }
    for (const auto& [e, n] : edges) {
      const auto it = edges.find({e.second, e.first});
      if (n != 1 || it == edges.end() || it->second != 1) return false;
    }
    return true;
  };
  out.blocks.assign(blocks.size(), TriangleMesh{});
  std::vector<char> block_ok(blocks.size(), 0);
  std::vector<int> block_tries(blocks.size(), 0);
  std::atomic<std::size_t> next_block{0};
  const auto contour = [&] {
    for (std::size_t bi = next_block++; bi < blocks.size(); bi = next_block++) {
      if (spec.stop && spec.stop->load()) break;
      const Block& B0 = blocks[bi];
      // The block's own clip (positive inside its box grown by a DC cell, which the field's erosion takes back) and the
      // band's (|m| up to `reach`).
      const double bl[3] = {B0.lo[0] - h, B0.lo[1] - h, B0.lo[2] - h}, bh[3] = {B0.hi[0] + h, B0.hi[1] + h, B0.hi[2] + h};
      // The box with its edges and corners rounded (radius two DC cells): where three cut planes and a wall meet at a
      // corner the contouring pinched the surface into an edge of four triangles (measured on the cube's seam, outside
      // the part at the block's corners); a rounded one it cuts like any curved face. Positive inside.
      const auto round_box = [&](const Vec3& p) {
        const double r = 2.0 * h;
        const double xyz[3] = {p.x, p.y, p.z};
        double out2 = 0.0, in = -1e300;
        for (int a = 0; a < 3; ++a) {
          const double c = 0.5 * (bl[a] + bh[a]), half = std::max(0.5 * (bh[a] - bl[a]) - r, 0.0);
          const double q = std::fabs(xyz[a] - c) - half;
          if (q > 0.0) out2 += q * q;
          in = std::max(in, q);
        }
        return -(std::sqrt(out2) + std::min(in, 0.0) - r);
      };
      // The band's field with its parameter raised by `more` (0: the field measured above, the simplifier's TRUE one;
      // `offset`: the one contoured), cut by the block and the band's reach.
      const auto field_at = [&](const Vec3& p, double more) {
        const double box = round_box(p);
        if (h - box > 2.0 * h) return h - box;
        Vec3 gm;
        const double m = across_at(X, p, &gm);
        if (!std::isfinite(m)) return std::max(h, h - box);
        const double clip = soft_min(box, reach + h - std::fabs(m), 2.0 * h);
        if (h - clip > 2.0 * h) return h - clip;   // far outside the band: its distance decides
        const double s = sheet_seam_weight(m, band), bump = sheet_seam_bump(m, band), ds = seam_weight_slope(m, band);
        const double T = (s < 1.0 ? (1.0 - s) * file_param(A, ta_topo, p) : 0.0) +
                         (s > 0.0 ? s * file_param(B, tb_topo, p) : 0.0) + raise * bump + more;
        return std::max(std::fabs(blend_mid(A, B, s, {ds * gm.x, ds * gm.y, ds * gm.z}, p)) - 0.5 * T, h - clip);
      };
      const std::function<double(const Vec3&)> truth = [&](const Vec3& p) { return field_at(p, 0.0); };
      const std::function<double(const Vec3&)> contoured = [&](const Vec3& p) { return field_at(p, offset); };
      const double e = std::max(1e-4, 0.01 * h);
      const std::function<Vec3(const Vec3&)> grad = [&](const Vec3& p) {
        const Vec3 gg{contoured({p.x + e, p.y, p.z}) - contoured({p.x - e, p.y, p.z}),
                      contoured({p.x, p.y + e, p.z}) - contoured({p.x, p.y - e, p.z}),
                      contoured({p.x, p.y, p.z + e}) - contoured({p.x, p.y, p.z - e})};
        const double l = std::sqrt(gg.x * gg.x + gg.y * gg.y + gg.z * gg.z);
        return l > 1e-12 ? Vec3{gg.x / l, gg.y / l, gg.z / l} : Vec3{0, 0, 1};
      };
      for (int attempt = 0; attempt < 6 && !block_ok[bi]; ++attempt) {
        block_tries[bi] = attempt + 1;
        MeshSink collect;
        const double sh[3] = {std::fmod(0.37 * attempt, 1.0) * h, std::fmod(0.23 * attempt, 1.0) * h, std::fmod(0.29 * attempt, 1.0) * h};
        const Vec3 box_lo{bl[0] - h - sh[0], bl[1] - h - sh[1], bl[2] - h - sh[2]}, box_hi{bh[0] + h, bh[1] + h, bh[2] + h};
        if (dev > 0.0) {
          BoundedSimplifyOptions so;
          so.max_out_mm = dev;
          so.max_in_mm = [max_in](const Vec3&) { return max_in; };
          so.sample_spacing_mm = std::min(0.1, 0.5 * h);
          // The whole band is read as a cut (its own band, never refined): simplified only within +-max_in of the TRUE
          // surface both ways, and kept as contoured where the contouring left it outside. Refined like a sheet, the
          // blend's band ran away (measured: Schwarz-D 6 / 8 mm on the cube, minutes on one 10 mm block, a sheet's
          // contouring there splitting without end); as contoured on the outward offset its chords sit within a
          // hundredth of a millimetre (DC cell a third of the wall), inside what the target spared.
          so.at_cut = [](const Vec3&) { return true; };
          so.cut_tol_mm = max_in;
          so.slab_mm = std::max(64.0, 4.0 * std::max(A.cell_mm, B.cell_mm));
          so.front_margin_mm = 3.0 * h;
          BoundedSimplifySink simp(collect, truth, so);
          lattice_dual_contour_field(contoured, grad, box_lo, box_hi, h, simp, 12, 0.02, /*best_diagonal=*/true);
          simp.finish();
        } else {
          lattice_dual_contour_field(truth, grad, box_lo, box_hi, h, collect, 12, 0.02, /*best_diagonal=*/true);
        }
        block_ok[bi] = collect.mesh.triangles.empty() || closed_mesh(collect.mesh);
        out.blocks[bi] = std::move(collect.mesh);
      }
    }
  };
  {
    const int bt = static_cast<int>(std::min<std::size_t>(static_cast<std::size_t>(nt), blocks.size()));
    std::vector<std::thread> pool;
    for (int t = 1; t < bt; ++t) pool.emplace_back(contour);
    contour();
    for (std::thread& t : pool) t.join();
  }
  if (spec.stop && spec.stop->load()) throw LayCancelled{};
  for (std::size_t bi = 0; bi < blocks.size(); ++bi) {
    out.retries += static_cast<std::size_t>(std::max(0, block_tries[bi] - 1));
    if (block_ok[bi]) continue;
    // A band that is not closed is no band: the seam falls back here, never in the file.
    out.why = who + " were blended, but the blend's surface could not be closed, so a solid wall joins them.";
    out.blocks.clear();
    out.ms = ms_since(t0);
    return out;
  }
  {   // empty blocks (the band does not reach them) are dropped
    std::vector<TriangleMesh> some;
    for (TriangleMesh& m : out.blocks)
      if (!m.triangles.empty()) some.push_back(std::move(m));
    out.blocks.swap(some);
  }
  for (const TriangleMesh& m : out.blocks) out.triangles += m.triangles.size();
  const double half = 0.5 * band;
  out.keep_a = [across, half](const Vec3& p) {
    const double m = across_at(*across, p);
    return !std::isfinite(m) || m <= -half;
  };
  out.keep_b = [across, half](const Vec3& p) {
    const double m = across_at(*across, p);
    return !std::isfinite(m) || m >= half;
  };
  out.ok = true;
  out.ms = ms_since(t0);
  out.samples = samples.size();
  return out;
}

}  // namespace topopt::lattice_layout
