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

  // ── stated, but out of the face plane: refused, and it says which region ────
  std::string off_text;
  const int off_rc = run_job("slot_origin_off_plane", off_text);
  CHECK(off_rc != 0, "a slot origin off the face plane is REFUSED, not projected onto it");
  CHECK(has(off_text, "slot_origin_mm"), "the refusal names the key it is refusing");
  CHECK(has(off_text, "face plane"), "and says what is wrong with it");
  CHECK(has(off_text, "region"),
        "and names the region, so a plan with many walls says which one");
  // The distance is the number to act on -- the fixture states it 2 mm out.
  CHECK(has(off_text, "2"), "and reports how far along the normal it stands");

  std::printf("%s: %d checks, %d failures\n", g_failures == 0 ? "PASS" : "FAIL", g_checks,
              g_failures);
  return g_failures == 0 ? 0 : 1;
}
