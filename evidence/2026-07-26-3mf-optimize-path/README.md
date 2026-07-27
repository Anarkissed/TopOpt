# Evidence — a 3MF that imports must also optimize (2026-07-26)

See `docs/handoffs/2026-07-26-3mf-optimize-path.md`.

## Diagnosis
- `DIAGNOSIS_reproduction.txt` — the `topopt-cli:` error is unique to the CLI binary
  (part.cpp + run_job.cpp + main.cpp), NOT the bridge; a lib3mf-less `topopt-cli`
  reproduces the maintainer's screenshot bit-for-bit, and the same binary runs the STL
  twin fine (so only 3MF is affected).

## M1 — end to end, both targets, real optimization
- `app_ondevice_optimize_3mf.txt` — iPad path: real bridge import+normalize+optimize
  of `plate_bore.3mf` → variants (178.9 s res-32 solve), passed.
- `live_worker_result.zip` — Mac worker path: live HTTP `topopt_worker.py` ran a
  multipart `.3mf` job to done (2 variants); zip holds report + variants + run_info.
- `live_worker_raw_3mf.run_info.json` — that run's run_info (`source_format: "3mf"`).

## M2 — STL unaffected  /  deeper-fix correctness
- `M2_and_deeper_fix.txt` — STL report.json + variant meshes byte-identical pre/post;
  3MF result == STL-twin result; the app-normalised job runs on a lib3mf-LESS binary
  (which still refuses a raw .3mf), byte-identical to the raw-3MF run.

## M4 — run_info true source format
- `worker_raw_3mf.run_info.json` — raw `.3mf` job (direct CLI).
- `worker_appflow_stl+sourcefmt.run_info.json` — app flow: model=STL + source_format=3mf.
- `worker_no_lib3mf_normalized.run_info.json` — same job on a lib3mf-less binary.
  All three record `"source_format": "3mf"`.

## Provenance-in-app tests
- `app_provenance_tests.txt` — AppModel 3MF→STL normalization + reopen round-trip +
  JobJSON source_format emission (STL emits none; 3MF emits "3mf"), all passed.

## Build
- `core_ctest.log` — core `ctest` 70/70 passed (incl. threemf_import, job_schema).
- `core_configure_with_lib3mf.log` — clean `core/build` configure that found lib3mf.
- `lib3mf_provision.log` — vcpkg lib3mf 2.5.0#1 provisioning (CI-matched).
