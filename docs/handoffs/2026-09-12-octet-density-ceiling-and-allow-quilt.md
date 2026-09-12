# Octet density ceiling, "Allow quilt", and Minimize plastic decoupled — 2026-09-12

**Branch:** `claude/quilt-lattice-preview-m2-39c5dd` (reset to `d5a90120` this morning at his
request; the previous night's per-cell attempt is parked on
`claude/quilt-per-cell-attempt-2026-09-11` for reference only).
**Installed build:** Debug, iOS Simulator, dylib 16:03:29 (the test-only `drawnBand`
accessor was added after it; no behaviour differs).
**Scope:** app only; octet only; grade-to-shape untouched.

## 1. His rulings

1. "The density does not properly scale with the size of the lattice cell … We set the
   minimum - but never the maximum. We need to implement a maximum and allow for
   thickness/density to play only between those two numbers."
2. "We SHOULD allow *one* method to go to that maximum … a purely manual method. There
   should be no automatic/simulated method that achieves that look."
3. "leave the grade to shape alone. Mainly because I like the look of a quilt as part of
   the grade to solid."
4. "implement this to the non-simulated paths … so that even when manually input they
   can't create a quilt. … a single small checkbox that says 'Allow quilt' … this is only
   for OCTET TRUSS."
5. "minimize_plastic on/off should not have any bearing on the lattice whatsoever."

## 2. The physics behind the number

What an octet lattice looks like is a function of strut diameter over cell size alone.
Exact union of the cell's 24 struts (128³ voxels, `evidence` in the session log):

| d/L | windows open | core ρ (table) | note |
|---|---|---|---|
| 0.20 | 51 % | 0.22 | the ceiling |
| 0.354 | 13 % | 0.53 | parallel struts touch (`quiltDensityCeiling`) |
| 0.384 | 7 % | 0.60 | core's table ends and is FLAT above |
| 0.408 | 0 % | — | windows closed |

Core's measured strut law is linear in the cell, so a d/L ceiling is ONE density at every
cell size. The slender-strut formula ρ = 12√2π(r/L)² is wrong past ρ ≈ 0.2 and was never
the app's law; core's 8-row table is.

## 3. What changed

- `LatticeType.aestheticStrutRatioCeiling = 0.20`, `hasAestheticCeiling` (octet only),
  `aestheticDensityCeiling(cellMM:)` (≈ 0.219 for octet; 1 for the others).
- `LatticeSDFScene`: the simulated map is RESCALED into [floor, ceiling] (`demand × cap`,
  exact under the gamma law; a clip would flatten everything above 22 % of the reference
  stress). A stated per-region density is CLIPPED at the ceiling unless Allow quilt.
  Two maps now: `demand` (raw — the dyadic cell planner, retention and the stress overlay
  read it; grade-to-shape untouched) and `drawnDemand` (what the cell texture's activation
  is baked from, for both the stepped bake and the ladder). `drawnBand` is the band it was
  capped against. DIAG: `densityCeiling rho=… demandCap=… cappedGraded=… cappedStated=…
  allowQuilt=…`.
- `LatticeSettings.allowQuilt` (Codable, absent ⇒ false). `manualThicknessDensity` and
  `manualThicknessRangeMM` (the slider's top) are held at the ceiling unless Allow quilt.
  The Uniform mode's default (the band midpoint, 0.475) is held under it too. The density
  BAND (`densitySpan`) itself is untouched because the stepped bake's printability floors
  read its ends.
- `ProjectModel.latticeAestheticDensityBand` tops out at the ceiling unless Allow quilt.
- Wizard: "Allow quilt" toggle under Density (non-organic panel), shown for octet only.
- Minimize plastic: the scene's utilisation cap on it is gone (`minimizePlastic` stays in
  the signature, unread); `resolvedCellPlan` Auto always sweeps floor → ceiling; the
  bake fingerprint no longer includes it (flipping the chip does not rebake); the wizard
  caption no longer mentions it; the three lattice call sites no longer pass it.

## 4. Verified

- Device (build 16:03): Simulate Stresses OFF, Density Uniform, Fine project → legend
  band 22 % · 0.80 mm across the front wall, one open 12 mm octet. The earlier 63 %
  ("Add to strengthen") sheet cannot recur on any automatic path.
- Tests: `LatticeAestheticDensityCeilingTests` (5), and re-pins with the reason written
  in each: `LatticeAcceptanceTests.testAutoWithMinimizePlasticGivesThinStruts` (ON == OFF,
  under the ceiling), `LatticeGradingWiringTests` (fingerprint excludes the chip; ON == OFF
  voxel for voxel), `LatticeThicknessAndFloorTests` (slider top and manual thickness held
  unless Allow quilt), `LatticeAestheticDensityControlTests` (band top = ceiling, or the
  printable floor where a 2 mm cell's bead is already past it). 18/18 green.
- Subset run: see §6 (appended when it lands).

## 5. Open — his call

- The ceiling value itself (0.20 ⇒ windows half open). 0.24 keeps 41 % open if he wants
  a heavier lattice as the automatic top.
- Grade-to-shape on 12 mm cells still reads as blocks by construction (whole cells);
  he wants the quilt-then-solid look there, and that is unchanged.
- His outline question at 3:51 was on a bake with "Grade the lattice" OFF; the later
  Shape-grade bake (band 5, single-cell off) marks 875 of 3,369 cells solid at the
  outline. Whether that ring is the look he wants is a separate item.

## 6. Subset

`swift test --filter "Lattice|Quilt|Stepped|ShellClip|Density|Proxy|Wizard|Settings"
--skip "MatrixProbe|Sweep|Permutation"`, Debug, macOS: **831 passed, 2 failed**, both
`LatticeCellPlanTests` pins of the removed objective coupling
(`testStrengthFirstHoldsTheFinestCell`, `testTheObjectiveReachesTheEmittedSpec`), re-pinned
to "the objective must not move the lattice's cell window" and green on rerun (4/4).
Earlier in the session the same subset found and I re-pinned: `LatticeAcceptanceTests`,
`LatticeGradingWiringTests` (2), `LatticeThicknessAndFloorTests` (2),
`LatticeAestheticDensityControlTests`; `LatticeCellGradingTests` and
`LatticeProbeSamplingTests` went green once the raw map was restored for the planners.
Evidence files rewritten by the suite were reverted before committing.

**Full app suite** (`swift test`, Debug, macOS, 3729 s): **2427 tests, 31 skipped, 5 failing
test cases** — exactly the five proven pre-existing on a clean `d5a90120` checkout the
night before (`AppModelTests` 3MF ×3 — lib3mf in a worktree; `OrganicSampleCubeTests
.testThickerIsLiveAndNeverRetraces`; `OrganicVariantCacheTests.testTheKeyIgnoresThicknessAndFollowsCoreAndTopology`).
No lattice test fails.
