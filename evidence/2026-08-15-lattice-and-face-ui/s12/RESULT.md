# §12 — "LATTICE THIS": VERIFIED ON HIS PART, AND IT IS A §12(e) STOP

★ **THE GATE SAID VERIFY BEFORE BUILDING. I VERIFIED, AND THE ANSWER IS NO —
BUT THE NUMBER THAT MOTIVATES THE BUTTON IS REAL AND LARGE.**

Binary: `build/topopt-cli`, **Release** (`CMAKE_BUILD_TYPE:STRING=Release`),
rebuilt at base `247a6bbc` via target `topopt_cli` (never the hyphen — that is a
silent no-op).
Part: `M2_verticalStand.step`, resolution 128, his own captured job
(`evidence/2026-08-07-lattice-variants-on-screen/run_his/job.json`) with **only**
`"mode"` changed to `"analyze"`.

---

## §12(c) — DOES `analyze_job` ALREADY GRADE, CERTIFY AND EXPORT? — MEASURED

★ **First, a correction to the brief's own line numbers.** §12(b) states
"`grade_lattice` LIVES ONLY INSIDE `analyze_job` (run_job.cpp 866-1313)" and
"`run_job` itself (1313+) contains ZERO grading references". **Neither holds on
this tree.** The real layout at `247a6bbc`:

| function | lines | grades? |
|---|---|---|
| `analyze_job` | `run_job.cpp:5339-5989` | **yes** — `grade_lattice` at **`:5744`** |
| `lattice_variant_job` | `run_job.cpp:5990-7008` | yes |
| `run_job` | `run_job.cpp:7009-end` | **yes** — the ladder's call at **`:3444`** plus the forecast's at `:5021/:5061/:5130/:5175` |

So the premise "grading lives only in analyze" is false; but the operative
question — *does an analyze on a solid part grade and certify* — is **YES**, and
it ran.

### IT RUNS, END TO END, WITH NO TOPOLOGY OPTIMISATION

```
analyze: M2_verticalStand.step as solid part (fixed design, ONE analysis solve, no optimization)
  peak stress: 0.02545 MPa   worst-case margin: 2162 (required 1.5)
  load case: declared external load
  verdict: ACCEPTED
  voxel mass: 682 g
```

### §12(f) — THE NUMBER THAT JUSTIFIES THE BUTTON

`out_analyze/run_info.json` → `grading`:

| | **lattice-only (this run)** | his TO+lattice run |
|---|---|---|
| latticed voxels | **107,823** | 13,034 |
| printed/candidate voxels | 110,904 | — |
| **lattice share** | **97.2 %** | **12 %** |
| solid fallback voxels | 3,081 | — |
| cells per member (min) | 5.1158 (floor 5) | — |
| any strut below the nozzle | **false** | — |
| region ungradeable | **false** | — |

★ **8.27× more latticed voxels, and the share goes 12 % → 97.2 %.**

The denominator checks out independently: 681.9546 g ÷ 1.24 g cm⁻³ ÷ (1.70528 mm)³
= **110,899 voxels** against the receipt's `region_voxels` **110,904** — i.e.
`region_voxels` IS the whole printed solid, which is what a `nullptr` candidate
set means (see the gap below).

★ **This is exactly the failure §12 named, inverted.** The TO+lattice receipts on
this tree show `include_void_by_optimizer` = **99,469 of 99,469** include-region
void voxels (`evidence/2026-08-13-in-region-drainability/lattice/variant_080_lattice.report.json:28`)
— every empty include voxel was empty *because the optimizer removed it*. With no
TO there is nothing to remove, and the lattice fills.

### §12(g) — MASS

| | mass |
|---|---|
| imported solid, as drawn, res 128 (this run) | **681.95 g** |
| his TO'd design, solid, rung 0.68 | 543.7 g |
| his TO'd design, latticed | 507 g |

★ **A lattice-only run starts from a HEAVIER part** (681.95 g vs 543.7 g): TO
removed 138 g before the lattice ever ran. What lattice-only buys is not a lighter
start, it is **8.27× more of the part actually latticed**. This run does not
report a latticed mass — see gap 2.

---

## ★ THE TWO GAPS — WHY THIS IS §12(e) AND NOT §12(d)

§12 defined the button as: *"Take the imported solid, apply the declared regions,
grade, certify, export."* Three of those five verbs work. **Two do not.**

### GAP 1 — `analyze` IGNORES `lattice.regions`. MEASURED, not read.

I ran the same job twice, the second declaring an identity face region on his
protected face 16 and a region-backed lattice **include** on it at the protection's
own 5 mm depth:

```json
"loads": { "face_regions": [ { "id": 100, "name": "protected wall", "add": [16] } ] },
"lattice": { "regions": [ { "role": "include", "kind": "region",
                            "region_id": 100, "geometry": { "depth_mm": 5 } } ] }
```

| | no regions | 1 include region |
|---|---|---|
| `region_voxels` | 110,904 | 110,904 |
| `latticed_voxels` | 107,823 | 107,823 |
| `solid_fallback_voxels` | 3,081 | 3,081 |

★ **The whole `grading` block is BYTE-IDENTICAL** (`a == b` in Python). Declaring
an include region on one 10,554-voxel face changed **nothing**.

**Cause, with file and line:** `run_job.cpp:5744` —

```cpp
const GradedField gf =
    grade_lattice(design_grid, density, a.von_mises_field, nullptr, gp);
                                                           ^^^^^^^
```

`nullptr` is the **candidate region set**. The run path passes `&cand`
(`run_job.cpp:3444`); analyze passes nothing, and its own comment at
`run_job.cpp:5726` says so: *"`nullptr` region below means the candidate set is
the whole printed design"*. The declared regions are consulted **only** in `Fit`
cell mode, and only to build `fit_field` (`run_job.cpp:5731-5741`) — never to
bound what gets latticed.

So a "Lattice This" button wired to `analyze` today would **lattice the entire
part and silently discard every region the user declared** — which is precisely
the "control that silently does nothing" defect §8(e) forbids, one level up.

### GAP 2 — `analyze` DOES NOT EXPORT A LATTICE.

`analyze_job` (`run_job.cpp:5339-5989`) contains **no** `generate_lattice` /
`generate_lattice_multilevel` call, **no** `lat.emit_stl` write arm, and writes
**no** `lattice_export_*` field. Those exist only at `run_job.cpp:1730/1760`
(the generator), `:1821` (the STL arm) and `:8522+` (the receipt) — reached from
`run_job` and `lattice_variant_job`. Confirmed on the artifacts: `out_analyze/`
holds `analysis.json`, `analysis_report.json`, `build_orientation.json`,
`fields.bin`, `run_info.json` — **and no `.stl`**.

---

## ★ THE VERDICT

**§12(e) — REPORT AND STOP. No button is added in this task, and no new pipeline
is built.**

What is missing, exactly, for a future task:

1. **Give analyze the candidate set.** Resolve `lattice_role_regions_from_job` in
   *every* cell mode (not just `Fit`) and pass `&cand` at `run_job.cpp:5744`
   instead of `nullptr`. This is the whole of "apply the declared regions".
2. **Give analyze the export arm.** Factor the generator + `emit_stl` block that
   `run_job` runs at `:1730-1821` so the analyze tail can call it, and populate
   the `lattice_export_*` receipt fields at `:8522+`.

Both are CORE changes in `run_job.cpp`, and R15 keeps core untouched here.

★ **What the measurement DOES settle, and it is worth keeping:** on his own part,
with no topology optimisation, the grading law lattices **97.2 %** of the printed
solid at **5.12 cells per member** with **no strut below his 0.45 mm nozzle** and
a **certified** margin. The lattice-only idea is sound and the prize is 8.27×.
The plumbing to aim it at declared regions, and to write the file out, is what
does not exist.

---

## REPRODUCE

```bash
cmake --build build --target topopt_cli -j8
./build/topopt-cli analyze evidence/2026-08-15-lattice-and-face-ui/s12/job/job_analyze.json \
    --out evidence/2026-08-15-lattice-and-face-ui/s12/out_analyze \
    --materials core/src/materials/materials.json
./build/topopt-cli analyze evidence/2026-08-15-lattice-and-face-ui/s12/job/job_analyze_regions.json \
    --out evidence/2026-08-15-lattice-and-face-ui/s12/out_regions \
    --materials core/src/materials/materials.json
```
