# No dead-end workflows, and editing setup must not destroy results

Slug: `variant-entry-gating-and-retention` ·
Evidence: `evidence/2026-08-03-variant-entry-gating-and-retention/`

Scope: `app/` + bridge. No core solver file was touched. No fixture,
`materials.json`, `ARCHITECTURE.md` or `DECISIONS.md` was touched. No assertion
was weakened or deleted.

---

## 1. (C) root-caused — with a fourth finding that explains (A)

The brief was right to insist on a named cause. There is **no** path from a
design-box edit to `outcome = nil`; the reviewer's reading of `ProjectModel` was
correct. What actually happened is three separate defects, and the design box is
the *subject* of one of them, not the trigger.

### MECHANISM 0 — PR 274's retention never engaged, so (A) was guaranteed

`RelatticeArtifacts` (the retained job document + `design.bin`) was defined,
persisted by `ProjectStore`, cleared by `AppModel`, and read back on reopen. But
**nothing in the app ever produced one from a live run.** At HEAD the only
assignment to `ProjectModel.relatticeArtifacts` outside tests is
`AppModel.swift:980`, `pm.relatticeArtifacts = artifacts`, inside
`restoreFromDisk` — the *read-back* path. `RemoteRun` built the job document
(`RemoteRunner.swift:423`) and threw it away, and never fetched `design.bin` at
all, although the worker has served every file in `out/` since handoff 122
(`GET /jobs/{id}/files/{name}`).

So every run made in the app reported "kept no job document", forever. That is
why the maintainer reached the smoothing modal at all — it was not an unlucky
old run, it was **every** run.

Proven at HEAD:

```
HeadRetentionNeverProducedTests.testHEAD_NothingEverCapturesTheRetentionPairFromALiveRun
  XCTAssertTrue failed — Writers found: ["AppModel.swift: pm.relatticeArtifacts = artifacts"]
```

### MECHANISM 1 — the in-memory loss · `RunModel.swift:999` (and `:1293`)

`RunModel.start` cleared `outcome` unconditionally, and `finish`'s failure branch
cleared it again. Both had to: streamed variants are **appended** to `outcome`
(`appendStreamed`, `RunModel.swift:1119`), so leaving the previous run's list in
place would splice two ladders into one. But the consequence was that a run which
produced **nothing** — refused at core's pre-flight, thrown, cancelled before the
first variant — destroyed hours of finished work it never replaced.

That path is reachable in one tap from the lattice page: `onOptimize: { startRun() }`
(`WorkspacePlaceholder.swift:1688` at HEAD) starts the **whole ladder**, and core
refuses it up front when a design box is present —
`core/src/cli/run_job.cpp:2978`, *"lattice certification does not support a
design box (add-material) run"*, thrown **before any import, voxelize or solve**.
That is failure (B) and failure (C) being the same event: the maintainer's
lattice-page Optimize was refused in milliseconds, and his variants were already
gone.

Proven at HEAD:

```
HeadLossReproTests.testHEAD_ARefusedRunDestroysTheCompletedRunsVariants
  XCTAssertEqual failed: ("nil") is not equal to ("Optional(2)")
```

`outcome` is **nil** — not "one variant short", not "stale". Gone.

### MECHANISM 2 — the durable loss · `AppModel.swift:915` + `:968`

`ProjectModel.snapshot` writes `optimized: hasResults` (`ProjectModel.swift:1248`),
and `hasResults` is false for every moment the live run has no outcome. Any save
in that window — Home, or the system backgrounding the app — wrote
`optimized: false` over a project whose `results.plist` was **still on disk**, and
`restoreFromDisk` only reads that file when the flag is true
(`AppModel.swift:968`, `if snap.optimized == true`). The results survived; the
flag orphaned them, permanently and silently. This is the "**again**" in the
maintainer's report: after mechanism 1 emptied the session, the first navigation
Home made it survive a relaunch.

Proven at HEAD:

```
HeadLossReproTests.testHEAD_ASaveWithNoLiveOutcomeOrphansThePersistedResults
  XCTAssertEqual failed: ("Optional(false)") is not equal to ("Optional(true)")
```

### How the pre-fix failures were confirmed

`evidence/…/HeadLossReproTests.swift` is written against **HEAD's API only** — it
uses no type or method this change adds — and was compiled and run in a throwaway
`git worktree` at `7bd1b13`. All three tests fail there; the raw output is
`evidence/…/aj1_prefix_failures_at_HEAD.log`. The shipped suite
(`VariantRetentionTests`) asserts the same facts on the fixed tree, where they
pass.

**The design box did not cause the loss.** It is what made the Optimize
*refusable*, and the refusal is what caused the loss. Removing the box and
tapping Optimize again then started a run that *would* proceed — which nils the
outcome at `start` — so the maintainer's "removing it made them impossible to get
to" is a faithful description of what he saw from either direction.

---

## 2. What was built

### The gate — `VariantEntry.swift` (new)

One pure decision surface for both entries. `VariantEntryFacts` has **no**
initialiser reaching `ProjectModel`, `ForceModel`, `SelectionModel`,
`DesignBoxModel` or `LatticeSettings` — asserted by a comment-stripped source read
(`testTheGateCannotReachLiveProjectState`), the same structural shape PR 279's AE3
uses. Every fact comes from the run's own outcome, the retained job, or the
compute choice.

Every blocking precondition, each with its own sentence (a generic "not
available" is not a value this type can produce):

| Entry | Precondition | Read from |
|---|---|---|
| both | a job is already running | run phase |
| both | the rung produced no geometry | the variant's mesh |
| both | run solved **ON DEVICE** (bridge writes no job document / design) | the run's recorded machine |
| both | run **predates** job/design retention (PR 274) | the retained pair, absent |
| both | the model file is gone | the imported file |
| smooth | the retained job declared no load case (self-weight) | the retained job |
| smooth | the run generated a lattice (pipeline order) | the run's own lattice report |
| lattice | the run used a **design box** — core refuses it | the **retained** job's `design_box` key |
| lattice | the worker served no `design.bin` | the retained pair |
| lattice | the app **re-attached**, so it no longer holds the document it sent | the runner |
| lattice | no Mac worker selected | the compute choice |

The control renders in the lattice page's own shape: a **disabled** button with
the reason underneath (`ResultsScreen.entryControl`), and the openers
(`openSmoothingPage`, `openLatticePage`) refuse a blocked variant before touching
anything, so no other caller can open a dead end either. The smoothing page's
`gateOverlay` modal is now unreachable from the app's own routes and stays only as
the page's last-ditch statement.

### Failure (B) — the app no longer invites a job the core refuses

`LatticeCoreCapability.liveConflict(latticeEnabled:designBoxActive:)` is the one
rule, used by the workspace Optimize button (`canOptimize` / `optimizeSummary`)
**and** the lattice page's own (`LatticeOptimizeSurface.compute`). Both go dead
with core's reason instead of letting a page be configured and then refused.

It is explicitly a **mirror of core, not an app policy**:
`testTheAppBlockExistsBecauseTheCoreRefusalDoes` reads
`core/src/cli/run_job.cpp` and asserts the app's constant tracks the refusal
phrase. When the concurrent design-box-recertification task lands the capability,
**that test goes red** and `LatticeCoreCapability.designBoxRefused` is the one
line to change. The app can never end up the last one holding a rule the solver
dropped.

### Retention — the pair now exists, and moves with the results

* `RemoteRun` keeps the exact submitted job bytes and fetches `design.bin` over
  the existing `/files/` route (`fetchDesign`, beside `fetchFields`, with the same
  best-effort discipline and the same say-which-failure diagnostics). A run
  without it is still a complete run; its variants are simply honestly
  un-smoothable.
* The pair is reported to the **run**, not the project. `RunModel` owns
  `retainedArtifacts` and adopts a pending pair only if the run produced accepted
  variants; `ProjectModel.relatticeArtifacts` is now a passthrough. Held
  separately, the two drifted: a failed run restores the previous variants while a
  pair cleared on the project would leave those variants claiming to have kept no
  design.
* A **re-attach** deliberately reports no pair — the worker keeps `job.json`
  beside the run, not in the served `out/`, and a document rebuilt from the
  current request is the re-authored load case this whole path exists to avoid.
  It says so with its own reason.

### Retention — a run that produces nothing gives the results back

`RunModel.preservedOutcome` + `restorePreservedOutcome()`. `start` still clears
`outcome` (it must — streaming appends to it) but **moves** the completed run's
results aside; every terminal path that ends with no outcome of its own puts them
back, along with their retention pair. A run that produced accepted variants
releases the hold: that replacement is the user's own Optimize.

The stall path is the one exception and it is deliberate: `watchdogFired` does
**not** restore, because its sheet offers "Keep waiting" and the still-running
solve would append to the restored list. `dismissFailure` — where the stalled run
is actually abandoned — restores instead.

### The durable flag no longer orphans a live file

`AppModel.persist` never downgrades the snapshot's `optimized` flag below what is
actually on disk (`ProjectStore.hasPersistedResults`, a presence check that does
not decode the blob). The flag describes the durable record, not the live session.

### Bar 4 — invalidation is told and confirmed

Nothing else retires a finished run any more, so the single remaining path is a
new Optimize. It now names what it will cost first —
`ResultsReplacementPrompt.forNewRun` ("Optimizing again replaces the 3 variants
this project already has (lightest 41.2 g). They can't be brought back.") — and
the user confirms or keeps. With no results to lose there is no prompt and
Optimize behaves exactly as before. And when a failed run *gives* results back,
the workspace says so, so they never reappear unexplained.

### Provenance (AJ5)

`SolvingMachine` — `thisDevice` / `worker(name:)` / `unnamedWorker` — resolved
from two recorded facts (`computedRemotely` + a new `OptimizeOutcome.solvedBy`,
persisted through `OutcomeCodec`). It is stamped by the run flow at `finish`,
because neither the bridge nor the worker knows where it ran. Shown on the run bar
(icon + name) and on the selected variant card, with the full sentence as the
accessibility label. **Nothing is guessed**: a worker whose name was not recorded
reads "A Mac worker", never a name that might be the wrong one.

This is the fix for the specific insult in the report: the on-device refusal says
"re-run it on a Mac worker", and the chip beside it now says whether you already
did.

---

## 3. The bars

| Bar | Verdict | Evidence |
|---|---|---|
| **AJ1** (C) is root-caused | MET | §1; `aj1_prefix_failures_at_HEAD.log`; `VariantRetentionTests` |
| **AJ2** no reachable dead end | MET | `VariantEntryGatingTests` (11 conditions / 14 distinct reason sentences, each asserted, + both openers) |
| **AJ3** variants survive setup edits | MET | `testEveryVariantSurvivesEveryKindOfSetupEdit` |
| **AJ4** the retained job is used | MET | `testTheDesignBoxVerdictComesFromTheRetainedJobNotTheLiveSetup` + two structural tests |
| **AJ5** provenance shown | MET | `testTheMachineIsStampedOnTheOutcomeAndSurfacedOnRunAndVariant` |
| **AJ6** no regression | MET | `aj6_before_after.txt`, `aj6_prior_pr_suites.log` |
| **AJ7** determinism | MET | `aj7_determinism.log` |

### AJ1

Named cause, file and line, for all three mechanisms (§1). Each fails at HEAD
with the raw assertion text recorded, and passes on this tree. The reproduction
source is committed as evidence so the failure can be re-run at any commit.

### AJ2

`testEveryBlockingPreconditionDisablesSmoothingWithItsOwnReason` /
`…Lattice…` walk every precondition and assert, for each: the control is
**disabled**, it carries a reason, the reason contains that condition's
**distinctive** words, it is not the string "not available", and it is **unique**
across conditions (a `Set` insert, so two conditions collapsing onto one message
fails). `testEveryUnavailabilityReasonIsDistinctAndSpecific` does the same
exhaustively over both enums. `testBothPageOpenersRefuseABlockedVariantBeforeOpeningAnything`
asserts the pages are unreachable, not merely apologetic.

**The green path is asserted first and explicitly**
(`testAHealthyWorkerRunEnablesBothEntries`) — a wrongly disabled button is the
other failure the brief names, and it needed its own assertion, not an absence.

### AJ3

One test completes a run and then edits, **in turn**: adding a design box,
**removing** it, adding an anchor, changing it to a load, adding a second load
group, declaring a keep-clear, removing it, and changing material + resolution.
After each it asserts all variants present, both entries still enabled, and the
retained job **byte-identical**.

### AJ4

Both directions, because each failure is a different real bug: live box +
retained none ⇒ still latticeable (else a wrongly disabled button); live none +
retained box ⇒ still refused (the maintainer's exact sequence — removing the box
does not retroactively make a boxed run latticeable). Plus the structural half:
the gate's source cannot name a live-state type, and the workspace's fact builder
cannot reach `project.designBox` / `.force` / `.selection`.

### AJ6

```
BEFORE (branch HEAD, pre-change)
  TopOptFlowsTests: 1030 tests, 14 skipped, 8 failures (3 test cases)
  TopOptKitTests:     30 tests, 0 failures

AFTER
  TopOptFlowsTests: 1061 tests, 14 skipped, 8 failures (3 test cases)
  TopOptKitTests:     30 tests, 0 failures
```

The three failing cases are identical before and after —
`testThreeMFImport…`, `testThreeMFImportOptimisesOnDeviceEndToEnd`,
`testReopenedThreeMFProjectReimportsTheStlWorkingCopy` — the **pre-existing**
worktree lib3mf gap, unrelated to this task.

Named suites re-run together: PR 251's alignment tests, PR 274's
`LatticeVariantTests`, PR 279's `SmoothingPageTests` + `SmoothingModelTests`,
plus `RunModelTests`, `ProjectStoreTests`, `OutcomeStoreTests`,
`ResultsModelTests`, `LatticePageTests`, `StreamedVariantVisibilityTests` —
**236 tests, 1 skipped, 0 failures**.

### AJ7

The two new suites run three times: **31 verdicts, byte-identical across all
three repeats, 0 failures** (`aj7_determinism.log`). The gate itself is re-evaluated 20× per case inside
`testTheGateIsDeterministic`.

---

## 4. Scope honestly stated, and what was deliberately NOT done

* **Mechanism 0 was outside the brief and was closed anyway.** Had it been left,
  the gate this task ships would be correct and completely inert: every button
  disabled, forever, for every run. That is not what "no dead end" means. It is
  called out here rather than folded in quietly.
* **A re-attached run cannot have its variants smoothed or latticed.** The app no
  longer holds the document it submitted, and the worker does not serve `job.json`.
  It gets its **own** reason ("this app reconnected to the run after a restart, so
  it no longer has the job it sent") rather than borrowing the predates-retention
  sentence, which would be a false statement about that run. Making the worker serve the
  job document (or persisting it in `RemoteJobStore` at submit) is the obvious
  follow-up and was not done half-way.
* **On-device runs still cannot be smoothed or latticed** — PR 274's disclosed
  limit, unchanged. The bridge writes no job document and no design container.
  What changed is that the app now *says which one you ran* beside that sentence.
* **"No Mac worker selected" disables the Lattice entry.** This is a genuine
  blocking precondition (the certification solves run where the core runs), and it
  is checkable without entering the page, so per AJ2 it is gated rather than
  discovered late. It is also the most *recoverable* of the reasons, and the copy
  says exactly where to go.
* **Entering the lattice page on a blocked variant is now impossible**, including
  when the user only wanted to look. Nothing is lost: the workspace lattice entry
  (`openLatticePage(variantIndex: nil)`) is untouched and still opens the page for
  a from-scratch run.
* **An all-rejected new run still replaces a previous good run.** Its outcome is
  non-nil and carries real information (the rejected rungs the diagnosis UI needs),
  so it is not "a run that produced nothing". It now passes through the bar-4
  confirmation first, so it is never silent — but it is a real remaining edge and
  is stated rather than hidden.
* **The design-box chip does not itself warn when lattice mode is on.** The
  Optimize sub-line is the single source of that message. One place, not two that
  must be kept in step.

---

## 5. In plain language

**What went wrong, in the order you hit it.**

You tapped "Smooth" on a finished variant. The page opened, told you what
smoothing buys you, said it was working out which surfaces are protected, showed
your selections — and then a box appeared saying this variant can't be smoothed at
all. Everything behind that refusal was known before the page opened. Worse, it
told you to re-run the job on a Mac worker, and nothing on the screen said whether
you already had.

Then you set up the lattice page and pressed Optimize. The job came back refused —
a lattice can't be certified on a run that used a design box, because the strength
check can't be rebuilt on the enlarged grid. Fair enough. But the app had let you
build that whole configuration before telling you.

And here is the part that cost you the most. **That refusal took your finished
variants with it.** Pressing Optimize wiped the results *first* and asked the
solver *second*. The solver said no in a few milliseconds — nothing was imported,
nothing was solved — but the variants were already gone. Then the moment you went
back to the home screen, the app wrote down "this project has no results", even
though the results file was still sitting on disk untouched. From then on it would
never open it again. That is why they were gone for good, and why removing the
design box seemed to be the thing that did it: it was the moment you looked.

Underneath all of it was a quieter one. The previous change built the machinery to
keep, alongside each result, the exact job that produced it and the design the
optimizer converged on — the two things smoothing and latticing a variant need.
It saved them, loaded them and cleared them correctly. It just never *made* one.
So every run you have ever done reported that it kept nothing.

**What it does now.**

The buttons decide before you tap them. If a variant can't be smoothed or
latticed, the button is greyed out and says, in one line, exactly why — this run
was solved on your iPad; this run used a design box; this run finished before
results kept their design file; no Mac worker is selected. Eleven different
reasons, never a shrug. And you can't get into either page any other way, so
there's nothing to walk into.

Every run now says which machine solved it, on the run and on each variant. When
a message tells you to use a Mac worker, the chip next to it tells you whether you
did.

Finished results are no longer something a failed run can take. Starting a new run
sets the old ones aside rather than deleting them; if the new run produces
nothing — refused, crashed, cancelled — the old ones come straight back, with the
job that produced them, and the app tells you that's what happened. Editing your
setup, any of it, never touches them at all. The only thing that can retire a
finished run now is a new run that actually succeeds, and before that happens the
app tells you how many variants it's about to replace and waits for you to say
yes.

Lastly, the app now keeps the job and the design from every run on a Mac worker —
so the smoothing page and "Lattice this variant" work on the runs you make from
here on, instead of always refusing.
