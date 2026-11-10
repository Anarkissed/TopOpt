# Lattice rebuild — proposal

Draft 1, 2026-11-10, LatticeReview. For the maintainer to edit. Nothing here is built.
Scope: cell lattices (every strut and sheet type, laid Stepped, Default Grade or uniform). Organic follows as its own proposal.
Background: the code review at `4bdcc9d2` (synthesis and digests in `agent-scratch/lattice-review/`).

Lines marked **DECIDE** are the places I expect you to change.

---

## 1. The one rule

**The engine makes one answer, called the layout. The preview draws it. The run builds the file from it. Nothing else decides geometry.**

Today the app and the engine each compute the lattice with their own code. After the rebuild the app computes nothing about the lattice: no cell sizes, no densities, no rim, no skin, no band. It sends your settings to the engine, gets the layout back, and draws it.

Three consequences:

- A setting either changes the layout or it is not on the page.
- If the engine cannot do what a setting asks, the page says so in one line with a one-tap fix, before any run.
- The numbers you tap on the part are the layout's numbers, and the run's receipt carries the same ones.

## 2. What the app shows, and what each thing must mean

This is the contract, written from the screens as they are today (release N1110).

### Lattice type

| Control | Meaning after the rebuild |
|---|---|
| Structural / Aesthetic | Sets the thin-wall rule and the certificate. **Structural:** a wall needs the engine's certified number of cells across it, else it stays solid. **Aesthetic:** 2 cells across, or 1 when "Allow single-cell members" is on (your ruling). One rule, used by the layout, the forecast and the certificate alike. |
| Type (octet and the others) | The cell that is laid. Limits (lightest and heaviest density, smallest printable cell) come from the engine's per-type facts. |

### Setup page

| Control | Meaning |
|---|---|
| Start from: Solid + Lattice faces | Only the space under faces set to Lattice is latticed. Everything else is solid. |
| Start from: All lattice − Lattice faces | The whole part is latticed, as **one** layout (your ruling). Faces set to No lattice keep solid to their depth. A face set to Lattice here changes its own settings only (depth of its band, density, finish). |
| Group role: Lattice | A prism under the face, to the group's depth, is latticed. |
| Group role: No lattice | A prism under the face, to the group's depth, stays solid. |
| Group role: Protect skin | The face keeps a solid skin of the stated depth. **0 mm means lattice right up to the skin** (your ruling). |
| Depth | How far the prism goes in, measured along the face's normal on the real part. |
| Expand | Grows or shrinks the prism's outline in the face's plane. |
| Lattice zones | A box or cylinder that lattices space no face reaches. Same rules as a Lattice prism. |
| Where two prisms overlap | The nearer face owns the space. Same face plane: the deeper one. No lattice beats Lattice. One rule, in the engine. |

### Lattice page

| Control | Meaning |
|---|---|
| Cell size: Auto | The engine picks: the largest cells that fit, the fewest cells (your 2026-09-14 rule), never a cell wider than the wall it sits in (your 2026-08-24 ruling). |
| Cell size: Manual | Your base cell. The layout still shrinks it where the wall is too thin. |
| Grade style: Stepped | Cells of several sizes packed largest first; smaller cells fill toward the outline. |
| Grade style: Default Grade | Cells halve toward the outline (S, S/2, S/4…). |
| Grade style: none (uniform) | One cell size everywhere it fits. |
| Density: Uniform | One density for the whole part. |
| Density: Per region | The density typed on each group or face. Shown only in this mode, sent only in this mode. |
| Density: By stress | Density follows the stress result, between "Grade from" and "Grade to". |
| Grade: Stress + shape / Shape / Stress | Which of the two things drive density and cell size: the stress, the distance to the outline, or both. |
| Band | How far in from the outline the shape grade acts, in mm on the real part. |
| Strength | How strongly the grade acts. 0 is the default. |
| Allow single-cell members | Aesthetic only. Lets a wall hold one cell across. |
| Allow quilt | Lets the finest cells get dense enough to read as a quilt at the outline. |
| Finish: None | Struts are cut at the surface. No skin. See section 4 for what happens to cut ends. |
| Finish: Rim | A solid bar along every edge of a latticed face; cut struts land on it. |
| Finish: Skin | A thin solid sheet over the latticed face; cut struts land in it. |
| Finish: Covered | The face is closed by the part's own solid surface. |
| Cells / In a part (sample) | A sample built by the engine from the same settings. **DECIDE:** the sample should take every setting on the page, or the page should show your own part again once the layout is fast enough to follow a slider. |

### On the part

| Thing shown | Meaning |
|---|---|
| Legend: Rim & skin, Interior fill, Grade to shape | Colours of the layout's own three classes of cell. |
| Tap a strut | Density, strut width and cell size read from the layout at that point. |
| The pill under Selections | One line naming anything the layout could not do as asked. Empty when it did everything. |
| Lattice button | Runs the job. Its second line says what will be built, from the layout. |

### Controls I propose to remove

They change the picture only, or nothing at all, today. **DECIDE** each:

- Band chips ("Grade to solid" / "Lattice through") — replaced by the one overlap rule.
- Per-face cell size.
- "Through the depth / Across the face".
- The Auto | Manual pill as a fold. Auto and Manual stay as real choices on Cell size and Density.

## 3. The layout

The layout is one object the engine returns. It holds:

- **Cells:** position, size, density, which region owns it, and its class (interior, grade band, rim or skin).
- **Surface:** for every latticed face, the skin thickness and the rim line.
- **Solid:** every place inside a lattice region that stays solid, with the reason (wall too thin, strut would not print, Protect skin, No lattice, sliver).
- **Totals:** latticed volume, solid volume by reason, mass.
- **Refusals:** anything the settings asked for that cannot be done, as a code and one plain sentence.

How it is made:

1. **Measure the part on its real surface.** Wall thickness by casting across the wall on the mesh. Depths and bands in mm on the mesh. The voxel grid is used only for the stress result.
2. **Decide the domain.** Start from, roles, depths, zones, overlaps: one function.
3. **Lay the cells.** Stepped, Default Grade or uniform, by the rules in section 2. One layout for the whole part under All lattice. The grid of cells is centred on the part so a symmetric part gets a symmetric layout.
4. **Set each cell's density.** Uniform, per region, or by stress, then the shape grade. The density belongs to the cell (your ruling C).
5. **Close the surface.** Rim, skin, cut ends (section 4).

The preview asks for the layout whenever a setting changes and draws it. The run asks for the same layout and builds the file. A test on every reference part checks that the two are the same object.

## 4. Geometry rules

- **Cells run to the true surface.** Struts are trimmed against the part's own surface, set back by the skin. A slope is a straight line, a fillet is a curve.
- **Where a whole cell does not fit:** smaller cells first (Stepped packs, Default Grade halves), then cut what remains.
- **Cut ends land on something.** In Skin or Rim they land in the skin or on the rim.
- **Finish None. DECIDE:** I propose a cut strut is kept only if its end lands on another strut or on solid, and a stub shorter than one strut width is dropped.
- **Slivers.** A leftover piece of a cell too small to print becomes solid and joins the skin.
- **Size changes.** Where two cell sizes meet, transition struts join them so every fine node has a partner. No join relies on the shell.
- **One solid.** The file is one clean, watertight body: struts, nodes, rim, skin and the part's own surface merged. No overlapping pieces.
- **The outside of the file is your part's surface**, not a grid approximation of it.
- **Printability.** The strut actually written is at least one bead wide, measured across its flats.

## 5. What a run tells you

- **Before:** the forecast is the layout's totals. It cannot describe a different job, because it is the same object.
- **After:** Results shows the lattice's own margin and verdict, the mass, how much went solid and why, and the verdicts of the enclosed-space and volume checks. A refused lattice says so on its own tab.
- **Certificate.** Structural runs the certificate the job names, with your safety margin, and refuses if any member it dropped is still in the file.
- **Enclosed space.** The check counts the skin and shell as solid. **DECIDE:** add drain holes as a setting, or leave the check as refuse-only.

## 6. What is kept, what is replaced

**Kept:** the job parser, the stress grading law, the per-type cell tables and strength data, the certificate (with the fixes from the review), the volume and enclosed-space checks, the engine's sample builder, every Setup-page gesture and handle.

**Replaced by the layout:** in the app, the cell bake, the band, rim and skin fields, the region mask and the measured-width code; in the engine, the three cell planners and the one long run function that ties them together.

**Old projects.** They open with the same settings. Their preview will change, because today's picture comes from the app's own rules. **DECIDE:** accept that, or keep the old picture read-only on versions that already ran.

## 7. Order of work

Each stage ends with something you can look at on the stand.

| Stage | What is built | You can check |
|---|---|---|
| A. Spec and reference parts | Sections 2 to 4 turned into exact rules; your stand plus three or four other parts, each with the settings and a picture you approve | The pictures and the rules read right |
| B. Domain and measure | Section 3 steps 1 and 2, in the engine | Lattice / solid borders drawn on the stand follow the real surface |
| C. Cells and density | Steps 3 and 4 | Stepped, Default Grade and uniform on the stand, under both Start from choices |
| D. Surface | Step 5 and section 4 | Rim, skin, None and cut ends |
| E. Preview draws the layout | The app's own lattice code switched off behind a setting | Speed on the iPad while dragging a slider |
| F. The run builds from the layout | File, receipt, forecast, Results | A printed part against the preview |
| G. Switch over and delete | Old code removed | Nothing |

Until stage G nothing that ships changes: the new path sits beside the old one.

**Kept from the earlier batch 0**, done first because they are small and stop the app misleading you meanwhile: the crash on one stored setting pair, blocking the combinations the engine refuses, and the preview claiming to be faithful when Stepped did not draw.

## 8. Risks

- **Speed.** The layout has to follow a slider on the iPad. Not measured yet. Stage E is where this is proved or the design changes (for example a coarse layout while dragging, the full one on release).
- **Shared engine files.** Stages B to F touch files other agents own. This needs the reviewer to sequence it.
- **Rules that live only in old code.** Stage A exists to pull them into the spec before anything is deleted.

## 9. Questions for you

1. Section 2: is any control's meaning wrong, or missing?
2. The four controls proposed for removal: agree?
3. Sample or your own part on the Lattice page?
4. Finish None: the cut-end rule in section 4?
5. Drain holes?
6. Old projects: may their preview change?
7. Which three or four parts, besides the stand, should be the references?
