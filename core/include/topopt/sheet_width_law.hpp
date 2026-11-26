#ifndef TOPOPT_SHEET_WIDTH_LAW_HPP
#define TOPOPT_SHEET_WIDTH_LAW_HPP

// THE SHEETS' LAWS PER MEMBER WIDTH (sheets spec 2026-11-25 rev 3, section 3.2; builder D).
//
// Today a gyroid (Schwarz-D) member is credited only from 10 (9) cells across: the strut law
// (strut_strength.hpp) was measured on blocks 3-4 cells across and enveloped with the bulk, and
// the bending error of the averaged material is within 2.4 % only from there. These tables are
// the same two measurements made per width N, N = 2, 3, 4, 5, 6, 8 (and 7 for bending), so a
// thinner member can be credited by its own row:
//
//   STRENGTH  per (N, rho): Kd, Kv, Kild, Kilv exactly as strut_law_at's, measured by
//             lattice_dehomog_probe `widths` (11-09's sandwich and cut-layer blocks N across, the
//             aliasing guard and its finer-pitch re-measure). SINCE THE REVIEWER'S RULING OF
//             2026-11-26 (item 3 (a)) the law's populations are the free surface and the OFF-GRIP
//             CUT POPULATION (the cut layer's cells off the two grip columns; 11-09's cut layer kept
//             the cells in the grip columns, where its peak sits) over the CUT SWEEP (0.25, and every
//             voxel layer of the law pitch from half a cell up: 0.5, 0.6 and the rest), and the bulk.
//             Per N the ENVELOPE (each coefficient's highest K, the weakest result, across the sweep),
//             then the MONOTONE RULE: made to RISE as N falls and never under today's law (a narrower
//             member is never credited more than a wider one, nor more than any sweep point at its
//             width or wider). evidence/2026-11-26-sheet-laws-envelope (envelope.py).
//   STIFFNESS per (N, rho): the C2b guided cantilever (tpms_probe `bend`) resolved against the
//             averaged material, at the band floor, 0.40 and the band ceiling. Where the averaged
//             material reads too stiff (error > 0) its tensor is scaled by 1 / (1 + error); where
//             it reads too soft nothing changes.
//
// Evidence: evidence/2026-11-26-sheet-laws-envelope (the strength rows, the floor, the envelope's
// checks) and evidence/2026-11-25-sheet-laws-thin-members (the fixtures it builds on, and the
// bending rows); the tables are GENERATED from their CSVs (sheet_width_law_tables.inc), and
// test_sheet_width_law pins every row. Carried caveats: see those READMEs and strut_strength.hpp
// (rows still rising with resolution are lower bounds; the interlayer factor is unsourced).
//
// Nothing here is wired into a verdict: the strength check reads these (builder B) when the
// floor is set by the lead and TOReview, through sheet_credit_law_at (below), never around it.

#include <optional>
#include <vector>

#include "topopt/lattice.hpp"
#include "topopt/strut_strength.hpp"  // StrutLawK

namespace topopt {

// True for the types measured per width (gyroid, Schwarz-D).
bool sheet_width_law_measured(LatticeTopology topo);

// The widths (cells across) that have their own strength row, narrowest first.
std::vector<int> sheet_width_law_widths(LatticeTopology topo);

// The Structural floor D's measurement supports (cells across): 2 when the 2-cell rows came out
// steady by the evidence README's criteria (fixed before the long runs), else 3. A proposal: the
// lead and TOReview set the number the check uses.
int sheet_width_floor_measured(LatticeTopology topo);

// The strength law of a member `cells_across` wide (the room through it over the cell, rounded
// down), at density rho: the row of the widest measured width not above `cells_across`,
// piecewise-linear in rho, clamped to that row's band (`clamped` says so). At or above
// lattice_cells_per_member_min(topo) it IS strut_law_at(topo, rho) (today's law). Throws
// std::invalid_argument under the narrowest measured width (no law there: the member is solid)
// or for a type with no table.
StrutLawK sheet_strut_law_at(LatticeTopology topo, int cells_across, double rho,
                             bool* clamped = nullptr);

// ── (b) OF THE RULING OF 2026-11-26, item 3: NO STRUCTURAL SHEET CREDIT UNTIL (a) ────────────────
// "NO Structural sheet credit until (a); Aesthetic may ship." A Structural sheet is credited only
// when BOTH keys turn:
//   1. the envelope law is in and passes (sheet_envelope_law_passes, generated from
//      evidence/2026-11-26-sheet-laws-envelope/kenv_checks.csv: the sweep complete, 0.5 and 0.6 in
//      it, monotone, never above a sweep point, never under today's law);
//   2. kSheetStructuralCreditReviewed: the reviewer has read (a)'s result and opens it (this line).
// Until then sheet_credit_law_at gives NO law at any width, today's 10 / 9 cells included. An
// Aesthetic sheet makes no strength claim and never asks: nothing here changes it.
inline constexpr bool kSheetStructuralCreditReviewed = false;

// The generated verdict of the envelope law's checks, per type (false for a type with no table).
bool sheet_envelope_law_passes(LatticeTopology topo);

// The gate itself: open only when the envelope law passes AND the reviewer has opened it.
constexpr bool sheet_structural_credit_gate(bool envelope_law_passes, bool reviewed) {
  return envelope_law_passes && reviewed;
}

// True when a Structural sheet of this type may be credited at all.
bool sheet_structural_credit_open(LatticeTopology topo);

// THE ONLY DOOR to a Structural sheet's strength law: std::nullopt while the gate is closed, and
// under the law's floor (sheet_width_floor_measured); else sheet_strut_law_at. A type with no
// table throws as sheet_strut_law_at does.
std::optional<StrutLawK> sheet_credit_law_at(LatticeTopology topo, int cells_across, double rho,
                                             bool* clamped = nullptr);

// The averaged material's bending-stiffness error for a member `cells_across` wide at density
// rho, as a fraction (+0.21 = the averaged member is 21 % too stiff): the measured row of the
// widest measured width not above it, linear in rho between the three measured densities and
// clamped to them; 0 at or above lattice_cells_per_member_min(topo) (today's model). Throws like
// sheet_strut_law_at.
double sheet_bending_error(LatticeTopology topo, int cells_across, double rho);

// The factor the averaged tensor is scaled by for that member: 1 / (1 + error) where the error is
// positive, 1 where it is not (an averaged member that reads too soft is left as it is).
double sheet_stiffness_scale(LatticeTopology topo, int cells_across, double rho);

}  // namespace topopt

#endif  // TOPOPT_SHEET_WIDTH_LAW_HPP
