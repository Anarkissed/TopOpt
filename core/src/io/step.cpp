#include "topopt/step.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <fstream>
#include <map>
#include <set>
#include <cstdio>
#include <stdexcept>
#include <utility>

#include <BRepAdaptor_Surface.hxx>
#include <BRepGProp.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepTools.hxx>
#include <BRep_Tool.hxx>
#include <GProp_GProps.hxx>
#include <GeomAbs_SurfaceType.hxx>
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
#include <gp_Ax1.hxx>
#include <gp_Cylinder.hxx>
#include <gp_Dir.hxx>
#include <gp_Pln.hxx>
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

// One tessellation of `shape`: BRepMesh writes a Poly_Triangulation into each face,
// the per-face triangulations are welded into one mesh, and every triangle records
// its 0-based face id in TopExp order (ROADMAP M1.6). Faces with no triangulation
// still consume an id (they own zero triangles).
struct Tessellated {
  TriangleMesh mesh;
  std::vector<int> triangle_face;  // parallel to mesh.triangles
};

Tessellated tessellate(const TopoDS_Shape& shape, double linear, double angular) {
  BRepMesh_IncrementalMesh mesher(shape, linear, /*isRelative=*/Standard_False, angular,
                                  /*isInParallel=*/Standard_True);
  mesher.Perform();
  VertexWelder welder;
  Tessellated out;
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
      out.triangle_face.push_back(face_id);
    }
  }
  out.mesh = welder.take();
  return out;
}

// T1: drop every triangle whose welded corners repeat (zero area). Vertices are kept
// as they are; kept triangles keep their order and their face id.
int drop_repeated_index_triangles(Tessellated& t) {
  int dropped = 0;
  std::size_t w = 0;
  for (std::size_t i = 0; i < t.mesh.triangles.size(); ++i) {
    const auto& tr = t.mesh.triangles[i];
    if (tr[0] == tr[1] || tr[1] == tr[2] || tr[0] == tr[2]) { ++dropped; continue; }
    t.mesh.triangles[w] = tr;
    t.triangle_face[w] = t.triangle_face[i];
    ++w;
  }
  t.mesh.triangles.resize(w);
  t.triangle_face.resize(w);
  return dropped;
}

// Closed and consistently wound: every directed edge appears once and its reverse
// once. A folded or overlapping triangulation fails this even when it closes.
bool closed_and_oriented(const TriangleMesh& m) {
  if (m.triangles.empty()) return false;
  std::map<std::pair<int, int>, int> directed;
  for (const auto& t : m.triangles)
    for (int k = 0; k < 3; ++k) ++directed[{t[k], t[(k + 1) % 3]}];
  for (const auto& kv : directed) {
    if (kv.second != 1) return false;
    const auto rev = directed.find({kv.first.second, kv.first.first});
    if (rev == directed.end() || rev->second != 1) return false;
  }
  return true;
}

// A repair pass is kept only if the mesh is closed, consistently oriented, encloses
// positive volume and keeps every face in `wanted` (the app's rule, StepMeshRepair).
bool repair_accepted(const Tessellated& t, const std::set<int>& wanted) {
  if (t.mesh.triangles.empty() || !check_watertight(t.mesh).watertight ||
      !closed_and_oriented(t.mesh) || !(signed_volume(t.mesh) > 0.0))
    return false;
  const std::set<int> present(t.triangle_face.begin(), t.triangle_face.end());
  return std::includes(present.begin(), present.end(), wanted.begin(), wanted.end());
}

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
  // Per-face surface classification (M6.2 geometric face selection): one
  // StepFaceInfo per face, in the same TopExp order as triangle_face below.
  // BRepAdaptor_Surface sees through the face's trimming to the underlying
  // surface type; only the classes the job schema selects on are distinguished.
  for (TopExp_Explorer e(shape, TopAbs_FACE); e.More(); e.Next()) {
    ++model.face_count;
    const BRepAdaptor_Surface surf(TopoDS::Face(e.Current()),
                                   /*restriction=*/Standard_False);
    StepFaceInfo info;
    switch (surf.GetType()) {
      case GeomAbs_Plane: {
        info.kind = StepSurfaceKind::Plane;
        const gp_Pln pln = surf.Plane();
        const gp_Pnt o = pln.Location();
        // The plane's parametric normal; flip it for a REVERSED face so the
        // stored normal points OUT of the solid, matching the outward
        // tessellation winding step.cpp already establishes below.
        gp_Dir n = pln.Axis().Direction();
        if (e.Current().Orientation() == TopAbs_REVERSED) n.Reverse();
        info.plane_origin = Vec3{o.X(), o.Y(), o.Z()};
        info.plane_normal = Vec3{n.X(), n.Y(), n.Z()};
        break;
      }
      case GeomAbs_Cylinder: {
        info.kind = StepSurfaceKind::Cylinder;
        const gp_Cylinder cyl = surf.Cylinder();
        info.cylinder_radius_mm = cyl.Radius();
        const gp_Ax1 axis = cyl.Axis();
        const gp_Pnt p = axis.Location();
        const gp_Dir d = axis.Direction();  // already unit
        info.axis_point = Vec3{p.X(), p.Y(), p.Z()};
        info.axis_dir = Vec3{d.X(), d.Y(), d.Z()};
        break;
      }
      default:
        info.kind = StepSurfaceKind::Other;
        break;
    }
    model.faces.push_back(info);
  }

  GProp_GProps props;
  BRepGProp::VolumeProperties(shape, props);
  model.brep_volume = props.Mass();

  Tessellated t = tessellate(shape, tess.linear_deflection, tess.angular_deflection);
  // STEP MESH REPAIR (his 2040 Extrusion Stand, 2026-10-29: the app closed it since
  // 2026-10-23 with StepMeshRepair.swift, the worker refused it "not watertight").
  // A valid B-rep can tessellate with cracks: (T1) a pole of a degenerated edge (a
  // sphere, or three fillets meeting) welds into a repeated-index sliver; (T2) a face
  // whose wire has edges far below the deflection meshes with a hole. Only a
  // NOT-watertight tessellation reaches this, so every watertight import is untouched.
  if (!t.mesh.empty() && !check_watertight(t.mesh).watertight) {
    Tessellated t1 = t;
    const int dropped = drop_repeated_index_triangles(t1);
    // Every face that owns a triangle with area must keep one.
    const std::set<int> wanted(t1.triangle_face.begin(), t1.triangle_face.end());
    if (repair_accepted(t1, wanted)) {
      std::fprintf(stderr, "[step] mesh repaired: %d pole sliver(s) dropped (%s)\n", dropped,
                   path.c_str());
      t = std::move(t1);
    } else {
      for (const double fraction : {0.5, 0.25}) {
        const double d = tess.linear_deflection * fraction;
        BRepTools::Clean(shape);  // force BRepMesh to mesh again, finer
        Tessellated tf = tessellate(shape, d, tess.angular_deflection);
        const int n = drop_repeated_index_triangles(tf);
        if (!repair_accepted(tf, wanted)) continue;
        std::fprintf(stderr, "[step] mesh repaired: re-meshed at %.3g mm, %d pole sliver(s) dropped (%s)\n",
                     d, n, path.c_str());
        t = std::move(tf);
        break;
      }
    }
  }
  model.mesh = std::move(t.mesh);
  model.triangle_face = std::move(t.triangle_face);
  if (model.mesh.empty())
    throw StepError("STEP tessellation produced no triangles: " + path);
  return model;
}


}  // namespace topopt
