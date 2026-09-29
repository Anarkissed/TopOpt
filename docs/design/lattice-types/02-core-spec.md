# 02 — Core work

**Plain language:** core already knows how stiff every new type is. What it doesn't have is everything built for octet alone:
- the generator that writes the struts;
- the table that turns "density 0.3 at an 8 mm cell" into "a 1.2 mm strut";
- the size limits;
- the check that cells of different sizes still join up.

This file lists where those octet-only pieces are, how to measure each type's own numbers, how to build the two sheet types, and the checklist a type must pass before the app may offer it.

Line numbers refer to PR 358's branch (`claude/raster-receipt-fields`) at `daa764c4`. Re-grep them; they will drift.

---

## 1. The octet-only inventory (a starting list; the agent completes it)

| Where | What is octet-only | What it needs |
|---|---|---|
| `core/include/topopt/lattice_gen.hpp:47` | `enum class LatticeGenTopology : int { Octet };` The production generator makes only octet. | The six strut types, then the two sheets. `lattice_gen_topology_names()` grows as each type goes live (§4). |
| `core/src/mesh/lattice_gen.cpp` | Octet's struts are hard-coded (from PR 201's probe). | The canonical-cell tables from `evidence/2026-07-27-strut-lattice-family/strut_lattice_gen.cpp`: integers in L/S, a strut owned by the cell holding its midpoint, streaming, deterministic. Octet must stay **byte-identical**. |
| `core/src/fea/lattice.cpp:401` `octet_strut_diameter_mm`, `:386` `kOctetDia` | Octet's measured diameter table. | One table per type (§2.2). |
| `core/src/fea/lattice.cpp:428` `lattice_cell_printability_floor_mm(topo, …)` and `:441` `lattice_min_density_for_strut(topo, …)` | Take a topology but **read octet's diameter table for every type**. | Read the type's own table. Octet's results stay unchanged. |
| `core/src/fea/lattice.cpp:314` `lattice_cells_per_member_min` | Returns 5 for every type. Its own comment calls this a placeholder, likely **too low** for SC, BCC, Diamond and Kelvin. | A measured value per type (§2.3). |
| `core/src/fea/lattice.cpp:329` `lattice_percolation_cells_per_member_min` | Returns 1.0 for every type (octet, axial, ρ ≈ 0.199 only). | A measured value per type (§2.3). |
| `core/src/fea/lattice.cpp:639` `octet_relative_density` | Octet voxelisation at vpc48. | The same function, per type. |
| `core/include/topopt/lattice.hpp:610–635` `kOctetAestheticStrutPerCell`, `octet_aesthetic_density_ceiling()` | Ruling D's ceiling, for octet. | The same geometry per type (R11), bisected through that type's own diameter table. |
| `core/include/topopt/strut_strength.hpp` | Octet's strut law (PR 259). It already refuses other types. | Each type's own law, or keep the stated refusal (R10). |
| `core/include/topopt/job.hpp:213`, `:407` | `topology = "octet"; // only "octet" is implemented` | Parse the new ids. Unknown ids still refuse. |
| `core/src/cli/run_job.cpp` (88 mentions), `core/src/simp/grading.cpp` (25), `cell_plan.cpp` (7), `stepped_plan.cpp` (5), `beam_network.cpp` / `.hpp`, `lattice_density_field.cpp`, `build_orientation.cpp`, `observability.hpp` receipt fields | Octet assumed, named or defaulted. | Classify every site as (a) already topology-free, (b) needs a per-type number, or (c) needs new logic. Put the table in the handoff **before** changing code. |

## 2. The six strut types

### 2.1 Geometry
- **The production canonical cell must be the one the tensor rows were measured on.** The rows came from `core/tests/harness/tensor_library_nine_probe.cpp`. Write a test that compares its strut list for each type with the production table: same S, nodes, struts and phase. The shipped "octet" rows were measured on a different geometry from the one the generator builds (tensor-library-nine finding 3). Don't repeat that.
- Reuse every generator property octet has:
  - streaming, with flat peak RSS;
  - determinism;
  - cell-local ownership;
  - boundary activation by overlap;
  - struts clipped to the allowed region eroded by their own radius;
  - the no-protrusion invariant against the shell;
  - Rim;
  - Diagrid, including the freeform version;
  - the solid outline beam;
  - the octree / stepped cell plans.

  Where any of these reads octet's geometry, generalise it.
- Nodes: keep octet's node treatment. The **union-volume acceptance test** (`lattice_union_volume.hpp`) must pass per type, and so must the percolation (connected-component) check on the emitted mesh.

### 2.2 Density ↔ strut size (per type)
Measure it the way octet's was measured:
- `octet_relative_density`: voxelise one periodic cell at vpc48.
- PR 235's B3 table (`evidence/2026-07-28-graded-cell-size-phase0/b3_printability.csv`): strut diameter at a 4 mm cell over ρ 0.05–0.60, exactly linear in cell size.

K·(r/L)² from `density.txt` is the low-density check only; nodes overlap as density rises. Report the n-gon-prism-versus-cylinder gap per type.

### 2.3 Floors (per type; state the conditions of every number)
- **Bending accuracy floor.** PR 235's guided-cantilever study (`core/tests/harness/graded_cell_size_probe.cpp`, C2b): resolved struts against a homogenised macro beam at 1…6 cells across, crossing the 2.4 % band. Octet: 1c +48.5 %, 2c +8.5 %, 3c +4.1 %, 4c +2.59 %, 5c +1.78 %, hence 5. Report the crossing and the ρ used.
- **Percolation floor.** Connected components of members 0.5 / 0.75 / 1 / 1.5 cells across, at the band's low, middle and high ρ.
- **Aesthetic hard floor (2).** Report each type's bending error at 2 cells, and whether it percolates at 2. If it doesn't, that type's aesthetic floor rises to where it does. Say so.
- Write each number into the per-type functions, in one place each. Octet's numbers stay as they are.

### 2.4 Cell-size steps (R4)
For each type, build a block with an S | S/2 interface (Doubled) and one Stepped interface (a k·S/n tile from the stepped menu). Weld it, then count connected components and **strut ends that land on no node of the neighbouring cell**. The type passes only with one component and zero dangling ends; then Doubled and Stepped are allowed for it. Otherwise core refuses them for that type, with a one-line reason the app can show.

Grading, the stepped plan and the beam-network certificate (`structural_certification: "beam_network"`, which Stepped requires) must build their spans from the type's own canonical cell.

### 2.5 Certification and receipts
- The tensor rows exist. Run the whole path end to end, Structural and Aesthetic, on the maintainer's M2 stand job used in PR 358's evidence. Every receipt names the topology.
- SC and BCC receipts carry the directional note (R3).
- `observability.hpp` receipt fields that say "octet" take the real topology. Octet's receipts stay byte-identical.

### 2.6 Strut-strength report (R10)
Run PR 259's de-homogenisation probe (`core/tests/harness/lattice_dehomog_probe.cpp`) per type, with the same envelope over bulk, free-surface and cut cells. Where that isn't done, the report says "not measured for this type". It never borrows octet's numbers. It remains report-only.

## 3. The two sheet types (Gyroid, Schwarz-D)

- **Field (R7).** `core/include/topopt/tpms.hpp` holds a small, pure, dependency-free module:
  - value and gradient for each type;
  - the PR 198 probe's exact formulas, with period L and phase 0 at the cell grid's anchor;
  - the wall as \|f\|/\|∇f\| ≤ t/2, with a signed-distance estimate d(x) ≈ \|f\|/\|∇f\| − t/2 for the mesher.

  It is documented so Flexible's C2 can call it unchanged.
- **Tensor rows re-measured on this wall** (01-types §B, trap 1):
  - use the PR 198 probe;
  - resolution-check vpc32 → vpc48 → vpc64;
  - land resolved rows only;
  - push the low end as far as the resolution allows (the PR 237 method).

  Add each type to `LatticeTopology` and make it certifiable only after this.
- **Wall-thickness law.** Measure the true normal wall thickness t against ρ (and t/L). This is what printability checks.
- **Printability (R6).** t ≥ one bead (`min_extrudable_width_mm`, the key the strut floor already reads). Report the ρ at which each cell size reaches one bead and two beads.
- **Generator:**
  - the existing dual-contouring mesher (`core/include/topopt/lattice_dc.hpp`) on the field's distance estimate;
  - clipped by **the same surface** the skin and outline come from;
  - unioned with the solid outline;
  - streamed.

  Acceptance is by union volume: the mesh volume against a voxel integral of the field. Record the **triangle count** on the M2 stand region against octet at the same cell.
- **Grading (R5).** ρ(x) → t(x) at a fixed cell size per region. Doubled and Stepped are refused with the reason. Two sheet regions that touch must share cell size and phase, or core refuses (a solid outline between them is the alternative). Use the same cell-grid anchor the app sends, so preview and run agree.
- **Floors (§2.3)** in bending and percolation. PR 221's scale-separation numbers are axial only (01-types §B).
- **Skins (R8).** Outline and Rim are allowed. Diagrid is refused with the reason.
- **Certificate and report.** Run the same end-to-end certificate as the struts. The sheet-stress report comes from the PR 259 method on sheets, or a stated refusal.

## 4. Go-live checklist (per type; all must hold, R1)

1. The production cell equals the measured cell (struts: the tensor-library-nine table; sheets: the re-measured rows).
2. Generates on a test block and on the M2 stand. Octet stays byte-identical. Streaming and deterministic (two runs, same hash).
3. Own density law, diameter or wall table, and printability floor. No octet table is read.
4. Own bending floor, percolation floor and aesthetic-floor check, with their conditions stated.
5. Size-step verdict (struts) or refusal (sheets), with a reason string.
6. The certificate runs end to end in both modes. Receipts name the type.
7. Percolation on the emitted mesh: one component per connected region.
8. Bridge-facing functions exist and are listed in the BRIDGE CONTRACT (§5).

Only then does the type enter `lattice_gen_topology_names()` and `lattice_certifiable_topology_names()`. One commit per type, in the R2 order.

## 5. What the app will need (proposed; the agent publishes the final list as the handoff's BRIDGE CONTRACT)

- The names: `lattice_gen_topology_names()` and `lattice_certifiable_topology_names()` (both exist; they grow).
- **Per-type facts:**
  - family (strut or sheet);
  - band (ρ min and max);
  - accuracy, percolation and aesthetic hard floors;
  - printability floor per bead width;
  - aesthetic density ceiling;
  - finishes allowed (outline, Rim, Diagrid), each with a reason if refused;
  - cell modes allowed (uniform, Doubled, Stepped), each with a reason if refused;
  - the directional-note flag;
  - the measured triangle cost per cell;
  - print status.

  One plain struct per type.
- **Struts:** the canonical cell (S, integer nodes, integer strut pairs). Diameter at (ρ, cell). ρ at (cell, radius).
- **Sheets:**
  - field value and gradient at a point;
  - wall thickness at (ρ, cell);
  - a deterministic sampler returning N (point, value) pairs, for the app's parity test.
- The existing per-topology core functions accept every new id. That means `lattice_derive_cell_for_member`, `lattice_rho_min` / `max`, the aesthetic floors, and everything the app's bridge wrappers call (for example the app's `lattice_region_derivation` in `TopOptBridge.hpp`).

## 6. Print status and the sample block

- **Loader** for `core/src/materials/lattice_print_tests.json`, as strict as `materials.cpp`: unknown keys and missing required keys are refused. It exposes `print_tested`, `date` and `note` per id. Agents never edit the file.
- **Sample block (R13).** A CLI subcommand: `topopt-cli lattice-sample --topology <id> [--cell 8] [--rho <band middle>] [--size 40] --out <file>`:
  - production generator;
  - 1.5 mm solid base plate;
  - no internal supports;
  - a small receipt: type, ρ, cell, strut or wall size, triangle count.

## 7. The octet legs-only report (Q2: measure, don't change)

The full-octet rows exist (`evidence/2026-07-29-tensor-library-nine/csv/octet_sweep.csv`, band 0.207–0.480). Compare them with the shipped legs-only rows at matching ρ, and report E100, E111, C44 and Zener side by side. Answer two questions:
- Does using the legs-only tensor for the full octet over-state or under-state stiffness?
- By how much, at ρ 0.25 / 0.35 / 0.45?

Change nothing. The maintainer rules.

## 8. Evidence to produce

`docs/handoffs/evidence/2026-09-28-lattice-types-core/`:
- the §1 inventory table;
- per-type CSVs for §2.2–2.4 and §3;
- the go-live checklist per type, with PASS/FAIL;
- 40 mm sample-block STLs for every type that went live;
- triangle counts;
- the §7 table;
- octet byte-identity hashes.
