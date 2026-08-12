# §1(b) — THE BASIS SWEEP IS BLOCKED ON THIS HOST. Reported, not dressed up.

`run_nt_triage.sh` asks one question per point: what is `N_t` at this subdomain
tiling? It needs ONE solve, because the basis is built once and `N_t` is a
property of that build.

**Neither of the two points below the shipped tiling completed.**

| tiling | outcome |
| --- | --- |
| `core = 8` (SHIPPED) | `N_t = 1674`, basis 40.26 MB — from his run and reproduced by every arm here |
| `core = 4` | ABANDONED after 25 min. ~7,300 subdomains on his grid; and it is the WRONG DIRECTION anyway — smaller cores mean MORE subdomains and a LARGER `N_t` |
| `core = 16` | ABANDONED after 35 min without completing solve 1 — and RETRIED on a quiet host (load ~14 vs ~108), where it still had not finished a solve |
| `core = 32` | not attempted (16 did not finish) |

★ **THE RETRY IS THE INFORMATIVE PART.** The first attempt could be dismissed as
contention. The second could not: at load ~14, with `core = 8` completing its
entire first solve in about 40 seconds, `core = 16` still did not produce one.
The tiling's BUILD cost is real and it is steep.

**Why, and what cannot be concluded from it.** The host was running four other
agents' TopOpt jobs for the whole window — `levelset_probe` and three
`topopt-cli run` processes out of other worktrees — at load averages of **108–122
on a 10-core box** (`../host_load.txt`). My process held ~1 core of the 6 it
asked for. So the 35 minutes is **not** a measurement of what a 16³ tiling costs:
it is that cost convolved with a ~10× starvation factor, and the two cannot be
separated after the fact.

What can be said, and is worth saying because it is a real hazard for the next
attempt: a coarser tiling makes the one-off LOBPCG **build** more expensive even
as it makes the per-solve **refresh** cheaper, because the local eigenproblems
grow with the cube of the core size (8³ ≈ 1.7k local DOFs, 16³ ≈ 14k). The prior
sweep that found 8³ → 16³ took `N_t` 313 → 47 was run at `40×16×41`
(`2026-08-02-geneo-standing-probe` W4), where the build was 12.4 s. That does not
transfer to 128³ for free, and this attempt is the evidence that it does not.

**The exact experiment the next task should run**, on a quiet machine:

```bash
CORES="8 16 32" sh evidence/2026-08-14-solver-speed-arm-and-diagnose/run_nt_triage.sh
```

One solve per point, and it answers §1(b)'s first half outright: if `N_t` at 16³
or 32³ is small enough that `2·N_t + 500 + 2·tail` drops under the ~4,400 plain
iterations his solves cost, the gate starts engaging and the 21.7× is reachable.
If it is not, GenEO is finished as a rescue on this problem and the answer is
§4(a)'s algebraic coarse space instead. **Neither branch is established here.**
