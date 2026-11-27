# B10 twins: the kept pages in the simulator (2026-11-11, UI-Notes)

The B10 build (`8560bcb6`, Debug, iOS Simulator) on a new iPad Pro 13″ simulator made for this and deleted after.
Repo fixtures only: `core/tests/fixtures/demo/l-bracket.step`. 13″ landscape, 1376 × 1032 pt, upright.
Each picture is named for its `mockup.html` anchor (plan.md B10: mockup twins for the kept pages).

| Picture | Mockup anchor | What it shows |
|---|---|---|
| `lib-home.png` | lib-home | The Library, his 11-04 look kept; Storage, ⋯ and New project at 44 pt |
| `import.png` | import | New part with l-bracket.step chosen (Browse… at 44 pt) |
| `import-material.png` | import-material | New part's material menu open |
| `topo-setup-gravity.png` | topo-setup (first step) | "Which way is down?" before gravity is set; Optimize waits with its one fix line |
| `topo-setup.png` | topo-setup | Topology Setup, nothing picked: Selections, Settings, Optimize |
| `topo-setup-role.png` | topo-setup (role at the face) | A bolt hole tapped: the role picker at the face keeps clear of the Selections panel (M1) |
| `topo-setup-load.png` | topo-setup-load | Top face 2 as a Load: Gravity │ Push │ Pull, 2.5 kg |
| `corner-settings.png` | corner-settings | The corner's Settings panel open under the view controls (M2); "Allow growth here", "+ Add" |
| `topo-run.png` | topo-run | Optimizing: Step, Elapsed, Time left; Cancel and Run in background |
| `topo-bg.png` | topo-bg | Run in background: "Result 1 of 4 · Tap to view" |
| `cut.png` | cut | Cut ("Editing faces"): its tool rail at 44 pt targets, Discard / Done |
| `cut-line.png` | cut-line | The Line tool armed ("Pencil edits. No pencil here — tap this again to use fingers.") |

## Not taken here, and why

- **Results (topo-results, -stress, -bend, -checks, -details, -orient, -print), topo-landed, topo-same, topo-finding,
  topo-name, topo-delete, topo-corner, topo-nomac**: they need a finished run. The Debug simulator build said "up to
  1 hr 27 min" for the l-bracket at Fast 64³, while #362's census held HEAVY.lock and the disk was at 12 GB free, so
  the run was cancelled at 5 min. The hosted tests cover these pages at all six windows (`B10SweepHostedTests`, among
  them the export danger line and its one "Try again" chip; `UniformChromeHostedTests`; `ResultsModelTests`).
- **Cut's other tools (cut-hole …, cut-ring, cut-pattern …, cut-plane-ask, cut-pieces)**, **lib-project, lib-part,
  lib-compare, lib-project-export, app-settings, view-corner, xray, num-pad*,** and portrait: not taken, to stay lean
  under the shared lock; their reach and fit are in the hosted sweep at all six windows.
- Lattice and Flexible anchors are not kept pages (the lattice twins wait for the rebuild; #362 owns Flexible).
