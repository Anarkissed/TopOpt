# §0 — THE STANDING BAR: the look, read off the topology screen

Screenshot: `00_topology_screen_the_standing_bar.png` (iPad Pro 13-inch, 1032×1376 pt).
Companions: `01_surface_stage_tray_with_pencil_button.png`, `01b_tray_crop.png`.

## What the screen actually looks like

| Rule | Value, as measured / as the tokens name it |
|---|---|
| Right-hand line | Everything on the right — the gizmo's glass, the chip column, the view toggles — sits on ONE trailing line, `PageChrome.edge = 24 pt`. |
| Gizmo | Top-right, its own glass panel, `PageChrome.gizmoClearance` reserved beneath it. Everything below it starts at `PageChrome.belowGizmo`. |
| Icon-only button | **40 × 40 pt** (the two view toggles) or **44 × 44 pt** (the Surface tray's tools) — a real touch target, never smaller. |
| Corner radius | `DS.Radius.pill` (999 → fully rounded) for buttons and chips; `DS.Radius.panelSmall = 20` for a panel that holds several. |
| Column spacing | `DS.Space.xs = 6` inside a tray, `DS.Space.s = 8` between two side-by-side toggles. |
| Panel padding | `DS.Space.xs = 6` inside the tray's glass, plus a 1 pt `DS.Color.strokePanel` border and `DS.Shadow.panel`. |
| ON colour | `DS.Color.accentDeep` filled — at **0.55 opacity** for a *view/mode* switch (wireframe, x-ray), at full opacity for an *armed tool* (the lit Select icon). |
| ON glyph | `DS.Color.textPrimary`. |
| OFF glyph | `DS.Color.textTertiary`, on `Color.clear` — no filled background at all. |
| Glyph weight | `.system(size: 17, weight: .semibold)` in the tray; 15 pt semibold in the smaller 40 pt toggles. |
| Text on the stage | Exactly ONE line, `DS.TypeScale.caption`, `textTertiary` (or `DS.Color.warning` when it is a refusal), right-aligned in a 160 pt column to the LEFT of the tray. |
| Primary action | One filled blue pill, bottom-right. There is only ever one. |
| Chips | Pill, dark translucent, icon + label, stacked bottom-right on the same 24 pt line. |

## §0(b) — the pencil button against that list

**The pencil button is the only new control in this task.** It is a *mode* switch, so
it is built to the wireframe/x-ray pattern and sits with them below the tray's divider,
not in the tool well above it:

- 44 × 44 pt frame — matches the tray's other buttons. ✓
- `DS.Radius.pill` corner, `.continuous` style. ✓
- `applepencil` SF Symbol at `.system(size: 17, weight: .semibold)` — same glyph metrics as
  the wireframe `grid` and x-ray `square.stack.3d.up` directly above it. ✓
- OFF: `DS.Color.textTertiary` glyph on `Color.clear`. ON: `DS.Color.textPrimary` glyph on
  `DS.Color.accentDeep.opacity(0.55)` — the *view/mode* opacity, not the armed-tool one,
  because it is not a tool. ✓
- In the same `DS.Space.xs` column, inside the same panel, on the same 24 pt trailing line. ✓
- `accessibilityLabel("Pencil only")`. ✓
- Adds no text of its own; when it is on but inert it borrows the stage's one hint line.
  See `03_pencil_mode_on_no_pencil_seen.png`. ✓

Nothing new was placed anywhere else on the screen. The bottom-right chip stack was
not touched — that column belongs to `lattice-stage-repair`.
