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
// G1: Organic's two placements, the owner's OR25 and OR26. Traced (trace_strands) is stage 1b's; Grown (grow_strands)
// is the rewrite of 2026-11-15 in this engine (organic_grow.cpp).
enum class OrganicMode : std::uint8_t { Traced, Grown };
struct OrganicAsk {
  double spacing_mm = 0.0;        // > 0: one spacing everywhere (both ends of the range); 0: the range below
  double width_mm = 0.0;          // the strut diameter; 0 = the generator's own: the minimum extrudable width
  Vec3 build_dir{0.0, 0.0, 1.0};  // up, as printed (the tracer's overhang clamp reads it, the clamp off; Grown grows along it)
  double spacing_min_mm = 3.0;    // the spacing at the busiest voxel, mm; > 0 (the old run's grading.cell_min_mm)
  double spacing_max_mm = 8.0;    // the spacing at the quietest voxel, mm; >= spacing_min_mm (its cell_max_mm)
  double spacing_exponent = 1.0;  // the grading law's demand exponent (the old run's grading.demand_exponent); > 0
  double reference_mpa = 0.0;     // > 0: a stated stress for the top of the law. 0: the percentile below (the old run)
  double percentile = 0.95;       // read when reference_mpa is 0 (the old run's grading.aesthetic_percentile)
  bool shape_fit = true;          // O13 (the old run's grading.organic_shape_fit, on when the job does not say)
  // OR30: the Finish is the regular lattices' own (Settings::rim_mm, cover_mm, skin, skin_spec), nothing here. Rim and
  // Covered are "where" settings of the domain the weave is traced and laid in; Skin on lays the net skin (O16).
  // Read by Grown only (grow_strands); Traced does not read them:
  OrganicMode mode = OrganicMode::Traced;
  bool walls_out = false;         // G2 (idea C): seeds on the region's walls too, growing inward
  double layer_mm = 0.2;          // one step of growth is one layer along build_dir, mm; > 0
  bool ties = true;               // G9: the transfer ties (the old job's default: on)
  double tie_swirl = 1.0;         // G9: the ties' swirl, 0 .. 1 (the old job's default: 1)
  // G2: the floor's seeds, one per stride cell of seed_stride x the median spacing each way, each placed at random in
  // its cell, its first heading at random inside the cone. The randomness is this fixed number: the same part and
  // settings give the same strands every time, on any thread count.
  double seed_stride = 0.25;      // > 0
  std::uint64_t seed = 1;
  // G13 (brief G5): the floor's feet compete after the first pruning; a foot is kept only where no kept foot stands
  // within foot_gap x the local spacing of its floor point (measured on the floor).
  // The lead's ruling (brief G5): 2.5, the smallest of 1, 1.5, 2, 2.5 that leaves the made-up cube's floor at most
  // 80 % covered by true feet. 0 or less: the feet do not compete (every foot is kept).
  double foot_gap = 2.5;
  // D (brief G6, step 3, an EXPERIMENT for a picture; the owner: "Why not work backwards? Instead of the goal being go
  // reach a face, the stress lines are the goal, but there are benefits and rules to [hitting] a face?"): D1, where the
  // spacing is at least a tenth of the way from the widest to the tightest the heading follows the stress with no
  // pull; D2, a tip that leaves through a side face offers ONE branch one spacing back, away from that face.
  bool stress_goal = false;
  // E (brief G6, try keys): a place is bare for the re-seeding when no kept strand lies within void_ratio x its
  // spacing (G11's 1.5; the "bare" share reported keeps 1.5); and the whole re-seed step (bare places found after the
  // pruning, stubs, the new tips grown, pruned again) is done reseed_rounds times (G11: once; 0: none).
  double void_ratio = 1.5;   // > 0
  int reseed_rounds = 1;     // >= 0
  // E (the owner on walls-out seeds: "I'd say their goal is to connect as many vines as possible"): a wall seed's tip
  // is grown after every floor seed's tip and its descendants, aims at the nearest kept strand it has not joined that
  // rises at the cone or steeper from it (within 4 spacings), stays on each joint it makes, and offers no branches.
  bool wall_connect = false;
  // E: wall roots compete as feet do (G13), separately from them: a wall seed's root is kept only where no kept wall
  // root stands within wall_gap x the local spacing of its wall point (straight-line distance). 0 or less: off.
  double wall_gap = 0.0;
  // F (brief G7, a try key): crossing vines. A wall seed's own strand heads on its heading, the stress and straight
  // away from its wall (no pull to a face), joins as today and goes on from the hit with its heading, with no limit
  // on its joins. 1: the wall tips grown after every floor tip and its descendants; 2: before any floor tip. 0: off.
  // Needs walls_out; refused with wall_connect.
  int wall_cross = 0;   // 0, 1 or 2
};

// O16, the net skin: Finish Skin (Settings::skin) on a weave region (the old finish step "Skin", organic_lattice.cpp,
// read for its rules and numbers only). For each
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
// A join is a weave bar (`net`): as wide as the thinner landing (or `width_mm` when above 0: SkinSpec::width_mm), `cell` the reach, its ends Node exactly at the two
// landings; a landing that is a cut end on the surface (Surface) has landed (Joined into the net strut). Nothing is
// pruned here: drop_loose_bars and the writer's bridge rules (O6 to O10) judge net struts as every bar.
// Returns the number of net struts laid. The same for any number of threads (it runs on one).
std::size_t lay_net_skin(Bars& bars, const Domain& domain, const std::vector<std::pair<int, double>>& reach,
                         double width_mm = 0.0);

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
  // O16: the trace's own median spacing (its report's achieved_spacing_median_mm): the net skin's reach for Traced, as
  // the old run sets it (Grown reads the spacing field's median instead).
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

// ── GROWN (G1 to G12, docs/design/lattice-rebuild/01-rules.md section 11) ─────
// What one Grown placement did. Lengths are curve lengths, mm, measured the same way for "grown" and "kept": the
// length of the strands' own segments. A segment is kept when a bar of it is left after the path's pruning (weave_bars,
// split_at_crossings, join_loose_bars, drop_loose_bars, drop_adrift_bars, as Session::lay_weave runs them on a weave
// alone). Every laid segment is counted once: grown = kept + every cut below.
struct GrowReport {
  // Seeds (G2): on the floor, one per stride cell; on the walls with walls_out; refused at their first step.
  std::size_t seeds_floor = 0, seeds_wall = 0, seeds_refused_support = 0;
  std::size_t strands_grown = 0, steps = 0, clamped = 0;   // tips grown, steps laid, headings held up to the cone
  // How tips ended (G3 to G5): at the region's edge, on a step with nothing under it, on their seventh join.
  std::size_t ended_edge = 0, ended_unsupported = 0, ended_joins = 0;
  // ... of them the floor seeds' tips that took at least one step (G16a, brief G6): how many, and how each ended.
  std::size_t floor_stepped = 0, floor_ended_edge = 0, floor_ended_unsupported = 0, floor_ended_joins = 0;
  // G5: crowded tips. Joined into the neighbour (the run 3 mm or less), then deflected; of those joins, the ones the
  // tip grew on from; crowded with a longer run: climbed on.
  std::size_t joins = 0, grew_on_after_join = 0, joins_refused_span = 0;
  // Branches (G6): offered (two each time), grown, refused by cause; a crowded branch with a short run is a link.
  std::size_t branches_offered = 0, branches_grown = 0, links = 0;
  std::size_t refused_region = 0, refused_support = 0, refused_crowded = 0;
  std::size_t tips = 0, tip_budget_hit = 0;   // tips pushed (seeds, branches, re-seeds); 1 when the 200,000 were reached
  // Re-seeding after the first pruning (G11): the bare share of the region before and after it (candidate voxels with
  // no kept strand within 1.5 x their spacing), the bare places found, stubs landed and failed, the stubs' length.
  double bare_before = 0.0, bare_after = 0.0;
  std::size_t reseed_voids = 0, reseed_landed = 0, reseed_failed = 0;
  double reseed_mm = 0.0;
  // G16c (brief G6): of the stubs landed, those rooted on a kept vine's vertex (the rest walked); and every stub made
  // (its root, its top: the bare place; its points, root first; its length; the local spacing and the landing radius
  // at the bare place).
  std::size_t reseed_from_vertex = 0;
  std::vector<std::size_t> reseed_voids_round;   // E: the bare places found, per re-seed round
  // E, wall_connect: wall tips grown, the joins they made, the distinct lines each joined; how they ended.
  std::size_t wall_grown = 0, wall_joins = 0, wall_ended_edge = 0, wall_ended_unsupported = 0, wall_ended_joins = 0;
  std::vector<std::size_t> wall_lines_joined;
  // E, wall_gap: wall roots that competed (a wall seed's strand still holding its root), kept, removed with a joint,
  // whole vines removed.
  std::size_t wall_roots = 0, wall_roots_kept = 0, wall_roots_cut_at_joint = 0, wall_vines_removed = 0;
  // F, wall_cross: crossing vines seeded, grown; how they ended (edge at a side face, the top, no face; unsupported;
  // the loop's guard); per grown vine its joins and the level distance from its wall point to its end (mm).
  std::size_t cross_seeded = 0, cross_grown = 0, cross_ended_side = 0, cross_ended_top = 0, cross_ended_noface = 0,
              cross_ended_unsupported = 0, cross_ended_guard = 0;
  std::vector<std::size_t> cross_joins;
  std::vector<double> cross_reach_mm;
  // D2 (stress_goal): branches offered one spacing back from a side face, grown, refused, strands too short for one;
  // and every tip that ended by leaving the region, by its last voxel's wall site: +x, -x, +y, -y, +z, none.
  std::size_t d2_offered = 0, d2_grown = 0, d2_refused = 0, d2_short = 0;
  std::size_t face_hits[6] = {0, 0, 0, 0, 0, 0};
  struct Stub {
    Vec3 root{}, top{};
    std::vector<Vec3> pts;
    double mm = 0.0, spacing_mm = 0.0, land_mm = 0.0;
    bool from_vertex = false;
  };
  std::vector<Stub> stubs;
  // Transfer ties (G9).
  std::size_t ties_seeded = 0, ties_laid = 0, ties_refused_minor = 0, ties_refused_reach = 0;
  // G13, the feet (floor seeds' strands) after the first pruning: kept; removed, cut from the floor up to their first
  // joint that holds with another plant's strand; removed whole (no such joint); the length those cuts took, with what
  // hung only on a vine removed whole (counted, in the lengths below, under "leads to nothing").
  std::size_t feet_kept = 0, feet_cut_at_joint = 0, vines_removed = 0;
  double feet_cut_mm = 0.0;
  // ... of which above half the region's height: the length, and the strands it was taken from.
  double feet_cut_high_mm = 0.0;
  std::size_t feet_cut_high_strands = 0;
  // A join or a link whose segment would leave the region's candidates: not made.
  std::size_t joins_refused_outside = 0, links_refused_outside = 0;
  // Lengths, mm (G12).
  double grown_mm = 0.0, kept_mm = 0.0;
  double cut_outside_mm = 0.0, cut_unsupported_mm = 0.0, cut_nothing_mm = 0.0, cut_repeat_mm = 0.0;
  std::size_t strands = 0;      // returned
  double ms = 0.0;
  void add(const GrowReport& o);
};

// G1 to G12: the owner's Grown placement of one weave region (OR26: "strands grown like organic vines, top to bottom
// or walls-out"), new code in this engine with the ORIGINAL Grown's growing rules and numbers (brief G4); the old
// generator (grow_organic_lattice) is neither edited nor called. The spacing is organic_spacing's (O12), the
// directions the `field`'s, the width the domain's thinnest strut or `ask.width_mm` (never under it: G8), one step one
// `ask.layer_mm` along `ask.build_dir`. Seeds placed at random by `ask.seed` (G2); each step follows the stress and is
// pulled toward the nearest face of the region that is not its floor (G3), held to the cone and supported (G4);
// crowded tips join, deflect and grow on (G5; never across what is not the region); branches and links (G6); transfer
// ties (G9). Then the pruning (G10, the feet competing in the first, G13; the path's own answer, G11), ONE round of
// re-seeding in the bare places it leaves, grown and pruned the same way, every cut counted (G12). The strands returned
// go through exactly Traced's path (Session::lay_organic). The same strands for the same inputs, every time. An empty
// field, or no candidate voxel, gives none. Throws std::invalid_argument for a range organic_spacing refuses, a width
// under the thinnest strut, a layer or a seed stride not above 0, a foot gap not a number, or a degenerate build
// direction.
std::vector<Strand> grow_strands(const Domain& domain, int region, const TensorField& field, const OrganicAsk& ask,
                                 GrowReport* report = nullptr);

// G3 and G16a alone, exposed for tests: the unit direction of the pull ("the light") at `p`, as grow_strands sets it up
// for `region` (the build direction where there is no pull); the build direction for an empty field or no candidate.
Vec3 grown_light(const Domain& domain, int region, const TensorField& field, const OrganicAsk& ask, const Vec3& p);

// O3 alone, exposed for tests: the fewest of the strand's points that keep each of its points within `tolerance_mm`
// of the line through the kept ones, both ends kept (the first of several equally short answers, by index).
std::vector<std::size_t> straighten_points(const std::vector<Vec3>& points, double tolerance_mm);

}  // namespace topopt::lattice_layout
