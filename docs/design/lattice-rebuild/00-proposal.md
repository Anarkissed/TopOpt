# Lattice rebuild — proposal

Draft 4, 2026-11-10, LatticeReview. For the maintainer to edit. Nothing here is built.
Scope: cell lattices (every strut and sheet type, laid Stepped, Default Grade or uniform). Organic follows as its own proposal.
Background: the code review at `4bdcc9d2` (synthesis and digests in `agent-scratch/lattice-review/`).

Lines marked **DECIDE** are the places I expect you to change. Lines marked **DECIDED** carry the maintainer's answers of 2026-11-10.

---

## 1. The one rule

**One piece of code makes one answer, called the layout. It runs on the device for the preview and on the worker for the file. Nothing else decides geometry.**

Today the app and the engine each compute the lattice with their own code. After the rebuild there is one implementation, in the engine's code, which is already compiled into the app. The preview calls it directly on the iPad; it never waits for a job, a worker or a file. The run calls the same code and builds the file from the same answer.

The layout is planning, not building. It needs no stress solve of its own, no certificate and no strut mesh, which are the three things that make a run slow.

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
| Group role: Protect skin | The face stays a solid surface of exactly the stated depth, with the lattice right behind it (your ruling). At 0 mm it is the thinnest face that prints, two line widths. Not the same thing as Finish: Skin, which is open bars. |
| Depth | How far the prism goes in, measured along the face's normal on the real part. |
| Expand | Grows or shrinks the prism's outline in the face's plane. |
| Lattice zones | A box or cylinder that lattices space no face reaches. Same rules as a Lattice prism. |
| Where two prisms overlap | The nearer face owns the space. Same face plane: the deeper one. No lattice beats Lattice. One rule, in the engine. |

### Lattice page

| Control | Meaning |
|---|---|
| Cell size: Auto | The engine picks: the largest cells that fit, the fewest cells (your 2026-09-14 rule), never a cell wider than the wall it sits in (your 2026-08-24 ruling). |
| Cell size: Manual | Your base cell. The layout still shrinks it where the wall is too thin. Can be set per zone or region. |
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
| Finish: Rim | One bar along every edge of a latticed face; cut struts land on it. |
| Finish: Skin | **DECIDED:** not a solid sheet. A flat lattice of bars across the face that joins the cut strut ends to each other: a rim is one bar, a skin is many. It stays open. |
| Finish: Covered | The face is closed by the part's own solid surface. |
| Cells / In a part (sample) | **DECIDED:** if the layout follows every setting and slider instantly, the page shows the user's own part. If it cannot, the page keeps the engine's sample, and the sample takes every setting on the page. Stage 0 decides which. |

### On the part

| Thing shown | Meaning |
|---|---|
| Legend: Rim & skin, Interior fill, Grade to shape | Colours of the layout's own three classes of cell. |
| Tap a strut | Density, strut width and cell size read from the layout at that point. |
| The pill under Selections | One line naming anything the layout could not do as asked. Empty when it did everything. |
| Lattice button | Runs the job. Its second line says what will be built, from the layout. |

### Removed and kept — DECIDED

- **Removed:** band chips ("Grade to solid" / "Lattice through"), replaced by the one overlap rule.
- **Removed:** per-face cell size. Cell size per zone or region stays.
- **Removed:** "Through the depth / Across the face".
- **Kept: the Auto | Manual pill.** His words: "Auto is for makers. Manual is for engineers. One app for two groups of people." Auto shows the few choices a maker needs and the engine decides the rest. Manual shows every value the layout uses, each editable.

### Manual controls for engineers — DECIDED: these ten

Each is a number the layout already has to choose. Manual shows it and lets it be set; Auto keeps choosing it. Each can be set for the part or per zone or region. They are listed in the order they get built, which follows the stage that makes each one possible.

| # | Control | What it sets | Why an engineer wants it | Built in |
|---|---|---|---|---|
| 1 | Strut width, from → to (mm) | The thinnest and thickest strut, stated directly instead of as a density | Struts are specified and inspected in mm, not in percent | C |
| 2 | Cells across a wall (minimum) | Overrides the 2 / 1 / certified rule, with a plain warning when it goes below what is certified | To accept or forbid lattice in a given wall thickness | C |
| 3 | Layout anchor and angle | Where the cell grid starts (a face, an edge, the part's centre) and its rotation | To line cells up with a feature, or turn struts off the print's weak direction | C |
| 4 | Size change rate | The largest step in cell size between neighbours | Controls how abruptly stiffness changes | C |
| 5 | Grade response | How steeply density follows stress, and the target stress the lattice is sized to (a share of the allowable) | Sets the safety factor of the lattice itself | C |
| 6 | Which loads drive the grade | One load case, or the worst of all | A part used in more than one way | C |
| 7 | Skin bars | Bar width, spacing and pattern of the skin's flat lattice | The skin carries the surface load | D |
| 8 | Rim width | Width of the rim bar | Edge strength and print adhesion | D |
| 9 | Joint fillet | The blend radius where struts meet | Joints are where lattices crack; a fillet lowers the peak stress | D |
| 10 | Overhang limit | The steepest unsupported strut allowed, with any breach highlighted on the part | Printability on the chosen build direction | D |

**Left out for now, and why:**

- **Symmetry.** The layout is centred on the part by default, so a symmetric part already gets a symmetric lattice. A control is only needed for a part that is nearly symmetric, which can wait.
- **Target mass.** It needs the layout to be solved several times to hit a number. Until then the mass is shown live, so the same result is reached by moving the strut width.

## 3. The layout

The layout is one object the engine returns. It holds:

- **Cells:** position, size, density, which region owns it, and its class (interior, grade band, rim or skin).
- **Surface:** for every latticed face, the skin thickness and the rim line.
- **Solid:** every place inside a lattice region that stays solid, with the reason (wall too thin, strut would not print, Protect skin, No lattice, sliver).
- **Totals:** latticed volume, solid volume by reason, mass.
- **Refusals:** anything the settings asked for that cannot be done, as a code and one plain sentence.

**Speed requirement — DECIDED:**

- **The aim:** dragging a slider stays smooth; the picture follows the finger, on the user's own part.
- **What he will settle for if that is all we can manage:** a one-time wait when a part is opened or a region changes, with sliders still quick afterwards.
- Working numbers until measured: full picture within about a third of a second of release; the one-time wait a few seconds at most, with the old picture kept up meanwhile.

How it is kept:

- **Measure once.** Walls and surfaces are measured when the part or a region changes, then kept. A slider never triggers it.
- **Redo only what changed.** Density and Strength move no cells. Band touches only cells near the outline. Cell size is the only setting that re-lays everything.
- **Draw as today.** The graphics chip draws the lattice from a small table of cells. Only who fills the table changes.
- **Fallback while dragging:** a coarse layout, replaced by the full one on release.

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
- **Cut ends land on something.** With Rim they land on the rim bar. With Skin they are joined to each other by the skin's bars.
- **Finish None — DECIDED:** a cut strut is kept only if its end lands on another strut or on solid, and a stub shorter than one strut width is dropped. Where that leaves a stepped edge, the app points at it on the part and says "Rim or Skin will fix this".
- **Slivers.** A leftover piece of a cell too small to print becomes solid and joins the nearest solid.
- **Size changes.** Where two cell sizes meet, transition struts join them so every fine node has a partner. No join relies on the shell.
- **One solid.** The file is one clean, watertight body: struts, nodes, rim bars, skin bars and the part's solid merged. No overlapping pieces.
- **The outside of the file is your part's surface**, not a grid approximation of it.
- **Printability.** The strut actually written is at least one bead wide, measured across its flats.

## 5. What a run tells you

- **Before:** the forecast is the layout's totals. It cannot describe a different job, because it is the same object.
- **After:** Results shows the lattice's own margin and verdict, the mass, how much went solid and why, and the verdicts of the enclosed-space and volume checks. A refused lattice says so on its own tab.
- **Certificate.** Structural runs the certificate the job names, with your safety margin, and refuses if any member it dropped is still in the file.
- **Enclosed space — DECIDED:** the check counts every solid surface that really closes the lattice in (Covered faces and the part's own walls; a Skin is open bars and does not). Where it finds trapped lattice the app shows a notice and highlights the place on the part. Drain holes as a setting are set aside for now: slicers can add them.

## 6. What is kept, what is replaced

**Kept:** the job parser, the stress grading law, the per-type cell tables and strength data, the certificate (with the fixes from the review), the volume and enclosed-space checks, the engine's sample builder, every Setup-page gesture and handle.

**Replaced by the layout:** in the app, the cell bake, the band, rim and skin fields, the region mask and the measured-width code; in the engine, the three cell planners and the one long run function that ties them together.

**Old projects — DECIDED:** they open with the same settings and their preview may change.

## 7. Order of work

Each stage ends with something you can look at on the stand.

| Stage | What is built | You can check |
|---|---|---|
| 0. Speed proof | A rough layout for the stand only, timed on the Mac as a first indication (**DECIDED**), then on the iPad when he installs a build | The numbers. If it misses, we switch to the alternative in section 8 before any real work is spent |
| A. Spec and reference parts | Sections 2 to 4 turned into exact rules; your stand plus three or four other parts, each with the settings and a picture you approve | The pictures and the rules read right |
| B. Domain and measure | Section 3 steps 1 and 2, in the engine | Lattice / solid borders drawn on the stand follow the real surface |
| C. Cells and density | Steps 3 and 4 | Stepped, Default Grade and uniform on the stand, under both Start from choices |
| D. Surface | Step 5 and section 4 | Rim, skin, None and cut ends |
| E. Preview draws the layout | The app's own lattice code switched off behind a setting | Speed again, now on every reference part |
| F. The run builds from the layout | File, receipt, forecast, Results | A printed part against the preview |
| G. Switch over and delete | Old code removed | Nothing |

Until stage G nothing that ships changes: the new path sits beside the old one.

**Kept from the earlier batch 0**, done first because they are small and stop the app misleading you meanwhile: the crash on one stored setting pair, blocking the combinations the engine refuses, and the preview claiming to be faithful when Stepped did not draw.

## 8. Risks

- **Speed.** The layout has to follow a slider on the iPad. Not measured yet; the argument is only that the app does a similar amount of work on the device today. Stage 0 proves it or not before anything else is built.
- **The alternative if stage 0 fails.** The app's fast preview stays the author of the layout, and the run builds exactly the cells the preview placed, refusing if it cannot (the engine already has a path for this). It still gives "what you see is what you get". The cost: the layout rules stay in the app, so the engine cannot lay out a part by itself and the sample needs the app's code too.
- **Shared engine files.** Stages B to F touch files other agents own. This needs the reviewer to sequence it.
- **Rules that live only in old code.** Stage A exists to pull them into the spec before anything is deleted.

## 9. Reference parts — DECIDED

The stand plus three parts of the same machine, each with the anchors, loads and protected faces the maintainer supplied. The model files stay on his disk and are never copied into the repo; the tests read them from a folder he names and skip where it is absent.

| Part | What it covers |
|---|---|
| 2040 Extrusion Stand | A sloped face, pockets, both Start-from choices; the screenshots this work began from |
| Base | A flat plate with a raised edge all round, loaded mid-span, held at two bolt holes: thin, wide walls and holes through them |
| Top Motor Mount | Bosses, fillets and many holes; curved walls; lightly loaded |
| Pressing Plate Mount | A channel with 3 mm walls and a flange: the thin-wall rule at its limit |

## 10. Still to decide

1. Section 2: any control whose meaning is wrong or missing.
2. The speed numbers, once stage 0 has measured them.
