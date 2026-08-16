# 2026-08-15 — lattice and face UI: the page, and what is still not done

Evidence: `evidence/2026-08-15-lattice-and-face-ui/`
**Base commit: `247a6bbc`** — PR 331 (`d4bf1a05`) and PR 334 (`247a6bbc`) both
merged, as required.

> **"I don't want to fix this whole fucking page a 3rd time."**

★ **I did not finish this page.** Sections 6 (CAD-surfaces mode) and 7 (the
pattern tool) are **NOT BUILT**. They are the last two on the brief's own priority
list and they are the two I ran out of room for. (§10, the finishes, WAS built —
after the maintainer asked for it directly in review; see §10.) Everything above them is done and measured. **§13 says
exactly what is missing and what it would take**, because a page half-rebuilt and
described as finished is how this gets fixed a fourth time.

---

## §0 — THE ANSWERS, ONE LINE EACH

**Why was a primitive missing, and what fixes it?** `latticeDepthPlanes()`
required `geo.isPlane` before it would build a face's primitive
(`ProjectModel.swift:925` at base) and `continue`d silently otherwise; the region
path refused four more ways, three of them just "the region is curved". ★ On his
own part that is **19 of the 22 faces he declares — 86.4% — drawing nothing**, and
42 of the part's 78 (53.8%). Fixed by making the primitive the **distance-field
offset of the face's own surface** (`FaceOffsetShell`), which is one rule for
planes, cylinders and everything else, so there is nothing left to skip on.

**The row count for his 3-face load selection: 23 → 1.** `latticeSelectableRefs`
returned the regions **plus every raw face**, unconditionally — so his 22-face
load group combined into one region rendered **1 region row + 22 face rows = 23**.
A face a region covers is now that region's collapsed child.

**The exact badge and (i) text for the 3.0-cells-across card** — pasted in §3
below, including the strut failure his panel never mentioned.

**Where the swept range collapses to a scalar:** ★ **`LatticeSettings.swift:801`,
and it was the WRONG FLOOR.** It clamped *both* window ends up to
`LatticeBounds.cellFloorMM` — core's **light**-end floor, 4.93 mm — so his
2.0–4.0 mm window reached the job as **4.93–4.93**. min == max ⇒ one dyadic level
⇒ `distinct_cells: 1` and one strut radius. It now uses the **dense** floor
(~1.17 mm), which is the floor the app's own typed entry was already bounded by.

**How many numeric inputs gained typed entry: 5** (2 wizard scrubs, 2 swept range
ends, 2 depth fields — the two depth routes share one mechanism). Full inventory
in §5.

**Does each finish render? YES — BUILT after the maintainer asked for it
directly.** ★ The root cause was an ABSENCE: `LatticeSamplePatch.mesh` had **no
`boundary` parameter at all**, so None / Rim / Skin produced byte-identical
geometry and the chips were decoration. Rim is now a beam frame along the block's
twelve edges; Skin is the anchored diagrid on its six faces. ★ AND A SECOND FAULT
UNDER IT: the Auto-density cinematic ends with `dive()` (zoom 0.45, INSIDE the
lattice) and a boundary swap only cross-faded the mesh — so correct geometry was
being drawn from a viewpoint buried in the struts. A finish is something you look
at from outside, so showing one now re-frames. Latency, per finish, on the sample:
**None 769 ms · Rim 752 ms · Skin 800 ms**, all at 118,920 triangles.

**What remains purple or green:** full census in §4. Nothing purple remains as
CHROME. The greens that remain are verdict/role colours, listed with reasons.

**★ AND §12's number, because it is the largest single result here:** a
lattice-only run on his part latticed **107,823 voxels — 97.2% of the printed
solid — against the TO+lattice run's 13,034 and 12%. 8.27×.** It also does **not**
apply declared regions and does **not** export, so §12 STOPS at its own gate.

---

## §12 — "LATTICE THIS": VERIFIED, AND IT IS A §12(e) STOP

Full workings: `evidence/2026-08-15-lattice-and-face-ui/s12/RESULT.md`.

★ **First, the brief's own line numbers are wrong on this tree.** §12(b) says
"`grade_lattice` LIVES ONLY INSIDE `analyze_job` (run_job.cpp 866-1313)" and
"`run_job` itself (1313+) contains ZERO grading references". Neither holds:

| function | lines | grades? |
|---|---|---|
| `analyze_job` | `run_job.cpp:5339-5989` | yes — `grade_lattice` at **`:5744`** |
| `lattice_variant_job` | `run_job.cpp:5990-7008` | yes |
| `run_job` | `run_job.cpp:7009-end` | yes — the ladder's call at **`:3444`** |

**It runs, end to end, with no topology optimisation** (Release `topopt-cli`, his
own captured job with only `"mode"` changed to `"analyze"`):

| | **lattice-only** | his TO+lattice run |
|---|---|---|
| latticed voxels | **107,823** | 13,034 |
| lattice share | **97.2 %** | 12 % |
| cells per member (min) | 5.1158 (floor 5) | — |
| any strut below the nozzle | **false** | — |
| margin | 2161.5, ACCEPTED (required 1.5) | — |
| mass | **681.95 g** solid as drawn | 543.7 g solid / 507 g latticed |

★ The denominator checks independently: 681.9546 g ÷ 1.24 g cm⁻³ ÷ (1.70528 mm)³
= 110,899 against the receipt's `region_voxels` 110,904.

★ **This is the failure §12 named, inverted.** The TO+lattice receipts on this
tree show `include_void_by_optimizer` = **99,469 of 99,469** — every empty
include voxel was empty because the optimizer removed it. With no TO there is
nothing to remove.

### But two of the five verbs do not work, so it stops

**GAP 1 — `analyze` IGNORES `lattice.regions`. Measured, not read.** I ran the
same job twice, the second declaring an identity face region on his protected face
16 and a region-backed include on it. **The entire `grading` block is
byte-identical** (`region_voxels` 110,904 both times). Cause: `run_job.cpp:5744`
passes **`nullptr`** as the candidate region set where the run path passes
`&cand` (`:3444`); the comment at `:5726` says so outright. Declared regions are
consulted only in `Fit` cell mode, and only to build `fit_field`.

**GAP 2 — `analyze` does NOT export a lattice.** No `generate_lattice` call, no
`emit_stl` arm, no `lattice_export_*` field in `analyze_job`; those live at
`run_job.cpp:1730/1760`, `:1821` and `:8522+`. `out_analyze/` contains no `.stl`.

**So no button was added and no pipeline was built** (§12(e)). A "Lattice This"
wired to `analyze` today would lattice the whole part and silently discard every
region the user declared — the exact defect §8(e) forbids one level up. What it
needs: pass `&cand` at `:5744` in every cell mode, and factor `run_job`'s
generator/export arm so the analyze tail can call it. Both are core changes and
R15 keeps core untouched.

---

## §0 (the bar) — THE STYLE RULES, AND EVERY CONTROL CHECKED AGAINST THEM

`evidence/…/s0/STYLE_RULES.md` holds 18 rules read off `s0/topology_page.png`,
each naming its token and the source line it comes from. The checks:

| control | rule | verdict |
|---|---|---|
| "Lattice" (TO page) | S13 radius 20, **S19 navigation blue**, **S20 top-right slot** | ★ 64 pt and the slot unchanged; fill `accentGreen` → `accentDeep`; top-aligned with the gizmo, not centred on it |
| "Topology" (lattice page) | S13 radius 20, **S19**, **S21 top-left under the name** | ★ moved top-left under the project name, thinned to the name capsule's own construction |
| "Settings" (lattice page) | S13 radius 20, **S19**, **S20** | ★ was `densityColor(0.75)` (purple); now `accentDeep`, and moved UP into the slot Topology vacated |
| Struts preview chip | S7 accent tint | ★ was `densityColor(0.75)`; now `DS.Color.accent` |
| diagnosis badge (§3) | S13 pill radius, S16 warning colour | matches |
| (i) pop-up (§3) | S14 panel surface, S13 radius 20 | matches |
| region child rows (§1) | S15 readout = bare text, no capsule | matches — children carry NO chips |
| drawer Density row (§8) | S15 chip = control | matches — capsule + `fillSelected`, only when per-region |
| swept range fields (§9) | S15 control, typed per §5 | matches |
| per-region gap note (§8e) | S16 warning colour | matches |
| wizard card (§11a) | S13 radius 22, S14 panel | matches; no longer holds editors |

---

## §1 — THE LIST SHOWS REGIONS

**Root cause, one function.** `ProjectModel.latticeSelectableRefs` returned

```swift
latticeRegionRefs(g) + g.faces.map { .face(...) } + primitives
```

— the regions **and every raw face**, always. His captured job
(`evidence/2026-08-07-lattice-variants-on-screen/run_his/job.json`) carries **one
load group with 22 face ids**, so combining them gave **23 rows**, each with its
own Lattice/Solid/Off chips, its own depth and its own out-of-regime readout.

**The fix.** A face any region of the group resolves to is subtracted from the
top-level list (`latticeRegionCoveredFaces`) and appears as that region's **child**
when the region is expanded (`latticeRegionMemberFaces` →
`latticeRegionFaceChildren`), with **no chips of its own** (§1b) — role, lattice
choice, depth and verdict are the region's.

★ A **collapsed** parent still owns its faces, so a face cannot reappear as a
top-level row merely because the row holding it is shut
(`testACollapsedRegionStillHidesItsFaces`).

★ **PR 331's disclosure is reused, not duplicated** — the region row's chevron
writes `FaceRegion.collapsed`, exactly as before.

★ **What I did NOT do:** wire PR 331's filters and Combine into this list (§1c).
They remain reachable only from the Regions sheet. The 22 → 2 measurement is PR
331's and stands; what this task changed is the ROW COUNT once combined, which is
the half that was broken.

---

## §2 — THE PRIMITIVE

### (a) A primitive is ALWAYS created — root cause, with the number

`lattice_primitive_probe` on `M2_verticalStand.step` at 128
(`evidence/…/s0/s2a_missing_primitive.txt`):

```
plane            36  (46.2%)   <- these got a primitive
cylinder         12  (15.4%)   <- NO PRIMITIVE
other            30  (38.5%)   <- NO PRIMITIVE
★ 42 of 78 faces (53.8%) DRAW NOTHING when set to Lattice.

HIS DECLARED FACES
declared        22
get a primitive  3
GET NOTHING     19  (86.4% of his own selection)
```

So "in many cases" is **86.4% of the faces he actually selects.**

### (b) The shape is the shape of what was selected

★ **The primitive is the isosurface of distance-to-the-face at the depth value**,
evaluated on the face's own tessellation (`FaceOffsetShell.build`). There is **no
`switch` on surface kind anywhere in that file** — the three behaviours fall out
of the one rule:

* **PLANE → a slab** (every vertex travels one direction) — asserted
* **CYLINDER → an annular tube** — his doughnut — asserted radially, per vertex
* **ANY CURVED FACE → a shell that follows it** — asserted on a region whose
  members are *all* curved

★ **It cannot self-intersect.** `curvatureLimitMM` measures the discrete radius of
curvature per edge (arc length ÷ turned angle, concave edges only) and clamps the
travel there — where a distance field stops growing and where a true surface
offset folds. Asserted on a radius-2 concave arc: a 50 mm request reaches 2 mm.
★ **The clamp is REPORTED** (`clampedFromMM`), never silent.

★ **The declared B-rep normal wins the SIGN.** Winding alone is not safe: the
emission reads `StepFaceGeometry.planeNormal`, and a mesh whose winding disagrees
would put the picture on the opposite side of the wall from the region the run
freezes. Caught by an existing fixture that winds two walls identically while
declaring opposite normals.

★ **What overlapping primitives do** (§2 asked): nothing special — each region
offsets its own surface independently, so two primitives may occupy the same
material and the PICTURE shows both. The RUN's precedence is core's and unchanged
(clearance beats include and exclude; exclude beats include). The UI does not
resolve overlap and does not pretend to.

### (c) Magnetic detents — NOT DONE. See §13.

### (d)/(e) Depth and the handle are ONE value

Asserted **in both directions** (`LatticePrimitiveAlwaysTests`):
typing 1.5 / 3.0 / 6.25 mm moves the handle to exactly that distance from its
plane origin; dragging to 2.0 / 5.5 / 1.25 mm gives the drawer, the primitive and
`LatticeSlabDepth` the same number. There are now **three** routes to it — the
drawer field, the row pill, the 3D handle — and all three write
`writeLatticeDepthMM` / `groupDepthMM` through the one clamp. The protection depth
reads the same number (§2e), asserted.

---

## §3 — THE BADGE AND THE (i)

**The arithmetic, worked from numbers already on the card**: `cellsPerMember` is
thickness ÷ cell, so the thickness (14.7 mm) is recoverable and both fixes fall
straight out of it.

★ **THE EXACT TEXT ON HIS FAILING CARD** (pinned by
`LatticeFaceDiagnosisTests`):

**Badge (on the COLLAPSED row, no expanding required):**

```
Won't certify — 2 problems, tap for the fix
```

**(i) pop-up — EVERY failure, each leading with the fix:**

```
Not certifiable — too few struts across this wall.
Make it deeper: 24.7 mm.
Or use a smaller cell: 2.9 mm.
3.0 struts across, needs 5.

Too thin to print — the struts are finer than the nozzle.
Raise the density above 5%.
Or use a bigger cell: 6.9 mm.
0.32 mm strut, nozzle is 0.45 mm.
```

★ **The second problem is the one his panel never mentioned** (§3c). The badge
says "2 problems", so it cannot hide even before the pop-up opens.

★ **A DEFECT THE TEST CAUGHT AND IT IS NOT COSMETIC.** 5 × 4.93 = 24.65, which
nearest-rounds to "24.6 mm" — and **24.6 ÷ 4.93 = 4.99, which still fails.** A
printed fix that does not fix it is worse than none, so a fix that must be BIGGER
rounds up and one that must be SMALLER rounds down.
`testEveryPrintedFixActuallyClearsTheFloor` re-runs the floor test on the printed
values rather than trusting the format string.

Also asserted: no jargon on the badge ("regime", "homogenize", "cells per member"
all banned); a certifiable card is **silent**; face 16 at 20.0 mm gives 4.06 and
**still fails** (the borderline a "close enough" rule would have passed).

---

## §4 — COLOUR AND PLACEMENT

★ **I MISREAD §4(a)/§4(b) FIRST TIME AND THE MAINTAINER CORRECTED ME IN SESSION.
HIS WORDS GOVERN:**

> "I meant for the 'Lattice' button to be a dark blue like the *colour* of the
> chips with the icons! But stay the size and position they are at the top of the
> screen just to the left of the gizmo with the perfect amount of spacing. This is
> the same space where 'Lattice Settings' will be on the other page."
>
> "the original position was to be vertically centered on the gizmo. **DO NOT DO
> THAT**. It should be at the top of the screen — not centered with the gizmo"

My first attempt moved "Topology" under the project name and "Lattice" into the
bottom-right chip stack, and shrank both to top-bar height. **All of that is
reverted.** What §4 actually is:

**(a)/(b) THE TO PAGE'S "Lattice" BUTTON KEEPS ITS SIZE AND SLOT** — 64 pt
(`PageChrome.actionButton`), **top-right, LEFT of the gizmo by exactly
`PageChrome.gizmoClearance`** (210 + 2×8 = 226 pt), "the perfect amount of
spacing".

★ **AND A SECOND CORRECTION HE GAVE AFTERWARDS, WHICH MOVES THE *BACK* BUTTON
ONLY:** *"put the 'Topology' button below the name of the project. It should be
flush with the LEFT side of the screen, directly below the name and < arrow with
the regular padding between the two"* and *"make the 'Topology' button as thin as
the name of the project as well."*

So the two stage buttons are no longer the same shape, because they are no longer
the same job:

| | "Lattice" (TO page) | "Topology" (lattice page) |
|---|---|---|
| goes | FORWARD | BACK |
| slot | top-right, left of the gizmo | **top-left, under the project name** |
| inset | `gizmoClearance` 226 / `gizmoInset` 8 | `DS.Space.xl4` 24 / one `PageChrome.gap` below the identity row |
| height | 64 (`actionButton`) | **as thin as the name capsule** — `.padding(.vertical, 9)` around `bodyStrong`, the identical construction `chrome` uses, so it is thin BY CONSTRUCTION and cannot drift |

★ **AND THE TOP-RIGHT SLOT NOW HOLDS EXACTLY ONE BUTTON PER PAGE**: the TO page's
"Lattice", and — since "Topology" vacated it — the lattice page's "Settings",
which moved UP into it.

★ **THE COLOUR: `accentGreen` `#30D158` → `DS.Color.accentDeep` `#004080`** with a
1.5 pt `DS.Color.accentDeepEdge` `#3D8FD6` hairline — TWO NEW tokens, used as a pair, on all three stage buttons. His reason is semantic, not decorative: *"make
all 3 stage buttons a **darker** blue? I want them to be different from the
'Optimize' button."* `accent` `#0A84FF` is what a page's PRIMARY ACTION wears
(Optimize, Save & Exit, Next). The stage buttons do not run anything — they move
you between pages. Same hue (210°), max channel 128 against 255 — half the lightness, so the
separation is decisive; the lighter rim is what stops a fill that deep reading as
a dead slab, and is the maintainer's own suggestion ("a bit of a lighter blue
highlight around it"). ★ Four values were tried in review and the reasoning is
recorded on the token so it is not re-litigated: `#0A4D8F` and `#005EBD` read
fine but sat closer to the accent; `#061D95` went near-navy; `#0077F0` was only
15/255 from the accent, which defeats the point of having the token at all. `DS.Shadow.accentDeepGlow` matches, so a
navigation button does not halo in the action blue it is deliberately not wearing.

**★ AND THEY SIT AT THE TOP OF THE SCREEN, NOT CENTRED ON THE GIZMO.** The old
top padding was `DS.Space.s + (gizmoSize − 64) / 2` — 81 pt down, centring a 64 pt
button inside the 210 pt gizmo. It is now `PageChrome.gizmoInset` (8 pt), so the
button's top edge lines up with the gizmo's own top inset and the two read as one
top row.

**(c)/(d) The lattice Settings button now OWNS the top-right slot** — same
`gizmoClearance` from the right, top edge on `gizmoInset`, exactly where the TO
page puts "Lattice". Its fill goes **purple → the same `accentDeep`**, so all
three navigation buttons are one colour. **The gizmo did not move.**

★ **`SettingsChipID.stageNav` and the bottom-right chip are GONE**, and so is the
keep-out band they motivated — see the note at the end of this section.

**(c) THE PURPLE/GREEN CENSUS.** Fixed:

| was | file:line |
|---|---|
| stage nav — `accentGreen` | `WorkspacePlaceholder.swift:2426` (base) |
| lattice Settings — `densityColor(0.75)` | `WorkspacePlaceholder.swift:2454` (base) |
| Struts chip — `densityColor(0.75)/(0.6)` | `WorkspacePlaceholder.swift:2339/2344` (base) |

**Kept, with reasons** (§4c exempts the page's own state language):

| kept | file:line | why |
|---|---|---|
| `okGreen` verdicts | `WorkspacePlaceholder.swift:5116`, `LatticePage.swift` ×10, `ResultsScreen` ×6 | a VERDICT colour — certified/satisfied. Exempt by §4(c). |
| Anchor chip green | `WorkspacePlaceholder.swift:5636-5637` | the anchor ROLE colour; loads are blue. Role language. |
| Design Box green | `WorkspacePlaceholder.swift:2926, 2946` | matches the **green drag handles** in the viewport, and its own copy says "drag the green handles". Breaking it would break the sentence. |
| role chips `densityColor(0.5)/(0.8)` | `WorkspacePlaceholder.swift:5003-5004` | these ARE the rendered region colours (`latticeRegionTint` mid-violet / deep indigo) — the chip matches the volume it declares. |
| depth knob `densityColor(0.6)` | `WorkspacePlaceholder.swift:3393` | matches the depth plane it drags. |
| `accentPurple` | `ProgressBar.swift:43` | inside a `#Preview` — Xcode canvas only, never shipped. |
| debug HUD green | `WorkspacePlaceholder.swift:3127` | behind `boxDragDebug`, developer-only. |

★ **A LATENT GAP MY WRONG FIRST ATTEMPT SURFACED, RECORDED BUT NOT TAKEN.**
While the Lattice button was briefly a bottom-right chip, the cluster grew by one
row and `Paint` landed on top of a floating `0 mm` clearance value pill
(`s0/topology_after_stack.png`). That exposed something real and pre-existing:
**the bottom-right cluster has NO keep-out registration at all.**
`ViewportKeepOut` knows about the orientation gizmo and nothing else, so a
model-anchored pill (priority `.label`) can always drift under the settings chips
— which is the one rule that file exists to enforce.

I prototyped a `chrome.bottomChips` band, it did not fully seat the pill, and
**both the chip and the band are now reverted** because the button never belonged
in that cluster. **The latent gap is still there, unchanged from base**, and it is
in §13 — it is a `ViewportKeepOut` question, not a §4 one.

---

## §5 — NUMERIC INPUT: THE INVENTORY

★ His rule, stated twice: "Any input MUST be selectable and a small numeric
keyboard pop-up… NOT just touch inputs."

| # | field | file:line | typed entry? |
|---|---|---|---|
| 1 | wizard cell size | `LatticeSetupWizard.swift` `scrubRow("size")` | ★ ADDED |
| 2 | wizard thickness / density % | `LatticeSetupWizard.swift` `scrubRow("thickness")` | ★ ADDED |
| 3 | wizard swept MIN | `LatticeSetupWizard.swift` `scrubRow("cellMin")` | ★ ADDED (field did not exist) |
| 4 | wizard swept MAX | `LatticeSetupWizard.swift` `scrubRow("cellMax")` | ★ ADDED (field did not exist) |
| 5 | drawer Depth (group + selectable) | `WorkspacePlaceholder.swift` `latticeDrawerBody` | ★ ADDED |
| 6 | row depth pill | `WorkspacePlaceholder.swift` `latticePrimitiveRow` | ★ ADDED |
| 7 | lattice page cell (fixed) | `LatticePage.swift:1310` | already had it |
| 8 | lattice page swept min/max | `LatticePage.swift:1323/1333` | already had it |
| 9 | load weight pill | `WorkspacePlaceholder.swift:5824` | already had it |
| 10 | keep-clear value pill | `GlassValuePill.swift:93` | already had it |
| 11 | print params (infill, widths) | `PrintParamsSheet.swift:284/393/426` | already had it |
| 12 | worker port | `ComputeLocationControl.swift:111` | already had it |

**Six gained typed entry** (two of them by gaining existence). Drag remains as the
coarse adjustment everywhere; typing and dragging write through the same setter,
so there is no parallel entry path and no second clamp.

★ **Still drag-only, and named rather than hidden:** the face-protect depth chip
(`faceProtectDepthChip`) cycles a **fixed ladder** 3/5/8/12 mm on tap — it is a
stepper, not a free field. It is the one numeric control on this page that does
not open the pad, and it never accepted arbitrary numbers to begin with.

---

## §8 — DENSITY: THREE MODES

**(a) There is no "Swept" density option anywhere in code or copy** — checked,
and recorded in `LatticeDensityMode`'s own comment. The only `swept` is
`LatticeCellSizeMode.swept`, correctly scoped to cell size. Nothing to remove.

**(b) Auto remains the default** — asserted.

**(c) Selecting "Per region" is the entire wiring.** PR 334 built the conditional
drawer row and recorded "NOTHING CAN SET IT TRUE TODAY". `LatticeDensityMode`
gained `perRegion` and `WorkspacePlaceholder.perRegionDensity` is the one
expression that connects them.

**(d) The other two modes leave the drawer byte-identical** — PR 334's two exact
cases `["Depth"]` / `["Depth","Density"]` are kept, and the row VALUES are
asserted equal across modes too.

★ **PR 334's GAP 2 WAS REAL AND I NEARLY SHIPPED IT.** `latticeDrawerBody`
attached `depthDrag` to **every** modifiable row and hardcoded the `-depth`
accessibility id. Safe while "Depth" was the only control — but the moment
per-region reveals a Density row, that row inherits the DEPTH's gesture and a
duplicate id: a control silently editing the wrong number. Each modifiable row is
now keyed by its own label slug and only the depth row gets the depth drag
(`LatticeDrawerRowGesture`).

**(e) The gap is surfaced, not silent.** PR 331's per-sector density override does
NOT reach core (its own handoff: "density is a function of the cell, not an
input"). Both the wizard and the lattice page carry:

```
Set each region's density in its drawer. Core still derives density from the
cell — these are saved, not yet run.
```

PR 334's three-gap note is **updated in place** — gaps 1 and 2 marked closed with
what closed them, gap 3 left open and still asserted — exactly as that test asked
("must be UPDATED, never deleted").

**(f) The wizard stage showing what the mode does — NOT DONE.** See §13.

---

## §9 — SWEPT CELL SIZE

**(a) The range inputs are restored** — and the reason they were missing is that
**`LatticeWizardModel` never carried `cellMinMM`/`cellMaxMM` at all.**
`LatticeSettings` has had them since the sweep task and `runSpec` emits them; the
wizard's model simply had no field, so its "Swept" segment had nothing to show and
`applied(to:)` handed the project back whatever it already had. That absence IS
the 2:42 AM screenshot. Both ends are typed (§5).

**(b) ★ WHERE THE WINDOW BECAME A SCALAR: `LatticeSettings.swift:801`.**

```swift
let floor = b.cellFloorMM ?? 0        // ← the LIGHT floor, 4.93 mm
let lo = Swift.max(cellMinMM, floor)  // 2.0 → 4.93
let hi = Swift.max(cellMaxMM, lo)     // 4.0 → 4.93
```

His 2.0–4.0 mm window reached the job as **4.93–4.93**. `cell_plan_max_level`
(`core/src/simp/cell_plan.cpp:43-51`) builds a **dyadic** ladder — levels are
`min · 2^L` — so a ratio of 1.0 yields `Lmax = 0`: one level, every block takes
it, `distinct_cells: 1`, one strut radius. **The app, not core.**

★ **The app already knew the right answer.** PR 310 moved the swept floor to the
**dense** floor, and `LatticeCellEntry.entryFloorMM` has used `cellFloorDensestMM`
(~1.17 mm; his run records `min_printable_cell_mm: 1.173`) for typed entry ever
since. So the control **accepted** 2.0 mm and the emission **threw it away**: two
floors, two answers, one silent overwrite. There is one floor now.
Pinned by `testASweptWindowIsNotFlattenedByTheWrongFloor`, which asserts the
window survives **as a window** (`hi/lo ≥ 2`) — a test checking only the low end
would have passed on 4.93–4.93.

**(d) ★ WHICH FIELD DRIVES THE SWEEP — and the caption was lying about it.**
`plan_cell_sizes` (`cell_plan.cpp:186-199`) picks each block's level from
`need` — the smallest level whose strut still prints at that block's **thinnest
density** — bounded by `cap`, the largest level still spanning N* cells of its
**thinnest member width**. **Density and member width. Stress never enters.** The
caption claimed "fine where the stress is high, coarse where it is low", which
describes a mode that does not exist. Replaced.

★ **A consequence worth stating:** because `need` comes from density, a **flat**
density field gives every block the same `need` and the sweep collapses to one
level even with a legal window. So the window is necessary and not sufficient.

**(e) ★ BOTH HALVES OF §9(e) WERE TRUE.** The caption named `cellFloorMM` (4.93,
the light floor) while the control was bounded by `cellFloorDensestMM` (1.17) —
**stale**. AND a clamp **was** silently discarding his window — at line 801, to
that same wrong floor. The caption was, accidentally, describing the bug.

**(f) A clamp that fires now says so**, with the number:
`LatticeCellEntry.sweptClampNote` → *"Raised to 1.17 mm — below that no strut
prints at this line width."*

**(c) ★ A SWEPT RUN ON HIS PART EMITTING `distinct_cells > 1` — NOT MEASURED.**
The app-side collapse is fixed and pinned by a test on the emitted job document,
but I did **not** run a full swept optimise on his part to report
`distinct_cells` and the strut range against the current 1 and 0.225/0.225. **R11
is therefore NOT met**, and §13 says what it needs.

---

## §10 — FINISHES: BUILT

★ **THE ROOT CAUSE WAS AN ABSENCE, NOT A BUG.**
`LatticeSamplePatch.mesh(lattice:cellMM:cells:relativeDensity:)` took **no
`boundary` argument**. The wizard's None / Rim / Skin chips wrote `model.boundary`
and the mesh builder never read it, so all three emitted identical geometry. His
report — *"The finish still doesn't work. There is no skin or rim visible."* — was
not a rendering or camera problem. There was nothing to render.

* **None** — bare struts.
* **Rim** — a beam frame along the block's twelve edges, at 1.6× strut radius so
  it reads as a DRESSING rather than as more lattice. (Core's rim rides the pairs
  of boundary faces that meet at an edge; this is that, on the sample.)
* **Skin** — the anchored DIAGRID: crossing diagonals lying in each of the six
  outer faces, cell to cell, so it is tied to the strut nodes it lands on.

★ **AND A SECOND FAULT STACKED UNDER IT.** The Auto-density cinematic ends with
`dive()` — pan to the densest point, zoom to 0.45, i.e. INSIDE the lattice — and
`boundarySwap` only cross-faded the mesh. So a correct rim was being drawn from a
viewpoint buried in the struts. Showing a finish now re-frames the sample, because
a finish is a thing you look at from OUTSIDE.

**§10(c) — measured latency per finish**, on the sample at 118,920 triangles:
**None 769 ms · Rim 752 ms · Skin 800 ms.** Well inside the "a finish preview is
affordable" claim.

★ **§10(b)** — the standing correction: "Skin pattern — Diagrid" read like an
unselected picker and is not one. It is now a stated fact: *"Skin pattern: Diagrid
— the only one core builds."*

★ **AND THE DEFAULT IS NOW `none`** ("it should default to 'none'"), in all three
places it was set: the wizard model, `LatticeSettings.init`, and the decode
fallback (which was `.rim`).

---

## §11 — THE TWO LAYOUT DEFECTS

**(a) ★ ROOT CAUSE: THE WIZARD RENDERED EVERY CONTROL TWICE.** `wizardCard`
(`LatticeSetupWizard.swift:152` at base) rendered `model.stage.settings` through
`settingControl`, and `selectionsModal` (`:210`) rendered **every** stage's
settings through the same function. On the Finish stage the Density and Finish
editors existed twice — once in the left modal and once in a 380 pt panel floating
over the model. **Duplication by construction, not a layout accident.**

And the two Save & Exit: `nextButton` (`:184`) relabelled itself to "Save & Exit"
on the last stage, while `saveAndExit` (`:371`) drew the corner one.

**Fixed:** each control exists **once**, in the left modal (§11c's mandated
panel); the card keeps only what only it can carry — which stage you are on, and
Next. **One "Save & Exit" on the page**, the corner's, which is where every other
page puts its primary action (S17). The card is now a short bar and stops covering
the object the page exists to show.

**(b) The type picker is no longer clipped.** A horizontal `ScrollView` was
already there; what was missing is `fixedSize()` on the chips, so SwiftUI
compressed the row to the modal's 348 pt instead of letting it overflow and
scroll. A truncated chip is a lattice the user cannot pick.

**(c) The left modal is already centre-left and vertically centred on every page**
— `PageLeftModal`, shipped by PR 332. **No page changed.** The wizard's modal
gained an internal `ScrollView`, which `PageLeftModal` always promised ("only a
modal that outgrew the band scrolls INSIDE it") and which the swept range fields
need.

---

## §6 — THE SURFACE STAGE: BUILT

The maintainer asked for this directly after the review rounds ("I don't see
'Surface' mode. I think it should be a whole different Stage with a button visible
in both the TO and Lattice stages"), which also settled §13's open decision: it is
a THIRD STAGE, not a mode inside one, and its button sits in a NAVIGATION COLUMN
above Settings rather than replacing it.

**(a) The stage, and where its button goes.** `WorkspaceStage.surface` is the
third row of the visibility table, and every primitive column in it is `false` —
design box, group primitives, keep-outs, depth planes, lattice controls. Not
dimmed: absent. `WorkspaceStageVisibility.of(.surface).rowSections` is
`[.clearanceEditor]`, so no lattice section survives in the Selections list either.

★ **"WHERE YOU GO" ABOVE "WHAT YOU CONFIGURE"** — his phrasing, adopted. The
top-right is now a NAVIGATION COLUMN (`stage.forward`) with the page's own
settings button beneath it, its inset derived from `stage.forward.count` rather
than guessed:

| stage | back (top-left) | forward column (top-right) | below it |
|---|---|---|---|
| Topology | — (it is the root) | Lattice, Surface | Optimize's chips |
| Lattice | Topology | Surface | **Lattice Settings** |
| Surface | Topology | Lattice | — |

**(b) ★ THE WIREFRAME IS B-REP EDGES, NOT EVERY TRIANGLE EDGE.** This was called
out in §13 as one of the two real builds, and the reason survived contact: a STEP
part arrives TESSELLATED, so drawing every triangle edge turns a bore into a fan
of spokes and a fillet into a mesh of noise — the opposite of "so faces are easy
to see". `SurfaceWireframe.edges` keeps an edge iff two DIFFERENT faces meet on it
(a B-rep edge) or exactly one triangle uses it (a boundary rim).

★ AND IT IS DEDUPED BY VERTEX POSITION, NOT BY INDEX. A tessellated STEP part is
normally written with each face carrying its OWN copies of the shared corner
vertices, so the two sides of a real B-rep edge have DIFFERENT indices at identical
coordinates. Keying on the index finds no shared edges at all and draws the whole
tessellation — the exact failure the rule exists to avoid. Keyed on the quantised
position (1e-4 mm), it finds the real ones.

It works on an STL too: a mesh import carries the dihedral segmenter's
pseudo-faces (handoff 134), so `faceIDs` still partitions the surface. A mesh with
NO face partition draws NOTHING rather than everything.

Pinned by `testTheWireframeDrawsBRepEdgesAndNotTessellation`, whose fixture is a
square split into FOUR triangles about a centre vertex: the four spokes and the
base's diagonal must not be drawn, and the test also asserts the naive
every-triangle-edge set is strictly larger, so it is not an empty set agreeing
with itself.

**(g) ★ THE PENCIL HOVER — and the point the picker had been discarding.**
`FacePicker.pickTriangle` runs Möller–Trumbore and keeps the ray parameter in
`bestT` to find the nearest triangle, then returns only the index. `FacePicker.hit`
now returns `origin + dir·bestT` alongside the face id and its normal — the same
ray the tap already casts, so the hovered line cannot disagree with the face a tap
would select.

`onContinuousHover` had ONE precedent in the whole app (the orientation gizmo, for
a mouse), which §13 flagged. What makes it tractable is that a hover gives the same
thing a tap gives — a point in view space — so it goes through
`CameraProjection.ray` → `FacePicker.hit` → `SurfaceCut.at`, unchanged. On hardware
without hover it simply never fires and the stage still works by tap.

The preview line is drawn DASHED while hovering and SOLID once held. Its direction
is `faceNormal × normal`: perpendicular to both, so it lies IN the face and IN the
cut plane — the visible trace of one on the other, which is what makes it read as
a line on the surface rather than a floating stick. Asserted to 1e-9 on both dots.

**(h) ROTATE, WITH 15° DETENTS.** A horizontal drag turns the plane about the
face's own normal; RELEASING lands on the nearest 15°. A detent, not a stepper —
the drag is continuous and only the release snaps. `testRotatingKeepsTheCutPlane
PerpendicularToTheFace` walks all 24 detents and asserts the plane still stands up
out of the face at each, so the preview line cannot leave the surface as it turns.

**(i)/(j) ★ THE CUT IS A HALF-SPACE, PERSISTED AS GEOMETRY.** Not a line drawn on
the face: PR 331 measured why — a line has no clean meaning on a fillet, and 19.8%
of his part's surface types land in `Other`. So a cut is a POINT AND A NORMAL, and
`FaceRegionModel.splitManual` already took exactly that. The two children take
OPPOSITE senses with opposite strictness, so a voxel centre exactly on the plane
lands in one child, never two and never none — asserted.

`ProjectModel.commitSurfaceCut` divides the DEEPEST live region under the point, so
cutting a piece that was already cut divides THAT PIECE and not its parent all over
again. A face with no region gets an identity region first, and that region JOINS
THE GROUP THAT ALREADY OWNED THE FACE — otherwise the two halves would exist in no
list, and the Selections list is the only place a role can be given to them.

★ **LAYER 1 IS UNTOUCHED.** `testTheCutDoesNotRepartitionTheFaces` asserts
`viewerMesh.faceIDs` is byte-identical after a commit. Projection and every
analytic-surface lookup stand on the face partition being exactly what the B-rep
said; a cut is LAYER 2 and never renumbers LAYER 1.

**★ WHAT OF §6 IS STILL NOT BUILT.** Named, not hidden:

- **(c)/(d) double-tap for similar faces** — single tap selects; the "similar"
  filter derived from a tapped face is not wired. `RegionFilter`/`match` and PR
  331's measured blend signature both exist; nothing consumes them from a tap.
- **(e) pencil-vs-finger routing** — the router exists (`SmoothBrushTools.Input`,
  `route(_:touches:)`) and is NOT yet gated on this stage, so today a finger drag
  rotates the cut as a pencil drag does.
- **(f) 2-finger undo / 3-finger redo** — `MetalMeshView:2383` already carries the
  gestures; they are not bound to the region model's history in this stage.

17 tests, all passing (`SurfaceStageTests`, `SurfaceCutCommitTests`).

---

## §12b — THE REVIEW ROUNDS, AND FOUR MORE DEFECTS THEY FOUND

★ Four things the maintainer caught on device that no test would have:

**1. The "Struts" chip floated over the Selections rows.** It was mounted in
`latticePreviewOverlay` — LEADING-anchored, offset down from the top bar, a
screen-space guess that happened to land on top of the panel. It is now the last
row INSIDE `selectionsPanel`, bottom-right, so it cannot overlap what it sits on.

**2. ★ THE DEPTH FIELD AND THE PRIMITIVE WERE NOT LOCKED — and the cause is a
resolution order, not a missing write.** `LatticeSlabDepth.depthMM` resolves a
PER-SELECTABLE override BEFORE the group's number. The group drawer's field
assigned `lattice.groupDepthMM[group]` directly — so the moment the user dragged a
primitive's knob (which writes `selectableDepthMM`), the group field went inert
for that face: the number changed and the primitive did not move. **Dragging the
handle is the other half of the feature he asked for, so reaching that state is
the normal path, not an unusual one.** `ProjectModel.writeGroupDepthMM` is now the
one entry point and clears the group's per-selectable overrides; both the typed
field and the group drag go through it. Pinned by four tests including
`testTheOldBareAssignmentIsWhatLeftThemUnlocked`, which drives the OLD write and
watches the primitive refuse to move — so a revert to a plain assignment fails.
The depth knob's touch target also went 22 → 44 pt (drawn size unchanged); half
Apple's minimum is part of "I cannot drag the primitive out".

**3. A DISABLED "Optimize" overlapped the Gravity chip.** The bottom-right cluster
cleared the bar with a hardcoded `DS.Space.xl4 + 50 + DS.Space.m` — 50 pt for
Optimize. A disabled Optimize carries a "what is missing" subtitle and is taller,
so the bar grew up into the chips. The bar now MEASURES itself
(`BottomBarHeightKey`) and the cluster clears the measured height, so it cannot be
wrong at any size the bar becomes.

**4. The two top-right stage buttons were different heights.** "Lattice" (TO) was
`PageChrome.actionButton` (64) and "Settings" (lattice) `compactButton` (48).
They share ONE slot across the two pages, so they now share its stature: both 48.

---

## §13 — ★ WHAT IS NOT DONE, AND WHAT EACH WOULD TAKE

| § | item | state | what it needs |
|---|---|---|---|
| **6** | CAD-surfaces mode ("Surface" stage) | **NOT BUILT** — and see the readiness audit below | the whole section: mode gate hiding primitives, wireframe, single/double tap (PR 331's blend signature is already measured and available), pencil-vs-finger routing, 2/3-finger undo/redo, hover preview, rotate+15° detents, half-space cut persisted as point+normal. `FaceRegionModel.splitManual(point:normal:)` already takes any point — only the UI point-picking is missing, as PR 331 recorded. |
| **7** | pattern tool | **NOT BUILT** | columns default 3 with live lines, rows via the board icon, typed entry. ★ The MECHANISM exists: `FaceRegionGeometry.gridSplitCells` + `FaceRegionModel.splitGrid` place the cuts in the region's own frame and the sliver guard fires; §7(h)'s one-collapsible-parent-row is PR 331's `collapsed` and already works in this list. What is missing is the control surface. |
| — | ★ **THE "SURFACE" STAGE — READINESS, AUDITED** | mostly wiring, TWO real builds | ★ ALREADY EXISTS: the stage-visibility table takes a third row; `FaceSelection.pick` (single tap); **the pencil/finger router** (`SmoothBrushTools.Input` + `route(_:touches:)`, wired in `MetalMeshView.handlePencilPan`) — §6(e) is reuse, not new; **2-finger undo / 3-finger redo** (`MetalMeshView:2383-2388`); `FaceRegionModel.splitManual(point:normal:)`; `RegionCut` already persists point+normal. ★ SMALL: the tap's 3D POINT (`pickTriangle` computes the ray parameter `bestT` and discards it), "similar faces" (needs a filter DERIVED from a tapped face — `RegionFilter`/`match` and PR 331's measured blend heuristic already exist), 15° detents (`ClearanceHaptics` + design-box detents to copy). ★ **TWO REAL BUILDS: (i) a wireframe pass** — the renderer draws `.line` in five places but has NO mesh-edge buffer, and on a STEP part it must draw B-REP edges (where `faceIDs` differ across a shared edge) or a tessellated cylinder reads as a fan; **(ii) pencil hover** — `onContinuousHover` appears once in the whole app (`OrientationGizmoView`, for a mouse), so §6(g)'s hovered cut line has no precedent to copy. ★ AND ONE DECISION FOR THE MAINTAINER: he asked for the Surface button BELOW each stage's own button, but on the lattice stage that slot is Settings — so either Surface goes third in that column or Settings moves down one. |
| **2(c)** | magnetic detents on the drag | **NOT BUILT** | the depth drag is linear. `DetentPulse` and the design-box detent machinery exist to copy. |
| **8(f)** | per-region wizard cinematic | **NOT BUILT** | the sample with two regions at visibly different densities. |
| **9(c)** | `distinct_cells > 1` on his part | **NOT MEASURED** | a full swept optimise run. The app-side collapse is fixed and unit-pinned; the end-to-end number is not taken. **R11 is not met.** |
| **1(c)** | filters + Combine reachable from the Selections list | **NOT DONE** | they live in the Regions sheet only. |
| — | the bottom-right cluster has NO keep-out band | **LATENT, unchanged from base** | `ViewportKeepOut` registers the orientation gizmo and nothing else, so a model-anchored `.label` pill can drift under the settings chips. Surfaced by a wrong first attempt at §4(b), then reverted with it. Needs a derived `.chrome` band for the cluster, and the pill's `maxShift` checked against it. |

---

## BARS

| bar | verdict |
|---|---|
| **R1** §0 first: screenshot, rules written down, every control checked | **MET** — `s0/STYLE_RULES.md`, 18 rules, table in §0 above |
| **R2** a primitive is ALWAYS created; failing test first; root cause | **MET** — 86.4% of his own faces measured; `FaceOffsetShell`; 12 tests |
| **R3** depth and handle cannot diverge, both directions | **MET** — asserted both ways, plus the protection depth |
| **R4** the list shows regions; row count before/after | **MET** — 23 → 1 for his group |
| **R5** every numeric input inventoried, typed entry confirmed | **MET** — 12 inventoried, 6 gained it, 1 stepper named |
| **R6** every purple/green surface reported | **MET** — 3 fixed, 7 kept with reasons |
| **R7** badge + (i) on his failing card, exact text, incl. the strut failure | **MET** — pasted in §3 |
| **R8** CAD-surfaces mode demonstrated | ★ **NOT MET — NOT BUILT** (§13) |
| **R9** pattern tool demonstrated | ★ **NOT MET — NOT BUILT** (§13) |
| **R10** three density modes, auto default, per-region reveals the row | **MET** — asserted; PR 334's invariant kept and its gap 2 closed |
| **R11** swept run on his part emits `distinct_cells > 1` | ★ **NOT MET** — the app-side collapse is root-caused and fixed at `LatticeSettings.swift:801` and pinned by test, but the end-to-end run was not taken |
| **R12** each finish renders, with latency | **MET** — Rim is an edge frame, Skin an anchored diagrid, None bare struts; **769 / 752 / 800 ms** at 118,920 tris. Root cause was a missing `boundary` parameter, plus a camera left inside the lattice by `dive()` |
| **R13** ONE "Save & Exit", no duplicated panel | **MET** |
| **R14** no wall of text; longest string + word count | **MET** — longest badge **8 words** ("Won't certify — 2 problems, tap for the fix"), cap 25. Longest string added anywhere: the swept caption, **26 words** (a caption, not a badge). |
| **R15** no verdict moves; core untouched | **MET** — the only core change is a new `EXCLUDE_FROM_ALL` probe + its CMake entry. No core `src/` or `include/` file changed. |
| **R16** never weaken or delete an assertion | **MET** — `assertion_census.txt`, read whole. No category fell; four assertions whose subject moved are each restated (one deliberate inversion, mandated by §2a) |
| **R17** no unfilled placeholders, no root scratch | **MET** |
| **R18** "Lattice This" runs end to end without TO | **STOPPED AT ITS OWN GATE (§12e)** — it RUNS (107,823 latticed, 97.2%, vs 13,034/12%) but ignores declared regions and does not export, both measured, both with file and line |

**Suites.** App: **1550 tests, 22 skipped, 8 failures — all 8 the known lib3mf
environmental gap** (three `AppModelTests` 3MF cases that refuse before testing
anything). Baseline before this task: 1524/22/8, the same three. **This task adds
26 tests and moved the failure count by zero.** Report N/1550 here and 1550/1550
in CI; the three 3MF tests DID NOT RUN.

★ Three tests failed mid-task because a DEFAULT the maintainer moved was pinned as
a literal, and each was fixed rather than weakened — see `assertion_census.txt`
and the evidence README. The `VariantEntryGating` one is now strictly stronger
than what it replaced: it asserts the RULE ("whatever the default is, it must not
be a treatment that emits nothing") instead of one value that satisfied it.

---

## METHOD

**New, app.** `FaceOffsetShell.swift` (the distance-field offset rule and its
curvature clamp — pure, no view, no Metal) and `LatticeFaceDiagnosis.swift` (every
failure, its number, its target and the fix with its value — pure, so the exact
strings and their word counts are assertable).

**Changed, app.** `ProjectModel` (the region-covered-face subtraction, the one
primitive builder, the region path's four refusals removed), `ClearanceGeometry`
(the `.shell` shape + its handle), `MetalMeshView` (drawing the shell and its
boundary skirt — interior edges are shared and must not be walled),
`WorkspacePlaceholder` (region children, the badge + (i), the stage button's
colour and both of its homes, per-row drawer gestures, typed depth, the cluster
keep-out band), `LatticeSetupWizard` (the card stops duplicating the modal, one
Save & Exit, the swept range, three density modes, typed entry),
`LatticeWizardModel` (`cellMinMM`/`cellMaxMM` — the absent fields),
`LatticeSettings` (`perRegion`, and the wrong-floor clamp), `LatticePage` (three
density modes, the honest swept caption, the clamp note),
`WorkspaceChipLayout` (`.stageNav`).

**New, core.** `tests/harness/lattice_primitive_probe.cpp` only —
`EXCLUDE_FROM_ALL`, so CI's test count does not move. **No core `src/` or
`include/` file changed.**

### ★ TRAPS THIS BRANCH HIT

1. **A test fixture can lie about winding.** `twoWallMesh` winds both walls
   identically while declaring opposite normals. Deriving the offset direction
   from winding alone passed every new test and failed that old one — which is how
   the "declared normal wins the sign" rule got found. Worth keeping: the
   EMISSION reads the declared normal, so the picture must too.
2. **A 4-facet "cylinder" is a square.** The asymmetric quad→triangle split skews
   each vertex normal ~22° off radial, which read as a defect in the offset rule
   and was a property of the fixture. Printing the per-vertex numbers, not
   re-reading the code, is what separated them.
3. **`cmake --build build --target topopt-cli` is still a silent no-op.** The
   target is `topopt_cli`.
4. **Nearest-rounding a suggested fix can produce a fix that does not work.**
   24.65 → "24.6" → 4.99 struts across. Assert the printed value against the
   bound, not the format string.

---

## IN PLAIN LANGUAGE

You told me the biggest problem was that pressing "Lattice" on a face often drew
nothing. It turns out that was not "often": on the twenty-two faces you actually
selected for your load, **nineteen of them drew nothing**. The reason is one line
— the code that drew the shape could only draw a flat slab, so it needed a flat
face, and it quietly gave up on anything curved. Your bracket is more than half
curved.

The fix is the thing you guessed at when you asked about the doughnut. Instead of
drawing a slab, the app now takes the surface you actually picked and pushes it
inward by the depth. On a flat face that gives you a slab, same as before. On a
bore it gives you a tube — your doughnut. On a fillet it gives you a shell that
follows the curve. It is one rule, so there is nothing left for it to give up on.
And it will not fold through itself on an inside corner, because it stops where
the walls meet and it tells you when it stopped.

The twenty-three rows are gone. When you combine faces into one thing, that thing
is now one row, and the faces sit underneath it with no buttons of their own —
because the role, the depth and the verdict belong to the group, not to each face.

The message you could not read now says what is wrong and what to type. Not "Out
of regime · 3.0 cells across" but "Won't certify — 2 problems, tap for the fix",
and behind it: *make it deeper, 24.7 mm, or use a smaller cell, 2.9 mm.* **Two**
problems, because your card also had a strut thinner than your nozzle and the app
never mentioned it. And a small thing that turned out not to be small: the obvious
way to round that number gives you 24.6 mm, which still fails. It rounds the way
that works now, and there is a test that checks the advice actually solves the
problem.

The swept cell size was not broken in the way it looked. The window fields were
missing from that screen, yes — but underneath, **the app was throwing your
numbers away**. You typed 2 to 4 millimetres; the app pushed both ends up to
4.93 and sent 4.93 to 4.93, which is not a range, which is why you got one cell
size. It was using the wrong floor — the app had two different floors for the same
thing and the one you typed against was not the one it sent. Now there is one.
And the caption was wrong twice over: it said the sweep follows stress, and it
does not — it follows density and wall thickness.

**Three things I did not do, and I want to be blunt about them.** The CAD-surfaces
mode is not built. The pattern tool is not built. The finishes still do not show
you anything on the sample. Those were the last three on your own priority list
and I ran out of room before I got to them. The machinery for the pattern tool
already exists underneath — the cuts, the equal spacing, the sliver refusal, the
one-row folding — so it is a control surface, not a rebuild. I have written down
what each of them needs.

**And one thing I checked before building, which is why I did not build it.** You
asked for a "Lattice This" button that skips the optimiser. I ran it from the
command line on your part first. The good news is large: with no optimiser
deleting material first, it latticed **97% of your part instead of 12%** —
eight times more. But it also ignores every region you declare and it does not
write the file out. So a button today would lattice the whole part and silently
throw away every region you set, which is the exact thing you have been telling me
to stop doing. I stopped, and I wrote down the two changes that would make it
real.

---

## Round 7 — 2026-08-16

Full write-up: `evidence/2026-08-15-lattice-and-face-ui/r7_surface_round7.md`.

Nine items, all built and tested. The three that were misdiagnosed for several
rounds each, and are worth carrying forward:

1. **The pattern's division rule was never the bug.** Five rules were tried and each
   reported as still uneven. What was actually wrong: a divider is a PLANE and a
   plane cuts a curved strip in more than one place, and the lateral box built to
   contain that overlapped its neighbours by a quarter of their length. The fix is
   the maintainer's own — fit the circle, hinge every divider on its AXIS — because
   spokes cannot reach the far arm. New file `SurfacePatternArc.swift`; the accreted
   helpers in `SurfaceCutLines` are deleted.

2. **`FaceID?` from the id pass hid a third answer.** "Empty pixel" and "no pass"
   were one `nil`, and the caller asked the CPU picker in both cases — a picker that
   casts a world ray at model vertices. That is why tapping the floor selected a
   face. `MeshRenderer.FaceIDPass` names all three.

3. **A group has TWO memberships and both have to move together.** `faces` and
   `regionIDs`. Every "it stayed connected to its group" report on this branch is
   one of them being edited without the other.

New: `SurfacePatternArc.swift`, `SurfaceComponents.swift`, `SurfaceScratch.swift`,
`SurfacePatternArcTests.swift`, `SurfaceRound7Tests.swift`.
`FaceRegion` gained `edges` (which cuts are boundaries — `splitGrid` was throwing
that distinction away); `GridCell.drawn` became optional so "draws nothing" is
expressible. Both omitted from the encoding when absent, so PR 331's byte-identity
bar holds.

### Rounds 7b–7f — the device rounds

Full numbers: `evidence/2026-08-15-lattice-and-face-ui/r7_surface_round7.md`.

**★ THE PATTERN WAS ROOT-CAUSED ON HIS OWN PART, NOT ON A TEST SHAPE.** It passed
every synthetic strip I built and still failed on his screen, five rounds running.
`M2_verticalStand.step` is now a checked-in fixture (`Tests/TopOptFlowsTests/
Fixtures/`, loaded by `#filePath`) and swept face-by-face by `RealPartPatternTests`.
Face 4, the fillet band in his screenshots: **52 / 47 / 0 → 32 / 33 / 34**. The zero
is the whole of "Smallest piece: 0 voxels" and of "3 columns gives 1 cut".

The cause was a short-circuit sending any `frame.cylindrical` face to the old
even-angle split — and **no shape I would have invented could have caught it**, because
every synthetic mesh is a bare triangle list with no analytic surface and so never
takes that branch. Sweeping every face of the real part then found two more defects
nothing was looking for.

**★ AND THE SAME LESSON TWICE MORE.** A group holds `faces` AND `regionIDs`, and this
round found FIVE more readers of one without the other — the tint, the centroid, the
normal, the anchor set, and three empty-group sweeps that would have DELETED a
region-held group. `SelectionGroup.isEmptySelection` and
`WorkspacePlaceholder.groupTintedFaces` are now the single answers.

Other root causes worth carrying: the id pass collapsed "empty pixel" and "no pass"
into one `nil` (floor taps selected faces); `nil == nil` made an unowned piece
unselectable; a face LOOP walked through an isolated piece because it is geometry and
knows nothing of regions; a group holding a cut's PARENT held its children implicitly,
so removing one changed nothing and the face froze.

**Suite:** 1740 tests, 22 skipped, 8 failures — all 8 the known lib3mf gap
(`AppModelTests`, 3 tests), unchanged from the base commit.

**Not verified by me:** every device check in these rounds is the maintainer's; my
verification is headless plus a build on the iPad Pro 13-inch simulator.
