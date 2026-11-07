#pragma once

#include <string>
#include <vector>

#include "topopt/flexible/data.hpp"
#include "topopt/flexible/error.hpp"
#include "topopt/flexible/faces.hpp"
#include "topopt/flexible/field.hpp"

namespace topopt {
namespace flexible {

// ════════════════════════════════════════════════════════════════════════════════
// F9 — AUTO (01 "Auto recommender rules", M5, R5, R6)
//
//   1. Eligibility: honeycomb only when EVERY loaded stack runs along build Z
//      (± 15°); gyroid always.
//   2. Reachability: per family and per tested temperature, can every face's map be
//      met inside the table (no column too firm, too soft or beyond the data)?
//   3. Feel: "springy" prefers gyroid, "damped" prefers honeycomb (Chatpun 2025,
//      Beloshenko 2021). If only one family survives it wins, and says so.
//   4. Tiebreaks: fewer columns near a table edge, then less material, then (between
//      temperatures) the one whose densities sit furthest inside the table.
//   5. Nothing reachable: per face, where it fails and the nearest achievable squish
//      — and the CLOSEST candidate is still named, marked not reachable, so the
//      buildable map can be drawn for it.
// Every reason is a stable code plus one sentence.
// ════════════════════════════════════════════════════════════════════════════════

struct Reason {
  std::string code;
  std::string text;
  int face_region_id = -1;  // -1 when not about one face
};

// What one loaded face asks for.
struct FaceRequest {
  const Stack* stack = nullptr;
  SquishMap map;
  double weight_n = 0.0;
  const StampGrid* design_stamp = nullptr;
};

// Where one face fails for one candidate.
struct FaceFailure {
  int face_region_id = -1;
  std::string topology;
  double temp_c = 0.0;
  int too_firm = 0, too_soft = 0, beyond_data = 0;
  int buildable_beyond_data = 0;  // reachable targets that squish past the data once smoothed
  int solid_under_map = 0;        // squish drawn where the column has no lattice (B2)
  double u_min_mm = 0.0, u_max_mm = 0.0, v_min_mm = 0.0, v_max_mm = 0.0;  // failing columns
  bool nearest_known = false;
  double nearest_depth_min_mm = 0.0, nearest_depth_max_mm = 0.0;  // over failing columns
  std::string text;
};

struct Candidate {
  std::string topology;
  double temp_c = 0.0;
  bool eligible = true;
  bool has_data = false;
  Refusal refusal;  // why not eligible / no data
  bool reachable = false;
  int unreachable_columns = 0;
  int near_edge_columns = 0;
  double material_volume_mm3 = 0.0;
  bool mass_known = false;  // every column's specimen density was known
  double mass_g = 0.0;      // Σ specimen density(ρ) × A × h — measured masses, not a guess
  double insideness = 0.0;  // mean distance of the densities from the table's ends, ÷ span
  std::vector<FaceFailure> failures;
};

struct Recommendation {
  bool chosen = false;     // false only when no candidate has data at all
  bool reachable = false;  // the choice meets every face
  std::string topology;
  double temp_c = 0.0;
  std::string feel;
  std::vector<Reason> reasons;
  std::vector<Candidate> candidates;
  std::vector<FaceFailure> failures;  // the choice's, when !reachable
  std::string sentence;               // the one line the UI shows
};

// The tiebreaks (rule 4) over candidates that already passed eligibility, reachability
// and feel: fewer near-edge columns, then fewer grams (when every candidate's mass is
// known), then furthest inside the table. Returns the winner's index and, in `code`, the
// tiebreak that separated it from its CLOSEST rival ("" when they tie throughout) (H4).
std::size_t pick_by_tiebreaks(const std::vector<const Candidate*>& pool, std::string& code);

// `temps` and `topologies` are the candidates to weigh: one value each when the
// user fixed them, every tested temperature / both families under "auto". Throws
// FlexibleError on a bad feel or topology name.
Recommendation recommend(const FlexibleData& data, const std::string& material_id,
                         const std::vector<double>& temps,
                         const std::vector<std::string>& topologies, const std::string& feel,
                         int beads_per_wall, double bead_width_mm,
                         const std::vector<FaceRequest>& faces);

}  // namespace flexible
}  // namespace topopt
