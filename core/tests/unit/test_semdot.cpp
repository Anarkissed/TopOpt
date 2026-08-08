// SEMDOT's smooth-edged volume-fraction map (task 2026-08-08-semdot-does-it-
// come-out-smoother). Pure C++/std (no OCCT, no Eigen) — the map is grid
// arithmetic over topopt/voxel.hpp — so it runs in every configuration. Uses the
// self-contained CHECK harness and the public API only (topopt/semdot.hpp).
//
// WHAT IS PINNED HERE, and why each one is a property the mode's whole claim
// rests on rather than a smoke test:
//
//   1. VOLUME EXACTNESS. The level set is chosen so the volume target is met, so
//      sum_e V_e must equal it — for a smooth field, for a binary field, and for
//      a UNIFORM one where every grid-point sample ties. If the tie rule were a
//      hard `>= phi` count this is the check that would catch it.
//   2. THE UNIFORM PASSTHROUGH. On a uniform field the map must be the identity
//      at the target fraction. That is what makes iteration 1 of the first rung
//      survive without a special case, and it must fall out of the tie rule.
//   3. SUB-VOXEL CONTENT — THE POINT OF THE MODE. A plane placed at a known
//      fraction through a voxel must come back as a volume fraction that tracks
//      that fraction. This is the property PR 315 measured the SIMP field as NOT
//      having (96.6% binary at boundary voxels), and it is the only reason to
//      expect a smoother surface.
//   4. PINS SURVIVE. Every non-Active voxel comes back byte-for-byte as handed
//      in, so the mask contract the whole masked path rests on is untouched.
//   5. DETERMINISM, as BIT-identity of a re-derivation.
//   6. THE REFUSALS. Everything SEMDOT subsumes must throw rather than be
//      silently ignored.

#include "topopt/semdot.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

using topopt::DesignMask;
using topopt::kSemdotDefaultGridPoints;
using topopt::MaskValue;
using topopt::SemdotField;
using topopt::semdot_nodal_density;
using topopt::semdot_volume_fractions;
using topopt::SimpOptions;
using topopt::VoxelGrid;
using topopt::VoxelTag;

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

namespace {

VoxelGrid make_grid(int nx, int ny, int nz) {
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = 1.0;
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  return g;
}

DesignMask all_active(const VoxelGrid& g) {
  return DesignMask(g.voxel_count(), MaskValue::Active);
}

std::size_t count_active(const DesignMask& m) {
  std::size_t n = 0;
  for (MaskValue v : m)
    if (v == MaskValue::Active) ++n;
  return n;
}

bool bit_identical(const std::vector<double>& a, const std::vector<double>& b) {
  if (a.size() != b.size()) return false;
  return std::memcmp(a.data(), b.data(), a.size() * sizeof(double)) == 0;
}

template <typename F>
bool throws_invalid(F&& f) {
  try {
    f();
  } catch (const std::invalid_argument&) {
    return true;
  } catch (...) {
    return false;
  }
  return false;
}

}  // namespace

int main() {
  // ── 1. VOLUME EXACTNESS on a smooth (non-tied) field ──────────────────────
  {
    const VoxelGrid g = make_grid(12, 12, 12);
    const DesignMask mask = all_active(g);
    // A smooth ramp along x, so grid-point samples are essentially all distinct.
    std::vector<double> rho(g.voxel_count(), 0.0);
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i)
          // Generic, not axis-degenerate: a field that varies along ONE axis in
          // even steps gives every voxel of a slab the same four sample values,
          // so the level set lands on a whole slab at once and there is no
          // boundary layer to read. The optimizer's fields are not like that.
          rho[g.index(i, j, k)] = std::fmin(
              1.0, std::fmax(0.0, 0.5 + 0.45 * std::sin(0.37 * i + 0.11 * j -
                                                        0.19 * k)));
    const double n_active = static_cast<double>(count_active(mask));
    for (double vf : {0.2, 0.5, 0.75}) {
      const SemdotField f = semdot_volume_fractions(g, rho, mask, vf * n_active,
                                                    kSemdotDefaultGridPoints);
      // Met to the grid-point quantum: K is a whole number of grid points, so
      // the slack is half a grid point = 0.5/n^3 of one voxel (semdot.hpp,
      // "ONE HONEST LIMIT"), plus floating-point summation of n_active terms.
      const double quantum =
          0.5 / (kSemdotDefaultGridPoints * kSemdotDefaultGridPoints *
                 static_cast<double>(kSemdotDefaultGridPoints));
      CHECK(std::fabs(f.achieved_volume - vf * n_active) < quantum + 1e-9,
            "semdot: achieved volume must meet the target to the grid-point "
            "quantum");
      CHECK(f.level_set >= 0.0 && f.level_set <= 1.0,
            "semdot: level set must be in [0,1]");
      CHECK(f.fractional_voxels > 0,
            "semdot: a ramped field must produce a fractional boundary layer");
      for (double v : f.volume_fraction)
        CHECK(v >= 0.0 && v <= 1.0, "semdot: volume fraction must be in [0,1]");
    }
  }

  // ── 2. THE UNIFORM PASSTHROUGH — the tie rule, with no special case ────────
  {
    const VoxelGrid g = make_grid(8, 8, 8);
    const DesignMask mask = all_active(g);
    const double vf = 0.37;
    const std::vector<double> rho(g.voxel_count(), vf);
    const double n_active = static_cast<double>(count_active(mask));
    const SemdotField f = semdot_volume_fractions(g, rho, mask, vf * n_active,
                                                  kSemdotDefaultGridPoints);
    double worst = 0.0;
    for (double v : f.volume_fraction) worst = std::fmax(worst, std::fabs(v - vf));
    // Every sample ties at vf, so f = K/N = vf and every voxel comes back at vf.
    // The tie fraction is K/N with K a whole number of samples, so the identity
    // holds to half a sample out of N — not to the last bit.
    const double sample_quantum =
        0.5 / (static_cast<double>(g.voxel_count()) * kSemdotDefaultGridPoints *
               kSemdotDefaultGridPoints * kSemdotDefaultGridPoints);
    CHECK(worst < sample_quantum + 1e-15,
          "semdot: a UNIFORM field must map to itself at the target fraction "
          "(this is what makes iteration 1 survive without a special case)");
    CHECK(std::fabs(f.achieved_volume - vf * n_active) <
              0.5 / 64.0 + 1e-9,
          "semdot: uniform field volume must still meet the target");
    CHECK(f.tied_samples == static_cast<std::size_t>(g.voxel_count()) *
                                kSemdotDefaultGridPoints *
                                kSemdotDefaultGridPoints *
                                kSemdotDefaultGridPoints,
          "semdot: every sample of a uniform field is a tie");
  }

  // ── 3. SUB-VOXEL CONTENT: a plane at a known depth comes back as a fraction ─
  //
  // A binary half-space cut at x = c, voxel-quantized. The SIMP field can only
  // say "this voxel is in or out"; SEMDOT must say HOW MUCH of the boundary voxel
  // is in, and that number must MOVE as the true cut moves within one voxel.
  {
    const VoxelGrid g = make_grid(16, 6, 6);
    const DesignMask mask = all_active(g);
    const double n_active = static_cast<double>(count_active(mask));
    double prev_boundary_v = -1.0;
    int increasing = 0, samples = 0;
    for (double c : {8.15, 8.35, 8.55, 8.75, 8.95}) {
      // Binary field: voxel i is solid iff its centre is below the cut.
      std::vector<double> rho(g.voxel_count(), 0.0);
      double solid = 0.0;
      for (int k = 0; k < g.nz; ++k)
        for (int j = 0; j < g.ny; ++j)
          for (int i = 0; i < g.nx; ++i) {
            const double centre = static_cast<double>(i) + 0.5;
            if (centre < c) {
              rho[g.index(i, j, k)] = 1.0;
              solid += 1.0;
            }
          }
      // Target the TRUE volume of the half-space, not the voxelized one: the
      // level set then has to place the boundary sub-voxel to hit it.
      const double true_vol = c * static_cast<double>(g.ny) * g.nz;
      const SemdotField f =
          semdot_volume_fractions(g, rho, mask, true_vol, 8);
      CHECK(std::fabs(f.achieved_volume - true_vol) < 0.5 / 512.0 + 1e-9,
            "semdot: half-space volume target must be met to the quantum");
      // Read the fill of the column the true cut passes through.
      const std::size_t e = g.index(static_cast<int>(c), 3, 3);
      const double v = f.volume_fraction[e];
      CHECK(v > 0.0 && v < 1.0,
            "semdot: the voxel the cut passes through must be FRACTIONAL — "
            "this is the sub-voxel content the SIMP field does not have");
      if (prev_boundary_v >= 0.0 && v > prev_boundary_v) ++increasing;
      if (prev_boundary_v >= 0.0) ++samples;
      prev_boundary_v = v;
      (void)solid;
    }
    CHECK(samples > 0 && increasing == samples,
          "semdot: the boundary voxel's fill must GROW as the cut moves "
          "through it — a fraction that does not track the cut carries no "
          "sub-voxel information");
  }

  // ── 4. PINS SURVIVE BYTE-FOR-BYTE ─────────────────────────────────────────
  {
    const VoxelGrid g = make_grid(10, 10, 10);
    DesignMask mask = all_active(g);
    std::vector<double> rho(g.voxel_count(), 0.5);
    std::size_t n_active = 0;
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) {
          const std::size_t e = g.index(i, j, k);
          if (i < 2) {
            mask[e] = MaskValue::FrozenSolid;
            rho[e] = 1.0;
          } else if (i > 7) {
            mask[e] = MaskValue::FrozenVoid;
            rho[e] = 0.0;
          } else {
            rho[e] = 0.4 + 0.01 * static_cast<double>(j);
            ++n_active;
          }
        }
    const SemdotField f = semdot_volume_fractions(
        g, rho, mask, 0.5 * static_cast<double>(n_active),
        kSemdotDefaultGridPoints);
    bool pins_ok = true;
    for (std::size_t e = 0; e < g.voxel_count(); ++e)
      if (mask[e] != MaskValue::Active &&
          std::memcmp(&f.volume_fraction[e], &rho[e], sizeof(double)) != 0)
        pins_ok = false;
    CHECK(pins_ok, "semdot: every non-Active voxel must come back byte-for-byte");
    CHECK(f.design_voxels == n_active,
          "semdot: the design set is the Active set");
    CHECK(std::fabs(f.achieved_volume - 0.5 * static_cast<double>(n_active)) <
              0.5 / 64.0 + 1e-9,
          "semdot: the volume budget is over the Active set only");
  }

  // ── 5. DETERMINISM: bit-identical re-derivation ────────────────────────────
  {
    const VoxelGrid g = make_grid(11, 9, 7);
    const DesignMask mask = all_active(g);
    std::vector<double> rho(g.voxel_count(), 0.0);
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i)
          rho[g.index(i, j, k)] =
              0.5 + 0.4 * std::sin(0.7 * i + 0.31 * j - 0.13 * k);
    for (double& v : rho) v = std::fmin(1.0, std::fmax(0.0, v));
    const double target = 0.44 * static_cast<double>(count_active(mask));
    const SemdotField a = semdot_volume_fractions(g, rho, mask, target, 5);
    const SemdotField b = semdot_volume_fractions(g, rho, mask, target, 5);
    CHECK(bit_identical(a.volume_fraction, b.volume_fraction),
          "semdot: re-derivation from the same inputs must be BIT-identical");
    CHECK(a.level_set == b.level_set, "semdot: the level set must be bit-identical");
    const std::vector<double> nod1 = semdot_nodal_density(g, rho);
    const std::vector<double> nod2 = semdot_nodal_density(g, rho);
    CHECK(bit_identical(nod1, nod2),
          "semdot: the nodal field must be bit-identical");
    CHECK(nod1.size() == static_cast<std::size_t>(g.nx + 1) * (g.ny + 1) * (g.nz + 1),
          "semdot: one nodal value per grid node");
  }

  // ── 5b. THE NODAL RULE: only voxels that EXIST are averaged ───────────────
  {
    const VoxelGrid g = make_grid(2, 2, 2);
    const std::vector<double> rho(g.voxel_count(), 1.0);
    const std::vector<double> nod = semdot_nodal_density(g, rho);
    // The corner node touches ONE voxel and averages only what exists, so on a
    // uniform field it reads the SAME value — the property that keeps the map the
    // identity on a uniform field (semdot.hpp, "NOT marching cubes' background-0
    // rule").
    CHECK(std::fabs(nod[0] - 1.0) < 1e-15,
          "semdot: a corner node averages only the voxels that exist");
    // The centre node touches all eight and reads 1.
    const std::size_t sy = 3, sz = 9;
    CHECK(std::fabs(nod[sz + sy + 1] - 1.0) < 1e-15,
          "semdot: an interior node averages all eight incident voxels");
  }

  // ── 6. THE REFUSALS ───────────────────────────────────────────────────────
  {
    const VoxelGrid g = make_grid(4, 4, 4);
    const DesignMask mask = all_active(g);
    const std::vector<double> rho(g.voxel_count(), 0.5);
    CHECK(throws_invalid([&] {
            semdot_volume_fractions(g, rho, mask, 8.0, 0);
          }),
          "semdot: grid_points < 1 must throw");
    CHECK(throws_invalid([&] {
            semdot_volume_fractions(g, std::vector<double>(3, 0.5), mask, 8.0);
          }),
          "semdot: a density of the wrong size must throw");
    CHECK(throws_invalid([&] {
            semdot_volume_fractions(g, rho, mask, 1e9);
          }),
          "semdot: a target volume above the Active count must throw");
    CHECK(throws_invalid([&] { semdot_nodal_density(g, std::vector<double>(3)); }),
          "semdot: nodal density of a wrong-sized field must throw");
  }

  // ── 6b. THE OPTION REFUSALS — everything the mode subsumes ─────────────────
  //
  // These run through the real validators via simp_optimize on a tiny grid. Each
  // must throw for its OWN reason, before any solve, so a caller that stacks a
  // subsumed mechanism on top of SEMDOT is told rather than quietly obeyed.
  {
    const VoxelGrid g = make_grid(4, 4, 4);
    const DesignMask mask = all_active(g);
    topopt::SimpParams params;
    params.youngs_modulus = 1000.0;
    params.poisson = 0.3;
    std::vector<topopt::DirichletBC> bcs;
    std::vector<topopt::NodalLoad> loads;
    auto base = [] {
      SimpOptions o;
      o.semdot = true;
      o.updater = topopt::SimpUpdater::MMA;
      o.max_iterations = 1;
      o.volume_fraction = 0.5;
      return o;
    };
    auto refuses = [&](SimpOptions o, const char* what) {
      bool threw = false;
      std::string msg;
      try {
        (void)topopt::simp_optimize(g, params, bcs, loads, o, mask);
      } catch (const std::invalid_argument& e) {
        threw = true;
        msg = e.what();
      } catch (...) {
      }
      CHECK(threw && msg.find("semdot") != std::string::npos, what);
    };
    {
      SimpOptions o = base();
      o.updater = topopt::SimpUpdater::OC;
      o.projection.push_back({8.0, 0.2, 5});
      refuses(o, "semdot + a Heaviside projection schedule must be REFUSED");
    }
    {
      SimpOptions o = base();
      o.mma_projection = true;
      refuses(o, "semdot + mma_projection must be REFUSED");
    }
    {
      SimpOptions o = base();
      o.penalty_continuation.push_back({1.0, 5});
      refuses(o, "semdot + penalty_continuation must be REFUSED");
    }
    {
      SimpOptions o = base();
      o.semdot_grid_points = 0;
      refuses(o, "semdot_grid_points < 1 must be REFUSED");
    }
    {
      // The UNCONSTRAINED overload is out of scope, and out of scope must mean
      // refused, not quietly ignored.
      SimpOptions o = base();
      bool threw = false;
      std::string msg;
      try {
        (void)topopt::simp_optimize(g, params, bcs, loads, o);
      } catch (const std::invalid_argument& e) {
        threw = true;
        msg = e.what();
      } catch (...) {
      }
      CHECK(threw && msg.find("semdot") != std::string::npos,
            "semdot on the unconstrained simp_optimize overload must be REFUSED");
    }
  }

  std::printf("test_semdot: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
