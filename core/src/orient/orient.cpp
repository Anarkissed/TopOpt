// Orientation candidate generation + support-volume proxy metric (ROADMAP M4.3,
// ARCHITECTURE.md §3 orient/, §4/§9 M4 "orientation candidate generation
// (face-aligned + coarse sphere sampling)").
//
// This translation unit is pure C++/std (no Eigen, no OCCT), so it is part of the
// always-built library and its test runs in every configuration. It provides the
// geometry-only pieces of orientation handling; combining these into a score and
// the Gate V5 hook ranking is M4.4.

#include "topopt/orient.hpp"

#include <array>
#include <cmath>
#include <cstddef>
#include <stdexcept>
#include <vector>

#include "topopt/mesh.hpp"
#include "topopt/voxel.hpp"

namespace topopt {
namespace {

// --- small vector helpers (file-local; the public API stays plain Vec3) -----
double dot(const Vec3& a, const Vec3& b) {
  return a.x * b.x + a.y * b.y + a.z * b.z;
}

Vec3 cross(const Vec3& a, const Vec3& b) {
  return Vec3{a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z,
             a.x * b.y - a.y * b.x};
}

double length(const Vec3& a) { return std::sqrt(dot(a, a)); }

Vec3 normalized(const Vec3& a) {
  const double n = length(a);
  return Vec3{a.x / n, a.y / n, a.z / n};
}

// Two directions are "the same" for deduplication when within ~1.8 deg.
constexpr double kDedupeCos = 0.9995;
// Two triangle normals bin into the same flat face when within ~2.5 deg.
constexpr double kFaceBinCos = 0.999;

}  // namespace

std::vector<Vec3> flat_face_normals(const TriangleMesh& mesh,
                                    double area_fraction) {
  if (mesh.empty())
    throw std::invalid_argument("flat_face_normals: mesh has no triangles");
  if (!(area_fraction > 0.0) || area_fraction > 1.0)
    throw std::invalid_argument(
        "flat_face_normals: area_fraction must be in (0, 1]");

  // One group per distinct flat-face direction: accum is the area-weighted sum of
  // unit normals (so normalized(accum) is the representative direction) and area
  // is the accumulated facet area.
  struct Group {
    Vec3 accum;
    double area;
  };
  std::vector<Group> groups;
  double total_area = 0.0;

  for (const std::array<int, 3>& t : mesh.triangles) {
    const Vec3& v0 = mesh.vertices[static_cast<std::size_t>(t[0])];
    const Vec3& v1 = mesh.vertices[static_cast<std::size_t>(t[1])];
    const Vec3& v2 = mesh.vertices[static_cast<std::size_t>(t[2])];
    const Vec3 n = cross(Vec3{v1.x - v0.x, v1.y - v0.y, v1.z - v0.z},
                         Vec3{v2.x - v0.x, v2.y - v0.y, v2.z - v0.z});
    const double twice_area = length(n);
    if (twice_area <= 0.0) continue;  // degenerate facet: no defined normal
    const double area = 0.5 * twice_area;
    const Vec3 unit{n.x / twice_area, n.y / twice_area, n.z / twice_area};
    total_area += area;

    bool placed = false;
    for (Group& g : groups) {
      if (dot(unit, normalized(g.accum)) > kFaceBinCos) {
        g.accum.x += area * unit.x;
        g.accum.y += area * unit.y;
        g.accum.z += area * unit.z;
        g.area += area;
        placed = true;
        break;
      }
    }
    if (!placed) groups.push_back(Group{Vec3{area * unit.x, area * unit.y,
                                             area * unit.z},
                                        area});
  }

  std::vector<Vec3> out;
  if (total_area <= 0.0) return out;  // all facets degenerate: no flat faces
  const double threshold = area_fraction * total_area;
  for (const Group& g : groups)
    if (g.area >= threshold) out.push_back(normalized(g.accum));
  return out;
}

namespace {

// Append `d` (assumed unit) to `out` unless a near-parallel direction is already
// present (within ~1.8 deg).
void add_unique(std::vector<Vec3>& out, const Vec3& d) {
  for (const Vec3& e : out)
    if (dot(d, e) > kDedupeCos) return;
  out.push_back(d);
}

}  // namespace

std::vector<Vec3> orientation_candidates(const TriangleMesh& mesh) {
  // Validates the mesh (throws on empty) and gives the face-aligned directions.
  const std::vector<Vec3> faces = flat_face_normals(mesh);

  std::vector<Vec3> out;
  // Coarse sphere sampling: the 26 lattice directions {-1,0,1}^3 \ {0}. This set
  // already contains the 6 axis-aligned directions, so no separate step is needed
  // for them; they are the six single-nonzero-component members.
  for (int dk = -1; dk <= 1; ++dk)
    for (int dj = -1; dj <= 1; ++dj)
      for (int di = -1; di <= 1; ++di) {
        if (di == 0 && dj == 0 && dk == 0) continue;
        add_unique(out, normalized(Vec3{static_cast<double>(di),
                                        static_cast<double>(dj),
                                        static_cast<double>(dk)}));
      }

  // Face-normal-aligned candidates: each significant flat face, either way up.
  for (const Vec3& f : faces) {
    add_unique(out, f);
    add_unique(out, Vec3{-f.x, -f.y, -f.z});
  }
  return out;
}

int support_overhang_voxels(const VoxelGrid& grid, const Vec3& build_dir) {
  const double blen = length(build_dir);
  if (blen < 1e-12)
    throw std::invalid_argument(
        "support_overhang_voxels: build_dir is zero length");
  const Vec3 b{build_dir.x / blen, build_dir.y / blen, build_dir.z / blen};
  const Vec3 down{-b.x, -b.y, -b.z};

  // The 45-degree downward support cone: the subset of the 26 neighbour offsets
  // whose direction is within kOverhangAngleDeg of straight-down. A voxel is
  // supported if any such neighbour is solid. Exactly-45-degree offsets are
  // included (self-supporting), so an overhang is strictly steeper than 45 deg.
  const double cone_cos =
      std::cos(kOverhangAngleDeg * 3.14159265358979323846 / 180.0);
  std::vector<std::array<int, 3>> cone;
  for (int dk = -1; dk <= 1; ++dk)
    for (int dj = -1; dj <= 1; ++dj)
      for (int di = -1; di <= 1; ++di) {
        if (di == 0 && dj == 0 && dk == 0) continue;
        const Vec3 o{static_cast<double>(di), static_cast<double>(dj),
                     static_cast<double>(dk)};
        if (dot(normalized(o), down) >= cone_cos - 1e-9)
          cone.push_back({di, dj, dk});
      }

  // Build coordinate of a voxel centre (origin term dropped: only differences
  // matter). The lowest slab in this coordinate rests on the build plate.
  auto build_coord = [&](int i, int j, int k) {
    return ((static_cast<double>(i) + 0.5) * b.x +
            (static_cast<double>(j) + 0.5) * b.y +
            (static_cast<double>(k) + 0.5) * b.z) *
           grid.spacing;
  };

  double s_min = 0.0;
  bool have_min = false;
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        const double s = build_coord(i, j, k);
        if (!have_min || s < s_min) {
          s_min = s;
          have_min = true;
        }
      }
  if (!have_min) return 0;  // no solid voxels

  const double base_band = 0.5 * grid.spacing;  // lowest half-voxel slab
  int count = 0;
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        if (build_coord(i, j, k) - s_min <= base_band + 1e-9)
          continue;  // rests on the build plate: supported
        bool supported = false;
        for (const std::array<int, 3>& o : cone) {
          const int ni = i + o[0], nj = j + o[1], nk = k + o[2];
          if (ni < 0 || ni >= grid.nx || nj < 0 || nj >= grid.ny || nk < 0 ||
              nk >= grid.nz)
            continue;  // off-grid neighbour is not support
          if (grid.solid(ni, nj, nk)) {
            supported = true;
            break;
          }
        }
        if (!supported) ++count;
      }
  return count;
}

}  // namespace topopt
