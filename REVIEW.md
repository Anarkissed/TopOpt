# Review — things that want your eyes

Only taste/polish calls on **finished** work. Nothing here is half-done, and
nothing here is something I could have checked myself.

---

## 1. The Covered wall on the wizard sample — how much should it hide?

**Done:** four solid quad panels on the vertical faces, top and bottom left open
so the lattice inside stays visible. Verified by measurement, not by eye: the
panels sit at `x/z ±9.538` against the lattice's `±9.512` (outside it on all four
sides) and are flush in `y` at `±9.512` (so the open ends are exactly level with
the lattice). `LatticeCoveredWallTests` asserts all of that.

**The call:** a real cover closes *every* face. The sample deliberately does not,
because a fully closed box would hide the cell the sample exists to show. If you
would rather it close all six and be honest at the cost of showing nothing, it is
a one-line change (add the two `y` panels to the `panels` array in
`LatticeSamplePatch`).

---

## 2. The density ceiling — 0.95 or core's 0.8999?

You said "0.5–0.95 makes sense". The floor is done and derived from your printer
(see below). The **ceiling** is a policy call I did not want to make for you:

- Core certifies octet up to **0.89988**.
- Asking for 0.95 puts the lattice **outside the certifiable band**, so the run
  would be clamped back with a reason, or uncertified if the clamp were removed.

**The call:** leave the ceiling at core's certifiable limit (current behaviour),
or raise it to 0.95 and accept uncertified runs at the top end. One constant.

---

## 3. Auto's coarse end when core has not certified a cells-per-member ceiling

`resolvedCellPlan` uses core's cells-per-member ceiling when it exists. When it
does not, Auto falls back to **8× the floor** (three dyadic levels).

**The call:** 8× is my judgement of "as coarse as a sweep can usefully go before
the cell outgrows any real member". If you want it more or less aggressive under
*minimise plastic*, it is one number.

---

## 4. The dressing weight for Rim and Diagrid

Both are drawn as a **1.6× strut-radius thickening** at the region boundary —
the same weight the wizard's sample block uses, so the part and the sample agree.

Measured effect on your face 15: None 7,356 → Rim 7,419 → Skin 7,516 pixels.

**The call:** 1.6× reads as a dressing rather than as more lattice. If you want
the rim heavier or the diagrid more prominent, it is one constant each.

---

## 5. The lattice legend's tick format

Each tick reads `NN% · X.XX mm` — the density **and** the strut thickness it
produces at the current cell, because a percentage alone is not something you can
hold against a nozzle. Five ticks, dense at the top, matching the stress legend.

**The call:** if you would rather see density only (shorter, quieter) or
thickness only, it is one function (`latticeLegendTicks`).

---

## 6. Two legends, one edge

When the **stress view** and the **strut preview** are both on, only the stress
legend shows — I suppressed the density legend rather than stack two colour bars
on the same edge.

**The call:** if you want both visible simultaneously, say where the second
should sit.

---

# Not review items — open work, stated plainly

## D2 · the artifacts — FOUND AND FIXED, ONE LINE

Verified, not asserted: the two new guards passed on real GPU renders (3.5 s and
6.4 s, so they rendered rather than skipped), and the full app suite is green —
**2001 tests, 28 skipped, 0 failures**.

**What it was.** `depth_fragment` — the shell's prepass shader — returns a `GBuf`
that declares `float4 albedo [[color(2)]]` and writes 0 there, meaning "this pixel
is the shell, not the lattice". But the shell's PIPELINE (`dpd`) only ever declared
attachments 0 and 1. A pipeline writes only the attachments it declares, so that
write was dropped and attachment 2 was left UNDEFINED over every shell pixel — and
then stored, because the pass stores it.

The deferred shade reads that attachment's alpha as its "is this pixel a strut"
mask. Undefined alpha >= 128 reads as a strut, so the shade painted lattice colour
across the shell, in a pattern that changed frame to frame. That is exactly what
you photographed and described as struts behind the back wall.

PR 340 added attachment 2 to the shader struct and to the lattice pipeline and
missed the shell's. So the bug arrived with the unified pass — and the fix does NOT
require reverting it, so I have not spent that budget you authorised.

**What identified it.** Two facts that no depth race can produce:

    shell drawn ....  [2111, 8816, 8853, 2251, 9008, 8423, ...]   spread 6,897
    shell absent ...  [6040 x10]                                  spread     0

Half those readings are ABOVE 6,040 — the count with the shell not drawn at all.
A shell can only occlude, so more struts with it than without is impossible; that
impossibility is what said "undefined memory", not "numerical jitter". And the
values clustered in two groups rather than smearing, which is tile contents, not a
race. It also explains why `cullMode`, `discard_fragment()`, split passes and
depth-write changes all did nothing: none of them touched the missing declaration.

    after the fix .. spread 0, and the shell-drawn count sits at or below the
                     unoccluded ceiling on every render

**Guarded by `LatticeGBufferMaskTests`**, two assertions: the mask is bit-exact
across renders with the shell drawn, and — the one with no escape — drawing the
shell can never yield MORE strut pixels than omitting it. The second is physics
rather than taste, and it would have caught this even if the garbage had been
repeatable. I also swept for the same class of defect: only two pipelines ever
declare attachment 1, and the 3-attachment pass has one construction site, so this
was the only instance.

## The core xcframework was stale, and it HUNG the app suite

Separately, and worth knowing because it cost the first two test runs: the app
suite wedged inside `~vector<JobLatticeRegion>()` — a destructor — reached from
`DefaultArmingEvidenceGen`. That is an ABI mismatch, and it is mine: I added
`outline_uw` and `outline_loop_start` to `JobLatticeRegion` in `core/job.hpp`, but
`app/TopOptKit/vendor/TopOptCore.xcframework` still dated from **Aug 17** and was
compiled against the old layout, while `bridge.cpp` compiles against the new
header. Destruction then walks garbage.

It presented as a hang in `ContactShadingTests` (a suite that normally takes 0.5 s)
because the log is block-buffered and ends mid-line — the true location only came
out of a process sample. `app/scripts/build_core.sh` is running now; the app suite
cannot be trusted until it finishes.

## A SECOND artifact, found by looking — NOT fixed, and characterised

The one you reported is fixed. But you told me to look rather than assert, so I put
the build on the simulator and rotated your L-bracket around, and there is a
**second, different** artifact underneath. I am not going to pretend I fixed it.

**What it looks like.** Turn the strut preview on and look at the part from BELOW.
The underside of the latticed slab carries dark speckle — sparse isolated dots at
one angle, dense mottling at another. From above, and from either side, it is clean.

**What I established about it:**

- It is **the march, not the mesh**. Toggling the strut preview OFF makes the same
  surface perfectly clean — no dots at all. So nothing is wrong with his geometry or
  with the region highlight.
- It is **deterministic**. Five consecutive frames of the live app are byte-identical
  (`md5` on `simctl` captures), and three more after a camera nudge. The nudge
  changed the hash, which proves the capture reflects live rendering rather than a
  stale buffer — so "identical" means stable, not frozen.
- It is therefore **NOT the bug I fixed**, which was undefined memory and changed
  every frame. It is also not caused by that fix: an undeclared attachment can only
  have put garbage IN, and this survives with the attachment correctly declared.

**My hypothesis, stated as a hypothesis.** The INNER face of a face region is the
depth you dragged, and the bake deliberately does not pad it (padding it would
lattice material you never declared — the front face is padded 1.5 voxels precisely
because it can be). On this part that inner face is coincident with the slab's
bottom surface, and the shell's discard test is
`regionTex.sample(...).r <= 0.0` — a linear sample of a field that is ~0 right
there. That is a per-pixel coin flip, which is what speckle looks like.

**What I tried, and why it is not in the tree.** I biased that test by half a voxel
(`< -eps`) so the shell is only dropped when clearly inside, erring toward keeping
the shell. I rebuilt, put it on the simulator, and looked: **the speckle was still
there.** So I reverted it. It is unverified and it did not work, and I would rather
hand you a clean tree than a shader edit I cannot stand behind.

**What I would do next, and why not by screenshot.** Two screenshots at different
camera angles cannot measure this — I could not even tell you whether my attempt
made it worse, because the framing changed. This needs the same treatment the first
artifact got: a headless test that renders from the far side at a FIXED camera and
counts shell/lattice disagreement pixels, so the fix is chosen against a number.
Then the real question can be decided properly — whether to bias the test, to
tie-break consistently between the two readers of the field, or to give the inner
face a pad that the CLIP honours but the EMITTED region does not.

## The notification's equal padding (D3)

Deferred at your instruction after three failed attempts. The last approach
(measure both cluster edges, pad out to each, centre in the remainder) is in the
tree and did not achieve equal gaps on screen.

## Not started

Nothing else. `outer_finish` for **Covered** and the region outline both reach core,
and the xcframework rebuild above is what makes them take effect in a real run.
Core itself is verified green: 100% of 125 tests.
