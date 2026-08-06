# Strut line-width provenance — S1: where the 0.42 goes

Branch `claude/strut-line-width-provenance-s1-822be6`.
Evidence: `evidence/2026-08-05-strut-line-width-provenance/`.

**This stage changes no production file.** It is a diagnosis. There is no build
ritual and nothing to deploy; the one-line fix and the app work are S2's, and S2
is deliberately held (see §0.4).

---

## 0. What changes for the maintainer

### 0.1 The headline

**Your printer settings reached the solver intact. Your outer wall line width did
not.** When you send a job over the LAN, the CLI parses
`loads.wall_line_width_outer_mm: 0.42` correctly, validates it, stores it — and
then never copies it out of the parsed job into the load case the solver runs. The
value dies at one missing assignment,
[core/src/cli/run_job.cpp:3138](core/src/cli/run_job.cpp:3138). Everything
downstream then falls back to the documented "mirror the inner width" sentinel, so
the run computed with **0.45 mm** as the outer bead width and wrote 0.45 mm into
`run_info.json`.

So `run_info` is not lying about what the run used. It is telling the truth about
a value that had already been thrown away.

This is a **regression, not an oversight**. The line existed. PR #227 shipped it
on 2026-07-28 at 20:52 (commit `84a1350`), and the conflict resolution of a
`Merge branch 'main'` 71 minutes later (commit `fc6e95f`, PR #228) hoisted the
job→load-case block into a new helper and re-typed five of the six assignments,
dropping the sixth. Every run since — including both of yours, fingerprints
`2b8b715fd347` and `b3abcf880554` — ran a binary without it.

### 0.2 What it actually cost you, plainly

On your 2026-08-02 run (5 wall loops, outer **0.42 mm** sent / inner **0.45 mm**
sent):

| quantity | what the run used | what your settings say | delta |
|---|---|---|---|
| outer wall line width | **0.45 mm** | **0.42 mm** | +0.03 mm |
| wall-ring thickness `t` | 5 × 0.45 = **2.25 mm** | 0.42 + 4 × 0.45 = **2.22 mm** | +0.03 mm, +1.35 % |

And then the part that matters for trusting this week's numbers: **no margin, no
verdict, no mass and no recommendation moved.** `t` is read by exactly one piece
of arithmetic, `width_aware_knockdown()`, and only inside a `width_aware` branch;
the shipped posture is OFF (`kProductionWidthAwareKnockdown = false`,
[core/src/simp/production.cpp:183](core/src/simp/production.cpp:183)) and your
`run_info` records `width_aware_knockdown: false`. The gate-diagnosis wall-loops
lever reads `t` too, but in the width-blind posture it explicitly refuses to
recommend walls at all. So the corrupted number is the **provenance record**, not
the physics.

That still matters, for two reasons. First, the record is what this project reads
when it argues about your settings — anything quoted this week as "outer 0.45 mm"
or "t = 2.25 mm" off a `run_info` was quoting a number your device did not send.
Second, the day `kProductionWidthAwareKnockdown` is armed, this same drop starts
sizing the gate's wall ring 0.03 mm **thicker** than reality on a 0.42/0.45 job,
which credits the part with wall rescue it does not have.

### 0.3 What is *not* affected

- **On-device runs are correct.** The bridge writes the field straight onto the
  load case ([bridge.cpp:466-467](app/TopOptKit/Sources/TopOptBridge/bridge.cpp:466))
  and never goes through the broken helper. Only the job.json path — LAN worker
  and CLI — loses it. Same project, two front-ends, two different outer widths.
- **The lattice strut floor is on a different key.** `min_extrudable_width_mm`
  rides the `lattice` block and core does read it
  ([run_job.cpp:2158](core/src/cli/run_job.cpp:2158)), so a lattice run's strut
  printability floor was never corrupted by this drop.
- **Exactly one field is lost.** Every other member of `JobLoadCase` is copied;
  audited field by field in `F_blast_radius_and_s2_call_sites.txt` §F.1.

### 0.4 S2-S4 are held, on purpose

S2 (give the strut its own width field), S3 (the consumer cross-check) and S4
(the flip table) are **held pending PR 301 and PR 302**. S2 edits four files PR
301 is currently changing — `LatticePage.swift`, `AppModel.swift`,
`WorkspacePlaceholder.swift` and both runners — and S3 cross-checks against both
PRs' shipped behaviour. Starting S2 now would mean resolving the same class of
merge conflict that caused this bug in the first place.

**The four app call sites S2 needs** (all four pass the same
`project.printParams.wallLineWidthOuterMM` as the strut's `lineWidthMM`, so the
strut currently *is* the outer wall bead):

1. [LatticePage.swift:140](app/TopOptKit/Sources/TopOptFlows/LatticePage.swift:140)
   — `LatticeBounds.compute(...)`, the page's bounds and refusal text.
2. [LatticePage.swift:180](app/TopOptKit/Sources/TopOptFlows/LatticePage.swift:180)
   — the panel summary row.
3. [AppModel.swift:269](app/TopOptKit/Sources/TopOptFlows/AppModel.swift:269)
   — `project.lattice.runSpec(...)`. **This is the one that reaches the job and
   the bridge**; the other three are display.
4. [WorkspacePlaceholder.swift:2018](app/TopOptKit/Sources/TopOptFlows/WorkspacePlaceholder.swift:2018)
   — the workspace lattice summary.

It lands at `minExtrudableWidthMM:`
([LatticeSettings.swift:439](app/TopOptKit/Sources/TopOptFlows/LatticeSettings.swift:439)
and [:454](app/TopOptKit/Sources/TopOptFlows/LatticeSettings.swift:454)) and is
serialized by both runners —
[RemoteRunner.swift:709-712](app/TopOptKit/Sources/TopOptFlows/RemoteRunner.swift:709)
and [RelatticeRunner.swift:129-130](app/TopOptKit/Sources/TopOptFlows/RelatticeRunner.swift:129).
The wall widths this task is about are sent at
[RemoteRunner.swift:821-825](app/TopOptKit/Sources/TopOptFlows/RemoteRunner.swift:821)
(LAN) and [RunModel.swift:1033-1034](app/TopOptKit/Sources/TopOptFlows/RunModel.swift:1033)
(device).

---

## 1. R1 — no production file changed

```bash
git diff main -- core/src core/include app/TopOptKit/Sources
```

Empty. Captured with its output in
`evidence/2026-08-05-strut-line-width-provenance/R1_no_production_file_changed.txt`;
`git status --porcelain` shows only this task's evidence directory and this
handoff.

---

## 2. (a) Where `run_info.wall_line_width_outer_mm` gets its value

Full chain with quoted source in `A_provenance_chain.txt`. In short, on the
job.json path:

| step | file:line | what happens |
|---|---|---|
| 1. parse | [job.cpp:650-656](core/src/cli/job.cpp:650) | `0.42` is read into `job.loads.wall_line_width_outer_mm` and range-checked. Correct. |
| 2. transfer | [run_job.cpp:3137-3138](core/src/cli/run_job.cpp:3137) | `wall_loops` and the **inner** width are copied to `ProductionLoadCase`. The **outer** width is not. **The defect.** |
| 3. forward | [loadcase.cpp:495-496](core/src/cli/loadcase.cpp:495) | guarded on `> 0`, so the never-written `-1.0` declines to override; `MinimizePlasticOptions` keeps the mirror sentinel |
| 4. echo | [run_job.cpp:262-264](core/src/cli/run_job.cpp:262) | prints the **effective** outer width — which, with the sentinel intact, is the inner width, 0.45 mm |

`job.loads.wall_line_width_outer_mm` is read by **nothing** in the tree. It is
written by the parser and consumed by no one — the grep is in `A` §2.

So the answer to (a) is: **an echo, of a value the pipeline had already replaced
with a fallback.** The echo at step 4 is not the bug and should not be changed.

---

## 3. (b) What happens when a job omits the key — and does the app send it?

**The fallback is real and is the documented design.** Omitting
`wall_line_width_outer_mm` leaves it at `-1.0`, the "mirror inner" sentinel
([pipeline.hpp:432-436](core/include/topopt/pipeline.hpp:432)), which collapses
`t = outer + (loops-1)·inner` to the pre-split `t = loops·inner` byte for byte.
That is what `out_job_inner_only/run_info.json` shows in the 2026-07-28 evidence,
and it is correct behaviour.

**But that is not what is happening to his jobs.** `RemoteRunner` emits the key
**unconditionally** —
[RemoteRunner.swift:824-825](app/TopOptKit/Sources/TopOptFlows/RemoteRunner.swift:824),
no `if`, through a Double-identity mapping
([TopOptKit.swift:1436](app/TopOptKit/Sources/TopOptKit/TopOptKit.swift:1436))
seeded from `PrintParams.fdmDefault`, whose widths are outer **0.42 mm** / inner
**0.45 mm** ([PrintParams.swift:106-109](app/TopOptKit/Sources/TopOptFlows/PrintParams.swift:106)).
His own `job.json` carries `"wall_line_width_outer_mm": 0.42`. The hypothesis
that the fallback fires because the device omits the key is **refuted**: the key
is present, valid, and parsed. The fallback fires because the parsed value is
dropped one step later.

---

## 4. (c) The reproduction

Script: `evidence/2026-08-05-strut-line-width-provenance/C_reproduce.sh`.
Output: `C_reproduce.txt`. The three jobs are the **committed** fixtures from
`evidence/2026-07-28-line-width-plumbing/`, so today's `run_info` is directly
comparable with the `run_info` committed beside them (produced at `4fed171`,
before the deletion).

```bash
./evidence/2026-08-05-strut-line-width-provenance/C_reproduce.sh
```

```
cli built from: 90e9ec5
=== job_maintainer_defaults
  JOB SENT:
    "wall_line_width_mm": 0.45
    "wall_line_width_outer_mm": 0.42
  run_info.json GOT BACK (HEAD, 90e9ec5):
    "wall_loops": 5,
    "wall_line_width_mm": 0.45,
    "wall_line_width_outer_mm": 0.45,
    "wall_thickness_mm": 2.25,
  run_info.json COMMITTED 2026-07-28 (built at 4fed171, pre-drop):
    "wall_loops": 5,
    "wall_line_width_mm": 0.45,
    "wall_line_width_outer_mm": 0.42,
    "wall_thickness_mm": 2.22,
```

The **positive control** is `job_split`, and it is the one that proves this is a
mirror and not a hardcoded 0.45:

```
=== job_split
  JOB SENT:            inner 0.5, outer 0.4
  GOT BACK (HEAD):     inner 0.5, outer 0.5,  t = 2.5
  COMMITTED 2026-07-28: inner 0.5, outer 0.4,  t = 2.4
```

Sending outer **0.4 mm** with inner **0.5 mm** echoes **0.5 mm**. The fallback
tracks whatever the inner width is; 0.45 mm only appears everywhere because
0.45 mm is the app's inner default.

`job_inner_only` (outer omitted, inner **0.45 mm**) reproduces its committed
result exactly — outer **0.45 mm**, `t` = **2.25 mm** — because on that job the
fallback is the intended answer.

**Does the reproduction disagree with the repository evidence?** No. It agrees
with it *and* dates it: the 2026-07-28 evidence was honest when it was written
(commit `4fed171` still had the copy), and the same three jobs on the same three
fixtures now return the mirrored width. The disagreement between the two is the
regression, measured.

---

## 5. (d) Which width the derivations actually used on his run

Stated plainly, because this is the deliverable: **on his run every derivation
used 0.45 mm as the outer bead width, and the 0.42 mm he set was used by
nothing.**

Full analysis in `D_what_the_derivations_used.txt`. The consumer set is small and
complete:

- `knockdown_spec_for()` → `t` = **2.25 mm** instead of **2.22 mm** (outer
  **0.45 mm** instead of **0.42 mm**, inner **0.45 mm** in both). Recorded in
  `run_info`.
- `t` is consumed only by `width_aware_knockdown()`, only under
  `if (knockdown.width_aware)` ([analyze.cpp:326](core/src/simp/analyze.cpp:326),
  [gate_diagnosis.cpp:110](core/src/simp/gate_diagnosis.cpp:110)). His run
  records `width_aware_knockdown: false`, and the production constant is `false`.
- the gate-diagnosis wall-loops lever declines to recommend anything in the
  width-blind posture ([gate_diagnosis.cpp:423-431](core/src/simp/gate_diagnosis.cpp:423)).

Therefore: the wrong width was used, and the only number it produced —
`wall_thickness_mm` = **2.25 mm** at outer **0.45 mm** — never entered a margin,
a verdict, a mass or a recommendation. Nothing this project argued about this
week needs re-deriving. What needs correcting is the belief that `run_info`'s
0.45 mm reflected a device setting: it did not.

### 5.1 Which job produced that `run_info` — established, not assumed

`evidence/2026-08-03-preflight-feasibility-and-divergence/maintainer-job/` holds
four job variants. Identification in `E_which_job_produced_that_run_info.txt`:
`run_info` says resolution 128 (rules out `job_res64.json`), `has_design_box:
true` (rules out `job_growth_autobox.json`) and `ladder: [0.9]` with
`rungs=1` in `worker.log` — and at that run's own commit the ladder was
`minimize_plastic ? production_reduction_ladder() : {0.9}`, which rules out
`job_reduction.json`. That leaves **`job.json`**.

The conclusion does not rest on the identification: **all four variants send
outer 0.42 mm / inner 0.45 mm.**

The other fingerprint, `b3abcf880554` — the overnight lattice run quoted at
[run_job.cpp:5558](core/src/cli/run_job.cpp:5558) — is a different run on a
different commit (2026-08-04). Both fingerprints resolve to real commits and both
are downstream of the deletion, so both ran a binary that drops the outer width.

---

## 6. (e) Which of the three it is, in one sentence

**It is a substitution that silently discards what the job stated:** the outer
width is parsed and validated, then dropped at
[run_job.cpp:3138](core/src/cli/run_job.cpp:3138) before it can reach the solver,
after which the documented mirror-inner fallback fires on an absence the job did
not actually have.

---

## 7. Why no test caught it

Both tests that touch the split are green at HEAD, and neither crosses the
boundary the merge broke:

- [test_job.cpp:434-485](core/tests/unit/test_job.cpp:434) asserts the **parser**
  — step 1, which still works. `./build/test_job` → "all 177 checks passed".
- [test_production_parity.cpp:278-284](core/tests/validation/test_production_parity.cpp:278)
  asserts `knockdown_spec_for()` by setting
  `MinimizePlasticOptions::wall_line_width_outer_mm = 0.42` **directly on the
  struct**, which is precisely the "tests on the value type miss the call site"
  shape this repo has shipped defects on before.

The missing test is a job.json carrying an outer width driven **through**
`run_job`, asserting `run_info` echoes it. That is S2's, with the fix.

---

## 8. Blocked-stops — none hit

- The value's origin **was** traced to a line ([run_job.cpp:3138](core/src/cli/run_job.cpp:3138)).
- The reproduction **agrees** with the repository evidence once the evidence is
  dated to the commit that produced it (§4).
- Observing the answer required **no code change** — the drop is visible in the
  source, in the git history, and in a CLI run of committed fixtures.

---

## 9. In plain language — what was done, and what happens next

**What was asked.** Every job the app sends says the outer wall line width is
0.42 mm. Every run report says 0.45 mm. Find out why, without changing any code.

**What was found.** The 0.42 mm is read correctly, checked correctly, and then
simply not passed on. One line of code that used to hand it to the solver was
deleted on 2026-07-28 while merging two branches that both touched the same block
— one branch added the line, the other rewrote the block around it an hour later
and left it out. From that moment the solver has been told "no outer width given",
and it does the sensible thing for that case: it uses the inner width instead,
0.45 mm, and reports 0.45 mm honestly.

**Does it change any result you were given?** No. The only number that width
feeds is the thickness of the solid wall ring — 2.25 mm was recorded where 2.22 mm
was true, a difference of 0.03 mm — and that ring is only used by a strength
credit that is switched off in the shipped build. So no margin, verdict, weight or
recommendation is wrong because of this. What *is* wrong is the record: the run
reports say 0.45 mm, and it was never a setting you chose.

**Two more things worth knowing.** Runs on the iPad/Mac itself were never
affected — they take a different route into the solver that still carries the
0.42 mm. So the same project can produce two different outer widths depending on
whether you run it on the device or send it to the worker. And the lattice strut
thickness limit travels on a separate channel that works, so lattice runs were not
corrupted by this.

**What happens next.** The fix in the solver is one line, restoring what was
deleted, plus a test that sends a real job through and checks the report echoes
what was sent — that is stage 2, along with giving the lattice strut its own width
setting instead of quietly borrowing the outer wall's. Stages 2 to 4 are held
until PRs 301 and 302 land, because stage 2 edits four app files PR 301 is
changing right now, and merging into a moving branch is exactly what caused this
bug. The four places to change are listed in §0.4 so nobody has to find them
again.
