// ── RULING 2 (reviewer, 2026-10-10): THE OUTLINE IS A CLIP, IN EVERY JOB THAT SENDS ONE
//
// `point_in_clearance_region` honours `outline_uv`, so the certification MASK clips to the
// pocket. `clip_segment` consulted the include region NOT AT ALL -- LatticeBoundary's own
// signed distance is planes, base and keep-outs, and the header said in as many words that
// the role regions contribute no signed-distance term. So a cell the outline cuts had its
// struts drawn straight across the cut, a strut could run past the region's own rectangle
// until it met the shell, and the mask then certified every one of those voxels SOLID.
// One voxel described two ways is exactly what bar B7 exists to stop.
//
// ── MEASURED, on the two fixtures below ───────────────────────────────────────
// `outline_clip_whole` and `outline_clip_quadrant` are the SAME region with the SAME 32
// cells filling its whole 24 x 24 mm rectangle. The quadrant arm adds one `outline_uv`
// loop keeping a 12 x 12 mm quarter of it.
//
//                              whole        quadrant
//   mask (plan posture)        3610 vox     1000 vox    the mask already honoured it
//   interior_volume_mm3        2498.242     2502.643    <-- at f0d8bf27, PRE-CLIP
//   interior_volume_mm3         ---          427.838    <-- with the clip
//
// Pre-clip the quadrant's lattice was 100.2% of the whole rectangle's while its mask was
// 27.7% of it: 2074.8 mm3 of struts, 83% of what was written, sat in voxels the receipt
// called companion solid. That is the defect in one row, and it is why this test asserts
// a RATIO against the control arm rather than "the clip removed something".
//
// ── THE BYTE-IDENTITY BAR ─────────────────────────────────────────────────────
// Scope (b) is "every job whose include carries outline_uv", so a job with none must be
// untouched. That is structural, not a promise: `clip_includes_` is set only by
// add_include_region, and only for a geometry whose `outline_uv` is non-empty. Measured
// too -- `plan_partial_depth` (no outline) emits the same STL byte for byte before and
// after the clip, md5 6588e1651bd046fdfe8008bc1a58d059 -- and this test asserts the
// structural half: no clip line, and nothing reported as clipped away. Re-run the
// measured half with TOPOPT_CLI_OVERRIDE pointed at a binary built before the clip.
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

static const char* cli_exe() {
  const char* over = std::getenv("TOPOPT_CLI_OVERRIDE");
  return (over != nullptr && *over != '\0') ? over : TOPOPT_CLI_EXE;
}

struct Run {
  int rc = -1;
  std::string err, out, report, run_info;
};

static Run run_job(const std::string& name) {
  Run r;
  const std::string job = std::string(ORGANIC_FIXTURE_DIR) + "/" + name + ".json";
  const std::string dir = std::string(CLI_TMP_DIR) + "/oc_" + name;
  const std::string so = dir + ".stdout", se = dir + ".stderr";
  std::system(("rm -rf \"" + dir + "\" && mkdir -p \"" + dir + "\"").c_str());
  r.rc = std::system((std::string("\"") + cli_exe() + "\" lattice-variant \"" + job +
                      "\" --out \"" + dir + "\" > \"" + so + "\" 2> \"" + se + "\"")
                         .c_str());
  r.out = read_file(so);
  r.err = read_file(se);
  r.run_info = read_file(dir + "/run_info.json");
  // The report's name carries the ladder's rung, so it is FOUND, not assumed.
  const std::string list = dir + "/.names";
  std::system(("ls \"" + dir + "\" > \"" + list + "\" 2>/dev/null").c_str());
  const std::string names = read_file(list);
  const std::size_t at = names.find("_lattice.report.json");
  if (at != std::string::npos) {
    const std::size_t bol = names.rfind('\n', at);
    const std::size_t b = bol == std::string::npos ? 0 : bol + 1;
    r.report = read_file(dir + "/" + names.substr(b, at + 20 - b));
  }
  return r;
}

static bool has(const std::string& h, const char* n) {
  return h.find(n) != std::string::npos;
}

static bool num_after(const std::string& t, const char* key, double* out) {
  const std::string k = std::string("\"") + key + "\": ";
  const std::size_t at = t.find(k);
  if (at == std::string::npos) return false;
  try {
    *out = std::stod(t.substr(at + k.size()));
  } catch (...) {
    return false;
  }
  return true;
}

static bool str_after(const std::string& t, const char* key, std::string* out) {
  const std::string k = std::string("\"") + key + "\": \"";
  const std::size_t at = t.find(k);
  if (at == std::string::npos) return false;
  const std::size_t b = at + k.size(), e = t.find('"', b);
  if (e == std::string::npos) return false;
  *out = t.substr(b, e - b);
  return true;
}

int main() {
  const Run whole = run_job("outline_clip_whole");
  const Run quad = run_job("outline_clip_quadrant");

  CHECK(whole.rc == 0, "the no-outline control must be ACCEPTED");
  CHECK(quad.rc == 0, "the outlined job must be ACCEPTED -- the clip removes struts, it "
                      "does not refuse the job");

  // ── WHICH JOBS TAKE THE TERM ────────────────────────────────────────────────
  CHECK(has(quad.err, "1 clipped to their own outline"),
        "the outlined region must be reported as clipped to its outline");
  CHECK(!has(whole.err, "[clip] include regions:"),
        "a job with no outline must not even report a clip -- it cannot reach the term");

  // ── THE PREMISE: the mask already honoured the outline ──────────────────────
  // Without this, "the clip removed struts" could be satisfied by a change that removed
  // struts for some entirely different reason.
  CHECK(has(whole.err, "[stepped] plan posture: 3610 voxel(s)") ||
            has(whole.err, "[stepped] plan posture:"),
        "the control states its posture");
  double whole_lat = 0.0, quad_lat = 0.0;
  CHECK(num_after(whole.run_info, "plan_latticed_mm3", &whole_lat) &&
            num_after(quad.run_info, "plan_latticed_mm3", &quad_lat),
        "both runs state what the plan latticed");
  CHECK(whole_lat > quad_lat * 2.0,
        "premise: the mask ALREADY clipped to the outline, so the outlined job lattices a "
        "fraction of the rectangle. The defect was never the mask.");

  // ── THE RECEIPT: what the clip takes, per region, and it balances ───────────
  // The plan covers the same volume in both arms. The outline splits that volume into
  // what the region reaches and what the clip removes, so the two must add back up to the
  // control's. Exact on one voxel basis -- no tolerance is owed here.
  std::string whole_clip, quad_clip;
  CHECK(str_after(whole.run_info, "clip_outside_region_mm3", &whole_clip) &&
            str_after(quad.run_info, "clip_outside_region_mm3", &quad_clip),
        "run_info must state, per region, the volume the clip stops struts from filling");
  CHECK(whole_clip == "r1=0.000",
        "a region whose plan cells all sit inside it has nothing clipped away");
  double quad_clip_mm3 = 0.0;
  if (quad_clip.size() > 3) quad_clip_mm3 = std::stod(quad_clip.substr(3));
  CHECK(quad_clip_mm3 > 0.0, "the outlined region must report a non-zero clipped volume");
  CHECK(std::fabs((quad_lat + quad_clip_mm3) - whole_lat) <= 1e-2,
        "what the region reaches plus what the clip removes equals the volume the plan "
        "covers, which is the control's");

  // ── THE GEOMETRY ACTUALLY MOVED ─────────────────────────────────────────────
  // This is the check that fails against any binary without the clip: at f0d8bf27 the
  // outlined job wrote 2502.643 mm3 of lattice against the control's 2498.242 -- 100.2%,
  // for a pocket a quarter the area.
  double whole_int = 0.0, quad_int = 0.0;
  CHECK(num_after(whole.report, "interior_volume_mm3", &whole_int) &&
            num_after(quad.report, "interior_volume_mm3", &quad_int),
        "both reports state the lattice interior volume");
  CHECK(whole_int > 0.0 && quad_int > 0.0, "neither run may be empty");
  CHECK(quad_int < 0.25 * whole_int,
        "the struts must stop at the outline: a quarter-area pocket cannot hold a "
        "quarter-area pocket's worth of lattice and more");

  // ── AND A JOB WITH NO OUTLINE IS UNTOUCHED ──────────────────────────────────
  const Run plain = run_job("plan_partial_depth");
  CHECK(plain.rc == 0, "the no-outline plan job still runs");
  CHECK(!has(plain.err, "[clip] include regions:"),
        "no outline, no clip term, nothing reported");
  std::string plain_clip;
  CHECK(str_after(plain.run_info, "clip_outside_region_mm3", &plain_clip) &&
            plain_clip == "r1=0.000",
        "and nothing clipped away from it");

  std::fprintf(stderr, "%s: %d checks, %d failure(s)\n", __FILE__, g_checks, g_failures);
  if (g_failures == 0) std::fprintf(stderr, "all %d checks passed\n", g_checks);
  return g_failures == 0 ? 0 : 1;
}
