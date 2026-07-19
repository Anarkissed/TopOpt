# 118 — Density-trajectory extrapolation: STEP-0 go/no-go (skip iterations by extrapolating the fixed-point?)

**Track:** core (exploratory, go/no-go gated). **Territory intended:** `/core/`
only — offline analysis (STEP 0a) + an opt-in in-solver Anderson step (STEP 0b).
**Builds on / references:** 110 (warm-start: injection hygiene + the
different-optimum characterization template + the "both default OFF, byte-identical
when OFF" rule), 113 (the Metal precedent — STEP-0 go/no-go resolved as an honest
Blocked-stop before any code; and the thermal protocol: interleave/cooldown, iters
are ground truth), M6.3 (Heaviside projection + β-continuation).

---

## Outcome: BLOCKED before measurement — a mandatory sequencing prerequisite is not met.

**No ceiling was measured. No solver code was written. No fixtures/benchmarks were
touched. The `keyframe`/`history` primitives already in core are noted, but the
*instrument this task consumes — the capture bundle — does not exist*, so STEP 0a
cannot be run on canonical data, and STEP 0b is gated on STEP 0a.**

This is the Metal precedent applied one stage earlier: 113 could measure its
roofline because its instrument was self-contained throwaway micro-benchmark code;
this task's instrument is a **named, reusable prerequisite dataset** (its snapshots
also feed the eventual ML archive), which the sequencing marks **mandatory AFTER**.
Running the ceiling on ad-hoc, hand-rolled, non-canonical captures would produce
exactly the "inflated win / corrupted ledger" the brief warns against. So the honest
move is to state the block with evidence, spec everything so this executes
mechanically once the instrument lands, and stop.

**No GO/NO-GO for the ML stage is issued here** — the go/no-go is *un-evaluable*
until STEP 0a runs on captured projection-era trajectories. The decision framework
is preserved verbatim below.

---

## Sequencing verification (what was checked, and what was found)

The brief's mandatory sequencing has two gates. Verified against `origin/main`
(= this branch's base, `33da719`):

1. **AFTER the projection task merges — SATISFIED (for the measured path).**
   β-continuation Heaviside projection is merged and is the default on the
   OC/production path: `heaviside_continuation_schedule()` (β doubling 1→32,
   β=64 excluded) is installed by `configure_production_options`
   ([production.cpp](../../core/src/simp/production.cpp):26) whenever
   `projection_supported(updater)`. So OC production runs are already
   "projection-era." (Caveat: `M7.mma-projection` — projection ON the MMA path —
   is still open in the ROADMAP; MMA runs currently skip projection, Option B.
   If the capture bundle captures MMA runs, they will NOT be projection-era until
   that task lands. Capture the OC/production path, or wait on M7.mma-projection.)

2. **AFTER the capture bundle — NOT MET. The instrument does not exist.**
   Searched all handoffs, all git history on every ref, and the tree: there is no
   capture-bundle handoff, no commit, no CLI subcommand or tool, and no committed
   trajectory data (the only "capture" hit is an unrelated PNG asset,
   `docs/handoffs/assets/112_stage_box_capture.png`). What *does* exist is the raw
   primitive the bundle would be built on:
   - `SimpOptions::keyframe` + `keyframe_stride`
     ([simp.hpp](../../core/include/topopt/simp.hpp):476-485) — a read-only
     per-stride callback handed the **analysis density** (filtered + projected —
     the physical_density-consistent field a mesh is extracted from). Today it is
     wired only to the app's playback (it extracts a mesh and *discards* the
     field — `simp.cpp:936-940`, `968-970`); nothing serializes the field.
   - `SimpOptimizeResult::history` (`simp.hpp:535`) — per-iteration
     `{compliance, change, volume_fraction}` **scalars only**, no field.

   STEP 0a's input is "captured trajectories (≥2 fixtures + one 64-scale,
   projection-era runs)." That artifact is absent. STEP 0a cannot start.

Also required and not startable as a consequence: STEP 0b (in-solver Anderson) is
explicitly gated — "only if 0a says the trajectory is extrapolable."

---

## The capture-bundle prerequisite — contract this task needs it to satisfy

So the prerequisite is crisp and this task is not blocked on a vague dependency, the
capture bundle (its own handoff/number, run first, not concurrent with a solver
task) must deliver:

- **A deterministic capture path** — a probe or a `topopt-cli` subcommand — that,
  with `keyframe_stride = 1`, serializes the **analysis density field at every OC
  iteration** to a compact on-disk format, alongside the per-iteration `history`
  (compliance/change/volfrac) and run metadata: grid dims, fixture id, load mode,
  updater, the exact projection schedule, seed, and the terminal field.
- **Coverage:** ≥2 canonical fixtures (suggest the two 110 already uses — the
  L-bracket loadcase and the self-weight block — so 0a lines up with the warm-start
  ledger) **plus one 64-scale run**, **both load modes** (external load /
  self-weight), **projection-era (OC/production path)**. Seeded and reproducible, so
  the *same* snapshots feed STEP 0a and, on a GO, the ML archive — one canonical
  instrument, never ad-hoc re-captures.
- **Determinism preserved:** capture is read-only (the `keyframe` contract already
  guarantees it never mutates `x` or the optimization); a captured run must be
  byte-identical to the same run without capture except for the I/O.

**Feasibility, verified in this environment (de-risks the bundle + 0a):** the
`simp`+`fea`+`voxel` stack this needs is external-dependency-light — `simp.cpp`
compiles here syntax-clean against the headers with **no OpenCascade and no lib3mf**
(those are STEP/3MF import only, in `io/`, not on the optimize path). Eigen headers
are needed by the `fea` reduced/assembly TUs (header-only; not on this box but
trivially vendored). Procedural fixtures — exactly how the existing
`tests/harness/*_probe.cpp` build geometry without any CAD import — avoid OCCT
entirely. **Not characterized:** the wall-clock/compute cost of a 64-scale
projection-era run to convergence with per-iteration full-field capture on this CPU
container (potentially long — budget a background run).

---

## STEP 0a — offline ceiling: methodology (ready to execute once captures exist)

Pure analysis, no solver changes. Goal: **bound the achievable skip before touching
the solver** by asking how predictable the terminal field is from mid-trajectory.

For each captured run (terminal field ρ_T, length N iterations) and for each
checkpoint **k ∈ {25%, 50%, 75%} of N**:

1. **Raw baseline:** error(ρ_k, ρ_T) — how far the field-at-k already is from
   terminal. This is the "do nothing, just stop at k" reference.
2. **Extrapolated candidate:** from a **short trailing window of m = 3–5 consecutive
   captured fields ending at k**, compute
   - **Aitken Δ²** (vector, elementwise on the design set):
     ρ̂ = ρ_k − (Δρ_k)² / (Δ²ρ_k), guarded for near-zero curvature; and
   - **Anderson/AA extrapolation** (depth m): with residuals f_i = ρ_{i+1} − ρ_i,
     solve the constrained least-squares min‖Σ α_i f_{k−i}‖ s.t. Σ α_i = 1, then
     ρ̂ = Σ α_i ρ_{k−i+1}. (Same math STEP 0b would run in-solver.)
   Measure error(ρ̂, ρ_T) for each.
3. **Error metrics (report all three; the shape one is decisive):**
   - relative L2 of the **projected** field over design voxels (continuous);
   - **shape agreement** — fraction of design voxels on the same side of ρ=0.5
     (equivalently IoU of the solid set) — terminal *shape* is what ships;
   - **compliance error** — compliance(ρ̂) vs compliance(ρ_T). This costs **one FEA
     solve** — the very "evaluation" STEP 0b's reject-if-worse guard pays, so its
     cost is measured here too.

**The ceiling, named honestly.** The ceiling is the largest checkpoint fraction at
which extrapolation error ≤ the run's termination tolerance — i.e. "we could have
stopped at k, extrapolated, and certified." Convert **only** as the brief demands:
`iterations_saved = N − k`, `win = iterations_saved × s/iter`, **minus** the
extrapolation + one-FEA-eval overhead. Iterations are ground truth; s/iter is stated
per fixture/scale. No wall-clock headline that isn't backed by an iteration count.

**Extrapolable?** The trajectory is "extrapolable" only if error(ρ̂, ρ_T) is
**materially below** error(ρ_k, ρ_T) at a useful k (extrapolation gets you closer to
terminal than the field you already have). If ρ̂ ≈ ρ_k (extrapolation buys nothing),
the trajectory is not extrapolable → NO-GO at 0a, and the ML idea dies here.

---

## STEP 0b — in-solver Anderson (opt-in, default OFF) — design, gated on 0a = extrapolable

Do NOT build this until 0a says the trajectory is extrapolable. Design, for when it
does:

- **Periodic extrapolation step** on the density fixed-point sequence: every P
  iterations, over a window m = 3–5, form the Anderson jump (the 0a math) in-solver.
- **Full injection hygiene (the warm-start 110 discipline), applied to the jumped
  field before it re-enters the loop:** volume rescale (mean over the design set →
  `volume_fraction`), clamp to [`density_min`, 1], **one** filter pass, and **MMA
  state reset** (asymptotes/history reset — a gradient optimizer must not see the
  jump as a spurious step). Frozen/empty voxels pinned exactly as the uniform start
  pins them.
- **Reject-if-worse guard (mandatory):** after building the jumped field, do one FEA
  solve and compare its objective to the pre-jump objective. **If worse, revert to
  the pre-jump design and continue.** A jump may therefore cost *at most the one
  evaluation*, never progress. **Deterministic by construction** (same field → same
  jump → same accept/reject).
- **THE ONE RULE (per 110):** default **OFF**; with it OFF the run is
  **byte-identical** to today (one flag/null check per iteration, the
  keyframe/progress pattern). Opt-in only.
- **Measurement:** iterations-to-termination for **cold vs warmA vs
  warmA+Anderson**, **both load modes**, under the **113 thermal protocol**
  (interleave the three configs, cooldown between; **iterations are ground truth**,
  not wall-clock). Extend the 110 headline table with a warmA+Anderson column.
- **Different-optimum characterization per the 110 template:** report each config's
  design-change distance and compliance — Anderson may reach a different local
  optimum; that is expected and fine. **Accept gate untouched; certification
  unchanged; Gate-V2 green.**

---

## GO / NO-GO for the ML stage (preserved verbatim; un-evaluable until 0a runs)

Stated with numbers, once 0a + 0b produce them:

- **NO-GO if** 0a shows the trajectory isn't extrapolable, **or** Anderson (0b)
  captures most of the measured 0a ceiling, **or** the residual win is **<10% of
  iterations**. → The ML idea dies here at the cost of one experiment, and the
  handoff says so plainly (the Metal/113 precedent).
- **GO only if** a **material gap** remains between Anderson and the offline ceiling.
  Then **SPEC — do not build** — the learned extrapolator: trained on the run
  archive; the **OOD requirement** made explicit (arbitrary STEP files are not the
  training distribution — a bad jump must cost **only iterations**, and the spec must
  show how that's verified, i.e. the **same reject-if-worse FEA guard** as 0b bounds
  a bad learned jump to one evaluation); with **Anderson as the baseline the model
  must beat**. The maintainer decides whether to fund it.

---

## For the next agent (how to unblock this)

1. Land the **capture bundle** (its own handoff/number) to the contract above:
   projection-era, OC path, ≥2 fixtures + one 64-scale, both load modes,
   per-iteration analysis-density fields serialized deterministically. Not
   concurrent with any solver task.
2. Then re-open this task and execute **STEP 0a** mechanically per the methodology
   here; name the ceiling in iterations and convert honestly.
3. Only on 0a = extrapolable, build **STEP 0b** (opt-in, default OFF, byte-identical
   when OFF, reject-if-worse) and fill the cold/warmA/warmA+Anderson table.
4. Then — and only then — issue the GO/NO-GO with numbers. On NO-GO, say so plainly
   and let the ML idea die at the cost of one experiment.
