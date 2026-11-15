// Lattice rebuild, Organic stage 1b: the owner's Traced placement through the new engine (rules O3, O4).
// The old tracer (trace_organic_lattice, organic_lattice.hpp) is called as it is; its raw curves and connectors become
// strands (lattice_layout.hpp, Strand) and go through stage 1a's path (weave_bars, split_at_crossings, joining). Nothing
// after the trace in the old path is called: no clip at the edge, no repair loop, no mat, fill, trim, weld or mesher.
#pragma once

#include <vector>

#include "topopt/lattice_layout.hpp"

namespace topopt::lattice_layout {

// A stress result as the old tracer reads it: the grid of DemandField (same origin, spacing, sizes and voxel order:
// (k * ny + j) * nx + i), with SIX values per voxel: the full Cauchy tensor in Voigt order [xx, yy, zz, xy, yz, zx],
// true shear (not engineering), MPa. That is the order trace_organic_lattice reads (organic_lattice.hpp, `stress`).
// Von Mises alone gives no direction; a voxel whose tensor is zero has none and a curve stops there.
struct TensorField {
  Vec3 origin{};              // the grid's low corner, mm, in the part's own coordinates
  double spacing = 0.0;       // voxel edge, mm
  int nx = 0, ny = 0, nz = 0;
  std::vector<double> voigt;  // 6 * nx * ny * nz
  // No voxels, or spacing <= 0, or voigt.size() != 6 * nx * ny * nz.
  bool empty() const;
  std::size_t index(int i, int j, int k) const {
    return (static_cast<std::size_t>(k) * static_cast<std::size_t>(ny) + static_cast<std::size_t>(j)) *
               static_cast<std::size_t>(nx) +
           static_cast<std::size_t>(i);
  }
};

// What the trace is asked for. Everything else the tracer reads is its own default, or from the domain:
//   the minimum extrudable width is the domain's thinnest strut, its line width times its strut lines
//   (DomainSpec::bead_mm * min_strut_lines), and the bead is taken as stated (bead_is_stated), so no calibration runs
//   and every strand is exactly the width the trace gives it.
// O12, the spacing is a RANGE that follows the stress (organic_spacing): tight (spacing_min_mm) where the stress is at
// or over the reference, wide (spacing_max_mm) where there is none. `spacing_mm` > 0 is the one spacing of stage 1b:
// both ends at that number (the range is then not read).
struct OrganicAsk {
  double spacing_mm = 0.0;        // > 0: one spacing everywhere (both ends of the range); 0: the range below
  double width_mm = 0.0;          // the strut diameter; 0 = the generator's own: the minimum extrudable width
  Vec3 build_dir{0.0, 0.0, 1.0};  // up, as printed (the tracer's overhang clamp reads it; the clamp is off)
  double spacing_min_mm = 3.0;    // the spacing at or over the reference stress, mm; > 0
  double spacing_max_mm = 8.0;    // the spacing where there is no stress, mm; >= spacing_min_mm
  double spacing_exponent = 1.0;  // the curve from stress to spacing (f^exponent below); > 0
  double reference_mpa = 0.0;     // > 0: the stress at which the spacing is the smallest. 0: the region's own (below)
  double percentile = 0.95;       // read when reference_mpa is 0
  // O15, the Organic rim (an option): 0 = none; > 0 = that width, mm; below 0 = the width the app sends when its
  // "Solid rim at edges" switch is on (organic_rim_default_mm). A "where" setting: changing it reads the part again.
  // 0 here so a caller that does not ask is unchanged; the file job's default is below 0 (the app's).
  double rim_mm = 0.0;
  // O16, the Organic net skin (an option): on, a net of struts over each open face of every weave region
  // (lay_net_skin). false here; the file job's default is on (the app's).
  bool net_skin = false;
};

// O15: the rim the app sends with its switch on (LatticeSettings.organicSolidRimForJobMM, OrganicSizeCheck.floor):
// the printability floor, max(1.535 x the line width, one voxel of the stress result's grid). 1.535 is
// 0.5 x sqrt(3 pi), the app's printFloorPerBead.
double organic_rim_default_mm(double bead_mm, double voxel_mm);

// O16, the net skin (the old finish step "Skin", organic_lattice.cpp, read for its rules and numbers only). For each
// (region, reach) asked, over that weave region's open face (the part's surface where the region's lattice meets it,
// read a hair inside the nearest point of the surface):
//   landings: the ends of the region's bars within their own half width + 0.5 x reach of that open face (the old
//     kOrganicFinishBandRatio), each place once (the thinnest width there);
//   a join between two landings lies 0.55 to 1.0 reach apart (kOrganicFinishMinSpanRatio), their surface normals
//     (the depth's gradient, read a half width either side) within 50 degrees (cos 0.6428, kOrganicFinishCoplanarCos)
//     when both are read, no bar already joins exactly those two places, it is not buried (all 7 points along it inside
//     existing bars), and it stays on the region (each of its 5 inner points lattice of the region, or within its half
//     width of the open face; the old clip to the region);
//   each landing wants its 3 nearest such partners (the old net_skin_degree); a pair wanted both ways is joined; then
//     every landing with fewer than 1, then fewer than 2, joins takes its nearest partner within 1.5 reach (0.55
//     reach at least), by the same tests; a pair is joined once.
// A join is a weave bar (`net`): as wide as the thinner landing, `cell` the reach, its ends Node exactly at the two
// landings; a landing that is a cut end on the surface (Surface) has landed (Joined into the net strut). Nothing is
// pruned here: drop_loose_bars and the writer's bridge rules (O6 to O10) judge net struts as every bar.
// Returns the number of net struts laid. The same for any number of threads (it runs on one).
std::size_t lay_net_skin(Bars& bars, const Domain& domain, const std::vector<std::pair<int, double>>& reach);

// O12: the spacing handed to the tracer, one per voxel of the field's grid (0 off the candidates), with the candidates
// (voxels whose CENTRE is lattice of `region`). Per candidate, from the tensor's von Mises s (true shear):
//   f = s / reference held to 0 .. 1;  d = max - (max - min) * f^exponent
// reference: the stated one, or the `percentile` of s over the region's candidates (sorted, index floor(q * (n - 1)),
// as stress_reference reads its percentile). A reference of 0 (no stress in the region) gives f = 0: the widest.
// The old run (run_job.cpp, run_organic_step) uses the same line, d = cell_max - (cell_max - cell_min) * f^exp, but
// its f is the grading law's relative density normalised over the region, (rho - rho_lo) / (rho_hi - rho_lo); see the
// comment in organic.cpp for where the two differ. Throws std::invalid_argument for min <= 0, max < min, exponent <= 0.
struct OrganicSpacing {
  std::vector<char> candidate;
  std::vector<double> spacing_mm;
  std::size_t candidates = 0;
  double reference_mpa = 0.0;   // the reference used (stated, or the region's percentile)
};
OrganicSpacing organic_spacing(const Domain& domain, int region, const TensorField& field, const OrganicAsk& ask);

// The spacing the tracer actually used, over the candidates of one trace (its spacing_used_mm, which raises the asked
// spacing to its print and resolution floors where they bind); all 0 when nothing was traced.
struct OrganicTraceStats {
  std::size_t candidates = 0;
  double spacing_smallest_mm = 0.0, spacing_largest_mm = 0.0, spacing_mean_mm = 0.0;
  double reference_mpa = 0.0;
  // O16: the trace's own median spacing (its report's achieved_spacing_median_mm): the net skin's reach, as the old run
  // sets it.
  double spacing_median_mm = 0.0;
};

// The Traced placement of one weave region, as strands. The candidate voxels are those whose CENTRE the domain says is
// lattice of `region`; trace_organic_lattice runs on the field's grid with them. One strand per curve (in the trace's
// order), then one per connector (its two points): the points as traced (part coordinates, mm), width twice the
// curve's (or connector's) radius at every point, `spacing_mm` the smallest spacing the tracer used under any of its
// points, `region`. The spacing asked per voxel is organic_spacing's (O12).
//   O3, straighten: each strand is reduced to the fewest of its own points that keep every traced point within 0.1 x
//     its width of the straightened line; both ends kept. No widening.
//   O4, free ends: each curve's two ends (a connector's ends sit on curves) are run on along the strand's own last
//     segment, at most one spacing, to where it leaves the region's lattice: the end is moved one width past that
//     point, so weave_bars cuts it there and finishes it (finish_bar_ends): Solid (run in by its width), Surface
//     (moved onto the part's surface), or Loose (lattice of another region). An end with no edge within one spacing
//     stays where it is, Loose, for the joining.
// An empty field, or no candidate voxel, gives no strands. Throws what the tracer throws (std::invalid_argument): a
// spacing that is not > 0 (or a range organic_spacing refuses), a width under the minimum extrudable width, a
// degenerate build direction.
// `stats`, when given, receives the spacing used (OrganicTraceStats).
std::vector<Strand> trace_strands(const Domain& domain, int region, const TensorField& field, const OrganicAsk& ask,
                                  OrganicTraceStats* stats = nullptr);

// O3 alone, exposed for tests: the fewest of the strand's points that keep each of its points within `tolerance_mm`
// of the line through the kept ones, both ends kept (the first of several equally short answers, by index).
std::vector<std::size_t> straighten_points(const std::vector<Vec3>& points, double tolerance_mm);

}  // namespace topopt::lattice_layout
