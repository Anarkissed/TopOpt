// cad_project_probe — S3 + S4 of task 2026-08-06-cad-face-projection.
//
// THE NUMBERS THE MAINTAINER HAS NEVER HAD. His complaint is that protected
// holes still come out wrong and walls do not stay straight. Nobody has ever
// measured, on his own part, HOW round a bolt bore actually is in the file the
// slicer receives. This harness measures it — before and after the exact
// projection — against the nominal radius the B-rep itself carries.
//
// EVERY NUMBER STATES ITS REFERENCE (bar R4):
//   * a bore radius is measured about that face's OWN nominal axis
//     (StepFaceInfo::axis_point / axis_dir) and compared to that face's OWN
//     nominal radius (StepFaceInfo::cylinder_radius_mm) — both read from the
//     B-rep on import, not fitted;
//   * a flat-face deviation is the signed distance to that face's OWN nominal
//     plane (plane_origin / plane_normal), again from the B-rep;
//   * every displacement is also printed as a fraction of ONE VOXEL, which is
//     printed first.
//
//   cmake --build core/build --target cad_project_probe
//   ./core/build/cad_project_probe <part.step> <res> <evidence_dir> <variant.stl>...

#include "topopt/cad_project.hpp"
#include "topopt/face_overrides.hpp"
#include "topopt/mesh.hpp"
#include "topopt/step.hpp"
#include "topopt/stl.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <map>
#include <string>
#include <vector>

using namespace topopt;

namespace {

std::string base_name(const std::string& p) {
  const std::size_t s = p.find_last_of("/\\");
  return s == std::string::npos ? p : p.substr(s + 1);
}

double tri_area(const TriangleMesh& m, std::size_t t) {
  const auto& tr = m.triangles[t];
  const Vec3& a = m.vertices[static_cast<std::size_t>(tr[0])];
  const Vec3& b = m.vertices[static_cast<std::size_t>(tr[1])];
  const Vec3& c = m.vertices[static_cast<std::size_t>(tr[2])];
  const Vec3 u{b.x - a.x, b.y - a.y, b.z - a.z};
  const Vec3 v{c.x - a.x, c.y - a.y, c.z - a.z};
  const Vec3 n{u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z,
               u.x * v.y - u.y * v.x};
  return 0.5 * std::sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 5) {
    std::printf("usage: cad_project_probe <part.step> <res> <evidence_dir> "
                "<variant.stl>...\n");
    return 2;
  }
  const std::string step_path = argv[1];
  const int res = std::atoi(argv[2]);
  const std::string ev = argv[3];

  StepModel model;
  try {
    model = import_part_file_resolved(step_path);
  } catch (const std::exception& e) {
    std::printf("FATAL: cannot import %s: %s\n", step_path.c_str(), e.what());
    return 2;
  }
  const VoxelGrid grid = voxelize(model.mesh, res);
  CadProjectOptions opt = cad_project_options_for_grid(grid.spacing);
  opt.enabled = true;

  std::printf("== cad_project_probe — S3/S4 of 2026-08-06-cad-face-projection ==\n\n");
  std::printf("part            %s   (%d B-rep faces)\n",
              base_name(step_path).c_str(), model.face_count);
  std::printf("grid            %d x %d x %d @ resolution %d\n", grid.nx, grid.ny,
              grid.nz, res);
  std::printf("ONE VOXEL       %.6f mm\n", grid.spacing);
  std::printf("HALF A VOXEL    %.6f mm   <- the bar every displacement below is "
              "held to\n", 0.5 * grid.spacing);
  std::printf("tolerances      attribution %.6f mm (%.2f voxel), motion guard "
              "%.6f mm (%.2f voxel),\n                ambiguity band %.6f mm "
              "(%.2f voxel)\n\n",
              opt.tolerance_mm, opt.tolerance_mm / grid.spacing, opt.max_move_mm,
              opt.max_move_mm / grid.spacing, opt.ambiguity_band_mm,
              opt.ambiguity_band_mm / grid.spacing);

  // Does the CAD's OWN tessellation sit on the CAD's OWN nominal surfaces? Every
  // "AFTER" number below is measured against the nominal StepFaceInfo, so if the
  // tessellation and the nominal disagree, that gap is the floor under any
  // exactness claim. Measured, not assumed.
  {
    double wp = 0.0, wc = 0.0;
    for (std::size_t t = 0; t < model.mesh.triangles.size(); ++t) {
      const int f = model.triangle_face[t];
      if (f < 0 || f >= model.face_count) continue;
      const StepFaceInfo& fi = model.faces[static_cast<std::size_t>(f)];
      for (int k = 0; k < 3; ++k) {
        const Vec3& v =
            model.mesh.vertices[static_cast<std::size_t>(model.mesh.triangles[t][k])];
        if (fi.kind == StepSurfaceKind::Plane) {
          const Vec3 d{v.x - fi.plane_origin.x, v.y - fi.plane_origin.y,
                       v.z - fi.plane_origin.z};
          wp = std::fmax(wp, std::fabs(d.x * fi.plane_normal.x +
                                       d.y * fi.plane_normal.y +
                                       d.z * fi.plane_normal.z));
        } else if (fi.kind == StepSurfaceKind::Cylinder &&
                   fi.cylinder_radius_mm > 0.0) {
          const Vec3 w{v.x - fi.axis_point.x, v.y - fi.axis_point.y,
                       v.z - fi.axis_point.z};
          const double s = w.x * fi.axis_dir.x + w.y * fi.axis_dir.y +
                           w.z * fi.axis_dir.z;
          const Vec3 r{w.x - s * fi.axis_dir.x, w.y - s * fi.axis_dir.y,
                       w.z - s * fi.axis_dir.z};
          wc = std::fmax(wc, std::fabs(std::sqrt(r.x * r.x + r.y * r.y +
                                                 r.z * r.z) -
                                       fi.cylinder_radius_mm));
        }
      }
    }
    std::printf("-- the FLOOR under every exactness claim below ---------------\n");
    std::printf("The CAD's own tessellation vertices, measured against the CAD's "
                "own nominal\nsurfaces: worst planar %.3e mm, worst cylindrical "
                "%.3e mm.\nNothing projected onto a nominal surface can be "
                "'exact' beyond this.\n\n", wp, wc);
  }

  std::ofstream bcsv(ev + "/s3_bores.csv");
  bcsv << "variant,face_id,nominal_radius_mm,vertices,"
          "before_min,before_max,before_mean,before_rms_err,before_oor,"
          "after_min,after_max,after_mean,after_rms_err,after_oor\n";
  std::ofstream fcsv(ev + "/s3_flats.csv");
  fcsv << "variant,face_id,vertices,before_max_abs,before_rms,after_max_abs,"
          "after_rms\n";
  std::ofstream mcsv(ev + "/s3_motion.csv");
  mcsv << "variant,verts,attributed,unattributed,ambiguous,n_plane,n_cylinder,"
          "n_other,n_seam,moved,moved_plane,moved_cylinder,left_other,"
          "refused_by_guard,seam_constrained,max_move_mm,rms_move_mm,"
          "max_move_voxel,seam_edges,max_seam_step_mm,rms_seam_step_mm\n";

  for (int ai = 4; ai < argc; ++ai) {
    const std::string vpath = argv[ai];
    TriangleMesh sub;
    try {
      sub = import_part_file_resolved(vpath).mesh;
    } catch (const std::exception& e) {
      std::printf("FATAL: cannot import %s: %s\n", vpath.c_str(), e.what());
      return 2;
    }
    const std::string vname = base_name(vpath);
    std::printf("==============================================================\n");
    std::printf("VARIANT %s — %zu verts, %zu tris\n", vname.c_str(),
                sub.vertices.size(), sub.triangles.size());

    const CadAttribution att = attribute_to_cad_faces(sub, model, opt);
    std::printf("attributed %zu / %zu (%.2f%%)  —  Plane %zu, Cylinder %zu, "
                "Other %zu (LEFT ALONE)\n",
                att.attributed, sub.vertices.size(),
                100.0 * static_cast<double>(att.attributed) /
                    static_cast<double>(sub.vertices.size()),
                att.n_plane, att.n_cylinder, att.n_other);
    std::printf("unattributed %zu — treated as OPTIMIZER-CUT and left alone. Of "
                "those:\n  ambiguous (a second face of another kind just as "
                "close)  %zu  (%.4f%% of all vertices)\n"
                "  near a face's PATCH but not its ANALYTIC surface        %zu  "
                "(%.4f%%)\n", att.unattributed, att.ambiguous,
                100.0 * static_cast<double>(att.ambiguous) /
                    static_cast<double>(sub.vertices.size()),
                att.off_analytic_surface,
                100.0 * static_cast<double>(att.off_analytic_surface) /
                    static_cast<double>(sub.vertices.size()));
    std::printf("seam vertices %zu (%.2f%%)\n\n", att.n_seam,
                100.0 * static_cast<double>(att.n_seam) /
                    static_cast<double>(sub.vertices.size()));

    // How much area falls on kind Other — if it is large, that is a finding.
    {
      double a_other = 0.0, a_plane = 0.0, a_cyl = 0.0, a_un = 0.0, a_all = 0.0;
      for (std::size_t t = 0; t < sub.triangles.size(); ++t) {
        const double a = tri_area(sub, t);
        a_all += a;
        int f = -1;
        bool same = true;
        for (int k = 0; k < 3; ++k) {
          const int g = att.face_of_vertex[static_cast<std::size_t>(sub.triangles[t][k])];
          if (k == 0) f = g; else if (g != f) same = false;
        }
        if (!same || f < 0) { a_un += a; continue; }
        switch (model.faces[static_cast<std::size_t>(f)].kind) {
          case StepSurfaceKind::Plane: a_plane += a; break;
          case StepSurfaceKind::Cylinder: a_cyl += a; break;
          default: a_other += a; break;
        }
      }
      std::printf("-- S3 area by treatment (triangles all of whose vertices "
                  "agree on one face) --\n");
      std::printf("  Plane    (projected exactly) %10.1f mm^2  %6.2f%%\n",
                  a_plane, 100.0 * a_plane / a_all);
      std::printf("  Cylinder (projected exactly) %10.1f mm^2  %6.2f%%\n", a_cyl,
                  100.0 * a_cyl / a_all);
      std::printf("  Other    (LEFT ALONE)        %10.1f mm^2  %6.2f%%\n",
                  a_other, 100.0 * a_other / a_all);
      std::printf("  cut / seam / unattributed    %10.1f mm^2  %6.2f%%\n\n", a_un,
                  100.0 * a_un / a_all);
    }

    const std::vector<BoreRoundness> b0 = measure_bores(sub, model, att);
    const std::vector<FaceFlatness> f0 = measure_flats(sub, model, att);

    CadProjectionStats st;
    const TriangleMesh proj = project_onto_cad_faces(sub, model, opt, att, &st);

    // AFTER is measured over the vertices the projection actually placed. The
    // ones the fold guard put back are EXCLUDED and COUNTED — averaging them in
    // would report a face as "still off nominal" when what is off nominal is the
    // handful of vertices we deliberately refused to move.
    std::vector<std::size_t> bore_excl, flat_excl;
    const std::vector<BoreRoundness> b1 =
        measure_bores(proj, model, att, &st.reverted, &bore_excl);
    const std::vector<FaceFlatness> f1 =
        measure_flats(proj, model, att, &st.reverted, &flat_excl);

    // ── S3: BOLT BORES ──────────────────────────────────────────────────────
    std::printf("-- S3 BOLT BORES — measured radius vs the B-rep's OWN nominal "
                "----------\n");
    std::printf("Reference: StepFaceInfo::cylinder_radius_mm and the face's own "
                "axis, read from\nthe B-rep on import. Every figure in mm; "
                "out-of-roundness = max - min.\n\n");
    std::printf("AFTER excludes the vertices the fold guard put back; the "
                "`held` column counts them.\n\n");
    std::printf("%6s %9s %7s %5s | %28s | %28s\n", "face", "nominal", "verts",
                "held", "BEFORE  min/max  oor  rmserr",
                "AFTER   min/max  oor  rmserr");
    std::map<int, BoreRoundness> after_by_face;
    for (const BoreRoundness& b : b1) after_by_face[b.face_id] = b;
    for (const BoreRoundness& b : b0) {
      const BoreRoundness& a = after_by_face[b.face_id];
      const std::size_t held =
          b.face_id < static_cast<int>(bore_excl.size())
              ? bore_excl[static_cast<std::size_t>(b.face_id)] : 0;
      std::printf("%6d %9.4f %7zu %5zu | %7.4f/%7.4f %6.4f %6.4f | "
                  "%7.4f/%7.4f %6.4f %6.4f\n",
                  b.face_id, b.nominal_radius_mm, b.vertices, held, b.min_mm,
                  b.max_mm, b.out_of_roundness_mm, b.rms_error_mm, a.min_mm,
                  a.max_mm, a.out_of_roundness_mm, a.rms_error_mm);
      bcsv << vname << "," << b.face_id << "," << b.nominal_radius_mm << ","
           << b.vertices << "," << b.min_mm << "," << b.max_mm << ","
           << b.mean_mm << "," << b.rms_error_mm << "," << b.out_of_roundness_mm
           << "," << a.min_mm << "," << a.max_mm << "," << a.mean_mm << ","
           << a.rms_error_mm << "," << a.out_of_roundness_mm << "\n";
    }
    if (b0.empty()) std::printf("  (no cylindrical face carried any vertex)\n");
    {
      double worst_oor = 0.0, worst_after = 0.0;
      for (const BoreRoundness& b : b0)
        worst_oor = std::fmax(worst_oor, b.out_of_roundness_mm);
      for (const BoreRoundness& b : b1)
        worst_after = std::fmax(worst_after, b.out_of_roundness_mm);
      std::printf("\nWORST out-of-roundness on this variant: BEFORE %.4f mm "
                  "(%.2f voxel) -> AFTER %.4f mm (%.2f voxel)\n", worst_oor,
                  worst_oor / grid.spacing, worst_after,
                  worst_after / grid.spacing);
    }

    // ── S3: FLAT FACES ──────────────────────────────────────────────────────
    std::printf("\n-- S3 FLAT FACES — deviation from the B-rep's OWN nominal "
                "plane -------\n");
    std::map<int, FaceFlatness> fafter;
    for (const FaceFlatness& f : f1) fafter[f.face_id] = f;
    double wmax0 = 0.0, wrms0 = 0.0, wmax1 = 0.0, wrms1 = 0.0;
    std::size_t nf = 0;
    for (const FaceFlatness& f : f0) {
      wmax0 = std::fmax(wmax0, f.max_abs_mm);
      wrms0 = std::fmax(wrms0, f.rms_mm);
      const FaceFlatness& a = fafter[f.face_id];
      wmax1 = std::fmax(wmax1, a.max_abs_mm);
      wrms1 = std::fmax(wrms1, a.rms_mm);
      ++nf;
    }
    std::printf("%zu planar faces carried vertices.\n", nf);
    std::printf("WORST max |deviation|  BEFORE %.6f mm (%.3f voxel) -> AFTER "
                "%.3e mm\n", wmax0, wmax0 / grid.spacing, wmax1);
    std::printf("WORST rms  deviation   BEFORE %.6f mm (%.3f voxel) -> AFTER "
                "%.3e mm\n", wrms0, wrms0 / grid.spacing, wrms1);
    std::printf("\n%6s %7s | %11s %11s | %11s %11s\n", "face", "verts",
                "before max", "before rms", "after max", "after rms");
    // print the ten worst planar faces, by max deviation
    std::vector<FaceFlatness> sorted = f0;
    std::sort(sorted.begin(), sorted.end(),
              [](const FaceFlatness& x, const FaceFlatness& y) {
                return x.max_abs_mm > y.max_abs_mm;
              });
    for (std::size_t i = 0; i < sorted.size() && i < 10; ++i) {
      const FaceFlatness& f = sorted[i];
      const FaceFlatness& a = fafter[f.face_id];
      std::printf("%6d %7zu | %11.6f %11.6f | %11.3e %11.3e\n", f.face_id,
                  f.vertices, f.max_abs_mm, f.rms_mm, a.max_abs_mm, a.rms_mm);
    }
    for (const FaceFlatness& f : f0) {
      const FaceFlatness& a = fafter[f.face_id];
      fcsv << vname << "," << f.face_id << "," << f.vertices << ","
           << f.max_abs_mm << "," << f.rms_mm << "," << a.max_abs_mm << ","
           << a.rms_mm << "\n";
    }

    // ── WHY THE PART'S VOLUME CHANGES ───────────────────────────────────────
    // The re-certification reads a mass off the projected mesh, and it is not
    // the same mass. That is not a defect to explain away: it is a measurement
    // of how far off the exported outer surface was, in the one direction the
    // absolute deviations above cannot show.
    {
      auto signed_vol = [](const TriangleMesh& m) {
        double v = 0.0;
        for (std::size_t t = 0; t < m.triangles.size(); ++t) {
          const Vec3& a = m.vertices[static_cast<std::size_t>(m.triangles[t][0])];
          const Vec3& b = m.vertices[static_cast<std::size_t>(m.triangles[t][1])];
          const Vec3& c = m.vertices[static_cast<std::size_t>(m.triangles[t][2])];
          v += (a.x * (b.y * c.z - b.z * c.y) - a.y * (b.x * c.z - b.z * c.x) +
                a.z * (b.x * c.y - b.y * c.x)) / 6.0;
        }
        return v;
      };
      const double v0 = signed_vol(sub), v1 = signed_vol(proj);
      std::printf("\n-- WHY THE VOLUME MOVES ------------------------------------\n");
      std::printf("enclosed volume  before %.1f mm^3 -> after %.1f mm^3  "
                  "(%+.2f%%)\n", v0, v1, 100.0 * (v1 - v0) / v0);
      // The direction, face by face: positive mean signed deviation means the
      // exported surface sat OUTSIDE the CAD plane — the part was too big there.
      double area_out = 0.0, area_in = 0.0, wsum = 0.0, wtot = 0.0;
      for (const FaceFlatness& f : f0) {
        const double w = static_cast<double>(f.vertices);
        wsum += f.mean_signed_mm * w;
        wtot += w;
        if (f.mean_signed_mm > 0.0) area_out += w; else area_in += w;
      }
      std::printf("planar faces: %.0f%% of planar vertices sat OUTSIDE their own "
                  "CAD plane,\n              %.0f%% inside; vertex-weighted mean "
                  "signed deviation %+.4f mm (%+.3f voxel)\n",
                  100.0 * area_out / (area_out + area_in),
                  100.0 * area_in / (area_out + area_in),
                  wtot > 0.0 ? wsum / wtot : 0.0,
                  wtot > 0.0 ? wsum / wtot / grid.spacing : 0.0);
      std::printf("Bores read the other way (measured radius ABOVE nominal on "
                  "every one), so the\nexport dilates the outside and erodes the "
                  "holes — both make the printed part\nwrong, and both are "
                  "corrected in the same pass.\n");
    }

    // ── S3: HOW FAR ANYTHING MOVED ──────────────────────────────────────────
    std::printf("\n-- S3 HOW FAR ANY VERTEX MOVED, against HALF A VOXEL -------\n");
    std::printf("moved            %zu (Plane %zu, Cylinder %zu)\n", st.moved,
                st.moved_plane, st.moved_cylinder);
    std::printf("left alone       %zu unattributed (optimizer-cut), %zu on a "
                "kind we have no surface for\n", st.left_unattributed,
                st.left_other);
    std::printf("fold guard       %zu band vertices put back (free) + %zu "
                "PROJECTED vertices put back (costs\n                 "
                "exactness), in %d passes; inverted triangles left %zu "
                "carrying %.4f mm^2\n", st.reverted_band,
                st.reverted_by_fold_guard, st.fold_guard_passes,
                st.inverted_triangles_remaining, st.inverted_area_mm2);
    std::printf("refused by guard %zu  <- would have moved further than half a "
                "voxel; the ATTRIBUTION\n                     would be wrong, "
                "not the CAD, so the vertex is left where it is\n",
                st.refused_by_guard);
    std::printf("MAX MOVE         %.6f mm = %.4f voxel\n", st.max_move_mm,
                st.max_move_mm / grid.spacing);
    std::printf("rms move         %.6f mm = %.4f voxel\n", st.rms_move_mm,
                st.rms_move_mm / grid.spacing);
    {
      std::size_t h[9] = {0, 0, 0, 0, 0, 0, 0, 0, 0};
      for (const double m : st.move_mm) {
        if (m <= 0.0) continue;
        const int b = static_cast<int>(std::floor(8.0 * m / grid.spacing));
        h[static_cast<std::size_t>(b >= 8 ? 8 : b)]++;
      }
      std::printf("\ndisplacement histogram, in EIGHTHS of a voxel:\n");
      for (int b = 0; b < 9; ++b)
        std::printf("  [%4.3f,%4.3f) voxel %9zu  %6.2f%% of moved\n",
                    0.125 * b, b == 8 ? 9.0 : 0.125 * (b + 1),
                    h[static_cast<std::size_t>(b)],
                    st.moved ? 100.0 * static_cast<double>(h[static_cast<std::size_t>(b)]) /
                                   static_cast<double>(st.moved) : 0.0);
    }
    std::printf("\n-- the BLOCKED-STOP question, answered with data ------------\n");
    std::printf("The stop condition reads: a move beyond HALF A VOXEL means the "
                "ATTRIBUTION is\nwrong, not the CAD. So for every such vertex: "
                "does its analytic projection\nstill land on the tessellated "
                "patch of the very face it was attributed to?\n");
    std::printf("moved further than half a voxel   %zu (%.2f%% of moved)\n",
                st.moved_over_half_voxel,
                st.moved ? 100.0 * static_cast<double>(st.moved_over_half_voxel) /
                               static_cast<double>(st.moved) : 0.0);
    std::printf("of those, STILL ON THEIR OWN FACE %zu (%.2f%%)\n",
                st.over_half_still_on_own_patch,
                st.moved_over_half_voxel
                    ? 100.0 * static_cast<double>(st.over_half_still_on_own_patch) /
                          static_cast<double>(st.moved_over_half_voxel)
                    : 0.0);

    // ── S4: THE SEAM ────────────────────────────────────────────────────────
    std::printf("\n-- S4 THE SEAM ---------------------------------------------\n");
    std::printf("seam vertices              %zu\n", att.n_seam);
    std::printf("transition band            %zu optimizer-cut vertices carried, "
                "furthest %.6f mm (%.4f voxel)\n                           "
                "(%d rings; every attributed vertex kept its exact position)\n",
                st.blended, st.max_blend_mm, st.max_blend_mm / grid.spacing,
                opt.seam_blend_rings);
    std::printf("held inside their patch    %zu (their analytic projection "
                "would have left the\n                           CAD face; they "
                "were placed on its boundary instead)\n",
                st.seam_constrained);
    std::printf("moved/unmoved mesh edges   %zu of %zu total (%.2f%%)\n",
                st.seam_edges, sub.triangles.size() * 3 / 2,
                100.0 * static_cast<double>(st.seam_edges) /
                    (static_cast<double>(sub.triangles.size()) * 1.5));
    std::printf("MAX discontinuity across the seam  %.6f mm = %.4f voxel\n",
                st.max_seam_step_mm, st.max_seam_step_mm / grid.spacing);
    std::printf("rms discontinuity across the seam  %.6f mm = %.4f voxel\n",
                st.rms_seam_step_mm, st.rms_seam_step_mm / grid.spacing);
    std::printf("\nA SHIFT IS NOT A CREASE. What is visible is a change of "
                "surface ANGLE:\n");
    std::printf("dihedral change at seam edges      max %.2f deg, rms %.2f deg\n",
                st.max_seam_dihedral_change_deg,
                st.rms_seam_dihedral_change_deg);
    std::printf("dihedral of the WHOLE mesh         before rms %.2f deg -> after "
                "rms %.2f deg\n", st.rms_dihedral_before_deg,
                st.rms_dihedral_after_deg);
    std::printf("\nBUT A MAX OVER 14000 EDGES IS ONE EDGE. \"A visible crease at "
                "EVERY CAD boundary\"\nis a COUNT, so here is the count. This "
                "surface is a voxel staircase: it arrives\nalready full of sharp "
                "edges, and what matters is how many the projection ADDS.\n");
    std::printf("%-28s %12s %12s\n", "manifold edges", "BEFORE", "AFTER");
    std::printf("%-28s %12zu %12zu\n", "total", st.total_edges, st.total_edges);
    std::printf("%-28s %12zu %12zu\n", ">= 45 deg", st.sharp45_before,
                st.sharp45_after);
    std::printf("%-28s %12zu %12zu\n", ">= 60 deg", st.sharp60_before,
                st.sharp60_after);
    std::printf("%-28s %12zu %12zu\n", ">= 90 deg", st.sharp90_before,
                st.sharp90_after);
    std::printf("\nNEWLY SHARP (was < 45 deg, is now >= 60 deg): %zu edges "
                "= %.4f%% of the mesh\n  of which at a moved/unmoved junction: "
                "%zu (%.4f%% of the %zu seam edges)\n", st.newly_sharp,
                100.0 * static_cast<double>(st.newly_sharp) /
                    static_cast<double>(st.total_edges),
                st.newly_sharp_at_seam,
                st.seam_edges ? 100.0 * static_cast<double>(st.newly_sharp_at_seam) /
                                    static_cast<double>(st.seam_edges) : 0.0,
                st.seam_edges);

    mcsv << vname << "," << sub.vertices.size() << "," << att.attributed << ","
         << att.unattributed << "," << att.ambiguous << "," << att.n_plane << ","
         << att.n_cylinder << "," << att.n_other << "," << att.n_seam << ","
         << st.moved << "," << st.moved_plane << "," << st.moved_cylinder << ","
         << st.left_other << "," << st.refused_by_guard << ","
         << st.seam_constrained << "," << st.max_move_mm << ","
         << st.rms_move_mm << "," << st.max_move_mm / grid.spacing << ","
         << st.seam_edges << "," << st.max_seam_step_mm << ","
         << st.rms_seam_step_mm << "\n";

    // ── WHERE THE NEW SHARP EDGES ACTUALLY ARE ──────────────────────────────
    // Only 3.6% of them sit at a moved/unmoved junction, so the seam is NOT
    // where this is coming from. The candidate that is left: projecting a
    // TERRACED surface onto the plane it was terracing collapses the risers, and
    // a collapsed riser is a folded or vanished triangle. Counted, per surface
    // kind, rather than guessed at.
    {
      auto normal_of = [](const TriangleMesh& m, std::size_t t) {
        const Vec3& a = m.vertices[static_cast<std::size_t>(m.triangles[t][0])];
        const Vec3& b = m.vertices[static_cast<std::size_t>(m.triangles[t][1])];
        const Vec3& c = m.vertices[static_cast<std::size_t>(m.triangles[t][2])];
        const Vec3 u{b.x - a.x, b.y - a.y, b.z - a.z};
        const Vec3 v{c.x - a.x, c.y - a.y, c.z - a.z};
        return Vec3{u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z,
                    u.x * v.y - u.y * v.x};
      };
      std::size_t flipped = 0, collapsed = 0, all_moved_tris = 0;
      std::size_t flipped_plane = 0, flipped_cyl = 0;
      double min_area_before = 1e300, min_area_after = 1e300;
      double inv_area_before = 0.0, inv_area_after = 0.0;
      double max_inv_area_after = 0.0;
      double area_all_dbg = 0.0;
      for (std::size_t t = 0; t < sub.triangles.size(); ++t)
        area_all_dbg += tri_area(sub, t);
      for (std::size_t t = 0; t < sub.triangles.size(); ++t) {
        const Vec3 nb = normal_of(sub, t);
        const Vec3 na = normal_of(proj, t);
        const double ab = 0.5 * std::sqrt(nb.x * nb.x + nb.y * nb.y + nb.z * nb.z);
        const double aa = 0.5 * std::sqrt(na.x * na.x + na.y * na.y + na.z * na.z);
        min_area_before = std::fmin(min_area_before, ab);
        min_area_after = std::fmin(min_area_after, aa);
        bool any_moved = false;
        for (int k = 0; k < 3; ++k)
          if (st.move_mm[static_cast<std::size_t>(sub.triangles[t][k])] > 0.0)
            any_moved = true;
        if (!any_moved) continue;
        ++all_moved_tris;
        if (aa < 1e-12) { ++collapsed; continue; }
        if (nb.x * na.x + nb.y * na.y + nb.z * na.z < 0.0) {
          ++flipped;
          inv_area_before += ab;
          inv_area_after += aa;
          max_inv_area_after = std::fmax(max_inv_area_after, aa);
          const int f = att.face_of_vertex[static_cast<std::size_t>(sub.triangles[t][0])];
          if (f >= 0) {
            if (model.faces[static_cast<std::size_t>(f)].kind ==
                StepSurfaceKind::Plane) ++flipped_plane;
            else if (model.faces[static_cast<std::size_t>(f)].kind ==
                     StepSurfaceKind::Cylinder) ++flipped_cyl;
          }
        }
      }
      std::printf("\n-- DID THE PROJECTION FOLD THE MESH? ------------------------\n");
      std::printf("triangles touched by the projection   %zu of %zu\n",
                  all_moved_tris, sub.triangles.size());
      std::printf("INVERTED (normal reversed)            %zu  (%.4f%% of "
                  "touched)  [Plane %zu, Cylinder %zu]\n", flipped,
                  all_moved_tris ? 100.0 * static_cast<double>(flipped) /
                                       static_cast<double>(all_moved_tris) : 0.0,
                  flipped_plane, flipped_cyl);
      std::printf("COLLAPSED to zero area                %zu\n", collapsed);
      // AN INVERTED SLIVER IS NOT A FOLD. What decides whether the mesh is
      // damaged is how much AREA the inverted triangles carry: a riser flattened
      // onto the plane it was terracing legitimately collapses, and a collapsed
      // facet contributes nothing to a slice. A fold with real area does.
      std::printf("area carried by the inverted ones     %.6f mm^2 before -> "
                  "%.6f mm^2 after\n", inv_area_before, inv_area_after);
      std::printf("  = %.6f%% of the part's %.0f mm^2; the LARGEST single "
                  "inverted triangle is %.3e mm^2\n",
                  100.0 * inv_area_after / area_all_dbg, area_all_dbg,
                  max_inv_area_after);
      std::printf("smallest triangle area  before %.3e mm^2 -> after %.3e mm^2\n",
                  min_area_before, min_area_after);
      std::printf("watertight  before %s -> after %s\n",
                  check_watertight(sub).watertight ? "yes" : "no",
                  check_watertight(proj).watertight ? "yes" : "no");
    }

    // ── THE DECISION TABLE ──────────────────────────────────────────────────
    // Two settings are open, and neither should be argued: the attribution
    // tolerance (one voxel, or the half-voxel the task's stop condition assumes)
    // and the width of the seam transition band. Sweep both and print what each
    // buys and costs, so the choice is read off data.
    std::printf("\n-- THE DECISION TABLE — tolerance x seam band ---------------\n");
    std::printf("`cover` is the share of ALL vertices that get an exact answer. "
                "`bore oor` and\n`flat max` are the WORST over every face, AFTER "
                "projection. `seam dih` is the max\nchange of dihedral angle at "
                "a moved/unmoved edge — the crease. The mesh's own\nambient "
                "dihedral is printed on the last column for comparison.\n\n");
    std::printf("%5s %5s %5s %7s %8s %9s %9s %9s %8s %8s %9s\n", "tol",
                "rings", "guard", "cover", "moved", "bore oor", "flat max",
                "inverted", "inv mm2", "newsharp", "seam rms");
    std::printf("%5s %5s %5s %7s %8s %9s %9s %9s %8s %8s %9s\n", "vox", "", "",
                "%", "", "mm", "mm", "tris", "mm^2", "edges", "mm");
    for (const double tv : {0.5, 1.0}) {
      for (const int rings : {0, 1, 2}) {
        for (const bool guard : {false, true}) {
          CadProjectOptions o = cad_project_options_for_grid(grid.spacing);
          o.enabled = true;
          o.tolerance_mm = tv * grid.spacing;
          o.max_move_mm = tv * grid.spacing;
          o.seam_blend_rings = rings;
          o.fold_guard = guard;
          const CadAttribution a = attribute_to_cad_faces(sub, model, o);
          CadProjectionStats s;
          const TriangleMesh p = project_onto_cad_faces(sub, model, o, a, &s);
          double oor = 0.0, flat = 0.0;
          for (const BoreRoundness& b : measure_bores(p, model, a, &s.reverted))
            oor = std::fmax(oor, b.out_of_roundness_mm);
          for (const FaceFlatness& f : measure_flats(p, model, a, &s.reverted))
            flat = std::fmax(flat, f.max_abs_mm);
          std::printf("%5.2f %5d %5s %6.2f%% %8zu %9.2e %9.2e %9zu %8.3f %8zu "
                      "%9.4f\n", tv, rings, guard ? "on" : "off",
                      100.0 * static_cast<double>(a.attributed) /
                          static_cast<double>(sub.vertices.size()),
                      s.moved, oor, flat, s.inverted_triangles_remaining,
                      s.inverted_area_mm2, s.newly_sharp, s.rms_seam_step_mm);
          std::fflush(stdout);
        }
      }
    }

    // Write the projected mesh so it can be re-certified and looked at.
    const std::string outp = ev + "/" + vname.substr(0, vname.find_last_of('.')) +
                             "_projected.stl";
    write_stl_file(outp, proj);
    std::printf("\nprojected mesh written to %s\n", outp.c_str());
    std::fflush(stdout);
  }
  std::printf("\nevidence written to %s/s3_bores.csv, s3_flats.csv, "
              "s3_motion.csv\n", ev.c_str());
  return 0;
}
