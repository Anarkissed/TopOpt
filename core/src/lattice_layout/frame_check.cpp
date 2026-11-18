// The Organic strength check as a frame of beams (brief E2, Part A; lattice_layout_frame.hpp). A port of the
// prototype's last version (organic/frame/run_v21.py, frame.py, asm_v2.py, loop/raster.py) with the lead's rulings:
// the load on the frame for any part (item 5), the drive ball in voxels (item 4), the minimum piece in both modes.
#include "topopt/lattice_layout_frame.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <limits>
#include <memory>
#include <numeric>
#include <thread>
#include <unordered_map>

#include "topopt/fea.hpp"
#include "topopt/lattice_union_volume.hpp"
#include "topopt/sparse_ldlt.hpp"

namespace topopt::lattice_layout {
namespace {

double ms_since(std::chrono::steady_clock::time_point t0) {
  return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
}
Vec3 sub3(const Vec3& a, const Vec3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
double dot3(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
double len3(const Vec3& a) { return std::sqrt(dot3(a, a)); }
Vec3 cross3(const Vec3& a, const Vec3& b) { return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}; }

struct UnionFind {
  std::vector<int> p;
  explicit UnionFind(std::size_t n) : p(n) { std::iota(p.begin(), p.end(), 0); }
  int find(int x) {
    while (p[static_cast<std::size_t>(x)] != x) {
      p[static_cast<std::size_t>(x)] = p[static_cast<std::size_t>(p[static_cast<std::size_t>(x)])];
      x = p[static_cast<std::size_t>(x)];
    }
    return x;
  }
  void unite(int a, int b) {
    a = find(a);
    b = find(b);
    if (a != b) p[static_cast<std::size_t>(std::max(a, b))] = std::min(a, b);
  }
};

using CellKey = std::array<long long, 3>;
struct CellHash {
  std::size_t operator()(const CellKey& k) const {
    return static_cast<std::size_t>(k[0] * 73856093LL ^ k[1] * 19349663LL ^ k[2] * 83492791LL);
  }
};
CellKey cell_of(const Vec3& p, double c) {
  return {static_cast<long long>(std::floor(p.x / c)), static_cast<long long>(std::floor(p.y / c)),
          static_cast<long long>(std::floor(p.z / c))};
}

int thread_count(int threads, int work) {
  const int hw = static_cast<int>(std::max(1u, std::thread::hardware_concurrency()));
  return std::max(1, std::min(work, threads > 0 ? threads : hw));
}

// A round section of diameter d.
struct Section { double A, I, J; };
Section section(double d) {
  const double r = 0.5 * d;
  const double A = M_PI * r * r, I = M_PI * r * r * r * r / 4.0;
  return {A, I, 2.0 * I};
}

// The local triad (rows ex, ey, ez), as frame.py's frames().
std::array<Vec3, 3> triad(const Vec3& a, const Vec3& b, double& L) {
  const Vec3 v = sub3(b, a);
  L = len3(v);
  const Vec3 ex{v.x / L, v.y / L, v.z / L};
  const Vec3 ref = std::fabs(ex.z) < 0.9 ? Vec3{0.0, 0.0, 1.0} : Vec3{1.0, 0.0, 0.0};
  Vec3 ey = cross3(ref, ex);
  const double n = len3(ey);
  ey = {ey.x / n, ey.y / n, ey.z / n};
  return {ex, ey, cross3(ex, ey)};
}

// The second largest singular value of a centred point set (the spread off its best line).
double second_spread(const std::vector<Vec3>& pts) {
  Vec3 m{0, 0, 0};
  for (const Vec3& p : pts) m = {m.x + p.x, m.y + p.y, m.z + p.z};
  const double n = static_cast<double>(pts.size());
  m = {m.x / n, m.y / n, m.z / n};
  double c[3][3] = {};
  for (const Vec3& p : pts) {
    const double d[3] = {p.x - m.x, p.y - m.y, p.z - m.z};
    for (int i = 0; i < 3; ++i)
      for (int j = 0; j < 3; ++j) c[i][j] += d[i] * d[j];
  }
  // eigenvalues of the symmetric 3x3 (Jacobi sweeps)
  double a[3][3];
  for (int i = 0; i < 3; ++i)
    for (int j = 0; j < 3; ++j) a[i][j] = c[i][j];
  for (int sweep = 0; sweep < 50; ++sweep) {
    const double off = a[0][1] * a[0][1] + a[0][2] * a[0][2] + a[1][2] * a[1][2];
    if (off < 1e-300) break;
    for (int p = 0; p < 2; ++p)
      for (int q = p + 1; q < 3; ++q) {
        if (std::fabs(a[p][q]) < 1e-300) continue;
        const double th = 0.5 * (a[q][q] - a[p][p]) / a[p][q];
        const double t = (th >= 0 ? 1.0 : -1.0) / (std::fabs(th) + std::sqrt(th * th + 1.0));
        const double cs = 1.0 / std::sqrt(t * t + 1.0), sn = t * cs;
        for (int k = 0; k < 3; ++k) {
          const double akp = a[k][p], akq = a[k][q];
          a[k][p] = cs * akp - sn * akq;
          a[k][q] = sn * akp + cs * akq;
        }
        for (int k = 0; k < 3; ++k) {
          const double apk = a[p][k], aqk = a[q][k];
          a[p][k] = cs * apk - sn * aqk;
          a[q][k] = sn * apk + cs * aqk;
        }
      }
  }
  std::array<double, 3> ev{a[0][0], a[1][1], a[2][2]};
  std::sort(ev.begin(), ev.end());
  return std::sqrt(std::max(0.0, ev[1]));
}

}  // namespace

// ── 1. THE FRAME (prototype steps 1 to 3, 6) ───────────────────────────────────────────────────────────────────────
FrameModel build_frame(const Bars& bars, const Domain* domain, const FrameSettings& s) {
  FrameModel f;
  const std::size_t nb = bars.bars.size();
  f.bars = nb;
  if (nb == 0) return f;
  // Ends within node_weld_mm are one node (a hash grid of that cell, its 27 neighbours; welding is transitive).
  const std::size_t ne = 2 * nb;
  auto end_at = [&](std::size_t e) -> const Vec3& { return e < nb ? bars.bars[e].a : bars.bars[e - nb].b; };
  UnionFind uf(ne);
  {
    const double c = std::max(s.node_weld_mm, 1e-12);
    std::unordered_map<CellKey, std::vector<int>, CellHash> grid;
    grid.reserve(ne);
    for (std::size_t e = 0; e < ne; ++e) grid[cell_of(end_at(e), c)].push_back(static_cast<int>(e));
    const double w2 = s.node_weld_mm * s.node_weld_mm;
    for (std::size_t e = 0; e < ne; ++e) {
      const CellKey k = cell_of(end_at(e), c);
      for (long long dx = -1; dx <= 1; ++dx)
        for (long long dy = -1; dy <= 1; ++dy)
          for (long long dz = -1; dz <= 1; ++dz) {
            const auto it = grid.find({k[0] + dx, k[1] + dy, k[2] + dz});
            if (it == grid.end()) continue;
            for (int o : it->second) {
              if (static_cast<std::size_t>(o) <= e) continue;
              const Vec3 d = sub3(end_at(e), end_at(static_cast<std::size_t>(o)));
              if (dot3(d, d) <= w2) uf.unite(static_cast<int>(e), o);
            }
          }
    }
  }
  std::vector<int> node_of(ne, -1), node_of_root(ne, -1);
  for (std::size_t e = 0; e < ne; ++e) {
    const int r = uf.find(static_cast<int>(e));
    if (node_of_root[static_cast<std::size_t>(r)] < 0) {
      node_of_root[static_cast<std::size_t>(r)] = static_cast<int>(f.nodes.size());
      f.nodes.push_back(end_at(static_cast<std::size_t>(r)));   // the lowest-numbered end of its class
    }
    node_of[e] = node_of_root[static_cast<std::size_t>(r)];
  }
  const std::size_t nn = f.nodes.size();
  // Solid nodes: an end of kind Solid, or an end where the domain says solid (prototype: why >= NotAsked).
  f.solid.assign(nn, 0);
  {
    std::unique_ptr<Domain::Probe> probe;
    if (domain) probe = std::make_unique<Domain::Probe>(domain->probe());
    for (std::size_t e = 0; e < ne; ++e) {
      const Bar& b = bars.bars[e < nb ? e : e - nb];
      const Bar::End kind = e < nb ? b.end_a : b.end_b;
      char& sol = f.solid[static_cast<std::size_t>(node_of[e])];
      if (sol) continue;
      if (kind == Bar::End::Solid) {
        sol = 1;
        continue;
      }
      if (!probe) continue;
      const Why w = probe->where(end_at(e)).why;
      if (w != Why::Lattice && w != Why::Outside) sol = 1;
    }
  }
  // T-joins: a node with one bar that lies on another bar (inside it, within tjoin_off_line_mm of its line) splits it.
  std::vector<int> degree(nn, 0);
  for (std::size_t i = 0; i < nb; ++i) {
    ++degree[static_cast<std::size_t>(node_of[i])];
    ++degree[static_cast<std::size_t>(node_of[nb + i])];
  }
  std::vector<std::vector<std::pair<double, int>>> splits(nb);
  {
    const double c = 2.0;   // the bar hash's cell, mm (a search structure only: it changes no answer)
    std::unordered_map<CellKey, std::vector<int>, CellHash> grid;
    for (std::size_t i = 0; i < nb; ++i) {
      const Bar& b = bars.bars[i];
      const double r = s.tjoin_reach_mm;
      const CellKey lo = cell_of({std::min(b.a.x, b.b.x) - r, std::min(b.a.y, b.b.y) - r, std::min(b.a.z, b.b.z) - r}, c);
      const CellKey hi = cell_of({std::max(b.a.x, b.b.x) + r, std::max(b.a.y, b.b.y) + r, std::max(b.a.z, b.b.z) + r}, c);
      for (long long x = lo[0]; x <= hi[0]; ++x)
        for (long long y = lo[1]; y <= hi[1]; ++y)
          for (long long z = lo[2]; z <= hi[2]; ++z) grid[{x, y, z}].push_back(static_cast<int>(i));
    }
    for (std::size_t n = 0; n < nn; ++n) {
      if (degree[n] != 1) continue;
      const Vec3& X = f.nodes[n];
      const auto it = grid.find(cell_of(X, c));
      if (it == grid.end()) continue;
      for (int bi : it->second) {
        const std::size_t i = static_cast<std::size_t>(bi);
        if (node_of[i] == static_cast<int>(n) || node_of[nb + i] == static_cast<int>(n)) continue;
        const Bar& b = bars.bars[i];
        const Vec3 v = sub3(b.b, b.a);
        const double vv = dot3(v, v);
        if (!(vv > 0.0)) continue;
        const double t = dot3(sub3(X, b.a), v) / vv;
        if (!(t > 1e-6 && t < 1.0 - 1e-6)) continue;
        const Vec3 q{b.a.x + t * v.x - X.x, b.a.y + t * v.y - X.y, b.a.z + t * v.z - X.z};
        if (len3(q) >= s.tjoin_off_line_mm) continue;
        bool seen = false;
        for (const auto& [tt, m] : splits[i]) seen = seen || m == static_cast<int>(n);
        if (!seen) {
          splits[i].push_back({t, static_cast<int>(n)});
          ++f.t_joins;
        }
      }
    }
  }
  // Pieces: whole bars, then the split ones; a piece of no length is left out.
  auto add = [&](int a, int b, std::size_t bar) {
    if (len3(sub3(f.nodes[static_cast<std::size_t>(b)], f.nodes[static_cast<std::size_t>(a)])) < s.zero_piece_mm) {
      ++f.zero_pieces;
      return;
    }
    FramePiece p;
    p.a = a;
    p.b = b;
    p.bar = static_cast<int>(bar);
    p.width = bars.bars[bar].width;
    p.link = bars.bars[bar].link;
    f.links += p.link;
    f.pieces.push_back(p);
  };
  for (std::size_t i = 0; i < nb; ++i)
    if (splits[i].empty()) add(node_of[i], node_of[nb + i], i);
  for (std::size_t i = 0; i < nb; ++i) {
    if (splits[i].empty()) continue;
    std::sort(splits[i].begin(), splits[i].end());
    int prev = node_of[i];
    for (const auto& [t, n] : splits[i]) {
      add(prev, n, i);
      prev = n;
    }
    add(prev, node_of[nb + i], i);
  }
  return f;
}

// ── 2. THE MATERIAL PER VOXEL (prototype R1, the lead's item 3) ────────────────────────────────────────────────────
FrameMaterial frame_material(const Bars& bars, const Domain& domain, const VoxelGrid& grid, const FrameSettings& s,
                             int threads) {
  const auto t0 = std::chrono::steady_clock::now();
  FrameMaterial m;
  const std::size_t n = grid.voxel_count();
  m.solid.assign(n, 0.0f);
  m.lattice.assign(n, 0.0f);
  const int k = std::clamp(s.material_subdiv, 1, 4);   // k^3 <= 64 sub-points: one 64-bit mask per voxel
  const int k3 = k * k * k;
  const double h = grid.spacing;
  std::vector<std::uint64_t> solid_mask(n, 0);
  std::vector<char> in_part(n, 0);
  const int nt = thread_count(threads, grid.nz);
  auto slab = [&](int k0, int k1) {
    const Domain::Probe probe = domain.probe();
    for (int kk = k0; kk < k1; ++kk)
      for (int jj = 0; jj < grid.ny; ++jj)
        for (int ii = 0; ii < grid.nx; ++ii) {
          if (!grid.solid(ii, jj, kk)) continue;
          const std::size_t e = grid.index(ii, jj, kk);
          in_part[e] = 1;
          const Vec3 lo{grid.origin.x + ii * h, grid.origin.y + jj * h, grid.origin.z + kk * h};
          std::uint64_t mask = 0;
          for (int a = 0; a < k; ++a)
            for (int b = 0; b < k; ++b)
              for (int c = 0; c < k; ++c) {
                const Vec3 p{lo.x + (a + 0.5) * h / k, lo.y + (b + 0.5) * h / k, lo.z + (c + 0.5) * h / k};
                const Why w = probe.where(p).why;
                if (w != Why::Lattice && w != Why::Outside) mask |= std::uint64_t{1} << ((a * k + b) * k + c);
              }
          solid_mask[e] = mask;
        }
  };
  {
    std::vector<std::thread> pool;
    for (int t = 0; t < nt; ++t) pool.emplace_back(slab, grid.nz * t / nt, grid.nz * (t + 1) / nt);
    for (std::thread& t : pool) t.join();
  }
  std::vector<OrganicSpan> spans;
  spans.reserve(bars.bars.size());
  for (const Bar& b : bars.bars) spans.push_back({b.a, b.b, 0.5 * b.width});
  std::vector<double> in_solid;
  const std::vector<double> open = lattice_union_voxel_volume(
      spans, grid, k,
      [&](std::size_t e, int sp) { return !in_part[e] || ((solid_mask[e] >> sp) & 1u) != 0; }, &in_solid);
  const double v = h * h * h;
  for (std::size_t e = 0; e < n; ++e) {
    if (!in_part[e]) continue;
    m.solid[e] = static_cast<float>(static_cast<double>(__builtin_popcountll(solid_mask[e])) / k3);
    m.lattice[e] = static_cast<float>(open[e] / v);
    m.solid_mm3 += m.solid[e] * v;
    m.lattice_open_mm3 += open[e];
    m.lattice_mm3 += open[e] + in_solid[e];
  }
  m.ms = ms_since(t0);
  return m;
}

// ── 3 TO 6. THE CHECK ──────────────────────────────────────────────────────────────────────────────────────────────
FrameCheck check_frame(const FrameModel& f, const FrameVoxelSolve& vs, const FrameStrength& st, const FrameSettings& s) {
  FrameCheck out;
  const double inf = std::numeric_limits<double>::infinity();
  out.smallest_margin = inf;
  out.bar_margin.assign(f.bars, std::numeric_limits<float>::quiet_NaN());
  const VoxelGrid& g = *vs.grid;
  const std::vector<double>& U = *vs.displacement;
  const FrameMaterial& mat = *vs.material;
  const std::size_t nn = f.nodes.size(), np = f.pieces.size();
  const double h = g.spacing;
  const int NX = g.nx + 1, NY = g.ny + 1;
  auto node_index = [&](int a, int b, int c) { return (static_cast<std::size_t>(c) * NY + b) * NX + a; };
  const double E = st.youngs_mpa, G = E / (2.0 * (1.0 + st.poisson));
  const double ks = 6.0 * (1.0 + st.poisson) / (7.0 + 6.0 * st.poisson);   // a solid round section's shear coefficient
  Vec3 up = st.up;
  {
    const double l = len3(up);
    up = l > 0.0 ? Vec3{up.x / l, up.y / l, up.z / l} : Vec3{0.0, 0.0, 1.0};
  }
  auto t0 = std::chrono::steady_clock::now();

  // Nodes in use, driven nodes, pieces of the frame (connected components).
  std::vector<char> used(nn, 0);
  UnionFind uf(nn);
  for (const FramePiece& p : f.pieces) {
    used[static_cast<std::size_t>(p.a)] = used[static_cast<std::size_t>(p.b)] = 1;
    uf.unite(p.a, p.b);
  }
  std::vector<char> driven(nn, 0);
  std::vector<int> comp(nn, -1), comp_driven(nn, 0);
  for (std::size_t i = 0; i < nn; ++i) {
    if (!used[i]) continue;
    ++out.nodes_used;
    comp[i] = uf.find(static_cast<int>(i));
    if (f.solid[i]) {
      driven[i] = 1;
      ++out.driven;
      ++comp_driven[static_cast<std::size_t>(comp[i])];
    }
  }
  std::vector<char> comp_real(nn, 0), comp_in(nn, 0), fixrot(nn, 0);
  for (std::size_t i = 0; i < nn; ++i)
    if (used[i]) comp_real[static_cast<std::size_t>(comp[i])] = 1;
  {
    std::unordered_map<int, std::vector<Vec3>> pts;
    for (std::size_t c = 0; c < nn; ++c) {
      if (!comp_real[c]) continue;
      ++out.pieces_of_frame;
      const int d = comp_driven[c];
      if (d == 0) {
        ++out.undriven_pieces;
        continue;
      }
      comp_in[c] = 1;
      if (d == 1) fixrot[c] = 1;
      else if (d < s.collinear_max_driven) pts[static_cast<int>(c)];
    }
    if (!pts.empty()) {
      for (std::size_t i = 0; i < nn; ++i)
        if (used[i]) {
          const auto it = pts.find(comp[i]);
          if (it != pts.end()) it->second.push_back(f.nodes[i]);
        }
      for (const auto& [c, P] : pts)
        if (second_spread(P) < s.collinear_tol_mm) fixrot[static_cast<std::size_t>(c)] = 1;
    }
    for (std::size_t c = 0; c < nn; ++c) out.rotations_held += fixrot[c];
  }

  // ── 4. The drive: each driven node, the mean displacement of the material voxels whose centres lie within the ball.
  std::vector<std::array<double, 3>> ud(nn, {0.0, 0.0, 0.0});
  {
    auto corner_u = [&](int a, int b, int c, int comp_) { return U[3 * node_index(a, b, c) + static_cast<std::size_t>(comp_)]; };
    auto voxel_u = [&](int i, int j, int k, std::array<double, 3>& u) {
      u = {0.0, 0.0, 0.0};
      for (int dc = 0; dc < 2; ++dc)
        for (int db = 0; db < 2; ++db)
          for (int da = 0; da < 2; ++da)
            for (int q = 0; q < 3; ++q) u[static_cast<std::size_t>(q)] += 0.125 * corner_u(i + da, j + db, k + dc, q);
    };
    const double R = s.drive_ball_voxels * h;
    const int reach = static_cast<int>(std::ceil(R / h)) + 1;
    std::vector<double> counts;
    for (std::size_t n = 0; n < nn; ++n) {
      if (!driven[n] || !comp_in[static_cast<std::size_t>(comp[n])]) continue;
      const Vec3& X = f.nodes[n];
      const int bi = static_cast<int>(std::floor((X.x - g.origin.x) / h)), bj = static_cast<int>(std::floor((X.y - g.origin.y) / h)),
                bk = static_cast<int>(std::floor((X.z - g.origin.z) / h));
      std::array<double, 3> acc{0.0, 0.0, 0.0}, u{};
      int cnt = 0;
      for (int dk = -reach; dk <= reach; ++dk)
        for (int dj = -reach; dj <= reach; ++dj)
          for (int di = -reach; di <= reach; ++di) {
            const int i = bi + di, j = bj + dj, k = bk + dk;
            if (i < 0 || j < 0 || k < 0 || i >= g.nx || j >= g.ny || k >= g.nz) continue;
            const Vec3 ctr{g.origin.x + (i + 0.5) * h, g.origin.y + (j + 0.5) * h, g.origin.z + (k + 0.5) * h};
            if (len3(sub3(ctr, X)) > R) continue;
            const std::size_t e = g.index(i, j, k);
            if (!(mat.solid[e] + mat.lattice[e] > s.drive_share)) continue;
            voxel_u(i, j, k, u);
            for (int q = 0; q < 3; ++q) acc[static_cast<std::size_t>(q)] += u[static_cast<std::size_t>(q)];
            ++cnt;
          }
      counts.push_back(cnt);
      if (cnt > 0) {
        for (int q = 0; q < 3; ++q) ud[n][static_cast<std::size_t>(q)] = acc[static_cast<std::size_t>(q)] / cnt;
      } else {   // no material voxel in the ball: the displacement at the point, trilinear between the grid's corners
        ++out.drive_fallback;
        const double fx = (X.x - g.origin.x) / h, fy = (X.y - g.origin.y) / h, fz = (X.z - g.origin.z) / h;
        const int i0 = std::clamp(static_cast<int>(std::floor(fx)), 0, g.nx - 1), j0 = std::clamp(static_cast<int>(std::floor(fy)), 0, g.ny - 1),
                  k0 = std::clamp(static_cast<int>(std::floor(fz)), 0, g.nz - 1);
        const double tx = fx - i0, ty = fy - j0, tz = fz - k0;
        for (int dc = 0; dc < 2; ++dc)
          for (int db = 0; db < 2; ++db)
            for (int da = 0; da < 2; ++da) {
              const double w = (da ? tx : 1 - tx) * (db ? ty : 1 - ty) * (dc ? tz : 1 - tz);
              for (int q = 0; q < 3; ++q) ud[n][static_cast<std::size_t>(q)] += w * corner_u(i0 + da, j0 + db, k0 + dc, q);
            }
      }
    }
    if (!counts.empty()) {
      std::nth_element(counts.begin(), counts.begin() + static_cast<long>(counts.size() / 2), counts.end());
      out.drive_voxels_median = counts[counts.size() / 2];
    }
  }

  // ── 5. The load on the frame: per loaded grid node, the lattice's share of its force, on the frame nodes near it.
  std::vector<std::array<double, 3>> F(nn, {0.0, 0.0, 0.0});
  {
    std::unordered_map<int, std::array<double, 3>> force;
    for (const FrameVoxelSolve::Load& l : vs.loads) force[l.node][static_cast<std::size_t>(l.component)] += l.value;
    const double R = std::max(st.light_width_mm, h);
    std::unordered_map<CellKey, std::vector<int>, CellHash> near;
    for (std::size_t n = 0; n < nn; ++n)
      if (used[n] && !driven[n] && comp_in[static_cast<std::size_t>(comp[n])])
        near[cell_of(f.nodes[n], R)].push_back(static_cast<int>(n));
    std::vector<char> loaded(nn, 0);
    std::vector<int> found;
    for (const auto& [node, fv] : force) {
      const double mag = std::sqrt(fv[0] * fv[0] + fv[1] * fv[1] + fv[2] * fv[2]);
      out.load_total_n += mag;
      if (!(mag > 0.0)) continue;
      const int a = node % NX, b = (node / NX) % NY, c = node / (NX * NY);
      double lat = 0.0, all = 0.0;
      for (int dk = -1; dk <= 0; ++dk)
        for (int dj = -1; dj <= 0; ++dj)
          for (int di = -1; di <= 0; ++di) {
            const int i = a + di, j = b + dj, k = c + dk;
            if (i < 0 || j < 0 || k < 0 || i >= g.nx || j >= g.ny || k >= g.nz) continue;
            const std::size_t e = g.index(i, j, k);
            lat += mat.lattice[e];
            all += mat.solid[e] + mat.lattice[e];
          }
      const double share = all > 0.0 ? lat / all : 0.0;
      if (!(share * mag > 0.0)) continue;
      const Vec3 P{g.origin.x + a * h, g.origin.y + b * h, g.origin.z + c * h};
      found.clear();
      const CellKey ck = cell_of(P, R);
      for (long long dx = -1; dx <= 1; ++dx)
        for (long long dy = -1; dy <= 1; ++dy)
          for (long long dz = -1; dz <= 1; ++dz) {
            const auto it = near.find({ck[0] + dx, ck[1] + dy, ck[2] + dz});
            if (it == near.end()) continue;
            for (int n : it->second)
              if (len3(sub3(f.nodes[static_cast<std::size_t>(n)], P)) <= R) found.push_back(n);
          }
      if (found.empty()) {
        out.load_unheld_n += share * mag;
        continue;
      }
      const double each = share / static_cast<double>(found.size());
      for (int n : found) {
        for (int q = 0; q < 3; ++q) F[static_cast<std::size_t>(n)][static_cast<std::size_t>(q)] += each * fv[static_cast<std::size_t>(q)];
        loaded[static_cast<std::size_t>(n)] = 1;
      }
      out.load_on_frame_n += share * mag;
    }
    for (char x : loaded) out.frame_nodes_loaded += x;
    out.load_on_open_lattice = out.load_unheld_n > s.load_unheld_share * out.load_total_n;
  }
  out.ms_drive = ms_since(t0);

  // ── 6. Assembly: the free freedoms of the nodes of driven pieces; driven translations and held rotations fixed.
  t0 = std::chrono::steady_clock::now();
  std::vector<int> dof(6 * nn, -2);   // -2: not in the solve; -1: fixed; >= 0: free
  std::vector<double> ufix(6 * nn, 0.0);
  int nf = 0;
  for (std::size_t n = 0; n < nn; ++n) {
    if (!used[n] || !comp_in[static_cast<std::size_t>(comp[n])]) continue;
    for (int q = 0; q < 6; ++q) {
      const bool fixed = (driven[n] && q < 3) || (driven[n] && q >= 3 && fixrot[static_cast<std::size_t>(comp[n])]);
      dof[6 * n + static_cast<std::size_t>(q)] = fixed ? -1 : nf++;
      if (fixed && q < 3) ufix[6 * n + static_cast<std::size_t>(q)] = ud[n][static_cast<std::size_t>(q)];
    }
  }
  out.dofs = static_cast<std::size_t>(nf);
  SymmetricLower K;
  K.n = nf;
  std::vector<double> rhs(static_cast<std::size_t>(nf), 0.0);
  for (std::size_t n = 0; n < nn; ++n)
    for (int q = 0; q < 3; ++q) {
      const int d = dof[6 * n + static_cast<std::size_t>(q)];
      if (d >= 0) rhs[static_cast<std::size_t>(d)] += F[n][static_cast<std::size_t>(q)];
    }
  struct PieceFrame { std::array<Vec3, 3> R; double L; };
  std::vector<PieceFrame> pf(np);
  std::vector<char> in_solve(np, 0);
  K.row.reserve(np * 78);
  K.col.reserve(np * 78);
  K.val.reserve(np * 78);
  for (std::size_t pi = 0; pi < np; ++pi) {
    const FramePiece& p = f.pieces[pi];
    if (!comp_in[static_cast<std::size_t>(comp[static_cast<std::size_t>(p.a)])]) continue;
    in_solve[pi] = 1;
    pf[pi].R = triad(f.nodes[static_cast<std::size_t>(p.a)], f.nodes[static_cast<std::size_t>(p.b)], pf[pi].L);
    const Section sc = section(p.width);
    const FrameStiffness kl = frame2_stiffness(E, G, sc.A, sc.I, sc.I, sc.J, pf[pi].L, ks);
    const double mult = p.link ? s.link_stiffness : 1.0;
    // kg = T^T kl T, T = blockdiag(R, R, R, R)
    double KT[12][12], Kg[12][12];
    const auto& R = pf[pi].R;
    const double Rm[3][3] = {{R[0].x, R[0].y, R[0].z}, {R[1].x, R[1].y, R[1].z}, {R[2].x, R[2].y, R[2].z}};
    for (int r = 0; r < 12; ++r)
      for (int bc = 0; bc < 4; ++bc)
        for (int j = 0; j < 3; ++j) {
          double acc = 0.0;
          for (int q = 0; q < 3; ++q) acc += kl(r, 3 * bc + q) * Rm[q][j];
          KT[r][3 * bc + j] = acc;
        }
    for (int br = 0; br < 4; ++br)
      for (int i = 0; i < 3; ++i)
        for (int c = 0; c < 12; ++c) {
          double acc = 0.0;
          for (int q = 0; q < 3; ++q) acc += Rm[q][i] * KT[3 * br + q][c];
          Kg[3 * br + i][c] = acc * mult;
        }
    int d[12];
    double u0[12];
    for (int q = 0; q < 6; ++q) {
      d[q] = dof[6 * static_cast<std::size_t>(p.a) + static_cast<std::size_t>(q)];
      d[6 + q] = dof[6 * static_cast<std::size_t>(p.b) + static_cast<std::size_t>(q)];
      u0[q] = ufix[6 * static_cast<std::size_t>(p.a) + static_cast<std::size_t>(q)];
      u0[6 + q] = ufix[6 * static_cast<std::size_t>(p.b) + static_cast<std::size_t>(q)];
    }
    for (int r = 0; r < 12; ++r) {
      if (d[r] < 0) continue;
      double minus = 0.0;
      for (int c = 0; c < 12; ++c) {
        if (d[c] == -1) minus += Kg[r][c] * u0[c];
        else if (d[c] >= 0 && d[r] >= d[c] && Kg[r][c] != 0.0) {
          K.row.push_back(d[r]);
          K.col.push_back(d[c]);
          K.val.push_back(Kg[r][c]);
        }
      }
      rhs[static_cast<std::size_t>(d[r])] -= minus;
    }
  }
  out.ms_assemble = ms_since(t0);

  // The solve.
  t0 = std::chrono::steady_clock::now();
  std::vector<double> u(6 * nn, 0.0);
  for (std::size_t i = 0; i < 6 * nn; ++i)
    if (dof[i] == -1) u[i] = ufix[i];
  if (nf > 0) {
    SparseLdltOptions o;
    o.memory_limit_gb = s.solve_memory_gb;
    SparseLdltResult r = sparse_ldlt_solve(K, rhs, o);
    out.factor_gb = r.factor_gb;
    out.residual = r.residual;
    out.solver = r.backend + " " + r.method;
    { SymmetricLower none; K = std::move(none); }
    if (!r.ok) {
      out.why_not = r.too_large ? "the frame's factor would be larger than the memory allowed for it"
                    : !r.available ? "this build has no sparse direct solver"
                    : r.numeric_ok ? "the frame's solve was not accurate enough to be believed"
                                   : "the frame could not be factorised (a piece of it is not held)";
      out.ms_solve = ms_since(t0);
      return out;
    }
    for (std::size_t i = 0; i < 6 * nn; ++i)
      if (dof[i] >= 0) u[i] = r.x[static_cast<std::size_t>(dof[i])];
  }
  out.solved = true;
  out.ms_solve = ms_since(t0);
  out.node_u.assign(nn, Vec3{0.0, 0.0, 0.0});
  for (std::size_t n = 0; n < nn; ++n) out.node_u[n] = {u[6 * n], u[6 * n + 1], u[6 * n + 2]};

  // ── The verdict (steps 9, 10): per piece, then per strut.
  t0 = std::chrono::steady_clock::now();
  std::vector<double> pm_stress(np, inf), pN(np, 0.0), pT(np, inf), pC(np, inf), plen(np, 0.0);
  for (std::size_t pi = 0; pi < np; ++pi) {
    const FramePiece& p = f.pieces[pi];
    plen[pi] = len3(sub3(f.nodes[static_cast<std::size_t>(p.b)], f.nodes[static_cast<std::size_t>(p.a)]));
    if (!in_solve[pi]) continue;
    const Section sc = section(p.width);
    const FrameStiffness kl = frame2_stiffness(E, G, sc.A, sc.I, sc.I, sc.J, pf[pi].L, ks);
    const auto& R = pf[pi].R;
    double ul[12];
    for (int blk = 0; blk < 4; ++blk) {
      const std::size_t n = static_cast<std::size_t>(blk < 2 ? p.a : p.b);
      const Vec3 v{u[6 * n + static_cast<std::size_t>(3 * (blk % 2))], u[6 * n + static_cast<std::size_t>(3 * (blk % 2) + 1)],
                   u[6 * n + static_cast<std::size_t>(3 * (blk % 2) + 2)]};
      for (int q = 0; q < 3; ++q) ul[3 * blk + q] = dot3(R[static_cast<std::size_t>(q)], v);
    }
    double fl[12];
    for (int r = 0; r < 12; ++r) {
      double acc = 0.0;
      for (int c = 0; c < 12; ++c) acc += kl(r, c) * ul[c];
      fl[r] = acc;
    }
    const double N = fl[6];   // tension +
    const double M = std::max(std::hypot(fl[4], fl[5]), std::hypot(fl[10], fl[11]));
    const double r = 0.5 * p.width;
    const double sb = M * r / sc.I, s_t = N / sc.A + sb, s_c = -N / sc.A + sb;
    const double rise = std::min(1.0, std::fabs(dot3(sub3(f.nodes[static_cast<std::size_t>(p.b)], f.nodes[static_cast<std::size_t>(p.a)]), up)) / pf[pi].L);
    const double lim_t = st.level_mpa * (1.0 - rise * rise) + st.across_mpa * rise * rise;
    pT[pi] = s_t > 0.0 ? lim_t / s_t : inf;
    pC[pi] = s_c > 0.0 ? st.level_mpa / s_c : inf;
    pm_stress[pi] = std::min(pT[pi], pC[pi]);
    pN[pi] = N;
  }
  // Struts: non-link pieces joined through nodes that are not joints (a joint: three or more non-link pieces, driven,
  // or an end of one piece only).
  std::vector<int> nldeg(nn, 0);
  for (const FramePiece& p : f.pieces)
    if (!p.link) {
      ++nldeg[static_cast<std::size_t>(p.a)];
      ++nldeg[static_cast<std::size_t>(p.b)];
    }
  UnionFind su(np);
  {
    std::vector<int> first(nn, -1);
    for (std::size_t pi = 0; pi < np; ++pi) {
      const FramePiece& p = f.pieces[pi];
      if (p.link) continue;
      for (const int n : {p.a, p.b}) {
        const std::size_t nu = static_cast<std::size_t>(n);
        if (nldeg[nu] != 2 || driven[nu]) continue;
        if (first[nu] < 0) first[nu] = static_cast<int>(pi);
        else su.unite(first[nu], static_cast<int>(pi));
      }
    }
  }
  std::vector<int> strut_of(np, -1);
  {
    std::unordered_map<int, int> id;
    for (std::size_t pi = 0; pi < np; ++pi) {
      if (f.pieces[pi].link) continue;
      const int root = su.find(static_cast<int>(pi));
      auto it = id.find(root);
      if (it == id.end()) {
        it = id.emplace(root, static_cast<int>(out.struts.size())).first;
        out.struts.emplace_back();
        FrameStrut& sn = out.struts.back();
        sn.stress_margin = inf;
        sn.buckling_margin = inf;
        sn.width_min = inf;
      }
      strut_of[pi] = it->second;
      out.struts[static_cast<std::size_t>(it->second)].pieces.push_back(static_cast<int>(pi));
    }
  }
  double strut_len_all = 0.0;
  for (FrameStrut& sn : out.struts) {
    bool out_of_solve = false;
    double Nmin = 0.0, worst = -1.0;
    int worst_piece = sn.pieces.front();
    const char* worst_by = "tension";
    for (int pi : sn.pieces) {
      const FramePiece& p = f.pieces[static_cast<std::size_t>(pi)];
      sn.length_mm += plen[static_cast<std::size_t>(pi)];
      sn.width_min = std::min(sn.width_min, p.width);
      sn.width_max = std::max(sn.width_max, p.width);
      out_of_solve = out_of_solve || !in_solve[static_cast<std::size_t>(pi)];
      Nmin = std::min(Nmin, pN[static_cast<std::size_t>(pi)]);
      if (plen[static_cast<std::size_t>(pi)] >= s.min_piece * p.width && pm_stress[static_cast<std::size_t>(pi)] < sn.stress_margin) {
        sn.stress_margin = pm_stress[static_cast<std::size_t>(pi)];
        worst_by = pT[static_cast<std::size_t>(pi)] <= pC[static_cast<std::size_t>(pi)] ? "tension" : "compression";
      }
      const double demand = pm_stress[static_cast<std::size_t>(pi)] > 0.0 ? 1.0 / pm_stress[static_cast<std::size_t>(pi)] : inf;
      if (demand > worst) {
        worst = demand;
        worst_piece = pi;
      }
    }
    if (Nmin < 0.0) sn.buckling_margin = (M_PI * M_PI * E * section(sn.width_min).I / (sn.length_mm * sn.length_mm)) / -Nmin;
    sn.margin = std::min(sn.stress_margin, sn.buckling_margin);
    sn.by = sn.buckling_margin < sn.stress_margin ? "buckling" : worst_by;
    const FramePiece& wp = f.pieces[static_cast<std::size_t>(worst_piece)];
    const Vec3& A = f.nodes[static_cast<std::size_t>(wp.a)];
    const Vec3& B = f.nodes[static_cast<std::size_t>(wp.b)];
    sn.at = {0.5 * (A.x + B.x), 0.5 * (A.y + B.y), 0.5 * (A.z + B.z)};
    sn.stub = sn.length_mm < sn.width_max;
    sn.judged = !out_of_solve && !sn.stub;
    strut_len_all += sn.length_mm;
    if (out_of_solve) {
      out.unjudged_mm += sn.length_mm;
      continue;
    }
    if (sn.stub) {
      ++out.stubs;
      continue;
    }
    ++out.judged;
    out.under_safety += sn.margin < st.safety;
    out.under_one += sn.margin < 1.0;
    out.buckling_failures += sn.buckling_margin < st.safety;
    out.smallest_margin = std::min(out.smallest_margin, sn.margin);
  }
  out.strut_mm = strut_len_all;
  out.too_unjudged = out.unjudged_mm > s.unjudged_share * strut_len_all;
  for (std::size_t pi = 0; pi < np; ++pi) {
    const int si = strut_of[pi];
    if (si < 0 || !out.struts[static_cast<std::size_t>(si)].judged) continue;
    float& bm = out.bar_margin[static_cast<std::size_t>(f.pieces[pi].bar)];
    const float m = static_cast<float>(out.struts[static_cast<std::size_t>(si)].margin);
    if (std::isnan(bm) || m < bm) bm = m;
  }
  for (std::size_t i = 0; i < out.struts.size(); ++i)
    if (out.struts[i].judged) out.weakest.push_back(static_cast<int>(i));
  std::sort(out.weakest.begin(), out.weakest.end(), [&](int a, int b) {
    const double ma = out.struts[static_cast<std::size_t>(a)].margin, mb = out.struts[static_cast<std::size_t>(b)].margin;
    return ma != mb ? ma < mb : a < b;
  });
  if (out.weakest.size() > static_cast<std::size_t>(std::max(0, s.weakest))) out.weakest.resize(static_cast<std::size_t>(std::max(0, s.weakest)));
  out.ms_verdict = ms_since(t0);
  return out;
}

// ── ONE STRENGTHEN ROUND ───────────────────────────────────────────────────────────────────────────────────────────
StrengthenRound strengthen_round(const FrameModel& f, const FrameCheck& c, const Bars& bars, TensorField& field,
                                 const StrengthenSettings& s) {
  StrengthenRound out;
  const std::size_t nv = static_cast<std::size_t>(field.nx) * field.ny * field.nz;
  std::vector<float> boost(nv, 1.0f);
  const double h = field.spacing;
  for (const FrameStrut& st : c.struts) {
    if (!st.judged || !(st.margin < s.watch_margin)) continue;
    ++out.struts_watched;
    const double b = std::min(s.boost_max, std::pow(s.watch_margin / st.margin, s.boost_power));
    const double least = st.width_max * s.target_margin / st.margin;
    for (int pi : st.pieces) {
      const FramePiece& p = f.pieces[static_cast<std::size_t>(pi)];
      const double r = bars.bars[static_cast<std::size_t>(p.bar)].cell;
      if (!(r > 0.0)) continue;
      const Vec3& A = f.nodes[static_cast<std::size_t>(p.a)];
      const Vec3& B = f.nodes[static_cast<std::size_t>(p.b)];
      for (const Vec3& q : {A, B, Vec3{0.5 * (A.x + B.x), 0.5 * (A.y + B.y), 0.5 * (A.z + B.z)}}) {
        out.floors.push_back({q, r, least});
        if (!(h > 0.0) || nv == 0) continue;
        const int i0 = std::max(0, static_cast<int>(std::floor((q.x - r - field.origin.x) / h)));
        const int i1 = std::min(field.nx - 1, static_cast<int>(std::floor((q.x + r - field.origin.x) / h)));
        const int j0 = std::max(0, static_cast<int>(std::floor((q.y - r - field.origin.y) / h)));
        const int j1 = std::min(field.ny - 1, static_cast<int>(std::floor((q.y + r - field.origin.y) / h)));
        const int k0 = std::max(0, static_cast<int>(std::floor((q.z - r - field.origin.z) / h)));
        const int k1 = std::min(field.nz - 1, static_cast<int>(std::floor((q.z + r - field.origin.z) / h)));
        for (int k = k0; k <= k1; ++k)
          for (int j = j0; j <= j1; ++j)
            for (int i = i0; i <= i1; ++i) {
              const double dx = field.origin.x + (i + 0.5) * h - q.x, dy = field.origin.y + (j + 0.5) * h - q.y,
                           dz = field.origin.z + (k + 0.5) * h - q.z;
              if (dx * dx + dy * dy + dz * dz > r * r) continue;
              float& v = boost[field.index(i, j, k)];
              v = std::max(v, static_cast<float>(b));
            }
      }
    }
  }
  for (std::size_t e = 0; e < nv; ++e) {
    if (!(boost[e] > 1.0f)) continue;
    ++out.voxels_boosted;
    out.boost_largest = std::max(out.boost_largest, static_cast<double>(boost[e]));
    for (int q = 0; q < 6; ++q) field.voigt[6 * e + static_cast<std::size_t>(q)] *= static_cast<double>(boost[e]);
  }
  out.boosted_mm3 = static_cast<double>(out.voxels_boosted) * h * h * h;
  return out;
}

}  // namespace topopt::lattice_layout
