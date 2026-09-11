// See topopt/lattice_dc.hpp for why the lattice is contoured from its own SDF.
#include "topopt/lattice_dc.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <unordered_map>
#include <vector>

#include <chrono>

namespace topopt {
namespace {

inline Vec3 sub(const Vec3& a, const Vec3& b) { return Vec3{a.x - b.x, a.y - b.y, a.z - b.z}; }
inline Vec3 add(const Vec3& a, const Vec3& b) { return Vec3{a.x + b.x, a.y + b.y, a.z + b.z}; }
inline Vec3 mul(const Vec3& a, double s) { return Vec3{a.x * s, a.y * s, a.z * s}; }
inline double dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
inline double len(const Vec3& a) { return std::sqrt(dot(a, a)); }
inline double now_seconds() {
  return std::chrono::duration<double>(
             std::chrono::steady_clock::now().time_since_epoch()).count();
}

// ★ AN INJECTIVE CELL KEY, NOT A HASH. These maps are keyed by grid coordinate, and a
// multiply-XOR hash COLLIDES: two different cells land on one entry, so a lookup returns
// another cell's vertex or another cell's capsule list. With millions of cells that is
// not a rare event, and it showed up as dropped quads, holes and a volume near half the
// truth. Pack the coordinates instead -- 21 bits each, biased positive -- which is exact
// for |coord| < 2^20, i.e. a 203 mm part down to a 0.0002 mm cell.
inline long long cell_key(long long i, long long j, long long k) {
  constexpr long long kBias = 1LL << 20;
  return (((i + kBias) & 0x1FFFFF) << 42) | (((j + kBias) & 0x1FFFFF) << 21) |
         ((k + kBias) & 0x1FFFFF);
}

// The same, for a node of an octree: the level joins the coordinate. Octree coordinates
// are non-negative and below 2^level, so 20 bits each plus 4 for the level is injective
// for any tree this builds (kMaxDepth below is the guard).
constexpr int kMaxDepth = 15;
inline long long node_key(int level, long long i, long long j, long long k) {
  return (static_cast<long long>(level) << 60) | ((i & 0xFFFFF) << 40) |
         ((j & 0xFFFFF) << 20) | (k & 0xFFFFF);
}

struct Cap {
  Vec3 a{0, 0, 0}, ab{0, 0, 0};
  double r = 0.0, ab2 = 0.0;
};

// ── the field, and its exact gradient ────────────────────────────────────────
// A capsule's signed distance is |p - closest point on the segment| - r, so the union's
// is the min over capsules. The gradient is the unit vector away from that closest
// point, which is EXACT -- no finite differencing, and therefore no noise in the Hermite
// data the QEF is solved from.
//
// Outside the union this min IS the distance to the surface. Inside it is the depth of
// the deepest capsule covering the point, which is a LOWER bound on the true depth. Both
// facts matter for the octree: |d| > half the node's diagonal proves the node holds no
// surface either way round, so the descent below may prune on it.
struct Field {
  std::vector<Cap> caps;
  double cell = 0.0;            // spatial-hash cell, sized on the largest capsule
  double clip_z = -1e30;        // the base plane: everything below it is outside
  std::unordered_map<long long, std::vector<int>> grid;
  mutable std::size_t evals = 0;

  static long long key_of(long long i, long long j, long long k) { return cell_key(i, j, k); }
  // distance, and the index of the nearest capsule (-1 when nothing is near)
  double eval(const Vec3& p, int* which = nullptr) const {
    ++evals;
    double best = 1e30;
    int bi = -1;
    const long long ci = static_cast<long long>(std::floor(p.x / cell));
    const long long cj = static_cast<long long>(std::floor(p.y / cell));
    const long long ck = static_cast<long long>(std::floor(p.z / cell));
    for (long long i = ci - 1; i <= ci + 1; ++i)
      for (long long j = cj - 1; j <= cj + 1; ++j)
        for (long long k = ck - 1; k <= ck + 1; ++k) {
          auto it = grid.find(key_of(i, j, k));
          if (it == grid.end()) continue;
          for (int m : it->second) {
            const Cap& c = caps[static_cast<std::size_t>(m)];
            const Vec3 ap = sub(p, c.a);
            double t = c.ab2 > 0.0 ? dot(ap, c.ab) / c.ab2 : 0.0;
            t = t < 0.0 ? 0.0 : (t > 1.0 ? 1.0 : t);
            const double d = len(sub(ap, mul(c.ab, t))) - c.r;
            if (d < best) { best = d; bi = m; }
          }
        }
    if (which) *which = bi;
    if (bi < 0) return 1e30;          // nothing near: far outside, which is all we need
    const double below = clip_z - p.z;      // the half-space, intersected with the union
    return below > best ? below : best;
  }
  Vec3 gradient(const Vec3& p) const {
    int m = -1;
    const double here = eval(p, &m);
    if (m < 0) return Vec3{0, 0, 1};
    if (clip_z > -1e29 && here == clip_z - p.z) return Vec3{0, 0, -1};  // on the base plane
    const Cap& c = caps[static_cast<std::size_t>(m)];
    const Vec3 ap = sub(p, c.a);
    double t = c.ab2 > 0.0 ? dot(ap, c.ab) / c.ab2 : 0.0;
    t = t < 0.0 ? 0.0 : (t > 1.0 ? 1.0 : t);
    const Vec3 d = sub(ap, mul(c.ab, t));
    const double l = len(d);
    return l > 1e-12 ? mul(d, 1.0 / l) : Vec3{0, 0, 1};
  }
};

// ── the quadratic error function ─────────────────────────────────────────────
// Held as its accumulated normal equations rather than as a list of planes, because that
// is what makes SIMPLIFICATION exact: the QEF of a parent cell is the SUM of its
// children's, so a merged cell is fitted to every fine crossing plane beneath it, not to
// a re-sampled approximation of them. The leftover residual at the solved point is then
// the honest measure of what the merge costs, and it is the number the size dial is set
// against.
struct Qef {
  double ata[6] = {0, 0, 0, 0, 0, 0};   // xx xy xz yy yz zz
  double atb[3] = {0, 0, 0};
  double btb = 0.0;
  double mx = 0.0, my = 0.0, mz = 0.0;
  int n = 0;

  void add_plane(const Vec3& p, const Vec3& nn) {
    const double d = dot(nn, p);
    ata[0] += nn.x * nn.x; ata[1] += nn.x * nn.y; ata[2] += nn.x * nn.z;
    ata[3] += nn.y * nn.y; ata[4] += nn.y * nn.z; ata[5] += nn.z * nn.z;
    atb[0] += nn.x * d; atb[1] += nn.y * d; atb[2] += nn.z * d;
    btb += d * d;
    mx += p.x; my += p.y; mz += p.z; ++n;
  }
  void add(const Qef& o) {
    for (int t = 0; t < 6; ++t) ata[t] += o.ata[t];
    for (int t = 0; t < 3; ++t) atb[t] += o.atb[t];
    btb += o.btb; mx += o.mx; my += o.my; mz += o.mz; n += o.n;
  }
  Vec3 mass() const {
    return n > 0 ? Vec3{mx / n, my / n, mz / n} : Vec3{0, 0, 0};
  }
  // (A^T A + lambda I) x = A^T b + lambda * mass, by Cramer on the 3x3
  Vec3 solve(double lambda) const {
    const Vec3 m = mass();
    const double m00 = ata[0] + lambda, m01 = ata[1], m02 = ata[2],
                 m11 = ata[3] + lambda, m12 = ata[4], m22 = ata[5] + lambda;
    const double b0 = atb[0] + lambda * m.x, b1 = atb[1] + lambda * m.y,
                 b2 = atb[2] + lambda * m.z;
    const double det = m00 * (m11 * m22 - m12 * m12) - m01 * (m01 * m22 - m12 * m02) +
                       m02 * (m01 * m12 - m11 * m02);
    if (std::fabs(det) < 1e-16) return m;
    const double ix = (b0 * (m11 * m22 - m12 * m12) - m01 * (b1 * m22 - m12 * b2) +
                       m02 * (b1 * m12 - m11 * b2)) / det;
    const double iy = (m00 * (b1 * m22 - m12 * b2) - b0 * (m01 * m22 - m12 * m02) +
                       m02 * (m01 * b2 - b1 * m02)) / det;
    const double iz = (m00 * (m11 * b2 - b1 * m12) - m01 * (m01 * b2 - b1 * m02) +
                       b0 * (m01 * m12 - m11 * m02)) / det;
    return Vec3{ix, iy, iz};
  }
  // the residual of the UNREGULARISED fit, which is what the merge actually costs
  double residual(const Vec3& x) const {
    const double ax = ata[0] * x.x + ata[1] * x.y + ata[2] * x.z;
    const double ay = ata[1] * x.x + ata[3] * x.y + ata[4] * x.z;
    const double az = ata[2] * x.x + ata[4] * x.y + ata[5] * x.z;
    const double r = x.x * ax + x.y * ay + x.z * az -
                     2.0 * (x.x * atb[0] + x.y * atb[1] + x.z * atb[2]) + btb;
    return r > 0.0 ? r : 0.0;
  }
  double rms(const Vec3& x) const {
    return n > 0 ? std::sqrt(residual(x) / static_cast<double>(n)) : 0.0;
  }
};

// the 12 edges of a cell, as pairs of corner indices (corner bit 1=x, 2=y, 4=z), each
// ordered from the LOW corner to the high one along its axis
constexpr int kEdge[12][2] = {{0,1},{2,3},{4,5},{6,7}, {0,2},{1,3},{4,6},{5,7},
                              {0,4},{1,5},{2,6},{3,7}};
constexpr int kEdgeAxis[12] = {0,0,0,0, 1,1,1,1, 2,2,2,2};
// ★ THE MANIFOLD CRITERION (Schaefer, Ju & Warren). One vertex per CELL is only right
// when the surface crosses that cell in ONE piece. Where two struts pass close without
// touching, a single cell can carry two separate sheets, and forcing them through one
// vertex is what makes an edge belong to more than two triangles -- measured at ~4,400
// such edges on the M2 lattice, a count that stayed flat as the grid refined, which is
// the signature of a configuration problem rather than a resolution one. So the cell's
// crossings are grouped into connected components and each gets its OWN vertex.
//
// Components are found on the cube's FACES: two crossings on the same face are joined if
// the face's sign pattern connects them. A face with four crossings is ambiguous, and
// rather than guess we evaluate the exact field at the face centre -- which we can
// afford, and which no marching-cubes table can do.
constexpr int kFaceCorner[6][4] = {{0,2,6,4}, {1,3,7,5}, {0,1,5,4},
                                   {2,3,7,6}, {0,1,3,2}, {4,5,7,6}};
constexpr int kFaceEdge[6][4]   = {{4,10,6,8}, {5,11,7,9}, {0,9,2,8},
                                   {1,11,3,10}, {0,5,1,4}, {2,7,3,6}};

struct Dsu {
  int p[12];
  Dsu() { for (int i = 0; i < 12; ++i) p[i] = i; }
  int find(int x) { while (p[x] != x) { p[x] = p[p[x]]; x = p[x]; } return x; }
  void join(int a, int b) { a = find(a); b = find(b); if (a != b) p[a] = b; }
};

// ── one cell, analysed ───────────────────────────────────────────────────────
// Shared by the uniform grid and the octree so the two cannot drift apart. A cube has 12
// edges, so at most four disjoint surface components can cross it (each needs a closed
// loop of at least three crossings).
constexpr int kMaxComponents = 4;

struct CellAnalysis {
  std::array<signed char, 12> comp{};   // component of each edge's crossing, -1 = none
  int ncross = 0;
  int ncomp = 0;
  bool ambiguous_face = false;          // a face crossed four times: two arcs, or one
  std::array<Qef, kMaxComponents> qef{};
  std::array<Vec3, kMaxComponents> pos{};
};

// v[8] are the corner values in corner-index order; lo is the cell's minimum corner.
void analyse_cell(const Field& F, const Vec3& lo, double size, const double v[8],
                  int crossing_steps, double lambda, CellAnalysis& A) {
  A = CellAnalysis{};
  A.comp.fill(-1);
  auto corner_pos = [&](int c) {
    return Vec3{lo.x + ((c & 1) ? size : 0.0), lo.y + (((c >> 1) & 1) ? size : 0.0),
                lo.z + (((c >> 2) & 1) ? size : 0.0)}; };

  std::array<int, 12> has{};
  std::array<Vec3, 12> xp{}, xn{};
  has.fill(0);
  for (int e = 0; e < 12; ++e) {
    const int c0 = kEdge[e][0], c1 = kEdge[e][1];
    const double d0 = v[c0], d1 = v[c1];
    if ((d0 < 0.0) == (d1 < 0.0)) continue;
    Vec3 a = corner_pos(c0), b = corner_pos(c1);
    double da = d0;
    for (int st = 0; st < crossing_steps; ++st) {   // the field is exact: bisect it
      const Vec3 mid = mul(add(a, b), 0.5);
      const double dm = F.eval(mid);
      if ((dm < 0.0) == (da < 0.0)) { a = mid; da = dm; } else { b = mid; }
    }
    has[static_cast<std::size_t>(e)] = 1;
    xp[static_cast<std::size_t>(e)] = mul(add(a, b), 0.5);
    xn[static_cast<std::size_t>(e)] = F.gradient(xp[static_cast<std::size_t>(e)]);
    ++A.ncross;
  }
  if (A.ncross == 0) return;

  Dsu dsu;
  for (int f = 0; f < 6; ++f) {
    int on[4], cnt = 0;
    for (int t = 0; t < 4; ++t)
      if (has[static_cast<std::size_t>(kFaceEdge[f][t])]) on[cnt++] = t;
    if (cnt == 2) {
      dsu.join(kFaceEdge[f][on[0]], kFaceEdge[f][on[1]]);
    } else if (cnt == 4) {
      A.ambiguous_face = true;
      // ambiguous: ask the field at the face centre which pair is joined
      Vec3 ctr{0, 0, 0};
      for (int t = 0; t < 4; ++t) ctr = add(ctr, corner_pos(kFaceCorner[f][t]));
      ctr = mul(ctr, 0.25);
      const bool centre_in = F.eval(ctr) < 0.0;
      const bool c0_in = v[kFaceCorner[f][0]] < 0.0;
      if (centre_in == c0_in) {          // corner 0 reaches the centre: pair e3-e0, e1-e2
        dsu.join(kFaceEdge[f][3], kFaceEdge[f][0]);
        dsu.join(kFaceEdge[f][1], kFaceEdge[f][2]);
      } else {
        dsu.join(kFaceEdge[f][0], kFaceEdge[f][1]);
        dsu.join(kFaceEdge[f][2], kFaceEdge[f][3]);
      }
    }
  }

  int root_of[12];
  for (int t = 0; t < 12; ++t) root_of[t] = -1;
  for (int e = 0; e < 12; ++e) {
    if (!has[static_cast<std::size_t>(e)]) continue;
    const int r = dsu.find(e);
    int c = -1;
    for (int t = 0; t < A.ncomp; ++t)
      if (root_of[t] == r) { c = t; break; }
    if (c < 0) {
      if (A.ncomp >= kMaxComponents) c = 0;    // cannot happen: 12 edges, 3 per loop
      else { c = A.ncomp; root_of[c] = r; ++A.ncomp; }
    }
    A.comp[static_cast<std::size_t>(e)] = static_cast<signed char>(c);
    A.qef[static_cast<std::size_t>(c)].add_plane(xp[static_cast<std::size_t>(e)],
                                                 xn[static_cast<std::size_t>(e)]);
  }
  for (int c = 0; c < A.ncomp; ++c) {
    Vec3 x = A.qef[static_cast<std::size_t>(c)].solve(lambda);
    x.x = std::min(std::max(x.x, lo.x), lo.x + size);
    x.y = std::min(std::max(x.y, lo.y), lo.y + size);
    x.z = std::min(std::max(x.z, lo.z), lo.z + size);
    A.pos[static_cast<std::size_t>(c)] = x;
  }
}

// ── the four cells around one grid edge ──────────────────────────────────────
// A quad is emitted per sign-changing grid edge and joins the four cells that share it.
// Each of those cells sees the edge as a DIFFERENT one of its own twelve, and must hand
// back the vertex of the component containing it -- that is the whole point of splitting
// a cell. The four are listed anticlockwise about the +axis, so the quad's normal is
// +axis when the edge's low endpoint is inside.
struct EdgeFan {
  long long di[4], dj[4], dk[4];   // cell offsets from the edge's low CORNER
  int slot[4];                     // which of that cell's twelve edges this is
};
constexpr EdgeFan kFanX = {{0,0,0,0}, {0,-1,-1,0}, {0,0,-1,-1}, {0,1,3,2}};
constexpr EdgeFan kFanY = {{0,0,-1,-1}, {0,0,0,0}, {0,-1,-1,0}, {4,6,7,5}};
constexpr EdgeFan kFanZ = {{0,-1,-1,0}, {0,0,-1,-1}, {0,0,0,0}, {8,9,11,10}};
inline const EdgeFan& fan_for(int axis) {
  return axis == 0 ? kFanX : (axis == 1 ? kFanY : kFanZ);
}

void mesh_quality(TriangleMesh& mesh, LatticeDcStats& stats) {
  stats.vertices = mesh.vertices.size();
  stats.triangles = mesh.triangles.size();
  std::unordered_map<long long, int> use;
  use.reserve(mesh.triangles.size() * 2);
  for (const auto& t : mesh.triangles)
    for (int e = 0; e < 3; ++e) {
      const int x = t[e], y = t[(e + 1) % 3];
      const long long key = static_cast<long long>(std::min(x, y)) * 4000000000LL +
                            static_cast<long long>(std::max(x, y));
      ++use[key];
    }
  for (const auto& kv : use) {
    if (kv.second == 1) ++stats.boundary_edges;
    else if (kv.second > 2) ++stats.nonmanifold_edges;
  }
  stats.watertight = stats.boundary_edges == 0;
  stats.manifold = stats.watertight && stats.nonmanifold_edges == 0;
  double vol = 0.0;
  for (const auto& t : mesh.triangles) {
    const Vec3& a = mesh.vertices[static_cast<std::size_t>(t[0])];
    const Vec3& b = mesh.vertices[static_cast<std::size_t>(t[1])];
    const Vec3& c = mesh.vertices[static_cast<std::size_t>(t[2])];
    vol += dot(a, Vec3{b.y * c.z - b.z * c.y, b.z * c.x - b.x * c.z,
                       b.x * c.y - b.y * c.x});
  }
  stats.volume_mm3 = vol / 6.0;
}

Field build_field(const std::vector<OrganicSpan>& spans, double& rmin, double& rmax) {
  Field F;
  rmin = 1e30; rmax = 0.0;
  for (const OrganicSpan& sp : spans) {
    if (!(sp.r > 0.0)) continue;
    Cap c;
    c.a = sp.a; c.ab = sub(sp.b, sp.a); c.ab2 = dot(c.ab, c.ab); c.r = sp.r;
    F.caps.push_back(c);
    rmin = std::min(rmin, sp.r); rmax = std::max(rmax, sp.r);
  }
  if (F.caps.empty()) return F;
  F.cell = std::max(2.0 * rmax, 1e-6);
  for (std::size_t n = 0; n < F.caps.size(); ++n) {
    const Cap& c = F.caps[n];
    const Vec3 b = add(c.a, c.ab);
    const Vec3 lo{std::min(c.a.x, b.x) - c.r, std::min(c.a.y, b.y) - c.r,
                  std::min(c.a.z, b.z) - c.r};
    const Vec3 hi{std::max(c.a.x, b.x) + c.r, std::max(c.a.y, b.y) + c.r,
                  std::max(c.a.z, b.z) + c.r};
    for (long long i = static_cast<long long>(std::floor(lo.x / F.cell));
         i <= static_cast<long long>(std::floor(hi.x / F.cell)); ++i)
      for (long long j = static_cast<long long>(std::floor(lo.y / F.cell));
           j <= static_cast<long long>(std::floor(hi.y / F.cell)); ++j)
        for (long long k = static_cast<long long>(std::floor(lo.z / F.cell));
             k <= static_cast<long long>(std::floor(hi.z / F.cell)); ++k)
          F.grid[Field::key_of(i, j, k)].push_back(static_cast<int>(n));
  }
  return F;
}

// ═══ the uniform grid, kept as the reference implementation ══════════════════
TriangleMesh contour_uniform(const Field& F, double h, const LatticeDcOptions& opt,
                             LatticeDcStats& stats) {
  TriangleMesh mesh;
  std::unordered_map<long long, double> corner;
  auto corner_at = [&](long long i, long long j, long long k) {
    const long long key = cell_key(i, j, k);
    auto it = corner.find(key);
    if (it != corner.end()) return it->second;
    const double v = F.eval(Vec3{i * h, j * h, k * h});
    corner.emplace(key, v);
    return v; };

  std::vector<std::array<long long, 3>> active;
  {
    std::unordered_map<long long, char> seen;
    for (const Cap& c : F.caps) {
      const Vec3 b = add(c.a, c.ab);
      // ★ THE WALK MUST COVER A CELL'S NEIGHBOURS, NOT JUST THE CELL. A quad is emitted
      // for a sign-changing grid edge and joins the FOUR cells sharing it, so every one
      // of those must have been visited or the quad is dropped and the mesh opens.
      const double pad = c.r + 3.0 * h;
      const long long i0 = static_cast<long long>(std::floor((std::min(c.a.x, b.x) - pad) / h));
      const long long i1 = static_cast<long long>(std::ceil((std::max(c.a.x, b.x) + pad) / h));
      const long long j0 = static_cast<long long>(std::floor((std::min(c.a.y, b.y) - pad) / h));
      const long long j1 = static_cast<long long>(std::ceil((std::max(c.a.y, b.y) + pad) / h));
      const long long k0 = static_cast<long long>(std::floor((std::min(c.a.z, b.z) - pad) / h));
      const long long k1 = static_cast<long long>(std::ceil((std::max(c.a.z, b.z) + pad) / h));
      for (long long i = i0; i <= i1; ++i)
        for (long long j = j0; j <= j1; ++j)
          for (long long k = k0; k <= k1; ++k) {
            const long long key = cell_key(i, j, k);
            if (seen.count(key)) continue;
            seen.emplace(key, 1);
            ++stats.cells_visited;
            bool neg = false, pos = false;
            for (int ci = 0; ci < 8; ++ci) {
              const double v = corner_at(i + (ci & 1), j + ((ci >> 1) & 1), k + ((ci >> 2) & 1));
              (v < 0.0 ? neg : pos) = true;
            }
            if (!(neg && pos)) continue;            // wholly inside or wholly outside
            active.push_back({i, j, k});
          }
    }
  }
  stats.cells_active = active.size();

  std::unordered_map<long long, std::array<int, 12>> cell_slot;
  cell_slot.reserve(active.size() * 2);
  CellAnalysis A;
  for (const auto& c : active) {
    const long long i = c[0], j = c[1], k = c[2];
    double v[8];
    for (int ci = 0; ci < 8; ++ci)
      v[ci] = corner_at(i + (ci & 1), j + ((ci >> 1) & 1), k + ((ci >> 2) & 1));
    analyse_cell(F, Vec3{i * h, j * h, k * h}, h, v, opt.crossing_steps,
                 opt.qef_regularisation, A);
    const int vfirst = static_cast<int>(mesh.vertices.size());
    for (int t = 0; t < A.ncomp; ++t) mesh.vertices.push_back(A.pos[static_cast<std::size_t>(t)]);
    if (A.ncomp > 1) ++stats.cells_split;
    std::array<int, 12> slot{};
    for (int e = 0; e < 12; ++e)
      slot[static_cast<std::size_t>(e)] =
          A.comp[static_cast<std::size_t>(e)] < 0 ? -1 : vfirst + A.comp[static_cast<std::size_t>(e)];
    cell_slot.emplace(cell_key(i, j, k), slot);
  }

  auto vert_on = [&](long long i, long long j, long long k, int slot) {
    auto it = cell_slot.find(cell_key(i, j, k));
    return it == cell_slot.end() ? -1 : it->second[static_cast<std::size_t>(slot)]; };
  auto emit = [&](int a, int b, int c2, int d, bool flip) {
    if (a < 0 || b < 0 || c2 < 0 || d < 0) { ++stats.quads_dropped; return; }
    if (!flip) {
      mesh.triangles.push_back({a, b, c2});
      mesh.triangles.push_back({a, c2, d});
    } else {
      mesh.triangles.push_back({a, c2, b});
      mesh.triangles.push_back({a, d, c2});
    }
  };
  for (const auto& c : active) {
    const long long i = c[0], j = c[1], k = c[2];
    const double d000 = corner_at(i, j, k);
    // the three edges leaving this cell's minimum corner; every grid edge is reached
    // exactly once this way
    const double dx = corner_at(i + 1, j, k), dy = corner_at(i, j + 1, k),
                 dz = corner_at(i, j, k + 1);
    for (int axis = 0; axis < 3; ++axis) {
      const double dn = axis == 0 ? dx : (axis == 1 ? dy : dz);
      if ((d000 < 0.0) == (dn < 0.0)) continue;
      const EdgeFan& f = fan_for(axis);
      int vv[4];
      for (int t = 0; t < 4; ++t)
        vv[t] = vert_on(i + f.di[t], j + f.dj[t], k + f.dk[t], f.slot[t]);
      emit(vv[0], vv[1], vv[2], vv[3], d000 >= 0.0);
    }
  }
  stats.field_evaluations = F.evals;
  return mesh;
}


// ═══ the octree ══════════════════════════════════════════════════════════════
// It only ever goes COARSER than the base grid, and that is a finding, not a limitation.
//
// COARSENING is the size dial. A uniform 0.2 mm grid spends the same triangle budget on
// the middle of a straight strut as on a six-way joint, and the middle of a strut is
// exactly where one merged vertex is right. The merge is accepted on the RESIDUAL of the
// summed child QEFs, so its tolerance is a real distance in mm rather than a heuristic,
// and the sum is exact: a parent's QEF is its children's added together, so the merged
// vertex is fitted to every fine crossing plane beneath it, not to a resampling of them.
//
// REFINING BELOW THE BASE was built, measured and withdrawn. The remaining non-manifold
// edges come from a face crossed FOUR times whose two cells each group all four crossings
// into one component -- the dual then runs four quads between the same pair of vertices.
// That looked like a resolution artefact (the count fell 284 -> 153 from 0.4 mm to
// 0.2 mm), so those cells were taken one level finer. It made things WORSE: 284
// non-manifold edges became 591, with 177 boundary edges and 129 dropped quads where
// there had been none, and widening the refinement to the cell's whole one-ring made it
// worse again (3,871 boundary, 2,595 dropped). The cause is that a coarse cell beside a
// refined one cannot see, at its own corners, a crossing that exists only on the finer
// grid, so it reports itself empty and the mesh opens along that face. Coarsening never
// meets this, because it only merges cells whose fine crossings it has already summed --
// which is why the same level changes are harmless in that direction. So the base grid is
// chosen fine enough, and the tree buys the cost back by merging upwards.
//
// ★ AND THE TREE IS SEEDED FROM THE NARROW BAND, NOT DESCENDED BLINDLY FROM A ROOT. A
// root node covering a 203 mm part cannot be tested for emptiness cheaply -- the field's
// spatial hash would have to be swept over the whole box -- so instead the base cells are
// collected exactly as the uniform path collects them, their ancestors are marked
// occupied, and the recursion only ever enters a node some candidate lies in.

inline long long fdiv2(long long a) { return a >= 0 ? (a >> 1) : -(((-a) + 1) >> 1); }

// level counts SIZE: cell = cell_mm * 2^level, and level 0 -- the base -- coincides
// cell-for-cell with the uniform path's grid, which is what lets the two be compared
// directly. Nothing is ever built below level 0.
constexpr int kLevelBias = 8;
inline long long lvl_key(int lvl, long long i, long long j, long long k) {
  constexpr long long b = 1LL << 18;
  return (static_cast<long long>(lvl + kLevelBias) << 57) | (((i + b) & 0x7FFFF) << 38) |
         (((j + b) & 0x7FFFF) << 19) | ((k + b) & 0x7FFFF);
}

inline std::array<long long, 3> lvl_coords(long long key) {
  constexpr long long b = 1LL << 18;
  return {((key >> 38) & 0x7FFFF) - b, ((key >> 19) & 0x7FFFF) - b, (key & 0x7FFFF) - b};
}

struct Leaf {
  int level = 0;
  int i = 0, j = 0, k = 0;
  unsigned char signs = 0;      // bit c set => corner c is INSIDE
  unsigned char ncomp = 0;
  std::uint64_t comp = 0;       // 4 bits per edge, 0xF = no crossing
  int vfirst = -1;
  int slot(int e) const {
    const unsigned c = static_cast<unsigned>((comp >> (4 * e)) & 0xF);
    return c == 0xF ? -1 : vfirst + static_cast<int>(c);
  }
};

// What a node hands back to its parent. A node is only COMMITTED as a leaf once its
// parent has declined to merge it, so a merge costs nothing to undo -- and because the
// recursion computes children on demand, only the current path is ever in memory.
struct Prov {
  enum Kind { Empty, Leaf_, Internal } kind = Empty;
  CellAnalysis an;
  Qef qef;                             // every crossing plane in the SUBTREE
  unsigned short edge_clean = 0xFFF;   // bit e: no sign change is hidden inside edge e
};

struct Octree {
  const Field& F;
  const LatticeDcOptions& opt;
  LatticeDcStats& stats;
  double h = 0.0;                 // the base cell, and the finest a leaf can be
  int up = 0;                     // levels of merging allowed above the base
  double tol = 0.0;
  std::vector<std::unordered_map<long long, char>> occupied;   // index = level
  std::unordered_map<long long, double> corner;
  std::unordered_map<long long, char> internal;   // nodes that hold FINER leaves
  std::vector<Leaf> leaves;
  std::unordered_map<long long, int> leaf_at;
  TriangleMesh mesh;

  double size_of(int lvl) const { return h * std::ldexp(1.0, lvl); }

  // Corners live on the FINEST grid, so one cache serves every level.
  double corner_f(long long fi, long long fj, long long fk) {
    const long long key = cell_key(fi, fj, fk);
    auto it = corner.find(key);
    if (it != corner.end()) return it->second;
    const double hf = h;
    const double v = F.eval(Vec3{fi * hf, fj * hf, fk * hf});
    corner.emplace(key, v);
    return v;
  }
  void corners_of(int lvl, long long i, long long j, long long k, double v[8]) {
    const long long m = 1LL << lvl;
    for (int c = 0; c < 8; ++c)
      v[c] = corner_f(i * m + ((c & 1) ? m : 0), j * m + (((c >> 1) & 1) ? m : 0),
                      k * m + (((c >> 2) & 1) ? m : 0));
  }
  Vec3 lo_of(int lvl, long long i, long long j, long long k) const {
    const double s = size_of(lvl);
    return Vec3{i * s, j * s, k * s};
  }

  void commit(const Prov& p, int lvl, long long i, long long j, long long k) {
    if (p.kind == Prov::Internal) { internal.emplace(lvl_key(lvl, i, j, k), 1); return; }
    if (p.kind != Prov::Leaf_) return;
    Leaf L;
    L.level = lvl;
    L.i = static_cast<int>(i); L.j = static_cast<int>(j); L.k = static_cast<int>(k);
    double v[8];
    corners_of(lvl, i, j, k, v);
    for (int c = 0; c < 8; ++c) if (v[c] < 0.0) L.signs |= static_cast<unsigned char>(1u << c);
    L.ncomp = static_cast<unsigned char>(p.an.ncomp);
    for (int e = 0; e < 12; ++e) {
      const std::uint64_t c =
          p.an.comp[static_cast<std::size_t>(e)] < 0
              ? 0xFULL
              : static_cast<std::uint64_t>(p.an.comp[static_cast<std::size_t>(e)]);
      L.comp |= c << (4 * e);
    }
    L.vfirst = static_cast<int>(mesh.vertices.size());
    for (int c = 0; c < p.an.ncomp; ++c)
      mesh.vertices.push_back(p.an.pos[static_cast<std::size_t>(c)]);
    if (p.an.ncomp > 1) ++stats.cells_split;
    if (lvl > 0) ++stats.cells_merged;
    ++stats.cells_active;
    leaf_at.emplace(lvl_key(lvl, i, j, k), static_cast<int>(leaves.size()));
    leaves.push_back(L);
  }

  // ── the base cell ───────────────────────────────────────────────────────────
  Prov base_cell(long long i, long long j, long long k) {
    ++stats.cells_visited;
    Prov out;
    double v[8];
    corners_of(0, i, j, k, v);
    bool neg = false, pos = false;
    for (int c = 0; c < 8; ++c) (v[c] < 0.0 ? neg : pos) = true;
    if (!(neg && pos)) return out;                  // wholly inside or wholly outside
    analyse_cell(F, lo_of(0, i, j, k), h, v, opt.crossing_steps, opt.qef_regularisation,
                 out.an);
    if (out.an.ncross == 0) return out;
    out.kind = Prov::Leaf_;
    for (int c = 0; c < out.an.ncomp; ++c) out.qef.add(out.an.qef[static_cast<std::size_t>(c)]);
    return out;
  }

  // ── above the base: build the children, then try to merge them away ────────
  Prov node(int lvl, long long i, long long j, long long k) {
    if (!occupied[static_cast<std::size_t>(lvl)].count(lvl_key(lvl, i, j, k))) return Prov{};
    if (lvl == 0) return base_cell(i, j, k);
    ++stats.cells_visited;
    Prov kid[8];
    bool any = false, all_leafish = true;
    for (int c = 0; c < 8; ++c) {
      kid[c] = node(lvl - 1, 2 * i + (c & 1), 2 * j + ((c >> 1) & 1), 2 * k + ((c >> 2) & 1));
      if (kid[c].kind != Prov::Empty) any = true;
      if (kid[c].kind == Prov::Internal) all_leafish = false;
    }
    Prov out;
    if (!any) return out;
    if (try_merge(lvl, i, j, k, kid, all_leafish, out)) return out;
    for (int c = 0; c < 8; ++c)
      commit(kid[c], lvl - 1, 2 * i + (c & 1), 2 * j + ((c >> 1) & 1), 2 * k + ((c >> 2) & 1));
    out.kind = Prov::Internal;
    return out;
  }

  // ── the merge test ──────────────────────────────────────────────────────────
  // Five conditions, ordered CHEAPEST FIRST because most candidates are refused: each one
  // is there to stop a specific failure the measurements catch -- an open mesh, a
  // non-manifold edge, or a strut swallowed whole.
  bool try_merge(int lvl, long long i, long long j, long long k, const Prov kid[8],
                 bool all_leafish, Prov& out) {
    if (!all_leafish) return false;                        // (1) a child still has children
    for (int c = 0; c < 8; ++c)
      if (kid[c].kind == Prov::Leaf_ && kid[c].an.ncomp > 1) return false;   // (2)

    // (3) the geometry: fit ONE vertex to every fine crossing plane beneath this node and
    // refuse the merge if they sit further off it than the tolerance allows. This is the
    // test that rejects most candidates, and it costs no field evaluation at all -- the
    // children's normal equations are already summed -- so it is asked first.
    Qef q;
    for (int c = 0; c < 8; ++c) q.add(kid[c].qef);
    if (q.n == 0) return false;
    Vec3 x = q.solve(opt.qef_regularisation);
    if (q.rms(x) > tol) return false;

    // (4) nothing may be hidden INSIDE an edge of the merged cell. A strut thinner than
    // the merged cell can pass straight through one edge, changing sign twice, and the
    // merged corners would never see it -- the mesh would then open along that edge. The
    // children know: an edge is clean when both halves are clean and the midpoint agrees
    // with equal-signed ends, which carries the guarantee all the way down by induction.
    const double size = size_of(lvl);
    const Vec3 lo = lo_of(lvl, i, j, k);
    double v[8];
    corners_of(lvl, i, j, k, v);
    const long long m = 1LL << lvl, hm = m / 2;
    auto at = [&](int c, long long ox, long long oy, long long oz) {
      return corner_f(i * m + ((c & 1) ? m : 0) + ox, j * m + (((c >> 1) & 1) ? m : 0) + oy,
                      k * m + (((c >> 2) & 1) ? m : 0) + oz); };
    unsigned short clean = 0;
    for (int e = 0; e < 12; ++e) {
      const int c0 = kEdge[e][0], c1 = kEdge[e][1], ax = kEdgeAxis[e];
      const double vm = at(c0, ax == 0 ? hm : 0, ax == 1 ? hm : 0, ax == 2 ? hm : 0);
      const bool a_in = v[c0] < 0.0, b_in = v[c1] < 0.0, m_in = vm < 0.0;
      const bool halves = ((kid[c0].edge_clean >> e) & 1) && ((kid[c1].edge_clean >> e) & 1);
      const bool nothing_hidden = (a_in != b_in) || (m_in == a_in);
      if (halves && nothing_hidden) clean |= static_cast<unsigned short>(1u << e);
    }
    if (clean != 0xFFF) return false;

    // (5) and last, because it is the only step that costs bisections and gradients: the
    // merged cell must itself be a single sheet crossing no face twice -- the same
    // condition that makes a leaf manifold in the first place.
    CellAnalysis A;
    analyse_cell(F, lo, size, v, opt.crossing_steps, opt.qef_regularisation, A);
    if (A.ncomp != 1 || A.ambiguous_face) return false;

    x.x = std::min(std::max(x.x, lo.x), lo.x + size);
    x.y = std::min(std::max(x.y, lo.y), lo.y + size);
    x.z = std::min(std::max(x.z, lo.z), lo.z + size);
    out.kind = Prov::Leaf_;
    out.an = A;
    out.an.pos[0] = x;
    out.qef = q;
    out.edge_clean = clean;
    return true;
  }

  bool has_finer(int lvl, long long i, long long j, long long k) const {
    return internal.count(lvl_key(lvl, i, j, k)) != 0;
  }
  // the leaf holding a given cell, at that level or COARSER
  int leaf_covering(int lvl, long long i, long long j, long long k) const {
    long long a = i, b = j, c = k;
    for (int l = lvl; l <= up; ++l) {
      auto it = leaf_at.find(lvl_key(l, a, b, c));
      if (it != leaf_at.end()) return it->second;
      a = fdiv2(a); b = fdiv2(b); c = fdiv2(c);
    }
    return -1;
  }

  // ── the quads ───────────────────────────────────────────────────────────────
  // One per MINIMAL sign-changing grid edge -- the edge is owned by the finest leaf that
  // touches it -- so a coarse leaf beside finer ones simply contributes its single vertex
  // to each of their quads, and the level change is crack-free with no patching at all.
  void emit_quads() {
    auto push = [&](const int vv[4], bool flip) {
      int u[4], n = 0;                 // a coarse neighbour appears twice: that is a triangle
      for (int t = 0; t < 4; ++t)
        if (n == 0 || vv[t] != u[n - 1]) u[n++] = vv[t];
      if (n > 1 && u[0] == u[n - 1]) --n;
      if (n < 3) return;
      if (!flip) {
        mesh.triangles.push_back({u[0], u[1], u[2]});
        if (n == 4) mesh.triangles.push_back({u[0], u[2], u[3]});
      } else {
        mesh.triangles.push_back({u[0], u[2], u[1]});
        if (n == 4) mesh.triangles.push_back({u[0], u[3], u[2]});
      }
    };
    for (std::size_t li = 0; li < leaves.size(); ++li) {
      const Leaf& L = leaves[li];
      for (int e = 0; e < 12; ++e) {
        const int c0 = kEdge[e][0], c1 = kEdge[e][1];
        const bool in0 = ((L.signs >> c0) & 1) != 0, in1 = ((L.signs >> c1) & 1) != 0;
        if (in0 == in1) continue;
        const EdgeFan& f = fan_for(kEdgeAxis[e]);
        const long long ci = L.i + (c0 & 1), cj = L.j + ((c0 >> 1) & 1),
                        ck = L.k + ((c0 >> 2) & 1);
        int cell[4];
        bool finest_here = true;
        for (int t = 0; t < 4 && finest_here; ++t) {
          const long long a = ci + f.di[t], b = cj + f.dj[t], c = ck + f.dk[t];
          if (has_finer(L.level, a, b, c)) finest_here = false;   // a finer leaf owns it
          else cell[t] = leaf_covering(L.level, a, b, c);
        }
        if (!finest_here) continue;
        int owner = -1;
        for (int t = 0; t < 4 && owner < 0; ++t)
          if (cell[t] >= 0 && leaves[static_cast<std::size_t>(cell[t])].level == L.level)
            owner = cell[t];
        if (owner != static_cast<int>(li)) continue;    // another same-level leaf emits it
        int vv[4];
        bool ok = true;
        for (int t = 0; t < 4 && ok; ++t) {
          if (cell[t] < 0) { ok = false; break; }
          const Leaf& N = leaves[static_cast<std::size_t>(cell[t])];
          vv[t] = N.level == L.level ? N.slot(f.slot[t]) : N.vfirst;
          if (vv[t] < 0) ok = false;
        }
        if (!ok) { ++stats.quads_dropped; continue; }
        push(vv, !in0);
      }
    }
  }
};

TriangleMesh contour_octree(const Field& F, double h, const LatticeDcOptions& opt,
                            LatticeDcStats& stats) {
  Octree T{F, opt, stats};
  T.h = h;
  T.up = 0;
  while (std::ldexp(1.0, T.up + 1) <= std::max(1.0, opt.max_leaf_multiple)) ++T.up;
  T.up = std::min(T.up, 6);
  T.tol = opt.simplify_tolerance_mm > 0.0 ? opt.simplify_tolerance_mm : 0.1 * h;
  stats.simplify_tolerance_mm = T.tol;

  // ── the narrow band, and its ancestors ──────────────────────────────────────
  // Identical to the uniform path's walk, for the same reason: a quad joins the four
  // cells around a grid edge, so every one of them must be reachable or the quad is
  // dropped and the mesh opens.
  T.occupied.assign(static_cast<std::size_t>(T.up) + 1, {});
  for (const Cap& c : F.caps) {
    const Vec3 b = add(c.a, c.ab);
    const double pad = c.r + 3.0 * h;
    const long long i0 = static_cast<long long>(std::floor((std::min(c.a.x, b.x) - pad) / h));
    const long long i1 = static_cast<long long>(std::ceil((std::max(c.a.x, b.x) + pad) / h));
    const long long j0 = static_cast<long long>(std::floor((std::min(c.a.y, b.y) - pad) / h));
    const long long j1 = static_cast<long long>(std::ceil((std::max(c.a.y, b.y) + pad) / h));
    const long long k0 = static_cast<long long>(std::floor((std::min(c.a.z, b.z) - pad) / h));
    const long long k1 = static_cast<long long>(std::ceil((std::max(c.a.z, b.z) + pad) / h));
    for (long long i = i0; i <= i1; ++i)
      for (long long j = j0; j <= j1; ++j)
        for (long long k = k0; k <= k1; ++k) {
          long long a = i, b2 = j, c2 = k;
          for (int l = 0; l <= T.up; ++l) {
            if (!T.occupied[static_cast<std::size_t>(l)].emplace(lvl_key(l, a, b2, c2), 1).second)
              break;                       // this ancestor, and every one above, is marked
            a = fdiv2(a); b2 = fdiv2(b2); c2 = fdiv2(c2);
          }
        }
  }

  // Drive the recursion from the coarsest level: every node it enters holds a candidate.
  std::vector<std::array<long long, 3>> top;
  top.reserve(T.occupied[static_cast<std::size_t>(T.up)].size());
  for (const auto& kv : T.occupied[static_cast<std::size_t>(T.up)])
    top.push_back(lvl_coords(kv.first));
  std::sort(top.begin(), top.end());     // deterministic vertex order
  for (const auto& t : top) {
    Prov p = T.node(T.up, t[0], t[1], t[2]);
    T.commit(p, T.up, t[0], t[1], t[2]);
  }

  T.occupied.clear();
  T.corner.clear();                        // the signs the emission needs are on the leaves
  T.emit_quads();

  stats.cell_mm = h;
  double fine = 1e30, coarse = 0.0;
  for (const Leaf& L : T.leaves) {
    const double s = T.size_of(L.level);
    fine = std::min(fine, s); coarse = std::max(coarse, s);
  }
  stats.finest_leaf_mm = T.leaves.empty() ? 0.0 : fine;
  stats.coarsest_leaf_mm = coarse;
  stats.field_evaluations = F.evals;
  return T.mesh;
}

}  // namespace

TriangleMesh lattice_dual_contour(const std::vector<OrganicSpan>& spans,
                                  const LatticeDcOptions& opt, LatticeDcStats& stats) {
  stats = LatticeDcStats{};
  const double t0 = now_seconds();
  double rmin = 1e30, rmax = 0.0;
  Field F = build_field(spans, rmin, rmax);
  stats.capsules = F.caps.size();
  if (F.caps.empty()) return TriangleMesh{};

  F.clip_z = opt.clip_below_z;
  double h = opt.cell_mm > 0.0
                 ? opt.cell_mm
                 : (2.0 * rmin) / std::max(1, opt.cells_across_thinnest);
  stats.cell_mm_requested = h;
  // ★ THE CELL IS RAISED TO FIT THE BUDGET BEFORE ANYTHING IS ALLOCATED. The active-cell
  // count is about (capsule surface area)/cell^2 -- measured at 3.18 M against an estimate
  // of 2.64 M on the M2 lattice, so the estimate is the right order and errs low by ~20 %,
  // which the budget absorbs. Without this, an automatic cell derived from the THINNEST
  // strut asks a 16 GB machine for a 20 GB corner cache and the run dies half way.
  if (opt.max_active_cells > 0) {
    double area = 0.0;
    for (const Cap& c : F.caps) area += 2.0 * M_PI * c.r * (std::sqrt(c.ab2) + 2.0 * c.r);
    const double hmin = std::sqrt(1.2 * area / static_cast<double>(opt.max_active_cells));
    if (h < hmin) h = hmin;
  }
  stats.cell_mm = h;
  TriangleMesh mesh = opt.adaptive ? contour_octree(F, h, opt, stats)
                                   : contour_uniform(F, h, opt, stats);
  if (!opt.adaptive) { stats.finest_leaf_mm = h; stats.coarsest_leaf_mm = h; }
  if (stats.quads_dropped && std::getenv("TOPOPT_DC_TRACE"))
    std::fprintf(stderr, "[dc] %zu quad(s) dropped: a neighbouring cell had no vertex\n",
                 stats.quads_dropped);
  mesh_quality(mesh, stats);
  stats.seconds = now_seconds() - t0;
  return mesh;
}

}  // namespace topopt
