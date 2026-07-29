# Landing PR 237's measured octet rows into the production tensor table

**Date:** 2026-07-29
**Scope:** production data change. Transcribes PR 237's measured & validated octet
homogenized tensors into the live `kOctet` table, widening the certifiable octet
density band from `0.14764–0.59093` to `0.05047–0.89988`. No new machinery — the
band-derivation, grading law, and certification solve are unchanged; they simply read
a wider table.
**Builds on:** PR 237 (`evidence/2026-07-28-density-band-extension` — measured the
extended library, evidence-only), PR 234 (validated the 0.15–0.54 band within ±2.4%),
PR 198 (the original vpc48 library), the lattice grading law
(`docs/handoffs/2026-07-29-lattice-grading-law.md`).
**Code:** `core/src/fea/lattice.cpp` (the `kOctet` table; `rows_of` returns main's
size-agnostic `RowTable`),
`core/include/topopt/lattice.hpp` (band docstring),
`core/tests/validation/test_lattice_certification.cpp` (the band-range assertion).
**Evidence:** `evidence/2026-07-29-octet-rows-land/`.

---

## TL;DR

PR 237 measured octet tensors down to rho ~0.05 (vpc128 converged truth) and up to
rho ~0.90 (vpc48 validated vs vpc64), each end within ±2.4% of periodic-homogenization
truth, and wrote them to `proposed_octet_rows.txt` — but changed **evidence only**. So
production still carried PR 198's 8-row table (band 0.14764–0.59093) with a hard clamp
at 0.591 that read up to −153% low above it, and a floor at 0.148 that aliased below.

This change transcribes the 19 proposed rows into `kOctet` verbatim. Because the band
is **derived** (`resolved_span()` → `lattice_rho_min/max`) and every consumer reads
those functions, widening the table is the whole change: the grading law and the
certification gate pick up `0.05047–0.89988` with no edit of their own.

## What changed

- `kOctet` grew from `std::array<Row, 8>` to `std::array<Row, 19>`. After the rebase
  onto PR #246 (below), that is the ONLY structural change needed: #246 already made
  `rows_of` return a `RowTable` view (pointer + size) by value, so it reports
  `kOctet.size()` = 19 automatically and every accessor is size-agnostic. `kOctetDia`
  (the strut-diameter table, a separate `DiaRow` array) is untouched.
- The 19 rows: 5 NEW low (0.05047–0.11908, vpc128), the 7 EXISTING MID rows
  (0.14764–0.59093, PR 198 vpc48, **bit-identical**), 7 NEW high (0.61509–0.89988,
  vpc48 validated vs vpc64).
- The old single `0.10308` row (the only `resolved=false` row) is **dropped**: it was
  the under-resolved wall-<4-vox row PR 198 excluded from every fit, and it is
  superseded by the genuinely-resolved vpc128 low rows. All 19 rows are `resolved=true`
  per PR 237's convergence verdict, so `resolved_span()` returns `[0, 18]` and the band
  is the full 0.05047–0.89988.
- Header docstring for `lattice_rho_min/max` and the `Row::resolved` comment updated to
  describe the widened, all-resolved band (no more "excluded under-resolved row").
- One validation assertion (`test_lattice_certification.cpp`) that hardcoded the old
  floor (`lattice_rho_min > 0.1`) updated to the new band (`> 0.04 && < 0.10`, max
  `> 0.85`). This was the only test that assumed the old numbers; `test_grading` reads
  the band from core and adapts automatically.

## Bars (all met — see `evidence/2026-07-29-octet-rows-land/`)

- **T1 exact transcription** — `row_diff.txt`: normalized `rho,C11,C12,C44,resolved`
  rows from `lattice.cpp` vs `proposed_octet_rows.txt`, diff empty. 19 = 19.
- **T2 resolved flags** — all 19 rows `resolved=true` (PR 237's verdict: every row
  resolved & validated). `resolved_span` → `[0,18]`.
- **T3 band** — `lattice_rho_min = 0.05047`, `lattice_rho_max = 0.89988`
  (`verify_output.txt`).
- **T4 old rows unchanged** — the 7 MID rows reproduce bit-for-bit (`verify_output.txt`
  §T4). PR 234's validated 0.15–0.54 band is byte-preserved.
- **T5 grading unchanged, wider band** — `test_grading.txt`: 23360 checks, 0 failures,
  against the committed table; `grading.cpp` not edited. Its L2 assertion (every
  emitted density inside `[rho_lo, rho_hi]`) holds with the wider bounds. Clamp bounds
  before/after in `verify_output.txt` §T5.
- **T6 non-lattice byte-identical** — the certification test's
  `"no posture => byte-identical path"` case passes; call-site inspection shows the
  changed symbols are only reachable behind `has_lattice` / the lattice path
  (`README.md`).
- **T7 interpolation at the extremes** — `verify_output.txt` §T7: exact endpoints
  return the endpoint rows un-clamped; rho below 0.05047 / above 0.89988 clamps to the
  endpoint with the flag set; interior midpoints return the exact linear mean. The
  `a+1 <= hi ? a+1 : hi` guard cannot walk `a` past `hi-1` once rho is clamped, so both
  new ends are safe.

The real `test_lattice_certification` validation test passes in full (ALL PASS, 0
failures — `test_lattice_certification.txt`), including the composite certification gate
exactness and the updated band-range assertion.

## Follow-up 1: section-2b stale probe radii (CI failure)

`main` gained PR #242 (`lattice-certification-e2e`) after this branch forked — it added
`octet_relative_density` and test sections 2b/2c. CI (which tests the PR *merge*) failed
2b's `"a thin strut maps BELOW the band"` and `"a fat strut maps ABOVE the band"`
because those probe radii were chosen against the OLD band and now land inside the
widened one.

This was **not** a mapping regression: `octet_relative_density` is pure geometry
(voxelizes one unit cell on the vpc48 basis) and never reads `kOctet`, so each `r/L`
maps to the same rho as before — only the band edges moved. Confirmed by computing the
mapped rho for the old radii against both bands (`section2b_radii_diagnosis.txt`):
`r/L=0.06 → 0.0951` (was BELOW 0.148, now INSIDE) and `r/L=0.21 → 0.6674` (was ABOVE
0.591, now INSIDE). 2c still passed throughout because it feeds explicit out-of-band
rho values, not radii.

Fix: re-picked the two probes as **r/L ratios** (called as `octet_relative_density(1.0,
r/L)`, cell-invariant) with margin outside the octet band: thin `r/L=0.03 → rho ~0.0148`
(< rho_min), fat `r/L=0.34 → rho ~0.963` (> rho_max, < 1). Expressing them as ratios
rather than bare radii makes the band dependency explicit so the next band move surfaces
loudly, not silently.

## Follow-up 2: rebased onto PR #246 (nine-topology library)

`main` then gained PR #246 (`tensor-library-nine-topologies`), which added eight more
topology tables (sc/bcc/fcc/diamond/kelvin/rhombic + tetragonal bccz/fccz/reentrant) to
the same file. This is the structural point: #246 replaced `rows_of`'s
`const std::array<Row,8>&` return with a **`RowTable` view (pointer + size) returned by
value** — precisely the representation that lets octet be 19 rows while the others stay
8 (and the tetragonal ones return `{nullptr,0}`). Rebased this branch onto #246 and kept
`RowTable`; the only edit `rows_of` needed was none — `{kOctet.data(), kOctet.size()}`
reports 19 on its own. (std::span was the alternative, but the tree is C++17 and
`RowTable` is the already-proven in-tree idiom, so no new vocabulary type was warranted.)

Both changes survive and were re-verified on the rebased tree (`rebase_onto_nine_
topologies.txt`, `verify_per_topology_bands.txt`): octet band `[0.05047, 0.89988]`; each
other topology reports its OWN band from its own resolved rows (sc `[0.087,0.496]`, bcc
`[0.211,0.593]`, fcc `[0.095,0.591]`, diamond `[0.157,0.592]`, kelvin `[0.094,0.505]`,
rhombic `[0.172,0.513]`); octet MID rows still bit-identical; the B2 anchor (0.29731) and
`fcc == octet-legs` cross-check still hold; tetragonal still refused. Full
`test_lattice_certification` ALL PASS (sections 1, 2, 2a, 2b, 2c, 3, 4&5);
`test_grading` 23360 / 0.

## Carry-forward

- **Near-solid rows (>~0.85) still owe a strut-strength de-homogenization** — PR 237's
  note stands: the STIFFNESS tensor at the high rows is converged and validated, but a
  de-homogenization step (named in `2026-07-26-lattice-homog-phase0`) should ride
  alongside for strut strength. The certification path already flags strut-level
  strength UNCERTIFIED (Phase 2) — see the cert test's
  `"strut-level strength flagged UNCERTIFIED"` case — so this widening does not silently
  certify near-solid strut strength; it certifies stiffness.
- **The ±10% resolution caveat in `lattice.hpp`** predates PR 237's convergence work;
  the low rows are now vpc128 converged rather than the least-reliable, but the general
  header caveat is left as a conservative reminder.
- **CI build** is unchanged (`cmake -S core -B build` + vcpkg + `ctest`). The evidence
  recipes compile standalone against Homebrew Eigen to avoid the OCCT install; they are
  a convenience for reproducing this specific change, not a replacement for CI.
