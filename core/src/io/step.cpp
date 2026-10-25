#include "topopt/step.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <fstream>
#include <map>
#include <stdexcept>
#include <utility>
#include <vector>

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

  // Tessellate: BRepMesh writes a Poly_Triangulation into each face. The
  // constructor performs the meshing at the requested linear/angular deflection.
  //
  // ★ C2 B0, item 15 of the Flexible core list (2026-10-24). Two clean-ups that the
  // mesh path's weld_and_clean (part.cpp) already does, or that BRepMesh does not
  // report:
  //  (a) REPEATED-CORNER triangles are dropped. A fillet-corner face (a sphere
  //      octant with a degenerated edge) gets two BRepMesh nodes at its pole, both
  //      at one 3-D point. They weld into one vertex, and a triangle on both becomes
  //      (a, a, b): zero area, one self-edge and one 4-use edge, so the part is not
  //      watertight. His four rig parts had 8 / 4 / 10 / 2 of them.
  //  (b) A FACE THAT COMES OUT OPEN (an edge not used exactly twice, once the slivers
  //      are gone) re-meshes the WHOLE shape finer: half the deflection, at most two
  //      tries. It is the whole shape because each face's boundary is discretised on
  //      the edges it shares with its neighbours; re-meshing one face alone would
  //      crack them. The attempt with the fewest open faces is kept, the original on
  //      a tie, and whatever is still open is REPORTED (`open_faces`), never silently.
  //      BRepMesh reported no error on his 2040 Stand's face 16.
  // A part with neither defect takes exactly the path it always did.
  struct Meshed {
    TriangleMesh mesh;
    std::vector<int> triangle_face;
    int dropped = 0;
    std::vector<int> open;
  };
  auto mesh_at = [&](double linear) {
    BRepMesh_IncrementalMesh mesher(shape, linear,
                                    /*isRelative=*/Standard_False,
                                    tess.angular_deflection,
                                    /*isInParallel=*/Standard_True);
    mesher.Perform();
    Meshed out;
    VertexWelder welder;
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
        if (ia == ib || ib == ic || ia == ic) {  // (a): a repeated corner
          ++out.dropped;
          continue;
        }
        welder.add_triangle(ia, ib, ic);
        out.triangle_face.push_back(face_id);
      }
    }
    out.mesh = welder.take();
    out.open = step_open_faces(out.mesh, out.triangle_face);
    return out;
  };

  Meshed best = mesh_at(tess.linear_deflection);
  if (!best.open.empty()) {
    double linear = tess.linear_deflection;
    for (int attempt = 0; attempt < 2 && !best.open.empty(); ++attempt) {
      linear *= 0.5;
      BRepTools::Clean(shape);  // drop the old triangulation, or BRepMesh keeps it
      Meshed finer = mesh_at(linear);
      if (finer.open.size() < best.open.size()) {
        best = std::move(finer);
        model.remeshed_at_linear_deflection = linear;
      }
    }
  }
  model.dropped_repeated_corner_triangles = best.dropped;
  model.open_faces = best.open;
  model.mesh = std::move(best.mesh);
  model.triangle_face = std::move(best.triangle_face);
  if (model.mesh.empty())
    throw StepError("STEP tessellation produced no triangles: " + path);
  return model;
}



std::vector<int> step_open_faces(const TriangleMesh& mesh, const std::vector<int>& triangle_face) {
  // Count every undirected edge's uses; a closed 2-manifold uses each exactly twice.
  std::map<std::pair<int, int>, int> use;
  for (const auto& t : mesh.triangles)
    for (int k = 0; k < 3; ++k) {
      int a = t[static_cast<std::size_t>(k)], b = t[static_cast<std::size_t>((k + 1) % 3)];
      if (a > b) std::swap(a, b);
      ++use[{a, b}];
    }
  std::vector<int> open;
  for (std::size_t i = 0; i < mesh.triangles.size(); ++i) {
    const auto& t = mesh.triangles[i];
    for (int k = 0; k < 3; ++k) {
      int a = t[static_cast<std::size_t>(k)], b = t[static_cast<std::size_t>((k + 1) % 3)];
      if (a > b) std::swap(a, b);
      if (use[{a, b}] != 2) {
        open.push_back(i < triangle_face.size() ? triangle_face[i] : -1);
        break;
      }
    }
  }
  std::sort(open.begin(), open.end());
  open.erase(std::unique(open.begin(), open.end()), open.end());
  return open;
}

}  // namespace topopt
