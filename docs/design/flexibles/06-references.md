# 06 — References (with the specific finding each one supports)

**Plain language:** every number in this pack traces to a source here. Each entry gives the link and *what it actually showed*, not just the title. Keys in `[brackets]` match the `source` columns in `data/`.

**Verification status.** Everything below was gathered by two research runs on 2026-09-26 and then transcribed by the reviewer. Where the research run itself flagged doubt, or where the reviewer could not open a page, it says so.

**Standing bar for agents (maintainer rule):** you may not return "not possible / not printable / not viable" without addressing, by name, the sources below that show it *is* possible, and saying why they don't apply.

---

## A. Squish data for printed flexible lattices

- **[iacob2024]** Iacob et al., *Polymer Testing* 137 (2024) 108517 — https://www.sciencedirect.com/science/article/pii/S0142941824001946
  - Material and method: colorFabb varioShore (foaming TPU); **slicer infill** in PrusaSlicer, **0 perimeters, 4 top/bottom layers**, 0.2 mm layers; Prusa MK3S+ with Revo; flow 110 / 72 / 60 % at 190 / 220 / 240 °C; 35 mm/s; fan 70 %.
  - Specimens: Ø29 × 12.5 mm (ISO 7743); 10 mm/min to 25 %; 4 cycles; secant modulus from the 4th cycle with the toe extrapolated.
  - **36 tabulated moduli** (→ `data/iacob2024_varioshore_secant_moduli.csv`), spanning **0.14 → 9.08 MPa (65×)**.
  - Honeycomb is ~1.5–4× stiffer than gyroid. Stiffness is near-linear in infill (R > 0.97) and **non-monotonic in temperature: 190 > 240 > 220 °C**.
  - Hysteresis and incomplete recovery in every cycle. Within-batch SD 3–15 %. Stable after 2 months.
  - **Read in full from the PDF (Nadim supplied it):** title "Compressive behavior of thermoplastic polyurethane with an active agent foaming for 3D-printed customized comfort insoles"; authors Iacob, Popescu, Stochioiu, Baciu & Hadar; doi:10.1016/j.polymertesting.2024.108517; CC BY.
  - Test and print details:
    - 108 specimens, 3 per configuration.
    - Lloyd LRX Plus with a 5 kN load cell; **top and bottom surfaces lubricated**.
    - Stress = force ÷ initial cross-section, strain = deformation ÷ initial 12.5 mm height (nominal, skins included).
    - The 4th-cycle start was extrapolated from the linear part between 0.1·σmax and 0.2·σmax.
    - Bed 0 °C; fan off for the first 4 layers, full from layer 6.
  - Table 2 gives **mean ± SD for every modulus** (now in the CSV). Table 3 gives **specimen density for all 36 configurations**, before testing and 2 months after, plus print times (now in the CSV).
  - Hardness order 190 > 240 > 220 °C (from their ref [20]); SEM shows unfoamed beads at 190 °C and pores up to ~223.5 µm at 220 °C.
  - Deformation was "buckling and bending, rather than cracking or permanent deformations".
  - Their single-subject insole claim is low-evidence: their own ANOVA p = 0.677 / 0.876.
- **[chatpun2025]** Chatpun, Dissaneewate, Kwanyuang, Nouman, Srewaradachpisal & Movrin, *Appl. Sci.* 15, 3916 (2025); preprint verified at https://www.preprints.org/manuscript/202503.0894
  - Polymaker PolyFlex TPU95 **slicer infill** (ideaMaker) at 14–20 %: honeycomb, grid, triangular, cubic, gyroid; Ø28.6 × 12.5 mm; to 50 %; cycles 2–4 analysed.
  - Honeycomb had the highest load at 50 % strain and the largest loop. **Gyroid had the lowest load: softest and springiest.** Figures only.
- **[li2026]** Li et al., *iScience* 29 (2026) 115868 — https://pmc.ncbi.nlm.nih.gov/articles/PMC13186003/
  - FDM gyroid at 30–70 % (the SSRN preprint says 20 % lowest) in eSUN eTPU 95A, Rosh TPU 95A and Xinbo PEBA 85A, printed at 220 °C and 50 mm/s.
  - Plateau at 10–30 % strain; densification beyond 50–60 % at 70 %. **Monotonic in density.** PEBA softest.
  - It is ambiguous whether the gyroid was CAD-designed or slicer infill, so treat it as trend data.
- **[beloshenko2021]** Beloshenko et al., *Polymers* 2021 — https://pmc.ncbi.nlm.nih.gov/articles/PMC8433625/
  - FDM TPU honeycomb vs gyroid: honeycomb +30 % rigidity, +25 % strength, +42 % energy absorbed. Gyroid is less direction-dependent and recovers better.
- **[bates2016]** Bates, Farrow & Trask, *Materials & Design* 2016 — https://researchportal.bath.ac.uk/en/publications/3d-printed-polyurethane-honeycombs-for-repeated-tailored-energy-a/
  - FFF TPU honeycombs at relative density 0.18–0.49 survived **repeated compression to densification without failure**, with energy-absorbing efficiency comparable to closed-cell PU foam.
- **[bates2019]** Bates et al., *Materials & Design* 2019 — https://www.sciencedirect.com/science/article/pii/S0264127518308256 (URL match probable, not confirmed)
  - **Graded** TPU honeycombs: grading significantly changes energy and damping, and lowers peak loads in severe impacts.
  - This is the paper to read for how steep a grade can be.
- **[turnier_trottier2025]** Turnier Trottier et al., *JMMP* 9 (2025) 182 — https://www.mdpi.com/2504-4494/9/6/182
  - **Laser-sintered (not FDM)** TPE300 / TPU1301: BCC, FCC and Kelvin as designed meshes; ASTM D3574 to 75 %.
  - Kelvin > FCC > BCC on energy/comfort; the re-entrant cell buckled and was dropped. Tables in `data/elastomer_lattice_studies.csv`.
- **[dixit_jain2024]** https://pmc.ncbi.nlm.nih.gov/articles/PMC11443119/ — FDM TPU BCC (designed, 10 mm cells). Strength 5.34 → 4.42 MPa as layer height rises from 0.24 to 0.40 mm.
- **[emerald_rpj2021]** https://www.emerald.com/rpj/article/27/11/24/455232/A-comparative-analysis-of-the-compression — FDM TPU infill patterns. 2D patterns buckle elasto-plastically; the authors recommend 5 % gyroid for comfort.
- **[delarosa2025]** https://www.ncbi.nlm.nih.gov/pmc/articles/PMC12073879/ — FFF TPU designed lattices. Open-cell lattices had more print defects, and those defects drove the stiffness scatter.
- **[nazir_supportless]** https://pubmed.ncbi.nlm.nih.gov/36654760/ — FDM TPU. Removing supports from TPU lattices is "very difficult", so self-supporting designs are the answer.
- **[zhang2022]** http://www.scielo.br/j/mr/a/bTgwLNzzpVCG4SfPYWmtpvn/?lang=en — FDM TPU FCC variants (abstract only verified).
- **[polymers2025_reusable_honeycomb]** https://www.ncbi.nlm.nih.gov/pmc/articles/PMC12656569/ (probable match) — TPU 95A honeycombs were reusable over repeated compressions.
- **[scirep2026_gradient_pore]** https://pmc.ncbi.nlm.nih.gov/articles/PMC12992627/ (probable match) — TPU 98A gradient-pore lattice.
- **[materdes2025_constrained_gyroid]** https://www.sciencedirect.com/science/article/pii/S026412752501113X — graded gyroid in TPU. An outer wall adds lateral confinement.
- **[bayreuth_zenodo_2026]** https://zenodo.org/records/20856007 — raw compression data (CC-BY 4.0) for SLS/HSS TPU Weaire–Phelan lattices.
- **[tamkang_ijamt2026]** https://link.springer.com/article/10.1007/s00170-026-19114-1 — PLA vs TPU lattice rankings **reverse**. Rigid-lattice results do not transfer to TPU.

## B. Graded TPMS, cell size and wall thickness (PDFs supplied by Nadim, read in full 2026-09-27; in `papers/`)

- **Justino Netto, Sardinha & Leite**, "Influence of the cell size and wall thickness on the compressive behaviour of fused filament fabricated PLA gyroid structures", *Mechanics of Materials* 195 (2024) 105051, doi:10.1016/j.mechmat.2024.105051.
  - Setup: FDM PLA, 0.4 mm nozzle and extrusion width, 0.1 mm layers. Gyroid **CAD mesh** (not infill), walls 0.8 / 0.6 / 0.4 mm (2 / 1.5 / 1 beads) × cells 10 / 5 / 4 mm in a 20 mm cube. ASTM D1621 at 2 mm/min to 62.5 %.
  - **At equal density, cell size and wall thickness matter separately:** a10w08 (2 beads) vs a5w04 (1 bead), both 0.17 designed volume fraction → E 82.1 vs 65.0 MPa, yield 1.03 vs 1.61 MPa, energy 0.49 vs 0.93 MJ/m³. The large-cell version collapsed brittly layer by layer; the small-cell version showed a plateau.
  - Gibson–Ashby exponents: stiffness 1.24 (r² 0.94), yield 1.78 (r² 0.98). Designed fit: volume fraction = 1.9·(w/a)^0.95.
  - Every print came out 1.1–7.9 % lighter than designed. 1-bead walls had holes at overhangs; 1.5-bead walls had broken toolpaths; 0.8 mm walls were hole-free.
  - Confounds: the 10 mm cells are only 2 across, and layer height was not scaled.
- **Wallat, Altschuh, Reder, Nestler & Poehler**, "Computational Design and Characterisation of Gyroid Structures with Different Gradient Functions for Porosity Adjustment", *Materials* 15 (2022) 3730, doi:10.3390/ma15103730.
  - **Grades only the level-set t at a fixed cell** (per z-slice; constant, linear and quadratic profiles; porosity 0.4–0.8). Simulation only, no printing.
  - Graded designs have higher stress peaks, located on the **high-porosity** side. Linear 0.4–0.5 was ~22 % stiffer than constant 0.5.
  - Per-slice matching produces wall-thickness ripple.
- **Wang, Wang, Zhao, Wu, Feng & Wu**, "Stiffness design method of Gyroid-based functionally graded lattice structures with variable porosity controlled by load path", *Composite Structures* 377 (2026) 119794, doi:10.1016/j.compstruct.2025.119794.
  - **Grades t per 5 mm cell** (skeletal gyroid) from a load-path field, with bilinear interpolation between cells. Volume fraction = 0.5 + 0.3173·t, connected for |t| ≤ 1.4.
  - FDM PLA-CF plates. At matched volume fraction, graded vs uniform: FEA predicted +71.5 % stiffness in 3-point bending, but the **test measured +15.6 %**.
  - Eqs. 14 and 16 contain errors; don't copy them. The field → target → clamp → rescale → interpolate pipeline is reusable.
- **Kedziora, Decker & Museyibov**, "Application of Functionally Graded Shell Lattice as Infill in Additive Manufacturing", *Materials* 16 (2023) 4401, doi:10.3390/ma16124401.
  - **Metal FFF** (Markforged 17-4PH) bicycle crank. Gyroid **thickness** graded in 8 bands (0.5–1.5 mm) at a fixed cell; 1.6 mm skin; 0.35 mm lattice–skin fillets. Final STL ~600 MB.
  - Walls that aren't **multiples of the line width** printed badly (p.13).
  - An anisotropic 18×8×10 mm cell beat the isotropic 10 mm cell at every mass. Mechanics are FEA only; the print came out 11 % light because of missing infill.
- **Still not found:** any published method or test for grading gyroid **cell size at a fixed wall thickness**. There was also a November 2025 "pyramid-shaped TPMS transition" method for blending unit sizes, mentioned in an earlier TopOpt session; the citation was not recorded.
- MSLattice (Al-Ketan & Abu Al-Rub, 2021), a free generator for uniform and graded TPMS, cited via https://arxiv.org/pdf/2506.09321.

## C. Solid printed TPU / constitutive data

- **[gallup2025]** Gallup et al., *Polymers* 2025 (URL as listed by the research run: https://oasis.library.unlv.edu/cgi/viewcontent.cgi?article=1971&context=me_fac_articles — match not confirmed)
  - NinjaFlex **3-term Mooney–Rivlin constants by nozzle temperature**, for infill-only and wall-only coupons, fitted in tension (→ `data/hyperelastic_constants_printed_tpu.csv`).
  - Modulus 8.14 → 17.63 MPa from 225 to 250 °C (infill-only). Wall-only coupons (beads side by side) were stiffer at every temperature. ANSYS validation error 3–5 %.
  - **C10 < 0**: check Drucker stability before any compression use.
- **[reppel_weinberg_2018]** Reppel & Weinberg 2018 (URL as listed: https://journals.ub.ovgu.de/index.php/techmech/article/download/564/540/1187 — match not confirmed)
  - Printed NinjaFlex Ogden N=2, neo-Hookean and Mooney–Rivlin fits. Uniaxial data alone cannot uniquely identify the parameters.
- **[arxiv_2605_21836]** https://arxiv.org/pdf/2605.21836 — 5-parameter Mooney–Rivlin for TPU 85. Units for C20 and C11 unverified.
- **[pires_ist]** https://fenix.tecnico.ulisboa.pt/downloadFile/3378094857519130/ResumoAlargado_PedroPires90344.pdf — a 6-constant Ogden model was stable; neo-Hookean and Arruda–Boyce fitted poorly.
- Raster anisotropy of printed TPU — https://link.springer.com/article/10.1007/s40964-024-00937-x — neo-Hookean fits only the initial region; Ogden and Mooney–Rivlin fit the whole curve.
- **No published hyperfoam constants for foamed printed TPU, and no Prony-series or Mullins parameters for FDM TPU lattices.** This is a research gap.

## D. Foaming filaments and in-print graded foaming

- **[colorfabb_varioshore_tds]** https://colorfabb.com/media/datasheets/tds/colorfabb/TDS_E_ColorFabb_varioShore_TPU.pdf ; help centre https://support.colorfabb.com/hc/en-150/articles/360003021858-VarioShore-TPU
- **[cnckitchen_varioshore]** https://www.cnckitchen.com/blog/testing-colorfabb-varioshore-tpu-foaming-3d-printing-filament — 35 Shore D at 190 °C to 16 Shore D at 220 °C (independent, not peer-reviewed).
- **[prusa_forum_varioshore]** https://forum.prusa3d.com/forum/prusaslicer/which-settings-to-change-to-print-colorfabb-varioshore-tpu-at-different-temperatures/ — community extrusion multipliers (unverified).
- **[arxiv_2607_25326]** https://arxiv.org/pdf/2607.25326 — varioShore expansion onset ≈208 °C; single wall 0.45 → 0.97 mm uncompensated; target Shore → temperature → flow pipeline compiled into slicer projects.
- **[arxiv_2505_08093]** https://arxiv.org/pdf/2505.08093 — most prior foaming work used discrete regions, not continuous gradients.
- TEM-foamable TPE, graded density within one print — https://www.sciencedirect.com/science/article/abs/pii/S2214860422004584 and https://www.researchgate.net/publication/362535216
  - Controlling nozzle temperature *and* flow gave **density ranges up to 0.86 g/cm³ within a single print** (linear, concave and convex gradients).
  - A density vs temperature fit with a Gompertz function reached 0.96 → 0.17 g/cm³ by temperature alone.
- **[esun_tpu_lw]** https://esun3dstore.com/products/tpu-lw ; https://www.esun3d.com/etpu-lw-product
- **[siraya_foaming_guide]** https://siraya.tech/blogs/news/the-ultimate-guide-to-3d-printing-with-foaming-filaments-tpu-pla-and-beyond ; **[siraya_tpu_air_manual]** https://siraya.tech/pages/siraya-tech-tpu-air-user-manual ; **[siraya_peba_air]** https://siraya.tech/pages/siraya-tech-peba-air-70a-95a-user-manual ; **[siraya_roamr_guide]** https://siraya.tech/pages/roamr-tpu-air-hr-85a-user-guide
- **[siraya_range]** Siraya Tech's range lists Flex TPU 85A / 95A / 64D and Rebound PEBA 85A / 95A. No properties were retrieved; read the TDS before offering them. https://siraya.tech ; PEBA Air product page https://siraya.tech/products/siraya-tech-rebound-peba-air-70a-95a-foamed-elastic-filament
- **[bambu_tpu_for_ams_tds]** https://cdn.shopify.com/s/files/1/1339/4265/files/Bambu_TPU_for_AMS_Technical_Data_Sheet.pdf ; **[bambu_tpu_guide]** https://wiki.bambulab.com/en/knowledge-sharing/tpu-printing-guide
- **[bambu_forum_foamy]** https://forum.bambulab.com/t/printing-foaming-tpu-filaflex-foamy-my-first-experiences/63886
- **[carbon_epu41_tds]** https://docs.carbon3d.com/files/technical-data-sheets/tds_carbon_epu-41.pdf (DLS reference only)
- Slicers don't link temperature and flow: OrcaSlicer issue #1163, https://github.com/SoftFever/OrcaSlicer/issues/1163. Cited only as evidence of the gap; the maintainer uses Bambu Studio.

## E. Test standards

- ASTM D3574 (flexible foam; B1 = IFD with a 203 mm foot at 50 mm/min, 60 s hold, force at 25 % and 65 %; support factor = IFD65 / IFD25; C = CFD, full-face to 50 %) — https://www.zwickroell.com/industries/plastics/polymer-foam/astm-d3574-flexible-foam/ ; https://www.admet.com/testing-applications/testing-standards/astm-d3574-b1-indentation-force-deflection-ifd-testing/
- ISO 7743 (the Iacob method); ASTM D575-91 (the Chatpun method); ASTM D395 (compression set); ISO 7619 / ASTM D2240 (Shore).
- **No printed-lattice paper reports results in IFD units.** This is a gap.

## F. Rigid lattices (for the Structural / Aesthetic follow-ons, not needed for the Flexible stage)

- Bean, Lopez-Anido & Vel, *Appl. Sci.* 12 (2022) 2180 — https://digitalcommons.library.umaine.edu/cie_facpub/8/ — homogenized gyroid **slicer infill** in FDM. Zener index 0.95–1.25; FE vs test within 4 % at 50 % density.
- Saleh et al., *Polymers* 14 (2022) 4595 — https://www.ncbi.nlm.nih.gov/pmc/articles/PMC9654767/ — FDM PLA and PLA-CF gyroid, Schwarz D and Schwarz P. Modulus 0.09–0.47 GPa; strength 2.98–13.89 MPa; diamond best.
- SLA TPMS scaling — https://link.springer.com/article/10.1007/s40964-026-01751-3 — Gibson–Ashby exponent n: D 1.78, G 2.29, P 2.20, Split-P 1.96, Lidinoid 3.68.
- Lumpe & Stankovic, *PNAS* 118 (2021) — https://doi.org/10.3929/ethz-b-000457598 — more than 17,000 lattices with homogenized properties.
- Bastek, Kumar, Telgen, Glaesener & Kochmann, *PNAS* 119 (2022) — https://doi.org/10.3929/ethz-b-000520254 and https://github.com/jhbastek/InvertibleTrussDesign — anisotropic truss stiffness dataset. Check licences before redistributing.

## G. Test rig

- CNC Kitchen Open Pull — https://github.com/CNCKitchen/Open-Pull
  - Two NEMA17 14:1 motors, Tr10x2 screws, 5 kN AEP TC4 load cell, HX711, A4988, 24 V 5 A.
  - Built for tension; add compression plates.

## H. Insoles (v2 — out of scope, kept for later)

See `data/v2_insoles_out_of_scope/insole_priors.csv`:
- Pedar normative walking peaks;
- the > 200 kPa offload threshold (Muir 2022, https://pubmed.ncbi.nlm.nih.gov/35987171/);
- the medRxiv diabetic preprint;
- FDA Class I.
