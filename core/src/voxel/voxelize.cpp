// Solid voxelizer (ROADMAP M1.5): surface triangle mesh -> filled cubic voxel
// grid with per-voxel interior/surface tags.
//
// Fill method: for each grid column (fixed i,j) a vertical ray is cast upward
// through the voxel centres. Every triangle whose XY projection contains the
// column centre contributes a crossing (z of the triangle plane at that centre,
// plus the sign of the triangle's projected orientation = sign of its normal's
// z-component). A voxel centre is inside the solid when the signed sum of
// crossings strictly above it is non-zero (a winding-number test). Summing signs
// rather than counting parity makes the fill robust when the ray grazes an edge
// shared by two triangles that face the same way (e.g. the diagonal of the
// cube's top/bottom faces): both are counted, the winding doubles but stays
// non-zero, so the classification does not flip.

#include "topopt/voxel.hpp"

#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <vector>

#include "topopt/mesh.hpp"

namespace topopt {

std::size_t VoxelGrid::solid_count() const {
  std::size_t n = 0;
  for (VoxelTag t : tags) {
    if (t != VoxelTag::Empty) ++n;
  }
  return n;
}

namespace {

// A ray/triangle crossing in one column: the z where the triangle plane meets
// the column centre, and the sign of the triangle's projected orientation
// (+1 up-facing, -1 down-facing).
struct Crossing {
  double z;
  int sign;
};

}  // namespace

VoxelGrid voxelize(const TriangleMesh& mesh, int resolution) {
  if (resolution < 1) {
    throw std::invalid_argument("voxelize: resolution must be >= 1");
  }
  if (mesh.empty() || mesh.vertices.empty()) {
    throw std::invalid_argument("voxelize: mesh is empty");
  }

  Vec3 lo, hi;
  bounding_box(mesh, lo, hi);
  const double ext_x = hi.x - lo.x;
  const double ext_y = hi.y - lo.y;
  const double ext_z = hi.z - lo.z;
  const double max_ext = std::max(ext_x, std::max(ext_y, ext_z));
  if (!(max_ext > 0.0)) {
    throw std::invalid_argument("voxelize: mesh bounding box has zero extent");
  }

  // Cubic voxels: edge length = longest extent / resolution. The longest axis
  // gets exactly `resolution` voxels; each other axis gets enough voxels to
  // cover its extent (a small epsilon absorbs FP noise so an axis that divides
  // evenly does not gain a spurious extra voxel).
  const double h = max_ext / static_cast<double>(resolution);
  auto axis_count = [&](double ext) {
    int n = static_cast<int>(std::ceil(ext / h - 1e-9));
    return n < 1 ? 1 : n;
  };

  VoxelGrid grid;
  grid.nx = axis_count(ext_x);
  grid.ny = axis_count(ext_y);
  grid.nz = axis_count(ext_z);
  grid.spacing = h;
  grid.origin = lo;
  grid.tags.assign(static_cast<std::size_t>(grid.nx) *
                       static_cast<std::size_t>(grid.ny) *
                       static_cast<std::size_t>(grid.nz),
                   VoxelTag::Empty);

  const int nx = grid.nx;
  const int ny = grid.ny;
  const int nz = grid.nz;

  // Per-column list of crossings (x-fastest indexing over the nx*ny columns).
  std::vector<std::vector<Crossing>> columns(static_cast<std::size_t>(nx) *
                                             static_cast<std::size_t>(ny));

  auto col_x = [&](int i) { return lo.x + (static_cast<double>(i) + 0.5) * h; };
  auto col_y = [&](int j) { return lo.y + (static_cast<double>(j) + 0.5) * h; };

  for (const auto& tri : mesh.triangles) {
    const Vec3& a = mesh.vertices[static_cast<std::size_t>(tri[0])];
    const Vec3& b = mesh.vertices[static_cast<std::size_t>(tri[1])];
    const Vec3& c = mesh.vertices[static_cast<std::size_t>(tri[2])];

    // Twice the signed area of the XY projection == sign of the triangle
    // normal's z-component. A (near-)zero value means the triangle is vertical
    // (edge-on to the +Z ray): it can never be crossed, so skip it.
    const double area2 = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
    if (std::fabs(area2) < 1e-18) continue;
    const int sign = area2 > 0.0 ? 1 : -1;

    // Only the columns inside the triangle's XY bounding box can be crossed.
    const double tri_min_x = std::min(a.x, std::min(b.x, c.x));
    const double tri_max_x = std::max(a.x, std::max(b.x, c.x));
    const double tri_min_y = std::min(a.y, std::min(b.y, c.y));
    const double tri_max_y = std::max(a.y, std::max(b.y, c.y));

    int i0 = static_cast<int>(std::floor((tri_min_x - lo.x) / h - 0.5));
    int i1 = static_cast<int>(std::ceil((tri_max_x - lo.x) / h - 0.5));
    int j0 = static_cast<int>(std::floor((tri_min_y - lo.y) / h - 0.5));
    int j1 = static_cast<int>(std::ceil((tri_max_y - lo.y) / h - 0.5));
    i0 = std::max(i0, 0);
    j0 = std::max(j0, 0);
    i1 = std::min(i1, nx - 1);
    j1 = std::min(j1, ny - 1);

    for (int j = j0; j <= j1; ++j) {
      const double py = col_y(j);
      for (int i = i0; i <= i1; ++i) {
        const double px = col_x(i);

        // Boundary-inclusive point-in-triangle on the XY projection, via the
        // three edge functions. Inclusive so a centre lying exactly on a shared
        // edge is seen by both triangles; the winding sum tolerates that.
        const double e0 =
            (b.x - a.x) * (py - a.y) - (b.y - a.y) * (px - a.x);
        const double e1 =
            (c.x - b.x) * (py - b.y) - (c.y - b.y) * (px - b.x);
        const double e2 =
            (a.x - c.x) * (py - c.y) - (a.y - c.y) * (px - c.x);
        const bool inside = (e0 >= 0.0 && e1 >= 0.0 && e2 >= 0.0) ||
                            (e0 <= 0.0 && e1 <= 0.0 && e2 <= 0.0);
        if (!inside) continue;

        // z of the triangle plane at (px,py) via barycentric interpolation.
        // Weights: c<-e0, a<-e1, b<-e2, normalized by area2 = e0+e1+e2.
        const double z_hit = (e1 * a.z + e2 * b.z + e0 * c.z) / area2;
        columns[static_cast<std::size_t>(j) * static_cast<std::size_t>(nx) +
                static_cast<std::size_t>(i)]
            .push_back(Crossing{z_hit, sign});
      }
    }
  }

  // Winding fill: a voxel centre is inside iff the signed sum of crossings
  // strictly above it is non-zero.
  std::vector<char> occupied(grid.tags.size(), 0);
  for (int j = 0; j < ny; ++j) {
    for (int i = 0; i < nx; ++i) {
      std::vector<Crossing>& cr =
          columns[static_cast<std::size_t>(j) * static_cast<std::size_t>(nx) +
                  static_cast<std::size_t>(i)];
      if (cr.empty()) continue;
      std::sort(cr.begin(), cr.end(),
                [](const Crossing& p, const Crossing& q) { return p.z < q.z; });
      // Total winding of all crossings; subtract as we pass each crossing from
      // the bottom, leaving the winding of crossings strictly above the centre.
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
        const int above = total - below;
        if (above != 0) {
          occupied[grid.index(i, j, k)] = 1;
        }
      }
    }
  }

  // Classify solid voxels: Surface if any 6-face-neighbour is not solid (empty
  // or outside the grid), otherwise Interior.
  auto is_occupied = [&](int i, int j, int k) {
    if (i < 0 || j < 0 || k < 0 || i >= nx || j >= ny || k >= nz) return false;
    return occupied[grid.index(i, j, k)] != 0;
  };
  for (int k = 0; k < nz; ++k) {
    for (int j = 0; j < ny; ++j) {
      for (int i = 0; i < nx; ++i) {
        if (!is_occupied(i, j, k)) continue;
        const bool boundary =
            !is_occupied(i - 1, j, k) || !is_occupied(i + 1, j, k) ||
            !is_occupied(i, j - 1, k) || !is_occupied(i, j + 1, k) ||
            !is_occupied(i, j, k - 1) || !is_occupied(i, j, k + 1);
        grid.tags[grid.index(i, j, k)] =
            boundary ? VoxelTag::Surface : VoxelTag::Interior;
      }
    }
  }

  return grid;
}

// ---------------------------------------------------------------------------
// Marching cubes wrapper + Gate V3 property suite (ROADMAP M3.5).
// ---------------------------------------------------------------------------

TriangleMesh marching_cubes(const VoxelGrid& grid,
                            const std::vector<double>& density, double iso) {
  if (density.size() != grid.voxel_count())
    throw std::invalid_argument(
        "marching_cubes: density size != grid.voxel_count()");
  return marching_cubes(grid.nx, grid.ny, grid.nz, grid.spacing, grid.origin,
                        density, iso);
}

int min_feature_violations(const VoxelGrid& grid,
                           const std::vector<double>& density, double iso) {
  if (density.size() != grid.voxel_count())
    throw std::invalid_argument(
        "min_feature_violations: density size != grid.voxel_count()");
  const int nx = grid.nx, ny = grid.ny, nz = grid.nz;
  auto solid = [&](int i, int j, int k) {
    return density[grid.index(i, j, k)] > iso;
  };
  // Mark every voxel that belongs to at least one fully-solid 2x2x2 block. A
  // block with min corner (i,j,k) exists for i in [0,nx-2] etc.; if all 8 of its
  // voxels are solid, all 8 are "thick enough". Any solid voxel left unmarked is
  // part of a feature thinner than 2 voxels in some direction.
  std::vector<char> covered(grid.voxel_count(), 0);
  for (int k = 0; k + 1 < nz; ++k)
    for (int j = 0; j + 1 < ny; ++j)
      for (int i = 0; i + 1 < nx; ++i) {
        bool full = true;
        for (int dk = 0; dk < 2 && full; ++dk)
          for (int dj = 0; dj < 2 && full; ++dj)
            for (int di = 0; di < 2 && full; ++di)
              if (!solid(i + di, j + dj, k + dk)) full = false;
        if (!full) continue;
        for (int dk = 0; dk < 2; ++dk)
          for (int dj = 0; dj < 2; ++dj)
            for (int di = 0; di < 2; ++di)
              covered[grid.index(i + di, j + dj, k + dk)] = 1;
      }
  int violations = 0;
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i)
        if (solid(i, j, k) && !covered[grid.index(i, j, k)]) ++violations;
  return violations;
}

V3Report check_v3(const VoxelGrid& grid, const std::vector<double>& density,
                  double iso) {
  if (density.size() != grid.voxel_count())
    throw std::invalid_argument("check_v3: density size != grid.voxel_count()");

  V3Report r;

  // Gate 1 + 2: marching cubes -> cleanup -> watertight + single component.
  const TriangleMesh raw = marching_cubes(grid, density, iso);
  r.mesh_components_raw = count_components(raw);
  r.mesh = keep_largest_component(raw);
  r.watertight = check_watertight(r.mesh);
  r.mesh_components = count_components(r.mesh);

  // Gate 3: Load/Fixture voxels retained at density >= 0.9.
  r.min_load_fixture_density = 1.0;
  r.load_fixture_voxels = 0;
  bool retained = true;
  for (std::size_t idx = 0; idx < grid.tags.size(); ++idx) {
    const VoxelTag t = grid.tags[idx];
    if (t != VoxelTag::Load && t != VoxelTag::Fixture) continue;
    ++r.load_fixture_voxels;
    const double d = density[idx];
    if (d < r.min_load_fixture_density) r.min_load_fixture_density = d;
    if (d < kV3RetentionThreshold) retained = false;
  }
  r.load_fixture_retained = retained;  // vacuously true if no such voxels

  // Gate 4: minimum feature size >= 2 voxels.
  r.min_feature_violations = min_feature_violations(grid, density, iso);

  r.passes = r.gate_watertight() && r.gate_single_component() &&
             r.gate_load_fixture_retained() && r.gate_min_feature();
  return r;
}

}  // namespace topopt
