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
// G1: Organic's two placements, the owner's OR25 and OR26. Traced (trace_strands) is stage 1b's; Grown (grow_strands)
// is the rewrite of 2026-11-15 in this engine (organic_grow.cpp).
enum class OrganicMode : std::uint8_t { Traced, Grown };
struct OrganicAsk {
  double spacing_mm = 0.0;        // > 0: one spacing everywhere (both ends of the range); 0: the range below
  double width_mm = 0.0;          // the strut diameter; 0 = the generator's own: the minimum extrudable width
  Vec3 build_dir{0.0, 0.0, 1.0};  // up, as printed (the tracer's overhang clamp reads it; Grown grows along it)
  double spacing_min_mm = 3.0;    // the spacing at or over the reference stress, mm; > 0
  double spacing_max_mm = 8.0;    // the spacing where there is no stress, mm; >= spacing_min_mm
  double spacing_exponent = 1.0;  // the curve from stress to spacing (f^exponent below); > 0
  double reference_mpa = 0.0;     // > 0: the stress at which the spacing is the smallest. 0: the region's own (below)
  double percentile = 0.95;       // read when reference_mpa is 0
  // Read by Grown only (grow_strands); Traced does not read them:
  OrganicMode mode = OrganicMode::Traced;
  bool walls_out = false;         // G2 (idea C): seeds on the region's walls too, growing inward
  double layer_mm = 0.2;          // one step of growth is one layer along build_dir, mm; > 0
  bool ties = true;               // G9: the transfer ties (the old job's default: on)
  double tie_swirl = 1.0;         // G9: the ties' swirl, 0 .. 1 (the old job's default: 1)
};

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

// ── GROWN (G1 to G12, docs/design/lattice-rebuild/01-rules.md section 11) ─────
// What one Grown placement did. Lengths are curve lengths, mm, measured the same way for "grown" and "kept": the
// length of the strands' own segments. A segment is kept when a bar of it is left after the path's pruning (weave_bars,
// split_at_crossings, join_loose_bars, drop_loose_bars, drop_adrift_bars, as Session::lay_weave runs them on a weave
// alone). Every laid segment is counted once: grown = kept + every cut below.
struct GrowReport {
  // Seeds (G2): on the floor, one per local spacing; on the walls with walls_out; refused when their turn came.
  std::size_t seeds_floor = 0, seeds_wall = 0, seeds_refused_room = 0, seeds_refused_support = 0;
  std::size_t strands_grown = 0, steps = 0, clamped = 0;   // tips grown, steps laid, headings held up to the cone
  // How tips ended (G3 to G5): at the region's edge, on a step with nothing under it, joined into a neighbour.
  std::size_t ended_edge = 0, ended_unsupported = 0, ended_joined = 0;
  std::size_t crowded_climbed_on = 0;   // crowded, the run to join over 3 mm, not within the lower limit: climbed on
  // Branches (G6, G7): offered, grown, refused by cause; a crowded branch with a short run is a link instead.
  std::size_t branches_offered = 0, branches_grown = 0, links = 0;
  std::size_t refused_region = 0, refused_support = 0, refused_crowded = 0, refused_room = 0;
  // GR-REWIND (G5): each try, and each place a tip was rewound to, by how it ended.
  std::size_t rewinds = 0, rewind_places = 0, rewind_grew_on = 0, rewind_joined = 0, rewind_ended_on_joint = 0;
  double taken_back_mm = 0.0;
  // Thinning to the window (G10, pruning step 4): stretches of a weaker strand left out; of those, joined into the other.
  std::size_t thinned = 0, thinned_joined = 0;
  // Regrowth into holes after the path's pruning (G11, step 5).
  std::size_t regrow_rounds = 0, holes = 0, regrow_landed = 0, regrow_failed = 0;
  // Transfer ties (G9).
  std::size_t ties_seeded = 0, ties_laid = 0, ties_refused_minor = 0, ties_refused_reach = 0, ties_refused_support = 0;
  // Lengths, mm (G12, step 6).
  double grown_mm = 0.0, kept_mm = 0.0;
  double cut_outside_mm = 0.0, cut_unsupported_mm = 0.0, cut_nothing_mm = 0.0, cut_crowded_mm = 0.0,
         cut_repeat_mm = 0.0;
  std::size_t strands = 0;      // returned
  double ms = 0.0;
  void add(const GrowReport& o);
};

// G1 to G12: the owner's Grown placement of one weave region (OR26: "strands grown like organic vines, top to bottom
// or walls-out"), new code in this engine; the old generator (grow_organic_lattice) is neither edited nor called. The
// spacing is organic_spacing's (O12), the directions the `field`'s, the width the domain's thinnest strut or
// `ask.width_mm` (never under it: G8), one step one `ask.layer_mm` along `ask.build_dir`. Strands grow from seeds (G2),
// each step following the stress (G3), held to the cone and supported (G4), kept to the spacing window by crowding,
// joins and GR-REWIND (G5); branches (G6, G7); then repeats merged (G10, step 1), thinned to the window (step 4), the
// path's pruning run (steps 2, 3) and holes regrown (G11, step 5), the transfer ties laid (G9), every cut counted (G12).
// The strands returned go through exactly Traced's path (Session::lay_organic). The same strands for the same inputs,
// every time. An empty field, or no candidate voxel, gives none. Throws std::invalid_argument for a range
// organic_spacing refuses, a width under the thinnest strut, a layer not above 0 or a degenerate build direction.
std::vector<Strand> grow_strands(const Domain& domain, int region, const TensorField& field, const OrganicAsk& ask,
                                 GrowReport* report = nullptr);

// O3 alone, exposed for tests: the fewest of the strand's points that keep each of its points within `tolerance_mm`
// of the line through the kept ones, both ends kept (the first of several equally short answers, by index).
std::vector<std::size_t> straighten_points(const std::vector<Vec3>& points, double tolerance_mm);

}  // namespace topopt::lattice_layout
