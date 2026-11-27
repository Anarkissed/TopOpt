// CORE LIST item 40 and its addendum (his Carriage Arms run 13185527): a
// reduction rung that asks for LESS material than the part's frozen material
// alone prints.
//
// On the design-box path a rung's target is `vf * part_solid - frozen`, spread
// over the Active envelope and clamped to [density_min, 1] (minimize_plastic,
// the rung loop). When the frozen share (the anchor and load faces, the anchor
// pad, the face protections) is at or above the rung's ask, the target clamps to
// the density floor: the optimizer removes every free voxel and prints the frozen
// material alone. On 13185527 the rungs 0.68 / 0.52 / 0.38 / 0.26 all printed
// 0.758, nothing flagged it, report.json kept no requested value, and the files
// were still named variant_068 ... variant_026.
//
// Pinned here, red-first (every check below compiles against the pre-fix API and
// reads report.json the way the app does):
//   (a) THE FLAG. On a run where some rung's target clamped to the floor, every
//       report line carries its request and `target_saturated`, and the run
//       carries a `frozen_share` block: the share, the voxel counts, and what
//       froze the part, the sources summing to the frozen count.
//   (b) THE SKIP. The rungs after the first accepted floor rung would get the SAME
//       target, so they are not run. Each is reported with its reason and the rung
//       whose design it would repeat; it gets no variant and no file. Proven to be
//       the same design: the skipped rung run ALONE reproduces the floor rung.
//   (c) THE CONTROL. A run whose frozen share is below every rung's ask carries
//       none of the new keys, so its report.json keeps today's bytes.
//   (d) WHAT FROZE IT, through the production load case (build_production_loadcase
//       on the demo l-bracket with protected faces): the anchor and load faces,
//       the anchor pad, and one line per protected face, named by face id, each
//       voxel counted once, the lines summing to the frozen count.
//
// Drives minimize_plastic (Eigen), so it is Eigen-gated in CMake like the sibling
// optimizer gates; the real settings rules and materials are injected. Same
// self-contained CHECK harness and test-local JSON reader as test_gate_v2.

#include "topopt/face_region.hpp"
#include "topopt/fea.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/report.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

using topopt::DesignBox;
using topopt::DesignMask;
using topopt::DirichletBC;
using topopt::MaskValue;
using topopt::Material;
using topopt::MaterialLibrary;
using topopt::MinimizePlasticOptions;
using topopt::MinimizePlasticResult;
using topopt::NodalLoad;
using topopt::ProductionLoadCase;
using topopt::ProductionRunSetup;
using topopt::SettingsRules;
using topopt::StepModel;
using topopt::StepSurfaceKind;
using topopt::Vec3;
using topopt::VoxelGrid;
using topopt::VoxelTag;

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

// --- Minimal, test-local JSON reader (same idiom as test_gate_v2.cpp) --------
struct Json {
  enum class T { Num, Str, Arr, Obj, Bool, Null } t = T::Num;
  double num = 0.0;
  bool boolean = false;
  std::string str;
  std::vector<Json> arr;
  std::vector<std::pair<std::string, Json>> obj;
  bool has(const std::string& key) const {
    for (const auto& kv : obj)
      if (kv.first == key) return true;
    return false;
  }
  const Json& at(const std::string& key) const {
    for (const auto& kv : obj)
      if (kv.first == key) return kv.second;
    throw std::runtime_error("missing JSON key: " + key);
  }
};

class JsonParser {
 public:
  explicit JsonParser(const std::string& s) : s_(s) {}
  Json parse() {
    skip_ws();
    Json v = value();
    skip_ws();
    if (pos_ != s_.size()) throw std::runtime_error("trailing JSON characters");
    return v;
  }

 private:
  const std::string& s_;
  std::size_t pos_ = 0;

  void skip_ws() {
    while (pos_ < s_.size()) {
      char c = s_[pos_];
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r') ++pos_;
      else break;
    }
  }
  char peek() {
    if (pos_ >= s_.size()) throw std::runtime_error("unexpected end of JSON");
    return s_[pos_];
  }
  Json value() {
    skip_ws();
    char c = peek();
    if (c == '{') return object();
    if (c == '[') return array();
    if (c == '"') {
      Json v;
      v.t = Json::T::Str;
      v.str = string();
      return v;
    }
    if (c == '-' || (c >= '0' && c <= '9')) return number();
    if (c == 't' || c == 'f') return boolean();
    if (c == 'n') return null_literal();
    throw std::runtime_error(std::string("unexpected JSON character '") + c +
                             "'");
  }
  Json boolean() {
    Json v;
    v.t = Json::T::Bool;
    if (s_.compare(pos_, 4, "true") == 0) {
      v.boolean = true;
      pos_ += 4;
    } else if (s_.compare(pos_, 5, "false") == 0) {
      v.boolean = false;
      pos_ += 5;
    } else {
      throw std::runtime_error("invalid JSON boolean literal");
    }
    return v;
  }
  Json null_literal() {
    if (s_.compare(pos_, 4, "null") != 0)
      throw std::runtime_error("invalid JSON null literal");
    pos_ += 4;
    Json v;
    v.t = Json::T::Null;
    return v;
  }
  Json object() {
    Json v;
    v.t = Json::T::Obj;
    ++pos_;  // '{'
    skip_ws();
    if (peek() == '}') {
      ++pos_;
      return v;
    }
    while (true) {
      skip_ws();
      if (peek() != '"') throw std::runtime_error("expected JSON object key");
      std::string key = string();
      skip_ws();
      if (peek() != ':') throw std::runtime_error("expected ':' in object");
      ++pos_;
      v.obj.emplace_back(std::move(key), value());
      skip_ws();
      char n = peek();
      ++pos_;
      if (n == ',') continue;
      if (n == '}') break;
      throw std::runtime_error("expected ',' or '}' in object");
    }
    return v;
  }
  Json array() {
    Json v;
    v.t = Json::T::Arr;
    ++pos_;  // '['
    skip_ws();
    if (peek() == ']') {
      ++pos_;
      return v;
    }
    while (true) {
      v.arr.push_back(value());
      skip_ws();
      char n = peek();
      ++pos_;
      if (n == ',') continue;
      if (n == ']') break;
      throw std::runtime_error("expected ',' or ']' in array");
    }
    return v;
  }
  Json number() {
    std::size_t start = pos_;
    if (peek() == '-') ++pos_;
    while (pos_ < s_.size()) {
      char c = s_[pos_];
      if ((c >= '0' && c <= '9') || c == '.' || c == 'e' || c == 'E' ||
          c == '+' || c == '-')
        ++pos_;
      else
        break;
    }
    Json v;
    v.t = Json::T::Num;
    v.num = std::stod(s_.substr(start, pos_ - start));
    return v;
  }
  std::string string() {
    ++pos_;  // opening quote
    std::string out;
    while (true) {
      if (pos_ >= s_.size()) throw std::runtime_error("unterminated string");
      char c = s_[pos_++];
      if (c == '"') break;
      if (c == '\\') {
        if (pos_ >= s_.size()) throw std::runtime_error("unterminated escape");
        char e = s_[pos_++];
        switch (e) {
          case '"': out.push_back('"'); break;
          case '\\': out.push_back('\\'); break;
          case '/': out.push_back('/'); break;
          case 'n': out.push_back('\n'); break;
          case 't': out.push_back('\t'); break;
          default: out.push_back(e); break;
        }
      } else {
        out.push_back(c);
      }
    }
    return out;
  }
};

// The thin L-bracket test_designbox_reduction uses: a vertical arm mounted at
// the top, a horizontal foot loaded down at its free end. arm = span = 8, ny = 3,
// t = 2 gives 84 solid voxels: 6 Fixture (i < 2, k = 7) and 6 Load (i = 7, k < 2).
VoxelGrid l_bracket(std::vector<DirichletBC>& bcs, int arm, int span, int ny,
                    int t, double h) {
  VoxelGrid g;
  g.nx = span; g.ny = ny; g.nz = arm; g.spacing = h;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(span) * ny * arm, VoxelTag::Empty);
  for (int k = 0; k < arm; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < span; ++i)
        if (i < t || k < t) g.set_tag(i, j, k, VoxelTag::Interior);
  auto solid = [&](int i, int j, int k) {
    if (i < 0 || j < 0 || k < 0 || i >= span || j >= ny || k >= arm) return false;
    return g.tag(i, j, k) != VoxelTag::Empty;
  };
  for (int k = 0; k < arm; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < span; ++i) {
        if (!solid(i, j, k)) continue;
        if (!solid(i-1,j,k)||!solid(i+1,j,k)||!solid(i,j-1,k)||!solid(i,j+1,k)||
            !solid(i,j,k-1)||!solid(i,j,k+1))
          g.set_tag(i, j, k, VoxelTag::Surface);
      }
  for (int j = 0; j < ny; ++j)
    for (int i = 0; i < t; ++i) g.set_tag(i, j, arm - 1, VoxelTag::Fixture);
  bcs.clear();
  for (int b = 0; b <= ny; ++b)
    for (int a = 0; a <= t; ++a) {
      const int node = topopt::fea_node_index(g, a, b, arm);
      bcs.push_back({node, 0, 0.0});
      bcs.push_back({node, 1, 0.0});
      bcs.push_back({node, 2, 0.0});
    }
  for (int k = 0; k < t; ++k)
    for (int j = 0; j < ny; ++j) g.set_tag(span - 1, j, k, VoxelTag::Load);
  return g;
}

Material fdm_material() {
  Material m;
  m.youngs_modulus_mpa = 3500.0; m.yield_strength_mpa = 55.0;
  m.density_g_cm3 = 1.24; m.z_knockdown = 0.55; m.poisson = 0.33; m.family = "fdm";
  return m;
}

// The production reduction ladder on the design-box path. The comfort floor
// (margin_floor_multiple) stays at its +infinity default, as in production, so
// no rung ends the walk early for being comfortably strong.
MinimizePlasticOptions reduction_options(const std::vector<NodalLoad>& loads) {
  MinimizePlasticOptions o;
  o.volume_fraction_ladder = {0.68, 0.52, 0.38, 0.26};
  o.margin_stop = 1.5;
  o.external_loads = loads;
  o.gravity = 9810.0 * 1e-9;
  o.gravity_direction = Vec3{0.0, 0.0, -1.0};
  o.updater = topopt::SimpUpdater::MMA;
  o.infill_percent = 100.0;
  o.bake_build_orientation = topopt::BakeBuildOrientation::Off;
  // A design box drawn snug around the part (x, z in [0, 16], y in [0, 6]): the
  // run is on the whole-domain path, so its rungs are fractions of the PART.
  o.design_box = DesignBox{Vec3{0.0, 0.0, 0.0}, Vec3{16.0, 6.0, 16.0}};
  return o;
}

Json report_of(const MinimizePlasticResult& r) {
  const std::string text = topopt::job_report_json(r.report);
  topopt::validate_job_report_json(text);
  return JsonParser(text).parse();
}

const Json* variant_line(const Json& report, double requested) {
  for (const char* array : {"variants", "rejected_variants"}) {
    if (!report.has(array)) continue;
    for (const Json& v : report.at(array).arr)
      if (v.has("requested_volume_fraction") &&
          std::fabs(v.at("requested_volume_fraction").num - requested) < 1e-12)
        return &v;
  }
  return nullptr;
}

bool any_line_has(const Json& report, const std::string& key) {
  for (const char* array : {"variants", "rejected_variants"}) {
    if (!report.has(array)) continue;
    for (const Json& v : report.at(array).arr)
      if (v.has(key)) return true;
  }
  return false;
}

long long sources_sum(const Json& frozen_share) {
  long long sum = 0;
  for (const Json& s : frozen_share.at("sources").arr)
    sum += static_cast<long long>(s.at("voxels").num);
  return sum;
}

long long source_voxels(const Json& frozen_share, const std::string& name) {
  long long n = -1;
  for (const Json& s : frozen_share.at("sources").arr)
    if (s.at("source").str == name)
      n = (n < 0 ? 0 : n) + static_cast<long long>(s.at("voxels").num);
  return n;
}

double max_abs_diff(const std::vector<double>& a, const std::vector<double>& b) {
  if (a.size() != b.size()) return INFINITY;
  double m = 0.0;
  for (std::size_t i = 0; i < a.size(); ++i)
    m = std::max(m, std::fabs(a[i] - b[i]));
  return m;
}

}  // namespace

int main() {
  SettingsRules rules;
  MaterialLibrary materials;
  try {
    rules = topopt::load_settings_rules_file(SETTINGS_RULES_PATH);
    materials = topopt::load_materials_file(MATERIALS_JSON_PATH);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "FAIL: could not load the rules or materials: %s\n",
                 e.what());
    return 1;
  }
  const Material material = fdm_material();

  std::vector<DirichletBC> bcs;
  const VoxelGrid part = l_bracket(bcs, /*arm=*/8, /*span=*/8, /*ny=*/3, /*t=*/2,
                                   /*h=*/2.0);
  const long long part_solid = static_cast<long long>(part.solid_count());
  CHECK(part_solid == 84, "fixture: the L-bracket has 84 solid voxels");
  // A light tip load: this gate is about what the ladder reports, not strength,
  // so the frozen material alone must clear the margin comfortably.
  const std::vector<NodalLoad> tip =
      topopt::traction_loads(part, VoxelTag::Load, Vec3{0.0, 0.0, -2.0});

  // The frozen set, standing in for his protections: the whole y = 0 slab of the
  // L (28 voxels) plus the arm at y = 1 (16). With the BC skin the slab and arm do
  // not already cover (Fixture at y = 2, Load at y = 1 and y = 2: 6 voxels), 50 of
  // the 84 voxels are frozen, a share of 0.595. So rung 0.68 is above it (its
  // target is honoured) and 0.52, 0.38 and 0.26 are below it.
  DesignMask frozen(part.voxel_count(), MaskValue::Active);
  for (int k = 0; k < part.nz; ++k)
    for (int j = 0; j < 2; ++j)
      for (int i = 0; i < part.nx; ++i) {
        if (!part.solid(i, j, k)) continue;
        if (j == 0 || i < 2) frozen[part.index(i, j, k)] = MaskValue::FrozenSolid;
      }
  const long long expected_frozen = 50;
  const long long expected_skin = 12;  // 6 Fixture + 6 Load voxels
  const double expected_share =
      static_cast<double>(expected_frozen) / static_cast<double>(part_solid);

  // ── (a) + (b): the starved run ────────────────────────────────────────────
  MinimizePlasticOptions starved_opts = reduction_options(tip);
  starved_opts.design_mask = frozen;
  const MinimizePlasticResult starved = topopt::minimize_plastic(
      part, material, "fdm", bcs, rules, starved_opts);
  const Json starved_report = report_of(starved);

  std::printf("[40] starved run: %zu rung(s) evaluated:", starved.evaluated.size());
  for (const auto& v : starved.evaluated)
    std::printf("  %.2f -> printed %.4f%s", v.requested_volume_fraction,
                v.report.printed_fraction, v.accepted ? "" : " (rejected)");
  std::printf("\n");

  CHECK(starved.evaluated.size() >= 2 && starved.evaluated[0].accepted &&
            starved.evaluated[1].accepted,
        "precondition: rungs 0.68 and 0.52 both run and pass");
  CHECK(starved.evaluated.size() == 2,
        "(b): only 0.68 and the first floor rung 0.52 are run; 0.38 and 0.26, "
        "which would get the same clamped target, are not");

  CHECK(starved_report.has("frozen_share"),
        "(a): report.json carries a frozen_share block on a saturated run");
  if (starved_report.has("frozen_share")) {
    const Json& fs = starved_report.at("frozen_share");
    CHECK(static_cast<long long>(fs.at("part_solid_voxels").num) == part_solid,
          "(a): frozen_share.part_solid_voxels is the part's solid count");
    CHECK(static_cast<long long>(fs.at("frozen_voxels").num) == expected_frozen,
          "(a): frozen_share.frozen_voxels counts the BC skin and the mask once");
    CHECK(std::fabs(fs.at("share").num - expected_share) < 1e-9,
          "(a): frozen_share.share = frozen / part solid (50 / 84)");
    CHECK(fs.at("smallest_honoured_fraction").num > expected_share &&
              fs.at("smallest_honoured_fraction").num < 0.68,
          "(a): the smallest honoured ask sits just above the share, below the "
          "0.68 rung that was honoured");
    CHECK(fs.at("files_named_by").str == "requested_volume_fraction",
          "(a): the receipt says the files are named by the REQUESTED fraction");
    CHECK(sources_sum(fs) == expected_frozen,
          "(a): the sources add up to the frozen count, each voxel once");
    CHECK(source_voxels(fs, "anchor_and_load_faces") == expected_skin,
          "(a): the anchor and load faces' own voxels are a source of their own");

    const Json& skipped = fs.at("skipped_rungs");
    CHECK(skipped.arr.size() == 2, "(b): two rungs are reported skipped");
    if (skipped.arr.size() == 2) {
      CHECK(std::fabs(skipped.arr[0].at("requested_volume_fraction").num - 0.38) <
                    1e-12 &&
                std::fabs(skipped.arr[1].at("requested_volume_fraction").num -
                          0.26) < 1e-12,
            "(b): the skipped rungs are 0.38 and 0.26, in ladder order");
      for (const Json& s : skipped.arr) {
        CHECK(std::fabs(s.at("same_design_as").num - 0.52) < 1e-12,
              "(b): each skipped rung names the floor rung it would repeat");
        CHECK(!s.at("reason").str.empty(), "(b): each skipped rung says why");
      }
      std::printf("[40] skipped reason: %s\n",
                  skipped.arr[0].at("reason").str.c_str());
    }
  }

  const Json* line068 = variant_line(starved_report, 0.68);
  const Json* line052 = variant_line(starved_report, 0.52);
  CHECK(line068 != nullptr && line052 != nullptr,
        "(a): every line of a saturated run carries requested_volume_fraction");
  if (line068 != nullptr)
    CHECK(line068->has("target_saturated") &&
              !line068->at("target_saturated").boolean,
          "(a): rung 0.68 is above the frozen share: target_saturated false");
  if (line052 != nullptr) {
    CHECK(line052->has("target_saturated") &&
              line052->at("target_saturated").boolean,
          "(a): rung 0.52 asked below the frozen share: target_saturated true");
    // What the floor rung achieved: the frozen material, within a voxel or two.
    CHECK(std::fabs(line052->at("printed_fraction").num - expected_share) <
              2.5 / static_cast<double>(part_solid),
          "(a): the floor rung printed the frozen share (achieved != requested)");
  }

  // (b) THE SAME DESIGN. Rung 0.38 run on its own is a floor rung with nothing
  // before it, so it runs; this run starts uniform like the main run's 0.52 rung
  // did (no warm start is armed), so its design must be the floor design.
  {
    MinimizePlasticOptions alone_opts = starved_opts;
    alone_opts.volume_fraction_ladder = {0.38};
    const MinimizePlasticResult alone = topopt::minimize_plastic(
        part, material, "fdm", bcs, rules, alone_opts);
    CHECK(alone.evaluated.size() == 1 && starved.evaluated.size() >= 2,
          "(b): rung 0.38 alone runs (no floor rung before it)");
    if (alone.evaluated.size() == 1 && starved.evaluated.size() >= 2) {
      const double d = max_abs_diff(
          alone.evaluated[0].optimization.physical_density,
          starved.evaluated[1].optimization.physical_density);
      std::printf("[40] rung 0.38 alone vs the floor rung 0.52: max |drho| = %.3g, "
                  "printed %.4f vs %.4f\n",
                  d, alone.evaluated[0].report.printed_fraction,
                  starved.evaluated[1].report.printed_fraction);
      CHECK(d <= 1e-9,
            "(b): the skipped rung's own design IS the floor rung's design");
    }
  }

  // ── (c) the control: nothing frozen beyond the BC skin ─────────────────────
  const MinimizePlasticResult control = topopt::minimize_plastic(
      part, material, "fdm", bcs, rules, reduction_options(tip));
  const Json control_report = report_of(control);
  std::printf("[40] control: %zu rung(s) evaluated\n", control.evaluated.size());
  CHECK(!control_report.has("frozen_share"),
        "(c): an unsaturated run carries no frozen_share block");
  CHECK(!any_line_has(control_report, "requested_volume_fraction") &&
            !any_line_has(control_report, "target_saturated"),
        "(c): an unsaturated run's lines carry none of the new keys");

  // ── (d) what froze it, through the production load case ───────────────────
  {
    const StepModel model =
        topopt::import_step_file(std::string(DEMO_FIXTURE_DIR) + "/l-bracket.step");
    const Material pla = materials.at("PLA");
    ProductionLoadCase lc;
    ProductionLoadCase::LoadGroup g;
    std::vector<int> planes;
    for (int f = 0; f < model.face_count; ++f) {
      const auto& info = model.faces[static_cast<std::size_t>(f)];
      if (info.kind == StepSurfaceKind::Cylinder) lc.anchor_face_ids.push_back(f);
      else if (info.kind == StepSurfaceKind::Plane) planes.push_back(f);
    }
    CHECK(planes.size() >= 3, "fixture: the l-bracket has planar faces");
    if (planes.size() >= 3) {
      // The LARGEST planar face carries the load (a small one can tag no voxels
      // at this resolution); every other planar face is protected, deep.
      const std::vector<double> area = topopt::face_areas_mm2(model);
      const int load_face = *std::max_element(
          planes.begin(), planes.end(), [&](int a, int b) {
            return area[static_cast<std::size_t>(a)] <
                   area[static_cast<std::size_t>(b)];
          });
      g.face_ids.push_back(load_face);
      g.force = Vec3{0.0, 0.0, -5.0};
      lc.load_groups.push_back(g);
      for (int f : planes)
        if (f != load_face) lc.face_protection_face_ids.push_back(f);
      lc.face_protection_depth_mm = 2.0;  // one voxel layer at this resolution
      lc.minimize_plastic = true;  // the reduction ladder, with the anchor pad
      lc.build_dir = Vec3{0.0, 0.0, 1.0};
      Vec3 lo{INFINITY, INFINITY, INFINITY}, hi{-INFINITY, -INFINITY, -INFINITY};
      for (const Vec3& p : model.mesh.vertices) {
        lo = Vec3{std::min(lo.x, p.x), std::min(lo.y, p.y), std::min(lo.z, p.z)};
        hi = Vec3{std::max(hi.x, p.x), std::max(hi.y, p.y), std::max(hi.z, p.z)};
      }
      lc.has_design_box = true;
      lc.design_box = DesignBox{lo, hi};

      ProductionRunSetup setup = topopt::build_production_loadcase(model, 24, lc);
      MinimizePlasticOptions opts = setup.options;
      opts.simp.max_iterations = 8;  // capped: this checks the receipt, not a design
      const MinimizePlasticResult r = topopt::minimize_plastic(
          setup.grid, pla, "PLA", setup.bcs, rules, opts);
      const Json rep = report_of(r);
      std::printf("[40] l-bracket: %zu protected faces, %zu rung(s) evaluated\n",
                  lc.face_protection_face_ids.size(), r.evaluated.size());
      CHECK(rep.has("frozen_share"),
            "(d): the protected l-bracket's rungs ask below its frozen share");
      if (rep.has("frozen_share")) {
        const Json& fs = rep.at("frozen_share");
        std::printf("[40] l-bracket frozen share %.4f (%lld of %lld voxels)\n",
                    fs.at("share").num,
                    static_cast<long long>(fs.at("frozen_voxels").num),
                    static_cast<long long>(fs.at("part_solid_voxels").num));
        CHECK(sources_sum(fs) ==
                  static_cast<long long>(fs.at("frozen_voxels").num),
              "(d): the sources add up to the frozen count");
        CHECK(source_voxels(fs, "anchor_and_load_faces") > 0,
              "(d): the anchor and load faces are a source");
        CHECK(source_voxels(fs, "anchor_pad") > 0, "(d): the anchor pad is a source");
        CHECK(source_voxels(fs, "other") <= 0,
              "(d): nothing frozen is left unattributed on the production path");
        std::size_t named = 0;
        for (const Json& s : fs.at("sources").arr) {
          if (s.at("source").str != "face_protection") continue;
          const int fid = static_cast<int>(s.at("face_id").num);
          if (std::find(lc.face_protection_face_ids.begin(),
                        lc.face_protection_face_ids.end(),
                        fid) != lc.face_protection_face_ids.end())
            ++named;
          std::printf("[40]   face_protection face %d: %lld voxels\n", fid,
                      static_cast<long long>(s.at("voxels").num));
        }
        CHECK(named == lc.face_protection_face_ids.size(),
              "(d): one line per protected face, each named by its face id");
      }
    }
  }

  if (g_failures == 0) {
    std::printf("starved_rung (item 40): all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "starved_rung (item 40): %d/%d checks FAILED\n", g_failures,
               g_checks);
  return 1;
}
