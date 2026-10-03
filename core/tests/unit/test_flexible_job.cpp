// F11 of task 2026-09-28-flexible-squish-maths: the `flexible` job block — strict
// parsing, the refusals, the lattice-region re-parse, and the Flexible region mask.

#include "topopt/flexible/job_block.hpp"

#include <cstdio>
#include <functional>
#include <string>
#include <vector>

#include "flexible_test_boxes.hpp"

using namespace topopt;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                            \
  do {                                                              \
    ++g_checks;                                                     \
    if (!(cond)) {                                                  \
      ++g_failures;                                                 \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg);  \
    }                                                               \
  } while (0)

static std::string replace(std::string s, const std::string& a, const std::string& b) {
  const std::size_t at = s.find(a);
  if (at == std::string::npos) {
    std::fprintf(stderr, "test setup: \"%s\" not found\n", a.c_str());
    return s;
  }
  return s.replace(at, a.size(), b);
}

static const std::string kFace =
    "{\"face_region_id\":101,\"role\":\"loaded\",\"weight_n\":294.3,"
    "\"deepest_squish_mm\":4,\"mode\":\"both\",\"curve_x\":[[0,0.2],[0.5,1],[1,0.2]],"
    "\"curve_y\":[[0,0.2],[0.5,1],[1,0.2]],\"skin_on\":true}";
static const std::string kStamp =
    "{\"name\":\"sq\",\"mode\":\"soft\",\"force_n\":8,\"origin_mm\":[30,30],\"cell_mm\":10,"
    "\"nu\":2,\"nv\":2,\"values_mpa\":[0.02,0.02,0.02,0.02]}";

static std::string job(const std::string& flex_body, const std::string& extra = "",
                       const std::string& material = "varioshore_tpu") {
  return "{\"model\":\"pad.stl\",\"material\":\"" + material +
         "\",\"mode\":\"analyze\",\"output\":{\"report\":\"report.json\",\"mesh_format\":\"stl\",\"mesh_prefix\":\"v\"},\"resolution\":100,"
         "\"loads\":{\"face_regions\":["
         "{\"id\":100,\"add\":[0]},{\"id\":101,\"add\":[1]},{\"id\":103,\"add\":[3]}]}," +
         extra + "\"flexible\":{" + flex_body + "}}";
}

static std::string body(const std::string& faces = "[" + kFace + "]",
                        const std::string& extra = "") {
  return "\"material_id\":\"varioshore_tpu\",\"nozzle_temp_c\":220,\"topology\":\"auto\","
         "\"feel\":\"springy\",\"beads_per_wall\":1,\"min_extrudable_width_mm\":0.42,"
         "\"faces\":" + faces + extra;
}

static bool refused(const std::string& text, const char* needle) {
  try {
    parse_job(text);
  } catch (const JobError& e) {
    if (std::string(e.what()).find(needle) == std::string::npos) {
      std::fprintf(stderr, "  (message was: %s)\n", e.what());
      return false;
    }
    return true;
  } catch (const std::exception& e) {
    std::fprintf(stderr, "  (wrong exception: %s)\n", e.what());
    return false;
  }
  std::fprintf(stderr, "  (accepted)\n");
  return false;
}

static void test_parse() {
  const JobDescription j = parse_job(job(body("[" + kFace + ",{\"face_region_id\":100,"
                                                        "\"role\":\"resting\",\"skin_on\":false}]",
                                              ",\"check_stamps\":[" +
                                                  replace(kStamp, "{", "{\"face_region_id\":101,") +
                                                  "]")));
  CHECK(j.flexible != nullptr, "the block is parsed");
  const JobFlexible& f = *j.flexible;
  CHECK(f.material_id == "varioshore_tpu" && !f.nozzle_temp_auto && f.nozzle_temp_c == 220 &&
            f.topology == "auto" && f.feel == "springy" && f.beads_per_wall == 1 &&
            f.min_extrudable_width_mm == 0.42,
        "scalars");
  CHECK(f.faces.size() == 2 && f.faces[0].role == "loaded" && f.faces[1].role == "resting" &&
            !f.faces[1].skin_on,
        "faces and roles");
  CHECK(f.faces[0].curve_x_x.size() == 3 && f.faces[0].curve_x_y[1] == 1.0 &&
            f.faces[0].frame_rotation_deg == 0 && !f.faces[0].has_design_stamp,
        "curves and defaults");
  CHECK(f.check_stamps.size() == 1 && f.check_stamps[0].stamp.nu == 2 &&
            f.check_stamps[0].face_region_id == 101,
        "check stamps");
  const flexible::SquishMap m = squish_map_of(f.faces[0]);
  CHECK(m.mode == "both" && m.deepest_squish_mm == 4 && m.y_y.size() == 3, "squish_map_of");

  CHECK(parse_job("{\"model\":\"pad.stl\",\"material\":\"varioshore_tpu\",\"mode\":\"analyze\",\"output\":{\"report\":\"report.json\",\"mesh_format\":\"stl\",\"mesh_prefix\":\"v\"},"
                  "\"resolution\":100,\"loads\":{"
                  "\"face_regions\":[{\"id\":101,\"add\":[1]}]}}")
                .flexible == nullptr,
        "no block: the member stays null");

  const JobDescription a = parse_job(job(replace(body(), "\"nozzle_temp_c\":220",
                                                 "\"nozzle_temp_c\":\"auto\"")));
  CHECK(a.flexible->nozzle_temp_auto, "nozzle_temp_c \"auto\"");
  const JobDescription d =
      parse_job(job(body("[" + replace(kFace, "\"skin_on\":true",
                                       "\"skin_on\":true,\"frame_rotation_deg\":270,"
                                       "\"design_stamp\":" + kStamp) + "]")));
  CHECK(d.flexible->faces[0].has_design_stamp && d.flexible->faces[0].frame_rotation_deg == 270,
        "design stamp and rotation");
  const JobDescription c = parse_job(job(body(
      "[" + replace(replace(kFace, "\"mode\":\"both\"", "\"mode\":\"centre_edge\""),
                    "\"curve_x\":[[0,0.2],[0.5,1],[1,0.2]],\"curve_y\":[[0,0.2],[0.5,1],[1,0.2]]",
                    "\"curve_centre_edge\":[[0,0],[1,1]]") + "]")));
  CHECK(c.flexible->faces[0].curve_c_x.size() == 2, "centre_edge curve");
}

static void test_refusals() {
  CHECK(refused(job(body(), "\"lattice\":{\"cell_mm\":5,\"strut_radius_mm\":0.5},"), "not both"),
        "flexible + lattice refused");
  CHECK(refused(job(body() + ",\"colour\":1"), "unknown key \"colour\""), "unknown block key");
  CHECK(refused(job(body("[" + replace(kFace, "\"skin_on\":true", "\"skin_on\":true,\"q\":1") + "]")),
                "unknown key \"q\""),
        "unknown face key");
  CHECK(refused(job(replace(body(), "\"feel\":\"springy\",", "")), "missing required key \"feel\""),
        "missing feel");
  CHECK(refused(job(body(), "", "PLA"), "differs from the job's"), "material mismatch");
  CHECK(refused(job(replace(body(), "\"nozzle_temp_c\":220", "\"nozzle_temp_c\":\"hot\"")),
                "nozzle_temp_c"),
        "a non-auto string temperature");
  CHECK(refused(job(replace(body(), "\"topology\":\"auto\"", "\"topology\":\"octet\"")), "topology"),
        "octet topology");
  CHECK(refused(job(replace(body(), "\"beads_per_wall\":1", "\"beads_per_wall\":3")), "beads_per_wall"),
        "3 beads");
  CHECK(refused(job(replace(body(), "\"min_extrudable_width_mm\":0.42", "\"min_extrudable_width_mm\":0")),
                "min_extrudable_width_mm"),
        "zero bead width");
  CHECK(refused(job(body("[" + replace(kFace, "\"mode\":\"both\"", "\"mode\":\"diagonal\"") + "]")),
                "mode"),
        "bad mode");
  CHECK(refused(job(body("[" + replace(kFace, ",\"curve_y\":[[0,0.2],[0.5,1],[1,0.2]]", "") + "]")),
                "missing required key \"curve_y\""),
        "both without curve_y");
  CHECK(refused(job(body("[" + replace(kFace, "[[0,0.2],[0.5,1],[1,0.2]]", "[[0,0.2],[0.6,1],[0.5,0.2],[1,0]]") + "]")),
                "strictly increasing"),
        "a bad pen curve");
  CHECK(refused(job(body("[" + replace(kFace, "101", "999") + "]")), "not declared"),
        "an undeclared face region");
  CHECK(refused(job(body("[" + kFace + "," + kFace + "]")), "appears twice"), "a duplicated face");
  CHECK(refused(job(body("[{\"face_region_id\":100,\"role\":\"resting\",\"skin_on\":true}]")),
                "at least one \"loaded\""),
        "no loaded face");
  CHECK(refused(job(body("[{\"face_region_id\":100,\"role\":\"resting\",\"skin_on\":true,"
                         "\"weight_n\":3}," + kFace + "]")),
                "unknown key \"weight_n\""),
        "a resting face takes no load");
  CHECK(refused(job(body("[" + replace(kFace, "\"skin_on\":true", "\"skin_on\":true,\"frame_rotation_deg\":45") + "]")),
                "0, 90, 180 or 270"),
        "a 45 degree rotation");
  CHECK(refused(job(body("[" + replace(kFace, "\"weight_n\":294.3", "\"weight_n\":0") + "]")), "weight_n"),
        "zero weight");
  CHECK(refused(job(body("[" + replace(kFace, ",\"skin_on\":true", "") + "]")), "skin_on"),
        "skin_on is required");
  CHECK(refused(job(body("[" + replace(kFace, "\"skin_on\":true", "\"skin_on\":true,\"design_stamp\":" +
                                           replace(kStamp, "\"force_n\":8", "\"force_n\":8.1")) + "]")),
                "0.5 %"),
        "a stamp whose cells do not add up to its force");
  CHECK(refused(job(body("[" + kFace + ",{\"face_region_id\":100,\"role\":\"resting\",\"skin_on\":true}]",
                         ",\"check_stamps\":[" + replace(kStamp, "{", "{\"face_region_id\":100,") + "]")),
                "not a loaded face"),
        "a check stamp on a resting face");
  // Regions: parsed by the lattice parser itself.
  const JobDescription r = parse_job(job(body("[" + kFace + "]",
      ",\"regions\":[{\"role\":\"include\",\"kind\":\"region\",\"region_id\":101,"
      "\"geometry\":{\"depth_mm\":10}}]")));
  CHECK(r.flexible->regions.size() == 1 && r.flexible->regions[0].kind == "region" &&
            r.flexible->regions[0].region_id == 101 && r.flexible->regions[0].depth_mm == 10 &&
            !r.lattice.present,
        "a region lattice region, and the job still has no lattice");
  CHECK(refused(job(body("[" + kFace + "]", ",\"regions\":[{\"role\":\"inside\",\"kind\":\"region\","
                                             "\"region_id\":101,\"geometry\":{\"depth_mm\":10}}]")),
                "flexible.regions"),
        "a bad region role is refused by the lattice parser, named as flexible.regions");
  CHECK(refused(job(body("[" + kFace + "]", ",\"regions\":[{\"role\":\"include\",\"kind\":\"region\","
                                             "\"region_id\":101,\"relative_density\":0.3,"
                                             "\"geometry\":{\"depth_mm\":10}}]")),
                "squish map"),
        "relative_density belongs to the other stages");
}

static void test_region_mask() {
  StepModel m = flexible_test::box(100, 100, 20);
  const VoxelGrid g = voxelize(m.mesh, 50);  // 2 mm
  JobDescription j = parse_job(job(body()));
  j.loads.face_regions = flexible_test::one_region_per_face();
  std::vector<char> mask = flexible_region_mask(j, m, g);
  std::size_t n = 0;
  for (char c : mask) n += c ? 1 : 0;
  CHECK(n == g.solid_count(), "no regions: the whole part is the lattice region");
  j = parse_job(job(body("[" + kFace + "]", ",\"regions\":[{\"role\":\"include\",\"kind\":\"region\","
                                             "\"region_id\":101,\"geometry\":{\"depth_mm\":10}}]")));
  j.loads.face_regions = flexible_test::one_region_per_face();
  mask = flexible_region_mask(j, m, g);
  bool top_only = true;
  n = 0;
  for (int k = 0; k < g.nz; ++k)
    for (int jj = 0; jj < g.ny; ++jj)
      for (int i = 0; i < g.nx; ++i)
        if (mask[g.index(i, jj, k)]) {
          ++n;
          if (g.voxel_center(i, jj, k).z < 10.0) top_only = false;
        }
  CHECK(top_only && n == g.solid_count() / 2, "a 10 mm region under the top: the top half only");
}

int main() {
  test_parse();
  test_refusals();
  test_region_mask();
  std::printf("test_flexible_job: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
