# evidence — 2026-08-15 lattice-and-face-ui

Base commit: **`247a6bbc`** (PR 331 `d4bf1a05` and PR 334 `247a6bbc` both merged).

| path | what it holds |
|---|---|
| `s0/STYLE_RULES.md` | ★ §0's HARD BAR: the 18 style rules read off the Topology screenshot, each with the token and the source line it comes from |
| `s0/topology_page.png` | the Topology screen BEFORE any change (the §0 screenshot) |
| `s0/topology_after.png` | the same screen after §4 |
| `s0/crop_top.png`, `s0/crop_bottomright.png` | the two regions §4 is about |
| `s0/topology_after_top.png` | ★ §4 ON DEVICE, TO stage: "Lattice" at its ORIGINAL size (64 pt) and slot — top of screen, left of the gizmo, top-aligned with it rather than centred on it — in `accentDeep` |
| `s0/lattice_stage.png`, `s0/lattice_stage_top.png` | ★ §4 ON DEVICE, lattice stage: "Topology" moved TOP-LEFT under the project name (fill left edge **24.0 pt**, identical to the back chevron; height **49 pt** against the name capsule's 52.5, same `.padding(.vertical, 9)` construction) and "Settings" moved UP into the top-right slot. All three navigation buttons `accentDeep`. The gizmo has not moved. |
| `s0/nav_vs_action_blue.png` | ★ THE POINT OF `accentDeep`: "Lattice" `rgb(10,77,143)` beside "Optimize" `#0A84FF` — navigation vs action, sampled from the same frame |
| `s0/s2a_missing_primitive.txt` | ★ §2(a) measured on his part: 19 of his 22 declared faces (86.4%) drew NOTHING |
| `s12/RESULT.md` | ★ §12 "Lattice This" — verified from the CLI, and why it is a §12(e) STOP |
| `s12/job/` | the two analyze jobs (with and without declared lattice regions) |
| `s12/out_analyze/`, `s12/out_regions/` | their receipts — the grading blocks that are byte-identical |

## Reproduce

```bash
# §2(a) — the missing primitive, on his own part
cmake --build build --target lattice_primitive_probe -j8
./build/lattice_primitive_probe evidence/2026-08-15-lattice-and-face-ui/s12/job/M2_verticalStand.step 128 \
    20 1 4 19 21 22 25 26 27 32 41 42 43 44 45 46 47 49 75 76 24 31

# §12 — lattice-only on the solid part, with and without declared regions
cmake --build build --target topopt_cli -j8
./build/topopt-cli analyze evidence/2026-08-15-lattice-and-face-ui/s12/job/job_analyze.json \
    --out evidence/2026-08-15-lattice-and-face-ui/s12/out_analyze \
    --materials core/src/materials/materials.json
```

## Suites, with their denominators

**App** — `swift test` in `app/TopOptKit`:

```
1550 tests, 22 skipped, 8 failures
```

★ **All 8 failures are the SAME environmental gap and none of them are this
task's**: this machine's core slice has no lib3mf, so three `AppModelTests` 3MF
cases refuse before they test anything ("3MF import requires lib3mf, which is not
available in this build"). The honest reading is **1542/1550 HERE and 1550/1550 in
CI, and the three 3MF tests DID NOT RUN.**

The baseline taken BEFORE this task's changes was `1524 tests, 22 skipped, 8
failures` — the same three cases. This task adds **26 tests** and moved the
failure count by **zero**.

★ **THREE TESTS FAILED MID-TASK AND WERE FIXED RATHER THAN WEAKENED**, each
because a DEFAULT the maintainer asked to move was pinned as a literal:

* `LatticeRetentionControlTests.testUntouchedControlsSerializeToTheIdentical{Job,
  RelatticeJob}` — the boundary default moved `.fullSkin` → `.none`, so the
  fixture now STATES `boundary = .fullSkin` to match the legacy snapshot it is
  compared against. The file already set that precedent for `cellSizeMode`, for
  exactly this reason: a fixture that silently tracks a default measures whichever
  default is current rather than the thing it names.
* `VariantEntryGatingTests.testChoosingRimOnlyWarnsAndIsNotTheDefault` — pinned
  `.fullSkin`. Its SUBJECT is "the default must never be a treatment that silently
  emits nothing", and `.none` satisfies that. Rewritten to assert THE RULE
  (`boundaryProducesNothing(default) == nil`, which holds for any future default)
  plus `!= .rim` — strictly stronger than the value it replaced.

The `DesignOverhaulRound2Tests` chip-order changes from an earlier attempt at
§4(b) were REVERTED with the chip itself; both files are byte-identical to base.

**Core** — the probes built here are `EXCLUDE_FROM_ALL` and add nothing to CI's
test count. `lattice_primitive_probe` is a new harness (not a test).
