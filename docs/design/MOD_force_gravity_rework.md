# MOD-F1 — Force & Gravity Interaction Rework

**Target:** TopOpt design concept (workspace screen) and, downstream, the M7 iPad shell.
**Status:** Proposed. Supersedes the Force tool, the arrow-drag gesture, and the modal weight dialog.

---

## 1. Problem

The current workspace uses a desktop-CAD mode system (Orbit / Faces / Force) on a touch device. Three specific failures:

- **P1 — Vector-aiming on glass.** Drawing a 3D force direction by dragging on a 2D screen is imprecise; the 45° snap is a patch over the symptom, not a fix. No successful touch CAD app (reference: Shapr3D) asks users to freehand a 3D vector; all constrain drags to one degree of freedom.
- **P2 — Leaking data model.** "Groups with no arrows are treated as fixed anchors" requires a sentence of explainer copy in the panel. If the UI must explain an implicit rule, the rule is wrong at the UI layer.
- **P3 — Meaningless default direction.** Loads should default to gravity, but imported CAD files are modeled in arbitrary orientations (~90% of real files). Without a declared gravity direction, "down" is undefined and every load starts wrong.

## 2. Locked design decisions

- **D1 — No Force tool. No modes.** Drag always orbits; tap always selects faces. The tool segment control is deleted.
- **D2 — Gravity setup is a first-class setup step.** Immediately after import, before any selection: prompt *"Which way is down? Tap the face that points at the floor in real life."* On tap:
  - `gravity` = outward normal of the tapped face, stored as a unit vector in **model space** (survives re-orientation).
  - The model animates ("settles") so gravity aligns with world −Y; a ground grid and soft contact shadow fade in. Respect `prefers-reduced-motion` (snap instead of animate).
  - A persistent **gravity chip** (top-right) shows state and offers *Change*, which re-enters the setup prompt at any time.
  - Gravity (use orientation) is **never** conflated with print orientation (build orientation). Print orientation remains a results-screen concern. Copy must not mix the two.
- **D3 — Explicit Anchor | Load chip replaces the implicit rule.** When a face selection exists, a floating chip appears beside it: **[ Anchor ] [ Load ]**. The user declares intent; the panel explainer copy from P2 is deleted.
- **D4 — Loads spawn correct, not blank.** Choosing *Load* creates a force at the group centroid pointing **along gravity** (world −Y). Direction is then adjusted only through constrained affordances:
  - Snap row on the active load: **Gravity** (world −Y) · **Push** (−face normal) · **Pull** (+face normal).
  - v2 (shell, not prototype): a single-DOF rotation ring at the arrow base for custom directions, 15° detents, haptic ticks, second ring appears only after the first commits. Never a freehand drag.
- **D5 — Weight edits in place. No modal.** The weight is a pill on the arrow itself: **horizontal scrub** to change the value (Procreate-style), **tap** to type. Global kg/lbs toggle; store kg (kgf) internally. The weight dialog is deleted.
- **D6 — Arrow rendering convention.** If the force has a component *into* the face (`dot(dir, n) < 0`), draw tip at the application point; otherwise (pulling/hanging) draw tail at the application point. Tapered shaft, group color, weight pill at the tail end.
- **D7 — Loads are tractions, not points; BC faces are passive.** A load group hands the solver a uniform traction over the combined area of its selected faces — the centroid point-force shortcut in the design concept is a prototype-only visual and must not reach the core. All load and anchor faces are frozen as an N-voxel passive shell via the existing design-mask array. Internal load paths (ribs, gussets, webs) are never specified by the user or the UI — they are outputs of the compliance solve.

## 3. Interaction spec (happy path)

1. Import completes → gravity prompt. User taps the floor-facing face → model settles onto ground grid; gravity chip appears.
2. User taps 1–n faces → they tint with the next group color; chip **[ Anchor ] [ Load ]** floats beside the selection.
3. User taps **Anchor** → group locks (distinct anchor tint + lock glyph). Taps elsewhere start the next group.
4. User selects the load faces, taps **Load** → arrow appears along gravity with default weight; snap row + weight pill visible while the group is active.
5. User scrubs the pill to 2.5 kg (or taps to type). Optimize enables once ≥1 anchor and ≥1 load exist, with a live summary ("1 anchor · 2 loads").
6. Tapping any face of an existing group re-activates it (chip / snap row / pill return). Tapping a face already in the active group removes it; an empty group is deleted. A remove control on the active chip deletes the group.

## 4. Out of scope for this MOD

- Rotation-ring gizmo implementation (spec'd in D4, ships with the shell, not the HTML concept).
- Hole-aware face grouping is **in scope and unchanged**: it carries over from the existing spec exactly as designed and must work with the new Anchor | Load chip (see acceptance criteria). Only its *implementation* is outside this MOD — no rework needed.
- Torque/moment loads, distributed pressure, multiple load cases.
- Any solver or results-screen change. Print-orientation UI is untouched.

## 5. Acceptance criteria

- [ ] The Orbit/Faces/Force segment control no longer exists; orbit and select coexist without a mode switch.
- [ ] A new import cannot reach the selection stage without gravity being set or explicitly deferred; gravity is editable afterward from a persistent chip.
- [ ] Setting gravity visibly settles the model onto a ground plane with a contact shadow; reduced-motion users get an instant transition.
- [ ] No implicit anchor rule and no explainer copy for it; anchors exist only via the Anchor action.
- [ ] A new load's initial direction equals world −Y regardless of imported model orientation.
- [ ] Direction can only be changed via snap options (and, in shell v2, the constrained ring) — no freehand vector drag anywhere.
- [ ] Weight is editable by scrub and by typing, in place, with no modal dialog in the workspace.
- [ ] Optimize is disabled until ≥1 anchor and ≥1 load exist, and its label summarizes the load case.
- [ ] Loads are applied to the solver as uniform traction distributed over the group's combined selected face area (consistent nodal loads) — never as a centroid point force. If the physical load contacts multiple faces, one group with one weight covers them all; the traction spreads over the total area.
- [ ] All load and anchor faces are marked passive (non-design) as an N-voxel shell in the existing design-mask array, so the optimizer cannot remove the surfaces the boundary conditions are applied to.
- [ ] Hole-aware face grouping ("tap inside a hole to grab the whole hole") works for both Anchor and Load groups; selecting a bolt hole selects its full cylindrical face set (plus counterbore/chamfer faces where present) as one unit.
