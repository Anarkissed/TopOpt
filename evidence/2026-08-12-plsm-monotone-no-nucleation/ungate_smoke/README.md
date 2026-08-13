# the control arm measured nothing, and every health check passed

`void_components`, `euler_chi`, `cavities` and `tunnels` were written as 0 on
every row of `MN_nucleating` — the arm whose entire purpose is to show what the
void's component count does WITHOUT the constraint. The counters lived inside
the `if (a.monotone && ...)` branch, so the one arm that does not pass
`--monotone` could never populate them.

★ **The night queue verifies each arm four ways — exit code, `summary.txt`
exists, at least one iteration, no `FATAL` in the log — and all four passed.**
The arm ran correctly for 36 iterations and produced no data for the task's
central question.

Fixed by splitting measurement from enforcement: the topology is counted on
every iteration of every PLSM arm, and `--monotone` now gates only the repair.
`mono_violations` is likewise counted on the control, since "how often the
constraint WOULD have fired" is exactly what the control exists to report.

`iterations.csv` here is the 3-iteration smoke test that verified it, run
WITHOUT `--monotone`:

| iter | components | chi | cavities | tunnels | new | split | violations | reverts |
|---|---|---|---|---|---|---|---|---|
| 1 | 87 | −1989 | 0 | 2076 | 0 | 0 | 0 | 0 |
| 2 | 512 | −2816 | 42 | 3370 | **3** | **422** | 1 | 0 |
| 3 | 518 | −2367 | 42 | 2927 | 0 | 6 | 1 | 0 |

★ And it already shows the task's answer on the control: the count rises by
**SPLITTING (422)**, not by **NUCLEATION (3)**. `mono_reverts` stays 0, confirming
enforcement is genuinely off.

25 minutes of the first arm were discarded and the queue restarted so that all
eight arms share one binary (R2).
