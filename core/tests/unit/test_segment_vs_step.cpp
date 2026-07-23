// test_segment_vs_step.cpp — pseudo-faces measured against B-rep ground truth
// (handoff 134). OCCT-gated: it needs the real STEP import to compare with.
//
// This is the strongest available evidence that the segmenter selects what a
// human calls "that face", because it does not rely on anyone's judgement. The
// demo L-bracket exists as a STEP file with REAL B-rep faces. Tessellate it,
// write it out as an STL — exactly what a user does when they export a mesh
// from CAD — re-import through the MESH path, and compare the manufactured
// partition against the B-rep the same part came from.
//
// If the pseudo-faces match the B-rep faces in count, kind and (for bores)
// radius and axis, then a tap resolves to the same face id it would have on the
// STEP, which is precisely the contract Phase 1 claims.

#include "topopt/mesh.hpp"
#include "topopt/part.hpp"
#include "topopt/segment.hpp"
#include "topopt/step.hpp"
#include "topopt/stl.hpp"

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

using topopt::import_part;
using topopt::import_step_file;
using topopt::PartModel;
using topopt::StepFaceInfo;
using topopt::StepModel;
using topopt::StepSurfaceKind;

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

struct Histogram {
  int planes = 0, cylinders = 0, other = 0;
};

static Histogram histogram(const std::vector<StepFaceInfo>& faces) {
  Histogram h;
  for (const auto& f : faces) {
    switch (f.kind) {
      case StepSurfaceKind::Plane: ++h.planes; break;
      case StepSurfaceKind::Cylinder: ++h.cylinders; break;
      case StepSurfaceKind::Other: ++h.other; break;
    }
  }
  return h;
}

static std::vector<double> cylinder_radii(const std::vector<StepFaceInfo>& faces) {
  std::vector<double> r;
  for (const auto& f : faces)
    if (f.kind == StepSurfaceKind::Cylinder) r.push_back(f.cylinder_radius_mm);
  std::sort(r.begin(), r.end());
  return r;
}

int main() {
  const std::string step_path = std::string(DEMO_FIXTURE_DIR) + "/l-bracket.step";
  const std::string stl_path = std::string(SEGMENT_TMP_DIR) + "/l_bracket_cad_export.stl";

  // Ground truth: the B-rep faces of the part.
  const StepModel step = import_step_file(step_path);
  const Histogram want = histogram(step.faces);

  // The user's route: export STL from CAD, then import the mesh.
  topopt::write_stl_file(stl_path, step.mesh, topopt::StlFormat::Binary);
  const PartModel part = import_part(stl_path);
  const Histogram got = histogram(part.model.faces);

  std::printf("SEGMENT-VS-STEP l-bracket: B-rep %d faces (%d plane, %d cyl, %d other)"
              " | pseudo %d faces (%d plane, %d cyl, %d other)\n",
              step.face_count, want.planes, want.cylinders, want.other,
              part.model.face_count, got.planes, got.cylinders, got.other);

  CHECK(part.pseudo_faces, "the STL round-trip reports manufactured faces");
  CHECK(part.model.face_count == step.face_count,
        "the pseudo-face partition has the same face COUNT as the B-rep");
  CHECK(got.planes == want.planes, "same number of PLANAR faces as the B-rep");
  CHECK(got.cylinders == want.cylinders,
        "same number of CYLINDRICAL faces as the B-rep");
  CHECK(got.other == want.other, "no face is left unclassified that the B-rep classified");

  // The bolt bores are the faces that MATTER most to get right: a keep-clear
  // sweeps along the axis at the radius, so a wrong fit is a wrong keep-out.
  const std::vector<double> want_r = cylinder_radii(step.faces);
  const std::vector<double> got_r = cylinder_radii(part.model.faces);
  CHECK(want_r.size() == got_r.size(), "same number of bores");
  if (want_r.size() == got_r.size()) {
    for (std::size_t i = 0; i < want_r.size(); ++i) {
      const bool close = std::fabs(got_r[i] - want_r[i]) <= 0.02 * want_r[i];
      CHECK(close, "each fitted bore radius matches the B-rep radius within 2%");
      if (!close)
        std::fprintf(stderr, "  bore %zu: B-rep %.4f, fitted %.4f\n", i, want_r[i],
                     got_r[i]);
    }
  }

  // Each fitted cylinder axis must be parallel to the B-rep's (sign is a
  // convention, so compare |dot|).
  for (const auto& f : part.model.faces) {
    if (f.kind != StepSurfaceKind::Cylinder) continue;
    bool matched = false;
    for (const auto& g : step.faces) {
      if (g.kind != StepSurfaceKind::Cylinder) continue;
      const double d = std::fabs(f.axis_dir.x * g.axis_dir.x +
                                 f.axis_dir.y * g.axis_dir.y +
                                 f.axis_dir.z * g.axis_dir.z);
      if (d > 0.999) matched = true;
    }
    CHECK(matched, "each fitted bore axis is parallel to a B-rep bore axis");
  }

  // Determinism against the file, not just within one process.
  const PartModel again = import_part(stl_path);
  CHECK(again.model.triangle_face == part.model.triangle_face,
        "re-importing the exported STL reproduces identical pseudo-face ids");

  std::remove(stl_path.c_str());

  if (g_failures == 0) {
    std::printf("segment vs step: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "segment vs step: %d/%d checks FAILED\n", g_failures, g_checks);
  return 1;
}
