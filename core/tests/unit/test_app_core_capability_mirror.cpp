// test_app_core_capability_mirror.cpp — task
// 2026-08-03-retention-designbox-device-failure.
//
// WHY A CORE TEST READS SWIFT.
//
// The app mirrors a handful of core REFUSALS: rules the solver enforces, which the
// app restates so a button can be disabled with the reason instead of submitting a
// job that comes back refused. A mirror is only safe if it moves when core moves.
//
// PR 284 knew that and armed a tripwire — a Swift test that reads
// `core/src/cli/run_job.cpp` and fails the moment core stops refusing. PR 285
// stopped refusing three hours later. The tripwire DID go red. Nobody saw it,
// because CI (.github/workflows/ci.yml) has exactly one job — `core-linux` — which
// configures `core/` and runs ctest. It has never built the app package, so no app
// test has ever gated a PR. The maintainer's next run showed a greyed-out Lattice
// button explaining that "the core refuses to lattice it", from a build whose core
// certifies it happily.
//
// So the tripwire is restated HERE, in the suite that actually gates merges. It is
// pure text over two files in this repo — no OCCT, no Eigen, no Swift toolchain —
// so it runs in every configuration on the Linux runner, and a core change that
// leaves the app's mirror behind fails the PR that makes it.
//
// TO ADD A MIRROR: put the core phrase and the app constant in the table below.

#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                           \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

static std::string read_file(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) {
    std::fprintf(stderr, "FAIL: cannot read %s\n", path.c_str());
    ++g_failures;
    return {};
  }
  std::ostringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

static bool has(const std::string& hay, const std::string& needle) {
  return hay.find(needle) != std::string::npos;
}

int main() {
  const std::string repo = REPO_ROOT_DIR;
  const std::string run_job = read_file(repo + "/core/src/cli/run_job.cpp");
  const std::string gate =
      read_file(repo + "/app/TopOptKit/Sources/TopOptFlows/VariantEntry.swift");
  if (run_job.empty() || gate.empty()) {
    std::fprintf(stderr, "app/core mirror: %d checks, %d FAILURES\n", g_checks,
                 g_failures);
    return 1;
  }

  // ── MIRROR 1: the BLANKET design-box lattice refusal, removed by PR 285 ─────
  // Core must not carry it, and the app's switch must agree that it does not.
  const std::string blanket =
      "lattice certification does not support a design box";
  const bool core_refuses_every_box = has(run_job, blanket);
  const bool app_refuses_every_box = has(gate, "designBoxRefused = true");

  CHECK(core_refuses_every_box == app_refuses_every_box,
        "LatticeCoreCapability.designBoxRefused disagrees with run_job.cpp. "
        "Core carrying the blanket design-box refusal and the app blocking on it "
        "must be the same answer — set designBoxRefused in "
        "app/TopOptKit/Sources/TopOptFlows/VariantEntry.swift to match.");

  // The app must still HOLD the phrase it is mirroring, so the comparison above
  // is anchored to core's own words rather than to a paraphrase that drifts.
  CHECK(has(gate, blanket),
        "the app no longer quotes core's blanket-refusal phrase, so the mirror "
        "has nothing to compare against");

  // ── MIRROR 2: the refusal core DOES still carry — grading + design_box ──────
  // Both run_job's pre-flight and lattice_variant_job throw it; the app's live
  // conflict is what mirrors it.
  const std::string graded =
      "block is not yet supported together with a";
  const bool core_refuses_graded_box = has(run_job, graded);
  const bool app_mirrors_graded_box = has(gate, "gradedDesignBoxRefusalPhrase");

  CHECK(core_refuses_graded_box == app_mirrors_graded_box,
        "the grading-with-a-design-box refusal and the app's live conflict "
        "disagree. If core dropped it, drop LatticeCoreCapability's "
        "gradedDesignBoxRefusalPhrase and liveConflict with it; if core added "
        "one, the app must state it.");

  // ── THE INVARIANT BEHIND BOTH ──────────────────────────────────────────────
  // The app may never be the last one holding a rule the solver dropped. Stated
  // as its own check so the failure message says the principle, not just a diff.
  CHECK(!(app_refuses_every_box && !core_refuses_every_box),
        "the app refuses a design-box lattice that core certifies — this is the "
        "exact regression of 2026-08-02: a disabled button citing a core rule "
        "that no longer exists");

  std::fprintf(stderr, "app/core mirror: %d checks, %d FAILURES\n", g_checks,
               g_failures);
  return g_failures == 0 ? 0 : 1;
}
