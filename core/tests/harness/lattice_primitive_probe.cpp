// lattice_primitive_probe — ★ WHY "LATTICE" ON A FACE OFTEN DRAWS NOTHING
// (task 2026-08-15-lattice-and-face-ui §2a).
//
//   cmake --build build --target lattice_primitive_probe
//   ./build/lattice_primitive_probe <part.step> <resolution> [face ids...]
//
// ★ HIS REPORT: "In many cases, when I press 'Lattice' on a face, NO PRIMITIVE
// APPEARS. It ALWAYS has to create a primitive. IF THERE ISN'T ONE MADE, IT IS
// BROKEN."
//
// The app builds the visible primitive — the lattice DEPTH PLANE — in
// `ProjectModel.latticeDepthPlanes()`. For a B-rep face that construction is
// guarded (`ProjectModel.swift:925`):
//
//     guard ..., let geo = mesh.faceGeometry(f), geo.isPlane,
//           let outline = mesh.facePlaneOutline(...) else { continue }
//
// `isPlane` is `kind == .plane` (`TopOptKit.swift:65`). A face that is a CYLINDER
// or an `Other` surface fails the guard and is SILENTLY SKIPPED — no primitive,
// no refusal, no message. The region path has the same shape four times over
// (`ProjectModel.swift:1011` requires a member to be a plane before it
// contributes to the region's normal at all).
//
// This probe prices that guard on a real part: how many faces are planes, and —
// for the faces the maintainer actually declares — how many would get a
// primitive today against how many he selected.
//
// It reports ONLY what the import says. No app code runs here; the point is that
// the app's predicate is a function of `StepFaceInfo::kind`, which is exactly
// what this prints.

#include "topopt/face_overrides.hpp"
#include "topopt/part.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

using namespace topopt;

namespace {

const char* kind_name(StepSurfaceKind k) {
  switch (k) {
    case StepSurfaceKind::Plane: return "plane";
    case StepSurfaceKind::Cylinder: return "cylinder";
    default: return "other";
  }
}

// The app's own predicate, transcribed: `StepFaceGeometry.isPlane`.
bool app_would_draw_a_primitive(const StepFaceInfo& f) {
  return f.kind == StepSurfaceKind::Plane;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr,
                 "usage: lattice_primitive_probe <part.step> <resolution> "
                 "[face ids...]\n");
    return 2;
  }
  const std::string path = argv[1];
  const int resolution = std::atoi(argv[2]);

  StepModel model;
  try {
    model = import_part_file_resolved(path);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "cannot import %s: %s\n", path.c_str(), e.what());
    return 2;
  }
  const VoxelGrid grid = voxelize(model.mesh, resolution);

  std::printf("=== 1. THE PART ===\n");
  std::printf("part            %s\n", path.c_str());
  std::printf("resolution      %d   spacing %g mm\n", resolution, grid.spacing);
  std::printf("faces           %zu\n", model.faces.size());

  std::printf("\n=== 2. SURFACE KIND, WHOLE PART ===\n");
  std::size_t n_plane = 0, n_cyl = 0, n_other = 0;
  for (const StepFaceInfo& f : model.faces) {
    switch (f.kind) {
      case StepSurfaceKind::Plane: ++n_plane; break;
      case StepSurfaceKind::Cylinder: ++n_cyl; break;
      default: ++n_other; break;
    }
  }
  const std::size_t total = model.faces.size();
  auto pct = [&](std::size_t n) {
    return total ? 100.0 * static_cast<double>(n) / static_cast<double>(total)
                 : 0.0;
  };
  std::printf("plane           %3zu  (%.1f%%)   <- these get a primitive TODAY\n",
              n_plane, pct(n_plane));
  std::printf("cylinder        %3zu  (%.1f%%)   <- NO PRIMITIVE\n", n_cyl,
              pct(n_cyl));
  std::printf("other           %3zu  (%.1f%%)   <- NO PRIMITIVE\n", n_other,
              pct(n_other));
  std::printf("\n★ %zu of %zu faces (%.1f%%) DRAW NOTHING when set to Lattice.\n",
              n_cyl + n_other, total, pct(n_cyl + n_other));

  if (argc > 3) {
    std::printf("\n=== 3. HIS DECLARED FACES ===\n");
    std::vector<int> ids;
    for (int i = 3; i < argc; ++i) ids.push_back(std::atoi(argv[i]));
    std::size_t drawn = 0, skipped = 0;
    std::printf("id     kind       primitive today\n");
    for (int id : ids) {
      if (id < 0 || static_cast<std::size_t>(id) >= model.faces.size()) {
        std::printf("%-6d %-10s %s\n", id, "-", "OUT OF RANGE");
        continue;
      }
      const StepFaceInfo& f = model.faces[static_cast<std::size_t>(id)];
      const bool ok = app_would_draw_a_primitive(f);
      if (ok) ++drawn; else ++skipped;
      std::printf("%-6d %-10s %s\n", id, kind_name(f.kind),
                  ok ? "yes" : "*** NONE ***");
    }
    std::printf("\ndeclared        %zu\n", ids.size());
    std::printf("get a primitive %zu\n", drawn);
    std::printf("GET NOTHING     %zu  (%.1f%% of his own selection)\n", skipped,
                ids.empty() ? 0.0
                            : 100.0 * static_cast<double>(skipped) /
                                  static_cast<double>(ids.size()));
  }
  return 0;
}
