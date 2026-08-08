# S1(a) — why a cold certification solve lands in a different ninth figure

**The answer is not "cold vs warm design". It is that `analyze_fixed_design` is
not a pure function of its arguments.** Two calls with byte-identical inputs
return different margins, because the SOLVER carries state between calls and the
two call sites are deliberately given different solver state.

Everything below is measured, not argued.

---

## 1 · The measurement that settles it

`core/src/simp/analyze.cpp` was instrumented (patch: `s1a_cert_input_probe.patch`)
to dump, at every `analyze_fixed_design` entry, an FNV-1a hash of the grid tags,
the density field, the BC array and the load array, plus the grid dims/spacing/
origin, the material and SIMP params, the build direction, `cg_tolerance`,
`cg_max_iterations`, the solver kind, `margin_stop`, the knockdown spec,
`load_path_ok`, `part_solid`, `printed_iso` and whether a lattice posture was
supplied — and, on exit, the CG iteration count, the final relative residual, an
FNV hash of the whole displacement vector and the resulting margins.

Fixture: the maintainer's own job document at resolution 40 (`job.json` from
worker job `ca62f91cba4b422d`, `resolution` lowered so the loop is 60 s instead of
64 minutes). Full output: `s1a_probe_output.txt`. Rung 0.68, the first two solid
(null-posture) calls of the run:

```
CERTPROBE grid=40x10x37 spacing=5.4568937684299561 origin=-18.275750737198241,-48.909974716000001,0
          tags=35a935586e3286c4 density=8783339658f85963 nbc=2106 bcs=ef388c6c57a7c696
          nload=995 loads=5860948804eb27f2 lsum=-33.361701965332394 labs=33.361701965332394
          E=3500 nu=0.33000000000000002 p=3 bdir=0,0,1 tol=1e-08 maxit=0 solver=2
          mstop=1.5 kd=0.20706279240848655,0,35,2.2200000000000002 lp=1 psolid=3557
          iso=0.5 lat=0
CERTPROBE-STATE recycling=1 mglatched=1
CERTPROBE-OUT  cgiter=509  cgres=9.3133345767974295e-09 cgconv=1 u=97991b42b0411509
               maxvm=0.025281198682520222 worst=2175.5297559536912

CERTPROBE grid=40x10x37 ... tags=35a935586e3286c4 density=8783339658f85963
          nbc=2106 bcs=ef388c6c57a7c696 nload=995 loads=5860948804eb27f2 ... (IDENTICAL)
CERTPROBE-STATE recycling=0 mglatched=1
CERTPROBE-OUT  cgiter=1062 cgres=9.3587170018616862e-09 cgconv=1 u=2895e283c1ee1767
               maxvm=0.025281198684636505 worst=2175.529755771578
```

**Every input hash is equal. `recycling` is not.** 509 iterations against 1062,
two different displacement fields, and margins that differ at the ninth
significant figure. Same on all four rungs (rung 0.52: 415 vs 1021; rung 0.38:
359 vs 1094).

---

## 2 · The mechanism, with file and line

| # | fact | file:line |
|---|---|---|
| 1 | The Krylov recycling subspace is a **thread-local carried between solves** | `core/src/fea/recycle.cpp:83` (`thread_local RcSpace g_space`), `:84` (`g_solve_counter`) |
| 2 | It is **production-ARMED** | `core/src/simp/production.cpp:672` (`fea_set_krylov_recycle_dim(kProductionRecycleDim)`) |
| 3 | …and deliberately **NOT reset per rung** | `core/src/simp/production.cpp:674` (`opts.krylov_recycle_reset_per_rung = false`) |
| 4 | It is applied on the **matrix-free Jacobi-CG** path | `core/src/fea/matfree.cpp:945` (`RecycleSession recycle(n, m.invdiag.data(), …)`) |
| 5 | …and **NOT on the multigrid** path, because production says so | `core/src/simp/production.cpp:673` (`fea_set_krylov_recycle_wrap_multigrid(false)`); the gate is `core/src/fea/multigrid.cpp:1208-1211` |
| 6 | The **ladder's per-rung certification** — the solve whose margin is RECORDED — runs with all of that armed | `core/src/simp/minimize_plastic.cpp:1806` (`FixedDesignAnalysis fda = analyze_fixed_design(...)`) |
| 7 | Every **re-certification** runs with recycling and GenEO switched OFF | `core/src/cli/run_job.cpp:2517` (`class ScopedLadderSolverIsolation`), constructed as the first statement of `lattice_one_variant` at `run_job.cpp:2547` |
| 8 | …and that isolation **covers `lattice_variant_job` on purpose** | `core/src/cli/run_job.cpp:2515-2516` — *"Applied inside THIS function rather than at the callback so the re-lattice entry point (lattice_variant_job) gets it too — the two must not diverge (bar Z6)"* |
| 9 | Why the isolation exists: without it, rung k+1's optimize started from a subspace harvested or dropped by rung k's LATTICE solves | `core/src/cli/run_job.cpp:2477-2513` (task `2026-08-04-subfloor-lattice-unloaded-regions`, §7) |
| 10 | The comparison that then refuses | `core/src/cli/run_job.cpp:5463-5465` (was `== `), and the same `==` in the run's own receipt at `run_job.cpp:1391` |

So the recorded margin and every reproduction of it are computed **by two
different Krylov paths on the same operator, by design**. Both stop at the same
relative residual (`options.simp.cg_tolerance` = 1e-8, minimize_plastic's
`kCertTol`, asserted at `minimize_plastic.cpp:1803`), so they land at two
different points inside the same residual ball.

**This is not a bug to fix.** Item 9 is a defect that was found and closed by
measurement; re-arming the accelerators for the re-certification would make rung
k+1's design depend on rung k's lattice configuration again. The two solves are
supposed to be different. What was wrong is the comparison.

---

## 3 · Why it only shows on HIS part — the falsifier

Item 5 predicts that a part whose grid COARSENS never engages the recycler at all,
and so reproduces bit-for-bit. Measured on three runs, reading `cg_multigrid`,
`hier_built` and `recycle_dim` straight out of each run's `iterations.csv`:

| run | solves | multigrid carried | hierarchy built | recycler engaged | `solid_reconstruction_exact` |
|---|---|---|---|---|---|
| `plate_bore.stl` res 48 (repo fixture) | 240 | **240 / 240** | 240 / 240 | **0 / 240** | **true** on all 4 rungs |
| `M2_verticalStand.step` res 40 | 243 | 4 / 243 | 9 / 243 | **238 / 243** | false |
| **his run**, `M2_verticalStand.step` res 128 | 445 | **0 / 445** | 3 / 445 | **444 / 445** | **false on all 4 rungs** |

His part is a thin vertical stand; its grid does not coarsen, so every solve falls
back to matrix-free Jacobi-CG, which is exactly the path the recycler wraps. The
repo's own lattice fixtures coarsen, which is why the existing suite never caught
this.

---

## 4 · The run has been failing its own proof, silently, all along

The optimize run's lattice pass re-certifies each variant with a null posture as
"a live proof the reconstruction is faithful" and writes the answer into the
per-variant receipt. His four receipts, on the Mac Mini right now:

| rung | `solid_margin_worst_case` | `solid_margin_reproduced` | `solid_reconstruction_exact` |
|---|---|---|---|
| 0.68 | 2169.617171 | 2169.617163 | **false** |
| 0.52 | 2259.952815 | 2259.952813 | **false** |
| 0.38 | 2193.876833 | 2193.876835 | **false** |
| 0.26 | 2008.278339 | 2008.278337 | **false** |

Nothing reads that key, so nothing said so. The standalone `lattice-variant` path
lands on the SAME numbers as the in-run re-certification (§5), which is the final
confirmation that the two are the same posture and the recorded value is the odd
one out.

---

## 5 · Reproduced in process, as a test

`core/tests/unit/test_margin_reproduction.cpp` (ctest name `margin_reproduction`)
builds a 23×7×11 graded beam, forces the same regime (`fea_set_mg_parity_pad_mode(0)`
so the hierarchy is rejected → matrix-free Jacobi-CG), runs three warm-up solves
with recycling armed, and then certifies the SAME design twice — once armed, once
disarmed:

```
B: recorded 18.634321588184484  reproduced 18.634321714356346
   relative delta 6.77e-09 (band 1e-06)
B3: load off by 1e-4 -> relative delta 0.0001
```

25 checks, 0 failures. It asserts the divergence exists (so the band cannot
silently become unnecessary), that the band admits it, and that the same band
still refuses a load case off by one part in 10⁴.
