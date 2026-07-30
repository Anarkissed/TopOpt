# B10 — density at rest, MEASURED

Measured on the BUILT page (LatticePage.swift, captures in this directory at exact
iPad-11" point sizes 1366×1024 / 1024×1366) and on the CURRENT panel it replaces
(LatticeControlsPanel.swift as of the parent commit, 300 pt column — source
measurements, since the panel is deleted by this PR).

Capture caveat, stated up front: the PNGs are the repo's established offscreen
ImageRenderer captures (the numeric-input / plane-extents precedent). ImageRenderer
cannot draw platform-backed controls, so Toggles and Sliders appear as placeholder
glyphs (the yellow bars / circled icons); their SwiftUI frames — what the
measurements below use — are exact. The live iPad frame remains the maintainer's
on-device QA step, per the U7 precedent.

## Controls visible at rest, nothing selected (default state, landscape)

**Built page: 16.**
back (52 pt) · undo (52) · redo (52) · RUN SIM (48) · panel minimize (44) ·
7 ladder rows (62 each; row 1 embeds the infill switch) · 3 chips (46) ·
Optimize (64). Title pill, From Setup bar and hint bar are read-only.
(The workspace's always-on orientation gizmo is shared chrome, not the page's.)

**Replaced panel (open, with its two entry chips): 15 in a 300 pt column.**
Lattice chip · Struts chip · mode toggle · 7 topology cards (62×62 thumbnails,
horizontal scroller) · Cell chip · Min chip · Max chip · region Place/Clear.
Same order of magnitude — but the page spreads them over the full screen at ≥44 pt,
where the panel packed them into one 300 pt scroller with ~29 pt chips.

## Lines of text NOT adjacent to a control (primary surface)

**Built page: 1** — the bottom-left hint bar, which the approved prototype itself
defines as a fixed element of the page ("Scrub sliders left–right · tap a value to
type it"). The From Setup bar is a read-only DATA readout (inherited values), not
explanation. Everything explanatory (band notes, who-honours lanes, role
subtitles, gap notes) lives behind pane disclosure. Bar of 0 explanatory lines:
met, with the prototype-defined hint bar declared rather than hidden.

**Replaced panel: 6–8** at rest with the panel open — "N cells across the member",
"Certifiable band X–Y% (from core)", up to three clamp-reason lines, the
region-scope advisory and the cells-per-member advisory paragraphs, plus the proxy
legend's caption. All on the primary surface, none behind disclosure.

## Taps from page entry to a runnable lattice job (defaults)

**Built page: 2.** (1) tap "Lattice infill" → On; (2) tap Optimize. Every default
is runnable: topology octet (certifiable AND generatable, asserted in
LatticePageTests), density defaults clamp onto core's band, boundary Rim only,
uniform density.

**Replaced panel: 3.** Lattice chip (open panel) → mode toggle → Optimize.

## Smallest touch target

**Built page: 44 pt** (panel minimize/back, segment buttons, banner action,
"Snap to 1 voxel", chip-drawer action; everything else is larger — rows 54–62,
fields 48, RUN SIM 48, Optimize 64). Bar ≥ 44: met.

**Replaced panel: ≈ 29 pt** — LatticeValueChip is 14 pt text + 6 pt vertical
padding. Below the bar; one of the reasons the page replaces it.

## Overlapping panels

None in any state, either orientation, by construction: the panel owns the left
column (landscape) or the bottom sheet (portrait), chips own the trailing edge,
the banner is centred with max-width 560 between the panel and RUN SIM, and the
entry gate is a deliberate modal over a scrim. Verified visually in
page_default_landscape/portrait, page_gate_*, and the pane captures.

## iPad portrait, default state, fits without scrolling

**Yes.** The portrait sheet (≤ 46% height, the prototype's rule) holds the header
plus all 7 ladder rows with room to spare — see page_default_portrait.png (all
seven rows visible, no clipping). Sub-panes (cell & density, boundary) scroll
INSIDE the panel when they exceed the sheet; the default state does not.
