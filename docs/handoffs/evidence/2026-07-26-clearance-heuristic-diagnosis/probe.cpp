// probe.cpp — auto-clearance heuristic DIAGNOSTIC (handoff 2026-07-26).
//
// Runs the SAME pipeline the app runs on a mesh import — import_part ->
// segment_mesh_faces — on every mesh fixture in the repo, then reproduces the
// two app-side predicates that drive the auto-clearance heuristic:
//
//   * isBore  : FaceTopology.isCurved (app) — ANY pair of a face's triangle
//               normals differ by > 5 deg. This is what makes a face count as a
//               clearance "bore" primitive and what arms autoClearanceApplies.
//               (mirror of app/.../FaceSelection.swift isCurved)
//
//   * isCyl   : StepFaceGeometry.isCylinder (app) — kind == Cylinder AND
//               radius > 0. This is what yields a NON-nil Auto margin/axial.
//               (mirror of app/.../TopOptKit.swift isCylinder)
//
// and the derived Auto distances (ClearanceGeometry.swift):
//   margin = r ; axial = 2r , with r = cylinder_radius_mm.
//
// For each fixture it prints one row per pseudo-face and a summary line:
//   #primitives proposed  =  count(isBore)
//   #with a real radius   =  count(isBore && isCyl)
//   #blank-Auto rows      =  count(isBore && !isCyl)
//
// The point is to see where the "eight primitives" and the "blank Auto" rows
// come from, measured, on the real bracket.

#include "topopt/mesh.hpp"
#include "topopt/part.hpp"
#include "topopt/segment.hpp"
#include "topopt/step.hpp"

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

using namespace topopt;

static Vec3 tri_normal(const TriangleMesh& m, int t) {
  const auto& tri = m.triangles[(size_t)t];
  const Vec3& a = m.vertices[(size_t)tri[0]];
  const Vec3& b = m.vertices[(size_t)tri[1]];
  const Vec3& c = m.vertices[(size_t)tri[2]];
  Vec3 e1{b.x - a.x, b.y - a.y, b.z - a.z};
  Vec3 e2{c.x - a.x, c.y - a.y, c.z - a.z};
  Vec3 n{e1.y * e2.z - e1.z * e2.y, e1.z * e2.x - e1.x * e2.z,
         e1.x * e2.y - e1.y * e2.x};
  double nl = std::sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
  if (nl <= 0) return Vec3{0, 0, 0};
  return Vec3{n.x / nl, n.y / nl, n.z / nl};
}

// Mirror of FaceTopology.isCurved: max pairwise angle between the face's
// triangle normals; curved iff that exceeds 5 deg. Returns the max angle (deg)
// so we can see HOW curved, and -1 if the face has <2 usable normals.
static double face_max_fan_deg(const TriangleMesh& m,
                               const std::vector<int>& tri_face, int face) {
  std::vector<Vec3> ns;
  for (size_t t = 0; t < tri_face.size(); ++t)
    if (tri_face[t] == face) {
      Vec3 n = tri_normal(m, (int)t);
      if (n.x != 0 || n.y != 0 || n.z != 0) ns.push_back(n);
    }
  if (ns.size() < 2) return -1.0;
  double worst = 0.0;
  for (size_t i = 0; i < ns.size(); ++i)
    for (size_t j = i + 1; j < ns.size(); ++j) {
      double d = ns[i].x * ns[j].x + ns[i].y * ns[j].y + ns[i].z * ns[j].z;
      if (d > 1) d = 1;
      if (d < -1) d = -1;
      double ang = std::acos(d) * 180.0 / 3.14159265358979323846;
      if (ang > worst) worst = ang;
    }
  return worst;
}

static const char* kind_str(StepSurfaceKind k) {
  switch (k) {
    case StepSurfaceKind::Plane: return "Plane";
    case StepSurfaceKind::Cylinder: return "Cyl";
    default: return "Other";
  }
}

static void probe(const std::string& label, const std::string& path) {
  std::printf("\n============================================================\n");
  std::printf("FIXTURE: %s\n  path: %s\n", label.c_str(), path.c_str());
  PartModel pm;
  try {
    pm = import_part(path);
  } catch (const std::exception& e) {
    std::printf("  IMPORT FAILED: %s\n", e.what());
    return;
  }
  const StepModel& sm = pm.model;
  const TriangleMesh& mesh = sm.mesh;
  Vec3 lo, hi;
  bounding_box(mesh, lo, hi);
  const double diag = std::sqrt((hi.x - lo.x) * (hi.x - lo.x) +
                                (hi.y - lo.y) * (hi.y - lo.y) +
                                (hi.z - lo.z) * (hi.z - lo.z));
  std::printf("  %zu triangles, %d pseudo-faces, bbox diag %.2f mm "
              "(pseudo_faces=%d)\n",
              mesh.triangles.size(), sm.face_count, diag,
              (int)pm.pseudo_faces);

  // Per-face triangle counts.
  std::vector<int> tcount((size_t)sm.face_count, 0);
  for (int f : sm.triangle_face)
    if (f >= 0 && f < sm.face_count) tcount[(size_t)f]++;

  int n_bore = 0, n_bore_cyl = 0, n_blank = 0;
  std::printf("  %-4s %-6s %-5s %8s %8s %8s %8s  %s\n", "face", "kind", "tris",
              "fitR", "fanDeg", "margin", "axial", "-> heuristic verdict");
  for (int f = 0; f < sm.face_count; ++f) {
    const StepFaceInfo& fi = sm.faces[(size_t)f];
    const double fan = face_max_fan_deg(mesh, sm.triangle_face, f);
    const bool isBore = fan > 5.0;  // FaceTopology.isCurved, 5 deg
    const bool isCyl =
        fi.kind == StepSurfaceKind::Cylinder && fi.cylinder_radius_mm > 0;
    const double r = fi.cylinder_radius_mm;
    const double margin = isCyl ? r : 0.0;
    const double axial = isCyl ? 2.0 * r : 0.0;
    const char* verdict = "";
    if (isBore && isCyl) {
      verdict = "BORE primitive (radius ok)";
      n_bore++;
      n_bore_cyl++;
    } else if (isBore && !isCyl) {
      verdict = "BORE primitive -> BLANK Auto (no radius)";
      n_bore++;
      n_blank++;
    } else {
      verdict = "(not a bore)";
    }
    // Only print bores + a compact note for non-bores to keep it readable.
    if (isBore) {
      char rbuf[16], mbuf[16], abuf[16];
      if (isCyl) {
        std::snprintf(rbuf, sizeof rbuf, "%8.3f", r);
        std::snprintf(mbuf, sizeof mbuf, "%8.3f", margin);
        std::snprintf(abuf, sizeof abuf, "%8.3f", axial);
      } else {
        std::snprintf(rbuf, sizeof rbuf, "%8s", "-");
        std::snprintf(mbuf, sizeof mbuf, "%8s", "BLANK");
        std::snprintf(abuf, sizeof abuf, "%8s", "BLANK");
      }
      std::printf("  %-4d %-6s %-5d %s %8.2f %s %s  %s\n", f, kind_str(fi.kind),
                  tcount[(size_t)f], rbuf, fan, mbuf, abuf, verdict);
    }
  }
  // Face-kind census over ALL faces.
  int planes = 0, cyls = 0, others = 0;
  for (const auto& fi : sm.faces) {
    if (fi.kind == StepSurfaceKind::Plane) planes++;
    else if (fi.kind == StepSurfaceKind::Cylinder) cyls++;
    else others++;
  }
  std::printf("  SUMMARY: %d pseudo-faces (%d plane, %d cyl, %d other)\n",
              sm.face_count, planes, cyls, others);
  std::printf("  HEURISTIC: %d bore primitives proposed | %d with a real "
              "radius | %d BLANK-Auto rows\n",
              n_bore, n_bore_cyl, n_blank);
}

int main(int argc, char** argv) {
  const std::string root = argc > 1 ? argv[1] : ".";
  struct F {
    std::string label, rel;
  };
  const std::vector<F> fixtures = {
      {"WallMount_ShelfBracket (the reported part)",
       "core/tests/fixtures/mesh/WallMount_ShelfBracket.stl"},
      {"plate_bore (authored bracket, clean bore)",
       "core/tests/fixtures/mesh/plate_bore.stl"},
      {"filleted_bore_plate (rounded-rim bore, PR-167/paint fixture)",
       "core/tests/fixtures/mesh/filleted_bore_plate.stl"},
      {"l-bracket (CAD export, 2 through-holes)",
       "docs/handoffs/evidence/2026-07-25-mesh-job-params/l-bracket.stl"},
      {"hook", "core/tests/fixtures/orient/hook.stl"},
      {"sphere_r10mm (everywhere-curved)",
       "core/tests/fixtures/stl/sphere_r10mm.stl"},
      {"cube_10mm (no holes)", "core/tests/fixtures/stl/cube_10mm.stl"},
      {"sample_cube (app resource)", "app/TopOpt/Resources/sample_cube.stl"},
      {"bracket_clean (mesh-repair evidence)",
       "docs/handoffs/evidence/2026-07-24-mesh-repair/bracket_clean.stl"},
      {"bracket_wall_hole", "docs/handoffs/evidence/2026-07-24-mesh-repair/bracket_wall_hole.stl"},
      {"bracket_small_hole", "docs/handoffs/evidence/2026-07-24-mesh-repair/bracket_small_hole.stl"},
  };
  for (const auto& f : fixtures) probe(f.label, root + "/" + f.rel);
  return 0;
}
