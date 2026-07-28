# Evidence — MG stagnation Phase 0 (latch re-arm question)

Handoff: `docs/handoffs/2026-07-27-mg-stagnation-phase0.md`.
Harness: `core/tests/harness/mg_rearm_probe.cpp` (copied here for self-containment).

All numbers are from the production entry point `fea_solve_mgcg_matfree` (graded
overload) linked against a Release `libtopopt.a`. Cycle counts / `hier_built`
verdicts / CG counts are deterministic; only `sec` columns are thermal.

| file | command | what it shows |
|---|---|---|
| `scan_out.txt` | `./mg_rearm_probe scan` | M1 — geometric MG on the UNIFORM (iteration-0) field across extents/regimes. Stagnation begins on the uniform field at real extents with a hole. |
| `ladder_128.txt` | `./mg_rearm_probe ladder 128 80 96 0.45 12 1e-4` | M2 — real OC field developed down `{0.68,0.52,0.38,0.26}`, geometric MG at each rung start/end, both regimes. Cycles climb monotonically with development. |
| `ladder_192.txt` | `./mg_rearm_probe ladder 192 112 128 0.4 8 1e-3` | M2/M5 at production extents. NO-HOLE crosses into stagnation by rung 1–2; WITH-HOLE stagnates from the uniform field on. |

Reproduce: see handoff §8. `mg_rearm_probe <mode>`; `ladder` args are
`<ex> <ey> <ez> <occ> <oc_iters_per_rung> <develop_tol>`.

Headline: the leading hypothesis ("iteration-3 haze is the worst moment; developed
structure will let MG carry") is refuted — developing structure makes geometric MG
monotonically WORSE, so re-arming the latch at rung boundaries lands on
progressively harder fields and cannot rescue a stagnating-regime run.
