# Evidence — 2026-08-03 retention & design-box device failure

Handoff: `docs/handoffs/2026-08-03-retention-designbox-device-failure.md`

## The maintainer's run

| File | What it is |
|---|---|
| `device_run_job.json` | The job document from worker job `b56bbf4421f34212` — WallMount ShelfBracket, submitted 01:23, finished 01:32 on 2026-08-02. This is the run whose two greyed-out buttons are the subject of the task. Byte-for-byte as the worker stored it. `design_box` present, `material: PLA`, `resolution: 64`, anchors `[8, 14, 12]`, one load group, three keep-clear bores. Consumed directly by `DeviceRunEntryGateTests`. |
| `device_run_info.json` | That run's `run_info.json`. |

Its `out/` held `design.bin` (1 573 112 bytes), `fields.bin`, `report.json` and
`variant_068.stl` — i.e. both halves of the retention pair were produced and were
servable. Not copied here (1.5 MB of density field); path was
`~/.topopt-worker/b56bbf4421f34212/out/`.

## The earlier refused run — where "domain expansion" came from

| File | What it is |
|---|---|
| `refused_lattice_designbox_job.json` | Worker job `6ed5fba93c8240ad`, 2026-08-01 19:34 — a `lattice` + `grading` + `design_box` job. |
| `core_refusal_2026-08-01T1934.log` | Its worker log. Core refused it in 51 ms with *"…the certification load case cannot be reconstructed under **domain expansion**"* — the wording in the maintainer's report, which the app's own message never uses (it says "expanded grid"). This run predates PR 285's merge (a473714, 21:14), so the refusal was correct at the time. |

## The build path (D2)

| File | What it is |
|---|---|
| `worker_cli_version.txt` | The worker's `topopt-cli`: `fingerprint=ce4e181a8535` (the merge commit, both PRs in), built 01:08 — fifteen minutes before the run — and **zero** occurrences of the string PR 285 deleted. The shipping worker binary IS the merged code. Since `RemoteRunner` refuses a fingerprint mismatch before running, and the run completed, the app binary was built from that same commit. |

## The tests

| File | What it is |
|---|---|
| `mirror_test_before_after.txt` | `core/tests/unit/test_app_core_capability_mirror.cpp` run against a clean `git archive` of the merged commit `ce4e181` (**3 of 4 checks FAIL, exit 1**) and against this branch (**0 failures, exit 0**). This test runs in the existing `core-linux` CI job and would have failed PR 285 at merge time. |
| `app_suite_before_after.txt` | PR 284's own tripwire shown red on unmodified `main`; `DeviceRunEntryGateTests` reproducing the maintainer's exact sentence against unmodified `main`; and the after state. Also records that the three remaining 3MF failures are the pre-existing worktree `lib3mf` provisioning gap. |

## Reproducing

```bash
./app/scripts/build_core.sh                       # fresh worktrees vendor no core
(cd app/TopOptKit && swift test --filter DeviceRunEntryGateTests)

cmake -S core -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --target test_app_core_capability_mirror
ctest --test-dir build -R app_core_capability_mirror --output-on-failure
```
