# 094 — Savings % reporting basis: fix (no-box part-relative fraction)

Status: **IMPLEMENTED.** Core-only, reporting-only. Implements the fix spec in
093-savings-floor-diagnosis.md (Rank 1). The `git diff` for this branch is:
`core/src/simp/minimize_plastic.cpp` (the reporting gate), a new regression gate
`core/tests/validation/test_savings_part_relative.cpp`, and its CMake registration.

---

## STEP 0 — BASIS DECISION: option (a), MINIMAL. And why NOT (b).

**Chosen: (a) — extend handoff 080's part-relative overwrite to the no-box branch.**
The reported achieved fraction becomes `printed_voxels / part_solid` on the no-box
path too, so the displayed `savings = 1 − achieved` and the reported mass are two
views of ONE voxel count (`#{ρ>0.5}`) and can no longer disagree. This kills the
178 g "floor" — the gap between the target-tracking `Σρ/n_active` the % used and the
`#{ρ>0.5}` count the mass uses (093).

### Why not (b) — the complete, mesh-enclosed-volume basis

(b) wants BOTH the mass and the % derived from the exported mesh's enclosed volume
(measure 3 in the task; 086/087's recommendation). I assessed it and **deferred it**,
not because it is unreachable from /core/, but because it **cannot be self-approved
without violating guard (b)**:

1. **The mesh IS reachable from /core/.** The 1× marching-cubes surface `variant.v3.mesh`
   is populated in `minimize_plastic` (`check_v3`, ~line 563) and `signed_volume(mesh)`
   exists (`mesh.hpp:45`). 087's follow-up already spells out the mass half:
   `mass_grams = density · |signed_volume(v3.mesh)| / 1000`, moved to after `v3` is
   populated. So (b) does **not** require touching `bridge.cpp` or the CLI (the
   LAN-offload task's territory) — no territory collision.

2. **But (b) moves the MASS, and the mass is what 080's guard is pinned to.**
   `test_designbox_reduction` asserts, to 1e-6, the identity
   `implied_baseline = mass / achieved == part_mass`, where `part_mass` is the
   **voxel-count** part mass (`density · part.solid_count() · voxel_volume / 1000`,
   test line 106-109). That identity is exact *today* only because both `mass` and
   `achieved` are voxel-count based and the `printed_voxels` cancels. Re-basing `mass`
   on `|signed_volume(v3.mesh)|` breaks the cancellation: `mesh_mass / achieved`
   resolves to `density · part_mesh_volume`, which differs from the voxel `part_mass`
   by the same ~0.25–4 % voxel-vs-mesh gap 086/087 measured. That is a change to the
   exact box-path number 080 locked. **Task guard (b): "If your change alters that
   number, you broke 080 — stop and report."** So (b) is a stop-and-report boundary.

3. **(b) done consistently is a multi-consumer, maintainer-gated change.** To keep %
   and mass on one basis (093's coupling rule), (b) must move the savings numerator
   AND denominator to mesh volume too, AND update `test_designbox_reduction`'s
   `part_mass` to the mesh basis, AND the CLI `JobReport` mass — so the same design
   does not report ~559 g in the app and ~583 g in the CLI report (087 STEP-3 point 1).
   087 itself defers the anchor choice to the maintainer ("anchor mass on the 1× mesh
   volume … Maintainer decision in that follow-up"). It is not a reporting one-liner;
   it redefines a user-facing mass across three consumers and moves an 080-guarded
   value. That belongs to the maintainer, not this fix.

**Principle check.** The task's rule — "the number the user reads must describe the
object in the file" — is the reason (b) is the eventual right answer, and (a) does not
fully reach it (see the residual). But (a) **does** make the number describe the
object *consistently and conservatively*: after (a) the % and the mass agree, and both
describe the voxel model, which is a faithful (slightly heavy) stand-in for the printed
mesh. The one dishonest thing today — a % that tracks a *target* the print never
realizes — is removed. Closing the last ~4 % to the mesh is (b), spec'd below as a
follow-up.

---

## STEP 1 — THE CHANGE

`core/src/simp/minimize_plastic.cpp`, one new predicate + one gate widened:

```cpp
const bool part_relative = expanded && !options.freeze_imported_part;   // unchanged (080)
const bool report_part_relative = !expanded || part_relative;           // NEW (094)
```

- `part_relative` (unchanged) still gates the **budget rescale** (`opt.volume_fraction
  = vf·part_solid − frozen_effective … / active_effective`) and the effective-count
  loop — **box path only**. On the no-box path the rung target is already `vf` of the
  whole part; rescaling there would change what the optimizer solves (Gate-V2 / the
  ladder). **The solve is byte-identical. Not touched.**
- `report_part_relative` (new) gates ONLY the **reporting overwrite**:
  `variant.optimization.volume_fraction = printed_voxels / part_solid`. It is true when
  there is no box (`!expanded`) OR on the 080 box path (`expanded && !freeze_imported_part`),
  i.e. everywhere except a design-box run that freezes the imported part. On the no-box
  path `G == grid`, so `part_solid` is the whole part and `printed_voxels` is the printed
  shape on that same grid — exactly the honest ratio.

Nothing else changes. The overwrite is a pure read of `printed_voxels` (already counted
for the mass) and `part_solid` (already computed), written after the solve and after the
per-rung accept decision.

### One test adapted (not weakened): `test_minimize_plastic` scenario O

`test_minimize_plastic`'s MMA-switchover parity check (scenario O) compared OC vs MMA by
reading `optimization.volume_fraction` at tol 1e-2 — a field 094 now repurposes to the
THRESHOLDED `printed_voxels/part_solid`. OC and MMA satisfy the same continuous volume
constraint but distribute the grayscale interface differently, so their `#{ρ>0.5}` counts
legitimately diverge on the gray rung 2 (vf 0.30) — reading the reported field there tests
gray-distribution noise, not convergence. Fixed by comparing the **continuous** fraction
`Σρ/solid_count` (the quantity the volume constraint actually drives to target), recomputed
in-test from `physical_density`. This is strictly more faithful to the check's stated intent
("OC and MMA hit the same achieved volume fraction"); the compliance-parity assertion beside
it is untouched. This was the ONLY check in the whole suite that read the repurposed field
as an optimizer diagnostic (1 of 547 checks in that gate; every other reader treats it as
the reported savings basis, which is exactly what 094 makes correct).

---

## STEP 2 — USER-VISIBLE DELTA (the real 128³ L-bracket) — STATED PLAINLY

This CHANGES the headline number the maintainer has been reading. It is **correct** and
must not be softened. Reconstructed from the device data in 093 (part 868 g; mass is the
voxel-count mass, **UNCHANGED** by this fix):

| rung | vf target | **displayed BEFORE** (`1−vf`) | **displayed AFTER** (094, `1−printed/part`) | mass (g) *(unchanged)* | true printed/part = mass/868 |
|-----:|----------:|------------------------------:|--------------------------------------------:|-----------------------:|-----------------------------:|
| 0 | 0.68 | **−32 %** | **−25 %** | 647 | 0.745 |
| 1 | 0.52 | **−48 %** | **−38 %** | 538 | 0.620 |
| 2 | 0.38 | **−62 %** | **−49 %** | 440 | 0.507 |
| 3 | 0.26 | **−74 %** | **−59 %** | 357 | 0.411 |

**"−74 %" becomes "−59 %."** That is the correction, not a regression: the old number
reported `1 − vf_target` (a target the constraint always hits); the new number reports
`1 − printed/part` (the material actually laid down). The **mass column does not move** —
the fix only makes the % agree with the mass that was already correct. At 64³ (crisp,
near-0/1) the before/after are ≈ identical (there `printed/part ≈ vf`), so device 64³
runs are visually unchanged.

Corroboration on a small in-repo fixture (`test_savings_part_relative`, no-box, gray
field): pre-094 the ladder-0 rung reported `achieved = 0.6789` (= the 0.68 target) while
`printed/part = 0.8611`; post-094 it reports `0.8611`. Same field, same mass
(0.11532 g), only the readout moved from target to measurement — the 128³ story in
miniature.

---

## RESIDUAL NOT CLOSED — the 086/087 voxel-vs-mesh gap (quantified)

(a) makes the % and the mass **consistent** with each other, but leaves them **both** on
the voxel-count basis, which over-reads the exported MESH:

- 087 measured, on a real lacy 64³ part: voxel-count mass **582.99 g** vs 2×-resampled
  exported mesh **559.39 g** — the voxel count is **+4.2 % heavier** than the printed
  mesh. 086 measured +0.25 %/+0.7 % on a chunky, near-crisp part. The gap scales with
  grayscale-ness (Mnd) and laciness; production MMA runs without projection, so it is
  several percent, not negligible.

- **Direction of the residual after 094:** the numerator `printed_voxels` over-reads its
  mesh volume by ~4 % (gray boundary voxels counted whole), while the denominator
  `part_solid` is a crisp voxelization of the imported part (staircase only, ~sub-%). So
  `printed/part` (voxel) runs a few % **higher** than `printed/part` (mesh), which makes
  `savings = 1 − printed/part` a few points **lower** — i.e. **094 slightly UNDERSTATES
  the true printed savings.** Example, rung 3: voxel `printed/part = 0.411` → −59 %;
  applying 087's +4.2 % voxel-over-mesh to the numerator gives mesh `printed/part ≈
  0.394` → **≈ −61 %** true. So the honest mesh number is a touch *more* savings than
  the −59 % we now show. The bias is **conservative** (tells the user they saved a bit
  less than they really did on the object in the file) and **consistent** (same sign and
  ~magnitude on every rung), not a sign error.

**Is the 086 mesh-mass gap now closed? NO — still open, unchanged.** 094 does not touch
`mass_grams`; it remains voxel-count based, so the ~4 % mass-vs-mesh over-read 086/087
flagged survives exactly as they left it. 094 closes a *different* gap — the
savings-vs-mass disagreement (measure 1 vs measure 2). The mass-vs-mesh gap (measure 2 vs
measure 3) is the (b) follow-up.

---

## FOLLOW-UP SPEC — (b), the mesh-enclosed-volume basis (maintainer-gated)

Do this when the maintainer signs off on moving the user-facing mass (it changes an
080-guarded number, so it is not self-approvable):

1. **Mass → mesh volume** (087's exact patch). In `minimize_plastic.cpp`, move the
   `mass_grams` assignment to AFTER `variant.v3 = check_v3(...)` (so `v3.mesh` exists) and
   replace the voxel count:
   ```cpp
   variant.mass_grams =
       material.density_g_cm3 * std::abs(topopt::signed_volume(variant.v3.mesh)) / 1000.0;
   ```
   Anchor on the **1× mesh** (`v3.mesh`), not the resampled export, so mass does not track
   the display/export `smooth_factor` knob (087 recommends this; the 1×/2×/4× volumes
   agree within 0.66 %).
2. **Savings → the SAME mesh basis.** Report `achieved = |signed_volume(result_mesh)| /
   |signed_volume(part_mesh)|`, where `part_mesh` is the marching-cubes surface of the
   crisp part-solid indicator field on the same grid (both 0.5-iso MC volumes → one
   consistent basis; the `printed_voxels` cancellation that (a) relies on becomes a
   `signed_volume` cancellation). Keep % and mass on ONE basis (093's coupling rule) — do
   not move only one.
3. **Update `test_designbox_reduction`** to compute `part_mass` from the part mesh volume,
   and re-baseline its printed savings %. This is the "alters the 080 number" step — it is
   why (b) needs the maintainer. Keep the structural assertions (`achieved < 0.9`, baseline
   == part mesh mass, rung count) intact.
4. **CLI `JobReport` mass** moves with it automatically (single core definition), so the app
   and the CLI report agree (087 STEP-3 point 1).

After (b) the number the user reads describes the enclosed volume of the STL/3MF in the
file — closing the residual above.

---

## GUARDS — status

- **(a) Regression test (093's proposal): DONE and it BITES.**
  `core/tests/validation/test_savings_part_relative.cpp` asserts, on a deliberately
  grayscale field (`min_feature_mm = 2.5`, h = 1.0 mm → filter rmin = 2.5 voxels, so the
  count strictly exceeds `Σρ`): displayed % == `1 − printed_voxels/part_solid` on the
  no-box path, and equivalently `mass/achieved == part_mass`; the same identity on the box
  path (080). **Verified it FAILS against pre-094 core on the no-box path** (git-stashed
  the source fix, rebuilt: reported `achieved = 0.6789` vs expected `0.8611`,
  `mass/achieved = 0.170 g ≠ part_mass 0.134 g` — 2 checks fail); PASSES after the fix
  (7/7). The box path passed both before and after (080 already fixed it).
- **(b) 080 not regressed. designbox_reduction byte-identical.** Box rung-0
  `achieved(part-rel) = 0.6429`, `mass = 0.53568 g`, `implied_baseline = 0.83328 g ==
  part_mass`, `savings = 35.7 %`, all 6 checks — identical before and after the change
  (the box path predicate `report_part_relative` reduces to `part_relative` when
  `expanded`, so the box path is untouched). The change alters no 080 number.
- **(c) Gate-V2 GREEN and byte-identical by construction.** `test_gate_v2` calls
  `simp_optimize` DIRECTLY (line 487), never `minimize_plastic`, so the reporting overwrite
  cannot leak into it; it uses `SimpOptions` defaults, unchanged. Green (116 s).
- **(d) DESIGN untouched — reporting only.** The overwrite writes only the scalar
  `variant.optimization.volume_fraction`, after the solve and after the accept decision
  (which reads the stress margin, not the fraction). Empirical proof: the pre-094 and
  post-094 no-box runs of the regression fixture produced an **identical** density field
  (`printed = 93`, `Σρ = 77.18`, `mass = 0.11532 g`, same rung rows) — only the reported
  fraction moved. Density arrays and accept/reject decisions are byte-identical.
- **(e) Full core suite GREEN: 41/41 tests passed** (`ctest -j`, Eigen present, 270 s).
  The only test that needed adapting was `minimize_plastic` scenario O (above); every
  other gate — including the two slow optimizer gates `gate_v2` and `mma` — passed
  unchanged.

---

## Build / verify

`/core/` change → the app must run `app/scripts/build_core.sh` (macOS, brew/xcframework —
cannot run in this Linux worktree) to refresh the vendored lib before the next app build.
Here the core was built and tested with cmake+ctest (as 086/087 did on Linux; Eigen
installed via `libeigen3-dev`):

```
cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release
cmake --build core/build -j
ctest --test-dir core/build            # full suite
ctest --test-dir core/build -R "savings_part_relative|designbox_reduction|gate_v2"
```

No ROADMAP box checked. No `bridge.cpp` / CLI edit (LAN-offload territory untouched).
No fixtures, benchmarks, materials.json, ARCHITECTURE.md changed.
