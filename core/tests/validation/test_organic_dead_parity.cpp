// test_organic_dead_parity.cpp — THE SIZE PROBE AND THE RUN MUST AGREE ABOUT
// WHICH WALLS ARE DEAD (#354's audit, 2026-09-29).
//
// Ruling H decides deadness per WALL: p99 of the REAL von Mises over the region's
// voxels, against a threshold that is max(2 % of the part's peak, 0.005 MPa). Both
// the p99 and the peak are measured over a DOMAIN, and the probe and the run were
// not naming the same one: the probe synthesised over `cand` (the grading law's raw
// candidate set) and without `synthesised_whole`, where the run synthesises over
// `mask` and passes it. A size check that describes a different run from the one it
// recommends for is not a check.
//
// ★ WHAT THIS TEST CATCHES, AND WHAT IT DOES NOT. Stated plainly because the two
// halves of that defect are not equally observable:
//
//   - IT DOES NOT go red when the probe is pointed back at `cand`. Measured, not
//     assumed: with `cand` restored this test stays green at 16/16. The reason is in
//     grading.cpp -- for organic, all three `params.organic_geometry` branches mask
//     EVERY candidate voxel before any octet refusal, so `cand` and the posture mask
//     are the same set on every organic run. The domain half of the fix is a
//     contract, not a number that moved.
//   - IT DOES go red on a domain that is genuinely different. The control used is a
//     POST-RIM domain (synthesise after the solid-rim band is cleared instead of
//     before) -- the same mistake this code's own history records making once on the
//     probe's certificate mask. It fails 4 of 16 checks, INCLUDING a verdict flip:
//     the probe calls the tab wall alive (p99 0, its voxels cleared) while the run
//     calls it DEAD. So the assertions do bite on the class of defect they are for.
//   - IT CANNOT SEE the run's certification mask. The run's domain is
//     `lattice_certification_mask(boundary, ...) ∩ gf.posture.mask`, and the probe
//     has no certification mask. Nothing this fixture can be configured into
//     separated those two sets (cell 3-10 mm, uniform and swept, three rho bands, a
//     clearance keep-out, all three outer finishes), so that gap is unmeasured here.
//
// WHY THIS IS AT CLI LEVEL. The domain is chosen in run_job.cpp, and nothing links
// run_job.cpp: the unit test beside this one (test_organic_printability's "the dead
// set follows the domain") pins the MECHANISM -- one wall, one stress field, opposite
// verdicts over two domains -- but it cannot see which domain the probe passes. Only
// a run can. So this runs the real topopt-cli as a subprocess, the way test_cli and
// test_design_stream do, and reads the two receipts the ONE run writes:
//
//     <out>/organic_probe.json   candidates[0].regions[]  .synthesised_whole/.stress_p99
//     <out>/run_info.json        grading.organic.synthetic_stress_by_region[]  (same keys)
//
// Those two keys on each side are REPORT-ONLY and were added with this test: before
// them the verdicts existed only on `[synthetic]` stderr lines, which is why the two
// sides could be compared only by reading and parsing two logs.
//
// ★ AND IT ASSERTS THE NUMBERS, NOT ONLY THE VERDICTS. Two booleans can agree by
// luck -- a wall 49x above the threshold reads "alive" over almost any domain. The
// p99 and the dead threshold ARE the domain, so comparing those is what makes a
// domain change visible; the post-rim control fails on them first.
//
// ★ AND IT CHECKS THE FIXTURE STILL MEASURES SOMETHING. A fixture that degenerates
// to "no regions", "both alive" or "both dead" would make the parity vacuous and
// stay green forever, so the split itself is asserted: exactly one dead, one alive,
// each by a factor rather than a hair.
//
// Self-contained CHECK harness (ARCHITECTURE §4), like the other tests.

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                            \
  do {                                                              \
    ++g_checks;                                                     \
    if (!(cond)) {                                                  \
      ++g_failures;                                                 \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                               \
  } while (0)

static std::string read_file(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) {
    std::fprintf(stderr, "test bug: cannot read %s\n", path.c_str());
    ++g_failures;
    return "";
  }
  std::ostringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

// The number after "\"key\": ", searching from `from`. NaN when absent.
static double num_after(const std::string& s, const std::string& key,
                        std::string::size_type from = 0) {
  const std::string pat = "\"" + key + "\": ";
  const std::string::size_type at = s.find(pat, from);
  if (at == std::string::npos) return std::nan("");
  return std::atof(s.c_str() + at + pat.size());
}

// The boolean after "\"key\": ", searching from `from`. `missing` when absent.
static bool bool_after(const std::string& s, const std::string& key,
                       std::string::size_type from, bool missing) {
  const std::string pat = "\"" + key + "\": ";
  const std::string::size_type at = s.find(pat, from);
  if (at == std::string::npos) return missing;
  return s.compare(at + pat.size(), 4, "true") == 0;
}

// One wall's row, as either receipt reports it.
struct Wall {
  int region_id = 0;
  int face_id = -1;
  bool whole = false;
  double p99 = 0.0;
};

// Every object inside the array that follows "\"array_key\": [", up to its
// MATCHING ']'. The end is found by bracket depth, not by the first ']': the probe's
// rows carry "curves_per_family": [0, 0, 0], and a naive scan would stop inside the
// first row. Rows themselves are flat objects on both sides, so splitting them on
// '{' .. '}' is exact.
static std::vector<Wall> walls_in(const std::string& text,
                                  const std::string& array_key) {
  std::vector<Wall> out;
  const std::string pat = "\"" + array_key + "\": [";
  std::string::size_type at = text.find(pat);
  if (at == std::string::npos) return out;
  at += pat.size();
  std::string::size_type end = std::string::npos;
  {
    int depth = 1;
    for (std::string::size_type i = at; i < text.size(); ++i) {
      if (text[i] == '[') ++depth;
      else if (text[i] == ']' && --depth == 0) { end = i; break; }
    }
  }
  if (end == std::string::npos) return out;
  while (true) {
    const std::string::size_type ob = text.find('{', at);
    if (ob == std::string::npos || ob > end) break;
    const std::string::size_type cb = text.find('}', ob);
    if (cb == std::string::npos || cb > end) break;
    const std::string row = text.substr(ob, cb - ob + 1);
    Wall w;
    w.region_id = static_cast<int>(num_after(row, "region_id"));
    w.face_id = static_cast<int>(num_after(row, "face_id"));
    w.whole = bool_after(row, "synthesised_whole", 0, false);
    w.p99 = num_after(row, "stress_p99");
    out.push_back(w);
    at = cb + 1;
  }
  return out;
}

static bool close_rel(double a, double b, double tol) {
  const double d = std::fabs(a - b);
  const double s = std::max(std::fabs(a), std::fabs(b));
  return s > 0.0 ? d <= tol * s : d == 0.0;
}

int main() {
  const std::string job = std::string(ORGANIC_FIXTURE_DIR) + "/dead_parity.json";
  const std::string out = std::string(CLI_TMP_DIR) + "/organic_dead_parity";

  // The model path in the fixture job is relative, and the CLI resolves it against
  // the job's own directory — so the fixture runs in place, unpatched.
  const std::string cmd = std::string("\"") + TOPOPT_CLI_EXE +
                          "\" lattice-variant \"" + job + "\" --out \"" + out + "\"";
  const int rc = std::system(cmd.c_str());
  CHECK(rc == 0, "topopt-cli lattice-variant on the dead-parity fixture must exit 0");
  if (rc != 0) {
    std::fprintf(stderr, "  command was: %s\n", cmd.c_str());
    std::fprintf(stderr, "%d checks, %d failures\n", g_checks, g_failures);
    return 1;
  }

  const std::string probe = read_file(out + "/organic_probe.json");
  const std::string info = read_file(out + "/run_info.json");
  CHECK(!probe.empty(), "the run must write organic_probe.json");
  CHECK(!info.empty(), "the run must write run_info.json");
  if (probe.empty() || info.empty()) {
    std::fprintf(stderr, "%d checks, %d failures\n", g_checks, g_failures);
    return 1;
  }

  // ── the two dead sets ───────────────────────────────────────────────────────
  const std::vector<Wall> pw = walls_in(probe, "regions");
  const std::vector<Wall> rw = walls_in(info, "synthetic_stress_by_region");

  CHECK(pw.size() == 2, "the probe must report both of the fixture's walls");
  CHECK(rw.size() == 2, "the run must report both of the fixture's walls");

  // ── ★ THE FIXTURE STILL MEASURES SOMETHING (the positive control) ───────────
  // Parity between two empty sets, two all-alive sets or two all-dead sets is
  // vacuous. The fixture's tab is free-standing so the split is structural, not
  // tuned, and these bounds say so with room to spare: measured 49x above the
  // threshold on the live wall and 3.6x below it on the dead one.
  const double thr_run = num_after(info, "synthetic_stress_dead_threshold");
  int dead = 0, alive = 0;
  for (const Wall& w : rw) {
    if (w.whole) {
      ++dead;
      CHECK(w.p99 < 0.5 * thr_run,
            "the dead wall must be dead by a factor, not by a hair");
    } else {
      ++alive;
      CHECK(w.p99 > 10.0 * thr_run,
            "the live wall must be carrying real load, not sitting on the line");
    }
  }
  CHECK(dead == 1, "the fixture must produce exactly ONE dead wall");
  CHECK(alive == 1, "the fixture must produce exactly ONE live wall");

  // ── ★ THE PARITY ITSELF ─────────────────────────────────────────────────────
  // Same walls, same verdicts, and — the part that pins the DOMAIN rather than the
  // luck of a wall far from the line — the same p99 and the same threshold. The
  // receipts print at different precisions (the run 9 significant digits, the probe
  // 6), so the tolerance is on the text, not on the computation: 1e-5 relative is
  // three orders tighter than the smallest domain change could hide in.
  const double thr_probe = num_after(probe, "dead_threshold");
  CHECK(close_rel(thr_probe, thr_run, 1e-5),
        "the probe and the run must measure the same dead threshold (the same peak, "
        "over the same domain)");

  for (const Wall& p : pw) {
    const Wall* r = nullptr;
    for (const Wall& q : rw) if (q.region_id == p.region_id) r = &q;
    char msg[256];
    std::snprintf(msg, sizeof msg,
                  "region %d: the run must report the same wall the probe does",
                  p.region_id);
    CHECK(r != nullptr, msg);
    if (!r) continue;
    std::snprintf(msg, sizeof msg,
                  "region %d (face %d): probe says %s, run says %s — the size check "
                  "is describing a different run from the one it recommends for",
                  p.region_id, p.face_id, p.whole ? "DEAD" : "alive",
                  r->whole ? "DEAD" : "alive");
    CHECK(p.whole == r->whole, msg);
    std::snprintf(msg, sizeof msg,
                  "region %d (face %d): probe p99 %.6g vs run p99 %.6g — the two are "
                  "measuring over different domains",
                  p.region_id, p.face_id, p.p99, r->p99);
    CHECK(close_rel(p.p99, r->p99, 1e-5), msg);
  }

  std::fprintf(stderr, "dead set: threshold %.6g | ", thr_run);
  for (const Wall& p : pw) {
    const Wall* r = nullptr;
    for (const Wall& q : rw) if (q.region_id == p.region_id) r = &q;
    std::fprintf(stderr, "region %d face %d probe %s p99 %.4g / run %s p99 %.4g  ",
                 p.region_id, p.face_id, p.whole ? "DEAD " : "alive", p.p99,
                 r ? (r->whole ? "DEAD " : "alive") : "ABSENT", r ? r->p99 : 0.0);
  }
  std::fprintf(stderr, "\n");

  std::fprintf(stderr, "%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
