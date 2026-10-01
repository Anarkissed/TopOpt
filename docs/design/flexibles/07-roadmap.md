# 07 — Build order (app first, one small core step before it)

**Plain language:** Nadim needs to *see* the lattice to judge it, so the screens come early. But the lattice maths must exist once, in core, so the preview and the exported file can't disagree. So: a small core step for the squish maths, then the Flexible screens, with the lattice recipe built in parallel, then the preview of the actual bead paths, and only then the file export and the test pucks.

Territory lock (DECISIONS 2026-07-11): core tasks touch `/core/` only; app tasks touch `/app/` only (the bridge is app-side). An app task that needs a core function that doesn't exist yet stops and asks.

| Step | Track | What | Needs |
|---|---|---|---|
| **C1** | core | **Squish maths.** Strict loader for the maintainer-seeded filament and curve files · lookup, inverse and forward (soft and rigid stamps) · monotone curve evaluator · face frames, stacks, linked ends, handover · squish map → target depth → density field · "what can be built" smoothing · Auto recommender with reasons · `flexible` job block · CLI that writes per-face SVG heat maps, CSV and a receipt. **No lattice geometry, no mesh.** | This pack committed; seeds copied into `core/src/materials/` |
| **C2** | core | **Lattice recipe.** Density field → gyroid/honeycomb field with bead-sized walls, cell-size grading, clipping and skins → **per-layer bead paths** (+ CLI that writes a layer as SVG). No mesh export yet. | C1 (can run **in parallel with A1**) |
| **A1** | app | **The Flexible stage.** Third choice next to Structural/Aesthetic · filament list · lattice placement (existing tools) · squish screen: face stepper, linked opposite face, weight/deepest squish, pen curves on the model's edges (X → Y → 3D overlay), modes, drew/buildable toggle, skin per face · stamps (built-in library incl. fingers/thumbs/palm, SVG/image import, size, soft/rigid, check mode) · Auto with reason · physics panel. All numbers via bridge calls into C1. | C1 merged |
| **A2** | app | **Bead-path preview**: layer slider, slicer-style drawing (capsule impostors), nothing written to disk. | C2 merged |
| C3 | core | **Export** STL/3MF from the same recipe · coupon exporter (sets A, B, S, SW) · print-settings recommendation (Bambu Studio terms). | C2 |
| C4 | core | **Calibration ingest**: rig CSV → `calibrated` curve entries. | Rig data |
| C5 | core | **Per-layer temperature/flow** for foaming filaments: table, or G-code post-processing (Q5). | Q5 entry |
| later | both | Soft-over-firm layering (M16) · graded honeycomb · Kelvin / re-entrant "experimental" (coupon set C) · gyroid in the Aesthetic picker (Q6) · sideways load-spreading from rig data. | Rulings + data |
| v2 | both | Insoles: footprint pressure picture → a stamp (greyscale = pressure) → the same pipeline. | Everything above |

**Physical steps for Nadim, alongside:**
1. Build the rig.
2. After C3, slice the coupons in Bambu Studio (Arachne) and confirm single-bead walls.
3. Squash B (replication), then A, S and SW.
4. Measure the X1C hotend's temperature-step time (04 §3).
