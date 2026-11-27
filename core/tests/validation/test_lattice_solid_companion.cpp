// The SOLID beside a latticed part (reviewer's ruling 11-09, the rim coupon's SOLID).
//
// He opened the rim coupon (prints/2026-11-08-rim-coupon, made by a38af0c6) and its
// _SOLID.stl carried a ROD one voxel square along the arch's apex, a COMB of one-voxel
// fins on the curved top, and raw voxel steps for outer faces. The thin-member test read
// the voxel staircase of the curved surface as thin members; the companion was the
// marching cubes of the solid voxels.
//
// The bar, on core's own coupon (lattice_coupon_solid) at the print's settings
// (resolution 64, octet, 4 mm cell, 0.45 mm bead, lattice_part, welded + SOLID written):
// §1 the run writes its receipt and the SOLID.
// §2 no SOLID piece is thinner than 2 line widths (0.9 mm): every voxel the SOLID holds
//    on the run's own grid lies in a k x k x k block of SOLID voxels, k = ceil(0.9 / h).
// §3 every SOLID face that faces air lies on the part's own surface, within 0.1 mm.
//    (A face that faces the part's inside is the solid/lattice interface.)
// §4 the tongue (12 mm wide, under the 20 mm an octet member needs at a 4 mm cell) stays
//    solid, and the body (33 mm) is latticed.
// §5 the SOLID is closed.
// §6 no edge wedges (ruling 11-09 20:10Z, the convex-corner rule): away from the tongue's
//    junction (x < 27) the SOLID holds no voxel at all, so no convex edge of the body is
//    left solid; the junction itself (x 27-33) is named, and kept under 2,500 voxels.
// §7 preview = core: lattice_solid_fallback_reasons on the part's own grid gives the run's
//    split, voxel count for voxel count (every reason 1-4 is a solid-fallback voxel).
#include "topopt/grading.hpp"
#include "topopt/job.hpp"
#include "topopt/lattice_sample.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh_distance.hpp"
#include "topopt/part.hpp"
#include "topopt/settings.hpp"
#include "topopt/stl.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <limits>
#include <sstream>
#include <string>
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

int face_with_normal(const StepModel& m, double nx, double ny, double nz) {
  std::vector<double> area(static_cast<std::size_t>(m.face_count), 0.0);
  for (std::size_t t = 0; t < m.mesh.triangles.size() && t < m.triangle_face.size(); ++t) {
    const int f = m.triangle_face[t];
    if (f < 0 || f >= m.face_count) continue;
    const Vec3& a = m.mesh.vertices[static_cast<std::size_t>(m.mesh.triangles[t][0])];
    const Vec3& b = m.mesh.vertices[static_cast<std::size_t>(m.mesh.triangles[t][1])];
    const Vec3& c = m.mesh.vertices[static_cast<std::size_t>(m.mesh.triangles[t][2])];
    const Vec3 u{b.x - a.x, b.y - a.y, b.z - a.z}, v{c.x - a.x, c.y - a.y, c.z - a.z};
    const Vec3 n{u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x};
    area[static_cast<std::size_t>(f)] += 0.5 * std::sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
  }
  int best = -1;
  for (int f = 0; f < m.face_count; ++f) {
    const StepFaceInfo& fi = m.faces[static_cast<std::size_t>(f)];
    if (fi.kind != StepSurfaceKind::Plane) continue;
    if (fi.plane_normal.x * nx + fi.plane_normal.y * ny + fi.plane_normal.z * nz <= 0.99)
      continue;
    if (best < 0 || area[static_cast<std::size_t>(f)] > area[static_cast<std::size_t>(best)])
      best = f;
  }
  return best;
}

std::string read_file(const std::string& p) {
  std::ifstream in(p, std::ios::binary);
  std::stringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

double num_after(const std::string& s, const std::string& key) {
  const std::size_t k = s.find("\"" + key + "\": ");
  if (k == std::string::npos) return std::numeric_limits<double>::quiet_NaN();
  const std::size_t v = k + key.size() + 4;
  if (s.compare(v, 4, "null") == 0) return std::numeric_limits<double>::quiet_NaN();
  return std::strtod(s.c_str() + v, nullptr);
}

// The print's job (prints/2026-11-08-rim-coupon/rim_coupon_open.json) with the skin off:
// the skin dresses the lattice and never touches the solid beside it.
std::string job_json(const std::string& model, int anchor, int load) {
  return "{\"model\": \"" + model + "\", \"material\": \"PLA\", \"mode\": \"lattice_part\", "
         "\"resolution\": 64, "
         "\"loads\": {\"minimize_plastic\": true, \"build_dir\": [0, 0, 1], "
         "\"anchor_face_ids\": [" + std::to_string(anchor) + "], \"groups\": [{\"face_ids\": [" +
         std::to_string(load) + "], \"force\": [0, 0, -20]}]}, "
         "\"lattice\": {\"topology\": \"octet\", \"require_lattice_void_reaches_exterior\": "
         "false, \"skin\": \"none\", \"outer_finish\": \"none\", \"emit_welded_stl\": true}, "
         "\"grading\": {\"topology\": \"octet\", \"cell_mm\": 4.0, "
         "\"min_extrudable_width_mm\": 0.45, \"intent\": \"structural\"}, "
         "\"output\": {\"report\": \"report.json\", \"mesh_format\": \"stl\", "
         "\"mesh_prefix\": \"coupon\"}}";
}

Vec3 sub(const Vec3& a, const Vec3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
Vec3 cross(const Vec3& a, const Vec3& b) {
  return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}

}  // namespace

int main() {
  const std::string dir = TMP_DIR;
  const double bead = 0.45, two_lines = 2.0 * bead;

  // ── the coupon as a part ───────────────────────────────────────────────────
  write_stl_file(dir + "/solid_companion_coupon.stl", lattice_coupon_solid(), StlFormat::Binary);
  const StepModel part = import_part(dir + "/solid_companion_coupon.stl").model;
  const int bottom = face_with_normal(part, 0, 0, -1);
  const int end = face_with_normal(part, 1, 0, 0);
  CHECK(bottom >= 0 && end >= 0, "precondition: the coupon's bottom and an x+ end face");

  const std::string out = dir + "/solid_companion_run";
  std::filesystem::remove_all(out);
  std::ofstream(dir + "/solid_companion.json")
      << job_json("solid_companion_coupon.stl", bottom, end);
  std::string receipt, refused;
  try {
    const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
    const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
    const JobDescription job = load_job_file(dir + "/solid_companion.json");
    (void)lattice_variant_job(job, dir, out, materials, rules);
  } catch (const std::exception& e) {
    refused = e.what();
    std::printf("  (refused: %s)\n", e.what());
  }
  std::string solid_path;
  if (std::filesystem::exists(out))
    for (const auto& e : std::filesystem::directory_iterator(out)) {
      const std::string n = e.path().filename().string();
      if (n.size() > 20 && n.compare(n.size() - 20, 20, "_lattice.report.json") == 0)
        receipt = read_file(e.path().string());
      if (n.size() > 10 && n.compare(n.size() - 10, 10, "_SOLID.stl") == 0)
        solid_path = e.path().string();
    }
  // §1
  CHECK(refused.empty() && !receipt.empty(), "§1 the run writes its receipt");
  CHECK(!solid_path.empty(), "§1 the run writes the SOLID beside the welded lattice");
  if (solid_path.empty()) {
    std::fprintf(stderr, "%d checks, %d failures\n", g_checks, g_failures);
    return 1;
  }
  std::printf("[solid] receipt: solid fallback %.0f voxels (member too thin %.0f, widest "
              "rejected %.2f mm), latticed %.0f\n",
              num_after(receipt, "solid_fallback_voxels"),
              num_after(receipt, "member_too_thin_for_cell"),
              num_after(receipt, "widest_rejected_member_mm"),
              num_after(receipt, "latticed_voxels"));

  const TriangleMesh solid = read_stl_file(solid_path).mesh;
  const WatertightReport wt = check_watertight(solid);
  // §5
  CHECK(wt.watertight, "§5 the SOLID is closed");

  // The run's own grid: the part voxelized at the job's resolution, as lattice_part does.
  const VoxelGrid grid = voxelize(part.mesh, 64);
  // The SOLID on the run's grid: a voxel is SOLID when its centre lies inside the file, read
  // by the EXACT signed distance (MeshDistance), not by voxelize_onto_grid. The file's
  // lattice-facing faces are the marching cubes of this very grid, so their vertices sit
  // on the grid's own columns, and a +Z ray cast through a column grazes them: the ray
  // rule then filled whole columns the file does not hold (it read the 14,978-voxel
  // SOLID as 24,041 voxels). The signed distance has no ray to graze.
  VoxelGrid sg = grid;
  {
    const MeshDistance in_solid(solid);
    for (int c = 0; c < sg.nz; ++c)
      for (int b = 0; b < sg.ny; ++b)
        for (int a = 0; a < sg.nx; ++a)
          sg.set_tag(a, b, c, in_solid.signed_distance(grid.voxel_center(a, b, c)) > 0.0
                                  ? VoxelTag::Interior
                                  : VoxelTag::Empty);
  }
  const double h = grid.spacing;
  const int k = std::max(1, static_cast<int>(std::ceil(two_lines / h - 1e-9)));
  std::printf("[solid] grid %d x %d x %d at %.4f mm; a piece needs %d voxels (%.2f mm) "
              "across\n", grid.nx, grid.ny, grid.nz, h, k, k * h);

  // ── §2 no piece under 2 line widths ────────────────────────────────────────
  // Covered = inside some k x k x k block that is all SOLID (the opening by a cube).
  {
    auto in = [&](int i, int j, int kk) {
      return i >= 0 && j >= 0 && kk >= 0 && i < sg.nx && j < sg.ny && kk < sg.nz &&
             sg.solid(i, j, kk);
    };
    std::vector<char> block(sg.voxel_count(), 0);  // the block whose low corner is here
    for (int c = 0; c < sg.nz; ++c)
      for (int b = 0; b < sg.ny; ++b)
        for (int a = 0; a < sg.nx; ++a) {
          bool all = true;
          for (int dc = 0; dc < k && all; ++dc)
            for (int db = 0; db < k && all; ++db)
              for (int da = 0; da < k && all; ++da) all = in(a + da, b + db, c + dc);
          block[sg.index(a, b, c)] = all ? 1 : 0;
        }
    long long solid_vox = 0, thin = 0;
    double lo[3] = {1e9, 1e9, 1e9}, hi[3] = {-1e9, -1e9, -1e9};
    for (int c = 0; c < sg.nz; ++c)
      for (int b = 0; b < sg.ny; ++b)
        for (int a = 0; a < sg.nx; ++a) {
          if (!sg.solid(a, b, c)) continue;
          ++solid_vox;
          bool covered = false;
          for (int dc = 0; dc < k && !covered; ++dc)
            for (int db = 0; db < k && !covered; ++db)
              for (int da = 0; da < k && !covered; ++da) {
                const int a0 = a - da, b0 = b - db, c0 = c - dc;
                covered = a0 >= 0 && b0 >= 0 && c0 >= 0 && block[sg.index(a0, b0, c0)];
              }
          if (covered) continue;
          ++thin;
          const Vec3 p = grid.voxel_center(a, b, c);
          lo[0] = std::min(lo[0], p.x); lo[1] = std::min(lo[1], p.y); lo[2] = std::min(lo[2], p.z);
          hi[0] = std::max(hi[0], p.x); hi[1] = std::max(hi[1], p.y); hi[2] = std::max(hi[2], p.z);
        }
    std::printf("[solid] §2 %lld SOLID voxels; %lld in no %d-voxel block", solid_vox, thin, k);
    if (thin > 0)
      std::printf(" (x %.2f-%.2f, y %.2f-%.2f, z %.2f-%.2f)", lo[0], hi[0], lo[1], hi[1], lo[2],
                  hi[2]);
    std::printf("\n");
    CHECK(solid_vox > 0, "§2 the SOLID holds voxels on the run's grid");
    CHECK(thin == 0, "§2 no SOLID piece is thinner than 2 line widths");
  }

  // ── §3 the faces that face air lie on the part's own surface ───────────────
  {
    const MeshDistance on_part(part.mesh);
    const MeshDistance on_solid(solid);
    double air_area = 0.0, off_area = 0.0, worst = 0.0;
    Vec3 worst_at{0, 0, 0};
    for (const auto& t : solid.triangles) {
      const Vec3& a = solid.vertices[static_cast<std::size_t>(t[0])];
      const Vec3& b = solid.vertices[static_cast<std::size_t>(t[1])];
      const Vec3& c = solid.vertices[static_cast<std::size_t>(t[2])];
      Vec3 n = cross(sub(b, a), sub(c, a));
      const double l = std::sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
      if (!(l > 1e-12)) continue;
      const double area = 0.5 * l;
      n = {n.x / l, n.y / l, n.z / l};
      const Vec3 m{(a.x + b.x + c.x) / 3.0, (a.y + b.y + c.y) / 3.0, (a.z + b.z + c.z) / 3.0};
      // Outward from the SOLID, whichever way the file winds.
      const double e = 0.05 * h;
      if (on_solid.signed_distance({m.x + e * n.x, m.y + e * n.y, m.z + e * n.z}) > 0.0)
        n = {-n.x, -n.y, -n.z};
      // A face faces air when a step of 0.02 mm out of it leaves the part. The step is
      // under the 0.1 mm bar, so a face on the part's surface always counts, and a face
      // more than 0.1 mm off it counts too; a solid/lattice interface just under a curved
      // top (the junction's skin) stays an interface. (A half-voxel step read those as
      // facing air: on the arch it leaves the part from 0.25 mm down.)
      const double s = 0.02;
      const Vec3 q{m.x + s * n.x, m.y + s * n.y, m.z + s * n.z};
      if (on_part.signed_distance(q) >= 0.0) continue;  // faces the part's inside
      air_area += area;
      double d = 0.0;
      for (const Vec3& p : {a, b, c, m}) d = std::max(d, on_part.unsigned_distance(p));
      if (d > 0.1) off_area += area;
      if (d > worst) {
        worst = d;
        worst_at = m;
      }
    }
    std::printf("[solid] §3 air-facing %.1f mm^2; %.1f mm^2 of it more than 0.1 mm off the "
                "part (worst %.3f mm at %.2f, %.2f, %.2f)\n",
                air_area, off_area, worst, worst_at.x, worst_at.y, worst_at.z);
    CHECK(air_area > 0.0, "§3 the SOLID has faces that face air");
    CHECK(worst <= 0.1, "§3 every air-facing SOLID face is within 0.1 mm of the part");
  }

  // ── §4 the tongue stays solid; the body is latticed ────────────────────────
  {
    long long tongue = 0, tongue_solid = 0, body = 0, body_solid = 0;
    for (int c = 0; c < grid.nz; ++c)
      for (int b = 0; b < grid.ny; ++b)
        for (int a = 0; a < grid.nx; ++a) {
          if (!grid.solid(a, b, c)) continue;
          const Vec3 p = grid.voxel_center(a, b, c);
          if (p.x > 35.0 && p.y > 16.0 && p.y < 24.0) {
            ++tongue;
            if (sg.solid(a, b, c)) ++tongue_solid;
          }
          if (p.x > 8.0 && p.x < 28.0 && p.y > 8.0 && p.y < 32.0 && p.z > 4.0 && p.z < 28.0) {
            ++body;
            if (sg.solid(a, b, c)) ++body_solid;
          }
        }
    std::printf("[solid] §4 tongue %lld of %lld voxels solid; body core %lld of %lld solid\n",
                tongue_solid, tongue, body_solid, body);
    CHECK(tongue > 0 && tongue_solid == tongue, "§4 the tongue stays solid");
    CHECK(body > 0 && body_solid == 0, "§4 the body's core is latticed");
  }

  // ── §6 no edge wedges ──────────────────────────────────────────────────────
  {
    long long body = 0, junction = 0;
    for (int c = 0; c < sg.nz; ++c)
      for (int b = 0; b < sg.ny; ++b)
        for (int a = 0; a < sg.nx; ++a) {
          if (!sg.solid(a, b, c)) continue;
          const double x = grid.voxel_center(a, b, c).x;
          if (x < 27.0) ++body;
          else if (x < 33.0) ++junction;
        }
    std::printf("[solid] §6 SOLID voxels: %lld in the body (x < 27), %lld at the tongue's "
                "junction (x 27-33)\n", body, junction);
    CHECK(body == 0, "§6 no convex edge of the body is left solid");
    CHECK(junction < 2500, "§6 the junction's solid stays under 2,500 voxels");
  }

  // ── §7 preview = core ──────────────────────────────────────────────────────
  {
    std::vector<double> dens(grid.voxel_count(), 0.0);
    for (std::size_t e = 0; e < dens.size(); ++e)
      dens[e] = grid.tags[e] == VoxelTag::Empty ? 0.0 : 1.0;
    const MeshDistance md(part.mesh);
    GradingLawParams gp;
    gp.topology = LatticeTopology::Octet;
    gp.target_cell_size_mm = 4.0;
    gp.min_extrudable_width_mm = bead;
    gp.member_surface = &md;
    const std::vector<std::uint8_t> why = lattice_solid_fallback_reasons(grid, dens, gp);
    long long count[8] = {0, 0, 0, 0, 0, 0, 0, 0}, solid = 0;
    for (const std::uint8_t r : why) {
      if (r <= 6) ++count[r];
      if (r >= 1 && r <= 4) ++solid;
    }
    std::printf("[solid] §7 reasons: latticed %lld, too thin %lld, any cell %lld, unprintable "
                "%lld, other %lld, sliver latticed %lld, corner joined %lld; the run's solid "
                "fallback %.0f\n", count[0], count[1], count[2], count[3], count[4], count[5],
                count[6], num_after(receipt, "solid_fallback_voxels"));
    CHECK(count[6] > 0, "§7 the convex corners are reported as joined");
    CHECK(static_cast<double>(solid) == num_after(receipt, "solid_fallback_voxels"),
          "§7 the preview's solid count is the run's");
  }

  std::fprintf(stderr, "%d checks, %d failures\n", g_checks, g_failures);
  if (g_failures == 0) std::printf("PASS: %d checks, 0 failures\n", g_checks);
  else std::printf("FAIL: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
