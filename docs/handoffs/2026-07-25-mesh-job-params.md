# 2026-07-25 — Mesh jobs dropped the user's parameters (job.json serialization)

**Track:** app bridge (`app/TopOptKit/Sources/TopOptFlows`). **Territory:**
`RemoteRunner.swift` (`buildJobJSON`), `RunModel.swift` (`bridgeRunner`, the
`RunRequest` doc comments), new `JobJSONEquivalenceTests.swift`. **No core change,
no worker change** — both were already source-agnostic; only the Swift serializer
discriminated.

**Gates:**
* `swift test --filter JobJSONEquivalenceTests` — 3/3 (the field-equivalence bar +
  the anti-skeleton guard + the no-load-case parity). NO worker needed.
* `swift test --filter RunModelTests` — 47/47 (the local runner path unbroken).
* End-to-end: the l-bracket **as STL** and **as STEP**, same logical job (96³, 40 %
  infill, real anchors + load), run to a report through `topopt-cli`. run_info
  proves `mode=minimize_plastic`, `load_source=loadcase`, `infill_percent=40`,
  `resolution=96` — see `evidence/2026-07-25-mesh-job-params/`.

---

## 0. What was actually wrong

The iPad's `makeRunRequest()` (`AppModel.swift`) packs every parameter identically
for a STEP or a mesh part — anchors, load groups + forces, infill, resolution,
design box, clearances, protections. The core's `run_job` (the CLI + LAN worker
driver) consumes a `loads` block identically for STEP and mesh — the mesh-optimize
work (`2026-07-24-mesh-optimize-path`) made `import_part_file_resolved` + the
`tag_*_face` forwarders honor pseudo-face ids exactly as B-rep ids. The worker
copies job.json through verbatim.

The **one** place that discriminated was `RemoteRunner.buildJobJSON()`. It gated the
ENTIRE `loads` block behind `request.isStepModel`:

```swift
if request.isStepModel {
    var loads = [ ...minimize_plastic, build_dir, anchor_face_ids, groups,
                  infill_percent, clearances, face_protections... ]
    job["loads"] = loads
} else {
    job["loads"] = ["build_dir": [0, 0, 1]]   // ← mesh: a SKELETON
}
```

`isStepModel` is `false` for `.stl`/`.3mf`, so a mesh RunRequest serialized to a
skeleton job — `{"loads": {"build_dir": [0,0,1]}}` — dropping the anchors, load
groups, infill and (via the CLI's default) letting resolution look absent. With no
anchors + no groups the CLI's `build_production_loadcase` had no load case to solve,
so the run degraded to the worst case: self-weight, 100 % infill, cold. run_info
still echoed the requested `mode=minimize_plastic` (it is `job.mode` verbatim) while
the actual solve was self-weight — **that contradiction is the dropped-loads
signature**, and at 128³ it OOM-killed (rc=-9) after 2 iters.

`design_box` / `keep_outs` survived on the mesh path only because they are emitted
ABOVE the `isStepModel` gate.

## 1. The fix

`buildJobJSON` now builds the full `loads` block for EVERY model source — no
`isStepModel` gate, no `else` skeleton. A mesh RunRequest already carries its
anchors/loads/clearances/protections as segmentation **pseudo-face ids**, which ride
the exact same `anchor_face_ids` / `groups[].face_ids` / `clearances[].face_id` /
`face_protections` fields a STEP part's B-rep ids do (the face-id contract is shared,
handoff 134). So the same serializer emits a mesh job.json field-equivalent to the
STEP one — only `model` and the face-id *provenance* differ.

The local on-device twin had the same latent bug: `RunModel.bridgeRunner` routed a
mesh to the self-weight entry (`minimizePlastic(stlPath:)`) even when the user had
declared a load case, because it too keyed off `isStepModel` alone. The bridge's
`run_minimize_plastic_loadcase` already imports through `import_part_file_resolved`
(handoff 134 made it OCCT-free + mesh-capable), so a mesh's pseudo-face anchors drive
the same builder. `bridgeRunner` now takes the load-case path whenever the request
carries a load case (`!anchorFaceIDs.isEmpty || !loadGroups.isEmpty`) — for STEP OR
mesh — and only a part with NO declared load case falls to the self-weight ladder.

`isStepModel` is kept ONLY to preserve STEP's always-load-case routing; its doc and
the now-stale "Consumed only on the STEP … path" field comments on `RunRequest` were
corrected to say STEP-and-mesh.

## 2. Field-equivalence, asserted

`JobJSONEquivalenceTests` builds ONE logical `RunRequest` twice — once pointing at
`/tmp/part.step`, once at `/tmp/part.stl` — with identical anchors `[3,7]`, two load
groups with forces, `infill=40`, `resolution=96`, a design box + keep-out, two
clearances, two protections. It calls `buildJobJSON()` on each (exposed `internal`
for the test, so it needs no worker) and asserts:

* **field-equivalence:** with `model` set aside, the two job dicts are `NSDictionary`-
  equal (the whole nested structure — loads, groups, clearances, design_box).
* **anti-skeleton:** the mesh job actually carries `anchor_face_ids=[3,7]`,
  `infill_percent=40`, both `groups`, both `clearances`, `face_protections`, and
  `resolution=96` — none of the fields the bug dropped.
* **no-load-case parity:** even a request with no load case emits the same well-formed
  `loads` (minimize_plastic + build_dir) for mesh and STEP, never a skeleton.

## 3. End-to-end: the l-bracket as STL vs STEP

`evidence/2026-07-25-mesh-job-params/` holds two jobs, `job.step.json` and
`job.mesh.json`, built from the same logical request (96³, PLA, anchors `[8,9]` — the
two r=2.5 screw holes — a −250 N load on face 2, infill 40). Their canonical diff
(`job_diff.txt`) is a SINGLE line: the model path. The L-bracket STEP and its STL
export segment to the identical 10-face layout (same kinds, radii, centroids — the
STL is the STEP's own tessellation), so the same face ids select the same geometry;
the ids' provenance (B-rep vs pseudo-face) is the only difference.

Both run through `topopt-cli` to a report. The result (`EQUIVALENCE.txt`):

```
console provenance (the ONLY intended run-output difference):
  model: l-bracket.stl  (10 pseudo faces, 2 fixture faces matched)
  model: l-bracket.step (10 B-rep faces, 2 fixture faces matched)

report.json   mesh vs step:  BYTE-IDENTICAL
run_info.json mesh vs step:  IDENTICAL (only created_wall_ms differs)

run_info (both):  mode=minimize_plastic  load_source=loadcase
                  resolution=96  infill_percent=40
peak memory:      mesh 1.28 GB   step 1.26 GB   (no OOM)
```

Because the STL is the STEP's own tessellation, voxelization is identical and the
whole optimization is identical — the mesh and STEP `report.json` come out
**byte-for-byte equal**, and `run_info.json` is identical but for the wall-clock
stamp. Both evaluated vf 0.68 and rejected it on the same honest gate (236 sub-2-voxel
min-feature regions → effective margin 0.48 < the 1.5 required); a concentrated point
load on an L-bracket yields a genuinely thin optimum at this reduction — the point is
the mesh behaves EXACTLY as the STEP does, not that a variant is accepted.

`run_info.mode` equals the requested `minimize_plastic` and `load_source=loadcase`
for the mesh run — never the silent self-weight fallback the bug produced — and
`infill_percent=40`, `resolution=96` are echoed. No OOM (the bug OOM-killed at 128³;
this 96³ mesh job peaks at 1.28 GB).

## 4. Files

**New:**
* `app/TopOptKit/Tests/TopOptFlowsTests/JobJSONEquivalenceTests.swift` — the gate.
* `docs/handoffs/evidence/2026-07-25-mesh-job-params/` — the two jobs, their diff,
  both run_info.json + report.json, the run logs, the l-bracket .step/.stl.

**Modified:**
* `app/TopOptKit/Sources/TopOptFlows/RemoteRunner.swift` — `buildJobJSON` emits the
  full loads block for every source; `buildJobJSON` is now `internal` (test seam).
* `app/TopOptKit/Sources/TopOptFlows/RunModel.swift` — `bridgeRunner` takes the
  load-case path for a mesh with a declared load case; `RunRequest` field docs +
  `isStepModel` doc corrected.

## 5. Scope honesty

* **3MF** rides the identical serializer (dispatch is by the model extension the app
  sets); it was not run here (no lib3mf-imported .3mf in this loop), same standing
  caveat as handoffs 134 / mesh-optimize.
* The evidence run selects anchors/load by **raw pseudo-face id**, the form the app's
  tap produces. The geometric-selector path (`{"cylindrical", r}`) is unchanged and
  still matches a mesh's fitted radius under the same 1e-6 tolerance.
