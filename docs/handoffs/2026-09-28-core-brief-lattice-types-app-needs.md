# Core brief: what the app needs from core for lattice types, beyond 02-core-spec §5–§6

2026-10-01, from PR #354's app agent to #358 (TASK 2026-09-28-lattice-types-app, U9).
`docs/design/lattice-types/03-app-spec.md` §6 says: when core lacks something, write a brief and
carry on. **The app never edits core and never re-implements a core number in Swift.**

**What this brief does not repeat.** Most of what the app needs is already in core's plan:
- 02 §5's per-type facts struct (family, band, floors, printability floor, aesthetic ceiling,
  finishes and cell modes with reasons, the directional flag, triangle cost, print status);
- the canonical cell; the diameter and density laws; the TPMS field and sampler;
- 02 §6's print-status loader and `lattice-sample`.

The app will read all of those from the BRIDGE CONTRACT when it is published. This brief lists
only what is **not** in 02 §5–§6, or is needed in a particular shape. It comes from a read-only
sweep of core at 4a1ccc45; evidence is in
`docs/handoffs/evidence/2026-09-28-lattice-types-app/` (`map_raw.json`, the core-surface report).

## In plain words

The picker must show every type, grey the ones core doesn't offer, and say why in core's words.
Today core can tell the app which types it can *build* (octet) and *certify* (the seven strut
types), but not:
- why a type isn't offered;
- what the full list of types is, including the sheets;
- whether a type has been printed.

Core's job parser also still refuses any topology but octet. And one question about Stepped under
Structural needs core and the maintainer together.

## Items

**(a) Why a type is not offered: one reason per type.**
- 03 §2 requires every type core doesn't offer to stay visible and greyed, *with core's reason*.
  That includes BCCZ, FCCZ and Re-entrant (M1).
- 02 §5 gives reasons only for finishes and cell modes.
- Ask: each type's offer status, plus one plain line saying why when it is not offered. For
  example "not built yet", "certification needs the tetragonal path (Q4)" or "rows not re-measured
  on the production wall".
- It belongs in the facts struct or beside it.
- Until it exists, the app words its reason from core's two facts (not in
  `lattice_gen_topology_names()` / not in `lattice_certifiable_topology_names()`), and says so.

**(b) One complete list of type ids, sheets included, and one name table.**
- `LatticeTopology` has ten ids and no gyroid or Schwarz-D. "schwarz_d" appears only in
  `lattice_print_tests.json`.
- The generatable and certifiable names come from two separately kept tables:
  `lattice_gen_topology_name` (lattice_gen.cpp:852) and `lattice_topology_name` (lattice.cpp:244).
  The app intersects them as strings.
- Ask:
  - a function listing every id the app should show;
  - the sheet ids fixed;
  - a test that every generatable name round-trips through the certifiable name table, so a
    spelling drift cannot silently grey a live type.

**(c) The job parser accepts each type it makes live.**
- `lattice.topology` and `grading.topology` must be `"octet"` today (job.cpp:1229-1231,
  1735-1737).
- Ask: treat accepting the id in both blocks as part of each type's go-live checklist (02 §4).
- The app gates the offered set on a whole-job parse of each id, with an octet control (U1), so a
  type is offered only when its job would be accepted.

**(d) Print status through the bridge, not a file path.**
- The app bundles only `materials.json`, and has no path to `core/src/materials/lattice_print_tests.json`.
- Ask: the 02 §6 loader exposed as a function: `print_tested`, `date` and `note` for an id.
- Also: how an id missing from the file reads. Today the file has no fccz or reentrant entries.
  The app will treat "absent" as "not print-tested" unless core says otherwise.

**(e) "No ceiling", stated.**
- Sheets use the band maximum until Q1 is answered (R11).
- Ask: how the facts struct says that a type has no aesthetic ceiling, with a reason, so the app
  can grey "Allow quilt" in core's words (U5).

**(f) Sheets: the per-region cell and anchor keys on the job.**
- 03 §5 asks the app and core to agree them through a brief.
- The app will send one cell size per region (R5), anchored where the run anchors it.
- Ask: the key names and the anchor convention, published with K2.

**(g) Can a worker run `lattice-sample`?**
- 03 §2 offers a button on the tag sheet only if the existing worker path can run the command
  without new core work. Otherwise the sheet shows the command.
- Ask: a way to detect the subcommand, for example listed by `topopt-cli version`, or a capability
  flag.

**(h) Strut strength: "not measured for this type" (R10).**
- `evaluate_strut_strength` takes no topology, and the caller gates on octet (analyze.cpp:465).
- Ask: a per-type "measured" flag, so the receipt says "not measured for this type" from core
  rather than from a Swift id check.

**(i) For core AND the maintainer: Stepped / Default Grade under Structural.** This was found while
reporting the #358 probe flips (see `probes_flipped.md` in the evidence folder).
- Since 74e510c4 the app's preview sizes Stepped and Default Grade cells under Structural at the
  beam-network floor: 2 cells per member, against 5 for the homogenised certificate.
- The job names `structural_certification: beam_network` for Stepped only; core refuses the key for
  Default Grade.
- The run calls `certify_organic_structural` only for algorithm organic (run_job.cpp:7488, call at
  7587).
- Ask core: does a Stepped job naming the beam network get that certificate? If not, either core
  runs it for Stepped, or the maintainer rules that the preview returns to the homogenised floor.

**(j) Optional: the frame basis at parse time.**
- Core refuses a RUN, after the solve, when a face region's stated `frame_u`/`frame_w` disagree
  with core's own plane basis (clearance.cpp:254-278, run_job.cpp:1009-1018).
- Since 12ff5880 the in-plane check is at parse time. Checking agreement with the plane basis there
  too would fail such a job before any solve.
- The app's frames are built from the unit normal, but its test pins only +z.

## Not asked: the app's own

These are the app's to fix, type by type, in the sync that lights each type:
- the bridge's octet-only gates (bridge.cpp:3042, 3059, 3106, 3154);
- the Swift aesthetic-ceiling bisection;
- `LatticeType.named()`'s silent octet fallback.

The broken `steppedCellsWired` probe is also the app's, but fixing it moves octet job bytes, so it
waits for the maintainer.
