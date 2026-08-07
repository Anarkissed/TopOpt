# evidence — 2026-08-07-lattice-variants-on-screen

Handoff: `docs/handoffs/2026-08-07-lattice-variants-on-screen.md`

Everything here comes from the maintainer's own run: worker job
`ca62f91cba4b422d`, `M2_verticalStand.step` at 128³, four rungs, all accepted,
graded octet lattice (cell 2 mm, density band 0.265125–0.899880).

## Captured from that run — `run_his/`

| file | what it is | verbatim? |
|---|---|---|
| `job.json` | the job document the worker ran | yes |
| `report.json` | the run's scalar report (4 accepted, 0 rejected) | yes |
| `run_info.json` | the run record | yes |
| `variant_0{26,38,52,68}_lattice.report.json` | the four per-variant lattice certification receipts — the source of every latticed mass | yes |
| `checkpoint_lines.txt` | the eight `VARIANT` / `LATTICE` lines the CLI printed, lifted from `worker.log` with only the log timestamp/`stdout` prefix stripped | yes |
| `fields.bin` | the per-rung scalars (grid, requested vf, MASS, support) | **derived** — see below |
| `mesh_sizes.txt` | the four latticed STL sizes in bytes | yes (the files themselves are 5.17 GB and are not here) |

`fields.bin` is his real 31 MB container with the three per-voxel overlay arrays
(von Mises, stress tensor, displacement) replaced by zero-length, produced by
`trim_fields_bin.py` — 31 070 976 bytes → 256. The header, the grid, and every
per-rung scalar including the mass are his. A test using it exercises the MASS
path and not the stress/flex overlays, which have their own coverage. Re-derive
with:

```
./trim_fields_bin.py <job>/out/fields.bin run_his/fields.bin
```

## Measurements and bar output

| file | bar | how to reproduce |
|---|---|---|
| `R1_end_to_end.txt` | R1 | `TOPOPT_LATTICE_HIS_RUN=<job>/out swift test -c release --package-path app/TopOptKit --filter LatticeVariantsHisRunEvidence` |
| `R2_red.txt` | R2 | the same test with `RemoteRunner.handleEvent`'s `case "log"` removed |
| `R2_green.txt` | R2 | `swift test --package-path app/TopOptKit --filter LatticeVariantsOnScreenTests` |
| `R3_transfer_profile.txt` | R3 | `TOPOPT_LATTICE_TRANSFER_PROFILE=1 TOPOPT_LATTICE_STL=<job>/out/variant_052_lattice.stl swift test -c release --package-path app/TopOptKit --filter LatticeMeshTransferProfileTests` |
| `R4_assertion_census.txt` | R4 | `./assertion_census.sh` |
| `S2c_recommender_inversion.txt` | S2(c) | arithmetic over the receipts + `fields.bin` above |

Machine for every measured number: M2 Pro, 16 GB (`hw.memsize` 17 179 869 184),
macOS 26, release build, loopback HTTP. The iPad figures in the handoff's §4 are
arithmetic against 8 GB of physical RAM on the attached iPad13,8 — clearly
labelled as such, and NOT a device measurement.

## Not reproduced here

The four latticed meshes (740 MB / 1.06 GB / 1.42 GB / 1.95 GB). `R1` and `R3`
read them from the worker's own job directory via the env gates above; every
other test replays their SIZES only.
