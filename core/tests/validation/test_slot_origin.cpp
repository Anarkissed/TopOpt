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
#include "topopt/lattice.hpp"

#include <cmath>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
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

// ★ RULING 2026-11-02 (c): these plans send no "rho", so the grading law sizes their
// cells, and they were built when a 3 mm octet cell at the 0.45 mm bead printed from a
// density of 0.131 up (the legs-only law). On the full cell's law it prints from 0.235,
// so the law keeps every voxel these plans lattice solid (strut_unprintable_at_every_cell)
// and core refuses the plan for having no density. The fixtures are maintainer data and
// are not edited (the change is proposed in the handoff): the three slot-origin arms read
// a copy at a 0.32 mm bead, where the 3 mm cell prints from 0.128 -- the threshold the
// plans were built around. Nothing in those three arms reads the bead. The K1 arms below
// run their fixtures as they are: their verdicts are refusals at the 0.45 mm bead they
// state (one is the prints-open rule itself), and at 0.32 mm the 7 mm base's 2.33 mm tile
// would print.
static constexpr const char* kFixtureBead = "\"min_extrudable_width_mm\": 0.45";
static constexpr const char* kCopyBead = "\"min_extrudable_width_mm\": 0.32";

// ★ RULING 11-10 (a): EACH PLANNED CELL STATES ITS OWN DENSITY, as the app's real plans do
// (102117B9's Default Grade plan: every cell carries a rho). The tab these plans sit on is a
// 12 mm plate, and an octet member needs 5 cells across: 15 mm at the 3 mm cell, 30 at the
// 6 mm one. The law used to grade it only because the grid's outside read as material
// (finding 4); read honestly it grades none of it and refuses. A plan whose every cell
// carries a density is the design itself (ruling 2026-10-11), so the run carries on without
// the law's grade, and these arms go on testing what they were written for. 0.30 prints at
// both of the plans' cells at the copy's 0.32 mm bead (the 3 mm cell from 0.131). The
// maintainer's fixtures are not edited.
static constexpr const char* kCellSize = "\"size_mm\": ";
static constexpr const char* kCellRho = ", \"rho\": 0.30";

static std::size_t state_cell_densities(std::string& text) {
  std::size_t stated = 0;
  for (std::size_t at = text.find(kCellSize); at != std::string::npos;
       at = text.find(kCellSize, at + 1), ++stated) {
    std::size_t end = at + std::strlen(kCellSize);
    while (end < text.size() && (std::isdigit(static_cast<unsigned char>(text[end])) ||
                                 text[end] == '.'))
      ++end;
    text.insert(end, kCellRho);
  }
  return stated;
}

static std::string rebeaded_copy(const std::string& name) {
  const std::string dir = std::string(CLI_TMP_DIR) + "/c_bead_jobs";
  std::system(("mkdir -p \"" + dir + "\" && cp \"" + ORGANIC_FIXTURE_DIR +
               "/dead_parity_tab.stl\" \"" + dir + "/\"")
                  .c_str());
  std::string text = read_file(std::string(ORGANIC_FIXTURE_DIR) + "/" + name + ".json");
  std::size_t swapped = 0;
  for (std::size_t at = text.find(kFixtureBead); at != std::string::npos;
       at = text.find(kFixtureBead, at + 1), ++swapped)
    text.replace(at, std::strlen(kFixtureBead), kCopyBead);
  CHECK(swapped == 2, "the fixture states its 0.45 mm bead twice (grading and lattice)");
  if (text.find("\"stepped_cells\"") != std::string::npos)
    CHECK(state_cell_densities(text) >= 2,
          "the copy states a density on every planned cell (ruling 11-10 (a))");
  const std::string job = dir + "/" + name + ".json";
  if (FILE* f = std::fopen(job.c_str(), "w")) {
    std::fwrite(text.data(), 1, text.size(), f);
    std::fclose(f);
  }
  return job;
}

static int run_job(const std::string& name, std::string& text, bool rebeaded = false) {
  const std::string job = rebeaded ? rebeaded_copy(name)
                                   : std::string(ORGANIC_FIXTURE_DIR) + "/" + name + ".json";
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
  {
    const auto octet = topopt::LatticeTopology::Octet;
    const double at_045 = topopt::lattice_min_density_for_strut(octet, 3.0, 0.45);
    const double at_032 = topopt::lattice_min_density_for_strut(octet, 3.0, 0.32);
    CHECK(at_045 > 0.2,
          "premise: on octet's full-cell law a 3 mm cell at 0.45 mm prints only over 0.2");
    CHECK(std::fabs(at_032 - 0.1312) < 0.01,
          "premise: at 0.32 mm it prints from about the 0.131 the plans were built around");
  }
  // ── stated, and in the face plane: the plan validates ───────────────────────
  std::string in_text;
  const int in_rc = run_job("slot_origin_inplane", in_text, true);
  CHECK(in_rc == 0,
        "a plan whose cells sit on the STATED slot grid validates and runs");

  // ── the control: the same plan, no key ──────────────────────────────────────
  std::string ab_text;
  const int ab_rc = run_job("slot_origin_absent", ab_text, true);
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
  const int off_rc = run_job("slot_origin_off_plane", off_text, true);
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
