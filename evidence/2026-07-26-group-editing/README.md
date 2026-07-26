# Evidence — group editing (manual primitives + deletion + group lock)

See `docs/handoffs/2026-07-26-group-editing.md` for the full write-up.

## Files

- `core-test_clearance.txt` — 28 checks. Includes **B2**: a manual bolt and a manual
  face each produce a BIT-IDENTICAL mask to the auto face of the same geometry, plus
  the degenerate-manual safe no-op.
- `core-test_job.txt` — 106 checks. Includes `test_clearances_manual`: manual bolt +
  face geometry round-trip, the face_id⊕geometry XOR rule, and **B1** (a manual and an
  auto bolt share every field but the source).
- `core-clearance-parity.txt` — the loadcase→core integration path (`loadcase.cpp`,
  which the split touched) stays byte-identical for auto clearances (**B4**).
- `app-manualprimitive-tests.txt` — `ManualPrimitiveTests` (17) + `ManualPrimitiveJobTests`
  (4): add/move/delete, auto-deletion (**B3**), undo/redo (**B5**), group lock (**B6**),
  detent math, sidecar round-trip.
- `app-related-suites.txt` — the 95 related app tests (Clearance/Force/Project/Undo/
  Selection/JobJSON) stay green — no regression.
- `sample-job-clearances.json` — the three clearance shapes the extended schema accepts,
  auto and manual side by side (parses; `_`-keys are ignored comments).

## Reproduce

```bash
# core
cd core && cmake --build build --target test_clearance test_job -j4
./build/test_clearance && ./build/test_job && ./build/test_clearance_parity

# app
cd app/TopOptKit
swift test --filter "ManualPrimitive"
```

## B7 — device-real (maintainer)

Not captured here by design: the bar is the maintainer watching it on device. The
handoff lists the six-step check. The vendored core was refreshed
(`app/scripts/build_core.sh`, exit 0) so the app links the new bridge.
