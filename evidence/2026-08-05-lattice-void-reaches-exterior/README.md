# evidence — 2026-08-05-lattice-void-reaches-exterior

Handoff: `docs/handoffs/2026-08-05-lattice-void-reaches-exterior.md`

THE RULE: the void space inside any lattice must connect to the exterior. No
sealed lattice-filled cavities. Option
`lattice.require_lattice_void_reaches_exterior`, default **false**.

Reuses `evidence/2026-08-04-protect-freeze-vs-solidity/`'s `M2_verticalStand.step`
and `job_maintainer.json` — the maintainer's own part and his own captured job
document — rather than re-capturing them.

| file | what it is |
|---|---|
| `s1_sealed_cavity_before_after.sh` / `.txt` | **S1 / R2, the load-bearing bar.** A lattice-filled cavity buried in the middle of the l-bracket's foot, run three ways. **BEFORE** (option absent): today's build exports a 1.7 MB latticed STL and reports `lattice_accepted: true` — the defect, asserted rather than described. **AFTER** (armed): refused, no STL written, with the cells, the volume, the mm bounding box and the declared region named. **OPEN** (armed, the SAME slab with `half_w` 8 → 40 mm so it reaches the surface): still passes. Without the OPEN run the bar would also be met by a check that refused everything. |
| `r1_byte_identity.sh` / `.txt` | **R1**, stash-rebuild checksum across two SEPARATELY BUILT binaries. **A** no lattice at all, base vs branch: identical. **B** lattice WITH a role region and the option OFF, base vs branch: identical, including every latticed mesh and receipt. **C** same binary, armed vs not: geometry and designs identical, documents differ ONLY by the `void_escape` block they gain. Asserts the two binaries DIFFER first — the `topopt_cli` / `topopt-cli` silent-no-op trap. It caught a real bug in its own first run (the stash was never popped, so both sides were the base binary); the fix is in the script, commented. |
| `r3_gate_table.py` / `.txt` | **R3**, every rung's verdict and both margins, off vs on, plus the voxel-classification flip count per rung and the composite lattice margins — all zero movement. Against a negative-control floor run FIRST: **C1** one voxel moved across the printed iso by 1e-9 ⇒ exactly 1 flip; **C2** rung 0.68 vs rung 0.52 ⇒ 2009 flips. Without those two, "0 flips" would be a comparator that cannot count. |
| `s3_fixture_table.py` / `.txt` | **S3**, the measured table: seven real lattice-shaped jobs this repo owns (uniform whole-part, graded swept, freeform `skin` finish, self-weight mesh job, + exclude region, + include region, the maintainer's WallMount part at 8 mm) plus TWO DELIBERATE controls (the sealed cavity and its open twin). Both controls are ASSERTED — the script exits non-zero if either goes the wrong way — because a table where nothing refuses is not evidence that the fixtures are clean. |
| `s3_maintainer_run.py` / `.txt` / `_128.txt` | **S3, the headline question.** His captured job document — M2_verticalStand, his 8 include + 1 exclude regions — with the grading block replaced by the uniform 8 mm cell the brief describes, and the rule armed. Run at resolution 64 and at his own 128. What it is NOT: his overnight design (fingerprint `b3abcf880554`) is not in this repo, so the literal run cannot be re-decided; this is his job re-run here. All THREE deviations from his job are stated in the script's own docstring: the grading block replaced by the uniform cell, `simp.max_iterations` being IGNORED in loadcase mode (`run_job.cpp:5120` applies it only on the non-loadcase branch), and `"skin"` forced to `"none"` (see below). |
| `res_sensitivity.py` / `.txt` | The verdict's dependence on the grid, measured rather than filed. A MARGINAL cavity (a 6 mm cylinder in an 8.33 mm-thick foot, ~1 mm of wall) FLIPS across resolutions 32–72; the SHIPPED fixture (a slab with ≥ 2 voxels of solid on every side) is sealed at all six and its open twin passes at all six. It is the cavity that is marginal, not the check. |
| `r6_deleted_test_sweep.sh` / `.txt` | **R6.** Every removed line in `core/` and `app/` listed individually (five, all of them lines edited rather than assertions), plus a `CHECK(`-message census by TEXT so a moved assertion is not miscounted as a lost one: 3344 distinct on `origin/main`, 3434 on the branch, **0 present on main and absent now**, 90 added. |
| `ctest.txt` | The full suite on this branch, MERGED WITH MAIN: **100 % of 108 tests passed**, including the two new ones — `lattice_void` (the walk, 70 checks, with a 26-connected fill computed alongside as the negative control) and `lattice_void_exterior` (the wiring, 28 checks, with the OPEN control). |
| `l-bracket.step` | The demo part the constructed cases are built on, copied so the scripts are self-contained. |

## Every fixture here sets `"skin": "none"`

Main gained a refusal while this task was in flight (`lattice-cell-fit-mode`,
`run_job.cpp` M4): a lattice `skin` other than `"none"` that emits NO geometry is
refused rather than silently exported undressed. On a voxel-silhouette part — all
of these, and the maintainer's — the rim/diagrid finish rides analytic boundary
faces that do not exist, so it emits nothing and that refusal fires. It is a
DIFFERENT rule from this one and it would mask this one, so every fixture sets
`"skin": "none"` with the reason written down at the point it is set. On the
maintainer's job, whose document says `"rim"`, it is a stated third deviation.

Every number in this directory was RE-MEASURED after merging main, and every one
of them came back the same.

## The one number to carry away

His own job comes back **open on every rung**, at resolution 64 and at 128, with
the lattice's escape network touching all six faces of the design grid at escape
depth 0. His include regions are 4 mm-deep face slabs drawn on the part's outer
surface and bolt cylinders that punch through it — the "lattices that start from
the outside going in" case he said works fine. The rule agrees with him.
