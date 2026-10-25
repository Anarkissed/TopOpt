# Flexible fixtures: his parts (C2, 2026-10-24)

His answer of 2026-10-24 04:54 (via the reviewer): "Feel free to use the pad and L-Bracket." These are copied verbatim with
`git show` from `origin/claude/flexible-screens` (PR #362's branch). They are NOT his squish-rig STEP files, which he had
removed from the repo; those are never used.

| folder | from (`docs/handoffs/evidence/2026-09-29-flexible-screens/round7/…`) | md5 |
|---|---|---|
| `his_pad_1021/project.json` | `batch_u21/his_live_1021_pad/project.json` (9,839 B) | b1e0f885799ee6d2dcf0e697ea985729 (matches #362's 07:03 post) |
| `his_pad_1021/model.stl` | `batch_u21/his_live_1021_pad/model.stl` (684 B) | d574940d5bd417d1110dba0f68e190dc |
| `his_pad_1020/project.json` | `batch_u1/his_live_1020/project.json` (9,654 B) | d076d95179a9306f8e30c5a7ddab4a7a (matches) |
| `his_pad_1020/model.stl` | `batch_u1/his_live_1020/model.stl` (684 B) | d574940d5bd417d1110dba0f68e190dc (the same pad) |
| `his_lbracket_1021/project.json` | `batch_u21/his_live_1021_lbracket/project.json` (3,728 B) | 87a1f65090b290854000ef1c28177f55 (matches) |
| `his_lbracket_1021/model.step` | `batch_u21/his_live_1021_lbracket/model.step` (15,005 B) | d411b79475d2e07851c79a8f0d408594 |

`project.json` is the APP's project file, which core does not read. Core's tests read the models directly and build their own
jobs, labelled as such. The exact jobs the app sends (its encoder plus #354's prism encoding) were asked of #362 on 2026-10-24.
When they arrive they go here as new files, and the tests that quote his numbers re-pin to them.
