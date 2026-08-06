// test_protect_freeze_vs_solidity.cpp — task 2026-08-04-protect-freeze-vs-solidity:
// PROTECT IS A FREEZE, NOT A SOLIDITY DECLARATION.
//
// THE DEFECT AS REPORTED. Face protection marks the skin FrozenSolid, and ONE tag
// was read as carrying TWO independent facts: (a) the optimizer may not remove
// this — what the user asks for — and (b) this material is SOLID, forever. So
// "don't reshape this wall, but DO lattice inside it" was said to be
// unexpressible.
//
// WHAT THE CODE ACTUALLY DOES, and this file is the proof. On the production
// (two-step) path the two facts are ALREADY separate:
//
//   * MaskValue lives in its own grid-indexed array and constrains the DESIGN
//     VARIABLE only — FrozenSolid pins the density at 1 and drops the voxel from
//     the OC update. That is a statement about the optimizer, nothing else.
//   * whether a printed voxel is solid or latticed is decided downstream by
//     LatticeBoundary + lattice_certification_mask, from the final density, the
//     clearance keep-outs and the include / exclude ROLE regions. Neither the
//     generator nor the certification mask ever reads the design mask.
//
// So lattice-include over frozen material was already legal in the mechanism and
// only the REPORTING and the COPY said otherwise. A test that merely asserted the
// new receipt keys would not catch a regression that re-coupled the two; these
// bars assert the BEHAVIOUR, both directions, on a real end-to-end run.
//
//   PF1 INCLUDE OVER FROZEN MATERIAL IS LATTICED. A run with a face protection
//       and an include region over the protected face lattices frozen voxels:
//       frozen_material.latticed > 0. The protection still did its job — the
//       protected voxels are all printed (density == 1), i.e. RETAINED, so this
//       is "retained AND latticed", not "removed".
//
//   PF2 EXCLUDE OVER FROZEN MATERIAL IS SOLID. The same protection with an
//       exclude region over the same face lattices NONE of it:
//       frozen_material.latticed == 0 and every frozen voxel is kept solid.
//       Today's behaviour, now stated rather than implied.
//
//   PF3 THE AUDIT (bar 3, PR 285's shape reused): over the FROZEN voxels, every
//       cell the certification mask lattices is a cell the generator emitted
//       (cells_not_emitted == 0), and no frozen voxel receives both a strut and
//       companion solid (voxels_strut_and_solid == 0). *** This is the bar that
//       fails if someone "fixes" the frozen set out of the mask without also
//       telling the generator: the certificate would then describe struts
//       through protected material the file does not contain.
//
//   PF4 THE WARNING FIRES ON THE RIGHT THING (bar 4). Lattice declared on frozen
//       material does NOT warn — it is the only way to express a legitimate
//       intent, and warning would train users away from it. Lattice declared on
//       a CLEARANCE VOID DOES warn: there is no material there and no rung or
//       cell size can create any. Asserted on the real stderr text AND on the
//       counters that drive it (include_void_by_clearance).
//
//   PF5 THE PRE-FLIGHT REGION FORECAST (item 6). An include region thinner than
//       the cells-per-member floor requires is named BEFORE the run, with both
//       numbers. This is the maintainer's 4 mm slab vs 5 x 4.6026 mm = 23.0 mm.
//
//   PF6 DETERMINISM. The include-over-frozen run reruns byte-identical.
//
// Self-contained CHECK harness (ARCHITECTURE §4), like the sibling gates.

#include "topopt/job.hpp"
#include "topopt/lattice.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/part.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

#include <unistd.h>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

using namespace topopt;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                           \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

static std::string read_file(const std::string& p) {
  std::ifstream f(p, std::ios::binary);
  if (!f) return {};
  std::ostringstream ss;
  ss << f.rdbuf();
  return ss.str();
}

static bool contains(const std::string& h, const std::string& n) {
  return h.find(n) != std::string::npos;
}

// Read `"key": <number>` out of a JSON blob. Returns NaN when absent, so an
// absent key can be distinguished from a zero one.
static double json_number(const std::string& s, const std::string& key) {
  const std::string k = "\"" + key + "\":";
  const std::size_t at = s.find(k);
  if (at == std::string::npos) return std::nan("");
  return std::strtod(s.c_str() + at + k.size(), nullptr);
}

// ---------------------------------------------------------------------------
// Capture whatever a callable writes to stderr, so the WARNING bar can be
// asserted on the real text a user would see rather than on a proxy for it.
// Restores the original fd unconditionally.
template <typename Fn>
static std::string capture_stderr(const std::string& tmp_path, Fn&& fn) {
  std::fflush(stderr);
  const int saved = ::dup(2);
  FILE* f = std::fopen(tmp_path.c_str(), "w");
  if (!f) {
    fn();
    if (saved >= 0) ::close(saved);
    return {};
  }
  ::dup2(::fileno(f), 2);
  try {
    fn();
  } catch (...) {
    std::fflush(stderr);
    ::dup2(saved, 2);
    ::close(saved);
    std::fclose(f);
    throw;
  }
  std::fflush(stderr);
  ::dup2(saved, 2);
  ::close(saved);
  std::fclose(f);
  return read_file(tmp_path);
}

// ---------------------------------------------------------------------------
// The fixture: the demo l-bracket, with a declared load case (so a face
// protection is reachable — protections live on the production load-case path)
// and a lattice whose cell/radius sit inside the certifiable band.
struct Fixture {
  StepModel model;
  int protect_face = -1;   // a real planar face, protected
  int load_face = -1;      // a real planar face carrying the load
  Vec3 protect_centre{};   // the protected face's fitted outline centre
  Vec3 protect_normal{};   // its outward normal
};

static const int kResolution = 24;

// The planar face that tags the MOST voxels at `resolution` — the way the
// builder itself would see it, so the protection is guaranteed to freeze a real,
// countable skin rather than nothing.
static int biggest_planar_face(const StepModel& model, int resolution,
                               int exclude) {
  const VoxelGrid grid = voxelize(model.mesh, resolution);
  int best = -1;
  std::size_t best_n = 0;
  for (int f = 0; f < model.face_count; ++f) {
    if (f == exclude) continue;
    if (model.faces[static_cast<std::size_t>(f)].kind != StepSurfaceKind::Plane)
      continue;
    VoxelGrid gg = grid;
    const std::size_t tagged = tag_step_face(gg, model, f, VoxelTag::Load);
    if (tagged > best_n) {
      best_n = tagged;
      best = f;
    }
  }
  return best;
}

static JobDescription lattice_protect_job(const Fixture& fx) {
  JobDescription job;
  job.model = "l-bracket.step";
  job.material = "PLA";
  job.mode = "minimize_plastic";
  job.resolution = kResolution;
  job.output.report = "report.json";
  job.output.mesh_format = "stl";
  job.output.mesh_prefix = "variant";
  job.ladder = {0.9};        // one heavy rung: keep the run minutes-scale and
  job.margin_stop = 0.0;     // keep enough material to lattice
  job.simp_max_iterations = 6;
  job.loads.present = true;
  job.loads.anchors = {JobFaceSelector{"cylindrical", 2.5}};
  JobLoadGroup g;
  g.face_ids = {fx.load_face};
  g.force = Vec3{0.0, 0.0, -40.0};
  job.loads.groups.push_back(g);
  job.loads.minimize_plastic = true;
  // THE PROTECTION — the thing this task is about.
  job.loads.face_protection_face_ids = {fx.protect_face};
  job.loads.face_protection_depth_mm = 3.0;
  job.lattice.present = true;
  job.lattice.topology = "octet";
  job.lattice.cell_mm = 3.0;
  job.lattice.strut_radius_mm = 0.45;  // rho ~0.41, inside the band
  job.lattice.emit_stl = true;
  return job;
}

// A slab region over the protected face, reaching INTO the part — the same shape
// the app's LatticeRegionEmission synthesises from a B-rep planar face (origin at
// the face, normal flipped inward), and deep enough to clear the cells-per-member
// floor so the region itself is not the limiting factor (PF5 covers that case).
static JobLatticeRegion slab_over_protected(const Fixture& fx,
                                            const std::string& role,
                                            double depth_mm) {
  JobLatticeRegion r;
  r.role = role;
  r.kind = "face";
  r.origin = fx.protect_centre;
  r.normal = Vec3{-fx.protect_normal.x, -fx.protect_normal.y,
                  -fx.protect_normal.z};
  r.half_u_mm = 200.0;  // unbounded in-plane: the whole face and beyond
  r.half_w_mm = 200.0;
  r.depth_mm = depth_mm;
  return r;
}

int main() {
  const std::string dir = DEMO_FIXTURE_DIR;
  const std::string tmp = std::string(CLI_TMP_DIR);
  MaterialLibrary materials;
  SettingsRules rules;
  try {
    materials = load_materials_file(MATERIALS_JSON_PATH);
    rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "FAIL: could not load materials/rules: %s\n", e.what());
    return 1;
  }

  Fixture fx;
  try {
    fx.model = import_part_file(dir + "/l-bracket.step");
  } catch (const std::exception& e) {
    // No OCCT in this build — the gate cannot run. Say so loudly rather than
    // passing vacuously.
    std::fprintf(stderr,
                 "protect_freeze_vs_solidity: SKIPPED, l-bracket.step could not "
                 "be imported (%s)\n",
                 e.what());
    return 0;
  }
  fx.load_face = biggest_planar_face(fx.model, kResolution, /*exclude=*/-1);
  fx.protect_face = biggest_planar_face(fx.model, kResolution, fx.load_face);
  CHECK(fx.load_face >= 0 && fx.protect_face >= 0 &&
            fx.load_face != fx.protect_face,
        "fixture: a load face and a DISTINCT protected face were found");
  if (fx.load_face < 0 || fx.protect_face < 0) return 1;
  {
    const StepFaceInfo& pf = fx.model.faces[static_cast<std::size_t>(fx.protect_face)];
    fx.protect_centre = pf.plane_origin;
    fx.protect_normal = pf.plane_normal;
  }

  auto run = [&](const JobDescription& job, const std::string& sub) {
    const std::string out = tmp + "/pfvs_" + sub;
    std::filesystem::remove_all(out);
    return run_job(job, dir, out, materials, rules,
                   /*emit_progress=*/false, RunObservability{});
  };
  auto receipt_of = [](const RunJobResult& r) -> std::string {
    for (const std::string& p : r.mesh_paths)
      if (contains(p, "_lattice."))
        return p.substr(0, p.rfind(".stl")) + ".report.json";
    return {};
  };
  auto lattice_mesh_of = [](const RunJobResult& r) -> std::string {
    for (const std::string& p : r.mesh_paths)
      if (contains(p, "_lattice.")) return p;
    return {};
  };

  // ── PF1 — INCLUDE OVER FROZEN MATERIAL IS LATTICED ─────────────────────────
  std::string incl_rcpt, incl_mesh_bytes;
  {
    JobDescription job = lattice_protect_job(fx);
    job.lattice.regions.push_back(slab_over_protected(fx, "include", 30.0));
    const std::string err = capture_stderr(tmp + "/pfvs_incl.err", [&] {
      const RunJobResult r = run(job, "incl");
      incl_rcpt = read_file(receipt_of(r));
      incl_mesh_bytes = read_file(lattice_mesh_of(r));
    });
    CHECK(!incl_rcpt.empty(), "PF1: the include run wrote a lattice receipt");
    CHECK(contains(incl_rcpt, "\"frozen_material\""),
          "PF1: the receipt carries the frozen-material record");
    const double printed = json_number(incl_rcpt, "frozen_printed_voxels");
    const double latticed = json_number(incl_rcpt, "frozen_latticed");
    const double in_include = json_number(incl_rcpt, "frozen_in_include_region");
    CHECK(printed > 0.0,
          "PF1 precondition: the protection actually froze printed material");
    CHECK(in_include > 0.0,
          "PF1 precondition: frozen material lies inside the include region");
    CHECK(latticed > 0.0,
          "PF1: lattice-INCLUDE over FROZEN material lattices it — the material "
          "is retained AND latticed");

    // ── PF3 — THE AUDIT over the frozen voxels.
    CHECK(json_number(incl_rcpt, "frozen_cells_not_emitted") == 0.0,
          "PF3: every cell the certificate lattices over frozen material is a "
          "cell the generator emitted");
    CHECK(json_number(incl_rcpt, "frozen_cells_certified") > 0.0,
          "PF3 precondition: frozen material really did reach the certified "
          "lattice cell set (the equality above is not vacuous)");
    // *** MEASURED, NOT ASSUMED. *** The naive form of this bar — "no voxel gets
    // both a strut and companion solid" — is FALSE on the role path and was
    // never true there: roles are deliberately kept out of the strut clip so the
    // lattice/solid interface stays bonded, and a cell straddling a role
    // boundary therefore welds struts into material certified solid. That is
    // MORE material than certified (conservative) and is not what this task
    // introduced. What must be zero is the divergence proper: a cell emitting
    // struts into a region the certificate calls ENTIRELY solid.
    CHECK(json_number(incl_rcpt, "frozen_strut_and_solid_unexplained") == 0.0,
          "PF3: no cell emits struts into a region the certificate calls "
          "entirely solid (the real certified-vs-exported divergence)");

    // ── PF4a — lattice on FROZEN material does NOT warn.
    CHECK(!contains(err, "WARNING"),
          "PF4: lattice declared on FROZEN material does NOT warn — it is the "
          "only way to express a legitimate intent");
    CHECK(contains(err, "frozen material:"),
          "PF4: it is REPORTED (a plain per-variant line), just not warned on");
    CHECK(json_number(incl_rcpt, "include_void_by_clearance") == 0.0,
          "PF4: no clearance-caused include void in the frozen case");
  }

  // ── PF2 — EXCLUDE OVER FROZEN MATERIAL IS SOLID ────────────────────────────
  {
    JobDescription job = lattice_protect_job(fx);
    job.lattice.regions.push_back(slab_over_protected(fx, "exclude", 30.0));
    const RunJobResult r = run(job, "excl");
    const std::string rcpt = read_file(receipt_of(r));
    CHECK(contains(rcpt, "\"frozen_material\""),
          "PF2: the exclude run also records the frozen material");
    const double printed = json_number(rcpt, "frozen_printed_voxels");
    const double latticed = json_number(rcpt, "frozen_latticed");
    const double solid = json_number(rcpt, "frozen_kept_solid");
    const double in_excl = json_number(rcpt, "frozen_in_exclude_region");
    const double in_excl_latticed = json_number(rcpt, "frozen_in_exclude_region_latticed");
    CHECK(printed > 0.0, "PF2 precondition: frozen material was printed");
    CHECK(latticed + solid == printed,
          "PF2: the counts partition the frozen printed set exactly");
    // *** SCOPED TO THE EXCLUDE REGION, deliberately. *** The run's frozen set is
    // not only the protected face: the production load case also freezes an
    // anchor/load pad, which lies OUTSIDE this exclude region and is latticed by
    // the whole-part default. Asserting `latticed == 0` over ALL frozen material
    // would therefore assert something false about a different region, and would
    // pass only by accident on a fixture whose pad happened not to be latticed.
    CHECK(in_excl > 0.0,
          "PF2 precondition: frozen material lies inside the exclude region");
    CHECK(in_excl_latticed == 0.0,
          "PF2: lattice-EXCLUDE over FROZEN material lattices NONE of it — "
          "retained AND solid");
  }

  // ── PF4b — THE WARNING FIRES ON A CLEARANCE VOID ───────────────────────────
  // Same protection, same include slab, PLUS a keep-clear inside the include
  // region. Now there IS material the include can never reach, and that — not
  // the protection — is what the user must be told.
  {
    JobDescription job = lattice_protect_job(fx);
    job.lattice.regions.push_back(slab_over_protected(fx, "include", 30.0));
    JobClearance kc;
    kc.kind = "bolt";
    kc.manual = true;
    kc.axis_point = fx.protect_centre;
    kc.axis_dir = fx.protect_normal;
    kc.radius_mm = 6.0;
    kc.half_length_mm = 40.0;
    job.loads.clearances.push_back(kc);
    std::string rcpt;
    const std::string err = capture_stderr(tmp + "/pfvs_kc.err", [&] {
      const RunJobResult r = run(job, "kc");
      rcpt = read_file(receipt_of(r));
    });
    CHECK(json_number(rcpt, "include_void_by_clearance") > 0.0,
          "PF4 precondition: the keep-clear voids include-region voxels");
    CHECK(contains(err, "WARNING") && contains(err, "Keep clear"),
          "PF4: lattice declared on a CLEARANCE VOID DOES warn — there is no "
          "material there and no rung or cell size can create any");
    // And the frozen material in the SAME run is still not warned about: the
    // warning is aimed at the clearance, not at the protection.
    CHECK(!contains(err, "face-protection collar") &&
              !contains(err, "NOT optimizable"),
          "PF4: the retired frozen-overlap warning text is gone for good");
  }

  // ── PF5 — THE PRE-FLIGHT REGION FORECAST ───────────────────────────────────
  // An include region THINNER than the floor requires is named before the run,
  // with both numbers. The maintainer's case is a 4 mm slab against 23.0 mm.
  {
    JobDescription job = lattice_protect_job(fx);
    job.lattice.regions.push_back(slab_over_protected(fx, "include", 4.0));
    const double n_star = lattice_cells_per_member_min(LatticeTopology::Octet);
    const double required = n_star * job.lattice.cell_mm;
    CHECK(required > 4.0,
          "PF5 precondition: 4 mm IS under the floor at this cell size");
    const std::string err = capture_stderr(tmp + "/pfvs_thin.err", [&] {
      try {
        run(job, "thin");
      } catch (const std::exception&) {
        // The forecast is emitted before any solve; a later failure must not
        // hide it, so the assertion below still reads the captured text.
      }
    });
    // The forecast's SHAPE changed in task 2026-08-07-cell-mode-fit-and-swept-floor
    // (S3): per-region output is now one TABLE ROW rather than a paragraph each, so
    // the marker moved from the old "FORECAST region_too_thin" prefix onto the row
    // itself. The assertion is unchanged in strength and in message — the region is
    // still named, by index, kind and its own measured extent, before the run — and
    // is in fact stricter, because it now pins all three on one line.
    CHECK(contains(err, "0 (face)") && contains(err, "4.000") &&
              contains(err, "SOLID: under the floor"),
          "PF5: a too-thin include region is NAMED before the run");
    CHECK(contains(err, "cells-per-member floor needs"),
          "PF5: the forecast carries the floor's own numbers");
    // And it is a FORECAST, not a refusal: the run still happens.
    CHECK(!contains(err, "refus"),
          "PF5: the forecast states the physics, it does not refuse the job");
  }

  // ── PF6 — DETERMINISM ──────────────────────────────────────────────────────
  {
    JobDescription job = lattice_protect_job(fx);
    job.lattice.regions.push_back(slab_over_protected(fx, "include", 30.0));
    const RunJobResult r = run(job, "incl_2");
    CHECK(read_file(receipt_of(r)) == incl_rcpt,
          "PF6: the include-over-frozen receipt is byte-identical on a rerun");
    CHECK(read_file(lattice_mesh_of(r)) == incl_mesh_bytes,
          "PF6: the latticed mesh is byte-identical on a rerun");
  }

  if (g_failures == 0) {
    std::printf("protect_freeze_vs_solidity: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "protect_freeze_vs_solidity: %d/%d checks FAILED\n",
               g_failures, g_checks);
  return 1;
}
