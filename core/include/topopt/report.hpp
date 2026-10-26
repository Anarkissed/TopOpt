#pragma once

#include <stdexcept>
#include <string>
#include <vector>

#include "topopt/gate_diagnosis.hpp"  // GateDiagnosis (value types only)
#include "topopt/mesh.hpp"      // Vec3
#include "topopt/settings.hpp"  // SlicerSettings

namespace topopt {

// M5.2 — the single JSON job report emitted per optimization run
// (ARCHITECTURE.md §5 pipeline: "... -> 3MF/STL export + JSON report"; §9 M5
// "JSON report format"). One run produces one report describing every requested
// variant: its achieved volume fraction / material saved, worst-case stress and
// margin, chosen build orientation, and recommended slicer settings.
//
// This module is the report DATA MODEL + JSON serialization + schema validation
// only. It is pure C++/std (no Eigen, no OCCT), so it lives in the always-built
// library and its test runs in every configuration. It does NOT run FEA, SIMP,
// orientation scoring or the settings engine — the caller (the M5.3 pipeline
// driver) assembles a JobReport from those results and hands it here to
// serialize. The one piece of derived numeric logic it owns is the stress
// margin, whose definition is locked in settings/rules.json (see below).

// Worst-case stress margin for one variant's chosen build orientation, per
// settings/rules.json semantics_locked.margin_definition (DECISIONS.md
// 2026-07-08). All three are dimensionless safety factors (yield / stress);
// larger is safer, and worst_case is the number the M5.1 settings engine
// consumes as its `worst_case_stress_margin` input.
// CORE LIST item 42 B — one bridge's hold-itself receipt (VariantReport::bridge_holds).
struct BridgeHoldReport {
  double size_mm = 0.0;      // (2 x radius + 1) x voxel spacing
  double hold_margin = 0.0;  // the bridge's own effective margin under the hold load
  int thickenings = 0;       // voxel layers added after the first lay (0..3)
  bool held = true;
};

struct StressMargin {
  double in_plane = 0.0;    // yield_strength_mpa / max_von_mises_stress
  double interlayer = 0.0;  // (z_knockdown * yield_strength_mpa) / max_interlayer_tension
  double worst_case = 0.0;  // min(in_plane, interlayer)
};

// Thrown for any failure to build, serialize or validate a job report:
// a non-physical margin input or a JSON document that does not match the
// report schema.
class ReportError : public std::runtime_error {
 public:
  explicit ReportError(const std::string& msg) : std::runtime_error(msg) {}
};

// Compute the worst-case stress margin from a chosen orientation's stress state,
// exactly per the locked definition:
//   in_plane_margin   = yield_strength_mpa / max_von_mises_stress
//   interlayer_margin = (z_knockdown * yield_strength_mpa) / max_interlayer_tension
//   worst_case        = min(in_plane_margin, interlayer_margin)
// A stress that is exactly 0 means that failure mode carries no load, i.e. an
// unbounded margin: the corresponding term is +infinity, and the min falls back
// to the other (loaded) term. For resin (z_knockdown == 1) the two terms scale
// identically. Throws ReportError if yield_strength_mpa is not finite and > 0,
// z_knockdown is not in (0, 1], or either stress is not finite and >= 0.
StressMargin compute_stress_margin(double yield_strength_mpa, double z_knockdown,
                                   double max_von_mises_stress,
                                   double max_interlayer_tension);

// THE LARGEST VOLUME FRACTION ANY LADDER RUNG MAY REQUEST (task
// 2026-08-03-growth-ladder). 2.0 = "you may at most double the part".
//
// It lives HERE, in the dependency-free report module, because it is enforced in
// two places that must not disagree and cannot include each other: minimize_plastic
// refuses a ladder above it, and the report schema validator reads the printed /
// achieved / saved fractions on this scale for a GROWTH document (one carrying an
// `added_material` block). Every non-growth document is validated on the [0, 1]
// scale it always was — this cap widens nothing for them.
//
// The pre-growth rule was `vf in (0, 1]`; it is UNCHANGED for reduction ladders.
// A ladder may exceed 1.0 only when EVERY rung does (a mixed ladder is refused)
// and only when the run has a design box to grow into. Past 2.0 the ask is not a
// topology-optimization question, and an unbounded field would turn a mistyped
// ladder (2.5 meaning 0.25) into an expensive silent success instead of a refusal.
inline constexpr double kMaxLadderVolumeFraction = 2.0;

// WHERE THIS VARIANT'S PLASTIC IS, relative to the ORIGINAL imported part (task
// 2026-08-03-growth-ladder). On a GROWTH run this is the headline result — it is
// the answer to "how much plastic did you add, and where" — so it is a first-class
// report field, not a footnote derived downstream.
//
// It generalizes PR 285's design-box `added_material` receipt, which computed the
// same inside/outside split but only inside the CLI's LATTICE export path, so a
// solid growth run had no accounting at all. The two agree by construction on the
// quantities they share (printed / inside / outside / outside volume); PR 285's
// receipt additionally carries the lattice policy's `kept_solid`, which exists only
// when a lattice ran and is therefore NOT duplicated here.
//
// `evaluated == false` (the default) means the run never measured this — every
// reduction run, and every run predating the growth ladder — and then the block is
// omitted from report.json entirely, so those documents keep their exact bytes.
struct AddedMaterialReport {
  bool evaluated = false;
  // Printed voxels of THIS variant (physical density > the 0.5 iso), and the split
  // by whether the voxel lies inside the ORIGINAL part envelope or outside it.
  // printed_voxels == inside_part + outside_part, always.
  long long printed_voxels = 0;
  long long inside_part = 0;
  long long outside_part = 0;
  // The original part's own solid voxel count — the denominator every fraction on
  // this line is taken against, carried so a reader never has to reconstruct it.
  long long part_solid_voxels = 0;
  // outside_part / printed_voxels (0 when nothing printed): "what share of the
  // object I am about to print is material that was not in my model".
  double outside_fraction = 0.0;
  // Volumes on the voxel basis (count x spacing^3), in mm^3, and the NET change in
  // printed volume against the part (printed - part_solid, so NEGATIVE if this
  // variant prints less than the part — which is what a growth rung that could not
  // reach its target looks like, and it must be visible, not hidden).
  double outside_volume_mm3 = 0.0;
  double net_added_volume_mm3 = 0.0;
  // The same two on the mass basis (material density x volume), in grams.
  double outside_mass_grams = 0.0;
  double net_added_mass_grams = 0.0;
};

// One variant's line in the job report (§5 "per variant").
struct VariantReport {
  // TWO volume bases, each answering one question (handoff 104, resolving 102).
  // They diverge on the grayscale MMA field (no Heaviside projection) and coincide
  // when the field is crisp; the divergence grows as the target shrinks.
  //
  // `volume_fraction` — the OPTIMIZER'S ACHIEVED fraction ("did the solve hit its
  // volume target?"). No-box path: the optimizer's continuous fraction Σρ/n_active
  // over the active design set (≈ the request). Design-box path: handoff 080's
  // part-relative count printed_voxels/part_solid (the solve targets the Active
  // envelope, so its raw fraction is not part-relative). This is the quantity the
  // cli_demo "achieved vf ≈ request" invariant tests.
  double volume_fraction = 0.0;
  // `printed_fraction` — the PRINTED / thresholded count basis ("how much material
  // actually prints?") = #{ρ>0.5}/part_solid, the SAME voxel count the reported mass
  // is built from. The emitted "volume_saved_fraction" is 1 - printed_fraction, so
  // savings% and mass are two views of one count and can never disagree (handoff
  // 094's fix, kept in its own field). Matches the exported mesh's mass basis; can
  // exceed 1 on the box add-material path (net material added → negative savings).
  double printed_fraction = 0.0;
  // Peak stresses for the chosen orientation (MPa): the max von Mises stress
  // ("max stress") and the max tension across layer planes (M4.4 field).
  double max_stress_mpa = 0.0;
  double max_interlayer_tension_mpa = 0.0;
  // Worst-case stress margin (compute_stress_margin).
  StressMargin margin;
  // The build orientation this line's numbers describe, EXPRESSED IN THE FRAME
  // OF THE EXPORTED MESH (handoff 2026-08-01-bake-build-orientation).
  //
  //   * `export_baked` false (the default, and every pre-bake run) — the mesh is
  //     exported in model-space coordinates, so this IS the model-frame build
  //     direction, exactly as before, and `orientation_model` is unused.
  //   * `export_baked` true — the exported vertices were ROTATED so the certified
  //     build direction is +Z in the file, so this reads (0,0,1) and
  //     `orientation_model` carries the same direction in the input model's own
  //     coordinates.
  //
  // The field means "which way is up in the object this report describes", and
  // the object this report describes is the exported file. Everything else on
  // this line — the stresses, both margins, the min-feature count — is a
  // rigid-motion invariant and reads the same in either frame.
  Vec3 orientation{0.0, 0.0, 0.0};
  // The exported geometry was rotated into the build frame. Emitted into
  // report.json (with `orientation_model`) ONLY when true, so an un-baked run's
  // document keeps its exact bytes and every existing reader is unaffected.
  bool export_baked = false;
  Vec3 orientation_model{0.0, 0.0, 0.0};
  // Recommended slicer settings for this variant (M5.1 engine output).
  SlicerSettings settings;
  // M5.2b — print-reliability warning. `min_feature_violations` is the variant's
  // check_v3 min_feature_violations count (solid regions thinner than 2 voxels,
  // ARCHITECTURE §7 V3 gate 4). `min_feature_warning` is the human-readable
  // warning surfaced when that count exceeds the rules.json threshold
  // (settings min_feature_warning_text); "" when there is no warning. Report-only:
  // does not gate or modify geometry.
  int min_feature_violations = 0;
  std::string min_feature_warning;
  // Acceptance-gate outcome (handoff: multigrid-coarsenability-padding). A rung is
  // accepted iff its infill-adjusted worst-case margin clears the stop threshold.
  // `accepted` is that verdict; `margin_effective` is the value actually compared
  // at the gate (margin.worst_case × the infill knockdown — equal to worst_case for
  // solid/100% infill); `margin_required` is the margin_stop threshold. Reported on
  // BOTH accepted and rejected rungs so a rejection carries its own margin-vs-required
  // numbers, rather than vanishing (a lie of absence). accepted == (margin_effective
  // >= margin_required).
  bool accepted = true;
  double margin_required = 0.0;
  double margin_effective = 0.0;
  // WHY this rung was rejected (handoff 131, extended by
  // 2026-07-23-gate-honesty-connectivity-rejection). "" on every ACCEPTED rung and
  // ONLY there: a rejected rung always says why — REJECTION SPEAKS — so a reader
  // never has to infer the cause from the numbers. Exactly three values, all
  // defined once in pipeline.hpp:
  //   * "margin below required" (kMarginBelowRequiredReason) — the ordinary
  //     strength verdict. The rung WAS fully analysed; margin_effective vs
  //     margin_required below are real measurements and are the detail.
  //   * "load path not connected" (kLoadPathNotConnectedReason) — the CONNECTIVITY
  //     BELT (voxel.hpp load_path_connected) found no path of printed material
  //     from the anchor (Fixture) voxels to the load (Load) voxels. The rung WAS
  //     analysed, so the numbers on the line are measurements — of a SEVERED
  //     structure. That is precisely why they look excellent: a design that
  //     carries nothing has no stress, hence an enormous margin.
  //   * "rung infeasible (load path lost)" (kRungInfeasibleReason) — the rung never
  //     reached the gate at all: the optimizer severed the structure and the run
  //     was ended on the rung-infeasibility signature (simp.hpp rung_infeasible).
  //
  // READ THE REASON BEFORE THE NUMBERS on any rejected line, and note what the
  // reason says about their STATUS. An infeasible rung's per-rung ANALYSIS IS NEVER
  // RUN — no stress solve, no V3 suite, no settings engine — because analysing a
  // corpse produces confident nonsense, so its stress, margin, orientation and
  // settings fields are ZERO PLACEHOLDERS meaning "not measured", not measurements.
  // A disconnected rung's fields ARE measurements, of a structure that cannot be
  // built. Either way the margin on such a line is not a strength result. (The
  // motivating run's severed rung measured margin 680.9 and was ACCEPTED and
  // shipped on that basis — handoff 131 §evidence.)
  std::string rejection_reason;
  // WHY the verdict above is what it is, and what would change it (handoff
  // 2026-08-02-gate-diagnosis-recommendations). Structured, not prose: which term
  // BINDS, its value against the value it had to reach, and recommendations that
  // were each VERIFIED by evaluating gate_margin_effective under the proposed
  // change. Default-constructed (`evaluated == false`) unless the caller ran
  // diagnose_gate, and then omitted from the JSON entirely — so a run without a
  // diagnosis keeps its document byte-for-byte.
  //
  // IT EXPLAINS THE VERDICT; IT NEVER MOVES ONE. `accepted`, `margin_required`
  // and `margin_effective` above are the gate's, and the diagnosis is written
  // FROM them.
  GateDiagnosis diagnosis;
  // WHERE THIS VARIANT'S PLASTIC IS (task 2026-08-03-growth-ladder). Measured only
  // on a GROWTH run, so `evaluated == false` on every reduction run and the block
  // is omitted from report.json — those documents keep their exact bytes.
  AddedMaterialReport added_material;
  // Task 2026-08-03-growth-ladder — the growth rung asked for more material than
  // the design box could hold, so the volume target was CLAMPED to "fill the box"
  // and this rung did not actually run at the fraction its line requests. The
  // ladder does not stop on it (a saturated rung is a box problem, not a strength
  // verdict), but no reader may be allowed to read the achieved fraction as if the
  // request had been honoured. Always false on a reduction ladder.
  bool growth_target_saturated = false;
  // CORE LIST item 40 — THE REDUCTION MIRROR: the rung asked for LESS material than
  // the part's frozen material alone prints, so its target fell under the density
  // floor and was RAISED to it. The optimizer then removes every free voxel and the
  // rung prints the frozen share, not its request (his Carriage Arms, 13185527:
  // 0.68 / 0.52 / 0.38 / 0.26 all printed 0.758). `requested_volume_fraction` is the
  // rung's ask, beside the achieved `volume_fraction` / `printed_fraction` above.
  // Both are emitted only when `request_reported`, which the driver sets on EVERY
  // line of a run where some rung saturated (and on no other run), so every other
  // report.json keeps its exact bytes. Always false on a growth ladder.
  bool request_reported = false;
  double requested_volume_fraction = 0.0;
  bool target_saturated = false;
  // CORE LIST items 41 + 47 — the rung's printed material as BODIES (voxel.hpp
  // printed_bodies): how many the exported file carries, the loose specks dropped,
  // and the anchored pieces its design let go of (which reject the rung, naming
  // the anchored faces or regions). Emitted as report.json "bodies" only when
  // `bodies_reported` (more than one body exported, a speck dropped, or an anchor
  // lost), so every one-body, speck-free line keeps its exact bytes.
  bool bodies_reported = false;
  int bodies_exported = 1;
  int specks_dropped = 0;
  long long speck_voxels = 0;
  double speck_volume_mm3 = 0.0;
  int anchored_pieces_lost = 0;
  // CORE LIST item 42, option B — the design was split and BRIDGED back into one
  // piece before it was certified (its numbers include the bridge).
  int bridges = 0;
  long long bridge_voxels = 0;
  // ...and each bridge HOLDS ITSELF (the reviewer's values of 2026-10-25 07:05): its
  // nominal thickness, its own margin with the piece it joined hanging from it alone,
  // how many voxel layers were added to get there (at most 3), and whether it held
  // (a bridge that did not is lifted again, and items 47 / the belt judge the rung).
  std::vector<BridgeHoldReport> bridge_holds;
  long long lost_anchor_voxels = 0;
  std::vector<int> lost_anchor_face_ids;
  std::vector<int> lost_anchor_region_ids;  // FRAGILE JOINTS (reviewer's ruling 2026-10-26): places where the printed part
  // holds together only along an edge or at a corner (two face-connected pieces
  // touching through edge / corner neighbours only). A hinge in the solve,
  // fragile when printed; reported, never fixed. report.json "fragile_joints"
  // only when > 0, so every other line keeps its exact bytes.
  int fragile_joints = 0;
  // Where (mm, the solve grid's model frame): the midpoint of each joint's first
  // edge / corner contact, in a deterministic order, at most
  // kFragileJointPositionsMax of them (fragile_joints is the full count).
  std::vector<Vec3> fragile_joint_positions_mm;
};
inline constexpr std::size_t kFragileJointPositionsMax = 50;

// ── WHAT FROZE THE PART, and the rungs it made redundant (CORE LIST item 40) ──
//
// One source of the frozen material a reduction rung's target is taken net of.
// Each entry counts only the voxels NO EARLIER ENTRY froze, so the entries add up
// to `FrozenShareReport::frozen_voxels`, each voxel once. Sources, in order:
//   "anchor_and_load_faces" — the voxels the anchor and load faces themselves tag
//                             (their boundary-condition skin);
//   "anchor_pad"            — the structural pad behind them (loadcase.hpp);
//   "face_protection"       — one per protected face (`face_id`) or region
//                             (`region_id`), in the order the job declares them;
//   "other"                 — frozen voxels the caller did not attribute (present
//                             only when non-zero).
struct FrozenSourceCount {
  std::string source;
  int face_id = -1;    // >= 0 on a face protection declared on a face
  int region_id = -1;  // >= 0 on a face protection declared on a region
  long long voxels = 0;
};

// A rung that was NOT RUN because an earlier rung already made its design: its ask
// was below the frozen share too, so its target clamps to the same floor the
// `same_design_as` rung ran with. No variant, no file; this line says why.
struct SkippedRungReport {
  double requested_volume_fraction = 0.0;
  double same_design_as = 0.0;  // the requested fraction of the floor rung
  std::string reason;
};

// The frozen share of the part and what froze it. `evaluated == false` (the
// default) unless some rung's target clamped to the density floor, and then the
// block is omitted from report.json entirely, so every other document keeps its
// exact bytes.
struct FrozenShareReport {
  bool evaluated = false;
  long long part_solid_voxels = 0;
  // Voxels printed whatever the optimizer does: the Load/Fixture skin plus every
  // FrozenSolid voxel. `frozen_material_voxels` is the same set as the target
  // counts it, a frozen LATTICE voxel at its relative density; it equals
  // `frozen_voxels` on every run that declares no frozen lattice.
  long long frozen_voxels = 0;
  double frozen_material_voxels = 0.0;
  long long active_voxels = 0;  // the voxels the volume constraint moves
  // frozen_material_voxels / part_solid_voxels: what the frozen material alone
  // prints, as a fraction of the part. A rung asking for less cannot be honoured.
  double share = 0.0;
  // The smallest ask the run CAN honour: (frozen + density_min x active) / part.
  double smallest_honoured_fraction = 0.0;
  std::vector<FrozenSourceCount> sources;
  std::vector<SkippedRungReport> skipped_rungs;
};

// ── "REDESIGN TO STRENGTHEN" (CORE LIST item 50) ─────────────────────────────
// Three versions rebuilt inside the design box from what is frozen, each the least
// plastic found that meets its target: 25 / 50 / 75 % less worst stress than the
// reference (the part's verified margin as drawn, or margin_required if that is
// higher). Every margin here is the gate's knockdown margin. `verified_margin` is
// the EXPORTED geometry re-voxelized and certified; `in_loop_margin` is the rung's
// own certification of its voxel field.
struct StrengthenVersionReport {
  int version = 0;
  double stress_cut = 0.0;      // 0.25 / 0.50 / 0.75
  double target_margin = 0.0;
  std::string status;           // "verified" | "repaired" | "unreachable" | "merged"
  double volume_fraction = 0.0; // of the domain's free (Active) voxels
  double in_loop_margin = 0.0;
  double verified_margin = 0.0;
  double mass_grams = 0.0;
  double mass_fraction_of_original = 0.0;
  double max_deflection_mm = 0.0;  // max |u| over the load nodes, verified solve
  double iou_with_original = 0.0;  // printed voxels vs the part as drawn
  bool essentially_original = false;  // IoU > 0.9
  bool anchors_attached = true;       // item 47's check on the version
  int specks = 0;
  long long keep_clear_voxels = 0;    // exported voxels inside a Keep Clear
  int coarse_runs = 0;
  // Coarse runs that started from the previous coarse design (cleaned of loose
  // pieces) instead of the level set's hole array: every coarse run but the
  // pass's first (reviewer's order, 2026-10-26).
  int coarse_seeded = 0;
  int repairs = 0;
  double seconds = 0.0;
  std::string note;
  // THE FINE START (core-loose-pieces, ruling 2026-10-25: don't carry specks
  // across grids). Where the version's first fine run started — "coarse design"
  // (the passing coarse design resampled onto the fine grid) or "hole array"
  // (no design to hand on; not expected) — how many LOOSE pieces the hand-off
  // held (face-connected, touching no support or load) and the design voxels they
  // lost, the non-frozen loose voxels left (0: the start holds none), and the
  // frozen-only pieces still loose (the solves take those out of the system).
  std::string fine_start;
  int fine_start_loose = 0;
  long long fine_start_loose_voxels_removed = 0;
  long long fine_start_loose_left = 0;
  int fine_start_frozen_loose = 0;
};
struct StrengthenReport {
  bool evaluated = false;
  double as_drawn_margin = 0.0;
  double margin_required = 0.0;
  double reference_margin = 0.0;
  double ceiling_margin = 0.0;       // the domain filled solid
  double original_mass_grams = 0.0;
  long long frozen_outside_box_voxels = 0;
  int coarse_resolution = 0;
  // The adaptive-volume rule used (our proposal, after Lin & Sheu 2009):
  // vf <- vf * (target (1 + delta) / margin)^gamma, each step capped at +-vf_step,
  // floored at the previous version's fraction.
  double delta = 0.0, gamma = 0.0, vf_step = 0.0;
  // WHERE THE CEILING'S WORST STRESS SITS (the reviewer's ruling of 2026-10-25
  // 03:58): the voxel of peak von Mises in the box filled solid, the CAD face
  // nearest it, and whether it touches an anchor or load face. A peak at the edge
  // of a fixed or loaded face can be a stress singularity that grows with
  // resolution, so a cap set there may not be real. `cap_note` is the one line.
  int cap_face_id = -1;
  Vec3 cap_point{0.0, 0.0, 0.0};
  bool cap_at_anchor_face = false;
  bool cap_at_load_face = false;
  std::string cap_note;
  std::vector<StrengthenVersionReport> versions;
};

// The whole run's report: the material used and one entry per requested variant.
struct JobReport {
  std::string material;  // material name (key into materials.json)
  // ACCEPTED rungs, in ladder order (the savings ladder). Unchanged contract:
  // callers that count accepted variants read this.
  std::vector<VariantReport> variants;
  // Evaluated-but-REJECTED rungs, in ladder order (empty when the whole ladder was
  // accepted). Each carries accepted=false and its margin_effective vs
  // margin_required. Emitted as report.json "rejected_variants" so a rejection is
  // REPORTED, not silently omitted — the honesty fix for the vanished-rung-3 lie of
  // absence. Every entry carries a NON-EMPTY rejection_reason (see above); three
  // kinds live here: the terminal TOO-WEAK rung the ladder stopped on, the terminal
  // DISCONNECTED rung the connectivity belt stopped it on, and any rung the
  // optimizer ended as INFEASIBLE — which does NOT stop the ladder, so this array
  // can hold more than one entry.
  std::vector<VariantReport> rejected;
  // CORE LIST item 40 — emitted as report.json "frozen_share" only when evaluated.
  FrozenShareReport frozen_share;
  // CORE LIST item 50 — emitted as report.json "strengthen" only when evaluated.
  StrengthenReport strengthen;
};

// Serialize a job report to a single JSON document (2-space indented). Numeric
// fields that are not finite (e.g. an unbounded margin term when a stress is 0)
// are emitted as JSON null. Each variant additionally carries the derived
// "volume_saved_fraction" = 1 - printed_fraction (savings is the printed/count
// basis — handoff 104). The output always satisfies validate_job_report_json below.
std::string job_report_json(const JobReport& report);

// Schema-validate a job report JSON document (the report schema this module
// emits). Parses `json_text` and checks that every required field is present
// with the right type, that counts are integers, that volume_saved_fraction is
// consistent with the savings basis (1 - printed_fraction when printed_fraction is
// present, else the legacy 1 - volume_fraction), and that stresses / volume
// fractions are in range. Throws ReportError on malformed JSON or any schema
// violation; returns normally when the document conforms.
void validate_job_report_json(const std::string& json_text);

}  // namespace topopt
