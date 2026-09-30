# 02 — The squish model

**Plain language:** we don't simulate rubber from first principles; the physics of soft lattices at 20–60 % squash is too hard to get right on an iPad, and no published constants would make it trustworthy anyway. Instead we store **measured squash curves** (force vs. how far in) for each filament, lattice type and density. We look up the right curve for each spot on the part and solve a simple "bed of springs". The answer is only as good as the curves. That is the point: every number traces back to a test.

This is **not FEA** and must never be labelled as certified (00-decisions §4, draft entry item 2).

---

## 1. Inputs

- **Curve set**: entries in the `curve_table.schema.json` shape. v1 has 36 literature entries in `data/iacob2024_curves.json` (varioShore, gyroid + honeycomb, 10–35 %, 190 / 220 / 240 °C).
- **Material + print condition**: `material_id` and, for foaming filaments, one of the offered temperatures. Never interpolate between temperatures.
- **Topology**: gyroid | honeycomb.
- **Relative-density field** ρ(x) over the latticed region.
- **Lattice height** h along the load direction, per column. This is the lattice core between the solid skins.
- **Loads**: regions with force F (N), direction (v1 must be build ±Z), and a load mode (uniform pressure, or rigid flat press; open question Q8).

## 2. What a curve means (read before using Iacob rows)

- Iacob's numbers are **secant moduli**: stress ÷ strain, measured from the origin, at 10 % and 20 % nominal strain. So the known points are σ(0.10) = 0.10·E10 and σ(0.20) = 0.20·E20. The CSV and JSON already carry both.
- Strain is **nominal over the whole 12.5 mm specimen, skins included**. The skins are 4 + 4 layers × 0.2 mm = 1.6 mm of near-solid TPU (≈ 40–50 MPa) against a 0.14–9 MPa core, so they barely compress.
  - If you apply a curve to a part with a **different skin-to-core ratio**, correct explicitly. Core strain ≈ nominal × 12.5 / 10.9, so core stress–strain has E_core ≈ 0.872 × E_nominal.
  - Pick one convention (nominal-with-specimen-geometry, or core), record it in the receipt, and test that the round trip is exact.
- **4th loading cycle, toe removed.** This describes a part after break-in (Mullins softening). A fresh part is stiffer.
- **Nominal infill % is NOT the printed relative density.** This was verified from Iacob's own Table 3 specimen masses: at 190 °C (unfoamed, solid ≈ 1.2 g/cm³), with the 1.6 mm skins subtracted as fully dense. That subtraction is a reviewer estimate.

  | Pattern | Nominal infill | Estimated printed core relative density |
  |---|---|---|
  | Gyroid | 10 / 15 / 20 / 25 / 30 / 35 % | 0.143 / 0.180 / 0.226 / 0.271 / 0.316 / 0.362 |
  | Honeycomb | 10 / 15 / 20 / 25 / 30 / 35 % | 0.165 / 0.236 / 0.286 / 0.341 / 0.396 / 0.446 |

  Values are in the `est_core_relative_density_190C` column and the curve entries.

  **Two consequences:**
  1. A TopOpt gyroid *designed* at ρ = 0.25 corresponds to Iacob's **~20 %** row, not the 25 % row. That is a 76 % stiffness difference at 190 °C (E20 1.46 vs 2.57 MPa).
  2. Honeycomb carries ~20–25 % more material than gyroid at the same nominal %. So part of honeycomb's "1.5–4× stiffer" is just more plastic; at equal *printed* density the gap is roughly 1.5×.

  **Rule for C1:** key literature rows on the estimated core density, not the nominal %. For 220/240 °C the foamed bead density is unknown, so apply the 190 °C nominal→core mapping. The slicer paths are the same and flow compensation targets the same bead width. That is an assumption; flag it. Coupon set A measures the real mapping for generated lattices.
- Low-density gyroid has E20 < E10. The curve flattens between 10 % and 20 %, which is the start of a plateau (walls beginning to buckle). Honeycomb often stiffens instead. Keep both shapes; don't smooth them away.

## 3. Interpolation rules

| Across | Rule |
|---|---|
| Strain, within a curve | Piecewise-linear through (0,0), then each listed point. |
| Strain beyond the last point | Linear extension of the last segment up to `strain_max_measured` (0.25 for Iacob), flagged **extrapolated**. Beyond that: **refuse**. |
| Density, between tabulated densities | Linear in ρ at fixed strain. Iacob report near-linear dependence on infill (correlation > 0.97). σ is strictly increasing in ρ at every strain, in every row (verified). Use the core-density axis (§2), not nominal %. |
| Density, outside the tabulated range | **Refuse.** v1 range on the core-density axis: gyroid ≈ 0.14–0.36, honeycomb ≈ 0.17–0.45. |
| Temperature (foaming) | **Never**. Offer tested temperatures only (R10). |
| Topology | Never. Separate tables. |
| Material | Never, unless the maintainer rules proxies in (Q4). A proxy scales a donor table by the solid-modulus ratio and is tier `proxy`. |

## 4. Inversion: target → density

Per region: σ* = F / A (A = loaded area projected perpendicular to the load), ε* = d / h.

At fixed ε*, σ(ε*; ρ) is monotone increasing in ρ, so solve σ(ε*; ρ) = σ* for ρ by bisection on [ρ_min, ρ_max].
- If σ* is below σ(ε*; ρ_min), even the softest option is too firm.
- If σ* is above σ(ε*; ρ_max), even the firmest option is too soft.

In both cases return **unreachable** with the nearest achievable depth at the stated force. That is the number the user can act on.

Between regions, the density field is blended over a transition length of at least one cell of the larger cell size (03-generators §3). The solver must use the **realised** density field, not the per-region targets, so the transition zones are simulated as built.

## 5. Forward solve (the "bed of springs")

Discretise the latticed region into columns along the load direction. Each column i has footprint a_i, height h_i and curve σ_i(ε) (evaluated at its realised ρ). v1 grades in-plane only, so each column is uniform through its height.

- **Uniform pressure p over a region** (body weight, cushion): ε_i = σ_i⁻¹(p), depth_i = ε_i · h_i. This is closed-form per column; different columns sink by different amounts.
- **Rigid flat press with total force F** (IFD-style): one common depth d with Σ a_i · σ_i(d / h_i) = F. Solve by bisection; the left side is monotone in d.
- **Coupling hook:** a lateral shear term (Pasternak) is reserved with its parameter set to **0** until calibrated (indentation vs full-face coupon comparison). With coupling 0, loads don't spread sideways. That **over-predicts** depth under small patches and at edges, so say it in the UI.

Unloaded columns do not move.

## 6. Displacement field (for the animation)

For a uniform column, vertical displacement varies linearly through the lattice height: u(z) = depth · (z − z_bottom) / h. Skins move rigidly with the column top and bottom. Emit per-vertex displacement for the export mesh (or a sampled field the app can apply) **from the same solve that produces the reported numbers**. The animation must never come from a separate, prettier model.

## 7. Error bands

Show a band, not only a point. Defaults are in `flexible_materials.seed.json` → `error_band_defaults`, reviewer-suggested and maintainer to confirm:

| Tier | Band on depth | Basis |
|---|---|---|
| calibrated | ±20 % | Research: calibrated curves ≈ ±15–25 %. Iacob within-batch SD (3 specimens each) is mostly under 10 %, up to ~20 % on some foamed honeycomb rows. Each entry carries its own `rel_sd`. |
| literature (same material, other printer) | ±40 % | Research: literature curves transferred ≈ ±30–50 %. varioShore is process-sensitive. |
| proxy | ±50 % | Only if Q4 allows proxies. |

Report the band as depth × (1 ± band). If extrapolated, say so next to the band.

## 8. Not modelled (state it; don't hide it)

- Loading-rate effects.
- Creep and compression set.
- Fatigue.
- Temperature of use.
- First-cycle (Mullins) stiffness.
- Lateral load spreading (v1).
- Snap-through or local buckling beyond what's in the curve.
- Bending of the skins.
- Loads not along build Z.

## 9. "Show the physics"

- Plot the curve(s) for the chosen material, temperature, topology and density, with each region's operating point (ε*, σ*) marked.
- Show the tier, the source and the band.
- For foaming filaments, show the three tested temperatures side by side. The non-monotonic ordering is a real, surprising fact the user should see.

---

## 10. Faces, stacks and handover (M12, M13, R11, R13)

- **Loaded face.** A face region (the existing `loads.face_regions` ids) that the user marks as carrying weight. **Load direction** = into the part along the face's area-weighted normal.
- **Face frame (R13).** X = the face's longest direction seen along the load (2D principal axis of the face projected onto the plane ⟂ load); Y = load × X; the user may rotate it in 90° steps. Face coordinates (u, v) ∈ [0, 1]² span the projected face's extent in that frame. Faces whose normals spread more than 30° are flagged (the map is projected along one direction).
- **Stack.** The material swept from the loaded face along the load direction until it leaves the part. The faces where it leaves are the **linked other end** (reported, shown in the UI). Columns of the solve are the stack's rays.
- **One profile per stack.** If two loaded faces' stacks cover the same material along the same axis (e.g. top and bottom both loaded with different profiles) → refuse and name both faces; the user marks one as where it rests.
- **Handover (R11).** Where stacks along different axes overlap (a top stack and a side stack at an edge), each lattice point follows the **nearest loaded face**, blended over **one cell** of the larger local cell size. The receipt reports the handover volume per face pair.
- **Side stacks** (load direction more than 15° from build Z) are gyroid-only and carry the **estimated** tier (proxy band) until the sideways coupon set (SW) is measured. Evidence it's reasonable: gyroid's geometry is cubic-symmetric, and Beloshenko 2021 found printed TPU gyroid much less direction-dependent than honeycomb.

## 11. Loads from stamps (M14)

- The app sends each stamp as a **pressure grid in the face frame** (resolution, cell values in MPa summing to the stated force, and soft | rigid). Core uses the grid as-is.
- **Soft stamp:** each column under the grid gets its cell's pressure; depth per column = h · ε(p; ρ).
- **Rigid stamp:** every column under the footprint sinks the same depth d; solve Σ aᵢ·σᵢ(d / hᵢ) = F by bisection (monotone).
- **Design load:** the stamp chosen for design, or — if none — the weight spread evenly over the face (p = F / A). Columns outside a design stamp take the even-spread pressure so the map still defines their density.
- **Flag** any stamp whose narrowest width is under ~3 local cells: v1 has no sideways spreading, so small stamps are the least accurate.

## 12. Squish maps: curves → target depth (M11, R12)

- Each loaded face holds: deepest squish D (mm), mode, and pen curves as **control points** (u or t in [0, 1], value in [0, 1]; endpoints at 0 and 1; x strictly increasing).
- Curves are evaluated by **monotone cubic Hermite (Fritsch–Carlson)**, clamped to [0, 1] (R12), in core. The app calls core to draw them.
- **Modes:** both axes S = X(u)·Y(v); either axis S = max(X(u), Y(v)); centre → edge S = C(t) with t = distance to the face boundary ÷ the largest such distance (0 at the edge, 1 at the most-inside point).
- **Target depth** per column = S · D. **Target density** per column = the inverse lookup (§4) at that column's design pressure and target strain (depth ÷ stack height).

## 13. "What can be built" (R14)

- Clamp each target depth to the reachable range at that column's pressure (softest ↔ firmest in the table), then smooth with a Gaussian of σ ≈ half the local cell size (density can't change faster than about a cell).
- Report clamped columns (too soft / too firm) and the largest smoothing change per face.
- This is a **heuristic stand-in**. When the lattice generator exists, its realised density field replaces it.
