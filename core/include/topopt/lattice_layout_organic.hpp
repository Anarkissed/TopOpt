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
// O12, the spacing is a RANGE that follows the stress, by the old run's own law (organic_spacing): spacing_min_mm at
// the busiest voxel of the weave, spacing_max_mm at the quietest. `spacing_mm` > 0 is the one spacing of stage 1b:
// both ends at that number (the range is then not read). O13, shape fit: the spacing is also tightened toward the
// weave's outline and in thin members, as the old run does it.
struct OrganicAsk {
  double spacing_mm = 0.0;        // > 0: one spacing everywhere (both ends of the range); 0: the range below
  double width_mm = 0.0;          // the strut diameter; 0 = the generator's own: the minimum extrudable width
  Vec3 build_dir{0.0, 0.0, 1.0};  // up, as printed (the tracer's overhang clamp reads it; the clamp is off)
  double spacing_min_mm = 3.0;    // the spacing at the busiest voxel, mm; > 0 (the old run's grading.cell_min_mm)
  double spacing_max_mm = 8.0;    // the spacing at the quietest voxel, mm; >= spacing_min_mm (its cell_max_mm)
  double spacing_exponent = 1.0;  // the grading law's demand exponent (the old run's grading.demand_exponent); > 0
  double reference_mpa = 0.0;     // > 0: a stated stress for the top of the law. 0: the percentile below (the old run)
  double percentile = 0.95;       // read when reference_mpa is 0 (the old run's grading.aesthetic_percentile)
  bool shape_fit = true;          // O13 (the old run's grading.organic_shape_fit, on when the job does not say)
};

// O12: the spacing handed to the tracer, one per voxel of the field's grid (0 off the candidates), with the candidates
// (voxels whose CENTRE is lattice of `region`). It is the old run's field for an ordinary Traced job (run_job.cpp,
// run_organic_step, with the Aesthetic grading law of grade_lattice), with minimize_plastic ON fixed: the owner's
// rule is that minimize_plastic has no bearing on the lattice, and on is what the app sends by default. The weave is
// every voxel that is lattice of ANY weave region (the old run's lattice set). s is the tensor's von Mises (true
// shear); per candidate:
//   u = s / reference held to 0 .. 1 (reference: the stated one, or the `percentile` of s over the weave, sorted,
//       index floor(q * (n - 1)); a reference of 0 gives u = 0)
//   g = u^(2 * spacing_exponent)                    (the grading law's density, less its constant band ends)
//   f = ((g - g_lo) / (g_hi - g_lo))^2, held to 0 .. 1, g_lo and g_hi the weave's least and greatest g (f = 0 when
//       they are equal: a uniform stress gives the widest)
//   d = max - (max - min) * f
// The two 2s are the old run's exponents with minimize_plastic on (kAestheticOpenExponent; off, both are 0.5).
// O13, shape fit (ask.shape_fit, a range with max > min): d = min(d, max(min, cap)), cap the smaller of
//   2 * k * h: k the number of voxel steps (faces only) from the voxel to the nearest voxel that is not of the weave,
//     1 for a voxel on the field grid's own face; h the voxel. A cell of size d centred there would cross the outline.
//   W / 5: W the part's member width there (local_member_thickness_mm: the largest ball inside the part that holds
//     the voxel, over the voxels whose centre is inside the part, read no farther than 32 voxels: wider is no cap),
//     5 the cells across a member octet needs (lattice_cells_per_member_min). A thin member holds smaller cells.
// It only ever tightens, never under min. With min = max nothing changes. Throws std::invalid_argument for min <= 0,
// max < min, exponent <= 0.
struct OrganicSpacing {
  std::vector<char> candidate;
  std::vector<double> spacing_mm;
  std::size_t candidates = 0;
  double reference_mpa = 0.0;           // the reference used (stated, or the weave's percentile)
  std::size_t shape_fit_tightened = 0;  // O13: candidates the shape fit tightened
};
OrganicSpacing organic_spacing(const Domain& domain, int region, const TensorField& field, const OrganicAsk& ask);

// The spacing the tracer actually used, over the candidates of one trace (its spacing_used_mm, which raises the asked
// spacing to its print and resolution floors where they bind); all 0 when nothing was traced.
struct OrganicTraceStats {
  std::size_t candidates = 0;
  double spacing_smallest_mm = 0.0, spacing_largest_mm = 0.0, spacing_mean_mm = 0.0;
  double reference_mpa = 0.0;
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
