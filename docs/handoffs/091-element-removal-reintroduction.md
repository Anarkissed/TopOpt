# 091 — Element removal with reintroduction: STEP 0 rejection (a memory lever that cannot move the peak)

**Track:** core. **Territory:** `/core/` only (no app, no fixtures, no
materials.json, no ARCHITECTURE.md, no ROADMAP box).
**Builds on / corrects:** 090-void-coarsening (the post-090 baseline and profile),
079 (design-box padding + memory), 080 (whole-domain part-relative rescaling),
066 (MMA-vs-projection gate: the production path skips Heaviside), 083 (Heaviside
worsens terracing), 086 (MMA plateau termination).

## Outcome: REJECT on the stated goal, with TWO independent decisive reasons.

The task framed element removal as **"the remaining MEMORY lever"** — the thing
that brings 128³ / Fine+box under the M1 iPad's ~3 GB per-app cap. STEP 0 kills
that framing with numbers measured on the real path:

1. **It cannot reduce PEAK memory** (Reason 1, below). Peak is set by the
   **uniform-grey iteration-0 full system**, which recurs at the start of **every
   rung** (the design variable resets to a uniform field each rung —
   `simp.cpp:1307`, measured). At any removal-*safe* threshold the iteration-0
   removable fraction is **0%**. So the peak allocation is the full system
   regardless. Removal is a *time / average-memory* lever, not a peak lever — the
   same honest "no" 090 gave, now shown to be **structural**, not incidental.

2. **Reintroduction is unreliable on TopOpt's production path** (Reason 0b). The
   production MMA path **skips Heaviside** (066). The 2021 reference paper's own
   evidence is that with the density filter alone the reintroduction sensitivities
   *"dissipate rapidly … almost zero beyond r_min"* and Heaviside is what
   *amplifies* them. Measured corollary on the real path: the no-Heaviside
   grayscale design (Mnd ≈ 0.27 per 066; contrast gate_v2's projected Mnd
   **0.015** measured this session) **never develops deep void**, so at the only
   removal-safe threshold (`rho_t = 1e-3`) **only ~5 % of the domain is ever
   removable** (measured curve below). To reclaim more needs `rho_t ≈ 1e-2`, which
   removes **~90 % of the domain at iteration 1** and depends on exactly the
   reliable reintroduction the no-Heaviside path cannot deliver.

Either reason alone ends the task; together they are conclusive. **A well-argued
rejection is the requested successful outcome.** No production code changed — the
assembled + no-box paths are byte-identical, Gate-V2 is green and unchanged. The
only artifact is a read-only measurement harness (`tests/harness/removal_probe.cpp`,
not wired to CTest, mirroring `mma_probe.cpp`).

This is NOT a claim that the published method is wrong — Bruns & Tortorelli (2003),
Guest & Smith Genut (2010), the 2021 CMAME paper, and Siemens' shipping "active
region adaptation" are all sound. The claim is narrower and specific to *this*
codebase: **the method's win is a converged-tail / high-projection win, and
TopOpt's production formulation has neither a memory peak in the tail nor
Heaviside projection.**

---

## Environment

Linux x86-64, GCC 13.3, `-O3`, 4 cores (`nproc`=4, matching the iPad's 4
performance cores). This is **not** Apple/NEON, so absolute walls do not transfer
— but every STEP-0 conclusion here is about **DOF counts, density trajectories and
memory structure**, which are hardware-independent. The removable-fraction curve
is the density *trajectory* (solver-independent physics, per `mma_probe.cpp`), so
it transfers. No on-device run.

---

## STEP 0a — IS THERE ANYTHING TO REMOVE? Measured on the real path.

**The task inherited a premise from 090's prose — "the grow region … sits at
rho_min." That is wrong, measured through the real `expand_design_domain` +
`minimize_plastic` path.** The initial grow-region density is the **rung's
part-rescaled volume fraction**, a small grey value, floored at `rho_min` only for
a pathologically loose box.

Reconstructed real case (`removal_probe.cpp`, L-bracket part in a design box,
`freeze_imported_part=false`, `coarsen_align=8`), matching 090's grid exactly:

```
expanded domain grid: 96x80x96 = 737,280 voxels
elements (non-Empty) : 737,280       DOFs ~ 2,286,387
part L-bracket solid : 26,400  (3.6% of elements — 090's proportion)
active_effective=736,800  frozen_effective=480  part_solid=26,400
```

Initial Active grey density = `clamp( (vf·part_solid − frozen_eff) / active_eff,
rho_min, 1 )` (the whole-domain rescaling of handoff 080, `minimize_plastic.cpp:373`;
the design variable is then seeded uniform at that value, `simp.cpp:1309`):

| rung vf | initial Active grey density | vs rho_min |
|--------:|----------------------------:|-----------|
| 0.70    | **0.02443**                 | 24× rho_min |
| 0.50    | **0.01726**                 | 17× rho_min |
| 0.30    | **0.01010**                 | 10× rho_min |

**So the grow region starts at a small grey ~0.010–0.024 — NOT rho_min, and NOT
the rung's raw vf (0.3–0.7).** This is the decisive middle case the task named:
*"savings only accrue as the design converges, and the win is much smaller."* The
literature's known drawback — *"the full-space expensive computation at the
beginning"* — **does apply here**, and worse than usual, because the design
variable **resets to this uniform grey at the start of every rung** (`x` is not
warm-started across rungs — `simp.cpp:1307-1312`; `minimize_plastic.cpp:431` calls
`simp_optimize` fresh per rung). The expensive full-space beginning is paid **4
times** in a 4-rung ladder.

### The removable-fraction curve — measured, and it is the whole story

`removal_probe.cpp` drives the **production** updater (MMA, no Heaviside) on a
proportionally-identical 32×24×32 design box (same part fraction, same rescaled
grey = 0.0115) with the production matrix-free multigrid + 090 block cache, and
records, each MMA iteration, the fraction of Active voxels with **filtered
physical** `rho ≤ rho_t`:

```
rung vf=0.30, initial grey=0.01149     (removable% of Active; act.elems = nelem - removable)
 iter | rho_t=1e-3          | rho_t=1e-2          | rho_t=1e-1
    1 |  6.6%   22,966      |  93.9%    1,505     |  96.6%     830
    5 |  6.2%   23,044      |  90.9%    2,239     |  98.0%     490
   10 |  6.6%   22,952      |  91.1%    2,184     |  99.5%     124
   18 |  5.2%   23,302  (converged, MMA plateau 086)         | 99.6%  87
 conv | 5.2%  removable     | 83.7% removable     | 99.6% removable
```

Read this carefully — it contains the entire verdict:

- **`rho_t = 1e-3` is the only removal-SAFE threshold** (it is below the initial
  grey 0.010–0.024, so it does not try to remove the whole domain at iteration 0).
  At this threshold the removable fraction is **~5–7 % throughout, and 5.2 % at
  convergence** — and it does **not** climb toward the void fraction. Reason: the
  *filtered* physical density only reaches the `1e-3` floor deep inside large void
  pockets, and the **no-Heaviside grayscale design never sharpens enough** to
  create them (Reason 0b). So safe removal reclaims **~5 % of DOFs** — negligible.

- **`rho_t = 1e-2` straddles the grey.** It removes **0 %** at the uniform-grey
  iteration 0, then **~90 %** at iteration 1 — a violent state-variable
  discontinuity (the paper's own warning), removing ~90 % of the domain on the
  basis of a one-iteration-old field. The 80–97 % band is also *noisy* (78 % at
  iter 13, 97 % at iter 6): those "removable" voxels sit at 0.005–0.01, i.e.
  **intermediate load-bearing soft material, not void.**

- **`rho_t = 1e-1` = 0.1** removes **everything** at iteration 0 (grey 0.0115 ≪
  0.1) → only the 480-voxel BC skin remains → disconnected → **singular** ("every
  free DOF is void", the M3.1 gate throws). Unusable.

**The saving curve, stated plainly: at a safe threshold it is a flat ~5 %; to get
more you must cross into unsafe/unreliable territory.**

---

## STEP 0b — THE HEAVISIDE GAP. Confirmed from the paper's own derivation.

The 2021 reference (*"Revisiting element removal … with reintroduction by
Heaviside projection"*, CMAME, arXiv:2012.02860) — read via the ar5iv HTML, full
text, not the abstract:

- **The filter alone gives a removed element nonzero design sensitivity.** Their
  chain rule (around Fig. 1(f)):
  `dc/dφ_i = Σ_{e∈N_i} (dc/dρ_e)(∂ρ_e/∂μ_e)(∂μ_e/∂φ_i)` — *"if an element Ω_e is
  within r_min of the structural boundary, its sensitivity dc/dφ_e can be nonzero
  even if dc/dρ_e = 0. This is purely due to the propagation effect under the
  filtering operation."* So Heaviside **amplifies**, it does not **create** the
  reintroduction gradient. This part of the task's premise is correct.

- **But un-amplified, it is too weak to reintroduce reliably.** *"When using the
  density filter alone the sensitivities have maximum values in the interior of the
  solid region and dissipate rapidly … Elements beyond the distance r_min have
  almost zero relative density after the two propagation operations. On the other
  hand, the Heaviside projection amplifies the small sensitivity coefficients that
  propagate from the topological boundaries."* **The paper does not demonstrate
  reliable reintroduction without projection**; its whole contribution (HPM) is the
  amplification, and it reports the pure-filter route (Bruns & Tortorelli) as slow
  and suitable only for simple problems.

- **The production MMA path has no Heaviside** (066 gate; 083 found enabling it
  makes terracing WORSE — a product regression, not a free switch).

- **The mitigating datum does not rescue it.** 090-simpl-evaluation notes SiMPL
  reaches near-binary designs with no Heaviside via its sigmoid — but TopOpt does
  not run SiMPL in production; it runs grayscale MMA (Mnd ≈ 0.27). On *that* path
  the measured consequence is the 5 % ceiling above: no Heaviside → gray design →
  little deep void → little safe-removable material. The Mnd contrast is direct:
  gate_v2's **projected** design measured **Mnd = 0.015** this session vs the MMA
  path's ~0.27. Removal's payoff scales with binariness, which is exactly what the
  production path forgoes.

**Verdict on 0b: reintroduction technically survives without Heaviside (the filter
gradient is nonzero), but not reliably or strongly enough to matter — and turning
Heaviside on to fix it is a product change the task explicitly forbids doing
quietly.**

---

## The post-090 profile, and why removal misses it

Starting from 090's corrected baseline (NOT "93 % of the solve is void"):

- Post-090 solve = **12.21 s** = build **3.73 s** (31 %) + iterate **8.59 s** (69 %),
  peak RSS **1.511 GB**, end-to-end peak **~1.97 GB** (079).
- Memory by component (090): element table **66 MB** (stays — all design variables
  alive, by this task's own requirement), coarse operators **248 MB**, CG vectors
  **192 MB**.

What removal could touch and what it actually reclaims:

| component | removal-reducible? | reclaimed at the safe threshold (5 % DOFs) |
|-----------|--------------------|--------------------------------------------|
| design/filter/sensitivity/density arrays (per-voxel) | **NO** — every design variable stays alive (task requirement) | 0 |
| element table (66 MB) | partially (FEA elements only; design vars stay) | ~5 % |
| coarse operators (248 MB) | yes, ∝ active DOFs | ~5 % |
| CG vectors (192 MB) | yes, ∝ active DOFs | ~5 % |
| **peak** of all the above | **NO — maximal at iteration 0 of every rung** | **0** |

The achievable ceiling, named before designing: at the safe threshold removal is a
**~5 %** DOF reduction realized only in the converged tail — smaller than 090's
already-banked 1.34×, and it does not touch the peak at all.

---

## STEP 2 risks — assessed, and they compound the rejection

- **Per-iteration active-set recompute.** Cheap in isolation (one density sweep),
  but see the multigrid point.
- **The multigrid rebuild — the decisive cost risk.** The hierarchy is built on the
  *reduced* system. A changing active set changes which DOFs are free every
  iteration, so the **symbolic structure and the entire scatter pattern of A1
  rebuild every iteration.** 090's Galerkin block cache **partly survives**: the
  block `S = WᵀKeW` is parity-keyed and geometric, so *generic-interior* blocks are
  still reusable — BUT the genericity test requires all 8 coarse nodes active and
  all 24 fine DOFs free (`multigrid.cpp:909`), and removal manufactures **more
  non-generic boundary elements** (a longer void–solid interface) and a **different
  scatter target** every iteration. Net: removal keeps the block arithmetic cache
  but forces a fresh symbolic build + scatter every iteration, while saving ~5 % of
  DOFs at the safe threshold. That is plausibly **net slower**, not faster.
- **The conditioning bonus is real but small.** The paper's own iteration counts:
  2D 352 → 227–280, 3D **292 → 268–314** (i.e. essentially unchanged in 3D, their
  most relevant case). Not a second independent win here.

---

## CORRECTNESS GUARDS — satisfied by construction (no production change)

- **a/b/c (same answer / growth preserved / 078 parity):** nothing in the
  optimizer, FEA, filter, or multigrid changed, so the answer is byte-identical and
  growth is trivially preserved. The growth machinery this task would have had to
  protect is intact: `test_design_domain` **24/24** (measured this session:
  `grown_active=135`, matrix-free vs assembled `max|Δρ| = 5.05e-9`).
- **d (stress path):** untouched; the paper's warning about *"a discontinuity in
  the state variables"* from adaptive BCs is precisely why the accept-gate's
  recovered von Mises must never see a changing active set — an argument FOR not
  shipping removal on the stress path, now moot.
- **e (Gate-V2 + suite green, no-box byte-identical):** measured this session —
  `gate_v2` **72/72**, `designbox_reduction` **6/6**, `design_domain` **24/24**.
  No `/core/` production file was modified, so `galerkin_cache`,
  `designbox_anchor_pad`, `designbox_padding`, `anchor_integrity` etc. are
  unchanged.

---

## EVIDENCE — the question that matters: does this bring 128³ / Fine+box under ~3 GB?

**No — and, unlike 090 which merely *did not*, this one *cannot*.** Scaling 090's
per-element memory, 128³ needs ~0.88 GB of coarse operators alone and Fine+box
~1.95 GB, on top of the always-full per-voxel design arrays. Removal's peak is the
iteration-0 full system, so it leaves those figures unchanged. The only STEP-1
lever large enough for the peak remains **090's option (b)** — a coarser multigrid
level over the void, which shrinks the coarse operator *as a preconditioner*
without deactivating any fine element (so growth stays safe). That, not removal, is
where a memory win lives.

---

## What remains / recommendation

1. **Do not implement element removal on the current production path.** Revisit
   only if (a) the production path adopts Heaviside or a SiMPL-style sigmoid that
   yields near-binary designs (raising the safe-threshold removable fraction from
   ~5 % toward the void fraction), **and** (b) the goal is reframed from *peak
   memory* to *converged-tail wall time*. Both preconditions are currently false.
2. **The real memory lever is 090's option (b)** (coarse-operator coarsening over
   the void), which reduces the peak because the coarse operator is a
   preconditioner and can shrink without deactivating fine elements — the invariant
   090 established. That is the recommended next task for the 128³ goal.
3. `removal_probe.cpp` is left under `tests/harness/` (read-only, not wired to
   CTest) so the STEP-0 numbers here are reproducible.

## Files

- `core/tests/harness/removal_probe.cpp` — **new**, read-only measurement harness
  (0a numbers on the real 96×80×96 grid + the removable-fraction curve). Not a CI
  test; compiled standalone like `mma_probe.cpp`.
- No production `/core/` file changed.

## Citations

- Bruns & Tortorelli, *Comput. Methods Appl. Mech. Engrg.* / IJNME 57:1413–1430
  (2003) — founding element-removal-with-reintroduction method.
- Guest & Smith Genut (2010), *Reducing dimensionality in TO using adaptive design
  variable fields*, IJNME.
- **Reference:** *Revisiting element removal for density-based structural topology
  optimization with reintroduction by Heaviside projection*, CMAME (2021),
  arXiv:2012.02860 (read in full via ar5iv HTML) — filter propagates the
  reintroduction gradient, Heaviside amplifies it; `rho_t ∈ {1e-3, 1e-2, 1e-1}`;
  3D n_active 100 % → 20–23 % *after 100 iterations* at V_max = 0.16 *with*
  projection; 3D iteration counts 292 → 268–314.
- Siemens (2024), "active region adaptation" — commercial deployment of the same
  idea.
- Internal: 090-void-coarsening, 079, 080, 066, 083, 086.

## THE ONE RULE — honoured

- Assembled + no-box paths **byte-identical** (no production file touched).
- Gate-V2 **green and unchanged** (72/72 measured).
- Nothing enabled; nothing opt-in added — the task ended at STEP 0 by design.
- **No ROADMAP box checked.** `/core/` changed only by adding a read-only harness →
  `app/scripts/build_core.sh` still applies before the app links core.
