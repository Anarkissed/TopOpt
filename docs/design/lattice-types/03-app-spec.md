# 03 — App work

**Plain language:** the type chips are already on screen; seven of them are just greyed out. The app's job:
- light each type up the moment core says it's ready;
- mark the ones you haven't printed;
- draw each type exactly as core will build it;
- grey out, with a reason, the options a type can't use (for example, gyroid can't change cell size mid-part).

Nothing about how the stage looks changes.

Paths refer to PR 354's branch at `ec2af861`.

---

## 1. Getting the new core (M3)

- Merge `origin/claude/raster-receipt-fields` (PR 358) into 354's branch, **one-way**. Never edit a core file. A conflict in core means stop.
- Rebuild the linked core (`app/scripts/build_core.sh`), then run the suite.
- **Report which core-capability probes flipped** (for example `TopOptKit.coreCarriesTheSampleRepairFix`, `LatticeCoreCapability`, and every place the app tests for a PR 358 key) and what changed on screen because of them. The app has been running on a 2026-09-09/11 core that lacks PR 358's keys (`stepped_cells`, `stepped_min_tile_mm`, `structural_certification`, `shape_grade`, `max_relative_density`). Linking 358 changes behaviour on its own, before any new type.
- From then on, sync again whenever the core agent pushes (the maintainer says "sync core").

## 2. The picker

- **The offered set comes from core.** Replace `static let offeredTypeIDs: Set<String> = ["octet"]` (`LatticeSetupWizard.swift:2423`) with core's generatable ∩ certifiable, via the bridge. Every type core doesn't offer stays **visible and greyed, with core's reason**. That includes BCCZ, FCCZ and Re-entrant (M1).
- **Order**: Octet first (M4), then SC, BCC, FCC, Diamond, Kelvin, Rhombic dodecahedron, then Gyroid, Schwarz-D. The greyed not-this-round types come last.
- **"Not print-tested" tag** (M2), from core's print status. Tapping it opens a sheet with two things:
  - what the tag means, in one sentence: "You haven't printed this type yet. The certificate covers its strength; only a print shows how it comes off the bed.";
  - how to clear it: print the sample block (core's `lattice-sample`), then mark the type tested in `lattice_print_tests.json`. Offer a button only if the existing worker path can run that command without new core work; otherwise show the command.

  Tested types show the date instead.
- **Directional note** for SC and BCC (R3), one line under the chip when selected: "Strongest when the load runs along the cell axes."
- **Names** (Q5 defaults): Simple cubic, BCC, FCC, Diamond, Kelvin, Rhombic dodecahedron, Gyroid, Schwarz-D. Extend `LatticeType.displayName(forID:)`.
- **Look**: before adding anything, screenshot the Topology screen and match it (standing rule). Chips, tag and sheet use the existing design tokens (`DS.*`), with no new colours.

## 3. Every number from core (R12)

- **Strut geometry comes from core's canonical cell**, not from the Swift tables in `LatticeType.swift`. Those carry only 7 types and no Kelvin or Rhombic. Keep them only as a test oracle pinned equal to core's tables, or delete them.
- Density ↔ strut size, floors, band, aesthetic ceiling, the finishes allowed and the cell modes allowed all come from core's per-type facts (02-core-spec §5). This covers every octet-only site in the app. Start with:
  - `LatticeSDFMetal.swift` (22 octet mentions; the octet band and quilt paths);
  - `LatticeSettings.swift`;
  - `LatticeOctreeBake.swift` (octet's 20 % quilt ceiling);
  - `LatticeDensityProxy.swift` (`realReferences` triangle counts; core's measured cost replaces them);
  - `LatticeRegionCells.swift`, `LatticeAutoPosture.swift`, `WorkspacePlaceholder.swift`;
  - `TopOptKit.swift`, `bridge.cpp` / `TopOptBridge.hpp`;
  - `RemoteRunner.swift` / `RelatticeRunner.swift` (the job's `topology` keys).

  Make a full table (file, line, what, fix) before changing code.
- **Options a type can't use are greyed with core's reason.** Examples:
  - Doubled/Stepped where core's size-step test failed for that strut type;
  - Doubled/Stepped for sheets ("Gyroid and Schwarz-D change density by wall thickness, not cell size");
  - Diagrid for sheets;
  - "Allow quilt" wherever core gives no ceiling.

  Nothing is hidden.

## 4. Preview = the run's STL (M5), per type

- **Struts.** The raymarch preview (`LatticeSDFMetal` / `LatticeSDFPreview`), the sample patch and the octree bake draw from core's canonical cell and core's diameter law. For each live type, add a parity test in the existing preview-parity style: the preview's geometry for a sample patch against core's emitted mesh for the same patch (strut endpoints, radii, enclosed volume).
- **Sheets.** Raymarch core's field, using the same formula in the Metal shader. Keep a CPU mirror of the shader's field function and unit-test it against core's deterministic sampler at N points; values must match to 1e-6. Wall thickness comes from core's law. One cell size per region. Use the same cell-grid anchor the run uses.
- Mesh-budget and forecast numbers use core's measured triangle cost per type.

## 5. Receipts and job

- Receipts and forecasts name the type (display name), and carry the print tag and the directional note.
- The job sends the chosen `topology` id in the `lattice` and `grading` blocks. For sheets, agree the per-region cell and anchor keys with core through a core brief.
- **Octet is unchanged**: an octet project's job JSON is byte-identical to today's (prove it with a hash), and existing tests stay green. Organic is untouched.

## 6. When core lacks something

Write a core brief the way this branch already does (`docs/handoffs/YYYY-MM-DD-core-brief-<slug>.md`), carry on with other items, and list it in the handoff. The app never edits core and never re-implements a core number in Swift.

## 7. Evidence

`docs/handoffs/evidence/2026-09-28-lattice-types-app/`:
- screenshots of **each live type** on the M2 stand, in Structural and in Aesthetic;
- the greyed states with their reasons;
- the tag sheet;
- parity numbers per type;
- the octet job-JSON hash;
- the list of core-capability probes that flipped after the merge.
