# analyze_fixed_design under a declared load case

## The problem

PR 200 disclosed that the analyze path (`analyze_job`, `core/src/cli/run_job.cpp`)
was **self-weight only** — a declared `"loads"` block was rejected outright:

```cpp
if (job.loads.present)
  throw JobError("analyze: jobs with a \"loads\" block are not yet supported ...");
```

That blocks **bar S3** of the smoothing work — *proving re-certification can LOWER
a margin*. Under self-weight a lighter part is always safer, so **no geometry change
can move a verdict downward**. The maintainer is authoring a traction fixture;
without a load-case analyze path that fixture cannot be re-analyzed, so the fixture
alone does not close S3.

`analyze_fixed_design` **is** the code production uses (PR 196:
`minimize_plastic`'s per-rung certification calls it), so this had to be wired
*without* perturbing the self-weight path.

## What shipped

`analyze_job` now branches on `job.loads.present`:

- **loadcase** — builds the design's grid + Dirichlet BCs + external tractions
  through the **same seam the optimizer uses**: a new shared
  `production_loadcase_from_job(job, model)` maps the job's `"loads"` block onto a
  `ProductionLoadCase`, then `build_production_loadcase` resolves anchors → clamped
  BCs (or the min-x fallback) and each force group → a distributed traction. The
  fixed design (the model solid, or a `--mesh` substitute voxelized onto the same
  grid) is then certified under the **external** load via one `analyze_fixed_design`
  solve — never self-weight.
- **self-weight** — the pre-existing path, byte-for-byte unchanged.

The job **parser was already complete** (`core/src/cli/job.cpp` switches to
loadcase mode on a `"loads"` key and rejects `fixture_faces`/`gravity`/`ladder`/
`margin_stop`); this task reused it exactly and added **no second schema**. The
`JobDescription → ProductionLoadCase` mapping that used to live inline in
`run_job`'s optimize path was **extracted** into `production_loadcase_from_job` and
is now called from **both** the optimize path and the analyze path — one mapping,
no drift.

### The margin the loadcase gate uses

The `"loads"` schema rejects a `margin_stop` key, so in loadcase mode
`job.margin_stop` is unset. The gate uses `options.margin_stop`, which
`build_production_loadcase` leaves at the **production default `1.5`** — the same
threshold the optimizer's loadcase ladder gates on. `analyze_job` now reports the
margin it actually **used** (`AnalyzeJobResult::margin_required`), so the CLI and
`analysis.json` never falsely show `0`. In self-weight mode
`options.margin_stop == job.margin_stop`, so the reported bytes are identical.

### L5 — never a silent self-weight fallback

Two failure modes, both **loud** (the PR-178 param-drop bug was exactly a silent
degradation):

- **A face that does not exist** (raw id out of range, or a geometric selector that
  matches nothing) → `resolve_selectors` / `tag_step_face` throw; `analyze_job`
  surfaces a `JobError` naming the out-of-range face.
- **Every group zero-force / sub-voxel** → `build_production_loadcase` returns an
  empty external set with `require_external_loads` armed; `analyze_job` **refuses**
  with a diagnostic that explicitly names the self-weight fallback it is *not*
  taking. (The optimizer catches this inside `minimize_plastic`; analyze never runs
  the optimizer, so it must guard itself.)

## The bars

Test `core/tests/validation/test_loadcase_analyze.cpp` (58 checks, 0 failures).
L1–L4 run on a synthetic in-code `StepModel` (a solid beam) through the real
`build_production_loadcase → minimize_plastic → analyze_fixed_design` seam; the
integration + L5-loud cases drive the actual `analyze_job` on the demo
`l-bracket.step`.

- **L1 — self-weight is byte-identical.** A self-weight rung's OWN certification
  reproduces bit-for-bit through `analyze_fixed_design` (`==`, not tolerance). The
  pre-existing `test_analyze_fixed_design` and the parity tests still pass, and the
  self-weight `analysis.json` is structurally unchanged (no `load_source` key;
  `margin_required` still `job.margin_stop`) — see `evidence/selfweight_analysis.json`.
- **L2 — reproduce a rung's OWN numbers under a loadcase.** Run a loadcase
  optimization, analyze that variant's converged density, assert von Mises, stress
  tensor, displacement, mass, support, every margin term, min-feature count, printed
  fraction and verdict with `==`. Passes; the peak stress is a real positive number
  (the bar binds on a meaningful value).
- **L3 — the gate can REJECT.** A `margin_stop` above the analyzed margin comes back
  REJECTED, one below ACCEPTS, and raising it changes **only** the verdict (the
  stress field and reported margin are bit-identical across the two). At CLI level:
  the **same 41.44 g solid l-bracket** is ACCEPTED under self-weight (margin **2551**)
  but REJECTED under a declared load (margin **0.008**) — the fact S3 needs. See
  `evidence/{selfweight,loadcase}_analysis.json`.
- **L4 — deterministic re-run.** The loadcase analysis re-run is bit-identical
  (pure, stateless).
- **L5 — loud, never self-weight.** `evidence/L5_out_of_range.txt` (a nonexistent
  load face throws, naming it) and `evidence/L5_zero_force_refuse.txt` (an empty
  external set refuses, naming the self-weight fallback it declines).

## Files

- `core/src/cli/run_job.cpp` — `production_loadcase_from_job` (extracted, shared);
  `analyze_job` loadcase branch + L5 guards; `analysis.json` gains a loadcase
  receipt block (loadcase mode only, so self-weight bytes are unchanged);
  `margin_required` sourced from `options.margin_stop`.
- `core/include/topopt/job.hpp` — `AnalyzeJobResult::margin_required`; doc updates.
- `core/src/cli/main.cpp` — the `analyze` command prints the load case + the margin
  the gate actually used.
- `core/tests/validation/test_loadcase_analyze.cpp` + `core/CMakeLists.txt`
  (`loadcase_analyze`).

## Scope boundaries (deliberate)

- **Design box.** The analyze path certifies a *fixed* design, so a `design_box`
  (which *grows* material during optimization) does not apply; the loadcase analyze
  runs on the part grid, matching the self-weight path (which already ignores
  `design_box`). A loadcase job with a box still analyzes the part-as-drawn.
- **`--smooth` under a loadcase** derives its freeze regions from the resolved
  **anchor** faces (`result.fixture_face_ids`), not the load faces. `--mesh` (the
  general substitute-geometry mechanism S3 ultimately uses) is fully supported in
  loadcase mode.
