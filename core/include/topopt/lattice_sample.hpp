#pragma once

// ★ THE SAMPLE BLOCK (lattice types round 1, R13 / 02-core-spec §6).
//
// One step from "core says this type is live" to a print on the maintainer's bed, so
// he can clear the "Not print-tested" tag (M2). A cube of the type's cells built by
// the PRODUCTION generator — the same code a run uses, nothing sample-specific about
// the struts — standing on a solid base plate for bed adhesion (the BCCZ print of
// 2026-07-29 lost the bed on its sharp cell corners). No internal supports.
//
// Defaults: a 40 mm cube of 8 mm cells, density at the middle of the type's
// certifiable band, a 1.5 mm plate. The plate sits under the cube (z in [0, plate]),
// the cube's cells on top of it; the bottom struts and nodes are half sunk in the
// plate, which is what bonds them to it.

#include <array>
#include <string>

#include "topopt/mesh.hpp"  // TriangleSink

namespace topopt {

struct LatticeSampleSpec {
  std::string topology;      // a GENERATABLE id (lattice_gen_topology_names)
  // "cube" (the default: one uniform block) or "coupon" (ruling 2026-11-02: one shape that
  // is both the app's Lattice preview and the block he prints; lattice_coupon.cpp states it).
  std::string shape = "cube";
  double cell_mm = 8.0;
  double rho = 0.0;          // cube: <= 0 => the middle of the type's certifiable band
  double size_mm = 40.0;     // cube: the edge; must be a whole number of cells
  double plate_mm = 1.5;     // the base plate's thickness; 0 = none
  double bead_mm = 0.0;      // cube: > 0 refuses a strut under one bead. coupon: the bead
                             //   the grade never goes below (0 => 0.42 mm)
  // coupon: the density graded along its length, <= 0 => the band's bottom / top.
  double rho_lo = 0.0, rho_hi = 0.0;
  bool step = true;          // coupon: a cell-size step where the type allows one
};

struct LatticeSampleReceipt {
  std::string topology;
  double rho = 0.0;               // the density the struts were sized for
  bool rho_was_band_middle = false;
  double band_min = 0.0, band_max = 0.0;
  double cell_mm = 0.0;
  int cells_per_side = 0;
  double size_mm = 0.0;
  double plate_mm = 0.0;
  double strut_diameter_mm = 0.0;  // the type's own law at (rho, cell)
  unsigned long long triangles = 0;        // lattice + plate
  unsigned long long lattice_triangles = 0;
  unsigned long long struts = 0, nodes = 0;
  // ★ Finding 8, sheets: the contoured mesh before simplification, and the deviation
  // MEASURED on every written triangle (the sheet's own surface; the block's cut faces).
  unsigned long long lattice_triangles_contoured = 0;
  double max_deviation_mm = 0.0, cut_max_deviation_mm = 0.0;
  // ── the coupon ──
  std::string shape = "cube";
  std::array<double, 3> coupon_dims_mm{0, 0, 0};  // x, y, z extents (plate included)
  double bead_mm = 0.0;
  double rho_lo = 0.0, rho_hi = 0.0;              // the grade along x
  std::string step;                               // "doubled" | "stepped" | "none"
  double step_at_x_mm = 0.0;
  std::string step_reason;                        // why none, in one line
  bool tongue_latticed = false;
  std::string tongue_reason;                      // why solid, in one line
  unsigned long long loose_pieces_dropped = 0, loose_triangles_dropped = 0;
};

// Build the block into `sink` and return its receipt. Throws std::invalid_argument,
// with the reason, for: a type core cannot generate, a size that is not a whole
// number of cells, a density outside the type's band, or (bead_mm > 0) a strut that
// would print thinner than one bead.
LatticeSampleReceipt write_lattice_sample(const LatticeSampleSpec& spec, TriangleSink& sink);

// The coupon alone (write_lattice_sample dispatches here for shape "coupon").
LatticeSampleReceipt write_lattice_coupon(const LatticeSampleSpec& spec, TriangleSink& sink);

// ★ The coupon's outline as one closed, welded solid (45 x 40 x 35 mm, the plate inside it):
// the part a run lattices when the coupon is the part (ruling 11-08 (A), the rim's test
// block). Its half-cylinder top is faceted in 1-degree steps, so it carries no sharp edge.
TriangleMesh lattice_coupon_solid();

// ★ THE BRIDGE ENTRY (preview parity): the same sample as an in-memory triangle soup, so the
// app's Lattice preview draws exactly what core writes to the file. Throws as
// write_lattice_sample does; `receipt` (optional) gets the receipt.
TriangleMesh lattice_sample_mesh(const LatticeSampleSpec& spec, LatticeSampleReceipt* receipt);

// The receipt as a small JSON object (one line per field).
std::string lattice_sample_receipt_json(const LatticeSampleReceipt& r);

}  // namespace topopt
