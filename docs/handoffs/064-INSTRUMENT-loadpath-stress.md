# 064 — INSTRUMENT: load-path & stress-display contradiction ("I bracket large")

**Type:** TEMPORARY diagnostic instrumentation only. No behavior/logic/math/BC/control-flow
changes. Every added source line is a `std::fprintf(stderr, ...)` (C++) or `NSLog` (Swift),
each tagged `// TEMP-INSTRUMENT` (or inline `TEMP-INSTRUMENT` in the string) so the whole set
greps out cleanly for removal.

**Worktree / branch:** `/home/user/TopOpt` on branch `claude/instrument-loadpath-stress-frov8p`
(the checkout was already the designated branch; all edits are on it).

---

## The contradiction we are resolving

On the confirmed `.step` model **"I bracket large"**, the maintainer observed two facts that
cannot both hold for one consistent model:

- At **150 lb** applied load, Optimize **FAILS** with "couldn't handle the load"
  (`allRejectedOnMargin` — the terminal/heaviest rung fails the margin gate).
- At **100 lb**, the **displayed stress map is near-uniform ~1 MPa** (≈3% of the ~40 MPa yield)
  across the whole part.

100 lb → ~1 MPa implies 150 lb → ~1.5 MPa, nowhere near yield — so it should NOT fail. The only
way both are true is if the **failure check** and the **displayed stress** are reading
**different loads / different solves**. The instrumentation below proves which.

### Prime suspect (what the code review flagged)

`run_minimize_plastic_loadcase` (bridge.cpp) builds `external` (nodal loads) from the user's
load groups. If `external` ends up **empty**, the core silently substitutes **self-weight**
(`minimize_plastic.cpp:138`). A near-uniform ~1 MPa field across the whole part is exactly what
self-weight-on-the-solid looks like — NOT a concentrated 100 lb point/face load. So the leading
hypothesis is: **the user's applied force never reaches `external`, the display shows self-weight
stress, and the "failure" at 150 lb comes from a different code path.** The logs confirm or
refute this directly.

---

## Logs added (what & where)

All C++ logs go to **stderr**; the Swift log uses **NSLog** (Console.app / Xcode console).
Grep tag for all of them: `TEMP-INSTRUMENT`.

### 1. `app/TopOptKit/Sources/TopOptFlows/RunModel.swift` (~line 348) — log #1
Right before the `if request.isStepModel` branch in `bridgeRunner`. Confirms the **.step
load-case path** is taken and dumps the **declared load case** as the app hands it off:
```
TEMP-INSTRUMENT [RunModel] isStepModel=<bool> anchorFaces=<n> loadGroups=<n>
TEMP-INSTRUMENT [RunModel] loadGroup[i] faces=<n> force=(x, y, z) |F|sum=<v>
```
> If `isStepModel=false`, the STL self-weight path runs and there is no user load at all.
> If `|F|sum` is already ~0 here, the load never left the app.

### 2. `app/TopOptKit/Sources/TopOptBridge/bridge.cpp` — the load-group loop in
`run_minimize_plastic_loadcase`

- **~line 492 (log #3, inside the loop):** per-group force + the zero-force skip test, then
  after face tagging the `any`/empty-group skip test + Load-voxel count:
  ```
  TEMP-INSTRUMENT [bridge] loadGroup[g] n_faces=<n> force=(x,y,z) |F|sum=<v> zeroForceSkip=<0|1>
  TEMP-INSTRUMENT [bridge] loadGroup[g] any=<0|1> loadVoxels=<n> emptyGroupSkip=<0|1>
  ```
  > Finds **which** group (if any) got dropped, and why — zero force, or no faces mapped to any
  > Load voxel (`any==false`).

- **~line 534 (log #2 — THE KEY LOG), after the loop, before the Dirichlet BC build:**
  ```
  TEMP-INSTRUMENT [bridge] external.size()=<n> sum|external.value|=<v> (total applied force to solver)
  ```
  > This is the force that actually reaches the solver. `external.size()==0` ⇒ core substitutes
  > self-weight ⇒ displayed stress is gravity, not the user's 100/150 lb.

- **~line 570 (log #4), after the Fixture→node clamp loop, before the min-x fallback:**
  ```
  TEMP-INSTRUMENT [bridge] any_fixture=<0|1> clampedNodes=<n> minXFallbackWillFire=<0|1>
  ```
  > Did the declared anchor actually freeze voxels, or did the min-x fallback fire (different BCs
  > than the user drew)?

Also added `#include <cstdio>` to bridge.cpp (tagged TEMP-INSTRUMENT).

### 3. `core/src/simp/minimize_plastic.cpp`

- **~line 144 (log #6), right after `loads` is chosen (external vs self-weight fallback):**
  ```
  TEMP-INSTRUMENT [core] external_loads.empty()=<0|1> selfWeightSubstituted=<0|1> loads.size()=<n> sum|loads.value|=<v>
  ```
  > Direct confirmation of the self-weight substitution (item #6) and the magnitude the ladder
  > actually solves.

- **~line 300 (log #5, part A), after the per-voxel stress loop:** the two peaks, same solve:
  ```
  TEMP-INSTRUMENT [core] rung=<r> vf=<v> failCheckPeakVM=<v> displayFieldPeakVM=<v> max_interlayer=<v> printedVoxels=<n>
  ```
  > `failCheckPeakVM` = `max_von_mises` (feeds the acceptance margin). `displayFieldPeakVM` =
  > peak of `variant.von_mises_field` (copied verbatim to the app for display). In the current
  > code both derive from the SAME `st.von_mises` loop — if they are equal every rung, the
  > failure-check and display use the same field, and the divergence must be upstream in the
  > LOAD (logs #2/#6), not in stress recovery.

- **~line 378 (log #5, part B), right after `variant.accepted` is set:** the acceptance decision
  that produces "couldn't handle the load":
  ```
  TEMP-INSTRUMENT [core] rung=<r> vf=<v> marginWorstCase=<v> infillKnockdown=<v> marginStop=<v> accepted=<0|1> maxStressMPa=<v> yieldMPa=<v>
  ```

Also added `#include <cstdio>` to minimize_plastic.cpp (tagged TEMP-INSTRUMENT).

---

## How to run & collect (maintainer)

Build and run the app as usual, open **"I bracket large"** (`.step`), set the same anchors/loads
you used before, and press **Optimize twice**: once at **100 lb**, once at **150 lb**. Capture
the console (Xcode debug console or `Console.app` filtered on `TEMP-INSTRUMENT`; the C++ stderr
lines and the Swift `NSLog` lines interleave in the same stream).

Paste **both runs** below. Keep them labeled 100 lb vs 150 lb.

### Log output — 100 lb run
```
<paste here>
```

### Log output — 150 lb run
```
<paste here>
```

---

## How to read the results (interpretation guide)

Compare across the two runs. The single fact that resolves the contradiction will be one of:

1. **`external.size()==0` in BOTH runs (log #2) + `selfWeightSubstituted=1` (log #6).**
   The applied load never reaches the solver in either case; the displayed ~1 MPa is self-weight.
   Then the 150-lb "failure" is NOT coming from the 150 lb load through this path — check whether
   the failure text at 150 lb even came from this run (e.g. a solver throw, a different code path,
   or a stale/again-empty run). This is the leading hypothesis.

2. **`external.size()>0` at 100 lb but `==0` (or much smaller) at 150 lb.**
   A group is being dropped only at 150 lb — read log #3 to see which group and why
   (`zeroForceSkip` vs `emptyGroupSkip`/`any==false`). The 150 lb value is failing to tag Load
   voxels (or arrives as zero force), so 150 lb falls back to self-weight or empties out.

3. **`external` populated and `sum|external.value|` scales ~1.5× from 100→150 lb (log #2/#6),
   AND `failCheckPeakVM != displayFieldPeakVM` (log #5A).**
   The failure check and the display read different peak stresses within the same run — a genuine
   two-fields bug. (Unlikely given both come from one loop today, but this log will catch it.)

4. **`any_fixture=0` / `minXFallbackWillFire=1` (log #4).**
   The declared anchor never froze; the min-x fallback clamps a different boundary than the user
   drew, so the whole stress picture is against BCs the user didn't intend. Check whether this
   differs between the two runs.

Also sanity-check `failCheckPeakVM` vs `maxStressMPa`/`yieldMPa` (log #5B): a ~1 MPa peak with a
~40 MPa yield gives a margin far above `marginStop`, so `accepted=1` — which is INCONSISTENT with
a "couldn't handle the load" failure on the same numbers. If the 150 lb run shows a small peak but
`accepted=0`, the acceptance math is seeing a different (larger) stress than the display — read
which of `marginWorstCase` / `maxStressMPa` is out of line.

**Deliverable of this run:** turn the 150-fails / 100-blue contradiction into ONE definite root
cause (which of 1–4 above), backed by the pasted numbers.

---

## Removal (when done)

Every added line carries `TEMP-INSTRUMENT`. To find them all:
```
grep -rn "TEMP-INSTRUMENT" core/src/simp/minimize_plastic.cpp \
  app/TopOptKit/Sources/TopOptBridge/bridge.cpp \
  app/TopOptKit/Sources/TopOptFlows/RunModel.swift
```
Delete those lines (and the two `#include <cstdio> // TEMP-INSTRUMENT` lines, and the small
`{ ... }` scope blocks / the `int tagged_load_voxels` recount loop introduced only for logging).
No other code depends on them; removing them restores the files byte-for-byte to pre-064 behavior.
