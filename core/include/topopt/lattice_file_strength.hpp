// Install 3: the strength check of the new engine's lattice file (rule V4), as `topopt-cli lattice-file` makes it.
//
// The OLD engine's check (run_job.cpp, certify_latticed_variant: the null-posture solve, the composite solve, the gate),
// fed from the new layout (lattice_layout_file.hpp, lattice_credit). Its inputs (loads, supports, material, safety
// margin, build direction, voxel size) come from the strength job: a run job of the kind the old Lattice run takes
// ("mode": "lattice_part"), read by the old job reader (load_job_file). Built only where run_job.cpp is (OCCT and
// Eigen); elsewhere a lattice file job that asks for a check is refused (strength_unavailable).
#pragma once

#include <atomic>
#include <string>
#include <vector>

#include "topopt/lattice_layout_file.hpp"

namespace topopt {

// THE SETTINGS a strength job may state (its top-level "strength_settings" object; docs/strength-check/
// variables.json is the same list with its words). Each has its default (the constant the check uses when the job
// states none), its range, and its kind. A key not here, or a value outside its range, fails the job with one line.
struct StrengthSettingSpec {
  enum class Kind { Number, Integer, Bool, Choice, PerMaterial };
  std::string key;
  Kind kind = Kind::Number;
  double def = 0.0;          // PerMaterial: unused (the materials file's)
  double min = 0.0, max = 0.0;
  bool min_open = false;     // the value must be ABOVE min (z_knockdown: above 0)
  std::vector<double> choices;
};
const std::vector<StrengthSettingSpec>& strength_setting_specs();

// The check, reading the material library and the settings rules from these files when a job asks for it.
lattice_layout::StrengthCheck lattice_file_strength_check(const std::string& materials_path,
                                                          const std::string& rules_path);

// Brief E2, item 12: the strengthen rounds as one job (topopt-cli organic-strengthen). `job_path` is a lattice-file job
// (every lattice region a weave) naming its strength job; nothing is meshed. Each round's check is written to
// out_dir/r<N>/ (strength.json, fields.bin, strut_margins.bin), each round's fix to out_dir/r<N+1>/ (stress.tensor,
// floors.bin, strengthened.json); the job's own files are never changed. out_dir/strengthen.json is written whatever
// happened. `said` gets a line as each step starts; `stop` is read between steps (and inside the lay).
struct OrganicStrengthenResult {
  bool ok = false;
  std::string code, why, detail;   // ok: "done", "limit", "nothing_to_vary" or "frame_not_solved"
  int exit_code = 1;
  bool passing = false;            // the last check's verdict is "pass"
  int rounds_fixed = 0;
  std::string last_strengthened;   // out_dir-relative; empty when no round was made
  bool old_bars_kept = true;       // brief E3a, the additive mode: every round kept round 0's bars (OS12)
};
OrganicStrengthenResult run_organic_strengthen(const std::string& job_path, const std::string& out_dir, int threads,
                                               const std::string& materials_path, const std::string& rules_path,
                                               void (*said)(const char*) = nullptr,
                                               const std::atomic<bool>* stop = nullptr);

// Brief E4, item 2: the plain sentences of an Organic result whose solid does not certify (`solid_margin.text`).
// `infill_percent` the job's; `passes_at` the least whole infill at which the solid certifies (-1: none);
// `walls_certify` true when counting the printed walls as solid would certify it (said only then); `shown` the spots
// listed, `total` all of them.
std::string organic_solid_text(double infill_percent, int passes_at, bool walls_certify, std::size_t shown,
                               std::size_t total);

}  // namespace topopt
