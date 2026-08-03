// growth_ladder_gate — MEASURE the growth ladder (task 2026-08-03-growth-ladder).
//
// A harness, not a ctest: it prints tables and writes evidence. It answers the
// three questions the task says must be measured rather than argued.
//
//   G2  THE MAINTAINER'S FAILING BRACKET. The real run (fingerprint 9f6738726016,
//       WallMount bracket, PLA, 35% infill) was REJECTED at margin_effective
//       0.5759 against a required 1.5, and the app could only say "raise infill or
//       use a stronger material". Run a GROWTH LADDER on that condition and print
//       every rung: requested volume fraction, achieved fraction, printed/added
//       mass, in-plane / interlayer / effective margins, the verdict, and which
//       rung is RECOMMENDED. If no rung passes, say so with the numbers — that is
//       a valid outcome and the maintainer needs it.
//
//   G5  THE PAD DECISION. The SAME growth ladder, twice: with the anchor/load
//       structural pad frozen and without. Print both tables side by side —
//       verdicts, margins and the growth accounting — so kGrowthPathAnchorPad is
//       a measurement and not an argument.
//
//   G6  THE GATE IS UNCHANGED. The full gate table across the growth ladder, plus
//       PR 248's negative-control discipline: the run is repeated bit-for-bit and
//       every gate field must differ by ZERO — 1e-9 is the floor a real change has
//       to clear, and identity is what a re-run must produce.
//
// The FIXTURE. The WallMount geometry is not in the repo (the run was a device
// job), so what is reproduced is the CONDITION, exactly: PLA at 35% infill against
// margin_stop 1.5, on a mounted-and-loaded bracket whose baseline design lands
// under the gate. The binding term is printed for every rung, so the reader can
// see for themselves whether this ladder's rejection is the same KNOCKDOWN-bound
// rejection the real run had — which is the whole question G2 asks.
//
// Build/run (Eigen-gated, EXCLUDE_FROM_ALL):
//   cmake --build build --target growth_ladder_gate
//   ./build/growth_ladder_gate [evidence_dir]

#include "topopt/analyze.hpp"
#include "topopt/fea.hpp"
#include "topopt/loadcase.hpp"  // kProductionAnchorPadDepthVoxels, kGrowthPathAnchorPad
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
#include <fstream>
#include <string>
#include <vector>

using namespace topopt;

namespace {

std::string g_out;          // accumulated evidence text (also echoed to stdout)
std::string g_pad_section;  // the G5 pad comparison, captured on its own
bool g_capture_pad = false;

void emit(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
void emit(const char* fmt, ...) {
  char buf[1024];
  va_list ap;
  va_start(ap, fmt);
  std::vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  std::fputs(buf, stdout);
  g_out += buf;
  if (g_capture_pad) g_pad_section += buf;
}

// The bracket: a vertical arm clamped at the top, a horizontal foot loaded down at
// its free end (the same L shape test_designbox_reduction and the design-domain
// tests use, so this harness's geometry is comparable to the shipped gates').
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

// PLA, the material of the motivating run.
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

constexpr double kInfillPercent = 35.0;   // the motivating run's infill
constexpr double kMarginStop = 1.5;       // the motivating run's requirement

MinimizePlasticOptions growth_options(const std::vector<NodalLoad>& loads) {
  MinimizePlasticOptions o;
  o.volume_fraction_ladder = production_growth_ladder();
  o.margin_stop = kMarginStop;
  o.external_loads = loads;
  o.gravity = 9810.0 * 1e-9;
  o.gravity_direction = Vec3{0.0, 0.0, -1.0};
  o.updater = SimpUpdater::MMA;
  o.infill_percent = kInfillPercent;
  o.bake_build_orientation = BakeBuildOrientation::Off;
  return o;
}

double part_mass_grams(const VoxelGrid& part, const Material& m) {
  return m.density_g_cm3 * static_cast<double>(part.solid_count()) *
         part.voxel_volume() / 1000.0;
}

// The gate table for one run: every rung, every number the verdict rests on.
void print_ladder(const MinimizePlasticResult& r, double part_mass,
                  const char* label) {
  emit("\n%s\n", label);
  emit("  rung  request  achieved   mass_g   added_g  out%%   in_plane  "
       "interlayer  worst   effective  req    verdict\n");
  for (std::size_t i = 0; i < r.evaluated.size(); ++i) {
    const MinimizePlasticVariant& v = r.evaluated[i];
    const VariantReport& vr = v.report;
    const AddedMaterialReport& a = vr.added_material;
    emit("  %-4zu  %6.2f   %7.4f  %7.3f  %+7.3f  %4.1f  %8.4f  %10.4f  %6.4f  "
         "%9.4f  %.2f  %s%s%s\n",
         i, v.requested_volume_fraction, vr.printed_fraction, v.mass_grams,
         a.evaluated ? a.net_added_mass_grams : 0.0,
         a.evaluated ? 100.0 * a.outside_fraction : 0.0, vr.margin.in_plane,
         vr.margin.interlayer, vr.margin.worst_case, vr.margin_effective,
         vr.margin_required, vr.accepted ? "ACCEPTED" : "REJECTED",
         vr.rejection_reason.empty() ? "" : " — ",
         vr.rejection_reason.c_str());
    if (vr.growth_target_saturated)
      emit("        ^ SATURATED: the design box could not hold this rung's ask; "
           "it ran at 'fill the box' instead\n");
  }
  emit("  part mass = %.3f g   growth_ladder=%d   stopped_on_margin=%d\n",
       part_mass, r.growth_ladder ? 1 : 0, r.stopped_on_margin ? 1 : 0);

  // THE RECOMMENDATION — the LAST ACCEPTED rung, which on a descending growth
  // ladder is the SMALLEST addition that passed. Exactly the rule the reduction
  // ladder uses for "the lightest that passed"; no second code path.
  const MinimizePlasticVariant* rec = nullptr;
  for (const MinimizePlasticVariant& v : r.evaluated)
    if (v.accepted) rec = &v;
  if (rec != nullptr) {
    emit("  RECOMMENDED: rung at %.2f (+%.0f%% of the part) — added %+.3f g, "
         "effective margin %.4f >= %.2f\n",
         rec->requested_volume_fraction,
         100.0 * (rec->requested_volume_fraction - 1.0),
         rec->report.added_material.net_added_mass_grams,
         rec->report.margin_effective, rec->report.margin_required);
  } else {
    emit("  NO RUNG PASSES. The largest addition on the ladder (+%.0f%%) reached "
         "effective margin %.4f against a required %.2f — short by %.4f. Growing "
         "is not the lever for this part; the binding term is printed above.\n",
         100.0 * (r.evaluated.front().requested_volume_fraction - 1.0),
         r.evaluated.front().report.margin_effective,
         r.evaluated.front().report.margin_required,
         r.evaluated.front().report.margin_required -
             r.evaluated.front().report.margin_effective);
  }
}

// Every gate field of one run, flattened, so two runs can be diffed EXACTLY
// (PR 248's negative-control discipline: identity is what a re-run must produce,
// and 1e-9 is the floor any claimed difference has to clear).
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
    f.push_back(vr.margin_required);
    f.push_back(vr.accepted ? 1.0 : 0.0);
    f.push_back(v.mass_grams);
    f.push_back(static_cast<double>(vr.added_material.printed_voxels));
    f.push_back(static_cast<double>(vr.added_material.outside_part));
  }
  return f;
}

}  // namespace

int main(int argc, char** argv) {
  const std::string evidence_dir = argc > 1 ? argv[1] : "";

  SettingsRules rules;
  try {
    rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "could not load rules.json: %s\n", e.what());
    return 1;
  }
  const Material material = pla();

  const int arm = 8, span = 8, ny = 3, t = 2;
  const double h = 2.0;
  std::vector<DirichletBC> bcs;
  VoxelGrid part = l_bracket(bcs, arm, span, ny, t, h);
  const double part_mass = part_mass_grams(part, material);

  // The design box the growth ladder needs, derived by the SAME function
  // build_production_loadcase uses when the user drew none.
  const DesignBox box = minimal_growth_design_box(
      part, production_growth_ladder().front(), kGrowthBoxHeadroom);

  emit("growth_ladder_gate — task 2026-08-03-growth-ladder\n");
  emit("=====================================================================\n");
  emit("fixture      L-bracket %dx%dx%d @ %.1f mm, %lld solid voxels, %.3f g\n",
       span, ny, arm, h, static_cast<long long>(part.solid_count()), part_mass);
  emit("material     PLA (yield %.0f MPa, z_knockdown %.2f)\n",
       material.yield_strength_mpa, material.z_knockdown);
  emit("condition    infill %.0f%%, margin_required %.2f — the motivating run's\n",
       kInfillPercent, kMarginStop);
  emit("knockdown    f^1.5 = %.6f  (effective = worst_case x this)\n",
       infill_margin_knockdown(kInfillPercent));
  emit("ladder       GROWTH [1.55, 1.25, 1.10] (production_growth_ladder)\n");
  emit("design box   AUTO-DERIVED min=(%.1f,%.1f,%.1f) max=(%.1f,%.1f,%.1f) mm\n",
       box.min.x, box.min.y, box.min.z, box.max.x, box.max.y, box.max.z);

  // ── THE LOAD IS CALIBRATED TO THE MOTIVATING RUN'S REJECTION POINT ────────
  // The WallMount geometry is not in the repo, so what is reproduced is the
  // CONDITION: the imported part, at 35% infill against a required 1.5, lands at
  // effective margin 0.5759 — the exact number the maintainer's run was rejected
  // on. The margin of a FIXED design is inversely proportional to the load (a
  // linear solve: double the force, halve every margin), so one probe solve at an
  // arbitrary force fixes the force that lands on 0.5759, and a second confirms
  // it. Nothing is typed in; the calibration is measured and printed.
  constexpr double kMotivatingEffectiveMargin = 0.5759;
  double force_n = 120.0;
  {
    MinimizePlasticOptions o = growth_options(
        traction_loads(part, VoxelTag::Load, Vec3{0.0, 0.0, -force_n}));
    o.volume_fraction_ladder = {1.0};
    const MinimizePlasticResult probe =
        minimize_plastic(part, material, "PLA", bcs, rules, o);
    const double e = probe.evaluated.front().report.margin_effective;
    force_n *= e / kMotivatingEffectiveMargin;
    emit("calibration  probe at 120 N -> effective %.4f; the load that lands on "
         "the motivating run's %.4f is %.4f N\n",
         e, kMotivatingEffectiveMargin, force_n);
  }
  const Vec3 tip_force{0.0, 0.0, -force_n};
  const std::vector<NodalLoad> tip = traction_loads(part, VoxelTag::Load, tip_force);

  // ── The BASELINE: what the part does today, un-grown, under this condition.
  // This is the "0.5759 against 1.5" line of the motivating run.
  {
    MinimizePlasticOptions o = growth_options(tip);
    o.volume_fraction_ladder = {1.0};   // the part itself, no box: the status quo
    const MinimizePlasticResult r =
        minimize_plastic(part, material, "PLA", bcs, rules, o);
    const VariantReport& vr = r.evaluated.front().report;
    emit("\nBASELINE (the part as imported, no growth)\n");
    emit("  in_plane %.4f  interlayer %.4f  worst_case %.4f  EFFECTIVE %.4f  "
         "required %.2f  -> %s\n",
         vr.margin.in_plane, vr.margin.interlayer, vr.margin.worst_case,
         vr.margin_effective, vr.margin_required,
         vr.accepted ? "ACCEPTED" : "REJECTED");
    emit("  binding term: %s\n",
         vr.margin_effective < vr.margin.worst_case * 0.999
             ? "the INFILL KNOCKDOWN (effective << worst_case) — the motivating "
               "run's own binding term"
             : "the stress margin itself");
  }

  // ── G2 + G5: the growth ladder, pad ON and pad OFF ────────────────────────
  g_capture_pad = true;
  MinimizePlasticResult pad_on, pad_off;
  for (int pass = 0; pass < 2; ++pass) {
    const bool pad = pass == 0;
    MinimizePlasticOptions o = growth_options(tip);
    o.design_box = box;
    if (pad) {
      // The SAME FrozenSolid anchor/load pad build_production_loadcase freezes:
      // kProductionAnchorPadDepthVoxels layers behind every anchor and load face.
      DesignMask m = make_active_mask(part);
      for (int k = 0; k < part.nz; ++k)
        for (int j = 0; j < part.ny; ++j)
          for (int i = 0; i < part.nx; ++i) {
            const VoxelTag tg = part.tag(i, j, k);
            if (tg != VoxelTag::Fixture && tg != VoxelTag::Load) continue;
            // Freeze this BC voxel and the pad depth behind it, along the axis the
            // face faces (x for the load face, z for the fixture face).
            for (int d = 0; d < kProductionAnchorPadDepthVoxels; ++d) {
              const int pi = tg == VoxelTag::Load ? i - d : i;
              const int pk = tg == VoxelTag::Fixture ? k - d : k;
              if (pi < 0 || pk < 0) continue;
              if (!part.solid(pi, j, pk)) continue;
              m[part.index(pi, j, pk)] = MaskValue::FrozenSolid;
            }
          }
      o.design_mask = std::move(m);
    }
    MinimizePlasticResult& into = pad ? pad_on : pad_off;
    into = minimize_plastic(part, material, "PLA", bcs, rules, o);
    print_ladder(into, part_mass,
                 pad ? "G5(a) GROWTH LADDER — anchor/load pad ON "
                       "(kGrowthPathAnchorPad = true)"
                     : "G5(b) GROWTH LADDER — anchor/load pad OFF (the "
                       "pre-task behaviour on this mode)");
  }

  // ── G4: growth is REAL growth, on every rung ──────────────────────────────
  emit("\nG4 GROWTH IS REAL GROWTH (pad ON) — printed mass vs the part's %.3f g\n",
       part_mass);
  bool all_grew = true;
  for (const MinimizePlasticVariant& v : pad_on.evaluated) {
    const AddedMaterialReport& a = v.report.added_material;
    const bool grew = v.mass_grams > part_mass;
    all_grew = all_grew && grew;
    emit("  rung %.2f: printed %.3f g (%+.3f g, %+.1f%%), %lld of %lld printed "
         "voxels OUTSIDE the part (%.1f%%), outside volume %.1f mm^3  -> %s\n",
         v.requested_volume_fraction, v.mass_grams, a.net_added_mass_grams,
         100.0 * (v.mass_grams / part_mass - 1.0), a.outside_part,
         a.printed_voxels, 100.0 * a.outside_fraction, a.outside_volume_mm3,
         grew ? "GREW" : "*** DID NOT GROW ***");
  }
  emit("  every rung grew: %s\n", all_grew ? "YES" : "NO");

  // ── G5 summary: the pad decision, priced ──────────────────────────────────
  emit("\nG5 THE PAD DECISION, PRICED\n");
  emit("  %-28s  %-10s  %-10s\n", "", "pad ON", "pad OFF");
  emit("  %-28s  %-10zu  %-10zu\n", "rungs evaluated", pad_on.evaluated.size(),
       pad_off.evaluated.size());
  {
    std::size_t acc_on = 0, acc_off = 0;
    for (const MinimizePlasticVariant& v : pad_on.evaluated) acc_on += v.accepted;
    for (const MinimizePlasticVariant& v : pad_off.evaluated) acc_off += v.accepted;
    emit("  %-28s  %-10zu  %-10zu\n", "rungs ACCEPTED", acc_on, acc_off);
  }
  const std::size_t n = std::min(pad_on.evaluated.size(), pad_off.evaluated.size());
  for (std::size_t i = 0; i < n; ++i) {
    const VariantReport& a = pad_on.evaluated[i].report;
    const VariantReport& b = pad_off.evaluated[i].report;
    emit("  rung %.2f  effective %.4f vs %.4f (%+.4f)   mass %.3f vs %.3f g "
         "(%+.3f)   verdict %s vs %s\n",
         pad_on.evaluated[i].requested_volume_fraction, a.margin_effective,
         b.margin_effective, a.margin_effective - b.margin_effective,
         pad_on.evaluated[i].mass_grams, pad_off.evaluated[i].mass_grams,
         pad_on.evaluated[i].mass_grams - pad_off.evaluated[i].mass_grams,
         a.accepted ? "ACC" : "REJ", b.accepted ? "ACC" : "REJ");
  }

  g_capture_pad = false;

  // ── G2(b): A PART THE LADDER RESCUES CHEAPLY ──────────────────────────────
  // The run above lands on the TOP rung, so it does not exercise the thing the
  // ladder exists for: finding the SMALLEST addition. Halve the load — a part
  // only slightly under the gate — and the same ladder must walk PAST the
  // expensive rungs and recommend the cheap one.
  {
    MinimizePlasticOptions o = growth_options(
        traction_loads(part, VoxelTag::Load, Vec3{0.0, 0.0, -force_n * 0.45}));
    o.design_box = box;
    const MinimizePlasticResult r =
        minimize_plastic(part, material, "PLA", bcs, rules, o);
    print_ladder(r, part_mass,
                 "G2(b) THE SAME LADDER ON A PART ONLY SLIGHTLY UNDER THE GATE "
                 "(load x0.45) — it must recommend the SMALLEST addition, not "
                 "the largest");
  }

  // ── G6: the gate is unchanged — the negative-control floor ────────────────
  emit("\nG6 NEGATIVE CONTROL (PR 248's discipline): the same growth run, twice\n");
  MinimizePlasticOptions o2 = growth_options(tip);
  o2.design_box = box;
  const MinimizePlasticResult repeat =
      minimize_plastic(part, material, "PLA", bcs, rules, o2);
  const std::vector<double> f1 = gate_fields(pad_off), f2 = gate_fields(repeat);
  // (pad_off is the run `repeat` reproduces: same options, no design mask.)
  double worst = 0.0;
  bool same_shape = f1.size() == f2.size();
  if (same_shape)
    for (std::size_t i = 0; i < f1.size(); ++i) {
      const double d = std::fabs(f1[i] - f2[i]);
      if (d > worst) worst = d;
    }
  emit("  fields compared: %zu   shape match: %s   WORST |difference|: %.3g\n",
       f1.size(), same_shape ? "yes" : "NO", worst);
  emit("  floor: 1e-9. %s\n",
       same_shape && worst == 0.0
           ? "EXACTLY ZERO — bit-identical, as a re-run must be."
           : "*** NOT identical — a determinism failure, investigate. ***");

  if (!evidence_dir.empty()) {
    const std::string path = evidence_dir + "/growth_ladder_gate.txt";
    std::ofstream f(path);
    f << g_out;
    std::printf("\nwrote %s\n", path.c_str());
    // The pad decision on its own, because loadcase.hpp's kGrowthPathAnchorPad
    // names this file as the measurement behind the constant.
    const std::string ppath = evidence_dir + "/pad_on_off.txt";
    std::ofstream pf(ppath);
    pf << "THE ANCHOR/LOAD PAD ON THE GROWTH PATH — MEASURED, NOT ARGUED\n"
       << "(task 2026-08-03-growth-ladder, bar G5; kGrowthPathAnchorPad)\n"
       << "The same growth ladder, same fixture, same load, same rungs: once with\n"
       << "the kProductionAnchorPadDepthVoxels FrozenSolid pad frozen behind every\n"
       << "anchor and load face, once without (the pre-task behaviour on this mode).\n"
       << g_pad_section;
    std::printf("wrote %s\n", ppath.c_str());
  }
  return 0;
}
