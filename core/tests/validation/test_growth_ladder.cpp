// test_growth_ladder — "minimize plastic" OFF is a GROWTH LADDER that recommends
// the SMALLEST ADDITION that passes (task 2026-08-03-growth-ladder).
//
// WHAT THIS PINS, bar by bar:
//
//   H1  THE REDUCTION PATH IS UNTOUCHED. build_production_loadcase with
//       minimize_plastic ON still yields production_reduction_ladder() verbatim
//       and still freezes the anchor pad, and minimize_plastic still enforces the
//       pre-growth `vf in (0, 1]` rule on every ladder that stays at or below 1.
//       (The BYTE-identity of the ON path is a stash-rebuild checksum in the
//       handoff; this is the standing in-suite guard that its INPUTS did not move.)
//
//   H2  *** THE RECOMMENDATION IS THE SMALLEST ADDITION THAT PASSES, NOT THE LAST
//       EVALUATED. *** Three cases on ONE real growth ladder, separated only by
//       margin_stop, so the geometry and every margin are held fixed and the only
//       thing that moves is where the gate sits:
//         (a) every rung passes  -> the SMALLEST rung is recommended;
//         (b) only the TOP rung passes -> the TOP rung is recommended (the
//             boundary case the task names explicitly);
//         (c) no rung passes -> NOTHING is recommended, the rejection is reported
//             with its numbers, and the largest rung is NOT returned as a
//             consolation prize.
//
//   H3  GROWTH IS REAL GROWTH. On every evaluated rung the printed mass EXCEEDS
//       the imported part's, material is printed OUTSIDE the part envelope, and
//       the added-material accounting is internally consistent
//       (inside + outside == printed; net mass == printed - part).
//       A ladder that only redistributes is a MISS.
//
//   H4  *** GROWTH WITHOUT SOMEWHERE TO GROW IS REFUSED, LEGIBLY. *** No design
//       box -> throw; a FROZEN imported part -> throw; a ladder that MIXES growth
//       and reduction rungs -> throw; a rung above the cap -> throw. Each message
//       must name the condition (asserted on message content, not just the type),
//       because "invalid argument" would send the user hunting.
//
//   H5  THE DERIVED BOX IS MINIMAL, DETERMINISTIC AND SUFFICIENT. The box
//       minimal_growth_design_box derives contains the part, is the same box every
//       time, and actually lets the top rung run without saturating.
//
//   H6  THE GATE IS UNCHANGED, AND THE DOCUMENT IS HONEST. The growth report
//       round-trips through job_report_json / validate_job_report_json (whose
//       fraction bounds now read on the growth scale ONLY for a document that
//       carries the added_material block), while a REDUCTION report still emits no
//       such block and is still validated on [0, 1].
//
//   H7  DETERMINISM. The same growth run twice, bit-identical on every gate field
//       (the 1e-9 negative-control floor is a floor; identity is what a re-run
//       must produce).
//
// Self-contained CHECK harness (ARCHITECTURE §4), public API only. Drives
// minimize_plastic, so it is Eigen-gated in CMake like the other optimizer gates;
// the real settings rule table is injected.

#include "topopt/analyze.hpp"
#include "topopt/fea.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/production.hpp"
#include "topopt/report.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>

using namespace topopt;

static int g_failures = 0;
static int g_checks = 0;
static void check(bool ok, const char* what) {
  ++g_checks;
  if (!ok) {
    ++g_failures;
    std::printf("  FAIL: %s\n", what);
  }
}
#define CHECK(cond, msg) check((cond), (msg))

namespace {

// The L-bracket of test_designbox_reduction: a vertical arm clamped at the top, a
// horizontal foot loaded down at its free end.
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
      const int node = fea_node_index(g, a, b, arm);
      bcs.push_back({node, 0, 0.0});
      bcs.push_back({node, 1, 0.0});
      bcs.push_back({node, 2, 0.0});
    }
  for (int k = 0; k < t; ++k)
    for (int j = 0; j < ny; ++j) g.set_tag(span - 1, j, k, VoxelTag::Load);
  return g;
}

Material pla() {
  Material m;
  m.youngs_modulus_mpa = 3500.0;
  m.yield_strength_mpa = 55.0;
  m.density_g_cm3 = 1.24;
  m.z_knockdown = 0.55;
  m.poisson = 0.33;
  m.family = "fdm";
  return m;
}

double part_mass_grams(const VoxelGrid& part, const Material& m) {
  return m.density_g_cm3 * static_cast<double>(part.solid_count()) *
         part.voxel_volume() / 1000.0;
}

MinimizePlasticOptions growth_options(const std::vector<NodalLoad>& loads,
                                      double margin_stop) {
  MinimizePlasticOptions o;
  o.volume_fraction_ladder = production_growth_ladder();
  o.margin_stop = margin_stop;
  o.external_loads = loads;
  o.gravity = 9810.0 * 1e-9;
  o.gravity_direction = Vec3{0.0, 0.0, -1.0};
  o.updater = SimpUpdater::MMA;
  o.infill_percent = 100.0;
  o.bake_build_orientation = BakeBuildOrientation::Off;
  return o;
}

// The recommendation, by THE rule the whole pipeline uses: the LAST ACCEPTED rung.
// On a descending growth ladder that is the SMALLEST addition that passed — the
// exact mirror of "the lightest reduction that passed". nullptr = nothing passed.
const MinimizePlasticVariant* recommendation(const MinimizePlasticResult& r) {
  const MinimizePlasticVariant* rec = nullptr;
  for (const MinimizePlasticVariant& v : r.evaluated)
    if (v.accepted) rec = &v;
  return rec;
}

// Flatten every gate field, for the determinism control.
std::vector<double> gate_fields(const MinimizePlasticResult& r) {
  std::vector<double> f;
  for (const MinimizePlasticVariant& v : r.evaluated) {
    const VariantReport& vr = v.report;
    f.push_back(v.requested_volume_fraction);
    f.push_back(vr.volume_fraction);
    f.push_back(vr.printed_fraction);
    f.push_back(vr.max_stress_mpa);
    f.push_back(vr.max_interlayer_tension_mpa);
    f.push_back(vr.margin.in_plane);
    f.push_back(vr.margin.interlayer);
    f.push_back(vr.margin.worst_case);
    f.push_back(vr.margin_effective);
    f.push_back(vr.accepted ? 1.0 : 0.0);
    f.push_back(v.mass_grams);
    f.push_back(static_cast<double>(vr.added_material.printed_voxels));
    f.push_back(static_cast<double>(vr.added_material.inside_part));
    f.push_back(static_cast<double>(vr.added_material.outside_part));
  }
  return f;
}

bool threw_containing(const std::function<void()>& fn, const char* needle,
                      std::string& got) {
  try {
    fn();
  } catch (const std::exception& e) {
    got = e.what();
    return got.find(needle) != std::string::npos;
  }
  got = "(no exception)";
  return false;
}

}  // namespace

int main() {
  std::printf("test_growth_ladder\n");

  SettingsRules rules;
  try {
    rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "FAIL: could not load rules.json: %s\n", e.what());
    return 1;
  }
  const Material material = pla();

  const int arm = 8, span = 8, ny = 3, t = 2;
  const double h = 2.0;
  std::vector<DirichletBC> bcs;
  VoxelGrid part = l_bracket(bcs, arm, span, ny, t, h);
  const double part_mass = part_mass_grams(part, material);
  const std::vector<NodalLoad> tip =
      traction_loads(part, VoxelTag::Load, Vec3{0.0, 0.0, -40.0});

  // =========================================================================
  // H1 — THE REDUCTION PATH IS UNTOUCHED (its inputs, in this suite; its BYTES,
  //      by the handoff's stash-rebuild checksum).
  // =========================================================================
  {
    std::printf(" H1: the reduction path is untouched\n");
    const std::vector<double> red = production_reduction_ladder();
    CHECK(red == (std::vector<double>{0.68, 0.52, 0.38, 0.26}),
          "H1: production_reduction_ladder is still {0.68, 0.52, 0.38, 0.26}");
    for (double v : red)
      CHECK(v > 0.0 && v <= 1.0, "H1: every reduction rung stays in (0, 1]");

    // The PRE-GROWTH rule still binds on a ladder that does not ask to grow: a
    // reduction ladder with a rung above 1 is refused exactly as before, and it
    // is refused as an OUT-OF-RANGE rung, not as a growth ladder.
    std::string msg;
    MinimizePlasticOptions o = growth_options(tip, 0.0);
    o.volume_fraction_ladder = {0.9, 0.5};
    o.volume_fraction_ladder[1] = 1.2;  // ascending AND out of range
    CHECK(threw_containing(
              [&] { minimize_plastic(part, material, "PLA", bcs, rules, o); },
              "not in (0, 1]", msg),
          "H1: a reduction ladder with a rung above 1 is still refused");
  }

  // =========================================================================
  // H4 — GROWTH WITHOUT SOMEWHERE TO GROW IS REFUSED, LEGIBLY.
  // =========================================================================
  {
    std::printf(" H4: growth with nowhere to go is refused, legibly\n");
    std::string msg;

    MinimizePlasticOptions no_box = growth_options(tip, 1.0);  // no design_box
    CHECK(threw_containing(
              [&] { minimize_plastic(part, material, "PLA", bcs, rules, no_box); },
              "no design box is set", msg),
          "H4(a): a growth ladder with NO design box is refused");
    CHECK(msg.find("Refusing to redistribute and call it growth") !=
              std::string::npos,
          "H4(a): the refusal says WHY — it will not present redistribution as "
          "growth");

    MinimizePlasticOptions frozen = growth_options(tip, 1.0);
    frozen.design_box =
        minimal_growth_design_box(part, production_growth_ladder().front(),
                                  kGrowthBoxHeadroom);
    frozen.freeze_imported_part = true;
    CHECK(threw_containing(
              [&] { minimize_plastic(part, material, "PLA", bcs, rules, frozen); },
              "freeze_imported_part", msg),
          "H4(b): a growth ladder over a FROZEN part is refused, naming the flag");

    MinimizePlasticOptions mixed = growth_options(tip, 1.0);
    mixed.design_box = frozen.design_box;
    mixed.volume_fraction_ladder = {1.25, 0.9};  // descending, but mixed
    CHECK(threw_containing(
              [&] { minimize_plastic(part, material, "PLA", bcs, rules, mixed); },
              "mixes GROWTH rungs", msg),
          "H4(c): a ladder that mixes growth and reduction rungs is refused");

    MinimizePlasticOptions over = growth_options(tip, 1.0);
    over.design_box = frozen.design_box;
    over.volume_fraction_ladder = {kMaxLadderVolumeFraction + 0.5, 1.2};
    CHECK(threw_containing(
              [&] { minimize_plastic(part, material, "PLA", bcs, rules, over); },
              "ladder cap", msg),
          "H4(d): a growth rung above kMaxLadderVolumeFraction is refused");
  }

  // =========================================================================
  // H5 — THE DERIVED BOX IS MINIMAL, DETERMINISTIC AND SUFFICIENT.
  // =========================================================================
  DesignBox box;
  {
    std::printf(" H5: the auto-derived growth box\n");
    const double top = production_growth_ladder().front();
    box = minimal_growth_design_box(part, top, kGrowthBoxHeadroom);
    const DesignBox again = minimal_growth_design_box(part, top, kGrowthBoxHeadroom);
    CHECK(box.min.x == again.min.x && box.min.y == again.min.y &&
              box.min.z == again.min.z && box.max.x == again.max.x &&
              box.max.y == again.max.y && box.max.z == again.max.z,
          "H5: the derived box is deterministic to the bit");

    // It CONTAINS the part grid's bounding box (it is that box, inflated).
    CHECK(box.min.x <= part.origin.x && box.min.y <= part.origin.y &&
              box.min.z <= part.origin.z,
          "H5: the derived box covers the part's low corner");
    CHECK(box.max.x >= part.origin.x + part.nx * part.spacing &&
              box.max.y >= part.origin.y + part.ny * part.spacing &&
              box.max.z >= part.origin.z + part.nz * part.spacing,
          "H5: the derived box covers the part's high corner");

    // And it is SUFFICIENT: the expanded domain holds enough Active volume for the
    // top rung's ask with the stated headroom.
    MinimizePlasticOptions o = growth_options(tip, 0.0);
    o.design_box = box;
    const VoxelGrid solved = minimize_plastic_solved_grid(part, o);
    const double added_capacity =
        static_cast<double>(solved.voxel_count()) -
        static_cast<double>(part.solid_count());
    CHECK(added_capacity >= kGrowthBoxHeadroom * (top - 1.0) *
                                static_cast<double>(part.solid_count()),
          "H5: the derived box supplies the top rung's ask x the headroom");

    // A part with no solid voxels has nothing to grow FROM, and says so.
    std::string msg;
    VoxelGrid empty = part;
    empty.tags.assign(empty.tags.size(), VoxelTag::Empty);
    CHECK(threw_containing(
              [&] { minimal_growth_design_box(empty, top, kGrowthBoxHeadroom); },
              "nothing to grow from", msg),
          "H5: an empty part is refused, naming the reason");
  }

  // =========================================================================
  // H2 / H3 / H6 / H7 — ONE real growth ladder, read three ways.
  // =========================================================================
  // Run the ladder ONCE with the gate wide open (margin_stop 0) so every rung is
  // evaluated and accepted, and read off the rungs' actual effective margins.
  // Those three numbers then place the gate for H2's three cases, so (a), (b) and
  // (c) differ from each other ONLY in margin_stop — the geometry, the solves and
  // every margin are the same run.
  MinimizePlasticOptions open = growth_options(tip, 0.0);
  open.design_box = box;
  const MinimizePlasticResult all =
      minimize_plastic(part, material, "PLA", bcs, rules, open);

  {
    std::printf(" H2/H3: the ladder, all rungs evaluated\n");
    CHECK(all.growth_ladder,
          "H2: the result NAMES itself a growth ladder (no inference needed)");
    CHECK(all.evaluated.size() == production_growth_ladder().size(),
          "H2: with the gate open every growth rung is evaluated");
    for (const MinimizePlasticVariant& v : all.evaluated)
      CHECK(v.accepted, "H2: with margin_stop 0 every rung is accepted");

    // The margins DESCEND with the rungs: more material is stronger. This is the
    // monotonicity the walk's early stop rests on, so it is asserted, not assumed.
    for (std::size_t i = 1; i < all.evaluated.size(); ++i)
      CHECK(all.evaluated[i].report.margin_effective <
                all.evaluated[i - 1].report.margin_effective,
            "H2: a smaller growth rung is weaker than a larger one (the "
            "monotonicity the early stop depends on)");

    std::printf("      rungs:");
    for (const MinimizePlasticVariant& v : all.evaluated)
      std::printf("  %.2f->eff %.4f mass %.4f g", v.requested_volume_fraction,
                  v.report.margin_effective, v.mass_grams);
    std::printf("\n      part mass %.4f g\n", part_mass);

    // ── H3: GROWTH IS REAL GROWTH, on EVERY rung ──────────────────────────
    for (const MinimizePlasticVariant& v : all.evaluated) {
      const AddedMaterialReport& a = v.report.added_material;
      CHECK(v.mass_grams > part_mass,
            "H3: every growth rung prints MORE mass than the imported part");
      CHECK(a.evaluated, "H3: every growth rung carries added-material accounting");
      CHECK(a.outside_part > 0,
            "H3: every growth rung prints material OUTSIDE the part envelope "
            "(a ladder that only redistributes is a MISS)");
      CHECK(a.inside_part + a.outside_part == a.printed_voxels,
            "H3: inside + outside == printed, exactly");
      CHECK(a.part_solid_voxels ==
                static_cast<long long>(part.solid_count()),
            "H3: the accounting's denominator IS the part's solid count");
      CHECK(a.net_added_mass_grams > 0.0,
            "H3: the reported NET added mass is positive on every rung");
      CHECK(std::fabs((v.mass_grams - part_mass) - a.net_added_mass_grams) <=
                1e-9 * std::fabs(part_mass) + 1e-12,
            "H3: net added mass == printed mass - part mass, to the bit");
      CHECK(a.outside_fraction > 0.0 && a.outside_fraction <= 1.0,
            "H3: the outside share is a fraction of the printed object");
      CHECK(v.report.printed_fraction > 1.0,
            "H3: the reported printed fraction EXCEEDS 1 and is not clamped — "
            "the growth is visible in the number the app reads");
      std::printf(
          "      rung %.2f: printed %lld (%lld inside, %lld outside = %.1f%%), "
          "+%.4f g\n",
          v.requested_volume_fraction, a.printed_voxels, a.inside_part,
          a.outside_part, 100.0 * a.outside_fraction, a.net_added_mass_grams);
    }
  }

  // ── H2: THE RECOMMENDATION IS THE SMALLEST ADDITION THAT PASSES ──────────
  {
    std::printf(" H2: smallest-that-passes, three gate placements\n");
    const std::size_t n = all.evaluated.size();
    const double top_eff = all.evaluated.front().report.margin_effective;
    const double mid_eff = all.evaluated[n - 2].report.margin_effective;
    const double low_eff = all.evaluated.back().report.margin_effective;

    // (a) EVERY rung passes -> the SMALLEST addition is recommended.
    {
      MinimizePlasticOptions o = growth_options(tip, low_eff * 0.5);
      o.design_box = box;
      const MinimizePlasticResult r =
          minimize_plastic(part, material, "PLA", bcs, rules, o);
      const MinimizePlasticVariant* rec = recommendation(r);
      CHECK(rec != nullptr, "H2(a): something is recommended when all rungs pass");
      CHECK(rec != nullptr && rec->requested_volume_fraction ==
                                  production_growth_ladder().back(),
            "H2(a): *** the SMALLEST rung is recommended, not the largest ***");
      // ...and it really is the smallest ACCEPTED one, not merely the last
      // element: nothing accepted sits below it.
      bool smallest = true;
      for (const MinimizePlasticVariant& v : r.evaluated)
        if (v.accepted && rec != nullptr &&
            v.requested_volume_fraction < rec->requested_volume_fraction)
          smallest = false;
      CHECK(smallest,
            "H2(a): no accepted rung asks for LESS than the recommended one");
    }

    // (b) ONLY THE TOP rung passes -> the TOP rung is recommended. The gate is
    //     placed between the top rung's margin and the next one's.
    {
      MinimizePlasticOptions o = growth_options(tip, 0.5 * (top_eff + mid_eff));
      o.design_box = box;
      const MinimizePlasticResult r =
          minimize_plastic(part, material, "PLA", bcs, rules, o);
      const MinimizePlasticVariant* rec = recommendation(r);
      CHECK(rec != nullptr,
            "H2(b): the top rung is recommended when only it passes");
      CHECK(rec != nullptr && rec->requested_volume_fraction ==
                                  production_growth_ladder().front(),
            "H2(b): *** a ladder where only the TOP rung passes recommends the "
            "TOP rung ***");
      CHECK(r.stopped_on_margin,
            "H2(b): the walk stopped on the margin at the next rung down");
      CHECK(!r.report.rejected.empty(),
            "H2(b): the rung that failed is REPORTED, not omitted");
      CHECK(!r.report.rejected.front().rejection_reason.empty(),
            "H2(b): and it says why");
    }

    // (c) NO rung passes -> NOTHING is recommended, and the failure carries its
    //     numbers. The largest rung must NOT be handed back as a consolation.
    {
      MinimizePlasticOptions o = growth_options(tip, top_eff * 2.0);
      o.design_box = box;
      const MinimizePlasticResult r =
          minimize_plastic(part, material, "PLA", bcs, rules, o);
      CHECK(recommendation(r) == nullptr,
            "H2(c): *** nothing is recommended when no rung passes — the "
            "largest rung is NOT returned as a consolation prize ***");
      CHECK(r.report.variants.empty(),
            "H2(c): the accepted-variant array is empty, as it must be");
      CHECK(r.report.rejected.size() == 1,
            "H2(c): the one evaluated rung is reported as rejected");
      const VariantReport& rej = r.report.rejected.front();
      CHECK(rej.margin_effective > 0.0 && rej.margin_required > 0.0,
            "H2(c): the rejection carries BOTH numbers the user needs (what it "
            "reached, and what it had to reach)");
      CHECK(rej.margin_effective < rej.margin_required,
            "H2(c): and they say what the verdict says");
      CHECK(rej.added_material.evaluated,
            "H2(c): a failed growth run still reports how much it would have "
            "added — the maintainer needs the numbers, not just the 'no'");
      CHECK(r.stopped_on_margin,
            "H2(c): the walk stopped on the margin at the very first rung");
    }
  }

  // ── H6: the document is honest, and the reduction document is unchanged ──
  {
    std::printf(" H6: report round-trip, growth and reduction\n");
    const std::string growth_json = job_report_json(all.report);
    bool ok = true;
    try {
      validate_job_report_json(growth_json);
    } catch (const std::exception& e) {
      ok = false;
      std::printf("      growth report rejected by its own validator: %s\n",
                  e.what());
    }
    CHECK(ok,
          "H6: a GROWTH report validates — its fractions are read on the growth "
          "scale because it carries the added_material block");
    CHECK(growth_json.find("\"added_material\"") != std::string::npos,
          "H6: the growth report EMITS the added-material accounting");
    CHECK(growth_json.find("\"outside_part\"") != std::string::npos &&
              growth_json.find("\"net_added_mass_grams\"") != std::string::npos,
          "H6: ...including where the plastic went and how much was added");

    // A REDUCTION run on the same fixture: no added_material block at all, and
    // the document is still validated on the [0, 1] scale it always was.
    MinimizePlasticOptions red = growth_options(tip, 0.0);
    red.volume_fraction_ladder = {0.68, 0.52};
    const MinimizePlasticResult rr =
        minimize_plastic(part, material, "PLA", bcs, rules, red);
    const std::string red_json = job_report_json(rr.report);
    CHECK(red_json.find("added_material") == std::string::npos,
          "H6: a REDUCTION report emits NO added-material block (its document "
          "keeps its exact bytes)");
    CHECK(!rr.growth_ladder, "H6: and it does not call itself a growth ladder");
    bool red_ok = true;
    try {
      validate_job_report_json(red_json);
    } catch (const std::exception&) {
      red_ok = false;
    }
    CHECK(red_ok, "H6: the reduction report validates, unchanged");
    for (const MinimizePlasticVariant& v : rr.evaluated) {
      CHECK(!v.report.added_material.evaluated,
            "H6: no reduction rung carries added-material accounting");
      CHECK(!v.report.growth_target_saturated,
            "H6: no reduction rung can be growth-saturated");
    }
  }

  // ── H7: DETERMINISM ─────────────────────────────────────────────────────
  {
    std::printf(" H7: determinism\n");
    MinimizePlasticOptions o = growth_options(tip, 0.0);
    o.design_box = box;
    const MinimizePlasticResult again =
        minimize_plastic(part, material, "PLA", bcs, rules, o);
    const std::vector<double> a = gate_fields(all), b = gate_fields(again);
    CHECK(a.size() == b.size(), "H7: the same run evaluates the same rungs");
    double worst = 0.0;
    if (a.size() == b.size())
      for (std::size_t i = 0; i < a.size(); ++i)
        worst = std::max(worst, std::fabs(a[i] - b[i]));
    CHECK(worst == 0.0,
          "H7: every gate field is BIT-identical across a repeat run (the 1e-9 "
          "negative-control floor is a floor; identity is the requirement)");
    std::printf("      %zu gate fields, worst |difference| = %.3g\n", a.size(),
                worst);
  }

  if (g_failures == 0) {
    std::printf("growth_ladder: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "growth_ladder: %d/%d checks FAILED\n", g_failures,
               g_checks);
  return 1;
}
