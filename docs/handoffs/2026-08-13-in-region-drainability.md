# in-region-drainability

Evidence: `evidence/2026-08-13-in-region-drainability/`. No production file
changed: `git diff origin/main -- core/src core/include app/` is empty.

---

## 0. THE ANSWERS

**1. What was `in_region` written for, and is the fix a second predicate or a
changed one? — A SECOND PREDICATE, and the original is correct.** `in_region` is
a **template parameter** (`plsm_topology.hpp:79-81`), not a hardcoded rule, so
there was never a rule to be wrong. All three callers
(`levelset_probe.cpp:3894`, `:3974`, `:3999`) pass the ACTIVE set and all three
want it: the optimiser does not own the frozen region and its component
bookkeeping is right to ignore it. **None was changed.**

★★ **2. And it was never shipped.** `plsm_topology.hpp` lives in
`core/tests/harness/`, is included by one file, and that target is
`EXCLUDE_FROM_ALL` (`core/CMakeLists.txt:1674`). **Production's own predicate,
`lattice_void_escape` (`core/src/mesh/lattice_void.cpp:67-79`, called from
`run_job.cpp:3496`), is CORRECT** — frozen material at density 1.0 ≥ iso
classifies `kSolid` and blocks escape. The 337 mm³ refusal was computed
correctly.

★ **3. The failing test demanded by R3 passed on the first run, and that is the
result.** One 7×7×7 fixture, one void voxel walled in on all six faces by frozen
material: optimiser predicate **0 (drainable)**, manufacturing predicate **1
(sealed)**. Both correct, to different questions. A failing-test bar met by a
test that passes first time is evidence the defect was misdiagnosed. **The real
defect is a LABELLING defect** — a column named `cavities` carrying the
optimiser's answer.

★★★ **4. The robust triple's sealed void does NOT re-derive to 14.85% — and the
cross-check found a real defect IN MY OWN SCRIPT.** 11,157.6 mm³ / 10.01%, not
16,552.9 / 14.85%. §3.

★ **5. A per-iteration MONITOR, not an in-loop constraint and not a post-hoc
gate.** It costs **0.0074 s — 0.026% of an iteration**. §4.

★★ **6. And the −27.6% light-rung gap still has no owner.** §5.

---

## 1. THE FIX

`levelset_probe.cpp` now computes both readings every iteration and emits three
columns beside `cavities`: `sealed_pockets_manuf`, `sealed_voxels_manuf`,
`sealed_mm3_manuf`. Live check: **66 (optimiser) against 416 (manufacturing)**,
48 header columns matching 48 row columns.

**The manufacturing predicate, unambiguously:** void 6-connected; escape to the
true part exterior **or to any grid face**; **frozen material counted as SOLID**,
because powder does not pass through a bolt boss.

★ **R1 — the added columns are proven inert by checksum, not by argument.**
`X_robust_recheck` re-ran `BS_robust` on the new binary with identical flags and
reproduced it **byte-for-byte** at it0020, it0060 and it0120.

## 2. R4 — EVERY CALLER, AND THE ANSWER IS "CHANGE NOTHING"

| call site | predicate | wants | changed |
|---|---|---|---|
| `levelset_probe.cpp:3894` | `in_active` | optimiser | no |
| `levelset_probe.cpp:3974` | `in_active` | optimiser | no |
| `levelset_probe.cpp:3999` | `in_active` | optimiser | no |

`in_region` at `external_field_surface_probe.cpp:301` is an unrelated mesh-region
selector sharing the name only.

## 3. ★★★ THE CROSS-CHECK FAILED, AND THE DEFECT WAS MINE

R2 asked for one arm re-derived through the new columns. It disagreed:

| | sealed voxels | sealed mm³ |
|---|---|---|
| `sealed_void.py` (primary) | 3,338 | 16,552.9 |
| new C++ columns | 2,250 | 11,157.6 |
| **delta** | **−1,088** | **−5,395.3 (−33%)** |

★ **ROOT CAUSE.** `sealed_void.py` defined 'exterior' as ONLY the
outside-the-part set. **That is wrong where the part touches the GRID BOUNDARY,
and 15,099 part voxels do.** A void voxel on the grid face is on the part's own
surface and is open to atmosphere.

★ **Both the harness and production already had it right.**
`core/src/mesh/lattice_void.cpp:128`: *"A component touching any face reaches the
exterior (everything outside the grid is exterior)."* **`sealed_void.py` was the
outlier.** Adding the grid-face term reproduces the C++ column exactly — 2,250 /
16 pockets.

★★ **So every sealed-void figure quoted on this branch was 33–49% too high.**
Recomputed for all 16 arms from snapshots already on disk, no re-runs:

| arm | v1 (wrong) | v2 (correct) |
|---|---|---|
| robust triple (shipped rung) | 16,552.9 / 14.85% | **11,157.6 / 10.01%** |
| perimeter C=1 (shipped rung) | 9,536.0 / 8.55% | **5,945.7 / 5.33%** |
| V0_none | 16,131.3 / 14.47% | 10,636.9 / 9.54% |
| V1_perim1 | 7,973.9 / 7.15% | 4,026.6 / 3.61% |

★ **THE ORDERING SURVIVES** — robust is still the worst on drainability — **so
the blocker on the robust triple STANDS.** Against the 337 mm³ refusal it is
**33×**, not 49×.

★ **One arm was the right call.** Twelve would have cost eleven hours and found
the same defect.

## 4. ★★ THE DRAINABILITY OPTIONS, PRICED

★ **The measurement that decides it: one drainability reading on a 128×31×118
grid costs 0.0074 s** — measured directly in
`test_plsm_topology_drainability` §5, five reps, nothing else in the process.
Against a ~28 s state solve that is **0.026% of an iteration**.

★ **Why it was measured directly and not by differencing.** Differencing the
cross-check run against the original gave **+26 s/iteration** — which would have
killed the cheapest option. The machine was under external load (`topopt-cli` at
96%, a `clang` compile at 99%, load average 8.59) and BOTH the solve and the
non-solve time rose by the same 1.9×. **A uniform slowdown across two unrelated
phases is the machine, not the code.** The honest number is 3,500× smaller than
the artefact.

| option | cost | verdict |
|---|---|---|
| (i) post-hoc, rung-gated | **88 min to a refusal** at the rung that matters | ✗ |
| (ii) in-loop differentiable constraint | a new aggregated measure, its adjoint, and a second constraint in an MMA that currently carries one | ✗ not yet |
| ★ (iii) **per-iteration MONITOR** | **0.0074 s, 0.026% of an iteration** | ★ **RECOMMENDED** |

★★ **I recommend (iii), and it makes (ii) unnecessary for now.** My earlier
belief — that trapped powder is a high-density problem so a post-hoc check
suffices — was **half right and the reviewer found the gap: the shipped rung IS
the high-density one.** Sealed void is 0.00–0.04% at the light rung and
3.5–10.0% at the shipped rung, so the problem bites exactly where the real parts
are, and (i) means running 88 minutes to be told no.

★ **A monitor does not need to be differentiable to be useful.** It needs to say
at iteration 10 that the run is heading for a refusal, not at minute 88. At
0.026% of an iteration it is free, it reuses the union-find already built, and it
requires no change to the MMA. **If a monitor turns out to be insufficient —
because knowing early is not the same as fixing it — (ii) is the fallback, and
the monitor's per-iteration series is exactly the data needed to design it.**

★ **Scoping only. None of the three is built in this branch.**

## 5. ★★ THE FINDING WITH NO OWNER

**Nothing clears SIMP at the light rung, including doing nothing.** The
unmodified control certifies at **2183 against SIMP's 3014.12 — −27.6%.** That is
a property of the parametric level set, not of any mechanism tested in four
tasks. It is the largest open number on this branch and **no task is assigned to
it.** Written into `PROPOSAL-1` §0 as well, so it stops depending on anyone
remembering.

## 6. THE PROBLEMS I HIT

**P1 — the brief's premise was wrong twice.** Declared and accepted. §0.

**P2 — ★ my own script was the buggy one.** §3. The cross-check the reviewer
insisted on is the only reason it was found, and he was right that a
disagreement would be worth more than agreement.

**P3 — ★ differencing two runs under different load nearly killed the right
recommendation.** §4. **Never price a mechanism by differencing wall-clock across
runs on a shared machine.**

**P4 — ★ I filtered a census report and lost its signal.** The R5 census
correctly printed `REMOVED: lattice_depth_tie`; my `grep -E '^[0-9]\.|REMOVED|…'`
matched the heading and dropped the indented name under it, so I read the bar as
clean when it was not. **The tool worked; my reading of it did not.** Third time
on this branch a filter has hidden the thing being checked.
★ The entry itself is benign — `origin/main` has moved **26 commits** since this
branch merged it and `lattice_depth_tie` arrived in one of them
(`12a8f91`, not an ancestor of HEAD). Nothing was deleted here.

**P5 — the operator stopped a revert-rebuild that would have discarded
uncommitted work.** Correct call; R1 was done by commit-then-diff instead.

## 7. BARS

| bar | state |
|---|---|
| R1 byte-identity | ★ PASS — three snapshots identical by checksum |
| R2 one-arm cross-check | ★ **FAILED and that is the finding** — §3 |
| R3 failing test first | ★ PASS — the test passes, which is the result |
| R4 callers enumerated | ★ PASS — three, none changed |
| R5 assertion census | PASS — no message, refusal or operator removed; one ctest delta explained in P4 |
| R6 no placeholders / no root scratch | PASS |
| R7 separate review-response commit | PASS — `df9cea0` |

## 8. IN PLAIN LANGUAGE

You asked me to fix a bug in the check that answers *"can trapped powder escape
from this part?"*

**The bug was real, but almost nothing about the framing was.** The code isn't
shipped — it's a test file used by one diagnostic that isn't normally built. The
real production check is correct. And the shared routine was never broken at all:
it asks you *what counts as inside the part* and answers correctly either way. I
wrote the failing test that was demanded and **it passed immediately**, which is
the finding. The only genuine fault was a **label** — a column answering the
optimiser's question under a name that read like the printer's. It now prints
both.

★★ **Then the cross-check caught something real, and it was mine.** Re-deriving
one number through the new code disagreed with my Python script by a third. The
script was wrong: it treated the edge of the computational box as if it were
sealed, when a hole at the edge of the part is open to the air. **Both the
production code and the test harness already had this right.** So every
trapped-powder figure I have quoted on this branch was **33–49% too high**. All
of them are corrected. **The conclusion does not change** — the recommended
method is still the worst of the group on trapped powder, and still needs a gate
— but the numbers do.

★ **And a near miss worth recording.** To price a per-iteration drainability
check I first compared two runs and got 26 seconds per step, which would have
ruled it out. Your machine was busy at the time, and *everything* in the run was
1.9× slower, including parts my change cannot touch. Measured properly the check
costs **0.0074 seconds — about a fortieth of a percent of a step.** That makes it
essentially free, and it is what I recommend: not a constraint the optimiser has
to obey, just a readout that says at step 10 that a run is heading for rejection,
instead of finding out 88 minutes later.

★ **One thing still has nobody's name on it.** At light weights the new method is
27.6% weaker than the old one **before any of our mechanisms are applied**. That
is about the method itself, it is the biggest unanswered number here, and I have
now raised it four times.
