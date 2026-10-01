// F1 + F2 of task 2026-09-28-flexible-squish-maths: the strict loaders for the
// maintainer's Flexible data, and the nominal-infill -> printed-core density axis.
//
// The live files are read through FLEXIBLE_MATERIALS_JSON_PATH (never written).
// Every negative case is a small inline document: tests/fixtures/** is untouched.

#include "topopt/flexible/data.hpp"
#include "topopt/flexible/squish.hpp"

#include <cmath>
#include <cstdio>
#include <functional>
#include <stdexcept>
#include <string>

using namespace topopt::flexible;

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

static bool throws(const std::function<void()>& f, const char* needle = nullptr) {
  try {
    f();
  } catch (const FlexibleError& e) {
    if (needle && std::string(e.what()).find(needle) == std::string::npos) {
      std::fprintf(stderr, "  (message was: %s)\n", e.what());
      return false;
    }
    return true;
  } catch (...) {
    return false;
  }
  return false;
}

// ── inline catalogue builder ─────────────────────────────────────────────────────
static const char* kMaterialBody =
    "\"display_name\":\"Test TPU\",\"family\":\"tpu\",\"shore_a_nominal\":92,"
    "\"foaming\":true,\"tier\":\"literature\",\"offered_nozzle_temps_c\":[190,220],"
    "\"nozzle_temp_range_c\":[195,260],\"bed_temp_c\":null,\"speed_mm_s\":null,"
    "\"retraction\":null,\"drying\":null,\"ams_compatible\":false,"
    "\"solid_density_g_cm3\":1.2,\"solid_youngs_modulus_mpa\":null,"
    "\"squish_tables\":[\"t.json\"],\"sources\":[\"x\"]";

static std::string catalogue(const std::string& material_body = kMaterialBody,
                             const std::string& extra_top = "",
                             const std::string& bands =
                                 "{\"status\":\"s\",\"literature_same_material\":0.4,"
                                 "\"calibrated\":0.2,\"proxy\":0.5,\"note\":\"n\"}") {
  return "{\"schema_version\":1,\"status\":\"draft\","
         "\"tiers\":{\"literature\":\"a\",\"proxy_candidate\":\"b\",\"calibrate_first\":\"c\"},"
         "\"error_band_defaults\":" + bands + "," +
         "\"materials\":{\"tpu_x\":{" + material_body + "}}" + extra_top + "}";
}

// One curve entry; `loading` and `rd` are the fields most tests vary.
static std::string entry(const std::string& id, double temp, double rd,
                         const std::string& est, const std::string& loading =
                             "[[0.1,0.05],[0.2,0.08]]",
                         const std::string& extra = "",
                         const std::string& specimen =
                             "{\"shape\":\"cylinder\",\"diameter_mm\":29,\"height_mm\":12.5,"
                             "\"skin_total_mm\":1.6}") {
  char b[64];
  std::snprintf(b, sizeof(b), "%.17g", temp);
  std::string t = b;
  std::snprintf(b, sizeof(b), "%.17g", rd);
  return "{\"id\":\"" + id + "\",\"tier\":\"literature\",\"material_id\":\"tpu_x\","
         "\"nozzle_temp_c\":" + t + ",\"topology\":\"gyroid\","
         "\"geometry_source\":\"slicer_infill\",\"relative_density\":" + b + ","
         "\"relative_density_basis\":\"nominal_infill\",\"est_core_relative_density\":" +
         est + ",\"specimen\":" + specimen + ","
         "\"conditioning\":{\"cycle_reported\":4,\"rate_mm_per_min\":10},"
         "\"loading\":" + loading + ",\"strain_max_measured\":0.25,"
         "\"source\":\"iacob2024\"" + extra + "}";
}

static std::string table(const std::string& entries) {
  return "{\"schema_version\":1,\"entries\":[" + entries + "]}";
}

static std::string two_temp_table() {
  return table(entry("a10_190", 190, 0.10, "0.15") + "," +
               entry("a20_190", 190, 0.20, "0.25", "[[0.1,0.1],[0.2,0.15]]") + "," +
               entry("a10_220", 220, 0.10, "null", "[[0.1,0.02],[0.2,0.03]]") + "," +
               entry("a20_220", 220, 0.20, "null", "[[0.1,0.04],[0.2,0.06]]"));
}

static void test_live_files() {
  FlexibleData d = load_flexible_data(FLEXIBLE_MATERIALS_JSON_PATH);
  const MaterialCatalogue& c = d.catalogue;
  CHECK(c.schema_version == 1, "catalogue schema_version 1");
  CHECK(c.materials.size() == 10, "ten filaments in the live catalogue");
  CHECK(c.tiers.size() == 3, "three tier definitions");
  CHECK(c.error_bands.literature_same_material == 0.40, "literature band 0.40 as seeded");
  CHECK(c.error_bands.calibrated == 0.20, "calibrated band 0.20 as seeded");
  CHECK(c.error_bands.proxy == 0.50, "proxy band 0.50 as seeded");
  CHECK(d.tables.size() == 1 && d.tables[0].entries.size() == 36,
        "one table, 36 Iacob entries");
  const Material& v = c.materials.at("varioshore_tpu");
  CHECK(v.foaming && v.tier == "literature", "varioShore is foaming + literature");
  CHECK(v.offered_nozzle_temps_c.size() == 3 && v.offered_nozzle_temps_c[0] == 190 &&
            v.offered_nozzle_temps_c[1] == 220 && v.offered_nozzle_temps_c[2] == 240,
        "varioShore offers exactly 190/220/240");
  CHECK(v.flow_pct_at_temp.at(220) == 72, "flow at 220 read from the string key");
  // NULL MEANS UNKNOWN: nothing is substituted.
  CHECK(!v.drying.known, "varioShore drying is null -> unknown");
  CHECK(!v.retraction_known, "varioShore retraction is null -> unknown");
  CHECK(v.bed_temp_c.known && v.bed_temp_c.lo == 50 && v.bed_temp_c.hi == 60,
        "bed temp range read");
  const Material& t95 = c.materials.at("tpu95a_generic");
  CHECK(!t95.solid_youngs_modulus_mpa.known, "TPU95A modulus null -> unknown");
  CHECK(!t95.nozzle_temp_range_c.known, "TPU95A nozzle range null -> unknown");
  CHECK(!t95.ams_compatible_known, "TPU95A ams null -> unknown");
  CHECK(t95.solid_density_g_cm3.known && t95.solid_density_g_cm3.value == 1.21,
        "TPU95A density known");
  CHECK(t95.offered_nozzle_temps_c.empty(), "TPU95A offers no temperature");
  const Material& b = c.materials.at("bambu_tpu_for_ams");
  CHECK(!b.shore_a_nominal.known && b.shore_d_nominal.known &&
            b.shore_d_nominal.value == 68,
        "Bambu hard TPU: shore A unknown, shore D 68");
  CHECK(b.drying.known && b.drying.temp_c.lo == 70 && b.drying.hours.lo == 8,
        "scalar drying temp/hours read as a point range");
  const Material& e = c.materials.at("esun_tpu_lw");
  CHECK(e.drying.hours_min.known && e.drying.hours_min.value == 4, "hours_min read");
  CHECK(e.retraction_known && e.retraction == "off", "retraction string read");
  const CurveEntry& g = d.tables[0].entries[0];
  CHECK(g.id == "iacob2024_gyroid_10pct_190C" && g.loading.size() == 2 &&
            g.loading[0].strain == 0.1 && g.loading[0].stress_mpa == 0.042,
        "first Iacob entry read");
  CHECK(!g.beads_per_wall.known && !g.cell_mm.known && !g.has_unloading,
        "Iacob nulls stay unknown");
  CHECK(g.est_core_relative_density.known && g.est_core_relative_density.value == 0.143,
        "est core read");
}

static void test_catalogue_strictness() {
  CHECK(!throws([] { parse_material_catalogue(catalogue()); }), "inline catalogue is valid");
  // unknown keys at every level
  CHECK(throws([] { parse_material_catalogue(catalogue(kMaterialBody, ",\"extra\":1")); },
               "unknown key \"extra\""),
        "unknown top-level key rejected");
  CHECK(throws([] {
          parse_material_catalogue(catalogue(std::string(kMaterialBody) + ",\"colour\":\"red\""));
        }, "unknown key \"colour\""),
        "unknown material key rejected");
  CHECK(throws([] {
          parse_material_catalogue(catalogue(
              kMaterialBody, "",
              "{\"status\":\"s\",\"literature_same_material\":0.4,\"calibrated\":0.2,"
              "\"proxy\":0.5,\"note\":\"n\",\"estimated\":0.5}"));
        }, "unknown key \"estimated\""),
        "unknown error_band_defaults key rejected");
  {
    std::string body = kMaterialBody;
    body.replace(body.find("\"drying\":null"), 13, "\"drying\":{\"temp_c\":50,\"fan\":1}");
    CHECK(throws([&] { parse_material_catalogue(catalogue(body)); }, "unknown key \"fan\""),
          "unknown drying key rejected");
  }
  {
    std::string body = kMaterialBody;
    body.replace(body.find("\"solid_youngs_modulus_mpa\":null"), 31,
                 "\"solid_youngs_modulus_mpa\":{\"value\":50,\"condition\":\"x\",\"sd\":2}");
    CHECK(throws([&] { parse_material_catalogue(catalogue(body)); }, "unknown key \"sd\""),
          "unknown modulus key rejected");
  }
  // missing required keys
  {
    std::string body = kMaterialBody;
    body.replace(body.find("\"display_name\":\"Test TPU\","), 26, "");
    CHECK(throws([&] { parse_material_catalogue(catalogue(body)); },
                 "missing required key \"display_name\""),
          "missing display_name rejected");
  }
  {
    std::string body = kMaterialBody;
    body.replace(body.find("\"bed_temp_c\":null,"), 18, "");
    CHECK(throws([&] { parse_material_catalogue(catalogue(body)); },
                 "missing required key \"bed_temp_c\""),
          "a required-but-nullable key may not be omitted");
  }
  CHECK(throws([] {
          parse_material_catalogue(
              "{\"schema_version\":1,\"status\":\"s\",\"tiers\":{},\"materials\":{}}");
        }, "error_band_defaults"),
        "missing error_band_defaults rejected");
  // values
  {
    std::string body = kMaterialBody;
    body.replace(body.find("\"tier\":\"literature\""), 19, "\"tier\":\"guess\"");
    CHECK(throws([&] { parse_material_catalogue(catalogue(body)); }, "tier"),
          "an undefined tier is rejected");
  }
  {
    std::string body = kMaterialBody;
    body.replace(body.find("\"foaming\":true"), 14, "\"foaming\":\"yes\"");
    CHECK(throws([&] { parse_material_catalogue(catalogue(body)); }, "foaming"),
          "a non-boolean foaming is rejected");
  }
  {
    std::string body = kMaterialBody;
    body.replace(body.find("[195,260]"), 9, "[260,195]");
    CHECK(throws([&] { parse_material_catalogue(catalogue(body)); }, "nozzle_temp_range_c"),
          "a reversed range is rejected");
  }
  {
    std::string body = kMaterialBody;
    body.replace(body.find("[190,220]"), 9, "[220,190]");
    CHECK(throws([&] { parse_material_catalogue(catalogue(body)); },
                 "offered_nozzle_temps_c"),
          "offered temperatures must be strictly increasing");
  }
  CHECK(throws([] {
          parse_material_catalogue(catalogue(kMaterialBody, "",
                                             "{\"status\":\"s\",\"literature_same_material\":"
                                             "-0.4,\"calibrated\":0.2,\"proxy\":0.5,\"note\":\"n\"}"));
        }, "literature_same_material"),
        "a negative band is rejected");
  CHECK(throws([] {
          parse_material_catalogue("{\"schema_version\":1,\"schema_version\":1}");
        }, "duplicated key"),
        "a duplicated JSON key is rejected, not last-wins");
  CHECK(throws([] { parse_material_catalogue(std::string(100, '[') + std::string(100, ']')); }, "nesting"),
        "a pathologically nested document is refused, not a stack overflow");
  CHECK(throws([] { parse_material_catalogue("{\"schema_version\":1e400}"); }, "out of range"),
        "an out-of-range number is a FlexibleError, not a stray std::out_of_range");
}

static void test_curve_strictness() {
  CHECK(!throws([] { parse_curve_table(two_temp_table(), "t.json"); }),
        "inline table is valid");
  CHECK(throws([] { parse_curve_table("{\"schema_version\":2,\"entries\":[]}", "t.json"); },
               "schema_version"),
        "schema_version must be 1");
  CHECK(throws([] {
          parse_curve_table(table(entry("a", 190, 0.1, "0.1", "[[0.1,0.05],[0.2,0.08]]",
                                        ",\"colour\":1")), "t.json");
        }, "unknown key \"colour\""),
        "unknown entry key rejected");
  CHECK(throws([] {
          parse_curve_table(table(entry("a", 190, 0.1, "0.1", "[[0.1,0.05],[0.2,0.08]]", "",
                                        "{\"shape\":\"cylinder\",\"height_mm\":12.5,"
                                        "\"skin_total_mm\":1.6,\"wet\":true}")), "t.json");
        }, "unknown key \"wet\""),
        "unknown specimen key rejected");
  CHECK(throws([] {
          parse_curve_table(table(entry("a", 190, 0.1, "0.1", "[[0.1,0.05],[0.2,0.08]]", "",
                                        "{\"shape\":\"cylinder\",\"skin_total_mm\":1.6}")),
                            "t.json");
        }, "missing required key \"height_mm\""),
        "missing specimen height rejected");
  CHECK(throws([] {
          std::string e = entry("a", 190, 0.1, "0.1");
          e.replace(e.find("\"source\":\"iacob2024\""), 20, "\"x\":1");
          parse_curve_table(table(e), "t.json");
        }),
        "missing source rejected");
  // loading curves
  CHECK(throws([] {
          parse_curve_table(table(entry("a", 190, 0.1, "0.1", "[[0.1,0.08],[0.2,0.05]]")),
                            "t.json");
        }, "strictly increasing"),
        "stress decreasing along the curve is rejected");
  CHECK(throws([] {
          parse_curve_table(table(entry("a", 190, 0.1, "0.1", "[[0.2,0.05],[0.1,0.08]]")),
                            "t.json");
        }, "strictly increasing"),
        "strain decreasing is rejected");
  CHECK(throws([] {
          parse_curve_table(table(entry("a", 190, 0.1, "0.1", "[[0.1,0.05],[0.2,0.05]]")),
                            "t.json");
        }, "strictly increasing"),
        "a flat step is rejected (strictly)");
  CHECK(throws([] {
          parse_curve_table(table(entry("a", 190, 0.1, "0.1", "[[0.1,0.05]]")), "t.json");
        }, "loading"),
        "fewer than two loading points rejected");
  CHECK(throws([] {
          parse_curve_table(table(entry("a", 190, 0.1, "0.1", "[[0,0],[0.2,0.05]]")), "t.json");
        }, "loading"),
        "a loading strain of 0 is rejected (the origin is implied)");
  CHECK(throws([] {
          parse_curve_table(table(entry("a", 190, 0.1, "0.1", "[[0.1,0.05],[0.3,0.08]]")),
                            "t.json");
        }, "strain_max_measured"),
        "a loading point past strain_max_measured is rejected");
  // relative density
  CHECK(throws([] { parse_curve_table(table(entry("a", 190, 0.0, "0.1")), "t.json"); },
               "relative_density"),
        "relative_density 0 rejected");
  CHECK(throws([] { parse_curve_table(table(entry("a", 190, 1.2, "0.1")), "t.json"); },
               "relative_density"),
        "relative_density 1.2 rejected");
  CHECK(!throws([] { parse_curve_table(table(entry("a", 190, 1.0, "0.1")), "t.json"); }),
        "relative_density 1.0 accepted");
  CHECK(throws([] {
          std::string e = entry("a", 190, 0.1, "0.1");
          e.replace(e.find("\"topology\":\"gyroid\""), 19, "\"topology\":\"octet\"");
          parse_curve_table(table(e), "t.json");
        }, "topology"),
        "an unknown topology is rejected");
  CHECK(throws([] {
          parse_curve_table(table(entry("a", 190, 0.1, "0.1", "[[0.1,0.05],[0.2,0.08]]",
                                        ",\"beads_per_wall\":3")), "t.json");
        }, "beads_per_wall"),
        "beads_per_wall 3 rejected");
  for (const char* bad : {",\"rel_sd\":-0.3", ",\"replicates\":2.5", ",\"unloading\":[]",
                          ",\"bead_width_mm\":0", ",\"cell_mm\":-4"})
    CHECK(throws([&] {
            parse_curve_table(table(entry("a", 190, 0.1, "0.1", "[[0.1,0.05],[0.2,0.08]]", bad)), "t.json");
          }),
          "an out-of-range optional value is refused");
}

static void test_cross_checks() {
  const MaterialCatalogue c = parse_material_catalogue(catalogue());
  CHECK(!throws([&] { make_flexible_data(c, {parse_curve_table(two_temp_table(), "t.json")}); }),
        "consistent catalogue + table");
  CHECK(throws([&] {
          make_flexible_data(c, {parse_curve_table(two_temp_table(), "other.json")});
        }, "other.json"),
        "a table the material does not list is rejected");
  CHECK(throws([&] {
          std::string e = entry("a", 190, 0.1, "0.1");
          e.replace(e.find("\"material_id\":\"tpu_x\""), 21, "\"material_id\":\"nope\"");
          make_flexible_data(c, {parse_curve_table(table(e), "t.json")});
        }, "nope"),
        "an entry naming an unknown material is rejected");
  CHECK(throws([&] {
          make_flexible_data(c, {parse_curve_table(table(entry("a", 190, 0.1, "0.1") + "," +
                                                         entry("a", 190, 0.2, "0.2")),
                                                   "t.json")});
        }, "duplicated entry id"),
        "duplicate entry ids rejected");
}

// H5: an offered temperature outside the maker's printing range is FLAGGED, never
// dropped or changed (data untouched).
static void test_temperature_flags() {
  FlexibleData d = load_flexible_data(FLEXIBLE_MATERIALS_JSON_PATH);
  const std::string n190 = temperature_note(d, "varioshore_tpu", 190);
  CHECK(n190.find("below the manufacturer") != std::string::npos &&
            n190.find("195") != std::string::npos && n190.find("iacob2024") != std::string::npos,
        "190 C: below the manufacturer's 195-260 C range, tested by iacob2024");
  CHECK(temperature_note(d, "varioshore_tpu", 220).empty(), "220 C is inside the range: no note");
}

// The loader converts every curve to CORE strain once (02 §2): the specimen's skins are
// treated as rigid and removed from the gauge length.
static void test_core_strain() {
  FlexibleData d = load_flexible_data(FLEXIBLE_MATERIALS_JSON_PATH);
  const CurveEntry& g = d.tables[0].entries[0];
  const double k = 12.5 / (12.5 - 1.6);
  CHECK(g.loading[0].strain == 0.1 && g.core_loading.size() == 2 &&
            std::fabs(g.core_loading[0].strain - 0.1 * k) < 1e-15 &&
            g.core_loading[0].stress_mpa == g.loading[0].stress_mpa &&
            std::fabs(g.core_strain_max_measured - 0.25 * k) < 1e-15,
        "file values kept as written; core curve = nominal strain x 12.5 / 10.9, stress unchanged");
}

static void test_density_axis() {
  FlexibleData d = load_flexible_data(FLEXIBLE_MATERIALS_JSON_PATH);
  for (const char* topo : {"gyroid", "honeycomb"}) {
    const DensityAxis ax = build_density_axis(d, "varioshore_tpu", topo);
    CHECK(ax.map.size() == 6, "six nominal points per pattern");
    CHECK(ax.mapping_temp_c == 190, "the map is the 190 C rows'");
    CHECK(ax.density_basis == "estimated_core (190 \xC2\xB0""C mapping)",
          "basis string names the mapping");
    int at190 = 0, other = 0;
    for (const CurveEntry& e : d.tables[0].entries) {
      if (e.topology != topo) continue;
      const double core = core_density_of(ax, e);
      if (e.nozzle_temp_c == 190) {
        ++at190;
        CHECK(core == e.est_core_relative_density.value,
              "the map reproduces the 190 C est_core value EXACTLY");
      } else {
        ++other;
        // the same nominal % at 190 C
        for (const CurveEntry& r : d.tables[0].entries)
          if (r.topology == e.topology && r.nozzle_temp_c == 190 &&
              r.relative_density == e.relative_density)
            CHECK(core == r.est_core_relative_density.value,
                  "220/240 C rows take the 190 C core value per nominal %");
      }
    }
    CHECK(at190 == 6 && other == 12, "every row mapped");
  }
  const DensityAxis g = build_density_axis(d, "varioshore_tpu", "gyroid");
  CHECK(g.map.front().core == 0.143 && g.map.back().core == 0.362,
        "gyroid core axis 0.143..0.362 (02 §2 table)");
  const DensityAxis h = build_density_axis(d, "varioshore_tpu", "honeycomb");
  CHECK(h.map.front().core == 0.165 && h.map.back().core == 0.446,
        "honeycomb core axis 0.165..0.446 (02 §2 table)");

  const MaterialCatalogue c = parse_material_catalogue(catalogue());
  // est_core stated at two temperatures: two maps, refused.
  CHECK(throws([&] {
          FlexibleData bad = make_flexible_data(
              c, {parse_curve_table(table(entry("a", 190, 0.1, "0.15") + "," +
                                          entry("b", 220, 0.2, "0.25")),
                                    "t.json")});
          build_density_axis(bad, "tpu_x", "gyroid");
        }, "more than one temperature"),
        "est_core from two temperatures is refused");
  // a 220 row whose nominal % was never mapped.
  CHECK(throws([&] {
          FlexibleData bad = make_flexible_data(
              c, {parse_curve_table(table(entry("a", 190, 0.1, "0.15") + "," +
                                          entry("b", 190, 0.2, "0.25") + "," +
                                          entry("c", 220, 0.3, "null")),
                                    "t.json")});
          const DensityAxis ax = build_density_axis(bad, "tpu_x", "gyroid");
          core_density_of(ax, bad.tables[0].entries[2]);
        }, "not on the"),
        "an unmapped nominal value is refused, not interpolated");
  // rows whose curves cross: the inverse could not bracket density
  CHECK(throws([&] {
          FlexibleData bad = make_flexible_data(
              c, {parse_curve_table(table(entry("a", 190, 0.1, "0.15", "[[0.1,0.05],[0.2,0.2]]") + "," +
                                          entry("b", 190, 0.2, "0.25", "[[0.1,0.06],[0.2,0.07]]")),
                                    "t.json")});
          curve_set(bad, "tpu_x", 190, "gyroid");
        }, "cross"),
        "rows whose stress does not rise with density are refused");
  // Rows that cross ONLY at one row's own curve point, strictly between the sampled
  // strains (review round 1): a's steep step to 0.070 at 0.10125 pokes above b there.
  CHECK(throws([&] {
          FlexibleData bad = make_flexible_data(
              c, {parse_curve_table(
                     table(entry("a", 190, 0.1, "0.15", "[[0.1,0.065],[0.10125,0.070],[0.2,0.075]]") + "," +
                           entry("b", 190, 0.2, "0.25", "[[0.1,0.066],[0.1025,0.0705],[0.2,0.3]]")),
                     "t.json")});
          curve_set(bad, "tpu_x", 190, "gyroid");
        }, "cross"),
        "a crossing at a row's own point (between samples) is refused");
  // a map that is not increasing
  CHECK(throws([&] {
          FlexibleData bad = make_flexible_data(
              c, {parse_curve_table(table(entry("a", 190, 0.1, "0.25") + "," +
                                          entry("b", 190, 0.2, "0.15")),
                                    "t.json")});
          build_density_axis(bad, "tpu_x", "gyroid");
        }, "increasing"),
        "a decreasing nominal->core map is refused");
}

int main() {
  test_live_files();
  test_catalogue_strictness();
  test_curve_strictness();
  test_cross_checks();
  test_density_axis();
  test_temperature_flags();
  test_core_strain();
  std::printf("test_flexible_data: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
