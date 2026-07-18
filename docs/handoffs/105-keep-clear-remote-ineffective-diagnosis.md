# 105 — "Keep clear" ineffective on a remote run: DIAGNOSIS (read-only)

**Status:** Diagnosis only. No code changed. The fix is written up as a PROPOSED
follow-up task at the end. Evidence is artifacts-first (the Mac worker's job
workdir), then a headless CLI reproduction with the exact job, then code.

Investigates: `l-bracket-large`, Fine·128³ **design box**, four "bolt" clearances,
launched **remotely** from a **stale iPad app** (predates PR 127 affix model,
possibly PR 125 liveness rewrite; its clearance serialization is PR-123-era).
Symptom: keep-clear appears **ineffective** — tendrils reach near-bore /
plate-contact regions the user expected to be protected.

## TL;DR — VERDICT: **APPLIED** (not app-never-sent, not core-dropped)

The clearances **were serialized** and **reached core**; core **applied them
correctly**. The keep-clear is not being ignored — as specified, it protects
almost nothing in the design volume, so the tendrils are **geometrically legal**.
Three compounding facts, in order of impact:

1. **HEADLINE (needs reconciliation with you): the wire values are
   `margin = 5 mm`, `axial = 5 mm` — NOT the `15 / 15` reportedly set in the UI.**
   The job.json the worker actually ran carries `concentric_margin_mm: 5`,
   `axial_clearance_mm: 5` on every clearance. At those distances the protected
   column rises only **~3 mm above the mounting plate** (see §2), which is far too
   shallow to keep a socket/driver path clear — this alone explains "ineffective".
   Whether the stale app **serialized the wrong number** (an app bug — the real
   headline if so) or the run simply used `5/5` cannot be proven from artifacts;
   it needs the stale build or a fresh capture. **Please confirm what the UI
   showed.**

2. **The design box floor sits exactly on top of the fastener foot**, so the
   applied bolt clearance barely pokes into the design volume. `design_box.min.z
   = 25.0998`; the foot-top plane (face 0) is at `z = 25.0`. The bore shaft spans
   `z ∈ [0, 23]`; with `axial = 5` the protected band is `z ∈ [-5, 28]`. Only
   `z ∈ [25.1, 28]` — **~2.9 mm** — overlaps the design volume where the optimizer
   can actually place material. Everything below is frozen part/foot (protected by
   precedence, not by the clearance). Net protected keep-out in the design space:
   a 2.9 mm-tall, 7.5 mm-radius puck over each hole. Tendrils landing at `z > 28`
   or radius `> 7.5 mm` are **legal**.

3. **2 of the 4 declared clearances were silent no-ops** — faces 10 & 11 are the
   **counterbores** (`StepSurfaceKind::Other`), not cylinders, so core's Bolt
   rasterizer built an empty region and logged the misleading reason
   `SKIP=region-outside-grid`. This is **redundant** with the shaft clearance here
   (the shaft band already covers the counterbore z-range) so it is **not** the
   operative cause — but it is a real contract gap and a **regression risk on
   current main** (§4).

Classification is unambiguous on the artifact evidence: the clearance block is
present in job.json (**not** APP-NEVER-SENT) and core parsed + rasterized it
(**not** CORE-DROPPED). It is **APPLIED**; the region is just tiny.

## The run

Worker job dir: `~/.topopt-worker/6cbeb150242a464e/` (the **only** remote job on
disk carrying a `clearances` block; `model.step` is byte-length identical to the
other `l-bracket-large.step` jobs). Three laddered variant STLs
(`variant_038/052/068.stl`, Jul 18 07:04–13:05) — a long 128³ design-box run.
No `report.json` and no saved stdout: the worker holds the CLI log **in memory
only** (`job.events`), so handoff-100's per-clearance lines for the original run
are not persisted. I reproduced them (§1b).

### 1a. job.json — the `clearances` block (quoted verbatim)

```json
"clearances": [
  { "concentric_margin_mm": 5, "kind": "bolt", "axial_clearance_mm": 5, "face_id": 9 },
  { "face_id": 11, "kind": "bolt", "axial_clearance_mm": 5, "concentric_margin_mm": 5 },
  { "concentric_margin_mm": 5, "face_id": 8, "kind": "bolt", "axial_clearance_mm": 5 },
  { "axial_clearance_mm": 5, "face_id": 10, "concentric_margin_mm": 5, "kind": "bolt" }
]
```

with `"resolution": 128`, `mode: minimize_plastic`, `anchor_face_ids:
[5,9,11,8,10]`, and
`design_box.min = [-100.0905, -50.2490, 25.0998]`,
`design_box.max = [ 83.4111,  50.1895, 150.4594]`.

So: **clearances present → NOT app-never-sent.** And the numbers are **5/5**, not
15/15.

### 1b. Reproduced CLI log (exact job, worker's own binary `core/build/topopt-cli`)

```
[loadcase] clearance face=9  kind=bolt voxels_frozen=348 status=ok
[loadcase] clearance face=11 kind=bolt voxels_frozen=0   SKIP=region-outside-grid
[loadcase] clearance face=8  kind=bolt voxels_frozen=348 status=ok
[loadcase] clearance face=10 kind=bolt voxels_frozen=0   SKIP=region-outside-grid
```

Faces 8 & 9 applied (348 voxels each); faces 10 & 11 froze nothing. **Core did
not drop the block — it applied it.**

## 2. Legality check (measured, not assumed)

`StepModel` face geometry, dumped from the exact `model.step`:

| face | kind | radius | axis | x-centre | z-span | what it is |
|------|------|--------|------|----------|--------|------------|
| 8  | **Cylinder** | 2.5 | (0,0,1) | −56.25 | 0–23 | bolt **shaft** hole 1 |
| 10 | **Other** | — | — | −56 (±4.5) | **23–25** | **counterbore** of hole 1 |
| 9  | **Cylinder** | 2.5 | (0,0,1) | +31.25 | 0–23 | bolt **shaft** hole 2 |
| 11 | **Other** | — | — | +31 (±4.5) | **23–25** | **counterbore** of hole 2 |

Applied bolt clearance on face 8/9 at `margin=5, axial=5`:
* radial keep-out radius = `bore_r + margin = 2.5 + 5 = 7.5 mm`
* axial band = `shaft_span ± axial = [0,23] ± 5 = z ∈ [-5, 28]`

The design volume is `z ≥ 25.0998` (box floor) sitting on the `z = 25.0` foot
top. **Protected design-space column = z ∈ [25.1, 28] ≈ 2.9 mm tall, r ≤ 7.5 mm.**
Below `z = 25` the cylinder overlaps solid foot, which the precedence rule keeps
(never voids part material) — correct, but it is not "keep-out", it is "keep-in".

**Conclusion:** a tendril growing in the design box and touching the plate at
`radius > 7.5 mm` from a bore axis, or arriving above `z ≈ 28`, is **inside no
protected region** — it is geometrically legal. The optimizer obeyed the
clearance; the clearance was ~3 mm tall. For comparison, at `axial = 15` the band
would reach `z = 38` (≈13 mm into the design volume) and at `margin = 15` the
radius would be 17.5 mm — that is the difference between "ineffective" and
"effective" on this geometry, which is why reconciling the 5-vs-15 question (§ TL;DR
item 1) matters most.

### Controlled experiment proving faces 10/11 are geometry no-ops, not out-of-grid

Re-ran setup with `margin=axial=200 mm`. Faces 10 & 11 STILL froze 0
(`region_voxels==0`) — impossible for a valid cylinder anywhere near the part, so
`valid=false` in `mask_clearance_region` (face is not a `Cylinder`). Face 8
reported `voxels_frozen=0 status=ok` (region intersected the grid but every voxel
was already frozen by face 9's huge region processed first — the shared-mask
counts only *newly* frozen voxels; not a geometry failure). This also confirms the
**design-box remap offset is correct**: face 8's `region_voxels > 0` means the
`(oi,oj,ok)` part→solved mapping and part-precedence guard placed the part exactly
where handoff 100 intended.

## 3. Why "region-outside-grid" is a misleading label (core, minor)

`core/src/voxel/clearance.cpp`: `region_in_grid = (region_voxels > 0)`. A Bolt on
a non-cylinder face returns early with `region_voxels == 0`, so
`core/src/cli/loadcase.cpp:log_clearance` prints `SKIP=region-outside-grid` even
though the true reason is **"face is not a cylinder"**. The counterbore case is
indistinguishable in the log from a genuinely-out-of-domain region. This hid the
root cause and should be split into two reasons.

## 4. Regression risk on CURRENT main (the important forward-looking part)

The stale app is off the hook for causing THIS run (clearances were sent). But the
underlying face-selection gap is **still latent on current main**:

* **Serialization is fine.** `RemoteRunner.swift:477-484` serializes
  `request.clearances` (raw `face_id`, `kind`, margin/axial) for the remote path —
  a remote design-box run is **not** app-never-sent on today's code.
* **The counterbore still gets tagged as a bolt.** `ProjectModel.clearanceSpecs()`
  emits `kind: .bolt` for every face where `FaceTopology.isCurved(f)` is true
  (`ProjectModel.swift:186-192`). `isCurved` is a **normal-fan heuristic** (>5°
  between triangle normals) — a counterbore/countersink/chamfer fans and reads
  **curved**, and `FaceTopology.loop(fromFace:)` walks the connected curved run so
  a hole tap grabs **shaft + counterbore** together (exactly the {8,10}/{9,11}
  grouping this job shows). Those counterbore specs serialize with raw `face_id`
  and **still silently no-op in core** (`StepSurfaceKind::Other`). The app's own
  `ClearanceGeometry.bolt(...)` returns `.degenerate` for them (no red volume in
  the 3D preview) — honest, but easy to miss.
* **Net:** the next run from current main reproduces the same 2-of-4 silent no-op.
  It is masked here only because the shaft clearance's axial band happens to cover
  the counterbore. On a part where the counterbore needs independent protection,
  it would lose coverage outright.

The clearance path is the **one place** that trusts a raw `face_id` index instead
of the geometric match `resolve_selectors` enforces everywhere else
(`run_job.cpp:67-88` matches fixture/anchor/load faces by surface property, never
raw index — "match by surface property, never raw index"). Clearances
(`run_job.cpp:194-210`) dereference `model.faces[jc.face_id]` directly.

## PROPOSED follow-up task (implementation, NOT done here)

Headline first, then hardening:

1. **Reconcile the 5-vs-15 discrepancy with the user; if the app under-serialized,
   fix the stale-app clearance serialization** (or confirm current main sends the
   UI value). This is the operative cause of "ineffective" and must be settled
   before anything else. Verify current main sends the on-screen margin/axial for a
   remote design-box run (round-trip a job.json capture).
2. **Reconsider the default distances for the design-box case.** When the design
   box floor coincides with the fastener-foot top, `axial = 2·bore_r` gives a ~3 mm
   protected column. Either raise the default axial for anchored bores, or key it
   off the box-floor-to-face gap so the protected column has a meaningful height in
   the design volume. Surface the *effective in-design-volume* keep-out height in
   the UI, not just the raw mm.
3. **Stop tagging non-cylinder faces as bolt clearances.** In
   `clearanceSpecs()`/`FaceTopology`, gate `kind:.bolt` on a true cylinder (or drop
   counterbore/chamfer faces from the hole loop for clearance purposes) so a bore
   emits exactly one bolt clearance on its shaft. Mirror the core rule: a Bolt
   clearance must resolve to a `Cylinder` face.
4. **Fix the misleading core log** (`clearance.cpp` / `loadcase.cpp`): distinguish
   `SKIP=not-a-cylinder` (valid==false) from `SKIP=region-outside-grid`
   (region_voxels==0 but geometry valid), and surface `voxels_frozen==0 status=ok`
   (fully absorbed by part precedence) so a front-end can warn honestly.
5. **(Optional, robustness) resolve clearance faces geometrically**, like every
   other face selector, instead of trusting a raw cross-process `face_id` index.

### Reproduction (read-only, for the next engineer)

```sh
cp ~/.topopt-worker/6cbeb150242a464e/{job.json,model.step} /tmp/repro/
core/build/topopt-cli run /tmp/repro/job.json --out /tmp/repro/out   # watch [loadcase] clearance lines, then Ctrl-C
```

Face-kind dump: a ~15-line program linking `core/build/libtopopt.a` +
`import_step_file` prints each face's `StepSurfaceKind`/radius/axis (used for the
§2 table).
