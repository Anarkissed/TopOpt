// ── R1: THE IN-PLANE SLOT ORIGIN, AS SENT ──────────────────────────────────────
// From #354's core brief of 2026-10-02 (R1), the maintainer's ruling (b) and the
// reviewer's ruling of 2026-10-05.
//
// The app's octree grid is the occupancy origin minus an in-plane anchor shift that the
// app SEARCHES for, to fit more base cells. Core laid the plan from the region's `origin`
// and applied no anchor, so on every one of his projects the non-base cells came out off
// core's grid by ONE constant in-plane vector per region -- 570B38E2 region 1 by
// x = 1.6647, z = 0.5443 (mod 2.578), for both cell sizes. `stepped_plan.hpp` had always
// said the slot origin carries "the region's anchor shift in-plane"; nothing on the wire
// carried one. `slot_origin_mm` is that key.
//
// WHAT THE THREE FIXTURES ESTABLISH, and why all three are needed:
//   - `slot_origin_inplane`  the plan validates ONLY because the grid was stated;
//   - `slot_origin_absent`   the IDENTICAL plan without the key is REFUSED. This is the
//                            control, and without it the first case would equally be
//                            explained by a loosened alignment check -- which is the
//                            more likely way to "fix" R1 by accident;
//   - `slot_origin_off_plane` a slot origin with a component along the normal is refused,
//                            because an anchor shift is in-plane by definition and a
//                            normal component would move the plane the prism's depth is
//                            measured from, changing every containment verdict in silence.
//
// The 1.5 mm cell is the one under test and it is deliberately NOT the base: a doubled
// region's base is its largest sent cell (run_job.cpp:6989-7001), and base cells are
// exempt from the alignment check (stepped_plan.cpp:187-189). An earlier draft of this
// fixture sent only the 1.5 mm cell, which therefore BECAME the base, was exempt, and was
// accepted with or without the key -- a test that measured nothing. The 3 mm cell is in
// the plan to take the base away from it.
#include <cstdio>
#include <cstdlib>
#include <string>

static int g_checks = 0, g_failures = 0;
#define CHECK(cond, what)                                                          \
  do {                                                                             \
    ++g_checks;                                                                     \
    if (!(cond)) {                                                                  \
      ++g_failures;                                                                 \
      std::fprintf(stderr, "FAIL %s:%d  %s\n", __FILE__, __LINE__, (what));         \
    }                                                                               \
  } while (0)

static std::string read_file(const std::string& p) {
  std::string out;
  if (FILE* f = std::fopen(p.c_str(), "rb")) {
    char buf[8192];
    std::size_t n;
    while ((n = std::fread(buf, 1, sizeof buf, f)) > 0) out.append(buf, n);
    std::fclose(f);
  }
  return out;
}

static int run_job(const std::string& name, std::string& text) {
  const std::string job = std::string(ORGANIC_FIXTURE_DIR) + "/" + name + ".json";
  const std::string dir = std::string(CLI_TMP_DIR) + "/" + name;
  const std::string so = dir + ".stdout", se = dir + ".stderr";
  const std::string cmd = std::string("\"") + TOPOPT_CLI_EXE + "\" lattice-variant \"" +
                          job + "\" --out \"" + dir + "\" > \"" + so + "\" 2> \"" + se +
                          "\"";
  const int rc = std::system(cmd.c_str());
  text = read_file(so) + read_file(se);
  return rc;
}

static bool has(const std::string& h, const char* n) {
  return h.find(n) != std::string::npos;
}

int main() {
  // ── stated, and in the face plane: the plan validates ───────────────────────
  std::string in_text;
  const int in_rc = run_job("slot_origin_inplane", in_text);
  CHECK(in_rc == 0,
        "a plan whose cells sit on the STATED slot grid validates and runs");

  // ── the control: the same plan, no key ──────────────────────────────────────
  std::string ab_text;
  const int ab_rc = run_job("slot_origin_absent", ab_text);
  CHECK(ab_rc != 0,
        "the identical plan WITHOUT slot_origin_mm is refused -- the derived origin "
        "stands, so nothing moves for jobs that do not send the key");
  // And refused for the right reason: the alignment check, naming the offset. If this
  // ever became some other refusal, the pair above would stop being a comparison.
  CHECK(has(ab_text, "from the slot grid"),
        "and it is the ALIGNMENT check that refuses it, naming the offset");
  // The offset it names is the BASE cell's (0.4 mm), not the 1.5 mm cell's (3.4 mm):
  // since R6 removed the base exemption, the base cell is checked too and is the first
  // cell in the plan that is off the grid core used. Either number is the same evidence
  // -- that the ALIGNMENT check is what refuses, measured from the derived origin -- and
  // this comment is here because the suite caught the change when R6 landed.
  CHECK(has(ab_text, "0.4"),
        "which reports the offset from the grid core used (0.4 mm, the base cell's)");

  // ── ★ K2: STATED OFF THE FACE PLANE IS A PHASE, NOT AN ERROR ────────────────
  // This block asserted a REFUSAL until 2026-10-09. The reviewer corrected the ruling it
  // came from (2026-10-05 -> 2026-10-08): requiring the slot origin to lie in the face
  // plane is wrong for a TILTED facet, whose grid in the app is world-aligned, so the
  // point it packed from legitimately stands off the plane. Forcing it on would make the
  // app re-anchor tilted ladders and change the preview the maintainer approved.
  //
  // What must hold instead is the property that makes the two jobs separable: the slot
  // origin sets the PHASE and cannot move the PRISM. The fixture's origin stands one base
  // cell inward along the normal, and its cells sit at y 0..3 and 0..1.5 of a 12 mm prism
  // -- inside, measured from the region's own plane. Measured from the slot origin, as
  // core did before K2, their centres project to -1.5 and -2.25 and the plan was refused.
  // So this one case distinguishes the two readings on its own.
  std::string off_text;
  const int off_rc = run_job("slot_origin_off_plane", off_text);
  CHECK(off_rc == 0,
        "K2: a slot origin off the face plane is a grid PHASE and is accepted");
  CHECK(off_text.find("face plane") == std::string::npos,
        "K2: and nothing refuses it for leaving the plane");
  CHECK(off_text.find("outside its") == std::string::npos,
        "K2: nor for leaving the prism -- depth is measured from the region's own plane, "
        "so moving the phase along the normal cannot shift the prism");

  // ── ★ K1: THE PLAN'S BASE CELL TRAVELS ON THE WIRE ──────────────────────────
  // This file is where the per-region PLAN KEYS are tested through a run, so the base
  // belongs here beside the slot origin it is sent next to.
  //
  // An earlier cut of K1 INFERRED the base as the region's largest sent cell. That is a
  // silent substitute: a region need not contain a base-size cell. On 3418E167's real
  // Aesthetic Stepped plan, region 1 sends 3.5 mm and 4.6667 mm cells while the app's base
  // is 7 mm, so the inference guessed 4.6667 and ran every menu, alignment and grouping
  // check against a ladder the app never used -- and put the sizes a hair off too, since
  // three quarters of a rounded 4.6667 is 3.500025 rather than the 3.5 the plan sends.
  std::string miss_text;
  CHECK(run_job("plan_base_missing", miss_text) != 0,
        "K1: a planned region with no plan_base_cell_mm is REFUSED, not guessed at");
  CHECK(miss_text.find("plan_base_cell_mm") != std::string::npos,
        "K1: and the refusal names the key it needs");
  CHECK(miss_text.find("region 1") != std::string::npos,
        "K1: and the region, so a plan with many walls says which");
  CHECK(miss_text.find("cannot infer") != std::string::npos,
        "K1: and says WHY core will not fill it in -- a region need not contain a "
        "base-size cell");

  // ★ AND THE STATED BASE IS THE ONE USED, proved through the refusal's own words rather
  // than by an acceptance. This fixture is 3418E167's shape: cells of 3.5 and 4.6667 on a
  // 7 mm base. It is refused -- 4.6667 needs divisor 3, which the prints-open rule drops at
  // base 7 -- and the message must quote BASE 7. Under the old inference it quoted 4.667.
  std::string used_text;
  CHECK(run_job("plan_base_used", used_text) != 0,
        "K1 premise: that plan is refused on the menu, which is what makes the message "
        "readable as evidence");
  CHECK(used_text.find("base 7 mm") != std::string::npos,
        "K1: the validator was given the SENT base (7 mm), not the largest sent cell");
  CHECK(used_text.find("base 4.667 mm") == std::string::npos,
        "K1: and not the inferred one -- this is the string the old cut produced");

  std::printf("%s: %d checks, %d failures\n", g_failures == 0 ? "PASS" : "FAIL", g_checks,
              g_failures);
  return g_failures == 0 ? 0 : 1;
}
