# The app's core jobs on his three projects (for PR #361, the Flexible core track)

This folder answers point 2 of the reviewer's ruling of 2026-10-24 17:46. It holds the exact **scene job** and **run job(s)** that the app (#362) builds for his three live projects. This was a test-only run: no source or test file was edited, and no harness file was added.

## Recorded at

- **Commit:** `c772d2a3` on `claude/flexible-screens`. The code is the merge `03ad2df5` (the solver cure, Option 1). `c772d2a3` only adds `solver_cure_merge/merge_runs.txt`.
- **Core:** the app's vendored core has fingerprint `03ad2df57977`. Each run printed `core 03ad2df57977`.
- **Build:** the test binary is the one at `/tmp/r7x20b-build`, built at M at 14:57:59. The `swift build --build-tests` at 15:35:59 did nothing ("Build complete! (0.64 secs.)").
- **Runs:** 2026-10-24, 15:36:23 to 15:37:59. Load average was about 3 to 4.5.

## How the files were recorded

The recorder is the existing `FlexibleAngledGoldenRecorder/testRecord8EverySendsJob` (`app/TopOptKit/Tests/TopOptFlowsTests/FlexibleAngledGoldenRecorder.swift`).

The recorder only takes a fixed list of send sets. One of them, `his_0004`, restores `FlexibleHisProject.dir` through `FlexiblePressFixtures.his0004`, and that directory honours the existing env var `HIS_PROJECT_DIR`. So for each project:

- `HIS_PROJECT_DIR` points the `his_0004` slot at that project's folder;
- `FLEX_AP_GOLDEN_DIR` sends the output to a scratch folder;
- the slot's four or three files are copied here byte for byte, with the recorder's file names.

The slot restores the project exactly as the app does:

1. `FlexibleHisProject.restore(dir, asSaved: true)` copies the folder into a temp store and runs `AppModel.open`. No [Lattice under it] taps are added; there are none for these folder names in any case.
2. It builds a `FlexibleStageModel` with the repo's catalogue and opens the scene.
3. It waits until every loaded stack is built or refused and no design is in flight.
4. It records the sends. When `FlexibleCoreHold` holds the project, there is one send per hold fix (`runJobJSON(resting:)` with that fix's resting faces). Otherwise there is one `direct` send. Then it records `sceneJob()`.

All three projects have face-prisms, so the recorder did not use ruling 6's pre-ruling door. It prints `no face-prism — opened as before ruling 6` when it does, and that line did not appear for these projects.

> **File names:** the `his_0004_` prefix is the recorder's slot name. These files are NOT his 0004 project. Each folder below is the project its files came from.

## Inputs

These files were not changed by the runs: the md5s were taken before and after and are identical.

| project | file | md5 |
|---|---|---|
| 10-21 pad | `round7/batch_u21/his_live_1021_pad/project.json` | `b1e0f885799ee6d2dcf0e697ea985729` |
| | `round7/batch_u21/his_live_1021_pad/model.stl` | `d574940d5bd417d1110dba0f68e190dc` |
| 10-20 pad | `round7/batch_u1/his_live_1020/project.json` | `d076d95179a9306f8e30c5a7ddab4a7a` |
| | `round7/batch_u1/his_live_1020/model.stl` | `d574940d5bd417d1110dba0f68e190dc` |
| 10-21 l-bracket | `round7/batch_u21/his_live_1021_lbracket/project.json` | `87a1f65090b290854000ef1c28177f55` |
| | `round7/batch_u21/his_live_1021_lbracket/model.step` | `d411b79475d2e07851c79a8f0d408594` |

## What each file is

There are three kinds of file:

- **Scene job:** the job the Flexible page opens core's scene with. It declares every region a tap can pick: the part's faces and all the Flexible sections. Core frames the stacks, designs and fields from it, and it is never sent as a run.
- **Run job (send n):** what the Export step sends to core for send n.
- **Sends file:** the index. It has one line per send: the button's title, the resting set passed to `runJobJSON(resting:)`, and the file holding that send's job.

How a send is built (`FlexibleStageModel.runJobJSON(resting:)`):

- Each loaded face named in the resting set is made a resting entry.
- A press (edge pair) with a region in the set is left out of that job, since a press is never a resting entry.

All jobs are `mode: analyze` and use material `varioshore_tpu`. The paths are tokenised: `$ROOT` stands for the temp store, so the model is `$ROOT/<project id>/model.stl|step`. The files contain no other path.

### `his_live_1021_pad/`: the 10-21 pad

Pad 100 x 100 x 20, id A1000001-…-0003, resolution 96. Face 5 is a Stamp, Face 3 is Curves, and the edge group is Edge 12 + Edge 9. The model loaded 2 keys and core refused no stack. Core hold offers 2 sends.

| file | bytes | md5 | what |
|---|---|---|---|
| `his_0004_scene_job.json` | 11717 | `806e5d56f56fd6adbf0b95fa3d8d7080` | Scene job. It declares 18 regions (faces 0–5, plus 2000020–22, 24, 26, 47, 50 and 60–64); its `flexible.faces` lists 5 as loaded. |
| `his_0004_send1_run_job.json` | 67151 | `187cda6cd2aaef8fae749f9b8e064122` | Send 1, "Send Group 1 only, Face 3 resting". Face 5 is loaded. Faces 3, 2000021 and 2000020 rest. The edge presses are left out. It declares 12 regions (0–5, 2000020, 2000021 and 2000061–64). |
| `his_0004_send2_run_job.json` | 16471 | `e48cc02bd908407b50e89f48dc234599` | Send 2, "Send Group 2 only". The edge presses [2000063, 2000064] and [2000061, 2000062] are loaded. Faces 5, 3, 2000021 and 2000020 rest. It declares the same 12 regions. |
| `his_0004_sends.txt` | 287 | `9fb5df68b0a92b78997bbd29dcd3db5e` | The index of the two sends. |

### `his_live_1020/`: the 10-20 pad

Same part and id as the 10-21 pad, resolution 96. Face 5 and Face 3 are both Stamps, and the edge group is Edge 12 + Edge 9. The model loaded 2 keys and core refused no stack. Core hold offers 2 sends.

| file | bytes | md5 | what |
|---|---|---|---|
| `his_0004_scene_job.json` | 11497 | `ffab73d9bf0107af45f87cc4f50d8c0e` | Scene job. It declares the same 18 regions; its `flexible.faces` lists 5 as loaded. |
| `his_0004_send1_run_job.json` | 67039 | `1894a83d1d3aeb064389cda0ae6e974a` | Send 1, "Send Group 1 only, Face 3 resting". The entries are the same as the 10-21 pad's send 1. |
| `his_0004_send2_run_job.json` | 14906 | `a76902d7f16d72f8c2514b73f827e363` | Send 2, "Send Group 2 only". The entries are the same as the 10-21 pad's send 2. |
| `his_0004_sends.txt` | 287 | `9fb5df68b0a92b78997bbd29dcd3db5e` | The index of the two sends. Its bytes are identical to the 10-21 pad's. |

### `his_live_1021_lbracket/`: the 10-21 l-bracket

"l bracket large" (STEP), id DB254706-…, resolution 128. It has one group: Face 6 (2000008, Curves). The model loaded 1 key and core refused no stack. Nothing is held, so there is one `direct` send.

| file | bytes | md5 | what |
|---|---|---|---|
| `his_0004_scene_job.json` | 5303 | `7655efc4c17b51499288cebdc1dfb55c` | Scene job. It declares 14 regions (faces 0–11, 2000008 and 2000009); its `flexible.faces` lists 2000008 as loaded. |
| `his_0004_send1_run_job.json` | 4818 | `9b89227812a2bd9d230f2177f506465e` | The single `direct` send (resting []). 2000008 is loaded. It declares 13 regions (0–11 and 2000008). |
| `his_0004_sends.txt` | 164 | `bbc2dfd83154149e5bbad212a1e2af33` | The index (one send). |

## Determinism

Each project was recorded three times from the same binary:

- twice with `SWIFT_DETERMINISTIC_HASHING=1` (det1, det2);
- once unseeded (with the variable unset).

`cmp` results:

- **det1 vs det2:** 11 of 11 files identical.
- **det1 vs unseeded:** 11 of 11 files identical.
- **Copies in this folder vs det2:** identical.

The unseeded runs exit 1, which is expected. The recorder's `setUp` asserts deterministic hashing (`FlexibleAngledGoldenRecorder.swift:722`), and that assertion is the only failure. The files are still written.

**Cross-check against the committed goldens.** Every run also recorded the recorder's other send sets (his_r5, A1_0002, A1_0003, A1_0004): 17 files per run, 153 over the 9 runs. All 153 equal the committed `Tests/TopOptFlowsTests/Fixtures/angled_press_goldens` byte for byte, which shows this is the same recorder producing the same bytes at this commit. They are not copied here.

`LatticeStaleTypeTests` was in every filter. It passed 6/6 in each of the 9 runs.

## How to reproduce

Run from `app/TopOptKit` at `c772d2a3`, once per project:

```sh
RECORD=1 SWIFT_DETERMINISTIC_HASHING=1 FLEX_AP_BASE=c772d2a3 \
HIS_PROJECT_DIR=$REPO/docs/handoffs/evidence/2026-09-29-flexible-screens/round7/batch_u21/his_live_1021_pad \
FLEX_AP_GOLDEN_DIR=/some/scratch/his_live_1021_pad \
swift test --scratch-path /tmp/r7x20b-build --skip-build \
  --filter 'FlexibleAngledGoldenRecorder/testRecord8EverySendsJob|LatticeStaleTypeTests'
```

For the other two projects, change the project folder (`round7/batch_u1/his_live_1020` or `round7/batch_u21/his_live_1021_lbracket`) and the scratch folder. Then keep `his_0004_*` from the scratch folder and compare it to this folder with `cmp`.

`FLEX_AP_BASE` is only printed. Without `FLEX_AP_GOLDEN_DIR`, the recorder would overwrite the committed goldens.
