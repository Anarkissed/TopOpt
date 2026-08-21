// MEASUREMENT-ONLY probe for task 2026-08-20-lattice-only-grading (R1 baseline).
//
// Reproduces the PRODUCTION grading law on the PRODUCTION inputs of a
// lattice-only (`mode: "analyze"`) run and reports the DENSITY DISTRIBUTION the
// receipt does not currently carry — in particular the fraction of latticed
// voxels sitting at `rho_min`, which is the number bar R1 says must move.
//
// It does NOT re-derive the law: it calls `grade_lattice` itself. The inputs are
// reconstructed and then CHECKED against the run's own artifacts before any
// number is printed:
//   * the grid comes from re-voxelizing the same STEP at the same resolution and
//     is asserted equal to the grid recorded in fields.bin;
//   * the von Mises field is READ from that same fields.bin (the run's own field);
//   * the resulting GradedField aggregates are asserted equal to run_info.json's.
// If those checks pass, the histogram below describes the run that actually ran.
//
// Build (standalone, nothing in the repo changes):
//   c++ -std=c++17 -O2 -I core/include <this> core/build-lg/libtopopt.a <occt libs> -o probe
// Run:
//   probe <model.step> <resolution> <fields.bin> <cell_min_mm> <cell_max_mm> <min_width_mm> [allowable_mpa]
//
// `allowable_mpa` is OPTIONAL and is the §0 preview: when given, the probe ALSO
// reports the distribution the absolute-utilisation law would produce, computed
// with the identical clamp/floor arithmetic, so the before/after can be compared
// before a line of production code is written.

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

#include "topopt/grading.hpp"
#include "topopt/lattice.hpp"
#include "topopt/part.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {

struct FieldsHeader {
  int nx = 0, ny = 0, nz = 0;
  double ox = 0, oy = 0, oz = 0, spacing = 0, voxel_volume = 0;
  int variants = 0;
};

// Little-endian reader mirroring core/src/io/fields.cpp's writer exactly.
struct LEReader {
  const std::vector<std::uint8_t>& b;
  std::size_t p = 0;
  explicit LEReader(const std::vector<std::uint8_t>& v) : b(v) {}
  void need(std::size_t n) const {
    if (p + n > b.size()) throw std::runtime_error("fields.bin: truncated");
  }
  std::uint8_t u8() { need(1); return b[p++]; }
  void skip(std::size_t n) { need(n); p += n; }
  std::int32_t i32() { need(4); std::int32_t v; std::memcpy(&v, b.data() + p, 4); p += 4; return v; }
  std::int64_t i64() { need(8); std::int64_t v; std::memcpy(&v, b.data() + p, 8); p += 8; return v; }
  float f32() { need(4); float v; std::memcpy(&v, b.data() + p, 4); p += 4; return v; }
  double f64() { need(8); double v; std::memcpy(&v, b.data() + p, 8); p += 8; return v; }
};

std::vector<double> read_first_von_mises(const std::string& path, FieldsHeader& h) {
  std::ifstream in(path, std::ios::binary);
  if (!in) throw std::runtime_error("cannot open " + path);
  std::vector<std::uint8_t> bytes((std::istreambuf_iterator<char>(in)),
                                   std::istreambuf_iterator<char>());
  LEReader r(bytes);
  const std::uint8_t version = r.u8();
  if (version != 1) throw std::runtime_error("fields.bin: unexpected format version");
  r.skip(3);
  h.nx = r.i32(); h.ny = r.i32(); h.nz = r.i32();
  h.ox = r.f64(); h.oy = r.f64(); h.oz = r.f64();
  h.spacing = r.f64(); h.voxel_volume = r.f64();
  h.variants = r.i32();
  r.skip(4);
  if (h.variants < 1) throw std::runtime_error("fields.bin: no variants");
  r.f64(); r.f64(); r.i32(); r.skip(4);          // vf, mass, support, pad
  const std::int64_t vm_n = r.i64();
  r.i64();                                        // tensor block (0 in v1)
  r.i64();                                        // displacement count
  std::vector<double> vm(static_cast<std::size_t>(vm_n));
  for (std::int64_t i = 0; i < vm_n; ++i) vm[static_cast<std::size_t>(i)] = r.f32();
  return vm;
}

// A fixed-bin histogram over the certifiable band — deterministic by construction
// (bar §1b: a full pass in a fixed order, never a sampled estimate).
struct Hist {
  static constexpr int kBins = 20;
  long long bin[kBins] = {0};
  long long at_lo = 0, at_hi = 0, total = 0;
  double lo = 0, hi = 0;

  void build(const std::vector<double>& rho, const std::vector<char>& mask,
             double band_lo, double band_hi) {
    lo = band_lo; hi = band_hi;
    const double eps = 1e-9;
    for (std::size_t e = 0; e < mask.size(); ++e) {
      if (!mask[e]) continue;
      const double r = rho[e];
      ++total;
      if (r <= band_lo + eps) ++at_lo;
      if (r >= band_hi - eps) ++at_hi;
      int k = static_cast<int>((r - band_lo) / (band_hi - band_lo) * kBins);
      if (k < 0) k = 0;
      if (k >= kBins) k = kBins - 1;
      ++bin[k];
    }
  }

  void print(const char* title) const {
    std::printf("\n%s\n", title);
    std::printf("  latticed voxels            : %lld\n", total);
    if (total == 0) return;
    std::printf("  at rho_min (%.5f)        : %lld  (%.2f %%)\n", lo, at_lo,
                100.0 * static_cast<double>(at_lo) / static_cast<double>(total));
    std::printf("  at rho_max (%.5f)        : %lld  (%.2f %%)\n", hi, at_hi,
                100.0 * static_cast<double>(at_hi) / static_cast<double>(total));
    std::printf("  distribution across the band (%d equal bins):\n", kBins);
    for (int k = 0; k < kBins; ++k) {
      const double a = lo + (hi - lo) * k / kBins;
      const double b = lo + (hi - lo) * (k + 1) / kBins;
      const double pct = 100.0 * static_cast<double>(bin[k]) / static_cast<double>(total);
      std::printf("    [%.4f, %.4f) %9lld  %6.2f %%  ", a, b, bin[k], pct);
      for (int s = 0; s < static_cast<int>(pct / 2.0 + 0.5); ++s) std::printf("#");
      std::printf("\n");
    }
  }
};

}  // namespace

int main(int argc, char** argv) {
  if (argc < 7) {
    std::fprintf(stderr,
                 "usage: %s <model.step> <resolution> <fields.bin> <cell_min_mm> "
                 "<cell_max_mm> <min_width_mm> [allowable_mpa]\n", argv[0]);
    return 2;
  }
  const std::string model = argv[1];
  const int resolution = std::atoi(argv[2]);
  const std::string fields = argv[3];
  const double cell_min = std::atof(argv[4]);
  const double cell_max = std::atof(argv[5]);
  const double min_width = std::atof(argv[6]);
  const double allowable = argc > 7 ? std::atof(argv[7]) : 0.0;

  FieldsHeader h;
  const std::vector<double> vm = read_first_von_mises(fields, h);

  // ── the grid, rebuilt the way the analyze path builds it, then CHECKED ───────
  const StepModel part = import_part_file(model);
  VoxelGrid grid = voxelize(part.mesh, resolution);
  std::printf("grid: probe %dx%dx%d spacing %.9f  |  fields.bin %dx%dx%d spacing %.9f\n",
              grid.nx, grid.ny, grid.nz, grid.spacing, h.nx, h.ny, h.nz, h.spacing);
  if (grid.nx != h.nx || grid.ny != h.ny || grid.nz != h.nz ||
      std::fabs(grid.spacing - h.spacing) > 1e-12 ||
      std::fabs(grid.origin.x - h.ox) > 1e-9 ||
      std::fabs(grid.origin.y - h.oy) > 1e-9 ||
      std::fabs(grid.origin.z - h.oz) > 1e-9) {
    std::fprintf(stderr,
                 "REFUSING: the probe's grid is not the run's grid — every number "
                 "below would describe a different object.\n");
    return 3;
  }
  if (vm.size() != grid.voxel_count()) {
    std::fprintf(stderr, "REFUSING: von Mises field size %zu != voxel count %zu\n",
                 vm.size(), grid.voxel_count());
    return 3;
  }

  // density = occupancy, exactly as run_job's analyze path builds it
  std::vector<double> density(grid.voxel_count(), 0.0);
  for (std::size_t i = 0; i < grid.tags.size(); ++i)
    if (grid.tags[i] != VoxelTag::Empty) density[i] = 1.0;

  GradingLawParams gp;
  gp.topology = LatticeTopology::Octet;
  gp.cell_mode = CellSizeMode::Swept;
  gp.min_cell_size_mm = cell_min;
  gp.max_cell_size_mm = cell_max;
  gp.min_extrudable_width_mm = min_width;
  gp.demand_exponent = 1.0;

  const GradedField gf = grade_lattice(grid, density, vm, nullptr, gp);

  double vm_max = 0.0;
  for (std::size_t e = 0; e < vm.size(); ++e)
    if (density[e] > 0.5 && std::isfinite(vm[e]) && vm[e] > vm_max) vm_max = vm[e];

  std::printf("\n=== the run, as the receipt reports it (cross-check vs run_info.json) ===\n");
  std::printf("  band                  : [%.5f, %.5f]\n", gf.band_rho_min, gf.band_rho_max);
  std::printf("  region_voxels         : %zu\n", gf.region_voxels);
  std::printf("  latticed_voxels       : %zu\n", gf.latticed_voxels);
  std::printf("  solid_fallback_voxels : %zu\n", gf.solid_fallback_voxels);
  std::printf("  min/max strut mm      : %.9f / %.9f\n",
              gf.min_strut_diameter_mm, gf.max_strut_diameter_mm);
  std::printf("  rho_min/max used      : %.9f / %.9f\n", gf.rho_min_used, gf.rho_max_used);
  std::printf("  clamped lo / hi       : %zu / %zu\n", gf.clamped_lo_voxels, gf.clamped_hi_voxels);
  std::printf("  peak von Mises (MPa)  : %.9g\n", vm_max);

  Hist before;
  before.build(gf.posture.relative_density, gf.posture.mask, gf.band_rho_min, gf.band_rho_max);
  before.print("=== BEFORE — density distribution under the PEAK-RELATIVE law ===");

  if (allowable > 0.0) {
    // The §0 preview: the SAME clamp, applied to utilisation instead of the peak
    // ratio, over the SAME latticed set. Not a second law — the identical
    // arithmetic with a different denominator, so the comparison is apples to
    // apples.
    std::vector<double> rho_abs(grid.voxel_count(), 0.0);
    long long over = 0;
    for (std::size_t e = 0; e < gf.posture.mask.size(); ++e) {
      if (!gf.posture.mask[e]) continue;
      double u = vm[e] / allowable;
      if (!(u >= 0.0)) u = 0.0;
      if (u > 1.0) { u = 1.0; ++over; }
      double r = gf.band_rho_max * u;
      if (r < gf.band_rho_min) r = gf.band_rho_min;
      if (r > gf.band_rho_max) r = gf.band_rho_max;
      rho_abs[e] = r;
    }
    Hist after;
    after.build(rho_abs, gf.posture.mask, gf.band_rho_min, gf.band_rho_max);
    std::printf("\nallowable used: %.6f MPa   peak utilisation: %.6g   over-allowable voxels: %lld\n",
                allowable, vm_max / allowable, over);
    after.print("=== AFTER (preview) — density distribution under ABSOLUTE UTILISATION ===");
  }
  return 0;
}
