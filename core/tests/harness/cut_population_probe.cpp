// cut_population_probe — S2 of task 2026-08-08-smoothing-that-works-and-is-usable.
//
// THE MEASUREMENT PR 306 STOPPED SHORT OF, AND SAID SO. It raced mean-curvature
// flow against the shipped Taubin smoother on an analytic sphere, MCF won 51.6%
// to 11.2%, and it then refused to go further because the CAD-versus-cut
// classifier did not exist and it would not write a second one. PR 307 merged
// that classifier. This probe finishes the job on the maintainer's OWN part.
//
//   cmake --build core/build --target cut_population_probe
//   ./core/build/cut_population_probe <design.bin> <part.step> <evidence_dir>
//
// ── WHAT IS MEASURED, AND THE ONE THING THAT COULD NOT BE ────────────────────
//
// The brief asks for "PR 299's metric unchanged" on the cut population. PR 299's
// metric is the unsigned distance from each exported vertex to the ORIGINAL CAD
// SURFACE, and its whole justification is that the CAD is the smooth surface the
// staircase is an error against — "it has a floor at 0 that no cheat reaches".
//
// ON THE CUT POPULATION THAT REFERENCE DOES NOT EXIST. Those vertices are surface
// the optimizer cut; the CAD says nothing about where they should be, and the
// distance from a cut surface to the nearest CAD triangle is a geometric fact
// about the part's shape, not an error. Driving it down would mean pulling the
// optimizer's own structure toward the CAD, which is damage, not smoothing.
//
// So this probe does three things instead of quietly substituting a metric:
//
//   1. It MEASURES the claim rather than asserting it (S2.1): the same design
//      field is extracted at the shipped tessellation and at twice that, and the
//      two surfaces are compared. If the staircase were a tessellation artefact,
//      a finer extraction of the same field would remove it and would BE the
//      reference. PR 303 S1.6 already found it does not; this reproduces that on
//      the cut population specifically, so the "no reference exists" claim is a
//      reading and not an argument.
//
//   2. On the CAD population — where PR 299's metric IS defined, because those
//      vertices do have a correct answer — it runs the calibrated comparison. It
//      is the only place on his part where "how much stair-step amplitude does
//      this operator remove" has a truthful answer, and it is reported as such.
//
//   3. On the CUT population it reports what CAN be known without a ground
//      truth, with the controls that make PR 299's objection to intrinsic
//      roughness ("melting the part also reduces it") inapplicable: surface
//      motion is bounded by C1 at half a cell, volume is held by C3, and the
//      minimum cross-section of every tendril is measured geometrically. A
//      dihedral reduction bought by melting shows up in those three columns.
//
// ── C4 ───────────────────────────────────────────────────────────────────────
// Every vertex the classifier attributes to a CAD face is FROZEN, for both
// operators, and the result is asserted BIT-IDENTICAL — not "small". MCF takes
// it through TrustSign::Pinned; Taubin takes it through vertex_weight 0, which is
// its own copy-verbatim branch. Same fact, each operator's own mechanism, one
// classifier.

#include "topopt/cad_project.hpp"
#include "topopt/design_store.hpp"
#include "topopt/face_overrides.hpp"
#include "topopt/mesh.hpp"
#include "topopt/smooth.hpp"
#include "topopt/step.hpp"
#include "topopt/surface_operator.hpp"
#include "topopt/voxel.hpp"

#include "stairstep_metric.hpp"
#include "surface_instruments.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

using namespace topopt;
using namespace topopt::stairstep;
using namespace topopt::surface_instruments;

namespace {

// THE SHIPPED EXPORT. `run_job.cpp` extracts the variant mesh at
// `output.smooth_factor` with a tricubic resample and keeps the largest
// component. Reproduced here so the subject is the file he actually receives.
constexpr int kShippedFactor = 2;

TriangleMesh extract(const VoxelGrid& g, const std::vector<double>& rho,
                     int factor) {
  return keep_largest_component(marching_cubes_resampled(
      g.nx, g.ny, g.nz, g.spacing, g.origin, rho, 0.5, factor,
      ResampleInterp::Tricubic));
}

struct Population {
  std::vector<char> cad;   // attributed to a CAD face — C4 freezes these
  std::vector<char> cut;   // attributed to nothing — the brush's whole domain
  std::size_t n_cad = 0, n_cut = 0, n_ambiguous = 0;
};

Population split(const CadAttribution& att, std::size_t nverts) {
  Population p;
  p.cad.assign(nverts, 0);
  p.cut.assign(nverts, 0);
  for (std::size_t v = 0; v < nverts; ++v) {
    if (att.face_of_vertex[v] >= 0) { p.cad[v] = 1; ++p.n_cad; }
    else if (att.ambiguous_at(v))   { ++p.n_ambiguous; }
    else                            { p.cut[v] = 1; ++p.n_cut; }
  }
  return p;
}

struct Motion {
  double max_mm = 0.0, rms_mm = 0.0;
  std::size_t moved = 0;
};

Motion motion(const TriangleMesh& a, const TriangleMesh& b,
              const std::vector<char>& only) {
  Motion m;
  double s2 = 0.0;
  std::size_t n = 0;
  const std::size_t lim = std::min(a.vertices.size(), b.vertices.size());
  for (std::size_t v = 0; v < lim; ++v) {
    if (!only.empty() && !only[v]) continue;
    const double dx = b.vertices[v].x - a.vertices[v].x;
    const double dy = b.vertices[v].y - a.vertices[v].y;
    const double dz = b.vertices[v].z - a.vertices[v].z;
    const double d = std::sqrt(dx * dx + dy * dy + dz * dz);
    if (d > 0.0) ++m.moved;
    if (d > m.max_mm) m.max_mm = d;
    s2 += d * d;
    ++n;
  }
  if (n) m.rms_mm = std::sqrt(s2 / static_cast<double>(n));
  return m;
}

// C4, ASSERTED AS BIT-IDENTITY. Returns the number of CAD-attributed vertices
// that are not byte-for-byte where they started.
std::size_t cad_vertices_that_moved(const TriangleMesh& a, const TriangleMesh& b,
                                    const std::vector<char>& cad) {
  std::size_t bad = 0;
  const std::size_t lim = std::min(a.vertices.size(), b.vertices.size());
  for (std::size_t v = 0; v < lim; ++v) {
    if (!cad[v]) continue;
    if (std::memcmp(&a.vertices[v], &b.vertices[v], sizeof(Vec3)) != 0) ++bad;
  }
  return bad;
}

double signed_volume_abs(const TriangleMesh& m) {
  return std::fabs(signed_volume(m));
}

struct Row {
  std::string label;
  int iterations = 0;
  double wall_s = 0.0;
  Motion cut_motion, cad_motion;
  double dihedral_before = 0.0, dihedral_after = 0.0;
  double vol_before = 0.0, vol_after = 0.0;
  double cad_dev_rms_before = 0.0, cad_dev_rms_after = 0.0;
  double cad_dev_max_before = 0.0, cad_dev_max_after = 0.0;
  std::size_t c4_violations = 0;
  std::size_t c1_clamped = 0, c2_projected = 0, pinned = 0;
  SliceSection section;
};

}  // namespace


int main(int argc, char** argv) {
  if (argc < 3) {
    std::printf("usage: cut_population_probe <design.bin> <part.step> [evidence_dir]\n");
    return 2;
  }
  const std::string design_path = argv[1];
  const std::string step_path = argv[2];
  const std::string ev = argc > 3 ? argv[3] : ".";

  DesignStore store = read_design_file(design_path);
  VoxelGrid grid;
  grid.nx = store.nx; grid.ny = store.ny; grid.nz = store.nz;
  grid.spacing = store.spacing; grid.origin = store.origin;
  grid.tags.assign(store.voxel_count(), VoxelTag::Empty);

  std::printf("== cut_population_probe — S2 on HIS OWN PART ==\n\n");
  std::printf("design   %s\n", design_path.c_str());
  std::printf("part     %s\n", step_path.c_str());
  std::printf("grid     %d x %d x %d, spacing %.6f mm\n", grid.nx, grid.ny,
              grid.nz, grid.spacing);
  std::printf("export   shipped tessellation factor %d (tricubic), so the lattice\n"
              "         that PRODUCED the vertices has cell %.6f mm and C1's trust\n"
              "         radius at 0.5 cells is %.6f mm\n",
              kShippedFactor, grid.spacing / kShippedFactor,
              0.5 * grid.spacing / kShippedFactor);
  std::printf("rungs    %zu\n\n", store.variants.size());

  const StepModel model = import_part_file_resolved(step_path);
  if (model.mesh.vertices.empty()) {
    std::printf("FATAL: the STEP imported empty — OCCT is required for this probe\n");
    return 2;
  }
  std::printf("CAD      %zu faces over %zu tessellation triangles\n\n",
              model.faces.size(), model.mesh.triangles.size());

  const CadProjectOptions copts = cad_project_options_for_grid(grid.spacing);
  const double cell_mm = grid.spacing / kShippedFactor;

  std::ofstream csv(ev + "/s2_cut_population.csv");
  csv << "rung,operator,iterations,wall_s,cut_max_mm,cut_rms_mm,cut_moved,"
         "cad_moved_bitwise,dihedral_before,dihedral_after,vol_before_mm3,"
         "vol_after_mm3,vol_drift_pct,cad_dev_rms_before,cad_dev_rms_after,"
         "cad_removed_pct,c1_clamped,c2_projected,pinned,min_section_mm2\n";

  for (std::size_t r = 0; r < store.variants.size(); ++r) {
    const StoredDesign& d = store.variants[r];
    char rung[64];
    std::snprintf(rung, sizeof rung, "%.2f", d.requested_volume_fraction);

    const Clock::time_point te = Clock::now();
    const TriangleMesh subject = extract(grid, d.density, kShippedFactor);
    const double extract_s = secs_since(te);

    std::printf("=====================================================================\n");
    std::printf("RUNG %s — %zu vertices / %zu triangles (extracted in %.2f s)\n",
                rung, subject.vertices.size(), subject.triangles.size(), extract_s);
    std::printf("=====================================================================\n");

    // ── the split ────────────────────────────────────────────────────────────
    const Clock::time_point ta = Clock::now();
    const CadAttribution att = attribute_to_cad_faces(subject, model, copts);
    const Population pop = split(att, subject.vertices.size());
    std::printf("\n-- THE SPLIT (PR 307's classifier, not a second one) ---------------\n");
    std::printf("  CAD-attributed %8zu (%5.2f%%)   <- C4 freezes every one of these\n",
                pop.n_cad, 100.0 * pop.n_cad / subject.vertices.size());
    std::printf("  ambiguous      %8zu (%5.2f%%)   <- on a CAD edge; also frozen\n",
                pop.n_ambiguous, 100.0 * pop.n_ambiguous / subject.vertices.size());
    std::printf("  OPTIMIZER-CUT  %8zu (%5.2f%%)   <- the brush's whole domain\n",
                pop.n_cut, 100.0 * pop.n_cut / subject.vertices.size());
    std::printf("  (attribution took %.2f s)\n", secs_since(ta));

    // ── S2.1: IS THERE A REFERENCE AT ALL? ───────────────────────────────────
    // Extract the SAME field twice as finely. If the staircase were the
    // tessellation, this surface would not have it and would be the reference.
    const Clock::time_point tf = Clock::now();
    const TriangleMesh finer = extract(grid, d.density, kShippedFactor * 2);
    const TriGrid finer_grid(finer);
    const Deviation dev_all = deviation_from_cad(subject, finer_grid);
    const Deviation dev_cut = deviation_from_cad(subject, finer_grid, pop.cut);
    std::printf("\n-- S2.1 IS A FINER EXTRACTION OF THE SAME FIELD A REFERENCE? ------\n");
    std::printf("  factor %d: %zu verts   factor %d: %zu verts   (%.1f s)\n",
                kShippedFactor, subject.vertices.size(), kShippedFactor * 2,
                finer.vertices.size(), secs_since(tf));
    std::printf("  the shipped surface deviates from the finer one by:\n");
    std::printf("      all vertices   max %.4f mm  rms %.4f mm  (%.1f%% of a voxel)\n",
                dev_all.max_mm, dev_all.rms_mm, 100.0 * dev_all.rms_mm / grid.spacing);
    std::printf("      CUT vertices   max %.4f mm  rms %.4f mm  (%.1f%% of a voxel)\n",
                dev_cut.max_mm, dev_cut.rms_mm, 100.0 * dev_cut.rms_mm / grid.spacing);
    std::printf("  READ THIS AGAINST THE STAIRCASE ITSELF: PR 299 measured the\n");
    std::printf("  stair-step amplitude at rms 0.3424 mm = 21%% of its voxel. A finer\n");
    std::printf("  extraction that moves the surface by far less than that is not\n");
    std::printf("  removing the staircase, and therefore is not a reference for it.\n");

    // ── the constraints, shared by both operators ───────────────────────────
    TrustSignPolicy policy;
    std::vector<TrustSign> sign =
        classify_trust_sign(subject, grid, d.density, policy);
    std::size_t pinned_by_c4 = 0;
    for (std::size_t v = 0; v < subject.vertices.size(); ++v) {
      // ★ C4, THE ONE LINE PR 306 NAMED. A vertex the CAD can account for does
      // not move, whatever else is true of it. `ambiguous` is folded in on the
      // safe side: a vertex on a CAD edge could belong to either surface, so it
      // is frozen rather than guessed at.
      if (pop.cad[v] || att.ambiguous_at(v)) {
        sign[v] = TrustSign::Pinned;
        ++pinned_by_c4;
      }
    }

    std::vector<double> taubin_weight(subject.vertices.size(), 1.0);
    for (std::size_t v = 0; v < subject.vertices.size(); ++v)
      if (sign[v] == TrustSign::Pinned) taubin_weight[v] = 0.0;

    const double vol0 = signed_volume_abs(subject);
    const double dih0 = dihedral_rms_deg(subject);
    const TriGrid cad_ref(model.mesh);
    const Deviation cad0 = deviation_from_cad(subject, cad_ref, pop.cad);
    const SliceSection sec0 = min_slice_section_of(subject, grid);

    std::vector<Row> rows;

    auto record = [&](const std::string& label, const TriangleMesh& out,
                      int iters, double wall, const SurfaceOperatorStats* st) {
      Row row;
      row.label = label;
      row.iterations = iters;
      row.wall_s = wall;
      row.cut_motion = motion(subject, out, pop.cut);
      row.cad_motion = motion(subject, out, pop.cad);
      row.c4_violations = cad_vertices_that_moved(subject, out, pop.cad);
      row.dihedral_before = dih0;
      row.dihedral_after = dihedral_rms_deg(out);
      row.vol_before = vol0;
      row.vol_after = signed_volume_abs(out);
      row.cad_dev_rms_before = cad0.rms_mm;
      row.cad_dev_max_before = cad0.max_mm;
      const Deviation da = deviation_from_cad(out, cad_ref, pop.cad);
      row.cad_dev_rms_after = da.rms_mm;
      row.cad_dev_max_after = da.max_mm;
      if (st) {
        row.c1_clamped = st->c1_clamped;
        row.c2_projected = st->c2_projected;
        row.pinned = st->pinned;
      }
      row.section = min_slice_section_of(out, grid);
      rows.push_back(row);
      csv << rung << "," << label << "," << iters << "," << wall << ","
          << row.cut_motion.max_mm << "," << row.cut_motion.rms_mm << ","
          << row.cut_motion.moved << "," << row.c4_violations << ","
          << row.dihedral_before << "," << row.dihedral_after << ","
          << row.vol_before << "," << row.vol_after << ","
          << 100.0 * (row.vol_after - row.vol_before) / row.vol_before << ","
          << row.cad_dev_rms_before << "," << row.cad_dev_rms_after << ","
          << (row.cad_dev_rms_before > 0
                  ? 100.0 * (1.0 - row.cad_dev_rms_after / row.cad_dev_rms_before)
                  : 0.0)
          << "," << row.c1_clamped << "," << row.c2_projected << ","
          << row.pinned << "," << row.section.min_area_mm2 << "\n";
    };

    // ── the incumbent ────────────────────────────────────────────────────────
    for (const int pairs : {20, 160}) {
      TaubinParams tp;
      tp.pairs = pairs;
      SmoothConstraints tc;
      tc.enforce_min_feature = false;   // PR 299's "off" rows: the family's best case
      tc.vertex_weight = taubin_weight; // C4, through Taubin's own verbatim branch
      const Clock::time_point t0 = Clock::now();
      const SmoothResult sr = constrained_taubin_smooth(subject, tp, tc);
      record("Taubin_pairs_" + std::to_string(pairs), sr.mesh,
             sr.stats.applied_pairs, secs_since(t0), nullptr);
    }

    // ── the candidate ────────────────────────────────────────────────────────
    for (const int steps : {5, 20, 40}) {
      MeanCurvatureParams mp;
      mp.steps = steps;
      SurfaceConstraints sc;
      sc.cell_mm = cell_mm;
      sc.trust_voxels = 0.5;
      sc.sign = sign;           // C2 + C4
      sc.preserve_volume = true;  // C3
      const Clock::time_point t0 = Clock::now();
      const SurfaceOperatorResult sr = mean_curvature_flow(subject, mp, sc);
      record("MCF_x" + std::to_string(steps), sr.mesh, sr.stats.applied_steps,
             secs_since(t0), &sr.stats);
    }

    // ── the table ────────────────────────────────────────────────────────────
    std::printf("\n-- THE BAKE-OFF ON THE CUT POPULATION ------------------------------\n");
    std::printf("  C4: %zu vertices frozen (CAD + ambiguous). The `cadmoved` column\n"
                "  is a BITWISE count and must read 0 on every row.\n\n", pinned_by_c4);
    std::printf("operator            iters   wall_s   cutmax   cutrms  cutmoved  cadmoved"
                "   dihed_b  dihed_a    vol%%   minsec_mm2\n");
    std::printf("as exported             0    0.000   0.0000   0.0000         0         0"
                "   %7.2f  %7.2f   0.000   %10.4f\n", dih0, dih0, sec0.min_area_mm2);
    for (const Row& x : rows) {
      std::printf("%-18s %6d  %7.3f   %6.4f   %6.4f  %8zu  %8zu   %7.2f  %7.2f  %6.3f   %10.4f\n",
                  x.label.c_str(), x.iterations, x.wall_s, x.cut_motion.max_mm,
                  x.cut_motion.rms_mm, x.cut_motion.moved, x.c4_violations,
                  x.dihedral_before, x.dihedral_after,
                  100.0 * (x.vol_after - x.vol_before) / x.vol_before,
                  x.section.min_area_mm2);
    }

    std::printf("\n-- THE CALIBRATED READING, ON THE CAD POPULATION -------------------\n");
    std::printf("  PR 299's metric IS defined here — these vertices have a correct\n");
    std::printf("  answer. With C4 armed nothing may move, so every row must read\n");
    std::printf("  UNCHANGED; that is the assertion, not a result. The un-frozen\n");
    std::printf("  arm below is what the operators would do to his CAD if C4 were off.\n");
    std::printf("  as exported: rms %.4f mm  max %.4f mm over %zu CAD vertices\n",
                cad0.rms_mm, cad0.max_mm, pop.n_cad);
    for (const Row& x : rows)
      std::printf("  %-18s rms %.4f -> %.4f mm   max %.4f -> %.4f mm\n",
                  x.label.c_str(), x.cad_dev_rms_before, x.cad_dev_rms_after,
                  x.cad_dev_max_before, x.cad_dev_max_after);

    // ── the unfrozen arm: the calibrated amplitude comparison ────────────────
    std::printf("\n-- C4 OFF: WHAT EACH OPERATOR DOES TO SURFACE THAT HAS AN ANSWER ---\n");
    std::printf("  This is the ONLY place on his part where 'how much stair-step\n");
    std::printf("  amplitude does this operator remove' is a truthful question, and\n");
    std::printf("  it is measured with PR 299's metric verbatim. It is NOT a proposal\n");
    std::printf("  to run either operator here — PR 307's projection owns this surface\n");
    std::printf("  and is exact. It is the calibration for the cut-population table.\n");
    std::printf("operator            iters   wall_s   cad_rms_mm   removed%%   cad_max_mm\n");
    std::printf("as exported             0    0.000     %8.4f      0.0%%     %8.4f\n",
                cad0.rms_mm, cad0.max_mm);
    {
      for (const int pairs : {20, 160}) {
        TaubinParams tp;
        tp.pairs = pairs;
        SmoothConstraints tc;
        tc.enforce_min_feature = false;
        const Clock::time_point t0 = Clock::now();
        const SmoothResult sr = constrained_taubin_smooth(subject, tp, tc);
        const double w = secs_since(t0);
        const Deviation da = deviation_from_cad(sr.mesh, cad_ref, pop.cad);
        std::printf("Taubin_pairs_%-6d %6d  %7.3f     %8.4f    %6.1f%%     %8.4f\n",
                    pairs, sr.stats.applied_pairs, w, da.rms_mm,
                    100.0 * (1.0 - da.rms_mm / cad0.rms_mm), da.max_mm);
      }
      for (const int steps : {5, 20, 40}) {
        MeanCurvatureParams mp;
        mp.steps = steps;
        SurfaceConstraints sc;
        sc.cell_mm = cell_mm;
        sc.trust_voxels = 0.5;
        sc.preserve_volume = true;
        const Clock::time_point t0 = Clock::now();
        const SurfaceOperatorResult sr = mean_curvature_flow(subject, mp, sc);
        const double w = secs_since(t0);
        const Deviation da = deviation_from_cad(sr.mesh, cad_ref, pop.cad);
        std::printf("MCF_x%-14d %6d  %7.3f     %8.4f    %6.1f%%     %8.4f\n",
                    steps, sr.stats.applied_steps, w, da.rms_mm,
                    100.0 * (1.0 - da.rms_mm / cad0.rms_mm), da.max_mm);
      }
    }
    std::printf("\n");
    std::fflush(stdout);
  }
  return 0;
}
