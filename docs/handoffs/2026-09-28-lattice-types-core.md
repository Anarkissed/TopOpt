# Handoff — 2026-09-28-lattice-types-core: eight lattice types, round 1 (TRACK core)

## Where this stands, in plain language

**Types live so far: none. Types parked: none. K0 (the inventory) is done; K1 starts
with FCC.**

This is the first commit of the round and it deliberately contains no code. The spec
requires the octet-only inventory to be written *before* any code
(`docs/design/lattice-types/02-core-spec.md` §1), and writing it first changed what I
think the round is. The short version:

- The **certification half is already done.** `LatticeTopology` carries all ten ids,
  and `lattice_cubic_tensor`, `lattice_rho_min/max`, `lattice_resolved_rows` and
  `lattice_topology_certifiable` are already per-type with the six strut types' rows
  landed. Nothing in this round has to make a strut type *certifiable*.
- What is octet-only is the **generator** (one enum value, one `throw`) and the
  **practical numbers**.
- The round is dominated by **one substitution**: `octet_strut_diameter_mm(rho, cell)`
  is called from **44 places**, none of them topology-aware. Ten of those are inside
  `lattice_cell_printability_floor_mm` and `lattice_min_density_for_strut` — two
  functions that already **take a topology argument and ignore it**. Twenty are inside
  `run_job.cpp`'s anonymous namespaces, where no unit test can reach them.
- So the first real work is not FCC's geometry. It is giving those two functions a
  per-type table, because most of the other sites then follow, and R9 (octet
  byte-identical) is an exact test of whether the plumbing change was safe.

## What I did

1. **Branch.** Committed the tail of the #354 follow-ups as its own commit
   (`478ad2c7`, docs only — the convex-edge open item the reviewer asked to record),
   then `git fetch origin && git merge --no-ff origin/main -m "Sync: merge main"`
   (`266e1bd3`). No conflicts, as the reviewer's trial merge predicted. The merge
   brought #359 (Flexible pack), #360 (this pack,
   `core/src/materials/lattice_print_tests.json`, the DECISIONS entry) and five papers.
2. **Blocked checks, all clear.** The `2026-09-28: LATTICE TYPES ROUND 1` entry is at
   `docs/DECISIONS.md:203` with all nine items. The pack is complete (7 files + data).
   `core/src/materials/lattice_print_tests.json` exists (1310 bytes) and is identical
   to the pack's seed copy; I have not touched it.
3. **Read** ARCHITECTURE.md, the DECISIONS entry, AGENT_PROMPTS §1, and the pack
   (README, 00-decisions, 01-types, 02-core-spec, 05-roadmap; skimmed 03-app-spec).
4. **K0 — the inventory**, in
   `docs/handoffs/evidence/2026-09-28-lattice-types-core/k0_inventory.md`. 366
   mentions across 34 files, every behavioural site classified (a)/(b)/(c), line
   numbers re-grepped at the merged head rather than taken from the spec (the spec's
   were at `daa764c4` and several had drifted).

## Test evidence (raw, pasted, unedited)

Baseline suite on the merged head, **to record inherited failures before any change**:

```
<pending — the run is in flight; this section is filled before the next commit>
```

CI run: maintainer to fill
PR: #358 (`claude/raster-receipt-fields`)
New tests added: none yet — this commit is the inventory only.

## What I did NOT do

- **No code.** No type is live; `lattice_gen_topology_names()` is unchanged.
- **No measurements yet.** Every per-type number in §2 of the inventory is still
  octet's. Nothing has been borrowed *into* a new type, because no new type exists.
- **Did not answer any Q.** Q1–Q5 are the maintainer's; in particular the octet
  legs-only question (Q2) is K5, which measures and reports and changes nothing.
- **Did not verify the baseline suite before writing the inventory.** The inventory is
  a read-only census, so it cannot be invalidated by a red suite; but if the baseline
  comes back with failures I inherited, the round's first task becomes restoring green
  per AGENT_PROMPTS §1, and I will say so rather than build on it.

## Warnings for the next run

- **`octet_strut_diameter_mm` cannot be fixed by search-and-replace.** 20 of its 44
  call sites are inside `run_job.cpp`'s anonymous namespaces; a mechanical rename
  there would compile and would not be testable. Lift the decision, per this week's
  rule.
- **Seven struct members default `LatticeTopology` to `Octet`** (`grading.hpp:172`,
  `cell_plan.hpp:187`, `lattice_material.hpp:92`, `analyze.hpp:52`/`:159`,
  `pipeline.hpp:499`/`:559`). They are harmless today because callers set them, and
  they are exactly the shape of a silent default. Under this round's rule ("a
  can't-happen still refuses") a caller that fails to set one must refuse rather than
  inherit octet. Assert it; don't trust it.
- **`lattice.hpp:63` already records the legs-only labelling gap** for octet's tensor
  and says it is "documented, not silently changed". K5/Q2 is the measurement of that
  gap. Do not let a per-type change quietly resolve it.

## Open items

- **A real part with a convex edge inside a lattice region** (carried from the #358
  follow-ups, reviewer 2026-09-30): the only term that can separate
  `lattice_certification_mask` from the posture on a real part is the shell base
  rejecting posture voxels at a convex edge. No fixture exercises it; to be built only
  if a probe/run mismatch appears.
