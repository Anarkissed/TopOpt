# The quilt, before and after — captured from the running app

All simulator captures are `xcrun simctl io <udid> screenshot` on device
`A030C20C-D243-4CC4-A602-E2A90FB6CCDF`, bundle `com.nadim.topopt`, project
`68BF7B74` ("M2 verticalStand", green Optimized badge). Each was taken with the
app's own `DIAG stepped regions … sizes=[…]` line captured in the same session, and
the headless bake reproduced that line exactly every time
(`LatticeQuiltBakeProbe.testTheHeadlessBakeMatchesTheApp`).

| file | what it is |
|---|---|
| `01_BEFORE_his_settings_armed.png` | 04:44, build at `1320715f`. `sizes=[1.72=13 2.01=30 3.44=12 4.01=17 **5.16=82 6.02=56** 10.31=197 12.03=121]` — 26% of the wall at exactly S/2. |
| `02_AFTER_his_settings_front.png` | 06:16, build `d4342a87`, same settings. `sizes=[2.58=9 3.01=4 3.25=3 3.44=20 4.00=10 4.01=11 4.33=9 10.31=188 12.00=104 12.03=68 13.00=102]` — no S/2, body at the local wall. |
| `03/04_AFTER_no_grade_front/back.png` | No grade, single-cell ON. `sizes=[10.31=217 12.00=114 12.03=83 13.00=114]` — four sizes, all wall-following, zero subdivision. |
| `05_AFTER_no_grade_back_zoom.png` | the back wall at native resolution: large, evenly spaced, well-separated cells. |
| `06_OPEN_single_cell_OFF_still_fabric.png` | **STILL BROKEN.** single-cell OFF + shape grade: region cell 5.156/6.015 (two across, correct) but the grade takes ~29% of the wall to 1.43–2.17 mm and it reads as fine noise. See handoff §4b. |
| `07_tap_callout_after.png` | a tap in the graded band: `10% · 0.45 mm strut · 3.44 mm cell`. On the wall body the same tap reads `5% · 0.94 mm strut · 10.31 mm cell`, against `5% · 0.47 mm · 5.16 mm` before. |
| `08_bake_progression_offscreen.png` | offscreen, the three bakes side by side: before → per-spot tolerance → wall-following cell. |

| `09_FINAL_his_settings_front.png` | final build `e6b19570`, his settings. `sizes=[2.58=9 3.01=4 3.25=3 3.44=5 4.00=6 4.01=9 4.33=5 10.31=203 12.00=108 12.03=70 13.00=106]` — **92.2% of the wall at the local wall thickness**, grade a thin gradient at the outline. |
| `10_FINAL_single_cell_OFF.png` | single-cell OFF on the final build: `[1.62=3 1.72=68 2.00=51 2.01=25 2.17=175 4.30=34 5.16=1384 6.00=603 6.02=484 6.50=458]`. |
| `11_single_cell_OFF_before_after.png` | the 4th fix, side by side: the band was taking its finest rung twice (18.0% below S/3 -> 3.7%). |

The full analysis is in `docs/handoffs/2026-08-26-quilt-found-and-measured.md`.
