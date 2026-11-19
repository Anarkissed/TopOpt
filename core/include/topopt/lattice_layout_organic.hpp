// Lattice rebuild, Organic stage 1b: the owner's Traced placement through the new engine (rules O3, O4).
// The old tracer (trace_organic_lattice, organic_lattice.hpp) is called as it is; its raw curves and connectors become
// strands (lattice_layout.hpp, Strand) and go through stage 1a's path (weave_bars, split_at_crossings, joining). Nothing
// after the trace in the old path is called: no clip at the edge, no repair loop, no mat, fill, trim, weld or mesher.
#pragma once

#include <cstdint>
#include <functional>
#include <string>
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
// Brief E2, item 9: a least strut width over a ball (from a strengthen round, organic_strengthen). After the lay, every
// non-link bar whose middle lies within `radius_mm` of `centre` is at least `width_mm` wide, never above the job's own
// upper strut width (OrganicAsk::width_heavy_mm); links then follow S8 where that rose. Applied only when the strut
// width is on a Sweep (width_heavy_mm above 0): a single width is the owner's own number.
struct WidthFloor {
  Vec3 centre{};
  double radius_mm = 0.0;
  double width_mm = 0.0;
};

// ── Brief E3a: STRENGTHENING BY ADDING (rules OS10 to OS14) ──────────────────────────────────────────────────────────
// A strengthen round in the additive mode never lays the lattice again: it adds to the lattice as laid, and nothing that
// exists is moved or removed (a bar may be cut into pieces on its own line, never thinner). What a round added is kept
// as a list of operations (AddOp), applied in order after the lay of the job's own inputs; after each round the bars'
// hash (bars_hash) is stated, and a lay that does not reach it is refused (never a silent difference).
//   kind 1, a brace point: v = the host bar's a (x, y, z), b (x, y, z), u along it from a, the braces' width. All brace
//     points of a round are laid in one call of lay_braces (rule T's brace maker), before the round's widenings.
//   kind 2, a widening: v = the bar's a (x, y, z), b (x, y, z), its new width (never thinner). Links ending where a
//     widened bar ends then follow S8 (only wider).
//   kind 3 (OS18, brief E8), a relief vine: v = region, width, cell, end_a (0 Node: on a bar; 1 Solid), end_b, n, then n
//     points (x, y, z). Laid after the round's braces and widenings, in op order, by lay_relief_vine.
// A later engine may add kinds; the file carries each operation's kind and length, and an engine meeting a kind it
// does not know refuses the list.
struct AddOp {
  int kind = 0;
  std::vector<double> v;
};
struct AddRound {
  std::vector<AddOp> ops;
  std::uint64_t hash = 0;   // bars_hash after this round
};
struct Additions {
  std::vector<AddRound> rounds;
  bool empty() const { return rounds.empty(); }
};

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
  // G (brief G8, a try key): top runs. A strand that ended by leaving the region through the top face runs along it,
  // level, one radius below its end, on the stress: the longest a run may be, in local spacings. 0: off.
  double top_run = 0.0;
  // G (addendum): each top end (and each foot, for roots) makes 1 to run_max runs, fanned evenly round the build
  // direction; 1 or more.
  int run_max = 1;
  // G (addendum): roots: a foot's runs along the floor, one radius above its floor point; their longest length in local
  // spacings, then they dip into the floor. 0: off.
  double root_run = 0.0;
  // G (follow-up): a run (root) is not started where a point of a run (root) made from another end lies within
  // run_gap x the local spacing of its start; 0: the test is off.
  double run_gap = 0.5;
  // H (brief G9, try keys): how firmly a run turns to its target (above 0); the magnet's reach in local spacings
  // (0: off); the drift toward stronger stress (0: off); the travel, in local spacings, before it may weld onto a
  // strand (0 or above); the roots' own not-on-top distance (below 0: run_gap).
  double run_follow = 1.0;
  double run_pull = 0.0;
  double run_seek = 0.0;
  double run_min = 0.5;
  double root_gap = -1.0;
  // I (brief G10, try keys): AUTO. u(p), the stress share 0 .. 1, is O12's: the von Mises at p's voxel over the
  // spacing's reference (grading_demand_fraction, Aesthetic); 0 off the field or with a reference of 0.
  // auto_by_stress: a top end makes round(run_max x u(end)) runs and a foot round(run_max x u(floor point)) roots
  // (0 to run_max) in place of the random draw. width_heavy_mm above 0: every point handed back is
  // w + (width_heavy_mm - w) x u(point) wide, w the light width (the growth itself uses w); 0: off.
  // Q2 (brief G24): Traced too: every point of a traced strand (curves and connectors) is w + (width_heavy_mm - w) x
  // u(point), w its own (light) width; the tracer, O3 and O4 use w.
  bool auto_by_stress = false;
  double width_heavy_mm = 0.0;
  // J (brief G12): member_cap false: O13's shape fit applies the outline cap (2 k h) alone, not the member cap (W / 5)
  // (the owner, 2026-11-16: "the 5 cell rule is not useful for organic"). prune: rule J2 on the weave bars of each Grown
  // area in the path (prune_weave). Defaults: as before.
  bool member_cap = true;
  bool prune = false;
  // K1 (brief G13), a flat floor on the bed (the owner, 2026-11-16: "Yes, add the floor"): in a Grown area every point
  // less than this height above the bed (the plane through the part's lowest point along build_dir) is solid, not
  // lattice. Carried to the domain as Settings::bed_floor_mm (DomainSpec::bed_floor_mm) by the file job, for Grown and
  // (Q1, brief G24) Traced alike. 0 = no floor (as before); 0 or above. OP9 (brief C2, E3): Session::lay_organic (and
  // so lay_organic_draft, lay_organic_preview) copies it the same way, so the ask's value alone lays the floor.
  double bed_floor_mm = 0.0;
  // L1 (brief G14), Grade to shape as a variable: O13's outline cap is (2 / shape_reach) x steps x the grid step (the
  // owner, 2026-11-16: "Should this be considered a 'Grade to shape' and make it a variable?"). 1 = as before; 2 = the
  // small cells reach twice as far in from every face; 0 = no outline cap at all. 0 or above.
  double shape_reach = 1.0;
  // L2 (brief G14), Detect floating parts (the owner: "detect parts of the MODEL ... which, without anything holding them
  // up, would be floating in mid-air"): per Grown area, the undersides of solid that hangs over its lattice are found
  // (OrganicSpacing::hold_patches), every candidate within part_reach_mm of them takes the tightest spacing, the feet
  // and wall roots there are never thinned (Grower), and supports are grown down from them (hold_up_weave). Off: as
  // before. part_reach_mm 0 or above. Q3 (brief G24): Traced too: the zone (organic_spacing is the spacing the tracer
  // is given, so part_reach_mm tightens it there on purpose) and the same supports (hold_up_weave over the traced
  // strands' bars); the feet and wall roots rule is the Grower's own and has no Traced twin.
  bool hold_parts = false;
  double part_reach_mm = 8.0;
  // (brief G15, heavier; the owner: "ok. Go for that.") part_support_mm: above 0, the least distance between support
  // points on a piece's underside (0: spacing_min_mm, as before). part_to_floor: a support passes THROUGH the vine
  // vertices it reaches (a joint each) and ends only on the part's solid or the area's floor; leaving the area or
  // running more than twice the area's depth ends it at its last joint, or refuses it with none (false: as before).
  double part_support_mm = 0.0;
  bool part_to_floor = false;
  // M (brief G19; the owner, 2026-11-16: "Could wall seeding be stress based?"): wall_gap_heavy above 0: a wall root's
  // gap is wall_gap + (wall_gap_heavy - wall_gap) x f, f (0 .. 1) O12's own stress measure at its wall point
  // (OrganicSpacing::stress_f, read as sep reads the spacing); so wall_gap where the stress is light, wall_gap_heavy
  // where it is heaviest. 0 or less: off (wall_gap everywhere, as before). Needs wall_gap on, at most wall_gap, and
  // the spacing as a range (O12's measure exists only then). Feet (foot_gap) and L2 c are not changed.
  double wall_gap_heavy = 0.0;
  // N (brief G21, rule M's twin for the crossing vines): a wall seed becomes a crossing vine when no crossing vine
  // already chosen stands within cross_gap x the local spacing of its wall point (2.5: F's gap, as before). Above 0;
  // only with wall_cross on when not 2.5. cross_gap_heavy above 0: the gap there is
  // cross_gap + (cross_gap_heavy - cross_gap) x f, f O12's stress measure at that wall point (as rule M reads it); so
  // cross_gap where the stress is light, cross_gap_heavy where it is heaviest. 0 or less: off. Needs wall_cross on, at
  // most cross_gap, and the spacing as a range. A crossing vine's heading, climb, ties and width are not changed.
  double cross_gap = 2.5;
  double cross_gap_heavy = 0.0;
  // O (brief G22): the steepest a crossing vine climbs, in degrees from level (45: F's limit, as before). From 30 (the
  // cone) to 45; only with wall_cross on when not 45. Nothing else about a crossing vine changes.
  double cross_climb_max_deg = 45.0;
  // S8 (brief G28; the owner, 2026-11-17: "Fix the thin links ... the links need a variable in manual"): a link made by
  // the cut at crossings is link_width x the thinner of the two bars it joins, held between the light width and the
  // thicker of the two. 0.5 to 2.0; 1: as thick as the thinner strut. Both Organic modes.
  double link_width = 1.0;
  // T (brief G30; the owner: "Yes, add it"): no strut runs longer than unbraced_max x its thinnest width without a
  // joint (brace_weave). 0: off (as before); 4 to 40. A Manual variable; Auto will use 10.
  double unbraced_max = 0.0;
  // P (brief G23): level ties. tie_level: every transfer tie walks the level part of its direction (not started where
  // that is under 0.2 of the whole), every point at its start's height, welds at that height (a recorded vertex within
  // a quarter layer of it as it is, else the point where the other strand crosses it), ends on its last weld (or in
  // the solid), cut at the joint before the first span over kLevelSpanMax (10 mm), joint to joint straight. Needs
  // ties. tie_gap: a tie starts every tie_gap x the local spacing of a vine's length (1: as before; above 0; only with
  // ties when not 1); tie_gap_heavy above 0: tie_gap + (tie_gap_heavy - tie_gap) x f, f O12's stress measure there
  // (as rule N). 0 or less: off. Needs ties, at most tie_gap, the spacing as a range. The "not within half a spacing
  // of another tie" test scales by the same factor.
  // R (brief G26): Traced too (lay_traced_level_ties), where none of them needs ties (Grown's switch): the ties start on
  // the traced curves only, at points where the curve climbs 30 degrees or more from level, with no swirl.
  bool tie_level = false;
  double tie_gap = 1.0;
  double tie_gap_heavy = 0.0;
  // Brief E2, item 9: the width floors (WidthFloor). Empty: none (as before). The file job, the preview and the
  // strengthen job take them from a strengthened.json (apply_strengthened).
  std::vector<WidthFloor> floors;
  // Brief E3a: what strengthening by adding added (a strengthened.json of version 2), applied after the lay and the
  // floors, each round's hash checked (apply_additions). Empty: none.
  Additions additions;
  // Brief E4, leg 2 (OS16): with additions, the file's print check (print_check_hook, lattice_layout_file.hpp), run
  // after the lay and the floors and after each round's operations, before that round's hash is checked: its bars
  // replace the bars (a sag lifted, a leg laid). Empty: none (the additions are applied to the bars as laid). A non-empty
  // answer is a refusal (Outcome::additions_refused). The file job and the preview's Exact set it.
  std::function<std::string(const Layout&, Bars&)> print_check;
  // OP6 (brief C1; the owner, 2026-11-18: "It should be a choice between stress and shape gradient or shape gradient
  // alone."). true (the default): as before. false, "shape only": O12's stress shares are 0 everywhere for every SIZE
  // rule: f (organic_spacing gives every candidate the widest spacing, spacing_max_mm, before O13's shape fit and L2;
  // stress_f 0) and u (its reference_mpa is 0, so the width's heavy end (I1, Q2, T's widths), the three gaps' heavy ends
  // (M, N, P) and Auto's runs per end (I) all read 0). The DIRECTIONS still come from the stress field (Traced's
  // curves, Grown's heading) and are not changed by it.
  bool follow_stress = true;
  // OG1 (brief E6; the owner, 2026-11-19: "Yes, build it"), the gap rule: gap = gap_lines x the line width (bead_mm). At
  // every point of a traced or grown strand the width is at most (the local spacing there - gap), never under the
  // thinnest strut; it caps the by-stress heavy width and never widens anything. 0 = off (as before); 0 to 4.
  // validate_organic refuses a cell size whose small end is under (the light width + gap).
  double gap_lines = 1.5;
  // OG2 (brief E6; the owner: "add material beyond the flat plane ... no more than 1mm variability in depth"): a weave
  // bar's Surface end on an open face, where the face is not in relief_exclude_faces, its outward normal points down
  // against build_dir by no more than 45 degrees, and the end is more than 2 mm above the bed, is carried on along its
  // bar until it stands p beyond the surface (along the normal), p = face_relief_mm x a number 0 .. 1 fixed by its
  // strand and region. 0 = off (every end flush, as before); 0 to 1 (default 1, "Default is not flush"). The owner,
  // 2026-11-19: "Let's just make it a single "on/off" that limits to 1mm" (the app's switch: on 1, off 0); the 5 mm
  // ceiling of earlier that day is withdrawn. relief_exclude_faces: the part's face ids (the
  // app: loaded and fixed faces) where no end stands proud.
  double face_relief_mm = 1.0;
  std::vector<int> relief_exclude_faces;
  // OG3 (brief E6, leg D), Traced: no point of a traced curve is laid closer than strand_keep x the local spacing,
  // centre line to centre line, to a curve of the same direction family it does not end on; a curve that comes that
  // close ENDS there (the tracer's d_test, OrganicParams::test_ratio) and joins by the existing rules. Seeding stays at
  // the spacing; the thinning test stays at the tracer's 0.5. 0.5 to 1; 0.5 = the tracer's old constant
  // (kOrganicTestRatio), the old lay bar for bar. Grown does not read it.
  double strand_keep = 0.9;
};
inline constexpr double kOrganicStrandKeepDefault = 0.9;   // OG3
inline constexpr double kOrganicGapLinesDefault = 1.5;   // OG1
inline constexpr double kOrganicGapLinesMax = 4.0;
inline constexpr double kOrganicReliefMaxMm = 1.0;       // OG2 (the owner, 2026-11-19: on/off, "limits to 1mm")

// OG1: the strand points' local spacing and its reason, and (gap above 0) the cap: for each strand of `strands` from
// `first` on, each point's local spacing is `spacing` (per voxel of `field`'s grid, 0 off the candidates) at its voxel,
// else the smallest non-zero of the 26 around it, else the strand's own spacing_mm (reason None); `why` (per voxel,
// SpacingWhy) its reason. With gap_mm above 0: cap = max(thinnest_mm, local - gap_mm), every width over it set to it
// (Strand::cap_mm filled). Returns the points whose width was lowered.
std::size_t organic_gap_cap(std::vector<Strand>& strands, std::size_t first, const TensorField& field,
                            const std::vector<double>& spacing, const std::vector<std::uint8_t>& why, double gap_mm,
                            double thinnest_mm);
// OG1: the weave bars whose width is over their gap cap (Bar::gap_cap_mm above 0): what the strength loop's widening
// (additive widening, the width floors) broke of the gap rule. Never silent: each round says it.
std::size_t gap_broken(const Bars& bars);

// Brief E2, item 9: the floors on laid bars (Session::lay_organic calls it last). Every non-link bar whose middle lies
// in a floor's ball: w = max(w, min(floor, upper_mm)); then every link: S8's width from the struts at its two ends
// (link_width x the thinner, between light_mm and the thicker), where that is wider than it is. Returns the bars
// widened; `links`, when given, the links widened.
std::size_t apply_width_floors(Bars& bars, const std::vector<WidthFloor>& floors, double upper_mm, double light_mm,
                               double link_width, std::size_t* links = nullptr);

// Brief E2, items 10 and 11: the files a strengthen round writes.
// The floors file, little-endian: 8 bytes "TOFLOORS", int32 version (1), int32 count, then per floor five float64:
// centre x, y, z, radius mm, width mm.
bool write_floors_file(const std::string& path, const std::vector<WidthFloor>& floors);
bool read_floors_file(const std::string& path, std::vector<WidthFloor>& floors, std::string* why = nullptr);
// strengthened.json: {"version": 1, "stress_input": NAME, "floors": NAME, "reference_mpa": X, ...}; the two names are
// files beside it. `reference_mpa` is the reference the engine resolved for the ORIGINAL stress input, written with 17
// digits so that it reads back as the same double.
struct Strengthened {
  std::string stress_input, floors;   // file names, beside the strengthened.json
  double reference_mpa = 0.0;
  // Brief E3a: version 2, the additive mode: {"version": 2, "mode": "additive", "additions": NAME, ...}; the job's own
  // stress input and floors are kept, and the additions file (beside it) is applied after the lay.
  int version = 1;
  std::string additions;
};
bool write_strengthened_file(const std::string& path, const Strengthened& s, const std::string& more_json = {});
// The job key "strengthened" (file job and preview alike): reads it, replaces `field` with its stress input, states
// its reference in `ask` and adds its floors to `ask`. False (with `why`) when anything cannot be read.
// Version 2 (brief E3a): `field` is left as it is; `ask.additions` takes the additions file's list.
bool apply_strengthened(const std::string& path, TensorField& field, OrganicAsk& ask, std::string* why = nullptr);

// Brief E3a. The bars' hash: FNV-1a (64 bits) over every bar in order: its ends and width (their IEEE bits), its end
// kinds, strand, region and flags (link, brace, net, skin, support, level_tie). Two lays are the same lattice, bar for
// bar, exactly when their hashes agree (to a 64-bit hash's chance).
std::uint64_t bars_hash(const Bars& bars);
// The numbers additions are applied with: the job's light width (S), layer and link width (S8).
struct AddContext {
  double light_mm = 0.0, layer_mm = 0.2, link_width = 1.0;
  // OG5 (brief E9): with `line_mm` above 0, apply_additions guards each round's bars (guard_bars) after its operations,
  // before its print check and hash; the strengthen job does the same after a round's two steps.
  std::vector<int> weave_regions;
  double line_mm = 0.0;
  GuardReport* guard = nullptr;
};
struct AddReport {
  std::size_t brace_points = 0, braces = 0, widened = 0, links_widened = 0;
  std::size_t relief_vines = 0, relief_bars = 0;   // OS18 (brief E8): kind 3
  std::vector<int> braces_at;   // per brace point of the round, in op order: braces laid there
};
// One round's operations on `bars` (no hash check). False (with `why`) when an operation names a bar the lattice does
// not hold, or is of a kind this engine does not know.
bool apply_add_round(Bars& bars, const Domain& domain, const AddRound& round, const AddContext& c, AddReport* report = nullptr,
                     std::string* why = nullptr);
// Every round in order, each round's hash checked. False (with `why`) at the first that fails.
// Rule OG5 (brief E9; the owner, 2026-11-19: "That CAN'T happen"): every bar of a weave (every kind: strands, links,
// ties, net-skin bars, braces, supports, relief vines) keeps its centre line in the part (1e-3 mm), and lies in solid
// only as an END run-on entered from the lattice, at most min(its width, the solid's thickness along it there less its
// radius less `line_mm`), never under 0 and never mid-bar (and, in a Protect skin, never with its tube within `line_mm`
// of the part's surface): a bar through solid is cut into its lattice parts (each
// ended by that rule), a bar wholly out of the lattice is removed. OG2's relief at an open face is not judged. A new
// end lying in solid is Solid, else Surface; drop_loose_bars and drop_adrift_bars follow it at the lay. Returns the
// bars cut or removed; `report` gathers them.
std::size_t guard_bars(Bars& bars, const Domain& domain, const std::vector<int>& weave_regions, double line_mm,
                       GuardReport* report = nullptr);
// OG5 at source: how far a weave bar entering solid at `entry`, going `dir`, runs on into it: min(its width (S11), the
// solid's thickness along `dir` there less its radius less `line_mm`), never under 0.
double solid_run_on(const Domain::Probe& probe, const Vec3& entry, const Vec3& dir, double width, double line_mm);
// `between`, when given: run after each round's operations, before its hash (OS16); a non-empty answer refuses.
bool apply_additions(Bars& bars, const Domain& domain, const Additions& adds, const AddContext& c, std::string* why = nullptr,
                     const std::function<std::string(Bars&)>& between = {});
// OS18 (amended 2026-11-19, the owner: "Yes, build it that way"): the TWIN VINE maker (one for Traced and Grown). Built
// once on the bars of a round (a 2 mm grid of them). make() for one weak STRETCH: its centre line `line` from joint J0
// to joint Jn (every vertex, in order), its region, the stretch's width and the twin's, the local spacing, and the sides
// a twin already took for any of its struts (`avoid`). The twin leaves J0, reaches the sideways offset
// s = (stretch width + twin width) / 2 + gap over a lead of 2 s along the stretch, keeps that offset parallel to the
// stretch's centre line, and returns to Jn the same way: its end points are EXACTLY J0 and Jn. The side: the two
// principal stress directions across the stretch at its middle (the field's voxel there), both senses, the most free
// room first, one side for the whole stretch (a side within 45 degrees of one in `avoid` is not tried). A bar ending on
// the stretch between J0 and Jn (a cross vine, or a brace) that leaves toward the twin's side (its direction's share
// along the offset over 0.3) is JOINED: the twin passes through the point of that bar at the offset (the crossing cut
// then makes the joint); every other bar not ending at J0 or Jn and not on the stretch must stay at least the gap
// away, surface to surface (read every 0.1 mm). Every point (but within a width of J0 and Jn) lies in the region's
// lattice. A stretch shorter than 4 s: no_room "too_short"; no side passes: "no_free_side" (a bar within the gap) or
// "outside_lattice". The op is kind 3 (region, width, cell, Node ends, points).
struct TwinAsk {
  double gap_mm = 0.675;          // OG1's gap (one line width with the gap rule off)
};
struct TwinVine {
  bool laid = false;
  std::string no_room;            // "too_short", "no_free_side", "outside_lattice" (not laid)
  Vec3 mid{};                     // the stretch's middle (its place)
  Vec3 side{};                    // the side taken (unit)
  std::vector<Vec3> points;
  std::size_t sides_tried = 0, cross_joined = 0;
  double offset_mm = 0.0;
  AddOp op;                       // kind 3, when laid
};
class TwinVineMaker {
 public:
  TwinVineMaker(const Bars& bars, const Domain& domain, const TensorField& field, const TwinAsk& ask);
  TwinVine make(const std::vector<Vec3>& line, int region, double stretch_width, double width, double spacing,
                const std::vector<Vec3>& avoid) const;
 private:
  const Bars& bars_;
  const Domain& domain_;
  const TensorField& field_;
  TwinAsk ask_;
  std::map<std::array<long long, 3>, std::vector<std::size_t>> grid_;
};

// The additions file, little-endian: 8 bytes "TOADDS\0\0", int32 version (1), int32 rounds; per round: uint64 hash,
// int32 operations; per operation: int32 kind, int32 count, count float64.
bool write_additions_file(const std::string& path, const Additions& adds);
bool read_additions_file(const std::string& path, Additions& adds, std::string* why = nullptr);
// The old-bar invariant (OS12): every bar of `before` is in `after` whole, or as pieces lying on its line (each end
// within tol_mm of it) that cover it end to end, of its strand and never thinner; links may only widen. "" when it
// holds, else what broke first; `split`, when given: the old bars found cut into pieces.
// The bars of `after` lying on each bar of `olds` (both ends within tol_mm of it, of its strand and link kind, longer
// than tol_mm), in list order: where an old bar went when bars were cut.
std::vector<std::vector<std::size_t>> pieces_on(const Bars& after, const std::vector<Bar>& olds, double tol_mm = 1e-5);
std::string old_bars_kept(const Bars& before, const Bars& after, double tol_mm = 1e-5, std::size_t* split = nullptr);

// OP11 (brief C2, E7): a group of weave regions and its own ask (Session::lay_organic's group list). The app names
// the groups; the whole part latticed is one group holding every weave region (the one-ask calls mean exactly that).
struct OrganicGroup {
  std::vector<int> regions;   // weave region ids
  OrganicAsk ask;
};
// OP11: validate_organic for a group list: every refusal of each group's ask (validate_organic, field not checked there,
// OrganicRefusal::group its index), then the list's own (group -1 unless said): a weave region of the settings in no
// group (setting "groups", code region_without_group) or in two (region_in_two_groups), a group's region that is not
// a weave region (not_a_weave_region, its group), a group with no region (empty_group, its group); the flat floor,
// one number for the part, differing between groups (bed_floor_mm, floors_differ, the group that differs from the
// first); then, `field` given, the stress input (as validate_organic). Empty: valid.
std::vector<OrganicRefusal> validate_organic_groups(const Settings& settings, const std::vector<OrganicGroup>& groups,
                                                    const TensorField* field = nullptr);
// OP7 (brief C2, E1): every range and rule an Organic ask must keep, in one call, so the file job's parser and the
// session path (Session::lay_organic, lay_organic_draft, lay_organic_preview) refuse exactly the same asks. Returns
// every refusal (empty: the ask is valid), in a fixed order. The rules (the sheet's sections A to D):
//   the cell size: spacing_mm 0 (the range) or above 0; with the range, spacing_min_mm above 0, spacing_max_mm at least
//     it (equal is allowed: one spacing), spacing_exponent above 0; the small end (or the one size) at least the
//     smallest printable cell, kSmallestCellFactor x the light width (OP7, both modes);
//   the struts: the thinnest strut (bead_mm x min_strut_lines) above 0; width_mm 0 or at least it; width_heavy_mm 0 or
//     at least the light width; link_width 0.5 to 2; unbraced_max 0 or 4 to 40;
//   shape_reach, bed_floor_mm, part_reach_mm, part_support_mm 0 or above; tie_swirl 0 to 1; foot_gap, wall_gap,
//     root_gap numbers; void_ratio above 0; reseed_rounds 0 to 100; wall_cross 0, 1 or 2; cross_gap above 0 (not 2.5
//     only with wall_cross); cross_climb_max_deg 30 to 45 (not 45 only with wall_cross); tie_gap above 0; top_run,
//     root_run, run_gap, run_pull, run_seek, run_min 0 or above; run_max 1 to 1,000,000; run_follow above 0;
//     build_dir not zero; layer_mm and seed_stride above 0;
//   the three heavy gaps: 0 or less is off; above 0 at most their light gap, and needs the cell size as a range
//     (spacing_mm 0; OP8: its two ends may be equal, the heavy ends then do not act); wall_gap_heavy needs wall_gap above 0; cross_gap_heavy needs wall_cross;
//   Grown only (as the Grower reads them): wall_cross needs walls_out and not wall_connect; tie_level, tie_gap not 1 and
//     tie_gap_heavy above 0 need ties;
//   `field` given (the session path): a weave region in `settings` and an empty field is refused (setting "stress").
//     Null (the file job, whose own refusal for it is no_stress_result): not checked.
// Every text is one plain sentence for the owner, naming the control and the number allowed, no key names.
// OP8 (brief C2, E2): the note Outcome::notes carries when the cell size's two ends are equal and a heavy end is set.
inline constexpr const char* kNoteEqualEnds =
    "The cell size has one value, so the thick end of the strut thickness and the heavy ends of the gaps do nothing.";
inline constexpr double kSmallestCellFactor = 1.5349900619197328;   // 0.5 x sqrt(3 pi): the tracer's print floor
double organic_smallest_cell_mm(const Settings& settings, const OrganicAsk& ask);   // kSmallestCellFactor x light
std::vector<OrganicRefusal> validate_organic(const Settings& settings, const OrganicAsk& ask,
                                             const TensorField* field = nullptr);

// J2 (brief G12), the pruning of a Grown area's weave bars, for each (region, median asked spacing) of `areas`:
//   J2a, no end in the air: a weave bar (not a net strut) of the area with an end that is not Solid, not Surface, and not
//     at a joint (a Node or Loose end: another kept bar ends at the same point, as drop_loose_bars reads a node; a
//     Joined end: the bar it ends in is kept) is removed; repeated until there is none, so a strand is cut back to its
//     last joint and a bar with no joint at either end goes whole.
//   J2b, no small separate piece: the area's kept bars (net struts too) fall into pieces: bars sharing an end point
//     (not when both bars end Solid there), a Joined end and the bar it ends in, an end lying within half the other
//     bar's width of it. Every piece but the largest is removed when its bars' length is under 20 x the area's median.
// Returns the counts per area (in the order of `areas`).
struct PruneCount {
  int region = 0;
  std::size_t ends_cut = 0;        // J2a: bars removed in the first round (each an end in the air)
  std::size_t bars_cut = 0;        // J2a: bars removed in all
  double cut_mm = 0.0;
  std::size_t pieces_removed = 0;  // J2b
  double removed_mm = 0.0;
  std::size_t pieces_apart = 0;    // J2b: pieces kept apart from the largest (20 x the median or more)
  double apart_mm = 0.0;
  std::size_t supports_cut = 0;          // L2: support bars J2a removed (an end not Solid, not Surface, not at a joint)
  std::size_t pieces_held_by_support = 0;   // L2: pieces J2b would have removed but kept, as they hold a support bar
  double held_by_support_mm = 0.0;
};
std::vector<PruneCount> prune_weave(Bars& bars, const std::vector<std::pair<int, double>>& areas);

// L2 d, e (brief G14): supports from the undersides of floating parts, on the weave bars after the growth and J2 (the
// Grower's strands are bars by then: a "kept strand" is a kept weave bar of the area that is not a net strut, its
// "vertices" the bars' ends, "a strand that ends in the solid" a bar end tagged Solid). Per patch of `area`:
// support points = the patch's bottoms, lowest first then by x, y, kept when at least spacing_min_mm from every point
// kept before (at least one). A point is already held when a kept bar's Solid end lies within 0.5 x spacing_min_mm of
// it. Otherwise a support walks DOWN from it one layer (layer_mm) at a time, leaning each step at most one layer
// sideways toward the nearest kept bar end below it inside the 45 degree cone (straight down with none). It ends on the
// first of: a kept bar end within that bar's width (the support ends exactly there: a joint, end Node), the part's solid
// (BedFloor: on the floor; any other solid: on solid). Refused when a step leaves the part (air) or enters another
// region's lattice ("left the area"), or the walk is longer than the region's depth (Region prism depth, or the shell
// depth). A kept support is one strand (points from its lower end up, the top one width into the solid above the
// point, the light width, not a tie) laid by weave_bars, its bars given a new strand number. Its ends: Solid where it
// enters solid, Node on a bar end.
struct HoldPatchCount {
  int region = 0;
  Vec3 lo{}, hi{};
  double plan_mm2 = 0.0;
  std::size_t points = 0, held = 0, on_vine = 0, on_solid = 0, on_floor = 0, refused_air = 0, refused_long = 0;
  double mm = 0.0;
  std::size_t ends_before = 0, ends_after = 0;   // kept weave bar ends tagged Solid under the patch (in its voxel
                                                 // columns, within one grid step of its bottoms' height)
  // The top end of a support: where its top piece (from its last vertex below the solid to the solid) was shorter than
  // its width, weave_bars drops that piece as a stub (S4) and the strand's last vertex is left as a Node with nothing
  // above it. It is then tagged Solid when the solid begins within the support's width + half a grid step above it
  // (`top_retagged`: the mesh runs a Solid end on into the solid by its width), else left (`top_open`).
  std::size_t top_retagged = 0, top_open = 0;
  std::size_t joints = 0;   // part_to_floor: vine vertices kept supports passed through (a fallback's last joint is its end)
  std::size_t bars_laid = 0;
  int strand_lo = -1, strand_hi = -1;   // the strand numbers of this patch's supports: [lo, hi)
};
std::vector<HoldPatchCount> hold_up_weave(Bars& bars, const Domain& domain, const std::vector<WeaveHold>& areas);

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
  // M (brief G19): per voxel, O12's 0 .. 1 stress measure f for a candidate (the f the spacing hi - (hi - lo) x f was
  // made from, before O13 and L2 change the spacing); 0 elsewhere, and 0 everywhere with one spacing.
  std::vector<double> stress_f;
  // OG1 (brief E6): per voxel, what set a candidate's spacing (SpacingWhy: Uniform, Stress, Shape, Hold; the last of
  // O12, O13, L2 that changed it); 0 (None) elsewhere.
  std::vector<std::uint8_t> why;
  // L2 a, b (OrganicAsk::hold_parts; all empty or 0 when off; brief G15). The FLOATING PIECES of the part, found layer
  // by layer from the bed on the field's grid (see organic_spacing): solid voxels not grounded, 26-connected, 20 mm3 or
  // more (smaller ones counted in hold_small_patches). Per kept piece: every voxel's centre, its volume and box; its
  // UNDERSIDE against this region (bottom-face centres of its voxels with a candidate of this region straight below,
  // and their area, plan_mm2) and its SIDES (centres of its voxels with a candidate of this region beside them in the
  // same layer, and their area); the candidates its reach took into the zone, and of them those tightened.
  struct HoldPatch {
    std::vector<Vec3> bottoms, centres, sides;
    double plan_mm2 = 0.0, volume_mm3 = 0.0, side_mm2 = 0.0;
    Vec3 lo{}, hi{};
    std::size_t zone = 0, tightened = 0;
  };
  std::vector<HoldPatch> hold_patches;
  std::size_t hold_small_patches = 0;   // floating pieces under 20 mm3, ignored
  std::vector<Vec3> hold_centres;       // the centres of every voxel of the kept pieces
  double hold_reach_mm = 0.0;           // OrganicAsk::part_reach_mm
  std::size_t hold_zone = 0;            // candidates within the reach of a hanging voxel's centre
  std::size_t hold_tightened = 0;       // of those, the ones whose spacing was above the tightest and was set to it
};
// OP11 (brief C2, E7): `pool`, when given, is the weave for this call in place of every weave region: a GROUP's regions
// (the reference, the g stretch and O13's outline are read over them alone, as if they were the part's only weave).
OrganicSpacing organic_spacing(const Domain& domain, int region, const TensorField& field, const OrganicAsk& ask,
                               const std::vector<int>* pool = nullptr);

// The spacing the tracer actually used, over the candidates of one trace (its spacing_used_mm, which raises the asked
// spacing to its print and resolution floors where they bind); all 0 when nothing was traced.
struct OrganicTraceStats {
  std::size_t candidates = 0;
  double spacing_smallest_mm = 0.0, spacing_largest_mm = 0.0, spacing_mean_mm = 0.0;
  double reference_mpa = 0.0;
  // O16: the trace's own median spacing (its report's achieved_spacing_median_mm): the net skin's reach for Traced, as
  // the old run sets it (Grown reads the spacing field's median instead).
  double spacing_median_mm = 0.0;
  // Q3 (brief G24): with OrganicAsk::hold_parts, the floating pieces O12's spacing found for this region (L2 a; its
  // tight-cell zone, L2 b, is already in the spacing the tracer was given), handed to Session::lay_organic so that
  // hold_up_weave lays Grown's own supports under them over the traced strands. Empty when off.
  std::vector<OrganicSpacing::HoldPatch> hold_patches;
  // R (brief G26), with OrganicAsk::tie_level only: the level ties (lay_traced_level_ties). Start points offered (every
  // tie_gap x sep of a curve's length), of them refused because the curve there climbs under 30 degrees, lay within
  // half a spacing (x the gap) of another tie, or the minor stress is under 0.10 of the major; ties tried (two per
  // start), not started (the level part under 0.2), no weld and no solid end (or one joint), cut at a span over
  // 10 mm, laid; per laid tie its joints, every flat span (mm); the largest height difference within one tie as laid
  // (mm); the weld points put into another strand as a vertex.
  bool tie_level = false;
  std::size_t ties_level_starts = 0, ties_level_refused_flat = 0, ties_level_refused_near = 0,
              ties_level_refused_minor = 0, ties_level_seeded = 0, ties_level_refused_steep = 0,
              ties_level_refused_reach = 0, ties_level_cut_span = 0, ties_level_laid = 0, ties_level_vertices_put = 0;
  std::vector<std::size_t> tie_level_joints;
  std::vector<double> tie_level_span_mm;
  double tie_level_dz_max_mm = 0.0;
  std::size_t gap_capped = 0;   // OG1 (brief E6): strand points whose width the gap rule lowered
  // OG3 (brief E6, leg D): level-tie segments taken out (near-parallel within the gap of a strand they do not join),
  // and those kept.
  std::size_t og3_tie_segments_cut = 0, og3_tie_segments_kept = 0;
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
// OP11 (brief C2, E7): `pool` as organic_spacing's (null: every weave region).
std::vector<Strand> trace_strands(const Domain& domain, int region, const TensorField& field, const OrganicAsk& ask,
                                  OrganicTraceStats* stats = nullptr, const std::vector<int>* pool = nullptr);
// T (brief G30): what brace_weave needs for this job's weave regions: unbraced_max, the light width, the layer, the
// link width, and the braces' width rule (the strands' own: by stress with width_heavy_mm, the share over each
// region's O12 reference, else the light width). Off (unbraced_max 0) when the ask has it off.
// `references`: each weave region's O12 reference (region, MPa), as the region's own spacing computed it ONCE (the
// trace's OrganicTraceStats::reference_mpa, Grown's organic_spacing): nothing is computed again here.
WeaveBraceAsk organic_brace_ask(const Domain& domain, const TensorField& field, const OrganicAsk& ask,
                                const std::vector<std::pair<int, double>>& references);
// R (brief G26), the level ties for Traced (OrganicAsk::tie_level), P's rule by P's own walk (organic_grow.cpp):
// along each of the first `curves` strands of `strands` (the traced curves; the connectors follow them), a start point
// every tie_gap x sep(p) of its length (read every layer; tie_gap_heavy by stress as P), not where the curve there
// climbs under 30 degrees from level, not within half a spacing (x the gap) of another tie, not where the minor stress
// is under 0.10 of the major; from it both ways along the level part of the second principal direction (no swirl),
// every point at its height, welding where another strand's segment (curve or connector, not a tie) crosses that height
// or onto another tie's point at it, ending on its last weld or in the solid, cut at the joint before a span over
// 10 mm, joint to joint straight; 8 spacings at most. sep and stress_f are the Grower's (`sp`, organic_spacing's answer
// for this region). Each tie is appended as a strand (tie true, width `light_mm` at every point, spacing the curve's);
// every tie point that lies on another strand's segment (its start, its welds) is put into that strand as a vertex
// (its width read off the segment's two ends), so each is a joint in the bars. Throws std::invalid_argument for a
// tie_gap not above 0, a tie_gap_heavy above tie_gap, or tie_gap_heavy on without the spacing as a range.
void lay_traced_level_ties(const Domain& domain, int region, const TensorField& field, const OrganicAsk& ask,
                           const OrganicSpacing& sp, std::size_t curves, double light_mm, std::vector<Strand>& strands,
                           OrganicTraceStats* stats);

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
  // G, top_run: strands that ended at the top; runs made, by how they ended (welded to a strand, welded to another
  // run, into the solid); refused (no level heading, left into air, out of reach); each run's length (mm).
  std::size_t top_vines = 0, top_runs_vine = 0, top_runs_run = 0, top_runs_solid = 0, top_refused_level = 0,
              top_refused_air = 0, top_refused_reach = 0;
  std::vector<double> top_run_mm;
  std::size_t top_refused_ontop = 0;   // addendum C: a run not started on top of another end's run
  // G (addendum D), roots: made by ending (welded to a strand, to another root, into the solid sideways, dipped into
  // the floor); refused (on top of another end's root, left into air, no solid under its dip, no start on the foot).
  std::size_t root_feet = 0, root_runs_vine = 0, root_runs_run = 0, root_runs_solid = 0, root_runs_dip = 0,
              root_refused_ontop = 0, root_refused_air = 0, root_refused_nofloor = 0, root_refused_nostart = 0;
  std::vector<double> root_run_mm;
  // the spread of n: how many ends drew 1, 2, ... runs (index n)
  std::vector<std::size_t> top_n, root_n;
  // H (brief G9): steps on a followable direction, on the magnet, with no target; runs that used the magnet at least
  // once (top runs, roots).
  std::size_t top_steps_follow = 0, top_steps_magnet = 0, top_steps_none = 0, top_runs_magnet = 0;
  std::size_t root_steps_follow = 0, root_steps_magnet = 0, root_steps_none = 0, root_runs_magnet = 0;
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
  // P (brief G23), with tie_level only: ties not started (the level part under 0.2), ties cut at a span over 10 mm;
  // per laid level tie its joints (start, welds, solid end); every flat span between two joints (mm); the largest
  // height difference between two points of one level tie as the growth ends (mm), over all its points and over its
  // points that are not a recorded vertex used as it is (those may lie up to a quarter layer off).
  bool tie_level = false;
  std::size_t ties_level_refused_steep = 0, ties_level_cut_span = 0;
  // P (the lead's ruling, 2026-11-18): level ties removed by the repeat merge, their end having no point at their own
  // height to move to (a level tie is never left off level).
  std::size_t ties_level_removed = 0;
  std::vector<std::size_t> tie_level_joints;
  std::vector<double> tie_level_span_mm;
  double tie_level_dz_max_mm = 0.0, tie_level_dz_max_unsnapped_mm = 0.0;
  // G13, the feet (floor seeds' strands) after the first pruning: kept; removed, cut from the floor up to their first
  // joint that holds with another plant's strand; removed whole (no such joint); the length those cuts took, with what
  // hung only on a vine removed whole (counted, in the lengths below, under "leads to nothing").
  std::size_t feet_kept = 0, feet_cut_at_joint = 0, vines_removed = 0;
  // L2 c (brief G14): feet and wall roots within OrganicSpacing::hold_reach_mm of a hanging voxel's centre, kept though
  // another kept one stood within the gap (they would have been removed).
  std::size_t hold_feet_kept = 0, hold_wall_roots_kept = 0;
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
  // M (brief G19): per area, its wall roots that competed by third of O12's measure f at the wall point (light: f
  // under 1/3, middle, heavy: 2/3 and up), and of them those kept with rule M off (wall_gap everywhere) and as run
  // (on when wall_gap_heavy is above 0; then equal to kept_off when off). Only with wall_gap on.
  struct WallThirds {
    int region = 0;
    std::size_t roots[3] = {0, 0, 0}, kept_off[3] = {0, 0, 0}, kept_on[3] = {0, 0, 0};
  };
  std::vector<WallThirds> wall_thirds;
  // N (brief G21): per area, the crossing vines chosen (seeded) by third of O12's measure f at the wall point (light,
  // middle, heavy as for wall_thirds) and their total. Only with wall_cross on.
  struct CrossThirds {
    int region = 0;
    std::size_t seeded[3] = {0, 0, 0}, total = 0;
  };
  std::vector<CrossThirds> cross_thirds;
  std::size_t gap_capped = 0;   // OG1 (brief E6): strand points whose width the gap rule lowered
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
// T fix (brief G30): `spacing`, when given, is organic_spacing(domain, region, field, ask) computed once by the
// caller (Session::lay_organic); the growth then reads it instead of computing it again. The result is the same.
std::vector<Strand> grow_strands(const Domain& domain, int region, const TensorField& field, const OrganicAsk& ask,
                                 GrowReport* report = nullptr, const OrganicSpacing* spacing = nullptr);

// G3 and G16a alone, exposed for tests: the unit direction of the pull ("the light") at `p`, as grow_strands sets it up
// for `region` (the build direction where there is no pull); the build direction for an empty field or no candidate.
Vec3 grown_light(const Domain& domain, int region, const TensorField& field, const OrganicAsk& ask, const Vec3& p);

// O3 alone, exposed for tests: the fewest of the strand's points that keep each of its points within `tolerance_mm`
// of the line through the kept ones, both ends kept (the first of several equally short answers, by index).
std::vector<std::size_t> straighten_points(const std::vector<Vec3>& points, double tolerance_mm);

// ── ORGANIC PREVIEW (brief L2, items 2 to 4; organic_preview.cpp) ─────────────────────────────────────────────────
// Item 2, RUNS: the lattice of the weave regions handed over as polylines. Bars are read in list order; a bar continues
// the run before it when it is not a link, is of a weave region, has the same strand number, region and marks, and its
// first end is the run's last point (within 1e-6 mm): consecutive bars of one strand joined end to end are one run, so
// the cut at crossings' splits are undone. `link` bars are left out. A strand that branches, or is broken (by the
// dropping, or by a bar of another strand between), gives several runs. Per point: its place, its width (at a joint the
// mean of the two bars' widths, at an end its bar's) and its local spacing (the bar's `cell`, the strand's spacing).
// Thinning to `tolerance_mm` (0 or less: none): a point is dropped when every original point between the kept ones lies
// within the tolerance of the kept segment and its width within 5 % of the width interpolated there (by length); a
// run's two ends are always kept, and a run's marks never change along it (a mark change starts a new run).
// kRunAlong (leg H): the run lies along an allowed open face (its bars have Bar::along_proud: OG2b keeps their bulge),
// set only when weave_runs is asked for it (`relief_marks`, the preview); the bit 16 was held for the cancelled band
// (OG4), which nothing shipped reads.
enum WeaveRunMark : std::uint8_t { kRunLevelTie = 1, kRunBrace = 2, kRunSupport = 4, kRunNet = 8, kRunAlong = 16 };
struct WeaveRun {
  int region = 0;
  std::uint8_t marks = 0;                          // WeaveRunMark bits
  Bar::End end_a = Bar::End::Node, end_b = Bar::End::Node;   // the kinds of its two ends (its first and last bar's)
  std::vector<Vec3> points;
  std::vector<double> width_mm, spacing_mm;       // one per point
  // OG2b (brief E6, leg B): how far the run's tube may stand out where it runs along an open face (the largest
  // Bar::along_proud of its bars). Packed in version 2 only.
  double proud_mm = 0.0;
  // Leg H: how far each end stands proud of the open face (OG2: its first bar's proud_a when end_a is Surface, its last
  // bar's proud_b when end_b is), 0 when flush; and the model face the run lies along (the first of its bars with
  // Bar::along_face; -1 when none or the model has no faces). Packed in version 2 only.
  double proud_a_mm = 0.0, proud_b_mm = 0.0;
  int along_face = -1;
};
// `bar_of`, when given (OF2, the file's tubes): per run, the place in `bars` of the bar each of its segments came from
// (read with no thinning, `tolerance_mm` 0; with thinning it is left empty).
// `relief_marks` (leg H, the preview): a run also ends where its bars start or stop lying along an open face or change the
// face they lie along, and carries kRunAlong there. Off (the file's tubes, and every caller before): as before.
std::vector<WeaveRun> weave_runs(const Bars& bars, const std::vector<int>& weave_regions, double tolerance_mm = 0.1,
                                 std::vector<std::vector<std::size_t>>* bar_of = nullptr, bool relief_marks = false);
// The runs packed for the app, little-endian.
// Version 1 (the shipped reader's): per run 12 bytes (point count u32, region i32, marks u8, end_a u8, end_b u8
// (Bar::End), one pad byte), then 20 bytes per point (x, y, z, width, spacing as float32).
// Version 2 (leg H): first 8 bytes, "WRN2" and u32 2; then per run 28 bytes (point count u32, region i32, marks u8,
// end_a u8, end_b u8, a pad byte, proud_a_mm f32, proud_b_mm f32, along_face i32, proud_mm f32), then the same 20 bytes
// per point. The version 1 reader given version 2 reads "WRN2" as a point count of 843,993,687 and returns nil (the
// bytes do not add up): it refuses, it never misdraws.
std::vector<std::uint8_t> pack_weave_runs(const std::vector<WeaveRun>& runs, int version = 1);

// Item 3, two qualities of an Organic lay for the preview. Exact: Session::lay_organic as it is (the picture is what
// will be made), then the runs. Draft (for dragging a slider; NOT what will be made): the same trace or growth, then
// the weave's bars with no cut at crossings (so no links), no joining of loose ends, no merging of repeats, nothing
// dropped (loose bars, pieces adrift, the J2 pruning); the braces laid on the uncut bars, the supports and the net skin
// as they come. A job with cell regions too: their bars are laid, not joined and not dropped either.
enum class PreviewQuality : std::uint8_t { Exact, Draft };
struct OrganicPreviewAsk {
  PreviewQuality quality = PreviewQuality::Exact;
  double tolerance_mm = 0.1;   // the runs' thinning (item 2)
};
struct OrganicPreview {
  PreviewQuality quality = PreviewQuality::Exact;   // what was laid: say it on screen when Draft
  Outcome outcome;                                   // the lay itself (its bars, counts, Grown's report)
  std::vector<WeaveRun> runs;                        // the weave regions' runs (item 2)
};
OrganicPreview lay_organic_preview(Session& session, const Settings& settings, const TensorField& field,
                                   const OrganicAsk& ask, const OrganicPreviewAsk& preview, int threads = 0,
                                   const std::atomic<bool>* stop = nullptr);
// OP11 (brief C2, E7): the same with a group list (Session::lay_organic's groups). weave_runs needs no change: every
// bar carries its region, and a run never crosses regions.
OrganicPreview lay_organic_preview(Session& session, const Settings& settings, const TensorField& field,
                                   const std::vector<OrganicGroup>& groups, const OrganicPreviewAsk& preview,
                                   int threads = 0, const std::atomic<bool>* stop = nullptr);

// Item 4, the Auto Sweep limits (the app's fields), per weave region of the domain. D = the smaller of the region's
// depth and the narrowest width of its mouth outline in its own plane (the least width over all directions: the convex
// outline's narrowest caliper, not an axis box). With `line_mm` the print line width: strut lower = max(2 lines,
// D x kSweepStrutLower), upper = max(lower, D x kSweepStrutUpper), both rounded to whole lines; cell lower =
// D x kSweepCellLower, upper = D x kSweepCellUpper, rounded to the nearest 0.5 mm and never under the engine's smallest
// printable Organic spacing (the tracer's print floor, t x sqrt(3 pi) / 2, t the thinnest strut: 2 lines); Auto = the middle of each range, same rounding.
// A region the weave cannot be measured on this way (a curved shell, or no outline): `measured` false, all 0.
inline constexpr double kSweepStrutLower = 1.0 / 20.0;
inline constexpr double kSweepStrutUpper = 1.0 / 10.0;
inline constexpr double kSweepCellLower = 1.0 / 9.0;
inline constexpr double kSweepCellUpper = 4.0 / 9.0;
struct SweepLimits {
  int region = 0;
  bool measured = false;
  double d_mm = 0.0, depth_mm = 0.0, mouth_width_mm = 0.0;
  double strut_lower_mm = 0.0, strut_upper_mm = 0.0, strut_auto_mm = 0.0;
  double cell_lower_mm = 0.0, cell_upper_mm = 0.0, cell_auto_mm = 0.0;
  // OG1 (brief E6): the gap (gap_lines x the line) and the cell size it allows with the limits' thin strut (strut lower
  // + gap, rounded UP to 0.5 mm); the cell's lower end is at least it (its upper end then at least the lower), and
  // cell_lower_by_gap says the rule raised it. 0 / false with gap_lines 0.
  double gap_mm = 0.0, gap_cell_mm = 0.0;
  bool cell_lower_by_gap = false;
};
std::vector<SweepLimits> organic_sweep_limits(const Domain& domain, double line_mm,
                                              double gap_lines = kOrganicGapLinesDefault);
// OP10 (brief C2, E4, made per group by E7): Session::sweep_limits_for(settings, region ids, line_mm), the Auto Sweep
// limits of a GROUP of weave regions (the whole part: every weave region's id): the union over the MEASURED regions
// among those given (organic_sweep_limits' entries): cell lower = the smallest lower, upper = the largest upper; strut
// the same; Auto = the middle of each, by the same rounding (whole lines; the nearest 0.5 mm, never under the smallest
// printable cell). `measured_regions` / `unmeasured` list the ids given that were / were not measured (a curved shell,
// no outline, or not a weave region the domain built). `measured` false (every number 0) when none was.
struct SweepLimitsUnion {
  bool measured = false;
  std::vector<int> measured_regions, unmeasured;
  double strut_lower_mm = 0.0, strut_upper_mm = 0.0, strut_auto_mm = 0.0;
  double cell_lower_mm = 0.0, cell_upper_mm = 0.0, cell_auto_mm = 0.0;
  // OG1: as SweepLimits: the gap, and whether it raised the cell's lower end of any region taken.
  double gap_mm = 0.0;
  bool cell_lower_by_gap = false;
};

// ── OP12 (brief C2, E5; organic_synthetic.cpp): synthetic stress for the new engine ─────────────────────────────────
// The owner: "Simulate stresses on unstressed walls" (Organic and Aesthetic only, a Number of foci per wall, 1 to 5)
// and the samples that show ONE stress focus on a body with no solve. One call that takes the stress input and returns
// it filled, with a report; the caller sets the filled field as the lay's tensor.
//   `in` EMPTY (no solve): the field is made on a grid over the part's box, its voxel half the smallest spacing asked
//     (over the groups' asks: spacing_mm, else spacing_min_mm), never over voxel_max_mm (1 mm); every weave region is
//     without stress and filled, with its wall's count or kSyntheticFociDefault.
//   Otherwise: only the regions listed in `walls` are considered. A voxel belongs to a weave region when its centre is
//     lattice of it (as the spacing reads it). peak = the largest von Mises over every weave voxel; a listed region is
//     WITHOUT STRESS when the 99th percentile of its von Mises (sorted, index round(0.99 (n - 1))) is at or under
//     max(dead_fraction x peak, dead_floor_mpa) (the old rule, his ruling of 2026-09-07). A region with stress is left
//     untouched (reported so).
//   Foci (as the old engine places them): the region's box over its voxel centres, its two largest extents (axes a1,
//     a2, half sizes h1, h2); focus q of n at angle 2 pi q / n + angle0_rad on the ellipse of `ellipse` (80 %) of h1, h2
//     round the box centre (the third axis at the centre); weights alternate +1 (pull), -1 (push); soft = soft_fraction
//     (a quarter) of the largest extent.
//   The field (the lead's ruling: three distinct principal stresses, the minor at least 0.10 of the major for ties): at
//     each voxel, for each focus, r the unit vector from it, t1 = unit(build direction x r) (any unit vector across r
//     where that is zero), t2 = r x t1, g = w / (L^2 + soft^2): T += g (radial r r^T + across_build t1 t1^T +
//     across_other t2 t2^T), the factors 1, -0.30, 0.12. The build direction is the region's group's ask's.
//   Magnitude (the lead's ruling, confirmed by the owner: "Absolutely right. Full range"; it differs from the old engine
//     on purpose): one factor per region so that its largest synthetic von Mises equals the reference its GROUP's lay
//     will use for the real field: the group's stated reference_mpa, else its `percentile` of the real von Mises over
//     the group's regions that HAVE stress; when none has (or `in` is empty), 1 MPa. The region's real values are
//     replaced whole (a voxel whose T is zero keeps its value).
//   Refused (E1's list, nothing made): a count not a whole number 1 to 5 (setting "foci"), a region that is not a weave
//     region (setting "region").
inline constexpr int kSyntheticFociDefault = 3;   // the owner, 2026-11-18: "Change the default to 3" (the OLD run keeps 4)
inline constexpr int kSyntheticFociMin = 1, kSyntheticFociMax = 5;
struct SyntheticStressAsk {
  double dead_fraction = 0.02, dead_floor_mpa = 0.005;           // K2, the old run's numbers
  double radial = 1.0, across_build = -0.30, across_other = 0.12;  // the field's three factors
  double ellipse = 0.80, angle0_rad = 0.35, soft_fraction = 0.25;  // the old placing of the foci
  double voxel_max_mm = 1.0;                                       // the made grid's largest voxel (no input)
};
struct SyntheticWall {
  int region = 0;
  int foci = kSyntheticFociDefault;   // 1 to 5; a wall that gives no count keeps the default
};
struct SyntheticRegionReport {
  int region = 0, group = -1;      // its group's index in the list given (-1: in none)
  bool flagged = false;            // listed in `walls` (every weave region with no input)
  bool without_stress = false;
  double p99_mpa = 0.0, threshold_mpa = 0.0;
  int foci = 0;                    // used (0 when not flagged)
  double soft_mm = 0.0;
  std::size_t voxels = 0, filled = 0;
  double reference_mpa = 0.0, factor = 0.0, peak_after_mpa = 0.0;   // filled only: the target, the factor, the peak
};
struct SyntheticStress {
  TensorField field;               // the input, filled (or the made field)
  std::vector<SyntheticRegionReport> regions;   // every weave region, in the domain's order
  double peak_mpa = 0.0, threshold_mpa = 0.0;   // over the real weave voxels
  bool from_empty = false;
  std::vector<OrganicRefusal> refused;           // not empty: nothing made
};
SyntheticStress organic_synthetic_stress(const Domain& domain, const TensorField& in,
                                         const std::vector<SyntheticWall>& walls,
                                         const std::vector<OrganicGroup>& groups, const SyntheticStressAsk& how = {});
// Bound to the session: the domain the lay will lay in (the settings' "where", with the first group's flat floor as
// Session::lay_organic sets it), made and kept as Session::sweep_limits makes it.
SyntheticStress organic_synthetic_stress(Session& session, const Settings& settings, const TensorField& in,
                                         const std::vector<SyntheticWall>& walls,
                                         const std::vector<OrganicGroup>& groups, const SyntheticStressAsk& how = {});

}  // namespace topopt::lattice_layout
