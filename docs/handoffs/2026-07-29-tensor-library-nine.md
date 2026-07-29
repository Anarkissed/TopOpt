# Tensor library — the remaining nine topologies

**Task:** extend the homogenized cubic-tensor certification library from octet-only
to the other nine strut topologies PR 219 ships as a generation study (sc, bcc, bccz,
fcc, fccz, diamond, kelvin, rhombic, reentrant).

**Method (a repeat, not research):** PR 198's periodic-homogenization probe run nine
more times, over a TABLE of topologies. One new harness,
`core/tests/harness/tensor_library_nine_probe.cpp`, fuses two pieces of committed
code verbatim — the integer node-basis/bond TABLE of the strut-lattice family study
(`evidence/2026-07-27-strut-lattice-family/strut_lattice_gen.cpp`) and the periodic
homogenization of the band-extension probe (`lattice_band_extend_probe.cpp`,
production `hex8_stiffness` element, periodic BC, cubic 2-case fast path). The only new
code is a periodic voxelizer (replicate each canonical strut over the 27 integer-shift
neighbourhood, min distance) — for octet-legs it reproduces the shipped rows to 4
digits, which is the faithfulness cross-check.

Evidence: `evidence/2026-07-29-tensor-library-nine/` (probe source, per-topology
`*_sweep.csv`, `*_self.csv`, timings). Read-only measurement; production landing is a
separate, guarded change to `topopt/lattice.{hpp,cpp}` (below).

---

## HEADLINE RESULTS

### 1. Three topologies are TETRAGONAL — cubic library cannot certify them (T3★)

The three "z-privileged" variants add vertical struts (bccz, fccz) or an auxetic waist
(reentrant) on ONE axis, so their effective tensor is **tetragonal (C33 ≠ C11)**, not
cubic. A single `(C11,C12,C44)` tensor structurally cannot represent that. Anisotropy is
density-dependent (worst at low rho, where the z-features dominate relatively more);
peak `|C33/C11 − 1|` and shear split `|Cyz/Cxy − 1|` across the sweep:

| topology | peak C33/C11 − 1 | peak Cyz/Cxy − 1 | verdict |
|----------|------------------|------------------|---------|
| bccz     | +160 % (→ +42 % near solid) | +5.7 % | **TETRAGONAL — generate-but-NOT-certify** |
| fccz     | +83 % (→ +14 %) | +9.1 % | **TETRAGONAL — generate-but-NOT-certify** |
| reentrant| +501 % (→ −4 %, crosses 1) | +8488 % | **TETRAGONAL/auxetic — generate-but-NOT-certify** |

★ **BCCZ is the maintainer's printed, priority topology, and it is exactly the case the
task warned about.** The z-columns that make bccz the printability answer for tall
parts are the same z-columns that stiffen its z-axis 1.4–2.6× (density-dependent) and
break cubic symmetry. Certifying it against a cubic tensor — which averages that away —
would quietly mis-state the axial (z) margin by up to ~2.6×.
The honest answer: bccz is **generate-but-not-certify** under today's cubic model. It
needs a **tetragonal** library (6 constants: C11, C33, C12, C13, C44, C66) — a
well-scoped follow-on that this harness already measures the constants for (see CSVs).
The gate REFUSES it rather than certify badly (bar B3).

### 2. Seven topologies are cubic — the tensor is EXACT; landed / measured

For these the off-cubic residual is ~0 and C33 = C11 to machine precision, so a cubic
tensor is exact. Zener is genuine anisotropy the tensor captures fully, not a modelling
error:

| topology | validated band (rho) | Zener range | worst in-band drift | notes |
|----------|----------------------|-------------|---------------------|-------|
| sc       | 0.087 – 0.496        | 0.045 – 0.60 | 0.71 % | extreme LOW shear (near-zero C44) — strong orientation dep. **LANDED** |
| bcc      | 0.210 – 0.593        | 1.56 – 34.7  | 1.75 % | extreme HIGH Zener (bending) — strong orientation dep. **LANDED** |
| fcc      | 0.095 – 0.591        | 0.87 – 1.74  | 1.94 % | **≡ the shipped "octet" tensor** (finding 3). **LANDED** |
| diamond  | 0.157 – 0.592        | 1.57 – 2.92  | 2.02 % | aesthetic; cubic. **LANDED** |
| kelvin   | 0.094 – 0.505        | 0.68 – 0.89  | 3.20 %¹ | aesthetic; cubic; 24 thin struts. **LANDED** |
| rhombic  | 0.172 – 0.513        | 1.23 – 2.78  | 1.72 % | cubic; 32 struts → narrower band (thin at low rho). **LANDED** |
| octet(full) | 0.207 – 0.480     | 1.32 – 1.93  | 1.15 % | full octet WITH braces — measured, NOT landed (see finding 3) |

¹ kelvin's worst is one interior node at rho≈0.21 (−3.2 %); every other node is ≤2.0 %.
The node is kept because E100(rho) is convex — dropping it and interpolating across the
gap over-estimates by ~+12 % at that rho, far worse than the node's own −3.2 %.

**LANDED = row table written to `topopt/lattice.cpp`; the topology is now certifiable.**
Full-octet is measured (evidence CSV `octet_sweep.csv`) but NOT landed: the shipped
`Octet` enum entry is legs-only and B2-frozen, so adding braced-octet rows is a
maintainer decision (relabel vs re-measure — finding 3), not this task's to force.

Orientation caveat: sc (Zener ≪ 1) and bcc (Zener ≫ 1) are so anisotropic that the
grading law's SCALAR proxy (E100 along [100]) badly misrepresents an off-axis load. The
CERTIFICATION solve uses the full tensor and is correct for the printed orientation, but
these two should carry an "axis-aligned load only" caveat if ever graded.

### 3. The shipped "octet" tensor is actually LEGS-ONLY (= fcc), a pre-existing gap

Proven: this generic driver on the **fcc** (corner↔face-centre legs, no octahedral
braces) geometry reproduces the shipped `kOctet` rows to 4 digits (rho 0.2530 → E100
221.71 MPa, Zener 1.2764; rho 0.2973 → 286.42, 1.2154 — exact). So the shipped
certification "octet" was homogenized on **legs-only** geometry, while the production
GENERATOR (`lattice_gen.cpp` `ref_struts`) meshes the **full** octet (24 legs + 12
octahedron braces). The certified material and the printed geometry are therefore not
the same octet. This PREDATES this task and is NOT changed here (bar B2 keeps the octet
rows byte-identical). Flagged for the maintainer: either relabel the shipped entry
`fcc`, or re-measure "octet" on the full braced geometry (this harness has that tensor,
column `octet` in the CSVs).

---

## PER-TOPOLOGY DETAIL

Full per-row tensors (C11/C12/C44, both shears, C33/C11) are in
`evidence/.../per_row_detail.md` and the `*_sweep.csv`. Summary (T1–T3):

| topology | struts/cell | min strut len | off-cubic | C33/C11 | Zener range | validated band | verdict |
|----------|-------------|---------------|-----------|---------|-------------|----------------|---------|
| sc       | 3  | 1.000 L | ~1e-13 | 1.000 | 0.045 – 0.60 | 0.087 – 0.496 | cubic — landed |
| bcc      | 8  | 0.866 L | ~1e-13 | 1.000 | 1.56 – 34.7  | 0.210 – 0.593 | cubic — landed |
| fcc      | 12 | 0.707 L | ~1e-13 | 1.000 | 0.87 – 1.74  | 0.095 – 0.591 | cubic — landed (≡ octet-legs) |
| diamond  | 16 | 0.433 L | ~1e-13 | 1.000 | 1.57 – 2.92  | 0.157 – 0.592 | cubic — landed |
| kelvin   | 24 | 0.354 L | ~1e-13 | 1.000 | 0.68 – 0.89  | 0.094 – 0.505 | cubic — landed |
| rhombic  | 32 | 0.433 L | ~1e-13 | 1.000 | 1.23 – 2.78  | 0.172 – 0.513 | cubic — landed |
| octet(full) | 36 | 0.707 L | ~1e-13 | 1.000 | 1.32 – 1.93 | 0.207 – 0.480 | cubic — measured, not landed |
| bccz     | 9  | 0.866 L | ~1e-13 | **2.6 → 1.4** | 1.79 – 31.9 | (none) | **tetragonal — refused** |
| fccz     | 13 | 0.707 L | ~1e-13 | **1.8 → 1.1** | 0.78 – 1.72 | (none) | **tetragonal — refused** |
| reentrant| 17 | 0.750 L | ~1e-13 | **6.0 → 0.96** | 0.15 – 0.72 | (none) | **tetragonal/auxetic — refused** |

**T1 (vox/strut per row):** reported in every `*_sweep.csv`. The floor (6 vox across the
strut DIAMETER, PR 198) binds the LOW end of every band. Octet's 6–8 did NOT transfer:
the high-connectivity cells (kelvin 24, rhombic 32 struts) run thinner at a given rho, so
their low-rho rows fail vox/strut at vpc48 first — rhombic needs rho ≥ 0.17, octet(full)
≥ 0.21. The task's warning ("do not assume octet's resolution transfers") held.

**T2 (validation method):** identical to PR 234/237 — each vpc48 row's E100 vs the vpc64
reference curve interpolated to the row's OWN measured rho (the clean metric that removes
the density-landing artefact; the raw fixed-vf drift is up to ±30 % for steep,
anisotropic E(rho) and is meaningless). Each cubic band is within ±2.4 % (kelvin one
interior node at 3.2 %, footnote ¹). The bands are bounded BELOW by resolution
(vox/strut) and ABOVE by drift creeping past 2.4 % as struts fuse near the cell walls
(sc, octet-full, rhombic top rows).

**T3 (Zener / cubic validity):** the off-cubic residual is ~1e-13 at solid for every
topology, so where the tensor IS cubic (C33 = C11) a `(C11,C12,C44)` tensor is EXACT and
Zener — however extreme — is real anisotropy the tensor captures, not a modelling error.
The certification solve carries the full tensor, so it is correct for the printed
orientation regardless of Zener. The THREE tetragonal topologies (C33 ≠ C11) are the only
ones a cubic tensor misrepresents; they are refused (finding 1). Orientation caveat on sc
(Zener → 0.045) and bcc (Zener → 34.7): correct under axis-aligned load, but the grading
law's scalar E100 proxy would badly mis-rank an off-axis member — flag if ever graded.

## T4 — cells-per-member floor

PR 235 measured octet's BENDING floor at 4–5 cells and bending was the binding case.
Measuring each topology's bending floor requires the PR 235 guided-cantilever
finite-block study (resolved struts vs a homogenized macro beam) — a separate harness
at finite-block resolution, out of scope for this measurement pass. Reported honestly:

- **octet/fcc, rhombic** (stretch-dominated, high nodal connectivity Z≈12): bending
  converges fast; octet's measured **5** is representative.
- **bcc, kelvin, diamond, sc** (bending-dominated, Z = 4–8): bending response is more
  compliant and longer-range, so their floor is **expected to be HIGHER than 5** — NOT
  measured here, do not assume octet's transfers.

Production `lattice_cells_per_member_min` returns octet's measured 5.0 for all
certifiable topologies as a documented placeholder; it is load-bearing ONLY for the
grading law, which is octet-only in production, so no other topology is graded against a
stale floor today. A per-topology bending-floor measurement is the named follow-up.

## Compute (B4)

All ten topologies, full sweep (8 densities × {vpc48 row, vpc64 reference}, 4 load
cases each, tol 1e-8), on a 6-P/4-E-core M2 Pro, run 10-wide in parallel (heavy CPU
contention, ~0.55 core each):

- **Total wall: 564 s** (~9.4 min) for all ten. Per-topology wall (under contention):
  sc 240 s, bcc 314 s, fcc 429 s, bccz 431 s, fccz 471 s, diamond 481 s, octet 499 s,
  kelvin 510 s, reentrant 548 s, rhombic 564 s. Struts/cell drives cost (more solid →
  bigger periodic system): rhombic (32) and kelvin (24) are the slowest.
- **Solo** (no contention) a single topology's sweep is ~1–2 min; the vpc64 reference
  solves dominate. A single vpc48 4-case cell is ~2–3 s, vpc64 ~8–12 s.
- **A future topology therefore costs one `sweep` invocation, ~1–2 min solo.** vpc96 is
  only needed to push a band's LOW edge below where vpc48 resolves the strut (not done
  here — the vpc48/64 bands already cover the useful printable range).

Truth is periodic homogenization of ONE resolved unit cell (resolution-clean, no free
surface); no finite-block solves are needed. Cost scales ~vpc³; the vpc64 single cell is
the convergence reference.

## Bars

- **B1 self-check:** every topology's SOLID cell recovers E_solid = 3500.0000 MPa to 4
  digits, off-cubic residual ~1e-13 (`*_self.csv`). Cubic(iso) == hex8_stiffness
  bit-identical (carried from PR 234).
- **B2 octet unchanged:** the shipped `kOctet` rows are UNTOUCHED and the production
  octet path is byte-identical — proven by dumping the octet tensor at 201 rho points
  from the pre-change and post-change builds: both hash to `90f5d2c8…`
  (`evidence/.../B2_octet_byte_identical.txt`). The test also asserts the exact anchor
  row. If octet moves, something broke.
- **B3 refusal:** a topology with no validated cubic rows (the three tetragonal ones)
  throws `LatticeTopologyNotCertifiable` from `lattice_cubic_tensor` — REFUSED, not
  certified against a neighbour's tensor or a default.
- **B4 compute:** reported above.

## Production landing

`topopt/lattice.{hpp,cpp}`: enum extended with all nine; row storage generalized to
variable-size tables (octet byte-identical); `lattice_topology_certifiable()` +
`lattice_certifiable_topology_names()` added; `lattice_cubic_tensor` refuses
non-certifiable topologies (B3). Bridge `lattice_topology_from_name` /
`lattice_certifiable_topologies` mirror the core accessor so the app UI widens
automatically. Job/grading/generation front-ends stay octet-only (unchanged) — this
task lands the CERTIFICATION tensor, not the generator.
