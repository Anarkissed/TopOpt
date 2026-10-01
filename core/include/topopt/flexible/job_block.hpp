#pragma once

#include <memory>
#include <string>
#include <vector>

#include "topopt/flexible/field.hpp"  // StampGrid, SquishMap
#include "topopt/job.hpp"             // JobDescription, JobLatticeRegion
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

namespace topopt {

// ════════════════════════════════════════════════════════════════════════════════
// F11 — THE `flexible` JOB BLOCK (task 2026-09-28-flexible-squish-maths)
//
// Optional. Absent => JobDescription::flexible is null and every existing job is
// byte-identical. Strict: an unknown key, a missing required key or a bad value is
// refused with the key named. A job carrying BOTH `flexible` and `lattice` (or
// `grading`) is refused: they are different lattice stages.
//
//   "flexible": {
//     "material_id": "varioshore_tpu",           must equal the job's "material"
//     "nozzle_temp_c": 220 | "auto",              "auto": every tested temperature
//     "topology": "auto" | "gyroid" | "honeycomb",
//     "feel": "springy" | "damped",
//     "beads_per_wall": 1 | 2,
//     "min_extrudable_width_mm": 0.42,            THE bead width (see below)
//     "regions": [ ... ],                         optional; lattice.regions schema
//     "faces": [ {
//        "face_region_id": 101, "role": "loaded" | "resting",
//        "frame_rotation_deg": 0 | 90 | 180 | 270,   optional, default 0
//        "weight_n": 294.3, "deepest_squish_mm": 4,
//        "mode": "both" | "either" | "centre_edge",
//        "curve_x": [[0, 0.2], [0.5, 1], [1, 0.2]],  both/either
//        "curve_y": [[0, 0.2], [0.5, 1], [1, 0.2]],  both/either
//        "curve_centre_edge": [[0, 0], [1, 1]],      centre_edge
//        "design_stamp": { stamp } | null,           optional
//        "skin_on": true } ],                         required (M15)
//     "check_stamps": [ { "face_region_id": 101, stamp } ]   optional
//   }
//   stamp = { "name", "mode": "soft" | "rigid", "force_n", "origin_mm": [u, v],
//             "cell_mm", "nu", "nv", "values_mpa": [nu*nv, row-major in v] }
//
// ★ THE BEAD WIDTH IS `min_extrudable_width_mm` — the key the lattice strut floor
// reads (lattice.min_extrudable_width_mm / grading.min_extrudable_width_mm, "the
// thinnest bead the user says the machine lays"). A Flexible job cannot carry a
// lattice or grading block, so it states the same key in its own block, with the
// same meaning; no new width concept is introduced (03 §1). Required: printability
// is user input, never a default.
//
// ★ REGIONS ARE PARSED BY THE LATTICE PARSER ITSELF. `regions` is handed to
// parse_job inside a stand-in lattice block, so a Flexible region and a lattice
// region can never mean two different things (M10: "where the lattice goes is
// chosen the same way"). The two lattice-stage-only keys (relative_density,
// synthetic_*) are refused here first.
// ════════════════════════════════════════════════════════════════════════════════

struct JobFlexibleFace {
  int face_region_id = -1;
  std::string role;  // "loaded" | "resting"
  int frame_rotation_deg = 0;
  double weight_n = 0.0;
  double deepest_squish_mm = 0.0;
  std::string mode;
  std::vector<double> curve_x_x, curve_x_y;
  std::vector<double> curve_y_x, curve_y_y;
  std::vector<double> curve_c_x, curve_c_y;
  bool has_design_stamp = false;
  flexible::StampGrid design_stamp;
  bool skin_on = true;
};

struct JobFlexibleCheckStamp {
  int face_region_id = -1;
  flexible::StampGrid stamp;
};

struct JobFlexible {
  std::string material_id;
  bool nozzle_temp_auto = false;
  double nozzle_temp_c = 0.0;
  std::string topology;  // "auto" | "gyroid" | "honeycomb"
  std::string feel;      // "springy" | "damped"
  int beads_per_wall = 1;
  double min_extrudable_width_mm = 0.0;
  std::vector<JobLatticeRegion> regions;
  std::vector<JobFlexibleFace> faces;
  std::vector<JobFlexibleCheckStamp> check_stamps;
};

// Parse the `flexible` block of a whole job document. Called by parse_job (the
// only caller) when the block is present; throws flexible::FlexibleError, which
// parse_job reports as a JobError.
std::shared_ptr<const JobFlexible> parse_flexible_block(const std::string& job_json_text);

// Every entry point except `topopt-cli flexible` calls this first: a job carrying a
// flexible block must never be run by a runner that would silently ignore it.
inline void refuse_flexible_job(const JobDescription& job, const char* entry) {
  if (job.flexible)
    throw JobError(std::string(entry) + " does not run the Flexible stage; this job carries a "
                   "\"flexible\" block, which runs with `topopt-cli flexible`");
}

// The squish map of a loaded face.
flexible::SquishMap squish_map_of(const JobFlexibleFace& face);

// THE FLEXIBLE LATTICE REGION as a voxel mask on `grid` (1 = latticed): the solid
// voxels the block's include/exclude regions select, minus the job's clearances —
// the lattice stage's own precedence (clearance beats both, exclude beats include,
// no include region = the whole part), built from the same public primitives
// run_job.cpp's lattice_role_regions_from_job / multiscale_region_mask use. It lives
// in the always-built library so the app can call it on every slice.
std::vector<char> flexible_region_mask(const JobDescription& job, const StepModel& model,
                                       const VoxelGrid& grid);

}  // namespace topopt
