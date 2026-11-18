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
  "demand": "stress.bin",
  "tensor": "stress.tensor"
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
| `tensor` | **not sent by the app yet**: the stress result for Organic (Traced), the full stress tensor so the trace has directions: the name of a file beside the job (a file name only, no folder), in the tensor file format below | none: a weave region is then refused (`no_stress_result`, OR14) |

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
| `region_zones` | none | **not in the bridge's struct yet**: rule D21, a zone in place of a region's faces. When given, one entry per region: `null` for a region of faces, or its zone, `{"kind": "box", "centre": [x,y,z], "axes": [[..],[..],[..]], "half_mm": [a,b,c]}` or `{"kind": "cylinder", "centre": [x,y,z], "axis": [x,y,z], "radius_mm": r, "half_length_mm": h}`, in the part's own coordinates, mm. A zone's region has a face count of 0; its `region_depth_mm` is not read (the depth is the zone's own: 2 × the third half size, or 2 × the half length); `region_no_lattice` and `region_expand_mm` are read as for faces. Refused (`job_unreadable`, `detail` saying why): sizes not above 0, axes not unit (a box's: not at right angles) to 1e-6, a kind other than box or cylinder, a key the zone does not know, faces and a zone on one region, a list not one per region |
| `region_finish` | none | per region: `null` (the part's Finish) or the region's own (S13), an object with any of `rim_mm`, `cover_mm` (0 none for this region, below 0 two line widths), `skin` (true / false), `skin_width_mm` (0 = as wide as the thinner strut), `skin_reach_cells`. What a region leaves out is the part's. An unknown key, or a list not as long as `region_ids`, refuses the job. **Not in the bridge's struct yet** |
| `region_pieces` | none | **not in the bridge's struct yet**: rule D22, a region given as pieces of faces (the app's Edit faces). When given, one entry per region: `null` (its faces, or its zone), or its pieces, `[{"faces": [..], "cuts": [{"point": [x,y,z], "normal": [x,y,z], "strict": false}]}, ..]`, in the part's own coordinates, mm; a cut keeps a point p when (p − point) · normal ≥ 0, or > 0 when `strict` (core's `FaceRegionSpec` cut; `strict` may be left out, false). With pieces the region's `region_faces` are not read (the parent faces may be sent as well). Refused (`job_unreadable`, `detail` saying why): a normal of nothing, a point or normal not three numbers, a key a piece or cut does not know, an empty list, pieces and a zone on one region, a list not one per region. Pieces that leave no surface (no faces, faces the part does not have, cuts that keep nothing) are refused `region_faces_missing` with the region's id |
| `protect_ids`, `protect_depth_mm`, `protect_face_counts`, `protect_faces` | [] | Protect skins, the same way; depth 0 = two line widths |
| `protect_pieces` | none | **not in the bridge's struct yet**: rule D22 for Protect skins, one entry per Protect skin: `null` (its faces) or its pieces, as `region_pieces`; with pieces its `protect_faces` are not read. Refused the same way; pieces that leave no surface are refused `protect_faces_missing` |
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
| `max_step` | 0 | **not in the bridge's struct yet**: the largest size step between neighbouring cells (C24), a ratio; 0 = no limit (the layout is the one laid without it, byte for byte). Within one region's layout no cell is more than this many times the size of a cell it shares a face with; the larger cell is divided down its own ladder. On Default Grade a value under 2 is held at 2; no value is under 1. The file reports the value kept as `step_held_at` |
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
| `region_own` | absent | **not in the bridge's struct yet**: a Lattice region's own cells and struts (C23, R19). One entry per region, in the order of `region_ids` (a list of another length is refused): `null` for a region that takes the part's settings in everything, or an object holding any of `algorithm`, `cell_mm`, `cell_max_mm`, `cell_min_mm`, `min_cells_across`, `grade_to_shape`, `band_mm`, `band_cell_mm`, `cells_by_stress`, `by_stress`, `dial`, `dial_light`, `dial_heavy`, `strut_width_mm`, `width_light_mm`, `width_heavy_mm`, `strength`, `response`, `reference_mpa`, `max_step`, each read as the part's key of that name is. A key it does not hold, or one that is the part's only (the type, Allow quilt, Let walls cut cells, thin walls, the line width and lines, the percentile), refuses the job (`job_unreadable`). What an entry does not state, the region takes from the part's. A region's `by_stress` or `cells_by_stress` true with no `demand` is refused (`no_stress_result`) as the part's is |
| `region_weave` | all false | **not in the bridge's struct yet**: Organic (Traced), per region: true or 1 = the region is filled by the Traced weave (`RegionAsk::weave`), not by cells. Not as long as `region_ids`: refused (`job_unreadable`). With any true the job runs `Session::lay_organic` in place of `lay`, and needs `tensor` |
| `organic_spacing_mm` | none | Organic: one distance between neighbouring strands, mm, above 0, both ends of the range (`OrganicAsk::spacing_mm`; the tracer raises it to its print and resolution floors where they bind). It, or the range below, is needed when a region is a weave: without either the job is refused (`job_unreadable`, the key named). Given with any range key: refused |
| `organic_spacing_min_mm`, `organic_spacing_max_mm` | none | Organic, rule O12: the range, mm, given together: the spacing at the weave's busiest voxel (min, above 0) and at its quietest (max, at least min), by the old run's law (01-rules.md, O12); the percentile is the layout's `percentile`, or a stated `reference_mpa` in its place. One alone, min 0 or less, max under min: refused (`job_unreadable`) |
| `organic_spacing_exponent` | 1 | Organic, rule O12: the grading law's demand exponent (the old run's `demand_exponent`), above 0; read only with the range (alone: refused) |
| `organic_shape_fit` | true | Organic, rule O13: the shape fit (the spacing tightened toward the weave's outline and in thin members), true or false; anything else refused (`job_unreadable`) |
| `organic_width_mm` | 0 | Organic: the strut diameter, mm (`OrganicAsk::width_mm`); 0 = the thinnest strut (`bead_mm` x `min_strut_lines`). Under 0, or above 0 and under the thinnest strut: refused (`job_unreadable`) |
| ~~`organic_rim_mm`~~ | gone | WITHDRAWN 2026-11-15 with rule O15: refused as an unknown key (`job_unreadable`). It was rule O15 (`OrganicAsk::rim_mm`): the Organic rim. 0 = none; above 0 = that width, mm; below 0 = the width the app sends with "Solid rim at edges" on: max(1.535 x `bead_mm`, the tensor file's voxel). Not a number: refused (`job_unreadable`). Read only when a region is a weave |
| ~~`organic_net_skin`~~ | gone | Gone 2026-11-15: refused as an unknown key (`job_unreadable`); the switch is `skin`. It was rule O16 (`OrganicAsk::net_skin`): the net skin over each open face of a weave region; false = none. Not true or false: refused (`job_unreadable`). Read only when a region is a weave |
| `organic_mode` | `"traced"` | Organic, rule G1: `"traced"` (stage 1b's placement, `trace_strands`) or `"grown"` (the owner's Grown, written new: `grow_strands`). Anything else: refused (`job_unreadable`, the key named). Grown grows one layer per step: the layer is the `mesh` object's `layer_mm` (0.2) |
| `organic_walls_out` | false | Grown only, rule G2 (idea C): seeds on the region's walls too, growing inward (`OrganicAsk::walls_out`) |
| `organic_ties` | true | Grown only, rule G9: the transfer ties (`OrganicAsk::ties`) |
| `organic_tie_swirl` | 1 | Grown only, rule G9: the ties' swirl, 0 to 1 (`OrganicAsk::tie_swirl`); outside it: refused |

**Organic takes the regular Finish** (OR30, rule O16): a job with a weave region uses `rim_mm`, `cover_mm`, `skin` and `skin_width_mm` exactly as a cell lattice does. Rim stands only where the part's solid backs the region's outline; Covered closes every face; `skin` true lays the net skin over a weave region's open faces (its struts `skin_width_mm` wide when above 0); all off is None. There is no Organic finish key of its own.

The file matches the preview only if these are the values the preview was laid with.

### `mesh` (all optional; leave it out unless there is a reason)

`pitch_mm` (0.25: how finely each cell's shape is read), `bar_sides` (12), `block_mm` (12), `grow_mm` (0.02), `clean_mm` (0.004), `part_mm` (0.006), `fill_under_mm3` (-1: a closed space inside the material smaller than one smallest cell is filled; lattice sealed in behind skins is larger and stays), `bridge_rise` (0.5: a strut flatter than 30 degrees is printed as a bridge; 0 = every strut round), `post_mm` (0.9), `weave_stand_every_mm` (20: Organic, rule O8: a whole shallow run of a weave that goes farther than this between stands gets one post at the middle of that stretch where material lies straight below it; 0 = never; under 0 is refused, `job_unreadable`. The number is the lead's, not the owner's), `weave_foot_mm` (-1: Organic, rule O11: a weave bar that runs into the part's solid wall gets a blended foot of this size f where it meets the wall: a round strut flares from its radius r, 3 f out, to r + f at the wall; a shallow strut keeps its flat underside and widens by f each side and upward; f is held at r; below 0 = half the bar's width; 0 = no foot, the file as before. Cube-lattice bars never get one). `weave_round_top` (true: Organic, rule O14: a weave's shallow strut (a bridge) is written with a D section, its underside the square bar's flat plane and width, its sides straight for half the strut's width, its top a half round; as wide and as tall as the square bar; its foot keeps the D; false = the square bar, the file as before; not a yes or no is refused, `job_unreadable`. Cube-lattice bridges stay square). `weave_sag_lift_mm` (0.9: Organic, rule O17: a weave strand's sag no deeper than this below the lower of its two nodes held from below is lifted onto the straight line between them; 0 = never; under 0 is refused, `job_unreadable`), `weave_sag_legs` (true: Organic, rule O18: a deeper sag with material straight below its low point gets a zig-zag leg in the old engine's shape, from that material up; false = no leg; not a yes or no is refused). A weave job's result says what was done in its `organic` object: `sags_lifted`, `sag_lift_largest_mm`, `sag_legs`, `sag_legs_mm`, `sags_unsupported`; a cube-lattice job's result is as before. They are core's `MeshSpec`. For the print check: `layer_mm` (0.2), `pixel_mm` (0.05), `most_passes` (10), `leave_out` (true: a strut that would start in mid-air is left out first, posts come second; false: posts only), `keep_if_not_clean` (false).

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
             "stubs": 0, "joined": 0, "dropped": 60, "pieces": 1, "adrift": 0, "stepped_edges": 1, "thin_solid": 0, "cells_by_stress": false, "step_held_at": 0,
             "floor_cell_mm": 2.37, "min_strut_mm": 0.45, "open_look": 0.19, "touch": 0.354,
             "empty_regions": [],
             "weave_regions": 1, "strands": 120, "weave_bars": 900,   (only with a weave region)
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
  "organic": {"ms_trace": 0, "spacing_used_mm": {"smallest": 0, "largest": 0, "mean": 0},
    "rim_mm": 0, "net_struts": 0, "net_mm": 0,
    "shallow_bars": 0, "held_both": 0, "held_one": 0, "held_none": 0,
    "kept_any_length": 0, "weave_left_unheld": 0, "stands_added": 0,
    "feet": 0, "feet_held": 0, "feet_mm3": 0,
    "runs": 0, "longest_run_mm": 0, "run_bands": [
      {"band": "to 5 mm", "runs": 0, "kept": 0, "left_out": 0, "post": 0},
      {"band": "5 to 10 mm", "runs": 0, "kept": 0, "left_out": 0, "post": 0},
      {"band": "10 to 20 mm", "runs": 0, "kept": 0, "left_out": 0, "post": 0},
      {"band": "over 20 mm", "runs": 0, "kept": 0, "left_out": 0, "post": 0}]},   (only with a weave region)
  "grown": {"strands": 0, "grown_mm": 0, "kept_mm": 0, "cut_mm": {"outside": 0, "unsupported": 0,
    "leads_to_nothing": 0, "crowded": 0, "repeat": 0}, "seeds_floor": 0, ...},   (Grown only)
  "ms": {"import": 27, "measure": 0, "read": 9, "cells": 0, "bars": 1, "open_space": 6,
         "carve": 5, "struts": 47, "solid": 1, "finish": 2, "write": 1, "total": 94}
}
```

- `layout` holds the counts the bridge's `LatticeLayoutResult` holds, under the same names (`bars` here is how many).
- `grown` is written only when `organic_mode` is `"grown"` (a Traced or cube-lattice job's result is as it was): the
  `GrowReport` (rule G12): the strands returned, the length grown and kept (curve length, mm; grown = kept + every
  cut), the length cut by reason, then the seeds, steps, tip ends, branches and their refusals by cause, links,
  GR-REWIND (`rewinds`, `rewind_places` and how each place ended: `rewind_grew_on`, `rewind_joined`,
  `rewind_ended_on_joint`, `taken_back_mm`), thinning, regrowth (`holes`, `regrow_landed`, `regrow_failed`), ties
  and the time, ms.
  `thin_solid`: cut cells print rule P8 (f) made solid (a cut piece thinner than its own strut, lying against solid); they are counted in `solid_pieces` too.
  `cells_by_stress`: cell size by stress (C22) was applied to the layout (false when it was not asked for, or one of its OFF cases holds).
  `step_held_at`: the part's size-step limit the layout kept (C24, `max_step` held at the ladder's smallest step: 1.5 on Default Grade is kept as 2); 0 when none was asked. A region's own `max_step` is not reported here.
  `weave_regions`, `strands`, `weave_bars` (Organic, Traced): the weave regions laid, the strands the trace gave for them, and the bars of those regions (in `bars` too). Written only when the job has a weave region (the lead's ruling, 2026-11-17: a job with no Organic region writes the released engine's result byte for byte).
  `by_stress`: the struts were graded by stress; then `reference_mpa` is the reference used (the stated one or the part's own), `highest_mpa` the highest stress any cell read in its own cube, `at_light` and `at_heavy` the cells at the light end (no stress) and at the heavy end (at or over the reference). All 0 otherwise.
- `mesh` is core's `MeshReport`. `mm3` is the plastic in the file; `part_mm3` the solid part's.
- `print_check` is his print rules measured on the mesh the file holds, layer by layer (0.2 mm layers), the part standing on its lowest face:
  - `bed_contact_mm2` (the bridge's name): the area lying flat on the bed; `bed_flat` says it is the whole first layer with no sloped underside.
  - `midair_starts` (the bridge's name) and `one_ended`: both 0 in any file that is written; `clean` says so.
  - `passes` and `found_per_pass`: the mesh is made, checked and made again; each number is how many mid-air starts and one-ended overhangs that pass still had.
  - `left_out_at` ([x, y, z] each): the PLACES the make-check-make loop left struts out at, as it ended (core's `PrintableReport::drop_at`), gathered over all its passes: each mid-air start or one-ended overhang the layer check found, half a layer below it. Every strut whose lowest point is at one of these places is left out, and so is a small separate piece of the solid body that starts there. It is a list of places, not a count and not a list of struts: one place may leave out several struts, or none (`mesh.drop_unanswered` counts those). `posts` ([x, y, z_bottom, z_top] each): short posts added to hold up what leaving out could not fix. The preview can show both after a run.
  - `longest_bridge_reach_mm`: the farthest any bridge reaches past its supports (half its span).
  - `thin_islands`: a count only. Slices of the file about one line thick (a strut lying in an open face, cut in half by it).
- `organic` (Organic; written only when the job has a weave region): `ms_trace` is the trace's time, ms (every weave region; it is in none of `ms`'s steps, only in its `total`). `net_struts` and `net_mm` the net skin's struts as laid (O16, Finish Skin; after loose bars are dropped) and their length, mm. The rest is THE SHALLOW-BAR TABLE the owner's bridge rules (OR8 to OR10) need, from the weave's bars as laid (`shallow_bar_table` in `lattice_layout_file.hpp`):
  - `shallow_bars`: the weave's bars lying under 30 degrees (`bar_is_bridge`). `held_both`, `held_one`, `held_none`: how many of their two ends are held (an end is held when it is a node, in the solid, or joined to another bar; an end on the part's surface or loose in the lattice is not).
  - `runs`: WHOLE runs: shallow bars chained through joints where exactly two shallow bars end at one point and go on in line within 15 degrees (a crossing of two level strands is four, and ends both runs there). A shallow bar that chains to nothing is a run of one. `longest_run_mm`: the longest run, the sum of its bars' lengths.
  - `kept_any_length`, `weave_left_unheld`, `stands_added`: the owner's bridge rules (01-rules.md, O6 to O9): the shallow bars kept because both ends are held (in the solid, or on a bar that is itself kept), at any length; those left out because an end leads to nothing (never posted instead); the posts put under long shallow runs as stands (O8; they are in `print_check.posts` too).
  - `feet`, `feet_held`, `feet_mm3`: the blended feet (01-rules.md, O11): the weave ends that run into the solid and were given a foot, those whose size was held at the strut's radius, and the material the feet add (each foot between the wall and 3 f out, less the strut it wraps there).
  - `run_bands`: the runs by length (to 5 mm, over 5 to 10, over 10 to 20, over 20) and what the layer check did with each run: `left_out` when any of its bars was left out (its lowest point at one of `print_check.left_out_at`, read as the file writer reads it, or by the bridge rules, O9), else `post` when a post's top is within half the bar's width + 0.5 mm of one of its bars, else `kept`.
  - The table is filled when the mesh was made, so a `would_not_print` refusal carries it too.
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
| `no_stress_result` (Organic) | 3 | Organic follows the part's stress, and no stress result came with this job, so no file was made. Run the stress check first. (A region is a weave and no `tensor` came with the job. OR14: nothing is exported from a made-up stress here.) |
| `tensor_unreadable` | 1 | The stress tensor sent with the lattice job could not be read, so nothing was made. (`detail` says what is wrong with it: not a tensor file, the version, the size, a number that is not finite.) |
| `demand_unreadable` | 1 | The stress result sent with the lattice job could not be read, so nothing was made. (`detail` says what is wrong with it: not a demand file, the version, the size, a number that is not finite.) |
| `job_unreadable` | 1 | The lattice job sent to the Mac could not be read, so nothing was made. (`detail` names the key.) |
| `mesh_failed` | 1 | the mesh maker's own plain line, or: The lattice file could not be put together. Nothing was made. |
| `cannot_write` | 1 | The lattice file could not be saved on the Mac (the folder is missing or the disk is full). |
| `cancelled` | 1 | Stopped before the lattice file was finished. Nothing was made. (Only from code that passes a stop flag. On the worker a cancel stops the whole process and the worker reports it itself.) |
| `strength_mixed` | 1 | The strength check judges an Organic lattice and a cell lattice in different ways and cannot check a part that has both, so no file was made. Use one kind in every region, or turn the strength check off. (A `strength_job` on a job with weave AND cell regions: refused before any work; brief E2. Every region a weave: checked as a frame of beams, rules OS2 to OS6.) |
| `strengthened_unreadable` | 1 | The strengthened stress sent with the lattice job could not be read, so nothing was made. (Job key `strengthened`, brief E2.) |
| `error` | 1 | Something went wrong while making the lattice file, and nothing was made. |

The checks run in this order: the stress result (when the job names one) reads; the stress tensor (when the job names one) reads; the model opens; it has a surface; every region and Protect skin has at least one face that is the part's; By stress has a stress result; a weave has a stress tensor; the type is a strut type; cell size by stress has a stress result; the worker can make meshes; the part is closed; the layout has cells; By stress has a reference; the layout has struts.

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

## The tensor file (the stress tensor, for Organic)

Little-endian, no padding; the demand file's header with its own magic:

| Bytes | What |
|---|---|
| 8 | `TOTENSOR` |
| 4 | int32 version: 1 |
| 4 x 3 | int32 nx, ny, nz: voxels along x, y, z |
| 8 x 3 | float64 the grid's low corner x, y, z, mm, in the part's own coordinates |
| 8 | float64 the voxel edge, mm |
| 24 x nx ny nz | six float32 per voxel, in core's VoxelGrid order (index (k ny + j) nx + i); each voxel's six in `TensorField`'s order: xx, yy, zz, xy, yz, zx, MPa, true shear (not engineering); all 0 where the solve had no material |

The file is exactly 56 + 24 nx ny nz bytes. It is refused (`tensor_unreadable`) when it does not start with `TOTENSOR`, its version is not 1, its grid has no voxels, it is not exactly that size, or any number in it is not finite (or the edge is not above 0). Code: `read_tensor_file`, `write_tensor_file` in `lattice_layout_file.hpp`. The trace reads it as `TensorField` (`lattice_layout_organic.hpp`): the candidate voxels are those whose centre is lattice of the weave region.

A weave job (made-up numbers): lattice 4 mm deep under face 7, filled by the weave, strands 4 mm apart at the thinnest strut, the tensor file beside the job:

```json
{
  "mode": "lattice_file",
  "model": "wing.step",
  "tensor": "wing.tensor",
  "layout": {
    "region_ids": [1], "region_no_lattice": [0], "region_depth_mm": [4], "region_expand_mm": [0],
    "region_face_counts": [1], "region_faces": [7],
    "region_weave": [true], "organic_spacing_mm": 4, "organic_width_mm": 0
  }
}
```

A job with no weave region makes the same file it made before these keys, byte for byte (the organic keys and a tensor file are read and not used).

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
