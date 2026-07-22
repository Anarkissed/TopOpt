# 124 — Face protection primitive ("Protect": preserve a face's own skin)

**Outcome: IMPLEMENTED end-to-end (core + seam + app), all gates green, evidence
delivered.** A new protection primitive **"Protect"** — the polar opposite of
keep-clear. Where a keep-clear reserves EMPTY space in FRONT of a face
(`FrozenVoid`), a Face protection means **"the optimizer may not TOUCH this
face"**: it freezes the part's OWN material solid behind the selected face
(`FrozenSolid` preservation), footprint-only, to **one global depth** governing
every protection in the project. Opt-in by construction — no protection declared
is byte-identical (structurally + parity-proven), Gate-V2 untouched.

**Track:** core + seam + app. **Territory:**
- `/core/` — `include/topopt/{loadcase,job}.hpp`, `src/cli/{loadcase,job,run_job}.cpp`,
  two new validation tests.
- seam — `app/TopOptKit/Sources/TopOptBridge/{bridge.cpp,include/TopOptBridge.hpp}`,
  `Sources/TopOptKit/TopOptKit.swift`.
- app — `Sources/TopOptFlows/{ForceModel,ProjectModel,AppModel,RunModel,RemoteRunner,
  WorkspacePlaceholder,WorkspaceChipLayout,MetalMeshView,ResultsModel,ResultsScreen,
  OutcomeStore}.swift`, one new test.

**Builds on:** 100 (the clearance seam this mirrors, opposite polarity), 082/064
(the anchor-pad `mask_step_face` FrozenSolid overlay this reuses), 080 (whole-
domain optimize — the part is Active, so a protection is meaningful), 103 (the
keep-clear ATTRIBUTE model this mirrors), 123 (conditional projection — asserted
not to thin the frozen skin). **Sequenced after** PR 152's conditional-projection
merge; branched from it (5671db0). Not concurrent with any other core task.

---

## The semantic (maintainer's spec, exact)

A Face protection freezes the part's own material solid behind the selected face
to a **shared depth**. It is `FrozenSolid` preservation covering **ONLY the
selected face's footprint** — not the plane slab's bounding rectangle, not
surrounding void. **One GLOBAL depth** governs ALL Face protections in the project
(a single number, editable, default ~2× min-feature = **5 mm**, shown once). This
NEVER frees void — it only freezes existing part solid (the handoff-100 part-
membership guard, run in reverse).

---

## Design: reuse `mask_step_face`, fold into the anchor-pad overlay

`mask_step_face` (step.hpp) already walks part-SOLID layers from a face and writes
`FrozenSolid` into a design mask — it is exactly the anchor pad's primitive. Face
protection reuses it verbatim:

- **`ProductionLoadCase`** gains `face_protection_face_ids` + one global
  `face_protection_depth_mm` (default `kFaceProtectionDepthDefaultMm = 5.0`).
- **`build_production_loadcase`** builds the FrozenSolid `design_mask` overlay when
  the anchor pad is wanted (`minimize_plastic`) **OR** any protection is declared
  (a protection is honored in BOTH ladder and single-`{0.9}` modes). Depth (mm) →
  voxel layers on the run's grid (`round(depth/spacing)`, floored at 1). Each
  protection is frozen into a per-face mask (to count THIS face's voxels honestly,
  not ones an anchor pad already froze) then OR'd into the shared pad.
- **Precedence is automatic.** `minimize_plastic` merges `design_mask` (pad +
  protection) into the effective mask BEFORE the clearance OR-step, and that step
  only sets `FrozenVoid` where `mask != FrozenSolid`. So a protection overlapping a
  clearance margin keeps the part solid — **FrozenSolid WINS over FrozenVoid**, now
  with a user-facing source.

### The honest edge (no silent over-claim)

A protection on a face whose solid is thinner than the depth freezes what exists
and **SAYS so**. `mask_step_face` walks solid layers, so it naturally freezes only
available material. The builder detects the thin case by freezing once at `depth`
and once at `depth+1`: an equal count means the face's solid was fully consumed
(thinner than / equal to the depth). `ProductionRunSetup::FaceProtectionReport`
carries `{face_id, voxels_frozen, depth_voxels, thinner_than_depth}` — the numbers
shown to the user are these numbers.

### The seam (123-lineage)

`BridgeLoadCase` gains `face_protection_face_ids` + `face_protection_depth_mm`
(<=0 → core default); `OptimizeResult` gains four parallel report arrays;
`bridge.cpp` unflattens the protections and copies the reports back. The CLI
`job.json` `loads` block gains `"face_protections": [ids]` +
`"face_protection_depth_mm"`; `RemoteRunner` serializes them identically, so a LAN
worker preserves faces byte-identically to the local bridge (production parity).

### The app (keep-clear-mirrored)

- **"Protect" chip** beside Anchor / Load / Keep clear (`anchorLoadChip`), plus a
  row **Protect affix toggle** (`protectAffixToggle`). Protect is a purely-explicit
  ATTRIBUTE on a group (`ForceModel.faceProtect` — no auto rule, unlike keep-clear).
  A protect-only selection is a complete declaration (does not block Optimize).
- **Crosshatch overlay** — a protected face carries a UNIQUE mint-teal
  (`protectFaceRGB`) recognised BY COLOUR in `viewer_fragment`, which lays a
  screen-space diagonal **crosshatch** over it (a "preserved" weave, deliberately
  unlike the red clearance VOLUMES that read "forbidden"). No new Metal buffers.
- **Global depth chip** (`faceProtectDepthChip`) appears in the settings cluster
  ONLY when ≥ 1 face is protected; it steps the ONE shared depth (3/5/8/12 mm).
- **Selections rows** show the Protect affix + a "Protect" kind label.
- **Results honesty** — the applied-clearances card extends to a "Protection
  applied" section (voxels frozen per face, + the thinner-than-depth note);
  `OutcomeCodec` persists `appliedFaceProtections` so a reopened run keeps the
  notes (the 108-class honesty round-trip discipline).

> **A6 reconcile note.** The chip additions in `WorkspacePlaceholder` are minimal;
> if A6's chip restyle merges later it owes a small reconcile in `anchorLoadChip` /
> the affix row.

---

## THE ONE RULE (opt-in by construction)

No protection declared ⇒ byte-identical: `face_protection_face_ids` empty leaves
the `design_mask` overlay exactly the anchor pad (or empty when `minimize_plastic`
is off), `face_protection_reports` empty, and the run bit-identical. The app omits
the `faceProtect` / `faceProtectDepthMM` snapshot keys and the `face_protections`
job.json keys entirely when nothing is protected. Gate-V2 untouched.

---

## Evidence

- **`face_protection` (new, Eigen).** Hand-built L-bracket, drives
  `minimize_plastic` directly. Under an aggressive ladder the protected face's skin
  is retained SOLID (all density 1.0) while the **unprotected twin skin erodes**
  (min 0.29) — the would-fail-against-a-stub survival proof. **Precedence:** a
  `FrozenVoid` clearance on the SAME skin voxels loses (skin stays 1.0).
  **Projection (123):** with the conditional gate armed AND firing, the frozen skin
  is still all 1.0 (projection never touches pinned FrozenSolid).
- **`face_protection_parity` (new, OCCT+Eigen).** On the shared
  `build_production_loadcase` seam: no protection ⇒ empty overlay + empty reports +
  bit-identical run (THE ONE RULE); a declared protection reports the face, voxels
  frozen (378 at 5 mm / spacing 2.5), and depth in voxels (2); a 1000 mm depth on a
  ~thin part flags `thinner_than_depth` and freezes exactly the part's own solid
  (2142 = full solid), no over-claim.
- **Core suite:** `ctest` 60/60 pass (incl. gate_v2, clearance_parity,
  conditional_projection, designbox_anchor_pad).
- **App suite:** `FaceProtectionTests` (12) pass — the affix logic, Codable +
  snapshot omission (THE ONE RULE), spec derivation, honesty-note formatting incl.
  thin/zero, `OutcomeCodec` round-trip + legacy-blob decode, and the **viewer MSL
  compiles** (the crosshatch does not break the shader). Full `swift test` green.

### Device QA checklist (maintainer)

1. Tap a face → **Protect** chip → face shows the mint **crosshatch**.
2. Protect ≥ 1 face → the **global depth chip** appears; edit it once, all
   protected faces share it.
3. Run → results show **"Protection applied"** with voxels frozen per face.
4. A run where the **protected face visibly survives** an aggressive rung while an
   unprotected twin erodes (mirror the `face_protection` fixture on a real part).
5. Confirm under a **fired conditional-projection** run the frozen skin is not
   thinned.

---

## Follow-ups / honest edges

- The crosshatch is a color-keyed screen-space effect (no new buffer);
  `WorkspacePlaceholder.protectFaceRGB` and the shader's `PROTECT_RGB` must stay in
  lockstep (documented at both sites).
- A face that is both an anchor AND protected shows the crosshatch (protection tint
  wins in `roleTints`); the label precedence is keep-clear > protect > pending.
