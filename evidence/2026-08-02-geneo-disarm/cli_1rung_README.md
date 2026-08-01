# AA5 end-to-end: the decision log on a COMPLETING production run

`ladder32_1rung.json` — the same job as `cli_ladder32_*` cut to a single rung so
the run COMPLETES and reaches run_info's finalize block (the 4-rung version
aborts on a pre-existing non-finite-margin defect; see `cli_ladder32_README.md`).

`cli_1rung_run_info.json`, the GenEO block:

```
geneo_twolevel                true      geneo_basis_builds        5
geneo_trigger_iters           500       geneo_coarse_refreshes    4
geneo_rebuild_factor          2         geneo_armed_solves        9
geneo_refresh_cost_per_column 2         geneo_declined_solves    23
geneo_deflated_iter_cost      2         geneo_basis_dim         700
geneo_decisions_dropped       0         geneo_basis_mb        22.73
```

**23 declined against 9 armed.** Every arm and disarm TRANSITION is in
`geneo_decisions` with the reason and the numbers it fired on — 15 events, none
dropped:

| solve | action | burn | threshold | N_t | engaged_burn | engaged_tail | iterations |
|---:|---:|---:|---:|---:|---:|---:|---:|
|  1 | 3 BUILD    |    500 |    500 | 724 |   500 |  700 |  1,200 |
|  2 | 5 DECLINE  |  2,805 |  3,348 | 724 |   500 |  700 |  2,805 |
|  3 | 2 ENGAGE   |  3,348 |  3,348 | 724 |   500 |  700 | 10,736 |
|  4 | 5 DECLINE  |  2,595 |  3,848 | 724 |   500 |  700 |  2,595 |
|  5 | 3 REBUILD  |  3,848 |  3,848 | 658 | 3,848 |   38 |  3,886 |
|  6 | 5 DECLINE  |  2,259 |  5,240 | 658 | 3,848 |   38 |  2,259 |
|  8 | 2 ENGAGE   |  5,240 |  5,240 | 658 | 3,848 |   38 |  9,477 |
|  9 | 3 REBUILD  |  5,740 |  5,740 | 723 | 5,740 |   42 |  5,782 |
| 10 | 2 ENGAGE   |  7,270 |  7,270 | 723 | 5,740 |   42 |  7,557 |
| 11 | 5 DECLINE  |  5,826 |  7,770 | 723 | 5,740 |   42 |  5,826 |
| 17 | 3 REBUILD  |  7,770 |  7,770 | 806 | 7,770 | 1,134 |  8,904 |
| 18 | 2 ENGAGE   | 11,650 | 11,650 | 806 | 7,770 | 1,134 | 17,549 |
| 19 | 5 DECLINE  |  4,775 | 12,150 | 806 | 7,770 | 1,134 |  4,775 |
| 20 | 3 REBUILD  | 12,150 | 12,150 | 700 | 12,150 |  98 | 12,248 |
| 21 | 5 DECLINE  |  2,874 | 13,746 | 700 | 12,150 |  98 |  2,874 |

Every threshold is reproducible from the row above it:
`threshold = 2*N_t + engaged_burn + 2*engaged_tail`. Solve 3, for instance:
`2*724 + 500 + 2*700 = 3,348`, and the burn column shows engagement at exactly
3,348. **Nothing here needs another instrumentation task to interpret.**

## The log is also the clearest statement of the known limitation

Read the threshold column downward: **500 → 3,348 → 3,848 → 5,240 → 5,740 →
7,270 → 7,770 → 11,650 → 12,150 → 13,746.** Each REBUILD records its own high
burn as `engaged_burn`, and that burn is a property of the GATE POLICY rather
than of GenEO — so the bar the accelerator has to clear ratchets upward. By solve
21 the gate is turning down a 2,874-iteration solve against a 13,746 threshold.

The direction is conservative (fewer engagements, never more), so it cannot
reintroduce the tax this task removed, and the rescue still fired four times
here on solves of 7,557-17,549 iterations. The one-line tightening —
`min(engaged_burn, kGeneoTriggerIters)` — is named in the handoff as the first
follow-up and deliberately NOT made here.
