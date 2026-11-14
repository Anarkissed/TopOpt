# Core brief for #358: core answers "what is the smallest cell that prints?" with different floors

From PR #354's app track, round 3 (2026-10-06). The reviewer's ruling Q3(ii), 2026-10-05: "the
preview uses the floor core applies in that job's run, per algorithm. Cite core's file:line for each
and call that same function. If core uses different floors for the same question on different paths,
report it to me for #358; don't pick one."

This brief is that report. Core lines are at 23e6154e, the core #354 links. Every line was read by one
reader and checked by a second. "PLAUSIBLE" marks a path that was read but not run. No file under
`core/` was edited.

## The numbers (octet, 0.45 mm bead)

| Floor | Value | Where core computes it |
|---|---|---|
| Light floor: w/φ(ρ_min) | 4.931378498 mm | `lattice_cell_printability_floor_mm`, lattice.cpp:428-438 |
| Aesthetic light floor: w/φ(2ρ_min) | 3.360703149 mm | grading.cpp:444-451, grading.hpp:163 |
| Dense floor at the job's cap: w/φ(min(ρ_max, cap)) | 2.25 mm | inline only, grading.cpp:184-187 and 258-260 |
| Dense floor, uncapped: w/φ(ρ_max) | 1.173173434 mm | inline ×4, see D1 |
| Organic print floor: 0.5·w·√(3π) | 0.690745528 mm | organic_lattice.cpp:943-946 |

## What the app does now

- **The tile floor is the dense floor at the job's own cap.** It is composed in the bridge from
  `lattice_rho_max` and `lattice_strut_diameter_mm` (`lattice_min_printable_cell_mm`, PR #354
  1db8bba7), exactly as grade_lattice composes it.
- **No public core function takes the cap.** That composition is core's arithmetic, repeated, not
  core's function. Please export one (ask E1 below).

## The disagreements

### D1: the dense floor honours `max_relative_density` only inside grade_lattice

`grade_lattice` caps the band top (grading.cpp:184-187), so Fixed gets 2.25 mm under the cap
(258-260, 265-268). Every other place computes w/φ(ρ_max) uncapped, giving 1.173 mm:
- `lattice_derive_cell_for_member` (lattice.cpp:485-488, 517-518), which has no cap parameter;
- through it, `fill_fit_region_cell` (run_job.cpp:1222, 1231) and the bridge's region derivation;
- `lattice_min_density_for_strut` (lattice.cpp:450-463), used as grade_lattice's `print_rho_floor`
  (grading.cpp:282-286);
- `cell_plan_finest_printable_cell_mm` (cell_plan.cpp:58-75);
- `planned_cell_mm` for Fixed, Fit and Swept (run_job.cpp:1562-1564, 1585-1599);
- the swept frontier note (11258-11259);
- the pre-flight sentences (11511, 11543, 11577, 11609, 11624-11627).

So one run reports two numbers under one key name. `fit.min_printable_cell_mm` is the CAPPED one
(grading.cpp:271; run_job.cpp:1512, 12758-12759). The per-region receipt prints the UNCAPPED
1.173173434 (6117-6120). Both appear in the 3418E167 receipt.

### D2 (PLAUSIBLE): Fit and the cap collide

- Fit's cell floor is uncapped (run_job.cpp:1231).
- Its density raise bisects the uncapped band (grading.cpp:880, 282-286).
- The L2 check then requires ρ ≤ the capped ρ_hi (grading.cpp:1133-1135).

Any Fit region whose derived cell is under 2.25 mm should therefore throw with Allow quilt off, i.e.
an extent under 11.25 mm at N* = 5. Core's only cap test is a Fixed run at the light-floor cell
(test_grading.cpp:105, 115-147).

### D3: the refusal sentence quotes the light floor on every path

The post-grade sentence quotes `gf.printability_floor_mm`, the light floor at ρ_min
(run_job.cpp:6186-6191; grading.cpp:236-237, 270), whatever the cell mode.
- On swept, the floor that binds is per cell, at the cell's own min ρ (cell_plan.cpp:197-204).
- On Fixed and Fit, the dense floor binds.

The same sentence's "a member must be at least N* × cell_size_mm" uses
`gf.cell_size_mm = max(0, abs_floor_mm)`, which is 2.25 under the cap (grading.cpp:265-269, 287).
That number is neither a rung of the window nor the floor it quotes a line later.

### D4 (PLAUSIBLE): Stepped tests the region's MEDIAN density; swept tests each cell's MIN

- `run_stepped_step` computes S_r = max(W_med/N*, w/φ(ρ_med)) (run_job.cpp:4109, 4117-4120).
- The no-plan emission sizes each strut at its voxel's own ρ, with no bead check
  (7192-7201; `checked_radius` only requires r > 0, lattice_gen.cpp:256-261).
- grade_lattice's per-voxel printability assert (grading.cpp:1180-1187) runs before Stepped replaces
  the cell field (6477), and nothing asserts again afterwards.
- N* is 5 under both intents (4068).

### D5: a plan's tile floor is the job's own number, or the bead

- `tile_floor = stepped_min_tile_mm`, or else the bead (run_job.cpp:7012-7014). A doubled job cannot
  carry that key (job.cpp:2050-2059), so its floor is just over the bead.
- Prints-open hangs on the intent string (7011), which doubled jobs don't carry.
- A sent cell's ρ is checked against neither the bead nor the cap: `stepped_validate_plan` never reads
  `cell.rho` (stepped_plan.cpp:98-135), and job.cpp:1356-1362 checks only (0, 1].
- The plan's base cell has no floor (stepped_plan.cpp:70).
- Plan cells are laid without reference to the graded mask (run_job.cpp:7048-7057).

### D6: the forecast (the stage's Check) is uncapped and has zero demand

`forecast_grading_params` sends no cap and no intent (run_job.cpp:8303-8328, 8504, 10085-10091), and
grades a ZERO demand field (8480-8482). So it grades every voxel at ρ_min and applies the light floor
per cell on swept. The Check and the run therefore differ in both directions.

### D7: organic answers "smallest spacing" with three different beads

- The recommendation band uses the printer bead (run_job.cpp:5587-5590).
- The tracer uses the per-voxel bead: the stated `organic_strut_width_mm` when one is stated
  (organic_lattice.cpp:943-946, 981; run_job.cpp:4590-4594, 4616).
- Without a window (the app's organic Auto) it uses
  max(2h·√(ρ_max/3π), w) (run_job.cpp:4591-4594; organic_lattice.hpp:712-721).

At a stated 0.9 mm bead, the first two give 0.6907 mm and 1.3815 mm.

### D8: a stated density over the cap is clamped silently

- The schema accepts a stated region density up to the uncapped band (job.cpp:1446-1455), and the
  refusal quotes "up to lattice_rho_max" (run_job.cpp:1383).
- grade_lattice then clamps it to the capped top (grading.cpp:558-568). The clamp is counted, but
  nothing refuses it.
- In Fit, the uncapped raise can then lift it back over the cap (see D2).

### D9 (inert today): two topologies on one path

On the geometry path grade_lattice is told Octet (run_job.cpp:5402; the forecast at 8305). The job's
topology is used elsewhere (resolved at 5311-5312): the stepped step (4067), the validator (7023) and
the radii (7099). The region report mixes Octet's N* and ρ_max with the job's φ (6083-6086, 6117-6120).

### D10: Doubled ACCEPTS a lattice of 0 voxels; Stepped refuses the same mask with the wrong cause

- `region_ungradeable` is tested at run_job.cpp:6168. The outline beam then clears the mask
  (6400-6446).
- His 3418E167, converted to Doubled, printed "over 0 voxels" then "verdict: ACCEPTED", with
  `interior_volume_mm3` 0.
- The same job as Stepped (his real one) is REFUSED after 171 s: "the stepped algorithm derived no
  region cell … carrying 0 distinct region ids … use "algorithm": "doubled"".
  - The real cause is the swept grade: window [2.4, 2.8], 27,780 base cells dropped as unprintable,
    4 voxels left, then cleared by the beam.
  - The message names region ids instead, and recommends the algorithm that silently accepts 0.

Evidence: PR #354 worktree `scratch/evidence/item5-3418/{run,conv}/`.

### D11: "irrecoverable_by_any_cell_size" uses a different floor per mode

It uses the light floor on uniform and swept (grading.cpp:723, 1067) and the capped floor on Fit
(863, 873). The refusal (run_job.cpp:6179-6180) and the forecast's remedies (8528-8530, 8584) read it.

### D12: Stepped reads an unmeasurable (+inf) width as SMALLER than a measured one

- `run_stepped_step` substitutes cap·h for +inf (run_job.cpp:4087-4088): 58.37 mm at h = 1.824.
- `local_member_thickness_mm`'s +inf means at least 2·cap·h, and its finite widths reach 113 mm
  (voxelize.cpp:579-604).

So a member too thick to measure gets a finer S_r than a measured thinner one.

### D13: the region verdict calls a printability fallback "load"

`solid_load` is decided from the UNCAPPED derivation (run_job.cpp:6130-6140), not from the fallback
reason. On 3418E167 (converted), face 15 is reported `solid_load` (stress fraction 0.166). But at
least 42,877 of its 43,056 voxels fell back as `strut_unprintable`.

## Asks

- **E1.** One public function for the dense floor at a cap,
  `lattice_min_printable_cell_mm(topo, w, max_relative_density)`, used by every path in D1.
- **E2.** Export what Stepped lays per region, so the app's Stepped preview can call core's own rule:
  `run_stepped_step`'s S_r, ρ_med, W_med, voxel counts and its refusal. It is in run_job.cpp's
  anonymous namespace (67-7818), so the bridge cannot reach it today.
  - Also export the swept plan's per-cell predicate. Today it exists only inside `plan_cell_sizes`.
- **E3.** One verdict on an empty post-beam mask for all three algorithms. Name the real cause (the
  swept grade, then the beam), not region ids.
- **E4.** Rule D2–D8 and D11–D13. The app picks none of them.

## Also seen on the app's path (for the queued organic preview task, not core)

His 102117B9 as Manual one size (4 mm and 6 mm, ruling 5's swept window) is REFUSED by core. One
latticed voxel (4.959 mm³, include region 31) sits in a sealed cavity, and the app writes
`require_lattice_void_reaches_exterior: true`. The preview draws the lattice regardless. The full
preview-vs-run comparison is in the round 3 handoff.
