# Lattice types, round 1 — reference pack

**Plain language:** today the Structural and Aesthetic stages can only build the Octet truss; every other type is shown greyed. This round adds eight more:
- six strut lattices: **Simple cubic, BCC, FCC, Diamond, Kelvin, Rhombic dodecahedron**;
- two sheet lattices: **Gyroid, Schwarz-D**.

Most of the hard physics was measured in July, and core already holds the stiffness tables for all eight. Two kinds of work are missing:
- the octet-only parts: the generator, the density-to-strut-size law, the size limits, the size steps, and the preview;
- a few measurements that were never taken for anything but octet.

This pack covers:
- what the maintainer decided;
- what each type needs;
- the gates a type must pass before it can be picked;
- where every number comes from.

Drafted by the reviewer (Claude) on 2026-09-28 from the repo's own handoffs and evidence plus the published papers. **Committed by the maintainer.**

## Read in this order

| File | What it is |
|---|---|
| `00-decisions.md` | Maintainer decisions (binding), reviewer defaults (keep unless overridden), open questions, and the DECISIONS.md entry. |
| `01-types.md` | The eight types. What is already measured for each and what is still owed. |
| `02-core-spec.md` | Core work: the octet-only inventory, the per-type measurements, the gyroid/Schwarz-D spec, the go-live gates and the bridge API. |
| `03-app-spec.md` | App work: the picker, the print-tested tag, per-type previews, and the modes a type can't use. |
| `04-references.md` | Every source, with the specific finding it supports: papers, repo evidence and physical prints. |
| `05-roadmap.md` | Build order, who does what, and how the branches sync. |

## Data (`data/`)

| File | Contents | Status |
|---|---|---|
| `lattice_print_tests.json` | Which lattice types the maintainer has physically printed, and when. | Seed. The live copy is `core/src/materials/lattice_print_tests.json`. **Maintainer data**: agents read it and never edit it. The maintainer clears a type's "Not print-tested" tag by editing the live copy. |

Every measured number this pack cites lives in the repo's own evidence folders (paths in `04-references.md`). The pack copies none of them; agents read the evidence directly.

## Rules for agents

- **Maintainer data** (`lattice_print_tests.json`, `materials.json`, fixtures, `flexible_*`) is never edited. Propose changes under `## Blocked`.
- **No borrowed numbers.** A number measured for octet is never used for another type. A type can't be picked until its own numbers exist (`00-decisions.md` R1).
- **Octet stays byte-identical**: its outputs, its tensor and its receipts.
- Where this pack and `DECISIONS.md` disagree, **DECISIONS.md wins**. Where either disagrees with `ARCHITECTURE.md`, stop and report.
- The standing bar: no "not possible / not printable / not viable" verdict without naming the sources in `04-references.md` that show it is, and saying why they don't apply.
