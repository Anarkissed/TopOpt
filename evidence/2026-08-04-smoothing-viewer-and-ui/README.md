# Evidence — 2026-08-04-smoothing-viewer-and-ui

Handoff: `docs/handoffs/2026-08-04-smoothing-viewer-and-ui.md`

## V1 / V2 — the measurement

* `smooth_viewer_identity_probe.txt` — the full probe run on the maintainer's own
  `WallMount_ShelfBracket.stl` at resolution 96, through the shipped
  `constrained_taubin_smooth` with the min-feature constraint enforced. Answers
  V1 (does the shipped count+bounds viewer signature separate a brushed-smoothed
  mesh from its input?) and V2 (is mesh mass computed from the original mesh?).
  Rebuild + rerun:

      cmake --build core/build --target smooth_viewer_identity_probe
      ./core/build/smooth_viewer_identity_probe \
          core/tests/fixtures/mesh/WallMount_ShelfBracket.stl 96 <evidence_dir>

  Deterministic: two runs are byte-identical apart from the evidence path.
* `smooth_viewer_identity.txt` — the same run's machine-readable summary.

**The headline:** brushing the INTERIOR of the part leaves the shipped signature
IDENTICAL at every strength while 23 vertices have moved by up to 0.59 mm; the
content hash separates them. Mesh mass IS computed from the smoothed mesh and
does move (245.650462 → 245.790474 g on a corner patch) — it was the receipt's
one-decimal print that hid it.

## U7 — the text counts

* `count_standing.py` — the counter, applied identically to both revisions.
  Round 2 is read from `git show HEAD:...SmoothingPage.swift`; run it from the
  worktree root after `git show HEAD:app/TopOptKit/Sources/TopOptFlows/SmoothingPage.swift
  > /tmp/round2page.swift`.

  |                       | round 2 | round 3 |
  |-----------------------|---------|---------|
  | standing prose, at rest        | 998 ch  | 184 ch |
  | controls at rest               | 11      | 11     |
  | standing prose, after 1 stroke | 1225 ch | 184 ch |
  | controls, after 1 stroke       | 13      | 11     |

## B4 — the screenshots, both orientations

Offscreen `ImageRenderer` captures at iPad-11" point sizes (1366×1024 and
1024×1366), the /app/ evidence precedent. The page is CHROME ONLY — the Metal
stage renders beneath it in the app — so these show the chrome over the dark
backdrop. Regenerate:

    TOPOPT_SMOOTHING_PAGE_EVIDENCE=1 swift test --package-path app/TopOptKit \
        --filter SmoothingPageEvidenceGen

| file | what it shows |
|---|---|
| `page_entry_notice_{landscape,portrait}.png` | U6 — the ONE dismissible notice on entry |
| `page_at_rest_{landscape,portrait}.png` | U2/U6 — brush-only modal, nothing standing, two-row cluster |
| `page_brushed_landscape.png` | U1 — three strokes; the panel is UNCHANGED, Re-certify reads "strongest region 0.75" |
| `page_pencil_only_landscape.png` | U2 — Pencil only on |
| `page_certified_note_landscape.png` | U5 — the transient note is the only thing at the top |
| `page_receipt_drawer_{landscape,portrait}.png` | U4 + V2 — the drawer, with Mass (mesh) 182.640 → 182.601 g |

## B5 — suites

* `core_ctest_tail.txt` — the tail of the core run: **100 % passed, 106 of 106**
  (1697 s). `smooth`, `smooth_brush` and `smooth_recert_loadcase` all passed and
  are unchanged by this task.
* App package: **1221 tests, 14 skipped, 8 failures** — all 8 pre-existing, the
  documented lib3mf worktree gap (`app/TopOptKit/vendor/` carries no lib3mf, and
  the refusal says so verbatim).
