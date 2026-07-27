# Assertions must survive the build type (build system only)

**Scope:** build system + documentation only. **`core/src` untouched** — the
assertions themselves were not rewritten, weakened, or deleted. Another task is
live in `core/src/simp/simp.cpp`; this change deliberately stays out of it.

## What this change actually does — and does not — do (read first)

`NDEBUG` is defined only by the optimized configs (`Release`, `RelWithDebInfo`,
`MinSizeRel`). **The `Debug` config never defines `NDEBUG`**, so in Debug the
`assert()`s were *always* live — before this change as much as after — and the
`-UNDEBUG` this change adds is a **no-op in Debug**. This change alters exactly
one thing: it keeps the asserts live in the **optimized** configs, where
`-DNDEBUG` was silently deleting them.

That split governs how to read the A5 evidence below:

- **Release ctest is the proof.** Release is the config this change actually
  changes (guards were dead, now live). Its full pass is the load-bearing result.
- **Debug ctest is a regression check.** Debug is the config where the guards
  were already live and `-UNDEBUG` does nothing; its pass only confirms the
  redundant flag introduced no breakage. It proves the weaker half.

## The defect

Every safety guard in the core is a plain `assert()`. Plain `assert()` is
compiled to nothing when `NDEBUG` is defined. This repo never overrides
`CMAKE_CXX_FLAGS_RELEASE`, so `-DCMAKE_BUILD_TYPE=Release` (and
`RelWithDebInfo` / `MinSizeRel`) appends `-DNDEBUG` and **silently deletes every
one of those guards** — the build still succeeds, `ctest` still passes, and the
protection is gone with no signal.

This stopped being hypothetical when the Phase-0 outer-iterations handoff
committed a copy-paste `-DCMAKE_BUILD_TYPE=Release` reproduce line
(`docs/handoffs/2026-07-26-outer-iterations-phase0.md`) — the next person to
build the project from those instructions would disarm the guards.

## The fix (target level, not build-type advice)

`core/CMakeLists.txt`, on the `topopt` target itself:

```cmake
if(MSVC)
  target_compile_options(topopt PRIVATE /UNDEBUG)
else()
  target_compile_options(topopt PRIVATE -UNDEBUG)
endif()
```

Why this shape:

- **Target-level, not "use Debug".** The whole defect is that a *correct-looking*
  release build disarms the guards. The protection must not depend on the
  caller picking a build type, so we strip `NDEBUG` on the library target
  regardless of `CMAKE_BUILD_TYPE`.
- **A compile OPTION, not a compile DEFINITION.** CMake emits `-D` definitions
  *before* the per-config flags but appends target compile options *after* them.
  A trailing `-UNDEBUG` therefore reliably wins over the config's `-DNDEBUG`
  (verified below: `simp.cpp` is compiled `... -DNDEBUG -UNDEBUG`). Adding it as
  a definition would land before `-DNDEBUG` and lose.
- **PRIVATE.** All six asserts live in the library's own translation units, so
  the flag only needs to apply to `topopt`'s sources; it does not leak onto
  executables that merely link the target.

## Assert inventory — the core production path

There are exactly **6 runtime `assert()` calls** in `core/src` (no runtime
asserts in `core/include`; `static_assert` excluded). All six are in the two
Eigen-gated optimizer TUs that compile into `libtopopt`:

| # | File:line | Guards | Frequency |
|---|-----------|--------|-----------|
| 1 | `simp/simp.cpp:1798` | Draft-quality parity: the final **certified** compliance solve (unconstrained overload) runs at the tight `cg_tolerance` — the adaptive loose trajectory schedule equals the cert tol at rest and is never tighter than it. Draft mode structurally cannot certify on a loosened solve. | **once per `simp_optimize` call** (finalize block) |
| 2 | `simp/simp.cpp:2596` | Same parity guard for the **masked/active-domain overload's** certificate. | **once per `simp_optimize` call** (finalize block) |
| 3 | `simp/minimize_plastic.cpp:724` | Draft escalation must never loosen the certification tolerance (`opt_esc.cg_tolerance == kCertTol`) when it re-runs a rung at the tight tol. | per ladder-rung, **only when draft escalation triggers** |
| 4 | `simp/minimize_plastic.cpp:879` | `result.evaluated` never grows past its reserved ladder capacity — protects the long-lived references taken into that vector (infeasible-rung push path). | once **per ladder-rung** |
| 5 | `simp/minimize_plastic.cpp:945` | The recovery / stress-certification solve always uses the tight tolerance (`opt.cg_tolerance == kCertTol`). Draft mode cannot certify a stress margin on a loosened solve. | once **per ladder-rung** |
| 6 | `simp/minimize_plastic.cpp:1129` | Same reserved-capacity invariant as #4 on the accepted-rung push path. | once **per ladder-rung** |

**Hot-loop check (the thing the maintainer asked for):** none of the six sits in
a hot loop. The two `simp.cpp` guards run once per `simp_optimize` call in the
finalize block, *after* the iteration loop. The four `minimize_plastic.cpp`
guards run at most once per ladder rung (≈4–6 times per run), and #3 only when
draft escalation actually fires. None is inside the per-iteration CG loop or the
per-element assembly/apply loops. Each is a couple of `double` comparisons plus,
for #1/#2, two calls to the trivial arithmetic `adaptive_traj_cg_tol`. Keeping
them live is not measurable against solver time (A3 below). **There is no
hot-loop assertion to worry about before shipping.**

## Documentation fix

`docs/handoffs/2026-07-26-outer-iterations-phase0.md` — the reproduce block kept
its `-DCMAKE_BUILD_TYPE=Release` line (the `-O2` timings that produced that
handoff's measurements stand and are unchanged) but now carries a comment
stating that the `topopt` target undefines `NDEBUG` so the parity asserts stay
live under Release, with a pointer here. The measurements and conclusions were
not touched.

---

## Evidence (`evidence/2026-07-26-ndebug-assertions/`)

Host: macOS (arm64), Apple clang 21.0.0, CMake 4.4.0, Eigen + OCCT 7.9.3 present
locally; lib3mf not installed locally, so the single `threemf_roundtrip` TU/test
is absent (67 tests configure instead of 68). CI builds with
`-DTOPOPT_REQUIRE_DEPS=ON` and has all three deps.

Note on method: the two draft-quality parity guards are **structurally
always-true invariants** — at `change == 0`, `adaptive_traj_cg_tol` returns
`cg_tolerance` by construction, so no public input can make the predicate false.
That is exactly why they are `assert`s. They therefore cannot be tripped through
the API without editing `core/src` (forbidden here). Liveness is proven two ways
instead: (1) the *actual* guard message strings present/absent in the compiled
archive — this binds the proof to the real guards, not a stand-in — and (2) the
same violation compiled with the library's *own* before/after `NDEBUG` flags.

### A1 (guards live under Release) + A2 (old behaviour broken)

`A1-A2-archive-strings.txt` — the real guards in `libtopopt.a`, built with
`-DCMAKE_BUILD_TYPE=Release`:

| guard message | BEFORE (main) | AFTER (fix) |
|---|---|---|
| `certification tolerance must be the tight floor` | 0 | 1 |
| `must use the tight` | 0 | 1 |
| `escalation must never loosen` | 0 | 1 |
| `grew past its reserved capacity` | 0 | 1 |

`simp.cpp` compile line: BEFORE `-DNDEBUG` → AFTER `-DNDEBUG -UNDEBUG`.
`0` = the guard's `assert` was compiled out of the Release archive (disarmed,
A2). `1` = compiled in (live, A1).

`A1-A2-guard-fire.txt` — the same violation (`guard_fire_probe.cpp`, which
reproduces `simp.cpp:1798`'s predicate + message verbatim with the certification
tolerance deliberately loosened off the tight floor), compiled with the two flag
regimes the library itself uses:

- BEFORE flags (`-O2 -DNDEBUG`): reaches `certified`, exit 0 — guard **dead**.
- AFTER flags (`-O2 -DNDEBUG -UNDEBUG`): `Assertion failed: … must be the tight
  floor …`, SIGABRT, exit 134 — guard **fires**.

### A3 (cost) + A4 (byte identity)

`A3-A4-cost-byte-identity.txt`, `reference_run_before.txt`,
`reference_run_after.txt` — one production `minimize_plastic` ladder on a tiny
10×4×10 L-bracket (`ref_run.cpp`), run against the BEFORE-lib (guards out) and
AFTER-lib (guards live).

- **A4:** `cmp` reports the two reference outputs BYTE-IDENTICAL — same 10-digit
  per-rung compliances, same per-rung physical-density FNV-1a digests, same
  accepted/infeasible flags. Assertions that pass change nothing.
- **A3 headline (CG iterations, unchanged):** `TOTAL_CG_ITERATIONS = 111309`
  before and after; per-rung `7694 / 12017 / 35149 / 56449` identical. Asserts
  are checks, not math, so the solver does the same work.
- **A3 corroboration (labelled, wall clock is not a headline):** `/usr/bin/time
  -p`, 3 samples each — before `user ≈ 6.7–7.1 s`, after `user ≈ 6.7–7.0 s`; the
  ranges overlap. No assert is individually chargeable to time (see hot-loop
  check above).

#### A3 — full Release ctest cost, measured before/after pair

`A3-release-ctest-cost.txt`, `ctest-release-baseline.txt` (guards compiled out),
`ctest-release.txt` (guards live). Both are the same 67-test suite, serial
`ctest`, same machine, measured **idle**, back-to-back:

| Release ctest | guards | result | Total Test time (real) |
|---|---|---|---|
| `ctest-release-baseline.txt` (main, no `-UNDEBUG`) | compiled out | 67/67 | **1351.82 s** |
| `ctest-release.txt` (fixed, `-UNDEBUG`) | live | 67/67 | **893.88 s** |

The guards-**live** run is **458 s faster** than guards-out. Assertions can only
*add* time, so this delta is entirely environmental noise, not assertion cost — a
third same-suite Release run (earlier, sharing the machine with the Debug ctest)
totalled 838.94 s, giving `838.94 / 1351.82 / 893.88 s` across three runs: a
~500 s spread with the ordering inverted. **Full-suite ctest wall time cannot
resolve assertion cost.**

The valid, controlled cost figure is the `ref_run` pair above: the same ladder
run against the guards-out and guards-live libraries executes the **identical
111309 CG iterations** and produces **byte-identical** output. The six asserts
are 6 `double` comparisons executed a handful of times per run (never in the
CG/element inner loops) — nanoseconds, orders of magnitude below the ~500 s ctest
noise floor. **Cost of keeping the guards live: unmeasurable in wall time, provably
zero in algorithmic work.**

### A5 (ctest passes in Debug and Release)

Raw logs: `ctest-release.txt`, `ctest-debug.txt` (full, with
`--output-on-failure`). Both configs: **100% tests passed, 0 failed out of 67**
(Release total 893.88 s guards-live; Debug total 18441.09 s — Debug is an
unoptimized build, so its FEA/optimizer validation tests run many times slower,
`cli_demo` alone shelling out to `topopt-cli` for a battery of full solves). The
`ctest-release.txt` used here is the clean, idle, guards-live run (same one that
serves as the A3 "after" measurement).

Per the framing at the top: **Release is the proof** (the config where this
change flips the guards from dead to live) and **Debug is the regression check**
(the config where the guards were already live and `-UNDEBUG` is a no-op). Debug
ran far slower only because it is an unoptimized build of the same FEA/optimizer
validation suite; the slowness is the build config, not this change.

### A6 (no core/src changes)

```
 core/CMakeLists.txt                                | 26 ++++++++++++++++++++++
 docs/handoffs/2026-07-26-outer-iterations-phase0.md |  5 +++++
 2 files changed, 31 insertions(+)
```

`git diff --name-only | grep '^core/src/'` → no matches. `core/src` untouched.

## BLOCKED-STOP: not triggered

The guards were kept live **without** editing `core/src` — a target-level
`-UNDEBUG` on `topopt` is sufficient, and the assertions remain exactly as
written. No conversion of the two parity guards to runtime checks was needed, so
nothing is deferred to after the current core task.
