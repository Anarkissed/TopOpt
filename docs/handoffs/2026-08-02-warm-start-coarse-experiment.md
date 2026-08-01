# Does `warm_start_coarse` rescue the startup transient?

**Task:** `warm-start-coarse-experiment` · **Evidence:**
`evidence/2026-08-02-warm-start-coarse-experiment/`
**Kind:** EXPERIMENT. Measures a built-but-unreachable option, adds the plumbing
and instrumentation needed to measure it, and changes NO default. The gate is
untouched. No assertion was weakened or deleted.

*(Sections marked MEASURED carry numbers; the recommendation is at the end.)*

---

## 0. Why the option is off — the question the task asked first

**Both answers are true, and the second one is the load-bearing one:**

**(a) It was measured — on fixtures too small to be relevant, and the result was
marginal-to-negative.** Handoff 110 §Headline measured Part B alone (`warmB`) on
two fixtures of **≤ 1024 solid voxels**:

| fixture | cold iters | warmB iters | verdict 110 recorded |
| --- | ---: | ---: | --- |
| L-bracket loadcase (8×3×8) | 326 | 276 fine + 29 coarse = **305** | −6 % |
| self-weight block (16×8×8) | 460 | 438 fine + 59 coarse = **497** | **+8 % — a LOSS** |

110's own words: *"warmB alone is marginal, and on self-weight it raised the raw
iteration count… as an iteration count it is a wash-to-loss."*

**(b) It was NEVER ARMED, and could not be.** This is the fact that decides the
task. `MinimizePlasticOptions::warm_start_coarse` has **no writer anywhere in the
shipping tree**:

- `git log -S "warm_start_coarse = true" -- core/` returns exactly ONE commit —
  `b781531`, handoff 110's own commit, in its own tests.
- `core/src/cli/run_job.cpp` only ever *echoed* it (`info.warm_start_coarse =
  options.warm_start_coarse`, line 188) — it read a value nothing could set.
- `app/` contains no reference to it at all.
- By contrast Part A (`warm_start_inherit`) IS armed in production, at
  [`loadcase.cpp:275`](core/src/cli/loadcase.cpp:275) — `opts.warm_start_inherit =
  !external.empty()`, handoff 113's measured decision: **load-case runs warm,
  self-weight runs cold.**

So the task's premise that "`run_job.cpp:185` plumbs it" is **not correct**:
run_job *reported* it and never *set* it. The lever has been dark since it was
built. Handoff 110 said so and named the exact gap this task is meant to close:

> *"Part B on the design-box path is structurally supported but NOT measured…
> Both fixtures here are no-box load-case / self-weight runs. Measure a box run
> before relying on warmB there."*
> *"These numbers are a floor, not a ceiling, for production grids — but that too
> is unmeasured here."*

### Does 110's rejection still hold after PR 273?

**No — and the task is right to force the question.** 110 priced Part B in
ITERATIONS. On its fixtures multigrid was healthy, every iteration cost about the
same, and iterations ≈ cost, so that was a fair price. PR 273
(`2026-08-02-iteration-phase-timing`) proved that equivalence **fails exactly in
the regime this task targets**: on a stagnating iteration **87.9 % of the wall is
GenEO overhead the iteration counter cannot see**, and 3 of 65 iterations carried
80 % of a rung. A lever that removes 3 expensive iterations out of 65 scores
−4.6 % in 110's currency and −80 % in the maintainer's.

**So 110's number does not refute this task, and this task re-measures in wall
and in operator applies, not in iterations.** That is the whole reason the
experiment is worth running — and it is why §4's measurement reports both.

---

## 1. The structural finding, before any timing — `warm_start_coarse` can only
   ever rescue RUNG 0

Read at [`minimize_plastic.cpp:1104`](core/src/simp/minimize_plastic.cpp:1104):

```cpp
warm_seed = options.warm_start_inherit ? rho : std::vector<double>();
```

The cascade fills `warm_seed` once, before the ladder. After rung 0 converges,
that line either replaces it with rung 0's design (inherit ON) or **clears it**
(inherit OFF). With inherit off — which is what production does on a self-weight
run, by handoff 113's deliberate decision — **every rung ≥ 1 starts from uniform
grey in both postures.**

Two consequences the maintainer needs before reading any table:

1. **The comparison is a rung-0 comparison.** Rungs ≥ 1 should reproduce cold to
   the byte. §5 tests that rather than assuming it. (Edge case, named for
   honesty: if rung 0 ends INFEASIBLE or non-convergent, the branches at
   `minimize_plastic.cpp:1006`/`:1067` leave `warm_seed` untouched, so the coarse
   seed would carry into rung 1. That path is not exercised by these fixtures.)
2. **If the transient is per-rung, this lever addresses 1 rung of N.** The
   maintainer's run spent 57.7 of 72.2 minutes in the transient **of one rung**.
   A 4-rung ladder that restarts from grey each time pays that transient four
   times, and the cascade can only pay down the first. The lever sized against
   the whole problem is Part A (inherit), which is already armed for load-case
   runs and deliberately off for self-weight. **This is the single most important
   thing this task learned, and it is a property of the code, not of a
   measurement.**

---

## 2. What was built (measurement and reachability only — no default moved)

| change | why |
| --- | --- |
| `job.hpp` / `job.cpp` — optional **`"warm_start": { "coarse": bool }`** block | The option had no writer, so it could not be measured on the production path at all. Absent block => `has_warm_start` false => driver keeps its OFF default => byte-identical. Not a default change: a per-run arming switch. |
| `run_job.cpp` — maps the block onto `options.warm_start_coarse` | One line, guarded by `has_warm_start`, alongside the identical `draft` mapping. Explicitly does NOT touch `warm_start_inherit`, which keeps handoff 113's rule. |
| `pipeline.hpp` / `minimize_plastic.cpp` — **`warm_start_coarse_ms`** | AC3. The result carried the pre-solve's ITERATIONS but not its WALL, so its own cost could not be charged. Timed on the same steady clock as PR 273's phase instrument, spanning coarsen + solve + prolong, so no part of the price sits outside the span. |
| `pipeline.hpp` / `minimize_plastic.cpp` — **`warm_start_coarse_matvecs`** | The pre-solve's cost in the one unit a **contended host cannot change**. PR 273 named `matvecs` the honest work unit when `cg_iters` is not; it is also deterministic, which mattered enormously here (§3). |
| `observability.hpp` / `observability.cpp` / `run_job.cpp` — all three echoed into `run_info.json` | Config already said the posture was armed; nothing said what it charged. Filled post-run with the same finalize-only discipline as `cg_multigrid`. |
| `core/tests/unit/test_job.cpp` — `test_warm_start_block()` | Schema coverage for the new block: absent => off, armed, explicitly-off, and four rejections (non-boolean, missing key, unknown key, non-object). |
| `core/tests/harness/warm_start_coarse_gate.cpp` | The measurement harness. Standalone, not in CTest, a sibling of `ad_disarm_gate.cpp` whose fixtures, 1e-9 negative-control discipline and comparison quantities it reuses verbatim so the two tables read side by side. |

Nothing in `core/tests/fixtures/`, `materials.json`, `ARCHITECTURE.md` or
`DECISIONS.md` was touched. The gate is untouched. `geneo.cpp` and
`multigrid.cpp` — owned by the two coordinating tasks — were not edited.

---

## 3. MEASUREMENT CONDITIONS — read this before any wall number

*(filled in with the results)*

---

## 4. MEASURED — the transient, with and without

*(filled in with the results)*

---

## 5. MEASURED — the gate table and the negative-control floor

*(filled in with the results)*

---

## 6. Recommendation

*(filled in with the results)*
