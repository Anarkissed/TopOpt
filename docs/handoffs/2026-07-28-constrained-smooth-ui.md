# Constrained smoothing with re-certification — the feature (2026-07-28)

Status: **the RECEIPT is real and device-real; the smoothing UI is built and
unit-tested.** Follows the two earlier passes that were scoped down: the
`analyze_fixed_design` receipt engine (PR 196) and the constrained Taubin smoother
+ hard constraints (PR 200). Both proved S1 (frozen means frozen) and S2 (min-feature
as a wall) on device, but S3 — *the receipt can LOWER a verdict* — was blocked: their
analyze path was self-weight only, and under self-weight a lighter part is always
safer, so no geometry edit can move a verdict down.

This pass removes that block and delivers the differentiated value: **the RECEIPT and
the HARD CONSTRAINTS**, not the cosmetic look (PR 200's appetite check already found
the existing 2× export resample removes the gross terracing). It wires the declared
load case through `analyze_job`, proves the honest weakening in code + on device,
adds the load-case bridge seam, and builds the smoothing UI with the honesty rule and
the S7 handling.

Evidence: `evidence/2026-07-28-constrained-smooth-ui/` (device-real CLI receipt +
transcript, the receipt table, the analysis.json provenance files, the smoothed
STLs).

---

## TL;DR — the honest picture

Constrained Taubin smoothing barely moves a *smooth* prismatic part (a smooth
surface has nothing to denoise — its surface shifts by microns, so its re-voxelized
margin does not change). What smoothing DOES remove is **high-frequency convex
material**: print terracing, marching-cubes stair-steps, sharp ribs. On a
**load-bearing** rib that is a real weakening — and the receipt reports it:

- **The receipt is real (S3).** A synthetic cog bar (star cross-section = load-bearing
  ribs) in axial tension, sized so the solid margin sits at **1.635** (just above the
  1.5 stop). Gentle smoothing (1–2 pairs) holds the margin; rounding the ribs off
  (4–20 pairs) shrinks the tension section, peak stress climbs 33.6 → 52 MPa, and the
  re-analysed margin drops through 1.5 to **~1.1 — the gate flips to REJECTED**. The
  numbers shown are always the SMOOTHED part's.
- **The hard constraint is the safety.** With min-feature enforcement ON (the default),
  the SAME full-strength smoothing is REFUSED (0/20 pairs applied, `min_feature_limited`),
  because rounding the ribs would thin them below the printable floor — so the part
  stays at 1.635 ACCEPTED. The melt is structurally impossible, and the receipt says
  the strength was capped.
- **The honesty rule is structural, not cosmetic.** Smoothing routes through
  re-certification; the UI (`SmoothingModel`) exposes numbers ONLY from a certified
  re-cert — there is no channel to a cached optimizer number.

---

## What was built

### Core

1. **Declared load case in `analyze_job`** (`core/src/cli/run_job.cpp`). The analyze
   path threw on a `"loads"` block; it now branches through the SHARED
   `build_production_loadcase` (anchors + tractions) exactly as the optimizer does, so
   a re-certification runs under the IDENTICAL grid / BCs / traction the run used.
   Self-weight stays byte-identical. A new `production_loadcase_from_job(job, model)`
   helper is the ONE job→ProductionLoadCase mapping, called by both the optimize and
   analyze paths (extracted from the optimize path, behaviour-preserving — the loadcase
   parity tests still pass). `AnalyzeJobResult::margin_required` reports the gate
   actually used (production 1.5 for a loadcase, whose schema has no `margin_stop`) so
   the CLI / provenance never show a false 0. Load faces are frozen during smoothing
   and their voxels retagged after re-voxelization, so the traction stays attached.

2. **The S3 proof** — `core/tests/validation/test_smooth_recert_loadcase.cpp` (30
   checks). Builds the cog specimen IN CODE (a welded `StepModel`, no OCCT), drives it
   through `build_production_loadcase`, and certifies through `analyze_fixed_design`:
   the margin falls monotonically through the gate (ACCEPTED→REJECTED), min-feature ON
   caps it, drift is reported against the Taubin bound (S4), the same smoothing twice
   is byte-identical (S5), and a 1-iteration CG cap yields `non_convergent`/`accepted=false`
   with no false receipt (S7). It opt-in-dumps the specimen STL (`TOPOPT_S3_EVIDENCE_DIR`)
   so the CLI re-certifies the identical part.

3. **The load-case bridge seams** (`app/TopOptKit/Sources/TopOptBridge/`) —
   `analyze_loadcase` and `smooth_and_recertify_loadcase`, the load-case twins of the
   self-weight seams, built on `build_production_loadcase` + `analyze_fixed_design`.
   `AnalyzeResult` gains `non_convergent` (the S7 boundary the UI reads). The
   `BridgeLoadCase → ProductionLoadCase` mapping is extracted into ONE
   `production_loadcase_from_bridge` shared by the optimize and re-cert paths
   (no drifting second copy — the `knockdown_spec_for` lesson). Compiles clean against
   the core (`-fsyntax-only`) and through `build_core.sh` (macOS + iOS slices).

### App (the smoothing UI)

4. **`TopOptKit.smoothAndRecertifyLoadCase`** (`Sources/TopOptKit/Smoothing.swift`) —
   the Swift wrapper: builds the `BridgeLoadCase` + `BridgeFreezeRegions`, calls the
   seam, maps to the Swift value type `SmoothRecertifyResult` (every field is the
   smoothed part's; `nonConvergent` is distinct from an honest `accepted == false`).

5. **`SmoothingModel`** (`Sources/TopOptFlows/SmoothingModel.swift`) — the state +
   HONESTY LOGIC. It exposes a re-cert receipt ONLY from `.certified`; `.working`,
   `.couldNotCertify` (S7) and `.failed` expose NO numbers, so a stale margin can
   never sit beside a smoothed shape. Carries the copy (the pill text, the quantization
   disclosure, the drift line, the S7 message) and the `live(context:)` factory that
   runs the blocking re-cert off the main actor. **11 headless tests**
   (`SmoothingModelTests`) lock the honesty rule, the S7 branch, the drift disclosure,
   and the export gating.

6. **`SmoothingPanel`** (`Sources/TopOptFlows/SmoothingPanel.swift`) + a data-gated
   **"Smooth" chip** in `ResultsScreen.vizRail`. The panel renders the strength slider,
   the `Smoothed · re-analyzed` pill, an info popover with the quantization footnote,
   the re-analysed verdict + receipt rows (margin, peak stress, both masses, frozen
   count, pairs applied/requested, drift line, min-feature-capped note), the S7 / failure
   cards, and an Export-smoothed-STL button. `ResultsScreen` takes an optional
   `smoothing: SmoothingModel?` (default nil → the chip hides, like every other viz chip).

---

## The bars

Device-real unless noted. Core unit: `test_smooth_recert_loadcase` (30 checks, 0
fail), `test_analyze_fixed_design` (22/0), full loadcase parity suite green. App unit:
`SmoothingModelTests` (11/0).

- **S3 — THE RECEIPT IS REAL.** ✅ **The headline.** Device-real via `topopt-cli` on
  the cog specimen: solid margin **1.635 ACCEPTED** → smoothed **1.122 REJECTED** at
  strength 0.20 (`receipt_table.txt`, `cli_receipt_transcript.txt`). A larger strength
  drives it to ~1.07. min-feature ON refuses it (0/20 pairs, stays 1.635 ACCEPTED).
  The unit test proves the same in code with a monotone crossing.
- **S4 — VOLUME DRIFT vs BOUND.** ✅ Reported per strength in the transcript +
  `analysis.json`. On this rib-rounding specimen the measured drift (~1–5%) EXCEEDS the
  Taubin small-perturbation bound (~0.03–0.57%) — the honest signal that real material
  was removed, surfaced (not hidden) in the receipt and the drift line. The bound
  holding for gentle DENOISING is proven separately on the sphere/variant in
  `test_smooth` (PR 200).
- **S5 — DETERMINISM.** ✅ `--smooth 0.40` twice → smoothed STL + `analysis_report.json`
  + `fields.bin` byte-identical (`cmp` clean); the unit test asserts the same on the
  smoothed vertices + the re-analysed numbers.
- **S6 — OFF IS BYTE-IDENTICAL.** ✅ Analyse-without-smooth provenance carries ZERO
  smoothing keys (`out_solid/analysis.json`); the self-weight analyze regression
  (`test_analyze_fixed_design` 22/0) is unchanged by the loadcase refactor, and the
  loadcase parity tests confirm the shared-helper extraction is behaviour-preserving.
- **S7 — THE KNOWN DEFECT IS HANDLED, NOT INHERITED.** ✅ PR 200 found `variant_030 @
  0.50` fails the production multigrid-CG during re-cert (deterministic, one sparse
  field). `analyze_fixed_design` reports that as `non_convergent = true` /
  `accepted = false` — never a false receipt (proven by the S7 check's 1-iteration CG
  cap). **The UI decision:** the bridge surfaces `non_convergent`; `SmoothingModel`
  maps it to `.couldNotCertify`, which shows *"Couldn't re-certify at strength X — try
  a lower strength."* with NO numbers, distinct from an honest "weakened, rejected".
  PR 214's non-convergence-as-rung-rejection covers the LADDER, not the analyze path,
  so this is genuinely new. (A future option: a one-shot re-analysis could afford a
  more robust solver policy — higher CG cap / Jacobi fallback — for very sparse fields;
  left to the maintainer as it changes `analyze_fixed_design`'s solver policy.)
- **S8 — DEVICE-REAL.** ✅ Every receipt row ran through the compiled `topopt-cli`;
  the whole app stack builds through `build_core.sh` + `xcodebuild` and the honesty
  logic is unit-tested on macOS.

---

## Honest limits (stated, not worked around)

- **The weakening needs high-frequency load-bearing geometry.** The physics: shrink-
  compensated Taubin moves a smooth compact section by microns, so a clean prismatic
  part cannot register a margin change at grid resolution — and to flip a margin sized
  at, say, 1.7 you must move ~12% of the section, far more than the ~0.5% drift bound.
  The specimen therefore has explicit ribs (like terracing), and the flip case runs
  with min-feature enforcement OFF; with it ON the constraint refuses the rounding.
  This is not a workaround — it is the true shape of the feature: gentle smoothing of a
  reasonably smooth part barely changes the margin; aggressive smoothing of ribs weakens
  it, and the receipt + the constraint are exactly what make that safe and visible.
- **The final call-site wiring is a device-QA step.** The UI stack is complete,
  compiling and unit-tested, and `ResultsScreen` accepts a `SmoothingModel`; the
  `WorkspacePlaceholder` call site still passes `nil` (chip hidden). Wiring it needs
  the live pieces — the part path, the run's anchors/load groups (from `ForceModel` /
  the selection), the materials/rules paths + resolution, and the selected variant's
  mesh written to a temp STL — assembled into a `SmoothingModel.Context` and passed as
  `SmoothingModel.live(context:)`. That plumbing renders on device only, so it is left
  as the one documented wiring step, matching how PR 196/200 shipped their seams. No
  new mechanism is needed.
- **Freeze set on the CLI loadcase path = anchor + load + declared clearance faces.**
  Protected-face / manual-clearance freezing uses the IDENTICAL predicate and is wired
  in the bridge seam (`freeze` + the auto anchor/load freeze); it reaches the CLI when
  a job declares those blocks.

---

## Files

Core: `src/cli/run_job.cpp` (loadcase branch in `analyze_job`,
`production_loadcase_from_job`, `margin_required`), `include/topopt/job.hpp`
(`AnalyzeJobResult::margin_required`, doc), `src/cli/main.cpp` (print the real
`margin_required`), `tests/validation/test_smooth_recert_loadcase.cpp` (new),
`CMakeLists.txt`.
App: `TopOptBridge/include/TopOptBridge.hpp` + `TopOptBridge/bridge.cpp`
(`analyze_loadcase`, `smooth_and_recertify_loadcase`, `production_loadcase_from_bridge`,
`AnalyzeResult::non_convergent`); `TopOptKit/Smoothing.swift` (new);
`TopOptFlows/SmoothingModel.swift` + `SmoothingPanel.swift` (new); `ResultsScreen.swift`
(the `smoothing:` param + the Smooth chip); `Tests/TopOptFlowsTests/SmoothingModelTests.swift`
(new).

Regression: core loadcase parity (`test_production_parity`, `test_face_protection_parity`,
`test_clearance_parity`, `test_loadcase_small_face`, `test_load_retention_connectivity`,
`test_anchor_integrity`, `test_design_domain`), `test_job` (119), `test_smooth` (50),
`test_analyze_fixed_design` (22) all pass. App `TopOptFlowsTests` pass except the
pre-existing 3MF/lib3mf-provisioning tests (`AppModelTests` — this worktree's macOS
slice is 3MF-free; unrelated to this change).
