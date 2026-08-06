# Q3(c) — `simp.max_iterations` IS ACCEPTED AND SILENTLY IGNORED ON THE LOADCASE PATH

A named defect, found while trying to bound the R4 run. Not introduced by this branch
and not fixed by it. It is the same shape as the open item the maintainer already
carries — a control that exists, is accepted, and cannot act.

## The symptom

`r4_his_part.sh` states `"simp": {"max_iterations": 30}`. The run went past **iteration
210** on rung 0 of 3. The same key on the self-weight fixtures (`r1`, `r6`, `s3`) does
bind.

## The root cause, with file and line

`core/src/cli/run_job.cpp` — the mode branch:

```
5461:   if (job.loads.present) {          // LOADCASE mode
          …options = std::move(setup.options);   // from build_production_loadcase
5516:   } else {                          // self-weight mode
5549:     configure_production_options(options);
          …
5560:     if (job.simp_max_iterations > 0)
5561:       options.simp.max_iterations = job.simp_max_iterations;
5568:   }
```

**Lines 5560-5561 are inside the `else`.** A job with a `loads` block takes its options
from `build_production_loadcase` and `job.simp_max_iterations` is never read on that
path — the value is parsed, stored, and dropped.

The schema accepts the key unconditionally (`core/src/cli/job.cpp:715-721`), and unlike
`ladder` / `margin_stop` — which the loadcase branch **explicitly refuses** with a
message (`job.cpp:465-470`) — `simp.max_iterations` is neither refused nor honoured. A
user reading that refusal list reasonably concludes the keys NOT listed are honoured.

## Why the cap would not have been the whole story anyway

Even where `max_iterations` is read, it is not a single ceiling on a rung:

* **OC + a projection schedule** — `build_stage_plan` (`core/src/simp/simp.cpp:967-974`)
  builds one stage per `ProjectionStage` and takes each stage's cap from
  `ps.iterations`; `options.max_iterations` is not consulted on that branch at all.
  `heaviside_continuation_schedule()` (`simp.cpp:313-319`) is 6 stages × 50 =
  **300 iterations**, locked by benchmarks.
* **MMA + conditional projection** (handoff 123, armed by
  `production.cpp:556-570`) — a grayscale rung that converges gray is CONTINUED into
  β-projection *within the same rung*, and `max_iterations` is documented at
  `simp.cpp:963-966` as "the global safety cap that backstops the plateau-driven
  continuation" for that stage. So the rung total is the plateau phase plus the
  continuation phase, each backstopped separately.

So "how long is a rung" is bounded by a schedule, not by the number the job states —
and on the loadcase path the job's number is not even in play.

## The fix, not taken here

One line moves `5560-5561` above the branch, or into both arms. It is not taken in this
PR because this task changes the lattice cell law, and moving an iteration cap changes
the DESIGN on every loadcase run that states the key — a verdict-moving change that
needs its own before/after gate table. Filed here so it is not rediscovered.

**What a fix must also do:** either honour the key on the loadcase path or REFUSE it
there, the way `ladder` and `margin_stop` are refused. Accepting and ignoring is the
worst of the three.

## What it cost this task

R4's three-rung run could not be bounded, so it did not finish; §5.2 of the handoff
records exactly what that leaves unestablished.
