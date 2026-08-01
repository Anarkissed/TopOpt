# Smoothing page — evidence (2026-08-02)

| file | what it is |
|---|---|
| `ae1_frozen_memcmp.txt` | **Bar AE1.** `core/build/test_smooth_brush` on PR 200's own specimen — the committed real ladder variant `variant_030.stl` (4344 verts, 8700 tris), frozen against the same resolved bolt-bore predicate (228 vertices, the number PR 200 reported). `frozen_changed` is counted with `std::memcmp` on the raw `Vec3` doubles at every brush strength. 54 checks, 0 failures. |
| `wallmount_probe.txt` | **Bar AE4** + H2 + H3 + the brush measurement. `core/build/smooth_brush_probe` on the committed `WallMount_ShelfBracket.stl` at resolution 128. Prints the specimen, the 12 largest pseudo-faces, the geometrically-chosen load case, the calibration, two full sweeps and the local-vs-global brush comparison. |
| `wallmount_sweep.txt` | The same run's machine-readable summary line set. |
| `core_ctest.txt` | Full core suite: **94/94 passed**, 1632 s. |
| `app_tests.txt` | Full app suite: 1079 tests, 14 skipped, 8 failures — all in the 3 pre-existing 3MF tests (no lib3mf vendored in this worktree). |

## Reproducing

```
cmake -S core -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j8 --target test_smooth_brush smooth_brush_probe
./build/test_smooth_brush
./build/smooth_brush_probe core/tests/fixtures/mesh/WallMount_ShelfBracket.stl 128 0 35 <evidence-dir>
```

The probe's arguments are `<mesh> <resolution> <force_N|0=calibrate> <infill%>
<evidence_dir> [anchor_axis anchor_max load_axis load_max]`. Passing 0 for the force
calibrates both postures; the face selection defaults to anchor = max-x, load = min-y,
which is the shelf-bracket reading of this part, and every choice is printed.

## The headline numbers

* **AE1** — 228 frozen vertices, `frozen_changed = 0` at strengths 0.10/0.25/0.50/0.75/1.00,
  while 4116 free vertices move (max shift 0.75 mm).
* **AE4** — with the specimen calibrated to sit just above the gate (effective 1.6500,
  ACCEPTED), smoothing at strength 0.25 drops it to **1.3718, REJECTED** — a −16.9 %
  fall through the 1.50 stop. **The verdict drops.**
* **Non-monotone** — the same sweep reads ACCEPT (1.6500), ACCEPT (1.6747), **REJECT**
  (1.3718), REJECT (1.4472), REJECT (1.4459), **ACCEPT** (1.5018). The verdict flips
  three times across six strengths.
* **H2 both ways on one part** — min-feature violations 17 → 13 at strength 0.10, then
  → 50 at strength 1.00.
* **The brush** — smoothing only the loaded half (24 % fewer vertices moved, 4169 left
  bit-identical, half the min-feature violations) cost **−0.5395** of margin against the
  global pass's **−0.3050**. Where you brush dominates how much you brush.
