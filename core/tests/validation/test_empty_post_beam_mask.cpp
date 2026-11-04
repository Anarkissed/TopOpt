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

// Runs one fixture job and returns the CLI's exit status; stdout and stderr are captured
// into the caller's strings, because the refusal is the thing under test.
static int run_job(const std::string& name, std::string& out_text, std::string& err_text) {
  const std::string job = std::string(ORGANIC_FIXTURE_DIR) + "/" + name + ".json";
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

  CHECK(drc != 0,
        "an empty post-beam mask must be REFUSED, not reported as a finished part");
  CHECK(!has(dout, "verdict: ACCEPTED"),
        "and it must not print a verdict of ACCEPTED over no lattice at all");

  // The refusal has to name the cause a reader can act on. The grade is not the
  // culprit here -- it produced a lattice -- so naming only the grade's own counters
  // would send the reader to the wrong place.
  CHECK(has(dall, "outline") || has(dall, "beam"),
        "the refusal names the outline beam, which is what emptied the mask");
  CHECK(has(dall, "750"),
        "it names how many voxels were cleared, so the reader can see it was all of them");

  // ★ AND IT MUST NOT POINT AT AN ALGORITHM. The Stepped refusal recommended
  // `"algorithm": "doubled"`, which is the path that accepted 0 voxels silently.
  CHECK(!has(dall, "\"algorithm\": \"doubled\""),
        "the refusal recommends no algorithm -- the one it used to recommend is the one "
        "that accepted nothing");

  // ── the control: the same job, a band under the bleed threshold ─────────────
  std::string cout_, cerr_;
  const int crc = run_job("empty_after_beam_control", cout_, cerr_);
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
