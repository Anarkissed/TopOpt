// gate_diagnosis — see topopt/gate_diagnosis.hpp for WHAT this is and, more
// importantly, what it refuses to do.
//
// ONE RULE GOVERNS THIS WHOLE FILE: the only way a number reaches a
// GateRecommendation is through `price()` below, and `price()` is a thin wrapper
// over gate_margin_effective (analyze.hpp) — the function PR 271 extracted
// VERBATIM out of analyze_fixed_design precisely so a counterfactual verdict is
// computed by the REAL gate and not by a second copy that could drift. There is
// no other margin arithmetic in this translation unit. Algebra appears exactly
// once, to pick a starting CANDIDATE for the infill search; the candidate is then
// priced, and dropped if it does not pass.

#include "topopt/gate_diagnosis_eval.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <limits>
#include <string>
#include <vector>

#include "topopt/build_orientation.hpp"
#include "topopt/gate_diagnosis.hpp"

namespace topopt {

namespace {

// The sentence that must ride along with any number derived by dividing by
// z_knockdown (ARCHITECTURE.md §6: "Values are seeded conservative and
// human-tuned later"). It is UNSOURCED for every material in the catalog, so a
// figure that depends on it is not the same kind of claim as one that does not.
constexpr const char* kZKnockdownProvenance =
    "this figure divides by the material's z_knockdown (layer-bond factor), "
    "which is a seeded, conservative, human-tuned constant with no measured "
    "source for any material in the catalog (ARCHITECTURE.md §6). Treat it as "
    "an ordering, not a calibrated number.";

std::string fixed(double v, int places) {
  if (!std::isfinite(v)) return "unbounded";
  char buf[64];
  std::snprintf(buf, sizeof(buf), "%.*f", places, v);
  return std::string(buf);
}

// ---------------------------------------------------------------------------
// THE ONE PRICING PATH.
//
// A candidate change is described by a Proposal; `price()` turns it into the
// gate's own number by calling gate_margin_effective. NOTHING in this file
// computes a margin any other way.
// ---------------------------------------------------------------------------

struct Proposal {
  Material material;          // defaults to the run's material
  double infill_percent = 100.0;
  double wall_thickness_mm = 0.0;
  double max_von_mises = 0.0;
  double max_interlayer = 0.0;
};

struct Priced {
  double margin_effective = 0.0;
  bool passes = false;
  // The INTERLAYER term is the one the min lands on, i.e. this number divides by
  // z_knockdown. Recomputed per proposal because a material swap or an
  // orientation change can move which term governs.
  bool interlayer_governs = false;
  bool evaluable = true;  // false => the posture needs data the caller withheld
};

// The wall ring the slicer deposits, from a loop count. The ONE formula
// (production.cpp knockdown_spec_for): t = outer + (loops-1)*inner, with a
// negative outer meaning "mirror the inner width", and 0 loops meaning no ring.
double wall_thickness_for(int loops, double inner_w, double outer_w_or_neg) {
  if (loops <= 0) return 0.0;
  const double outer = outer_w_or_neg >= 0.0 ? outer_w_or_neg : inner_w;
  return outer + static_cast<double>(loops - 1) * inner_w;
}

// The width-aware posture's in-plane argument, repriced for a candidate
// (infill, wall ring) from the SAME per-voxel pairs the gate maxed over, using
// the SAME width_aware_knockdown function. No re-solve: the stress field does
// not depend on either setting (infill never enters the solver, ARCHITECTURE §2).
//
// Returns NaN when the caller did not supply the pairs — the signal that the
// lever is NOT EVALUABLE, which is reported rather than papered over with the
// default-posture law.
double reprice_max_vm_effective(const GateDiagnosisInputs& in, double infill,
                                double wall_t) {
  if (in.printed_von_mises.empty() ||
      in.printed_von_mises.size() != in.printed_member_width_mm.size())
    return std::numeric_limits<double>::quiet_NaN();
  double worst = 0.0;
  for (std::size_t e = 0; e < in.printed_von_mises.size(); ++e) {
    const double k =
        width_aware_knockdown(infill, in.printed_member_width_mm[e], wall_t);
    const double vm_eff = in.printed_von_mises[e] / k;
    if (vm_eff > worst) worst = vm_eff;
  }
  return worst;
}

Priced price(const GateDiagnosisInputs& in, const Proposal& p) {
  KnockdownSpec k = in.knockdown;
  k.infill_knockdown = infill_margin_knockdown(p.infill_percent);
  k.infill_percent = p.infill_percent;
  k.wall_thickness_mm = p.wall_thickness_mm;

  double vm_eff = p.max_von_mises;
  if (k.width_aware) {
    // The width-aware in-plane term is a per-voxel MAX, so it must be rebuilt
    // from the population whenever infill or the wall ring moves — and it is
    // rebuilt ALWAYS, including at the run's own settings, so that "the
    // diagnosis's price of the run itself" and "the gate's own number" are the
    // same arithmetic on the same data rather than two paths that could drift.
    // Only the pairs the gate itself maxed over can do that honestly; without
    // them the lever is NOT EVALUABLE and says so.
    vm_eff = reprice_max_vm_effective(in, p.infill_percent, p.wall_thickness_mm);
    if (!std::isfinite(vm_eff)) {
      Priced out;
      out.evaluable = false;
      return out;
    }
    // A load-scale proposal scales every voxel's stress by the same factor, so
    // the repriced max scales with it (width_aware_knockdown does not read the
    // stress). Apply that factor exactly rather than re-listing the pairs.
    if (in.max_von_mises > 0.0)
      vm_eff *= p.max_von_mises / in.max_von_mises;
  }

  Priced out;
  out.margin_effective =
      gate_margin_effective(p.material.yield_strength_mpa, p.material.z_knockdown,
                            p.max_von_mises, vm_eff, p.max_interlayer, k);
  out.passes = out.margin_effective >= in.margin_stop;
  // WHICH TERM the min landed on, from the same definition the gate uses.
  const StressMargin m = compute_stress_margin(
      p.material.yield_strength_mpa, p.material.z_knockdown,
      k.width_aware ? vm_eff : p.max_von_mises, p.max_interlayer);
  out.interlayer_governs = m.interlayer <= m.in_plane;
  return out;
}

// The SMALLEST integer infill percent in [lo, hi] whose PRICED margin clears the
// gate, or hi + 1 when none does. Every step is a real gate_margin_effective
// evaluation — this is a search over measurements, not a formula.
//
// A BISECTION is valid here because the gate is monotone non-decreasing in
// infill in BOTH postures: the scalar knockdown is f^1.5, and the width-aware
// per-voxel k = f_wall + (1-f_wall)·f^1.5 rises with f at every voxel, so the
// inflated in-plane max falls. Bisecting bounds the cost at ~log2(100) ≈ 7
// evaluations instead of up to 100, which matters in the width-aware posture
// where one evaluation is a pass over the printed set.
int smallest_passing_infill(const GateDiagnosisInputs& in, int lo, int hi,
                            int* tried) {
  if (lo > hi) return hi + 1;
  int best = hi + 1;
  while (lo <= hi) {
    const int mid = lo + (hi - lo) / 2;
    Proposal p;
    p.material = in.material;
    p.infill_percent = static_cast<double>(mid);
    p.wall_thickness_mm = in.knockdown.wall_thickness_mm;
    p.max_von_mises = in.max_von_mises;
    p.max_interlayer = in.max_interlayer;
    if (tried != nullptr) ++*tried;
    if (price(in, p).passes) {
      best = mid;
      hi = mid - 1;
    } else {
      lo = mid + 1;
    }
  }
  return best;
}

// The run's own proposal (nothing changed) — the identity the diagnosis
// cross-checks itself against.
Proposal as_run(const GateDiagnosisInputs& in) {
  Proposal p;
  p.material = in.material;
  p.infill_percent = in.infill_percent;
  p.wall_thickness_mm = in.knockdown.wall_thickness_mm;
  p.max_von_mises = in.max_von_mises;
  p.max_interlayer = in.max_interlayer;
  return p;
}

GateLeverOutcome outcome(GateLever l, bool evaluable, int tried, bool passed,
                         const std::string& reason) {
  GateLeverOutcome o;
  o.lever = l;
  o.evaluable = evaluable;
  o.candidates_tried = tried;
  o.passed = passed;
  o.reason = reason;
  return o;
}

// Attach the z_knockdown provenance to a recommendation whose number the
// interlayer term governs. Rule 6 of the handoff: provenance travels WITH the
// advice, never in a footnote a caller can drop.
void attach_provenance(GateRecommendation* r, const Priced& p) {
  if (!p.interlayer_governs) return;
  r->inherits_unsourced_z_knockdown = true;
  r->provenance = kZKnockdownProvenance;
}

}  // namespace

GateDiagnosis diagnose_gate(const GateDiagnosisInputs& in) {
  GateDiagnosis d;
  d.evaluated = true;
  d.accepted = in.accepted;
  d.margin_in_plane = in.margin.in_plane;
  d.margin_interlayer = in.margin.interlayer;
  d.margin_worst_case = in.margin.worst_case;
  d.margin_effective = in.margin_effective;
  d.infill_percent = in.infill_percent;
  d.min_feature_violations = in.min_feature_violations;
  d.knockdown_factor =
      (std::isfinite(in.margin.worst_case) && in.margin.worst_case > 0.0)
          ? in.margin_effective / in.margin.worst_case
          : in.knockdown.infill_knockdown;

  // ── WHICH TERM BINDS ───────────────────────────────────────────────────────
  // Decided from the gate's own arithmetic. The "would it pass at SOLID infill"
  // question is answered by pricing it, not by reasoning about it.
  Proposal solid = as_run(in);
  solid.infill_percent = 100.0;
  const Priced at_solid = price(in, solid);

  if (!in.load_path_ok) {
    d.binding = GateTerm::LoadPath;
    d.binding_value = 0.0;
    d.required_value = 1.0;
    d.ratio = 0.0;
  } else if (in.margin_effective < in.margin_stop) {
    if (at_solid.evaluable && at_solid.passes) {
      // *** THE MOTIVATING CASE. *** The part itself clears the requirement; the
      // INFILL KNOCKDOWN is what took it under. Report the knockdown against the
      // knockdown the part needs, so the two numbers are on one scale.
      d.binding = GateTerm::Knockdown;
      d.binding_value = d.knockdown_factor;
      d.required_value = (in.margin.worst_case > 0.0)
                             ? in.margin_stop / in.margin.worst_case
                             : std::numeric_limits<double>::infinity();
    } else {
      d.binding = (in.margin.interlayer <= in.margin.in_plane)
                      ? GateTerm::Interlayer
                      : GateTerm::InPlane;
      d.binding_value = (d.binding == GateTerm::Interlayer) ? in.margin.interlayer
                                                            : in.margin.in_plane;
      d.required_value = (d.knockdown_factor > 0.0)
                             ? in.margin_stop / d.knockdown_factor
                             : std::numeric_limits<double>::infinity();
    }
    d.ratio = (d.required_value > 0.0) ? d.binding_value / d.required_value : 0.0;
  } else if (in.min_feature_violations >= in.min_feature_warning_threshold &&
             in.min_feature_warning_threshold > 0) {
    // The STRENGTH gate is satisfied and the §7 V3 min-feature reliability check
    // is what flags the part. This is the ONE binding term a resolution change is
    // relevant to.
    d.binding = GateTerm::MinFeature;
    const bool measured = std::isfinite(in.min_member_thickness_mm) &&
                          in.min_member_thickness_mm > 0.0 &&
                          in.voxel_spacing_mm > 0.0;
    d.binding_value =
        measured ? in.min_member_thickness_mm / in.voxel_spacing_mm : 0.0;
    d.required_value = static_cast<double>(in.min_feature_voxels);
    d.ratio = (d.required_value > 0.0) ? d.binding_value / d.required_value : 0.0;
  } else {
    d.binding = GateTerm::None;
    d.binding_value = in.margin_effective;
    d.required_value = in.margin_stop;
    d.ratio = (in.margin_stop > 0.0) ? in.margin_effective / in.margin_stop : 0.0;
  }

  // Diagnosis-level provenance: whenever the LAYER-BOND term is the one the raw
  // worst case landed on, every margin figure downstream divides by z_knockdown.
  if (d.binding == GateTerm::Interlayer || d.binding == GateTerm::Knockdown ||
      d.binding == GateTerm::InPlane) {
    if (in.margin.interlayer <= in.margin.in_plane) {
      d.inherits_unsourced_z_knockdown = true;
      d.provenance = kZKnockdownProvenance;
    }
  }

  // ── A SEVERED LOAD PATH IS NOT A SETTINGS PROBLEM ──────────────────────────
  // No print setting reconnects a structure that carries nothing, so no lever is
  // tried and none is offered. Saying that plainly is the whole answer.
  if (d.binding == GateTerm::LoadPath) {
    d.no_setting_fixes_this = true;
    d.no_fix_reason =
        "the design has no connected path of printed material from the anchor to "
        "the load, so it carries nothing. The stress and margin on this line are "
        "measurements of a severed structure, not a strength result. No print "
        "setting reconnects it — the geometry (or the volume-fraction target) has "
        "to change.";
    d.levers.push_back(outcome(GateLever::Infill, false, 0, false,
                               "not tried: the load path is severed, so the "
                               "strength gate is not what rejected this design"));
    return d;
  }

  const bool need_fix = !in.accepted || d.binding == GateTerm::MinFeature;

  // ── LEVER 1: INFILL ────────────────────────────────────────────────────────
  // The least invasive change there is, and in the motivating case the right
  // one. Algebra picks the CANDIDATE; the gate decides.
  bool infill_evaluable = true;
  {
    // Does the posture allow pricing an infill change at all?
    Proposal probe = as_run(in);
    probe.infill_percent = std::min(100.0, in.infill_percent + 1.0);
    infill_evaluable = price(in, probe).evaluable;
  }
  if (!need_fix) {
    // Accepted: run the same machinery DOWNWARD and report the headroom.
    if (infill_evaluable && in.infill_percent > 0.0) {
      int tried = 0;
      const int here = static_cast<int>(std::ceil(in.infill_percent));
      // Nothing below the run's own infill may pass; then the honest headroom is
      // "none" — the run is already at the floor — and that is `here`.
      const int found = smallest_passing_infill(
          in, 1, static_cast<int>(std::floor(in.infill_percent)), &tried);
      const int lowest = std::min(found, here);
      d.headroom_evaluated = true;
      d.headroom_min_infill_percent = static_cast<double>(lowest);
      d.levers.push_back(outcome(
          GateLever::Infill, true, tried, true,
          "accepted at " + fixed(in.infill_percent, 0) + "% infill; the gate "
          "still passes down to " + std::to_string(lowest) + "%"));
    } else {
      d.levers.push_back(outcome(GateLever::Infill, infill_evaluable, 0, false,
                                 infill_evaluable
                                     ? "no headroom to report"
                                     : "the width-aware posture is armed but the "
                                       "caller supplied no per-voxel (stress, "
                                       "member width) pairs, so a candidate "
                                       "infill cannot be repriced without a "
                                       "re-solve"));
    }
  } else if (!infill_evaluable) {
    d.levers.push_back(outcome(
        GateLever::Infill, false, 0, false,
        "NOT EVALUABLE: the width-aware knockdown posture is armed but the "
        "caller supplied no per-voxel (stress, member width) pairs, so the "
        "in-plane term cannot be repriced for a candidate infill without a "
        "re-solve. Nothing is recommended rather than priced by the wrong law."));
  } else if (in.infill_percent >= 100.0) {
    d.levers.push_back(outcome(GateLever::Infill, true, 0, false,
                               "already at 100% infill — the knockdown is "
                               "already exactly 1.0 and cannot be raised"));
  } else {
    // The ALGEBRAIC CANDIDATE: invert the f^1.5 seed curve for the knockdown the
    // part needs. This is a STARTING POINT ONLY — see the file header.
    double f0 = in.infill_percent;
    if (std::isfinite(in.margin.worst_case) && in.margin.worst_case > 0.0) {
      const double k_needed = in.margin_stop / in.margin.worst_case;
      if (k_needed > 0.0) f0 = 100.0 * std::pow(k_needed, 2.0 / 3.0);
    }
    int start = static_cast<int>(std::ceil(f0));
    const int floor_start = static_cast<int>(std::floor(in.infill_percent)) + 1;
    if (start < floor_start) start = floor_start;
    if (start < 1) start = 1;
    int tried = 0;
    bool passed = false;
    // *** INVERT, THEN EVALUATE. *** Price the algebraic candidate. If it passes
    // it IS the answer (one gate evaluation, the common case). If it does NOT —
    // which is exactly what an inversion-only implementation would ship — bisect
    // upward for the smallest integer infill that really does clear the gate, and
    // if nothing up to 100% does, emit NOTHING.
    int chosen = 0;
    {
      Proposal p0 = as_run(in);
      p0.infill_percent = static_cast<double>(start);
      ++tried;
      chosen = price(in, p0).passes
                   ? start
                   : smallest_passing_infill(in, start + 1, 100, &tried);
    }
    if (chosen >= start && chosen <= 100) {
      // FINAL CONFIRMATION: price the value that is about to be emitted, and emit
      // it ONLY if this evaluation passes. Nothing reaches a user on the strength
      // of the search's bookkeeping alone.
      Proposal p = as_run(in);
      p.infill_percent = static_cast<double>(chosen);
      const Priced pr = price(in, p);
      if (pr.passes) {
        GateRecommendation r;
        r.lever = GateLever::Infill;
        r.parameter = "infill_percent";
        r.current_value = in.infill_percent;
        r.proposed_value = static_cast<double>(chosen);
        r.proposed_label = std::to_string(chosen) + "%";
        r.margin_effective_at_proposal = pr.margin_effective;
        r.margin_required = in.margin_stop;
        r.verified_through_gate = true;
        attach_provenance(&r, pr);
        r.note = "the stress field does not depend on infill (infill never "
                 "enters the solver), so this is the real gate's verdict at " +
                 std::to_string(chosen) + "% infill, not an extrapolation";
        d.recommendations.push_back(r);
        passed = true;
      }
    }
    d.levers.push_back(outcome(
        GateLever::Infill, true, tried, passed,
        passed ? "" : "no infill up to 100% clears the gate: at solid infill the "
                      "worst-case margin is " + fixed(in.margin.worst_case, 4) +
                      "x against the required " + fixed(in.margin_stop, 2) + "x"));
  }

  // ── LEVER 2: WALL LOOPS ────────────────────────────────────────────────────
  // A slicer setting like infill, but the DEFAULT gate posture is width-BLIND:
  // gate_margin_effective never reads wall_thickness_mm unless width_aware is
  // armed. Recommending more walls there would be recommending something the
  // gate cannot see, so it is reported as inert rather than offered.
  if (!need_fix) {
    // nothing to say on an accepted part
  } else if (!in.knockdown.width_aware) {
    d.levers.push_back(outcome(
        GateLever::WallLoops, true, 1, false,
        "INERT IN THIS POSTURE: the width-aware knockdown is not armed, so the "
        "gate credits wall loops with exactly nothing (gate_margin_effective "
        "never reads wall_thickness_mm on the scalar path). More walls would "
        "make the part stronger in reality and would not move this verdict by "
        "one bit, so nothing is recommended."));
  } else {
    int tried = 0;
    bool passed = false;
    for (int loops = in.wall_loops + 1; loops <= in.wall_loops + 8; ++loops) {
      Proposal p = as_run(in);
      p.wall_thickness_mm =
          wall_thickness_for(loops, in.wall_line_width_mm,
                             in.wall_line_width_outer_mm);
      const Priced pr = price(in, p);
      if (!pr.evaluable) break;
      ++tried;
      if (!pr.passes) continue;
      GateRecommendation r;
      r.lever = GateLever::WallLoops;
      r.parameter = "wall_loops";
      r.current_value = static_cast<double>(in.wall_loops);
      r.proposed_value = static_cast<double>(loops);
      r.proposed_label = std::to_string(loops) + " loops";
      r.margin_effective_at_proposal = pr.margin_effective;
      r.margin_required = in.margin_stop;
      r.verified_through_gate = true;
      attach_provenance(&r, pr);
      r.note = "walls are credited on the in-plane term only — 191/192 measured "
               "axial and bending, never z-bonding — so this cannot rescue an "
               "interlayer-bound part";
      d.recommendations.push_back(r);
      passed = true;
      break;
    }
    d.levers.push_back(outcome(
        GateLever::WallLoops, tried > 0, tried, passed,
        passed ? "" : "no wall count within +8 loops clears the gate"));
  }

  // ── LEVER 3: BUILD ORIENTATION ─────────────────────────────────────────────
  // ONLY when the INTERLAYER term binds — it is the one term the build direction
  // moves at all — and ONLY from PR 271's ranking. The row's `margin_effective`
  // and `would_be_accepted` were computed by gate_margin_effective inside the
  // scorer, so this lever consumes a verdict that already exists; it never
  // invents one.
  const bool interlayer_binds =
      d.binding == GateTerm::Interlayer ||
      (d.binding == GateTerm::Knockdown &&
       in.margin.interlayer <= in.margin.in_plane);
  if (!need_fix) {
    // nothing to say on an accepted part
  } else if (!interlayer_binds) {
    d.levers.push_back(outcome(
        GateLever::BuildOrientation, true, 0, false,
        "not offered: the build direction enters the gate through the "
        "INTERLAYER term alone, and that term is not what binds here"));
  } else if (in.orientation == nullptr || !in.orientation->evaluated ||
             in.orientation->candidates.empty()) {
    d.levers.push_back(outcome(
        GateLever::BuildOrientation, false, 0, false,
        "NOT EVALUABLE: the build-orientation ranking was not armed on this run, "
        "so no candidate orientation has been priced by the gate. Guessing one "
        "is not acceptable; re-run with the ranking armed."));
  } else {
    // The ranking's OWN gate-constrained pick (score_build_orientations'
    // `auto_applied_index`: the maximin restricted to candidates that would be
    // ACCEPTED). Taking any other row would be second-guessing the scorer.
    const BuildOrientationReport& br = *in.orientation;
    const std::size_t idx = std::min(br.auto_applied_index, br.candidates.size() - 1);
    const OrientationCriteria& c = br.candidates[idx];
    const bool differs = idx != br.as_built_index;
    if (c.would_be_accepted && differs) {
      GateRecommendation r;
      r.lever = GateLever::BuildOrientation;
      r.parameter = "build_direction";
      r.proposed_value = static_cast<double>(idx);
      r.proposed_label = "(" + fixed(c.build_dir.x, 3) + ", " +
                         fixed(c.build_dir.y, 3) + ", " +
                         fixed(c.build_dir.z, 3) + ")";
      r.margin_effective_at_proposal = c.margin_effective;
      r.margin_required = in.margin_stop;
      r.verified_through_gate = true;
      r.inherits_unsourced_z_knockdown = true;
      r.provenance = kZKnockdownProvenance;
      r.note = "from the build-orientation ranking's own gate-constrained pick "
               "(candidate " + std::to_string(idx) + " of " +
               std::to_string(br.candidates.size()) + "); its margin was priced "
               "by the same gate expression this verdict came from";
      d.recommendations.push_back(r);
      d.levers.push_back(outcome(GateLever::BuildOrientation, true, 1, true, ""));
    } else {
      d.levers.push_back(outcome(
          GateLever::BuildOrientation, true, 1, false,
          differs ? "the ranking's gate-constrained pick still does not clear the "
                    "gate, so no orientation is recommended"
                  : "the ranking already points at the orientation this run "
                    "built, so there is nothing to change"));
    }
  }

  // ── LEVER 4: A HEAVIER VOLUME-FRACTION RUNG ────────────────────────────────
  // Only rungs THIS RUN ACTUALLY SOLVED can be priced: a heavier rung the ladder
  // never walked is a different design, and pricing it needs a full re-solve.
  // That limit is REPORTED, not worked around.
  if (need_fix) {
    int tried = 0;
    bool passed = false;
    const GateSolvedRung* best = nullptr;
    for (const GateSolvedRung& r : in.solved_rungs) {
      if (r.volume_fraction <= in.this_volume_fraction) continue;
      ++tried;
      if (!r.accepted) continue;
      if (best == nullptr || r.volume_fraction < best->volume_fraction) best = &r;
    }
    if (best != nullptr) {
      GateRecommendation r;
      r.lever = GateLever::VolumeFraction;
      r.parameter = "volume_fraction";
      r.current_value = in.this_volume_fraction;
      r.proposed_value = best->volume_fraction;
      r.proposed_label = fixed(best->volume_fraction, 3);
      r.margin_effective_at_proposal = best->margin_effective;
      r.margin_required = in.margin_stop;
      r.verified_through_gate = true;
      r.note = "this rung was SOLVED and gated in this same run — the margin is "
               "its own measured verdict, not an extrapolation";
      d.recommendations.push_back(r);
      passed = true;
    }
    d.levers.push_back(outcome(
        GateLever::VolumeFraction, true, tried, passed,
        passed ? ""
               : "no heavier rung this run solved was accepted. A rung HEAVIER "
                 "than the ladder's top is a different design and pricing it "
                 "needs a full re-solve, so none is offered."));
  }

  // ── LEVER 5: MATERIAL ──────────────────────────────────────────────────────
  // *** WHERE INVERSION AND MEASUREMENT DISAGREE. *** "Try a stronger material"
  // ranks by yield. The gate's interlayer term is (z_knockdown * yield) /
  // tension, so a higher-yield material with a lower z_knockdown is measurably
  // WEAKER where that term binds. Every catalog entry is priced; only entries
  // that PASS and that leave the solved field alone are emitted.
  if (need_fix && d.binding != GateTerm::MinFeature) {
    if (in.materials == nullptr) {
      d.levers.push_back(outcome(
          GateLever::Material, false, 0, false,
          "NOT EVALUABLE: no material catalog was supplied to the diagnosis"));
    } else {
      int tried = 0, passed_but_needs_resolve = 0;
      bool passed = false;
      for (const auto& kv : *in.materials) {
        if (kv.first == in.material_name) continue;
        Proposal p = as_run(in);
        p.material = kv.second;
        const Priced pr = price(in, p);
        if (!pr.evaluable) continue;
        ++tried;
        if (!pr.passes) continue;  // e.g. a HIGHER yield with a lower z_knockdown
        // It passes the gate. Is the gate's INPUT still valid under the swap?
        // For a force-driven linear solve the modulus cancels exactly, but
        // Poisson's ratio does not: a different nu is a different stress field,
        // and confirming it costs a re-solve.
        if (!in.poisson_locked || kv.second.poisson != in.material.poisson) {
          ++passed_but_needs_resolve;
          continue;
        }
        GateRecommendation r;
        r.lever = GateLever::Material;
        r.parameter = "material";
        r.proposed_value = kv.second.yield_strength_mpa;
        r.proposed_label = kv.first;
        r.margin_effective_at_proposal = pr.margin_effective;
        r.margin_required = in.margin_stop;
        r.verified_through_gate = true;
        attach_provenance(&r, pr);
        r.note = "same Poisson ratio as " + in.material_name +
                 ", and the modulus cancels in a force-driven linear solve, so "
                 "this run's stress field is exactly the stress field this "
                 "material would produce";
        d.recommendations.push_back(r);
        passed = true;
      }
      std::string why;
      if (!passed) {
        why = "no catalog material clears the gate on this run's stress field";
        if (passed_but_needs_resolve > 0)
          why = std::to_string(passed_but_needs_resolve) +
                " material(s) would clear the gate but carry a DIFFERENT "
                "Poisson ratio, which changes the stress field. Confirming them "
                "costs a full re-solve, so none is recommended.";
      }
      d.levers.push_back(
          outcome(GateLever::Material, true, tried, passed, why));
    }
  }

  // ── LEVER 6: RESOLUTION ────────────────────────────────────────────────────
  // *** ONLY WHEN MIN-FEATURE BINDS. *** A resolution change is irrelevant to a
  // stress-margin failure, and the canned string this task replaces offered it
  // there. Note the DIRECTION too: the §7 V3 floor is "at least 2 voxels", so a
  // FINER grid clears it; the old copy said "coarser", which makes it worse.
  if (need_fix && d.binding != GateTerm::MinFeature) {
    d.levers.push_back(outcome(
        GateLever::Resolution, true, 0, false,
        "not offered: this is a strength-margin verdict and the voxel resolution "
        "is not one of its terms. The min-feature count on this line is advisory "
        "and did not cause the rejection."));
  } else if (d.binding == GateTerm::MinFeature) {
    const bool measured = std::isfinite(in.min_member_thickness_mm) &&
                          in.min_member_thickness_mm > 0.0 &&
                          in.voxel_spacing_mm > 0.0 && in.min_feature_voxels > 0;
    if (!measured) {
      d.levers.push_back(outcome(
          GateLever::Resolution, false, 0, false,
          "NOT EVALUABLE: the thinnest printed member was not measured on this "
          "run, so the spacing that would clear the 2-voxel floor cannot be "
          "computed without re-running the design"));
    } else {
      // The §7 V3 min-feature criterion itself, evaluated on the MEASURED
      // thinnest member: a feature spans >= min_feature_voxels iff
      // thickness >= min_feature_voxels * spacing.
      const double needed_spacing =
          in.min_member_thickness_mm / static_cast<double>(in.min_feature_voxels);
      GateRecommendation r;
      r.lever = GateLever::Resolution;
      r.parameter = "voxel_spacing_mm";
      r.current_value = in.voxel_spacing_mm;
      r.proposed_value = needed_spacing;
      r.proposed_label = fixed(needed_spacing, 3) + " mm or finer";
      // This lever is NOT priced by gate_margin_effective — the quantity it moves
      // is the V3 min-feature count, not the stress margin — so it does not claim
      // the strength gate's verification. It carries the V3 criterion's own
      // arithmetic instead, and says so.
      r.margin_effective_at_proposal = in.margin_effective;
      r.margin_required = in.margin_stop;
      r.verified_through_gate = false;
      r.note = "checked against the §7 V3 min-feature criterion (feature span >= " +
               std::to_string(in.min_feature_voxels) + " voxels) on THIS design's "
               "measured thinnest member (" + fixed(in.min_member_thickness_mm, 3) +
               " mm), not against the strength gate — the strength gate already "
               "passes. Assumes a finer run reproduces at least this geometry; "
               "the optimizer may converge somewhere else.";
      d.recommendations.push_back(r);
      d.levers.push_back(outcome(GateLever::Resolution, true, 1, true, ""));
    }
  }

  // ── LEVER 7: A LIGHTER LOAD ────────────────────────────────────────────────
  // LAST, and framed for what it is: changing the REQUIREMENT, not fixing the
  // part. Stress is linear in the applied load for a force-driven linear elastic
  // solve, so a candidate scale is priced exactly by scaling the two stress
  // arguments — no re-solve.
  if (need_fix && d.binding != GateTerm::MinFeature) {
    int tried = 0;
    bool passed = false;
    for (int pct = 95; pct >= 5; pct -= 5) {
      const double s = pct / 100.0;
      Proposal p = as_run(in);
      p.max_von_mises = in.max_von_mises * s;
      p.max_interlayer = in.max_interlayer * s;
      const Priced pr = price(in, p);
      if (!pr.evaluable) break;
      ++tried;
      if (!pr.passes) continue;
      GateRecommendation r;
      r.lever = GateLever::Load;
      r.parameter = "applied_load_scale";
      r.current_value = 1.0;
      r.proposed_value = s;
      r.proposed_label = std::to_string(pct) + "% of the declared load";
      r.margin_effective_at_proposal = pr.margin_effective;
      r.margin_required = in.margin_stop;
      r.verified_through_gate = true;
      attach_provenance(&r, pr);
      r.note = "THIS CHANGES THE REQUIREMENT, NOT THE PART. It is only honest "
               "advice if the declared load was itself an over-estimate.";
      d.recommendations.push_back(r);
      passed = true;
      break;
    }
    if (tried > 0 || !passed)
      d.levers.push_back(outcome(
          GateLever::Load, tried > 0, tried, passed,
          passed ? "" : "even at 5% of the declared load the gate does not pass"));
  }

  // ── WHEN NOTHING PASSES, SAY SO PLAINLY ────────────────────────────────────
  if (need_fix && d.recommendations.empty()) {
    d.no_setting_fixes_this = true;
    if (d.binding == GateTerm::MinFeature) {
      d.no_fix_reason =
          "the strength gate passes; what is flagged is the §7 V3 min-feature "
          "check, and the thinnest printed member was not measured on this run, "
          "so no spacing can be named.";
    } else if (!at_solid.evaluable) {
      d.no_fix_reason =
          "no lever could be priced through the real gate without a re-solve on "
          "this run's posture — see the per-lever reasons.";
    } else if (!at_solid.passes) {
      // The physical statement, not a list of things to try.
      const bool il = in.margin.interlayer <= in.margin.in_plane;
      d.no_fix_reason =
          std::string("no print setting fixes this: even at 100% infill the raw "
                      "worst-case margin is ") +
          fixed(in.margin.worst_case, 4) + "x, below the required " +
          fixed(in.margin_stop, 2) + "x. The binding physical quantity is the " +
          (il ? "peak tension across layer planes, " + fixed(in.max_interlayer, 4) +
                    " MPa against a layer-bond allowable of " +
                    fixed(in.material.z_knockdown * in.material.yield_strength_mpa, 4) +
                    " MPa"
              : "peak von Mises stress, " + fixed(in.max_von_mises, 4) +
                    " MPa against a yield of " +
                    fixed(in.material.yield_strength_mpa, 4) + " MPa") +
          ". The part has to carry less load, or be a different shape.";
    } else {
      d.no_fix_reason =
          "every lever was evaluated through the real gate and none of the "
          "admissible candidates passed — see the per-lever reasons.";
    }
  }

  return d;
}

}  // namespace topopt
