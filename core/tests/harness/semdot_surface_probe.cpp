// semdot_surface_probe — S2 of task 2026-08-08-semdot-does-it-come-out-smoother.
//
// THE ONE QUESTION: does the optimizer produce smoother geometry on HIS part?
// Two design.bin files — one from the SIMP path, one from the SEMDOT path, the
// same job document otherwise — measured side by side on the same instruments PR
// 314/315 used, which are INCLUDED here and not retyped (bar R3).
//
//   cmake --build build --target semdot_surface_probe
//   ./build/semdot_surface_probe <simp/design.bin> <semdot/design.bin> \
//        <part.step> <evidence_dir>
//
// ── WHAT IS MEASURED, AND WHERE EACH NUMBER IS DEFINED ──────────────────────
//
// PR 314 established that on the OPTIMIZER-CUT population there is no ground
// truth: those vertices are surface the optimizer invented, the CAD says nothing
// about where they should be, and the distance from a cut surface to the nearest
// CAD triangle is a fact about the part's shape, not an error. That did not stop
// mattering when the operator changed. So this probe reports, per rung, per arm:
//
//   * ON THE CAD POPULATION, restricted to the OBLIQUE surface — PR 299's metric
//     verbatim (`deviation_from_cad` with the m < 0.98 oblique mask). This is THE
//     STAIR-STEP AMPLITUDE and it is the only place on his part where the
//     question "how much staircase is there" has a truthful answer.
//     ★ AND UNLIKE A SURFACE OPERATOR, SEMDOT CAN MOVE IT. A downstream smoother
//     is handed a finished mesh; SEMDOT changes the FIELD, and the part's own
//     boundary voxels are design variables, so their fill fraction — and with it
//     the exported surface's sub-voxel position — is the optimizer's to place.
//     Whether it does is exactly what this column answers.
//
//   * ON THE OPTIMIZER-CUT POPULATION, the intrinsic roughness that needs no
//     reference: rms dihedral, computed by the SAME `dihedral_rms_deg` on a
//     SUBMESH of the triangles whose three vertices are all cut-attributed. The
//     instrument is not reimplemented; the population is restricted, exactly as
//     `deviation_from_cad`'s own `only` argument restricts the other one. A
//     whole-part dihedral would be diluted ~5x by the CAD surface (PR 307: 81.8%
//     of rung 068 is CAD) and would flatter any change.
//
//   * THE CONTROLS PR 299 demanded of any roughness claim, because melting the
//     part also reduces roughness: enclosed volume, the minimum cross-section of
//     every tendril (`min_cross_section`, PR 306's instrument), and the min-feature
//     violation count.
//
//   * THE FIELD ITSELF, which is where the two arms actually differ and the one
//     reading that says whether the mechanism did anything at all:
//       - the BOUNDARY-VOXEL BINARY FRACTION (PR 315's measurement: SIMP is 96.6%
//         binary at boundary voxels),
//       - the MARCHING-CUBES CROSSING OFFSET |frac - 0.5| in mm on the DESIGN
//         lattice (PR 315: rms 0.1037 mm for SIMP, against a 0.3424 mm staircase
//         — the whole sub-voxel placement the field could support).
//     ★ THE TRAP PR 315 PAID FOR, honoured here: the same statistic on the
//     SHIPPED (tricubic factor-2) lattice reads ~0.1326 mm and looks like signal.
//     It is not — a tricubic through binary corners manufactures a ramp. The
//     DESIGN lattice is the one that answers the question, and every column below
//     is named for the lattice it was measured on.

#include "topopt/cad_project.hpp"
#include "topopt/design_store.hpp"
#include "topopt/face_overrides.hpp"
#include "topopt/mesh.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

#include "stairstep_metric.hpp"
#include "surface_instruments.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

using namespace topopt;
using namespace topopt::stairstep;
using namespace topopt::surface_instruments;

namespace {

// THE SHIPPED EXPORT, reproduced exactly as cut_population_probe reproduces it:
// run_job extracts the variant mesh at output.smooth_factor with a tricubic
// resample and keeps the largest component.
constexpr int kShippedFactor = 2;

TriangleMesh extract(const VoxelGrid& g, const std::vector<double>& rho,
                     int factor) {
  return keep_largest_component(marching_cubes_resampled(
      g.nx, g.ny, g.nz, g.spacing, g.origin, rho, 0.5, factor,
      ResampleInterp::Tricubic));
}

// The triangles all of whose vertices are in `only`, as a standalone mesh —
// so `dihedral_rms_deg` can be run on a POPULATION without being rewritten.
TriangleMesh submesh(const TriangleMesh& m, const std::vector<char>& only) {
  TriangleMesh out;
  std::vector<int> remap(m.vertices.size(), -1);
  for (const auto& tr : m.triangles) {
    if (!only[static_cast<std::size_t>(tr[0])] ||
        !only[static_cast<std::size_t>(tr[1])] ||
        !only[static_cast<std::size_t>(tr[2])])
      continue;
    std::array<int, 3> t{};
    for (int k = 0; k < 3; ++k) {
      const int v = tr[static_cast<std::size_t>(k)];
      if (remap[static_cast<std::size_t>(v)] < 0) {
        remap[static_cast<std::size_t>(v)] = static_cast<int>(out.vertices.size());
        out.vertices.push_back(m.vertices[static_cast<std::size_t>(v)]);
      }
      t[static_cast<std::size_t>(k)] = remap[static_cast<std::size_t>(v)];
    }
    out.triangles.push_back(t);
  }
  return out;
}

// ── THE FIELD READINGS, on the DESIGN lattice ──────────────────────────────
//
// A voxel is a BOUNDARY voxel when one of its six neighbours is on the other side
// of the iso, reading outside the grid as background 0.0 — marching cubes' own
// rule, which is what makes this the set MC actually interpolates across.
struct FieldStats {
  std::size_t boundary_voxels = 0;
  std::size_t binary_boundary = 0;   // at one end of the certifiable band
  std::size_t fractional_voxels = 0;  // strictly between 0 and 1, whole grid
  double crossing_rms_frac = 0.0;     // rms |frac - 0.5| over MC crossings
  double crossing_rms_mm = 0.0;       // the same, in mm on the design lattice
  std::size_t crossings = 0;
  double midpoint_share = 0.0;        // share of crossings within 1% of midpoint
};

FieldStats field_stats(const VoxelGrid& g, const std::vector<double>& d,
                       double iso, double band_lo, double band_hi) {
  FieldStats s;
  auto at = [&](int i, int j, int k) -> double {
    if (i < 0 || j < 0 || k < 0 || i >= g.nx || j >= g.ny || k >= g.nz) return 0.0;
    return d[g.index(i, j, k)];
  };
  double sum2 = 0.0;
  std::size_t near_mid = 0;
  const int off[6][3] = {{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}};
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        const double a = d[g.index(i, j, k)];
        if (a > 0.0 && a < 1.0) ++s.fractional_voxels;
        bool boundary = false;
        for (const auto& o : off) {
          const double b = at(i + o[0], j + o[1], k + o[2]);
          if ((a > iso) != (b > iso)) boundary = true;
        }
        if (!boundary) continue;
        ++s.boundary_voxels;
        if (a <= band_lo || a >= band_hi) ++s.binary_boundary;
        // The three positive-direction edges only, so every lattice edge is
        // counted exactly once.
        for (int e = 0; e < 3; ++e) {
          const double b = at(i + (e == 0), j + (e == 1), k + (e == 2));
          if ((a > iso) == (b > iso)) continue;
          if (a == b) continue;
          const double frac = (iso - a) / (b - a);
          const double off_mid = std::fabs(frac - 0.5);
          sum2 += off_mid * off_mid;
          if (off_mid < 0.01) ++near_mid;
          ++s.crossings;
        }
      }
  if (s.crossings) {
    s.crossing_rms_frac =
        std::sqrt(sum2 / static_cast<double>(s.crossings));
    s.crossing_rms_mm = s.crossing_rms_frac * g.spacing;
    s.midpoint_share =
        static_cast<double>(near_mid) / static_cast<double>(s.crossings);
  }
  return s;
}

struct ArmRow {
  std::string arm;
  std::string rung;
  double requested_vf = 0.0, achieved_vf = 0.0;
  double margin_worst = 0.0, margin_eff = 0.0, max_vm = 0.0;
  int accepted = 0;
  int iterations = 0;
  std::size_t verts = 0, tris = 0;
  std::size_t n_cad = 0, n_cut = 0, n_amb = 0, n_oblique = 0;
  Deviation obl_all, obl_cad, obl_cut;
  double dih_all = 0.0, dih_cut = 0.0, dih_cad = 0.0;
  double volume_mm3 = 0.0;
  double min_section_mm2 = 0.0;
  int min_feature = 0;
  FieldStats field;
};

const char* yn(bool b) { return b ? "yes" : "no"; }

}  // namespace

int main(int argc, char** argv) {
  if (argc < 4) {
    std::printf(
        "usage: semdot_surface_probe <simp/design.bin> <semdot/design.bin> "
        "<part.step> [evidence_dir]\n");
    return 2;
  }
  const std::string simp_path = argv[1];
  const std::string semdot_path = argv[2];
  const std::string step_path = argv[3];
  const std::string ev = argc > 4 ? argv[4] : ".";

  const StepModel model = import_part_file_resolved(step_path);
  if (model.mesh.vertices.empty()) {
    std::printf("FATAL: the STEP imported empty — OCCT is required for this probe\n");
    return 2;
  }
  const TriGrid cad_ref(model.mesh);

  std::printf("== semdot_surface_probe — S2 on HIS OWN PART ==\n\n");
  std::printf("SIMP     %s\n", simp_path.c_str());
  std::printf("SEMDOT   %s\n", semdot_path.c_str());
  std::printf("part     %s (%zu faces, %zu tessellation triangles)\n\n",
              step_path.c_str(), model.faces.size(), model.mesh.triangles.size());

  std::vector<ArmRow> rows;

  const char* arm_name[2] = {"SIMP", "SEMDOT"};
  const std::string arm_path[2] = {simp_path, semdot_path};

  for (int arm = 0; arm < 2; ++arm) {
    DesignStore store = read_design_file(arm_path[static_cast<std::size_t>(arm)]);
    VoxelGrid grid;
    grid.nx = store.nx; grid.ny = store.ny; grid.nz = store.nz;
    grid.spacing = store.spacing; grid.origin = store.origin;
    grid.tags.assign(store.voxel_count(), VoxelTag::Empty);
    const CadProjectOptions copts = cad_project_options_for_grid(grid.spacing);

    std::printf("#####################################################################\n");
    std::printf("# ARM %s — grid %d x %d x %d, spacing %.6f mm, %zu rungs\n",
                arm_name[static_cast<std::size_t>(arm)], grid.nx, grid.ny, grid.nz,
                grid.spacing, store.variants.size());
    std::printf("#####################################################################\n");

    for (std::size_t r = 0; r < store.variants.size(); ++r) {
      const StoredDesign& d = store.variants[r];
      ArmRow row;
      row.arm = arm_name[static_cast<std::size_t>(arm)];
      char rung[64];
      std::snprintf(rung, sizeof rung, "%.2f", d.requested_volume_fraction);
      row.rung = rung;
      row.requested_vf = d.requested_volume_fraction;
      row.achieved_vf = d.achieved_volume_fraction;
      row.margin_worst = d.margin_worst_case;
      row.margin_eff = d.margin_effective;
      row.max_vm = d.max_von_mises_mpa;
      row.accepted = d.accepted ? 1 : 0;
      row.iterations = d.iterations;

      // The FIELD, on the DESIGN lattice. The band ends are the certifiable octet
      // band PR 315 measured the binary fraction against.
      row.field = field_stats(grid, d.density, 0.5, 0.05047, 0.89988);

      const TriangleMesh subject = extract(grid, d.density, kShippedFactor);
      row.verts = subject.vertices.size();
      row.tris = subject.triangles.size();
      if (subject.vertices.empty()) {
        rows.push_back(row);
        continue;
      }

      // PR 307's classifier — CAD / ambiguous / optimizer-cut.
      const CadAttribution att = attribute_to_cad_faces(subject, model, copts);
      std::vector<char> cad(subject.vertices.size(), 0);
      std::vector<char> cut(subject.vertices.size(), 0);
      for (std::size_t v = 0; v < subject.vertices.size(); ++v) {
        if (att.face_of_vertex[v] >= 0) { cad[v] = 1; ++row.n_cad; }
        else if (att.ambiguous_at(v)) { ++row.n_amb; }
        else { cut[v] = 1; ++row.n_cut; }
      }

      // PR 299's OBLIQUE mask, its rule verbatim: a vertex whose nearest CAD
      // triangle normal is not within 0.02 of an axis. Axis-aligned faces have no
      // staircase, only a half-voxel offset no operator can touch, so averaging
      // them in flatters the reading.
      std::vector<char> oblique(subject.vertices.size(), 0);
      for (std::size_t v = 0; v < subject.vertices.size(); ++v) {
        const auto dt = cad_ref.distance_and_tri(subject.vertices[v]);
        if (dt.second < 0) continue;
        const Vec3 n = cad_ref.tri_normal(dt.second);
        const double m =
            std::fmax(std::fabs(n.x), std::fmax(std::fabs(n.y), std::fabs(n.z)));
        if (m < 0.98) { oblique[v] = 1; ++row.n_oblique; }
      }
      std::vector<char> obl_cad(subject.vertices.size(), 0);
      std::vector<char> obl_cut(subject.vertices.size(), 0);
      for (std::size_t v = 0; v < subject.vertices.size(); ++v) {
        obl_cad[v] = static_cast<char>(oblique[v] && cad[v]);
        obl_cut[v] = static_cast<char>(oblique[v] && cut[v]);
      }

      row.obl_all = deviation_from_cad(subject, cad_ref, oblique);
      row.obl_cad = deviation_from_cad(subject, cad_ref, obl_cad);
      row.obl_cut = deviation_from_cad(subject, cad_ref, obl_cut);

      row.dih_all = dihedral_rms_deg(subject);
      row.dih_cut = dihedral_rms_deg(submesh(subject, cut));
      row.dih_cad = dihedral_rms_deg(submesh(subject, cad));

      row.volume_mm3 = std::fabs(signed_volume(subject));
      const CrossSection cs = min_cross_section(subject, grid);
      row.min_section_mm2 = cs.valid ? cs.min_mm : 0.0;
      row.min_feature = min_feature_now(subject, grid);

      std::printf("\n---------------------------------------------------------------\n");
      std::printf("%s  rung %s   %zu verts / %zu tris   iterations %d\n",
                  row.arm.c_str(), row.rung.c_str(), row.verts, row.tris,
                  row.iterations);
      std::printf("---------------------------------------------------------------\n");
      std::printf("  vf requested %.4f   achieved %.6f   (miss %+.6f)\n",
                  row.requested_vf, row.achieved_vf,
                  row.achieved_vf - row.requested_vf);
      std::printf("  margin worst %.4f   effective %.4f   max vM %.4f MPa   "
                  "accepted %s\n",
                  row.margin_worst, row.margin_eff, row.max_vm,
                  yn(row.accepted != 0));
      std::printf("  SPLIT: CAD %zu (%.2f%%)  ambiguous %zu (%.2f%%)  CUT %zu "
                  "(%.2f%%)   oblique %zu (%.2f%%)\n",
                  row.n_cad, 100.0 * row.n_cad / row.verts, row.n_amb,
                  100.0 * row.n_amb / row.verts, row.n_cut,
                  100.0 * row.n_cut / row.verts, row.n_oblique,
                  100.0 * row.n_oblique / row.verts);
      std::printf("  ★ STAIR-STEP AMPLITUDE (PR 299's metric, oblique CAD surface)\n");
      std::printf("      oblique ALL   rms %.4f mm  max %.4f  p99 %.4f  (%.1f%% of a voxel)\n",
                  row.obl_all.rms_mm, row.obl_all.max_mm, row.obl_all.p99_mm,
                  100.0 * row.obl_all.rms_mm / grid.spacing);
      std::printf("      oblique CAD   rms %.4f mm  max %.4f  p99 %.4f\n",
                  row.obl_cad.rms_mm, row.obl_cad.max_mm, row.obl_cad.p99_mm);
      std::printf("      oblique CUT   rms %.4f mm  (NOT an error — no reference "
                  "exists there; PR 314)\n", row.obl_cut.rms_mm);
      std::printf("  ★ ROUGHNESS (rms dihedral, same instrument, restricted "
                  "populations)\n");
      std::printf("      whole mesh %.4f deg    CUT %.4f deg    CAD %.4f deg\n",
                  row.dih_all, row.dih_cut, row.dih_cad);
      std::printf("  CONTROLS: volume %.1f mm3   min section %.4f mm2   "
                  "min-feature %d\n",
                  row.volume_mm3, row.min_section_mm2, row.min_feature);
      std::printf("  ★ THE FIELD, on the DESIGN lattice (never the shipped one)\n");
      std::printf("      boundary voxels %zu   binary at a band end %zu (%.2f%%)\n",
                  row.field.boundary_voxels, row.field.binary_boundary,
                  row.field.boundary_voxels
                      ? 100.0 * row.field.binary_boundary / row.field.boundary_voxels
                      : 0.0);
      std::printf("      fractional voxels (0<V<1), whole grid: %zu\n",
                  row.field.fractional_voxels);
      std::printf("      MC crossings %zu   |frac-0.5| rms %.6f = %.4f mm   "
                  "within 1%% of midpoint %.2f%%\n",
                  row.field.crossings, row.field.crossing_rms_frac,
                  row.field.crossing_rms_mm, 100.0 * row.field.midpoint_share);
      rows.push_back(row);
    }
  }

  // ── the CSV ───────────────────────────────────────────────────────────────
  std::ofstream csv(ev + "/s2_semdot_vs_simp.csv");
  csv << "arm,rung,requested_vf,achieved_vf,iterations,margin_worst_case,"
         "margin_effective,max_von_mises_mpa,accepted,verts,tris,n_cad,n_cut,"
         "n_ambiguous,n_oblique,obl_all_rms_mm,obl_all_max_mm,obl_all_p99_mm,"
         "obl_cad_rms_mm,obl_cut_rms_mm,dihedral_all_deg,dihedral_cut_deg,"
         "dihedral_cad_deg,volume_mm3,min_section_mm2,min_feature_violations,"
         "design_boundary_voxels,design_binary_boundary,design_fractional_voxels,"
         "design_crossings,design_crossing_rms_frac,design_crossing_rms_mm,"
         "design_midpoint_share\n";
  csv.setf(std::ios::fixed);
  for (const ArmRow& r : rows) {
    csv.precision(6);
    csv << r.arm << ',' << r.rung << ',' << r.requested_vf << ','
        << r.achieved_vf << ',' << r.iterations << ',' << r.margin_worst << ','
        << r.margin_eff << ',' << r.max_vm << ',' << r.accepted << ','
        << r.verts << ',' << r.tris << ',' << r.n_cad << ',' << r.n_cut << ','
        << r.n_amb << ',' << r.n_oblique << ',' << r.obl_all.rms_mm << ','
        << r.obl_all.max_mm << ',' << r.obl_all.p99_mm << ','
        << r.obl_cad.rms_mm << ',' << r.obl_cut.rms_mm << ',' << r.dih_all << ','
        << r.dih_cut << ',' << r.dih_cad << ',' << r.volume_mm3 << ','
        << r.min_section_mm2 << ',' << r.min_feature << ','
        << r.field.boundary_voxels << ',' << r.field.binary_boundary << ','
        << r.field.fractional_voxels << ',' << r.field.crossings << ','
        << r.field.crossing_rms_frac << ',' << r.field.crossing_rms_mm << ','
        << r.field.midpoint_share << '\n';
  }
  csv.close();

  // ── the verdict table, arm against arm, rung by rung ──────────────────────
  std::printf("\n\n=====================================================================\n");
  std::printf("THE ANSWER — SEMDOT against SIMP, rung by rung\n");
  std::printf("=====================================================================\n");
  // THE HEADLINE AMPLITUDE IS THE CAD POPULATION, NOT THE WHOLE OBLIQUE SET.
  // PR 314 settled that the cut surface has no ground truth, so its
  // distance-to-CAD is a fact about the part's shape and not an error — and on
  // this part it is 3.7-8.6 mm, an order above the CAD population's 0.43. Folding
  // it into one "oblique" number would make the headline mostly geometry and
  // would move for reasons that have nothing to do with staircase.
  //
  // AND THE CROSSING COLUMN IS THE MECHANISM, NOT AN OUTCOME — read it the other
  // way up. PR 315 measured SIMP's marching-cubes crossings landing within 1% of
  // the edge MIDPOINT 91% of the time, rms |frac-0.5| = 0.1037 mm, and called
  // that "the whole sub-voxel signal the field supported". A midpoint every time
  // IS the staircase. So a BIGGER offset here means MORE sub-voxel placement, and
  // that is what SEMDOT is for. It is signed accordingly: positive = SEMDOT put
  // more sub-voxel content in the field than SIMP did.
  std::printf("%-6s | %-24s | %-24s | %-24s\n", "rung",
              "stair-step amp, CAD (mm)", "roughness, CUT (deg)",
              "sub-voxel content (mm)");
  std::printf("%-6s | %8s %8s %6s | %8s %8s %6s | %8s %8s %6s\n", "",
              "SIMP", "SEMDOT", "%better", "SIMP", "SEMDOT", "%better",
              "SIMP", "SEMDOT", "%more");
  // PAIRED BY RUNG LABEL, NOT BY POSITION. The two arms need not evaluate the
  // same number of rungs — a rung either arm rejects, or one that ends
  // infeasible, stops that ladder and leaves the other longer. Pairing by index
  // would then silently compare rung 0.52 of one arm against 0.38 of the other
  // and print a difference that is a ladder mismatch wearing a smoothness label.
  // A rung only one arm reached is reported as such rather than dropped.
  auto find_arm = [&rows](const char* arm, const std::string& rung) -> const ArmRow* {
    for (const ArmRow& r : rows)
      if (r.arm == arm && r.rung == rung) return &r;
    return nullptr;
  };
  std::vector<std::string> order;
  for (const ArmRow& r : rows)
    if (std::find(order.begin(), order.end(), r.rung) == order.end())
      order.push_back(r.rung);
  auto pct = [](double from, double to) {
    return from > 0.0 ? 100.0 * (from - to) / from : 0.0;
  };
  for (const std::string& rung : order) {
    const ArmRow* a = find_arm("SIMP", rung);
    const ArmRow* b = find_arm("SEMDOT", rung);
    if (!a || !b) {
      std::printf("%-6s | ONLY %s REACHED THIS RUNG — not compared\n", rung.c_str(),
                  a ? "SIMP" : "SEMDOT");
      continue;
    }
    std::printf("%-6s | %8.4f %8.4f %+6.1f | %8.4f %8.4f %+6.1f | %8.4f %8.4f %+6.0f\n",
                rung.c_str(), a->obl_cad.rms_mm, b->obl_cad.rms_mm,
                pct(a->obl_cad.rms_mm, b->obl_cad.rms_mm), a->dih_cut, b->dih_cut,
                pct(a->dih_cut, b->dih_cut), a->field.crossing_rms_mm,
                b->field.crossing_rms_mm,
                -pct(a->field.crossing_rms_mm, b->field.crossing_rms_mm));
  }
  std::printf(
      "\nA POSITIVE %% IS SEMDOT WINNING IN ALL THREE COLUMNS. The first two are\n"
      "the OUTCOME (lower amplitude, lower roughness); the third is the\n"
      "MECHANISM (more sub-voxel placement in the field). Positive mechanism with\n"
      "negative outcome is the interesting failure: the boundary DID get finer\n"
      "than the grid, and the surface got worse anyway.\n");
  std::printf("\nwrote %s/s2_semdot_vs_simp.csv\n", ev.c_str());
  return 0;
}
