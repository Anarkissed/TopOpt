# The exported geometry is rotated into the certified build orientation

**Date:** 2026-08-01
**Branch:** `claude/export-geometry-build-orientation-3613b6` (from main after PR 271, `9f67387`)
**Implements:** PR 271 (`2026-08-01-build-direction-separation` — the resolver, the
job key and the scorer this consumes), PR 266 (`2026-08-01-orientation-scoring-probe`
— the measurement), PR 253 / PR 250 (the lattice containment and floating-end bars
this must not break), PR 201 (the mesh statistics V5 rests on).
**Scope:** `core/` export + report + job schema + `app/`. No solver work. Fixtures,
`materials.json`, `ARCHITECTURE.md`, `DECISIONS.md` and ROADMAP checkboxes
untouched. No assertion weakened or deleted. The gate's verdict logic and
tolerance are unchanged.
**Evidence:** `evidence/2026-08-01-bake-build-orientation/`

---

## WHAT SHIPPED

**The certified orientation is now in the geometry, not in a number.**
`threemf.cpp:47` said it outright — *"the mesh is exported in its own model-space
coordinates"* — then called `AddBuildItem(mesh_object, identity)`.
`threemf_stream.cpp:185` emitted a bare `<item objectid="1"/>`. STL carries no
transform at all. So the certified orientation existed only in `report.json`, the
slicer placed the part however it liked, and the certificate described a different
object from the one being sliced.

Three things:

1. **The rotation is baked into the VERTICES**, not into a build transform. A 3MF
   transform is advice that "place on bed" / "auto-orient" / "arrange" reset.
   Rotated vertices cannot be reset. The transform stays identity as belt and
   braces, and both writers now say why in a comment so nobody puts one back.
2. **One decision, one place.** `resolve_bake_plan` is to baking what
   `resolve_build_direction` is to the build direction: the only site that decides.
3. **Auto-apply only when the user chose nothing** — and then it is impossible to
   miss: the receipt's first key, a stderr line, and the app's top banner.

**Every bar was met. One BLOCKED-STOP path was taken, on the app, and it is
reported below rather than papered over.**

| bar | result |
|---|---|
| **V1** the file is the certified object | **MET, EXACTLY.** The criteria recomputed from the exported mesh in its own +Z match the model-frame criteria at the certified direction: build height 35 = 35, overhang faces 274 = 274, overhang **area to relative deviation 0.000e+00**. |
| **V2** explicit orientation byte-identical | **MET, against a real PR 271 binary.** `report.json`, `variant_060.stl` and `fields.bin` are **raw sha256 identical** to an independently built worktree at `9f67387`. And auto-apply over a declared direction **throws**, so the leak is structural, not incidental. |
| **V3** no key / no scorer defined and tested | **MET.** Three modes asserted directly off the resolver; a job predating the key parses as `auto`; `off` is PR 271 exactly. |
| **V4** the rotation is exact and lossless | **MET.** All six cube axes are signed axis permutations; **8,640 solid vertices and 117,636 lattice vertices compared through the exported files, 0 drifted.** Off-axis reported separately: 20 of 26 candidates, worst direction error 9.5e-16. |
| **V5** winding and manifoldness survive | **MET.** det == +1 exactly on all six axes (< 1.1e-15 off-axis); boundary edges 0/0, non-manifold 0/0, components 1/1, enclosed volume identical **and same-signed**. |
| **V6** the lattice comes with it | **MET.** The lattice receipt is byte-identical apart from the frame declaration — clipped struts, landings, anchor nodes, volumes, composite margin all unchanged. Containment holds in the exported frame (0 out-of-part vertices). |
| **V7** auto-apply announced, never silent | **MET, in four places**: the receipt's first key, a dedicated `auto_applied` block with the measured counterfactual, a stderr line, and the app's top banner. |
| **V8** determinism + full ctest | **MET. Full ctest 91/91, 100% passed** (90 before; the +1 is `bake_build_orientation`). Two runs of the same job byte-identical — the receipt identical once wall-clock timings are stripped, the same treatment PR 271's own evidence gave `wall_ms`. |
| **V9** *(added — see below)* auto-apply is verdict-monotone | **MET.** It can never turn an orientation that would have been ACCEPTED into a REJECTED one. |

---

## *** THE FINDING THAT CHANGED THE DESIGN ***

**The task said "apply the scorer's best candidate". Doing that literally loses
parts.**

PR 271's `recommended_index` is a **maximin over six criteria** and is deliberately
**not** the margin-maximiser — it trades interlayer margin against support material
and print height, because those are real costs and the criteria genuinely disagree.
That is the right rule for **advice a human reads**. It is the wrong rule for a
**choice made on someone's behalf**, because it can pick an orientation that FAILS
the gate on a part that would have passed.

This is measured, not hypothetical. Applying the unconstrained recommendation on the
committed design-box fixture:

| | rungs (no box) | rungs (with box) |
|---|---|---|
| PR 271 (no auto-apply) | 2 | 2 |
| unconstrained auto-apply | 3 | **1** |

An accepted ladder rung, lost outright — on a user who never asked for the
trade.

**So the gate became a CONSTRAINT on the auto-choice, and the six criteria the
objective:** auto-apply maximins over the candidates that would be ACCEPTED, and
falls back to the unconstrained pick only when nothing passes (there is then no
verdict to protect). Because the as-inferred direction is always candidate 0, a
passing inferred orientation guarantees a non-empty feasible set. That gives the
property the whole design now rests on:

> **AUTO-APPLY IS VERDICT-MONOTONE. It can rescue a part; it can never sink one.**

Asserted in `apply_recommended_orientation` (it *throws* on a violation, rather
than reporting one), and tested as bar V9.

**PR 271's `recommended_index` is untouched** — still the pure maximin, still
published. When the constraint bites, the receipt says so and prints the
unconstrained pick beside it with its failing verdict, so the trade-off is visible
rather than resolved in silence.

**Was PR 271's U5 weakened?** No — it was *inverted on purpose, in the one place the
task asked for*. U5's rule was "a recommendation never **silently** changes a
verdict", and the word carrying it was *silently*. Auto-apply changes the verdict
loudly, only when the user made no choice, and only in the safe direction. The
structural half of U5 is *stronger* than before: applying a recommendation over a
**declared** direction now throws.

---

## THE FRAME AUDIT — the correctness heart

Two frames, and only two:

* **MODEL frame** — the input geometry's coordinates. The voxel grid, the solve,
  `fields.bin`, the loads, the fixtures, the clearances and the design box.
  **None of them move.**
* **BUILD frame** — the exported file's coordinates: the model frame rotated so the
  applied build direction is +Z.

**The key result: every direction-bearing SCALAR is a rigid-motion invariant, so it
describes both frames and there is no frame to get wrong.** Only VECTORS needed a
frame stated. Field by field:

| field | where | frame | what was done |
|---|---|---|---|
| `orientation` | `report.json` | **EXPORT** when baked | Reads `(0,0,1)` — the build direction *in the file*. `orientation_model` + `orientation_frame` added beside it. Emitted only when baked, so un-baked documents keep their bytes. |
| `max_interlayer_tension_mpa`, `margin.*`, `margin_effective` | `report.json` | **both** | Scalars evaluated at the build direction; the rotation carries the computation to itself. Asserted equal across the rotation (V1). |
| `min_feature_violations`, `printed_fraction`, `max_stress_mpa` | `report.json` | **both** | Direction-independent. Asserted equal. |
| `support_volume_voxels`, `build_height_layers`, `first_layer_footprint_voxels` | receipt | **both** | Counts at the build direction; invariant. V1 recomputes the support criterion **from the file** and matches to 0.000e+00. |
| candidate `build_direction` vectors | `build_orientation.json` | **MODEL**, declared | New `export_frame` block names the frame, gives the rotation matrix, and states `build_direction_in_file: [0,0,1]`. |
| `strut_interlayer_bound_mpa`, `strut_il_cross_factor`, `build_dir_on_lattice_axis` | lattice receipt | **both** | The lattice is generated on the model grid and **rotated with the part**, so its relation to the build direction travels with the geometry. New `export_frame` key says exactly this. |
| per-voxel arrays, displacement vectors | `fields.bin` | **MODEL**, NOT rotated | Cannot carry a frame (binary v1 container). The header doc now states it in capitals and points at `run_info.json`'s rotation for anyone who needs to map them. **This is what forced the app decision below.** |
| the rotation itself | `run_info.json` | — | New `export_frame` object (gated on baked, so un-baked run_info is byte-identical). |

**No BLOCKED-STOP was needed here**: no direction-bearing report field turned out to
be inexpressible. The one place where two frames could genuinely be *mixed* is not a
report field at all — it is the app's viewer, and it is handled below.

---

## THE APP — a BLOCKED-STOP taken, and why

**Built and tested:** the receipt decoder for every new field, and a top-of-panel
banner that states, in order: that the orientation was chosen for you, which one it
is, the **measured** counterfactual, and — when true — *"This part passes because of
the orientation we chose."*

**Not enabled:** the app and the on-device bridge both send
`bake_build_orientation: "off"`.

**Why, plainly.** `RemoteRunner.fetchMesh` downloads the **exported** mesh and the
viewer draws it under the **model-frame** gravity arrow, design box, clearances,
load groups and the per-voxel overlays spliced from `fields.bin`. Rotate the mesh
alone and every one of those lands on the wrong geometry. That is a frame mix — and
the task's own instruction is that shipping a report that mixes frames is worse than
shipping no rotation. The on-device bridge is the same story from the other side: it
returns `variant.v3.mesh` in model coordinates and writes no file, so a
chosen-and-baked orientation there would certify something the returned mesh does
not carry.

**The consequence, stated rather than hidden:** an app run still certifies the
gravity-inferred orientation and still only *recommends*, exactly as it did after
PR 271 — no better, no worse. The CLI / worker-direct path gets the baked file.

**The fix, for whoever takes it:** make the viewer frame-aware — map the fetched mesh
back through `export_frame.rotation_row_major` (already published, so no second
derivation) before display, or render the model-frame mesh the bridge already holds.
Then one line comes out of `RemoteRunner` and two out of `bridge.cpp`. A test fails
if anyone removes them earlier.

---

## HOW THE PIECES FIT

| piece | what |
|---|---|
| `build_frame.hpp` / `build_frame.cpp` | **NEW.** `BuildFrameRotation`, the six exact literals, Rodrigues off-axis, `RotatingTriangleSink`. |
| `resolve_bake_plan` (`production.hpp/.cpp`) | **THE ONE DECISION.** Three modes, one pre-composed reason string. |
| `analyze_fixed_design` | New `auto_apply_build_orientation` parameter. Re-seals exactly the direction-dependent outputs from the candidate row the scorer **already priced with the same gate expression** — no second arithmetic path. |
| `apply_recommended_orientation` | The gate-constrained pick, the monotonicity guard, the counterfactual. |
| `export_variant_mesh`, `export_latticed_variant`, the analyze path's `_smoothed.stl` | Baked. The lattice goes through `RotatingTriangleSink`, so **peak memory stays flat in the output size** — a gigabyte of struts is still a disk cost, not a memory cost. |
| `test_bake_build_orientation.cpp` | **NEW.** 166 checks across V1–V9, end to end through `run_job`. |

**Exactness, by construction.** For the six cube axes the rotation is applied as
`out[i] = sign[i] * v[perm[i]]` — a permutation and a multiplication by ±1, never a
matrix product. No sums, so no rounding and no signed-zero cancellation. Cube-axis
detection is **exact equality**, deliberately not a tolerance: a near-axis direction
takes the general path and is honestly reported as lossy, so V4 can never pass
vacuously.

---

## TESTS

* **Core: `ctest` 91/91, 100% passed — run twice** (447.9 s and 420.8 s;
  `evidence/.../ctest_run{1,2}.txt`). 90 before; the +1 is
  `bake_build_orientation`, whose own suite is **166 checks, 0 failures**.
* **App: 1028 tests, 3 failing test cases — all three PRE-EXISTING**, and the same
  three PR 271 reported: the 3MF-import tests that need `lib3mf` provisioned in the
  checkout (this worktree carries the 3MF-free macOS slice, and the run says so
  itself). **This change adds zero app test failures.** The `BuildOrientation`
  suite is **13/13** — PR 271's 9, unchanged and still passing, plus 4 new ones
  covering the auto-apply decode, an old receipt still reading as "nothing
  applied", the gate-constraint flag, and the `"off"` key the app must keep
  sending. *(`swift test`'s summary line counts ASSERTIONS, so it reads "8
  failures" for those three tests; PR 271's handoff counted tests and said 3. Same
  three tests.)*
* **Two core tests needed their INPUTS corrected, and no assertion was touched.**
  `git diff` on both shows zero removed `CHECK`s:
  * `test_analyze_fixed_design` hand-derived `unit(-gravity)` as "the exact input the
    recovery block used". With auto-apply the run certifies at
    `v.applied_build_dir`, so that reconstruction was simply feeding a *different*
    input and comparing. It now reads the applied direction and prints both, so a
    future coincidence cannot make the check vacuous. All 22 assertions still run.
  * `test_designbox_reduction` pins the orientation posture off, because it arms the
    production-WITHDRAWN `margin_floor_multiple` (see the residual below). Its six
    assertions are untouched.
* The vendored `TopOptCore.xcframework` in a fresh worktree is stale and must be
  rebuilt (`app/scripts/build_core.sh`) before the app suite links — a pre-existing
  worktree condition, not something this change introduced.
* Two unrelated gotchas worth knowing before reading a dirty `git status` after an
  app-suite run: `ContactShadingTests` **rewrites**
  `docs/handoffs/assets/120_contact_cylinder_{before,after}.png` every run (reverted
  here; nothing in this change touches them), and `build_core.sh` rewrites
  `app/TopOptKit/vendor/`.

---

## RESIDUALS — what this does NOT establish

* **A DECLARED orientation is still advice-only in the file** under the default
  `auto` mode. That is V2's requirement, not an oversight — someone who named a
  direction may need a face down for finish or a part in existing fixturing. The
  escape hatch is `"bake_build_orientation": "always"`, which is opt-in, tested, and
  never the default because it changes the exported bytes of a job that declared a
  direction.
* **Off-axis orientations are the COMMON case, and they are lossy.** 20 of the 26
  candidates are off-axis, and the auto-choice reaches them in practice — the
  cantilever fixture in `test_analyze_fixed_design` picks `(-0.707, 0, -0.707)`.
  Those exports are rounded dot products, not a relabelling: direction-exact to
  9.5e-16 but not coordinate-exact. `exact_axis_permutation` on the receipt is how a
  reader tells which they have. Whether a part tilted 45° on the plate is a *good*
  suggestion is a separate question this task did not measure.
* **Per-rung orientations may differ.** Each rung is a different design with its own
  overhangs, so each is certified and rotated in its own best orientation. Each file
  is self-consistent; the published receipt describes the rung the user exports.
* **`z_knockdown` is still unsourced** (PR 259's caveat, inherited). Every interlayer
  margin divides by it, so every verdict auto-apply protects or rescues shares that
  dependency.
* **The ladder floor interacts with orientation.** With the production-WITHDRAWN
  `margin_floor_multiple` armed (test fixtures only), a better-oriented rung 0 is
  stronger and clears the comfort floor sooner, shortening the ladder. Measured on
  the design-box fixture; production leaves that dial at `+infinity`, so it does not
  bite there. Recorded because it will surprise whoever arms it next.

---

## `emit_3mf` — the question asked, answered, NOT flipped

*(Reported per the task's request; nothing was changed.)*

**Yes, it is a one-line default change** — `core/include/topopt/job.hpp:144`,
`bool emit_3mf = false` → `true`. But three things make it a decision rather than a
formality, and one of them corrects the premise:

1. **PR 201's "3MF ≈ 45% of STL" does not apply to this key — and I measured it.**
   `emit_3mf` is *lattice-only*, and the lattice 3MF is written by
   `StreamingThreeMfWriter`, whose own header says: *"a STORED zip is uncompressed,
   so a streaming .3mf is **larger** on disk than a lib3mf-deflated one."* PR 201's
   ratio was measured on the lib3mf-deflated `write_3mf_file`, which serves the
   **solid** variant export — a different key (`output.mesh_format`). Measured on the
   committed `plate_bore` fixture, both formats from one generator pass:

   | file | bytes |
   |---|---|
   | `variant_060_lattice.stl` | 1,942,484 |
   | `variant_060_lattice.3mf` | **8,510,037 — 4.38× LARGER** |

   Flipping the default would add a file 4.4× the size of the one already written,
   not one 45% of it. `evidence/.../emit_3mf_question.txt`.
2. **The app is unaffected either way.** `RemoteRunner` always sends `emit_3mf`
   explicitly from the user's toggle, so the core default only governs CLI jobs that
   omit the key.
3. **It is safe to flip mechanically** — the streaming writer depends on nothing but
   the stdlib, so it works on the lib3mf-free build too. One app-side fixture
   (`LatticeModeTests.swift:137`) asserts the app's own `false` and would want a look.

**Recommendation: do not flip on the size argument — it points the other way.** If
3MF-by-default is wanted for *format* reasons (metadata, colour, a slicer that
prefers it) that is a separate and legitimate case, but it costs disk rather than
saving it. The honest version of "make the lattice 3MF small" is to teach
`StreamingThreeMfWriter` to DEFLATE, which is its own piece of work.

**Nothing was changed. The default is still `false`.**

---

## PLAIN LANGUAGE

Until now, the software worked out which way up your part should be printed, wrote
that answer down in a report, and then exported a file that knew nothing about it.
The file came out in whatever orientation the original CAD model happened to be in.
Your slicer then put the part on the bed however it liked — most slicers will happily
lie it flat or "auto-orient" it — and the strength certificate you'd just been shown
was describing a *different object* from the one about to be printed.

That matters because orientation is not cosmetic on a 3D print. A printed part is
much weaker between its layers than along them, so which way up it sits changes how
strong it actually is. The previous piece of work measured this on the test part: the
orientation the software used to assume makes it seven to nine times weaker in the
direction prints actually break, needs support material where the good orientation
needs none, takes six times as many layers — and at the finer setting, **fails its
own strength check when the good orientation passes it.**

So this change does three things.

**It turns the part.** The exported file is now physically rotated so the orientation
it was certified in is "up" in the file. Not a note attached to the file — the actual
corner coordinates are moved. A slicer can rearrange your plate all it likes; it
cannot un-rotate geometry. (I checked that the turning is exact: for the six
straight-on orientations, every coordinate in the exported file is the same number as
before, just moved to a different axis or with its sign changed. I compared 8,640
corners on the solid part and 117,636 on the lattice version — not one drifted.)

**It picks an orientation when you haven't.** If you never said which way up to print
it, the software now chooses the best one, certifies *that* one, rotates the file to
match, and tells you — loudly — that it did. If you *did* say, it uses yours exactly
and doesn't touch your file at all; I proved that produces byte-for-byte the same
output as before this change, and made it structurally impossible for the automatic
choice to override you.

**And here is the part I want to flag, because it changed my mind halfway through.**
The task asked me to apply "the best candidate". The existing scorer's "best" is a
compromise across six things — strength, support material, print height, and so on —
and it deliberately doesn't just maximise strength, because those genuinely pull in
different directions. That's the right way to *advise* someone. It turned out to be
the wrong way to *decide for* them: on one of the test parts, applying it as-is threw
away a lighter version of the part that would have passed its strength check
perfectly well. Nobody asked to trade a working part for a bit less support material.
So I changed the rule: when choosing on your behalf, the software only considers
orientations that **pass** the strength check, and picks the best of those. The
result is a guarantee I can state simply — **the automatic choice can rescue a part,
it can never sink one** — and there's a test whose only job is to fail if that ever
stops being true. The compromise-based recommendation is still shown to you, and when
it differs from what was applied, you're told, along with why it wasn't used.

**One thing I deliberately did not enable.** The iPad and Mac apps still work the old
way for now. The reason is specific: the app downloads the exported file and draws it
underneath things that are all in the *original* coordinates — the gravity arrow, the
regions you painted, the stress colouring. If I rotated the file but not those, every
one of them would land on the wrong part of the part. That's a worse problem than the
one I'm fixing, so I stopped short rather than ship it. The app still shows you the
recommendation exactly as it did before, and I've built and tested the display for
the new behaviour so it's ready; what's missing is teaching the 3D view about the two
coordinate systems, which is its own piece of work. I've written down exactly which
three lines come out when someone does it.

Everything else is unchanged: the strength calculation, the tolerances, the pass/fail
rule. Nothing about how the part is analysed moved — only which way up the file comes
out, and who gets told about it.
