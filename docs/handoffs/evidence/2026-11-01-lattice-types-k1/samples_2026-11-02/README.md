# Lattice samples, 2026-11-02 rulings (core, branch claude/lattice-types-k1)

For each of the 8 new types: the **cube** (40 mm, 8 mm cells, the band's middle density, on a 1.5 mm plate) and the **coupon** (45 x 40 x 35 mm: a 3 mm solid wall, the lattice body graded along x from the band's bottom to its top and never under one 0.42 mm bead, a cell-size step to 4 mm at x 19 where the type allows one, a 12 mm tongue, a round top of radius 20, on a 1.5 mm plate). Print each as it stands, no supports. Every number below is read from the receipt (`<file>.stl.json`) beside its STL.

Built by `topopt-cli version=0.1.0 fingerprint=dev dirty=unknown lattice_sample=1`, the frozen binary of `git archive 81f49eef core` (an archive build has no git, hence the `dev` fingerprint).

| type | intents | shape | cell | density | thinnest strut / wall | triangles | file |
|---|---|---|---|---|---|---|---|
| FCC | Structural + Aesthetic | cube | 8 mm | 0.343 (band middle) | strut 2.125 mm | 70,932 | 3.5 MB |
| FCC | Structural + Aesthetic | coupon | 8 mm, doubled to 4 mm at x 19 | 0.095 to 0.591 along x | strut 1.024 mm | 189,284 | 9.5 MB |
| Kelvin | Structural + Aesthetic | cube | 8 mm | 0.299 (band middle) | strut 2.003 mm | 141,612 | 7.1 MB |
| Kelvin | Structural + Aesthetic | coupon | 8 mm, doubled to 4 mm at x 19 | 0.094 to 0.505 along x | strut 1.025 mm | 371,496 | 18.6 MB |
| Rhombic dodecahedron | Structural + Aesthetic | cube | 8 mm | 0.343 (band middle) | strut 1.675 mm | 161,312 | 8.1 MB |
| Rhombic dodecahedron | Structural + Aesthetic | coupon | 8 mm, stepped to 4 mm at x 19 | 0.172 to 0.513 along x | strut 1.115 mm | 479,600 | 24.0 MB |
| Diamond | Structural + Aesthetic | cube | 8 mm | 0.375 (band middle) | strut 2.468 mm | 87,252 | 4.4 MB |
| Diamond | Structural + Aesthetic | coupon | 8 mm, doubled to 4 mm at x 19 | 0.157 to 0.592 along x | strut 1.488 mm | 249,076 | 12.5 MB |
| BCC | Structural only | cube | 8 mm | 0.402 (band middle) | strut 2.581 mm | 38,832 | 1.9 MB |
| BCC | Structural only | coupon | 8 mm, doubled to 4 mm at x 19 | 0.210 to 0.593 along x | strut 1.754 mm | 116,176 | 5.8 MB |
| Simple cubic | Structural only | cube | 8 mm | 0.291 (band middle) | strut 3.230 mm | 21,612 | 1.1 MB |
| Simple cubic | Structural only | coupon | 8 mm, doubled to 4 mm at x 19 | 0.087 to 0.496 along x | strut 1.635 mm | 46,860 | 2.3 MB |
| Gyroid | Structural + Aesthetic | cube | 8 mm | 0.375 (band middle) | wall 0.993 mm | 431,990 | 21.6 MB |
| Gyroid | Structural + Aesthetic | coupon | 8 mm, one cell; tongue solid | 0.150 to 0.601 along x | wall 0.420 mm | 285,526 | 14.3 MB |
| Schwarz-D | Structural + Aesthetic | cube | 8 mm | 0.400 (band middle) | wall 0.856 mm | 697,152 | 34.9 MB |
| Schwarz-D | Structural + Aesthetic | coupon | 8 mm, one cell; tongue solid | 0.200 to 0.600 along x | wall 0.420 mm | 440,058 | 22.0 MB |

Reading the table:
- *intents*: core's `lattice_type_facts`. BCC and SC are offered for Structural parts only (Finding 6):
  - **BCC**: BCC is offered for Structural parts only: its thinnest certifiable strut is 0.219 of the cell, already wider than the open-print limit of a fifth of the cell, so no BCC density prints open (Finding 6).
  - **Simple cubic**: Simple cubic is offered for Structural parts only: its thinnest certifiable strut is 0.204 of the cell, already wider than the open-print limit of a fifth of the cell, so no Simple cubic density prints open (Finding 6).
- *thinnest strut / wall*: the cube's is the one strut size it has; the coupon's is at its lightest, the wall end of the grade. A sheet's is its true wall thickness.
- *step*: Doubled where the type's verdicts allow it, else Stepped, else none (the sheets keep one cell, R5). A coupon's tongue goes solid where it is under the type's aesthetic floor in cells.
- The sheets' meshes are simplified to within 0.02 mm of the true surface (Finding 8); the receipt's `max_deviation_mm` is that bound measured on every triangle.
- None of these is print-tested yet. Each has its receipt beside it; the `.log` files are the CLI's own lines.
