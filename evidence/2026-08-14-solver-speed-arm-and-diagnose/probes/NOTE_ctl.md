# The `ctl` probe was stopped after its first solve — deliberately

`run_probes.sh ctl` is the probes' own control: his job, shipped posture, same
`ITERS`. It was stopped after its FIRST SOLVE, because that solve is the whole
control — rung 0 iteration 1 is the only solve on which multigrid is attempted at
`ITERS=1` — and the host could not afford the remaining three rungs
(`../host_load.txt`). Its `iterations.csv` therefore carries exactly the row the
probe table needs and no others:

```
  rung 0 iter 1   cg_iters 927   hier_built 1   mg_cycles_attempted 300   used_mg 0
```

PLSM is deterministic, so rung 0 iteration 1 is the same solve in every arm that
does not change the optimiser. It has now been produced by **four independent
runs on this tree** — the `base` arm, the `iters=1` posture check, the `iters=2`
smoke run, and the earlier `topopt-cli run` — and every one of them reports:

```
  rung 0 iter 1   cg_iters 927   hier_built 1   mg_cycles_attempted 300
```

which is also, to the digit, what his captured production run reports
(`evidence/2026-08-10-plsm-production/s1_production_run/iterations.csv`).

**So the control row is measured, not inferred, and it agrees with every other
production of the same solve.** Only the later rungs of the `ctl` arm are
missing, and at `ITERS=1` they attempt no multigrid at all (the latch has closed
by then), so nothing the probe table reads is absent. Re-running
`sh run_probes.sh ctl` on a quiet machine fills them in; the `-s` guard in
`run_probes.sh` means the stopped run does not block that.
