// Face-protection parity + builder contract (handoff 124 — preserve-skin) on the
// SHARED build_production_loadcase seam the app and the CLI both route through,
// driven on the demo l-bracket. Complements test_face_protection (which proves the
// solver mechanism on a hand-built grid); here we prove the BUILDER wiring:
//
//   (1) THE ONE RULE — no protection declared => byte-identical to before. With
//       minimize_plastic=false (no anchor pad) an empty protection list leaves
//       options.design_mask EMPTY and face_protection_reports EMPTY, and a full
//       minimize_plastic run is bit-identical run-to-run.
//
//   (2) A declared protection freezes the face's skin FrozenSolid: the report
//       names the face, counts voxels_frozen > 0, records the depth in voxels
//       (round(depth_mm / spacing), floored at 1), and design_mask carries exactly
//       that many FrozenSolid voxels (single face, no pad) — the footprint of the
//       preserved skin.
//
//   (3) THE HONEST EDGE — a protection whose requested depth exceeds the face's
//       own solid thickness freezes WHAT EXISTS and SAYS so: thinner_than_depth is
//       true and voxels_frozen is bounded by the part's solid (no silent
//       over-claim beyond the geometry).
//
// Drives OCCT (STEP import) + Eigen (minimize_plastic), gated on both in CMake.

#include "topopt/loadcase.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

using topopt::build_production_loadcase;
using topopt::MaskValue;
using topopt::Material;
using topopt::MaterialLibrary;
using topopt::MinimizePlasticResult;
using topopt::ProductionLoadCase;
using topopt::ProductionRunSetup;
using topopt::SettingsRules;
using topopt::StepModel;
using topopt::StepSurfaceKind;
using topopt::Vec3;

namespace { int g_failures = 0; int g_checks = 0; }
#define CHECK(cond, msg)                \
  do {                                  \
    ++g_checks;                         \
    if (!(cond)) {                      \
      std::printf("FAIL: %s\n", msg);   \
      ++g_failures;                     \
    }                                   \
  } while (0)

namespace {

// The l-bracket load case: both holes anchored, the planar faces carry a downward
// force. minimize_plastic is set per test (false isolates the protection from the
// anchor pad; true walks the ladder).
ProductionLoadCase make_load_case(const StepModel& model, bool minimize_plastic) {
  ProductionLoadCase lc;
  ProductionLoadCase::LoadGroup g;
  for (int f = 0; f < model.face_count; ++f) {
    const auto& info = model.faces[static_cast<std::size_t>(f)];
    if (info.kind == StepSurfaceKind::Cylinder)
      lc.anchor_face_ids.push_back(f);
    else if (info.kind == StepSurfaceKind::Plane)
      g.face_ids.push_back(f);
  }
  g.force = Vec3{0.0, 0.0, -50.0};
  lc.load_groups.push_back(g);
  lc.minimize_plastic = minimize_plastic;
  lc.build_dir = Vec3{0.0, 0.0, 1.0};
  return lc;
}

// The first planar face id (a flat mounting face to protect).
int first_plane(const StepModel& model) {
  for (int f = 0; f < model.face_count; ++f)
    if (model.faces[static_cast<std::size_t>(f)].kind == StepSurfaceKind::Plane)
      return f;
  return -1;
}

std::size_t count_frozen_solid(const topopt::DesignMask& m) {
  std::size_t n = 0;
  for (const MaskValue v : m) if (v == MaskValue::FrozenSolid) ++n;
  return n;
}

bool densities_identical(const MinimizePlasticResult& a,
                         const MinimizePlasticResult& b) {
  if (a.evaluated.size() != b.evaluated.size()) return false;
  for (std::size_t i = 0; i < a.evaluated.size(); ++i) {
    const auto& ra = a.evaluated[i].optimization.physical_density;
    const auto& rb = b.evaluated[i].optimization.physical_density;
    if (ra.size() != rb.size()) return false;
    for (std::size_t k = 0; k < ra.size(); ++k)
      if (ra[k] != rb[k]) return false;
  }
  return true;
}

}  // namespace

int main() {
  const std::string demo_dir = DEMO_FIXTURE_DIR;
  const StepModel model = topopt::import_step_file(demo_dir + "/l-bracket.step");
  const MaterialLibrary materials = topopt::load_materials_file(MATERIALS_JSON_PATH);
  const Material material = materials.at("PLA");
  const SettingsRules rules = topopt::load_settings_rules_file(SETTINGS_RULES_PATH);
  const int resolution = 24;

  const int plane = first_plane(model);
  CHECK(plane >= 0, "l-bracket exposes a planar face to protect");

  // ── (1) THE ONE RULE: no protection => no reports, and the overlay is the
  //        ANCHOR PAD and nothing else.
  //
  // This used to read "no protection + no pad => the overlay is EMPTY", isolating
  // the protection by setting minimize_plastic = false, which used to mean "no
  // anchor pad". Task 2026-08-03-growth-ladder ended that coupling on purpose and
  // by measurement (loadcase.hpp kGrowthPathAnchorPad): the pad is a safety
  // feature, it is built in BOTH modes now, and there is no mode with no pad. So
  // the rule is stated the way it is actually true — an empty protection list
  // contributes NOTHING — and checked as a DIFFERENCE against the pad baseline
  // below, which is a stronger statement than the old count coincidence was.
  ProductionLoadCase lc_none = make_load_case(model, /*minimize_plastic=*/false);
  ProductionRunSetup s_none = build_production_loadcase(model, resolution, lc_none);
  const std::size_t pad_only = count_frozen_solid(s_none.options.design_mask);
  CHECK(pad_only > 0,
        "no protection => the overlay is the anchor pad alone, and it is real");
  CHECK(s_none.face_protection_reports.empty(),
        "no protection declared => no face-protection reports");

  // ── (2) A declared protection freezes the face's skin FrozenSolid. ────────
  ProductionLoadCase lc_prot = make_load_case(model, /*minimize_plastic=*/false);
  lc_prot.face_protection_face_ids.push_back(plane);
  lc_prot.face_protection_depth_mm = 5.0;
  ProductionRunSetup s_prot = build_production_loadcase(model, resolution, lc_prot);
  const double spacing = s_prot.grid.spacing;
  const int expect_depth =
      std::max(1, static_cast<int>(std::lround(5.0 / spacing)));

  CHECK(s_prot.face_protection_reports.size() == 1, "one face-protection report");
  if (!s_prot.face_protection_reports.empty()) {
    const auto& rep = s_prot.face_protection_reports.front();
    CHECK(rep.face_id == plane, "the report names the protected face");
    CHECK(rep.voxels_frozen > 0, "the protection froze part voxels");
    CHECK(rep.depth_voxels == expect_depth,
          "depth_voxels == round(depth_mm / spacing), floored at 1");
    CHECK(!rep.thinner_than_depth,
          "a 5mm skin on a thicker face is NOT flagged thinner-than-depth");
    // THE OVERLAY IS EXACTLY (anchor pad) ∪ (this protection's own skin) — an
    // exact SET equality, checked voxel by voxel, not a count coincidence. The
    // protection's own skin is rebuilt here through the SAME primitive the builder
    // uses (mask_step_face at the reported depth), so the assertion binds on the
    // real footprint rather than on a number the builder also produced.
    topopt::DesignMask own = topopt::make_active_mask(s_prot.grid);
    const std::size_t own_frozen = topopt::mask_step_face(
        s_prot.grid, model, plane, MaskValue::FrozenSolid, rep.depth_voxels, own);
    CHECK(own_frozen == rep.voxels_frozen,
          "the report's count IS the face's own footprint x depth ∩ part solid");
    CHECK(s_prot.options.design_mask.size() == s_none.options.design_mask.size() &&
              own.size() == s_prot.options.design_mask.size(),
          "the pad-only and protected overlays cover the same grid");
    bool exact_union = s_prot.options.design_mask.size() == own.size() &&
                       s_none.options.design_mask.size() == own.size();
    if (exact_union)
      for (std::size_t i = 0; i < own.size(); ++i) {
        const bool want = s_none.options.design_mask[i] == MaskValue::FrozenSolid ||
                          own[i] == MaskValue::FrozenSolid;
        if ((s_prot.options.design_mask[i] == MaskValue::FrozenSolid) != want) {
          exact_union = false;
          break;
        }
      }
    CHECK(exact_union,
          "design_mask is EXACTLY the anchor pad ∪ the reported frozen skin — the "
          "protection adds its own voxels and nothing else");
    // The overlay grows by AT MOST the protection's own footprint, and by less
    // when the pad already holds part of it. On THIS fixture it grows by ZERO: the
    // load group covers every planar face, so the protected face is also a
    // RETAINED LOAD face, whose 3-voxel pad already subsumes the 2-voxel skin. That
    // is the correct behaviour and worth stating — the exact-union check above is
    // what carries the content, and a "must grow" assertion here would be asserting
    // a property of this fixture's face choice, not of the feature.
    const std::size_t prot_total = count_frozen_solid(s_prot.options.design_mask);
    CHECK(prot_total >= pad_only && prot_total <= pad_only + rep.voxels_frozen,
          "the protection grows the overlay by at most its own footprint");
    std::printf("[124] overlay: pad-only=%zu  with-protection=%zu  (+%zu of the "
                "%zu-voxel skin; the rest was already in the pad)\n",
                pad_only, prot_total, prot_total - pad_only, rep.voxels_frozen);
  }
  CHECK(!s_prot.options.design_mask.empty(),
        "a declared protection builds a non-empty FrozenSolid overlay");

  // ── (3) THE HONEST EDGE: depth beyond the face's solid freezes what exists. ─
  ProductionLoadCase lc_thin = make_load_case(model, /*minimize_plastic=*/false);
  lc_thin.face_protection_face_ids.push_back(plane);
  lc_thin.face_protection_depth_mm = 1000.0;  // far exceeds any part thickness
  ProductionRunSetup s_thin = build_production_loadcase(model, resolution, lc_thin);
  CHECK(s_thin.face_protection_reports.size() == 1, "one report (deep protection)");
  if (!s_thin.face_protection_reports.empty()) {
    const auto& rep = s_thin.face_protection_reports.front();
    CHECK(rep.thinner_than_depth,
          "(honest) a depth exceeding the face's solid is flagged thinner-than-depth");
    CHECK(rep.voxels_frozen > 0 &&
              rep.voxels_frozen <= s_thin.grid.solid_count(),
          "(honest) frozen voxels are bounded by the part's own solid, no over-claim");
  }

  // ── THE ONE RULE, run level: no-protection path is bit-identical run-to-run. ─
  ProductionRunSetup s_none_a = build_production_loadcase(model, resolution, lc_none);
  ProductionRunSetup s_none_b = build_production_loadcase(model, resolution, lc_none);
  s_none_a.options.simp.max_iterations = 8;
  s_none_b.options.simp.max_iterations = 8;
  const MinimizePlasticResult r_a = topopt::minimize_plastic(
      s_none_a.grid, material, "PLA", s_none_a.bcs, rules, s_none_a.options);
  const MinimizePlasticResult r_b = topopt::minimize_plastic(
      s_none_b.grid, material, "PLA", s_none_b.bcs, rules, s_none_b.options);
  CHECK(densities_identical(r_a, r_b),
        "no-protection run is bit-identical run-to-run (empty list == today)");

  if (!s_prot.face_protection_reports.empty())
    std::printf("[124] protect face=%d depth=%d vox frozen=%zu (spacing=%.4f)\n",
                plane, s_prot.face_protection_reports.front().depth_voxels,
                s_prot.face_protection_reports.front().voxels_frozen, spacing);
  if (!s_thin.face_protection_reports.empty())
    std::printf("[124] thin-face: frozen=%zu of solid=%zu thinner=%d\n",
                s_thin.face_protection_reports.front().voxels_frozen,
                s_thin.grid.solid_count(),
                s_thin.face_protection_reports.front().thinner_than_depth ? 1 : 0);

  if (g_failures == 0) {
    std::printf("face_protection_parity (124): all %d checks passed\n", g_checks);
    return 0;
  }
  std::printf("face_protection_parity: %d/%d CHECK(s) FAILED\n", g_failures, g_checks);
  return g_failures == 0 ? 0 : 1;
}
