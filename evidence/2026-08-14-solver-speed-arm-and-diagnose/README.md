# evidence — solver-speed-arm-and-diagnose

Handoff: `docs/handoffs/2026-08-14-solver-speed-arm-and-diagnose.md`.
`reproduce.sh` regenerates everything here.

## ★ The diagnosis costs nothing and is step 1

The two root causes — why GenEO declines and when multigrid latched — are **read
out of artifacts already committed to this repository**, not measured by any run
in this directory:

```bash
python3 tables.py
```

Its first two sections come from
`evidence/2026-08-10-plsm-production/s1_production_run/`, a real captured 4-rung
128³ production run on his part. Under a second, no build, no solve. Everything
else here exists to test what to *do* about them.

## What is what

| file | what it is |
| --- | --- |
| `tables.py` / `tables.txt` | every table the handoff prints, from committed artifacts only |
| `assertion_census.sh` / `r6_assertion_census.txt` | R6 — message census across tests, ctest names, production refusals, CHECK-operator histogram, `static_assert` messages, and the harness bag |
| `check_r2.py` / `r2_byte_identity.txt` / `r2/` | R2 — `--arm base` reproduces `topopt-cli run`, and this tree reproduces HIS captured run for 13 solves. Compares the COMMON PREFIX; the script header explains why neither a positional zip nor a `(rung, iter)` key is the right rule |
| `run_probes.sh` / `probes/` | the mechanism probes — §4(a) algebraic level, §3 ersatz sharpness both ways |
| `run_arms.sh` / `arms/` | the full-ladder arms — the R1 table |
| `run_nt_triage.sh` / `nt_triage/` | §1(b) — the GenEO basis dimension `N_t` at each subdomain tiling, one solve per point. **`nt_triage/RESULT.md` is where this task's one BLOCKED measurement is reported as blocked** |
| `probes/NOTE_ctl.md`, `probes/NOTE_eta.md` | what was stopped early, why, and the command that finishes it |
| `ctest.txt` | the suite: **119/119 passed**, with the denominator stated — two lib3mf-gated tests are registered but not configured in this build, so CI's denominator is 121 |
| `host_load.txt` | the host was SHARED throughout; this is why no wall figure is cited as evidence |
| `queue.log` | the measurement queue's own transcript, in order, with timestamps |

## Two things to read before reading a number

**Wall is not the signal.** The host ran other agents' `topopt-cli` processes for
the whole measurement window (`host_load.txt`: load averages 22–122 on a 10-core
box). CG iteration counts, matvec counts and `N_t` are deterministic and
unaffected. Wall is printed beside them and is indicative only — the same
discipline `2026-08-02-warm-start-coarse-experiment` §3 and `2026-07-29-geneo-arming`
§Machine applied to the same condition.

**The arms are capped, identically.** `run_arms.sh` caps PLSM at `$ITERS` design
iterations per rung instead of the shipped 60, applied to every arm including
`base`. So every "total CG" figure here is a total over 4 × `$ITERS` design
iterations and is comparable **only within this table** — never against his
60-iteration run. The cap also makes each solve *cheaper* than his (≈1,400 CG
against his ≈4,400), which biases the table **against** GenEO engaging: the
threshold it must clear is unchanged while the plain solve it is racing got
shorter. A GenEO win measured here is therefore a conservative one.
