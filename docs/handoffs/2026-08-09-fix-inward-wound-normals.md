# fix-inward-wound-normals — every mesh core builds is now wound outward

**Task:** `2026-08-09-fix-inward-wound-normals`
**Evidence:** `evidence/2026-08-09-fix-inward-wound-normals/`
**Changes:** `core/` only. CI: `core-linux` + `app-macos`.
**Stacks on:** `strut-clip-matches-shell` (`c586e8d`) — it edits that task's
`mesh_distance.cpp` and `test_lattice_clip_shell.cpp`, so it cannot be reviewed
against `main`.

---

## 0. HEADLINE

**Every STL and 3MF this codebase has ever exported carried inverted facet
normals**, and `mesh.hpp` has documented the opposite contract the whole time
("the positive enclosed volume … for the outward-facing counter-clockwise
winding STL specifies"). A shipped 128-resolution variant encloses
**−442,684 mm³**.

**★ HIS FOUR FILES ARE AFFECTED BUT HE DOES NOT NEED TO RE-EXPORT FOR THIS.**
Slicers auto-repair inverted normals, which is exactly why his prints have come
out. This is a correctness and interoperability fix, not a print-quality one. He
should re-export for the *other* task (`strut-clip-matches-shell`, the 0.61 mm
strut teeth) — and when he does, he gets this for free.

**★ AND ONE THING THE FILED SCOPE DID NOT SAY: the lattice soup was already
MIXED.** Measured before any change: a one-cell octet soup came to
**−684.494 mm³ = −(36 × 20.000 strut) + (14 × 2.536 node)**. The strut prisms and
rim tori were inward; the node icosahedra were **already outward**. So fixing
`marching_cubes` alone — the filed scope — would have left every latticed file
with an outward shell around a soup that is inward in one family and outward in
another. The lattice generator had to move in the same change, and the node table
had to be left alone. I flipped it anyway on the first attempt, "for
consistency", and the cross-check caught it (§3).

---

## 1. WHAT CHANGED

| file | change |
|---|---|
| `core/src/mesh/mesh.cpp` | **the fix.** `marching_cubes`'s emission: `{idx[0], idx[1], idx[2]}` → `{idx[0], idx[2], idx[1]}`. The classic MC triangle table is written for "inside is where the field EXCEEDS the iso", the opposite of this function's convention. |
| `core/src/mesh/lattice_gen.cpp` | `emit_strut`'s four `add_triangle` calls, same swap. Covers `emit_skin_edge`, `emit_freeform_skin_edge` and `emit_rim_line`, which all funnel through it. |
| `core/src/mesh/lattice_gen.cpp` | `emit_node` — **NOT changed**, and now carries a comment saying why touching it is a mistake, with the measurement. |
| `core/src/mesh/mesh_distance.cpp` | the winding **compensation**: comment only. It is a measurement (`if (signed_volume(mesh) < 0.0)`), so it self-disarms; it is kept, and the comment now says it no longer fires and why it stays. |
| `core/src/mesh/surface_operator.cpp` | the vertex-normal compensation: same, comment only. |
| `core/tests/unit/test_lattice_clip_shell.cpp` | **the tripwire**: `CHECK(md.inward_wound())` → `CHECK(!md.inward_wound())`. |
| `core/tests/unit/test_mesh_winding.cpp` (new ctest `mesh_winding`) | the bar. |

**Which line does which** (the question §A of the brief asks to be answered
explicitly):

* **`mesh.cpp`'s swapped index pair** and **`lattice_gen.cpp`'s `emit_strut`**
  are the FIX — they change what is written.
* **`mesh_distance.cpp:272`** and **`surface_operator.cpp:265`** are the
  COMPENSATIONS — they change nothing, they simply stop executing.
* **`test_lattice_clip_shell` case 0's `!inward_wound()`** is what makes the
  difference between those two visible instead of inferred.

`emit_rim_torus` needed no change — measured outward already, and now pinned.

---

## 2. WHY THE SOURCE AND NOT THE WRITERS

The brief asked for the source unless there is a reason not to. There is not one.

* The writers are **two of many** consumers. `MeshDistance`,
  `surface_operator`'s normals, the app's `ViewerMesh.faceNormals` and every
  future reader all take the winding from the mesh in memory.
* `mesh.hpp` already documents the outward contract. Fixing the writers would
  leave that contract **false in memory** while making the files look right —
  the worst of both, and precisely the shape of bug this whole exercise is about.
* It would leave `MeshDistance` and `surface_operator` compensating **forever**,
  which is the "two mechanisms, one silently covering the other" the brief warns
  about.

The negative control in `test_mesh_winding` case 4 is aimed straight at the
alternative: a hand-built OUTWARD cube round-tripped through `write_stl_file`
must still enclose +1000 mm³. A writer-side flip inverts it and fails there.

---

## 3. ★ THE MISTAKE THE CROSS-CHECK CAUGHT

The first version of this change swapped `emit_node`'s icosahedron indices too,
on the reasoning that the generator should be internally consistent. That was
wrong: the icosahedron table was **already outward**.

A sign test would not have caught it — the soup total stayed positive. What
caught it was the check that the emitted geometry must equal the generator's own
analytic accounting:

```
emitted signed_volume  = 684.493890      <- wrong: 36x20.000 strut MINUS 14x2.536 node
interior_volume_mm3    = 755.506110      <- LatticeGenStats' own number
```

The 71.012 gap is exactly `2 x 14 x 2.536151`. After restoring `emit_node`, the
emitted volume is **755.506110**, equal to the generator's accounting to 1e-3.

Both checks are now in the file, and the rim case carries the same cross-check
with a stated band (the rim's `rim_volume_mm3` is the ANALYTIC torus volume while
the emission is an inscribed faceted tube, legitimately ~2% under — measured
10.161 of 495.697 — whereas an inward family would be 200% out).

---

## 4. BARS

### A fixture that fails first · **PASS**

`r2_red.txt` → **6 failures**, with the importer control passing (so only the
synthesizers were wrong). `r2_green.txt` → 15 checks, 0 failures.

### Byte-identity where nothing should change · **PASS**

The meshes MUST change — that is the fix. The claim this earns instead is much
narrower and is proved rather than asserted (`r1_geometry_unchanged.txt`): every
facet of every exported file is the SAME triangle, either unchanged or with its
last two vertices swapped, **0 unmatched on all eight files**:

| file | facets | same | reversed | unmatched |
|---|---:|---:|---:|---:|
| `variant_068.stl` | 284,704 | 0 | 284,704 | **0** |
| `variant_068_lattice.stl` | 763,320 | 120,384 | 642,936 | **0** |
| …and the other six | | | | **0** |

**The mixed split is the point.** A latticed file reporting 100% flipped would
mean the node balls had been wrongly flipped too. The end-to-end number says the
same thing:

```
variant_068          before -442684.0 mm^3  ->  after +442684.0   (exact negation)
variant_068_lattice  before -879884.4 mm^3  ->  after +880249.3   (NOT exact)
```

Half that discrepancy is 182.45 mm³ — the node icosahedra, which were already
outward, were correctly left alone, and now ADD where they used to subtract.

### A full gate table where things should change · **PASS — nothing changed**

His job, four rungs, runB (inward) vs runC (outward), `r4_gate_table.txt`:

| rung | margin | lattice margin | accepted | latticed voxels | interior mm³ | voxel flips |
|---|---|---|---|---|---|---|
| 0.68 | 3254.356637 = | 3090.491158 = | true | 1221 = | 4963.953 = | **0** (control 0) |
| 0.52 | 3389.417071 = | 3096.575242 = | true | 1123 = | 5611.517 = | **0** (control 0) |
| 0.38 | 3290.912400 = | 3047.621385 = | true | 527 = | 3720.701 = | **0** (control 0) |
| 0.26 | 3014.120054 = | 2912.194018 = | true | 225 = | 1409.429 = | **0** (control 0) |

Every quantity identical to the digits printed; lattice mass delta **+0.000000 g
on every rung**. A winding flip is an index permutation and cannot move physics —
this is that stated as a measurement rather than as an argument.

`gen_seconds` reads 574 s → 629 s, and I am NOT claiming that as a cost: the app
package's `swift test` was running concurrently for part of runC. A swapped index
pair has no runtime cost, and the per-rung work counts above are identical.

### §A(b) — PR 316's protrusion invariant re-measured · **PASS, and for the right reason**

| | fixtures | his rung 0.68 | 0.52 | 0.38 | 0.26 |
|---|---|---|---|---|---|
| protruding vertices | 0 and 0 | 0 / 1,848,060 | 0 / 1,933,764 | 0 / 923,856 | 0 / 328,344 |

Identical to the pre-flip run **including the measured-vertex counts**, and the
control line still reads its exact 2,880 of 496,092 at 0.178444 mm.

**Is it a zero for a different reason? Yes, and that is asserted.** Before, the
zero depended on `MeshDistance` detecting the inward winding and flipping its
pseudonormals. Now `signed_volume` is positive, that branch does not execute, and
`test_lattice_clip_shell` case 0 asserts `!md.inward_wound()`. The two situations
are no longer distinguishable only by reading code.

### The assertion-message census · **PASS, with one deliberate removal**

Baselined on `c586e8d` (this PR is the working tree against it), not on `main` —
censusing a stacked PR against `main` would credit it with the parent's
assertions. Result: ctests 115 → 116, production refusals 397 → 397 with none
removed, comparison kinds up or flat in every bucket, and **exactly one message
removed**:

```
"marching_cubes output is wound inward — if this flips, re-check every sign in this file"
```

That is the tripwire flip described above, and it is the census doing its job:
the one assertion whose truth this change inverts is the one it reported.

### Both CI jobs · **PASS**

core `ctest` **116/116** (lib3mf-gated tests registered, so the denominator is
CI's); app package **1367 tests, 0 failures**.

### No scratch at the repository root · **PASS**

Everything is under `core/`, `docs/`, `evidence/2026-08-09-fix-inward-wound-normals/`.

---

## 5. THE `std::fabs` QUESTION — A RECOMMENDATION, NOT A DECISION

§A(d) asks whether `mesh_enclosed_volume_mm3`'s `std::fabs` should stay as
belt-and-braces or go as a silent-corruption-hider. **My recommendation: KEEP it,
and it is not a close call — but the reasoning changes for one of its two
callers, so the decision is yours.**

There are two such sites, and they are the same shape:

| site | what it feeds |
|---|---|
| `run_job.cpp:3838` `mesh_enclosed_volume_mm3` | `:1922` the latticed receipt's `shell_enclosed_volume_mm3`; `:5053` a re-analysed mesh's MASS (`density_g_cm3 * V / 1000`) |
| `smooth.cpp:12` `enclosed_volume` | the smoothing operators' volume bookkeeping |

**Why keep.** Both ask for a MAGNITUDE — "how much material is in this body" —
and both are handed meshes whose provenance they do not control. `:5053` in
particular takes a mesh that may have been IMPORTED and repaired, and
`part.cpp:485` only normalises the winding when the repair path runs at all. If
the `fabs` went, an inward mesh reaching either site would produce a NEGATIVE
mass, and a negative mass is not a loud failure — it is a number that flows into
a receipt.

**Why the counter-argument is real anyway.** `fabs` is exactly what let this bug
live for as long as it did: it is the reason nothing downstream ever noticed the
sign. Removing it would turn a silent wrong answer into a visible one.

**The way to have both, if you want it**, and the reason I am not doing it here:
assert the sign and then take the magnitude —
`assert(v6 >= 0.0); return v6 / 6.0;` — which keeps the magnitude semantics while
making a future inward mesh fail loudly instead of quietly. That is a behaviour
change to a path this task does not otherwise touch, on meshes this task has not
measured (the imported/repaired ones), so it belongs to whoever owns that call
site, not to a winding fix. **Flagged, costed, not done.**

---

## 6. IN PLAIN WORDS

**Nothing you need to do differently, and nothing wrong with the parts you have
printed.**

Every 3D file this program has written has had its triangles listed in the wrong
order. A triangle in an STL file doesn't just say where its three corners are; the
order they are listed in tells the reader which side is the outside of the part.
Ours have been saying "outside is in here" — pointing inwards.

You have never seen it because slicers fix this automatically. It is a
well-known, extremely common fault in 3D files, and every slicer worth using
repairs it silently on load. That is why your prints have come out.

It still needed fixing, for three reasons:

* other software is not as forgiving as a slicer — a CAD package, a mesh
  inspector, or a rendering tool can show the part inside-out or refuse it;
* the program's own documentation said the files were the right way round, so
  anyone reading the code was being told something untrue;
* and two other parts of the program had quietly grown their own workarounds for
  it. One of those was holding up the strut-protrusion check from the other
  task. Two workarounds silently propping up one bug is how a future change ends
  up passing its tests while doing the opposite of what it says.

**Your four latticed files do contain this.** But you do not need to re-export
for it — a slicer will keep repairing it exactly as it has been. You *should*
re-export for the other task (the 0.61 mm strut ends poking through the surface),
and when you do you will get this fix along with it.

One detail worth knowing, because it is the only thing here that could have gone
wrong quietly: the geometry has not moved a micron. Every triangle in your files
is the same triangle in the same place; only the order of its corners changed.
That is measured, not assumed — 284,704 of 284,704 corners in the solid file and
763,320 of 763,320 in the latticed file matched their originals exactly, with
none left over.
