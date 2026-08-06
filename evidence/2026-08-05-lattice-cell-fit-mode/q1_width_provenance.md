# Q1(a) — what `min_extrudable_width_mm` IS, where it comes from, and who assumes what

Read before any number was changed, as the review asked. Every claim below is a file
and a line, and two of them contradict the review's premises.

## 1. The DEFINITION, in core

`core/include/topopt/grading.hpp:88-92`

> The STATED minimum extrudable strut width (mm) — requirement 3, an INPUT the law
> honours and reports against, not a magic number. The printability floor is set so a
> strut at rho_min prints at exactly this width; every higher-density strut is fatter.

`core/include/topopt/job.hpp:230` — "stated minimum strut width (mm), finite > 0".
`core/include/topopt/job.hpp:176-180` (the `lattice` block's copy) — "Optional STATED
minimum extrudable width (mm)".

So core's meaning is **extrusion width, not nozzle bore**, and core never sources it —
it is an input.

## 2. Where the APP populates it

`LatticeSpec.minExtrudableWidthMM` ← `lineWidthMM` ← **`project.printParams.wallLineWidthOuterMM`**,
at every call site:

| site | line |
|---|---|
| `app/TopOptKit/Sources/TopOptFlows/LatticePage.swift` | 140, 180 |
| `app/TopOptKit/Sources/TopOptFlows/AppModel.swift` | 269 |
| `app/TopOptKit/Sources/TopOptFlows/WorkspacePlaceholder.swift` | 1974 |

and it reaches the job at `RemoteRunner.swift:709-712` / `RelatticeRunner.swift:129-130`.
`LatticeSettings.swift:563` documents the parameter as "the user's **outer extrusion
line width** (mm) — the strut printability floor".

**PR #301 does not change this.** Its diff still passes
`project.printParams.wallLineWidthOuterMM` (its `WorkspacePlaceholder` hunk).

## 3. What `wallLineWidthOuterMM` IS

`app/TopOptKit/Sources/TopOptFlows/PrintParams.swift:43-49`

> Extrusion line width (mm) of the single OUTER wall loop — the width of one deposited
> bead, a slicer setting (typically 1.0–1.2× the nozzle), **NOT the nozzle diameter**.

and `:50-53` for its sibling:

> Extrusion line width (mm) of the INNER wall loops … A bead width, not the nozzle
> diameter. This is the core's historical single `wall_line_width_mm`.

`PrintParams.swift:106-109` — the shipped defaults:

```
wallLineWidthOuterMM: 0.42,  wallLineWidthInnerMM: 0.45
```

His job carries exactly those: `wall_line_width_outer_mm: 0.42`,
`wall_line_width_mm: 0.45`.

## 4. ★ TWO REVIEW PREMISES ARE CONTRADICTED BY THE CODE

**"0.42 is his NOZZLE BORE."** It is not, by this codebase's own definition.
`PrintParams.swift:44-46` says `wallLineWidthOuterMM` is a deposited bead width and
explicitly "NOT the nozzle diameter". 0.42 is his OUTER bead; 0.45 is his INNER bead.
Neither field records a bore — the app has no nozzle-diameter field at all.

**"THE APP SENDS 0.45."** It sends `wallLineWidthOuterMM`, which on his configuration
and on the shipped default is **0.42**. The `0.45000000000000001` in PR #301's evidence
comes from **its own test fixture**, not from his configuration:
`app/TopOptKit/Tests/TopOptFlowsTests/LatticeRetentionEvidenceGen.swift:28` calls
`runSpec(lineWidthMM: 0.45, …)` and `:36` constructs
`wallLineWidthOuterMM: 0.45, wallLineWidthInnerMM: 0.45`. Its other `0.45` is a
hardcoded string in a schema-acceptance probe (`probe_grading_body`), where the value
is arbitrary.

So this branch's 0.42 derivations DO describe what his device sends today.

## 5. ★ THE DEFECT THAT IS ACTUALLY THERE, and the review found the right smell

The codebase carries **two** bead widths and the lattice path silently takes the
**narrower** one:

* the strut printability floor is set from the **OUTER** wall bead (0.42);
* the width-aware knockdown and core's historical `wall_line_width_mm` use the
  **INNER** bead (0.45).

A lattice strut is **not a wall loop**. Nothing in the app, core, or any handoff states
which bead a slicer actually deposits for a lone strut, and taking the outer width is
the LESS conservative choice: it lets the derivation ask for a 1.0950 mm cell with
0.4200 mm struts where the 0.45 mm assumption needs 1.1732 mm and 0.4500 mm. If a lone
strut is in fact laid down at 0.45, every strut this mode derives at 0.42 is **thinner
than one line of his slicer's output** — the review's safety point, and it stands even
though its provenance was wrong.

**This is a decision, not a bug to quietly patch**, and it is APP-side (this task
changes `core/` only). It is named here, quantified in §6, and left to the maintainer.
Whoever takes it must answer: *which bead does the slicer lay for a single unsupported
extrusion?* — and the answer belongs in `PrintParams.swift` next to the two fields.

## 6. THE SENSITIVITY, both widths side by side (Q1(c))

His 4 mm wall, octet, N* = 5:

| stated width | finest printable cell | derived cell | rho | strut | cells/member | regime |
|---|---|---|---|---|---|---|
| **0.42** (outer bead — what the app sends) | 1.09496187186339 mm | 1.0950 mm | 0.6000 | 0.4200 mm | 3.65 | out of regime |
| **0.45** (inner bead — `wall_line_width_mm`) | 1.17317343413935 mm | 1.1732 mm | 0.6000 | 0.4500 mm | 3.41 | out of regime |

A 7.1 % move in the width moves the cell 7.1 % and the cells-per-member 6.6 %. The
qualitative verdict does not change — a 4 mm wall is out of regime either way, and
latticed either way — but no number should ever be quoted without the width beside it.
The full table at both widths is in `r2_flip_probe.txt`.

## 7. Q1(d) — CROSS-CHECK AGAINST PR #301

PR #301's cell control is bounded below by core's densest-end printability floor, which
its evidence records as **1.173173434139347 mm** at a 0.45 mm stated width. This
branch's derivation at 0.45:

```
PR #301 cross-check @ 0.45 mm: their control floor 1.17317343413935 mm,
this derivation 1.17317343413935 mm, delta 0.000e+00 mm — AGREE
```

Identical to the last printed digit, and the check is compiled into
`core/tests/tools/probe_fit_flips.cpp` so it re-runs with the numbers. Both are
`w / octet_strut_diameter_mm(lattice_rho_max, 1.0)`, read from core, not transcribed.
