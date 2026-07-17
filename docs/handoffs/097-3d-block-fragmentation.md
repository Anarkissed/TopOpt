# 097 — 3D solid-block cantilever: fragmented / tab-removed result

Status: **DIAGNOSED + FIXED.** The fragmented, "load-tab-removed" result is the
**self-weight** signature, not the external-load one. An externally loaded tab is
frozen and its load-bearing neck stays solid, so it stays connected and is never
removed in any faithful reproduction (all load directions, grid lengths 32–64).
The reported result is only produced when the run executes under **self-weight** —
which happens when a load-case run's external force is empty. The fix makes that
silent self-weight fall-through **loud** (`require_external_loads`), plus a
regression gate that locks "externally loaded ⇒ tab retained AND printed field
connected." **No ROADMAP box checked.**

Territory: `/core/` + the sanctioned `TopOptBridge/bridge.cpp`. Branch:
`claude/3d-block-fragmentation-10rhko`. No fixtures / benchmarks / materials.json /
ARCHITECTURE / ROADMAP box touched.

Reproduction harnesses (NOT wired into CTest): `core/tests/harness/per_iter_probe.cpp`
(per-iteration connectivity curve, external vs self-weight, STEP-0 counts) and
`core/tests/harness/block_frag_probe.cpp` (4-rung ladder variant). Built standalone,
e.g. `c++ -std=c++17 -O3 -DNDEBUG -I core/include core/tests/harness/per_iter_probe.cpp
build/libtopopt.a -o /tmp/per_iter`.

---

## STEP 0 — THE CONTRADICTION, resolved first (with counts)

The maintainer's two facts looked contradictory: (082) the anchor pad freezes the
LOAD face so it is un-removable, and (077/matfree) the core THROWS on a loaded void
DOF before any iteration — yet the run COMPLETED with the tab apparently gone. Both
are resolved by measuring the field.

### (a) The pad DOES reach the load face — WHEN the tab is externally loaded

`bridge.cpp:806-814` builds the pad on the no-box path behind **every anchor AND
every retained-LOAD face** (`retained_load_faces`, populated at `bridge.cpp:689-691`
for each non-zero force group). Measured on the reproduction (protruding 5×5×4 tab,
`mask_step_face` depth `kAnchorPadDepthVoxels=3`):

```
[STEP0-pad] tab voxels=100  tagged Load(->FrozenSolid)=100  in mask_step_face load pad=75
            |  total pad FrozenSolid=1275 (load-face pad layer=75)
```

All 100 tab voxels are forced FrozenSolid by the **Load tag** alone
(`effective_mask`, `simp.cpp:949-950`); 75 of them are ALSO in the 3-layer load pad.
So under an external load the tab is pinned to density 1 and is genuinely
un-removable. **BUT** this only fires when the tab is tagged Load — i.e. when a
non-zero external force exists. With **no external force** the tab is never tagged
(`bridge.cpp:676-677` skips a zero-force group), gets **0** load-face pad voxels, and
is a free design variable:

```
[STEP0-pad] tab voxels=100  tagged Load(->FrozenSolid)=0  in mask_step_face load pad=0
            |  total pad FrozenSolid=1200 (load-face pad layer=0)   [self-weight run]
```

### (b) The throw never fires — because the void-DOF gate is TOPOLOGICAL

The gate (`matfree.cpp:532-578`, `assembly.cpp` parity) marks a free DOF "void" iff
**no solid ELEMENT touches it**, keyed off grid TAGS, not SIMP density. In the SIMP
loop every non-Empty voxel keeps a hex element down to `density_min` (1e-3 > 0), so
every loaded DOF always has stiffness. Measured, both modes:

```
[STEP0-throw external]   load-face min density=1.0000 (pinned solid=YES)
                         min density over ALL non-Empty voxels=1.000e-03 (>0)
                         loaded voxels that are Empty(void)=0  => throw fires=NO
[STEP0-throw self-weight] load-face min density=0.0377 (pinned solid=NO)
                         min density over ALL non-Empty voxels=4.205e-03 (>0)
                         loaded voxels that are Empty(void)=0  => throw fires=NO
```

Two independent reasons the throw is silent: (1) no voxel is ever `Empty` (elements
persist at `density_min`), and (2) self-weight is a **distributed body load computed
once on the initial solid grid** — there is never a concentrated load sitting on a
stiffness-free DOF, which is the only thing the gate rejects. So a self-weight run
can strip the tab to ρ=0.04 (below iso ⇒ "removed") and STILL complete without the
throw.

### (c) Resolution

- **External load:** the tab is pinned to density 1 (a=100/100), the throw cannot
  fire (b), and it is NOT gone from the field — if the render shows it missing that
  is a display artifact. **But in fact it never even reaches the render as an
  island: an externally loaded tab stays connected (STEP 2), so keep-largest keeps
  it.**
- **Self-weight:** the tab is NOT frozen, is stripped to ρ≈0.04 (genuinely removed
  from the printed set), the throw still cannot fire (b), and the design fragments.
  **This is the reported result.**

The run "completing with the tab gone and no throw" is the **self-weight
signature**, and is impossible for a genuinely externally-loaded tab.

---

## STEP 1 — Bisect the plateau (086): EXONERATED

One rung (vf 0.26, the lightest — max stripping pressure), 32³ protruding-tab
cantilever, matrix-free MG-CG, plateau (window=10) vs cap-60 (window=0):

| config | terminates | final #components | load↔anchor same comp | final compliance |
|---|---|---:|:---:|---:|
| cap-60 (window 0) | iter 60 (cap) | **1** | **YES** | 2.590e1 |
| plateau (window 10) | iter 59 (plateau fired, converged) | **1** | **YES** | 2.590e1 |

Both converge to the identical connected single-component design. The tab
disconnects only during iters 1–7 (the near-uniform forming phase, before members
cross iso) and reconnects by iter 8, holding to the end. Confirmed connected at the
fuller 20×20 cross-section too (32×20×20 cap-60 connects by iter 3; 48×20×20 by iter
5). **086's extra iterations do not drive fragmentation — the bisect is identical.**

---

## STEP 2 — The named cause: the run executed as SELF-WEIGHT

Same geometry (32×20×20, vf 0.26, cap-60), external tip load vs self-weight
(tab NOT frozen), matrix-free:

| quantity | external tip load (tab tagged Load→frozen) | self-weight (tab not frozen) |
|---|---|---|
| load-face density | **1.0000 (pinned)** | **0.018 (removed, ≪ iso)** |
| final #components | **1 (connected)** | **5–13 (fragmented)** |
| load↔anchor same component | **YES** | **NO** |
| compliance | 2.2 (meaningful), converges | **~3e-7 (noise)** |
| max|Δρ| at the cap | drops (converges) | **pinned at the 0.2 move limit — never converges** |

Load-direction sweep (external, 32×20×20): −z / +x / +y / diagonal xz ALL converge
to a single connected component with the tab pinned at 1.0. **No external load case
fragments.**

### Why self-weight fragments and external does not

An externally loaded tab's **neck is load-bearing**, so it stays solid (measured
`neckmin=1.0`); the tab is welded to the body and keep-largest keeps it. Self-weight
of a slender cantilever is a different problem: the far tab's own weight is ~0.4 % of
the total and contributes essentially nothing to a **~1e-7, noise-dominated**
compliance, so the optimizer abandons it (strips it below iso) and, having no
dominant load path to preserve, churns at the move limit and fragments into
disconnected islands. This is exactly the maintainer's PRIME SUSPECT (self-weight as
an ill-posed, near-zero-objective load) — **named, with numbers.**

### How a load-case run becomes a self-weight run

`minimize_plastic` uses self-weight whenever `external_loads` is empty
(`minimize_plastic.cpp:250-254`). The bridge's load-case path builds `external` only
from **non-zero** force groups (`bridge.cpp:676-677` `continue`s on a zero-force
group); if every group is zero-force / the force never reached the solver, `external`
comes back empty and the run **silently** optimizes under self-weight — with the tab
unfrozen. The maintainer confirmed a Load WAS set in the UI, so the force was lost
upstream (UI→bridge; app territory, not reproducible in this core session); the core
defect is that the loss is **silent** and ships a fragmented, tab-removed design as
if it succeeded.

---

## STEP 3 — Root cause

The result is a **self-weight optimize of a slender cantilever with an unfrozen
tab**, reached by the load-case path silently falling through to `self_weight_loads`
when its external load is empty. Self-weight's near-zero, noise-dominated objective
cannot form a coherent load path, so the design fragments and the unfrozen tab is
stripped. The void-DOF throw cannot catch it (distributed load, elements persist at
`density_min`); mesh cleanup then drops the sub-iso tab and minority islands, so the
render shows the tab "completely removed." An externally-loaded tab is frozen with a
solid load-bearing neck and stays connected — it is never removed.

---

## STEP 4 — The fix (minimal, gated, byte-identical off the affected path)

1. **`MinimizePlasticOptions::require_external_loads`** (default **false**,
   `pipeline.hpp`). When true, an empty `external_loads` **throws**
   (`minimize_plastic.cpp`) instead of silently running self-weight. Default false ⇒
   genuine self-weight runs and every existing caller/fixture/Gate-V2 path are
   byte-for-byte unchanged.
2. **Bridge (`run_minimize_plastic_loadcase`)** sets
   `opts.require_external_loads = !load_case.load_group_sizes.empty()` — i.e. when the
   user defined load groups, a lost/zero force now surfaces as a **clear error**
   ("your load did not reach the solver") rather than a plausible-looking garbage
   design. A run with no load groups declared is left as self-weight (a legitimate
   mode).
3. **Regression gate** `load_retention_connectivity`
   (`core/tests/validation/test_load_retention_connectivity.cpp`): (a) an externally
   loaded protruding-tab cantilever run through `minimize_plastic` — every load-face
   voxel retained at density 1, and the printed field (ρ>iso) is a **single connected
   component** whose majority holds BOTH the load and anchor voxels and is the
   largest body; (b) `require_external_loads` + empty `external_loads` **throws**;
   (c) the guard does NOT fire for a genuine self-weight run (default false) nor when
   a real load is present.

### THE ONE RULE — evidence

- **No-box byte-identical:** the guard is gated on `require_external_loads`, default
  false; no core test/fixture sets it, so every existing path is unchanged.
- **Gate-V2 GREEN** (101.5 s, Linux Release), byte-identical.
- Green: `minimize_plastic` (25.3 s), `anchor_integrity` (4.4 s), `design_domain`
  (1.6 s), `designbox_anchor_pad` (5.8 s), `designbox_reduction` (2.4 s),
  `savings_part_relative` (1.0 s), and the new `load_retention_connectivity`
  (17.3 s, 8 checks). [`mma` — see run log.]
- Built with Eigen (`libeigen3-dev`) on Linux; OCCT/lib3mf absent, so the 3
  DEPS-gated tests are not registered here (CI runs them with
  `-DTOPOPT_REQUIRE_DEPS=ON`). No optimizer/design-box gate relevant to this change
  is missing.

### Build / not done

- `/core/` + `bridge.cpp` changed ⇒ the app must be re-vendored via
  `app/scripts/build_core.sh` (macOS-only; not run in this Linux session) before the
  Swift/app suite. Only `bridge.cpp` changed app-side (the sanctioned bridge,
  compiled from the vendored core).
- **The upstream force loss (UI→bridge) is NOT diagnosed here** — it is app
  territory and not reproducible in a core session (no OCCT / device job). This fix
  makes the loss surface as an error instead of a garbage result; the maintainer
  should still confirm why the UI's set force reached the bridge as zero.
