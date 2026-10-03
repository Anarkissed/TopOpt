#pragma once

#include <string>
#include <vector>

#include "topopt/job.hpp"

namespace topopt {

// ════════════════════════════════════════════════════════════════════════════════
// F12 — `topopt-cli flexible <job.json>`: run a job's flexible block end to end and
// write, into `out_dir`:
//
//   per LOADED face <id>:
//     face<id>_target_depth.svg     the drawn map: S · deepest squish (mm)
//     face<id>_buildable_depth.svg  what can be built (R14 heuristic), mm
//     face<id>_density.svg          buildable printed-core relative density
//     face<id>_cell_size.svg        the planning cell size at that density (mm)
//     face<id>_tier_flags.svg       per column: ok / extrapolated / too firm /
//                                   too soft / beyond the data, with the tier and band
//     face<id>_columns.csv          every column, every number
//   per CHECK stamp:
//     check_<name>_face<id>.svg / .csv   the dent under the stamp
//   field_xz_density.svg, field_xz_owner.svg
//                                   a slice of the 3D density field (and which face
//                                   owns each voxel) through the middle of the part
//   run_info.json                   with the `flexible` receipt block
//
// Nothing here is a certificate (R7): every depth carries a tier and a band.
//
// Returns `refused == true` (code + reason, receipt still written) when the STAGE
// refuses: a calibrate_first filament, an untested temperature, two loaded faces on
// one stack, honeycomb on a side stack, nothing with data. Throws JobError when the
// INPUT is wrong (cannot import, region resolves to nothing, ...).
// ════════════════════════════════════════════════════════════════════════════════
struct FlexibleRunResult {
  bool refused = false;
  std::string refusal_code;
  std::string refusal_reason;
  std::string receipt_json;        // the `flexible` block of run_info.json
  std::vector<std::string> files;  // written, relative to out_dir
};

// Which binary ran (the CLI's own fingerprint, as every run_info.json records it).
struct FlexibleProvenance {
  std::string cli_version;
  std::string fingerprint;
  std::string build_time;
};

// run_info.json here is the Flexible stage's OWN record: the provenance, the job's
// mode/material/format/resolution, and the `flexible` receipt — and nothing of the
// optimizer's (no solver, no margin fields: R7).
FlexibleRunResult run_flexible_job(const JobDescription& job, const std::string& job_dir,
                                   const std::string& out_dir,
                                   const std::string& flexible_materials_path,
                                   const FlexibleProvenance& provenance);

}  // namespace topopt
