// test_plsm_topology_drainability.cpp — the OPTIMISER and MANUFACTURING
// readings of `void_topology` are different questions, and this pins both.
//
// Task 2026-08-13-in-region-drainability. The harness header
// `core/tests/harness/plsm_topology.hpp` counts void components and cavities for
// the parametric level set. Its `in_region` is a TEMPLATE PARAMETER, not a
// hardcoded rule, and `levelset_probe.cpp` passes
//
//     in_active(v) = tags[v] != Empty && eff[v] == Active
//
// at all three call sites — the ACTIVE set, which EXCLUDES the frozen region.
//
// ★ THAT PREDICATE IS CORRECT FOR THE OPTIMISER AND WRONG FOR THE PRINTER.
// `void_topology` scores a component OPEN when it touches a lattice face OR a
// voxel outside the region. With the active-set predicate, frozen material is
// "outside the region", so ★A POCKET WALLED IN ENTIRELY BY A BOLT BOSS IS SCORED
// DRAINABLE. Powder does not pass through a bolt boss.
//
// ★ The fix is A SECOND PREDICATE, NOT A CHANGED ONE. The optimiser genuinely
// does not own the frozen set, so its own topology counters are right to ignore
// it; what was missing is that the harness reported only that reading. This test
// asserts BOTH readings on one fixture so neither can drift into the other.
//
// THE FIXTURE, 7x7x7, deliberately the smallest thing that separates them:
//   * indices 1..5 on every axis are PART; 0 and 6 are outside it (exterior).
//   * the single centre voxel (3,3,3) is VOID and ACTIVE.
//   * every other part voxel is SOLID and FROZEN.
// So the void is enclosed on all six faces by frozen solid, and touches no
// lattice face. The optimiser reading must call it open; the manufacturing
// reading must call it sealed.

#include <cstdio>
#include <ctime>
#include <vector>

// ★ AT FILE SCOPE AND FIRST. `levelset_kernel.hpp` is a SHIM whose bodies are
// `topopt::plsm_*`, so core's kernel header must already be open when it is
// read — the same ordering `plsm_probe.cpp` and `levelset_probe.cpp` follow.
#include "topopt/plsm_kernel.hpp"

#include "../harness/levelset_kernel.hpp"
#include "../harness/plsm_topology.hpp"

namespace {
int g_fail = 0;
void check(bool ok, const char* msg) {
  std::printf("  [%s] %s\n", ok ? "PASS" : "FAIL", msg);
  if (!ok) ++g_fail;
}
}  // namespace

int main() {
  Dims d;
  d.nx = d.ny = d.nz = 7;
  const std::size_t n = static_cast<std::size_t>(d.nx) * d.ny * d.nz;

  // occ: 1.0 = solid, 0.0 = void. Everything is solid except the centre.
  std::vector<double> occ(n, 1.0);
  // in_part: the 5x5x5 interior. Outside it is the true exterior.
  std::vector<char> in_part(n, 0);
  // frozen: every part voxel except the centre.
  std::vector<char> frozen(n, 0);

  for (int k = 1; k <= 5; ++k)
    for (int j = 1; j <= 5; ++j)
      for (int i = 1; i <= 5; ++i) {
        const std::size_t v = d.at(i, j, k);
        in_part[v] = 1;
        frozen[v] = 1;
      }
  const std::size_t centre = d.at(3, 3, 3);
  occ[centre] = 0.0;    // the pocket
  frozen[centre] = 0;   // it is the only ACTIVE voxel

  // Outside the part reads as void too (it is empty space), exactly as it does
  // on a real grid — this is what makes the escape test non-trivial.
  for (std::size_t v = 0; v < n; ++v)
    if (!in_part[v]) occ[v] = 0.0;

  auto in_active = [&](std::size_t v) { return in_part[v] && !frozen[v]; };
  auto in_part_pred = [&](std::size_t v) { return in_part[v] != 0; };

  std::printf("== 1. THE OPTIMISER READING — active set, frozen EXCLUDED ==\n");
  const VoidTopology opt = void_topology(d, occ, in_active, true);
  std::printf("     components %d   cavities %d\n", opt.components, opt.cavities);
  check(opt.components == 1, "the pocket is the only void component in the active set");
  // ★ THE DEFECT, PINNED AS BEHAVIOUR RATHER THAN ASSERTED AWAY. This is not a
  // bug in void_topology: with the active-set predicate the frozen neighbours
  // ARE outside the region, so scoring the pocket open is the correct answer to
  // the question the optimiser asked. It is the wrong question for a printer.
  check(opt.cavities == 0,
        "★ the optimiser reading scores the frozen-walled pocket DRAINABLE "
        "(cavities == 0) — correct for the design region, wrong for the printer");

  std::printf("== 2. THE MANUFACTURING READING — whole part, frozen counts as SOLID ==\n");
  const VoidTopology man = void_topology(d, occ, in_part_pred, true);
  std::printf("     components %d   cavities %d\n", man.components, man.cavities);
  check(man.components == 1, "the pocket is still one component over the part");
  check(man.cavities == 1,
        "★ the manufacturing reading scores it SEALED (cavities == 1)");

  std::printf("== 3. THE TWO READINGS DISAGREE, WHICH IS THE POINT ==\n");
  check(opt.cavities != man.cavities,
        "one fixture, two predicates, two answers — a single reported number "
        "cannot serve both callers");

  std::printf("== 4. A POCKET OPEN TO THE EXTERIOR IS OPEN UNDER BOTH ==\n");
  // Punch the frozen wall out to the exterior along -x from the centre.
  std::vector<double> occ2 = occ;
  for (int i = 1; i <= 3; ++i) occ2[d.at(i, 3, 3)] = 0.0;
  const VoidTopology opt2 = void_topology(d, occ2, in_active, true);
  const VoidTopology man2 = void_topology(d, occ2, in_part_pred, true);
  std::printf("     optimiser cavities %d   manufacturing cavities %d\n",
              opt2.cavities, man2.cavities);
  check(man2.cavities == 0,
        "with a channel to the exterior the manufacturing reading is drainable");
  check(opt2.cavities == 0, "and so is the optimiser reading");

  // ── ★ 5. WHAT A PER-ITERATION DRAINABILITY MONITOR WOULD COST ────────────
  //
  // Timed here rather than by differencing two probe runs: the machine was
  // under external load during the cross-check and differencing attributed a
  // 1.9x UNIFORM slowdown to the added measurement, which would have killed the
  // cheapest option in the scoping on a measurement artefact. This is the same
  // code on the same shape of grid, with nothing else in the process.
  //
  // NOT an assertion — a timing on a shared machine is not a contract. Printed
  // so the scoping has a number that came from running it.
  {
    Dims big;
    big.nx = 128; big.ny = 31; big.nz = 118;      // his grid, exactly
    const std::size_t bn = static_cast<std::size_t>(big.nx) * big.ny * big.nz;
    std::vector<double> bocc(bn, 1.0);
    std::vector<char> bpart(bn, 1);
    // ~20% void in compact pockets, the shipped-rung regime.
    for (int k = 0; k < big.nz; ++k)
      for (int j = 0; j < big.ny; ++j)
        for (int i = 0; i < big.nx; ++i)
          if (((i / 3) + (j / 3) + (k / 3)) % 5 == 0) bocc[big.at(i, j, k)] = 0.0;
    auto bin = [&](std::size_t v) { return bpart[v] != 0; };
    const int reps = 5;
    const std::clock_t t0 = std::clock();
    long long sink = 0;
    for (int r = 0; r < reps; ++r) sink += void_topology(big, bocc, bin, true).components;
    const double per = static_cast<double>(std::clock() - t0) /
                       static_cast<double>(CLOCKS_PER_SEC) / reps;
    std::printf("== 5. COST OF ONE DRAINABILITY READING ON A 128x31x118 GRID ==\n");
    std::printf("     %.4f s per call (%d reps, %lld components seen)\n", per, reps, sink);
    std::printf("     against a ~28 s state solve that is %.3f%% of an iteration\n",
                per / 28.0 * 100.0);
  }

  std::printf(g_fail ? "\nFAILED (%d)\n" : "\nOK\n", g_fail);
  return g_fail ? 1 : 0;
}
