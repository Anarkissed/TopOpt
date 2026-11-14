// CORE LIST item 50 acceptance (reviewer's ruling 2026-10-26 07:29 UTC): a
// version whose VERIFIED export meets its target is accepted even when loose
// specks were dropped (they become a note: count and mm^3); Keep Clear voxels
// and a detached anchor / severed load path still refuse; a refused version's
// note names the real reason. Motivating run: his job 0e07f31f, version 1 —
// verified 5.32 against a target of 4.11, refused for specks = 1, note "the
// verified export missed the target after 2 repairs".
// RED on the old rule (clean = accepted && specks == 0 && keep clear == 0; the
// fixed "missed the target" note).

#include "topopt/pipeline.hpp"
#include "topopt/strengthen_accept.hpp"

#include <cstdio>
#include <string>

using topopt::StrengthenAttemptReport;

static int g_failures = 0;
static void check(bool ok, const char* what) {
  std::printf("%s %s\n", ok ? "ok:  " : "FAIL:", what);
  if (!ok) ++g_failures;
}

int main() {
  const std::string margin = topopt::kMarginBelowRequiredReason;
  // 1. His v1: verified 5.32 >= 4.11, one speck dropped -> ACCEPTED, with a note.
  StrengthenAttemptReport a;
  a.attempt = 2;
  a.verified_margin = 5.315680289;
  a.specks = 1;
  a.speck_volume_mm3 = 2.53;
  const bool acc = topopt::strengthen_attempt_accepted(a, 4.113520637, margin);
  const std::string note = topopt::strengthen_speck_note(a);
  std::printf("      v1: accepted=%d note \"%s\"\n", acc ? 1 : 0, note.c_str());
  check(acc, "1: verified >= target with 1 speck dropped is ACCEPTED");
  check(note.find("1 loose speck") != std::string::npos &&
            note.find("2.53 mm^3") != std::string::npos,
        "1: the note names the speck count and its volume in mm^3");

  // 2. Keep Clear voxels still refuse, and the note says so.
  StrengthenAttemptReport k = a;
  k.specks = 0;
  k.keep_clear_voxels = 7;
  const std::string nk = topopt::strengthen_refusal_note(k, 4.11, margin, 2, 2);
  check(!topopt::strengthen_attempt_accepted(k, 4.11, margin) &&
            nk == "Keep Clear voxels (7)",
        "2: Keep Clear voxels refuse; the note is \"Keep Clear voxels (7)\"");

  // 3. A detached anchor (item 47) refuses: "not accepted: <reason>".
  StrengthenAttemptReport d = a;
  d.anchors_attached = false;
  d.rejection_reason = topopt::kAnchorDetachedReason;
  const std::string nd = topopt::strengthen_refusal_note(d, 4.11, margin, 2, 2);
  check(!topopt::strengthen_attempt_accepted(d, 4.11, margin) &&
            nd == std::string("not accepted: ") + topopt::kAnchorDetachedReason,
        "3: a detached anchor refuses; the note names it");

  // 4. His v2: verified 5.65 < 6.17 after both repairs: the short margin, and
  // "missed the target after 2 repairs" because that is what happened.
  StrengthenAttemptReport s;
  s.attempt = 1;
  s.verified_margin = 5.647687726;
  const std::string ns = topopt::strengthen_refusal_note(s, 6.170280956, margin, 2, 2);
  std::printf("      v2: \"%s\"\n", ns.c_str());
  check(!topopt::strengthen_attempt_accepted(s, 6.170280956, margin) &&
            ns.find("verified 5.65\xC3\x97 vs target 6.17\xC3\x97") == 0 &&
            ns.find("missed the target after 2 repairs") != std::string::npos,
        "4: a short margin says verified X\xC3\x97 vs target Y\xC3\x97 (+ the repairs line, true here)");

  // 5. Only the IN-LOOP margin reason: the verified export decides -> accepted.
  StrengthenAttemptReport m = a;
  m.specks = 0;
  m.rejection_reason = margin;
  check(topopt::strengthen_attempt_accepted(m, 4.11, margin),
        "5: an in-loop margin rejection does not refuse a version whose verified "
        "export meets the target");

  if (g_failures == 0) std::printf("strengthen_accept: all checks passed\n");
  else std::printf("strengthen_accept: %d check(s) FAILED\n", g_failures);
  return g_failures == 0 ? 0 : 1;
}
