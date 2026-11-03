// The per-type facts the app reads (topopt/lattice_types.hpp states the contract).

#include "topopt/lattice_types.hpp"

#include <cstdio>

#include <cmath>
#include <limits>
#include <stdexcept>

#include "topopt/lattice_gen.hpp"
#include "topopt/strut_cell.hpp"

namespace topopt {
namespace {

constexpr double kNaN = std::numeric_limits<double>::quiet_NaN();

LatticeOption yes() { return {true, ""}; }
LatticeOption no(const std::string& why) { return {false, why}; }

// Q5's default display names (docs/design/lattice-types/00-decisions.md).
const char* display_name_of(const std::string& id) {
  if (id == "octet") return "Octet truss";
  if (id == "sc") return "Simple cubic";
  if (id == "bcc") return "BCC";
  if (id == "fcc") return "FCC";
  if (id == "diamond") return "Diamond";
  if (id == "kelvin") return "Kelvin";
  if (id == "rhombic") return "Rhombic dodecahedron";
  if (id == "gyroid") return "Gyroid";
  if (id == "schwarz_d") return "Schwarz-D";
  return "";
}

bool known_topology(const std::string& id, LatticeTopology* out) {
  try {
    *out = lattice_topology_from_id(id);
    return true;
  } catch (const std::invalid_argument&) {
    return false;
  }
}

}  // namespace

// ── R4: CELL-SIZE STEPS, PER TYPE, AS MEASURED ─────────────────────────────────
// A strut type may use the Doubled ladder or an any-step Stepped plan only where core
// has PROVED its struts join across the step: a two-size block built by the production
// generator, every primitive tapped, ONE solid-overlap component and ZERO dangling
// strut ends (core/tests/harness/lattice_types_probe.cpp `step`, evidence
// docs/handoffs/evidence/2026-11-01-lattice-types-k1/<id>_step.{csv,txt}). Doubled is
// an S | S/2 block, Stepped an S | 2S/3 interface, both at the band's middle density.
// R5: a sheet grades by WALL THICKNESS at one cell size per region. No published method
// grades a TPMS's cell size at a fixed wall, and a period change at a boundary leaves the
// sheets unjoined, so neither size step is offered for one.
static const char* const kSheetNoSteps =
    "A sheet lattice grades by wall thickness at one cell size per region (R5): a change of "
    "cell size leaves its sheets unjoined, and no measured method joins them yet.";

LatticeOption lattice_type_doubled(LatticeTopology topo) {
  if (lattice_topology_is_sheet(topo)) return no(kSheetNoSteps);
  switch (topo) {
    case LatticeTopology::Octet:  // PR 235's C4 (zero bridge struts) and octet_step.txt
    case LatticeTopology::Fcc:    // fcc_step.txt: 1 component, 0 dangling of 2,208 ends
    case LatticeTopology::Kelvin: // kelvin_step.txt: 1 component, 0 dangling of 3,936 ends
    case LatticeTopology::Diamond:  // diamond_step.txt: 1 component, 0 dangling of 2,304 ends
    case LatticeTopology::Bcc:      // bcc_step.txt: 1 component, 0 dangling of 1,152 ends
    case LatticeTopology::SimpleCubic:  // sc_step.txt: 1 component, 0 dangling of 708 ends
      return yes();
    case LatticeTopology::Rhombic:  // rhombic_step.txt: the S|S/2 block is TWO pieces
      return no("Doubled cells are not offered for the rhombic dodecahedron: measured, its "
                "struts do not meet across a cell-size halving (an S | S/2 block comes out "
                "as two separate pieces). Use one cell size, or Stepped.");
    default:
      return no(std::string("Doubled cells are not offered for ") +
                lattice_topology_name(topo) +
                " yet: core has not measured whether its struts join across a size "
                "step.");
  }
}

LatticeOption lattice_type_stepped(LatticeTopology topo) {
  if (lattice_topology_is_sheet(topo)) return no(kSheetNoSteps);
  switch (topo) {
    case LatticeTopology::Octet:  // octet_step.txt: 1 component, 0 dangling
    case LatticeTopology::Fcc:    // fcc_step.txt: 1 component, 0 dangling of 1,152 ends
    case LatticeTopology::Kelvin: // kelvin_step.txt: 1 component, 0 dangling of 1,992 ends
    case LatticeTopology::Rhombic:  // rhombic_step.txt: 1 component, 0 dangling of 2,240 ends
    case LatticeTopology::Diamond:  // diamond_step.txt: 1 component, 0 dangling of 1,120 ends
    case LatticeTopology::Bcc:      // bcc_step.txt: 1 component, 0 dangling of 560 ends
    case LatticeTopology::SimpleCubic:  // sc_step.txt: 1 component, 0 dangling of 396 ends
      return yes();
    default:
      return no(std::string("Stepped cells are not offered for ") +
                lattice_topology_name(topo) +
                " yet: core has not measured whether its struts join across a size "
                "step.");
  }
}

std::string lattice_type_directional_note(const std::string& id) {
  // tensor-library-nine: the certificate carries the full tensor and is right, but the
  // grading law's scalar E100 proxy mis-ranks an off-axis member of these two.
  if (id == "sc" || id == "bcc")
    return "Strongly directional: best when the load runs along the cell axes.";
  return "";
}

const std::vector<std::string>& lattice_type_ids() {
  static const std::vector<std::string> ids = {"octet",   "sc",     "bcc",
                                               "fcc",     "diamond", "kelvin",
                                               "rhombic", "gyroid", "schwarz_d"};
  return ids;
}

LatticeOption lattice_type_aesthetic(LatticeTopology topo) {
  if (!lattice_type_numbers_measured(topo)) return yes();  // octet: R11 is its own rule
  const double rho_min = lattice_rho_min(topo);
  const double ceiling = lattice_aesthetic_density_ceiling(topo);
  if (!(ceiling < rho_min)) return yes();
  const std::string id = lattice_topology_name(topo);
  char buf[400];
  std::snprintf(buf, sizeof buf,
                "%s is offered for Structural parts only: its thinnest certifiable strut is "
                "%.3f of the cell, already wider than the open-print limit of a fifth of the "
                "cell, so no %s density prints open (Finding 6).",
                display_name_of(id), lattice_strut_diameter_mm(topo, rho_min, 1.0),
                display_name_of(id));
  return no(buf);
}

LatticeTypeFacts lattice_type_facts(const std::string& id) {
  LatticeTypeFacts f;
  f.id = id;
  f.display_name = display_name_of(id);
  f.readiness = lattice_type_readiness(id, lattice_gen_topology_names(),
                                       lattice_certifiable_topology_names());
  f.readiness_plain = lattice_type_readiness_plain(f.readiness);
  f.rho_min = f.rho_max = f.cells_per_member_min = f.percolation_cells_per_member_min =
      f.aesthetic_hard_floor_cells = f.printable_cell_per_bead =
          f.aesthetic_density_ceiling = f.triangles_per_cell = f.sheet_triangles_coeff =
              f.sheet_triangles_per_cell_mm = kNaN;
  const std::string not_live =
      std::string("Not offered: ") + f.readiness_plain + ".";
  f.outline = f.rim = f.diagrid = f.uniform = f.doubled = f.stepped = f.structural =
      f.aesthetic = no(not_live);
  f.strut_strength_note = "Strut strength is not measured for this type.";

  LatticeTopology topo;
  if (!known_topology(id, &topo)) return f;  // UnknownId: no facts to borrow
  const bool sheet = lattice_topology_is_sheet(topo);
  f.family = sheet ? "sheet" : "strut";
  if (lattice_topology_certifiable(topo)) {
    f.rho_min = lattice_rho_min(topo);
    f.rho_max = lattice_rho_max(topo);
  }
  f.directional_note = lattice_type_directional_note(id);
  f.directional = !f.directional_note.empty();
  if (lattice_has_strut_cell(topo)) {
    const StrutCell& c = lattice_strut_cell(topo);
    f.cell_denominator = c.S;
    // 8-gon prism = 32 triangles, icosahedral node = 20 (lattice_gen.hpp).
    f.triangles_per_cell = 32.0 * c.struts.size() + 20.0 * c.nodes.size();
  }
  f.numbers_measured = lattice_type_numbers_measured(topo);
  if (f.numbers_measured) {
    f.cells_per_member_min = lattice_cells_per_member_min(topo);
    f.percolation_cells_per_member_min = lattice_percolation_cells_per_member_min(topo);
    f.aesthetic_hard_floor_cells = aesthetic_cells_per_member_hard_floor(topo);
    f.printable_cell_per_bead = lattice_min_printable_cell_mm(topo, 1.0, 0.0);
    f.aesthetic_density_ceiling = lattice_aesthetic_density_ceiling(topo);
    if (sheet) {
      // sheet_triangle_cost.txt (tpms_probe `tris`): triangles per interior cell over
      // (L/h)^2, the larger of rho 0.20 / 0.40 at L/h 20 and 30 (a budget should not
      // undercount). Uniform wall at the band middle, h = a third of it: cell-size free.
      f.sheet_triangles_coeff = topo == LatticeTopology::Gyroid ? 19.44 : 24.00;
      // sheet_simplified_cost.txt (Finding 8): interior cells of the 40 mm sample block,
      // simplified to 0.02 mm, near the band middle at an 8 mm cell (gyroid rho 0.375:
      // 3,873; Schwarz-D rho 0.40: 6,213), per mm of cell. Linear in the cell: gyroid at 4
      // mm 1,962, Schwarz-D at 5 mm 3,854.
      f.sheet_triangles_per_cell_mm = topo == LatticeTopology::Gyroid ? 3873.0 / 8.0 : 6213.0 / 8.0;
      f.triangles_per_cell = 8.0 * f.sheet_triangles_per_cell_mm;
    }
  }
  if (f.readiness == LatticeTypeReadiness::Live) {
    // R8: the solid outline and Rim apply to every type; Diagrid anchors where struts
    // meet the surface, which every strut type has and a sheet does not.
    f.outline = f.rim = f.diagrid = yes();
    if (sheet)
      f.diagrid = no("Diagrid anchors where struts meet the surface; a sheet meets it along "
                     "curves, so there is nothing to anchor to (R8).");
    f.uniform = yes();
    f.doubled = lattice_type_doubled(topo);
    f.stepped = lattice_type_stepped(topo);
    f.structural = yes();
    f.aesthetic = lattice_type_aesthetic(topo);
  }
  if (topo == LatticeTopology::Octet) {
    f.strut_strength_measured = true;  // PR 259's law (strut_strength.hpp)
    f.strut_strength_note = "";
  }
  return f;
}

}  // namespace topopt
