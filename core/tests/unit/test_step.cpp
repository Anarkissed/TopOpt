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
using topopt::StepModel;
using topopt::StepTessellation;
using topopt::Vec3;
using topopt::WatertightReport;

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
