# Constrained smoothing with re-certification — the feature (2026-07-26)

Status: **BUILT and device-real.** Maintainer-approved after the PR 196
BLOCKED-STOP resolved (the `analyze_fixed_design` receipt engine it needs shipped
there). This adds the SMOOTH half — shrink-compensated Taubin with **hard
constraints** — and routes every smoothed mesh back through re-certification, so
the numbers shown always describe the exported geometry.

Evidence: `evidence/2026-07-26-constrained-smooth-ui/` (device-real CLI transcript,
per-strength receipt table, frozen-vertex bit-identity proof, byte-identity
proofs, the CG-convergence note).

---

## TL;DR

The existing pipeline already removes gross terracing (the 2× tricubic export
resample). This feature's value is the **receipt** and the **hard constraints**,
exactly as PR 196's appetite check established — so that is what it sells:

- **Frozen means frozen.** Vertices on keep-clear bores / anchor pads / protected
  faces are held **bit-identical** — not damped — via exact geometric predicates
  (PR 190's `ClearanceGeometry`), which survive re-meshing where a face-id map
  cannot (the exported mesh carries no face ids).
- **The melt is structurally impossible.** The §7 V3 min-feature detector is now a
  **hard constraint**: any smoothing step that would thin a region below printable
  width (2 voxels) is refused.
- **The receipt.** Every smoothed mesh is re-voxelized and re-certified through
  `analyze_fixed_design` (one FEA solve → stress / mass / margins / gate). The
  pre-smoothing numbers **never** appear beside smoothed geometry; the new numbers
  carry a `smoothed · re-analyzed` provenance tag and disclose the quantization gap.

---

## What was built

**1. The smoother — `constrained_taubin_smooth`** (`core/include/topopt/smooth.hpp`,
`core/src/mesh/smooth.cpp`). Pure geometry on a welded triangle mesh; no solve, no
optimizer, no ML.

- **Shrink-compensated Taubin λ|μ.** Alternating umbrella-Laplacian passes: a
  shrinking pass (λ = 0.33) and an inflating pass (μ = −λ/(1−λ·k_PB) ≈ −0.341,
  k_PB = 0.1). Per-pair transfer over the spectrum k ∈ [0,2] is
  f(k) = (1−λk)(1−μk), with **f(0) = 1** (rigid + uniform modes fixed — no bulk
  shrink) and **f(k_PB) = 1** (the pass-band). Unlike pure Laplacian
  (f = 1−λk < 1, monotone shrink to a point), volume is preserved.
- **Strength control.** One knob ∈ (0,1] → `pairs = round(strength · 20)`.
  strength 0 = 0 pairs = identity (byte-identical).
- **Stated volume-drift bound** (`taubin_volume_drift_bound`). Volume is a
  low-frequency functional; over the pass band f ∈ [1, A] with A the pass-band
  peak (A ≳ 1 by a few 1e-4), so after `pairs` pairs no volume-carrying mode is
  scaled beyond A^pairs. The bound is **A^pairs − 1**. Measured drift is reported
  against it and stays under it (evidence below).
- **Frozen mask.** Vertices within `freeze_tol_mm` (default 0.75 voxel) of ANY
  freeze region are excluded from every update — their coordinates are the input
  coordinates, bit for bit. Frozen NEIGHBOURS still contribute their fixed
  positions, which is what keeps a bore circular.
- **Min-feature constraint.** Each λ|μ pair is re-voxelized onto the reference
  grid; a pair that raises `min_feature_violations` above the input baseline (or
  breaks voxelization) is reverted and smoothing stops. Discriminating, not
  blanket: a fat body smooths freely.
- **Deterministic:** fixed vertex order, uniform weights, no RNG.

**2. The freeze predicate — `point_in_clearance_region`** (`clearance.hpp` /
`clearance.cpp`). Point-vs-region test (Bolt swept cylinder / Face bounded slab,
inflated outward by `tol`), sharing the exact inside-test the clearance rasterizer
uses — so a frozen vertex and a `FrozenVoid` voxel agree on the same geometry. The
rasterizer was refactored to call the shared test; `test_clearance` (28/28) proves
that refactor is **byte-identical**.

**3. Wiring — `analyze_job` + CLI** (`core/src/cli/run_job.cpp`, `main.cpp`;
`SmoothRequest` in `job.hpp`). `topopt-cli analyze <job> --mesh M --smooth S`:
resolves freeze predicates from the model's B-rep fixture faces (cylindrical →
Bolt bore, planar → Face pad) via `resolve_clearance_from_face`, smooths `M` under
those + the min-feature constraint, writes `<M>_smoothed.stl`, then re-certifies
THAT mesh (the existing `voxelize_onto_grid` + `analyze_fixed_design` path). The
provenance record (`analysis.json`) gains `smoothed:true`, strength, applied/
requested pairs, frozen-vertex count, **both** mass figures, volume drift + bound,
min-feature baseline/after/limited, and the quantization footnote — emitted ONLY
when smoothing ran, so the analyse-only bytes are unchanged. `--no-min-feature`
disables the constraint (for the S2 contrast).

**4. Bridge seam — `smooth_and_recertify_selfweight`** (`TopOptBridge`). The seam a
smoothing UI calls after the strength picker: smooth under app-supplied freeze
regions (`BridgeFreezeRegions`, the same `ManualClearanceGeometry` PR 190 threads
through the schema) + the mount slab, write the smoothed STL, re-certify via
`analyze_selfweight` (single source of truth). `AnalyzeResult` gains the smoothing
provenance fields the results screen renders. **Syntax-checked against the core
headers** (`-fsyntax-only`, clean); no Swift caller yet — the UI is deferred exactly
as PR 196's `analyze_selfweight` was, but the seam and its provenance fields are the
one source of truth for the tag when it lands.

### The UI provenance tag (spec — deferred, per the PR-196 pattern)

The results screen renders, whenever `AnalyzeResult.smoothed`:

- A pill `smoothed · re-analyzed` next to the geometry. Its info popover discloses:
  *"Re-analysis runs on the voxelization of the smoothed mesh at grid resolution,
  so analyzed and printed geometry differ by up to ~½ voxel. Margins/voxel mass
  describe the voxel proxy; mesh mass is the surface-enclosed volume."*
- The **new** margin/stress/mass — never a cached pre-smoothing value (structurally
  impossible: smoothing routes through re-cert, which recomputes everything).
- Both mass figures (`voxel_mass_grams`, `mesh_mass_grams`), the frozen-vertex count,
  and — if `min_feature_limited` — a "strength capped to keep min feature width" note.
- If the strength picker's re-cert throws (see the CG note), the UI must show the
  failure, NOT the pre-smoothing numbers.

---

## The bars

Device-real unless noted. Unit bars: `core/build/test_smooth` (50 checks, 0 fail).

**S1 — FROZEN MEANS FROZEN.** ✅ Bit-identical (doubles, `memcmp`) at every
strength — unit (synthetic sphere/Face, both predicate kinds) AND device-real:
`frozen_bit_identity.txt` smooths the real `variant_030.stl`, freezes a 228-vertex
bore, and reports `frozen_changed=0` at strengths 0.1–1.0 while 4116 free vertices
move. The CLI reports `frozen 104/4344` for the fixture-bore predicate, constant
across strengths (geometry-only).

**S2 — NO THINNING BELOW THE FLOOR.** ✅ (unit — the constraint needs a clean
baseline the marching-cubes round trip can't give). An explicit grid-aligned
3-voxel slab (baseline 0 violations): one unconstrained pair thins it (0 → 144);
the constraint refuses every thinning pair and holds the mesh at 0. Discrimination:
the fat sphere applies all 20 requested pairs. Note the honest finding — on the
REAL tendrilly variants, smoothing *reduces* min-feature (961 → 639) because it
removes terracing; the constraint's job is to stop the *local* pinch, which the
explicit-slab test isolates.

**S3 — THE RECEIPT IS REAL (verdict can drop).** ❌ **UNPROVEN — owed a maintainer
traction fixture.** Under self-weight the demo margins are 2000–9800× and *rise*
with smoothing (lighter part → less self-load): `variant_030` no-smooth margin 7777
→ smoothed@0.25 margin 9772. A verdict-LOWERING demo needs a fixed EXTERNAL
(traction) load where geometry changes but load does not. Fixtures are
maintainer-generated; do not author one. **What would prove it:** a job with a
`loads` block (anchor + a few-hundred-N traction) sized so the solid margin sits
near the 1.5 stop; smoothing a load-bearing strut then drops the re-run margin
below 1.5 and the gate flips to REJECTED on screen. (The declared-loadcase analyze
path itself is also still owed — `analyze_job` is self-weight only today.)

**S4 — VOLUME DRIFT vs BOUND.** ✅ Reported per strength, within bound
(`receipt_table.txt`): sphere unit 0.018/0.050/0.110/0.178/0.251% at
strength 0.1–1.0 vs bound 0.056/…/0.565%. Device-real `variant_030`:
0.137% (bound 0.141%) @0.25, 0.366% (bound 0.565%) @1.0. Always shrink-compensated
and under the stated envelope.

**S5 — DETERMINISM.** ✅ `byte_identity.txt`: `--smooth 1.00` twice → smoothed STL
and `analysis_report.json` byte-identical (`cmp` clean).

**S6 — OFF IS BYTE-IDENTICAL.** ✅ Smoothing gated behind `smooth.enabled`;
`run_job`'s export path unchanged. Analyse-without-`--smooth` provenance is
deterministic run-to-run and carries **zero** smoothing keys (the PR-196 17-line
template exactly).

**S7 — DEVICE-REAL.** ✅ Everything above ran through `core/build/topopt-cli`
built from this worktree on the L-bracket demo (res 48, PLA), plus a device-real
S1 program on the real variant STL.

---

## Honest limits (stated, not worked around)

- **S3 needs a traction fixture** (above). Self-weight cannot lower a verdict.
- **Re-cert solver convergence** (`cg_convergence_note.txt`): `variant_030 @ 0.50`
  fails the production multigrid-CG (`did not reach tolerance within
  max_iterations`) — deterministic, isolated to that one sparse/ill-conditioned
  re-voxelized field (0.25 and 1.0 on it, and 0.50 on the fatter 050/070, all
  succeed). The re-cert **throws rather than emitting a false receipt** — the
  honesty rule holds at the solver boundary. Owed follow-up: a one-shot re-analysis
  can afford a more robust solver policy (higher CG cap / Jacobi fallback for very
  sparse designs) without the byte-identity concern that blocks touching the
  optimizer's cert solver. Left to the maintainer (it changes
  `analyze_fixed_design`'s solver policy).
- **Freeze set in the self-weight CLI path = fixture faces** (the L-bracket's two
  Ø5 bores). Protected-face and manual-clearance freezing use the IDENTICAL
  predicate (`point_in_clearance_region`, proven on Bolt + Face + manual geometry
  in `test_smooth`) and are wired in the bridge seam; they reach the CLI the moment
  the declared-loadcase analyze path lands (it carries the `clearances` /
  `face_protection` blocks). No new mechanism needed.
- **Bridge seam has no Swift caller** — syntax-checked only, lands with the UI.

---

## Files

Core: `include/topopt/smooth.hpp` (new), `src/mesh/smooth.cpp` (new);
`include/topopt/clearance.hpp` + `src/voxel/clearance.cpp` (freeze predicate,
shared inside-test refactor); `include/topopt/job.hpp` + `src/cli/run_job.cpp`
(`SmoothRequest`, smoothing in `analyze_job`, provenance); `src/cli/main.cpp`
(`--smooth` / `--no-min-feature`); `CMakeLists.txt` (smooth.cpp + `test_smooth`);
`tests/unit/test_smooth.cpp` (new, 50 checks).
App: `TopOptBridge.hpp` + `bridge.cpp` (`AnalyzeResult` smoothing fields,
`BridgeFreezeRegions`, `smooth_and_recertify_selfweight`).

Regression: `test_analyze_fixed_design` 22/0, `test_clearance` 28/28 (byte-identity
of the rasterizer refactor), `test_voxel` 38/38, `test_job` 106/106, `test_report`,
`test_export`, `test_fields`, `test_resample` all pass.
