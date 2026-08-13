# DEFECT — a comment says a safety check is OFF by default while it is ARMED

★ **Raised separately per the reviewer, with the two line numbers.** Not fixed
here: the task that found it changes no production file.

## The contradiction

`core/src/cli/run_job.cpp:3463`:

> *"Off by default: `require_lattice_void_reaches_exterior` is false unless the
> job asks, and then this whole block is skipped and nothing downstream sees a
> difference."*

`core/include/topopt/job.hpp:289`:

```cpp
bool require_lattice_void_reaches_exterior = true;
```

★ **The comment is inverted. The check is armed by default.**

## Confirmed by the running code, not only by reading

A `lattice-variant` run on 2026-08-13 refused with:

> *"THIS CHECK IS ON BY DEFAULT, so REMOVING the key does not turn it off; only
> an explicit false does."*

The refusal text and the declaration agree; **only the comment at
`run_job.cpp:3463` disagrees.**

## Why it is worth a change of its own

★ A reader debugging an unexpected refusal reads the comment nearest the code,
concludes the check cannot be running unless their job asked for it, and looks
somewhere else. **A comment claiming a safety check is off while it is armed
costs someone a day**, and the failure mode is silent — nothing tests a comment.

## The fix

One sentence at `run_job.cpp:3463`, inverted to match `job.hpp:289`: the check is
**on** by default, removing the key does not disable it, and only an explicit
`false` does — which is exactly what the refusal message already tells users.

★ **No behaviour change. No test change.** The declaration and the runtime
message are already correct and agree with each other.
