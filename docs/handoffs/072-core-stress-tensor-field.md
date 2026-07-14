# Handoff 072 — Core: expose the per-voxel Cauchy stress tensor field

**Track:** core — `/core/` + the sanctioned `TopOptBridge` C++ bridge ONLY.
No `/app/` view code, no fixtures, no benchmarks, no `materials.json`, no
`ARCHITECTURE.md`, no ROADMAP box touched. **ROADMAP box NOT checked.**

**Worktree / branch:** `/home/user/TopOpt` on branch
`claude/stress-tensor-field-plumbing-d4ypf8`.
The environment provided a single isolated fresh checkout already on the
designated branch, which serves as the core-track worktree. Git forbids a
second worktree on a branch that is already checked out, and the branch
requirement (push only to `claude/stress-tensor-field-plumbing-d4ypf8`) is a
hard constraint, so I did the work in this checkout rather than fragmenting the
push target. Being explicit about this per the "be honest about anything not
done" instruction.

---

## What this is

Pure data-plumbing. The solver already computes the full per-voxel Cauchy
stress tensor during stress recovery (`hex8_stress(...).sigma`), fills a local
`std::vector<std::array<double,6>> stress`, uses it for the peak-stress /
interlayer-tension analysis, and then **discards** it. This change retains that
same tensor per voxel so the app can build load→anchor flux streamlines.

**NO new physics, NO change to the optimization or FEA math.** It mirrors the
existing `von_mises_field` plumbing 1:1 — the tensor exposed here is the exact
tensor the trusted `von_mises_field` scalar is already derived from.

---

## The Voigt convention + shear doubling (the one thing the app MUST match)

**Voigt order: `[xx, yy, zz, xy, yz, zx]`.**
**TRUE shear stresses (tau, NOT doubled).**

This is `Hex8Stress::sigma`'s own convention verbatim (`core/include/topopt/fea.hpp:70-71`):
the six entries are `[σxx, σyy, σzz, τxy, τyz, τzx]`, engineering/true shear —
the shear terms are the physical stresses, with no factor of 2. Von Mises is
recovered from this layout as

```
sqrt( 0.5*((sxx-syy)^2 + (syy-szz)^2 + (szz-sxx)^2)
      + 3*(sxy^2 + syz^2 + szx^2) )
```

which is exactly the formula `hex8_stress` uses for its own `von_mises`
(`core/src/fea/hex_element.cpp:230-235`) — the `3*(τ^2)` (not `1.5*(2τ)^2` etc.)
is what pins the "true shear" choice. The app consuming
`stress_tensor_field` must read the six components in this order with this
shear convention or its derived quantities will not match the core's von Mises.

---

## Changes

1. **`core/include/topopt/pipeline.hpp`** — new field on
   `MinimizePlasticVariant`, right after `von_mises_field`:
   ```cpp
   std::vector<double> stress_tensor_field;
   ```
   Flattened, grid-indexed, size `6 * grid.voxel_count()`: voxel `idx` occupies
   entries `[6*idx .. 6*idx+5]` in the Voigt order above, MPa. Zero on
   void/Empty voxels, gated exactly like `von_mises_field`. Empty for a
   cancelled/failed rung.

2. **`core/src/simp/minimize_plastic.cpp`** — in the stress-recovery block:
   - `variant.stress_tensor_field.assign(6 * G.voxel_count(), 0.0);` next to the
     existing `von_mises_field.assign(...)` (same zero-init, same gating).
   - Inside the printed-voxel loop, right after
     `stress[G.index(...)] = st.sigma;` and the `von_mises_field` write, flatten
     the same `st.sigma` into `stress_tensor_field[6*idx + c]` for `c in 0..5`.
   The local `stress` array and all downstream math are untouched — this only
   copies the value that was already being discarded.

3. **`app/TopOptKit/Sources/TopOptBridge/include/TopOptBridge.hpp`** — new
   `std::vector<float> stress_tensor_field;` on `OptimizeVariant`, mirroring
   `von_mises_field` (double→float narrowing for the app).

4. **`app/TopOptKit/Sources/TopOptBridge/bridge.cpp`** — in
   `to_optimize_variant`, copy it exactly mirroring the `von_mises_field`
   assign:
   ```cpp
   ov.stress_tensor_field.assign(v.stress_tensor_field.begin(),
                                 v.stress_tensor_field.end());
   ```

**Stopped at the bridge boundary as instructed** — NO Swift/TopOptKit mapping
was added. `app/TopOptKit/Sources/TopOptKit/TopOptKit.swift` is untouched; the
app task consumes the bridge field.

## Correctness guard (proves the field is REAL, not hollow)

New test function `check_stress_tensor_field` in
`core/tests/validation/test_minimize_plastic.cpp`, invoked in Scenario A
(cantilever bracket, mixed printed/void) and Scenario I (fully-printed 6×6×6
cube). For every solved non-cancelled variant it:
- asserts `stress_tensor_field.size() == 6 * voxel_count` (and the scalar
  sibling is `voxel_count`);
- for each printed voxel, re-derives von Mises FROM the exposed tensor using the
  stated convention and asserts it equals `von_mises_field[idx]` within
  `1e-9*(1+|ref|)`, voxel by voxel — this proves the exposed tensor is the SAME
  tensor the trusted scalar came from;
- asserts every component is zero off the printed set, and at least one printed
  voxel carries nonzero stress.

Scenario H (cancellation) now also asserts the cancelled rung's
`stress_tensor_field` is **empty**, and the accepted prefix rung's is sized
`6 * von_mises_field.size()`.

### Negative controls (ran, then reverted — the guard is not hollow)

- Populating the tensor with **zeros** → test FAILS at the von-Mises-match and
  nonzero-stress checks (`8/547 checks FAILED`).
- Populating with a **reversed (mislabeled) Voigt order** (`sigma[5-c]`) →
  test FAILS the von-Mises-match check (`4/547 checks FAILED`).
- Correct implementation → `all 547 checks passed`.

---

## Raw ctest output

Targeted (the test that carries the new guard):

```
$ ctest --test-dir build-core -R "^minimize_plastic$" --output-on-failure
Test project /home/user/TopOpt/build-core
    Start 23: minimize_plastic
1/1 Test #23: minimize_plastic .................   Passed   23.92 sec

100% tests passed, 0 tests failed out of 1

Total Test time (real) =  23.92 sec
```

Direct binary run (check count):

```
$ ./build-core/test_minimize_plastic
minimize_plastic (M5.3): all 547 checks passed
```

Full core suite (`ctest --test-dir build-core --output-on-failure --no-tests=error`,
28 tests — abridged to the tail; every line above also `Passed`):

```
23/28 Test #23: minimize_plastic .................   Passed   24.07 sec
24/28 Test #24: anchor_integrity .................   Passed    3.81 sec
25/28 Test #25: design_domain ....................   Passed    0.42 sec
26/28 Test #26: mma ..............................   Passed   72.28 sec
27/28 Test #27: mma_projection_gate ..............   Passed    1.08 sec
28/28 Test #28: stress ...........................   Passed   18.45 sec

100% tests passed, 0 tests failed out of 28

Total Test time (real) = 409.10 sec
```

Build: configured with `cmake -S core -B build-core -DCMAKE_BUILD_TYPE=Release`
(system GCC 13.3, Eigen3 3.4 via `libeigen3-dev`; OCCT/lib3mf absent locally, so
their optional targets are skipped — unrelated to this change). All test targets
compiled with no warnings/errors.

---

## Build/visibility note

This change is in `/core/`, so it is **invisible to the app until
`./app/scripts/build_core.sh` rebuilds the xcframework**. The bridge struct now
carries `stress_tensor_field`, but the Swift/app side won't see it until that
rebuild runs and the app task adds the TopOptKit mapping.

## Not done (by design / honesty)

- Swift/TopOptKit mapping — deliberately out of scope (bridge boundary).
- No golden fixture regenerated or edited; used the existing solved fixtures.
- ROADMAP box not checked (maintainer's call).
- Handoff number `072` is provisional — reassign NNN as needed.
