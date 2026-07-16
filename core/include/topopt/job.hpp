#pragma once

#include <stdexcept>
#include <string>
#include <vector>

#include "topopt/materials.hpp"  // MaterialLibrary
#include "topopt/mesh.hpp"       // Vec3
#include "topopt/pipeline.hpp"   // MinimizePlasticResult
#include "topopt/settings.hpp"   // SettingsRules
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
};

// A parsed, schema-valid job.json.
struct JobDescription {
  std::string model;     // model file path; relative paths resolve against the
                         // job file's directory
  std::string material;  // key into materials.json (validated by run_job)
  std::string mode;      // "minimize_plastic" (the only supported mode)
  int resolution = 0;    // voxelizer resolution along the longest axis, >= 1
  std::vector<JobFaceSelector> fixture_faces;  // non-empty; all matches are
                                               // tagged FIXTURE
  JobGravity gravity;
  std::vector<double> ladder;  // volume fractions, (0,1], strictly descending
  double margin_stop = 0.0;    // finite >= 0 (0 disables the stop)
  int simp_max_iterations = 0;  // optional "simp" block; 0 = SimpOptions default
  JobOutput output;
};

// Parse and schema-validate a job document. Throws JobError on malformed JSON,
// an unknown (non-underscore) key at any level, a missing required key, or a
// type/value violation. The diagnostic names the offending key.
JobDescription parse_job(const std::string& json_text);

// Read the file at `path` and parse it via parse_job(). Throws JobError if the
// file cannot be opened.
JobDescription load_job_file(const std::string& path);

// The outcome of run_job, exposing enough for callers (the CLI main and the
// integration test) to summarize and verify the run without re-reading files.
struct RunJobResult {
  StepModel model;                     // the imported model (geometry facts)
  std::vector<int> fixture_face_ids;   // B-rep faces matched by the selectors
  MinimizePlasticResult pipeline;      // the M5.3 driver's full result
  std::string report_path;             // <out_dir>/<output.report>
  std::string report_json;             // the bytes written to report_path
  std::vector<std::string> mesh_paths; // one exported mesh per accepted variant
};

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
RunJobResult run_job(const JobDescription& job, const std::string& job_dir,
                     const std::string& out_dir,
                     const MaterialLibrary& materials,
                     const SettingsRules& rules);

}  // namespace topopt
