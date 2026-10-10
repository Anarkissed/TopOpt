// ── K3: ON A PLAN JOB THE PLAN IS THE DESIGN, NOT CORE'S OWN GRADING ───────────
// Reviewer's ruling of 2026-10-10, three points, each proven here on a fixture with a
// PARTIAL-DEPTH prism:
//
//   (1) the solid companion is "printed minus the PLAN's cells", so a strip of the
//       region the plan placed no cell in prints SOLID and the plan's back nodes land
//       on it;
//   (2) the certificate's posture comes from the PLAN's mask -- and from the plan's own
//       per-cell density, because a mask without its density is half a posture;
//   (3) the receipt states the solid remainder per region, in mm3.
//
// Plus the ordering: a plan job's plan is validated BEFORE core's own grading law gets
// to refuse, because on a plan job the plan is the design and "your plan is invalid" is
// the sentence the app can act on.
//
// ── WHAT WAS WRONG, MEASURED ──────────────────────────────────────────────────
// The mask that drives the companion, the graded-cell activation, the posture, the
// min-feature pass and the void check was the LAW's. The plan decided only where struts
// went. So on `plan_partial_depth` -- a 12 mm deep region carrying ONE layer of 6 mm
// cells -- the law latticed the uncovered 6 mm strip and the companion did not fill it:
// the strip printed as air with the plan's back nodes ending on nothing.
//
// The pre-K3 binary (588672f5) on these two fixtures:
//     plan_partial_depth   solid_region_voxels 7830   volume 15292.96875 mm3
//     plan_full_depth      solid_region_voxels 7830   volume 15292.96875 mm3
// IDENTICAL -- the companion could not tell a half-covered region from a fully covered
// one, which is the defect in one line. That is why the assertions below are DIFFERENCES
// between the two runs: "the remainder is non-zero" is satisfied by a run that lattices
// nothing, and "the companion is non-zero" was already true while the bug was live.
//
// WHY THIS TEST RUNS THE BINARY: the decision lives in run_job.cpp's anonymous namespace,
// so nothing with external linkage can reach it, and what is under test is what a RUN
// emits and what its receipt says.
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <string>

static int g_checks = 0, g_failures = 0;
#define CHECK(cond, what)                                                          \
  do {                                                                             \
    ++g_checks;                                                                    \
    if (!(cond)) {                                                                 \
      ++g_failures;                                                                \
      std::fprintf(stderr, "FAIL %s:%d  %s\n", __FILE__, __LINE__, (what));        \
    }                                                                              \
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

struct Run {
  int rc = -1;
  std::string err, out, report, run_info, dir;
};

// ★ THE CONTROL IS RE-RUNNABLE. The pre-K3 numbers quoted at the top of this file were
// measured by pointing this same test at a binary built from 588672f5, through this
// override. Replacing the binary IN PLACE does not work -- macOS kills a build-tree
// executable whose bytes changed under its signature ("Killed: 9", and every check then
// fails for the wrong reason) -- so the override takes a PATH and the binary runs from
// where it was built.
static const char* cli_exe() {
  const char* over = std::getenv("TOPOPT_CLI_OVERRIDE");
  return (over != nullptr && *over != '\0') ? over : TOPOPT_CLI_EXE;
}

static Run run_job(const std::string& name) {
  Run r;
  const std::string job = std::string(ORGANIC_FIXTURE_DIR) + "/" + name + ".json";
  r.dir = std::string(CLI_TMP_DIR) + "/k3_" + name;
  const std::string so = r.dir + ".stdout", se = r.dir + ".stderr";
  std::system(("rm -rf \"" + r.dir + "\" && mkdir -p \"" + r.dir + "\"").c_str());
  const std::string cmd = std::string("\"") + cli_exe() + "\" lattice-variant \"" +
                          job + "\" --out \"" + r.dir + "\" > \"" + so + "\" 2> \"" + se +
                          "\"";
  r.rc = std::system(cmd.c_str());
  r.out = read_file(so);
  r.err = read_file(se);
  // The fixtures write "pd_<rung>_lattice.report.json"; the rung is the ladder's, so it
  // is FOUND rather than assumed (a hardcoded name once made two empty reads compare
  // equal).
  const std::string list = r.dir + "/.names";
  std::system(("ls \"" + r.dir + "\" > \"" + list + "\" 2>/dev/null").c_str());
  const std::string names = read_file(list);
  std::size_t at = names.find("_lattice.report.json");
  if (at != std::string::npos) {
    const std::size_t bol = names.rfind('\n', at);
    const std::string fn = names.substr(bol == std::string::npos ? 0 : bol + 1,
                                        at + 20 - (bol == std::string::npos ? 0 : bol + 1));
    r.report = read_file(r.dir + "/" + fn);
  }
  r.run_info = read_file(r.dir + "/run_info.json");
  return r;
}

static bool has(const std::string& h, const char* n) {
  return h.find(n) != std::string::npos;
}

// Reads a JSON number that follows "key": — the receipts are machine-written with one
// space after the colon, which the other CLI tests rely on too.
static bool num_after(const std::string& text, const char* key, double* out) {
  const std::string k = std::string("\"") + key + "\": ";
  const std::size_t at = text.find(k);
  if (at == std::string::npos) return false;
  try {
    *out = std::stod(text.substr(at + k.size()));
  } catch (...) {
    return false;
  }
  return true;
}

static bool str_after(const std::string& text, const char* key, std::string* out) {
  const std::string k = std::string("\"") + key + "\": \"";
  const std::size_t at = text.find(k);
  if (at == std::string::npos) return false;
  const std::size_t b = at + k.size();
  const std::size_t e = text.find('"', b);
  if (e == std::string::npos) return false;
  *out = text.substr(b, e - b);
  return true;
}

int main() {
  const Run part = run_job("plan_partial_depth");
  const Run full = run_job("plan_full_depth");

  CHECK(part.rc == 0, "the partial-depth plan must be ACCEPTED (it is a legal plan)");
  CHECK(full.rc == 0, "the full-depth control must be ACCEPTED");

  // ── (2) THE POSTURE IS THE PLAN'S, DENSITY AND ALL ──────────────────────────
  // Every voxel the plan lattices must be certified at the rho the plan SENT. Both
  // fixtures send a rho on every cell, so "at the law's" must be 0 -- if the posture
  // were still the law's, the certificate would be crediting a different number from the
  // one the struts were sized at, and on 570B38E2 it refused outright ("lattice relative
  // density 0.000000 is outside the certifiable octet band").
  CHECK(has(part.err, "[stepped] plan posture:"),
        "the run must state where each latticed voxel's density came from");
  CHECK(has(part.err, "0 at the law's (cells that sent none)"),
        "every cell here sends a rho, so no voxel may fall back to the law's density");
  CHECK(!has(part.err + part.out, "outside the certifiable octet band"),
        "the certificate must not be handed a zero density for a voxel the plan latticed");

  // ── RULING 1'S CONDITION: ONE DENSITY, AND THE RECEIPT COUNTS THE FALLBACKS ──
  // The certificate may never credit a strut other than the one drawn. Core reads both
  // from one function (`plan_strut_rho_at`) and refuses by name if they ever differ --
  // bit-exactly, over the FINAL mask. Proven to fire: perturbing the drawn density by a
  // relative 1e-9 makes the run exit 1 with
  //     "region 1: the strut at (18.1250, 0.6250, 8.1250) is DRAWN at relative density
  //      0.18000000018000001 and CERTIFIED at 0.17999999999999999"
  // so this is a tripwire and not a comment. Here we assert the run does NOT trip, and
  // that the receipt states the fallback count per region: both fixtures send a rho with
  // every cell, so core sizes and certifies none of their struts from its own field.
  CHECK(!has(part.err + part.out, "disagree about one voxel's density"),
        "the posture and the strut radius must not disagree about any voxel");
  std::string part_fb, full_fb;
  CHECK(str_after(part.run_info, "plan_rho_fallback_by_region", &part_fb),
        "run_info must count, per region, the voxels whose density core supplied");
  CHECK(str_after(full.run_info, "plan_rho_fallback_by_region", &full_fb),
        "the control must count them too");
  CHECK(part_fb == "r1=0" && full_fb == "r1=0",
        "every cell in these fixtures sends a rho, so no region may fall back to core's "
        "own grading for a single voxel");

  // ── K5: THE PLAN'S RHO MUST REACH EVERY STRUT **AND EVERY NODE** ────────────
  // The generator samples the radius at a strut's MIDPOINT and at a node's own position
  // (lattice_gen.cpp), and `node_pos` is `origin + g * 0.5 * cell` -- so a node with an
  // even index on an axis lies exactly ON a cell plane. A cell corner is shared by eight
  // cells, an edge node by four, a face node by two, and the octet's face-diagonal
  // struts lie IN the cell faces. Exact-boundary queries are the NORM, not an edge case.
  //
  // A half-open `floor` test attributed all of them to the cell on the + side, and at
  // the plan's outer face that cell is not in the plan -- so the lookup found nothing
  // and fell through to core's BAND FLOOR, the thinnest density the law allows, exactly
  // at the joints where the load leaves the lattice. Measured at 91abe169:
  //
  //                        from the plan   from the posture   AT THE BAND FLOOR
  //   plan_partial_depth   112             24                 30   (of 166)
  //   plan_full_depth      224             24                 55   (of 303)
  //
  // and on a 6 mm cell the band floor's 0.050470 builds a 0.547514 mm strut where the
  // plan's 0.18 asks for 1.067340 -- 1.949x too thin in diameter, 3.800x in area. The
  // emitted lattice volume rose 329.006 -> 368.093 mm3 (+11.9%) and 619.129 -> 699.275
  // (+12.9%) once the plan's density reached them.
  //
  // The bar is therefore not "most queries" but ALL of them, which is what these two
  // checks say. Re-run the measurement with TOPOPT_CLI_OVERRIDE at 91abe169.
  double q_plan = 0.0, q_post = 0.0, q_floor = 0.0;
  CHECK(num_after(part.run_info, "plan_rho_queries_plan", &q_plan) &&
            num_after(part.run_info, "plan_rho_queries_posture", &q_post) &&
            num_after(part.run_info, "plan_rho_queries_floor", &q_floor),
        "run_info must state where every strut and node radius query got its density");
  CHECK(q_plan > 0.0, "premise: the generator did ask for radii");
  CHECK(q_floor == 0.0,
        "NO strut or node may be sized at the band floor on a plan that sent a rho with "
        "every cell -- that is a notch where the load leaves the lattice");
  CHECK(q_post == 0.0,
        "and none may fall back to core's own field either: every query is answered by "
        "the plan's own cells");

  // ── (3) THE RECEIPT STATES THE SOLID REMAINDER PER REGION ───────────────────
  std::string part_rem_s, full_rem_s;
  CHECK(str_after(part.run_info, "plan_solid_remainder_mm3", &part_rem_s),
        "run_info must state the plan's solid remainder per region");
  CHECK(str_after(full.run_info, "plan_solid_remainder_mm3", &full_rem_s),
        "the control's run_info must state it too");
  CHECK(has(part_rem_s, "r1="), "the remainder is stated per region id");

  double part_rem = 0.0, full_rem = 0.0;
  // One region in these fixtures, so the per-region string is the whole number.
  if (part_rem_s.size() > 3) part_rem = std::stod(part_rem_s.substr(3));
  if (full_rem_s.size() > 3) full_rem = std::stod(full_rem_s.substr(3));
  double part_lat = 0.0, full_lat = 0.0;
  CHECK(num_after(part.run_info, "plan_latticed_mm3", &part_lat),
        "run_info must state what the plan latticed");
  CHECK(num_after(full.run_info, "plan_latticed_mm3", &full_lat),
        "the control must state it too");

  // THE PREMISE this test rests on: the control really does lattice more. Without this
  // the differences below could both be zero and every check would still pass.
  CHECK(part_lat > 0.0 && full_lat > part_lat * 1.5,
        "premise: the full-depth control must lattice substantially more than the "
        "partial plan (it has twice the cells)");
  CHECK(part_rem > 0.0, "the partial plan must leave a solid remainder");

  // COMPLEMENTARITY: what the control latticed and the partial plan did not is exactly
  // what the partial plan left solid and the control did not. Both are counted on the
  // same voxel basis, so this is exact to rounding in the printed receipt.
  const double strip_by_lattice = full_lat - part_lat;
  const double strip_by_remainder = part_rem - full_rem;
  CHECK(std::fabs(strip_by_lattice - strip_by_remainder) <= 1e-2,
        "the strip measured as lattice lost must equal the strip measured as solid "
        "gained");

  // ── (1) THE COMPANION FILLS THE STRIP ───────────────────────────────────────
  // This is the assertion the pre-K3 binary FAILS: it reported 15292.96875 mm3 for both
  // fixtures, so the difference was 0 while the correct difference is the strip.
  double part_comp = 0.0, full_comp = 0.0;
  CHECK(num_after(part.report, "solid_region_volume_mm3", &part_comp),
        "the lattice report must state the solid companion's volume");
  CHECK(num_after(full.report, "solid_region_volume_mm3", &full_comp),
        "the control's report must state it too");
  CHECK(part_comp > full_comp,
        "the partial plan's companion must be LARGER than the control's -- the strip the "
        "plan left uncovered is solid");
  CHECK(std::fabs((part_comp - full_comp) - strip_by_remainder) <= 1e-2,
        "the companion grew by exactly the solid remainder the receipt states: the "
        "companion IS printed minus the plan's cells");

  // The struts themselves must NOT have moved: K3 changes what is SOLID and what is
  // CERTIFIED, not where the plan put lattice. Both runs' strut soup scales with their
  // cell count, and the partial run's lattice volume stays what the plan asked for.
  double part_int = 0.0, full_int = 0.0;
  CHECK(num_after(part.report, "interior_volume_mm3", &part_int) &&
            num_after(full.report, "interior_volume_mm3", &full_int),
        "both reports state the lattice interior volume");
  CHECK(part_int > 0.0 && full_int > part_int,
        "the control's strut soup is larger (twice the cells), and neither is empty");

  // ── THE ORDERING: THE PLAN'S REFUSAL COMES FIRST ────────────────────────────
  // `plan_before_law` is empty_after_beam's job -- a 31 mm outline beam that clears every
  // voxel the law graded -- plus a 4 mm cell on a 6 mm halving ladder. Both are refusals.
  // The PLAN's must be the one reported. The pre-K3 binary reported the beam's and never
  // mentioned the cell, sending the app to fix a band that is not the problem.
  const Run ord = run_job("plan_before_law");
  const std::string ord_all = ord.out + ord.err;
  CHECK(ord.rc != 0, "an invalid plan is a refusal");
  CHECK(has(ord_all, "is 4 mm, which is not on that region's menu"),
        "the refusal must name the plan's own invalid cell");
  CHECK(!has(ord_all, "no lattice remains to emit"),
        "core must not blame its own grading before it has read the plan");

  std::fprintf(stderr, "%s: %d checks, %d failure(s)\n", __FILE__, g_checks, g_failures);
  if (g_failures == 0) std::fprintf(stderr, "all %d checks passed\n", g_checks);
  return g_failures == 0 ? 0 : 1;
}
