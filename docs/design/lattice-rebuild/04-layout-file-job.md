# Lattice rebuild — the lattice file job

2026-11-12, LatticeReview's helper. The contract between the app and the Mac worker for making the printable lattice file from the new layout engine.

## What it is

The app draws the lattice on the device from the layout. The file to print is made on the Mac from **the same layout with the same settings**: the worker runs

```
topopt-cli lattice-file job.json --out DIR [--threads N]
```

and two files appear in `DIR`: the lattice as a binary STL, and `lattice_file.json` saying what was made or, in one plain line, why nothing was.

It is a subcommand of the CLI (like `flexible` and `lattice-sample`), not a new mode of `run`: the existing job reader is strict about its own keys and holds loads, materials and a ladder, none of which this job has. The worker picks the subcommand from the job's `"mode"`, as it already does for `analyze` and `lattice_variant`; one route was added there. `--materials` and `--rules` are accepted and not read, because the worker passes them to every job.

Code: `core/include/topopt/lattice_layout_file.hpp`, `core/src/lattice_layout/file_job.cpp`. Tests: `lattice_layout_file`, `cli_lattice_file`, `cli_lattice_file_refused`.

## What the app sends

The same upload as any job: the model as `step`, the face sidecar as `faces` when the part has one, and the job as `job`. The worker saves the model beside `job.json` and writes its name into `"model"` itself.

```json
{
  "mode": "lattice_file",
  "model": "part.step",
  "output": "lattice.stl",
  "linear_deflection": 0,
  "threads": 0,
  "layout": { },
  "mesh": { },
  "demand": "stress.bin"
}
```

| Key | Meaning | When left out |
|---|---|---|
| `mode` | must be `"lattice_file"` | refused |
| `model` | the part's file: STEP, STL or 3MF. Relative to the job file's folder | refused |
| `output` | the STL's name. A file name only, no folder: it always lands in `--out` | `lattice.stl` |
| `linear_deflection` | how finely a STEP's curves are turned into triangles; send what the app opened the part with | core's own (0.1) |
| `threads` | 0 = every core | 0 |
| `layout` | the lattice settings, below | every default |
| `mesh` | how the mesh is made, below | every default |
| `demand` | the stress result for By stress: the name of a file beside the job (a file name only, no folder), in the demand file format below | none: By stress is then refused |

A key the job does not know is refused, so a misspelt setting is never quietly dropped. A key that starts with `_` is a comment and is skipped.

### `layout`

Exactly the fields of the bridge's `LatticeLayoutSettings`, under the same names, with the same meaning and the same defaults, and one more. Lists of lists are flattened the same way as in the bridge: a count per item, then all the items' faces in order.

| Key | Default | |
|---|---|---|
| `all_lattice` | false | false: lattice only where a Lattice region asks |
| `bead_mm` | 0.45 | line width |
| `min_strut_lines` | 1 | the thinnest strut, in line widths; 2 for a test piece that is all smallest lattice |
| `min_wall_mm` | 0 | |
| `rim_mm` | 0 | 0 none, below 0 two line widths |
| `cover_mm` | 0 | 0 none, below 0 two line widths |
| `region_ids` | [] | one number above 0 per region |
| `region_no_lattice` | [] | per region: true or 1 = No lattice |
| `region_depth_mm` | [] | per region |
| `region_expand_mm` | [] | per region |
| `region_face_counts` | [] | per region: how many of `region_faces` are its |
| `region_faces` | [] | the model's own face numbers, region after region |
| `protect_ids`, `protect_depth_mm`, `protect_face_counts`, `protect_faces` | [] | Protect skins, the same way; depth 0 = two line widths |
| `topology` | "octet" | core's type names |
| `algorithm` | "default_grade" | `uniform`, `default_grade` or `stepped` |
| `cell_mm` | 0 | 0 = Auto |
| `cell_max_mm` | 8 | |
| `cell_min_mm` | 0 | |
| `min_cells_across` | 1 | |
| `grade_to_shape` | false | |
| `band_mm` | 0 | |
| `band_cell_mm` | 0 | |
| `per_region` | false | |
| `dial` | 0.45 | |
| `dial_region`, `dial_value` | [] | per-region dials |
| `strut_width_mm` | 0 | above 0: this width everywhere |
| `allow_quilt` | false | |
| `strength` | 0 | |
| `small_cells_in_thin_walls` | false | **not in the bridge's struct yet**: core's per-part choice of 2026-11-12 (thin walls get small cells with the thinnest strut) |
| `one_grid` | false | **not in the bridge's struct yet**: "Let walls cut cells", core's per-part choice of 2026-11-14 (walls, pockets and skins may cut the cells, and nothing else changes; offered in Aesthetic only) |
| `cells_by_stress` | false | **not in the bridge's struct yet**: cell size by stress (C22). It needs the stress result (the top-level `demand` file): without one the job is refused (`no_stress_result`). The reference and response are those of the stress keys |
| `bars` | true | a file needs its struts: false is refused (`no_struts`) |
| `join_loose` | true | |
| `skin` | false | |
| `skin_width_mm` | 0 | |
| `skin_reach_cells` | 1.2 | |
| `drop_loose` | true | |
| `by_stress` | false | **not in the bridge's struct yet**: By stress (R7, R8, R12, R16 to R18): the stress decides every strut. With `per_region` also true the job is refused (`job_unreadable`). Without `demand` the job is refused (`no_stress_result`) |
| `dial_light` | 0.01 | By stress, "Grade to": the dial where the stress is nothing |
| `dial_heavy` | 1.0 | By stress, "Grade from": the dial at or over the reference |
| `width_light_mm`, `width_heavy_mm` | 0, 0 | By stress, Manual: when BOTH are above 0, the two ends are these strut widths in mm (the same in every cell size) and the dials are not read |
| `reference_mpa` | 0 | By stress: the stress at which the lattice is at its heavy end. 0 = the part's own: the `percentile` of the stress in the part's lattice space (R17) |
| `percentile` | 0.95 | read when `reference_mpa` is 0 |
| `response` | 1 | By stress: the exponent on stress / reference, held to 0.25 .. 4 |

The file matches the preview only if these are the values the preview was laid with.

### `mesh` (all optional; leave it out unless there is a reason)

`pitch_mm` (0.25: how finely each cell's shape is read), `bar_sides` (12), `block_mm` (12), `grow_mm` (0.02), `clean_mm` (0.004), `part_mm` (0.006), `fill_under_mm3` (-1: a closed space inside the material smaller than one smallest cell is filled; lattice sealed in behind skins is larger and stays), `bridge_rise` (0.5: a strut flatter than 30 degrees is printed as a bridge; 0 = every strut round), `post_mm` (0.9). They are core's `MeshSpec`. For the print check: `layer_mm` (0.2), `pixel_mm` (0.05), `most_passes` (10), `leave_out` (true: a strut that would start in mid-air is left out first, posts come second; false: posts only), `keep_if_not_clean` (false).

## What comes back

Exit code: **0** the file was made; **3** refused (the part or the settings cannot give a file: the maker can change something); **1** anything else; **2** the command line was wrong.

On the worker, exit 0 ends the job with a `done` event listing `lattice.stl` and `lattice_file.json`; anything else ends it with an `error` event whose message is the CLI's stderr, and **the last line of that message is the plain line**. `lattice_file.json` is written in every case (when `--out` can be written) and can be fetched like any other file of the job, so the app can read `code` and `why` from it instead.

While it works the CLI prints one line per step (`lattice-file: opening the part`, `measuring the part`, `laying the lattice`, `making the file`, `saving the file`); the worker passes them on as log lines. There is no percentage.

```json
{
  "ok": true,
  "code": "ok",
  "why": "",
  "detail": "",
  "file": "lattice.stl",
  "file_bytes": 82084,
  "part": {"faces": 6, "triangles": 12, "open_edges": 0},
  "layout": {"cells": 4, "solid_pieces": 0, "bars": 36, "at_one_line": 0, "at_widest": 0,
             "stubs": 0, "joined": 0, "dropped": 60, "pieces": 1, "adrift": 0, "stepped_edges": 1, "thin_solid": 0, "cells_by_stress": false,
             "floor_cell_mm": 2.37, "min_strut_mm": 0.45, "open_look": 0.19, "touch": 0.354,
             "empty_regions": [],
             "by_stress": false, "reference_mpa": 0, "highest_mpa": 0, "at_light": 0, "at_heavy": 0},
  "mesh": {"triangles": 1640, "mm3": 452.9, "part_mm3": 1000, "struts_mm3": 59.5, "solid_mm3": 398,
           "bars": 36, "bridges": 12, "balls": 14, "bars_left_out": 0, "bars_left_out_mm": 0,
           "drop_unanswered": 0, "posts": 0, "posts_mm": 0, "solid_pieces": 1, "slivers_left_out": 0,
           "slivers_mm3": 0, "touching_places": 0, "air_pockets": 0, "air_pockets_mm3": 0,
           "sealed_spaces": 0, "loose_bits": 0, "loose_mm3": 0, "flat_triangles": 0,
           "open_boxes": 8, "builds": 1},
  "print_check": {"bed_contact_mm2": 100, "midair_starts": 0, "clean": true, "passes": 1,
    "one_ended": 0, "longest_bridge_reach_mm": 1.2, "bed_flat": true, "first_layer_mm2": 100,
    "sloped_underside_mm2": 0, "layers": 50, "thin_islands": 0, "thin_layers": 0,
    "found_per_pass": [0], "left_out_at": [], "posts": []},
  "ms": {"import": 27, "measure": 0, "read": 9, "cells": 0, "bars": 1, "open_space": 6,
         "carve": 5, "struts": 47, "solid": 1, "finish": 2, "write": 1, "total": 94}
}
```

- `layout` holds the counts the bridge's `LatticeLayoutResult` holds, under the same names (`bars` here is how many).
  `thin_solid`: cut cells print rule P8 (f) made solid (a cut piece thinner than its own strut, lying against solid); they are counted in `solid_pieces` too.
  `cells_by_stress`: cell size by stress (C22) was applied to the layout (false when it was not asked for, or one of its OFF cases holds).
  `by_stress`: the struts were graded by stress; then `reference_mpa` is the reference used (the stated one or the part's own), `highest_mpa` the highest stress any cell read in its own cube, `at_light` and `at_heavy` the cells at the light end (no stress) and at the heavy end (at or over the reference). All 0 otherwise.
- `mesh` is core's `MeshReport`. `mm3` is the plastic in the file; `part_mm3` the solid part's.
- `print_check` is his print rules measured on the mesh the file holds, layer by layer (0.2 mm layers), the part standing on its lowest face:
  - `bed_contact_mm2` (the bridge's name): the area lying flat on the bed; `bed_flat` says it is the whole first layer with no sloped underside.
  - `midair_starts` (the bridge's name) and `one_ended`: both 0 in any file that is written; `clean` says so.
  - `passes` and `found_per_pass`: the mesh is made, checked and made again; each number is how many mid-air starts and one-ended overhangs that pass still had.
  - `left_out_at` ([x, y, z] each): the PLACES the make-check-make loop left struts out at, as it ended (core's `PrintableReport::drop_at`), gathered over all its passes: each mid-air start or one-ended overhang the layer check found, half a layer below it. Every strut whose lowest point is at one of these places is left out, and so is a small separate piece of the solid body that starts there. It is a list of places, not a count and not a list of struts: one place may leave out several struts, or none (`mesh.drop_unanswered` counts those). `posts` ([x, y, z_bottom, z_top] each): short posts added to hold up what leaving out could not fix. The preview can show both after a run.
  - `longest_bridge_reach_mm`: the farthest any bridge reaches past its supports (half its span).
  - `thin_islands`: a count only. Slices of the file about one line thick (a strut lying in an open face, cut in half by it).
- `ms`: `carve` is the part with the open cells taken out, done once; `struts`, `solid` and `finish` are the LAST pass's (each pass repeats them; `total` is everything).
- `detail` is the technical message behind a failure, for a log. It is not for the maker.
- The STL is written beside its target and moved in only when whole. A job that fails leaves no STL, and never replaces an earlier good one with half a file.

## Every refusal

`why` is exactly the line below (numbers filled in).

| `code` | Exit | The line |
|---|---|---|
| `model_unreadable` | 3 | The part's file could not be opened on the Mac, so no lattice file was made. |
| `model_empty` | 3 | The part's file has no surface in it, so there is nothing to put lattice in. |
| `part_not_closed` | 3 | The part's surface has gaps in it (3 open edges), so its inside cannot be told from its outside. Repair the model and send it again. |
| `region_faces_missing` | 3 | Region 2 points at faces this part does not have. Pick its faces again. (Several: "Regions 2 and 5 point at faces this part does not have. Pick their faces again.") |
| `protect_faces_missing` | 3 | Protect skin 3 points at faces this part does not have. Pick its faces again. |
| `type_not_supported` | 3 | This lattice type is made of sheets, and a lattice file can only be made from the types made of struts so far. Pick a strut type. |
| `no_cells` | 3 | No lattice cell fits anywhere in this part with these settings, so there is no lattice to make. Try a smaller cell, a deeper region, or more of the part. |
| `no_struts` | 3 | The lattice here has no struts left to print, so no file was made. Try a smaller cell or a deeper region. |
| `would_not_print` | 3 | After 10 tries the lattice still has 2 places that would start printing in mid-air and 1 overhang held at one end only. No file was made. A larger cell or a Protect skin near those places usually fixes it. |
| `mesh_unavailable` | 3 | The worker on the Mac was built without the part that makes lattice files, so it cannot make one. Update the worker. |
| `no_stress_result` | 3 | By stress needs a stress result, and none came with this job, so no file was made. Run the stress check first, or pick another density. (Also when the stress result has no stress anywhere in the lattice's space and no reference was stated: R18, never a file at the light end by default.) The same word for cell size by stress (`cells_by_stress`) with no stress result: Cell size by stress needs a stress result, and this job has none, so nothing was made. Send the part's stress result with it, or turn Cell size by stress off. |
| `demand_unreadable` | 1 | The stress result sent with the lattice job could not be read, so nothing was made. (`detail` says what is wrong with it: not a demand file, the version, the size, a number that is not finite.) |
| `job_unreadable` | 1 | The lattice job sent to the Mac could not be read, so nothing was made. (`detail` names the key.) |
| `mesh_failed` | 1 | the mesh maker's own plain line, or: The lattice file could not be put together. Nothing was made. |
| `cannot_write` | 1 | The lattice file could not be saved on the Mac (the folder is missing or the disk is full). |
| `cancelled` | 1 | Stopped before the lattice file was finished. Nothing was made. (Only from code that passes a stop flag. On the worker a cancel stops the whole process and the worker reports it itself.) |
| `error` | 1 | Something went wrong while making the lattice file, and nothing was made. |

The checks run in this order: the stress result (when the job names one) reads; the model opens; it has a surface; every region and Protect skin has at least one face that is the part's; By stress has a stress result; the type is a strut type; cell size by stress has a stress result; the worker can make meshes; the part is closed; the layout has cells; By stress has a reference; the layout has struts.

## The demand file (a stress result, for By stress)

Little-endian, no padding:

| Bytes | What |
|---|---|
| 8 | `TODEMAND` |
| 4 | int32 version: 1 |
| 4 x 3 | int32 nx, ny, nz: voxels along x, y, z |
| 8 x 3 | float64 the grid's low corner x, y, z, mm, in the part's own coordinates |
| 8 | float64 the voxel edge, mm |
| 4 x nx ny nz | float32 von Mises stress, MPa, one per voxel, in core's VoxelGrid order: index (k ny + j) nx + i; 0 where the solve had no material |

Voxel (i, j, k) is the cube from corner + edge x (i, j, k) to corner + edge x (i+1, j+1, k+1). The file is exactly 56 + 4 nx ny nz bytes. It is refused (`demand_unreadable`) when it does not start with `TODEMAND`, its version is not 1, its grid has no voxels, it is not exactly that size, or any number in it is not finite (or the edge is not above 0). Code: `read_demand_file`, `write_demand_file` in `lattice_layout_file.hpp`.

A cell's stress is the highest value among the voxels its cube shares volume with (R16); a turned cell's cube is read as the axis-aligned box round its eight corners. Cell size by stress (`cells_by_stress`, C22) reads the same file.

## A worked example

A bracket whose top is face 12 and whose two bolt pads are faces 30 and 31 (made-up numbers). The maker wants lattice 6 mm deep under the top, pulled in 1 mm from its edge, no lattice under the pads, a 1 mm solid skin on the front face 4, a rim, and 0.4 mm lines.

```json
{
  "mode": "lattice_file",
  "model": "bracket.step",
  "output": "bracket_lattice.stl",
  "layout": {
    "all_lattice": false,
    "bead_mm": 0.4,
    "rim_mm": -1,
    "region_ids": [1, 2],
    "region_no_lattice": [0, 1],
    "region_depth_mm": [6, 6],
    "region_expand_mm": [-1, 0],
    "region_face_counts": [1, 2],
    "region_faces": [12, 30, 31],
    "protect_ids": [1],
    "protect_depth_mm": [1],
    "protect_face_counts": [1],
    "protect_faces": [4],
    "algorithm": "default_grade",
    "cell_max_mm": 8,
    "dial": 0.45
  }
}
```

On the Mac by hand:

```
topopt-cli lattice-file /path/to/job/job.json --out /path/to/job/out
```

It prints the steps, then `lattice-file: made /path/to/job/out/bracket_lattice.stl (… cells, … struts, … triangles, … s)`, and exits 0. Had face 12 not been one of the part's, it would print `lattice-file: REFUSED (region_faces_missing): Region 1 points at faces this part does not have. Pick its faces again.`, write the same line into `lattice_file.json`, write no STL, and exit 3.

A runnable job on the repo's own 10 mm cube is in `core/tests/fixtures/lattice_file/job.json`.

## Where the mesh is made

One function, `make_file_mesh(session, outcome, options, report)`: it reads the open space of the layout's cells once, then makes the mesh, checks every layer and makes it again until nothing starts in mid-air (`build_printable_mesh`, at most `mesh.most_passes` times). It fills `report.bed_contact_mm2`, `report.midair_starts`, `report.builds` and the rest of `print_check`. A mesh that is still not clean is not written, unless the job says `"keep_if_not_clean": true` (for looking at it, never for printing).
