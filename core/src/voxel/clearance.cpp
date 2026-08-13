#include "topopt/clearance.hpp"

#include <cmath>
#include <stdexcept>

namespace topopt {
namespace {

double dot(const Vec3& a, const Vec3& b) {
  return a.x * b.x + a.y * b.y + a.z * b.z;
}
Vec3 sub(const Vec3& a, const Vec3& b) {
  return Vec3{a.x - b.x, a.y - b.y, a.z - b.z};
}
Vec3 cross(const Vec3& a, const Vec3& b) {
  return Vec3{a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z,
              a.x * b.y - a.y * b.x};
}
double norm(const Vec3& a) { return std::sqrt(dot(a, a)); }

// The in-plane orthonormal basis (u, w) spanning the plane whose UNIT normal is
// `normal`, chosen deterministically so the auto and manual paths agree exactly.
// Returns false only for a degenerate normal (the picked reference is parallel).
bool plane_basis(const Vec3& normal, Vec3& u, Vec3& w) {
  const Vec3 ref = std::fabs(normal.x) < 0.9 ? Vec3{1.0, 0.0, 0.0}
                                             : Vec3{0.0, 1.0, 0.0};
  Vec3 uu = cross(ref, normal);
  const double ul = norm(uu);
  if (ul <= 1e-12) return false;
  u = Vec3{uu.x / ul, uu.y / ul, uu.z / ul};
  w = cross(normal, u);  // already unit (normal ⟂ u, both unit)
  return true;
}

// The axial span [t_lo, t_hi] of a face's tessellation projected onto a unit
// axis through `axis_point`: t = (v - axis_point)·axis_dir over every vertex of
// every triangle belonging to `face_id`. Returns false if the face owns no
// triangles (a degenerate / untessellated face → no region).
bool face_axial_span(const StepModel& model, int face_id, const Vec3& axis_point,
                     const Vec3& axis_dir, double& t_lo, double& t_hi) {
  bool any = false;
  for (std::size_t t = 0; t < model.mesh.triangles.size(); ++t) {
    if (model.triangle_face[t] != face_id) continue;
    const auto& tri = model.mesh.triangles[t];
    for (int c = 0; c < 3; ++c) {
      const Vec3& v = model.mesh.vertices[static_cast<std::size_t>(tri[c])];
      const double s = dot(sub(v, axis_point), axis_dir);
      if (!any) {
        t_lo = t_hi = s;
        any = true;
      } else {
        if (s < t_lo) t_lo = s;
        if (s > t_hi) t_hi = s;
      }
    }
  }
  return any;
}

// The in-plane bounding rectangle of a face's tessellation, in the (u, w) basis
// spanning the plane: [u_lo,u_hi] x [w_lo,w_hi] of (v - origin)·u / ·w over the
// face's triangle vertices. Returns false if the face owns no triangles.
bool face_plane_extent(const StepModel& model, int face_id, const Vec3& origin,
                       const Vec3& u, const Vec3& w, double& u_lo, double& u_hi,
                       double& w_lo, double& w_hi) {
  bool any = false;
  for (std::size_t t = 0; t < model.mesh.triangles.size(); ++t) {
    if (model.triangle_face[t] != face_id) continue;
    const auto& tri = model.mesh.triangles[t];
    for (int c = 0; c < 3; ++c) {
      const Vec3& v = model.mesh.vertices[static_cast<std::size_t>(tri[c])];
      const Vec3 rel = sub(v, origin);
      const double du = dot(rel, u), dw = dot(rel, w);
      if (!any) {
        u_lo = u_hi = du;
        w_lo = w_hi = dw;
        any = true;
      } else {
        if (du < u_lo) u_lo = du;
        if (du > u_hi) u_hi = du;
        if (dw < w_lo) w_lo = dw;
        if (dw > w_hi) w_hi = dw;
      }
    }
  }
  return any;
}

// True iff `p` is inside `geom`, its boundary grown outward by `tol` on every
// extent. The single inside test rasterize_clearance and the freeze predicate
// share, so a frozen mesh vertex and a FrozenVoid voxel agree on the geometry.
// `tol` is the outward band (mm); the caller passes the voxel-centre eps for the
// rasterizer and a physical band for the freeze predicate.
bool region_contains(const ClearanceGeometry& geom, const Vec3& p, double tol) {
  if (!geom.valid) return false;
  // ★ THE ONE BRANCH THAT MAKES A REGION A REGION (task 2026-08-15-lattice-
  // regions §1b). A mask-backed geometry IS a voxel set: membership is the
  // lookup, and every analytic field below is unread.
  //
  // `tol` IS DELIBERATELY IGNORED HERE, and that is a statement, not an
  // oversight. On the analytic path tol inflates the region OUTWARD to build a
  // band around its surface (the smoother's freeze predicate). A voxel set has
  // no closed-form offset — inflating it would mean a dilation, i.e. a second
  // EDT per query — so a mask answers the EXACT region at every tol. The
  // consequence is bounded and one-directional: a positive tol asks for a
  // region at least this big and gets exactly the region, so a mask-backed
  // region is never reported as covering MORE than it does. Every lattice-role
  // membership call passes tol == 0 (verified: run_job.cpp fit-cell field,
  // per-region attribution, the certification mask, multiscale_region_mask, and
  // LatticeBoundary::in_{include,exclude}_region), so on the path this field was
  // built for the distinction does not arise at all.
  if (geom.mask) return geom.mask->contains(p);
  if (geom.kind == ClearanceKind::Bolt) {
    const Vec3 rel = sub(p, geom.axis_point);
    const double t = dot(rel, geom.axis_dir);
    if (t < geom.t_lo - tol || t > geom.t_hi + tol) return false;
    const Vec3 radial = Vec3{rel.x - t * geom.axis_dir.x,
                             rel.y - t * geom.axis_dir.y,
                             rel.z - t * geom.axis_dir.z};
    return norm(radial) <= geom.radius + tol;
  }
  // Face slab.
  const Vec3 rel = sub(p, geom.origin);
  const double s = dot(rel, geom.normal);
  if (s < -tol || s > geom.depth + tol) return false;
  const double du = dot(rel, geom.u), dw = dot(rel, geom.w);
  return du >= geom.u_lo - tol && du <= geom.u_hi + tol &&
         dw >= geom.w_lo - tol && dw <= geom.w_hi + tol;
}

}  // namespace

bool point_in_clearance_region(const ClearanceGeometry& geom, const Vec3& p,
                               double tol) {
  return region_contains(geom, p, tol);
}

// ── AUTO path: resolve the predicate from a B-rep / pseudo face. ────────────
// This is the geometry-derivation block that used to live inline in
// mask_clearance_region; its output is now the explicit ClearanceGeometry the
// shared rasterizer consumes. Behaviour is unchanged, so the wrapper below (and
// every existing caller/test) is byte-identical (BAR B4).
ClearanceGeometry resolve_clearance_from_face(const StepModel& model, int face_id,
                                              const ClearanceParams& params) {
  if (face_id < 0 || face_id >= model.face_count)
    throw std::invalid_argument(
        "resolve_clearance_from_face: face_id " + std::to_string(face_id) +
        " out of range — the model carries " +
        std::to_string(model.face_count) + " faces");
  if (model.triangle_face.size() != model.mesh.triangles.size())
    throw std::invalid_argument(
        "resolve_clearance_from_face: triangle_face is not parallel to "
        "mesh.triangles");

  ClearanceGeometry g;
  g.kind = params.kind;
  const StepFaceInfo& face = model.faces[static_cast<std::size_t>(face_id)];

  if (params.kind == ClearanceKind::Bolt &&
      face.kind == StepSurfaceKind::Cylinder && norm(face.axis_dir) > 0.5) {
    g.axis_point = face.axis_point;
    const double dl = norm(face.axis_dir);
    g.axis_dir = Vec3{face.axis_dir.x / dl, face.axis_dir.y / dl,
                      face.axis_dir.z / dl};
    g.radius = face.cylinder_radius_mm + params.concentric_margin_mm;
    if (g.radius > 0.0 &&
        face_axial_span(model, face_id, g.axis_point, g.axis_dir, g.t_lo,
                        g.t_hi)) {
      g.t_lo -= params.axial_clearance_mm;
      g.t_hi += params.axial_clearance_mm;
      g.valid = true;
    }
  } else if (params.kind == ClearanceKind::Face &&
             face.kind == StepSurfaceKind::Plane &&
             norm(face.plane_normal) > 0.5 && params.slab_depth_mm > 0.0) {
    g.origin = face.plane_origin;
    const double nl = norm(face.plane_normal);
    g.normal = Vec3{face.plane_normal.x / nl, face.plane_normal.y / nl,
                    face.plane_normal.z / nl};
    g.depth = params.slab_depth_mm;
    if (plane_basis(g.normal, g.u, g.w) &&
        face_plane_extent(model, face_id, g.origin, g.u, g.w, g.u_lo, g.u_hi,
                          g.w_lo, g.w_hi))
      g.valid = true;
  }
  return g;
}

// ── MANUAL path: resolve the predicate from user-supplied geometry. ─────────
// No B-rep, no triangles: the base axis/radius/half-length (or
// origin/normal/half-extents) come from `geom`, and `params` grows them by the
// SAME margins the auto path applies. A manual and an auto primitive whose base
// geometry matches therefore resolve to the same predicate (BAR B2).
ClearanceGeometry resolve_clearance_manual(const ManualClearanceGeometry& geom,
                                           const ClearanceParams& params) {
  ClearanceGeometry g;
  g.kind = geom.kind;

  if (geom.kind == ClearanceKind::Bolt) {
    const double dl = norm(geom.axis_dir);
    if (dl <= 1e-12) return g;  // degenerate axis → empty region
    g.axis_point = geom.axis_point;
    g.axis_dir = Vec3{geom.axis_dir.x / dl, geom.axis_dir.y / dl,
                      geom.axis_dir.z / dl};
    g.radius = geom.radius_mm + params.concentric_margin_mm;
    g.t_lo = -geom.half_length_mm - params.axial_clearance_mm;
    g.t_hi = geom.half_length_mm + params.axial_clearance_mm;
    if (g.radius > 0.0 && g.t_hi > g.t_lo) g.valid = true;
  } else {  // Face
    const double nl = norm(geom.normal);
    if (nl <= 1e-12 || params.slab_depth_mm <= 0.0) return g;
    g.origin = geom.origin;
    g.normal = Vec3{geom.normal.x / nl, geom.normal.y / nl, geom.normal.z / nl};
    g.depth = params.slab_depth_mm;
    if (!plane_basis(g.normal, g.u, g.w)) return g;
    g.u_lo = -geom.half_u_mm;
    g.u_hi = geom.half_u_mm;
    g.w_lo = -geom.half_w_mm;
    g.w_hi = geom.half_w_mm;
    if (g.u_hi > g.u_lo && g.w_hi > g.w_lo) g.valid = true;
  }
  return g;
}

// ── Shared rasterizer: a resolved predicate → FrozenVoid voxels. ────────────
ClearanceRasterResult rasterize_clearance(const VoxelGrid& solved_grid,
                                          const VoxelGrid& part, int offset_i,
                                          int offset_j, int offset_k,
                                          const ClearanceGeometry& geom,
                                          DesignMask& out) {
  if (out.size() != solved_grid.voxel_count())
    throw std::invalid_argument(
        "rasterize_clearance: out size != solved_grid.voxel_count()");

  ClearanceRasterResult result;
  if (!geom.valid) return result;
  const double eps = 1e-9 * solved_grid.spacing;

  for (int k = 0; k < solved_grid.nz; ++k)
    for (int j = 0; j < solved_grid.ny; ++j)
      for (int i = 0; i < solved_grid.nx; ++i) {
        const Vec3 p = solved_grid.voxel_center(i, j, k);
        if (!region_contains(geom, p, eps)) continue;
        ++result.region_voxels;

        // PRECEDENCE: never void PART material. A solved voxel mapping to a
        // solid part voxel is FrozenSolid/keep-in and wins — skip it.
        const int pi = i - offset_i, pj = j - offset_j, pk = k - offset_k;
        if (pi >= 0 && pi < part.nx && pj >= 0 && pj < part.ny && pk >= 0 &&
            pk < part.nz && part.solid(pi, pj, pk))
          continue;

        const std::size_t idx = solved_grid.index(i, j, k);
        if (out[idx] != MaskValue::FrozenVoid) {
          out[idx] = MaskValue::FrozenVoid;
          ++result.voxels_frozen;
        }
      }

  result.region_in_grid = result.region_voxels > 0;
  return result;
}

// ── Wrapper: the original face-derived entry point, unchanged behaviour. ────
ClearanceRasterResult mask_clearance_region(const VoxelGrid& solved_grid,
                                            const VoxelGrid& part, int offset_i,
                                            int offset_j, int offset_k,
                                            const StepModel& model, int face_id,
                                            const ClearanceParams& params,
                                            DesignMask& out) {
  const ClearanceGeometry geom =
      resolve_clearance_from_face(model, face_id, params);
  return rasterize_clearance(solved_grid, part, offset_i, offset_j, offset_k,
                             geom, out);
}

}  // namespace topopt
