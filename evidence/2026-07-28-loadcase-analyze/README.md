# Evidence — analyze under a declared load case (2026-07-28)

Handoff: `docs/handoffs/2026-07-28-loadcase-analyze.md`.

## Files

- **`test_loadcase_analyze.stderr.txt`** — the L1–L5 test run
  (`core/tests/validation/test_loadcase_analyze.cpp`): **58 checks, 0 failures**.
  L1 self-weight reproduction (bit-identical), L2 loadcase rung reproduction
  (bit-identical), L3 gate accept/reject, L4 deterministic re-run, L5 builder
  precondition + end-to-end loud refusals on the demo l-bracket.

- **`selfweight_analysis.json`** vs **`loadcase_analysis.json`** — the S3 fact, on
  the **SAME 41.44 g solid l-bracket** at resolution 48:
  - self-weight → `margin_worst_case` **2550.7**, `accepted: true`.
  - declared load (`loadcase_job.json`, 60 kN on face 2, anchored on the Ø5 bores)
    → `margin_worst_case` **0.0084**, `accepted: false`.

    A declared load moves the verdict DOWN on unchanged geometry; self-weight never
    can. The loadcase provenance carries `"load_source": "loadcase"`, the group /
    anchor counts, the nodal-load count, and the declared force — no silent
    self-weight fallback. The self-weight provenance has **no** `load_source` key
    (byte-identical to before this change).

- **`loadcase_job.json`** — the CLI load-case job used above (anchors by cylindrical
  selector r=2.5, one force group by raw face id).

- **`L5_out_of_range.txt`** — a load group referencing face 9999 → loud `JobError`
  naming the out-of-range face (exit 1).

- **`L5_zero_force_refuse.txt`** — a zero-force group → the empty-external refusal
  that explicitly declines the self-weight fallback (exit 1).
