# 284 and 285's headline fixes do not work on device — why

Slug: `retention-and-designbox-device-failure`
Evidence: `evidence/2026-08-03-retention-designbox-device-failure/`

**The short version.** One of the two reported refusals is a real, reproduced
regression, and I have it cold. PR 285 removed the design-box lattice refusal from
**core**; the **app** carries its own copy of that refusal, PR 285 touched no app
file, and the copy was never removed. PR 284 had armed a tripwire test for exactly
this eventuality — and that tripwire has been **red on `main` since PR 285 merged**,
because CI has one job, `core-linux`, which has never built the app package. The
maintainer's build is correct; the binaries are correct; the app is simply the last
one holding a rule the solver dropped.

The retention half is **not** contradicted: on the maintainer's own run's artifacts,
retention worked and Smooth comes back available. Details and the one thing I could
not reproduce are in D4.

---

## D1 — Find the string

Both sentences are produced **in the app, live, at render time**. Neither is stored
with the run and neither comes back from the worker.

| Message | Produced by | Decided by |
|---|---|---|
| "this run used a design box — … the core refuses to lattice it" | `app/TopOptKit/Sources/TopOptFlows/LatticeVariantSession.swift:94` (`RelatticeUnavailable.designBoxRun.reason`) | `app/TopOptKit/Sources/TopOptFlows/VariantEntry.swift:184` |
| "this run finished before results kept their job document…" | `app/TopOptKit/Sources/TopOptFlows/SmoothingVariantSession.swift:190` (`SmoothUnavailable.noRetainedJob.reason`) | `SmoothingVariantSession.swift:299` via `VariantEntry.swift:157` |

Both are reached from one shared fact-set, `WorkspacePlaceholder.variantEntryFacts`
(`WorkspacePlaceholder.swift:1416`), evaluated every time the results screen draws.
Nothing is persisted and nothing is fetched.

The reviewer's search failed on the apostrophe because the source uses a typographic
`’`; the phrase also says "expanded **grid**", while the report says "expanded
**domain**". That second wording is not a transcription slip — it is **core's own**
refusal text, which the maintainer had seen hours earlier:

```
2026-08-01T19:34:41.526 stderr topopt-cli: lattice certification does not support
a design box (add-material) run: the certification load case cannot be
reconstructed under domain expansion. Run the lattice job without a design box.
```
(`evidence/…/core_refusal_2026-08-01T1934.log`, worker job `6ed5fba93c8240ad`.)

---

## D2 — Is the shipping binary the merged code? **Yes. Determined, not assumed.**

The maintainer was right both times. Do not ask him to rebuild.

The worker's CLI is `/Users/nadim/dev/TopOpt/TopOpt/core/build/topopt-cli` (named in
every `worker.log` launch line):

```
topopt-cli version=0.1.0 fingerprint=ce4e181a8535
-rwxr-xr-x  2197000  Aug  2 01:08   core/build/topopt-cli
strings hits for the removed refusal: 0
```

- `ce4e181a8535` is the merge commit `ce4e181` — **both PRs in**.
- Built 01:08, fifteen minutes before the 01:23 run.
- The binary **no longer contains** the string PR 285 deleted. PR 285's code is in
  the shipping worker.

**And the app binary is proven current too, without touching it.** `RemoteRunner`
refuses a worker whose `/health` fingerprint differs from the app's own baked
`CoreFingerprint` (`RemoteRunner.swift:433`, "worker core mismatch … Refusing to
run"). The 01:23 run **was accepted and ran to completion**, so the app's fingerprint
equalled `ce4e181a8535`. The shipping app is built from the merge commit, with PR
284's gate and PR 285's core.

**Can `build_core.sh` silently produce a mismatched worker?** No — and this is worth
stating precisely, because PR 204's failure mode is a real one.
`app/scripts/build_core.sh` builds only `libtopopt.a` slices into
`app/.build-core/` and vendors an xcframework; it does **not** build `topopt-cli` at
all (that is `build_cli_macos.sh`). So a "full rebuild" via `build_core.sh` does
leave the worker's CLI untouched. But it cannot do so *silently*: `build_core.sh`
writes `CoreFingerprint.generated.swift` from `git -C core rev-parse --short=12 HEAD`
using the identical derivation CMake bakes into the CLI, and a skewed pair is refused
**before** the run with a named error. The guard is already loud, and it demonstrably
fired nowhere on 01:23. **The build path is not the cause and needs no change.**

---

## D3 — Why did the bars pass? *(the important one)*

Two independent reasons, one per PR. Both are "the suite does not cover the shipping
path", and they compounded.

### 1. CI has never built the app. The tripwire fired into a void.

`.github/workflows/ci.yml` has exactly one job: `core-linux` — configure `core/`,
`cmake --build`, `ctest`. That is the whole of CI. `app/` is not built, not tested,
not linted, on any runner.

PR 284 **anticipated this exact regression** and wrote a source-reading tripwire
(`VariantEntryGatingTests.testTheAppBlockExistsBecauseTheCoreRefusalDoes`), with a
comment saying in terms: *"When the concurrent design-box-recertification task lands
the capability, that test goes red and this constant is what changes."*

PR 285 landed that capability three hours later. **The test did go red.** It has been
red on `main` ever since — I ran it unmodified at `ce4e181`:

```
VariantEntryGatingTests.swift:299: error: XCTAssertEqual failed:
  ("false") is not equal to ("true") - the app's design-box block must track
  core's own refusal.
```

PR 285 ran `ctest 97/97` in core. PR 284 ran the app suite locally
(`aj6_full_app_suite_after.log`). Neither PR could see the other's suite, and the one
that gates merges cannot see the app at all. The cross-language mirror had a tripwire
and no wire.

### 2. Every gate test built its own job. None used a real one.

`VariantEntryGatingTests.job(designBox:)` hand-assembles a four-key dictionary
(`model`, `material`, `resolution`, `loads`). `SmoothRecertLoadCase.fromRetainedJob`
and `RetainedJobFacts.parse` were only ever asked about **that** document — never
about the ~1.4 KB document `RemoteRunner.buildJobJSON()` actually submits, with its
`design_box`, `clearances`, `wall_line_width_*`, `bake_build_orientation`,
`build_orientation_report`. The suite proved the gate's arithmetic and never once
proved the gate's **verdict on a document a real run produced**.

### 3. A third defect that only this question would have surfaced

`VariantEntry.latticeBlocks` appended `.designBoxRun` **unconditionally**
(`VariantEntry.swift:182–185`). It never read `LatticeCoreCapability.designBoxRefused`
— the very constant whose documentation says "drop this when core stops refusing".
So the documented remedy was **inert**: flipping it would have changed nothing a user
could see. A mirror that does not consult its own switch is not a mirror.

---

## D4 — Retention, end to end, on the real path

Every hop, traced against the maintainer's own run (worker job
`b56bbf4421f34212`, WallMount_ShelfBracket, submitted 01:23, finished 01:32):

| # | Hop | Code | Verdict on this run |
|---|---|---|---|
| 1 | app builds the job | `RemoteRunner.buildJobJSON()` :608 | ✅ 1442 bytes, valid |
| 2 | app keeps its half | `submittedJobJSON = jobJSON` :444 | ✅ on the fresh-submit branch |
| 3 | app → worker | `postJob` :1101 | ✅ job accepted |
| 4 | worker → topopt-cli | `topopt_worker.py:813` | ✅ `job.json` on disk, byte-identical shape |
| 5 | CLI writes the design | `out/design.bin` | ✅ **1 573 112 bytes, 01:32** |
| 6 | worker serves it | `_file()` :921 (serves any file in `out/`) | ✅ no allowlist to fall foul of |
| 7 | app fetches it | `fetchDesign()` :984 | ✅ path `jobs/{id}/files/design.bin` resolves |
| 8 | app pairs them | `onArtifacts?(...)` :1381 | ✅ both halves present |
| 9 | callback → run | `WorkspacePlaceholder.swift:666` → `RunModel.noteRetainedArtifacts` :880 | ✅ single dispatch site, correctly wired |
| 10 | adopt on success | `RunModel.adoptPendingArtifacts` :1289 | ✅ |
| 11 | persist | `AppModel.swift:957` → `ProjectStore.saveRelatticeArtifacts` :164 | ✅ |
| 12 | read back | `variantEntryFacts` :1419 → `project.relatticeArtifacts` (forwards to `run.retainedArtifacts`) | ✅ |

**No hop drops it.** PR 284's capture fix is present in the shipping binary and, on
this run, had everything it needed.

Two independent confirmations that retention actually engaged:

1. **The lattice message itself proves it.** `.designBoxRun` is only reachable from
   the `else if` branch at `VariantEntry.swift:182`, i.e. **only when
   `artifacts != nil`**. The refusal the maintainer read is itself evidence that both
   halves of the retention pair were in hand. Had the pair been missing he would have
   seen `.runPredatesDesignStore` instead.
2. **The retained document is complete.** Fed his run's actual `job.json` to the real
   parser: material `PLA`, resolution 64, anchors `[8, 14, 12]`, one load group, three
   keep-clear bores — and `VariantEntry.smoothing` returns **enabled**
   (`DeviceRunEntryGateTests.testSmoothIsAvailableOnTheDeviceRun`, passing).

### What I could not reproduce, stated plainly

**The Smooth refusal does not follow from that run's artifacts.** With the pair
present, Smooth is available; with the pair absent, Lattice would have said
"…kept their design file", not the design-box sentence. The two reported messages
cannot both come from that one run's facts.

The likeliest reading is that the two sentences were noted at different moments of a
long evening — there were three WallMount runs (18:41 ok, 19:34 **refused by core**,
01:23 ok), and the 19:34 refusal is where the "domain expansion" wording came from.
I have **not** changed any code on that hypothesis (D7). The exact iPad container
that would settle it is not reachable from this Mac — the Mac's app store has no
WallMount project.

**One named finding on the Smooth side, not acted on.** `VariantEntry.swift:159`
feeds the smoothing gate `f.artifacts?.jobJSON`, which is **all-or-nothing with
`design.bin`** (`VariantEntryFacts.artifacts`, :99). Smoothing needs only the job
document. So if `design.bin` ever fails to fetch, Smooth is refused with a sentence
blaming the **job document** — which was kept. That message would be false, and it is
the only mechanism that produces the reported Smooth sentence on a worker run. It is
a one-line change, but nothing in the evidence says it fired here, so per D7 I have
left it alone and flagged it for your call.

---

## D5 — The design-box refusal, end to end

**It is the app. D1 answers it.** It never reaches the worker or core.

```
run.outcome ─┐
             ├─► variantEntryFacts        WorkspacePlaceholder.swift:1416
project ─────┘      retainedJob = the run's own job.json
                        │
                        ▼
                RetainedJobFacts.parse    VariantEntry.swift:51
                        │  job["design_box"] is [String: Any]  →  true
                        ▼
                VariantEntry.latticeBlocks  :184   out.append(.designBoxRun)
                        ▼
                LatticeVariantSession.swift:94  → the greyed button's sentence
```

The gate is right to read the box from the retained job rather than live state
(that is PR 284's bar AJ4, and it stands). What was wrong is the **verdict**: it
mirrored a core rule that PR 285 deleted.

Core's remaining rule is much narrower and is about **grading**, not the design box —
`run_job.cpp:2805` (`lattice_variant_job`) and `run_job.cpp:3428` (the run_job
pre-flight), both throwing only when `job.grading.present && job.has_design_box`.
**Uniform lattice under a design box is supported and tested** — that is exactly what
PR 285 built.

### The change

| File | Change |
|---|---|
| `VariantEntry.swift` | `designBoxRefused` → `false`; gate at :182 now **consults** it; `liveConflict` narrowed to *graded* + box, with `graded` a **required** parameter so no caller can inherit the wrong answer silently |
| `LatticePageModel.swift:244` | passes `graded: densityMode == .auto` |
| `WorkspacePlaceholder.swift:4537` | passes `graded: project.lattice.densityMode == .auto` |

Net effect for the maintainer: a design-box run's variants can be latticed; a
*graded* lattice with a design box is still refused **before** submission, now
quoting the rule core actually has.

---

## D6 — Tests that would have caught this

**Two, at both levels. Each verified to fail against the broken state.**

### 1. `core/tests/unit/test_app_core_capability_mirror.cpp` — in the CI that gates merges

A core-side test that reads `core/src/cli/run_job.cpp` **and**
`app/…/VariantEntry.swift` and fails when the mirror disagrees. Pure text over two
files: no OCCT, no Eigen, no Swift toolchain, so it runs on the **existing Linux
runner** — the gap that let this through. Registered as ctest
`app_core_capability_mirror`.

Confirmed by running it against a clean `git archive` of the merged commit `ce4e181`:

```
=== against the MERGED BROKEN state (ce4e181) ===
FAIL (line 81): LatticeCoreCapability.designBoxRefused disagrees with run_job.cpp…
FAIL (line 101): the grading-with-a-design-box refusal and the app's live conflict disagree…
FAIL (line 109): the app refuses a design-box lattice that core certifies — this is
                 the exact regression of 2026-08-02…
app/core mirror: 4 checks, 3 FAILURES        exit=1

=== against this branch ===
app/core mirror: 4 checks, 0 failures        exit=0
```

**This would have failed PR 285 at merge time.**

### 2. `app/…/Tests/TopOptFlowsTests/DeviceRunEntryGateTests.swift` — the real document

Gates on the maintainer's **actual** job document
(`evidence/…/device_run_job.json`, byte-for-byte from worker job
`b56bbf4421f34212`). Nothing in it constructs a job. Against unmodified `ce4e181` it
reproduces his sentence verbatim:

```
DeviceRunEntryGateTests.swift:100: error: XCTAssertTrue failed - Lattice is blocked
on a design-box run: this run used a design box — the certification load case can't
be rebuilt on the expanded grid, so the core refuses to lattice it. Re-run it
without a design box to lattice its variants
```

PR 284's own tripwire is also repaired rather than deleted
(`testTheAppBlockTracksTheCoreRefusalInBothDirections`) — it now pins core's state
from **both** sides, so a revert in either direction is loud.

### Results

- `DeviceRunEntryGateTests` 4/4, `VariantEntryGatingTests` 16/16,
  `VariantRetentionTests` 15/15.
- Full app package: only the three pre-existing 3MF tests fail, because
  `build_core.sh` in this worktree reported `lib3mf: (none) — macOS slice is
  3MF-free`. Known worktree provisioning gap; untouched by this task.
- Core: **99/99, 100% passed** (1263 s), with `Test #17: app_core_capability_mirror`
  inside that run — full log excerpt in `evidence/…/app_suite_before_after.txt`.

---

## D7 — No speculative fixes

Every line changed is downstream of a cause named with file and line in D1/D3/D5 and
reproduced by a test that fails against the broken state. The one thing I suspect but
cannot prove — the Smooth/`design.bin` coupling at `VariantEntry.swift:159` — is
**reported and left alone**.

---

## The one thing I'd ask you to decide

**Should CI build the app package?** Right now nothing in `app/` gates a PR, and this
is the second consecutive PR pair where that mattered. The mirror test closes the
specific hole for cross-language *refusal* constants at zero cost, but it cannot
cover app logic in general. A macOS runner needs Homebrew OCCT + Eigen and is
materially slower and more expensive than the Linux job — that is a cost call, and
yours, so I have not made it.

---

## In plain language

You set a design box, ran the bracket on the Mac, and both buttons were greyed out.
You were right that it wasn't your rebuild.

**The Lattice button.** There are two copies of the "you can't lattice a design-box
run" rule: one in the solver, one in the app so the button can grey itself out with a
reason instead of letting you submit a job that comes back refused. PR 285 removed
the solver's copy — that was the whole point of it. It never touched the app, so the
app's copy is still there, still telling you "the core refuses to lattice it" about a
core that, in that very same build, does it happily. The app was the last one holding
a rule the solver had already dropped. That's fixed: your design-box runs can be
latticed now. A *graded* lattice with a design box is still refused, because the
solver genuinely still refuses that one — but now the app says so in the solver's own
words, before you submit, instead of after.

**The embarrassing part.** PR 284 saw this coming. It left behind a test whose entire
job was to go off the moment the solver dropped that rule. The solver dropped it three
hours later and the test went off exactly as designed — and nobody heard it, because
our CI runs one thing: build the solver on Linux and run the solver's tests. It has
never built the app. So every app test we've ever written, including that alarm, has
been sitting outside the room. That's why both PRs were green and both were wrong: the
green was real, it just wasn't measuring the thing that broke. I've moved the alarm
into the solver's own test suite, where CI will actually hear it — and I checked that
it does go off against the exact broken commit.

**The Smooth button.** Here the news is better than it looks. Retention *worked*. I
found your actual run on the Mac — the job document and the 1.5 MB design file are
both sitting on disk, complete, and I fed that real document through the real code:
Smooth comes back available. In fact the Lattice message you saw is itself proof
retention worked, because that particular sentence can only appear when both retained
pieces are in hand. So I can't make the two messages you reported come from the same
run — my best guess is they were noted at different points in the evening (there were
three runs, and one of them, at 19:34, was refused by the solver with the "domain
expansion" wording you quoted). I did not invent a fix for something I couldn't
reproduce. I did find one genuine weak spot nearby: if the design file ever fails to
download, the Smooth button blames the *job document* instead, which would be a lie —
one line to fix, but nothing says it happened to you, so I've left it for you to call.

**Your build was fine.** I checked the actual binaries rather than taking anyone's
word: the worker's solver was rebuilt at 01:08, fifteen minutes before your run, from
the merge commit, and the deleted text is genuinely gone from it. And because the app
refuses to talk to a worker built from a different commit — and your run went through
— the app was built from that same commit too. Both PRs really were in your hands.
The app just wasn't listening to them.
