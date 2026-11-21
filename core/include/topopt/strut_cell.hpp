#pragma once

// ★ THE CANONICAL STRUT CELL, PER TYPE — one definition (task: lattice types round 1,
// docs/design/lattice-types/02-core-spec.md §2.1).
//
// Every strut lattice core builds is (S, struts, nodes) on an INTEGER grid in units of
// L/S, where L is the cell edge. This is the table the tensor rows were measured on:
// the builder below is the integer node-basis + bond machinery of the strut-lattice
// family study (evidence/2026-07-27-strut-lattice-family/strut_lattice_gen.cpp), which
// core/tests/harness/tensor_library_nine_probe.cpp copied operation-for-operation to
// measure the landed rows. `test_strut_cell` compiles that probe's own source and
// asserts the production table equals its `make_lattice` element for element (same S,
// struts, phase), so the certified cell and the generated cell cannot drift apart —
// the failure tensor-library-nine finding 3 recorded for octet.
//
// THE CONVENTIONS
//   * CANONICAL strut: its midpoint lies in the half-open cell [0,S)^3, so every strut
//     of the infinite tiling belongs to exactly one cell. Endpoints are stored a < b
//     (lexicographic x, y, z), and the list is in that order (the probe's std::set).
//   * CANONICAL node: coordinates in [0,S)^3.
//   * PHASE 0: the integer origin is the cell's min corner, the same anchor the
//     generator's cell grid uses.
//   * Every strut of every type here lies inside the CLOSED cell [0,S]^3 of the cell
//     that owns it (asserted when the table is built). That is what lets the
//     generator keep octet's cell-local ownership: a cell only ever emits geometry
//     inside its own closed box.
//
// Octet is listed for the bridge (the app draws every type from core, R12). Its row is
// the FULL octet the production generator builds — the 12 nearest-neighbour bonds,
// legs AND octahedral braces — and NOT the legs-only cell its shipped tensor rows were
// measured on (open question Q2). The octet GENERATOR keeps its own hand-written
// tables (lattice_gen.cpp) so its bytes cannot move; this row is what they emit.

#include <vector>

#include "topopt/lattice.hpp"

namespace topopt {

struct StrutCellPoint {
  int x = 0, y = 0, z = 0;
};
struct StrutCellStrut {
  StrutCellPoint a, b;
};

struct StrutCell {
  int S = 0;                            // integer denominator: coords in units of L/S
  std::vector<StrutCellStrut> struts;   // canonical (midpoint in [0,S)^3), a < b, sorted
  std::vector<StrutCellPoint> nodes;    // canonical (coords in [0,S)^3), sorted
};

// True for the topologies that have a canonical cell here: octet, sc, bcc, fcc,
// diamond, kelvin, rhombic. False for the tetragonal three (not in round 1).
bool lattice_has_strut_cell(LatticeTopology topo);

// The canonical cell. Throws std::invalid_argument, naming the type, for a topology
// with no cell (never a fallback to another type's cell).
const StrutCell& lattice_strut_cell(LatticeTopology topo);

// Every translate (by a multiple of S on each axis) of a canonical strut / node that
// lies inside the CLOSED cell [0,S]^3. These are the candidates one cell considers;
// ownership then decides which of the cells sharing a face, edge or corner emits each
// (lattice_gen.cpp). Deterministic order: canonical order, then shift (dz, dy, dx).
std::vector<StrutCellStrut> strut_cell_closed_struts(const StrutCell& cell);
std::vector<StrutCellPoint> strut_cell_closed_nodes(const StrutCell& cell);

// The RELATIVE DENSITY of the type's periodic cell at unit-cell strut radius
// `r_unit` (r / L), voxelised at `vpc` voxels per cell edge — the tensor probe's
// `build_cell` exactly: a voxel is solid when its centre is within r of a strut of the
// infinite tiling (the 27 integer-shift images of every canonical strut). Struts are
// round cylinders with spherical ends (the point-segment distance). This is the basis
// every landed tensor row's rho was measured on, so it is the basis the density law
// is stated on.
double strut_cell_voxel_density(const StrutCell& cell, double r_unit, int vpc);

// ★ THE SAME SOLID'S TRUE (CONVERGED) VOLUME FRACTION — what the density law is stated
// on for every type that goes live in round 1.
//
// WHY NOT vpc48. On a lattice-aligned voxel grid the solid fraction is a STAIRCASE in r
// with steps that do not shrink smoothly: the struts run along the grid's own
// directions, so whole rows of voxel centres enter at once. Measured on the canonical
// cells (docs/handoffs/evidence/2026-11-01-lattice-types-k1/law_resolution.txt):
// rhombic at r/L 0.045 reads 0.059 at vpc48 and 0.0785 at vpc256 (-24 %); FCC at r/L
// 0.0667 reads 0.0951 vs 0.1026 (-7 %). A law bisected on that staircase sizes a strut
// to wherever a step happens to fall. The tensor rows themselves are resolution-checked
// AS A FUNCTION OF DENSITY (vpc48 vs vpc64 at matched rho, PR 198/237), so the strut
// that realises a density is the one whose TRUE solid fraction is that density.
//
// So this samples the cell at `samples` points of the 3-D Halton sequence (bases 2, 3,
// 5; indices 1..samples) with the same inside test as strut_cell_voxel_density. The
// sequence is fixed, so the answer is deterministic, and it is CONTINUOUS in r to the
// sampling's own discrepancy (no lattice-aligned rows), so a bisection on it converges.
double strut_cell_solid_fraction(const StrutCell& cell, double r_unit,
                                 int samples = 1 << 20);

}  // namespace topopt
