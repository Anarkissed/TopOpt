# Reference captures — the holes and the quilt

**`01_holes_and_quilt_front_bottom.png`** — captured 2026-08-26 02:24 from the
maintainer's own project on the simulator, armed preview, Stepped · aesthetic ·
single-cell ON · Skin · Fast·64³ · Protect 8 mm, two include faces (15 @ 12 mm,
2 @ 13 mm). This is the area he photographed and the area to work on.

## What to look at in this image

* **THE QUILT** — the fine triangular fabric blanketing the whole wall. Note how
  much finer its pitch is than the cell size the tap callout reports (10–12 mm).
  That mismatch is the point: this texture is the **SKIN diagrid**, not the interior
  truss. Confirm it for yourself by tapping the legend and isolating **Rim & skin**
  vs **Interior fill** — they are different geometries with different pitches.
* **THE HOLES** — the dark patches inside the wall, most visible mid-left and along
  the lower area above the base. They are genuinely empty: tapping inside one
  returns a strut at the hole's EDGE, because the ray passes through and lands on
  the rim.
* The grey band up the middle is the shell (correct — that surface is not declared).

## How these were captured

`simctl io screenshot` writes a real PNG, unlike the MCP screenshot action:

```
xcrun simctl io A030C20C-D243-4CC4-A602-E2A90FB6CCDF screenshot <path>.png
```

Do this before and after every candidate fix, at the SAME camera, and keep both.
Two "fixed" claims were made this session from distant views where the wall reads
as flat texture and neither defect is visible — always capture zoomed in on the
bottom front.

## What the maintainer's own screenshots showed (not reproducible to disk here)

His attachments could not be written to the worktree. For the record, they showed:
the same wall at 02:04 with obvious dark voids and quilt; an earlier close-up where
struts terminated in ragged sawtooth stubs with no nodes joining them (that one was
the incommensurate-cell defect, fixed in `14e5eca3`); and tap callouts reading
`5% · 1.10 mm strut · 12.03 mm cell` and `26% · 0.45 mm strut · 2.01 mm cell`.
