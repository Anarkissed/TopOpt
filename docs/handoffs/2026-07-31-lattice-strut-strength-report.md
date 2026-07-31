# Strut-strength margins on the lattice receipt — REPORT ONLY

**Date:** 2026-07-31
**Branch:** `claude/lattice-strut-strength-report-838bb9` (from main after PR 259)
**Predecessor:** `2026-07-31-lattice-dehomogenization-probe` (PR 259 — the measured
law this consumes), `2026-07-31-multiscale-lattice-feasibility` (PR 255 — the three
designs the reproduction bar re-runs).
**Scope:** core/ + the app fields that display the result. Fixtures, materials.json,
ARCHITECTURE.md, DECISIONS.md untouched.
**THE GATE DID NOT CHANGE.** `lattice_accepted` means exactly what it meant
yesterday; `strut_strength_uncertified` stays true; no verdict logic or tolerance
was touched (diff proof + test, bar L1 below).

---

## What shipped, in one paragraph

PR 259's measured de-homogenization law — `strut_vm <= K_dev(rho)·vm(Sigma) +
K_vol(rho)·|p(Sigma)|`, with the interlayer analogue on Kild/Kilv — is now
embedded in core as data (`strut_strength.cpp`, the kfit `*_cert` envelope rows
VERBATIM, its own file exactly like the homogenized tensor tables), interpolated
in rho, and evaluated per latticed voxel from that voxel's macro stress TENSOR on
every latticed certification. The lattice receipt gains a `strut_strength` object
reporting — separately, never collapsed — the in-plane strut margin, the
interlayer strut margin, the worst case, both bounds in MPa (the z-knockdown-free
"ratio" half of PR 259's deliberate split), each argmax voxel's rho and macro
invariants, the NAMED unsourced z_knockdown the interlayer margin divides by, the
cells-per-member regime guard, and the out-of-band-rho clamp count. run_info's
`lattice` object carries the run-level minima; the app's lattice notes show
in-plane and interlayer as separate lines with the unsourced-constant and
out-of-regime caveats attached. The per-voxel evaluator is a standalone function
taking the build direction as an EXPLICIT parameter, so an orientation scorer can
sweep N directions against one solved field.

## The one design decision worth reading twice

**The measured envelope is build-direction-independent across the lattice cube
axes — and that is a measured fact, not a gap.** kfit's Kild/Kilv are worst-case
over all macro states with the build axis on a lattice cube axis, and vm/|p| are
rotation invariants, so x/y/z builds give the SAME interlayer bound (cubic
symmetry; the probe pinned uni_x ≡ uni_z as its instrument check). The evaluator
asserts this identity in test. Build-direction RESOLUTION enters honestly for
off-axis directions: the strut layer-normal stress then picks up strut SHEAR
components the axis law never sees, and those are rigorously bounded by
`|sigma_ab| <= vm/sqrt(3)` applied to the strut-vm bound, giving

    il_bound(n) = [Kild·vm + Kilv·|p|]
                + (2/sqrt(3))·(|nx·ny| + |ny·nz| + |nz·nx|)·[Kd·vm + Kv·|p|]

The cross factor is ZERO on any cube axis — so the production numbers reduce
EXACTLY to PR 259's J6 recipe (which is how L2 and L8 can both hold) — and
positive off-axis, in the conservative direction, which is the only honest
direction for a report. The in-plane bound is invariant in n by construction, and
the L8 test asserts exactly that split: two build directions on one solved field
move the interlayer margin and leave the in-plane margin bit-identical.

## Bars

### L1 — NO GATE CHANGE (diff + test)

* Diff proof: `evidence/l1_analyze_diff.txt` — every change to `analyze.cpp` is
  additive and sits AFTER `out.accepted`/`out.margin_effective` are sealed; the
  `margin_effective` formula lines and the `accepted = load_path_ok && margin_ok`
  line are untouched. `evidence/l1_run_job_diff.txt` — the receipt's
  `lattice_accepted` emission is byte-identical; the `strut_strength` object is
  appended with `"gated": false`.
* Test proof (`test_strut_strength`, part 7): a latticed slab whose strut
  worst-case margin measures below 0.5 is still ACCEPTED by today's solid-strength
  gate, `margin_effective == margin.worst_case * infill_knockdown` still holds,
  and `lattice_strength_uncertified` stays true. The J6 test re-asserts it on the
  three real designs: shipped verdict (accepted, margins 1.46–1.50) unchanged
  while the report reads 0.38–0.63.

### L2 — REPRODUCES PR 259's J6 NUMBERS (`test_strut_report_j6`, in ctest)

PR 255's three designs rebuilt from evidence fields and run through the
PRODUCTION path (`analyze_fixed_design`'s built-in report — the embedded table,
the same solve, build z):

| design | probe strut-vm margin | production | probe interlayer | production |
|---|---|---|---|---|
| s0_plain | 0.6164 | 0.6164 | 0.3936 | 0.3936 |
| s2_gappen | 0.6320 | 0.6320 | 0.3799 | 0.3799 |
| s3_contin | 0.6266 | 0.6266 | 0.3769 | 0.3769 |

Agreement is within the probe CSV's own print precision (5e-5 on margins, 5e-4 on
the MPa bounds; voxel counts exact; argmax rho exact to 4 decimals). Full log:
`evidence/j6_reproduction.txt`. The test lives in ctest and SKIPs loudly if the
evidence tree is absent.

### L3 — ABSENT LATTICE IS BYTE-IDENTICAL (stash-rebuild checksum)

The demo (non-lattice) job run with the changed build and with the stashed-and-
rebuilt pre-change build produces byte-identical outputs (report.json,
run_info.json, meshes) — `evidence/l3_byte_identity.txt`. Every new code path is
behind `has_lattice` / `lattice_strut_report_present`; a non-lattice run cannot
reach any of it.

### L4 — THE CELLS-PER-MEMBER GUARD IS REPORTED

Per variant, the receipt reports `cells_per_member_min` (thinnest LATTICED
member's local width / cell size, the same EDT the width-aware gate uses) against
`cells_per_member_floor` READ from core (`lattice_cells_per_member_min`), plus
`out_of_regime` and a regime_note when below it. On PR 259's own J6 designs the
production path measures 0.50–1.00 cells per member against the 5-cell floor —
OUT OF REGIME, exactly the probe's finding — so their strut numbers reproduce AND
carry the label saying how far to trust them.

### L5 — OUT-OF-BAND rho IS CLAMPED-AND-COUNTED

The law table spans rho 0.04762–0.89598; the octet certifiable band pokes above
it (to 0.89988). Voxels outside the span are clamped to the endpoint row and
COUNTED (`rho_clamped_voxels` per receipt, summed into run_info), never
extrapolated — K_dev is 124 at the floor and extrapolation is exactly how a wrong
number would look plausible. The J6 designs exercise this live: s2/s3 carry ~100
above-span voxels each (the probe clamped them silently; the production path
counts them). Low-end clamps cannot occur in production (band floor 0.05047 >
law floor 0.04762) but are handled and tested anyway.

### L6 — THE APP SHOWS BOTH, SEPARATELY

run_info's `lattice` object gains `strut_margin_in_plane` /
`strut_margin_interlayer` / `strut_margin_worst_case` / `strut_z_knockdown` (+
`strut_z_knockdown_unsourced: true`) / `strut_min_cells_per_member` /
`strut_out_of_regime` / `strut_rho_clamped_voxels` / `strut_gated: false` — keys
emitted only when a report ran. The app parses them into
`LatticeReport.StrutStrength`, persists them through the OutcomeStore DTO (the
honesty-round-trip rule), and `latticeNotes` renders one line with BOTH margins —
"in-plane margin X, interlayer margin Y (÷ layer-bond knockdown 0.55, an
unsourced constant)" — plus an out-of-regime line when flagged. Never one
collapsed number: which one binds is the point (on every design measured so far,
interlayer binds).

### L7 — DETERMINISM + ctest

* The evaluator is a single deterministic pass (no threads, no RNG); re-run
  bit-identity is asserted in the unit test, and a full lattice job run twice
  produces byte-identical receipts/report/meshes —
  `evidence/determinism_receipts.sha256`.
* Full ctest: <<CTEST_COUNT>> — see `evidence/ctest_summary.txt`.

### L8 — THE EVALUATOR IS CALLABLE, NOT WELDED TO THE RECEIPT

`evaluate_strut_strength(stress_tensor_field, lattice_mask, relative_density,
build_dir, yield, z_knockdown)` in `strut_strength.hpp` — a free function; the
BUILD DIRECTION is an explicit parameter, never read from options, so PR 247-style
orientation sweeps can call it N times against ONE solved field. The test calls
it twice with different build directions on the same solved field and asserts the
interlayer margin changes while the in-plane margin does not — plus the cubic-
symmetry identity (x ≡ z exactly) and the exact off-axis cross-term formula.
`analyze_fixed_design` calls the same function the receipt then serializes, and
the test asserts the standalone call reproduces the analysis' own report.

### BLOCKED-STOP check — not needed

The macro stress TENSOR is retained per latticed voxel
(`stress_tensor_field`, filled by `hex8_stress_cubic` since the Phase-1
certification), so the two-invariant law evaluates from production data with no
plumbing gap and no scalar substitute anywhere.

## Files

* `core/include/topopt/strut_strength.hpp` + `core/src/fea/strut_strength.cpp` —
  NEW: the kfit `*_cert` law table (verbatim, provenance-commented), rho
  interpolation with clamp-and-flag, and the standalone per-field evaluator.
* `core/include/topopt/analyze.hpp` / `core/src/simp/analyze.cpp` — report-only
  fields on `FixedDesignAnalysis` (`lattice_strut_report`, `lattice_strut`,
  `lattice_min_cells_per_member`, `lattice_strut_out_of_regime`), filled after
  the gate; octet-only (no other topology has a law — fcc reports nothing).
* `core/src/cli/run_job.cpp` — receipt `strut_strength` object; run-level minima
  into run_info via `lat_agg`.
* `core/include/topopt/observability.hpp` / `core/src/simp/observability.cpp` —
  run_info strut keys (emitted only when present; +inf serialized as null).
* `core/tests/unit/test_strut_strength.cpp`,
  `core/tests/validation/test_strut_report_j6.cpp`, `core/CMakeLists.txt` — the
  bars above, registered in ctest.
* App: `TopOptKit.swift` (`LatticeReport.StrutStrength`), `RemoteRunner.swift`
  (run_info parse), `ResultsModel.swift` (notes), `OutcomeStore.swift` (DTO
  mirror), `LatticeModeTests.swift` (round-trip + separate-notes tests).
* `evidence/2026-07-31-lattice-strut-strength-report/` — diffs, test logs, J6
  reproduction, byte-identity and determinism checksums, an example receipt.

## Carried caveats (the report says them; so does this handoff)

1. **z_knockdown is unsourced.** The interlayer margin divides by it; PR 259
   showed the verdict a future gate would take turns on it (0.377–0.394 at 0.55
   vs 0.69–0.72 at 1.0). The receipt names it, marks it unsourced, and reports
   the MPa bounds separately — those survive re-sourcing. Sourcing it (coupons)
   is still open.
2. **The law rows are joint-peak, resolution-limited.** ~log-divergent with micro
   resolution (+10–18% per 32→48 step); the band-floor row is a still-rising
   lower bound. The receipt carries a resolution_note.
3. **Out-of-regime designs get labelled numbers, not silence.** Below the
   cells-per-member floor the homogenized macro field itself is out of its
   validated regime; the numbers print WITH the flag.
4. **Octet only.** No other topology has a measured strut law; they report
   nothing rather than octet's numbers.
5. **Layer anisotropy of the BASE material** (PR 247) stacks on top of this
   purely geometric law and is still not in any model.

## Plain language

Since the beginning, every latticed part's report has carried a confession:
"strength uncertified." The software could prove a latticed part was stiff
enough, but not that its thin rods wouldn't snap — checking that needs a
conversion factor between the smeared-out stress the software computes and the
real stress inside one rod. Last week's probe (PR 259) finally measured that
conversion factor, rod by rod, across every density the software prints, and
found the shipped designs would likely fail along their print layers well before
the report implied.

This task takes that measured conversion table and builds it into the product —
as a REPORT, deliberately not as a pass/fail rule. Every latticed part's receipt
now shows two extra safety numbers: one for the rods breaking in general, one for
them splitting along the 3D-printing layers, which is the weaker direction and,
on every design measured so far, the one that governs. The two are shown
separately on purpose, because the maintainer needs to see WHICH one is the
problem. Next to them, the receipt is candid about three things: the layer number
divides by a "how weak are layer bonds" constant that has always been a guess in
this codebase (the raw measured stress is printed too, so the geometry survives
whenever that constant gets measured properly); designs whose walls are too thin
for the underlying math get their numbers stamped "out of regime — indicative
only"; and densities beyond the measured table's edge are pinned to the edge and
counted, never guessed past it.

Why not make it a gate? Because the maintainer asked for numbers to run real
tests against first. The verdict the software gives today is exactly the verdict
it gave yesterday — provably, byte for byte on non-lattice jobs, and by test on
lattice jobs whose new strut numbers read "failing." When physical test results
come back and the guessed constant gets measured, flipping this report into a
gate is a one-line-of-policy change sitting on top of numbers that are already
proven to reproduce the probe exactly.

One more thing was built in quietly: the strut check is a standalone function you
hand a build direction to. That means a future "which way should I print this?"
feature can spin the part in software and re-ask the strut question in every
orientation almost for free — the expensive physics solve happens once.
