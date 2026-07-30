# FFF transversely-isotropic property survey — ASA / PLA / PETG

Provenance rule: every number is transcribed from a named source at its stated
print conditions. "Not reported" means the source omits it. Nothing interpolated.
Paywalled/Cloudflare-blocked full texts are flagged and reported from
abstract/metadata only. This feeds a *certified* margin, so unusable numbers are
called out, not smoothed over.

## PLA

| Source (DOI) | Constants (verbatim) | Print conditions |
|---|---|---|
| Krupnin et al. 2023, *Materials* 16(22):7229, 10.3390/ma16227229 | Tensile E1=1255 MPa, E2=753 MPa; ν12=0.323, ν21=0.214. Compression E1=2609, E2=920. **E2/E1=0.60**. G12 not a single value; **Z-tensile not reported** | Raise3D Pro2, PLLA. **Layer 0.25 mm**, 215 °C, bed 60 °C, 40 mm/s, 100% infill, raster 0–90° in 15° steps. Line width, perimeters n/r |
| Bembenek et al. 2022, *Polymers* 14(12):2446, 10.3390/polym14122446 | UTS: XY 21.699, XZ 9.548, YZ 15.452 MPa. **Interlayer XZ/XY = 0.44** (YZ/XY=0.71). Modulus/Poisson/shear not reported | Layer 0.12/0.20/0.28 mm, 0.4 nozzle, wall 1.2 mm, 5 top/bottom, 60/30 mm/s, 180–220 °C, infill 0–100%. **Averaged across temp/infill sets** — ratio more reliable than absolutes. Bed, raster, line width n/r |
| Boztepe & Haskul 2026, *Polymers* 18(2):243, 10.3390/polym18020243 | PLA+: E=3.06 GPa, UTS 41–43 MPa, ν=0.35. In-plane single orientation; no Z/G12/anisotropy | Layer 0.2 mm, width 0.4 mm, 210 °C, bed 60 °C, 25 mm/s, 100% grid |
| Stojković et al. 2023, *Materials* 16(13):4574, 10.3390/ma16134574 | UTS by layer: 0.1→32, 0.2→30.19, 0.3→28.75 MPa (in-plane). Thicker → weaker | 210 °C, bed 60 °C, 50 mm/s, 75% cubic, wall 0.6 mm. Orientation/raster/width n/r |
| "PLA DIC+FEM" S0167663622002708 — **UNVERIFIED (paywall)** | G12 = 817 MPa (45° off-axis), TI treatment | Print conditions unknown. **Do not certify on this.** |
| Song et al. 2017, *Mater. Des.* 123:154, 10.1016/j.matdes.2017.03.051 — **paywall** | Full TI set exists; abstract only (KIC 5 vs 4 MPa·√m ext/trans). Elastic numbers not retrievable | — |

Best open PLA: Krupnin (E1,E2,ν12,ν21 at 0.25 mm) — **no measured G12, no Z-tensile**.

## PETG

| Source (DOI) | Constants (verbatim) | Print conditions |
|---|---|---|
| Romeijn et al. 2022, *Addit. Manuf.* 60:103145, 10.1016/j.addma.2022.103145 — **PELLET MEX, not filament** | Full 9-const orthotropic: E1=1898.7, E2=1272.4, E3=1894.8; ν12=0.401, ν23=0.373, ν13=0.461; G12=748.8, G23=685.5, G13=611.7 MPa (G from 45° off-axis, **not directly measured**). E2/E1=0.670. **No strength** | Pellet robotic MEX, **5 mm nozzle, 2 mm layer**, 220 °C, enclosure 38 °C, raster 0°, solid. **NOT desktop FFF**; E3≈E1 is a deposition artefact |
| Bembenek et al. 2022, 10.3390/polym14122446 | UTS: XY 19.265, XZ 14.298, YZ 16.482 MPa. **Interlayer XZ/XY = 0.742** (YZ/XY=0.856) | (as PLA row) |
| Anwer et al., OSTI 1909122 | X UTS = 52 MPa (75% infill, 240 °C); Z 20–29 MPa; anneal → 61. **Z/X ≈ 0.38–0.56** | ASTM Type V, wall 0.76 mm, 235/240/245 °C, 0.4 nozzle, infill 25/50/75%. Layer/bed/speed/raster in unretrieved Supp. |
| Stojković et al. 2023, 10.3390/ma16134574 | UTS by layer: 0.1→33.52, 0.2→30.37, 0.3→29.45 MPa (in-plane) | 235 °C, bed 73 °C, 50 mm/s, 75% cubic, wall 0.6 mm |
| Frontiers Bioeng. 2025, 10.3389/fbioe.2025.1549191 | UTS 51–52 MPa; no orientation split | Layer 0.12 mm, width 0.77 mm, 240 °C, bed 90 °C, 25.75 mm/s, 100% lines, raster 0° |
| RSM PETG, PMC12694470 | UTS 43.09, yield 21.01 MPa, E max 1.18 GPa; 0° strongest, 45° weakest | Layer 0.1 mm inner, 240 °C, bed 75 °C, 30 mm/s, 50% infill, 0.4 nozzle |

**No usable full 5-constant TI elastic set for filament FFF PETG.** Only tensor is
pellet MEX (unusable). Interlayer *shear* for neat PETG: not found.

## ASA

| Source (DOI) | Constants (verbatim) | Print conditions |
|---|---|---|
| Appalsamy, Hamilton, Kgaphola 2024, *J. Compos. Sci.* 8(4):121, 10.3390/jcs8040121 | Solid 100%: E flat=1236.88, side=1351.66, upright(Z)=1319.70 MPa; UTS flat=39.07, side=40.88, upright(Z)=35.24 MPa. **Interlayer upright/flat=0.90, upright/side=0.86.** E_Z/E_inplane ≈0.98–1.07. No Poisson/shear. **Sparse-infill data must not be used as a ratio.** | Stratasys Fortus 900mc, ASTM D638. **Layer height, temps, speed, width, raster, perimeters: NONE reported.** Moduli look apparent/crosshead (low for ASA ≈2 GPa) — caveat |
| Polymers 18(2):302, 2026, 10.3390/polym18020302 | E=1423±46 MPa, UTS=31.7±0.3 MPa, ε_ult 11.2%. In-plane only. No Poisson/shear/Z | Stratasys Fortus 450, **layer 0.254 mm**, 100% infill, 250 °C, platform 100 °C, raster ±45° |
| Głowacki et al. 2024, *Polymers* 16(13):1823, 10.3390/polym16131823 | UTS = 16.82±0.31 MPa | Zortrax M200 Plus, 100% linear. Layer/temps/speed/orientation n/r |
| El Magri et al. 2022, *Polym. Eng. Sci.* 10.1002/pen.25891 — **paywall** | Dedicated Z study. Best Z at 270 °C, 60 mm/s, **0.155 mm layer**; layer height most influential; Z ≪ X–Y. No MPa in abstract | abstract only |
| Yap et al. 2019, *IJCMSE* 8(1):1950002, 10.1142/S2047684119500027 — **paywall** | The one full orthotropic ASA elastic set (ultrasonic). Numbers not in abstract | abstract only |

**ASA is the thinnest.** No Poisson, no G12, no interlayer shear anywhere open.

## Summary

**Interlayer TENSILE ratio (across ÷ in-plane):** PLA **0.44** (Bembenek), PETG
**0.38–0.74**, ASA **0.86–0.90** (single study, apparent moduli, no conditions).
Not directly comparable across sources (different orientation conventions,
infills, printers).

**vs the app's z_knockdown:** PLA 0.55 (app less conservative than 0.44), PETG 0.70
(top of range), ASA 0.60 (more conservative than the lone 0.86–0.90 study).

**Layer height:** most work at 0.1–0.2 mm; a few straddle 0.24 (Krupnin 0.25, ASA
0.254, Bembenek 0.28) but in-plane only. In-plane strength falls with thicker
layers (measured); interlayer *absolute* strength worse at thick layers (El Magri);
**no ratio-vs-layer-height curve found** — thick 0.24 mm on the weak side is an
inference.

**Full 5-constant TI elastic datasets:** PLA partial (no G12, no Z); PETG none
usable for FFF; ASA none open. Interlayer *shear* strength: absent for all three.
Any TI elastic model for FFF PETG/ASA today is **assumed, not measured.**

### Sources (URLs used)

Open / verified:
- https://pmc.ncbi.nlm.nih.gov/articles/PMC10673164/ — Krupnin 2023 PLA
- https://pmc.ncbi.nlm.nih.gov/articles/PMC12845914/ — Boztepe & Haskul 2026 PLA+
- https://pmc.ncbi.nlm.nih.gov/articles/PMC9230522/ — Bembenek 2022 PLA+PETG
- https://pmc.ncbi.nlm.nih.gov/articles/PMC10342851/ — Stojković 2023 PLA+PETG
- https://www.mdpi.com/2504-477X/8/4/121 — Appalsamy 2024 ASA
- https://www.mdpi.com/2073-4360/18/2/302 — ASA/PA12/PC 2026
- https://www.mdpi.com/2073-4360/16/13/1823 — Głowacki 2024 ASA
- https://opus.lib.uts.edu.au/bitstream/10453/166023/2/Binder1.pdf — Romeijn 2022 (pellet PETG)
- https://www.osti.gov/servlets/purl/1909122 — Anwer PETG
- https://www.frontiersin.org/journals/bioengineering-and-biotechnology/articles/10.3389/fbioe.2025.1549191/full — PETG
- https://pmc.ncbi.nlm.nih.gov/articles/PMC12694470/ — RSM PETG
- https://pmc.ncbi.nlm.nih.gov/articles/PMC9572911/ — Xu 2022 shear (PA12 only)

Paywalled / inaccessible (flagged, not used):
- https://www.sciencedirect.com/science/article/abs/pii/S0264127517302976 — Song 2017 PLA full TI
- https://www.sciencedirect.com/science/article/pii/S0167663622002708 — PLA G12=817 (unverified)
- https://doi.org/10.1002/pen.25891 — El Magri 2022 ASA Z
- https://doi.org/10.1142/S2047684119500027 — Yap 2019 ASA full orthotropic
- https://www.sciencedirect.com/science/article/pii/S2238785422020361 — interlayer shear multi-polymer
