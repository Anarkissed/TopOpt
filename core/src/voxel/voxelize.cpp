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
#include <string>
#include <utility>
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

DesignMask make_active_mask(const VoxelGrid& grid) {
  return DesignMask(grid.voxel_count(), MaskValue::Active);
}

// ---------------------------------------------------------------------------
// Design-domain expansion (ROADMAP M7.dom-core).
// ---------------------------------------------------------------------------

namespace {

void validate_box(const DesignBox& b, const char* what) {
  const double c[6] = {b.min.x, b.min.y, b.min.z, b.max.x, b.max.y, b.max.z};
  for (double v : c)
    if (!std::isfinite(v))
      throw std::invalid_argument(std::string("expand_design_domain: ") + what +
                                  " has a non-finite coordinate");
  if (b.min.x > b.max.x || b.min.y > b.max.y || b.min.z > b.max.z)
    throw std::invalid_argument(std::string("expand_design_domain: ") + what +
                                " has min > max on some axis");
}

// Whether a point lies inside an axis-aligned box (inclusive of the faces).
bool point_in_box(const Vec3& p, const DesignBox& b) {
  return p.x >= b.min.x && p.x <= b.max.x && p.y >= b.min.y && p.y <= b.max.y &&
         p.z >= b.min.z && p.z <= b.max.z;
}

}  // namespace

DesignDomain expand_design_domain(const VoxelGrid& part,
                                  const DesignBox& design_box,
                                  const std::vector<DesignBox>& keep_out,
                                  int coarsen_align) {
  if (!(part.spacing > 0.0))
    throw std::invalid_argument(
        "expand_design_domain: part.spacing must be > 0");
  if (coarsen_align < 1)
    throw std::invalid_argument(
        "expand_design_domain: coarsen_align must be >= 1");
  validate_box(design_box, "design_box");
  for (const DesignBox& k : keep_out) validate_box(k, "keep_out box");

  const double s = part.spacing;

  // Per axis, pad the part grid DOWN to cover design_box.min and UP to cover
  // design_box.max, in whole voxels, keeping the part's lattice (so part voxels
  // map to integer offsets). lo_pad voxels are prepended below the part origin;
  // the total count also covers the part and any voxels needed above it. Finally
  // round `total` UP to a multiple of coarsen_align by appending HIGH-side voxels
  // only (lo_pad — and therefore the offset and origin — is never touched), so
  // the multigrid hierarchy can coarsen every axis (see voxel.hpp). The appended
  // voxels sit beyond design_box.max and are classified Empty below.
  auto axis = [&](double origin, int n, double bmin, double bmax, int& lo_pad,
                  int& total) {
    // Voxels to prepend so the new origin (origin - lo_pad*s) is <= bmin.
    lo_pad = static_cast<int>(std::ceil((origin - bmin) / s - 1e-9));
    if (lo_pad < 0) lo_pad = 0;
    // Voxels to append beyond the part's far face so the grid reaches bmax.
    const double part_far = origin + static_cast<double>(n) * s;
    int hi_pad = static_cast<int>(std::ceil((bmax - part_far) / s - 1e-9));
    if (hi_pad < 0) hi_pad = 0;
    total = lo_pad + n + hi_pad;
    if (coarsen_align > 1) {
      const int rem = total % coarsen_align;
      if (rem != 0) total += coarsen_align - rem;  // grow the HIGH side only
    }
  };

  int oi, oj, ok, new_nx, new_ny, new_nz;
  axis(part.origin.x, part.nx, design_box.min.x, design_box.max.x, oi, new_nx);
  axis(part.origin.y, part.ny, design_box.min.y, design_box.max.y, oj, new_ny);
  axis(part.origin.z, part.nz, design_box.min.z, design_box.max.z, ok, new_nz);

  DesignDomain domain;
  domain.offset_i = oi;
  domain.offset_j = oj;
  domain.offset_k = ok;

  VoxelGrid& g = domain.grid;
  g.nx = new_nx;
  g.ny = new_ny;
  g.nz = new_nz;
  g.spacing = s;
  g.origin = Vec3{part.origin.x - static_cast<double>(oi) * s,
                  part.origin.y - static_cast<double>(oj) * s,
                  part.origin.z - static_cast<double>(ok) * s};
  g.tags.assign(static_cast<std::size_t>(new_nx) *
                    static_cast<std::size_t>(new_ny) *
                    static_cast<std::size_t>(new_nz),
                VoxelTag::Empty);
  domain.mask.assign(g.voxel_count(), MaskValue::Active);

  for (int k = 0; k < new_nz; ++k)
    for (int j = 0; j < new_ny; ++j)
      for (int i = 0; i < new_nx; ++i) {
        const std::size_t idx = g.index(i, j, k);
        // Does this expanded voxel map to a SOLID imported-part voxel?
        const int pi = i - oi, pj = j - oj, pk = k - ok;
        if (pi >= 0 && pi < part.nx && pj >= 0 && pj < part.ny && pk >= 0 &&
            pk < part.nz && part.solid(pi, pj, pk)) {
          // The imported part: frozen solid, keeping its original tag (incl. any
          // Load/Fixture face tag). Never removed, never overridden by a box.
          g.tags[idx] = part.tag(pi, pj, pk);
          domain.mask[idx] = MaskValue::FrozenSolid;
          continue;
        }
        // Not part material: only the design volume is a design region.
        const Vec3 c = g.voxel_center(i, j, k);
        if (!point_in_box(c, design_box)) continue;  // Empty / Active-ignored
        bool blocked = false;
        for (const DesignBox& ko : keep_out)
          if (point_in_box(c, ko)) {
            blocked = true;
            break;
          }
        if (blocked) {
          // Keep-out: FrozenVoid. Tag Empty so it carries no FEA element and no
          // self-weight (the mask value is ignored for Empty voxels but recorded
          // to document intent).
          domain.mask[idx] = MaskValue::FrozenVoid;
        } else {
          // New design material the optimizer may grow into.
          g.tags[idx] = VoxelTag::Interior;
          domain.mask[idx] = MaskValue::Active;
        }
      }

  return domain;
}

int remap_node_to_domain(const VoxelGrid& part, const DesignDomain& domain,
                         int node) {
  const int node_count = (part.nx + 1) * (part.ny + 1) * (part.nz + 1);
  if (node < 0 || node >= node_count)
    throw std::invalid_argument(
        "remap_node_to_domain: node out of range for part grid");
  const int stride_x = part.nx + 1;
  const int stride_xy = stride_x * (part.ny + 1);
  const int a = node % stride_x;
  const int b = (node / stride_x) % (part.ny + 1);
  const int c = node / stride_xy;
  // Corner-node id on the expanded grid, shifted by the domain offset. The
  // formula (fea.hpp) is inlined so this always-built TU keeps no link
  // dependency on the Eigen-gated fea_node_index in assembly.cpp.
  const int A = a + domain.offset_i;
  const int B = b + domain.offset_j;
  const int C = c + domain.offset_k;
  const VoxelGrid& g = domain.grid;
  return (C * (g.ny + 1) + B) * (g.nx + 1) + A;
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

  // M7.anchor-integrity (FIX 3): flag every raw-mesh vertex that sits on the
  // surface of a frozen (Load/Fixture) voxel, so the cleanup keeps a pinned
  // anchor/hole region even when it becomes a minority island — but NOTHING more.
  //
  // A marching-cubes vertex lies on an EDGE between two adjacent voxel CENTRES
  // (origin + (i+0.5)*spacing), differing by 1 in exactly one axis; the vertex
  // "belongs to" ONLY those two bounding voxels. We identify them precisely: in
  // voxel-centre coordinates u = (p - origin)/spacing - 0.5, the two constant
  // axes sit exactly on an integer centre and the varying axis lies strictly
  // between floor(u) and floor(u)+1. Flagging exactly this <=2-voxel edge set
  // (not a fat neighbourhood) means only a component that genuinely BOUNDS a
  // frozen voxel is marked: a separate optimisation-noise fragment near — but
  // separated by void from — the frozen region is NOT flagged, so it is still
  // cleaned away and the single-component invariant holds for normal parts.
  // When the part carries no Load/Fixture voxels this flags nothing and
  // keep_largest_and_marked_components degenerates to keep_largest_component
  // (byte-identical to the pre-M7.anchor-integrity path).
  bool any_frozen = false;
  for (const VoxelTag t : grid.tags)
    if (t == VoxelTag::Load || t == VoxelTag::Fixture) {
      any_frozen = true;
      break;
    }
  std::vector<char> vertex_frozen(raw.vertices.size(), 0);
  if (any_frozen) {
    const double h = grid.spacing;
    auto is_frozen = [&](int i, int j, int k) {
      if (i < 0 || i >= grid.nx || j < 0 || j >= grid.ny || k < 0 ||
          k >= grid.nz)
        return false;
      const VoxelTag t = grid.tag(i, j, k);
      return t == VoxelTag::Load || t == VoxelTag::Fixture;
    };
    for (std::size_t vi = 0; vi < raw.vertices.size(); ++vi) {
      const Vec3& p = raw.vertices[vi];
      const double u[3] = {(p.x - grid.origin.x) / h - 0.5,
                           (p.y - grid.origin.y) / h - 0.5,
                           (p.z - grid.origin.z) / h - 0.5};
      // Nearest integer centre + signed distance to it, per axis.
      int ctr[3];
      double d[3];
      for (int a = 0; a < 3; ++a) {
        ctr[a] = static_cast<int>(std::lround(u[a]));
        d[a] = u[a] - static_cast<double>(ctr[a]);
      }
      // The varying axis is the one whose coordinate is NOT on a centre.
      int va = 0;
      for (int a = 1; a < 3; ++a)
        if (std::fabs(d[a]) > std::fabs(d[va])) va = a;
      int lo[3] = {ctr[0], ctr[1], ctr[2]};
      int hi[3] = {ctr[0], ctr[1], ctr[2]};
      if (std::fabs(d[va]) > 1e-6) {
        lo[va] = static_cast<int>(std::floor(u[va]));
        hi[va] = lo[va] + 1;  // the two edge-endpoint voxels on the varying axis
      }
      if (is_frozen(lo[0], lo[1], lo[2]) || is_frozen(hi[0], hi[1], hi[2]))
        vertex_frozen[vi] = 1;
    }
  }
  // SURFACE, don't silently delete. keep_largest_and_marked_components reports
  // how many non-largest components genuinely bound frozen material via
  // `out_extra_kept`; that count is the SIGNAL (r.load_fixture_islands). The
  // displayed mesh itself stays the single largest body (keep_largest_component)
  // — so the §7 V3 single-component gate and every existing caller are byte-
  // identical — but a disconnected frozen region is no longer hidden: a caller
  // that sees load_fixture_islands > 0 knows the cleanup dropped pinned
  // Load/Fixture material and can warn instead of shipping a silently-broken
  // result (diagnosis 064: "keep the structure connected [the FIX 1 pad]; if
  // islands remain, surface a warning rather than silently deleting them"). In
  // the common healthy case out_extra_kept == 0 and the marked mesh IS the
  // largest component, so we reuse it and do no extra work.
  int extra = 0;
  TriangleMesh marked =
      keep_largest_and_marked_components(raw, vertex_frozen, extra);
  r.load_fixture_islands = extra;
  r.mesh = extra == 0 ? std::move(marked) : keep_largest_component(raw);
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
