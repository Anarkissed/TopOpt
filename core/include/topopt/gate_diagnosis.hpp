#ifndef TOPOPT_GATE_DIAGNOSIS_HPP
#define TOPOPT_GATE_DIAGNOSIS_HPP

// gate_diagnosis — the DATA MODEL of a gate explanation, plus its JSON emitter
// (handoff 2026-08-02-gate-diagnosis-recommendations).
//
// *** NOTHING IN THIS FILE MOVES A VERDICT. *** A GateDiagnosis is written by
// diagnose_gate (gate_diagnosis_eval.hpp) from numbers the gate has ALREADY
// produced, and nothing downstream reads one to decide anything.
//
// WHY THE MODEL LIVES IN ITS OWN HEADER. `VariantReport` (report.hpp) carries a
// GateDiagnosis, and the EVALUATOR needs KnockdownSpec / Material from
// analyze.hpp — which itself includes report.hpp. Splitting the value types
// (here, dependency-free) from the evaluator (gate_diagnosis_eval.hpp, which
// includes analyze.hpp) breaks that cycle without a forward-declared pointer in
// the report.
//
// WHY IT EXISTS AT ALL. A real maintainer run (fingerprint 9f6738726016,
// WallMount bracket, 1.5 h) rejected every rung and told the user:
//
//   "The strongest variant's worst-case stress margin was 0.00x — below the 1.5x
//    safety minimum. Try a stronger material, a coarser resolution, or a lighter
//    load."
//
// Two faults in one sentence. (a) 0.00 was a max over an EMPTY array: the part's
// own worst-case margin was 2.7814 and the number the gate compared was 0.5759.
// (b) The advice was canned and mostly wrong — 2.7814 is nearly 2x the 1.5
// requirement, so the material is not the problem and the resolution is
// irrelevant. What rejected the part was the f^1.5 INFILL KNOCKDOWN at 35%
// infill: 2.7814 x 0.35^1.5 = 0.5759. The fix is infill, and the exact figure is
// computable AND checkable.
//
// *** THE LOAD-BEARING RULE: A RECOMMENDATION IS A MEASUREMENT, NOT A HEURISTIC.
// Every GateRecommendation that reaches this struct was produced by evaluating
// gate_margin_effective (analyze.hpp) — the expression PR 271 extracted VERBATIM
// out of analyze_fixed_design so a counterfactual verdict is computed by the REAL
// gate rather than a second copy that could drift — under the proposed change,
// and confirming the result clears margin_stop. Algebraic inversion picks a
// CANDIDATE; the candidate is then EVALUATED, and one that does not pass is
// DROPPED, not emitted. That distinction is not decorative: "try a stronger
// material" ranks by yield, and PA12_CF has a HIGHER yield than PLA (60 vs 55
// MPa) with a much lower z_knockdown (0.40 vs 0.55), so where the INTERLAYER
// term binds it is measurably WEAKER than the material it would replace. An
// inversion on yield recommends it; this module prices it and drops it.

#include <string>
#include <vector>

namespace topopt {

// WHICH TERM BINDS. Exactly one, decided from the gate's own arithmetic — never
// from the size of a number in isolation.
//
//   LoadPath   — the connectivity belt rejected the design. Nothing else on the
//                line is a strength statement and no print setting fixes it.
//   Knockdown  — the RAW worst-case margin clears margin_stop but the INFILL
//                KNOCKDOWN takes it under. This is the motivating case, and the
//                one the old canned string got completely wrong.
//   InPlane    — the raw worst-case margin is itself below required, with the
//                von Mises (in-plane) term as the min.
//   Interlayer — same, with the layer-bond term as the min.
//   MinFeature — the STRENGTH gate is satisfied and the §7 V3 min-feature
//                reliability check is what flags the part. The ONLY binding term
//                a RESOLUTION change is relevant to.
//   None       — nothing binds: the part passed, with headroom to report.
enum class GateTerm { None, LoadPath, InPlane, Interlayer, Knockdown, MinFeature };

// Stable lowercase snake_case names, for report.json and for tests.
const char* gate_term_name(GateTerm t);

// The candidate levers, in LEAST-INVASIVE-FIRST order — the order they are tried
// and the order recommendations are emitted in.
//
//   Infill           — free to change in the slicer; usually the right answer.
//   WallLoops        — a slicer setting too, but the DEFAULT gate posture is
//                      width-BLIND (walls are credited only when the width-aware
//                      knockdown is armed), so there this lever cannot move the
//                      gate and is reported inert rather than offered.
//   BuildOrientation — only when the INTERLAYER term binds, and only from PR
//                      271's ranking (a row already priced by the real gate).
//   VolumeFraction   — more material. Only rungs THIS RUN ACTUALLY SOLVED can be
//                      priced; a heavier rung the ladder never walked is a
//                      different design and needs a re-solve.
//   Material         — every catalog entry, evaluated through the gate. Emitted
//                      only when the swap leaves the solved stress field alone.
//   Resolution       — ONLY when MinFeature binds. Irrelevant to a stress-margin
//                      failure and never offered there.
//   Load             — LAST, and framed as changing the REQUIREMENT rather than
//                      fixing the part.
enum class GateLever {
  Infill, WallLoops, BuildOrientation, VolumeFraction, Material, Resolution, Load
};

const char* gate_lever_name(GateLever l);

// ONE recommendation. Every numeric field was produced by gate_margin_effective
// under the proposal — see the file header — except where
// `verified_through_gate` is explicitly false and `note` names the criterion
// that was used instead.
struct GateRecommendation {
  GateLever lever = GateLever::Infill;
  std::string parameter;        // the settable name, e.g. "infill_percent"
  double current_value = 0.0;   // what the run used
  double proposed_value = 0.0;  // what to change it to
  std::string proposed_label;   // human form: "66%", "PA12", "(0.000, 0.000, 1.000)"

  // *** THE VERIFICATION. *** `margin_effective_at_proposal` is
  // gate_margin_effective evaluated under this proposal, and `margin_required`
  // is the SAME margin_stop the real verdict used. A gate-priced recommendation
  // is emitted ONLY when the first is >= the second, so `verified_through_gate`
  // is true on every such row by construction. It is carried explicitly anyway
  // so a reader (and a test) can see the claim rather than infer it.
  //
  // `verified_through_gate == false` occurs for exactly one lever — Resolution —
  // whose quantity is the §7 V3 min-feature COUNT, not the stress margin. That
  // row states its own criterion in `note` and never borrows the gate's
  // authority.
  double margin_effective_at_proposal = 0.0;
  double margin_required = 0.0;
  bool verified_through_gate = false;

  // PROVENANCE TRAVELS WITH THE ADVICE. True when this recommendation's number
  // divides by `z_knockdown`, which ARCHITECTURE.md §6 says is seeded
  // conservative and human-tuned and which is UNSOURCED for every material.
  // When set, `provenance` carries the sentence that must be shown WITH the
  // number — an unsourced-constant-derived figure may not be presented with the
  // confidence of a measured one.
  bool inherits_unsourced_z_knockdown = false;
  std::string provenance;

  // Any further assumption the number rests on ("" when there is none).
  std::string note;
};

// What happened to one lever: was it evaluable at all, how many candidates were
// priced, did any pass. Reported for EVERY lever, including those that produced
// nothing — "tried and nothing passed" and "never tried" are different facts and
// a reader must be able to tell them apart.
struct GateLeverOutcome {
  GateLever lever = GateLever::Infill;
  // The lever can be priced through gate_margin_effective with NO re-solve.
  // false => nothing was emitted for it and `reason` says why.
  bool evaluable = false;
  int candidates_tried = 0;
  bool passed = false;
  std::string reason;  // why not evaluable, or why nothing passed
};

// The structured explanation of ONE gate verdict.
struct GateDiagnosis {
  bool evaluated = false;  // diagnose_gate ran (default-constructed => absent)
  bool accepted = false;   // the verdict being explained — an INPUT, echoed

  // --- WHICH TERM BINDS, and by how much -------------------------------------
  // `binding_value >= required_value` is the PASS sense for every term, so the
  // ratio always reads the same way. What the two quantities ARE depends on the
  // term (diagnose_gate documents each): the knockdown vs the knockdown needed;
  // a raw margin term vs the raw margin needed; a feature span in voxels vs the
  // §7 V3 floor; 0 vs 1 for a severed load path.
  GateTerm binding = GateTerm::None;
  double binding_value = 0.0;
  double required_value = 0.0;
  double ratio = 0.0;

  // --- THE TWO NUMBERS THE MOTIVATING DIALOG CONFLATED ------------------------
  // They differ by the infill knockdown (4.8x in the motivating run) and only one
  // of them explains the refusal, so BOTH are always carried. (Three doubles
  // rather than a StressMargin: this header must stay dependency-free — see the
  // header note on the include cycle.)
  double margin_in_plane = 0.0;
  double margin_interlayer = 0.0;
  double margin_worst_case = 0.0;  // the RAW solid margin   (2.7814)
  double margin_effective = 0.0;   // what the gate compared (0.5759)
  double knockdown_factor = 0.0;   // margin_effective / margin_worst_case (f^1.5)
  double infill_percent = 100.0;   // the run's infill (the knockdown's argument)
  int min_feature_violations = 0;

  // True when the LAYER-BOND term is the one the raw worst case landed on, so the
  // whole diagnosis — not just an individual recommendation — rests on the
  // unsourced z_knockdown.
  bool inherits_unsourced_z_knockdown = false;
  std::string provenance;

  // --- THE ADVICE -------------------------------------------------------------
  // Least-invasive first. EMPTY is a legitimate, and often the honest, answer.
  std::vector<GateRecommendation> recommendations;
  std::vector<GateLeverOutcome> levers;

  // *** WHEN NOTHING PASSES, SAY SO PLAINLY. *** True when every evaluable lever
  // was tried and no admissible candidate cleared the gate. `no_fix_reason` then
  // states the BINDING PHYSICAL QUANTITY — e.g. "even at 100% infill the raw
  // worst-case margin is 0.91x, below the required 1.5x; the binding physical
  // quantity is the peak tension across layer planes, ..." — instead of a list of
  // things to try.
  bool no_setting_fixes_this = false;
  std::string no_fix_reason;

  // --- HEADROOM, on an ACCEPTED part (the same machinery, run downward) --------
  // "passes at 35% infill; would still pass at 22%". Present only when the part
  // was accepted AND the infill lever was evaluable.
  bool headroom_evaluated = false;
  double headroom_min_infill_percent = 0.0;  // lowest infill that still passes
};

// Serialize a diagnosis as the report.json "diagnosis" object, nested at
// `indent`. Callers emit it ONLY when `evaluated` is true, so a run that did not
// diagnose keeps its document byte-for-byte.
void emit_gate_diagnosis(std::string& out, const GateDiagnosis& d,
                         const std::string& indent);

}  // namespace topopt

#endif  // TOPOPT_GATE_DIAGNOSIS_HPP
