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
#include <limits>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "topopt/coarsen.hpp"
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
                                  bool freeze_part, int coarsen_align) {
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
  // `raw` is the resulting count (lo_pad + part + any voxels needed above it),
  // BEFORE coarsening alignment.
  auto raw_axis = [&](double origin, int n, double bmin, double bmax,
                      int& lo_pad, int& raw) {
    // Voxels to prepend so the new origin (origin - lo_pad*s) is <= bmin.
    lo_pad = static_cast<int>(std::ceil((origin - bmin) / s - 1e-9));
    if (lo_pad < 0) lo_pad = 0;
    // Voxels to append beyond the part's far face so the grid reaches bmax.
    const double part_far = origin + static_cast<double>(n) * s;
    int hi_pad = static_cast<int>(std::ceil((bmax - part_far) / s - 1e-9));
    if (hi_pad < 0) hi_pad = 0;
    raw = lo_pad + n + hi_pad;
  };

  int oi, oj, ok, raw_nx, raw_ny, raw_nz;
  raw_axis(part.origin.x, part.nx, design_box.min.x, design_box.max.x, oi, raw_nx);
  raw_axis(part.origin.y, part.ny, design_box.min.y, design_box.max.y, oj, raw_ny);
  raw_axis(part.origin.z, part.nz, design_box.min.z, design_box.max.z, ok, raw_nz);

  // Round each element extent UP to a multiple of the FIXED `coarsen_align` by
  // appending HIGH-side voxels only (lo_pad — and therefore the offset and origin
  // — is never touched), so the geometric-multigrid hierarchy can coarsen
  // (handoff 079). The driver passes kDesignBoxCoarsenAlign = 8; coarsen_align <= 1
  // disables rounding (legacy byte-identical grid).
  //
  // WALK-BACK (handoff 122/127): PR #151 escalated this alignment ADAPTIVELY
  // (required_coarsen_align) to a deeper power of two, to force the coarsest MG
  // level under its DOF cap — on the theory that res-128 design-box runs fell back
  // to Jacobi-CG because the grid could not coarsen. A real res-128 loadcase run
  // (fingerprint 92e702008a9b) disproved the premise. At the FIXED align-8 floor
  // that job's grid is 232x64x216, which is NOT coarsenable; PR #151's escalation
  // grew it to 240x64x224, which IS — so multigrid BUILT the hierarchy there and
  // then STAGNATED, falling back on every one of 158 iterations while paying the
  // (now futile) build each solve. The fallback is a CONVERGENCE failure — the
  // geometric V-cycle stagnates past kMgIterBudget on the ~1e-9-contrast SIMP field
  // with a large clearance keep-out void (the adversarial-coefficient regime
  // multigrid.cpp's own comments warn about), which no amount of padding fixes.
  // Forcing coarsenability was in fact WORSE than inert here: it converted a cheap
  // build-fast-fail into an expensive build-then-stagnate-then-Jacobi every solve
  // (measured ~2.5x slower per stagnating solve). The escalation is withdrawn; the
  // fixed floor restores the exact pre-#151 grid. The coarsenability RULE
  // (mg_grid_coarsenable, topopt/coarsen.hpp) remains as documentation and a future
  // gate once the MG-convergence problem is fixed, but it no longer sizes the pad.
  // The residual stagnation risk is handled in the SOLVER now, not here: see the
  // per-run stagnation latch in multigrid.cpp (handoff 127).
  const int new_nx = round_up_to(raw_nx, coarsen_align);
  const int new_ny = round_up_to(raw_ny, coarsen_align);
  const int new_nz = round_up_to(raw_nz, coarsen_align);

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
          // The imported part keeps its original tag (incl. any Load/Fixture face
          // tag), never overridden by a box. `freeze_part` decides whether it is a
          // FrozenSolid keep-in (add-material feature) or an Active design variable
          // the optimizer may also remove (whole-domain optimize, handoff 080). The
          // Load/Fixture tags survive both, so the mask-aware simp path still pins
          // the BC skin FrozenSolid even when the part interior is Active.
          g.tags[idx] = part.tag(pi, pj, pk);
          domain.mask[idx] =
              freeze_part ? MaskValue::FrozenSolid : MaskValue::Active;
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

// Shared winding-fill core, defined below: mark every voxel of the grid (origin
// `lo`, cubic spacing `h`, nx*ny*nz) whose centre the mesh encloses by the +Z
// winding rule, then classify Surface/Interior. Both voxelize (grid derived from
// the mesh bbox) and voxelize_onto_grid (grid supplied) delegate here, so the two
// paths mark IDENTICAL occupancy for identical geometry.
static VoxelGrid voxelize_fill(const TriangleMesh& mesh, const Vec3& lo, double h,
                               int nx, int ny, int nz);

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

  return voxelize_fill(mesh, lo, h, axis_count(ext_x), axis_count(ext_y),
                       axis_count(ext_z));
}

// Voxelize `mesh` onto the SAME grid geometry as `reference` (origin, spacing and
// nx*ny*nz) instead of a bbox-derived grid, so an EDITED / smoothed variant mesh
// can be re-analysed on the exact grid the original run solved on — same voxel
// centres, so the run's node-indexed BCs and loads apply unchanged. This is the
// re-voxelization the standalone re-certification path (analyze_fixed_design) needs
// (handoff 2026-07-26-constrained-smooth). The quantization gap it introduces (the
// mesh surface vs its voxelization at this resolution) is the footnote the
// re-analysis provenance discloses. Throws if the mesh is empty.
VoxelGrid voxelize_onto_grid(const TriangleMesh& mesh, const VoxelGrid& reference) {
  if (mesh.empty() || mesh.vertices.empty())
    throw std::invalid_argument("voxelize_onto_grid: mesh is empty");
  if (!(reference.spacing > 0.0) || reference.nx < 1 || reference.ny < 1 ||
      reference.nz < 1)
    throw std::invalid_argument("voxelize_onto_grid: reference grid is degenerate");
  return voxelize_fill(mesh, reference.origin, reference.spacing, reference.nx,
                       reference.ny, reference.nz);
}

static VoxelGrid voxelize_fill(const TriangleMesh& mesh, const Vec3& lo, double h,
                               int nx, int ny, int nz) {
  VoxelGrid grid;
  grid.nx = nx;
  grid.ny = ny;
  grid.nz = nz;
  grid.spacing = h;
  grid.origin = lo;
  grid.tags.assign(static_cast<std::size_t>(nx) * static_cast<std::size_t>(ny) *
                       static_cast<std::size_t>(nz),
                   VoxelTag::Empty);

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

namespace {

// One in-place pass of the Felzenszwalb–Huttenlocher exact 1D squared-distance
// transform over a strided line of length `n`: f[q] <- min_p (q-p)² + f[p]. Seed
// samples hold 0, others a large finite value. `scratch_v` / `scratch_z` are
// caller-owned so the 3D driver reuses them across lines. Used by
// local_member_thickness_mm's seeded EDT (handoff 2026-07-26-width-aware-knockdown).
void edt_1d(double* f, int n, int stride, std::vector<int>& v,
            std::vector<double>& z, std::vector<double>& d) {
  const double kInf = std::numeric_limits<double>::infinity();
  int k = 0;
  v[0] = 0;
  z[0] = -kInf;
  z[1] = kInf;
  for (int q = 1; q < n; ++q) {
    const double fq = f[static_cast<std::size_t>(q) * stride];
    double s = ((fq + static_cast<double>(q) * q) -
                (f[static_cast<std::size_t>(v[k]) * stride] +
                 static_cast<double>(v[k]) * v[k])) /
               (2.0 * q - 2.0 * v[k]);
    while (s <= z[k]) {
      --k;
      s = ((fq + static_cast<double>(q) * q) -
           (f[static_cast<std::size_t>(v[k]) * stride] +
            static_cast<double>(v[k]) * v[k])) /
          (2.0 * q - 2.0 * v[k]);
    }
    ++k;
    v[k] = q;
    z[k] = s;
    z[k + 1] = kInf;
  }
  k = 0;
  for (int q = 0; q < n; ++q) {
    while (z[k + 1] < q) ++k;
    const double dq = static_cast<double>(q - v[k]);
    d[q] = dq * dq + f[static_cast<std::size_t>(v[k]) * stride];
  }
  for (int q = 0; q < n; ++q) f[static_cast<std::size_t>(q) * stride] = d[q];
}

// Exact squared Euclidean distance transform of a seed set on the grid: seed[idx]
// == true → distance 0, else the squared distance (voxel²) to the nearest seed.
// Separable Felzenszwalb along x, then y, then z. A grid with NO seed returns a
// large finite value everywhere (treated as "infinitely far" by the caller).
std::vector<double> squared_edt(const std::vector<char>& seed, int nx, int ny,
                                int nz) {
  // A finite sentinel larger than any achievable squared distance on this grid,
  // small enough that adding q² never overflows the parabola arithmetic.
  const double kBig = 4.0 * (static_cast<double>(nx) * nx +
                             static_cast<double>(ny) * ny +
                             static_cast<double>(nz) * nz) +
                      1.0;
  std::vector<double> f(seed.size());
  for (std::size_t idx = 0; idx < seed.size(); ++idx)
    f[idx] = seed[idx] ? 0.0 : kBig;

  const int maxdim = std::max({nx, ny, nz});
  std::vector<int> sv(static_cast<std::size_t>(maxdim));
  std::vector<double> sz(static_cast<std::size_t>(maxdim) + 1);
  std::vector<double> sd(static_cast<std::size_t>(maxdim));

  auto index = [nx, ny](int i, int j, int k) {
    return (static_cast<std::size_t>(k) * ny + j) * nx + i;
  };
  // x: contiguous rows (stride 1).
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      edt_1d(&f[index(0, j, k)], nx, 1, sv, sz, sd);
  // y: stride nx.
  for (int k = 0; k < nz; ++k)
    for (int i = 0; i < nx; ++i)
      edt_1d(&f[index(i, 0, k)], ny, nx, sv, sz, sd);
  // z: stride nx*ny.
  for (int j = 0; j < ny; ++j)
    for (int i = 0; i < nx; ++i)
      edt_1d(&f[index(i, j, 0)], nz, nx * ny, sv, sz, sd);
  return f;
}

}  // namespace

std::vector<double> local_member_thickness_mm(const VoxelGrid& grid,
                                              const std::vector<double>& density,
                                              double iso, int cap_radius_voxels) {
  if (density.size() != grid.voxel_count())
    throw std::invalid_argument(
        "local_member_thickness_mm: density size != grid.voxel_count()");
  if (cap_radius_voxels <= 0)
    throw std::invalid_argument(
        "local_member_thickness_mm: cap_radius_voxels must be > 0");
  const int nx = grid.nx, ny = grid.ny, nz = grid.nz;
  const std::size_t n = grid.voxel_count();

  // The printed set (the same non-Empty + density>iso material the mesh / mass /
  // stress field use). Void = everything else.
  std::vector<char> printed(n, 0);
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        const std::size_t idx = grid.index(i, j, k);
        printed[idx] = (grid.solid(i, j, k) && density[idx] > iso) ? 1 : 0;
      }

  // d²(v): squared distance from each printed voxel to the nearest VOID voxel
  // (seeds = void). Out-of-grid is NOT seeded, so a member filling to a grid face
  // reads no thinner there — the design grid pads the part with void, which is the
  // free surface. A fully-solid grid has no void seed → d² stays large → every
  // voxel resolves as "thick" (no wall rescue), the conservative degenerate.
  std::vector<char> seed_void(n);
  for (std::size_t idx = 0; idx < n; ++idx) seed_void[idx] = printed[idx] ? 0 : 1;
  const std::vector<double> d2 = squared_edt(seed_void, nx, ny, nz);

  // Granulometric opening: for r = 1..cap, S_r = { printed voxel with d ≥ r } is the
  // erosion by a radius-r ball; a voxel SURVIVES the opening by that ball iff it lies
  // within r of some S_r point (its seeded EDT ≤ r²). The largest surviving r is the
  // inscribed half-thickness. τ = 2·r·spacing; a voxel still surviving at the cap is
  // ≥ 2·cap·spacing thick and returns +inf ("thicker than measured" → no rescue).
  std::vector<int> level(n, 0);
  std::vector<char> seed_s(n);
  for (int r = 1; r <= cap_radius_voxels; ++r) {
    const double r2 = static_cast<double>(r) * r;
    bool any = false;
    for (std::size_t idx = 0; idx < n; ++idx) {
      const bool in = printed[idx] && d2[idx] >= r2;
      seed_s[idx] = in ? 1 : 0;
      any = any || in;
    }
    if (!any) break;  // no voxel is r-deep: no larger member survives either
    const std::vector<double> dr2 = squared_edt(seed_s, nx, ny, nz);
    for (std::size_t idx = 0; idx < n; ++idx)
      if (printed[idx] && dr2[idx] <= r2) level[idx] = r;
  }

  std::vector<double> thickness(n, 0.0);
  const double inf = std::numeric_limits<double>::infinity();
  for (std::size_t idx = 0; idx < n; ++idx) {
    if (!printed[idx]) continue;
    thickness[idx] = (level[idx] >= cap_radius_voxels)
                         ? inf
                         : 2.0 * static_cast<double>(level[idx]) * grid.spacing;
  }
  return thickness;
}

LoadPathWalk walk_load_path(const VoxelGrid& grid,
                            const std::vector<double>& density, double iso) {
  if (density.size() != grid.voxel_count())
    throw std::invalid_argument(
        "walk_load_path: density size != grid.voxel_count()");
  const int nx = grid.nx, ny = grid.ny, nz = grid.nz;
  LoadPathWalk w;

  // Printed = the material that actually exists in this field (the same
  // non-Empty + density > iso set the mesh, the mass and the stress field use).
  auto printed_at = [&](std::size_t idx) {
    return grid.tags[idx] != VoxelTag::Empty && density[idx] > iso;
  };

  // Endpoint census. Nothing to certify unless BOTH endpoints exist (voxel.hpp:
  // vacuously true); counting the Load voxels also gives the stopping criterion
  // below — the walk succeeds once it has reached all of them.
  for (std::size_t idx = 0; idx < grid.tags.size(); ++idx) {
    const VoxelTag t = grid.tags[idx];
    const bool p = printed_at(idx);
    if (p) ++w.printed_voxels;
    if (t == VoxelTag::Load) {
      ++w.load_voxels;
      if (p) ++w.load_voxels_printed;
    } else if (t == VoxelTag::Fixture) {
      ++w.anchor_voxels;
      if (p) ++w.anchor_voxels_printed;
    }
  }
  if (w.load_voxels == 0 || w.anchor_voxels == 0) {
    w.decidable = false;
    w.connected = true;  // vacuous: there is no load path to certify
    return w;
  }
  w.decidable = true;

  // BREADTH-FIRST flood fill from every PRINTED Fixture voxel (an anchor voxel
  // that was carved away anchors nothing) over 26-connectivity. Breadth-first so
  // the LEVEL SETS exist: level(v) is the geodesic distance in printed voxels
  // from the anchor set, and every level strictly between the anchors and the
  // nearest load is a separator (a step changes the level by at most one). The
  // reachable SET — hence the verdict — does not depend on the order, so the
  // switch from the pre-task depth-first walk changes no answer.
  std::vector<char> seen(grid.voxel_count(), 0);
  std::vector<std::size_t> frontier, next;
  auto push = [&](std::size_t idx) {
    if (seen[idx]) return;
    seen[idx] = 1;
    if (grid.tags[idx] == VoxelTag::Load) ++w.reached_load_voxels;
    ++w.reached_voxels;
    next.push_back(idx);
  };
  for (std::size_t idx = 0; idx < grid.tags.size(); ++idx)
    if (grid.tags[idx] == VoxelTag::Fixture && printed_at(idx)) push(idx);

  int level = 0;
  int load_level = -1;             // the level the first Load voxel appeared at
  std::vector<int> level_size;     // level_size[l] = |level set l|
  level_size.push_back(static_cast<int>(next.size()));
  while (!next.empty()) {
    frontier.swap(next);
    next.clear();
    if (load_level < 0)
      for (const std::size_t idx : frontier)
        if (grid.tags[idx] == VoxelTag::Load) { load_level = level; break; }
    for (const std::size_t idx : frontier) {
      // Decode grid.index() = (k*ny + j)*nx + i.
      const int i = static_cast<int>(idx % static_cast<std::size_t>(nx));
      const int j = static_cast<int>((idx / static_cast<std::size_t>(nx)) %
                                     static_cast<std::size_t>(ny));
      const int k = static_cast<int>(idx / (static_cast<std::size_t>(nx) *
                                            static_cast<std::size_t>(ny)));
      for (int dk = -1; dk <= 1; ++dk)
        for (int dj = -1; dj <= 1; ++dj)
          for (int di = -1; di <= 1; ++di) {
            if (di == 0 && dj == 0 && dk == 0) continue;
            const int ni = i + di, nj = j + dj, nk = k + dk;
            if (ni < 0 || nj < 0 || nk < 0 || ni >= nx || nj >= ny || nk >= nz)
              continue;
            const std::size_t nidx = grid.index(ni, nj, nk);
            if (!printed_at(nidx)) continue;
            push(nidx);
          }
    }
    ++level;
    if (!next.empty()) level_size.push_back(static_cast<int>(next.size()));
  }

  w.connected = w.reached_load_voxels == w.load_voxels;
  w.unreached_load_voxels = w.load_voxels - w.reached_load_voxels;

  // MARGINALITY (information, never a refusal): the narrowest level set strictly
  // between the anchor set and the nearest reached load — an UPPER BOUND on the
  // minimum cut of the surviving path.
  if (load_level >= 0) {
    w.geodesic_levels = load_level;
    for (int l = 1; l < load_level && l < static_cast<int>(level_size.size()); ++l) {
      if (w.narrowest_separator_voxels < 0 ||
          level_size[static_cast<std::size_t>(l)] < w.narrowest_separator_voxels) {
        w.narrowest_separator_voxels = level_size[static_cast<std::size_t>(l)];
        w.narrowest_separator_level = l;
      }
    }
    if (w.narrowest_separator_voxels >= 0)
      w.narrowest_separator_mm2 =
          static_cast<double>(w.narrowest_separator_voxels) * grid.spacing *
          grid.spacing;
  }
  return w;
}

bool load_path_connected(const VoxelGrid& grid,
                         const std::vector<double>& density, double iso) {
  if (density.size() != grid.voxel_count())
    throw std::invalid_argument(
        "load_path_connected: density size != grid.voxel_count()");
  return walk_load_path(grid, density, iso).connected;
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
