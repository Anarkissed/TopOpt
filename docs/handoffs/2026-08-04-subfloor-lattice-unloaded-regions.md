# Keep sub-floor lattice where the region carries no load

Task: `subfloor-lattice-unloaded-regions`
Evidence: `evidence/2026-08-04-subfloor-lattice-unloaded-regions/`
Built on: handoff `2026-08-04-protect-freeze-vs-solidity` §10 (PR 294), consumed, not re-derived.

---

## 0. THE HEADLINE, BEFORE ANYTHING ELSE

**It works, it is off by default, and it costs more than the probe suggested.**

On the maintainer's own part, his own back wall goes from **324 of 1257 voxels
latticed (25.8 %) to 1257 of 1257 (100 %)** — 822 of them retained below the
cells-per-member floor, at **0.74–4.45 cells per member** against a floor of 5.
Struts stay **0.42–1.77 mm**, and 0.42 mm is his own stated nozzle width: the
printability floor was not relaxed alongside the accuracy floor.

Three things came back that the brief asked about and one that it did not:

* **The argmax did not move.** On a real part, on every rung, with material
  actually retained. §10's probe result generalised (S3).
* **The margin moved by at most +0.0853 %** on the composite certificate,
  against the 0.10 % bound stated before the measurement was read (S4). Met —
  but only just, and **three rungs moved NEGATIVE** (−0.0008 %, −0.0110 %).
  Every movement §10 measured was positive. The direction is not what the probe
  predicted, and that is stated here rather than averaged away.
* **His job as written retains NOTHING**, and that is not the filter being too
  tight. It is the shape of his job — §5.
* **★ ARMING RETENTION CHANGED THE DESIGNS OF LATER RUNGS — and that is now
  FIXED, not filed.** It was solver state leaking from a finished rung's lattice
  work into the next rung's optimize: on the streaming path the lattice pipeline
  runs FEA solves BETWEEN rungs, and they were harvesting into and dropping the
  Krylov recycle subspace and GenEO basis that rung k+1 consumes. A scoped guard
  now suppresses both for the duration. **After the fix, arming the flag changes
  no design at any rung** (40/380/416 flips → 0/0/0). §7. **This is the finding a
  reader should carry away.**

And the thing that must not be lost, because it governs how much any of the
above is worth: **the certification is structurally blind to cells-per-member.**
§10's control swept the cell across the floor at fixed ρ and got a margin
identical to ten decimal places. So no Δ margin here — small, positive, negative
or zero — is evidence that a sub-floor lattice is *accurate*. Retaining one is a
decision to accept an inaccuracy this codebase cannot currently quantify. The
receipt says exactly that, in those words.

---

## 1. WHAT SHIPPED

### The candidate filter is conditioned. The gate is untouched.

`grade_lattice` (core/src/simp/grading.cpp) gained one region-scoped, measured
predicate. When `retain_subfloor_in_unloaded_regions` is armed AND the region's
peak von Mises measures at or under `lattice_subfloor_retention_stress_fraction()`
(0.20) of the **part's** peak, a candidate whose member cannot hold the floor is
kept as lattice instead of falling back to solid.

Nothing about the gate's verdict logic or tolerance changed. There was never a
gate to relax — §10 established that and this task did not re-litigate it.

**The predicate is MEASURED, never declared.** The law takes the region peak over
its candidate set and the part peak over every printed voxel, region membership
ignored, and divides. A job cannot assert that a region is unloaded.

**Three ways it refuses, all deliberate:**

* **No region ⇒ no retention.** With no candidate mask the two peaks are equal,
  the fraction is 1.0, and latticing a whole part below the floor is not "an
  unloaded region".
* **No demand field ⇒ no retention.** An all-zero demand makes the fraction 0.0,
  which *reads* as "carries nothing" but *means* "nothing was measured". This is
  exactly what the pre-flight forecast passes. Retention is measurement-backed or
  it is nothing, so absence of a field disarms it. (Unit test 13f.)
* **Printability is never relaxed with it.** An unprintable strut is a fact about
  the printer, not about load. On the swept path a retained voxel takes the
  *finest* dyadic level at which its own density still prints — finest because
  that maximises cells-per-member and so minimises the error being accepted, and
  a real ladder level so the material still meets its neighbours at shared nodes.

### The flag stays and became specific.

`lattice_strut_out_of_regime` is still raised over retained material — it comes
out of `analyze_fixed_design`'s own min-cells-per-member comparison, unchanged,
because the retained voxels really are in the posture. Measured on the wall run:
`out_of_regime` False→True, `cells_per_member_min` 5.187→0.741.

What is new is that the receipt now says *which* voxels, *at what*
cells-per-member, and *at what fraction of peak stress* — in `run_info.json`, in
the per-variant lattice receipt, and in the pre-flight forecast. A boolean that
says "out of regime" without saying why or how much is not a receipt.

### The default is inert, and that is measured, not asserted.

**S1 PASS, in four parts** — because this PR contains two changes with different
byte-identity properties and collapsing them would hide the second (§7):

* **A** a run with NO lattice, base vs branch: **byte-identical**. The blast
  radius stops at lattice runs.
* **B1** lattice, ARMED but inert, same binary: identical in every artifact except
  the `subfloor_retention` block the receipt gains — which MUST differ, or the
  user could not tell the option was on — and that block reports zero retention.
* **B2** lattice, ARMED and FIRING, same binary: the lattice artifacts change
  (that is the feature); **`report.json`, `design.bin`, `fields.bin` and every
  solid mesh are bit-identical**. This is the flag's real bar and the property
  §7's leak broke.
* **C** lattice, base vs branch: **deliberately different** — the leak fix moves
  designs on streaming lattice runs. Reported, not asserted away; what IS asserted
  is that no verdict flips.

★ The script now **asserts the two binaries differ before it compares anything.**
The first run of this bar passed vacuously: the CMake target is `topopt_cli` but
the binary is `topopt-cli`, so `--target topopt-cli` matched the existing *file*,
exited 0, and built nothing. Base and branch were the same binary and every
checksum matched. A byte-identity bar whose two sides are the same binary is
worse than no bar. (The same trap bit a second time on `--target grading` vs
`test_grading` — see §8.)

---

## 2. WHERE 0.20 COMES FROM

Derived from §10's first table, not from taste. The certified-margin movement from
latticing a region at 1.33 cells per member, by that region's share of peak stress:

| region peak vM, % of part peak | 11.66 | 14.02 | 16.57 | 19.37 | 22.09 | 23.48 |
|---|---:|---:|---:|---:|---:|---:|
| Δ certified margin | +0.0001 % | +0.0002 % | +0.0003 % | +0.0008 % | **+0.0203 %** | **+0.0823 %** |

Flat to within +0.0008 % up to 19.37 %, then up by a factor of 25 at 22.09 %.
**0.20 is the round threshold sitting in that knee**: it admits every station
measured flat and excludes every station measured steep.

The number lives in `lattice_subfloor_retention_stress_fraction()` beside the
floor it conditions, with the derivation and the blindness caveat above it, and
the law reads it rather than hardcoding it — the same discipline as every other
limit in `grading.hpp`.

**S4's acceptance bound, stated before the measurement was read:** 0.10 %, chosen
as the largest Δ §10 measured *anywhere* across its whole sweep (+0.0823 % at
23.5 % of peak) — a station 0.20 **rejects**. So the bound is deliberately loose
relative to what should happen. Measured on the real part: **0.0853 %.** Met, with
less headroom than the derivation predicts, which is itself worth knowing.

---

## 3. S5 — THE THRESHOLD, TESTED AT ITS EDGE

An untested threshold is a guess with a number attached. `test_grading.cpp` §13c
builds a part whose region stress fraction is set exactly, and straddles the
ceiling by one percentage point:

| region at | measured fraction | qualified | outcome |
|---|---:|---|---|
| 19 % of peak | 0.19 exactly | YES | wall latticed |
| **20 % of peak** | 0.20 exactly | YES | latticed — the test is `<=`, pinned so an exact hit cannot drift |
| 21 % of peak | 0.21 exactly | no | **posture byte-identical to the disarmed posture** |

The above-ceiling case is compared against a genuinely disarmed run, mask and
densities, not merely checked for "retained == 0".

---

## 4. S6 — THE GATE TABLE

`s6_gate_table.sh` / `.txt`. Five configurations, every rung, solid verdict +
margin, composite verdict + margin, voxel-classification flips.

Four are existing paths compared **base vs branch** — protection with no lattice;
lattice with no grading; graded uniform cell; graded swept + roles. Every rung:
**Δ margin exactly 0.00e+00, no verdict flip, 0 of 90112 classification flips.**

The fifth exists only on the branch, so it is compared branch-off vs branch-on on
a region measured quiet on the part's own field (0.021 of peak) with a ladder
coarse enough that all 252 region voxels are genuinely sub-floor:

| rung | retained | composite Δ | verdict |
|---|---:|---:|---|
| 0.68 | 252 of 252 | +1.74e-04 | no flip |
| 0.52 | 252 of 252 | +1.85e-04 | no flip |
| 0.38 | 252 of 252 | −1.35e-04 | no flip |
| 0.26 | 252 of 252 | −1.04e-04 | no flip |

**Negative control: PASS** — one voxel moved by 1e-9 across the iso, comparator
reports exactly 1 flip. Without it every "0 flips" above means nothing.

★ Two rows of this table were originally worthless and said so only after being
made to. The quiet region's slab first ran *outward* from the face and landed
entirely outside the part (`region_voxels` 0); corrected, it then had no
sub-floor material at all (`0 of 252 below floor`). Both produce a serene row of
zero deltas that tests nothing. The script now **fails loudly** on an empty region
and on a region with nothing below the floor, because a treatment row that cannot
distinguish itself from its control is not evidence.

---

## 5. S2 — THE MAINTAINER'S CASE, AND WHY HIS JOB RETAINS NOTHING

**Run exactly as he wrote it, retention retains zero on every rung.** The run
measures his region at **0.9102** of the part's peak. Not close.

That is not the filter being too tight. `grade_lattice` is handed **one** candidate
mask — the union of his 8 include regions minus his 1 exclude — so the predicate
answers for the union, and his union contains four bolt regions. Bolt holes are
where the stress is.

`subfloor_region_probe` measures each region separately on his own part, with no
solve at all (the demand is the rung's own von Mises out of `fields.bin`):

| his include region | region vox | below floor | stress frac | qualifies | retained | latticed |
|---|---:|---:|---:|---|---:|---:|
| **ALL (his job as written)** | 10607 | 10135 | **0.9102** | no | 0 | 4.4 % |
| **face n=(0,0,−1) 137×31mm d=4** | 1257 | 933 | **0.1707** | **YES** | **822** | **100 %** |
| bolt r=84 | 4 | 4 | 0.4247 | no | 0 | 0 % |
| bolt r=30 | 0 | 0 | — | — | 0 | — |
| bolt r=30 | 4 | 3 | 0.2798 | no | 0 | 25 % |
| bolt r=30 | 0 | 0 | — | — | 0 | — |
| face n=(−1,0,0) 31×137mm | 1022 | 1022 | 0.9102 | no | 0 | 0 % |
| face n=(−1,0,0) 9×77mm | 78 | 78 | 0.2602 | no | 0 | 0 % |
| face n=(0,1,0) 184×175mm | 8339 | 8191 | 0.4545 | no | 0 | 1.8 % |

**Exactly one of his regions is the wall he is describing.** So the end-to-end pair
is his job with the lattice scoped to that wall, off vs on, at his resolution 128:

| rung | region | latticed OFF | latticed ON | retained | in-regime | cells/member | strut mm |
|---|---:|---:|---:|---:|---:|---|---|
| **0.68** | 1257 | 324 (25.8 %) | **1257 (100 %)** | **822** | 111 | 0.74–4.45 | 0.42–1.77 |
| 0.52 | 1145 | 0 | 0 | 0 | 0 | — | — |
| 0.38 | 1096 | 0 | 0 | 0 | 0 | — | — |
| 0.26 | 1089 | 0 | 0 | 0 | 0 | — | — |

The lower rungs lattice nothing either way: their walls are thinner still and the
region no longer qualifies. **The feature helps him on one rung of four**, and the
honest summary of his case is that the top rung is the one he can lattice.

**WHAT HE HAS TO DO DIFFERENTLY:** scope the lattice region to the wall. With all
8 includes selected he gets nothing, forever, and the receipt now tells him why —
it reports the measured 0.9102 against the 0.20 ceiling rather than silently
retaining nothing.

**The per-region probe is not a re-implementation.** It builds masks with core's
own `resolve_clearance_manual` + `LatticeBoundary` and calls the real
`grade_lattice`. `lattice-variant` was tried first and refused, correctly: it
requires the restored design to reproduce the recorded margin **bit-exactly**, and
on this part a cold certification solve lands 2.8e-9 relative away from the
warm-started one the ladder recorded. That guard was not weakened and not worked
around — the probe simply needs no solve.

---

## 6. THE ACCOUNTING BUG THE LAW'S OWN INVARIANT CAUGHT

Worth recording because of *how* it surfaced.

In swept mode the cell plan rejects a whole **base cell** using the thinnest member
anywhere inside it. Dropping that ceiling for a qualified region therefore lets
through two different kinds of voxel: ones genuinely below the floor at their own
cell, and ones sitting on wider material that clear it. The first version flagged
both as retained. `grade_lattice`'s own invariant — the retained count must equal
the sub-floor voxels the posture actually carries — **threw**, and it threw on the
maintainer's real part, in the probe, not in a test.

Fixed: only genuinely sub-floor voxels are flagged and counted; the rest are
reported separately as `voxels_recovered_in_regime`, latticed and fully
certifiable, carrying no accuracy claim. That keeps `voxels_retained` the *exact*
count of material the certificate is out of regime over, which is the number the
whole receipt exists to state.

Pinned by unit test 13i, which re-derives each flagged voxel's cells-per-member
from the posture rather than trusting the report.

**On the invariant itself.** Retention does make a latticed voxel legal below the
floor, so the assertion had to change — this is stated plainly rather than
claimed as "untouched". It was **narrowed, not weakened**: a sub-floor voxel now
passes only if retention was armed, the region's measured fraction cleared the
ceiling, *and* that exact voxel is individually flagged. An unflagged sub-floor
voxel still throws, exactly as before. Three further assertions were added — the
flagged set must match the count, retained material implies an armed qualified
region, and with no retention in force the thinnest latticed member must still
clear the floor. The band and printability halves are untouched and
unconditional.

---

## 7. ★ THE LEAK — FOUND, ROOT-CAUSED, AND CLOSED

On the wall pair, arming retention changed the **solid** margin of rungs *below*
the one where retention fired — rungs at which nothing was retained.

**The control decides it.** Same job, retention off, run twice: `report.json`,
`fields.bin` and `design.bin` byte-identical, 0 classification flips on every rung
(this is also S9). The pipeline is deterministic on this part, so the difference
was **caused**.

### The root cause, read off the call graph rather than guessed

`lattice_one_variant` runs from `run_job`'s `on_variant` callback — i.e. **between
rung k and rung k+1 of the optimize ladder**, not after it (run_job.cpp, the
streaming path). It performs real FEA solves: the null-posture reproduction, the
composite certification, and on a clamped run the clamp counterfactual.

Both of the solver's carried accelerators are sticky, and both were live on this
job (straight out of its own `run_info.json`):

* the **Krylov recycle subspace** — `krylov_recycling: true`, `dim 16`, and
  `krylov_recycle_reset_per_rung` is **false** by default, so it is deliberately
  carried from one rung into the next;
* the **GenEO deflation basis** — `geneo_armed_solves: 1`, `geneo_basis_dim: 1674`.

So rung k+1's optimize was starting from a subspace **harvested from — or dropped
by — rung k's LATTICE solves**. A rung's design depended on the lattice
configuration of the previous rung. Those are separate solves and must not be
coupled.

**This was pre-existing.** Any change to a rung's lattice posture — cell size,
region, topology, skin — could move later rungs on the streaming path. Sub-floor
retention is simply the first *user-facing option* that exposes it.

### The fix: suppress, don't reset

A scoped guard (`ScopedLadderSolverIsolation`) disables both accelerators for the
duration of the lattice pipeline and restores the previous enable states on the
way out, however the function returns.

**Why suppression and not a reset.** Resetting afterwards would leave rung k+1
with an *empty* space — a third behaviour, different from both a no-lattice run
and the batch path. Suppression preserves the carried state exactly, because both
gates sit **before** the invalidation:
`RecycleSession::begin` returns on `!rc_enabled()` before its resolution-change
drop (recycle.cpp), and `geneo_solve_begin` returns on `!S.enabled` before its
structure-fingerprint drop (geneo.cpp). A suppressed solve can neither harvest
from, apply, nor invalidate what the ladder is carrying. Rung k+1 therefore
inherits precisely what rung k left it — which is what a run with no lattice block
does.

It costs the diagnostic solves their accelerators. That is the right trade: their
wall time is reported separately, and the ladder's correctness is not negotiable
against their speed. The guard lives inside `lattice_one_variant` so the
re-lattice entry point gets it too.

### Measured, on the maintainer's part, all four rungs

| rung | before the fix | after the fix |
|---|---|---|
| 0.68 — retention fired here | identical, 0 flips | identical, 0 flips |
| 0.52 | **40 flips** | **0 — identical** |
| 0.38 | **380 flips** | **0 — identical** |
| 0.26 | **416 flips** | **0 — identical** |

**Arming the flag now changes no design at any rung.** Retention still fires
exactly as before: 822 retained, measured fraction 0.170748, out-of-regime raised.

### What the fix costs, stated plainly

Closing the leak necessarily **moves the OFF baseline** on streaming lattice runs
— rung k+1 no longer consumes lattice-polluted solver state. Measured against the
pre-fix binary on the same job: 32 / 207 / 282 classification flips on rungs
0.52 / 0.38 / 0.26, margins within **+0.0736 %**, **no verdict flips**. That is
the defect being corrected, not a regression, and S1 now reports it as its own
result (part C) instead of folding it into the flag's bar.

---

## 8. S7 — THE FORECAST

**Does F3 already cover it? NO.** `variant-postprocessing-fix`'s pre-flight
forecast reported the two fallback reasons but had no concept of retention, so a
user arming it learned nothing before the run. Added: a `subfloor_retention` block
in `lattice_forecast.json`.

Same design, same region, the opt-in key the only difference:

* **not requested** — "252 of this region's voxels are below the cells-per-member
  floor and will stay SOLID. Setting `grading.retain_subfloor_in_unloaded_regions`
  would lattice them if this region measures at or under the stress-fraction
  ceiling — and would put the certificate over them out of regime."
* **requested** — "...They will be latticed ANYWAY ... IF this region's peak von
  Mises measures at or under 0.2 of the part's peak. If it measures above that,
  they stay solid. **This pre-flight CANNOT tell you which**: it runs before any
  solve, so there is no stress field to measure."

**The forecast's population count is exact** (252 forecast, 252 in the real run):
the cells-per-member predicate is width/cell and never sees density, so the
band-floor approximation the whole forecast runs under cannot move it. What it
**cannot** evaluate is the predicate itself, and it says so instead of guessing —
which is also why the law disarms retention on a demand-less field.

**One deliberate, named exception to "bit-identical".** `lattice_forecast.json`
gains this block on *every* forecast, including jobs that did not opt in — because
telling a user that material is below the floor and could be retained is most
useful precisely when they have *not* opted in. That document is produced only by
`forecast_only` jobs, makes no certification claim and never feeds a certificate.
Every run artifact S1 names is byte-identical.

---

## 9. THE BARS

| bar | verdict | where |
|---|---|---|
| **S1** byte-identity, four parts | **PASS** — A no-lattice run byte-identical; B1 armed-but-inert identical but for its own reporting block; **B2 armed AND FIRING leaves the solid ladder bit-identical**; C the leak fix's deliberate movement flips no verdict | §1, §7, `s1_byte_identity.txt` |
| **S2** the maintainer's case | **MET** — 25.8 % → 100 %, 822 retained at 0.74–4.45 cpm; his job as written retains 0 and §5 says why | §5, `s2s4_wall_case.txt`, `s2_per_region.txt` |
| **S3** argmax does not move | **MET** — same voxel on every rung, on a real part, with material retained | §0, `s2s4_wall_case.txt` |
| **S4** margin priced | **MET** — 0.0853 % vs the 0.10 % bound stated first; 3 rungs moved NEGATIVE, which §10 did not predict | §2 |
| **S5** threshold tested at its edge | **MET** — 19/20/21 % straddle, above-ceiling posture byte-identical to disarmed | §3 |
| **S6** full gate table + 1e-9 control | **PASS** — no verdict flip anywhere, 0 classification flips on existing paths, control sees 1 voxel | §4 |
| **S7** forecast says so | **MET** — F3 did NOT cover it; added, and exact on the population | §8 |
| **S8** ctest + app tests | **core 106/106**; **app 1180 executed, 13 skipped, 0 failures** | `ctest.txt`, `app_tests.txt` |
| **S9** determinism | **MET** — same job twice, byte-identical | §7 |

Both blocked-stops were checked and neither fired. The argmax held; the margin
delta came in under the bound stated before the number was read. **The threshold
was not moved to fit any measurement.**

---

## 10. WHAT WAS LEFT ALONE, AND WHAT IS FILED

* **The gate's verdict logic and tolerance** — untouched, as required.
* **`lattice_variant`'s bit-exact reproduction guard** — it refused this part and
  the refusal was correct. Worked *around* by not needing a solve, never weakened.
* **The per-region predicate.** `grade_lattice` receives one mask, so a job with
  8 include regions gets one verdict for all of them. The union reading is the
  **conservative** one — it refuses more — but it means a user with seven quiet
  regions and one hot one gets nothing. Making the predicate per-region needs the
  region decomposition plumbed into the law, and §10 measured a single region.
  **Filed, not fixed.**
* ~~The solver-state coupling of §7.~~ **FIXED in this PR**, not filed — see §7.
  What remains filed is the broader question it raises: the same leak meant ANY
  lattice-setting change could move later rungs on the streaming path, so it is
  worth auditing whether other post-processes run inside the ladder callback.
* **The blindness itself.** Answering whether a sub-floor lattice is *accurate*
  needs direct FEA of real strut geometry, measured at a **44–276× cost ceiling**.
  Nothing here closes that, and nothing here pretends to.

---

## 11. MERGED WITH main AFTER PR 293 (multiscale-lattice-to)

`origin/main` moved six commits while this was in flight, and PR 293 touched the
same files. Two real conflicts, both resolved by **keeping both sides**:

* **`GradingLawParams`** — main added `prescribed_relative_density` (multiscale
  prescribes rho instead of deriving it from demand); this task added the two
  retention fields. Purely additive.
* **`run_job.cpp`** — both sides appended a new function at the same point, and
  both bodies shared the closing brace. Kept all four functions. At the
  `grade_lattice` call site both parameter blocks are kept and the call takes
  main's new explicit `printed_iso` argument.

**The one interaction worth stating, because git could not have caught it.**
Multiscale prescribes the density and stops using `demand` *for the density* —
but it still hands in the variant's real von Mises field, and that is what the
retention predicate measures. So retention remains a MEASUREMENT on a multiscale
run. Main implemented the prescribed density inside `rho_of`, which the retention
code already calls, so retained voxels take the prescribed density automatically.
Both facts are now stated in `grading.hpp` above the two fields.

**Re-verified against the new base**, since the merge changed what "base" means:

| | |
|---|---|
| core ctest | **106/106** (main's suite grew by one) |
| app suite | **1180 executed, 13 skipped, 0 failures** |
| S1 byte-identity vs `origin/main` | **PASS** |
| S6 gate table vs `origin/main` | **PASS**, numbers unchanged |
| retention smoke test | unchanged — 252/252 retained, fraction 0.0219, out-of-regime raised |

★ **S1 needed two fixes to stay honest across the merge.**

1. Its stash-rebuild assumed uncommitted work. Once this task's work was
   committed, `git stash` had nothing to take and the script would have built the
   *branch* twice and passed vacuously — the same failure mode as the
   `topopt-cli` target trap. It now detects a clean tree and builds the base from
   `origin/main` in a detached worktree instead. (That worktree must outlive the
   runs: `topopt-cli` bakes its materials.json path in at compile time, and
   deleting it early made the base run fail outright.)
2. `run_info.json` then differed in exactly one key: `fingerprint`, the git commit
   the binary was built from. It is excluded, and the reason is stronger than the
   clock exclusions rather than weaker — this bar *begins* by asserting the two
   binaries differ, so a build-provenance stamp is guaranteed to differ on every
   correct run. Comparing it would make the bar impossible to pass rather than
   meaningful to fail. It was the ONLY difference in the whole document.

---

## 12. IN PLAIN LANGUAGE

The maintainer wanted to put a lattice inside a back wall that holds nothing up.
The software refused, silently, and left the wall solid plastic.

It refused for a real reason. A lattice is only trustworthy when a part is thick
enough to fit about five lattice cells across it — thinner than that and the
maths the certificate is built on stops describing the object. His wall is 4 mm
thick. It never had a chance.

So the rule now bends where it can afford to. If the software **measures** — from
the run's own stress results, not from anything the user claims — that a region is
carrying under a fifth of the worst stress in the part, it will lattice that
region anyway. Off by default; you ask for it. His wall went from a quarter
latticed to entirely latticed.

**What you are buying, and what you are paying.** You are buying the lattice. What
you are paying is that the certificate over that wall is no longer a promise. The
software says so, in the receipt and before the run: it names how many voxels,
how far below the limit, and at what share of the part's stress. It does *not*
say "we checked, it's fine" — because it cannot. The certificate is blind to this
particular question. The margin it reports would not move even if the lattice
there were badly wrong. That is why this is written down as an accepted unknown
rather than a clean bill of health, and why it stays off unless you ask.

**Two things worth knowing before using it.**

Selecting all eight of his lattice regions gets him nothing — the group as a whole
sits at 91 % of peak stress, because it includes the bolt holes, and bolt holes
are where the load goes. He has to pick the wall on its own. The software now
tells him this instead of leaving him to guess.

And one thing turned up that nobody asked about — and it turned out to be a real
bug, so it was fixed rather than noted. Switching this on slightly changed the
*other* designs in the same run: the lighter versions the software tries after the
first one. Not because the wall affected them physically. The software reuses some
solver scratch work between attempts to go faster, and the lattice calculation was
quietly leaving its own scratch work behind for the next attempt to pick up. So
the next design depended on what the lattice had done to the previous one, which
it never should. That is now sealed off, and switching the option on changes no
other design at all.

It was worth chasing for a reason beyond this feature: the same leak meant that
*any* change to a lattice setting — cell size, region, topology — could quietly
shift the other designs in the run. This option was just the first one visible
enough to catch it.
