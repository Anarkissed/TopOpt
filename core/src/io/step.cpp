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
  for (TopExp_Explorer e(shape, TopAbs_FACE); e.More(); e.Next()) {
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
    }
  }

  model.mesh = welder.take();
  if (model.mesh.empty())
    throw StepError("STEP tessellation produced no triangles: " + path);
  return model;
}

}  // namespace topopt
