# 03 — Geometry: gyroid and honeycomb generators

**Plain language:** we build the lattice ourselves (M6). Every wall is exactly one extrusion line wide (or two), because that's the kind of wall the published squish tests measured. Density is set mainly by **how big the cells are**: bigger cells with the same thin walls give a softer, lighter lattice. Cell size changes smoothly between soft and firm zones, instead of jumping the way slicer infill does.

---

## 0. The recipe — one definition (M9)

- Everything the preview shows and everything the export writes comes from **one core recipe**:

  density field (02 §10–13) → lattice field (gyroid/honeycomb, bead walls, grading, clip, skins) → either **per-layer bead paths** (preview) or a **mesh** (export).

- **Per-layer bead paths.** For a 1-bead wall, the printer lays the bead along the wall's mid-surface. At layer height z that is the **zero contour of the lattice field in the plane z** (for a gyroid, the zero set of f at that z). For a 2-bead wall, it is two offset contours at ±w/2. Core returns these as polylines per layer, clipped to the part and joined to the skin outline. The app draws them like a slicer preview.
- **This is what we ask the printer for.** Bambu Studio slicing the exported STL can still differ slightly (e.g. Arachne dropping a very short segment). One maintainer slice check per feature closes that gap. If TopOpt later writes the lattice G-code itself (Q5), preview and print become identical.
- **Side stacks.** Stacks can run in any direction (02 §10). The density field is 3D, so the lattice doesn't care which way the load comes from. Honeycomb prisms stay along build Z (R6).

## 1. Walls in whole beads

- Wall thickness t = n_beads × w. Here n_beads ∈ {1, 2} and w is the bead (line) width.
- **Use the existing line-width key** that the lattice strut floor already reads. Do not invent a parallel field. His device sends a 0.42 mm bead.
  - See the line-width history: `wall_line_width_mm` / `wall_line_width_outer_mm` / `grading.min_extrudable_width_mm`, and handoff `2026-08-08-strut-clip-matches-shell.md`.
  - If the right key is ambiguous, stop and ask under `## Blocked`. Do not pick one silently.
- Why whole beads: a wall between one and two beads wide gets sliced as one wide bead or two thin ones, depending on slicer thresholds. A wall thinner than the slicer's minimum bead is **dropped**. The mesh must hold t within a tight band so the slicer does the predictable thing.

## 2. Gyroid (sheet)

Implicit gyroid: f(x) = sin(kx)·cos(ky) + sin(ky)·cos(kz) + sin(kz)·cos(kx), with k = 2π / L.

- **Wall = { |f| / |∇f| ≤ t/2 }** (gradient-normalised), or an equivalent true-distance construction.
  - The raw sheet |f| ≤ c does **not** have uniform thickness, because |∇f| varies over the surface, and uniform thickness is the whole point.
  - Requirement: on the output mesh, measured wall thickness stays within **±10 % of t** over at least 95 % of the sampled wall area. Report the histogram.
- **Density ↔ cell size (thin-wall planning relation):** ρ ≈ 3.0915 · t / L.
  - 3.0915 is the gyroid minimal-surface area per unit cubic cell of edge 1. Use it for planning only.
  - Measure the realised ρ from the output volume and report the deviation (it grows at high ρ).

| target ρ | L, 1 bead (t = 0.42) | L, 2 beads (t = 0.84) |
|---|---|---|
| 0.10 | 12.98 mm | 25.97 mm |
| 0.15 | 8.66 | 17.31 |
| 0.20 | 6.49 | 12.98 |
| 0.25 | 5.19 | 10.39 |
| 0.30 | 4.33 | 8.66 |
| 0.35 | 3.71 | 7.42 |

Two beads mainly matter for firm zones: above ~35 %, one-bead cells get small (< ~3.7 mm).

## 3. Grading (the part slicer infill can't do)

Input is a relative-density field ρ(x): the 3D field C1 builds from the face squish maps (02 §10–13). With t fixed, grading means **cell size varies**: L(x) = 3.0915 · t / ρ(x).

Known approaches, each with a failure mode you must measure rather than assume:

- **(a) Blend discrete-L gyroid fields** with smooth weights (the "multi-morphology" / sigmoid-blending family in the graded-TPMS literature). Watch for doubled walls, thickened walls or holes inside the blend zone.
- **(b) Spatially varying frequency.** Evaluate the gyroid on a warped coordinate or phase. Naive f(k(x)·x) distorts the cells in proportion to ∇k·x. Watch for stretched cells and thickness drift.
- **(c) Wall-width modulation** inside the single-bead band. Useful for fine control on top of (a) or (b); not enough alone, since the band only spans about 1.5–2× in density.

Choose, measure and report. Whatever you choose must pass:

- **Thickness in transition zones:** the same ±10 % band as §2, measured specifically inside the transition zones.
- **Blend length:** at least one cell of the larger L. The maintainer may lengthen it.
- **Connectivity:** one connected lattice body per region. No floating islands and no walls ending in mid-air. Count components and report.
- **Monotone density across the blend:** no dip or bump beyond ±5 % of the linear blend.
- **Gradient limit:** start with cell size changing ≤ 20 % per cell. Report the largest |∇L| that still passes the bars above.

**What the literature actually covers (all four papers read in full on 2026-09-27, PDFs in `papers/`):**

- **None of them grades cell size at a fixed wall.** All three grading papers grade *wall thickness at a fixed cell*:
  - Wallat 2022: level-set t per z-slice, one 2.5–5 mm cell, simulation only.
  - Wang 2026: t per 5 mm cell, bilinear interpolation between cells, FDM PLA-CF.
  - Kedziora 2023: 8 thickness bands, 0.5–1.5 mm, metal FFF, simulation only.

  Fixed-wall cell-size grading, which is what we need, is **not established in these sources**. Methods (a) and (b) above are ours to validate by measurement. This is not a reason to return a no-go. Graded gyroids in general are printable on FDM: Wang 2026 printed graded gyroid plates in PLA-CF, and a constrained graded gyroid was tested in TPU (06-references §A).
- **Pitfall 1 — thickness drifts with cell size.**
  - With a raw sheet |G| ≤ t, wall thickness ≈ 2t / |∇G|, and |∇G| ∝ 1/L. So at fixed t the walls get *thicker* as cells grow.
  - Use the gradient-normalised field |G| / |∇G| ≤ w/2. That keeps w fixed as L varies, and also evens out the variation of |∇G| over the surface.
- **Pitfall 2 — don't match density slice by slice.** Wallat's per-slice thresholding makes t ripple at roughly L/4 to cancel the gyroid's natural ±~10 % per-slice area swing. That ripple means uneven walls. Grade in 3D, and accept the natural per-layer swing.
- **Pitfall 3 — frequency distortion.** Writing sin(2πx/L(x)) makes the local frequency d(x/L)/dx, not 1/L. Either keep ∇L small, or integrate the phase, or blend fixed-L fields (method a).
- **Where stress piles up:** stress concentrates on the **sparse** side of a gradient (Wallat 2022, peak stresses at rounded edges on the high-porosity side). Relevant to durability; no action needed in C2.
- **A reusable pipeline pattern** (Wang 2026): field → per-cell target → shaping exponent → clamp to a printable and connected range → rescale to the overall target → continuous interpolation → evaluate the implicit. Output L instead of t.
  - Do **not** copy Wang's Eqs. 14 and 16 as printed. The reader found a sign error and an inverted relation.
- **Whole beads, independently confirmed.**
  - Kedziora 2023 (p.13): walls that "deviate from multiples of the standard line width… deteriorate part quality due to poor material connectivity where lines merge".
  - Justino Netto 2024: 1.5-bead (0.6 mm) walls gave broken-up toolpaths. 1-bead (0.4 mm) walls had holes at overhangs and the largest mass shortfall; 0.8 mm walls were hole-free.
- **Later options** (not C2):
  - Anisotropic cells stretched along the main bending direction beat isotropic cells at equal mass (Kedziora 2023, 18×8×10 vs 10×10×10 mm).
  - A small fillet where the lattice meets the skin (Kedziora used 0.35 mm).
  - Skins as a whole number of beads.

## 4. Honeycomb (vertical hexagonal prisms)

- Prism axis = build Z. Flat-to-flat cell size d. **ρ = 2t / d** (thin-wall, exact for regular hexagons): 10 % → d = 8.4 mm, 20 % → 4.2 mm, 35 % → 2.4 mm at t = 0.42.
- **v1: uniform cell size and wall width over the whole part**, because R4 already makes v1 one topology per part. Graded honeycomb is later.
- The generator doesn't judge load direction. R6 eligibility is the recommender's job (C1).

## 5. Clipping, skins, one surface

- The lattice fills the model interior. Solid skins cover it:
  - **top/bottom** (surfaces facing ±Z within a stated angle): k layers × layer height, default 4 × 0.2 = 0.8 mm, matching Iacob;
  - **sides:** optional, default none (Iacob used 0 perimeters), or n beads.
- **One surface, not two:** the lattice must be clipped against the *same* surface the skin is extracted from. This repeats PR 316's lesson (struts poked through a shell extracted from a different surface).
- **Suggested implementation:** combine the part's signed distance, the skin shell and the lattice field implicitly, then extract **once** with core's existing iso-surface extraction. That makes the result watertight by construction. Find and reuse the existing extraction; don't write a new one.
- **Outward winding and positive signed volume** (handoff `2026-08-09-fix-inward-wound-normals.md`). Measure with an independent edge-use census on the written file (0 boundary edges, 0 non-manifold edges), not from the generator's own report.

## 6. Printability (FDM, TPU)

- Gyroid and honeycomb are self-supporting; they are the standard slicer infill patterns. Never place internal supports in a lattice, because they are trapped forever.
- Single-bead walls rely on the slicer's variable-width wall generator. In **Bambu Studio** that is *Wall generator: Arachne*. The maintainer checks it by slicing (acceptance item after C3 export): he confirms the lattice walls come out as single-bead paths with no dropped walls.
- Minimum printable wall thickness for TPU is **not published** (research gap). The ±10 % band around one bead width is our proxy until coupons say otherwise.

## 7. Mesh size

TPMS surfaces cost far more triangles per cell than octet struts. The reviewer's rough expectation is 3–8× per cell; that has not been measured.

- **Measure** triangles, STL and 3MF size, generation time and peak RSS for:
  - every coupon in `data/coupon_sets.json`;
  - a 100 × 100 × 20 mm pad at uniform ρ = 0.15, 0.25 and 0.35, 1 bead;
  - the same pad graded 0.15 → 0.35 across its width.
- Stream like the octet writer does (flat RSS ≈ 2.7 MB).
- Decimation to a stated geometric tolerance is allowed, provided the thickness band in §2 still passes after it.

## 8. Isolation (nothing else moves)

- **Do not** add gyroid or honeycomb to `lattice_generatable_topologies()` or the certifiable set. The Aesthetic and Structural pickers must stay byte-identical until the maintainer rules (Q6).
- Existing octet and organic outputs must stay byte-identical. So must any job without the new block.
- Deterministic: the same job gives byte-identical output.

## 9. The 2-bead question (why coupon set S exists)

**Theory:** if the two beads of a 2-bead wall weld into one solid wall, a 2-bead gyroid is the 1-bead gyroid scaled ×2. It has the same shape and density, so it should give the same curve. The only new physics is the seam: at worst (no bond at all), the wall is **up to ~4× softer in bending** ((2t)³ vs 2·t³).

Gallup 2025's wall-only NinjaFlex coupons (beads side by side) were stiffer than infill coupons at every temperature, so for solid TPU the beads should weld.

**Evidence that it is NOT that simple:** Justino Netto et al. 2024 (*Mechanics of Materials* 195, 105051; PDF in `papers/`) tested almost exactly this case in FDM **PLA**, at the same designed volume fraction (0.17):

| | Wall | Cell | Beads | E (MPa) | Yield (MPa) | Energy (MJ/m³) | Failure |
|---|---|---|---|---|---|---|---|
| a10w08 | 0.8 mm | 10 mm | 2 | 82.1 ± 7.5 | 1.03 | 0.49 | brittle layer-by-layer collapse |
| a5w04 | 0.4 mm | 5 mm | 1 | 65.0 ± 3.7 | 1.61 | 0.93 | plateau |

The 2-bead, large-cell version was **~26 % stiffer, ~36 % weaker and absorbed ~47 % less energy**, and it failed differently. The measured densities differed by ~5 %.

**Confounds, from the reader and the reviewer:**
- The 10 mm cells had only **2 cells across** the 20 mm cube.
- The layer height was not scaled (0.1 mm throughout).
- It is PLA: brittle collapse is a PLA behaviour, and TPU will not crack the same way.

The authors' own summary: "for structures with similar apparent density, larger cells and thicker walls resulted in higher stiffness and lower yield strength and absorbed energy."

**What this means for the build:**
- Same density is a **first approximation for stiffness only.**
- C1 must **not** feed a 2-bead lattice from 1-bead tables as if they were equal. Until coupon set S says otherwise, 2-bead predictions carry the `proxy` band and an "unverified: 2-bead" flag.
- Coupon set S already scales the **whole specimen** ×2 (Ø58 × 25 mm), which removes the cells-across confound Justino Netto had. It keeps 0.2 mm layers, because 0.4 mm layers aren't practical for TPU on a 0.4 mm nozzle. So the layer-height confound remains, and S's result should be read with that caveat.