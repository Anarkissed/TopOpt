# THE VOID LEDGER, and the printability defaults measured

PR #358, holds of 2026-09-21. Core only. Every figure below is measured on this
branch unless it is quoted as a prior number, in which case it is named and dated.

## 1. Which prior numbers are void, per certificate PATH

### (a) The density / homogenised certificate — EVERY organic margin before this PR
Two commits in this PR change what it is told, and both are in this path alone:

| commit | date | what it changed | size |
|---|---|---|---|
| `f496ede1` | 2026-09-11 | it judged the lattice the TRACER DREW, not the one that ships | 1.84x the material |
| `f896340e` | 2026-09-16 | it counted each strut crossing once PER STRUT; now measures the union | +37 % |

Every organic margin from the density path quoted before this PR is VOID. That
includes any margin quoted in the commit messages of PR #355 and earlier, and any
margin in a handoff predating 2026-09-11.

### (b) The beam-network structural certificate — the input was ALWAYS the shipped set
`certify_organic_structural` has been fed `R.oc.organic_spans_out` — the POST-CLIP
span set — since its first commit, `0863fcab` (2026-09-03). It was never fed the
traced set. The 1.84x defect above is the density path only.

**So on the question asked, the PR 355 amendment's eleven-configuration table and
`docs/2026-09-06-device-certificate-research.md` STAND.** They were never wrong in
the way that was feared.

**They are superseded anyway, for a different and nameable reason,** and this must
not be read as an endorsement of their numbers:

- `dfaccf89` changed the bead calibration, so the RADII of those spans changed
  (+44 % mass). The beam network reads `sp.r`; different radii, different margins.
- `6d6177c4` / `07e99374` changed the span SET itself: the node merge had been
  deleting every span shorter than half its own radius, which on the stand is
  +11.7 % material and 16,546 -> 23,998 members.

The claim most at risk is the research doc's headline — "EVERY configuration fits
under 300 MB; the worst is 287 MB (traced 3-5)" — because memory scales with
member count and the member count rose ~45 % on the one part measured. NOT
re-measured here; flagged, not asserted.

### (c) Organic MASS — ~44 % low everywhere it was quoted before `dfaccf89`
From `dfaccf89` (2026-09-10): same job, same settings, lattice volume
**29,234 -> 41,959 mm3, +44 %**. The old model believed there was more material
than there was, so every prior figure is LOW. Quoted in: the commit messages of
PR #355 and earlier that carry a mm3 figure for an organic lattice, every
`run_info.json` produced before that commit, and the `[bead]` calibration lines in
those runs.

★ AND THE "34 % CLIP GAP" THAT COMMIT FLAGGED AND LEFT OPEN IS NOW SMALLER, because
part of it was never clipping — it was the node merge deleting material:

| | shipped union | / target 97,600.6 mm3 | short by |
|---|---|---|---|
| before `07e99374` | 64,500.5 mm3 | 66.1 % | 33.9 pts |
| after | 72,042.1 mm3 | 73.8 % | **26.2 pts** |

The node-merge deletion was **7.7 points** of the 34 — a quarter of the gap.

### (d) `27bf0d91`'s open item — CLOSED BY MEASUREMENT, and its premise was false
That commit left: *"NOT MEASURED YET: whether the certified margin moves."* The
paired run exists (`evidence/2026-08-21-organic-lattice/STAND/PAIR_{OFF,ON}.log`)
and was **never reported in any commit**:

| | members | welded nodes | T-junction ends | ends on NOTHING | margin |
|---|---|---|---|---|---|
| unsubdivided | 15,650 | 4,270 | 16,872 | 784 | **146.3** |
| subdivided | 61,401 | 14,202 | 52,398 | 442 | **210.1** |

The margin moves **+43.6 %**; the old behaviour was pessimistic by ~30 %.

The get-out offered — "organic welded by accident of segment length" — is FALSE for
this part. Its longest member was **28.94 mm** against an 0.8 mm weld reach, because
the run-collapse pass lengthens spans before the certificate sees them. Organic was
missing two thirds of its joints. So shipped organic figures DID depend on the
unsubdivided weld and are pessimistic by ~30 %. No stepped certificate has been
quoted, so nothing stepped is affected.

## 1d-bis. THE OUTLINE-BEAM RECEIPT FIELDS, MEASURED (hold of 2026-09-22)

These shipped in `6e0feb63` UNVERIFIED end to end: the stand has the shape grade off,
so they stayed 0 and no run had ever filled them. "Wired the same way as the verified
span census" is an argument, and this PR had just found a field wired everywhere
except the line that fills it. Measured now, on a stepped run of the stand with
`shape_grade: true` and `shape_grade_band_mm: 30` (evidence .../STAND/SG2):

| receipt field | value | ruling-B formula, computed independently |
|---|---|---|
| `outline_beam_mm` | 1.202639651 | `max(2*0.45, clamp(0.35*1.705279, 0.10, 0.35) + 0.5*1.705279)` = 1.2026 |
| `outline_bleed_mm` | 7.5 | band 30 >= 25 so `(30 - 15)/2` = 7.5 |
| `outline_inward_mm` | 8.702639651 | beam + bleed |
| `outline_voxels` | 23,636 | (voxels turned solid) |

★ AND THE NUMBER IS 1.2026, NOT 1.2100, WHICH IS THE POINT. 1.2100 is the unit test's
value at a 1.72 mm voxel; the stand's grid is 1.705279 mm. A field carrying a baked
constant would have read 1.2100 here and looked right against the brief that asked for
it. It reads the RUN'S OWN GEOMETRY, which is what was actually in question.

The band was set to 30 mm deliberately so the BLEED fires too: a run at the default
band would leave that term 0 and verify only half the formula.

## 1e. WHAT IS SUPERSEDED ON THIS HEAD AND NOT RE-RUN — the dependency, stated

The weld fix (`27bf0d91`) moved the stand's beam-network margin **146.3 -> 210.1**,
+43.6 %, and the direction is SAFE: the old number was pessimistic, so nothing
certified under it was certified too generously. That is why this is a dependency to
be discharged and not an emergency.

THREE THINGS ARE SUPERSEDED ON THIS HEAD AND HAVE NOT BEEN RE-RUN HERE:

1. **The eleven-configuration table** (PR 355 amendment). Its margins were computed
   before the weld fix, before the bead calibration changed the radii (+44 %), and
   before the node merge stopped deleting spans (+11.7 % material, +45 % members on
   the stand). Every margin in it is stale in the safe direction on the weld count and
   in an unknown direction on the other two.
2. **The tie / swirl decisions.** "Ties needed" was judged against margins taken with
   two thirds of the joints missing — the stand welded 4,270 nodes where it now welds
   14,202. A structure judged too weak without ties, on a solve that could not see most
   of its joints, may not need them. THE +43.6 % SAYS THAT JUDGEMENT MAY HAVE BEEN
   OVER-CONSERVATIVE; it does not say the ties are unnecessary, and nothing here
   should be read as retiring them.
3. **`docs/2026-09-06-device-certificate-research.md`'s "every configuration fits under
   300 MB, worst 287 MB (traced 3-5)".** Memory scales with member count and the member
   count rose ~45 % on the one part measured. 287 x 1.45 = 416 MB, which is over the
   300 MB line and under the 512 MB one that document also reports. NOT measured on the
   other ten configurations.

**THE RE-RUN IS THE FIRST STEP OF THE SUBMODEL CERTIFICATE TASK, not a loose end of
this PR.** That task needs fresh baselines on this head regardless, so re-running the
eleven there costs it nothing and gives it the only numbers it can trust. Doing it
inside PR 358 instead would re-measure eleven configurations against a head that the
submodel work is about to change again.

Order for whoever picks it up: re-run the eleven on this head FIRST, re-quote the
margins and the memory table, and only then judge ties/swirl — because the tie
decision is the one most likely to move, and it should be judged on a solve that can
see the joints.

## 2. The printability defaults

### Attribution: this was the agent's own decision
`5846c476` flipped `organic_base_mat`, `organic_fill_mat` and
`organic_trim_below_base` to false and removed `organic_overhang_fillet`, in one
line, and **its commit message does not mention the change at all**. No ruling by
letter and date covers it. The nearest maintainer findings are the 2026-08-25 raw
flow cube (printability enforcement is a CHOICE, and the census measures either
way) and the principle that printability is user input — but the former kept its
own flag **default ON**, so neither supports flipping these to false. It was my
decision and it is recorded here as mine.

### The measurement: eleven configurations, mats on vs off

Reconstructed from the configuration NAMES of the 2026-09-06 research (the original
job files were not kept), so this is a valid mats-on-vs-off comparison of each
config against itself, and NOT a continuation of that document's numbers.

| configuration | refused, mats OFF | refused, mats ON | flat base, OFF | flat base, ON | legs OFF | legs ON | stitches ON |
|---|---|---|---|---|---|---|---|
| traced 5.5-6 | no | no | **none** | 4 clusters | 5,099 | 1,227 | 408 |
| traced 4-4 | no | no | **none** | **none** | 9,361 | 9,281 | 0 |
| traced 3-5 | no | no | **none** | 3 clusters | 5,382 | 1,292 | 1,322 |
| grown, no ties | no | no | **none** | 2 clusters | 2,574 | 2,431 | 4,006 |
| grown, ties | no | no | **none** | 2 clusters | 1,951 | 1,867 | 4,027 |
| grown, ties, no swirl | no | no | **none** | 2 clusters | 2,173 | 2,118 | 4,001 |
| grown uniform 4.5 | no | no | **none** | 2 clusters | 2,976 | 3,291 | 1,937 |
| grown uniform 5.5 | no | no | **none** | **none** | 3,445 | 3,831 | 0 |
| grown uniform 6.5 | no | no | **none** | 2 clusters | 2,715 | 2,495 | 1,313 |
| M2 stand, unified | no | no | **none** | **none** | 4,597 | 4,636 | 0 |
| M2 stand, no shape fit | no | no | **none** | **none** | 5,228 | 5,412 | 0 |

"flat base" is `base_mat_clusters` from the receipt: **none** = the part ships with
nothing flat to sit on. `unsupported_cells_remaining` is 0 in all 22 runs, which is why
no row refuses.

**REFUSED at the raster printability gate: 0 of 11 with the mats off, 0 of 11 with
them on.** `unsupported_cells_remaining` is 0 in every run. Turning the mats off
made nothing unprintable at the gate — the support-leg pass carries all eleven.

**Of the printable, shipping WITHOUT a flat base: 11 of 11 with the mats off,
4 of 11 with them on.** That is the real cost of the default, and it is not a
refusal: the part passes the mid-air check and has nothing flat to sit on.

**The mats and the legs are alternatives for one job.** With the mats on, the leg
count collapses on the traced configurations — 5,099 -> 1,227 and 5,382 -> 1,292,
about 4x. Off, the lattice leans on thousands more support legs instead.

### The raster gate itself is untouched — verified
No commit in this PR modifies `require_no_midair_start`, the refusal it raises, or
the `unsupported_cells_remaining` accounting it reads. Checked with `git log -S`
over `origin/main..HEAD`; both are empty.

### Recommendation, for the maintainer and not taken here
The measurement does not support a refusal-based argument either way — nothing
refuses. It does show that the default as it stands ships every configuration with
no flat base. Whether that is right is a product decision about what "prints" means,
and it is his. Core will do either; the defaults are not changed in this commit.
