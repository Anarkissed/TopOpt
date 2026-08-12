# evidence — plsm-production-settings

`SCRATCH=/somewhere/outside/the/repo ./reproduce.sh` regenerates all of it.
Nothing here is cloned and nothing is downloaded.

★ **THIS IS THE PRODUCTION PATH.** Every arm is `topopt-cli run` on his captured
job document, not `levelset_probe`. PR 326 and PR 327 ran in a sandbox whose
volume convention prints 17.1% less material than production's at the same
nominal rung (75,281 against 88,424 printed voxels at rung 0.68), so nothing
measured there can be read against production's own run of record. That is the
single most important thing to know before reading any table.

## the two rungs, and their two names

R3 asks for every claim at both. They are the same two rungs under two
conventions, and both names appear in every table:

| job document says | printed fraction | SIMP's margin there |
|---|---|---|
| rung **0.68** | **0.7973** — the SHIPPED rung | 3254.36 |
| rung **0.26** | **0.5283** — the LIGHT rung | 3014.12 |

SIMP's numbers are read out of `../2026-08-10-plsm-production/s3_simp/
base.report.json` — production's own run of record — by `tables.py`, never
retyped.

## what is here

| file | what it is |
|---|---|
| `reproduce.sh` | the whole campaign, in order. R2 first, R1 last. |
| `run_arms.sh` | the four arms. One variable between consecutive arms. |
| `measure.sh` | the surface table, the sealed void, the certificates. |
| `tables.py` | every table in the handoff, built from the instruments' output. |
| `replay_stop_rule.py` | R3(e): the shipped rule replayed over every published margin curve. |
| `run_r1_byte_identity.sh` | R1: stash-rebuild checksum, one folder, two binaries. |
| `assertion_census.sh` | R7: a MESSAGE census, not a name grep. |
| `fd/` | R2: the finite differences, both functionals, both weights. |
| `arms/` | each arm's log, receipt, report and per-rung `_alpha.meta`. |
| `m1_surface.csv` | the surface table — ONE probe invocation, SIMP in the same run. |
| `m2_topology.csv` | R6 + item 4's counters, through the shipped implementation. |

## the four arms

Each changes ONE thing from the arm above it. B, C and D are all capped at 60
iterations so the budget is not a second variable; only D → A changes it, and
changing it is item 3.

| arm | ersatz | eta | weight | cap | margin probe |
|---|---|---|---|---|---|
| `B_heaviside` | `H_eta` at the cell centre | 2 | continuum | 60 | off |
| `C_eta1` | `H_eta` at the cell centre | **1** | continuum | 60 | off |
| `D_fraction` | **the volume fraction, k = 4** | 1 | **discrete** | 60 | off |
| `A_ship` | the volume fraction, k = 4 | 1 | discrete | **120** | **every 10** |

`B_heaviside` is the PREVIOUS production posture exactly — the ersatz, the band
width, the compliance weight and the iteration cap that shipped before this task.

★ **THE COMPLIANCE WEIGHT IS ISOLATED BY R2, NOT BY A FIFTH ARM, AND THAT IS THE
STRONGER ISOLATION.** `plsm_frac_fd_probe` differences BOTH weights against the
SAME two state solves on the SAME design. An arm would have shown a different
design; the finite difference shows which gradient is right, which is the
question being asked.

## reading rules that bit somebody before

* ★ **`dihedral_*` numbers may only be compared WITHIN a column.** They fall with
  the extraction lattice on any field, so a row from one probe invocation and a
  row from another are two different triangle sets. Every roughness number here
  comes from ONE invocation, with SIMP's rungs produced in it.
* ★ **A margin is a CURVE, never a point.** Reporting the endpoint understates by
  16–24% on every arm that turns over, and that distortion has already reversed
  two conclusions in this line of work.
* ★ **Sealed void is a HIGH-DENSITY problem.** It essentially vanishes at the
  light rung (0.04% / 0.02% against 8.55–11.12% at the shipped rung), so a light
  rung passing the enclosed-void check says nothing about a heavy one.
* ★ **A mechanism's sign is not portable across volumes.** The gyroid seed's
  −12.0% at the probe's rung 0.68 became +5.3% WORSE than nothing at the shipped
  volume. Test at the shipped volume before refining anything.
