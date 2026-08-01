#ifndef TOPOPT_GATE_DIAGNOSIS_EVAL_HPP
#define TOPOPT_GATE_DIAGNOSIS_EVAL_HPP

// diagnose_gate — turn ONE gate verdict into a structured explanation plus
// recommendations that the REAL GATE has already been asked
// (handoff 2026-08-02-gate-diagnosis-recommendations).
//
// The value types live in gate_diagnosis.hpp (dependency-free, so report.hpp can
// carry one without an include cycle). This header is the EVALUATOR: it needs
// KnockdownSpec and gate_margin_effective from analyze.hpp.
//
// *** IT NEVER MOVES A VERDICT. *** `accepted`, `margin_effective` and
// `margin_stop` are INPUTS. diagnose_gate writes only to its own GateDiagnosis.

#include <string>
#include <vector>

#include "topopt/analyze.hpp"         // KnockdownSpec, gate_margin_effective
#include "topopt/gate_diagnosis.hpp"  // the value types
#include "topopt/materials.hpp"       // Material, MaterialLibrary
#include "topopt/report.hpp"          // StressMargin

namespace topopt {

struct BuildOrientationReport;  // build_orientation.hpp

// One rung THIS RUN ACTUALLY SOLVED, for the volume-fraction lever. Only real
// measured rungs go here — the lever never extrapolates to a rung the ladder did
// not walk, because pricing that needs a full re-solve.
struct GateSolvedRung {
  double volume_fraction = 0.0;
  double margin_effective = 0.0;
  bool accepted = false;
};

// Everything diagnose_gate is allowed to read. Every field is something the
// caller ALREADY has after one certification analysis; nothing here implies a
// second solve.
struct GateDiagnosisInputs {
  // --- The verdict being explained (inputs, never recomputed) ----------------
  bool accepted = false;
  bool load_path_ok = true;
  double margin_stop = 0.0;
  double margin_effective = 0.0;  // the gate's own number
  StressMargin margin;            // the raw solid margin

  // --- The gate's arguments --------------------------------------------------
  Material material;
  std::string material_name;
  KnockdownSpec knockdown;
  double max_von_mises = 0.0;
  double max_von_mises_effective = 0.0;  // == max_von_mises in the default posture
  double max_interlayer = 0.0;

  // --- The levers' current settings -------------------------------------------
  double infill_percent = 100.0;
  int wall_loops = 0;
  double wall_line_width_mm = 0.45;
  double wall_line_width_outer_mm = -1.0;  // < 0 => mirror the inner width

  // --- The V3 reliability facts ------------------------------------------------
  int min_feature_violations = 0;
  int min_feature_warning_threshold = 1;
  // The thinnest PRINTED member in mm (local_member_thickness_mm on this design).
  // 0 / non-finite => not measured. ONLY the resolution lever reads it, so a
  // caller whose run never hits a min-feature binding may leave it at 0 and pay
  // nothing for the measurement.
  double min_member_thickness_mm = 0.0;
  double voxel_spacing_mm = 0.0;
  // §7 V3 gate 4's floor, in voxels ("minimum feature size >= 2 voxels").
  int min_feature_voxels = 2;

  // --- Width-aware re-pricing (EMPTY in the default posture) --------------------
  // The (von Mises, local member width) pairs over the SOLID PRINTED voxels the
  // width-aware gate maxed over. With them, a candidate infill / wall ring is
  // repriced through the SAME width_aware_knockdown the gate used — no re-solve
  // (infill never enters the solver, ARCHITECTURE §2). WITHOUT them, and with the
  // width-aware posture ARMED, the infill and wall levers are reported NOT
  // EVALUABLE rather than priced by the wrong (default-posture) law.
  std::vector<double> printed_von_mises;
  std::vector<double> printed_member_width_mm;

  // --- PR 271's orientation ranking (rows already priced by the real gate) ------
  const BuildOrientationReport* orientation = nullptr;

  // --- The material catalog (READ ONLY; never written) --------------------------
  const MaterialLibrary* materials = nullptr;
  // A material swap leaves the solved stress field alone ONLY if it does not
  // change Poisson's ratio: for a FORCE-driven linear elastic solve the modulus
  // cancels exactly (u ∝ 1/E, σ = D(E,ν)·B·u ∝ E·(1/E)), but ν does not. So a
  // candidate material is emitted only when its `poisson` equals the current
  // material's AND this flag is true — the caller sets it FALSE whenever any
  // Dirichlet BC prescribes a NON-ZERO displacement, which breaks the
  // cancellation. Candidates with a different ν are counted as needing a
  // re-solve and are never recommended.
  bool poisson_locked = true;

  // --- The rungs this run actually solved ---------------------------------------
  std::vector<GateSolvedRung> solved_rungs;
  double this_volume_fraction = 0.0;
};

// Diagnose ONE gate verdict.
//
// Deterministic and side-effect free. Reads only `in`; touches no global state;
// NEVER solves. Cost is a handful of gate_margin_effective evaluations (each a
// compute_stress_margin and a multiply) plus, in the width-aware posture, one
// pass over the printed-voxel pairs per candidate.
GateDiagnosis diagnose_gate(const GateDiagnosisInputs& in);

}  // namespace topopt

#endif  // TOPOPT_GATE_DIAGNOSIS_EVAL_HPP
