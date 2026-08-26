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

---

# `02_quilting_pink_his_camera.png` — THE BEST IMAGE OF THE QUILT

Captured 2026-08-26 02:26 at a camera the maintainer set himself, because it "shows
the quilting (in pink) much better". Same project and settings. **Start here.**

## The key observation — the pink is SOLID, not lattice

The mauve/pink patches scattered across the wall are **flat, angular blobs with no
strut structure inside them**. They are not a fine lattice; they are the march
drawing **solid material**. Compare them against the surrounding truss in the same
image: the truss has visible individual struts and open windows, the pink patches
have neither.

That reframes the quilt entirely. It is not "cells too small" — it is **cells being
rendered as solid**.

## Where that comes from (HYPOTHESIS — not yet verified, test it first)

In `UnifiedShading.swift`, `lsdf_march`:

```
float F = anyActive ? max(dn * cellHere, dClip) : dClip;
```

When `anyActive` is false the cell is drawn as **solid** (`dClip`) by design — that
is the deliberate "where the run leaves it solid, draw solid, do not draw a hole"
rule. So any cell that finds no active neighbour renders exactly like these patches.

And `anyActive` is computed over the 3×3×3 neighbourhood with a **same-lattice
gate**:

```
bool sameLattice = LC.stepped > 0.0
    ? (abs(rgb.b - LC.S) <= 1e-3 * max(LC.S, 1.0))   // same CELL SIZE
    : (int(max(0.0, rgb.g) + 0.5) == LC.L);          // same dyadic LEVEL
```

**Neighbours of a different cell size contribute nothing.** So a cell whose whole
neighbourhood is a different size than itself sees `anyActive == false` and is drawn
SOLID. Anywhere the grade changes cell size, cells can be isolated this way — and
the shape-fit grade creates size changes all over a face.

This is consistent with everything measured: it is immune to density (solid is
solid), it appears under both Stepped and Default (both have size transitions), and
it survives every bake-side check because the bake DID paint those cells — the
march simply refuses to draw their struts.

## How to test it (cheap, decisive)

1. In the bake, count cells whose 26 neighbours are all a different size than
   themselves. If that count is non-trivial and their positions match the pink
   patches, it is confirmed.
2. Or temporarily make `sameLattice` always true and re-render at this camera. If
   the pink patches vanish, it is confirmed. (That is a DIAGNOSTIC only — evaluating
   a neighbour's struts in the wrong cell's frame is what the gate exists to
   prevent, per its own comment. The real fix has to let a differently-sized
   neighbour contribute correctly, or stop isolating cells in the first place.)
