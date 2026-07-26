# 2026-07-26 — Does the f^1.5 knockdown hold on a REAL PRINTED PART? (MEASUREMENT)

**Track:** diagnostic / measurement. **NO production code, NO default changed**
(bar K5). One new measurement harness
([`core/tests/harness/knockdown_probe.cpp`](../../core/tests/harness/knockdown_probe.cpp),
the sanctioned `cg_tol_probe.cpp` / `lattice_probe.cpp` pattern — grids built
programmatically, standalone build, NOT wired into CTest), this report, and its
evidence directory. No `core/src`, no `/app/`, no fixture, no `materials.json`,
no benchmark, no ROADMAP box, no DECISIONS/ARCHITECTURE edit. `git status` in the
last section.

**What is new vs handoff [2026-07-26-lattice-phase0](2026-07-26-lattice-phase0.md).**
184's M2 measured the f^1.5 knockdown against a **free gyroid block** at vf≈0.30
and found it non-conservative by ~2×. That block is *not what prints*. A real part
is slicer infill wrapped in **solid wall loops** (perimeters parallel to the load)
and **top/bottom shell layers**. The side walls are continuous solid columns that
carry axial load **in parallel** with the core — stiffness the pure-infill law
omits — so 184's number may not transfer. This report **builds the wall-and-core
specimen, resolves it, validates the composition, and carries the worst case to
the accept gate.**

---

## TL;DR — the answer, with the sign stated

**f^1.5 does not have one verdict; it has a SIZE-DEPENDENT one, and that is the
finding.**

1. **On the bare infill core (184's object): f^1.5 is NON-CONSERVATIVE**, by
   **1.5–1.8×** across the whole 15–60 % band (fitted exponent ≈ **2.0**, not
   1.5). 184 reproduced and extended — not an artifact of the single vf it used.
2. **The solid walls rescue SMALL parts.** A real printed part's side walls are a
   large fraction of a small cross-section (φ_wall = 4t(W−t)/W² = **0.68 at
   W=10 mm, 5 loops**), so a small part is **much stiffer** than f^1.5 assumes —
   f^1.5 is **CONSERVATIVE** there (assumed/measured as low as **0.08**). *For
   small parts, 184's alarm IS a free-block artifact.*
3. **The rescue vanishes with size.** φ_wall → 0.04 at W=200 mm, so a large part
   → the bare core → f^1.5 non-conservative again. There is a **crossover width
   W\*** below which f^1.5 is safe and above which it is not.
4. **Where it bites (K4):** at the default **5 wall loops**, W\* is **~41 mm at
   60 % infill, ~98 mm at 30 %**; at **3 loops**, **~25 mm / ~59 mm**. The
   maintainer's ~200 mm parts are **past W\* for essentially the whole infill
   band** — squarely in the non-conservative region.
5. **The decision number (K3):** for a part the gate certified at margin **exactly
   1.5**, the true margin at the worst point (**200 mm, 30 % infill, 3 wall
   loops**) is **≈ 1.0** (0.98 at measurement resolution, ~1.04 bulk-corrected) —
   **the 1.5 safety factor is fully consumed**. At the default 5 loops the worst
   200 mm point is **~1.09–1.13** (a ~25 % erosion). Parts ≤ 100 mm keep margin
   ≥ ~1.2.

**Verdict: NOT an all-clear and NOT a false alarm.** f^1.5 is safe for small
parts and unsafe for large thin-walled ones. The gate has no size term, so it is
optimistic for exactly the large parts the reframe targets. **This is a
measurement that produces a decision; the decision (add a size/shell-aware
knockdown, or bound the certifiable part size) is the maintainer's — not made
here.**

---

## METHOD + SELF-CHECK (bar K1)

**Instrument.** Effective axial stiffness via the displacement-controlled
**uniaxial** test `lattice_probe.cpp` validated: two end planes Dirichlet-
constrained (0 and δ = 1e-3·L on the axis DOF), three transverse DOFs pin the
rigid modes, lateral faces free (uniaxial-stress → recovers E). End reaction =
Σ(K u) over the max-face nodes via `fea_assembled_apply`; `E_app = F /
(A_bbox·strain)`, A_bbox the full envelope, so **E_app/E_solid is stiffness
relative to the bounding volume** — exactly what the knockdown claims to model.
Solved with `fea_solve_mgcg` (multigrid-preconditioned CG; drop-in accelerator,
same converged field). PLA E=3500 MPa, ν=0.33 (`materials.json`).

**SELF-CHECK (probe output, K1):** a fully-solid 16³ block recovers
**E_app = 3500.0000 MPa = E_solid to 4 digits on all three axes (ratio 1.000000)**.
The instrument is sound. (`evidence/.../probe_stdout.txt`.)

**Specimen.** A K×K-cell box (edge W = K·5 mm), solid where any of: within t_cap
of the z=0/z=W planes (**shell layers**, 5·0.20 mm), within t_wall of an x/y side
plane (**wall loops**, loops·0.45 mm), or the gyroid |field| < calibrated level
(**infill core** at fraction f). Load axis z, so the side walls run the full
height as continuous parallel columns — the real load path.

**One honest instrument limit, disclosed.** To keep every solve seconds-to-
minutes (the porous cores are not multigrid-coarsenable — `used_mg=0` throughout —
so CG runs 200–1700 Jacobi iterations), the sweep runs at **vpc=16**
(h=0.31 mm, ~2.2 voxels across the ~0.70 mm gyroid wall), coarser than 184's
<5 %-converged vpc=32. The **core resolution check** (`A0_core_resolution.csv`)
quantifies the resulting bias: bare gyroid at f≈0.30 reads E/Es = 0.0672 (vpc16),
0.0758 (vpc24), **0.0816 (vpc32 — matches 184's 0.082 exactly)** at single cell,
and 0.0824 (vpc16) → **0.0904 (vpc24) → 0.0987 (vpc32)** at K=2. So **vpc16
under-reads the core E by ~10 % vs the vpc≥24 bulk.** This makes Part C/D mildly
**pessimistic** on the core (larger apparent non-conservatism); the bulk-corrected
bracket is given at the worst point. **The Voigt validation is immune to it** —
it uses a core measured at the *same* vpc.

---

## A — THE CORE LAW across the whole infill band (`A_core_law.csv`)

Bare gyroid core (no walls), K=2, vpc=16. Because the coarse grid cannot render a
wall thinner than ~0.19 vf, the calibrator overshoots the two lowest targets
(f=0.15 and 0.20 both land at **vf=0.1875**); the honest comparison is therefore
**E vs (measured vf)^1.5**, which removes the calibration confound. Both columns
are first-hand (vf and E are measured; vf^1.5 is arithmetic).

| target f | measured vf | E_core/Es | vf^1.5 | **f^1.5/E (over-prediction)** | fit exponent p | sign |
|---|---|---|---|---|---|---|
| 0.15 | 0.1875 | 0.04595 | 0.0812 | **1.77×** | 1.84 | NON-CONS |
| 0.20 | 0.1875 | 0.04595 | 0.0812 | 1.77× | 1.84 | NON-CONS |
| 0.25 | 0.2344 | 0.07181 | 0.1135 | **1.58×** | 1.82 | NON-CONS |
| 0.30 | 0.2578 | 0.08236 | 0.1309 | **1.59×** | 1.84 | NON-CONS |
| 0.40 | 0.4062 | 0.15437 | 0.2589 | **1.68×** | 2.07 | NON-CONS |
| 0.50 | 0.5000 | 0.22100 | 0.3536 | **1.60×** | 2.18 | NON-CONS |
| 0.60 | 0.6172 | 0.32455 | 0.4849 | **1.49×** | 2.33 | NON-CONS |

**The Gibson-Ashby f^1.5 over-predicts the bare gyroid core's stiffness by
1.49–1.77× (mean ~1.6×) at EVERY density; the real exponent is ~2.0.** This is
184's result, now across the whole band the app offers, and it is the **large-part
limit** of the printed part (§C). Sign: **non-conservative everywhere** on the
bare core.

---

## B — THE COMPOSITE: direct resolution + Voigt validation (`B_composite.csv`)

Wall-and-core specimens, DIRECTLY resolved. `E_core/Es` is a MATCHED bare-core
solve (same K, vpc, with the same caps), so `modelΔ` isolates the wall-composition
assumption; `asm/meas = f^1.5 / E_meas` is the **gate error, with sign**.

| K | W mm | loops | infill | φ_wall | E_core/Es | **E_meas/Es** | E_Voigt | modelΔ | f^1.5 | **asm/meas** | sign |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 2 | 10 | 0 | 0.15 | 0.00 | 0.0622 | 0.0622 | 0.0622 | — | 0.0581 | 0.93 | CONS |
| 2 | 10 | 5 | 0.15 | 0.68 | 0.0622 | **0.7182** | 0.7033 | −2.1 % | 0.0581 | **0.08** | CONS |
| 2 | 10 | 0 | 0.30 | 0.00 | 0.1085 | 0.1085 | 0.1085 | — | 0.1643 | 1.51 | NON-CONS |
| 2 | 10 | 5 | 0.30 | 0.68 | 0.1085 | **0.7321** | 0.7179 | −1.9 % | 0.1643 | **0.22** | CONS |
| 2 | 10 | 5 | 0.60 | 0.68 | 0.3716 | 0.8225 | 0.8012 | −2.6 % | 0.4648 | 0.57 | CONS |
| 3 | 15 | 0 | 0.30 | 0.00 | 0.1046 | 0.1046 | 0.1046 | — | 0.1643 | 1.57 | NON-CONS |
| 3 | 15 | 5 | 0.30 | 0.50 | 0.1046 | **0.5633** | 0.5508 | −2.2 % | 0.1643 | **0.29** | CONS |
| 3 | 15 | 5 | 0.60 | 0.50 | 0.3637 | 0.7015 | 0.6807 | −3.0 % | 0.4648 | 0.66 | CONS |

(Full table incl. K=3 @ 15 % in the CSV.)

**Two results.**
1. **The Voigt composition is VALIDATED.** `E_part/Es = φ_wall + (1−φ_wall)·E_core/Es`
   matches the directly-resolved composite to **−1.9 % … −3.0 %** at every point,
   across φ_wall 0.50–0.68 and the full infill band. The small residual is one-
   signed: the real part is ~2–3 % **softer** than pure parallel springs (Poisson-
   mismatch at the wall/core interface), so the §C/§D extrapolation — which uses
   Voigt — is **mildly optimistic; the true non-conservatism is at least as large.**
2. **The gate error flips sign with the walls.** The bare core at 30 % is
   non-conservative (asm/meas 1.51, ≈ 184). Add the default 5 wall loops to a
   10 mm part and it flips hard **conservative** (0.22) — the walls make the part
   3–7× stiffer than f^1.5 assumes. **The shells are the whole story.**

---

## C — SIZE / CROSSOVER (bar K4) — validated Voigt extrapolated (`C_size_crossover.csv`)

`E_part/Es(W) = φ_wall(W) + (1−φ_wall)·E_core/Es`, φ_wall = 4t(W−t)/W², E_core
the §A bare-core law. **W\*** = width where E_part/Es = f^1.5 (below: CONSERVATIVE;
above: NON-CONSERVATIVE). Direct 200 mm resolution is infeasible (184 M1: a
printable lattice over a 200 mm part is 560 M voxels, 104× the LAN ceiling) — this
is the sanctioned scaled-specimen-with-scaling-argument substitute: the model is
validated at φ_wall 0.50–0.68 (§B) and extrapolated down the *same functional
form* to φ_wall→0.04, no new physics introduced.

**Crossover width W\* (mm):**

| infill | W\* @ 3 loops | W\* @ 5 loops (default) |
|---|---|---|
| 0.15 | 423 | 705 |
| 0.20 | 117 | 195 |
| 0.25 | 93 | 155 |
| 0.30 | **59** | **98** |
| 0.40 | 45 | 75 |
| 0.50 | 30 | 51 |
| 0.60 | **25** | **41** |

**Where the error stops being ignorable:** at high infill it starts small — at
**60 % infill any part wider than ~41 mm (5 loops) / ~25 mm (3 loops) is already
non-conservative.** At 30 % the threshold is ~98 / ~59 mm. Shell fraction falls as
1/W, so **the discrepancy grows monotonically with part size, exactly as
predicted** — and for the maintainer's ~200 mm envelope it is non-conservative
across the entire practical infill band.

---

## D — CARRY IT TO THE GATE (bar K3) — the number that decides urgency (`D_gate_margin.csv`)

The gate accepts iff `margin.worst_case × f^1.5 ≥ margin_stop` (default 1.5)
([`minimize_plastic.cpp:1105`](../../core/src/simp/minimize_plastic.cpp),
knockdown `:69`, exponent 1.5 `:66`). If the true knockdown is the
measured `E_part/Es` rather than `f^1.5`, then a part certified at margin **exactly
1.5** actually has **true margin = 1.5 × (E_part/Es) / f^1.5**.

**True margin for a part the gate passed at 1.5:**

| infill | 40 mm (3/5 loops) | 100 mm (3/5) | **200 mm (3/5)** |
|---|---|---|---|
| 0.15 | 4.40 / 6.42 | 2.50 / 3.35 | 1.85 / 2.28 |
| 0.20 | 2.86 / 4.17 | 1.62 / 2.18 | 1.20 / 1.48 |
| 0.25 | 2.32 / 3.23 | 1.46 / 1.84 | 1.16 / 1.36 |
| 0.30 | 1.85 / 2.53 | 1.20 / 1.49 | **0.98 / 1.13** |
| 0.40 | 1.57 / 1.98 | 1.18 / 1.36 | 1.05 / 1.14 |
| 0.50 | 1.37 / 1.64 | 1.11 / 1.23 | **1.03 / 1.09** |
| 0.60 | 1.33 / 1.51 | 1.16 / 1.24 | 1.11 / 1.14 |

**The worst point is 200 mm, 30 % infill, 3 wall loops: true margin ≈ 0.98**
(measurement resolution) — **below 1.0, i.e. a part the gate certifies as safe at
1.5 is predicted to be at the failure boundary.** Bulk-correcting the ~10 % vpc16
core softness lifts it to **~1.04**; either way **the 1.5 safety factor is
entirely consumed** at this point. At the **default 5 wall loops** the worst 200 mm
margin is **~1.09** (50 % infill) to **~1.13** (30 %) — a **~25 % erosion** of the
reported headroom, never quite to failure. Parts **≤ 100 mm** keep true margin
**≥ ~1.2** across the band; the problem is specifically **large, low-wall-count,
mid-infill** parts.

---

## HONESTY CAVEATS (what would change these numbers)

1. **Stiffness, not strength.** The gate applies f^1.5 to a *strength* margin; this
   study measures a *stiffness* knockdown (as 184 did — it is what a linear FEA
   resolves). §D's margins assume stiffness-knockdown ≈ strength-knockdown (true in
   Gibson-Ashby: both ~f^1.5 nominal, both ~f^2.0 measured). But in a wall+core
   section the solid walls carry a disproportionate share of **both** stiffness and
   peak stress, so the strength margin could move differently from the stiffness
   ratio. **§D is a sign-robust estimate, not a strength certificate.** The physical
   anchor — printed coupons pulled to yield — is the fixture only the maintainer can
   generate (184 flagged the same).
2. **Idealized walls.** Perfectly solid perimeters, gyroid core = slicer gyroid,
   load aligned with the walls, isotropic material. Real prints have inter-bead and
   inter-layer voids and weaker z-bonding; a wall loaded across layers is weaker than
   modeled, which would make the real non-conservatism **worse**, not better.
3. **Voigt residual is one-signed** (real part 2–3 % softer than the model), so §C/§D
   are mildly optimistic; the true crossover is slightly smaller and the true margin
   slightly lower than tabulated.
4. **Extrapolation, stated.** The composite was directly resolved only at K=2,3
   (φ_wall 0.50–0.68); 200 mm is model-based because direct resolution is infeasible
   (BLOCKED-STOP below). The model held to ±3 % over the measured range and is
   extended, unchanged in form, to φ_wall 0.04.

---

## BLOCKED-STOP note

A **wall-and-core specimen up to K=3 (48³, W=15 mm)** is fully runnable on this
6-P-core Mac (seconds–minutes per porous solve; the caps/walls are well-conditioned,
the porous cores run Jacobi-CG at 200–1700 iters). **Direct resolution of a real
~200 mm part is not** — the printable ~0.70 mm gyroid wall forces ≈560 M voxels
(184 M1), 104× the LAN ceiling, for a single solve. Per the task's BLOCKED-STOP
clause this report therefore **validates the composition at the largest runnable
specimen and extrapolates with the stated scaling argument** (φ_wall is a pure
geometric ratio; Voigt is the exact aligned-column rule; both were measured to hold
to ±3 %). The smallest specimen that *would* answer §C directly at 200 mm is that
560 M-voxel grid — reported as arithmetic, not attempted.

---

## COMPLIANCE

* **Bar K5 — NO FIX.** The knockdown (`minimize_plastic.cpp:69`, exponent `:66`),
  the gate (`:1105`), and every default are **untouched**. This report changes nothing but
  adds a measurement and a decision.
* **FORBIDDEN — clean.** No `fixtures/`, benchmark, `materials.json`,
  `ARCHITECTURE.md`, `DECISIONS.md`, ROADMAP box, `/app/`, or production default was
  modified. Only additive files: this handoff, `evidence/2026-07-26-knockdown-check/`,
  and the standalone harness `core/tests/harness/knockdown_probe.cpp` (not wired into
  CTest; mirrors `lattice_probe.cpp`). `core/build/` artifacts are untracked.
* **Reproduce:** from `core/`, `cmake -S . -B build -DTOPOPT_USE_OCCT=OFF
  -DTOPOPT_BUILD_TESTS=OFF && cmake --build build --target topopt -j`, then
  `c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3
  tests/harness/knockdown_probe.cpp build/libtopopt.a -o build/knockdown_probe`;
  run with `TOPOPT_KNOCKDOWN_CSV_DIR` set to the evidence dir. Env `TOPOPT_KNOCKDOWN_ONLY
  ∈ {res, core}` runs a subset.
* **Every number is first-hand.** `evidence/2026-07-26-knockdown-check/`:
  `probe_stdout.txt` (full run incl. the E_solid=3500.0000 self-check),
  `A0_core_resolution.csv`, `A_core_law.csv`, `B_composite.csv`,
  `C_size_crossover.csv`, `D_gate_margin.csv`.

## Found in passing (NOT acted on)

* The gate's `infill_percent` **defaults to 100** (`pipeline.hpp:313` per 184 M5),
  so the knockdown is 1.0 unless the user moves the slider — the size-dependent
  error above only bites once infill < 100 is set. Unchanged; noted.
* `A_core_law.csv` rows f=0.15 and f=0.20 are the same specimen (vpc16 cannot render
  vf<0.19); a finer-grid re-run would separate them but does not change any sign or
  conclusion (both compared against measured vf).
* The core/app f^1.5 duplication (memory `infill-knockdown-duplicated-app-core`) is
  the surface any future size/shell-aware correction would have to change in **both**
  places. Noted for whoever picks up the decision; not touched here.
