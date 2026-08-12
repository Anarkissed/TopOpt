# evidence — 2026-08-14 face regions

| file | what it is |
|---|---|
| `r2_r3_his_part.txt` | `face_region_probe` on **M2_verticalStand.step @ 128** — his own part. §1 the part's face/area/voxel range; §2 what the blend heuristic matched and what `kind == "other"` misses and over-catches; §3 the tap count, three ways; **§4 the R2 bar** — layer 1 and the CAD error before and after a union + a 10×5 grid split; §5 the R6 bar — a simulated CAD edit and the drift it reports. |
| `r1_r2_byte_identity.sh` / `.txt` | **R1** the demo job with NO regions, run by a topopt-cli built from base and one from this branch, every artifact compared by sha256. **R2** the same job expressed with `face_ids` and with an equivalent identity `region`, both on the branch cli — byte-identical means every derived measure, CAD error included, is identical trivially. **R5** a sub-region under the floor, refused. |
| `r4_consumers.md` | **R4** — every consumer of a face id, file and line, what it read before and what it reads now. 21 sites, and the one gap. |
| `r7_r8_census.txt` | **R7** every on-screen string added, longest first. **R8** the assertion census, base vs branch, by message-bearing construct. |

Reproduce:

```
cmake --build build --target face_region_probe
./build/face_region_probe evidence/2026-08-12-lattice-page-redesign/M2_verticalStand.step 128

DEMO_DIR=$PWD/core/tests/fixtures/demo \
  ./evidence/2026-08-14-face-regions/r1_r2_byte_identity.sh <base-cli> <branch-cli> <out-dir>
```
