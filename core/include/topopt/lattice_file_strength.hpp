// Install 3: the strength check of the new engine's lattice file (rule V4), as `topopt-cli lattice-file` makes it.
//
// The OLD engine's check (run_job.cpp, certify_latticed_variant: the null-posture solve, the composite solve, the gate),
// fed from the new layout (lattice_layout_file.hpp, lattice_credit). Its inputs (loads, supports, material, safety
// margin, build direction, voxel size) come from the strength job: a run job of the kind the old Lattice run takes
// ("mode": "lattice_part"), read by the old job reader (load_job_file). Built only where run_job.cpp is (OCCT and
// Eigen); elsewhere a lattice file job that asks for a check is refused (strength_unavailable).
#pragma once

#include <string>

#include "topopt/lattice_layout_file.hpp"

namespace topopt {

// The check, reading the material library and the settings rules from these files when a job asks for it.
lattice_layout::StrengthCheck lattice_file_strength_check(const std::string& materials_path,
                                                          const std::string& rules_path);

}  // namespace topopt
