#ifndef TOPOPT_CELL_PLAN_HPP
#define TOPOPT_CELL_PLAN_HPP

// THE DYADIC CELL-SIZE PLAN (handoff 2026-08-01-lattice-cell-size-sweep).
//
// grading.hpp chooses a lattice's relative DENSITY per voxel and, until this task,
// ONE cell size for the whole part. This header chooses the CELL SIZE per region of
// the part, so a thick boss can carry a coarse cell (fat, printable struts) while a
// thin rib carries a fine one (enough cells across the member to homogenize) — the
// AUTO / FIXED / SWEPT posture.
//
// ── WHY DYADIC, AND WHY THAT IS THE WHOLE TRANSITION RULE ────────────────────────
// The hard part of a varying cell size is how cells of DIFFERENT size MEET: a 4 mm
// cell abutting an 8 mm cell shares no nodes in general, and a strut that ends at an
// unshared node is a FLOATING END — a reject (PR 250's bar).
//
// The octet cell's 14 nodes are its 8 corners (integer multiples of the cell edge S)
// and its 6 face centres (one coordinate at a half multiple, S/2). Restrict the
// admissible cell sizes to the DYADIC ladder S_L = S0 * 2^L and place every cell on
// an ALIGNED 2^L block of the base grid (an octree), and every node of a level-L cell
// sits at a multiple of S_L/2 = S0 * 2^(L-1), which for L >= 1 is a multiple of S0 —
// i.e. it is also a node position of the base grid. COARSE NODES NEST IN THE FINE
// GRID. The two levels therefore meet AT SHARED NODES with zero bridge struts and
// zero stitching geometry. PR 235's C4 measured exactly this on resolved geometry
// (zero bridge struts, zero extra transition triangles) and named it as what slicers'
// adaptive-cubic infill already does on real prints.
//
// The two alternatives were measured and REJECTED:
//   * CONFORMAL WARP (smoothly stretch the cell). PR 235's C5: an ~8% per-cell
//     stretch drives Ez/Ex to 1.15 — the cell stops being cubic, and the certification
//     library carries exactly one cubic tensor per topology. Certification-fatal.
//   * BANDED REGIONS with a gap or a hand-stitched interface. Needs bridge geometry
//     that no measured tensor covers, and any missed bridge is a floating end.
//
// So: DYADIC OCTREE, aligned, and 2:1 BALANCED (face-adjacent cells differ by at most
// one level). Balancing only ever SPLITS a cell, which strictly helps the
// cells-per-member ceiling, so it can never push a cell out of the certifiable regime;
// it bounds the interface stress step, which PR 235's C4 measured at 1.68x the
// lattice's own internal riser for a single factor-2 jump.
//
// ── THE LEVEL LAW (the same law grading.hpp already applies, made PER CELL) ───────
// For each base cell the plan reads two limits from core, never hardcoding them:
//   * the CELLS-PER-MEMBER floor N* (lattice_cells_per_member_min) against the real
//     LOCAL member width W -> an UPPER bound on the cell: S <= W / N*. A cell above
//     it cannot be homogenized, so it is never emitted.
//   * the PRINTABILITY floor against the stated minimum extrudable width -> a LOWER
//     bound: S * phi(rho) >= min_width, with phi = octet_strut_diameter_mm(rho, 1)
//     the measured diameter per unit cell. A cell below it prints a strut thinner
//     than one bead.
// The chosen level is the SMALLEST admissible one — the finest cell that still keeps
// this cell's own thinnest strut printable, capped by what its own thinnest member can
// homogenize. That is what makes cell size FOLLOW DEMAND: low demand -> low rho ->
// thin struts -> the cell must grow; high demand -> fat struts -> the cell stays fine.
// A base cell whose two bounds CROSS (nothing is both printable and homogenizable
// there) is not latticed at all — it stays SOLID, the same L4 fallback the scalar law
// already applies per part, now applied per cell.
//
// TENSOR COST: none. The homogenized cubic tensor is a function of RELATIVE DENSITY
// only, and relative density is a ratio, so it is cell-size invariant — measured in
// this task's evidence (R2) and previously by PR 235's C1 (identical to 0.000e+00
// across a 4x cell range). A varying cell size therefore does not perturb the
// certification solve at all; it changes only which voxels clear the cells-per-member
// regime, which is reported per level.
//
// DETERMINISTIC. Pure integer/arithmetic sweeps in a fixed cell order, no RNG, no
// threads, no atomics: the same inputs always produce a byte-identical plan.

#include <cstddef>
#include <vector>

#include "topopt/lattice.hpp"  // LatticeTopology
#include "topopt/mesh.hpp"     // Vec3
#include "topopt/voxel.hpp"    // VoxelGrid

namespace topopt {

// How the cell size is chosen.
//   Fixed — the caller's target cell, raised to the printability floor. ONE cell for
//           the whole part: exactly the pre-sweep law, byte-identical (bar R1).
//   Auto  — core picks ONE uniform cell: the printability floor itself, i.e. the
//           SMALLEST cell every strut still prints at. Smallest is best here because
//           the cells-per-member ceiling is an UPPER bound (W / N*), so the finest
//           printable cell is exactly the uniform cell that leaves the most of the
//           part latticed. No user number.
//   Swept — the dyadic plan above, between min_cell_size_mm and max_cell_size_mm.
enum class CellSizeMode { Fixed, Auto, Swept };

const char* cell_size_mode_name(CellSizeMode m);  // "fixed" | "auto" | "swept"
// Parse a mode name; false (and `out` untouched) for anything else — a job schema
// never silently falls back to a mode the user did not ask for.
bool cell_size_mode_from_name(const char* name, CellSizeMode& out);

// What one cell-size LEVEL contributed — the per-region report (bar R5). One entry
// per dyadic level that owns at least one cell; a level IS a region of constant cell
// size, so this is the cells-per-member regime reported per region rather than one
// number for the part.
struct CellLevelReport {
  int level = 0;               // L; cell = base_cell_mm * 2^L
  double cell_size_mm = 0.0;
  long long cells = 0;         // octree cells assigned this level
  long long voxels = 0;        // latticed voxels inside them
  double min_member_width_mm = 0.0;   // thinnest member at this level (+inf if all
                                      //   exceed the EDT cap)
  double min_cells_per_member = 0.0;  // that member's span, in cells
  double min_strut_diameter_mm = 0.0;
  double max_strut_diameter_mm = 0.0;
  // TRIPWIRE, measured independently of the law that built the plan: is this level's
  // thinnest member below the floor the homogenized model needs? The plan enforces
  // the cap by construction, so a true here is a BUG in the plan, not a mode — the
  // same posture PR 263 takes with lattice_strut_out_of_regime.
  bool out_of_regime = false;
  bool any_strut_below_min = false;   // likewise: printability, measured after the fact
};

// The plan: a dyadic octree over a BASE cell grid, plus the report.
struct CellSizePlan {
  CellSizeMode mode = CellSizeMode::Fixed;

  // ── the dyadic ladder ───────────────────────────────────────────────────────────
  Vec3 origin{0.0, 0.0, 0.0};  // base grid corner (model mm) = the voxel grid origin
  double base_cell_mm = 0.0;   // S0, the level-0 (finest) cell
  int max_level = 0;           // levels are 0..max_level; cell(L) = S0 * 2^L.
                               //   0 on the Fixed/Auto paths (one uniform cell).
  int nx = 0, ny = 0, nz = 0;  // BASE cell grid dimensions

  // Base-cell-indexed (nx*ny*nz, x fastest): the level of the octree cell COVERING
  // this base cell, or -1 where nothing is latticed. Every base cell of one octree
  // cell carries that cell's level, so the octree is recoverable by scanning for
  // aligned blocks (cell_owner below does it for you).
  std::vector<signed char> level;

  // ── provenance: the limits READ FROM CORE ───────────────────────────────────────
  double cells_per_member_floor = 0.0;  // N*
  double printability_floor_mm = 0.0;   // smallest cell printing the rho_min strut

  // ── the report ──────────────────────────────────────────────────────────────────
  std::vector<CellLevelReport> levels;  // ascending level; only occupied levels
  long long latticed_cells = 0;
  // Cells whose level was RAISED above the base for PRINTABILITY (bar R3's "count of
  // cells raised to the floor"). A cell coarsened purely because a neighbour in its
  // octree block needed it is counted too — the merge is what set its size.
  long long cells_raised_to_floor = 0;
  // Cells the two bounds CROSSED on: no dyadic cell is both printable and
  // homogenizable there, so they stay SOLID (the per-cell L4 fallback).
  long long cells_dropped_unprintable = 0;  // needed a coarser cell than N* allows
  long long cells_split_by_balance = 0;     // octree cells split (into 8) to hold
                                            //   the 2:1 balance
  double min_strut_diameter_mm = 0.0;       // across the WHOLE swept part (bar R3)
  double max_strut_diameter_mm = 0.0;
  double min_cells_per_member = 0.0;        // across the whole swept part
  bool any_out_of_regime = false;           // any level's tripwire fired
  bool any_strut_below_min = false;

  // ── accessors ───────────────────────────────────────────────────────────────────
  std::size_t index(int i, int j, int k) const {
    return (static_cast<std::size_t>(k) * ny + j) * nx + i;
  }
  double cell_mm_at_level(int L) const;
  // The cell size covering base cell (i,j,k), or 0.0 where not latticed.
  double cell_size_at(int i, int j, int k) const;
  // The OCTREE cell owning base cell (i,j,k): its level and the base-grid corner of
  // its aligned block. Returns false where not latticed. The generator emits an
  // octree cell exactly once, from its owning (min-corner) base cell.
  bool cell_owner(int i, int j, int k, int& level_out, int& bi, int& bj,
                  int& bk) const;
};

// Inputs the level law needs, all of them limits the caller states or core owns.
struct CellPlanParams {
  LatticeTopology topology = LatticeTopology::Octet;
  CellSizeMode mode = CellSizeMode::Fixed;

  // Fixed: the requested cell (raised to the printability floor). Ignored by Auto.
  double target_cell_size_mm = 0.0;
  // Swept: the ladder ends. base = min (raised to nothing — a min below the
  // printability floor is legal and simply means the finest levels go unused where
  // struts would be too thin); max sets max_level = floor(log2(max/min)). Both must
  // be > 0 with max >= min. Ignored by Fixed/Auto.
  double min_cell_size_mm = 0.0;
  double max_cell_size_mm = 0.0;

  // The STATED minimum extrudable strut width (mm) — the printability bound.
  double min_extrudable_width_mm = 0.0;
  // The local-member-thickness EDT radius cap (voxels), mirroring grading.hpp.
  int thickness_cap_voxels = 32;
};

// Build the SWEPT plan over `grid`'s candidate set (throws for any other mode — the
// Fixed and Auto paths are ONE uniform cell and stay in grading.hpp's own per-voxel
// loop untouched, which is what makes a fixed-cell job byte-identical to a pre-sweep
// run, bar R1; grading.hpp fills a trivial one-level plan for them so the REPORT has
// the same shape in all three modes).
//
// `rho` is the per-voxel relative density
// the grading law already chose (grid-indexed; read only where `candidate` is set) —
// the plan does NOT choose density, so the two laws compose without circularity: rho
// depends on demand alone, and cell size depends on rho + local member width.
// `candidate[e] != 0` marks voxel e a lattice candidate; `width` is the local member
// width field (mm), passed in so the caller measures it once and both laws share it.
//
// Guarantees, asserted internally before returning (the bars this exists to hold):
//   * every latticed base cell's chosen cell satisfies S <= W / N* for EVERY voxel in
//     it (bar R5's regime) AND S * phi(rho) >= min_extrudable_width for every voxel in
//     it (bar R3's printability) — per CELL, never averaged over the part;
//   * the assignment is a valid aligned octree (every level-L cell occupies a 2^L
//     block whose base cells all carry L), so coarse nodes nest in the base grid and
//     the levels meet at shared nodes (bar R4's transition);
//   * face-adjacent octree cells differ by at most one level (2:1 balance).
// Throws std::invalid_argument on a size mismatch or a non-positive/inconsistent
// param, std::logic_error if an invariant above is ever violated.
CellSizePlan plan_cell_sizes(const VoxelGrid& grid,
                             const std::vector<double>& rho,
                             const std::vector<char>& candidate,
                             const std::vector<double>& width,
                             const CellPlanParams& params);

// The per-voxel cell size the plan implies (grid-indexed, mm; 0 off the latticed
// set) — what the certification posture carries so its cells-per-member guard is
// evaluated at each voxel's OWN cell rather than one number for the part.
std::vector<double> cell_size_field(const VoxelGrid& grid,
                                    const CellSizePlan& plan);

}  // namespace topopt

#endif  // TOPOPT_CELL_PLAN_HPP
