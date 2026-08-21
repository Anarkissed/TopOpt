// SYNTHETIC PROBE for the organic tracer (task 2026-08-21-organic-lattice).
// A block with a KNOWN principal frame, so the tracer's answer can be checked against
// arithmetic rather than against itself: uniaxial tension along +x rotated by a known
// angle gives curves that must run along that axis, spaced at the requested d_sep.
//
// Build:
//   c++ -std=c++17 -O2 -I core/include evidence/2026-08-21-organic-lattice/organic_probe.cpp \
//       core/build/libtopopt.a -o /tmp/organic_probe && /tmp/organic_probe

#include <cmath>
#include <cstdio>
#include <vector>

#include "topopt/organic_lattice.hpp"

using namespace topopt;

int main() {
  VoxelGrid g;
  g.nx = 40; g.ny = 40; g.nz = 40;
  g.spacing = 1.0;
  g.origin = {0.0, 0.0, 0.0};
  // ★ voxel_count() IS tags.size(), so the tags must be sized from nx*ny*nz — sizing
  // them FROM voxel_count() leaves the grid empty and every assertion below vacuous.
  g.tags.assign(static_cast<std::size_t>(g.nx) * g.ny * g.nz, VoxelTag::Interior);
  const std::size_t n = g.voxel_count();
  if (n == 0) { printf("EMPTY GRID — the probe would measure nothing\n"); return 1; }

  std::vector<char> cand(n, 1);
  std::vector<double> stress(6 * n, 0.0);
  std::vector<double> sp(n, 0.0);
  std::vector<double> width(n, 40.0);

  // A field whose principal directions are the world axes everywhere, with distinct
  // magnitudes so the RANKING is unambiguous: sigma_xx = 3, sigma_yy = 2, sigma_zz = 1.
  for (std::size_t e = 0; e < n; ++e) {
    stress[6 * e + 0] = 3.0;
    stress[6 * e + 1] = 2.0;
    stress[6 * e + 2] = 1.0;
    sp[e] = 5.0;
  }

  OrganicParams P;
  P.min_extrudable_width_mm = 0.45;
  P.build_dir = {0, 0, 1};
  OrganicLattice L = trace_organic_lattice(g, cand, stress, sp, &width, P);
  const OrganicReport& r = L.report;
  printf("--- axis-aligned uniform field, d_sep = 5.0 mm on a 40 mm cube ---\n");
  printf("candidates            %zu\n", r.candidate_voxels);
  printf("degenerate            %zu (%.4f)\n", r.degenerate_voxels, r.degenerate_fraction);
  printf("curves traced/kept    %zu / %zu (thinned %zu, stubs %zu)\n",
         r.curves_traced, r.curves_kept, r.curves_thinned, r.curves_too_short);
  printf("per family            %zu / %zu / %zu\n", r.curves_per_family[0],
         r.curves_per_family[1], r.curves_per_family[2]);
  printf("connectors            %zu   len %.3f/%.3f/%.3f mm (min/med/max)\n",
         r.connectors, r.connector_min_length_mm, r.connector_median_length_mm,
         r.connector_max_length_mm);
  printf("  cross-dev (non-deg)  max %.3f deg  mean %.3f deg over %zu; degenerate %zu\n",
         r.max_connector_cross_deviation_deg, r.mean_connector_cross_deviation_deg,
         r.connectors_cross_measured, r.connectors_shorter_than_strut);
  printf("R3 <2 connections     %zu   (zero connections %zu)\n",
         r.curves_with_fewer_than_two_connections, r.curves_with_no_connection);
  printf("components            %zu   largest %zu (%.4f)\n", r.connected_components,
         r.largest_component_curves, r.largest_component_fraction);
  printf("requested spacing     %.4f .. %.4f mm\n", r.requested_spacing_min_mm,
         r.requested_spacing_max_mm);
  printf("ACHIEVED spacing      %.4f .. %.4f mm (median %.4f)\n",
         r.achieved_spacing_min_mm, r.achieved_spacing_max_mm,
         r.achieved_spacing_median_mm);
  printf("curves/member         min %.4f median %.4f  below floor %zu\n",
         r.min_curves_per_member, r.median_curves_per_member,
         r.below_curves_per_member_floor_voxels);
  printf("latticed voxels       %zu   rho %.5f .. %.5f (median %.5f)\n",
         r.latticed_voxels, r.rho_min_emitted, r.rho_max_emitted,
         r.rho_median_emitted);
  printf("emitted volume        %.3f mm^3 (soup basis)\n", r.emitted_volume_mm3);
  printf("segments outside 45   %.4f  (curves %.4f, connectors %.4f)\n",
         r.segments_outside_45_fraction, r.curve_segments_outside_45_fraction,
         r.connectors_outside_45_fraction);
  printf("analytic rho at d=5   %.6f  (organic_density_at)\n",
         organic_density_at(5.0, 0.45));
  printf("frame-swap worst      %.4f\n", r.max_frame_swap_fraction);

  // The check the field makes possible: every family-0 curve must run along +/-x.
  double worst = 0.0;
  for (const OrganicCurve& c : L.curves) {
    if (c.family != 0) continue;
    for (std::size_t t = 1; t < c.points.size(); ++t) {
      const double dx = c.points[t].x - c.points[t - 1].x;
      const double dy = c.points[t].y - c.points[t - 1].y;
      const double dz = c.points[t].z - c.points[t - 1].z;
      const double L2 = std::sqrt(dx * dx + dy * dy + dz * dz);
      if (!(L2 > 0.0)) continue;
      worst = std::max(worst, std::acos(std::min(1.0, std::fabs(dx) / L2)) * 180.0 / M_PI);
    }
  }
  printf("family-0 worst deviation from +/-x: %.6f deg  %s\n", worst,
         worst < 1e-6 ? "PASS" : "FAIL");

  // DETERMINISM: the same call twice must give byte-identical curve points.
  OrganicLattice L2 = trace_organic_lattice(g, cand, stress, sp, &width, P);
  bool same = L2.curves.size() == L.curves.size() &&
              L2.connectors.size() == L.connectors.size();
  if (same)
    for (std::size_t i = 0; i < L.curves.size() && same; ++i) {
      same = L.curves[i].points.size() == L2.curves[i].points.size();
      for (std::size_t t = 0; t < L.curves[i].points.size() && same; ++t)
        same = L.curves[i].points[t].x == L2.curves[i].points[t].x &&
               L.curves[i].points[t].y == L2.curves[i].points[t].y &&
               L.curves[i].points[t].z == L2.curves[i].points[t].z;
    }
  printf("determinism (same call twice, exact doubles): %s\n", same ? "PASS" : "FAIL");

  // The overhang clamp ARMED at 45, on the same field: family 0 runs along x, which is
  // 90 deg from the build direction, so EVERY step must be clamped.
  OrganicParams Q = P;
  Q.overhang_angle_deg = 45.0;
  OrganicLattice L3 = trace_organic_lattice(g, cand, stress, sp, &width, Q);
  printf("--- clamp armed at 45 deg ---\n");
  printf("clamped steps         %lld / %lld (%.4f)\n", L3.report.clamped_steps,
         L3.report.total_steps, L3.report.clamped_step_fraction);
  printf("curves touched        %zu / %zu (%.4f)\n", L3.report.curves_touched_by_clamp,
         L3.report.curves_kept, L3.report.curves_touched_fraction);
  printf("segments outside 45   %.6f  (curves %.6f  connectors %.6f)\n",
         L3.report.segments_outside_45_fraction,
         L3.report.curve_segments_outside_45_fraction,
         L3.report.connectors_outside_45_fraction);
  return 0;
}
