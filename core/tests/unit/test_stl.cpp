// Unit tests for STL import + watertight/manifold check (ROADMAP M1.3).
//
// No third-party test framework is available (ARCHITECTURE §4 locks the
// dependency set), so this reuses the self-contained CHECK harness style from
// test_materials.cpp. Tests exercise the public API only (topopt/stl.hpp,
// topopt/mesh.hpp).
//
// Golden values are the human-authored ground truth in
// core/tests/fixtures/stl/expected_values.json (fixture discipline,
// AGENT_PROMPTS §4). They are duplicated here as literals with the fixture as
// the cited source; the tests must not edit that file, only assert against it.
// STL_FIXTURE_DIR is injected by CMake so the tests are independent of the
// working directory ctest runs from.

#include "topopt/mesh.hpp"
#include "topopt/stl.hpp"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

using topopt::bounding_box;
using topopt::check_watertight;
using topopt::import_stl_file;
using topopt::read_stl_file;
using topopt::signed_volume;
using topopt::StlError;
using topopt::StlFormat;
using topopt::StlMesh;
using topopt::TriangleMesh;
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
  return std::string(STL_FIXTURE_DIR) + "/" + name;
}

// Relative-tolerance compare for volumes (expected_values.json pins 1e-9).
static bool rel_close(double got, double want, double rel) {
  return std::fabs(got - want) <= rel * std::fabs(want);
}

// Returns true iff import_stl_file(path) throws StlError; captures the message.
static bool import_rejects(const std::string& path, std::string& what) {
  try {
    import_stl_file(path);
  } catch (const StlError& e) {
    what = e.what();
    return true;
  } catch (...) {
    return false;
  }
  return false;
}

// --- Binary STL writer (test-local; not a committed fixture) ----------------
// Emits a minimal binary STL so the binary parse path is exercised without a
// golden binary file. The 80-byte header deliberately does NOT begin with
// "solid" so format detection classifies it as binary.
static void put_le_u32(std::ofstream& o, uint32_t v) {
  unsigned char b[4] = {static_cast<unsigned char>(v & 0xFF),
                        static_cast<unsigned char>((v >> 8) & 0xFF),
                        static_cast<unsigned char>((v >> 16) & 0xFF),
                        static_cast<unsigned char>((v >> 24) & 0xFF)};
  o.write(reinterpret_cast<const char*>(b), 4);
}
static void put_le_float(std::ofstream& o, float f) {
  uint32_t bits;
  std::memcpy(&bits, &f, sizeof(bits));
  put_le_u32(o, bits);
}
static void write_binary_one_triangle(const std::string& path, const Vec3 v[3]) {
  std::ofstream o(path, std::ios::binary);
  char header[80];
  std::memset(header, 0, sizeof(header));
  std::strcpy(header, "binary test STL");  // not "solid"
  o.write(header, 80);
  put_le_u32(o, 1);  // one triangle
  for (int i = 0; i < 3; ++i) put_le_float(o, 0.0f);  // facet normal (ignored)
  for (int i = 0; i < 3; ++i) {
    put_le_float(o, static_cast<float>(v[i].x));
    put_le_float(o, static_cast<float>(v[i].y));
    put_le_float(o, static_cast<float>(v[i].z));
  }
  char attr[2] = {0, 0};
  o.write(attr, 2);
}

int main() {
  // === cube_10mm.stl: closed 12-triangle box, volume 1000 mm^3 =============
  {
    StlMesh s = read_stl_file(fixture("cube_10mm.stl"));
    CHECK(s.format == StlFormat::Ascii, "cube detected as ASCII");
    CHECK(s.mesh.triangle_count() == 12, "cube has 12 triangles");
    CHECK(s.mesh.vertices.size() == 8, "cube welds to 8 unique vertices");

    WatertightReport r = check_watertight(s.mesh);
    CHECK(r.watertight, "cube is watertight");
    CHECK(r.boundary_edges == 0, "cube has 0 boundary edges");
    CHECK(r.non_manifold_edges == 0, "cube has 0 non-manifold edges");

    CHECK(rel_close(signed_volume(s.mesh), 1000.0, 1e-9),
          "cube volume is 1000 mm^3");

    Vec3 lo, hi;
    bounding_box(s.mesh, lo, hi);
    CHECK(lo.x == 0.0 && lo.y == 0.0 && lo.z == 0.0, "cube bbox min (0,0,0)");
    CHECK(hi.x == 10.0 && hi.y == 10.0 && hi.z == 10.0,
          "cube bbox max (10,10,10)");

    // The pipeline entry point accepts a watertight mesh unchanged.
    TriangleMesh m = import_stl_file(fixture("cube_10mm.stl"));
    CHECK(m.triangle_count() == 12, "import_stl_file returns the cube mesh");
  }

  // === sphere_r10mm.stl: 320-triangle icosphere ============================
  {
    StlMesh s = read_stl_file(fixture("sphere_r10mm.stl"));
    CHECK(s.format == StlFormat::Ascii, "sphere detected as ASCII");
    CHECK(s.mesh.triangle_count() == 320, "sphere has 320 triangles");

    WatertightReport r = check_watertight(s.mesh);
    CHECK(r.watertight, "sphere is watertight");
    CHECK(r.boundary_edges == 0, "sphere has 0 boundary edges");

    // Mesh (not analytic) signed volume, pinned to the fixture's on-disk value.
    // expected_values.json states mesh_volume_mm3 = 4047.044792044954 with
    // volume_rel_tolerance = 1e-9. That value was corrected by the maintainer
    // (see the file's "_erratum" and DECISIONS.md 2026-07-04, resolving handoff
    // 005 "## Blocked"): it is now computed from the committed sphere's on-disk
    // vertices (stored at ~7 significant figures), so a correct divergence-
    // theorem importer reproduces it exactly at 1e-9. This asserts the MESH
    // volume, not the analytic sphere volume (4188.79...), per the fixture note.
    CHECK(rel_close(signed_volume(s.mesh), 4047.044792044954, 1e-9),
          "sphere mesh volume is 4047.044792044954 mm^3");

    Vec3 lo, hi;
    bounding_box(s.mesh, lo, hi);
    CHECK(lo.x == -10.0 && lo.y == -10.0 && lo.z == -10.0,
          "sphere bbox min (-10,-10,-10)");
    CHECK(hi.x == 10.0 && hi.y == 10.0 && hi.z == 10.0,
          "sphere bbox max (10,10,10)");

    CHECK(import_stl_file(fixture("sphere_r10mm.stl")).triangle_count() == 320,
          "import_stl_file returns the sphere mesh");
  }

  // === broken_open_cube.stl: +X face removed, 4-edge hole ==================
  {
    // read_stl_file must still PARSE the open mesh (so its report is inspectable).
    StlMesh s = read_stl_file(fixture("broken_open_cube.stl"));
    CHECK(s.format == StlFormat::Ascii, "broken cube detected as ASCII");
    CHECK(s.mesh.triangle_count() == 10, "broken cube has 10 triangles");

    WatertightReport r = check_watertight(s.mesh);
    CHECK(!r.watertight, "broken cube is not watertight");
    CHECK(r.boundary_edges == 4, "broken cube has 4 boundary edges");
    CHECK(r.non_manifold_edges == 0, "broken cube has 0 non-manifold edges");

    // The importer MUST reject it with a diagnostic naming the cause.
    std::string what;
    CHECK(import_rejects(fixture("broken_open_cube.stl"), what),
          "import_stl_file rejects the open mesh");
    CHECK(what.find("watertight") != std::string::npos,
          "rejection diagnostic mentions watertightness");
    CHECK(what.find("boundary") != std::string::npos,
          "rejection diagnostic mentions boundary edges");
  }

  // === Missing file is an StlError, not a crash ===========================
  {
    bool threw = false;
    try {
      read_stl_file(fixture("does_not_exist_98765.stl"));
    } catch (const StlError&) {
      threw = true;
    }
    CHECK(threw, "missing STL file throws StlError");
  }

  // === Binary STL round-trip (format detection + little-endian floats) =====
  {
    const std::string path = "test_stl_binary_tmp.stl";
    const Vec3 tri[3] = {{1.0, 2.0, 3.0}, {4.0, 5.0, 6.0}, {7.0, 8.0, 9.0}};
    write_binary_one_triangle(path, tri);

    StlMesh s = read_stl_file(path);
    CHECK(s.format == StlFormat::Binary, "binary file detected as binary");
    CHECK(s.mesh.triangle_count() == 1, "binary file yields 1 triangle");
    CHECK(s.mesh.vertices.size() == 3, "binary triangle welds to 3 vertices");
    // Vertices are inserted in encounter order by the welder.
    if (s.mesh.vertices.size() == 3) {
      const Vec3& a = s.mesh.vertices[0];
      const Vec3& b = s.mesh.vertices[1];
      const Vec3& c = s.mesh.vertices[2];
      CHECK(a.x == 1.0 && a.y == 2.0 && a.z == 3.0, "binary vertex 0 decoded");
      CHECK(b.x == 4.0 && b.y == 5.0 && b.z == 6.0, "binary vertex 1 decoded");
      CHECK(c.x == 7.0 && c.y == 8.0 && c.z == 9.0, "binary vertex 2 decoded");
    }
    std::remove(path.c_str());
  }

  if (g_failures == 0) {
    std::printf("stl import: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "stl import: %d/%d checks FAILED\n", g_failures,
               g_checks);
  return 1;
}
