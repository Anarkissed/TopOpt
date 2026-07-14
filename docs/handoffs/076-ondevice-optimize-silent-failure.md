# 076 — On-device optimize silent failure (diagnose-first)

**Status:** app-side DIAGNOSED + INSTRUMENTED + made honest. Root cause is a **core**
solver stall (deferred to a core follow-up, below). No `/core/` changed.

**Worktree:** `/Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/mma-switchover-default-4244f5`
**Branch:** `claude/diagnose-optimize-silent-fail-d1e07b`
**Needs a current xcframework:** yes — this is an `/app/`-only change; run
`./app/scripts/build_core.sh` (~50s) in a fresh worktree before `swift test` /
building the app (the vendored `TopOptCore.xcframework` is git-ignored and was absent).

## TL;DR

The symptom — "import STEP, tap Optimize, **hangs at 0%**, no error, and Optimize greys
out until you **leave the project and come back**" — is **not a swallowed error**. The
app's error path is already correct: a `BridgeError`/`std::exception` is surfaced
end-to-end as a `.solver` failure sheet (proven by the pre-existing
`testSolverThrowIsAFailureSheetWithDiagnostic`, and the STEP-1 trace below). The run
**never throws** — it never returns either. The background bridge call is stuck in the
core solve, so `RunModel.finish` never fires, `phase` stays `.running`, the card sits at
0%, and `canOptimize`'s `guard phase != .running` greys Optimize.

**On the greyed button (corrected):** it is *not* permanent. It stays greyed for as long
as **that** `RunModel` instance lives at `.running` — `backHome()` neither cancels the run
nor resets the phase (`AppModel.swift:494`). Leaving and reopening the project re-enables
it because the reopen rebuilds a **fresh** `ProjectModel`/`RunModel` (phase `.idle`) from
disk on a `projectsById` cache miss (`AppModel.swift:476`) — e.g. after the app is
relaunched/evicted. A same-launch reopen that *hits* the cache reuses the stuck model
(`AppModel.swift:474`). The orphaned background solve keeps running the whole time. The
STEP-4 watchdog now recovers the run **in place** (after the grace period) so leaving the
project is no longer required.

Root cause (STEP 2): the **production MultigridCG path** — flipped on in handoff 074 at
both bridge entry points — stalls and then runs an **effectively-unbounded Jacobi-CG
fallback** (~`2·n_dof` ≈ **1.6M iterations**). That is a multi-hour, effectively-hung
first solve on an iPad. It is **not covered by any desktop test**: the library default
stays JacobiCG, so Gate-V2 / `minimize_plastic` tests never exercise the production
solver, and the `test_mgcg` unit tests cap iterations at 100 on **solid** grids (no
soft-void contrast). See "Core follow-up".

### Trigger, narrowed by user testing: it reproduces ONLY with the design box (growth space)

The hang appears **only when the bounding/design box is used**, never without it — a
decisive clue. The design box is the sole path that calls `expand_design_domain` and
solves on a **larger EXPANDED grid** instead of the part grid. That expanded grid is what
makes the fallback catastrophic:

- **Odd / non-2-divisible expanded dims** (`expand_design_domain` pads by arbitrary voxel
  counts — e.g. the core test sees `11×3×11`) mean multigrid **cannot coarsen**, so it
  drops **straight to the pure Jacobi-CG fallback** (`multigrid.cpp:29-32`) — no MG
  acceleration at all.
- The box **grows material into empty space**: the expanded region starts at
  `density_min` (soft void) everywhere except the frozen part, so a large fraction of a
  now-larger grid is 10⁹-contrast soft void — worst-case conditioning for Jacobi-CG.
- Result: a large, ill-conditioned system solved by un-accelerated CG with a ~`2·n_dof`
  cap → the hang. Without a box the part grid is smaller and better-conditioned, MG
  engages (or CG converges quickly), so no hang.

**Ruled out — the BC/load remap.** I suspected the bridge builds `bcs`/loads on the part
grid while the solve runs on the expanded grid without remapping. **Refuted:**
`minimize_plastic` remaps BOTH `bcs` and `external_loads` by the expand offset via
`remap_node_to_domain` (`core/src/simp/minimize_plastic.cpp:157-187`), and a validation
test exercises it at a **nonzero** offset (`core/tests/validation/test_design_domain.cpp`).
The bridge is also self-consistent: it builds `bcs`/loads and calls `minimize_plastic`
with the **same** part `grid`. So the expanded system is correctly constrained — it is a
solver **conditioning/size** problem, not a wrong-BC problem.

## STEP 1 — where `err.message` goes (it is NOT dropped)

`run_minimize_plastic_loadcase` / `run_minimize_plastic` (`bridge.cpp`) catch
`std::exception` → `err.ok=false`, `err.message=e.what()`.
→ `TopOptKit.minimizePlasticLoadCase` / `minimizePlastic` call `throwIfFailed(err)` →
`throw TopOptError(message:)` (`TopOptKit.swift:539`).
→ `RunModel.bridgeRunner` (`RunModel.swift`) rethrows; `start`'s background closure
catches into `.failure(error)`; `finish`'s `.failure` branch sets
`failure = .solver(message)`, `phase = .failed`.
→ `RunScreen` renders `failureSheet` on `.failed` (`RunScreen.swift:46,143`).

**Conclusion:** for a genuine throw the message already reaches the UI. The bug is a
**hang**, which produces no throw to surface — so STEP 1's premise (a swallowed
`err.message`) does not hold. The honest app-side fix for a *hang* is a watchdog (STEP 4).

## Instrumentation added (the actual diagnostic spine)

**`bridge.cpp`** — a `bridge_log()` helper (os_log on Apple → Console.app + Xcode;
stderr elsewhere) emits greppable `[TopOptBridge]` checkpoints through the whole setup:
ENTER (with **#anchors / #load groups / #load faces / minimize_plastic / design_box /
resolution**), STEP import, post-voxelize **grid dims + spacing + bbox + solid count**
(`grid_summary`), and — the key one — **"entering minimize_plastic (solver=MultigridCG)"**
with the final **grid dims, #nodal_loads, #dirichlet_bcs** immediately before the solve,
then a return / THREW line. The "entering minimize_plastic" line logs **both** the part
grid and — when a design box is set — the **expanded `SOLVED-ON` grid** (the larger grid
that actually hangs), plus `design_box=`, `nodal_loads=`, `dirichlet_bcs=`. On the next
device run the **last line printed** pinpoints the stall: it will be that line, proving
the hang is in the core solve (the first FEA solve runs before the first progress tick),
and showing the expanded dims + load case the solver was handed (STEP 2's counts).

**`RunModel.swift`** — `diag()` (os_log, category `run`) logs the failure reason before
the sheet renders, so a failed run is never silent even pre-UI.

## STEP 4 — the app-side honesty fix: setup-stall watchdog

`RunModel` now arms a `RunWatchdog` at `start`. It is **disarmed by the first sign of
progress** (`publish` / `appendStreamed`) — so a slow-but-healthy run is **never** touched
— and if it fires first (no progress within a generous grace, default **150 s**) the
stalled run is converted into an honest failure sheet (`RunFailure.stalledDuringSetup`,
actionable: "try Fast resolution or a simpler load case") and `phase` leaves `.running`,
so **Optimize re-enables**. When the stalled run used a **design box**, the sheet names it
(`RunFailure.stalledWithDesignBox`: "turn it off or make it smaller") since that is the
confirmed trigger and the reliable workaround today; otherwise the generic
`stalledDuringSetup` copy. Production `TimerRunWatchdog` uses a cancellable main-queue
timer; tests inject a manual one. Also hardened: an **empty** core diagnostic no longer
renders a blank sheet (`RunFailure.unknownSolverError`), and `finish` now carries the
run's `CancelToken` and drops **stale** results (a watchdog-failed run's orphaned core
computation returning late must not clobber a fresh run).

This does not — and must not — fix the core stall; it makes the app **honest** about it.

## STEP 3 — headless guards

No throw exists to reproduce (it's a hang), and no STEP load-case fixture wires a full
anchored case, so the guards are:

- `testSetupStallBecomesAFailureSheet` — a held (never-returning) run + a fired watchdog
  ⇒ `.failed` with `stalledDuringSetup`, not a stuck `.running`. **This is the
  regression guard for the reported bug.**
- `testSetupStallWithDesignBoxNamesTheBox` — a stalled run that used a design box surfaces
  the design-box-tailored message (points at the confirmed trigger).
- `testWatchdogDisarmsOnFirstProgress` — one progress tick stands the watchdog down; a
  late fire is a no-op (a healthy run is never aborted).
- `testLateReturnFromAStalledRunIsDroppedForTheNewRun` — the stale-result / token guard.
- `testProductionMultigridPathTerminatesAndReportsProgress` — drives the **real**
  production MultigridCG bridge path at **res 16** (engages the MG hierarchy, unlike the
  existing res-8 real test which falls straight to Jacobi), asserting it terminates and
  streams progress. A future MG stall at this scale trips the 300 s timeout in CI instead
  of shipping to a device. (~29 s locally.)

## Load-case reality on device (STEP 2 context)

`canOptimize(in:minimizePlastic:)` returns `true` with **zero anchors and zero loads**
when minimize-plastic is on, so the button is tappable with an empty case. That is **not**
a setup throw: the bridge falls back to a min-x clamp + self-weight
(`bridge.cpp` `any_fixture` path). So an empty/degenerate load case still feeds the same
MultigridCG solve and stalls the same way — the hang is in the solver, not the load setup.

## Files changed (core untouched — `git diff --stat -- core/` is empty)

```
app/TopOptKit/Sources/TopOptBridge/bridge.cpp            |  75 +++++++++
app/TopOptKit/Sources/TopOptFlows/RunModel.swift         | 148 +++++++++++++--
app/TopOptKit/Tests/TopOptFlowsTests/RunModelTests.swift | 123 ++++++++++++
```

## Raw test output

`./app/scripts/build_core.sh` → built macOS (Eigen+OCCT) + iOS sim/device (OCCT-free)
slices, vendored `TopOptCore.xcframework`.

`swift test` (full package):
```
Test Suite 'All tests' passed …
   Executed 388 tests, with 0 failures (0 unexpected) in 51.375 seconds
```
New tests (subset): all pass —
`testSetupStallBecomesAFailureSheet`, `testWatchdogDisarmsOnFirstProgress`,
`testLateReturnFromAStalledRunIsDroppedForTheNewRun` (each <1 ms),
`testProductionMultigridPathTerminatesAndReportsProgress` (29.4 s, terminates + ticks).

## Deferred to a CORE follow-up (do NOT hack from /app/)

The stall is in `core/src/fea/multigrid.cpp` and must be fixed there. **The reproducer to
use is a design-box (expanded-grid) run**, since that is what triggers it on device:

1. **Near-unbounded Jacobi-CG fallback cap (primary).** Production passes
   `cg_max_iterations = 0` → `cap = std::max(1000, 2*ng)` (`multigrid.cpp:396-397`). On the
   SIMP soft-void operator (`density_min=1e-3`, `penalty=3` ⇒ 10⁹ contrast) geometric MG
   stagnates, bails after `kMgIterBudget=100` V-cycles (`multigrid.cpp:408`), and
   `jacobi_cg_fallback(…, cap, …)` (`:428`) grinds up to ~`2·n_dof` ill-conditioned CG
   iterations. **Fix candidates:** a sane hard cap (e.g. a few thousand) that then
   **throws** non-convergence (so the app surfaces it via the existing `.solver` path),
   and/or a stronger preconditioner for high-contrast operators.
2. **Expanded-grid coarsening (the design-box amplifier).** `expand_design_domain` yields
   arbitrary-parity dims, so MG **cannot build a hierarchy** and drops straight to the
   un-accelerated Jacobi-CG fallback (`multigrid.cpp:29-32`) on a *larger*, soft-void-
   dominated system — the box-only trigger. **Fix candidate:** pad the expanded grid to
   coarsening-friendly (even, ≥ a few levels) dims so MG actually engages on design-box
   runs; that alone likely removes the observed hang even before the cap fix.
3. **Coverage gap (this is why it shipped).** Add a validation/property test running
   `minimize_plastic` with `opts.simp.solver = MultigridCG`, a **`design_box`**, non-empty
   `bcs`/`external_loads`, and the production `cg_max_iterations = 0`, asserting bounded
   time / a clean throw. Today nothing exercises the production solver on an expanded grid
   (all mgcg tests use solid grids + cap 100; all gate/minimize tests use default
   JacobiCG; `test_design_domain` uses default JacobiCG). Ref: handoff 074 (the flip).
4. Secondary: Galerkin hierarchy setup memory pressure at large DOF on iPad.

**Captured `err.message` on device:** *none* — the run does not throw; it hangs. The next
device run with this build will print the `[TopOptBridge]` checkpoint trace; the expected
last line is `entering minimize_plastic (solver=MultigridCG) design_box=1 part … | SOLVED-ON
expanded grid … nodal_loads=… dirichlet_bcs=…`, confirming the stall is inside the core
solve on the **expanded** grid. If instead a real message appears, the new `diag()`/sheet
path will show it verbatim.

**Interim workaround for users:** run **without** the growth space (design box) — the
part-grid path does not hang. The watchdog now also names the box in the failure sheet
when a stalled run used one.
