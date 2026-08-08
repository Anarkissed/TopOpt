# shell-at-the-runs-printed-iso — the filed defect does not exist; here is what does

**Task:** `2026-08-09-shell-at-runs-printed-iso`
**Evidence:** `evidence/2026-08-09-shell-at-runs-printed-iso/`
**Changes:** `core/` only. CI: `core-linux` + `app-macos`.
**Stacks on:** `fix-inward-wound-normals` (`1ac40d0`), which stacks on
`strut-clip-matches-shell` (`c586e8d`).

---

## 0. HEADLINE

**★ THE TASK WAS FILED ON A FALSE PREMISE, AND I FILED IT.** The claim was that
`check_v3` is called with the file-scope constant `kIso = 0.5`
"unconditionally", so a multiscale run would export a shell cut at 0.5 while its
printed set extends down to ~0.0252.

`analyze.cpp` declares **two** things called `kIso`:

```
:25   constexpr double kIso = 0.5;                 // file scope
:143    const double kIso = printed_iso;           // INSIDE analyze_fixed_design
:389    out.v3 = check_v3(grid, density, kIso);    // <- binds to :143
```

`analyze_fixed_design`'s body is lines **133–564** (brace-matched), so :389 binds
to the **shadowing local**, and `minimize_plastic.cpp:573` resolves that argument
to `multiscale_printed_iso()` on a multiscale run. **The exported shell is
already cut at the run's own printed iso.**

Two consequences follow, and both retire parts of the filed scope:

* **The solid export is NOT self-inconsistent either.** Both call sites pass
  `run_printed_iso(options)`, and at `smooth_factor == 1` the export writes
  `v3.mesh` — which is at that same iso. The two already agree; there is nothing
  to make agree.
* **PR 316's no-protrusion invariant does NOT refuse multiscale runs**, which is
  what I warned about when filing. Measured below.

**WHAT IS REAL is smaller, and it is mine.** `strut-clip-matches-shell` added
`exported_shell_for()` with a hardcoded `kExportedShellIso = 0.5` **and a comment
asserting the false claim as fact** — the comment that got this task filed. That
helper feeds the lattice FORECAST, and the forecast also carried two more
separate `0.5` literals. Three chances to drift, and a piece of confident
misinformation sitting in the file where the next reader would find it.

---

## 1. §B — THE PREDICTION, STATED BEFORE THE RUN, THEN CHECKED

**Prediction, written before running anything:** the multiscale printed iso is
0.025235, far *below* 0.5, so a shell cut there **encloses more** material. PR
316's invariant should therefore get **easier** on a multiscale run, never
harder, and its refusal should not fire. *If it gets harder, the iso is not the
problem and that is the finding.*

**Result — the prediction held.** A multiscale lattice run (l-bracket, res 40,
`multiscale: true`, armed: `[multiscale] armed: topology=octet
region_voxels=1080`):

```
clip_base_surface             exported_shell
max_strut_protrusion_mm       0
protruding_vertices           0   of 786,120 measured
lattice_accepted              True
```

**0 of 786,120, and the run completed.** No refusal. The invariant is satisfied
on multiscale exactly as on classic runs, and for the predicted reason: the shell
already contains the in-band material, so there is nothing for a strut to
protrude through.

The direction is also pinned as an assertion, not just observed once —
`test_shell_iso_provenance` case 2 requires the multiscale shell to have *more*
triangles than the 0.5 shell.

---

## 2. WHAT CHANGED

| file | change |
|---|---|
| `core/src/cli/run_job.cpp` | `exported_shell_for(sg, dens)` → `exported_shell_for(sg, dens, printed_iso)`. The iso is a **parameter**, not a file-scope constant, and out-of-range throws. |
| `core/src/cli/run_job.cpp` | its comment: the false claim replaced by the shadowing fact, with the line numbers and the brace-matched body range. |
| `core/src/cli/run_job.cpp` | `forecast_uniform` resolves **one** iso and hands it to all three consumers (shell, boundary base, certification mask) — they were three separate `0.5` literals. |
| `core/tests/unit/test_shell_iso_provenance.cpp` (new ctest `shell_iso_provenance`) | the bar. |

**Why the forecast's resolved iso is still 0.5, and why that is a fact rather
than an oversight:** the forecast runs inside `lattice_variant_job`, and that
entry point **never arms** `multiscale_lattice` — the flag is set only in
`run_job` (~:7422). So the job being forecast is classic and its printed iso is
0.5. Resolving it through the same helper makes that a stated fact, and makes the
forecast follow automatically if the re-lattice path ever learns multiscale.

---

## 3. BARS

### A fixture that fails first · **PASS**

The defect is a wrong *belief*, so the test is red against the state the belief
describes: `analyze.cpp:389` pinned to the literal `0.5`. `r2_red.txt` —
`v3.mesh` stays **188 triangles at both isos** and case 3 fails. Restored,
`r2_green.txt` — 764 at the multiscale iso, 7 checks, 0 failures.

### Byte-identity where nothing should change · **PASS**

The forecast is the only path touched, and its resolved iso is unchanged, so it
must come out identical (`r1_byte_identity.txt`, two binaries asserted to differ
first): `lattice_forecast.json` and `loadcase.json` both **IDENTICAL**. The
uniform branch was genuinely exercised (`cell_mode: uniform`, 602 region voxels),
so the check is not vacuous.

### A gate table where things should change · **N/A, and stated rather than skipped**

Nothing should change: the resolved iso is the same value the literals were. The
multiscale run above is the positive evidence that the *behaviour under test*
(shell at the printed iso) is real and exercised — 4,304 in-band voxels, 10,336
triangles against 6,884 at 0.5.

### Assertion-message census · **PASS**

Baselined on `1ac40d0` (this PR is the working tree against it). Test messages
3202 → 3224 with **none removed**; ctests 116 → 117 (`shell_iso_provenance`);
production refusals 397 → **398** (the new `exported_shell_for` guard), none
removed; comparison kinds up or flat in every bucket.

### No scratch at the repository root · **PASS**

---

## 4. WHAT I GOT WRONG, AND THE CHEAP THING THAT WOULD HAVE CAUGHT IT

I read `check_v3(grid, density, kIso)`, searched for `kIso`, found
`constexpr double kIso = 0.5` at the top of the file, and stopped. The shadowing
declaration is 246 lines below it with the *same name*. Nothing in the reading
was careless except the stopping.

**The cheap thing:** the fact was testable in about twenty lines —
`check_v3(f, d, a)` versus `marching_cubes(f, d, a)` for two values of `a` — and
no amount of re-reading would have been worth as much. That test now exists, and
its header says why.

A probe reconstructing `v3.mesh` from `design.bin` is **not** a substitute and is
deliberately not shipped: the export may be rotated onto a chosen build
direction, and my reconstruction did not reproduce the enclosed volume (40,638 vs
35,365 mm³) even though rotation preserves volume. The evidence file states that
caveat instead of hiding it; the controlled ctest is the load-bearing artifact.

---

## 5. IN PLAIN WORDS

**Nothing for you to do, and nothing was wrong with your files.**

I had flagged a possible problem: on a particular kind of run — the "multiscale"
mode, which you are not using — I thought the program might be cutting the outer
skin of the part at the wrong threshold, so the skin wouldn't actually contain
all the material.

**It doesn't. I was wrong, and I checked properly this time.** The program was
already using the right threshold. I'd misread the code: there are two variables
with the same name in the same file, about 250 lines apart, and I found the wrong
one.

I also ran the multiscale mode end to end to be sure the strut-protrusion check
from the earlier fix doesn't reject it. It doesn't — zero struts outside the
skin, out of 786,120 checked.

What I did fix is a small thing I introduced with the earlier task: a hardcoded
threshold and a comment stating the wrong explanation as fact. The comment is the
more important of the two — it is what caused this whole detour, and it would
have misled the next person the same way. There is now also a test that checks
the real behaviour directly, so nobody has to trust a reading of the code again.

**Your four latticed variants are unaffected by this one.** The re-export you
need is still only for the strut protrusion from the first task.