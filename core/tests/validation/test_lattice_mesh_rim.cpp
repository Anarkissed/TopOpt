// The rim on a real part (reviewer's ruling 11-08 (A)): lattice.skin "rim", and a zone's
// regions[].skin "rim". Before it, a run's rim rode only pairs of flat CAD faces in the
// lattice boundary, and a run's boundary has none, so every rim job was refused (M4,
// rim_triangles 0) -- on core's coupon and on his l-bracket alike.
//
// Now the rim rides the SHARP EDGES of a clean surface, never the voxel grid (the part's
// own mesh when the part itself is latticed, else the design's exported surface): edges
// whose faces meet at more than 30 degrees, joined into chains, pieces under one cell
// dropped; one tube per chain at the skin radius in whole line widths, seated inside the
// shell the struts are clipped to (up to 1.5 voxels in), clipped like any strut; dressing
// only. Where the part stays solid the clip drops it: the rim dresses the lattice.
//
// §1 the edges: a bar has its 12; the coupon's outline is closed and its smooth
//    half-cylinder top carries none; a piece under one cell is dropped and counted.
// §2 the coupon latticed and covered, with and without the rim: the rim is laid, its
//    diameter a whole number of line widths, the receipt says it is not counted in
//    strength, and the certificate's margin is the same number either way; no chain the
//    rim rides crosses the smooth top.
// §3 the coupon open (outer_finish "none"): the cut strut ends near the edges are tied.
// §4 his l-bracket: its plates are 8 mm thick, under the 17.5 mm an octet member needs at
//    3.5 mm cells, so the run REFUSES and no rim is laid. Until ruling 11-09 (2) the run's
//    grid ended at the bracket's own faces and the member width read past them as
//    material: the plates read 18.75 mm and were latticed, and the rim rode that lattice.
//    That lattice was the grid's edge, not the part. (Latticing an 8 mm plate takes a
//    cell under 1.6 mm, a run too heavy for this test.)
// §5 Rim per zone: the coupon with the rim only in "Wall end" (the 6 mm under its x = 0
//    face): every chain it rides has its midpoint there, and the rest are counted.
// §6 the welded body (emit_welded_stl) with the rim is one closed mesh.
#include "topopt/feature_edges.hpp"
#include "topopt/job.hpp"
#include "topopt/lattice_sample.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/materials.hpp"
#include "topopt/part.hpp"
#include "topopt/settings.hpp"
#include "topopt/stl.hpp"

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

TriangleMesh box(double L, double W, double H) {
  TriangleMesh m;
  for (const Vec3& v : std::vector<Vec3>{{0, 0, 0}, {L, 0, 0}, {L, W, 0}, {0, W, 0},
                                         {0, 0, H}, {L, 0, H}, {L, W, H}, {0, W, H}})
    m.vertices.push_back(v);
  const int t[12][3] = {{0, 2, 1}, {0, 3, 2}, {4, 5, 6}, {4, 6, 7}, {0, 1, 5}, {0, 5, 4},
                        {3, 7, 6}, {3, 6, 2}, {0, 4, 7}, {0, 7, 3}, {1, 2, 6}, {1, 6, 5}};
  for (const auto& tri : t) m.triangles.push_back({tri[0], tri[1], tri[2]});
  return m;
}

// The LARGEST planar face with this outward normal (by its triangles' area): an STL's
// fitted faces include slivers smaller than a voxel, which tag nothing.
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
  if (best >= 0)
    std::printf("[rim] face (%.0f,%.0f,%.0f): id %d, %.1f mm^2\n", nx, ny, nz, best,
                area[static_cast<std::size_t>(best)]);
  return best;
}

std::string read_file(const std::string& p) {
  std::ifstream in(p, std::ios::binary);
  std::stringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

double num_after(const std::string& s, const std::string& key, std::size_t from = 0) {
  if (from == std::string::npos) return std::numeric_limits<double>::quiet_NaN();
  const std::size_t k = s.find("\"" + key + "\": ", from);
  if (k == std::string::npos) return std::numeric_limits<double>::quiet_NaN();
  const std::size_t v = k + key.size() + 4;
  if (s.compare(v, 4, "null") == 0) return std::numeric_limits<double>::quiet_NaN();
  return std::strtod(s.c_str() + v, nullptr);
}
bool has(const std::string& s, const std::string& w) { return s.find(w) != std::string::npos; }

// A lattice_part job: anchored on `anchor`, 20 N in -z on `load`, octet at 4 mm.
std::string job_json(const std::string& model, int anchor, int load, int resolution,
                     const std::string& lattice_extra, double cell_mm = 4.0) {
  return "{\"model\": \"" + model + "\", \"material\": \"PLA\", \"mode\": \"lattice_part\", "
         "\"resolution\": " + std::to_string(resolution) + ", "
         "\"loads\": {\"minimize_plastic\": true, \"build_dir\": [0, 0, 1], "
         "\"anchor_face_ids\": [" + std::to_string(anchor) + "], \"groups\": [{\"face_ids\": [" +
         std::to_string(load) + "], \"force\": [0, 0, -20]}]}, "
         "\"lattice\": {\"topology\": \"octet\", \"require_lattice_void_reaches_exterior\": "
         "false" + lattice_extra + "}, "
         "\"grading\": {\"topology\": \"octet\", \"cell_mm\": " + std::to_string(cell_mm) + ", "
         "\"min_extrudable_width_mm\": 0.45, \"intent\": \"structural\"}, "
         "\"output\": {\"report\": \"report.json\", \"mesh_format\": \"stl\", "
         "\"mesh_prefix\": \"variant\"}}";
}

struct Run {
  std::string receipt, refused, folder;
  std::vector<std::vector<Vec3>> chains;  // TOPOPT_RIM_DUMP
};
Run lattice_part(const std::string& dir, const std::string& tag, const std::string& json) {
  Run out;
  out.folder = dir + "/mesh_rim_" + tag;
  std::filesystem::remove_all(out.folder);
  const std::string dump = dir + "/mesh_rim_" + tag + "_chains.txt";
  std::filesystem::remove(dump);
  setenv("TOPOPT_RIM_DUMP", dump.c_str(), 1);
  std::ofstream(dir + "/mesh_rim_" + tag + ".json") << json;
  try {
    const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
    const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
    const JobDescription job = load_job_file(dir + "/mesh_rim_" + tag + ".json");
    (void)lattice_variant_job(job, dir, out.folder, materials, rules);
  } catch (const std::exception& e) {
    out.refused = e.what();
    std::printf("  (%s refused: %s)\n", tag.c_str(), e.what());
  }
  unsetenv("TOPOPT_RIM_DUMP");
  if (std::filesystem::exists(out.folder))
    for (const auto& e : std::filesystem::directory_iterator(out.folder)) {
      const std::string n = e.path().filename().string();
      if (n.size() > 20 && n.compare(n.size() - 20, 20, "_lattice.report.json") == 0)
        out.receipt = read_file(e.path().string());
    }
  std::ifstream in(dump);
  std::string word;
  while (in >> word) {
    if (word != "CHAIN") break;
    int closed = 0;
    std::size_t n = 0;
    double len = 0.0;
    in >> closed >> n >> len;
    std::vector<Vec3> pts(n);
    for (Vec3& p : pts) in >> p.x >> p.y >> p.z;
    out.chains.push_back(pts);
  }
  return out;
}

Vec3 midpoint(const std::vector<Vec3>& pts) {
  double total = 0.0;
  for (std::size_t i = 0; i + 1 < pts.size(); ++i) {
    const Vec3 d{pts[i + 1].x - pts[i].x, pts[i + 1].y - pts[i].y, pts[i + 1].z - pts[i].z};
    total += std::sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
  }
  double half = 0.5 * total;
  for (std::size_t i = 0; i + 1 < pts.size(); ++i) {
    const Vec3 d{pts[i + 1].x - pts[i].x, pts[i + 1].y - pts[i].y, pts[i + 1].z - pts[i].z};
    const double l = std::sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
    if (half <= l && l > 0) return {pts[i].x + d.x * half / l, pts[i].y + d.y * half / l,
                                    pts[i].z + d.z * half / l};
    half -= l;
  }
  return pts.empty() ? Vec3{0, 0, 0} : pts.back();
}

// A point of the coupon's smooth top: above the spring line, off every end face and off
// the tongue's sides. A sharp edge never lies there.
bool on_smooth_top(const Vec3& p) {
  const double eps = 1.5;   // a voxel and a half: the shipped shell's edges wander that far
  if (p.z < 15.0 + eps) return false;
  for (double x : {0.0, 33.0, 45.0})
    if (std::fabs(p.x - x) < eps) return false;
  if (p.x > 33.0 - eps)
    for (double y : {14.0, 26.0})
      if (std::fabs(p.y - y) < eps) return false;
  return true;
}

}  // namespace

int main() {
  const std::string dir = TMP_DIR;

  // ── §1 the edges ──────────────────────────────────────────────────────────
  {
    FeatureEdgeStats st;
    const std::vector<FeatureChain> ch = mesh_feature_chains(box(60, 20, 20), 30.0, 4.0, &st);
    std::printf("[rim] bar: %zu feature edges, %zu chains, %zu piece(s), %.1f mm\n",
                st.feature_edges, st.chains, st.pieces, st.length_mm);
    CHECK(st.feature_edges == 12 && st.chains == 12 && st.pieces == 1,
          "§1 a bar has its 12 sharp edges, 12 chains meeting at corners, one piece");
    CHECK(std::fabs(st.length_mm - 400.0) < 1e-9 && st.open_edges == 0 &&
              st.nonmanifold_edges == 0,
          "§1 the bar's edges total 4 x (60 + 20 + 20) mm; nothing skipped");
    bool convex = true;
    for (const FeatureChain& c : ch)
      for (char v : c.convex) convex = convex && v;
    CHECK(convex, "§1 a box's edges are all convex");

    FeatureEdgeStats tiny;
    (void)mesh_feature_chains(box(1, 1, 1), 30.0, 13.0, &tiny);
    CHECK(tiny.chains == 0 && tiny.pieces_dropped_short == 1 &&
              std::fabs(tiny.length_dropped_mm - 12.0) < 1e-9,
          "§1 a piece under one cell (12 mm of edge, a 13 mm cell) is dropped and counted");

    FeatureEdgeStats cs;
    const std::vector<FeatureChain> cc = mesh_feature_chains(lattice_coupon_solid(), 30.0, 4.0, &cs);
    long long on_top = 0;
    for (const FeatureChain& c : cc)
      for (std::size_t i = 0; i < c.segments(); ++i) {
        const Vec3& l = c.left_normal[i];
        const Vec3& r = c.right_normal[i];
        if (std::fabs(l.x) < 1e-9 && std::fabs(r.x) < 1e-9 && l.z > 0.01 && r.z > 0.01) ++on_top;
      }
    std::printf("[rim] coupon outline: %zu feature edges, %zu chains, %.1f mm; open %zu, "
                "non-manifold %zu; between two top facets: %lld\n",
                cs.feature_edges, cs.chains, cs.length_mm, cs.open_edges, cs.nonmanifold_edges,
                on_top);
    CHECK(cs.open_edges == 0 && cs.nonmanifold_edges == 0, "§1 the coupon's outline is closed");
    CHECK(cs.chains > 0 && on_top == 0, "§1 the coupon's smooth top carries no sharp edge");
  }

  // ── the coupon as a part ───────────────────────────────────────────────────
  write_stl_file(dir + "/mesh_rim_coupon.stl", lattice_coupon_solid(), StlFormat::Binary);
  const StepModel coupon = import_part(dir + "/mesh_rim_coupon.stl").model;
  const int c_bottom = face_with_normal(coupon, 0, 0, -1);
  const int c_end = face_with_normal(coupon, 1, 0, 0);
  CHECK(c_bottom >= 0 && c_end >= 0, "precondition: the coupon's bottom and an x+ end face");
  const std::string cj = "mesh_rim_coupon.stl";

  // ── §2 covered, with and without the rim ───────────────────────────────────
  {
    const Run none = lattice_part(dir, "coupon_none", job_json(cj, c_bottom, c_end, 32, ", \"skin\": \"none\""));
    const Run rim = lattice_part(dir, "coupon_rim", job_json(cj, c_bottom, c_end, 32, ", \"skin\": \"rim\""));
    const std::size_t rb = rim.receipt.find("\"rim\": {");
    const double laid = num_after(rim.receipt, "chains_laid", rb);
    const double dmax = num_after(rim.receipt, "diameter_mm", rb) ;
    const double m0 = num_after(none.receipt, "lattice_margin_effective");
    const double m1 = num_after(rim.receipt, "lattice_margin_effective");
    long long across_top = 0;
    for (const auto& c : rim.chains)
      for (const Vec3& p : c)
        if (on_smooth_top(p)) { ++across_top; break; }
    std::printf("[rim] coupon covered: %s\n", rb == std::string::npos ? "(no rim block)"
                                                                       : rim.receipt.substr(rb, 700).c_str());
    std::printf("[rim] margins: none %.6g, rim %.6g; rim elements %.0f, rim triangles in file; "
                "%zu chains dumped, %lld cross the smooth top\n",
                m0, m1, num_after(rim.receipt, "rim_elements"), rim.chains.size(), across_top);
    (void)dmax;
    CHECK(rim.refused.empty() && rb != std::string::npos, "§2 the rim job runs and writes its rim block");
    CHECK(laid > 0 && num_after(rim.receipt, "rim_elements") > 0, "§2 the rim is laid");
    CHECK(has(rim.receipt, "\"strength\": \"rim: not counted in strength\""),
          "§2 the receipt says the rim is not counted in strength");
    {
      const double w = num_after(rim.receipt, "line_width_mm", rb);
      const std::size_t d = rim.receipt.find("\"diameter_mm\": [", rb);
      const double d0 = d == std::string::npos ? NAN : std::strtod(rim.receipt.c_str() + d + 16, nullptr);
      const double k = d0 / w;
      CHECK(std::isfinite(k) && std::fabs(k - std::round(k)) < 1e-9 && k >= 1,
            "§2 the rim's diameter is a whole number of line widths");
    }
    CHECK(std::isfinite(m0) && m0 == m1, "§2 the certificate's margin is the same with or without the rim");
    CHECK(!rim.chains.empty() && across_top == 0, "§2 no chain the rim rides crosses the smooth top");
    CHECK(!has(none.receipt, "\"rim\": {"), "§2 control: no rim asked, no rim block");
    // Seated ALONG each run, not only at its points (station_spacing_mm): with stations
    // only at a chain's points, a straight edge between two corners never seated (a
    // corner of three faces cannot) and lost its length to the clip; this coupon laid
    // 288 of its 516 mm, and at resolution 64 two whole edges clipped away. Only the
    // corners are left out now.
    {
      double chain_len = 0.0;  // the coupon's chains are all open
      for (const auto& c : rim.chains)
        for (std::size_t i = 0; i + 1 < c.size(); ++i)
          chain_len += std::sqrt((c[i + 1].x - c[i].x) * (c[i + 1].x - c[i].x) +
                                 (c[i + 1].y - c[i].y) * (c[i + 1].y - c[i].y) +
                                 (c[i + 1].z - c[i].z) * (c[i + 1].z - c[i].z));
      const double laid_mm = num_after(rim.receipt, "length_laid_mm", rb);
      const double solid_mm = num_after(rim.receipt, "length_on_solid_mm", rb);
      std::printf("[rim] coupon covered: laid %.1f of %.1f mm of edge (%.1f %%), %.1f mm along "
                  "material left solid, %.0f chain(s) clipped away, %.0f on solid\n",
                  laid_mm, chain_len, 100.0 * laid_mm / chain_len, solid_mm,
                  num_after(rim.receipt, "chains_clipped_away", rb),
                  num_after(rim.receipt, "chains_on_solid", rb));
      CHECK(num_after(rim.receipt, "chains_clipped_away", rb) == 0,
            "§2 no edge chain is clipped away");
      CHECK(chain_len > 0.0 && std::isfinite(solid_mm) && laid_mm + solid_mm >= 0.9 * chain_len,
            "§2 the rim lays at least 90 % of the edges the lattice reaches (only corners are "
            "left out; edges along material left solid are counted, not laid)");
    }
  }

  // ── §3 open: the cut ends near the edges are tied ──────────────────────────
  {
    const Run r = lattice_part(dir, "coupon_open",
                               job_json(cj, c_bottom, c_end, 32,
                                        ", \"skin\": \"rim\", \"outer_finish\": \"none\""));
    const std::size_t rb = r.receipt.find("\"rim\": {");
    std::printf("[rim] coupon open: tie ends %.0f, tied %.0f, touching %.0f, out of reach %.0f, "
                "clipped away %.0f, %.1f mm of tie\n",
                num_after(r.receipt, "tie_ends", rb), num_after(r.receipt, "ties_laid", rb),
                num_after(r.receipt, "ties_touching", rb), num_after(r.receipt, "ties_out_of_reach", rb),
                num_after(r.receipt, "ties_clipped_away", rb), num_after(r.receipt, "tie_length_mm", rb));
    CHECK(rb != std::string::npos && num_after(r.receipt, "chains_laid", rb) > 0,
          "§3 the open coupon's rim is laid");
    CHECK(num_after(r.receipt, "ties_laid", rb) > 0, "§3 cut strut ends near the edges are tied to it");
  }

  // ── §4 his l-bracket ───────────────────────────────────────────────────────
  {
    const std::string lb = std::string(DEMO_FIXTURE_DIR) + "/l-bracket.step";
    const StepModel m = import_part(lb).model;
    const int bottom = face_with_normal(m, 0, 0, -1), side = face_with_normal(m, 1, 0, 0);
    CHECK(bottom >= 0 && side >= 0, "precondition: the l-bracket's bottom and its x+ face");
    const Run r = lattice_part(dir, "lbracket", job_json(lb, bottom, side, 32, ", \"skin\": \"rim\"", 3.5));
    std::printf("[rim] l-bracket: %s\n", r.refused.c_str());
    static const char kWidest[] = "Every member is too thin: the widest is ";
    const std::size_t at = r.refused.find(kWidest);
    const double widest = at == std::string::npos
                              ? -1.0
                              : std::strtod(r.refused.c_str() + at + sizeof kWidest - 1, nullptr);
    CHECK(r.refused.find("could lattice NONE") != std::string::npos,
          "§4 his l-bracket's 8 mm plates are too thin for 3.5 mm cells: the run refuses");
    // ★ ruling 11-10 (3): measured below a voxel, the widest member is the ball inscribed in
    // the L's corner, touching both outer faces and the inner corner's edge: diameter
    // 2 x 8 sqrt 2 / (1 + sqrt 2) = 9.373 mm. (The two-voxel levels read no more than 8.)
    const double corner_ball = 2.0 * 8.0 * std::sqrt(2.0) / (1.0 + std::sqrt(2.0));
    CHECK(widest > 0.0 && widest <= corner_ball + 1e-3,
          "§4 and the widest member it rejects is no wider than the ball in the bracket's "
          "corner, where its two 8 mm plates meet");
    // ★ ruling 11-10: the floor is quoted at the run's own cell, beside the width
    CHECK(r.refused.find("under the 17.5 mm that 5 cells of this run's finest cell (3.5 mm) need") !=
              std::string::npos,
          "§4 and the refusal quotes the floor at the run's own 3.5 mm cell, beside the width");
  }

  // ── §5 Rim per zone ────────────────────────────────────────────────────────
  {
    const int c_wall = face_with_normal(coupon, -1, 0, 0);
    char regs[600];
    std::snprintf(regs, sizeof regs,
                  ", \"skin\": \"none\", \"whole_part\": true, \"regions\": [{\"role\": \"include\", "
                  "\"kind\": \"face\", \"face_id\": %d, \"label\": \"Wall end\", \"skin\": \"rim\", "
                  "\"geometry\": {\"origin\": [0, 20, 17.5], \"normal\": [1, 0, 0], "
                  "\"half_u_mm\": 20, \"half_w_mm\": 17.5, \"depth_mm\": 6}}]",
                  c_wall);
    const Run r = lattice_part(dir, "coupon_zone", job_json(cj, c_bottom, c_end, 32, regs));
    const std::size_t rb = r.receipt.find("\"rim\": {");
    long long outside = 0;
    for (const auto& c : r.chains)
      if (midpoint(c).x > 6.0 + 1e-6) ++outside;
    std::printf("[rim] zone: %zu chains ridden, %lld with a midpoint outside Wall end; other skin "
                "%.0f, laid %.0f\n",
                r.chains.size(), outside, num_after(r.receipt, "chains_other_skin", rb),
                num_after(r.receipt, "chains_laid", rb));
    CHECK(r.refused.empty() && num_after(r.receipt, "chains_laid", rb) > 0,
          "§5 the zone's rim is laid");
    CHECK(!r.chains.empty() && outside == 0, "§5 every chain it rides has its midpoint in Wall end");
    CHECK(num_after(r.receipt, "chains_other_skin", rb) > 0, "§5 the rest are counted, not laid");
  }

  // ── §6 the welded body is one closed mesh ──────────────────────────────────
  {
    const Run r = lattice_part(dir, "coupon_welded",
                               job_json(cj, c_bottom, c_end, 32,
                                        ", \"skin\": \"rim\", \"emit_welded_stl\": true"));
    std::string welded;
    if (std::filesystem::exists(r.folder))
      for (const auto& e : std::filesystem::directory_iterator(r.folder)) {
        const std::string n = e.path().filename().string();
        if (n.find("WELDED") != std::string::npos && n.size() > 4 &&
            n.compare(n.size() - 4, 4, ".stl") == 0)
          welded = e.path().string();
      }
    FeatureEdgeStats ws;
    if (!welded.empty()) (void)mesh_feature_chains(read_stl_file(welded).mesh, 30.0, 4.0, &ws);
    std::printf("[rim] welded: %s, %zu welded vertices, open %zu, non-manifold %zu\n",
                welded.empty() ? "(none)" : welded.c_str(), ws.welded_vertices, ws.open_edges,
                ws.nonmanifold_edges);
    CHECK(!welded.empty() && ws.welded_vertices > 0 && ws.open_edges == 0 &&
              ws.nonmanifold_edges == 0,
          "§6 the welded body with the rim is one closed mesh");
  }

  std::printf("%s: %d checks, %d failures\n", g_failures ? "FAIL" : "PASS", g_checks, g_failures);
  return g_failures ? 1 : 0;
}
