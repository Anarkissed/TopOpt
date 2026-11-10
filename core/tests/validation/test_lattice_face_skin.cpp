// A FACE SKIN (reviewer's ruling 11-10 (3); his 11-10 note: "protect faces' lowest number is
// 1mm but if all I want is the skin protected, there's no way to ensure it goes lattice >
// skin with no space in between").
//
// Today the only way to keep a face is a Protect keep: an exclude region at the Protect
// depth, so the voxels within it stay solid -- at least 1 mm, rounded up to whole voxels,
// and stepped -- and the lattice starts behind that slab. A skin region
// {"kind": "face", "role": "skin", "face_id"} asks instead for a solid of exactly 2 line
// widths on that face's own surface, with the lattice running on, unbroken, behind it.
//
// The bar, on core's own coupon (lattice_coupon_solid) at the rim coupon's settings
// (resolution 64, octet, 4 mm cell, 0.45 mm bead, lattice_part, welded + SOLID written),
// on its flat x = 0 end (the arch's outline, 40 mm wide, 35 mm tall, the latticed body behind
// it; the y = 0 flank runs on into the arch without an edge, so it is not a face of its own):
// §1 today: the same face kept by a 1 mm exclude -- the SOLID behind it measured on the
//    file, the slab he described (printed; it is the "before").
// §2 the skin run writes its receipt and SOLID; the receipt's row says 0.9 mm (2 line
//    widths), measured on the skin as built within 0.02 mm, and no solid voxel behind it.
// §3 ON THE FILE: from the face's inside (2 skin depths from its edges), the SOLID runs
//    0.9 mm deep and stops -- no slab, no inner wall.
// §4 the lattice runs into the skin: the welded lattice has material inside the skin's
//    0.9 mm band all over the face.
// §5 the skin stops at the face's edges: its volume is the face's area x 0.9 mm.
// §6 the SOLID is closed, and the skin's outer face is the part's own (x = 0).
// §7 his Protect depth (ruling 11-10 (ii)): 0 is the skin alone (2 line widths), under 2
//    line widths is rounded up and marked, above it is exact; refusals, in words: a negative
//    depth, a finish on a skin, no face, a face the part does not have.
#include "topopt/job.hpp"
#include "topopt/lattice_sample.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh_distance.hpp"
#include "topopt/part.hpp"
#include "topopt/settings.hpp"
#include "topopt/stl.hpp"

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

double num_after(const std::string& s, const std::string& key, std::size_t from = 0) {
  const std::size_t k = s.find("\"" + key + "\": ", from);
  if (k == std::string::npos) return std::numeric_limits<double>::quiet_NaN();
  const std::size_t v = k + key.size() + 4;
  if (s.compare(v, 4, "null") == 0) return std::numeric_limits<double>::quiet_NaN();
  return std::strtod(s.c_str() + v + (s[v] == '[' ? 1 : 0), nullptr);
}

// The rim coupon's job (prints/2026-11-08-rim-coupon) with the skin off, plus `regions`.
std::string job_json(const std::string& model, int anchor, int load, const std::string& regions) {
  return "{\"model\": \"" + model + "\", \"material\": \"PLA\", \"mode\": \"lattice_part\", "
         "\"resolution\": 64, "
         "\"loads\": {\"minimize_plastic\": true, \"build_dir\": [0, 0, 1], "
         "\"anchor_face_ids\": [" + std::to_string(anchor) + "], \"groups\": [{\"face_ids\": [" +
         std::to_string(load) + "], \"force\": [0, 0, -20]}]}, "
         "\"lattice\": {\"topology\": \"octet\", \"require_lattice_void_reaches_exterior\": "
         "false, \"skin\": \"none\", \"outer_finish\": \"none\", \"emit_welded_stl\": true" +
         regions + "}, "
         "\"grading\": {\"topology\": \"octet\", \"cell_mm\": 4.0, "
         "\"min_extrudable_width_mm\": 0.45, \"intent\": \"structural\"}, "
         "\"output\": {\"report\": \"report.json\", \"mesh_format\": \"stl\", "
         "\"mesh_prefix\": \"coupon\"}}";
}

struct Run {
  std::string refused, receipt, solid_path, welded_path;
};

Run run(const std::string& dir, const std::string& name, const std::string& json) {
  Run r;
  const std::string out = dir + "/" + name + "_run";
  std::filesystem::remove_all(out);
  std::ofstream(dir + "/" + name + ".json") << json;
  try {
    const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
    const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
    const JobDescription job = load_job_file(dir + "/" + name + ".json");
    (void)lattice_variant_job(job, dir, out, materials, rules);
  } catch (const std::exception& e) {
    r.refused = e.what();
  }
  if (std::filesystem::exists(out))
    for (const auto& e : std::filesystem::directory_iterator(out)) {
      const std::string n = e.path().filename().string();
      if (n.size() > 20 && n.compare(n.size() - 20, 20, "_lattice.report.json") == 0)
        r.receipt = read_file(e.path().string());
      if (n.size() > 10 && n.compare(n.size() - 10, 10, "_SOLID.stl") == 0)
        r.solid_path = e.path().string();
      if (n.size() > 11 && n.compare(n.size() - 11, 11, "_WELDED.stl") == 0)
        r.welded_path = e.path().string();
    }
  return r;
}

std::string refusal(const std::string& dir, const std::string& name, const std::string& json) {
  std::ofstream(dir + "/" + name + ".json") << json;
  try {
    (void)load_job_file(dir + "/" + name + ".json");
  } catch (const std::exception& e) {
    return e.what();
  }
  return "";
}

// How deep the solid runs from the face (x = 0) into the part along +x, at (y, z).
double depth_at(const MeshDistance& md, double y, double z) {
  auto inside = [&](double x) { return md.signed_distance({x, y, z}) > 0.0; };
  double lo = 0.01, hi = 12.0;
  if (!inside(lo)) return 0.0;
  if (inside(hi)) return hi;
  for (int it = 0; it < 40; ++it) {
    const double mid = 0.5 * (lo + hi);
    (inside(mid) ? lo : hi) = mid;
  }
  return 0.5 * (lo + hi);
}

}  // namespace

int main() {
  const std::string dir = TMP_DIR;
  const double t = 2.0 * 0.45;

  write_stl_file(dir + "/face_skin_coupon.stl", lattice_coupon_solid(), StlFormat::Binary);
  const StepModel part = import_part(dir + "/face_skin_coupon.stl").model;
  const int bottom = face_with_normal(part, 0, 0, -1);
  const int end = face_with_normal(part, 1, 0, 0);
  // The x = 0 end: the coupon's arch outline, the latticed body behind it. (Its y = 0 flank
  // runs on into the arch with no edge between, so it is no face of its own; the tongue's -y
  // side is, and it is solid at 4 mm cells.)
  const int side = face_with_normal(part, -1, 0, 0);
  CHECK(bottom >= 0 && end >= 0 && side >= 0,
        "precondition: the coupon's bottom, its x+ end and its x = 0 end");
  // The face's own extent, in y (x0..x1 below) and z.
  double x0 = 1e9, x1 = -1e9, z0 = 1e9, z1 = -1e9, area = 0.0;
  for (std::size_t i = 0; i < part.mesh.triangles.size(); ++i) {
    if (part.triangle_face[i] != side) continue;
    const auto& tr = part.mesh.triangles[i];
    const Vec3& a = part.mesh.vertices[static_cast<std::size_t>(tr[0])];
    const Vec3& b = part.mesh.vertices[static_cast<std::size_t>(tr[1])];
    const Vec3& c = part.mesh.vertices[static_cast<std::size_t>(tr[2])];
    for (const Vec3* p : {&a, &b, &c}) {
      x0 = std::min(x0, p->y); x1 = std::max(x1, p->y);
      z0 = std::min(z0, p->z); z1 = std::max(z1, p->z);
    }
    const Vec3 u{b.x - a.x, b.y - a.y, b.z - a.z}, v{c.x - a.x, c.y - a.y, c.z - a.z};
    const Vec3 n{u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x};
    area += 0.5 * std::sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
  }
  std::printf("[skin] the x = 0 end is face %d: y %.2f-%.2f, z %.2f-%.2f, %.1f mm^2\n", side, x0,
              x1, z0, z1, area);
  // Inside the outline (sides to z 15, then an arc of 20 mm about y 20, z 15), at least
  // `m` from its edges.
  auto in_face = [](double y, double z, double m) {
    return y >= m && y <= 40.0 - m && z >= m &&
           (z <= 15.0 || std::hypot(y - 20.0, z - 15.0) <= 20.0 - m);
  };
  // The face's inside, 2 skin depths from its edges, sampled on a 1.5 mm grid.
  std::vector<std::pair<double, double>> inner;
  for (double y = x0; y <= x1; y += 1.5)
    for (double z = z0; z <= z1; z += 1.5)
      if (in_face(y, z, 2 * t)) inner.emplace_back(y, z);

  // ── §1 today: a 1 mm Protect keep on the same face ─────────────────────────
  {
    char regs[512];
    std::snprintf(regs, sizeof regs,
                  ", \"whole_part\": true, \"regions\": [{\"role\": \"exclude\", \"kind\": "
                  "\"face\", \"face_id\": %d, \"geometry\": {\"origin\": [0, %.4f, %.4f], "
                  "\"normal\": [1, 0, 0], \"frame_u\": [0, 0, -1], \"frame_w\": [0, 1, 0], "
                  "\"half_u_mm\": %.4f, \"half_w_mm\": %.4f, \"depth_mm\": 1.0}}]",
                  side, 0.5 * (x0 + x1), 0.5 * (z0 + z1), 0.5 * (z1 - z0), 0.5 * (x1 - x0));
    // (core's in-plane basis for the normal +x is u = -z, w = +y: clearance.cpp plane_basis)
    const Run r = run(dir, "face_skin_today", job_json("face_skin_coupon.stl", bottom, end, regs));
    if (!r.refused.empty()) std::printf("[skin] today: refused: %s\n", r.refused.c_str());
    if (!r.solid_path.empty()) {
      const TriangleMesh today_solid = read_stl_file(r.solid_path).mesh;  // MeshDistance keeps a pointer
      const MeshDistance md(today_solid);
      double lo = 1e9, hi = 0.0;
      for (const auto& [y, z] : inner) {
        const double d = depth_at(md, y, z);
        lo = std::min(lo, d);
        hi = std::max(hi, d);
      }
      std::printf("[skin] §1 today, a 1 mm keep: the solid behind the face runs %.3f to %.3f mm "
                  "deep (the slab)\n", lo, hi);
    }
  }

  // ── §2 the skin ────────────────────────────────────────────────────────────
  char regs[256];
  std::snprintf(regs, sizeof regs,
                ", \"regions\": [{\"kind\": \"face\", \"role\": \"skin\", \"face_id\": %d, "
                "\"label\": \"end\"}]", side);
  const Run r = run(dir, "face_skin", job_json("face_skin_coupon.stl", bottom, end, regs));
  if (!r.refused.empty()) std::printf("[skin] refused: %s\n", r.refused.c_str());
  CHECK(r.refused.empty() && !r.receipt.empty(), "§2 the skin run writes its receipt");
  CHECK(!r.solid_path.empty(), "§2 and its SOLID");
  const std::size_t row = r.receipt.find("\"face_skins\"");
  CHECK(row != std::string::npos, "§2 the receipt carries the skin's row");
  if (row == std::string::npos || r.solid_path.empty()) {
    std::fprintf(stderr, "%d checks, %d failures\n", g_checks, g_failures);
    return 1;
  }
  const double th = num_after(r.receipt, "thickness_mm", row);
  const std::size_t mt = r.receipt.find("\"measured_thickness_mm\": [", row);
  const double mlo = num_after(r.receipt, "measured_thickness_mm", row);
  const double mhi = mt == std::string::npos ? -1.0
                     : std::strtod(r.receipt.c_str() + r.receipt.find(", ", mt + 26) + 2, nullptr);
  const double at = num_after(r.receipt, "measured_at", row);
  const double behind = num_after(r.receipt, "solid_voxels_behind", row);
  const double vol = num_after(r.receipt, "volume_mm3", row);
  std::printf("[skin] §2 receipt: %.3f mm asked, measured %.4f to %.4f mm at %.0f points, "
              "%.0f solid voxels behind, %.2f mm^3\n", th, mlo, mhi, at, behind, vol);
  CHECK(std::fabs(th - t) < 1e-9, "§2 the default skin is 2 line widths, 0.9 mm");
  CHECK(at > 0 && std::fabs(mlo - t) < 0.02 && std::fabs(mhi - t) < 0.02,
        "§2 measured on the skin as built, it is 0.9 mm thick everywhere inside the face");
  CHECK(behind == 0.0, "§2 no solid voxel sits behind the skin");

  // ── §3 on the file ─────────────────────────────────────────────────────────
  const TriangleMesh solid = read_stl_file(r.solid_path).mesh;
  const MeshDistance md(solid);
  double lo = 1e9, hi = 0.0;
  for (const auto& [y, z] : inner) {
    const double d = depth_at(md, y, z);
    lo = std::min(lo, d);
    hi = std::max(hi, d);
  }
  std::printf("[skin] §3 on the SOLID file: the solid behind the face runs %.4f to %.4f mm deep "
              "at %zu points\n", lo, hi, inner.size());
  CHECK(!inner.empty() && std::fabs(lo - t) < 0.02 && std::fabs(hi - t) < 0.02,
        "§3 on the file the solid behind the face is the 0.9 mm skin and stops there: no "
        "slab, no inner wall");

  // ── §4 the lattice runs into the skin ──────────────────────────────────────
  CHECK(!r.welded_path.empty(), "§4 the welded lattice is written");
  if (!r.welded_path.empty()) {
    const TriangleMesh lat = read_stl_file(r.welded_path).mesh;
    // 4 mm squares over the face's inside (every corner 2 skin depths in): how many hold
    // lattice inside the skin's band.
    const int nu = std::max(1, static_cast<int>((x1 - x0) / 4.0));
    const int nw = std::max(1, static_cast<int>((z1 - z0) / 4.0));
    std::vector<char> want(static_cast<std::size_t>(nu * nw), 0), hit(want.size(), 0);
    for (int iw = 0; iw < nw; ++iw)
      for (int iu = 0; iu < nu; ++iu) {
        const double ya = x0 + 4.0 * iu, za = z0 + 4.0 * iw;
        want[static_cast<std::size_t>(iw * nu + iu)] =
            in_face(ya, za, 2 * t) && in_face(ya + 4, za, 2 * t) && in_face(ya, za + 4, 2 * t) &&
            in_face(ya + 4, za + 4, 2 * t);
      }
    for (const Vec3& p : lat.vertices) {
      if (!(p.x > 0.0 && p.x < t)) continue;
      const int iu = static_cast<int>((p.y - x0) / 4.0);
      const int iw = static_cast<int>((p.z - z0) / 4.0);
      if (iu < 0 || iw < 0 || iu >= nu || iw >= nw) continue;
      hit[static_cast<std::size_t>(iw * nu + iu)] = 1;
    }
    int n = 0, nwant = 0;
    for (std::size_t q = 0; q < want.size(); ++q) nwant += want[q], n += want[q] && hit[q];
    std::printf("[skin] §4 the lattice reaches into the skin in %d of %d 4 mm squares\n", n,
                nwant);
    CHECK(nwant > 0 && n == nwant,
          "§4 the lattice runs into the skin all over the face (one cell = 4 mm)");
  }

  // ── §5 the skin stops at the face's edges ──────────────────────────────────
  CHECK(std::fabs(vol - area * t) < 0.02 * area * t,
        "§5 the skin's volume is the face's area x 0.9 mm: it stops at the face's edges");

  // ── §6 closed, and its outer face is the part's ────────────────────────────
  CHECK(check_watertight(solid).watertight, "§6 the SOLID is closed");
  double off = 0.0;
  for (const auto& [y, z] : inner) off = std::max(off, std::fabs(md.signed_distance({0.0, y, z})));
  CHECK(off < 1e-3, "§6 the skin's outer face is the part's own x = 0 face");

  // ── §7 refusals, in words ──────────────────────────────────────────────────
  auto skin_job = [&](const std::string& extra) {
    return job_json("face_skin_coupon.stl", bottom, end,
                    ", \"regions\": [{\"kind\": \"face\", \"role\": \"skin\"" + extra + "}]");
  };
  const std::string fid = ", \"face_id\": " + std::to_string(side);
  // ★ ruling 11-10 (ii): under 2 line widths is ROUNDED UP and said, never refused
  {
    std::ofstream(dir + "/face_skin_thin.json") << skin_job(fid + ", \"thickness_mm\": 0.5");
    std::string why;
    double th_thin = 0.0;
    bool rounded = false;
    try {
      const JobDescription j = load_job_file(dir + "/face_skin_thin.json");
      th_thin = j.lattice.face_skins.empty() ? 0.0 : j.lattice.face_skins[0].thickness_mm;
      rounded = !j.lattice.face_skins.empty() && j.lattice.face_skins[0].rounded_up;
    } catch (const std::exception& e) {
      why = e.what();
    }
    CHECK(why.empty() && std::fabs(th_thin - t) < 1e-9 && rounded,
          "§7 a 0.5 mm skin is rounded up to 2 line widths (0.9 mm), and marked so");
    std::ofstream(dir + "/face_skin_zero.json") << skin_job(fid + ", \"thickness_mm\": 0");
    const JobDescription z = load_job_file(dir + "/face_skin_zero.json");
    CHECK(!z.lattice.face_skins.empty() && std::fabs(z.lattice.face_skins[0].thickness_mm - t) < 1e-9 &&
              !z.lattice.face_skins[0].rounded_up,
          "§7 depth 0 is the skin alone, 2 line widths, and not called a rounding");
    std::ofstream(dir + "/face_skin_thick.json") << skin_job(fid + ", \"thickness_mm\": 1.7");
    const JobDescription k = load_job_file(dir + "/face_skin_thick.json");
    CHECK(!k.lattice.face_skins.empty() && k.lattice.face_skins[0].thickness_mm == 1.7,
          "§7 above 2 line widths it is exactly his depth");
  }
  const std::string neg = refusal(dir, "face_skin_neg", skin_job(fid + ", \"thickness_mm\": -1"));
  CHECK(neg.find("must be 0") != std::string::npos, "§7 a negative depth is refused");
  const std::string fin =
      refusal(dir, "face_skin_finish", skin_job(fid + ", \"outer_finish\": \"shell\""));
  CHECK(fin.find("a skin states only") != std::string::npos,
        "§7 a finish on a skin is refused: it is solid");
  const std::string noface = refusal(dir, "face_skin_noface", skin_job(""));
  CHECK(noface.find("needs the \"face_id\"") != std::string::npos,
        "§7 a skin with no face is refused");
  const Run far = run(dir, "face_skin_far", skin_job(", \"face_id\": 999"));
  CHECK(far.refused.find("names face 999") != std::string::npos &&
            far.refused.find("faces (0 to") != std::string::npos,
        "§7 a skin on a face the part does not have is refused, with the part's face count");

  // ── §8 a Protect and a skin on ONE face (TO-core, 11-10) ───────────────────
  // The depth tie (a protected face's lattice region must sit at the protection's depth; on
  // release-4, E2.5 and E4 (k) too) reads job.lattice.regions only, and a skin never enters
  // that list. So a skin at a depth other than the face's protection parses. The control: an
  // exclude region at that same other depth on that face is refused, so the tie is live here.
  {
    auto protect = [&](std::string j) {
      const std::string at = "\"build_dir\": [0, 0, 1], ";
      j.insert(j.find(at) + at.size(), "\"face_protections\": [{\"face_id\": " +
                                           std::to_string(side) + ", \"depth_mm\": 3}], ");
      return j;
    };
    const std::string both =
        refusal(dir, "face_skin_protected", protect(skin_job(fid + ", \"thickness_mm\": 1.7")));
    CHECK(both.empty(), "§8 a 3 mm protected face with a 1.7 mm skin parses: a skin is not a "
                        "lattice region, so the depth tie does not read it");
    if (!both.empty()) std::printf("  refused: %s\n", both.c_str());
    const std::string tie = refusal(
        dir, "face_skin_tie_control",
        protect(job_json("face_skin_coupon.stl", bottom, end,
                         ", \"regions\": [{\"kind\": \"face\", \"role\": \"exclude\", "
                         "\"face_id\": " + std::to_string(side) +
                             ", \"geometry\": {\"origin\": [0, 20, 8], \"normal\": [-1, 0, 0], "
                             "\"half_u_mm\": 5, \"half_w_mm\": 10, \"depth_mm\": 1.7}}]")));
    CHECK(tie.find("BOTH protected") != std::string::npos,
          "§8 control: a 1.7 mm exclude region on that 3 mm protected face is refused");
    if (tie.find("BOTH protected") == std::string::npos) std::printf("  got: %s\n", tie.c_str());
  }

  std::printf("%s: %d checks, %d failures\n", g_failures == 0 ? "PASS" : "FAIL", g_checks,
              g_failures);
  return g_failures == 0 ? 0 : 1;
}
