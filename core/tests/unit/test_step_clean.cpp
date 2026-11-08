// C2 B0, item 15 of the Flexible core list (2026-10-24): the STEP import drops
// repeated-corner triangles, and re-meshes when a face comes out open.
//
// core/src/io/step.cpp meshed the shape once (BRepMesh_IncrementalMesh at 0.1 mm), welded on a
// 1e-6 mm grid, and handed the mesh on with NO clean-up. Two defects followed on his four
// squish-rig parts, all of which pass Fusion's Validate:
//
// (a) POLE SLIVERS. A fillet-corner face (a sphere octant with a degenerated edge) gets two
//     BRepMesh nodes at its pole, both at one 3-D point. A triangle on both nodes welds to
//     (a, a, b): zero area, one self-edge and one 4-use edge. The mesh path's weld_and_clean
//     (part.cpp) drops exactly these; the STEP path kept them. A filleted box reproduces it:
//     8 corners, 8 slivers, 16 bad edges, not watertight.
// (b) ONE BROKEN FACE. 2040 Extrusion Stand face 16 (a plane with 0.01-0.05 mm wire edges) came
//     back at 0.1 mm with a 4-edge hole and overlapping triangles, and BRepMesh reported no
//     error. The import now finds every face that touches an edge not used exactly twice, and
//     re-meshes the shape finer (half the deflection, at most two tries). Whatever is still open
//     is REPORTED by face id, never silently. The re-mesh path itself waits on his file (Q5): no
//     synthetic shape here makes BRepMesh open a face. Its detector is tested on a hand-built mesh.
//
// A part with neither defect is unchanged: same triangles, same order, nothing re-meshed.

#include "topopt/mesh.hpp"
#include "topopt/step.hpp"

#include <BRepFilletAPI_MakeFillet.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <STEPControl_Writer.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>

#include <cmath>
#include <cstdio>
#include <map>
#include <string>
#include <utility>
#include <vector>

using namespace topopt;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                            \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

static int repeated_corners(const TriangleMesh& m) {
  int n = 0;
  for (const auto& t : m.triangles) n += (t[0] == t[1] || t[1] == t[2] || t[0] == t[2]);
  return n;
}

static int bad_edges(const TriangleMesh& m) {
  std::map<std::pair<int, int>, int> use;
  for (const auto& t : m.triangles)
    for (int k = 0; k < 3; ++k) {
      int a = t[k], b = t[(k + 1) % 3];
      if (a > b) std::swap(a, b);
      ++use[{a, b}];
    }
  int bad = 0;
  for (const auto& kv : use) bad += kv.second != 2;
  return bad;
}

int main() {
  // (a) A FILLETED BOX: 8 sphere-octant corners, each with a pole. It is written to STEP and
  // imported through core's own path.
  {
    BRepPrimAPI_MakeBox box(40, 30, 20);
    BRepFilletAPI_MakeFillet f(box.Shape());
    for (TopExp_Explorer e(box.Shape(), TopAbs_EDGE); e.More(); e.Next()) f.Add(3.0, TopoDS::Edge(e.Current()));
    f.Build();
    const std::string path = std::string(STEP_CLEAN_TMP_DIR) + "/filleted_box.step";
    STEPControl_Writer w;
    w.Transfer(f.Shape(), STEPControl_AsIs);
    CHECK(w.Write(path.c_str()) == IFSelect_RetDone, "the filleted box writes to STEP");
    const StepModel m = import_step_file(path);
    std::printf("  filleted box: %zu triangles, %d dropped, %d bad edges, re-meshed at %g\n", m.mesh.triangles.size(),
                m.dropped_repeated_corner_triangles, bad_edges(m.mesh), m.remeshed_at_linear_deflection);
    CHECK(repeated_corners(m.mesh) == 0, "item 15(a): no repeated-corner triangle survives the import");
    CHECK(m.dropped_repeated_corner_triangles == 8, "item 15(a): one sliver per corner pole is dropped (8)");
    CHECK(bad_edges(m.mesh) == 0 && check_watertight(m.mesh).watertight, "item 15(a): the filleted box is watertight");
    CHECK(m.triangle_face.size() == m.mesh.triangles.size(), "item 15(a): triangle_face stays parallel");
    CHECK(m.remeshed_at_linear_deflection == 0.0 && m.open_faces.empty(),
          "item 15: slivers alone never trigger a re-mesh (the negative control)");
    CHECK(std::fabs(signed_volume(m.mesh) - m.brep_volume) < 0.01 * m.brep_volume,
          "item 15(a): the mesh volume is the B-rep's (within 1 %)");
  }

  // (b) THE DETECTOR, on a hand-built mesh: a cube (faces 0..5, two triangles each) with one
  // triangle of face 2 missing. The faces touching an edge that is not used exactly twice are
  // reported, sorted.
  {
    TriangleMesh m;
    m.vertices = {{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0}, {0, 0, 1}, {1, 0, 1}, {1, 1, 1}, {0, 1, 1}};
    m.triangles = {{0, 2, 1}, {0, 3, 2},   // face 0: bottom
                   {4, 5, 6}, {4, 6, 7},   // face 1: top
                   {0, 1, 5}, {0, 5, 4},   // face 2: -Y
                   {1, 2, 6}, {1, 6, 5},   // face 3: +X
                   {2, 3, 7}, {2, 7, 6},   // face 4: +Y
                   {3, 0, 4}, {3, 4, 7}};  // face 5: -X
    std::vector<int> tf = {0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5};
    CHECK(step_open_faces(m, tf).empty(), "item 15(b): a closed cube has no open face");
    m.triangles.erase(m.triangles.begin() + 4);  // face 2's {0, 1, 5}
    tf.erase(tf.begin() + 4);
    // its edges: 0-1 (bottom's), 1-5 (+X's), 5-0 (face 2's own diagonal)
    CHECK(step_open_faces(m, tf) == std::vector<int>({0, 2, 3}),
          "item 15(b): a hole in face 2 names the faces on its rim, sorted (0, 2, 3)");
  }

  // (c) A PART WITH NEITHER DEFECT is untouched: the plain box fixture keeps its 12 triangles,
  // nothing is dropped, nothing is re-meshed.
  {
    const StepModel m = import_step_file(std::string(STEP_FIXTURE_DIR) + "/cube.step");
    CHECK(m.mesh.triangles.size() == 12 && m.dropped_repeated_corner_triangles == 0 &&
              m.remeshed_at_linear_deflection == 0.0 && m.open_faces.empty(),
          "item 15: cube.step is unchanged (12 triangles, nothing dropped or re-meshed)");
  }

  std::printf("test_step_clean: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
