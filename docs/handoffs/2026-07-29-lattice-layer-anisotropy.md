# 2026-07-29 — Does the certified lattice know which way the layers run?

**Track:** MEASURE-AND-REPORT ONLY. No gate change, no production-code change, no
`materials.json` change. One additive offline harness
(`core/tests/harness/lattice_anisotropy_probe.cpp`, the sanctioned
`lattice_homog_probe.cpp` pattern — programmatic octet, Eigen periodic-BC, NOT wired
into CTest), this report, and `evidence/2026-07-29-lattice-layer-anisotropy/`. The
maintainer decides what, if anything, to do about the finding.

## TL;DR

**No — a certified latticed part does not know which way the print layers run, and it
is not certified against layer-line failure inside the lattice.** The gap is real and,
if anything, wider than the maintainer's hypothesis: it is not that the tensor
*overstates* a computed lattice strength — it is that the lattice region's strength
(layer-line *and* ordinary) is **never gated at all**, and the homogenized tensor that
*is* used (for stiffness / load path) is built from an **isotropic** base and is
**cubic**, so it is structurally incapable of encoding "z is weaker than x/y."

Two independent blindnesses:

1. **Stiffness (what the tensor models).** The octet tensor library (PR 198/237) is
   homogenized on an **isotropic PLA** base and reduced to a **cubic** tensor
   (C11, C12, C44). Cubic symmetry means x≡y≡z: the build axis is invisible. Modelling
   a transversely-isotropic base instead drops the effective build-direction modulus
   by **~13 % (k=0.85) to ~25–29 % (k=0.70)** and breaks cubic symmetry (C33/C11 down
   to 0.66–0.98) — i.e. the shipped tensor **overstates build-direction lattice
   stiffness** by that much, which biases the certification's load path.

2. **Strength (what the gate checks).** `analyze_fixed_design` **excludes every
   latticed voxel from both the von-Mises maximum and the interlayer-tension field**
   (`analyze.cpp:258`), sets `lattice_strength_uncertified = true`, and the acceptance
   gate has **zero dependence on lattice-region strength**. A fully-latticed part
   reports `margin.interlayer = +∞` and is accepted on connectivity alone.
   Layer-line failure of a strut is neither computed nor gated — only flagged, and the
   flag never reaches `report.json`.

**If it were modelled**, the worst-case margin of a latticed region under tension would
move by up to **~45 %** (× k/1.2 at the worst orientation) purely from the interlayer
mode, on top of an already-uncertified **~25–44×** strut/macro stress concentration.
The recommended print orientation is the *same rule as solids* — **build direction
perpendicular to the principal tensile stress** — but it matters *more* for a lattice,
and inside the lattice is exactly where the cert is blind.

---

## G1 — Is the gap real? YES. What the code actually does.

### G1a. The homogenization base is isotropic; the tensor is cubic
- The offline library (PR 198) meshes the octet cell with the **isotropic** production
  element `hex8_stiffness(kE=3500, kNu=0.33, h)` —
  `core/tests/harness/lattice_homog_probe.cpp:60-62, 241-246`; the isotropic D is
  `core/src/fea/hex_element.cpp:104-109` (`D[0][0]=D[1][1]=D[2][2]`, no z term).
- The result is reduced to **three cubic constants** by averaging the
  symmetry-equivalent entries (`lattice_homog_probe.cpp:412-431`), off-cubic residual
  `0.0000` on every octet row. Production stores exactly those three
  (`core/include/topopt/lattice.hpp:38-42`, `core/src/fea/lattice.cpp:88-98`) and scales
  linearly by `Es/3500` (`lattice.cpp:221-226`). **Cubic ⇒ C_xx=C_yy=C_zz; the build
  axis cannot be represented.**
- A transversely-isotropic element whose plane of isotropy IS the FDM layer plane —
  `hex8_stiffness_transverse(E, nu, h, k)`, layer normal z, E_z=k·E, G_yz=G_zx=k·G —
  **already exists** (`hex_element.cpp:114-162`, ROADMAP M4.1) but is **wired into
  nothing**: no caller in `core/src`. `z_knockdown` enters *only* the scalar margin
  (`report.cpp:402-423`) and orientation scoring (`orient.cpp:241-256`), never the
  elastic tensor, and never the lattice.

### G1b. The interlayer margin does NOT cover latticed voxels
- In the composite certification solve, a latticed voxel takes the `is_lat` branch and
  its Cauchy stress is left **zero in the `stress` array** that feeds
  `max_interlayer_tension` — `core/src/simp/analyze.cpp:250-265` (comment at :258:
  *"`stress[idx]` stays zero -> excluded from interlayer"*). It is likewise excluded
  from `max_von_mises`. `lattice_strength_uncertified` is set true whenever any lattice
  voxel exists (`analyze.cpp:380`).
- `max_interlayer_tension` (`orient.cpp` `max_interlayer_tension`) is therefore the
  worst normal traction over **solid voxels only**; `margin.interlayer =
  (z_knockdown·yield)/max_interlayer_tension` (`report.hpp:33`, `report.cpp:402-427`)
  describes the **solid** region.

### G1c. What the maintainer reads (`report.json`) is the solid design
- `report.json` is produced from a **`nullptr` posture** (`run_job.cpp:965-969`), i.e.
  the fully-solid analysis; `VariantReport` has **no lattice fields**
  (`report.hpp:60-107`). The composite/lattice certification runs as a **second** solve
  (`certify_latticed_variant`, `run_job.cpp:445-513`) and is written to a **separate
  receipt** `<prefix>_<vf>_lattice.report.json` and `run_info.lattice`
  (`run_job.cpp:520-558, 1489-1521`). Even that receipt's headline
  `lattice_margin_worst_case` is the **solid-region** margin over the composite field;
  a `note` discloses the strut-strength gap but the margin *field name* does not.
- A **fully-latticed** part → all-zero `stress` → `max_interlayer_tension = 0` →
  `margin.interlayer = +∞` (zero-tension branch, `report.cpp:422-424`) → accepted on
  **load-path connectivity alone**. The gate never depends on lattice-region strength
  (`analyze.cpp:366-380`, and `emit_lattice` never rejects a variant,
  `run_job.cpp:1442-1481`).

**Conclusion (G1):** latticed regions are certified for **stiffness** (against a
layer-blind, isotropic-based cubic tensor) and **not** for strength of any kind —
layer-line included. The maintainer's mechanism ("overstate strength, pass the gate,
break along a layer") lands: a latticed part *can* pass on its solid-region margin
while its struts carry no layer-line certification.

---

## G2 / G3 — Size of the effect (measured)

Harness: `lattice_anisotropy_probe.cpp`. Octet voxelized at **vpc=32**, periodic-BC
homogenization, base material swapped for a **transversely-isotropic** D (the exact
`hex8_stiffness_transverse` algebra) built in the material frame and **rotated** so the
layer normal points along each build direction (the struts never move — each
orientation is the same cell printed a different face down). Full 6×6 effective tensor;
strut-level stress recovered from the corrector fields.

**Instrument validation** (`probe_stdout.txt`):
- H0: my general `B^T D B` element vs production `hex8_stiffness` (isotropic) —
  `max|Δ| = 5.7e-14`.
- Isotropic-base octet reproduces the **production library**: E100/Es = 0.0433 @
  ρ=0.198 (lib 0.0445 @ 0.204), 0.0922 @ ρ=0.313 (lib interp ≈ 0.091); Zener 1.39 /
  1.16 — the harness *is* the PR 198 instrument, ~1 %.
- The **±10 % octet resolution caveat** (PR 198 HR study, struts unconverged at vpc48)
  rides every absolute magnitude below; the **ratios** (E_build/E_iso, C33/C11,
  interlayer/vm) are the robust outputs and cancel most of it.

### G2 — Stiffness tensor change (`stiffness_sweep.csv`)

Effective build-direction Young's modulus, transverse base ÷ isotropic base, and how
far the tensor leaves cubic symmetry (C33/C11), at ρ≈0.20 and 0.31:

| build | k=0.85 | k=0.70 | k=0.55 | C33/C11 @k=0.70 |
|-------|--------|--------|--------|------------------|
| [001] | 0.88 × | 0.75 × | 0.62 × | 0.81 |
| [011] | 0.85 × | 0.71 × | 0.56 × | 0.94 |
| [111] | 0.86 × | 0.72 × | 0.58 × | 1.00 (soft axis off the cell axes) |

**Reading:** the shipped cubic-isotropic tensor overstates the lattice's
build-direction stiffness by **~12–15 % at k=0.85** and **~25–29 % at k=0.70**, and the
true tensor is **not cubic** (C33 ≠ C11). Because the certification solve uses this
tensor for the composite displacement field, an overstated build-direction stiffness
biases how load routes to the (gated) solid regions — a second-order but real effect on
the reported solid margin.

### G3 — Interlayer strength vs build orientation (`interlayer_orientation.csv`)

Fix the macro load (uniaxial tension along [100]); recover the octet strut stress field
once; sweep the **build direction** and read the worst solid-voxel interlayer traction
`max(n·σ·n)` against the (build-independent) peak von Mises. Interlayer **governs** the
margin when this ratio exceeds `z_knockdown` k.

| build vs load angle | max(n·σ·n)/peak_vm (ρ0.20 / ρ0.31) |
|--------------------|-------------------------------------|
| 0° (build ∥ load)  | 1.16 / 1.17  ← **WORST** |
| 15°                | 1.21 / 1.21 |
| 45° (= [110])      | 0.96 / 0.94 |
| 55° (= [111])      | 0.75 / 0.82 |
| 90° (build ⊥ load) | 0.41 / 0.39  ← **BEST** |

- **Worst orientation** (build ∥ tensile load, layer planes across the tension): ratio
  ≈ 1.2, so interlayer governs for every FDM k. Worst-case margin =
  (k/1.2) × the in-plane margin → cut to **46 % (k0.55) / 58 % (k0.70) / 71 % (k0.85)**.
- **Best orientation** (build ⊥ tensile load): ratio ≈ 0.4 < any k ≥ 0.55, so
  interlayer never governs → **zero layer-line penalty**. Swinging the build direction
  from parallel to perpendicular to the load changes the interlayer stress **~3×**.
- The governing rule is **build direction ⊥ principal tensile stress** — the *same* law
  `orient.cpp` already applies to solids (§7 V5). The maintainer's "print on edge"
  intuition is a special case of it. It is *not* the naive "octet has no vertical
  struts so flat is always safe": the driver is build-vs-**load** angle, not
  build-vs-a-fixed-strut.
- Layered on top of all this is the generic **de-homogenization stress concentration**:
  peak strut von Mises is **~25× (ρ0.31) to ~44× (ρ0.20)** the smeared macro stress —
  the reason lattice strength is uncertified at all (Phase 2), independent of layers.
  (Absolute peaks sit at voxelized joint singularities and are mesh-sensitive; the
  *ratios* above are not.)

---

## G4 — Material data: what exists, and that it is assumed, not measured

`core/src/materials/materials.json` carries, per FDM material, a single scalar
`z_knockdown` — the interlayer **strength** ratio:

| | PLA | PETG | ASA | ABS | PC | PA12-CF |
|--|-----|------|-----|-----|----|---------|
| z_knockdown | 0.55 | 0.70 | 0.60 | 0.55 | 0.60 | 0.40 |

- There is **no interlayer stiffness term at all** — one modulus per material. The
  stiffness knockdowns I swept (0.70–0.85) are *illustrative*, not from the file.
- **Provenance: assumed, not measured.** `ARCHITECTURE.md:118-120` states verbatim that
  the values are *"seeded conservative and human-tuned later — agents MUST NOT change
  numeric values, only the human does."* Git history is a single opaque commit
  (`b496df8 "added 1.2b"`). No coupon data, datasheet, or print-settings link is
  recorded. The loader only checks `z_knockdown ∈ (0,1]` (`materials.cpp:352-360`).
- **z_knockdown is used only for scalar margin/orientation scoring, never in any elastic
  tensor, and never for the lattice.** So any future layer-aware lattice margin would
  rest entirely on this **single, guessed anisotropy ratio** — and a margin quoted to
  three digits on a guessed ratio (and a ±10 % octet tensor) is false precision.
  If this is ever wired in, label it as resting on an assumed ratio until real ASA/PLA/
  PETG interlayer coupons at the maintainer's print settings replace it.

---

## Deliverable answers

- **Are latticed parts currently certified against layer-line failure?** No. The lattice
  region is excluded from the interlayer (and von-Mises) checks and flagged
  `lattice_strength_uncertified`; the gate ignores lattice-region strength; the tensor
  that *is* used is isotropic-based and cubic, hence layer-blind.
- **By how much would the number move if anisotropy were modelled?** Stiffness: the
  build-direction effective modulus drops ~13–29 % (k 0.85→0.70), tensor goes
  non-cubic. Strength: worst-case interlayer margin of a latticed region under tension
  falls to ~46–71 % of the in-plane value at the worst orientation (build ∥ load), and
  is unaffected at the best (build ⊥ load) — a swing of ~3× in interlayer stress with
  orientation, sitting on top of a ~25–44× strut/macro concentration.
- **What a recommended print orientation must consider:** orient the **build direction
  perpendicular to the principal tensile stress** so layer planes carry tension in-plane
  — the existing solid rule (`orient.cpp`), but weightier for lattices because the strut
  concentration amplifies the interlayer stress and the lattice interior is where the
  cert is currently blind.

## ★ Gate untouched
No production code, `materials.json`, or gate threshold was changed. This report
measures and reports; the maintainer decides. Recommended NEXT steps (all opt-in, none
taken here): (1) surface `lattice_strength_uncertified` in `report.json`, not just the
side receipt; (2) if layer-aware lattice strength is wanted, it needs the Phase-2
de-homogenization (`2026-07-26-lattice-homog-phase0`) plus real interlayer coupon data,
not the guessed z_knockdown.

## Reproduce
```
cd core
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DTOPOPT_REQUIRE_DEPS=OFF
cmake --build build --target topopt -j8
c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
    tests/harness/lattice_anisotropy_probe.cpp build/libtopopt.a \
    -o build/lattice_anisotropy_probe
TOPOPT_ANISO_CSV_DIR=../evidence/2026-07-29-lattice-layer-anisotropy \
    ./build/lattice_anisotropy_probe
```
Evidence: `probe_stdout.txt`, `stiffness_sweep.csv`, `interlayer_orientation.csv`.
