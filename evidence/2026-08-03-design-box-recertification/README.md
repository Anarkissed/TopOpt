# Evidence — design-box re-certification (2026-08-03)

Handoff: `docs/handoffs/2026-08-03-design-box-recertification.md`

## Reproduce

```
core/build/topopt-cli                     # this branch
zsh evidence/2026-08-03-design-box-recertification/run_evidence.sh <cli> <out-dir>
```

Run it once with a HEAD-built binary and once with this branch's, then:

```
python3 evidence/2026-08-03-design-box-recertification/gate_table.py  <label> <dir> ...
python3 evidence/2026-08-03-design-box-recertification/design_cmp.py  <head>/design.bin <new>/design.bin
```

## Jobs (all on the committed `plate_bore.stl`, 24x16x4 mm)

| job | what it is | HEAD | this branch |
|---|---|---|---|
| `A_nobox_lattice` | no design box + lattice | runs | byte-identical |
| `B_box_nolattice` | design box, no lattice | runs | byte-identical |
| `C_box_keepclear_lattice` | **the maintainer's shape**: design box + 4 keep-clears + declared load + lattice | REFUSED | runs, 4 certified rungs |
| `D_box_selfweight_lattice` | design box + self-weight + lattice — the added-material specimen (55.7% outside the part) | REFUSED | runs |
| `E_box_lattice_variant` | `lattice_variant` on D's `design.bin` | REFUSED | runs, reproduction exact |
| `F_box_analyze_smooth` | `analyze --smooth` on D's variant (AI5) | clipped to the part grid | certifies the whole object |
| `G_nobox_analyze_smooth` | the same with no design box | runs | byte-identical |
| `X_preexisting_selfweight_clearance_crash` | **not this task's**: keep-clear into the add-region + self-weight, no lattice block | throws | throws identically |

## Records

* `gate_tables.txt` — AI4: every rung, verdict + margin, before and after, plus the
  voxel-classification comparison against a 1e-9 negative-control floor.
* `byte_identity.txt` — AI3: stash-rebuild checksums, per artifact.
* `preexisting_selfweight_clearance_crash.txt` — the pre-existing blocker, on both binaries.
* `receipts/` — the certification receipts the design-box runs produced,
  including the `added_material` section AI6 asks for.
