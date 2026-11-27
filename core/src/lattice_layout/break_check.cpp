// Organic strength, CUT 1 stage C1: the break check on the printed shape (see lattice_layout_break.hpp).
#include "topopt/lattice_layout_break.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <limits>
#include <map>
#include <stdexcept>
#include <unistd.h>

#include "topopt/fea.hpp"
#include "topopt/observability.hpp"
#include "topopt/segment.hpp"
#include "topopt/voxel.hpp"

namespace topopt::lattice_layout {
namespace {

constexpr double kBytesPerMaterialVoxel = 3200.0;   // the plan's estimate (section 4), to be measured in M1
// Review 4: the full-box arrays (tags, E, the stresses, classes, the distance and multiple, five masks: about 49 B) and
// the solution (3 doubles per node, about 24 B per box voxel).
constexpr double kBytesPerBoxVoxel = 73.0;

struct Grid {
  Vec3 lo{};
  double h = 0.0;
  int nx = 0, ny = 0, nz = 0;
  std::size_t index(int i, int j, int k) const {
    return (static_cast<std::size_t>(k) * static_cast<std::size_t>(ny) + static_cast<std::size_t>(j)) * static_cast<std::size_t>(nx) +
           static_cast<std::size_t>(i);
  }
  Vec3 centre(int i, int j, int k) const { return {lo.x + (i + 0.5) * h, lo.y + (j + 0.5) * h, lo.z + (k + 0.5) * h}; }
};

Grid grid_of(const BreakAsk& ask) {
  if (!ask.print || ask.print->vertices.empty() || !(ask.voxel_mm > 0.0)) throw std::invalid_argument("break check: no print or no voxel size");
  Vec3 mn{1e300, 1e300, 1e300}, mx{-1e300, -1e300, -1e300};
  for (const Vec3& v : ask.print->vertices) {
    mn = {std::min(mn.x, v.x), std::min(mn.y, v.y), std::min(mn.z, v.z)};
    mx = {std::max(mx.x, v.x), std::max(mx.y, v.y), std::max(mx.z, v.z)};
  }
  // The grid is anchored to the PART's box (its low corner, plus grid_shift voxels), so the same part gives the same
  // voxels whatever the lay adds a hair outside it; it is then extended by whole voxels to hold the whole print.
  Vec3 an = mn;
  if (ask.part && !ask.part->mesh.vertices.empty()) {
    an = {1e300, 1e300, 1e300};
    for (const Vec3& v : ask.part->mesh.vertices) an = {std::min(an.x, v.x), std::min(an.y, v.y), std::min(an.z, v.z)};
  }
  Grid g;
  g.h = ask.voxel_mm;
  const double ax = an.x + ask.grid_shift.x * g.h, ay = an.y + ask.grid_shift.y * g.h, az = an.z + ask.grid_shift.z * g.h;
  auto below = [&](double anchor, double lo) { return anchor - std::max(0.0, std::ceil((anchor - lo) / g.h - 1e-9)) * g.h; };
  g.lo = {below(ax, mn.x), below(ay, mn.y), below(az, mn.z)};
  // up to the print's high side: the last voxel's centre no further than half a voxel past it
  g.nx = std::max(1, static_cast<int>(std::lround((mx.x - g.lo.x) / g.h)));
  g.ny = std::max(1, static_cast<int>(std::lround((mx.y - g.lo.y) / g.h)));
  g.nz = std::max(1, static_cast<int>(std::lround((mx.z - g.lo.z) / g.h)));
  return g;
}

// The material voxels counted row by row with the product voxeliser's own rule (voxelize.cpp voxelize_fill: a +Z
// signed-crossing scan, boundary-inclusive triangles, the winding of the crossings above the centre non-zero), so the
// count equals voxelize_onto_grid's without a box-sized array: per row only that row's columns' crossings are held.
std::size_t count_material(const BreakAsk& ask, const Grid& g) {
  const TriangleMesh& mesh = *ask.print;
  const Vec3 lo = g.lo;
  const double h = g.h;
  const int nx = g.nx, ny = g.ny, nz = g.nz;
  std::vector<std::vector<int>> rows(static_cast<std::size_t>(ny));
  for (std::size_t t = 0; t < mesh.triangles.size(); ++t) {
    const auto& tri = mesh.triangles[t];
    const Vec3& a = mesh.vertices[static_cast<std::size_t>(tri[0])];
    const Vec3& b = mesh.vertices[static_cast<std::size_t>(tri[1])];
    const Vec3& c = mesh.vertices[static_cast<std::size_t>(tri[2])];
    const double area2 = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
    if (std::fabs(area2) < 1e-18) continue;
    const double tri_min_y = std::min(a.y, std::min(b.y, c.y));
    const double tri_max_y = std::max(a.y, std::max(b.y, c.y));
    int j0 = static_cast<int>(std::floor((tri_min_y - lo.y) / h - 0.5));
    int j1 = static_cast<int>(std::ceil((tri_max_y - lo.y) / h - 0.5));
    j0 = std::max(j0, 0);
    j1 = std::min(j1, ny - 1);
    for (int j = j0; j <= j1; ++j) rows[static_cast<std::size_t>(j)].push_back(static_cast<int>(t));
  }
  struct Crossing { double z; int sign; };
  std::size_t count = 0;
  std::vector<std::vector<Crossing>> columns(static_cast<std::size_t>(nx));
  for (int j = 0; j < ny; ++j) {
    for (auto& col : columns) col.clear();
    const double py = lo.y + (static_cast<double>(j) + 0.5) * h;
    for (int t : rows[static_cast<std::size_t>(j)]) {
      const auto& tri = mesh.triangles[static_cast<std::size_t>(t)];
      const Vec3& a = mesh.vertices[static_cast<std::size_t>(tri[0])];
      const Vec3& b = mesh.vertices[static_cast<std::size_t>(tri[1])];
      const Vec3& c = mesh.vertices[static_cast<std::size_t>(tri[2])];
      const double area2 = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
      const int sign = area2 > 0.0 ? 1 : -1;
      const double tri_min_x = std::min(a.x, std::min(b.x, c.x));
      const double tri_max_x = std::max(a.x, std::max(b.x, c.x));
      int i0 = static_cast<int>(std::floor((tri_min_x - lo.x) / h - 0.5));
      int i1 = static_cast<int>(std::ceil((tri_max_x - lo.x) / h - 0.5));
      i0 = std::max(i0, 0);
      i1 = std::min(i1, nx - 1);
      for (int i = i0; i <= i1; ++i) {
        const double px = lo.x + (static_cast<double>(i) + 0.5) * h;
        const double e0 = (b.x - a.x) * (py - a.y) - (b.y - a.y) * (px - a.x);
        const double e1 = (c.x - b.x) * (py - b.y) - (c.y - b.y) * (px - b.x);
        const double e2 = (a.x - c.x) * (py - c.y) - (a.y - c.y) * (px - c.x);
        const bool inside = (e0 >= 0.0 && e1 >= 0.0 && e2 >= 0.0) || (e0 <= 0.0 && e1 <= 0.0 && e2 <= 0.0);
        if (!inside) continue;
        const double z_hit = (e1 * a.z + e2 * b.z + e0 * c.z) / area2;
        columns[static_cast<std::size_t>(i)].push_back(Crossing{z_hit, sign});
      }
    }
    for (auto& cr : columns) {
      if (cr.empty()) continue;
      std::sort(cr.begin(), cr.end(), [](const Crossing& p, const Crossing& q) { return p.z < q.z; });
      int total = 0;
      for (const Crossing& x : cr) total += x.sign;
      int below = 0;
      std::size_t next = 0;
      for (int k = 0; k < nz; ++k) {
        const double cz = lo.z + (static_cast<double>(k) + 0.5) * h;
        while (next < cr.size() && cr[next].z <= cz) {
          below += cr[next].sign;
          ++next;
        }
        if (total - below != 0) ++count;
      }
    }
  }
  return count;
}

std::vector<char> material_of(const BreakAsk& ask, const Grid& g) {
  VoxelGrid ref;
  ref.nx = g.nx;
  ref.ny = g.ny;
  ref.nz = g.nz;
  ref.spacing = g.h;
  ref.origin = g.lo;
  const VoxelGrid v = voxelize_onto_grid(*ask.print, ref);
  std::vector<char> mat(v.tags.size(), 0);
  for (std::size_t e = 0; e < v.tags.size(); ++e) mat[e] = v.tags[e] != VoxelTag::Empty;
  return mat;
}

double seg_dist(const Vec3& p, const Vec3& a, const Vec3& b) {
  const Vec3 ab{b.x - a.x, b.y - a.y, b.z - a.z}, ap{p.x - a.x, p.y - a.y, p.z - a.z};
  const double L2 = ab.x * ab.x + ab.y * ab.y + ab.z * ab.z;
  double t = L2 > 0.0 ? (ap.x * ab.x + ap.y * ab.y + ap.z * ab.z) / L2 : 0.0;
  t = std::min(1.0, std::max(0.0, t));
  const Vec3 q{a.x + t * ab.x - p.x, a.y + t * ab.y - p.y, a.z + t * ab.z - p.z};
  return std::sqrt(q.x * q.x + q.y * q.y + q.z * q.z);
}

double tri_dist(const Vec3& p, const Vec3& a, const Vec3& b, const Vec3& c) {
  // the closest point on triangle abc (Ericson, Real-Time Collision Detection 5.1.5)
  const Vec3 ab{b.x - a.x, b.y - a.y, b.z - a.z}, ac{c.x - a.x, c.y - a.y, c.z - a.z}, ap{p.x - a.x, p.y - a.y, p.z - a.z};
  auto dot = [](const Vec3& u, const Vec3& v) { return u.x * v.x + u.y * v.y + u.z * v.z; };
  auto dist = [&](const Vec3& q) { return std::sqrt((p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y) + (p.z - q.z) * (p.z - q.z)); };
  const double d1 = dot(ab, ap), d2 = dot(ac, ap);
  if (d1 <= 0.0 && d2 <= 0.0) return dist(a);
  const Vec3 bp{p.x - b.x, p.y - b.y, p.z - b.z};
  const double d3 = dot(ab, bp), d4 = dot(ac, bp);
  if (d3 >= 0.0 && d4 <= d3) return dist(b);
  const double vc = d1 * d4 - d3 * d2;
  if (vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0) { const double v = d1 / (d1 - d3); return dist({a.x + v * ab.x, a.y + v * ab.y, a.z + v * ab.z}); }
  const Vec3 cp{p.x - c.x, p.y - c.y, p.z - c.z};
  const double d5 = dot(ab, cp), d6 = dot(ac, cp);
  if (d6 >= 0.0 && d5 <= d6) return dist(c);
  const double vb = d5 * d2 - d1 * d6;
  if (vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0) { const double w = d2 / (d2 - d6); return dist({a.x + w * ac.x, a.y + w * ac.y, a.z + w * ac.z}); }
  const double va = d3 * d6 - d5 * d4;
  if (va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0) {
    const double w = (d4 - d3) / ((d4 - d3) + (d5 - d6));
    return dist({b.x + w * (c.x - b.x), b.y + w * (c.y - b.y), b.z + w * (c.z - b.z)});
  }
  const double denom = 1.0 / (va + vb + vc), v = vb * denom, w = vc * denom;
  return dist({a.x + ab.x * v + ac.x * w, a.y + ab.y * v + ac.y * w, a.z + ab.z * v + ac.z * w});
}

// The exposed voxel faces of the material that lie on the part's faces `faces`: a voxel face whose neighbour across it
// is not material, whose outward axis agrees with the part face's outward normal (cos > 0.7), and whose centre lies
// within one voxel of one of the face's triangles. Each entry: the voxel and its axis (0 -x, 1 +x, 2 -y, 3 +y, 4 -z, 5 +z).
// The exposed faces of material voxels within reach of a part face's triangles (review 1.2: no 0.7 threshold on the normal,
// so chamfers and curved faces are found; only the side is tested: the voxel face must point out of the same side as the
// triangle, dot > 0, else a flat face also takes the side faces of its last voxel layer and the load bunches at its
// edges, the made bar below read 12.06 for 13.95): an exposed voxel face whose centre lies within 0.75 voxel of the face's
// triangles (a voxel face ON the part's plane is within half a voxel of it after the centre rule; 0.75 keeps a feature
// one whole voxel off the face, an auto pad, out of it, review 1.7). Also how much of the face's own area has material
// within one voxel: area samples (sub-triangles no larger than a voxel), each covered when a material voxel's centre
// lies within 1.5 voxels of it.
struct FacePick {
  std::vector<std::array<int, 4>> faces;   // (i, j, k, axis)
  double area_mm2 = 0.0, empty_mm2 = 0.0;
};
FacePick faces_on(const BreakAsk& ask, const Grid& g, const std::vector<char>& mat, int face) {
  FacePick out;
  const TriangleMesh& pm = ask.part->mesh;
  struct Tri { Vec3 a, b, c, lo, hi, n; };
  std::vector<Tri> tris;
  for (std::size_t t = 0; t < pm.triangles.size() && t < ask.part->triangle_face.size(); ++t) {
    if (ask.part->triangle_face[t] != face) continue;
    const auto& q = pm.triangles[t];
    Tri T{pm.vertices[static_cast<std::size_t>(q[0])], pm.vertices[static_cast<std::size_t>(q[1])], pm.vertices[static_cast<std::size_t>(q[2])], {}, {}, {}};
    const Vec3 u{T.b.x - T.a.x, T.b.y - T.a.y, T.b.z - T.a.z}, w{T.c.x - T.a.x, T.c.y - T.a.y, T.c.z - T.a.z};
    T.n = {u.y * w.z - u.z * w.y, u.z * w.x - u.x * w.z, u.x * w.y - u.y * w.x};
    T.lo = {std::min({T.a.x, T.b.x, T.c.x}), std::min({T.a.y, T.b.y, T.c.y}), std::min({T.a.z, T.b.z, T.c.z})};
    T.hi = {std::max({T.a.x, T.b.x, T.c.x}), std::max({T.a.y, T.b.y, T.c.y}), std::max({T.a.z, T.b.z, T.c.z})};
    tris.push_back(T);
  }
  if (tris.empty()) return out;
  const double h = g.h, reach = 0.75 * h;
  auto M = [&](int i, int j, int k) { return i >= 0 && j >= 0 && k >= 0 && i < g.nx && j < g.ny && k < g.nz && mat[g.index(i, j, k)]; };
  const int ax[6][3] = {{-1, 0, 0}, {1, 0, 0}, {0, -1, 0}, {0, 1, 0}, {0, 0, -1}, {0, 0, 1}};
  // exposed voxel faces near each triangle (each voxel face once)
  std::vector<std::array<int, 4>> seen;
  for (const Tri& T : tris) {
    const int i0 = std::max(0, static_cast<int>(std::floor((T.lo.x - reach - g.lo.x) / h)) - 1), i1 = std::min(g.nx - 1, static_cast<int>(std::floor((T.hi.x + reach - g.lo.x) / h)) + 1);
    const int j0 = std::max(0, static_cast<int>(std::floor((T.lo.y - reach - g.lo.y) / h)) - 1), j1 = std::min(g.ny - 1, static_cast<int>(std::floor((T.hi.y + reach - g.lo.y) / h)) + 1);
    const int k0 = std::max(0, static_cast<int>(std::floor((T.lo.z - reach - g.lo.z) / h)) - 1), k1 = std::min(g.nz - 1, static_cast<int>(std::floor((T.hi.z + reach - g.lo.z) / h)) + 1);
    for (int k = k0; k <= k1; ++k)
      for (int j = j0; j <= j1; ++j)
        for (int i = i0; i <= i1; ++i) {
          if (!M(i, j, k)) continue;
          for (int a = 0; a < 6; ++a) {
            if (M(i + ax[a][0], j + ax[a][1], k + ax[a][2])) continue;
            const Vec3 c0 = g.centre(i, j, k);
            const Vec3 fc{c0.x + 0.5 * h * ax[a][0], c0.y + 0.5 * h * ax[a][1], c0.z + 0.5 * h * ax[a][2]};
            // facing out on the same side as the part's face (any angle short of 90 degrees: a chamfer or a curve is
            // found; the side faces of the last voxel layer, square to the face, are not)
            if (T.n.x * ax[a][0] + T.n.y * ax[a][1] + T.n.z * ax[a][2] <= 0.0) continue;
            if (tri_dist(fc, T.a, T.b, T.c) <= reach) seen.push_back({i, j, k, a});
          }
        }
  }
  std::sort(seen.begin(), seen.end());
  seen.erase(std::unique(seen.begin(), seen.end()), seen.end());
  out.faces = std::move(seen);
  // the face's area with no material within one voxel
  for (const Tri& T : tris) {
    const Vec3 u{T.b.x - T.a.x, T.b.y - T.a.y, T.b.z - T.a.z}, w{T.c.x - T.a.x, T.c.y - T.a.y, T.c.z - T.a.z};
    const Vec3 cr{u.y * w.z - u.z * w.y, u.z * w.x - u.x * w.z, u.x * w.y - u.y * w.x};
    const double area = 0.5 * std::sqrt(cr.x * cr.x + cr.y * cr.y + cr.z * cr.z);
    if (!(area > 0.0)) continue;
    const double L = std::max({std::sqrt(u.x * u.x + u.y * u.y + u.z * u.z), std::sqrt(w.x * w.x + w.y * w.y + w.z * w.z),
                               std::hypot(std::hypot(T.c.x - T.b.x, T.c.y - T.b.y), T.c.z - T.b.z)});
    const int n = std::max(1, static_cast<int>(std::ceil(L / h)));
    const double da = area / static_cast<double>(n * n);
    for (int p = 0; p < n; ++p)
      for (int q = 0; q < n - p; ++q)
        for (int up = 0; up < (p + q < n - 1 ? 2 : 1); ++up) {
          // the centroid of sub-triangle (p, q), upright or inverted
          const double s0 = up == 0 ? (p + 1.0 / 3.0) / n : (p + 2.0 / 3.0) / n, t0 = up == 0 ? (q + 1.0 / 3.0) / n : (q + 2.0 / 3.0) / n;
          const Vec3 x{T.a.x + s0 * u.x + t0 * w.x, T.a.y + s0 * u.y + t0 * w.y, T.a.z + s0 * u.z + t0 * w.z};
          out.area_mm2 += da;
          const int ci = static_cast<int>(std::floor((x.x - g.lo.x) / h)), cj = static_cast<int>(std::floor((x.y - g.lo.y) / h)),
                    ck = static_cast<int>(std::floor((x.z - g.lo.z) / h));
          bool covered = false;
          for (int dk = -2; dk <= 2 && !covered; ++dk)
            for (int dj = -2; dj <= 2 && !covered; ++dj)
              for (int di = -2; di <= 2 && !covered; ++di) {
                if (!M(ci + di, cj + dj, ck + dk)) continue;
                const Vec3 c = g.centre(ci + di, cj + dj, ck + dk);
                covered = std::hypot(std::hypot(c.x - x.x, c.y - x.y), c.z - x.z) <= 1.5 * h;
              }
          if (!covered) out.empty_mm2 += da;
        }
  }
  return out;
}

// The four nodes of voxel (i, j, k)'s face on axis a.
std::array<int, 4> face_nodes(const VoxelGrid& vg, int i, int j, int k, int a) {
  const int s = a % 2;   // 0 low side, 1 high side
  if (a < 2) {
    const int x = i + s;
    return {fea_node_index(vg, x, j, k), fea_node_index(vg, x, j + 1, k), fea_node_index(vg, x, j + 1, k + 1), fea_node_index(vg, x, j, k + 1)};
  }
  if (a < 4) {
    const int y = j + s;
    return {fea_node_index(vg, i, y, k), fea_node_index(vg, i + 1, y, k), fea_node_index(vg, i + 1, y, k + 1), fea_node_index(vg, i, y, k + 1)};
  }
  const int z = k + s;
  return {fea_node_index(vg, i, j, z), fea_node_index(vg, i + 1, j, z), fea_node_index(vg, i + 1, j + 1, z), fea_node_index(vg, i, j + 1, z)};
}

std::string num(double v) {
  char b[40];
  std::snprintf(b, sizeof b, "%.9g", v);
  return b;
}
std::string jstr(const std::string& t) {
  std::string o = "\"";
  for (const char c : t) {
    if (c == '"' || c == '\\') { o += '\\'; o += c; }
    else if (c == '\n') o += "\\n";
    else if (static_cast<unsigned char>(c) < 0x20) o += ' ';
    else o += c;
  }
  return o + "\"";
}
// Positions and directions are written in the model frame (the ask's print frame turned back; off: as they are).
Vec3 model_point(const PrintFrame& f, const Vec3& p) { return f.on ? f.point_to_model(p) : p; }
Vec3 model_dir(const PrintFrame& f, const Vec3& d) { return f.on ? f.dir_to_model(d) : d; }
std::string vec_json(const Vec3& v) { return "[" + num(v.x) + ", " + num(v.y) + ", " + num(v.z) + "]"; }
std::string point_json(const BreakPoint& p, const PrintFrame& f) {
  if (!p.found) return "null";
  const Vec3 at = model_point(f, p.at);
  return "{\"multiple\": " + num(p.multiple) + ", \"at\": [" + num(at.x) + ", " + num(at.y) + ", " + num(at.z) + "], \"class\": \"" +
         p.cls + "\"" + (p.post >= 0 ? ", \"post\": " + std::to_string(p.post) : std::string()) + ", \"thickness_voxels\": " +
         num(p.thickness_voxels) + ", \"resolved\": " + (p.resolved ? "true" : "false") + ", \"by\": \"" + p.by + "\"}";
}

// The limit law on a stress state's principal values (ascending) and directions (rows): the multiple, and whether
// tension governs.
// Review 1.1: EVERY principal stress is judged against the limit for its own direction and sign, the smallest multiple
// kept: a tension by the released rod law's interpolation (frame_check.cpp:800, lim_t = level (1 - rise^2) + across
// rise^2, level = the yield, across = the yield x z_knockdown, run_job.cpp:13416-13417), a compression by the yield
// (frame_check.cpp:802).
double law_of(const double val[3], const double vec[9], double yield_mpa, double z_knockdown, const Vec3& up, bool* tension) {
  double m = std::numeric_limits<double>::infinity();
  bool ten = true;
  const double ul = std::sqrt(up.x * up.x + up.y * up.y + up.z * up.z);
  for (int i = 0; i < 3; ++i) {
    if (val[i] > 0.0) {
      const double rise = ul > 0.0 ? std::min(1.0, std::fabs(vec[3 * i] * up.x + vec[3 * i + 1] * up.y + vec[3 * i + 2] * up.z) / ul) : 0.0;
      const double lim = yield_mpa * (1.0 - rise * rise) + yield_mpa * z_knockdown * rise * rise;
      if (lim / val[i] < m) { m = lim / val[i]; ten = true; }
    } else if (val[i] < 0.0 && yield_mpa / -val[i] < m) {
      m = yield_mpa / -val[i];
      ten = false;
    }
  }
  if (tension) *tension = ten;
  return m;
}

}  // namespace

double break_multiple(const double s[6], double yield_mpa, double z_knockdown, const Vec3& up, std::string* by) {
  const double a[9] = {s[0], s[3], s[5], s[3], s[1], s[4], s[5], s[4], s[2]};
  double val[3], vec[9];
  symmetric_eigen3(a, val, vec);   // ascending; vectors as rows
  bool ten = true;
  const double m = law_of(val, vec, yield_mpa, z_knockdown, up, &ten);
  if (by) *by = ten ? "tension" : "compression";
  return m;
}

double break_member_thickness(const std::vector<char>& mat, int nx, int ny, int nz, int pi, int pj, int pk, int reach) {
  auto at = [&](int i, int j, int k) {
    return i >= 0 && j >= 0 && k >= 0 && i < nx && j < ny && k < nz &&
           mat[(static_cast<std::size_t>(k) * static_cast<std::size_t>(ny) + static_cast<std::size_t>(j)) * static_cast<std::size_t>(nx) + static_cast<std::size_t>(i)];
  };
  double best = 0.0;
  for (int ck = pk - reach; ck <= pk + reach; ++ck)
    for (int cj = pj - reach; cj <= pj + reach; ++cj)
      for (int ci = pi - reach; ci <= pi + reach; ++ci) {
        if (!at(ci, cj, ck)) continue;
        const double dp = std::sqrt(static_cast<double>((ci - pi) * (ci - pi) + (cj - pj) * (cj - pj) + (ck - pk) * (ck - pk)));
        double d = 1e300;
        const int T = reach + 2;
        for (int qk = ck - T; qk <= ck + T; ++qk)
          for (int qj = cj - T; qj <= cj + T; ++qj)
            for (int qi = ci - T; qi <= ci + T; ++qi)
              if (!at(qi, qj, qk))
                d = std::min(d, std::sqrt(static_cast<double>((qi - ci) * (qi - ci) + (qj - cj) * (qj - cj) + (qk - ck) * (qk - ck))));
        const double dt = d - 0.5;
        if (dp <= dt + 1e-9) best = std::max(best, 2.0 * dt);
      }
  return best;
}

double break_memory_limit_bytes() {
  const long pages = sysconf(_SC_PHYS_PAGES), page = sysconf(_SC_PAGESIZE);
  if (pages <= 0 || page <= 0) return 0.0;
  return 0.40 * static_cast<double>(pages) * static_cast<double>(page);
}

BreakSize organic_break_size(const BreakAsk& ask) {
  const Grid g = grid_of(ask);
  BreakSize s;
  s.nx = g.nx;
  s.ny = g.ny;
  s.nz = g.nz;
  s.box_voxels = static_cast<std::size_t>(g.nx) * static_cast<std::size_t>(g.ny) * static_cast<std::size_t>(g.nz);
  s.limit_bytes = ask.memory_limit_bytes > 0.0 ? ask.memory_limit_bytes : break_memory_limit_bytes();
  // review 1.9: the solver's node numbers are ints (3 per node): a grid past that range is too big, never an overflow
  const double nodes = static_cast<double>(g.nx + 1) * static_cast<double>(g.ny + 1) * static_cast<double>(g.nz + 1);
  if (nodes * 3.0 > static_cast<double>(std::numeric_limits<int>::max())) {
    s.bytes = std::numeric_limits<double>::infinity();
    return s;
  }
  // the box alone over the guard: no count (a part that cannot fit is turned away at once)
  if (static_cast<double>(s.box_voxels) * kBytesPerBoxVoxel > s.limit_bytes) {
    s.bytes = static_cast<double>(s.box_voxels) * kBytesPerBoxVoxel;
    return s;
  }
  s.material_voxels = count_material(ask, g);
  s.bytes = static_cast<double>(s.material_voxels) * kBytesPerMaterialVoxel + static_cast<double>(s.box_voxels) * kBytesPerBoxVoxel;
  return s;
}

std::vector<char> break_judged(const std::vector<char>& mat, int nx, int ny, int nz, int min_voxels_across) {
  const auto idx = [&](int i, int j, int k) {
    return (static_cast<std::size_t>(k) * static_cast<std::size_t>(ny) + static_cast<std::size_t>(j)) * static_cast<std::size_t>(nx) + static_cast<std::size_t>(i);
  };
  auto M = [&](int i, int j, int k) { return i >= 0 && j >= 0 && k >= 0 && i < nx && j < ny && k < nz && mat[idx(i, j, k)]; };
  // some material voxel within `min_voxels_across` voxels whose inscribed ball (radius DT, at least min/2 voxels) holds
  // the point; DT read within that reach (enough to decide)
  const int W = std::max(1, min_voxels_across);
  const double need = 0.5 * static_cast<double>(min_voxels_across);
  std::vector<char> res(mat.size(), 0);
  std::vector<float> dt(mat.size(), 0.0f);
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        if (!M(i, j, k)) continue;
        double d = W + 1.0;
        for (int dk = -W; dk <= W; ++dk)
          for (int dj = -W; dj <= W; ++dj)
            for (int di = -W; di <= W; ++di)
              if (!M(i + di, j + dj, k + dk)) d = std::min(d, std::sqrt(static_cast<double>(di * di + dj * dj + dk * dk)));
        dt[idx(i, j, k)] = static_cast<float>(d - 0.5);
      }
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        if (!M(i, j, k)) continue;
        bool thick = false;
        for (int dk = -W; dk <= W && !thick; ++dk)
          for (int dj = -W; dj <= W && !thick; ++dj)
            for (int di = -W; di <= W && !thick; ++di) {
              if (!M(i + di, j + dj, k + dk)) continue;
              const double c2 = dt[idx(i + di, j + dj, k + dk)];
              thick = c2 >= need - 1e-9 && std::sqrt(static_cast<double>(di * di + dj * dj + dk * dk)) <= c2 + 1e-9;
            }
        res[idx(i, j, k)] = thick;
      }
  return res;
}

BreakResult organic_break_check(const BreakAsk& ask) {
  BreakResult R;
  const auto t0 = std::chrono::steady_clock::now();
  const auto say = [&](const char* line) { if (ask.said) ask.said(line); };
  const auto stopped = [&] { return ask.stop && ask.stop->load(); };
  // Not checked: the block says why and with what numbers; never a multiple, never a pass.
  const auto not_checked = [&](const std::string& code, const std::string& why) -> BreakResult {
    R.ok = false;
    R.not_checked = code;
    R.why = why;
    R.verdict = "not_checked";
    R.seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    R.peak_mb = process_memory().peak_rss_mb;
    R.json = "{\"verdict\": \"not_checked\", \"reason\": " + jstr(code) + ", \"why\": " + jstr(why) + ", \"pass_line\": " + num(ask.pass_line) +
             ", \"grid\": {\"voxel_mm\": " + num(ask.voxel_mm) + ", \"nx\": " + std::to_string(R.size.nx) + ", \"ny\": " + std::to_string(R.size.ny) +
             ", \"nz\": " + std::to_string(R.size.nz) + ", \"material_voxels\": " + std::to_string(R.size.material_voxels) +
             ", \"bytes_needed\": " + num(R.size.bytes) + ", \"bytes_allowed\": " + num(R.size.limit_bytes) + "}, \"solve\": {\"rounds\": " +
             std::to_string(R.rounds) + ", \"converged\": " + (R.converged ? "true" : "false") + ", \"tolerance\": " + num(ask.tolerance) +
             ", \"seconds\": " + num(R.seconds) + ", \"peak_mb\": " + num(R.peak_mb) + "}}";
    return R;
  };
  if (!ask.print || ask.print->vertices.empty() || ask.print->triangles.empty() || !ask.part || !(ask.yield_mpa > 0.0) ||
      !(ask.youngs_mpa > 0.0) || !(ask.poisson > -1.0 && ask.poisson < 0.5) || !(ask.z_knockdown > 0.0) || !(ask.voxel_mm > 0.0) ||
      !(ask.smooth_mm >= 0.0) || ask.min_voxels_across < 1 ||
      !(std::sqrt(ask.up.x * ask.up.x + ask.up.y * ask.up.y + ask.up.z * ask.up.z) > 0.0))
    return not_checked("error", "the check was asked with no print, no part, no material or no build direction");
  if (ask.fixed_faces.empty()) return not_checked("no_load", "the strength job holds the part by no face the check can read");
  if (ask.loads.empty()) return not_checked("no_load", "the strength job has no force on a face the check can read");
  try {
  // 0. the size guard, before any large allocation
  say("checking its strength: reading the print");
  R.size = organic_break_size(ask);
  if (!(R.size.limit_bytes > 0.0)) return not_checked("error", "the Mac's memory could not be read, so the check's size could not be judged");
  if (R.size.bytes > R.size.limit_bytes) {
    char b[200];
    if (std::isfinite(R.size.bytes))
      std::snprintf(b, sizeof b, "the check would need about %.1f GB and may use %.1f GB (40 %% of this machine's memory)", R.size.bytes / 1e9,
                    R.size.limit_bytes / 1e9);
    else
      std::snprintf(b, sizeof b, "the part's grid is past the solver's range (%d x %d x %d voxels)", R.size.nx, R.size.ny, R.size.nz);
    return not_checked("too_big", b);
  }
  if (stopped()) return not_checked("stopped", "the job was stopped before the check");
  const Grid g = grid_of(ask);
  const double h = g.h;
  const std::vector<char> mat = material_of(ask, g);
  R.size.nx = g.nx;
  R.size.ny = g.ny;
  R.size.nz = g.nz;
  R.size.box_voxels = mat.size();
  R.size.material_voxels = 0;
  for (char c : mat) R.size.material_voxels += c != 0;
  R.size.bytes = static_cast<double>(R.size.material_voxels) * kBytesPerMaterialVoxel + static_cast<double>(R.size.box_voxels) * kBytesPerBoxVoxel;
  auto M = [&](int i, int j, int k) { return i >= 0 && j >= 0 && k >= 0 && i < g.nx && j < g.ny && k < g.nz && mat[g.index(i, j, k)]; };
  // 1. the grid for the solve: material only
  VoxelGrid vg;
  vg.nx = g.nx;
  vg.ny = g.ny;
  vg.nz = g.nz;
  vg.spacing = h;
  vg.origin = g.lo;
  vg.tags.assign(mat.size(), VoxelTag::Empty);
  for (std::size_t e = 0; e < mat.size(); ++e) if (mat[e]) vg.tags[e] = VoxelTag::Interior;
  const std::vector<double> E(mat.size(), ask.youngs_mpa);
  // 2. the part's fixed and loaded faces on this grid. A face with over 5 % of its area out of reach of the print's
  // material is a load or a hold on empty space: not checked, the face named (review 1.2).
  std::string faces_json;
  std::vector<char> held(static_cast<std::size_t>(fea_node_count(vg)), 0);
  const auto pick = [&](int face, const char* role) -> std::pair<FacePick, std::string> {
    FacePick fp = faces_on(ask, g, mat, face);
    const double share = fp.area_mm2 > 0.0 ? fp.empty_mm2 / fp.area_mm2 : 1.0;
    faces_json += std::string(faces_json.empty() ? "" : ", ") + "{\"face\": " + std::to_string(face) + ", \"role\": \"" + role +
                  "\", \"area_mm2\": " + num(fp.area_mm2) + ", \"empty_share\": " + num(share) + ", \"voxel_faces\": " +
                  std::to_string(fp.faces.size()) + "}";
    if (fp.area_mm2 <= 0.0 || fp.faces.empty() || share > 0.05) {
      char b[200];
      std::snprintf(b, sizeof b, "face %d (%s) has %.1f %% of its area with no printed material within one voxel", face, role, 100.0 * share);
      return {fp, b};
    }
    return {fp, std::string()};
  };
  std::vector<DirichletBC> bcs;
  for (int face : ask.fixed_faces) {
    const auto [fp, bad] = pick(face, "fixed");
    if (!bad.empty()) return not_checked("load_on_empty_space", bad);
    for (const auto& f : fp.faces)
      for (int n : face_nodes(vg, f[0], f[1], f[2], f[3])) {
        if (held[static_cast<std::size_t>(n)]) continue;
        held[static_cast<std::size_t>(n)] = 1;
        for (int q = 0; q < 3; ++q) bcs.push_back({n, q, 0.0});
      }
  }
  if (bcs.empty()) return not_checked("no_load", "the faces that hold the part meet no material of the print");
  // Each load is spread over its faces' corner nodes that are NOT held (a held node's share would go into the
  // reaction, review 1.3), the shares renormalised so the whole force is applied.
  std::map<int, std::array<double, 3>> nodal;
  Vec3 asked{0.0, 0.0, 0.0};
  for (const BreakLoad& L : ask.loads) {
    asked = {asked.x + L.force.x, asked.y + L.force.y, asked.z + L.force.z};
    std::map<int, double> wgt;
    for (int face : L.faces) {
      const auto [fp, bad] = pick(face, "loaded");
      if (!bad.empty()) return not_checked("load_on_empty_space", bad);
      for (const auto& f : fp.faces)
        for (int n : face_nodes(vg, f[0], f[1], f[2], f[3]))
          if (!held[static_cast<std::size_t>(n)]) wgt[n] += 0.25;
    }
    double tw = 0.0;
    for (const auto& [n, w] : wgt) tw += w;
    if (!(tw > 0.0)) return not_checked("no_load", "a load's faces meet no printed material that is not also held");
    for (const auto& [n, w] : wgt) {
      auto& v = nodal[n];
      v[0] += L.force.x * w / tw;
      v[1] += L.force.y * w / tw;
      v[2] += L.force.z * w / tw;
    }
  }
  std::vector<NodalLoad> loads;
  Vec3 applied{0.0, 0.0, 0.0};
  for (const auto& [n, v] : nodal) {
    applied = {applied.x + v[0], applied.y + v[1], applied.z + v[2]};
    for (int q = 0; q < 3; ++q)
      if (v[static_cast<std::size_t>(q)] != 0.0) loads.push_back({n, q, v[static_cast<std::size_t>(q)]});
  }
  const double asked_n = std::sqrt(asked.x * asked.x + asked.y * asked.y + asked.z * asked.z);
  const double off_n = std::sqrt((applied.x - asked.x) * (applied.x - asked.x) + (applied.y - asked.y) * (applied.y - asked.y) +
                                 (applied.z - asked.z) * (applied.z - asked.z));
  if (!(off_n <= 1e-9 * std::max(asked_n, 1e-300))) return not_checked("error", "the applied force is not the asked force");
  // 3. one solve at the working load (the solver takes no stop and gives no rounds while it runs)
  if (stopped()) return not_checked("stopped", "the job was stopped before the solve");
  say("checking its strength: solving");
  CgInfo info;
  FeaSolution u;
  try {
    u = fea_solve_mgcg_matfree(vg, E, ask.poisson, bcs, loads, ask.tolerance, ask.max_rounds, &info);
  } catch (const std::exception& ex) {
    R.rounds = info.iterations;
    return not_checked("did_not_settle", std::string("the solve did not settle: ") + ex.what());
  }
  R.rounds = info.iterations;
  R.converged = info.converged;
  if (!info.converged) return not_checked("did_not_settle", "the solve did not settle within its rounds");
  {
    char b[120];
    std::snprintf(b, sizeof b, "checking its strength: solved in %d rounds", R.rounds);
    say(b);
  }
  if (stopped()) return not_checked("stopped", "the job was stopped after the solve");
  say("checking its strength: reading the stresses");
  // 4. stresses
  std::vector<std::array<float, 6>> sig(mat.size(), std::array<float, 6>{});
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        if (!M(i, j, k)) continue;
        const std::array<int, 8> nd = fea_element_nodes(vg, i, j, k);
        std::array<double, 24> ue{};
        for (int q = 0; q < 8; ++q)
          for (int d = 0; d < 3; ++d) ue[static_cast<std::size_t>(3 * q + d)] = u.at(nd[static_cast<std::size_t>(q)], d);
        const Hex8Stress st = hex8_stress(ask.youngs_mpa, ask.poisson, h, ue);
        for (int q = 0; q < 6; ++q) sig[g.index(i, j, k)][static_cast<std::size_t>(q)] = static_cast<float>(st.sigma[static_cast<std::size_t>(q)]);
      }
  // 5. classes: posts (the laid square, clipped to the print's box, between its ends), vines (within half a width plus a
  // voxel of a kept bar's axis), solid within near_post_mm of a post's end, the rest of the solid
  const std::size_t np = ask.posts.size();
  Vec3 bmn{g.lo.x, g.lo.y, g.lo.z}, bmx{g.lo.x + g.nx * h, g.lo.y + g.ny * h, g.lo.z + g.nz * h};
  {
    Vec3 mn{1e300, 1e300, 1e300}, mx{-1e300, -1e300, -1e300};
    for (const Vec3& v : ask.print->vertices) {
      mn = {std::min(mn.x, v.x), std::min(mn.y, v.y), std::min(mn.z, v.z)};
      mx = {std::max(mx.x, v.x), std::max(mx.y, v.y), std::max(mx.z, v.z)};
    }
    bmn = mn;
    bmx = mx;
  }
  std::vector<std::array<double, 4>> pbox(np);
  for (std::size_t q = 0; q < np; ++q) {
    const BreakPost& p = ask.posts[q];
    pbox[q] = {std::max(bmn.x, p.x - 0.5 * p.width), std::min(bmx.x, p.x + 0.5 * p.width), std::max(bmn.y, p.y - 0.5 * p.width),
               std::min(bmx.y, p.y + 0.5 * p.width)};
  }
  std::vector<int> cls(mat.size(), -1);   // 0..np-1 posts, np vines, np+1 solid near a post, np+2 the rest
  {
    std::vector<char> vine(mat.size(), 0);
    for (const BreakBar& b : ask.bars) {
      const double r = 0.5 * b.width + h;
      const int i0 = std::max(0, static_cast<int>(std::floor((std::min(b.a.x, b.b.x) - r - g.lo.x) / h)));
      const int i1 = std::min(g.nx - 1, static_cast<int>(std::floor((std::max(b.a.x, b.b.x) + r - g.lo.x) / h)));
      const int j0 = std::max(0, static_cast<int>(std::floor((std::min(b.a.y, b.b.y) - r - g.lo.y) / h)));
      const int j1 = std::min(g.ny - 1, static_cast<int>(std::floor((std::max(b.a.y, b.b.y) + r - g.lo.y) / h)));
      const int k0 = std::max(0, static_cast<int>(std::floor((std::min(b.a.z, b.b.z) - r - g.lo.z) / h)));
      const int k1 = std::min(g.nz - 1, static_cast<int>(std::floor((std::max(b.a.z, b.b.z) + r - g.lo.z) / h)));
      for (int k = k0; k <= k1; ++k)
        for (int j = j0; j <= j1; ++j)
          for (int i = i0; i <= i1; ++i)
            if (M(i, j, k) && seg_dist(g.centre(i, j, k), b.a, b.b) <= r) vine[g.index(i, j, k)] = 1;
    }
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) {
          if (!M(i, j, k)) continue;
          const Vec3 c = g.centre(i, j, k);
          int c2 = -1;
          for (std::size_t q = 0; q < np && c2 < 0; ++q)
            if (c.x >= pbox[q][0] && c.x <= pbox[q][1] && c.y >= pbox[q][2] && c.y <= pbox[q][3] && c.z >= ask.posts[q].z_bottom &&
                c.z <= ask.posts[q].z_top)
              c2 = static_cast<int>(q);
          if (c2 < 0 && vine[g.index(i, j, k)]) c2 = static_cast<int>(np);
          if (c2 < 0) {
            c2 = static_cast<int>(np) + 2;
            for (std::size_t q = 0; q < np; ++q) {
              const double dx = std::max({pbox[q][0] - c.x, 0.0, c.x - pbox[q][1]}), dy = std::max({pbox[q][2] - c.y, 0.0, c.y - pbox[q][3]});
              const double dz = std::min(std::fabs(c.z - ask.posts[q].z_bottom), std::fabs(c.z - ask.posts[q].z_top));
              if (std::hypot(dx, dy) <= ask.near_post_mm && dz <= ask.near_post_mm) c2 = static_cast<int>(np) + 1;
            }
          }
          cls[g.index(i, j, k)] = c2;
        }
  }
  // 6. judged (resolved): break_judged (the gate the verdict reads)
  const std::vector<char> res = break_judged(mat, g.nx, g.ny, g.nz, ask.min_voxels_across);
  // 7. the smoothed multiple per material voxel
  std::vector<std::array<int, 3>> ball;
  const int RB = static_cast<int>(std::ceil(ask.smooth_mm / h)) + 1;
  for (int dk = -RB; dk <= RB; ++dk)
    for (int dj = -RB; dj <= RB; ++dj)
      for (int di = -RB; di <= RB; ++di)
        if (std::sqrt(static_cast<double>(di * di + dj * dj + dk * dk)) * h <= ask.smooth_mm + 1e-9) ball.push_back({di, dj, dk});
  std::vector<float> mult(mat.size(), std::numeric_limits<float>::infinity());
  std::vector<char> tens(mat.size(), 0);
  const std::size_t nu = ask.other_ups.size();
  std::vector<double> upJ(nu, std::numeric_limits<double>::infinity()), upA(nu, std::numeric_limits<double>::infinity());
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        if (!M(i, j, k)) continue;
        double s6[6] = {0, 0, 0, 0, 0, 0};
        int n = 0;
        for (const auto& o : ball) {
          if (!M(i + o[0], j + o[1], k + o[2])) continue;
          const auto& v = sig[g.index(i + o[0], j + o[1], k + o[2])];
          for (int q = 0; q < 6; ++q) s6[q] += v[static_cast<std::size_t>(q)];
          ++n;
        }
        for (double& x : s6) x /= n;
        const double a9[9] = {s6[0], s6[3], s6[5], s6[3], s6[1], s6[4], s6[5], s6[4], s6[2]};
        double val[3], vec[9];
        symmetric_eigen3(a9, val, vec);
        bool ten = true;
        const double m = law_of(val, vec, ask.yield_mpa, ask.z_knockdown, ask.up, &ten);
        mult[g.index(i, j, k)] = static_cast<float>(m);
        tens[g.index(i, j, k)] = ten;
        for (std::size_t q = 0; q < nu; ++q) {   // P4: the same stresses against another up (rounded as `mult` is)
          const double mq = static_cast<float>(law_of(val, vec, ask.yield_mpa, ask.z_knockdown, ask.other_ups[q], nullptr));
          upA[q] = std::min(upA[q], mq);
          if (res[g.index(i, j, k)]) upJ[q] = std::min(upJ[q], mq);
        }
      }
  if (ask.also_connected_ball) {   // the review's question 1.6, a reading for the record
    const int D = 2 * RB + 1;
    std::vector<int> slot(static_cast<std::size_t>(D) * D * D, -1);
    for (std::size_t q = 0; q < ball.size(); ++q)
      slot[(static_cast<std::size_t>(ball[q][2] + RB) * D + static_cast<std::size_t>(ball[q][1] + RB)) * D + static_cast<std::size_t>(ball[q][0] + RB)] = static_cast<int>(q);
    std::vector<int> seen(ball.size(), -1), queue;
    double cj = std::numeric_limits<double>::infinity(), ca = cj;
    std::size_t ej = 0, ea = 0;
    const int nb[6][3] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}};
    int stamp = 0;
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) {
          if (!M(i, j, k)) continue;
          ++stamp;
          queue.clear();
          const int c0 = slot[(static_cast<std::size_t>(RB) * D + RB) * D + RB];
          seen[static_cast<std::size_t>(c0)] = stamp;
          queue.push_back(c0);
          double s6[6] = {0, 0, 0, 0, 0, 0};
          for (std::size_t qi = 0; qi < queue.size(); ++qi) {
            const auto& o = ball[static_cast<std::size_t>(queue[qi])];
            const auto& v = sig[g.index(i + o[0], j + o[1], k + o[2])];
            for (int q = 0; q < 6; ++q) s6[q] += v[static_cast<std::size_t>(q)];
            for (const auto& d : nb) {
              const int x = o[0] + d[0], y = o[1] + d[1], z = o[2] + d[2];
              if (std::abs(x) > RB || std::abs(y) > RB || std::abs(z) > RB) continue;
              const int sl = slot[(static_cast<std::size_t>(z + RB) * D + static_cast<std::size_t>(y + RB)) * D + static_cast<std::size_t>(x + RB)];
              if (sl < 0 || seen[static_cast<std::size_t>(sl)] == stamp || !M(i + x, j + y, k + z)) continue;
              seen[static_cast<std::size_t>(sl)] = stamp;
              queue.push_back(sl);
            }
          }
          int n = 0;
          for (const auto& o : ball) n += M(i + o[0], j + o[1], k + o[2]);
          if (static_cast<int>(queue.size()) < n) ++R.connected_split_voxels;
          for (double& x : s6) x /= static_cast<double>(queue.size());
          const double m = static_cast<float>(break_multiple(s6, ask.yield_mpa, ask.z_knockdown, ask.up, nullptr));
          const std::size_t e = g.index(i, j, k);
          if (m < ca) { ca = m; ea = e; }
          if (res[e] && m < cj) { cj = m; ej = e; }
        }
    const auto at_of = [&](std::size_t e) {
      return g.centre(static_cast<int>(e % static_cast<std::size_t>(g.nx)), static_cast<int>((e / static_cast<std::size_t>(g.nx)) % static_cast<std::size_t>(g.ny)),
                      static_cast<int>(e / (static_cast<std::size_t>(g.nx) * static_cast<std::size_t>(g.ny))));
    };
    if (std::isfinite(cj)) { R.connected_judged.found = true; R.connected_judged.multiple = cj; R.connected_judged.at = at_of(ej); }
    if (std::isfinite(ca)) { R.connected_all.found = true; R.connected_all.multiple = ca; R.connected_all.at = at_of(ea); }
  }
  auto point = [&](std::size_t e) {
    BreakPoint p;
    p.found = true;
    p.multiple = mult[e];
    const int i = static_cast<int>(e % static_cast<std::size_t>(g.nx)), j = static_cast<int>((e / static_cast<std::size_t>(g.nx)) % static_cast<std::size_t>(g.ny)),
              k = static_cast<int>(e / (static_cast<std::size_t>(g.nx) * static_cast<std::size_t>(g.ny)));
    p.at = g.centre(i, j, k);
    const int c = cls[e];
    p.cls = c < static_cast<int>(np) ? "post" : c == static_cast<int>(np) ? "vine" : c == static_cast<int>(np) + 1 ? "solid_near_post" : "solid";
    p.post = c < static_cast<int>(np) ? c : -1;
    p.thickness_voxels = break_member_thickness(mat, g.nx, g.ny, g.nz, i, j, k);
    p.resolved = res[e] != 0;
    p.by = tens[e] ? "tension" : "compression";
    return p;
  };
  // 8. per class, first breaks, the post sections, places too thin to judge under the pass line
  std::vector<double> cm(np + 3, std::numeric_limits<double>::infinity()), cmr(np + 3, std::numeric_limits<double>::infinity());
  std::vector<std::size_t> cw(np + 3, 0), cwr(np + 3, 0);
  for (std::size_t e = 0; e < mat.size(); ++e) {
    if (!mat[e] || cls[e] < 0) continue;
    const std::size_t c = static_cast<std::size_t>(cls[e]);
    if (mult[e] < cm[c]) { cm[c] = mult[e]; cw[c] = e; }
    if (res[e] && mult[e] < cmr[c]) { cmr[c] = mult[e]; cwr[c] = e; }
  }
  double fa = std::numeric_limits<double>::infinity(), fr = fa;
  for (std::size_t c = 0; c < np + 3; ++c) {
    BreakClass bc;
    bc.cls = c < np ? "post" : c == np ? "vine" : c == np + 1 ? "solid_near_post" : "solid";
    bc.post = c < np ? static_cast<int>(c) : -1;
    if (std::isfinite(cm[c])) bc.all = point(cw[c]);
    if (std::isfinite(cmr[c])) bc.resolved = point(cwr[c]);
    if (c < np) {   // the force across the post's mid-height over its file section (the laid square clipped to the box)
      const BreakPost& p = ask.posts[c];
      const double zm = 0.5 * (p.z_bottom + p.z_top);
      const int km = std::max(0, std::min(g.nz - 1, static_cast<int>(std::floor((zm - g.lo.z) / h))));
      double f = 0.0;
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) {
          const Vec3 cc = g.centre(i, j, km);
          if (!M(i, j, km) || cc.x < pbox[c][0] - 0.5 * h || cc.x > pbox[c][1] + 0.5 * h || cc.y < pbox[c][2] - 0.5 * h || cc.y > pbox[c][3] + 0.5 * h) continue;
          // the force along the post's axis (the build direction)
          const auto& s = sig[g.index(i, j, km)];
          const Vec3& U = ask.up;
          const double ul = std::sqrt(U.x * U.x + U.y * U.y + U.z * U.z);
          const Vec3 n{U.x / ul, U.y / ul, U.z / ul};
          const double sn = s[0] * n.x * n.x + s[1] * n.y * n.y + s[2] * n.z * n.z + 2.0 * (s[3] * n.x * n.y + s[4] * n.y * n.z + s[5] * n.z * n.x);
          f += sn * h * h;
        }
      bc.section_mm2 = (pbox[c][1] - pbox[c][0]) * (pbox[c][3] - pbox[c][2]);
      bc.section_force_n = f;
      if (bc.section_mm2 > 0.0 && f != 0.0) {
        const double st = f / bc.section_mm2;
        bc.section_multiple = st < 0.0 ? ask.yield_mpa / -st : ask.yield_mpa * ask.z_knockdown / st;
      }
    }
    if (bc.all.found && bc.all.multiple < fa) { fa = bc.all.multiple; R.first_all = bc.all; }
    if (bc.resolved.found && bc.resolved.multiple < fr) { fr = bc.resolved.multiple; R.first_resolved = bc.resolved; }
    R.classes.push_back(bc);
  }
  bool any_under = false;
  {   // places too thin to judge under the pass line: seeds in order of multiple, at least 2 mm apart
    std::vector<std::size_t> cand;
    for (std::size_t e = 0; e < mat.size(); ++e)
      if (mat[e] && !res[e] && mult[e] < ask.pass_line) cand.push_back(e);
    // review 2: a fixed order for equal multiples (by place: the voxel index)
    std::sort(cand.begin(), cand.end(), [&](std::size_t a, std::size_t b) { return mult[a] != mult[b] ? mult[a] < mult[b] : a < b; });
    any_under = !cand.empty();   // review 1.4: the verdict reads the whole list; the cap only limits what is printed
    for (std::size_t e : cand) {
      if (R.not_judged_under.size() >= ask.places_listed) break;
      const BreakPoint p0 = [&] {
        BreakPoint p;
        const int i = static_cast<int>(e % static_cast<std::size_t>(g.nx)), j = static_cast<int>((e / static_cast<std::size_t>(g.nx)) % static_cast<std::size_t>(g.ny)),
                  k = static_cast<int>(e / (static_cast<std::size_t>(g.nx) * static_cast<std::size_t>(g.ny)));
        p.at = g.centre(i, j, k);
        return p;
      }();
      bool far = true;
      for (const BreakPoint& q : R.not_judged_under)
        far = far && std::hypot(std::hypot(q.at.x - p0.at.x, q.at.y - p0.at.y), q.at.z - p0.at.z) > 2.0;
      if (far) R.not_judged_under.push_back(point(e));
    }
  }
  // 9. the verdict
  // review 1.5: EVERY post whose file section reads under the pass line blocks a pass (whatever its weakest voxel)
  bool post_section_under = false;
  for (const BreakClass& bc : R.classes)
    if (bc.cls == "post" && bc.section_multiple > 0.0 && bc.section_multiple < ask.pass_line) post_section_under = true;
  if (!R.first_resolved.found) R.verdict = "not_proven";
  else if (R.first_resolved.multiple < ask.pass_line) R.verdict = "fail";
  else if (any_under || post_section_under) R.verdict = "not_proven";
  else R.verdict = "pass";
  for (std::size_t q = 0; q < nu; ++q) R.by_up.push_back({ask.other_ups[q], upJ[q], upA[q]});
  R.ok = true;
  R.seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  R.peak_mb = process_memory().peak_rss_mb;
  // 10. the JSON block
  const PrintFrame& F = ask.frame;
  std::string j = "{\"verdict\": \"" + R.verdict + "\", \"pass_line\": " + num(ask.pass_line) + ", \"first_break\": " + point_json(R.first_resolved, F) +
                  ", \"first_break_all_points\": " + point_json(R.first_all, F) + ", \"classes\": [";
  for (std::size_t q = 0; q < R.classes.size(); ++q) {
    const BreakClass& bc = R.classes[q];
    j += std::string(q ? ", " : "") + "{\"class\": \"" + bc.cls + "\"" + (bc.post >= 0 ? ", \"post\": " + std::to_string(bc.post) : std::string()) +
         ", \"all\": " + point_json(bc.all, F) + ", \"judged\": " + point_json(bc.resolved, F) +
         (bc.cls == "post" ? ", \"section_mm2\": " + num(bc.section_mm2) + ", \"section_force_n\": " + num(bc.section_force_n) +
                                 ", \"section_multiple\": " + num(bc.section_multiple)
                           : std::string()) +
         "}";
  }
  j += "], \"not_judged_under_pass_line\": [";
  for (std::size_t q = 0; q < R.not_judged_under.size(); ++q) j += std::string(q ? ", " : "") + point_json(R.not_judged_under[q], F);
  j += "]";
  if (nu > 0) {
    j += ", \"by_up\": [";
    for (std::size_t q = 0; q < nu; ++q) {
      const auto fin = [](double v) { return std::isfinite(v) ? num(v) : std::string("null"); };
      j += std::string(q ? ", " : "") + "{\"up\": " + vec_json(model_dir(F, R.by_up[q].up)) + ", \"first_break\": " + fin(R.by_up[q].judged) +
           ", \"first_break_all_points\": " + fin(R.by_up[q].all) + "}";
    }
    j += "]";
  }
  j += ", \"faces\": [" + faces_json + "], \"force_asked_n\": " + vec_json(model_dir(F, asked)) + ", \"force_applied_n\": " +
       vec_json(model_dir(F, applied));
  j += ", \"limit\": {\"yield_mpa\": " + num(ask.yield_mpa) + ", \"z_knockdown\": " + num(ask.z_knockdown) + ", \"up\": " + vec_json(model_dir(F, ask.up)) +
       "}, \"grid\": {\"voxel_mm\": " + num(h) + ", \"nx\": " + std::to_string(g.nx) + ", \"ny\": " +
       std::to_string(g.ny) + ", \"nz\": " + std::to_string(g.nz) + ", \"material_voxels\": " + std::to_string(R.size.material_voxels) +
       ", \"bytes_estimate\": " + num(R.size.bytes) + ", \"bytes_allowed\": " + num(R.size.limit_bytes) + ", \"smooth_mm\": " + num(ask.smooth_mm) + ", \"min_voxels_across\": " +
       std::to_string(ask.min_voxels_across) + "}, \"solve\": {\"rounds\": " + std::to_string(R.rounds) + ", \"converged\": " +
       (R.converged ? "true" : "false") + ", \"tolerance\": " + num(ask.tolerance) + ", \"seconds\": " + num(R.seconds) + ", \"peak_mb\": " +
       num(R.peak_mb) + "}}";
  R.json = j;
  return R;
  } catch (const std::exception& e) {
    return not_checked("error", std::string("the check stopped on an error: ") + e.what());
  }
}

}  // namespace topopt::lattice_layout
