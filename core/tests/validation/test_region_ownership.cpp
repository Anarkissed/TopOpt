// ── RULING 4 (reviewer, 2026-10-07): WHO OWNS SHARED SPACE ─────────────────────
// Core gave a point inside two include prisms to the FIRST matching region in
// DECLARATION ORDER, however far its face was -- the per-voxel region ids,
// fit_cell_field, the void rule, analyze's ids, and the any-step base derivation that
// reads them. That is not a geometric rule. Core now adopts the app's: among the include
// regions whose prism contains the point, the owner is the one whose FACE PLANE is
// nearest, with an exact tie to the lower region id.
//
// Containment is NOT re-derived for this. `stepped_region_owner` calls
// `point_in_clearance_region`, the predicate core already resolves per-voxel membership
// with, so there is one containment test and only the tie-break is new.
//
// THE TWO PROPERTIES, and why each needs a run rather than a header test:
//
//  1. ORDER-INDEPENDENCE. Reversing the declaration order must give a byte-identical
//     STL. This is the whole point of the rule and it cannot be seen from a header: it
//     is a property of the geometry a RUN emits. Note the fixture needs PER-REGION CELLS
//     to show it -- an earlier corner fixture with one cell size everywhere produced
//     identical STLs under reversal even BEFORE the fix, because ownership changed which
//     region a receipt row named without changing any geometry. With per-region cells the
//     shared voxels are latticed at the owner's cell, and before the fix the two orders
//     differed (7f602f83… vs 4c5809b0…) and the forward run reported ONE region cell
//     where the reversed reported two -- the first-declared region had swallowed the
//     shared volume.
//
//  2. STRADDLERS. Where two prisms meet the app keeps a cell WHOLE and lets it cross the
//     seam, so two regions' cells legitimately share space. That is allowed exactly where
//     each cell's CENTRE is owned by its own region; any other cross-region overlap is a
//     real collision. Both halves are asserted, because a rule that only permitted would
//     let the stand's 1,367 real overlapping pairs through, and a rule that only refused
//     would refuse every mitre.
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

static int run_job(const std::string& name, std::string& text, std::string& out_dir) {
  const std::string job = std::string(ORGANIC_FIXTURE_DIR) + "/" + name + ".json";
  out_dir = std::string(CLI_TMP_DIR) + "/" + name;
  const std::string so = out_dir + ".stdout", se = out_dir + ".stderr";
  const std::string cmd = std::string("\"") + TOPOPT_CLI_EXE + "\" lattice-variant \"" +
                          job + "\" --out \"" + out_dir + "\" > \"" + so + "\" 2> \"" +
                          se + "\"";
  const int rc = std::system(cmd.c_str());
  text = read_file(so) + read_file(se);
  return rc;
}

static bool has(const std::string& h, const char* n) {
  return h.find(n) != std::string::npos;
}

// The one STL a lattice-variant run writes, FOUND rather than assumed: the file carries
// a run-dependent stem (dp_073_lattice.stl), and a hardcoded name would read two empty
// strings and compare them equal -- a byte-identity check that passed by reading nothing.
// Hence also the non-empty assertion at the call site.
static std::string the_stl(const std::string& dir) {
  std::string path;
  const std::string cmd = "ls -1 \"" + dir + "\"/*lattice*.stl 2>/dev/null | head -1";
  if (FILE* pipe = popen(cmd.c_str(), "r")) {
    char buf[4096];
    if (std::fgets(buf, sizeof buf, pipe)) {
      path = buf;
      while (!path.empty() && (path.back() == '\n' || path.back() == '\r')) path.pop_back();
    }
    pclose(pipe);
  }
  return path.empty() ? std::string() : read_file(path);
}

int main() {
  // ── 1. the corner, both ways round ──────────────────────────────────────────
  std::string f_text, r_text, f_dir, r_dir;
  const int f_rc = run_job("owner_corner_fwd", f_text, f_dir);
  const int r_rc = run_job("owner_corner_rev", r_text, r_dir);
  CHECK(f_rc == 0, "the corner fixture runs");
  CHECK(r_rc == 0, "and so does the same fixture with its regions declared in reverse");

  // Both runs must derive a cell for BOTH regions. Before ownership, the first-declared
  // region swallowed the shared volume and the other got no voxels and no cell -- so this
  // is the assertion that catches a regression to declaration order even if the STLs
  // happened to match.
  CHECK(has(f_text, "14.5, 14.5") || has(read_file(f_dir + "/run_info.json"), "14.5, 14.5"),
        "the forward run derives a cell for BOTH regions, not just the first declared");
  CHECK(has(r_text, "14.5, 14.5") || has(read_file(r_dir + "/run_info.json"), "14.5, 14.5"),
        "and so does the reversed run");

  const std::string fs = the_stl(f_dir);
  const std::string rs = the_stl(r_dir);
  CHECK(fs.size() > 1000,
        "the forward run wrote a real lattice STL -- without this, two empty reads "
        "would satisfy the byte-identity check below by comparing nothing");
  CHECK(fs == rs,
        "★ the two declaration orders emit a BYTE-IDENTICAL lattice: ownership is "
        "geometric, so the order the app happened to write the regions in cannot change "
        "the part");

  // ── 2. straddlers ───────────────────────────────────────────────────────────
  std::string s_text, s_dir;
  CHECK(run_job("straddler_seam", s_text, s_dir) == 0,
        "a straddled seam is ACCEPTED: two regions' cells may share space where each "
        "centre is owned by its own region");

  std::string c_text, c_dir;
  CHECK(run_job("straddler_collision", c_text, c_dir) != 0,
        "a cross-region overlap whose centres are NOT each owned by their own region is a "
        "real collision and is refused");
  CHECK(has(c_text, "straddled seam"),
        "and the refusal says it is not a straddled seam, so the reader knows which rule "
        "it failed");
  CHECK(has(c_text, "region 1") && has(c_text, "region 2"),
        "naming both regions");
  CHECK(has(c_text, "owned by"),
        "and which region owns the offending centre -- the fact that decides it");

  std::printf("%s: %d checks, %d failures\n", g_failures == 0 ? "PASS" : "FAIL", g_checks,
              g_failures);
  return g_failures == 0 ? 0 : 1;
}
