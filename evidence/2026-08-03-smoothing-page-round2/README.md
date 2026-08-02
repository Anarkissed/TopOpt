# Evidence — smoothing-page-round2

Handoff: `docs/handoffs/2026-08-03-smoothing-page-round2.md`

## The blocker, root-caused

`s1_probe_res64.txt` / `s1_mesh_identity.txt` — `core/tests/harness/smooth_mesh_identity_probe.cpp`
on `WallMount_ShelfBracket.stl` at resolution 64 (the maintainer's Fast·64³).

```
A-remote  MeshExport.parseBinarySTL (soup)         121548
A-local   bridge to_optimize_variant (MC)           20248
B         import_part_file (welded)                 20248
ratio A-remote : B = 6.0030
```

The device reported 105060 vs 17496 → 6.0048. Same seam, same ratio.

Index-for-index agreement with core's mesh:

| app mesh | same count | same order |
|---|---|---|
| A-remote (LAN) | NO | NO |
| A-local (on-device) | **YES** | **YES** |

**The defect is remote-only** — which is why it shipped, and why it was total: a
LAN run is the only kind that retains the job document the page needs, so the
only reachable path was the broken one.

The panel's own readout, reproduced:

```
mask entries              20248
frozen                    2480
tolerance (mm)            2.43        <- the device's own "within 2.43 mm"
ROUND 1 — stage carried   121548 -> DO NOT match -> BRUSH REFUSED
ROUND 2 — stage carries    20248 -> match        -> BRUSH PAINTS
```

Reproduce:

```bash
cmake --build core/build --target smooth_mesh_identity_probe && ./core/build/smooth_mesh_identity_probe core/tests/fixtures/mesh/WallMount_ShelfBracket.stl 64
```

## S4 — PR 279's AE1, unchanged strength

`s4_ae1_frozen_memcmp.txt` — `core/tests/validation/test_smooth_brush.cpp` on
PR 200's own specimen (`variant_030.stl`, 4344 verts / 8700 tris).

```
frozen bore = 228 verts
strength  pairs  frozen_changed  moved  max_shift(mm)
 0.10       20         0          4116    0.0119
 0.25       20         0          4116    0.1098
 0.50       20         0          4116    0.3933
 0.75       20         0          4116    0.6254
 1.00       20         0          4116    0.7489
54 checks, 0 failures
```

`frozen_changed` counted with `std::memcmp` on the raw `Vec3` doubles. Identical
to PR 279's numbers — 228 frozen, 0 moved, at every strength.

## S6 — no regression

`s6_named_suites.txt`, `s6_app_full_suite.txt`, `s6_core_ctest.txt`.

**Core `ctest`: 100% tests passed, 98 of 98** (1259 s).

| suite | result |
|---|---|
| `SmoothingPageRound2Tests` (new) | 21 tests, **0 failures** |
| `SmoothingPageTests` (PR 279) | 31 tests, **0 failures** |
| `SmoothingModelTests` (PR 200) | 11 tests, **0 failures** |
| `LatticeVariantTests` (PR 274) | 16 tests, **0 failures** |
| `LatticeSDFAlignmentTests` (PR 251) | 7 tests, 1 skipped, **0 failures** |
| `LatticePageRound2Tests` | 15 tests, **0 failures** |
| `LatticePageTests` | 25 tests, **0 failures** |
| `SelectionModelTests` | 18 tests, **0 failures** |

App package, whole thing: **1131 tests, 13 skipped, 10 failures** — all 10
pre-existing, confirmed by re-running them on a stashed (clean) tree, where they
fail identically:

* 8 in 3 `AppModelTests` 3MF tests — this worktree has no `lib3mf-lib`, and the
  refusal says so verbatim (the documented worktree gap);
* 2 in `VariantEntryGatingTests.testTheAppBlockExistsBecauseTheCoreRefusalDoes` —
  it reads core for a lattice/design-box refusal string that PR 285 removed.

Nothing in this task touches 3MF import or the lattice design-box refusal.
