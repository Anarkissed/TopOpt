# evidence — 2026-08-04-protect-freeze-vs-solidity

Handoff: `docs/handoffs/2026-08-04-protect-freeze-vs-solidity.md`

| file | what it is |
|---|---|
| `M2_verticalStand.step` | THE MAINTAINER'S OWN PART. Not a fixture (fixtures are out of scope for this task) — it lives here so bar 2 is reproducible. Same file PR 293 captured. |
| `job_maintainer.json` | HIS job document, unmodified except the `model` path. Graded swept lattice, 8 include + 1 exclude regions, face protection on face 16 at 5 mm, resolution 128. |
| `maintainer_base.log` | his job on base (`main`) |
| `maintainer_branch_before_roles_fix.log` | his job on this branch BEFORE the §3 cell-predicate fix. Kept because it PROVES the fix did not touch his job: `strut_and_solid` is 97 / 39 both before and after, because his run is GRADED and the graded path already derived its cell set from the mask. The 48 / 426 divergence the fix removed was on the UNIFORM roles path (the l-bracket gate), not here. |
| `maintainer_final.log` | his job on the branch, captured just before the receipt-key rename |
| `maintainer_ship.log` | his job on the SHIPPED binary — the run bar 2's table is generated from |
| `bar2_maintainer_case.py` / `.txt` | bar 2 + the maintainer's half of bar 5: solid AND composite verdicts per rung, base vs branch, plus the frozen split base could not report |
| `bar1_byte_identity.sh` / `.txt` | **bar 1**, the load-bearing one: face protection + NO lattice, base vs branch, sha256 per artifact |
| `bar5_gate_table.sh` / `.txt` | **bar 5**: four configurations × every rung, solid + composite verdicts, voxel-classification flips, and the 1e-9 negative control |
| `core_gate.txt` | `test_protect_freeze_vs_solidity` — 26 checks |
| `ctest_run1.txt` | full ctest, FIRST run — 102/103, the one failure being a receipt-key collision I introduced (see the handoff) |
| `ctest_final.txt` | full ctest after the fix — **103/103** |
| `app_tests.txt` | app suite: 1152 executed, 8 failures across 3 lib3mf-absent 3MF cases, with the reason quoted from the test itself |
| `item8_subfloor_floor.txt` | **item 8** measured: sub-floor lattice on an unloaded region, and the control showing the gate is blind to cells-per-member |
| `item9_frozen_buttress.txt` | **item 9** measured: does a design box let the optimizer buttress a FROZEN wall (yes), with the unfrozen control |

Reproduce:

    cmake --build build --target topopt_cli test_protect_freeze_vs_solidity \
                                subfloor_lattice_probe frozen_buttress_probe
    ./build/test_protect_freeze_vs_solidity
    ./build/subfloor_lattice_probe
    ./build/frozen_buttress_probe
    DEMO_DIR=core/tests/fixtures/demo evidence/2026-08-04-protect-freeze-vs-solidity/bar1_byte_identity.sh <base-cli> build/topopt-cli /tmp/bar1
    DEMO_DIR=core/tests/fixtures/demo evidence/2026-08-04-protect-freeze-vs-solidity/bar5_gate_table.sh   <base-cli> build/topopt-cli /tmp/bar5
