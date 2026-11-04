#pragma once
// CORE LIST item 50, "Redesign to strengthen" — WHEN A VERSION IS ACCEPTED, and
// what a refused version's note says (reviewer's ruling 2026-10-26 07:29 UTC).
//
// A version is accepted on an attempt (its fine run, verified on the EXPORTED
// geometry) when:
//   * the verified margin >= the version's target — which is already
//     max(reference / (1 - stress cut), 1.05 x the previous version's verified
//     margin), so ">= 1.05 x the previous" holds with it;
//   * no anchored piece is detached (item 47) and the load path holds: the
//     variant's own rejection reason is none, or only its IN-LOOP margin (the
//     verified export margin decides the margin);
//   * no Keep Clear voxel prints.
// Dropped loose SPECKS never refuse a version: they become a note (count and
// volume in mm^3). A refused version's note names the real reason; "missed the
// target after N repairs" appears only when the margin really fell short after
// every repair ran.

#include <cstdio>
#include <string>

namespace topopt {

struct StrengthenAttemptReport {
  int attempt = 0;                 // 0 = the first fine run, then the repairs
  double verified_margin = 0.0;    // on the exported geometry
  int specks = 0;                  // loose specks dropped from the export
  double speck_volume_mm3 = 0.0;
  long long keep_clear_voxels = 0; // exported voxels inside a Keep Clear
  bool anchors_attached = true;    // item 47
  std::string rejection_reason;    // the variant's own ("" = accepted in loop)
};

// The variant's rejection reason refuses the version unless it is empty or the
// in-loop margin reason (`margin_reason`).
inline bool strengthen_structural_rejection(const StrengthenAttemptReport& a,
                                            const std::string& margin_reason) {
  return !a.rejection_reason.empty() && a.rejection_reason != margin_reason;
}

inline bool strengthen_attempt_accepted(const StrengthenAttemptReport& a,
                                        double target,
                                        const std::string& margin_reason) {
  return a.verified_margin >= target && a.anchors_attached &&
         !strengthen_structural_rejection(a, margin_reason) &&
         a.keep_clear_voxels == 0;
}

// An accepted version's speck note ("" when none were dropped).
inline std::string strengthen_speck_note(const StrengthenAttemptReport& a) {
  if (a.specks <= 0) return "";
  char buf[160];
  std::snprintf(buf, sizeof buf, "%d loose speck%s dropped from the export (%.3g mm^3)",
                a.specks, a.specks == 1 ? "" : "s", a.speck_volume_mm3);
  return buf;
}

// A refused version's note, from the attempt shown (the best verified one):
// the real reason, in this order — Keep Clear voxels, the variant's own
// structural rejection (detached anchor / severed load path), then a short
// margin; "the verified export missed the target after N repairs" is added
// only when that is what happened and every repair ran.
inline std::string strengthen_refusal_note(const StrengthenAttemptReport& best,
                                           double target,
                                           const std::string& margin_reason,
                                           int repairs_run, int repairs_max) {
  if (best.keep_clear_voxels > 0)
    return "Keep Clear voxels (" + std::to_string(best.keep_clear_voxels) + ")";
  if (!best.anchors_attached && best.rejection_reason.empty())
    return "not accepted: anchored piece detached";
  if (strengthen_structural_rejection(best, margin_reason))
    return "not accepted: " + best.rejection_reason;
  char buf[200];
  std::snprintf(buf, sizeof buf, "verified %.3g\xC3\x97 vs target %.3g\xC3\x97",
                best.verified_margin, target);
  std::string note = buf;
  if (best.verified_margin < target && repairs_run >= repairs_max)
    note += "; the verified export missed the target after " +
            std::to_string(repairs_max) + " repairs (best shown)";
  return note;
}

}  // namespace topopt
