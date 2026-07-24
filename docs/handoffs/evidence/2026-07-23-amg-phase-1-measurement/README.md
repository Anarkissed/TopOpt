# Evidence — AMG Phase 1 (the second measurement)

Raw stdout captures for `docs/handoffs/2026-07-23-amg-phase-1-measurement.md`.
Every table in that handoff can be checked against the exact stdout it came from.

| file | mode | what it proves |
|---|---|---|
| `verify_out.txt` | `./amg_lean_probe verify` | the three NEW element-local kernels (strength graph, `A*T`, Galerkin triple product) agree with an assembled reference built from the production matrix-free applies |
| `correctness_out.txt` | `correctness` | the lean AMG solves the RIGHT system (relative difference vs the library's own matrix-free Jacobi-CG at tol 1e-10) |
| `determinism_out.txt` | `determinism` | B4 — two independent setups + two independent solves, `memcmp` on operators, residual histories and solutions |
| `memory_out.txt` | `memory` | B1 — peak AMG memory against the production matrix-free baseline, stated first |
| `memsweep_out.txt` | `memsweep` | §3d — the strength-threshold sweep with the P₀ / coarse-operator / bookkeeping breakdown that explains the B1 number |
| `nullspace_out.txt` | `nullspace` | §3e — the two levers that could reach B1 at real extents: near-nullspace size (k=6 vs k=3) × coarsening control (default vs TIGHT) |
| `coarsening_out.txt` | `coarsening` | §2 — the coarsening-control sweep on the 131 §2d developed-field fixture |
| `stagnation_out.txt` | `stagnation` | B2/B3 on the 131 R1 fixtures, iteration-0 field |
| `developed_out.txt` | `developed` | B2/B3 on the 131 §2d developed-field fixtures |
| `ultradilute_out.txt` | `ultradilute` | the shared ACTIVE-DOMAIN fixture (handoff 134 §1a/§2) carrying a real OC-developed field |

Reproduce (the library must be built Release first):

```bash
cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release
cmake --build core/build --target topopt -j8
c++ -std=c++17 -O2 -I core/include -I core/src/fea \
    core/tests/harness/amg_lean_probe.cpp core/build/libtopopt.a -o amg_lean_probe
./amg_lean_probe <mode>
```

Run the modes SEQUENTIALLY, never concurrently (thermal protocol, handoff 113).

## Provenance notes

* `coarsening_out.txt`'s printed **header** describes an earlier three-clause
  draft of the admission rule; it predates the `max_nnz_per_row` clause and the
  bottom-level exemption. The committed `amg_lean.hpp:admit_level` is the rule
  quoted in the handoff §1d, and it is what produced every **number** in that
  capture — the per-row `max_nnz_per_row` values are in the row labels, and the
  rejection NOTEs name the clause that fired. The source's header text has since
  been corrected; the capture was not re-run because only wall-clock would change.
* `memsweep_out.txt` sweeps θ ∈ {0.02, 0.04, 0.08}. θ ≥ 0.16 is measured on the
  `48³` lattice in `coarsening_out.txt`, where it degenerates (a rejected level,
  a 84 408-row smoothed bottom and a 75 s solve); it was not repeated at real
  extents because that cost dominates the sweep without adding information.
* Wall-clock in every capture carries handoff 113's ±30 % band. Cycle counts,
  nnz, coarsening ratios, memory bytes and residual histories are deterministic.
