#ifndef TOPOPT_BUILD_ORIENTATION_HPP
#define TOPOPT_BUILD_ORIENTATION_HPP

// build_orientation — RANK candidate build directions against ONE already-solved
// certification field (handoff 2026-08-01-build-direction-separation).
//
// WHAT THIS IS. A POST-PASS, not an optimizer. PR 266 proved that the build
// direction enters a certification ONLY after the solve — the element stiffness
// (isotropic hex8, or the lattice's homogenized cubic tensor) never reads it — so
// one solved stress field answers the orientation question for every candidate
// EXACTLY. That was measured, not argued: 15 full re-solves across 3 cases
// returned a bit-identical stress/displacement/von-Mises field and every
// criterion agreed to the last bit. The whole 26-candidate sweep cost 0.5 ms at
// resolution 32 and 1.6 ms at 48 — 0.1% to 0.4% of the single certification solve
// it rides on.
//
// THE TRIPWIRE THAT WOULD END THAT. `hex8_stiffness_transverse` (the
// layer-anisotropic element) exists in core with zero production callers. If it
// is ever armed in the solve, the solved field starts depending on the build
// direction and this post-pass becomes 26 certifications instead of one. That
// arming is currently BLOCKED-STOP (handoff 2026-07-29-layer-anisotropy-fea: no
// measured transverse-isotropic constants for ASA/PETG). The day it lifts, the
// economics here must be re-derived, not inherited.
//
// *** IT IS A RECOMMENDATION. IT NEVER MOVES A VERDICT. ***
// The gate's `accepted` / `margin_effective` are computed from the orientation
// ACTUALLY USED and sealed BEFORE this runs; nothing here can write to them.
// When the recommended orientation would gate differently, the report says so in
// both directions (`verdict_would_change`, plus per-candidate `would_be_accepted`)
// and the user chooses. Certifying against an orientation the user did not choose
// is the "the number describes a different object than the file" failure this
// project has spent weeks eliminating.
//
// SIX CRITERIA, NEVER COLLAPSED TO ONE NUMBER. PR 266's S3 measured that they
// genuinely disagree (S-e wants a <110> edge; everything else wants a cube axis)
// and that a single weighted sum would launder that trade-off away. Every
// criterion is reported separately; `recommended_index` is a maximin over the
// MOVING criteria, published alongside the rows rather than instead of them.

#include <array>
#include <cstddef>
#include <string>
#include <vector>

#include "topopt/build_frame.hpp"  // BuildFrameRotation (the baked export frame)
#include "topopt/materials.hpp" // Material
#include "topopt/mesh.hpp"      // Vec3
#include "topopt/voxel.hpp"     // VoxelGrid

namespace topopt {

// Forward-declared, NOT included: analyze.hpp includes THIS header (so
// FixedDesignAnalysis can carry a BuildOrientationReport), and a pointer/
// reference is all the declarations below need. build_orientation.cpp includes
// analyze.hpp for the definitions.
struct KnockdownSpec;
struct LatticePosture;

// "Within this many degrees of the build plate" counts as a HORIZONTAL strut
// (S-e). A horizontal strut inside a lattice categorically needs support the
// lattice interior cannot give it. PR 266's instrument constant, kept identical
// so the production numbers are comparable to the probe's.
constexpr double kHorizontalStrutDeg = 10.0;

// One candidate build direction, scored on PR 266's six criteria against the ONE
// solved field. Criteria that do not apply (no lattice region, no measured strut
// law) are left at their defaults with their `*_evaluated` flag false — reported
// as absent, never as zero.
struct OrientationCriteria {
  Vec3 build_dir{0.0, 0.0, 1.0};   // unit
  bool on_cube_axis = false;       // exactly one nonzero component (to 1e-12)

  // --- S-a: support-material proxy (support_overhang_voxels, M4.3) -----------
  int support_voxels = 0;

  // --- S-b: the MACRO interlayer term and the gate's own numbers -------------
  double macro_interlayer_tension_mpa = 0.0;  // max_interlayer_tension at this dir
  double macro_interlayer_margin = 0.0;       // (z_knockdown*yield)/tension
  double macro_worst_case_margin = 0.0;       // min(in-plane, interlayer)
  // The GATE's number and verdict AS THEY WOULD BE at this orientation, computed
  // with the identical expression analyze_fixed_design used for the real one (the
  // same KnockdownSpec, the same margin_stop, the same load-path belt). This is
  // what makes "as built: REJECTED; as recommended (+z): ACCEPTED" a measured
  // statement rather than a guess — and it is REPORTED, never assigned back.
  double margin_effective = 0.0;
  bool would_be_accepted = false;

  // --- S-c / S-d: the strut law (PR 263's callable evaluator) ----------------
  // Only when a lattice posture with a measured law (octet) covered >= 1 voxel.
  bool strut_evaluated = false;
  double strut_in_plane_margin = 0.0;    // S-c — INVARIANT in build_dir (U7)
  double strut_interlayer_margin = 0.0;  // S-d
  double strut_il_bound_mpa = 0.0;
  double strut_il_cross_factor = 0.0;    // 0 exactly on a lattice cube axis

  // --- S-e: the strut-angle population, measured from the real generator -----
  bool strut_angles_evaluated = false;
  double horizontal_strut_length_fraction = 0.0;  // phi <= kHorizontalStrutDeg
  double flattest_strut_deg = 0.0;                // the lowest strut family
  double mean_strut_deg = 0.0;                    // length-weighted elevation

  // --- S-f: printability in the BUILD frame ----------------------------------
  int min_feature_violations = 0;        // the V3 count — does NOT move (U7-ish)
  int build_height_layers = 0;           // layer count along build_dir
  int first_layer_footprint_voxels = 0;  // plate adhesion proxy
};

// The ranking, the recommendation, and the honesty accounting around them.
struct BuildOrientationReport {
  bool evaluated = false;  // the scorer ran (options.build_orientation_report)

  // One row per candidate, in candidate order. Row `as_built_index` is the
  // orientation the verdict on this analysis actually describes.
  std::vector<OrientationCriteria> candidates;
  std::size_t as_built_index = 0;
  std::size_t recommended_index = 0;

  // true when NO explicit build direction reached the core and the documented
  // gravity fallback supplied it (resolve_build_direction_is_inferred). A receipt
  // must say "build direction ASSUMED from gravity" in that case rather than
  // presenting an inference as a user choice — PR 266's S5 point 3.
  bool build_direction_inferred = false;

  // ── AUTO-APPLY (handoff 2026-08-01-bake-build-orientation) ─────────────────
  // *** WHEN THIS IS TRUE THE RECOMMENDATION WAS APPLIED, AND IT MAY HAVE MOVED
  // THE VERDICT. *** It can only ever be true when NO build direction was
  // declared — `build_direction_inferred` above is then necessarily true — so it
  // never overrides a choice the user made. `as_built_index` points at the
  // APPLIED orientation (the one the verdict and the exported file both
  // describe), which keeps the U5 invariant "the reported verdict is the
  // as-built row's verdict" exactly as it was.
  //
  // PR 271's U5 discipline is not weakened here, it is INVERTED: a silent
  // auto-apply would be the same failure as a silent verdict flip, so the
  // receipt is REQUIRED to name the orientation, say it was chosen
  // automatically, and — when `auto_apply_changed_verdict` — say that the
  // orientation the run would otherwise have used gates differently.
  bool auto_applied = false;
  // The row auto-apply WOULD take / DID take. It is NOT always
  // `recommended_index`, and the difference is the single most important thing
  // to understand about this feature.
  //
  // *** THE GATE IS A CONSTRAINT; THE SIX CRITERIA ARE THE OBJECTIVE. ***
  // `recommended_index` is PR 271's pure maximin over the six criteria, and it
  // is deliberately NOT the margin-maximiser — the criteria genuinely disagree,
  // and support material and print height are real costs worth trading margin
  // for. That is the right rule for a RECOMMENDATION a human reads. It is the
  // wrong rule for a CHOICE MADE ON THE USER'S BEHALF, because it can pick an
  // orientation that FAILS the gate on a part that would have passed — measured,
  // not hypothetical: on the design-box fixture the unconstrained pick cost a
  // whole accepted ladder rung (2 rungs -> 1).
  //
  // So auto-apply maximins over the candidates that WOULD BE ACCEPTED, and falls
  // back to the unconstrained pick only when NO candidate passes (there is then
  // no verdict to protect). The as-inferred direction is always candidate 0, so
  // if the inferred orientation passes, at least one candidate passes — which
  // gives the property the whole design rests on:
  //
  //   AUTO-APPLY IS VERDICT-MONOTONE. It can never turn an orientation that
  //   WOULD HAVE BEEN ACCEPTED into a REJECTED one. Asserted in
  //   analyze_fixed_design, not merely intended.
  //
  // Nothing about `recommended_index` changes: it is still published, still the
  // pure maximin, and when the two differ the receipt says so and prints both.
  std::size_t auto_applied_index = 0;
  // The gate constraint BOUND: the accepted-subset maximin is a different row
  // from the unconstrained recommendation. Reported so the trade-off is visible
  // rather than resolved in silence.
  bool auto_apply_constrained_by_gate = false;
  // The row the DOCUMENTED GRAVITY FALLBACK pointed at: what this run would have
  // certified and exported had the orientation not been chosen. Equal to
  // `as_built_index` when nothing was applied. Kept so the receipt can state the
  // counterfactual with a measured number rather than an adjective.
  std::size_t as_inferred_index = 0;
  // The applied orientation gates DIFFERENTLY from the as-inferred one. When the
  // applied one ACCEPTS and the as-inferred one REJECTS, the auto-apply is the
  // reason the part passes, and the receipt says exactly that.
  bool auto_apply_changed_verdict = false;

  // The recommendation is a different direction from the one built.
  bool recommendation_differs = false;
  // *** The recommendation would gate DIFFERENTLY from what was built. When this
  // is true the receipt must state BOTH verdicts explicitly. The verdict that
  // stands is always the as-built one. ***
  bool verdict_would_change = false;

  // --- U7 self-checks, run in PRODUCTION (not just in the probe) -------------
  // PR 266's S2 invariants. If either drifts, the production wiring is wrong:
  // the strut IN-PLANE margin cannot move with build direction (it is a
  // deviatoric+pressure bound with no direction in it), and the six cube axes
  // must give an IDENTICAL strut INTERLAYER bound (cubic symmetry, pinned by
  // PR 259's uni_x == uni_z check). Reported so a receipt can carry them, and
  // asserted by test_build_direction.
  bool strut_in_plane_invariant = true;
  bool cube_axes_strut_interlayer_identical = true;
  int cube_axes_scored = 0;

  // Measured cost of the sweep itself (bar U3), excluding the one-off strut-axis
  // measurement below, so it is directly comparable to PR 266's 0.5 / 1.6 ms.
  double sweep_seconds = 0.0;
  double strut_axis_measure_seconds = 0.0;
};

// The already-computed certification facts the post-pass re-reads. Every member
// is something analyze_fixed_design has ALREADY produced for the orientation it
// solved; nothing here is recomputed and nothing is re-solved. Held by reference
// because this is a transient built at the call site.
struct BuildOrientationSolveFacts {
  const VoxelGrid& grid;          // the solved grid
  const VoxelGrid& printed_grid;  // `grid` with non-printed voxels marked Empty
  // The solve's Cauchy stress in BOTH shapes the production evaluators want:
  // `stress` (per-voxel Voigt array) for max_interlayer_tension, and the
  // flattened field for evaluate_strut_strength. Both already exist at the call
  // site, so passing both costs nothing and avoids a 6N repack per report.
  const std::vector<std::array<double, 6>>& stress;
  const std::vector<double>& stress_tensor_field;
  double max_von_mises = 0.0;            // in-plane term, direction-independent
  double max_von_mises_effective = 0.0;  // width-aware in-plane; == above otherwise
  int min_feature_violations = 0;        // from the V3 suite already run
  // Lattice posture, or nullptr. Without one, S-c/S-d/S-e are reported absent.
  const LatticePosture* lattice = nullptr;
  const std::vector<char>* lattice_mask = nullptr;  // the analysis's own mask
  std::size_t lattice_voxels = 0;
};

// Rank `candidates` against the solved field in `facts`.
//
//   as_built     — the orientation the caller's verdict describes. MUST appear in
//                  `candidates` (build_orientation_candidates puts it first);
//                  throws if it does not, because a report that could not point
//                  at what was built could not honour U5.
//   material     — yield / z_knockdown for the margins.
//   knockdown, margin_stop, load_path_ok
//                — the gate posture, so each candidate's `margin_effective` and
//                  `would_be_accepted` are computed by the IDENTICAL expression
//                  the real gate used.
//   inferred     — resolve_build_direction_is_inferred(options).
//
// Deterministic. Throws std::invalid_argument on an empty candidate set, a
// candidate that is not unit-normalizable, or `as_built` absent from the set.
BuildOrientationReport score_build_orientations(
    const BuildOrientationSolveFacts& facts,
    const std::vector<Vec3>& candidates, const Vec3& as_built,
    const Material& material, const KnockdownSpec& knockdown, double margin_stop,
    bool load_path_ok, bool inferred);

// APPLY the recommendation (handoff 2026-08-01-bake-build-orientation). Moves
// `as_built_index` onto `recommended_index`, records where the gravity fallback
// pointed in `as_inferred_index`, and sets the two auto-apply flags. Nothing is
// recomputed: every candidate row was already priced by the SAME gate expression
// the real verdict uses, so "the verdict at the applied orientation" is a row
// that already exists, not a second opinion.
//
// THE CALLER STILL OWNS THE VERDICT. This function does not touch any analysis
// output; analyze_fixed_design re-seals its own direction-dependent fields from
// the applied row immediately afterwards, and asserts they agree. Calling this
// on a report whose `build_direction_inferred` is false is a programming error
// (auto-apply may never override a declared direction) and throws.
void apply_recommended_orientation(BuildOrientationReport* r);

// THE receipt document — the ranking, the recommendation, and the U5 both-verdicts
// statement, as JSON. ONE emitter, shared by the CLI (which writes it to
// <out_dir>/build_orientation.json) and the on-device bridge (which returns the
// same string), so a user reads the identical document whichever ran the job and
// the app needs only one decoder.
//
// It states, in one place: which orientation the verdict describes, whether that
// orientation was DECLARED or ASSUMED from gravity, what the recommendation is,
// and — when the two would gate differently — BOTH verdicts side by side. It does
// not choose, and nothing downstream reads it to decide anything.
//
// `as_built_dir` is the direction the caller's verdict describes (it must be the
// one at `r.as_built_index`; it is passed separately so the receipt reports the
// caller's own vector rather than a re-normalized copy).
//
// `baked` (handoff 2026-08-01-bake-build-orientation) is the rotation that was
// applied to the EXPORTED GEOMETRY, or nullptr when the export was written in
// model-space coordinates. It is what lets this document name the FRAME of every
// vector it prints instead of leaving the reader to guess: with a rotation, the
// exported file's own build direction is +Z and every candidate direction below
// is a MODEL-frame vector. Passing it also makes the receipt state, in words,
// that the orientation was applied automatically and — when true — that it is
// why the part passes (bar V7).
//
// Throws std::invalid_argument if `r` was never evaluated.
std::string build_orientation_report_json(const BuildOrientationReport& r,
                                          const Vec3& as_built_dir,
                                          const BuildFrameRotation* baked = nullptr);

}  // namespace topopt

#endif  // TOPOPT_BUILD_ORIENTATION_HPP
