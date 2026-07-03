// Unit tests for the materials.json loader (ROADMAP M1.2).
//
// No third-party test framework is available (ARCHITECTURE §4 locks the
// dependency set), so this is a self-contained harness: each CHECK records a
// pass/fail and main() returns non-zero if anything failed, which is all ctest
// needs. Tests exercise the public API only (topopt/materials.hpp).

#include "topopt/materials.hpp"

#include <cstdio>
#include <fstream>
#include <string>

using topopt::load_materials_file;
using topopt::Material;
using topopt::MaterialError;
using topopt::MaterialLibrary;
using topopt::parse_materials;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                             \
  do {                                                              \
    ++g_checks;                                                     \
    if (!(cond)) {                                                  \
      ++g_failures;                                                 \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg);  \
    }                                                               \
  } while (0)

// Returns true iff parse_materials(json) throws MaterialError.
static bool rejects(const std::string& json) {
  try {
    parse_materials(json);
  } catch (const MaterialError&) {
    return true;
  } catch (...) {
    return false;  // wrong exception type is a failure to reject cleanly
  }
  return false;
}

// A fully valid material object body (the six locked fields).
static const char* kPLA =
    "\"youngs_modulus_mpa\":3500,\"yield_strength_mpa\":55,"
    "\"density_g_cm3\":1.24,\"z_knockdown\":0.55,\"poisson\":0.33,"
    "\"family\":\"fdm\"";

static std::string wrap(const std::string& body) {
  return std::string("{\"PLA\":{") + body + "}}";
}

int main() {
  // --- Valid input: fields parsed correctly ------------------------------
  {
    MaterialLibrary lib = parse_materials(wrap(kPLA));
    CHECK(lib.size() == 1, "one material parsed");
    auto it = lib.find("PLA");
    CHECK(it != lib.end(), "PLA present");
    if (it != lib.end()) {
      const Material& m = it->second;
      CHECK(m.youngs_modulus_mpa == 3500.0, "youngs parsed");
      CHECK(m.yield_strength_mpa == 55.0, "yield parsed");
      CHECK(m.density_g_cm3 == 1.24, "density parsed");
      CHECK(m.z_knockdown == 0.55, "z_knockdown parsed");
      CHECK(m.poisson == 0.33, "poisson parsed");
      CHECK(m.family == "fdm", "family parsed");
    }
  }

  // --- Valid input: multiple materials incl. a resin (z_knockdown 1.0) ---
  {
    std::string json =
        "{"
        "\"PLA\":{" + std::string(kPLA) + "},"
        "\"Resin_Standard\":{"
        "\"youngs_modulus_mpa\":2800,\"yield_strength_mpa\":60,"
        "\"density_g_cm3\":1.10,\"z_knockdown\":1.0,\"poisson\":0.35,"
        "\"family\":\"resin\"}"
        "}";
    MaterialLibrary lib = parse_materials(json);
    CHECK(lib.size() == 2, "two materials parsed");
    CHECK(lib.count("Resin_Standard") == 1, "resin present");
    if (lib.count("Resin_Standard"))
      CHECK(lib.at("Resin_Standard").family == "resin", "resin family");
  }

  // --- Empty object is a valid (empty) library ---------------------------
  {
    bool threw = false;
    try {
      MaterialLibrary lib = parse_materials("{}");
      CHECK(lib.empty(), "empty object -> empty library");
    } catch (const MaterialError&) {
      threw = true;
    }
    CHECK(!threw, "empty object does not throw");
  }

  // --- Schema violations: missing / unknown / duplicate fields -----------
  CHECK(rejects(wrap("\"yield_strength_mpa\":55,\"density_g_cm3\":1.24,"
                     "\"z_knockdown\":0.55,\"poisson\":0.33,"
                     "\"family\":\"fdm\"")),
        "missing youngs_modulus_mpa rejected");

  CHECK(rejects(wrap(std::string(kPLA) + ",\"extra_field\":1")),
        "unknown field rejected");

  CHECK(rejects(wrap("\"youngs_modulus_mpa\":3500,\"youngs_modulus_mpa\":3600,"
                     "\"yield_strength_mpa\":55,\"density_g_cm3\":1.24,"
                     "\"z_knockdown\":0.55,\"poisson\":0.33,"
                     "\"family\":\"fdm\"")),
        "duplicate field rejected");

  // --- Value rules: z_knockdown domain (0, 1] ----------------------------
  CHECK(rejects(wrap("\"youngs_modulus_mpa\":3500,\"yield_strength_mpa\":55,"
                     "\"density_g_cm3\":1.24,\"z_knockdown\":0,"
                     "\"poisson\":0.33,\"family\":\"fdm\"")),
        "z_knockdown 0 rejected");

  CHECK(rejects(wrap("\"youngs_modulus_mpa\":3500,\"yield_strength_mpa\":55,"
                     "\"density_g_cm3\":1.24,\"z_knockdown\":1.5,"
                     "\"poisson\":0.33,\"family\":\"fdm\"")),
        "z_knockdown > 1 rejected");

  CHECK(rejects(wrap("\"youngs_modulus_mpa\":3500,\"yield_strength_mpa\":55,"
                     "\"density_g_cm3\":1.24,\"z_knockdown\":-0.2,"
                     "\"poisson\":0.33,\"family\":\"fdm\"")),
        "negative z_knockdown rejected");

  // z_knockdown exactly 1.0 for an fdm material is allowed (upper bound).
  CHECK(!rejects(wrap("\"youngs_modulus_mpa\":3500,\"yield_strength_mpa\":55,"
                      "\"density_g_cm3\":1.24,\"z_knockdown\":1.0,"
                      "\"poisson\":0.33,\"family\":\"fdm\"")),
        "z_knockdown == 1.0 accepted");

  // --- Value rules: family + resin/z_knockdown coupling ------------------
  CHECK(rejects(wrap("\"youngs_modulus_mpa\":3500,\"yield_strength_mpa\":55,"
                     "\"density_g_cm3\":1.24,\"z_knockdown\":0.55,"
                     "\"poisson\":0.33,\"family\":\"metal\"")),
        "unknown family rejected");

  CHECK(rejects(wrap("\"youngs_modulus_mpa\":2800,\"yield_strength_mpa\":60,"
                     "\"density_g_cm3\":1.10,\"z_knockdown\":0.70,"
                     "\"poisson\":0.35,\"family\":\"resin\"")),
        "resin with z_knockdown != 1.0 rejected");

  // --- Type errors -------------------------------------------------------
  CHECK(rejects(wrap("\"youngs_modulus_mpa\":\"3500\",\"yield_strength_mpa\":55,"
                     "\"density_g_cm3\":1.24,\"z_knockdown\":0.55,"
                     "\"poisson\":0.33,\"family\":\"fdm\"")),
        "numeric field as string rejected");

  CHECK(rejects(wrap("\"youngs_modulus_mpa\":3500,\"yield_strength_mpa\":55,"
                     "\"density_g_cm3\":1.24,\"z_knockdown\":0.55,"
                     "\"poisson\":0.33,\"family\":7")),
        "family as number rejected");

  CHECK(rejects("{\"PLA\":42}"), "material value not an object rejected");

  // --- Malformed JSON ----------------------------------------------------
  CHECK(rejects("{\"PLA\":{" + std::string(kPLA) + "},}"),
        "trailing comma rejected");
  CHECK(rejects("{\"PLA\":{" + std::string(kPLA)), "unclosed braces rejected");
  CHECK(rejects("[1,2,3]"), "top-level array rejected");
  CHECK(rejects(""), "empty string rejected");
  CHECK(rejects("{\"PLA\":{" + std::string(kPLA) + "}} garbage"),
        "trailing garbage rejected");

  // --- File loading ------------------------------------------------------
  {
    const char* path = "test_materials_valid.json";
    {
      std::ofstream out(path);
      out << wrap(kPLA);
    }
    bool threw = false;
    try {
      MaterialLibrary lib = load_materials_file(path);
      CHECK(lib.count("PLA") == 1, "file round-trip loads PLA");
    } catch (const MaterialError&) {
      threw = true;
    }
    CHECK(!threw, "valid file does not throw");
    std::remove(path);
  }
  {
    bool threw = false;
    try {
      load_materials_file("does_not_exist_12345.json");
    } catch (const MaterialError&) {
      threw = true;
    }
    CHECK(threw, "missing file rejected");
  }

  if (g_failures == 0) {
    std::printf("materials loader: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "materials loader: %d/%d checks FAILED\n", g_failures,
               g_checks);
  return 1;
}
