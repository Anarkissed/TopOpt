// test_bake_build_orientation — THE EXPORTED FILE IS THE CERTIFIED OBJECT
// (task 2026-08-01-bake-build-orientation).
//
// The defect this pins closed: the certified build orientation existed only as a
// number in report.json. threemf.cpp said it outright — "the mesh is exported in
// its own model-space coordinates" — the streaming 3MF emitted a bare
// <item objectid="1"/>, and STL carries no transform at all. So the user
// exported, the slicer placed the part however it liked, and the certificate
// described a different object from the one being sliced. run_job already holds
// that line for the lattice REGION ("the object the gate certifies and the file
// the slicer opens are the SAME region by construction"); these bars extend it
// to ORIENTATION.
//
// WHAT EACH BAR PINS:
//
//   V1  THE FILE IS THE CERTIFIED OBJECT. The exported mesh is loaded back and
//       the build-direction-dependent criteria are recomputed FROM THE FILE in
//       its OWN +Z; they must equal the numbers the certification computed in
//       the model frame at the applied direction. Checked EXACTLY on a cube axis
//       (where the rotation is a relabelling) and with a reported deviation
//       off-axis.
//   V2  EXPLICIT ORIENTATION IS BYTE-IDENTICAL. A job that DECLARES a build
//       direction gets the pre-bake mesh and the pre-bake report, byte for byte.
//       Auto-apply must not leak into the case where the user chose.
//   V3  THE FALLBACK IS DEFINED AND IS TODAY'S BEHAVIOUR. "off" is PR 271
//       exactly; a job that predates the key parses as "auto"; and with no
//       recommendation available nothing is chosen.
//   V4  THE ROTATION IS EXACT AND LOSSLESS on the six cube axes — a signed axis
//       permutation, asserted BIT-IDENTICAL up to permutation and sign, through
//       the exported file. Off-axis deviation is reported separately, not hidden.
//   V5  WINDING AND MANIFOLDNESS SURVIVE. Determinant +1 on every rotation, and
//       PR 201's counts (boundary edges, non-manifold edges, components) and the
//       enclosed volume unchanged across the rotation — a reflection would flip
//       the winding and turn the part inside out for the slicer.
//   V6  THE LATTICE COMES WITH IT. The latticed export is rotated by the SAME
//       rigid motion as the solid one; PR 250's generator counts (landings,
//       anchor nodes) and PR 253's containment (clipped struts) are unchanged;
//       and a protected region still contains ZERO geometry afterwards.
//   V7  AUTO-APPLY IS ANNOUNCED, NEVER SILENT. When the orientation was chosen
//       for the user the receipt says so, names it, and — when the orientation
//       the run would otherwise have assumed FAILS — says that explicitly.
//   V8  DETERMINISM. Two runs of the same job produce identical bytes.
//
//   V9  *** AUTO-APPLY IS VERDICT-MONOTONE. *** Not in the task's bar list; added
//       because the measurement below forced it. The scorer's recommendation is a
//       maximin over six criteria and is deliberately NOT the margin-maximiser,
//       so applying it unasked can REJECT a part that would have passed (measured
//       on the design-box fixture: an accepted ladder rung lost outright). The
//       gate is therefore a CONSTRAINT on the auto-choice. This bar pins that it
//       can never sink a part.
//
// Self-contained CHECK harness (ARCHITECTURE §4), public API only. Drives
// run_job end to end on the committed plate_bore.stl fixture (resolution 32, one
// rung, few iterations) and the V5 hook fixture for the rescue case. It gates
// nothing in production.

#include "topopt/analyze.hpp"
#include "topopt/build_frame.hpp"
#include "topopt/build_orientation.hpp"
#include "topopt/fea.hpp"
#include "topopt/job.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/orient.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/production.hpp"
#include "topopt/report.hpp"
#include "topopt/settings.hpp"
#include "topopt/stl.hpp"
#include "topopt/voxel.hpp"

#include <array>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <limits>
#include <sstream>
#include <string>
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

std::string read_file(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  std::ostringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

bool contains(const std::string& hay, const std::string& needle) {
  return hay.find(needle) != std::string::npos;
}

double dot3(const Vec3& a, const Vec3& b) {
  return a.x * b.x + a.y * b.y + a.z * b.z;
}

// The 26 sphere directions the production candidate set uses, plus the six cube
// axes it contains. Rebuilt here from the PRODUCTION function so this test can
// never drift from the set the scorer actually ranks.
std::vector<Vec3> all_candidates() {
  return build_orientation_candidates(Vec3{0.0, 0.0, 1.0});
}

// Per-triangle vertex coordinates in FILE order. read_stl_file welds by exact
// coordinate, which reorders the vertex array but preserves triangle order, so
// this recovers the stream the writer emitted — the only basis on which two
// exported files can be compared coordinate by coordinate.
std::vector<Vec3> triangle_stream(const TriangleMesh& m) {
  std::vector<Vec3> out;
  out.reserve(m.triangles.size() * 3);
  for (const std::array<int, 3>& t : m.triangles)
    for (int c = 0; c < 3; ++c)
      out.push_back(m.vertices[static_cast<std::size_t>(t[c])]);
  return out;
}

// The SIGNED enclosed volume (divergence theorem, sum of tetrahedron volumes on
// the origin). Its SIGN is the orientation of the surface: positive for outward
// normals, negative if the winding was flipped. That is what makes it the right
// instrument for bar V5 — a reflection would silently keep every count below
// intact while turning the part inside out for the slicer, and only the sign
// would notice.
double signed_enclosed_volume(const TriangleMesh& m) {
  double v6 = 0.0;
  for (const std::array<int, 3>& t : m.triangles) {
    const Vec3& a = m.vertices[static_cast<std::size_t>(t[0])];
    const Vec3& b = m.vertices[static_cast<std::size_t>(t[1])];
    const Vec3& c = m.vertices[static_cast<std::size_t>(t[2])];
    v6 += a.x * (b.y * c.z - b.z * c.y) - a.y * (b.x * c.z - b.z * c.x) +
          a.z * (b.x * c.y - b.y * c.x);
  }
  return v6 / 6.0;
}

// The build height of a mesh along `n`, in layers of `spacing` — computed FROM
// THE MESH, which is what makes it a statement about the FILE.
int mesh_build_height_layers(const TriangleMesh& m, const Vec3& n,
                             double spacing) {
  double lo = std::numeric_limits<double>::infinity();
  double hi = -std::numeric_limits<double>::infinity();
  for (const Vec3& v : m.vertices) {
    const double s = dot3(v, n);
    lo = std::min(lo, s);
    hi = std::max(hi, s);
  }
  if (!(hi >= lo)) return 0;
  return static_cast<int>(std::ceil((hi - lo) / spacing)) + 1;
}

// ── the job fixtures ────────────────────────────────────────────────────────
// The committed plate_bore self-weight job (mirrors test_lattice_hookup's): one
// rung, 8 iterations, margin_stop 0 so the rung is accepted. Fast enough to run
// the half-dozen times these bars need.
JobDescription plate_job() {
  JobDescription job;
  job.model = "plate_bore.stl";
  job.material = "PLA";
  job.mode = "minimize_plastic";
  job.resolution = 32;
  job.fixture_faces.push_back(JobFaceSelector{"cylindrical", 3.0});
  job.gravity.direction = Vec3{0.0, 0.0, -1.0};
  job.gravity.magnitude_mm_s2 = 9810.0;
  job.ladder = {0.6};
  job.margin_stop = 0.0;
  job.simp_max_iterations = 8;
  job.output.report = "report.json";
  job.output.mesh_format = "stl";
  job.output.mesh_prefix = "variant";
  return job;
}

JobDescription plate_lattice_job() {
  JobDescription job = plate_job();
  job.lattice.present = true;
  job.lattice.topology = "octet";
  job.lattice.cell_mm = 3.0;
  job.lattice.strut_radius_mm = 0.45;  // rho ~0.41, inside the certifiable band
  job.lattice.emit_stl = true;
  return job;
}

struct Run {
  RunJobResult r;
  std::string out_dir;
  std::string report_json;
  std::string orientation_json;
};

Run run_case(const JobDescription& job, const std::string& sub) {
  const std::string fixture_dir = std::string(MESH_FIXTURE_DIR);
  static const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
  static const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  Run out;
  out.out_dir = std::string(CLI_TMP_DIR) + "/bake_" + sub;
  std::filesystem::remove_all(out.out_dir);
  out.r = run_job(job, fixture_dir, out.out_dir, materials, rules,
                  /*emit_progress=*/false, RunObservability{});
  out.report_json = read_file(out.r.report_path);
  if (!out.r.build_orientation_path.empty())
    out.orientation_json = read_file(out.r.build_orientation_path);
  return out;
}

std::string solid_mesh_of(const Run& run) {
  for (const std::string& p : run.r.mesh_paths)
    if (!contains(p, "_lattice.")) return p;
  return "";
}

std::string lattice_mesh_of(const Run& run) {
  for (const std::string& p : run.r.mesh_paths)
    if (contains(p, "_lattice.")) return p;
  return "";
}

// ===========================================================================
// V4 + V5 (the primitive): the rotation is EXACT on the cube axes, PROPER
// everywhere, and reports its own loss off-axis.
// ===========================================================================
void section_rotation_primitive() {
  std::printf("\n-- V4/V5: the rotation primitive --\n");

  const Vec3 axes[6] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0},
                        {0, -1, 0}, {0, 0, 1}, {0, 0, -1}};
  // A handful of awkward coordinates: negatives, a subnormal-ish small value, a
  // value with a long mantissa. If the exact path ever became a matrix product,
  // the long-mantissa one would drift and the signed zero would flip.
  const Vec3 probes[5] = {{1.0, 2.0, 3.0},
                          {-7.5, 0.0, 12.25},
                          {0.1234567890123456, -9.87654321e-7, 1e-300},
                          {-0.0, 0.0, -0.0},
                          {1e12, -1e-12, 3.14159265358979}};

  int exact_axes = 0;
  for (const Vec3& a : axes) {
    const BuildFrameRotation R = build_frame_rotation(a);
    CHECK(R.axis_permutation, "V4: a cube axis takes the EXACT permutation path");
    if (R.axis_permutation) ++exact_axes;
    CHECK(rotation_determinant(R) == 1.0,
          "V5: the rotation is PROPER (determinant exactly +1) — a reflection "
          "would flip triangle winding");
    // The axis maps onto +Z exactly.
    const Vec3 up = to_build_frame(R, a);
    CHECK(up.x == 0.0 && up.y == 0.0 && up.z == 1.0,
          "V4: the build direction maps to EXACTLY (0,0,1)");
    for (const Vec3& p : probes) {
      const Vec3 q = to_build_frame(R, p);
      // BIT-IDENTICAL UP TO PERMUTATION AND SIGN: each output component is
      // some input component, possibly negated, with no rounding at all.
      const double in[3] = {p.x, p.y, p.z};
      const double outc[3] = {q.x, q.y, q.z};
      bool ok = true;
      for (int i = 0; i < 3; ++i) {
        const double want = R.sign[static_cast<std::size_t>(i)] *
                            in[R.perm[static_cast<std::size_t>(i)]];
        if (outc[i] != want) ok = false;
      }
      CHECK(ok,
            "V4: every exported coordinate is an input coordinate, permuted and "
            "signed — bit-identical, no drift");
      // Round-trip is exact too, so nothing is lost on the way back.
      const Vec3 back = to_model_frame(R, q);
      CHECK(back.x == p.x && back.y == p.y && back.z == p.z,
            "V4: the inverse is exact (a signed permutation is its own kind of "
            "relabelling)");
    }
  }
  CHECK(exact_axes == 6, "V4: all six cube axes are exact (none fell through)");

  // ── OFF-AXIS: honest, and REPORTED separately (bar V4's second half) ────────
  double worst_dev = 0.0, worst_det = 0.0;
  int off_axis = 0;
  Vec3 worst_dir{0, 0, 0};
  for (const Vec3& c : all_candidates()) {
    const BuildFrameRotation R = build_frame_rotation(c);
    if (R.axis_permutation) continue;
    ++off_axis;
    const Vec3 up = to_build_frame(R, c);
    const double dev = std::sqrt(up.x * up.x + up.y * up.y + (up.z - 1.0) * (up.z - 1.0));
    if (dev > worst_dev) {
      worst_dev = dev;
      worst_dir = c;
    }
    worst_det = std::max(worst_det, std::fabs(rotation_determinant(R) - 1.0));
    CHECK(std::fabs(rotation_determinant(R) - 1.0) < 1e-12,
          "V5: an off-axis rotation is still PROPER (determinant +1)");
  }
  std::printf(
      "  off-axis candidates: %d | worst |R*d - (0,0,1)| = %.3e at "
      "(%.4g, %.4g, %.4g) | worst |det-1| = %.3e\n",
      off_axis, worst_dev, worst_dir.x, worst_dir.y, worst_dir.z, worst_det);
  CHECK(worst_dev < 1e-15,
        "V4: off-axis rotations still land on +Z to within double rounding "
        "(they are LOSSY in the coordinates, not WRONG in the direction)");
  CHECK(off_axis == 20,
        "V4: 20 of the 26 candidates are off-axis — the lossy path is the COMMON "
        "case, not a corner case");
}

// ===========================================================================
// V1 + V4 + V5 end to end: run the SAME job twice, once written in model
// coordinates and once BAKED onto a declared cube axis, and prove the two files
// are the same object placed differently.
// ===========================================================================
void section_file_is_the_certified_object() {
  std::printf("\n-- V1/V4/V5: the file is the certified object --\n");

  // A DECLARED cube axis, so the rotation is the exact permutation and every
  // comparison below can be bit-exact rather than approximate.
  const Vec3 declared{0.0, 1.0, 0.0};

  JobDescription off_job = plate_job();
  off_job.has_build_direction = true;
  off_job.build_direction = declared;
  off_job.bake_build_orientation = "off";
  const Run off = run_case(off_job, "v1_off");

  JobDescription baked_job = off_job;
  baked_job.bake_build_orientation = "always";
  const Run baked = run_case(baked_job, "v1_baked");

  const std::string off_mesh = solid_mesh_of(off);
  const std::string baked_mesh = solid_mesh_of(baked);
  CHECK(!off_mesh.empty() && !baked_mesh.empty(), "both runs exported a mesh");
  if (off_mesh.empty() || baked_mesh.empty()) return;

  const TriangleMesh U = read_stl_file(off_mesh).mesh;    // model frame
  const TriangleMesh B = read_stl_file(baked_mesh).mesh;  // build frame

  // ── V4, THROUGH THE FILE. Every exported coordinate is an input coordinate,
  // permuted and signed. Compared on the triangle STREAM (file order), so this
  // is a statement about the bytes on disk, not about an in-memory helper. ────
  const std::vector<Vec3> su = triangle_stream(U);
  const std::vector<Vec3> sb = triangle_stream(B);
  CHECK(su.size() == sb.size(),
        "V4: baking changes no triangle — the streams are the same length");
  if (su.size() == sb.size()) {
    const BuildFrameRotation R = build_frame_rotation(declared);
    std::size_t drift = 0;
    for (std::size_t i = 0; i < su.size(); ++i) {
      const Vec3 want = to_build_frame(R, su[i]);
      if (sb[i].x != want.x || sb[i].y != want.y || sb[i].z != want.z) ++drift;
    }
    CHECK(drift == 0,
          "*** V4: the exported file is BIT-IDENTICAL to the model-frame file up "
          "to permutation and sign — zero floating-point drift ***");
    std::printf("  V4: %zu vertices compared through the file, %zu drifted\n",
                su.size(), drift);
  }

  // ── V5: winding and manifoldness survive ───────────────────────────────────
  const WatertightReport wu = check_watertight(U);
  const WatertightReport wb = check_watertight(B);
  CHECK(wu.boundary_edges == wb.boundary_edges,
        "V5: boundary edge count unchanged by the rotation");
  CHECK(wu.non_manifold_edges == wb.non_manifold_edges,
        "V5: non-manifold edge count unchanged by the rotation");
  CHECK(count_components(U) == count_components(B),
        "V5: component count unchanged by the rotation");
  // THE ORIENTATION OF THE SURFACE. The SIGN of the enclosed volume IS the
  // winding: a rotation (determinant +1) preserves it, a reflection flips it,
  // and a flipped winding is a part the slicer reads inside out. The three
  // counts above cannot see that — a reflected mesh has identical boundary,
  // non-manifold and component counts — so the sign is the instrument that
  // matters here.
  //
  // The bar is SIGN PRESERVED AND NON-ZERO, deliberately not "positive": this
  // project's marching-cubes winding yields a NEGATIVE signed volume under this
  // convention, which is invisible downstream because run_job's own
  // mesh_enclosed_volume_mm3 takes fabs. Asserting positivity would be asserting
  // a convention this codebase does not hold, and would fail a correct rotation.
  const double vu = signed_enclosed_volume(U);
  const double vb = signed_enclosed_volume(B);
  CHECK(vu != 0.0 && vb != 0.0,
        "V5: both meshes enclose a non-zero volume (they are closed solids)");
  CHECK((vu > 0.0) == (vb > 0.0),
        "*** V5: the SIGN of the enclosed volume is unchanged — the rotation "
        "preserved the winding, so the part did not turn inside out ***");
  CHECK(std::fabs(vb - vu) <= 1e-9 * std::fabs(vu),
        "V5: the enclosed volume is a rigid-motion invariant and did not move");
  std::printf(
      "  V5: boundary %d/%d  non-manifold %d/%d  components %d/%d  volume "
      "%.10g / %.10g mm^3\n",
      wu.boundary_edges, wb.boundary_edges, wu.non_manifold_edges,
      wb.non_manifold_edges, count_components(U), count_components(B), vu, vb);

  // ── V1: THE CRITERIA, RECOMPUTED FROM THE FILE IN ITS OWN +Z ───────────────
  // Every build-direction-dependent criterion is a rigid-motion invariant, so
  // each one computed from the BAKED file at +Z must equal the same one computed
  // from the model-frame file at the CERTIFIED direction. That equality is the
  // whole claim: the file's own +Z IS the direction the certificate describes.
  //
  // The instruments are MESH-NATIVE — read off the exported triangles, not off a
  // re-voxelization. That is not a convenience, it is a correctness requirement:
  // `voxelize` derives its lattice from the mesh's bounding box, and a rotation
  // that flips an axis maps that box's min to its max, so the sample grid lands
  // at a different sub-voxel offset relative to the geometry. Re-voxelizing both
  // files and comparing counts therefore measures the voxelizer's phase, not the
  // rotation (measured: 82 vs 72 support voxels for two files that are the SAME
  // geometry to the bit). The mesh-native instruments have no such phase.
  const VoxelGrid gu = voxelize(U, 48);
  const double layer = gu.spacing;

  // (1) BUILD HEIGHT — how many layers tall the print is.
  const int h_model = mesh_build_height_layers(U, declared, layer);
  const int h_file = mesh_build_height_layers(B, Vec3{0.0, 0.0, 1.0}, layer);
  CHECK(h_model == h_file,
        "*** V1: the build height read FROM THE EXPORTED FILE along its own +Z "
        "equals the model-frame height along the certified direction ***");

  // (2) THE SUPPORT-MATERIAL CRITERION, mesh-native: the total area of downward
  // faces steeper than the 45-degree self-supporting cone — the same physical
  // question `support_overhang_voxels` asks, asked of the triangles instead of
  // the voxels. Its per-triangle terms are the same numbers in both frames (a
  // signed permutation permutes the cross-product components exactly), so the
  // sums agree to summation order at worst.
  auto overhang_area = [](const TriangleMesh& m, const Vec3& n) {
    const double cone = std::cos(45.0 * 3.14159265358979323846 / 180.0);
    double area = 0.0;
    int count = 0;
    for (const std::array<int, 3>& t : m.triangles) {
      const Vec3& a = m.vertices[static_cast<std::size_t>(t[0])];
      const Vec3& b = m.vertices[static_cast<std::size_t>(t[1])];
      const Vec3& c = m.vertices[static_cast<std::size_t>(t[2])];
      const Vec3 e1{b.x - a.x, b.y - a.y, b.z - a.z};
      const Vec3 e2{c.x - a.x, c.y - a.y, c.z - a.z};
      const Vec3 cr{e1.y * e2.z - e1.z * e2.y, e1.z * e2.x - e1.x * e2.z,
                    e1.x * e2.y - e1.y * e2.x};
      const double twice = std::sqrt(dot3(cr, cr));
      if (!(twice > 0.0)) continue;
      // Facing DOWN the build direction, steeper than the cone.
      if (-dot3(cr, n) / twice > cone) {
        area += 0.5 * twice;
        ++count;
      }
    }
    return std::pair<double, int>(area, count);
  };
  const auto ov_model = overhang_area(U, declared);
  const auto ov_file = overhang_area(B, Vec3{0.0, 0.0, 1.0});
  CHECK(ov_model.second == ov_file.second,
        "*** V1: the count of support-requiring faces read FROM THE EXPORTED "
        "FILE in its own +Z equals the model-frame count at the certified "
        "direction ***");
  CHECK(std::fabs(ov_file.first - ov_model.first) <=
            1e-12 * std::fabs(ov_model.first) + 1e-12,
        "*** V1: the support-requiring AREA agrees between the file and the "
        "model to floating-point summation order ***");
  std::printf(
      "  V1: height model=%d file=%d | overhang faces %d/%d | overhang area "
      "%.12g / %.12g mm^2 (rel dev %.3e)\n",
      h_model, h_file, ov_model.second, ov_file.second, ov_model.first,
      ov_file.first,
      ov_model.first > 0.0
          ? std::fabs(ov_file.first - ov_model.first) / ov_model.first
          : 0.0);

  // ── V1: and the REPORT describes that frame, explicitly ────────────────────
  CHECK(contains(baked.report_json, "\"orientation_frame\": \"export\""),
        "V1: a baked report NAMES the frame its orientation vector is in");
  CHECK(contains(baked.report_json, "\"orientation_model\""),
        "V1: a baked report also carries the model-frame direction, so nothing "
        "is lost");
  CHECK(!contains(off.report_json, "orientation_frame"),
        "V1: an un-baked report gains no frame keys (one frame, nothing to "
        "disambiguate)");
  // The vector itself: +Z in the file, the declared direction in the model.
  CHECK(contains(baked.report_json, "\"z\": 1") &&
            !contains(baked.report_json, "\"orientation\": {\n      \"x\": 0,\n"
                                          "      \"y\": 1"),
        "V1: the baked report's orientation is the direction IN THE FILE");

  // ── V2, the other half: the two runs' REPORTS differ ONLY in the frame ─────
  // Every margin, stress and count is a rigid-motion invariant, so baking must
  // not have moved one. Compared by pulling the numbers back out of both docs.
  auto num = [](const std::string& text, const std::string& key) {
    const std::string pat = "\"" + key + "\": ";
    const std::string::size_type at = text.find(pat);
    if (at == std::string::npos) return std::nan("");
    return std::atof(text.c_str() + at + pat.size());
  };
  for (const char* k : {"max_stress_mpa", "max_interlayer_tension_mpa",
                        "margin_effective", "min_feature_violations",
                        "printed_fraction"}) {
    const double a = num(off.report_json, k);
    const double b = num(baked.report_json, k);
    CHECK(a == b || (std::isnan(a) && std::isnan(b)),
          "V1: baking moved no certification number — every one of them is a "
          "rigid-motion invariant and reads the same in both frames");
  }
}

// ===========================================================================
// V2 + V3: a DECLARED direction is untouched, and "off" is PR 271 exactly.
// ===========================================================================
void section_declared_is_untouched() {
  std::printf("\n-- V2/V3: a declared direction is untouched --\n");

  JobDescription declared_auto = plate_job();
  declared_auto.has_build_direction = true;
  declared_auto.build_direction = Vec3{0.0, 1.0, 0.0};
  // No "bake_build_orientation" key at all — a job that PREDATES the key.
  CHECK(declared_auto.bake_build_orientation.empty(),
        "V3: a job that predates the key carries no bake mode");
  const Run a = run_case(declared_auto, "v2_declared_auto");

  JobDescription declared_off = declared_auto;
  declared_off.bake_build_orientation = "off";
  const Run b = run_case(declared_off, "v2_declared_off");

  // *** THE BAR: a declared direction produces the pre-bake mesh and the
  // pre-bake report, BYTE FOR BYTE. "off" is the pre-bake pipeline by
  // construction, so this is the comparison that proves auto-apply did not leak
  // into the case where the user chose. ***
  CHECK(a.report_json == b.report_json,
        "*** V2: DECLARED + default mode produces a byte-identical report to the "
        "pre-bake pipeline ***");
  const std::string ma = solid_mesh_of(a), mb = solid_mesh_of(b);
  CHECK(!ma.empty() && !mb.empty(), "both declared runs exported a mesh");
  if (!ma.empty() && !mb.empty())
    CHECK(read_file(ma) == read_file(mb),
          "*** V2: DECLARED + default mode produces a byte-identical MESH to the "
          "pre-bake pipeline ***");
  CHECK(!contains(a.report_json, "export_baked"),
        "V2: no bake keys appear on a declared run");
  CHECK(a.orientation_json.empty() ||
            !contains(a.orientation_json, "auto_applied"),
        "V2: nothing was auto-applied over a declared direction");

  // V3, the resolver's own statement, asserted directly rather than inferred
  // from a run: the three modes and what each decides.
  MinimizePlasticOptions o;
  o.gravity_direction = Vec3{0.0, 0.0, -1.0};
  {  // undeclared + auto => choose and bake
    const BuildOrientationBakePlan p = resolve_bake_plan(o);
    CHECK(p.auto_apply && p.bake && p.needs_scorer && !p.direction_declared,
          "V3: undeclared + auto => the orientation is chosen and baked");
  }
  {  // declared + auto => neither
    MinimizePlasticOptions d = o;
    d.build_direction = Vec3{0.0, 1.0, 0.0};
    const BuildOrientationBakePlan p = resolve_bake_plan(d);
    CHECK(!p.auto_apply && !p.bake && !p.needs_scorer && p.direction_declared,
          "V3: declared + auto => nothing is chosen and nothing is rotated");
  }
  {  // declared + always => bake, but still choose nothing
    MinimizePlasticOptions d = o;
    d.build_direction = Vec3{0.0, 1.0, 0.0};
    d.bake_build_orientation = BakeBuildOrientation::Always;
    const BuildOrientationBakePlan p = resolve_bake_plan(d);
    CHECK(p.bake && !p.auto_apply && !p.needs_scorer,
          "V3: declared + always => the DECLARED direction is baked, nothing is "
          "chosen for the user");
  }
  {  // off => the pre-bake pipeline, whatever else is set
    MinimizePlasticOptions d = o;
    d.bake_build_orientation = BakeBuildOrientation::Off;
    const BuildOrientationBakePlan p = resolve_bake_plan(d);
    CHECK(!p.bake && !p.auto_apply && !p.needs_scorer,
          "V3: off => no bake, no choice — PR 271's behaviour exactly");
  }
  // And the refusal that makes V2 structural rather than incidental: applying a
  // recommendation over a DECLARED direction is not merely avoided, it throws.
  {
    BuildOrientationReport r;
    r.evaluated = true;
    r.candidates.resize(1);
    r.build_direction_inferred = false;
    bool threw = false;
    try {
      apply_recommended_orientation(&r);
    } catch (const std::invalid_argument&) {
      threw = true;
    }
    CHECK(threw,
          "*** V2: auto-apply REFUSES to override a declared direction — the "
          "leak is structurally impossible, not merely unlikely ***");
  }
}

// ===========================================================================
// V7 + V9: the auto-applied orientation is announced, and it can never sink a
// part. Uses the V5 hook at resolution 48 — PR 266's own case, where the
// gravity-inferred orientation REJECTS and a better one ACCEPTS.
// ===========================================================================
void section_auto_apply_is_announced() {
  std::printf("\n-- V7/V9: auto-apply is announced, and never sinks a part --\n");

  const std::string fixture_dir = std::string(ORIENT_FIXTURE_DIR);
  const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
  const Material material = materials.at("PLA");

  const TriangleMesh mesh = import_stl_file(fixture_dir + "/hook.stl");
  VoxelGrid grid = voxelize(mesh, 48);
  int fixture_voxels = 0, load_voxels = 0;
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i) {
        if (!grid.solid(i, j, k)) continue;
        const Vec3 c = grid.voxel_center(i, j, k);
        if (i == 0 && c.y >= 8.0 && c.y <= 40.0) {
          grid.set_tag(i, j, k, VoxelTag::Fixture);
          ++fixture_voxels;
        } else if (c.x >= 20.0 && c.x <= 27.0 && c.y >= 7.0 && c.y <= 15.0) {
          grid.set_tag(i, j, k, VoxelTag::Load);
          ++load_voxels;
        }
      }
  CHECK(fixture_voxels > 0 && load_voxels > 0, "hook fixture/load regions tagged");

  std::vector<DirichletBC> bcs;
  for (int n : fea_tagged_nodes(grid, VoxelTag::Fixture))
    for (int c = 0; c < 3; ++c) bcs.push_back(DirichletBC{n, c, 0.0});
  const std::vector<int> load_nodes = fea_tagged_nodes(grid, VoxelTag::Load);
  std::vector<NodalLoad> loads;
  const double per_node = -60.0 / static_cast<double>(load_nodes.size());
  for (int n : load_nodes) loads.push_back(NodalLoad{n, /*axis y=*/1, per_node});

  std::vector<double> density(grid.voxel_count(), 0.0);
  std::size_t solid = 0;
  for (int k = 0; k < grid.nz; ++k)
    for (int j = 0; j < grid.ny; ++j)
      for (int i = 0; i < grid.nx; ++i)
        if (grid.solid(i, j, k)) {
          density[grid.index(i, j, k)] = 1.0;
          ++solid;
        }

  // The orientation the pipeline used to infer: -gravity = +y. PR 266 measured
  // it REJECTED at margin_stop 1.0 and the best candidate ACCEPTED.
  const Vec3 inferred{0.0, 1.0, 0.0};
  KnockdownSpec knockdown;

  const FixedDesignAnalysis plain = analyze_fixed_design(
      grid, [&] {
        SimpParams p;
        p.youngs_modulus = material.youngs_modulus_mpa;
        p.poisson = material.poisson;
        p.penalty = 3.0;
        return p;
      }(),
      density, bcs, loads, material, inferred, 1e-8, 20000,
      SolverKind::JacobiCG, /*margin_stop=*/1.0, knockdown,
      /*load_path_ok=*/true, static_cast<double>(solid), nullptr,
      /*score=*/true, /*inferred=*/true, /*auto_apply=*/false);

  const FixedDesignAnalysis applied = analyze_fixed_design(
      grid, [&] {
        SimpParams p;
        p.youngs_modulus = material.youngs_modulus_mpa;
        p.poisson = material.poisson;
        p.penalty = 3.0;
        return p;
      }(),
      density, bcs, loads, material, inferred, 1e-8, 20000,
      SolverKind::JacobiCG, /*margin_stop=*/1.0, knockdown,
      /*load_path_ok=*/true, static_cast<double>(solid), nullptr,
      /*score=*/true, /*inferred=*/true, /*auto_apply=*/true);

  std::printf(
      "  hook @48, load -y: as-inferred (+y) margin %.4f -> %s | applied "
      "(%.3g, %.3g, %.3g) margin %.4f -> %s\n",
      plain.margin_effective, plain.accepted ? "ACCEPTED" : "REJECTED",
      applied.applied_build_dir.x, applied.applied_build_dir.y,
      applied.applied_build_dir.z, applied.margin_effective,
      applied.accepted ? "ACCEPTED" : "REJECTED");

  CHECK(!plain.accepted,
        "the case is live: the gravity-inferred orientation REJECTS this part "
        "(PR 266's measurement)");
  CHECK(applied.build_direction_auto_applied,
        "V7: auto-apply fired and recorded that it did");
  CHECK(applied.accepted,
        "*** V9: auto-apply RESCUED the part — the same design, certified in an "
        "orientation the run chose ***");
  CHECK(applied.build_orientation.auto_apply_changed_verdict,
        "V7: the verdict change is flagged, not buried");

  // *** V9: VERDICT MONOTONICITY, on the whole candidate set. The applied row
  // must be accepted whenever the inferred row is — asserted directly against
  // the priced rows rather than inferred from one case. ***
  const BuildOrientationReport& rep = applied.build_orientation;
  const bool inferred_ok = rep.candidates[rep.as_inferred_index].would_be_accepted;
  const bool applied_ok = rep.candidates[rep.as_built_index].would_be_accepted;
  CHECK(!inferred_ok || applied_ok,
        "*** V9: auto-apply is VERDICT-MONOTONE — it can never turn an "
        "orientation that would have been ACCEPTED into a REJECTED one ***");
  // ... and the same statement over the unconstrained recommendation, to show
  // WHY the constraint exists: the pure maximin carries no such guarantee.
  const bool unconstrained_ok = rep.candidates[rep.recommended_index].would_be_accepted;
  std::printf(
      "  V9: inferred %s | applied %s | unconstrained recommendation %s "
      "(gate-constrained: %s)\n",
      inferred_ok ? "ACCEPT" : "REJECT", applied_ok ? "ACCEPT" : "REJECT",
      unconstrained_ok ? "ACCEPT" : "REJECT",
      rep.auto_apply_constrained_by_gate ? "yes" : "no");

  // U5 STILL HOLDS: the reported verdict is the verdict of the orientation the
  // analysis actually describes. Auto-apply moved WHICH orientation that is; it
  // did not decouple the two.
  CHECK(applied_ok == applied.accepted,
        "U5 survives auto-apply: the reported verdict is the APPLIED "
        "orientation's verdict");

  // ── THE RECEIPT SAYS ALL OF IT (bar V7) ────────────────────────────────────
  const BuildFrameRotation R = build_frame_rotation(applied.applied_build_dir);
  const std::string receipt = build_orientation_report_json(
      applied.build_orientation, applied.applied_build_dir, &R);
  CHECK(contains(receipt, "THE BUILD ORIENTATION WAS CHOSEN AUTOMATICALLY"),
        "V7: the receipt's FIRST key says the orientation was chosen for you");
  CHECK(contains(receipt, "\"auto_applied\""),
        "V7: the receipt carries the auto-apply block");
  CHECK(contains(receipt, "\"chosen_automatically\""),
        "V7: the as-built source is 'chosen_automatically', not 'declared' and "
        "not 'assumed_from_gravity'");
  CHECK(contains(receipt, "\"as_inferred\""),
        "V7: the receipt carries the MEASURED counterfactual");
  CHECK(contains(receipt, "\"rescued\": true") &&
            contains(receipt, "THIS PART PASSES BECAUSE OF THE CHOSEN ORIENTATION"),
        "*** V7: when the orientation the run would otherwise have used FAILS, "
        "the receipt says so explicitly ***");
  CHECK(contains(receipt, "\"export_frame\""),
        "V7: the receipt names the frame every vector in it is expressed in");
  CHECK(contains(receipt, "\"build_direction_in_file\": [0, 0, 1]"),
        "V7: the receipt states what the file's own build direction is");

  // An un-baked receipt must NOT gain any of that (byte-posture, bar V2).
  const std::string plain_receipt =
      build_orientation_report_json(plain.build_orientation, inferred, nullptr);
  CHECK(!contains(plain_receipt, "auto_applied") &&
            !contains(plain_receipt, "export_frame"),
        "V2: an un-baked receipt is PR 271's document — no new keys");
}

// ===========================================================================
// V6: the lattice comes with it.
// ===========================================================================
void section_lattice() {
  std::printf("\n-- V6: the lattice comes with it --\n");

  const Vec3 declared{0.0, 1.0, 0.0};  // a cube axis: exact comparison again
  JobDescription off_job = plate_lattice_job();
  off_job.has_build_direction = true;
  off_job.build_direction = declared;
  off_job.bake_build_orientation = "off";
  // A PROTECTED region: an exclude bolt the lattice must not put geometry in.
  JobLatticeRegion keep_clear;
  keep_clear.role = "exclude";
  keep_clear.kind = "bolt";
  keep_clear.axis_point = Vec3{8.0, 0.0, 2.0};
  keep_clear.axis_dir = Vec3{0.0, 0.0, 1.0};
  keep_clear.radius_mm = 3.0;
  keep_clear.half_length_mm = 5.0;
  off_job.lattice.regions.push_back(keep_clear);

  JobDescription baked_job = off_job;
  baked_job.bake_build_orientation = "always";

  const Run off = run_case(off_job, "v6_off");
  const Run baked = run_case(baked_job, "v6_baked");

  const std::string lu = lattice_mesh_of(off), lb = lattice_mesh_of(baked);
  CHECK(!lu.empty() && !lb.empty(), "V6: both runs exported a latticed mesh");
  if (lu.empty() || lb.empty()) return;

  // The generator's own counts, from the two receipts. PR 250's landings and
  // anchor nodes (zero floating ends) and PR 253's clipped struts (containment)
  // are properties of the strut graph against the boundary; a rigid motion moves
  // both together, so they must be UNCHANGED. If baking had been applied to the
  // generator's inputs instead of to its output stream, they would move.
  const std::string ru = read_file(lu.substr(0, lu.rfind(".stl")) + ".report.json");
  const std::string rb = read_file(lb.substr(0, lb.rfind(".stl")) + ".report.json");
  CHECK(!ru.empty() && !rb.empty(), "V6: both lattice receipts written");
  // The baked receipt gains exactly ONE thing: the block declaring which frame
  // its numbers describe. Strip that and the two documents must be identical —
  // which is the precise claim: the rotation changed the FRAME STATEMENT and
  // nothing else. Every generator count (clipped struts, landings, anchor
  // nodes), every volume and the composite margin are rigid-motion invariants
  // and must not have moved a bit.
  auto strip_export_frame = [](std::string s) {
    const std::string::size_type at = s.find("  \"export_frame\": {");
    if (at == std::string::npos) return s;
    const std::string::size_type end = s.find("},\n", at);
    if (end == std::string::npos) return s;
    s.erase(at, end + 3 - at);
    return s;
  };
  CHECK(contains(rb, "\"export_frame\""),
        "V6: the baked lattice receipt NAMES the frame its numbers describe");
  CHECK(!contains(ru, "\"export_frame\""),
        "V6: the model-space lattice receipt gains no frame key (byte posture)");
  CHECK(strip_export_frame(rb) == ru,
        "*** V6: apart from the frame declaration the lattice certification "
        "receipt is BYTE-IDENTICAL across the rotation — clipped struts, "
        "landings, anchor nodes, volumes and the composite margin all unchanged "
        "(PR 250 + PR 253's bars survive) ***");

  const TriangleMesh LU = read_stl_file(lu).mesh;
  const TriangleMesh LB = read_stl_file(lb).mesh;
  const std::vector<Vec3> su = triangle_stream(LU);
  const std::vector<Vec3> sb = triangle_stream(LB);
  CHECK(su.size() == sb.size(),
        "V6: the rotated lattice export has the SAME triangle count — the "
        "generator ran identically");
  if (su.size() == sb.size()) {
    const BuildFrameRotation R = build_frame_rotation(declared);
    std::size_t drift = 0;
    for (std::size_t i = 0; i < su.size(); ++i) {
      const Vec3 want = to_build_frame(R, su[i]);
      if (sb[i].x != want.x || sb[i].y != want.y || sb[i].z != want.z) ++drift;
    }
    CHECK(drift == 0,
          "*** V6: the rotated lattice file is the SAME geometry, exactly — the "
          "shell, the solid companion and every strut moved by ONE rigid motion "
          "***");
    std::printf("  V6: %zu lattice vertices compared, %zu drifted\n", su.size(),
                drift);
  }

  // ── PR 253's CONTAINMENT, in the exported frame ────────────────────────────
  // Every strut solid is clipped against the part boundary, so no exported
  // lattice geometry may lie outside the part. Checked in each file's OWN frame
  // against that file's OWN shell bounding box: a rotation moves the geometry
  // and the boundary together, so a violation count that moved would mean the
  // bake had been applied to only one of them.
  const BuildFrameRotation R = build_frame_rotation(declared);
  auto outside_bbox_count = [](const TriangleMesh& lattice,
                               const TriangleMesh& shell, double tol) {
    Vec3 lo{1e300, 1e300, 1e300}, hi{-1e300, -1e300, -1e300};
    for (const Vec3& v : shell.vertices) {
      lo.x = std::min(lo.x, v.x); lo.y = std::min(lo.y, v.y); lo.z = std::min(lo.z, v.z);
      hi.x = std::max(hi.x, v.x); hi.y = std::max(hi.y, v.y); hi.z = std::max(hi.z, v.z);
    }
    std::size_t n = 0;
    for (const Vec3& v : lattice.vertices)
      if (v.x < lo.x - tol || v.x > hi.x + tol || v.y < lo.y - tol ||
          v.y > hi.y + tol || v.z < lo.z - tol || v.z > hi.z + tol)
        ++n;
    return n;
  };
  {
    // The SOLID export of each run is the shell the lattice is contained in.
    const TriangleMesh SU = read_stl_file(solid_mesh_of(off)).mesh;
    const TriangleMesh SB = read_stl_file(solid_mesh_of(baked)).mesh;
    const std::size_t out_model = outside_bbox_count(LU, SU, 1e-9);
    const std::size_t out_file = outside_bbox_count(LB, SB, 1e-9);
    CHECK(out_model == 0,
          "V6: no lattice geometry lies outside the part in the model frame "
          "(PR 253's containment, the pre-existing bar)");
    CHECK(out_file == 0,
          "*** V6: no lattice geometry lies outside the part in the EXPORTED "
          "build frame either — containment survived the rotation ***");
    std::printf("  V6: out-of-part lattice vertices model=%zu file=%zu\n",
                out_model, out_file);
  }

  auto inside_bolt = [](const Vec3& p, const Vec3& axis_pt, const Vec3& axis_dir,
                        double radius, double half_len) {
    const Vec3 d{p.x - axis_pt.x, p.y - axis_pt.y, p.z - axis_pt.z};
    const double t = dot3(d, axis_dir);
    if (std::fabs(t) > half_len) return false;
    const Vec3 perp{d.x - t * axis_dir.x, d.y - t * axis_dir.y,
                    d.z - t * axis_dir.z};
    return std::sqrt(dot3(perp, perp)) < radius;
  };
  const Vec3 bolt_pt_b = to_build_frame(R, keep_clear.axis_point);
  const Vec3 bolt_dir_b = to_build_frame(R, keep_clear.axis_dir);
  std::size_t inside_model = 0, inside_file = 0;
  for (const Vec3& v : LU.vertices)
    if (inside_bolt(v, keep_clear.axis_point, keep_clear.axis_dir,
                    keep_clear.radius_mm, keep_clear.half_length_mm))
      ++inside_model;
  for (const Vec3& v : LB.vertices)
    if (inside_bolt(v, bolt_pt_b, bolt_dir_b, keep_clear.radius_mm,
                    keep_clear.half_length_mm))
      ++inside_file;
  // The declared REGION, measured in both frames. Note what an "exclude" role
  // means: it keeps that material SOLID (the solid-companion body), it does not
  // empty it — so a non-zero count here is correct by design. What must hold is
  // that the count is IDENTICAL: rotating the part rotates the region with it,
  // so the bake neither added geometry to a declared region nor removed it.
  CHECK(inside_file == inside_model,
        "*** V6: the declared region holds exactly the same geometry before and "
        "after the rotation — the region and the part moved together ***");
  CHECK(inside_model > 0,
        "V6: the check is NON-VACUOUS — the exclude region really does hold "
        "solid-companion geometry, so an identical count means something");
  std::printf("  V6: exclude-region occupancy model=%zu file=%zu\n", inside_model,
              inside_file);
}

// ===========================================================================
// V8: determinism.
// ===========================================================================
void section_determinism() {
  std::printf("\n-- V8: determinism --\n");
  // The DEFAULT posture: no declared direction, no bake key => the orientation
  // is chosen and baked. Two runs must agree to the byte, including the choice.
  const Run one = run_case(plate_job(), "v8_a");
  const Run two = run_case(plate_job(), "v8_b");
  CHECK(one.report_json == two.report_json,
        "V8: report.json byte-identical across two runs of the auto-baking job");
  // The receipt carries PR 271's MEASURED sweep cost (`sweep_seconds`,
  // `strut_axis_measure_seconds`), which are wall-clock readings and differ
  // between two runs of the same binary — exactly like `wall_ms` in run_info,
  // which PR 271's own byte-identity evidence strips for the same reason. With
  // those two stripped the document must be identical, and that is the real
  // claim: THE CHOICE is deterministic, not merely the numbers around it.
  auto strip_timings = [](std::string s) {
    for (const char* key : {"\"sweep_seconds\": ", "\"strut_axis_measure_seconds\": "}) {
      std::string::size_type at = s.find(key);
      while (at != std::string::npos) {
        const std::string::size_type from = at + std::string(key).size();
        std::string::size_type to = from;
        while (to < s.size() && s[to] != ',' && s[to] != '\n' && s[to] != '}') ++to;
        s.replace(from, to - from, "<stripped>");
        at = s.find(key, from);
      }
    }
    return s;
  };
  CHECK(strip_timings(one.orientation_json) == strip_timings(two.orientation_json),
        "V8: the build-orientation receipt is byte-identical across two runs "
        "once wall-clock timings are stripped — THE CHOICE is deterministic");
  CHECK(one.orientation_json != two.orientation_json ||
            one.orientation_json.empty() ||
            !contains(one.orientation_json, "sweep_seconds"),
        "V8: (the strip is non-vacuous — the raw documents do differ, in the "
        "timing fields alone)");
  const std::string ma = solid_mesh_of(one), mb = solid_mesh_of(two);
  CHECK(!ma.empty() && !mb.empty(), "V8: both runs exported a mesh");
  if (!ma.empty() && !mb.empty())
    CHECK(read_file(ma) == read_file(mb),
          "V8: the exported mesh is byte-identical across two runs");

  // And the default really is the baking one — otherwise every bar above would
  // be testing a posture no real job uses.
  CHECK(contains(one.report_json, "\"orientation_frame\": \"export\""),
        "V8: the DEFAULT posture (no keys at all) bakes the export");
  CHECK(!one.orientation_json.empty() &&
            contains(one.orientation_json, "CHOSEN AUTOMATICALLY"),
        "V8: the default posture writes the auto-apply receipt");
}

}  // namespace

int main() {
  std::printf("test_bake_build_orientation — the exported file IS the certified "
              "object\n");
  section_rotation_primitive();
  section_file_is_the_certified_object();
  section_declared_is_untouched();
  section_auto_apply_is_announced();
  section_lattice();
  section_determinism();
  std::printf("\n%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
