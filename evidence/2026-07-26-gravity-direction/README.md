# Device evidence — gravity direction widget (BAR V6)

iPad Pro 11-inch (M5) simulator, TopOpt Debug build, 2026-07-26. Project: "Wall Bracket"
(STL). Full write-up: `docs/handoffs/2026-07-26-gravity-direction.md`.

| File | Shows |
|------|-------|
| `01-persistent-indicator-and-chip.png` | Persistent "↓ down" arrow in the viewer + `Gravity set · −Z · Change` chip on one row (V5). |
| `02-setup-pointing-widget.png` | Setup phase: "Which way is down?" banner, the draggable blue arrow, and the magnet + confirm (✓) cluster. |
| `03-drag-custom-direction.png` | The arrow dragged to a custom off-axis direction; the cluster tracks the tip; no snap badge (correct — off-axis). |
| `04-snapped-to-axis.png` | The arrow dragged onto an axis → the **"Snapped to −Z"** badge appears (exact snap, V2). |
| `05-facetap-custom-and-resettle.png` | Face-tap shortcut still works: a tap on a face set gravity from its normal → the part re-settled, chip reads `custom` (req 4 / V4). |
| `06-setup-seeded-clean-after-fix.png` | After the fix: re-opening setup seeds the arrow to the current direction (points down) with **no stale badge** (see handoff "Bug found"). |
| `07-confirm-committed-back-to-edit.png` | Tapping ✓ commits the direction → back to edit, `−Z` restored, persistent indicator shown. |
