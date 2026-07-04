#include "topopt/step.hpp"

#include <array>
#include <cmath>
#include <fstream>
#include <map>
#include <utility>

#include <BRepGProp.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRep_Tool.hxx>
#include <GProp_GProps.hxx>
#include <IFSelect_ReturnStatus.hxx>
#include <Poly_Triangulation.hxx>
#include <STEPControl_Reader.hxx>
#include <TopAbs_Orientation.hxx>
#include <TopAbs_ShapeEnum.hxx>
#include <TopExp_Explorer.hxx>
#include <TopLoc_Location.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Shape.hxx>
#include <gp_Pnt.hxx>
#include <gp_Trsf.hxx>

namespace topopt {
namespace {

// Quantized vertex weld. OCCT triangulates each B-rep face independently, so a
// vertex on an edge shared by two faces (and the duplicated seam nodes of a
// periodic face like a cylinder's lateral surface) is emitted once per face.
// Snapping coordinates to a fine grid — 1e-6 mm, far below any tessellation
// deflection but far above the ~1e-12 numeric noise between genuinely coincident
// nodes — merges those duplicates into one shared vertex, which is what makes
// the surface a closed 2-manifold for check_watertight. Distinct vertices are at
// least a deflection apart (>> the grid), so they never collide.
class VertexWelder {
 public:
  int add(const gp_Pnt& p) {
    const std::array<long long, 3> key{Quantize(p.X()), Quantize(p.Y()),
                                       Quantize(p.Z())};
    auto it = index_of_.find(key);
    if (it != index_of_.end()) return it->second;
    const int idx = static_cast<int>(mesh_.vertices.size());
    index_of_.emplace(key, idx);
    mesh_.vertices.push_back(Vec3{p.X(), p.Y(), p.Z()});
    return idx;
  }

  void add_triangle(int a, int b, int c) {
    mesh_.triangles.push_back({a, b, c});
  }

  TriangleMesh take() { return std::move(mesh_); }

 private:
  static long long Quantize(double v) {
    return static_cast<long long>(std::llround(v / kEps));
  }
  static constexpr double kEps = 1e-6;

  std::map<std::array<long long, 3>, int> index_of_;
  TriangleMesh mesh_;
};

}  // namespace

StepModel import_step_file(const std::string& path,
                           const StepTessellation& tess) {
  // Report a missing/unreadable file clearly before handing it to OCCT (whose
  // own read diagnostics are terse and do not name the path).
  {
    std::ifstream probe(path, std::ios::binary);
    if (!probe) throw StepError("cannot open STEP file: " + path);
  }

  STEPControl_Reader reader;
  if (reader.ReadFile(path.c_str()) != IFSelect_RetDone)
    throw StepError("not a readable STEP file: " + path);
  reader.TransferRoots();
  const TopoDS_Shape shape = reader.OneShape();
  if (shape.IsNull())
    throw StepError("STEP file contains no shape: " + path);

  StepModel model;

  // Exact B-rep measures — independent of tessellation.
  for (TopExp_Explorer e(shape, TopAbs_SOLID); e.More(); e.Next())
    ++model.solid_count;
  if (model.solid_count == 0)
    throw StepError("STEP file contains no solid: " + path);
  for (TopExp_Explorer e(shape, TopAbs_FACE); e.More(); e.Next())
    ++model.face_count;

  GProp_GProps props;
  BRepGProp::VolumeProperties(shape, props);
  model.brep_volume = props.Mass();

  // Tessellate: BRepMesh writes a Poly_Triangulation into each face. The
  // constructor performs the meshing at the requested linear/angular deflection.
  BRepMesh_IncrementalMesh mesher(shape, tess.linear_deflection,
                                  /*isRelative=*/Standard_False,
                                  tess.angular_deflection,
                                  /*isInParallel=*/Standard_True);
  mesher.Perform();

  VertexWelder welder;
  std::vector<int> triangle_face;  // parallel to the welded triangles
  // `face_id` advances once per B-rep face in TopExp order, matching the
  // face_count enumeration above, so every triangle records the 0-based face
  // it came from (ROADMAP M1.6 selects voxels by that id). Faces with no
  // triangulation still consume an id (they own zero triangles).
  int face_id = 0;
  for (TopExp_Explorer e(shape, TopAbs_FACE); e.More(); e.Next(), ++face_id) {
    const TopoDS_Face face = TopoDS::Face(e.Current());
    TopLoc_Location loc;
    const Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(face, loc);
    if (tri.IsNull()) continue;
    const gp_Trsf trsf = loc.Transformation();
    // A REVERSED face's outward direction is opposite its parametric normal, so
    // flip the winding to keep every triangle facing outward. With consistent
    // outward winding, signed_volume (divergence theorem) returns +volume.
    const bool reversed = face.Orientation() == TopAbs_REVERSED;
    for (int i = 1; i <= tri->NbTriangles(); ++i) {
      int a = 0, b = 0, c = 0;
      tri->Triangle(i).Get(a, b, c);
      if (reversed) std::swap(b, c);
      const int ia = welder.add(tri->Node(a).Transformed(trsf));
      const int ib = welder.add(tri->Node(b).Transformed(trsf));
      const int ic = welder.add(tri->Node(c).Transformed(trsf));
      welder.add_triangle(ia, ib, ic);
      triangle_face.push_back(face_id);
    }
  }

  model.mesh = welder.take();
  model.triangle_face = std::move(triangle_face);
  if (model.mesh.empty())
    throw StepError("STEP tessellation produced no triangles: " + path);
  return model;
}

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

}  // namespace topopt
