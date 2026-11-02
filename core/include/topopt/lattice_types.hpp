#pragma once

// ★ ONE PLAIN STRUCT PER LATTICE TYPE, FOR THE APP (lattice types round 1, the BRIDGE
// CONTRACT of docs/handoffs/2026-11-01-lattice-types-k1.md; 02-core-spec §5).
//
// Everything the picker, the mode chips and the receipt need to say about a type, in
// core's words and core's numbers, so the app never re-derives one. Every number is
// read from the per-type functions that the run itself uses (lattice.hpp,
// strut_cell.hpp, lattice_gen.hpp) -- this file holds facts ABOUT those, never a second
// copy of a number.
//
// A number core has not measured for the type is NaN, never octet's (R1); the
// `numbers_measured` flag says which state the struct is in. Print status is the
// maintainer's file (lattice_print_tests.hpp), read by the caller and joined by id.

#include <string>
#include <vector>

#include "topopt/lattice.hpp"

namespace topopt {

// An option the type allows or refuses; `reason` is one plain sentence when refused.
struct LatticeOption {
  bool allowed = false;
  std::string reason;
};

struct LatticeTypeFacts {
  std::string id;            // core's id ("fcc")
  std::string display_name;  // Q5's default ("FCC"); the maintainer may rename
  std::string family;        // "strut" or "sheet"
  LatticeTypeReadiness readiness = LatticeTypeReadiness::UnknownId;
  std::string readiness_plain;  // lattice_type_readiness_plain: the picker's words

  bool numbers_measured = false;  // lattice_type_numbers_measured
  double rho_min = 0.0, rho_max = 0.0;  // certifiable band (NaN when none)
  double cells_per_member_min = 0.0;    // bending accuracy floor
  double percolation_cells_per_member_min = 0.0;
  double aesthetic_hard_floor_cells = 0.0;
  // The smallest printable cell is this many times the bead width (at the band top):
  // lattice_min_printable_cell_mm(topo, bead, 0) / bead.
  double printable_cell_per_bead = 0.0;
  double aesthetic_density_ceiling = 0.0;  // R11 ("prints open")

  LatticeOption outline, rim, diagrid;     // finishes (R8)
  LatticeOption uniform, doubled, stepped; // cell modes (R4 / R5)

  bool directional = false;     // R3: SC and BCC
  std::string directional_note;

  // Triangles per cell of the infinite tiling as the generator emits it (8-gon prisms,
  // 20-triangle nodes). A block's outer faces add their own; this is the per-cell cost.
  double triangles_per_cell = 0.0;

  bool strut_strength_measured = false;  // R10
  std::string strut_strength_note;

  // Struts only: the canonical cell's integer denominator (coords in units of L/S);
  // 0 for a type with no strut cell. The cell itself is lattice_strut_cell().
  int cell_denominator = 0;
};

// Every type the picker shows, in the picker's order: octet first (M4), then the round-1
// eight in 01-types.md's order. Gyroid and Schwarz-D are listed (planned) before they
// are live.
const std::vector<std::string>& lattice_type_ids();

// The facts for one id. An id core does not know gets readiness UnknownId and
// everything else empty/NaN -- never another type's facts.
LatticeTypeFacts lattice_type_facts(const std::string& id);

// The cell-mode verdict the job parser applies (R4): may a job build `id` with the
// Doubled ladder / an any-step Stepped plan? `reason` is the plain refusal.
LatticeOption lattice_type_doubled(LatticeTopology topo);
LatticeOption lattice_type_stepped(LatticeTopology topo);

}  // namespace topopt
