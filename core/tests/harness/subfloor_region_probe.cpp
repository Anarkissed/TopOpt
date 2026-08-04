// subfloor_region_probe.cpp — task 2026-08-04-subfloor-lattice-unloaded-regions,
// bar S2: WHICH OF THE MAINTAINER'S REGIONS IS ACTUALLY UNLOADED?
//
// THE QUESTION THIS ANSWERS, and why it needed its own probe.
//
// Run with his job document exactly as he wrote it, sub-floor retention retains
// NOTHING. The run measures his region at 0.9102 of the part's peak von Mises,
// nowhere near the 0.20 ceiling, so the predicate refuses. That is not the filter
// being too tight — it is the shape of his job: `grade_lattice` is handed ONE
// candidate mask, the UNION of his 8 include regions minus his 1 exclude, and the
// predicate therefore answers for the union. His union contains four BOLT regions,
// and bolt holes are where the stress is.
//
// His CASE, though, is a single back wall. So the useful question is not "does his
// job qualify" (measured: no) but "which of his regions WOULD, on their own" — and
// that is what this prints, one row per region, measured on his own part.
//
// WHY NOT JUST RUN `lattice-variant` NINE TIMES. That was tried first and it is
// refused, correctly: `lattice_variant` requires the restored design to reproduce
// the run's RECORDED margin BIT-EXACTLY, and on this part a cold certification
// solve lands 9e-6 away from the warm-started one the ladder recorded (3254.356646
// vs 3254.356637 — 2.8e-9 relative). That guard is not weakened here and not
// worked around; the probe simply does not need a solve at all.
//
// NO SOLVE RUNS. Everything below is read off artifacts his run already wrote:
//   design.bin  — the stored density field, per rung
//   fields.bin  — that rung's own per-voxel von Mises, the SAME field the grading
//                 law is handed as `demand` in a real run
// and the region masks are built with core's OWN membership code
// (resolve_clearance_manual + LatticeBoundary), not a re-implementation, so the
// candidate set is the one `lattice_one_variant` would build.
//
// Then `grade_lattice` is called per region, exactly as the run calls it, with
// retention ARMED. The numbers printed are therefore the numbers a real run would
// report — the only thing not re-done is the composite certification solve, and
// the retention predicate does not depend on it.
//
// Prints a table; asserts nothing.
//
//   usage: subfloor_region_probe <job.json> <run-dir> <rung-volume-fraction>

#include "topopt/clearance.hpp"
#include "topopt/design_store.hpp"
#include "topopt/grading.hpp"
#include "topopt/job.hpp"
#include "topopt/lattice.hpp"
#include "topopt/lattice_boundary.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

using namespace topopt;

namespace {

// fields.bin v1 (core/include/topopt/fields.hpp). The version byte is checked
// first, as that header requires. Returns the von Mises field of the block whose
// requested volume fraction matches `want`, or an empty vector.
std::vector<double> read_von_mises(const std::string& path, double want,
                                   int& nx, int& ny, int& nz) {
  std::ifstream f(path, std::ios::binary);
  if (!f) return {};
  std::vector<char> b((std::istreambuf_iterator<char>(f)),
                      std::istreambuf_iterator<char>());
  std::size_t o = 0;
  if (b.empty() || static_cast<unsigned char>(b[0]) != 1) return {};
  o = 4;
  auto rd_i32 = [&](void) { std::int32_t v; std::memcpy(&v, &b[o], 4); o += 4; return v; };
  auto rd_i64 = [&](void) { std::int64_t v; std::memcpy(&v, &b[o], 8); o += 8; return v; };
  auto rd_f64 = [&](void) { double v; std::memcpy(&v, &b[o], 8); o += 8; return v; };
  nx = rd_i32(); ny = rd_i32(); nz = rd_i32();
  o += 8 * 3;              // origin
  o += 8;                  // spacing
  o += 8;                  // voxel volume
  const int nvar = rd_i32();
  o += 4;                  // reserved
  for (int v = 0; v < nvar; ++v) {
    const double vf = rd_f64();
    o += 8;                // mass
    o += 8;                // support voxels + reserved
    const std::int64_t vm_n = rd_i64();
    const std::int64_t st_n = rd_i64();
    const std::int64_t dp_n = rd_i64();
    if (std::fabs(vf - want) < 1e-9 && vm_n > 0) {
      std::vector<double> out(static_cast<std::size_t>(vm_n));
      for (std::int64_t e = 0; e < vm_n; ++e) {
        float x; std::memcpy(&x, &b[o + 4 * static_cast<std::size_t>(e)], 4);
        out[static_cast<std::size_t>(e)] = static_cast<double>(x);
      }
      return out;
    }
    o += 4 * static_cast<std::size_t>(vm_n + st_n + dp_n);
  }
  return {};
}

// The SAME resolution `lattice_role_regions_from_job` (run_job.cpp) applies —
// spelled here rather than shared because run_job's copy is file-static. Any
// divergence would make this probe measure a different region set than a run, so
// it is deliberately kept to the same shape: a manual primitive with all
// clearance margins at zero, because the primitive IS the region.
ClearanceGeometry region_geometry(const JobLatticeRegion& r) {
  ManualClearanceGeometry mg;
  ClearanceParams p;
  if (r.kind == "bolt") {
    mg.kind = ClearanceKind::Bolt;
    p.kind = ClearanceKind::Bolt;
    mg.axis_point = r.axis_point;
    mg.axis_dir = r.axis_dir;
    mg.radius_mm = r.radius_mm;
    mg.half_length_mm = r.half_length_mm;
  } else {
    mg.kind = ClearanceKind::Face;
    p.kind = ClearanceKind::Face;
    p.slab_depth_mm = r.depth_mm;
    mg.origin = r.origin;
    mg.normal = r.normal;
    mg.half_u_mm = r.half_u_mm;
    mg.half_w_mm = r.half_w_mm;
  }
  return resolve_clearance_manual(mg, p);
}

std::string describe(const JobLatticeRegion& r) {
  char buf[128];
  if (r.kind == "bolt")
    std::snprintf(buf, sizeof buf, "bolt r=%.0f at (%.0f,%.0f,%.0f)", r.radius_mm,
                  r.axis_point.x, r.axis_point.y, r.axis_point.z);
  else
    std::snprintf(buf, sizeof buf, "face n=(%.0f,%.0f,%.0f) %.0fx%.0fmm d=%.0f",
                  r.normal.x, r.normal.y, r.normal.z, 2 * r.half_u_mm,
                  2 * r.half_w_mm, r.depth_mm);
  return buf;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 4) {
    std::fprintf(stderr,
                 "usage: subfloor_region_probe <job.json> <run-dir> <rung-vf>\n");
    return 2;
  }
  const std::string job_path = argv[1];
  const std::string run_dir = argv[2];
  const double want_vf = std::atof(argv[3]);

  const JobDescription job = load_job_file(job_path);
  const DesignStore store = read_design_file(run_dir + "/design.bin");

  const StoredDesign* sd = nullptr;
  for (const StoredDesign& v : store.variants)
    if (std::fabs(v.requested_volume_fraction - want_vf) < 1e-9) sd = &v;
  if (!sd) {
    std::fprintf(stderr, "no variant at volume fraction %.4f in design.bin\n",
                 want_vf);
    return 1;
  }

  int fx = 0, fy = 0, fz = 0;
  const std::vector<double> vm =
      read_von_mises(run_dir + "/fields.bin", want_vf, fx, fy, fz);
  if (vm.empty()) {
    std::fprintf(stderr, "no von Mises field for that rung in fields.bin\n");
    return 1;
  }

  VoxelGrid grid;
  grid.nx = store.nx; grid.ny = store.ny; grid.nz = store.nz;
  grid.origin = store.origin;
  grid.spacing = store.spacing;
  // NOTE: VoxelGrid::voxel_count() is tags.size(), not nx*ny*nz — so the tag
  // vector has to be sized from the dimensions directly, before it can be asked
  // how big it is.
  const std::size_t nvox = static_cast<std::size_t>(store.nx) *
                           static_cast<std::size_t>(store.ny) *
                           static_cast<std::size_t>(store.nz);
  grid.tags.assign(nvox, VoxelTag::Empty);
  for (std::size_t e = 0; e < nvox; ++e)
    if (sd->density[e] > 0.5) grid.tags[e] = VoxelTag::Interior;

  if (vm.size() != grid.voxel_count()) {
    std::fprintf(stderr, "fields.bin grid (%d x %d x %d, %zu values) disagrees "
                 "with design.bin (%d x %d x %d, %zu voxels)\n", fx, fy, fz,
                 vm.size(), grid.nx, grid.ny, grid.nz, grid.voxel_count());
    return 1;
  }

  const double n_star = lattice_cells_per_member_min(LatticeTopology::Octet);
  const double ceiling = lattice_subfloor_retention_stress_fraction();

  // The grading params his job declares, verbatim.
  GradingLawParams gp;
  gp.topology = LatticeTopology::Octet;
  gp.target_cell_size_mm = job.grading.cell_mm;
  gp.min_extrudable_width_mm = job.grading.min_extrudable_width_mm;
  gp.demand_exponent = job.grading.demand_exponent;
  if (!cell_size_mode_from_name(job.grading.cell_mode.c_str(), gp.cell_mode)) {
    std::fprintf(stderr, "unknown grading cell_mode\n");
    return 1;
  }
  gp.min_cell_size_mm = job.grading.cell_min_mm;
  gp.max_cell_size_mm = job.grading.cell_max_mm;
  gp.retain_subfloor_in_unloaded_regions = true;

  std::printf("=== S2 — the maintainer's regions, ONE AT A TIME, measured on his "
              "own part ===\n");
  std::printf("job: %s\nrun: %s\nrung: %.2f   grid %dx%dx%d @ %.4f mm\n",
              job_path.c_str(), run_dir.c_str(), want_vf, grid.nx, grid.ny,
              grid.nz, grid.spacing);
  std::printf("cells-per-member floor n* = %.1f; retention ceiling = %.2f of the "
              "part's peak von Mises.\n", n_star, ceiling);
  std::printf("NO SOLVE RAN: the demand field is this rung's own von Mises, read "
              "from fields.bin.\n\n");

  // The excludes apply in every row, exactly as in his job.
  std::vector<ClearanceGeometry> excludes;
  for (const JobLatticeRegion& r : job.lattice.regions)
    if (r.role != "include") {
      const ClearanceGeometry g = region_geometry(r);
      if (g.valid) excludes.push_back(g);
    }

  std::printf("%-3s %-38s %10s %10s %12s %5s %10s %10s %8s\n", "#", "region",
              "region vox", "below flr", "stressfrac", "qual", "retained",
              "latticed%", "min cpm");
  std::printf("%s\n", std::string(118, '-').c_str());

  auto measure = [&](const std::string& label,
                     const std::vector<ClearanceGeometry>& includes) {
    LatticeBoundary members;
    for (const ClearanceGeometry& g : includes) members.add_include_region(g);
    for (const ClearanceGeometry& g : excludes) members.add_exclude_region(g);
    std::vector<char> cand(grid.voxel_count(), 0);
    for (int k = 0; k < grid.nz; ++k)
      for (int j = 0; j < grid.ny; ++j)
        for (int i = 0; i < grid.nx; ++i) {
          const std::size_t e = grid.index(i, j, k);
          if (!(sd->density[e] > 0.5)) continue;
          const Vec3 c{grid.origin.x + (i + 0.5) * grid.spacing,
                       grid.origin.y + (j + 0.5) * grid.spacing,
                       grid.origin.z + (k + 0.5) * grid.spacing};
          if (members.in_exclude_region(c, 0.0)) continue;
          if (members.has_include_regions() && !members.in_include_region(c, 0.0))
            continue;
          cand[e] = 1;
        }
    GradedField gf;
    try {
      gf = grade_lattice(grid, sd->density, vm, &cand, gp);
    } catch (const std::exception& e) {
      std::printf("%-3s %-38s  grade_lattice refused: %s\n", "", label.c_str(),
                  e.what());
      return;
    }
    const double frac = gf.region_voxels > 0
                            ? static_cast<double>(gf.latticed_voxels) /
                                  static_cast<double>(gf.region_voxels)
                            : 0.0;
    std::printf("%-3s %-38s %10zu %10zu %12.4f %5s %10zu %9.1f%% %8.2f\n", "",
                label.c_str(), gf.region_voxels, gf.subfloor_candidate_voxels,
                gf.region_stress_fraction,
                gf.region_qualified_unloaded ? "YES" : "no",
                gf.subfloor_retained_voxels, 100.0 * frac,
                gf.subfloor_min_cells_per_member);
  };

  std::vector<ClearanceGeometry> all_includes;
  std::vector<const JobLatticeRegion*> inc_refs;
  for (const JobLatticeRegion& r : job.lattice.regions)
    if (r.role == "include") {
      const ClearanceGeometry g = region_geometry(r);
      if (!g.valid) continue;
      all_includes.push_back(g);
      inc_refs.push_back(&r);
    }

  measure("ALL, UNION predicate (what shipped)", all_includes);
  for (std::size_t i = 0; i < all_includes.size(); ++i) {
    char lbl[128];
    std::snprintf(lbl, sizeof lbl, "%zu: %s", i, describe(*inc_refs[i]).c_str());
    measure(lbl, {all_includes[i]});
  }

  // ── THE WIDENING, AND WHAT IT TOTALS TO ────────────────────────────────────
  // All regions at once with the PER-REGION predicate armed. This is the number
  // the aggregate cap bounds, and the one a per-region breakdown alone would not
  // give you: "each region qualified individually" and "the part is fine" are
  // different statements, and only this line answers the second.
  {
    LatticeBoundary members;
    for (const ClearanceGeometry& g : all_includes) members.add_include_region(g);
    for (const ClearanceGeometry& g : excludes) members.add_exclude_region(g);
    std::vector<char> cand(nvox, 0);
    std::vector<int> ids(nvox, 0);
    for (int k = 0; k < grid.nz; ++k)
      for (int j = 0; j < grid.ny; ++j)
        for (int i = 0; i < grid.nx; ++i) {
          const std::size_t e = grid.index(i, j, k);
          if (!(sd->density[e] > 0.5)) continue;
          const Vec3 c{grid.origin.x + (i + 0.5) * grid.spacing,
                       grid.origin.y + (j + 0.5) * grid.spacing,
                       grid.origin.z + (k + 0.5) * grid.spacing};
          if (members.in_exclude_region(c, 0.0)) continue;
          if (members.has_include_regions() && !members.in_include_region(c, 0.0))
            continue;
          cand[e] = 1;
          for (std::size_t ri = 0; ri < all_includes.size(); ++ri)
            if (point_in_clearance_region(all_includes[ri], c, 0.0)) {
              ids[e] = static_cast<int>(ri) + 1;
              break;
            }
        }
    GradingLawParams pr = gp;
    pr.region_ids = &ids;
    GradedField r = grade_lattice(grid, sd->density, vm, &cand, pr);
    std::printf("\n=== PER-REGION PREDICATE, all regions at once ===\n");
    std::printf("%-4s %10s %10s %12s %6s %10s\n", "id", "candidate", "below flr",
                "stressfrac", "qual", "retained");
    for (const GradedField::SubfloorRegion& x : r.subfloor_regions)
      std::printf("%-4d %10zu %10zu %12.4f %6s %10zu\n", x.region_id,
                  x.candidate_voxels, x.below_floor_voxels, x.stress_fraction,
                  x.qualified ? "YES" : "no", x.retained_voxels);
    std::printf("\nTHE AGGREGATE — the number the cap bounds:\n");
    std::printf("  part printed voxels            : %zu\n", r.part_printed_voxels);
    std::printf("  would retain (before the cap)  : %zu\n",
                r.subfloor_would_retain_voxels);
    std::printf("  RETAINED, all regions summed   : %zu\n",
                r.subfloor_retained_voxels);
    std::printf("  exposure, fraction of the part : %.5f  (%.3f %%)\n",
                r.subfloor_retained_fraction_of_part,
                100.0 * r.subfloor_retained_fraction_of_part);
    std::printf("  aggregate cap in force         : %.5f  (%.3f %%)\n",
                r.subfloor_aggregate_cap_fraction,
                100.0 * r.subfloor_aggregate_cap_fraction);
    std::printf("  OVER BUDGET                    : %s\n",
                r.subfloor_over_budget ? "YES — nothing retained" : "no");
    std::size_t qualified = 0;
    for (const GradedField::SubfloorRegion& x : r.subfloor_regions)
      if (x.qualified) ++qualified;
    std::printf("\n  regions qualifying individually: %zu of %zu\n", qualified,
                r.subfloor_regions.size());
    std::printf("  DO THE TWO READINGS AGREE? %s\n",
                r.subfloor_over_budget
                    ? "NO — every retained region passed its own test, and the "
                      "TOTAL still\n     exceeded what this task is willing to "
                      "hold under an unpriceable claim."
                    : "yes — the per-region verdicts and the part-level exposure "
                      "point the same way.");
  }

  std::printf("\nREAD IT LIKE THIS.\n");
  std::printf("  stressfrac  this region's PEAK von Mises over the PART's peak,\n");
  std::printf("              measured from the rung's own field — never declared.\n");
  std::printf("  qual        whether that cleared the ceiling above. A region that\n");
  std::printf("              does not qualify is left exactly as it is today: SOLID.\n");
  std::printf("  below flr   voxels whose member cannot hold n* cells across. This\n");
  std::printf("              is the population retention is about, and it is counted\n");
  std::printf("              whether or not the region qualifies.\n");
  std::printf("  retained    how many of those were kept as lattice. Where this is\n");
  std::printf("              non-zero the certificate over that material is OUT OF\n");
  std::printf("              REGIME, and the run says so.\n");
  return 0;
}
