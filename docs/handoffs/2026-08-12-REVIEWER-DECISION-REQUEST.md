# DECISION REQUEST — `main` moved, PLSM shipped, and three of its defaults are ones I have measurements against

★ **This is a request for a decision, not a handoff.** Two tasks are in flight
(`plsm-restriction-operator`, running; `plsm-monotone-no-nucleation`, queued) and
both were briefed against a baseline that no longer exists. One item below is
time-sensitive and independent of whatever you decide about the rest.

---

## 0. WHAT HAPPENED

Five commits landed on `main` during the `plsm-restriction-operator` run:

```
c618a90  Merge pull request #325 from Anarkissed/claude/plsm-production-725389
ea38c0d  plsm-production: fix the CI failures — a real non-determinism, and two of mine
f882404  plsm-production: S4 lattices and certifies; the open 1e-9 determinism failure
2676401  plsm-production: the app and CLI run it; the production result at rung 0.68
5c7595d  plsm-production: the parametric level set as a job mode, default OFF
```

**The parametric level set is now PRODUCTION CODE**, not a harness probe:
`core/src/simp/plsm.cpp` (705 lines), plus `plsm.hpp`, `plsm_basis.hpp`,
`plsm_kernel.hpp`, `plsm_mma.hpp` in `core/include/topopt/`, with changes to
`run_job.cpp`, `simp.cpp`, `multigrid.cpp`, `job.cpp`, `main.cpp`, `fea.hpp`,
`pipeline.hpp`, `observability.hpp` and the app. There is a handoff,
`docs/handoffs/2026-08-10-plsm-production.md`.

★ **A correction to the record I owe you first.** An earlier interrupt referred
to "your plsm-production handoff" and asked me to close an unfilled placeholder
in it. I replied that no such handoff existed. **That was true of my branch and
false of the repository** — it had landed on `main`, which my worktree does not
contain. I should have checked `main` before saying so. The placeholder is
presumably still open; I have not read the file yet.

---

## 1. ★★ THE TIME-SENSITIVE ITEM: PRODUCTION SHIPPED WITH THREE DEFAULTS I HAVE MEASUREMENTS AGAINST

This is independent of the merge question and is the reason I am writing rather
than just proceeding.

`PlsmOptions` on `main` carries, among others:

| production default | what PR 326 measured, matched iteration, same instruments |
|---|---|
| `eta_voxels = 2.0` | **η = 1 is materially better**: internal surface 60,329 → **53,243** (−11.7%), carved 12.7098 → **9.2460** (−27%), and the settled margin went 3028 (still climbing) → **3388.6**. It was the single largest free improvement in that task. |
| `hole_period_voxels = 8.0` | **period 16 is better and costs nothing**: internal surface 79,577 → **73,014** (−8.2%), certified margin 2859.5 → **3389.5**, peak stress a third lower, no extra term and no extra solve. |
| `max_iterations = 60` | **60 is not enough for the margin to settle.** Every penalised arm in PR 326 was still climbing at 60; C=8's margin *doubled* between iterations 40 and 60 while compliance moved 2%. A compliance-plateau stop halted this task's control arm at iteration 56 while its margin was still rising 3195 → 3395. |

★ **And production has NO RESTRICTION OPERATOR of any kind** — a grep of
`plsm.cpp` for perimeter / filter / curvature / diffusion / nucleation / robust
returns nothing but one comment saying *"there is no filter"*. PR 326's perimeter
penalty at C=1 is, on the arm I measured in the current task at matched
iteration 50, **−29.6% internal surface (75,488 → 53,175) at +4.0% margin over
SIMP** — i.e. free on the margin axis.

**It is default-OFF, so nothing is running it today.** But those defaults are what
govern the first time it is switched on, and two of them are one-line changes.

★ **I have not read `2026-08-10-plsm-production.md` yet**, so it is possible these
choices are deliberate and justified there. That is exactly why this is a
question and not a patch.

---

## 2. THE ISSUES THIS CREATES FOR THE TWO TASKS

**(a) R6 cannot be verified.** `check_r6.sh` now reports FAIL on
`core/src`, `core/include` and `app` — because `main` GAINED files my branch does
not have, which read as deletions. I have not touched production; I cannot
currently *prove* it. The repository's own memory note covers this case:
*"main moves under long tasks — re-run R1 against the MERGED tree."*

**(b) ★ The sandbox premise is void.** Both briefs say "SAME SANDBOX as PR
324/325/326 — `plsm_probe.cpp`, `plsm_basis.hpp`, `plsm_mma.hpp`,
`levelset_kernel.hpp`", and both say `git diff main -- core/src core/include`
stays EMPTY. **There are now production files with the same names**
(`core/include/topopt/plsm_basis.hpp`, `plsm_mma.hpp`) beside my harness copies
in `core/tests/harness/`. My copies were written as a sandbox *because
production had none*. That reason has expired. They may now be duplicating or
silently diverging from shipped code, and a future reader will not know which
`plsm_basis.hpp` a result came from.

**(c) The current task's results may need re-reading.** `plsm-restriction-operator`
measures three restriction operators against a *harness* baseline. If production
is the thing that matters now, the comparison that matters is against
**production's** PLSM, not PR 326's harness arm.

**(d) The monotone task's brief was written before this landed** and inherits
(b) wholesale.

---

## 3. ONE MORE PREMISE THAT DOES NOT HOLD — the monotone addendum

Independent of the merge. The addendum says:

> *"THE PROJECT ALREADY HAS TPMS MACHINERY from the lattice track — reuse it, do
> not write a second implementation. Say which file you took it from."*

★ **There is no TPMS machinery in this repository.** The only `gyroid`
occurrences in `core/` are a comment in `core/include/topopt/lattice.hpp:22`
saying *"TPMS sheets (Schwarz-D, gyroid) attach to the same machinery **later**"*
— explicitly not built — and a string in `rules.json`. The lattice track is the
seven **strut** topologies (octet-legs, sc, bcc, fcc, diamond, kelvin, rhombic),
a different object from a TPMS sheet.

A gyroid is a three-line analytic function, so writing it is no burden. But the
instruction to name the file it came from cannot be satisfied, and I will not
write a new one and imply it was reused, nor relabel a strut lattice as a TPMS.
**Flagging rather than silently overriding.** (I may be wrong — if the machinery
lives outside `core/`, point me at it.)

---

## 4. WHAT I RECOMMEND

**Now, regardless of your answer:** let the current queue finish (~2.5 h — two
rescaled diffusion arms and the robust triple) on the current binary, so
`plsm-restriction-operator` stays internally consistent. Swapping the binary
under three in-flight arms would invalidate the queue.

**Then, my proposal, in order:**

1. **Merge `main` and re-run every bar against the merged tree** — R6, the
   assertion-message census, `ctest`, and the C0 inertness control that licenses
   the whole comparison chain. About 30 minutes. Without this no bar in either
   task is provable.
2. **Read `2026-08-10-plsm-production.md`** before writing either handoff, and
   close its open placeholder if it is still open.
3. **Resolve the sandbox duplication explicitly** — either state in both handoffs
   that the harness copies are deliberately frozen forks and why, or point the
   harness at the production headers. My preference is the second where the
   interfaces allow it, because two files with one name is how a divergence goes
   unnoticed.
4. **Then start the monotone task** against the merged tree.

**On the three defaults (§1): I recommend raising them as a separate, small
change with the measurements attached**, not folding them into either task. They
are one-line edits to shipped code and deserve their own review, not a paragraph
inside a 900-line handoff about something else.

---

## 5. THE DECISIONS I NEED

1. **Merge `main` before or after the monotone task?** My recommendation: before.
2. **Should I re-measure `plsm-restriction-operator`'s candidates against
   PRODUCTION's PLSM**, or is the harness baseline still the right comparison?
3. **The sandbox duplication** — freeze the forks and document, or converge on
   the production headers?
4. **The three production defaults** — do you want them raised separately, folded
   into a handoff, or left alone because `2026-08-10-plsm-production.md` already
   justifies them?
5. **The TPMS premise** — is there machinery I have not found, or do I write the
   gyroid and declare the override?

★ **If I get no answer, my default is:** finish the current queue, merge `main`,
re-run all bars, read the production handoff, write up
`plsm-restriction-operator` against the merged tree with the sandbox duplication
stated plainly, and hold the monotone task until the merge is clean.

---

## 6. WHAT IS IN FLIGHT RIGHT NOW

`plsm-restriction-operator`, complete and measured:

| arm, matched iteration 50 | carved | internal surface | vs no operator | CAD err mm | margin | vs SIMP |
|---|---|---|---|---|---|---|
| SIMP (the bar) | 7.5521 | 26,191 | — | 0.4293 | 3254.3 | — |
| no restriction operator | 14.3167 | 75,488 | — | 0.4726 | 3394.6 | +4.3% |
| **A · Helmholtz filter r=1** | 12.4014 | 65,863 | −12.8% | 0.4614 | 3332.3 | +2.4% |
| A · filter r=2 | 11.6480 | 62,728 | −16.9% | 0.4901 | 1984.3 | −39.0% ✗ |
| A · filter r=3 | 11.0810 | 57,471 | −23.9% | 0.5331 | 1837.3 | −43.5% ✗ |
| **perimeter penalty C=1** | **9.1077** | **53,175** | **−29.6%** | **0.4261** | **3383.7** | **+4.0%** |

★ **The crude global tax beats the principled filter on every column.** Only
r=1 clears R4's margin bar, and it delivers less than half the surface reduction.
Candidate C's first sweep was destroyed by a scaling error of mine (I invented
`τ = T·λ·h`; Yamada 2010 says τ is *"the ratio of the fictitious interface energy
and the objective functional"*, swept 1e-5 to 5e-4 against **normalised**
sensitivities). It is rebuilt as a true gradient-norm ratio with a refusal below
1, and is re-running. Candidate B has not run yet.

Still queued: two diffusion arms, the robust triple, then the full measurement,
handoff and commit.
