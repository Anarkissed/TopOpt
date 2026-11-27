// ── D10 / E3: AN EMPTY LATTICE IS NOT A SUCCESSFUL BUILD ───────────────────────
// From #354's core brief of 2026-10-06 and the reviewer's ruling of 2026-10-07.
//
// `region_ungradeable` is tested BEFORE the outline beam runs (run_job.cpp:6168), and the
// beam then clears voxels out of the mask (:6400-6446). Nothing looks again. So a job
// whose grade DID lattice something, all of which the beam then cleared, reaches the end
// with an empty mask and is written up as a finished part:
//
//     [outline] ... 8.9750 mm inward | 750 voxel(s) turned solid
//     ... over 0 voxels
//     verdict: ACCEPTED
//
// That is a false ACCEPTANCE -- the most expensive kind, because a refusal costs a solve
// and this costs a print. #354 hit it on his 3418E167 converted to Doubled, with
// `interior_volume_mm3` 0. The same job as Stepped is refused, but for the wrong reason:
// "the stepped algorithm derived no region cell ... 0 latticed voxels carrying 0 distinct
// region ids", which names region ids and recommends `"algorithm": "doubled"` -- the one
// that accepts nothing silently.
//
// ★ RULING 2 (2026-11-06): the doubled lattice's shape grade is no longer a solid beam but
// the preview's graded BAND (grading.hpp GradingLawParams::band_*), solid only where no
// cell prints. So the defect job below no longer empties: the same 31 mm band now grades
// its 810 voxels and the part is accepted with them. The refusal this test was written
// for stays in run_job for the beam that remains (algorithm "stepped"); here the test
// holds the new rule -- this shape grade leaves a lattice, and never an ACCEPTED over none.
//
// WHY THIS TEST RUNS THE BINARY. The decision lives in run_job.cpp's anonymous namespace
// (:67-7818), so nothing with external linkage can reach it; and what is under test is
// what a RUN concludes and what its receipt says. A header test cannot see either.
//
// WHY THERE IS A CONTROL. "Refuses" is trivially satisfied by refusing everything, and a
// lattice run has many ways to refuse. The control is the SAME job with a 10 mm band
// instead of 31: under 25 mm the bleed is zero (lattice.hpp:717-719), so the beam is
// 0.975 mm, clears 310 voxels and leaves 440. It must still be ACCEPTED, and the
// assertion below requires a non-zero voxel count rather than merely exit 0 -- otherwise
// a change that emptied every lattice would pass both halves of this test.
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

static int g_cells_swapped = 0;

// ★ RULING 11-10 (a): THE CONTROL RUNS A COPY AT A 2.4 MM CELL. The tab is a 12 mm plate and
// an octet member needs 5 cells across: 15 mm at the fixture's 3 mm cell. The law used to
// grade it only because the grid's outside read as material (finding 4); read honestly it
// grades none of it and the control refuses, which would leave this test with no positive
// control at all. 5 x 2.4 mm = 12 mm, so the plate holds the cell and the control again
// shows a lattice that survives a 10 mm band. The maintainer's fixture is not edited: the
// copy swaps only the two cell bounds and runs beside a copy of the tab.
static constexpr const char* kFixtureCellMin = "\"cell_min_mm\": 3.0";
static constexpr const char* kFixtureCellMax = "\"cell_max_mm\": 3.0";

static std::string cell_copy(const std::string& name) {
  const std::string dir = std::string(CLI_TMP_DIR) + "/c_cell_jobs";
  std::system(("mkdir -p \"" + dir + "\" && cp \"" + ORGANIC_FIXTURE_DIR +
               "/dead_parity_tab.stl\" \"" + dir + "/\"")
                  .c_str());
  std::string text = read_file(std::string(ORGANIC_FIXTURE_DIR) + "/" + name + ".json");
  for (const char* key : {kFixtureCellMin, kFixtureCellMax}) {
    const std::size_t at = text.find(key);
    if (at == std::string::npos) continue;
    text.replace(at, std::strlen(key), std::string(key, std::strlen(key) - 3) + "2.4");
    ++g_cells_swapped;
  }
  const std::string job = dir + "/" + name + ".json";
  if (FILE* f = std::fopen(job.c_str(), "w")) {
    std::fwrite(text.data(), 1, text.size(), f);
    std::fclose(f);
  }
  return job;
}

// Runs one fixture job and returns the CLI's exit status; stdout and stderr are captured
// into the caller's strings, because the refusal is the thing under test.
static int run_job(const std::string& name, std::string& out_text, std::string& err_text,
                   bool at_2_4_mm = false) {
  const std::string job = at_2_4_mm
                              ? cell_copy(name)
                              : std::string(ORGANIC_FIXTURE_DIR) + "/" + name + ".json";
  const std::string dir = std::string(CLI_TMP_DIR) + "/" + name;
  const std::string so = dir + ".stdout", se = dir + ".stderr";
  // The fixture's `model` is relative and the CLI resolves it against the job's own
  // directory, so the fixture runs in place, unpatched.
  const std::string cmd = std::string("\"") + TOPOPT_CLI_EXE + "\" lattice-variant \"" +
                          job + "\" --out \"" + dir + "\" > \"" + so + "\" 2> \"" + se +
                          "\"";
  const int rc = std::system(cmd.c_str());
  out_text = read_file(so);
  err_text = read_file(se);
  return rc;
}

static bool has(const std::string& h, const char* n) {
  return h.find(n) != std::string::npos;
}

int main() {
  // ── the defect: the grade lattices voxels, the beam clears all of them ──────
  std::string dout, derr;
  const int drc = run_job("empty_after_beam", dout, derr);
  const std::string dall = dout + derr;

  // ★ ruling 2: the band grades instead of clearing, so the lattice survives it.
  CHECK(!has(dout, "over 0 voxels"),
        "the shape grade's band leaves a lattice (it no longer clears the mask)");
  CHECK(drc != 0 || has(dout, "verdict: ACCEPTED"),
        "and the run either certifies that lattice or refuses in words");
  CHECK(!(drc == 0 && has(dout, "over 0 voxels")),
        "never a verdict of ACCEPTED over no lattice at all");
  // ★ RULING 11-10: on the honest width the 12 mm tab holds no 3 mm octet cell, so this
  // swept job refuses -- and the refusal quotes the floor at the run's OWN finest cell
  // (3 mm, 15 mm needed) beside the width, never at the 1.12 mm legal minimum it used to.
  if (drc != 0) {
    CHECK(has(derr, "Every member is too thin: the widest is 12.5 mm across, under the 15 mm "
                    "that 5 cells of this run's finest cell (3 mm) need"),
          "a swept refusal quotes 5 x the run's own finest cell, beside the member width");
    CHECK(!has(derr, "must be at least"),
          "and nothing in it reads as a pass");
  }
  CHECK(!has(dall, "turned solid"),
        "no solid outline beam ran on the doubled lattice");

  // ★ AND IT MUST NOT POINT AT AN ALGORITHM. The Stepped refusal recommended
  // `"algorithm": "doubled"`, which is the path that accepted 0 voxels silently.
  CHECK(!has(dall, "\"algorithm\": \"doubled\""),
        "the refusal recommends no algorithm -- the one it used to recommend is the one "
        "that accepted nothing");

  // ── the control: the same job, a band under the bleed threshold ─────────────
  std::string cout_, cerr_;
  const int crc = run_job("empty_after_beam_control", cout_, cerr_, /*at_2_4_mm=*/true);
  CHECK(g_cells_swapped == 2, "the control's copy states the 2.4 mm cell at both bounds");
  CHECK(crc == 0, "the control job, whose lattice survives the beam, is still ACCEPTED");
  CHECK(has(cout_, "verdict: ACCEPTED"), "and still reports a verdict of ACCEPTED");
  // The positive control proper: a non-empty lattice. `over 0 voxels` is what the defect
  // printed, so requiring merely "accepted" would not distinguish them.
  CHECK(!has(cout_, "over 0 voxels"),
        "and its lattice is NOT empty -- otherwise this test would pass against a change "
        "that emptied every lattice");

  std::printf("%s: %d checks, %d failures\n", g_failures == 0 ? "PASS" : "FAIL", g_checks,
              g_failures);
  return g_failures == 0 ? 0 : 1;
}
