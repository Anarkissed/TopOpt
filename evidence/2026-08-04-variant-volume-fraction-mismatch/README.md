# Evidence — 2026-08-04-variant-volume-fraction-mismatch

Handoff: `docs/handoffs/2026-08-04-variant-volume-fraction-mismatch.md`

Everything here is read from the maintainer's own `~/.topopt-worker` directories
or produced by running his own job documents through this branch's `topopt-cli`.

## Failure A — the job the app sent

| file | what it is |
|---|---|
| `A1_failing_job_as_the_app_sent_it.json` | worker job `0cc8e495de084e5d`'s `job.json`, verbatim. `"variant": {"design": "design.bin", "volume_fraction": 1.1}`, `"minimize_plastic": false` |
| `A1_failing_job_worker.log` | the 48 ms death: `topopt-cli: job.json: "variant.volume_fraction" must be in (0, 1]`, `exit rc=1` |

The design container it was sent with (`~/.topopt-worker/0cc8e495de084e5d/design.bin`)
holds three blocks — requested `1.55 / 1.25 / 1.10`, achieved `1.5376855112224839 /
1.2368710980536173 / 1.0866043075327818`, fingerprints `14561760059330257218 /
9817955135575584118 / 2898949975693851963`. **`1.1` is that variant's own rung**;
it is not stale and not foreign. The defect was that a ladder POSITION was
travelling in a job key core validates as a FRACTION.

## Failure B — the zero-density lattice

| file | what it is |
|---|---|
| `B1_run_info_zero_density_signature.json` | `run_info.json` of worker run `4dabe3b8512d4d59` — the record behind the maintainer's panel. `latticed_cells: 132`, `triangles: 134116`, `strut_radius_min_mm: 0`, `strut_radius_max_mm: 0.6452567419`, `rho_min: 0`, `rho_max: 0.3709106553`, `strut_margin_in_plane: 530.3930798`, `strut_margin_interlayer: 317.0035085` |
| `B_extrusion_width_sweep.tsv` | the graded law re-run over that same design across declared extrusion widths × cell sizes (forecast only, so no FEA) |
| `B5_uniform_forecast_after.json` | the pre-flight forecast of the WallMount uniform job **after** the fix: `would_lattice_voxels: 49909 / 49909`. Before the fix the same job forecast **0** while the real run wrote 17.6 MB of struts |

Reading `B_extrusion_width_sweep.tsv`: at the declared **0.42 mm** the
printability floor is 4.603 mm, so a 3.0 mm cell is clamped up to it and buys
nothing (rung 0: 1295 voxels at both 4.6 and 3.0). At **0.30 mm** the floor drops
to 3.288 mm, the 3.0 mm cell becomes legal, and the same design lattices **1581**
voxels — +22 %. Rung 3 (the 0.26 rung the app re-latticed) lattices **0** at every
combination probed: its widest member is 13.64 mm and a 3.0 mm cell needs 15 mm.
That rung is the one whose `0` poisoned the run-level minimum.

The same sweep on the WallMount growth run (`efa7cfd3b4e344c6`, rung 1.55, 70 788
region voxels, no include regions) is quoted in the handoff §2.4: 0.42 mm ⇒ 0
voxels at any cell; 0.30 mm + 3.0 mm cell ⇒ 6 750 (9.5 %); 0.25 mm ⇒ 12 020
(17.0 %).

## Bar L1 — the latticed part

| file | what it is |
|---|---|
| `L1_wallmount_lattice_provenance.json` | `lattice_variant.json` — selection by fingerprint `2898949975693851963`, `achieved_volume_fraction 1.086604308`, margin reproduction **exact: true** |
| `L1_wallmount_lattice_receipt.json` | the full lattice receipt: 371 cells, 2 791 clipped struts, 9 851 latticed voxels, rho 0.2117, `lattice_accepted: true` |
| `wallmount_xsec.png` | three orthogonal sections of `variant_110_lattice.stl` (17 652 084 bytes, 353 040 triangles) |
| `wallmount_xsec_zoom.png` | the latticed wall at Z = 10.5 mm and X = 96.0 mm — individual octet cells and the diagrid skin are resolved |

**Strut radius 0.80 mm, diameter 1.60 mm.** The FAIL condition was 0.00.

Caveat carried in the handoff §5 and on the receipt itself:
`strut_strength.cells_per_member_min = 0.405` against a homogenization floor of 5.
The uniform path applies no cells-per-member floor, which is why it succeeds where
the graded law refuses; the gate verdict does not read the strut numbers
(`strut_gated: false`) and the report-only interlayer strut margin is 1.074.
