// M3.4 validation — Gate V2: the full 3D volume-fraction-targeted SIMP loop
// (simp_optimize) on the 3D cantilever and clamped-beam benchmarks reproduces
// the reference compliance/topology committed in
// core/tests/fixtures/benchmarks.json (ARCHITECTURE §7 V2). Lives in
// tests/validation/ per ARCHITECTURE §3 ("analytical benchmarks (beam theory,
// MBB, cantilever)").
//
// The fixture is human-authored and IMMUTABLE (ARCHITECTURE §1/§8): this test
// asserts against its values, it does not edit them. The gates asserted are
// exactly the ones the fixture declares:
//   * final compliance within `compliance_final_rel_tolerance` (5%),
//   * achieved physical volume fraction within
//     `achieved_volume_fraction_abs_tolerance` (0.01),
//   * the DOMINANT thresholded (rho > 0.5) component spans the required faces,
//   * and, where the fixture pins it, the number of connected components.
// The fixture's `informational_only` quantities (raw voxel counts, symmetry
// error) are not gated; `compliance_first_iteration` is additionally checked
// within the same 5% band as a setup-correctness anchor (a wrong BC/load/
// material setup that happened to match the converged compliance would still
// miss the uniform-start compliance).
//
// No third-party test framework (ARCHITECTURE §4); the same self-contained
// CHECK harness and test-local JSON reader as test_fea.cpp, public API only.

#include "topopt/fea.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

using topopt::DirichletBC;
using topopt::NodalLoad;
using topopt::SimpOptimizeResult;
using topopt::SimpOptions;
using topopt::SimpParams;
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

// --- Minimal, test-local JSON reader (same idiom as test_fea.cpp) ----------
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

Json load_json(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) throw std::runtime_error("cannot open fixture: " + path);
  std::ostringstream ss;
  ss << in.rdbuf();
  return JsonParser(ss.str()).parse();
}

// A fully-solid design grid (every voxel is a design voxel, matching the
// benchmarks' "all_voxels_design": true).
VoxelGrid solid_grid(int nx, int ny, int nz, double h) {
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = h;
  g.origin = topopt::Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  return g;
}

// 6-connected components of the thresholded (rho > thr) voxel set.
struct Components {
  std::vector<int> label;  // grid-indexed; -1 where rho <= thr
  std::vector<int> size;   // voxel count per component id
  int dominant = -1;       // id of the largest component (-1 if none)
};

Components connected_components(const VoxelGrid& g,
                               const std::vector<double>& rho, double thr) {
  Components c;
  c.label.assign(g.voxel_count(), -1);
  auto solid = [&](int i, int j, int k) {
    return rho[g.index(i, j, k)] > thr;
  };
  std::vector<std::size_t> stack;
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        if (!solid(i, j, k) || c.label[g.index(i, j, k)] != -1) continue;
        const int id = static_cast<int>(c.size.size());
        int count = 0;
        stack.clear();
        c.label[g.index(i, j, k)] = id;
        stack.push_back(g.index(i, j, k));
        while (!stack.empty()) {
          const std::size_t idx = stack.back();
          stack.pop_back();
          ++count;
          const int ci = static_cast<int>(idx % g.nx);
          const int cj = static_cast<int>((idx / g.nx) % g.ny);
          const int ck = static_cast<int>(idx / (static_cast<std::size_t>(g.nx) * g.ny));
          const int off[6][3] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0},
                                 {0, -1, 0}, {0, 0, 1}, {0, 0, -1}};
          for (const auto& o : off) {
            const int ni = ci + o[0], nj = cj + o[1], nk = ck + o[2];
            if (ni < 0 || ni >= g.nx || nj < 0 || nj >= g.ny || nk < 0 ||
                nk >= g.nz)
              continue;
            if (!solid(ni, nj, nk) || c.label[g.index(ni, nj, nk)] != -1)
              continue;
            c.label[g.index(ni, nj, nk)] = id;
            stack.push_back(g.index(ni, nj, nk));
          }
        }
        c.size.push_back(count);
      }
  int best = -1;
  for (std::size_t s = 0; s < c.size.size(); ++s)
    if (best < 0 || c.size[s] > c.size[static_cast<std::size_t>(best)])
      best = static_cast<int>(s);
  c.dominant = best;
  return c;
}

}  // namespace

int main() {
  const std::string path = std::string(BENCH_FIXTURE_DIR) + "/benchmarks.json";
  const Json root = load_json(path);
  const Json& benches = root.at("benchmarks");

  // Locked SIMP formulation (benchmarks.json "formulation_locked"): p = 3,
  // rho_min = 0.001, density-filter radius 1.5, move 0.2, OC eta 0.5 (the
  // sqrt in oc_update), initial x = volfrac, 60 iterations, tight CG tol.
  const double kFilterRadius = 1.5, kMove = 0.2;
  const int kIterations = 60;
  const double kCgTol = 1e-8;

  for (const auto& kv : benches.obj) {
    const std::string& name = kv.first;
    const Json& b = kv.second;

    const int nx = static_cast<int>(b.at("grid").at("nx").num);
    const int ny = static_cast<int>(b.at("grid").at("ny").num);
    const int nz = static_cast<int>(b.at("grid").at("nz").num);
    const double h = b.at("grid").at("spacing").num;
    const double E0 = b.at("material").at("E0").num;
    const double nu = b.at("material").at("nu").num;
    const double volfrac = b.at("volfrac").num;

    const Json& ref = b.at("reference");
    const Json& gates = b.at("gates");
    const double c_ref = ref.at("compliance_final").num;
    const double c_first_ref = ref.at("compliance_first_iteration").num;
    const double vf_ref = ref.at("achieved_volume_fraction").num;
    const double c_reltol = gates.at("compliance_final_rel_tolerance").num;
    const double vf_abstol =
        gates.at("achieved_volume_fraction_abs_tolerance").num;

    VoxelGrid g = solid_grid(nx, ny, nz, h);

    // BCs / loads per the fixture's textual description, keyed by benchmark.
    std::vector<DirichletBC> bcs;
    std::vector<NodalLoad> loads;
    auto clamp_face = [&](int a) {  // clamp all 3 DOF of every node on x = a
      for (int c = 0; c <= nz; ++c)
        for (int bb = 0; bb <= ny; ++bb) {
          const int n = topopt::fea_node_index(g, a, bb, c);
          bcs.push_back({n, 0, 0.0});
          bcs.push_back({n, 1, 0.0});
          bcs.push_back({n, 2, 0.0});
        }
    };
    if (name == "cantilever_24x8x8") {
      // Clamp the x=0 face; total Fz = -1 spread over all (ny+1)(nz+1) nodes of
      // the x=nx face.
      clamp_face(0);
      const double fz = -1.0 / static_cast<double>((ny + 1) * (nz + 1));
      for (int c = 0; c <= nz; ++c)
        for (int bb = 0; bb <= ny; ++bb)
          loads.push_back({topopt::fea_node_index(g, nx, bb, c), 2, fz});
    } else if (name == "clamped_beam_48x8x8") {
      // Clamp BOTH the x=0 and x=nx faces; total Fz = -1 spread over the (ny+1)
      // nodes of the top center line (i = nx/2, k = nz, all j).
      clamp_face(0);
      clamp_face(nx);
      const double fz = -1.0 / static_cast<double>(ny + 1);
      for (int bb = 0; bb <= ny; ++bb)
        loads.push_back({topopt::fea_node_index(g, nx / 2, bb, nz), 2, fz});
    } else {
      std::fprintf(stderr, "FAIL: unknown benchmark '%s' in fixture\n",
                   name.c_str());
      ++g_failures;
      ++g_checks;
      continue;
    }

    SimpParams p;
    p.youngs_modulus = E0;
    p.poisson = nu;
    p.penalty = 3.0;
    p.density_min = 0.001;

    SimpOptions opt;
    opt.volume_fraction = volfrac;
    opt.filter_radius = kFilterRadius;
    opt.move = kMove;
    opt.max_iterations = kIterations;
    opt.change_tol = 0.0;  // force all 60 iterations, like the reference
    opt.cg_tolerance = kCgTol;
    opt.cg_max_iterations = 0;

    const SimpOptimizeResult r = topopt::simp_optimize(g, p, bcs, loads, opt);

    const Components comps = connected_components(g, r.physical_density, 0.5);
    int dom_solids = comps.dominant >= 0
                         ? comps.size[static_cast<std::size_t>(comps.dominant)]
                         : 0;
    int total_solids = 0;
    for (int s : comps.size) total_solids += s;

    // Does the dominant component touch a given plane / region?
    bool touch_x0 = false, touch_xn = false, touch_load_line = false;
    for (int k = 0; k < nz; ++k)
      for (int j = 0; j < ny; ++j)
        for (int i = 0; i < nx; ++i) {
          if (comps.dominant < 0 ||
              comps.label[g.index(i, j, k)] != comps.dominant)
            continue;
          if (i == 0) touch_x0 = true;
          if (i == nx - 1) touch_xn = true;
          // clamped-beam loaded top-center line: voxels under node i=nx/2, k=nz.
          if (k == nz - 1 && (i == nx / 2 - 1 || i == nx / 2))
            touch_load_line = true;
        }

    const double c_relerr = std::fabs(r.compliance - c_ref) / c_ref;
    const double c_first_relerr =
        std::fabs(r.initial_compliance - c_first_ref) / c_first_ref;
    const double vf_abserr = std::fabs(r.volume_fraction - vf_ref);

    std::printf("[%s] %dx%dx%d volfrac %.2f, %d iters (converged=%d)\n",
                name.c_str(), nx, ny, nz, volfrac, r.iterations,
                static_cast<int>(r.converged));
    std::printf("  compliance %.4f (ref %.4f, rel err %.4f, gate %.2f)\n",
                r.compliance, c_ref, c_relerr, c_reltol);
    std::printf("  first-iter compliance %.4f (ref %.4f, rel err %.4f)\n",
                r.initial_compliance, c_first_ref, c_first_relerr);
    std::printf("  volume fraction %.6f (ref %.6f, abs err %.6f, gate %.3f)\n",
                r.volume_fraction, vf_ref, vf_abserr, vf_abstol);
    std::printf("  thresholded(0.5): %d solid voxels, %d components, "
                "dominant %d\n",
                total_solids, static_cast<int>(comps.size.size()), dom_solids);
    std::printf("  dominant spans: x0=%d xn=%d load_line=%d\n",
                static_cast<int>(touch_x0), static_cast<int>(touch_xn),
                static_cast<int>(touch_load_line));

    // ---- Gate V2 assertions -------------------------------------------------
    // 1. Final compliance within the fixture's relative tolerance.
    CHECK(c_relerr <= c_reltol,
          "V2: final compliance within 5% of the reference");
    // 2. Setup anchor: uniform-start compliance matches the reference too.
    CHECK(c_first_relerr <= c_reltol,
          "V2: first-iteration compliance matches (BC/load/material setup)");
    // 3. Achieved physical volume fraction within the fixture's abs tolerance.
    CHECK(vf_abserr <= vf_abstol,
          "V2: achieved volume fraction within tolerance of the reference");
    // 4. The optimizer actually reduced compliance a lot from the uniform start.
    CHECK(r.compliance < 0.5 * r.initial_compliance,
          "V2: optimized compliance far below the uniform-start compliance");
    // 5. The dominant thresholded component spans the required faces.
    CHECK(touch_x0 && touch_xn,
          "V2: dominant component spans the x=0 and x=nx faces");
    // 6. Where the fixture pins the component count, assert it exactly; and the
    //    clamped beam's dominant component must also reach the loaded top line.
    if (gates.has("connected_components_at_threshold_0p5")) {
      const int want =
          static_cast<int>(gates.at("connected_components_at_threshold_0p5").num);
      CHECK(static_cast<int>(comps.size.size()) == want,
            "V2: connected-component count matches the fixture");
    }
    if (name == "clamped_beam_48x8x8")
      CHECK(touch_load_line,
            "V2: dominant component reaches the loaded top-center line");
  }

  if (g_failures == 0) {
    std::printf("gate v2 validation: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "gate v2 validation: %d/%d checks FAILED\n", g_failures,
               g_checks);
  return 1;
}
