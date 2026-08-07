# S3 — the `out/` cleanup, scoped and NOT implemented

**Nothing in this branch deletes anything.** This is the scope his condition asks
for, written after the gate test he made the precondition.

---

## (a) The gate test, named

```
LatticesAreInTheAppGateTests
  .testEveryLatticeAnOptimizeRunProducedIsListedWeighedAndExportable
```

`app/TopOptKit/Tests/TopOptFlowsTests/LatticesAreInTheAppGateTests.swift`.

It drives HIS run (worker job `ca62f91cba4b422d`, four rungs, four lattices)
through the app's real `RemoteRun` against a real HTTP socket, and for **every one
of the four rungs** asserts:

| | what it proves |
|---|---|
| LISTED | the lattice is its own selectable tab, tied to the rung that produced it |
| WEIGHED | it carries `lattice_mass_grams` from that rung's own certification receipt — 215.16 / 239.93 / 244.78 / 246.38 g — and asserts that is **not** the solid's mass |
| EXPORTABLE | Export writes **that rung's** latticed file to disk, byte for byte, under a name that cannot collide with the solid's or with another rung's |

With a **positive control**: the four latticed files the fixture serves are
pairwise different bytes at the same length, so "the export matched its source"
cannot pass by exporting the wrong rung's file.

A second test, `testTheLatticedExportCannotSilentlyBecomeTheSolids`, pins that the
in-memory export path returns nothing for a latticed selection and the viewer
draws nothing rather than the solid.

**What the gate does NOT claim:** that a latticed mesh can be *displayed*. PR 311
measured that none of his four fit on his iPad, and export deliberately does not
depend on display. "Reachable" here means listed, weighed and exportable — which
is what a cleanup's safety actually rests on.

---

## (b) The cleanup, scoped

### What is on that disk today

`/Users/nadim/.topopt-worker`, 88 job directories, **9.7 GB**:

| | bytes | share |
|---|---|---|
| `*_lattice.stl` — 26 files across 9 jobs | **8.99 GB** | **93 %** |
| everything else — `design.bin`, `fields.bin`, `report.json`, the receipts, the solid `variant_*.stl`, `iterations.csv`, `run_info.json`, the job documents and the models | 1.3 GB | 7 % |

One job, his, is 5.17 GB of that.

### What a cleanup would DELETE

Only `variant_*_lattice.stl`, and only for jobs where the recipe is complete —
`job.json` + the model file + `out/design.bin` all present.

Measured, on that disk right now:

| | bytes |
|---|---|
| latticed meshes, total | 8.99 GB |
| **regenerable** (recipe complete) | **8.75 GB — 97 %** |
| not regenerable (no `design.bin`; pre-dates the container) | 0.24 GB |

The four jobs holding a `design.bin`-less lattice are `0ca24fe5267443f9`,
`ca366a5785024774` and `95f4130119414636` — 0.24 GB between them, and they are
also the *small* ones. A cleanup that skips them costs almost nothing.

### What it would KEEP, always

`design.bin` (the whole point), `job.json`, the model, `report.json`,
`fields.bin`, the per-variant `variant_XXX_lattice.report.json` receipts, the
solid `variant_XXX.stl`, `loadcase.json`, `run_info.json`, `iterations.csv`,
`build_orientation.json`, `worker.log`.

The receipts especially: the app reads the *mass, the margin and the verdict* off
the receipt, never off the mesh (`LatticeVariantAlternative.receiptFacts`). Delete
the mesh and the variant list, its masses, its verdicts and — after S2 — the
recommendation are all unchanged. Only Export and (where the device can hold it)
the 3-D view need the file.

### ★ WHAT BECOMES UNRECOVERABLE

**Measured, not assumed.** Rung 0.26 of his run was regenerated from
`{job.json, design.bin}` alone and compared with the eager file the run wrote,
triangle by triangle (`S1d_bytes_vs_eager.txt`):

```
triangles: 14807216 vs 14807216
identical triangles : 12540748 (84.6935 %)
differing triangles : 2266468 (15.3065 %)
worst vertex coordinate difference : 1.52588e-05 mm (8.95e-06 of a voxel)
worst normal component difference  : 2.00249e-13
```

So the honest statement is: **the regenerated file is not byte-identical, and the
object it describes is the same to within 15 nanometres.** Same triangle count,
85 % of triangles bit-identical, and the worst vertex anywhere is 1/112,000 of a
voxel out — four orders of magnitude below the 0.42 mm line width and three below
a 0.1 mm layer. The difference traces to the same root cause as §S1: the shell and
the graded struts are built from the reproduction solve's fields, which differ from
the run's at the ninth significant figure.

What that costs, concretely:

* **Nothing physical.** No printer, slicer or measurement can resolve 1.5e-5 mm.
* **Byte provenance.** A deleted file cannot be re-produced bit-for-bit, so a
  checksum recorded against the original can never be re-satisfied. If anything
  downstream ever pins a latticed STL by hash, deletion breaks it. Nothing does
  today (PR 312 enumerated every consumer: the only production reader of a
  latticed `.stl` in the whole repo is the app's re-lattice fetch).
* **The rungs with no `design.bin`.** 0.24 GB. Those are genuinely unrecoverable
  and must be excluded by the rule above, not by hoping.
* **Time.** See below — this is the real cost, and it is not small.

### ★ WHICH WORLD THE RECOMMENDATION ASSUMES

**It assumes S1 landed — and S1 is in this branch.** Before it, deletion was
destruction: `topopt-cli lattice-variant` refused all four of his rungs, so a
deleted mesh could not be remade by the CLI, by the iPad, or by anything else.
That is no longer true; all four now materialise (`S1cd_materialise.txt`).

**But regeneration is not 0.63 s, and the task's premise on that number needs
correcting.** The 0.63 s PR 312 measured was `gen_seconds` on *its own* small
reproduction run (2,140 cells). His run's own `run_info.json` records
`gen_seconds: 21.33` for all four rungs — the generator alone. And materialising a
rung on demand costs far more than the generator, because the re-lattice entry
point re-runs the FEA:

| rung | mesh | wall, end to end | of which the generator (from his `gen_seconds` rate) |
|---|---|---|---|
| 0.68 | 1.95 GB | **276 s** | ~8 s |
| 0.52 | 1.42 GB | **351 s** | ~6 s |
| 0.38 | 1.06 GB | **354 s** | ~4 s |
| 0.26 | 740 MB | **390 s** | ~3 s |

`lattice_variant.json` reports `analysis_solves: 4` — the reproduction proof, the
lattice pipeline's own null-posture proof, the composite certification, and the
band-clamp counterfactual. **Four 128³ certification solves at ~90 s each is where
the six minutes go.** The geometry really is ~1 % of it, exactly as PR 312 said;
it is the certification around it that is not.

So the trade a cleanup buys is: **8.75 GB of disk against ~6 minutes of Mac time
per rung, the first time anyone wants that file again.** That is a good trade for
a file nobody has opened, and a bad one for a file someone is about to print. It
argues for a **retention policy, not a purge**:

1. Delete `variant_*_lattice.stl` only where `job.json`, the model and
   `out/design.bin` are all present. (8.75 GB of the 8.99 GB.)
2. Only for jobs older than N days AND not the most recent K jobs.
3. Write a small `out/lattice_meshes_reclaimed.json` naming each deleted file, its
   byte count, its SHA-256 and the exact `topopt-cli lattice-variant` command that
   rebuilds it — so "it was here and here is how to get it back" is a fact on the
   disk, not folklore.
4. Never delete a receipt, a `design.bin`, a `fields.bin` or a solid mesh.
5. The app's Export path should learn to *materialise on demand* when the worker
   answers 404 for a reclaimed mesh. Until it does, a reclaimed mesh means Export
   fails on that variant — which is the one behaviour change a user would notice,
   and the reason this is scoped rather than shipped.

Item 5 is the real remaining work, and it is bigger than the deletion itself.

---

## (c) His 5.17 GB, and how to remove it safely by hand today

**It is still there.** `/Users/nadim/.topopt-worker/ca62f91cba4b422d/out`, four
files, 5,174,159,336 bytes:

```
variant_068_lattice.stl  1954879484
variant_052_lattice.stl  1420059884
variant_038_lattice.stl  1058859084
variant_026_lattice.stl   740360884
```

Its recipe is complete — `job.json` (971 B), `M2_verticalStand.step` (229,557 B)
and `out/design.bin` (14,983,608 B) are all present, which is 15.2 MB against
5.17 GB — and all four rungs have been materialised back from exactly those three
files in this task, with matching triangle counts, matching masses, matching
margins and matching verdicts (`R4_no_verdict_moves.txt`).

**What it takes to remove it safely, by hand, today:**

1. Confirm the recipe is there and readable:
   ```
   ls -l ~/.topopt-worker/ca62f91cba4b422d/job.json \
         ~/.topopt-worker/ca62f91cba4b422d/M2_verticalStand.step \
         ~/.topopt-worker/ca62f91cba4b422d/out/design.bin
   ```
2. Record what you are deleting, so it is a fact rather than a memory:
   ```
   cd ~/.topopt-worker/ca62f91cba4b422d/out && \
     shasum -a 256 variant_*_lattice.stl > lattice_meshes_reclaimed.sha256 && \
     ls -l variant_*_lattice.stl >> lattice_meshes_reclaimed.sha256
   ```
3. Keep a copy of the four receipts — they already sit beside the meshes as
   `variant_XXX_lattice.report.json` and are only ~10 kB each. Do not delete them.
4. Delete only the meshes:
   ```
   rm ~/.topopt-worker/ca62f91cba4b422d/out/variant_*_lattice.stl
   ```
5. To get any one of them back (≈6 minutes each, 22 GB of free disk needed for all
   four): rebuild the `lattice_variant` job with
   `evidence/2026-08-07-lattice-recipe-not-triangles/s2a_make_lattice_variant_job.py`
   and run `topopt-cli lattice-variant j_<vf>.json --out <dir>`. The full script is
   `s1cd_materialise.sh` in this evidence directory.

**Two caveats, stated rather than buried.** The rebuilt file is the same object but
not the same bytes (§b), so step 2's checksums will never be re-satisfied — they
record what *was* there, they do not let you prove you got it back. And after
deleting, the app's Export on those four variants fails until item 5 above is
built; the variant list, the masses, the margins, the verdicts and the
recommendation are all unaffected, because none of them reads the mesh.
