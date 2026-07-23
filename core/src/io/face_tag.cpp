// face_tag.cpp — voxel tagging / masking against a model face (M1.6, M3.7),
// split out of step.cpp by handoff 134.
//
// WHY THIS FILE EXISTS. These two functions read only `StepModel::mesh`,
// `StepModel::triangle_face` and the voxel grid — plain geometry, no OCCT. They
// were written inside the OCCT-gated step.cpp because STEP was the only source
// of faces. Now that an STL/3MF import also produces a face-carrying StepModel
// (src/io/part.cpp), face tagging must be available wherever a mesh is, which
// includes the dependency-free iOS slices where OCCT cannot be linked. So the
// OCCT-free half moved here, into an always-built translation unit.
//
// The code below is UNCHANGED from step.cpp; only its home moved.

#include "topopt/step.hpp"

#include <cmath>
#include <stdexcept>

namespace topopt {

namespace {

// Squared distance from point p to the triangle (a,b,c), via the closest point
// on the triangle (Ericson, Real-Time Collision Detection, ClosestPtPointTri).
// Region tests cover the vertex / edge / face Voronoi regions.
double point_tri_dist2(const Vec3& p, const Vec3& a, const Vec3& b,
                       const Vec3& c) {
  auto sub = [](const Vec3& u, const Vec3& v) {
    return Vec3{u.x - v.x, u.y - v.y, u.z - v.z};
  };
  auto dot = [](const Vec3& u, const Vec3& v) {
    return u.x * v.x + u.y * v.y + u.z * v.z;
  };
  auto axpy = [](const Vec3& base, double t, const Vec3& dir) {
    return Vec3{base.x + t * dir.x, base.y + t * dir.y, base.z + t * dir.z};
  };

  const Vec3 ab = sub(b, a);
  const Vec3 ac = sub(c, a);
  const Vec3 ap = sub(p, a);
  const double d1 = dot(ab, ap);
  const double d2 = dot(ac, ap);

  Vec3 q;
  if (d1 <= 0.0 && d2 <= 0.0) {
    q = a;  // vertex region A
  } else {
    const Vec3 bp = sub(p, b);
    const double d3 = dot(ab, bp);
    const double d4 = dot(ac, bp);
    if (d3 >= 0.0 && d4 <= d3) {
      q = b;  // vertex region B
    } else {
      const Vec3 cp = sub(p, c);
      const double d5 = dot(ab, cp);
      const double d6 = dot(ac, cp);
      const double vc = d1 * d4 - d3 * d2;
      const double vb = d5 * d2 - d1 * d6;
      const double va = d3 * d6 - d5 * d4;
      if (vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0) {
        q = axpy(a, d1 / (d1 - d3), ab);  // edge AB
      } else if (d6 >= 0.0 && d5 <= d6) {
        q = c;  // vertex region C
      } else if (vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0) {
        q = axpy(a, d2 / (d2 - d6), ac);  // edge AC
      } else if (va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0) {
        q = axpy(b, (d4 - d3) / ((d4 - d3) + (d5 - d6)), sub(c, b));  // edge BC
      } else {
        const double denom = 1.0 / (va + vb + vc);  // interior of the face
        q = axpy(axpy(a, vb * denom, ab), vc * denom, ac);
      }
    }
  }
  const Vec3 d = sub(p, q);
  return dot(d, d);
}

}  // namespace

std::size_t tag_step_face(VoxelGrid& grid, const StepModel& model, int face_id,
                          VoxelTag tag) {
  if (tag != VoxelTag::Load && tag != VoxelTag::Fixture)
    throw std::invalid_argument("tag_step_face: tag must be Load or Fixture");
  if (face_id < 0 || face_id >= model.face_count)
    throw std::invalid_argument("tag_step_face: face_id out of range");
  if (model.triangle_face.size() != model.mesh.triangles.size())
    throw std::invalid_argument(
        "tag_step_face: triangle_face is not parallel to mesh.triangles");

  // A voxel is against the face when its centre is within half a voxel edge of
  // the face surface. Compare squared distances (no sqrt); the epsilon absorbs
  // FP noise so a centre exactly half a voxel from a flush planar face counts.
  const double h = grid.spacing;
  const double thr2 = 0.25 * h * h;
  const double eps = 1e-9 * h * h;

  std::size_t tagged = 0;
  for (int k = 0; k < grid.nz; ++k) {
    for (int j = 0; j < grid.ny; ++j) {
      for (int i = 0; i < grid.nx; ++i) {
        if (!grid.solid(i, j, k)) continue;  // only material carries load/fixture
        const Vec3 centre = grid.voxel_center(i, j, k);
        bool against = false;
        for (std::size_t t = 0;
             t < model.mesh.triangles.size() && !against; ++t) {
          if (model.triangle_face[t] != face_id) continue;
          const auto& tri = model.mesh.triangles[t];
          const Vec3& a = model.mesh.vertices[static_cast<std::size_t>(tri[0])];
          const Vec3& b = model.mesh.vertices[static_cast<std::size_t>(tri[1])];
          const Vec3& c = model.mesh.vertices[static_cast<std::size_t>(tri[2])];
          if (point_tri_dist2(centre, a, b, c) <= thr2 + eps) against = true;
        }
        if (against) {
          grid.set_tag(i, j, k, tag);
          ++tagged;
        }
      }
    }
  }
  return tagged;
}

std::size_t mask_step_face(const VoxelGrid& grid, const StepModel& model,
                           int face_id, MaskValue mask_value, int depth_voxels,
                           DesignMask& mask) {
  if (depth_voxels < 1)
    throw std::invalid_argument("mask_step_face: depth_voxels must be >= 1");
  if (face_id < 0 || face_id >= model.face_count)
    throw std::invalid_argument("mask_step_face: face_id out of range");
  if (mask.size() != grid.voxel_count())
    throw std::invalid_argument("mask_step_face: mask size != voxel_count");
  if (model.triangle_face.size() != model.mesh.triangles.size())
    throw std::invalid_argument(
        "mask_step_face: triangle_face is not parallel to mesh.triangles");

  // Depth generalization of tag_step_face: a voxel in layer L against a flush
  // planar face has its centre (L + 0.5) edges from the face, so the first
  // `depth_voxels` layers are exactly the solid voxels whose centre is within
  // (depth_voxels - 0.5) edges of the face. Compare squared distances (no sqrt);
  // the epsilon absorbs FP noise at the layer boundary (depth 1 -> 0.5 h, the
  // M1.6 half-voxel threshold).
  const double h = grid.spacing;
  const double thr = (static_cast<double>(depth_voxels) - 0.5) * h;
  const double thr2 = thr * thr;
  const double eps = 1e-9 * h * h;

  std::size_t selected = 0;
  for (int k = 0; k < grid.nz; ++k) {
    for (int j = 0; j < grid.ny; ++j) {
      for (int i = 0; i < grid.nx; ++i) {
        if (!grid.solid(i, j, k)) continue;  // mask only material voxels
        const Vec3 centre = grid.voxel_center(i, j, k);
        bool against = false;
        for (std::size_t t = 0;
             t < model.mesh.triangles.size() && !against; ++t) {
          if (model.triangle_face[t] != face_id) continue;
          const auto& tri = model.mesh.triangles[t];
          const Vec3& a = model.mesh.vertices[static_cast<std::size_t>(tri[0])];
          const Vec3& b = model.mesh.vertices[static_cast<std::size_t>(tri[1])];
          const Vec3& c = model.mesh.vertices[static_cast<std::size_t>(tri[2])];
          if (point_tri_dist2(centre, a, b, c) <= thr2 + eps) against = true;
        }
        if (against) {
          mask[grid.index(i, j, k)] = mask_value;
          ++selected;
        }
      }
    }
  }
  return selected;
}

}  // namespace topopt
