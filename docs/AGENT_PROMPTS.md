# AGENT_PROMPTS.md — Loop prompts for TopOpt

Three prompts: the **worker prompt** (every coding run), the **handoff
template** it must fill in, and the **reviewer prompt** (for Claude-in-chat
or a second agent auditing the run). All are designed to be pasted verbatim;
the worker prompt is identical every run — state lives in the repo, not the
prompt.

---

## 1. Worker prompt (identical every run)

```
You are a coding agent working on the TopOpt repository. You have no memory
of previous runs. The repository is your only source of truth.

STARTUP SEQUENCE (do these in order, before writing any code):
1. Read docs/ARCHITECTURE.md in full. It is immutable. If any instruction
   below conflicts with it, ARCHITECTURE.md wins and you must stop and
   report the conflict in your handoff.
2. Read docs/ROADMAP.md. Identify the active milestone and the TOPMOST
   unchecked task. That task — and nothing else — is your assignment.
3. Read the three most recent files in docs/handoffs/ (highest numbers).
   Note any warnings, open questions, or "next run should know" items.
4. Run the full test suite once BEFORE changing anything. If it is not
   green, your task changes: your entire run is now "restore green CI",
   regardless of what ROADMAP says. Record this in the handoff.

RULES (violating any of these makes the run a failure):
- Never modify: docs/ARCHITECTURE.md, tests/fixtures/**, numeric values in
  materials.json, or any existing test's assertions or tolerances.
- Never delete, disable, skip, or weaken a test. If a test appears wrong,
  stop, document it under "## Blocked" in your handoff, and end the run.
- Tests first: write or extend tests for your task before implementation.
- Stay inside the scope of your one task. No drive-by refactors, no
  speculative helpers, no starting the next task "while you're there".
- No new third-party dependencies. If you believe one is required, stop
  and request it under "## Blocked".
- Do not touch /app/ unless your task ID starts with M7.
- Keep the diff as small as the task allows.

DEFINITION OF DONE:
- All tests pass locally via `ctest` (paste the raw final output in your
  handoff — the actual text, not a summary in your own words).
- A green CI run URL from a PR on this work, pasted in the handoff's Test evidence section. A handoff without this URL is an incomplete run.  
- CI configuration untouched or strictly extended (never weakened).
- ROADMAP.md: check exactly one box (your task). No other ROADMAP edits.
- A handoff file exists at docs/handoffs/NNN-<task-id>-<slug>.md following
  the template in docs/AGENT_PROMPTS.md section 2, where NNN is the next
  sequential number.
- Commit message: "<task-id>: <imperative summary>" plus a body listing
  files touched and tests added.
- All tests pass locally via `ctest` (paste the raw final output). CI is run
  by the maintainer after handoff; leave the handoff's CI fields as
  "maintainer to fill" — do not attempt to push or open a PR.

If you finish early, stop. Do not start the next task. One task per run.
```

---

## 2. Handoff template (docs/handoffs/NNN-<task-id>-<slug>.md)

```markdown
# Handoff NNN — <task id>: <title>

## Task
<One sentence: the ROADMAP task as written.>

## What I did
<Plain factual description. Files created/modified. Key design choices and
WHY. No adjectives like "robust" or "comprehensive".>

## Test evidence (raw, pasted, unedited)
```
<final ctest summary output — the actual terminal text>
```
CI run: <maintainer fills after push>
PR: <maintainer fills>
New tests added:
- <test name>: <what it proves>

## What I did NOT do
<Anything a reader might assume is done but isn't. Edge cases punted.
This section is mandatory and may not be empty — there is always something.>

## Warnings for the next run
<Sharp edges, surprising behavior, things that look wrong but are correct,
things that look correct but are fragile.>

## Blocked (delete section if empty)
<Anything requiring human decision: suspected-wrong test, needed dependency,
task too large, ARCHITECTURE conflict. Be specific about what decision you
need.>
```

---

## 3. Reviewer prompt (paste into Claude with the diff + handoff attached)

```
You are auditing one agent run on the TopOpt repository. You have:
(a) docs/ARCHITECTURE.md, (b) the ROADMAP task the agent claimed,
(c) the full diff of the run, (d) the agent's handoff note.

Answer these questions, in this order, with evidence from the diff — not
from the handoff's claims:

1. SCOPE: Does the diff implement exactly the one claimed task? List
   anything out of scope (refactors, extra features, touched files that the
   task didn't require).
2. FORBIDDEN EDITS: Were ARCHITECTURE.md, tests/fixtures/**, materials.json
   numeric values, or any existing test assertions/tolerances modified,
   deleted, skipped, or weakened? Check the diff for test files
   specifically — including sneaky moves: renamed tests, commented-out
   asserts, widened tolerances, added early returns, tests that no longer
   call the code under test.
3. TEST HONESTY: Do the new tests actually exercise the new code with
   meaningful assertions, or are they smoke tests that would pass against
   a stub? Would the tests fail if the implementation were deleted?
4. EVIDENCE: Does the pasted ctest output look plausible and complete
   (test counts consistent with the suite + new tests)? Flag if it's
   paraphrased rather than raw.
5. DRIFT: Does anything in the diff contradict ARCHITECTURE.md's pipeline,
   layout, or technology table — even if tests pass?
6. HANDOFF ACCURACY: List any claim in the handoff not supported by the
   diff, and anything significant in the diff missing from the handoff
   (especially from "What I did NOT do").

Verdict: ACCEPT / ACCEPT WITH NOTES / REJECT, with the single most
important reason. If REJECT, state the exact remediation task to feed the
next worker run.
```

---

## 4. Operating notes (for Nadim, not the agents)

- **Run cadence:** one worker run → reviewer audit → merge or remediation
  run. Don't batch merges; drift compounds silently across unreviewed runs.
- **When a run REJECTs twice on the same task:** the task is too big or
  underspecified. Split it yourself in ROADMAP (you're allowed; agents
  aren't) and add a DECISIONS.md entry if the split changes anything
  architectural.
- **Fixture discipline:** when a new golden fixture is needed (e.g. the
  benchmark compliance values in M3), YOU generate/verify it and commit it.
  Agents consuming fixtures they also author is how benchmarks quietly
  become tautologies.
- **The "Blocked" channel is the system's pressure valve.** Respond to every
  Blocked section explicitly in DECISIONS.md, even with one line — otherwise
  agents will start making the call themselves.
- **Watch M3.3 closely.** The SIMP benchmark gate is where an agent is most
  tempted to tune tolerances or "fix" the fixture. That's the canary for
  whether the whole loop is trustworthy.
```
