// C2 batch B1b (reviewer's ruling 2026-10-24 17:46): items 5 + 18 (the press column as a
// SERIES, per Q1), 4a (the field export, with the seam share) and 26 (grams per face and
// per include region). Red first.
//
//  5     a press with a FLAT PRISM ("flat_prism": {"apex_mm"}, the plane dot(p − A, d) = h,
//        h = deepest_squish_mm, d = press_direction) owns only its prism: the field carries the
//        press's ρ only where dot(p − A, d) ≤ h; past the plane a voxel goes to the next owner.
//  18    the press is designed as a SERIES column (Q1): its own segment (the run inside the
//        prism, plus run nobody else owns) at the ρ it solves for, the rest of the run at the
//        other owners' designed ρ, all at one stress: depth = L_own·ε(p; ρ_own) + Σ Lᵢ·ε(p; ρᵢ).
//        With no other segment, the design is exactly the single-ρ one.
//  4a    `topopt-cli flexible` writes flexible_field.json + flexible_field.bin: the assigned
//        field (ρ, owner, weight, runner-up), the FILLED field (the app's flood rule), the seam
//        share at each press plane (the app's pressSeam rule) and each press's footprint boundary.
//  26    grams per face (per owner, on the clipped field) and per include region.

#include "topopt/flexible/data.hpp"
#include "topopt/flexible/faces.hpp"
#include "topopt/flexible/field.hpp"
#include "topopt/flexible/job_block.hpp"
#include "topopt/flexible/run.hpp"
#include "topopt/flexible/squish.hpp"
#include "topopt/face_overrides.hpp"
#include "topopt/job.hpp"
#include "topopt/stl.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#include "flexible_test_boxes.hpp"

using namespace topopt;
using namespace topopt::flexible;
using flexible_test::box;
using flexible_test::one_region_per_face;
using flexible_test::region;
namespace fs = std::filesystem;

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

static_assert(kPressApiVersion == 4, "B1b: the press API version");

static const FlexibleData& data() {
  static const FlexibleData d = load_flexible_data(FLEXIBLE_MATERIALS_JSON_PATH);
  return d;
}
static CurveSet set220() { return curve_set(data(), "varioshore_tpu", 220, "gyroid").set; }

// ── 18: the series design, on one stack ─────────────────────────────────────────
static void test_series_math() {
  const StepModel m = box(40, 40, 20);
  const VoxelGrid g = voxelize(m.mesh, 40, VoxelTies::Watertight);
  const std::vector<ResolvedFaceRegion> rs = resolve_face_regions(m, one_region_per_face());
  std::vector<char> lat(g.voxel_count(), 0);
  for (std::size_t i = 0; i < lat.size(); ++i) lat[i] = g.tags[i] != VoxelTag::Empty;
  const Stack st = build_stack(m, region(rs, 101), rs, g, lat, 0, {0, 0, 1}, 2.0);
  const CurveSet s = set220();
  const BuildParams bp{"gyroid", 1, 0.42};
  const TierBand tb = tier_band(data().catalogue.error_bands, s.tier, false, 1);
  SquishMap mp;
  mp.mode = "both";
  mp.x_x = mp.y_x = {0, 1};
  mp.x_y = mp.y_y = {1, 1};
  mp.deepest_squish_mm = 3;
  const FaceDesign one = design_face(s, st, mp, 300, nullptr, bp, tb);
  // (1) CONSISTENCY: the same column split into an own half and a FIXED half at the single-ρ
  // design's own density must solve to that same density.
  std::vector<SeriesColumn> half(st.columns.size());
  for (std::size_t k = 0; k < st.columns.size(); ++k) {
    half[k].own_mm = 0.5 * st.columns[k].lattice_mm;
    half[k].fixed.push_back({0.5 * st.columns[k].lattice_mm, one.columns[k].target_density});
  }
  const FaceDesign two = design_face(s, st, mp, 300, nullptr, bp, tb, &half);
  double worst = 0.0;
  for (std::size_t k = 0; k < st.columns.size(); ++k)
    if (one.columns[k].status == "ok")
      worst = std::max(worst, std::fabs(two.columns[k].target_density - one.columns[k].target_density));
  std::printf("  series consistency: worst |rho_own - rho_single| = %.3g\n", worst);
  CHECK(one.ok > 0 && two.ok == one.ok && worst < 1e-6,
        "18: a column split into own + fixed at the same rho solves to the same rho");
  // (2) THE SERIES FORMULA: buildable depth = L_own·ε(p; ρ_own) + Σ L·ε(p; ρ_fixed).
  std::vector<SeriesColumn> firm(st.columns.size());
  const double rho_f = 0.30;
  for (std::size_t k = 0; k < st.columns.size(); ++k) {
    firm[k].own_mm = 0.25 * st.columns[k].lattice_mm;
    firm[k].fixed.push_back({0.75 * st.columns[k].lattice_mm, rho_f});
  }
  const FaceDesign three = design_face(s, st, mp, 300, nullptr, bp, tb, &firm);
  double err = 0.0;
  int checked = 0;
  for (std::size_t k = 0; k < st.columns.size(); ++k) {
    const ColumnDesign& c = three.columns[k];
    if (!c.buildable_ok) continue;
    const StrainResult eo = strain_under(s, c.pressure_mpa, c.buildable_density);
    const StrainResult ef = strain_under(s, c.pressure_mpa, rho_f);
    if (!eo.ok || !ef.ok) continue;
    const double expect = firm[k].own_mm * eo.strain + firm[k].fixed[0].length_mm * ef.strain;
    err = std::max(err, std::fabs(c.buildable_depth_mm - expect));
    ++checked;
  }
  std::printf("  series formula: %d columns, worst error %.3g mm\n", checked, err);
  CHECK(checked > 0 && err < 1e-9, "18: the buildable depth is the series sum");
  CHECK(three.columns[0].own_length_mm == firm[0].own_mm &&
            std::fabs(three.columns[0].height_mm - st.columns[0].lattice_mm) < 1e-12,
        "18: the column reports its own length; its height is the whole run");
  // (3) the fixed part alone squishes deeper than the target: even the firmest own segment
  // cannot meet it -> too_soft. The single-ρ design at the same target is the CONTROL: it can.
  // A light load (50 N) keeps the softest row inside the data; the target sits a quarter of the
  // way into the single-ρ reachable strain range; the fixed 75 % is at the softest row.
  {
    const double W = 50.0, p = W / st.footprint_area_mm2;
    const StrainResult lo = strain_under(s, p, s.density_max()), hi = strain_under(s, p, s.density_min());
    const double L = st.columns[0].lattice_mm;
    const double t = lo.strain + 0.25 * (hi.strain - lo.strain);
    std::vector<SeriesColumn> sf(st.columns.size());
    for (std::size_t k = 0; k < st.columns.size(); ++k) {
      sf[k].own_mm = 0.25 * st.columns[k].lattice_mm;
      sf[k].fixed.push_back({0.75 * st.columns[k].lattice_mm, s.density_min()});
    }
    SquishMap shallow = mp;
    shallow.deepest_squish_mm = t * L;
    const FaceDesign single = design_face(s, st, shallow, W, nullptr, bp, tb);
    const FaceDesign four = design_face(s, st, shallow, W, nullptr, bp, tb, &sf);
    std::printf("  too_soft: strains %.4f..%.4f, target %.4f mm, fixed depth %.4f mm; single ok %d, series too_soft %d of %zu\n",
                lo.strain, hi.strain, t * L, 0.75 * L * hi.strain, single.ok, four.too_soft, st.columns.size());
    CHECK(lo.ok && hi.ok && single.ok == static_cast<int>(st.columns.size()) &&
              four.too_soft == static_cast<int>(st.columns.size()),
          "18: when the fixed segments alone squish past the target, the column is too_soft (single-rho: ok)");
  }
}

// ── the run: 5 + 18 + 4a + 26 on a cube ────────────────────────────────────────────
static const std::string kDir = std::string(FLEXIBLE_TMP_DIR) + "/flexible_b1b_test";

static std::string read(const std::string& p) {
  std::ifstream in(p, std::ios::binary);
  std::ostringstream s;
  s << in.rdbuf();
  return s.str();
}

struct Field {
  int nx = 0, ny = 0, nz = 0;
  double h = 0, ox = 0, oy = 0, oz = 0;
  std::map<std::string, std::vector<float>> f;
  std::map<std::string, std::vector<std::int32_t>> i;
};

// A minimal reader for the exported field: the header's numbers by key, the arrays by offset.
static double num(const std::string& j, const std::string& key, std::size_t from = 0) {
  const std::size_t p = j.find("\"" + key + "\"", from);
  if (p == std::string::npos) return std::nan("");
  return std::atof(j.c_str() + j.find(':', p) + 1);
}
static Field read_field(const std::string& dir) {
  Field F;
  const std::string j = read(dir + "/flexible_field.json");
  const std::string b = read(dir + "/flexible_field.bin");
  F.nx = static_cast<int>(num(j, "nx"));
  F.ny = static_cast<int>(num(j, "ny"));
  F.nz = static_cast<int>(num(j, "nz"));
  F.h = num(j, "spacing_mm");
  const std::size_t o = j.find("\"origin_mm\"");
  if (o != std::string::npos) std::sscanf(j.c_str() + j.find('[', o), "[%lf, %lf, %lf]", &F.ox, &F.oy, &F.oz);
  const std::size_t n = static_cast<std::size_t>(F.nx) * F.ny * F.nz;
  for (const char* name : {"density", "owner_weight", "filled_density", "seam_side", "seam_across"}) {
    const std::size_t p = j.find(std::string("\"name\": \"") + name + "\"");
    if (p == std::string::npos) continue;
    const std::size_t off = static_cast<std::size_t>(num(j, "offset", p));
    std::vector<float> v(n);
    if (off + n * 4 <= b.size()) std::memcpy(v.data(), b.data() + off, n * 4);
    F.f[name] = v;
  }
  for (const char* name : {"owner", "runner_up", "filled_owner"}) {
    const std::size_t p = j.find(std::string("\"name\": \"") + name + "\"");
    if (p == std::string::npos) continue;
    const std::size_t off = static_cast<std::size_t>(num(j, "offset", p));
    std::vector<std::int32_t> v(n);
    if (off + n * 4 <= b.size()) std::memcpy(v.data(), b.data() + off, n * 4);
    F.i[name] = v;
  }
  return F;
}

// The cube: the top's x < 51.5 loaded straight down; the vertical +X/top EDGE pressed along
// (−1, 0, −1)/√2 with a flat prism 6 mm past its apex (60, 0, 60): the plane cuts the top at
// x = 60 − 6√2 and the right face at z = 60 − 6√2, so the press's pieces are those two sectors.
static std::string cube_job(bool with_prism) {
  const double c = 60.0 - 6.0 * std::sqrt(2.0);
  char cut[512];
  std::snprintf(cut, sizeof(cut),
                "{\"id\":201,\"add\":[1],\"cuts\":[{\"point\":[%.17g,0,0],\"normal\":[1,0,0]}]},"
                "{\"id\":203,\"add\":[3],\"cuts\":[{\"point\":[0,0,%.17g],\"normal\":[0,0,1]}]},"
                "{\"id\":211,\"add\":[1],\"cuts\":[{\"point\":[%.17g,0,0],\"normal\":[-1,0,0],\"strict\":true}]}",
                c, c, c);
  std::string fr;
  for (int f = 0; f < 6; ++f) fr += "{\"id\":" + std::to_string(100 + f) + ",\"add\":[" + std::to_string(f) + "]},";
  const std::string press = std::string("{\"face_region_ids\":[201,203],\"press_direction\":[-1,0,-1],") +
                            (with_prism ? "\"flat_prism\":{\"apex_mm\":[60,0,60]}," : "") +
                            "\"role\":\"loaded\",\"weight_n\":60,\"deepest_squish_mm\":6,\"mode\":\"both\","
                            "\"curve_x\":[[0,1],[1,1]],\"curve_y\":[[0,1],[1,1]],\"skin_on\":true}";
  const std::string top = "{\"face_region_id\":211,\"role\":\"loaded\",\"weight_n\":100,\"deepest_squish_mm\":2,"
                          "\"mode\":\"both\",\"curve_x\":[[0,1],[1,1]],\"curve_y\":[[0,1],[1,1]],\"skin_on\":true}";
  return "{\"model\":\"cube.stl\",\"material\":\"varioshore_tpu\",\"mode\":\"analyze\",\"resolution\":30,"
         "\"output\":{\"report\":\"r.json\",\"mesh_format\":\"stl\",\"mesh_prefix\":\"v\"},"
         "\"loads\":{\"face_regions\":[" + fr + cut + "]},"
         "\"flexible\":{\"material_id\":\"varioshore_tpu\",\"nozzle_temp_c\":220,\"topology\":\"gyroid\","
         "\"feel\":\"springy\",\"beads_per_wall\":1,\"min_extrudable_width_mm\":0.42,"
         "\"faces\":[" + top + "," + press + "]}}";
}

static FlexibleRunResult run(const std::string& name, const std::string& text) {
  const std::string dir = kDir + "/" + name;
  fs::create_directories(dir);
  write_stl_file(dir + "/cube.stl", box(60, 60, 60).mesh);
  return run_flexible_job(parse_job(text), dir, dir + "/out", FLEXIBLE_MATERIALS_JSON_PATH,
                          FlexibleProvenance{"test", "test", "now"});
}

static void test_run() {
  std::error_code ec;
  fs::remove_all(kDir, ec);
  const FlexibleRunResult r = run("prism", cube_job(true));
  const FlexibleRunResult u = run("whole", cube_job(false));  // the CONTROL: no flat prism
  CHECK(!r.refused && !u.refused, "the cube runs, with and without the flat prism");
  if (r.refused) std::fprintf(stderr, "  (%s: %s)\n", r.refusal_code.c_str(), r.refusal_reason.c_str());
  const double h = 6.0;
  const Vec3 A{60, 0, 60};
  const double rt = 1.0 / std::sqrt(2.0);
  auto height = [&](double x, double y, double z) { return -(x - A.x) * rt - (z - A.z) * rt + 0.0 * y; };

  // 5 + 4a: in the EXPORTED field, no voxel the press owns lies past its plane.
  for (int pass = 0; pass < 2; ++pass) {
    const Field F = read_field(kDir + (pass == 0 ? "/prism/out" : "/whole/out"));
    long long owned = 0, past = 0;
    const std::vector<std::int32_t>& own = F.i.count("owner") ? F.i.at("owner") : std::vector<std::int32_t>{};
    for (std::size_t v = 0; v < own.size(); ++v) {
      if (own[v] != 201) continue;
      ++owned;
      const int i = static_cast<int>(v % F.nx), j = static_cast<int>((v / F.nx) % F.ny),
                k = static_cast<int>(v / (static_cast<std::size_t>(F.nx) * F.ny));
      if (height(F.ox + (i + 0.5) * F.h, F.oy + (j + 0.5) * F.h, F.oz + (k + 0.5) * F.h) > h + 1e-9) ++past;
    }
    std::printf("  %s: the press owns %lld voxels, %lld past its plane\n", pass == 0 ? "flat prism" : "CONTROL (none)",
                owned, past);
    if (pass == 0)
      CHECK(F.nx > 0 && owned > 0 && past == 0, "5/4a: 0 press-field voxels past the flat prism in the exported field");
    else
      CHECK(past > 0, "5/4a: the CONTROL (no flat prism) owns voxels past the plane, so the check can see one");
  }

  // 18: the press is a SERIES column: own length = the run inside the prism (plus unowned run),
  // the rest at the top face's designed density; the depth is the series sum.
  const Stack* press = nullptr;
  for (const Stack& s : r.stacks)
    if (s.face_region_id == 201) press = &s;
  CHECK(press != nullptr && press->has_flat_prism && std::fabs(press->flat_depth_mm - h) < 1e-12,
        "5: the press's stack carries its flat prism (apex, depth = deepest_squish_mm)");
  CHECK(r.receipt_json.find("\"flat_prism\": {\"apex_mm\": [60, 0, 60], \"depth_mm\": 6") != std::string::npos,
        "5: the receipt names the flat prism");
  CHECK(r.receipt_json.find("\"series_columns\"") != std::string::npos,
        "18: the receipt counts the press's series columns");

  // 4a: the export's other arrays.
  {
    Field F = read_field(kDir + "/prism/out");
    const std::vector<float>& d = F.f["density"];
    const std::vector<float>& fd = F.f["filled_density"];
    const std::vector<float>& side = F.f["seam_side"];
    long long unfilled = 0, lattice = 0;
    for (std::size_t v = 0; v < d.size() && v < fd.size(); ++v) {
      if (d[v] < -0.5f) continue;
      ++lattice;
      if (!(fd[v] > 0.0f)) ++unfilled;
    }
    CHECK(lattice > 0 && unfilled == 0, "4a: the FILLED field has a density on every lattice voxel (the app's flood)");
    bool side_ok = side.size() == d.size(), in1 = false, out0 = false;
    for (std::size_t v = 0; side_ok && v < side.size(); ++v) {
      if (side[v] < 0.0f || side[v] > 1.0f) side_ok = false;
      const int i = static_cast<int>(v % F.nx), j = static_cast<int>((v / F.nx) % F.ny),
                k = static_cast<int>(v / (static_cast<std::size_t>(F.nx) * F.ny));
      const double hv = height(F.ox + (i + 0.5) * F.h, F.oy + (j + 0.5) * F.h, F.oz + (k + 0.5) * F.h);
      // "well inside" = more than the ramp (1 voxel) inside the plane: the share saturates at 1
      if (F.i["filled_owner"][v] == 201 && hv < h - 1.5 * F.h && hv > 0 && side[v] == 1.0f) in1 = true;
      if (hv > h + 3 * F.h && side[v] == 0.0f) out0 = true;
    }
    CHECK(side_ok && in1 && out0, "4a: the seam share is 1 well inside the press, 0 well past its plane, in [0, 1]");
    const std::string hj = read(kDir + "/prism/out/flexible_field.json");
    CHECK(hj.find("\"footprint_boundary\"") != std::string::npos && hj.find("\"filled_rule\"") != std::string::npos,
          "4a: the header carries each press's footprint boundary and names the fill rule");
  }

  // 26: grams per face, on the clipped field, and their total.
  {
    const std::string& j = r.receipt_json;
    const std::size_t g = j.find("\"grams\": {");
    CHECK(g != std::string::npos, "26: the receipt has a grams block");
    const double total = num(j, "total_g", g);
    const double f211 = num(j, "face_211_g", g), f201 = num(j, "face_201_g", g);
    std::printf("  grams: face 211 %.3f, press 201 %.3f, total %.3f\n", f211, f201, total);
    CHECK(f211 > 0 && f201 > 0 && std::fabs(f211 + f201 - total) < 1e-6 * total,
          "26: grams per face are > 0 and sum to the total");
  }
}

// ── 26: grams per include region ─────────────────────────────────────────────────
static void test_region_grams() {
  const std::string dir = std::string(FLEXIBLE_FIXTURE_DIR) + "/his_pad_1021";
  const StepModel pad = import_part_file_resolved(dir + "/model.stl");
  int top = -1;
  for (int f = 0; f < pad.face_count; ++f)
    if (pad.faces[static_cast<std::size_t>(f)].plane_normal.z > 0.99) top = f;
  std::string fr;
  for (int f = 0; f < 6; ++f) fr += "{\"id\":" + std::to_string(100 + f) + ",\"add\":[" + std::to_string(f) + "]},";
  fr += "{\"id\":120,\"add\":[" + std::to_string(top) + "],\"cuts\":[{\"point\":[50,0,0],\"normal\":[-1,0,0],\"strict\":true}]}";
  const std::string job =
      "{\"model\":\"model.stl\",\"material\":\"varioshore_tpu\",\"mode\":\"analyze\",\"resolution\":50,"
      "\"output\":{\"report\":\"r.json\",\"mesh_format\":\"stl\",\"mesh_prefix\":\"v\"},"
      "\"loads\":{\"face_regions\":[" + fr + "]},"
      "\"flexible\":{\"material_id\":\"varioshore_tpu\",\"nozzle_temp_c\":220,\"topology\":\"gyroid\","
      "\"feel\":\"springy\",\"beads_per_wall\":1,\"min_extrudable_width_mm\":0.42,"
      "\"regions\":[{\"role\":\"include\",\"kind\":\"region\",\"region_id\":120,\"geometry\":{\"depth_mm\":20}}],"
      "\"faces\":[{\"face_region_id\":" + std::to_string(100 + top) +
      ",\"role\":\"loaded\",\"weight_n\":100,\"deepest_squish_mm\":2,\"mode\":\"both\","
      "\"curve_x\":[[0,1],[1,1]],\"curve_y\":[[0,1],[1,1]],\"skin_on\":true}]}}";
  const FlexibleRunResult r = run_flexible_job(parse_job(job), dir, kDir + "/region_grams", FLEXIBLE_MATERIALS_JSON_PATH,
                                               FlexibleProvenance{"test", "test", "now"});
  const std::size_t g = r.receipt_json.find("\"grams\": {");
  const double reg = num(r.receipt_json, "region_0_g", g), total = num(r.receipt_json, "total_g", g);
  std::printf("  region grams: region 0 %.3f of %.3f total\n", reg, total);
  CHECK(!r.refused && reg > 0 && std::fabs(reg - total) < 1e-6 * total,
        "26: the one include region's grams are the lattice's (> 0)");
}

int main() {
  std::setvbuf(stdout, nullptr, _IONBF, 0);
  test_series_math();
  test_run();
  test_region_grams();
  std::printf("test_flexible_b1b: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
