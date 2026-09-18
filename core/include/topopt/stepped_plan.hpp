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
// The bound is the octet law: relative density at a bead-wide strut in a tile of that
// size, at or under kSteppedPrintsOpenMaxRho. On a 12 mm base at a 0.45 mm bead the
// fifths print open at 2.4 mm and the sixths at 2.0 mm do not, which is exactly what
// removes the sixths family -- and with it the 10 mm entry, reachable only as 5*(12/6).
//
// NOTE ON THE BOUND, for the structural case: 20 % is an AESTHETIC rule (the quilt's
// finest rung). Under intent: structural the honest lower bound is the printability
// floor together with the certifiable cells-per-member regime, which is a different and
// generally COARSER limit. `min_cell_mm` is how a caller states that floor; the density
// bound is applied on top of it, never instead of it.

#include <array>
#include <cstddef>
#include <string>
#include <vector>

#include "topopt/mesh.hpp"   // Vec3

namespace topopt {

// Divisors the packer may use. 2..6: sevenths and finer have never survived the density
// bound at any bead this pipeline prints, and each extra family multiplies the packer's
// search without adding a size the coarser families cannot already express.
inline constexpr int kSteppedMaxDivisor = 6;
// "Prints open": a bead-wide strut in a tile of this size must not exceed this relative
// density. The octet law supplies the density; see the note above on the structural case.
inline constexpr double kSteppedPrintsOpenMaxRho = 0.20;
// Two menu sizes closer than this (relative) are the same size: 2*(S/4) IS S/2, and a
// menu that listed both would make the packer try one size twice.
inline constexpr double kSteppedMenuSameRel = 1e-9;

// The sizes an any-step region may use, LARGEST FIRST and deduplicated. `base_cell_mm` is
// the region's base cell S, `bead_mm` the printable strut width, `min_cell_mm` a hard
// floor on the tile (0 = no floor beyond the density bound). Returns {S} alone when no
// family prints open, which is the honest answer for a base too fine to subdivide.
std::vector<double> stepped_size_menu(double base_cell_mm, double bead_mm,
                                      double min_cell_mm = 0.0);

// The divisors whose tile was admitted, ascending. Exposed because the packer places on a
// family's own tile grid and the receipt reports per family.
std::vector<int> stepped_admitted_divisors(double base_cell_mm, double bead_mm,
                                           double min_cell_mm = 0.0);


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
};

// One declared region's frame: the base cell the menu is derived from, and the origin of
// its slot grid (the face plane along the normal, the region's anchor shift in-plane).
// Cell origins are checked as offsets from THIS, never from the solved grid's origin --
// any-step cells sit on their family's tile grid within the region.
struct SteppedPlanRegion {
  int region_id = 0;
  double base_cell_mm = 0.0;
  Vec3 slot_origin{0, 0, 0};
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
SteppedPlanCheck stepped_validate_plan(const std::vector<SteppedCell>& cells,
                                       const std::vector<SteppedPlanRegion>& regions,
                                       double bead_mm, double min_cell_mm = 0.0);

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
};

// Groups validated cells into passes. `cells` must already have passed
// stepped_validate_plan; this does no checking beyond skipping cells whose region is
// undeclared. Groups come back in a FIXED order -- region id, then size descending --
// so the emitted file is byte-identical for identical input.
std::vector<SteppedCellGroup> stepped_group_cells(
    const std::vector<SteppedCell>& cells, const std::vector<SteppedPlanRegion>& regions);

}  // namespace topopt
