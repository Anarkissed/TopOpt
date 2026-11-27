# Note added 2026-11-27 (TO rebuild stage 5, item 4)

The evidence in this folder is left exactly as it was recorded. This note is the only addition.

`reproduce.sh` step S1 passes `--fp32` to `levelset_probe`. Single precision was deleted from the solver in commit e826135f (TO stage 5 item 4: it saved under 15 % of the solve wall with the stage-5 Chebyshev smoother). From that commit on, `levelset_probe` no longer knows the flag and stops with `FATAL: unknown argument --fp32`.

So `reproduce.sh` reproduces this folder only on a build from before e826135f. On a later build, the S2/S3 run completes, then the script stops at S1 (it runs under `set -e`), so R2 and the bars after it do not run either. S1's recorded answer (`s1_fp32_is_a_noop.txt`: the V-cycle never engages on his part, so the single-precision branch was never taken) is unaffected. It is a record of that build.
