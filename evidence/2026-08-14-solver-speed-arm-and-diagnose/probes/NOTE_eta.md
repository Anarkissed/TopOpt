# The `eta05` / `eta40` probes were NOT run — and §3 does not depend on them

They are §3's generalisation: PR 327's exact volume fraction is harness-only and
never entered production (the handoff's §3 establishes that from `git diff
--stat`), so the question "would a SHARPER ersatz tip the V-cycle further into
stagnation?" cannot be asked of the shipped path directly. `plsm.eta_voxels` is
the production knob that approximates it — narrow the smoothed band from 2 voxels
to 0.5 and you have applied the same sharpening on the same path — with
`eta_voxels = 4.0` as the positive control that keeps the comparison from passing
vacuously in either direction.

**Both were started and both were stopped**, to hand the machine to the `base`
and `rearm` arms, which answer §2(b) — a question with no other route — while
these answer a question §3 has already closed structurally. `run_probes.sh`'s
`-s` guard means the stopped runs do not block a re-run.

**What §3's answer does NOT rest on:** these probes. The shipped optimiser
computes `rho_e = H_eta(-phi)` at `eta_voxels = 2` today, PR 327 changed zero
lines of `core/src`, and therefore nothing about his run's multigrid can be
attributed to it. That is settled by the diff, not by a measurement.

**What these probes WOULD add**, and why they are worth running before anyone
productionises PR 327: whether the V-cycle's behaviour is sensitive to the band
width at all. §6c makes that question sharper rather than moot — the V-cycle now
fails on this geometry with a geometric coarse space AND with an algebraic one,
so if it is also insensitive to a 8× sweep of the ersatz band, the ersatz is
conclusively not a variable in the stagnation and productionising PR 327 carries
no solver risk.

```bash
sh evidence/2026-08-14-solver-speed-arm-and-diagnose/run_probes.sh eta05
sh evidence/2026-08-14-solver-speed-arm-and-diagnose/run_probes.sh eta40
```

Read `rung 0 iter 1`'s `mg_cycles_attempted` and `cg_iters` against the `ctl`
row: 300 cycles and 927 iterations is "no change".
