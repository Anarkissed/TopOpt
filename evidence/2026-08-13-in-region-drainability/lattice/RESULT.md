# ★★ THE REALISED REFUSAL QUANTITY — measured, not bounded

One `lattice-variant` run per arm, his recipe verbatim
(`evidence/2026-08-07-lattice-recipe-not-triangles/job_his_2mm_skinnone.json`),
`require_lattice_void_reaches_exterior` armed explicitly, variant keyed at
`volume_fraction 0.7973` — the requested fraction both design stores record.

| arm | upper bound (ALL sealed void) | ★ REALISED (latticed sealed) | verdict |
|---|---|---|---|
| robust triple | 11,158 mm³ | **1,021.5 mm³** | ★ **REFUSED** — 20 of 217 cells, 206 of 1242 latticed voxels, 1 cavity |
| perimeter C=1 | 5,946 mm³ | ★ **0 mm³** | ★ **ACCEPTED** — latticed, certified, `variant_080_lattice.stl` written |

★ **The upper bound overstated the robust triple's blocker by 11×** — 11,158
against a realised 1,021.5. Against production's 337.206 mm³ it is **3.0×**, not
the 33× the bound implied.

★★ **But the ordering did not merely persist — it became CATEGORICAL.** On the
bound the two arms differ by 1.9×. On the realised quantity **one refuses and one
ships.** The perimeter penalty is not "the right answer to a different question"
for latticed parts; on this recipe it is **the only answer that exists.**

★ **Robust refused before a single triangle was written** (`run_job.cpp:3503`) —
its output directory holds only `loadcase.json`.

★ **And the refusal text confirms the documentation defect independently:** *"THIS
CHECK IS ON BY DEFAULT, so REMOVING the key does not turn it off."* That is the
running code contradicting `run_job.cpp:3463`'s "Off by default".
