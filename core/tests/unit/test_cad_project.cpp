// test_cad_project.cpp — task 2026-08-06-cad-face-projection, bar R2.
//
// THE FAILING TEST, FIRST. A fixture with a KNOWN cylinder and a KNOWN plane is
// voxelized and exported through the SHIPPED export path
// (marching_cubes_resampled at the job's smooth_factor, Tricubic — the same call
// core/src/cli/run_job.cpp:321 makes), and the test asserts BOTH halves of the
// claim:
//
//   BEFORE — the exported surface is OFF NOMINAL. The bore is not round and the
//            flat face is not flat, by a margin stated in voxels. If this ever
//            stops holding, the whole task is moot and the test says so instead
//            of passing vacuously.
//   AFTER  — projection puts every attributed vertex EXACTLY on its own analytic
//            surface: the bore radius equals the B-rep's nominal radius and the
//            flat face lies in the B-rep's nominal plane, both to floating-point.
//
// Every threshold below is stated as a fraction of ONE VOXEL, which the test
// prints, and the reference for every deviation is the fixture's OWN nominal
// StepFaceInfo — never a fit to the exported mesh.
//
// OCCT-FREE: the fixture's StepModel is built in code (a hand-tessellated box
// with a through-bore plus the exact StepFaceInfo each face carries), so this
// runs in every configuration including the Linux CI runner without OCCT.

#include "topopt/cad_project.hpp"
#include "topopt/mesh.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstdio>
#include <vector>

using namespace topopt;

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

namespace {

// ── the fixture: a 40 x 40 x 20 mm block with a 6 mm-radius through-bore ─────
//
// Six planar faces (ids 0..5) and one cylindrical face (id 6). Every
// StepFaceInfo is EXACT by construction — this is the "the CAD knows the answer"
// half of the task, made concrete.

constexpr double kLx = 40.0, kLy = 40.0, kLz = 20.0;
constexpr double kCx = 20.0, kCy = 20.0;
constexpr double kR = 6.0;
constexpr int kSeg = 64;  // bore segments; also the square-boundary sampling

// Face ids.
enum : int { F_BOT = 0, F_TOP = 1, F_X0 = 2, F_X1 = 3, F_Y0 = 4, F_Y1 = 5,
             F_BORE = 6 };

// The 64 points that walk the outer square boundary counter-clockwise seen from
// +Z, starting at (0,0): 16 per side.
Vec3 square_point(int i, double z) {
  const int per = kSeg / 4;
  const int side = i / per;
  const double t = static_cast<double>(i % per) / static_cast<double>(per);
  switch (side) {
    case 0: return {kLx * t, 0.0, z};
    case 1: return {kLx, kLy * t, z};
    case 2: return {kLx * (1.0 - t), kLy, z};
    default: return {0.0, kLy * (1.0 - t), z};
  }
}

Vec3 circle_point(int i, double z) {
  const double a = 2.0 * M_PI * static_cast<double>(i) / static_cast<double>(kSeg);
  return {kCx + kR * std::cos(a), kCy + kR * std::sin(a), z};
}

// Which planar face does outer-boundary index i lie on? (Corner points belong to
// the side they start; the strip triangles are emitted per side, so a corner
// vertex is shared but every TRIANGLE has one unambiguous face.)
int side_face(int i) {
  const int per = kSeg / 4;
  switch (i / per) {
    case 0: return F_Y0;
    case 1: return F_X1;
    case 2: return F_Y1;
    default: return F_X0;
  }
}

struct Fixture {
  StepModel model;
};

Fixture build_fixture() {
  Fixture fx;
  TriangleMesh& m = fx.model.mesh;
  std::vector<int>& tf = fx.model.triangle_face;

  // vertex layout: square bottom [0,kSeg), square top, circle bottom, circle top
  const int SB = 0, ST = kSeg, CB = 2 * kSeg, CT = 3 * kSeg;
  for (int i = 0; i < kSeg; ++i) m.vertices.push_back(square_point(i, 0.0));
  for (int i = 0; i < kSeg; ++i) m.vertices.push_back(square_point(i, kLz));
  for (int i = 0; i < kSeg; ++i) m.vertices.push_back(circle_point(i, 0.0));
  for (int i = 0; i < kSeg; ++i) m.vertices.push_back(circle_point(i, kLz));

  auto tri = [&](int a, int b, int c, int face) {
    m.triangles.push_back({a, b, c});
    tf.push_back(face);
  };

  for (int i = 0; i < kSeg; ++i) {
    const int j = (i + 1) % kSeg;
    // bottom annulus (outward normal -Z => clockwise seen from +Z)
    tri(SB + i, CB + i, SB + j, F_BOT);
    tri(SB + j, CB + i, CB + j, F_BOT);
    // top annulus (outward normal +Z)
    tri(ST + i, ST + j, CT + i, F_TOP);
    tri(ST + j, CT + j, CT + i, F_TOP);
    // outer side wall (outward normal points away from the block)
    tri(SB + i, SB + j, ST + i, side_face(i));
    tri(SB + j, ST + j, ST + i, side_face(i));
    // bore wall (outward normal points INTO the hole, i.e. toward the axis)
    tri(CB + i, CT + i, CB + j, F_BORE);
    tri(CB + j, CT + i, CT + j, F_BORE);
  }

  fx.model.face_count = 7;
  fx.model.faces.assign(7, StepFaceInfo{});
  auto plane = [&](int id, Vec3 n, Vec3 o) {
    fx.model.faces[static_cast<std::size_t>(id)].kind = StepSurfaceKind::Plane;
    fx.model.faces[static_cast<std::size_t>(id)].plane_normal = n;
    fx.model.faces[static_cast<std::size_t>(id)].plane_origin = o;
  };
  plane(F_BOT, {0, 0, -1}, {0, 0, 0.0});
  plane(F_TOP, {0, 0, 1}, {0, 0, kLz});
  plane(F_X0, {-1, 0, 0}, {0.0, 0, 0});
  plane(F_X1, {1, 0, 0}, {kLx, 0, 0});
  plane(F_Y0, {0, -1, 0}, {0, 0.0, 0});
  plane(F_Y1, {0, 1, 0}, {0, kLy, 0});
  StepFaceInfo& b = fx.model.faces[F_BORE];
  b.kind = StepSurfaceKind::Cylinder;
  b.cylinder_radius_mm = kR;
  b.axis_point = {kCx, kCy, 0.0};
  b.axis_dir = {0, 0, 1};
  return fx;
}

}  // namespace

int main() {
  const Fixture fx = build_fixture();
  std::printf("fixture: %zu verts, %zu tris, %d faces "
              "(6 Plane + 1 Cylinder r=%.4f mm)\n",
              fx.model.mesh.vertices.size(), fx.model.mesh.triangles.size(),
              fx.model.face_count, kR);
  CHECK(check_watertight(fx.model.mesh).watertight,
        "the fixture must be watertight or the voxelization means nothing");

  // ── the SHIPPED export path, on the fixture ────────────────────────────────
  const int kRes = 48;
  const VoxelGrid grid = voxelize(fx.model.mesh, kRes);
  std::printf("grid %d x %d x %d, ONE VOXEL %.6f mm\n", grid.nx, grid.ny,
              grid.nz, grid.spacing);
  CHECK(grid.spacing > 0.0, "voxelization produced a degenerate grid");

  std::vector<double> occ(grid.voxel_count(), 0.0);
  for (std::size_t i = 0; i < occ.size(); ++i)
    if (grid.tags[i] != VoxelTag::Empty) occ[i] = 1.0;
  // factor 2 + Tricubic is exactly what run_job.cpp:321 does for the
  // maintainer's job (output.smooth_factor = 2).
  const TriangleMesh exported = marching_cubes_resampled(
      grid.nx, grid.ny, grid.nz, grid.spacing, grid.origin, occ, 0.5, 2,
      ResampleInterp::Tricubic);
  std::printf("exported: %zu verts, %zu tris\n", exported.vertices.size(),
              exported.triangles.size());
  CHECK(!exported.vertices.empty(), "the exported iso-surface is empty");

  CadProjectOptions opt = cad_project_options_for_grid(grid.spacing);
  CHECK(!CadProjectOptions{}.enabled,
        "the projection option must DEFAULT to OFF");
  opt.enabled = true;
  const CadAttribution att = attribute_to_cad_faces(exported, fx.model, opt);
  std::printf("attributed %zu / %zu (Plane %zu, Cylinder %zu, ambiguous %zu)\n",
              att.attributed, exported.vertices.size(), att.n_plane,
              att.n_cylinder, att.ambiguous);
  CHECK(att.n_cylinder > 100,
        "the bore must carry a substantial vertex population, or the AFTER "
        "assertion below would pass on an empty set");
  CHECK(att.n_plane > 100, "the planar faces must carry vertices too");

  // ── BEFORE: the exported surface is OFF NOMINAL ────────────────────────────
  const std::vector<BoreRoundness> bores0 = measure_bores(exported, fx.model, att);
  const std::vector<FaceFlatness> flats0 = measure_flats(exported, fx.model, att);
  CHECK(bores0.size() == 1, "exactly one cylindrical face should carry vertices");
  double oor0 = 0.0, rms_r0 = 0.0;
  for (const BoreRoundness& b : bores0) {
    oor0 = std::fmax(oor0, b.out_of_roundness_mm);
    rms_r0 = std::fmax(rms_r0, b.rms_error_mm);
    std::printf("BEFORE bore face %d: nominal %.4f, measured min %.4f max %.4f "
                "mean %.4f, out-of-roundness %.4f mm (%.3f voxel), rms error "
                "%.4f mm\n",
                b.face_id, b.nominal_radius_mm, b.min_mm, b.max_mm, b.mean_mm,
                b.out_of_roundness_mm, b.out_of_roundness_mm / grid.spacing,
                b.rms_error_mm);
  }
  double flat0 = 0.0;
  for (const FaceFlatness& f : flats0) flat0 = std::fmax(flat0, f.max_abs_mm);
  std::printf("BEFORE worst planar face: max |deviation from its own nominal "
              "plane| %.6f mm (%.3f voxel)\n", flat0, flat0 / grid.spacing);

  // The BEFORE bars. Stated in voxels, and deliberately well clear of zero so
  // they cannot be met by numerical noise.
  CHECK(oor0 > 0.20 * grid.spacing,
        "BEFORE: the exported bore must be measurably out of round (> 0.20 "
        "voxel) — otherwise there is nothing to fix");
  CHECK(rms_r0 > 0.05 * grid.spacing,
        "BEFORE: the exported bore radius must be measurably off nominal "
        "(rms > 0.05 voxel)");
  CHECK(flat0 > 0.10 * grid.spacing,
        "BEFORE: the exported flat faces must be measurably off their own "
        "nominal planes (> 0.10 voxel)");

  // ── AFTER: projection is EXACT ─────────────────────────────────────────────
  CadProjectionStats st;
  const TriangleMesh proj =
      project_onto_cad_faces(exported, fx.model, opt, att, &st);
  std::printf("projected: moved %zu (Plane %zu, Cylinder %zu), refused by guard "
              "%zu, max move %.6f mm (%.4f voxel)\n",
              st.moved, st.moved_plane, st.moved_cylinder, st.refused_by_guard,
              st.max_move_mm, st.max_move_mm / grid.spacing);

  CHECK(proj.vertices.size() == exported.vertices.size(),
        "projection must not change the vertex count");
  CHECK(proj.triangles.size() == exported.triangles.size(),
        "projection must not change the triangle count");
  for (std::size_t t = 0; t < proj.triangles.size(); ++t)
    if (proj.triangles[t] != exported.triangles[t]) {
      CHECK(false, "projection must not change the triangle indices");
      break;
    }

  // AFTER is read over the vertices the projection actually placed: any the fold
  // guard had to put back are excluded, and their number is asserted separately
  // just below so the exclusion can never quietly grow.
  const std::vector<BoreRoundness> bores1 =
      measure_bores(proj, fx.model, att, &st.reverted);
  const std::vector<FaceFlatness> flats1 =
      measure_flats(proj, fx.model, att, &st.reverted);
  std::printf("fold guard put back %zu of %zu projected vertices (%.4f%%)\n",
              st.reverted_by_fold_guard, st.moved + st.reverted_by_fold_guard,
              100.0 * static_cast<double>(st.reverted_by_fold_guard) /
                  static_cast<double>(st.moved + st.reverted_by_fold_guard));
  CHECK(st.reverted_by_fold_guard * 100 <=
            (st.moved + st.reverted_by_fold_guard),
        "the fold guard must put back under 1% of the projected vertices — "
        "more than that means the projection is fighting the mesh, not "
        "correcting it");

  // EXACT means exact: 1e-9 mm is a nanometre, twelve orders below the voxel.
  const double kExact = 1e-9;
  for (const BoreRoundness& b : bores1) {
    std::printf("AFTER  bore face %d: nominal %.6f, measured min %.6f max "
                "%.6f, out-of-roundness %.3e mm, rms error %.3e mm\n",
                b.face_id, b.nominal_radius_mm, b.min_mm, b.max_mm,
                b.out_of_roundness_mm, b.rms_error_mm);
    CHECK(b.out_of_roundness_mm <= kExact,
          "AFTER: the bore must be round to floating-point about its own "
          "nominal axis");
    CHECK(std::fabs(b.min_mm - b.nominal_radius_mm) <= kExact &&
              std::fabs(b.max_mm - b.nominal_radius_mm) <= kExact,
          "AFTER: every bore vertex must sit at the B-rep's OWN nominal radius");
  }
  double flat1 = 0.0;
  for (const FaceFlatness& f : flats1) flat1 = std::fmax(flat1, f.max_abs_mm);
  std::printf("AFTER  worst planar face: max |deviation| %.3e mm\n", flat1);
  CHECK(flat1 <= kExact,
        "AFTER: every attributed planar vertex must lie in the B-rep's OWN "
        "nominal plane to floating-point");

  // Nothing moved further than the guard, and the guard is one voxel.
  CHECK(st.max_move_mm <= opt.max_move_mm + kExact,
        "no vertex may move further than the motion guard");
  CHECK(st.refused_by_guard == 0,
        "on a fixture whose every surface IS a CAD face, no projection should "
        "have to be refused");

  // THE PROJECTION ITSELF NEVER TOUCHES OPTIMIZER-CUT SURFACE. Asserted on the
  // projection alone, i.e. with the seam transition band switched off, because
  // that is the claim: no vertex without a known answer is given one.
  {
    CadProjectOptions no_band = opt;
    no_band.seam_blend_rings = 0;
    CadProjectionStats st_nb;
    const TriangleMesh pure =
        project_onto_cad_faces(exported, fx.model, no_band, att, &st_nb);
    std::size_t unattributed = 0, moved_unattributed = 0;
    for (std::size_t i = 0; i < exported.vertices.size(); ++i) {
      if (att.face_of_vertex[i] >= 0) continue;
      ++unattributed;
      const Vec3 a = exported.vertices[i], b = pure.vertices[i];
      if (a.x != b.x || a.y != b.y || a.z != b.z) ++moved_unattributed;
    }
    std::printf("band OFF: unattributed vertices %zu, of which moved %zu "
                "(must be 0)\n", unattributed, moved_unattributed);
    CHECK(moved_unattributed == 0,
          "with the transition band off, an unattributed (optimizer-cut) vertex "
          "must never be moved");
    CHECK(st_nb.blended == 0,
          "with the transition band off, nothing may be blended");
  }

  // WITH THE BAND ON, exactly the optimizer-cut vertices may move, never an
  // attributed one, and never further than the projection itself moved anything.
  {
    std::size_t moved_attributed_beyond_projection = 0, moved_unattributed = 0;
    for (std::size_t i = 0; i < exported.vertices.size(); ++i) {
      const Vec3 a = exported.vertices[i], b = proj.vertices[i];
      const bool did_move = (a.x != b.x || a.y != b.y || a.z != b.z);
      if (!did_move) continue;
      if (att.face_of_vertex[i] >= 0) continue;  // projected: checked above
      ++moved_unattributed;
      const double d = std::sqrt((a.x - b.x) * (a.x - b.x) +
                                 (a.y - b.y) * (a.y - b.y) +
                                 (a.z - b.z) * (a.z - b.z));
      if (d > st.max_move_mm + 1e-12) ++moved_attributed_beyond_projection;
    }
    std::printf("band ON (%d rings): %zu optimizer-cut vertices carried, "
                "furthest %.6f mm; projection's own max %.6f mm\n",
                opt.seam_blend_rings, moved_unattributed, st.max_blend_mm,
                st.max_move_mm);
    CHECK(moved_unattributed == st.blended,
          "every optimizer-cut vertex that moved must be one the transition "
          "band reports carrying — no others");
    CHECK(moved_attributed_beyond_projection == 0,
          "the transition band may never carry a vertex further than the "
          "projection itself moved anything");
    CHECK(st.max_blend_mm <= st.max_move_mm + 1e-12,
          "the band's displacement is bounded by the projection's");
  }

  // THE FOLD GUARD: the exported mesh must not come back with a folded facet.
  std::printf("fold guard: %zu band vertices put back, %zu projected vertices "
              "put back, %zu inverted triangles left (%.6f mm^2)\n",
              st.reverted_band, st.reverted_by_fold_guard,
              st.inverted_triangles_remaining, st.inverted_area_mm2);
  CHECK(st.inverted_triangles_remaining == 0,
        "the projection must not leave a single triangle with a reversed "
        "normal");
  CHECK(check_watertight(proj).watertight,
        "the projected mesh must still be watertight");

  // A caller that turns both kinds off gets its mesh back unchanged — the
  // in-library form of the byte-identity bar.
  {
    CadProjectOptions off = opt;
    off.project_planes = false;
    off.project_cylinders = false;
    CadProjectionStats st_off;
    const TriangleMesh same =
        project_onto_cad_faces(exported, fx.model, off, att, &st_off);
    bool identical = same.vertices.size() == exported.vertices.size();
    for (std::size_t i = 0; identical && i < same.vertices.size(); ++i)
      identical = same.vertices[i].x == exported.vertices[i].x &&
                  same.vertices[i].y == exported.vertices[i].y &&
                  same.vertices[i].z == exported.vertices[i].z;
    CHECK(identical && st_off.moved == 0,
          "with both kinds disabled the mesh must come back untouched");
  }

  // The tolerances are derived from the voxel in ONE place, and they are the
  // numbers the handoff quotes.
  {
    const CadProjectOptions o = cad_project_options_for_grid(2.0);
    CHECK(o.enabled == false, "cad_project_options_for_grid must default OFF");
    CHECK(std::fabs(o.tolerance_mm - 2.0) < 1e-12,
          "attribution tolerance must be ONE voxel");
    CHECK(std::fabs(o.max_move_mm - 2.0) < 1e-12,
          "motion guard must be ONE voxel");
    CHECK(std::fabs(o.ambiguity_band_mm - 0.2) < 1e-12,
          "ambiguity band must be 0.10 voxel");
    CHECK(std::fabs(o.voxel_mm - 2.0) < 1e-12,
          "the voxel spacing must be carried for reporting");
  }

  std::printf("%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
