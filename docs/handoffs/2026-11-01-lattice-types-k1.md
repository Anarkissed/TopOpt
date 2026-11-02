# Handoff — 2026-11-01-lattice-types-k1: the strut generators, one type at a time (TRACK core)

Branch `claude/lattice-types-k1`, from `origin/claude/flexible-screens` at `da6cbd9f` (K0's
`0a5f86df` is in it). Plan: `docs/design/lattice-types/`. Previous core handoff:
`docs/handoffs/2026-09-28-lattice-types-core.md` (K0). Evidence:
`docs/handoffs/evidence/2026-11-01-lattice-types-k1/`.

## Where this stands, in plain language

**Live: FCC, Kelvin.** Measured and going live next, in the R2 order: Rhombic dodecahedron,
Diamond, BCC, Simple cubic (their density laws, percolation and bending floors are all measured
and in the evidence folder). Not started: Gyroid, Schwarz-D (K2). Parked: none.

<!-- STATUS -->

## What changed in core, once, for every strut type

1. **One canonical cell per type** (`topopt/strut_cell.hpp`). Octet, SC, BCC, FCC, Diamond,
   Kelvin, Rhombic as `(S, struts, nodes)` on an integer grid. `test_strut_cell` compiles the
   tensor probe's own source (`tensor_library_nine_probe.cpp`, its `main` renamed) and asserts the
   production table equals its `make_lattice()` element for element, and that the production
   voxeliser reproduces the probe's `build_cell` voxel for voxel. So the certified cell and the
   generated cell are one cell (go-live item 1), by test.
2. **The generator builds any of them through octet's machinery** (`lattice_gen.cpp`). Octet keeps
   its hand-written PR 201 tables; every other type gets a generic table from its canonical cell:
   every strut and node inside the closed cell, ownership by the cell holding the midpoint, else
   the lexicographically smallest ACTIVE cell sharing it (octet's node rule, applied to struts).
   Clipping, Rim, Diagrid (plain and freeform), the outline, streaming, determinism, Doubled and
   Stepped are the same code. Node balls are decided among the cells that hold one of the node's
   struts — diamond's cell corners are reached by no strut of the cell they cap, and without this
   a holed region emits floating balls (found by `test_strut_cell`'s first run).
3. **The run path reads the job's type** (`run_job.cpp`, `job.cpp`, `lattice_density_field.cpp`):
   the six generator calls, the certification posture, the three grading-law topologies, the
   receipts' cell reports, the uniform-lattice band, the Fit pre-flight, multiscale. K0 listed 24
   `Octet`s in `run_job.cpp`; none remain. Three new parse-time refusals, each naming its reason:
   organic with a non-octet type (it builds no cell), a region density outside the TYPE's band,
   Doubled/Stepped for a type whose R4 verdict is not PASS.
4. **Each type's own numbers in one place** (`lattice.cpp`, `type_measured`): the diameter table,
   the bending / percolation / aesthetic floors and the bending error curve, each beside the run
   that produced it. `lattice_strut_diameter_mm`, `lattice_density_from_strut`,
   `lattice_aesthetic_density_ceiling`, the floors and the adaptive aesthetic floor read it.
   `lattice_type_numbers_measured(topo)` says whether a type has them.
5. **The facts struct for the app** (`topopt/lattice_types.hpp`), **the print-tests loader**
   (`topopt/lattice_print_tests.hpp`, K4) and **the sample block** (`topopt-cli lattice-sample`,
   `topopt/lattice_sample.hpp`). See the BRIDGE CONTRACT below.
6. **The measurement harness** `core/tests/harness/lattice_types_probe.cpp` (`law`, `bend`,
   `perc`, `step`): every per-type number in this round comes out of it.

## Findings that reach past this round (measured; nothing about them is changed here)

1. **The density law is measured on the CONVERGED solid fraction, not on vpc48 voxels.**
   On a lattice-aligned voxel grid the solid fraction of a strut cell is a staircase in r,
   and it does not shrink smoothly with resolution (`law_resolution.txt`): rhombic at
   r/L 0.045 reads 0.059 at vpc48 and 0.0785 at vpc256 (-24 %); FCC at r/L 0.0667 reads
   0.0951 against 0.1026. So octet's B3 method (bisect r on the vpc48 voxels) sizes a strut
   to wherever a step falls. The tensor rows are resolution-checked AS A FUNCTION OF
   DENSITY (vpc48 vs vpc64 at matched rho), so the strut that realises a density is the
   one whose true solid fraction is that density. Each type's table is therefore bisected
   on `strut_cell_solid_fraction` (2^20 Halton points, deterministic, converged to ~0.2 %
   against 2^22), and the B3 table is reported beside it. Within the band the two differ by
   at most: FCC 2.7 %, Kelvin 3.9 %, rhombic 5.0 %, diamond 4.9 %, BCC 4.9 %, SC 4.0 %
   (`<type>_law.txt`, column "B3 gap"). **Octet's shipped table is the B3 table and is
   unchanged (R9).** FCC's B3 table equals it to four digits, which confirms octet's law
   was measured on the legs-only cell.
2. **The printed struts are lighter than the certified ones, for every type including
   octet.** The generator emits an 8-gon prism with circumradius r (area 2*sqrt(2)/pi =
   0.900 of the circle) and an icosahedral node of circumradius r; the tensor rows were
   measured on round capsules of radius r. At the same r the production solid is 6-10 %
   lighter (`<type>_law.txt`, column "as-built gap"; e.g. FCC -9.4 % at rho 0.05, -6.9 % at
   0.60). For a stretch-dominated strut that is roughly the same fraction less stiffness
   than certified. It is a property of PR 201's emitter, shared by octet, and changing it
   would move octet's bytes and the app's preview, so it is reported, not touched. A
   prism fix exists (scale the 8-gon to equal area: r x 1.0539) if the maintainer wants
   it, as its own change with its own R9 break.
3. **Q2, octet's legs-only tensor** (`octet_legs_only_report.txt`, measure only): the full
   octet is SOFTER along the cell axes than the legs-only tensor says (E100 -10.6 / -13.6 /
   -18.2 % at rho 0.25 / 0.35 / 0.45) and STIFFER along the diagonal and in shear (E111
   +13 to +16 %, C44 +15 to +19 %). So the shipped certificate over-states octet's axial
   stiffness by 12-22 % and under-states its diagonal and shear stiffness. The maintainer
   rules; nothing changed.
4. **The bending floor is far above 5 for the bending-dominated types**, as
   tensor-library-nine's T4 predicted: at 6 cells across Kelvin is still +4.6 %, rhombic
   +5.5 %, diamond +7.1 %, BCC +5.8 % (PR 235's C2b cantilever, vpc12, the same method as
   octet's). FCC crosses between 4 and 5 (5, octet's own number), SC between 3 and 4.
5. **Analyze mode records no recertified margin under aesthetic intent**, for octet too
   (byte-identical to the reference binary): `run_info.grading` has `recertified_*` only
   under structural. The `run` and `lattice-variant` paths certify the composite in both
   modes. Pre-existing; noted because "the certificate runs in both modes" is only true on
   those paths.


## FCC — LIVE

Go-live checklist (02-core-spec §4), each with its evidence in
`docs/handoffs/evidence/2026-11-01-lattice-types-k1/`:

| # | Bar | Verdict | Evidence |
|---|---|---|---|
| 1 | Production cell = measured cell | PASS | `test_strut_cell`: FCC's table equals `tensor_library_nine_probe.cpp`'s `make_lattice("fcc")` element for element (S 2, 12 struts, 4 nodes, phase 0); the production voxeliser reproduces the probe's `build_cell` exactly |
| 2 | Generates on a block and on the M2 stand; octet byte-identical; deterministic | PASS | `test_lattice_types` (ownership on a holed region, two runs same bytes, clipped + Diagrid run same bytes); the M2 stand `run` at res 64 laid and certified FCC on all four rungs (`lattice_margin` 1782 / 1717 / 1678 / 1640, accepted); octet: `r9_octet_fcc_commit.txt` (below) |
| 3 | Own density law, diameter table, printability floor | PASS | `fcc_law.{csv,txt}` (converged solid fraction; B3 beside it); `lattice_cell_printability_floor_mm` / `lattice_min_density_for_strut` read it (no octet table is read: `test_strut_diameter_per_type` 3b) |
| 4 | Own bending, percolation and aesthetic floors, with conditions | PASS | bending **5** (`fcc_bend.txt`: +54.0 / +8.9 / +4.2 / +2.6 / **+1.8** / +1.3 % at 1-6 cells; C2b cantilever, S 5 mm, vpc12, 6 cells long, cell rho 0.1991); percolation **0.75** (`fcc_perc.txt`: spanning at every placement 0 / .25 / .5 / .75 and rho 0.095 / 0.343 / 0.591 from 0.75 cells; 0.5 fails at the .25 placement); aesthetic hard floor **2** (+8.9 % and percolates; no finish relaxation, since octet's skinned 1-cell measurement is octet's) |
| 5 | Size-step verdict | PASS: Doubled and Stepped allowed | `fcc_step.txt`: S\|S/2 block 1 component, 0 dangling of 2,208 ends; S\|2S/3 interface 1 component, 0 of 1,152; octet control `octet_step.txt` the same |
| 6 | Certificate end to end, both modes; receipts name the type | PASS | M2 stand `run` Structural (4 rungs) and Aesthetic (2 rungs latticed: margins 1678 / 1639), every receipt `"topology": "fcc"` (`run_info.grading`, `.lattice`, `.lattice_export`, each `*_lattice.report.json`); the analyze path too (`fcc_stand_certificate.txt`: FCC's band 0.095-0.591 and floors read, recertified margin 66.19 against octet's 239.65 on the same job) |
| 7 | Percolation on the emitted mesh | PASS | 3x3x3 block, Doubled block and Stepped interface each one solid (`test_lattice_types`); on the M2 stand (`stand_percolation.txt`, `lattice-variant` of the FCC run's own design, rung 0.38): 48 pockets, **0 floating** (every piece reaches a cut, the solid companion or the shell); octet control on the same rung: 82 pockets, 2 the same test cannot place |
| 8 | Bridge-facing functions in the contract | PASS | BRIDGE CONTRACT below; `lattice_type_facts("fcc")` asserted field by field |

Numbers FCC now carries (all its own): band 0.09505-0.59093 (PR 246's rows, unchanged);
cells per member 5; percolation 0.75; aesthetic floor 2; aesthetic ceiling 0.2126 (strut =
20 % of the cell through FCC's law; octet's is 0.2189); smallest printable cell 2.620 x the bead at the band top;
464 triangles per cell; strut strength not measured (R10, refused in words). Print status:
not print-tested.

**Print it** (40 mm cube, 8 mm cells, band-middle density 0.343, 2.13 mm struts, 1.5 mm plate,
70,932 triangles; deterministic, `fcc_sample_40mm.stl` beside this handoff's evidence):

```bash
core/build/topopt-cli lattice-sample --topology fcc --out fcc_sample.stl
```

## Kelvin — LIVE

The same harness, conditions and checks as FCC; evidence `kelvin_*` beside FCC's.

| # | Bar | Verdict | Evidence |
|---|---|---|---|
| 1 | Production cell = measured cell | PASS | `test_strut_cell` (S 4, 24 struts, 12 nodes) |
| 2 | Generates; octet byte-identical; deterministic | PASS | `test_lattice_types`; the M2 stand `run` laid and certified Kelvin on all four Structural rungs (12-16 cells each: the 8-cell floor keeps cells coarse) and three Aesthetic ones (`kelvin_stand_certificate.txt`); octet `r9_octet_kelvin_commit.txt`: analysis_report and fields byte-identical, the one differing leaf is `/model` (the job builder writes the model path absolute) |
| 3 | Own law, diameter table, printability floor | PASS | `kelvin_law.{csv,txt}` (B3 within 3.9 %) |
| 4 | Own floors, with conditions | PASS | bending **8** (`kelvin_bend*.txt`: +62.3 / +32.9 / +18.1 / +11.0 / +7.1 / +4.6 / +3.0 / **+1.9** % at 1-8 cells, C2b vpc12, cell rho 0.1944); percolation **0.75**; aesthetic hard floor **2** (+32.9 % at 2 cells, percolates) |
| 5 | Size-step verdict | PASS: Doubled and Stepped allowed | `kelvin_step.txt`: S\|S/2 1 component, 0 dangling of 3,936 ends; S\|2S/3 1 component, 0 of 1,992 |
| 6 | Certificate, both modes; receipts name it | PASS | every receipt `"kelvin"`; analyze Structural recertified margin 99.66, accepted, on Kelvin's band 0.094-0.505 and floor 8 |
| 7 | Percolation on the emitted mesh | PASS | block, Doubled and Stepped one solid (`test_lattice_types`); M2 stand rung 0.38: 14 pockets, **0 floating** (`kelvin_stand_percolation.txt`) |
| 8 | Bridge contract | PASS | `lattice_type_facts("kelvin")` |

Numbers: band 0.09375-0.50521; cells per member 8; percolation 0.75; aesthetic floor 2; aesthetic
ceiling 0.2065; smallest printable cell 2.793 x the bead; 1,008 triangles per cell; strut strength
not measured. Not print-tested.

**Print it** (40 mm cube, 8 mm cells, rho 0.300, 2.00 mm struts, 1.5 mm plate, 141,612 triangles;
`kelvin_sample_40mm.stl`):

```bash
core/build/topopt-cli lattice-sample --topology kelvin --out kelvin_sample.stl
```

<!-- PER TYPE -->

## BRIDGE CONTRACT (02-core-spec §5) — what the app calls, and what each answer means

Everything below is in core today. The app keeps a type hidden until its own preview is
built (A2); nothing here forces a type onto the screen.

### Which types exist, and which are live
| call | header | answer |
|---|---|---|
| `lattice_type_ids()` | `lattice_types.hpp` | the picker's order: `octet` first (M4), then `sc`, `bcc`, `fcc`, `diamond`, `kelvin`, `rhombic`, `gyroid`, `schwarz_d` |
| `lattice_gen_topology_names()` | `lattice_gen.hpp` | the GENERATABLE ids; grows by one per type that goes live |
| `lattice_certifiable_topology_names()` | `lattice.hpp` | the CERTIFIABLE ids (unchanged by this round for struts) |
| `lattice_type_readiness(id, gen, cert)` + `lattice_type_readiness_plain(r)` | `lattice.hpp` | `Live` = offer it; anything else = grey it with core's plain words |

### One plain struct per type: `LatticeTypeFacts lattice_type_facts(id)` (`lattice_types.hpp`)
| field | meaning |
|---|---|
| `id`, `display_name`, `family` | core id; Q5's default name; `"strut"` or `"sheet"` |
| `readiness`, `readiness_plain` | as above |
| `numbers_measured` | true only when every number below is THIS type's own measurement; when false they are NaN, never octet's (R1) |
| `rho_min`, `rho_max` | the certifiable band |
| `cells_per_member_min` | bending accuracy floor (cells across a member) |
| `percolation_cells_per_member_min` | below it the struts do not hold together |
| `aesthetic_hard_floor_cells` | the aesthetic floor; no "with a finish" relaxation for the new types |
| `printable_cell_per_bead` | smallest printable cell = this × bead width (at the band top) |
| `aesthetic_density_ceiling` | R11 "prints open": strut diameter = 20 % of the cell, through the type's own law |
| `outline`, `rim`, `diagrid` | `{allowed, reason}` (R8) |
| `uniform`, `doubled`, `stepped` | `{allowed, reason}` (R4 measured; R5 for sheets) |
| `directional`, `directional_note` | R3 (SC, BCC): show the note on the picker and the receipt |
| `triangles_per_cell` | the per-cell emitted cost of the infinite tiling (8-gon prism 32, node 20) |
| `strut_strength_measured`, `strut_strength_note` | R10: false + "Strut strength is not measured for this type." for every new type |
| `cell_denominator` | S of the canonical cell (struts) |

Print status is maintainer data, joined by id:
`load_lattice_print_tests_file(path)` + `lattice_print_status(tests, id)` (`lattice_print_tests.hpp`):
`{listed, print_tested, date, note}`. **An id with no row reads as not print-tested.** The
loader refuses a malformed file by name; it accepts every core topology id plus `gyroid`
and `schwarz_d`.

### Struts: the geometry the preview draws (R12, M5)
| call | answer |
|---|---|
| `lattice_strut_cell(topo)` (`strut_cell.hpp`) | `{S, struts, nodes}`: integer coordinates in units of L/S, phase 0 at the cell's min corner. Canonical: a strut belongs to the cell holding its midpoint (half-open), a node to the cell holding it. |
| `strut_cell_closed_struts(cell)`, `strut_cell_closed_nodes(cell)` | every translate inside the CLOSED cell, for a renderer that draws cell by cell |
| `lattice_strut_diameter_mm(topo, rho, cell)` | the strut diameter core builds (the prism's circumradius is half of it) |
| `lattice_density_from_strut(topo, cell, radius)` | the other direction |
| `lattice_gen_topology_from_id(id)` | refuses an id core cannot build, by name |

The generator's ownership rule (so the preview places exactly what the run builds):
a strut is emitted by the cell whose half-open box holds its midpoint when that cell is
active; otherwise by the lexicographically smallest ACTIVE cell (i, then j, then k) that
shares it. A node ball is emitted the same way, but only among the cells that hold one of
its struts — a node no active cell's strut reaches is not emitted (diamond's cell corners
are the case that needs this).

### Every existing per-topology call accepts the new ids
`lattice_derive_cell_for_member`, `lattice_rho_min/max`, `lattice_cells_per_member_min`,
`lattice_percolation_cells_per_member_min`, `aesthetic_cells_per_member_hard_floor`,
`aesthetic_cells_per_member_floor`, `lattice_cell_printability_floor_mm`,
`lattice_min_printable_cell_mm`, `lattice_min_density_for_strut`,
`lattice_aesthetic_density_ceiling`, `stepped_size_menu`, `lattice_prints_open` — each
answers from the type's own measurement for a live type and refuses (never borrows) for
one that is not.

### The job (unchanged keys)
`lattice.topology` / `grading.topology` take any live id (they must agree, as before).
New refusals, each naming the reason: `algorithm: "organic"` with a non-octet type; a
region `relative_density` outside the TYPE's band; Doubled/Stepped for a type whose R4
verdict is not PASS. Multiscale refuses every type but octet (its material model needs
octet's upper rows), with core's existing reason. Receipts name the type:
`run_info.grading.topology`, `lattice_topology`, `lattice_export_topology`.

### The sample block
`topopt-cli lattice-sample --topology <id> [--cell 8] [--rho <band middle>] [--size 40]
[--plate 1.5] [--bead <mm>] --out <file.stl>` writes the STL and `<file.stl>.json`.
`topopt-cli --version` now ends with `lattice_sample=1`, so a worker can tell without a
trial run (brief item g).


## Octet stays byte-identical (R9) — how it was proved

- **Reference binary**: `topopt-cli` built from a `git archive` of the base `da6cbd9f`, copied to a
  directory and `chmod a-w` before any run (K0's warning: rebuilding under a measurement voided
  its evidence twice). The new binary is frozen the same way.
- **The M2 stand, both paths, both modes** (`r9_octet_fcc_commit.txt`, by `r9_compare.py`): analyze
  Structural and Aesthetic (res 128) and `run` Structural (res 64, four rungs, both exported lattice
  STLs) — every file byte-identical except the leaves that name the binary or the clock
  (`fingerprint`, `build_time`, `created_wall_ms`, `*_ms`, `*_s`, `gen_fraction`, the output path
  inside `*_alpha.meta`). The comparison script was proved able to fail: octet against FCC goes RED
  with 33 real differences.
- **The named test binaries, base vs HEAD** (`identity_<type>.txt`; the reviewer has not yet said
  which 17 make "the 17-test", so this is the superset of every lattice / grading / cell-plan /
  stepped / job / analyze / orientation binary, 21 of them, stdout and stderr with the `[mg] S7`,
  `[mg-safe]` and `[loose] flood fill` lines dropped). See each type's line below for the count and
  what the differing ones differ in.

### Gate per type (one full ctest + cli_demo + the identity diff before each push)

| type | ctest | cli_demo | identity diff (21 binaries) |
|---|---|---|---|
| FCC | 165 / 165 passed, 4,347 s (`ctest_fcc.txt`) | passed, 1,994 s | 18 identical; 3 differ only in: `test_lattice_gen` 29 -> 30 checks (its enum tripwire checks one name per generatable type, and `fcc` is one more), `test_lattice_variant` a wall-time line, `test_lattice_void_exterior` the build directory's path inside two output lines (`identity_fcc.txt`) |
| Kelvin | 163 / 165 in the gate's archive copy; the two that failed (`app_core_capability_mirror`, `smooth_brush`) read `../app` and `../docs`, which a `git archive` of `core/` does not carry, and both pass re-run in that same build with the trees linked (`ctest_kelvin.txt`); the pipeline now links them | passed, 1,965 s | 19 identical; `test_lattice_gen` (one more tripwire name) and `test_lattice_void_exterior` (build path) as before (`identity_kelvin.txt`) |

Tests added for the round: `test_strut_cell` (237 checks), `test_lattice_types` (85). Edited, each
because it was built to flip when a type goes live: `test_strut_diameter_per_type` (FCC leaves the
"must refuse" loops, which now skip every type with its own law; section 3's certifiable-but-no-law
example moves from FCC to Kelvin; new section 3b pins FCC's law), `test_job` (FCC moves from
"known but not live" to "live parses on both keys").

<!-- TESTS -->
