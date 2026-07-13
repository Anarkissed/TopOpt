# Diagnosis 064 — anchors eaten + near-zero stress regardless of load

**Track:** diagnostic (READ-ONLY). No source/test/ROADMAP/DECISIONS/fixture file
was modified. No code changed, no PR opened, no box checked. The only file
written is this report. All work done in worktree
`.claude/worktrees/gifted-sammet-89ab09`.

**Problem under investigation:** the user tags anchors (a face + its screw holes)
and a load, optimizes, and (a) the optimizer removes the anchor material and the
holes — the exact region meant to be frozen — and (b) every result shows ~1 MPa
peak (≈3 % of yield) *regardless* of the load magnitude. Also: the final result
has floating, disconnected pieces.

This report supersedes the *interpretation* of the earlier
[059-DIAGNOSIS-loadcase-and-optimize.md](059-DIAGNOSIS-loadcase-and-optimize.md)
(same class of symptoms) and answers the maintainer's framing directly.

---

## TL;DR — cause vs. effect

| # | Symptom | Verdict | Confidence |
|---|---------|---------|-----------|
| 1 | **Anchor / holes "eaten"** | **Real defect, but not a dropped BC.** The anchor IS frozen — only **one voxel deep** (`tag_step_face` tags the surface skin, not a shell), so the *bulk behind the anchor is Active and removed*. The reduction ladder then walks to its lightest rung and strips ~74 % of the bulk, isolating the frozen skin. On display, `keep_largest_component` **discards** the now-isolated anchor/hole skins — so a region whose density is pinned to 1 still *vanishes from the mesh*. | High |
| 2 | **~1 MPa regardless of load** | **Cannot be settled from code alone — two live causes, one benign one real.** (a) BENIGN: the load reaches the solver on the STEP path at full magnitude; ~1 MPa is correct physics for a large lightly-loaded part, and the stress map is **scaled to yield**, so a 2× load change (1→2 MPa) is invisible at the bottom of a 0–40 MPa bar → *looks* load-invariant. (b) REAL: if `external` ends up empty, the driver **silently falls back to self-weight**, which IS truly load-invariant. A one-line runtime log discriminates. | Medium |
| 3 | **Floating disconnected pieces** | **Effect of #1.** Aggressive removal isolates the pinned anchor/hole skins and thin members; the *playback* keyframes are raw marching cubes (no cleanup) so islands are visible while scrubbing; the final mesh is single-component only because `keep_largest_component` deletes the rest. | High |

**Do #1 and #2 share a root cause?** **Partly.** Both are downstream of *low
computed stress → huge margin → the ladder walks to its lightest rung (0.26 VF) →
over-removal.* That single mechanism produces the eaten-anchor look (#1) and the
floating pieces (#3). #2's *magnitude* is a separate question (physics vs. an
empty-load fallback) that only a runtime log settles — but if #2 is the empty-load
fallback, then #2 is *also* an upstream cause of #1 (even smaller stress → even
bigger margin → even more removal).

**Direct answer to the maintainer's framing (SET UP / DATA / ALGORITHM):**
- The **FEA + stress + SIMP math is correct** — this is *not* an algorithm-physics bug.
- The **data path is correct on the STEP path** (load + anchors reach the solver);
  the one real data defect is that an empty load case **silently** becomes
  self-weight instead of warning.
- The two real defects are in **SET UP / POLICY**: (i) anchors are frozen only a
  1-voxel skin (the N-voxel passive-shell tool exists but is unused), and (ii) the
  reduction ladder has **no coherence / minimum-margin floor**, so a
  lightly-stressed part is stripped to its lightest rung. Plus a **display** defect:
  `keep_largest_component` silently deletes isolated frozen regions.

---

## How the app actually runs (the path that matters)

`RunModel.bridgeRunner` branches on file type
([RunModel.swift:348](../../app/TopOptKit/Sources/TopOptFlows/RunModel.swift:348)):

- **STEP** (`.step`/`.stp`, case-insensitive —
  [RunModel.swift:50-52](../../app/TopOptKit/Sources/TopOptFlows/RunModel.swift:50))
  → `minimizePlasticLoadCase` → `run_minimize_plastic_loadcase` (anchors→Fixture,
  loads→traction). **This is the intended path.**
- **STL** → `minimizePlastic` → `run_minimize_plastic`, which **ignores the user's
  anchors and loads entirely**: it hardcodes a **min-x Fixture clamp**
  ([bridge.cpp:390-401](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp:390))
  and **self-weight** ([bridge.cpp:428](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp:428)).

The import dispatch is *also* case-insensitive and uses the same suffixes
([TopOptKit.swift:230-236](../../app/TopOptKit/Sources/TopOptKit/TopOptKit.swift:230)),
so a STEP file that can be face-selected also routes to the STEP run path — there
is **no format/case mismatch** between "can select faces" and "which run path."
**Implication:** if the user could tag anchor *faces* at all, they are on STEP and
`run_minimize_plastic_loadcase` is what ran. (An STL returns `nil` from
`FaceSelection.pick`, [FaceSelection.swift:38-42](../../app/TopOptKit/Sources/TopOptFlows/FaceSelection.swift:38),
so faces can't be tagged there.) **First thing to confirm at runtime: the imported
file's extension** — the whole diagnosis forks on STEP vs STL.

---

## 1 — Anchor → frozen/passive: mechanism is present but too shallow

**The freeze mechanism is real and correct.** On the STEP path the bridge tags the
anchor B-rep faces `Fixture`
([bridge.cpp:474](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp:474)) and
clamps their nodes
([bridge.cpp:519-529](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp:519)).
The core turns every `Load`/`Fixture` voxel into `FrozenSolid` in the effective
mask ([simp.cpp:833-834](../../core/src/simp/simp.cpp:833)) and **pins its physical
density to 1** ([simp.cpp:854](../../core/src/simp/simp.cpp:854), applied at
[simp.cpp:1069](../../core/src/simp/simp.cpp:1069)); `check_v3` then verifies
Load/Fixture voxels stay ≥ 0.9
([voxelize.cpp:272-284](../../core/src/voxel/voxelize.cpp:272)). So the anchor
voxels are *not* removed by the optimizer.

**But the frozen region is one voxel thick.** `tag_step_face` tags only voxels
whose centre is within **half a voxel edge** of the face surface
([step.cpp:240-241](../../core/src/io/step.cpp:240),
`thr2 = 0.25*h*h`). A flush planar anchor face → a single surface layer; a screw
bore → a thin cylindrical shell. The **material behind that skin is `Active`** and
is a free design variable. So "freezing the anchor" preserves a 1-voxel skin, not a
structural pad — the optimizer legally carves out everything the skin was attached
to.

**The tool to fix this already exists and is unused on the run path.**
`mask_step_face` freezes an **N-voxel-deep** passive shell (`depth_voxels`,
[step.cpp:270](../../core/src/io/step.cpp:270);
bridge wrapper [bridge.cpp:340](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp:340)),
which is exactly the MOD-F1 D7 "N-voxel passive shell so the optimizer cannot
remove the surfaces the BCs sit on" intent
([TopOptBridge.hpp:101-112](../../app/TopOptKit/Sources/TopOptBridge/include/TopOptBridge.hpp:101)).
`run_minimize_plastic_loadcase` **does not call it** — it uses the 1-voxel
`tag_step_face` only. The anchor keep-region is therefore structurally negligible.

**Verdict:** anchors are frozen, but only as a skin, so the *surrounding* material
(and thus the visible anchor boss + hole bosses) is eaten. **Where the fix goes:**
freeze an N-voxel pad around anchor (and load) faces — call `mask_step_face` /
extend `tag_step_face` depth in `run_minimize_plastic_loadcase` — and/or keep the
ladder from stripping the load path (see #2/#3).

## 1b — the hardcoded min-x clamp can still win

If **no** anchor face tags a voxel (`any_fixture == false`), the loadcase path
falls back to clamping the **min-x boundary**
([bridge.cpp:530-540](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp:530)) —
the same default the STL path always uses
([bridge.cpp:390-401](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp:390)).
In that case the user's anchor is *both* ignored as a BC *and* not frozen → eaten,
and the reaction is taken at min-x instead of the user's face. Static analysis says
a normal surface anchor face *does* tag voxels, so this is a fallback, not the
expected path — but it is the exact failure that produces "anchor eaten" most
starkly, and it is silent. **Confirm at runtime that `any_fixture` is true** (log
the Fixture voxel count).

## 2 — Load magnitude/direction → solver: wired on STEP; the fallback is the trap

**On the STEP path the load is delivered at full magnitude** (independently
re-verified here and in 059):
- UI → Newtons: weight stored in **kgf**, converted `kg * 9.80665`
  ([ForceModel.swift:230-231](../../app/TopOptKit/Sources/TopOptFlows/ForceModel.swift:230));
  100 lb ≈ 445 N. Clamped to [0.1, 500] kgf, never silently zero.
- Assembled into `BridgeLoadCase.load_forces` per group
  ([TopOptKit.swift:385-398](../../app/TopOptKit/Sources/TopOptKit/TopOptKit.swift:385)).
- Bridge spreads each non-zero group's force as a **consistent traction** over its
  tagged faces ([bridge.cpp:499-501](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp:499),
  `traction_loads`) into `external_loads`
  ([bridge.cpp:562](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp:562)).
- `minimize_plastic` uses `external_loads` when non-empty and recovers stress from
  that same solve
  ([minimize_plastic.cpp:138-142](../../core/src/simp/minimize_plastic.cpp:138),
  [:251](../../core/src/simp/minimize_plastic.cpp:251)).
- **Units are consistent** (N, MPa, mm) and, correctly, **no** g/cm³→t/mm³
  pre-scale is applied to external loads (that scale is self-weight-only,
  [bridge.cpp:566](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp:566)). No
  analogue of the old gravity-units defect exists on the traction path.

**The one code path that makes stress truly load-invariant.** If, for **every**
load group, the force is zero *or* none of its faces tag a solid voxel
(`any == false`, [bridge.cpp:491-498](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp:491)),
`external` is empty and `minimize_plastic` **silently falls back to self-weight**
([minimize_plastic.cpp:138-142](../../core/src/simp/minimize_plastic.cpp:138))
scaled at `gravity = 9.81e-6`
([bridge.cpp:566](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp:566)). That
self-weight is tiny and **independent of anything the user sets** → a fixed ~1 MPa
regardless of load. This is the failure mode the symptom description fits *exactly*
if it is literally invariant.

**Why code alone can't decide between "physics" and "empty-load fallback":** the
stress overlay is **scaled to the material yield**
([ResultsModel.swift:290-306](../../app/TopOptKit/Sources/TopOptFlows/ResultsModel.swift:290),
"scaled to 55 MPa yield"). At 1–2 MPa the whole part sits in the bottom ~3–5 % of
the bar (deep blue). A *real* 45→100 lb change moves 0.9→2.0 MPa — invisible on
that scale. So "regardless of load magnitude" is produced **both** by a genuinely
dropped load **and** by a correctly-delivered small load. The symptom is not, by
itself, evidence of a bug. **Only the runtime log below settles it.**

**Verdict:** not a units bug; not a wrong-region load. Either correct-but-small
physics (masked by the yield-scaled colormap) or the silent self-weight fallback.
The silent fallback is itself a defect — it should warn, not masquerade as a result.

## 3 — BC wiring / hardcoded fallback

Covered in **1b**: yes, a hardcoded **min-x clamp** fallback still exists and wins
whenever no Fixture voxel is tagged (loadcase path
[bridge.cpp:530-540](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp:530)) or
whenever the run is on STL (always,
[bridge.cpp:390-401](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp:390)). On a
normal STEP anchor it does not fire, but it is silent when it does.

## 4 — Stress recovery: physics is right; the recovery code is not the bug

The stress recovery is a standard penalized re-solve on the converged density with
per-voxel Hex8 von Mises over printed voxels
([minimize_plastic.cpp:251-283](../../core/src/simp/minimize_plastic.cpp:251)); it
is fed the same `loads` the optimizer used. There is no zeroing, mis-scaling, or
wrong-region bug in recovery. So the near-zero value is **input-driven**: either
the load is genuinely small (physics) or it is self-weight (fallback). The
recovery math itself is correct.

## Floating disconnected pieces — connectivity IS applied, and that's the twist

`keep_largest_component` **is** applied to the final variant mesh via `check_v3`
([voxelize.cpp:266-268](../../core/src/voxel/voxelize.cpp:266)), and the bridge
ships exactly that cleaned mesh (`v.mesh()`,
[bridge.cpp:150](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp:150)). So the
*final* mesh is single-component by construction — genuine floating islands should
not appear in the final still. Two real sources remain:

1. **Playback keyframes are raw.** The history frames are
   `marching_cubes(...)` with **no cleanup**
   ([minimize_plastic.cpp:229-231](../../core/src/simp/minimize_plastic.cpp:229)),
   and the results screen scrubs through them
   ([ResultsScreen.swift:151-155](../../app/TopOptKit/Sources/TopOptFlows/ResultsScreen.swift:151)).
   Disconnected islands are visible *during* playback — expected, but reads as
   "floating pieces."
2. **`keep_largest_component` deletes the isolated frozen anchor.** Once the ladder
   removes the bulk, the pinned 1-voxel anchor/hole skins become **separate mesh
   components** and are dropped as minority islands
   ([mesh.cpp:518-540](../../core/src/mesh/mesh.cpp:518)). So a region pinned to
   density 1 **still disappears from the displayed mesh** — this is a second,
   independent mechanism for "anchor eaten," and if a frozen skin is instead the
   *largest* island, the *real* structure is the part that vanishes.

**Where a fix goes:** don't rely on `keep_largest_component` to hide incoherent
output — keep the structure connected in the first place (freeze an N-voxel pad
that ties anchors into the body; floor the ladder). If islands remain, surface a
warning rather than silently deleting them.

---

## Confidence-ranked findings

1. **(High)** The eaten anchor/holes are the result of **low stress → ~20× margin
   → the ladder `{0.68,0.52,0.38,0.26}` (margin_stop 1.5, default) walking to its
   lightest rung** and stripping ~74 % of the bulk, combined with the anchor being
   frozen only a **1-voxel skin**. Neither the FEA nor the freeze *mechanism* is
   wrong; the ladder policy + freeze depth are.
2. **(High)** `keep_largest_component` **deletes** the isolated frozen anchor/hole
   skins from the displayed mesh (mesh.cpp:518), so "retained at density 1" does
   not guarantee "visible in the result." This compounds #1.
3. **(High)** On the STEP path the user's load and anchors **do reach the solver**
   at full magnitude with correct units; there is no traction units/region bug.
4. **(Medium)** The ~1 MPa is **either** correct physics for a large lightly-loaded
   part (made to look flat by the yield-scaled overlay) **or** the silent
   self-weight fallback (`external` empty). Cannot be distinguished from code; a
   one-line log settles it.
5. **(Medium)** If the imported file is actually **STL**, all symptoms are fully
   explained with certainty: `run_minimize_plastic` hardcodes a min-x clamp +
   self-weight and ignores every anchor/load the user set. Confirm the file
   extension first.
6. **(Low/Medium)** The silent self-weight fallback
   (minimize_plastic.cpp:138) and the silent min-x clamp fallback
   (bridge.cpp:530) are latent traps: both should warn instead of masquerading as
   valid results.

---

## Proposed fixes (in words — NOT applied)

- **Freeze a pad, not a skin (SET UP).** In `run_minimize_plastic_loadcase`, freeze
  anchor (and load) faces to an **N-voxel depth** using the existing
  `mask_step_face` / a depth-parameterized tag, so the keep region is a structural
  pad the optimizer must route load through — not a 1-voxel film. This alone stops
  the anchor/hole bosses from being carved away around the frozen skin.
- **Floor the ladder (ALGORITHM/POLICY).** The ladder should not recommend its
  lightest rung when the margin is enormous. Cap how far it walks (e.g. stop when
  margin ≫ margin_stop, or require a minimum retained volume / connected load path),
  so a lightly-loaded part keeps a coherent structure instead of being stripped to
  0.26 VF. This is a maintainer product call; it is where "arbitrary removal"
  actually lives.
- **Don't silently fall back (DATA).** Make an empty `external` a **surfaced
  warning** ("no load reached the solver — using self-weight"), not a silent
  substitution (minimize_plastic.cpp:138). Likewise surface the min-x clamp
  fallback (bridge.cpp:530) instead of clamping silently.
- **Stop hiding incoherence in the display.** Don't lean on
  `keep_largest_component` to make an over-removed result look clean; if it drops
  frozen anchor voxels or a large island, warn. Consider showing retained-but-
  disconnected regions rather than deleting them.
- **(Optional) Fix the overlay's floor perception.** A part far below yield reads as
  "zero." Consider an auto-ranged or log stress scale (opt-in) so a real load
  change is visible, distinct from the yield-referenced legend.

## Runtime checks that settle the open question (add a temporary log, then remove)

1. **File type** — log `request.modelPath` / `isStepModel` at
   [RunModel.swift:348](../../app/TopOptKit/Sources/TopOptFlows/RunModel.swift:348).
   STL ⇒ symptoms are fully explained (anchors/loads ignored); stop here.
2. **Empty-load vs. physics (settles #2)** — after the group loop at
   [bridge.cpp:507](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp:507), log
   `external.size()` and `Σ|external.value|`. Non-empty, sum ≈ your applied N ⇒ load
   delivered (the ~1 MPa is physics; the overlay hides the change). Zero ⇒ real
   dropped-load bug — find which group emptied (`force==0` at
   [bridge.cpp:491](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp:491) or
   `any==false` at [bridge.cpp:498](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp:498)).
3. **Anchor actually frozen (settles #1b)** — log the Fixture voxel count / whether
   `any_fixture` is true at
   [bridge.cpp:518-529](../../app/TopOptKit/Sources/TopOptBridge/bridge.cpp:518).
   Zero ⇒ the min-x fallback fired and the user's anchor was ignored.
4. **Ladder mechanism (settles #1/#3)** — log each rung's `margin.worst_case` and
   `requested_volume_fraction` at
   [minimize_plastic.cpp:344-345](../../core/src/simp/minimize_plastic.cpp:344). A
   ~20× margin on every rung down to 0.26 confirms the over-removal mechanism.

## What could NOT be determined from code alone

- Whether the imported part is STEP or STL for this repro (forks the whole
  diagnosis — check #1 above first).
- Whether #2 is correct physics or the empty-load fallback (needs check #2).
- The exact geometry-dependent point at which the frozen skin becomes an isolated
  island `keep_largest_component` drops (needs the actual part + a mesh-component
  count per rung).
