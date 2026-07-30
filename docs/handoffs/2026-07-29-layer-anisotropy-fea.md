# Layer-line anisotropy in the lattice FEA

**Date:** 2026-07-29
**Task:** put layer-line (FFF transverse-isotropy) into the lattice certification.
**Builds on (both already on main):**
- **PR 245** (`2026-07-29-lattice-layer-anisotropy`) *measured* the gap for octet:
  the tensor is homogenized on an isotropic base + cubic → build-axis invisible;
  the lattice region's strength is excluded from the gate entirely. Its offline
  harness `core/tests/harness/lattice_anisotropy_probe.cpp` already carries the
  TI-base + full tensor-rotation + periodic-homogenization machinery.
- **PR 246** (`2026-07-29-tensor-library-nine`) extended the tensor library to 7
  cubic-certifiable topologies and found **bccz/fccz/reentrant are TETRAGONAL
  (C33≠C11) and REFUSED certification** (`lattice_topology_certifiable()` false).
  So the maintainer's BCCZ is **already gate-refused** — on geometry alone, under an
  isotropic base.

**Verdict:** **BLOCKED-STOP at STEP 1.** The material constants a trustworthy
orientation-dependent *certification* would rest on **do not exist** for the
maintainer's materials (ASA/PETG especially) at his layer height. Certification is
**not** wired in — doing so would manufacture a trustworthy-looking margin on
guessed numbers, the exact failure the task named. There are now **three stacked
gaps**, each of which alone blocks trustworthy certification of a layer-aware
lattice (details in STEP 3):
1. **geometric tetragonal** for z-privileged topologies (BCCZ) — needs a 6-constant
   tetragonal library; PR 246 already scoped and measured it, gate refuses today;
2. **layer anisotropy** — the tensor is layer-blind; this task quantifies the
   orientation swing (below);
3. **the material constants themselves** — absent for ASA/PETG at ~0.24 mm; this is
   the *binding* one, and why STEP 1 stops.

What *was* delivered here: the honest provenance verdict (D1), a **sourced
literature survey** (D2/D3, new — PR 245 asserted "assumed" without the numbers),
an extension of PR 245's octet probe **to BCCZ + a fixed-load orientation
recommendation** (D5/D8), and this synthesis. Gate untouched (B1/B4); the maintainer
decides.

Nothing in `core/src` or `app/` changed. My only new file is one offline harness
`core/tests/harness/lattice_orientation_probe.cpp` (renamed to not collide with PR
245's), not in CTest. `git diff --name-only main` over tracked files is **empty**.

---

## STEP 1 — the material data, and its provenance (D1–D3)

### D1 — what materials.json carries today, and where it came from

`materials.json` carries, per material, **six scalars**:
`youngs_modulus_mpa, yield_strength_mpa, density_g_cm3, z_knockdown, poisson,
family` (`core/include/topopt/materials.hpp:12`; parsed
`core/src/materials/materials.cpp:293`). The **only** anisotropy number is a
single scalar `z_knockdown`:

| material | z_knockdown | material | z_knockdown |
|---|---|---|---|
| PLA | **0.55** | ASA | **0.60** |
| PETG | **0.70** | ABS | 0.55 |
| PA12 | 0.75 | PA12_CF | 0.40 |
| PETG_CF | 0.50 | resins | 1.0 (isotropic) |

There is **no separate interlayer-strength field**. The interlayer strength the
app checks is *derived* as `z_knockdown · yield_strength_mpa`. It enters the
certified margin in exactly one place —
`compute_stress_margin()` (`core/src/settings/report.cpp:402`):

```
in_plane   = yield / max_von_mises
interlayer = (z_knockdown · yield) / max_interlayer_tension     // report.cpp:423
worst_case = min(in_plane, interlayer)
```

where `max_interlayer_tension = max over solid voxels of (n·σ·n)`, `n` = the
build direction (`core/src/orient/orient.cpp:212`, called from
`core/src/simp/analyze.cpp:287`). `z_knockdown` also drives orientation scoring
(`orient.cpp:256`, `knock = 1/z_knockdown − 1`).

**Provenance — it is an ASSUMPTION, and the codebase says so in its own words.**
`docs/ARCHITECTURE.md:118`:

> "Values are seeded conservative and human-tuned later — agents MUST NOT change
> numeric values, only the human does."

There is no measurement, no datasheet, no coupon behind the `z_knockdown` numbers.
This matters **beyond lattices**: *every solid-part interlayer margin the app has
ever reported rests on this single assumed scalar per material.* It is a
reasonable, conservative-intent seed — not a measured constant. (The lattice
*modulus* tensors, by contrast, are measured by homogenization — PR 198 — but
that measurement was on an **isotropic** base and explicitly does **not** cover
z-bonding: see `analyze.cpp:338`, "191/192 measured axial and bending only — NOT
z-bonding".)

There is a second, deeper fact about the model shape. The transversely-isotropic
element `hex8_stiffness_transverse` (`core/src/fea/hex_element.cpp:114`) collapses
the whole anisotropy onto that **one** scalar `k = z_knockdown`:
`E_t = k·E`, `G_t = k·G` — one number governs both the through-layer modulus and
the interlayer shear. Real transverse isotropy needs **five** independent elastic
constants plus **two** strengths (interlayer tensile and shear). The app has one
elastic scalar and one derived strength. (And that element is defined but **wired
into nothing**: the production solve is fully isotropic for solids and cubic for
lattice — confirmed, `hex8_stiffness_transverse` has zero callers in `core/src`.)

### D2 — published transversely-isotropic FFF constants (sourced)

Full survey and every source in
`evidence/2026-07-29-layer-anisotropy-fea/literature-survey.md`. Headlines, each
with its print conditions:

**Interlayer TENSILE ratio (across-layer ÷ in-plane UTS):**

| material | ratio | source | layer height |
|---|---|---|---|
| PLA | **0.44** (XZ/XY) | Bembenek 2022, *Polymers* 14(12):2446 | aggregated 0.12–0.28 mm |
| PETG | **0.38–0.74** | Bembenek 2022 (0.742 matched); OSTI 1909122 (0.38–0.56) | 0.4 nozzle |
| ASA | **0.86–0.90** | Appalsamy 2024, *J. Compos. Sci.* 8(4):121 (single study, apparent moduli, **no print conditions reported**) | unknown |

**Directional elastic constants (best available):**
- PLA: E1=1255, E2=753 MPa, ν12=0.323, ν21=0.214 (Krupnin 2023, *Materials*
  16(22):7229, **layer 0.25 mm**, 215 °C, 100% infill). **No measured G12, no
  Z-tensile.** A PLA G12≈817 MPa exists but only in a paywalled paper (unverified).
- PETG: the only full 9-constant orthotropic set (Romeijn 2022, *Addit. Manuf.*
  60:103145) is **pellet MEX, 5 mm nozzle, 2 mm layers** — unusable as a desktop
  FFF card, and reports no strength.
- ASA: a full orthotropic elastic set was published **once** (Yap 2019, ultrasonic)
  but the numbers are paywalled/absent from the abstract. Open ASA data = in-plane
  E≈1.4 GPa, UTS≈31.7 MPa (Polymers 18(2):302, **layer 0.254 mm**).

### D3 — the interlayer ratio, and how far the sources are from the maintainer

The single ratio that drives everything: **PLA ≈ 0.44, PETG ≈ 0.38–0.74, ASA ≈
0.86–0.90.** Set against the app's `z_knockdown`:

- **PLA 0.55** is **less conservative** than the one clean open PLA datapoint (0.44).
- **PETG 0.70** sits at the **optimistic top** of its measured range (0.38–0.74).
- **ASA 0.60** is **more conservative** than the lone ASA study (0.86–0.90) — but
  that study is a single source with no reported print conditions, so this is not
  reassurance.

**Print-condition distance.** The maintainer prints thick (~0.24 mm layers; the
app already bakes in a 0.45 mm line width = 0.4 mm-nozzle default,
`pipeline.hpp:348`). Most anisotropy literature is at 0.1–0.2 mm; a few points
straddle 0.24 mm (Krupnin PLA 0.25, Polymers ASA 0.254, Bembenek 0.28) but those
are *in-plane* strength/stiffness, **not** interlayer ratios. In-plane strength
falls measurably with thicker layers (Stojković: PLA 32→28.75, PETG 33.5→29.5 MPa
over 0.1→0.3 mm), and interlayer *absolute* strength is worst at thick layers
(El Magri, ASA: best Z at 0.155 mm; layer height the single most influential
parameter). So the maintainer's thick layers sit on the **weak side** of
interlayer bonding — but no source gives a ratio-vs-layer-height curve at 0.24 mm,
so that is an **inference, not a measured number**.

**Note the app captures no layer height at all** — `z_knockdown` is a fixed
per-material scalar, blind to the parameter that dominates interlayer strength.

### BLOCKED-STOP (as the task instructed)

> "if usable constants cannot be sourced for the maintainer's materials at
> anything near his settings, STOP and report what a coupon test would need to
> measure. A certified margin resting on a guessed anisotropy ratio is worse than
> an uncertified one, because it looks trustworthy."

They cannot. A trustworthy orientation-dependent **certification** needs the five
TI elastic constants **and** interlayer tensile+shear strengths at ~0.24 mm for
ASA/PETG/PLA. Open access has: a partial PLA elastic set (no G12, no Z), no usable
FFF PETG elastic set, no ASA Poisson/shear/interlayer-shear at all, and interlayer
tensile ratios with a 2× spread and print-condition mismatch. **So the
certification is not wired in.** STEP 2 below runs anyway — but as a
*sensitivity study on the app's existing assumption*, not as a new certified
number (see "why STEP 2 is still honest").

**What a coupon program must measure** (per material, at the maintainer's actual
layer height / nozzle temp / line width / wall count — because the ratio does not
transfer across those):
1. Interlayer **tensile** strength (Z bars) and in-plane tensile strength → the
   strength ratio that replaces the assumed `z_knockdown` in the margin numerator.
2. Interlayer **shear** strength (currently absent from all open literature for
   all three materials) — the lattice struts fail in interlayer *shear/bending*,
   not just tension.
3. Through-layer modulus E_t and in-plane E_p → the real elastic knockdown (the
   app assumes E_t/E_p = z_knockdown, coupling stiffness to strength with no basis).
4. In-plane shear modulus G12 and G_t → needed for any real strut-bending model.
5. Ideally ν12, ν23 to close the 5-constant tensor.
Minimum viable: (1)+(2)+(3). That turns `z_knockdown` from a guess into a card.

---

## STEP 2 — orientation-dependent homogenization (D4–D6), offline

### Why STEP 2 is still honest under the block

The harness uses the **same single-scalar convention the app already ships**
(`E_t = k·E`, `G_t = k·G`, `k = z_knockdown`, weak axis = build). It introduces
**no new unsourced constant** — it propagates the *existing* assumption into
orientation space. What it reports is the **orientation ranking and the relative
swing**, which are governed by geometry and the qualitative fact `k < 1`; those
are robust to the absolute value of `k`. The *absolute* margin numbers inherit the
assumption's error bar (see B5). This is measure-and-report, exactly like PR 245.

### Method (`lattice_orientation_probe.cpp`)

This **extends PR 245's `lattice_anisotropy_probe.cpp`** — which already carries the
TI base, the full 4th-order tensor rotation and the periodic homogenizer, octet-only
— with (a) a **BCCZ generator** (the maintainer's topology, which PR 245's octet
probe never covered), (b) the **decision framing** below (load fixed, build swept),
and (c) a 3-material sweep. The octet numbers reproduce PR 245's finding as a
cross-check.

Periodic-BC strain homogenization (the proven `lattice_homog_probe` machinery), but
each solid voxel gets a **transversely-isotropic** base tensor whose weak
(layer-normal) axis = the build direction, rotated into the cell frame by a full
4th-order tensor rotation. Reorienting the part on the bed = rotating the build axis
relative to the (fixed) lattice cell and the (fixed) in-service load. For each
orientation it reports the effective moduli and, from the microscopic corrector
stress field under a fixed load, `r = max(n·σ·n)/max(σ_vm)` — the ratio of peak
interlayer tension to peak von Mises — and the interlayer margin **relative to**
in-plane, `k/r` (< 1 ⇒ interlayer governs).

Self-checks (all PASS, printed at run start): our integrator reproduces the
production `hex8_stiffness` / `hex8_stiffness_transverse` **entrywise to 0.0 /
1e-12**; rotating an isotropic tensor is a no-op (3.5e-16); rotating the TI base
z→y is exact; a solid cell homogenizes back to the rotated base (2.8e-15).
Numbers below at vpc=28 (>4 voxels/wall). Cross-checked against vpc=16
(`sweep_vpc16.txt`): the **ranking and the interlayer-governing crossover (~build
30°) are stable**; the worst-case margin is stable (build∥load `k/r` 0.49→0.47), and
the best-case sharpens with resolution (build⊥load `k/r` 2.14→2.82) — peak
micro-stress under-resolves at coarse vpc, as expected. The decision-relevant facts
(ranking, crossover, ~6× swing) do not move.

### D4/D6 — octet: how tensor and interlayer margin move with orientation

Load fixed along part-x; build swept from part-z (0° = "flat", layers ⊥ load) to
part-x (90° = build ∥ load). PLA, k=0.55, rho≈0.34:

| build (°) | E_x=load (MPa) | E_z (MPa) | r = int/vm | margin k/r | governing |
|---:|---:|---:|---:|---:|:--|
| 0 (flat, layers ⊥ load) | 302.3 | 217.4 | 0.195 | **2.82** | in-plane |
| 15 | 288.1 | 218.7 | 0.349 | 1.58 | in-plane |
| 30 | 260.5 | 224.4 | 0.588 | 0.94 | **interlayer** |
| 45 | 237.8 | 237.8 | 0.909 | 0.61 | **interlayer** |
| 60 | 224.4 | 260.5 | 1.118 | 0.49 | **interlayer** |
| 75 | 218.7 | 288.1 | 1.190 | **0.46** | **interlayer** |
| 90 (build ∥ load) | 217.4 | 302.3 | 1.173 | 0.47 | **interlayer** |

**Reading it:** octet's *geometry* is near-isotropic (E swings only ~1.4× with
orientation, symmetric about 45°), so the anisotropy is almost entirely the
**layer effect**. The interlayer margin swings **~6×** (2.82 → 0.46) — from
`k/r ≈ 2.8`
(build ⊥ load, interlayer harmless) to `k/r ≈ 0.49` (build ∥ load, interlayer
governs, delamination at roughly half the load the isotropic check would pass).
**Best = build ⊥ load; worst = build ∥ load.** Same rule as the solid orientation
scorer (`orient.cpp`), but it *matters far more* inside the lattice.

### D5 — the maintainer's BCCZ case: flat vs on-edge

**First, the standing fact:** BCCZ is **already refused certification** on main
(PR 246) — its vertical Z-columns make the effective tensor *geometrically*
tetragonal (C33/C11 up to +160% at low ρ, +42% near solid), which a cubic tensor
cannot represent, so `lattice_topology_certifiable(Bccz)` is false and the gate
throws rather than mis-state the axial margin by ~2.6×. So the maintainer cannot
certify a BCCZ part today at *any* orientation, regardless of layers. The
layer-anisotropy numbers below are the **second, independent** reason, and they
explain *why the print orientation he asked about matters*.

BCCZ (BCC diagonals + vertical Z pillars along cell-z), sideways load (part-x),
PLA k=0.55, on the layer-aware (TI-base) model:

| build (°) | E_x=load (MPa) | E_z pillars (MPa) | r = int/vm | margin k/r | governing |
|---:|---:|---:|---:|---:|:--|
| 0 (**flat**, pillars ∥ build ∥ part-z) | 92.0 | 213.2 | 0.365 | **1.51** | in-plane |
| 15 | 90.4 | 211.2 | 0.354 | 1.55 | in-plane |
| 30 | 86.9 | 210.8 | 0.534 | 1.03 | in-plane |
| 45 (**on edge**, layers diagonal) | 83.3 | 223.2 | 0.805 | **0.68** | **interlayer** |
| 60 | 80.6 | 257.2 | 0.969 | 0.57 | **interlayer** |
| 75 | 78.9 | 308.5 | 1.036 | 0.53 | **interlayer** |
| 90 | 78.3 | 338.5 | 1.032 | 0.53 | **interlayer** |

**The maintainer is right that flat BCCZ is weak sideways — but not for the reason
he thinks, and "on edge" does not fix it.**

- **Flat** (build ∥ pillars ∥ part-z; sideways load part-x): stiffness along the
  load **E_x ≈ 92 MPa** vs along the pillars **E_z ≈ 213 MPa** — the block is
  **~2.3× softer (and weaker) across the pillar axis than along it**. That is a
  real, large weakness and confirms his instinct. But the interlayer margin printed
  flat is the **best** case (`k/r ≈ 1.51`, interlayer *not* governing) — because
  the sideways load is perpendicular to the build direction. The weakness is
  **geometric** (the sideways load is carried by thin BCC diagonals in bending),
  not delamination.
- **On edge** (build ~45° to the struts; same sideways load): sideways stiffness
  is essentially **unchanged** (E_x ≈ 83 MPa — reorienting on the bed does not move
  the cell relative to the load), and the interlayer margin **drops to `k/r ≈
  0.68`** (now governing). So printing on edge makes it **worse**, not better.

The fix for a sideways-loaded BCCZ block is **not** a bed reorientation — it is a
**design** change: orient the *lattice* so its pillar axis runs along the dominant
load (E ≈ 213 MPa, ~2.3× stiffer), while keeping the build direction ⊥ to that
load. Or use octet, whose geometry is near-isotropic.

### D6 — worst/best per topology; is best topology-dependent?

- **Octet:** best build ⊥ load, worst build ∥ load; symmetric, geometry-neutral.
  The orientation choice is purely an interlayer choice.
- **BCCZ:** the best orientation is a **compromise** between two axes that fight —
  geometric stiffness wants the pillars along the load; interlayer wants build ⊥
  load. Yes, **best orientation is topology-dependent** (as predicted: octet has no
  vertical struts, BCCZ is defined by them). A topology with a strong axis forces a
  design decision the near-isotropic topology does not.

**Across the three materials** (full sweep in `anisotropy_sweep.csv`): the pattern is
identical; only the absolute margin rescales with `k`. Octet worst-orientation
interlayer margin `k/r`: **PLA 0.46, PETG 0.58, ASA 0.50** (best ≈ 2.8–3.0); the ~6×
octet swing and BCCZ's ~2.3× sideways softness hold for all three. The material with
the *most* alarming certified move is whichever has the largest gap between its
assumed `k` and reality — i.e. **PLA** (0.55 assumed vs 0.44 measured), and PETG/ASA
which are simply uncalibrated (STEP 1). The physics ranking does not depend on `k`.

---

## STEP 3 — wiring, and why the certification half stays out (D7–D9)

### D7 — the plumbing that *is* ready

`build_dir` already flows end-to-end: `LoadCase::build_dir`
(`loadcase.hpp:67`) ← job `loads.build_dir` (`job.hpp:188`, parsed
`cli/job.cpp:573`) ← Swift `RunModel.buildDirection` → bridge `build_dir_x/y/z`
(`TopOptKit.swift:1060`); variants record the chosen orientation
(`run_job.cpp:1037`). The solid interlayer margin is already a function of it. So
the *input* for orientation-dependent behaviour exists.

### D8 — recommended print orientation (delivered as report, not gate)

**Recommendation: orient so the build (layer-normal) direction is perpendicular to
the dominant in-service tensile stress; for a strut lattice with a defined strong
axis (BCCZ and kin), additionally align that strong axis with the load.** This is
the orientation the harness shows as best, and it coincides with the existing
solid-part rule in `orient.cpp` — the lattice just makes it matter more.

- **Margin at that orientation (octet, PLA):** interlayer `k/r ≈ 2.8` — i.e.
  interlayer does *not* govern; the in-plane check governs, as it does for a solid.
- **What it optimizes:** the interlayer failure mode (delamination), the lattice's
  most orientation-sensitive weakness (~6× swing for octet).
- **What it trades away:** build ⊥ load can raise support volume / print time / Z
  height; and it optimizes for *one* dominant load. Under a uniaxial load the
  harness always finds a safe orientation (octet best `k/r ≈ 2.8`); the danger is a
  **multiaxial** load — significant tension along two axes at once — where turning
  the build ⊥ to one exposes the other. There is then no single safe orientation
  (see D9).

### D9 — reject, don't certify-at-best-angle-with-a-footnote

For a genuinely multiaxial load (tension along more than one axis), *every* build
orientation leaves some axis loaded across the layers, so interlayer can govern at
every angle. The required policy for that case is **rejection**, not certifying the
least-bad angle with a caveat. Stated here as the policy for whenever the
certification is eventually built on measured constants; **not** implemented now,
because the certification is blocked at STEP 1 (and, for BCCZ, already refused by
PR 246). My uniaxial sweep does not itself exhibit an all-angles-fail case — that is
a property of multiaxial loading, noted so the eventual wiring does not skip it.

### The other BLOCKED-STOP (tensor-library restructuring)

> "if orientation-dependent certification cannot be expressed without restructuring
> the tensor library, report the scope before building it."

It cannot be expressed within today's library. Reporting the scope, as instructed —
note main has already done the *first* piece:

1. **The tensor struct is cubic-only, but the gate now distinguishes symmetry.**
   `struct CubicTensor { C11, C12, C44 }` (`lattice.hpp:44`), 3 constants,
   homogenized from an **isotropic** base. PR 246 added
   `lattice_topology_certifiable()` (`lattice.hpp`) and made `lattice_cubic_tensor()`
   **refuse** the tetragonal topologies (bccz/fccz/reentrant) rather than certify
   against a wrong-symmetry tensor. So the *refusal machinery* the final rung needs
   already exists — what is missing is a **tetragonal (6-constant: C11,C33,C12,C13,
   C44,C66) tensor library** to actually certify those topologies. PR 246 already
   **measured** those constants (`evidence/2026-07-29-tensor-library-nine/*.csv`);
   the follow-on it scoped is landing them behind a tetragonal struct.
2. **Layer anisotropy needs orientation, and the rotation code exists only in the
   probes.** A TI base makes even a *cubic* topology's effective tensor
   orientation-dependent (non-cubic once the layer normal tilts). PR 245's and this
   task's harnesses carry the 6×6 tensor rotation; **production has none** — the
   cubic tensor is assembled axis-aligned (`hex_element.cpp`). Production would need
   a rotation path in assembly and stress recovery keyed on `build_dir`.
3. **The strut de-homogenization gap is still open.** Even with a rotated,
   correct-symmetry tensor, the lattice interlayer margin needs the **strut-level**
   stress, which the macro (effective) stress underestimates by a
   stress-concentration factor (~25–44×, PR 245 / `analyze.hpp`). Lattice voxels are
   *excluded* from the interlayer field today for exactly this reason
   (`analyze.cpp:258`, "`stress[idx]` stays zero -> excluded from interlayer").
   Orientation is necessary but not sufficient.

So wiring *certified* layer-aware lattice margin is a multi-part build — tetragonal
tensor library (PR 246 measured it), a build-direction rotation path, a TI base, and
a strut de-homogenization model — **on top of** the missing material constants
(STEP 1). Pieces 1–3 are tractable engineering the codebase is already walking
toward; the constants are not, and they gate the trustworthiness of all of it.
Scope reported; not built.

---

## BARS

- **B1 — LATTICE OFF and SOLID PARTS byte-identical; solid interlayer path
  unmoved.** **I modified zero tracked files:** `git diff HEAD --name-only` is
  empty; `git status` shows only three *untracked* additions — the offline harness
  `core/tests/harness/lattice_orientation_probe.cpp` (not in `libtopopt`, CTest, or
  any shipped binary), this handoff, and the evidence dir. `compute_stress_margin`,
  `max_interlayer_tension`, and the isotropic solve are literally unchanged. (Note:
  `main` continued advancing during this task — PR 245/246, then octet-rows-land —
  so a diff vs `main` is non-empty, but none of those files are mine.)
- **B2 — every constant traceable.** Base E/nu = PLA materials.json values;
  `k = z_knockdown` per material (traced to ARCHITECTURE.md:118, an assumption).
  Every literature number in `evidence/.../literature-survey.md` carries author,
  DOI, and print conditions; unsourced/paywalled numbers are flagged and **not
  used**. No unsourced numbers enter the harness.
- **B3 — how much the certified margin *would* move.** If the maintainer's own
  `z_knockdown` were honoured *with orientation*, a fully-latticed octet region
  loaded with build ∥ its principal tension would see its interlayer margin fall
  to **`k/r ≈ 0.49`× of the in-plane margin** — i.e. the part becomes
  **interlayer-governed and roughly halves** versus the current isotropic lattice
  cert (which reports `margin.interlayer = +∞` for lattice regions today, because
  they are excluded — `analyze.cpp:258`). The move is from "+∞ (uncertified)" to
  "governing and ~0.5×." That is the whole point: today's number is not
  conservative, it is *absent*.
- **B4 — gate never softens.** The certification tolerance is untouched; no gate
  code was modified. Asserted by B1.
- **B5 — residual uncertainty (the error bar on his own numbers).** Two stacked
  uncertainties:
  1. **The assumption itself.** `z_knockdown` vs open literature: PLA 0.55 vs
     measured 0.44 (the app is ~25% **optimistic**), PETG 0.70 vs 0.38–0.74 (app at
     the optimistic edge), ASA 0.60 vs a single 0.86–0.90 study. So a certified
     interlayer margin built on today's `z_knockdown` could be **optimistic by
     ~25% for PLA** and is essentially uncalibrated for PETG/ASA.
  2. **Source disagreement.** The interlayer ratio spans ~0.38–0.74 for PETG
     alone — a **~1.9× spread**. A margin keyed on the low vs high end of the
     literature differs by that factor. Add the thick-layer penalty (inferred) and
     the missing interlayer-*shear* data (the actual strut failure mode).

  **Distinguish two things.** The orientation *ranking and relative swing* (~6× for
  octet; build ⊥ load best) is **robust** — it comes from geometry and `k<1`, not
  the exact `k`, and it reproduces PR 245. That is the trustworthy deliverable. But
  any *absolute certified margin* at a chosen orientation carries the full stack
  above: **easily a factor ~1.5–2× of uncertainty** for PLA (optimistic assumption +
  spread), and for PETG/ASA it is uncalibrated (no full elastic set, no interlayer
  shear). A safety margin is meaningless when its own error bar is a factor of ~2.
  That is why STEP 1 blocks the *number* even though STEP 2 trusts the *ranking*.

---

## Verification (facts, not narrative)

- Self-checks A1–A4 PASS on every run (top of `sweep_vpc28.txt`): our integrator
  reproduces the production element to 0.0 (iso) / 1e-12 (TI); isotropic-rotation
  no-op 3.5e-16; TI z→y exact; solid cell recovers the base tensor 2.8e-15.
- `git diff HEAD --name-only` is **empty** (zero modified tracked files); `git
  status` lists only three untracked additions:
  `core/tests/harness/lattice_orientation_probe.cpp`, this handoff, and
  `evidence/2026-07-29-layer-anisotropy-fea/`. No production file, CMake, or
  material data touched by this task.
- Build: `cmake --build core/build --target topopt` green on merged main; harness
  compiled standalone against `libtopopt.a`; octet numbers reproduce PR 245.

## Evidence

`evidence/2026-07-29-layer-anisotropy-fea/`:
- `README.md` — index + reproduce steps + headline numbers.
- `literature-survey.md` — full sourced survey (D2/D3), every number with DOI +
  print conditions, paywalled/unusable sources flagged.
- `anisotropy_sweep.csv` — machine-readable sweep (material, topology, rho,
  build angle, E along load, E along part-z, r, margin k/r, k, cg_iters), vpc=28.
- `sweep_vpc28.txt`, `sweep_vpc16.txt` — full console tables incl. the four
  self-checks; two resolutions for the trend-stability claim.
- `lattice_orientation_probe.cpp` — copy of the harness source.

## Bottom line for the maintainer

1. Your certified lattice does not know layer direction — confirmed, twice
   (stiffness and strength), and it never will *trustworthily* until you measure
   the constants. The current `z_knockdown` is a conservative-intent **guess**, and
   for PLA it is mildly **optimistic** vs the literature.
2. Orientation matters a lot: **~6× swing** in the interlayer margin for octet
   (k/r 2.82 → 0.46); build ⊥ your main tension is the rule.
3. Your BCCZ instinct is right that flat is weak sideways (**~2.3×**), but it is a
   **geometry** weakness, and printing on edge makes the **interlayer** worse. Fix
   it in the design (pillars along the load), not on the bed.
4. Recommended orientation: **build ⊥ dominant tension, strong lattice axis along
   the load.**
5. To actually *certify* any of this: run the coupon program in the STEP 1
   BLOCKED-STOP list. Until then this stays a report, and the gate stays exactly
   where it is.
