# The third lattice algorithm, and a selector for all three

**Base commit: `d28527cc`** ("The 5-cell floor is an accuracy threshold, so let the load
decide it") — PR 345's HEAD, which already carries PR 344. Both are unmerged; this
branch sits on 345's HEAD and is rebased, not cherry-picked. PR **346** appeared while
this task was running and is **not** pulled — see §0 for why, and for what it already
owns.

Scope: **core/**. No UI, no settings row, no control (§6a). The selector is schema + CLI
only, because the maintainer is wiring it into his own settings ladder and a control
invented here would have to be removed.

---

## SECTION 0 — the answers, one line each

**The three CLI invocations.** From `evidence/2026-08-21-organic-lattice/jobs/`, against
`M2_verticalStand.step` at resolution 128, mode `analyze` (the lattice-only path):

```
core/build/topopt-cli analyze doubled.json --out ../runs/doubled
core/build/topopt-cli analyze stepped.json --out ../runs/stepped
core/build/topopt-cli analyze organic.json --out ../runs/organic
```

The three job files differ in **exactly one line** — `"grading": { "algorithm": … }`.
`nokey_bandC.json` is the same job with the key absent; it resolves to `doubled` and
produces the byte-identical lattice.

**Did organic produce a connected lattice, and what is the disconnected count (R3).**
**Yes, and the count is 34 of 3,056 kept curves — 1.11 %.** One curve has no connector
at all; there are 3 connected components and the largest holds **98.46 %** of the
curves. The target is zero and 34 is not zero, so **34 is the finding**. It was 469 with
no connection at all before two defects were fixed (below).

**Is the exported mesh watertight and manifold (R4).** **Closed: zero boundary edges,
outward-wound, and its signed volume equals the generator's own analytic sum to the last
digit** (1403.7347 vs 1403.7 mm³). **Not edge-2-manifold — and neither is the shipped
octet export**, which carries *more* non-manifold edges on the same fixture (164,456 vs
127,080). A strut lattice is an interpenetrating union of closed solids by design;
`lattice_gen.hpp` says so and PR 201 closed a real print on it.

**The achieved spacing window (R5).** Requested **2.734–5.116 mm**; **achieved
1.369–7.795 mm, median 3.069 mm**. Neither floor bit — the printability floor is 1.618
mm and the *resolution* floor is 1.705 mm. Against §0(ii)'s theoretical 1.173–4.931 mm:
the low end is *below* it, because Jobard–Lefer lets a curve approach to `d_test = 0.5 ×
d_sep = 1.367 mm` before stopping. **That is the algorithm behaving as specified, and it
is where organic's extra mass comes from.**

**What fraction of struts the overhang clamp touched (R6).** At the default: **zero, and
the default is disarmed** — his coupon printed a 41.78 mm unsupported run clean, so the
45° rule is not the binding limit on this machine. The counterfactual is reported
regardless: **64.67 %** of traced curve segments sit outside a 45° cone. Armed at 45°:
74.15 % of steps clamped, 81.62 % of curves touched, and afterwards **exactly 0.000000**
of traced segments outside the cone. The clamp is exact because it runs *in* the loop.

**The three-way comparison (R10).** One table, `r10_three_way_comparison.txt`. Headline:
same part, same law, same density — doubled and stepped **77.568 g**, organic **90.538
g** (+16.7 %), and stepped leaves **4 of its 5 abutting region pairs mechanically
disconnected**.

---

## ★ THE PREMISE THAT WAS WRONG, AND WHAT I DID ABOUT IT

The task states that STEPPED "EXISTS as of PR 344/345" and must not be touched. It does
not exist as a distinct algorithm. PR 344's own handoff says, under *WHAT IS NOT DONE,
PLAINLY*:

> §4(a) — STEPPED is not shipped. The dyadic ladder exists and is FEA-driven, but no
> user-facing Lattice Settings option was added.

Read exactly — and the maintainer confirmed this reading mid-task — the mechanism PR 344
had in mind is the ladder already in `cell_mode: "swept"`, which *does* vary the cell
from the FEA. What was missing there was only the option.

**But this task's two algorithms differ on precisely the thing the ladder *is*.** It
defines DOUBLED as "the dyadic ladder" and STEPPED as "per-region cell from the FEA, **no
transition handling**". The ladder *is* the transition handling, so the two cannot both
be `swept`, and the no-transition variant was genuinely not in the tree: `CellSizeMode`
on PR 345's HEAD is `{Fixed, Auto, Swept, Fit}`, and grep for a lattice algorithm named
"stepped" across PR 344's, 345's and 346's branches finds only `stair-stepped`,
`steppedWidth` and a `LoadFlow` comment.

A selector value that silently ran DOUBLED would be the worst of the three options, so
**STEPPED is built here** rather than faked or refused. It is small, and the measurement
it produces is the point: it shows *why the ladder exists*.

---

## ★ PR 346, AND WHY IT IS NOT PULLED

PR 346 (open, stacked on 345) fixes a throw this task hit on arrival: `plan_cell_sizes:
level assignment is not an aligned octree`, on the maintainer's part, at the **default**
aesthetic band. Proved pre-existing against the base binary before any of this task's
code was written (`x0_preexisting_doubled_throw.txt`). PR 346 narrows it usefully —
`[0.10, 0.90]` fine, `[0.0505, 0.35]` fine, `[0.0505, 0.8999]` fails — and its remedy is
a **workaround** that says so in its own code (the default range now starts at 2 × ρ_min);
the real fix, intermediate octree levels, is explicitly not done there.

Not pulled: it is unmerged, this task's base is pinned to PR 345's HEAD, and the standing
instruction is to rebase when they land rather than cherry-pick. Nothing here needs it —
band C (`[0.1, 0.35]`) is one of the ranges PR 346 measures as fine, and all three
algorithms get the identical job apart from one key.

---

## THE METHOD

### §1 — the tracer (`core/include/topopt/organic_lattice.hpp`, `src/mesh/organic_lattice.cpp`)

**(a) Eigen-decompose.** A **cyclic Jacobi** solve per candidate voxel, fixed sweep count,
fixed pivot order. Chosen over the closed-form trigonometric solution deliberately: the
analytic form loses orthogonality near a degenerate pair, and a degenerate pair is
exactly where a stress field spends its time. Jacobi is a product of plane rotations, so
the frame is orthonormal by construction. Eigenvectors are ranked by |λ| descending with
ties on ascending column index, and each vector's **sign is canonicalised** (largest
component made positive) — without that the direction field is a line field whose sign
flips voxel to voxel and the traced curve depends on the traversal that produced it.
§1(a) predicted this would be milliseconds. Measured: the *whole tracer* is 0.22 s.

**(b) RK4.** The direction at an arbitrary point is trilinear over the eight surrounding
voxel centres, restricted to traceable voxels, with every contributor **sign-aligned to a
reference first** — without that, two adjacent voxels holding the same axis with opposite
signs interpolate to zero in the middle. Tracing stops at the candidate-set boundary.

**(c) Spacing by the field, not a constant.** `d_sep` is a per-voxel input — that is the
whole mechanism (CURVY's posture: *"controls the spacing between adjacent streamlines
locally using the density field"*). Seeds are offered at `d_sep` transverse to an
accepted curve; tracing stops within `d_test = 0.5 × d_sep` of another curve of the same
family. **Cell size is an output**, read off the achieved spacing.

`run_job` derives the field from the grading law's own density:
`d = organic_spacing_for(ρ, t) = (t/2)·√(3π/ρ)`, at a **constant bead**. The grade is
expressed through spacing, so a strut never has to thin below what the nozzle lays.

**(d) Connect.** For every pair of curves of *different* families that come within
`d_sep`, a connector at their nearest points. The shortest segment between two curves is
perpendicular to both tangents — which *is* the cross product — so Daynes' step 5 falls
out rather than being imposed. **Measured, not assumed:** on the axis-aligned fixture the
deviation from the cross product is **0.000°** over every connector the sampling can
resolve.

**(e) Thin.** Descending length, ties on ascending index, so long load paths survive.

### §2 — the constraints, in the loop

**(a) Overhang.** When a traced direction leaves the printable cone it is projected onto
the nearest in-cone direction *there and then*: keep the transverse component, rotate
toward the build axis until the cone angle is met exactly, sign from the direction's own
axial term. Never a repair pass — a repair pass discards the stress alignment that is the
entire justification for the method. The emitted segment is in-cone by construction,
which is why the armed arm measures **exactly zero** out-of-cone traced segments.

**(b) The angle is a parameter with a reported default**, and the default is **disarmed**
(`grading.organic_overhang_angle_deg`, 0). §0(i) is the reason and it is his own
experiment. Both the default and the 45° counterfactual are on every receipt.

**(c) The strut floor binds.** `min_extrudable_width_mm` = 0 means UNSET and the tracer
**refuses**, in `trace_organic_lattice`'s first block. Printability is user input.

**(d) Spacing and thickness are coupled through mass, and there are TWO floors.** The
printability floor is `d ≥ t·√(3π)/2` (tighter than that and three families put more
solid through the box than there is box) — **1.618 mm** here. The one nobody had named is
the **RESOLUTION floor**: the tracer integrates a field sampled at the voxel grid and
cannot place curves closer than the grid resolves the field they are meant to follow —
**1.705 mm** here, and on this part it is the binding one.

★ **That floor changed the default bead.** At the stated 0.42 mm nozzle the whole
certifiable band lands at `d = 0.68–2.87 mm`, so the dense half of the band is below the
grid and every voxel there is raised to the floor — the spacing stops varying and *the
grade disappears*: a uniform lattice wearing a graded density. So the default bead is
derived the other way round (`organic_default_strut_diameter_mm`): pick `t` so the
densest lattice in the band sits exactly *on* the resolution floor, never below the
user's stated minimum width. On this job that is **1.054 mm**, and both floors then miss:
**0 voxels raised for print, 0 for resolution.**

### §3 — certification: the cell rule has no meaning here

**(a) The curve-crossing count, under its own name.** `cells_per_member` counts cells
across a wall; an organic lattice has no cells. The equivalent is
`curves_per_member(x) = member_width(x) / spacing(x)` — how many curves of one family
cross the member. Measured on his part: **min 3.083, median 8.681**, floor 2.0, **0
voxels below the floor**. It is reported under its own name and `posture.cell_size_field`
is **left empty on purpose**, because filling it with the separation would silently
re-point the certification's cells-per-member guard at this number — the exact
overloading §3(a) forbids.

**(b) Why the floor is 2 and not 5.** PR 345 established that the 5 is an *accuracy*
threshold, not a buildability one. The same reasoning applies here and lands somewhere
different: there is **no homogenised tensor for traced geometry**, so there is no accuracy
claim to floor. What remains is percolation — below 2 curves a member is spanned by at
most one curve of each family, which is a line of struts and not a lattice. Anything
below is counted and reported out of regime.

**(c) ★ ORGANIC IS AESTHETIC-ONLY, AND IT REFUSES OTHERWISE.** §3(c) says organic may be
offered structurally *only if you can state what it certifies against*. It cannot be
stated: a traced lattice is anisotropic **by construction** — that alignment is where
Daynes' +101 % comes from — and the certification library carries exactly one **cubic**
tensor per topology, measured on the octet cell as a function of relative density alone.
So `"algorithm": "organic"` **requires `"intent": "aesthetic"` stated explicitly** and
throws otherwise, naming the reason.

It requires it *explicitly* rather than accepting the default, and that is deliberate:
the default intent differs between the two paths that reach the organic step (`analyze`
applies the lattice-only job's aesthetic default; `lattice_one_variant` is shared with
the TO+lattice path and leaves it Structural so that path stays untouched). A refusal
keyed on the *resolved* intent would mean different things on the two paths.

**(d) The certificate still runs.** Organic goes through the same
`analyze_fixed_design`, and the receipt carries `tensor_out_of_regime: true` with a
one-line note beside the verdict, so what it is a certificate *of* is never left to
inference.

### §4 — the selector

`LatticeAlgorithm { Doubled, Stepped, Organic }` in `topopt/lattice_algorithm.hpp`,
**orthogonal to `CellSizeMode`**: the mode says how the cell is chosen, this says what
kind of lattice is laid down. `grading.algorithm` in the job schema, refused rather than
defaulted when unknown. **Absent means `doubled`**, so every existing job is unchanged.

**All three emit a per-voxel relative density** (§4a) — every consumer enumerated and
verified in `r8_density_consumer_census.txt`, and nothing downstream branches on the
algorithm. That contract is what makes the selector cheap, and it is what lets the R10
table read **one** quantity three times: `grading.lattice_solid_volume_mm3`, computed from
whichever algorithm's own field the run produced.

**The app is untouched** (§4e). It already carries a per-voxel density and needs to know
nothing more; if the preview ever must know which algorithm ran, `run_info.grading.
algorithm` is core's answer to bridge rather than re-derive.

---

## ★ TWO DEFECTS THE MEASUREMENTS CAUGHT, BOTH IN MY OWN CODE

**1. The per-voxel density was an occupancy, 8× high.** The first version measured strut
volume deposited in each voxel *alone* and reported 0.159 where the analytic lattice
density is 0.0191. At a 1 mm voxel and a 5 mm separation a voxel either holds a bead or
holds nothing — a per-voxel figure is a **binary occupancy wearing a density's name**. It
is now box-filtered over one local separation, normalised by the candidate volume in the
window, off summed-area tables. **Caught by a positive control**: the synthetic fixture's
analytic `organic_density_at(5.0, 0.45)` = 0.019085 against a measured median of 0.01872
— 1.9 %.

**2. Two-thirds of the lattice was never traced, and R3 was the symptom.** Measured on
his part: `curves_per_family = [28, 534, 0]`. **The third principal family traced zero
curves.** Two causes, both structural in Jobard–Lefer as published:

* a curve **discarded as a stub offers no seeds**, so its whole branch of the seed tree
  dies — and the first seed of family 2 produced a stub. Fixed by a **sweep in ascending
  voxel index** that re-primes the flood whenever the queue empties. It also fixes a
  second thing the published algorithm cannot do: his lattice is *nine declared regions*,
  and a flood front cannot cross the solid between them.
* the stub threshold was 2 × `d_sep`. His lattice regions are **4 mm-deep face slabs**, so
  the family pointing *through* the slab produces ~4 mm curves against a ~5.5 mm
  threshold, and every one was discarded — the family that braces the other two.
  Threshold now 1.0 × `d_sep`, with that measurement recorded at the constant.

And a third, smaller: **one connector per curve *pair*** left two curves running
alongside each other for 80 mm braced *once*. Now one per **near-approach**, at stations
one separation apart, refined to the mutual nearest pair (which is what restores the
cross-product direction — the station search alone reads 78° off it).

After all three: `[637, 904, 1515]` curves, 17,153 connectors, **34 curves under two
connections instead of 469 with none.**

---

## BARS

| bar | status |
|---|---|
| R1 all three run from the CLI on his part | **done** — invocations in `r1_cli_invocations.txt`; one key apart |
| R2 doubled/stepped byte-identical to PR 345 | **done, with one qualification** — `fields.bin`, `analysis.json`, `analysis_report.json` byte-identical against the BASE binary on the key-less job. `run_info.json` gains three **additive** fields (`algorithm`, `algorithm_latticed_voxels`, `lattice_solid_volume_mm3`) and the timestamp. The lattice itself is identical; the receipt is a superset. Binary-differ guard run first. |
| R3 organic connected, disconnected count | **done — 34 of 3,056 (1.11 %), 1 with none, 3 components, largest 98.46 %.** Non-zero, and reported as the finding |
| R4 watertight + manifold, asserted | **done** — closed (0 boundary edges), outward-wound (signed volume == analytic sum), NOT edge-2-manifold — and the octet reference is *less* manifold on the same fixture |
| R5 achieved spacing window | **done** — 1.369–7.795 mm achieved vs 2.734–5.116 requested vs 1.173–4.931 theoretical, with both floors and which bit |
| R6 overhang clamp at default and at 45 | **done** — 0 % at the default (disarmed, with the coupon as the reason), 64.67 % counterfactual, exactly 0.000000 armed |
| R7 curve-crossing count defined and reported | **done** — `curves_per_member`, min 3.083 / median 8.681, floor 2.0, 0 below |
| R8 per-voxel density from all three; consumers | **done** — 11-entry census, each verified at the call site |
| R9 deterministic, same job twice | **done** — every artefact byte-identical bar the wall-clock stamp; both probes compare exact doubles |
| R10 three-way comparison table | **done** — one table, split into a control block and a result block |
| R11 no no-go without addressing §0 | **n/a — this is not a no-go.** Every item of §0 is addressed by name below |
| R12 no assertion weakened or deleted | **done** — full removed-line census, read whole: 13 removed lines, **0** carrying `throw`/`assert`/a refusal; 13 assertion sites added; no test file touched |
| R13 cost measured directly, Release verified | **done** — `CMAKE_BUILD_TYPE=Release` confirmed in the cache; the tracer timed **directly** at 0.2200 s, and no cost claim is derived from differencing the arms' wall clocks |
| R14 no placeholders, no root scratch | **done** — everything under `evidence/2026-08-21-organic-lattice/` |

---

## §0, ADDRESSED BY NAME (R11)

This is not a no-go, so the standing bar does not bind — but every item earned its place
and each is answered:

* **(i) his printed coupon.** It is why the overhang clamp defaults to **disarmed** and
  why 45° survives only as a reported counterfactual. Load-bearing, not cited and
  ignored.
* **(ii) the spacing window passes.** It does, and the *achieved* window is now measured
  against it — including the part it did not predict, the resolution floor.
* **(iii) Daynes.** The method: eigen-decompose, trace, grade along isostatic lines, and
  step 5's cross-product connector — verified at 0.000° rather than assumed.
* **(iv) Jobard–Lefer.** `d_sep` seeding and `d_test` stopping, both implemented and both
  named at their constants. Their known limitation (seeds only grow from accepted
  curves) is where defect 2 came from, and the sweep is the fix.
* **(v) CURVY.** Spacing driven by the density field at a constant bead, which is the
  posture `run_job` takes: `organic_spacing_for(ρ, t)`.
* **(vi) `adaptive-streamlines`.** Not needed — the algorithm is short and is here.
* **(vii) VTK's parameter names.** `SeparatingDistance` → `seed_ratio × d_sep`,
  `SeparatingDistanceRatio` → `test_ratio`. Same four knobs.
* **(viii) farthest-point seeding.** Not used. The voxel-order sweep is deterministic and
  needs no Delaunay structure; §5(a) requires a deterministic tie-break and ascending
  voxel index is one. Worth revisiting if uniformity becomes the complaint.
* **(ix) self-supporting lattice design.** The constraint is **in the tracing loop**, not
  in a repair pass, exactly as that literature does it — and the angle is adjustable.

---

## ★ WHAT IS NOT DONE, PLAINLY

* **R3 is 34, not 0.** 1.11 % of curves attach to fewer than two connectors and one
  attaches to none; three components rather than one. These are curves that end near a
  region boundary where no other family runs within a separation. The remedy is probably
  a boundary-anchored connector (the diagrid skin does the analogous thing for the octet
  path), and it is not built here.
* **The swirl is named, not solved (§6d).** 4.04 % of candidate voxels have their top two
  |eigenvalues| within 2 % of each other, so the principal *frame* there is not
  determined and the eigenvector order can swap between neighbours; the worst curve saw a
  flip on every step. §6(d) says report it and build no combing pass, so none is built.
  Frame-field smoothing is the separate question.
* **STEPPED is new here and is measured, not endorsed.** 4 of its 5 abutting region pairs
  are mechanically disconnected. It exists so the UI can be built against three
  algorithms and so that cost is visible; it is not a recommendation.
* **The geometry path is wired but no end-to-end STL of HIS part was produced.**
  `analyze` grades and reports; only `lattice_one_variant` writes lattice geometry, and
  reaching it needs a stored design (`lattice-variant`), which would need an optimize run
  of his part that does not exist here. Both new generators ARE exercised directly and
  measured — `generate_organic_lattice` and `generate_lattice_stepped`, the latter on the
  two-abutting-passes-at-unrelated-cells configuration that defines the algorithm — see
  `r4_watertight_manifold.txt`. What has not happened is one command producing one file
  containing shell + organic struts for `M2_verticalStand.step`.
* **No new unit tests.** Two standalone probes (`organic_probe`, `manifold_probe`) carry
  the positive controls; the existing suite was run as a regression check.

---

## PLAIN LANGUAGE

There are now three ways to fill a part with a lattice, and you can pick one from the job
file or the command line. Nothing changes unless you ask for it — a job that says nothing
gets exactly what it got yesterday, proved by running the old program and the new one on
the same job and comparing the files byte for byte.

The first way, **doubled**, is what you already had: cubic cells, and when the cell size
has to change it changes by doubling, so the corners of the big cells land on corners of
the small ones and the struts meet properly.

The second, **stepped**, gives each region you selected its own cell size, worked out
from how hard that region is actually working, and does *not* do the doubling trick. It
is simpler, and the price is now a number rather than an argument: of the five places
where two of your regions touch, the struts actually meet at **one**. At the other four
the two lattices pass each other without joining. That is exactly why the doubling exists
— and now you can see what it buys.

The third, **organic**, is the new one. Instead of stacking cells, it works out which way
the stress runs at every point and draws curves that follow it, like iron filings around
a magnet. Where the part works harder the curves are packed closer together; where it is
idle they spread out. Then it stitches the curves to each other wherever two of them pass
close, and those stitches are what make it a lattice rather than a bundle of wires.

Three things worth knowing about it:

**It came out heavier** — 90.5 g against 77.6 g for the same part at the same requested
density. That is not a mistake; the rule that stops one curve running into another lets
them get to half the spacing before it stops them, so locally it packs tighter than
asked. There is a dial for that if you want the mass back.

**The 45-degree overhang rule is off by default, because of your coupon.** You printed a
traced part with a 41.78 mm unsupported run, supports off, and it came out clean. Turning
the rule back on would straighten roughly two thirds of the curves toward vertical and
throw away the thing that makes the method worth doing. The report tells you what the
rule *would* have changed either way, and one line in the job file turns it on.

**It is for looks, and it says so — it will not let you pretend otherwise.** Asking for an
organic lattice as a *strength* claim is refused outright, with the reason. The strength
check works by looking up a stiffness measured on a cube-shaped cell, and these curves are
deliberately not cube-shaped — that is the entire point of following the stress. So the
certificate still runs, and it still tells you the truth about the part, but it now says
in writing that the lattice inside is not the material it is doing its arithmetic with.

Finally, two things I got wrong and the checks that caught them. The density it reported
was eight times too high, because it was measuring "is there a strut in this exact
millimetre" instead of "how solid is this neighbourhood" — a test against hand arithmetic
on a simple block caught it. And two of the three families of curves were barely being
drawn at all, because a curve too short to keep also stopped the program looking anywhere
near it, and your lattice regions are only 4 mm deep so the curves crossing the thickness
were all too short. That one showed up as the connection count: 469 curves joined to
nothing. After the fix it is 34.
