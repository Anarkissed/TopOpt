# 2026-07-26 — Lattice mode Phase 0: feasibility MEASUREMENT (READ-ONLY)

**Track:** diagnostic / measurement. **NO production code.** One new measurement
harness (`core/tests/harness/lattice_probe.cpp`, the sanctioned `cg_tol_probe.cpp`
pattern — grids built programmatically, standalone build, NOT wired into CTest),
this report, and its evidence directory. No source under `core/src`, no `/app/`,
no fixture, no `materials.json`, no ROADMAP box, no DECISIONS entry, no
ARCHITECTURE edit. `git status` verification in the last section.

**What is new vs handoff [089](089-lattice-tooling-research.md).** 089 answered a
*different* question (lattice as decoration on a TO result, to escape the chunky-rib
floor) and did it by **reading + estimating**. This task answers the maintainer's
*new* framing — **lattice INSTEAD of topology optimization, certified by ONE FEA
rather than a 4-rung × ~150-iteration ladder** — and does it by **building the
lattices and measuring them**. The reframe genuinely changes the affordability
arithmetic (one solve, not ~600), so the old answer is re-derived from measurement,
not restated. Where 089 estimated (e.g. "8–26 M triangles"), this report has a
measured number next to it.

**Solver method + self-check.** Effective stiffness is measured by a
displacement-controlled **uniaxial** test: the two end planes normal to the load
axis are Dirichlet-constrained (0 and δ = 1e-3·L on the axis DOF), three transverse
DOFs pin the in-plane rigid modes, lateral surfaces are **free** (uniaxial-stress →
recovers E, not the confined modulus). End reaction = Σ(K u) on the max-face nodes
via `fea_assembled_apply`; `E_app = F / (A_bbox · strain)`. A_bbox is the full
envelope cross-section, so **E_app/E_solid is the cellular solid's stiffness relative
to its bounding volume** — exactly what the knockdown claims to model.
**Self-check (probe output): a fully-solid block recovers E_app = 3500.0 MPa =
E_solid to 4 digits on all three axes (ratio 1.0000).** The instrument is sound.

---

## STEP 0 — THE REFRAME (answer before any measurement)

**a. It is NOT a faster TO and NOT a finer TO. — CONFIRMED.**
Latticing a 9.4 mm rib yields a latticed 9.4 mm rib. This is unchanged from 089 §0
and it is not what this task turns on, so I do not re-derive it. The *new* framing
sidesteps it: the maintainer no longer wants lattice *on* a TO rib; he wants lattice
*instead of* the TO shape. So "does lattice make ribs finer" is moot — the question
is now purely **can a lattice part be certified honestly and shipped affordably.**

**b. What explicit lattice geometry adds over slicer infill.**
The slicer already fills the interior with gyroid at the user's infill % (Print
Parameters reads "35% Gyroid"), TopOpt never sees or exports that geometry, and the
app models it *only* as a scalar Gibson-Ashby knockdown at the accept gate (089 §1a/§1b;
re-confirmed below in M5). Explicit lattice geometry adds exactly three things:
  1. **Control of topology** (Schwarz-D or octet instead of the slicer's fixed gyroid),
     cell size and grading — the slicer exposes only a density % and a pattern menu.
  2. **A file that already contains the structure**, portable to any slicer/printer
     at 0 % infill, instead of a recommendation the user must re-type.
  3. **The *possibility* of certifying that structure** — but only if the analysis
     describes the lattice, which is the whole question this report measures.

**c. Is (b) "slicer infill with extra steps"?** Partly, and it matters which part.
For the *structural* claim, yes-and-worse: whether the structure is the slicer's
gyroid or a TopOpt-authored gyroid, **the honest margin needs the analysis to see the
lattice**, and today it does not (M5). Authoring the geometry ourselves does not make
the analysis honest — it just moves the same homogenization gap in-house. For the
*geometry* claim (portability, non-gyroid topologies) there is a real, if narrow,
delta. This is **not** an immediate "stop"; the measurements below decide it, and
they decide it against shipping. I did not stop at Step 0.

---

## SCOPE

IN and measured: **Gyroid** (sheet TPMS, matches the slicer), **Schwarz-D** (a
different TPMS topology), **Octet truss** (a strut lattice, for contrast). All three
built programmatically at a calibrated volume fraction (bisected level / strut radius
→ vf ≈ 0.30, the mid of the slicer's 15–60 % band). OUT, deliberately: Voronoi and
stress-aligned graph lattices (harder to generate, do not move the feasibility answer).

---

## M1 — RESOLUTION REQUIRED (convergence study)

**Chosen wall thickness & justification.** At cell L = 5 mm, vf = 0.30, the sheet
gyroid's measured physical wall is **≈ 0.70 mm** (probe: at vpc = 64, median wall =
9 voxels × 0.078 mm). That is ~1.75 × a 0.4 mm extrusion width — a printable
two-line wall, well below the optimizer's 2.5 mm *min-feature* setting (which governs
TO ribs, not lattice walls). It is the thinnest wall this cell/vf produces and the
right stress case for "how fine must the grid be."

**Convergence (E_app/E_solid vs voxels/cell; full tables in
`evidence/.../m1_*.csv`, `probe_stdout.txt`):**

| lattice | vpc where Δ<5% on a doubling | wall voxels there | converged E/Es |
|---|---|---|---|
| gyroid | 32 (32→64: 4.2%; 48→64: 1.3%) | 4 (→9 at vpc64) | ~0.078 |
| schwarz-D | 32 (32→64: 2.8%) | 4 (→7) | ~0.130 |
| octet | 48 (32→64: 9.7%; 48→64: 2.9%) | 6 (→8) | ~0.082 |

**Voxels per wall required: ≈ 4 for the TPMS, ≈ 6–8 for the octet** (struts alias
worse — octet vf swings 0.20→0.39 below vpc 24). This lands on/just above the named
3–4 ceiling. The volume fraction itself only stops aliasing at ~4 voxels/wall, so 4
is a floor, not a comfortable margin.

**What ~4 voxels/wall implies for a real ~200 mm part** (0.70 mm wall,
`evidence/.../m1_part_scaling.txt`):

| voxels/wall | h (mm) | 200×100×150 mm (089 envelope) | 200³ cube |
|---|---|---|---|
| 3 (optimistic) | 0.233 | **236 M vox (44× ceiling)** | 630 M (117×) |
| **4 (measured)** | 0.175 | **560 M vox (104× ceiling), ~1.7 B DOF** | 1.49 B (276×) |
| 6 (octet) | 0.117 | 1.89 B (350×) | 5.0 B (933×) |

The stated ceiling — **Fine + design box ≈ 5.4 M voxels is ALREADY LAN-only** — is
exceeded by **44×–276×**. The implied grid is *far* past it. **That is the answer to
M1: direct resolution of a printable lattice over a real part is 1.5–4 orders of
magnitude beyond the current viable grid, for a single solve.** (Even the optimistic
3-voxel/1.0 mm-wall relaxation is 15–40× over — the conclusion survives a 2–3× error.)

---

## M2 — THE HOMOGENIZATION GAP  (bar: within 10%)

Resolved E/Es (single cell, vpc 32) vs the Gibson-Ashby **f^1.5** knockdown production
already applies (`evidence/.../m2_m6.csv`):

| lattice | vf | resolved E/Es | f^1.5 | **gap** | best-fit exponent p |
|---|---|---|---|---|---|
| gyroid | 0.306 | 0.0816 | 0.169 | **51.7%** | 2.11 |
| schwarz-D | 0.301 | 0.1265 | 0.165 | **23.3%** | 1.72 |
| octet | 0.313 | 0.0902 | 0.175 | **48.5%** | 2.07 |

Even taking the **bulk** value from M3 (stiffer than a single free cell): gyroid bulk
0.091 vs f^1.5(0.258)=0.131 → **30% gap**; schwarz-D bulk 0.123 vs 0.149 → **17% gap**.
**All three fail the 10% bar, and fail in the NON-CONSERVATIVE direction** — f^1.5
predicts 1.2–2.1× *more* stiffness than the lattice actually has. The fitted exponent
is **~2.0 for gyroid/octet** (bending-dominated), not the 1.5 the code assumes; this
is exactly 089 §1c's warning, now measured. **Inside-the-bar the homogenized road
would be open; it is well outside. The existing f^1.5 knockdown cannot carry an honest
lattice margin, and M8 is therefore not a shortcut — it is a new, per-lattice,
validated E(f) law.**

---

## M3 — SCALE SEPARATION  ("the measurement most likely to kill this")

Apparent modulus of a K×K×K free block vs K, at fixed vpc 16 (`evidence/.../m3_*.csv`):

| K cells | gyroid E/Es | schwarz-D E/Es |
|---|---|---|
| 1 | 0.0671 (−27% vs bulk) | 0.1207 (−2.0%) |
| 2 | 0.0824 (−9.9%) | 0.1225 |
| 3 | 0.0873 (−4.5%) | 0.1229 |
| 5 (bulk) | 0.0914 | 0.1232 |

**Cells-per-member to reach 10% of bulk: gyroid ≈ 2–3, schwarz-D ≈ 1.** This is the
one measurement that came out *better* than the named 5–10 ceiling — bicontinuous
TPMS separate fast, so **M3 does NOT kill homogenization.** But apply it honestly:
the project's own ~9.4 mm member at a printable 5 mm cell is **1.9 cells across** —
right at K≈2, where gyroid is still ~10% below bulk and on the non-conservative side.
To buy more cells across the member you must shrink the cell, which shrinks the wall
(~0.35 mm at 2.5 mm cells) and **doubles the M1 grid again**. So M3's verdict is:
scale separation is survivable for TPMS in principle, but at the maintainer's member
size it is marginal, and escaping the margin re-triggers the M1 explosion. The killer
is M1 and M2, not M3.

---

## M4 — GENERATION COST & TRIANGLE COUNT

Marching cubes over a representative volume (`probe_stdout.txt`). Baseline: **shipped
bracket variants are 22k–37k tris / ≤5.6 MB GPU (handoff 134); the viewer budget is
~125k tris (089).**

| cell L | 40 mm test cube (grid) | tris | STL | MC time | → 200×100×150 mm @30% |
|---|---|---|---|---|---|
| gyroid 5.0 mm | 96³ | 1.31 M | 66 MB | 815 ms | **18.5 M tris, 923 MB** |
| schwarz-D 5.0 mm | 96³ | 1.71 M | 85 MB | 279 ms | **24.0 M tris, 1.20 GB** |
| octet 5.0 mm | 96³ | 0.76 M | 38 MB | 122 ms | **10.6 M tris, 531 MB** |
| gyroid 2.5 mm | 192³ | 10.4 M | 521 MB | 5.2 s | **147 M tris, 7.3 GB** |
| schwarz-D 2.5 mm | 192³ | 13.7 M | 683 MB | 2.7 s | **192 M tris, 9.6 GB** |
| octet 2.5 mm | 192³ | 5.8 M | 292 MB | 1.1 s | **82 M tris, 4.1 GB** |

**Where the viewer becomes unusable, from 134's measured table:** a 36,628-tri variant
costs 5.58 MB GPU (linear in tris). At **18.5 M tris one variant is ~2.8 GB of GPU
buffers** — by itself over the ~3 GB iOS per-app jetsam ceiling on an iOS-16 iPad,
before rendering a frame. **Even the 40 mm *test cube* at a printable 5 mm cell is
1.3 M tris — 10× the viewer budget and 35× a shipped variant.** The full part is
150–190× the budget at 5 mm cells and crosses into "cannot be held in memory, let
alone drawn." Lattice output crosses the unusable threshold by 2–3 orders of
magnitude. This confirms — and now measures — 089 §3c.

---

## M5 — WHAT THE EXISTING GATE WOULD COMPUTE (read-only trace; NOT fixed)

Gate ([`minimize_plastic.cpp:992`](../../core/src/simp/minimize_plastic.cpp)):
`margin_effective = margin.worst_case × infill_margin_knockdown(infill_percent)`,
accept iff `≥ margin_stop (1.5)`.

* `margin.worst_case` is the **solid-material** FEA margin (ARCHITECTURE §2; the solver
  never sees a reduced modulus — 089 §1d, re-confirmed).
* `infill_margin_knockdown` ([`:69`](../../core/src/simp/minimize_plastic.cpp)) is the
  scalar `f^1.5`, `f = infill_percent/100`.
* `infill_percent` **defaults to 100** ([`pipeline.hpp:313`](../../core/include/topopt/pipeline.hpp)),
  so knockdown = **exactly 1.0** unless the user moves the slider.

**What f is for an explicitly-generated lattice: undefined by this model.** The
lattice walls **print solid** — a ~0.70 mm wall is ~2 extrusion lines, i.e. solid
perimeters with no infill region; the walls do **not** themselves receive slicer
infill. So the lattice is *not* "the envelope filled at f % uniform infill," which is
the only object `f^1.5` describes.

**What number the gate produces, plainly:** with the default `infill_percent = 100`,
knockdown = 1.0 and the gate certifies `solid_margin ≥ 1.5` — **the margin of the
solid envelope, an object that was never printed.** The real lattice is 5–12× more
compliant (E/Es 0.08–0.13) and correspondingly weaker, so its true margin is far
below that. **The current gate would PASS a lattice part on the strength of a solid
part — a number describing a different object than the file, in the non-conservative
direction.** Even if the user sets f < 100, M2 shows `f^1.5` is the wrong law (real
exponent ~2.0, gap 17–52%) and it is applied to a σ-field computed on solid material.
**Named, not fixed** (per the task).

---

## M6 — ISOTROPY  (bar: >15% needs a tensor)

Effective modulus along x/y/z, single cell (`m2_m6.csv`): **gyroid, schwarz-D and
octet all report 0.0% anisotropy across the three axes.**

**Honest caveat — this is necessary but not sufficient.** All three lattices have
**cubic symmetry**, so Ex = Ey = Ez by construction; a three-*axis* test cannot detect
**cubic (Zener) anisotropy**, whose stiff/soft directions are the face/body diagonals,
not the axes. For the **TPMS** this is fine — gyroid and Schwarz-D are documented
near-isotropic including shear, so a scalar knockdown is defensible (they do **not**
cross the 15% line). For the **octet truss** it is not settled: octet is a classic
cubic-anisotropic lattice (Zener ratio ≠ 1), and its anisotropy is *invisible* to this
axis test. A shear/diagonal probe would be needed and would very likely put octet
**over 15%** → **a scalar knockdown cannot describe octet; it needs a stiffness tensor**,
i.e. a materially larger M8 than a scalar one. **Which cross the line: octet (almost
certainly, pending a shear probe); the TPMS do not.**

---

## THE HONESTY FORK — every candidate classified

| lattice | (i) cosmetic, readout dropped | (ii) resolved FEA | (iii) homogenized | (iv) not shippable honestly |
|---|---|---|---|---|
| **gyroid** | honest but M4-dead: 18.5 M tris / 2.8 GB GPU per variant, off-device | **NO** — M1: 560 M vox / 1.7 B DOF, 104× ceiling, one solve | only via a NEW validated E(f) law (M2 gap 30–52%), scale-sep OK (M3) → **= M8** | — |
| **schwarz-D** | honest but M4-worst: 24 M tris / 9.6 GB STL | **NO** — same M1 wall | same; M2 gap 17–23%, scale-sep at 1 cell → **= M8** | — |
| **octet** | honest, cheapest tris (10.6 M) but still 85× budget | **NO** — M1 + 6–8 vox/wall | **NO as a scalar** — M6 cubic anisotropy → needs a **tensor** M8 | strut lattice with a scalar margin |

No candidate lands in (ii). The TPMS land in (iii)-**gated-by-M8**; octet lands in a
tensor-M8 or (iv). (i) is honest for all three but **defeated by M4 on the target
device**, exactly as 089 predicted — now with a measured 2.8 GB/variant figure.

---

## VERDICT — **NO-GO** for a shippable lattice mode in the current architecture/hardware

Decided by these measured numbers:

* **ROAD A (resolve directly) — CLOSED.** M1: a printable lattice over a 200 mm part
  needs **560 M–1.5 B voxels (44×–276× the 5.4 M LAN-only ceiling), ~1.7 B DOF.** The
  maintainer's reframe ("one FEA, not a 600-solve ladder") is real and I credited it:
  it cuts solve **count** ~600×. But **the binding constraint is per-solve size, not
  count** — one matrix-free CG on 560 M nodes needs tens of GB just for its handful of
  DOF-length vectors (this Mac has 17 GB; the iPad far less). 600× fewer solves × one
  individually-infeasible solve = still infeasible. The reframe moves the wall; it does
  not remove it. Road A is not slow, it is out of memory.

* **ROAD B (homogenize) — NOT OPEN as a Phase-0 shortcut; it IS the M8 milestone.**
  M3 shows scale separation is survivable for TPMS (the predicted killer did not fire),
  so homogenization is not *impossible*. But M2 shows the knockdown production already
  has (`f^1.5`) is wrong by **17–52% in the non-conservative direction** (true exponent
  ~2.0), and M6 shows octet needs a **tensor**. So Road B requires deriving and
  *validating* a new per-lattice E(f) law (and a tensor for octet) — which is precisely
  the "infill homogenization" ARCHITECTURE §2 excludes and the M8 milestone 089 §4
  named. Phase 0's job was to test whether the reframe makes B a shortcut; **it does
  not.**

* **ROAD C (cosmetic, readout dropped) — CLOSED by M4.** Honest if labelled, but
  **18–24 M tris / 0.5–1.2 GB STL at printable cells, ~2.8 GB GPU per variant** — over
  the iOS-16 per-app memory ceiling on its own. Not viable on the target device.

**Bottom line:** the maintainer's new arithmetic (one FEA instead of a ladder) is a
genuine ~600× cut, and it is the right thing to have checked — but the lattice wall
forces a per-solve grid that is 44×–276× past the viable ceiling, so the cut lands on
the wrong axis. **Lattice-as-structure is not shippable today by direct FEA or by the
existing knockdown; the only honest structural route remains M8 homogenization (a §2
amendment + a new validated law, tensor for octet), unchanged in conclusion from 089
but now measured rather than estimated.** A measured NO-GO, offered as the deliverable
the task says it will accept.

---

## BLOCKED-STOP notes

* A **unit-cell** convergence study is entirely runnable on this 6-P-core Mac (M1/M2/M6
  finish in seconds–minutes; the largest single solve here was an 80³ = 512 k-voxel M3
  block). Nothing in Phase 0 hit a memory or time wall. It is the **200 mm-part** solve
  that is unreachable — reported as arithmetic (M1), not attempted.
* No measurement needed a fixture I could not build programmatically; every grid is
  constructed in `lattice_probe.cpp` (gyroid/Schwarz-D level fields, octet strut-distance).
  The one thing this task **cannot** produce is a **real printed-and-tested lattice
  coupon** to anchor the homogenized law empirically — if the maintainer pursues M8,
  that physical calibration (print N gyroid/Schwarz-D/octet coupons at 3–4 volume
  fractions, measure E and yield) is the fixture only he can generate.

---

## FORBIDDEN — compliance

No production code. No `/app/` change. **ARCHITECTURE.md not touched** — §2 is the
thing under question, but amending it is a maintainer act recorded in DECISIONS.md.
**The amendment Road B would require** (for the maintainer to weigh, not for me to
make): §2's "Not a research project in infill homogenization" would have to be relaxed
to admit per-lattice effective-property derivation, with a new validation-gate class
(V1 beam theory cannot certify effective moduli) and — for octet — a stiffness tensor
in the assembly. No fixture, benchmark, `materials.json`, or ROADMAP box was touched.

## VERIFICATION

* **Read-only confirmed.** No file under `core/src`, `core/include`, `/app/`,
  `core/tests/fixtures`, `docs/ARCHITECTURE.md`, `docs/DECISIONS.md`, `docs/ROADMAP.md`
  or `materials.json` was modified. `git status` shows exactly the new, additive files:
  this handoff, `evidence/2026-07-26-lattice-phase0/`, and the measurement harness
  `core/tests/harness/lattice_probe.cpp` (the sanctioned probe location; not wired into
  CTest, mirrors `cg_tol_probe.cpp`). Build artifacts under `core/build/` are untracked
  and were not committed.
* **Reproduce:** from `core/`, `cmake -S . -B build -DTOPOPT_USE_OCCT=OFF
  -DTOPOPT_BUILD_TESTS=OFF && cmake --build build --target topopt -j`, then
  `c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3
  tests/harness/lattice_probe.cpp build/libtopopt.a -o build/lattice_probe`;
  run with `TOPOPT_LATTICE_CSV_DIR` set to the evidence dir.
* **Every number is first-hand.** `evidence/2026-07-26-lattice-phase0/`:
  `probe_stdout.txt` (full run incl. the E_solid=3500.0 self-check), `m1_*.csv`,
  `m2_m6.csv`, `m3_*.csv`, `m1_part_scaling.txt`. The M5 trace and the `infill_percent`
  default are cited to file:line and read directly in this worktree.

## Found in passing (NOT acted on)

The three items 089 flagged (decoupled recommended-infill vs knockdown input;
core/app knockdown copies un-pinned in CI; `mass_grams` is solid mass shown as
"plastic") are all still present and all directly relevant if any lattice/variable-infill
work proceeds. No new defect surfaced. Nothing was touched.
