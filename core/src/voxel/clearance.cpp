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

}  // namespace

ClearanceRasterResult mask_clearance_region(const VoxelGrid& solved_grid,
                                            const VoxelGrid& part, int offset_i,
                                            int offset_j, int offset_k,
                                            const StepModel& model, int face_id,
                                            const ClearanceParams& params,
                                            DesignMask& out) {
  if (face_id < 0 || face_id >= model.face_count)
    throw std::invalid_argument("mask_clearance_region: face_id out of range");
  if (out.size() != solved_grid.voxel_count())
    throw std::invalid_argument(
        "mask_clearance_region: out size != solved_grid.voxel_count()");
  if (model.triangle_face.size() != model.mesh.triangles.size())
    throw std::invalid_argument(
        "mask_clearance_region: triangle_face is not parallel to mesh.triangles");

  ClearanceRasterResult result;
  const StepFaceInfo& face =
      model.faces[static_cast<std::size_t>(face_id)];
  const double eps = 1e-9 * solved_grid.spacing;

  // ── Precompute the region's geometric predicate parameters. ──────────────
  // Bolt: swept cylinder (axis, radius, axial band). Face: bounded slab (plane
  // origin/normal, in-plane rectangle, outward depth). A kind whose geometry is
  // missing (Bolt on a non-cylinder, Face on a non-plane, or an untessellated
  // face) yields an empty region — nothing is marked.
  bool valid = false;
  // Bolt params.
  Vec3 axis_point{}, axis_dir{};
  double radius = 0.0, t_lo = 0.0, t_hi = 0.0;
  // Face params.
  Vec3 origin{}, normal{}, u{}, w{};
  double u_lo = 0.0, u_hi = 0.0, w_lo = 0.0, w_hi = 0.0, depth = 0.0;

  if (params.kind == ClearanceKind::Bolt &&
      face.kind == StepSurfaceKind::Cylinder && norm(face.axis_dir) > 0.5) {
    axis_point = face.axis_point;
    const double dl = norm(face.axis_dir);
    axis_dir = Vec3{face.axis_dir.x / dl, face.axis_dir.y / dl,
                    face.axis_dir.z / dl};
    radius = face.cylinder_radius_mm + params.concentric_margin_mm;
    if (radius > 0.0 &&
        face_axial_span(model, face_id, axis_point, axis_dir, t_lo, t_hi)) {
      t_lo -= params.axial_clearance_mm;
      t_hi += params.axial_clearance_mm;
      valid = true;
    }
  } else if (params.kind == ClearanceKind::Face &&
             face.kind == StepSurfaceKind::Plane &&
             norm(face.plane_normal) > 0.5 && params.slab_depth_mm > 0.0) {
    origin = face.plane_origin;
    const double nl = norm(face.plane_normal);
    normal = Vec3{face.plane_normal.x / nl, face.plane_normal.y / nl,
                  face.plane_normal.z / nl};
    depth = params.slab_depth_mm;
    // An in-plane orthonormal basis (u, w) perpendicular to the normal.
    const Vec3 ref = std::fabs(normal.x) < 0.9 ? Vec3{1.0, 0.0, 0.0}
                                               : Vec3{0.0, 1.0, 0.0};
    Vec3 uu = cross(ref, normal);
    const double ul = norm(uu);
    if (ul > 1e-12) {
      u = Vec3{uu.x / ul, uu.y / ul, uu.z / ul};
      w = cross(normal, u);  // already unit (normal ⟂ u, both unit)
      if (face_plane_extent(model, face_id, origin, u, w, u_lo, u_hi, w_lo,
                            w_hi))
        valid = true;
    }
  }
  if (!valid) return result;

  // ── Rasterize over the solved grid. ──────────────────────────────────────
  for (int k = 0; k < solved_grid.nz; ++k)
    for (int j = 0; j < solved_grid.ny; ++j)
      for (int i = 0; i < solved_grid.nx; ++i) {
        const Vec3 p = solved_grid.voxel_center(i, j, k);
        bool inside = false;
        if (params.kind == ClearanceKind::Bolt) {
          const Vec3 rel = sub(p, axis_point);
          const double t = dot(rel, axis_dir);
          if (t >= t_lo - eps && t <= t_hi + eps) {
            const Vec3 radial = Vec3{rel.x - t * axis_dir.x,
                                     rel.y - t * axis_dir.y,
                                     rel.z - t * axis_dir.z};
            if (norm(radial) <= radius + eps) inside = true;
          }
        } else {  // Face slab
          const Vec3 rel = sub(p, origin);
          const double s = dot(rel, normal);
          if (s >= -eps && s <= depth + eps) {
            const double du = dot(rel, u), dw = dot(rel, w);
            if (du >= u_lo - eps && du <= u_hi + eps && dw >= w_lo - eps &&
                dw <= w_hi + eps)
              inside = true;
          }
        }
        if (!inside) continue;
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

}  // namespace topopt
