# Evidence — SIMP penalization continuation (2026-08-02)

Handoff: `docs/handoffs/2026-08-02-simp-penalization-continuation.md`

This task adds an **opt-in, default-OFF** penalization-continuation schedule to
`SimpOptions` and MEASURES it against the shipped constant `p = 3`. The shipped
formulation is unchanged; `ad1_byte_identity.txt` is the proof.

| file | what it is |
| --- | --- |
| `ad1_byte_identity.txt` | **AD1.** Stash-rebuild checksums of the gate demo fixture from three runs: the pre-change binary twice, and the post-change binary with the option off. Every deterministic artifact matches; the one file that differs also differs pre-vs-pre (a wall-clock field). |
| `ad1_designbox_trajectory.txt` | **AD1, second witness.** The design-box (matrix-free, *stagnating*) path, which the demo fixture does not exercise: every deterministic column of the CLI's `iterations.csv`, row by row, pre-change vs post-change. |
| `probe_all.txt` | The primary measurement: five postures on the full 3-rung ladder, per-iteration trace (p, β, CG, whether multigrid carried, whether a hierarchy built), then the AD2–AD6 tables. |
| `iterations.csv`, `rungs.csv` | That run's raw per-iteration and per-rung rows. |
| `probe_matched_ladder.txt` | **AD3 (wall).** The same five postures on a MATCHED two-rung ladder — the baseline evaluated three rungs while every schedule stopped at two, so the primary run's totals are not a fair wall comparison and are not cited as one. One serialized process. |
| `iterations_matched_ladder.csv`, `rungs_matched_ladder.csv` | Its raw rows. |
| `probe_replay_isolation.txt` | The experiment that tried to isolate the per-call schedule REPLAY (conditional projection gate disarmed) and **failed to**: with the projection phase gone the OFF baseline also fails, so there is no control. Kept because it independently confirms that all the stagnation is in the β = 0 phase. |
| `determinism.txt` | **AD7 (determinism).** The two independent runs' per-rung records compared field by field: 130 deterministic values, 0 differing. |
| `ctest.txt` | **AD7.** Full `ctest` output after the change. |
| `fixture_scout_*.txt` | The two ladder scouts behind the fixture choice (see below). |
| `designbox_job.json` | The job used for the design-box byte-identity witness. |

## The fixture

`make_big_stagnation()` from `core/tests/harness/draft_arming_gate.cpp`,
reproduced verbatim in the probe: a 24×6×24 mm L-bracket at 1.0 mm spacing inside
a design box padded by 0.35 × the canonical (12, 13, 12) mm — the dilute,
high-contrast design-box regime on which the geometric V-cycle measurably
stagnates. Ladder `0.68 / 0.52 / 0.38`, `margin_stop 1.5`, 20-iteration rung
budget, the armed production option stack
(`configure_production_options`).

The pad scale and the ladder are the two dials that were scouted, for a reason
worth stating: at the canonical pad the ladder's rungs come back
`load path not connected` in **every** posture, and a gate table built on severed
rungs compares nothing. `fixture_scout_shallow_ladder.txt` (0.68/0.60/0.52) and
`fixture_scout_production_ladder.txt` (0.68/0.52/0.38) are the two candidates
that were tried at pad 0.35; the production-shaped one was chosen because its
baseline gives the real production shape — ACCEPT, ACCEPT, then a genuine
terminal REJECT on `margin below required` — while still stagnating three times
per rung. Those two scouts ran CONCURRENTLY, so their wall figures are not cited
anywhere.

The postures, in the probe's own words:

| label | schedule | source |
| --- | --- | --- |
| S0 | (empty) — constant p = 3 | what ships |
| S1 | 1.00…4.00 by 0.25, **20** iterations per value | Peetz & Elbanna, verbatim |
| S2 | 1.00…4.00 by 0.25, **1** iteration per value | Peetz's values, dwell scaled to fit a 20-iteration rung |
| S3 | 1.00…3.00 by 0.25, **1** iteration per value | Amir & Sigmund state "gradually increased from 1.0 to 3.0" and publish no dwell; this is that ramp at a dwell that fits |
| S4 | 1.00…3.00 by 0.50, **2** iterations per value | this task's own — justified by the MEASURED stagnation window (iterations 3–6), and ending at `params.penalty` so trajectory and certificate agree |

## Reproducing

```bash
cmake -S core -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j
```

```bash
c++ -std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" core/tests/harness/penalty_continuation_probe.cpp build/libtopopt.a -o build/penalty_continuation_probe
```

```bash
PC_PAD=0.35 PC_LADDER="0.68,0.52,0.38" PC_TRACE=1 ./build/penalty_continuation_probe 20 /tmp/pc_out
```

The unit contract (byte-identity, the pure schedule map, the published schedules,
the refusals) is a CTest target, not a probe:

```bash
ctest --test-dir build -R penalty_continuation --output-on-failure
```

Machine of record: Apple M2 Pro (6P+4E), 16 GB, macOS 25.5.0. Wall figures in
`probe_all.txt` come from ONE serialized process with nothing else running; the
scouting runs in the handoff's §fixture section were concurrent and their walls
are not cited.
