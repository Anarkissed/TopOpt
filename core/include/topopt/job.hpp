#pragma once

#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

#include "topopt/analyze.hpp"     // FixedDesignAnalysis
#include "topopt/loadcase.hpp"   // ProductionLoadCase
#include "topopt/materials.hpp"  // MaterialLibrary
#include "topopt/mesh.hpp"       // Vec3
#include "topopt/pipeline.hpp"   // MinimizePlasticResult
#include "topopt/settings.hpp"   // SettingsRules
#include "topopt/smooth.hpp"     // SmoothStats
#include "topopt/step.hpp"       // StepModel

namespace topopt {

// M6.2 — the `topopt-cli run job.json` job description (ARCHITECTURE §9 M6:
// the CLI driver is the canonical headless entry point driving the full §5
// pipeline). The schema is DEFINED by the maintainer-authored demo fixture
// core/tests/fixtures/demo/job.json (DECISIONS.md 2026-07-09): the parser
// implements exactly its keys and rejects unknown keys or missing required
// ones with a diagnostic — the same strictness as the materials loader.
// Keys beginning with '_' are maintainer comments, ignored at every level.
//
// Face selection is GEOMETRIC by locked rule (DECISIONS.md 2026-07-09): the
// job names surface properties (e.g. "every cylindrical face of radius r"),
// never raw OCCT face indices — face enumeration order is not stable across
// OCCT versions.
//
// parse_job / load_job_file are pure C++/std and live in the always-built
// library. run_job drives STEP import, FEA and export, so it is defined only
// when OCCT + Eigen are available (like import_step_file / minimize_plastic);
// its 3MF output path additionally requires lib3mf and fails with a JobError
// diagnostic when the library was built without it.

// Thrown for any job failure: an unreadable/malformed/schema-violating
// job.json, or a run-time failure the job caused (unknown material, a
// selector matching no face, a non-watertight model, an unwritable output).
class JobError : public std::runtime_error {
 public:
  explicit JobError(const std::string& msg) : std::runtime_error(msg) {}
};

// One geometric fixture-face selector. `kind` is the underlying-surface class;
// "cylindrical" (the only kind the demo schema defines) matches every B-rep
// face whose surface is a cylinder with the given radius, within
// kJobFaceRadiusToleranceMm (the fixture's selector semantics).
struct JobFaceSelector {
  std::string kind;        // "cylindrical"
  double radius_mm = 0.0;  // finite, > 0
};

// Cylinder-radius match tolerance (mm), per the demo fixture's _fixture_note.
constexpr double kJobFaceRadiusToleranceMm = 1e-6;

// Self-weight loading block. `direction` is the direction gravity pulls (the
// job's units: mm, mm/s^2); the driver's reported build direction is its unit
// negation. `magnitude_mm_s2` is finite and > 0 (9810 = Earth gravity in mm/s^2).
struct JobGravity {
  Vec3 direction{0.0, 0.0, -1.0};
  double magnitude_mm_s2 = 0.0;
};

// Output block: file names relative to the CLI's --out directory.
struct JobOutput {
  std::string report;       // the M5.2 JobReport JSON file name
  std::string mesh_format;  // "3mf" (primary) | "stl" (secondary), §4
  std::string mesh_prefix;  // per-variant mesh files: <prefix>_<vf*100>.<format>

  // Optional smooth-export tessellation (handoff 086-surface-resample). 1 (the
  // DEFAULT) exports the native marching-cubes mesh byte-for-byte as before.
  // N in [2,4] re-extracts the exported mesh from the SAME converged physical
  // density resampled N x finer via a tricubic (Catmull-Rom) interpolant, so the
  // curved iso-surface the grayscale field already describes is tessellated with
  // ~N x smaller facets. It changes ONLY the surface tessellation of the exported
  // STL/3MF — NOT the design, the physics, the optimizer, the density field, the
  // JobReport, or the V3-gated variant mesh (variant.v3.mesh is untouched). The
  // reported mass_grams stays voxel-count based; see the handoff for the (small)
  // mesh-vs-readout volume gap this widens. Optional key "smooth_factor"; absent
  // or 1 keeps every existing job byte-for-byte identical.
  int smooth_factor = 1;

  // CAD-FACE PROJECTION (task 2026-08-06-cad-face-projection).
  //
  // ★ ARMED BY DEFAULT since task 2026-08-06-arm-projection-and-void-check. It
  // shipped false in PR 307 and the maintainer has decided it is on. THE
  // DEFAULT EXPORT PATH THEREFORE CHANGES — deliberately, and this is the one
  // place in the project where that is true. There is no byte-identity claim
  // for a default run any more; see that task's handoff §R1 for the measured
  // before/after instead.
  //
  // ★ THE DEFAULT LIVES HERE, IN THE CORE, and not in whichever front-end is
  // assembling a job. "Universally" has to mean ONE answer: the CLI, the LAN
  // worker and the on-device bridge all read this initializer, so they cannot
  // diverge. The dropped outer wall line width — written correctly by
  // bridge.cpp and silently not by the CLI helper — is the shape this avoids.
  //
  // When true, every exported variant vertex that came from a face of the
  // IMPORTED PART — a wall, a mounting face, a bolt bore — is moved onto that
  // face's own analytic surface, which the B-rep already states exactly
  // (topopt/step.hpp StepFaceInfo: this plane, this cylinder, this radius, this
  // axis). Vertices the OPTIMIZER cut are left untouched, because no ground
  // truth exists there.
  //
  // This is NOT smoothing and does not share a line of code with it: nothing is
  // averaged, no surface is estimated, and the motion is bounded by one voxel.
  // It changes ONLY the exported mesh's vertex positions — not the design, the
  // physics, the optimizer, the density field, the VOXEL-derived mass, or the
  // certified margin (all of which are computed on the voxel grid, which this
  // never touches).
  //
  // ★ IT DOES MOVE EVERY MESH-DERIVED FIGURE, and that is not a defect. PR 307
  // measured the un-projected export ~8% OVERSIZE (100% of flat-face vertices
  // outside their own CAD plane by ~0.67 mm; a re-certified un-projected
  // variant reporting volume_fraction 1.0028, which is impossible). So a
  // mesh-derived mass DROPS by about 8% the day this defaults on, and it drops
  // because it stops being wrong. No mass formula was touched.
  //
  // Set "project_cad_faces": false to export the voxelised approximation
  // instead — the OFF control, so the same job can be run both ways.
  bool project_cad_faces = true;
};

// Optional "lattice" block (handoff 2026-07-28-lattice-generation-production).
// When present, run_job emits — ALONGSIDE each accepted variant's solid mesh — a
// LATTICED variant: the solid shell unioned with an octet strut lattice filling
// the part's solid interior, streamed to disk (peak RSS flat in output size). The
// union is the interpenetrating triangle soup a slicer accepts. Absent (present ==
// false, the DEFAULT) => no lattice file, no run_info lattice key, byte-identical
// to a pre-lattice run — the P1 bar.
//
// GENERATION RUNS WHEREVER run_job RUNS, i.e. the Mac worker's topopt-cli (the
// iPad's on-device path never populates this block). The mesh is written to
// out_dir and served as a downloadable artifact, so the iPad fetches the file and
// never holds the full mesh — item 3 of the task.
//
// The strut RADIUS is uniform here (`strut_radius_mm`). An externally supplied
// radius/density FIELD is carried by the core generator (topopt/lattice_gen.hpp);
// how that field is DERIVED from stress (the grading law) is a separate task, so
// the job front-end ships uniform for now and records the density it implies.
// One lattice ROLE region (task 2026-07-31-lattice-page-core-hookup) — a
// `lattice.regions` entry, the schema PR 254's lattice page proposed. A
// user-placed primitive (the same manual bolt-cylinder / bounded-slab geometry a
// manual clearance carries — no second geometry concept) with a ROLE:
//   "include" — material stays, LATTICED. When any include region exists, only
//               material inside the include union is latticed; the REST of the
//               part stays SOLID (certified solid + exported as a solid body).
//   "exclude" — material stays, kept SOLID (certified solid, exported solid).
// The third role, clearance (NO MATERIAL), is NOT spelled here — it is the
// existing loads.clearances keep-out, unchanged. PRECEDENCE (tested):
// clearance beats both; exclude beats include; include over optimizer void is a
// NO-OP (lattice cannot conjure material) and is reported in the receipt.
struct JobLatticeRegion {
  std::string role;  // "include" | "exclude"
  std::string kind;  // "bolt" (cylinder) | "face" (bounded slab)
  // Bolt: a cylinder about axis_point + t·axis_dir, t in [-half_length, +half_length].
  Vec3 axis_point{0.0, 0.0, 0.0};
  Vec3 axis_dir{0.0, 0.0, 0.0};
  double radius_mm = 0.0;
  double half_length_mm = 0.0;
  // Face: a bounded slab — origin + s·normal for s in [0, depth_mm], clipped to
  // the centred in-plane rectangle 2·half_u_mm × 2·half_w_mm.
  Vec3 origin{0.0, 0.0, 0.0};
  Vec3 normal{0.0, 0.0, 0.0};
  double half_u_mm = 0.0;
  double half_w_mm = 0.0;
  double depth_mm = 0.0;
  // ★ WHICH B-REP FACE THIS REGION CAME FROM (task 2026-08-12 §0a). Optional,
  // -1 = "not from a face" (a hand-placed primitive). It exists so the ONE
  // number the user drags can be CHECKED: when a face region names a face that
  // is also in `loads.face_protections`, the job REFUSES unless the protection
  // depth for that face equals this `depth_mm`. Without the id the two numbers
  // were unrelatable and drifted silently — 5 mm of protection under a 7 mm
  // lattice region, on the maintainer's own run.
  int face_id = -1;
};

struct JobLattice {
  bool present = false;
  std::string topology = "octet";  // only "octet" is implemented
  // cell_mm / strut_radius_mm describe the UNIFORM lattice. Required when no
  // "grading" block is present; REJECTED alongside one (a graded run derives the
  // cell from grading.cell_mm raised to the printability floor and the strut
  // radii from the run's own graded densities — a uniform cell/radius here would
  // conflict, so the schema refuses it rather than silently ignore it).
  double cell_mm = 0.0;            // cell edge (mm), finite > 0
  double strut_radius_mm = 0.0;    // uniform strut radius (mm), finite > 0
  // Lattice role regions (see JobLatticeRegion). Empty => whole-part lattice,
  // byte-identical to the pre-regions schema.
  std::vector<JobLatticeRegion> regions;
  // MULTISCALE LATTICE TO (task multiscale-lattice-to). false (the DEFAULT) is the
  // TWO-STEP pipeline every existing job runs: optimize assuming solid, then try to
  // lattice what survived. true asks the OPTIMIZER to place the lattice while it
  // grows the shape — inside this block's role region, the SIMP loop's material law
  // becomes the measured homogenized cubic tensor C(rho) of the lattice library
  // instead of rho^p*E0, and the converged design is projected onto the feasible
  // set {0} u [rho_lo, rho_hi] u {1} with the volume charge reported.
  //
  // WHY YOU WOULD WANT IT: under the two-step, the optimizer (told nothing about the
  // lattice, penalty 3.0 driving density to the extremes) leaves thin tendrils, and
  // a member thinner than the cells-per-member floor cannot hold a cell — so the
  // lattice pass falls back to SOLID. On the maintainer's M2_verticalStand run that
  // was 99-100% of every lattice region. It is not a bug in the lattice pass, and no
  // post-process can fix it.
  //
  // REQUIRES the "grading" block (a multiscale design is graded by construction:
  // every latticed voxel carries its own density) and mode "minimize_plastic" (there
  // is no optimizer to change on the analyze / lattice_variant paths). Honoured only
  // when production permits it (production_multiscale_lattice_to) and only for a
  // topology whose measured table can steer a design loop (octet today) — refused,
  // never silently downgraded.
  bool multiscale = false;
  bool emit_stl = true;            // write <prefix>_<vf>_lattice.stl
  bool emit_3mf = false;           // write <prefix>_<vf>_lattice.3mf (streaming)

  // Boundary finish (handoff 2026-07-29-lattice-boundary-finish). "diagrid"
  // (default): anchor balls at every clipped strut end + skin edges linking
  // them + rim loops/collar tori — the full finish the maintainer asked for
  // ("connect with the hole rim and skin"). "rim": just the edge loops.
  // "none": clipping only. The clip itself is not optional: struts are always
  // trimmed to the part and to declared clearance keep-outs.
  std::string skin = "diagrid";
  // Optional STATED minimum extrudable width (mm) — when > 0 the skin's own
  // printability clamp is lattice_skin_min_radius_mm(this) (read from core,
  // like grading.hpp's floor). 0 (absent) states no printability claim: the
  // skin then simply tracks the local interior strut radius.
  double min_extrudable_width_mm = 0.0;

  // Outer finish (task 2026-07-30-lattice-skin-freeform) — what covers the
  // part's outer boundary in the exported file:
  //   "shell"      (DEFAULT) — the solid shell mesh, exactly as before;
  //                byte-identical output.
  //   "skin"       — NO solid shell: the freeform 2D lattice skin rides the
  //                voxel-derived outer surface instead (open, see-through).
  //                NOT certifiable by the existing gate — the shell is what
  //                backstopped clipped boundary cells against the posture's
  //                periodic-octet assumption — so the receipt reports the
  //                composite margins but lattice_accepted is forced false.
  //   "shell+skin" — shell retained, freeform skin laid on it (decorative,
  //                closed); certification unchanged from "shell".
  // A non-"shell" finish requires skin == "diagrid" (the skin IS the finish).
  std::string outer_finish = "shell";

  // THE PRE-FLIGHT FORECAST (task 2026-08-03-variant-postprocessing-fix, bar F3).
  // true => `lattice_variant_job` runs the grading law and the role accounting on
  // the stored design, writes <out_dir>/lattice_forecast.json, and RETURNS — no
  // certification solve, no mesh, no receipt. It is the same law on the same
  // inputs the real run would use, so what it reports is what the run would do:
  // which voxels would be latticed, which would stay solid AND WHY (per reason),
  // how many include-region voxels sit on void, whether the boundary choice can
  // emit at all, and EVALUATED counterfactuals for the remedies worth offering.
  // Default false => every existing job is byte-identical.
  bool forecast_only = false;

  // THE ENCLOSED-VOID RULE (task 2026-08-05-lattice-void-reaches-exterior).
  //
  // ★ ARMED BY DEFAULT since task 2026-08-06-arm-projection-and-void-check. It
  // shipped false in PR 305 and the maintainer has decided it is on.
  //
  // ★ THIS ONE REFUSES RUNS, and that makes it a different kind of default from
  // `output.project_cad_faces` above. Projection changes geometry: a run that
  // worked still works and the exported surface moves. This one can stop a job
  // that succeeded yesterday. The two are NOT one switch and must never be
  // collapsed into one — see this file's other key and the independence
  // assertions in core/tests/unit/test_default_arming.cpp.
  //
  // Because it refuses on a default-on posture, the refusal is required to be
  // ACTIONABLE and not merely correct: the text names how many cells, where (mm
  // bounding box), which declared include region, how much volume is trapped,
  // AND how to proceed — which key turns the check off and what exporting with
  // it off actually means. A refusal that does not say how to continue is the
  // "painted door" defect this project has hit twice. The text is asserted, not
  // merely written: core/src/mesh/lattice_void.cpp and the remedy assertions in
  // core/tests/unit/test_lattice_void.cpp.
  //
  // false => the check does not run, nothing is measured and nothing is written
  // (the OFF control, so the same job can be run both ways). true (the DEFAULT)
  // => after the lattice occupancy is decided and BEFORE anything
  // is exported, the void space is flood-filled from outside the part inward
  // (topopt/lattice_void.hpp) and a lattice cell whose pore space cannot reach
  // the exterior REFUSES the variant, naming how many cells are sealed, where,
  // in which declared include region, and how much trapped volume.
  //
  // IT REFUSES; IT DOES NOT AUTO-CORRECT. Opening a sealed cavity means removing
  // material the user did not ask to remove, so the run says what is wrong and
  // stops. The two callers behave as they do for `region_ungradeable`:
  // lattice_variant_job (which exists to produce ONE object) throws;
  // the optimize ladder skips that rung, says so on stderr, and leaves it out of
  // the run-level aggregates.
  //
  // WHEN THE CHECK PASSES it still writes its receipt — how much void was
  // reachable, how deep the drain path runs and which grid faces it escapes
  // through — because a silent pass is indistinguishable from a check that
  // never ran.
  bool require_lattice_void_reaches_exterior = true;
};

// Optional "grading" block (handoff 2026-07-29-lattice-grading-law) — arms the
// stress-to-lattice grading law. Absent => byte-identical run (bar L1). When
// present, a von Mises field is fed to grade_lattice (grading.hpp), which produces
// a per-voxel density + one uniform cell size clamped to the certifiable band and
// the cells-per-member floor, and the report is written to run_info's "grading"
// object. The law READS the band/floor from core; only the knobs a job
// legitimately sets live here. TWO consumers:
//   * analyze_job — grades the fixed design's certification field (the original
//     path, unchanged);
//   * run_job (task 2026-07-31-lattice-page-core-hookup, stage 4) — REQUIRES a
//     "lattice" block (without one there is nothing to grade into — refused, never
//     silently ignored) and, per accepted variant, grades that variant's OWN final
//     certification von Mises field, then exports + certifies the GRADED lattice
//     (per-voxel rho posture; strut radii from the graded densities). The
//     per-variant receipt records the field's provenance (which variant, how many
//     optimizer iterations produced it) and the band-clamp counts.
struct JobGrading {
  bool present = false;
  std::string topology = "octet";       // only "octet" is implemented
  double cell_mm = 0.0;                 // TARGET uniform cell edge (mm), finite > 0;
                                        // raised to the printability floor if too small
  double min_extrudable_width_mm = 0.0; // stated minimum strut width (mm), finite > 0
  double demand_exponent = 1.0;         // rho = rho_max*(demand/max)^exp; 1.0 = fully-
                                        // stressed on von Mises. finite > 0

  // Cell-size MODE (handoff 2026-08-01-lattice-cell-size-sweep):
  //   "fixed" (DEFAULT, and what an absent key means) — cell_mm for the whole part,
  //     raised to the printability floor. Byte-identical to a pre-sweep run (bar R1).
  //     ★ WHICH floor changed in task 2026-08-05-lattice-cell-fit-mode (S2): the
  //     target is now raised only to the cell below which NO density in the band
  //     prints (min_extrudable_width / phi(rho_max)), not to the one evaluated at the
  //     band's LIGHTEST density. A target between the two is kept and the DENSITY is
  //     raised to suit it. A target at or above the old floor is untouched.
  //   "auto"  — core picks ONE cell (the printability floor: the finest cell every
  //     strut still prints at, and so the uniform cell that leaves the most of the
  //     part latticed). cell_mm is then ignored and may be omitted.
  //   "swept" — the cell VARIES across the part on a dyadic octree between
  //     cell_min_mm and cell_max_mm, following demand the way strut radius already
  //     does. REQUIRES both bounds; cell_mm is refused alongside it (a target cell
  //     would conflict with the ladder rather than add to it, so the schema says so
  //     instead of silently ignoring one).
  //   "fit"   — (task 2026-08-05-lattice-cell-fit-mode) the cell is DERIVED PER
  //     DECLARED INCLUDE REGION from what that region has to fit into:
  //     max(region extent / cells-per-member floor, the finest printable cell), with
  //     the relative density raised to whatever prints at it. REQUIRES at least one
  //     "role": "include" region — without a declaration there is no requirement to
  //     fit — and refuses cell_mm (core derives it) and
  //     retain_subfloor_in_unloaded_regions (fit already reports the out-of-regime
  //     material it emits). A region that cannot hold a PERCOLATING lattice at any
  //     (cell, density) is refused by the pre-flight before a solve is spent; one
  //     that percolates but cannot reach the accuracy floor is latticed and stamped
  //     OUT OF REGIME.
  std::string cell_mode = "fixed";
  double cell_min_mm = 0.0;             // swept only; finite > 0
  double cell_max_mm = 0.0;             // swept only; finite >= cell_min_mm

  // "retain_subfloor_in_unloaded_regions" (handoff 2026-08-04-subfloor-lattice-
  // unloaded-regions). ABSENT / false is the DEFAULT and is bit-identical to a
  // pre-task run (bar S1). True lets the grading law keep lattice in a region whose
  // members cannot hold the cells-per-member floor, PROVIDED the law MEASURES that
  // region's peak von Mises at or under `subfloor_stress_fraction` of the part's
  // peak. The maintainer's case is a back wall that carries no load and exists for
  // geometry: today it is silently left solid.
  //
  // OPTING IN IS ACCEPTING A KNOWN INACCURACY. The certificate over the retained
  // material is out of regime — `lattice_strut_out_of_regime` is raised and the
  // receipt names which voxels, at what cells-per-member, and at what fraction of
  // peak stress. Read lattice.hpp's ★★ note before using it: the certification is
  // structurally blind to cells-per-member, so a margin that does not move is NOT
  // evidence that this is safe.
  bool retain_subfloor_in_unloaded_regions = false;
  // "subfloor_stress_fraction" — optional override of the measured ceiling
  // (lattice_subfloor_retention_stress_fraction(), 0.20). 0 / absent = take the
  // core constant. Finite, > 0 and <= 1 when retention is on.
  double subfloor_stress_fraction = 0.0;
  // "subfloor_aggregate_cap" — optional override of the AGGREGATE exposure cap
  // (lattice_subfloor_aggregate_cap_fraction(), 0.03): the ceiling on total
  // sub-floor material retained across ALL regions, as a fraction of the printed
  // set. 0 / absent = take the core constant. Finite, > 0 and <= 1 when retention
  // is on. Over the cap the run retains NOTHING and the receipt says so — see
  // lattice.hpp's ★★★ note for why this is a policy ceiling on exposure and not a
  // safety threshold.
  double subfloor_aggregate_cap = 0.0;

  // ── "report_region_cells" (task 2026-08-05-lattice-cell-size-adaptation, Stage
  // A/E). ABSENT / false is the DEFAULT and the run is byte-identical — this adds
  // a receipt SECTION and changes no decision anywhere in the pipeline.
  //
  // True makes the run answer, for every declared lattice include region (or once
  // for the whole candidate set when none are declared): the region's MEASURED
  // member thickness and stress fraction, and the (cell, density) window that fits
  // it — derived at run time from lattice_derive_cell_for_member, never from a
  // literal. When no window exists it reports the arithmetic that rules it out and
  // the member width that would change the answer.
  //
  // WHY IT IS A REPORT AND NOT A MODE. The pipeline already refuses a member it
  // cannot certify; what it has never done is say at what cell and density that
  // member WOULD be certifiable. The maintainer was told he needed a 23 mm member,
  // which is N* x the printability floor evaluated at the band's LIGHTEST density —
  // a conditional number whose condition was never surfaced. This reports the
  // condition. It chooses nothing: which end of the window to print, whether to
  // thicken a wall, and whether to accept a skin instead are all the user's calls.
  bool report_region_cells = false;

  // ── "subfloor_per_region" (task 2026-08-05-lattice-cell-size-adaptation, Stage
  // B). Only meaningful with "retain_subfloor_in_unloaded_regions": true; absent /
  // false keeps the UNION reading, which is what every shipped retention run has
  // used, so those runs stay byte-identical.
  //
  // True hands the per-voxel DECLARED-REGION ids to the grading law, so the
  // unloaded-region predicate is answered once per region the user actually drew
  // instead of once for their union. Under the union a single loud region vetoes
  // the whole candidate set — which is why the maintainer's eight include regions
  // evaluate as one mask and his quiet back wall is vetoed by his bolt holes.
  //
  // ★ THIS IS A WIDENING, AND IT WAS MEASURED AND BLOCKED ONCE ALREADY. It is off
  // by default for that reason, not by oversight. Commit eed847b built, tested and
  // deliberately DISARMED it: a pre-registered bar paired a 3 % aggregate exposure
  // cap with a 0.10 % certified-margin bound, and on a real part a single region at
  // 2.889 % exposure — INSIDE the cap — moved the composite margin +0.1801 %, which
  // is 1.8x the bound. The rule stated in advance was to report the number rather
  // than move the threshold, so the widening stayed off. Nothing in this task
  // re-measures that. What changes here is only that it is now REACHABLE by a user
  // who reads the exposure and margin the receipt reports and decides for himself,
  // instead of being unreachable behind a `(void)` in run_job.cpp.
  bool subfloor_per_region = false;
};

// One load group of a declared load case (handoff 093): its faces are chosen
// GEOMETRICALLY (the same selector rule as fixture_faces), and its total force
// (newtons) is spread as a distributed traction over them. Mirrors one
// BridgeLoadCase load group so the CLI and app express the same load case.
struct JobLoadGroup {
  // Faces may be chosen GEOMETRICALLY (`faces`, hand-authored jobs) OR given as
  // RAW B-rep face ids (`face_ids`, the id form the iPad app's interactive
  // selection produces and the LAN worker forwards). Exactly one form per group.
  std::vector<JobFaceSelector> faces;  // every match tagged LOAD
  std::vector<int> face_ids;           // raw B-rep face ids, tagged LOAD
  Vec3 force{0.0, 0.0, 0.0};           // fx, fy, fz in N
};

// One "Keep clear" clearance region (handoff 100) — the CLI counterpart of the
// app's per-face clearance. `face_id` is a raw B-rep face id (the id form the app
// / LAN worker forwards); `kind` is "bolt" (swept cylinder about a bore) or
// "face" (a bounded slab in front of a plane). The mm distances are the editable,
// judgement-call numbers the app prefills — the CLI defaults them to the same
// suggestions when omitted. So a desktop worker honours protected holes
// identically to the app (production_parity: one builder, both front-ends).
struct JobClearance {
  int face_id = -1;
  std::string kind;  // "bolt" | "face"
  double concentric_margin_mm = 0.0;  // bolt: keep-out radius = bore_r + this
  double axial_clearance_mm = 0.0;    // bolt: sweep this far past each face
  double slab_depth_mm = 0.0;         // face: extrude the outline outward this far

  // MANUAL (user-placed) geometry (handoff group-editing). A clearance entry is
  // EITHER an auto face (`face_id >= 0`, `manual == false`, geometry derived from
  // the B-rep) OR a manual primitive (`manual == true`, `face_id == -1`, geometry
  // supplied here). The job schema requires exactly one of the two: a `geometry`
  // object OR a `face_id`. The kind-appropriate half of these fields is read.
  bool manual = false;
  Vec3 axis_point{0.0, 0.0, 0.0};  // bolt
  Vec3 axis_dir{0.0, 0.0, 0.0};    // bolt (unit not required)
  double radius_mm = 0.0;          // bolt: bore radius
  double half_length_mm = 0.0;     // bolt: half the cylinder's own axial extent
  Vec3 origin{0.0, 0.0, 0.0};      // face
  Vec3 normal{0.0, 0.0, 0.0};      // face (outward; unit not required)
  double half_u_mm = 0.0;          // face: in-plane half-extent (u)
  double half_w_mm = 0.0;          // face: in-plane half-extent (w)
};

// Optional "variant" block — REQUIRED by, and allowed ONLY in, mode
// "lattice_variant" (task 2026-08-02-lattice-a-variant). It names the finished
// design this job is to lattice: a variant of a COMPLETED run, read back from
// that run's design.bin (design_store.hpp).
//
// WHY A STORED DESIGN AND NOT A MESH. The obvious workaround — export the
// variant's STL and re-import it as the model — fails three ways, all
// correctly: a topology-optimized surface has no clean pseudo-faces so the
// anchors and loads cannot be re-selected; the min-feature check refuses its
// thin tendrils; and a fresh import carries no stress field to grade from. It
// is also LOSSY in the way that matters most: the mesh is the 0.5 iso-surface
// of a grayscale field, so its re-voxelization is a DIFFERENT design, and the
// certificate would describe that different object. This block points at the
// FIELD instead, which is the same object the gate already certified.
struct JobVariantRef {
  bool present = false;
  // Path to the originating run's design.bin. Relative paths resolve against
  // the job file's directory, exactly like "model".
  std::string design;
  // Which variant. EXACTLY ONE of the three forms, validated at parse:
  //   index            — position in the container (0-based), the form a
  //                      front-end listing variants in order produces;
  //   volume_fraction  — the ladder rung, the join key fields.bin already
  //                      documents. Matched exactly; no nearest-rung guessing,
  //                      because latticing a rung the user did not pick is
  //                      precisely the silent-surprise failure this job exists
  //                      to avoid.
  //   fingerprint      — the design FINGERPRINT (design_store.hpp's FNV-1a over
  //                      the density field), as a DECIMAL STRING.
  //
  // *** WHY THE FINGERPRINT FORM EXISTS (task
  // 2026-08-04-variant-volume-fraction-mismatch). *** `volume_fraction` is a
  // JOIN KEY on the stored block's `requested_volume_fraction`, but it is
  // validated as if it were a DENSITY FRACTION — bounded to (0, 1]. On a GROWTH
  // ladder (minimize_plastic off) the rungs are part-relative and legitimately
  // exceed 1: production_growth_ladder() is {1.55, 1.25, 1.10}, so the only
  // correct selector for the last rung is the number 1.1, and the bound rejected
  // it. Every re-lattice of a growth variant died at schema validation in ~48 ms.
  //
  // The bound is NOT the thing to widen: a fraction that describes a part is
  // exactly what must stay in (0, 1]. What was wrong is that a POSITION IN A
  // LADDER was being carried in a field shaped like a fraction. So a variant is
  // now named by its IDENTITY instead — the hash of the density field itself,
  // which cannot alias another rung, cannot go out of range, and is the same
  // number bar Z3 already uses to tie "the certified object" to "the exported
  // one". A STRING because an FNV-1a u64 does not survive a JSON double.
  bool has_index = false;
  int index = 0;
  bool has_volume_fraction = false;
  double volume_fraction = 0.0;
  bool has_fingerprint = false;
  std::uint64_t fingerprint = 0;

  // The variant's OWN achieved volume fraction, carried DESCRIPTIVELY and
  // CHECKED (task 2026-08-04-variant-volume-fraction-mismatch, bar A3). Optional;
  // when present it must equal the selected block's `achieved_volume_fraction`
  // EXACTLY or the job refuses. That is a strictly stronger guard than any range
  // bound: it is the front-end asserting, on the shipping path, that the number
  // it showed the user is the number the design actually achieved.
  //
  // NOT bounded above. On a growth ladder `achieved_volume_fraction` is
  // part-relative and legitimately exceeds 1 — MEASURED at 1.0866043075327818 for
  // the 1.10 rung of the maintainer's WallMount run (design.bin of worker job
  // efa7cfd3b4e344c6). A (0, 1] bound here would refuse the true number.
  bool has_achieved_volume_fraction = false;
  double achieved_volume_fraction = 0.0;
};

// A declared load case (ARCHITECTURE §1 mode (a)) — the CLI counterpart of the
// app's BridgeLoadCase. Optional in job.json (the "loads" block). When present,
// the run optimizes under these anchors + forces instead of self-weight; when
// absent, the run is the self-weight + fixture_faces path (unchanged). Both feed
// the SAME core builder (build_production_loadcase) as the app.
struct JobLoadCase {
  bool present = false;                     // "loads" block was given
  std::vector<JobFaceSelector> anchors;     // geometric selectors -> FIXTURE
  std::vector<int> anchor_face_ids;         // OR raw B-rep face ids -> FIXTURE
  std::vector<JobLoadGroup> groups;         // distributed tractions
  std::vector<JobClearance> clearances;     // "Keep clear" keep-out regions
  // Handoff 124 — Face protections (preserve-skin). Raw B-rep face ids whose OWN
  // part material the optimizer may not touch; the core freezes the part-solid
  // skin behind each to `face_protection_depth_mm` as FrozenSolid. ONE global
  // depth governs all of them; <= 0 (or omitted) means "use the core default"
  // (kFaceProtectionDepthDefaultMm). Empty => no protection => byte-identical.
  std::vector<int> face_protection_face_ids;
  double face_protection_depth_mm = -1.0;   // <= 0 => core default
  // ★ PER-FACE protection depth (task 2026-08-12 §0a). Either empty (every
  // protection uses the global depth — the pre-task wire, byte-identical) or
  // parallel to `face_protection_face_ids`. An entry <= 0 means "use the global".
  // Produced by the object form of "face_protections":
  //     "face_protections": [ {"face_id": 16, "depth_mm": 7} ]
  // alongside the legacy integer form, which is still accepted unchanged.
  std::vector<double> face_protection_depths_mm;
  Vec3 build_dir{0.0, 0.0, 1.0};            // interlayer-margin orientation
  double infill_percent = -1.0;             // < 0 = no override
  bool minimize_plastic = true;             // true = reduction ladder + pad
  // Width-aware knockdown (handoff 2026-07-26-width-aware-knockdown). Slicer wall
  // metadata crossing the bridge for the first time: the perimeter loop count and
  // its INNER / OUTER line widths, so the accept gate can size the solid wall ring
  // t = outer + (loops-1)·inner around each member. Read only when the width-aware
  // gate is armed (a separate maintainer decision); 0 loops / negative line width →
  // no override → no wall rescue. See
  // MinimizePlasticOptions::{wall_loops, wall_line_width_mm, wall_line_width_outer_mm}.
  int wall_loops = 0;                        // 0 = none (no wall rescue)
  double wall_line_width_mm = -1.0;          // inner; < 0 = core default (0.45)
  double wall_line_width_outer_mm = -1.0;    // outer; < 0 = mirror inner
};

// An axis-aligned box in model space (mm), min <= max componentwise — a design
// box or a keep-out. Deliberately a job-local POD so the schema owns its own
// validation; run_job copies it into a core DesignBox.
struct JobBox {
  Vec3 min{0.0, 0.0, 0.0};
  Vec3 max{0.0, 0.0, 0.0};
};

// A parsed, schema-valid job.json.
struct JobDescription {
  std::string model;     // model file path; relative paths resolve against the
                         // job file's directory
  // Optional. The TRUE source format the user supplied, when the `model` file is
  // a working copy in a different format (handoff 2026-07-26-3mf-optimize-path):
  // the app normalises a 3MF import to an STL working copy so the optimize path
  // never re-parses 3MF, then records "3mf" here so run_info still names the real
  // source. Empty => run_info derives the format from `model`'s extension, which
  // is the honest answer for a job that references the source file directly.
  std::string source_format;
  std::string material;  // key into materials.json (validated by run_job)
  // "minimize_plastic" (the optimize ladder — run_job), "analyze" (ONE
  // fixed-design analysis solve — analyze_job; task lattice-page-core-hookup
  // stage 3, so the LAN worker can route a RUN-SIM job), or "lattice_variant"
  // (LATTICE A FINISHED VARIANT — lattice_variant_job; task
  // 2026-08-02-lattice-a-variant: no optimization ladder, no design
  // iterations). Anything else is refused at parse; run_job refuses everything
  // but "minimize_plastic" (it never optimizes a job that did not ask to be
  // optimized), while analyze_job accepts "minimize_plastic" and "analyze"
  // (re-certifying an optimize job's model is the existing receipt flow).
  std::string mode;
  int resolution = 0;    // voxelizer resolution along the longest axis, >= 1
  std::vector<JobFaceSelector> fixture_faces;  // self-weight path: all matches
                                               // tagged FIXTURE (may be empty
                                               // when a "loads" block is given)
  JobGravity gravity;

  // Optional "build_direction": [x, y, z] — THE BUILD-PLATE NORMAL (handoff
  // 2026-08-01-build-direction-separation). "Which way is up on the plate", a
  // DIFFERENT question from gravity's "which way is down in service"; the job
  // schema had never asked the second one, so all three certification paths
  // inferred it as -gravity. Allowed in BOTH modes (unlike "gravity", which
  // loadcase mode forbids) — a load-case job has a service orientation too.
  //
  // ABSENT (has_build_direction == false) => today's behaviour EXACTLY: the core
  // falls back to unit(-gravity_direction) inside resolve_build_direction. Every
  // existing job stays byte-identical; that is the load-bearing bar (U1).
  //
  // In loadcase mode this key OVERRIDES "loads.build_dir" for the BUILD
  // direction. "loads.build_dir" keeps its existing job: it sets the service
  // gravity to its unit negation. That is the separation — the two keys stop
  // being one field doing two jobs.
  bool has_build_direction = false;
  Vec3 build_direction{0.0, 0.0, 0.0};

  // Optional "build_orientation_report": true — arm the ORIENTATION SCORER, a
  // post-pass on the certification solve that already ran (handoff
  // 2026-08-01-build-direction-separation; PR 266 measured it at 0.1-0.4% of
  // that solve). Ranks candidate build directions on six criteria and names a
  // recommendation on the receipt.
  //
  // IT NEVER AUTO-APPLIES AND NEVER MOVES A VERDICT. The gate is computed from
  // the orientation ACTUALLY USED; when the recommendation would gate
  // differently the receipt says so in both directions and the user chooses.
  //
  // FALSE (the default) => no scorer, no new report fields, byte-identical
  // output. Deliberately independent of "build_direction": the user who has NOT
  // chosen an orientation is exactly the one the ranking helps most.
  bool build_orientation_report = false;

  // Optional "bake_build_orientation": "auto" | "always" | "off" (handoff
  // 2026-08-01-bake-build-orientation). Governs whether the EXPORTED VERTICES
  // are rotated so the certified build direction is +Z in the file.
  //
  // The export was never reoriented before this key existed: the certified
  // orientation lived only as a number in report.json, the slicer placed the
  // part however it liked, and the certificate described a different object from
  // the one being sliced.
  //
  //   "auto" (THE DEFAULT) — bake only when no "build_direction" was declared,
  //       and then also CHOOSE the orientation (the scorer's best candidate) and
  //       certify THAT one. A job that declares a direction is untouched and
  //       bit-identical.
  //   "always" — bake whatever direction is resolved, declared or not. The
  //       opt-in for a user who wants their DECLARED orientation carried by the
  //       geometry instead of by a transform the slicer may reset.
  //   "off" — never bake, never choose: the pre-bake pipeline, byte for byte.
  //
  // ABSENT => "auto". This is the one place in the schema where an absent key
  // does NOT mean "the older behaviour", and it is deliberate: a certificate for
  // an orientation the file does not carry is the defect, and defaulting it off
  // would leave the defect in place for every job that never heard of the key.
  std::string bake_build_orientation;  // "" => "auto"

  std::vector<double> ladder;  // volume fractions, (0,1], strictly descending
  double margin_stop = 0.0;    // finite >= 0 (0 disables the stop)
  int simp_max_iterations = 0;  // optional "simp" block; 0 = SimpOptions default
  JobOutput output;
  JobLattice lattice;  // optional "lattice" block; absent => byte-identical run
  JobGrading grading;  // optional "grading" block; absent => byte-identical run

  // Optional "draft" block (handoff 2026-07-25-draft-quality): the approximate-
  // trajectory / exact-certification posture. Absent (has_draft == false, the
  // DEFAULT) => the fields below are ignored and the run keeps the driver's OFF
  // default (byte-identical). When present, mapped onto MinimizePlasticOptions::
  // draft_quality / draft_loose_tol / draft_escalation_c_gap in run_job.
  bool has_draft = false;
  bool draft_quality = false;
  double draft_loose_tol = 1e-3;
  double draft_escalation_c_gap = 0.02;
  // Phase 2 (handoff 2026-07-26-draft-quality-phase2): the design-space trigger.
  bool draft_use_design_trigger = false;       // arms it (replaces the gap decision)
  double draft_escalation_design_flip = 0.0;   // threshold (0 = the noise floor)
  int draft_probe_iters = 1;

  // Optional "warm_start" block (handoff 110 Part B). Absent (has_warm_start ==
  // false, the DEFAULT) => the field below is ignored and the run keeps the
  // driver's OFF default (byte-identical). When present, mapped onto
  // MinimizePlasticOptions::warm_start_coarse in run_job. This is a per-run
  // ARMING switch, not a default change: the driver default stays false.
  bool has_warm_start = false;
  bool warm_start_coarse = false;
  // Task 2026-08-10-plsm-production, S3(b): arm the TRAJECTORY warm start on the
  // matrix-free solver (SimpOptions::matfree_warm_start). Absent => false, the
  // byte-identical default. Trajectory-only — the certification solve is never
  // warm-started, whatever this says.
  bool warm_start_matfree = false;

  // Optional "semdot" block (task 2026-08-08-semdot-does-it-come-out-smoother).
  // Absent (has_semdot == false, the DEFAULT) => the fields below are ignored and
  // the run keeps the driver's OFF default (byte-identical). When present, mapped
  // onto MinimizePlasticOptions::simp.semdot / semdot_grid_points in run_job.
  // See topopt/semdot.hpp for what the mode is and SimpOptions::semdot for what
  // it changes and what it refuses.
  bool has_semdot = false;
  bool semdot = false;
  int semdot_grid_points = kSemdotDefaultGridPoints;

  // Optional "plsm" block (task 2026-08-10-plsm-production): THE PARAMETRIC
  // LEVEL SET as the design representation, in place of SIMP's density field.
  // ABSENT (has_plsm == false, the DEFAULT) => the fields below are ignored and
  // the run keeps MinimizePlasticOptions::plsm.mode == PlsmMode::Off, which is
  // byte-identical to every run made before this feature existed. When present
  // they are mapped onto MinimizePlasticOptions::plsm in run_job.
  //
  // ★ `plsm_knots` IS THREE NUMBERS, PER AXIS, IN VOXELS, AND ALL-ZERO IS THE
  // RIGHT ANSWER. Zero means "derive the spacing from the grid"
  // (plsm_knots_for_grid) — the production rule, and the only setting that
  // follows a change of resolution. The schema offers no scalar form: a single
  // knot spacing for three axes is exactly the shape of the trap PR 323 lost a
  // day to (GridapTopOpt's alpha rule reading `minimum(el_size)` on a 4:1 slab).
  //
  // ★★ EVERY DEFAULT BELOW IS READ OUT OF `PlsmOptions` AND NOT RETYPED, AND
  // THAT IS A DEFECT CLASS THIS TASK FOUND RATHER THAN A STYLE CHOICE. These
  // fields are copied onto `MinimizePlasticOptions::plsm` WHENEVER a job carries
  // a plsm block, so a hand-written default here SILENTLY OVERRIDES the
  // production one for every job that uses the feature. `eta_voxels` and
  // `max_iterations` were both duplicated as literals here; changing the
  // production defaults alone would have shipped two no-ops.
  bool has_plsm = false;
  bool plsm_enabled = false;
  std::string plsm_basis = PlsmOptions{}.basis;
  double plsm_knots[3] = {0.0, 0.0, 0.0};  // VOXELS, per axis; 0 = derive
  double plsm_support = PlsmOptions{}.support;
  double plsm_eta_voxels = PlsmOptions{}.eta_voxels;
  int plsm_max_iterations = PlsmOptions{}.max_iterations;
  std::string plsm_seed = PlsmOptions{}.seed;
  int plsm_refit_every = PlsmOptions{}.refit_every;
  double plsm_move = PlsmOptions{}.move;
  double plsm_cg_tolerance_loose = PlsmOptions{}.cg_tolerance_loose;
  bool plsm_warm_start = PlsmOptions{}.warm_start;
  // ── the volume-fraction ersatz and the margin-plateau stop (2026-08-13) ────
  // "fraction" | "heaviside". The second is PR 324/325/326's centre-sampled
  // smoothed Heaviside, kept reachable so the change is an A/B on this path.
  std::string plsm_ersatz = "fraction";
  int plsm_frac_samples = PlsmOptions{}.frac_samples;
  double plsm_frac_eps_mult = PlsmOptions{}.frac_eps_mult;
  bool plsm_frac_mollified = PlsmOptions{}.frac_mollified;
  bool plsm_frac_sens_exact = PlsmOptions{}.frac_sens_exact;
  bool plsm_frac_eps_l1 = PlsmOptions{}.frac_eps_l1;
  int plsm_margin_probe_every = PlsmOptions{}.margin_probe_every;
  int plsm_margin_plateau_probes = PlsmOptions{}.margin_plateau_probes;
  double plsm_margin_plateau_tol = PlsmOptions{}.margin_plateau_tol;

  // Optional declared load case (the "loads" block). When present the run uses
  // build_production_loadcase (anchors + forces) instead of self-weight.
  JobLoadCase loads;

  // The finished variant to lattice — mode "lattice_variant" only. See
  // JobVariantRef.
  JobVariantRef variant;

  // Optional design-domain expansion (the "add material" feature, handoff 093):
  // the optimizer may grow material into this box beyond the imported part, with
  // keep_out_boxes left void. Absent => the run stays on the imported grid.
  bool has_design_box = false;
  JobBox design_box;
  std::vector<JobBox> keep_out_boxes;
};

// Parse and schema-validate a job document. Throws JobError on malformed JSON,
// an unknown (non-underscore) key at any level, a missing required key, or a
// type/value violation. The diagnostic names the offending key.
JobDescription parse_job(const std::string& json_text);

// Read the file at `path` and parse it via parse_job(). Throws JobError if the
// file cannot be opened.
JobDescription load_job_file(const std::string& path);

// Handoff 114 — per-run OBSERVABILITY configuration for run_job. Only consulted
// when `emit_progress` is true (the topopt-cli path); in-process callers leave it
// default and write nothing, so their runs are byte-identical. Observability
// artifacts land in `out_dir` (so they are zipped/served alongside the meshes):
//   run_info.json     the version + config record (always, on the CLI path)
//   iterations.csv    the per-iteration CSV (default ON; iteration_csv disables)
//   snapshots/*.f16   density snapshots (opt-in; default OFF — disk cost is real)
// Capture is a pure OBSERVER: the design bytes are identical whatever is enabled.
struct RunObservability {
  // Per-iteration CSV. DEFAULT ON for CLI runs — it is observability, not solver
  // behavior, and ~80 KB for a full production run; set false (--no-iteration-csv)
  // to disable.
  bool iteration_csv = true;

  // Density snapshots. DEFAULT OFF — one float16 snapshot of the real 5.4M-voxel
  // domain is ~10.8 MB, and a 500-iter run at every=10 is ~550 MB. Opt in with
  // --snapshots. Written every `snapshot_every` iterations, plus every rung
  // boundary + terminal; the per-job `snapshot_cap` bounds disk by evicting the
  // oldest per-iteration snapshot (rung-boundary snapshots are never evicted).
  bool density_snapshots = false;
  int snapshot_every = 10;
  int snapshot_cap = 40;  // ~430 MB worst case at 10.8 MB/snapshot

  // The core build fingerprint (topopt-cli --version fingerprint), stamped into
  // run_info.json so the era is provable (the 113 lesson). The CLI passes its
  // compiled TOPOPT_BUILD_FINGERPRINT; other callers may leave it empty.
  std::string fingerprint = "unknown";

  // ★ HOW MUCH OF THE MACHINE THIS RUN MAY TAKE (task 2026-08-10-plsm-production).
  // 0 (the DEFAULT) = leave the production rule alone: run_job applies
  // production_matfree_thread_count(), the performance-core pin, and the run is
  // byte-for-byte what it was. > 0 overrides the matrix-free apply's thread count
  // AFTER configure_production_options has run (which is why it lives here and
  // not in a global the caller sets before the run — that would be overwritten).
  //
  // It is a PURE PERFORMANCE CONTROL and CANNOT MOVE A NUMBER: the apply threads
  // a deterministic 8-colour (2x2x2) partition of the voxel grid, so no two
  // threads touch the same node and the accumulation order is fixed regardless of
  // the count — fea.hpp states the result is BIT-IDENTICAL for any thread count.
  // It is here because a run that pins every performance core makes the machine
  // unusable for the hours it takes, and "wait until tonight" is not a setting.
  int matfree_threads = 0;
};

// The outcome of run_job, exposing enough for callers (the CLI main and the
// integration test) to summarize and verify the run without re-reading files.
struct RunJobResult {
  StepModel model;                     // the imported model (geometry facts)
  std::vector<int> fixture_face_ids;   // B-rep faces matched by the selectors
  MinimizePlasticResult pipeline;      // the M5.3 driver's full result
  std::string report_path;             // <out_dir>/<output.report>
  std::string report_json;             // the bytes written to report_path
  // The BUILD-ORIENTATION RECEIPT (handoff 2026-08-01-build-direction-separation):
  // <out_dir>/build_orientation.json, the ranking + the recommendation + the U5
  // both-verdicts statement for the recommended (lightest accepted) variant.
  // EMPTY unless the job armed "build_orientation_report" — a separate document
  // precisely so report.json / fields.bin / the meshes are byte-identical whether
  // the scorer ran or not.
  std::string build_orientation_path;
  std::string build_orientation_json;
  std::vector<std::string> mesh_paths; // one exported mesh per accepted variant
  // Handoff 122 — the per-voxel result FIELDS container (<out_dir>/fields.bin):
  // one versioned block per accepted variant carrying the von Mises / displacement
  // fields + the voxel mass & support summary, so a LAN remote run gets the same
  // overlays a local run does. Written for every run (batch AND streaming). See
  // topopt/fields.hpp for the format. Empty only if the run produced no output dir.
  std::string fields_path;             // <out_dir>/fields.bin
  int fields_variant_count = 0;        // accepted-variant blocks written
  // Task 2026-08-02-lattice-a-variant — the per-variant DESIGN container
  // (<out_dir>/design.bin): each evaluated variant's own density field, so a
  // finished variant can be latticed later WITHOUT re-running the ladder and
  // WITHOUT the lossy export-and-re-import round trip. See design_store.hpp.
  std::string design_path;             // <out_dir>/design.bin
  int design_variant_count = 0;        // variant blocks written
  // Task 2026-08-02-lattice-a-variant, bar Z2 — the LOAD-CASE RECEIPT
  // (<out_dir>/loadcase.json): every fact that determines the load this run
  // resolved (anchor faces + clamped DOF; per force group the resolved
  // magnitude and the voxels its faces actually tagged; clearances and
  // protections). A later re-lattice run writes the SAME document from the SAME
  // emitter, so "it certified under the same load case" is a byte comparison
  // rather than an argument.
  std::string loadcase_receipt_path;   // <out_dir>/loadcase.json
  std::string loadcase_receipt_json;
  // Handoff 114 — observability artifacts written to out_dir (empty when not
  // written, e.g. in-process callers with emit_progress=false).
  std::string run_info_path;           // <out_dir>/run_info.json (CLI path)
  std::string iteration_csv_path;      // <out_dir>/iterations.csv (when enabled)
  std::size_t snapshot_count = 0;      // density snapshots written (when enabled)
  // Task 2026-08-03-preflight-feasibility-and-divergence, guard 1 — what the
  // PRE-FLIGHT load-path check found before any solve ran. `ran` is false only
  // for a caller that never reached it. A run that REFUSED never returns a
  // result at all (it throws JobError with the actionable message), so on a
  // returned result this always reads CONNECTED or VACUOUS — the value is the
  // narrowest-cross-section reading and the measured cost (bar P4/P6).
  PreflightLoadPath preflight;
};

// The result of PRE-FLIGHTING a job without solving it (task 2026-08-03-
// preflight-feasibility-and-divergence).
struct PreflightJobResult {
  StepModel model;
  std::vector<int> fixture_face_ids;
  PreflightLoadPath preflight;
  // The actionable refusal text — non-empty exactly when the load path is
  // DECIDABLE and NOT CONNECTED, i.e. exactly when `run` would refuse this job.
  // It is the same string, from the same builder (preflight_refusal_report), so
  // "what would run say?" is answered without running.
  std::string refusal;
  bool would_refuse = false;
  double wall_ms = 0.0;  // import + setup + check, end to end
};

// PRE-FLIGHT a job WITHOUT SOLVING IT: import the model, build the identical
// setup `run_job` builds (build_job_setup — the same call, not a second
// derivation), resolve the design domain, and run the load-path connectivity
// check. No solve, no output directory, nothing written.
//
// It exists for two reasons. A user (or the app) can ask "will this job even
// have a load path?" for the cost of a voxelization instead of a ladder; and a
// SWEEP over archived jobs can prove the guard refuses none of them, which is
// the no-false-refusals bar this feature had to clear before shipping.
//
// Throws JobError on the same import / mode / material conditions run_job does.
PreflightJobResult preflight_job(const JobDescription& job,
                                 const std::string& job_dir,
                                 const MaterialLibrary& materials);

// Run one job end-to-end (§5): import the STEP model (relative `job.model`
// resolves against `job_dir`), select + tag the fixture faces geometrically,
// check watertightness, voxelize at job.resolution, run minimize_plastic under
// the job's self-weight (materials.json density_g_cm3 is converted to the
// mm-MPa-consistent t/mm^3 by folding the 1e-9 factor into the gravity
// magnitude, so reported stresses are MPa), then write the report and one mesh
// per accepted variant into `out_dir` (created if absent).
//
// Throws JobError for job-level failures: a material not in `materials`, a
// mode other than minimize_plastic, an unimportable/non-watertight model, a
// selector matching no face, a mesh_format the build cannot write (3MF without
// lib3mf), or an unwritable output. Propagates StepError / std::invalid_argument
// / solver errors from the underlying stages.
// When `emit_progress` is true (the topopt-cli binary sets it; in-process callers
// and tests leave it false, keeping the run byte-identical), run_job streams the
// run to STDOUT as structured, machine-parseable checkpoint lines and writes each
// accepted variant's mesh AS IT COMPLETES rather than all at the end, so a wrapper
// (the LAN worker, handoff 093) can forward live progress and progressive
// artifacts instead of blocking until the whole ladder finishes:
//   PROGRESS rung=<i> rungs=<n> iter=<k>          (once per optimizer iteration)
//   VARIANT vf=<req> achieved=<vf> margin=<m> accepted=<0|1> mesh=<path>
//                                                 (once per accepted rung)
// These lines are OBSERVERS: they do not change the design, the report, or the
// exported meshes (identical bytes to the batch path), so determinism holds.
// When `emit_progress` is true, run_job ALSO writes observability artifacts to
// `out_dir` per `obs` (handoff 114): run_info.json (always), the per-iteration
// iterations.csv (default ON), and opt-in density snapshots. These are pure
// observers — the report/mesh bytes are unchanged — so determinism holds.
RunJobResult run_job(const JobDescription& job, const std::string& job_dir,
                     const std::string& out_dir,
                     const MaterialLibrary& materials,
                     const SettingsRules& rules, bool emit_progress = false,
                     const RunObservability& obs = RunObservability{});

// ---------------------------------------------------------------------------
// analyze_job — ONE FEA analysis solve on a FIXED design, NO optimization
// (handoff 2026-07-26-constrained-smooth). The "receipt": re-certify a design
// exactly as run_job certifies each accepted rung (one penalized solve → stress /
// mass / margins / accept gate), but on a design the optimizer did NOT produce.
struct AnalyzeJobResult {
  StepModel model;                     // the imported model (BCs come from ITS faces)
  std::vector<int> fixture_face_ids;   // faces matched by the fixture selectors
  FixedDesignAnalysis analysis;        // stress / mass / margin / gate verdict
  bool analyzed_mesh = false;          // true iff a substitute mesh was re-voxelized
  std::string analyzed_mesh_path;      // that mesh's path ("" when analyzing the solid)
  double voxel_mass_grams = 0.0;       // analysis.mass_grams (the re-analyzed voxel mass)
  double mesh_mass_grams = 0.0;        // enclosed-volume mass of the analysed mesh (0 if solid)
  double margin_required = 0.0;        // the margin_stop the gate USED (job.margin_stop in
                                       // self-weight mode; the production default in loadcase
                                       // mode, where the loads schema rejects a margin_stop key)
  std::string report_path;             // <out_dir>/analysis_report.json (VariantReport schema)
  std::string report_json;             // the bytes written to report_path
  // The BUILD-ORIENTATION RECEIPT for a re-analysis (handoff
  // 2026-08-01-build-direction-separation), same document as the optimize path's.
  // EMPTY unless the job armed "build_orientation_report".
  std::string build_orientation_path;
  std::string build_orientation_json;
  std::string provenance_path;         // <out_dir>/analysis.json (provenance + BOTH masses)
  std::string fields_path;             // <out_dir>/fields.bin (one analysed "variant")

  // Constrained smoothing (handoff 2026-07-26-constrained-smooth-ui). Populated
  // only when the request enabled smoothing; the re-analysed numbers above then
  // describe the SMOOTHED mesh (never the pre-smoothing geometry — the honesty
  // rule). Default (no smoothing) leaves these zero and every byte on the
  // analyse-only path unchanged.
  bool smoothed = false;               // smoothing was applied to the --mesh input
  double smooth_strength = 0.0;        // the strength knob used (0,1]
  SmoothStats smooth_stats;            // frozen count, volume drift + bound, min-feature
  std::string smoothed_mesh_path;      // <out_dir>/<...>_smoothed.stl (the exported mesh)

  // Lattice grading (handoff 2026-07-29-lattice-grading-law). Populated only when the
  // job carried a "grading" block: the certification's von Mises field is fed to the
  // grading law and a run_info.json carrying the "grading" report is written. Default
  // (no grading block) leaves these unset and writes no run_info — byte-identical (L1).
  bool graded = false;
  std::string grading_run_info_path;   // <out_dir>/run_info.json (the grading report)
};

// A constrained-smoothing request for analyze_job (handoff
// 2026-07-26-constrained-smooth-ui). Off by default → analyze_job is byte-for-byte
// its pre-smoothing self. When enabled, analyze_job smooths the --mesh input under
// freeze predicates derived from the MODEL's B-rep (fixture / clearance / protected
// faces → exact cylinder/plane geometry) and the min-feature hard constraint, writes
// the smoothed mesh, then re-certifies THAT mesh through analyze_fixed_design.
struct SmoothRequest {
  bool enabled = false;
  double strength = 0.0;         // (0,1]; ≤0 disables
  int max_pairs = 20;            // strength 1.0 → this many Taubin λ|μ pairs
  double freeze_tol_mm = 0.0;    // ≤0 → default (0.75 × voxel spacing)
  bool enforce_min_feature = true;
};

// Map a job.json "loads" block onto the front-end-neutral ProductionLoadCase the
// core builder (build_production_loadcase) consumes. THE ONE MAPPING: run_job's
// optimize path, analyze_job's re-certification path and lattice_variant_job all
// call it, so a declared load case resolves IDENTICALLY however the job is run.
// Geometric anchor / load-face selectors are resolved against `model` here
// (resolve_selectors THROWS a JobError naming any selector that matches nothing);
// they compose with any raw B-rep face ids.
//
// DECLARED HERE SO IT CAN BE TESTED AT ITS OWN SEAM (task
// 2026-08-06-strut-line-width-field, S0). It lived in run_job.cpp's anonymous
// namespace, which is why the only tests that could reach the wall-width split set
// MinimizePlasticOptions directly and never crossed this boundary — precisely the
// "tests on the value type miss the call site" shape that let PR #228's
// merge-conflict resolution drop `wall_line_width_outer_mm` here for eight days.
ProductionLoadCase production_loadcase_from_job(const JobDescription& job,
                                                const StepModel& model);

// Re-certify a FIXED design under `job`'s load case. Builds the grid / fixtures /
// BCs / loads from the job's MODEL exactly as run_job does — a declared "loads"
// block re-certifies under that EXTERNAL load (the anchors clamp, the force groups
// become distributed tractions, via the SAME production_loadcase_from_job +
// build_production_loadcase seam the optimizer uses); no "loads" block is the
// self-weight + fixture_faces path (unchanged) — then runs ONE analyze_fixed_design
// solve on a fixed density and writes the results with an honest provenance record.
// NEVER optimizes.
//
// A declared load that references a face which does not exist, or whose every
// group tags no voxel / is zero-force, FAILS LOUDLY (JobError) — it never silently
// falls back to self-weight (that silent degradation is the PR-178 bug).
//
// The design analysed is chosen by `analyze_mesh_path`:
//   * ""            — the job's model as a SOLID part (density 1 on every solid
//                     voxel): "certify the part as drawn."
//   * <mesh path>   — a SUBSTITUTE mesh (e.g. a smoothed/edited variant to
//                     re-certify), voxelized onto the run's grid via
//                     voxelize_onto_grid, so the model's node-indexed BCs/loads
//                     still apply. The re-analysis therefore runs on the mesh's
//                     VOXELIZATION at job.resolution — it differs from the printed
//                     surface by up to ~half a voxel; this quantization gap is
//                     recorded in the provenance file, not hidden.
//
// Writes analysis_report.json (the NEW, re-analysed numbers — never the design's
// pre-edit numbers), analysis.json (provenance: analyzed=true, source, resolution,
// the quantization footnote, and BOTH the voxel mass and the analysed-mesh mass),
// and fields.bin. Throws JobError for a bad material/model/selector, a declared
// load referencing a nonexistent / sub-voxel face (never a self-weight fallback),
// or an unwritable output.
AnalyzeJobResult analyze_job(const JobDescription& job, const std::string& job_dir,
                             const std::string& out_dir,
                             const MaterialLibrary& materials,
                             const SettingsRules& rules,
                             const std::string& analyze_mesh_path = "",
                             const SmoothRequest& smooth = SmoothRequest{});

// ---------------------------------------------------------------------------
// lattice_variant_job — LATTICE A FINISHED VARIANT (task
// 2026-08-02-lattice-a-variant). Mode "lattice_variant".
//
// THE JOB THAT DID NOT EXIST. "Pick a variant, lattice it" had no
// implementation. The lattice page could be opened from a variant, but that
// only borrowed the variant's stress field as a grading demand: Optimize there
// re-ran the WHOLE LADDER from the ORIGINAL model, merely graded by a previous
// run's field. This entry point is the missing one — it takes a design the
// optimizer already produced and turns it into a latticed, graded, certified,
// exported object with NO optimization at all.
//
// WHAT IT DOES, IN ORDER:
//   1. Rebuild the load case from the job — which IS the original run's job
//      (the schema requires the `variant` block to sit in it, `mode` swapped),
//      so the anchors / forces / clearances / protections are not re-authored
//      but re-used. Writes the same loadcase.json receipt the optimize run
//      wrote; the two are byte-comparable (bar Z2).
//   2. Read the named variant's DENSITY FIELD back from the originating run's
//      design.bin, fingerprint-checked (design_store.hpp).
//   3. ONE null-posture certification solve on that density. Its margin MUST
//      equal the margin the original run RECORDED for this variant, or the job
//      REFUSES: an unequal margin means the load case, the grid or the design
//      is not the one that produced the variant, and everything after it would
//      be a certificate for a different object. This solve also recovers the
//      variant's own von Mises field, which is what the grading law then
//      consumes — so Auto density needs no separate simulation (bar Z4).
//   4. The shared per-variant lattice pipeline: grade, mask, EMIT the latticed
//      mesh, and certify the composite against the SAME mask and the SAME
//      density (bars Z3 and Z5 — the strut-strength report rides that solve).
//
// NO LADDER RUNS. Zero design iterations, zero variant meshes; the only solves
// are certification solves, and the count is recorded on the result and in the
// provenance file rather than asserted in a comment.
struct LatticeVariantJobResult {
  StepModel model;
  std::vector<int> fixture_face_ids;

  // WHICH design was latticed.
  int variant_index = 0;                     // position in design.bin
  double requested_volume_fraction = 0.0;    // its ladder rung
  double achieved_volume_fraction = 0.0;
  int optimizer_iterations = 0;              // that produced it, ORIGINALLY
  unsigned long long design_fingerprint = 0; // the stored field's hash

  // THE REPRODUCTION PROOF (step 3 above).
  double recorded_margin_worst_case = 0.0;   // as the original run recorded it
  double reproduced_margin_worst_case = 0.0; // as this job re-derived it
  // BIT-equality of the two above. REPORTED, no longer enforced: the recorded
  // margin came from a solve that carried a warm Krylov recycle subspace and this
  // one is denied it by ScopedLadderSolverIsolation, so on any run whose solves
  // fall back to Jacobi-CG this is false and always was. See analyze.hpp's
  // kMarginReproductionResidualFactor note for the full mechanism.
  bool reproduction_exact = false;
  // What is ENFORCED: the two margins agree inside the band the certification
  // solve's own relative-residual tolerance justifies. False never returns.
  bool reproduction_within_band = false;
  double reproduction_relative_delta = 0.0;  // |repro - recorded| / |recorded|
  double reproduction_band = 0.0;            // the band it was judged against

  FixedDesignAnalysis solid;    // the null-posture (SOLID) certification
  FixedDesignAnalysis lattice;  // the composite (LATTICED) certification

  // NO-LADDER accounting (bar Z1) — reported, not claimed.
  int analysis_solves = 0;        // certification solves actually run
  int design_iterations = 0;      // always 0
  int variant_meshes_written = 0; // always 0 (only the latticed file is written)
  double wall_seconds = 0.0;      // the whole job, end to end

  // Grading readout (bar Z4) — the achieved per-voxel density RANGE.
  bool graded = false;
  double cell_size_mm = 0.0;
  double rho_min_used = 0.0;
  double rho_max_used = 0.0;
  long long latticed_voxels = 0;

  std::vector<std::string> mesh_paths;  // the latticed file(s)
  std::string lattice_receipt_path;     // <prefix>_<vf>_lattice.report.json
  std::string lattice_receipt_json;
  std::string report_path;              // <out_dir>/lattice_variant_report.json
  std::string report_json;
  std::string provenance_path;          // <out_dir>/lattice_variant.json
  std::string loadcase_receipt_path;    // <out_dir>/loadcase.json
  std::string loadcase_receipt_json;
  std::string run_info_path;            // <out_dir>/run_info.json (grading record)
  std::string fields_path;              // <out_dir>/fields.bin
  // FORECAST-ONLY runs (job.lattice.forecast_only): the only two fields set, and
  // every field above is left at its default because no solve ran.
  std::string forecast_path;            // <out_dir>/lattice_forecast.json
  std::string forecast_json;
};

// Lattice the variant named by `job.variant`. Throws JobError for a bad
// material / model / selector, a design.bin that cannot be read or does not
// match this job's grid, a variant reference that names no stored design, a
// declared load that resolves to nothing, a reproduction mismatch (see above),
// or an unwritable output. NEVER optimizes.
LatticeVariantJobResult lattice_variant_job(const JobDescription& job,
                                            const std::string& job_dir,
                                            const std::string& out_dir,
                                            const MaterialLibrary& materials,
                                            const SettingsRules& rules);

}  // namespace topopt
