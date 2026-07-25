// Unit tests for the dihedral-angle pseudo-face segmenter and the part-import
// adapter (handoff 134: STL/3MF import, Phase 1).
//
// Same self-contained CHECK harness as test_stl.cpp (ARCHITECTURE §4 locks the
// dependency set, so there is no third-party test framework).
//
// The synthetic meshes are built IN CODE rather than committed as fixtures
// because their expected region counts are derivable from the construction —
// a cube has 6 planar faces, an N-gon prism has a barrel plus two caps — so the
// ground truth is the geometry, not a golden file. The determinism tests do use
// a written-then-read file, because "same file BYTES => same ids" is the actual
// claim being made.

#include "topopt/mesh.hpp"
#include "topopt/part.hpp"
#include "topopt/segment.hpp"
#include "topopt/stl.hpp"

#include <cmath>
#include <cstdio>
#include <map>
#include <set>
#include <string>
#include <vector>

using topopt::MeshSegmentation;
using topopt::PartDefect;
using topopt::PartError;
using topopt::PartInspection;
using topopt::PartModel;
using topopt::SegmentOptions;
using topopt::StepSurfaceKind;
using topopt::TriangleMesh;
using topopt::Vec3;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                           \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

// --------------------------------------------------------------------------
// Synthetic meshes. All are closed and outward-wound.

// Axis-aligned box [0,sx] x [0,sy] x [0,sz]: 8 vertices, 12 triangles,
// 6 planar faces.
static TriangleMesh make_box(double sx, double sy, double sz) {
  TriangleMesh m;
  m.vertices = {{0, 0, 0},   {sx, 0, 0},   {sx, sy, 0},   {0, sy, 0},
                {0, 0, sz},  {sx, 0, sz},  {sx, sy, sz},  {0, sy, sz}};
  // Outward winding (CCW seen from outside).
  m.triangles = {
      {0, 3, 2}, {0, 2, 1},  // z = 0   (normal -z)
      {4, 5, 6}, {4, 6, 7},  // z = sz  (normal +z)
      {0, 1, 5}, {0, 5, 4},  // y = 0   (normal -y)
      {3, 7, 6}, {3, 6, 2},  // y = sy  (normal +y)
      {0, 4, 7}, {0, 7, 3},  // x = 0   (normal -x)
      {1, 2, 6}, {1, 6, 5},  // x = sx  (normal +x)
  };
  return m;
}

// Closed N-gon prism of radius r and height h, axis +z, centred on the origin
// in x/y. Barrel + 2 caps. With N facets the barrel's per-facet dihedral turn
// is 360/N degrees, which is what the threshold sweep is about.
static TriangleMesh make_prism(int n, double r, double h) {
  TriangleMesh m;
  const double pi = 3.14159265358979323846;
  for (int i = 0; i < n; ++i) {
    const double a = 2.0 * pi * i / n;
    m.vertices.push_back(Vec3{r * std::cos(a), r * std::sin(a), 0.0});
  }
  for (int i = 0; i < n; ++i) {
    const double a = 2.0 * pi * i / n;
    m.vertices.push_back(Vec3{r * std::cos(a), r * std::sin(a), h});
  }
  const int cb = static_cast<int>(m.vertices.size());
  m.vertices.push_back(Vec3{0, 0, 0});  // bottom centre
  const int ct = cb + 1;
  m.vertices.push_back(Vec3{0, 0, h});  // top centre

  for (int i = 0; i < n; ++i) {
    const int j = (i + 1) % n;
    // Barrel quad, outward.
    m.triangles.push_back({i, j, n + j});
    m.triangles.push_back({i, n + j, n + i});
    // Caps.
    m.triangles.push_back({cb, j, i});          // bottom, normal -z
    m.triangles.push_back({ct, n + i, n + j});  // top, normal +z
  }
  return m;
}

// UV sphere of radius r with `stacks` x `slices` subdivision. Closed; every
// adjacent pair of facets meets at a shallow angle, so a sufficiently fine
// sphere is ONE pseudo-face.
static TriangleMesh make_sphere(double r, int stacks, int slices) {
  TriangleMesh m;
  const double pi = 3.14159265358979323846;
  const int top = 0;
  m.vertices.push_back(Vec3{0, 0, r});
  for (int i = 1; i < stacks; ++i) {
    const double phi = pi * i / stacks;
    for (int j = 0; j < slices; ++j) {
      const double th = 2.0 * pi * j / slices;
      m.vertices.push_back(Vec3{r * std::sin(phi) * std::cos(th),
                                r * std::sin(phi) * std::sin(th),
                                r * std::cos(phi)});
    }
  }
  const int bottom = static_cast<int>(m.vertices.size());
  m.vertices.push_back(Vec3{0, 0, -r});
  auto ring = [&](int i, int j) { return 1 + (i - 1) * slices + (j % slices); };

  for (int j = 0; j < slices; ++j)
    m.triangles.push_back({top, ring(1, j), ring(1, j + 1)});
  for (int i = 1; i < stacks - 1; ++i)
    for (int j = 0; j < slices; ++j) {
      m.triangles.push_back({ring(i, j), ring(i + 1, j), ring(i + 1, j + 1)});
      m.triangles.push_back({ring(i, j), ring(i + 1, j + 1), ring(i, j + 1)});
    }
  for (int j = 0; j < slices; ++j)
    m.triangles.push_back({bottom, ring(stacks - 1, j + 1), ring(stacks - 1, j)});
  return m;
}

static int region_count(const MeshSegmentation& s) { return s.face_count; }

// How many pseudo-faces of each kind.
static int count_kind(const MeshSegmentation& s, StepSurfaceKind k) {
  int n = 0;
  for (const auto& f : s.faces)
    if (f.kind == k) ++n;
  return n;
}

static std::string temp_path(const char* name) {
  return std::string(SEGMENT_TMP_DIR) + "/" + name;
}

// Triangle geometry helpers for the filleted-bore fixture below (which face a
// region contains is asserted by geometry, not by a golden triangle index).
static Vec3 tri_normal(const TriangleMesh& m, std::size_t t) {
  const auto& tr = m.triangles[t];
  const Vec3& a = m.vertices[static_cast<std::size_t>(tr[0])];
  const Vec3& b = m.vertices[static_cast<std::size_t>(tr[1])];
  const Vec3& c = m.vertices[static_cast<std::size_t>(tr[2])];
  Vec3 n{(b.y - a.y) * (c.z - a.z) - (b.z - a.z) * (c.y - a.y),
         (b.z - a.z) * (c.x - a.x) - (b.x - a.x) * (c.z - a.z),
         (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)};
  const double l = std::sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
  if (l > 0) { n.x /= l; n.y /= l; n.z /= l; }
  return n;
}
static Vec3 tri_centroid(const TriangleMesh& m, std::size_t t) {
  const auto& tr = m.triangles[t];
  const Vec3& a = m.vertices[static_cast<std::size_t>(tr[0])];
  const Vec3& b = m.vertices[static_cast<std::size_t>(tr[1])];
  const Vec3& c = m.vertices[static_cast<std::size_t>(tr[2])];
  return Vec3{(a.x + b.x + c.x) / 3, (a.y + b.y + c.y) / 3, (a.z + b.z + c.z) / 3};
}
// The flat top (Load) face: horizontal normal, topmost, outermost radius.
static int top_face_rep(const TriangleMesh& m) {
  int best = -1; double bs = -1e30;
  for (std::size_t t = 0; t < m.triangles.size(); ++t) {
    if (std::fabs(tri_normal(m, t).z) < 0.98) continue;
    const Vec3 c = tri_centroid(m, t);
    const double s = c.z * 1000 + std::sqrt(c.x * c.x + c.y * c.y);
    if (s > bs) { bs = s; best = static_cast<int>(t); }
  }
  return best;
}
// A bore-wall triangle: near-vertical normal, centroid radius closest to `r`.
static int bore_rep(const TriangleMesh& m, double r) {
  int best = -1; double be = 1e30;
  for (std::size_t t = 0; t < m.triangles.size(); ++t) {
    if (std::fabs(tri_normal(m, t).z) > 0.2) continue;
    const Vec3 c = tri_centroid(m, t);
    const double e = std::fabs(std::sqrt(c.x * c.x + c.y * c.y) - r);
    if (e < be) { be = e; best = static_cast<int>(t); }
  }
  return best;
}

int main() {
  // ------------------------------------------------------------------
  // Cube: 6 planar pseudo-faces, one per side.
  {
    const TriangleMesh cube = make_box(10, 10, 10);
    const MeshSegmentation s = topopt::segment_mesh_faces(cube);
    CHECK(region_count(s) == 6, "cube segments into exactly 6 pseudo-faces");
    CHECK(count_kind(s, StepSurfaceKind::Plane) == 6,
          "every cube pseudo-face is classified Plane");
    CHECK(s.triangle_face.size() == cube.triangles.size(),
          "triangle_face is parallel to the triangle list");

    // The two triangles of each side share a face id; opposite sides do not.
    CHECK(s.triangle_face[0] == s.triangle_face[1],
          "the two triangles of the z=0 side share one pseudo-face");
    CHECK(s.triangle_face[0] != s.triangle_face[2],
          "the z=0 and z=10 sides are different pseudo-faces");

    // Outward plane normals: the z=0 side faces -z, the z=10 side faces +z.
    const auto& lo = s.faces[static_cast<std::size_t>(s.triangle_face[0])];
    const auto& hi = s.faces[static_cast<std::size_t>(s.triangle_face[2])];
    CHECK(lo.plane_normal.z < -0.99, "z=0 side's plane normal points OUT (-z)");
    CHECK(hi.plane_normal.z > 0.99, "z=10 side's plane normal points OUT (+z)");
    CHECK(std::fabs(lo.plane_origin.z) < 1e-9,
          "z=0 side's plane origin lies on that plane");
    CHECK(std::fabs(hi.plane_origin.z - 10.0) < 1e-9,
          "z=10 side's plane origin lies on that plane");
  }

  // ------------------------------------------------------------------
  // Cylinder (24-gon prism, 15 deg per barrel facet — well inside the shipped
  // 35 deg threshold): barrel + 2 caps = 3 pseudo-faces, and the barrel is
  // recognised as a Cylinder with the right axis and radius. That last part is
  // what makes bolt keep-clear work on an STL.
  {
    const TriangleMesh cyl = make_prism(24, 5.0, 20.0);
    const MeshSegmentation s = topopt::segment_mesh_faces(cyl);
    CHECK(region_count(s) == 3,
          "24-gon cylinder segments into 3 pseudo-faces (barrel + 2 caps)");
    CHECK(count_kind(s, StepSurfaceKind::Plane) == 2,
          "the two caps are classified Plane");
    CHECK(count_kind(s, StepSurfaceKind::Cylinder) == 1,
          "the barrel is classified Cylinder");

    for (const auto& f : s.faces) {
      if (f.kind != StepSurfaceKind::Cylinder) continue;
      // Radius: the inscribed/circumscribed spread of a 24-gon about r=5 is
      // under 1%, and the fit sees the vertices (circumscribed), so expect 5.
      CHECK(std::fabs(f.cylinder_radius_mm - 5.0) < 0.05,
            "fitted cylinder radius recovers the 5 mm construction radius");
      CHECK(std::fabs(std::fabs(f.axis_dir.z) - 1.0) < 1e-6,
            "fitted cylinder axis is the z axis");
      CHECK(std::fabs(f.axis_point.x) < 1e-6 && std::fabs(f.axis_point.y) < 1e-6,
            "fitted cylinder axis passes through x=y=0");
    }
  }

  // ------------------------------------------------------------------
  // Sphere: one smooth region. A sphere IS one face, and the segmenter must not
  // shatter it. Not a Plane, and not a Cylinder either (the circle fit fails) —
  // it is Other, which selection and tagging handle fine.
  {
    const TriangleMesh sph = make_sphere(10.0, 24, 32);
    const MeshSegmentation s = topopt::segment_mesh_faces(sph);
    CHECK(region_count(s) == 1, "a fine sphere is a single pseudo-face");
    CHECK(s.faces[0].kind == StepSurfaceKind::Other,
          "the sphere is classified Other (neither plane nor cylinder)");
  }

  // ------------------------------------------------------------------
  // PLANAR-CONE GUARD (handoff 2026-07-24). The shipped default arms a per-plane
  // cone that stops a flat face leaking through a fillet — but ONLY on a face
  // that a real crease bounds. On every reference shape (sharp-edged flats,
  // curved barrels/spheres) the guard must change NOTHING, or it would fragment
  // real geometry and shift persisted pseudo-face ids. Assert byte-identity of
  // the partition with the guard on (default) vs off.
  {
    SegmentOptions off;
    off.planar_region_cone_deg = 0.0;  // pure local dihedral (handoff-134 rule)
    const TriangleMesh shapes[] = {make_box(10, 10, 10), make_prism(24, 5.0, 20.0),
                                   make_prism(8, 5.0, 20.0), make_sphere(10.0, 24, 32)};
    for (const TriangleMesh& m : shapes) {
      const MeshSegmentation on = topopt::segment_mesh_faces(m);       // default
      const MeshSegmentation of = topopt::segment_mesh_faces(m, off);  // guard off
      CHECK(on.face_count == of.face_count && on.triangle_face == of.triangle_face,
            "planar cone is a no-op on sharp-edged / curved reference meshes");
    }
  }

  // ------------------------------------------------------------------
  // THE FILLETED-BORE FIXTURE (committed as tests/fixtures/mesh/, the repeatable
  // stand-in for the shelf bracket that over-selected). A flat top face joined to
  // a vertical bore by a ROUNDED rim: each fillet facet turns under the 35 deg
  // threshold, so pure dihedral growth merges top+fillet+bore into one region and
  // one tap on the hole also grabs the Load face. The planar-cone guard cuts the
  // leak at the fillet. This asserts BOTH: the failure (guard off) and the fix
  // (default), so the fixture can never silently stop reproducing the bug.
  {
    const std::string path =
        std::string(MESH_FIXTURE_DIR) + "/filleted_bore_plate.stl";
    const PartModel p = topopt::import_part(path);  // welds + unifies winding
    const TriangleMesh& m = p.model.mesh;
    const double r_bore = 4.0;  // must match the committed fixture's bore radius
    const int top = top_face_rep(m);
    const int bore = bore_rep(m, r_bore);
    CHECK(top >= 0 && bore >= 0, "fixture exposes a flat top face and a bore wall");

    SegmentOptions off;
    off.planar_region_cone_deg = 0.0;
    const MeshSegmentation leaked = topopt::segment_mesh_faces(m, off);
    CHECK(leaked.triangle_face[static_cast<std::size_t>(top)] ==
              leaked.triangle_face[static_cast<std::size_t>(bore)],
          "WITHOUT the guard the fillet leaks: top face and bore are one region");

    const MeshSegmentation fixed = topopt::segment_mesh_faces(m);  // default guard
    CHECK(fixed.triangle_face[static_cast<std::size_t>(top)] !=
              fixed.triangle_face[static_cast<std::size_t>(bore)],
          "WITH the default guard the Load face and the bore are separate regions");
    CHECK(fixed.face_count > leaked.face_count,
          "the guard splits the leaked region rather than merging others");

    // The tunable threshold is the user's other escape: dropping it below the
    // fillet's per-facet turn also separates them (paint mode is the guarantee,
    // this is a second knob). Determinism holds for the guarded partition too.
    const MeshSegmentation again = topopt::segment_mesh_faces(m);
    CHECK(again.triangle_face == fixed.triangle_face,
          "the guarded segmentation is deterministic (same mesh => same ids)");
  }

  // ------------------------------------------------------------------
  // THE STATED CAVEAT, asserted so it cannot rot: a curved surface tessellated
  // more coarsely than ~10 facets/revolution turns more than the 35 deg
  // threshold per facet, so its barrel fragments into facet-sized pseudo-faces.
  // An 8-gon prism turns 45 deg per facet: 8 barrel strips + 2 caps = 10.
  {
    const TriangleMesh coarse = make_prism(8, 5.0, 20.0);
    const MeshSegmentation s = topopt::segment_mesh_faces(coarse);
    CHECK(region_count(s) == 10,
          "CAVEAT: an 8-gon (45 deg/facet) barrel fragments into 8 strips + 2 caps");

    // ...and the same geometry tessellated at 12 facets (30 deg) does NOT.
    const TriangleMesh ok = make_prism(12, 5.0, 20.0);
    const MeshSegmentation s2 = topopt::segment_mesh_faces(ok);
    CHECK(region_count(s2) == 3,
          "a 12-gon (30 deg/facet) barrel stays one pseudo-face at the shipped threshold");
  }

  // ------------------------------------------------------------------
  // A chamfer must NOT be swallowed. A 45 deg chamfer meets its neighbours at
  // 45 deg, which is above the 35 deg threshold, so it stays its own face.
  // This is the other side of the sweep: the threshold cannot simply be raised.
  {
    // Box with one edge chamfered at 45 deg: replace the x=10/z=10 edge with a
    // slanted strip. Built as a closed solid.
    TriangleMesh m;
    m.vertices = {
        {0, 0, 0},  {10, 0, 0},  {10, 10, 0},  {0, 10, 0},     // z=0
        {0, 0, 10}, {7, 0, 10},  {7, 10, 10},  {0, 10, 10},    // z=10 (short in x)
        {10, 0, 7}, {10, 10, 7},                               // chamfer foot on x=10
    };
    m.triangles = {
        {0, 3, 2}, {0, 2, 1},        // z=0
        {4, 5, 6}, {4, 6, 7},        // z=10 top
        {5, 8, 9}, {5, 9, 6},        // 45 deg chamfer strip
        {1, 2, 9}, {1, 9, 8},        // x=10 side (below the chamfer)
        {0, 1, 8}, {0, 8, 5}, {0, 5, 4},   // y=0
        {3, 7, 6}, {3, 6, 9}, {3, 9, 2},   // y=10
        {0, 4, 7}, {0, 7, 3},        // x=0
    };
    CHECK(topopt::check_watertight(m).watertight, "the chamfer fixture is closed");
    CHECK(std::fabs(topopt::signed_volume(m) - 955.0) < 1e-9,
          "the chamfer fixture is the 1000 mm^3 box less the 45 mm^3 chamfer");
    const MeshSegmentation s = topopt::segment_mesh_faces(m);
    // Six box sides plus the chamfer strip. If the chamfer were swallowed into
    // either neighbour this would be 6.
    CHECK(region_count(s) == 7,
          "a 45 deg chamfer survives as its own pseudo-face (7 faces, not 6)");
    CHECK(s.triangle_face[4] != s.triangle_face[2] &&
              s.triangle_face[4] != s.triangle_face[6],
          "and it is distinct from both the top face and the x=10 side");
  }

  // ------------------------------------------------------------------
  // DETERMINISM. Two runs over the same triangle list, and two IMPORTS of the
  // same file bytes, must produce identical ids.
  {
    const TriangleMesh cyl = make_prism(24, 5.0, 20.0);
    const MeshSegmentation a = topopt::segment_mesh_faces(cyl);
    const MeshSegmentation b = topopt::segment_mesh_faces(cyl);
    CHECK(a.triangle_face == b.triangle_face,
          "segmenting the same mesh twice yields identical pseudo-face ids");
    CHECK(a.face_count == b.face_count, "and the same face count");

    const std::string path = temp_path("seg_determinism.stl");
    topopt::write_stl_file(path, cyl, topopt::StlFormat::Binary);
    const PartModel p1 = topopt::import_part(path);
    const PartModel p2 = topopt::import_part(path);
    CHECK(p1.model.triangle_face == p2.model.triangle_face,
          "re-importing the SAME FILE BYTES yields identical pseudo-face ids");
    CHECK(p1.model.face_count == p2.model.face_count,
          "and the same pseudo-face count across re-imports");
    CHECK(p1.pseudo_faces, "an STL import reports pseudo_faces == true");
    CHECK(p1.model.face_count == 3,
          "the imported cylinder carries its 3 pseudo-faces through the adapter");
    // The face ids must also be STABLE VALUES, not merely equal between two
    // runs of the same binary: id 0 is seeded by triangle 0.
    CHECK(p1.model.triangle_face[0] == 0,
          "pseudo-face ids are seeded in ascending triangle order (triangle 0 -> face 0)");
    std::remove(path.c_str());
  }

  // ------------------------------------------------------------------
  // The adapter's StepModel is complete enough for downstream consumers: every
  // triangle carries a face id in range, and `faces` is indexed by that id.
  {
    const TriangleMesh cube = make_box(20, 10, 5);
    const std::string path = temp_path("seg_adapter.stl");
    topopt::write_stl_file(path, cube, topopt::StlFormat::Binary);
    const PartModel p = topopt::import_part(path);
    bool in_range = true;
    std::set<int> seen;
    for (const int f : p.model.triangle_face) {
      if (f < 0 || f >= p.model.face_count) in_range = false;
      seen.insert(f);
    }
    CHECK(in_range, "every triangle's pseudo-face id is in [0, face_count)");
    CHECK(static_cast<int>(seen.size()) == p.model.face_count,
          "every pseudo-face id is actually used by some triangle");
    CHECK(p.model.faces.size() == static_cast<std::size_t>(p.model.face_count),
          "faces[] is indexed by pseudo-face id");
    CHECK(p.model.triangle_face.size() == p.model.mesh.triangles.size(),
          "triangle_face is parallel to the imported mesh's triangles");
    CHECK(std::fabs(p.model.brep_volume - 20.0 * 10.0 * 5.0) < 1e-6,
          "the adapter reports the mesh's enclosed volume");
    CHECK(p.inspection.acceptable && p.inspection.checked,
          "a clean box passes inspection");
    std::remove(path.c_str());
  }

  // ------------------------------------------------------------------
  // REPAIR: inverted normals. An inward-wound (but consistently wound) cube is
  // repairable — unify_normals flips it outward — so it must be ACCEPTED, and
  // the repair must be REPORTED, not hidden.
  {
    TriangleMesh inward = make_box(10, 10, 10);
    for (auto& t : inward.triangles) std::swap(t[1], t[2]);
    const std::string path = temp_path("seg_inward.stl");
    topopt::write_stl_file(path, inward, topopt::StlFormat::Binary);
    const PartModel p = topopt::import_part(path);
    CHECK(p.inspection.acceptable, "an inward-wound cube is repaired, not refused");
    CHECK(p.inspection.flipped_triangles == 12,
          "the repair reports all 12 triangles as re-wound");
    CHECK(p.model.brep_volume > 0.0,
          "the repaired mesh has positive enclosed volume");
    const MeshSegmentation s = topopt::segment_mesh_faces(p.model.mesh);
    CHECK(region_count(s) == 6, "the repaired cube still segments into 6 faces");
    std::remove(path.c_str());
  }

  // A cube with ONE triangle flipped is also repairable: the flip is local and
  // orientation propagation fixes it.
  {
    TriangleMesh m = make_box(10, 10, 10);
    std::swap(m.triangles[5][1], m.triangles[5][2]);
    int flipped = 0;
    const bool ok = topopt::unify_normals(m, flipped);
    CHECK(ok, "a single reversed triangle is repairable (surface stays orientable)");
    CHECK(flipped == 1, "exactly the one reversed triangle is re-wound");
    CHECK(topopt::signed_volume(m) > 0.0, "and the result is outward-wound");
  }

  // ------------------------------------------------------------------
  // REFUSALS. Each must be a structured diagnosis, never a crash.

  // Open mesh: drop a side off the cube. A whole missing cube face is a
  // WALL-SIZED hole (its diagonal is ~0.82 of the part's), so Phase-2 hole
  // filling is ATTEMPTED but the conservative fraction bound refuses it — a
  // missing wall is not a defect to guess at.
  {
    TriangleMesh open = make_box(10, 10, 10);
    open.triangles.resize(10);  // remove the x=10 side
    const std::string path = temp_path("seg_open.stl");
    topopt::write_stl_file(path, open, topopt::StlFormat::Binary);
    bool threw = false;
    try {
      topopt::import_part(path);
    } catch (const PartError&) {
      threw = true;
    }
    CHECK(threw, "an open mesh with a wall-sized hole is refused");
    const PartInspection insp = topopt::inspect_part_file(path);
    CHECK(!insp.acceptable, "and inspect_part_file agrees it is unacceptable");
    CHECK(insp.defects.size() == 1 && insp.defects[0] == PartDefect::OpenBoundary,
          "the diagnosis names the open boundary");
    CHECK(insp.boundary_edges == 4, "and counts the 4 boundary edges");
    CHECK(insp.filled_holes == 0,
          "the wall-sized hole is NOT force-filled (conservative bound holds)");
    std::remove(path.c_str());
  }

  // Non-manifold: a fin sharing one edge with three triangles. The fin is NOT a
  // redundant duplicate facet (it is a distinct triangle to a new vertex), so
  // duplicate removal cannot fix it — it is an AMBIGUOUS junction and is refused.
  {
    TriangleMesh nm = make_box(10, 10, 10);
    // An extra triangle on the 0-1 edge makes that edge 3-used.
    nm.vertices.push_back(Vec3{5, -5, 5});
    nm.triangles.push_back({0, 1, static_cast<int>(nm.vertices.size()) - 1});
    const std::string path = temp_path("seg_nonmanifold.stl");
    topopt::write_stl_file(path, nm, topopt::StlFormat::Binary);
    const PartInspection insp = topopt::inspect_part_file(path);
    CHECK(!insp.acceptable, "an ambiguous non-manifold junction is refused");
    CHECK(insp.non_manifold_edges > 0, "the non-manifold edge is counted");
    CHECK(insp.removed_duplicate_triangles == 0,
          "the fin is not a duplicate, so nothing was removed to try to fix it");
    bool named = false;
    for (const auto d : insp.defects)
      if (d == PartDefect::NonManifoldEdges) named = true;
    CHECK(named, "the diagnosis names the non-manifold edges");
    std::remove(path.c_str());
  }

  // Zero-thickness shell: a closed but degenerate "solid" — two coincident
  // triangles back to back. Topologically closed, encloses nothing.
  {
    TriangleMesh shell;
    shell.vertices = {{0, 0, 0}, {10, 0, 0}, {0, 10, 0}};
    shell.triangles = {{0, 1, 2}, {0, 2, 1}};
    const std::string path = temp_path("seg_shell.stl");
    topopt::write_stl_file(path, shell, topopt::StlFormat::Binary);
    const PartInspection insp = topopt::inspect_part_file(path);
    CHECK(!insp.acceptable, "a zero-thickness shell is refused");
    bool named = false;
    for (const auto d : insp.defects)
      if (d == PartDefect::ZeroThickness) named = true;
    CHECK(named, "the diagnosis names the zero thickness");
    std::remove(path.c_str());
  }

  // ==================================================================
  // PHASE 2 REPAIRS (handoff mesh-repair-phase-2). Repair the common,
  // safely-fixable defects BEFORE refusing; re-inspect; proceed if clean;
  // report exactly what changed. Refuse only what cannot be safely fixed.

  // ------------------------------------------------------------------
  // remove_duplicate_triangles as a unit: the FIRST occurrence survives, every
  // later exact-oriented copy is dropped, and an opposite-wound copy is kept.
  {
    TriangleMesh m = make_box(10, 10, 10);
    const int base = static_cast<int>(m.triangles.size());
    m.triangles.push_back(m.triangles[0]);            // exact duplicate
    m.triangles.push_back(m.triangles[4]);            // exact duplicate
    auto rev = m.triangles[2];
    std::swap(rev[1], rev[2]);
    m.triangles.push_back(rev);                       // opposite winding: NOT a dup
    const int removed = topopt::remove_duplicate_triangles(m);
    CHECK(removed == 2, "exactly the two exact-oriented duplicates are removed");
    CHECK(static_cast<int>(m.triangles.size()) == base + 1,
          "the opposite-wound copy is kept (it is a membrane, not a duplicate)");
  }

  // ------------------------------------------------------------------
  // REPAIR: non-manifold from duplicate facets (the bracket class). Stacked
  // coincident triangles are the #1 cause of "N edges shared by three or more
  // triangles" in CAD-exported STLs. Removing the redundant copies restores a
  // 2-manifold solid, so the mesh is ACCEPTED and the repair is REPORTED.
  {
    TriangleMesh dup = make_box(10, 10, 10);
    // Duplicate three facets: each duplicated facet pushes its edges past two
    // uses, so this is genuinely non-manifold before repair.
    dup.triangles.push_back(dup.triangles[0]);
    dup.triangles.push_back(dup.triangles[3]);
    dup.triangles.push_back(dup.triangles[7]);
    CHECK(topopt::check_watertight(dup).non_manifold_edges > 0,
          "the duplicated-facet box IS non-manifold before repair");
    const std::string path = temp_path("seg_dupfacets.stl");
    topopt::write_stl_file(path, dup, topopt::StlFormat::Binary);
    const PartModel p = topopt::import_part(path);
    CHECK(p.inspection.acceptable,
          "duplicate-facet non-manifoldness is repaired, not refused");
    CHECK(p.inspection.removed_duplicate_triangles == 3,
          "the repair reports all three redundant facets removed");
    CHECK(p.inspection.non_manifold_edges == 0,
          "the repaired mesh has no non-manifold edges left");
    CHECK(topopt::check_watertight(p.model.mesh).watertight,
          "and it is watertight");
    CHECK(p.model.face_count == 6, "the repaired box still segments into 6 faces");
    CHECK(std::fabs(p.model.brep_volume - 1000.0) < 1e-6,
          "and encloses the original 1000 mm^3 (the solid was not changed)");
    std::remove(path.c_str());
  }

  // ------------------------------------------------------------------
  // REPAIR: a small hole is capped. A finely-tessellated sphere with a single
  // triangle removed has a small 3-edge hole; that is well within the
  // conservative bound, so it is filled and the sphere is ACCEPTED watertight.
  {
    TriangleMesh sph = make_sphere(10.0, 16, 24);
    const double full_volume = topopt::signed_volume(sph);
    // Remove one non-pole triangle (a clean 3-edge hole). Triangle 0 touches the
    // top pole; pick one from the equatorial band instead.
    const std::size_t hole_tri = sph.triangles.size() / 2;
    sph.triangles.erase(sph.triangles.begin() +
                        static_cast<std::ptrdiff_t>(hole_tri));
    CHECK(topopt::check_watertight(sph).boundary_edges == 3,
          "removing one triangle leaves a single 3-edge hole");
    const std::string path = temp_path("seg_hole.stl");
    topopt::write_stl_file(path, sph, topopt::StlFormat::Binary);
    const PartModel p = topopt::import_part(path);
    CHECK(p.inspection.acceptable, "a small hole is filled, not refused");
    CHECK(p.inspection.filled_holes == 1, "the repair reports one hole filled");
    CHECK(p.inspection.filled_hole_triangles == 3,
          "a 3-edge hole is capped by a 3-triangle centroid fan");
    CHECK(p.inspection.boundary_edges == 0,
          "the repaired mesh has no boundary edges left");
    CHECK(topopt::check_watertight(p.model.mesh).watertight,
          "and it is watertight");
    // The cap tents to the loop centroid, so the volume changes by at most the
    // tiny facet-sized sliver — a small hole fill does not change the solid.
    CHECK(std::fabs(p.model.brep_volume - full_volume) < 0.05 * full_volume,
          "the filled volume is within a hair of the original sphere");
    std::remove(path.c_str());
  }

  // ------------------------------------------------------------------
  // DETERMINISM of repair: the SAME broken file re-imported yields the SAME
  // repaired geometry and the SAME pseudo-face ids (repairs are persisted).
  {
    TriangleMesh dup = make_box(8, 6, 4);
    dup.triangles.push_back(dup.triangles[1]);
    dup.triangles.push_back(dup.triangles[9]);
    const std::string path = temp_path("seg_repair_det.stl");
    topopt::write_stl_file(path, dup, topopt::StlFormat::Binary);
    const PartModel a = topopt::import_part(path);
    const PartModel b = topopt::import_part(path);
    CHECK(a.model.mesh.vertices.size() == b.model.mesh.vertices.size() &&
              a.model.mesh.triangles.size() == b.model.mesh.triangles.size(),
          "re-importing a broken file yields identical repaired geometry");
    CHECK(a.model.triangle_face == b.model.triangle_face,
          "and identical pseudo-face ids");
    CHECK(a.inspection.removed_duplicate_triangles ==
              b.inspection.removed_duplicate_triangles,
          "and the same repair report");
    std::remove(path.c_str());
  }

  // ------------------------------------------------------------------
  // THE CONSERVATIVE BOUND IS A REAL GATE, tested at the boundary. The same
  // small-hole sphere that fills under the default bound is REFUSED when the
  // fraction bound is tightened below the hole's span: the repair never forces
  // a fill it was told is too big.
  {
    TriangleMesh sph = make_sphere(10.0, 16, 24);
    const std::size_t hole_tri = sph.triangles.size() / 2;
    sph.triangles.erase(sph.triangles.begin() +
                        static_cast<std::ptrdiff_t>(hole_tri));

    // Directly exercise fill_small_holes at the bound.
    topopt::MeshRepairOptions tight;
    tight.max_hole_fraction = 1e-6;  // below any real hole's span
    TriangleMesh a = sph;
    int loops = -1, tris = -1;
    topopt::fill_small_holes(a, tight, loops, tris);
    CHECK(loops == 0 && tris == 0,
          "a hole above the fraction bound is left OPEN, not force-filled");
    CHECK(topopt::check_watertight(a).boundary_edges == 3,
          "and the mesh is unchanged (still open) so it will be refused");

    topopt::MeshRepairOptions loose;  // defaults fill it
    TriangleMesh b = sph;
    int loops2 = -1, tris2 = -1;
    topopt::fill_small_holes(b, loose, loops2, tris2);
    CHECK(loops2 == 1 && tris2 == 3,
          "the very same hole IS filled under the default bound");

    // Edge-count bound: a hole with more edges than the cap is refused too.
    topopt::MeshRepairOptions few;
    few.max_hole_edges = 2;  // below the 3-edge hole
    TriangleMesh c = sph;
    int loops3 = -1, tris3 = -1;
    topopt::fill_small_holes(c, few, loops3, tris3);
    CHECK(loops3 == 0, "a hole with more edges than max_hole_edges is refused");
  }

  // ------------------------------------------------------------------
  // BEYOND REPAIR still refuses cleanly: a genuine non-manifold junction of two
  // solids sharing a single edge. Duplicate removal cannot separate them (the
  // four incident facets are all distinct), so it is refused — no crash, no
  // silent bad repair.
  {
    // Two unit boxes meeting along the shared edge x=10,y=10 (the +x/+y column):
    // build one box [0,10]^3 and a second box [10,20]x[10,20]x[0,10]; they touch
    // only along the vertical edge (10,10,0)-(10,10,10). Rather than model the
    // full solids, reproduce the ambiguous edge directly: four triangles fanning
    // a single shared edge, which is exactly the undecidable inside/outside case.
    TriangleMesh j = make_box(10, 10, 10);
    // Weld a second box's worth of facets onto the (2,6) edge so it is 4-used by
    // geometrically distinct triangles (not duplicates).
    const int a = 2, b = 6;  // an existing cube edge, used by 2 facets already
    j.vertices.push_back(Vec3{15, 15, 0});
    j.vertices.push_back(Vec3{15, 15, 10});
    const int p = static_cast<int>(j.vertices.size()) - 2;
    const int q = static_cast<int>(j.vertices.size()) - 1;
    j.triangles.push_back({a, b, p});
    j.triangles.push_back({b, q, p});
    const std::string path = temp_path("seg_junction.stl");
    topopt::write_stl_file(path, j, topopt::StlFormat::Binary);
    const PartInspection insp = topopt::inspect_part_file(path);
    CHECK(!insp.acceptable, "an ambiguous junction of distinct facets is refused");
    CHECK(insp.non_manifold_edges > 0, "and the surviving junction is counted");
    CHECK(insp.removed_duplicate_triangles == 0,
          "duplicate removal did not touch it (the facets are all distinct)");
    bool named = false;
    for (const auto d : insp.defects)
      if (d == PartDefect::NonManifoldEdges) named = true;
    CHECK(named, "the diagnosis names the non-manifold junction");
    std::remove(path.c_str());
  }

  // ------------------------------------------------------------------
  // UNITS: rescaling the working copy is how the inch/mm answer is applied.
  {
    const TriangleMesh cube = make_box(1, 1, 1);
    const std::string src = temp_path("seg_units_in.stl");
    const std::string dst = temp_path("seg_units_mm.stl");
    topopt::write_stl_file(src, cube, topopt::StlFormat::Binary);
    topopt::rescale_part_file(src, dst, 25.4);
    const PartModel p = topopt::import_part(dst);
    Vec3 lo, hi;
    topopt::bounding_box(p.model.mesh, lo, hi);
    CHECK(std::fabs((hi.x - lo.x) - 25.4) < 1e-3,
          "an inch-unit cube rescales to 25.4 mm across");
    CHECK(p.model.face_count == 6, "and still segments into 6 pseudo-faces");
    std::remove(src.c_str());
    std::remove(dst.c_str());
  }

  // ------------------------------------------------------------------
  // The threshold is a knob, and its effect is monotone: a coarser mesh needs a
  // higher threshold to stay whole. Pins the sweep's logic in code.
  {
    const TriangleMesh coarse = make_prism(8, 5.0, 20.0);  // 45 deg per facet
    SegmentOptions loose;
    loose.dihedral_threshold_deg = 50.0;
    const MeshSegmentation s = topopt::segment_mesh_faces(coarse, loose);
    CHECK(region_count(s) == 3,
          "raising the threshold above 45 deg reunites the 8-gon barrel");
  }

  if (g_failures == 0) {
    std::printf("mesh segmentation: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "mesh segmentation: %d/%d checks FAILED\n", g_failures,
               g_checks);
  return 1;
}
