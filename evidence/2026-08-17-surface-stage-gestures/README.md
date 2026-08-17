# Evidence — surface-stage-gestures (2026-08-17)

Handoff: `docs/handoffs/2026-08-17-surface-stage-gestures.md`.

## §0 — the standing bar

| File | What it shows |
|---|---|
| `00_topology_screen_the_standing_bar.png` | The topology screen, taken FIRST, before the one new control was added. |
| `00_look_rules_read_off_the_screenshot.md` | The rules read off it — button height, radius, colour, spacing, gizmo position — and the pencil button checked against them line by line. |
| `01_surface_stage_tray_with_pencil_button.png` | The Surface stage with the tray. |
| `01b_tray_crop.png` | The tray, enlarged: five tools, divider, wireframe, x-ray, and the new pencil button at the bottom in the same 44 pt / pill / tertiary-grey form. |

## R1 — demonstrated on his own part, `M2_verticalStand.step`

| File | What it shows |
|---|---|
| `02_similar_selection_count_reported.png` | The similar selection with its count reported on the cluster ("1 like this") and in the hint line — the state a double tap arms. |
| `03_pencil_mode_on_no_pencil_seen.png` | Pencil mode ON, and the stage saying *"Pencil only — no pencil seen yet, so fingers still edit."* §2(c) on screen. |
| `04_rotate_free_angle_36deg_between_detents.png` | The rotate drag stopped at 36° — **between** detents. The old `snap` would have forced 30°. |
| `04b_rotate_readout_36deg.png` | The readout, enlarged. |
| `04c_quarter_turn_lands_on_detent_120deg.png` | The ¼-turn button taking 36.8° to 120° — onto a detent, as it should. |
| `05_cut_committed_at_the_free_angle.png` | The cut committed at that free angle: the band is now two pieces. |
| `06_undo_restored_the_single_piece.png` | Undo — one piece again. |
| `07_redo_put_the_cut_back.png` | Redo — two pieces again. |

★ **Not claimed:** the harness has no multi-tap primitive, so the double tap itself and the
two/three-finger undo/redo double taps could not be injected on the device (two sequential
taps land ~1 s apart). Their destination states are shown above; their routing is pinned
headlessly. And the *enforced* half of pencil mode cannot be exercised on a simulator at
all — there is no pencil hardware, so no `.pencil` `UITouch` can arrive. See the handoff.

## The bars

| File | Bar |
|---|---|
| `r2_similar_match_count.txt` | R2 — the match count on his part, with PR 331's 24-of-78 / 13 missed / 19 over-caught reproduced in the same run. |
| `r6_diffstat.txt` | R6 — `git diff --stat` against the merge base `500833ed`. |
| `r7_longest_string.txt` | R7 — the longest string added and its word count. |
| `r8_assertion_census.txt` | R8 — every deleted line, read whole; no assertion deleted or weakened. |
| `r5_full_suite.txt` | R5 — the whole package suite, so nothing that already worked regressed. |
