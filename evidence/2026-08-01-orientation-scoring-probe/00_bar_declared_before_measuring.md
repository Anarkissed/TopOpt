# S4 — THE BAR, DECLARED BEFORE ANY NUMBER WAS MEASURED

Written and committed BEFORE the probe was run. Nothing below was tuned to the
result.

## What "worth building" would mean

Choosing build orientation automatically costs a job-schema change (a
`build_direction` separate from `gravity.direction`), a UI affordance, and a
permanent explanation burden ("why did it rotate my part?"). That is not free.
So the bar is set at the level where a maintainer would actually accept the
cost:

**GO** requires BOTH of:
  * **G1 — a criterion that matters moves by >= 1.5x** between the best
    candidate and the maintainer's hand-picked orientation (build = -gravity),
    on a criterion that reaches the gate or the plate. "Matters" means: the
    solid interlayer margin (S-b, it is HALF of `margin.worst_case`), the strut
    interlayer margin (S-d, on the lattice receipt), or the support-requiring
    horizontal strut population (S-e, which is a hard print failure, not a
    percentage).
  * **G2 — the criteria do not all agree.** If every criterion picks the same
    direction and that direction is the obvious one, a scorer is ceremony: the
    maintainer already picks it. The value of a scorer is precisely resolving a
    trade-off a human cannot eyeball.

**NO-GO** if the best candidate beats the maintainer's by only a few percent on
every criterion, or if the winner is always the same trivially-guessable
direction.

**BLOCKED-STOP** if cheap scoring (one solved field, N re-evaluations) does not
reproduce the honest re-solve on the criterion that matters most. In that case
report the cost of the honest version instead of shipping a fast wrong score.

## What I expect before measuring (recorded so a miss is visible)

  * S-a support: expect a LARGE swing (the hook lying flat vs standing up is the
    textbook case; the V5 gate already ranks it).
  * S-b solid interlayer: expect a large swing (PR 247 measured ~6x on octet).
  * S-c strut in-plane: expect EXACTLY zero swing (invariant by construction).
  * S-d strut interlayer: expect the six cube axes IDENTICAL and every off-axis
    candidate STRICTLY WORSE. I expect NO off-axis improvement, and if I measure
    one I will treat it as a bug in my evaluation, not a finding.
  * S-e strut angles: expect the cube axes to carry the 12/36 horizontal
    population PR 201 measured, and I expect at least one candidate class to do
    better, because the octet strut axes are the <110> face diagonals and a
    <110> build direction makes one family vertical.
  * S-f: expect min-feature to be exactly invariant (an isotropic 2x2x2 test),
    so S-f is only non-vacuous if measured as build-HEIGHT and first-layer
    footprint, which do move.
