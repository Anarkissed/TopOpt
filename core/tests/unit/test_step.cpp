// Unit tests for STEP import + controllable-deflection tessellation (ROADMAP
// M1.4).
//
// No third-party test framework is available (ARCHITECTURE §4 locks the
// dependency set), so this reuses the self-contained CHECK harness style from
// test_stl.cpp. Tests exercise the public API only (topopt/step.hpp,
// topopt/mesh.hpp) — OCCT never appears here.
//
// Golden values are the human-authored ground truth in
// core/tests/fixtures/step/expected_values.json (fixture discipline,
// AGENT_PROMPTS §4; DECISIONS.md 2026-07-03). They are duplicated here as
// literals citing that file; the tests must not edit it, only assert against it.
// NOTE: the cube file on disk is `cube.step`; its expected_values.json entry is
// keyed "10_mm_cube.step" (the maintainer renamed the file but not the key).
// STEP_FIXTURE_DIR is injected by CMake so the tests are independent of the
// working directory ctest runs from.

#include "topopt/mesh.hpp"
#include "topopt/step.hpp"

#include <cmath>
#include <cstdio>
#include <string>

using topopt::bounding_box;
using topopt::check_watertight;
using topopt::import_step_file;
using topopt::signed_volume;
using topopt::StepError;
using topopt::StepFaceInfo;
using topopt::StepModel;
using topopt::StepSurfaceKind;
using topopt::StepTessellation;
using topopt::Vec3;
using topopt::WatertightReport;

static double vlen(const Vec3& v) {
  return std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
}

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

static std::string fixture(const std::string& name) {
  return std::string(STEP_FIXTURE_DIR) + "/" + name;
}

// Relative-tolerance compare for volumes.
static bool rel_close(double got, double want, double rel) {
  return std::fabs(got - want) <= rel * std::fabs(want);
}
static bool abs_close(double got, double want, double tol) {
  return std::fabs(got - want) <= tol;
}

// Tessellate the cube at a given linear deflection.
static StepModel load_cube(double deflection) {
  StepTessellation t;
  t.linear_deflection = deflection;
  return import_step_file(fixture("cube.step"), t);
}
static StepModel load_cylinder(double deflection) {
  StepTessellation t;
  t.linear_deflection = deflection;
  return import_step_file(fixture("cylinder.step"), t);
}

int main() {
  // === cube.step: 10x10x10 planar solid, exact volume 1000 mm^3 =============
  // expected_values.json "10_mm_cube.step": solids 1, brep_faces 6,
  // analytic_volume_mm3 1000.0 (brep_volume_rel_tolerance 1e-6), and a planar
  // solid tessellates exactly so the MESH volume equals 1000.0 within 1e-6 at
  // ANY deflection. bbox min (-5, -5.384615385, 0) max (5, 4.615384615, 10).
  {
    StepModel m = load_cube(0.1);
    CHECK(m.solid_count == 1, "cube has 1 solid");
    CHECK(m.face_count == 6, "cube has 6 B-rep faces");
    CHECK(rel_close(m.brep_volume, 1000.0, 1e-6),
          "cube B-rep volume is 1000 mm^3");

    // Planar faces => 12 triangles welding to 8 corner vertices, watertight.
    CHECK(m.mesh.triangle_count() == 12, "cube tessellates to 12 triangles");
    CHECK(m.mesh.vertices.size() == 8, "cube welds to 8 unique vertices");
    WatertightReport r = check_watertight(m.mesh);
    CHECK(r.watertight, "cube mesh is watertight");
    CHECK(r.boundary_edges == 0, "cube mesh has 0 boundary edges");
    CHECK(r.non_manifold_edges == 0, "cube mesh has 0 non-manifold edges");

    CHECK(rel_close(signed_volume(m.mesh), 1000.0, 1e-6),
          "cube mesh volume is 1000 mm^3 (coarse deflection)");

    Vec3 lo, hi;
    bounding_box(m.mesh, lo, hi);
    CHECK(abs_close(lo.x, -5.0, 1e-6) && abs_close(lo.y, -5.384615385, 1e-6) &&
              abs_close(lo.z, 0.0, 1e-6),
          "cube bbox min (-5, -5.384615385, 0)");
    CHECK(abs_close(hi.x, 5.0, 1e-6) && abs_close(hi.y, 4.615384615, 1e-6) &&
              abs_close(hi.z, 10.0, 1e-6),
          "cube bbox max (5, 4.615384615, 10)");
  }

  // A planar solid tessellates exactly at ANY deflection: a much finer mesh is
  // still 12 triangles / 1000 mm^3 (proves the "exact at any deflection" claim).
  {
    StepModel m = load_cube(0.001);
    CHECK(m.mesh.triangle_count() == 12,
          "cube still 12 triangles at fine deflection");
    CHECK(rel_close(signed_volume(m.mesh), 1000.0, 1e-6),
          "cube mesh volume is 1000 mm^3 (fine deflection)");
  }

  // === cylinder.step: r=5, h=20, exact volume 500*pi mm^3 ==================
  // expected_values.json "cylinder.step": solids 1, brep_faces 3,
  // analytic_volume_mm3 1570.7963267948966. Tessellated volume is always BELOW
  // analytic (inscribed facets) and must increase monotonically toward it as
  // deflection tightens; ROADMAP M1.4 requires this across 3 deflection values
  // with the finest within 0.1% (rel 1e-3). We do not pin an exact tessellated
  // volume (it depends on OCCT's mesher) — we assert convergence + tolerance.
  const double kCylAnalytic = 1570.7963267948966;
  {
    StepModel m = load_cylinder(0.1);
    CHECK(m.solid_count == 1, "cylinder has 1 solid");
    CHECK(m.face_count == 3, "cylinder has 3 B-rep faces");
    CHECK(rel_close(m.brep_volume, kCylAnalytic, 1e-6),
          "cylinder B-rep volume is 500*pi mm^3");

    WatertightReport r = check_watertight(m.mesh);
    CHECK(r.watertight, "cylinder mesh is watertight");
    CHECK(r.boundary_edges == 0, "cylinder mesh has 0 boundary edges");
  }

  // Convergence across 3 deflection values (coarse -> fine).
  {
    const double d0 = 0.5, d1 = 0.05, d2 = 0.002;
    const double v0 = signed_volume(load_cylinder(d0).mesh);
    const double v1 = signed_volume(load_cylinder(d1).mesh);
    const double v2 = signed_volume(load_cylinder(d2).mesh);

    // Each is an inscribed approximation: strictly below the analytic volume
    // (allow a hair of numeric slack above zero deficit).
    CHECK(v0 < kCylAnalytic * (1.0 + 1e-9), "coarse cyl vol below analytic");
    CHECK(v1 < kCylAnalytic * (1.0 + 1e-9), "medium cyl vol below analytic");
    CHECK(v2 < kCylAnalytic * (1.0 + 1e-9), "fine cyl vol below analytic");

    // Monotonic convergence upward as deflection tightens.
    CHECK(v0 < v1, "cyl volume increases as deflection tightens (d0<d1)");
    CHECK(v1 < v2, "cyl volume increases as deflection tightens (d1<d2)");

    // Finest deflection within 0.1% of analytic (fixture tolerance 1e-3).
    CHECK(rel_close(v2, kCylAnalytic, 1e-3),
          "finest cyl mesh volume within 0.1% of 500*pi");

    // The coarse mesh is meaningfully worse than the finest (the test would be
    // vacuous if every deflection already hit tolerance).
    CHECK(!rel_close(v0, kCylAnalytic, 1e-3),
          "coarse cyl mesh volume is NOT yet within 0.1% (convergence is real)");
  }

  // Cylinder bounding box at a fine deflection. Curved-face chords lie inside
  // the true circle, so X/Y may be marginally inside +/-5 (assert within
  // +/-0.01); Z (flat caps at 0 and 20) is exact.
  {
    StepModel m = load_cylinder(0.002);
    Vec3 lo, hi;
    bounding_box(m.mesh, lo, hi);
    CHECK(abs_close(lo.x, -5.0, 0.01) && abs_close(lo.y, -5.0, 0.01),
          "cylinder bbox min X/Y ~ -5");
    CHECK(abs_close(hi.x, 5.0, 0.01) && abs_close(hi.y, 5.0, 0.01),
          "cylinder bbox max X/Y ~ 5");
    CHECK(abs_close(lo.z, 0.0, 1e-6) && abs_close(hi.z, 20.0, 1e-6),
          "cylinder bbox Z is exact (0 to 20)");
  }

  // === StepFaceInfo geometry (handoff 100 — clearance rasterizer input) =====
  // The cube is 6 axis-aligned planar faces. Every face must classify Plane with
  // a UNIT outward normal along one of the 6 axis directions, and its stored
  // origin must sit on that face of the [-5,5]x[-5.385,4.615]x[0,10] box (the
  // outward normal points AWAY from the solid interior). This pins that the
  // plane normal/origin are captured and outward-oriented (TopAbs_REVERSED
  // respected).
  {
    StepModel m = load_cube(0.1);
    CHECK(m.faces.size() == 6, "cube exposes 6 StepFaceInfo");
    int axis_hits = 0;
    for (const StepFaceInfo& f : m.faces) {
      CHECK(f.kind == StepSurfaceKind::Plane, "cube face is a Plane");
      CHECK(abs_close(vlen(f.plane_normal), 1.0, 1e-9),
            "cube plane normal is unit length");
      // Exactly one component is +/-1 (axis-aligned), the others ~0.
      const double ax = std::fabs(f.plane_normal.x);
      const double ay = std::fabs(f.plane_normal.y);
      const double az = std::fabs(f.plane_normal.z);
      const bool axis_aligned =
          (abs_close(ax, 1.0, 1e-9) && ay < 1e-9 && az < 1e-9) ||
          (abs_close(ay, 1.0, 1e-9) && ax < 1e-9 && az < 1e-9) ||
          (abs_close(az, 1.0, 1e-9) && ax < 1e-9 && ay < 1e-9);
      CHECK(axis_aligned, "cube plane normal is axis-aligned");
      if (axis_aligned) ++axis_hits;
      // The origin lies on the box face the outward normal points to.
      if (abs_close(f.plane_normal.x, 1.0, 1e-9))
        CHECK(abs_close(f.plane_origin.x, 5.0, 1e-6), "+X face origin at x=5");
      if (abs_close(f.plane_normal.x, -1.0, 1e-9))
        CHECK(abs_close(f.plane_origin.x, -5.0, 1e-6), "-X face origin at x=-5");
      if (abs_close(f.plane_normal.z, 1.0, 1e-9))
        CHECK(abs_close(f.plane_origin.z, 10.0, 1e-6), "+Z face origin at z=10");
      if (abs_close(f.plane_normal.z, -1.0, 1e-9))
        CHECK(abs_close(f.plane_origin.z, 0.0, 1e-6), "-Z face origin at z=0");
    }
    CHECK(axis_hits == 6, "all 6 cube faces are axis-aligned planes");
  }

  // The cylinder is r=5, h=20, axis along Z through the origin: 2 planar caps
  // (normals +/-Z) + 1 cylindrical lateral face. The lateral face must classify
  // Cylinder with radius 5, a UNIT axis direction parallel to Z, and an axis
  // point on the Z axis (x=y=0). This pins the exact axis/radius the swept-
  // cylinder bolt clearance is built from.
  {
    StepModel m = load_cylinder(0.002);
    CHECK(m.faces.size() == 3, "cylinder exposes 3 StepFaceInfo");
    int cyl_faces = 0, cap_faces = 0;
    for (const StepFaceInfo& f : m.faces) {
      if (f.kind == StepSurfaceKind::Cylinder) {
        ++cyl_faces;
        CHECK(abs_close(f.cylinder_radius_mm, 5.0, 1e-6),
              "cylinder lateral radius is 5 mm");
        CHECK(abs_close(vlen(f.axis_dir), 1.0, 1e-9),
              "cylinder axis_dir is unit length");
        CHECK(abs_close(std::fabs(f.axis_dir.z), 1.0, 1e-6),
              "cylinder axis is parallel to Z");
        CHECK(abs_close(f.axis_point.x, 0.0, 1e-6) &&
                  abs_close(f.axis_point.y, 0.0, 1e-6),
              "cylinder axis passes through x=y=0");
      } else if (f.kind == StepSurfaceKind::Plane) {
        ++cap_faces;
        CHECK(abs_close(std::fabs(f.plane_normal.z), 1.0, 1e-6),
              "cylinder cap normal is +/-Z");
      }
    }
    CHECK(cyl_faces == 1, "cylinder has exactly 1 lateral cylindrical face");
    CHECK(cap_faces == 2, "cylinder has 2 planar caps");
  }

  // === demo l-bracket: the real clearance target (handoff 100) =============
  // The demo L-bracket the app and CLI ship with: 10 B-rep faces — 8 planar,
  // 2 cylindrical bolt holes. Both holes are r=2.5 mm, axis parallel to Z, at
  // (x,y) = (-17, 0) and (9, 0). These are the "known hole axes/radii" a bolt
  // clearance is swept from; every planar face is axis-aligned with a unit
  // outward normal. Pinning them proves the geometry the app never carries is
  // recovered exactly core-side.
  {
    StepModel m = import_step_file(std::string(DEMO_FIXTURE_DIR) + "/l-bracket.step");
    CHECK(m.face_count == 10, "l-bracket has 10 B-rep faces");
    int cyls = 0, holeA = 0, holeB = 0;
    for (const StepFaceInfo& f : m.faces) {
      if (f.kind == StepSurfaceKind::Cylinder) {
        ++cyls;
        CHECK(abs_close(f.cylinder_radius_mm, 2.5, 1e-6),
              "l-bracket bolt hole radius is 2.5 mm");
        CHECK(abs_close(vlen(f.axis_dir), 1.0, 1e-9),
              "l-bracket hole axis_dir is unit");
        CHECK(abs_close(std::fabs(f.axis_dir.z), 1.0, 1e-6),
              "l-bracket hole axis is parallel to Z");
        if (abs_close(f.axis_point.x, -17.0, 1e-3) &&
            abs_close(f.axis_point.y, 0.0, 1e-3))
          ++holeA;
        if (abs_close(f.axis_point.x, 9.0, 1e-3) &&
            abs_close(f.axis_point.y, 0.0, 1e-3))
          ++holeB;
      } else if (f.kind == StepSurfaceKind::Plane) {
        CHECK(abs_close(vlen(f.plane_normal), 1.0, 1e-9),
              "l-bracket plane normal is unit");
        const double ax = std::fabs(f.plane_normal.x);
        const double ay = std::fabs(f.plane_normal.y);
        const double az = std::fabs(f.plane_normal.z);
        CHECK((abs_close(ax, 1.0, 1e-6) && ay < 1e-6 && az < 1e-6) ||
                  (abs_close(ay, 1.0, 1e-6) && ax < 1e-6 && az < 1e-6) ||
                  (abs_close(az, 1.0, 1e-6) && ax < 1e-6 && ay < 1e-6),
              "l-bracket plane normal is axis-aligned");
      }
    }
    CHECK(cyls == 2, "l-bracket has 2 cylindrical bolt holes");
    CHECK(holeA == 1, "l-bracket hole A axis at (-17, 0)");
    CHECK(holeB == 1, "l-bracket hole B axis at (9, 0)");
  }

  // === Missing file is a StepError, not a crash ============================
  {
    bool threw = false;
    std::string what;
    try {
      import_step_file(fixture("does_not_exist_98765.step"));
    } catch (const StepError& e) {
      threw = true;
      what = e.what();
    }
    CHECK(threw, "missing STEP file throws StepError");
    CHECK(what.find("does_not_exist_98765.step") != std::string::npos,
          "missing-file diagnostic names the path");
  }

  if (g_failures == 0) {
    std::printf("step import: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "step import: %d/%d checks FAILED\n", g_failures,
               g_checks);
  return 1;
}
