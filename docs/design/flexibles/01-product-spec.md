# 01 — What the Flexible stage does (product spec)

**Plain language:** you pick where the lattice goes, then go face by face and draw how squishy each part should be, right on the model. You can press it with stamps — a thumb, a palm, a heel, or a shape you load in — and watch where it dents. The app picks the lattice, shows you exactly what will be printed layer by layer, says how to print it, and exports the file. It never claims a strength certificate, and it always says where its numbers come from and how far off they might be.

UI layout and wording are **Nadim's decisions** (house rule). This file describes behaviour. App tasks also carry his standing UI rules: screenshot the Topology screen and match its visual language before adding a control, and every numeric input opens a numeric keypad.

---

## The flow (M9–M16)

1. **Lattice section entry.** Three choices side by side: **Structural · Aesthetic · Flexible**. Flexible looks exactly like the other two (M10).
2. **Pick a filament** from `flexible_materials.json`. Each shows its data tier; `calibrate_first` filaments build geometry but predict nothing.
3. **Place the lattice** with the same region tools as the other stages. Faces and groups from earlier stages are reused.
4. **Squish screen** (a separate screen, M11):
   - **Face stepper** — loaded faces one at a time ("Face 2 of 4"). Tapping a face makes it loaded; its **opposite face lights up as the linked other end of the same stack** (M13). Mark where the weight comes from; side stacks can be pushed from either side.
   - **Per face:** weight (kg), deepest squish (mm), optional **stamp** (below).
   - **Step 1 — X curve**, drawn with the pen tool on the face's edge. **Step 2 — Y curve** on the other edge. **Step 3 — 3D view**: squish colour and an exaggerated dent on the actual part, spinnable. Modes: *both axes* (soft only where both curves are high), *either axis* (soft where either is high), *centre → edge* (one curve following the face outline). Toggle *what you drew / what can be built*.
   - **Skin on/off per face** (M15): tap a face to toggle its solid skin. Off lets edges and side walls squish.
   - **Check mode:** swap stamps and watch the dent change. Nothing is re-designed; it just shows the response.
5. **Auto** picks the lattice (M5, R5): one-line reason, "springy or damped?", override allowed (untested picks show "no data here"). Side-loaded stacks are gyroid-only (R6).
6. **Preview — exactly what will be printed** (M9): the per-layer **bead paths** from core, drawn like a slicer preview with a layer slider. Nothing is written to disk.
7. **Physics:** the squish curve for the chosen filament / temperature / lattice / density, each face's operating point, the tier, the source, the band.
8. **Print settings** (Bambu Studio terms) and **export** STL / 3MF. G-code for Air filaments waits on Q5.

## Stamps (M14)

- **Sources:** built-in library (`data/stamps.json` — fingertip, thumb, palm, fist, heel, knee, elbow, flat plate, the ASTM IFD foot), or **load an SVG** (outline) or **an image** (silhouette; **greyscale = pressure**, darker presses harder).
- **Settings:** real size in mm (built-ins start at typical adult sizes; scale freely), rotation, position on the face, **weight in kg**, **soft** (weight spread over the stamp's shape — bodies, hands) or **rigid** (everything under it sinks the same distance — plates, blocks).
- **Several per face** (two feet, four fingers).
- **Design mode:** a stamp can be the design load ("under this, squish like my curves"). Without one, the design load is the weight spread evenly over the face.
- **Check mode:** any stamp, any time, to see the response.
- **Honest limit (R9):** v1 doesn't model sideways load spreading, so dents have sharper edges than real life and nothing outside the stamp moves. Stamps narrower than ~3 cells are flagged.
- **One definition:** the app turns a stamp into a **pressure grid on the face** and sends the grid; core uses the grid as-is and never re-reads the SVG or image.

## Auto recommender rules (v1)

1. **Eligibility:** honeycomb only for stacks loaded along build Z (± 15°). Gyroid always.
2. **Reachability:** for each eligible family (and each tested temperature for foaming filaments), can every face's squish map be met inside the table's density range at that strain? Drop what can't, and keep the reason ("honeycomb can't go soft enough under the thumb").
3. **Feel:** "springy" prefers gyroid (lowest loss, best recovery, near-isotropic); "damped" prefers honeycomb (bigger loop, firmer). If only one family survives, it wins and the reason says so.
4. **Tiebreaks:** fewer spots near a table edge → lower mass → (foaming) the temperature whose predictions sit furthest inside the data.
5. **Nothing reachable:** say which face and where, and the nearest achievable squish.

Evidence: Chatpun 2025 (TPU95: honeycomb highest load and loop, gyroid lowest), Beloshenko 2021 (honeycomb +30 % rigidity, +42 % energy; gyroid less direction-dependent, better recovery), Iacob 2024 (honeycomb stiffer at equal infill, partly because it carries ~20–25 % more material).

## Honesty rules (R7)

- No margin, safety factor, "certified" or "accepted" anywhere in this stage.
- Every squish number shows its **tier** and **± band**: literature (Iacob, a different printer) / calibrated (your rig) / proxy / **estimated** (side-loaded stacks, 2-bead walls until set S).
- `calibrate_first` filaments: geometry yes, squish numbers no — an empty field with the reason, never a greyed guess.
- Above 20 % strain → "extrapolated"; above 25 % or outside the density range → refused with the reason.
- Tables are 4th-cycle (after break-in): "a brand-new part is firmer for its first few squeezes".
- "Dents have sharper edges than real life, and a small press on a big pad sinks less than shown" (R9).

## Out of scope for v1

Soft-over-firm layering and side-dependent feel (M16) · mixing topologies in one part · organic and strut lattices · resins · insoles and pressure maps from the footprint rig (v2 — stamps are the first half of it) · rate, creep, compression-set and fatigue predictions · durability claims.
