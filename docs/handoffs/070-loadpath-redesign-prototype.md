# Handoff 070 — Load-path redesign: 3D motion PROTOTYPE (L-bracket)

**Track:** app — **PROTOTYPE PHASE ONLY.** No native/Metal code touched, no app
load-path code touched, ROADMAP box **not** checked. Deliverable is a browser
prototype the maintainer opens to confirm the animation *feel* before any native
port.

**Worktree:** `.claude/worktrees/brave-yalow-0c4a82` (branch
`claude/loadpath-viz-prototype-11ce74`).

## History / why v2

The first pass was a flat 2D SVG truss (an invented MBB-style shape). The
maintainer opened the real app and correctly called it out: the load path must
live inside the **actual 3D bodies** the app shows — an orbitable, semi-transparent
solid with a stress heatmap, arrows flowing *through* the walls. This handoff
describes the **complete rebuild** as real 3D (three.js) matching THIS app, using
the real demo part `core/tests/fixtures/demo/l-bracket.step`.

## Deliverable

- [`docs/prototypes/loadpath/loadpath-redesign.html`](../prototypes/loadpath/loadpath-redesign.html)
  — the prototype.
- [`docs/prototypes/loadpath/vendor/three.min.js`](../prototypes/loadpath/vendor/three.min.js)
  — three.js r149 (UMD), vendored locally so it runs offline. Must sit in
  `vendor/` next to the HTML.

## How to open it

**Double-click `loadpath-redesign.html`** — it opens in any browser, offline, no
server or build. three.js is a plain `<script>` (global `THREE`), so there's no
ES-module/CORS restriction on `file://`.

(It was also verified over `python3 -m http.server` in Claude's Browser pane, only
because that pane blocks `file://`. You don't need a server. The render loop
self-schedules with a `setTimeout` fallback so it also animates in a
backgrounded/suspended tab.)

## What it demonstrates (the requirements, now in-app)

- **Real 3D L-bracket**, built from the actual STEP geometry: base plate
  `x[-30,30] z[0,8]` + vertical cantilever flange `x[22,30] z[8,60]`, extruded 40 mm
  in y, with the two bolt holes at `(9,0)` / `(-17,0)` shown as **anchor rings**.
  Orbit by dragging, zoom by scrolling.
- **X-ray body** — semi-transparent solid + edge lines, so the paths are visible
  *through* the walls (the core ask). Also a **Stress** backdrop that reproduces the
  app's look: mostly-blue von Mises with a cyan hotspot at the **inner corner**
  `(22,8)` (the real stress concentration), the exact `ASA · scaled to 4 MPa yield
  at 20% gyroid` legend chip, kept semi-transparent so the arrows still read through
  it — i.e. **load path within a stress view**.
- **One red arrow per path**, four paths, each a single glowing comet-arrow
  (tapered tube + arrowhead + additive halo). A yellow **LOAD** arrow presses on the
  top of the flange; every red arrow travels **LOAD → ANCHOR**: down the vertical
  flange, around the inner corner, across the base plate, into a bolt-hole anchor.
- **Alive motion** — the arrow tail undulates with a traveling sine wave, amplitude
  tapering to zero at the head (clean arrowhead), per-path phase/speed offsets so
  they don't beat in lockstep. The wiggle is biased into the part's **wide 40 mm
  depth axis** so it stays inside the 8 mm-thin walls.
- **Default = all animate together; selection isolates one** (the "Isolate a path"
  dropdown in Tune).

## The three "alive" variations (pick one)

In **Tune → Alive motion style**:

1. **Sine** *(default)* — gentle single-sine undulation, steady speed. Calm/legible.
2. **Serpentine** — layered two-sine snake motion, longer tail. Most obviously alive.
3. **Pulse** — low lateral wiggle but surging speed + width "breathing" (thicker
   head). Reads as energy being pushed through.

## Controls

App-style chrome (top bar, right mode rail, mass chips, scrubber) frames it so it
feels native. Functional controls:

| Control | Effect |
|---|---|
| **drag / scroll** on the canvas | orbit / zoom the 3D model |
| **Right rail — Load path** | selects load-path mode (X-ray body) and slides its **tuning drawer** out to the left; re-tap or the drawer's ✕ closes it |
| **Right rail — Stress** | swaps the body backdrop to the stress heatmap (closes the drawer). Flex/Failure are inert placeholders. |
| **Scrubber** (play/pause + slider) | play/pause and scrub the flow animation (6 s loop) |
| **Drawer → Alive motion style** | the 3 wiggle presets above |
| **Drawer → Isolate a path** | solo one path, or "All paths (default)" |
| **Drawer → Body** | X-ray / Stress / Solid backdrop |
| **Drawer → Flow speed / Wiggle amount** | tune travel speed and undulation depth |
| **Drawer → Reduced motion (static)** | freezes arrows mid-path with clean heads — the accessible static presentation |

## Notes for the Metal port

- **Nothing is physically solved.** The L-bracket mesh is procedural (extruded L
  profile, no CSG holes — bolt holes are cosmetic rings); the stress colors are a
  mock distance field to the inner corner; the four paths are hand-placed splines.
  All of it is to judge look & motion, not accuracy.
- Motion knobs worth carrying into Metal: per-path phase/speed offset (keeps arrows
  desynced), head-anchored amplitude taper (clean arrowhead), comet radius taper,
  additive halo for glow, and **undulating along the body's widest local axis** so
  the wiggle never pokes through a thin wall. The three styles are presets of one
  parameter set `{amp, waves, wSpeed, bodyLen, speedPulse, breath}`.
- The real port would offset the arrow centerline along the actual derived
  principal-stress polyline (the app's existing load-path data) instead of the mock
  spline, and rebuild the tube/arrowhead in the `loadpath_vertex`/`loadpath_fragment`
  pipeline (replacing the current traveling-dash ribbon in `MetalMeshView.swift`).

## Explicitly NOT done (per assignment)

- No change to the real app load-path / Metal renderer
  (`app/TopOptKit/Sources/TopOptFlows/**` untouched).
- No Metal port of the confirmed design — that is the follow-up task.
- ROADMAP box not checked.

## Suggested next step

Maintainer opens the HTML, orbits the L-bracket, picks a motion style (and tunes
speed/wiggle), then a later task ports the chosen preset to the Metal load-path
pipeline, driving it from the app's real per-path stress polylines.
