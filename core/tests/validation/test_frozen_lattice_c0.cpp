// test_frozen_lattice_c0.cpp — task 2026-08-13-lattice-as-a-material, bar R1.
//
// ★ C0 INERTNESS, AS A WHOLE-RUN CHECKSUM: `Lattice(f = 1.0)` must be
// BYTE-IDENTICAL to Solid. If it is not, the material model is wrong and no
// result after it can be trusted — the brief makes this a BLOCKED-STOP and says
// it runs before any arm.
//
// ★ WHY IT IS A CTEST ON A SYNTHETIC WALL AND NOT A PROBE ON HIS PART.
// "Byte-identical" is SCALE-INDEPENDENT: it is a statement about which branches
// the code takes, and a 10 x 24 x 24 wall exercises exactly the branches a
// 128 x 31 x 118 import does — the pin, the material law, the volume budget, the
// certification posture and the receipt. Running it on his part costs a pair of
// full ladder runs (hours on a shared machine, and it was measured at 2h17m
// while another worktree's suite had the cores) to learn the same bit.
//
// So it lives here, runs in seconds, and — the part that matters — runs on EVERY
// CI build forever instead of once by hand. A bar that is checked once is a
// measurement; a bar that is checked on every commit is a guard.
//
// ★ AND IT IS DELIBERATELY NOT A TEST OF THE RESOLVER. `test_lattice_density_field`
// already asserts that f = 1.0 emits no mask bit. THIS asserts the thing that
// actually matters and that a resolver test cannot: that a WHOLE minimize_plastic
// RUN — mask pins, material law, volume budget, ladder, certification, receipt —
// lands on the same converged field, to the bit, whether the feature is armed at
// f = 1.0 or not armed at all.

#include "topopt/design_store.hpp"
#include "topopt/fea.hpp"
#include "topopt/lattice_density_field.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/settings.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

using namespace topopt;

namespace {

int g_failures = 0;

#define CHECK(cond, msg)                                                    \
  do {                                                                      \
    if (!(cond)) {                                                          \
      std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, (msg));           \
      ++g_failures;                                                         \
    }                                                                       \
  } while (0)

// A wall standing in the y-z plane, clamped at its base and pushed at its top
// edge — the same shape `frozen_buttress_probe` uses, at a size a test can
// afford. The first `kFrozenT` columns are held FrozenSolid: that is the region
// the density field is declared over.
// ★ THE GRID IS WIDER THAN THE BODY, AND THAT IS LOAD-BEARING.
// `local_member_thickness_mm` is a granulometric opening driven by a distance
// transform TO THE VOID. On a grid with NO void anywhere every voxel survives
// every radius and the thickness comes back +infinity — the "thicker than we
// measured" sentinel — so the cells-per-member floor can never bite and a test
// built on such a grid measures nothing. The first cut of this test did exactly
// that: both arms latticed everything and it looked like the feature was inert.
//
// So the BODY is `kSolidX` voxels thick in x and the grid extends past it; the
// material beyond is Empty. ★ The measured member is then 24 mm, NOT 12: void
// exists only on the +x side, so the distance transform sees a body 12 voxels
// deep from that one face and the inscribed-sphere thickness comes out at twice
// that. The number the test uses is the MEASURED one — printed in the row below
// — never the one that looks right from the dimensions.
constexpr int kFrozenT = 4;
constexpr int kSolidX = 12;
constexpr int kNX = 20, kNY = 24, kNZ = 24;

struct RunOut {
  std::uint64_t fingerprint = 0;
  double volume_fraction = 0.0;
  double compliance = 0.0;
  double margin_effective = 0.0;
  double mass_grams = 0.0;
  bool armed = false;
  std::size_t latticed = 0;
  // Reported so a failure says WHY rather than just that the counts differ.
  double member_width_mm = 0.0;
  double cells_per_member = 0.0;
  double cell_used_mm = 0.0;
  bool in_range = false, fit_feasible = false, refused = false;
};

RunOut run_wall(const Material& mat, const SettingsRules& rules, bool arm,
                double declared_density, double min_extrudable_width_mm,
                LatticeRegionCellMode cell_mode = LatticeRegionCellMode::Fixed,
                double run_cell_mm = 1.0, bool enforce_floor = false) {
  VoxelGrid g;
  g.nx = kNX; g.ny = kNY; g.nz = kNZ;
  g.spacing = 1.0;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(kNX) * kNY * kNZ, VoxelTag::Empty);

  DesignMask mask(g.voxel_count(), MaskValue::Active);
  std::vector<int> region_id(g.voxel_count(), 0);
  for (int k = 0; k < kNZ; ++k)
    for (int j = 0; j < kNY; ++j)
      for (int i = 0; i < kSolidX; ++i) {
        const std::size_t e = g.index(i, j, k);
        g.tags[e] = VoxelTag::Interior;
        if (i < kFrozenT) {
          mask[e] = MaskValue::FrozenSolid;
          region_id[e] = 1;
        }
      }

  std::vector<DirichletBC> bcs;
  for (int j = 0; j <= kNY; ++j)
    for (int i = 0; i <= kSolidX; ++i) {
      const int n = fea_node_index(g, i, j, 0);
      bcs.push_back({n, 0, 0.0});
      bcs.push_back({n, 1, 0.0});
      bcs.push_back({n, 2, 0.0});
    }
  std::vector<NodalLoad> loads;
  for (int j = 0; j <= kNY; ++j)
    loads.push_back({fea_node_index(g, 0, j, kNZ), 0, 4.0});

  MinimizePlasticOptions opt;
  opt.external_loads = loads;
  opt.require_external_loads = true;
  opt.design_mask = mask;
  opt.volume_fraction_ladder = {0.6};
  opt.simp.max_iterations = 6;
  opt.margin_stop = 0.0;  // this test is about identity, never about a verdict

  if (arm) {
    opt.frozen_lattice = true;
    opt.frozen_lattice_topology = LatticeTopology::Octet;
    opt.frozen_lattice_region_id = region_id;
    opt.frozen_lattice_cell_mm = run_cell_mm;
    // ★ STATED, NEVER DEFAULTED. Printability is entirely user input — it comes
    // from the project's print profile — and core refuses a frozen-lattice run
    // that does not state it. This is this FIXTURE's profile, not a default.
    opt.frozen_lattice_min_extrudable_width_mm = min_extrudable_width_mm;
    // The floor is deliberately NOT enforced: a refusal would ALSO produce an
    // empty field, and then the checksum would pass for the wrong reason — it
    // would be measuring the refusal, not the f = 1.0 dispatch.
    // ★ EXPLICIT, never derived from the cell mode. The identity runs pass
    // false: a refusal would ALSO produce an empty field, and then the C0
    // checksum would pass for the wrong reason — it would be measuring the
    // refusal, not the f = 1.0 dispatch. The FIT test passes true in BOTH arms,
    // because there the refusal is the whole subject.
    opt.frozen_lattice_refuse_below_floor = enforce_floor;
    LatticeRegionSpec s;
    s.id = 1;
    s.name = "wall";
    s.mode = LatticeRegionMode::Declared;
    s.declared_density = declared_density;
    s.cell_mode = cell_mode;
    opt.frozen_lattice_regions = {s};
  }

  const MinimizePlasticResult r =
      minimize_plastic(g, mat, "PLA", bcs, rules, opt);
  RunOut out;
  out.armed = r.frozen_lattice.armed;
  out.latticed = r.frozen_lattice.latticed_voxels;
  if (!r.frozen_lattice.regions.empty()) {
    const auto& rg = r.frozen_lattice.regions.front();
    out.member_width_mm = rg.member_width_median_mm;
    out.cells_per_member = rg.cells_per_member_median;
    out.cell_used_mm = rg.cell_used_mm;
    out.in_range = rg.in_validity_range;
    out.fit_feasible = rg.fit_feasible;
    out.refused = rg.refused;
  }
  if (!r.evaluated.empty()) {
    const MinimizePlasticVariant& v = r.evaluated.back();
    out.fingerprint = design_fingerprint(v.optimization.physical_density);
    out.volume_fraction = v.optimization.volume_fraction;
    out.compliance = v.optimization.compliance;
    out.margin_effective = v.report.margin_effective;
    out.mass_grams = v.mass_grams;
  }
  return out;
}

}  // namespace

int main() {
  const MaterialLibrary lib = load_materials_file(MATERIALS_JSON_PATH);
  const Material mat = lib.at("PLA");
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  const double kFixtureNozzleMM = 0.45;

  // ── ★ THE BAR ────────────────────────────────────────────────────────────
  const RunOut off = run_wall(mat, rules, /*arm=*/false, 1.0, kFixtureNozzleMM);
  const RunOut on1 = run_wall(mat, rules, /*arm=*/true, 1.0, kFixtureNozzleMM);

  std::printf("  frozen_lattice OFF          %016llx  vf %.12f  c %.12e\n",
              static_cast<unsigned long long>(off.fingerprint),
              off.volume_fraction, off.compliance);
  std::printf("  frozen_lattice ON, f = 1.0  %016llx  vf %.12f  c %.12e\n",
              static_cast<unsigned long long>(on1.fingerprint),
              on1.volume_fraction, on1.compliance);

  CHECK(on1.armed, "the arming must actually have happened — a test that "
                   "silently failed to arm would pass this bar vacuously");
  CHECK(on1.latticed == 0,
        "f = 1.0 must lattice NOTHING: a lattice at relative density 1 has no "
        "pore space and IS solid");
  CHECK(off.fingerprint == on1.fingerprint,
        "★ BAR R1: Lattice(f = 1.0) must be BYTE-IDENTICAL to Solid. If this "
        "fails the material model is wrong and no result after it can be "
        "trusted.");
  CHECK(off.volume_fraction == on1.volume_fraction &&
            off.compliance == on1.compliance,
        "and the run's own scalars must match to the bit too, not just the "
        "density field");
  CHECK(off.margin_effective == on1.margin_effective &&
            off.mass_grams == on1.mass_grams,
        "★ INCLUDING THE CERTIFICATE. The gate is where an inert feature would "
        "be most likely to leak: the posture merge and the strut term both hang "
        "off it.");

  // ── AND THE POSITIVE CONTROL, so the bar cannot pass by doing nothing ────
  //
  // ★ A checksum test that only ever compares two identical runs cannot tell
  // "the feature is inert at f = 1.0" from "the feature never does anything".
  // `comparison-bars-need-positive-controls` records three bars in this
  // repository that passed vacuously for exactly that reason. So: the SAME
  // arming at a density that IS a lattice must move the answer.
  const RunOut on3 = run_wall(mat, rules, /*arm=*/true, 0.30, kFixtureNozzleMM);
  std::printf("  frozen_lattice ON, f = 0.30 %016llx  vf %.12f  c %.12e  "
              "(%zu voxels latticed)\n",
              static_cast<unsigned long long>(on3.fingerprint),
              on3.volume_fraction, on3.compliance, on3.latticed);
  CHECK(on3.latticed > 0,
        "the positive control must actually lattice something, or it controls "
        "for nothing");
  CHECK(on3.fingerprint != off.fingerprint,
        "★ POSITIVE CONTROL: at f = 0.30 the SAME arming MUST change the "
        "converged design. If it does not, the f = 1.0 identity above is "
        "measuring a no-op feature rather than an inert one.");
  CHECK(on3.mass_grams < off.mass_grams,
        "and it must weigh LESS — a 30% lattice in place of solid is the whole "
        "point of the feature");

  // ── AND PRINTABILITY IS USER INPUT: unset is a REFUSAL, never a default ──
  {
    bool threw = false;
    try {
      run_wall(mat, rules, /*arm=*/true, 0.30, /*width=*/0.0);
    } catch (const std::invalid_argument&) { threw = true; }
    CHECK(threw,
          "★ a frozen-lattice run that does not STATE its minimum extrudable "
          "strut width must be REFUSED. That number comes from the project's "
          "own print profile, which the user chose and the software may not "
          "change; there is no default that is right for two different nozzles.");
  }

  // ── ★★ THE FIT: a region REFUSED at the run's cell that LATTICES at its own
  //
  // This is the difference between a feature that refuses and one that works,
  // end to end rather than at the resolver. The wall is 4 voxels thick at 1 mm
  // spacing, so it cannot hold 5 cells at a 2 mm cell — under a FIXED cell the
  // run refuses it and lattices nothing. Declared FIT, the cell is derived from
  // the wall's own thickness, the floor is cleared by construction, and the
  // region lattices.
  //
  // ★ The floor is ENFORCED in both arms here (unlike the identity runs above),
  // because the refusal is exactly what is under test.
  {
    // ★ THE MEMBER IS THE BODY, not the 4-voxel frozen strip:
    // `local_member_thickness_mm` is the inscribed-sphere thickness of the
    // PRINTED SET, and the frozen strip sits inside it. Measured at 24 mm here,
    // so the run cell has to be 6 mm for the 5-cell floor to bite (24/6 = 4) and
    // the fitted cell is 24/5 = 4.8 mm. Getting this wrong is how the first cut
    // of this test "passed" while both arms latticed everything.
    const RunOut fixed = run_wall(mat, rules, /*arm=*/true, 0.30,
                                  kFixtureNozzleMM,
                                  LatticeRegionCellMode::Fixed, /*cell=*/6.0,
                                  /*enforce_floor=*/true);
    const RunOut fitted = run_wall(mat, rules, /*arm=*/true, 0.30,
                                   kFixtureNozzleMM,
                                   LatticeRegionCellMode::Fit, /*cell=*/6.0,
                                   /*enforce_floor=*/true);
    std::printf("  FIXED  member %.3f mm = %.2f cells at %.2f mm  in_range=%d "
                "fit=%d refused=%d -> %zu latticed\n",
                fixed.member_width_mm, fixed.cells_per_member,
                fixed.cell_used_mm, fixed.in_range ? 1 : 0,
                fixed.fit_feasible ? 1 : 0, fixed.refused ? 1 : 0,
                fixed.latticed);
    std::printf("  FIT    member %.3f mm = %.2f cells at %.2f mm  in_range=%d "
                "fit=%d refused=%d -> %zu latticed\n",
                fitted.member_width_mm, fitted.cells_per_member,
                fitted.cell_used_mm, fitted.in_range ? 1 : 0,
                fitted.fit_feasible ? 1 : 0, fitted.refused ? 1 : 0,
                fitted.latticed);
    CHECK(fixed.latticed == 0,
          "at a 6 mm cell a 24 mm member holds 4 cells, misses the 5-cell floor "
          "and IS refused — that refusal is correct for the question it was "
          "asked");
    CHECK(fitted.latticed > 0,
          "★ and at a cell derived from the wall's OWN thickness it lattices. An "
          "earlier cut of this task refused here, and on his part that was the "
          "region holding 73% of the prize.");
    CHECK(fitted.mass_grams < fixed.mass_grams,
          "and the fitted run weighs less — the refusal was costing real mass");
  }

  if (g_failures == 0) std::printf("test_frozen_lattice_c0: OK\n");
  return g_failures == 0 ? 0 : 1;
}
