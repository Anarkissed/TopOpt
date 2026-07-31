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
// Throws std::invalid_argument if `r` was never evaluated.
std::string build_orientation_report_json(const BuildOrientationReport& r,
                                          const Vec3& as_built_dir);

}  // namespace topopt

#endif  // TOPOPT_BUILD_ORIENTATION_HPP
