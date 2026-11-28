# Stage 2 report: a strength number that holds (DRAFT, closing on a reduced basis)

DRAFT: every cell marked PENDING (b11) is filled from the final evidence runs before this report is sent.

Status: DRAFT, 2026-11-28. Stage 2 closes on a reduced basis by the maintainer's word, following the reviewer's ruling of 2026-11-28 03:10Z. Every number below comes from `stages/stage-2-strength-number.md` (cited by its section heading), `00-review.md`, `02-plan.md` or `stages/stage-4-rules-in-the-optimiser.md`. The 03:10Z ruling itself is not yet copied into the stage file; its five points are followed here as the lead passed them on. Cells marked `PENDING (b11)` wait on the final runs, listed at the end.

---

## PART 1: In plain words

**What stage 2 set out to do.** The app decides pass or fail from the safety margin. A margin of 1.5 means the part carries one and a half times your load. That number came from the single hottest little cube of the part, so it changed with the detail level. The weight shown was a solid block's, while the strength assumed your infill. Stage 2 set out to make the margin steady and honest, about the part you will print.

**What you get when it is switched on.**

1. **Printed weight.** Grams and "saved" now count your walls, infill and top and bottom skins. Against Bambu Studio on the sample bracket the figure was within 3 %: good, close enough to plan filament. On your stand the real saving is 15 % of the printed weight. The old solid figure said 23.5 %, which overstated it. On the sample bracket the three versions save 20 %, 33 % and 44 % of the plastic you would really use.
2. **A strength number that no longer rests on one hot cube.** Where the detail is fine enough, the app now reads the stress averaged over a small region whose size belongs to the plastic (1.2 mm for PLA, half the published value, your cautious rule). On textbook shapes this reading stays within 5 % of the true answer: good. On a 15 mm PLA part margins rise by about 26 % (42 % on the lightest version). That rests on the published value for PLA until your test rig checks it. For your PA12 parts there is no published value, so their strength number stays as today. Thin members also keep today's reading.
3. **The screen never shows more margin than the optimiser's own check certified.** Before, the check on the finished file could show far more. On the sample hook it showed 3.89 where the optimiser's own check said 2.66, almost half again too generous. Now you see 2.66. On a small sample bracket the lightest version showed 4.24; its own check said 2.09; you now see 2.09. This can only lower a number, never add a refusal.

**What was tried and stays switched off, and why.**

- **"One judge"** (the check on the finished file uses the optimiser's exact method). It refused every version of your Top Motor Mount: margin 1.65 fell to about 1.07, under the 1.5 pass mark. On a textbook ring it read the stress 52 to 76 % too high. It is too harsh to trust yet.
- **The surface reading** (stress carried out to the true surface of the part). Good on gentle holes, but on an inside corner rounded to 12 cubes it read 7 % low, outside the 5 % limit. Low readings are the unsafe kind.
- **Reading thin members from the forces they carry.** Exact on straight test bars (within 0.4 %), but the app cannot yet find the members in a real part.

**What the app cannot yet judge reliably.**

- **Thin load-bearing walls.** A member only 2 cubes thick in bending reads about a third of its true stress. Its margin could look up to three times too good. It needs about 12 cubes through to be within 10 %. This was true before stage 2 too; it is not new.
- **Tight inside corners.** A corner rounded to fewer than about 4 cubes cannot be read within 10 %. An inside fillet read well at 8 cubes of radius but missed at 12.
- **Squeezing and twisting loads** (compression and shear). Not tested.

**What the app will say.** Nothing new yet. A notice naming the thinnest member is built, but it stays off: it does not yet know which members carry load. Tight corners are spotted only inside the surface reading, which stays off. Both move to the next stage. No pop-ups.

**What to rely on.** Rely on the printed grams, and on the shown margin never being more generous than the optimiser certified. Rely on the averaged reading for finely detailed PLA parts, knowing it rests on a published value. For a thin wall that carries load, or a sharp inside corner, add thickness, a larger rounding or finer detail, and treat a printed test as the real answer.

---

## PART 2: Technical record

### 1. What flips (default on)

| flip | switch made default | evidence in the record | evidence on the final build |
|---|---|---|---|
| Printed grams at the user's infill, walls and skins | `TOPOPT_STRENGTH=size` (grams and the size reading share this switch) | Slicer: 138.3 g, share 0.612; shell model walls and skins 142.6 / 137.7 g (+3.1 / -0.4 %) ("Printed grams checked against a real slicer (B3)"). Skins from the job keys: 0.7466564941 g at default and stated 1.0 / 0.6 mm, 0.7581 g at 2.0 / 2.0 mm ("Printed grams read the user's own top and bottom skins"). Saved: stand res 128 15.2 % printed against 23.5 % solid ("B5 complete") [^1]; bracket res 96 20 / 33 / 44 % ("B5, the bracket at FULL resolution") | `PENDING (b11)` |
| The size form: stress read over the material's length on real stiffness, switch point 1.75 voxels, thin-member fallback (member under 2 x the size reads one voxel), surface-node ball, corner-aware width | `TOPOPT_STRENGTH=size` | Bar on curved shapes from 1.75 voxels: -4.9 to +8.2 % ("The surface-node ball NARROWED"); beam -4.9 % at 2 x, -1.7 % at 4 x ("The two fixes IN THE ENGINE"); across layers inside the bar at 19 of 20 points, -5.4 % at the coarsest ("The across-layer check read over a size"); 15 mm part +26 % / +42 % ("THE 15 mm PART RESTATED") [^2] | (b) his full-res parts before/after: `PENDING (b11)`; (c) time and peak memory: `PENDING (b11)`; (d) test K: `PENDING (b11)`; (e) lattice A to D: `PENDING (b11)` |
| Shown margin = the lower of the certificate and the file re-check | `TOPOPT_SHOWN=lower` | 15 mm bracket res 48: 0.26 version 4.241 -> 2.091; all four files the same bytes on and off ("The interim, first check"). Cannot add a refusal by construction ("THE REVIEWER'S RULING OF 2026-11-27 16:34Z", what I do with it) | test K: `PENDING (b11)`; Top Motor Mount and the stand: `PENDING (b11)`; hook, bracket, beam: `PENDING (b11)`; no version refused that the certificate passes: `PENDING (b11)` |
| Whole suite green on the flipped tip | all three above | Not run with the skins change ("Printed grams read the user's own top and bottom skins") | `PENDING (b11)` |

Size form, earlier evidence (build before the thin-member rule; to be replaced by b11): bracket res 96 PLA fell back to one voxel (needs 0.69 mm, has 1.04 mm); stand res 128 PA12 margin 2.587 -> 2.597 both ways, 526 / 458 / 516 s ("B5 complete"). Lattice A to D: 0 strength values differ with `size` on, build 26b8b784 ("Condition (b)"); job S not made on that base.

Shown-lower, what the hook will show when the flip is run (by construction, from "One judge, evidence (b) continued: the made sample hook"): certificate 4.341 / 3.713 / 2.664 against today's shown 4.759 / 4.556 / 3.891.

### 2. What stays behind its switch, unflipped

**One judge (`TOPOPT_RECHECK=fill`, k = 8).** Evidence (a) passed for the size form (16 rows within 0.5 % at k = 8) and the one-voxel form within 2.5 % on 12 rows ("ONE JUDGE, evidence (a), the full table"; "...for the SIZE form"). It fails (b):

| part | certificate | shown, off | shown, `fill:8` | source |
|---|---|---|---|---|
| Top Motor Mount 0.68 / 0.52 / 0.38 / 0.26 | 1.648 / 1.660 / 1.667 / 1.694 | 1.648 / 1.657 / 1.666 / 1.679 | 1.07 / 1.06 / 1.035 / 1.00, all REFUSED | "ONE JUDGE ON HIS OWN PART: evidence (b) FAILS" |
| the stand 0.68 | 2.587 | 2.597 | 2.444 (-5.9 %) | "One judge, evidence (b) continued: the original stand" |
| the hook 0.68 / 0.52 / 0.38 | 4.341 / 3.713 / 2.664 | 4.759 / 4.556 / 3.891 | 4.361 / 3.754 / 2.673 (within 1.1 %) | "The hook's three finished files re-checked with one judge ON" |

Cause: E x fill^3 on cut voxels. One-voxel peak against the true value ("All shapes side by side"):

| shape | all-or-nothing | E x fill^3 (one judge as built) | E x fill^2 | E x fill |
|---|---|---|---|---|
| thick ring, loaded curved bore | -6 to 0 % | +52 to +76 % | +17 to +27 % | -7 to -4 % |
| bending beam, cut faces, 4 to 16 through | -43 to -1 % | -12 to +16 % | -28 to +3 % | -47 to -4 % |

Top Motor Mount's peak sits at the inside corner where each flange meets the cross bar, 12.55 MPa on against 7.28 off there; median ratio 1.24, peak 1.54 ("WHERE Top Motor Mount's peak sits") [^3]. Cost: 3845 s against 4123 s; 936 MB against 803 MB. The reviewer ruled one judge does not flip as built (16:34Z, item 1).

**The surface carry (`TOPOPT_STRENGTH=surface`).** Real stiffness; first two full voxels carried to the true surface, curved (A + B / r^2) on free concave faces, straight on flat, convex and loaded ones; tight limit 4 voxels of radius, 8 through.

| shape | resolution | reading against exact | source |
|---|---|---|---|
| cut-skin beam, free flat faces | 4 / 8 / 16 through | -13 to -8 / -4 to -3 / -1 % | "THE READING TO PUT TO THE REVIEWER" |
| ring, loaded bore (pinned, gate -6 to +3 %) | bore 3 / 4 / 5 / 6 | -13.0 / -4.9 / -4.3 / +1.3 % | "A1 BUILT" |
| plate, round hole (held out) | radius 3 / 4 / 5 / 6 | -28.9 (tight) / -13.8 (tight) / -4.2 / -1.0 % | "A1 BUILT" [^4] |
| plate, six voxels thick | radius 3 / 4 / 5 / 6 | -30.7 / -14.9 / -3.9 / -0.8 % | "The reviewer's measurements 1 and 2" |
| ellipse (held out), six thick / two thick | b = 3 / 4 / 5 / 6 | -37.6 / -35.8 / -34.0 / -16.9 % against -37.2 / -36.7 / -34.7 / -5.2 % | "The reviewer's measurements 1 and 2" [^5] |
| inside fillet, L bracket bent open | R = 4 / 6 / 8 / 12 voxels | -9.0 (tight; 4 x not settled) / -8.3 against 4 x, -12.9 / -9.9 against the extrapolated limit / -3.5 / -6.8 % (settled reference) | "The inside fillet at 8 and 12 voxels of radius" [^6] |

It misses the 5 % bar at R = 12 on a settled reference and gets worse from R = 8 to R = 12. Tried and worse: patch recovery with zero traction, linear (ring -31 to -12 %, plate -43 to -19 % at patch 2.5) and quadratic (plate -43 to -20 %), both below the straight carry ("THE REAL FIX, candidate two"; "Candidate two with a QUADRATIC fit"). Also tried and no better, noisier: the bending-gradient carry, shapes 2 and 3 of `stress_carried_to_surface` (built and measured 2026-11-27 22:04; recorded in `05-workplan.md`'s resume note, not in the stage file): shape 2 a three-point fit A + B / r^2 + C x depth, shape 3 a damped form.

| case | shape 1 (in the switch) | shape 2 | shape 3 |
|---|---|---|---|
| plate with a hole, radius 5 / 6 voxels | -4.2 / -1.0 % | +4.4 / +7.4 % | -7.9 / -4.8 % |
| inside fillet R = 12, against its own 4 x value | -6.8 % | -5.0 % | -7.9 % |
| inside fillet R = 8 | -3.5 % | reference not settled (2 x reads about 10 % high) | reference not settled (2 x reads about 10 % high) | Also still owed under this switch: measurement 3 (across layers), 4 (his parts and carved samples), 5 (test K), and the design-box loose end ("THE REVIEWER'S RULING OF 2026-11-28 02:21Z").

**Section-force stress (measuring arm only, not in the engine).**

| case | result | source |
|---|---|---|
| determinate beam, bending, 2 to 16 voxels of core, 60 rows; tension core 2 and 4 | 1.000 in every row (per-voxel peak 0.41 to 0.96; carry 0.63 to 1.28 at 3 and 6) | "B MEASURED: section-force stress" (stage 2) |
| indeterminate, two members sharing a load, section from the model's own fills | tension +0.0 / +0.1 %; bending +0.4 / +0.1 % at 2.5 / 6.5 voxels (true section handed in: +1.1 to +5.1 %) | stage 4, "Section-force stress on a STATICALLY INDETERMINATE case" |

Missing: finding the members and their cut planes on a general shape (a skeleton); a curved or tapering member; the rows at one voxel of core did not solve.

### 3. Stated limits (ledger and report)

**A-06, thin members in bending** ("Ledger A-06 measured ahead for stage 4"): today's one-voxel reading against the true surface stress.

| voxels through | 2 | 3 | 4 | 6 | 8 | 12 | 16 |
|---|---|---|---|---|---|---|---|
| reading / surface stress | 0.33 (-67 %) | 0.56 (-44 %) | 0.68 (-32 %) | 0.80 (-20 %) | 0.85 (-15 %) | 0.91 (-9 %) | 0.93 (-7 %) |

Within 10 % needs 12 through; within 20 %, 6. The size form falls back to this reading on thin members, as ruled.

**A-07, two judges and the cut-voxel law**: the hook shown 10 to 46 % above the certificate today; closed for the shown number only by `TOPOPT_SHOWN=lower`; the law itself unsettled (tables in point 2).

**A-08, raisers under the resolved radius**: ellipse, every reading tried misses 10 % at tip radius 1.5 to 3 voxels (real stiffness one voxel -28 to -15 %; E x fill^3 -14 to +9 %, ledger). The inside fillet: -3.5 % at R = 8, -6.8 % at R = 12 (table above). "Resolved" for an inside fillet is not yet set.

**The one-voxel form's scatter**: within 2.5 % at k = 8 on 12 rows; one row -11.3 % at k = 16 ("ONE JUDGE, evidence (a), the full table") [^7]. A notch under 2 check voxels is outside the bar (ellipse 13.9 % low at one resolution).

**The size form's calibration** ("The size form against the theory's own readings"; ruling 19:36Z (d)), as multiples of the far stress, PLA L = 2.4 mm:

| hole radius, mm | Point Method | ball D = L / 2 (in force), von Mises | ball D = 2 L |
|---|---|---|---|
| 0.5 | 1.05 | 1.40 | 1.01 |
| 1 | 1.17 | 1.85 | 1.06 |
| 2 | 1.42 | 2.28 | 1.45 |
| 4 | 1.82 | 2.59 | 1.95 |
| 8 | 2.24 | 2.78 | 2.37 |
| 16 | 2.56 | 2.89 | 2.65 |

The ball in force is on the safe side of the Point Method by 7 to 58 %; a ball of 2 L would be neutral (-9 to +7 %). The small-part rise (+26 / +42 %) rests on the published length halved; his print replaces it.

**Compression and shear**: untested (ruling 19:36Z (d)).

**Detecting and naming flagged places: none ships with this close.** The tight-corner flag (`surface_tight_points`) exists only inside the unflipped surface reading, and nothing reports the counts yet ("A1 BUILT"). The thin-member notice exists as stage 4a's piece 4, behind `TOPOPT_STAGE4=member`: it names the thinnest member, its voxels through and the resolution that would resolve it, and changes nothing else (stage 4, "4a piece 4 as a NOTICE"). It does NOT ship with this close: it names the thinnest member anywhere, not a loaded one, and reads even voxel counts only. Both go to stage 4.

**Ledger at close**: A-01 open (fill^3 stays outside the size form); A-02 partly (size form where it applies; PA12 and thin members keep the peak); M-07 closed for grams by printed grams; R-08 partly (shown-lower).

**"Infill is a real lever" (the plan's stage 2 row)**: what was delivered is the weight side. Printed grams follow the user's infill and walls, so the weight shown is the printed part's. The stand really saves 15 % against the drawn part printed the same way, where the solid figures say 23.5 % ("B5 complete"). The strength side of infill (ledger R-04) is NOT addressed in stage 2. It stays open and is handed on.

### 4. Hand-over to stage 4

1. The surface reading (`stress_carried_to_surface`, `TOPOPT_STRENGTH=surface`), with measurements 3 to 5, the design-box loose end, and its tight-corner flag (to be named in the readout).
2. Section-force stress: member finding on a general shape, curved and tapered members; the planned answer to A-06 (stage 4 rulings, 2026-11-28 08:23Z).
3. The inside fillet: "resolved" radius set by measurement (R = 8 inside, R = 12 outside).
4. The member rule in voxels through (A-06 table); the piece 4 notice, to name LOADED thin members and read odd voxel counts; no readability floor on the optimiser's members without his word.
6. The strength side of infill (ledger R-04).
5. One judge flips only with the settled cut-voxel law, both judges together; then the fill-weighted one-voxel reading.

### Evidence still owed (b11)

1. The stand, res 128, size form + shown-lower.
2. Top Motor Mount, res 96, size form + shown-lower.
3. The bracket, res 96, size form + shown-lower.
4. The beam, res 64, size form + shown-lower.
5. The hook, res 64, size form + shown-lower.
6. Test K.
7. The lattice strength check, jobs A to D.
8. The whole suite on the flipped tip.

[^1]: Earlier figures for the stand's real saving were 13.5 % (first grams model, res 64) and 13.1 % (shell model, res 64); the later run at res 128 gives 15.2 %, used here.
[^2]: The 15 mm part was first measured at +33 to +41 % ("A small part, where PLA's own size switches the reading on by itself"); restated with the thin-member rule as +26 % / +42 %, used here.
[^3]: First reasoned to sit on a bolt hole ("evidence (b) FAILS"); corrected to the inside corner in the later section. The later "cut skin" section also corrects "the cruder judge is the nearer one".
[^4]: With the tight limit at 2.5 the radius-4 hole read +3.2 % ("Candidate one with a CURVATURE-SHAPED carry"); with the limit at 4 it is flagged and reads -13.8 % ("A1 BUILT"), used here.
[^5]: b = 6 read -5.5 % and -5.2 % on two-voxel plates; the later six-thick plate reads -16.9 %, which the record calls the honest value (the earlier was luck).
[^6]: R = 6 read -8.3 % against the 4 x reference ("The reviewer's measurements 1 and 2"); the later section judges it against the extrapolated limit, -12.9 / -9.9 %.
[^7]: On 7 rows the scatter was first given as "within about 2.5 %, k = 16 no tighter"; the full 12-row table adds the -11.3 % row at k = 16, used here.
