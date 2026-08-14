# evidence — geneo-subdomain-tiling-sweep

Handoff: `docs/handoffs/2026-08-16-geneo-tiling-sweep.md`.
`reproduce.sh` regenerates everything here.

This is PR 329's one BLOCKED measurement, re-run. 329 asked what `N_t` is at
each GenEO subdomain tiling on the maintainer's 128 job and could not answer:
the host was shared with four other agents' jobs and neither point below the
shipped tiling finished. `nt_triage/RESULT.md` there reported it as blocked and
named the exact command; this directory runs it.

## What is what

| file | what it is |
| --- | --- |
| `e0_expected_before_measuring.md` | the six predictions, written after `core=8` landed and **before** 12/16/24 did, so they can be graded rather than reconstructed |
| `run_nt_triage.sh` / `nt_triage/` | §1(a) — `N_t` at each tiling, ONE solve per point. `core<N>.txt` is the parsed row; `run_core<N>/` holds the `run_info.json` and `iterations.csv` it was read from |
| `run_arms.sh` / `arms/` | §1(c) — the full ladders that carry **TOTAL CG ITERATIONS**, the figure of merit. Deeper than the triage, and its header says why the triage cannot answer this |
| `collect_triage.sh` | copies each triage point's `run_info.json` / `iterations.csv` out of `$TMPDIR` into this directory — a measurement that exists only in a scratch dir can vanish between the run and the handoff |
| `tables.py` / `tables.txt` | every table the handoff prints |
| `assertion_census.sh` / `r7_assertion_census.txt` | R7 — message census across tests, ctest names, production refusals, the CHECK-operator histogram, `static_assert` messages, and the harness bag. **Baselined on HEAD, not `main`** — see the script header for why that is a correction and not a shortcut |
| `r4_byte_identity.txt` | R4 — no production default moved, by stash-rebuild checksum |
| `build_type.txt` | R3 — `CMAKE_BUILD_TYPE=Release`, `-O3 -DNDEBUG`, and the one `solver_arm_sweep` md5 every sweep point ran against |
| `host_load.txt` | R2 — the load at the start and end of the sweep, and what else was on the box |

## ★ Three things to read before reading a number

**1. THE MACHINE WAS NOT QUIET, AND THE TASK'S PREMISE THAT IT WAS IS WRONG.**
The task says "THE MACHINE IS QUIET NOW". It was not, at any point. Load average
was **18.1 at the first check and 122.8 mid-sweep** on a 10-core box, with three
other worktrees' `topopt-cli` processes and a full `ctest` build running
throughout. `host_load.txt` records it. This does not invalidate the sweep, and
the reason is the next point.

**2. THE FIGURE OF MERIT IS A COUNT, AND COUNTS DO NOT CARE.** `N_t`, total CG
iterations, matvecs and the gate's `burn`/`threshold` are all DETERMINISTIC — the
engagement gate compares counts and never a clock, by explicit design
(`geneo.hpp`, "WHY COUNTS AND NOT WALL"). They come back identical on a loaded
host and a quiet one. **Wall is reported beside them as context and is cited as
evidence nowhere**, which is the same discipline
`2026-08-02-warm-start-coarse-experiment` §3 and `2026-07-29-geneo-arming`
§Machine applied to the same condition. The one quantity in §1(b) that is
irreducibly wall — basis BUILD SECONDS — is printed with
`geneo_coarse_matvecs` beside it so the same cost is available in a unit the
host cannot move.

**3. THE ARMS ARE CAPPED, IDENTICALLY.** `run_arms.sh` caps PLSM at `$ITERS`
design iterations per rung instead of the shipped 60, applied to every arm
including `base`. Every "total CG" figure is a total over 4 x `$ITERS` design
iterations and is comparable **only within this table** — never against his
60-iteration run. The cap also makes each solve cheaper than his, which biases
the table **against** GenEO engaging: the threshold it must clear is unchanged
while the plain solve it races got shorter. A GenEO win here is conservative; a
GenEO loss here is not proof of one at his depth, and the handoff says so.
