#pragma once
// ── ANY-STEP STEPPED: the size menu, and the plan a job may state ─────────────
//
// WHAT CHANGED. Stepped used to derive ONE cell per declared region and lay each region
// as an independent pass. The maintainer's ruling (2026-09-17, approved in the preview
// first) extends it: a base slot the face outline CUTS IS PACKED, NOT HALVED. Inside a
// base slot the packer may place cells of several sizes, largest first, and the finest
// tile fills whatever the outline leaves.
//
// ★ THE MENU IS WHAT MAKES THAT DEPTH-CLEAN. For a base cell S the candidate sizes are
// every k*(S/n) for n = 2..kSteppedMaxDivisor and k = 1..n-1, plus S itself. A cell of
// size k*t at the face leaves (n-k)/n of the wall behind it, which the family's own 1/n
// tiles fill EXACTLY -- so no solid strip is ever laid to make up a depth. That is a
// property of the construction, not a repair, and test_stepped_plan asserts it.
//
// ★ AND A FAMILY IS ONLY ADMITTED IF ITS TILE PRINTS OPEN. A tile so small that a
// bead-wide strut fills it is not a lattice, it is a solid block wearing a cell's name.
// The bound is geometry: a bead-wide strut at most kSteppedPrintsOpenMaxStrutPerCell of
// the tile (ruled as octet density 0.20 on 2026-10-10; stated as the ratio it was since
// ruling 2026-11-02 (c)). On a 12 mm base at a 0.45 mm bead the
// fifths print open at 2.4 mm and the sixths at 2.0 mm do not, which is exactly what
// removes the sixths family -- and with it the 10 mm entry, reachable only as 5*(12/6).
//
// NOTE ON THE BOUND, for the structural case: it is an AESTHETIC rule (the quilt's
// finest rung). Under intent: structural the honest lower bound is the printability
// floor together with the certifiable cells-per-member regime, which is a different and
// generally COARSER limit. `min_cell_mm` is how a caller states that floor; the prints-open
// bound is applied on top of it, never instead of it.

#include "topopt/lattice.hpp"  // LatticeTopology
#include "topopt/clearance.hpp"  // ClearanceGeometry, point_in_clearance_region
#include <array>
#include <cstddef>
#include <string>
#include <vector>

#include "topopt/mesh.hpp"   // Vec3

namespace topopt {

// Divisors the packer may use. 2..6: sevenths and finer have never survived the prints-open
// bound at any bead this pipeline prints, and each extra family multiplies the packer's
// search without adding a size the coarser families cannot already express.
inline constexpr int kSteppedMaxDivisor = 6;
// ★ RULING A: how far the DOUBLED ladder may halve. 8 halvings takes a 12 mm base to
// 0.047 mm, far below any printable tile, so in practice the bead and the stated floor
// stop it first -- this is only a bound on the loop, not a design choice about depth.
inline constexpr int kSteppedMaxHalvings = 8;
// "Prints open": a bead-wide strut in a tile of this size must not exceed this relative
// density ON THE LEGS-ONLY OCTET LAW the rule was ruled and approved on (2026-10-10).
inline constexpr double kSteppedPrintsOpenMaxRho = 0.20;
// ★ THE SAME RULE AS GEOMETRY (ruling 2026-11-02 (c), option A): on that law a bead-wide
// strut at rho 0.20 is 0.7592 / 4 = 0.1898 of its tile, and that is the bound applied.
// Octet's law is now the full cell's, on which 0.20 would be a strut a third thinner, and
// the menus the maintainer approved were approved by LOOKING at the preview, which always
// drew the full octet: the geometry is what he ruled on, so the geometry is what stays.
// One number for every type (a statement about strut and tile, not about a type's law).
inline constexpr double kSteppedPrintsOpenMaxStrutPerCell = 0.7592 / 4.0;

// ── ★ ONE RULE, ONE PLACE: DOES A CELL OF THIS SIZE PRINT OPEN? ───────────────
// (Reviewer's ruling, 2026-10-10; stated as geometry by ruling 2026-11-02 (c).) A
// bead-wide strut in a cell this size must leave the cell mostly air: the strut at most
// kSteppedPrintsOpenMaxStrutPerCell of the cell. This is the answer
// `stepped_admitted_divisors` applies; the app calls it through the bridge, and its 0.20
// crossing (2.370917 mm at a 0.45 mm bead) is unchanged by (c).
//
// The bound is proportional to the bead: the smallest open cell is 5.268704 x bead.
// (Before (c) it was read through the octet law at rho 0.20, which is the same cell; a
// size off that table had to be resolved by side. A ratio has no table to fall off.)
bool lattice_prints_open(LatticeTopology topo, double cell_size_mm, double bead_mm);
// Two menu sizes closer than this (relative) are the same size: 2*(S/4) IS S/2, and a
// menu that listed both would make the packer try one size twice.
inline constexpr double kSteppedMenuSameRel = 1e-9;

// The sizes an any-step region may use, LARGEST FIRST and deduplicated. `base_cell_mm` is
// the region's base cell S, `bead_mm` the printable strut width, `min_cell_mm` a hard
// floor on the tile (0 = no floor beyond the prints-open bound). Returns {S} alone when no
// family prints open, which is the honest answer for a base too fine to subdivide.
// `apply_prints_open` is the AESTHETIC half of the bound and is off under a structural
// intent. The 20 % rule is a rule about how a quilt LOOKS; the beam-network certificate
// solves every strut rather than averaging them, so nothing structural depends on a cell
// being mostly air. Under structural the floor is `min_tile_mm` alone -- see §3.5 of the
// brief of 2026-09-17 and core's reply.
// ── ★ RULING A: TWO MENUS, ONE VALIDATOR ────────────────────────────────────────
// Any-step admits every k*(S/n) for n = 2..6. DOUBLED admits only the halving ladder
// S, S/2, S/4, ... -- the dyadic sizes the default grade has always drawn. The app now
// sends its placed cells for BOTH (the same bake packs them), so the only thing that
// differs downstream is which sizes are legal, and that is this flag. Everything else
// -- the family grid check, the prism check, the overlap hash -- is shared, because a
// doubled cell sits on its own size's grid exactly as an any-step cell sits on its
// family's tile.
enum class SteppedMenu {
  AnyStep,   // k*(S/n), n = 2..6 -- "stepped"
  Halves,    // S, S/2, S/4, ... -- "doubled"
};

// ★ `topo` IS FIRST AND HAS NO DEFAULT (task 2026-09-28-lattice-types-core). The
// "prints open" admission was a density question read on each type's law; since ruling
// 2026-11-02 (c) it is one geometry bound for every type (lattice_prints_open), so today
// no answer here depends on `topo`. It stays first and undefaulted because the trailing
// parameters have defaults that callers rely on, and a defaulted topology is how one
// type gets another's numbers the day a per-type rule returns.
std::vector<double> stepped_size_menu(LatticeTopology topo, double base_cell_mm,
                                      double bead_mm, double min_tile_mm = 0.0,
                                      bool apply_prints_open = true,
                                      SteppedMenu menu = SteppedMenu::AnyStep);

// The divisors whose tile was admitted, ascending. Exposed because the packer places on a
// family's own tile grid and the receipt reports per family.
std::vector<int> stepped_admitted_divisors(LatticeTopology topo,
                                           double base_cell_mm, double bead_mm,
                                           double min_tile_mm = 0.0,
                                           bool apply_prints_open = true,
                                           SteppedMenu menu = SteppedMenu::AnyStep);


// ── THE PLAN THE JOB STATES, AND WHY CORE VALIDATES RATHER THAN REPACKS ─────────
// The app sends the cells it placed -- the exact picture the maintainer approved on
// screen -- and core checks every one against the menu rule above. It does NOT silently
// repack: a core that quietly produced a different arrangement from the preview would
// make the screen a decoration rather than a contract, and the disagreement would only
// ever surface as a part that came out wrong. A refusal NAMES the offending cell.
struct SteppedCell {
  int region_id = 0;
  Vec3 origin{0, 0, 0};    // the cell's minimum corner, mm, in part coordinates
  double size_mm = 0.0;
  // ── ★ RULING C (maintainer, 2026-09-18): THE DENSITY COMES WITH THE CELL ──────
  // The preview's per-cell density, AFTER its aesthetic ceiling, its band raise and
  // its printability floor -- the densest texel of the cell. Core sizes the strut
  // from it with its own law (octet_strut_diameter_mm) and adds NO band term of its
  // own: the quilt raise and the coarse-cell share are the app's arithmetic, and
  // core re-deriving them from a demand field it grades differently is how the two
  // pictures drift. 0 = not sent, and core derives the density as it always has,
  // which is what every existing job does.
  double rho = 0.0;
};

// One declared region's frame: the base cell the menu is derived from, and the origin of
// its slot grid (the face plane along the normal, the region's anchor shift in-plane).
// Cell origins are checked as offsets from THIS, never from the solved grid's origin --
// any-step cells sit on their family's tile grid within the region.
struct SteppedPlanRegion {
  int region_id = 0;          // 1-based, the job's own include-region order
  double base_cell_mm = 0.0;
  // The region's own frame, DERIVED from lattice.regions[] rather than sent: cells state
  // their origin in model space, so this is the face-plane point their offsets are
  // measured from. `normal` and `depth_mm` describe the prism along the face normal; a
  // cell must lie within it, which is the one containment test that needs no in-plane
  // axis convention. 0 depth => the depth test is skipped.
  Vec3 slot_origin{0, 0, 0};
  // ★ K4: whether the SLOT ORIGIN above was sent on the wire or defaulted to the region
  // origin. The receipt reports it, because "the app packed on this grid" and "core
  // assumed the region origin" are different claims and the app can only check the first.
  bool slot_origin_stated = false;
  // ── ★ K2 (reviewer, 2026-10-08, correcting the ruling of 2026-10-05) ───────────
  // THE SLOT ORIGIN IS A GRID PHASE, NOT A PLANE POINT. It was required to lie in the
  // face plane, which is wrong for a TILTED facet: the app's octree grid there is
  // world-aligned, so the point it packed from is any point of the region's slot lattice
  // and generally stands off the plane. Requiring it on the plane would make the app
  // re-anchor tilted ladders, which changes the preview the maintainer approved.
  //
  // So the two jobs the one point used to do are now split: `slot_origin` carries the
  // PHASE (alignment, overlap and grouping measure from it), and `plane_origin` carries
  // the region's own face plane, which is what DEPTH is measured from. Moving the slot
  // origin along the normal now changes the phase and nothing else -- it cannot shift the
  // prism, which is what it silently did before.
  //
  // `plane_origin_stated` false means the slot origin is also the plane point, which is
  // every caller that has not been taught the difference (and every pure-header test).
  Vec3 plane_origin{0, 0, 0};
  bool plane_origin_stated = false;
  Vec3 normal{0, 0, 0};
  double depth_mm = 0.0;
};

struct SteppedPlanCheck {
  bool ok = false;
  std::string error;                     // names the offending cell when !ok
  std::size_t cells = 0;
  std::size_t regions = 0;
  // size -> count, descending by size: the same shape as the preview's DIAG
  // "octree kept" histogram, so the two can be compared entry for entry.
  std::vector<std::pair<double, std::size_t>> histogram;
  std::string histogram_line;            // "12.00=40 9.60=24 ...", for the receipt
};

// Checks, per the brief: every size is on that region's menu; every origin sits on a
// multiple of the tile of SOME family that can express that size (6 mm is both 12/2 and
// 2*(12/4), and either alignment is legitimate); and no two cells overlap. Region
// containment is NOT checked here -- it needs the outline and the material, which live
// with the caller.
// ★ `topo` FIRST, no default: the menu this validates against is a per-type
// density question (see stepped_size_menu).
SteppedPlanCheck stepped_validate_plan(LatticeTopology topo,
                                       const std::vector<SteppedCell>& cells,
                                       const std::vector<SteppedPlanRegion>& regions,
                                       double bead_mm, double min_tile_mm = 0.0,
                                       bool apply_prints_open = true,
                                       SteppedMenu menu = SteppedMenu::AnyStep,
                                       // ★ The include regions, for the STRADDLER rule
                                       // where two prisms meet: a cross-region overlap is
                                       // legitimate only where each cell's CENTRE is
                                       // owned by its own region (stepped_region_owner).
                                       // Omitted, every cross-region overlap is refused,
                                       // which is the conservative answer and what a
                                       // caller with no geometry to ask about should get.
                                       const std::vector<ClearanceGeometry>* includes =
                                           nullptr,
                                       // ★ D5: the job's density cap, so a cell's own rho
                                       // can be refused when it exceeds what the job
                                       // allows. 0 = not sent, and no cap is applied.
                                       double max_relative_density = 0.0);

// ── ONE PASS PER (REGION, FAMILY), NOT PER DISTINCT SIZE ────────────────────────
// The dyadic path builds a pass per distinct size on a grid anchored at the SOLVED
// GRID's origin. Any-step cells are not on that grid: they sit on their family's tile
// grid within the region, whose origin is the face plane along the normal and the
// region's anchor shift in-plane. So each (region, size) gets its OWN LatticeRegion --
// origin on that family's tile, cell_mm the size, and a `latticed` predicate that marks
// exactly the cells the plan placed. Nothing structural is missing from LatticeRegion;
// what was missing was the per-family ORIGIN, which is the whole of this.
//
// A group's origin is the plan's own slot origin shifted by whole tiles, so the grid it
// implies contains every cell of the group at integer indices -- never a re-anchoring
// that could move a cell the maintainer approved.
struct SteppedCellGroup {
  int region_id = 0;
  double size_mm = 0.0;
  Vec3 origin{0, 0, 0};              // the group's grid origin, in part coordinates
  int nx = 0, ny = 0, nz = 0;
  std::vector<std::array<int, 3>> cells;   // indices into that grid, ascending
  // ★ RULING C: each cell's sent density, in the SAME order as `cells`. 0 where the
  // job did not send one, which is every job written before the ruling -- the caller
  // then derives the density as it always has. Parallel rather than folded into the
  // triple so `cells` stays the plain index list every existing caller reads.
  std::vector<double> rho;
};

// Groups validated cells into passes. `cells` must already have passed
// stepped_validate_plan; this does no checking beyond skipping cells whose region is
// undeclared. Groups come back in a FIXED order -- region id, then size descending --
// so the emitted file is byte-identical for identical input.
std::vector<SteppedCellGroup> stepped_group_cells(
    const std::vector<SteppedCell>& cells, const std::vector<SteppedPlanRegion>& regions);

// ── ★ WHICH REGION OWNS A POINT (reviewer's ruling 4, 2026-10-07) ──────────────
// Core used to give a point inside two include prisms to the FIRST matching region in
// DECLARATION ORDER, however far its face was (run_job.cpp's per-voxel region ids,
// fit_cell_field, the void rule, and the any-step base derivation that reads them). That
// is not a geometric rule: it makes the answer depend on the order the app happened to
// write the regions in, and the app's own rule -- which core now adopts -- is the nearer
// FACE PLANE.
//
// Among the include regions whose PRISM CONTAINS the point, the owner is the one whose
// face plane is nearest; an exact tie goes to the lower region id. Never declaration
// order.
//
// CONTAINMENT IS NOT RE-DERIVED HERE. It is `point_in_clearance_region`, the same
// predicate core already resolves per-voxel membership with -- same lateral bounds, same
// frame convention, same outline. Only the TIE-BREAK is new, which is the whole of the
// change. A second containment test that agreed with the first only most of the time is
// the failure this avoids.
//
// Returns a 1-BASED index into `includes` (so it can be compared with a cell's
// `region_id`), or 0 for NO OWNER -- a point inside no prism belongs to nobody, and
// callers must treat 0 as "not in any include region" rather than as a region.
//
// A region with no face plane (a bolt: |normal| == 0) has no distance to compare, so it
// cannot win on nearness; among such regions the lower id wins. That case is not in the
// ruling and nothing in the job schema produces it for a lattice include today, so it is
// resolved deterministically rather than left to chance.
int stepped_region_owner(const Vec3& p, const std::vector<ClearanceGeometry>& includes);

// ── ★ E2.5: TWO REGIONS ON ONE FACE (plan.md §B6 note 22) ─────────────────────────
// Which of two include regions owns a point their face planes are EXACTLY equally near.
// Two regions on ONE face plane (coplanar and facing the same way) tie everywhere they
// overlap, so ruling 4's tie to the lower id would hand the whole overlap to whichever was
// declared first. There the DEEPER region wins (the plan's approved rule, "each keeps its
// own depth band; where they overlap, the deeper group's values win"); at equal depth, and
// on every other tie, the lower id wins, exactly as ruling 4 says. True when `a` wins.
// The owner rule above and the clip term that mirrors it (LatticeBoundary's owned
// region) both call this, so the two cannot disagree.
bool include_wins_plane_tie(const ClearanceGeometry& a, int id_a, const ClearanceGeometry& b,
                            int id_b);

}  // namespace topopt
