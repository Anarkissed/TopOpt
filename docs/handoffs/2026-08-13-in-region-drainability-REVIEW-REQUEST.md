# REVIEW REQUEST — `in-region-drainability`: §1 complete, and the brief's premise is wrong in a way that shrinks the task

★ **Declaring an override before going further.** Nothing is committed yet.

---

## 0. THE OVERRIDE

★★ **The brief says "a correctness defect in a SHIPPED predicate" and "★PRODUCTION.
Touches core/. CI: core-linux + app-macos." Both are false. Neither the fix nor
the finding touches production.**

### (1) The predicate is not shipped

`core/tests/harness/plsm_topology.hpp` is included by exactly one file —
`core/tests/harness/levelset_probe.cpp` — and that target is `EXCLUDE_FROM_ALL`
(`core/CMakeLists.txt:1674`). Nothing in `core/src`, `core/include` or `app/`
includes it. There is precedent for exactly this shape: `test_lattice_material_model`
carries the comment *"nothing in production consumes it"*.

### (2) Production's own drainability predicate is CORRECT

`lattice_void_escape` (`core/src/mesh/lattice_void.cpp:67-79`, called from
`core/src/cli/run_job.cpp:3496`) classifies `density[e] >= iso` as `kSolid`, and
the escape network is `cls != kSolid`. **Frozen material is printed, so its
density is 1.0 ≥ iso and it correctly blocks escape.** The 337 mm³ refusal was
computed correctly.

### (3) ★★ And `void_topology` has no defect either — the part that surprised me

`in_region` is a **template parameter**, not a hardcoded rule
(`plsm_topology.hpp:79-81`). The function is correct for whichever predicate it
is given. R3 asked for a failing test first; **I wrote it and it passed on the
first run**, which is the actual result:

| one 7×7×7 fixture — one void voxel walled in on all six faces by frozen material | `cavities` |
|---|---|
| optimiser predicate (`tags != Empty && eff == Active`) | **0 — drainable** |
| manufacturing predicate (whole part, frozen counts as solid) | **1 — sealed** |

Both answers are correct. They answer **different questions**.

★ **So the real defect is narrower than the brief assumes:** `levelset_probe.cpp`
computed only the optimiser reading and emitted it in a column named `cavities`,
which reads as a manufacturing claim. **That is what misled me** — I reported
5 / 0 / 2 cavities, then had to correct to 51 / 21 / 32.

---

## 1. R4 — EVERY CALLER ENUMERATED, AND ALL THREE WANT THE OPTIMISER DEFINITION

| call site | predicate passed | which definition it wants | changed? |
|---|---|---|---|
| `levelset_probe.cpp:3894` | `in_active` | optimiser | **no** |
| `levelset_probe.cpp:3974` | `in_active` | optimiser | **no** |
| `levelset_probe.cpp:3999` | `in_active` | optimiser | **no** |

All three sit inside the monotone/topology block. The optimiser genuinely does
not own the frozen set and its component bookkeeping is right to ignore it.
**Changing them would be the regression R4 warns about.**

★ Note also `in_region` in `core/tests/harness/external_field_surface_probe.cpp:301`
— an unrelated mesh-region selector that shares the name only.

## 2. THE FIX — A SECOND PREDICATE, NOT A CHANGED ONE

Exactly as the brief's 1(a) anticipated. `levelset_probe.cpp` now computes both
readings and emits three new columns beside the existing `cavities`:

    sealed_pockets_manuf, sealed_voxels_manuf, sealed_mm3_manuf

Verified on a live run: **66 (optimiser) against 416 (manufacturing)**, header 48
columns = row 48 columns.

The manufacturing predicate, stated unambiguously per 1(c): **void 6-connected,
escape to the TRUE PART EXTERIOR, frozen material counted as SOLID** because
powder does not pass through a bolt boss.

## 3. ★★ R2 IS A NO-OP — THE NUMBERS WERE NEVER WRONG

The brief's 1(d) asks for every Stage A/B arm's sealed void to be re-measured
under the corrected predicate, on the grounds that the robust triple's 14.85% and
the penalty's 8.55% depend on it.

★ **They do not.** `sealed_void.py` already implements the manufacturing
definition — its docstring states it explicitly and contrasts it with
`plsm_topology.hpp`'s. **The robust triple's 14.85% / 16,553 mm³ and the
penalty's 8.55% / 7,974 mm³ stand unchanged**, and the drainability argument
behind the robust-triple recommendation is unaffected.

**The bad reading only ever appeared in the harness's `cavities` column, which
nothing downstream consumed.**

---

## 4. WHAT IS OUTSTANDING

Nothing is committed yet.

| item | state |
|---|---|
| **R1** design byte-identity | ★ **not proven.** I began a revert-rebuild-compare and the operator stopped it — correctly, since it discards uncommitted work for the duration. I will commit first and diff against the prior commit instead. The change is inert by construction (writes only to CSV, never touches `alpha`/`phi`/`occ`), but "obviously fine" has been wrong repeatedly on this branch, so it still gets the checksum. |
| **R5** assertion census | not yet run for this task |
| **§2** drainability scoping | not started |
| **§3** Proposal 1 rewrite | not started |

---

## 5. THE DECISIONS I NEED

**1. Do you accept the override?** If this is harness-only, the CI framing
(core-linux + app-macos) and the PRODUCTION label do not apply, and the task
reduces to documentation plus one diagnostic column set.

**2. Do you accept that R2 is satisfied by showing the numbers never used the bad
predicate**, rather than by re-measuring? I can re-derive them through the new
harness columns as an independent cross-check if you want belt-and-braces — that
costs a re-run of all 12 arms, **~11 hours**, for numbers I expect to match.

**3. Proceed to §2 and §3?** §3 is documentation and can be done now; §2 is
scoping only.

★ **My belief on 2(c), stated ahead of the work rather than slipped in as an
aside:** sealed void essentially **vanishes at the light rung** — 0.01–0.07%
against 8.55–14.85% at the shipped rung. **Trapped powder is a high-density
problem.** If the parts that matter are light, a rung-gated post-hoc check is
probably sufficient and an in-loop constraint unnecessary. I would rather be told
to argue that properly than have it assumed.

---

## 6. ★ THE LARGEST OPEN NUMBER ON THIS BRANCH STILL HAS NO OWNER

**Nothing clears SIMP's margin at the light rung, including doing nothing** — the
unmodified control is **−27.6%** (2183 against SIMP's 3014.12). That is a property
of the parametric method, not of any mechanism, and no task is assigned to it.

---

## 7. IN PLAIN LANGUAGE

You asked me to fix a bug in the check that asks *"can trapped powder escape from
this part?"* — supposedly it was calling a sealed pocket drainable when the pocket
was walled in by material the user marked "keep".

**The problem is real but much smaller than it looked, in two ways.**

The code in question **is not shipped** — it is a test-harness file used by one
diagnostic program that is not even built normally. And the **real** production
check is correct: it treats kept material as solid, so powder correctly cannot
pass through it. The earlier refusal over a 337 mm³ sealed cavity was computed
properly.

Then I built the smallest test I could — a block with one empty cell in the
middle, walled in on all six sides — expecting it to expose the bug. **It passed
immediately**, and that is the finding. The shared code was never broken. It takes
*"what counts as inside the part"* as an input and gives the right answer either
way: ask whether the pocket is inside the region the optimiser controls and the
answer is *no, drainable*; ask whether powder can get out and the answer is *no,
sealed*. **Two questions, two correct answers.**

The only real fault was that the diagnostic asked the first question and printed
the answer under a label that sounded like the second. That is what misled me
earlier. It now prints **both**, side by side, so it cannot happen again.

★ **And the numbers behind the current recommendation never used the faulty
reading**, so nothing about the robust-triple decision changes.
