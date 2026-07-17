# 093 — LAN compute offload (run on a desktop, drive from the iPad)

**Spans tracks.** Touches `core/src/cli/`, the sanctioned bridge
(`app/TopOptKit/Sources/TopOptBridge/bridge.cpp`), the app runner
(`app/TopOptKit/Sources/TopOptFlows/`), and a new `tools/topopt-worker/`. Do NOT
run concurrently with anything touching `core/src/cli`, `bridge.cpp`, or
`RunModel`. No ROADMAP box is checked.

Goal: *Fine + design box* (~5.4M voxels) does not fit the iPad's memory budget.
Run the optimizer on a desktop (e.g. a Mac Mini) and drive it from the iPad over
the LAN. **STEP 0 was the hard gate** — the CLI and the bridge had DIVERGED and
produced DIFFERENT parts, so a worker running the CLI would have silently returned
a different part. That is fixed and proven first; everything else builds on it.

---

## STEP 0 — the divergence audit, and the seam that closes it

### What had diverged (measured on the pre-093 tree)

Everything since ~074 landed in the BRIDGE ONLY. `topopt_cli` ran a DIFFERENT
optimizer configuration than the app:

| setting | what the bridge did | what the CLI did (before) | effect if a worker ran the CLI |
|---|---|---|---|
| `simp.solver` | `MultigridCG_Matfree` | `JacobiCG` (SimpOptions default) | assembles the fine K → the multi-GB OOM the whole feature exists to avoid |
| Galerkin block cache | `fea_set_matfree_galerkin_block_cache(true)` (global) | off | slower coarse-operator build (bit-identical result) |
| `min_feature_mm` / projection | `enable_projection` → 2.5 mm + Heaviside (OC) | unset (0) | **different geometry** — thinner members, different design |
| reduction ladder | `{0.68,0.52,0.38,0.26}` | job.json's `ladder` | different rung set → different variants |
| anchor pad | `mask_step_face` FrozenSolid depth 3 | none | the anchor boss (diagnosis 064) carved thin → different, weaker part |
| design box / keep-outs, external loads, infill, build dir | full load-case geometry | **not expressible at all** | the CLI could not even run a design-box load case |

The CLI literally could not express the runs the app does (no design box, no
declared loads), and where it overlapped it ran the OOM-prone assembled solver
with different geometry. A desktop worker built on it was a correctness trap.

### The seam — ONE place both call (no copy-paste)

Two new core units are the single source of truth. The bridge and the CLI both
call them; drift is now structurally impossible (not a convention — the same
function).

1. **`core/include/topopt/production.hpp` — `configure_production_options()`**
   sets the product solver config: `MultigridCG_Matfree`, `min_feature_mm = 2.5`,
   the Heaviside schedule when the updater supports it (OC only — MMA, the
   production default, skips it), and enables the process-global Galerkin cache.
   `production_reduction_ladder()` is the canonical `{0.68,0.52,0.38,0.26}` both
   sides reference (no copied literal).
   - **The Galerkin cache is a GLOBAL atomic, not a SimpOptions field** (handoff
     091). It is handled EXPLICITLY: `configure_production_options` calls
     `fea_set_matfree_galerkin_block_cache(true)`, so "configured a production
     run" and "the cache is on" can never disagree between the two front-ends.
     It is bit-identical, so it changes no design.

2. **`core/include/topopt/loadcase.hpp` — `build_production_loadcase()`**
   is the load-case geometry (anchors→Fixture, per-group tractions, BCs, the
   FrozenSolid anchor pad, the design box + keep-outs, gravity, ladder) that used
   to live inline in `bridge.cpp`. It was EXTRACTED VERBATIM (a move, not a
   rewrite) into `core/src/cli/loadcase.cpp`, taking a front-end-neutral
   `ProductionLoadCase`. The bridge maps its `BridgeLoadCase` to it; the CLI maps
   its job.json to it. Both then call `minimize_plastic` with identical
   `(grid, bcs, options)`.

**Why this seam:** the divergence was two things — the *product config* (solver /
projection / cache) and the *load-case geometry* (pad / box / loads). Factoring
both means neither front-end constructs optimizer inputs on its own; they only
*map their input format* to the shared types. `configure_production_options` is
deliberately NOT a `MinimizePlasticOptions` default and is NOT applied inside
`minimize_plastic`: the locked reference runs (Gate-V2, the property suite, every
core test) use the library defaults and stay byte-identical. The production config
is opt-in at the production entry points only.

`keyframe_count` is deliberately left to each front-end (app: 12 for playback;
CLI: 0 — it exports meshes, not playback). It does not affect the design, so
CLI==app parity holds regardless.

### The proof — strong, and executed

Two independent proofs, both run on this branch:

1. **Committed gate `test_production_parity`** (`core/tests/validation/`,
   OCCT+Eigen): builds a real load case on the demo l-bracket and asserts
   (a) `configure_production_options` sets exactly the production fields + enables
   the Galerkin global; (b) `build_production_loadcase` is deterministic;
   (c) `minimize_plastic` on it is **bit-identical run to run** — same rung count,
   same accept/reject, bit-identical `physical_density`, bit-identical margins;
   (d) the load case is assembled (external loads + anchor pad) and the design box
   expands the solved grid. **Passes.**

2. **Real bridge-vs-CLI harness** (evidence, not committed — links the REAL
   `bridge.cpp` and the REAL `run_job` on Linux): runs
   `topoptbridge::run_minimize_plastic_loadcase` AND `topopt::run_job` on the same
   STEP + same load case + same resolution and compares the DESIGNS. Result:

   ```
   cylindrical anchor face ids: 8 9 (resolution 16)
   bridge: 4 variants, accepted_count=4
   cli:    4 evaluated, 4 accepted
     rung 0: vf=0.679925 margin=7384.307230 accepted=1  MATCH
     rung 1: vf=0.519581 margin=7157.078161 accepted=1  MATCH
     rung 2: vf=0.379920 margin=6739.020977 accepted=1  MATCH
     rung 3: vf=0.259041 margin=6367.856306 accepted=1  MATCH
   PARITY HARNESS: bridge == CLI, all fields identical
   ```

   Bit-identical achieved VF, worst-case margin, AND the full per-voxel von Mises
   field, per rung. The two front-ends produce the same part.

### The one rule (STEP 0d)

- **Gate-V2 GREEN and byte-identical:** it uses `SimpOptions`/`MinimizePlastic
  Options` defaults and still does — the shared setup is not applied to it, not
  reachable from it, and (being partly bit-identical) could not change it anyway.
- **Full core suite GREEN:** `ctest` → **45/45 passed** (includes `gate_v2`,
  `cli_demo`, `production_parity`, all design-box gates). `cli_demo`'s behavioural
  invariants (3 accepted rungs, achieved VF within 0.01 of request, settings band,
  cross-process determinism) still hold with the production config applied.

Environment note: this Linux host has no CMake config for OCCT; it was made to
build with Ubuntu's `libocct-*` 7.6 by symlinking the two 7.7-era toolkit names
the committed `CMakeLists` links (`libTKDESTEP.so`→`libTKSTEP`, `libTKDE.so`→
`libTKXSBase`). That is a local-env shim only — **no committed file was changed
for it** and CI's vcpkg OCCT is unaffected.

---

## The earliest real value: run Fine+box on the Mac Mini via `topopt-cli` TODAY

After STEP 0, the maintainer can run Fine+box headless, before any network work.
The CLI now supports a design box (both self-weight and load-case modes), raw
B-rep face ids (the app's selection form) as well as geometric selectors, and STEP input (STL import is planned but not yet wired — run_job currently imports STEP only).

**Command:**
```sh
topopt-cli run job.json --out ./out
```

**Worked `job.json` — a 128³-scale design-box run (self-weight):**
```json
{
  "model": "bracket.step",
  "material": "PLA",
  "mode": "minimize_plastic",
  "resolution": 128,
  "fixture_faces": [ { "kind": "cylindrical", "radius_mm": 2.5 } ],
  "gravity": { "direction": [0, 0, -1], "magnitude_mm_s2": 9810.0 },
  "ladder": [0.68, 0.52, 0.38, 0.26],
  "margin_stop": 1.5,
  "design_box": { "min": [-30, -20, 0], "max": [30, 20, 72] },
  "output": { "report": "report.json", "mesh_format": "stl", "mesh_prefix": "variant" }
}
```
- `ladder` uses the production values so the CLI walks the same rungs the app
  recommends. `design_box` (mm, model frame) is the grow region — larger than the
  part where you want material added.
- **Load-case form** (anchors + forces instead of self-weight) — replace
  `fixture_faces`/`gravity`/`ladder`/`margin_stop` with a `loads` block:
  ```json
  "loads": {
    "anchor_face_ids": [8, 9],
    "groups": [ { "face_ids": [3], "force": [0, 0, -250] } ],
    "build_dir": [0, 0, 1]
  }
  ```
  `anchor_face_ids`/`face_ids` are raw B-rep ids (what the app selects); or use
  `"anchors": [ {"kind":"cylindrical","radius_mm":2.5} ]` and `"faces":[...]` for
  hand-authored geometric selection. Loadcase mode uses the production ladder +
  anchor pad automatically.

The CLI streams progress while it runs:
```
PROGRESS rung=0 rungs=4 iter=7
VARIANT vf=0.68 achieved=0.6799 margin=7384.3 accepted=1 mesh=.../variant_068.stl
```
and writes each accepted variant's mesh AS IT COMPLETES (not batched at the end).

### Memory (why the desktop, and why this is not solver work)

Per handoffs 090/091/092: the peak is the **iteration-0 uniform-grey FP64 build
transient** — the first solve of every rung builds the fine operator over a
uniform density-0.5 field before the design sharpens — and it **recurs every
rung**. Matrix-free does not touch it (it is the build, not the solve), which is
exactly why no solver change moves it and the offload is the only path. 090/092
measured **~1.53 GB at 96×80×96**. That is above what the iPad reliably keeps
free, so Fine + design box does not run on device; on a desktop the cap is a
non-issue. (I did not re-measure this — it is already established; the earlier
Fine-scale run here is not a clean data point and is not relied on.)

The STEP-0 CLI now applies the SAME matrix-free multigrid + Galerkin config the
app does (see the parity harness), so the desktop run has the identical memory
profile the app would have had — it just runs where the RAM is.

---

## STEP 1 — the worker (`tools/topopt-worker/`)

A dependency-light (**Python stdlib only**) HTTP server wrapping `topopt-cli`.
System-agnostic (Linux/macOS/Windows, no `pip install`). See its README for the
run command and full API. Endpoints: `POST /jobs` (multipart STEP + job.json),
`GET /jobs/{id}/events` (SSE), `GET /jobs/{id}/result` (zip), `GET
/jobs/{id}/files/{name}` (one artifact), `DELETE /jobs/{id}` (cancel),
`GET /health` (version + build fingerprint). **No auth beyond binding to the LAN**
— single user, documented.

**Progress is REAL, not fabricated.** The CLI now emits `PROGRESS`/`VARIANT`
checkpoint lines (`run_job` `emit_progress`, wired in `main.cpp`); the worker
parses them into typed SSE events. Verified end-to-end here: submit → live
`progress` per iteration → `variant` per accepted rung (mesh already written) →
`done` with the artifact list; `/result` zip, `/files/*`, and `DELETE` cancel all
work.

---

## STEP 2 — the iPad side (`RemoteRunner.swift`)

`RunModel.remoteRunner(config:)` sits BESIDE `bridgeRunner` (unchanged, still the
default) and satisfies the same `RunModel.Runner` contract, so the existing
progress readout (PR 107) and streamed-variant path (PR 109) work against remote
events unchanged. Opt-in via a `RemoteRunnerConfig(host:port:expectedFingerprint:)`
(typed IP for v1; mDNS/Bonjour is a documented later nicety, cross-platform via
Avahi). It health-checks the worker, POSTs the job (mapping the `RunRequest` to
the CLI job schema with RAW face ids), streams SSE, drives `progress`/`onVariant`,
cancels via `DELETE`, and assembles the outcome from the report + meshes.

**Not verified on this host — no Xcode/Swift on Linux.** It is written against the
real TopOptKit types and the worker's real protocol and must be compiled + run on
device before it ships. Two concrete gaps are documented in the file and below.

---

## STEP 3 — the honest problems

**(a) Payload.** The bridge's in-memory `OptimizeResult` carries, per variant,
mesh + `vonMises` + `stressTensor` (6×) + `displacement` (3×) + 12 keyframe
meshes. Computed at 128³ (2.10M voxels):

| field | per variant |
|---|---|
| von Mises | 8.4 MB |
| stress tensor (6×) | 50.3 MB |
| displacement (3×) | 25.8 MB |
| variant mesh (~300k tris) | 14.4 MB |
| **12 keyframes** | **172.8 MB** |
| **per variant** | **~272 MB** → **×4 ≈ 1.09 GB** |
| per variant, no keyframes | ~99 MB → ×4 ≈ 396 MB |

Untenable to ship whole. Keyframes are PLAYBACK data — **dropping them for remote
is honest** (lossy/absent is fine there) and removes 63% of the payload. The
remaining fields (von Mises / stress / displacement) are what the readouts use, so
they should be compressed, not dropped — they are zero off the printed set and
smooth on it, so they gzip extremely well.
**Current worker reality:** the CLI writes only meshes + `report.json`, so the
worker path transfers **~58 MB total** for 4 variants — it sidesteps the payload
problem by OMITTING the fields. That is the honest tradeoff below.

**(b) Streaming.** Variants stream, they do not batch. The CLI writes each accepted
variant's mesh the moment it completes and prints a `VARIANT` line; the worker
emits an SSE `variant` event whose mesh the app fetches immediately via
`/files/{mesh}`. Verified: the `variant_060.stl` file exists on disk before rung 1
starts. The maintainer sees rungs appear one by one, not after an hour.

**(c) Failure.**
- *Worker unreachable:* the app's health check / POST fails fast → surfaced as a
  run failure (no silent hang).
- *Worker dies mid-run / stream drops (iPad sleeps):* the SSE events are
  append-only and replayed from the start on reconnect, and `/result` works after
  completion, so **a completed run is never lost to a dropped connection**. The
  `RemoteRun` delegate turns an unexpected stream end into an explicit error
  rather than hanging.
- *Disk full / bad job / solver error:* `topopt-cli` exits non-zero; the worker
  emits an `error` event carrying the CLI's stderr; the app throws it.
- *Cancel:* `DELETE /jobs/{id}` kills the subprocess; the progress callback
  returning `false` triggers it, exactly like a local cancel.

**(d) Version skew — the correctness one.** `GET /health` exposes the core build
fingerprint (`topopt-cli --version` → the core git commit, injected by CMake).
`RemoteRunner` compares it to the app's own `expectedFingerprint` and **REFUSES to
run on a mismatch** — a worker whose core differs silently produces a different
part. This is STEP 0's divergence in a new costume, closed the same way: don't let
two cores that differ run as if they agree.

---

## What is done, and what is not

**Done + verified on this branch (Linux, OCCT+Eigen):**
- STEP 0 seam (`configure_production_options` + `build_production_loadcase`);
  bridge + CLI both call it; committed `test_production_parity` + a real
  bridge==CLI byte-identical harness; Gate-V2 + full suite 45/45 green.
- CLI: design box + keep-outs, load-case mode (raw ids + selectors), streaming
  progress + progressive mesh export, `--version` fingerprint.
- Worker: full API, real progress, smoke-tested end-to-end.

**Written but NOT verified here (no Xcode):**
- `RemoteRunner.swift` — compiles-in-principle against the real types; must be
  built + driven on device.

**Known gaps / follow-ups (scoped, not landed):**
- **Result fidelity over the wire.** The CLI emits meshes + `report.json`, not the
  per-voxel `vonMises`/`displacement`/`stressTensor` fields or `massGrams`. So a
  remote variant renders and shows margins/settings/orientation, but the stress
  overlay, flex animation, mass readout and playback are empty. Closing this needs
  the CLI to serialise a full result artifact (then apply the payload plan in 3a:
  drop keyframes, gzip the fields). This is the clean next task.
- The CLI's geometric selector vocabulary is cylindrical-only; raw face ids cover
  the app's needs, but hand-authored non-cylindrical selection would want more
  kinds.
- mDNS/Bonjour discovery (typed host works today).

No ROADMAP box checked.
