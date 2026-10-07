# Handoff — 2026-09-28-flexible-squish-maths (TRACK core, C1): Flexible squish maths

## In plain words

**What I built.** The maths behind the new Flexible ("Squish") stage, in core, so the app
can draw everything from one definition. It loads the filament file and Iacob's squish
table strictly; looks up how hard a lattice pushes back at a given squish, and inverts
it (what density gives this squish under this weight?); evaluates the pen curves the
user draws; works out each loaded face's frame and the "stack" of material behind it,
down to the face at the other end; turns the curves into a target squish map, a
density per column and a 3D density field (with a blend where a top stack meets a side
stack); smooths it to what can be built; presses stamps (thumb, palm, heel) on it; and
picks gyroid or honeycomb and the temperature, with reasons. A `flexible` job block and
`topopt-cli flexible` write SVG heat maps, a CSV of columns and a receipt.

**What I measured.** Every one of Iacob's 72 published numbers (36 rows × 10 % and 20 %
strain, read on the core-strain axis after review round 1) comes back from the lookup to
2e-16. Inverse → forward round trips agree to 5e-15. Three scenario runs on generated boxes (a pad with a soft centre; the same pad
designed under a thumb and checked under a palm and a heel; a block loaded on top and
on a side) produce the pictures in `docs/handoffs/evidence/2026-09-28-flexible-squish-maths/`.
The heel check shows the honest answer: a pad drawn for 30 kg spread evenly is squished
past the tested strain under a 300 N heel, and the map says "no number" there instead
of inventing one.

**Status (2026-09-29): synced onto #354's app fix; the app builds.** Core done, review
round 1 done. History: the app-macos build failure was INHERITED, not mine:
`bridge.cpp:2708` (#354) reads `OrganicGenStats::filleted_spans`, which #358's `5846c476`
removed. The maintainer ruled that #354 fixes it (the app stops reading the field; no stub in
core), and the #354 agent is doing it. On "sync" I run SYNC → SYNC CHECK → push → FULL CHECK.

**What's next.** C2 (the lattice recipe) turns the density field into gyroid/honeycomb
walls and bead paths; A1 (the app screens) calls the functions in the BRIDGE CONTRACT
below. Nothing here is a certificate: every depth carries a tier and a band (R7).

## Task
C1 of docs/design/flexibles/07-roadmap.md: the Flexible stage's squish maths in /core/ —
loaders, lookup (inverse and forward), pen curves, face frames and stacks, squish maps
→ density field, stamps, the Auto recommender, a `flexible` job block and a CLI.

## Synced commits

**Latest sync (2026-09-29, pushed head `2405ddec`):**

| branch | last synced commit |
|---|---|
| #354 `claude/topopt-holes-quilting-298212` | `026904dd` Core #358, the app side: the overhang flare is gone — slot 47 retired … |
| #358 `claude/raster-receipt-fields` | `8414af47` Every symbol and key #358 removed, grepped against the app … |
| `main` | `f932266f` Merge pull request #360 (lattice types setup) |

All three merges were clean, no conflicts (`6171a6af` #358, `3d0c1e92` #354, `2405ddec` main).
#354 carries no build output. SYNC CHECK on `2405ddec`: core `ctest -E cli_demo` **139/139**,
`build_core.sh` exit 0, `swift build --package-path app/TopOptKit` **Build complete!**

First sync (2026-09-28): #354 `ec2af861`, #358 `daa764c4`, main `ce28b6fa`; `git log --oneline -5`
after setup: `d615a55c` Sync: merge #354 · `b378ce52` Sync: merge #358 · `ec2af861` · `08cb757c` · `da01c9b8`.

## What I did

All Flexible code is in NEW files:

| file | F-items |
|---|---|
| `core/include/topopt/flexible/error.hpp` | `FlexibleError` (malformed input, thrown) and `Refusal` (data does not cover it, returned) |
| `flexible/data.hpp`, `src/flexible/data.cpp` | F1 strict loaders; F2 density axis |
| `flexible/squish.hpp`, `src/flexible/squish.cpp` | F3 lookup, inverse, soft/rigid forward; F10 tiers and bands; the cell-size relation |
| `flexible/curve.hpp`, `src/flexible/curve.cpp` | F4 monotone pen curve (Fritsch–Carlson) |
| `flexible/faces.hpp`, `src/flexible/faces.cpp` | F5 face frames and stacks |
| `flexible/field.hpp`, `src/flexible/field.cpp` | F6 squish maps and the 3D field + handover; F7 buildable; F8 stamps |
| `flexible/recommend.hpp`, `src/flexible/recommend.cpp` | F9 Auto |
| `flexible/job_block.hpp`, `src/flexible/job_block.cpp` | F11 the job block, the Flexible region mask, the runner guard |
| `flexible/run.hpp`, `src/flexible/run.cpp` | F12 `topopt-cli flexible` (SVG, CSV, receipt) |
| `src/flexible/json.{hpp,cpp}` | module-local JSON reader/writer (house style: each module keeps its own) |
| `core/tests/unit/test_flexible_{data,squish,curve,faces,field,recommend,job,run}.cpp`, `flexible_test_boxes.hpp` | tests |
| `core/tests/tools/flexible_spot_table.cpp` | evidence tool (EXCLUDE_FROM_ALL) |

Hook lines in shared files (additive only; nothing reformatted, reordered or renamed):

| file | lines | what |
|---|---|---|
| `core/include/topopt/job.hpp` | +9 | `#include <memory>`, `struct JobFlexible;`, `std::shared_ptr<const JobFlexible> flexible;` (null when absent) |
| `core/src/cli/job.cpp` | +16 −1 | `"flexible"` added to the allowed top-level keys (the one changed line); the block parsed by `parse_flexible_block`; a job with `lattice`/`grading` AND `flexible` refused |
| `core/src/cli/run_job.cpp` | +5 | one include; `refuse_flexible_job(job, …)` as the first line of `run_job`, `analyze_job`, `lattice_variant_job`, `preflight_job` |
| `core/src/cli/main.cpp` | +53 | the `flexible` subcommand, one usage paragraph |
| `core/CMakeLists.txt` | +38 (appended) | the sources (always-built library), the tests, the CLI default path, the tool |

`observability.hpp` is NOT touched: an earlier version put the receipt into `RunInfo`,
and the resulting run_info.json carried 163 optimizer fields (several named `margin`)
into a stage that must show no margin (R7). The Flexible runner writes its own
run_info.json: provenance, mode, material, format, resolution and the `flexible` block.

**Why the always-built library.** The app's iOS slices can be built without OCCT, where
`run_job.cpp` is not compiled. Everything A1 calls must link on every slice, so the
Flexible region mask re-states `run_job.cpp`'s `lattice_role_regions_from_job` +
`multiscale_region_mask` precedence with the same public primitives
(`resolve_face_regions`, `region_member_voxels`, `cut_voxels`, `region_depth_layers`,
`resolve_clearance_manual/_from_face`, `LatticeBoundary`). See Warnings.

**Regions are parsed by the lattice parser.** `flexible.regions` is handed to
`parse_job` inside a stand-in `lattice` block, so a Flexible region and a lattice region
cannot mean different things (M10). The lattice-only keys `relative_density` and
`synthetic_*` are refused first with a Flexible message.

**The bead width key.** `min_extrudable_width_mm` — the key the lattice strut floor reads
(`lattice.min_extrudable_width_mm` / `grading.min_extrudable_width_mm`, "the thinnest
bead the user says the machine lays"; `organic_strut_width_mm` defaults to it). Not
ambiguous: `wall_line_width_mm`/`_outer_mm` are the perimeter-wall widths of the
knockdown gate, not the strut floor. A Flexible job cannot carry `lattice`/`grading`,
so the block states the same key with the same meaning; required, > 0.

**The strain convention (changed in review round 1).** CORE strain. The loader converts
every table curve once, with each entry's own `specimen.height_mm` and `skin_total_mm`:
ε_core = ε_nominal × height / (height − skin) (12.5 / 10.9 for Iacob), stress
unchanged; the skins are treated as rigid (under 3 % effect at the stiffest row). The
zones move with it: measured ≤ 0.2294, extrapolated ≤ 0.2867, refused beyond. The
column height is the latticed length; skins IN THE PART are not yet subtracted (C2 does),
so a skinned face currently reads high by about skin / height. Recorded in every receipt
(`strain_convention`). The first version applied no correction and under-predicted
squish by 5–13 %.

## F-items

| F | verdict | evidence |
|---|---|---|
| F1 strict loaders | **PASS** | `test_flexible_data` (111 checks): the live files load (10 filaments, 36 entries, bands 0.40/0.20/0.50, varioShore offers exactly 190/220/240); unknown keys refused at top, material, drying, modulus, band, entry, specimen levels; missing required keys (including required-but-nullable ones) refused; non-monotone / flat / single-point / origin-point loading refused; relative_density 0 and 1.2 refused, 1.0 accepted; nulls stay `known = false` (TPU95A modulus, varioShore drying/retraction); duplicate JSON keys and out-of-range numbers refused; cross-file checks (unknown material, unlisted table, duplicate ids). |
| F2 density axis | **PASS** | `test_flexible_data`: the map reproduces every 190 °C `est_core_relative_density` EXACTLY; every 220/240 °C row takes the 190 °C value of its nominal %; gyroid axis 0.143–0.362, honeycomb 0.165–0.446 (02 §2); `density_basis = "estimated_core (190 °C mapping)"` on every set and every receipt; ambiguous maps (two temperatures, a nominal off the map, a decreasing map) refused. |
| F3 lookup | **PASS** | `test_flexible_squish` (9,676 checks): all 72 Table 2 values (typed from the paper) within 1e-9 (tool: 2.7e-16, `iacob_spot_checks.md`); the example 20 % gyroid 190 °C ε 0.20 → 0.292 MPa; piecewise-linear through the origin; linear in ρ; extrapolated zone flagged, beyond refused (core strain after review round 1: 0.2294 / 0.2867); σ strictly increasing in ρ and in ε on dense grids for all six sets; round trip inverse → forward worst 5.5e-16 (ρ) / 4.4e-15 (ε); every refusal path (negative strain, beyond data, below/above ρ range, untested temperature 205 °C, octet, calibrate_first, proxy_candidate, unknown material, too_firm/too_soft/beyond_data/no_pressure with the nearest achievable depth); rigid press equilibrium Σaσ = F to 1e-9. |
| F4 pen curve | **PASS** | `test_flexible_curve` (61): passes through every point; never leaves its two neighbours' [min, max] (11 shapes incl. interior extremes); S-curve monotone; flat, 2-point, plateau; refusals. Positive control: naive tangents → 5 checks red. |
| F5 frames and stacks | **PASS** | `test_flexible_faces` (46): top face → load −Z, X +X (long side), Y = load × X, 100 × 60 extents, stack 20 mm, linked bottom (face 0 / region 100, 100 %); side face → side flag (and not with build X); 40° fold flagged, 10° not; rotation 90/180/270 exact, 45 refused; square face → tie rule; a cut sector gets its own frame. `test_flexible_field`: top + bottom → conflict naming 101 and 100 over the whole block; top + side → one handover pair, blended band inside the overlap, nearest-face density at both ends, the average at equal depth. STL faces reachable: `StepModel` pseudo-faces (evidence (a)–(c)). |
| F6 maps → field | **PASS** | `test_flexible_field` (59): both / either / centre→edge exactly as defined; target = S·D; design stamp pressure under it (20 N conserved), even spread elsewhere; target density carries the design pressure at the target strain; clamped too_firm / too_soft / beyond_data each tested; 3D field assembled with handover; receipts count clamped columns per face. |
| F7 buildable | **PASS** | flat map: buildable == target exactly; graded map: σ = ½ cell (gyroid 3.0915 t/ρ), buildable = forward at the smoothed density, stays inside the table; σ range and the parameters in the receipt (`smoothing_sigma_mm`, `buildable_smoothing`, `bead_width_key`). Labelled heuristic. |
| F8 stamps | **PASS** | force check 0.4 % accepted / 0.6 % refused; negative / wrong-size grids refused; soft depth = forward per column; rigid on a uniform lattice = soft; rigid past the data refused; soft past the data flagged per column; off-face force reported; 10 mm stamp flagged narrow (< 3 cells). Evidence (b): palm and heel. |
| F9 Auto | **PASS** | `test_flexible_recommend` (17): springy → gyroid, damped → honeycomb when both reach; only gyroid reaches 3 mm → gyroid with `only_family_reachable`; side stack → honeycomb ineligible (`honeycomb_side_stack`); temperature choice with a named tiebreak and 190 °C's failure recorded; nothing reachable → face, kind, where, nearest; calibrate_first → no recommendation. Positive control: inverted feel → 5 red. |
| F10 tiers and bands | **PASS** | literature ±40 %, calibrated ±20 %, proxy ±50 %, side stack and 2-bead walls → estimated ±50 % (`test_flexible_squish`, `test_flexible_field`); calibrate_first → refusal with reason, no numbers (`test_flexible_run`, the receipt carries `refusal`, no density map is written). |
| F11 job block | **PASS** | `test_flexible_job` (36): parse, defaults, strictness, refusals (with lattice; unknown/missing keys; material mismatch; bad temp/topology/beads/width/mode/curve/rotation/weight; undeclared or duplicated face; no loaded face; resting face with a load; skin_on required; stamp force; check stamp on a resting face; bad region role via the lattice parser; relative_density). Absent block ⇒ null member. Byte-identity: see below. |
| F12 CLI | **PASS** | `test_flexible_run` (40): all files written, the receipt's keys, one CSV row per column, refusals (`one_profile_per_stack`, `calibrate_first`, `temperature_not_tested`, `honeycomb_side_stack`) still write the receipt and the drawn map but no prediction; `run_job`, `analyze_job`, `lattice_variant_job`, `preflight_job` each refuse a flexible job (positive control: guard removed → red). Evidence (a)–(c). |
| F13 no regression | **PASS** (core) | Three existing jobs run through the base binary (`d615a55c`) and this branch: the demo fixture job (`run`, `analyze`) and test_mesh_job's plate-bore job. Every output byte-identical except wall-clock timing fields, the out-dir path quoted in `*_alpha.meta`, and lib3mf's random per-file `p:UUID`s inside the 3MFs (geometry identical) — `identity_result.txt`, comparer `harness/identity_compare.py` (positive control: a changed resolution is caught). Existing tests unchanged; no new dependency; `materials.json` untouched. App: see Blocked. |


## Test evidence (raw, pasted, unedited)

**Configuration:** macOS arm64, Release, OCCT + Eigen + lib3mf (arm64-osx-dynamic) — the
same three dependencies as CI's core-linux, **132 tests on the base, 140 on this branch**
(`ctest -N`); none are missing locally. The machine was shared with other sessions' heavy
jobs throughout.

**Base SYNC CHECK** (separate worktree at `d615a55c`, built clean):
```

Total Test time (real) = 3438.46 sec

The following tests FAILED:
	116 - cli_demo (Timeout)
Errors while running CTest
CTEST_EXIT=8
```
`cli_demo` hit the `--timeout 3000` I passed (CMake sets none; CI sets none). Rerun alone,
no timeout:
```
1/1 Test #116: cli_demo .........................   Passed  3220.15 sec

100% tests passed out of 1

Total Test time (real) = 3220.16 sec
EXIT=0
```
⇒ base core: **132/132**. Base app: `build_core.sh` exit 0; `swift build --package-path
app/TopOptKit` **FAILS** — see Blocked.

**Branch core suite** (commit `8759d85d`; the later commit changes one sentence's wording
and was re-tested with the eight Flexible suites + the harness):
```

Total Test time (real) = 3464.75 sec

The following tests FAILED:
	116 - cli_demo (Timeout)
Errors while running CTest
CTEST_EXIT=8
```
```
129/140 Test #133: flexible_data ....................   Passed    0.30 sec
130/140 Test #134: flexible_squish ..................   Passed    0.28 sec
131/140 Test #135: flexible_curve ...................   Passed    0.24 sec
132/140 Test #136: flexible_faces ...................   Passed    0.28 sec
133/140 Test #137: flexible_field ...................   Passed    0.99 sec
134/140 Test #138: flexible_recommend ...............   Passed    0.29 sec
135/140 Test #139: flexible_job .....................   Passed    0.45 sec
136/140 Test #140: flexible_run .....................   Passed    0.53 sec
```
`cli_demo` rerun alone, no timeout:
```
1/1 Test #116: cli_demo .........................   Passed  3156.88 sec

100% tests passed out of 1

Total Test time (real) = 3156.89 sec
EXIT=0
```
⇒ branch core: **140/140** (132 inherited + 8 new). No new failure; no inherited failure.

Flexible suites after the last commit (`62df7435`):
```
test_flexible_data: 118 checks, 0 failures
test_flexible_squish: 9676 checks, 0 failures
test_flexible_curve: 61 checks, 0 failures
test_flexible_faces: 46 checks, 0 failures
test_flexible_field: 62 checks, 0 failures
test_flexible_recommend: 19 checks, 0 failures
test_flexible_job: 36 checks, 0 failures
test_flexible_run: 40 checks, 0 failures
```
Positive controls (each test went red with its code deliberately broken, then restored):
the lookup (55 red), the pen-curve tangents (5), the load direction, σ and the handover
rule (3), the blend width, rigid covered area, smoothing-past-data in Auto, the feel
preference (5), the runner guard in `analyze_job`.

**App:** the build fails on an INHERITED error (bridge.cpp:2708 vs #358's `5846c476`; see
Blocked). The FULL CHECK (app suite) waits for #354's fix and the next "sync".
PR (draft): https://github.com/Anarkissed/TopOpt/pull/361 — CI: see the PR's checks. Expect
app-macos to fail on the inherited error until #354's fix is synced in.

Portability check (`std::` exception types without `<stdexcept>`) over every file I created
or changed: prints nothing. Every `std::` facility in the new files is included directly.

Independent review (read-only agent over the module): 9 findings; fixed #1 (Auto called a
map reachable while smoothing pushed columns past the data — scenario (b) was wrongly
"reachable"), #2 (rigid stamps: covered area; refused on solid), #3 (crossing rows now
refused), #4 (projected-centroid moments), #5 (refusal code/sentence mismatch), #6
(loader range checks), #7 (JSON nesting limit), #8 (blend width now pinned). Left: the
locale-dependence of `strtod` (a host with a comma-decimal LC_NUMERIC would misparse; the
app does not set one), the concave-corner EDT approximation (≤ 0.2 cell), and
`FlexibleError` from design/field functions escaping `run_flexible_job` unconverted (no
reachable path after validation; both derive from `std::exception`).

## BRIDGE CONTRACT (for A1 — cite verbatim)

All functions are in namespace `topopt::flexible` unless marked `topopt::`. Pure and
deterministic: no global mutable state, no I/O except the two loaders and
`run_flexible_job`. Units everywhere: **mm, N, MPa (= N/mm²)**, strain dimensionless,
density = printed-core relative density (0..1), angles in degrees.
**Two failure channels:** malformed input THROWS `FlexibleError` (a sentence naming the
key/field); input the data does not cover RETURNS a `Refusal {code, reason}` or a status
string — never an exception, never a guessed number.

**Data (load once, keep):**
- `FlexibleData load_flexible_data(const std::string& flexible_materials_json_path)` —
  reads the catalogue and every table it names from `flexible_curves/` beside it.
  Throws on any schema violation.
- `std::vector<double> tested_temperatures(const FlexibleData&, const std::string& material_id)`
  — the only temperatures to offer (R10). Empty ⇒ the filament predicts nothing.
- `data.catalogue.materials` (display name, tier, offered temps, nulls as `known=false`),
  `data.catalogue.error_bands`.

**Curves on screen (F4):**
- `std::string pen_curve_error(x, y)` — "" or the sentence to show. Rules: ≥ 2 points,
  x[0] = 0, x[n−1] = 1, x strictly increasing, y ∈ [0, 1], finite.
- `std::vector<double> pen_curve_values(x, y, t)` — draw the curve; throws the same
  sentence on invalid points. Output ∈ [0, 1], never overshoots a point.

**The squish table (F3, F10):**
- `CurveSetResult curve_set(data, material_id, nozzle_temp_c, topology)` → `{set, refusal}`.
  Refusal codes: `unknown_material`, `calibrate_first` (also for `proxy_candidate`, Q4),
  `temperature_not_tested`, `topology_no_data`, `too_few_rows`.
  `set.density_min()/density_max()`, `set.strain_measured_max()` (0.20),
  `set.strain_limit()` (0.25), `set.density_basis`, `set.tier`.
- `StressResult stress_at(set, strain, density)` → `{ok, stress_mpa, extrapolated, refusal}`;
  codes `negative_strain`, `strain_beyond_data`, `density_below_range`, `density_above_range`.
- `InverseResult density_for(set, target_strain, pressure_mpa)` → `{ok, status,
  core_density, extrapolated, nearest_density, nearest_strain, nearest_known, refusal}`;
  status `ok | too_firm | too_soft | beyond_data | no_pressure`. Nearest achievable depth
  = `nearest_strain × height`.
- `StrainResult strain_under(set, pressure_mpa, density)` → `{ok, strain, extrapolated,
  refusal}` (soft press, per column); codes as stress_at + `beyond_data`, `negative_pressure`.
- `RigidResult rigid_press(set, area_mm2[], height_mm[], density[], force_n)` →
  `{ok, depth_mm, strain[], any_extrapolated, refusal}`; code `beyond_data`.
- `TierBand tier_band(data.catalogue.error_bands, set.tier, side_stack, beads_per_wall)` →
  `{tier: literature|calibrated|proxy|estimated, band (fraction of depth), why}`.
  Show depth × (1 ± band).
- `double cell_size_mm(topology, density, beads_per_wall, bead_width_mm)` — gyroid
  3.0915·t/ρ, honeycomb 2·t/ρ.
- `MaybeNumber specimen_density_g_cm3(set, density)` — measured specimen mass density,
  linear in ρ (the mass tiebreak).
- `std::string temperature_note(data, material_id, temp_c)` — "" or e.g. "below the
  manufacturer's range 195-260 °C; tested by iacob2024" (show it; never hide the temp).
- Strain everywhere is CORE strain (`set.strain_convention`); `entry.loading` is the
  file as written, `entry.core_loading` what the lookup uses.

**Faces and stacks (F5):**
- `topopt::resolve_face_regions(model, job.loads.face_regions)` (existing) → regions.
- `std::vector<char> topopt::flexible_region_mask(job, model, grid)` — 1 = latticed voxel;
  `grid = topopt::voxelize(model.mesh, job.resolution)` (the run's own grid).
- `FaceFrame face_frame(mesh, triangles, rotation_deg, build_dir)` — `{valid, reason,
  load, x_axis, y_axis, rotation_deg, centroid, u_min, v_min, u_extent_mm, v_extent_mm,
  area_mm2, projected_area_mm2, normal_spread_deg, normal_spread_flag, build_angle_deg,
  side, principal_axis_tied}`; `to_uv(p,u,v)`, `from_uv(u,v)`. Throws for a rotation not a
  multiple of 90.
- `FaceFrame face_frame_cut(mesh, triangles, region.cuts, rotation_deg, build_dir)` — the
  frame of a sector (triangles clipped to the cuts); `bool passes_cuts(cuts, p)`.
- `Stack build_stack(model, region, all_regions, grid, lattice_mask, rotation_deg,
  build_dir, pitch_mm)` — columns on a `pitch_mm` grid (the run uses `grid.spacing`):
  `{frame, pitch_mm, nu, nv, cell[], columns[] {iu, iv, u_mm, v_mm, area_mm2, entry_t,
  exit_t, lattice_mm, exit_face}, exit_faces[] {id, area_fraction}, exit_regions[],
  footprint_area_mm2, lattice_mm_min/mean/max, stack_mm_max}`; `column_at(iu, iv)`.
  The linked other end = `exit_regions` (M13). Throws for an invalid frame / no column.

**Maps, design, stamps (F6–F8):**
- `SquishMap {mode: both|either|centre_edge, x_x, x_y, y_x, y_y, c_x, c_y,
  deepest_squish_mm}`; `topopt::squish_map_of(JobFlexibleFace)` builds one from a job.
- `std::vector<double> squish_fraction(stack, map)`, `edge_fraction(stack)`.
- `StampGrid {name, origin_u_mm, origin_v_mm, cell_mm, nu, nv, values_mpa[nu*nv, row-major
  in v], force_n, rigid}` — in the face frame's (u, v) mm. The APP rasterises shapes
  (M14). `stamp_grid_error(s)` ("" or why: sizes, ≥ 0, Σ value × cell² within 0.5 % of
  force_n), `stamp_force_n(s)`, `stamp_width_mm(s)`, `stamp_on_columns(s, stack)`.
- `FaceDesign design_face(set, stack, map, weight_n, design_stamp*, BuildParams{topology,
  beads_per_wall, bead_width_mm}, tier)` → per column `{s, pressure_mpa, height_mm,
  target_depth_mm, target_strain, status, target_extrapolated, target_density,
  nearest_depth_mm (NaN = unknown), nearest_known, clamped_density, clamped_depth_mm (NaN
  when the nearest is past the data), buildable_density,
  buildable_depth_mm, buildable_ok, buildable_extrapolated, cell_mm, sigma_mm}` plus
  counts (`ok, too_firm, too_soft, beyond_data, no_lattice, target_extrapolated,
  buildable_extrapolated, buildable_beyond_data, near_edge`), ranges and `tier`.
  "What you drew" = `target_depth_mm`; "what can be built" = `buildable_depth_mm`.
- `StampCheck check_stamp(set, stack, column_density[], stamp, build, tier)` →
  `{ok, refusal, depth_mm[] (<0 = not pressed), status[] ("" | ok | extrapolated |
  beyond_data), counts, max_depth_mm, rigid_depth_mm, stamp_width_mm, local_cell_mm,
  narrow, force_off_face_n, off_face, tier}`. A rigid stamp carries its STATED force on the
  area that lands. Refusal codes `beyond_data` (rigid), `rigid_over_solid`,
  `no_lattice_under_stamp`.
- `std::vector<StackConflict> find_stack_conflicts(grid, mask, stacks*)` — non-empty ⇒
  refuse and name `face_a`, `face_b` (M13).
- `DensityField assemble_density_field(grid, mask, {stack*, design*}[], build)` —
  per voxel density (−1 not lattice, 0 lattice under no loaded stack, else ρ), owner
  face, `handovers[] {face_a, face_b, overlap_mm3, blended_mm3}`.

**Auto (F9):**
- `Recommendation recommend(data, material_id, temps[], topologies[], feel, beads,
  bead_width_mm, FaceRequest[] {stack*, map, weight_n, design_stamp*})` →
  `{chosen, reachable, topology, temp_c, feel, reasons[] {code, text, face_region_id},
  candidates[] {…, mass_known, mass_g}, failures[] {…, buildable_beyond_data,
  solid_under_map}, sentence}`. `pick_by_tiebreaks(pool, code)` is the rule-4 step alone. Reason codes: `feel_springy_prefers_gyroid`,
  `feel_damped_prefers_honeycomb`, `other_family_unreachable`, `only_family_reachable`,
  `preferred_family_ineligible`, `honeycomb_side_stack`, `tiebreak_near_edge`,
  `tiebreak_mass`, `tiebreak_inside_data`, `solid_under_map`, `nothing_reachable`, `face_unreachable`,
  `only_candidate`, and any `curve_set` refusal code. Throws on a bad feel/topology name.

**Jobs and the CLI (F11, F12):**
- `topopt::parse_job(text)` fills `job.flexible` (null when absent). The existing schema
  still requires `model`, `material` (= `flexible.material_id`), `mode` (any of the four;
  unused by the Flexible runner), `resolution`, `output` (unused).
- `topopt::run_flexible_job(job, job_dir, out_dir, flexible_materials_path, provenance)`
  → `{refused, refusal_code, refusal_reason, receipt_json, files}` — the CLI path; A1
  should call the pieces above instead (no files until export, M9).

## Problems C2 and A1 must know about

1. **Unassigned lattice (C2).** A latticed voxel under no loaded stack gets density 0 in
   the field ("no density chosen") and is counted in the receipt (`unassigned_voxels`).
   C2 must decide what those are (e.g. a resting-only region). Core does not invent one.
2. **The buildable heuristic overshoots at a pressure step (C2, A1).** Scenario (b):
   around the thumb's edge buildable depth exceeds the target by up to 2.4 mm and 168
   columns reach the extrapolated zone — one cell of smoothing cannot follow a 4×
   pressure step. The tier map shows it; C2's realised lattice replaces the heuristic.
3. **Handover can cover the whole part (A1).** On the 100 × 100 × 60 block the top and
   side stacks overlap everywhere (600,000 mm³): the split is a nearest-face partition
   of the block, blended over one cell (85,264 mm³). Draw the owner map
   (`DensityField::owner`) rather than "the corner".
4. **Honeycomb's planning cell is d = 2t/ρ (C2).** The recommender, the smoothing σ
   and the receipt use it; C2's honeycomb generator should use the same relation or
   report its measured one.
5. **Strain convention (C2).** Core strain (specimen skins removed by the loader). C2 must
   subtract the PART's skins from each column's height; until then a skinned face reads
   high by about skin / height.
6. **Stamp edges (A1).** Stamps are averaged over each column's square (force
   conserved exactly), so a column the stamp only half covers carries half the pressure:
   the heel map shows a thin ring of shallow dents at the edge. Rasterise at ≤ half the
   column pitch.
7. **Rigid design stamps (A1).** A rigid stamp used as the DESIGN load is read as its
   STATED force over the area that lands on the face (`design_stamp_rigid_averaged`,
   `design_stamp_off_face`), because its real pressure depends on the lattice being
   designed. A partly covered column adds the even-spread share of its uncovered part.
8. **Frames (A1).** A square or round face has no longest direction: X = model +X
   projected (else +Y), flagged `principal_axis_tied` (principal moments within 1e-4). A
   cut sector is framed from its own triangles clipped to its cuts. Draw frames from core,
   never re-derive. **Orientation:** Y = load × X is a view from INSIDE the part, so a top
   face's SVG is mirrored relative to looking at it from outside, and +90° turns
   clockwise as seen from outside — A1 must label or flip v.
9. **Job schema (A1).** A Flexible job still needs `mode` (any of the four; unused),
   `output` (unused) and `material` (= `flexible.material_id`); `resolution` sets the
   voxel grid AND the column pitch. `skin_on` is required per face and recorded only —
   C1 has no skin geometry.
10. **The region mask is a second statement of the lattice precedence (C2/maintainer).**
    `flexible_region_mask` re-states run_job.cpp's `lattice_role_regions_from_job` +
    `multiscale_region_mask` with the same primitives, because run_job.cpp is not in the
    OCCT-free slices. A refactor that moves those two into the base library and has both
    call one function would remove the duplicate; I did not refactor a shared file.
11. **Reachability counts the buildable map too.** A column whose target is reachable but
    whose smoothed density squishes past the data, or squish drawn over SOLID
    (`solid_under_map`), makes the candidate not reachable. Buildable columns in the
    extrapolated zone are allowed and counted (scenario b: 108).
12. **Temperature outside the maker's range (H5).** varioShore offers 190 °C (Iacob tested
    it) while `nozzle_temp_range_c` is [195, 260]. Data unchanged; `temperature_note()`
    and the receipt's `temperature_notes` flag it: "below the manufacturer's range
    195-260 °C; tested by iacob2024". A1 should show it next to the temperature.
13. **Depth ignores the handover (C2).** Each face's depth assumes one density through the
    whole column, but the handover gives part of a column to another face (in (c) the top
    column at x = 99.5 is 59.5 of its 60 mm at face 103's density). C2 must solve columns
    in series through the assembled field, d = Σ hⱼ·ε(p; ρⱼ) (02 §4's "realised field").
14. **Smoothing at face edges (C2).** The Gaussian pulls edge columns toward the interior
    (in (c) face 101's edge 9.82 → 8.30 mm, −15 %). Use local-linear or mirrored weights.
15. **Adjacent sectors on one axis (C2)** meet with a hard density step (each is designed
    alone; there is no handover between same-axis sectors).
16. **Stamp rasterisation (A1).** Partly covered columns now keep their even-spread share
    (B3), so faded image-stamp edges no longer make near-unloaded rings; still rasterise
    at ≤ half the column pitch.


## What I did NOT do

- No lattice geometry, mesh, bead paths (C2), export or coupons (C3), print settings or
  G-code — out of scope.
- No lateral load spreading (R9: coupling hook at zero) and no displacement field for
  the animation (02 §6) — the forward solves return per-column depths; the u(z) ramp is
  for C2/A1 to draw from them.
- Skins are not modelled: `skin_on` is parsed and recorded, nothing more.
- The `calibrated` / `proxy` tiers are implemented but no data carries them yet; `proxy`
  stays refused (as calibrate_first) until Q4 is ruled.
- (Corrected in review round 1: the first version compared volume and said "grams would
  be a guess" — wrong, the measured specimen masses are in the table for every row.) The
  mass tiebreak now weighs grams: specimen density interpolated in ρ per temperature ×
  column volume. Specimen density includes the specimen's skins, so it is a relative
  (between-temperature) measure, not a predicted part mass.
- No per-temperature "furthest inside the data" beyond the insideness score; no
  unloading curves are used (the tables have none).
- The app is untouched (TRACK core). A1 is not started.


## Warnings for the next run

- **Rebuilding under a running ctest voids it.** My first base run was voided exactly
  that way (`test_cli` launches `build/topopt-cli`, which I rebuilt mid-run); the base
  check was redone in a separate worktree. Run base and branch checks in different
  build trees.
- The CLI's build fingerprint is the SHA at CONFIGURE time; re-run cmake after a
  commit if the fingerprint matters.
- `topopt-cli flexible` exit codes: 0 ran, 3 the stage refused (receipt written), 1
  error, 2 usage.
- The Flexible JSON reader refuses duplicate object keys; `parse_job`'s own reader does
  not. Only jobs carrying a `flexible` block are affected.
- `flexible_materials.json` is read from `--flexible-materials` or the compiled-in
  default (the live file in `core/src/materials/`); the tables from `flexible_curves/`
  beside it.


- There is no Flexible box in docs/ROADMAP.md, so none was checked.

## Blocked — RESOLVED 2026-09-29

#354's `026904dd` retired bridge slot 47 (merged #358); synced at `2405ddec`, the app package
builds. Kept below as the record.

**The synced base's app did not build.** I stopped before pushing. Maintainer ruling,
2026-09-28: the diagnosis is right; the fix belongs on #354 (the app stops reading the
removed field; no zero stub in core), and the #354 agent is making it. Push now as a draft
for backup and review; the app-macos failure is inherited, not mine.

```
app/TopOptKit/Sources/TopOptBridge/bridge.cpp:2708:44: error: no member named
'filleted_spans' in 'topopt::OrganicGenStats'
 2708 |   out[47] = static_cast<double>(emit_stats.filleted_spans);   // the support pass's arches
```

- Cause: #358's commit `5846c476` ("Dual contouring on an octree…") removed the overhang
  fillet counters from `OrganicGenStats` (`filleted_spans`, `fillet_unresolved`,
  `fillet_max_radius_mm`). #354's `bridge.cpp` still reads `filleted_spans` (one line; the
  other two are not read). The two branches merge without a textual conflict, but
  together they do not compile. `origin/main` still has the field, so each branch builds
  on its own.
- Same failure, same single line, on the synced base (`d615a55c`, separate worktree) and
  on this branch; `build_core.sh` succeeds on both. swift build stops at the first failing
  target, so later targets were not compiled on either.
- Not mine to fix under the rules: the line is #354's app code (TRACK core; never edit
  #354/#358), and the removal is #358's core change, not one of mine.
- **Decision needed (maintainer):** either #354 drops or replaces `out[47]` in the bridge,
  or #358 keeps a `filleted_spans` field (0, since the fillet stage is gone).
  **Ruled: #354 fixes it.** When the maintainer says "sync": SYNC → SYNC CHECK → push →
  FULL CHECK (app suite).
- At push time main (`f932266f`) and #358 (`95754820`) had moved past my last sync. As
  instructed, they were NOT merged for this backup push; the next "sync" merges them.
- Everything else is ready and committed locally on `claude/flexible-squish-maths`:
  core 140/140, evidence, handoff. The known pre-existing app failures to compare against
  after unblocking (from #354's latest handoff): `AppModelTests` 3MF ×3 (no lib3mf in a
  worktree slice), `OrganicSampleCubeTests.testThickerIsLive…`,
  `OrganicVariantCacheTests.testTheKeyIgnoresThickness…`.
- Disk: the volume had 4.7 GB free near the end, mostly used by other worktrees; an app
  suite run needs about 1–2 GB.

## Review round 1 (reviewer: ACCEPT-WITH-NOTES; one fix round, tests first)

Every item got a test FIRST, and each test was run against today's code before the fix.
Stubs reproduced today's behaviour for the new APIs, so the failures were behavioural,
not compile errors. The red run: data 3, squish 369, faces 2, field 7, recommend 4
failures. After the fixes: all green.

| item | verdict | the test that proves it |
|---|---|---|
| B1 rigid stamp partly off the face (check + design) | **PASS** | `test_flexible_field`: "B1: rigid half off the face: the stated 8 N on the covered 200 mm2, flagged off-face"; "B1: rigid design stamp half off: 20 N over the 200 mm2 on the face, flagged". `StampCheck::off_face`, `FaceDesign::design_stamp_off_face`. |
| B2 map drawn over solid | **PASS** | `test_flexible_recommend` "B2: squish drawn over solid is not reachable" (reason `solid_under_map`; `FaceDesign::solid_under_map`). |
| B3 partly covered column | **PASS** | `test_flexible_field` "B3: p = stamp average + even x (1 - covered / area)". |
| B4 split exit faces | **PASS** | `test_flexible_faces` "B4: the whole bottom takes 100 %, each half 50 % (the halves sum to 1)" (exit point tested against each region's cuts). |
| B5 side-by-side sectors | **PASS** | `test_flexible_field` "B5: side-by-side sectors (cut at x = 41, resolution 73) are not a conflict" (reproduced red first); "… a sector over a loaded bottom still is". `in_stack` tests the voxel's projection against the sector's cuts; overlaps thinner than one pitch are ignored. |
| B6 sectors framed from the whole face | **PASS** | `test_flexible_faces` "B6: the flat sector gets its own load (-Z), no spread, 100 mm2" (`face_frame_cut` clips triangles, Sutherland–Hodgman); "B6: the sector's frame is its own clipped face, exactly 60 x 50, 3000 mm2". The column-based re-frame is gone. |
| H1 placeholder depth | **PASS** | `test_flexible_field` "H1: unknown nearest depth is NaN, not 0.25 x h"; `test_flexible_run` "H1: unknown values are empty CSV fields, never 'nan' or a stand-in number". |
| H2 "least material" | **PASS** | `test_flexible_recommend` "H2: 190 C is the heaviest, in grams" and "at a row: its own specimen density" (`specimen_density_g_cm3`, `Candidate::mass_g`; tiebreak code `tiebreak_mass`). Scenario (c): 220 °C 245 g, 240 °C 273 g, 190 °C 378 g. The handoff line "grams would be a guess" is corrected. |
| H3 blend width | **PASS** | `test_flexible_field` "H3: the blend is one cell wide measured across the boundary" (w = ½ + (d_B − d_A) / (L·\|l_A − l_B\|)). Scenario (c) band: 57,588 mm³ (was 85,264; the reviewer's one-cell estimate of about 60,220 used the pre-conversion densities). |
| H4 tiebreak reason | **PASS** | `test_flexible_recommend` "H4: B beats A on mass; C lost earlier, on edges" (`pick_by_tiebreaks`). |
| H5 temperature outside the maker's range | **PASS** | `test_flexible_data` "190 C: below the manufacturer's 195-260 C range, tested by iacob2024"; `test_flexible_run` "H5: 190 C flagged … in the receipt". No data value changed. |
| Strain convention (02 §2) | **PASS** | `test_flexible_data` "file values kept as written; core curve = nominal strain x 12.5 / 10.9, stress unchanged"; `test_flexible_squish`: all 72 Table 2 values at the core strains 0.1147 / 0.2294 (`iacob_spot_checks.md`: 2.0e-16), zones 0.2294 / 0.2867, round trip ≤ 5e-15; the three scenarios re-run. |
| Minor: tie tolerance 1e-4 | **PASS** | the square-face tie test still passes at the new tolerance (`faces.cpp` principal_2d). |
| Minor: curve dead code | **PASS** | removed (a, b ≥ 0 always); `test_flexible_curve` 61/61, including the control that goes red with naive tangents. |
| Minor: row-crossing at the rows' own points | **PASS** | `test_flexible_data` "a crossing at a row's own point (between samples) is refused" (red before). |
| Minor: problem #11 stale | **PASS** | rewritten (reachability counts smoothing-past-data and solid-under-map). |
| Rulings recorded | — | the width key `flexible.min_extrudable_width_mm` accepted; Q4 open, proxy_candidate stays refused. |
| For C2 / A1 | recorded | Problems 13–16 and 8 (frame orientation): depth ignores the handover (solve in series), edge smoothing bias, hard steps between same-axis sectors, the frame seen from inside. |

What the re-run changed in the evidence (honest, not tuned):
- (a) The 12 corner columns are now "too soft": drawn at 0.377 mm, while the firmest
  gyroid squishes 0.402 mm under 30 kg. So Auto says nothing fits every face; the
  closest is gyroid at 220 °C. I kept the scenario's inputs as specified; the harness
  asserts the new outcome.
- (b) 128 columns go past the data once smoothed (was 180); heel 3,080 beyond the data.
- (c) Still gyroid at 220 °C, by the near-edge tiebreak (3,008 vs 3,648); it is also the
  lightest in grams.

### FULL CHECK (2026-09-29, on the pushed head `2405ddec`: sync + review round 1)

**Core, full suite, cli_demo included** (140 registered, macOS arm64 Release, OCCT +
Eigen + lib3mf, the same dependencies as CI):
```
140/140 Test #116: cli_demo .........................   Passed  4124.96 sec

100% tests passed out of 140

Total Test time (real) = 4124.98 sec
CTEST_EXIT=0
```
```
 81/140 Test #137: flexible_field ...................   Passed    0.92 sec
 84/140 Test #140: flexible_run .....................   Passed    0.35 sec
118/140 Test #138: flexible_recommend ...............   Passed    0.42 sec
120/140 Test #139: flexible_job .....................   Passed    0.16 sec
122/140 Test #133: flexible_data ....................   Passed    0.10 sec
129/140 Test #134: flexible_squish ..................   Passed    0.20 sec
138/140 Test #136: flexible_faces ...................   Passed    0.09 sec
139/140 Test #135: flexible_curve ...................   Passed    0.07 sec
140/140 Test #116: cli_demo .........................   Passed  4124.96 sec
```

**App, full package suite** (`swift test --package-path app/TopOptKit`, Debug, macOS,
lib3mf-free worktree slice, 3 h 38 min):
```
Executed 2551 tests, with 34 tests skipped and 14 failures (0 unexpected) in 13079.964 (13080.282) seconds
```
The 14 failure assertions fall in 9 test cases. **All 9 are INHERITED; none come from
this branch:**

| test case | assertions | verdict |
|---|---|---|
| `AppModelTests.testReopenedThreeMFProjectReimportsTheStlWorkingCopy` | 3 | inherited: known pre-existing (no lib3mf in a worktree slice) |
| `AppModelTests.testThreeMFImportNormalisesToStlWorkingCopyAndKeepsProvenance` | 5 | inherited: known pre-existing (no lib3mf) |
| `AppModelTests.testThreeMFImportOptimisesOnDeviceEndToEnd` | 3 | inherited: known pre-existing (no lib3mf) |
| `OrganicSampleCubeTests.testThickerIsLiveAndNeverRetraces` | 2 | inherited: known pre-existing (#354's handoff) |
| `OrganicVariantCacheTests.testTheKeyIgnoresThicknessAndFollowsCoreAndTopology` | 2 | inherited: known pre-existing (#354's handoff) |
| `LatticeCellGradingTests.testGradingChangesTheRenderedLattice` ("298 is not greater than 500") | 2 | **inherited, NEW with this sync**: identical failure on the synced base without my commits |
| `LatticePageRound2Tests.testIncludeAndExcludeRegionsReachTheEmittedJobJSON` (region geometry keys now carry `frame_u`, `frame_w`) | 2 | **inherited, NEW with this sync**: identical on the base |
| `LatticeSimSolveTriggerTests.testTheTriggerRefusesOnAllThreeGrounds` ("…and otherwise it actually runs") | 2 | **inherited, NEW with this sync**: identical on the base |
| `OrganicPreviewParameterParityTests.testThePreviewCarriesEveryOrganicParameterTheRunSets` (`bead_is_stated`, `defer_bead_calibration`) | 2 | **inherited, NEW with this sync**: identical on the base |

**How the four new ones were decided:** a scratch worktree at main `f932266f` + #358
`8414af47` + #354 `026904dd`, merged in my sync order. It differs from `2405ddec` only by
this branch's own files (nothing under `app/`). There, `build_core.sh` and then
`swift test --filter` on the four tests gave:
```
	 Executed 4 tests, with 4 failures (0 unexpected) in 39.508 (39.512) seconds
```
Same four messages as on my branch. They come in with #354/#358/main at this sync, not
from Flexible; they belong to #354's/#358's owners.

**Side effect, handled:** the app suite rewrites other tasks' evidence files
(`docs/handoffs/assets/*.png`, `evidence/**`). They were restored to their committed
contents; four that a docs commit had swept in (`91e1f0d1`) were restored in `592d9155`.

## C1 addendum: angled presses (maintainer ruling 2026-10-07, via the reviewer)

**What:** a press may state a direction, and may span 2+ ADJACENT face regions (an edge
or a corner) as ONE footprint: one frame, one stack, one squish map, one stamp grid.
#362's 3D squish and overlays read this stack; the app never recomputes the direction.

**Wire form** (`flexible.faces[]`, loaded entries only):
- `"press_direction": [x, y, z]`: optional, model frame, normalised by core. When absent,
  the load is today's area-weighted inward normal, byte-identical.
- `"face_region_ids": [a, b, …]`: 2 or more adjacent regions, used INSTEAD of
  `"face_region_id"` (both together are refused). The press is named by its first id;
  check_stamps and the file names use that id. A region may be in only one press.
- `job_schema` accepts both keys only in the flexible block; a lattice region carrying
  `press_direction` is refused as an unknown key (tested).

**Core:**
- `face_frame(…, const Vec3* press_direction)` and `face_frame_cut(…, press_direction)`:
  with a direction, load = that direction; X/Y follow the principal-axis rule on the
  footprint projected perpendicular to it; `build_angle` / `side` come from it, so more
  than 15° off Z is a side press under the unchanged R6 and tier rules (gyroid only,
  'estimated').
- `build_press_stack(model, footprint[], regions, grid, mask, rotation, build_dir, pitch,
  press_direction*)`: one stack over the union, with rays along the direction through the
  projected footprint. It refuses, with FlexibleError naming the region(s):
  - a direction that does not point INTO the part over every footprint triangle
    (outward or edge-on);
  - a non-adjacent set (connectivity through shared mesh edges, `face_adjacency`);
  - a multi-region footprint containing a cut sector (not yet; a sector pressed alone,
    angled or not, works);
  - a region listed twice.
- `build_stack(face, …)` is unchanged; its new `footprint_region_ids = {face.id}`.
  `Stack` gains `footprint_region_ids`, `press_direction_given`, `press_direction`.
- Conflicts and handover need no new code: `find_stack_conflicts` tests the 15° same-axis
  rule against the press's direction; a voxel's depth is measured from the footprint
  surface along that ray (its nearest footprint face); the blend is one cell across the
  boundary, as before.
- **Receipt:** a `"press"` block per face, written ONLY when a new key is present:
  `{"footprint_face_region_ids": […], "direction": [x, y, z] | "inward normal",
  "build_angle_deg", "side"}`. The frame block (direction, build angle, side) and the
  conflicts / handover blocks were already there.

**Tests, red first** (stubs reproduced today's behaviour: direction ignored, footprint
= first region):
- `test_flexible_press` (new): 19 of 25 checks red before the fix, 25/25 after:
  - cube edge at 45° (load, side, 5,091 ± 2 % columns, exits half bottom / half left,
    X across the edge 84.85 mm, Y along it 60 mm);
  - cube corner at 54.74° (hexagon ± 2 %, exits a third each to bottom / left / front,
    the tie rule);
  - edge without a direction (the union's inward normal);
  - tilted top face 20° (tan 20° of the columns leave through the side); no direction =
    build_stack exactly;
  - refusals: outward, edge-on, an edge press along the top face, non-adjacent
    top + bottom (names both), multi-region with a sector;
  - a single angled sector works;
  - a vertical edge press crossing a top press (one handover pair, blended);
  - an angled press within 15° of a loaded bottom (conflict).
- `test_flexible_job` +12 checks: the keys, every refusal, and the keys refused outside
  the flexible block. Before the fix the parser refused `face_region_ids` (crash).
- `test_flexible_run` +5 checks: an edge press runs end to end; the receipt's press block
  is exact; R6 makes it gyroid-only; an outward press is refused naming the region; a
  plain job's receipt has no press block. 3 red before the fix.

**Byte-identity without the new keys:** all earlier flexible suites pass unchanged, and
re-running scenarios (a)–(c) through the new binary changes ONLY the provenance lines
(`fingerprint`, `build_time`). Every SVG, CSV and receipt value is identical.

**A real bug found and fixed on the way: `principal_2d`.** When the larger principal
moment lay along the second basis axis and the off-diagonal was rounding noise (~1e-12,
not exactly 0), the eigenvector `(l1 − c, b)` was two noise terms and X pointed
anywhere. The cube edge's X came out ALONG the edge, skewed 1.7°. It now takes whichever
of `(l1 − c, b)` and `(b, l1 − a)` is larger. The edge-frame check was the red test.
Scenarios (a)–(c) are unaffected (identical output).

**Evidence (d) `d_cube_top_and_vertical_edge_press`:**
- a 60 mm cube pressed on top (10 kg) and on its vertical +X/+Y edge (15 kg, along
  (−1, −1, 0), centre → edge curve);
- 90° apart: one handover (101, 103), 34,671 mm³ blended, no conflict;
- the edge press is side (90°), 'estimated', gyroid only;
- its other end is the −Y and −X faces (0.51 / 0.49).
- **Finding for #362:** an edge press's columns run from 0.7 to 84.7 mm long (rays near
  the footprint's rim cut only a small corner). The 762 columns under 12.7 mm squish past
  the tested strain under the even pressure: dark red on the tier map. That is geometry,
  not a bug. The app should expect a "beyond the data" rim on edge and corner presses
  unless the drawn squish fades to the rim.

### Meaning changes (addendum)

| where | before | now | test |
|---|---|---|---|
| `faces.cpp` `principal_2d` | a near-diagonal moment matrix whose long axis was the 2nd basis axis gave a noise-driven X | the larger of the two eigenvector forms | `test_flexible_press` "edge: X is the long (84.9 mm) direction across the edge" |
| flexible job block | a loaded face named one region; its load was always the inward normal | optional `press_direction`; optional `face_region_ids` (2+ adjacent regions, one footprint) | `test_flexible_job` `test_press_keys`; `test_flexible_press`; `test_flexible_run` |
| flexible receipt | — | a `press` block, only when a new key is present | `test_flexible_run` (exact string; absent on a plain job) |

### BRIDGE CONTRACT additions (for #362 / A1)

- `Stack build_press_stack(model, std::vector<const ResolvedFaceRegion*> footprint,
  regions, grid, lattice_mask, rotation_deg, build_dir, pitch_mm, const Vec3*
  press_direction /* nullptr = inward normal */)`. Throws FlexibleError naming the
  region on: an outward or edge-on direction, a non-adjacent set, a multi-region press
  with a cut sector, a region listed twice.
- `FaceFrame face_frame(…, const Vec3* press_direction = nullptr)`,
  `face_frame_cut(…, press_direction)`.
- `Stack::footprint_region_ids`, `press_direction_given`, `press_direction` (unit);
  `frame.load`, `frame.build_angle_deg`, `frame.side` follow the direction.
- Everything downstream (`design_face`, `check_stamp`, `find_stack_conflicts`,
  `assemble_density_field`, `recommend`) takes the press stack unchanged.

NOT in scope (per the ruling): off-axis curve data (the tables stay build-Z; the side
rule covers angled presses until the rig measures face, edge and corner coupons); large
deformation, folds and self-contact.
