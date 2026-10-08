# Stage-job hashes, round 3

Made with round 2's `tools/dump_stage_hashes.sh` on snapshot S1-2026-10-02 (`SWIFT_DETERMINISTIC_HASHING` unset). Each value is the first 16 hex digits of the SHA-256 of the `lattice_part` job the app would send. Round 2's last arm, fo (3ba44c7d), is the baseline.

| arm | commit | 102117B9 | 68BF7B74 (stand) | 92A8016E (octet) | 570B38E2 | 3418E167 | AA4C7953 | 887AC498 |
|---|---|---|---|---|---|---|---|---|
| fo | round 2 end (3ba44c7d) | 3f19f920e5c96a5a | 6dbb48fab4029f78 | c4ca5d5ac009036d | 2baaf9cbb94027c7 | 7ba46796d87e3b34 | 3e6f162cb36212a9 | b457718dfc23ab42 |
| g | the one bridge guard + the stale-type gate | 3f19f920e5c96a5a | 6dbb48fab4029f78 | c4ca5d5ac009036d | 2baaf9cbb94027c7 | 7ba46796d87e3b34 | 3e6f162cb36212a9 | b457718dfc23ab42 |
| o5 | ruling 5: organic one size as a one-size window | 3f19f920e5c96a5a | 6dbb48fab4029f78 | c4ca5d5ac009036d | 2baaf9cbb94027c7 | 7ba46796d87e3b34 | 3e6f162cb36212a9 | b457718dfc23ab42 |
| l6 | ruling 6: the plan-not-sent line (blockValue reads the shared predicate) | 3f19f920e5c96a5a | 6dbb48fab4029f78 | c4ca5d5ac009036d | 2baaf9cbb94027c7 | 7ba46796d87e3b34 | 3e6f162cb36212a9 | b457718dfc23ab42 |
| t5 | R7 + anchor footprint + Q2 + Q3(i): core's tile floor (67595f19 + this) | 3f19f920e5c96a5a | 6dbb48fab4029f78 | c4ca5d5ac009036d | 2baaf9cbb94027c7 | **c89da26e6a71021c** | 3e6f162cb36212a9 | b457718dfc23ab42 |
| t7 | R7 step-down + the Stepped line + the organic rim's floor in the job (round 4) | **d08fc7a7650675b4** | 6dbb48fab4029f78 | c4ca5d5ac009036d | 2baaf9cbb94027c7 | c89da26e6a71021c | 3e6f162cb36212a9 | b457718dfc23ab42 |
| s9 | sync: #358 at 36f5fdde (ce294588) | d08fc7a7650675b4 | 6dbb48fab4029f78 | c4ca5d5ac009036d | 2baaf9cbb94027c7 | c89da26e6a71021c | 3e6f162cb36212a9 | b457718dfc23ab42 |
| so | the plan's slot origin (`slot_origin_mm`), withheld off-plane | d08fc7a7650675b4 | 6dbb48fab4029f78 | c4ca5d5ac009036d | 2baaf9cbb94027c7 | c89da26e6a71021c | 3e6f162cb36212a9 | b457718dfc23ab42 |
| go | the Structural Stepped block + the owner is core's (52cbc65e, c8d67dfa) | d08fc7a7650675b4 | 6dbb48fab4029f78 | c4ca5d5ac009036d | 2baaf9cbb94027c7 | c89da26e6a71021c | 3e6f162cb36212a9 | b457718dfc23ab42 |
| fd | no fifths in the any-step packer; core's depth rule in the bake | d08fc7a7650675b4 | 6dbb48fab4029f78 | c4ca5d5ac009036d | 2baaf9cbb94027c7 | c89da26e6a71021c | 3e6f162cb36212a9 | b457718dfc23ab42 |

g equals fo on all seven: the guard and the gate move no stage-job bytes.

o5 equals g: none of his seven projects has an organic Manual pick (102117B9 is organic Auto), so no stored job moves. The single-size bytes DO move in `OrganicJobsCoreAcceptsTests` (fit + cell_mm → swept 4/4), the positive control.

t5 equals l6 on six of seven: R7, the anchor footprint and Q2 are preview/UI only. 3418E167 moves
in ONE key, `grading.stepped_min_tile_mm` 1.8 → 2.25 — Q3(i): core's printable floor at the cap the
job writes (Allow quilt off), not four beads. Core reads that key only when validating a plan, and no
Stepped job carries one, so the run is unchanged.

t7 equals t5 on six of seven: the R7 step-down and the Stepped line are preview only. 102117B9 (organic)
moves in ONE key, `grading.organic_solid_rim_mm` 0.691 → 1.705 mm — the job's automatic rim is now the
printability floor the preview draws, max(1.535 × bead, one design voxel) (item 2, measured).

s9 equals t7 on all seven: the #358 sync at 36f5fdde moves no stage-job bytes.

so equals s9 on all seven. The slot origin rides only with a plan, and production sends no plan
(`defaultGradePlansEnabled` is off).

go and fd equal so on all seven. The gate refuses on the buttons, not in the job builder. The owner
swap, the packer's menu and the depth rule shape only the plan, and production sends none.
