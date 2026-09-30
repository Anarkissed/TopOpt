# 00 — Decisions, open questions, and the DECISIONS.md draft

**Plain language:** this file separates what Nadim has decided (binding), what the reviewer (Claude) recommends but Nadim hasn't ruled on (keep as defaults, don't change silently), and where the Flexible stage collides with `docs/ARCHITECTURE.md` — with a draft `DECISIONS.md` entry Nadim can paste to clear those collisions. Agents act on the draft only once it is actually in `DECISIONS.md`.

Updated 2026-09-27 evening, after the design conversation settled the screen flow.

---

## 1. Maintainer decisions (Nadim, 2026-09-26 / 27)

| # | Decision |
|---|---|
| M1 | A **Flexible** (working name; "Squish" also considered) stage alongside Aesthetic and Structural. |
| M2 | Materials: TPU / TPE / PEBA, **especially foaming "Air" filaments** where nozzle temperature changes softness. |
| M3 | Target flow: import model → pick a filament from a list the app offers → mark where the weight goes → set the squish wanted → app generates the lattice, simulates the squish, recommends print settings (and G-code for Air filaments, see §4), shows the physics, exports the file. |
| M4 | **Organic lattices excluded** — no published data. Only lattice families with real test data. |
| M5 | The app **recommends the lattice** in this stage (user sets squish, app picks), unlike the other stages. |
| M6 | **TopOpt generates the lattice itself** — full control of cell size, wall thickness, density and smooth transitions. Not slicer-infill settings. |
| M7 | The pressure-mapped **insole add-on is v2**. |
| M8 | He is building a DIY compression rig (SFU1204 ball screw hung from the top plate, two rails, geared NEMA17, TMC2209, HX711 with swappable load cells) for in-house calibration. |
| M9 | **App first, with one small core step before it.** He needs to *see* the lattice to judge it. The preview must show the lattice **exactly as it will be generated**, with **no file written until export** (saves disk). The lattice maths lives **once, in core**; the app draws from it and never re-implements it. |
| M10 | Flexible is a **third choice next to Structural and Aesthetic** when you first enter the Lattice section, and **looks exactly like them**. Faces and groups made earlier are reused; "where the lattice goes" is chosen the same way as the other stages. |
| M11 | **Squish is set on its own screen, on the model itself**, one face at a time: **X curve → Y curve → 3D view with an overlay** on the actual part. Curves are **pen-tool** curves (add, drag, delete points; S-curves allowed), drawn on the face's own edges. Combine modes: *both axes*, *either axis*, and a *centre → edge* curve that follows the face outline. A *what you drew / what can be built* toggle. |
| M12 | **Any face can carry weight — top, bottom and sides.** Side faces use gyroid only and carry an "estimated" label until sideways test pucks are done. |
| M13 | **One squish profile per stack of material.** Picking a face lights up its opposite face as the linked other end. The user marks where the weight comes from; sides can be pushed from either side. |
| M14 | **Stamps** — the shape of what presses: load an **SVG or an image** (greyscale = pressure), set its real **size in mm** and the **weight in kg**, **soft** (spreads evenly) or **rigid** (sinks evenly). **Built-in stamps including fingers, thumbs, palm** and more. Used to design ("under this stamp I want this squish") and to check ("what happens under a heel?"). |
| M15 | **Skin on/off per face** (off lets edges and side walls squish down). |
| M16 | **Soft-over-firm layering** (squish that firms up as you press, and different feel from each side under small loads) comes **after v1**. |

## 1b. Round 3 — his answers and the rows they change (2026-09-29, batch A: the Settings page; batch B: Exit always leaves a lattice)

These OVERRIDE the rows they name below. Agents: do not "fix" them back.

| # | Decision | Overrides |
|---|---|---|
| D-R3-1 | **Frame rotation is removed; every face is sent at 0°.** Both X and Y curves are drawn on the face's own two edges at once, so turning the frame has nothing left to do (and the stack cache keys halve). A saved 90° reads as 0 (read-through migration, `FlexibleSettingsMigration`). | R13's "user can rotate the frame in 90° steps" |
| D-R3-2 | **Walls are always 1 bead; the 1/2-bead chips are gone.** Core marks every 2-bead number "estimated" and nothing chooses 2 automatically yet. A saved 2 reads as 1. Core brief: *recommend should weigh 1 vs 2 beads once 2-bead coupons exist.* | R1's "2 allowed" (as a user choice) |
| D-R3-3 | **Curve convention: closer to the face = squishier.** The editor draws a stored y (core's fraction of the deepest squish) at height 1 − y above the face: the face line is the squishiest, the dashed guide the firmest ('soft' / 'firm' labels). Core's S, the job and storage keep their meaning. A curve DRAWN before round 3 flips its stored y once so its picture survives (marker `curveConvention`); the untouched default dome is kept and now reads as a valley touching the face — the dent's own shape. | M11's editor reading ("up = softer") |
| D-R3-4 | **Mode is always "both" (X and Y always combined); the X / Y / 3D steps are gone; the map always bends.** The drawn map dents statically while he edits ("What you drew · shown ×k") and loops only once a lattice is drawn; every filament bends, calibrate-first included (its map is core's squish_fraction). Saved "either" / "centre_edge" faces read as "both" with their curves kept. | M11's combine modes and steps; the pinned "a curve step never dents" rule |
| D-R3-5 | **One integer exaggeration k per page state**: clamp(round(0.20 · extent / deepest), 1, 10), capped so no column's shown dent passes 0.65 of its own lattice depth, **and so k × each pressed face's deepest squish stays within 0.65 of its columns' lattice depth** (the prism floor never leaves the part — verification: a flat-0.3 drawing had got × 10 and a floor 10 mm below the part); with a lattice, also by the shader's clamp. The dent, the depth prism and the chip share it; it freezes while the chip is dragged, and **one drag stops where k × depth meets the lattice** (release re-chooses k, the next drag goes on). The dent bottoms out on the prism floor only where the curve touches the face line (S = 1); elsewhere it stops short, by design. | the × 1–4 rule |
| D-R3-6 | **A tap on the model only selects.** Faces come from the main page: a Load group's faces arrive pressed with their area share (c = force · into-the-face ≥ cos 15° full, oblique × c, ≤ 0 asked), an Anchor group's faces rest. **The group is the one source of truth**: a weight typed on the Flexible page writes back to the group and the group's faces re-sync. **Every face a Load group presses is linked to it — also one pressed before round 3 by the old tap's 10 kg** (his top A reads "10 kg from Top"); an own weight the group replaces is said in one line. **[Rests] chosen on the Flexible page is his choice** and survives every re-sync (one line: "Top presses it on the main page"); **the trash is not offered for a face a group holds** (it would come straight back). The number pad commits once, when it closes (one write-back, one undo step). The Flexible job writes `loads.build_dir` = −gravity (core had assumed +Z). | M13's "picking a face" as the way to load it |
| D-R3-7 | **The density cross-section and its slider are removed** (they did nothing on a calibrate-first filament; the X-ray lattice shows the same field in 3D). | S2's slice evidence |
| D-R3-8 | **Only the dent map is green on the part.** The depth prism is drawn **only while its chip is dragged** (at rest it filled ~90 % of his pad under the face and hid the bend), and a flat prism's walls stand only where its outline turns (the per-pitch skirt was a barcode). The curves, their points, the chip, the prism and the selected face are DS `textPrimary`; the green is the map's own ramp and the page's accent. | round 3's "green glass chip / green prism" |
| D-R3-9 | **A stale lattice never owns the map.** Once a setting changes after Generate, the map is his live drawing (held still) and the stale walls hide — the protection the curve steps gave, kept without the steps (`FlexibleLatticePreview.drawn`). | — |
| D-R3-10 | **Exit is blocked only by what truly stops a lattice** (batch B, item 9): no filament (legacy only), no pressed face, two pressed faces sharing a stack, a face core cannot stack, a pressed face with no weight, a core refusal with no automatic fix. Each is ONE line at the top of Settings and a pop-up that selects and pulses the face, turns the camera to it and offers 1–3 one-tap fixes ([Face 5 rests] [Face 3 rests]; a number pad for kg; [Rest it] [Remove it]; the filament with data). The pop-up opens on a NEW blocking issue his last action caused, on Exit ("Fix 1 thing"), or from [Fix] / the main page's pill — never on recompute noise. **Never blocking:** a calibrate-first filament (D-R3-12), more than four pressed faces (D-R3-14), "still designing" (the main page builds when the designs land). **Silent fixes, with a toast:** temperature_not_tested → Auto; topology_no_data / honeycomb_side_stack → Gyroid (when the setting was not already that — then it blocks). One face's throw no longer stops the next face's design; a face core could not stack is not retried blindly. | the Generate gate (`FlexibleLatticeGate`, removed): calibrate-first refused, a fifth face refused, "still being designed" refused |
| D-R3-11 | **No Generate button: Save & Exit builds the lattice and the MAIN Flexible page shows it** (item 7.1). The one FlexibleStageModel per project lives in `FlexibleMainStage` (owned by the workspace, hook H1); the Settings page observes it (H2), so the lattice outlives the page. The main page draws the part with its dented map, the X-ray ghost and the lattice (H3/H4), with minimal X-ray / Heat / Lattice views (H5); its bottom bar carries a status pill — "Lattice ready", "Building the lattice…", the shape-only label, or the one thing to fix — in place of the octet "Lattice" run under Flexible (H10). `previewBakeInputs` drops `flexible` (H12) so no Flexible edit re-keys the octet bake. The Settings page's Export pill went with Generate (exports still wait on core). | the Settings page's Generate / Generate again / Export pill |
| D-R3-12 | **A calibrate-first filament gets a SHAPE-ONLY lattice** (his answer): core's lattice mask (the density field with no faces — the same `mask` core counts as latticeVoxels), density from the DRAWN map S — monotone, softer where he drew softer, inside the printable band whose ends are cells from core's `cellSizeMM` (the finest 8 walls, the coarsest half the shallowest pressed face's mean lattice depth, capped at 12 mm) — the firmer where two faces reach, flood-filled like a designed field. Labelled **"<filament>: shape only — no squish predicted"**; the dent beside it is "What you drew". It is the app's density choice, not a prediction (R7). | "calibrate-first: no lattice" |
| D-R3-13 | **The squish player** (his request: "a play button and/or timeline to drag that moves the squish in and out"), on the Settings page and the main page, in the Results morph player's look: play / pause loops rest → full → rest (2.4 s cosine ease) and resumes from where it is; dragging the timeline pauses and sets the amount 0…1; the dent and the walls move by ONE number (flexScale = k × amount); ends "Rest" and the full load ("10 kg", "10 kg each", else "Full load"); reduced motion: no auto-play. A fresh lattice plays; his live drawing (no lattice / stale) holds at full. **On the main page the loop runs in the renderer** (`MeshRenderer.stepFlexibleLoop`) — nothing publishes into the workspace per frame; continuous frames only while it plays. Its frame is computed against each page's keep-outs; it shows only when there is something to squish. | the Settings page's always-looping dent |
| D-R3-14 | **More than four pressed faces: walls for every face, the squish shown on the four LARGEST** (by stack area — the preview shader's four slots); the others' dents hold still with their walls, and the readiness line says "Squish shown on the 4 largest of 7 faces". | round 2's "refuse a fifth face" |

## 2. Reviewer defaults — NOT yet ruled (agents: keep them, do not change silently)

| # | Default | Why |
|---|---|---|
| R1 | Lattice walls in **whole beads**: 1 bead default, 2 allowed. | Iacob's tabulated data was printed as single-bead walls. Kedziora 2023 and Justino Netto 2024 independently found non-whole-bead walls print badly. |
| R2 | Look squish up by **printed (core) relative density**, not nominal infill % and not bead count. **2-bead lattices are 'unverified'** until coupon set S passes (proxy band + flag). | Iacob's own specimen masses: nominal infill understates printed density (gyroid 10 % ≈ 0.14 core; honeycomb 35 % ≈ 0.45). Justino Netto 2024: at equal density, 2-bead/large-cell PLA gyroid was ~26 % stiffer, ~36 % weaker, and failed differently. |
| R3 | v1 topologies: **gyroid** (soft/springy) and **honeycomb** (firm/damped). Kelvin and re-entrant "experimental" later. Octet, FCC, BCC, BCCZ, SC, diamond excluded. | Only gyroid and honeycomb have printed-TPU data. |
| R4 | **One topology per part in v1**; density graded across it. | No data on gyroid↔honeycomb joins. |
| R5 | **Auto** shows a one-line reason, asks "springy or damped?", allows override; an untested combination shows "no data here", not a number. | M5. |
| R6 | Honeycomb only where the load runs along its prism axis (build Z ± 15°). So **side faces are gyroid-only** (M12). | Honeycomb pushed sideways is a different structure with no data. |
| R7 | **No margin, certificate or "accepted" verdict** anywhere in this stage. Every prediction carries its tier (literature / calibrated / proxy / estimated) and an error band; outside the data → refuse with the reason. | The honesty principle: the number describes the object in the file. |
| R8 | Literature-tier squish **≤ 20 % strain**; **20–25 % "extrapolated"**; **> 25 % refused**. | Iacob tested to 25 % and reported secants at 10 % and 20 %. |
| R9 | v1 squish solve = **independent columns** (no sideways load spreading) + a coupling hook at zero until calibrated. **Stamps narrower than ~3 cells are flagged.** | No data for sideways spreading yet; the rig can measure it (small pusher vs full plate). |
| R10 | Foaming filaments: **tested temperatures only**; never interpolate between them. | varioShore stiffness is non-monotonic in temperature. |
| R11 | Where two loaded faces' stacks meet (corners/edges), each spot follows the **nearest loaded face**, blended over **one cell** of the larger cell size. Two loaded faces on the **same stack** (e.g. top and bottom both "pushed" with different profiles) → refuse and name them. | M13 (one profile per stack). |
| R12 | Pen curves are **monotone cubic (Fritsch–Carlson)** through the user's points, clamped to [0, 1]: S-curves allowed, never overshoots a point. Evaluated **in core**; the app calls it. | One definition: the curve the user sees is the curve core builds. |
| R13 | **Face frame**: load direction = into the part, along the face's area-weighted normal. X = the face's longest direction seen along the load (2D principal axis of the projected face); Y = load × X. User can rotate the frame in 90° steps. A face whose normals spread more than 30° is flagged. | A rule both app and core compute the same way (core computes; app displays). |
| R14 | "What can be built" = the drawn map **clamped to the data range and smoothed to about one cell** (Gaussian, σ ≈ half the local cell size). A heuristic until the lattice generator measures real limits. | Density can't change faster than about a cell. |

## 3. Open questions for Nadim

- **Q1** Confirm R1 (1-bead default, 2-bead allowed).
- **Q2** Confirm R4 (one topology per part in v1).
- **Q3** Confirm R8 strain limits.
- **Q4** Proxy tier: may the app ESTIMATE squish for a filament with no lattice table (e.g. generic TPU 95A, NinjaFlex) by scaling varioShore-190 °C by the solid-modulus ratio, with a ±50 % band? Or "calibrate first" only?
- **Q5** G-code: amend ARCHITECTURE §2 to allow a per-layer temperature/flow schedule for foaming filaments (see §4)?
- **Q6** Expose the gyroid generator in the **Aesthetic** picker too (generate-only)?
- **Q7** Stage name: "Flexible" or "Squish"?

## 4. Collisions with ARCHITECTURE.md (immutable to agents)

| ARCHITECTURE says | Flexible stage needs | Effect |
|---|---|---|
| §2 "Not a slicer … **we do not generate G-code**." | G-code for Air filaments. | **Blocks** G-code output until Nadim decides (Q5). The per-layer **bead-path preview is not G-code** and is fine: it's a drawing, nothing is written. |
| §4 FEA locked as linear elastic, small deformation. | Large-strain squish prediction. | Not a true conflict — the squish model is **not FEA** (a lookup of measured curves). Say so in DECISIONS. |
| §6 `materials.json` schema locked. | Flexible filaments need different fields. | New maintainer-seeded file `flexible_materials.json`; `materials.json` untouched. |
| §7 / DECISIONS 2026-07-10: FEA certifies every user-facing result. | Uncertified squish predictions. | Explicit carve-out: this stage never shows a certificate or margin. |

### Draft entry — paste into `docs/DECISIONS.md` (edit freely; agents act only on what is actually there)

```
- 2026-09-27: FLEXIBLE LATTICE STAGE (maintainer). A third lattice stage, "Flexible",
  for elastomer filaments (TPU / TPE / PEBA, including foaming "Air" filaments).
  1. NO CERTIFICATION CLAIM. The stage never shows a margin, certificate or "accepted"
     verdict. Every squish prediction carries its data tier and an error band and is
     refused outside the data it came from. Carve-out from the 2026-07-10 "FEA certifies
     every user-facing result" rule, which still governs Aesthetic and Structural.
  2. The squish model is NOT FEA: a lookup-and-invert model over measured compression
     curves (docs/design/flexibles/02-squish-model.md). ARCHITECTURE §4's FEA is unchanged.
  3. Flexible filaments and squish curves live in new maintainer-seeded files under
     core/src/materials/ (flexible_materials.json, flexible_curves/). materials.json is
     untouched. Agents build loaders and never change numeric values.
  4. ONE DEFINITION. All Flexible maths - curve evaluation, face frames, squish maps,
     density lookup, the lattice field and its per-layer bead paths - lives in /core/.
     The app draws from core through the bridge and never re-implements it. The preview
     is drawn from the same functions the export uses; no file is written until export.
  5. Lattices are generated by TopOpt (not slicer infill). v1 topologies: gyroid and
     honeycomb, walls in whole extrusion beads. Organic lattices excluded. The new
     generators are NOT added to lattice_generatable_topologies() (Aesthetic/Structural
     picker) without a separate maintainer decision.
  6. G-CODE (choose one, delete the other):
     (a) ARCHITECTURE §2 amended for this stage only: TopOpt may post-process slicer
         G-code to insert a per-layer temperature + extrusion-rate schedule for foaming
         filaments. TopOpt still does not slice.
     (b) No G-code in v1; the stage recommends settings and a per-layer temperature table.
  7. Reference pack: docs/design/flexibles/ (maintainer-committed). Its 00-decisions.md
     §2 lists reviewer defaults; agents keep them unless a later entry overrides.
```
