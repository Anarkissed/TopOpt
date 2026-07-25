// Unit tests for face overrides — the self-describing sidecar and the painted
// pseudo-face primitive (handoff 2026-07-24, paint mode).
//
// Self-contained CHECK harness (ARCHITECTURE §4 locks the dependency set).
//
// The claims under test are the paint-mode contract:
//   * a painted triangle set becomes a NEW face id, and everything downstream
//     tags it IDENTICALLY to a native pseudo-face (the "painted == tapped" bar);
//   * the sidecar round-trips deterministically and a re-import reproduces it;
//   * with no sidecar, the resolved import is byte-for-byte the plain import;
//   * a malformed sidecar fails LOUDLY (never silently drops a painted face).

#include "topopt/face_overrides.hpp"
#include "topopt/mesh.hpp"
#include "topopt/part.hpp"
#include "topopt/segment.hpp"
#include "topopt/step.hpp"
#include "topopt/stl.hpp"
#include "topopt/voxel.hpp"

#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

using topopt::FaceOverrides;
using topopt::StepModel;
using topopt::StepSurfaceKind;
using topopt::TriangleMesh;
using topopt::Vec3;
using topopt::VoxelGrid;
using topopt::VoxelTag;

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

static std::string tmp(const char* name) {
  return std::string(OVERRIDES_TMP_DIR) + "/" + name;
}

// Axis-aligned box, outward wound: 12 triangles, 6 planar pseudo-faces.
static TriangleMesh make_box(double s) {
  TriangleMesh m;
  m.vertices = {{0, 0, 0}, {s, 0, 0}, {s, s, 0}, {0, s, 0},
                {0, 0, s}, {s, 0, s}, {s, s, s}, {0, s, s}};
  m.triangles = {{0, 3, 2}, {0, 2, 1}, {4, 5, 6}, {4, 6, 7},
                 {0, 1, 5}, {0, 5, 4}, {2, 3, 7}, {2, 7, 6},
                 {1, 2, 6}, {1, 6, 5}, {0, 4, 7}, {0, 7, 3}};
  return m;
}

static std::vector<int> tris_of_face(const StepModel& m, int face) {
  std::vector<int> out;
  for (std::size_t t = 0; t < m.triangle_face.size(); ++t)
    if (m.triangle_face[t] == face) out.push_back(static_cast<int>(t));
  return out;
}

int main() {
  // ------------------------------------------------------------------
  // Sidecar round-trip: save -> load is identity, including the paint sets.
  {
    FaceOverrides ov;
    ov.dihedral_threshold_deg = 28.0;
    ov.planar_region_cone_deg = 0.0;  // 0 is meaningful (cone disabled)
    ov.paint_faces = {{3, 4, 5}, {10, 11}};
    const std::string p = tmp("roundtrip.faces");
    topopt::save_face_overrides(p, ov);
    const FaceOverrides r = topopt::load_face_overrides(p);
    CHECK(r.dihedral_threshold_deg == 28.0, "dihedral round-trips");
    CHECK(r.planar_region_cone_deg == 0.0, "cone=0 round-trips (not treated as unset)");
    CHECK(r.paint_faces == ov.paint_faces, "paint sets round-trip exactly");
  }

  // A missing sidecar loads as empty (the common no-tuning/no-paint case).
  {
    const FaceOverrides r = topopt::load_face_overrides(tmp("does_not_exist.faces"));
    CHECK(r.empty(), "a missing sidecar is empty, not an error");
  }

  // A malformed sidecar throws — never silently drops a painted Load face.
  {
    const std::string p = tmp("bad.faces");
    std::ofstream(p) << "not-a-header 9\nface 1 2 3\n";
    bool threw = false;
    try { topopt::load_face_overrides(p); } catch (const std::exception&) { threw = true; }
    CHECK(threw, "a bad header is rejected loudly");

    const std::string p2 = tmp("bad2.faces");
    std::ofstream(p2) << "topopt-face-overrides 1\nwobble 1 2\n";
    threw = false;
    try { topopt::load_face_overrides(p2); } catch (const std::exception&) { threw = true; }
    CHECK(threw, "an unknown directive is rejected loudly");
  }

  // ------------------------------------------------------------------
  // apply_face_overrides: a painted set becomes a new appended face, its
  // triangles are reassigned, and it is fitted (a flat set -> Plane).
  {
    const std::string stl = tmp("box.stl");
    topopt::write_stl_file(stl, make_box(10), topopt::StlFormat::Binary);
    StepModel base = topopt::import_part(stl).model;
    const int base_faces = base.face_count;

    // Paint the +z top face's own triangles into a new face.
    int top = -1;
    for (int f = 0; f < base.face_count; ++f) {
      const auto ts = tris_of_face(base, f);
      if (ts.empty()) continue;
      if (base.faces[static_cast<std::size_t>(f)].plane_normal.z > 0.99) top = f;
    }
    CHECK(top >= 0, "found the +z top pseudo-face");
    const std::vector<int> top_tris = tris_of_face(base, top);

    StepModel painted = base;
    FaceOverrides ov;
    ov.paint_faces = {top_tris};
    topopt::apply_face_overrides(painted, ov);
    const int pid = painted.face_count - 1;
    CHECK(painted.face_count == base_faces + 1, "one painted face was appended");
    for (const int t : top_tris)
      CHECK(painted.triangle_face[static_cast<std::size_t>(t)] == pid,
            "painted triangles were reassigned to the new face id");
    CHECK(painted.faces[static_cast<std::size_t>(pid)].kind == StepSurfaceKind::Plane,
          "a flat painted set is fitted as a Plane");
    CHECK(painted.faces[static_cast<std::size_t>(pid)].plane_normal.z > 0.99,
          "the painted plane keeps the +z outward normal");

    // THE BAR: the painted face tags the SAME voxels a native pseudo-face does.
    // Tag the top face on the original model, and the painted face on the
    // painted model; the tagged voxel set must be identical.
    VoxelGrid ga = topopt::voxelize(base.mesh, 12);
    VoxelGrid gb = topopt::voxelize(painted.mesh, 12);
    const std::size_t na = topopt::tag_step_face(ga, base, top, VoxelTag::Load);
    const std::size_t nb = topopt::tag_step_face(gb, painted, pid, VoxelTag::Load);
    CHECK(na > 0 && na == nb,
          "painted face tags exactly the same voxels as the native face");
    bool same = ga.tags.size() == gb.tags.size();
    for (std::size_t i = 0; same && i < ga.tags.size(); ++i)
      if (ga.tags[i] != gb.tags[i]) same = false;
    CHECK(same, "the tagged voxel grids are identical (painted == tapped)");

    // Out-of-range and empty painted sets are rejected.
    bool threw = false;
    StepModel m2 = base;
    FaceOverrides bad; bad.paint_faces = {{999999}};
    try { topopt::apply_face_overrides(m2, bad); } catch (const std::exception&) { threw = true; }
    CHECK(threw, "an out-of-range painted triangle is rejected");
    threw = false;
    FaceOverrides empty; empty.paint_faces = {{}};
    try { topopt::apply_face_overrides(m2, empty); } catch (const std::exception&) { threw = true; }
    CHECK(threw, "an empty painted face is rejected");
  }

  // ------------------------------------------------------------------
  // import_part_file_resolved: no sidecar => byte-for-byte the plain import;
  // with a sidecar => the tuned threshold AND the painted face appear, and the
  // resolved import is deterministic.
  {
    const std::string stl = tmp("resolved.stl");
    topopt::write_stl_file(stl, make_box(10), topopt::StlFormat::Binary);
    // The tmp dir persists across runs; a sidecar left by a previous run would
    // make the "no sidecar" case below lie. Start from a known-clean state.
    std::remove(topopt::face_overrides_sidecar_path(stl).c_str());

    const StepModel plain = topopt::import_part_file(stl);
    const StepModel r0 = topopt::import_part_file_resolved(stl);  // no sidecar yet
    CHECK(r0.face_count == plain.face_count &&
              r0.triangle_face == plain.triangle_face,
          "with no sidecar, resolved import == plain import");

    FaceOverrides ov;
    ov.paint_faces = {{0, 1}};  // two triangles -> one painted face
    topopt::save_face_overrides(topopt::face_overrides_sidecar_path(stl), ov);
    const StepModel r1 = topopt::import_part_file_resolved(stl);
    const StepModel r2 = topopt::import_part_file_resolved(stl);
    CHECK(r1.face_count == plain.face_count + 1,
          "the sidecar's painted face appears on a resolved re-import");
    CHECK(r1.triangle_face[0] == r1.face_count - 1 &&
              r1.triangle_face[1] == r1.face_count - 1,
          "the painted triangles carry the new id on re-import");
    CHECK(r1.triangle_face == r2.triangle_face && r1.face_count == r2.face_count,
          "a resolved re-import is deterministic (same file bytes => same ids)");
  }

  if (g_failures == 0)
    std::printf("face overrides: all %d checks passed\n", g_checks);
  else
    std::fprintf(stderr, "face overrides: %d/%d checks FAILED\n", g_failures, g_checks);
  return g_failures == 0 ? 0 : 1;
}
