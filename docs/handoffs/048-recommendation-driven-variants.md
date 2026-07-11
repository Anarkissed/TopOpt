# Handoff 048 — recommendation-driven variants (lightest-safe recommendation)

## Task (maintainer-directed, interactive)
Replace the fixed 70/50/30 variant fractions with recommendation-driven ones: the
app finds the lightest design that still clears the safety margin FOR THE USER'S
LOADS and recommends it. Follows the load-case work (handoffs 046–047). Not a
ROADMAP task — no box.

## Approach (deliberately low-risk: no new core algorithm)
`minimize_plastic` already keeps the margin-SAFE prefix of whatever ladder it's
given and stops at the first too-weak rung. So a **finer, lower ladder** makes the
safe subset ADAPT to the part + load case, and the **lightest safe rung is the
recommendation**. No new core search/bisection, no core change, no xcframework
rebuild — just the bridge ladder + the results model.

## What I did (all `/app/`)
- **Bridge** (`bridge.cpp`): a shared `reduction_ladder()` = {0.68, 0.52, 0.38,
  0.26} (finer + lower than the old {0.7, 0.5, 0.3}) used by BOTH run entry points'
  reduction path (self-weight `run_minimize_plastic` and the load-case
  `run_minimize_plastic_loadcase` when `minimize_plastic` is on). A stronger part
  keeps lighter rungs; a weaker one shows fewer, heavier ones — the variants now
  differ by part. `minimize_plastic`'s margin-stop still guarantees no unsafe
  variant is ever returned. (Off → single {0.9}, unchanged.)
- **Results model** (`ResultsModel`): `ResultVariantVM.isRecommended` — the
  lightest accepted rung (last in ladder order = max plastic saved while safe) is
  the recommendation, and the results screen now DEFAULT-SELECTS it (was the middle
  tab).
- **Results screen** (`ResultsScreen`): a green "RECOMMENDED" badge on that tab.

## What this is NOT (intentional bounds)
- **NOT a true continuous search.** The recommendation is the lightest safe rung of
  a fixed fine ladder, not a bisection to the exact margin crossing. This is the
  low-risk 80/20; a continuous "solve for the exact lightest-safe fraction" (a core
  bisection driver) is a future refinement if the maintainer wants non-grid
  fractions. The ladder values are a tuning knob in one place (`reduction_ladder()`).
- Compute: up to 4 rungs evaluated (vs 3), and it stops early for weak parts —
  a modest change, within the M6.3 "1.5–3× compute" envelope.

## Test evidence (raw, pasted, unedited) — full macOS package suite
```
Test Suite 'TopOptDesignTests.xctest' passed at 2026-07-10 21:27:.. .
Test Suite 'TopOptFlowsTests.xctest' passed at 2026-07-10 21:27:51.459.
	 Executed 167 tests, with 0 failures (0 unexpected) in 72.183 (72.243) seconds
Test Suite 'TopOptKitTests.xctest' passed at 2026-07-10 21:27:55.784.
	 Executed 21 tests, with 0 failures (0 unexpected) in 3.752 (3.758) seconds
** TEST SUCCEEDED **
```
(205 total.) Both iOS slices `** BUILD SUCCEEDED **`. No `/core/` change → core
`ctest` unaffected (26/26 stands from handoff 046); no xcframework rebuild needed
(the ladder is set in the bridge source, not the vendored lib).

Tests:
- `ResultsModelTests.testDefaultSelectedIsRecommendedLightest` (was
  `…IsMiddleWhenMultiple`): the lightest tab is `isRecommended`, exactly one is,
  and it is default-selected. Honesty-checked (forcing `isRecommended: false`
  fails it).
- `TopOptKitTests.testMinimizePlasticWithProgress`: updated `rungCount` 3 → 4 to
  track the new ladder length (an intentional behavior change; the test's purpose —
  consistent rungCount + monotone iterations — is unchanged). This is the only
  pre-existing assertion the ladder change touched.

## What I did NOT do
- **Did NOT verify on device** — the RECOMMENDED badge, the default tab selection,
  and that variant fractions now differ per part are maintainer device QA (M7
  standard). Run `./app/scripts/build_core.sh` only if the vendored core is stale
  (it is current; core unchanged this run).
- **Did NOT change the off (single-variant) path** — off still yields one {0.9}
  conservative variant.
- **Did NOT curate/cap** beyond the 4-rung ladder — a strong part shows up to 4
  tabs (the results screen handles variable counts). Trimming to a tighter set is a
  device-QA follow-up if 4 feels like too many.
- **Did NOT tune the ladder to any measured on-device performance** — the values
  are reasonable defaults, adjustable in `reduction_ladder()`.

## Warnings for the next run
- **The ladder lives in `reduction_ladder()` (bridge.cpp).** Tune there; it feeds
  both run paths. Core's own `minimize_plastic` default ({0.7,0.5,0.3}) and its
  tests are untouched.
- **`DECISIONS.md`** still carries the maintainer's uncommitted 2026-07-11
  print-time entry (not part of my commit), as in handoffs 045–047.
- A true continuous lightest-safe search (core bisection) is the natural next
  refinement if grid-locked fractions aren't good enough.

## Blocked
None.
