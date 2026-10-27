// ORIENTED KEEP REGIONS (ruling 2026-10-26 23:48): keep_regions in the clearances'
// vocabulary, so a TILTED hole and a SLANTED flat face export exactly too:
//   {"shape": "cylinder", "axis_point", "axis_dir", "radius_mm", "half_length_mm"}
//   {"shape": "box", "center", "axes": [3 orthonormal vectors], "half_extents_mm"}
//
// Through run_job on a block (44 x 24 x 14 mm, built here with Manifold) with a bore
// of radius 3 tilted 30 degrees from Z and a flat face slanted 30 degrees, held at two
// upright bores (r 2.5) with 50 N down on the far end (a load case, the app's path,
// where keep regions are frozen), ~1.1 mm voxels:
//   (a) the tilted bore's fitted diameter in the file is within 0.05 mm of the CAD's
//       (the voxel export, without the regions, is printed beside it);
//   (b) a slab on the slanted face (2 mm into the part, 1.5 mm out into the air) leaves
//       the face flat and on the CAD plane within 0.02 mm;
//   (c) the bore is never frozen solid: every voxel inside the bore is empty, while
//       the part's voxels inside both tilted regions are kept printed;
//   (d) one closed shell; the schema refuses bad oriented regions and still parses
//       the min/max form.
// Rays measure the file: from the bore's axis outwards, and down onto the face.

#include "topopt/job.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/part.hpp"
#include "topopt/settings.hpp"
#include "topopt/step.hpp"
#include "topopt/stl.hpp"

#include <manifold/manifold.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <limits>
#include <map>
#include <string>
#include <utility>
#include <vector>

using namespace topopt;

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

namespace {

const double kS30 = 0.5, kC30 = std::sqrt(3.0) / 2.0;
// The tilted bore: through (-8, 0, 7) along d, radius 3; (bu, bv) span its cross-section.
const Vec3 kBoreAt{-8.0, 0.0, 7.0};
const Vec3 kBoreDir{-kS30, 0.0, kC30};
const Vec3 kBoreU{kC30, 0.0, kS30};
const Vec3 kBoreV{0.0, 1.0, 0.0};
constexpr double kBoreR = 3.0;
// The slanted face: through (5, *, 14), outward normal n, down-slope fu, across fv.
const Vec3 kFaceN{kS30, 0.0, kC30};
const Vec3 kFaceU{kC30, 0.0, -kS30};
const Vec3 kFaceV{0.0, 1.0, 0.0};
const Vec3 kFaceMid{12.5, 0.0, 14.0 - 7.5 * kS30 / kC30};
constexpr double kReach = 1.5;  // mm out past the face: one 1.1 mm voxel and some

Vec3 add(const Vec3& a, const Vec3& b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
Vec3 sub(const Vec3& a, const Vec3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
Vec3 mul(const Vec3& a, double s) { return {a.x * s, a.y * s, a.z * s}; }
double dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
Vec3 cross(const Vec3& a, const Vec3& b) {
  return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}

manifold::Manifold framed(const manifold::Manifold& m, const Vec3& u, const Vec3& v,
                          const Vec3& w, const Vec3& at) {
  auto c = [](const Vec3& p) { return manifold::vec3{p.x, p.y, p.z}; };
  return m.Transform(manifold::mat3x4(c(u), c(v), c(w), c(at)));
}

TriangleMesh build_part() {
  using manifold::Manifold;
  Manifold block = Manifold::Cube({44.0, 24.0, 14.0}).Translate({-24.0, -12.0, 0.0});
  const Manifold above =  // the half-space over the slanted face
      framed(Manifold::Cube({200.0, 200.0, 200.0}, true).Translate({0.0, 0.0, 100.0}), kFaceU,
             kFaceV, kFaceN, Vec3{5.0, 0.0, 14.0});
  block = block - above;
  block = block - framed(Manifold::Cylinder(60.0, kBoreR, -1.0, 128, true), kBoreU, kBoreV,
                         kBoreDir, kBoreAt);
  for (double y : {-7.0, 7.0})
    block = block - Manifold::Cylinder(60.0, 2.5, -1.0, 96, true).Translate({-19.0, y, 7.0});
  const manifold::MeshGL g = block.GetMeshGL();
  TriangleMesh out;
  for (std::size_t v = 0; v < g.NumVert(); ++v)
    out.vertices.push_back({g.vertProperties[v * g.numProp], g.vertProperties[v * g.numProp + 1],
                            g.vertProperties[v * g.numProp + 2]});
  for (std::size_t t = 0; t < g.NumTri(); ++t)
    out.triangles.push_back({static_cast<int>(g.triVerts[3 * t]),
                             static_cast<int>(g.triVerts[3 * t + 1]),
                             static_cast<int>(g.triVerts[3 * t + 2])});
  return out;
}

// The nearest hit of the ray o + s*d (s > 0) on the mesh, +inf when none.
double ray_hit(const TriangleMesh& m, const Vec3& o, const Vec3& d) {
  double best = std::numeric_limits<double>::infinity();
  for (const auto& t : m.triangles) {
    const Vec3& a = m.vertices[static_cast<std::size_t>(t[0])];
    const Vec3 e1 = sub(m.vertices[static_cast<std::size_t>(t[1])], a);
    const Vec3 e2 = sub(m.vertices[static_cast<std::size_t>(t[2])], a);
    const Vec3 p = cross(d, e2);
    const double det = dot(e1, p);
    if (std::fabs(det) < 1e-14) continue;
    const Vec3 s = sub(o, a);
    const double u = dot(s, p) / det;
    if (u < -1e-9 || u > 1.0 + 1e-9) continue;
    const Vec3 q = cross(s, e1);
    const double v = dot(d, q) / det;
    if (v < -1e-9 || u + v > 1.0 + 1e-9) continue;
    const double h = dot(e2, q) / det;
    if (h > 1e-9 && h < best) best = h;
  }
  return best;
}

// The bore as the file has it: at 5 sections along the axis, 36 rays out from the
// axis; a least-squares circle per section. Mean fitted diameter, and the widest
// out-of-round (max - min distance from the fitted centre).
struct BoreFit {
  double diameter = 0.0;
  double out_of_round = 0.0;
};
BoreFit fit_bore(const TriangleMesh& m) {
  BoreFit f;
  int sections = 0;
  for (double t : {-5.0, -2.5, 0.0, 2.5, 5.0}) {
    const Vec3 o = add(kBoreAt, mul(kBoreDir, t));
    std::vector<std::pair<double, double>> pts;
    for (int a = 0; a < 36; ++a) {
      const double th = (a + 0.5) * 2.0 * M_PI / 36.0;
      const Vec3 d = add(mul(kBoreU, std::cos(th)), mul(kBoreV, std::sin(th)));
      const double r = ray_hit(m, o, d);
      if (std::isfinite(r)) pts.push_back({r * std::cos(th), r * std::sin(th)});
    }
    if (pts.size() < 3) continue;
    // Kasa fit: x^2 + y^2 + D x + E y + F = 0.
    double A[3][3] = {}, b[3] = {};
    for (const auto& p : pts) {
      const double row[3] = {p.first, p.second, 1.0}, rhs = -(p.first * p.first + p.second * p.second);
      for (int i = 0; i < 3; ++i) {
        for (int j = 0; j < 3; ++j) A[i][j] += row[i] * row[j];
        b[i] += row[i] * rhs;
      }
    }
    for (int c = 0; c < 3; ++c)  // Gauss-Jordan, the 3x3 normal equations
      for (int r = 0; r < 3; ++r) {
        if (r == c) continue;
        const double k = A[r][c] / A[c][c];
        for (int j = 0; j < 3; ++j) A[r][j] -= k * A[c][j];
        b[r] -= k * b[c];
      }
    const double D = b[0] / A[0][0], E = b[1] / A[1][1], F = b[2] / A[2][2];
    const double cx = -0.5 * D, cy = -0.5 * E, rad = std::sqrt(cx * cx + cy * cy - F);
    double lo = 1e9, hi = -1e9;
    for (const auto& p : pts) {
      const double r = std::hypot(p.first - cx, p.second - cy);
      lo = std::min(lo, r);
      hi = std::max(hi, r);
    }
    f.diameter += 2.0 * rad;
    f.out_of_round = std::max(f.out_of_round, hi - lo);
    ++sections;
  }
  if (sections > 0) f.diameter /= sections;
  return f;
}

// The slanted face as the file has it: rays straight down onto it over a grid inside
// the slab's footprint (0.5 mm in from its edges). Worst distance from the CAD plane,
// and the spread (max - min).
struct FaceFit {
  double worst = 0.0;
  double spread = 0.0;
  int misses = 0;
};
FaceFit fit_face(const TriangleMesh& m) {
  FaceFit f;
  double lo = 1e9, hi = -1e9;
  for (double s = -6.5; s <= 6.5 + 1e-9; s += 0.5)
    for (double y = -9.5; y <= 9.5 + 1e-9; y += 0.5) {
      const Vec3 o = add(add(add(kFaceMid, mul(kFaceU, s)), mul(kFaceV, y)), mul(kFaceN, 3.0));
      const double hit = ray_hit(m, o, mul(kFaceN, -1.0));
      if (!std::isfinite(hit)) {
        ++f.misses;
        continue;
      }
      const double h = 3.0 - hit;  // signed height over the CAD plane
      lo = std::min(lo, h);
      hi = std::max(hi, h);
      f.worst = std::max(f.worst, std::fabs(h));
    }
  f.spread = hi - lo;
  return f;
}

std::string keep_json() {
  char buf[1024];
  // The slab: 2 mm into the part and kReach out past the face, into the air (a flush
  // slab keeps the voxel bumps just above the face: 0.29 mm measured here).
  const Vec3 c = sub(kFaceMid, mul(kFaceN, 1.0 - 0.5 * kReach));
  std::snprintf(buf, sizeof buf,
                "{\"shape\": \"cylinder\", \"axis_point\": [%.9f, %.9f, %.9f], "
                "\"axis_dir\": [%.9f, %.9f, %.9f], \"radius_mm\": 5, \"half_length_mm\": 9}, "
                "{\"shape\": \"box\", \"center\": [%.9f, %.9f, %.9f], \"axes\": [[%.9f, %.9f, "
                "%.9f], [%.9f, %.9f, %.9f], [%.9f, %.9f, %.9f]], \"half_extents_mm\": [7, 10, %.6f]}",
                kBoreAt.x, kBoreAt.y, kBoreAt.z, kBoreDir.x, kBoreDir.y, kBoreDir.z, c.x, c.y, c.z,
                kFaceU.x, kFaceU.y, kFaceU.z, kFaceV.x, kFaceV.y, kFaceV.z, kFaceN.x, kFaceN.y,
                kFaceN.z, 1.0 + 0.5 * kReach);
  return buf;
}

std::string job_text(const std::string& keeps) {
  return "{\"model\": \"keep_tilt.stl\", \"material\": \"PLA\", "
         "\"mode\": \"minimize_plastic\", \"resolution\": 40, "
         "\"fixture_faces\": [{\"kind\": \"cylindrical\", \"radius_mm\": 2.5}], "
         "\"gravity\": {\"direction\": [0, 0, -1], \"magnitude_mm_s2\": 9810}, "
         "\"ladder\": [0.5], \"margin_stop\": 1.5, \"keep_regions\": [" +
         keeps +
         "], \"output\": {\"report\": \"r.json\", \"mesh_format\": \"stl\", "
         "\"mesh_prefix\": \"v\"}}";
}

JobDescription parsed(const std::string& keeps) {
  const std::string path = std::string(TMP_DIR) + "/keep_oriented_job.json";
  std::ofstream(path) << job_text(keeps);
  return load_job_file(path);
}

bool refused(const std::string& keeps) {
  try {
    (void)parsed(keeps);
    return false;
  } catch (const std::exception&) {
    return true;
  }
}

// The app's path: a load case (keep regions are frozen there), anchored at the two
// upright bores, 50 N down on the far end face.
JobDescription tilt_job(const StepModel& m, const std::vector<KeepRegion>& keeps) {
  JobDescription job;
  job.model = "keep_tilt.stl";
  job.material = "PLA";
  job.mode = "minimize_plastic";
  job.resolution = 40;
  job.has_plsm = true;
  job.plsm_enabled = true;
  job.plsm_max_iterations = 6;
  job.loads.present = true;
  job.loads.build_dir = Vec3{0.0, 0.0, 1.0};
  for (int f = 0; f < m.face_count; ++f) {
    const StepFaceInfo& fi = m.faces[static_cast<std::size_t>(f)];
    if (fi.kind == StepSurfaceKind::Cylinder && std::fabs(fi.cylinder_radius_mm - 2.5) < 0.1)
      job.loads.anchor_face_ids.push_back(f);
    if (fi.kind == StepSurfaceKind::Plane && fi.plane_normal.x > 0.99 &&
        job.loads.groups.empty()) {
      JobLoadGroup g;
      g.face_ids = {f};
      g.force = Vec3{0.0, 0.0, -50.0};
      job.loads.groups.push_back(g);
    }
  }
  job.ladder = {0.5};
  job.margin_stop = 1.5;
  job.bake_build_orientation = "off";  // the file in model coordinates
  job.output.report = "report.json";
  job.output.mesh_format = "stl";
  job.output.mesh_prefix = "variant";
  job.keep_regions = keeps;
  return job;
}

}  // namespace

int main() {
  const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  const std::string dir = TMP_DIR;
  const TriangleMesh cad = build_part();
  write_stl_file(dir + "/keep_tilt.stl", cad);
  const StepModel model = import_part_file(dir + "/keep_tilt.stl");
  const BoreFit bore_cad = fit_bore(cad);
  const FaceFit face_cad = fit_face(cad);
  std::printf("[keep-oriented] CAD: bore diameter %.4f (out of round %.4f), face worst %.4f "
              "spread %.4f\n", bore_cad.diameter, bore_cad.out_of_round, face_cad.worst,
              face_cad.spread);
  try {
    const JobDescription with_job = parsed(keep_json());
    CHECK(with_job.keep_regions.size() == 2 && with_job.keep_regions[0].oriented &&
              with_job.keep_regions[1].oriented,
          "precondition: both oriented regions parse");
    const JobDescription probe = tilt_job(model, {});
    CHECK(probe.loads.anchor_face_ids.size() == 2 && probe.loads.groups.size() == 1,
          "precondition: two upright bores held, the end face loaded");
    const RunJobResult with = run_job(tilt_job(model, with_job.keep_regions), dir,
                                      dir + "/keep_oriented_on", materials, rules, false,
                                      RunObservability{});
    const RunJobResult without = run_job(tilt_job(model, {}), dir, dir + "/keep_oriented_off",
                                         materials, rules, false, RunObservability{});
    // The lightest accepted design of each run: the most material removed.
    CHECK(!with.mesh_paths.empty() && !without.mesh_paths.empty(),
          "precondition: an accepted variant each");
    if (!with.mesh_paths.empty() && !without.mesh_paths.empty()) {
      const TriangleMesh fk = read_stl_file(with.mesh_paths.back()).mesh;
      const TriangleMesh fn = read_stl_file(without.mesh_paths.back()).mesh;
      const BoreFit bk = fit_bore(fk), bn = fit_bore(fn);
      const FaceFit ak = fit_face(fk), an = fit_face(fn);
      std::printf("[keep-oriented] bore diameter: CAD %.4f, with the regions %.4f (out of "
                  "round %.4f), voxel export %.4f (out of round %.4f)\n",
                  bore_cad.diameter, bk.diameter, bk.out_of_round, bn.diameter,
                  bn.out_of_round);
      std::printf("[keep-oriented] slanted face off the CAD plane: with the regions worst "
                  "%.4f spread %.4f (%d misses), voxel export worst %.4f spread %.4f (%d "
                  "misses)\n", ak.worst, ak.spread, ak.misses, an.worst, an.spread, an.misses);
      CHECK(std::fabs(bk.diameter - bore_cad.diameter) <= 0.05,
            "(a) the tilted bore's fitted diameter is within 0.05 mm of the CAD");
      CHECK(ak.misses == 0 && ak.worst <= 0.02,
            "(b) the slanted face is flat and on the CAD plane within 0.02 mm");

      // (c) on the solve grid
      const VoxelGrid& g = with.pipeline.solved_grid;
      const std::vector<double>* rho = nullptr;
      for (const MinimizePlasticVariant& v : with.pipeline.evaluated)
        if (v.accepted) rho = &v.optimization.physical_density;  // the last = the lightest
      CHECK(rho != nullptr && rho->size() == static_cast<std::size_t>(g.nx) * g.ny * g.nz,
            "precondition: the lightest accepted rung's density on the solve grid");
      if (rho != nullptr && rho->size() == static_cast<std::size_t>(g.nx) * g.ny * g.nz) {
        const double inside = kBoreR - 0.5 * std::sqrt(3.0) * g.spacing;
        long long bore = 0, bore_filled = 0, kept = 0, kept_lost = 0;
        for (int k = 0; k < g.nz; ++k)
          for (int j = 0; j < g.ny; ++j)
            for (int i = 0; i < g.nx; ++i) {
              const Vec3 p = g.voxel_center(i, j, k);
              const std::size_t idx = g.index(i, j, k);
              const Vec3 d = sub(p, kBoreAt);
              const double q = dot(d, kBoreDir);
              const double r = std::sqrt(std::max(0.0, dot(d, d) - q * q));
              if (std::fabs(q) <= 6.0 && r <= inside) {
                ++bore;
                bore_filled += g.solid(i, j, k) || (*rho)[idx] >= 0.5;
              }
              if (!g.solid(i, j, k)) continue;
              for (const KeepRegion& kr : with_job.keep_regions)
                if (kr.contains(p)) {
                  ++kept;
                  kept_lost += (*rho)[idx] < 0.5;
                  break;
                }
            }
        std::printf("[keep-oriented] solve grid h %.3f: %lld voxels inside the bore, %lld "
                    "solid or printed; %lld part voxels in the regions, %lld not printed\n",
                    g.spacing, bore, bore_filled, kept, kept_lost);
        CHECK(bore > 0 && bore_filled == 0, "(c) the bore is never frozen solid");
        CHECK(kept > 0 && kept_lost == 0, "(c) the part inside the tilted regions is kept");
      }

      std::map<std::pair<int, int>, int> uses;
      for (const auto& t : fk.triangles)
        for (int e = 0; e < 3; ++e) {
          const int a = t[e], b = t[(e + 1) % 3];
          ++uses[{std::min(a, b), std::max(a, b)}];
        }
      int bad = 0;
      for (const auto& kv : uses) bad += kv.second != 2;
      std::printf("[keep-oriented] file: %zu triangles, %d bodies (voxel export %d), %d edges "
                  "not on exactly two triangles\n", fk.triangles.size(), count_components(fk),
                  count_components(fn), bad);
      CHECK(count_components(fk) == 1 && bad == 0, "(d) one merged, closed 2-manifold shell");
    }
  } catch (const std::exception& e) {
    ++g_failures;
    std::fprintf(stderr, "FAIL: threw: %s\n", e.what());
  }
  CHECK(refused("{\"shape\": \"cylinder\", \"axis_point\": [0, 0, 0], \"axis_dir\": [0, 0, 0], "
                "\"radius_mm\": 5, \"half_length_mm\": 9}"),
        "(d) a zero axis_dir is refused");
  CHECK(refused("{\"shape\": \"box\", \"center\": [0, 0, 0], \"axes\": [[1, 0, 0], [0.1, 1, 0], "
                "[0, 0, 1]], \"half_extents_mm\": [1, 1, 1]}"),
        "(d) axes not at right angles are refused");
  CHECK(refused("{\"shape\": \"box\", \"center\": [0, 0, 0], \"min\": [0, 0, 0], \"axes\": [[1, "
                "0, 0], [0, 1, 0], [0, 0, 1]], \"half_extents_mm\": [1, 1, 1]}"),
        "(d) mixing the two forms is refused");
  CHECK(refused("{\"shape\": \"cylinder\", \"axis_point\": [0, 0, 0], \"axis_dir\": [0, 0, 1], "
                "\"radius_mm\": 0, \"half_length_mm\": 9}"),
        "(d) a zero radius is refused");
  CHECK(!refused("{\"shape\": \"cylinder\", \"min\": [-7, -7, 0], \"max\": [7, 7, 4], \"axis\": 2}"),
        "(d) the min/max form still parses");

  if (g_failures == 0) {
    std::printf("keep oriented: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "keep oriented: %d/%d checks FAILED\n", g_failures, g_checks);
  return 1;
}
