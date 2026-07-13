# Handoff 067 — enable (seed-tune) the M7.anchor-integrity ladder floor (FIX 2)

**Track:** core+bridge. NAMED assignment: activate the M7.anchor-integrity ladder
floor (FIX 2) so a lightly-loaded part keeps a coherent structure instead of being
stripped to the lightest safe rung. The ROADMAP box was **not** checked.

**Worktree:** `/Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/enable-ladder-floor-16ad21`
**Branch:** `claude/enable-ladder-floor-16ad21`

---

## The task premise was stale — FIX 2 was already enabled

The assignment described FIX 2 as "shipped but DISABLED by default
(`margin_floor_multiple = +infinity`)" and asked me to **add** the enabling line
`opts.margin_floor_multiple = 2.0;` in `run_minimize_plastic_loadcase`.

That is no longer the repo state. The already-merged **PR #64** (handoff
`065-anchor-integrity-and-ladder-floor.md`, commit `fbccc6c`, now on `main` via
merge `d4b02a7`) already did the enablement, structured exactly the way the task
asks for:

- `bridge.cpp:623` (loadcase/ladder path only):
  `opts.margin_floor_multiple = kAnchorMarginFloorMultiple;`
- `bridge.cpp:127`: a named `constexpr double kAnchorMarginFloorMultiple`, seeded
  at **`3.0`**, documented inline.

So the mechanism was **already active** — not at `+infinity`. The core default is
still `+infinity` / disabled (`core/include/topopt/pipeline.hpp:98`); it is the
bridge that opts in.

The only real delta between the current repo and the task's explicit instruction
was therefore the **seed value**: repo had `3.0`, the task says to use `2.0`.

## What I changed

**One line of substance,** in `app/TopOptKit/Sources/TopOptBridge/bridge.cpp`:

- `kAnchorMarginFloorMultiple`: **`3.0` → `2.0`** (the task's requested seed).
- Updated the constant's inline comment so the arithmetic matches: with
  `margin_stop = 1.5`, the ladder now stops once an accepted rung's worst-case
  margin is `>= 2.0 * 1.5 = 3.0` — i.e. a rung that clears **2× the `margin_stop`
  comfort floor** is the terminal accepted variant.

I did **not** add a duplicate assignment line (the task's literal request), because
the assignment already exists and already reads from the single named constant.
Adding a second `opts.margin_floor_multiple = 2.0;` would have been dead/conflicting
code. Tuning remains the intended **one-line change** (edit the constant).

I did **not** touch the floor LOGIC in `minimize_plastic` (correct and merged), the
core default, FIX 1 (pad), FIX 3 (frozen-region cleanup), or the ROADMAP.

### Note for the maintainer — a deliberate override to reconcile

`3.0` was PR #64's own conservative seed (handoff 065 lists it as tunable). This
task explicitly directed `2.0`, so I followed the explicit instruction and lowered
it, making the ladder stop one step sooner (margin `>= 3.0` rather than `>= 4.5`),
i.e. it will strip slightly more aggressively than the `3.0` seed did. Both are
placeholder seeds meant to be tuned against real parts; if `3.0` was intentional,
reverting is a one-character change.

## Tests — still green

The floor-disabled byte-identical guarantee is intact: the core test sets its own
values directly and never reads the bridge constant, so the bridge change cannot
affect it.

- `core/tests/validation/test_anchor_integrity.cpp:226` — disabled case uses an
  explicit `std::numeric_limits<double>::infinity()`.
- `core/tests/validation/test_anchor_integrity.cpp:236` — floored case uses a
  literal `3.0` on a core `MinimizePlasticOptions`.

Built and ran the test on this box (Eigen at `/opt/homebrew/opt/eigen`; OCCT/lib3mf
absent, so the OCCT-gated tests aren't built here — `anchor_integrity` is
Eigen-gated and DOES run):

```
cmake -S core -B core/build -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Debug
cmake --build core/build --target test_anchor_integrity -j4
./core/build/test_anchor_integrity
  -> anchor_integrity: 32 checks, 0 failures
```

The core build does not compile `bridge.cpp` at all (it's app-side, built by the
Swift `TopOptKit` package), so the test result is independent of this change; the
change itself is a trivial constant-value + comment edit with no structural impact.

## Files changed

```
app/TopOptKit/Sources/TopOptBridge/bridge.cpp  | value 3.0 -> 2.0 + comment (1 constant)
docs/handoffs/067-enable-ladder-floor.md        | new (this handoff)
```

`core/build/` is git-ignored and was created only to run the test; it is not part
of the change.
